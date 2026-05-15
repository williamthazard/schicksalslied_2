-- lib/voice_params.lua — helpers for building per-voice / per-cell param blocks
-- Spec §5 (samplers + one-shots), §9 (row-2 voices)

local VoiceParams = {}

-- Bus routing options surface to the user. Underlying SC bus index is
-- resolved at action time via VoiceParams.bus_idx_for.
VoiceParams.BUS_ROUTING_OPTIONS = { 'dry', 'reverb', 'delay+reverb' }

-- Map a bus_routing option index (1..3) to the SC audio bus number.
-- Lied.sc allocates 3 stereo buses in order: dryBus, reverbBus, delayBus.
-- The actual indices depend on Norns's output bus channel count + Lied's
-- allocation order. We hardcode the expected triplet here; Lied.sc prints
-- the actual indices at boot so the user can verify on hardware. If the
-- hardware values differ, update the constants below.
function VoiceParams.bus_idx_for(routing_idx)
    if routing_idx == 1 then return 4    -- dryBus (post output 0-1, so starts at 4 on stereo-output Norns)
    elseif routing_idx == 2 then return 6  -- reverbBus
    elseif routing_idx == 3 then return 8  -- delayBus
    end
    return 4
end

-- ────────────────────────────────────────────────────────────────────────
-- SAMPLER PARAM BLOCK (called from schicksalslied.lua's add_params for
-- slots 1..16). Adds 9 params per sampler (file param is added separately
-- by the caller — see Task 5.2).
-- ────────────────────────────────────────────────────────────────────────
function VoiceParams.add_sampler_block(slot)
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_amp',
        name = 'sampler ' .. slot .. ' amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
        action = function(v) engine.sampler_set_param(slot, 'amp', v) end,
    }
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_amp_slew',
        name = 'sampler ' .. slot .. ' amp slew',
        controlspec = controlspec.new(0, 5, 'lin', 0.01, 0.05, 's'),
        action = function(v) engine.sampler_set_param(slot, 'amp_slew', v) end,
    }
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_cutoff',
        name = 'sampler ' .. slot .. ' cutoff',
        controlspec = controlspec.new(20, 18000, 'exp', 1, 12000, 'Hz'),
        action = function(v) engine.sampler_set_param(slot, 'cutoff', v) end,
    }
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_resonance',
        name = 'sampler ' .. slot .. ' resonance',
        controlspec = controlspec.new(0, 4, 'lin', 0.01, 1, ''),
        action = function(v) engine.sampler_set_param(slot, 'resonance', v) end,
    }
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_pan',
        name = 'sampler ' .. slot .. ' pan',
        controlspec = controlspec.new(-1, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.sampler_set_param(slot, 'pan', v) end,
    }
    params:add{
        type = 'control',
        id = 'sampler_' .. slot .. '_pan_slew',
        name = 'sampler ' .. slot .. ' pan slew',
        controlspec = controlspec.new(0, 5, 'lin', 0.01, 1, 's'),
        action = function(v) engine.sampler_set_param(slot, 'pan_slew', v) end,
    }
    params:add{
        type = 'number',
        id = 'sampler_' .. slot .. '_polyphony',
        name = 'sampler ' .. slot .. ' polyphony',
        min = 1, max = 8, default = 1,
        action = function(v)
            local Roles = require 'lib/cell_roles'
            -- Sampler slot N pairs with trigger cell:
            --   slot 1..8 → cell (2N-1, 4)
            --   slot 9..16 → cell (2(N-8)-1, 6)
            local trigger_col, trigger_row
            if slot <= 8 then
                trigger_col = (slot * 2) - 1
                trigger_row = 4
            else
                trigger_col = ((slot - 8) * 2) - 1
                trigger_row = 6
            end
            local cell_id = string.format("%d_%d", trigger_col, trigger_row)
            Roles.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'option',
        id = 'sampler_' .. slot .. '_bus_routing',
        name = 'sampler ' .. slot .. ' bus routing',
        options = VoiceParams.BUS_ROUTING_OPTIONS,
        default = 1,
        action = function(routing_idx)
            engine.sampler_reroute(slot, VoiceParams.bus_idx_for(routing_idx))
        end,
    }
    params:add{
        type = 'trigger',
        id = 'sampler_' .. slot .. '_randomize',
        name = 'sampler ' .. slot .. ' randomize',
        action = function() VoiceParams.randomize_sampler(slot) end,
    }
end

-- Randomize a sampler's params (called from per-slot randomize + global randomize).
function VoiceParams.randomize_sampler(slot)
    params:set('sampler_' .. slot .. '_amp',        math.random(20, 80) / 100)
    params:set('sampler_' .. slot .. '_cutoff',     math.random(500, 12000))
    params:set('sampler_' .. slot .. '_resonance',  math.random(50, 300) / 100)
    params:set('sampler_' .. slot .. '_pan',        (math.random() * 2) - 1)
end

-- ────────────────────────────────────────────────────────────────────────
-- ONE-SHOT PARAM BLOCK (called from schicksalslied.lua's add_params for
-- slots 1..13). Adds 9 params per one-shot (file param added separately).
-- ────────────────────────────────────────────────────────────────────────
function VoiceParams.add_oneshot_block(slot)
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_amp',
        name = 'one-shot ' .. slot .. ' amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
        action = function(v) engine.oneshot_set_param(slot, 'amp', v) end,
    }
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_amp_slew',
        name = 'one-shot ' .. slot .. ' amp slew',
        controlspec = controlspec.new(0, 5, 'lin', 0.01, 0.05, 's'),
        action = function(v) engine.oneshot_set_param(slot, 'amp_slew', v) end,
    }
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_cutoff',
        name = 'one-shot ' .. slot .. ' cutoff',
        controlspec = controlspec.new(20, 18000, 'exp', 1, 12000, 'Hz'),
        action = function(v) engine.oneshot_set_param(slot, 'cutoff', v) end,
    }
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_resonance',
        name = 'one-shot ' .. slot .. ' resonance',
        controlspec = controlspec.new(0, 4, 'lin', 0.01, 1, ''),
        action = function(v) engine.oneshot_set_param(slot, 'resonance', v) end,
    }
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_pan',
        name = 'one-shot ' .. slot .. ' pan',
        controlspec = controlspec.new(-1, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.oneshot_set_param(slot, 'pan', v) end,
    }
    params:add{
        type = 'control',
        id = 'oneshot_' .. slot .. '_pan_slew',
        name = 'one-shot ' .. slot .. ' pan slew',
        controlspec = controlspec.new(0, 5, 'lin', 0.01, 0.5, 's'),
        action = function(v) engine.oneshot_set_param(slot, 'pan_slew', v) end,
    }
    params:add{
        type = 'number',
        id = 'oneshot_' .. slot .. '_polyphony',
        name = 'one-shot ' .. slot .. ' polyphony',
        min = 1, max = 8, default = 1,
        action = function(v)
            local Roles = require 'lib/cell_roles'
            local cell_id = string.format("%d_%d", slot, 8)
            Roles.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'option',
        id = 'oneshot_' .. slot .. '_bus_routing',
        name = 'one-shot ' .. slot .. ' bus routing',
        options = VoiceParams.BUS_ROUTING_OPTIONS,
        default = 1,
        action = function(routing_idx)
            engine.oneshot_reroute(slot, VoiceParams.bus_idx_for(routing_idx))
        end,
    }
    params:add{
        type = 'trigger',
        id = 'oneshot_' .. slot .. '_randomize',
        name = 'one-shot ' .. slot .. ' randomize',
        action = function() VoiceParams.randomize_oneshot(slot) end,
    }
end

function VoiceParams.randomize_oneshot(slot)
    params:set('oneshot_' .. slot .. '_amp',       math.random(20, 80) / 100)
    params:set('oneshot_' .. slot .. '_cutoff',    math.random(500, 12000))
    params:set('oneshot_' .. slot .. '_resonance', math.random(50, 300) / 100)
    params:set('oneshot_' .. slot .. '_pan',       (math.random() * 2) - 1)
end

-- Granular randomize (called from Global_Randomize)
function VoiceParams.randomize_granular()
    local Grain = require 'lib/grid_grain_params'
    Grain.randomize_all_rates()
end

-- ────────────────────────────────────────────────────────────────────────
-- ROW-2 VOICE CELL PARAM BLOCK (per cell; union of TriSin + Ringer params,
-- visibility by current role; MIDI role adds channel)
-- ────────────────────────────────────────────────────────────────────────

-- Map a role index (from cell_role param) to its display string.
-- Mirrors Roles.ENUM ordering — must stay in sync (11 entries with MIDI).
local ROLE_NAMES = {
    'TriSin', 'Ringer', 'crow 1+2', 'crow 3+4',
    'JF', 'JF run', 'JF quantize',
    'w/syn', 'w/del', 'w/tape looper', 'MIDI',
}

function VoiceParams.add_row2_cell_block(x)
    local cell_id = string.format("%d_2", x)
    local cs = controlspec

    -- ── Role selector ──
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_2_role',
        name = 'cell ' .. x .. ' role',
        options = ROLE_NAMES,
        default = VoiceParams._default_role_index(x),
        action = function(role_idx)
            local role = ROLE_NAMES[role_idx]
            local Roles = require 'lib/cell_roles'
            Roles.cell_role[x] = role
            -- Free previously-allocated SC instance if any
            local prev_alloc = Roles.allocated[cell_id]
            if prev_alloc and prev_alloc ~= role then
                if prev_alloc == 'TriSin' then
                    engine.trisin_free(cell_id)
                elseif prev_alloc == 'Ringer' then
                    engine.ringer_free(cell_id)
                end
                Roles.allocated[cell_id] = nil
            end
            VoiceParams._update_row2_visibility(x, role)
        end,
    }

    -- ── Shared params (TriSin + Ringer; bus routing is voice-only) ──
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_amp',
        name = 'cell ' .. x .. ' amp',
        controlspec = cs.new(0, 2, 'lin', 0.01, 0.5, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'amp', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_amp_slew',
        name = 'cell ' .. x .. ' amp slew',
        controlspec = cs.new(0, 5, 'lin', 0.01, 0.05, 's'),
        action = function(v) VoiceParams._set_cell_param(x, 'amp_slew', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_pan',
        name = 'cell ' .. x .. ' pan',
        controlspec = cs.new(-1, 1, 'lin', 0.01, 0, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'pan', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_pan_slew',
        name = 'cell ' .. x .. ' pan slew',
        controlspec = cs.new(0, 5, 'lin', 0.01, 0.5, 's'),
        action = function(v) VoiceParams._set_cell_param(x, 'pan_slew', v) end,
    }
    params:add{
        type = 'number',
        id = 'cell_' .. x .. '_2_polyphony',
        name = 'cell ' .. x .. ' polyphony',
        min = 1, max = 8, default = 4,
        action = function(v)
            local Roles = require 'lib/cell_roles'
            Roles.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_2_bus_routing',
        name = 'cell ' .. x .. ' bus routing',
        options = VoiceParams.BUS_ROUTING_OPTIONS,
        default = 1,
        action = function(routing_idx)
            local bus_idx = VoiceParams.bus_idx_for(routing_idx)
            local role = ROLE_NAMES[params:get('cell_' .. x .. '_2_role')]
            if role == 'TriSin' then
                engine.trisin_reroute(cell_id, bus_idx)
            elseif role == 'Ringer' then
                engine.ringer_reroute(cell_id, bus_idx)
            end
        end,
    }

    -- ── TriSin-only params (16) ──
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_carrier_ratio',
        name = 'cell ' .. x .. ' fm carrier ratio',
        controlspec = cs.new(0.1, 16, 'lin', 0.01, 1, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'cRatio', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_modulator_ratio',
        name = 'cell ' .. x .. ' fm modulator ratio',
        controlspec = cs.new(0.1, 16, 'lin', 0.01, 1, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'mRatio', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_index',
        name = 'cell ' .. x .. ' fm index',
        controlspec = cs.new(0, 20, 'lin', 0.01, 1, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'index', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_iscale',
        name = 'cell ' .. x .. ' fm iScale',
        controlspec = cs.new(0.1, 20, 'lin', 0.01, 5, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'iScale', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_attack',
        name = 'cell ' .. x .. ' attack',
        controlspec = cs.new(0, 5, 'lin', 0.01, 0, 's'),
        action = function(v) VoiceParams._set_trisin_only(x, 'attack', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_release',
        name = 'cell ' .. x .. ' release',
        controlspec = cs.new(0, 10, 'lin', 0.01, 0.4, 's'),
        action = function(v) VoiceParams._set_trisin_only(x, 'release', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_attack_curve',
        name = 'cell ' .. x .. ' attack curve',
        controlspec = cs.new(-10, 10, 'lin', 0.1, 4, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'cAtk', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_release_curve',
        name = 'cell ' .. x .. ' release curve',
        controlspec = cs.new(-10, 10, 'lin', 0.1, -4, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'cRel', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_env_attack',
        name = 'cell ' .. x .. ' fm env attack',
        controlspec = cs.new(0, 5, 'lin', 0.01, 0, 's'),
        action = function(v) VoiceParams._set_trisin_only(x, 'iattack', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_env_release',
        name = 'cell ' .. x .. ' fm env release',
        controlspec = cs.new(0, 10, 'lin', 0.01, 0.4, 's'),
        action = function(v) VoiceParams._set_trisin_only(x, 'irelease', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_env_attack_curve',
        name = 'cell ' .. x .. ' fm env attack curve',
        controlspec = cs.new(-10, 10, 'lin', 0.1, 4, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'ciAtk', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_env_release_curve',
        name = 'cell ' .. x .. ' fm env release curve',
        controlspec = cs.new(-10, 10, 'lin', 0.1, -4, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'ciRel', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_cutoff',
        name = 'cell ' .. x .. ' cutoff',
        controlspec = cs.new(20, 18000, 'exp', 1, 8000, 'Hz'),
        action = function(v) VoiceParams._set_trisin_only(x, 'cutoff', v) end,
    }
    params:add{
        type = 'number',
        id = 'cell_' .. x .. '_2_cutoff_env',
        name = 'cell ' .. x .. ' cutoff env',
        min = 0, max = 1, default = 1,
        action = function(v) VoiceParams._set_trisin_only(x, 'cutoff_env', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_resonance',
        name = 'cell ' .. x .. ' resonance',
        controlspec = cs.new(0, 4, 'lin', 0.01, 3, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'resonance', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_freq_slew',
        name = 'cell ' .. x .. ' freq slew',
        controlspec = cs.new(0, 5, 'lin', 0.01, 0, 's'),
        action = function(v) VoiceParams._set_trisin_only(x, 'freq_slew', v) end,
    }

    -- ── Ringer-only param (1) ──
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_decay',
        name = 'cell ' .. x .. ' decay',
        controlspec = cs.new(0.1, 20, 'lin', 0.01, 3, ''),
        action = function(v) VoiceParams._set_ringer_only(x, 'index', v) end,
    }

    -- ── MIDI-only param (1; gate time is global) ──
    params:add{
        type = 'number',
        id = 'cell_' .. x .. '_2_midi_channel',
        name = 'cell ' .. x .. ' midi channel',
        min = 1, max = 16, default = 1,
        action = function(_)
            local Midi = require 'lib/midi_role'
            Midi.on_channel_change(x, 2)
        end,
    }

    -- ── Per-cell randomize trigger (1) ──
    params:add{
        type = 'trigger',
        id = 'cell_' .. x .. '_2_randomize',
        name = 'cell ' .. x .. ' randomize',
        action = function() VoiceParams.randomize_row2_cell(x) end,
    }
end

-- Default role per column (mirrors lib/cell_roles.lua ROW_2_DEFAULTS)
function VoiceParams._default_role_index(x)
    local Roles = require 'lib/cell_roles'
    local role_name = Roles.ROW_2_DEFAULTS[x] or 'TriSin'
    for i, name in ipairs(ROLE_NAMES) do
        if name == role_name then return i end
    end
    return 1  -- TriSin
end

-- Dispatch a shared cell param (amp, pan, etc.) to the currently-active role's
-- SC instance. No-op if the role doesn't have an SC voice (crow/MIDI/etc.).
function VoiceParams._set_cell_param(x, param_key, val)
    local cell_id = string.format("%d_2", x)
    local role = ROLE_NAMES[params:get('cell_' .. x .. '_2_role')]
    if role == 'TriSin' then
        engine.trisin_set_param(cell_id, param_key, val)
    elseif role == 'Ringer' then
        engine.ringer_set_param(cell_id, param_key, val)
    end
end

function VoiceParams._set_trisin_only(x, param_key, val)
    local cell_id = string.format("%d_2", x)
    local role = ROLE_NAMES[params:get('cell_' .. x .. '_2_role')]
    if role == 'TriSin' then
        engine.trisin_set_param(cell_id, param_key, val)
    end
end

function VoiceParams._set_ringer_only(x, param_key, val)
    local cell_id = string.format("%d_2", x)
    local role = ROLE_NAMES[params:get('cell_' .. x .. '_2_role')]
    if role == 'Ringer' then
        engine.ringer_set_param(cell_id, param_key, val)
    end
end

-- Update param visibility based on current role.
function VoiceParams._update_row2_visibility(x, role)
    local trisin_only = {
        'fm_carrier_ratio', 'fm_modulator_ratio', 'fm_index', 'fm_iscale',
        'attack', 'release', 'attack_curve', 'release_curve',
        'fm_env_attack', 'fm_env_release', 'fm_env_attack_curve', 'fm_env_release_curve',
        'cutoff', 'cutoff_env', 'resonance', 'freq_slew',
    }
    local ringer_only = { 'decay' }
    local midi_only = { 'midi_channel' }
    local shared = { 'amp', 'amp_slew', 'pan', 'pan_slew', 'polyphony', 'bus_routing' }

    local prefix = 'cell_' .. x .. '_2_'
    local function show_or_hide(list, show)
        for _, p in ipairs(list) do
            if show then
                params:show(prefix .. p)
            else
                params:hide(prefix .. p)
            end
        end
    end

    -- Shared params are only meaningful for SC voices (TriSin/Ringer); hide
    -- for crow/JF/w/* roles since amp/pan/poly/bus don't apply to them.
    -- MIDI uses shared amp? No — MIDI has fixed velocity from sequins. So
    -- only show shared for TriSin or Ringer.
    show_or_hide(shared, role == 'TriSin' or role == 'Ringer')
    show_or_hide(trisin_only, role == 'TriSin')
    show_or_hide(ringer_only, role == 'Ringer')
    show_or_hide(midi_only, role == 'MIDI')

    _menu.rebuild_params()
end

-- Per-cell randomize (limited to current role's params)
function VoiceParams.randomize_row2_cell(x)
    local role = ROLE_NAMES[params:get('cell_' .. x .. '_2_role')]
    local prefix = 'cell_' .. x .. '_2_'
    params:set(prefix .. 'amp', math.random(20, 80) / 100)
    params:set(prefix .. 'pan', (math.random() * 2) - 1)
    if role == 'TriSin' then
        params:set(prefix .. 'fm_index', math.random(0, 10))
        params:set(prefix .. 'cutoff', math.random(500, 12000))
        params:set(prefix .. 'resonance', math.random(50, 350) / 100)
    elseif role == 'Ringer' then
        params:set(prefix .. 'decay', math.random(50, 1500) / 100)
    end
end

return VoiceParams
