# schicksalslied 2.0

a poetry sequencer for monome norns

> "What is a poet? A poet is an unhappy being whose heart is torn by secret sufferings, but whose lips are so strangely formed that when the sighs and the cries escape them, they sound like beautiful music."
> — Søren Kierkegaard, *Either/Or*

type on a keyboard or pick a line from history, assign it to a grid cell, toggle the cell on. each character of the line becomes a stream of bytes that drive the cell's synthesis, sampling, MIDI, or crow output. different cells play different lines simultaneously at their own rates. fully operable from grid, params menu, or MIDI controller.

## install

copy this folder to `/home/we/dust/code/schicksalslied/` on your norns.

**reboot norns** so the `Lied` SuperCollider engine registers, then load using SELECT.

## hardware

- monome norns (any model)
- monome grid (optional — script is fully operable via PARAMETERS without one)
- USB keyboard (for text entry)
- optional: MIDI controller, crow, w/syn, w/del, w/tape, just friends

## the grid

```
1 ─ history: 128 typed/loaded lines
2 ─ voice cells × 16 (TriSin, Ringer, crow, JF, w/, MIDI, ...)
3 ─ assign row for row 2
4 ─ looping samplers 1–8 (odd cols = trigger, even = rate)
5 ─ assign row for row 4
6 ─ looping samplers 9–16 (odd cols = trigger, even = rate)
7 ─ assign row for row 6
8 ─ one-shots 1–13 + mic→delay / granular out / mic dry (cols 14/15/16)
```

rows 2/4/6/8 are toggles — press to start/stop. rows 3/5/7 are momentary — press to assign the staged line to the cell above.

## hardware controls

```
K1: (preserves system back/menu)   E1: scroll history
K2: append history line             E2: global amp
K3: ENTER (stage + add to history)  E3: BPM
```

## voice roles

each of the 16 row-2 cells can be assigned one of 11 roles via PARAMETERS → synths → cell N → role.

- **TriSin** — FM voice (triangle carrier, sine modulator)
- **Ringer** — pinged resonant filter, percussive
- **crow 1+2** / **crow 3+4** — pitch CV + AR env on a pair of crow outputs
- **JF** / **JF run** / **JF quantize** — just friends via ii (synthesis, RUN, quantize)
- **w/syn** — w/syn over ii
- **w/del** — karplus-strong via w/del
- **w/tape looper** — w/tape loop choreography
- **MIDI** — note on/off to the configured device + channel

defaults alternate blocks of 4: TriSin × 4, Ringer × 4, TriSin × 4, Ringer × 4.

## samplers and one-shots

load files via PARAMETERS → looping samplers → sampler N → file (10-minute max per file). identical files loaded into multiple slots share one buffer.

sampler **trigger cells** (odd cols on rows 4/6) emit start + end positions per fire. **rate cells** (even cols, paired with the trigger to their left) set playback rate independently — negative for reverse, 0 for freeze. one-shots (row 8 cols 1-13) play the whole buffer per trigger.

## granular delay

row 8 col 14 toggles mic into the delay buffer. col 15 toggles granular output. col 16 toggles a dry mic passthrough.

any voice can route into the granular chain via its `granular send` param. turn up `feedback amp` (PARAMETERS → granular delay → feedback patch) to make the chain self-modulating.

## sequencer modes

every cell's rate is determined by its **seq mode** (PARAMETERS → … → cell N → seq mode):

- **lied** — rate derived from the cell's text bytes (`byte / byte × scale`)
- **fixed** — a constant musical fraction (1/16 through 64 beats)
- **seq** — cycle through 1-8 user-defined step durations
- **random** — random fraction in a configurable range

sampler position/duration and rate cells each have parallel **value modes** with the same four options.

## master FX

PARAMETERS → master fx: delay (sync'd or free, up to 8 sec), reverb (room + damp + amp), per-voice send levels per cell. delay routes to both dry and reverb at independent send levels.

## MIDI

PARAMETERS → midi input: pick device + role (TriSin or Ringer) for a dedicated voice. PARAMETERS → midi: pick the output device for the `MIDI` voice role. standard norns MIDI mapping works on every param.

## PSET

standard norns PSET via PARAMETERS → PSET. history and per-cell string assignments save to a sidecar `.lieddata` file alongside the .pset; PSET 01 autoloads on script start.

## tips

- start sparse — one voice + one sampler + granular is plenty
- use per-cell **phase** for backbeat patterns (kick on `rate=2 phase=0`, snare on `rate=2 phase=1`)
- save often: PSET captures everything including typed history

## troubleshooting

- **loud drone on load + JackDriver alloc error** → SC memory issue; SLEEP → K1-hold to reboot, redeploy.
- **synths fire once then silence** → matron clock scheduler wedged. SLEEP → K1-hold (NOT `system → restart`) for a hard power cycle.
- **cell strings don't restore from PSET** → check that `schicksalslied-NN.pset.lieddata` exists alongside the `.pset`.
- **"Buffer UGen: no buffer data" on sampler fire** → check matron log for the load message; common causes: file not found, unsupported format, exceeds 10-minute cap.

## documentation

a complete 20-chapter developer tutorial covering every line of the script lives in [`docs/tutorial/`](docs/tutorial/). useful if you want to understand the architecture, modify the script, or use it as a starting point for something completely different.

## sibling lieder

- [krähenlied](https://github.com/williamthazard/krahenlied) — crow + druid; the byte-to-musical-value mappings used by 2.0's crow/JF/w/ roles originate here.
- [schicksalslied 1.0](https://github.com/williamthazard/schicksalslied) — single global text field driving 6 SC voices + 3 softcut + crow.
- [superLied](https://github.com/williamthazard/superLied) — mac SC port. introduced the 8-row grid layout that 2.0 inherits.
- [näherinlied](https://github.com/williamthazard/naherinlied) — seamstress + SC port. parallel mac-friendly performance variant.

## acknowledgments

- tehn for initiating norns.
- Ezra Buchla for help refining Carter's Delay (the granular delay design used here).
- Dani Derks, Jonathan Snyder, Zack Scholl, and Robbie Lyman for ongoing mentorship, friendship, and guidance on norns development.
- The [lines](https://llllllll.co) community for the wealth of shared knowledge that makes scripts like this one possible.

## license

see [LICENSE](LICENSE).
