# schicksalslied 2.0 — Sub-plan B: Lua control layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Lua control layer for schicksalslied 2.0 — replaces the 1.x main script wholesale, adds per-cell sequencer logic, role dispatch for all 10 row-2 roles, w/tape looper port, keyboard/grid/screen UI, K1/K2/K3 hardware actions, and the SC engine command surface that the Lua layer needs to drive the kernel built in Sub-plan A. End state: deploy the project to a Norns device and verify on hardware — type a line, hit Enter, grid-press to assign to a cell, toggle the cell on, hear the SC engine respond appropriately for that cell's role.

**Architecture:** Lua side rebuilt around two state managers — `sequencer.lua` owns the per-cell sequins + toggle flags + clock-loop lifecycle + seq/value mode runtimes; `cell_roles.lua` owns the role enum + per-role dispatch + lazy allocation of SC voice instances. Main script (`schicksalslied.lua`) is the orchestrator: it sets up state, wires the keyboard/grid/screen handlers, calls `crow_reinit()` at boot (and via a params trigger), and starts the 61 clock loops. `wtape_looper.lua` extracts the 1.x `looper()` choreography and rewires it to per-cell sequins (one of the 10 row-2 role dispatches). On the SC side, Sub-plan A's `Lied.sc` kernel gains methods for allocating/freeing/triggering voice instances by cell ID; `Engine_Lied.sc` exposes those as new Crone commands.

**Tech Stack:** Norns Lua (norns.lua API + `crow`, `grid`, `screen`, `keyboard`, `params`, `engine`, `clock`, `Sequins`, `MusicUtil`, `softcut`-not-used, `audio`), SuperCollider CroneEngine (extensions to Sub-plan A's `Lied.sc` + `Engine_Lied.sc`), OSC for crone-bridge. No Lua test framework (Norns development is hardware-deploy-and-observe).

**Reference projects in this workspace:**
- `naherinlied/seamstress-stuff/naherinlied.lua` — donor for grid handler + keyboard handler + grid layout
- `naherinlied/naherinlied.scd:498-720` — donor for the OSC `_receiver` dispatch idiom (which Sub-plan A's Crone commands replace)
- `norns-ritual/norns-ritual/lib/ritual_lib.lua` — donor for "muted not destroyed" sequence pattern, clock-loop discipline
- `schicksalslied/schicksalslied.lua` (1.x, in this repo) — current main script, source for the keyboard handler base structure and the looper() function (Task 4.1)
- `schicksalslied/lib/*.sc` (after Sub-plan A) — the SC engine layer this layer drives

**Reference spec:** `schicksalslied/docs/superpowers/specs/2026-05-13-schicksalslied-2-0-design.md` — §3 (grid layout), §4 (allocation strategy), §7 (sequencing model: per-cell sequins, seq mode, value mode, text input flow), §8 (crow integration including the `crow_reinit()` function), §11 (UI: screen, keyboard, K1/K2/K3, grid LED brightness), §12 (behavioral changes vs 1.x — things removed not just files), §13 (migration — what removed, what added).

---

## Pre-flight

### Sub-plan B scope (which spec items)

- §3 (grid layout & cell roles): row 1 history, row 2 role-configurable, rows 3/5/7 assign-to-sequins, rows 4/6 sampler trigger+rate alternation, row 8 one-shot + mic/granular controls
- §4 (lazy allocation strategy): TriSin/Ringer per row-2 cell, samplers per loaded slot, one-shots per loaded slot. Engine command surface to allocate/free/trigger.
- §7 (sequencing model): per-cell `Seq[x][y]` with raw ASCII bytes, role-based dispatch with role-specific mapping, seq_mode (timing) and value_mode (rate/duration/position) runtime, clock-loop lifecycle, two-variable text input model (`Displayed_String` + `My_String`)
- §8 (crow integration): all 10 row-2 roles (TriSin, Ringer, crow 1+2, crow 3+4, JF, JF run, JF quantize, w/syn, w/del, w/tape looper), `crow_reinit()` function + re-init trigger
- §11 (UI): screen layout (two-string), keyboard handler, K1=panic / K2=pause-resume / K3=tap-tempo, grid LED brightness scheme (row 1: 0/4/15, rows 2/4/6/8: 0/15, rows 3/5/7: 4/15)

### Sub-plan B out of scope (deferred to Sub-plan C)

- Params menu structure (the ~7000-param hierarchy with hide-discipline). Sub-plan B exposes only the bare minimum params: the file params per sampler/one-shot slot, the `wsyn_voices` setup param, the `reinit_crow` trigger. Per-cell role params, per-cell seq_mode + value_mode configs, per-voice voice-class params, LFOs — all deferred.
- LFO bind machinery (depth-driven implicit start/stop wrapping)
- PSET round-trip verification
- Full soak test
- Sample loading via params:add{type='file'} (until Sub-plan C the slots default to no-file-loaded; voices are not loaded; samplers/one-shots cannot fire until Sub-plan C wires the params)

The consequence: Sub-plan B's deliverable is functional for the row-2 roles (TriSin, Ringer, crow ecosystem) but NOT yet for sampler/one-shot rows 4/6/8 cells (those need their params menu items to load files). Sub-plan B's verification will exercise row 2 thoroughly and row 8 cols 14-16 (mic/granular controls); rows 4/6/8 cells 1-13 are verified as "no crashes when triggered with empty slot" but no audio.

### Working directory + git context

`/Users/spencergraham/Desktop/other/lied-update/schicksalslied/` (its own git repo). HEAD should be the latest commit from Sub-plan A's test-fix run. Verify with:

```bash
git -C /Users/spencergraham/Desktop/other/lied-update/schicksalslied/ log -1 --format="%H %s"
```

Sub-plan B's commits will continue on the same branch. Each task commits before moving on.

### File structure produced by this plan

**Removed:**
```
schicksalslied/
  schicksalslied.lua            (1.x version — replaced wholesale)
  lib/
    LiedMotor_engine.lua        (1.x legacy)
    Engine_LiedMotor.sc         (1.x legacy)
    lied_lfo.lua                (1.x bundled LFO library; replaced by standard 'lfo' in Sub-plan C)
  ignore/                       (FormantTriPTR install material; tritri voice was dropped)
```

**Created / heavily rewritten:**
```
schicksalslied/
  schicksalslied.lua            (2.0 main script — total rewrite)
  lib/
    cell_roles.lua              (role enum + dispatch table + lazy alloc)
    sequencer.lua               (per-cell sequins, toggle state, clock loops, seq/value mode runtimes)
    wtape_looper.lua            (port of 1.x looper(), rewired to per-cell sequins)
```

**Modified (Sub-plan A extensions):**
```
schicksalslied/
  lib/
    Lied.sc                     (add voice/sampler/oneshot lifecycle methods + file-load helpers)
    Engine_Lied.sc              (add corresponding Crone commands)
    OneShot.sc                  (add triggerWithRate method for combined rate-set + retrigger)
```

**Unchanged from Sub-plan A:**
```
schicksalslied/
  test.scd                      (SC-only tests — Sub-plan A's verification harness stays usable for SC regressions)
  audio/test_*.wav              (SC-only test audio files; row-4/6/8 cells will use these via params after Sub-plan C)
  lib/
    TriSin.sc Ringer.sc Sampler.sc  (no changes; their methods are sufficient)
```

### Ground rules

- **Single git repo:** all work in `schicksalslied/`. Commits cascade through Sub-plan B's commits, picking up after Sub-plan A's HEAD.
- **No automated test harness for the Lua layer.** Norns has no built-in unit test framework. We do not introduce one. Verification = manual on Norns hardware, per the checklist in Phase 6.
- **SC regression check:** after every Sub-plan A SC modification (Phase 1's Tasks 1.2-1.4), `sclang test.scd` must still pass cleanly. We don't break Sub-plan A's verified state.
- **Norns API discipline:** use `clock`, `grid`, `screen`, `keyboard`, `params`, `engine` exactly as Norns specifies. The reference implementations (`naherinlied`, `norns-ritual`, current `schicksalslied`) demonstrate idiom. Don't invent.
- **No `Sequins` mocking off-Norns:** the Lua code uses Norns's `sequins` library directly. Off-Norns smoke tests are not in scope.
- **PSET hooks deferred:** params are added in Phase 5 only for the file-load and `reinit_crow` triggers. The per-cell role/mode params are stub-only (they exist as placeholders so `cell_roles` and `sequencer` can read defaults). Sub-plan C fills them in fully.

### Verification strategy

Sub-plan B has three verification milestones:

1. **After Phase 1** (SC engine extensions): `sclang test.scd` still passes — verifies Sub-plan A regressions are absent.
2. **After Phase 5** (full Lua wiring): syntax check via `luac -p` on every Lua file — verifies no syntax errors.
3. **After Phase 6** (Norns deploy): manual hardware verification per the Phase 6 checklist — verifies the full integrated script works in performance context.

We do NOT deploy after each phase. The script's intermediate states between phases are not bootable Norns scripts (e.g., after Phase 2 there is `sequencer.lua` but no entry point in `schicksalslied.lua` yet). Sub-plan B's complete state at the end of Phase 5 is the first deployable state.

---

## Phase 1 — SC engine command surface + legacy cleanup

Add the command surface that Sub-plan B's Lua layer will call into. Sub-plan A's `Lied` kernel created instance registries but didn't expose allocation/free/trigger. Also: remove the 1.x legacy files so the new 2.0 script doesn't accidentally inherit them.

### Task 1.1 — Remove 1.x legacy files

**Files:**
- Delete: `schicksalslied/lib/LiedMotor_engine.lua`
- Delete: `schicksalslied/lib/Engine_LiedMotor.sc`
- Delete: `schicksalslied/lib/lied_lfo.lua`
- Delete: `schicksalslied/ignore/` (whole directory)
- Also clean up the corresponding `~/Library/Application Support/SuperCollider/Extensions/schicksalslied/` if any 1.x symlinks linger

- [ ] **Step 1: Verify legacy files exist and are tracked**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
ls lib/LiedMotor_engine.lua lib/Engine_LiedMotor.sc lib/lied_lfo.lua 2>&1
ls -la ignore/ 2>&1
git ls-files lib/LiedMotor_engine.lua lib/Engine_LiedMotor.sc lib/lied_lfo.lua ignore/
```

Expected: all four are listed. If any are missing, that's an unexpected state — STOP and report BLOCKED.

- [ ] **Step 2: Remove the legacy files**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git rm lib/LiedMotor_engine.lua lib/Engine_LiedMotor.sc lib/lied_lfo.lua
git rm -r ignore/
git status
```

`git status` should show only deletions; no other unexpected changes.

- [ ] **Step 3: Check for stray local SC Extensions symlinks**

```bash
ls -la "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/" 2>/dev/null
```

This directory should contain symlinks only for the 2.0 classes (`Lied.sc`, `TriSin.sc`, `Ringer.sc`, `Sampler.sc`, `OneShot.sc`) — five symlinks. If you see `Engine_LiedMotor.sc` or `LiedMotor_engine.lua` here, remove them:

```bash
rm -f "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/Engine_LiedMotor.sc"
rm -f "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/LiedMotor_engine.lua"
ls "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/"
```

After cleanup, you should see exactly: `Lied.sc TriSin.sc Ringer.sc Sampler.sc OneShot.sc`.

- [ ] **Step 4: Verify sclang test.scd still works**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

All 16+ tests should still print and pass. Exit 0. No `*** ERROR`. This confirms no Sub-plan A regression from removing the legacy files (the 2.0 SC classes don't depend on any 1.x file).

- [ ] **Step 5: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git commit -m "schicksalslied 2.0: remove 1.x legacy files

Sub-plan B, Task 1.1. Deletes lib/LiedMotor_engine.lua, lib/
Engine_LiedMotor.sc, lib/lied_lfo.lua, and the ignore/ folder
(FormantTriPTR install material for the dropped tritri voice).
The 2.0 SC classes from Sub-plan A do not reference any of these.
test.scd still passes cleanly."
```

### Task 1.2 — Add voice/sampler/one-shot lifecycle methods to Lied kernel

The Lua dispatch needs to allocate, free, trigger, and set params on per-cell voice instances. Add kernel-level methods that manage the instance registries (`triSinInstances`, `ringerInstances`, `samplerInstances`, `oneShotInstances`) populated in Sub-plan A but never exposed.

**Files:**
- Modify: `schicksalslied/lib/Lied.sc`

- [ ] **Step 1: Add TriSin lifecycle methods to Lied**

In `lib/Lied.sc`, find the existing `setFbPatchSineHz` method (last of the granular control methods added in Sub-plan A's Task 4.3). After it, add:

```supercollider
    // -----------------------------------------------------------------
    // TriSin instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocTriSin { arg cellId;
        if (triSinInstances[cellId].isNil) {
            triSinInstances[cellId] = TriSin.new;
            ("TriSin allocated: " ++ cellId).postln;
        }
    }

    freeTriSin { arg cellId;
        var inst = triSinInstances[cellId];
        if (inst.notNil) {
            inst.free;
            triSinInstances[cellId] = nil;
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
        }
    }
```

- [ ] **Step 2: Add Ringer lifecycle methods**

After the TriSin methods, add:

```supercollider
    // -----------------------------------------------------------------
    // Ringer instance lifecycle (per row-2 cell)
    // -----------------------------------------------------------------

    allocRinger { arg cellId;
        if (ringerInstances[cellId].isNil) {
            ringerInstances[cellId] = Ringer.new;
            ("Ringer allocated: " ++ cellId).postln;
        }
    }

    freeRinger { arg cellId;
        var inst = ringerInstances[cellId];
        if (inst.notNil) {
            inst.free;
            ringerInstances[cellId] = nil;
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
        }
    }
```

- [ ] **Step 3: Add Sampler lifecycle methods**

After the Ringer methods, add:

```supercollider
    // -----------------------------------------------------------------
    // Sampler instance lifecycle (per row-4/6 slot, 1-16)
    // -----------------------------------------------------------------

    loadSampler { arg slot, filePath;
        var buf;
        fork {
            if (samplerInstances[slot].notNil) {
                this.clearSampler(slot);
            };
            buf = Buffer.read(server, filePath);
            server.sync;
            samplerInstances[slot] = Sampler.new(buf);
            ("Sampler " ++ slot ++ " loaded: " ++ filePath).postln;
        };
    }

    clearSampler { arg slot;
        var inst = samplerInstances[slot];
        if (inst.notNil) {
            inst.buffer.free;
            inst.free;
            samplerInstances[slot] = nil;
            ("Sampler " ++ slot ++ " cleared").postln;
        }
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
        }
    }
```

- [ ] **Step 4: Add OneShot lifecycle methods**

After the Sampler methods, add:

```supercollider
    // -----------------------------------------------------------------
    // OneShot instance lifecycle (per row-8 slot, 1-13)
    // -----------------------------------------------------------------

    loadOneShot { arg slot, filePath;
        var buf;
        fork {
            if (oneShotInstances[slot].notNil) {
                this.clearOneShot(slot);
            };
            buf = Buffer.read(server, filePath);
            server.sync;
            oneShotInstances[slot] = OneShot.new(buf);
            ("OneShot " ++ slot ++ " loaded: " ++ filePath).postln;
        };
    }

    clearOneShot { arg slot;
        var inst = oneShotInstances[slot];
        if (inst.notNil) {
            inst.buffer.free;
            inst.free;
            oneShotInstances[slot] = nil;
            ("OneShot " ++ slot ++ " cleared").postln;
        }
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
        }
    }
```

(Note: `triggerOneShot` uses `triggerWithRate` which we add to `OneShot.sc` in Task 1.3.)

- [ ] **Step 5: Verify sclang test.scd still passes**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

All existing tests should still print and pass (no new tests yet — the new methods aren't being exercised). Exit 0. No `*** ERROR`.

If you see `*** ERROR: ...triggerWithRate...`, that's expected and the test would fail. But since `triggerOneShot` is not yet called in tests, it won't error. Continue.

- [ ] **Step 6: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/Lied.sc
git commit -m "schicksalslied 2.0: Lied kernel voice/sampler/oneshot lifecycle methods

Sub-plan B, Task 1.2. Adds public methods on Lied kernel for:
- TriSin / Ringer per-cell: alloc, free, trigger, setParam
- Sampler / OneShot per-slot: load (Buffer.read + new), clear,
  trigger, setParam
Used by the Lua dispatch layer in Sub-plan B's later phases to
lazy-allocate voice instances and route trigger/param events.
File loading runs in a fork{} with server.sync so the Buffer is
ready before the SC class instance wraps it."
```

### Task 1.3 — Add `triggerWithRate` to OneShot

The OneShot class needs a method that sets the playback rate and triggers in a single OSC message (one `.set` with both `\rate` and `\t_gate`). This avoids the OSC ordering race where `\t_gate` could fire before `\rate` settles.

**Files:**
- Modify: `schicksalslied/lib/OneShot.sc`

- [ ] **Step 1: Add `triggerWithRate` method to OneShot**

In `lib/OneShot.sc`, find the existing `playVoice` method. After it, before `trigger`, add:

```supercollider
    // Trigger a voice with a specific rate, set + retrigger in one OSC message.
    // Used by Lied.triggerOneShot for one-shot cells where the rate comes
    // from the cell's value_mode runtime (per Sub-plan B's sequencer).
    triggerWithRate {
        arg voiceKey, rate;
        voiceParams[voiceKey][\rate] = rate;
        if (singleVoices[voiceKey].isPlaying, {
            singleVoices[voiceKey].set(\rate, rate, \t_gate, 1);
        }, {
            Synth.new("OneShot", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
            NodeWatcher.register(singleVoices[voiceKey], true);
        });
    }
```

- [ ] **Step 2: Verify sclang test.scd still passes**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

All existing tests should still print and pass. The new method is added but not called by any test. Exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/OneShot.sc
git commit -m "schicksalslied 2.0: OneShot.triggerWithRate

Sub-plan B, Task 1.3. Adds triggerWithRate method to OneShot
class: sets \\rate and \\t_gate in one combined .set() call
to avoid OSC ordering race. Called by Lied.triggerOneShot
(Task 1.2). Used by the Lua dispatch for one-shot cells where
per-trigger rate comes from the cell's value_mode runtime."
```

### Task 1.4 — Add Crone commands for voice/sampler/one-shot lifecycle in Engine_Lied

The Lua side calls these via `engine.<command_name>(...)`. Each command unpacks the OSC message and calls the corresponding `Lied` kernel method.

**Files:**
- Modify: `schicksalslied/lib/Engine_Lied.sc`

- [ ] **Step 1: Add the 16 new commands**

In `lib/Engine_Lied.sc`, find the last existing command (`\set_fb_sine_hz` from Sub-plan A's Task 4.3). After it, add:

```supercollider
        // -----------------------------------------------------------------
        // Voice instance lifecycle (per row-2 cell, cellId is string)
        // -----------------------------------------------------------------

        this.addCommand(\trisin_alloc, "s", { arg msg;
            kernel.allocTriSin(msg[1].asSymbol);
        });
        this.addCommand(\trisin_free, "s", { arg msg;
            kernel.freeTriSin(msg[1].asSymbol);
        });
        this.addCommand(\trisin_trigger, "sif", { arg msg;
            var cellId = msg[1].asSymbol;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var freq = msg[3];
            kernel.triggerTriSin(cellId, voiceKey, freq);
        });
        this.addCommand(\trisin_set_param, "ssf", { arg msg;
            kernel.setTriSinParam(msg[1].asSymbol, msg[2].asSymbol, msg[3]);
        });

        this.addCommand(\ringer_alloc, "s", { arg msg;
            kernel.allocRinger(msg[1].asSymbol);
        });
        this.addCommand(\ringer_free, "s", { arg msg;
            kernel.freeRinger(msg[1].asSymbol);
        });
        this.addCommand(\ringer_trigger, "sif", { arg msg;
            var cellId = msg[1].asSymbol;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var freq = msg[3];
            kernel.triggerRinger(cellId, voiceKey, freq);
        });
        this.addCommand(\ringer_set_param, "ssf", { arg msg;
            kernel.setRingerParam(msg[1].asSymbol, msg[2].asSymbol, msg[3]);
        });

        // -----------------------------------------------------------------
        // Sampler instance lifecycle (per row-4/6 slot, integer 1-16)
        // -----------------------------------------------------------------

        this.addCommand(\sampler_load, "is", { arg msg;
            kernel.loadSampler(msg[1].asInteger, msg[2].asString);
        });
        this.addCommand(\sampler_clear, "i", { arg msg;
            kernel.clearSampler(msg[1].asInteger);
        });
        this.addCommand(\sampler_trigger, "iifff", { arg msg;
            var slot = msg[1].asInteger;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var startPos = msg[3];
            var endPos = msg[4];
            var rate = msg[5];
            kernel.triggerSampler(slot, voiceKey, startPos, endPos, rate);
        });
        this.addCommand(\sampler_set_param, "isf", { arg msg;
            kernel.setSamplerParam(msg[1].asInteger, msg[2].asSymbol, msg[3]);
        });

        // -----------------------------------------------------------------
        // OneShot instance lifecycle (per row-8 slot, integer 1-13)
        // -----------------------------------------------------------------

        this.addCommand(\oneshot_load, "is", { arg msg;
            kernel.loadOneShot(msg[1].asInteger, msg[2].asString);
        });
        this.addCommand(\oneshot_clear, "i", { arg msg;
            kernel.clearOneShot(msg[1].asInteger);
        });
        this.addCommand(\oneshot_trigger, "iif", { arg msg;
            var slot = msg[1].asInteger;
            var voiceKey = msg[2].asInteger.asString.asSymbol;
            var rate = msg[3];
            kernel.triggerOneShot(slot, voiceKey, rate);
        });
        this.addCommand(\oneshot_set_param, "isf", { arg msg;
            kernel.setOneShotParam(msg[1].asInteger, msg[2].asSymbol, msg[3]);
        });
```

- [ ] **Step 2: Verify sclang test.scd still passes**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

All existing tests should still print and pass. The new commands are registered but not called by any test (since test.scd doesn't simulate Lua-side OSC). Exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/Engine_Lied.sc
git commit -m "schicksalslied 2.0: Engine_Lied lifecycle commands

Sub-plan B, Task 1.4. Adds 16 Crone commands wrapping the
kernel lifecycle methods from Task 1.2: trisin/ringer alloc,
free, trigger, set_param (cellId as string symbol; voiceKey as
integer converted to symbol \\1..\\8); sampler/oneshot load,
clear, trigger, set_param (slot as integer 1-16/1-13).

The Lua dispatch in Sub-plan B's later phases will call these
via engine.trisin_trigger, engine.sampler_load, etc."
```

---

## Phase 2 — sequencer.lua

The state manager for per-cell sequins, toggle flags, clock loops, and the seq/value mode runtimes. Single file at `lib/sequencer.lua`. Loaded by `schicksalslied.lua` via `Sequencer = include 'lib/sequencer'`.

### Task 2.1 — Module skeleton + state tables

**Files:**
- Create: `schicksalslied/lib/sequencer.lua`

- [ ] **Step 1: Write the module skeleton**

```lua
-- lib/sequencer.lua — schicksalslied 2.0 per-cell sequins + clock-loop state
-- Owns: Seq[x][y], Toggled[x][y], Momentary[x][y], clock_ids[x][y]
-- Owns: seq_mode and value_mode runtime calculations per cell
-- Loaded once by schicksalslied.lua's init().
--
-- Cell ID convention:
--   - Lua-internal cell key: composite "<col>_<row>" string (e.g., "3_2" for col 3, row 2)
--   - SC-side cellId: same string symbol (\3_2 etc.)
--   - Cells exist for rows 2, 4, 6, 8 (toggle rows); state for rows 1/3/5/7 is just
--     Momentary[x][y] for LED feedback during press.

local Sequins = require 'sequins'
local Sequencer = {}

-- ========================================================================
-- STATE TABLES
-- ========================================================================

-- Per-cell sequins (raw ASCII byte values). Indexed Seq[x][y].
Sequencer.Seq = {}

-- Per-cell toggle state (sequencer-enabled). Indexed Toggled[x][y].
Sequencer.Toggled = {}

-- Per-cell momentary state (grid key held down). For LED brightness.
Sequencer.Momentary = {}

-- Per-cell clock loop ID (returned by clock.run). Indexed Clock_Ids[x][y].
Sequencer.Clock_Ids = {}

-- Per-cell "fire pulse" decay counter (for currently-firing LED flash visual).
-- Currently unused in Phase 2 — populated/decayed in Phase 5's grid_redraw.
Sequencer.Fire_Decay = {}

-- Global pause flag. K2 toggles this; pause is clock-quantized via pause_pending.
Sequencer.Paused = false
Sequencer.Pause_Pending = false
Sequencer.Unpause_Pending = false

-- ========================================================================
-- INITIALIZATION
-- ========================================================================

-- Build empty state tables for all grid cells.
-- Toggle rows (sequencer-enabled): 2, 4, 6, 8
-- Momentary-only rows: 1, 3, 5, 7
-- All rows 1-8 cols 1-16 get Momentary state for LED feedback.
function Sequencer.init()
    for x = 1, 16 do
        Sequencer.Seq[x] = {}
        Sequencer.Toggled[x] = {}
        Sequencer.Momentary[x] = {}
        Sequencer.Clock_Ids[x] = {}
        Sequencer.Fire_Decay[x] = {}
        for y = 1, 8 do
            Sequencer.Seq[x][y] = Sequins({ string.byte(" ") })
            Sequencer.Toggled[x][y] = false
            Sequencer.Momentary[x][y] = false
            Sequencer.Clock_Ids[x][y] = nil
            Sequencer.Fire_Decay[x][y] = 0
        end
    end
end

return Sequencer
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/sequencer.lua && echo "OK"
```

Expected: `OK` printed. If `luac -p` reports a syntax error, fix it before committing.

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/sequencer.lua
git commit -m "schicksalslied 2.0: sequencer.lua skeleton with state tables

Sub-plan B, Task 2.1. Creates lib/sequencer.lua module with
state tables (Seq, Toggled, Momentary, Clock_Ids, Fire_Decay)
indexed by [x][y] across the 16x8 grid. Seq[x][y] is initialized
to Sequins({ ' ' as byte }) for every cell. Toggled/Momentary
default false. Pause flags (Paused, Pause_Pending, Unpause_Pending)
are scalar module state. Sequencer.init() called once by
schicksalslied.lua's init()."
```

### Task 2.2 — ASCII string→bytes helper + sequins assignment

**Files:**
- Modify: `schicksalslied/lib/sequencer.lua`

- [ ] **Step 1: Add string-to-bytes conversion + assign function**

In `lib/sequencer.lua`, after `Sequencer.init()` and before `return Sequencer`, add:

```lua
-- ========================================================================
-- ASCII / SEQUINS HELPERS
-- ========================================================================

-- Convert a Lua string to a table of ASCII byte values.
-- Empty string returns { string.byte(' ') } as a safe placeholder.
function Sequencer.string_to_bytes(s)
    if s == nil or #s == 0 then
        return { string.byte(" ") }
    end
    local t = {}
    for i = 1, #s do
        table.insert(t, string.byte(s, i))
    end
    return t
end

-- Assign a new byte sequence to the cell's Sequins instance.
-- Used by odd-row grid presses (rows 3, 5, 7) which target the cell ABOVE
-- in the corresponding even row (y - 1).
function Sequencer.assign(x, y, str)
    if Sequencer.Seq[x] and Sequencer.Seq[x][y] then
        Sequencer.Seq[x][y]:settable(Sequencer.string_to_bytes(str))
    end
end

-- Read the next byte from a cell's sequins. Returns the raw byte value.
-- Called by cell_roles.dispatch for the cell's role-specific mapping.
function Sequencer.next_byte(x, y)
    if Sequencer.Seq[x] and Sequencer.Seq[x][y] then
        return Sequencer.Seq[x][y]()
    end
    return string.byte(" ")
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/sequencer.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/sequencer.lua
git commit -m "schicksalslied 2.0: sequencer.lua ASCII helpers

Sub-plan B, Task 2.2. Adds three helpers:
- string_to_bytes(s): converts Lua string to ASCII byte array
  (empty string returns { byte(' ') } as safe placeholder)
- assign(x, y, str): updates a cell's sequins with new bytes;
  called by row 3/5/7 grid presses to retarget the cell above
- next_byte(x, y): reads next byte from cell's sequins; called
  by cell_roles.dispatch for role-specific mapping."
```

### Task 2.3 — Clock loop infrastructure

Each toggle cell (rows 2, 4, 6, 8) gets one always-running `clock.run` loop that calls into role dispatch when toggled-on and not paused. The rate per tick comes from the cell's seq_mode runtime (Task 2.4 below).

**Files:**
- Modify: `schicksalslied/lib/sequencer.lua`

- [ ] **Step 1: Add the clock-loop factory + lifecycle**

In `lib/sequencer.lua`, after the ASCII helpers and before `return Sequencer`, add:

```lua
-- ========================================================================
-- CLOCK LOOPS (per toggle cell)
-- ========================================================================

-- Forward reference: set by schicksalslied.lua's init() to cell_roles.dispatch.
-- Decoupled from cell_roles here so sequencer doesn't require cell_roles at load time.
Sequencer.dispatch_fn = nil

-- Returns a coroutine body for cell [x][y]. Runs forever; gates on Toggled + Paused.
local function step_for(x, y)
    return function()
        while true do
            clock.sync(Sequencer.get_rate(x, y))
            if Sequencer.Toggled[x][y] and (not Sequencer.Paused) then
                if Sequencer.dispatch_fn then
                    Sequencer.dispatch_fn(x, y)
                end
                -- Bump fire decay for LED flash visual (consumed by grid_redraw)
                Sequencer.Fire_Decay[x][y] = 4
            end
        end
    end
end

-- Start one clock loop per toggle cell (rows 2, 4, 6, 8 × 16 cols = 64 loops).
-- Note: row 8 cols 14-16 are NOT sequencer triggers (they're mic/granular
-- on/off toggles); their clock loops still run but their roles do nothing
-- on tick. See cell_roles.lua's row-8 cols 14-16 handling.
function Sequencer.start_all_clocks()
    for x = 1, 16 do
        for y = 2, 8, 2 do  -- rows 2, 4, 6, 8
            Sequencer.Clock_Ids[x][y] = clock.run(step_for(x, y))
        end
    end
end

-- Stop all clock loops. Called from schicksalslied.cleanup().
function Sequencer.stop_all_clocks()
    for x = 1, 16 do
        for y = 2, 8, 2 do
            if Sequencer.Clock_Ids[x][y] then
                clock.cancel(Sequencer.Clock_Ids[x][y])
                Sequencer.Clock_Ids[x][y] = nil
            end
        end
    end
end

-- ========================================================================
-- PAUSE / RESUME (K2 — clock-quantized)
-- ========================================================================

-- K2 press handler. Toggles Paused via a 1-beat-quantized pending flag.
-- Pause arrives on the next beat boundary; resume similarly delayed.
function Sequencer.toggle_pause()
    if Sequencer.Paused then
        if not Sequencer.Unpause_Pending then
            Sequencer.Unpause_Pending = true
            clock.run(function()
                clock.sync(1)
                Sequencer.Paused = false
                Sequencer.Unpause_Pending = false
            end)
        end
    else
        if not Sequencer.Pause_Pending then
            Sequencer.Pause_Pending = true
            clock.run(function()
                clock.sync(1)
                Sequencer.Paused = true
                Sequencer.Pause_Pending = false
            end)
        end
    end
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/sequencer.lua && echo "OK"
```

Note: `Sequencer.get_rate` is referenced but not yet defined — that's added in Task 2.4. `luac -p` won't catch this (it's a runtime resolution); the script will syntax-check fine but error at runtime if called before Task 2.4 completes. Don't run it until Task 2.4 lands.

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/sequencer.lua
git commit -m "schicksalslied 2.0: sequencer.lua clock-loop infrastructure

Sub-plan B, Task 2.3. Adds:
- step_for(x, y): inner clock.run body. Loops with
  clock.sync(get_rate(x,y)); on tick, if Toggled and not
  Paused, calls Sequencer.dispatch_fn (set by main script)
  and bumps Fire_Decay[x][y] for LED flash visual.
- start_all_clocks(): starts one loop per toggle cell
  (64 total = rows 2/4/6/8 × 16 cols). Called from
  schicksalslied.lua's init().
- stop_all_clocks(): cancels all clocks. Called from cleanup().
- toggle_pause(): K2 handler. Sets Pause_Pending then
  schedules a clock.sync(1) to flip Paused on the next beat.

get_rate(x,y) reference will be resolved in Task 2.4."
```

### Task 2.4 — seq_mode rate computation

Each toggle cell has a `seq_mode` param controlling how its clock rate is determined per tick: `sequins-derived` (a.k.a. lied), `fixed`, `user sequence`, or `random`. Sub-plan B does NOT add the per-cell params menu (deferred to Sub-plan C), but it DOES add stub `params:get` calls that read default values; the params framework will be exercised in Sub-plan C.

For Sub-plan B, we provide reasonable defaults inline and TEMPORARY hardcoded defaults from spec §7's "Default seq_mode values are seeded per cell to match naherinlied's column-specific rates" (row 2 col 1 = fixed 8, col 9 = user sequence 1, col 13 = fixed 3, etc.; rows 4/6 = all fixed 2; row 8 = random(1, 16)).

**Files:**
- Modify: `schicksalslied/lib/sequencer.lua`

- [ ] **Step 1: Add seq_mode constants + per-cell defaults table**

In `lib/sequencer.lua`, after the pause section and before `return Sequencer`, add:

```lua
-- ========================================================================
-- SEQ MODE — clock rate per cell per tick
-- ========================================================================
-- Four modes per spec §7:
--   sequins  : rate = Seq[x][y]() / Seq[x][y]() * scale (consumes 2 bytes)
--   fixed    : rate = fixed_value (a constant)
--   user_seq : rate cycles through a user-configured pattern of N step durations
--   random   : rate = math.random(min, max) per tick
--
-- Sub-plan C will add the full per-cell params menu wiring. For Sub-plan B,
-- we use sensible defaults that match spec §7's naherinlied-derived defaults.

-- Default seq_mode per cell. Keyed by [x][y] for toggle rows.
-- Format: { mode = 'sequins'|'fixed'|'user_seq'|'random', args... }
Sequencer.Seq_Mode = {}

-- Preset user-sequence patterns. Replicates spec §7's mention of naherinlied's
-- seqs[1..4]. cell_roles or schicksalslied.lua can swap these via params later.
Sequencer.User_Seq_Patterns = {
    Sequins({ 0.25, 0.25, 15.5 }),
    Sequins({ 0.5, 15, 0.5 }),
    Sequins({ 0.25, 15.25, 0.25, 0.25 }),
    Sequins({ 0.5, 0.5, 14.5, 0.5 }),
}

-- Default seq_mode per cell, matching naherinlied's column behavior.
local function default_seq_mode_for(x, y)
    if y == 2 then
        -- Row 2 (row-2 voice/crow cells): col-specific defaults per naherinlied
        if x == 1 or x == 2 then return { mode = 'fixed', fixed_value = 8 }
        elseif x >= 3 and x <= 8 then return { mode = 'sequins', scale = 8 }
        elseif x == 9 then return { mode = 'user_seq', pattern_index = 1 }
        elseif x == 10 then return { mode = 'user_seq', pattern_index = 2 }
        elseif x == 11 then return { mode = 'user_seq', pattern_index = 3 }
        elseif x == 12 then return { mode = 'user_seq', pattern_index = 4 }
        elseif x == 13 then return { mode = 'fixed', fixed_value = 3 }
        elseif x == 14 then return { mode = 'fixed', fixed_value = 1.5 }
        elseif x == 15 then return { mode = 'fixed', fixed_value = 1 }
        elseif x == 16 then return { mode = 'fixed', fixed_value = 0.5 }
        end
    elseif y == 4 or y == 6 then
        -- Sampler rows: fixed 2 across all cols
        return { mode = 'fixed', fixed_value = 2 }
    elseif y == 8 then
        -- One-shot row: random(1, 16)
        return { mode = 'random', random_min = 1, random_max = 16 }
    end
    return { mode = 'fixed', fixed_value = 1 }
end

-- Populate defaults — call from Sequencer.init()
local function init_seq_modes()
    for x = 1, 16 do
        Sequencer.Seq_Mode[x] = {}
        for y = 2, 8, 2 do
            Sequencer.Seq_Mode[x][y] = default_seq_mode_for(x, y)
        end
    end
end

-- Compute the rate for cell [x][y]'s next tick based on its current seq_mode.
function Sequencer.get_rate(x, y)
    local sm = Sequencer.Seq_Mode[x] and Sequencer.Seq_Mode[x][y]
    if sm == nil then return 1 end  -- safe default if cell has no mode

    if sm.mode == 'fixed' then
        return sm.fixed_value or 1
    elseif sm.mode == 'sequins' then
        local seq = Sequencer.Seq[x][y]
        local num = seq()
        local den = seq()
        local scale = sm.scale or 1
        if den == 0 then return scale end  -- guard against div-by-0
        return (num / den) * scale
    elseif sm.mode == 'user_seq' then
        local pattern_index = sm.pattern_index or 1
        local pattern = Sequencer.User_Seq_Patterns[pattern_index]
        if pattern then return pattern() end
        return 1
    elseif sm.mode == 'random' then
        local lo = sm.random_min or 1
        local hi = sm.random_max or 16
        return math.random(lo, hi)
    end
    return 1
end
```

- [ ] **Step 2: Call `init_seq_modes` from `Sequencer.init()`**

Find the existing `Sequencer.init()` function (added in Task 2.1) and add `init_seq_modes()` as its last call, just before the function's end:

```lua
function Sequencer.init()
    for x = 1, 16 do
        Sequencer.Seq[x] = {}
        Sequencer.Toggled[x] = {}
        Sequencer.Momentary[x] = {}
        Sequencer.Clock_Ids[x] = {}
        Sequencer.Fire_Decay[x] = {}
        for y = 1, 8 do
            Sequencer.Seq[x][y] = Sequins({ string.byte(" ") })
            Sequencer.Toggled[x][y] = false
            Sequencer.Momentary[x][y] = false
            Sequencer.Clock_Ids[x][y] = nil
            Sequencer.Fire_Decay[x][y] = 0
        end
    end
    init_seq_modes()
end
```

- [ ] **Step 3: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/sequencer.lua && echo "OK"
```

Now `Sequencer.get_rate` is defined and Task 2.3's `step_for` will resolve at runtime.

- [ ] **Step 4: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/sequencer.lua
git commit -m "schicksalslied 2.0: sequencer.lua seq_mode rate computation

Sub-plan B, Task 2.4. Adds:
- Seq_Mode[x][y] table: per-cell { mode, args }
- User_Seq_Patterns: 4 preset Sequins from spec §7
  (replicates naherinlied's seqs[1..4])
- default_seq_mode_for(x, y): column-specific defaults per
  spec §7 (row 2 col 1 = fixed 8, col 9 = user_seq 1, etc.;
  rows 4/6 = fixed 2; row 8 = random(1, 16))
- init_seq_modes(): called from Sequencer.init()
- get_rate(x, y): computes the next clock.sync delta from
  cell's seq_mode (sequins / fixed / user_seq / random)

Sub-plan C will replace these defaults with per-cell params
menu entries; for Sub-plan B the defaults are inline."
```

### Task 2.5 — value_mode value generation

For sampler trigger cells (rows 4/6 odd cols), sampler rate cells (rows 4/6 even cols), and one-shot cells (row 8 cols 1-13), each cell has one or more `value_mode` configs that determine what VALUE the cell emits when firing (position / duration / rate). The four modes match `seq_mode`'s structure: `lied`, `fixed`, `user_seq`, `random`.

For Sub-plan B, defaults are `lied` everywhere (the cell's sequins drives the value with role-specific mapping). Sub-plan C will add the full params menu surface.

**Files:**
- Modify: `schicksalslied/lib/sequencer.lua`

- [ ] **Step 1: Add value_mode runtime**

In `lib/sequencer.lua`, after the seq_mode section and before `return Sequencer`, add:

```lua
-- ========================================================================
-- VALUE MODE — value generation for sampler/one-shot cells
-- ========================================================================
-- Sampler trigger cells emit position + duration; sampler rate cells emit
-- rate; one-shot cells emit rate. Each value has its own value_mode config
-- with the same 4 options as seq_mode.
--
-- For Sub-plan B, all value_modes default to 'lied' (value derived from
-- cell's sequins with role-specific mapping). Sub-plan C adds per-cell
-- value_mode params.

-- Value_Mode[x][y][value_kind] = { mode, args... }
-- value_kind: 'position', 'duration', 'rate'
Sequencer.Value_Mode = {}

-- Default value_mode is always 'lied' for Sub-plan B; the mapping happens
-- in cell_roles.dispatch (Phase 3 / Task 3.2).
local function default_value_mode()
    return { mode = 'lied' }
end

local function init_value_modes()
    for x = 1, 16 do
        Sequencer.Value_Mode[x] = {}
        for y = 4, 8, 2 do  -- rows 4, 6, 8
            Sequencer.Value_Mode[x][y] = {
                position = default_value_mode(),
                duration = default_value_mode(),
                rate     = default_value_mode(),
            }
        end
    end
end

-- Compute a value for cell [x][y]'s value_kind ('position'|'duration'|'rate').
-- In 'lied' mode, returns nil — caller (cell_roles.dispatch) reads sequins
-- directly and applies role-specific mapping.
-- In 'fixed' mode, returns the configured fixed value.
-- In 'user_seq', returns next value from the cell's configured pattern.
-- In 'random', returns math.random(min, max).
function Sequencer.get_value(x, y, value_kind)
    local vm = Sequencer.Value_Mode[x]
        and Sequencer.Value_Mode[x][y]
        and Sequencer.Value_Mode[x][y][value_kind]
    if vm == nil then return nil end  -- 'lied' fallback signaled by nil

    if vm.mode == 'lied' then
        return nil
    elseif vm.mode == 'fixed' then
        return vm.fixed_value
    elseif vm.mode == 'user_seq' then
        local pattern = vm.pattern  -- a Sequins instance stored at cell
        if pattern then return pattern() end
        return nil
    elseif vm.mode == 'random' then
        local lo = vm.random_min or 0
        local hi = vm.random_max or 1
        return math.random() * (hi - lo) + lo
    end
    return nil
end
```

- [ ] **Step 2: Call `init_value_modes` from `Sequencer.init()`**

Find the existing `Sequencer.init()` function and add `init_value_modes()` as its last call, just after `init_seq_modes()`:

```lua
function Sequencer.init()
    -- ... existing body ...
    init_seq_modes()
    init_value_modes()
end
```

- [ ] **Step 3: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/sequencer.lua && echo "OK"
```

- [ ] **Step 4: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/sequencer.lua
git commit -m "schicksalslied 2.0: sequencer.lua value_mode runtime

Sub-plan B, Task 2.5. Adds:
- Value_Mode[x][y]: per-cell table with position/duration/rate
  sub-modes for sampler/one-shot cells (rows 4/6/8)
- default_value_mode(): 'lied' for Sub-plan B; Sub-plan C will
  wire per-cell params for fixed/user_seq/random
- get_value(x, y, value_kind): returns the value for one of
  'position'|'duration'|'rate' based on cell's value_mode.
  'lied' mode returns nil → caller (cell_roles dispatch)
  reads sequins directly and applies role-specific mapping.

init_value_modes() is called from Sequencer.init()."
```

---

## Phase 3 — cell_roles.lua

Owns the role enum, the role dispatch table for all 10 row-2 roles + sampler trigger/rate (rows 4/6) + one-shot (row 8 cols 1-13) + mic/granular controls (row 8 cols 14-16), and the lazy-allocation logic that creates SC voice instances on first trigger after role assignment.

### Task 3.1 — Module skeleton + role enum + cell ID helpers

**Files:**
- Create: `schicksalslied/lib/cell_roles.lua`

- [ ] **Step 1: Write the skeleton**

```lua
-- lib/cell_roles.lua — schicksalslied 2.0 role dispatch + lazy allocation
-- Owns: role enum, dispatch table, lazy alloc of SC voice instances per cell

local MusicUtil = require 'musicutil'
local Roles = {}

-- ========================================================================
-- ROLE ENUM (row 2 cells configurable; rows 4/6/8 are fixed)
-- ========================================================================
-- 10 options per spec §3. Order matters — params menu uses these as indices.
Roles.ENUM = {
    'TriSin',
    'Ringer',
    'crow 1+2',
    'crow 3+4',
    'JF',
    'JF run',
    'JF quantize',
    'w/syn',
    'w/del',
    'w/tape looper',
}

-- Default row-2 role per column (spec §3: 4 TriSin → 4 Ringer → 4 TriSin → 4 Ringer)
Roles.ROW_2_DEFAULTS = {
    'TriSin', 'TriSin', 'TriSin', 'TriSin',
    'Ringer', 'Ringer', 'Ringer', 'Ringer',
    'TriSin', 'TriSin', 'TriSin', 'TriSin',
    'Ringer', 'Ringer', 'Ringer', 'Ringer',
}

-- Per-cell role (row 2 only). For other rows, role is implicit.
-- Roles.cell_role[x] returns the current role string for row 2's col x.
Roles.cell_role = {}

function Roles.init()
    for x = 1, 16 do
        Roles.cell_role[x] = Roles.ROW_2_DEFAULTS[x]
    end
end

-- ========================================================================
-- CELL ID HELPERS
-- ========================================================================

-- Lua-internal cell key for Seq/Toggled/etc. tables.
function Roles.cell_id(x, y)
    return string.format("%d_%d", x, y)
end

-- Returns true if a cell is "currently sounding" — sequencer-enabled and
-- recently fired. Used by lazy-allocation idle-grace logic (Task 3.3).
-- For Sub-plan B we keep this simple: just checks Toggled.
function Roles.is_active(Sequencer, x, y)
    return Sequencer.Toggled[x][y] == true
end

return Roles
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/cell_roles.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/cell_roles.lua
git commit -m "schicksalslied 2.0: cell_roles.lua skeleton + role enum

Sub-plan B, Task 3.1. Creates lib/cell_roles.lua module with:
- Roles.ENUM: 10 role options per spec §3 (TriSin, Ringer,
  crow 1+2, crow 3+4, JF, JF run, JF quantize, w/syn, w/del,
  w/tape looper)
- Roles.ROW_2_DEFAULTS: per-column default (4 TriSin → 4
  Ringer → 4 TriSin → 4 Ringer per spec §3)
- Roles.cell_role[x]: current role for row 2 col x; mutable
  in Sub-plan C via params, default fixed in Sub-plan B
- cell_id(x, y) helper: '<x>_<y>' format string used as
  SC-side instance key

Roles.init() seeds cell_role from defaults. Called from
schicksalslied.lua's init()."
```

### Task 3.2 — Role dispatch table

Each role has a dispatch function that, given a cell, reads sequins values, applies role-specific mapping, and calls the appropriate `engine.<command>` or `crow.ii.*` method.

**Files:**
- Modify: `schicksalslied/lib/cell_roles.lua`

- [ ] **Step 1: Add the dispatch table and dispatch function**

In `lib/cell_roles.lua`, before `return Roles`, add:

```lua
-- ========================================================================
-- ROLE DISPATCH TABLE
-- ========================================================================
-- Each role dispatch reads bytes from the cell's sequins (via Sequencer),
-- applies role-specific mapping, and fires the appropriate engine or crow
-- method. Set Roles.Sequencer = <sequencer_module> at init time so the
-- dispatch functions can access the state.

Roles.Sequencer = nil  -- set by schicksalslied.lua's init()

-- Round-robin counters for voice keys per cell (TriSin/Ringer).
-- Index by cell_id string. Polyphony pool size is per cell (default 4).
Roles.rr_counter = {}
Roles.polyphony = {}  -- per cell, 1-8, default 4. Sub-plan C wires per-cell params.

local function next_voice_key(cell_id, default_poly)
    local poly = Roles.polyphony[cell_id] or default_poly or 4
    Roles.rr_counter[cell_id] = ((Roles.rr_counter[cell_id] or 0) % poly) + 1
    return Roles.rr_counter[cell_id]
end

-- Per-cell w/tape looper "is this cell's looper currently running?" flag.
-- Prevents stacking concurrent loopers from rapid retriggers of the same cell.
Roles.looper_running = {}

-- The 10 row-2 role dispatchers
Roles.dispatch_row_2 = {

    ['TriSin'] = function(x, y, seq)
        local cell_id = Roles.cell_id(x, y)
        local note = seq() % 32 + 49
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.trisin_trigger(cell_id, voice_key, freq)
    end,

    ['Ringer'] = function(x, y, seq)
        local cell_id = Roles.cell_id(x, y)
        local note = seq() % 32 + 49
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.ringer_trigger(cell_id, voice_key, freq)
    end,

    ['crow 1+2'] = function(x, y, seq)
        -- consumes 4 bytes: pitch (v/oct), slew, attack, release
        crow.output[1].volts = (seq() % 32 + 1) / 12
        crow.output[1].slew = (seq() % 32 + 1) / 300
        crow.output[2].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
        crow.output[2].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[2].dyn.release = (seq() % 32 + 1) / 40
        crow.output[2]()
    end,

    ['crow 3+4'] = function(x, y, seq)
        crow.output[3].volts = (seq() % 32 + 1) / 12
        crow.output[3].slew = (seq() % 32 + 1) / 300
        crow.output[4].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
        crow.output[4].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[4].dyn.release = (seq() % 32 + 1) / 40
        crow.output[4]()
    end,

    ['JF'] = function(x, y, seq)
        -- consumes 2 bytes: pitch (v/oct), level (1-6 via %5+1)
        local pitch = (seq() % 32 + 1) / 12
        local level = seq() % 5 + 1
        crow.ii.jf.play_note(pitch, level)  -- JF handles voice allocation
    end,

    ['JF run'] = function(x, y, seq)
        crow.ii.jf.run(seq() % 32 + 1)
    end,

    ['JF quantize'] = function(x, y, seq)
        crow.ii.jf.quantize(seq() % 32 + 1)
    end,

    ['w/syn'] = function(x, y, seq)
        local pitch = (seq() % 32 + 1) / 12
        local level = seq() % 5 + 1
        crow.ii.wsyn.play_note(pitch, level)
    end,

    ['w/del'] = function(x, y, seq)
        -- pluck event: time, freq, pluck level
        crow.ii.wdel.time(0)
        crow.ii.wdel.freq((seq() % 32 + 1) / 12)
        crow.ii.wdel.pluck(seq() % 5 + 1)
    end,

    ['w/tape looper'] = function(x, y, seq)
        local cell_id = Roles.cell_id(x, y)
        if Roles.looper_running[cell_id] then return end  -- prevent re-entry
        Roles.looper_running[cell_id] = true
        local Looper = require 'lib/wtape_looper'
        clock.run(function()
            Looper.run(seq)
            Roles.looper_running[cell_id] = false
        end)
    end,
}

-- Sampler trigger cells (rows 4/6 odd cols 1/3/5/7/9/11/13/15)
-- Maps: row 4 odd col K → sampler slot (K+1)/2;  row 6 odd col K → sampler slot 8 + (K+1)/2
local function sampler_slot_for(x, y)
    local base = (y == 4) and 0 or 8
    return base + (math.floor(x / 2) + 1)
end

local function dispatch_sampler_trigger(x, y, seq)
    local slot = sampler_slot_for(x, y)
    local cell_id = Roles.cell_id(x, y)
    local poly = Roles.polyphony[cell_id] or 1
    local voice_key = next_voice_key(cell_id, poly)
    -- Default 'lied' mode: read 2 bytes for position/duration
    local pos_value = Roles.Sequencer.get_value(x, y, 'position')
    local dur_value = Roles.Sequencer.get_value(x, y, 'duration')
    local start_pos, end_pos
    if pos_value == nil then
        start_pos = util.linlin(36, 62, 0, 0.9, seq())  -- lied mode: from sequins
    else
        start_pos = pos_value
    end
    if dur_value == nil then
        end_pos = start_pos + util.linlin(36, 62, 0.001, 0.1, seq())
    else
        end_pos = start_pos + dur_value
    end
    -- Rate: read from PAIRED rate-control cell's sequins or value_mode
    -- For trigger cell at (x, y), the rate cell is at (x + 1, y)
    local rate_value = Roles.Sequencer.get_value(x + 1, y, 'rate')
    local rate
    if rate_value == nil then
        rate = 1  -- naherinlied's `(S-35)/(S-35)` is always 1
    else
        rate = rate_value
    end
    engine.sampler_trigger(slot, voice_key, start_pos, end_pos, rate)
end

local function dispatch_sampler_rate(x, y, seq)
    -- Rate cells don't trigger directly; their sequins feeds the PAIRED
    -- trigger cell. But the rate cell also has a clock loop. On its tick,
    -- it could update the sampler's rate param directly.
    local slot = sampler_slot_for(x - 1, y)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        rate = 1  -- lied mode default for current implementation
    else
        rate = rate_value
    end
    engine.sampler_set_param(slot, 'rate', rate)
end

-- One-shot row 8 cols 1-13
local function dispatch_oneshot_trigger(x, y, seq)
    local slot = x  -- one-shot slot = col number for x = 1..13
    local cell_id = Roles.cell_id(x, y)
    local voice_key = next_voice_key(cell_id, 1)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        -- lied mode: rate from sequins. Use byte / 36 for typical range 1.0–2.0
        rate = seq() / 36
    else
        rate = rate_value
    end
    engine.oneshot_trigger(slot, voice_key, rate)
end

-- ========================================================================
-- TOP-LEVEL DISPATCH
-- ========================================================================
-- Called by sequencer's clock loops via Sequencer.dispatch_fn.

function Roles.dispatch(x, y)
    local seq = Roles.Sequencer.Seq[x][y]
    -- Wrap seq into a function that just returns the next byte
    local seq_fn = function() return seq() end

    if y == 2 then
        local role = Roles.cell_role[x]
        local fn = Roles.dispatch_row_2[role]
        if fn then fn(x, y, seq_fn) end
    elseif y == 4 or y == 6 then
        if x % 2 == 1 then
            dispatch_sampler_trigger(x, y, seq_fn)
        else
            dispatch_sampler_rate(x, y, seq_fn)
        end
    elseif y == 8 then
        if x <= 13 then
            dispatch_oneshot_trigger(x, y, seq_fn)
        end
        -- cols 14-16 are mic/granular on/off toggles; no per-tick action.
        -- The toggle press handler in schicksalslied.lua manages their amps.
    end
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/cell_roles.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/cell_roles.lua
git commit -m "schicksalslied 2.0: cell_roles.lua dispatch table

Sub-plan B, Task 3.2. Adds:
- Roles.dispatch_row_2: 10 role dispatchers (TriSin, Ringer,
  crow 1+2 / 3+4, JF / JF run / JF quantize, w/syn, w/del,
  w/tape looper)
- next_voice_key(cell_id, poly): per-cell round-robin counter
  for TriSin/Ringer voice key 1..N
- sampler_slot_for(x, y): row 4 odd col K → slot (K+1)/2;
  row 6 odd col K → slot 8 + (K+1)/2
- dispatch_sampler_trigger / _rate: rows 4/6 odd cols trigger,
  even cols set rate of the paired trigger
- dispatch_oneshot_trigger: row 8 cols 1-13; slot = x

Top-level Roles.dispatch(x, y) called from sequencer's clock
loops via Sequencer.dispatch_fn."
```

### Task 3.3 — Lazy allocation helpers + role-change handler

When a row-2 cell is toggled on and triggered for the first time, we need to allocate a TriSin or Ringer instance on the SC side. When a cell's role changes (Sub-plan C will wire this via params), the old instance should be freed.

For Sub-plan B, the role is fixed at the default — but the lazy-allocation discipline must be in place so that on the FIRST trigger after script load, the SC instance is allocated. The simplest approach: maintain a Lua-side `allocated` set and call `engine.trisin_alloc(cell_id)` (or `ringer_alloc`) before the first trigger.

**Files:**
- Modify: `schicksalslied/lib/cell_roles.lua`

- [ ] **Step 1: Add allocation tracking and ensure_allocated helpers**

In `lib/cell_roles.lua`, after `Roles.cell_id` and `Roles.is_active` (early in the file), add:

```lua
-- ========================================================================
-- LAZY ALLOCATION (Approach C from spec §4)
-- ========================================================================
-- Track which cells have an active SC instance allocated. On first trigger
-- after role-set, allocate. On role change (Sub-plan C will wire), free old.

Roles.allocated = {}  -- key: cell_id, value: current role string

-- Ensure cell's SC instance is allocated for its current role. Idempotent.
function Roles.ensure_allocated(x, y)
    if y ~= 2 then return end  -- only row 2 cells use lazy allocation
    local cell_id = Roles.cell_id(x, y)
    local role = Roles.cell_role[x]
    if Roles.allocated[cell_id] == role then return end
    -- If previously allocated as a different role, free it first
    if Roles.allocated[cell_id] then
        local prev = Roles.allocated[cell_id]
        if prev == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif prev == 'Ringer' then
            engine.ringer_free(cell_id)
        end
        Roles.allocated[cell_id] = nil
    end
    -- Allocate fresh for the current role (only audio voices need allocation)
    if role == 'TriSin' then
        engine.trisin_alloc(cell_id)
        Roles.allocated[cell_id] = role
    elseif role == 'Ringer' then
        engine.ringer_alloc(cell_id)
        Roles.allocated[cell_id] = role
    end
    -- Crow roles and looper don't need SC instances — they speak crow/ii directly
end

-- Called by schicksalslied.lua's cleanup() — free all allocated SC instances.
function Roles.free_all()
    for cell_id, role in pairs(Roles.allocated) do
        if role == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif role == 'Ringer' then
            engine.ringer_free(cell_id)
        end
    end
    Roles.allocated = {}
end
```

- [ ] **Step 2: Call `ensure_allocated` from row-2 dispatchers**

In `lib/cell_roles.lua`, find `Roles.dispatch_row_2['TriSin']` and `Roles.dispatch_row_2['Ringer']`. At the START of each, before the existing body, add an `ensure_allocated` call:

```lua
    ['TriSin'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)  -- ADD THIS LINE
        local cell_id = Roles.cell_id(x, y)
        -- ... rest unchanged
    end,

    ['Ringer'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)  -- ADD THIS LINE
        local cell_id = Roles.cell_id(x, y)
        -- ... rest unchanged
    end,
```

- [ ] **Step 3: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/cell_roles.lua && echo "OK"
```

- [ ] **Step 4: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/cell_roles.lua
git commit -m "schicksalslied 2.0: cell_roles.lua lazy allocation

Sub-plan B, Task 3.3. Adds:
- Roles.allocated[cell_id]: tracks current role string for cells
  that have an SC instance
- ensure_allocated(x, y): called from row-2 TriSin/Ringer
  dispatchers before each trigger. Idempotent. If a cell's
  role changed since last alloc, frees old instance first.
- Roles.free_all(): called from schicksalslied.cleanup() to
  release every allocated SC instance

Crow roles (crow 1+2 / 3+4 / JF / w/syn / w/del / w/tape
looper) do NOT need SC instances — they speak crow/ii directly."
```

---

## Phase 4 — wtape_looper.lua

Port the 1.x `schicksalslied.lua:341-404` `looper()` function. Replace every `C:step(N)()` / `J:step(N)()` with `seq()` calls (the cell's sequins).

### Task 4.1 — Port the looper

**Files:**
- Create: `schicksalslied/lib/wtape_looper.lua`

- [ ] **Step 1: Write the looper module**

The 1.x looper is 60+ lines of nested clock.sync calls that drive `crow.ii.wtape.loop_start`, `loop_end`, `loop_scale`, `loop_next`, `seek`, `loop_active`. The 2.0 port consumes bytes from a single cell's sequins via `seq()` instead of `C:step(N)` / `J:step(N)`.

The flow (per 1.x):
1. `loop_start` at one position, then `clock.sync`
2. `loop_end` at another position
3. Conditional branch: `if C[117] < 17 then` two-level loop, `else` two-level loop (different ordering of scale/next)
4. Both branches: `loop_scale` adjust, `loop_next` advance
5. After the conditional: `loop_active(0)`, several `seek` calls
6. Another conditional with `J[145]`: turn loop active back on, more scale/next manipulation

Write `lib/wtape_looper.lua`:

```lua
-- lib/wtape_looper.lua — schicksalslied 2.0 w/tape looper choreography
-- Ported from 1.x schicksalslied.lua:341-404 (the looper() function)
-- Rewired to consume bytes from a single cell's sequins via seq() instead
-- of the global C/J sequins-step calls from 1.x.
--
-- Called from cell_roles.lua's 'w/tape looper' dispatch.
-- Spec §8: preserved bit-for-bit; only the sequins source changed.

local Looper = {}

-- Run one full looper pass for a cell. Reads bytes from seq() (the cell's sequins).
-- All clock.sync calls remain — this runs inside a clock.run coroutine
-- spawned by cell_roles.dispatch_row_2['w/tape looper'].
function Looper.run(seq)
    crow.ii.wtape.loop_start(1)
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_end(1)
    if seq() < 17 then
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.loop_scale(seq() / seq())
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_next(seq() - seq())
            end
        end
    else
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.loop_next(seq() - seq())
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_scale(seq() / seq())
            end
        end
    end
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_active(0)
    for _ = 1, seq() do
        clock.sync(seq() / seq())
        crow.ii.wtape.seek((seq() - seq()) * 300)
    end
    for _ = 1, seq() do
        clock.sync(seq() / seq())
        crow.ii.wtape.loop_active(1)
        if seq() < 17 then
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_scale(seq() / seq())
                for _ = 1, seq() do
                    clock.sync(seq() / seq())
                    crow.ii.wtape.loop_next(seq() - seq())
                end
            end
        else
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_next(seq() - seq())
                for _ = 1, seq() do
                    clock.sync(seq() / seq())
                    crow.ii.wtape.loop_scale(seq() / seq())
                end
            end
        end
        clock.sync(seq() / seq())
        crow.ii.wtape.loop_active(0)
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.seek((seq() - seq()) * 300)
        end
    end
end

return Looper
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p lib/wtape_looper.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add lib/wtape_looper.lua
git commit -m "schicksalslied 2.0: wtape_looper.lua port

Sub-plan B, Task 4.1. Ports 1.x schicksalslied.lua:341-404
looper() function to lib/wtape_looper.lua. Same nested
choreography of crow.ii.wtape.loop_start, loop_end, loop_scale,
loop_next, seek, loop_active — only the sequins source changed:
1.x consumed bytes from global C/J sequins via C:step(N)() and
J:step(N)(); 2.0 consumes from a single cell's sequins via
seq() arg passed by cell_roles.lua's 'w/tape looper' dispatcher.

Called as Looper.run(seq) inside a clock.run coroutine — runs
for one full pass then returns. The dispatcher's looper_running
flag prevents re-entry from rapid retriggers."
```

---

## Phase 5 — schicksalslied.lua wiring

The main 2.0 script. Replaces the 1.x file wholesale. Owns: state variables, keyboard handler, grid handler, screen redraw, K1/K2/K3 actions, `crow_reinit()`, params for file slots, `init()` and `cleanup()`.

### Task 5.1 — Skeleton + state + init/cleanup

**Files:**
- Modify: `schicksalslied/schicksalslied.lua` (wholesale rewrite)

- [ ] **Step 1: Write the new schicksalslied.lua skeleton**

Replace the entire contents of `schicksalslied/schicksalslied.lua` with:

```lua
---schicksalslied 2.0
---
---a poetry sequencer
---
---type to enter text, ENTER to stage,
---grid row 3/5/7 press to assign,
---grid row 2/4/6/8 toggle to fire.
---
---K1: panic (free all sounds)
---K2: pause/resume (clock-quantized)
---K3: tap tempo
---
---version 2.0.0

engine.name = 'Lied'

local Sequencer  = include 'lib/sequencer'
local Roles      = include 'lib/cell_roles'
local MusicUtil  = require 'musicutil'

-- ========================================================================
-- GLOBAL STATE — text input + history
-- ========================================================================
Displayed_String = ""    -- live typing buffer
My_String        = ""    -- staged line, set by ENTER and row-1 release
History          = {}    -- typed + file-loaded lines, indexed 1..N
History_Index    = 0
New_Line         = false
Needs_Restart    = false -- legacy from 1.x's FormantTriPTR install; always false in 2.0

-- ========================================================================
-- GRID + SCREEN
-- ========================================================================
G                = grid.connect()
Grid_Dirty       = true

-- K1/K2/K3 state for tap-tempo
Tap_Tempo_Times  = {}

-- ========================================================================
-- CROW INIT FUNCTION
-- ========================================================================
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
    print('crow re-initialized')
end

-- ========================================================================
-- HISTORY + TEXT FILE LOADING
-- ========================================================================
local function load_text_file(path)
    if path == nil or path == '' or path == '-' then return end
    io.input(path)
    for line in io.lines() do
        if #line > 0 then
            table.insert(History, line)
        end
    end
    Grid_Dirty = true
    redraw()
end

-- ========================================================================
-- PARAMS (minimal set — Sub-plan C wires the full menu)
-- ========================================================================
local function add_params()
    -- Crow setup
    params:add{
        type = 'trigger',
        id = 'reinit_crow',
        name = 're-init crow modules',
        action = crow_reinit,
    }
    params:add{
        type = 'control',
        id = 'wsyn_voices',
        name = 'w/syn voices',
        controlspec = controlspec.new(1, 4, 'lin', 1, 4, ''),
        action = function(v) crow.ii.wsyn.voices(v) end,
    }
    -- Sampler file params (16 slots) — Sub-plan A's Lied loads via engine.sampler_load
    for slot = 1, 16 do
        params:add{
            type = 'file',
            id = 'sampler_' .. slot .. '_file',
            name = 'sampler ' .. slot,
            action = function(path)
                if path == nil or path == '' or path == '-' then
                    engine.sampler_clear(slot)
                else
                    engine.sampler_load(slot, path)
                end
            end,
        }
    end
    -- One-shot file params (13 slots)
    for slot = 1, 13 do
        params:add{
            type = 'file',
            id = 'oneshot_' .. slot .. '_file',
            name = 'one-shot ' .. slot,
            action = function(path)
                if path == nil or path == '' or path == '-' then
                    engine.oneshot_clear(slot)
                else
                    engine.oneshot_load(slot, path)
                end
            end,
        }
    end
    -- Text file load
    params:add{
        type = 'file',
        id = 'text_file',
        name = 'text file',
        action = load_text_file,
    }
    -- Row 8 cols 14-16 "on amp" defaults
    params:add{
        type = 'control',
        id = 'mic_to_delay_amp',
        name = 'mic to delay amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
    }
    params:add{
        type = 'control',
        id = 'granular_out_amp',
        name = 'granular out amp',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0.3, ''),
    }
    params:add{
        type = 'control',
        id = 'mic_dry_amp',
        name = 'mic dry amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
    }
end

-- ========================================================================
-- INIT
-- ========================================================================
function init()
    Sequencer.init()
    Roles.init()
    Roles.Sequencer = Sequencer
    Sequencer.dispatch_fn = function(x, y) Roles.dispatch(x, y) end

    add_params()
    params:bang()

    Sequencer.start_all_clocks()

    -- Screen redraw timer at 15fps
    Screen_Metro = metro.init()
    Screen_Metro.time = 1/15
    Screen_Metro.event = function() redraw() end
    Screen_Metro:start()

    -- Grid redraw timer at 30fps
    Grid_Metro = metro.init()
    Grid_Metro.time = 1/30
    Grid_Metro.event = function()
        if Grid_Dirty then
            grid_redraw()
            Grid_Dirty = false
        end
    end
    Grid_Metro:start()

    -- Fire-decay tick for LED flash on currently-firing cells (15fps)
    Fire_Decay_Metro = metro.init()
    Fire_Decay_Metro.time = 1/15
    Fire_Decay_Metro.event = function()
        for x = 1, 16 do
            for y = 2, 8, 2 do
                if Sequencer.Fire_Decay[x][y] > 0 then
                    Sequencer.Fire_Decay[x][y] = Sequencer.Fire_Decay[x][y] - 1
                    Grid_Dirty = true
                end
            end
        end
    end
    Fire_Decay_Metro:start()

    crow_reinit()

    print('schicksalslied 2.0 ready')
end

-- ========================================================================
-- CLEANUP
-- ========================================================================
function cleanup()
    Sequencer.stop_all_clocks()
    Roles.free_all()
    if Screen_Metro then Screen_Metro:stop() end
    if Grid_Metro then Grid_Metro:stop() end
    if Fire_Decay_Metro then Fire_Decay_Metro:stop() end
    G:all(0)
    G:refresh()
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua && echo "OK"
```

The script references `redraw()`, `grid_redraw()`, and the keyboard/grid/K1/K2/K3 handlers that we'll add in subsequent tasks. `luac -p` checks syntax only, not symbol resolution — should pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add schicksalslied.lua
git commit -m "schicksalslied 2.0: main script skeleton + init/cleanup

Sub-plan B, Task 5.1. Replaces 1.x schicksalslied.lua with the 2.0
skeleton. Adds:
- engine.name = 'Lied'
- Global state: Displayed_String, My_String, History,
  History_Index, New_Line, Grid_Dirty, Tap_Tempo_Times
- crow_reinit() function for hot-plug recovery
- load_text_file(path) helper for the text_file param
- add_params(): minimal set (reinit_crow, wsyn_voices, 16
  sampler file params, 13 oneshot file params, text_file,
  mic/granular amp defaults). Sub-plan C adds full per-cell
  role/mode/voice params.
- init(): wires Sequencer + Roles, starts clock loops, screen
  metro at 15fps, grid metro at 30fps, fire-decay tick at 15fps,
  calls crow_reinit()
- cleanup(): stops clocks, frees SC instances, clears grid

Handlers (key, enc, keyboard.char/code, G.key, redraw,
grid_redraw) added in Tasks 5.2-5.5."
```

### Task 5.2 — Keyboard handling

Two-variable text input model per spec §11: `Displayed_String` (live typing) and `My_String` (staged for assignment).

**Files:**
- Modify: `schicksalslied/schicksalslied.lua`

- [ ] **Step 1: Add keyboard handlers**

In `schicksalslied.lua`, before the `init()` function, add:

```lua
-- ========================================================================
-- KEYBOARD HANDLER (spec §11 — two-variable text input model)
-- ========================================================================

keyboard.char = function(character)
    if #Displayed_String < 200 then
        Displayed_String = Displayed_String .. character
    end
end

keyboard.code = function(code, val)
    if val == 0 then return end
    if code == 'BACKSPACE' then
        Displayed_String = Displayed_String:sub(1, -2)
    elseif code == 'UP' then
        if #History == 0 then return end
        if New_Line then
            History_Index = #History - 1
            New_Line = false
        else
            History_Index = util.clamp(History_Index - 1, 0, #History)
        end
        Displayed_String = History[History_Index + 1] or ""
    elseif code == 'DOWN' then
        if #History == 0 or History_Index == nil then return end
        History_Index = util.clamp(History_Index + 1, 0, #History)
        if History_Index == #History then
            Displayed_String = ""
            New_Line = true
        else
            Displayed_String = History[History_Index + 1] or ""
        end
    elseif code == 'ENTER' and #Displayed_String > 0 then
        -- ENTER promotes Displayed_String to My_String, adds to History,
        -- clears Displayed_String (per spec §7 text input flow)
        My_String = Displayed_String
        table.insert(History, Displayed_String)
        Displayed_String = ""
        History_Index = #History
        New_Line = true
        Grid_Dirty = true
    elseif keyboard.ctrl() then
        -- Ctrl chord: remove last History entry, clear Displayed_String
        table.remove(History, #History)
        History_Index = #History
        Displayed_String = ""
        Grid_Dirty = true
    end
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add schicksalslied.lua
git commit -m "schicksalslied 2.0: keyboard handler

Sub-plan B, Task 5.2. Adds keyboard.char and keyboard.code
per spec §11 two-variable text input model:
- char keys → append to Displayed_String (cap 200 chars)
- BACKSPACE → strip last char of Displayed_String
- UP/DOWN → cycle History; selected line → Displayed_String
- ENTER → promote Displayed_String to My_String AND append
  to History AND clear Displayed_String (does NOT call any
  global set() like 1.x did — assignment is per-cell via grid)
- Ctrl chord → remove last History entry, clear Displayed_String"
```

### Task 5.3 — Grid handling

Three different press behaviors per row per spec §3:
- Row 1: history slots. Press concatenates the history line to `Displayed_String`. Release without other holds sets `My_String = Displayed_String`. Holding multiple combines.
- Row 2/4/6/8 (toggle rows): press toggles `Sequencer.Toggled[x][y]`. Row 8 cols 14-16 are different (on/off for mic/granular amps).
- Row 3/5/7 (odd rows): press assigns `My_String` to the cell ABOVE (y-1) via `Sequencer.assign(x, y-1, My_String)`.

**Files:**
- Modify: `schicksalslied/schicksalslied.lua`

- [ ] **Step 1: Add the grid.key handler**

In `schicksalslied.lua`, before `init()` (after the keyboard handler), add:

```lua
-- ========================================================================
-- GRID HANDLER (spec §3 + §11)
-- ========================================================================

G.key = function(x, y, z)
    Sequencer.Momentary[x][y] = (z == 1)
    Grid_Dirty = true

    if y == 1 then
        -- History row
        if x + 16 * (y - 1) > #History then return end
        if z == 1 then
            -- Press: append history[x + 16*(y-1)] to Displayed_String
            My_String = Displayed_String .. History[x + 16 * (y - 1)]
            Displayed_String = My_String
        else
            -- Release: check if any other row-1 buttons are still held
            local any_held = false
            for col = 1, 16 do
                if Sequencer.Momentary[col][1] then any_held = true; break end
            end
            if any_held then return end
            -- All released — set My_String from current Displayed_String
            if #Displayed_String > 0 then
                My_String = Displayed_String
            end
            Displayed_String = ""
            New_Line = true
        end

    elseif y == 2 or y == 4 or y == 6 or y == 8 then
        -- Toggle row
        if z == 1 then
            -- Row 8 cols 14-16: special on/off for mic/granular amps
            if y == 8 and x >= 14 and x <= 16 then
                Sequencer.Toggled[x][y] = not Sequencer.Toggled[x][y]
                local on_value
                local set_fn
                if x == 14 then
                    on_value = params:get('mic_to_delay_amp')
                    set_fn = function(v) engine.set_mic_amp(v) end
                elseif x == 15 then
                    on_value = params:get('granular_out_amp')
                    set_fn = function(v) engine.set_granular_out_amp(v) end
                else  -- x == 16
                    on_value = params:get('mic_dry_amp')
                    set_fn = function(v) engine.set_mic_dry_amp(v) end
                end
                set_fn(Sequencer.Toggled[x][y] and on_value or 0)
            else
                -- Regular sequencer toggle
                Sequencer.Toggled[x][y] = not Sequencer.Toggled[x][y]
                if y == 2 and Sequencer.Toggled[x][y] then
                    Roles.ensure_allocated(x, y)
                end
            end
        end

    elseif y == 3 or y == 5 or y == 7 then
        -- Assign row: press assigns My_String to the cell at (x, y-1)
        if z == 1 then
            if #My_String > 0 then
                Sequencer.assign(x, y - 1, My_String)
            end
        end
    end
end
```

- [ ] **Step 2: Add the grid_redraw function**

In `schicksalslied.lua`, after `G.key`, add:

```lua
-- ========================================================================
-- GRID LED RENDERING (spec §11 brightness table)
-- ========================================================================

function grid_redraw()
    G:all(0)
    -- Row 1: history slots. 0 if empty, 4 if filled, 15 if held
    for x = 1, 16 do
        local idx = x  -- slot index = col for row 1
        if idx <= #History then
            G:led(x, 1, 4)
        end
        if Sequencer.Momentary[x][1] then
            G:led(x, 1, 15)
        end
    end
    -- Rows 2/4/6/8 (toggle rows): 0 idle, 15 toggled-on, 15 held.
    -- When Paused, toggled-on dims to 6.
    for x = 1, 16 do
        for y = 2, 8, 2 do
            if Sequencer.Toggled[x][y] then
                local level = Sequencer.Paused and 6 or 15
                G:led(x, y, level)
            end
            if Sequencer.Momentary[x][y] then
                G:led(x, y, 15)
            end
        end
    end
    -- Rows 3/5/7 (momentary): 4 idle, 15 held
    for x = 1, 16 do
        for y = 3, 7, 2 do
            G:led(x, y, 4)
            if Sequencer.Momentary[x][y] then
                G:led(x, y, 15)
            end
        end
    end
    G:refresh()
end
```

- [ ] **Step 3: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua && echo "OK"
```

- [ ] **Step 4: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add schicksalslied.lua
git commit -m "schicksalslied 2.0: grid handler + LED rendering

Sub-plan B, Task 5.3. Adds G.key and grid_redraw per spec §3 + §11:
- Row 1 (history): press appends history line to Displayed_String;
  release-without-other-holds promotes to My_String
- Rows 2/4/6/8 (toggle): press toggles Sequencer.Toggled; row 2
  cells also call Roles.ensure_allocated when toggled-on
- Row 8 cols 14-16: special on/off for mic/granular amps
  (set via engine.set_mic_amp / set_granular_out_amp / set_mic_dry_amp
  with values from the configured 'on amp' params)
- Rows 3/5/7 (assign): press calls Sequencer.assign(x, y-1, My_String)

grid_redraw uses spec §11 brightness table:
- Row 1: 0/4/15 (empty/filled/held)
- Rows 2/4/6/8: 0/15 (off/on); when Paused, on dims to 6
- Rows 3/5/7: 4/15 (idle/held)"
```

### Task 5.4 — Screen redraw

Two-string layout per spec §11: typing buffer at bottom in a bordered box, staged line above it with `★` prefix, history items scrolling up.

**Files:**
- Modify: `schicksalslied/schicksalslied.lua`

- [ ] **Step 1: Add the redraw function**

In `schicksalslied.lua`, after `grid_redraw` (before `init()`), add:

```lua
-- ========================================================================
-- SCREEN REDRAW (spec §11 two-string layout)
-- ========================================================================

function redraw()
    screen.clear()
    screen.level(10)

    -- Input box at the bottom (y 50-64)
    screen.rect(2, 50, 125, 14)
    screen.stroke()
    screen.move(5, 59)
    screen.text("> " .. Displayed_String)

    -- Staged line indicator at y≈40 — only show if My_String is non-empty AND
    -- different from Displayed_String (avoid redundant display right after ENTER)
    if #My_String > 0 and My_String ~= Displayed_String then
        screen.move(5, 40)
        screen.text("* " .. My_String)
    end

    -- History items above (up to 4-5 lines, scrolling up)
    for i = 1, 5 do
        if not (History_Index - i >= 0) then break end
        screen.move(5, 32 - 10 * (i - 1))
        screen.text(History[History_Index - i + 1] or "")
    end

    screen.update()
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add schicksalslied.lua
git commit -m "schicksalslied 2.0: screen redraw

Sub-plan B, Task 5.4. Adds redraw() per spec §11 two-string layout:
- Input box at y 50-64 with '> Displayed_String'
- Staged line at y 40 with '* My_String' (only if non-empty and
  different from Displayed_String — avoids redundancy post-ENTER)
- Up to 5 history items above, scrolling up from History_Index"
```

### Task 5.5 — K1 / K2 / K3 hardware key actions

Per spec §11: K1 = panic, K2 = pause/resume (clock-quantized), K3 = tap tempo.

**Files:**
- Modify: `schicksalslied/schicksalslied.lua`

- [ ] **Step 1: Add the key handler**

In `schicksalslied.lua`, after `redraw()` and before `init()`, add:

```lua
-- ========================================================================
-- HARDWARE KEYS (K1 / K2 / K3 — spec §11)
-- ========================================================================

local function tap_tempo()
    local now = util.time()
    table.insert(Tap_Tempo_Times, now)
    if #Tap_Tempo_Times > 4 then
        table.remove(Tap_Tempo_Times, 1)
    end
    if #Tap_Tempo_Times >= 2 then
        local intervals = {}
        for i = 2, #Tap_Tempo_Times do
            table.insert(intervals, Tap_Tempo_Times[i] - Tap_Tempo_Times[i - 1])
        end
        local avg = 0
        for _, v in ipairs(intervals) do avg = avg + v end
        avg = avg / #intervals
        local bpm = 60 / avg
        bpm = util.clamp(bpm, 20, 400)
        params:set('clock_tempo', bpm)
        print(string.format('tap tempo: %.1f bpm', bpm))
    end
end

local function panic()
    Roles.free_all()
    crow.ii.jf.run(0)
    print('PANIC: freed all voices')
end

function key(n, z)
    if z == 0 then return end
    if n == 1 then
        panic()
    elseif n == 2 then
        Sequencer.toggle_pause()
        Grid_Dirty = true
    elseif n == 3 then
        tap_tempo()
    end
end

function enc(n, d)
    -- Reserved for future use; no encoder actions in Sub-plan B
end
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
git add schicksalslied.lua
git commit -m "schicksalslied 2.0: K1 / K2 / K3 hardware keys

Sub-plan B, Task 5.5. Adds key(n, z) and enc(n, d) per spec §11:
- K1 (panic): calls Roles.free_all() + crow.ii.jf.run(0)
- K2 (pause/resume): calls Sequencer.toggle_pause() — clock-quantized
  via Pause_Pending / Unpause_Pending flags, takes effect on next beat
- K3 (tap tempo): records timestamps; on 2nd+ press averages
  intervals from sliding window of last 4, computes BPM, sets via
  params:set('clock_tempo', bpm)
- enc: stub for future use

Sub-plan B complete after this task — ready for deploy to Norns
in Phase 6."
```

---

## Phase 6 — Deploy + verification

The final phase. Build a tarball, copy to Norns, unpack, load the script, run through the manual verification checklist.

### Task 6.1 — Deploy to Norns

**Files:**
- No code changes — purely deployment

- [ ] **Step 1: Verify everything compiles**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
luac -p schicksalslied.lua lib/sequencer.lua lib/cell_roles.lua lib/wtape_looper.lua && echo "All Lua OK"
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Expected: `All Lua OK` printed. `sclang test.scd` runs cleanly with all original Sub-plan A tests passing (exit 0, no `*** ERROR`).

- [ ] **Step 2: Build the deployment tarball**

```bash
cd /Users/spencergraham/Desktop/other/lied-update/
tar -czf schicksalslied-2.0.tar.gz \
    schicksalslied/schicksalslied.lua \
    schicksalslied/lib/Engine_Lied.sc \
    schicksalslied/lib/Lied.sc \
    schicksalslied/lib/TriSin.sc \
    schicksalslied/lib/Ringer.sc \
    schicksalslied/lib/Sampler.sc \
    schicksalslied/lib/OneShot.sc \
    schicksalslied/lib/cell_roles.lua \
    schicksalslied/lib/sequencer.lua \
    schicksalslied/lib/wtape_looper.lua \
    schicksalslied/README.md
ls -la schicksalslied-2.0.tar.gz
```

Note: we deliberately do NOT include `test.scd`, `audio/test_*.wav`, `mac_ext/`, or `docs/` — those are desktop dev artifacts, not Norns runtime needs.

- [ ] **Step 3: Copy to Norns and unpack** (manual user step)

This step requires the user to:
1. Connect Norns to the same Wi-Fi network as the Mac
2. Open Finder → `Cmd+K` → `smb://norns.local` (password: `sleep`)
3. Copy `schicksalslied-2.0.tar.gz` to the mounted Norns drive
4. SSH into Norns: `ssh we@norns.local` (password: `sleep`)
5. On Norns: `cd /home/we/dust/code/ && tar -xzf /home/we/schicksalslied-2.0.tar.gz`
6. On Norns: `rm /home/we/schicksalslied-2.0.tar.gz`

Alternative: drag-drop into Maiden's file browser at `http://norns.local` and use its terminal tab to run `tar -xzf` against `/home/we/dust/code/`.

The user does this manually. Report progress in the task tracking after each milestone.

- [ ] **Step 4: Commit the tarball trail (no code change, optional)**

If desired, document that deployment was completed by adding a marker file. Otherwise, just verify on Norns and move to Step 5.

### Task 6.2 — Hardware verification checklist

Once the script is deployed to Norns, work through this checklist. Each item is a manual hardware check. Pass → continue. Fail → identify the issue, return to the appropriate task to fix.

**Setup verification:**

- [ ] Load the script on Norns: SELECT → schicksalslied → K3. Screen should show: input box at bottom (empty, "> "), no staged line, no history.
- [ ] Maiden console shows: `schicksalslied 2.0 ready` and `crow re-initialized` (the latter only if crow is connected; if not, expect no error since the i2c calls silently fail when no device).
- [ ] No SC errors in `journalctl -u norns-sclang -f` (run in a separate SSH session if testing thoroughly).

**Text input verification:**

- [ ] Plug in a USB keyboard. Type "hello world" — should appear in input box after "> " prefix.
- [ ] Press BACKSPACE — last char of input is removed.
- [ ] Press ENTER — "hello world" disappears from input box; staged line "★ hello world" appears at y≈40; "hello world" appears as first history item above.
- [ ] Type "second line" → ENTER. Input clears; staged line updates to "★ second line"; "hello world" and "second line" both in history above.
- [ ] Press UP — input box shows "second line"; press UP again — input shows "hello world".
- [ ] Press DOWN — input cycles back through history.

**Grid verification (plug in a monome grid):**

- [ ] After typing 2 lines, row 1 cols 1-2 LEDs should be at level 4 (filled history slots).
- [ ] Press row 1 col 1 — LED goes to 15 while held; Displayed_String appends "hello world".
- [ ] Release row 1 col 1 — LED back to 4; My_String becomes "hello world"; staged line on screen.
- [ ] Press row 2 col 1 — LED toggles between off (0) and on (15); audio voice toggles.
- [ ] With a row-2 cell toggled on, press the corresponding row-3 cell. Row 3 cell LED briefly flashes 15 (held), then back to 4. The row-2 cell's sequins is now assigned to My_String.
- [ ] If row-2 col 1 is set to TriSin (default) and toggled on, you should hear an FM tone playing at the configured tempo (default seq_mode for col 1 is fixed 8 beats).

**Audio verification (row 2 voices):**

- [ ] Type a line, press ENTER, press row-3 col-1 to assign to TriSin cell at (1,2). Toggle row-2 col 1 on. Should hear TriSin notes firing every 8 beats. The pitch depends on the assigned text's ASCII values.
- [ ] Toggle row-2 col 5 on (Ringer). Should hear pinged resonant tones at the row-5 sequins's rate.
- [ ] Press K1 (panic). All audio stops immediately.

**Crow verification** (if you have a crow + at least one device):

- [ ] Set row 2 col 1 to "JF" via params (Sub-plan C wires this — for Sub-plan B you'll need to manually edit `cell_role[1]` in cell_roles.lua or just leave the default TriSin and add a separate test).
- [ ] Trigger and hear JF respond.
- [ ] Re-init crow: press the "re-init crow modules" trigger in params. crow should re-establish state.

**Sampler / one-shot verification (after Sub-plan C wires the full params):**

For Sub-plan B, the sampler/one-shot files are loadable via params, but the row-2 roles don't trigger samplers — only rows 4/6/8 cells do. With no files loaded, rows 4/6/8 cell triggers are silent no-ops (the engine commands gracefully handle nil instances). You can test that loading a file via params doesn't crash:

- [ ] Load any .wav file into sampler 1's file param. Check Maiden console for `Sampler 1 loaded: <path>`.
- [ ] Toggle row-4 col 1 (the row-4 sampler-trigger cell for slot 1). Should fire the sampler at the sequins-determined position. (Audio depends on whether the test sample is audible.)

**Pause / resume verification:**

- [ ] With some row-2 cells toggled on (audio playing), press K2. Audio stops on the next beat (clock-quantized). Toggled-on LEDs dim from 15 to 6.
- [ ] Press K2 again. Audio resumes on the next beat. LEDs return to 15.

**Tap tempo verification:**

- [ ] Press K3 four times at a steady ~120 BPM rate. Maiden console shows `tap tempo: ~120.0 bpm`. The script's clock tempo updates.

**Test all 10 row-2 roles (requires manual cell_role modification or wait for Sub-plan C):**

- [ ] TriSin ✓ (above)
- [ ] Ringer ✓ (above)
- [ ] crow 1+2 (manual change cell_role[1] to 'crow 1+2', restart, verify crow output 1 voltage changes)
- [ ] crow 3+4 (same idea)
- [ ] JF (above)
- [ ] JF run (manual)
- [ ] JF quantize (manual)
- [ ] w/syn (manual)
- [ ] w/del (manual)
- [ ] w/tape looper (manual — verify the looper choreography starts when toggled)

**Final sanity:**

- [ ] No crashes during 5+ minutes of normal interaction
- [ ] No SC crackle (Maiden CPU meter < ~50% with 4-6 voices active)
- [ ] Pause/resume preserves sequins position (resume continues from where it left off)
- [ ] cleanup() runs without errors when script is unloaded (SELECT → choose another script)

If any checklist item fails:
- For UI/state bugs: return to Task 5.2-5.5 and fix the relevant handler
- For sequencer/dispatch bugs: return to Phase 2 or 3
- For SC engine bugs: return to Phase 1 (likely a lifecycle command issue)

---

## Self-review

**1. Spec coverage check:**

| Spec section | Sub-plan B task(s) |
|---|---|
| §3 grid layout (row roles + brightness) | Task 5.3 (grid handler + grid_redraw) |
| §4 lazy allocation (Approach C) | Tasks 1.2-1.4 (SC kernel methods + commands), 3.3 (Lua-side ensure_allocated) |
| §7 sequencing (per-cell sequins, seq_mode, value_mode, text input flow) | Phase 2 entirely (sequencer.lua) + Task 5.2 (keyboard handler) |
| §8 crow integration (10 row-2 roles, crow_reinit, w/tape looper) | Phase 3 (cell_roles.lua), Phase 4 (wtape_looper.lua), Task 5.1 (crow_reinit) |
| §11 UI (screen, keyboard, K1/K2/K3, grid LEDs) | Tasks 5.2-5.5 |
| §12 behavioral changes vs 1.x | Implicit across all tasks (e.g., no `set()` global function, two-variable text input) |
| §13 migration (file removal) | Task 1.1 (remove legacy files) |
| §14 testing items | Task 6.2 (manual checklist replaces the spec's automated tests for Sub-plan B's scope) |

What's NOT in Sub-plan B but in the spec:
- §9 params menu (Sub-plan C)
- §10 LFOs (Sub-plan C)
- §14 tests #1, #2, #3, #4 (automated SC tests — covered in Sub-plan A's `test.scd`)
- §14 test #6 looper isolation (verified manually in Task 6.2; automated requires Norns hardware)
- §14 test #9 clock-quantized pause (verified manually in Task 6.2)

**2. Placeholder scan:** ✓ No "TBD", "TODO", "implement later". Every step has executable code or commands. Task 6.1's deploy step references manual user actions clearly.

**3. Type consistency:**
- `cell_id` format is `"<x>_<y>"` strings everywhere ✓
- `voice_key` is an integer (1-8) passed to engine commands, converted to Symbol `\1..\8` on SC side ✓
- `slot` is an integer (1-16 for samplers, 1-13 for one-shots) ✓
- `Sequencer.dispatch_fn` is set in init() to `Roles.dispatch` — no ordering issue ✓
- `Roles.Sequencer` is set in init() before `Sequencer.start_all_clocks()` so dispatch can read state ✓

**4. Scope check:** Sub-plan B's deliverable is a fully bootable Norns script that implements the per-cell sequencer, role dispatch, keyboard/grid/screen UI, hardware keys, w/tape looper, and the SC engine commands needed to drive Sub-plan A's classes. PSET params and LFO machinery are deliberately deferred to Sub-plan C; Sub-plan B's verification covers what's in scope.

---

## Execution handoff

**Plan complete and saved to `schicksalslied/docs/superpowers/plans/2026-05-14-schicksalslied-2-0-sub-plan-B-lua-control.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Same approach as Sub-plan A. Manual deploy + verification at the end (Phase 6 requires hardware).

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints. Best when you want to interject between tasks.

**Which approach?** After Sub-plan B's Norns checkpoint passes, I write Sub-plan C (params menu + LFOs + soak test).
