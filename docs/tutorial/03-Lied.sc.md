# Chapter 03 — `lib/Lied.sc`

The SC kernel that owns all DSP for schicksalslied 2.0. **about 1,250 source lines** — the largest SC file in the project, and the most architecturally dense. (The `Lines N-M` annotations below were written against an earlier, shorter revision and are approximate; search for the quoted code in `lib/Lied.sc` rather than jumping to the line number.)

If you've worked through chapters 01-02 you have everything you need to start. We'll build this file top-to-bottom: class skeleton, then the four-bus + three-group audio architecture, then the master FX SynthDefs, then the granular chain (lazily allocated when first needed), then voice instance management for the five voice classes (Sine, TriSin, Ringer, Sampler, OneShot). By the end of the chapter your class compiles, instantiates, and routes audio cleanly — but it won't yet be reachable from Norns (that's the next chapter's job).

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
    var <sineInstances;             // Dictionary: cell_id (Symbol) → Sine instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance
```

**Lines 11-15**: the five voice-instance dictionaries. Sine, TriSin and Ringer are keyed by cell IDs (`'1_2'`, `'5_2'`, etc.). Sampler and OneShot are keyed by integer slot numbers. The asymmetry reflects the conceptual model: row 2 voices belong to grid cells; samplers and one-shots belong to numbered slots.

```supercollider
    var <bufferCache;               // Dictionary: filePath (String) → 2-channel Buffer
    var <bufferRefCounts;           // Dictionary: filePath → Integer (# slots using it)
    var <samplerPaths;              // Dictionary: slot (Integer) → filePath (for refcount maintenance)
    var <oneShotPaths;              // Dictionary: slot → Array of filePaths
    var <oneShotLoadGen;            // Dictionary: slot → Integer, bumped by every load/clear
    var <samplerLoadGen;            // same, for looping sampler slots
```

**Lines 16-21**: buffer dedup state. `bufferCache` maps a file path to its loaded 2-channel Buffer (or to the `\loading` sentinel during a load-in-progress). `bufferRefCounts` tracks how many sampler/one-shot slots reference each cached buffer. `samplerPaths` / `oneShotPaths` reverse-map each slot to the path(s) it currently uses, so clearing a slot knows which refcounts to decrement. `samplerPaths[slot]` is a single String; **`oneShotPaths[slot]` is always an Array** of path Strings (a single file is a one-element Array, a folder is one entry per file). `samplerLoadGen[slot]` and `oneShotLoadGen[slot]` are per-slot generation counters that make overlapping loads safe (see the shared sample-buffer cache section).

```supercollider
    var <pendingTriSinParams;  // Dictionary: cellId (Symbol) → Dictionary(paramKey → value)
    var <pendingRingerParams;
    var <pendingSineParams;
    var <pendingSamplerParams; // Dictionary: slot (Integer) → Dictionary
    var <pendingOneShotParams;
```

**Lines 19-22**: pending params for voices not yet allocated. The pattern is also referenced in chapter 13 (voice_params.lua) — when the Lua side sets a param via `engine.trisin_set_param("1_2", \amp, 0.3)` before `engine.trisin_alloc("1_2")` has run, the value is cached here. At alloc time, the cached values are applied to the new voice instance.

```supercollider
    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
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
    var <pendingMicAmp, <pendingGranularOutAmp;
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

> There is no mic dry-passthrough synth any more. The old `\liedMicDry` SynthDef (and its `micDrySynth`, `setMicDryAmp` and `set_mic_dry_amp` command) were removed: row 8 col 16 is now a shortcut to the norns **LEVELS monitor** (`monitor_level`), the hardware input monitor, so the dry mic never passes through SuperCollider at all and can't feed the feedback patch. See chapters 14 and 19.

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
            // softclip bounds the recirculated part (|out| < 1), so at
            // preLevel 1 the buffer can't grow without limit pass after pass.
            // It's linear below 0.5, so normal-level material is untouched.
            sig = sig + (BufRd.ar(1, buf, ptr) * preLevel).softclip;
            BufWr.ar(sig, buf, ptr);
        }).add;
```

**Lines 148-155**: the recorder. Read the current pointer position, read the mic signal, mix in `preLevel` times the existing buffer content at the same position, write the result back to the buffer at the pointer.

The `preLevel` parameter (defaulting to 0) controls feedback within the buffer. At 0, each write overwrites old content. At 1, each write sums new audio with old, producing accumulating layered material. It is exposed to the user as the **buffer preservation** param (`buffer_preservation` → `engine.set_rec_pre_level` → `setRecPreLevel`). The recirculated part is passed through `.softclip`, which bounds it below 1 in magnitude: without it, `preLevel = 1` would let the buffer grow without limit on every pass; with it, the old material saturates gently instead (and is effectively linear below about 0.5, so ordinary levels are untouched).

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
```

**Lines 185-232**: the grain reader, the heart of the granular chain. This deserves a careful walk:

- **`env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2)`** — an ASR envelope. The synth lives until the envelope hits 0 (gate goes low and release completes), then frees itself.
- **`grainTrigger = CoinGate.ar(sync, Impulse.ar(dens)) + CoinGate.ar(1 - sync, Dust.ar(dens))`** — the grain trigger stream. `sync` (0-1, the **grain sync distribution** param) is a probability that decides, trigger by trigger, between `Impulse.ar(dens)` (regular, synchronized pulses) and `Dust.ar(dens)` (random Poisson-distributed pulses). `sync = 1` (default) is all Impulse, `0` is all Dust, in between is a mix of both. `dens` is kept equal to `1 / (grainDur × |rate|)`, set at allocation and again by `applyTapRates` whenever the rates change.
- **`durCtrl = baseDur * LFNoise1.kr(100).exprange(1 / durRand, durRand)`** — grain duration with random variation. `LFNoise1.kr(100)` is a 100 Hz random walk (at control rate: `GrainBuf` only reads duration, rate and position at the instant a grain starts, so audio-rate noise was wasted work, about a third of the grain cost); `.exprange(min, max)` maps it exponentially to `[1/durRand, durRand]`. Multiplying `baseDur` by this produces a duration that varies exponentially around `baseDur`.
- **`rateCtrl = rate.lag3(0.5) * LFNoise1.kr(100).exprange(...)`** — playback rate with random variation. Same pattern but with `.lag3(0.5)` smoothing on the central rate (so user rate changes don't click).
- **`panCtrl = pan + LFNoise1.kr(100).bipolar(panRand)`** — stereo pan with random variation. `bipolar(panRand)` maps the random walk to `[-panRand, +panRand]`. It is applied at the very end by `Pan2` (see below), so the whole grain stream sweeps smoothly with the LFO.
- **`ptrRand = LFNoise1.kr(100).bipolar(ptrRandSamples)`** — random offset (in samples) added to the lookback distance, producing position variation between grains.
- **`totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay)`** — the actual lookback distance for THIS grain at THIS moment. Clamped to a minimum to prevent reading too close to the write head.
- **`ptr = In.ar(ptrBus, 1); ptr = ptr - totalDelay; ptr = ptr / BufFrames.kr(buf)`** — read the write-head position, back it up by `totalDelay`, normalize to 0-1 (GrainBuf expects normalized positions).
- **`maxGrainDur = (totalDelay / rateCtrl.abs) / SampleRate.ir; durCtrl = min(durCtrl, maxGrainDur)`** — cap the grain duration so the grain doesn't outrun the write head. If a grain plays for longer than `totalDelay / |rate|` seconds, it would catch up to the write head and play data that hasn't been written yet (or is currently being overwritten). The cap prevents this.
- **`GrainBuf.ar(1, grainTrigger, durCtrl, buf, rateCtrl, ptr, 4, 0, grainEnv)`** — the actual grain reader. **Mono** output (the delay buffer is read as one channel and `GrainBuf`'s own pan argument is 0), density trigger, duration, buffer, rate, position, interpolation (4 = cubic), pan, env (-1 = built-in Hann window, otherwise a custom window buffer; see the grain window param).
- **`MoogFF.ar(...)`** — apply a resonant lowpass filter to the (mono) grain output. One filter instead of two, which halves the cost of what is the most expensive UGen in the synth. `cutoff` (driven by a per-grain LFO Ndef) is capped at `cutoffMax` (the **grain cutoff ceiling** param), and `resonance` is clipped to 0-4.
- A negative `rate` plays the grain backwards (the **grain reverse** param flips every other grain's rate negative).
- **`Out.ar(out, Pan2.ar(sig, panCtrl))`** — pan the filtered mono grains with `panCtrl` and write the stereo result to `out` (typically dryBus). Before, `GrainBuf` panned each grain at its start using whatever the pan LFO read at that moment and the stereo pair then went through two filters; panning after the filter moves the whole stream continuously and costs one `MoogFF`.

`★ Insight ─────────────────────────────────────`
**`GrainBuf` does the heavy lifting**: it's a built-in SC UGen that handles grain envelope shaping, scheduling, and reading from a buffer at randomized positions. Without `GrainBuf` we'd need to manually trigger individual grain players and overlap their envelopes, which would be much harder to write and likely slower. Always reach for the built-in granular UGens (GrainBuf, GrainIn, GrainSin, GrainFM) before rolling your own.

**The `LFNoise1.kr(100).exprange(...)` pattern** for randomized parameters is canonical for granular synthesis. `LFNoise1` is "low-frequency noise with linear interpolation" — at 100 Hz it produces a smoothly-varying random signal. `exprange` maps it to the desired range with exponential bias (so values cluster near the geometric mean). The combination produces natural-feeling parameter motion that doesn't sound robotic.
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

**Lines 234-242**: a small mixer that sums the stereo granular send bus to mono with 0.5 gain, then writes the mono result to micBus (where the granular chain reads it). This is what lets voices route into the granular chain via their `granular_send` send level: any voice's granular_send writes to granularBus; `liedGranSend` mixes granularBus → micBus.

The 0.5 gain is the mono-mix normalization (so a stereo signal of (L=1, R=1) becomes mono signal 1.0, not 2.0).

## The voice SynthDefs (added here, not by the voice classes)

```supercollider
        // --- SynthDefs: voices ---
        // Added here, where Crone has already booted the server. They used to
        // come from a StartUp hook in each voice class calling
        // Server.default.waitForBoot, which runs at every sclang start
        // (whatever script is loaded) and could boot scsynth before Crone set
        // it up — on norns only Crone may boot the server.
        [TriSin, Ringer, Sine, Sampler, OneShot].do({ |voice| voice.addSynthDefs });
```

**Lines 238-244**: each voice class keeps its SynthDef in a class method, `*addSynthDefs` (chapters 05-08), and `Lied.init` calls all five right here, just before the `server.sync` barrier below. Because `init` runs inside `CroneEngine`'s alloc Routine, the server is already booted and configured by Crone when these lines execute, and the `server.sync` that follows waits for all five definitions to land before any voice is instantiated.

`★ Insight ─────────────────────────────────────`
**On norns, only Crone may boot the server.** Crone's own startup clears `SC_JACK_DEFAULT_INPUTS`/`OUTPUTS`, boots scsynth, and then connects it to JACK. A `StartUp.add { Server.default.waitForBoot { ... } }` hook inside a class library file runs at *every* sclang start, whatever script is loaded, and can fire before Crone's own hook, booting scsynth un-configured. The visible symptom is an intermittent `SUPERCOLLIDER FAIL` / `AUDIO ENGINE FAIL` after SYSTEM > RESTART (which restarts sclang but leaves JACK running). Moving the `.add` calls into `Lied.init` means this script never touches server boot, so a plain norns restart just works.
`─────────────────────────────────────────────────`

### Voice helpers: `Lied.pauseWhenSilent` and `Lied.notePan`

The voice SynthDefs call two small class methods defined in the "Voice SynthDef helpers" section of `Lied.sc` (just before the shared sample-buffer cache). They exist because the voices are **persistent**: one `Synth` per voice key, retriggered forever and never freed (chapter 05). A persistent synth whose note has ended still runs its whole graph every block (oscillators, `MoogFF`, `Amplitude`, four `Out`s, all writing zeros). With 16 cells plus samplers that idle cost adds up.

```supercollider
    *pauseWhenSilent { arg trig, length, sig;
        var paused = (Sweep.kr(trig) > length) * (Amplitude.kr(sig).asArray.sum < 1e-4);
        PauseSelf.kr(paused);
        ^paused
    }

    *notePan { arg pan, slew, trig, paused;
        ^pan.lag3(slew * (1 - (Trig1.kr(trig, ControlDur.ir) * Delay1.kr(paused))));
    }
```

**`pauseWhenSilent(trig, length, sig)`** makes the enclosing synth pause itself: `PauseSelf.kr(paused)` pauses (does not free) the synth it is in when `paused` turns true. It also **returns** `paused`, so `notePan` can use it. `paused` is true only when both conditions hold:

- `Sweep.kr(trig) > length`: time since the last trigger exceeds `length`, the time the note needs to finish. `Sweep` is a ramp in seconds that restarts from 0 at each trigger. `length` is `attack + release` for Sine and TriSin, the `duration` argument for Sampler (region length x loops / rate), and `len` (`BufDur.kr(buf) / rate.abs`, kept finite at rate 0) for OneShot.
- `Amplitude.kr(sig).asArray.sum < 1e-4`: the **pre-amp** signal (-80 dB) has actually died away. `sig` is Sine's `sig`, TriSin's post-filter `filter`, Sampler's enveloped `filtered`, OneShot's `filter`. `.asArray.sum` makes it work for mono and stereo signals alike.

Neither condition is enough alone. Time alone would pause a voice while a filter still rings, and a self-oscillating `MoogFF` (high resonance) never goes quiet, so it correctly never pauses. Silence alone would pause a sample during a quiet gap in the middle of its playback. The signal is measured before `amp` is applied, so turning the fader down does not make a voice pause early, and a voice with the fader at 0 still pauses once its note is done.

**Resuming.** A paused synth ignores `set` triggers until it is run again. So every voice class's retrigger path sends one bundle, `Server.default.makeBundle(nil, { synth.run(true); group.set(..., \t_gate, 1) })`: `n_run` and the trigger arrive at the same time stamp, and the synth wakes up and sees the trigger on its first block. The `Synth` handle comes from `voiceSynths` (`voiceKey -> Synth`, filled when the voice is first created); `n_run` on an already-running synth is harmless. Creating a voice works the same way: the first-note branch of each class wraps `Synth.new(...)` and the first `group.set(..., \t_gate, 1)` in one `makeBundle`, so the trigger lands in the synth's first block. (As a separate message it could arrive after a very short note had already paused the synth, and the note was lost.) The Sampler and OneShot `resetVoices` (panic) frees the subgroups, which frees their synths, and drops the handles (`voiceSynths.removeAt`), so the next trigger creates fresh ones.

**Why `PauseSelf`.** It pauses in the same control block the condition turns true. On resume, the bundle's trigger resets `Sweep` in the first block, which drops the condition to 0 and re-arms `PauseSelf` for the next note. Two alternatives were tried. `DetectSilence` keeps its own silence timer, which still reads "silent" when the voice wakes, so it re-paused at once and swallowed the note. An `EnvGen` with `doneAction: 1` re-arms but acts one block late: a trigger landing in that block (about 1.3 ms after the pause point) was consumed, and then the synth paused anyway, dropping the note. Offline renders at 48 kHz with 120 retriggers aimed at that window: the `EnvGen` version dropped 2 notes, `PauseSelf` none.

**`notePan(pan, slew, trig, paused)`** is the pan used by Sine, TriSin, Sampler and OneShot. `paused` is the value `pauseWhenSilent` returned. A plain `pan.lag3(pan_slew)` has a problem with paused voices: the lag stops tracking while the synth is paused, so a note that wakes after a long pause starts at a stale position and glides across from there. `notePan` multiplies the slew time by `1 - (Trig1.kr(trig, ControlDur.ir) * Delay1.kr(paused))`. `Trig1` is 1 for one control block after each trigger. `Delay1` holds `paused` back by one block, so it still reads 1 on the first block after a resume (the synth did not run while paused). The product is 1 only on the block that **resumes a paused voice**. For that block the lag time is 0 and the pan **snaps to its current value**.

A note that retriggers a voice that is **still sounding** does not snap: `paused` is 0, so the pan keeps slewing. An earlier version snapped on every trigger, which jumped a ringing tail across the stereo field within one 64-sample block, and that clicked. After the snap block, `pan` changes (a knob turn, an LFO) are smoothed again **while the note sounds**: a note can start in the left speaker and audibly swing to the right as it decays.

## Instantiating the master FX (where order matters)

```supercollider
        server.sync;
```

**Line 246**: barrier. Wait for the server to finish registering all the SynthDefs above (master FX, granular chain and the five voice classes) before we try to instantiate them. (This used to be a `server.bind` block, but as the comment in section 5 explained, that had race conditions.)

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
```

**Lines 246-253**: initial state for the granular chain (not yet allocated).

- **`granularAllocated = false`** — the lazy-alloc flag.
- **`grainPanRates / grainCutoffRates / grainResRates`** — arrays of `grainCount` random integers in `[1, 64]`. `Array.fill(n, { block })` calls the block n times to construct an array. `rrand(1, 64)` is "random ranged integer in [1, 64]". These are the **periods** of each grain's pan/cutoff/res LFO; randomizing them gives each grain its own slowly-evolving modulation profile.
- **`grainDelayScale = 1.0`** — the default scale for lookback distances.
- **The remaining assignments** hold the defaults for the granular engine params: Hann window (`grainWindowIndex = 0`), cutoff ceiling 16000 Hz, sync distribution 1.0, not frozen, rate multiplier 1.0, octaves/fifths/sub-octaves/reverse off, and `recPreLevel = 0` (buffer preservation).

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
    // Called the first time mic_amp or granular_out_amp
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
```

**Lines 332-338**: the fork begins. `grainEnvBufs` holds the three custom grain windows (percussive, swell, reverse swell) that the **grain window** param selects between; Hann (index 0) is GrainBuf's built-in window (env `-1`) and needs no buffer. `delayBuf = Buffer.alloc(server, ...)` allocates the long heap-based delay buffer. The size is `sampleRate × (beat_sec × 512)` — 512 beats of audio. At 120 BPM (beat_sec = 0.5), that's 256 seconds = ~12 MB stereo float. At 60 BPM, 256 sec; at 240 BPM, 64 sec. The buffer scales with the current tempo at alloc time.

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
            fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
            // Voice→granular send (reads granularBus, writes to micBus).
            // Lives in micGrp so it runs at the head of the chain.
            granSendSynth = Synth(\liedGranSend, [\in, granularBus, \out, micBus], micGrp);
            ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus, \rate, if (granularFrozen) { 0 } { 1 }], ptrGrp);
            recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf, \preLevel, recPreLevel], recGrp);
            if (granularFrozen) { recSynth.run(false); };
```

**Lines 346-354**: instantiate the persistent chain synths. Walking each:

- **`micSynth`** in `micGrp`, reads physical input 0, writes to micBus, default amp 0.
- **`fbPatchMixSynth`** in `micGrp` with `\addToHead` — placed at the very head of micGrp, ensures it reads bus 0 first (before any other writes to dryBus in this block can affect what InFeedback sees).
- **`granSendSynth`** in `micGrp`, reads granularBus, writes to micBus. No specific positioning required.
- **`ptrSynth`** in `ptrGrp`, writes the running phasor index to ptrBus. If the chain is allocated while frozen, it starts with `rate = 0`.
- **`recSynth`** in `recGrp`, reads ptrBus + micBus, mixes them (with `preLevel` feedback = the buffer preservation param, softclipped), writes to delayBuf. If frozen, it starts paused (`run(false)`).

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
            grainRates  = this.computeTapRates;
            grainDurs   = grainCount.collect({ arg i; beat_sec * (i + 1); }).scramble;
            grainDelays = grainCount.collect({ arg i;
                server.sampleRate * (beat_sec * (i + 1)) * 16 * grainDelayScale;
            }).scramble;
```

**Lines 388-396**: per-grain parameter arrays. `.scramble` is SC's "shuffle an array randomly" method.

- **`grainRates = this.computeTapRates`** — one playback rate per grain, from a 4-voice table chosen by the octaves / fifths & 4ths / sub-octaves switches (default table `[1/4, 1/2, 1, 3/2]`, the Carter's Delay rates; e.g. all three on gives `[1/2, 1, 3/2, 2]`). Every rate is multiplied by `grainRateMult`, and with **grain reverse** on, every other grain's rate is negated. The same method is re-run by `applyTapRates` when any of those params change live (which also recomputes each grain's `\dens`).
- **`grainDurs = grainCount.collect({ arg i; beat_sec * (i + 1) }).scramble`** — `grainCount` durations, each `beat_sec * (i + 1)`. For grainCount = 4: durations of 1, 2, 3, 4 beats (in seconds). Scrambled.
- **`grainDelays = grainCount.collect({ ... }).scramble`** — per-grain lookback distances. The formula `sampleRate × (beat_sec × (i + 1)) × 16` is "i+1 beats worth of samples times 16" — giving lookback distances of 16, 32, 48, 64 beats for i = 0..3. The `* grainDelayScale` lets the user shrink these.

```supercollider
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
```

**Lines 398-422**: instantiate the grain synths. `grainCount.collect` runs the block N times and returns an array of the results.

Each grain synth gets its specific rate, duration, delay, and modulation Ndefs. `grainRates` already has exactly `grainCount` entries, so it is indexed directly. The `n % grainCount` for `ptrRandSamples` ensures the variation amount is bounded.

The `\pan, grainPanLFOs[n]` is the Ndef-passing idiom: when you pass an Ndef as an arg value, SC routes the Ndef's output into the synth's input for that arg.

```supercollider
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
```

**Lines 446-460**: free each resource in reverse order. Ndefs first (the LFOs), then the four groups in reverse (granGrp, recGrp, ptrGrp, micGrp — micGrp last because it contained granSendSynth). Then the custom grain-window buffers, the freeze flag reset, the delay buffer and the two buses.

```supercollider
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
```

**Lines 462-477**: explicitly null out every reference. This is important for two reasons:
1. **Garbage collection**: holding stale references prevents Lua/SC's garbage collector from cleaning up. After free, the references are nil; the underlying server resources are already freed.
2. **Re-entrance**: future `setMicAmp` calls check `granularAllocated and: { micSynth.notNil }`. By nulling out `micSynth`, we ensure these checks correctly identify the chain as torn down.

```supercollider
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
```

**Lines 479-492**: also clear the pending values, so a future `ensureGranularChain` doesn't apply stale values from before the free. Then set `granularAllocated = false` so the next setter call re-engages the lazy alloc.

## Granular setters (cache-then-apply, with lazy alloc)

The simple setters for the granular chain (mic amp, granular out amp, six feedback patch setters). They all follow the same pattern:

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
    setGranularOutAmp { arg amp;
        pendingGranularOutAmp = amp;
        if (amp > 0) { this.ensureGranularChain };
        if (granularAllocated and: { granGrp.notNil }) { granGrp.set(\amp, amp) };
    }
```

**Lines 500-510**: same pattern for granular output amp (the old `setMicDryAmp` is gone along with the mic dry synth). Note `granGrp.set(\amp, amp)` — setting a group's `amp` arg propagates to every synth inside the group that has an `amp` arg. So one call sets the amp on all 4 grain synths.

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

**Lines 512-540**: the six feedback patch setters. Each follows the cache-then-apply pattern. Notably, these do NOT call `ensureGranularChain` — even if the feedback amp is set, we don't auto-allocate the chain. The user must enable mic / granular out to trigger alloc.

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

## Granular engine setters (freeze, window, rates)

Besides the amp and LFO setters, the kernel exposes the "granular engine" controls that `grid_grain_params.lua` wires up (chapter 14). They follow the same shape: cache the value in an instance variable, then apply it if the chain is alive.

```supercollider
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
```

**Freeze** stops the write head (`ptrSynth` rate 0) and pauses the recorder, in one bundle so they change on the same block. The grains keep reading the buffer. The flag is cached, so a chain allocated while frozen starts frozen (see `ensureGranularChain`).

- **`setRecPreLevel`** — clips to 0-1 and sets `recSynth`'s `preLevel` (buffer preservation).
- **`setGrainWindow`** — index 0-3 into hann / percussive / swell / reverse swell; sets each grain synth's `grainEnv` to `-1` (Hann) or the matching `grainEnvBufs` buffer number.
- **`setGrainSyncDistribution`** — clips 0-1 and does `granGrp.set(\sync, ...)`.
- **`setGrainCutoffCeiling`** — clips 200-18000 and does `granGrp.set(\cutoffMax, ...)`.
- **`setGrainRateMult`, `setGrainOctaves`, `setGrainFifths`, `setGrainSuboctaves`, `setGrainReverse`** — store the value and call `applyTapRates`.

```supercollider
    applyTapRates {
        var finalRates = this.computeTapRates;
        grainRates = finalRates;
        if (granularAllocated and: { grainSynths.notNil }) {
            grainCount.do({ |i|
                if (grainSynths[i].notNil) {
                    grainSynths[i].set(
                        \rate, finalRates[i],
                        \dens, 1 / (grainDurs[i] * finalRates[i].abs));
                };
            });
        };
    }
```

`applyTapRates` pushes new rates to the live grains **and** recomputes each grain's `dens` with the same formula used at allocation. `dens` is the trigger density, `1 / (grainDur × |rate|)`: without updating it, a grain whose rate changed would keep triggering at its old density and sound different from a freshly allocated chain.

## Per-cell Sine lifecycle

`allocSine`, `freeSine`, `triggerSine` and `setSineParam` mirror the TriSin lifecycle exactly (`sineInstances`, `pendingSineParams`, `Sine.new(dryBus, reverbBus, delayBus, granularBus)`). Sine is the simplest voice and the default role of all 16 row-2 cells; its source is `lib/Sine.sc` (same voice-class structure as chapters 05-06). Its SynthDef is TriSin's with the FM stripped out: `sig = SinOsc.ar(slewed_freq) * envelope`, then `paused = Lied.pauseWhenSilent(t_gate, attack + release, sig)` and `Pan2.ar(sig, Lied.notePan(pan, pan_slew, t_gate, paused))`. Like every persistent voice it keeps its `Synth` in `voiceSynths`, pauses itself when silent and is resumed in the same bundle as each retrigger (see Voice helpers).

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

**Lines 715-732**: allocate a TriSin instance for `cellId`. The `isNil` check makes this idempotent. After construction:

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

**Lines 734-742**: free. Standard pattern: look up, free if exists, nil the references.

```supercollider
    triggerTriSin { arg cellId, voiceKey, freq;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.trigger(voiceKey, freq);
        }
    }
```

**Lines 744-749**: trigger. Idiomatic null-check.

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

**Lines 751-762**: setParam with pending caching. Two branches:

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

**Lines 768-815**: parallel to TriSin's lifecycle, just operating on `ringerInstances` and `pendingRingerParams` instead. The code is essentially identical except for the class name (`Ringer.new` vs `TriSin.new`) and the dict references.

This duplication is intentional. Abstracting it (e.g., a generic `allocVoice(class, cellId, ...)`) would add an indirection layer that the Lua-side `engine.<role>_alloc` calls don't benefit from. Keeping them separate is more readable and easier to specialize per-class if needed.

## Shared sample-buffer cache (samplers and one-shots)

Looping samplers and one-shots load audio the same way, through one set of helpers (`lib/Lied.sc` lines 903-1003). Both voices share a single cache, so the same file loaded into a sampler and a one-shot costs one buffer.

```supercollider
    bumpGen { arg gens, slot;
        gens[slot] = (gens[slot] ? 0) + 1;
        ^gens[slot];
    }
```

**`bumpGen`** (line 920): bump and return a slot's generation counter. There are two counter dictionaries, `samplerLoadGen` and `oneShotLoadGen`, and the helper takes whichever one applies. Every load **and every clear** calls it. A load fork remembers the number it was given; if the counter has moved on by the time the fork finishes, a newer request exists and this one is stale. `Lied.free` bumps every slot of both dictionaries too, so no load can install onto freed buses.

```supercollider
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
```

**`sampleFileOk`** (line 928): the pre-flight check, shared by both voices. `SoundFile.openRead` reads only the header; `nil` means the file can't be opened. `duration = numFrames / sampleRate` is checked against the 600 s (10 minute) cap, and `sf.close` releases the handle (`Buffer.read` re-opens the file itself). `label` ("Sampler" or "OneShot") only changes the log text.

```supercollider
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
```

**`readStereoBuffer`** (line 946): **every cached buffer is 2-channel.** Stereo files load with `Buffer.read`; mono files load with `Buffer.readChannel(channels: [0, 0])`, which reads the one channel into both; files with more than two channels keep their first two (`[0, 1]`). The reason is that `Sampler` reads with `BufRd.ar(2, ...)` and `OneShot` with `PlayBuf.ar(2, ...)`. A buffer UGen asked for more channels than the buffer has plays only the channels it finds, so a mono file used to come out of the **left speaker only**. Dual-mono buffers fix that without any special case in the voices (chapters 07 and 08).

```supercollider
    acquireBuffer { arg filePath;
        var buf;
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

    releaseBuffer { arg filePath;
        if (bufferRefCounts[filePath].notNil) {
            bufferRefCounts[filePath] = bufferRefCounts[filePath] - 1;
            if (bufferRefCounts[filePath] <= 0) {
                // free the Buffer (unless it's the \loading sentinel), clear cache + refcount
            };
        };
    }
```

**`acquireBuffer` / `releaseBuffer`** (lines 960 and 980): the cache-hit / `\loading`-sentinel / refcount logic.

- **Polling wait**: if `bufferCache[filePath] == \loading`, another fork is reading this file right now. Wait 50 ms and check again, so two forks never read the same file twice and orphan a buffer.
- **Cache hit**: increment the refcount and reuse the buffer.
- **Cache miss**: claim the entry with the `\loading` sentinel, read through `readStereoBuffer`, `server.sync`, replace the sentinel with the real buffer, refcount 1.

`acquireBuffer` must run inside a Routine (it waits). `releaseBuffer` drops one reference and frees the Buffer at zero, guarding against freeing the `\loading` sentinel and skipping silently if the refcount entry is missing (a defensive check against cache desync).

```supercollider
    carryVoiceParams { arg old, inst, keys;
        old.voiceParams[old.class.voiceKeys[0]].keysValuesDo({ |k, v|
            if (keys.includes(k)) { inst.setParam('all', k, v) };
        });
    }
```

**`carryVoiceParams`** (line 999): copy the outgoing instance's live params onto its replacement, so reloading a sample keeps the user's sound instead of resetting to SynthDef defaults. Voice 1 holds what `setParam('all', ...)` last wrote, and any `set_param` that arrived mid-load landed on the old instance, so it's included. Only the keys in `keys` are copied (the params Lua owns, not per-trigger values or bus routing).

## Sampler lifecycle (async loads, generations, carry-over)

Looping samplers now load exactly like one-shots: asynchronously, cancellable, and with the old instance playing until the swap.

```supercollider
    loadSampler { arg slot, filePath;
        // Bump first: even a refused load cancels older loads still in flight
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
```

**`loadSampler`** (line 1011): check the file with `sampleFileOk`, take a generation number from `bumpGen(samplerLoadGen, slot)`, fork, and `acquireBuffer`. If the generation moved on while the file was reading, the fork is **superseded**: it releases the reference it just took and installs nothing, so back-to-back loads (PSET recall, E3 stepping through files) can't overwrite each other's instances or leak refcounts. Otherwise it calls `installSampler`. Note that the old sampler is **no longer cleared first**; it keeps playing while the new file reads.

```supercollider
    installSampler { arg slot, buf, filePath;
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
        if (oldPath.notNil) { this.releaseBuffer(oldPath) };
    }
```

**`installSampler`** (line 1030) swaps the new instance in:

- The old instance's live Lua-owned params (amp, slews, cutoff, resonance, pan, rate, the four sends) are carried over with `carryVoiceParams`, then the old instance is freed.
- Pending params are applied on top, then cleared.
- The **old path's buffer reference is released only after the new instance holds its own**, so reloading the same file never frees and re-reads it.

```supercollider
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
```

**`clearSampler`** (line 1055): bump the generation first, so a load still in flight is cancelled (it releases its own buffer when it finishes), then free the instance and release the path's single reference.

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

**Lines 1069-1087**: trigger and setParam, parallel to the TriSin patterns.

## OneShot lifecycle (folders, generations, carry-over)

One-shots add one twist to the shared machinery: a slot can hold **several buffers** (a folder of samples). The code is built on the helpers above.

```supercollider
    loadOneShotPaths { arg slot, filePaths, label, gen;
        fork {
            var buffers = List.new, acquired = List.new;
            filePaths.do({ |p|
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
                ...
            };
        };
    }
```

**`loadOneShotPaths`** (line 1099): take the generation number its caller just bumped, fork, and acquire a buffer for every path, **stopping as soon as the generation changes** so a cancelled folder load doesn't keep reading (and holding in RAM) the rest of its files. A **superseded** fork releases only the references it actually acquired and installs nothing; the newest request always wins.

```supercollider
    installOneShot { arg slot, buffers, filePaths;
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
        if (pending.notNil) { ... apply, then pendingOneShotParams[slot] = nil };
        oneShotInstances[slot] = inst;
        oneShotPaths[slot] = filePaths;
        if (oldPaths.notNil) { oldPaths.do({ |p| this.releaseBuffer(p) }) };
    }
```

**`installOneShot`** (line 1121) has the same shape as `installSampler`: carry the live params over (no `rate` keys; a one-shot's rate is per trigger), apply pending params, and release the old paths only after the new ones are held.

```supercollider
    loadOneShot { arg slot, filePath;
        // Bump first: even a refused load cancels older loads still in flight.
        var gen = this.bumpGen(oneShotLoadGen, slot);
        if (this.sampleFileOk("OneShot", slot, filePath)) {
            this.loadOneShotPaths(slot, [filePath], filePath, gen);
        };
    }

    loadOneShotFiles { arg slot, pathList;
        var paths = pathList.split($\n).reject({ |p| p.isEmpty });
        if (paths.isEmpty) {
            this.clearOneShot(slot);
        } {
            this.loadOneShotPaths(slot, paths, paths.size.asString ++ " files",
                this.bumpGen(oneShotLoadGen, slot));
        };
    }
```

Both loaders bump the generation **before** checking the file, so even a load that `sampleFileOk` refuses cancels any older load still in flight for that slot; otherwise an earlier file could finish and install over the one the user picked last. `loadSampler` does the same.

A single file is just a one-element path Array, so `oneShotPaths[slot]` is **always an Array** (an earlier version stored a bare String there, and `clearOneShot` then iterated its characters and never freed the buffer). Folder loading is `loadOneShotFiles` (lines 1106-1117), reached from the `oneshot_load_files` engine command. Its second argument is a **newline-separated list of absolute paths built by Lua** (`load_oneshot_folder` in chapter 13): Lua scans, sorts, filters and budgets the folder, so Lua's file count and order are exactly what the trigger's `bufIdx` indexes here. An empty list clears the slot.

```supercollider
    clearOneShot { arg slot;
        var inst = oneShotInstances[slot];
        var paths = oneShotPaths[slot];
        this.bumpGen(oneShotLoadGen, slot);  // cancel any load still in flight
        if (inst.notNil) {
            inst.free;
            oneShotInstances[slot] = nil;
            pendingOneShotParams[slot] = nil;
            ("OneShot " ++ slot ++ " cleared").postln;
        };
        if (paths.notNil) { paths.do({ |p| this.releaseBuffer(p) }) };
        oneShotPaths[slot] = nil;
    }
```

`clearOneShot` (line 1166) bumps the generation, so a load still in flight is cancelled, then frees the instance and releases one reference per path.

```supercollider
    triggerOneShot { arg slot, voiceKey, rate = 1, bufIdx = 0, ampScale = 1.0;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.triggerWithRate(voiceKey, rate, bufIdx, ampScale);
        };
    }
```

**`triggerOneShot`** (line 1180): besides `rate`, a trigger carries `bufIdx` (which buffer of the folder to play) and `ampScale` (the accent multiplier). `setOneShotParam` still caches into `pendingOneShotParams` when there's no instance.

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

**Lines 1205-1215**: iterate over the instance dicts and call `resetVoices` on each. `resetVoices` (defined on the voice classes, chapters 07-08) frees all voice subgroups and recreates them empty — clearing any active notes without freeing the instance. It also drops the `voiceSynths` handles, so a paused voice is not resumed through a stale reference (see Voice helpers above).

These are called from the Lua panic handler (the K1 panic flow, or explicit param). The user can immediately silence all in-flight notes without re-loading any files or instances.

## Tearing it all down: the `free` method

```supercollider
    free {
        oneShotLoadGen.keys.do { |slot| this.bumpGen(oneShotLoadGen, slot) };
        samplerLoadGen.keys.do { |slot| this.bumpGen(samplerLoadGen, slot) };
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        sineInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        if (granularAllocated) { this.freeGranularChain };
```

**Lines 1218-1226**: first bump both load-generation dictionaries, so any sample load still reading from disk is cancelled and releases its buffer instead of installing onto freed buses. Then free every voice instance. `.do { |inst| inst.free }` iterates the dictionary's values and calls `.free` on each. If the granular chain is alive, tear it down too.

```supercollider
        bufferCache.do { |buf|
            if (buf.notNil and: { buf != \loading }) { buf.free };
        };
```

**Lines 1227-1233**: free every cached buffer. The guard against `\loading` prevents trying to free the sentinel (which would error — symbols don't have `.free`). The `buf.notNil` is belt-and-suspenders.

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

**Lines 1234-1245**: free the master FX synths, groups, and buses. The closing `}` ends the class.

`★ Insight ─────────────────────────────────────`
**Order of free matters when objects depend on each other.** Voice instances are freed first because they might be in the middle of triggering synths in the voice subgroups; freeing the subgroups out from under live synths could orphan node references. Master FX synths are freed before their group (otherwise the group.free would orphan them). Groups are freed before buses (the synths in the groups might write to the buses on a final block). Following this dependency-aware order prevents stray `Node X not found` errors.

**This `free` method is what `Engine_Lied.sc`'s `free { kernel.free }` calls** when the engine is unloaded. Every Lua `cleanup()` invocation eventually reaches here. The cleanup is comprehensive enough that subsequent script loads see a clean server.
`─────────────────────────────────────────────────`

## Summary

`Lied.sc` is about 1,250 lines of dense SC code, but the patterns it uses repeat throughout. Reading the file with the architectural context from earlier chapters in mind:

- **Bus + group architecture** sets up the audio routing fabric (sections 4, 7, 11).
- **SynthDefs** (sections 5, 6) define the DSP graphs.
- **Lazy granular chain alloc** (section 10) is the most novel construction in the file.
- **Voice instance lifecycle methods** (sections 13-16) follow a consistent pattern across Sine / TriSin / Ringer / Sampler / OneShot (Sampler and OneShot share the generation counters and carry-over).
- **Shared sample-buffer cache** (`acquireBuffer` / `releaseBuffer` with the `\loading` sentinel, 2-channel buffers from `readStereoBuffer`) handles file dedup safely for both samplers and one-shots; `bumpGen` makes overlapping loads safe.
- **Pending-params pattern** appears in every voice and in the granular chain — same idea applied to each.
- **`free`** (section 18) is comprehensive and dependency-aware.

If you're reading the file from scratch, work top to bottom. If you're hunting a specific behavior, the section headers in this document map to line ranges that you can jump to in the source.
