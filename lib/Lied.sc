// lib/Lied.sc — schicksalslied 2.0 SC kernel
Lied {
    classvar <grainCount = 4;  // Number of grain synths. 4 = lower CPU; 8 = original Carter's character.
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <granularBus;          // stereo bus voices route to when bus_routing = 'granular'
    var <granSendSynth;        // sums granularBus → micBus; lazy with granular chain
    var <voiceGroup, <fxGroup, <outGroup;
    var <delaySynth, <reverbSynth, <outSynth;
    var <beat_sec;                  // updated via setBeatSec from Lua
    var <triSinInstances;           // Dictionary: cell_id (Symbol) → TriSin instance
    var <ringerInstances;           // Dictionary: cell_id (Symbol) → Ringer instance
    var <sineInstances;             // Dictionary: cell_id (Symbol) → Sine instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance
    var <bufferCache;               // Dictionary: filePath (String) → 2-channel Buffer
    var <bufferRefCounts;           // Dictionary: filePath → Integer (# slots using it)
    var <samplerPaths;              // Dictionary: slot (Integer) → filePath (for refcount maintenance)
    var <oneShotPaths;              // Dictionary: slot → Array of filePaths
    var <oneShotLoadGen;            // Dictionary: slot → Integer, bumped by every load/clear
    var <samplerLoadGen;            // same, for looping sampler slots
    var <pendingTriSinParams;  // Dictionary: cellId (Symbol) → Dictionary(paramKey → value)
    var <pendingRingerParams;
    var <pendingSineParams;
    var <pendingSamplerParams; // Dictionary: slot (Integer) → Dictionary
    var <pendingOneShotParams;

    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
    var <grainSynths;
    var <grainPanLFOs, <grainCutoffLFOs, <grainResLFOs;
    var <grainRates, <grainDurs, <grainDelays;
    var <grainPanRates, <grainCutoffRates, <grainResRates;
    var <granularAllocated;
    var <grainDelayScale;  // multiplier for grain ptrSampleDelay (default 1.0)
    var <grainEnvBufs;     // custom grain envelope window buffers
    var <grainWindowIndex; // 0 = Hann (-1), 1 = Percussive, 2 = Swell, 3 = Reverse Swell
    var <grainCutoffCeiling;
    var <grainSyncDistribution;
    var <granularFrozen;
    var <grainRateMult;
    var <grainOctavesOn, <grainFifthsOn, <grainSuboctavesOn, <grainReverseOn;
    var <recPreLevel;
    // Pending granular setter values — applied at end of ensureGranularChain's
    // fork. Solves the "user toggles granular before chain is alive → setter's
    // .set fires on nil synth → amp stuck at 0" silent-grain bug.
    var <pendingMicAmp, <pendingGranularOutAmp;
    var <pendingFbAmp, <pendingFbBalance, <pendingFbHpFreq;
    var <pendingFbNoise, <pendingFbSineLevel, <pendingFbSineHz;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        beat_sec = 0.5;             // default = 120 BPM
        triSinInstances  = Dictionary.new;
        ringerInstances  = Dictionary.new;
        sineInstances    = Dictionary.new;
        samplerInstances = Dictionary.new;
        oneShotInstances = Dictionary.new;
        bufferCache      = Dictionary.new;
        bufferRefCounts  = Dictionary.new;
        samplerPaths     = Dictionary.new;
        oneShotPaths     = Dictionary.new;
        oneShotLoadGen   = Dictionary.new;
        samplerLoadGen   = Dictionary.new;
        pendingTriSinParams  = Dictionary.new;
        pendingRingerParams  = Dictionary.new;
        pendingSineParams    = Dictionary.new;
        pendingSamplerParams = Dictionary.new;
        pendingOneShotParams = Dictionary.new;
        "Lied init: allocating buses + master FX...".postln;

        // --- Audio buses ---
        // dryBus       = main output (mirrors naherinlied's ~fb)
        // reverbBus    = pre-reverb send (mirrors naherinlied's c)
        // delayBus     = pre-delay send  (mirrors naherinlied's b)
        dryBus    = Bus.audio(server, 2);
        reverbBus = Bus.audio(server, 2);
        delayBus  = Bus.audio(server, 2);
        granularBus = Bus.audio(server, 2);  // route voices into granular chain
        ("Lied buses: dryBus=" ++ dryBus.index ++ " reverbBus=" ++ reverbBus.index
            ++ " delayBus=" ++ delayBus.index ++ " granularBus=" ++ granularBus.index).postln;

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
                amp = 1.0, amp_slew = 0.1, to_reverb_send = 1, to_dry_send = 0;
            var sig = In.ar(inBus, 2);
            // maxdelaytime = 8s. CombL allocates from SC's real-time memory
            // pool, which is small on Norns — 16s here caused JackDriver
            // alloc-fail (~6MB stereo buffer). 8s (~3.1MB stereo) is half the
            // failure threshold and covers 8-beat sync at any tempo down to
            // 60 BPM. Matches the cap in DELAY_SYNC_BEATS in schicksalslied.lua.
            var del = CombL.ar(sig, 8.0, delayTime, decayTime);
            var ampSmoothed = amp.lag(amp_slew);
            Out.ar(dryOut,    del * ampSmoothed * to_dry_send.lag(0.05));
            Out.ar(reverbOut, del * ampSmoothed * to_reverb_send.lag(0.05));
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
            // softclip bounds the recirculated part (|out| < 1), so at
            // preLevel 1 the buffer can't grow without limit pass after pass.
            // It's linear below 0.5, so normal-level material is untouched.
            sig = sig + (BufRd.ar(1, buf, ptr) * preLevel).softclip;
            BufWr.ar(sig, buf, ptr);
        }).add;

        // Feedback patch mix — from main output, balance/softclip/HPF/inject, summed to
        // mono (micBus is 1 channel) and written back to micBus (creates a feedback loop)
        SynthDef(\liedFbPatchMix, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05, balance = 0,
                hpFreq = 12, noiseLevel = 0.0, sineLevel = 0, sineHz = 55;
            var input = InFeedback.ar(in, 2);
            var output;
            output = Balance2.ar(input[0], input[1], balance);
            output = output + (PinkNoise.ar * noiseLevel);
            output = output + (SinOsc.ar(sineHz) * sineLevel);
            output = HPF.ar(output, hpFreq.max(5));
            output = output.softclip;
            Out.ar(out, output.sum * 0.5 * amp.lag3(amp_slew));
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
                cutoff = 12000, cutoffMax = 16000, resonance = 1;
            var sig, env, grainTrigger, durCtrl, rateCtrl, panCtrl;
            var ptr, ptrRand, totalDelay, maxGrainDur;
            env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);
            grainTrigger = CoinGate.ar(sync.clip(0, 1), Impulse.ar(dens)) + CoinGate.ar(1 - sync.clip(0, 1), Dust.ar(dens));
            // Control rate is plenty: GrainBuf only reads dur/rate/pos when a
            // grain starts (these were audio rate; ~1/3 of the grain cost).
            durCtrl = baseDur * LFNoise1.kr(100).exprange(1 / durRand, durRand);
            rateCtrl = rate.lag3(0.5) * LFNoise1.kr(100).exprange(1 / rateRand, rateRand);
            panCtrl = pan + LFNoise1.kr(100).bipolar(panRand);
            ptrRand = LFNoise1.kr(100).bipolar(ptrRandSamples);
            totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay);
            ptr = In.ar(ptrBus, 1);
            ptr = ptr - totalDelay;
            ptr = ptr / BufFrames.kr(buf);
            maxGrainDur = (totalDelay / rateCtrl.abs) / SampleRate.ir;
            durCtrl = min(durCtrl, maxGrainDur);
            // Mono grains, filtered once, then panned: half the MoogFF cost of
            // filtering a stereo pair (MoogFF is about half the grain cost).
            // The pan LFO now moves the whole grain stream smoothly instead
            // of placing each grain where the LFO was when it started.
            sig = GrainBuf.ar(
                1,
                grainTrigger,
                durCtrl,
                buf,
                rateCtrl,
                ptr,
                4,
                0,
                grainEnv
            );
            sig = MoogFF.ar(
                sig * env * amp.lag3(amp_slew),
                freq: min(cutoff, cutoffMax).clip(50, 18000),
                gain: resonance.clip(0, 4)
            );
            Out.ar(out, Pan2.ar(sig, panCtrl));
        }).add;

        // Voice → granular bus → micBus send. Sums stereo voice signal to
        // mono with 0.5 gain so the grain chain processes voice audio along
        // with the mic input. Only audible when granular chain is allocated.
        SynthDef(\liedGranSend, {
            arg in = 0, out = 0;
            var sig = In.ar(in, 2);
            var mono = (sig[0] + sig[1]) * 0.5;
            Out.ar(out, mono);
        }).add;

        // --- SynthDefs: voices ---
        // Added here, where Crone has already booted the server. They used to
        // come from a StartUp hook in each voice class calling
        // Server.default.waitForBoot, which runs at every sclang start
        // (whatever script is loaded) and could boot scsynth before Crone set
        // it up — on norns only Crone may boot the server.
        [TriSin, Ringer, Sine, Sampler, OneShot].do({ |voice| voice.addSynthDefs });

        server.sync;

        // --- Instantiate master FX (persistent) ---
        // Order matters: SC groups execute head→tail, and audio buses clear
        // between blocks. delaySynth's writes to reverbBus must happen BEFORE
        // reverbSynth reads from it in the same block — otherwise the delay's
        // contribution to reverbBus gets zeroed before reverb can use it.
        // addToHead pushes each new synth in front of the previous one, so
        // instantiating reverb first then delay produces order: delay, reverb.
        reverbSynth = Synth.new(\liedReverb,
            [\inBus, reverbBus, \dryOut, dryBus],
            fxGroup);
        delaySynth  = Synth.new(\liedDelay,
            [\inBus, delayBus, \dryOut, dryBus, \reverbOut, reverbBus],
            fxGroup);
        outGroup    = Group.after(fxGroup);
        outSynth    = Synth.new(\liedOut,
            [\inBus, dryBus],
            outGroup);

        granularAllocated      = false;
        grainPanRates          = Array.fill(grainCount, { rrand(1, 64) });
        grainCutoffRates       = Array.fill(grainCount, { rrand(1, 64) });
        grainResRates          = Array.fill(grainCount, { rrand(1, 64) });
        grainDelayScale        = 1.0;
        grainWindowIndex       = 0;
        grainCutoffCeiling     = 16000;
        grainSyncDistribution  = 1.0;
        granularFrozen         = false;
        grainRateMult          = 1.0;
        grainOctavesOn         = 0;
        grainFifthsOn          = 0;
        grainSuboctavesOn      = 0;
        grainReverseOn         = 0;
        recPreLevel            = 0.0;
        "Lied initialized.".postln;
    }

    setBeatSec { arg newBeatSec;
        // Only act + print if the value actually changed. Norns fires the
        // clock_tempo action multiple times per encoder tick (delay_sync
        // re-fire + internal subsystem broadcasts), each calling this with
        // the same value — produces noisy duplicate prints otherwise.
        if (beat_sec != newBeatSec) {
            beat_sec = newBeatSec;
            ("Lied: beat_sec = " ++ beat_sec).postln;
        };
    }

    setOutAmp { arg amp;
        outSynth.set(\amp, amp);
    }

    setDelayTime { arg t;
        delaySynth.set(\delayTime, t);
    }

    setDelayDecay { arg t;
        delaySynth.set(\decayTime, t);
    }

    setDelayAmp { arg amp;
        delaySynth.set(\amp, amp);
    }

    setDelayToReverbSend { arg amt;
        delaySynth.set(\to_reverb_send, amt);
    }

    setDelayToDrySend { arg amt;
        delaySynth.set(\to_dry_send, amt);
    }

    // Scale the grain ptrSampleDelay for all grains.
    // Stored value takes effect on NEXT granular chain allocation (re-engage
    // granular toggles after setting). To make it effective on an already-
    // running chain, panic + re-engage.
    setGrainDelayScale { arg scale;
        grainDelayScale = scale;
        ("Lied: grainDelayScale = " ++ scale
            ++ " (effective on next granular allocation)").postln;
    }

    setReverbRoom { arg room;
        reverbSynth.set(\room, room);
    }

    setReverbDamp { arg damp;
        reverbSynth.set(\damp, damp);
    }

    setReverbAmp { arg amp;
        reverbSynth.set(\amp, amp);
    }

    // -----------------------------------------------------------------
    // Lazy granular chain allocation
    // -----------------------------------------------------------------
    // Called the first time mic_amp or granular_out_amp
    // is set to a non-zero value. Allocates the delay buffer, mic chain,
    // recorder, fbPatchMix, and grainCount grain synths.
    // Idempotent — subsequent calls are no-ops once granularAllocated.

    ensureGranularChain {
        if (granularAllocated) { ^this };
        // Set flag BEFORE forking to gate re-entry on rapid double-press.
        // There's a brief window (~one server.sync round-trip, ~5-20ms) where
        // granularAllocated is true but the synths aren't yet allocated. The
        // amp setters that depend on these check granularAllocated, so they
        // will attempt micSynth.set(...) etc. and silently no-op for the
        // window where micSynth is still nil. Acceptable trade-off vs the
        // alternative of double-allocation.
        granularAllocated = true;
        ("Lied: allocating granular chain (" ++ grainCount ++ " grains)...").postln;

        fork {
            // Buffer + buses + custom grain envelope windows
            delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1);
            grainEnvBufs = [
                Buffer.sendCollection(server, Env.perc(0.01, 0.99, 1, -4).asSignal(512)),
                Buffer.sendCollection(server, Env.new([0, 1, 0], [0.7, 0.3], [3, -3]).asSignal(512)),
                Buffer.sendCollection(server, Env.new([0, 1, 0], [0.98, 0.02], [4, -4]).asSignal(512))
            ];
            micBus = Bus.audio(server, 1);
            ptrBus = Bus.audio(server, 1);

            server.sync;

            // Group hierarchy: mic → ptr → rec → gran, before voiceGroup
            micGrp  = Group.before(voiceGroup);
            ptrGrp  = Group.after(micGrp);
            recGrp  = Group.after(ptrGrp);
            granGrp = Group.after(recGrp);

            // Persistent chain synths (default amp = 0)
            micSynth        = Synth(\liedMic,        [\in, 0, \out, micBus, \amp, 0],     micGrp);
            fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
            // Voice→granular send (reads granularBus, writes to micBus).
            // Lives in micGrp so it runs at the head of the chain.
            granSendSynth = Synth(\liedGranSend, [\in, granularBus, \out, micBus], micGrp);
            ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus, \rate, if (granularFrozen) { 0 } { 1 }], ptrGrp);
            recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf, \preLevel, recPreLevel], recGrp);
            if (granularFrozen) { recSynth.run(false); };

            // Grain LFOs (grainCount each)
            grainPanLFOs    = Array.fill(grainCount, { 0 });
            grainCutoffLFOs = Array.fill(grainCount, { 0 });
            grainResLFOs    = Array.fill(grainCount, { 0 });
            grainCount.do({ arg i;
                var panRate = grainPanRates[i];
                var cutoffRate = grainCutoffRates[i];
                var resRate = grainResRates[i];
                grainPanLFOs[i] = Ndef(
                    ("grainPan" ++ i).asSymbol,
                    { |rate=8| LFTri.kr(1 / (rate * beat_sec)).range(-1, 1); }
                );
                grainPanLFOs[i].set(\rate, panRate);
                grainCutoffLFOs[i] = Ndef(
                    ("grainCutoff" ++ i).asSymbol,
                    { |rate=8| LFTri.kr(1 / (rate * beat_sec)).range(500, 15000); }
                );
                grainCutoffLFOs[i].set(\rate, cutoffRate);
                grainResLFOs[i] = Ndef(
                    ("grainRes" ++ i).asSymbol,
                    { |rate=8| LFTri.kr(1 / (rate * beat_sec)).range(0, 2); }
                );
                grainResLFOs[i].set(\rate, resRate);
            });

            // Wait for the Ndef proxies above to fully allocate on the
            // server before we map them into grain synths. Without this sync,
            // the grain synth creation can race ahead of the Ndefs, producing
            // a flood of "Node X not found" errors as /n_set targets nodes
            // the server hasn't created yet.
            server.sync;

            // Scrambled per-grain rates/durations/delays (grainCount grains).
            // Grain delays are scaled by grainDelayScale (default 1.0):
            //   scale=1.0 → 8..64 sec range (Carter's Delay character)
            //   scale=0.1 → 0.8..6.4 sec range (more immediate response)
            grainRates  = this.computeTapRates;
            grainDurs   = grainCount.collect({ arg i; beat_sec * (i + 1); }).scramble;
            grainDelays = grainCount.collect({ arg i;
                server.sampleRate * (beat_sec * (i + 1)) * 16 * grainDelayScale;
            }).scramble;

            grainSynths = grainCount.collect({ arg n;
                var envBufNum = if (grainWindowIndex == 0) { -1 } { grainEnvBufs[grainWindowIndex - 1].bufnum };
                Synth(\liedGran, [
                    \amp, 0,
                    \buf, delayBuf,
                    \out, dryBus,
                    \atk, 1,
                    \rel, 1,
                    \gate, 1,
                    \sync, grainSyncDistribution,
                    \dens, 1 / (grainDurs[n] * grainRates[n].abs),
                    \baseDur, grainDurs[n],
                    \durRand, 1,
                    \rate, grainRates[n],
                    \rateRand, 1,
                    \pan, grainPanLFOs[n],
                    \panRand, 0,
                    \grainEnv, envBufNum,
                    \ptrBus, ptrBus,
                    \ptrSampleDelay, grainDelays[n],
                    \ptrRandSamples, server.sampleRate * (beat_sec * ((n % grainCount) + 1)) * 2,
                    \minPtrDelay, grainDelays[n],
                    \cutoff, grainCutoffLFOs[n],
                    \cutoffMax, grainCutoffCeiling,
                    \resonance, grainResLFOs[n]
                ], granGrp);
            });

            // Apply any pending setter values that were called BEFORE the
            // chain was fully allocated (the off-by-fork race). This is what
            // makes "toggle granular_out on" actually set granGrp's amp on the
            // first toggle instead of requiring an off-then-on workaround.
            if (pendingMicAmp.notNil)        { micSynth.set(\amp, pendingMicAmp); };
            if (pendingGranularOutAmp.notNil) { granGrp.set(\amp, pendingGranularOutAmp); };
            if (pendingFbAmp.notNil)         { fbPatchMixSynth.set(\amp, pendingFbAmp); };
            if (pendingFbBalance.notNil)     { fbPatchMixSynth.set(\balance, pendingFbBalance); };
            if (pendingFbHpFreq.notNil)      { fbPatchMixSynth.set(\hpFreq, pendingFbHpFreq); };
            if (pendingFbNoise.notNil)       { fbPatchMixSynth.set(\noiseLevel, pendingFbNoise); };
            if (pendingFbSineLevel.notNil)   { fbPatchMixSynth.set(\sineLevel, pendingFbSineLevel); };
            if (pendingFbSineHz.notNil)      { fbPatchMixSynth.set(\sineHz, pendingFbSineHz); };

            "Lied granular chain allocated.".postln;
        };
    }

    // -----------------------------------------------------------------
    // Free the granular chain entirely (called from panic and from free)
    // -----------------------------------------------------------------

    freeGranularChain {
        if (granularAllocated.not) { ^this };
        "Lied: freeing granular chain...".postln;

        grainPanLFOs.do({ arg lfo; lfo.free; });
        grainCutoffLFOs.do({ arg lfo; lfo.free; });
        grainResLFOs.do({ arg lfo; lfo.free; });
        granGrp.free;
        recGrp.free;
        ptrGrp.free;
        granSendSynth = nil;  // freed by micGrp.free below
        micGrp.free;
        if (grainEnvBufs.notNil) {
            grainEnvBufs.do({ arg b; if (b.notNil) { b.free; } });
            grainEnvBufs = nil;
        };
        granularFrozen = false;
        delayBuf.free;
        micBus.free;
        ptrBus.free;

        grainSynths = nil;
        grainPanLFOs = nil;
        grainCutoffLFOs = nil;
        grainResLFOs = nil;
        micSynth = nil;
        ptrSynth = nil;
        recSynth = nil;
        fbPatchMixSynth = nil;
        delayBuf = nil;
        micBus = nil;
        ptrBus = nil;
        micGrp = nil;
        ptrGrp = nil;
        recGrp = nil;
        granGrp = nil;

        // Clear pending values so a future ensureGranularChain doesn't apply
        // stale values from a previous lifecycle.
        pendingMicAmp = nil;
        pendingGranularOutAmp = nil;
        pendingFbAmp = nil;
        pendingFbBalance = nil;
        pendingFbHpFreq = nil;
        pendingFbNoise = nil;
        pendingFbSineLevel = nil;
        pendingFbSineHz = nil;

        granularAllocated = false;
    }

    setMicAmp { arg amp;
        pendingMicAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { micSynth.notNil }) { micSynth.set(\amp, amp) };
    }

    setGranularOutAmp { arg amp;
        pendingGranularOutAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { granGrp.notNil }) { granGrp.set(\amp, amp) };
    }

    setFbPatchAmp { arg amp;
        pendingFbAmp = amp;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\amp, amp) };
    }

    setFbPatchBalance { arg balance;
        pendingFbBalance = balance;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\balance, balance) };
    }

    setFbPatchHpFreq { arg freq;
        pendingFbHpFreq = freq;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\hpFreq, freq) };
    }

    setFbPatchNoiseLevel { arg lvl;
        pendingFbNoise = lvl;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\noiseLevel, lvl) };
    }

    setFbPatchSineLevel { arg lvl;
        pendingFbSineLevel = lvl;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\sineLevel, lvl) };
    }

    setFbPatchSineHz { arg hz;
        pendingFbSineHz = hz;
        if (granularAllocated and: { fbPatchMixSynth.notNil }) { fbPatchMixSynth.set(\sineHz, hz) };
    }

    setGrainPanRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };  // out of range, ignore
        grainPanRates[grainIdx] = rate;
        if (granularAllocated and: { grainPanLFOs[grainIdx].notNil }) {
            grainPanLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainCutoffRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };  // out of range, ignore
        grainCutoffRates[grainIdx] = rate;
        if (granularAllocated and: { grainCutoffLFOs[grainIdx].notNil }) {
            grainCutoffLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainResRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };  // out of range, ignore
        grainResRates[grainIdx] = rate;
        if (granularAllocated and: { grainResLFOs[grainIdx].notNil }) {
            grainResLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGranularFreeze { arg freeze;
        granularFrozen = (freeze > 0);
        if (granularAllocated and: { ptrSynth.notNil and: { recSynth.notNil } }) {
            if (granularFrozen) {
                server.makeBundle(nil, { ptrSynth.set(\rate, 0); recSynth.run(false); });
            } {
                server.makeBundle(nil, { ptrSynth.set(\rate, 1); recSynth.run(true); });
            };
        };
    }

    setRecPreLevel { arg lvl;
        recPreLevel = lvl.asFloat.clip(0, 1);
        if (granularAllocated and: { recSynth.notNil }) {
            recSynth.set(\preLevel, recPreLevel);
        };
    }

    setGrainWindow { arg winIdx;
        grainWindowIndex = winIdx.asInteger.clip(0, 3);
        if (granularAllocated and: { grainSynths.notNil and: { grainEnvBufs.notNil } }) {
            var envBufNum = if (grainWindowIndex == 0) { -1 } { grainEnvBufs[grainWindowIndex - 1].bufnum };
            grainSynths.do({ |g| if (g.notNil) { g.set(\grainEnv, envBufNum); }; });
        };
    }

    setGrainSyncDistribution { arg syncDist;
        grainSyncDistribution = syncDist.asFloat.clip(0, 1);
        if (granularAllocated and: { granGrp.notNil }) {
            granGrp.set(\sync, grainSyncDistribution);
        };
    }

    setGrainCutoffCeiling { arg maxFreq;
        grainCutoffCeiling = maxFreq.asFloat.clip(200, 18000);
        if (granularAllocated and: { granGrp.notNil }) {
            granGrp.set(\cutoffMax, grainCutoffCeiling);
        };
    }

    computeTapRates {
        var finalRates = Array.newClear(grainCount);
        var oct = (grainOctavesOn > 0);
        var fif = (grainFifthsOn > 0);
        var sub = (grainSuboctavesOn > 0);
        var baseRates;

        // Dedicated 4-voice table: each active category is guaranteed its own voice.
        case
            { oct and: fif and: sub } { baseRates = [1/2, 1, 3/2, 2]; }       // Sub -1, Unison, Fifth, Octave
            { oct and: fif }          { baseRates = [1, 2, 3/2, 4/3]; }       // Unison, Octave, Fifth, Fourth
            { oct and: sub }          { baseRates = [1/4, 1/2, 1, 2]; }       // Sub -2, Sub -1, Unison, Octave
            { fif and: sub }          { baseRates = [1/2, 1, 3/2, 4/3]; }     // Sub -1, Unison, Fifth, Fourth
            { oct }                   { baseRates = [1, 2, 1, 2]; }           // Unison, Octave, Unison, Octave
            { fif }                   { baseRates = [1, 3/2, 4/3, 9/8]; }     // Unison, Fifth, Fourth, Maj2
            { sub }                   { baseRates = [1, 1/2, 1/4, 1/2]; }     // Unison, Sub -1, Sub -2, Sub -1
            { true }                  { baseRates = [1/4, 1/2, 1, 3/2]; };    // Carter default: 1/4, 1/2, 1, 1.5

        grainCount.do({ |i|
            var base = baseRates[i % baseRates.size];
            var signed = if (grainReverseOn > 0 and: { i.odd }) { base.neg } { base };
            finalRates[i] = signed * grainRateMult;
        });
        ^finalRates;
    }

    applyTapRates {
        var finalRates = this.computeTapRates;
        grainRates = finalRates;
        if (granularAllocated and: { grainSynths.notNil }) {
            grainCount.do({ |i|
                if (grainSynths[i].notNil) {
                    // dens follows rate (same formula as allocation), so a live
                    // rate change matches what a fresh chain would sound like.
                    grainSynths[i].set(
                        \rate, finalRates[i],
                        \dens, 1 / (grainDurs[i] * finalRates[i].abs));
                };
            });
        };
    }

    setGrainRateMult { arg mult;
        grainRateMult = mult.asFloat.max(0.01);
        this.applyTapRates;
    }

    setGrainOctaves { arg on;
        grainOctavesOn = if (on > 0) { 1 } { 0 };
        this.applyTapRates;
    }

    setGrainFifths { arg on;
        grainFifthsOn = if (on > 0) { 1 } { 0 };
        this.applyTapRates;
    }

    setGrainSuboctaves { arg on;
        grainSuboctavesOn = if (on > 0) { 1 } { 0 };
        this.applyTapRates;
    }

    setGrainReverse { arg on;
        grainReverseOn = if (on > 0) { 1 } { 0 };
        this.applyTapRates;
    }

    // -----------------------------------------------------------------
    // TriSin instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocTriSin { arg cellId;
        var pending;
        if (triSinInstances[cellId].isNil) {
            triSinInstances[cellId] = TriSin.new(dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
            // Apply pending param values that were set before alloc
            pending = pendingTriSinParams[cellId];
            if (pending.notNil) {
                pending.keysValuesDo({ |k, v|
                    triSinInstances[cellId].setParam('all', k, v);
                });
                pendingTriSinParams[cellId] = nil;
                ("TriSin allocated: " ++ cellId
                    ++ " (applied " ++ pending.size ++ " pending params)").postln;
            } {
                ("TriSin allocated: " ++ cellId).postln;
            };
        }
    }

    freeTriSin { arg cellId;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.free;
            triSinInstances[cellId] = nil;
            pendingTriSinParams[cellId] = nil;  // clear stale pending
            ("TriSin freed: " ++ cellId).postln;
        }
    }

    triggerTriSin { arg cellId, voiceKey, freq;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.trigger(voiceKey, freq);
        }
    }

    setTriSinParam { arg cellId, paramKey, paramValue;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            // No instance yet — cache for when alloc happens
            if (pendingTriSinParams[cellId].isNil) {
                pendingTriSinParams[cellId] = Dictionary.new;
            };
            pendingTriSinParams[cellId][paramKey] = paramValue;
        };
    }

    // -----------------------------------------------------------------
    // Ringer instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocRinger { arg cellId;
        var pending;
        if (ringerInstances[cellId].isNil) {
            ringerInstances[cellId] = Ringer.new(dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
            // Apply pending param values that were set before alloc
            pending = pendingRingerParams[cellId];
            if (pending.notNil) {
                pending.keysValuesDo({ |k, v|
                    ringerInstances[cellId].setParam('all', k, v);
                });
                pendingRingerParams[cellId] = nil;
                ("Ringer allocated: " ++ cellId
                    ++ " (applied " ++ pending.size ++ " pending params)").postln;
            } {
                ("Ringer allocated: " ++ cellId).postln;
            };
        }
    }

    freeRinger { arg cellId;
        var inst = ringerInstances[cellId];
        if (inst.notNil) {
            inst.free;
            ringerInstances[cellId] = nil;
            pendingRingerParams[cellId] = nil;  // clear stale pending
            ("Ringer freed: " ++ cellId).postln;
        }
    }

    triggerRinger { arg cellId, voiceKey, freq;
        var inst = ringerInstances[cellId];
        if (inst.notNil) {
            inst.trigger(voiceKey, freq);
        }
    }

    setRingerParam { arg cellId, paramKey, paramValue;
        var inst = ringerInstances[cellId];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            // No instance yet — cache for when alloc happens
            if (pendingRingerParams[cellId].isNil) {
                pendingRingerParams[cellId] = Dictionary.new;
            };
            pendingRingerParams[cellId][paramKey] = paramValue;
        };
    }

    // -----------------------------------------------------------------
    // Sine instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocSine { arg cellId;
        var pending;
        if (sineInstances[cellId].isNil) {
            sineInstances[cellId] = Sine.new(dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
            // Apply pending param values that were set before alloc
            pending = pendingSineParams[cellId];
            if (pending.notNil) {
                pending.keysValuesDo({ |k, v|
                    sineInstances[cellId].setParam('all', k, v);
                });
                pendingSineParams[cellId] = nil;
                ("Sine allocated: " ++ cellId
                    ++ " (applied " ++ pending.size ++ " pending params)").postln;
            } {
                ("Sine allocated: " ++ cellId).postln;
            };
        }
    }

    freeSine { arg cellId;
        var inst = sineInstances[cellId];
        if (inst.notNil) {
            inst.free;
            sineInstances[cellId] = nil;
            pendingSineParams[cellId] = nil;  // clear stale pending
            ("Sine freed: " ++ cellId).postln;
        }
    }

    triggerSine { arg cellId, voiceKey, freq;
        var inst = sineInstances[cellId];
        if (inst.notNil) {
            inst.trigger(voiceKey, freq);
        }
    }

    setSineParam { arg cellId, paramKey, paramValue;
        var inst = sineInstances[cellId];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            // No instance yet — cache for when alloc happens
            if (pendingSineParams[cellId].isNil) {
                pendingSineParams[cellId] = Dictionary.new;
            };
            pendingSineParams[cellId][paramKey] = paramValue;
        };
    }

    // -----------------------------------------------------------------
    // Voice SynthDef helpers (used by the voice classes' *addSynthDefs)
    // -----------------------------------------------------------------

    // Voices are persistent synths (retriggered, never freed). This pauses
    // the enclosing synth once a note has had time to finish (time since the
    // last trigger > length) AND its pre-amp signal is below -80 dB, so idle
    // voices cost no DSP; the voice classes resume it (n_run) in the same
    // bundle as the next trigger. Time alone isn't enough (filters ring, and
    // a self-oscillating MoogFF never goes quiet, so it never pauses), nor
    // is silence alone (a sample can have quiet gaps). PauseSelf pauses in
    // the same control block the condition turns true, and re-arms when the
    // resuming trigger resets Sweep. (An envelope doneAction fires a block
    // later, which swallowed a trigger landing in that block.) Returns the
    // pause condition, for notePan.
    *pauseWhenSilent { arg trig, length, sig;
        var paused = (Sweep.kr(trig) > length) * (Amplitude.kr(sig).asArray.sum < 1e-4);
        PauseSelf.kr(paused);
        ^paused
    }

    // Pan for a retriggered voice. A paused voice's pan lag stops tracking,
    // so a note that resumes one snaps to the current pan (zero lag time
    // for one control block) instead of gliding over from where the last
    // note left it. A note that retriggers a voice still sounding keeps
    // slewing: snapping there would jump the ringing tail across the
    // stereo field within one block, which clicks. `paused` is what
    // pauseWhenSilent returned; Delay1 reads it from the last block the
    // synth ran, so it is 1 only on the block that resumes a paused voice.
    *notePan { arg pan, slew, trig, paused;
        ^pan.lag3(slew * (1 - (Trig1.kr(trig, ControlDur.ir) * Delay1.kr(paused))));
    }

    // -----------------------------------------------------------------
    // Shared sample-buffer cache (looping samplers + one-shots)
    // -----------------------------------------------------------------
    // bufferCache holds one Buffer per file path, refcounted across every
    // slot that uses it. Every cached Buffer is 2-channel: Sampler (BufRd)
    // and OneShot (PlayBuf) both read 2 channels, and a buffer UGen asked
    // for more channels than a buffer has plays only the ones it finds (a
    // mono file came out of the left speaker only). Mono files are read
    // into both channels, which through Balance2 sounds exactly like Pan2
    // on the mono signal; files with more than 2 channels keep the first two.
    //
    // Loads are async (fork + server.sync), so every load/clear bumps the
    // slot's load generation. A load fork that finishes after a newer
    // request releases its buffers instead of installing them; otherwise
    // back-to-back loads (PSET recall, E3 on a file param stepping through
    // files) overwrote each other's instances without freeing them.

    bumpGen { arg gens, slot;
        gens[slot] = (gens[slot] ? 0) + 1;
        ^gens[slot];
    }

    // True if filePath opens and fits the 10-minute buffer cap. Cached
    // buffers are always 2-channel, so 600 s costs ~230 MB @ 48k whatever
    // the file's channel count (dedup means N slots on one file = 1 buffer).
    sampleFileOk { arg label, slot, filePath;
        var sf = SoundFile.openRead(filePath);
        var duration;
        if (sf.isNil) {
            (label ++ " " ++ slot ++ " load failed: cannot open " ++ filePath).postln;
            ^false
        };
        duration = sf.numFrames / sf.sampleRate;
        sf.close;
        if (duration > 600) {
            (label ++ " " ++ slot ++ " load REFUSED: " ++ duration.round(0.1)
                ++ "s exceeds 600s max (would exhaust Norns RAM).").postln;
            ^false
        };
        ^true
    }

    // Read filePath as a 2-channel Buffer (see above).
    readStereoBuffer { arg filePath;
        var sf = SoundFile.openRead(filePath);
        var numChannels = 2;
        if (sf.notNil) { numChannels = sf.numChannels; sf.close };
        ^if (numChannels == 2) {
            Buffer.read(server, filePath)
        } {
            Buffer.readChannel(server, filePath,
                channels: if (numChannels == 1) { [0, 0] } { [0, 1] })
        };
    }

    // Take a reference on the cached Buffer for filePath, reading it first if
    // nothing has it yet. Must be called from inside a Routine (it waits).
    acquireBuffer { arg filePath;
        var buf;
        // The \loading sentinel handles two forks loading the same file
        // concurrently: the second polls until the first finishes, then
        // shares its Buffer instead of orphaning a second one.
        while ({ bufferCache[filePath] == \loading }) { 0.05.wait };
        buf = bufferCache[filePath];
        if (buf.notNil) {
            bufferRefCounts[filePath] = (bufferRefCounts[filePath] ? 0) + 1;
        } {
            bufferCache[filePath] = \loading;
            buf = this.readStereoBuffer(filePath);
            server.sync;
            bufferCache[filePath] = buf;
            bufferRefCounts[filePath] = 1;
        };
        ^buf;
    }

    // Drop one reference; free the Buffer once no slot uses it.
    releaseBuffer { arg filePath;
        if (bufferRefCounts[filePath].notNil) {
            bufferRefCounts[filePath] = bufferRefCounts[filePath] - 1;
            if (bufferRefCounts[filePath] <= 0) {
                if (bufferCache[filePath].notNil
                    and: { bufferCache[filePath] != \loading }) {
                    bufferCache[filePath].free;
                };
                bufferCache[filePath] = nil;
                bufferRefCounts[filePath] = nil;
                ("Buffer freed: " ++ filePath).postln;
            };
        };
    }

    // Copy the outgoing instance's live params onto its replacement, so a
    // reload keeps the user's sound instead of resetting to SynthDef
    // defaults. Voice 1 holds what setParam('all', ...) last wrote, and any
    // set_param that arrived mid-load landed on the old instance too.
    carryVoiceParams { arg old, inst, keys;
        old.voiceParams[old.class.voiceKeys[0]].keysValuesDo({ |k, v|
            if (keys.includes(k)) { inst.setParam('all', k, v) };
        });
    }

    // -----------------------------------------------------------------
    // Sampler instance lifecycle (per row-4/6 slot, 1-16)
    // -----------------------------------------------------------------

    // Read filePath, then swap a new Sampler into the slot. The old
    // instance keeps playing until the swap.
    loadSampler { arg slot, filePath;
        // Bump first: even a refused load cancels older loads still in flight,
        // so an earlier file can't install over the one the user picked last.
        var gen = this.bumpGen(samplerLoadGen, slot);
        if (this.sampleFileOk("Sampler", slot, filePath)) {
            fork {
                var buf = this.acquireBuffer(filePath);
                if (samplerLoadGen[slot] != gen) {
                    // A newer load/clear for this slot arrived while we were reading.
                    this.releaseBuffer(filePath);
                    ("Sampler " ++ slot ++ " load superseded: " ++ filePath).postln;
                } {
                    this.installSampler(slot, buf, filePath);
                    ("Sampler " ++ slot ++ " loaded " ++ filePath).postln;
                };
            };
        };
    }

    installSampler { arg slot, buf, filePath;
        // Params Lua owns (not per-trigger start/end, the buffer, or the bus
        // routing, which a fresh instance already has right).
        var carryKeys = #[\amp, \amp_slew, \cutoff, \cutoff_slew, \resonance,
            \pan, \pan_slew, \rate, \rateSlew,
            \dry_send, \reverb_send, \delay_send, \granular_send];
        var old = samplerInstances[slot];
        var oldPath = samplerPaths[slot];
        var pending = pendingSamplerParams[slot];
        var inst = Sampler.new(buf, dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
        if (old.notNil) {
            this.carryVoiceParams(old, inst, carryKeys);
            old.free;
        };
        if (pending.notNil) {
            pending.keysValuesDo({ |k, v| inst.setParam('all', k, v) });
            pendingSamplerParams[slot] = nil;
        };
        samplerInstances[slot] = inst;
        samplerPaths[slot] = filePath;
        // Release the old buffer only now that the new one holds its ref,
        // so reloading the same file never frees and re-reads it.
        if (oldPath.notNil) { this.releaseBuffer(oldPath) };
    }

    clearSampler { arg slot;
        var inst = samplerInstances[slot];
        var path = samplerPaths[slot];
        this.bumpGen(samplerLoadGen, slot);  // cancel any load still in flight
        if (inst.notNil) {
            inst.free;
            samplerInstances[slot] = nil;
            pendingSamplerParams[slot] = nil;  // clear stale pending
            ("Sampler " ++ slot ++ " cleared").postln;
        };
        if (path.notNil) { this.releaseBuffer(path) };
        samplerPaths[slot] = nil;
    }

    triggerSampler { arg slot, voiceKey, startPos, endPos, rate;
        var inst = samplerInstances[slot];
        if (inst.notNil) {
            inst.trigger(voiceKey, startPos, endPos, rate);
        }
    }

    setSamplerParam { arg slot, paramKey, paramValue;
        var inst = samplerInstances[slot];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            // No instance yet — cache for when load happens
            if (pendingSamplerParams[slot].isNil) {
                pendingSamplerParams[slot] = Dictionary.new;
            };
            pendingSamplerParams[slot][paramKey] = paramValue;
        };
    }

    // -----------------------------------------------------------------
    // OneShot instance lifecycle (per row-8 slot, 1-12)
    // -----------------------------------------------------------------
    // A slot holds one OneShot over an Array of buffers: a single file is a
    // 1-element Array, a folder is one buffer per file (the trigger's bufIdx
    // picks which). oneShotPaths[slot] is always an Array of path Strings.

    // Read filePaths into buffers, then swap a new OneShot into the slot.
    // The old instance keeps playing until the swap. The caller has already
    // bumped oneShotLoadGen and passes the new generation.
    loadOneShotPaths { arg slot, filePaths, label, gen;
        fork {
            var buffers = List.new, acquired = List.new;
            filePaths.do({ |p|
                // Stop reading as soon as a newer load/clear arrives, so a
                // cancelled folder load doesn't hold all its files in RAM.
                if (oneShotLoadGen[slot] == gen) {
                    buffers.add(this.acquireBuffer(p));
                    acquired.add(p);
                };
            });
            if (oneShotLoadGen[slot] != gen) {
                acquired.do({ |p| this.releaseBuffer(p) });
                ("OneShot " ++ slot ++ " load superseded: " ++ label).postln;
            } {
                this.installOneShot(slot, buffers.asArray, filePaths);
                ("OneShot " ++ slot ++ " loaded " ++ label
                    ++ " (" ++ buffers.size ++ " buffers)").postln;
            };
        };
    }

    installOneShot { arg slot, buffers, filePaths;
        // Params Lua owns (everything except per-trigger buf/rate/amp_scale
        // and the bus routing, which a fresh instance already has right).
        var carryKeys = #[\amp, \amp_slew, \cutoff, \cutoff_slew, \resonance,
            \pan, \pan_slew, \dry_send, \reverb_send, \delay_send, \granular_send];
        var old = oneShotInstances[slot];
        var oldPaths = oneShotPaths[slot];
        var pending = pendingOneShotParams[slot];
        var inst = OneShot.new(buffers, dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
        if (old.notNil) {
            this.carryVoiceParams(old, inst, carryKeys);
            old.free;
        };
        if (pending.notNil) {
            pending.keysValuesDo({ |k, v| inst.setParam('all', k, v) });
            pendingOneShotParams[slot] = nil;
        };
        oneShotInstances[slot] = inst;
        oneShotPaths[slot] = filePaths;
        // Release the old buffers only now that the new ones hold their refs,
        // so a file shared by old and new loads is never freed and re-read.
        if (oldPaths.notNil) { oldPaths.do({ |p| this.releaseBuffer(p) }) };
    }

    loadOneShot { arg slot, filePath;
        // Bump first: even a refused load cancels older loads still in flight.
        var gen = this.bumpGen(oneShotLoadGen, slot);
        if (this.sampleFileOk("OneShot", slot, filePath)) {
            this.loadOneShotPaths(slot, [filePath], filePath, gen);
        };
    }

    // pathList: newline-separated file paths. Lua builds the list (sorted,
    // filtered, within its memory budget), so Lua's sample count and order
    // are exactly what bufIdx indexes here.
    loadOneShotFiles { arg slot, pathList;
        var paths = pathList.split($\n).reject({ |p| p.isEmpty });
        if (paths.isEmpty) {
            this.clearOneShot(slot);
        } {
            this.loadOneShotPaths(slot, paths, paths.size.asString ++ " files",
                this.bumpGen(oneShotLoadGen, slot));
        };
    }

    clearOneShot { arg slot;
        var inst = oneShotInstances[slot];
        var paths = oneShotPaths[slot];
        this.bumpGen(oneShotLoadGen, slot);  // cancel any load still in flight
        if (inst.notNil) {
            inst.free;
            oneShotInstances[slot] = nil;
            pendingOneShotParams[slot] = nil;  // clear stale pending
            ("OneShot " ++ slot ++ " cleared").postln;
        };
        if (paths.notNil) { paths.do({ |p| this.releaseBuffer(p) }) };
        oneShotPaths[slot] = nil;
    }

    triggerOneShot { arg slot, voiceKey, rate = 1, bufIdx = 0, ampScale = 1.0;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.triggerWithRate(voiceKey, rate, bufIdx, ampScale);
        };
    }

    setOneShotParam { arg slot, paramKey, paramValue;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            // No instance yet — cache for when load happens
            if (pendingOneShotParams[slot].isNil) {
                pendingOneShotParams[slot] = Dictionary.new;
            };
            pendingOneShotParams[slot][paramKey] = paramValue;
        };
    }

    // -----------------------------------------------------------------
    // Panic helpers — hard-stop all in-flight notes per family without
    // freeing the instances (so future triggers still work).
    // -----------------------------------------------------------------

    silenceAllSamplers {
        samplerInstances.do({ |inst|
            if (inst.notNil) { inst.resetVoices };
        });
    }

    silenceAllOneShots {
        oneShotInstances.do({ |inst|
            if (inst.notNil) { inst.resetVoices };
        });
    }

    free {
        // Cancel in-flight sample loads so none installs onto freed buses.
        oneShotLoadGen.keys.do { |slot| this.bumpGen(oneShotLoadGen, slot) };
        samplerLoadGen.keys.do { |slot| this.bumpGen(samplerLoadGen, slot) };
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        sineInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        if (granularAllocated) { this.freeGranularChain };
        // Free cached sample buffers; without this, every script reload leaks
        // the buffers on the SC server (the Lied object dies, the Buffer
        // objects in the cache go out of scope, but their server-side
        // allocations persist until SC restart).
        bufferCache.do { |buf|
            if (buf.notNil and: { buf != \loading }) { buf.free };
        };
        delaySynth.free;
        reverbSynth.free;
        outSynth.free;
        outGroup.free;
        voiceGroup.free;
        fxGroup.free;
        dryBus.free;
        reverbBus.free;
        delayBus.free;
        granularBus.free;
        "Lied freed.".postln;
    }
}
