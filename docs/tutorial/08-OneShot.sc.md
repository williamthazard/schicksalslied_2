# Chapter 08 — `lib/OneShot.sc`

The simple one-shot sample voice. **175 lines.** Despite the name, OneShot is **persistent** (no `doneAction: 2`). The "one-shot" refers to the sample playing through once per trigger — not to the synth's lifecycle. The persistence enables long samples to be faded out mid-playback via `group.set(\amp, 0)`.

## What you'll learn

How the voice-pool pattern specializes for simple buffer playback. After this chapter:

- You'll understand the simplest sample-playback signal chain (`PlayBuf` → filter → balance → sends).
- You'll see the `triggerWithRate` variant: combined param + trigger update in one OSC message.
- You'll understand why OneShot is intentionally persistent (vs. self-freeing).

## Prerequisites within the tutorial

- Chapter 05 (voice-pool pattern). Chapter 07's Sampler covers the more complex BufRd-based playback; OneShot is essentially the simplification of that.

## Source sections

1. Header + class declaration (lines 1-14)
2. `*initClass` + `*addSynthDefs` (the SynthDef) (lines 16-55)
3. `*new` + `init` (lines 57-94)
4. `playVoice` (lines 96-105)
5. `triggerWithRate` (lines 107-123)
6. `trigger`, `buffer`, `adjustVoice`, `setParam` (lines 125-155)
7. `resetVoices` (lines 157-170)
8. `free` (lines 172-174)

## 1. Header and class declaration

```supercollider
// lib/OneShot.sc — persistent one-shot sampler with .lag3 on amp + cutoff
// Upgrade of naherinlied's OneShot: fixes the double-amp-multiplication
// bug (1.x multiplied amp twice in the signal chain), makes the synth
// persistent (no doneAction:2) so long samples can be faded out
// mid-playback via group.set(\amp, 0), adds .lag3 smoothing on amp AND
// cutoff.
OneShot {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
    var <buffers;
```

**Lines 1-14**: class declaration with detailed header.

The header documents two upgrades from naherinlied's OneShot:

1. **Fixed double-amp bug**: 1.x multiplied amp twice in the signal chain, producing an `amp²` response curve. This version multiplies amp once.
2. **Persistent lifecycle**: dropped `doneAction: 2`. The synth stays alive after playback ends so the user can fade it out mid-playback (without a fade, the synth would auto-free at end-of-buffer and any in-progress fade would be cut short).
3. **`.lag3` smoothing** on amp AND cutoff for click-free parameter changes.

The instance variables match the Sampler class structure: `globalParams`, `voiceParams`, `voiceGroup`, `singleVoices`, plus `buffers`: an **Array** of loaded audio Buffers. A single-file slot holds a one-element Array; a folder slot holds one Buffer per file, and each trigger's `bufIdx` picks which one plays.

`★ Insight ─────────────────────────────────────`
**The "fixed bug" comment matters even for ported code.** It's tempting to preserve quirks "for backward compatibility" — but if the quirk is a clear bug (here, an unintentional `amp²` response), fixing it is the right call. Document the change in a comment so future maintainers know it's intentional and not a regression to revert.

**The persistence trade-off**: persistent = can fade out long samples mid-playback (good); persistent = dead OneShot nodes accumulate on the server (bad, but reuse pattern handles it). The `playVoice` reuse pattern keeps the node count bounded.
`─────────────────────────────────────────────────`

## 2. `*initClass` + `*addSynthDefs` (the SynthDef)

```supercollider
    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
    }

    // Added by Lied.init once Crone has booted the server — never from a
    // StartUp hook, which runs at every sclang start and could boot scsynth
    // before Crone had set it up.
    *addSynthDefs {
        SynthDef("OneShot", {
            arg t_gate = 0,
                rate = 1,
                cutoff = 12000,
                cutoff_slew = 0.05,
                resonance = 1,
                amp = 0.5,
                amp_slew = 0.05,
                amp_scale = 1.0,
                pan = 0,
                pan_slew = 0.5,
                buf = 0,
                dry_bus = 0, reverb_bus = 0, delay_bus = 0, gran_bus = 0,
                dry_send = 1, reverb_send = 0, delay_send = 0, granular_send = 0;

            var sig, filter, signal, ampSig;
            // Buffers are always 2-channel (Lied reads mono files into
            // both channels). Balance2 on a dual-mono pair gives the
            // same levels Pan2 gave the mono signal at every pan
            // position; stereo files keep their image.
            sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf) * rate, t_gate);
            filter = MoogFF.ar(sig, cutoff.lag3(cutoff_slew), resonance);
            signal = Balance2.ar(filter[0], filter[1], pan.lag3(pan_slew));

            // Post-fader: amp scales all 4 sends. No doneAction:2 — synth is persistent.
            ampSig = amp.lag3(amp_slew) * amp_scale;
            Out.ar(dry_bus,    signal * ampSig * dry_send.lag3(0.05));
            Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
            Out.ar(delay_bus,  signal * ampSig * delay_send.lag3(0.05));
            Out.ar(gran_bus,   signal * ampSig * granular_send.lag3(0.05));
        }).add;
    }
```

**Lines 16-55**: `*initClass`, then `*addSynthDefs` and SynthDef. As in TriSin (chapter 05), `*initClass` only sets `voiceKeys`; the SynthDef lives in `*addSynthDefs`, which `Lied.init` calls once Crone has booted the server (a `StartUp.add`/`waitForBoot` hook here could boot scsynth before Crone configured it).

The SynthDef has 19 args. Simpler than TriSin (34) and even simpler than Sampler (which has the A/B crossfade machinery). The signal chain:

1. **`PlayBuf.ar(numChannels, bufnum, rate, trigger)`** — read samples from `buf` at the given rate. `numChannels = 2` because every buffer `Lied.sc` hands to OneShot is 2-channel (`readStereoBuffer`, chapter 03): stereo files as-is, mono files (drums, vocal stabs) read into both channels, files with more channels trimmed to the first two. `BufRateScale.kr(buf) * rate` is the sample-rate-adjusted playback rate.
2. **`MoogFF.ar`** — resonant lowpass with slewed cutoff.
3. **`Balance2.ar(filter[0], filter[1], pan)`** — stereo balance with slewed position, applied to the filtered left and right channels. This replaced `PlayBuf.ar(1)` + `Pan2.ar`, which played only the left channel of a stereo file. For a **mono** file the two channels are identical, and `Balance2` uses the same equal-power sine table as `Pan2` (about 0.707 per side at pan 0, full level on one side at the extremes), so mono files sound exactly as they did with `Pan2` at every pan position. Stereo files now keep their stereo image, with `pan` acting as a balance control. (Sampler already works this way, chapter 07.)
4. **Four `Out.ar` calls** to the four FX buses.

`amp_scale` (default 1.0) is a per-hit multiplier applied on top of the smoothed `amp`: the accent system sends a boost or reduction with each trigger (it is not smoothed, so it takes effect on the hit that carries it). `t_gate = 0` is the trigger. PlayBuf's last arg is the trigger; when it transitions from 0 to non-zero, PlayBuf restarts from the beginning of the buffer.

**No envelope**. The PlayBuf reaches the end of the buffer and continues outputting silence (or, depending on PlayBuf's loop setting which defaults to no-loop, it just stops generating samples and outputs zeros). The synth stays alive.

`★ Insight ─────────────────────────────────────`
**`BufRateScale.kr(buf) * rate`** is the canonical way to play a buffer at "native rate × user rate." `BufRateScale.kr` returns the ratio `buf.sampleRate / server.sampleRate` — typically 1.0 unless your buffer has a different SR than the server. Multiplying by `rate` lets the user transpose: `rate = 2` plays an octave up, `rate = 0.5` plays an octave down, `rate = -1` plays in reverse.

**`PlayBuf.ar` with `t_gate` as the trigger arg**: standard SC pattern for retriggerable sample playback. Setting `t_gate = 1` restarts from the buffer's start. The `t_` prefix marks it as a transient — SC auto-resets it to 0 the next block.

**Why no `doneAction: 2`?** Because the SynthDef doesn't have an envelope that "ends." Without an envelope, there's no signal saying "playback is done." The synth would have to be freed explicitly via `playbuf.done` triggering an `EnvGen` with `doneAction: 2`, but that defeats the persistence we want.
`─────────────────────────────────────────────────`

## 3. `*new` + `init`

```supercollider
    *new { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        ^super.new.init(buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx);
    }

    init { arg buf, dryBusIdx, reverbBusIdx, delayBusIdx, granularBusIdx;
        var s = Server.default;

        buffers = if (buf.isArray) { buf } { [buf] };
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \cutoff, 12000,
            \cutoff_slew, 0.05,
            \resonance, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 0.5,
            \buf, buffers[0].bufnum,
            \amp_scale, 1.0,
            \rate, 1,
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

**Lines 57-94**: constructor + init.

`*new` takes a `buf` arg plus the four bus indices. `buf` may be a single Buffer or an **Array of Buffers** (`Lied.installOneShot` always passes an Array); `buffers = if (buf.isArray) { buf } { [buf] }` normalizes both to an Array. The first buffer's integer `bufnum` goes into the globalParams dict as the default `buf` — the SynthDef's `buf` arg takes a bufnum integer, not a Buffer object.

Otherwise the init mirrors TriSin's and Ringer's: voiceGroup, globalParams, 8 voice subgroups, 8 voiceParams copies.

## 4. `playVoice`

```supercollider
    playVoice {
        arg voiceKey;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\t_gate, 1);
        }, {
            Synth.new("OneShot", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }
```

**Lines 96-105**: play a voice. Same structure as TriSin's playVoice (chapter 05):

- **If alive**: just `set(\t_gate, 1)`. PlayBuf restarts from the buffer's beginning.
- **If not alive**: allocate fresh + set t_gate + register with NodeWatcher.

Note `playVoice` takes only `voiceKey` (no freq, no start/end). One-shots have no per-trigger freq because their pitch comes from the playback rate (which is a param set separately, not per-trigger).

## 5. `triggerWithRate`

```supercollider
    triggerWithRate {
        arg voiceKey, rate = 1, bufIdx = 0, ampScale = 1.0;
        var targetBuf = buffers.wrapAt(bufIdx);
        voiceParams[voiceKey][\rate] = rate;
        voiceParams[voiceKey][\buf] = targetBuf.bufnum;
        voiceParams[voiceKey][\amp_scale] = ampScale;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\rate, rate, \buf, targetBuf.bufnum, \amp_scale, ampScale, \t_gate, 1);
        }, {
            Synth.new("OneShot", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }
```

**Lines 107-123**: trigger with a specific rate, buffer and accent scale, set + fire in one OSC round-trip.

This is what `Lied.triggerOneShot` calls (which is what `engine.oneshot_trigger` ultimately invokes). The args are voice key, `rate`, `bufIdx` (which buffer of the slot to play) and `ampScale` (the accent multiplier). The function:

1. **Pick the buffer**: `buffers.wrapAt(bufIdx)` wraps out-of-range indices around instead of failing, so a stale index can never hit a missing buffer.
2. **Cache** rate, bufnum and amp_scale in `voiceParams[voiceKey]`.
3. **If alive**: set `\rate`, `\buf`, `\amp_scale` and `\t_gate` in one `set` call (one OSC message). PlayBuf restarts on the chosen buffer at the new rate.
4. **If not alive**: allocate fresh (with current `voiceParams` including the just-cached values), set t_gate, register.

The combined `set(...)` in the alive branch is important: setting these together means the rate / buffer / accent change AND the retrigger happen in the same audio block. Setting them separately would risk a one-block period where the rate is updated but the trigger hasn't fired yet.

`★ Insight ─────────────────────────────────────`
**Combining param sets into one `set` call is an OSC optimization**. `singleVoices[voiceKey].set(\rate, rate)` and `singleVoices[voiceKey].set(\t_gate, 1)` would be two separate OSC messages with two round-trips through the network stack. Combining: `set(\rate, rate, \t_gate, 1)` is one OSC message with two param updates. Faster and atomic at the audio-block level.

**Why have both `playVoice` and `triggerWithRate`?** Because some callers might want to trigger without changing rate (just retrigger the current rate). `playVoice` is the "no args, just fire" version; `triggerWithRate` is the "fire with this specific rate" version. The script's Lua side uses `triggerWithRate` exclusively (via `engine.oneshot_trigger`).
`─────────────────────────────────────────────────`

## 6. `trigger`, `adjustVoice`, `setParam`

```supercollider
    trigger {
        arg voiceKey;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK); });
        }, {
            this.playVoice(voiceKey);
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

**Lines 125-155**: standard trigger, adjustVoice, setParam, plus a small `buffer` getter that returns `buffers[0]`. Identical patterns to TriSin/Ringer (chapter 05).

`trigger` delegates to `playVoice` (no rate change). Useful for callers that want to fire without modifying rate. Note `'all'` distribution iterates the 8 voice keys.

`adjustVoice` and `setParam` are word-for-word identical to TriSin's versions.

## 7. `resetVoices`

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
```

**Lines 157-170**: reset all voice subgroups for panic recovery.

For each voice key:
1. Free the existing subgroup (and any synth inside it).
2. Create a fresh empty subgroup.

After this, every voice key has an empty subgroup. The next trigger on any voice key will:
- Check `singleVoices[voiceKey].isPlaying` → false (fresh empty group).
- Take the "allocate fresh" branch in `playVoice` / `triggerWithRate`.
- Spawn a new Synth.

The comment notes this is "post-K1-panic recovery" — when the user hits K1 panic, `Lied.silenceAllOneShots` calls `resetVoices` on each OneShot instance. The result: every voice goes silent, but the next trigger still works (because the subgroups exist, just empty).

## 8. `free`

```supercollider
    free {
        voiceGroup.free;
    }
}
```

**Lines 172-174**: free the outer group + everything inside.

The closing `}` ends the class.

## Checkpoint

```supercollider
~lied.loadOneShot(1, "/path/to/a/drum/hit.wav");  // slot 1; folders go through loadOneShotFiles(slot, "path1\npath2")
~lied.triggerOneShot(1, \1, 1);    // play at rate 1
~lied.triggerOneShot(1, \1, 0.5);  // play at half speed (octave down)
~lied.triggerOneShot(1, \1, -1);   // play in reverse
~lied.triggerOneShot(1, \1, 1, 0, 1.6); // buffer 0, accented (x1.6)
~lied.setOneShotParam(1, \amp, 0); // fade to silence mid-playback
~lied.clearOneShot(1);
```

You should hear the file playing through with the modified rate, then fading via the amp slew.

## Summary

`OneShot.sc` is 175 lines. The patterns to internalize:

- **Persistent lifecycle**: synth stays alive after playback ends. Enables mid-playback fade-out via group.set(amp, 0).
- **Combined `set(rate, t_gate, 1)`**: atomic param + trigger update in one OSC message.
- **19 args**: smaller than TriSin's 34, a little larger than Ringer's 18. Roughly the median for voice classes.
- **`resetVoices` for panic recovery**: destroy + recreate subgroups, keeping the instance alive.
- **Shared structure with TriSin/Ringer/Sampler**: voiceKeys, voiceParams template, isPlaying-branch retrigger, etc.

Comparison to the other voice classes:

| Aspect | TriSin | Ringer | OneShot | Sampler |
|---|---|---|---|---|
| Persistent | yes | no | yes | yes |
| Trigger args | freq | freq | rate, buffer index, accent scale | start, end, rate |
| FM | yes | no | no | no |
| Filter | MoogFF + env | none | MoogFF | MoogFF |
| Envelope | AR + curve | Perc + doneAction:2 | none | none |
| resetVoices | no | no | yes | yes |
| Buffer-based | no | no | yes | yes |

OneShot sits in the middle of the lineage: simpler than Sampler (no A/B crossfade), simpler than TriSin (no FM), but more capable than Ringer (full buffer playback rather than a single impulse decay). It's the right voice class to use for short percussive samples or vocal stabs where you want a clean play-once-on-trigger behavior.

## What's next

**Chapter 09 — Norns Lua Foundations** pivots to the Lua side. We'll cover the Norns-specific Lua idioms this script depends on: `params:add{...}`, the `clock.sync` / `clock.sleep` distinction, the `sequins` library, the `grid.key` / `grid.led` handler shape, the screen drawing API, and Norns's `include` (which is *not* a caching require). By the end of chapter 09, you'll be ready for the script-specific Lua of chapters 10-19.
