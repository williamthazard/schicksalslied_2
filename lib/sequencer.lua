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

return Sequencer
