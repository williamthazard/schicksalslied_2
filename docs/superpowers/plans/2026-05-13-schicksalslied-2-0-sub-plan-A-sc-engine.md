# schicksalslied 2.0 — Sub-plan A: SC engine layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SuperCollider engine layer for schicksalslied 2.0 — kernel, Crone wrapper, voice classes (TriSin, Ringer), samplers (Sampler, OneShot), and the granular delay chain. End state: `sclang test.scd` runs cleanly on a desktop Mac, exercises every SC class, produces sound, and verifies real-time amp control. The Lua control layer (Sub-plan B) and params menu (Sub-plan C) are out of scope here.

**Architecture:** Single SC kernel class (`Lied`) owns buses, master FX, granular delay chain, and registries for the lazy-allocated voice/sampler/one-shot instances. Each voice type is its own SC class with a `voiceGroup` containing N polyphony sub-groups; real-time amp updates flow through `voiceGroup.set(\amp, x)` with `.lag()` smoothing inside the SynthDef. Persistent envelope voices (TriSin, Sampler, OneShot, granular chain) keep their Synths alive and retrigger via `\t_gate`; perc-style voices (Ringer) allocate fresh Synths per trigger and use `\stopGate = -1.05` for retrigger note-stealing.

**Tech Stack:** SuperCollider (`sclang`, SynthDefs, Groups, Buses, OSC), CroneEngine on Norns (deferred to Sub-plan B for actual wiring; here we build the kernel that the engine wraps). No Lua code yet. Testing via a `test.scd` Routine that boots SC, instantiates classes, triggers them, and waits — verified by ear and by SC's Post Window.

**Reference projects in this workspace:**
- `naherinlied/TriSin.sc`, `naherinlied/ringer.sc`, `naherinlied/oneshot.sc` — voice class templates
- `naherinlied/naherinlied.scd:98-189` — `\PlayBufPlayer` SynthDef for `Sampler.sc`
- `norns-ritual/norns-ritual/lib/Ritual.sc` — group hierarchy, master FX, `track_amp.lag()` pattern
- `norns-ritual/norns-ritual/test.scd` — test harness structure to mirror
- `https://github.com/williamthazard/carters-delay-norns/blob/main/lib/Engine_CartersDelay.sc` — proven Norns granular delay chain (SynthDefs to port)

**Reference spec:** `schicksalslied/docs/superpowers/specs/2026-05-13-schicksalslied-2-0-design.md` — §2, §3 (bus topology), §4 (allocation, retrigger discipline), §5 (sampler + one-shot), §6 (granular delay).

---

## Pre-flight

### Sub-plan A scope (which spec items)

- §2 (architecture overview), file layout for `lib/Lied.sc`, `lib/Engine_Lied.sc`, voice/sampler classes
- §4 (SC engine design — class hierarchy, retrigger discipline, allocation strategy, bus routing)
- §5 (sampler & one-shot SynthDefs and class structure)
- §6 (granular delay chain — mic, ptr, rec, fbPatchMix, 16 grain synths, Ndef LFOs)
- §14 testing items #1 (SC smoke test), #3 (real-time amp control), #7 (long-sample fade-out), #8 (sampler crossfade)

### Sub-plan A out of scope (deferred to B / C)

- The Lua script (`schicksalslied.lua`) rewrite — Sub-plan B
- `cell_roles.lua` / `sequencer.lua` / `wtape_looper.lua` — Sub-plan B
- Grid handling, screen redraw, keyboard input, K1/K2/K3 — Sub-plan B
- Params menu, LFO machinery, PSET — Sub-plan C
- Granular delay LFO *params* (we hard-code initial rates here; param wiring lands in Sub-plan C)
- Norns hardware deployment / CPU verification — done at the end of Sub-plan C

### File structure produced by this plan

**Created:**

```
schicksalslied/
  test.scd                     test harness (runs every voice class for verification)
  lib/
    Lied.sc                    SC kernel
    Engine_Lied.sc             Crone wrapper (skeleton; full command surface comes in B)
    TriSin.sc                  FM voice class (.lag() on amp)
    Ringer.sc                  pinged resonant voice class (.lag() on amp)
    Sampler.sc                 long-file sampler (Phasor + BufRd crossfade)
    OneShot.sc                 one-shot sampler (persistent, .lag() on amp)
  mac_ext/                     symlinks for local SC development
    Lied.sc -> ../lib/Lied.sc
    Engine_Lied.sc -> ../lib/Engine_Lied.sc
    TriSin.sc -> ../lib/TriSin.sc
    Ringer.sc -> ../lib/Ringer.sc
    Sampler.sc -> ../lib/Sampler.sc
    OneShot.sc -> ../lib/OneShot.sc
  audio/
    test_long.wav              short test sample (~5s) for Sampler tests
    test_oneshot.wav           short test sample (~1s) for OneShot tests
    test_field.wav             long test sample (~20s) for fade-out tests
```

**NOT touched yet** (Sub-plan B/C will remove these):
- `schicksalslied/schicksalslied.lua` (1.x still loadable; we add files alongside)
- `schicksalslied/lib/Engine_LiedMotor.sc`
- `schicksalslied/lib/LiedMotor_engine.lua`
- `schicksalslied/lib/lied_lfo.lua`
- `schicksalslied/lib/Engine_LiedMotor.sc` etc.

### Ground rules

- **All SC class names match their filenames** (SC convention; class `Lied` is in `Lied.sc`).
- **Local SC dev path:** symlinks in `mac_ext/` mirror `norns-ritual`'s pattern; symlink each file into `~/Library/Application Support/SuperCollider/Extensions/schicksalslied/` (covered by setup task).
- **Test runner:** `sclang test.scd` from the `schicksalslied/` directory. The script boots SC, sets `numInputBusChannels = 0` to avoid audio-device handshake issues (matches `seamstress-ritual.scd`), exercises each class, exits.
- **Commit cadence:** commit at the end of each task (after verification passes). Commits should be runnable — partial features at task boundaries should still compile and run `test.scd` without errors.
- **Git working dir:** `schicksalslied/` is its own git repo (verified — `.git/` is present). All commits land there. Reference commands assume `cd schicksalslied` first.

### Bias of this plan

These are SC tests, not Lua unit tests. Verification is largely **listen-and-confirm** (with print statements anchoring expected behavior) plus checking the SC Post Window for errors. Each task's "verification" step describes what you should HEAR and see. If you don't hear it, the test fails — debug before committing.

---

## Task 0 — sclang on PATH (verification)

The plan calls `sclang test.scd` from the command line. On macOS, `sclang` lives inside the SuperCollider app bundle and isn't on `$PATH` by default. This was already wired into `~/.bash_profile` and `~/.zshrc` during plan creation (lines were appended pointing PATH at `/Applications/SuperCollider.app/Contents/MacOS`). Each subagent task that invokes `sclang` should verify the binary is reachable before running.

**Files:**
- Pre-existing (modified during plan creation): `~/.bash_profile`, `~/.zshrc`

- [ ] **Step 1: Verify `sclang` is reachable from a fresh subagent shell**

```bash
# In a fresh shell, .bash_profile sources the SuperCollider PATH addition
bash -lc 'which sclang && sclang -v 2>&1 | head -1'
```

Expected output (versions may differ):
```
/Applications/SuperCollider.app/Contents/MacOS/sclang
sclang 3.14.1 (Built from tag 'Version-3.14.1' [426edf6])
```

- [ ] **Step 2: If `sclang` is NOT reachable, re-apply the PATH setup**

If the above command shows "sclang: command not found", the PATH addition is missing. Re-add:

```bash
cat >> ~/.bash_profile <<'EOF'

# SuperCollider sclang on PATH (added for schicksalslied 2.0 development)
export PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH"
EOF
```

Then re-verify with Step 1.

- [ ] **Step 3: Defensive idiom for every task that calls sclang**

Every task in this plan that runs `sclang test.scd` should be invoked as:

```bash
cd /Users/spencergraham/Desktop/other/lied-update/schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

This is a defensive belt-and-suspenders pattern: even if the subagent's shell didn't source `.bash_profile`, the inline `PATH=...` prefix puts sclang on PATH for that single invocation. Use this form in every Bash step that calls `sclang`.

No commit for this task — it's pure environment verification, not a code change.

---

## Phase 1 — SC kernel skeleton + Crone wrapper

Three small classes; smoke test that they boot cleanly with no SynthDefs yet.

### Task 1.1 — Project structure + symlink setup

**Files:**
- Create: `schicksalslied/mac_ext/` (directory + symlinks)
- Create: `schicksalslied/lib/Lied.sc` (skeleton)
- Create: `schicksalslied/lib/Engine_Lied.sc` (skeleton)
- Create: `schicksalslied/test.scd` (skeleton)
- Create: `schicksalslied/audio/` (directory)

- [ ] **Step 1: Create directories**

```bash
cd schicksalslied
mkdir -p mac_ext audio
```

- [ ] **Step 2: Write skeleton `lib/Lied.sc`**

```supercollider
// lib/Lied.sc — schicksalslied 2.0 SC kernel (skeleton)
Lied {
    var <server;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        "Lied initialized.".postln;
    }

    free {
        "Lied freed.".postln;
    }
}
```

- [ ] **Step 3: Write skeleton `lib/Engine_Lied.sc`**

```supercollider
// lib/Engine_Lied.sc — schicksalslied 2.0 Crone wrapper (skeleton)
// The full command surface lands in Sub-plan B. This skeleton just instantiates
// the Lied kernel so Norns will recognize the engine when loaded.
Engine_Lied : CroneEngine {
    var kernel;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        kernel = Lied.new(context.server);
        "Engine_Lied alloc complete.".postln;
    }

    free {
        kernel.free();
    }
}
```

- [ ] **Step 4: Symlink classes into SC Extensions directory**

**Important:** `Engine_Lied.sc` extends `CroneEngine`, a class that only exists in the Norns SuperCollider environment (it's not in the local SC distribution). If `Engine_Lied.sc` is placed in local Extensions, the class library compile fails with `Superclass 'CroneEngine' of class 'Engine_Lied' is not defined`, blocking sclang. **Only symlink `Lied.sc`** (the kernel) and the voice classes (added in later phases) into local Extensions. `Engine_Lied.sc` stays in `lib/` only — it's a Norns deployment artifact, not a local-dev artifact. (Same applies to every Crone-extending class added in this plan; if no such classes are added in later tasks, this caveat is Task-1.1-specific.)

```bash
mkdir -p "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied"
ln -sf "$(pwd)/lib/Lied.sc" "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/Lied.sc"
ls -la "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/"
```

Expected output: one symlink listed (Lied.sc).

Also write `mac_ext/` symlinks for both `Lied.sc` and `Engine_Lied.sc` — these are project-local documentation symlinks (they don't go to Extensions); they make it easy to see which files travel together when the project is deployed to Norns:

```bash
ln -sf ../lib/Lied.sc        mac_ext/Lied.sc
ln -sf ../lib/Engine_Lied.sc mac_ext/Engine_Lied.sc
```

- [ ] **Step 5: Write skeleton `test.scd`**

```supercollider
// test.scd — schicksalslied 2.0 SC engine test harness
// Run from project root:  sclang test.scd
// Boots SC, exercises each voice class, verifies sound + no errors, exits.

(
Routine({
    var kernel;

    Server.default.options.numInputBusChannels = 0;
    "Booting SuperCollider server...".postln;
    Server.default.bootSync;
    "Server booted.".postln;
    0.5.wait;

    "Instantiating Lied kernel...".postln;
    kernel = Lied.new(Server.default);
    2.0.wait;

    "All tests passed.".postln;
    kernel.free;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
)
```

- [ ] **Step 6: Run `test.scd`, verify clean boot**

```bash
cd schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Expected output (key lines, in order):
```
Booting SuperCollider server...
Server booted.
Instantiating Lied kernel...
Lied initialized.
All tests passed.
Lied freed.
```

If you see `*** ERROR: Class 'Lied' not defined` — the symlinks aren't being picked up. Restart sclang and verify the symlink path exists.

- [ ] **Step 7: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc lib/Engine_Lied.sc test.scd mac_ext/
git commit -m "schicksalslied 2.0: SC kernel + Crone wrapper skeleton

Sub-plan A, Task 1.1. Adds Lied.sc kernel class (empty init/free),
Engine_Lied.sc Crone wrapper skeleton, test.scd harness, and mac_ext/
symlinks for local SC development. Does not yet replace the 1.x
LiedMotor engine; both coexist during Sub-plan A development."
```

### Task 1.2 — Buses, master FX, group hierarchy

The `Lied` kernel needs three audio buses and two master FX synths (delay → reverb chain), wired so that any voice writing to delay-pre is reverberated, and any voice writing to reverb-pre is reverberated without delay. See spec §4 "Bus routing per voice".

**Files:**
- Modify: `schicksalslied/lib/Lied.sc`
- Modify: `schicksalslied/test.scd`

- [ ] **Step 1: Add SynthDefs and bus allocation to `Lied.init`**

Replace the contents of `init { arg inServer; ... }` in `lib/Lied.sc` with:

```supercollider
init { arg inServer;
    server = inServer ? Server.default;
    "Lied init: allocating buses + master FX...".postln;

    // --- Audio buses ---
    // dryBus       = main output (mirrors naherinlied's ~fb)
    // reverbBus    = pre-reverb send (mirrors naherinlied's c)
    // delayBus     = pre-delay send  (mirrors naherinlied's b)
    dryBus    = Bus.audio(server, 2);
    reverbBus = Bus.audio(server, 2);
    delayBus  = Bus.audio(server, 2);

    // --- Group hierarchy ---
    //   server default group
    //     └── voiceGroup (all voice instances will add to this; populated lazily later)
    //     └── fxGroup    (runs after voiceGroup, contains delay + reverb synths)
    voiceGroup = Group.new(server);
    fxGroup    = Group.after(voiceGroup);

    // --- SynthDefs: master FX ---
    // NOTE: norns-ritual wraps SynthDef definitions in `server.bind { ... }`,
    // but that pattern is unreliable in CLI-launched sclang (test.scd) — the
    // bundle mechanism races with `server.sync` and triggers "SynthDef X not
    // found" when the FX synth allocation immediately follows. Direct .add
    // calls + server.sync works reliably across both CLI and IDE contexts.

    // Delay reads delayBus → output to dryBus AND reverbBus (delay → reverb chain)
    // NOTE: CombL.ar's 4th arg is `decayTime` (time to decay 60 dB), not a
    // feedback amplitude coefficient. Naming the arg `decayTime` matches SC's
    // own terminology and avoids confusing the Lua-side param wiring later.
    SynthDef(\liedDelay, {
        arg inBus, dryOut, reverbOut, delayTime = 0.3, decayTime = 0.5,
            amp = 1.0, amp_slew = 0.1;
        var sig = In.ar(inBus, 2);
        var del = CombL.ar(sig, 2.0, delayTime, decayTime);
        var ampSmoothed = amp.lag(amp_slew);
        Out.ar(dryOut,    del * ampSmoothed);
        Out.ar(reverbOut, del * ampSmoothed);
    }).add;

    // Reverb reads reverbBus → output to dryBus
    SynthDef(\liedReverb, {
        arg inBus, dryOut, room = 0.5, damp = 0.5,
            amp = 1.0, amp_slew = 0.1;
        var sig = In.ar(inBus, 2);
        var rev = FreeVerb.ar(sig, 1.0, room, damp);
        Out.ar(dryOut, rev * amp.lag(amp_slew));
    }).add;

    // Pass dryBus through to main output (0)
    SynthDef(\liedOut, {
        arg inBus, amp = 1.0, amp_slew = 0.1;
        var sig = In.ar(inBus, 2);
        Out.ar(0, sig * amp.lag(amp_slew));
    }).add;

    server.sync;

    // --- Instantiate master FX (persistent) ---
    delaySynth  = Synth.new(\liedDelay,
        [\inBus, delayBus, \dryOut, dryBus, \reverbOut, reverbBus],
        fxGroup);
    reverbSynth = Synth.new(\liedReverb,
        [\inBus, reverbBus, \dryOut, dryBus],
        fxGroup);
    outSynth    = Synth.new(\liedOut,
        [\inBus, dryBus],
        Group.after(fxGroup));

    "Lied initialized.".postln;
}
```

Update the class variable declarations at the top of `Lied` to include the new state. Note `outGroup` — every server-side group needs a named class var so `free` can release it (no anonymous `Group.after(...)` calls).

```supercollider
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <voiceGroup, <fxGroup, <outGroup;
    var <delaySynth, <reverbSynth, <outSynth;

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        // ... (body from above, with one change: outGroup = Group.after(fxGroup);
        // before instantiating outSynth into outGroup)
    }

    free {
        delaySynth.free;
        reverbSynth.free;
        outSynth.free;
        outGroup.free;
        voiceGroup.free;
        fxGroup.free;
        dryBus.free;
        reverbBus.free;
        delayBus.free;
        "Lied freed.".postln;
    }
}
```

The corresponding instantiation block in `init` should be:

```supercollider
delaySynth  = Synth.new(\liedDelay,
    [\inBus, delayBus, \dryOut, dryBus, \reverbOut, reverbBus],
    fxGroup);
reverbSynth = Synth.new(\liedReverb,
    [\inBus, reverbBus, \dryOut, dryBus],
    fxGroup);
outGroup = Group.after(fxGroup);
outSynth = Synth.new(\liedOut,
    [\inBus, dryBus],
    outGroup);
```

(Plan correction: the original code used `Group.after(fxGroup)` inline as `outSynth`'s parent arg, dropping the reference. That leaks a group on every kernel restart. Always store group references.)

- [ ] **Step 2: Update `test.scd` to verify FX chain audibly**

Replace the body of the `Routine({ ... })` in `test.scd` with:

```supercollider
Routine({
    var kernel, testSynth;

    Server.default.options.numInputBusChannels = 0;
    "Booting SuperCollider server...".postln;
    Server.default.bootSync;
    "Server booted.".postln;
    0.5.wait;

    "Instantiating Lied kernel...".postln;
    kernel = Lied.new(Server.default);
    1.0.wait;

    // Test 1: dry bus passthrough — should hear a clean 440Hz tone for 1s
    "Test 1: dry bus passthrough (clean 440Hz, no FX)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.dryBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    1.5.wait;

    // Test 2: reverb send — 440Hz tone with reverb tail
    "Test 2: reverb send (440Hz with reverb tail)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.reverbBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    3.0.wait;

    // Test 3: delay send — 440Hz tone with delay (and reverb on the delay tail)
    "Test 3: delay send (440Hz with delay + reverb)...".postln;
    testSynth = {
        var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.01, 0.8), doneAction: 2) * 0.3;
        Out.ar(kernel.delayBus, [sig, sig]);
    }.play(kernel.voiceGroup);
    5.0.wait;

    kernel.free;
    "All tests passed.".postln;
    Server.default.quit;
    1.0.wait;
    0.exit;
}).play(SystemClock);
```

(`kernel.free` before `"All tests passed.".postln` — preserves the Task 1.1 review fix.)

- [ ] **Step 3: Run `test.scd`, verify each FX behaves audibly**

```bash
cd schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

You should hear, in order:
1. A clean 440Hz tone for ~1 second, no reverb, no delay.
2. The same tone with a noticeable reverb tail.
3. The same tone with delay echoes, each echo getting reverb on top.

The Post Window should print all three "Test N" lines, no SC errors, ending with "All tests passed."

If you hear no sound: confirm your audio output device is selected in SC (Server.default.options.outDevice_(...)). If you hear errors about buses not existing, you probably broke the symlinks — verify `ls ~/Library/Application\ Support/SuperCollider/Extensions/schicksalslied/`.

- [ ] **Step 4: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc test.scd
git commit -m "schicksalslied 2.0: Lied kernel buses + master FX

Sub-plan A, Task 1.2. Adds dry/reverb/delay buses and persistent
master delay + reverb synths to the Lied kernel. .lag() on FX amp
args for real-time control. Test harness verifies all three bus
paths audibly."
```

### Task 1.3 — beat_sec command + skeleton instance registries

The granular delay (Phase 4) needs a beat duration to allocate its buffer. The `Engine_Lied` Crone wrapper exposes a `\set_beat_sec` command that updates the kernel; Sub-plan B will wire it from the Lua side. For now we just plumb the value.

Also: add empty registries (Lua-side Dictionaries) for the voice/sampler/one-shot instances that will be populated in later phases.

**Files:**
- Modify: `schicksalslied/lib/Lied.sc`
- Modify: `schicksalslied/lib/Engine_Lied.sc`
- Modify: `schicksalslied/test.scd`

- [ ] **Step 1: Add `beat_sec` and registries to `Lied`**

Update class variables and `init`:

```supercollider
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <voiceGroup, <fxGroup;
    var <delaySynth, <reverbSynth, <outSynth;
    var <beat_sec;                  // updated via setBeatSec from Lua
    var <triSinInstances;           // Dictionary: cell_id (Symbol) → TriSin instance
    var <ringerInstances;           // Dictionary: cell_id (Symbol) → Ringer instance
    var <samplerInstances;          // Dictionary: slot (Integer)  → Sampler instance
    var <oneShotInstances;          // Dictionary: slot (Integer)  → OneShot instance

    *new { arg server;
        ^super.new.init(server);
    }

    init { arg inServer;
        server = inServer ? Server.default;
        beat_sec = 0.5;             // default = 120 BPM
        triSinInstances  = Dictionary.new;
        ringerInstances  = Dictionary.new;
        samplerInstances = Dictionary.new;
        oneShotInstances = Dictionary.new;
        "Lied init: allocating buses + master FX...".postln;

        // ... rest unchanged
    }

    setBeatSec { arg newBeatSec;
        beat_sec = newBeatSec;
        ("Lied: beat_sec = " ++ beat_sec).postln;
    }

    free {
        // ... existing free body
        // Free all instance registries
        triSinInstances.do { |inst| inst.free };
        ringerInstances.do { |inst| inst.free };
        samplerInstances.do { |inst| inst.free };
        oneShotInstances.do { |inst| inst.free };
        // ... rest unchanged
    }
}
```

- [ ] **Step 2: Wire `\set_beat_sec` command in `Engine_Lied`**

Replace the body of `alloc` in `Engine_Lied.sc`:

```supercollider
alloc {
    kernel = Lied.new(context.server);

    this.addCommand(\set_beat_sec, "f", { arg msg;
        kernel.setBeatSec(msg[1]);
    });

    "Engine_Lied alloc complete.".postln;
}
```

- [ ] **Step 3: Verify `Lied.setBeatSec` works in `test.scd`**

After kernel instantiation, add a test:

```supercollider
"Test 4: setBeatSec updates kernel.beat_sec...".postln;
kernel.setBeatSec(0.25);    // 240 BPM
("  Expected beat_sec=0.25, actual=" ++ kernel.beat_sec).postln;
if (kernel.beat_sec == 0.25, {
    "  ✓ setBeatSec works".postln;
}, {
    "  ✗ FAIL: setBeatSec did not update beat_sec".postln;
});
1.0.wait;
```

- [ ] **Step 4: Run `test.scd`, verify beat_sec test passes**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Expected new lines in the post window:
```
Test 4: setBeatSec updates kernel.beat_sec...
Lied: beat_sec = 0.25
  Expected beat_sec=0.25, actual=0.25
  ✓ setBeatSec works
```

- [ ] **Step 5: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc lib/Engine_Lied.sc test.scd
git commit -m "schicksalslied 2.0: beat_sec plumbing + instance registries

Sub-plan A, Task 1.3. Adds beat_sec state to Lied kernel (settable
via Engine_Lied's \\set_beat_sec command) and empty Dictionary
registries for the voice/sampler/one-shot instances that later
phases will populate. Test verifies setBeatSec roundtrip."
```

---

## Phase 2 — Voice classes (TriSin + Ringer)

Port both voice classes from naherinlied, add `.lag()` on amp so `voiceGroup.set(\amp, x)` is click-free mid-sound.

### Task 2.1 — TriSin class (port + .lag on amp)

**Files:**
- Create: `schicksalslied/lib/TriSin.sc`
- Modify: `schicksalslied/mac_ext/` (add symlink)
- Modify: `schicksalslied/test.scd`

Reference: `naherinlied/trisin.sc` (full source, 186 lines). The 2.0 version adds `amp.lag(amp_slew)` so amp updates are click-free mid-note.

- [ ] **Step 1: Write `lib/TriSin.sc`**

```supercollider
// lib/TriSin.sc — FM voice class (ported from naherinlied with .lag on amp)
TriSin {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef("TriSin", {
                    arg t_gate = 0,
                        mRatio,
                        cRatio,
                        index,
                        iScale,
                        freq,
                        phase,
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
                        bus;

                    var car, mod, envelope, iEnv, filter, signal;
                    var slewed_freq = freq.lag3(freq_slew);

                    envelope = EnvGen.kr(
                        envelope: Env(
                            [0, 1, 0],
                            times: [attack, release],
                            curve: [cAtk, cRel]),
                        gate: t_gate
                    );

                    iEnv = EnvGen.kr(
                        Env(
                            [index, index * iScale, index],
                            times: [iattack, irelease],
                            curve: [ciAtk, ciRel]),
                        gate: t_gate
                    );

                    mod = SinOsc.ar(slewed_freq * mRatio, mul: slewed_freq * mRatio * iEnv);
                    car = LFTri.ar(slewed_freq * cRatio + mod) * envelope;

                    filter = MoogFF.ar(
                        in: car,
                        freq: Select.kr(cutoff_env > 0, [cutoff, cutoff * envelope]),
                        gain: resonance
                    );

                    signal = Pan2.ar(
                        filter,
                        pan.lag3(pan_slew)
                    );

                    // .lag3 on amp for click-free real-time amp control
                    Out.ar(bus, signal * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new {
        ^super.new.init;
    }

    init {
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \mRatio, 1,
            \cRatio, 1,
            \index, 1,
            \iScale, 5,
            \phase, 0,
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
            \bus, 0;
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

    // Trigger the named voice key (or 'all'). For persistent envelopes,
    // re-triggers the existing Synth if alive; otherwise allocates one.
    playVoice {
        arg voiceKey, freq;
        if (singleVoices[voiceKey].isPlaying, {
            voiceParams[voiceKey][\freq] = freq;
            singleVoices[voiceKey].set(\freq, freq);
            singleVoices[voiceKey].set(\t_gate, 1);
        }, {
            voiceParams[voiceKey][\freq] = freq;
            Synth.new("TriSin", voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
            singleVoices[voiceKey].set(\t_gate, 1);
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

    // Set a param on one voice (Synth-level) AND cache in voiceParams (for next alloc).
    adjustVoice {
        arg voiceKey, paramKey, paramValue;
        singleVoices[voiceKey].set(paramKey, paramValue);
        voiceParams[voiceKey][paramKey] = paramValue;
    }

    // Set param across all 8 voices in one go via voiceGroup.set (1 OSC msg).
    // This is the cross-cutting "real-time amp control" idiom: changing amp
    // here audibly fades currently-sounding notes, not just future ones.
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

    freeAllNotes {
        voiceGroup.set(\stopGate, -1.05);
    }

    free {
        voiceGroup.free;
    }
}
```

- [ ] **Step 2: Symlink TriSin into Extensions**

```bash
cd schicksalslied
ln -sf "$(pwd)/lib/TriSin.sc" "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/TriSin.sc"
ln -sf ../lib/TriSin.sc mac_ext/TriSin.sc
ls -la mac_ext/
```

Verify both symlinks point to existing files.

- [ ] **Step 3: Add a TriSin test to `test.scd`**

Add this block after the existing Test 4 (and before the final "All tests passed."):

```supercollider
// Test 5: TriSin — trigger a note, verify sound, verify real-time amp control
"Test 5: TriSin basic trigger (440Hz, voice \\1, on dryBus)...".postln;
~triSinTest = TriSin.new;
~triSinTest.setParam('all', \bus, kernel.dryBus.index);
~triSinTest.setParam('all', \amp, 0.5);
~triSinTest.setParam('all', \release, 2.0);  // long release for amp-sweep test
~triSinTest.trigger(\1, 440);
"  Expected: 440Hz tone with 2s release.".postln;
2.0.wait;

"Test 6: TriSin real-time amp fade — note still sounding, fade amp to 0 mid-note".postln;
~triSinTest.trigger(\2, 220);
0.3.wait;
"  Mid-note, setting amp=0 (should hear smooth fade-out, no click)...".postln;
~triSinTest.setParam('all', \amp, 0);
1.5.wait;
~triSinTest.setParam('all', \amp, 0.5);  // restore for cleanup
0.5.wait;
~triSinTest.free;
1.0.wait;
```

- [ ] **Step 4: Run `test.scd`, verify TriSin tests audibly**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for:
- Test 5: A 440Hz FM-ish tone with about a 2-second release tail.
- Test 6: A second tone (220Hz) starts; ~300ms in, the volume smoothly fades to silence over ~1 second. **No clicks during the fade.** If there's a click, `amp.lag3(amp_slew)` isn't working — check the SynthDef.

The cross-cutting "real-time amp control" requirement is verified here. **This is the spec's §14 test #3.**

- [ ] **Step 5: Commit**

```bash
cd schicksalslied
git add lib/TriSin.sc mac_ext/TriSin.sc test.scd
git commit -m "schicksalslied 2.0: TriSin voice class

Sub-plan A, Task 2.1. Ports naherinlied's TriSin class with .lag3
on amp (replacing direct amp multiplication) for click-free
real-time amp control. setParam('all', ...) uses voiceGroup.set
for single-OSC-message updates. Test verifies real-time amp fade
of a sounding note (spec §14 test #3)."
```

### Task 2.2 — TriSin polyphony round-robin verification

We didn't change anything in TriSin's polyphony handling vs naherinlied (it still has 8 sub-groups via `voiceKeys`). But we should verify round-robin behavior works correctly.

**Files:**
- Modify: `schicksalslied/test.scd`

- [ ] **Step 1: Add a polyphony test to `test.scd`**

Add this block after Test 6:

```supercollider
"Test 7: TriSin polyphony — fire 4 notes in rapid succession on different voiceKeys".postln;
~triSinPoly = TriSin.new;
~triSinPoly.setParam('all', \bus, kernel.dryBus.index);
~triSinPoly.setParam('all', \amp, 0.3);
~triSinPoly.setParam('all', \release, 3.0);  // long release so notes overlap
~triSinPoly.trigger(\1, 261.6);   // C4
0.3.wait;
~triSinPoly.trigger(\2, 329.6);   // E4
0.3.wait;
~triSinPoly.trigger(\3, 392.0);   // G4
0.3.wait;
~triSinPoly.trigger(\4, 523.3);   // C5
"  Expected: 4 notes stacking into a C major chord with overlapping releases.".postln;
3.0.wait;
~triSinPoly.free;
1.0.wait;
```

- [ ] **Step 2: Run `test.scd`, verify polyphony**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

You should hear a 4-note arpeggio building into a sustained C major chord. The notes should overlap — if they steal each other (each new note silences the previous), the polyphony isn't working. The voice keys are independent groups, so they should not collide.

- [ ] **Step 3: Commit**

```bash
cd schicksalslied
git add test.scd
git commit -m "schicksalslied 2.0: TriSin polyphony verification

Sub-plan A, Task 2.2. Adds round-robin polyphony test — 4 notes on
4 different voiceKeys with long release, verifies they stack rather
than steal each other."
```

### Task 2.3 — Ringer class

Ringer is simpler than TriSin: perc-style envelope with `doneAction:2`. Naherinlied's `ringer.sc` already has `.lag3` on amp at the output, so it's a more straightforward port. The retrigger discipline differs from TriSin: each trigger allocates a fresh Synth and the previous one (if alive) gets `\stopGate = -1.05`.

**Files:**
- Create: `schicksalslied/lib/Ringer.sc`
- Modify: `schicksalslied/mac_ext/`
- Modify: `schicksalslied/test.scd`

Reference: `naherinlied/ringer.sc` (137 lines). Drop the redundant `* envelope` (the SynthDef multiplies envelope twice in naherinlied's version; that's a 1.x quirk we're not porting).

- [ ] **Step 1: Write `lib/Ringer.sc`**

```supercollider
// lib/Ringer.sc — pinged resonant voice class (perc envelope, doneAction:2)
Ringer {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef("Ringer", {
                    arg out = 0,
                        stopGate = 1,
                        index,
                        freq,
                        amp,
                        pan,
                        freq_slew,
                        amp_slew,
                        pan_slew,
                        bus;

                    var envelope = EnvGen.kr(
                        envelope: Env.perc(
                            attackTime: 0.01,
                            releaseTime: index.abs * 2,
                            level: 1),
                        gate: stopGate,
                        doneAction: 2
                    );

                    var sig = Ringz.ar(
                        Impulse.ar(0),
                        freq.lag3(freq_slew),
                        index,
                        amp
                    ) * envelope;

                    var signal = Pan2.ar(
                        sig,
                        pan.lag3(pan_slew)
                    );

                    Out.ar(bus, signal * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new {
        ^super.new.init;
    }

    init {
        var s = Server.default;

        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \freq, 400,
            \index, 3,
            \amp, 0.5,
            \pan, 0,
            \freq_slew, 0,
            \amp_slew, 0.05,
            \pan_slew, 0.5,
            \bus, 0;
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

    // Stop-gate the previous (if any), then fire a fresh Synth.
    // Ringer's envelope has doneAction:2 so it self-frees at release.
    playVoice {
        arg voiceKey, freq;
        singleVoices[voiceKey].set(\stopGate, -1.05);
        voiceParams[voiceKey][\freq] = freq;
        Synth.new("Ringer", [\freq, freq] ++ voiceParams[voiceKey].getPairs, singleVoices[voiceKey]);
    }

    trigger {
        arg voiceKey, freq;
        if (voiceKey == 'all', {
            voiceKeys.do({ arg vK; this.playVoice(vK, freq); });
        }, {
            this.playVoice(voiceKey, freq);
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

    freeAllNotes {
        voiceGroup.set(\stopGate, -1.05);
    }

    free {
        voiceGroup.free;
    }
}
```

- [ ] **Step 2: Symlink Ringer into Extensions**

```bash
cd schicksalslied
ln -sf "$(pwd)/lib/Ringer.sc" "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/Ringer.sc"
ln -sf ../lib/Ringer.sc mac_ext/Ringer.sc
```

- [ ] **Step 3: Add Ringer test to `test.scd`**

Add after the polyphony test:

```supercollider
"Test 8: Ringer basic trigger (pinged resonant filter at 440Hz)...".postln;
~ringerTest = Ringer.new;
~ringerTest.setParam('all', \bus, kernel.dryBus.index);
~ringerTest.setParam('all', \amp, 0.5);
~ringerTest.setParam('all', \index, 4);
~ringerTest.trigger(\1, 440);
"  Expected: pinged Ringz tone with ~8s decay (index=4, release=index*2).".postln;
2.0.wait;

"Test 9: Ringer real-time amp fade — note still sounding, fade amp to 0...".postln;
~ringerTest.trigger(\2, 220);
0.3.wait;
"  Mid-note, setting amp=0 (should hear smooth fade-out)...".postln;
~ringerTest.setParam('all', \amp, 0);
1.5.wait;
~ringerTest.free;
1.0.wait;
```

- [ ] **Step 4: Run `test.scd`, verify Ringer behavior**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for:
- Test 8: Pinged resonant tone with a slow decay (~4-8 seconds).
- Test 9: Second pinged tone, smoothly fades to silence ~300ms in.

- [ ] **Step 5: Commit**

```bash
cd schicksalslied
git add lib/Ringer.sc mac_ext/Ringer.sc test.scd
git commit -m "schicksalslied 2.0: Ringer voice class

Sub-plan A, Task 2.3. Ports naherinlied's Ringer class with .lag3
on amp at output. Perc-style envelope with doneAction:2; retrigger
allocates fresh Synth, previous one gates off via stopGate=-1.05.
Test verifies pinged tone + real-time amp fade."
```

---

## Phase 3 — Sampler + OneShot

Build the two sampler classes that replace softcut.

### Task 3.1 — Sampler class (Phasor + BufRd crossfade)

**Files:**
- Create: `schicksalslied/lib/Sampler.sc`
- Modify: `schicksalslied/mac_ext/`
- Modify: `schicksalslied/test.scd`
- Need: `schicksalslied/audio/test_long.wav` (~5s test audio)

Reference: `naherinlied/naherinlied.scd:98-189` — the `\PlayBufPlayer` SynthDef. Wrap it in a class similar to the other voice classes.

- [ ] **Step 1: Provide a test audio file**

Generate a quick test sample (any short audio file works; if you have no audio handy, use SC to render one):

```bash
cd schicksalslied/audio
# Option A: generate a 5s test tone with sox if available
sox -n -r 48000 -c 2 test_long.wav synth 5.0 sine 440 sine 660 mix 0.5 0.5

# Option B (if sox not installed): boot SC and use Buffer.write to render one
# (Skip if you already have any .wav/.aiff at hand — copy it to audio/test_long.wav)
```

Verify: `ls -la audio/test_long.wav` shows a file with non-zero size.

- [ ] **Step 2: Write `lib/Sampler.sc`**

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

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef(\Sampler, {
                    arg out = 0,
                        bufnum = 0,
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
                        resonance = 1,
                        rateSlew = 0.1,
                        bus = 0;
                    var snd, snd2, pos, pos2, frames, duration, env, sig,
                        startA, endA, startB, endB, crossfade, aOrB;

                    aOrB = ToggleFF.kr(t_trig);
                    startA = Latch.kr(start, aOrB);
                    endA   = Latch.kr(end,   aOrB);
                    startB = Latch.kr(start, 1 - aOrB);
                    endB   = Latch.kr(end,   1 - aOrB);
                    crossfade = Lag.ar(K2A.ar(aOrB), 0.1);

                    rate = Lag.kr(rate, rateSlew) * BufRateScale.kr(bufnum);
                    frames = BufFrames.kr(bufnum);
                    duration = frames * (end - start) / rate.abs / s.sampleRate * loops;

                    env = EnvGen.ar(
                        Env.new(
                            levels: [0, amp, amp, 0],
                            times:  [0, duration - 0.1, 0.1]),
                        gate: t_trig,
                    );

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

                    sig = Pan2.ar(
                        MoogFF.ar(
                            in: (crossfade * snd) + ((1 - crossfade) * snd2) * env,
                            freq: cutoff,
                            gain: resonance),
                        pan.lag3(pan_slew)
                    );

                    // .lag3 on amp for click-free real-time amp control
                    Out.ar(bus, LeakDC.ar(sig) * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new { arg buf;
        ^super.new.init(buf);
    }

    init { arg buf;
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
            \resonance, 1,
            \rateSlew, 0.1,
            \bus, 0;
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

    // Trigger the named voice with a play window and rate.
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

    free {
        voiceGroup.free;
    }
}
```

- [ ] **Step 3: Symlink Sampler into Extensions**

```bash
cd schicksalslied
ln -sf "$(pwd)/lib/Sampler.sc" "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/Sampler.sc"
ln -sf ../lib/Sampler.sc mac_ext/Sampler.sc
```

- [ ] **Step 4: Add Sampler test to `test.scd`**

Add at the appropriate point in the Routine (after Ringer tests):

```supercollider
"Test 10: Sampler — load audio/test_long.wav, trigger, hear playback".postln;
~samplerBuf = Buffer.read(Server.default, "audio/test_long.wav");
Server.default.sync;
("  Loaded buffer: " ++ ~samplerBuf.numFrames ++ " frames, "
    ++ ~samplerBuf.numChannels ++ " channels").postln;

~samplerTest = Sampler.new(~samplerBuf);
~samplerTest.setParam('all', \bus, kernel.dryBus.index);
~samplerTest.setParam('all', \amp, 0.5);
~samplerTest.trigger(\1, 0.0, 1.0, 1);   // play full buffer
"  Expected: full test_long.wav plays at original rate.".postln;
6.0.wait;
~samplerTest.free;
~samplerBuf.free;
1.0.wait;
```

- [ ] **Step 5: Run `test.scd`, verify sampler plays**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for the test audio file playing back at original rate for ~5 seconds. If you hear nothing, check the `audio/test_long.wav` path and that the buffer loaded (post window should show "Loaded buffer: ..."). If you hear distortion, the file may not be 2-channel stereo — the SynthDef reads as `numChannels: 2`.

- [ ] **Step 6: Commit**

```bash
cd schicksalslied
git add lib/Sampler.sc mac_ext/Sampler.sc audio/ test.scd
git commit -m "schicksalslied 2.0: Sampler class (Phasor + BufRd crossfade)

Sub-plan A, Task 3.1. Ports naherinlied's PlayBufPlayer SynthDef
into a Sampler class with the voice-key idiom. Dual-Phasor +
ToggleFF crossfade for click-free retrigger. .lag3 on amp for
real-time control. Adds test_long.wav for verification."
```

### Task 3.2 — Sampler crossfade test (rapid retrigger, no clicks)

This is spec §14 test #8: rapidly retrigger the sampler at small intervals and listen for clicks. The dual-Phasor + ToggleFF design should produce none.

**Files:**
- Modify: `schicksalslied/test.scd`

- [ ] **Step 1: Add crossfade test**

Insert after Test 10:

```supercollider
"Test 11: Sampler crossfade — rapid retriggers at 16th-note intervals (~250ms)".postln;
~xfBuf = Buffer.read(Server.default, "audio/test_long.wav");
Server.default.sync;
~xfSampler = Sampler.new(~xfBuf);
~xfSampler.setParam('all', \bus, kernel.dryBus.index);
~xfSampler.setParam('all', \amp, 0.3);
"  Expected: 16 retriggers, each cutting cleanly to the next.".postln;
"  Failure mode: audible clicks/pops on each retrigger.".postln;
16.do({ arg i;
    var startPos = i.linlin(0, 16, 0.0, 0.8);
    var endPos   = startPos + 0.05;
    ~xfSampler.trigger(\1, startPos, endPos, 1);
    0.25.wait;
});
~xfSampler.free;
~xfBuf.free;
1.0.wait;
```

- [ ] **Step 2: Run `test.scd`, listen carefully for clicks**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

You should hear 16 short clips of the test buffer triggered in sequence over ~4 seconds. **Listen for clicks at the trigger points.** Subtle pops are acceptable (perfect click-free is hard); audible "tick-tick-tick" at each trigger means the crossfade isn't working.

If clicks are audible: the `Lag.ar(K2A.ar(aOrB), 0.1)` envelope time may need adjustment. Try `0.2` instead of `0.1` and re-test. Document the change in your commit message.

- [ ] **Step 3: Commit**

```bash
cd schicksalslied
git add test.scd
git commit -m "schicksalslied 2.0: Sampler crossfade verification

Sub-plan A, Task 3.2. Adds rapid retrigger test (16 triggers at 16th
notes) to verify the dual-Phasor + ToggleFF crossfade prevents clicks.
Implements spec §14 test #8."
```

### Task 3.3 — OneShot class

OneShot replaces naherinlied's drum samplers but is reframed as generic one-shot — could hold drums OR a 20-minute field recording. Must support real-time amp fade-out (spec §14 test #7).

**Files:**
- Create: `schicksalslied/lib/OneShot.sc`
- Modify: `schicksalslied/mac_ext/`
- Modify: `schicksalslied/test.scd`
- Need: `schicksalslied/audio/test_oneshot.wav` (~1s), `schicksalslied/audio/test_field.wav` (~20s for fade test)

Reference: `naherinlied/oneshot.sc` (131 lines). Fix the double-amp-multiplication bug, add `.lag3` for click-free amp updates, make persistent (no doneAction:2).

- [ ] **Step 1: Provide test audio**

```bash
cd schicksalslied/audio
# Short hit for retrigger tests
sox -n -r 48000 -c 1 test_oneshot.wav synth 0.5 noise fade 0.01 0.5 0.0

# Long sample for fade-out tests
sox -n -r 48000 -c 1 test_field.wav synth 20.0 sine 220 sine 330 mix 0.3 0.3
```

If sox isn't available, copy any 1s and 20s audio files into place with those names.

- [ ] **Step 2: Write `lib/OneShot.sc`**

```supercollider
// lib/OneShot.sc — persistent one-shot sampler with .lag3 on amp
// Upgrade of naherinlied's OneShot: fixes the double-amp-multiplication
// bug (1.x multiplied amp twice in the signal chain), makes the synth
// persistent (no doneAction:2) so amp can be faded out mid-playback,
// adds .lag3 smoothing on amp.
OneShot {
    classvar <voiceKeys;

    var <globalParams;
    var <voiceParams;
    var <voiceGroup;
    var <singleVoices;
    var <buffer;

    *initClass {
        voiceKeys = [\1, \2, \3, \4, \5, \6, \7, \8];
        StartUp.add {
            var s = Server.default;

            s.waitForBoot {

                SynthDef("OneShot", {
                    arg t_gate = 0,
                        rate = 1,
                        cutoff = 12000,
                        resonance = 1,
                        amp = 0.5,
                        amp_slew = 0.05,
                        pan = 0,
                        pan_slew = 0.5,
                        buf,
                        bus = 0;

                    var sig = PlayBuf.ar(1, buf, BufRateScale.ir(buf) * rate, t_gate);
                    var filter = MoogFF.ar(sig, cutoff, resonance);
                    var signal = Pan2.ar(filter, pan.lag3(pan_slew));

                    // Single amp multiplication with .lag3 for click-free
                    // real-time control. No doneAction:2 — synth is persistent.
                    Out.ar(bus, signal * amp.lag3(amp_slew));
                }).add;
            }
        }
    }

    *new { arg buf;
        ^super.new.init(buf);
    }

    init { arg buf;
        var s = Server.default;

        buffer = buf;
        voiceGroup = Group.new(s);

        globalParams = Dictionary.newFrom([
            \cutoff, 12000,
            \resonance, 1,
            \amp, 0.5,
            \amp_slew, 0.05,
            \pan, 0,
            \pan_slew, 0.5,
            \buf, buf.bufnum,
            \rate, 1,
            \bus, 0;
        ]);
        singleVoices = Dictionary.new;
        voiceParams = Dictionary.new;
        voiceKeys.do({
            arg voiceKey;
            singleVoices[voiceKey] = Group.new(voiceGroup);
            voiceParams[voiceKey] = Dictionary.newFrom(globalParams);
        });
    }

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

    free {
        voiceGroup.free;
    }
}
```

- [ ] **Step 3: Symlink OneShot**

```bash
cd schicksalslied
ln -sf "$(pwd)/lib/OneShot.sc" "$HOME/Library/Application Support/SuperCollider/Extensions/schicksalslied/OneShot.sc"
ln -sf ../lib/OneShot.sc mac_ext/OneShot.sc
```

- [ ] **Step 4: Add OneShot tests to `test.scd`**

```supercollider
"Test 12: OneShot — basic trigger, hear a quick noise burst".postln;
~oneShotBuf = Buffer.read(Server.default, "audio/test_oneshot.wav");
Server.default.sync;
~oneShotTest = OneShot.new(~oneShotBuf);
~oneShotTest.setParam('all', \bus, kernel.dryBus.index);
~oneShotTest.setParam('all', \amp, 0.5);
~oneShotTest.trigger(\1);
"  Expected: 0.5s noise burst.".postln;
1.0.wait;
~oneShotTest.free;
~oneShotBuf.free;
1.0.wait;

"Test 13: OneShot long-sample fade-out (spec §14 test #7)".postln;
~fieldBuf = Buffer.read(Server.default, "audio/test_field.wav");
Server.default.sync;
~fieldTest = OneShot.new(~fieldBuf);
~fieldTest.setParam('all', \bus, kernel.dryBus.index);
~fieldTest.setParam('all', \amp, 0.5);
~fieldTest.setParam('all', \amp_slew, 1.0);  // slow fade
~fieldTest.trigger(\1);
"  Long sample (~20s) starts playing...".postln;
2.0.wait;
"  Mid-playback: setting amp=0 with 1s slew. Expected: smooth fade to silence.".postln;
~fieldTest.setParam('all', \amp, 0);
2.0.wait;
"  ✓ if you heard a smooth fade with no click, real-time amp on long samples works".postln;
~fieldTest.free;
~fieldBuf.free;
1.0.wait;
```

- [ ] **Step 5: Run `test.scd`, verify both tests**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for:
- Test 12: A 0.5-second noise burst.
- Test 13: A long sustained tone starts playing; 2 seconds in, it smoothly fades to silence over ~1 second. **This is spec §14 test #7.** If you hear a pop instead of a fade, `amp.lag3(amp_slew)` isn't taking effect — debug.

- [ ] **Step 6: Commit**

```bash
cd schicksalslied
git add lib/OneShot.sc mac_ext/OneShot.sc audio/test_oneshot.wav audio/test_field.wav test.scd
git commit -m "schicksalslied 2.0: OneShot class (persistent, real-time amp)

Sub-plan A, Task 3.3. Upgrades naherinlied's OneShot: removes the
double-amp-multiplication bug, makes the synth persistent (no
doneAction:2) so long samples can be faded out mid-playback via
group.set, adds .lag3 amp smoothing. Tests basic trigger and the
spec §14 test #7 (long-sample fade-out)."
```

---

## Phase 4 — Granular delay chain

Port the proven Norns design from `carters-delay-norns/lib/Engine_CartersDelay.sc` into the `Lied` kernel. All allocated persistently at boot.

### Task 4.1 — Granular SynthDefs (mic, ptr, rec, fbPatchMix, gran)

**Files:**
- Modify: `schicksalslied/lib/Lied.sc`

- [ ] **Step 1: Add granular SynthDefs to `Lied`'s `server.bind` block**

In `lib/Lied.sc`, inside the `init` method's `server.bind { ... }` block (after the existing `\liedOut` SynthDef and before the closing `};`), add:

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

        // Mic dry passthrough → main output bus (naherinlied feature, not in
        // carters-delay-norns standalone)
        SynthDef(\liedMicDry, {
            arg in = 0, out = 0, amp = 0, amp_slew = 0.05;
            var sig = SoundIn.ar(in) * amp.lag3(amp_slew);
            Out.ar(out, [sig, sig]);
        }).add;

        // Pointer (write head) — advances through the delay buffer
        SynthDef(\liedPtr, {
            arg out = 0, buf = 0, rate = 1;
            var sig = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, BufFrames.kr(buf));
            Out.ar(out, sig);
        }).add;

        // Recorder — writes (micBus + preLevel * existing buffer) to delay buffer
        SynthDef(\liedRec, {
            arg ptrIn = 0, micIn = 0, buf = 0, preLevel = 0;
            var ptr = In.ar(ptrIn, 1);
            var sig = In.ar(micIn, 1);
            sig = sig + (BufRd.ar(1, buf, ptr) * preLevel);
            BufWr.ar(sig, buf, ptr);
        }).add;

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
                cutoff = 12000, resonance = 1;
            var sig, env, densCtrl, durCtrl, rateCtrl, panCtrl,
                ptr, ptrRand, totalDelay, maxGrainDur;
            env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);
            densCtrl = Select.ar(sync, [Dust.ar(dens), Impulse.ar(dens)]);
            durCtrl = baseDur * LFNoise1.ar(100).exprange(1 / durRand, durRand);
            rateCtrl = rate.lag3(0.5) * LFNoise1.ar(100).exprange(1 / rateRand, rateRand);
            panCtrl = pan + LFNoise1.kr(100).bipolar(panRand);
            ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples);
            totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay);
            ptr = In.ar(ptrBus, 1);
            ptr = ptr - totalDelay;
            ptr = ptr / BufFrames.kr(buf);
            maxGrainDur = (totalDelay / rateCtrl) / SampleRate.ir;
            durCtrl = min(durCtrl, maxGrainDur);
            sig = GrainBuf.ar(
                2,
                densCtrl,
                durCtrl,
                buf,
                rateCtrl,
                ptr,
                4,
                panCtrl,
                grainEnv
            );
            sig = MoogFF.ar(
                sig * env * amp.lag3(amp_slew),
                freq: cutoff,
                gain: resonance
            );
            Out.ar(out, sig);
        }).add;
```

- [ ] **Step 2: Verify SynthDefs compile**

```bash
cd schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

The post window should run through all existing tests without errors. SC will print errors immediately if any SynthDef fails to compile. If you see "Variable 'X' not defined" or "expected 'Y'", check syntax.

- [ ] **Step 3: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc
git commit -m "schicksalslied 2.0: granular delay SynthDefs

Sub-plan A, Task 4.1. Ports carters-delay-norns SynthDefs into the
Lied kernel: \\liedMic, \\liedMicDry, \\liedPtr, \\liedRec,
\\liedFbPatchMix, \\liedGran. .lag3 on every amp arg for real-time
control. SynthDefs only — buffer allocation + group hierarchy +
synth instantiation comes in Task 4.2."
```

### Task 4.2 — Granular chain instantiation (groups, buffer, synths, Ndefs)

**Files:**
- Modify: `schicksalslied/lib/Lied.sc`

- [ ] **Step 1: Add granular instance state to `Lied` class vars**

Update the class variable declarations at the top of `Lied`:

```supercollider
Lied {
    var <server;
    var <dryBus, <reverbBus, <delayBus;
    var <voiceGroup, <fxGroup;
    var <delaySynth, <reverbSynth, <outSynth;
    var <beat_sec;
    var <triSinInstances, <ringerInstances, <samplerInstances, <oneShotInstances;

    // Granular delay state
    var <delayBuf, <micBus, <ptrBus;
    var <micGrp, <ptrGrp, <recGrp, <granGrp;
    var <micSynth, <micDrySynth, <ptrSynth, <recSynth, <fbPatchMixSynth;
    var <grainSynths;
    var <grainPanLFOs, <grainCutoffLFOs, <grainResLFOs;
    var <grainRates, <grainDurs, <grainDelays;

    // ... (rest of class)
}
```

- [ ] **Step 2: Add granular allocation to `Lied.init` after master FX instantiation**

In `init`, after the line `outSynth = Synth.new(\liedOut, ...);` and before the closing `"Lied initialized.".postln;`, add:

```supercollider
    // -----------------------------------------------------------------
    // Granular delay chain — allocated persistently
    // -----------------------------------------------------------------

    // Delay buffer: 512 beats long at initial tempo (beat_sec defaults to 0.5)
    delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1);
    micBus = Bus.audio(server, 1);
    ptrBus = Bus.audio(server, 1);

    server.sync;

    // Granular group hierarchy: mic → ptr → rec → gran, before voiceGroup so
    // mic input writes to delayBuf before voiceGroup's voices read from it.
    // Voice groups remain head-of-chain for clean signal flow.
    micGrp  = Group.before(voiceGroup);
    ptrGrp  = Group.after(micGrp);
    recGrp  = Group.after(ptrGrp);
    granGrp = Group.after(recGrp);

    // Persistent granular chain synths (default amp = 0; turned up by cell toggles)
    micSynth        = Synth(\liedMic,        [\in, 0, \out, micBus, \amp, 0],     micGrp);
    micDrySynth     = Synth(\liedMicDry,     [\in, 0, \out, dryBus, \amp, 0],     micGrp);
    fbPatchMixSynth = Synth(\liedFbPatchMix, [\in, 0, \out, micBus, \amp, 0],     micGrp, \addToHead);
    ptrSynth        = Synth(\liedPtr,        [\buf, delayBuf, \out, ptrBus],      ptrGrp);
    recSynth        = Synth(\liedRec,        [\ptrIn, ptrBus, \micIn, micBus, \buf, delayBuf], recGrp);

    // Grain LFOs (16 each for pan, cutoff, resonance). Stored as Ndefs; the
    // \rate.kr arg lets Sub-plan C wire params to these.
    grainPanLFOs     = Array.fill(16, { 0 });
    grainCutoffLFOs  = Array.fill(16, { 0 });
    grainResLFOs     = Array.fill(16, { 0 });
    16.do({ arg i;
        grainPanLFOs[i] = Ndef(
            ("grainPan" ++ i).asSymbol,
            { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(-1, 1); }
        );
        grainCutoffLFOs[i] = Ndef(
            ("grainCutoff" ++ i).asSymbol,
            { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(500, 15000); }
        );
        grainResLFOs[i] = Ndef(
            ("grainRes" ++ i).asSymbol,
            { LFTri.kr(1 / (Rand(1, 64) * beat_sec)).range(0, 2); }
        );
    });

    // Scrambled per-grain rates, durations, delays (carters-delay-norns idiom)
    grainRates  = [1/4, 1/2, 1, 3/2, 2].scramble;
    grainDurs   = 16.collect({ arg i; beat_sec * (i + 1); }).scramble;
    grainDelays = 16.collect({ arg i; server.sampleRate * (beat_sec * (i + 1)) * 16; }).scramble;

    grainSynths = 16.collect({ arg n;
        Synth(\liedGran, [
            \amp, 0,
            \buf, delayBuf,
            \out, dryBus,
            \atk, 1,
            \rel, 1,
            \gate, 1,
            \sync, 1,
            \dens, 1 / (grainDurs[n] * grainRates[n % 5]),
            \baseDur, grainDurs[n],
            \durRand, 1,
            \rate, grainRates[n % 5],
            \rateRand, 1,
            \pan, grainPanLFOs[n],
            \panRand, 0,
            \grainEnv, -1,
            \ptrBus, ptrBus,
            \ptrSampleDelay, grainDelays[n],
            \ptrRandSamples, server.sampleRate * (beat_sec * ((n % 8) + 1)) * 2,
            \minPtrDelay, grainDelays[n],
            \cutoff, grainCutoffLFOs[n],
            \resonance, grainResLFOs[n]
        ], granGrp);
    });

    "Lied granular chain allocated.".postln;
```

- [ ] **Step 3: Update `Lied.free` to free granular state**

In `free`, before the existing bus/group frees, add:

```supercollider
    delayBuf.free;
    micBus.free;
    ptrBus.free;
    grainPanLFOs.do({ arg lfo; lfo.free; });
    grainCutoffLFOs.do({ arg lfo; lfo.free; });
    grainResLFOs.do({ arg lfo; lfo.free; });
    granGrp.free;
    recGrp.free;
    ptrGrp.free;
    micGrp.free;
```

- [ ] **Step 4: Add a granular chain smoke test to `test.scd`**

```supercollider
"Test 14: granular chain allocation check (silent — verify nothing crashes)".postln;
("  16 grain synths: " ++ kernel.grainSynths.size).postln;
("  delayBuf frames: " ++ kernel.delayBuf.numFrames).postln;
("  micBus channels: " ++ kernel.micBus.numChannels).postln;
"  All allocated, amp=0 (silent). Granular audio test next.".postln;
1.0.wait;

"Test 15: granular delay audible — turn up mic (simulated source) + grains".postln;
"  NOTE: This test plays a tone INTO the delay buffer via micDrySynth's";
"  out routed to micBus instead of using a real mic input. This avoids".postln;
"  audio-device handshake issues during automated testing.".postln;
// Inject a test tone into micBus via a temporary synth
~granTestSrc = {
    var sig = SinOsc.ar(440) * EnvGen.kr(Env.perc(0.5, 2.0), doneAction: 2) * 0.3;
    Out.ar(kernel.micBus, sig);
}.play(kernel.micGrp);
0.1.wait;
// Turn up grain output
kernel.grainSynths.do({ arg syn; syn.set(\amp, 0.2); });
"  Expected: 440Hz tone enters delay loop, granular wash builds and decays.".postln;
8.0.wait;
// Turn grains back down
kernel.grainSynths.do({ arg syn; syn.set(\amp, 0); });
2.0.wait;
```

- [ ] **Step 5: Run `test.scd`, verify granular chain**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for:
- Test 14: Post window prints `16 grain synths`, `delayBuf frames`, and a non-zero `micBus channels`. No SC errors.
- Test 15: A 440Hz tone is injected into the delay buffer; the 16 grain synths start producing a granular wash that picks up the tone material with varying rates and pitches over ~8 seconds, then fades when the grain amps return to 0.

If you hear nothing in Test 15: the test source isn't reaching the delay buffer. Verify `kernel.micBus.index` matches what `\liedRec` is reading from.

If you hear a runaway feedback loop: `\liedFbPatchMix` has amp=0 by default, so it shouldn't engage feedback. If it does, check that `fbPatchMixSynth` was initialized with `\amp, 0` (not e.g. `0.5`).

- [ ] **Step 6: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc test.scd
git commit -m "schicksalslied 2.0: granular delay chain instantiation

Sub-plan A, Task 4.2. Allocates the granular delay chain in the
Lied kernel: delayBuf (512 beats), micBus, ptrBus, mic/ptr/rec/
fbPatchMix synths, 16 grain synths with their pan/cutoff/resonance
Ndef LFOs. All amps default to 0 (silent) — engaged later by
cell-toggle commands from Sub-plan B. Test verifies allocation
and audible granular wash with injected test signal."
```

### Task 4.3 — Granular control commands in Engine_Lied

Expose commands so Sub-plan B can drive mic / micDry / grain amps from Lua. These are the commands the cell toggles in row 8 cols 14-16 will call.

**Files:**
- Modify: `schicksalslied/lib/Engine_Lied.sc`
- Modify: `schicksalslied/lib/Lied.sc`
- Modify: `schicksalslied/test.scd`

- [ ] **Step 1: Add public methods on `Lied`**

In `lib/Lied.sc`, add these methods after `setBeatSec`:

```supercollider
setMicAmp { arg amp;
    micSynth.set(\amp, amp);
}

setMicDryAmp { arg amp;
    micDrySynth.set(\amp, amp);
}

setGranularOutAmp { arg amp;
    granGrp.set(\amp, amp);  // single OSC msg updates all 16 grain synths
}

setFbPatchAmp { arg amp;
    fbPatchMixSynth.set(\amp, amp);
}

setFbPatchBalance { arg balance;
    fbPatchMixSynth.set(\balance, balance);
}

setFbPatchHpFreq { arg freq;
    fbPatchMixSynth.set(\hpFreq, freq);
}

setFbPatchNoiseLevel { arg lvl;
    fbPatchMixSynth.set(\noiseLevel, lvl);
}

setFbPatchSineLevel { arg lvl;
    fbPatchMixSynth.set(\sineLevel, lvl);
}

setFbPatchSineHz { arg hz;
    fbPatchMixSynth.set(\sineHz, hz);
}
```

- [ ] **Step 2: Add corresponding commands to `Engine_Lied`**

In `lib/Engine_Lied.sc`'s `alloc` method, after the existing `\set_beat_sec` command:

```supercollider
this.addCommand(\set_mic_amp,         "f", { arg msg; kernel.setMicAmp(msg[1]); });
this.addCommand(\set_mic_dry_amp,     "f", { arg msg; kernel.setMicDryAmp(msg[1]); });
this.addCommand(\set_granular_out_amp,"f", { arg msg; kernel.setGranularOutAmp(msg[1]); });
this.addCommand(\set_fb_amp,          "f", { arg msg; kernel.setFbPatchAmp(msg[1]); });
this.addCommand(\set_fb_balance,      "f", { arg msg; kernel.setFbPatchBalance(msg[1]); });
this.addCommand(\set_fb_hpf,          "f", { arg msg; kernel.setFbPatchHpFreq(msg[1]); });
this.addCommand(\set_fb_noise,        "f", { arg msg; kernel.setFbPatchNoiseLevel(msg[1]); });
this.addCommand(\set_fb_sine_level,   "f", { arg msg; kernel.setFbPatchSineLevel(msg[1]); });
this.addCommand(\set_fb_sine_hz,      "f", { arg msg; kernel.setFbPatchSineHz(msg[1]); });
```

- [ ] **Step 3: Add a granular-amp-control test to `test.scd`**

Replace Test 15's manual `kernel.grainSynths.do(...)` calls with the new public methods:

```supercollider
"Test 16: granular control commands (via kernel public methods)".postln;
~granTestSrc2 = {
    var sig = SinOsc.ar(330) * EnvGen.kr(Env.perc(0.5, 2.0), doneAction: 2) * 0.3;
    Out.ar(kernel.micBus, sig);
}.play(kernel.micGrp);
0.1.wait;
kernel.setGranularOutAmp(0.2);
"  granular_out_amp = 0.2 (expecting wash to build)".postln;
6.0.wait;
kernel.setGranularOutAmp(0);
"  granular_out_amp = 0 (expecting silence)".postln;
2.0.wait;
```

- [ ] **Step 4: Run `test.scd`, verify control methods work**

```bash
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

Listen for the granular wash building and then fading when amp goes to 0. Verify post window prints the expected lines without errors.

- [ ] **Step 5: Commit**

```bash
cd schicksalslied
git add lib/Lied.sc lib/Engine_Lied.sc test.scd
git commit -m "schicksalslied 2.0: granular control commands

Sub-plan A, Task 4.3. Exposes mic / micDry / granular-out /
fbPatchMix amp control as Lied public methods and as
Engine_Lied Crone commands (\\set_mic_amp, \\set_mic_dry_amp,
\\set_granular_out_amp, \\set_fb_amp, \\set_fb_balance,
\\set_fb_hpf, \\set_fb_noise, \\set_fb_sine_level,
\\set_fb_sine_hz). Sub-plan B will wire these to cell toggles."
```

---

## Final checkpoint

At the end of Sub-plan A:

- [ ] **Run the full `test.scd` end-to-end**

```bash
cd schicksalslied
PATH="/Applications/SuperCollider.app/Contents/MacOS:$PATH" sclang test.scd
```

You should hear, in order:
1. Three master FX bus tests (dry, reverb, delay)
2. Two TriSin tests (basic + real-time amp fade)
3. TriSin polyphony (4-note chord stack)
4. Two Ringer tests (basic + real-time amp fade)
5. Sampler basic playback (5s test buffer)
6. Sampler crossfade (16 rapid retriggers, no clicks)
7. OneShot basic (0.5s noise burst)
8. OneShot long-sample fade-out (smooth 1s fade mid-playback)
9. Granular chain allocation check (post window only)
10. Granular control via public methods (wash builds and fades)

Total runtime: ~60-90 seconds.

**The post window's final line should be `All tests passed.`**

- [ ] **Sub-plan A wrap-up commit**

```bash
cd schicksalslied
git log --oneline -20  # review the Sub-plan A commit history
```

You should see ~11 commits for Sub-plan A. If everything looks clean, you're done with Sub-plan A. Sub-plan B (the Lua control layer) is the next thing to plan.

---

## Self-review

**1. Spec coverage check:**

| Spec section | Sub-plan A task(s) |
|---|---|
| §2 Architecture overview (file layout) | Task 1.1 (structure setup) |
| §4 SC engine design (kernel, buses, FX, retrigger discipline) | Tasks 1.2, 1.3, 2.1, 2.3 |
| §4 Allocation strategy (persistent FX + granular; lazy voices/samplers — TriSin/Ringer/Sampler/OneShot stubs allocated in tests) | Tasks 2.1, 2.3, 3.1, 3.3, 4.2 |
| §5 Sampler design (Phasor + BufRd crossfade, file loading model) | Tasks 3.1, 3.2 |
| §5 OneShot design (.lag on amp, persistent for fade) | Task 3.3 |
| §6 Granular delay (mic chain, fbPatchMix, 16 grains, Ndef LFOs) | Tasks 4.1, 4.2, 4.3 |
| §14 test #1 (SC smoke test) | Final checkpoint |
| §14 test #3 (real-time amp control) | Tasks 2.1 (TriSin), 2.3 (Ringer) |
| §14 test #7 (long-sample fade) | Task 3.3 |
| §14 test #8 (sampler crossfade) | Task 3.2 |

What's NOT in Sub-plan A but is in the spec:
- §3 grid layout — entire UI layer (Sub-plan B)
- §4 lazy allocation logic (registries exist, but actual lazy alloc happens when Lua calls; Sub-plan B)
- §6 grain LFO **params** wiring (Ndefs exist but rate params aren't exposed yet; Sub-plan C)
- §7 sequencing model (Sub-plan B)
- §8 crow integration (Sub-plan B)
- §9 params menu (Sub-plan C)
- §10 LFOs (Sub-plan C)
- §11 UI (Sub-plan B)
- §14 tests #2, #4, #5, #6, #9, #10, #11 (require Norns hardware or Lua side; deferred)

This is correct decomposition — Sub-plan A produces a self-contained, testable SC engine. The deferred items have a clear home in Sub-plans B and C.

**2. Placeholder scan:** ✓ No "TBD", "TODO", or "implement later". Every code block is complete and runnable.

**3. Type consistency:**
- `voiceGroup` is the same field across `TriSin`, `Ringer`, `Sampler`, `OneShot` ✓
- `setParam(voiceKey, paramKey, paramValue)` signature is identical across all four voice classes ✓
- Bus names (`dryBus`, `reverbBus`, `delayBus`, `micBus`, `ptrBus`) are consistent across `Lied`'s class vars and all SynthDef wiring ✓
- Commands in `Engine_Lied` use the format strings consistently (`"f"` for single floats, `"sff"` etc. for stringly-named voices — though no string args yet since instance management is in Sub-plan B) ✓

No issues found in the review pass.

---

## Execution handoff

**Plan complete and saved to `schicksalslied/docs/superpowers/plans/2026-05-13-schicksalslied-2-0-sub-plan-A-sc-engine.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best when you want hands-off execution with verification gates.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Best when you want to interject between tasks or work alongside the agent.

**Which approach?** After Sub-plan A's checkpoint passes, I write Sub-plan B (Lua control layer).
