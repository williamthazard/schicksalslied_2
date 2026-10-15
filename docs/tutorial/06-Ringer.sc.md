# Chapter 06 — `lib/Ringer.sc`

The pinged-resonant voice class. **144 lines.** Ringer is the percussive cousin to TriSin: instead of a held envelope and FM modulation, it uses an impulse pinging a resonant filter, with a one-shot envelope that auto-frees the synth.

## What you'll learn

How the voice-pool pattern specializes for a one-shot lifecycle. After this chapter you'll understand:

- `Env.perc` + `doneAction: 2` for self-freeing synths.
- The `stopGate, -1.05` pattern for forced-release on retrigger.
- `Impulse.ar(0)` + `Ringz.ar` as the simplest plucked-string-style synthesis.
- Why `freeAllNotes` uses a gentle gate-off (vs TriSin's hard `freeAll`).

## Prerequisites within the tutorial

- Chapter 05. Ringer shares the voice-pool pattern structure with TriSin — the `classvar voiceKeys`, `globalParams`/`voiceParams`/`singleVoices`, `*initClass` + `*addSynthDefs` idiom (`Lied.init` registers the SynthDefs, chapter 05), and `setParam` machinery are identical and not re-explained here.

## Source sections

1. Class declaration + ivars (lines 1-9)
2. `*initClass` + `*addSynthDefs` (the SynthDef) (lines 10-62)
3. `*new` + `init` (lines 64-98)
4. `playVoice` and `trigger` (lines 100-116)
5. `adjustVoice` and `setParam` (lines 118-135)
6. `freeAllNotes` and `free` (lines 137-143)

## 1. Class declaration and ivars

```supercollider
// lib/Ringer.sc — pinged resonant voice class (perc envelope, doneAction:2)
Ringer {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
```

**Lines 1-9**: class declaration + 5 instance variables. Same shape as TriSin's class declaration. Class-shared `voiceKeys`, four instance variables for state.

The header note "perc envelope, doneAction:2" flags the two distinctive features: a percussive envelope shape (no held sustain) and self-freeing synths.

## 2. `*initClass` + `*addSynthDefs` (the SynthDef)

```supercollider
    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("Ringer", {
            arg stopGate = 1,
                index,
                freq,
                hz_offset = 0,
                amp,
                pan,
                freq_slew,
                amp_slew,
                pan_slew,
                dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;
```

**Lines 10-29**: `*initClass`, then `*addSynthDefs` and SynthDef args. As in TriSin (chapter 05), `*initClass` only sets `voiceKeys`; the SynthDef lives in `*addSynthDefs`, which `Lied.init` calls once Crone has booted the server (a `StartUp.add`/`waitForBoot` hook here could boot scsynth before Crone configured it).

- **`stopGate = 1`** — the envelope gate. Starts at 1 (envelope plays). Setting to a negative value (-1.05) forces release.
- **`index`** — dual-purpose: it is the Ringz **decay time** (how long the filter rings, in seconds) AND it sets the envelope release time (`index.abs * 2`). It is *not* an amplitude control.
- **`freq, hz_offset, amp, pan`** — standard voice params; `hz_offset` is a fixed Hz offset added to `freq` (default 0) for fine detuning.
- **`freq_slew, amp_slew, pan_slew`** — smoothing times.
- **Bus indices + send levels** — same shape as TriSin (4 buses, 4 sends; defaults: dry 1, others 0).

18 args total — about half of TriSin's 34. The simpler signal chain needs fewer controls.

```supercollider
            var envelope, sig, signal, ampSig;

            envelope = EnvGen.kr(
                envelope: Env.perc(
                    attackTime: 0.01,
                    releaseTime: index.abs * 2,
                    level: 1),
                gate: stopGate,
                doneAction: 2
            );
```

**Lines 31-40**: variable declarations + the envelope.

`Env.perc(attackTime, releaseTime, level)` is a "percussive" envelope shape — attack to peak, then release. Args here:

- **`attackTime: 0.01`** — fixed 10 ms attack. Short enough to be percussive; long enough to avoid clicks.
- **`releaseTime: index.abs * 2`** — release time scales with `index`. If index = 3, release is 6 seconds; if index = 10, release is 20 seconds. The `.abs` handles negative index values gracefully.
- **`level: 1`** — peak amplitude 1.0.

`EnvGen.kr(env, gate, doneAction)`:
- **`gate: stopGate`** — the gate signal. With default `stopGate = 1`, the envelope plays through. Setting `stopGate` to a negative value forces release.
- **`doneAction: 2`** — when the envelope ends, free the enclosing synth. **This is what makes Ringer one-shot** — each note allocates a fresh Synth that self-frees when its envelope completes.

`★ Insight ─────────────────────────────────────`
**`index.abs * 2` for release time** is a clever choice. The `index` param is dual-purpose: it controls the Ringz filter's decay time AND the envelope release time. Higher index = longer ring AND longer decay. Lower index = shorter ping AND shorter decay. Coupling these means tweaking one knob produces a coherent character change.

**`doneAction: 2` is the SC convention for "free when done."** Any synth that "plays through and is done" should use it. The alternative — Lua tracking when synths are expected to be done and explicitly freeing them — is fragile (Lua and SC clocks can drift) and adds complexity. Let SC self-clean when possible.
`─────────────────────────────────────────────────`

```supercollider
            // amp is applied ONLY via ampSig below (single, linear fader
            // law, matching TriSin/Sampler/OneShot).
            sig = Ringz.ar(
                Impulse.ar(0),
                max(0.1, freq + hz_offset).lag3(freq_slew),
                index
            ) * envelope;

            signal = Pan2.ar(
                sig,
                pan.lag3(pan_slew)
            );

            // Post-fader: amp scales all 4 sends
            ampSig = amp.lag3(amp_slew);
            Out.ar(dry_bus,    signal * ampSig * dry_send.lag3(0.05));
            Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
            Out.ar(delay_bus,  signal * ampSig * delay_send.lag3(0.05));
            Out.ar(gran_bus,   signal * ampSig * granular_send.lag3(0.05));
        }).add;
    }
```

**Lines 42-61**: signal generation and routing.

- **`Impulse.ar(0)`** — fires one impulse at synth start. The `0` is the frequency (0 = single fire, not periodic). This is the "ping."
- **`Ringz.ar(in, freq, decaytime)`** — a resonant filter that rings at `freq` when excited. Here:
  - `in = Impulse.ar(0)` — the impulse excites the filter.
  - `freq = max(0.1, freq + hz_offset).lag3(freq_slew)` — the base frequency plus the Hz offset (clamped to at least 0.1 Hz), smoothed by the slew time.
  - `decaytime = index` — the index controls how long the filter rings. (Note this is a duration in seconds, distinct from the envelope's release time which is `index.abs * 2`.)
  - `mul` is left at 1 — gain is applied once, downstream.

The result is multiplied by the envelope, producing a pinged-resonant note that decays away.

- **`Pan2.ar(sig, pan)`** — stereo pan.
- **Four `Out.ar` calls** — write to each FX bus at the bus's send level.

`amp` is applied exactly once, via `ampSig` on the sends. The naherinlied donor also passed `amp` as Ringz's `mul`, making the effective output `amp²`; that was removed so Ringer's fader law matches every other voice (a fade on the amp knob is linear, and 0.5 means half, not a quarter).

`★ Insight ─────────────────────────────────────`
**`Ringz.ar(in, freq, decaytime, mul)` is the simplest plucked-string-style synthesis UGen.** An impulse excites a resonant filter; the filter rings at the input frequency; the natural decay produces a plucked-string sound. Compared to physical-modeling alternatives (Pluck.ar, karplus-strong networks), Ringz is much cheaper but less expressive. For the Ringer voice in this script, Ringz is plenty.

**Single-multiply `amp`** keeps loudness consistent across voices: the same amp value on a TriSin cell and a Ringer cell lands in the same ballpark, and LFOs/knob fades on amp behave the same everywhere. The tradeoff: presets saved under the old `amp²` law play louder below amp 1 (0.5 → 2× / +6 dB) and need re-levelling once.
`─────────────────────────────────────────────────`

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
            \index, 3,
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
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }
```

**Lines 64-98**: constructor + initializer.

Same shape as TriSin's init but with a smaller param set (no FM ratios, no multi-stage envelopes, no filter). Note `index, 3` defaults to medium decay (~6 second release).

The 8 voice subgroups + 8 param-dict copies follow the same pattern as TriSin's init.

## 4. `playVoice` and `trigger`

```supercollider
    playVoice {
        arg voiceKey, freq;
        singleVoices[voiceKey].set(\stopGate, -1.05);
        voiceParams[voiceKey][\freq] = freq;
        Synth.new("Ringer", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
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

**Lines 100-116**: trigger machinery.

`playVoice(voiceKey, freq)` differs from TriSin's in a key way: **no `isPlaying` branch**.

- **`set(\stopGate, -1.05)`** — sends a negative stopGate to any existing synth in this voice's subgroup. Forces them to release immediately. The `-1.05` is a SC magic value (a negative gate that triggers `doneAction: 2` release).
- **Update cached freq** in `voiceParams[voiceKey]`.
- **`Synth.new("Ringer", voiceParams[voiceKey].getPairs, singleVoices[voiceKey])`** — spawn a fresh synth in the subgroup, with the cached params spliced in via `.getPairs`.

Note: NO `isPlaying` branch. Every trigger always spawns a fresh synth because Ringer is one-shot (doneAction:2 frees the synth at envelope end). The pre-trigger `stopGate = -1.05` ensures any old synth (that hasn't yet released) releases now, preventing pile-up.

`trigger(voiceKey, freq)` is the public API. If `voiceKey == 'all'`, fire all 8 voices at the same freq (chord-bomb).

`★ Insight ─────────────────────────────────────`
**The `stopGate, -1.05` pattern is the canonical "fade-then-replace" idiom for one-shot SC voices.** Setting the gate to a negative value triggers the envelope's release with the requested doneAction (here, free). The exact value (-1.05 vs -1.0 vs -2.0) has subtle differences in SC's envelope handling; -1.05 is what naherinlied uses and the script preserves.

**Without the `stopGate, -1.05` before the new Synth.new**, fast retriggers would cause voice pile-up: a new Ringer synth allocated while the previous one's envelope is still in release, both ringing simultaneously. The forced release ensures only one Ringer synth per voice key sounds at a time.

**Compare to TriSin's playVoice**: TriSin checks `isPlaying` and re-triggers the existing synth (because TriSin is persistent, no doneAction:2). Ringer always spawns fresh. The two patterns reflect the two voice lifecycle models.
`─────────────────────────────────────────────────`

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

**Lines 118-135**: identical to TriSin's. Same "set on voice + cache in dict" pattern; `'all'` broadcasts via the outer voiceGroup with one OSC message + 8 cache updates.

## 6. `freeAllNotes` and `free`

```supercollider
    freeAllNotes {
        voiceGroup.set(\stopGate, -1.05);
    }

    free {
        voiceGroup.free;
    }
}
```

**Lines 137-143**: cleanup methods.

`freeAllNotes`:
- **`voiceGroup.set(\stopGate, -1.05)`** — broadcast a forced-release to every active Ringer synth in the outer group. Each synth's envelope enters release mode; doneAction:2 frees each when release completes.

This is the **gentle stop** — notes ring out their releases naturally. Compare to TriSin's `voiceGroup.freeAll`, which would hard-cut every synth (clicky).

For a Ringer chord that's currently sustaining, calling `freeAllNotes` produces a graceful fade-out as each note's natural envelope finishes. This is what makes Ringer's panic-stop behavior musical.

`free`:
- **`voiceGroup.free`** — destroy everything. The instance is dead after this; don't reuse.

The closing `}` ends the class.

## Checkpoint

```supercollider
~lied.allocRinger(\testRing);
~lied.triggerRinger(\testRing, 1, 220);   // a ping at 220 Hz
~lied.triggerRinger(\testRing, 1, 220);   // another ping; previous one releases via stopGate=-1.05
~lied.freeRinger(\testRing);
```

You should hear a single resonant decay, replaced by a new resonant decay on the second trigger (no double-stacking).

## Summary

`Ringer.sc` is 144 lines. The patterns to internalize:

- **One-shot lifecycle with `Env.perc` + `doneAction: 2`**: each trigger spawns a fresh synth that self-frees at release-end.
- **`stopGate, -1.05` before retrigger**: forces previous note to release, preventing pile-up.
- **Dual-purpose `index` arg**: controls both Ringz decay and envelope release time. One knob for character.
- **Ringz + Impulse**: the simplest plucked-string-style synthesis.
- **Gentle `freeAllNotes`**: gate-off broadcast lets envelopes finish naturally.

Compared to TriSin:

| Aspect | TriSin | Ringer |
|---|---|---|
| Lifecycle | Persistent | One-shot (doneAction:2) |
| Envelope | AR with curve | Perc with hardcoded attack |
| Filter | MoogFF + optional env | None |
| FM | Yes (mRatio, cRatio, index, iEnv) | No (just Ringz pinged) |
| Retrigger | `set(t_gate, 1)` on existing Synth | `set(stopGate, -1.05)` + new Synth |
| Args | 33 | 17 |
| freeAllNotes | `voiceGroup.freeAll` (hard) | `voiceGroup.set(\stopGate, -1.05)` (gentle) |

## What's next

**Chapter 07 — Sampler.sc** adds buffer playback with A/B Phasor crossfade — the most sophisticated voice class in the project. It introduces buffer handling, smooth retriggers between sample regions, and a duration-aware envelope.
