# Chapter 11 — Deployment and Debugging

## What you'll learn

The operational side of running schicksalslied 2.0: how to deploy your built source from a dev workstation to Norns, when to reboot vs reload, where to look when something goes wrong, and the specific failure modes you'll likely encounter (since they came up during this script's own development). By the end of this chapter, you'll have a checklist of diagnostics to reach for when the script misbehaves, and you'll know which `system → restart` vs hard-power-cycle to use in which situation.

## Prerequisites within the tutorial

- Chapters 01-10 (you have a fully-built script).

## Deploy mechanics

The Norns runtime looks for scripts under `/home/we/dust/code/<scriptname>/`. To deploy your local source, you tar it, upload it, and extract it.

### From scratch

```bash
# On your dev workstation, from the directory containing schicksalslied/:
tar -czf schicksalslied.tar.gz schicksalslied/

# Upload to Norns via SSH/SCP:
scp schicksalslied.tar.gz we@norns.local:~/

# SSH in and extract:
ssh we@norns.local
tar -xzf ~/schicksalslied.tar.gz -C /home/we/dust/code/
```

The `-C /home/we/dust/code/` extracts INTO that directory, creating `schicksalslied/` underneath. **Don't pre-create the target directory** — tar will create it. (A previous version of this tutorial's deploy instructions had users `mkdir -p schicksalslied` then extract, which produced `schicksalslied/schicksalslied/` and a broken script load. The tar command creates the directory itself.)

### Exclude unnecessary files

For a smaller tarball and faster deploy, exclude files that don't need to be on Norns:

```bash
tar -czf schicksalslied.tar.gz \
    --exclude='schicksalslied/mac_ext' \
    --exclude='schicksalslied/test.scd' \
    --exclude='schicksalslied/.git' \
    --exclude='schicksalslied/docs' \
    --exclude='schicksalslied/audio' \
    --exclude='schicksalslied/.gitignore' \
    --exclude='schicksalslied/.DS_Store' \
    --exclude='schicksalslied/data' \
    schicksalslied
```

The resulting tarball is around 60 KB — small enough that the SCP step is essentially instant over WiFi.

### After deployment

On Norns, hit SELECT to navigate the script picker, then select `schicksalslied`. The script loads. If everything works, you'll see "schicksalslied 2.0 ready" in the matron log (visible via Maiden's REPL pane).

`★ Insight ─────────────────────────────────────`
**The `audio/` and `data/` excludes** matter because users may have large audio files in their local `audio/` directory (for sample loading) and PSET files in `data/`. If you accidentally include them, the tarball balloons to many MB and may take seconds to transfer; worse, extracting may overwrite the user's PSETs with your dev defaults. Always exclude these.

**The `mac_ext/` directory holds symlinks** used during dev for editing SC files in SuperCollider IDE. They're macOS-specific paths and would be broken on Norns. Always exclude.
`─────────────────────────────────────────────────`

## Reboot vs reload

This is the most important operational distinction. **Different changes require different recovery actions.**

### Changes to `.lua` files only

A script reload is enough. On Norns: hit SELECT, choose `schicksalslied` again. The Lua side re-runs from `init()`. SC engine is reused as-is.

This is the fast path — about 2 seconds. Use it whenever you've only edited Lua.

### Changes to `.sc` files

You **must reboot Norns**. SC class library is compiled at boot; changes to `.sc` files don't take effect until the next compile. A script reload does NOT recompile SC.

Two reboot methods:

1. **`system → restart` on Norns UI** — this is a soft restart. It re-runs matron init, which re-compiles the SC class library. This is fine for most `.sc` changes.

2. **Hard power cycle** — for the rare case when `system → restart` doesn't clear matron-level state. Specifically, when matron's clock scheduler gets wedged (see "wedged matron" below), only a full power-off clears it.

#### Hard power cycle method depends on hardware

- **Wall-powered Norns** (no battery): unplug, wait 5 seconds, plug back in.
- **Battery-equipped Norns** (Norns shield with battery, retrofits): unplugging does not power off — the battery keeps it running. Use **SLEEP** from the on-device menu, then **hold K1** to power back on.

`★ Insight ─────────────────────────────────────`
**The battery distinction matters and is easy to forget.** If you tell a battery-Norns user to "unplug and replug," nothing happens — the battery sustains the device, your patch isn't applied, and the user is convinced the script is broken when in fact the reboot just didn't happen. Always ask about the user's hardware before suggesting an unplug-based reboot.

**`system → restart` vs hard power cycle**: when in doubt, do the harder one. The cost is 30 seconds; the benefit is certainty.
`─────────────────────────────────────────────────`

## Reading logs

Two logs matter:

### Matron log

The Lua side's log. Contains print statements from your script, Norns system messages, and Lua errors.

- **In Maiden** (the in-browser editor at `http://norns.local/`): the REPL pane shows matron output in real time. You can also type Lua expressions to inspect script state.
- **Direct file** (over SSH): `tail -f /home/we/dust/log/matron.log` (location depends on your Norns image; on newer images it may be `journalctl -u matron`).

### sclang / SuperCollider log

The SC side's log. Contains your SynthDef compilation messages, server errors, and any `.postln` output from your SC classes.

- **In Maiden**: there's a separate pane for the sclang REPL. Engine alloc messages, `Buffer.read` confirmations, and any `SUPERCOLLIDER FAIL` errors appear here.

Watch both panes during script load. If you see `### SCRIPT ERROR: ...` in matron, the Lua side failed. If you see `JackDriver: ...` or `SUPERCOLLIDER FAIL` in sclang, the SC side failed.

## Common failure modes

These are the patterns this script's own development hit. Each comes with diagnostic steps and the actual fix.

### "SUPERCOLLIDER FAIL" at script load

What you see: matron prints "loading engine: Lied" and then "### SCRIPT ERROR: SUPERCOLLIDER FAIL". sclang shows nothing useful — just no output.

**Most common cause**: a Lua-side cross-include identity bug. A param action calls `engine.<something>` before the engine's address has propagated, OR the script's `_G.GlobalSequencer` setup is broken so a param action reads a nil table.

**Diagnostic**: in the matron REPL after the error, try `print(_G.GlobalSequencer.history)`. If nil, the global wasn't set. Trace the init flow (chapter 19): is `_G.GlobalSequencer = Sequencer` happening before `add_params`?

**Fix**: ensure the init order in `schicksalslied.lua` is exactly as documented. The order matters; refactoring can subtly break it.

### "JackDriver: exception in real time: alloc failed"

What you see: sclang prints this error, possibly accompanied by a loud drone (SC server outputting noise from uninitialized memory). Matron shows the script running normally otherwise.

**Cause**: SC's real-time memory pool ran out. Usually because a `CombL`, `DelayN`, or similar delay-line UGen was instantiated with too large a `maxdelaytime`.

**Diagnostic**: in sclang REPL, check `s.options.memSize.postln;` (default 16384 = 16 MB). If it's the default, then check what's allocating: search the script source for delay-line UGens with large maxdelaytime args.

**Fix**: reduce maxdelaytime. The script's `CombL.ar(sig, 8.0, ...)` is sized to fit (~3 MB stereo at 48 kHz). At 16 sec (~6 MB), it fails. The 8-sec value is the documented maximum for this script.

To stop a loud drone: hit `Cmd-.` in Maiden's sclang pane, or SLEEP the Norns and power back on.

### "Synths only fire once, then silence" — wedged matron

What you see: cell toggles light up, you hear one fire, then no more fires. `clock.get_beats()` still advances normally if you call it from the REPL.

**Cause**: matron's clock scheduler is wedged. New clock callbacks aren't being scheduled, even though the beats counter is updated. This is the most subtle failure mode; the script appears to be running but no per-cell coroutines tick.

**Diagnostic** — the **TICK probe**:

```lua
clock.run(function()
    for i = 1, 5 do
        clock.sync(1)
        print('TICK', i, clock.get_beats())
    end
end)
```

Run this in Maiden's matron REPL. If you see 5 TICK lines printed at ~0.5 sec intervals, matron is healthy. If you see 0 or 1 lines after waiting 5+ seconds, matron is wedged.

**Fix**: a full hard power cycle. `system → restart` is NOT enough — the wedge survives soft restart. For battery-equipped Norns: SLEEP, then hold K1 to power back on. For wall-powered: unplug + replug.

**Prevention**: this script's `params:bang()` at init fires many actions; if any action does work that's expensive enough to starve matron's event loop, the scheduler can wedge. Keep param actions lightweight (one OSC call max).

### Cell strings don't restore from PSET

What you see: PSET loads, params restore, but cell text assignments are wrong — cells show `(none)` instead of the lines they had when saved.

**Cause**: the PSET sidecar file is missing. The `.pset` file holds param values; the `.lieddata` sidecar holds history and per-cell strings. Without the sidecar, history is empty after load, so cell string params point to history slots that no longer exist.

**Diagnostic**: on Norns, check `ls /home/we/dust/data/schicksalslied/`. You should see `schicksalslied-01.pset` and `schicksalslied-01.pset.lieddata`. If only the .pset exists, the sidecar wasn't saved (or was deleted).

**Fix**: re-save the PSET. The save action writes both files. If a sidecar was lost, there's no way to recover the original assignments — they're not in the .pset.

**Prevention**: when backing up PSETs, copy both files together.

### "Buffer UGen: no buffer data" on sampler/one-shot fire

What you see: sclang prints this, the sampler is silent on trigger.

**Cause**: the slot's buffer wasn't loaded successfully. Common reasons: file doesn't exist at the path stored in the PSET; file is in an unsupported format; file exceeds the 10-minute cap.

**Diagnostic**: check the matron log for the sampler_load message. It should print `Sampler N loaded new buffer: /path/to/file.wav (duration s)`. If you see `Sampler N load failed: cannot open ...`, the file path is bad. If you see `Sampler N load REFUSED: 612.3s exceeds 600s max`, the file is too long.

**Fix**: ensure the file exists. If it does and is short enough, check the format — Buffer.read supports WAV/AIFF/FLAC; some uncommon formats fail.

### Cross-include identity bug ("X is nil" in a param action)

What you see: a param action throws "attempt to index a nil value" on `Sequencer.history` or `Roles.cell_role` or similar.

**Cause**: the action is reading the file-local `Sequencer` (or `Roles`) reference instead of `_G.GlobalSequencer` (or `_G.GlobalRoles`). The file-local was a fresh `include` table and doesn't have the runtime state.

**Diagnostic**: the action's code. Find the line that reads `Sequencer.X` or `Roles.X`. Replace with `_G.GlobalSequencer.X` or `_G.GlobalRoles.X`.

**Fix**: route through the `_G` global. This is the documented workaround (chapter 09). When adding new code that needs cross-module state, ALWAYS use the `_G` global, not the file-local include.

`★ Insight ─────────────────────────────────────`
**Most "weird state" bugs in this script have been one of these six.** Memorizing them — what they look like, how to diagnose, how to fix — will save you a lot of debugging time. They're listed in roughly the order of how often they came up during development.

**The TICK probe is the single most useful diagnostic** in your toolkit. It distinguishes "matron is hung" from "my code is broken" in 5 seconds. Before deep-diving any timing-related complaint, run the probe.
`─────────────────────────────────────────────────`

## What to check first

When something misbehaves, ask these questions in order:

1. **Is matron's scheduler alive?** Run the TICK probe. If not: hard power cycle.
2. **Did the SC engine load successfully?** Look for "Engine_Lied alloc complete." in sclang. If not: check for SUPERCOLLIDER FAIL.
3. **Are the param values what you expect?** In matron REPL: `print(params:get('cell_1_2_seq_mode'))`. Match against what you expect.
4. **Are the per-cell coroutines alive?** `print(_G.GlobalSequencer.Clock_Ids[1][2])` should return a small integer. If nil, the cell's loop wasn't started.
5. **Is the cell role what you expect?** `print(_G.GlobalRoles.cell_role[1])` — should be a role string from the ENUM.
6. **Is the SC voice allocated?** In sclang: `Crone.engine.kernel.triSinInstances.keys.postln;` — should include the cells you've toggled.
7. **Is the buffer cache populated?** For sampler issues: `Crone.engine.kernel.bufferCache.keysValuesDo({|p,b| (p ++ " refs=" ++ Crone.engine.kernel.bufferRefCounts[p]).postln; });` — should show your loaded files with refcount > 0.

Most issues localize to one of these checks. If everything looks normal but the script still misbehaves, you're in deep-bug territory and should add `print`s along the trace from chapter 01.

## A note on development workflow

The fastest dev loop for this script is:

1. Edit `.lua` files locally.
2. Tar + scp + extract (the script in section "Deploy mechanics" above).
3. SELECT to reload on Norns.
4. Check matron REPL for errors.
5. Test the change.
6. Repeat.

For SC changes, add a reboot step between 3 and 4. A typical full-cycle iteration on SC changes is about 30 seconds (mostly the reboot). On Lua changes, it's about 5 seconds.

Keep both matron and sclang REPL panes open in Maiden during development. The errors from each are essential signals — you do NOT want to miss them.

For complex changes, it's often worth doing the work in two passes:

1. **First pass**: get it to compile and load. Don't worry about correctness; just want no errors.
2. **Second pass**: actually test the feature.

Splitting the problem this way means you catch syntax errors and missing-module errors in a quick loop, leaving the slower correctness-testing for when the code is at least running.

`★ Insight ─────────────────────────────────────`
**The "edit locally, deploy, test" loop is slower than working in SC IDE or in a desktop Lua environment, but it has the advantage that you're testing on the actual target hardware.** Norns's specific limitations (small CPU, small memory pool, specific clock behavior) only show up there. Catching those issues at dev time is much better than discovering them later.

**For SynthDef work specifically**, the SC IDE on your workstation is the right place to iterate. Once a SynthDef is working in SC IDE, deploying to Norns is usually mechanical. Iterating SC code in Maiden's sclang REPL is slower (no syntax highlighting, no help browser, no docs lookup). Use SC IDE for SC work; use Maiden REPL just for diagnostics.
`─────────────────────────────────────────────────`

## Chapter 11 checkpoint

You should be able to:

- [ ] Deploy a tarball from your workstation to Norns and load the script.
- [ ] Distinguish between SC changes (need reboot) and Lua changes (need only reload).
- [ ] Execute the right reboot method for your hardware (battery-equipped or wall-powered).
- [ ] Run the TICK probe to diagnose matron scheduler health.
- [ ] Recognize and fix the six common failure modes covered above.
- [ ] Read both matron and sclang logs and identify where errors originate.

If those are solid, you have everything needed to maintain and extend schicksalslied 2.0.

## Closing

You've built the entire script — from `Lied.sc`'s real-time-pool-sensitive delay line to `voice_params.lua`'s dynamic-visibility param tree, with everything in between. You've internalized the three-tier architecture, the OSC barrier, the bus + group execution order, the pending-params + lazy-alloc patterns, the cross-include identity workaround, the absolute-vs-relative clock sync distinction, the option-type musical-fraction Timing system, the PSET sidecar, and the rest.

Where to go from here:

- **Modify and extend.** Add a new voice role. Tweak the granular chain. Replace MoogFF with a different filter. Each modification will exercise a different part of the architecture; each will teach you something the tutorial couldn't.

- **Re-read the per-file chapters as reference.** Each numbered chapter (03-08, 10-19) covers exactly one source file with full line-by-line annotation. When you're modifying a specific file and want to understand exactly why a specific block was written the way it was, jump to its chapter.

- **Look at the sibling lieder.** krahenlied, superLied, and naherinlied each handle the same "text as bytes drive musical material" idea differently. Reading them after this tutorial highlights the design tradeoffs that landed schicksalslied 2.0 where it is.

- **Build your own lied.** The pattern — Lua control + SC DSP + grid input + text-driven byte streams — is generalizable. Your version might emphasize something different: live-coding the text, different sequencing modes, a different audio engine entirely.

The script is open source; the README is in the repo root. If you discover bugs or improvements, the project welcomes them.

Thank you for reading. Now go make music.
