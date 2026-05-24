# Chapter 11 — `lib/sequencer.lua`

The per-cell Sequins state + clock-loop module. **485 source lines.** This is the layer that turns "text + clock" into "music."

The chapter has two main jobs. The first is to define the per-cell state that everything else in the Lua side reads from: a Sequins per cell holding the cell's text-as-bytes, plus tables for toggle state, momentary state, clock IDs, and fire-decay timers. The second job is the more architecturally interesting one — wiring up 64 simultaneous clock coroutines (one per toggle cell across rows 2, 4, 6, 8), each stepping through its assigned text at its own per-cell rate, dispatching to its role on every fire.

Along the way we'll hit the script's most non-obvious timing technique: the choice between **absolute** beat-grid sync (used by lied/fixed modes) and **relative** gap-based sync (used by user_seq/random). The bug this distinction solves — overlapping sequences with surprising rhythm — is documented inline so you can verify the fix from first principles.

This chapter assumes chapter 09's coverage of `clock.run`, `clock.sync(rate)`, and the sequins library. The SC side from chapters 01-08 should be complete by now.

## Header and imports

```lua
-- lib/sequencer.lua — schicksalslied 2.0 per-cell sequins + clock-loop state

local Sequins = require 'sequins'
local Timing = include 'lib/timing'

local Sequencer = {}
```

**Lines 1-7**: file header + two imports.

- **`require 'sequins'`** uses standard Lua `require` (cached). Sequins is a system library on Norns. The require returns the constructor function.
- **`include 'lib/timing'`** uses Norns's non-caching include. Returns the `Timing` module table. Used for `Timing.value(idx)`, `Timing.rate_value(idx)`, `Timing.OPTIONS`, `Timing.RATE_OPTIONS`.

`Sequencer = {}` starts the module table. Subsequent code adds fields directly.

`★ Insight ─────────────────────────────────────`
**Note the asymmetry**: `Sequins` uses `require` (cached), `Timing` uses `include` (re-execute every call). The choice matches each library's role:
- `Sequins` is a foundational library — same instance everywhere is fine.
- `Timing` is a project-local module that we might want to hot-reload during development.

Both work for the script's purposes; the choice is about each module's lifecycle expectation, not a correctness requirement.
`─────────────────────────────────────────────────`

## The per-cell state tables

```lua
-- ========================================================================
-- PER-CELL STATE TABLES (indexed [x][y])
-- ========================================================================

-- Per-cell sequins (raw ASCII byte values). Indexed Seq[x][y].
Sequencer.Seq = {}

-- Per-cell toggle state. True = cell is "on" (fires on its clock divisions).
Sequencer.Toggled = {}

-- Per-cell momentary state (grid press currently held). Used by grid_redraw for hold-brightness.
Sequencer.Momentary = {}

-- Per-cell clock loop ID (returned by clock.run). Indexed Clock_Ids[x][y].
Sequencer.Clock_Ids = {}

-- Per-cell fire decay counter. Set to 4 on each fire; decremented every screen tick to produce the LED flash.
Sequencer.Fire_Decay = {}

-- Global pause flag. K2 toggles this via Sequencer.toggle_pause (clock-quantized).
Sequencer.Paused = false
Sequencer.Pause_Pending = false
Sequencer.Unpause_Pending = false
```

**Lines 15-37**: five table-of-tables for per-cell state + three boolean flags for global pause logic. The state tables are indexed `[x][y]`; init builds them out to cover all 128 cells.

Each table's role:

- **`Seq`** — Sequins instances. The byte-stream-driven state that role dispatchers read on every fire.
- **`Toggled`** — logical "on/off" for each cell. The clock loop checks this on each tick.
- **`Momentary`** — physical "button currently held." Distinct from Toggled because the grid handler updates both: Toggled flips on press; Momentary tracks the hold.
- **`Clock_Ids`** — the integer IDs returned by `clock.run`. Used by `stop_all_clocks` to cancel coroutines.
- **`Fire_Decay`** — small integer that counts down on each frame, giving LED fire-flash behavior.

The three pause flags are subtly different:

- **`Paused`** — the actual paused state. When true, clock loops fire `clock.sync` but skip dispatch.
- **`Pause_Pending`** — a press is in flight; a clock coroutine will flip `Paused` to true on the next beat boundary.
- **`Unpause_Pending`** — same shape for resume.

The pending flags prevent multiple K2 presses from spawning multiple in-flight transition coroutines.

## Building out the state tables (`Sequencer.init`)

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
    Sequencer._init_seq_modes()
    Sequencer._init_value_modes()
end
```

**Lines 49-66**: build out all five state tables.

The double loop is `x = 1..16` (columns) × `y = 1..8` (rows). For each cell:

- `Sequencer.Seq[x][y] = Sequins({ string.byte(' ') })` — a one-element Sequins containing the byte value of space. This is the "empty" state: an unassigned cell fires `space, space, space, ...` indefinitely.
- The other four state tables initialize to false / nil / 0 as appropriate.

The two trailing calls populate the mode default tables — see sections 9 and 10.

`★ Insight ─────────────────────────────────────`
**Initializing all 128 cells, not just the 64 toggle cells**, is defensive. Momentary rows (1, 3, 5, 7) get full state initialization too — they have `Momentary[x][y]` for press-hold tracking, but their `Toggled` and `Seq` entries are unused. The cost is trivial; the benefit is that any future code that touches a momentary-row cell's tables doesn't have to special-case missing entries.

**The Sequins constructor with a single-byte default** is a critical robustness choice. Without it, a cell with nil Sequins would crash on the first `seq()` call. With the default, it produces a stream of spaces — silent, but not error-producing. Voice dispatchers that map space (byte 32) to a musical value (e.g., `32 % 32 + 49 = 49 = MIDI note 49 = C#3`) will play a low note quietly; not silence, but not chaos either.
`─────────────────────────────────────────────────`

## Converting strings to byte streams

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
```

**Lines 68-83**: a single helper, `string_to_bytes(s)`, that converts a Lua string to an array of byte values.

- **`s == nil or #s == 0`** — guard against nil/empty. Returns the single-space byte placeholder.
- **`string.byte(s, i)`** — returns the byte at position `i` (1-indexed). For ASCII strings each "character" is one byte.

Used by `Sequencer.assign` (next section) when assigning a new string to a cell, and by the PSET sidecar restore (when loading saved cell strings).

For multi-byte / UTF-8 content, each byte becomes a separate sequins entry. This is intentional: the script treats text as a byte stream, not as Unicode characters. ASCII text produces ASCII bytes; UTF-8 text produces UTF-8's variable-length byte sequences, which still drive the sequencer just fine (the bytes happen to fall in higher ranges that wrap around via modulo).

## History + the gridless string-assignment surface

```lua
-- ========================================================================
-- HISTORY + GRIDLESS-FRIENDLY STRING ASSIGNMENT
-- ========================================================================
-- The per-cell `cell_X_Y_string` param can list slots and so post-assignment
-- sync can map a cell's content back to a slot index.
Sequencer.history = {}

-- Per-cell record of the string most recently assigned, keyed by "x_y".
-- Tracks the original string (not the byte sequence) so we can re-resolve
-- which slot the cell points to whenever history changes.
Sequencer._cell_assigned_strings = {}

-- Refresh hook wired by schicksalslied.lua's init. Called whenever history
-- mutates so cell string params can rebuild their option lists.
Sequencer.on_history_changed_fn = nil
```

**Lines 85-100**: three state references.

- **`Sequencer.history`** — the list of typed lines. Aliased into `schicksalslied.lua`'s local `history` table via init's `Sequencer.history = history`. **Both names point at the same table**; mutating one is visible through the other.

- **`Sequencer._cell_assigned_strings`** — a flat hash table keyed by `"x_y"` strings, mapping to the original assigned string. The cell-level `cell_X_Y_string` param uses this to determine what each cell currently plays.

- **`Sequencer.on_history_changed_fn`** — a hook. `voice_params.lua` installs this so the params surface can refresh when history grows or shrinks.

```lua
function Sequencer.add_history(str)
    if str == nil or #str == 0 then return end
    table.insert(Sequencer.history, str)
    if Sequencer.on_history_changed_fn then Sequencer.on_history_changed_fn() end
end

function Sequencer.remove_last_history()
    if #Sequencer.history > 0 then
        table.remove(Sequencer.history, #Sequencer.history)
        if Sequencer.on_history_changed_fn then Sequencer.on_history_changed_fn() end
    end
end
```

**Lines 100-111**: two functions that mutate history. Both fire the hook after mutation (if the hook is installed).

The empty-string guard in `add_history` prevents adding nothing-strings to history (which would crowd the menu and grid row 1 with empty slots).

```lua
-- Hook for params-side reaction when a cell's string is (re-)assigned.
-- voice_params installs this so the cell's string param can re-sync.
Sequencer.on_cell_assigned_fn = nil

-- Assign a new byte sequence to the cell's Sequins instance.
-- Used by odd-row grid presses (rows 3, 5, 7) which target the cell ABOVE
-- in the corresponding even row (y - 1), and by the `cell_X_Y_string`
-- param's action. `silent=true` skips the params-side sync hook so the
-- param's own action can call this without re-firing itself.
function Sequencer.assign(x, y, str, silent)
    if Sequencer.Seq[x] and Sequencer.Seq[x][y] then
        Sequencer.Seq[x][y]:settable(Sequencer.string_to_bytes(str))
    end
    Sequencer._cell_assigned_strings[x .. '_' .. y] = str
    if not silent and Sequencer.on_cell_assigned_fn then
        Sequencer.on_cell_assigned_fn(x, y)
    end
end
```

**Lines 113-130**: the second hook + the assign function.

`Sequencer.assign(x, y, str, silent)` does three things:

1. **Mutate the live Sequins** via `:settable`. This is the critical line — the cell's clock loop reads from `Sequencer.Seq[x][y]`, so this immediately changes what the cell will fire on its next tick.
2. **Record the assignment** in `_cell_assigned_strings`. This is the side-table the params surface reads.
3. **Fire the cell-assigned hook**, unless `silent=true`.

The `silent` flag exists because the cell string param's action calls `assign(...)`, and the on_cell_assigned hook (installed by voice_params) calls `refresh_one_cell_string_param`, which calls `params:set(string_id, ...)`, which would re-fire the original action. The silent flag breaks the loop.

`★ Insight ─────────────────────────────────────`
**`Sequencer.assign` is the SINGLE WRITER for cell Sequins state.** Grid handlers call it. PSET restore calls it. The cell string param's action calls it. Every assignment flows through this function. This is what makes the gridless string assignment work — by funneling all assignment paths through one function, we can be sure the side-effects (Sequins :settable + table update + optional hook) happen consistently.

**The `Sequencer.Seq[x] and Sequencer.Seq[x][y]` guard** is defensive. If somehow assign was called for an uninitialized cell (it shouldn't be, but defensive), the function still writes to `_cell_assigned_strings` even though the Sequins write is skipped. This preserves the display state in the params menu without crashing.
`─────────────────────────────────────────────────`

## Consuming bytes during dispatch (`next_byte`)

```lua
-- Read the next byte from a cell's sequins. Returns the raw byte value.
-- Called by cell_roles.dispatch for the cell's role-specific mapping.
function Sequencer.next_byte(x, y)
    if Sequencer.Seq[x] and Sequencer.Seq[x][y] then
        return Sequencer.Seq[x][y]()
    end
    return string.byte(" ")
end
```

**Lines 132-139**: read one byte from the cell's Sequins. The defensive guard returns space byte (32) if the Sequins doesn't exist. The Sequins call `Seq[x][y]()` advances the cursor and returns the next byte.

Used by every role dispatcher in `cell_roles.lua`. Each dispatcher reads N bytes per fire (1 for TriSin/Ringer, 4 for crow 1+2, 2 for sampler trigger position+duration, etc.) and maps them to musical values.

## The 64 clock loops

```lua
-- ========================================================================
-- CLOCK LOOPS (per toggle cell)
-- ========================================================================

-- Forward reference: set by schicksalslied.lua's init() to cell_roles.dispatch.
-- Decoupled from cell_roles here so sequencer doesn't require cell_roles at load time.
Sequencer.dispatch_fn = nil
```

**Lines 141-147**: a forward reference. `dispatch_fn` will be set by `schicksalslied.lua` after both modules are loaded. The sequencer doesn't import `cell_roles` directly — that would create a circular dependency (cell_roles imports sequencer state). The forward-reference pattern resolves it: sequencer says "someone will set me a dispatch_fn"; schicksalslied sets it.

### `step_for`

```lua
-- Returns a coroutine body for cell [x][y]. Runs forever; gates on Toggled + Paused.
--
-- Two clock-sync strategies, chosen per-tick by current seq_mode:
--
--   modes 1 (lied/sequins) + 2 (fixed): absolute beat-grid sync. Fires land on
--   the rate's natural multiples relative to clock zero. Preserves naherinlied
--   semantics and makes the per-cell seq_phase param meaningful (backbeat).
--
--   modes 3 (user_seq) + 4 (random): relative sync. Each fire is exactly the
--   computed rate (in beats) from the previous fire. Fixes the [1, 2] pattern
--   bug where absolute sync would collapse onto every integer beat — because
--   sync(2) from beat 1 lands on beat 2, not beat 3. The trick is to pass
--   offset = current_beat % rate so the alignment "moves with us."
local function step_for(x, y)
    local phase_id = 'cell_' .. x .. '_' .. y .. '_seq_phase'
    local mode_id  = 'cell_' .. x .. '_' .. y .. '_seq_mode'
    return function()
        while true do
            local rate = Sequencer.get_rate(x, y)
            local mode_idx = params.lookup[mode_id] and params:get(mode_id) or 1
            if mode_idx == 3 or mode_idx == 4 then
                local now = clock.get_beats()
                clock.sync(rate, now % rate)
            else
                local phase = params.lookup[phase_id] and params:get(phase_id) or 0
                if phase > 0 then
                    clock.sync(rate, phase)
                else
                    clock.sync(rate)
                end
            end
            if Sequencer.Toggled[x][y] and (not Sequencer.Paused) then
                if Sequencer.dispatch_fn then
                    Sequencer.dispatch_fn(x, y)
                end
                Sequencer.Fire_Decay[x][y] = 4
            end
        end
    end
end
```

**Lines 162-189**: the heart of the file. `step_for(x, y)` returns a coroutine body that drives one cell's fire loop.

The outer call captures `x`, `y`, and precomputes the param ID strings. This is a small optimization — string concatenation on every iteration would be wasteful.

The inner function (returned) runs forever in a `while true do ... end` loop. Each iteration:

1. **Read `rate`** via `Sequencer.get_rate(x, y)`. This is mode-dependent (see section 9).
2. **Read `mode_idx`** with defensive lookup. If params haven't been added yet (early init), default to mode 1.
3. **Choose sync strategy** based on mode:
   - **Modes 3 or 4 (user_seq/random)**: relative sync via `clock.sync(rate, now % rate)`. By passing the current `beats % rate` as the offset, the next sync fires exactly `rate` beats from now.
   - **Otherwise (modes 1 or 2 — lied or fixed)**: absolute sync via `clock.sync(rate)` (or `clock.sync(rate, phase)` if a per-cell phase is set).
4. **After sync**: check whether to dispatch. The cell must be Toggled AND not globally Paused. If both, call `dispatch_fn` and bump `Fire_Decay` for the LED flash.

`★ Insight ─────────────────────────────────────`
**The two clock-sync strategies are the single most important detail in this file.** The musical reasoning has been outlined in the "What you'll learn" section above; the line-level annotation is:

`clock.sync(rate)` waits until the next absolute beat where `beats % rate == 0`. At `now = 6.7, rate = 2`, the next match is beat 8 — waiting 1.3 beats.

`clock.sync(rate, offset)` waits until the next beat where `(beats - offset) % rate == 0`. At `now = 6.7, rate = 2, offset = 0.7 (= now % rate)`, the next match is at `now + rate = 8.7` — waiting exactly 2 beats. Relative timing.

The reason absolute timing is right for lied/fixed: cells with the same rate should fire together on the global beat grid, even if their loops started at different times. Two `rate=2` cells in lied mode both fire on beats 0, 2, 4, etc.

The reason relative timing is right for user_seq/random: each picked rate is the intended GAP between fires. If user_seq says `[1, 2]`, you want fire-gap-1-fire-gap-2-fire. Absolute sync would collapse the 2-beat gap onto the next absolute even beat, which might be only 1 beat away.
`─────────────────────────────────────────────────`

### `start_all_clocks` and `stop_all_clocks`

```lua
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
```

**Lines 195-213**: start and stop all clock loops.

`start_all_clocks` is called from `init` in `schicksalslied.lua`. The double loop iterates the 64 toggle cells. Each `clock.run(step_for(x, y))` spawns a coroutine and stores its ID.

`stop_all_clocks` is called from `cleanup`. It iterates the same cells and cancels each running coroutine.

The note about row 8 cols 14-16 is important: those cells (mic toggle, granular out, mic dry) are NOT sequencer-driven. Their clock loops still run, but their role dispatch is a no-op (see cell_roles.dispatch's row-8 branch). The simpler alternative would be to not start clocks for those cells; the script chose to start them anyway for uniformity (every toggle cell has a clock; the role decides whether to do anything).

## Clock-quantized pause and resume

```lua
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
                grid_dirty = true
            end)
        end
    else
        if not Sequencer.Pause_Pending then
            Sequencer.Pause_Pending = true
            clock.run(function()
                clock.sync(1)
                Sequencer.Paused = true
                Sequencer.Pause_Pending = false
                grid_dirty = true
            end)
        end
    end
end
```

**Lines 215-243**: clock-quantized pause/resume. The function is called by the K2 handler.

If currently paused:
- If no unpause is pending, start one. Set the pending flag, spawn a coroutine that waits one beat then unpauses + clears the flag.

If currently playing:
- Same shape, but with the pause coroutine.

The pending flags prevent rapid K2 presses from spawning multiple in-flight transition coroutines. Pressing K2 twice quickly within a single beat-wait period triggers only one transition.

The `grid_dirty = true` at the end of each coroutine triggers a grid redraw (so the pause-indication LED updates).

`★ Insight ─────────────────────────────────────`
**Why quantize pause/resume?** Without quantization, K2 would cut notes mid-attack — sometimes at click-producing zero-crossings, sometimes mid-envelope. With quantization, every K2 lands on a beat boundary; notes that were going to fire fire normally; the next iteration of the clock loop sees `Paused=true` and skips its dispatch.

The cost: up to 1 beat of latency between press and effect (~0.5 sec at 120 BPM). The benefit: every pause/resume is musically clean.

**The clock-quantized state-change pattern is reusable.** Want a parameter change to take effect on the next bar? Spawn a coroutine with `clock.sync(4)` + the set. Want a metronome to start exactly on the next downbeat? Same. The price is one coroutine per change (lives < 1 beat); the benefit is musical timing.
`─────────────────────────────────────────────────`

## The four sequencer modes (`get_rate`)

### Defaults

```lua
-- ========================================================================
-- SEQ MODE — clock rate per cell per tick
-- ========================================================================
-- Four modes per spec §7:
--   sequins  : rate = Seq[x][y]() / Seq[x][y]() * scale (consumes 2 bytes)
--   fixed    : rate = fixed_value (a constant)
--   user_seq : rate cycles through a user-configured pattern of N step durations
--   random   : rate = math.random(min, max) per tick

Sequencer.Seq_Mode = {}

Sequencer.User_Seq_Patterns = {
    Sequins({ 0.25, 0.25, 15.5 }),
    Sequins({ 0.5, 15, 0.5 }),
    Sequins({ 0.25, 15.25, 0.25, 0.25 }),
    Sequins({ 0.5, 0.5, 14.5, 0.5 }),
}
```

**Lines 245-268**: the four modes (described in the comment), the `Seq_Mode` per-cell defaults table, and four preset Sequins patterns.

The preset patterns are the original naherinlied user-sequence patterns. They're each 3-4 steps with durations like `{0.25, 0.25, 15.5}` (two quick fires then a long pause). The patterns are pre-built as Sequins because each invocation `pat()` advances the cursor — they need to be persistent objects.

Sub-plan C wires these into the per-cell `cell_X_Y_seq_step_N_duration` params, where the user can customize each step. The legacy preset patterns are kept as fallback defaults.

### `default_seq_mode_for`

```lua
local function default_seq_mode_for(x, y)
    if y == 2 then
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
        return { mode = 'fixed', fixed_value = 2 }
    elseif y == 8 then
        return { mode = 'random', random_min = 1, random_max = 16 }
    end
    return { mode = 'fixed', fixed_value = 1 }
end
```

**Lines 270-293**: per-column defaults for each toggle row. These mirror naherinlied's per-column defaults:

- Row 2 cols 1-2: fixed every 8 beats.
- Row 2 cols 3-8: sequins-derived, scale 8.
- Row 2 cols 9-12: four different user_seq patterns.
- Row 2 cols 13-16: progressively faster fixed rates.
- Rows 4/6 (samplers): fixed every 2 beats.
- Row 8 (one-shots): random 1-16.

The reasoning: provide useful out-of-the-box rates that produce musical material without configuration. The user can override any cell via params.

```lua
function Sequencer._init_seq_modes()
    for x = 1, 16 do
        Sequencer.Seq_Mode[x] = {}
        for y = 2, 8, 2 do
            Sequencer.Seq_Mode[x][y] = default_seq_mode_for(x, y)
        end
    end
end
```

**Lines 295-303**: populate the defaults table. Called from `Sequencer.init`.

### `get_rate`

```lua
function Sequencer.get_rate(x, y)
    local prefix = 'cell_' .. x .. '_' .. y .. '_seq_'
    local mode_param_id = prefix .. 'mode'

    if params.lookup[mode_param_id] == nil then
        local sm = Sequencer.Seq_Mode[x] and Sequencer.Seq_Mode[x][y]
        if sm == nil then return 1 end
        if sm.mode == 'fixed' then return sm.fixed_value or 1
        elseif sm.mode == 'sequins' then
            local seq = Sequencer.Seq[x][y]
            local num = seq()
            local den = seq()
            local scale = sm.scale or 1
            if den == 0 then return scale end
            return (num / den) * scale
        elseif sm.mode == 'user_seq' then
            local pat = Sequencer.User_Seq_Patterns[sm.pattern_index or 1]
            if pat then return pat() end
            return 1
        elseif sm.mode == 'random' then
            local lo = sm.random_min or 1
            local hi = sm.random_max or 16
            return math.random() * (hi - lo) + lo
        end
        return 1
    end

    local mode_idx = params:get(mode_param_id)
    if mode_idx == 1 then
        local seq = Sequencer.Seq[x][y]
        local num = seq()
        local den = seq()
        local scale = params:get(prefix .. 'scale') or 1
        if den == 0 then return scale end
        return (num / den) * scale
    elseif mode_idx == 2 then
        return Timing.value(params:get(prefix .. 'fixed_value')) or 1
    elseif mode_idx == 3 then
        return Sequencer._user_seq_step(x, y)
    elseif mode_idx == 4 then
        local lo_idx = params:get(prefix .. 'random_min') or 1
        local hi_idx = params:get(prefix .. 'random_max') or #Timing.OPTIONS
        if lo_idx > hi_idx then lo_idx, hi_idx = hi_idx, lo_idx end
        return Timing.value(math.random(lo_idx, hi_idx))
    end
    return 1
end
```

**Lines 308-362**: the rate computation. Two paths:

**Pre-Sub-plan-C fallback** (lines 314-336): if params haven't been added yet (early init or test environment), use the in-memory `Seq_Mode` table. For each mode:

- **fixed**: return `sm.fixed_value or 1`.
- **sequins**: read 2 bytes (num and den), return `(num / den) * scale`. Guard against `den == 0`.
- **user_seq**: read the next value from the preset Sequins pattern.
- **random**: pick a uniform random float in the range. Note this uses raw bounds, not Timing-indexed.

**Live params path** (lines 338-361): once params are present, read from them.

- **mode 1 (lied/sequins)**: same byte-ratio math, but `scale` comes from the `cell_X_Y_seq_scale` param.
- **mode 2 (fixed)**: read the `fixed_value` option index, convert via `Timing.value(idx)`.
- **mode 3 (user_seq)**: delegate to `_user_seq_step`.
- **mode 4 (random)**: read min/max option indices, swap if reversed, pick random in range, convert to value via `Timing.value`.

The `or 1` fallbacks at every step are defensive — if Timing.value somehow returns nil (out-of-range index), fall back to rate 1 (every beat) rather than crashing.

### `_user_seq_step`

```lua
Sequencer._user_seq_cursors = {}
function Sequencer._user_seq_step(x, y)
    if Sequencer._user_seq_cursors[x] == nil then
        Sequencer._user_seq_cursors[x] = {}
    end
    local prefix = 'cell_' .. x .. '_' .. y .. '_seq_'
    local num_steps = params:get(prefix .. 'num_steps') or 4
    local cursor = (Sequencer._user_seq_cursors[x][y] or 0) % num_steps + 1
    Sequencer._user_seq_cursors[x][y] = cursor
    local idx = params:get(prefix .. 'step_' .. cursor .. '_duration')
    return Timing.value(idx) or 1
end
```

**Lines 366-377**: step through the user-defined sequence.

`_user_seq_cursors[x][y]` is the per-cell cursor — the index of the last step that fired. Each call:

1. Lazy-create the `[x]` sub-table if needed.
2. Read `num_steps` (defaults to 4).
3. Increment cursor (mod num_steps), store.
4. Read the duration param for that step (e.g., `cell_3_2_seq_step_2_duration`).
5. Convert option index to value.

The cursor is per-cell and per-value-kind. If the user has multiple cells in user_seq mode, each cycles independently. If the user changes `num_steps` mid-play, the modulo handles it gracefully — the cursor wraps to the new num_steps boundary on the next iteration.

## Value modes for samplers and one-shots

### Defaults + init

```lua
-- Value_Mode[x][y][value_kind] = { mode, args... }
-- value_kind: 'position', 'duration', 'rate'
Sequencer.Value_Mode = {}

local function default_value_mode()
    return { mode = 'lied' }
end

function Sequencer._init_value_modes()
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
```

**Lines 390-411**: per-cell, per-kind value-mode defaults. Every sampler/one-shot cell gets a `position`, `duration`, and `rate` value-mode (though sampler-rate cells only meaningfully use `rate`, and one-shots use only `rate`). All default to `'lied'` — derive from bytes.

The triple-nested table structure is `Value_Mode[x][y][value_kind]`. The `value_kind` is a string: `'position'`, `'duration'`, or `'rate'`.

### `get_value`

```lua
function Sequencer.get_value(x, y, value_kind)
    local prefix = 'cell_' .. x .. '_' .. y .. '_' .. value_kind .. '_'
    local mode_param_id = prefix .. 'mode'

    if params.lookup[mode_param_id] == nil then
        local vm = Sequencer.Value_Mode[x]
            and Sequencer.Value_Mode[x][y]
            and Sequencer.Value_Mode[x][y][value_kind]
        if vm == nil then return nil end
        if vm.mode == 'lied' then return nil
        elseif vm.mode == 'fixed' then return vm.fixed_value
        elseif vm.mode == 'random' then
            return math.random() * ((vm.random_max or 1) - (vm.random_min or 0))
                + (vm.random_min or 0)
        end
        return nil
    end

    local rate_mode = (value_kind == 'rate')
    local mode_idx = params:get(mode_param_id)
    if mode_idx == 1 then return nil
    elseif mode_idx == 2 then
        local raw = params:get(prefix .. 'fixed_value')
        return rate_mode and Timing.rate_value(raw) or raw
    elseif mode_idx == 3 then return Sequencer._user_value_step(x, y, value_kind)
    elseif mode_idx == 4 then
        if rate_mode then
            local lo_idx = params:get(prefix .. 'random_min') or 1
            local hi_idx = params:get(prefix .. 'random_max') or #Timing.RATE_OPTIONS
            if lo_idx > hi_idx then lo_idx, hi_idx = hi_idx, lo_idx end
            return Timing.rate_value(math.random(lo_idx, hi_idx))
        end
        local lo = params:get(prefix .. 'random_min') or 0
        local hi = params:get(prefix .. 'random_max') or 1
        return math.random() * (hi - lo) + lo
    end
    return nil
end
```

**Lines 415-456**: similar shape to `get_rate` but with the rate-vs-non-rate split.

- **Mode 1 (lied)**: return nil. The caller (in cell_roles dispatchers) derives from bytes.
- **Mode 2 (fixed)**: rate kind uses `Timing.rate_value(idx)`; position/duration return raw float.
- **Mode 3 (user_seq)**: delegate to `_user_value_step`.
- **Mode 4 (random)**: rate kind uses `Timing.rate_value(math.random(lo_idx, hi_idx))` (option-typed); position/duration use raw float range.

The `rate_mode = (value_kind == 'rate')` boolean determines whether to use the rate-options conversion. This is what makes rate values musical (always a fraction from `Timing.RATE_OPTIONS`) while position/duration are continuous.

### `_user_value_step`

```lua
Sequencer._user_value_cursors = {}
function Sequencer._user_value_step(x, y, value_kind)
    if Sequencer._user_value_cursors[x] == nil then
        Sequencer._user_value_cursors[x] = {}
    end
    if Sequencer._user_value_cursors[x][y] == nil then
        Sequencer._user_value_cursors[x][y] = {}
    end
    local prefix = 'cell_' .. x .. '_' .. y .. '_' .. value_kind .. '_'
    local num_steps = params:get(prefix .. 'num_steps') or 4
    local cursor = (Sequencer._user_value_cursors[x][y][value_kind] or 0)
        % num_steps + 1
    Sequencer._user_value_cursors[x][y][value_kind] = cursor
    local raw = params:get(prefix .. 'step_' .. cursor .. '_value')
    if value_kind == 'rate' then return Timing.rate_value(raw) end
    return raw
end
```

**Lines 458-474**: per-cell per-kind step cursor. Triple-nested structure: `_user_value_cursors[x][y][value_kind]`. Each kind cycles independently.

`★ Insight ─────────────────────────────────────`
**Per-kind cursors mean position, duration, and rate cycle independently within the same cell.** If position has 4 steps and rate has 3 steps, position cycles 1→2→3→4→1→2→... while rate cycles 1→2→3→1→2→3→1→... Two independent rhythmic patterns from one cell.

This is a subtle but powerful feature. You can set up a cell whose position varies on a 5-step cycle while rate varies on a 3-step cycle — that's a 15-step composite pattern with very irregular feel.

**Note `step_<N>_value` (line 471)** vs `step_<N>_duration` (in `_user_seq_step`). Value-mode steps store a `value`; seq-mode steps store a `duration`. Different param IDs, different semantics. The naming convention follows the role: seq mode is about rate (durations of beats); value mode is about output values (frame positions or playback rates).
`─────────────────────────────────────────────────`

## The reset helper

```lua
function Sequencer.reset_all_seq_modes_to_default()
    Sequencer._init_seq_modes()
    print('Sequencer: all seq modes reset to default')
end
```

**Lines 478-483**: a one-shot reset called from a global trigger param. Just re-runs `_init_seq_modes`, which repopulates the `Seq_Mode` table with the per-column defaults. The print is a confirmation in the matron log.

The function doesn't directly touch params — once Sub-plan C is wired, the params override the in-memory `Seq_Mode` anyway. A future improvement would be to also push the defaults back to the params (so the user can see what changed). For now, this just resets the fallback behavior.

## Summary

`sequencer.lua` is 485 lines of cohesive state + logic. The patterns to internalize:

- **Per-cell state via `[x][y]` indexed tables.**
- **In-place Sequins mutation via `:settable`** — the cell's clock loop sees changes immediately.
- **Hook-based callbacks** (`on_history_changed_fn`, `on_cell_assigned_fn`) — installed by `voice_params` to wire the gridless string assignment surface.
- **Two clock-sync strategies** depending on mode — absolute for grid-aligned modes, relative for gap-based modes.
- **Pre-Sub-plan-C fallbacks throughout** — every mode-reading function has a "if params don't exist, use in-memory defaults" branch. These fallbacks fire only during early init; in normal operation, the live params path is taken.
- **Defensive `or default` fallbacks** in every param read — bad/missing param values fall back to safe defaults rather than crashing.

The file is dense but follows a small set of patterns. Once you've internalized the patterns, scanning the file is easy.
