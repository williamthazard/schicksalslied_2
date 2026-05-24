# Chapter 01 — Introduction

## What you'll learn

This chapter sets the context for the rest of the tutorial. You'll come away with: a mental model of the script's three-layer architecture; a map of every file in the repository and what it's responsible for; a working development environment (SuperCollider IDE on your workstation, Norns reachable over SSH); and a clear picture of how a change in one file propagates through the system to produce sound.

After this chapter, the next ten will fill in each layer in detail. You'll write actual code starting in chapter 02. This chapter has no checkpoint of its own — its purpose is to orient.

## Prerequisites within the tutorial

None. This is chapter 01.

## What you're building

schicksalslied 2.0 is a script for [monome Norns](https://monome.org/docs/norns/) that turns text into music. A user types poetry at a USB keyboard or selects lines from history on a connected grid. Each line's characters become a stream of bytes — `'A'` is 65, `' '` is 32 — and those bytes drive synthesis parameters, sample positions, MIDI notes, and crow outputs. Different lines produce different music. Two cells assigned different lines play different melodies at the same time.

The script has roughly 5,800 lines of code split across:

- **Lua** (about 4,000 lines): control flow, UI, parameter management, MIDI, grid handling, sequencer state. Runs on the Norns's matron interpreter.
- **SuperCollider** (about 1,800 lines): all DSP. Runs on the SuperCollider server (scsynth), supervised by Norns's Crone engine layer, which is in turn supervised by sclang.

When the tutorial is done, you'll have produced byte-for-byte equivalent files. Along the way you'll have understood every line.

### What the end product can do

To make the scope concrete: when you finish chapter 11, your build will support all of the following simultaneously, with no editing or recompilation between mode switches:

- A 16-cell row of voice synthesizers, each cell independently assignable to one of 11 roles (two SC-side voices: TriSin, Ringer; eight crow / Just Friends / w/ device roles; one MIDI-out role).
- 16 looping sampler slots, each with its own file, polyphony, sends, and per-cell trigger + rate sequencing.
- 13 one-shot sample slots with the same per-slot architecture.
- A 4-grain Carter's-Delay granular feedback loop with a mic input, voice send buses, and a feedback patch.
- A 4-band master FX rack: tap delay (sync'd or free), Freeverb, and the granular chain as a third send destination.
- Per-cell sequencer modes (lied / fixed / user_seq / random) and per-cell value modes for sampler position, duration, and rate.
- LFOs targeting every continuous parameter.
- MIDI input mapped to a dedicated voice instance (separate from the grid sequencer).
- A PSET save/load system that round-trips not only the params but also the user's typed history and per-cell string assignments via a sidecar file.

That is a lot of surface area for a Norns script. The architecture is what makes it tractable. Let's look at it.

## The three-tier architecture

Every layer in this script falls into exactly one of three tiers. Internalizing this division — and the rules for what each tier may and may not do — is the single most useful mental model for working in the codebase.

```
┌─────────────────────────────────────────────────────────────┐
│  CONTROL LAYER (Lua, ~4000 lines)                           │
│  schicksalslied.lua + lib/*.lua                             │
│                                                             │
│  Owns: timing, UI, parameter values, grid handling,         │
│  sequencer state, MIDI, PSET save/load.                     │
│  May NOT: produce sound directly. (Sends OSC to SC.)        │
└─────────────────────────────────────────────────────────────┘
                            ↕  OSC (engine.<command> calls)
┌─────────────────────────────────────────────────────────────┐
│  BRIDGE LAYER (SuperCollider, ~140 lines)                   │
│  lib/Engine_Lied.sc                                         │
│                                                             │
│  Owns: registering commands with Crone.                     │
│  May NOT: do DSP. Each command unpacks an OSC message       │
│  and dispatches to a kernel method on the DSP layer.        │
└─────────────────────────────────────────────────────────────┘
                            ↕  method calls
┌─────────────────────────────────────────────────────────────┐
│  DSP LAYER (SuperCollider, ~1700 lines)                     │
│  lib/Lied.sc + lib/{TriSin,Ringer,Sampler,OneShot}.sc       │
│                                                             │
│  Owns: SynthDefs, voice management, audio buses, FX.        │
│  May NOT: know anything about Lua, grids, or params.        │
│  Receives commands as method calls from the bridge.         │
└─────────────────────────────────────────────────────────────┘
```

Reading the script always starts with finding which tier you're in. A user pressing a grid button is a Control event; the LED that lights up is a Control update; the synth that fires is a DSP event sent down through the Bridge. A `_menu.rebuild_params()` call is only Control; a `Synth.new(\liedDelay, ...)` is only DSP. There's no legitimate reason for code on one tier to invoke code on another except through the documented interface (`engine.<cmd>(...)` going down, no path going up — DSP cannot call into Control).

### Why this split

Norns enforces this split at the technical level. The Lua interpreter and the SC server are separate processes that communicate via OSC. Crone (Norns's engine layer) is what mediates the OSC traffic — your engine class extends `CroneEngine` and uses `this.addCommand(\name, "typespec", { |msg| ... })` to register handlers. The Lua side calls `engine.<name>(...)` which becomes an OSC message; Crone routes it to your handler block.

The pragmatic effect: you cannot accidentally write a function that mixes timing logic with DSP. The barrier is real; you can only get values from Lua to SC by serializing them through an OSC type-spec string. This is what keeps the script's audio rock-solid even when the Lua side is busy (drawing the screen, redrawing the grid, handling MIDI). The audio thread doesn't block on Lua.

`★ Insight ─────────────────────────────────────`
**The OSC barrier is a feature, not a friction**. Many audio frameworks let DSP code and control code share a process and a memory space. That's faster but means a bug in your control code can starve the audio thread. Norns's choice — separate processes, OSC bridge — means a Lua infinite loop will freeze the screen but keep the audio playing. If you ever notice that one half of your script is misbehaving while the other half is fine, this is why: they're literally different programs.

**The cost is the dispatch cost.** Every Lua → SC call serializes the args into an OSC packet, sends it over the local network stack, deserializes on the SC side, and dispatches via Crone's command map. This is fast (sub-millisecond for typical args), but you would never want to do it inside a tight per-sample loop. The convention this script enforces — and that you'll see throughout — is "compute the parameter target on the Lua side, send a single OSC command, let SC slew internally." Don't try to drive a SynthDef parameter from Lua at audio rate.
`─────────────────────────────────────────────────`

## A tour of the file tree

A complete map of the repository. We'll spend at least one chapter on every file listed here.

```
schicksalslied/
├── schicksalslied.lua          ← top-level script: init, params, grid, screen, MIDI
├── README.md
├── lib/
│   ├── Lied.sc                 ← the SC kernel: bus graph, FX, granular chain
│   ├── Engine_Lied.sc          ← Crone wrapper: addCommand registrations
│   ├── TriSin.sc               ← FM voice (triangle carrier, sine modulator)
│   ├── Ringer.sc               ← pinged resonant filter voice
│   ├── Sampler.sc              ← looping sample voice with split-buffer playback
│   ├── OneShot.sc              ← one-shot sample voice
│   ├── sequencer.lua           ← per-cell Sequins state, clock loops, get_rate
│   ├── cell_roles.lua          ← role registry, dispatch_row_2[role], ensure_allocated
│   ├── voice_params.lua        ← every param for every voice cell + sampler + one-shot
│   ├── grid_grain_params.lua   ← granular delay params block
│   ├── lied_lfos.lua           ← LFO definition helper, bound to params
│   ├── midi_input.lua          ← MIDI keyboard → dedicated TriSin/Ringer voice
│   ├── midi_role.lua           ← MIDI-out cell role implementation
│   ├── timing.lua              ← canonical musical-fraction lookup tables
│   ├── wtape_looper.lua        ← w/tape cell role implementation
│   └── text files/             ← example .txt files to load as initial poetry
└── docs/
    ├── superpowers/            ← internal spec + plan documents (not user-facing)
    └── tutorial/               ← this tutorial
```

### What lives where

The split between `schicksalslied.lua` and `lib/*.lua` is informational, not architectural — Lua's `include` (a Norns idiom we'll discuss in chapter 06) glues them all together at load time. The top-level file is large (about 1,400 lines) because it owns the things that don't have a smaller, more focused home: the param tree definition, the grid input handler, the screen redraw routine, the MIDI device init, the PSET sidecar hook. Anything that's a coherent subsystem with a clear interface — sequencer state, role dispatch, voice param blocks, LFOs — lives in `lib/`.

The `.sc` files split for a different reason: SuperCollider's class system. `Engine_Lied`, `Lied`, `TriSin`, `Ringer`, `Sampler`, and `OneShot` are each a class. Each class needs its own file. The split here is dictated by SC's compiler, not by an architectural choice.

### Reading the tour as a learning path

If you wanted to read every file from scratch in the most pedagogically useful order, it would be:

1. `timing.lua` — small, self-contained, introduces the musical-fraction concept the rest of the script uses.
2. `wtape_looper.lua` — small, single-responsibility, gentle introduction to role dispatchers.
3. `Engine_Lied.sc` — small, demonstrates the command-registration pattern.
4. `TriSin.sc` — small, shows the SC voice-class pattern in its simplest form.
5. `Ringer.sc` — similar to TriSin but with a different DSP structure.
6. `OneShot.sc` — adds buffer handling to the voice pattern.
7. `Sampler.sc` — adds looping + split-buffer playback to the voice pattern.
8. `Lied.sc` — the big one; pulls all the voice classes together with the FX chain.
9. `midi_role.lua` — a Lua-side role dispatcher, parallel to the SC voice classes.
10. `cell_roles.lua` — the role registry + dispatch table that ties roles to cells.
11. `sequencer.lua` — Sequins-based per-cell state + clock loops.
12. `lied_lfos.lua` — LFO helper, simple enough to introduce after the params concept.
13. `voice_params.lua` — the big params definition; depends on sequencer + roles being understood.
14. `grid_grain_params.lua` — small, similar pattern to voice_params but for the granular system.
15. `midi_input.lua` — sits above the voices; consumes the voice classes.
16. `schicksalslied.lua` — the top-level integration point that brings everything together.

The chapters in this tutorial are roughly grouped along this path, but rearranged into thematic clusters: SC engine first, then Crone, then a Lua refresher, then the sequencer + roles + params subsystem, then grid + UI + modulation + MIDI + deployment.

## How a sound gets made

Before we go deeper, here's the journey a single note takes from grid press to speaker. This trace is referenced throughout the rest of the tutorial; come back to it if you ever lose track of which layer is in play.

**Setup state.** The user has pressed grid cell (1, 2) — column 1, row 2 — which has been configured (via the params menu, or by default) as a `TriSin` role. They've also typed a line and assigned it to that cell.

**Step 1 (Control).** The user's grid press is delivered to `g.key(x, y, z)` in `schicksalslied.lua`. For a row-2 cell, this routes through a state param (`cell_1_2_state`) which calls `params:set` and fires that param's action.

**Step 2 (Control).** The state param's action writes `Sequencer.Toggled[1][2] = true` and calls `Roles.ensure_allocated(1, 2)`. This is the lazy allocation step: if no SC TriSin instance has been allocated for this cell yet, the dispatcher calls `engine.trisin_alloc("1_2")`. That's an OSC message to SC.

**Step 3 (Bridge).** Crone receives the OSC message and dispatches to the handler registered in `Engine_Lied.sc`. That handler calls `kernel.allocTriSin(\1_2)`.

**Step 4 (DSP).** `allocTriSin` (defined in `Lied.sc`) constructs a new `TriSin.new(...)` instance, passing it the bus indices to write to. The TriSin instance instantiates 8 voice synths in a group. They're silent (envelope gate = 0), waiting to be triggered.

**Step 5 (Control, asynchronous).** Meanwhile, a clock coroutine started at script init has been running for this cell. Each iteration it calls `clock.sync(rate)` to wait for the next beat boundary. Once awakened, it checks `Sequencer.Toggled[1][2]` — now true — and calls `Sequencer.dispatch_fn(1, 2)`, which forwards to `Roles.dispatch(1, 2)`.

**Step 6 (Control).** `Roles.dispatch` looks up the role for column 1 (`'TriSin'`) and calls `Roles.dispatch_row_2['TriSin'](1, 2, seq_fn)`. The TriSin handler reads one byte from the cell's Sequins (the byte stream derived from the assigned text), maps it to a MIDI note via `byte % 32 + 49`, quantizes to scale, converts to Hz, and calls `engine.trisin_trigger("1_2", voice_key, freq)`. That's another OSC message.

**Step 7 (Bridge).** Crone dispatches to the trigger handler, which calls `kernel.triggerTriSin(\1_2, voiceKey, freq)`.

**Step 8 (DSP).** `triggerTriSin` looks up the `TriSin` instance for `'1_2'` and calls its `trigger(voiceKey, freq)` method, which sets the target voice's freq + gate and starts the envelope.

**Step 9 (Audio).** The SC server processes the next audio block. The triggered TriSin synth produces samples, which are written to the dry, reverb, and delay buses according to the per-cell send levels. The FX synths process those buses and sum into the main output. You hear a note.

**Step 10 (Control, parallel).** Back on the Lua side, the dispatch_row_2 handler set `Sequencer.Fire_Decay[1][2] = 4`. A metronome at 15 fps decrements this counter; while it's > 0, the grid redraw paints that cell at level 15 (bright). Over the next ~250 ms the LED fades.

**Step 11 (Loop).** The clock coroutine for cell (1, 2) re-enters its loop and calls `clock.sync(rate)` again, waiting for the next beat. Steps 6–10 repeat as long as Toggled stays true.

That trace touches every layer. Each chapter that follows will deepen one segment of it.

`★ Insight ─────────────────────────────────────`
**Most bugs you'll encounter while developing this script can be localized by asking "at which step did the trace break?"** A bug at step 1 is a grid handler bug. A bug at step 4 is an SC voice initialization bug. A bug at step 6 is a role dispatcher bug. A bug at step 8 is a TriSin voice management bug. Memorizing the trace makes debugging much faster.

**A useful diagnostic technique that follows from this**: instrument one step at a time. If a cell isn't firing, add a `print` to step 5 (the clock coroutine). If the print fires but no audio, add a `print` to step 6 (the dispatcher). And so on. You can usually pinpoint the broken step in two or three debug iterations.
`─────────────────────────────────────────────────`

## The development environment

You will work in three places:

1. **A text editor on your workstation.** Vim, VS Code, Emacs, Helix — anything. You'll edit `.lua` and `.sc` files and copy them to Norns.

2. **SuperCollider IDE on your workstation.** For chapters 02 through 04, you'll evaluate SynthDefs and test voice classes interactively before deploying. Download from [supercollider.github.io](https://supercollider.github.io). Any 3.13+ version is fine.

3. **An SSH session to Norns.** For deploying, reading logs, and running diagnostics. The default user is `we` (no sudo password by default on stock Norns images).

### Deploy mechanism

Norns hosts script files in `/home/we/dust/code/<scriptname>/`. To deploy schicksalslied, you tar the source folder on your workstation, upload it, and extract it on Norns:

```bash
# On your workstation, from the directory CONTAINING schicksalslied/:
tar -czf schicksalslied.tar.gz schicksalslied/

# Upload (Norns runs an SMB share at //norns.local/we and an SSH server):
scp schicksalslied.tar.gz we@norns.local:~/

# Extract on Norns:
ssh we@norns.local
tar -xzf ~/schicksalslied.tar.gz -C /home/we/dust/code/
```

After deploy, on the Norns: hit SELECT to navigate to the script picker, find `schicksalslied`, and select it. The script will start.

### When to reboot Norns

**You must reboot Norns** any time you change an `.sc` file. Norns's SC class library is compiled at boot; changes to `.sc` files don't take effect until the next boot. A "soft" script reload (re-selecting the script in SELECT) is not enough.

To reboot Norns:

- If your Norns is **wall-powered** (no battery): unplug, wait a few seconds, plug back in.
- If your Norns has a **battery** (Norns shield with battery, or some retrofits): pulling the power doesn't actually power it off. Use SLEEP from the on-device menu, then **hold K1** to power back on.

`★ Insight ─────────────────────────────────────`
**`system → restart` is not a full reboot.** Norns's on-device "restart" option re-runs script init but does not re-compile the SC class library. If you've changed any `.sc` file, you must do a full power cycle. Failing to do this is one of the most common "but I changed the code, why is the old behavior still there?" moments.

**The matron scheduler can also wedge** — a state where Lua coroutines stop being scheduled even though the script appears to be running. This is rare, but when it happens, only a full power cycle clears it (not `system → restart`). If your script's clock-driven behavior stops working but you can still run REPL commands, suspect a wedged scheduler. Chapter 11 covers diagnostics for this.
`─────────────────────────────────────────────────`

### Reading Norns's logs

When something goes wrong, the matron log is your first source of truth. Two ways to read it:

- **Maiden** (the in-browser editor that Norns serves at `http://norns.local/`). The REPL pane at the bottom shows matron output in real time. Type Lua expressions to inspect script state.
- **Direct file** (over SSH): `tail -f /home/we/dust/log/matron.log` (or check the location for your Norns image; some have it under `/var/log/norns/`).

For SuperCollider errors, the sclang REPL is the place. Open Maiden, and you'll see a separate pane for the SuperCollider repl. Errors from `Buffer.read`, `SynthDef` compilation, and engine alloc all appear here.

## Working through the rest of this tutorial

The remaining ten chapters take you from a blank Norns script directory to a fully working schicksalslied 2.0. Each chapter is intended to take 30 to 90 minutes of attentive reading + typing.

The first time you build the script, expect to spend roughly 10 to 15 hours total. That sounds like a lot, but you're not just copying — you're learning. By the end you'll be comfortable enough with the architecture to modify it: add a new voice role, change the granular chain's grain count, extend the sequencer with a new mode.

### Suggested working method

- **Build incrementally.** After each chapter, deploy what you have to Norns and verify the checkpoint. Don't try to write the whole script offline and then test all at once — you'll spend longer hunting bugs than you would have spent on the incremental builds.
- **Read the surrounding code.** When a chapter references a function from a different file, take a minute to look it up. The tutorial annotates the function you're focused on, but understanding the call sites helps you remember why the function exists.
- **Type, don't paste.** Typing the code yourself anchors it in your memory in a way that pasting doesn't. You'll catch implicit assumptions about indentation, scope, and ordering that you'd miss reading.
- **Jump back to chapters as reference.** Each chapter (03-08 and 10-19) covers exactly one source file. When you're modifying a specific file and want to look up an idiom, you can jump straight to its chapter without re-reading from the beginning.

### What to expect from chapter 02

Chapter 02 reviews the SuperCollider concepts this script depends on: server-side buses, groups (and why ordering within a group matters), `SynthDef` basics, and — most importantly for this script — the difference between SC's real-time memory pool and its server-side heap. You'll evaluate small `SynthDef` examples in SC IDE to make sure each concept is fresh in mind before chapter 03 dives into `Lied.sc`.

If you already write SuperCollider regularly, chapter 02 will be a refresher and you can skim it. If you're newer to SC, take it slow — chapter 03 is denser and assumes the chapter 02 material.

## Chapter 01 checkpoint

There is no code to write yet. The checkpoint for this chapter is environmental:

- [ ] You can SSH into Norns as user `we`.
- [ ] You can SCP files from your workstation to Norns.
- [ ] You have SuperCollider IDE running on your workstation.
- [ ] You know whether your Norns has a battery and the matching power-cycle gesture.
- [ ] You have a USB keyboard (or are prepared to drive the script via grid + params only).
- [ ] You can find the matron log (either through Maiden's REPL pane or via SSH).

If all six boxes are checked, you're ready for chapter 02.

## Optional further reading

If you want background on the broader ecosystem before diving in:

- [Norns Studies, Study 0–5](https://monome.org/docs/norns/studies/) — the canonical introduction to Norns scripting. Reading 0–3 will give you a solid base in Lua + Norns conventions before chapter 06.
- [Norns Clocks documentation](https://monome.org/docs/norns/clocks/) — the clock API is central to schicksalslied's per-cell timing; chapter 07 assumes you've at least skimmed this.
- [Norns Grid Recipes](https://monome.org/docs/norns/grid-recipes/) — patterns for grid handlers. Chapter 10 builds on these.
- [Norns Engine Studies 1–3](https://monome.org/docs/norns/engine-study-1/) — the canonical introduction to writing a Crone engine. Chapters 02–05 assume you're at least conversant with the engine-study-1 material.

Reading the Norns Studies in advance is not required — this tutorial teaches everything it needs from scratch — but the Studies are well-written and free, and they give you a second voice on the material, which often helps. If you want a "first read both at once" approach, pair this tutorial's chapter 06 with Norns Studies 0–3 and read them side by side.

## What's next

**Chapter 02 — SuperCollider Fundamentals** covers the SC concepts you'll need for chapters 03 and 04: buses, groups, SynthDef structure, the real-time memory pool. Each concept is demonstrated with a small runnable example you can evaluate in SC IDE on your workstation. By the end of chapter 02, you'll have a basic working SynthDef that you can deploy and trigger from sclang, setting up the move to the full `Lied.sc` kernel in chapter 03.
