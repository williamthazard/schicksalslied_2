# Chapter 13 — `lib/voice_params.lua`

The per-voice / per-cell parameter declaration module. **1,064 source lines** — the largest Lua file in the project. This is where the user-facing params menu structure gets defined, one block helper at a time.

The file is mostly **block helpers**: functions that declare 9-90 params each, called from `schicksalslied.lua:add_params()` in a loop. The patterns repeat heavily, so this chapter establishes each pattern once and then summarizes repeated instances. Reading top-to-bottom, you'll see: how a per-slot sampler block is built (the canonical pattern), how it gets specialized for one-shots, how row-2 voice cells extend the pattern with role-aware dispatch, how dynamic visibility hides irrelevant params based on mode selection, how option-type Timing params replace continuous controlspecs for musical-grid timing, how the `_G.GlobalSequencer` / `_G.GlobalRoles` cross-include workaround appears in practice, how the action-wrapper pattern extends Norns's built-in clock_tempo action, and how the per-cell string assignment param makes the script fully gridless-capable.

This chapter assumes chapter 09's coverage of params (cross-include identity in particular), chapter 11's value-mode and Timing distinction, and chapter 12's `cell_id` and role plumbing.

## Header and imports

```lua
-- lib/voice_params.lua — helpers for building per-voice / per-cell param blocks
-- Spec §5 (samplers + one-shots), §9 (row-2 voices)

local Roles  = include 'lib/cell_roles'
local Midi   = include 'lib/midi_role'
local Grain  = include 'lib/grid_grain_params'
local Timing = include 'lib/timing'

local VoiceParams = {}
```

**Lines 1-9**: file header + four imports + module table.

The `include` calls return file-local references. Because Norns's `include` doesn't cache, **these references are NOT the same as the corresponding references in `schicksalslied.lua` or other includers** (the cross-include identity bug, chapter 09). For state that needs to be shared (e.g., `Roles.cell_role`, `Sequencer.history`), this file uses `_G.GlobalRoles` and `_G.GlobalSequencer` at runtime — the locals declared here serve only as IDE-level documentation, not actual runtime references.

`Timing` is fine to use locally because it has no mutable state — it's a pure lookup module. `Midi` and `Grain` are used locally for their function exports; both have minimal mutable state.

## The sampler block (canonical example: `add_sampler_block`)

Declared once per sampler slot. Called from `schicksalslied.lua:add_params()` in a loop `for slot = 1, 16 do VoiceParams.add_sampler_block(slot) end`.

### The state param

```lua
function VoiceParams.add_sampler_block(slot)
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
```

**Lines 16-36**: the state toggle for the slot's trigger cell. Wrapped in a `do ... end` block to scope the `trigger_col`, `trigger_row` locals — they're used inside the action closure and not needed outside.

The slot-to-(col,row) mapping:
- Slots 1-8 → trigger cells in row 4 at odd columns: slot 1 → (1, 4), slot 2 → (3, 4), ..., slot 8 → (15, 4).
- Slots 9-16 → trigger cells in row 6 at odd columns: slot 9 → (1, 6), slot 10 → (3, 6), ..., slot 16 → (15, 6).

The math `(slot * 2) - 1` gives 1, 3, 5, 7, 9, 11, 13, 15 for slot 1..8. For slots 9-16, `((slot - 8) * 2) - 1` gives the same odd-column pattern but in row 6.

The action: write `Toggled[col][row] = (idx == 2)` (on if option index 2 = 'on') and mark grid dirty. This is the parity with the grid press handler — both paths converge on writing the Toggled table.

`★ Insight ─────────────────────────────────────`
**The state param + action is what makes "grid press" and "MIDI knob" equivalent operations.** A grid press calls `params:set('sampler_5_state', 2)`. A MIDI controller mapped to the state param does the same. The action runs in both cases, writing the Toggled flag and updating the grid. There's no separate code path for "grid-driven toggle" vs "MIDI-driven toggle" — they converge here.

**The `do ... end` block scoping for trigger_col/row** is a small but important style detail. Without it, those locals would be visible throughout the function — confusing because they're only relevant to this one action. With the scoping, the locals are clearly tied to just this param.
`─────────────────────────────────────────────────`

### The continuous params (amp, cutoff, etc.)

```lua
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
```

**Lines 37-78**: six identical-shape continuous params (amp, amp_slew, cutoff, resonance, pan, pan_slew). The pattern:

```lua
params:add{
    type = 'control',
    id = 'sampler_' .. slot .. '_<key>',
    name = 'sampler ' .. slot .. ' <human-readable>',
    controlspec = controlspec.new(min, max, warp, step, default, unit),
    action = function(v) engine.sampler_set_param(slot, '<sc_key>', v) end,
}
```

Differences across the six:
- **amp**: 0-2 linear, default 0.5. Range > 1 because amp is post-fader and combined with send levels — some headroom is useful for loud sources.
- **amp_slew**: 0-5 sec linear, default 0.05. Slew time for amp transitions. Default is short enough to suppress clicks; longer values produce intentional volume swells.
- **cutoff**: 20-18000 Hz **exponential** warp. Exponential because pitch perception is logarithmic; linear cutoff would feel uneven on the encoder.
- **resonance**: 0-4 linear, default 1.
- **pan**: -1 to 1 linear, default 0 (center).
- **pan_slew**: 0-5 sec linear, default 1.

Every action calls `engine.sampler_set_param(slot, 'sc_param_key', value)` — forwarding the value to the SC kernel.

`★ Insight ─────────────────────────────────────`
**The `controlspec.new(min, max, warp, step, default, unit)` is the canonical way to define a continuous param**. The `warp` argument controls how the encoder's linear motion maps to the parameter value: `'lin'` is linear, `'exp'` is exponential. Always use `'exp'` for frequencies, cutoffs, and other perceptually-logarithmic values; use `'lin'` for amps, pans, and other perceptually-linear values.

**The `step` argument** controls the smallest increment. Smaller step = finer resolution but more encoder ticks needed to traverse the range. For amp (0-2 range), step 0.01 gives 200 ticks to traverse — about right. For cutoff (20-18000 Hz range), step 1 (1 Hz) is fine because the exp warp handles the perceptual mapping.

**The `unit` argument** is a display suffix in the params menu — empty for unitless params, 's' for seconds, 'Hz' for frequencies. Just cosmetic.
`─────────────────────────────────────────────────`

### Polyphony

```lua
    params:add{
        type = 'number',
        id = 'sampler_' .. slot .. '_polyphony',
        name = 'sampler ' .. slot .. ' polyphony',
        min = 1, max = 8, default = 1,
        action = function(v)
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
```

**Lines 79-100**: polyphony param. Integer 1-8, default 1. The action computes the trigger cell's (col, row), formats the cell_id string, and writes to `_G.GlobalRoles.polyphony[cell_id]`. This is read by `next_voice_key` in `cell_roles.lua` to know how many voice slots to round-robin through.

Note the `_G.GlobalRoles or Roles` fallback — defensive against early-init where `_G.GlobalRoles` isn't set yet.

### Send levels

```lua
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
```

**Lines 101-124**: four send levels — dry, reverb, delay, granular. Same pattern: 0-2 range (except granular at 0-1), 0.01 step, all default 0 except dry (default 1 — the natural starting state).

The four sends correspond to the four FX buses in `Lied.sc`. Setting `reverb_send` to a non-zero value routes the sampler's signal into the reverb chain; same for the other sends.

### Randomize trigger

```lua
    params:add{
        type = 'trigger',
        id = 'sampler_' .. slot .. '_randomize',
        name = 'sampler ' .. slot .. ' randomize',
        action = function() VoiceParams.randomize_sampler(slot) end,
    }
end
```

**Lines 125-131**: a trigger param. Type `'trigger'` is a param that's not a value at all — it's a button. The action fires when the user "presses" it (selects + presses K3 in the params menu, or MIDI-triggers it).

## Randomize helper for samplers

```lua
function VoiceParams.randomize_sampler(slot)
    params:set('sampler_' .. slot .. '_amp',        math.random(20, 80) / 100)
    params:set('sampler_' .. slot .. '_cutoff',     math.random(500, 12000))
    params:set('sampler_' .. slot .. '_resonance',  math.random(50, 300) / 100)
    params:set('sampler_' .. slot .. '_pan',        (math.random() * 2) - 1)
end
```

**Lines 134-139**: set the four most-musical params to random values. Each `params:set` fires the corresponding action, which propagates to SC.

The choice of which params to randomize is editorial: amp, cutoff, resonance, pan are the ones most likely to produce interesting variation. The send levels and slews are deliberately NOT randomized — those are more "set-and-forget" params where the user typically wants a specific routing they configured.

`math.random(20, 80) / 100` gives a float in [0.20, 0.80] (not [0.0, 1.0]) — bounded amp to avoid silence-or-clipping extremes.

## The one-shot block (`add_oneshot_block`) — same pattern, smaller surface

Structurally parallel to `add_sampler_block` but with these differences:

- **No trigger_col/row math**: one-shots live at row 8 col `slot` (slot 1..13 = col 1..13).
- **State action** is simpler:
  ```lua
  action = function(idx)
      _G.GlobalSequencer.Toggled[slot][8] = (idx == 2)
      grid_dirty = true
  end,
  ```
- **No amp_slew range / cutoff range / etc. differences from sampler** — almost identical controlspecs.
- **Polyphony action** uses cell_id `"slot_8"`.

```lua
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
    -- ... [amp, amp_slew, cutoff, resonance, pan, pan_slew, polyphony, dry/reverb/delay/granular sends, randomize] ...
end
```

**Lines 145-240**: walks the same shape as sampler. We're skipping the per-param annotation because they're identical to sampler.

The only meaningful difference: the polyphony action uses `string.format("%d_%d", slot, 8)` directly because one-shots already use the slot number as the column.

`★ Insight ─────────────────────────────────────`
**Why are these two functions nearly-identical instead of being one abstract function?** Because the small differences (cell_id math, default amp value, granular_send max range — sampler can route 0-1 granular send, one-shot also 0-1) compound into enough code-path divergence that the abstraction would have flag arguments and conditional branches. Keeping them as parallel duplicate functions is easier to read and easier to modify per-class.

**Adding a new one-shot param** is just an `add_oneshot_block` edit. Adding the same param to samplers means duplicating into `add_sampler_block`. The duplication is intentional — the alternative would be more complex.
`─────────────────────────────────────────────────`

## Randomize helpers for one-shots and granular

```lua
function VoiceParams.randomize_oneshot(slot)
    params:set('oneshot_' .. slot .. '_amp',       math.random(20, 80) / 100)
    params:set('oneshot_' .. slot .. '_cutoff',    math.random(500, 12000))
    params:set('oneshot_' .. slot .. '_resonance', math.random(50, 300) / 100)
    params:set('oneshot_' .. slot .. '_pan',       (math.random() * 2) - 1)
end

function VoiceParams.randomize_granular()
    Grain.randomize_all_rates()
end
```

**Lines 242-252**: same shape as `randomize_sampler`. The granular randomize delegates to `Grain.randomize_all_rates()` (defined in `grid_grain_params.lua`).

## The big one: `add_row2_cell_block` — role-aware per-cell params

The largest function in the file. Declares 48+ params per row-2 cell, covering:

1. Role selector (option).
2. State toggle (option).
3. Cell string (delegates to `add_cell_string_block`).
4. Seq mode block (delegates to `add_cell_seq_mode_block`, 15 params).
5. Shared params (amp, amp_slew, pan, pan_slew, polyphony, 4 sends, pitch_offset).
6. TriSin-only params (16: fm ratios, fm index/iscale, envelopes, cutoff, etc.).
7. Ringer-only param (decay).
8. MIDI-only param (midi_channel).
9. Randomize trigger.

### Role selector

```lua
local ROLE_NAMES = {
    'TriSin', 'Ringer', 'crow 1+2', 'crow 3+4',
    'JF', 'JF run', 'JF quantize',
    'w/syn', 'w/del', 'w/tape looper', 'MIDI',
}

function VoiceParams.add_row2_cell_block(x)
    local cell_id = string.format("%d_2", x)
    local cs = controlspec

    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_2_role',
        name = 'cell ' .. x .. ' role',
        options = ROLE_NAMES,
        default = VoiceParams._default_role_index(x),
        action = function(role_idx)
            local role = ROLE_NAMES[role_idx]
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
```

**Lines 261-296**: the role param. `ROLE_NAMES` is the canonical list mirroring `Roles.ENUM` (chapter 08).

The action does three things:
1. **Update `R.cell_role[x]`** with the new role string. (Note `R = _G.GlobalRoles or Roles` — the cross-include workaround.)
2. **Free any previously-allocated SC voice** for this cell, if the previous role was TriSin/Ringer AND the new role differs.
3. **Update param visibility** to show role-relevant params and hide irrelevant ones.

The "free previous" step matters: if cell 5 was TriSin (alloc'd a TriSin instance) and the user changes role to crow 1+2 (no SC instance needed), we should free the now-unused TriSin instance to avoid keeping dead SC voice nodes around.

### State toggle

```lua
    params:add{
        type = 'option',
        id = 'cell_' .. x .. '_2_state',
        name = 'cell ' .. x .. ' state',
        options = { 'off', 'on' },
        default = 1,
        action = function(idx)
            local on = (idx == 2)
            _G.GlobalSequencer.Toggled[x][2] = on
            if on then Roles.ensure_allocated(x, 2) end
            grid_dirty = true
        end,
    }
```

**Lines 300-312**: same shape as sampler state. The difference: when turning on, also call `Roles.ensure_allocated(x, 2)` — this guarantees the SC voice is allocated before the first fire. (Without this, the first fire's `ensure_allocated` inside the dispatcher would be called from the clock coroutine; pre-allocating is a tiny optimization that also lets us see "voice allocated" messages immediately on toggle.)

### Cell string + seq mode delegations

```lua
    VoiceParams.add_cell_string_block(x, 2)
    VoiceParams.add_cell_seq_mode_block(x, 2)
```

**Lines 315-318**: delegates to other functions (covered later in this walkthrough).

### Shared params

```lua
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_amp',
        name = 'cell ' .. x .. ' amp',
        controlspec = cs.new(0, 2, 'lin', 0.01, 0.5, ''),
        action = function(v) VoiceParams._set_cell_param(x, 'amp', v) end,
    }
    -- ... [amp_slew, pan, pan_slew] ...
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
    -- ... [4 send levels: dry, reverb, delay, granular] ...
```

**Lines 320-386**: shared params (amp, amp_slew, pan, pan_slew, polyphony, 4 sends). The action of each amp/pan/pan_slew/sends call dispatches via `VoiceParams._set_cell_param(x, key, v)`, which routes to the active role's setParam (defined below). Polyphony writes directly to `_G.GlobalRoles.polyphony`.

### Pitch offset

```lua
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
```

**Lines 388-404**: pitch offset in semitones, -36 to +36 (three octaves up/down). The `formatter` function is Norns's hook for customizing how the value displays in the params menu. The formatter:

- Always shows `'+N st'` or `'-N st'` (signed semitones).
- Adds a parenthetical hint for special intervals: unison, octave multiples, perfect 5ths, perfect 4ths.

So the user sees `'+12 st (+1 oct)'` or `'-7 st (-P5)'` instead of just a number. This is a nice UX touch that doesn't change the underlying value but makes navigation more musical.

`★ Insight ─────────────────────────────────────`
**The `formatter` hook is widely underused in Norns scripts.** Many scripts show raw numbers where a formatted string would be more useful. Examples where formatting helps: percentages (display 0.7 as "70%"), beats (display 0.5 as "1/2 beat"), MIDI note numbers (display 60 as "C4"), curve values (display 4 as "exp"). The formatter doesn't affect the stored value; it only changes the display. Cheap UX win.

**The formatter receives the param itself**, not the value. `param:get()` reads the current value. This is because the formatter might want to consult other state on the param (like the option list for an option-type param). For most cases, `param:get()` is what you want.
`─────────────────────────────────────────────────`

### TriSin-only params

```lua
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_fm_carrier_ratio',
        name = 'cell ' .. x .. ' fm carrier ratio',
        controlspec = cs.new(0.1, 16, 'lin', 0.01, 1, ''),
        action = function(v) VoiceParams._set_trisin_only(x, 'cRatio', v) end,
    }
    -- ... [fm_modulator_ratio, fm_index, fm_iscale,
    --      attack, release, attack_curve, release_curve,
    --      fm_env_attack, fm_env_release, fm_env_attack_curve, fm_env_release_curve,
    --      cutoff, cutoff_env, resonance, freq_slew] ...
```

**Lines 407-518**: 16 TriSin-specific params. Each action calls `VoiceParams._set_trisin_only(x, sc_key, v)`, which writes to SC ONLY IF the cell's current role is TriSin (the function checks; we'll see it below). This makes the params safe to define for all cells — even if the cell is currently set to Ringer, writes here are silently dropped.

The param names map to TriSin SynthDef args:
- `fm_carrier_ratio` → SC arg `cRatio`
- `fm_modulator_ratio` → `mRatio`
- `fm_index` → `index`
- `fm_iscale` → `iScale`
- `attack` → `attack` (volume envelope)
- `release` → `release`
- `attack_curve`, `release_curve` → `cAtk`, `cRel`
- `fm_env_attack`, `fm_env_release` → `iattack`, `irelease` (FM index envelope)
- `fm_env_attack_curve`, `fm_env_release_curve` → `ciAtk`, `ciRel`
- `cutoff`, `cutoff_env`, `resonance` → cutoff filter params
- `freq_slew` → glide time

### Ringer-only param

```lua
    params:add{
        type = 'control',
        id = 'cell_' .. x .. '_2_decay',
        name = 'cell ' .. x .. ' decay',
        controlspec = cs.new(0.1, 20, 'lin', 0.01, 3, ''),
        action = function(v) VoiceParams._set_ringer_only(x, 'index', v) end,
    }
```

**Lines 521-527**: a single Ringer-specific param. The `decay` param maps to Ringer's `index` SynthDef arg (which controls envelope release time via the formula `releaseTime: index.abs * 2` in `Ringer.sc`).

### MIDI-only param

```lua
    params:add{
        type = 'number',
        id = 'cell_' .. x .. '_2_midi_channel',
        name = 'cell ' .. x .. ' midi channel',
        min = 1, max = 16, default = 1,
        action = function(_)
            Midi.on_channel_change(x, 2)
        end,
    }
```

**Lines 530-538**: MIDI channel param. The action calls `Midi.on_channel_change(x, 2)` — a hook that lets the MIDI role respond to channel changes (e.g., re-create note-off coroutines if there's pending state).

### Per-cell randomize trigger

```lua
    params:add{
        type = 'trigger',
        id = 'cell_' .. x .. '_2_randomize',
        name = 'cell ' .. x .. ' randomize',
        action = function() VoiceParams.randomize_row2_cell(x) end,
    }
end
```

**Lines 541-547**: the randomize trigger. Delegates to `randomize_row2_cell` (covered below).

## Per-role helpers: routing param writes to the right SC method

```lua
function VoiceParams._default_role_index(x)
    local role_name = Roles.ROW_2_DEFAULTS[x] or 'TriSin'
    for i, name in ipairs(ROLE_NAMES) do
        if name == role_name then return i end
    end
    return 1
end
```

**Lines 550-556**: convert a column's default role name (from `Roles.ROW_2_DEFAULTS[x]`) to its index in `ROLE_NAMES`. Used by the role param's `default` field.

The lookup is O(N) but N is small (11 roles) and this only runs at init.

```lua
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
```

**Lines 560-584**: three role-routing helpers.

- **`_set_cell_param`**: dispatches to either TriSin or Ringer based on current role. Used for shared params (amp, pan, etc.) that BOTH classes have.
- **`_set_trisin_only`**: writes only if current role is TriSin. Used for TriSin-specific params.
- **`_set_ringer_only`**: writes only if current role is Ringer. Used for Ringer-specific params.

Crow/JF/w/* roles have no SC voice — the role check filters out writes for those roles entirely. Setting a TriSin-only param while a cell is in crow mode is a no-op (silently).

`★ Insight ─────────────────────────────────────`
**Why three helpers instead of one with a class-filter arg?** Because each helper is called from many param actions, and the param actions are easier to read when the routing is explicit (`_set_trisin_only(x, 'cRatio', v)` is obvious; `_set_role_param(x, 'cRatio', 'TriSin', v)` is less so). The duplication is intentional.

**A subtle thing**: changes to a TriSin-only param while the cell is in Ringer mode are still **stored in the param** (params:get/set work normally), they just don't propagate to SC. When the user changes back to TriSin, the pre-existing param values WON'T retroactively apply to the now-allocated TriSin instance — the user would need to explicitly nudge each param. This is why `add_row2_cell_block` calls `Roles.ensure_allocated` in the state action (to allocate immediately, so subsequent param changes can propagate).
`─────────────────────────────────────────────────`

## Dynamic visibility by role (`_update_row2_visibility`)

```lua
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

    show_or_hide(shared, role == 'TriSin' or role == 'Ringer')
    show_or_hide(trisin_only, role == 'TriSin')
    show_or_hide(ringer_only, role == 'Ringer')
    show_or_hide(midi_only, role == 'MIDI')

    local pitch_offset_visible = (role ~= 'w/tape looper')
    if pitch_offset_visible then
        params:show(prefix .. 'pitch_offset')
    else
        params:hide(prefix .. 'pitch_offset')
    end

    _menu.rebuild_params()
end
```

**Lines 586-628**: dynamic visibility for row-2 params based on the current role.

Four lists of params:
- `trisin_only` (16 params): TriSin-specific.
- `ringer_only` (1 param): Ringer-specific.
- `midi_only` (1 param): MIDI-specific.
- `shared` (9 params): TriSin AND Ringer.

The visibility logic:
- Shared params visible iff role is TriSin or Ringer (the only roles with SC voices).
- TriSin-only iff role is TriSin.
- Ringer-only iff role is Ringer.
- MIDI-only iff role is MIDI.
- Pitch offset visible for all roles EXCEPT w/tape looper (w/tape doesn't use pitch).

`_menu.rebuild_params()` triggers the params menu to recalculate its display.

## Per-cell randomize (`randomize_row2_cell`)

```lua
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
```

**Lines 631-643**: role-aware randomize. Always randomizes amp + pan. If role is TriSin, also randomizes FM index, cutoff, resonance. If Ringer, randomizes decay.

This is more useful than blindly randomizing every param because cell parameters that don't apply to the current role wouldn't audibly change anything.

## The seq-mode block: 15 params per cell + defaults

The seq_mode block has 15 params per cell:
- 1 mode (option-type with 4 options)
- 1 scale (continuous, for lied mode)
- 1 fixed_value (option-type, for fixed mode)
- 1 num_steps (integer, for user_seq mode)
- 8 step_N_duration (option-type, for user_seq mode)
- 2 random_min/max (option-type, for random mode)
- 1 phase (continuous, applies to all modes)

```lua
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
```

**Lines 649-663**: the mode param. Action: trigger visibility refresh.

```lua
    params:add{
        type = 'control',
        id = prefix .. 'scale',
        name = 'rate scale',
        controlspec = controlspec.new(0.0625, 64, 'lin', 0.0625,
            VoiceParams._default_seq_scale(x, y), ''),
    }
```

**Lines 664-672**: scale for lied mode. Range 0.0625 (1/16) to 64. Step 0.0625 — so every encoder tick lands on a 1/16-beat multiple. Default is per-cell (8 for "lied row" cells, 1 otherwise).

The comment in the source notes: "step + min on the same 1/16-beat grid so integer values (1, 2, 4, 8, ...) are always exact multiples and reachable via encoder." This is a careful controlspec choice — without aligned step and min, the user could end up at 1.0625 (not a musical multiple) when scrolling.

```lua
    params:add{
        type = 'option',
        id = prefix .. 'fixed_value',
        name = 'fixed value',
        options = Timing.labels(),
        default = Timing.idx_for_value(VoiceParams._default_fixed_value(x, y)),
    }
```

**Lines 677-683**: fixed_value option. Options come from `Timing.labels()` (28 musical fractions: 1/64, 1/32, ..., 32, 64). Default is the index closest to the per-cell default (computed by `_default_fixed_value`).

```lua
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
```

**Lines 684-698**: num_steps param. The action shows/hides step params based on the new num_steps value — BUT only if currently in user_seq mode (mode 3). In other modes, num_steps changes are silently stored but don't affect visibility.

```lua
    for s = 1, 8 do
        params:add{
            type = 'option',
            id = prefix .. 'step_' .. s .. '_duration',
            name = 'step ' .. s .. ' duration',
            options = Timing.labels(),
            default = Timing.idx_for_value(1),
        }
    end
```

**Lines 699-707**: 8 step duration params. All default to "1 beat" (index 14 in Timing.OPTIONS).

```lua
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
```

**Lines 708-721**: random min/max bounds. Default min = 1 beat, max = 16 beats — a useful range for random-rate cells.

```lua
    params:add{
        type = 'control',
        id = prefix .. 'phase',
        name = 'phase offset',
        controlspec = controlspec.new(0, 16, 'lin', 0.0625, 0, 'beats'),
    }
end
```

**Lines 726-731**: the phase param. Range 0-16 beats, 1/16-beat step. Applies in lied + fixed modes (modes 1 and 2 — see `step_for` in sequencer.lua). Use case: backbeat patterns where cell X fires on beat 0, 2, 4 (rate=2 phase=0) and cell Y fires on beat 1, 3, 5 (rate=2 phase=1).

### Default helpers

```lua
function VoiceParams._default_seq_mode_index(x, y)
    return 1
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
```

**Lines 743-762**: three default helpers.

- `_default_seq_mode_index` always returns 1 (lied mode). The comment explains: "all cells default to lied (option index 1) regardless of cell. This loses the naherinlied-specific per-column starting rates but gives a consistent byte-driven starting behavior across the grid."
- `_default_seq_scale` returns 8 for row 2 cols 3-8 (the sequins-derived columns from naherinlied); 1 otherwise.
- `_default_fixed_value` returns the per-cell default rate (used as the starting point for fixed mode when the user switches to fixed).

## Seq-mode visibility

Briefly:

- mode 1 (lied) shows: `scale`.
- mode 2 (fixed) shows: `fixed_value`.
- mode 3 (user_seq) shows: `num_steps` + first N `step_N_duration` (where N = num_steps).
- mode 4 (random) shows: `random_min`, `random_max`.

`_menu.rebuild_params()` at the end refreshes the menu display.

## The value-mode block for samplers and one-shots

Value-mode block for samplers and one-shots. Takes a `value_kind` ('position', 'duration', or 'rate') and adds 13 params per kind.

```lua
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
```

**Lines 800-814**: mode param. Same shape as seq_mode but with `value_kind` in the prefix.

```lua
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
```

**Lines 819-838**: helper closure `add_value_param`. The structure branches on whether `value_kind == 'rate'`:

- **Rate kind**: use option-type param with `Timing.rate_labels()` (the signed-musical-fraction list).
- **Non-rate (position/duration)**: use control-type param with a continuous range.

The closure captures `cs` (the controlspec) — for non-rate, we build one controlspec at the top and reuse for every continuous param. For rate, the closure ignores the controlspec branch and builds an option param.

```lua
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
```

**Lines 840-865**: the rest of the param block. Same structure as seq_mode: fixed_value, num_steps, 8 step values, random min/max. Each value uses `add_value_param` so the rate-vs-non-rate branching happens in one place.

The defaults are computed inline: rate mode defaults to 1 (native rate), 0.5 (half-speed for random min), 2 (double-speed for random max); non-rate defaults to the midpoint of the range.

## Re-firing param actions after a file load (`reapply_sampler` / `reapply_oneshot`)

```lua
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
```

**Lines 874-889**: re-fire param actions after a file load. The comment explains the rationale: `loadSampler`/`loadOneShot` create a fresh SC instance with SynthDef defaults. Without re-firing the param actions, the Lua-side current values would be out of sync with SC.

The trick: `params:set(pid, params:get(pid))` writes the param to its OWN current value, which fires the action without changing anything. The action's `engine.sampler_set_param(slot, key, v)` lands in SC's pending-params cache (the instance is still mid-fork allocation; the kernel applies pending params at the end of the alloc fork).

Called from the file param's action, immediately after `engine.sampler_load(slot, path)` / `engine.oneshot_load(slot, path)`.

`★ Insight ─────────────────────────────────────`
**`params:set(pid, params:get(pid))` is the "re-fire action" idiom in Norns Lua.** Used anywhere you need to trigger a param's side effect without changing the value. Other places this appears in the script:
- `for x = 1, 16 do params:set('cell_X_2_role', params:get(...)) end` to force visibility refresh at init.
- Same for seq_mode and value_mode init-time refreshes.

**Why iterate `SC_BOUND_KEYS` instead of all params?** Because not every sampler/one-shot param needs re-firing — only the ones whose action sends an OSC command to SC. Sequencer-related params (state, polyphony, randomize trigger) don't need re-fire; they're Lua-side only. The whitelist avoids re-firing actions that wouldn't help.

**The `params.lookup[pid]` defensive check** handles the case where some sampler params don't exist (e.g., if we somehow added a SC_BOUND_KEYS entry that doesn't have a corresponding param). Skip silently.
`─────────────────────────────────────────────────`

## The cell string assignment surface (gridless operation)

The single biggest UX surface in `voice_params.lua`.

```lua
function VoiceParams.bind_sequencer(seq)
    seq.on_history_changed_fn = function()
        VoiceParams.refresh_all_cell_string_params()
    end
    seq.on_cell_assigned_fn = function(x, y)
        VoiceParams.refresh_one_cell_string_param(x, y)
    end
end
```

**Lines 915-922**: install hooks on the Sequencer module. Called from `schicksalslied.lua:init()` after the canonical Sequencer is created. The hooks are how voice_params reacts to history mutations and cell assignments.

```lua
local STRING_PARAM_TRUNCATE = 18

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
```

**Lines 924-944**: build the option list for one cell's string param. Three categories:

- **Option 1: `'(none)'`** — always present, represents "cell is empty/silent."
- **Option 2: `'(custom)'` or `'(grid: <text>)'`** — the display-only state. If the cell has a non-history string assigned, show its content (truncated to 18 chars).
- **Options 3+**: each history entry as `'N: <text>'`.

Truncation to 18 chars is for menu display — longer strings would overflow Norns's screen.

```lua
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
                -- no-op
            else
                local slot = idx - 2
                local s = Seq.history[slot]
                if s then Seq.assign(x, y, s, true) end
            end
        end,
    }
end
```

**Lines 946-968**: declare the cell string param.

The action branches on the selected option index:
- **idx 1**: assign empty string. The `true` is the `silent` flag — don't fire the on_cell_assigned hook (which would re-fire this action and loop).
- **idx 2**: no-op. Selecting `(custom)`/`(grid: ...)` is just a display state; manually selecting it doesn't change the cell.
- **idx 3+**: lookup history at `idx - 2`, assign that string.

```lua
local STRING_CELLS = (function()
    local t = {}
    for x = 1, 16 do t[#t + 1] = { x, 2 } end
    for y = 4, 6, 2 do
        for x = 1, 16 do t[#t + 1] = { x, y } end
    end
    for x = 1, 13 do t[#t + 1] = { x, 8 } end
    return t
end)()
```

**Lines 971-979**: build the list of cells that have string params. Row 2 cols 1-16, row 4 cols 1-16, row 6 cols 1-16, row 8 cols 1-13. Total: 16 + 16 + 16 + 13 = 61 cells.

The immediately-invoked function pattern (IIFE) `(function() ... end)()` constructs the table at load time. After this, `STRING_CELLS` is a fixed array.

```lua
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
```

**Lines 983-1005**: refresh one cell's string param. Logic:

1. Look up the param.
2. Read the cell's stored string from `_cell_assigned_strings`.
3. Try to find the string in history (sets `slot` if matched).
4. Compute `custom_str` for the display label: nil if matched OR if empty; the stored string otherwise.
5. Rebuild the option list with that `custom_str`.
6. Mutate `p.options` and `p.count` in place (Norns supports this).
7. Set the displayed value:
   - Empty / nil string → option 1 (`(none)`).
   - Matched history slot N → option N+2.
   - Custom string (not matched) → option 2 (`(grid: ...)`).

The `params:set(pid, opt_idx, true)` is silent — doesn't fire the action — to avoid the loop.

```lua
function VoiceParams.refresh_all_cell_string_params()
    for _, c in ipairs(STRING_CELLS) do
        VoiceParams.refresh_one_cell_string_param(c[1], c[2])
    end
    if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end
```

**Lines 1009-1014**: refresh all 61 cells. Called when history changes (so option lists need updating across all cells). The single `_menu.rebuild_params()` at the end is more efficient than calling rebuild_params 61 times.

## State params for sampler rate cells

```lua
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
```

**Lines 1021-1033**: declares a state param for sampler rate cells (rows 4/6 even cols). The shape mirrors the row-2 / sampler / one-shot state params, but with a per-cell ID using x/y directly.

Without this, rate cells would be the only toggle cells that don't have a state param — making MIDI mapping / gridless workflows incomplete. Adding this closes that gap.

## Value-mode visibility

```lua
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
```

**Lines 1035-1062**: same shape as `_update_seq_mode_visibility` but for value-mode sub-params. Notable differences:

- No `scale` param (lied mode just returns nil for the value, and the dispatcher computes from bytes).
- Step params use `step_N_value` (not `step_N_duration`).

## Module return

```lua
return VoiceParams
```

**Line 1064**: the module table return. `include 'lib/voice_params'` returns this table.

## Summary

`voice_params.lua` has heavy structural repetition: every voice cell, sampler, and one-shot has a parallel set of params with parallel action shapes. The patterns to internalize:

- **Block helper per "thing"**: `add_sampler_block(slot)`, `add_oneshot_block(slot)`, `add_row2_cell_block(x)`. Each adds a fixed number of params for one instance of the thing.
- **Per-param `params:add{...}` declarations** with action closures that capture the per-instance context (slot, cell coords).
- **`engine.<setter>(slot/cellId, key, v)`** in nearly every action — that's how Lua-side param changes propagate to SC.
- **`_G.GlobalRoles` / `_G.GlobalSequencer` cross-include workaround**: every action that needs to write to a shared module reads through `_G.<ModuleName>`.
- **Dynamic visibility helpers** for option-typed mode params (`_update_seq_mode_visibility`, `_update_value_mode_visibility`, `_update_row2_visibility`).
- **`_menu.rebuild_params()` calls** at the end of every visibility-changing function — without these, the params menu wouldn't reflect the new state.
- **Defensive `or default` fallbacks** in actions that read other params: the actions might fire before all params are added (during init), and defaults keep them from crashing.

Reading the file top to bottom: the sampler block establishes the basic patterns; the one-shot block reinforces them; the row-2 block extends them with role-aware dispatch; the seq/value mode blocks add another layer of dynamic visibility; the cell string code adds the gridless-operation surface.
