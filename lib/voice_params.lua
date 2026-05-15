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

return VoiceParams
