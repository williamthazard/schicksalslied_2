-- lib/cell_roles.lua — schicksalslied 2.0 role dispatch + lazy allocation
-- Owns: role enum, dispatch table, lazy alloc of SC voice instances per cell

local MusicUtil = require 'musicutil'
local Looper = include 'lib/wtape_looper'
local Midi = include 'lib/midi_role'
local Roles = {}

-- ========================================================================
-- PITCH QUANTIZATION (global scale + root)
-- ========================================================================
-- Returns the input midi_note unchanged when scale_mode == 1 (chromatic /
-- no quantization — schicksalslied's historical behavior). Otherwise snaps
-- to the chosen scale's nearest note.
-- Called by every pitched role dispatcher (TriSin, Ringer, crow 1+2,
-- crow 3+4, JF, JF run, JF quantize, w/syn, w/del — MIDI dispatcher in
-- lib/midi_role.lua is wired in Task 3.2).
function Roles.quantize_note(midi_note)
    local scale_idx = params:get('scale_mode')
    if scale_idx == nil or scale_idx == 1 then
        return midi_note  -- chromatic / pre-params-init = no quantization
    end
    local root = (params:get('root_note') or 1) - 1  -- 0-based 0..11
    -- scale_mode index 2 = MusicUtil.SCALES[1], so offset by 1
    local scale = MusicUtil.generate_scale_of_length(root,
        MusicUtil.SCALES[scale_idx - 1].name, 128)
    return MusicUtil.snap_note_to_array(midi_note, scale)
end

-- ========================================================================
-- ROLE ENUM (row 2 cells configurable; rows 4/6/8 are fixed)
-- ========================================================================
-- 11 options per spec §3 (10 original + MIDI added in Sub-plan C).
-- Order matters — params menu uses these as indices.
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
    'MIDI',
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

-- ========================================================================
-- LAZY ALLOCATION (Approach C from spec §4)
-- ========================================================================
-- Track which cells have an active SC instance allocated. On first trigger
-- after role-set, allocate. On role change (Sub-plan C will wire), free old.

Roles.allocated = {}  -- key: cell_id, value: current role string

-- Ensure cell's SC instance is allocated for its current role. Idempotent.
function Roles.ensure_allocated(x, y)
    if y ~= 2 then return end  -- only row 2 cells use lazy allocation
    local cell_id = Roles.cell_id(x, y)
    local role = Roles.cell_role[x]
    if Roles.allocated[cell_id] == role then return end
    -- If previously allocated as a different role, free it first
    if Roles.allocated[cell_id] then
        local prev = Roles.allocated[cell_id]
        if prev == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif prev == 'Ringer' then
            engine.ringer_free(cell_id)
        end
        Roles.allocated[cell_id] = nil
    end
    -- Allocate fresh for the current role (only audio voices need allocation)
    if role == 'TriSin' then
        engine.trisin_alloc(cell_id)
        Roles.allocated[cell_id] = role
    elseif role == 'Ringer' then
        engine.ringer_alloc(cell_id)
        Roles.allocated[cell_id] = role
    end
    -- Crow roles and looper don't need SC instances — they speak crow/ii directly
end

-- Called by schicksalslied.lua's cleanup() — free all allocated SC instances.
function Roles.free_all()
    for cell_id, role in pairs(Roles.allocated) do
        if role == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif role == 'Ringer' then
            engine.ringer_free(cell_id)
        end
    end
    Roles.allocated = {}
end

-- ========================================================================
-- ROLE DISPATCH TABLE
-- ========================================================================
-- Each role dispatch reads bytes from the cell's sequins (via Sequencer),
-- applies role-specific mapping, and fires the appropriate engine or crow
-- method. Set Roles.Sequencer = <sequencer_module> at init time so the
-- dispatch functions can access the state.

Roles.Sequencer = nil  -- set by schicksalslied.lua's init()

-- Round-robin counters for voice keys per cell (TriSin/Ringer).
-- Index by cell_id string. Polyphony pool size is per cell (default 4).
Roles.rr_counter = {}
Roles.polyphony = {}  -- per cell, 1-8, default 4. Sub-plan C wires per-cell params.

local function next_voice_key(cell_id, default_poly)
    local poly = Roles.polyphony[cell_id] or default_poly or 4
    Roles.rr_counter[cell_id] = ((Roles.rr_counter[cell_id] or 0) % poly) + 1
    return Roles.rr_counter[cell_id]
end

-- Per-cell w/tape looper "is this cell's looper currently running?" flag.
-- Prevents stacking concurrent loopers from rapid retriggers of the same cell.
Roles.looper_running = {}

-- The 10 row-2 role dispatchers
Roles.dispatch_row_2 = {

    ['TriSin'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)
        local cell_id = Roles.cell_id(x, y)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local note = Roles.quantize_note(seq() % 32 + 49 + offset)
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.trisin_trigger(cell_id, voice_key, freq)
    end,

    ['Ringer'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)
        local cell_id = Roles.cell_id(x, y)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local note = Roles.quantize_note(seq() % 32 + 49 + offset)
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.ringer_trigger(cell_id, voice_key, freq)
    end,

    ['crow 1+2'] = function(x, y, seq)
        -- consumes 4 bytes: pitch (v/oct), slew, attack, release
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.output[1].volts = pitch_note / 12
        crow.output[1].slew = (seq() % 32 + 1) / 300
        crow.output[2].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[2].dyn.release = (seq() % 32 + 1) / 40
        crow.output[2]()
    end,

    ['crow 3+4'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.output[3].volts = pitch_note / 12
        crow.output[3].slew = (seq() % 32 + 1) / 300
        crow.output[4].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[4].dyn.release = (seq() % 32 + 1) / 40
        crow.output[4]()
    end,

    ['JF'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        local level = seq() % 5 + 1
        crow.ii.jf.play_note(pitch_note / 12, level)
    end,

    ['JF run'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.jf.run(pitch_note / 12)
    end,

    ['JF quantize'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.jf.quantize(pitch_note / 12)
    end,

    ['w/syn'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        local level = seq() % 5 + 1
        crow.ii.wsyn.play_note(pitch_note / 12, level)
    end,

    ['w/del'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.wdel.time(0)
        crow.ii.wdel.freq(pitch_note / 12)
        crow.ii.wdel.pluck(seq() % 5 + 1)
    end,

    ['w/tape looper'] = function(x, y, seq)
        local cell_id = Roles.cell_id(x, y)
        if Roles.looper_running[cell_id] then return end  -- prevent re-entry
        Roles.looper_running[cell_id] = true
        clock.run(function()
            Looper.run(seq)
            Roles.looper_running[cell_id] = false
        end)
    end,

    ['MIDI'] = function(x, y, seq)
        Midi.dispatch(x, y, seq)
    end,
}

-- Sampler trigger cells (rows 4/6 odd cols 1/3/5/7/9/11/13/15)
-- Maps: row 4 odd col K → sampler slot (K+1)/2;  row 6 odd col K → sampler slot 8 + (K+1)/2
local function sampler_slot_for(x, y)
    local base = (y == 4) and 0 or 8
    return base + (math.floor(x / 2) + 1)
end

local function dispatch_sampler_trigger(x, y, seq)
    local slot = sampler_slot_for(x, y)
    local cell_id = Roles.cell_id(x, y)
    local poly = Roles.polyphony[cell_id] or 1
    local voice_key = next_voice_key(cell_id, poly)
    -- Default 'lied' mode: read 2 bytes for position/duration
    local pos_value = Roles.Sequencer.get_value(x, y, 'position')
    local dur_value = Roles.Sequencer.get_value(x, y, 'duration')
    local start_pos, end_pos
    if pos_value == nil then
        start_pos = util.clamp(util.linlin(32, 126, 0, 0.9, seq()), 0, 0.9)
    else
        start_pos = pos_value
    end
    if dur_value == nil then
        end_pos = start_pos + util.clamp(util.linlin(32, 126, 0.001, 0.1, seq()), 0.001, 0.1)
    else
        end_pos = start_pos + dur_value
    end
    -- Rate: read from PAIRED rate-control cell's sequins or value_mode
    -- For trigger cell at (x, y), the rate cell is at (x + 1, y)
    local rate_value = Roles.Sequencer.get_value(x + 1, y, 'rate')
    local rate
    if rate_value == nil then
        rate = 1  -- naherinlied's `(S-35)/(S-35)` is always 1
    else
        rate = rate_value
    end
    engine.sampler_trigger(slot, voice_key, start_pos, end_pos, rate)
end

local function dispatch_sampler_rate(x, y, seq)
    -- Rate cells don't trigger directly; their sequins feeds the PAIRED
    -- trigger cell. But the rate cell also has a clock loop. On its tick,
    -- it could update the sampler's rate param directly.
    local slot = sampler_slot_for(x - 1, y)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        rate = 1  -- lied mode default for current implementation
    else
        rate = rate_value
    end
    engine.sampler_set_param(slot, 'rate', rate)
end

-- One-shot row 8 cols 1-13
local function dispatch_oneshot_trigger(x, y, seq)
    local slot = x  -- one-shot slot = col number for x = 1..13
    local cell_id = Roles.cell_id(x, y)
    local voice_key = next_voice_key(cell_id, 1)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        -- lied mode: rate from sequins. Use byte / 36 for typical range 1.0–2.0
        rate = seq() / 36
    else
        rate = rate_value
    end
    engine.oneshot_trigger(slot, voice_key, rate)
end

-- ========================================================================
-- TOP-LEVEL DISPATCH
-- ========================================================================
-- Called by sequencer's clock loops via Sequencer.dispatch_fn.

function Roles.dispatch(x, y)
    local seq = Roles.Sequencer.Seq[x][y]
    -- Wrap seq into a function that just returns the next byte
    local seq_fn = function() return seq() end

    if y == 2 then
        local role = Roles.cell_role[x]
        local fn = Roles.dispatch_row_2[role]
        if fn then fn(x, y, seq_fn) end
    elseif y == 4 or y == 6 then
        if x % 2 == 1 then
            dispatch_sampler_trigger(x, y, seq_fn)
        else
            dispatch_sampler_rate(x, y, seq_fn)
        end
    elseif y == 8 then
        if x <= 13 then
            dispatch_oneshot_trigger(x, y, seq_fn)
        end
        -- cols 14-16 are mic/granular on/off toggles; no per-tick action.
        -- The toggle press handler in schicksalslied.lua manages their amps.
    end
end

return Roles
