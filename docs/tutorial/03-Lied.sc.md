# Chapter 03 — `lib/Lied.sc`

The SC kernel that owns all DSP for schicksalslied 2.0. **925 source lines** — the largest SC file in the project, and the most architecturally dense.

If you've worked through chapters 01-02 you have everything you need to start. We'll build this file top-to-bottom: class skeleton, then the four-bus + three-group audio architecture, then the master FX SynthDefs, then the granular chain (lazily allocated when first needed), then voice instance management for the four voice classes. By the end of the chapter your class compiles, instantiates, and routes audio cleanly — but it won't yet be reachable from Norns (that's the next chapter's job).

Open a fresh `lib/Lied.sc` in your editor, and keep SC IDE open with the post window visible. After each major section you can recompile the class library (`Cmd-Shift-L` on Mac, `Ctrl-Shift-L` elsewhere) and try the code interactively. No Norns needed for this chapter.

## The class skeleton

We start with the absolute minimum:

```supercollider
// lib/Lied.sc — schicksalslied 2.0 SC kernel
Lied {
```

A header comment naming the file's purpose. The class declaration opens with `Lied {` — no parent specified, so SC implicitly extends `Object`. No `: ParentClass` syntax means "extends Object". This is deliberate: `Lied` doesn't inherit from `CroneEngine` because **`Lied` is the kernel, not the engine wrapper**. The Crone wrapper (`Engine_Lied`, chapter 04) extends `CroneEngine`; it wraps an instance of `Lied`. Keeping the kernel free of Crone gives us a class that can be tested standalone in SC IDE and could, in principle, be wrapped for a different runtime entirely.

## The instance variables

```supercollider
    classvar <grainCount = 4;  // Number of grain synths. 4 = lower CPU; 8 = original Carter's character.
```

**Line 3**: a class variable (shared across all instances) holding the number of grain synths in the granular chain. The `<` prefix generates a public getter, so `Lied.grainCount` works. The default is 4 (chosen to keep Norns CPU comfortable); 8 was the original Carter's-Delay character but doubles the per-block DSP cost.

```supercollider
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <granularBus;          // stereo bus voices route to when bus_routing = 'granular'
```

**Lines 4-6**: server reference + the four audio buses. Each `<` makes the variable publicly readable from outside. `granularBus` has a comment because it's the most likely one to need explanation: it's stereo (like the other three), but voices write to it conditionally — only if their granular_send is non-zero.

```supercollider
    var <granSendSynth;        // sums granularBus → micBus; lazy with granular chain
```

**Line 7**: the SC Synth that mixes the granular bus into the mic bus. Lazy — only exists when the granular chain is allocated.

```supercollider
    var <voiceGroup, <fxGroup, <outGroup;
    var <delaySynth, <reverbSynth, <outSynth;
```

**Lines 8-9**: the three execution-ordered groups (voices → FX → output) and the master FX synths.

```supercollider
    var <beat_sec;                  // updated via setBeatSec from Lua
```

**Line 10**: the current "duration of one beat in seconds" — updated by `setBeatSec` whenever Lua's clock_tempo changes. Used by the granular chain for buffer sizing (delay buffer is N × beat_sec seconds long).

```supercollider
    var <triSinInstances;           // Dictionary: cell_id (Symbol) → TriSin instance
    var <ringerInstances;           // Dictionary: cell_id (Symbol) → Ringer instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance
```

**Lines 11-14**: the four voice-instance dictionaries. TriSin and Ringer are keyed by cell IDs (`'1_2'`, `'5_2'`, etc.). Sampler and OneShot are keyed by integer slot numbers. The asymmetry reflects the conceptual model: row 2 voices belong to grid cells; samplers and one-shots belong to numbered slots.

```supercollider
    var <bufferCache;               // Dictionary: filePath (String) → Buffer
    var <bufferRefCounts;           // Dictionary: filePath → Integer (# slots using it)
    var <samplerPaths;              // Dictionary: slot (Integer) → filePath (for refcount maintenance)
    var <oneShotPaths;              // Dictionary: slot → filePath
```

**Lines 15-18**: buffer dedup state. `bufferCache` maps a file path to its loaded Buffer (or to the `\loading` sentinel during a load-in-progress). `bufferRefCounts` tracks how many sampler/one-shot slots reference each cached buffer. `samplerPaths` / `oneShotPaths` reverse-map each slot to the path it currently uses, so `clearSampler(N)` knows which path's refcount to decrement.

```supercollider
    var <pendingTriSinParams;  // Dictionary: cellId (Symbol) → Dictionary(paramKey → value)
    var <pendingRingerParams;
    var <pendingSamplerParams; // Dictionary: slot (Integer) → Dictionary
    var <pendingOneShotParams;
```

**Lines 19-22**: pending params for voices not yet allocated. The pattern is also referenced in chapter 13 (voice_params.lua) — when the Lua side sets a param via `engine.trisin_set_param("1_2", \amp, 0.3)` before `engine.trisin_alloc("1_2")` has run, the value is cached here. At alloc time, the cached values are applied to the new voice instance.

```supercollider
    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <micDrySynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
    var <grainSynths;
```

**Lines 24-28**: the granular chain's state. `delayBuf` is the long heap-allocated audio buffer (512 beats worth). `micBus` is where mic input + voice granular sends meet. `ptrBus` carries the write-head position. The four groups (`micGrp`, `ptrGrp`, `recGrp`, `granGrp`) enforce execution order in the granular chain. `grainSynths` is an array of `grainCount` SC Synths (4 in this build) that read grains from the delay buffer.

```supercollider
    var <grainPanLFOs, <grainCutoffLFOs, <grainResLFOs;
    var <grainRates, <grainDurs, <grainDelays;
    var <grainPanRates, <grainCutoffRates, <grainResRates;
```

**Lines 29-31**: per-grain modulation state. The LFOs are SC `Ndef` proxies (we'll see them constructed in `ensureGranularChain`). The "rates" arrays hold the period of each grain's pan/cutoff/res LFO; the rates can be changed at runtime via `setGrainPanRate`, etc.

```supercollider
    var <granularAllocated;
    var <grainDelayScale;  // multiplier for grain ptrSampleDelay (default 1.0)
```

**Lines 32-33**: the flag tracking whether the granular chain is alive, plus a global multiplier on per-grain lookback distances. Scale of 1.0 produces the Carter's Delay character (8-64 sec lookback at 120 BPM); lower values tighten the texture.

```supercollider
    // Pending granular setter values — applied at end of ensureGranularChain's
    // fork. Solves the "user toggles granular before chain is alive → setter's
    // .set fires on nil synth → amp stuck at 0" silent-grain bug.
    var <pendingMicAmp, <pendingMicDryAmp, <pendingGranularOutAmp;
    var <pendingFbAmp, <pendingFbBalance, <pendingFbHpFreq;
    var <pendingFbNoise, <pendingFbSineLevel, <pendingFbSineHz;
```

**Lines 34-39**: pending granular setter values. Same pattern as pending voice params: setters called before the granular chain is allocated cache their values; the alloc flow applies them once the synths exist. The comment names a specific bug class (silent grains on first toggle) this pattern prevents.

`★ Insight ─────────────────────────────────────`
**The instance-variable block is the API contract** — anyone reading `Lied.sc` should be able to skim lines 3-39 and understand the kernel's state shape. The variables-with-`<` form a discoverable surface: from sclang's REPL you can inspect any of these via `Crone.engine.kernel.<name>`. During development this is invaluable for diagnosing buffer/voice/group state.

**Why are there so many "pending" variables?** Because every Lua-side parameter has a corresponding pre-alloc safety net. Without these, the cumulative effect of "params:bang at init fires hundreds of actions, each calling engine.<setter>" would lose information for any voice/slot not yet allocated. The pending pattern preserves intent for later application.
`─────────────────────────────────────────────────`

## Constructor and initial state

```supercollider
    *new { arg server;
        ^super.new.init(server);
    }
```

**Lines 41-43**: standard SC class constructor. `*new` is the class method (note the `*`). Inside, `^super.new.init(server)` returns (via `^`) the result of `super.new` (Object's `new`, which allocates the instance) chained with `.init(server)` (our own initialization). This is the canonical SC constructor pattern.

```supercollider
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
```

**Lines 45-60**: the start of `init`. `server = inServer ? Server.default` uses `?` (SC's nil-coalescing) to default to the global default server if no server arg is given. `beat_sec = 0.5` defaults to 120 BPM (= 0.5 sec/beat).

The 12 `= Dictionary.new` calls construct empty dictionaries for every state table. These are mutable; subsequent code populates them via `dict[key] = value` writes.

The `.postln` is the first of many debug prints throughout the kernel. They're intentionally chatty during init so you can see exactly which step succeeded in the matron log.

## Audio buses and the execution-ordered group hierarchy

```supercollider
        // --- Audio buses ---
        // dryBus       = main output (mirrors naherinlied's ~fb)
        // reverbBus    = pre-reverb send (mirrors naherinlied's c)
        // delayBus     = pre-delay send  (mirrors naherinlied's b)
        dryBus    = Bus.audio(server, 2);
        reverbBus = Bus.audio(server, 2);
        delayBus  = Bus.audio(server, 2);
        granularBus = Bus.audio(server, 2);  // route voices into granular chain
```

**Lines 62-69**: allocate the four stereo audio buses on the server. The 2 in `Bus.audio(server, 2)` is the channel count.

The comments reference naherinlied (the sibling Seamstress port) — the bus structure is inherited from there. `~fb`, `c`, `b` were the variable names in naherinlied's `.scd` file; the renaming to `dryBus`/`reverbBus`/`delayBus` is more legible in class context.

```supercollider
        ("Lied buses: dryBus=" ++ dryBus.index ++ " reverbBus=" ++ reverbBus.index
            ++ " delayBus=" ++ delayBus.index ++ " granularBus=" ++ granularBus.index).postln;
```

**Lines 70-71**: a diagnostic print showing the actual bus indices. Useful for debugging when something writes to the wrong bus — you can see the mapping in the matron log.

```supercollider
        // --- Group hierarchy ---
        //   server default group
        //     └── voiceGroup (all voice instances will add to this; populated lazily later)
        //     └── fxGroup    (runs after voiceGroup, contains delay + reverb synths)
        voiceGroup = Group.new(server);
        fxGroup    = Group.after(voiceGroup);
```

**Lines 73-78**: create the voice and FX groups. `Group.new(server)` adds at the head of the default group. `Group.after(voiceGroup)` places `fxGroup` immediately after `voiceGroup` — so the server's execution order is `voiceGroup → fxGroup`. Voice synths (allocated later by individual voice classes) will populate `voiceGroup`; FX synths (allocated below) will populate `fxGroup`. (Note `outGroup` is created later after the FX synths are instantiated.)

## Master FX: defining the SynthDefs

```supercollider
        // --- SynthDefs: master FX ---
        // NOTE: norns-ritual wraps SynthDef definitions in `server.bind { ... }`,
        // but that pattern is unreliable in CLI-launched sclang (test.scd) — the
        // bundle mechanism races with `server.sync` and triggers "SynthDef X not
        // found" when the FX synth allocation immediately follows. Direct .add
        // calls + server.sync works reliably across both CLI and IDE contexts.
```

**Lines 80-85**: a note explaining why we use direct `.add` instead of `server.bind { ... }`. This is an empirical lesson from development: `server.bind` produces faster (bundled) SynthDef registration but has a race condition with the immediate `Synth.new` calls that follow. Direct `.add` + `server.sync` is slower but reliable. Worth knowing if you ever refactor this.

### `\liedDelay`

```supercollider
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
```

**Lines 87-104**: the delay synth. The comments explain two non-obvious choices:

- **`decayTime` arg naming**: CombL's fourth arg is the time for the comb to decay 60 dB, but it could be confused with a feedback amplitude. Naming it `decayTime` matches SC's convention.
- **`8.0` maxdelaytime**: chosen empirically after a 16-second value caused JackDriver alloc-fail (chapter 02 covers the real-time memory pool).

The synth: read stereo from `inBus`, comb-filter it, lag-smooth the amp, write to both `dryOut` and `reverbOut` at independently-modulatable send levels. This is the Y-shaped output that lets the delay route to dry, reverb, or both.

`★ Insight ─────────────────────────────────────`
**Two `.lag` granularities here**: `amp.lag(amp_slew)` uses the synth's `amp_slew` arg (default 0.1 sec); the send levels use a hardcoded `.lag(0.05)` (50 ms). The hardcoded send slews are short because send-level changes are usually small adjustments where a long slew would be sluggish; the amp slew is longer because amp changes are often large (mute / unmute) where a short slew would click.

**Order of operations in the `Out.ar` calls**: `del * ampSmoothed * send.lag(0.05)`. Multiplication is associative, so the order doesn't matter for the math, but the **lag insertion** does — by lagging the send level (which is what the user sweeps) separately from the amp (which is what the engine slews), we get smooth send sweeps independent of any amp transitions happening simultaneously.
`─────────────────────────────────────────────────`

### `\liedReverb`

```supercollider
        // Reverb reads reverbBus → output to dryBus
        SynthDef(\liedReverb, {
            arg inBus, dryOut, room = 0.5, damp = 0.5,
                amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            var rev = FreeVerb.ar(sig, 1.0, room, damp);
            Out.ar(dryOut, rev * amp.lag(amp_slew));
        }).add;
```

**Lines 106-113**: the reverb synth. Simpler than delay: read from `inBus`, apply `FreeVerb` (the Schroeder reverb UGen), lag-smooth the amp, write to dryOut.

`FreeVerb.ar(sig, mix, room, damp)`:
- `mix = 1.0` — fully wet (we want the reverb's tail, not the original signal — the original passes around the reverb via dryBus → outSynth).
- `room` — room size (0-1, larger = longer tail).
- `damp` — high-frequency damping (0-1, higher = darker tail).

### `\liedOut`

```supercollider
        // Pass dryBus through to main output (0)
        SynthDef(\liedOut, {
            arg inBus, amp = 1.0, amp_slew = 0.1;
            var sig = In.ar(inBus, 2);
            Out.ar(0, sig * amp.lag(amp_slew));
        }).add;
```

**Lines 115-120**: the master output synth. The simplest possible — read dryBus, multiply by amp, write to physical out (bus 0). This is the very last stage in the audio path. All output level changes happen here.

## The granular chain's SynthDefs (defined now, instantiated lazily)

The granular chain has seven SynthDefs. They're defined here so they're registered with the server at init time, but they're only instantiated lazily (in `ensureGranularChain`). Defining them eagerly is cheap (just registering the graph definition); instantiating them is expensive (actual server-side nodes).

### `\liedMic`

```supercollider
        // -----------------------------------------------------------------
        // GRANULAR DELAY CHAIN — ported from carters-delay-norns
        // -----------------------------------------------------------------

        // Mic input → micBus (mic feeds the delay buffer)
        SynthDef(\liedMic, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05;
            var sig = SoundIn.ar(in) * amp.lag3(amp_slew);
            Out.ar(out, sig);
        }).add;
```

**Lines 122-131**: the mic input synth. `SoundIn.ar(in)` reads from physical input (in = 0 → mic input). Scale by amp (defaulting to 0 — silent until user enables mic). Write to `out` (typically micBus).

The `amp.lag3(amp_slew)` uses `.lag3` (third-order lag, cubic) instead of `.lag` (first-order) — `.lag3` gives a smoother ramp, important for amp transitions that the user can hear.

### `\liedMicDry`

```supercollider
        // Mic dry passthrough → main output bus (naherinlied feature, not in
        // carters-delay-norns standalone)
        SynthDef(\liedMicDry, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05;
            var sig = SoundIn.ar(in) * amp.lag3(amp_slew);
            Out.ar(out, [sig, sig]);
        }).add;
```

**Lines 133-139**: a mic passthrough to the main output. Distinct from `liedMic`: this synth writes to `dryBus` (not `micBus`), and it writes as a stereo array `[sig, sig]` (duplicating mono to both channels). This is what lets the user route their mic input through the script without going through the granular chain.

The comment notes this is a naherinlied feature, not in the original Carter's Delay design.

### `\liedPtr`

```supercollider
        // Pointer (write head) — advances through the delay buffer
        SynthDef(\liedPtr, {
            arg out = 0, buf = 0, rate = 1;
            var sig = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, BufFrames.kr(buf));
            Out.ar(out, sig);
        }).add;
```

**Lines 141-146**: the write-head pointer. `Phasor.ar(trig, rate, start, end)` produces a continuously-advancing index from 0 to `BufFrames.kr(buf)`, wrapping. Writing this index to `ptrBus` makes it available to the recorder + grain synths.

`BufRateScale.kr(buf) * rate` is the advancement rate: BufRateScale returns the sample-rate adjustment factor (so the pointer advances 1 sample per audio frame regardless of the buffer's stored sample rate); `rate` is a user-modifiable speed factor (typically 1, but could be set to slow down or speed up the write head).

### `\liedRec`

```supercollider
        // Recorder — writes (micBus + preLevel * existing buffer) to delay buffer
        SynthDef(\liedRec, {
            arg ptrIn = 0, micIn = 0, buf = 0, preLevel = 0;
            var ptr = In.ar(ptrIn, 1);
            var sig = In.ar(micIn, 1);
            sig = sig + (BufRd.ar(1, buf, ptr) * preLevel);
            BufWr.ar(sig, buf, ptr);
        }).add;
```

**Lines 148-155**: the recorder. Read the current pointer position, read the mic signal, mix in `preLevel` times the existing buffer content at the same position, write the result back to the buffer at the pointer.

The `preLevel` parameter (defaulting to 0) controls feedback within the buffer. At 0, each write overwrites old content. At 1, each write sums new audio with old, producing accumulating layered material. The script doesn't currently expose preLevel as a user-controllable param (default is fixed at 0), but the SynthDef supports it for future expansion.

`BufRd.ar(1, buf, ptr)` reads 1 channel from `buf` at the `ptr` position. `BufWr.ar(sig, buf, ptr)` writes `sig` to `buf` at the `ptr` position.

### `\liedFbPatchMix`

```supercollider
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
```

**Lines 157-170**: the feedback patch. This is the wildest UGen graph in the script. It reads the main output (bus 0) via `InFeedback.ar` (which allows reading buses that are processed later in the same block — the regular `In.ar` requires the writer to come first; `InFeedback.ar` accepts one-block latency in exchange for backward-reading capability). Then:

1. **`Balance2.ar(L, R, balance)`** — pans/balances the stereo input to mono with adjustable L/R bias. `balance = 0` is centered; ±1 fully L or R.
2. **Add pink noise** scaled by `noiseLevel` — for sound-design exploration.
3. **Add a sine** at `sineHz` scaled by `sineLevel` — for hum injection.
4. **HPF** — remove DC and very low frequencies (high-pass at `hpFreq`, default 12 Hz).
5. **`softclip`** — saturate, preventing runaway feedback explosions.
6. Scale by amp and write to `out` (typically micBus, completing the feedback loop).

The end result: turn up the amp and the granular chain self-modulates with the softclipped, optionally-noise-and-sine-injected main output feeding back into the mic bus.

`★ Insight ─────────────────────────────────────`
**`InFeedback.ar` is the key to making this work**. Reading bus 0 (the main output) while writing to it would normally produce a one-block-delayed read with `In.ar`, but only if the source node executes before the destination — here, the feedback patch (in `micGrp`) executes BEFORE `outSynth` (in `outGroup`), so a regular `In.ar` would read silence. `InFeedback.ar` explicitly handles this case, reading the previous block's value.

**`softclip` is essential** for any feedback loop. Without it, even small amp values can produce explosive feedback — once a transient gets amplified, each pass through the loop amplifies it further until DAC clipping (which is harsh) or NaN propagation (which is silent but corrupts state). `softclip` is a smooth tanh-like saturation that bounds the signal in [-1, 1] without harsh clipping artifacts.
`─────────────────────────────────────────────────`

### `\liedGran`

```supercollider
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
```

**Lines 172-214**: the grain reader, the heart of the granular chain. This deserves a careful walk:

- **`env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2)`** — an ASR envelope. The synth lives until the envelope hits 0 (gate goes low and release completes), then frees itself.
- **`densCtrl = Select.ar(sync, [Dust.ar(dens), Impulse.ar(dens)])`** — grain density. `sync` arg selects between `Dust.ar(dens)` (random Poisson-distributed pulses, asynchronous) and `Impulse.ar(dens)` (regular pulses, synchronous). Default `sync = 1` means use Impulse.
- **`durCtrl = baseDur * LFNoise1.ar(100).exprange(1 / durRand, durRand)`** — grain duration with random variation. `LFNoise1.ar(100)` is a 100 Hz random walk; `.exprange(min, max)` maps it exponentially to `[1/durRand, durRand]`. Multiplying `baseDur` by this produces a duration that varies exponentially around `baseDur`.
- **`rateCtrl = rate.lag3(0.5) * LFNoise1.ar(100).exprange(...)`** — playback rate with random variation. Same pattern but with `.lag3(0.5)` smoothing on the central rate (so user rate changes don't click).
- **`panCtrl = pan + LFNoise1.kr(100).bipolar(panRand)`** — stereo pan with random variation. `bipolar(panRand)` maps the random walk to `[-panRand, +panRand]`.
- **`ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples)`** — random offset (in samples) added to the lookback distance, producing position variation between grains.
- **`totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay)`** — the actual lookback distance for THIS grain at THIS moment. Clamped to a minimum to prevent reading too close to the write head.
- **`ptr = In.ar(ptrBus, 1); ptr = ptr - totalDelay; ptr = ptr / BufFrames.kr(buf)`** — read the write-head position, back it up by `totalDelay`, normalize to 0-1 (GrainBuf expects normalized positions).
- **`maxGrainDur = (totalDelay / rateCtrl) / SampleRate.ir; durCtrl = min(durCtrl, maxGrainDur)`** — cap the grain duration so the grain doesn't outrun the write head. If a grain plays for longer than `totalDelay / rateCtrl` seconds, it would catch up to the write head and play data that hasn't been written yet (or is currently being overwritten). The cap prevents this.
- **`GrainBuf.ar(2, densCtrl, durCtrl, buf, rateCtrl, ptr, 4, panCtrl, grainEnv)`** — the actual grain reader. 2-channel output, density trigger, duration, buffer, rate, position, interpolation (4 = cubic), pan, env (-1 = use default Hanning window).
- **`MoogFF.ar(...)`** — apply a resonant lowpass filter to the grain output. `cutoff` and `resonance` are user-controllable.
- **`Out.ar(out, sig)`** — write the filtered grains to `out` (typically dryBus).

`★ Insight ─────────────────────────────────────`
**`GrainBuf` does the heavy lifting**: it's a built-in SC UGen that handles grain envelope shaping, scheduling, and reading from a buffer at randomized positions. Without `GrainBuf` we'd need to manually trigger individual grain players and overlap their envelopes, which would be much harder to write and likely slower. Always reach for the built-in granular UGens (GrainBuf, GrainIn, GrainSin, GrainFM) before rolling your own.

**The `LFNoise1.ar(100).exprange(...)` pattern** for randomized parameters is canonical for granular synthesis. `LFNoise1` is "low-frequency noise with linear interpolation" — at 100 Hz it produces a smoothly-varying random signal. `exprange` maps it to the desired range with exponential bias (so values cluster near the geometric mean). The combination produces natural-feeling parameter motion that doesn't sound robotic.
`─────────────────────────────────────────────────`

### `\liedGranSend`

```supercollider
        // Voice → granular bus → micBus send. Sums stereo voice signal to
        // mono with 0.5 gain so the grain chain processes voice audio along
        // with the mic input. Only audible when granular chain is allocated.
        SynthDef(\liedGranSend, {
            arg in = 0, out = 0;
            var sig = In.ar(in, 2);
            var mono = (sig[0] + sig[1]) * 0.5;
            Out.ar(out, mono);
        }).add;
```

**Lines 216-224**: a small mixer that sums the stereo granular send bus to mono with 0.5 gain, then writes the mono result to micBus (where the granular chain reads it). This is what lets voices route into the granular chain via their `granular_send` send level: any voice's granular_send writes to granularBus; `liedGranSend` mixes granularBus → micBus.

The 0.5 gain is the mono-mix normalization (so a stereo signal of (L=1, R=1) becomes mono signal 1.0, not 2.0).

## Instantiating the master FX (where order matters)

```supercollider
        server.sync;
```

**Line 226**: barrier. Wait for the server to finish registering all the SynthDefs above before we try to instantiate them. (This used to be a `server.bind` block, but as the comment in section 5 explained, that had race conditions.)

```supercollider
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
```

**Lines 228-244**: the FX instantiation. This is the section that contains the order-dependent bug we hit (covered in chapter 02 and 03). The comment preserves the explanation: **instantiating reverb first then delay produces order: delay, reverb** because `\addToHead` (the default) pushes each new synth in front of the previous one.

`Synth.new(synthdef_name, args_array, group, addAction)`:
- The args array is alternating `\key, value` pairs.
- The group is `fxGroup` for the FX synths, `outGroup` for the output synth.
- The addAction defaults to `\addToHead` (not specified here).

After this block, the execution order in fxGroup is `[delaySynth, reverbSynth]`, and outGroup contains `[outSynth]`. The server's overall order: voiceGroup (empty for now) → delaySynth → reverbSynth → outSynth.

## Final init state

```supercollider
        granularAllocated = false;
        grainPanRates    = Array.fill(grainCount, { rrand(1, 64) });
        grainCutoffRates = Array.fill(grainCount, { rrand(1, 64) });
        grainResRates    = Array.fill(grainCount, { rrand(1, 64) });
        grainDelayScale  = 1.0;

        "Lied initialized.".postln;
    }
```

**Lines 246-253**: initial state for the granular chain (not yet allocated).

- **`granularAllocated = false`** — the lazy-alloc flag.
- **`grainPanRates / grainCutoffRates / grainResRates`** — arrays of `grainCount` random integers in `[1, 64]`. `Array.fill(n, { block })` calls the block n times to construct an array. `rrand(1, 64)` is "random ranged integer in [1, 64]". These are the **periods** of each grain's pan/cutoff/res LFO; randomizing them gives each grain its own slowly-evolving modulation profile.
- **`grainDelayScale = 1.0`** — the default scale for lookback distances.

The closing brace ends `init`.

## The simple setter methods

```supercollider
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
```

**Lines 255-264**: `setBeatSec` stores the new beat duration. The early-exit-if-unchanged guard is debug-noise control: as the comment explains, the Lua side fires this multiple times per encoder tick and we don't want to spam the log.

Note: `setBeatSec` only stores the value — it doesn't resize the granular delay buffer or anything. Resizing would require a full chain teardown + reallocation. The current design: changing tempo doesn't affect the running granular chain's character; the buffer is the size it was when the chain was allocated. To get a different-size buffer, the user must trigger `freeGranularChain` and re-engage granular (panic + re-toggle).

```supercollider
    setOutAmp { arg amp;
        outSynth.set(\amp, amp);
    }
```

**Lines 266-268**: the master output gain. One-liner: `.set` on the output synth.

```supercollider
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
```

**Lines 270-288**: five identical-shape setters for the delay synth's parameters. Each is a one-liner that does `.set` on `delaySynth`. The CombL's smoothing (lag) handles the actual ramping; the setter just notifies SC of the target value.

```supercollider
    // Scale the grain ptrSampleDelay for all grains.
    // Stored value takes effect on NEXT granular chain allocation (re-engage
    // granular toggles after setting). To make it effective on an already-
    // running chain, panic + re-engage.
    setGrainDelayScale { arg scale;
        grainDelayScale = scale;
        ("Lied: grainDelayScale = " ++ scale
            ++ " (effective on next granular allocation)").postln;
    }
```

**Lines 290-298**: `setGrainDelayScale` stores the new scale but does NOT apply it to a running granular chain. The comment explains why: the grain lookback distances are baked into the grain synths at instantiation time; changing them on a running synth would require killing each grain synth and respawning with new args. The lazy approach (apply on next alloc) is simpler; the user triggers it by panicking + re-engaging.

```supercollider
    setReverbRoom { arg room;
        reverbSynth.set(\room, room);
    }

    setReverbDamp { arg damp;
        reverbSynth.set(\damp, damp);
    }

    setReverbAmp { arg amp;
        reverbSynth.set(\amp, amp);
    }
```

**Lines 300-310**: three reverb setters, same pattern as the delay setters.

## Lazy allocation of the granular chain

This is the most complex method in the file. It's an idempotent constructor for the granular chain: the first call allocates everything; subsequent calls do nothing.

```supercollider
    // -----------------------------------------------------------------
    // Lazy granular chain allocation
    // -----------------------------------------------------------------
    // Called the first time any of mic_amp / mic_dry_amp / granular_out_amp
    // is set to a non-zero value. Allocates the delay buffer, mic chain,
    // recorder, fbPatchMix, and grainCount grain synths.
    // Idempotent — subsequent calls are no-ops once granularAllocated.

    ensureGranularChain {
        if (granularAllocated) { ^this };
```

**Lines 312-321**: header comment + the early return. `^this` returns `this` (SC's equivalent of "self") if already allocated — a no-op return for the idempotent case.

```supercollider
        // Set flag BEFORE forking to gate re-entry on rapid double-press.
        // There's a brief window (~one server.sync round-trip, ~5-20ms) where
        // granularAllocated is true but the synths aren't yet allocated. The
        // amp setters that depend on these check granularAllocated, so they
        // will attempt micSynth.set(...) etc. and silently no-op for the
        // window where micSynth is still nil. Acceptable trade-off vs the
        // alternative of double-allocation.
        granularAllocated = true;
        ("Lied: allocating granular chain (" ++ grainCount ++ " grains)...").postln;
```

**Lines 322-330**: the flag set + log. The comment explains a subtle race-condition tradeoff: we set the flag BEFORE the fork starts so that a quick second call returns immediately (no double-allocation), but this means there's a window where the flag is true and the synths are still nil. The amp setters handle this with `granularAllocated and: { micSynth.notNil }` guards. The trade-off (silent setter no-ops vs. potential double-allocation) is the right one for this script's behavior.

```supercollider
        fork {
            // Buffer + buses
            delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1);
            micBus = Bus.audio(server, 1);
            ptrBus = Bus.audio(server, 1);

            server.sync;
```

**Lines 332-338**: the fork begins. `delayBuf = Buffer.alloc(server, ...)` allocates the long heap-based delay buffer. The size is `sampleRate × (beat_sec × 512)` — 512 beats of audio. At 120 BPM (beat_sec = 0.5), that's 256 seconds = ~12 MB stereo float. At 60 BPM, 256 sec; at 240 BPM, 64 sec. The buffer scales with the current tempo at alloc time.

Note this is heap memory (via `Buffer.alloc`), not the real-time pool. This is what lets the script have a many-MB granular buffer without running into the same memory issue the delay's CombL does.

`micBus` and `ptrBus` are 1-channel (mono). `server.sync` waits for the buffer allocation to complete before proceeding.

```supercollider
            // Group hierarchy: mic → ptr → rec → gran, before voiceGroup
            micGrp  = Group.before(voiceGroup);
            ptrGrp  = Group.after(micGrp);
            recGrp  = Group.after(ptrGrp);
            granGrp = Group.after(recGrp);
```

**Lines 340-344**: four groups in execution order. `Group.before(voiceGroup)` places `micGrp` immediately before `voiceGroup`. Then each subsequent group goes after the previous. Final order: `micGrp → ptrGrp → recGrp → granGrp → voiceGroup → fxGroup → outGroup`. The granular chain runs first (so by the time voices fire, the chain's state is already updated for this block).

```supercollider
            // Persistent chain synths (default amp = 0)
            micSynth        = Synth(\liedMic,        [\in, 0, \out, micBus, \amp, 0],     micGrp);
            micDrySynth     = Synth(\liedMicDry,     [\in, 0, \out, dryBus, \amp, 0],     micGrp);
            fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
            // Voice→granular send (reads granularBus, writes to micBus).
            // Lives in micGrp so it runs at the head of the chain.
            granSendSynth = Synth(\liedGranSend, [\in, granularBus, \out, micBus], micGrp);
            ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus],      ptrGrp);
            recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf], recGrp);
```

**Lines 346-354**: instantiate the persistent chain synths. Walking each:

- **`micSynth`** in `micGrp`, reads physical input 0, writes to micBus, default amp 0.
- **`micDrySynth`** in `micGrp`, reads physical input 0, writes to dryBus, default amp 0.
- **`fbPatchMixSynth`** in `micGrp` with `\addToHead` — placed at the very head of micGrp, ensures it reads bus 0 first (before any other writes to dryBus in this block can affect what InFeedback sees).
- **`granSendSynth`** in `micGrp`, reads granularBus, writes to micBus. No specific positioning required.
- **`ptrSynth`** in `ptrGrp`, writes the running phasor index to ptrBus.
- **`recSynth`** in `recGrp`, reads ptrBus + micBus, mixes them (with optional preLevel feedback), writes to delayBuf.

```supercollider
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
```

**Lines 356-379**: per-grain LFO creation via `Ndef`. `Ndef` is SC's "node-def" — a named proxy that produces an audio signal. Each `Ndef("grainPanN", { ... })` registers a named control-rate proxy that another synth can read by passing the Ndef as a value (via the Ndef's `.ar` or `.kr` accessor methods; `Ndef` defaults to control rate for `.kr`-shaped functions).

For each grain index `i`:
- **`grainPanLFOs[i] = Ndef('grainPanN', { |rate=8| LFTri.kr(1/(rate*beat_sec)).range(-1, 1) })`** — a triangle LFO with period `rate × beat_sec` seconds, scaled to range [-1, 1]. The `rate` arg defaults to 8 (beats); calling `.set(\rate, panRate)` updates it.
- Same pattern for cutoff (range 500-15000 Hz) and res (range 0-2).

These Ndefs run continuously after creation. When we instantiate the grain synths (below), we pass these Ndefs as values for the grain's `pan`, `cutoff`, `resonance` args — the grain synth reads the LFOs in real time, producing slowly-evolving per-grain modulation.

```supercollider
            // Wait for the Ndef proxies above to fully allocate on the
            // server before we map them into grain synths. Without this sync,
            // the grain synth creation can race ahead of the Ndefs, producing
            // a flood of "Node X not found" errors as /n_set targets nodes
            // the server hasn't created yet.
            server.sync;
```

**Lines 381-386**: critical `server.sync`. Each Ndef construction is async (sends a node allocation request to the server). Without the sync, the grain synth construction (next) would happen before the Ndefs are alive on the server, producing /n_set errors.

```supercollider
            // Scrambled per-grain rates/durations/delays (grainCount grains).
            // Grain delays are scaled by grainDelayScale (default 1.0):
            //   scale=1.0 → 8..64 sec range (Carter's Delay character)
            //   scale=0.1 → 0.8..6.4 sec range (more immediate response)
            grainRates  = [1/4, 1/2, 1, 3/2, 2].scramble;
            grainDurs   = grainCount.collect({ arg i; beat_sec * (i + 1); }).scramble;
            grainDelays = grainCount.collect({ arg i;
                server.sampleRate * (beat_sec * (i + 1)) * 16 * grainDelayScale;
            }).scramble;
```

**Lines 388-396**: per-grain parameter arrays. `.scramble` is SC's "shuffle an array randomly" method.

- **`grainRates = [1/4, 1/2, 1, 3/2, 2].scramble`** — 5 fixed rates, randomly ordered. The grain synths cycle through this array (modulo) to assign per-grain playback rates.
- **`grainDurs = grainCount.collect({ arg i; beat_sec * (i + 1) }).scramble`** — `grainCount` durations, each `beat_sec * (i + 1)`. For grainCount = 4: durations of 1, 2, 3, 4 beats (in seconds). Scrambled.
- **`grainDelays = grainCount.collect({ ... }).scramble`** — per-grain lookback distances. The formula `sampleRate × (beat_sec × (i + 1)) × 16` is "i+1 beats worth of samples times 16" — giving lookback distances of 16, 32, 48, 64 beats for i = 0..3. The `* grainDelayScale` lets the user shrink these.

```supercollider
            grainSynths = grainCount.collect({ arg n;
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
                    \ptrRandSamples, server.sampleRate * (beat_sec * ((n % grainCount) + 1)) * 2,
                    \minPtrDelay, grainDelays[n],
                    \cutoff, grainCutoffLFOs[n],
                    \resonance, grainResLFOs[n]
                ], granGrp);
            });
```

**Lines 398-422**: instantiate the grain synths. `grainCount.collect` runs the block N times and returns an array of the results.

Each grain synth gets its specific rate, duration, delay, and modulation Ndefs. The `n % 5` is because `grainRates` has 5 entries (for the 5 fixed rates) while grainCount could be anything (4 in this build). The `n % grainCount` for `ptrRandSamples` ensures the variation amount is bounded.

The `\pan, grainPanLFOs[n]` is the Ndef-passing idiom: when you pass an Ndef as an arg value, SC routes the Ndef's output into the synth's input for that arg.

```supercollider
            // Apply any pending setter values that were called BEFORE the
            // chain was fully allocated (the off-by-fork race). This is what
            // makes "toggle granular_out on" actually set granGrp's amp on the
            // first toggle instead of requiring an off-then-on workaround.
            if (pendingMicAmp.notNil)        { micSynth.set(\amp, pendingMicAmp); };
            if (pendingMicDryAmp.notNil)     { micDrySynth.set(\amp, pendingMicDryAmp); };
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
```

**Lines 424-440**: apply pending values from any setters called before the alloc completed. This is the granular chain's pending-params pattern. Each `if (pending*.notNil)` check fires `.set` on the appropriate synth.

The closing `};` ends the fork, then `}` ends the method.

`★ Insight ─────────────────────────────────────`
**The fork structure** is what makes lazy allocation work safely. Without it, `ensureGranularChain` would block the caller (the setter that triggered alloc) until the allocation completes — and inside a fork-free context, you can't use `server.sync`. The fork:

1. Sets the flag and returns control to the caller.
2. The caller (e.g., `setGranularOutAmp(0.5)`) tries `granGrp.set(\amp, 0.5)` — but `granGrp` is still nil at this moment.
3. The fork continues in background, allocates everything.
4. The fork's tail applies pending values, including the 0.5 that didn't reach granGrp earlier.

End result: the setter call appears to "just work" from the user's perspective, even though under the hood it was deferred to the alloc completion.
`─────────────────────────────────────────────────`

## Tearing the granular chain back down

```supercollider
    freeGranularChain {
        if (granularAllocated.not) { ^this };
        "Lied: freeing granular chain...".postln;

        grainPanLFOs.do({ arg lfo; lfo.free; });
        grainCutoffLFOs.do({ arg lfo; lfo.free; });
        grainResLFOs.do({ arg lfo; lfo.free; });
        granGrp.free;
        recGrp.free;
        ptrGrp.free;
        granSendSynth = nil;
        micGrp.free;
        delayBuf.free;
        micBus.free;
        ptrBus.free;
```

**Lines 446-460**: free each resource in reverse order. Ndefs first (the LFOs), then the four groups in reverse (granGrp, recGrp, ptrGrp, micGrp — micGrp last because it contained granSendSynth). Then the buffer and the two buses.

```supercollider
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
```

**Lines 462-477**: explicitly null out every reference. This is important for two reasons:
1. **Garbage collection**: holding stale references prevents Lua/SC's garbage collector from cleaning up. After free, the references are nil; the underlying server resources are already freed.
2. **Re-entrance**: future `setMicAmp` calls check `granularAllocated and: { micSynth.notNil }`. By nulling out `micSynth`, we ensure these checks correctly identify the chain as torn down.

```supercollider
        // Clear pending values so a future ensureGranularChain doesn't apply
        // stale values from a previous lifecycle.
        pendingMicAmp = nil;
        pendingMicDryAmp = nil;
        pendingGranularOutAmp = nil;
        pendingFbAmp = nil;
        pendingFbBalance = nil;
        pendingFbHpFreq = nil;
        pendingFbNoise = nil;
        pendingFbSineLevel = nil;
        pendingFbSineHz = nil;

        granularAllocated = false;
    }
```

**Lines 479-492**: also clear the pending values, so a future `ensureGranularChain` doesn't apply stale values from before the free. Then set `granularAllocated = false` so the next setter call re-engages the lazy alloc.

## Granular setters (cache-then-apply, with lazy alloc)

Nine setters for the granular chain. They all follow the same pattern:

```supercollider
    setMicAmp { arg amp;
        pendingMicAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { micSynth.notNil }) { micSynth.set(\amp, amp) };
    }
```

**Lines 494-498**: `setMicAmp`. Three steps:

1. **Cache** in `pendingMicAmp`. Even if the chain is alive, we still cache — this is fine; pending will just be ignored if the chain doesn't need re-alloc.
2. **Trigger alloc** if amp is non-zero AND chain isn't alive. The `ensureGranularChain` is idempotent so calling it when already-alloc'd is fine.
3. **Apply now** if the chain is alive and micSynth is non-nil. The `and: { ... }` is SC's short-circuit "lazy and" — second clause only evaluated if first is true.

```supercollider
    setMicDryAmp { arg amp;
        pendingMicDryAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { micDrySynth.notNil }) { micDrySynth.set(\amp, amp) };
    }

    setGranularOutAmp { arg amp;
        pendingGranularOutAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { granGrp.notNil }) { granGrp.set(\amp, amp) };
    }
```

**Lines 500-510**: same pattern for mic dry amp and granular output amp. Note `granGrp.set(\amp, amp)` — setting a group's `amp` arg propagates to every synth inside the group that has an `amp` arg. So one call sets the amp on all 4 grain synths.

```supercollider
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
```

**Lines 512-540**: the six feedback patch setters. Each follows the cache-then-apply pattern. Notably, these do NOT call `ensureGranularChain` — even if the feedback amp is set, we don't auto-allocate the chain. The user must enable mic / granular out / mic dry to trigger alloc.

```supercollider
    setGrainPanRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };
        grainPanRates[grainIdx] = rate;
        if (granularAllocated and: { grainPanLFOs[grainIdx].notNil }) {
            grainPanLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainCutoffRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };
        grainCutoffRates[grainIdx] = rate;
        if (granularAllocated and: { grainCutoffLFOs[grainIdx].notNil }) {
            grainCutoffLFOs[grainIdx].set(\rate, rate);
        };
    }

    setGrainResRate { arg grainIdx, rate;
        if (grainIdx >= grainCount) { ^this };
        grainResRates[grainIdx] = rate;
        if (granularAllocated and: { grainResLFOs[grainIdx].notNil }) {
            grainResLFOs[grainIdx].set(\rate, rate);
        };
    }
```

**Lines 542-564**: three per-grain modulation setters. The `if (grainIdx >= grainCount) { ^this }` is bounds-checking — out-of-range grain indices return early without writing.

## Per-cell TriSin lifecycle

```supercollider
    allocTriSin { arg cellId;
        var pending;
        if (triSinInstances[cellId].isNil) {
            triSinInstances[cellId] = TriSin.new(dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
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
```

**Lines 570-587**: allocate a TriSin instance for `cellId`. The `isNil` check makes this idempotent. After construction:

- **`TriSin.new(dryBus.index, reverbBus.index, delayBus.index, granularBus.index)`** — pass the four bus indices so the TriSin instance knows where to route audio.
- **Apply pending params** — `pendingTriSinParams[cellId].keysValuesDo({ |k, v| ... })` iterates the pending dict; for each key-value pair, call `setParam('all', k, v)` on the new instance (which broadcasts to all 8 voices).
- **Clear pending** — `pendingTriSinParams[cellId] = nil` to avoid re-applying on future allocs.
- **Log** — distinct messages for "with pending" vs "without pending" applications.

```supercollider
    freeTriSin { arg cellId;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.free;
            triSinInstances[cellId] = nil;
            pendingTriSinParams[cellId] = nil;
            ("TriSin freed: " ++ cellId).postln;
        }
    }
```

**Lines 589-597**: free. Standard pattern: look up, free if exists, nil the references.

```supercollider
    triggerTriSin { arg cellId, voiceKey, freq;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.trigger(voiceKey, freq);
        }
    }
```

**Lines 599-604**: trigger. Idiomatic null-check.

```supercollider
    setTriSinParam { arg cellId, paramKey, paramValue;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.setParam('all', paramKey, paramValue);
        } {
            if (pendingTriSinParams[cellId].isNil) {
                pendingTriSinParams[cellId] = Dictionary.new;
            };
            pendingTriSinParams[cellId][paramKey] = paramValue;
        };
    }
```

**Lines 606-617**: setParam with pending caching. Two branches:

- **Instance exists**: forward to `inst.setParam('all', ...)`.
- **No instance yet**: lazy-create the per-cell pending dict, store the value.

## Per-cell Ringer lifecycle (parallel to TriSin)

```supercollider
    allocRinger { arg cellId;
        // ... identical structure to allocTriSin ...
    }
    freeRinger { arg cellId; ... }
    triggerRinger { arg cellId, voiceKey, freq; ... }
    setRingerParam { arg cellId, paramKey, paramValue; ... }
```

**Lines 619-670**: parallel to TriSin's lifecycle, just operating on `ringerInstances` and `pendingRingerParams` instead. The code is essentially identical except for the class name (`Ringer.new` vs `TriSin.new`) and the dict references.

This duplication is intentional. Abstracting it (e.g., a generic `allocVoice(class, cellId, ...)`) would add an indirection layer that the Lua-side `engine.<role>_alloc` calls don't benefit from. Keeping them separate is more readable and easier to specialize per-class if needed.

## Sampler lifecycle, with the buffer cache + `\loading` sentinel

The most complex lifecycle in the file. `loadSampler` handles file loading, dedup via the buffer cache, the `\loading` sentinel for concurrency, and pending param application.

```supercollider
    loadSampler { arg slot, filePath;
        fork {
            var sf, duration, buf, pending;
            var maxSec = 600;
            sf = SoundFile.openRead(filePath);
            if (sf.isNil) {
                ("Sampler " ++ slot ++ " load failed: cannot open " ++ filePath).postln;
            } {
                duration = sf.numFrames / sf.sampleRate;
                sf.close;
```

**Lines 676-687**: pre-flight check. `SoundFile.openRead(filePath)` opens the file's header for inspection (without loading the audio data). `nil` means the file can't be read. If it can:
- `duration = numFrames / sampleRate` gives the duration in seconds.
- `sf.close` releases the file handle (we don't need it for actual loading; `Buffer.read` re-opens internally).

```supercollider
                if (duration > maxSec) {
                    ("Sampler " ++ slot ++ " load REFUSED: "
                        ++ duration.round(0.1) ++ "s exceeds "
                        ++ maxSec ++ "s max (would exhaust Norns RAM).").postln;
                } {
                    if (samplerInstances[slot].notNil) {
                        this.clearSampler(slot);
                    };
```

**Lines 687-696**: enforce the 10-minute cap. Files longer than `maxSec` (600 seconds = 10 minutes) are refused. The log message explains why (RAM exhaustion).

If we're proceeding with the load, clear any existing sampler in this slot first. `clearSampler` handles refcount maintenance for the previous buffer.

```supercollider
                    while ({ bufferCache[filePath] == \loading }) { 0.05.wait };
                    buf = bufferCache[filePath];
                    if (buf.notNil) {
                        bufferRefCounts[filePath] = (bufferRefCounts[filePath] ? 0) + 1;
                        ("Sampler " ++ slot ++ " reusing cached buffer: " ++ filePath
                            ++ " (refs=" ++ bufferRefCounts[filePath] ++ ")").postln;
                    } {
                        bufferCache[filePath] = \loading;
                        buf = Buffer.read(server, filePath);
                        server.sync;
                        bufferCache[filePath] = buf;
                        bufferRefCounts[filePath] = 1;
                        ("Sampler " ++ slot ++ " loaded new buffer: " ++ filePath
                            ++ " (" ++ duration.round(0.1) ++ "s)").postln;
                    };
```

**Lines 702-716**: the buffer cache + `\loading` sentinel logic (detailed below in section 15).

- **Polling wait**: if `bufferCache[filePath] == \loading`, another fork is currently loading this file. Wait 50 ms and check again. Loop until either the sentinel is replaced (load complete) or never set (no concurrent load).
- **Cache hit**: increment refcount, reuse the buffer.
- **Cache miss**: claim the slot with the `\loading` sentinel, do `Buffer.read`, sync, replace sentinel with real buffer, set refcount to 1.

```supercollider
                    samplerInstances[slot] = Sampler.new(buf, dryBus.index, reverbBus.index, delayBus.index, granularBus.index);
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
```

**Lines 717-728**: construct the `Sampler` instance and apply pending params (same shape as TriSin alloc). Also record the path in `samplerPaths[slot]` so we can find it later for refcount maintenance.

```supercollider
                };
            };
        };
    }
```

**Lines 729-732**: close the conditional braces + the fork + the method.

### `clearSampler`

```supercollider
    clearSampler { arg slot;
        var inst = samplerInstances[slot];
        var path = samplerPaths[slot];
        if (inst.notNil) {
            inst.free;
            samplerInstances[slot] = nil;
            pendingSamplerParams[slot] = nil;
            if (path.notNil and: { bufferRefCounts[path].notNil }) {
                bufferRefCounts[path] = bufferRefCounts[path] - 1;
                if (bufferRefCounts[path] <= 0) {
                    if (bufferCache[path].notNil
                        and: { bufferCache[path] != \loading }) {
                        bufferCache[path].free;
                    };
                    bufferCache[path] = nil;
                    bufferRefCounts[path] = nil;
                    ("Buffer freed: " ++ path).postln;
                };
            };
            samplerPaths[slot] = nil;
            ("Sampler " ++ slot ++ " cleared").postln;
        };
    }
```

**Lines 734-761**: clear a sampler slot with full refcount maintenance:

1. Free the instance, null out the entry.
2. Look up the path. **Defensive nil-check**: if `bufferRefCounts[path]` is nil (cache desync), skip the decrement to avoid a `nil - 1` error.
3. Decrement refcount. If it hits 0, free the buffer (with the sentinel-guard to avoid freeing `\loading`).
4. Null out the path reference.

The defensive nil-check was added during development after observing a PSET-load scenario that could desync the cache. Better to skip cleanup silently than to throw.

### `triggerSampler` and `setSamplerParam`

```supercollider
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
            if (pendingSamplerParams[slot].isNil) {
                pendingSamplerParams[slot] = Dictionary.new;
            };
            pendingSamplerParams[slot][paramKey] = paramValue;
        };
    }
```

**Lines 763-781**: trigger and setParam, parallel to the TriSin patterns.

## OneShot lifecycle (same shape as sampler)

`loadOneShot`, `clearOneShot`, `triggerOneShot`, `setOneShotParam` — all structurally identical to the Sampler equivalents except for:

- Different dict references (`oneShotInstances`, `oneShotPaths`, `pendingOneShotParams`).
- Different class instantiation (`OneShot.new(buf, ...)` instead of `Sampler.new`).
- Different trigger signature (no startPos/endPos; just rate).

The buffer cache logic is the same — OneShot and Sampler share the cache, so loading the same file into a Sampler slot and a OneShot slot only costs one buffer.

```supercollider
    triggerOneShot { arg slot, voiceKey, rate;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.triggerWithRate(voiceKey, rate);
        }
    }
```

**Lines 863-868**: note the call is `inst.triggerWithRate(voiceKey, rate)` not just `inst.trigger(...)`. The OneShot class has a separate method for rate-only triggers (it has a `triggerWithRate` that wraps the more general `trigger`). The Sampler's signature is `trigger(voiceKey, startPos, endPos, rate)`; OneShot's `triggerWithRate` is `(voiceKey, rate)`.

## Panic helpers

```supercollider
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
```

**Lines 888-898**: iterate over the instance dicts and call `resetVoices` on each. `resetVoices` (defined on the voice classes, chapters 07-08) frees all voice subgroups and recreates them empty — clearing any active notes without freeing the instance.

These are called from the Lua panic handler (the K1 panic flow, or explicit param). The user can immediately silence all in-flight notes without re-loading any files or instances.

## Tearing it all down: the `free` method

```supercollider
    free {
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        if (granularAllocated) { this.freeGranularChain };
```

**Lines 900-905**: free every voice instance. `.do { |inst| inst.free }` iterates the dictionary's values and calls `.free` on each. If the granular chain is alive, tear it down too.

```supercollider
        bufferCache.do { |buf|
            if (buf.notNil and: { buf != \loading }) { buf.free };
        };
```

**Lines 910-912**: free every cached buffer. The guard against `\loading` prevents trying to free the sentinel (which would error — symbols don't have `.free`). The `buf.notNil` is belt-and-suspenders.

This was added during development. Without it, every script reload leaked the cached buffers on the SC server. Reloads would slowly exhaust server memory until SC restart.

```supercollider
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
```

**Lines 913-925**: free the master FX synths, groups, and buses. The closing `}` ends the class.

`★ Insight ─────────────────────────────────────`
**Order of free matters when objects depend on each other.** Voice instances are freed first because they might be in the middle of triggering synths in the voice subgroups; freeing the subgroups out from under live synths could orphan node references. Master FX synths are freed before their group (otherwise the group.free would orphan them). Groups are freed before buses (the synths in the groups might write to the buses on a final block). Following this dependency-aware order prevents stray `Node X not found` errors.

**This `free` method is what `Engine_Lied.sc`'s `free { kernel.free }` calls** when the engine is unloaded. Every Lua `cleanup()` invocation eventually reaches here. The cleanup is comprehensive enough that subsequent script loads see a clean server.
`─────────────────────────────────────────────────`

## Summary

`Lied.sc` is 925 lines of dense SC code, but the patterns it uses repeat throughout. Reading the file with the architectural context from earlier chapters in mind:

- **Bus + group architecture** sets up the audio routing fabric (sections 4, 7, 11).
- **SynthDefs** (sections 5, 6) define the DSP graphs.
- **Lazy granular chain alloc** (section 10) is the most novel construction in the file.
- **Voice instance lifecycle methods** (sections 13-16) follow a consistent pattern across TriSin / Ringer / Sampler / OneShot.
- **Buffer cache with `\loading` sentinel** (section 15) handles file dedup safely.
- **Pending-params pattern** appears in every voice and in the granular chain — same idea applied to each.
- **`free`** (section 18) is comprehensive and dependency-aware.

If you're reading the file from scratch, work top to bottom. If you're hunting a specific behavior, the section headers in this document map to line ranges that you can jump to in the source.
