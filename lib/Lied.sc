// lib/Lied.sc — schicksalslied 2.0 SC kernel
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <granularBus;          // stereo bus voices route to when bus_routing = 'granular'
    var <granSendSynth;        // sums granularBus → micBus; lazy with granular chain
    var <voiceGroup, <fxGroup, <outGroup;
    var <delaySynth, <reverbSynth, <outSynth;
    var <beat_sec;                  // updated via setBeatSec from Lua
    var <triSinInstances;           // Dictionary: cell_id (Symbol) → TriSin instance
    var <ringerInstances;           // Dictionary: cell_id (Symbol) → Ringer instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance
    var <bufferCache;               // Dictionary: filePath (String) → Buffer
    var <bufferRefCounts;           // Dictionary: filePath → Integer (# slots using it)
    var <samplerPaths;              // Dictionary: slot (Integer) → filePath (for refcount maintenance)
    var <oneShotPaths;              // Dictionary: slot → filePath
    var <pendingTriSinParams;  // Dictionary: cellId (Symbol) → Dictionary(paramKey → value)
    var <pendingRingerParams;
    var <pendingSamplerParams; // Dictionary: slot (Integer) → Dictionary
    var <pendingOneShotParams;

    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <micDrySynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
    var <grainSynths;
    var <grainPanLFOs, <grainCutoffLFOs, <grainResLFOs;
    var <grainRates, <grainDurs, <grainDelays;
    var <grainPanRates, <grainCutoffRates, <grainResRates;
    var <granularAllocated;

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
        bufferCache      = Dictionary.new;
        bufferRefCounts  = Dictionary.new;
        samplerPaths     = Dictionary.new;
        oneShotPaths     = Dictionary.new;
        pendingTriSinParams  = Dictionary.new;
        pendingRingerParams  = Dictionary.new;
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

        // Voice → granular bus → micBus send. Sums stereo voice signal to
        // mono with 0.5 gain so the grain chain processes voice audio along
        // with the mic input. Only audible when granular chain is allocated.
        SynthDef(\liedGranSend, {
            arg in = 0, out = 0;
            var sig = In.ar(in, 2);
            var mono = (sig[0] + sig[1]) * 0.5;
            Out.ar(out, mono);
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

        granularAllocated = false;
        grainPanRates    = Array.fill(8, { rrand(1, 64) });
        grainCutoffRates = Array.fill(8, { rrand(1, 64) });
        grainResRates    = Array.fill(8, { rrand(1, 64) });

        "Lied initialized.".postln;
    }

    setBeatSec { arg newBeatSec;
        beat_sec = newBeatSec;
        ("Lied: beat_sec = " ++ beat_sec).postln;
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
    // Called the first time any of mic_amp / mic_dry_amp / granular_out_amp
    // is set to a non-zero value. Allocates the delay buffer, mic chain,
    // recorder, fbPatchMix, and 8 grain synths (reduced from 16 for CPU).
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
        "Lied: allocating granular chain (8 grains)...".postln;

        fork {
            // Buffer + buses
            delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1);
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
            micDrySynth     = Synth(\liedMicDry,     [\in, 0, \out, dryBus, \amp, 0],     micGrp);
            fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
            // Voice→granular send (reads granularBus, writes to micBus).
            // Lives in micGrp so it runs at the head of the chain.
            granSendSynth = Synth(\liedGranSend, [\in, granularBus, \out, micBus], micGrp);
            ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus],      ptrGrp);
            recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf], recGrp);

            // Grain LFOs (8 each)
            grainPanLFOs    = Array.fill(8, { 0 });
            grainCutoffLFOs = Array.fill(8, { 0 });
            grainResLFOs    = Array.fill(8, { 0 });
            8.do({ arg i;
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

            // Scrambled per-grain rates/durations/delays (8 grains)
            grainRates  = [1/4, 1/2, 1, 3/2, 2].scramble;
            grainDurs   = 8.collect({ arg i; beat_sec * (i + 1); }).scramble;
            grainDelays = 8.collect({ arg i; server.sampleRate * (beat_sec * (i + 1)) * 16; }).scramble;

            grainSynths = 8.collect({ arg n;
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
        delayBuf.free;
        micBus.free;
        ptrBus.free;

        grainSynths = nil;
        grainPanLFOs = nil;
        grainCutoffLFOs = nil;
        grainResLFOs = nil;
        micSynth = nil;
        micDrySynth = nil;
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

        granularAllocated = false;
    }

    setMicAmp { arg amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated) { micSynth.set(\amp, amp) };
    }

    setMicDryAmp { arg amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated) { micDrySynth.set(\amp, amp) };
    }

    setGranularOutAmp { arg amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated) { granGrp.set(\amp, amp) };
    }

    setFbPatchAmp { arg amp;
        if (granularAllocated) { fbPatchMixSynth.set(\amp, amp) };
    }

    setFbPatchBalance { arg balance;
        if (granularAllocated) { fbPatchMixSynth.set(\balance, balance) };
    }

    setFbPatchHpFreq { arg freq;
        if (granularAllocated) { fbPatchMixSynth.set(\hpFreq, freq) };
    }

    setFbPatchNoiseLevel { arg lvl;
        if (granularAllocated) { fbPatchMixSynth.set(\noiseLevel, lvl) };
    }

    setFbPatchSineLevel { arg lvl;
        if (granularAllocated) { fbPatchMixSynth.set(\sineLevel, lvl) };
    }

    setFbPatchSineHz { arg hz;
        if (granularAllocated) { fbPatchMixSynth.set(\sineHz, hz) };
    }

    setGrainPanRate { arg grainIdx, rate;
        grainPanRates[grainIdx] = rate;
        if (granularAllocated and: { grainPanLFOs[grainIdx].notNil }) {
            grainPanLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainCutoffRate { arg grainIdx, rate;
        grainCutoffRates[grainIdx] = rate;
        if (granularAllocated and: { grainCutoffLFOs[grainIdx].notNil }) {
            grainCutoffLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainResRate { arg grainIdx, rate;
        grainResRates[grainIdx] = rate;
        if (granularAllocated and: { grainResLFOs[grainIdx].notNil }) {
            grainResLFOs[grainIdx].set(\rate, rate);
        };
    }

    // -----------------------------------------------------------------
    // TriSin instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocTriSin { arg cellId;
        var pending;
        if (triSinInstances[cellId].isNil) {
            triSinInstances[cellId] = TriSin.new;
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

    rerouteTriSin { arg cellId, busVal;
        var inst = triSinInstances[cellId];
        if (inst.notNil) { inst.reroute(busVal); }
    }

    // -----------------------------------------------------------------
    // Ringer instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocRinger { arg cellId;
        var pending;
        if (ringerInstances[cellId].isNil) {
            ringerInstances[cellId] = Ringer.new;
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

    rerouteRinger { arg cellId, busVal;
        var inst = ringerInstances[cellId];
        if (inst.notNil) { inst.reroute(busVal); }
    }

    // -----------------------------------------------------------------
    // Sampler instance lifecycle (per row-4/6 slot, 1-16)
    // -----------------------------------------------------------------

    loadSampler { arg slot, filePath;
        fork {
            var sf, duration, buf, pending;
            var maxSec = 600;  // 10-minute max per unique buffer (~230 MB stereo @ 48k);
                                // dedup means N slots referencing same file = 1 buffer cost.
            sf = SoundFile.openRead(filePath);
            if (sf.isNil) {
                ("Sampler " ++ slot ++ " load failed: cannot open " ++ filePath).postln;
            } {
                duration = sf.numFrames / sf.sampleRate;
                sf.close;
                if (duration > maxSec) {
                    ("Sampler " ++ slot ++ " load REFUSED: "
                        ++ duration.round(0.1) ++ "s exceeds "
                        ++ maxSec ++ "s max (would exhaust Norns RAM).").postln;
                } {
                    // Clear existing slot first (handles refcount for previous file)
                    if (samplerInstances[slot].notNil) {
                        this.clearSampler(slot);
                    };
                    // Reuse cached buffer if this path is already loaded
                    buf = bufferCache[filePath];
                    if (buf.notNil) {
                        bufferRefCounts[filePath] = bufferRefCounts[filePath] + 1;
                        ("Sampler " ++ slot ++ " reusing cached buffer: " ++ filePath
                            ++ " (refs=" ++ bufferRefCounts[filePath] ++ ")").postln;
                    } {
                        buf = Buffer.read(server, filePath);
                        server.sync;
                        bufferCache[filePath] = buf;
                        bufferRefCounts[filePath] = 1;
                        ("Sampler " ++ slot ++ " loaded new buffer: " ++ filePath
                            ++ " (" ++ duration.round(0.1) ++ "s)").postln;
                    };
                    samplerInstances[slot] = Sampler.new(buf);
                    // Apply pending params if any were set before load
                    pending = pendingSamplerParams[slot];
                    if (pending.notNil) {
                        pending.keysValuesDo({ |k, v|
                            samplerInstances[slot].setParam('all', k, v);
                        });
                        pendingSamplerParams[slot] = nil;
                        ("Sampler " ++ slot ++ " loaded"
                            ++ " (applied " ++ pending.size ++ " pending params)").postln;
                    };
                    samplerPaths[slot] = filePath;
                };
            };
        };
    }

    clearSampler { arg slot;
        var inst = samplerInstances[slot];
        var path = samplerPaths[slot];
        if (inst.notNil) {
            inst.free;
            samplerInstances[slot] = nil;
            pendingSamplerParams[slot] = nil;  // clear stale pending
            // Decrement buffer refcount; free buffer when no slot references it
            if (path.notNil) {
                bufferRefCounts[path] = bufferRefCounts[path] - 1;
                if (bufferRefCounts[path] <= 0) {
                    bufferCache[path].free;
                    bufferCache[path] = nil;
                    bufferRefCounts[path] = nil;
                    ("Buffer freed: " ++ path).postln;
                };
                samplerPaths[slot] = nil;
            };
            ("Sampler " ++ slot ++ " cleared").postln;
        };
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

    rerouteSampler { arg slot, busVal;
        var inst = samplerInstances[slot];
        if (inst.notNil) { inst.reroute(busVal); }
    }

    // -----------------------------------------------------------------
    // OneShot instance lifecycle (per row-8 slot, 1-13)
    // -----------------------------------------------------------------

    loadOneShot { arg slot, filePath;
        fork {
            var sf, duration, buf, pending;
            var maxSec = 600;  // 10-minute max per unique buffer (~230 MB stereo @ 48k);
                                // dedup means N slots referencing same file = 1 buffer cost.
            sf = SoundFile.openRead(filePath);
            if (sf.isNil) {
                ("OneShot " ++ slot ++ " load failed: cannot open " ++ filePath).postln;
            } {
                duration = sf.numFrames / sf.sampleRate;
                sf.close;
                if (duration > maxSec) {
                    ("OneShot " ++ slot ++ " load REFUSED: "
                        ++ duration.round(0.1) ++ "s exceeds "
                        ++ maxSec ++ "s max (would exhaust Norns RAM).").postln;
                } {
                    if (oneShotInstances[slot].notNil) {
                        this.clearOneShot(slot);
                    };
                    buf = bufferCache[filePath];
                    if (buf.notNil) {
                        bufferRefCounts[filePath] = bufferRefCounts[filePath] + 1;
                        ("OneShot " ++ slot ++ " reusing cached buffer: " ++ filePath
                            ++ " (refs=" ++ bufferRefCounts[filePath] ++ ")").postln;
                    } {
                        buf = Buffer.read(server, filePath);
                        server.sync;
                        bufferCache[filePath] = buf;
                        bufferRefCounts[filePath] = 1;
                        ("OneShot " ++ slot ++ " loaded new buffer: " ++ filePath
                            ++ " (" ++ duration.round(0.1) ++ "s)").postln;
                    };
                    oneShotInstances[slot] = OneShot.new(buf);
                    // Apply pending params if any were set before load
                    pending = pendingOneShotParams[slot];
                    if (pending.notNil) {
                        pending.keysValuesDo({ |k, v|
                            oneShotInstances[slot].setParam('all', k, v);
                        });
                        pendingOneShotParams[slot] = nil;
                        ("OneShot " ++ slot ++ " loaded"
                            ++ " (applied " ++ pending.size ++ " pending params)").postln;
                    };
                    oneShotPaths[slot] = filePath;
                };
            };
        };
    }

    clearOneShot { arg slot;
        var inst = oneShotInstances[slot];
        var path = oneShotPaths[slot];
        if (inst.notNil) {
            inst.free;
            oneShotInstances[slot] = nil;
            pendingOneShotParams[slot] = nil;  // clear stale pending
            if (path.notNil) {
                bufferRefCounts[path] = bufferRefCounts[path] - 1;
                if (bufferRefCounts[path] <= 0) {
                    bufferCache[path].free;
                    bufferCache[path] = nil;
                    bufferRefCounts[path] = nil;
                    ("Buffer freed: " ++ path).postln;
                };
                oneShotPaths[slot] = nil;
            };
            ("OneShot " ++ slot ++ " cleared").postln;
        };
    }

    triggerOneShot { arg slot, voiceKey, rate;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.triggerWithRate(voiceKey, rate);
        }
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

    rerouteOneShot { arg slot, busVal;
        var inst = oneShotInstances[slot];
        if (inst.notNil) { inst.reroute(busVal); }
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
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        if (granularAllocated) { this.freeGranularChain };
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
