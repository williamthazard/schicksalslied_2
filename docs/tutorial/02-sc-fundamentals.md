# Chapter 02 — SuperCollider Fundamentals

## What you'll learn

The SuperCollider concepts that the rest of this tutorial assumes you understand: `SynthDef` structure, audio and control buses, groups (and why execution order within a group matters), buffers, and the distinction between SC's two distinct memory pools — the real-time pool that UGens like `CombL` allocate from, and the server-side heap where buffers live. We'll also cover three specific SC idioms this script leans on heavily: `lag`/`lag3` smoothing, the `fork` + `server.sync` async pattern, and the `Dictionary` + `getPairs` argument splicing pattern.

Every concept comes with a runnable code block you can evaluate in SuperCollider IDE on your workstation. No Norns required for this chapter.

## Prerequisites within the tutorial

- Chapter 01 (you understand the three-tier architecture and have SC IDE installed).

## What this chapter is not

A full SuperCollider primer. SC is a deep language; there are book-length introductions. This chapter touches only the SC concepts schicksalslied 2.0 actually uses, with examples drawn from the kinds of code you'll be writing in chapters 03 and 04. If you want a broader SC introduction, [the Tour of UGens](https://doc.sccode.org/Guides/Tour_of_UGens.html) and the [Getting Started](https://doc.sccode.org/Tutorials/Getting-Started/00-Getting-Started-With-SC.html) guide in SC's built-in help are excellent.

## Setting up SC IDE for the examples

Open SuperCollider IDE. You'll see three panes: an editor on the left, the **Post Window** on the right (where output appears), and the **Help Browser** (which you can open with `Cmd-D` / `Ctrl-D` on any word).

Boot the server before evaluating any of the examples in this chapter:

```supercollider
s.boot;
```

Place the cursor on that line and press `Cmd-Enter` (Mac) or `Ctrl-Enter` (Win/Linux) to evaluate it. After a moment, the Post Window will print something like `SuperCollider 3 server ready.` Now you can run the examples.

To **stop all sound** at any time: press `Cmd-.` (Mac) or `Ctrl-.` (Win/Linux). This frees every running synth on the server. Use it often.

`★ Insight ─────────────────────────────────────`
**`s.boot` starts the audio server (`scsynth`) as a separate process from `sclang` (the interpreter you're running code in).** This is the same separation Norns uses, just with you driving sclang from the IDE instead of Crone driving it. Every example below sends OSC messages from sclang to scsynth; you can watch the messages with `s.dumpOSC(1);` if you ever want to see the protocol in motion. Turn dumping off with `s.dumpOSC(0);`.

**`Cmd-.` (stop everything)** is the SC equivalent of an emergency mute. It sends `/g_freeAll 0` to the root group, freeing every synth and group below it. Audio drops to silence; the server is still running and ready for new synths. Memorize this shortcut.
`─────────────────────────────────────────────────`

## 1. The minimal SynthDef

A `SynthDef` is a description of a digital signal processing graph. You define one, send it to the server, and then instantiate it (one or more times) as `Synth` instances that actually produce sound.

Here is the smallest useful SynthDef:

```supercollider
(
SynthDef(\beep, {
    arg freq = 440, amp = 0.1;
    var sig = SinOsc.ar(freq) * amp;
    Out.ar(0, sig ! 2);
}).add;
)
```

Evaluate it (place cursor inside the parenthesized block and Cmd-Enter — the parens let you select the whole block as a single expression). The server now has a `\beep` SynthDef registered. Play one:

```supercollider
x = Synth(\beep, [\freq, 220, \amp, 0.2]);
```

You should hear a 220 Hz sine wave. Stop it:

```supercollider
x.free;
```

(Or use `Cmd-.` to stop all synths.)

### Anatomy of the SynthDef

```supercollider
SynthDef(\beep, {            // ↖ name (symbol) + a function (the synth graph)
    arg freq = 440, amp = 0.1;  // ↖ named args with defaults
    var sig = SinOsc.ar(freq) * amp;  // ↖ var declarations + the graph body
    Out.ar(0, sig ! 2);      // ↖ Out.ar(bus_index, signal)
}).add;                      // ↖ send to server's SynthDef library
```

Reading top to bottom:

- `SynthDef(\name, function)` constructs the SynthDef object.
- The function takes named arguments. When you `Synth.new(\beep, [\freq, 220])`, the `220` is routed to the `freq` argument. Args with no value passed use their default.
- `var ... = ...;` declares local variables. SC requires all `var` declarations to appear at the top of the function, before any other statement.
- `SinOsc.ar(freq)` is a UGen (unit generator). The `.ar` suffix means audio rate (one sample per audio frame). There's also `.kr` (control rate, lower resolution and cheaper) and `.ir` (initialization rate, computed once at instantiation).
- `* amp` multiplies the oscillator output by the amp argument. UGens are values you can do arithmetic on.
- `Out.ar(0, sig ! 2)` writes the signal to audio bus 0 (the main left output on most systems). The `! 2` syntax duplicates the mono signal to a 2-element array (stereo). `Out.ar` interprets a multi-channel array by writing to consecutive bus indices, so this writes to bus 0 (left) and bus 1 (right).
- `.add` registers the SynthDef with the server. Without `.add`, the SynthDef exists only in sclang's memory.

`★ Insight ─────────────────────────────────────`
**SC's `arg` and `var` ordering is strict.** All `arg` declarations come first (one block, comma-separated), then all `var` declarations, then the body. You cannot interleave a `var` after a statement that uses it. This trips up everyone who comes from Lua/JS/Python; if you see a "Parse error: expected `var`" message, you have a var declaration that's too late in the function. Move all vars to the top.

**The `\name` syntax is SC's symbol literal.** Symbols are interned strings used for argument keys, SynthDef names, and bus role tags. `\amp == \amp` is fast (pointer equality); `"amp" == "amp"` is slower (string comparison). The convention everywhere in SC is to use symbols for keys.
`─────────────────────────────────────────────────`

### Triggering and freeing

You created the synth and stopped it:

```supercollider
x = Synth(\beep, [\freq, 220, \amp, 0.2]);  // x now holds the running synth
x.set(\freq, 330);                          // change params while running
x.set(\amp, 0.05);
x.free;                                     // stop it
```

`Synth.new` (which `Synth(...)` is shorthand for) returns a reference to the running instance. You can call `.set` on it any time to change parameters; you can call `.free` to release it.

A SynthDef does not stop on its own unless it uses an envelope with `doneAction: 2`. The `\beep` example will play forever until you free it. Most "real" voices use an envelope:

```supercollider
(
SynthDef(\beepEnv, {
    arg freq = 440, amp = 0.1, attack = 0.01, release = 0.5;
    var env = EnvGen.kr(
        Env.perc(attack, release),
        doneAction: 2     // free the synth when the envelope ends
    );
    var sig = SinOsc.ar(freq) * amp * env;
    Out.ar(0, sig ! 2);
}).add;
)

Synth(\beepEnv);   // plays for ~0.5 sec, then auto-frees
```

`EnvGen` plays an envelope; `Env.perc(attack, release)` defines a percussive envelope shape; `doneAction: 2` is "free the enclosing synth when this envelope finishes." This is the standard pattern for one-shot voices. The `OneShot.sc` voice in this project uses exactly this pattern (with a different envelope shape).

## 2. Audio buses

`Out.ar(0, sig)` writes to audio bus 0. Audio buses are the routing fabric of SC: any synth can write to any bus, and any synth can read from any bus via `In.ar`. The first two audio buses (0 and 1) are wired to your physical stereo output by default.

Try the two-synth version: one synth writes to a private bus; a second synth reads it back and outputs to the main mix.

```supercollider
(
SynthDef(\writer, {
    arg out, freq = 440;
    var sig = SinOsc.ar(freq) * 0.1;
    Out.ar(out, sig);          // write to whichever bus we're given
}).add;

SynthDef(\reader, {
    arg in, out;
    var sig = In.ar(in, 1);    // read 1 channel from `in`
    var distorted = sig.tanh * 2;
    Out.ar(out, distorted ! 2);
}).add;
)
```

Allocate a private bus and chain the two synths:

```supercollider
b = Bus.audio(s, 1);                           // 1-channel audio bus
~writer = Synth(\writer, [\out, b.index, \freq, 440]);
~reader = Synth(\reader, [\in, b.index, \out, 0]);  // route to main out
```

You should hear a soft, slightly distorted 440 Hz tone. Free them:

```supercollider
~writer.free; ~reader.free; b.free;
```

This is how schicksalslied 2.0 routes audio. There are four buses for the FX pipeline (`dryBus`, `reverbBus`, `delayBus`, `granularBus`), each with two channels. Voice synths write to them according to per-voice send levels; FX synths read them and process; an `outSynth` reads the final `dryBus` and writes it to bus 0 (the main output).

### The audio bus per-block clear rule

Audio buses are **cleared at the start of every audio block** (control period). This is a single sentence with enormous implications, so let's unpack it.

The SC server processes audio in fixed-size blocks (the default is 64 samples — about 1.3 ms at 48 kHz). Inside one block, all the active synths run once in order; each synth's UGens process 64 samples of input and write 64 samples of output. Between blocks, the server **zeros every audio bus** so that the next block starts clean.

Within a block, if synth A writes to bus B and synth C reads bus B, the order in which A and C execute determines whether C sees A's output:

- If A executes **before** C: C sees A's output. ✓
- If A executes **after** C: C sees zeros (the bus was cleared at block start; A's write hasn't happened yet within this block; by the time A writes, C has already done its read for this block).

This is exactly the bug pattern that bit this script in development. The delay synth's output is supposed to feed the reverb synth via `reverbBus`, but with `addToHead` semantics the reverb synth ended up executing first — so the delay's write to `reverbBus` was always too late. The fix (chapter 03) was to ensure the delay synth runs before the reverb synth.

`★ Insight ─────────────────────────────────────`
**The bus-clear rule is what makes SC's parallel-graph model work.** Without it, buses would accumulate forever — every write would add to the previous block's value. The clear makes each block a clean slate. The cost is that you have to think about execution order; the benefit is that you can route arbitrarily without worrying about residue from previous blocks.

**Control rate buses behave differently.** A `Bus.control(s, 1)` does not clear between blocks; it's a one-sample-per-block slot that holds whatever was last written. This is useful for slowly-changing values (LFOs, MIDI control values). schicksalslied 2.0 uses control buses sparingly — most modulation flows through synth parameters set via OSC.
`─────────────────────────────────────────────────`

## 3. Groups and execution order

A `Group` is an ordered collection of nodes (synths and other groups) on the server. The server processes nodes in group order, head to tail. By organizing your synths into groups, you control the execution order — which is what determines whether the bus-clear rule helps or hurts you.

Default group structure on a fresh server:

```
Root group (id 0)
└── Default group (id 1)
    └── [your synths go here]
```

By default, `Synth.new` adds to the head of the default group. Each new synth becomes the first thing executed in that group, **pushing previously-added synths back**.

```supercollider
g = Group.new(s);   // create a new group
a = Synth.new(\beep, [], g);   // adds to head of g
b = Synth.new(\beep, [\freq, 880], g);  // adds to head of g, pushes a back
// execution order: b, then a
```

You can also explicitly use `\addToTail`:

```supercollider
g = Group.new(s);
a = Synth.new(\beep, [], g, \addToHead);   // a at head
b = Synth.new(\beep, [], g, \addToTail);   // b at tail
// execution order: a, then b
```

Or position relative to another node:

```supercollider
c = Synth.new(\beep, [], a, \addAfter);    // c executes immediately after a
d = Synth.new(\beep, [], a, \addBefore);   // d executes immediately before a
```

### Why this matters for schicksalslied 2.0

The script defines three groups (in `Lied.sc`):

- `voiceGroup` — contains the cell voices (TriSin, Ringer, Sampler, OneShot instances).
- `fxGroup` — contains the master FX synths (delay, reverb).
- `outGroup` — contains the master output synth.

These are arranged with `Group.after`:

```supercollider
voiceGroup = Group.new(server);
fxGroup    = Group.after(voiceGroup);
outGroup   = Group.after(fxGroup);
```

So the server executes: all voices → all FX → master output. Each block. This is the right order: voices write to all four FX buses; FX synths read those buses and process; the master out reads the final dry bus and writes to physical out.

The bug we hit in chapter 01's narrative was within `fxGroup`. We instantiated:

```supercollider
delaySynth  = Synth.new(\liedDelay, [...], fxGroup);   // ← went to head
reverbSynth = Synth.new(\liedReverb, [...], fxGroup);  // ← also addToHead by default
```

The second `addToHead` pushed `delaySynth` to position 2. So the order in `fxGroup` was reverbSynth → delaySynth. The reverb tried to read from `reverbBus` (which the delay was supposed to be writing to) before the delay had executed in that block. Bug.

The fix was to swap the instantiation order, so the second-added (delay) ends up at head and the first-added (reverb) gets pushed to tail. Now: delaySynth → reverbSynth. Delay writes to reverbBus first; reverb reads delay's output in time.

`★ Insight ─────────────────────────────────────`
**Group ordering inside an FX chain is exactly as fragile as it sounds.** Every time you add a new synth to a group, ask yourself: where does it need to be relative to everything else? `\addToHead` is convenient because you can just keep calling `Synth.new(synth, args, group)` and synths pile up at the head — but that means the **most recently created** synth runs **first**, which is often the opposite of what a beginner expects.

**A defensive practice**: when ordering matters, use `\addToTail` consistently and write the synths in the order you want them to execute. Then there's no surprise. Or use `Group.after` / `Synth.after` to make ordering explicit. The chapter 03 build of `Lied.sc` uses both approaches.
`─────────────────────────────────────────────────`

## 4. Buffers

A `Buffer` is a server-side array of audio samples. Buffers hold loaded sound files, recorded mic input, delay lines, and any other "stored audio" the script needs to manipulate.

```supercollider
b = Buffer.alloc(s, s.sampleRate * 2, 1);   // 2 sec of mono audio
b.zero;                                     // explicit zeroing (alloc'd buffers are zeroed by default)
b.numFrames.postln;                         // 96000 at 48 kHz
b.free;                                     // release
```

For loading an audio file:

```supercollider
b = Buffer.read(s, "/path/to/sound.wav");
// ... use the buffer ...
b.free;
```

`Buffer.read` and `Buffer.alloc` are **asynchronous**. The server allocates the buffer in a different thread; if you try to use the buffer in the same line as you allocate it, you'll get an error (the buffer isn't ready yet). For one-line examples, sclang's REPL gives the allocation time to complete before your next line. For programmatic use, you need `server.sync` (covered below).

### Server-side heap vs. real-time pool

This is the single most important SC concept for understanding `Lied.sc`'s memory behavior.

The SC server has two distinct memory pools:

1. **Heap memory** — used by `Buffer.alloc`, `Buffer.read`, and similar long-lived allocations. The heap is generous (hundreds of MB on a desktop, ~250 MB+ on Norns). Heap allocations happen in a worker thread and are safe to do at any time.

2. **Real-time memory pool** — used by certain UGens that need internal buffers, most notably the delay-line UGens (`DelayN`, `DelayL`, `DelayC`, `CombN`, `CombL`, `CombC`, `LocalBuf`, and others). The real-time pool is small (about 8 MB by default on Norns) and allocates in **real time** — i.e., as part of UGen initialization, which happens on the audio thread.

This distinction explains a behavior the script ran into during development: when we set `CombL`'s `maxdelaytime` to 16 seconds (planning to support 4-beat delay sync at 60 BPM), JackDriver threw `alloc failed, increase server's memory allocation` and the delay synth produced noise instead of audio. At 48 kHz stereo float, a 16-second `CombL` buffer is about 6 MB. The real-time pool on Norns was not large enough.

The fix was to lower `maxdelaytime` to 8 seconds (about 3 MB), which fits with headroom to spare. The same value is set in `Lied.sc:95`.

```supercollider
// In Lied.sc:
var del = CombL.ar(sig, 8.0, delayTime, decayTime);
//                       ↑
//                       maxdelaytime — allocates from real-time pool
```

`★ Insight ─────────────────────────────────────`
**You can put very large buffers in the heap, but be careful with real-time pool allocations.** A 100 MB sample buffer is fine (`Buffer.read` puts it on the heap). A 16-second `CombL` is not (real-time pool, may not fit). When you're designing a SynthDef that uses a delay UGen, check the documented allocation size and make sure your `maxdelaytime` budget is appropriate.

**The granular delay chain in `Lied.sc` is on the heap.** `delayBuf = Buffer.alloc(server, server.sampleRate * (beat_sec * 512), 1)` — that's a 512-beat-long mono delay buffer (about 230 MB at 60 BPM). It's allocated via `Buffer.alloc`, so it lives on the heap, not in the real-time pool. This is why the granular chain can be much longer than the comb-filter delay tap.

**To check your Norns SC server's real-time pool size**: in Maiden's SC REPL, run `s.options.memSize.postln;`. The default on stock Norns is 16384 (the unit is kilobytes, so 16 MB). It can be increased in Norns's SC startup config, but doing so reduces memory available for other things and is generally not recommended unless you have a specific need.
`─────────────────────────────────────────────────`

## 5. Smoothing parameters with `lag` and `lag3`

When you `set` a parameter on a running synth, the parameter changes instantly — within one control block, the UGen sees the new value. That instant change often causes audible clicks or pops, especially for amp and pitch.

To smooth these transitions, SC provides the `.lag` and `.lag3` UGen methods. These work like a one-pole low-pass filter applied to the parameter signal:

```supercollider
(
SynthDef(\smoothAmp, {
    arg freq = 440, amp = 0;
    var smoothAmp = amp.lag(0.1);    // 0.1 sec lag time
    var sig = SinOsc.ar(freq) * smoothAmp;
    Out.ar(0, sig ! 2);
}).add;
)

x = Synth(\smoothAmp, [\freq, 440]);
x.set(\amp, 0.3);    // ramps up smoothly over ~0.1 sec
x.set(\amp, 0);      // ramps down
x.free;
```

`.lag` is a linear lag (first-order). `.lag3` is a third-order lag (cubic), which gives a smoother ramp with more "musical" pacing. schicksalslied 2.0 uses `.lag3` for amp slewing on every voice:

```supercollider
// From TriSin.sc:
Out.ar(dry_bus, signal * ampSig * dry_send.lag3(0.05));
```

The `0.05` is in seconds — 50 ms is a typical click-suppression slew. Use shorter slews (10 ms) for rapid changes; longer (200 ms+) for sweeping pad-style transitions.

### Implementation note

`lag` and `lag3` produce one UGen instance each. They're cheap — a few CPU cycles per sample. You can put them on dozens of parameters without measurable cost.

## 6. The `fork` + `server.sync` async pattern

When you write code that allocates buffers, sends them to synths, then triggers those synths, you have to wait for each step to complete before proceeding. `Buffer.read` is async; if you do `Synth.new(...)` referencing the buffer immediately after `Buffer.read`, the buffer isn't ready.

`fork` runs a block of code as a `Routine` (SC's coroutine), in which you can `wait` for things:

```supercollider
(
fork {
    var buf;
    buf = Buffer.read(s, "/path/to/sound.wav");
    s.sync;    // wait for the server to finish the read
    "Buffer loaded".postln;
    Synth(\beep, [\freq, 440]);
    1.wait;
    "1 second later".postln;
};
)
```

`s.sync` (where `s` is the server) sends a sync OSC message and blocks the routine until the server confirms it. By that point, every preceding async operation (buffer allocations, SynthDef compilations, etc.) is done.

`1.wait` blocks for 1 second of wallclock time. You can also wait on TempoClocks for beat-aligned scheduling.

`Lied.sc` uses this pattern heavily, e.g., in `loadSampler`:

```supercollider
loadSampler { arg slot, filePath;
    fork {
        var sf, duration, buf, pending;
        // ... open file, check duration ...
        buf = Buffer.read(server, filePath);
        server.sync;
        // ... now safe to construct Sampler with this buffer ...
        samplerInstances[slot] = Sampler.new(buf, ...);
    };
}
```

The `fork` is required because `server.sync` only works inside a Routine (it needs `yield`-style suspension). Outside of `fork`, you'd block sclang itself, which would deadlock the OSC dispatch loop.

`★ Insight ─────────────────────────────────────`
**`fork` is shorthand for `Routine { ... }.play;`** It returns the Routine, which you can store and cancel later if needed: `r = fork { ... }; r.stop;`. The implicit `.play` schedules the routine on the default TempoClock; it starts running immediately.

**Inside a `fork`, sequential code is sequential.** This is the surprising thing about working with async operations in SC compared to JavaScript: you don't need `then` callbacks or `await` keywords. `s.sync` blocks the routine until the server confirms; the next line just runs after the sync completes. SC's coroutine model makes async code look like synchronous code, which is great for readability.
`─────────────────────────────────────────────────`

## 7. The `Dictionary` + `getPairs` pattern

When you create a SynthDef with 20+ arguments, hand-passing each one to every `Synth.new` call becomes painful and error-prone:

```supercollider
Synth.new(\bigVoice, [\freq, 440, \amp, 0.2, \pan, 0, \cutoff, 8000, \resonance, 3, ... 15 more pairs ...]);
```

The script uses a different pattern: store the current parameter values in a `Dictionary`, and splice them into `Synth.new` via `.getPairs`:

```supercollider
// In the voice class:
voiceParams = Dictionary.newFrom([
    \freq, 440, \amp, 0.2, \pan, 0, \cutoff, 8000, ...
]);

// To trigger:
Synth.new("TriSin", voiceParams.getPairs, group);
```

`getPairs` returns a flat array of alternating keys and values: `[\freq, 440, \amp, 0.2, \pan, 0, ...]`. This is exactly the format `Synth.new` wants for its args. So one Dictionary holds the current state of every parameter, and every new synth instance gets all current values at construction time.

This solves two problems at once:

1. **Code clarity.** Param changes go through `voiceParams[\amp] = 0.3` (semantic; named storage), not through synth-specific calls.
2. **State persistence across voice instances.** When a new TriSin voice is triggered (because the cell fired), it inherits the current `voiceParams` state. Param changes you made while no voice was running are still applied to the next-triggered voice.

This is one of the most-used idioms in `Lied.sc` and all the voice classes. You'll see it implemented in detail in chapter 05.

## 8. Putting it together: a minimal "voice in a bus" mini-rig

To consolidate everything, here's a runnable example that exercises every concept from this chapter at once. Evaluate the block in SC IDE:

```supercollider
(
// Step 1 — define the voice and an FX processor.
SynthDef(\miniVoice, {
    arg out, freq = 440, amp = 0, attack = 0.01, release = 0.5;
    var env = EnvGen.kr(Env.perc(attack, release), doneAction: 2);
    var sig = SinOsc.ar(freq) * amp.lag3(0.05) * env;
    Out.ar(out, sig ! 2);
}).add;

SynthDef(\miniFX, {
    arg in, out, delayTime = 0.3, decayTime = 1.5, amp = 1.0;
    var sig = In.ar(in, 2);
    var wet = CombL.ar(sig, 2.0, delayTime, decayTime);
    Out.ar(out, sig + wet * amp.lag3(0.05));
}).add;

// Step 2 — wait for the SynthDefs to compile and register on the server.
s.sync;

// Step 3 — allocate a fx bus + create groups in the right order.
~fxBus = Bus.audio(s, 2);
~voiceGrp = Group.new(s);
~fxGrp    = Group.after(~voiceGrp);

// Step 4 — instantiate the FX synth, reading from ~fxBus, writing to main out.
~fxSynth = Synth.new(\miniFX, [\in, ~fxBus.index, \out, 0], ~fxGrp);

// Step 5 — fire a voice into the fx bus and let it auto-free.
Synth.new(\miniVoice, [\out, ~fxBus.index, \freq, 220, \amp, 0.3], ~voiceGrp);
)
```

You should hear a single sine-burst with a few echo taps. Fire more by re-running just the `Synth.new(\miniVoice, ...)` line. To clean up:

```supercollider
~fxSynth.free; ~fxBus.free; ~voiceGrp.free; ~fxGrp.free;
```

Now look back at the components:

- **SynthDef** structure (args, vars, body, `.add`).
- **lag3** for amp smoothing.
- **`s.sync`** to wait for the SynthDefs to register before allocating buses and synths.
- **`Bus.audio`** for the private FX bus.
- **`Group.new` + `Group.after`** to establish execution order (voices → FX).
- **`In.ar` + `Out.ar`** to route audio through the bus.
- **`CombL` allocating from the real-time pool** for the delay tap (with a conservative 2.0 maxDelay).
- **doneAction: 2** for one-shot lifecycle.

Almost every chapter 03 and chapters 05-08 idiom is here in miniature.

`★ Insight ─────────────────────────────────────`
**The `s.sync` between SynthDef registration and `Synth.new` matters.** Without it, you might `Synth.new(\miniVoice, ...)` before the server has finished registering `\miniVoice`, and you'd get a "SynthDef \miniVoice not found" error. SC IDE typically gives you enough time when running line-by-line, but in production code that runs as a single block, `s.sync` is your safety net.

**`~name` is sclang's environment variable syntax.** Roughly equivalent to a global variable. The `Lied.sc` engine class doesn't use these — it stores state as class instance variables (`var <dryBus`, `var <reverbBus`, etc.) — but they're useful for experimentation in the IDE.
`─────────────────────────────────────────────────`

## 9. A note on multichannel expansion

You'll see this pattern in voice classes:

```supercollider
signal = Pan2.ar(filter, pan.lag3(pan_slew));
Out.ar(dry_bus, signal * ampSig * dry_send.lag3(0.05));
Out.ar(reverb_bus, signal * ampSig * reverb_send.lag3(0.05));
Out.ar(delay_bus, signal * ampSig * delay_send.lag3(0.05));
```

Four `Out.ar` calls writing the same `signal` to four different buses at different gain levels. This is the per-voice "send" routing: one voice contributes to multiple FX buses simultaneously, each at an independent gain.

`Pan2.ar` produces a stereo signal (2-channel). `Out.ar(bus, stereoSig)` writes the stereo signal to two consecutive bus indices starting at `bus`. As long as `dry_bus`, `reverb_bus`, etc. are all 2-channel buses (allocated with `Bus.audio(s, 2)`), this all works seamlessly.

`★ Insight ─────────────────────────────────────`
**Multichannel expansion in SC**: when you put an array of UGens through a UGen-of-UGens operation, the result expands. For example, `SinOsc.ar([440, 660])` returns a 2-element array of `SinOsc` instances. This is how Pan2 turns a mono signal into a stereo array: it internally produces `[sig * leftGain, sig * rightGain]`.

**`Out.ar(bus, [a, b])`** writes `a` to `bus` and `b` to `bus + 1`. If you pass a 4-element array, it writes to buses `bus..bus+3`. This is why 2-channel buses "just work" with stereo signals: pass an array of size 2, occupy two consecutive bus indices.
`─────────────────────────────────────────────────`

## 10. Diagnosing SC problems

You'll inevitably hit SC errors during chapters 03 and 04. A few common patterns and how to debug them:

**"SynthDef X not found"** — you tried to `Synth.new(\X, ...)` before `\X` was registered. Either evaluate `.add` first, or add an `s.sync` between defining the SynthDef and using it.

**Silence where you expect sound** — most likely causes, in order: (1) you forgot to `.boot` the server; (2) your amp is 0 (you set it but the change hasn't slewed up yet, or you accidentally multiplied by 0 somewhere); (3) the bus you're writing to isn't being read by anything; (4) group ordering: the writer comes after the reader within a group.

**Loud nasty noise on instantiation** — typically a UGen ran with an out-of-range arg (negative `maxdelaytime`, a Buf reference that wasn't loaded, division by zero in a `kr` chain). Stop with `Cmd-.` and check your args.

**Server crash** — heavy CPU load or memory exhaustion. Check the post window for "alloc failed" or "Jack: process callback time exceeded". Lower polyphony, reduce delay-line `maxdelaytime`, or simplify the SynthDef.

**"alloc failed" specifically** — real-time pool exhausted. See section 4. You're trying to allocate more delay buffer than the pool has room for.

## Chapter 02 checkpoint

You should be able to:

- [ ] Boot the SC server and stop sounds with `Cmd-.`.
- [ ] Write a SynthDef with arg slewing and an envelope, evaluate it, and trigger it.
- [ ] Explain (in your own words) why audio buses are cleared per block and why this affects group ordering.
- [ ] Explain the difference between SC's heap and its real-time memory pool, and which UGens allocate from which.
- [ ] Write a small `fork { ... s.sync; ... }` block that loads a buffer and plays a synth that uses it.
- [ ] Identify what `voiceParams.getPairs` is doing in the context of `Synth.new(...)`.

If those are solid, you're ready for chapter 03.

## What's next

**Chapter 03 — The Lied Engine** walks through `lib/Lied.sc` in detail. We'll build out:

- The class structure (`var <` accessors for REPL diagnostics).
- The bus graph: how `dryBus`, `reverbBus`, `delayBus`, and `granularBus` are allocated and connected.
- The FX synths (delay, reverb, master out) and the carefully ordered group structure that makes them work together.
- The granular delay chain: write buffer (heap), pointer, recorder, grain readers, feedback patch.
- Voice instance management: `triSinInstances`, `ringerInstances`, `samplerInstances`, `oneShotInstances` — and the `pending*Params` dictionaries that let the script set per-cell parameters before the corresponding voice instance has been allocated.
- The `bufferCache` + `bufferRefCounts` system for shared sample buffers.

By the end of chapter 03, you'll have a complete `Lied.sc` that compiles and instantiates, even though it can't yet receive commands from Norns (that's chapter 04's job).
