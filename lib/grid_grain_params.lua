-- lib/grid_grain_params.lua — granular delay params block
-- Spec §6: master amps + fb patch surface + buried + per-grain LFO rates × 8.

local Roles = include 'lib/cell_roles'

local Grain = {}

-- Add the granular delay param group.
-- IMPORTANT: the master amps (mic_to_delay_amp, granular_out_amp) live
-- INSIDE this group too. They are added by schicksalslied.lua's add_params
-- *after* this function returns (so they're the group's last 2 params), and
-- the group capacity here accounts for them.
-- Group capacity breakdown:
--   - 5 separators (master_amps, grain_engine, fb_patch_surface,
--     fb_patch_advanced, grain_lfo_rates)
--   - 2 master amp state toggles (mic_to_delay_state, granular_out_state)
--   - 10 granular engine (granular_freeze, buffer_preservation, grain_window,
--     grain_sync_distribution, granular_cutoff_ceiling, grain_rate_mult,
--     grain_octaves, grain_fifths, grain_suboctaves, grain_reverse)
--   - 3 fb patch surface (feedback_amp, feedback_balance, feedback_hpf)
--   - 3 fb patch advanced (noise_inject_level, sine_inject_level, sine_inject_freq)
--   - 12 grain LFO rates (4 grains × 3 params)
--   - 1 randomize-all trigger
--   - 1 grain_delay_scale
--   - 2 master amps (added by caller AFTER Grain.add_params returns)
-- Total: 5 + 2 + 10 + 3 + 3 + 12 + 1 + 1 + 2 = 39
-- (Row 8 col 16, mic monitoring, is the norns LEVELS monitor — see
-- schicksalslied.lua — so it has no param here.)
function Grain.add_params()
    params:add_group('granular_delay', 'granular delay', 39)

    params:add_separator('master_amps_separator', 'master amps')
    -- The 2 state params below toggle the master amps on/off. The amps
    -- themselves are added by schicksalslied.lua after this function
    -- returns, so they show at the end of the group.

    params:add{
        type = 'option',
        id = 'mic_to_delay_state',
        name = 'mic to delay state',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[14][8] = (idx == 2)
            local on_value = params:get('mic_to_delay_amp')
            engine.set_mic_amp((idx == 2) and on_value or 0)
            grid_dirty = true
        end,
    }
    params:add{
        type = 'option',
        id = 'granular_out_state',
        name = 'granular out state',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[15][8] = (idx == 2)
            local on_value = params:get('granular_out_amp')
            engine.set_granular_out_amp((idx == 2) and on_value or 0)
            grid_dirty = true
        end,
    }

    params:add_separator('grain_engine_separator', 'granular engine')

    params:add{
        type = 'option',
        id = 'granular_freeze',
        name = 'granular freeze',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[13][8] = (idx == 2)
            engine.set_granular_freeze(idx - 1)
            grid_dirty = true
        end,
    }
    -- Not saved in PSETs: the delay buffer isn't saved, so recalling 'on'
    -- would bring the chain up frozen on an empty (silent) buffer.
    params:set_save('granular_freeze', false)
    params:add{
        type = 'control',
        id = 'buffer_preservation',
        name = 'buffer preservation',
        controlspec = controlspec.new(0.0, 1.0, 'lin', 0.01, 0.0, ''),
        action = function(v) engine.set_rec_pre_level(v) end,
    }
    params:add{
        type = 'option',
        id = 'grain_window',
        name = 'grain window',
        options = { 'hann', 'percussive', 'swell', 'reverse swell' },
        default = 1,
        action = function(idx) engine.set_grain_window(idx - 1) end,
    }
    params:add{
        type = 'control',
        id = 'grain_sync_distribution',
        name = 'grain sync distribution',
        controlspec = controlspec.new(0.0, 1.0, 'lin', 0.01, 1.0, ''),
        action = function(v) engine.set_grain_sync_distribution(v) end,
    }
    params:add{
        type = 'control',
        id = 'granular_cutoff_ceiling',
        name = 'grain cutoff ceiling',
        controlspec = controlspec.new(200, 16000, 'exp', 1, 16000, 'Hz'),
        action = function(v) engine.set_grain_cutoff_ceiling(v) end,
    }
    params:add{
        type = 'control',
        id = 'grain_rate_mult',
        name = 'grain rate mult',
        controlspec = controlspec.new(0.25, 4.0, 'lin', 0.01, 1.0, 'x'),
        action = function(v) engine.set_grain_rate_mult(v) end,
    }
    params:add{
        type = 'option',
        id = 'grain_octaves',
        name = 'grain octaves',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx) engine.set_grain_octaves(idx - 1) end,
    }
    params:add{
        type = 'option',
        id = 'grain_fifths',
        name = 'grain fifths & 4ths',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx) engine.set_grain_fifths(idx - 1) end,
    }
    params:add{
        type = 'option',
        id = 'grain_suboctaves',
        name = 'grain sub-octaves',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx) engine.set_grain_suboctaves(idx - 1) end,
    }
    params:add{
        type = 'option',
        id = 'grain_reverse',
        name = 'grain reverse',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx) engine.set_grain_reverse(idx - 1) end,
    }

    params:add_separator('fb_patch_surface', 'feedback patch')

    params:add{
        type = 'control',
        id = 'feedback_amp',
        name = 'feedback amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0, ''),
        action = function(v) engine.set_fb_amp(v) end,
    }
    params:add{
        type = 'control',
        id = 'feedback_balance',
        name = 'feedback balance',
        controlspec = controlspec.new(-1, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.set_fb_balance(v) end,
    }
    params:add{
        type = 'control',
        id = 'feedback_hpf',
        name = 'feedback hpf',
        controlspec = controlspec.new(5, 2000, 'exp', 1, 12, 'Hz'),
        action = function(v) engine.set_fb_hpf(v) end,
    }

    params:add_separator('fb_patch_advanced', '(advanced)')

    params:add{
        type = 'control',
        id = 'noise_inject_level',
        name = 'noise inject level',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.set_fb_noise(v) end,
    }
    params:add{
        type = 'control',
        id = 'sine_inject_level',
        name = 'sine inject level',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) engine.set_fb_sine_level(v) end,
    }
    params:add{
        type = 'control',
        id = 'sine_inject_freq',
        name = 'sine inject freq',
        controlspec = controlspec.new(20, 2000, 'exp', 0.1, 55, 'Hz'),
        action = function(v) engine.set_fb_sine_hz(v) end,
    }

    params:add_separator('grain_lfo_rates', 'grain LFO rates')

    for n = 0, 3 do
        params:add{
            type = 'control',
            id = 'grain_' .. n .. '_pan_rate',
            name = 'grain ' .. (n + 1) .. ' pan rate',
            controlspec = controlspec.new(1, 64, 'lin', 0.1, math.random(1, 64), 'beats'),
            action = function(v) engine.set_grain_pan_rate(n, v) end,
        }
        params:add{
            type = 'control',
            id = 'grain_' .. n .. '_cutoff_rate',
            name = 'grain ' .. (n + 1) .. ' cutoff rate',
            controlspec = controlspec.new(1, 64, 'lin', 0.1, math.random(1, 64), 'beats'),
            action = function(v) engine.set_grain_cutoff_rate(n, v) end,
        }
        params:add{
            type = 'control',
            id = 'grain_' .. n .. '_res_rate',
            name = 'grain ' .. (n + 1) .. ' res rate',
            controlspec = controlspec.new(1, 64, 'lin', 0.1, math.random(1, 64), 'beats'),
            action = function(v) engine.set_grain_res_rate(n, v) end,
        }
    end

    params:add{
        type = 'trigger',
        id = 'randomize_grain_lfo_rates',
        name = 'randomize all grain LFO rates',
        action = function() Grain.randomize_all_rates() end,
    }

    -- Grain delay scale — multiplies the grain ptrSampleDelay values.
    -- Default 1.0 = grains read 8..64 sec back (Carter's Delay character —
    -- long, evolving). Set to ~0.1 for responsive granular output (~1 sec).
    -- Takes effect on NEXT granular allocation: toggle granular off + on (or
    -- panic + re-engage) to apply the new scale.
    params:add{
        type = 'control',
        id = 'grain_delay_scale',
        name = 'grain delay scale',
        controlspec = controlspec.new(0.01, 2.0, 'lin', 0.01, 1.0, ''),
        action = function(v) engine.set_grain_delay_scale(v) end,
    }
end

-- Randomize every grain LFO rate. Updates params (which trigger their actions).
function Grain.randomize_all_rates()
    for n = 0, 3 do
        params:set('grain_' .. n .. '_pan_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_cutoff_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_res_rate', math.random(10, 6400) / 100)
    end
    print('Grain LFO rates randomized.')
end

return Grain
