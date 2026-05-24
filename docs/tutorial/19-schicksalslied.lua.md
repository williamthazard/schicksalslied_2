# Chapter 19 — `schicksalslied.lua`

The top-level script. **1,407 source lines** — the largest file in the project. This is the integration point where every previous chapter's module gets wired together.

If you've read chapters 03-18, the imports at the top of this file will all be familiar. The chapter has three movements. The first walks through the user-facing surface: keyboard input, grid handler, screen redraw, hardware keys/encoders, and the comprehensive `panic` function. The second is `add_params` — 737 lines of mostly-repetitive `params:add{...}` declarations; we establish the patterns and annotate the architecturally meaningful sections rather than reading every block. The third is `init()` and `cleanup()` — the orchestration that decides what gets set up in what order, including the PSET sidecar hook for persisting non-param script state across save/load.

A note on prerequisites: you really do need all the previous chapters here. Every module imported at the top of this file gets used somewhere in `init` or in a param action. If a section references a function you don't recognize, it's almost certainly defined in an earlier chapter.

## Header and dependencies

```lua
---schicksalslied 2.0
---
---a poetry sequencer
---
---type to enter text, ENTER to stage,
---grid row 3/5/7 press to assign,
---grid row 2/4/6/8 toggle to fire.
---
---K1: (unused)       E1: scroll history
---K2: append history E2: global amp
---K3: enter          E3: bpm
---
---version 2.0.0

engine.name = 'Lied'

local Sequencer  = include 'lib/sequencer'
local Roles      = include 'lib/cell_roles'
local MusicUtil  = require 'musicutil'
local Midi       = include 'lib/midi_role'
local Grain      = include 'lib/grid_grain_params'
local MidiInput  = include 'lib/midi_input'
```

**Lines 1-22**: file header + engine declaration + 6 module imports.

The `---` triple-dash prefix is Norns's convention for the **SELECT screen description**. Lines 1-13 appear on the Norns when the user is choosing scripts: title, tagline, summary, key bindings, version. This is the only place this metadata lives.

**`engine.name = 'Lied'`** triggers Norns to load `lib/Engine_Lied.sc` and instantiate the engine before `init()` runs. This must come BEFORE any `engine.<command>` calls.

The 6 imports:

- **`Sequencer`** (include) — the per-cell state and clock-loop module. The file-local `Sequencer` is used at module top-level; `_G.GlobalSequencer` (set in init) is used inside actions that need to share state across files.
- **`Roles`** — the role registry. Same pattern: file-local + `_G.GlobalRoles`.
- **`MusicUtil`** (require) — Norns's music-theory library. Used at module level + everywhere.
- **`Midi`** — MIDI-out role module.
- **`Grain`** — granular params module.
- **`MidiInput`** — MIDI keyboard input module.

The `include` calls don't cache (chapter 09). The file-local references are file-local; cross-file state-sharing uses `_G.GlobalSequencer` / `_G.GlobalRoles`.

`★ Insight ─────────────────────────────────────`
**`engine.name = 'Lied'` at the TOP of the file** — not inside `init()` — is intentional. Norns reads this declaration before `init` runs, so the engine class can be loaded and the SC voice instantiated before the Lua side starts trying to call engine commands. Inside init would be too late.

**The SELECT screen description format** (triple-dash comments at the very top) is a Norns convention. The first uncommented line ends the description block. Adding code after the description but before `engine.name` would push parts of the description off the screen — keep the description as the very first thing.
`─────────────────────────────────────────────────`

## Pre-flight: rejecting samples that are too long

```lua
-- ========================================================================
-- SAMPLE DURATION GUARD
-- ========================================================================
local MAX_SAMPLE_SEC = 600

local function file_duration(path)
    if path == nil or path == '' or path == '-' then return nil end
    local ch, samples, sr, fmt = audio.file_info(path)
    if ch == nil or samples == nil or sr == nil or sr == 0 then
        return nil
    end
    return samples / sr
end

local function check_sample_duration(label, slot, path)
    if path == nil or path == '' or path == '-' then return true end
    local dur = file_duration(path)
    if dur == nil then
        return true
    end
    if dur > MAX_SAMPLE_SEC then
        print(string.format(
            '%s %d load REJECTED: file is %.1fs (max %ds). Use a shorter sample.',
            label, slot, dur, MAX_SAMPLE_SEC))
        return false
    end
    return true
end
```

**Lines 24-55**: pre-flight check on sample file loads.

- **`MAX_SAMPLE_SEC = 600`** — 10 minutes. Same cap as the SC kernel's `loadSampler` / `loadOneShot` use. Defined in both Lua and SC because each side enforces the cap on its own path.
- **`file_duration(path)`** uses Norns's `audio.file_info(path)` to inspect the file's header (channels, sample count, sample rate, format). Returns duration in seconds, or nil if the file can't be inspected.
- **`check_sample_duration(label, slot, path)`** returns true if the file is safe to load. Prints a rejection message + returns false if the file is too long.

These are called from the file-load param actions in `add_params` (covered below). If they return false, the engine command is NOT sent; the SC side never sees the bad file.

`★ Insight ─────────────────────────────────────`
**Two-sided duration enforcement** (Lua + SC) might seem redundant but isn't. The Lua check is cheap and gives immediate feedback to the user (rejection message in the matron log). The SC check is the safety net — if somehow a long file bypasses the Lua check (e.g., a programmatic load that didn't go through the param action), SC's loadSampler still refuses. Defense in depth.

**Treating "-" as nil** (`path == '-'`) is a Norns convention. The file param uses `-` as the "no file" placeholder; treating it as nil means "no work to do" rather than "try to load a file named -."
`─────────────────────────────────────────────────`

## Module-level state: text/history + grid hotplug

```lua
-- ========================================================================
-- MODULE-LEVEL LOCALS — text input + history
-- ========================================================================
local displayed_string = ""
local my_string        = ""
local history          = {}
local history_index    = 0
local new_line         = false
local needs_restart    = false

-- ========================================================================
-- GRID + SCREEN
-- ========================================================================
local g = grid.connect()

local screen_metro, grid_metro, fire_decay_metro

grid_dirty = true

grid.add = function(dev)
    g = grid.connect()
    grid_dirty = true
    print('grid connected: ' .. (dev.name or 'unknown'))
end

grid.remove = function(dev)
    print('grid disconnected: ' .. (dev.name or 'unknown'))
end
```

**Lines 57-90**: text/history state, grid handle, metro forward-declarations, hotplug handlers.

The text-input state:
- **`displayed_string`** — the line currently being typed (or recalled from history).
- **`my_string`** — the staged line (set by ENTER; assigned to cells by row-3/5/7 grid presses).
- **`history`** — the array of typed lines. Aliased into `Sequencer.history` in init.
- **`history_index`** — current scroll position.
- **`new_line`** — flag indicating we just hit ENTER; tells UP-arrow to jump to last history rather than the post-last "new line" position.
- **`needs_restart`** — legacy from 1.x's FormantTriPTR install flow. Always false in 2.0.

The grid setup:
- **`g = grid.connect()`** — get a handle (or a no-grid placeholder).
- **Metro handles** are forward-declared so init() and cleanup() can share them.
- **`grid_dirty = true`** — declared as a **global** (no `local` keyword). This is because `sequencer.lua`'s `toggle_pause` writes to it; if it were file-local, sequencer.lua couldn't see it.
- **Hotplug handlers** (`grid.add`, `grid.remove`) fire when the user connects/disconnects a grid mid-session. Without `grid.add`, plugging in a grid after init would leave the LEDs dark until the first grid press triggered a redraw.

`★ Insight ─────────────────────────────────────`
**`grid_dirty` as a global** is the script's one concession to cross-module mutation. Sequencer's `toggle_pause` needs to set this flag, and the easiest way is a global. Could be done with a `Sequencer.grid_dirty` field instead; the current global approach is simpler.

**Hotplug handling for grids** is a UX touch most scripts skip. Without it, the user has to reload the script after plugging in their grid — annoying. The 5-line `grid.add` / `grid.remove` block handles this gracefully.
`─────────────────────────────────────────────────`

## Initializing crow and the ii-attached devices

```lua
local function crow_reinit()
    crow.input[1].mode('clock')
    crow.ii.pullup(true)
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
    crow.output[2].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
    crow.output[4].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
    print('crow re-initialized')
end
```

**Lines 95-116**: initialize crow and ii-attached devices.

Walk:

- **`crow.input[1].mode('clock')`** — configure crow input 1 to receive clock pulses. (Used by Norns's clock_source if set to crow.)
- **`crow.ii.pullup(true)`** — enable pullup resistors on crow's i2c bus. **Critical for ii reliability**; without it, ii communication can be flaky depending on the devices connected.
- **JF setup**: `mode(1)` = synthesis mode (vs gestalt). `run_mode(1)` = some specific run mode. `tick(tempo)` = sync JF's internal clock to the current BPM.
- **w/tape setup**: `timestamp(1)`, `freq(0)`, `play(0)` — initialize w/tape's transport.
- **w/del setup**: zero out modulation params.
- **w/syn setup**: `ar_mode(1)` = AR envelope mode; `voices` from the params menu; `patch(1, 1)` and `patch(2, 2)` = standard "this and that" inputs routed to ramp and curve.
- **crow.output[2/4].action**: declarative envelope shape for crow outputs 2 and 4. The `dyn{attack=1}` and `dyn{release=1}` are placeholders that the per-cell crow dispatchers override at trigger time.

`print('crow re-initialized')` is a confirmation log.

`★ Insight ─────────────────────────────────────`
**The `crow.output[N].action` syntax** is crow's declarative envelope DSL. `{to(5, dyn{attack=1}), to(0, dyn{release=1})}` reads: "go to 5V over `dyn.attack` seconds, then go to 0V over `dyn.release` seconds." The `dyn` namespace is for "dynamic" variables — per-shot params that get set at trigger time (in cell_roles.lua's crow dispatcher: `crow.output[2].dyn.attack = (seq() % 32 + 1) / 40`).

**`crow.ii.pullup(true)` is one of those settings that's easy to forget but matters.** Some scripts skip it; their users hit intermittent ii failures and don't know why. Always enable pullup if you're using crow's ii.
`─────────────────────────────────────────────────`

## Loading a `.txt` file into history

```lua
local function load_text_file(path)
    if path == nil or path == '' or path == '-' then return end
    io.input(path)
    for line in io.lines() do
        if #line > 0 then
            Sequencer.add_history(line)
        end
    end
    grid_dirty = true
    redraw()
end
```

**Lines 121-131**: load a .txt file into history.

- **Guard** against nil/empty/"-" paths.
- **`io.input(path)`** opens the file as the default input.
- **`io.lines()`** iterates each line. For each non-empty line, call `Sequencer.add_history(line)` (which fires the on_history_changed hook so cell string params refresh).
- **`grid_dirty = true`** + **`redraw()`** to refresh the screen showing the new history.

Called from the `text_file` file-load param action (in add_params).

## The USB-keyboard text-input handler

```lua
keyboard.char = function(character)
    if #displayed_string < 200 then
        displayed_string = displayed_string .. character
    end
end
```

**Lines 137-141**: handle character input. `keyboard.char` fires for every typed character. Append to `displayed_string` if under the 200-char cap.

```lua
keyboard.code = function(code, val)
    if val == 0 then return end
    if code == 'BACKSPACE' then
        displayed_string = displayed_string:sub(1, -2)
    elseif code == 'UP' then
        if #history == 0 then return end
        if new_line then
            history_index = #history - 1
            new_line = false
        else
            history_index = util.clamp(history_index - 1, 0, #history)
        end
        displayed_string = history[history_index + 1] or ""
    elseif code == 'DOWN' then
        if #history == 0 or history_index == nil then return end
        history_index = util.clamp(history_index + 1, 0, #history)
        if history_index == #history then
            displayed_string = ""
            new_line = true
        else
            displayed_string = history[history_index + 1] or ""
        end
    elseif code == 'ENTER' and #displayed_string > 0 then
        my_string = displayed_string
        Sequencer.add_history(displayed_string)
        displayed_string = ""
        history_index = #history
        new_line = true
        grid_dirty = true
    elseif keyboard.ctrl() then
        Sequencer.remove_last_history()
        history_index = #history
        displayed_string = ""
        grid_dirty = true
    end
end
```

**Lines 143-181**: handle special keys + Ctrl chord.

`keyboard.code` fires for special keys (arrows, ENTER, BACKSPACE, etc.). `val == 0` is key-release; we act on press only (`val == 1` or `val == 2` for repeat).

- **BACKSPACE**: trim the last character.
- **UP**: scroll history backward. The `new_line` branch handles the special case where the user just hit ENTER — jump back to the last history line rather than incrementing from the post-end position.
- **DOWN**: scroll forward. At end-of-history, set `new_line = true` (next UP returns to history).
- **ENTER**: stage `displayed_string`, add to history, clear, jump to end.
- **Ctrl chord** (Ctrl-anything): remove last history entry. This is the "oops, I made a typo in the last line" undo.

`★ Insight ─────────────────────────────────────`
**The `new_line` flag** handles the "post-end-of-history" position. Without it, hitting UP at the end would scroll to one-before-end (correct) but then DOWN would scroll back to one-after (wrong — there's nothing there). The `new_line` state distinguishes "at the past-the-end position" from "at the last history item."

**Keyboard.ctrl()** detects if any Ctrl key is currently pressed. Used as a modifier: any keypress with Ctrl held becomes a Ctrl chord. The script's Ctrl chord is "delete last history" — a non-mouse-friendly action that benefits from a dedicated key combo.
`─────────────────────────────────────────────────`

## Mapping grid cells to their state params

```lua
local function state_param_id_for(x, y)
    if y == 2 then
        return 'cell_' .. x .. '_2_state'
    elseif y == 4 then
        if x % 2 == 1 then return 'sampler_' .. math.floor((x + 1) / 2) .. '_state' end
        return 'cell_' .. x .. '_' .. y .. '_state'
    elseif y == 6 then
        if x % 2 == 1 then return 'sampler_' .. (math.floor((x + 1) / 2) + 8) .. '_state' end
        return 'cell_' .. x .. '_' .. y .. '_state'
    elseif y == 8 then
        if x <= 13 then return 'oneshot_' .. x .. '_state'
        elseif x == 14 then return 'mic_to_delay_state'
        elseif x == 15 then return 'granular_out_state'
        elseif x == 16 then return 'mic_dry_state'
        end
    end
    return nil
end
```

**Lines 193-210**: map a toggle-row grid cell to its corresponding state param.

The mapping:
- **Row 2**: `cell_X_2_state` (16 of these).
- **Row 4 odd cols**: `sampler_N_state` where N = 1-8.
- **Row 4 even cols**: `cell_X_4_state` (rate cells).
- **Row 6 odd cols**: `sampler_N_state` where N = 9-16.
- **Row 6 even cols**: `cell_X_6_state` (rate cells).
- **Row 8 cols 1-13**: `oneshot_N_state` where N = col.
- **Row 8 col 14**: `mic_to_delay_state`.
- **Row 8 col 15**: `granular_out_state`.
- **Row 8 col 16**: `mic_dry_state`.

Used by `g.key` (route press through param) and `panic` (clear UI state).

## The grid handler (`g.key`)

```lua
g.key = function(x, y, z)
    Sequencer.Momentary[x][y] = (z == 1)
    grid_dirty = true

    if y == 1 then
        if x + 16 * (y - 1) > #history then return end
        if z == 1 then
            my_string = displayed_string .. history[x + 16 * (y - 1)]
            displayed_string = my_string
        else
            local any_held = false
            for col = 1, 16 do
                if Sequencer.Momentary[col][1] then any_held = true; break end
            end
            if any_held then return end
            if #displayed_string > 0 then
                my_string = displayed_string
            end
            displayed_string = ""
            new_line = true
        end

    elseif y == 2 or y == 4 or y == 6 or y == 8 then
        if z == 1 then
            local state_id = state_param_id_for(x, y)
            if state_id then
                local cur = params:get(state_id) or 1
                params:set(state_id, (cur == 1) and 2 or 1)
            else
                Sequencer.Toggled[x][y] = not Sequencer.Toggled[x][y]
            end
        end

    elseif y == 3 or y == 5 or y == 7 then
        if z == 1 then
            if #my_string > 0 then
                Sequencer.assign(x, y - 1, my_string)
            end
        end
    end
end
```

**Lines 212-264**: the grid handler. Brief annotation:

- **Always**: update Momentary, mark grid dirty.
- **Row 1 (history)**: press → append history line to displayed_string. Release → if no other row-1 button held, stage the staged string.
- **Rows 2, 4, 6, 8 (toggle rows)**: press → route through state param (which fires the param's action, writing Toggled + any side effects). Fallback for rate cells without state params: direct Toggled write.
- **Rows 3, 5, 7 (assign rows)**: press → assign my_string to cell above.

The state-param routing is what makes grid presses equivalent to params menu actions or MIDI mapping. Single source of truth.

## Rendering the grid

```lua
function grid_redraw()
    if g == nil then return end
    g:all(0)
    for x = 1, 16 do
        local idx = x
        if idx <= #history then
            g:led(x, 1, 4)
        end
        if Sequencer.Momentary[x][1] then
            g:led(x, 1, 15)
        end
    end
    for x = 1, 16 do
        for y = 2, 8, 2 do
            if Sequencer.Toggled[x][y] then
                local level = Sequencer.Paused and 6 or 15
                g:led(x, y, level)
            end
            if Sequencer.Momentary[x][y] then
                g:led(x, y, 15)
            end
        end
    end
    for x = 1, 16 do
        for y = 3, 7, 2 do
            g:led(x, y, 4)
            if Sequencer.Momentary[x][y] then
                g:led(x, y, 15)
            end
        end
    end
    g:refresh()
end
```

**Lines 270-306**: render the grid state.

Three iteration blocks:

1. **Row 1 (history)**: for each col, if a history slot exists, light at level 4. If currently held (momentary), bright at level 15.
2. **Rows 2, 4, 6, 8 (toggle rows)**: if Toggled, light at level 15 (or 6 if Paused). Momentary overrides to 15.
3. **Rows 3, 5, 7 (assign rows)**: always-on dim (level 4). Momentary brightens.

The "Paused dims to 6" trick visually reflects pause state on the grid — toggled cells stay visible but dim.

`g:refresh()` pushes the LED state to the hardware. Without it, the LED changes don't appear.

Called from a 30 fps metro (in init).

## Rendering the screen

```lua
function redraw()
    screen.clear()
    screen.aa(0)
    screen.line_width(1)
    screen.level(10)

    screen.rect(2, 50, 125, 14)
    screen.stroke()
    screen.move(5, 59)
    screen.text("> " .. displayed_string)

    for i = 1, 5 do
        if not (history_index - i >= 0) then break end
        screen.level(i == 1 and 15 or 4)
        screen.move(5, 55 - 10 * i)
        screen.text(history[history_index - i + 1] or "")
    end
    screen.level(10)

    screen.update()
end
```

**Lines 312-335**: render the screen.

- **`screen.clear()`** wipes.
- **`screen.aa(0)`** turns OFF anti-aliasing (sharper text on Norns's small screen).
- **`screen.rect(2, 50, 125, 14) + stroke()`** draws the input box at the bottom.
- **`screen.text("> " .. displayed_string)`** renders the live typing buffer inside the box.
- **History scroll loop**: 5 most-recent history items above the input box. The line at history_index (i==1) draws brighter (level 15); others dim (level 4).
- **`screen.update()`** pushes to hardware.

Called from a 15 fps metro (in init).

## The comprehensive panic

```lua
local function panic()
    for x = 1, 16 do
        for y = 2, 8, 2 do
            local state_id = state_param_id_for(x, y)
            if state_id then
                params:set(state_id, 1)
            else
                Sequencer.Toggled[x][y] = false
            end
        end
    end
    Roles.free_all()
    Roles.looper_running = {}
    engine.set_mic_amp(0)
    engine.set_mic_dry_amp(0)
    engine.set_granular_out_amp(0)
    engine.set_fb_amp(0)
    engine.free_granular()
    engine.silence_all_samplers()
    engine.silence_all_oneshots()
    crow.ii.jf.run(0)
    crow.ii.wtape.play(0)
    for n = 1, 4 do
        crow.output[n].volts = 0
    end
    Midi.all_notes_off()
    grid_dirty = true
    print('PANIC: silenced everything')
end
```

**Lines 341-389**: silence everything. Comprehensive teardown of all in-flight state.

Walking through:

1. **Clear all toggle states** via params:set (so the params menu reflects "off" alongside the grid LEDs).
2. **`Roles.free_all()`** — free every allocated SC voice instance. Subsequent triggers will lazily re-allocate.
3. **`Roles.looper_running = {}`** — clear the w/tape looper re-entry guard table.
4. **Zero all granular amps** via engine commands.
5. **`engine.free_granular()`** — tear down the entire granular chain (frees ~50-70% baseline CPU).
6. **`silence_all_samplers / oneshots`** — hard-stop in-flight sample playback via `resetVoices`.
7. **`crow.ii.jf.run(0)`** — stop JF.
8. **`crow.ii.wtape.play(0)`** — stop w/tape playback.
9. **Zero crow CV outputs** — final-position guarantee.
10. **`Midi.all_notes_off()`** — send note_off for every tracked active MIDI note.
11. **`grid_dirty = true`** — repaint.

The function is intentionally comprehensive. Anything that could be making sound or sending control gets silenced.

`★ Insight ─────────────────────────────────────`
**Panic ordering matters for some operations.** Free granular chain BEFORE the amp settings persist (otherwise the amps stay at 0 in the kernel's pending values, and the next toggle would re-allocate with amp = 0 = silent). Clearing Roles.allocated lets subsequent triggers re-allocate; without it, role-change detection would think voices were still allocated and skip the alloc.

**w/syn and w/del aren't silenced** because they don't expose direct silence commands. The comment notes this — their voices decay via internal envelopes. Clearing toggles is the main mitigation (no new triggers reach them).

**The print at the end** is the "panic happened" log marker. Useful for debugging — if a fire happens after panic, the timestamp tells you whether it predates or postdates the panic.
`─────────────────────────────────────────────────`

## Hardware keys and encoders

```lua
function key(n, z)
    if z == 0 then return end

    if n == 2 then
        if #history > 0 and history_index >= 1 and history_index <= #history then
            my_string = displayed_string .. history[history_index]
            displayed_string = my_string
            grid_dirty = true
        end

    elseif n == 3 then
        if #displayed_string > 0 then
            my_string = displayed_string
            table.insert(history, displayed_string)
            displayed_string = ""
            history_index = #history
            new_line = true
            grid_dirty = true
        end
    end
end

function enc(n, d)
    if n == 1 then
        if #history == 0 then return end
        if new_line and d < 0 then
            history_index = #history - 1
            new_line = false
        else
            history_index = util.clamp(history_index + d, 0, #history)
        end
        if history_index == #history then
            displayed_string = ""
            new_line = true
        else
            displayed_string = history[history_index + 1] or ""
            new_line = false
        end
        grid_dirty = true

    elseif n == 2 then
        params:delta('global_amp', d)

    elseif n == 3 then
        params:delta('clock_tempo', d)
    end
end
```

**Lines 391-449**: hardware key + encoder handlers.

`key(n, z)`:
- `n` = which key (1, 2, or 3); `z` = state (0 = release, 1 = press).
- Act on press only (`if z == 0 then return end`).
- **K1**: unhandled. Preserves Norns's system-level "long-press K1 to exit" behavior.
- **K2**: append currently-highlighted history line to displayed_string. Mirrors row-1 grid press semantics.
- **K3**: ENTER. Stage displayed_string + add to history + clear + jump to end.

`enc(n, d)`:
- `n` = encoder (1, 2, or 3); `d` = delta (-1 or 1 typically, larger if user spins fast).
- **E1**: scroll history. Same logic as keyboard UP/DOWN, applied to the delta. The `new_line and d < 0` branch handles the "post-end-of-history" jump-back-to-last case.
- **E2**: adjust global amp via `params:delta`. (params:delta is the canonical way to map an encoder to a param — handles controlspec step + min/max correctly.)
- **E3**: adjust BPM.

## Global randomize

```lua
local function global_randomize()
    local ok, VoiceParams = pcall(require, 'lib/voice_params')
    if not ok then
        print('global_randomize: lib/voice_params not yet present, skipping')
        return
    end
    for x = 1, 16 do
        VoiceParams.randomize_row2_cell(x)
    end
    for slot = 1, 16 do
        VoiceParams.randomize_sampler(slot)
    end
    for slot = 1, 13 do
        VoiceParams.randomize_oneshot(slot)
    end
    VoiceParams.randomize_granular()
    print('global randomize complete')
end
```

**Lines 461-472**: randomize every cell + sampler + one-shot + granular. Used by the global_randomize trigger param.

The `pcall(require, ...)` is defensive against an early-development state where voice_params didn't yet exist. In current builds it always succeeds.

Iterates all randomizable surfaces, calling each module's randomize function. Results in a wholesale parameter shuffle.

## `add_params`: the big params declaration block

The biggest single block in the file (737 lines). It declares every parameter in the script. The structure is:

```lua
local function add_params()
    params:add_separator('schicksalslied_top', 'SCHICKSALSLIED')
    params:add_group('global', 'global', 9)
    -- 9 global params: clock_source (Norns built-in), text_file, panic_trigger,
    -- global_amp, global_randomize, scale_mode, root_note, master_amps (3 via Grain)
    
    params:add_group('crow', 'crow', 10)
    -- crow + w/syn + w/del + JF global config
    
    params:add_group('midi', 'midi', 3)
    -- midi_device, midi_gate_time, midi_note_off_delay
    
    params:add_group('midi_input', 'midi input', 28)
    -- MIDI keyboard input config: device, channel, role, plus per-role voice params
    
    params:add_group('master_fx', 'master fx', 9)
    -- delay_sync, delay_time, delay_decay, delay_amp, delay_to_reverb_send,
    -- delay_to_dry_send, reverb_room, reverb_damp, reverb_amp
    
    Grain.add_params()
    -- granular delay group: 30 params (see grid_grain_params.lua.md)
    
    params:add_group('row_2_cells', 'synths', 16 * 48 + 4)
    -- 16 row-2 voice cells, ~48 params each, via VoiceParams.add_row2_cell_block
    
    params:add_group('samplers', 'looping samplers', 16 * 89 + 4)
    -- 16 sampler slots, ~89 params each, via VoiceParams.add_sampler_block
    --   + add_cell_seq_mode_block + add_cell_value_mode_block (twice for pos/dur)
    --   + add_rate_cell_state_block + add_cell_value_mode_block (rate)
    --   + add_cell_string_block (twice for trigger + rate cells)
    
    params:add_group('one_shot_samplers', 'one-shot samplers', 13 * 44 + 2)
    -- 13 one-shot slots, ~44 params each
    
    LiedLfos.add_row_2_lfos_group()    -- 160 LFOs for row-2 cells
    LiedLfos.add_sampler_lfos_group()  -- 64 sampler LFOs
    LiedLfos.add_oneshot_lfos_group()  -- 52 one-shot LFOs
    LiedLfos.add_crow_lfos_group()     -- 6 crow/w-device LFOs
end
```

The full block is 737 lines because each per-cell / per-slot / per-LFO declaration is several lines of `params:add{...}` syntax.

### Annotated key blocks

**Global group** — the script-wide params:

```lua
params:add_group('global', 'global', 9)
params:add{
    type = 'file', id = 'text_file', name = 'text file',
    path = norns.state.path .. 'lib/text files/',
    action = load_text_file,
}
params:add{
    type = 'trigger', id = 'panic_trigger', name = 'panic',
    action = panic,
}
params:add{
    type = 'control', id = 'global_amp', name = 'global amp',
    controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
    action = function(v) engine.set_out_amp(v) end,
}
params:add{
    type = 'trigger', id = 'global_randomize', name = 'global randomize',
    action = global_randomize,
}
params:add{
    type = 'option', id = 'scale_mode', name = 'scale',
    options = (function() ... build scale name list ... end)(),
    default = 1,
}
params:add{
    type = 'number', id = 'root_note', name = 'root',
    min = 1, max = 12, default = 1,
    formatter = function(p) return ({'C','C#','D','D#','E','F','F#','G','G#','A','A#','B'})[p:get()] end,
}
```

Key things:

- **`type = 'file'`** opens a file picker rooted at the given path. The action receives the selected path.
- **`type = 'trigger'`** is a button. The action fires when the user "presses" the param.
- **`type = 'option'`** with dynamically-built options list: the scale name list is built via an IIFE that enumerates `MusicUtil.SCALES`.
- **`formatter` function for `root_note`** converts the integer to a note name for display.

**Delay sync param** (in master_fx group):

```lua
local DELAY_SYNC_LABELS = {
    'free', '1/16', '1/12', '1/8', '1/6', '3/16', '1/4', '1/3', '3/8',
    '1/2', '2/3', '3/4', '1', '4/3', '3/2', '2', '8/3', '3', '4', '5',
    '6', '7', '8',
}
local DELAY_SYNC_BEATS = {
    1/16, 1/12, 1/8, 1/6, 3/16, 1/4, 1/3, 3/8,
    1/2, 2/3, 3/4, 1, 4/3, 3/2, 2, 8/3, 3, 4, 5,
    6, 7, 8,
}
params:add{
    type = 'option', id = 'delay_sync', name = 'delay sync',
    options = DELAY_SYNC_LABELS, default = 1,
    action = function(idx)
        if idx == 1 then
            params:show('delay_time')
            engine.set_delay_time(params:get('delay_time'))
        else
            params:hide('delay_time')
            local beats = DELAY_SYNC_BEATS[idx - 1]
            engine.set_delay_time(beats * clock.get_beat_sec())
        end
        _menu.rebuild_params()
    end,
}
```

The delay sync param: option 1 is "free" (uses delay_time directly); options 2+ map to beat multiples. The action computes the actual delay time and sends to the engine. Detailed in chapter 11 of the conceptual tutorial.

**The cell-block loops** (row 2, samplers, one-shots) follow a consistent pattern:

```lua
params:add_group('row_2_cells', 'synths', 16 * 48 + 4)
for x = 1, 16 do
    params:add_separator('row_2_cell_' .. x .. '_separator', 'cell ' .. x)
    VoiceParams.add_row2_cell_block(x)
end
```

For each cell: add a visual separator with the cell number, then call the block helper from voice_params. The block helper does all the heavy lifting (adding ~48 params per call).

Samplers are more elaborate because each sampler slot has multiple param categories:

```lua
params:add_group('samplers', 'looping samplers', 16 * 89 + 4)
for slot = 1, 16 do
    -- Map slot → trigger cell coords
    local trigger_col, trigger_row
    if slot <= 8 then
        trigger_col, trigger_row = (slot * 2) - 1, 4
    else
        trigger_col, trigger_row = ((slot - 8) * 2) - 1, 6
    end
    local rate_col = trigger_col + 1  -- rate cell is immediately to the right
    
    params:add_separator('sampler_' .. slot .. '_separator', 'looping sampler ' .. slot)
    
    -- File param (using sampler_load engine command)
    params:add{
        type = 'file', id = 'sampler_' .. slot .. '_file', name = 'looping sampler ' .. slot .. ' file',
        path = norns.state.path .. 'audio/',
        default = '-',
        action = function(path)
            if check_sample_duration('Sampler', slot, path) then
                engine.sampler_load(slot, path)
                VoiceParams.reapply_sampler(slot)
            end
        end,
    }
    
    -- Voice params (9-ish via add_sampler_block)
    VoiceParams.add_sampler_block(slot)
    
    -- Sequencer params for trigger cell (15 via add_cell_seq_mode_block)
    params:add_separator(..., 'trigger cell sequencer')
    VoiceParams.add_cell_seq_mode_block(trigger_col, trigger_row)
    
    -- Value-mode params for trigger cell (position, duration)
    params:add_separator(..., 'trigger cell position')
    VoiceParams.add_cell_value_mode_block(trigger_col, trigger_row, 'position', 0, 1)
    params:add_separator(..., 'trigger cell duration')
    VoiceParams.add_cell_value_mode_block(trigger_col, trigger_row, 'duration', 0, 1)
    
    -- Cell string param for trigger cell
    VoiceParams.add_cell_string_block(trigger_col, trigger_row)
    
    -- Rate cell state + seq + value + string
    VoiceParams.add_rate_cell_state_block(rate_col, trigger_row)
    VoiceParams.add_cell_seq_mode_block(rate_col, trigger_row)
    VoiceParams.add_cell_value_mode_block(rate_col, trigger_row, 'rate', 0, 1)
    VoiceParams.add_cell_string_block(rate_col, trigger_row)
end
```

Each sampler slot accumulates: 1 file param + 9 sampler params + 15 seq_mode + 13×2 value_mode (position + duration) + 1 string + 1 rate state + 15 rate seq_mode + 13 rate value_mode + 1 rate string = **~89 params per slot**. Times 16 slots = ~1,420 params for samplers alone.

One-shots are slightly simpler — no separate trigger/rate cell, just one set of params per slot: ~44 params per slot × 13 slots = ~570 params.

The file action calls `check_sample_duration` (section 2 of this chapter) BEFORE sending to the engine, and `VoiceParams.reapply_sampler(slot)` AFTER (to push current param values to the freshly-allocated SC voice).

`★ Insight ─────────────────────────────────────`
**Total param count estimate**:
- 9 global + 10 crow + 3 midi + 28 midi_input + 9 master_fx + 30 granular = 89 globals.
- 16 row-2 cells × ~48 params = 768.
- 16 samplers × ~89 = ~1,424.
- 13 one-shots × ~44 = ~572.
- 282 LFOs × ~16 sub-params each = ~4,512.
- **Total: ~7,300 params.**

That's a massive params surface. The group structure is what makes it navigable. Without `params:add_group`, all 7,300 would be one flat list. With it, the user navigates: PARAMETERS → looping samplers → sampler 3 → cutoff. Clear, scannable.

**`params:bang()` at the end of init (covered next)** fires every action with the current value — 7,300+ action calls. Each action does one OSC dispatch. That's ~7,300 OSC messages in a few hundred milliseconds. Norns handles it.
`─────────────────────────────────────────────────`

## `init` — the orchestration

This is THE most important function in the file. It wires every module together. 

```lua
function init()
    Sequencer.init()
    Roles.init()
    Roles.Sequencer = Sequencer
    Sequencer.dispatch_fn = function(x, y) Roles.dispatch(x, y) end
```

**Lines 1214-1217**: build internal state. The Sequencer + Roles modules' init functions populate their state tables. Then wire them: `Roles.Sequencer = Sequencer` lets Roles read Sequencer state; `Sequencer.dispatch_fn = ...` lets Sequencer call into Roles.

```lua
    _G.GlobalSequencer = Sequencer
    _G.GlobalRoles = Roles
    Sequencer.history = history
    do
        local VoiceParams = include 'lib/voice_params'
        VoiceParams.bind_sequencer(Sequencer)
    end
```

**Lines 1219-1227**: expose canonical globals + alias history + install voice_params hooks.

- **`_G.GlobalSequencer = Sequencer`** — the cross-include identity workaround (chapter 09). Anywhere in the codebase that needs the canonical Sequencer reads `_G.GlobalSequencer`.
- **`_G.GlobalRoles = Roles`** — same for Roles.
- **`Sequencer.history = history`** — alias the file-local history table into Sequencer. They now share the same table.
- **`VoiceParams.bind_sequencer(Sequencer)`** — install on_history_changed_fn / on_cell_assigned_fn hooks. After this, history mutations refresh cell string param options; cell assignments refresh per-cell param displays.

The `do ... end` block scopes the local VoiceParams reference so it doesn't pollute outer scope.

```lua
    add_params()
```

**Line 1230**: declare all params. After this, the params menu has its full surface.

```lua
    local function sidecar_path(pset_filename)
        return pset_filename .. '.lieddata'
    end
    params.action_write = function(filename, _name, _pset_number)
        local data = {
            history = history,
            assigned = Sequencer._cell_assigned_strings,
        }
        tab.save(data, sidecar_path(filename))
    end
    params.action_read = function(filename, _silent, _pset_number)
        local path = sidecar_path(filename)
        local data = util.file_exists(path) and tab.load(path) or nil
        if type(data) == 'table' then
            for i = #history, 1, -1 do history[i] = nil end
            if type(data.history) == 'table' then
                for i, s in ipairs(data.history) do history[i] = s end
            end
            history_index = #history
            for k in pairs(Sequencer._cell_assigned_strings) do
                Sequencer._cell_assigned_strings[k] = nil
            end
            if type(data.assigned) == 'table' then
                for k, s in pairs(data.assigned) do
                    local cx, cy = k:match('^(%d+)_(%d+)$')
                    if cx and cy then
                        Sequencer.assign(tonumber(cx), tonumber(cy), s, true)
                    end
                end
            end
        end
        local VoiceParams = include 'lib/voice_params'
        VoiceParams.refresh_all_cell_string_params()
        grid_dirty = true
    end
    params.action_delete = function(filename, _name, _pset_number)
        local path = sidecar_path(filename)
        if util.file_exists(path) then os.execute('rm "' .. path .. '"') end
    end
```

**Lines ~1233-1273**: PSET sidecar hooks. Detailed below in this section.

The hooks save/restore `history` + `_cell_assigned_strings` alongside the PSET file via a `.lieddata` sidecar. Without this, PSET load would drop those tables (since they're script-side state, not params).

In-place table mutation for `history` is critical: reassigning the local would orphan the `Sequencer.history` alias.

```lua
    params:bang()
```

**Line ~1275**: fire every param action with its current value. This is what pushes all the default + restored values to SC and to the rest of the script.

```lua
    engine.set_beat_sec(clock.get_beat_sec())
    do
        local prior = params:lookup_param('clock_tempo').action
        params:set_action('clock_tempo', function(bpm)
            if prior then prior(bpm) end
            engine.set_beat_sec(clock.get_beat_sec())
            if params.lookup['delay_sync'] ~= nil and params:get('delay_sync') ~= 1 then
                params:set('delay_sync', params:get('delay_sync'))
            end
        end)
    end
```

**Lines ~1278-1289**: capture-then-chain the clock_tempo action. Covered in chapter 13. The new action: call the original (updates the actual matron clock) + push beat_sec to SC + re-fire delay_sync to recompute synced delay time.

```lua
    Midi.init()
    MidiInput.init()
```

**Lines ~1291-1292**: initialize MIDI modules. They connect to vports and register event handlers.

```lua
    for x = 1, 16 do
        local role_idx = params:get('cell_' .. x .. '_2_role')
        params:set('cell_' .. x .. '_2_role', role_idx)
    end
    for y = 2, 8, 2 do
        local max_x = (y == 8) and 13 or 16
        for x = 1, max_x do
            local mode_idx = params:get('cell_' .. x .. '_' .. y .. '_seq_mode')
            params:set('cell_' .. x .. '_' .. y .. '_seq_mode', mode_idx)
        end
    end
    for y = 4, 6, 2 do
        for x = 1, 15, 2 do
            for _, kind in ipairs({ 'position', 'duration' }) do
                local pid = 'cell_' .. x .. '_' .. y .. '_' .. kind .. '_mode'
                params:set(pid, params:get(pid))
            end
        end
        for x = 2, 16, 2 do
            local pid = 'cell_' .. x .. '_' .. y .. '_rate_mode'
            params:set(pid, params:get(pid))
        end
    end
    for x = 1, 13 do
        local pid = 'cell_' .. x .. '_8_rate_mode'
        params:set(pid, params:get(pid))
    end
```

**Lines ~1294-1320**: force visibility refresh on every mode-driven param.

`params:bang()` fires all actions, BUT the visibility logic depends on the order of param declaration and on `_menu.rebuild_params()` being called after all the show/hide calls. To ensure initial visibility is correct, we re-fire each mode action explicitly with `params:set(pid, params:get(pid))` — this re-runs the action and triggers a visibility refresh.

```lua
    Sequencer.start_all_clocks()
```

**Line ~1323**: spawn the 64 per-cell clock coroutines. The sequencer is now live.

```lua
    screen_metro = metro.init()
    screen_metro.time = 1/15
    screen_metro.event = function() redraw() end
    screen_metro:start()
    
    grid_metro = metro.init()
    grid_metro.time = 1/30
    grid_metro.event = function()
        if grid_dirty then
            grid_redraw()
            grid_dirty = false
        end
    end
    grid_metro:start()
    
    fire_decay_metro = metro.init()
    fire_decay_metro.time = 1/15
    fire_decay_metro.event = function()
        for x = 1, 16 do
            for y = 2, 8, 2 do
                if Sequencer.Fire_Decay[x][y] > 0 then
                    Sequencer.Fire_Decay[x][y] = Sequencer.Fire_Decay[x][y] - 1
                    grid_dirty = true
                end
            end
        end
    end
    fire_decay_metro:start()
```

**Lines ~1325-1355**: set up the three metros.

- **`screen_metro`** at 15 fps: calls `redraw` unconditionally. (The redraw itself is fast; no dirty-flag optimization needed at 15 fps.)
- **`grid_metro`** at 30 fps: calls `grid_redraw` only if `grid_dirty`. Dirty-flag optimization saves redraws when nothing's changed.
- **`fire_decay_metro`** at 15 fps: decrements per-cell fire-decay counters by 1 per frame. When a counter hits 0, the LED returns to normal brightness.

```lua
    crow_reinit()
    print('schicksalslied 2.0 ready')
end
```

**Lines ~1357-1359**: initialize crow and log readiness.

## `cleanup` — symmetric teardown

```lua
function cleanup()
    Sequencer.stop_all_clocks()
    Roles.free_all()
    if screen_metro then screen_metro:stop() end
    if grid_metro then grid_metro:stop() end
    if fire_decay_metro then fire_decay_metro:stop() end
    MidiInput.cleanup()
    crow.ii.jf.run(0)
    print('schicksalslied 2.0 cleanup complete')
end
```

**Lines 1399-1407**: symmetric teardown.

- Stop all clock coroutines.
- Free all SC voice instances.
- Stop the three metros (with `if` guards in case init failed early).
- Clean up MIDI input.
- Stop JF.
- Log.

The kernel's `free` method is called separately by Norns (when the engine is unloaded). It tears down all SC-side state (groups, buses, granular chain, etc.).

`★ Insight ─────────────────────────────────────`
**Symmetric init/cleanup is critical for clean script reloads.** Every metro, coroutine, voice instance, and MIDI subscription started in `init` must be stopped in `cleanup`. Missing one means resource leaks across reloads — eventually you'd exhaust matron's coroutine pool or SC's node count.

**The `if metro then metro:stop() end` guards** handle the rare case where init failed before creating the metros. Without the guards, cleanup would error on the nil metro reference. Defensive but cheap.
`─────────────────────────────────────────────────`

## Summary

`schicksalslied.lua` is 1,407 lines, but the line count is mostly in the repetitive `add_params` block — the architecturally meaningful surface is much smaller:

- ~100 lines of helpers (file_duration, crow_reinit, load_text_file).
- ~120 lines of input handlers (keyboard, g.key, state_param_id_for).
- ~80 lines of rendering (grid_redraw, redraw).
- ~50 lines of panic.
- ~50 lines of key/enc/global_randomize.
- ~740 lines of add_params (mostly delegating to voice_params and granular helpers).
- ~180 lines of init (the most important block).
- ~10 lines of cleanup.

The patterns to internalize:

- **Cross-include identity workaround**: `_G.GlobalSequencer` + `_G.GlobalRoles` set in init.
- **State + amp pair pattern**: grid presses route through state params; state actions gate amps.
- **`state_param_id_for(x, y)`** as the single source-of-truth mapping from grid cell to param ID.
- **PSET sidecar via params.action_write/read/delete**: persist non-param script state.
- **Capture-then-chain for built-in actions**: clock_tempo.action wrapper.
- **Force-refresh after bang**: explicit re-fire of every mode action to set initial visibility correctly.
- **Three metros for UI**: separate cadences for screen, grid, fire-decay.
- **`engine.name = 'Lied'` at file top**: not inside init.
- **Comprehensive panic**: every source of sound and control is silenced explicitly.

For modifying this file:
- Adding a new global param → add inside `params:add_group('global', ...)`.
- Adding a new sampler param → add to `voice_params.lua:add_sampler_block` (NOT here).
- Adding a new init step → place it in the right ordering position in init().
- Adding a new panic target → add a line to panic().
- Adding a new metro → declare at top, init in init(), stop in cleanup().

The file is the integration point. Everything else slots in.
