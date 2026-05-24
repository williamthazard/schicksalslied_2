# `lib/grid_grain_params.lua` — Line-by-Line

The granular delay params block. **176 lines**. A single function (`Grain.add_params`) that declares the entire granular subsystem's parameter surface.

Conceptual context: [chapter 13](13-voice_params.lua.md) (the broader params surface this module slots into) and [chapter 03](03-Lied.sc.md) (the granular chain on the SC side that these params drive).

Sections:

1. Header + imports (lines 1-6)
2. `add_params` group + state toggles (lines 8-69)
3. Feedback patch surface (lines 71-93)
4. Feedback patch advanced (lines 95-117)
5. Per-grain LFO rates (lines 119-143)
6. Randomize trigger + grain_delay_scale (lines 145-164)
7. `randomize_all_rates` (lines 166-174)
8. Module return (line 176)

## 1. Header and imports

```lua
-- lib/grid_grain_params.lua — granular delay params block
-- Spec §6: master amps + fb patch surface + buried + per-grain LFO rates × 8.

local Roles = include 'lib/cell_roles'

local Grain = {}
```

**Lines 1-6**: header + imports.

The `Roles` import is present but unused in this file (a leftover from earlier development). The module table starts empty.

## 2. `add_params` group + state toggles

```lua
function Grain.add_params()
    params:add_group('granular_delay', 'granular delay', 30)

    params:add_separator('master_amps_separator', 'master amps')
    -- The 3 master amps are added by schicksalslied.lua's add_params right
    -- AFTER this function returns, so they fall under this separator.
    -- The 3 state params below toggle those amp controls on/off.

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
```

**Lines 23-43**: open the group, add the master-amps separator, declare the first state toggle.

`params:add_group('granular_delay', 'granular delay', 30)` opens a collapsible group in the params menu. The 30 is the expected param count (used for layout calculations).

`params:add_separator('master_amps_separator', 'master amps')` is a visual divider. The 3 master amps (`mic_to_delay_amp`, `granular_out_amp`, `mic_dry_amp`) are added by `schicksalslied.lua` AFTER this function returns — that's an unusual cross-file split, documented in the comment.

The first state toggle: `mic_to_delay_state` controls the mic→delay path. The action:

1. Write `Toggled[14][8] = (idx == 2)` — keeps the grid in sync (col 14 row 8 is the corresponding grid cell).
2. Read `mic_to_delay_amp` (the current user value).
3. Send `engine.set_mic_amp((idx == 2) and on_value or 0)`. If state is on, send the user's amp value; if off, send 0.
4. Mark grid dirty.

This is the state+amp pair pattern (covered in chapter 13): the toggle gates the amp; the amp determines the "on" level.

```lua
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
    params:add{
        type = 'option',
        id = 'mic_dry_state',
        name = 'mic dry state',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            _G.GlobalSequencer.Toggled[16][8] = (idx == 2)
            local on_value = params:get('mic_dry_amp')
            engine.set_mic_dry_amp((idx == 2) and on_value or 0)
            grid_dirty = true
        end,
    }
```

**Lines 44-69**: two more state toggles for `granular_out` (col 15 row 8) and `mic_dry` (col 16 row 8). Same shape as the first.

`★ Insight ─────────────────────────────────────`
**The triple state-toggle pattern for col 14, 15, 16 row 8** matches the script's "right edge of row 8 = mic + granular controls" convention. These three cells are the grid surface for engaging the granular chain; the state params are the params-menu equivalent.

**The "state determines whether to send the amp or 0"** is what makes the granular chain lazy. With state off, every setter sends 0 (silent). The kernel's `ensureGranularChain` only allocates when an amp is set to non-zero. So with all three states off at script start, the granular chain stays unallocated (saves CPU + memory).
`─────────────────────────────────────────────────`

## 3. Feedback patch surface

```lua
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
```

**Lines 71-93**: feedback patch's three "surface" params (the commonly-tweaked ones).

- **`feedback_amp`** — overall feedback gain. Range 0-2 linear, default 0. The "amount of self-feedback in the granular chain." Turning this up makes the granular chain self-modulating — output feeds back into mic input.
- **`feedback_balance`** — L/R balance for the feedback signal. Range -1 to 1, default 0 (centered). Sometimes useful to bias the feedback to one channel.
- **`feedback_hpf`** — high-pass filter cutoff on the feedback. Range 12-2000 Hz exponential, default 12 Hz (basically off). Higher cutoff removes more low frequencies from the feedback path — important for preventing runaway sub-bass buildup.

All three actions dispatch to the corresponding kernel setter.

## 4. Feedback patch advanced

```lua
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
```

**Lines 95-117**: feedback patch's three "advanced" params.

- **`noise_inject_level`** — pink noise added to the feedback path. Adds energy that sustains the feedback loop even when the input is quiet.
- **`sine_inject_level`** — sine wave added to the feedback path. Adds a tonal element.
- **`sine_inject_freq`** — the sine's frequency. Default 55 Hz (a low rumble).

These are tagged "(advanced)" because they produce drastic textural changes. Most users will leave them at 0; experimental users can dial them in.

## 5. Per-grain LFO rates

```lua
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
```

**Lines 119-143**: 4 grains × 3 LFO rates each = 12 params. Each LFO controls one aspect of one grain's modulation:

- **`grain_N_pan_rate`** — period of grain N's pan LFO (in beats).
- **`grain_N_cutoff_rate`** — period of grain N's cutoff LFO.
- **`grain_N_res_rate`** — period of grain N's resonance LFO.

These map to the Ndefs created in `Lied.sc`'s `ensureGranularChain` (the per-grain LFOs we discussed in chapter 03 section 10).

Two notable things:

1. **Indexing**: the param IDs use `n = 0..3` (0-based) because the SC kernel's `grainPanRates`, `grainCutoffRates`, `grainResRates` arrays are 0-indexed (`Array.fill(grainCount, ...)` creates 0-indexed arrays). The display names use `(n + 1)` so the user sees grain 1-4 in the menu.

2. **Random defaults**: `math.random(1, 64)` generates a random initial rate per param. This is what gives the granular chain its "interesting out of the box" character — different grains have different LFO periods, producing varied modulation.

The action dispatches to the corresponding kernel setter (`engine.set_grain_pan_rate(n, v)` etc.). The kernel updates the Ndef, which in turn updates the LFO running on the server.

`★ Insight ─────────────────────────────────────`
**Random defaults at param-creation time** is a small but effective UX touch. Without it, all 12 LFO rate params would default to the same value (e.g., 8 beats). The result: 4 grains all modulating at the same rate, in lockstep — boring, robotic-sounding. With random defaults, the grains start out polyrhythmic, producing organic-feeling modulation.

**The downside**: the random values aren't stable across script reloads (unless they're saved to PSET, which they are). Without a PSET, every fresh script load gives different starting rates. For most users this is fine — they save a PSET once they like the sound — but it's worth knowing.
`─────────────────────────────────────────────────`

## 6. Randomize trigger + grain_delay_scale

```lua
    params:add{
        type = 'trigger',
        id = 'randomize_grain_lfo_rates',
        name = 'randomize all grain LFO rates',
        action = function() Grain.randomize_all_rates() end,
    }

    params:add{
        type = 'control',
        id = 'grain_delay_scale',
        name = 'grain delay scale',
        controlspec = controlspec.new(0.01, 2.0, 'lin', 0.01, 1.0, ''),
        action = function(v) engine.set_grain_delay_scale(v) end,
    }
end
```

**Lines 145-164**: the panic-mash randomize trigger + the `grain_delay_scale` master param.

- **`randomize_grain_lfo_rates`** — trigger param. Action calls `Grain.randomize_all_rates` (defined below). Useful for quickly throwing the granular character into a new texture.

- **`grain_delay_scale`** — multiplier on the per-grain lookback distances. Range 0.01 to 2.0, default 1.0 (the Carter's Delay character: grains read 8-64 sec back). Set to 0.1 for ~1 sec lookback (much more immediate). Set to 2.0 for ~16-128 sec lookback (very long, evolving).

The comment notes the param takes effect on the NEXT granular allocation — not on the currently-running chain. To apply: toggle granular off + on, or panic + re-engage.

## 7. `randomize_all_rates`

```lua
function Grain.randomize_all_rates()
    for n = 0, 3 do
        params:set('grain_' .. n .. '_pan_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_cutoff_rate', math.random(10, 6400) / 100)
        params:set('grain_' .. n .. '_res_rate', math.random(10, 6400) / 100)
    end
    print('Grain LFO rates randomized.')
end
```

**Lines 167-174**: implementation of the randomize trigger.

Iterates the 4 grains × 3 rates. For each, set a random value via `params:set(pid, new_value)`. Setting a param fires its action, which dispatches to the kernel — so the new rates propagate to SC immediately.

`math.random(10, 6400) / 100` produces a float in [0.10, 64.00] with 0.01 step granularity. Matches the controlspec's range (1-64) but allows finer-grained values than the integer-only `math.random` produces directly.

`print('Grain LFO rates randomized.')` is a log line so the user can confirm the action fired.

## 8. Module return

```lua
return Grain
```

**Line 176**: standard return.

## Summary

`grid_grain_params.lua` is 176 lines: a single function declaring the granular subsystem's params + one helper. The patterns to internalize:

- **Group capacity comment**: documenting the math behind the group's expected param count helps future maintainers verify correctness when adding/removing params.
- **State+amp pair pattern** (3×): each grid-controllable thing has a state toggle that gates the corresponding amp.
- **"Surface" vs "advanced" separators** organize the params menu by user-facing importance.
- **Random defaults at declaration time** for params that benefit from initial variety.
- **Trigger params for bulk operations** (the randomize button).
- **Cross-file responsibility split**: the granular master amps are added by `schicksalslied.lua` rather than here, falling under this file's "master amps" separator. Slightly unusual; documented in the comment.

To add a new granular param, add a `params:add{...}` block in the appropriate section (likely the advanced separator group) and add a matching kernel setter. The pattern is unambiguous and the example density makes it easy to extend.
