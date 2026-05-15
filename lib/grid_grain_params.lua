-- lib/grid_grain_params.lua — granular delay params block
-- Spec §6: master amps + fb patch surface + buried + per-grain LFO rates × 8.

local Grain = {}

-- Add the granular delay param group.
-- IMPORTANT: the master amps (mic_to_delay_amp, granular_out_amp, mic_dry_amp)
-- live INSIDE this group too. They are added by schicksalslied.lua's
-- add_params *after* this function returns, so the group capacity here
-- accounts for them.
-- Group capacity breakdown:
--   - 4 separators (master, fb_patch_surface, fb_patch_advanced, grain_lfo_rates)
--   - 3 master amps (added by caller AFTER Grain.add_params returns)
--   - 3 fb patch surface (feedback_amp, feedback_balance, feedback_hpf)
--   - 3 fb patch advanced (noise_inject_level, sine_inject_level, sine_inject_freq)
--   - 24 grain LFO rates (8 grains × 3 params)
--   - 1 randomize-all trigger
-- Total: 4 + 3 + 3 + 3 + 24 + 1 = 38
function Grain.add_params()
    params:add_group('granular_delay', 38)

    params:add_separator('master_amps_separator', 'master amps')
    -- The 3 master amps are added by schicksalslied.lua's add_params right
    -- AFTER this function returns, so they fall under this separator.

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
        controlspec = controlspec.new(12, 2000, 'exp', 1, 12, 'Hz'),
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

    for n = 0, 7 do
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
end

-- Randomize every grain LFO rate. Updates params (which trigger their actions).
function Grain.randomize_all_rates()
    for n = 0, 7 do
        params:set('grain_' .. n .. '_pan_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_cutoff_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_res_rate', math.random(10, 6400) / 100)
    end
    print('Grain LFO rates randomized.')
end

return Grain
