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
    init_seq_modes()
    init_value_modes()
end

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

return Sequencer
