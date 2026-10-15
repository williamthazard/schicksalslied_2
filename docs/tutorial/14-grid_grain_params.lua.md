# `lib/grid_grain_params.lua` — Line-by-Line

The granular delay params block. **255 lines**. A single function (`Grain.add_params`) that declares the entire granular subsystem's parameter surface.

Conceptual context: [chapter 13](13-voice_params.lua.md) (the broader params surface this module slots into) and [chapter 03](03-Lied.sc.md) (the granular chain on the SC side that these params drive).

Sections:

1. Header + imports (lines 1-6)
2. `add_params` group + state toggles (lines 8-62)
3. Granular engine params (lines 64-148)
4. Feedback patch surface (lines 150-172)
5. Feedback patch advanced (lines 174-196)
6. Per-grain LFO rates (lines 198-223)
7. Randomize trigger + grain_delay_scale (lines 225-243)
8. `randomize_all_rates` (lines 245-253)
9. Module return (line 255)

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
```

**Lines 8-43**: the capacity comment, the group, the master-amps separator, and the first state toggle.

`params:add_group('granular_delay', 'granular delay', 39)` opens a collapsible group in the params menu. The 39 is the expected param count (used for layout calculations), and the comment documents the arithmetic so it can be re-checked whenever a param is added or removed. The 2 master amps (`mic_to_delay_amp`, `granular_out_amp`) are added by `schicksalslied.lua` AFTER this function returns, which is why they appear last in the group and are counted here. (An earlier build had a third master amp, `mic_dry_amp`; it is gone, see the Insight below.)

The first state toggle: `mic_to_delay_state` controls the mic→delay path. The action:

1. Write `Toggled[14][8] = (idx == 2)` — keeps the grid in sync (col 14 row 8 is the corresponding grid cell).
2. Read `mic_to_delay_amp` (the current user value).
3. Send `engine.set_mic_amp((idx == 2) and on_value or 0)`. If state is on, send the user's amp value; if off, send 0.
4. Mark grid dirty.

This is the state+amp pair pattern (covered in chapter 13): the toggle gates the amp; the amp determines the "on" level. The amp params (declared in `schicksalslied.lua`) close the loop from the other side: each amp's action pushes its value to SC live, but only while its state toggle is on — so turning `granular_out_amp` mid-performance fades the running grains, while turning it with the toggle off just stores the level for the next switch-on (and never re-opens the path or allocates the chain).

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
```

**Lines 44-62**: the second state toggle, for `granular_out` (col 15 row 8). Same shape as the first.

`★ Insight ─────────────────────────────────────`
**The state+amp pair covers cols 14 and 15; the other two right-edge cells are different.** Col 13 is **granular freeze** (it has a plain on/off param, `granular_freeze`, below, and no amp). Col 16 is **not a param of this module at all**: it is a shortcut to the norns system **LEVELS monitor** (`monitor_level`), handled in `schicksalslied.lua` (chapter 19). The old `mic_dry_state` / `mic_dry_amp` pair and the SC `liedMicDry` synth that passed the mic dry through the engine were removed, so the dry mic never enters SuperCollider and cannot feed the feedback patch.

**The "state determines whether to send the amp or 0"** is what makes the granular chain lazy. With state off, every setter sends 0 (silent). The kernel's `ensureGranularChain` only allocates when an amp is set to non-zero. So with both states off at script start, the granular chain stays unallocated (saves CPU + memory).
`─────────────────────────────────────────────────`

## 2b. Granular engine params

```lua
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
```

**Lines 64-82**: the separator and **granular freeze** (grid row 8 col 13). The action keeps `Toggled[13][8]` in sync, then sends `engine.set_granular_freeze(idx - 1)`, which stops the write head and pauses the recorder while the grains keep playing the frozen buffer. `params:set_save('granular_freeze', false)` excludes it from PSETs: the delay buffer itself isn't saved, so recalling a PSET with freeze on would bring the chain up frozen on an empty, silent buffer.

The rest of the engine group follows one pattern: a param whose action sends one engine command.

| Param (id) | Menu name | Range / options | Engine command | Effect |
|---|---|---|---|---|
| `buffer_preservation` | buffer preservation | 0-1, default 0 | `set_rec_pre_level` | how much of the old buffer survives each recording pass (0 = overwrite; recirculation is softclipped) |
| `grain_window` | grain window | hann / percussive / swell / reverse swell | `set_grain_window` (idx - 1) | grain envelope shape |
| `grain_sync_distribution` | grain sync distribution | 0-1, default 1 | `set_grain_sync_distribution` | 1 = regular synchronized grain triggers, 0 = random (Dust) triggers |
| `granular_cutoff_ceiling` | grain cutoff ceiling | 200-16000 Hz exp, default 16000 | `set_grain_cutoff_ceiling` | caps every grain's filter cutoff |
| `grain_rate_mult` | grain rate mult | 0.25-4x, default 1 | `set_grain_rate_mult` | multiplies all grain playback rates |
| `grain_octaves` | grain octaves | off / on | `set_grain_octaves` (idx - 1) | octave-up rates in the grain table |
| `grain_fifths` | grain fifths & 4ths | off / on | `set_grain_fifths` (idx - 1) | fifth and fourth rates |
| `grain_suboctaves` | grain sub-octaves | off / on | `set_grain_suboctaves` (idx - 1) | octave-down rates |
| `grain_reverse` | grain reverse | off / on | `set_grain_reverse` (idx - 1) | every other grain plays backwards |

All ten are counted in the group capacity above. Their kernel side is covered in chapter 03 ("Granular engine setters"); the three interval switches and the rate multiplier all end in `applyTapRates`, which also recomputes each grain's trigger density so a live rate change sounds like a freshly built chain.

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
        controlspec = controlspec.new(5, 2000, 'exp', 1, 12, 'Hz'),
        action = function(v) engine.set_fb_hpf(v) end,
    }
```

**Lines 150-172**: feedback patch's three "surface" params (the commonly-tweaked ones).

- **`feedback_amp`** — overall feedback gain. Range 0-2 linear, default 0. The "amount of self-feedback in the granular chain." Turning this up makes the granular chain self-modulating — output feeds back into mic input.
- **`feedback_balance`** — L/R balance for the feedback signal. Range -1 to 1, default 0 (centered). Sometimes useful to bias the feedback to one channel.
- **`feedback_hpf`** — high-pass filter cutoff on the feedback. Range 5-2000 Hz exponential, default 12 Hz (basically off). Higher cutoff removes more low frequencies from the feedback path — important for preventing runaway sub-bass buildup.

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

**Lines 174-196**: feedback patch's three "advanced" params.

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

**Lines 198-223**: 4 grains × 3 LFO rates each = 12 params. Each LFO controls one aspect of one grain's modulation:

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

**Lines 225-243**: the panic-mash randomize trigger + the `grain_delay_scale` master param.

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

**Lines 246-253**: implementation of the randomize trigger.

Iterates the 4 grains × 3 rates. For each, set a random value via `params:set(pid, new_value)`. Setting a param fires its action, which dispatches to the kernel — so the new rates propagate to SC immediately.

`math.random(10, 6400) / 100` produces a float in [0.10, 64.00] with 0.01 step granularity. Matches the controlspec's range (1-64) but allows finer-grained values than the integer-only `math.random` produces directly.

`print('Grain LFO rates randomized.')` is a log line so the user can confirm the action fired.

## 8. Module return

```lua
return Grain
```

**Line 255**: standard return.

## Summary

`grid_grain_params.lua` is 255 lines: a single function declaring the granular subsystem's params + one helper. The patterns to internalize:

- **Group capacity comment**: documenting the math behind the group's expected param count helps future maintainers verify correctness when adding/removing params.
- **State+amp pair pattern** (2×): the mic-to-delay and granular-out cells each have a state toggle that gates the corresponding amp (freeze is a plain toggle; col 16 is the LEVELS monitor shortcut).
- **"Surface" vs "advanced" separators** organize the params menu by user-facing importance.
- **Random defaults at declaration time** for params that benefit from initial variety.
- **Trigger params for bulk operations** (the randomize button).
- **Cross-file responsibility split**: the granular master amps are added by `schicksalslied.lua` rather than here, falling under this file's "master amps" separator. Slightly unusual; documented in the comment.

To add a new granular param, add a `params:add{...}` block in the appropriate section (likely the advanced separator group) and add a matching kernel setter. The pattern is unambiguous and the example density makes it easy to extend.
