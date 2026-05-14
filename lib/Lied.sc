// lib/Lied.sc — schicksalslied 2.0 SC kernel
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <voiceGroup, <fxGroup, <outGroup;
    var <delaySynth, <reverbSynth, <outSynth;
    var <beat_sec;                  // updated via setBeatSec from Lua
    var <triSinInstances;           // Dictionary: cell_id (Symbol) → TriSin instance
    var <ringerInstances;           // Dictionary: cell_id (Symbol) → Ringer instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance

    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <micDrySynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
    var <grainSynths;
    var <grainPanLFOs, <grainCutoffLFOs, <grainResLFOs;
    var <grainRates, <grainDurs, <grainDelays;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        beat_sec = 0.5;             // default = 120 BPM
        triSinInstances  = Dictionary.new;
        ringerInstances  = Dictionary.new;
        samplerInstances = Dictionary.new;
        oneShotInstances = Dictionary.new;
        "Lied init: allocating buses + master FX...".postln;

        // --- Audio buses ---
        // dryBus       = main output (mirrors naherinlied's ~fb)
        // reverbBus    = pre-reverb send (mirrors naherinlied's c)
        // delayBus     = pre-delay send  (mirrors naherinlied's b)
        dryBus    = Bus.audio(server, 2);
        reverbBus = Bus.audio(server, 2);
        delayBus  = Bus.audio(server, 2);

        // --- Group hierarchy ---
        //   server default group
        //     └── voiceGroup (all voice instances will add to this; populated lazily later)
        //     └── fxGroup    (runs after voiceGroup, contains delay + reverb synths)
        voiceGroup = Group.new(server);
        fxGroup    = Group.after(voiceGroup);

        // --- SynthDefs: master FX ---
        // NOTE: norns-ritual wraps SynthDef definitions in `server.bind { ... }`,
        // but that pattern is unreliable in CLI-launched sclang (test.scd) — the
        // bundle mechanism races with `server.sync` and triggers "SynthDef X not
        // found" when the FX synth allocation immediately follows. Direct .add
        // calls + server.sync works reliably across both CLI and IDE contexts.

        // Delay reads delayBus → output to dryBus AND reverbBus (delay → reverb chain)
        // NOTE: CombL.ar's 4th arg is `decayTime` (time to decay 60 dB), not a
        // feedback amplitude coefficient. Naming the arg `decayTime` matches SC's
        // own terminology and avoids confusing the Lua-side param wiring later.
        SynthDef(\liedDelay, {
            arg inBus, dryOut, reverbOut, delayTime = 0.3, decayTime = 0.5,
                amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            var del = CombL.ar(sig, 2.0, delayTime, decayTime);
            var ampSmoothed = amp.lag(amp_slew);
            Out.ar(dryOut,    del * ampSmoothed);
            Out.ar(reverbOut, del * ampSmoothed);
        }).add;

        // Reverb reads reverbBus → output to dryBus
        SynthDef(\liedReverb, {
            arg inBus, dryOut, room = 0.5, damp = 0.5,
                amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            var rev = FreeVerb.ar(sig, 1.0, room, damp);
            Out.ar(dryOut, rev * amp.lag(amp_slew));
        }).add;

        // Pass dryBus through to main output (0)
        SynthDef(\liedOut, {
            arg inBus, amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            Out.ar(0, sig * amp.lag(amp_slew));
        }).add;

        // -----------------------------------------------------------------
        // GRANULAR DELAY CHAIN — ported from carters-delay-norns
        // -----------------------------------------------------------------

        // Mic input → micBus (mic feeds the delay buffer)
        SynthDef(\liedMic, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05;
            var sig = SoundIn.ar(in) * amp.lag3(amp_slew);
            Out.ar(out, sig);
        }).add;

        // Mic dry passthrough → main output bus (naherinlied feature, not in
        // carters-delay-norns standalone)
        SynthDef(\liedMicDry, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05;
            var sig = SoundIn.ar(in) * amp.lag3(amp_slew);
            Out.ar(out, [sig, sig]);
        }).add;

        // Pointer (write head) — advances through the delay buffer
        SynthDef(\liedPtr, {
            arg out = 0, buf = 0, rate = 1;
            var sig = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, BufFrames.kr(buf));
            Out.ar(out, sig);
        }).add;

        // Recorder — writes (micBus + preLevel * existing buffer) to delay buffer
        SynthDef(\liedRec, {
            arg ptrIn = 0, micIn = 0, buf = 0, preLevel = 0;
            var ptr = In.ar(ptrIn, 1);
            var sig = In.ar(micIn, 1);
            sig = sig + (BufRd.ar(1, buf, ptr) * preLevel);
            BufWr.ar(sig, buf, ptr);
        }).add;

        // Feedback patch mix — from main output, balance/softclip/HPF/inject,
        // writes back to micBus (creates a feedback loop)
        SynthDef(\liedFbPatchMix, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05, balance = 0,
                hpFreq = 12, noiseLevel = 0.0, sineLevel = 0, sineHz = 55;
            var input = InFeedback.ar(in, 2);
            var output;
            output = Balance2.ar(input[0], input[1], balance);
            output = output + (PinkNoise.ar * noiseLevel);
            output = output + (SinOsc.ar(sineHz) * sineLevel);
            output = HPF.ar(output, hpFreq);
            output = output.softclip;
            Out.ar(out, output * amp.lag3(amp_slew));
        }).add;

        // Grain synth — reads from delay buffer at randomized rates/positions
        SynthDef(\liedGran, {
            arg amp = 0, amp_slew = 0.05, buf = 0, out = 0,
                atk = 1, rel = 1, gate = 1,
                sync = 1, dens = 40,
                baseDur = 0.05, durRand = 1,
                rate = 1, rateRand = 1,
                pan = 0, panRand = 0,
                grainEnv = (-1), ptrBus = 0, ptrSampleDelay = 20000,
                ptrRandSamples = 5000, minPtrDelay = 1000,
                cutoff = 12000, resonance = 1;
            var sig, env, densCtrl, durCtrl, rateCtrl, panCtrl,
                ptr, ptrRand, totalDelay, maxGrainDur;
            env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);
            densCtrl = Select.ar(sync, [Dust.ar(dens), Impulse.ar(dens)]);
            durCtrl = baseDur * LFNoise1.ar(100).exprange(1 / durRand, durRand);
            rateCtrl = rate.lag3(0.5) * LFNoise1.ar(100).exprange(1 / rateRand, rateRand);
            panCtrl = pan + LFNoise1.kr(100).bipolar(panRand);
            ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples);
            totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay);
            ptr = In.ar(ptrBus, 1);
            ptr = ptr - totalDelay;
            ptr = ptr / BufFrames.kr(buf);
            maxGrainDur = (totalDelay / rateCtrl) / SampleRate.ir;
            durCtrl = min(durCtrl, maxGrainDur);
            sig = GrainBuf.ar(
                2,
                densCtrl,
                durCtrl,
                buf,
                rateCtrl,
                ptr,
                4,
                panCtrl,
                grainEnv
            );
            sig = MoogFF.ar(
                sig * env * amp.lag3(amp_slew),
                freq: cutoff,
                gain: resonance
            );
            Out.ar(out, sig);
        }).add;

        server.sync;

        // --- Instantiate master FX (persistent) ---
        delaySynth  = Synth.new(\liedDelay,
            [\inBus, delayBus, \dryOut, dryBus, \reverbOut, reverbBus],
            fxGroup);
        reverbSynth = Synth.new(\liedReverb,
            [\inBus, reverbBus, \dryOut, dryBus],
            fxGroup);
        outGroup    = Group.after(fxGroup);
        outSynth    = Synth.new(\liedOut,
            [\inBus, dryBus],
            outGroup);

        // -----------------------------------------------------------------
        // Granular delay chain — allocated persistently
        // -----------------------------------------------------------------

        // Delay buffer: 512 beats long at initial tempo (beat_sec defaults to 0.5)
        delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1);
        micBus = Bus.audio(server, 1);
        ptrBus = Bus.audio(server, 1);

        server.sync;

        // Granular group hierarchy: mic → ptr → rec → gran, before voiceGroup so
        // mic input writes to delayBuf before voiceGroup's voices read from it.
        // Voice groups remain head-of-chain for clean signal flow.
        micGrp  = Group.before(voiceGroup);
        ptrGrp  = Group.after(micGrp);
        recGrp  = Group.after(ptrGrp);
        granGrp = Group.after(recGrp);

        // Persistent granular chain synths (default amp = 0; turned up by cell toggles)
        micSynth        = Synth(\liedMic,        [\in, 0, \out, micBus, \amp, 0],     micGrp);
        micDrySynth     = Synth(\liedMicDry,     [\in, 0, \out, dryBus, \amp, 0],     micGrp);
        fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
        ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus],      ptrGrp);
        recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf], recGrp);

        // Grain LFOs (16 each for pan, cutoff, resonance). Stored as Ndefs; the
        // \rate.kr arg lets Sub-plan C wire params to these.
        grainPanLFOs     = Array.fill(16, { 0 });
        grainCutoffLFOs  = Array.fill(16, { 0 });
        grainResLFOs     = Array.fill(16, { 0 });
        16.do({ arg i;
            grainPanLFOs[i] = Ndef(
                ("grainPan" ++ i).asSymbol,
                { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(-1, 1); }
            );
            grainCutoffLFOs[i] = Ndef(
                ("grainCutoff" ++ i).asSymbol,
                { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(500, 15000); }
            );
            grainResLFOs[i] = Ndef(
                ("grainRes" ++ i).asSymbol,
                { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(0, 2); }
            );
        });

        // Scrambled per-grain rates, durations, delays (carters-delay-norns idiom)
        grainRates  = [1/4, 1/2, 1, 3/2, 2].scramble;
        grainDurs   = 16.collect({ arg i; beat_sec * (i + 1); }).scramble;
        grainDelays = 16.collect({ arg i; server.sampleRate * (beat_sec * (i + 1)) * 16; }).scramble;

        grainSynths = 16.collect({ arg n;
            Synth(\liedGran, [
                \amp, 0,
                \buf, delayBuf,
                \out, dryBus,
                \atk, 1,
                \rel, 1,
                \gate, 1,
                \sync, 1,
                \dens, 1 / (grainDurs[n] * grainRates[n % 5]),
                \baseDur, grainDurs[n],
                \durRand, 1,
                \rate, grainRates[n % 5],
                \rateRand, 1,
                \pan, grainPanLFOs[n],
                \panRand, 0,
                \grainEnv, -1,
                \ptrBus, ptrBus,
                \ptrSampleDelay, grainDelays[n],
                \ptrRandSamples, server.sampleRate * (beat_sec * ((n % 8) + 1)) * 2,
                \minPtrDelay, grainDelays[n],
                \cutoff, grainCutoffLFOs[n],
                \resonance, grainResLFOs[n]
            ], granGrp);
        });

        "Lied granular chain allocated.".postln;

        "Lied initialized.".postln;
    }

    setBeatSec { arg newBeatSec;
        beat_sec = newBeatSec;
        ("Lied: beat_sec = " ++ beat_sec).postln;
    }

    setMicAmp { arg amp;
        micSynth.set(\amp, amp);
    }

    setMicDryAmp { arg amp;
        micDrySynth.set(\amp, amp);
    }

    setGranularOutAmp { arg amp;
        granGrp.set(\amp, amp);  // single OSC msg updates all 16 grain synths
    }

    setFbPatchAmp { arg amp;
        fbPatchMixSynth.set(\amp, amp);
    }

    setFbPatchBalance { arg balance;
        fbPatchMixSynth.set(\balance, balance);
    }

    setFbPatchHpFreq { arg freq;
        fbPatchMixSynth.set(\hpFreq, freq);
    }

    setFbPatchNoiseLevel { arg lvl;
        fbPatchMixSynth.set(\noiseLevel, lvl);
    }

    setFbPatchSineLevel { arg lvl;
        fbPatchMixSynth.set(\sineLevel, lvl);
    }

    setFbPatchSineHz { arg hz;
        fbPatchMixSynth.set(\sineHz, hz);
    }

    free {
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        // Granular delay state (freed before master FX so signal flow unwinds cleanly)
        delayBuf.free;
        micBus.free;
        ptrBus.free;
        grainPanLFOs.do({ arg lfo; lfo.free; });
        grainCutoffLFOs.do({ arg lfo; lfo.free; });
        grainResLFOs.do({ arg lfo; lfo.free; });
        granGrp.free;
        recGrp.free;
        ptrGrp.free;
        micGrp.free;
        delaySynth.free;
        reverbSynth.free;
        outSynth.free;
        outGroup.free;
        voiceGroup.free;
        fxGroup.free;
        dryBus.free;
        reverbBus.free;
        delayBus.free;
        "Lied freed.".postln;
    }
}
