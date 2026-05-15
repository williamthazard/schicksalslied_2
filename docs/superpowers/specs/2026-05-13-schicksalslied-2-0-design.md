# schicksalslied 2.0 — Design

**Date:** 2026-05-13
**Status:** Approved (brainstorm complete, awaiting implementation plan)
**Scope:** Major rewrite of `schicksalslied` (monome norns poetry sequencer), porting the additions naherinlied gained over its norns sibling and adding the Carter's-delay granular chain. Drops voice complexity (`tritri`, `sinsin`, `karplu`, `resonz`) and the FormantTriPTR external UGen install dance. Replaces softcut with SuperCollider samplers. Adopts a per-cell-sequins grid model with a configurable role enum for row-2 cells.
**Reference projects in this workspace:** `naherinlied/` (the donor: row-banded grid layout, voice classes, SC sampler, granular delay); `norns-ritual/` (the resource-management exemplar: Phasor-keeps-running mute idiom, `track_amp.lag()` on every voice, group-based real-time amp control).
**Reference external scripts:** [`carters-delay-norns`](https://github.com/williamthazard/carters-delay-norns) (proven Norns port of the granular delay; design source for Section 6); [`cheat_codes_2`](https://github.com/dndrks/cheat_codes_2), [`paracosms`](https://github.com/schollz/paracosms) (param-heavy Norns scripts demonstrating menu navigation patterns at scale).

---

## 1. Goals & non-goals

### Goals

- Bring naherinlied's expressive feature set (16-column polyphonic synth/sampler/drum grid, per-cell sequins, SC-side sampler with crossfade, granular delay) back into `schicksalslied` on monome norns.
- Add the `carters-delay-norns` granular delay chain (16 grain synths, mic-fed delay buffer, `fbPatchMix` feedback chain) as a first-class part of the script.
- Establish ritual-style real-time control discipline: every voice supports `group.set(\amp, x)` mid-sound, smoothed by `.lag()`. Turning a voice down audibly fades the playing notes, not just the next trigger.
- Make every setup-relevant param PSET-savable so a performer can build a setup, save it, and recall it (or recall one of several saved setups).
- Keep CPU within Norns's budget. SC crackle is a hard fail for performance.

### Non-goals

- The particle-physics screen UI from naherinlied (won't fit on 128×64). Screen is text + history list as in 1.x.
- The Lissajous scope window (SC GUI, not applicable on Norns).
- The `tritri` voice and FormantTriPTR external UGen install (consolidated away).
- The `sinsin`, `karplu`, `resonz` voices (consolidated under TriSin + Ringer per user judgment that the dropped voices were "different without much distinction").
- Backwards compatibility with 1.x PSETs. The surface area changes too much.
- Softcut use in the script. The SC samplers replace it.

---

## 2. Architecture overview

### File layout (under `schicksalslied/`)

```
schicksalslied.lua            main script — UI, input, params, sequencing
lib/
  Engine_Lied.sc              new CroneEngine — replaces Engine_LiedMotor.sc
  Lied.sc                     SC engine kernel — buses, master FX, mic chain,
                              granular delay, fbPatchMix, sampler registry,
                              one-shot sampler registry
  TriSin.sc                   per-voice class (ported from naherinlied,
                              upgraded with .lag() on mutable params)
  Ringer.sc                   per-voice class (already had .lag() on amp)
  Sampler.sc                  new — SC long-file sampler (Phasor + BufRd
                              crossfade)
  OneShot.sc                  per-voice class (upgraded with .lag() on amp,
                              persistent group)
  cell_roles.lua              new — role enum, defaults, dispatch table
  sequencer.lua               new — per-cell sequins, seq modes, toggle
                              state, clock-loop lifecycle
  wtape_looper.lua            new — the looper choreography extracted from
                              1.x's main script, rewired to per-cell sequins
README.md                     to be rewritten (writing task, not in this spec)
```

**Removed:** `lib/Engine_LiedMotor.sc`, `lib/LiedMotor_engine.lua`, `lib/lied_lfo.lua`, `ignore/FormantTriPTR.sc`, `ignore/FormantTriPTR_scsynth.so`. The whole `ignore/` folder can go away unless we add some other external dependency.

**Standard library used:** `require 'lfo'` (Norns standard library — replaces 1.x's bundled `lied_lfo.lua`, which was a preview of fixes that have since landed in the standard lib).

### Layering

- **`schicksalslied.lua`** orchestrates: keyboard input, History (typed + file-loaded via `Split()` from a `params:add{type='file'}` path, retained from 1.x), screen redraw, params setup, calls into `sequencer.lua` and `cell_roles.lua` for per-cell event handling.
- **`sequencer.lua`** owns runtime state: per-cell `Sequins`, per-cell toggle flags, per-cell clock IDs, the assign-current-string mechanic from odd-row grid presses.
- **`cell_roles.lua`** owns role-dispatch: given a cell `(x, y)` and its current sequins value, fires the right `engine.<command>()` or `crow.ii.*` call.
- **`lib/Lied.sc`** owns SC state: holds the sampler registry (`Dictionary[slot] → Sampler instance`), the one-shot registry (same), the granular delay chain, the master FX, provides methods for `Engine_Lied.sc` to call.
- **`Engine_Lied.sc`** is the Crone shim: pure command registration, no logic.

### Two cross-cutting requirements

**1. Real-time amp control via groups.** Every voice class has a `voiceGroup` and a `.lag()`-smoothed `amp` arg. `group.set(\amp, x)` from the params menu (or via MIDI map / LFO) audibly fades the currently-playing audio, not just the next trigger. This is the "ritual lesson" — without it, schicksalslied 1.x and naherinlied both effectively bake params at trigger time, which is wrong for live performance.

**2. PSET compatibility.** Every "setup" piece of state — per-cell role, file paths, voice params, LFO settings, bus routing, seq-mode choices — lives in `params:add{...}` so PSET captures the full configuration. Transient performance state (`Displayed_String`, `My_String`, History runtime, sequins runtime values, cell toggle flags) is *not* PSET'd — performance content.

---

## 3. Grid layout & cell roles

### Row-by-row

| Row | Behavior | Active cells | Per-cell config? |
|-----|---|---|---|
| 1 | History selector (press = concat line to typing buffer; release = activate; combine by holding multiple) | up to 16 (capped at grid width) | no |
| 2 | Role-configurable sequencer trigger | 16 | **yes (role enum)** |
| 3 | "Assign current `My_String` to this column's row-2 cell sequins" | 16 | no |
| 4 | Sampler row, alternating | 8 trigger + 8 rate-control = samplers 1–8 | no |
| 5 | "Assign current `My_String` to this column's row-4 cell sequins" | 16 | no |
| 6 | Sampler row, alternating | 8 trigger + 8 rate-control = samplers 9–16 | no |
| 7 | "Assign current `My_String` to this column's row-6 cell sequins" | 16 | no |
| 8 | One-shot sampler triggers + mic/granular controls | cols 1–13 = one-shot samplers; cols 14–16 = mic-delay-in / granular-out / mic-dry on/off | no |

Total: 16 (history) + 16 + 16 + 16 + 13 + 3 = ~80 actionable cells.

### Row 2 role enum (per-cell)

`TriSin` · `Ringer` · `crow 1+2` · `crow 3+4` · `JF` · `JF run` · `JF quantize` · `w/syn` · `w/del` · `w/tape looper` · `MIDI`

11 options (10 original + `MIDI` added in Sub-plan C for external sequencer routing). No `off` role — a cell that's toggled off does nothing, regardless of its role; an explicit "off" role would be redundant.

**MIDI role** sends note_on/note_off via a globally-configured MIDI device (built from `midi.vports`). Per-cell `midi_channel` (1-16, hidden unless role=MIDI). Global `midi_gate_time` (seconds, default 0.1) controls note-off latency. Patterned on `tehn/awake.lua`'s idiom: dynamic device list, per-cell active-note tracking, tracked all-notes-off (not CC123 blast).

**Global scale quantization** (Sub-plan C addition): all 10 pitched dispatchers (TriSin/Ringer/crow/JF/w/syn/w/del/MIDI) read the global `scale_mode` and `root_note` params (chromatic default = pass-through = historical schicksalslied behavior). When set to a musical scale, pitches snap via `MusicUtil.snap_note_to_array` to the chosen scale.

`JF` and `w/syn` rely on the modules' **built-in voice allocation** via `crow.ii.jf.play_note(pitch, level)` and `crow.ii.wsyn.play_note(pitch, level)` (see [JF Just-Type docs](https://github.com/whimsicalraps/Just-Friends/blob/main/Just-Type.md) and [w/syn ii docs](https://github.com/whimsicalraps/wslash/wiki/Syn#ii)). No Lua-side round-robin counter required. Voice-count setup commands stay in `crow_reinit()`.

### Default role mapping for row 2

Matches naherinlied's `4 TriSin → 4 Ringer → 4 TriSin → 4 Ringer`:

| col | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| role | TriSin | TriSin | TriSin | TriSin | Ringer | Ringer | Ringer | Ringer | TriSin | TriSin | TriSin | TriSin | Ringer | Ringer | Ringer | Ringer |

Params menu has bulk-set triggers: "set row 2 to all TriSin," "set row 2 to all Ringer," "set row 2 to default mix," "randomize row 2 roles."

### Sampler trigger/rate-control alternation

Rows 4 and 6 follow naherinlied's odd/even convention:

- **Odd columns (1, 3, 5, 7, 9, 11, 13, 15)** trigger the paired sampler. The trigger event uses the cell's sequins value to set the sampler's play position (`start`) and play duration (`end - start`).
- **Even columns (2, 4, 6, 8, 10, 12, 14, 16)** set the playback rate of the paired sampler. The rate event uses the cell's sequins value to set the sampler's `rate` arg, with `rateSlew` smoothing.

Pairing: `(col 1, col 2) → sampler 1`, `(col 3, col 4) → sampler 2`, etc. 8 samplers per row × 2 rows = 16 samplers total.

### Row 8 cols 14–16 (mic/granular controls)

These are **on/off toggles**, not sequencer triggers (row 8's other cells are sequencer triggers for one-shot samplers). Each has a "configured on amp" stored in params:

| Cell | Target synth | Amp param (default) |
|---|---|---|
| col 14, row 8 | `\mic` (mic → delay buffer) | `mic_to_delay_amp` (0.5) |
| col 15, row 8 | all 16 `\gran` synths | `granular_out_amp` (0.3) |
| col 16, row 8 | `\micDry` (mic → main output, dry passthrough) | `mic_dry_amp` (0.5) |

Toggle on → `group.set(\amp, <configured>)` (`.lag()`-smoothed). Toggle off → `set(\amp, 0)`.

### History capacity

Row 1 is 16 slots. Lines beyond the 16th in `History` are accessible only via keyboard UP/DOWN. The `text_file` param can still load .txt files with >16 lines (those extras live in History but are off-grid). Consequence of using only row 1 for history; not a behavior change from naherinlied.

---

## 4. SC engine design

### Class hierarchy (in `lib/`)

| Class | Role | Lifetime |
|---|---|---|
| `Lied` | Kernel — boots SC, owns buses, master FX, granular delay chain, instance registries | persistent |
| `TriSin` | Row-2 voice (FM, ported from naherinlied, `.lag()` on `amp`) | one per row-2 cell, lazy |
| `Ringer` | Row-2 voice (pinged resonant, already has `.lag()` on `amp`) | one per row-2 cell, lazy |
| `Sampler` | Long-file sampler — Phasor + BufRd crossfade | one per loaded row-4/6 slot |
| `OneShot` | Row-8 one-shot sampler with `.lag()` on `amp` (upgraded) | one per loaded row-8 slot |

Each voice class follows the same idiom:

- A top-level `voiceGroup` containing N sub-groups (one per polyphony slot, N = 1–8, default depends on role)
- Round-robin index into the polyphony pool
- A `voiceParams` cache (Dictionary in SC)
- `instance.setParam('all', \amp, x)` calls `voiceGroup.set(\amp, x)` — a single OSC message that affects all currently-playing notes in the pool. Replaces naherinlied's per-sub-group iteration (1 OSC instead of 8).

### The retrigger discipline (key change vs 1.x)

schicksalslied 1.x fires a fresh `Synth.new` per trigger with `doneAction: 2` — meaning param changes only affect the *next* trigger, never currently-sounding notes. 2.0 follows naherinlied + ritual's persistent-Synth idiom:

- **Persistent envelope voices** (TriSin, Sampler, OneShot, mic chain, fbPatchMix, grain synths): one persistent Synth per polyphony slot, no `doneAction:2`. Retrigger via `group.set(\t_gate, 1)`. Real-time param changes hit the live Synth.
- **Perc-style voices** (Ringer): each trigger allocates a fresh Synth with `Env.perc, doneAction:2`. Previous note (if still sounding) gates off via `\stopGate = -1.05`. Real-time `amp` still works on the currently-sounding note before it self-frees.

### Allocation strategy (Approach C — hybrid lazy)

**Persistent at boot:**

- Buses: `dry` (~fb), `reverb-pre` (c), `delay-pre` (b), `mic`, `ptr`
- Master delay + reverb FX
- Full granular delay chain: 1 `\mic`, 1 `\micDry`, 1 `\ptr`, 1 `\rec`, 1 `\fbPatchMix`, 16 `\gran` synths
- 48 SC-side `Ndef`s for grain LFOs (pan, cutoff, resonance — see Section 6)

**Lazy:**

- `TriSin` / `Ringer` instances per row-2 cell (allocate on first trigger after role-set; free on role change or after configurable idle-grace seconds with no triggers). Default idle-grace: 30s, tunable via a global param.
- `Sampler` instances per row-4/6 slot (allocate when a file is loaded; free when file is cleared).
- `OneShot` instances per row-8 slot (allocate when a file is loaded; free when file is cleared).

### Polyphony defaults

- TriSin / Ringer (row 2): **default 4**, configurable 1–8.
- Sampler (rows 4/6): **default 1** (single slot, retrigger replaces). Configurable 1–8.
- OneShot (row 8): **default 1**. Rationale: drum hits typically don't need to overlap with themselves; retrigger replaces is the natural mode. Increase to 2–4 only when stacking is wanted (vocal samples, long field recordings layered on themselves).

### Bus routing per voice

Each voice has a `bus_routing` param: `dry` / `reverb` / `delay+reverb`. Sets the voice's `\bus` SynthDef arg to the corresponding bus index. Signal flow:

```
voice → \bus (one of dry/reverb-pre/delay-pre)
delay-pre → \Delay synth → reverb-pre (chained)
reverb-pre → \Reverb synth → dry
dry → main output
```

Identical to naherinlied's three-bus topology.

---

## 5. Sampler & one-shot sampler design

### Sampler (rows 4 & 6, 16 slots total)

**SynthDef:** Port of naherinlied's `\PlayBufPlayer` — dual `Phasor` + `BufRd` with `ToggleFF`-driven crossfade for click-free retrigger between play windows. `MoogFF` filter (cutoff + resonance), `LeakDC` on output, `Pan2` final. `.lag()` on amp for live MIDI-knob control.

**Args** (live-controllable via `group.set`):

- `t_trig` — retrigger gate (set by trigger row, cols 1/3/5/7/9/11/13/15 of rows 4/6)
- `start`, `end` — play window bounds, set by the trigger cell's `position` and `duration` value-modes per fire (see §7 Value mode). Default (lied mode) matches naherinlied: `start = util.linlin(36, 62, 0, 0.9, byte)`, `end = start + util.linlin(36, 62, 0.001, 0.1, byte)`.
- `rate` — playback rate, set by the rate-control cell's `rate` value-mode per fire (see §7 Value mode), with `rateSlew` smoothing
- `amp`, `amp_slew`, `cutoff`, `resonance` — params-menu controls, `.lag()`-smoothed
- `pan`, `pan_slew`, `bus` — same idiom as other voices
- `loops` — fixed at 1 (single window pass per trigger; looping is from sequencer re-triggering, not from PlayBuf looping)

**Buffer loading:** 16 `params:add{type='file', id='sampler_<N>_file'}` (PSET-savable). When a file is selected, `engine.sampler_load(slot, path)` is called. The kernel:

1. Allocates a `Buffer.read` for the file.
2. Lazy-allocates a `Sampler` SC class instance bound to that buffer.
3. Stores it in the `Lied` registry under `slot`.
4. Sets the instance's `\bus`/`\amp`/etc. from cached param values.

When a file is cleared (file param set to nil/empty), the `Sampler` instance is freed and the buffer is released. Empty slots cost zero CPU.

### One-shot sampler (row 8 cols 1–13, 13 slots)

**Important framing:** these are *generic SC one-shot samplers*, not necessarily percussive. They can hold drum hits, vocal samples, field recordings, or anything else. The "drum" label from naherinlied is too narrow. Real-time amp control is critical — a 20-minute field recording playing during a set must be fade-able to silence via a MIDI knob, not just stoppable on next trigger.

**SynthDef (2.0 version):**

```supercollider
SynthDef("OneShot", {
    arg t_gate=0, rate=1, cutoff=12000, resonance=1, amp=0.5, amp_slew=0.05,
        pan=0, pan_slew=0.5, buf=0, bus=0;
    var sig = PlayBuf.ar(1, buf, BufRateScale.ir(buf) * rate, t_gate);
    var filter = MoogFF.ar(sig, cutoff, resonance);
    var signal = Pan2.ar(filter, pan.lag3(pan_slew));
    Out.ar(bus, signal * amp.lag3(amp_slew));
}).add;
```

Single `amp` multiplication (1.x's double-multiplication bug fixed), `.lag3()` smoothing. **The Synth is persistent (no `doneAction:2`).** A long field recording can be faded out mid-playback via `group.set(\amp, 0)` with a slow `amp_slew`. PlayBuf's `t_gate` arg is the trigger: low → high re-starts from frame 0. Default `loop = 0` means PlayBuf plays through once and stops at the buffer end (the Synth stays alive, just silent — ready for retrigger).

**Per-cell `rate` value-mode:** each one-shot cell has its own `rate` value-mode (see §7), defaulting to `lied` (rate derived from the cell's sequins). The user can also configure `fixed`, `user sequence`, or `random` rate behavior per cell. The cell-emitted rate is set on the SC Synth at trigger time.

**Why persistent retrigger doesn't cost more CPU than fire-and-forget** (verified through CPU model in the brainstorm):

- `Synth.new` is expensive per event: server allocates a new node, initializes all UGens, sets up control mappings, OSC carrying ~10 args.
- `group.set(\t_gate, 1)` is cheap per event: one OSC message, one control-rate value update, PlayBuf re-reads from frame 0.
- At 16th-note triggering and faster, persistent is more efficient. Baseline DSP cost (PlayBuf + MoogFF + Pan2 + lag) is paid whether triggering or not.
- 13 persistent OneShot slots × 1 Synth each (default polyphony) = 13 Synths. Comparable to polyphony=2 fire-and-forget at high trigger rates.

**Buffer loading:** 13 `params:add{type='file', id='oneshot_<N>_file'}`. Same lazy-allocation pattern as samplers.

### Per-voice params (PSET-savable)

For each sampler (16) and each one-shot (13):

- File path (`params:add{type='file'}`)
- `amp` (with `amp_slew`)
- `cutoff`, `resonance`
- `pan`, `pan_slew`
- `polyphony` (1–8, default 1)
- `bus_routing` (dry / reverb / delay+reverb)
- Per-voice randomize trigger + global "all samplers randomize" trigger

---

## 6. Granular delay chain

### Topology

Closely mirrors the proven `carters-delay-norns` standalone, with two additions naherinlied had (`micDry` passthrough) and one design tweak (configurable LFO periods for PSET).

**Synths, allocated persistently at boot:**

```
micGrp (head):
  \fbPatchMix     InFeedback from main out → softclip + HPF + balance +
                  (optional noise/sine inject) → micBus
  \mic            SoundIn.ar(0) * amp → micBus
  \micDry         SoundIn.ar(0) * amp → main out (dry passthrough)

ptrGrp (after micGrp):
  \ptr            Phasor through delayBuf at sample-rate → ptrBus

recGrp (after ptrGrp):
  \rec            BufWr.ar of (micBus + preLevel * BufRd.ar) at ptrBus position
                  into delayBuf

granGrp (after recGrp, tail):
  \gran × 16      GrainBuf reading from delayBuf at scrambled rates/durs/offsets,
                  each with its own pan/cutoff/resonance Ndef driving \pan,
                  \cutoff, \resonance args
```

`delayBuf = Buffer.alloc(s, s.sampleRate * (beat_sec * 512), 1)` — 512 beats at *initial* tempo, mono. Buffer size is fixed at allocation time. Changing Norns tempo mid-run shifts where read heads land relative to write head, but buffer length is fixed. **Documented constraint:** pick the tempo before loading the script, or restart to re-allocate.

### Beat duration: getting `beat_sec` from Norns into SC

`Engine_Lied.sc` exposes a `\set_beat_sec` command. `schicksalslied.lua` calls `engine.set_beat_sec(clock.get_beat_sec())` at init and on tempo changes (via Norns's clock-change callback). The SC kernel caches the value for the granular delay synths' rate/delay calculations. The delay buffer is allocated using the value at first boot only; subsequent updates affect the grain synths' periods.

### Grain LFOs (16 × 3 = 48 `Ndef`s, configurable)

The `carters-delay-norns` standalone hardcodes random LFO periods (`timer.beatDur/rrand(1,64)`). For 2.0 we keep the SC-side `Ndef` topology — lighter than 48 Lua-side LFOs and proven on Norns — but expose each grain's three LFO periods as PSET-savable params:

```supercollider
panLFOs[n] = Ndef(symbol, {
    LFTri.kr(1 / (\rate.kr(8) * beat_sec)).range(-1, 1)
});
```

Each grain has three rate params (`grain_<N>_pan_rate`, `grain_<N>_cutoff_rate`, `grain_<N>_res_rate`) expressed as beat-multiples. Default values match `rrand(1, 64)` semantics: randomized at first PSET creation, then stored.

**These are SC-side `Ndef`s, *not* Lua `_lfos`.** Deliberate exception to the "all LFOs are Lua-side" rule:

1. Lower CPU than 48 Lua-side clocked LFOs ticking the lattice library
2. Lower latency (no per-tick OSC traffic)
3. Matches the standalone's proven Norns topology

A "randomize all grain LFO rates" trigger lets you re-roll the rates as a setup move. The randomized values are stored in the rate params, so PSET captures them.

### `fbPatchMix` params

**Surfaced** (top of granular-delay params group):
- `feedback_amp`
- `feedback_balance`
- `feedback_hpf` (HPF cutoff)

**Buried** (bottom of granular-delay params group, under an "(advanced)" separator, default 0):
- `noise_inject_level`
- `sine_inject_level`
- `sine_inject_freq` (default 55 Hz)

Easter-egg-style: present in PSET, MIDI-mappable, but not headlined in the params menu organization.

### Row 8 cols 14/15/16 (toggle-driven on/off)

Each cell has a configurable "on amp" param. Toggle on → call `engine.set_<target>_amp` with the configured value, `.lag()` smoothed. Toggle off → set amp to 0, same smoothing. Already described in Section 3.

### Real-time amp control

Every amp in the granular chain — `\mic.amp`, `\micDry.amp`, `\fbPatchMix.amp`, every `\gran[n].amp` — has `.lag(amp_slew)` smoothing. A MIDI-mapped knob can sweep any of them mid-sound without clicks or stair-stepping. `granular_out_amp` updates all 16 grain synths in one `granGrp.set(\amp, x)` call.

---

## 7. Sequencing model

### Per-cell `Sequins` (raw bytes)

Every toggle cell across rows 2, 4, 6, and row-8 cols 1–13 has its own `Sequins` instance:

- Row 2: 16 cells × 1 sequins = 16
- Row 4: 16 cells (trigger + rate-control alternating) × 1 sequins = 16
- Row 6: same = 16
- Row 8 cols 1–13: 13 sequins
- **Total: 61 `Sequins` instances.**

Stored in a 2D Lua table: `Seq[x][y]`. Each sequins holds **raw ASCII byte values** (not pre-mapped). The mapping (`% 32 + 49` for note nums, `% 32 / 12` for v/oct, etc.) is applied at *dispatch time* by the cell's role. Changing a cell's role doesn't require rebuilding its sequins — same byte stream, new interpretation.

At init each sequins is seeded with `{ string.byte(" ") }`.

### Role-based dispatch (`cell_roles.lua`)

When a cell fires (its clock-loop tick triggers while `Toggled[x][y] == true` and `Paused == false`), `cell_roles.dispatch(x, y)` is called. The dispatch table maps each role to a function that:

1. Reads one or more byte values via `Seq[x][y]()`
2. Applies the role's mapping
3. Fires the appropriate `engine.<command>()` or `crow.ii.<device>.<method>(...)` call

Examples:

```lua
roles.TriSin = function(seq, cell)
  local note = seq() % 32 + 49
  local freq = MusicUtil.note_num_to_freq(note)
  engine.trisin_trig(cell.id, freq)
end

roles["JF"] = function(seq)
  local pitch = seq() % 32 / 12
  local level = seq() % 5 + 1
  crow.ii.jf.play_note(pitch, level)
end

roles["w/tape looper"] = function(seq, cell)
  if cell.looper_running then return end
  cell.looper_running = true
  clock.run(function()
    wtape_looper.run(seq)
    cell.looper_running = false
  end)
end
```

The `cell.looper_running` flag prevents stacking concurrent loopers on rapid retriggers from the same cell.

### Seq mode (per cell — controls *when* the cell fires)

Each cell has a `seq_mode` param with 4 values:

| Value | Behavior | Sub-params |
|---|---|---|
| `sequins-derived` (a.k.a. `lied`) | rate = `Seq[x][y]() / Seq[x][y]() * scale` (consumes 2 sequins values per tick for a numerator/denominator ratio, like 1.x's `(S:step(3*i)/S:step(3*i+1))*Divs[i]` pattern) | `sequins_scale` (multiplier) |
| `fixed` | rate = `fixed_value` | `fixed_value` (1/16, 1/8, ..., 16) |
| `user sequence` | rate cycles through a user-configured per-cell pattern | `num_steps` (1–8), `step_<N>_duration` for N = 1..8 |
| `random` | rate = `math.random(min, max)` per tick | `random_min`, `random_max` |

Per-cell pattern is *user-configurable* (departure from naherinlied's hardcoded `seqs[1..4]`). User picks number of steps and per-step durations. Per-cell parameters; ~14 clock-shape-related params per cell across all modes (most hidden via `params:hide` based on active `seq_mode`).

Default `seq_mode` values are seeded per cell to match naherinlied's column-specific rates (row 2 col 1 = fixed 8, col 9 = user sequence 1, col 13 = fixed 3, etc.; rows 4/6 = all fixed 2; row 8 = random(1, 16)).

### Value mode (sampler & one-shot cells only — controls *what values* the cell emits)

In addition to `seq_mode` (timing), sampler-trigger cells (rows 4/6 odd cols), sampler-rate cells (rows 4/6 even cols), and one-shot cells (row 8 cols 1–13) each have **one or more `<value>_mode` params** controlling how the cell generates the specific values it emits at fire time.

| Cell type | Values emitted per fire | `<value>_mode` params |
|---|---|---|
| Sampler trigger (rows 4/6, odd cols) | `position` (0.0–0.9, start of play window) + `duration` (0.001–0.1, window length) | `position_mode`, `duration_mode` |
| Sampler rate (rows 4/6, even cols) | `rate` (−16 to 16, with `rate_slew` smoothing) | `rate_mode` |
| One-shot trigger (row 8 cols 1–13) | `rate` (−16 to 16) | `rate_mode` |

Each `<value>_mode` has the same 4 options as `seq_mode`, parallel structure:

| Value mode | Behavior | Sub-params |
|---|---|---|
| `sequins-derived` (a.k.a. `lied`) — **default** | value = one byte read from `Seq[x][y]`, mapped via the role's default function (e.g., `util.linlin(36, 62, 0, 0.9, byte)` for sampler position; matches naherinlied's behavior bit-for-bit) | `sequins_scale` (where applicable) |
| `fixed` | value = `<value>_fixed_value` | `<value>_fixed_value` |
| `user sequence` | value cycles through a user-configured per-cell list | `<value>_num_steps` (1–8), `<value>_step_<N>_value` for N = 1..8 |
| `random` | value = `math.random(<value>_random_min, <value>_random_max)` per fire | `<value>_random_min`, `<value>_random_max` |

About 14 params per `<value>_mode` config (mostly hidden via `params:hide` based on active mode). Per-cell totals:

- Sampler trigger cells (2 value_modes each): ~28 extra params per cell × 8 cells × 2 rows = **448**
- Sampler rate cells (1 value_mode each): ~14 extra params per cell × 8 cells × 2 rows = **224**
- One-shot cells (1 value_mode each): ~14 extra params per cell × 13 cells = **182**

**Additional total: ~854 params.** Updated grand total: ~7000 params (from ~6200).

Defaults: `lied` for all value_modes, replicating naherinlied's behavior exactly (sampler position+duration from sequins, sampler rate from sequins, one-shot rate from the legacy global per-slot rate param — kept as the `fixed_value` source when default mode is `lied`).

**Row-2 cells (TriSin/Ringer/crow/JF/w/syn/w/del/w/tape) are NOT included** in this value-mode mechanism — their pitch/level/etc. stay sequins-derived (lied mode) by default. Extending value-mode to row-2 cells is a possible future enhancement but not in scope for 2.0 unless explicitly added.

### Clock-loop lifecycle (always-running, gated by toggle)

Per naherinlied's idiom: one `clock.run` per cell, started at script init, runs forever. Inside:

```lua
function step_for(x, y)
  return function()
    while true do
      clock.sync(sequencer.get_rate(x, y))
      if Toggled[x][y] and not Paused then
        cell_roles.dispatch(x, y)
      end
    end
  end
end
```

61 always-running clock loops. CPU cost is negligible — `clock.sync` is essentially "wake me at time T," and the body work happens only when toggled-on and not paused. We *don't* lazy-start/stop clock loops because the CPU savings are minimal compared to actual DSP load and the always-running pattern is simpler.

### Toggle state and the "assign" mechanic

Two tables: `Momentary[x][y]` (grid-key held-down boolean, transient, for LED brightness) and `Toggled[x][y]` (persistent sequencer-enabled, set via even-row press).

- **Even-row press** (rows 2, 4, 6, 8): toggles `Toggled[x][y]`. LED reflects state.
- **Odd-row press** (rows 3, 5, 7): assigns `My_String` to `Seq[x][y-1]:settable(bytes)`. Row 7 press updates row 6's sequins; row 5 → row 4; row 3 → row 2.

### Text input flow (two-variable model)

Two variables: `Displayed_String` (keyboard typing buffer, what's shown after `>`) and `My_String` (the line staged for assignment).

1. **Type on keyboard** → chars accumulate in `Displayed_String`, shown on screen.
2. **Keyboard ENTER** → `My_String = Displayed_String`; `Displayed_String` is added to `History`; `Displayed_String` is cleared. The just-typed line is now staged.
3. **Grid row-1 press** → `My_String = Displayed_String .. History[col + 16*(row-1)]`. Holding multiple row-1 buttons concatenates them in press-order; releasing all confirms.
4. **Grid odd-row press (rows 3, 5, 7)** → `Seq[x][y-1]:settable(string_to_bytes(My_String))`. Cell above the press point gets its sequins replaced.
5. **Keyboard UP / DOWN** → cycles `History`; the selected line replaces `Displayed_String` (matches 1.x behavior).
6. **Row-1 release after single press** → no separate action; `My_String` was already set during press.

This is a meaningful behavioral change from 1.x — there's no longer a single "global active line." Every cell is independently assignable. The user assigns explicitly.

---

## 8. Crow integration

### Devices and methods used

| Device | Methods | Used by which cell role |
|---|---|---|
| `crow.input[1]` | `mode('clock')` (init only) | clock sync input |
| `crow.output[1..4]` | `.volts`, `.slew`, `.action`, `.dyn.attack`, `.dyn.release`, `()` (call) | `crow 1+2`, `crow 3+4` |
| `crow.ii.jf` | `mode`, `run_mode`, `tick` (init); `play_note(pitch, level)`, `run(v)`, `quantize(v)` | `JF`, `JF run`, `JF quantize` |
| `crow.ii.wsyn` | `ar_mode`, `voices`, `patch` (init); `lpg_time`, `lpg_symmetry`, `fm_ratio`, `fm_index`, `fm_env` (param actions); `play_note(pitch, level)` | `w/syn`, plus several params controls |
| `crow.ii.wdel` | `mod_rate`, `mod_amount` (init); `feedback`, `filter` (param actions); `time`, `freq`, `pluck` | `w/del` |
| `crow.ii.wtape` | `timestamp`, `freq`, `play` (init); `speed`, `reverse`, `loop_start`, `loop_end`, `loop_scale`, `loop_next`, `loop_active`, `seek` | `w/tape looper` |

No features dropped versus 1.x. The `Walking` global flag goes away (per-cell toggle replaces it); the `wcheck()` coroutine that polled `crow.ii.wtape.play(Walking and 1 or 0)` is removed (the `w/tape looper` role handles play state when triggered).

### `crow_reinit()` function + re-init trigger

A new function consolidates all the crow setup commands currently scattered at the bottom of `schicksalslied.lua:852-863`:

```lua
function crow_reinit()
  crow.input[1].mode('clock')
  crow.ii.jf.mode(1)
  crow.ii.jf.run_mode(1)
  crow.ii.jf.tick(clock.get_tempo())
  crow.ii.wtape.timestamp(1)
  crow.ii.wtape.freq(0)
  crow.ii.wtape.play(0)
  crow.ii.wdel.mod_rate(0)
  crow.ii.wdel.mod_amount(0)
  crow.ii.wsyn.ar_mode(1)
  crow.ii.wsyn.voices(params:get('wsyn_voices') or 4)
  crow.ii.wsyn.patch(1, 1)
  crow.ii.wsyn.patch(2, 2)
end
```

Called from `init()` once at startup, and also wired to a `params:add{type='trigger', id='reinit_crow', name='re-init crow modules', action=crow_reinit}` button at the top of the crow params section. Use case: crow gets hot-plugged after the script starts, or i2c handshake silently drops mid-set, or the user reconnects a device.

`wsyn_voices` is a new param (1–4, default 4) replacing the hardcoded `crow.ii.wsyn.voices(4)`. PSET-savable.

### `w/tape looper` port

The 60+-line `looper()` coroutine in `schicksalslied.lua:341-404` is preserved (B2 — the user explicitly does not want to lose it) as the body of the `w/tape looper` role's dispatch. Rewiring:

- Replace every `C:step(N)()` with `seq()` (where `seq = Seq[x][y]`). Each call advances the cursor naturally; the looper consumes ~50 byte values across one full pass.
- Replace every `J:step(N)()` similarly. Mapping (`% N + 1` for iteration counts, `/ 12` for v/oct) done inline as 1.x does.
- The role dispatch wraps the looper in `clock.run(...)` so it runs as its own coroutine when the cell fires.
- `cell.looper_running` flag prevents stacking concurrent loopers on rapid retriggers from the same cell.

The full nested `loop_start` → `loop_end` → `loop_scale` → `loop_next` → `seek` → `loop_active` choreography is preserved bit-for-bit; only the sequins source changes.

### Per-role dispatch summary

- `crow 1+2` / `crow 3+4`: consumes 4 bytes per fire (pitch v/oct, slew, attack-time, release-time) and fires `crow.output[N].volts` + `crow.output[N+1]()` (paired pitch + AR).
- `JF`, `w/syn`: consumes 2 bytes (pitch + level), fires `play_note(...)`.
- `JF run`, `JF quantize`, `w/del`: consumes 1–2 bytes, fires the corresponding ii method.
- `w/tape looper`: described above.

---

## 9. Params menu structure

### Top-level layout

```
[group] cells                 (~870 params)
[group] cell value modes      (~854 params — sampler/one-shot cells only)
[group] row-2 voices          (~400 params)
[group] samplers              (~96 params)
[group] one-shot samplers     (~78 params)
[group] granular delay        (~57 params)
[group] LFOs                  (~4650 params)
[group] crow                  (~11 params + triggers)
[group] global                (~10 triggers + text file param)
```

Approximate total: ~7000 params. For comparison, `cheat_codes_2` and `paracosms` operate at similar scales — proven feasible on Norns. PSET load time will be the bottleneck (~seconds for a full set with 29 buffer-loads), not runtime.

### Per-group structure (representative)

**`cells` group.** Separators by row. Per cell, a sub-block of seq-mode config (plus role param for row 2 only):

```
─ row 2 (role configurable) ─
  cell 1 role                  (10-option enum)
  cell 1 seq_mode              (4-option enum)
  cell 1 fixed_value           (hidden unless seq_mode=fixed)
  cell 1 num_steps             (hidden unless seq_mode=hand-picked)
  cell 1 step 1 duration       (hidden unless ...)
  cell 1 step 2 duration       ...
  cell 1 step 8 duration       ...
  cell 1 random_min            (hidden unless seq_mode=random)
  cell 1 random_max            (hidden unless seq_mode=random)
  cell 1 sequins_scale         (hidden unless seq_mode=sequins-derived)
  (repeat for cells 2..16)

─ row 2 bulk ─
  set row 2 to all TriSin      (trigger)
  set row 2 to all Ringer      (trigger)
  set row 2 to default mix     (trigger)
  randomize row 2 roles        (trigger)
```

Rows 4, 6, 8 follow same shape without role param (roles fixed). `params:hide` keeps the menu uncluttered per the active `seq_mode`.

**`cell value modes` group** (new — sampler/one-shot only). Per cell, a sub-block of `<value>_mode` configs:

```
─ row 4 sampler trigger cells (1, 3, 5, ...) ─
  cell 1 position_mode         (4-option enum)
  cell 1 position_fixed_value  (hidden unless mode=fixed)
  cell 1 position_num_steps    (hidden unless mode=user sequence)
  cell 1 position_step 1 value ...
  ...
  cell 1 position_random_min   (hidden unless mode=random)
  cell 1 position_random_max
  cell 1 duration_mode
  cell 1 duration_fixed_value
  ...
─ row 4 sampler rate cells (2, 4, 6, ...) ─
  cell 2 rate_mode
  cell 2 rate_fixed_value
  ...
(repeat for rows 6, 8)

─ value-mode bulk ─
  randomize all sampler positions  (trigger)
  randomize all sampler durations  (trigger)
  randomize all sampler rates      (trigger)
  randomize all one-shot rates     (trigger)
  reset all to lied mode           (trigger)
```

Value-mode params are organized into their own top-level group separate from `cells` (which holds the timing/seq_mode configs) so the user can navigate timing config and value config independently.

**`row-2 voices` group.** Per cell, a sub-block holding the union of `TriSin` and `Ringer` params (visibility by current role):

```
─ cell 1 (role: TriSin) ─
  cell 1 amp                   (with .lag idiom)
  cell 1 amp slew
  cell 1 pan
  cell 1 pan slew
  cell 1 polyphony             (1-8, default 4)
  cell 1 bus routing
  ─ FM params (TriSin only) ─
  cell 1 fm carrier ratio
  cell 1 fm modulator ratio
  cell 1 fm index
  cell 1 fm iScale
  cell 1 attack
  cell 1 release
  cell 1 attack curve
  cell 1 release curve
  cell 1 fm env attack
  cell 1 fm env release
  cell 1 fm env attack curve
  cell 1 fm env release curve
  cell 1 cutoff
  cell 1 cutoff env
  cell 1 resonance
  cell 1 freq slew
  ─ Ringer params (Ringer only) ─
  cell 1 decay                 (the SC arg is still `index` internally;
                                "decay" is the display name)
  cell 1 randomize all         (trigger)
```

**`samplers` group.** Per sampler: file, amp, amp_slew, cutoff, resonance, pan, pan_slew, polyphony, bus_routing, randomize trigger.

**`one-shot samplers` group.** Same structure as samplers.

**`granular delay` group:**

```
─ master ─
  mic to delay amp
  granular out amp
  mic dry amp
─ feedback patch ─
  feedback amp
  feedback balance
  feedback hpf
  ─ (advanced) ─
  noise inject level           (default 0)
  sine inject level            (default 0)
  sine inject freq             (default 55)
─ grain LFO rates ─
  grain 1 pan rate
  grain 1 cutoff rate
  grain 1 resonance rate
  ...
  randomize all grain LFO rates (trigger)
```

**`crow` group:**

```
re-init crow modules          (trigger, top)
wsyn voices                   (1-4, default 4)
wsyn lpg speed
wsyn lpg symmetry
wsyn fm num
wsyn fm deno
wsyn fm index
wsyn fm envelope
wdel feedback
wdel filter cutoff
```

**`global` group:**

```
text file                     (params:add{type='file'})
panic                         (trigger, also K1)
pause/resume                  (trigger, also K2)
tap tempo                     (trigger, also K3)
global randomize              (trigger)
set all seq modes to default  (trigger)
```

### `params:hide` discipline

Whenever a cell's `seq_mode` changes, the cell's action callback updates which sub-params are hidden. Same for role changes (TriSin vs Ringer param visibility). Same for LFO depth (params hide when depth = 0; show when depth > 0). Avoids menu clutter at scale.

### PSET integration

All params `:add`-ed; PSET captures everything. File paths PSET-survive (`type='file'` is path-savable). Audio buffers re-load when PSET is applied. Cell roles and seq-mode configs PSET-survive. The user can save multiple PSETs as "performance setups" and switch between them. Transient state (`Displayed_String`, `My_String`, History runtime, `Toggled`, `Seq` runtime values) is *not* PSET'd — performance content.

---

## 10. LFOs

### Library and infrastructure

Uses the **standard Norns LFO library** (`require 'lfo'`). No bundled `lied_lfo.lua` (which was a 2-year-old preview of fixes since landed in the standard lib).

### Architecture (uses standard Norns LFO library directly)

The standard `lfo` library handles its own enable/disable + visibility, so we use it directly without wrapping:

- Adding an LFO via `LFO:add{...}` exposes an `lfo_<id>` option param (off/on) which serves as the master switch.
- When the LFO is "off", the library internally calls `lfo_params_visibility("hide", id)`, hiding all other LFO params (depth, shape, period, etc.).
- When set to "on", the library calls `:start()` automatically and shows the sub-params.

**Sub-plan C correction:** the original Section 10 proposal to make depth itself the on/off driver was incompatible with this library design — depth can't be raised above 0 to enable the LFO when depth is hidden while state=off. Sub-plan C adopts the library's built-in enable mechanism directly.

This adds one param per LFO vs the original proposal (~282 LFOs ≈ +282 params over the original count) but is simpler and matches every other Norns script's LFO UX.

### Coverage (Option 1 — full)

Matching 1.x's per-param breadth, applied to 2.0's voice topology:

**Row-2 voices (per cell, 16 cells):**
- TriSin params with LFOs: `amp`, `pan`, `attack`, `release`, `cutoff`, `resonance`, `fm_index`, `fm_carrier_ratio`, `fm_modulator_ratio` (9 LFOs)
- Ringer params with LFOs: `amp`, `pan`, `decay` (3 LFOs)
- Per cell: 12 LFOs allocated (both classes), visibility per role. 16 × 12 = **192 LFOs**.

**Samplers (16):** `amp`, `pan`, `cutoff`, `resonance`, `rate` → 5 LFOs each. **80 LFOs.**

**One-shot samplers (13):** `amp`, `pan`, `cutoff`, `resonance` → 4 LFOs each. **52 LFOs.**

**Crow params (global):** `wsyn_lpg_speed`, `wsyn_lpg_symmetry`, `wsyn_fm_num`, `wsyn_fm_deno`, `wsyn_fm_index`, `wsyn_fm_envelope`, `wdel_feedback`, `wdel_filter_cutoff` → 8 LFOs.

**Total: ~332 LFOs × ~14 params each = ~4650 LFO params.**

Granular grain LFOs are excluded (they're SC-side `Ndef`s, see Section 6).

### Clock-sync

When `mode = clocked`, the LFO's period is in beats (sync'd to Norns clock). When `mode = free`, period is in seconds. Defaults: clocked for amp/pan LFOs (so MIDI/Link tempo changes propagate). Per-LFO selectable.

### PSET-savability

All LFO params are normal `params:add` entries; PSET captures depth/period/shape/mode/offset/etc. Reloading a PSET restores LFO state — including the depth value that re-activates `:start()` automatically via the wrapped action.

---

## 11. UI

### Norns screen (128×64)

Two-string layout — user needs to see both typing buffer and staged line:

```
  [history line -5]
  [history line -4]
  [history line -3]
  [history line -2]
  ★ [My_String]                    (y≈40, only if My_String != "" && != Displayed_String)
  ┌──────────────────────────┐
  │ > [Displayed_String]     │     (y 50-64, bordered input box)
  └──────────────────────────┘
```

- Input box at y 50–64 (preserved from 1.x).
- Above box: "staged line" with `★` prefix (`My_String`). Hidden if redundant with `Displayed_String` (typical state right after ENTER).
- Above staged line: recent History items, scrolling up.
- The `Needs_Restart` UI from 1.x is gone (no FormantTriPTR install).

### Keyboard handling (recap from Section 7)

- **Char keys** → append to `Displayed_String`
- **ENTER** → `My_String = Displayed_String`; append `Displayed_String` to `History`; clear `Displayed_String`
- **BACKSPACE** → strip last char of `Displayed_String`
- **UP / DOWN** → cycle `History`; selected line → `Displayed_String`
- **Ctrl** (any ctrl chord) → remove last `History` entry; clear `Displayed_String`

### Hardware keys K1 / K2 / K3

- **K1 — panic.** Frees all running SC voices (TriSin, Ringer, samplers, one-shots) via engine commands; frees the granular chain; calls `crow.ii.jf.run(0)`, `crow.ii.wtape.play(0)`; zeroes crow CV outputs 1-4; sends MIDI All-Notes-Off (via `Midi_Role.all_notes_off`, which iterates tracked active notes). w/syn and w/del notes decay naturally via their internal envelopes (no direct silence verb exposed by those modules). Clearing `Toggled` is the main mitigation for those — no new triggers will reach them.
- **K2 — pause/resume (clock-quantized).** Sets `Pause_Pending = true`; a coroutine does `clock.sync(1)` to wait until the next beat, then flips `Paused`. Cell dispatches gate on `Paused`. Pause/unpause happens on a beat boundary, not mid-tick. Visual hint during pending state: toggled-on cells pulse between 15 and 6.
- **K3 — tap tempo.** Each press records a timestamp; computes BPM from interval; passes to `clock.set_tempo()`. Sliding-window average on subsequent presses.

All three also exposed as params triggers (`panic`, `pause_resume`, `tap_tempo`) → MIDI-mappable.

### Grid LED rendering

`grid_redraw_clock` polls `Grid_Dirty` at 30 fps. Per-row brightness scheme (bit-for-bit naherinlied + pause treatment):

| Row | Cells | Idle | Active (toggled on) | Held (Momentary) | Pause (K2 engaged) |
|---|---|---|---|---|---|
| 1 | history slots (1–16) | 0 (empty) / 4 (filled) | — | 15 | unchanged |
| 2, 4, 6, 8 | toggle | 0 | 15 | 15 | toggled-on cells dim from 15 to 6 |
| 3, 5, 7 | momentary | 4 | — | 15 | unchanged |

---

## 12. Behavioral changes vs 1.x (concepts removed, not files)

These are 1.x concepts/idioms that have no analog in 2.0. They're not file changes (covered in §13) but they're semantic departures worth being explicit about so an implementer doesn't accidentally port them.

- **`Walking` / `Going` / `Running` global flags removed.** These were 1.x's K1/K2/K3-driven global enables for crow / softcut / engine respectively. In 2.0 every cell has its own `Toggled[x][y]` flag; there's no global "all of voice-class X is enabled" state. K1/K2/K3 are repurposed (panic / pause / tap tempo, §11).
- **`wcheck()` coroutine removed.** 1.x runs a 30-Hz coroutine polling `crow.ii.wtape.play(Walking and 1 or 0)`. With `Walking` gone, `wcheck` goes with it. The `w/tape looper` role manages tape play state when triggered.
- **Global `S` / `C` / `J` sequins removed.** Replaced by per-cell `Seq[x][y]`. The 1.x mapping functions `remap` / `crowmap` / `jfmap` (in `schicksalslied.lua:186-197`) move into role-specific dispatch in `cell_roles.lua` — each role applies its own ASCII-byte mapping.
- **The `set()` global function removed.** 1.x's `set()` (line 256) did `S:settable / C:settable / J:settable` simultaneously off the active line. 2.0 has no global active line; assignment is per-cell via odd-row grid press.
- **Softcut buffer-clear region, fade-time machinery removed.** All of `softcut_init()`, `update_softcut`, `Soft[i]`, `Rate[i]`, `Pans[i]` loops, and the `Buffering` flag (lines 50-66, 100-163, 231-254) — gone. SC samplers replace this entire layer.
- **First-boot UGen install flow removed.** The `Needs_Restart` flag and the `Restart_Message` UI element (lines 557-568) go away. No external UGen to install since tritri is dropped.

---

## 13. Migration & file structure

### Removed files

- `lib/Engine_LiedMotor.sc`
- `lib/LiedMotor_engine.lua`
- `lib/lied_lfo.lua`
- `ignore/FormantTriPTR.sc`, `ignore/FormantTriPTR_scsynth.so`
- The `ignore/` folder (if no other external deps surface)

### Added files

- `lib/Engine_Lied.sc` (Crone wrapper)
- `lib/Lied.sc` (SC kernel)
- `lib/TriSin.sc`, `lib/Ringer.sc` (per-voice classes)
- `lib/Sampler.sc` (Phasor + BufRd crossfade sampler)
- `lib/OneShot.sc` (upgraded with `.lag()` on amp, persistent group)
- `lib/cell_roles.lua`
- `lib/sequencer.lua`
- `lib/wtape_looper.lua`

### Preserved files

- `schicksalslied.lua` (heavily rewritten, same filename — existing `dust/code/schicksalslied/` install path stays)
- `README.md` (needs full rewrite, but that's a writing task; not in this spec)

### Install on Norns

Identical to 1.x — `/home/we/dust/code/schicksalslied/`. The user replaces the folder contents. **No first-boot UGen install needed** (tritri/FormantTriPTR is gone). Version bump: `version 2.0.0` at the top of `schicksalslied.lua`.

### Backwards compatibility

**None.** 2.0 is not source-compatible with 1.x. 1.x PSETs will not load on 2.0 (different param IDs, different structure). Users keeping 1.x setups can:

- Keep a separate 1.x install at a different path (e.g., `schicksalslied-v1/`) and switch between scripts on Norns.
- Or accept that 1.x setups need re-creation in 2.0.

The "fresh start" cost is documented in the rewritten README's "upgrading from 1.x" section.

---

## 14. Testing & verification

Each item must be done before declaring 2.0 ready.

**1. SC class smoke test (off-Norns).** A `test.scd` script in the project root (modeled on `norns-ritual/norns-ritual/test.scd`) that boots SC locally, instantiates `Lied`, exercises each voice class for ~3 seconds (`TriSin`, `Ringer`, `Sampler`, `OneShot`, granular chain, `fbPatchMix`), confirms no SC errors, exits. Catches DSP-graph problems without needing a Norns device.

**2. CPU budget verification (on Norns).** Load 2.0 on hardware. Watch SuperCollider CPU in Maiden:

| Stage | Expected ceiling |
|---|---|
| Baseline (no toggles) | <8% |
| Full row 2 active (16 cells × poly 4 TriSin, 1/4 notes) | <40% |
| Add 16 samplers loaded + 1/2 notes | <60% |
| Add 13 one-shots loaded + 1/4 notes | <75% |
| Engage granular delay (3 row-8 controls on) | <90% |

**Crackle is a fail.** If any stage produces audible crackle, scale back (reduce default polyphony, reduce grain count, etc.) and re-test.

**3. Real-time amp control test.** For each voice class:

- Trigger a long-sustain note (TriSin/Ringer with long release, Sampler with full buffer, OneShot with a long field recording).
- Mid-sound, sweep that voice's `amp` param via the params menu encoder.
- The currently-sounding audio must respond audibly. Smooth — no clicks.

This is the cross-cutting "ritual lesson" verification. Failure means the voice isn't correctly implementing `.lag()` + `voiceGroup.set` pattern from Section 4.

**4. PSET round-trip.** Configure a setup (~10 minutes of param tweaking — cell roles, files loaded, LFOs enabled, granular settings). Save PSET 1. Change everything substantially. Save PSET 2. Switch back to PSET 1. Verify every audible parameter matches the saved state. Particularly: sampler/one-shot files re-load and play, cell roles restored, LFO depth/period restored and re-`:start()`s automatically.

**5. Crow hot-plug recovery.** Boot the script with crow unplugged. Confirm script doesn't crash. Plug crow in. Trigger crow-role cells — expect no events reach modules. Press `reinit_crow` trigger. Verify subsequent crow events reach JF/w-syn/w-tape. Same test with crow disconnected during a set.

**6. Looper coroutine isolation.** Toggle a `w/tape looper` cell on at 1/4 sync. Verify only one looper runs at a time per cell (`cell.looper_running` flag). Reassign the cell mid-looper; verify the in-flight looper completes without errors but the cell's next trigger uses the new role.

**7. Long-sample fade-out.** Load a long field recording (>5 minutes) into a one-shot slot. Trigger it. Mid-playback, MIDI-map a knob to that slot's `amp` and sweep to 0 over 3 seconds. Expect smooth audible fade, not pop, not delayed-until-next-trigger.

**8. Sampler crossfade.** Load a sampler. Trigger rapidly at small intervals (1/16 notes) with varying play windows. Listen for clicks — the dual-Phasor + ToggleFF crossfade should eliminate them. If clicks appear, the SynthDef's `Lag.ar(K2A.ar(aOrB), 0.1)` envelope time may need adjustment.

**9. Clock-quantized pause.** Mid-set, press K2. Verify pause kicks in on the next beat (not mid-tick). Press K2 again. Verify resume happens on the next beat. Sequins state preserved across pause (cell sequins resumes from where it was).

**10. Value-mode round-trip.** Pick a sampler trigger cell. Set its `position_mode` to `user sequence` with 3 distinct values. Trigger the cell repeatedly. Listen for the sampler positions cycling through those 3 values. Switch to `random` mode with a tight min/max range. Confirm positions vary within range. Switch back to `lied` mode. Confirm naherinlied-style behavior (positions derived from sequins bytes). Same test for `duration_mode` on the same cell, `rate_mode` on a paired rate cell, and `rate_mode` on a one-shot cell.

**11. Performance soak.** Run a 30-minute "set" with all features active, sequencer running, user interacting normally. No crackle, no crashes, no clock drift, no runaway memory. Norns CPU peak should stay under 95%.

---

## 15. Known risks

- **Param menu navigation at ~7000 params.** Addressable via the patterns `cheat_codes_2` and `paracosms` use (well-organized sub-groups, hide-discipline, careful menu ordering). Will need attention during implementation; not architecturally blocked.
- **PSET load time.** Each `params:add{type='file'}` triggers a buffer-load on PSET apply; 16 samplers + 13 one-shots = 29 buffer-loads. May take seconds. Acceptable for a setup change, not for performance.
- **Looper coroutine + clock-quantized pause interaction.** If a looper coroutine starts mid-`clock.sync(N)` and the user pauses, the looper continues until its next `clock.sync` return, which may be mid-choreography. Probably acceptable; flagged for verification during testing.
- **Lazy TriSin/Ringer allocation idle-grace tuning.** "Free after N seconds idle" is a tunable. Too short → allocate/free thrash. Too long → CPU baseline doesn't shrink. Initial value 30s, tunable via a global param.
- **Delay buffer fixed at boot.** `delayBuf` is sized by the tempo at init. Changing tempo doesn't resize. Restart to re-allocate. Documented as a constraint.

---

## Open items for implementation planning

Nothing architecturally blocked. The implementation-plan stage (`superpowers:writing-plans`) will sequence the work, identify dependencies, and produce a step-by-step plan. Order is approximately:

1. SC kernel (`Lied.sc`) + Crone wrapper (`Engine_Lied.sc`) skeleton; buses, master FX, off-Norns smoke test passing.
2. Voice classes (`TriSin.sc`, `Ringer.sc`); real-time amp test passing for both.
3. `Sampler.sc` + `OneShot.sc`; sampler crossfade test + long-sample fade test passing.
4. Granular delay chain + `fbPatchMix`; CPU stage 5 test passing.
5. Per-cell sequins + `cell_roles.lua` + `sequencer.lua`; basic firing across all roles.
6. Grid handling + screen redraw + K1/K2/K3 + keyboard input.
7. `wtape_looper.lua` port; looper isolation test.
8. Params menu structure + LFO bind machinery; PSET round-trip test.
9. Soak test + final scaling pass.
