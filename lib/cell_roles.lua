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
