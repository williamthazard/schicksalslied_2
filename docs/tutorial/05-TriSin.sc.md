# Chapter 05 — `lib/TriSin.sc`

The FM-synthesis voice class. **219 lines.** TriSin is the most parameter-rich voice in the project — FM index envelope, MoogFF filter with optional envelope tracking, slewed pitch, plus the standard send routing.

## What you'll learn

This chapter is the canonical introduction to the **voice-pool pattern** that all four voice classes share. After this chapter:

- You'll understand the shared structural recipe (classvar `voiceKeys`, `globalParams` template, `singleVoices` subgroups, `voiceParams` cache, the trigger/setParam/free methods).
- You'll understand the `*initClass` + `*addSynthDefs` idiom for one-time SynthDef registration (called from `Lied.init`, never from a `StartUp` hook).
- You'll have a complete `TriSin` class that can be instantiated and triggered from `Lied.sc`'s voice allocation methods.

Chapters 06-08 (Ringer, Sampler, OneShot) reference back to this chapter for the common patterns and specialize on the differences.

## Prerequisites within the tutorial

- Chapters 01-04. Chapter 03 covers how `Lied.sc` allocates and routes to voice instances; chapter 04 covers how Engine_Lied exposes the trigger commands.

## The voice-pool pattern

Every voice class in this script follows the same structural recipe:

```
class VoiceName {
    classvar <voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];

    var <globalParams;          // Dictionary of default values for the SynthDef args
    var <voiceParams;           // voiceKey → per-voice param Dictionary
    var <voiceGroup;            // outer Group containing all voice subgroups
    var <singleVoices;          // voiceKey → per-voice Group (inside voiceGroup)
    var <buffer;                // (only for Sampler / OneShot — holds the audio buffer)

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    *addSynthDefs { /* SynthDef(...).add, called from Lied.init */ }

    *new { arg ... bus indices ...;
        ^super.new.init(...);
    }

    init { arg ... bus indices ...;
        // create voiceGroup
        // create globalParams Dictionary
        // for each voiceKey: create a subgroup + a copy of globalParams
    }

    trigger { arg voiceKey, ...trigger args...; ... }
    setParam { arg voiceKey, paramKey, paramValue; ... }
    free { ... }
}
```

### Why this shape

The classes were designed to support **round-robin polyphony**: each voice cell on the grid claims one of 8 voice keys per trigger, cycling through the pool. If polyphony is 4, the cell uses voiceKeys 1-4 in rotation; if 8, all 8. (The polyphony number is enforced on the Lua side via `Roles.polyphony[cell_id]` — see [chapter 12](12-cell_roles.lua.md).) This is why every class has exactly 8 voiceKeys: that's the upper bound on per-cell polyphony.

The **subgroup-per-key** structure (`singleVoices[\3]` is a `Group` containing one Synth) lets us:

- Track whether a key has an active synth via `singleVoices[\3].isPlaying`.
- Stop the synth on a key via `singleVoices[\3].set(\stopGate, -1.05)` (or just `.freeAll` for hard stops).
- Apply param changes to one key at a time without affecting others.

The **`voiceParams` dictionary per key** lets each voice instance hold its own current parameter state. When a fresh synth is allocated, it gets the per-key params spliced via `getPairs`. Param changes propagate to the dict via the `adjustVoice` / `setParam` methods.

The **`globalParams` dictionary** is the template — when a new voice instance is constructed for the first time (or after a reset), its per-key `voiceParams` is initialized from `globalParams.copy`. So all keys start from the same defaults; they diverge as the user (or the script) sets per-voice values.

`★ Insight ─────────────────────────────────────`
**This is the "object pool" pattern from game programming**, adapted to SC. Instead of creating and destroying voice instances on demand (which would thrash the server's node allocator), we pre-create 8 empty subgroups at class init, and fill them with synths on trigger. When a synth is done, the subgroup empties out but stays alive. The next trigger on that key just instantiates a new synth in the existing subgroup. Cheap, predictable, low-GC.

**Per-voice param dicts also solve the "set the next note before triggering it" problem.** You can `setParam(\3, \freq, 880)` before triggering key 3, and the next `trigger(\3, ...)` will pick up the new freq because `voiceParams[\3].getPairs` includes the updated value. This is how the Lua side's per-voice param updates work without any explicit "queue this for next trigger" plumbing.
`─────────────────────────────────────────────────`

## The `*initClass` + `*addSynthDefs` idiom

Look at the top of any voice class:

```supercollider
    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("TriSin", {
            arg ...;
            ...
        }).add;
    }
```

What is going on:

- **`*initClass`** is a class method called automatically by SC when the class is compiled. It runs once, before any instances exist, and only sets class-level state (the `voiceKeys` array). It deliberately does **not** touch the server.
- **`*addSynthDefs`** is an ordinary class method holding the SynthDef. Nothing calls it automatically: `Lied.init` calls `[TriSin, Ringer, Sine, Sampler, OneShot].do(_.addSynthDefs)` right before its `server.sync` (chapter 03). By then Crone has booted and configured the server, so `.add` registers the definition on a live server, once per engine load.

So the chain of events is: class compiles → `*initClass` sets `voiceKeys` → Crone boots the server → the engine allocates and `Lied.init` runs → `*addSynthDefs` is called for each voice class → `server.sync` waits until all definitions are registered.

`★ Insight ─────────────────────────────────────`
**Why not register SynthDefs from a `StartUp.add { Server.default.waitForBoot { ... } }` hook?** That is the usual SC idiom for class-defined SynthDefs, and it is what these classes used to do. On norns it is a trap: only Crone may boot the server, because its own startup clears `SC_JACK_DEFAULT_INPUTS`/`OUTPUTS` and then connects scsynth to JACK. A `StartUp` hook in a class file runs at every sclang start, whatever script is loaded, and can run before Crone's hook, booting scsynth un-configured. After SYSTEM > RESTART (sclang restarts, JACK keeps running) this showed up intermittently as `SUPERCOLLIDER FAIL` / `AUDIO ENGINE FAIL`, cleared only by a power cycle. Calling `*addSynthDefs` from `Lied.init` removes the voice classes from the boot sequence entirely.

**Why a class method rather than `init`?** `init` runs per instance, and the SynthDef only needs registering once per engine load, not once per voice-class instance. Registering in `init` would call `.add` several times: harmless but wasteful. A single call from `Lied.init` does it once. The server is guaranteed to be alive at that point, so no `waitForBoot` is needed either.
`─────────────────────────────────────────────────`

## Source sections (TriSin.sc specifically)

1. Class declaration + ivars (lines 1-9)
2. `*initClass` + `*addSynthDefs` (lines 11-95)
3. `*new` + `init` (lines 97-146)
4. `playVoice` and `trigger` (lines 150-179)
5. `adjustVoice` and `setParam` (lines 182-202)
6. `freeAllNotes` and `free` (lines 204-211)

## 1. Class declaration and ivars

```supercollider
// lib/TriSin.sc — FM voice class (ported from naherinlied with .lag on amp)
TriSin {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
    var voiceSynths;    // voiceKey -> Synth; it pauses itself when silent
```

**Lines 1-9**: class declaration + 5 instance variables matching the voice-pool pattern's template above. `voiceSynths` is private (no `<`): it maps each voice key to its `Synth`, so the voice can be resumed after it has paused itself (see section 4).

## 2. `*initClass` + `*addSynthDefs` (the SynthDef)

```supercollider
    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("TriSin", {
            arg t_gate = 0,
                mRatio,
                cRatio,
                index,
                iScale,
                freq,
                hz_offset = 0,
                cutoff,
                resonance,
                cutoff_env,
                attack,
                release,
                iattack,
                irelease,
                cAtk,
                cRel,
                ciAtk,
                ciRel,
                amp,
                pan,
                freq_slew,
                amp_slew,
                pan_slew,
                dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;
```

**Lines 11-44**: `*initClass` (just `voiceKeys`), then `*addSynthDefs` and the start of the SynthDef. The TriSin SynthDef has **34 args** — by far the largest in the project.

The args, grouped:

- **Trigger gate**: `t_gate = 0` — `t_` prefix marks this as a transient (auto-resets to 0 the next block after being set to 1). Triggering happens by setting `t_gate = 1`.

- **FM core**: 
  - `mRatio` — modulator-to-carrier frequency ratio.
  - `cRatio` — carrier-to-base-frequency ratio.
  - `index` — FM modulation index (depth of the modulator).
  - `iScale` — scale factor for the index envelope (peak index = `index * iScale`).

- **Pitch**: `freq` — base frequency in Hz; `hz_offset` — a fixed offset in Hz added to `freq` (default 0), for fine detuning and slow beating between cells.

- **Filter**: `cutoff`, `resonance` — MoogFF lowpass.
- **`cutoff_env`** — flag (0 or 1) for envelope-tracked cutoff.

- **Volume envelope**: `attack, release` (times) + `cAtk, cRel` (curve shapes).
- **FM index envelope**: `iattack, irelease, ciAtk, ciRel`.

- **Mix params**: `amp`, `pan` + their slew times.
- **Slew times**: `freq_slew, amp_slew, pan_slew`.

- **Bus + send levels**: 4 bus indices + 4 send levels.

`★ Insight ─────────────────────────────────────`
**34 args feels like a lot, but FM synthesis warrants it.** Each envelope needs four shape params (time + curve); we have two envelopes (volume + FM index). The frequency ratios need 2 args. The pitch layer adds 2 (`freq`, `hz_offset`). The filter adds 3. The mix layer adds 6. The send layer adds 8. The sum lands at 34 — and removing any single arg would cost a meaningful control.
`─────────────────────────────────────────────────`

```supercollider
            var car, mod, envelope, iEnv, envCutoff, onFloor, filter, signal, ampSig, paused;
            var slewed_freq = max(0.1, freq + hz_offset).lag3(freq_slew);

            envelope = EnvGen.kr(
                envelope: Env(
                    [0, 1, 0],
                    times: [attack, release],
                    curve: [cAtk, cRel]),
                gate: t_gate
            );

            // Unity-shaped index envelope (0 → 1 → 0), scaled AFTER EnvGen.
            // EnvGen latches each segment's target level when the segment
            // starts, so levels [index, index*iScale, index] froze FM depth
            // at note-on; mapping here keeps the same curve per note while
            // index/iScale knob + LFO moves reach sounding notes. The short
            // lag3 smooths 0.01-step knob/LFO updates (no zipper on depth).
            iEnv = EnvGen.kr(
                Env(
                    [0, 1, 0],
                    times: [iattack, irelease],
                    curve: [ciAtk, ciRel]),
                gate: t_gate
            );
            iEnv = index.lag3(0.05) * (1 + ((iScale.lag3(0.05) - 1) * iEnv));
```

**Lines 46-70**: variable declarations, freq offset + slewing, and two envelopes. `max(0.1, freq + hz_offset)` adds the Hz offset to the base frequency (clamped so it can never reach 0 or go negative) before `.lag3(freq_slew)` smooths pitch changes.

`Env([0, 1, 0], times: [attack, release], curve: [cAtk, cRel])`:
- Three breakpoints: 0 → 1 → 0.
- Two segments: 0-to-1 over `attack` seconds, 1-to-0 over `release` seconds.
- Two curve shapes: `cAtk` for the attack segment, `cRel` for the release.

This is an **AR (attack-release) envelope**, gated by `t_gate`. Setting `t_gate = 1` retriggers from the start.

**NO `doneAction: 2`** — important. The synth STAYS ALIVE after the envelope completes. The user can re-trigger the same Synth indefinitely. This is the **persistent voice** model. (Once a note is over and silent the synth *pauses itself*, so staying alive costs nothing; see `Lied.pauseWhenSilent` below and in chapter 03.)

`iEnv` (FM index envelope) goes index → index*iScale → index. This sweeps the FM intensity during the note: low → high → low. If iScale = 5, the index temporarily hits 5x its base value mid-note. Sweeping the FM index produces the characteristic "evolving timbre" that gives TriSin its name.

The EnvGen itself only produces the unity shape 0 → 1 → 0; `index` and `iScale` are applied afterwards. `EnvGen` reads each segment's target level only when that segment starts, so writing `levels: [index, index * iScale, index]` would freeze FM depth at note-on: turning the index/iScale knobs (or an LFO on them) would do nothing to a sounding note. Mapping after the EnvGen gives the identical curve per note while letting live changes through. The 50 ms `lag3` keeps 0.01-step knob/LFO updates from stepping audibly in the modulation depth.

```supercollider
            mod = SinOsc.ar(slewed_freq * mRatio, mul: slewed_freq * mRatio * iEnv);
            car = LFTri.ar(slewed_freq * cRatio + mod) * envelope;
```

**Lines 72-73**: the FM construction.

- **`mod`**: sine oscillator at frequency `freq × mRatio`. The `mul` (output gain) is `slewed_freq * mRatio * iEnv` — which is the FM modulation depth, scaling with the FM frequency AND the envelope. This is the classic FM-index-relative-to-frequency formula.
- **`car`**: triangle oscillator at `freq × cRatio`, with `mod` added to its phase argument. Adding to the phase of an LFTri is how SC implements frequency modulation: the modulator's value perturbs the carrier's instantaneous phase. Then multiply by the volume envelope.

The `LFTri` carrier (triangle, not sine) is what gives TriSin its name: TRIangle carrier modulated by SINe modulator.

`★ Insight ─────────────────────────────────────`
**Frequency modulation via "add to phase"** is the canonical SC pattern: `LFTri.ar(carrier_freq + modulator_signal)`. The "frequency arg" of LFTri.ar is really a phase rate; adding a signal perturbs the phase. The result is FM.

**The `slewed_freq * mRatio * iEnv` formula for modulator amplitude** is what's called "index of modulation" in FM theory: the ratio of modulator amplitude to modulator frequency. Higher index = wider sideband spread = brighter sound. The `iEnv` envelope shapes this over time.
`─────────────────────────────────────────────────`

```supercollider
            // The enveloped cutoff stops at 20 Hz: at 0 Hz MoogFF freezes and
            // holds its last output as DC, so the voice never fell silent
            // (and never paused). Once the decay reaches that floor,
            // resonance is capped below self-oscillation so the filter rings
            // down instead of humming at 20 Hz. The note above 20 Hz is
            // unchanged.
            envCutoff = cutoff * envelope;
            onFloor = (envCutoff < 20) * (Sweep.kr(t_gate) > attack);
            filter = MoogFF.ar(
                in: car,
                freq: Select.kr(cutoff_env > 0, [cutoff, envCutoff.max(20)]),
                gain: Select.kr(cutoff_env > 0, [resonance, resonance.min(4 - (0.5 * onFloor))])
            );

            paused = Lied.pauseWhenSilent(t_gate, attack + release, filter);

            signal = Pan2.ar(
                filter,
                Lied.notePan(pan, pan_slew, t_gate, paused)
            );
```

**Lines 75-94**: filter, self-pause and pan.

`MoogFF.ar(in, freq, gain)` is a Moog ladder filter UGen with `freq` cutoff and `gain` resonance.

`Select.kr(cutoff_env > 0, [cutoff, envCutoff.max(20)])` is the conditional cutoff:
- If `cutoff_env > 0` (boolean, 1 when true), use `envCutoff`, which is `cutoff * envelope`. The cutoff is multiplied by the envelope value (0-1), producing a cutoff sweep that closes as the note decays.
- Otherwise, use `cutoff` directly. Static filter.

This is the "filter envelope tracking" option. With `cutoff_env = 1`, the filter opens at the attack and closes at the release.

The swept cutoff stops at 20 Hz (`.max(20)`) instead of reaching 0. A `MoogFF` at 0 Hz doesn't go quiet; it freezes, holding whatever it was outputting as a constant DC offset. That offset kept the voice from ever counting as silent (so it never paused), and the next note had to jump away from it. At 20 Hz the filter drains to true zero shortly after the note. The cutoff only gets that low in the last few percent of the release, where the signal is already tiny, so the audible note is sample-for-sample unchanged.

The floor has one catch: at `resonance` 4 `MoogFF` self-oscillates, and a self-oscillating filter parked at 20 Hz would hum there until the next note. So `onFloor` (1 once the attack is over and the swept cutoff is below 20 Hz) caps the gain at 3.5 for just that stretch, and the filter rings down instead. The `Sweep.kr(t_gate) > attack` term keeps the cap away from the start of a note, where the envelope also begins near 0. With `cutoff_env = 0` neither the floor nor the cap applies.

`paused = Lied.pauseWhenSilent(t_gate, attack + release, filter)` is what makes a persistent voice cheap. Persistent means the synth never frees, but it would otherwise keep computing the FM graph (and writing zeros to four buses) between notes. This helper pauses the synth once `attack + release` seconds have passed since the last `t_gate` **and** the post-filter signal is below -80 dB. The signal check matters here: `MoogFF` can ring on after the envelope ends, and with `cutoff_env = 0` at `resonance` 4 it self-oscillates, in which case the voice correctly never pauses. The next trigger resumes it (section 4). The helper returns its pause condition, which goes to `notePan` below. Full explanation, and why it uses `PauseSelf` rather than `DetectSilence` or an envelope `doneAction`, in chapter 03.

`Lied.notePan(pan, pan_slew, t_gate, paused)` replaces the old `pan.lag3(pan_slew)`. A paused synth's pan lag is frozen at a stale value, so the note that **resumes** a paused voice snaps to the current pan (it does not start from where the last note left it). A note that retriggers a voice that is still sounding keeps slewing: snapping there would jump the ringing tail across the stereo field within one block, which clicked. After that, the pan slews with `pan_slew` for as long as the note sounds, so a pan change during a note still glides. Details in chapter 03.

```supercollider
            ampSig = amp.lag3(amp_slew);
            Out.ar(dry_bus,    signal * ampSig * dry_send.lag3(0.05));
            Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
            Out.ar(delay_bus,  signal * ampSig * delay_send.lag3(0.05));
            Out.ar(gran_bus,   signal * ampSig * granular_send.lag3(0.05));
        }).add;
    }
```

**Lines 96-102**: post-fader amp and the four Y-shaped sends. Each `Out.ar` writes `signal × amp × send_level` to its FX bus.

`.add` at the end registers the SynthDef. The closing `}` of `*addSynthDefs` follows it directly (line 103); there is no `StartUp`/`waitForBoot` wrapper to unwind.

## 3. `*new` + `init`

```supercollider
    *new { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \hz_offset, 0,
            \mRatio, 1,
            \cRatio, 1,
            \index, 1,
            \iScale, 5,
            \cutoff, 8000,
            \cutoff_env, 1,
            \resonance, 3,
            \attack, 0,
            \release, 0.4,
            \iattack, 0,
            \irelease, 0.4,
            \cAtk, 4,
            \cRel, (-4),
            \ciAtk, 4,
            \ciRel, (-4),
            \amp, 0.5,
            \pan, 0,
            \freq_slew, 0,
            \amp_slew, 0.05,
            \pan_slew, 0.5,
            \dry_bus, dryBusIdx ? 0,
            \reverb_bus, reverbBusIdx ? 0,
            \delay_bus, delayBusIdx ? 0,
            \gran_bus, granularBusIdx ? 0,
            \dry_send, 1,
            \reverb_send, 0,
            \delay_send, 0,
            \granular_send, 0,
        ]);
        singleVoices = Dictionary.new;
        voiceSynths = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }
```

**Lines 105-154**: constructor + initializer. `*new` is standard SC delegation to `init`.

`init`:
- **`voiceGroup = Group.new(s)`** — outer group on the server.
- **`globalParams` Dictionary** — defaults for every SynthDef arg. Note `index` defaults to 1 (modest FM); `iScale, 5` means peak FM intensity is 5x the base index. Bus indices come from constructor args; `dryBusIdx ? 0` defaults to 0 (main output) if nil.
- **8 voice subgroups + 8 param dictionaries**: for each `voiceKey`, create a sub-Group of `voiceGroup` and copy `globalParams` into `voiceParams[voiceKey]` (shallow copy so per-voice changes don't pollute the template).

Defaults worth noting:
- **`freq, 400`** — A4 isn't exactly 400, but 400 is the "starting freq" before triggers update it. Each trigger overwrites this.
- **`mRatio, 1` and `cRatio, 1`** — equal ratios = sine modulator at same frequency as triangle carrier. Subtle FM at low index; more pronounced at higher index.
- **`cutoff, 8000` and `cutoff_env, 1`** — filter at 8 kHz with envelope tracking enabled by default.
- **`release, 0.4` and `irelease, 0.4`** — 400 ms release. Plucky-percussive feel.
- **`cAtk, 4` and `cRel, -4`** — moderately exponential attack and release curves. Negative values are concave (curve sweeps fast at start, slow at end); positive are convex.

`★ Insight ─────────────────────────────────────`
**`Dictionary.newFrom(globalParams)` returns a shallow copy.** Mutations to the per-voice dict don't propagate back to `globalParams`. This is important — without it, setting `voiceParams[\1][\amp] = 0.3` would also set `globalParams[\amp] = 0.3`, and future voice allocations would all start from the changed value. The shallow-copy semantics let each voice diverge from the template.
`─────────────────────────────────────────────────`

## 4. `playVoice` and `trigger`

```supercollider
    playVoice {
        arg voiceKey, freq;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\freq] = freq;
            // The voice pauses itself once silent (Lied.pauseWhenSilent);
            // resume it in the same bundle as the retrigger.
            Server.default.makeBundle(nil, {
                voiceSynths[voiceKey].run(true);
                singleVoices[voiceKey].set(\freq, freq, \t_gate, 1);
            });
        }, {
            voiceParams[voiceKey][\freq] = freq;
            // One bundle, so the first trigger lands in the synth's first
            // block: a separate later message could find it paused.
            Server.default.makeBundle(nil, {
                voiceSynths[voiceKey] = Synth.new("TriSin", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
                singleVoices[voiceKey].set(\t_gate, 1);
            });
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }

    trigger {
        arg voiceKey, freq;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK, freq); });
        }, {
            this.playVoice(voiceKey, freq);
        });
    }
```

**Lines 158-187**: trigger machinery.

`playVoice(voiceKey, freq)`: the **persistent voice retrigger pattern**.

- **If alive** (`singleVoices[voiceKey].isPlaying` returns true): retrigger the existing synth. Inside one `Server.default.makeBundle(nil, {...})` it sends `voiceSynths[voiceKey].run(true)` (resume the synth if it had paused itself; harmless if it is running) and sets the new freq AND `\t_gate, 1`. Both messages carry the same time stamp, so the synth wakes and sees the trigger on its first block. The `t_gate` re-fires the envelope from the start. The synth stays alive across triggers.
- **If not alive**: allocate fresh. `voiceSynths[voiceKey] = Synth.new("TriSin", voiceParams[voiceKey].getPairs, singleVoices[voiceKey])` — splice all cached params via getPairs, and keep the handle for later resumes. `Synth.new` and `set(\t_gate, 1)` go in one `makeBundle`, so the first trigger lands in the synth's first block (a separate later message could find the synth already paused when the note is very short). Finally `NodeWatcher.register(...)` so `isPlaying` will accurately track future state changes.

As long as the synth exists, retriggering is one resume plus one `set`, bundled. Only the first call per voice key (or after an explicit free) allocates a new Synth.

`★ Insight ─────────────────────────────────────`
**`isPlaying` is a NodeWatcher-maintained flag**. SC sets it to true on construction; without NodeWatcher, it stays true forever (even after the synth is freed by some other path). With `NodeWatcher.register(node, true)`, SC monitors the node and updates `isPlaying` based on real server `/n_end` events. The `true` arg means "track free events" — set `isPlaying` to false when the node frees.

**Why register only on the "no synth yet" branch?** Because that's the only branch that creates a new synth. The "already playing" branch reuses the existing synth (which is already registered from its earlier creation).
`─────────────────────────────────────────────────`

`trigger(voiceKey, freq)` is the public API. If `voiceKey == 'all'`, fire all 8 voices at the same freq (chord-bomb mode).

## 5. `adjustVoice` and `setParam`

```supercollider
    adjustVoice {
        arg voiceKey, paramKey, paramValue;
        singleVoices[voiceKey].set(paramKey, paramValue);
        voiceParams[voiceKey][paramKey] = paramValue;
    }

    setParam {
        arg voiceKey, paramKey, paramValue;
        if (voiceKey == 'all', {
            voiceGroup.set(paramKey, paramValue);
            voiceKeys.do({
                arg vK;
                voiceParams[vK][paramKey] = paramValue;
            });
        }, {
            this.adjustVoice(voiceKey, paramKey, paramValue);
        });
    }
```

**Lines 190-210**: param-setting.

`adjustVoice` sets the param on the single voice's subgroup (which broadcasts the set to any synth inside it — usually one synth) AND updates the cached param value (so future `Synth.new` uses it).

`setParam('all', ...)` is the **"real-time amp control" idiom**: one OSC message to the outer `voiceGroup` updates the param on every active synth simultaneously, plus updates all per-voice caches. This is what the Lua side calls when setting `cell_1_2_amp` — it goes to all 8 voices at once.

`★ Insight ─────────────────────────────────────`
**`voiceGroup.set(paramKey, paramValue)` is one OSC message.** Norns sends OSC over UDP localhost — fast, but not free. By using a group-level set instead of 8 individual synth-level sets, we save 7 OSC messages per cross-voice param change. With multiple cells and frequent param changes (LFOs, MIDI control), this matters.

**The dual-write pattern (set the synth + cache the value)** is the key to the voice-pool pattern's correctness. Without the cache update, the next voice allocation would use the stale `globalParams`-derived value. Without the synth set, currently-sounding notes wouldn't reflect the change. Both writes are mandatory.
`─────────────────────────────────────────────────`

## 6. `freeAllNotes` and `free`

```supercollider
    freeAllNotes {
        voiceGroup.freeAll;
    }

    free {
        voiceGroup.free;
    }
}
```

**Lines 212-219**: cleanup methods.

`freeAllNotes`:
- **`voiceGroup.freeAll`** — frees every synth in the outer group + recursively in subgroups. Hard kill. The subgroups themselves stay alive.

This is the **hard panic stop** — every synth cuts abruptly. For TriSin's persistent voices this is fine because:
- The user knows panic = silence right now.
- TriSin doesn't have a natural "fade out gracefully" path without complex state.

The cost: when `freeAllNotes` is called, TriSin notes cut abruptly. This is acceptable for panic situations.

(Compare to Ringer's `freeAllNotes`, which gates envelopes off gracefully — see chapter 06.)

`free`:
- **`voiceGroup.free`** — destroy everything. The instance is dead after this; don't reuse.

The closing `}` ends the class.

## Checkpoint

In SC IDE, recompile (`Cmd-Shift-L`). Then test against your chapter 03 `Lied` instance:

```supercollider
s.boot;
~lied = Lied.new(s);
// Wait for "Lied init complete."

~lied.allocTriSin(\test);
~lied.triggerTriSin(\test, 1, 440);   // voice 1 at 440 Hz
~lied.triggerTriSin(\test, 2, 550);   // voice 2 at 550 Hz (a major third up)
~lied.triggerTriSin(\test, 3, 660);   // voice 3 — a perfect fifth (almost) of the root
~lied.setTriSinParam(\test, \amp, 0.0);  // fade all voices on this cell to silence
~lied.setTriSinParam(\test, \amp, 0.5);  // bring them back
~lied.freeTriSin(\test);
~lied.free;
```

You should hear a stack of FM tones, voice 1 separable from voices 2 and 3 because each has its own subgroup.

## Summary

`TriSin.sc` is 219 lines defining a full-featured FM voice. The patterns established here apply (with variations) to all four voice classes:

- **Persistent voice model**: no `doneAction: 2`. Each subgroup's Synth stays alive and **pauses itself when silent** (`Lied.pauseWhenSilent`); retriggers send `run(true)` plus `set(\t_gate, 1)` in one bundle, using the `voiceSynths` handle.
- **`isPlaying` branch for retrigger vs allocate**: only allocate when no synth exists for the voice key.
- **`NodeWatcher.register(node, true)`** to keep `isPlaying` accurate.
- **Two envelopes**: AR volume envelope + AR FM-index envelope. Both gated by t_gate, both shaped per-cell via params.
- **Conditional cutoff envelope**: `Select.kr(cutoff_env > 0, [cutoff, envCutoff.max(20)])` toggles between static cutoff and envelope-tracked cutoff (floored at 20 Hz so the filter drains to silence).

The voice-pool pattern (classvar voiceKeys, globalParams template, singleVoices subgroups, voiceParams cache, trigger / setParam / free) is the canonical structure for all voice classes in this script.

## What's next

**Chapter 06 — Ringer.sc** specializes the voice-pool pattern for a percussive one-shot voice. Where TriSin is persistent and uses FM, Ringer is one-shot (doneAction: 2) and uses an impulse-pinged resonant filter. We'll see how the same architectural skeleton supports a different signal generation strategy.
