# Chapter 04 — `lib/Engine_Lied.sc`

The Crone wrapper that exposes the `Lied` kernel to Norns. **140 lines of source, almost entirely `addCommand` registrations.**

## What you'll learn

By the end of this chapter the SC engine is fully command-driven from outside: the Lua side can allocate voices, trigger them, load samples, control granular parameters, and shut down the engine, all via OSC messages routed through Crone. The chapter is small because the file is small and almost every line follows the same pattern — we establish the pattern once and then catalog the full command surface.

## Prerequisites within the tutorial

- Chapters 01-03. You especially need chapter 03's understanding of the `Lied` kernel — Engine_Lied is a thin wrapper that just exposes the kernel's methods to OSC.

## Why this file exists

When a Norns script declares `engine.name = 'Lied'`, Norns looks up the class `Engine_Lied` and instantiates it. The class must extend `CroneEngine` (Norns's base class for user engines). `CroneEngine` provides the OSC plumbing — registering OSC handlers under `/<command>` and routing them to your command callbacks — so you don't have to write any OSC code yourself.

Your engine class has one job: in its `alloc` method, register every command you want to expose, then keep references to the underlying kernel for them to dispatch to.

`★ Insight ─────────────────────────────────────`
**The CroneEngine layer is what makes Norns engines composable across scripts.** Any Norns script can load any engine. The Lua-side `engine.<name>(...)` call is converted to an OSC message; Crone routes the message based on the registered command name and type-spec. As long as your engine class is on the SC class path and registers a sensible command surface, Lua scripts can use it.

**The engine class file naming convention is critical.** `Engine_<Name>.sc` is auto-discovered by Crone when `engine.name = '<Name>'` is set. The class declared in the file must be named `Engine_<Name>` and extend `CroneEngine`. Get any of this wrong (file misnamed, class name mismatched, parent class incorrect) and Norns won't be able to load the engine, producing `### SCRIPT ERROR: engine.name lookup failed`.
`─────────────────────────────────────────────────`

Why a thin wrapper instead of putting everything in `Lied.sc`? **Separation of concerns:**

- The kernel (`Lied.sc`) has no idea how it's being called. It exposes a method API. You can use it from sclang's REPL, from a test script, from another SC project, etc.
- The Crone wrapper (`Engine_Lied.sc`) knows about OSC commands. It's specific to the Norns context.

Keeping them separate means the kernel is reusable. The `Lied` class could in principle drive a non-Norns SC project (a desktop standalone, a different framework) — you'd just write a different wrapper for that context. The wrapper is the only file that's Norns-specific.

## Source sections

1. Class declaration + ivars (lines 1-6)
2. Constructor (lines 7-9)
3. `alloc` start + kernel construction (lines 11-12)
4. Master FX commands (lines 14-26)
5. Granular chain commands (lines 27-44)
6. TriSin voice commands (lines 50-65)
7. Ringer voice commands (lines 66-81)
8. Sampler commands (lines 86-102)
9. OneShot commands (lines 107-123)
10. Bulk panic commands (lines 124-132)
11. `free` (lines 137-139)

## 1. Class declaration and ivars

Open `lib/Engine_Lied.sc`:

```supercollider
// lib/Engine_Lied.sc — schicksalslied 2.0 Crone wrapper (skeleton)
// The full command surface lands in Sub-plan B. This skeleton just instantiates
// the Lied kernel so Norns will recognize the engine when loaded.
Engine_Lied : CroneEngine {
    var <kernel;  // public getter for REPL diagnostics
```

**Lines 1-5**: header comments + class declaration. The class **extends `CroneEngine`** — this is what makes it a Norns engine. Without that inheritance, Norns wouldn't recognize the class as an engine when the Lua side declares `engine.name = 'Lied'`.

The comment about "Sub-plan B" is a development-history artifact — the class was built incrementally; this file got most of its content in Sub-plan B. Leaving the comment in place preserves the development context for future readers.

`var <kernel` holds the `Lied` instance. The `<` makes it publicly readable from outside — invaluable during development for inspecting kernel state via `Crone.engine.kernel.<anything>` in the sclang REPL.

`★ Insight ─────────────────────────────────────`
**The file-naming convention is a Crone contract**: when Norns sees `engine.name = 'Lied'`, it looks for a class named `Engine_Lied` in a file at the script's path (`lib/Engine_Lied.sc`). Both pieces must align: the file's name, the class declaration inside, and the Lua-side `engine.name`. Any mismatch produces a `### SCRIPT ERROR: engine.name lookup failed` at load.

**Why a public getter on `kernel`?** During development we several times needed to inspect engine state directly via `Crone.engine.kernel.bufferCache.keys` or `Crone.engine.kernel.triSinInstances.keys.postln;`. These diagnostics are only possible with the `<` accessor. There's no runtime cost; always include the `<` on engine state you'd want to see.
`─────────────────────────────────────────────────`

## 2. Constructor

```supercollider
    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }
```

**Lines 7-9**: the boilerplate constructor. CroneEngine's `new` takes a `context` (which holds the server reference) and a `doneCallback` (called when alloc finishes). We just pass them through with `^super.new(...)`. No initialization happens here — that's `alloc`'s job.

This is intentional. Doing setup in `*new` could run before Crone has wired up the context object, producing nil-object errors. The convention is: do nothing in `*new` beyond pass-through; do everything in `alloc`.

## 3. `alloc` start + kernel construction

```supercollider
    alloc {
        kernel = Lied.new(context.server);
```

**Lines 11-12**: instantiate the kernel. `context.server` is the SC server reference (Crone provides this in `context`). We pass it to `Lied.new`. The kernel begins its async init (it forks to set up buses, groups, SynthDefs, master FX synths — see [chapter 03](03-Lied.sc.md)).

This call returns immediately because `Lied.init` forks the heavy work. By the time `alloc` finishes registering commands below, the kernel may still be finishing its init — but commands sent before the kernel is fully alive will mostly be no-ops or cached (the kernel's setter methods handle pre-alloc setters).

## Registering commands

Inside `alloc`, after the kernel is constructed, you register commands one at a time:

```supercollider
this.addCommand(\set_delay_amp, "f", { arg msg;
    kernel.setDelayAmp(msg[1]);
});
```

The signature is `this.addCommand(commandName, typeSpec, handlerBlock)`:

- **`\set_delay_amp`** — the command name (symbol). This is what the Lua side calls: `engine.set_delay_amp(0.5)` sends an OSC message to `/set_delay_amp`.
- **`"f"`** — the OSC type spec string. Each character describes one argument: `f` = float, `i` = integer, `s` = symbol (string). Order matters: the spec must match the args the Lua side will pass.
- **`{ arg msg; ... }`** — the handler block. `msg` is an array containing the OSC message contents. `msg[0]` is the command name itself (so `msg[0] == \set_delay_amp` in this handler); `msg[1]` is the first argument after the command name, `msg[2]` is the second, etc.

When the Lua side calls `engine.set_delay_amp(0.5)`, this handler runs with `msg = [\set_delay_amp, 0.5]`. It extracts `msg[1]` (the 0.5) and forwards to the kernel.

### Multi-argument commands

For commands with multiple args, the type spec strings concatenate:

```supercollider
this.addCommand(\trisin_trigger, "sif", { arg msg;
    var cellId = msg[1].asSymbol;
    var voiceKey = msg[2].asInteger.asString.asSymbol;
    var freq = msg[3];
    kernel.triggerTriSin(cellId, voiceKey, freq);
});
```

`"sif"` means three args: first a string, second an integer, third a float. The Lua side calls `engine.trisin_trigger("1_2", 3, 440.0)` and the handler runs with:

- `msg[1] = "1_2"` (the cell ID string)
- `msg[2] = 3` (the voice key as an integer)
- `msg[3] = 440.0` (the freq)

The handler converts each as needed before passing to the kernel. Note `msg[2].asInteger.asString.asSymbol` — this transforms `3` to `\3` (the symbol). The voice classes' `voiceKeys` array uses symbol keys (`[\1, \2, \3, ...]`), so we need to convert the integer to a symbol for lookup.

`★ Insight ─────────────────────────────────────`
**Why is voice_key represented as a symbol on SC's side but as an integer on Lua's side?** The Lua side keeps voice keys as integers for arithmetic — round-robin counters use modular increment. The SC side keeps them as symbols for Dictionary lookup — symbols are fast to hash and compare. The conversion happens at the boundary (in the engine command handler). This is a typical pattern when bridging two languages with different idiomatic representations: pick whatever's convenient on each side, convert at the seam.

**`msg[2].asInteger.asString.asSymbol`** is doing the conversion in three steps because `msg[2]` arrives as a float (OSC defaults `i` to numeric, but the runtime sometimes hands it back as a float depending on how Lua serialized it). `.asInteger` forces it to int, `.asString` makes it a string like "3", `.asSymbol` interns the string as a symbol `\3`. Belt-and-suspenders, but cheap.
`─────────────────────────────────────────────────`

### The OSC type-spec characters

The full Crone-supported set:

| Char | Type | Lua-side value type | SC-side value type |
|---|---|---|---|
| `i` | integer | number (converted to int) | Integer |
| `f` | float | number | Float |
| `s` | string/symbol | string | String (use `.asSymbol` to convert) |
| `b` | blob (rarely used) | byte string | Int8Array |

You'll mostly use `s`, `i`, and `f`. The script uses `"is"` (integer + string) for load commands, `"sif"` for trigger commands with cell IDs, `"isf"` for sampler/oneshot per-param sets (slot + key + value), and so on. Each unique type spec corresponds to a distinct call signature on the Lua side.

### Commands with no arguments

For commands that take no args, the type spec is the empty string `""`:

```supercollider
this.addCommand(\silence_all_samplers, "", { arg msg;
    kernel.silenceAllSamplers;
});
```

Lua side: `engine.silence_all_samplers()`. The handler runs with `msg = [\silence_all_samplers]` — `msg[1]` is nil because there are no args.

## Naming conventions

Look at the command names this engine registers vs. the kernel methods they invoke:

| OSC command name | Kernel method |
|---|---|
| `\set_delay_amp` | `setDelayAmp` |
| `\trisin_trigger` | `triggerTriSin` |
| `\sampler_load` | `loadSampler` |
| `\set_grain_pan_rate` | `setGrainPanRate` |
| `\silence_all_samplers` | `silenceAllSamplers` |
| `\free_granular` | `freeGranularChain` |

Patterns:

- **OSC command names are `snake_case`** (Lua convention).
- **SC method names are `camelCase`** (SuperCollider convention).
- **The engine wrapper translates between them** by hand-converting in each handler.

This is a deliberate convention: each side uses its own language's idioms internally, and the bridge does the translation. There's no automatic name conversion — every `addCommand` lists both names explicitly. This is verbose but unambiguous.

`★ Insight ─────────────────────────────────────`
**The convention also reverses verb/noun order**: Lua's `engine.set_delay_amp(0.5)` reads as "set the delay amp"; SC's `kernel.setDelayAmp(0.5)` reads the same. But Lua's `engine.trisin_trigger(...)` is "trisin trigger" (noun then verb); SC's `kernel.triggerTriSin(...)` reverses to "trigger TriSin". The convention isn't perfectly consistent — `trisin_trigger` is `triggerTriSin` but `sampler_load` is `loadSampler`. The pattern in practice is: the engine command name leads with the **subsystem** (trisin, ringer, sampler, oneshot, delay, reverb, etc.), and the kernel method leads with the **verb**. This makes it easy to grep for "what commands does the script send to a given subsystem?"

**Don't fight this when adding new commands.** When you add a new feature, register it with `\<subsystem>_<verb>` as the command name and `<verb><Subsystem>` as the kernel method. Future-you (and code reviewers) will thank you.
`─────────────────────────────────────────────────`

## 4. Master FX commands

```supercollider
        // --- Master out + clock ---
        this.addCommand(\set_beat_sec, "f", { arg msg; kernel.setBeatSec(msg[1]); });
        this.addCommand(\set_out_amp,  "f", { arg msg; kernel.setOutAmp(msg[1]); });

        // --- Master FX ---
        this.addCommand(\set_delay_time,  "f", { arg msg; kernel.setDelayTime(msg[1]); });
        this.addCommand(\set_delay_decay, "f", { arg msg; kernel.setDelayDecay(msg[1]); });
        this.addCommand(\set_delay_amp,   "f", { arg msg; kernel.setDelayAmp(msg[1]); });
        this.addCommand(\set_delay_to_reverb_send, "f", { arg msg; kernel.setDelayToReverbSend(msg[1]); });
        this.addCommand(\set_delay_to_dry_send,    "f", { arg msg; kernel.setDelayToDrySend(msg[1]); });
        this.addCommand(\set_reverb_room, "f", { arg msg; kernel.setReverbRoom(msg[1]); });
        this.addCommand(\set_reverb_damp, "f", { arg msg; kernel.setReverbDamp(msg[1]); });
        this.addCommand(\set_reverb_amp,  "f", { arg msg; kernel.setReverbAmp(msg[1]); });
```

**Lines 14-26**: 11 master-FX setters. All take a single float and dispatch to the corresponding kernel method. The pattern:

```supercollider
this.addCommand(\<lua_command>, "f", { arg msg; kernel.<KernelMethod>(msg[1]); });
```

Three things vary across these calls:
- **The `\command_name` symbol** — what the Lua side sends as the OSC address.
- **The kernel method name** — typically `<command_name>` rewritten as camelCase (e.g., `\set_delay_time` → `setDelayTime`).
- **`msg[1]`** — the single float argument that came in.

`this.addCommand` registers the handler with Crone. Subsequent OSC messages to `/<command_name>` will fire this block.

`★ Insight ─────────────────────────────────────`
**One-line addCommand blocks vs multi-line**: The first command (`\set_beat_sec`) is on three lines for legibility; the rest are crammed into one line each. The convention in this file: one-line for trivial pass-throughs (just `kernel.<method>(msg[1])`); multi-line when the handler does anything more than dispatch. The first call was written multi-line as a template; subsequent ones use the one-line form once the pattern is established.
`─────────────────────────────────────────────────`

## 5. Granular chain commands

```supercollider
        // --- Granular chain ---
        this.addCommand(\set_mic_amp,          "f", { arg msg; kernel.setMicAmp(msg[1]); });
        this.addCommand(\set_mic_dry_amp,      "f", { arg msg; kernel.setMicDryAmp(msg[1]); });
        this.addCommand(\set_granular_out_amp, "f", { arg msg; kernel.setGranularOutAmp(msg[1]); });
        this.addCommand(\set_grain_delay_scale,"f", { arg msg; kernel.setGrainDelayScale(msg[1]); });
        this.addCommand(\set_fb_amp,           "f", { arg msg; kernel.setFbPatchAmp(msg[1]); });
        this.addCommand(\set_fb_balance,       "f", { arg msg; kernel.setFbPatchBalance(msg[1]); });
        this.addCommand(\set_fb_hpf,           "f", { arg msg; kernel.setFbPatchHpFreq(msg[1]); });
        this.addCommand(\set_fb_noise,         "f", { arg msg; kernel.setFbPatchNoiseLevel(msg[1]); });
        this.addCommand(\set_fb_sine_level,    "f", { arg msg; kernel.setFbPatchSineLevel(msg[1]); });
        this.addCommand(\set_fb_sine_hz,       "f", { arg msg; kernel.setFbPatchSineHz(msg[1]); });
        this.addCommand(\free_granular,        "",  { arg msg; kernel.freeGranularChain; });

        this.addCommand(\set_grain_pan_rate,    "if", { arg msg; kernel.setGrainPanRate(msg[1].asInteger, msg[2]); });
        this.addCommand(\set_grain_cutoff_rate, "if", { arg msg; kernel.setGrainCutoffRate(msg[1].asInteger, msg[2]); });
        this.addCommand(\set_grain_res_rate,    "if", { arg msg; kernel.setGrainResRate(msg[1].asInteger, msg[2]); });
```

**Lines 27-44**: nine granular-chain setters + one no-arg `free_granular` + three per-grain modulation rate setters.

Most granular commands are single floats. The `\set_fb_*` commands target the feedback patch synth.

The grain pan/cutoff/res rate setters take **two args**: an int (grain index, 0-3) and a float (the rate). The type spec is `"if"`. `msg[1].asInteger` defensively converts to int (Lua may send what looks like an integer as a float through OSC; `.asInteger` normalizes). `msg[2]` is the float, no conversion needed.

`free_granular` takes no args and tears down the entire granular chain. Called from the Lua side via the K1 panic flow or when the user explicitly mutes the chain.

## 6. TriSin voice commands

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
```

**Lines 50-65**: four TriSin lifecycle commands.

- **`\trisin_alloc` and `\trisin_free`**: take a string (cellId). `msg[1].asSymbol` converts the OSC string to a symbol for use as a Dictionary key in the kernel. Symbols are faster to look up than strings.

- **`\trisin_trigger`**: takes string + int + float. The voice-key conversion `msg[2].asInteger.asString.asSymbol` is the three-step idiom explained above — Lua sends an integer; we convert to int first (defensive), then to string ("3"), then to symbol (`\3`). The voice classes use symbol keys like `\1`, `\2`, ..., `\8` to index their `singleVoices` dictionary.

- **`\trisin_set_param`**: takes two strings + a float. Cell ID and param key both convert to symbols; param value passes through.

`★ Insight ─────────────────────────────────────`
**The voice-key conversion is the most subtle line in this file.** `msg[2].asInteger.asString.asSymbol` reads strangely but does specific work:
1. `.asInteger` — forces to int (defensive against OSC `i` being deserialized as float).
2. `.asString` — converts int 3 to the string `"3"`.
3. `.asSymbol` — interns the string `"3"` as the symbol `\3`.

If you tried `msg[2].asSymbol` directly on a float, you'd get `\3.0` (not `\3`), which wouldn't match the voice class's `voiceKeys = [\1, \2, ..., \8]`. The roundabout conversion ensures symbol equality.

**Why use symbols for voice keys at all?** Because Lua's integer voice keys (from `next_voice_key`'s round-robin counter) wouldn't directly index a SC Dictionary that uses symbols. The conversion is the seam between Lua's representation (integer) and SC's representation (symbol).
`─────────────────────────────────────────────────`

## 7. Ringer voice commands

```supercollider
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
```

**Lines 66-81**: four Ringer lifecycle commands. Identical structure to TriSin's, just different command names and kernel methods.

The duplication is intentional. Abstracting it (e.g., a helper that generates pairs of `<role>_alloc` / `<role>_free` commands) would obscure the structure. Each role's commands stand on their own.

## 8. Sampler commands

```supercollider
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
```

**Lines 86-102**: four sampler commands.

- **`\sampler_load`**: int slot + string file path. `msg[2].asString` is the path — actually no conversion needed (it's already a string), but `.asString` is defensive in case OSC delivered a different type.
- **`\sampler_clear`**: just the int slot.
- **`\sampler_trigger`**: five args: slot, voice key, start, end, rate. Note the type spec `"iifff"` — 2 ints + 3 floats.
- **`\sampler_set_param`**: slot int + param key string + value float.

`msg[1].asInteger` converts the slot to int. Compare to TriSin's `msg[1].asSymbol` for cell ID — samplers identify by integer slot, voices identify by string cell ID. Different code paths, different conversions.

## 9. OneShot commands

```supercollider
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

**Lines 107-123**: four one-shot commands. Same shape as sampler but with `\oneshot_trigger` taking only 3 args (`"iif"`) — slot, voice key, rate. No start/end because OneShot plays the whole buffer.

## 10. Bulk panic commands

```supercollider
        this.addCommand(\silence_all_samplers, "", { arg msg;
            kernel.silenceAllSamplers;
        });
        this.addCommand(\silence_all_oneshots, "", { arg msg;
            kernel.silenceAllOneShots;
        });

        "Engine_Lied alloc complete.".postln;
    }
```

**Lines 124-134**: two no-arg commands (type spec `""`).

- **`\silence_all_samplers`** — calls `kernel.silenceAllSamplers` (which iterates the instance dict and calls `resetVoices` on each).
- **`\silence_all_oneshots`** — same for one-shots.

The handler body is just `kernel.<method>` — no `(...)` because SC's method-call syntax doesn't require parens for zero-arg calls.

The final `.postln` is the signal that the engine is fully alive. After this message appears in the matron log, the Lua side can start sending commands with confidence.

## 11. `free`

```supercollider
    free {
        kernel.free;
    }
}
```

**Lines 137-140**: when Norns unloads the engine (script changes, Norns shuts down, etc.), `free` is called. Forward to `kernel.free`, which tears down everything in `Lied.sc` ([chapter 03](03-Lied.sc.md) section 18). The Crone wrapper itself has no state to free beyond the kernel reference.

## What happens when the Lua side calls an engine command

Worth walking through end-to-end so the picture is clear. Consider `engine.trisin_trigger("1_2", 3, 440.0)` from Lua:

1. **Lua side.** The script calls `engine.trisin_trigger(...)`. Norns's Lua engine module serializes this into an OSC message: address `/trisin_trigger`, args `["1_2", 3, 440.0]`.
2. **OSC transport.** The message is sent over local UDP (typically loopback) to scsynth, which forwards it to sclang via Crone's relay.
3. **Crone dispatch.** sclang's Crone instance receives the message, looks up the registered handler for `\trisin_trigger`, and invokes the handler block with `msg = [\trisin_trigger, "1_2", 3, 440.0]`.
4. **Handler.** The handler converts arguments and calls `kernel.triggerTriSin(\1_2, \3, 440.0)`.
5. **Kernel.** `triggerTriSin` looks up `triSinInstances[\1_2]`, finds the alive `TriSin` instance, and calls `inst.trigger(\3, 440.0)`.
6. **Voice class.** `TriSin.trigger` dispatches to `playVoice` for the specific voice key, which either retriggers the existing synth or allocates a new one.
7. **SC server.** The synth in question receives a `/n_set` (or `/s_new`) message and updates its state. Next audio block: sound.

This is steps 6-9 of the sound-journey trace from chapter 01. The chain is fully unidirectional from Lua to SC for triggering; there's no callback from SC back to Lua.

## Why the wrapper is so thin

The kernel-vs-wrapper split is the "boundary object" pattern. The kernel is the domain logic; the wrapper is the framework adapter.

A heuristic for keeping wrappers thin: if a handler is more than 2 lines (extracting args + dispatching), move the logic into a kernel method and call that method from the handler. Handler complexity is a smell — it usually means you've snuck logic into the wrapper that belongs in the kernel.

## Adding new commands

If you want to expose a new capability from the kernel to the Lua side:

1. **Add the kernel method.** E.g., add `setNewThing { arg val; ... }` to `Lied.sc`.
2. **Recompile SC class library** (or reboot Norns) to pick up the new method.
3. **Add the addCommand block** to `Engine_Lied.sc`:

```supercollider
this.addCommand(\set_new_thing, "f", { arg msg;
    kernel.setNewThing(msg[1]);
});
```

4. **Recompile/reboot again.**
5. **Add the Lua side** that calls `engine.set_new_thing(value)`.

Each side has to know about the new command. There's no automatic discovery. The fact that you must update both `Engine_Lied.sc` and the Lua side in lockstep is by design — it forces you to think about the OSC type-spec and the conversion at the boundary, which catches a lot of "I forgot the cellId is supposed to be a symbol" bugs at the point you'd write them.

## Checkpoint

After saving `lib/Engine_Lied.sc`, your full SC engine is ready to be loaded by Norns. To verify before deploying to Norns:

In SC IDE, recompile (`Cmd-Shift-L`). The `Engine_Lied` class should now be available.

You can't fully test the engine in SC IDE alone (the Crone integration requires Norns). But you can instantiate the kernel directly and verify all the underlying methods work:

```supercollider
~lied = Lied.new(s);
// Wait for "Lied init complete."

~lied.allocTriSin(\test);
~lied.triggerTriSin(\test, \1, 440);
~lied.setTriSinParam(\test, \amp, 0.3);
~lied.freeTriSin(\test);

~lied.allocRinger(\testRing);
~lied.triggerRinger(\testRing, \1, 220);
~lied.freeRinger(\testRing);

~lied.free;
```

If the kernel methods all work correctly from sclang, the Crone wrapper just translates OSC messages into the same method calls — there's no way for the wrapper to break things the kernel can already do.

Final verification happens at the start of [chapter 20](20-deployment-debugging.md) (deployment). For now, you can deploy the SC side to Norns and run any Lua script that loads engine `Lied`. If you see `Engine_Lied alloc complete.` in the Norns matron log, the engine is registered and reachable.

## Summary

`Engine_Lied.sc` is the most repetitive file in the project. About 50 `addCommand` registrations, all following a small set of patterns. The patterns to internalize:

1. **One-arg float**: `"f"`, dispatch to `kernel.<method>(msg[1])`.
2. **Multi-arg with type conversions**: extract each arg via `msg[N]`, convert as needed (`.asSymbol`, `.asInteger`, `.asString`), dispatch.
3. **Voice key conversion**: `msg[N].asInteger.asString.asSymbol` is the canonical seam.
4. **No-arg**: `""` type spec, body just calls the kernel method.

Adding a new command means adding one block here + adding the kernel method in `Lied.sc` + adding the Lua side that calls `engine.<command>(...)`. The three sides must agree on names and types. There's no automatic discovery — the explicit registration is the contract.

## What's next

**Chapter 05 — TriSin.sc** pivots to the voice classes. The four voice classes (TriSin, Ringer, Sampler, OneShot) share a common voice-pool pattern; chapter 05 establishes the pattern in detail using TriSin as the canonical example, then chapters 06-08 specialize the pattern for the other three.
