-- lib/voice_params.lua — helpers for building per-voice / per-cell param blocks
-- Spec §5 (samplers + one-shots), §9 (row-2 voices)

local Roles  = include 'lib/cell_roles'
local Midi   = include 'lib/midi_role'
local Grain  = include 'lib/grid_grain_params'
local Timing = include 'lib/timing'

local VoiceParams = {}

-- ────────────────────────────────────────────────────────────────────────
-- SAMPLER PARAM BLOCK (called from schicksalslied.lua's add_params for
-- slots 1..16). Adds 9 params per sampler (file param is added separately
-- by the caller — see Task 5.2).
-- ────────────────────────────────────────────────────────────────────────
function VoiceParams.add_sampler_block(slot)
    -- Sampler state — toggles the trigger cell on/off.
    do
        local trigger_col, trigger_row
        if slot <= 8 then
            trigger_col, trigger_row = (slot * 2) - 1, 4
        else
            trigger_col, trigger_row = ((slot - 8) * 2) - 1, 6
        end
        params:add{
            type = 'option',
            id = 'sampler_' .. slot .. '_state',
            name = 'looping sampler ' .. slot .. ' state',
            options = { 'off', 'on' },
            default = 1,
            action = function(idx)
                _G.GlobalSequencer.Toggled[trigger_col][trigger_row] = (idx == 2)
                grid_dirty = true
            end,
        }
    end
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
            local R = _G.GlobalRoles or Roles
            R.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'control', id = 'sampler_' .. slot .. '_dry_send',
        name = 'sampler ' .. slot .. ' dry send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) engine.sampler_set_param(slot, 'dry_send', v) end,
    }
    params:add{
        type = 'control', id = 'sampler_' .. slot .. '_reverb_send',
        name = 'sampler ' .. slot .. ' reverb send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) engine.sampler_set_param(slot, 'reverb_send', v) end,
    }
    params:add{
        type = 'control', id = 'sampler_' .. slot .. '_delay_send',
        name = 'sampler ' .. slot .. ' delay send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) engine.sampler_set_param(slot, 'delay_send', v) end,
    }
    params:add{
        type = 'control', id = 'sampler_' .. slot .. '_granular_send',
        name = 'sampler ' .. slot .. ' granular send',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.sampler_set_param(slot, 'granular_send', v) end,
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
        type = 'option',
        id = 'oneshot_' .. slot .. '_state',
        name = 'one-shot ' .. slot .. ' state',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[slot][8] = (idx == 2)
            grid_dirty = true
        end,
    }
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
            local cell_id = string.format("%d_%d", slot, 8)
            local R = _G.GlobalRoles or Roles
            R.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'control', id = 'oneshot_' .. slot .. '_dry_send',
        name = 'one-shot ' .. slot .. ' dry send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) engine.oneshot_set_param(slot, 'dry_send', v) end,
    }
    params:add{
        type = 'control', id = 'oneshot_' .. slot .. '_reverb_send',
        name = 'one-shot ' .. slot .. ' reverb send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) engine.oneshot_set_param(slot, 'reverb_send', v) end,
    }
    params:add{
        type = 'control', id = 'oneshot_' .. slot .. '_delay_send',
        name = 'one-shot ' .. slot .. ' delay send',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) engine.oneshot_set_param(slot, 'delay_send', v) end,
    }
    params:add{
        type = 'control', id = 'oneshot_' .. slot .. '_granular_send',
        name = 'one-shot ' .. slot .. ' granular send',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.oneshot_set_param(slot, 'granular_send', v) end,
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
            -- Use the canonical Roles instance (the one the dispatcher reads).
            -- voice_params.lua's local `Roles` is a different table per include;
            -- writes here wouldn't reach the dispatcher otherwise.
            local R = _G.GlobalRoles or Roles
            R.cell_role[x] = role
            local prev_alloc = R.allocated[cell_id]
            if prev_alloc and prev_alloc ~= role then
                if prev_alloc == 'TriSin' then
                    engine.trisin_free(cell_id)
                elseif prev_alloc == 'Ringer' then
                    engine.ringer_free(cell_id)
                end
                R.allocated[cell_id] = nil
            end
            VoiceParams._update_row2_visibility(x, role)
        end,
    }

    -- ── Cell state — toggles the sequencer cell on/off (mirrors grid press). ──
    -- When turning on, also ensures the SC voice instance is allocated.
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_2_state',
        name = 'cell ' .. x .. ' state',
        options = { 'off', 'on' },
        default = 1,  -- 'off'
        action = function(idx)
            local on = (idx == 2)
            _G.GlobalSequencer.Toggled[x][2] = on
            if on then Roles.ensure_allocated(x, 2) end
            grid_dirty = true
        end,
    }

    -- ── Cell string assignment (gridless workflow) ──
    VoiceParams.add_cell_string_block(x, 2)

    -- ── Seq mode + sub-params (14) — inline after role ──
    VoiceParams.add_cell_seq_mode_block(x, 2)

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
            local R = _G.GlobalRoles or Roles
            R.polyphony[cell_id] = v
        end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_dry_send',
        name = 'cell ' .. x .. ' dry send',
        controlspec = cs.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'dry_send', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_reverb_send',
        name = 'cell ' .. x .. ' reverb send',
        controlspec = cs.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'reverb_send', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_delay_send',
        name = 'cell ' .. x .. ' delay send',
        controlspec = cs.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'delay_send', v) end,
    }
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_granular_send',
        name = 'cell ' .. x .. ' granular send',
        controlspec = cs.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'granular_send', v) end,
    }

    -- ── Pitch offset (semitones, applied before scale quantization) ──
    params:add{
        type = 'number',
        id = 'cell_' .. x .. '_2_pitch_offset',
        name = 'cell ' .. x .. ' pitch offset',
        min = -36, max = 36, default = 0,
        formatter = function(param)
            local v = param:get()
            local suffix = ''
            if v == 0 then suffix = ' (unison)'
            elseif v % 12 == 0 then suffix = string.format(' (%+d oct)', v / 12)
            elseif math.abs(v) == 7 then suffix = v > 0 and ' (+P5)' or ' (-P5)'
            elseif math.abs(v) == 5 then suffix = v > 0 and ' (+P4)' or ' (-P4)'
            end
            return string.format('%+d st%s', v, suffix)
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
    local shared = { 'amp', 'amp_slew', 'pan', 'pan_slew', 'polyphony',
                     'dry_send', 'reverb_send', 'delay_send', 'granular_send' }

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

    -- pitch_offset applies to all pitched roles; hide only for w/tape looper
    local pitch_offset_visible = (role ~= 'w/tape looper')
    if pitch_offset_visible then
        params:show(prefix .. 'pitch_offset')
    else
        params:hide(prefix .. 'pitch_offset')
    end

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

-- ────────────────────────────────────────────────────────────────────────
-- SEQ_MODE param block per cell (4-option mode + sub-params per mode)
-- ────────────────────────────────────────────────────────────────────────

local SEQ_MODE_OPTIONS = { 'lied', 'fixed', 'seq', 'random' }

function VoiceParams.add_cell_seq_mode_block(x, y)
    local prefix = 'cell_' .. x .. '_' .. y .. '_seq_'

    params:add{
        type = 'option',
        id = prefix .. 'mode',
        name = string.format('cell %d-%d seq mode', x, y),
        options = SEQ_MODE_OPTIONS,
        default = VoiceParams._default_seq_mode_index(x, y),
        action = function(idx)
            VoiceParams._update_seq_mode_visibility(x, y, idx)
        end,
    }
    params:add{
        type = 'control',
        id = prefix .. 'scale',
        name = 'rate scale',
        -- step + min on the same 1/16-beat grid so integer values (1, 2, 4,
        -- 8, ...) are always exact multiples and reachable via encoder.
        controlspec = controlspec.new(0.0625, 64, 'lin', 0.0625,
            VoiceParams._default_seq_scale(x, y), ''),
    }
    -- Option-type timing params: every scroll position is a musical fraction,
    -- so even a fire caught mid-scroll lands on a sensible division. See
    -- lib/timing.lua for the option set. Stored as 1-based indices; consumed
    -- in lib/sequencer.lua via Timing.value(idx).
    params:add{
        type = 'option',
        id = prefix .. 'fixed_value',
        name = 'fixed value',
        options = Timing.labels(),
        default = Timing.idx_for_value(VoiceParams._default_fixed_value(x, y)),
    }
    params:add{
        type = 'number',
        id = prefix .. 'num_steps',
        name = 'num steps',
        min = 1, max = 8, default = 4,
        action = function(n)
            if params:get(prefix .. 'mode') == 3 then
                for s = 1, 8 do
                    local pid = prefix .. 'step_' .. s .. '_duration'
                    if s <= n then params:show(pid) else params:hide(pid) end
                end
                _menu.rebuild_params()
            end
        end,
    }
    for s = 1, 8 do
        params:add{
            type = 'option',
            id = prefix .. 'step_' .. s .. '_duration',
            name = 'step ' .. s .. ' duration',
            options = Timing.labels(),
            default = Timing.idx_for_value(1),
        }
    end
    params:add{
        type = 'option',
        id = prefix .. 'random_min',
        name = 'random min',
        options = Timing.labels(),
        default = Timing.idx_for_value(1),
    }
    params:add{
        type = 'option',
        id = prefix .. 'random_max',
        name = 'random max',
        options = Timing.labels(),
        default = Timing.idx_for_value(16),
    }
    -- Phase offset (beats) applied to clock.sync so cells can fire on different
    -- beat positions for backbeat patterns: e.g., kick on rate=2 phase=0
    -- (beats 0,2,4) + snare on rate=2 phase=1 (beats 1,3,5). Applies in all
    -- modes since clock.sync is shared by all rate computations.
    params:add{
        type = 'control',
        id = prefix .. 'phase',
        name = 'phase offset',
        controlspec = controlspec.new(0, 16, 'lin', 0.0625, 0, 'beats'),
    }
end
-- 15 params per cell: 1 mode + 1 scale + 1 fixed + 1 num_steps + 8 step durations + 2 random + 1 phase.

-- Default seq_mode index per cell.
-- User-decision: all cells default to lied (option index 1) regardless of cell.
-- This loses the naherinlied-specific per-column starting rates but gives a
-- consistent byte-driven starting behavior across the grid. User can change
-- individual cells via PARAMETERS, or trigger 'reset_all_seq_modes' to fire
-- Sequencer.reset_all_seq_modes_to_default (which reads default_seq_mode_for
-- in sequencer.lua — that's the in-memory fallback, no longer reachable via
-- params:bang since all cells start at index 1).
function VoiceParams._default_seq_mode_index(x, y)
    return 1  -- lied
end

function VoiceParams._default_seq_scale(x, y)
    if y == 2 and x >= 3 and x <= 8 then return 8 end
    return 1
end

function VoiceParams._default_fixed_value(x, y)
    if y == 2 then
        if x == 1 or x == 2 then return 8
        elseif x == 13 then return 3
        elseif x == 14 then return 1.5
        elseif x == 15 then return 1
        elseif x == 16 then return 0.5
        end
    elseif y == 4 or y == 6 then return 2 end
    return 1
end

function VoiceParams._update_seq_mode_visibility(x, y, mode_idx)
    local prefix = 'cell_' .. x .. '_' .. y .. '_seq_'
    local sequins_params = { 'scale' }
    local fixed_params = { 'fixed_value' }
    local random_params = { 'random_min', 'random_max' }

    local function show_or_hide(list, show)
        for _, p in ipairs(list) do
            if show then params:show(prefix .. p)
            else params:hide(prefix .. p) end
        end
    end
    show_or_hide(sequins_params, mode_idx == 1)
    show_or_hide(fixed_params, mode_idx == 2)
    show_or_hide(random_params, mode_idx == 4)

    -- user_seq: num_steps is always visible in user_seq; the step rows visible
    -- count tracks num_steps. Outside user_seq, hide all step controls.
    if mode_idx == 3 then
        params:show(prefix .. 'num_steps')
        local n = params:get(prefix .. 'num_steps') or 4
        for s = 1, 8 do
            local pid = prefix .. 'step_' .. s .. '_duration'
            if s <= n then params:show(pid) else params:hide(pid) end
        end
    else
        params:hide(prefix .. 'num_steps')
        for s = 1, 8 do params:hide(prefix .. 'step_' .. s .. '_duration') end
    end
    _menu.rebuild_params()
end

-- ────────────────────────────────────────────────────────────────────────
-- VALUE_MODE param block per cell per value_kind ('position'|'duration'|'rate')
-- ────────────────────────────────────────────────────────────────────────

local VALUE_MODE_OPTIONS = { 'lied', 'fixed', 'seq', 'random' }

function VoiceParams.add_cell_value_mode_block(x, y, value_kind, range_lo, range_hi)
    local prefix = 'cell_' .. x .. '_' .. y .. '_' .. value_kind .. '_'

    params:add{
        type = 'option',
        id = prefix .. 'mode',
        name = string.format('cell %d-%d %s mode', x, y, value_kind),
        options = VALUE_MODE_OPTIONS,
        default = 1,
        action = function(idx)
            VoiceParams._update_value_mode_visibility(x, y, value_kind, idx)
        end,
    }
    -- Rate kind uses option-type params from Timing.RATE_OPTIONS so every
    -- scroll position is a musical playback rate (incl. negatives and 0).
    -- Position/duration are buffer fraction + fractional seconds — not
    -- musical — so they stay continuous with a fine step for precision.
    local rate_mode = (value_kind == 'rate')
    local cs
    if not rate_mode then
        local step = (value_kind == 'position' or value_kind == 'duration') and 0.001
            or (range_hi - range_lo) / 1000
        cs = controlspec.new(range_lo, range_hi, 'lin', step,
            (range_lo + range_hi) / 2, '')
    end

    local function add_value_param(id, name, default_value)
        if rate_mode then
            params:add{
                type = 'option', id = id, name = name,
                options = Timing.rate_labels(),
                default = Timing.rate_idx_for_value(default_value),
            }
        else
            params:add{ type = 'control', id = id, name = name, controlspec = cs }
        end
    end

    add_value_param(prefix .. 'fixed_value', 'fixed value',
        rate_mode and 1 or ((range_lo + range_hi) / 2))
    params:add{
        type = 'number',
        id = prefix .. 'num_steps',
        name = 'num steps',
        min = 1, max = 8, default = 4,
        action = function(n)
            if params:get(prefix .. 'mode') == 3 then
                for s = 1, 8 do
                    local pid = prefix .. 'step_' .. s .. '_value'
                    if s <= n then params:show(pid) else params:hide(pid) end
                end
                _menu.rebuild_params()
            end
        end,
    }
    for s = 1, 8 do
        add_value_param(prefix .. 'step_' .. s .. '_value', 'step ' .. s .. ' value',
            rate_mode and 1 or ((range_lo + range_hi) / 2))
    end
    add_value_param(prefix .. 'random_min', 'random min',
        rate_mode and 0.5 or range_lo)
    add_value_param(prefix .. 'random_max', 'random max',
        rate_mode and 2 or range_hi)
end
-- 13 params per (cell × value_kind): 1 mode + 1 fixed + 1 num_steps + 8 step values + 2 random.

-- Re-fire SC-bound per-slot params so their actions push the current Lua
-- values to the freshly-allocated SC voice instance. Used after file load:
-- loadSampler/loadOneShot create instances with SynthDef defaults, and
-- without this, the Lua-side user values would silently diverge from SC.
-- The engine.set_param calls land in SC's pending-params cache (the instance
-- is still being allocated in a fork) and are applied when alloc completes.
local SC_BOUND_KEYS = {
    'amp', 'amp_slew', 'cutoff', 'resonance', 'pan', 'pan_slew',
    'dry_send', 'reverb_send', 'delay_send', 'granular_send',
}
function VoiceParams.reapply_sampler(slot)
    for _, key in ipairs(SC_BOUND_KEYS) do
        local pid = 'sampler_' .. slot .. '_' .. key
        if params.lookup[pid] then params:set(pid, params:get(pid)) end
    end
end
function VoiceParams.reapply_oneshot(slot)
    for _, key in ipairs(SC_BOUND_KEYS) do
        local pid = 'oneshot_' .. slot .. '_' .. key
        if params.lookup[pid] then params:set(pid, params:get(pid)) end
    end
end

-- ────────────────────────────────────────────────────────────────────────
-- CELL STRING ASSIGNMENT (gridless workflow)
-- ────────────────────────────────────────────────────────────────────────
-- Option-type param per toggle-row cell whose options are:
--   1.  (none)        — cell plays the Sequins({' '}) placeholder
--   2.  (custom)      — cell content doesn't match any single history slot
--                       (e.g., a concatenation assigned via grid)
--   3+. '<n>: <text>' — history slot N, content truncated for display
--
-- Options are rebuilt by VoiceParams.refresh_cell_string_params whenever
-- history mutates (insertion via keyboard ENTER / file load, deletion via
-- Ctrl chord). Selecting a slot writes the corresponding history string
-- into the cell's Sequins via Sequencer.assign(..., silent=true) so the
-- param-side sync doesn't recurse.

-- Bind the sequencer module and install reaction hooks so the cell string
-- params stay in sync with Sequencer.history (option labels) and with
-- per-cell assignments (param value + custom label). NOTE: this function
-- only installs the hooks on the Sequencer module — Sequencer is a single
-- shared instance (exposed as _G.GlobalSequencer), so the hooks fire
-- regardless of which include of voice_params installed them. The refresh
-- functions, however, look up _G.GlobalSequencer at call time rather than
-- capturing a per-include Sequencer ref, because each `include` returns a
-- fresh table with its own locals.
function VoiceParams.bind_sequencer(seq)
    seq.on_history_changed_fn = function()
        VoiceParams.refresh_all_cell_string_params()
    end
    seq.on_cell_assigned_fn = function(x, y)
        VoiceParams.refresh_one_cell_string_param(x, y)
    end
end

local STRING_PARAM_TRUNCATE = 18  -- chars shown per option-label string

-- Build the option list for one cell's string param. `custom_str` is the
-- cell's currently-assigned content when it doesn't match any history slot
-- (e.g., a grid concatenation); it gets embedded into option 2's label so
-- the user can see what the cell actually plays without leaving the menu.
local function build_options_for_cell(custom_str)
    local opts = { '(none)' }
    if custom_str and custom_str ~= '' and custom_str ~= ' ' then
        opts[2] = '(grid: ' .. string.sub(custom_str, 1, STRING_PARAM_TRUNCATE) .. ')'
    else
        opts[2] = '(custom)'
    end
    local Seq = _G.GlobalSequencer
    if Seq and Seq.history then
        for i, s in ipairs(Seq.history) do
            opts[#opts + 1] = string.format('%d: %s', i, string.sub(s, 1, STRING_PARAM_TRUNCATE))
        end
    end
    return opts
end

function VoiceParams.add_cell_string_block(x, y)
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_' .. y .. '_string',
        name = string.format('cell %d-%d string', x, y),
        options = build_options_for_cell(nil),
        default = 1,
        action = function(idx)
            local Seq = _G.GlobalSequencer
            if Seq == nil then return end
            if idx == 1 then
                Seq.assign(x, y, ' ', true)
            elseif idx == 2 then
                -- (custom)/(grid: ...) is a display-only state; selecting it
                -- manually is a no-op (the cell already contains that string).
            else
                local slot = idx - 2
                local s = Seq.history[slot]
                if s then Seq.assign(x, y, s, true) end
            end
        end,
    }
end

-- Cells that get a string param (everything on toggle rows except mic toggles).
local STRING_CELLS = (function()
    local t = {}
    for x = 1, 16 do t[#t + 1] = { x, 2 } end                  -- row 2: all 16
    for y = 4, 6, 2 do
        for x = 1, 16 do t[#t + 1] = { x, y } end              -- rows 4 & 6: all 16
    end
    for x = 1, 13 do t[#t + 1] = { x, 8 } end                  -- row 8 cols 1-13
    return t
end)()

-- Refresh one cell's string param: rebuild its option list with the right
-- custom label, then set its value to reflect the cell's stored assignment.
function VoiceParams.refresh_one_cell_string_param(x, y)
    local Seq = _G.GlobalSequencer
    if Seq == nil then return end
    local pid = 'cell_' .. x .. '_' .. y .. '_string'
    local p = params.lookup and params.lookup[pid] and params:lookup_param(pid)
    if not p then return end

    local stored = Seq._cell_assigned_strings[x .. '_' .. y]
    local slot
    if stored and stored ~= '' and stored ~= ' ' then
        for i, h in ipairs(Seq.history) do
            if h == stored then slot = i; break end
        end
    end

    local custom_str = (stored and not slot and stored ~= '' and stored ~= ' ') and stored or nil
    p.options = build_options_for_cell(custom_str)
    p.count = #p.options

    local opt_idx = (stored == nil or stored == '' or stored == ' ') and 1
        or (slot and (slot + 2) or 2)
    params:set(pid, opt_idx, true)
end

-- Called when history mutates. Rebuilds every cell's options and re-syncs
-- each cell's selected index in case slot indices shifted.
function VoiceParams.refresh_all_cell_string_params()
    for _, c in ipairs(STRING_CELLS) do
        VoiceParams.refresh_one_cell_string_param(c[1], c[2])
    end
    if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

-- ────────────────────────────────────────────────────────────────────────
-- RATE-CELL STATE (sampler rate cells; rows 4/6 even cols)
-- ────────────────────────────────────────────────────────────────────────
-- Adds the missing toggle-state param so rate cells can be controlled via
-- MIDI-mapped params / fully gridless workflows.
function VoiceParams.add_rate_cell_state_block(x, y)
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_' .. y .. '_state',
        name = string.format('cell %d-%d state', x, y),
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[x][y] = (idx == 2)
            grid_dirty = true
        end,
    }
end

function VoiceParams._update_value_mode_visibility(x, y, value_kind, mode_idx)
    local prefix = 'cell_' .. x .. '_' .. y .. '_' .. value_kind .. '_'
    local fixed_params = { 'fixed_value' }
    local random_params = { 'random_min', 'random_max' }

    local function show_or_hide(list, show)
        for _, p in ipairs(list) do
            if show then params:show(prefix .. p)
            else params:hide(prefix .. p) end
        end
    end
    -- mode 1 (lied) hides all sub-params
    show_or_hide(fixed_params, mode_idx == 2)
    show_or_hide(random_params, mode_idx == 4)

    if mode_idx == 3 then
        params:show(prefix .. 'num_steps')
        local n = params:get(prefix .. 'num_steps') or 4
        for s = 1, 8 do
            local pid = prefix .. 'step_' .. s .. '_value'
            if s <= n then params:show(pid) else params:hide(pid) end
        end
    else
        params:hide(prefix .. 'num_steps')
        for s = 1, 8 do params:hide(prefix .. 'step_' .. s .. '_value') end
    end
    _menu.rebuild_params()
end

return VoiceParams
