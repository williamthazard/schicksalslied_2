# Chapter 07 — `lib/Sampler.sc`

The looping audio-file voice with A/B Phasor crossfade. **212 lines.** The most sophisticated voice class in the project.

## What you'll learn

The key feature: **clickless retriggers between different start/end regions** via a dual-Phasor + crossfade construction. Most sample-playback SynthDefs produce clicks when the read position jumps; this one smoothly transitions. After this chapter you'll understand:

- The `ToggleFF + Latch + Lag` pattern for A/B crossfade.
- Signed playback rate via SC's "boolean as signal" trick.
- Duration-aware envelope shaping.
- Why `LeakDC.ar` matters before FX sends.

## Prerequisites within the tutorial

- Chapter 05 (voice-pool pattern, `*initClass + StartUp.add`, persistent-voice retrigger).

## Source sections

1. Header + class declaration (lines 1-12)
2. `*initClass` + SynthDef (lines 13-104)
3. `*new` + `init` (lines 106-146)
4. `triggerVoice` (lines 148-164)
5. `trigger`, `adjustVoice`, `setParam` (lines 166-192)
6. `resetVoices` and `free` (lines 194-211)

## 1. Header and class declaration

```supercollider
// lib/Sampler.sc — long-file sampler with Phasor + BufRd crossfade
// Ported from naherinlied's \PlayBufPlayer SynthDef (naherinlied.scd:98-189),
// wrapped in a class for consistent retrigger / param-update idiom.
Sampler {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
    var <buffer;
```

**Lines 1-12**: class declaration.

The header notes the port: naherinlied's `\PlayBufPlayer` SynthDef became this class's main SynthDef. The voice-pool pattern (chapter 05) is applied to it — same `voiceKeys`/`globalParams`/`voiceParams`/`singleVoices` structure plus a `buffer` field holding the Buffer reference.

## 2. `*initClass` + SynthDef

```supercollider
    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef(\Sampler, {
                    arg bufnum = 0,
                        rate = 1,
                        start = 0,
                        end = 1,
                        t_trig = 0,
                        loops = 1,
                        amp = 0.2,
                        amp_slew = 0.05,
                        pan = 0,
                        pan_slew = 1,
                        cutoff = 12000,
                        cutoff_slew = 0.05,
                        resonance = 1,
                        rateSlew = 0.1,
                        dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                        dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;
```

**Lines 13-36**: class init + SynthDef args.

24 args. Notable ones:

- **`bufnum = 0`** — the buffer number. Set per-instance from constructor.
- **`rate = 1`** — playback rate. 1 = native; -1 = reverse; 0 = freeze.
- **`start = 0, end = 1`** — buffer region. Normalized 0-1.
- **`t_trig = 0`** — trigger.
- **`loops = 1`** — number of times to loop the region per trigger.
- **`amp, amp_slew, pan, pan_slew, cutoff, cutoff_slew, resonance, rateSlew`** — standard mix + filter + slew params.
- **Send buses + levels** — same shape as TriSin/Ringer.

### The A/B crossfade machinery

```supercollider
                    var snd, snd2, pos, pos2, frames, duration, env, sig, ampSig,
                        startA, endA, startB, endB, crossfade, aOrB, filtered;

                    aOrB = ToggleFF.kr(t_trig);
                    startA = Latch.kr(start, aOrB);
                    endA   = Latch.kr(end,   aOrB);
                    startB = Latch.kr(start, 1 - aOrB);
                    endB   = Latch.kr(end,   1 - aOrB);
                    crossfade = Lag.ar(K2A.ar(aOrB), 0.1);
```

**Lines 37-46**: the A/B crossfade machinery — the most novel construction in the file.

- **`aOrB = ToggleFF.kr(t_trig)`** — a flip-flop. Every time `t_trig` fires (transitions 0→1), `aOrB` toggles between 0 and 1.

- **`startA = Latch.kr(start, aOrB)`** — captures the CURRENT value of `start` when `aOrB` changes. `Latch.kr(input, trig)` returns the input's value at the last trigger; in between triggers, the latched value stays the same. So `startA` holds the start value as of the most recent transition to aOrB=1.

- **`startB = Latch.kr(start, 1 - aOrB)`** — captures start when `aOrB` transitions the OTHER direction. So `startB` holds the start value as of the most recent transition to aOrB=0.

- **`endA, endB`** — same pattern for end positions.

- **`crossfade = Lag.ar(K2A.ar(aOrB), 0.1)`** — convert the kr toggle to ar (`K2A.ar`), then lag-smooth over 100 ms. This produces a slewing signal that ramps from 0 to 1 (or 1 to 0) over 100 ms whenever `aOrB` changes.

The effect: when you trigger the synth twice, the first trigger captures one set of (start, end) values into the A latches; the second trigger captures the NEW values into the B latches. The crossfade signal slews from A's region to B's region over 100 ms.

`★ Insight ─────────────────────────────────────`
**`ToggleFF + Latch + Lag` is the canonical SC pattern for A/B crossfading.** ToggleFF gives you the flip-flop control signal; Latch captures the input on each toggle; Lag (with K2A for audio rate) slews between them. It's a few lines but it's exactly the right combination of UGens to produce smooth A/B swaps.

**This pattern works for any "swap between two states smoothly on trigger" use case.** A/B sample regions, A/B filter cutoff values, A/B pitch sets, A/B anything. The 100 ms lag is the slew time; adjust to taste.
`─────────────────────────────────────────────────`

### Rate + duration + envelope

```supercollider
                    rate = Lag.kr(rate, rateSlew) * BufRateScale.kr(bufnum);
                    frames = BufFrames.kr(bufnum);
                    duration = frames * (end - start) / rate.abs / s.sampleRate * loops;

                    env = EnvGen.ar(
                        Env.new(
                            levels: [0, amp, amp, 0],
                            times:  [0.005, max(0.001, duration - 0.105), 0.1]),
                        gate: t_trig,
                    );
```

**Lines 47-56**: rate calculation + duration + envelope.

- **`rate = Lag.kr(rate, rateSlew) * BufRateScale.kr(bufnum)`** — slew the user's rate AND scale by the buffer's native rate.
- **`frames = BufFrames.kr(bufnum)`** — total frame count of the buffer.
- **`duration = frames * (end - start) / rate.abs / s.sampleRate * loops`** — compute the playback duration in seconds. The region length in frames is `frames * (end - start)`; divide by `rate.abs` (samples-per-frame at this rate); divide by `s.sampleRate` (frames-per-second); multiply by `loops`.

- **`env`**: a 4-segment envelope: 0 → amp → amp → 0. The segments are 0.005 / `max(0.001, duration - 0.105)` / 0.1 seconds. So: a 5 ms attack, hold for `duration - 105ms`, and a 100 ms release. The `max(0.001, ...)` guards against very short durations producing a negative hold time.

`t_trig` gates the envelope (restart from segment 0 on each fire).

`★ Insight ─────────────────────────────────────`
**The duration-aware envelope** is what makes the Sampler clean-sounding even with frequent retriggers. By scheduling the release at the END of the buffer region's playback, the synth fades out exactly when the region completes. Without this, the synth would play through the region and continue producing silence (or wrap around if loops > 1) without any envelope shaping.
`─────────────────────────────────────────────────`

### The Phasors

```supercollider
                    pos = Phasor.ar(
                        trig: aOrB,
                        rate: rate,
                        start: (((rate > 0) * startA) + ((rate < 0) * endA)) * frames,
                        end:   (((rate > 0) * endA)   + ((rate < 0) * startA)) * frames,
                        resetPos: (((rate > 0) * startA) + ((rate < 0) * endA)) * frames,
                    );

                    snd = BufRd.ar(
                        numChannels: 2,
                        bufnum: bufnum,
                        phase: pos,
                        interpolation: 4,
                    );

                    pos2 = Phasor.ar(
                        trig: (1 - aOrB),
                        rate: rate,
                        start: (((rate > 0) * startB) + ((rate < 0) * endB)) * frames,
                        end:   (((rate > 0) * endB)   + ((rate < 0) * startB)) * frames,
                        resetPos: (((rate > 0) * startB) + ((rate < 0) * endB)) * frames,
                    );

                    snd2 = BufRd.ar(
                        numChannels: 2,
                        bufnum: bufnum,
                        phase: pos2,
                        interpolation: 4,
                    );
```

**Lines 58-86**: the dual Phasors + dual BufRds.

The cleverness is in the start/end computation:

```
start: (((rate > 0) * startA) + ((rate < 0) * endA)) * frames
end:   (((rate > 0) * endA)   + ((rate < 0) * startA)) * frames
```

`(rate > 0)` evaluates to 1.0 if rate is positive, 0.0 otherwise (SC's "boolean as signal" trick). So:

- If `rate > 0`: start = `startA * frames`, end = `endA * frames`. Forward playback.
- If `rate < 0`: start = `endA * frames`, end = `startA * frames`. Reverse playback (Phasor decrements toward startA).
- If `rate == 0`: both terms are 0; the Phasor freezes at its current position.

This is what gives Sampler its directional flexibility — positive rate plays forward, negative plays backward, zero freezes.

`BufRd.ar(numChannels, bufnum, phase, interpolation)`:
- `numChannels: 2` — read 2 channels (stereo).
- `phase: pos` — read at the position specified by the Phasor.
- `interpolation: 4` — cubic interpolation (smoothest).

The B Phasor + BufRd is identical, but triggered by `(1 - aOrB)` and using `startB/endB`.

### Crossfade + filter + sends

```supercollider
                    filtered = MoogFF.ar(
                        in: (crossfade * snd) + ((1 - crossfade) * snd2) * env,
                        freq: cutoff.lag3(cutoff_slew),
                        gain: resonance);

                    sig = Balance2.ar(filtered[0], filtered[1], pan.lag3(pan_slew));

                    ampSig = amp.lag3(amp_slew);
                    Out.ar(dry_bus,    LeakDC.ar(sig) * ampSig * dry_send.lag3(0.05));
                    Out.ar(reverb_bus, LeakDC.ar(sig) * ampSig * reverb_send.lag3(0.05));
                    Out.ar(delay_bus,  LeakDC.ar(sig) * ampSig * delay_send.lag3(0.05));
                    Out.ar(gran_bus,   LeakDC.ar(sig) * ampSig * granular_send.lag3(0.05));
                }).add;
            }
        }
    }
```

**Lines 88-104**: crossfade + filter + balance + sends.

The crossfade: `(crossfade * snd) + ((1 - crossfade) * snd2)`. When crossfade slews from 0 to 1, the output transitions from snd2-only to snd-only over 100 ms.

`MoogFF.ar` filters the crossfaded output; `Balance2.ar(L, R, pan)` is a stereo balance (pan position from -1 to 1 controls L/R levels).

`LeakDC.ar(sig)` is a DC-blocking high-pass filter. Inserted before each send because BufRd output can have DC offset (especially after rate changes, MoogFF behavior, etc.), and accumulating DC offset on the buses can affect dynamics.

## 3. `*new` + `init`

```supercollider
    *new { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        buffer = buf;
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \bufnum, buf.bufnum,
            \rate, 1,
            \start, 0,
            \end, 1,
            \loops, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 1,
            \cutoff, 12000,
            \cutoff_slew, 0.05,
            \resonance, 1,
            \rateSlew, 0.1,
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

**Lines 106-146**: constructor + init.

`*new` takes a `buf` arg (the audio buffer) plus the four bus indices. The constructor stores `buffer = buf` and passes `buf.bufnum` (the integer bufnum) into the globalParams dict.

Defaults:
- `rate: 1`, `start: 0, end: 1` — play the whole buffer forward at native rate.
- `loops: 1` — once through.
- `amp: 0.5` — moderate level.

The 8-subgroup pattern is identical to other voice classes.

## 4. `triggerVoice`

```supercollider
    triggerVoice {
        arg voiceKey, startPos, endPos, rate = 1;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\start] = startPos;
            voiceParams[voiceKey][\end]   = endPos;
            voiceParams[voiceKey][\rate]  = rate;
            singleVoices[voiceKey].set(\start, startPos, \end, endPos, \rate, rate, \t_trig, 1);
        }, {
            voiceParams[voiceKey][\start] = startPos;
            voiceParams[voiceKey][\end]   = endPos;
            voiceParams[voiceKey][\rate]  = rate;
            Synth.new(\Sampler, voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_trig, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }
```

**Lines 149-164**: trigger with start, end, rate.

Same `isPlaying` branch pattern as TriSin:

- **If alive**: update cached values, then one combined `set(\start, \end, \rate, \t_trig=1)`. The combined set is critical — by setting all four args in one OSC message, the A/B crossfade machinery (which depends on `start, end` being captured when `aOrB` toggles) sees the NEW values at the moment of the toggle.
- **If not alive**: cache + allocate fresh + set t_trig + NodeWatcher.

If you're tracking why combined sets matter for the A/B crossfade: the SynthDef's `Latch.kr(start, aOrB)` captures the value of `start` at the moment of the trigger. By setting `\start` and `\t_trig` in the same OSC message, we ensure the latch captures the new value, not the old one.

## 5. `trigger`, `adjustVoice`, `setParam`

```supercollider
    trigger {
        arg voiceKey, startPos, endPos, rate = 1;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.triggerVoice(vK, startPos, endPos, rate); });
        }, {
            this.triggerVoice(voiceKey, startPos, endPos, rate);
        });
    }

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

**Lines 166-192**: standard cross-voice control methods. Identical structure to TriSin's analogous methods (chapter 05). The only difference: `trigger` takes start/end/rate args.

## 6. `resetVoices` and `free`

```supercollider
    resetVoices {
        var s = Server.default;
        voiceKeys.do({ arg voiceKey;
            if (singleVoices[voiceKey].notNil) {
                singleVoices[voiceKey].free;
            };
            singleVoices[voiceKey] = Group.new(voiceGroup);
        });
    }

    free {
        voiceGroup.free;
    }
}
```

**Lines 199-211**: panic recovery + cleanup.

`resetVoices`: for each voice key, free the existing subgroup (and any synth inside) and create a fresh empty subgroup. Used by `Lied.silenceAllSamplers` for K1 panic recovery — destroys + recreates the subgroups, keeping the instance alive.

After this, every voice key has an empty subgroup. The next trigger on any voice key will take the "allocate fresh" branch in `triggerVoice` because `isPlaying` returns false on the fresh empty group.

`free`: free the outer group + everything inside.

`★ Insight ─────────────────────────────────────`
**The reset-vs-free distinction**: `voiceGroup.free` (in `free`) destroys the whole hierarchy — instance is dead. `resetVoices` destroys just the inner subgroups, recreating them empty — instance is alive but silenced. Different semantics for different use cases.
`─────────────────────────────────────────────────`

## Checkpoint

```supercollider
~b = Buffer.read(s, "/path/to/your/file.wav");
// (Wait for the buffer load)
~lied.loadSampler... // covered in chapter 03; for sclang-only testing you'd construct Sampler.new(~b, ...) directly
~lied.triggerSampler(1, 1, 0, 1, 1);    // play full buffer at rate 1
~lied.triggerSampler(1, 1, 0.3, 0.6, 1); // retrigger from 30% to 60% — should crossfade smoothly
~lied.clearSampler(1);
~b.free;
```

You should hear clickless segment changes, with an audible 100 ms crossfade between regions.

## Summary

`Sampler.sc` is 212 lines. The patterns to internalize:

- **A/B Phasor + Latch + Lag crossfade**: smooth retriggers between different start/end regions.
- **Signed rate via "boolean as signal"**: `(rate > 0) * start + (rate < 0) * end` selects forward or reverse direction.
- **Duration-aware envelope**: envelope's hold time computed from buffer region length / rate, ensuring graceful fade-out at region end.
- **Combined `set(start, end, rate, t_trig=1)`**: atomic update + trigger in one OSC message, critical for A/B latch correctness.
- **`LeakDC.ar` before sends**: prevents DC offset accumulation on FX buses.
- **`resetVoices` for panic recovery**: destroy + recreate subgroups, keeping the instance alive.

## What's next

**Chapter 08 — OneShot.sc** is the simplest voice class — a one-shot sample-playback voice with no looping and no A/B crossfade. Used for percussive samples (kicks, snares, vocal stabs). Despite the name, it's persistent (no doneAction:2) — the "one-shot" refers to playing the buffer once per trigger.
