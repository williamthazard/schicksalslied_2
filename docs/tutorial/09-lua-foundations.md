# Chapter 06 — Norns Lua Foundations

## What you'll learn

The Lua idioms specific to Norns that this script relies on: `params:add{...}` and the param tree, `clock.run` / `clock.sync` / `clock.sleep` and the absolute-vs-relative timing distinction, the `sequins` library, grid/screen handler shapes, `metro` for timer-driven redraws, and Norns's `include` (which is **not** a caching `require`). We'll also cover the `_G.GlobalSequencer` cross-include identity workaround that appears throughout this script's Lua side.

This chapter is a primer for the Lua side. If you write Norns scripts regularly, you can skim it. If you're new to Norns, slow down — chapters 07-10 assume you can read and write the code patterns introduced here.

## Prerequisites within the tutorial

- Chapter 01 (you know the three-tier architecture).
- Some Lua familiarity. If you've never written Lua, work through the first 3 chapters of [Programming in Lua](https://www.lua.org/pil/contents.html) before continuing.

## What this chapter is not

A full Norns scripting tutorial. The [Norns Studies](https://monome.org/docs/norns/studies/) on monome.org are the canonical reference. This chapter is a focused tour of the parts of Norns Lua that schicksalslied 2.0 depends on. If you find yourself confused about something we don't cover here, the Studies are where to look.

## Norns script anatomy

Every Norns script has the same top-level shape:

```lua
engine.name = 'EngineName'   -- optional; only if your script uses a custom SC engine

function init()
    -- runs once at script load. Set up params, start clocks, etc.
end

function key(n, z)
    -- called on hardware key press/release. n is the key (1, 2, 3); z is 1=press, 0=release.
end

function enc(n, d)
    -- called on encoder turn. n is the encoder (1, 2, 3); d is the delta (-1 or 1 typically).
end

function redraw()
    -- called when you want to repaint the screen. Norns does NOT call this automatically;
    -- you must call it yourself (typically from a metronome timer).
end

function cleanup()
    -- runs once at script unload. Free resources, stop clocks, etc.
end
```

Schicksalslied has all five of these, plus additional handlers for grid, MIDI, and keyboard input. We'll see them all in chapter 10.

`★ Insight ─────────────────────────────────────`
**Norns does not auto-call `redraw`.** Many GUI frameworks auto-repaint on state change; Norns does not. You're responsible for triggering repaints when state changes. The convention is to set a `screen_dirty = true` flag from your handlers and call `redraw()` from a metro timer that ticks 15 fps. schicksalslied uses this pattern (in `schicksalslied.lua:1296` you'll see `screen_metro.time = 1/15`).

**Norns calls `cleanup` when the script unloads** — when the user picks a different script, when Norns is restarting, etc. Anything you allocated server-side (engine voices, buffers) should be released. Anything you started (metros, clocks) should be stopped. Anything you set on hardware (crow outputs, MIDI sends) should be reset.
`─────────────────────────────────────────────────`

## Params

The `params` API is Norns's central state-management system. You declare params at init; each has a unique ID, a name, a type, and value constraints. The system gives you:

- **A UI menu** the user can navigate to view/change values.
- **Persistence** via PSET (preset save/load).
- **Actions** that fire when the value changes (your hook to actually do something with the new value).
- **MIDI mapping** via long-press in the params menu.

### Declaring a param

The basic form:

```lua
params:add{
    type = 'control',
    id = 'master_volume',
    name = 'master volume',
    controlspec = controlspec.new(0, 1, 'lin', 0.01, 0.5, ''),
    action = function(v)
        engine.set_out_amp(v)
    end,
}
```

Fields:

- **`type`**: `'control'` (continuous value with a controlspec), `'option'` (enum), `'number'` (integer with min/max), `'text'`, `'file'`, `'trigger'`, plus a few others.
- **`id`**: unique string identifier. Used by `params:get(id)`, `params:set(id, value)`, etc. Convention: snake_case.
- **`name`**: human-readable display string for the params menu.
- **`controlspec`** (for `type='control'`): a `controlspec.new(min, max, warp, step, default, units)` declaration. `warp` is `'lin'`, `'exp'`, etc.
- **`action`**: function called whenever the param changes value. The action receives the new value.

There are other fields for option-type params, file-type params, etc. — we'll see them in chapter 09.

`★ Insight ─────────────────────────────────────`
**The action fires on every change, including from PSET load and `params:bang()`.** This is what lets you write a param action that pushes the value to SC, and have it Just Work for direct user changes, PSET loads, AND init-time defaults. The action is the canonical "this value just changed, do whatever needs doing" hook.

**Don't put heavy work in actions.** Actions fire frequently — e.g., MIDI-mapped knobs can fire actions hundreds of times per second during a sweep. Actions should be lightweight: typically just one OSC call to SC, or one parameter update. Don't allocate, don't print, don't do anything synchronous that takes time.
`─────────────────────────────────────────────────`

### Reading and writing params

```lua
local v = params:get('master_volume')   -- read
params:set('master_volume', 0.7)        -- write (fires the action)
params:set('master_volume', 0.7, true)  -- write SILENTLY (does NOT fire action)
```

The `silent` flag (third arg) is critical for some patterns. If you're trying to keep two params in sync via cross-action calls, you can introduce infinite loops by triggering actions from inside other actions; using `silent=true` breaks the loop.

### `params:bang()`

```lua
params:bang()
```

Iterates every param and fires its action with the current value. Usually called once at init, after all `params:add` calls, to push initial values everywhere. Without `bang`, the SC side doesn't know about the param defaults until the user touches each one.

### Param groups and separators

```lua
params:add_separator('synths_section', 'SYNTHS')
params:add_group('synth_voices', 'voices', 16 * 50 + 4)  -- group label, internal name, expected param count
-- ... 16*50+4 params:add{} calls ...
```

`add_separator` puts a bold heading in the params menu. `add_group` creates a collapsible subsection — the user can navigate into and out of it. The third arg to `add_group` is the expected count; Norns uses this for layout calculations and will warn (but not crash) if you add more or fewer than promised.

The Norns params menu can become unwieldy if you have thousands of params (this script has about 3000). Group structure is what makes it navigable.

## Clocks: `clock.run`, `clock.sync`, `clock.sleep`

Norns has a global tempo clock (matron's scheduler). You can run coroutines that schedule themselves on this clock for beat-aligned timing.

```lua
local clock_id = clock.run(function()
    while true do
        clock.sync(1)   -- wait for next whole beat boundary
        do_something()
    end
end)
```

`clock.run(fn)` schedules `fn` as a coroutine on the matron clock and returns an ID. The coroutine can call `clock.sync(rate)` or `clock.sleep(seconds)` to suspend itself; matron resumes it at the right time.

### `clock.sync` is absolute, not relative

This is the single most important fact about Norns clocks for understanding this script's sequencer. **`clock.sync(rate)` waits until the next beat boundary where `beats % rate == 0`**, not "wait `rate` beats from now."

Consequences:

- `clock.sync(1)` fires every whole beat (1, 2, 3, ...). If you're currently at beat 6.7, it fires at beat 7.0 (in 0.3 beats).
- `clock.sync(2)` fires on even beats (2, 4, 6, ...). At beat 6.7, it fires at beat 8.
- `clock.sync(4)` fires on beats divisible by 4 (4, 8, 12, ...). At beat 6.7, it fires at beat 8.

This is **absolute grid-alignment**, which is what you want for a multi-voice sequencer: two cells on `rate=1` always fire on the same beat, even if their loops started at different times. Two cells on `rate=2` fire together. This is how synced layered patterns work.

But it has surprising consequences when the rate changes between fires. Consider a cell on `rate=2` from beat 0:

- Fire at 0, sync(2) → fire at 2.
- Fire at 2, sync(2) → fire at 4.
- Fire at 4 — but now the user sets a new rate of 1.5.
- sync(1.5) at beat 4 → next beat where `b % 1.5 == 0` is `4.5`, then `6.0`, `7.5`, etc.
- The gap from "rate=2 fire at 4" to "rate=1.5 fire at 4.5" is 0.5 beats, not 1.5 beats!

For a sequencer that's stepping through a *user-defined sequence* of rates `[1, 2, 1]`, this is wrong — you don't want absolute beat-grid alignment; you want each step to be exactly its declared duration after the previous step. That's where `clock.sync(rate, offset)` comes in:

```lua
clock.sync(rate, now % rate)
```

By passing the current `beats % rate` as the offset, you align the next fire to "exactly rate beats from now." This is **relative timing**. The script uses absolute timing for lied/fixed modes (where the grid alignment is desired) and relative timing for user_seq/random modes (where exact gap intervals matter). We'll see this in detail in chapter 07.

`★ Insight ─────────────────────────────────────`
**The absolute-vs-relative timing distinction caused a real bug in this script's development.** The user_seq mode initially used `clock.sync(rate)` and produced "overlapping sequences" — two cells both on `rate=1` started together, but a user_seq cell with `[1, 2]` should fire on beat 0 (gap=1), beat 1 (gap=2), beat 3, beat 4, beat 6... With absolute timing, it fired on beat 0, beat 1 (sync(1)), beat 2 (sync(2) lands on the next even beat = 2 not 3), losing the intended gap. The fix was relative timing for user_seq + random.

**`clock.sleep(seconds)` is wallclock**: not beat-aligned. Use it when you need a literal time delay, not a beat delay. Examples: a short delay before re-enabling a button after a press, a fade-out timer. Don't use it for sequencing — use `clock.sync`.
`─────────────────────────────────────────────────`

### `clock.cancel(id)` and `clock.get_beats()`

```lua
clock.cancel(clock_id)   -- kill a running coroutine
local current = clock.get_beats()   -- read current beat count (a float)
local seconds_per_beat = clock.get_beat_sec()   -- inverse of BPM
```

`clock.get_beats()` is what the script's sequencer reads to know "where are we now" when computing relative offsets. `clock.get_beat_sec()` is what the engine reads to know "how long is one beat in real time" — used by the granular delay buffer sizing (which is beat-aligned).

## `sequins`

The [sequins library](https://monome.org/docs/norns/sequins/) is a lightweight sequence-stepping helper. You give it an array of values; it gives you a callable that returns the next value each call, cycling forever.

```lua
local Sequins = require 'sequins'
local s = Sequins({ 1, 2, 3, 4 })
print(s())   -- 1
print(s())   -- 2
print(s())   -- 3
print(s())   -- 4
print(s())   -- 1 (cycled back)
```

`s:settable(newArray)` replaces the underlying array in place, preserving the cursor where possible. This is how schicksalslied 2.0 swaps in a new text-driven byte sequence without restarting the loop:

```lua
local s = Sequins({ string.byte(' ') })  -- placeholder
-- ... later, when the user assigns text to the cell:
s:settable({ string.byte('A'), string.byte('B'), string.byte('C') })
-- The next s() call returns 65 (A's byte), etc.
```

Sequins supports more advanced operations (random selection, weighted selection, sub-sequences), but the script only uses the basic `Sequins(array)` constructor + `s()` advance + `s:settable(newArray)` replacement.

`★ Insight ─────────────────────────────────────`
**The sequins library is what makes the text-as-bytes idea work cheaply.** Every cell has its own Sequins instance over its own assigned text's bytes. Each call to `seq()` returns the next byte and advances the cursor. Multiple parallel cells with different texts produce different sequences naturally — no coordination needed beyond each cell having its own Sequins.

**`:settable` is in-place mutation.** The Sequins object's reference is stable; only the data array changes. This means anywhere else in the code that holds a reference to the Sequins keeps the reference valid after `:settable`. (Compare to reassigning a Lua local — that would break references.)
`─────────────────────────────────────────────────`

## Grid

A monome grid connects over USB. Norns auto-discovers it. To use it:

```lua
local g = grid.connect()   -- get a handle to the grid (or nil if none)

g.key = function(x, y, z)
    -- called on every button press/release
    -- x: column (1-indexed, 1-16 typically)
    -- y: row (1-indexed, 1-8 typically)
    -- z: 1 for press, 0 for release
end
```

To set LEDs:

```lua
g:all(0)       -- turn off all LEDs
g:led(x, y, brightness)   -- set one LED. brightness: 0-15.
g:refresh()    -- push the changes to the hardware (without this, your sets are buffered but invisible)
```

The script's grid redraw is `function grid_redraw()` in `schicksalslied.lua`, called from a 30 fps metro.

### A typical grid handler

```lua
g.key = function(x, y, z)
    if z == 1 then
        -- press
        if y == 1 then
            -- row 1: history
            handle_history_press(x)
        elseif y == 8 and x == 14 then
            -- specific cell: mic toggle
            toggle_mic()
        end
    end
    -- (z == 0 = release; often unused for toggle-row cells)
    grid_dirty = true   -- mark for redraw
end
```

The conditional cascade on `y` and `x` lets you assign different functions to different grid regions. schicksalslied uses this to dedicate rows to specific functions (row 1 = history; rows 2/4/6/8 = toggles; rows 3/5/7 = assigns).

### When the grid is disconnected

`grid.connect()` returns a handle even when no grid is attached; `g:refresh()` on a disconnected grid is a no-op. So the code can run with or without a grid. The script also checks `if g == nil then return end` at the top of `grid_redraw` — defensive in case grid.connect somehow returned nil.

## Screen

The Norns screen is 128x64 pixels, 16 levels of brightness. The API is immediate-mode:

```lua
function redraw()
    screen.clear()
    screen.level(15)         -- brightness (0-15)
    screen.move(10, 20)      -- cursor position (x, y)
    screen.text("Hello")     -- draw text at cursor (font is built-in)
    screen.move(0, 30)
    screen.line(128, 30)
    screen.stroke()           -- finalize the line
    screen.update()           -- push to hardware
end
```

You call drawing primitives that buffer commands; `screen.update()` pushes the buffer to the hardware. Without `update`, your draws don't appear.

Common primitives:

- `screen.clear()` — wipe.
- `screen.level(n)` — brightness, 0-15.
- `screen.move(x, y)` — set cursor.
- `screen.text(s)`, `screen.text_right(s)`, `screen.text_center(s)` — render text.
- `screen.line(x, y)` — line from current cursor to (x, y).
- `screen.rect(x, y, w, h)` — rectangle outline.
- `screen.fill()` / `screen.stroke()` — finalize a path as filled or stroked.

The script's `redraw()` is in `schicksalslied.lua` and renders the text field at top, history scroll list in the middle, and some indicator state at the bottom.

## metros

A `metro` is a Norns timer. Useful for repetitive work that shouldn't run as a clock coroutine (because it isn't beat-aligned).

```lua
local m = metro.init()
m.time = 1 / 15      -- fire every 1/15 sec = 15 fps
m.event = function()
    if screen_dirty then
        redraw()
        screen_dirty = false
    end
end
m:start()

-- ... later:
m:stop()
```

The script uses three metros:

- `screen_metro` at 15 fps — calls `redraw` if `screen_dirty`.
- `grid_metro` at 30 fps — calls `grid_redraw` if `grid_dirty`.
- `fire_decay_metro` at 15 fps — decrements the per-cell fire-decay counters (for the LED flash when a cell fires).

`★ Insight ─────────────────────────────────────`
**The dirty-flag pattern (set in event handlers, consumed in metro callbacks)** is the canonical Norns redraw idiom. It avoids both "redraw on every state change" (too much work) and "redraw at fixed rate always" (wastes CPU when idle). State changes set the dirty flag; the metro checks the flag and redraws only when needed. CPU usage drops to ~0 when nothing is happening; UI responsiveness stays high.

**Don't use metros for beat-synced work.** Use `clock.run` + `clock.sync`. Metros tick at wallclock intervals, which can drift relative to the beat clock. Beat-synced work (sequencer steps, beat-locked LFOs) belongs on the clock.
`─────────────────────────────────────────────────`

## `include` is not `require`

Norns Lua has an `include` function that's similar to Lua's `require` but importantly different:

- **`require 'module'`** is Lua-standard. Caches the result; subsequent calls return the same module table.
- **`include 'lib/something'`** is Norns-specific. **Re-executes the file every time.** Returns a fresh module table each call.

This is the source of one of the most subtle bug categories in this script.

Consider:

```lua
-- in schicksalslied.lua:
local Sequencer = include 'lib/sequencer'
Sequencer.dispatch_fn = function(x, y) ... end
```

```lua
-- in voice_params.lua:
local Sequencer = include 'lib/sequencer'
print(Sequencer.dispatch_fn)   -- nil!  Different table!
```

Each `include 'lib/sequencer'` re-executes `sequencer.lua` and returns a fresh table. The `dispatch_fn` set on schicksalslied.lua's local `Sequencer` is **not visible** to the `Sequencer` that voice_params.lua sees.

### The `_G.GlobalSequencer` workaround

The script's solution: expose canonical instances via `_G` (Lua's global table):

```lua
-- in schicksalslied.lua's init:
local Sequencer = include 'lib/sequencer'
_G.GlobalSequencer = Sequencer
```

```lua
-- in voice_params.lua:
local Seq = _G.GlobalSequencer
print(Seq.dispatch_fn)   -- works
```

Anywhere in the codebase that needs to read or modify shared state writes `_G.GlobalSequencer` or `_G.GlobalRoles` instead of going through `include` again. This sidesteps the cross-include identity bug entirely.

`★ Insight ─────────────────────────────────────`
**This bug shape — multiple includes producing multiple module instances — is unique to Norns Lua.** It does not exist in standard Lua (where `require` caches), in JavaScript (where modules cache), in Python (similarly cached), etc. If you've worked in a language with module caching as default, you will not expect this and will be surprised by it. The script's `_G.Global*` pattern is the documented workaround.

**An alternative would have been to convert all `include` calls to `require`-style caching** at the script level. But Norns scripts conventionally use `include` because it supports re-loading during development. The pattern of "one canonical instance in `_G`" is the price of keeping `include`'s hot-reload behavior while having shared mutable state across modules.

**Why use `include` at all instead of `require`?** Two reasons: (1) Norns's `include` resolves paths relative to the script's directory, which is convenient. (2) `include` re-executes on every call, which means edits to a lib file take effect on the next include without restarting the script (the script side anyway — SC class library still requires reboot). The hot-reload property is genuinely useful during development.
`─────────────────────────────────────────────────`

## Common pitfalls

A few traps you'll encounter when writing Norns Lua and how to avoid them:

**`params:set` doesn't always do what you think.** It writes the value AND fires the action. If you only want to write without firing, pass `true` as the third arg. Get this wrong and you can introduce infinite loops between two actions that set each other.

**`clock.run` returns immediately.** The coroutine starts in the background. Don't do `clock.run(...).join()`-style waiting — there is no such thing. If you need to wait for the coroutine to finish, use a different mechanism.

**`engine.<command>` is async.** When you call `engine.set_delay_amp(0.5)`, the OSC message is queued and dispatched eventually — usually within a millisecond, but not synchronously. Don't assume that the SC side has finished processing the command immediately after the Lua call returns.

**LFOs running during script init can produce surprising values.** If you set up params + LFOs, then call `params:bang()`, the LFO actions can fire mid-init and depend on params that haven't been processed yet. The script's `add_params` ordering is careful about this — define everything, THEN bang.

**`util.file_exists` returns boolean, not a file handle.** It's a stat check. Don't use it for opening; use `io.open(path, 'r')` if you need to actually read.

**Tables with string keys vs integer keys are different.** `{ [1] = 'a' }` is array-like; `{ ['1'] = 'a' }` is hash-like. The `#` length operator only counts the array part. This bites you when you try to count entries in a hash and get 0.

## Chapter 06 checkpoint

You should be able to:

- [ ] Write a `params:add{...}` call for a control-type param with a working action.
- [ ] Explain the difference between `clock.sync(rate)` (absolute grid) and `clock.sync(rate, now % rate)` (relative gap).
- [ ] Use the Sequins library to create a cycling sequence and replace its underlying table in place.
- [ ] Write a `g.key` handler that distinguishes press from release and reacts based on (x, y).
- [ ] Write a basic `redraw()` function that uses `screen.clear`, `screen.move`, `screen.text`, and `screen.update`.
- [ ] Explain why `include` requires the `_G.GlobalSequencer` workaround and when you'd use it.

If all six boxes check, you're ready for chapter 07.

## What's next

**Chapter 07 — The Sequencer** walks through `lib/sequencer.lua` in detail. We'll build the per-cell Sequins state, the clock loop per toggle cell, the four sequencer modes (lied / fixed / user_seq / random) with their rate-derivation logic, and the absolute-vs-relative timing distinction in concrete code. By the end of chapter 07, your script will be able to start 64 simultaneous beat-aligned coroutines that each step through their assigned text at their per-cell rates — which is the heart of what makes schicksalslied 2.0 work.
