# `lib/lied_lfos.lua` — Line-by-Line

The LFO binding module. **117 lines**. Wraps the standard Norns `lfo` library to attach LFOs to every modulatable param in the script.

Conceptual context: [chapter 19](19-schicksalslied.lua.md) (LFO binding sites) and the standard Norns LFO library docs.

Sections:

1. Header (lines 1-22)
2. Module setup + storage (lines 23-27)
3. `LiedLfos.bind` (lines 29-49)
4. `add_row_2_lfos_group` (lines 51-72)
5. `add_sampler_lfos_group` (lines 74-87)
6. `add_oneshot_lfos_group` (lines 89-102)
7. `add_crow_lfos_group` (lines 104-115)
8. Module return (line 117)

## 1. Header

```lua
-- lib/lied_lfos.lua — LFO instantiation for every voice/sampler/oneshot/crow
-- target param. Uses the standard Norns LFO library (require 'lfo').
--
-- The standard library:
--   - LFO:add{ ... } returns an LFO object and adds ~13 params under
--     IDs like lfo_<id>, lfo_shape_<id>, lfo_depth_<id>, etc.
--   - The library handles its own visibility: lfo_<id> param (off/on)
--     auto-hides/shows the other params via params:hide/show.
--   - lfo:start() and lfo:stop() are called automatically by the library
--     when lfo_<id> changes; no wrapper action needed.
--
-- We just need to:
--   1. Pre-build the LFO with a meaningful id, default depth=0,
--      and an action function that calls params:set on the target param.
--   2. Add it to the params menu via lfo:add_params(id, sep).
--   3. NEVER start the LFO at init — depth=0 + state=off means no overhead.
--
-- Spec §10 inline correction: the original spec proposed depth-driven implicit
-- start/stop. This is incompatible with the standard library which hides the
-- depth param when state=off (user couldn't re-enable). Riding the library
-- is simpler and matches every other Norns script's LFO UX.
```

**Lines 1-22**: a substantial header explaining what the library does and how this wrapper uses it.

Key points:
- **Each LFO adds ~13 params**: state (off/on), shape, depth, offset, period, etc. The library handles the dynamic visibility (depth hidden when state=off) and the start/stop lifecycle.
- **We don't start LFOs at init** — depth=0 + state=off means the LFO exists but does no work. Only when the user enables it via the state param does the library actually start it ticking.
- **The "spec correction" note** documents a design decision that was changed during development. The original design wanted depth=0 to implicitly stop the LFO; that conflicted with the library's "hide depth when state=off" behavior (the user wouldn't be able to re-enable). The fix: keep state and depth independent; let the library handle the lifecycle.

`★ Insight ─────────────────────────────────────`
**The "inline spec correction" comment is unusually transparent.** Most code projects keep design changes in a separate changelog or commit message; embedding the rationale in a source comment means anyone reading the file will see why the implementation differs from any earlier spec.

**This is good practice for scripts where the spec evolves during development.** Future-you (or another developer) will see the comment and understand: "we tried X, it had Y problem, we chose Z." Without it, the code looks arbitrary; with it, the code looks deliberate.
`─────────────────────────────────────────────────`

## 2. Module setup + storage

```lua
local LFO = require 'lfo'
local LiedLfos = {}

LiedLfos.bound = {}
```

**Lines 23-27**: import the LFO library, declare the module table, declare a storage table for LFO objects.

`require 'lfo'` is cached (standard Lua require), so all the calls in this file see the same LFO module table.

`LiedLfos.bound = {}` is a strong reference holder. Without it, Lua's GC could collect the LFO objects after `bind` returns (since no other strong reference exists). With it, the objects stay alive for the lifetime of the script.

The table also serves as a registry — `LiedLfos.bound[lfo_id]` gives access to the LFO object from outside, which is useful for diagnostics.

## 3. `LiedLfos.bind`

```lua
function LiedLfos.bind(lfo_id, target_param_id, min, max, label_for_separator)
    local lfo = LFO.new(
        'sine',           -- shape
        min or 0,         -- min
        max or 1,         -- max
        0,                -- depth (start inert; user enables via lfo_<id> state param)
        'clocked',        -- mode
        4,                -- period
        function(scaled, raw)
            params:set(target_param_id, scaled)
        end
    )
    lfo:add_params(lfo_id, label_for_separator)
    LiedLfos.bound[lfo_id] = lfo
    return lfo
end
```

**Lines 34-49**: the core bind function. Five args:

- **`lfo_id`** — unique LFO identifier (used as param ID prefix).
- **`target_param_id`** — the param this LFO drives.
- **`min, max`** — the LFO's output range. Should match the target param's range.
- **`label_for_separator`** — display label shown as a separator above the LFO's params in the menu.

Inside:

1. **`LFO.new(shape, min, max, depth, mode, period, action)`** constructs the LFO. Args:
   - `'sine'` — wave shape. (User can change to triangle, saw, etc. via the shape param.)
   - `min, max` — output range. Initial values; user can change.
   - `0` — depth. Critical: starts at 0 = no modulation = no work. User must turn it up to activate.
   - `'clocked'` — beat-synced mode. (Alternative: 'free' = wallclock.)
   - `4` — period in beats. (User can change.)
   - `function(scaled, raw)` — the action callback. `scaled` is the LFO's current value mapped into [min, max]; `raw` is the pre-scaling value. We write `scaled` to the target param.

2. **`lfo:add_params(lfo_id, label_for_separator)`** adds the LFO's full param set (state, shape, depth, offset, period, etc.) to the params menu, prefixed by `lfo_id` and preceded by a separator with the given label.

3. **`LiedLfos.bound[lfo_id] = lfo`** stores the strong reference.

4. Return the LFO object for any caller that wants further access.

`★ Insight ─────────────────────────────────────`
**`params:set(target_param_id, scaled)` in the LFO action** is what makes the LFO actually do something. The LFO ticks at its period; each tick computes the new `scaled` value and writes to the target. Setting a param fires its own action (which might dispatch to the engine), so the LFO's modulation propagates downstream as if the user were turning a knob.

**The action receives BOTH `scaled` and `raw`**. We always use `scaled` because it's already in the target param's range. `raw` is useful if you want to combine multiple LFOs or do custom mapping; we don't in this script.

**Depth=0 at construction is the key to no-overhead inactive LFOs.** The library checks depth before doing modulation work. With depth=0, the action is called but writes a constant value (or no-op, depending on the library's implementation) — either way, the cost is negligible.
`─────────────────────────────────────────────────`

## 4. `add_row_2_lfos_group`

```lua
function LiedLfos.add_row_2_lfos_group()
    params:add_group('row_2_voice_lfos', 'synth LFOs', 160 * 16)
    for x = 1, 16 do
        local prefix = 'cell_' .. x .. '_2_'
        local label_prefix = 'cell ' .. x .. ' '
        LiedLfos.bind('cell_' .. x .. '_amp',       prefix .. 'amp',        0, 2,     label_prefix .. 'amp')
        LiedLfos.bind('cell_' .. x .. '_pan',       prefix .. 'pan',       -1, 1,     label_prefix .. 'pan')
        LiedLfos.bind('cell_' .. x .. '_attack',    prefix .. 'attack',     0, 5,     label_prefix .. 'attack')
        LiedLfos.bind('cell_' .. x .. '_release',   prefix .. 'release',    0, 10,    label_prefix .. 'release')
        LiedLfos.bind('cell_' .. x .. '_cutoff',    prefix .. 'cutoff',    20, 18000, label_prefix .. 'cutoff')
        LiedLfos.bind('cell_' .. x .. '_resonance', prefix .. 'resonance',  0, 4,     label_prefix .. 'resonance')
        LiedLfos.bind('cell_' .. x .. '_fm_index',  prefix .. 'fm_index',   0, 20,    label_prefix .. 'fm index')
        LiedLfos.bind('cell_' .. x .. '_fm_cratio', prefix .. 'fm_carrier_ratio',   0.1, 16, label_prefix .. 'fm carrier ratio')
        LiedLfos.bind('cell_' .. x .. '_fm_mratio', prefix .. 'fm_modulator_ratio', 0.1, 16, label_prefix .. 'fm modulator ratio')
        LiedLfos.bind('cell_' .. x .. '_decay',     prefix .. 'decay',     0.1, 20,   label_prefix .. 'decay')
    end
end
```

**Lines 56-72**: bind 10 LFOs per row-2 cell × 16 cells = 160 total. Plus the 16 LFOs × 16 params each = 2,560 param menu entries.

The `params:add_group('row_2_voice_lfos', 'synth LFOs', 160 * 16)` reserves the group capacity (Norns uses this for layout planning). The third arg is the expected param count; if you add more than this, Norns will warn but not crash.

For each cell x = 1..16:
- 10 LFOs covering the most-musical parameters: amp, pan, attack, release, cutoff, resonance, fm_index, fm_carrier_ratio, fm_modulator_ratio, decay.

The min/max ranges match the target params' controlspecs (e.g., cutoff uses 20-18000 because the cutoff param is 20-18000 Hz).

Note that `decay` and the FM-related params apply to TriSin/Ringer. When a cell is in a non-SC role (crow, JF, MIDI), modulating these does nothing — but the LFOs are pre-bound anyway. No runtime cost, and they're available if the user switches the cell back to TriSin later.

`★ Insight ─────────────────────────────────────`
**Pre-binding LFOs for params that may not apply** is the right call here. The alternative — only binding LFOs when the cell's role is TriSin or Ringer — would require dynamically adding/removing param groups when roles change. Norns's params API supports this in principle (params:hide / params:show) but the LFO library wasn't designed for hot-add/hot-remove. The simpler approach: bind everything up front; let the role determine whether modulation does anything.

**The LFO menu structure** ends up with one "synth LFOs" group containing 16 cells × 10 LFO subsections. Each LFO subsection is preceded by its label separator and contains ~16 LFO config params. The user navigates: PARAMETERS → synth LFOs → cell 5 amp → enable/depth/period/...

For users with hundreds of LFOs available, finding the one they want is non-trivial. The separator labels are essential — they're what makes the menu navigable.
`─────────────────────────────────────────────────`

## 5. `add_sampler_lfos_group`

```lua
function LiedLfos.add_sampler_lfos_group()
    params:add_group('sampler_lfos', 'looping sampler LFOs', 64 * 16)
    for slot = 1, 16 do
        local prefix = 'sampler_' .. slot .. '_'
        local label_prefix = 'sampler ' .. slot .. ' '
        LiedLfos.bind('sampler_' .. slot .. '_amp',       prefix .. 'amp',        0, 2,     label_prefix .. 'amp')
        LiedLfos.bind('sampler_' .. slot .. '_pan',       prefix .. 'pan',       -1, 1,     label_prefix .. 'pan')
        LiedLfos.bind('sampler_' .. slot .. '_cutoff',    prefix .. 'cutoff',    20, 18000, label_prefix .. 'cutoff')
        LiedLfos.bind('sampler_' .. slot .. '_resonance', prefix .. 'resonance',  0, 4,     label_prefix .. 'resonance')
    end
end
```

**Lines 77-87**: 4 LFOs per sampler × 16 samplers = 64 LFOs. Group capacity: 64 × 16 = 1,024 params.

Smaller per-sampler set than row-2 cells: just amp, pan, cutoff, resonance. These are the most useful modulation targets for sample playback.

## 6. `add_oneshot_lfos_group`

```lua
function LiedLfos.add_oneshot_lfos_group()
    params:add_group('oneshot_lfos', 'one-shot LFOs', 52 * 16)
    for slot = 1, 13 do
        local prefix = 'oneshot_' .. slot .. '_'
        local label_prefix = 'one-shot ' .. slot .. ' '
        LiedLfos.bind('oneshot_' .. slot .. '_amp',       prefix .. 'amp',        0, 2,     label_prefix .. 'amp')
        LiedLfos.bind('oneshot_' .. slot .. '_pan',       prefix .. 'pan',       -1, 1,     label_prefix .. 'pan')
        LiedLfos.bind('oneshot_' .. slot .. '_cutoff',    prefix .. 'cutoff',    20, 18000, label_prefix .. 'cutoff')
        LiedLfos.bind('oneshot_' .. slot .. '_resonance', prefix .. 'resonance',  0, 4,     label_prefix .. 'resonance')
    end
end
```

**Lines 92-102**: 4 LFOs per one-shot × 13 one-shots = 52 LFOs. Same set as samplers (amp, pan, cutoff, resonance).

## 7. `add_crow_lfos_group`

```lua
function LiedLfos.add_crow_lfos_group()
    params:add_group('crow_lfos', 'crow LFOs', 6 * 16)
    LiedLfos.bind('wsyn_lpg_speed',     'wsyn_lpg_speed',    -5, 5, 'w/syn lpg speed')
    LiedLfos.bind('wsyn_lpg_symmetry',  'wsyn_lpg_symmetry', -5, 5, 'w/syn lpg symmetry')
    LiedLfos.bind('wsyn_fm_index',      'wsyn_fm_index',      0, 5, 'w/syn fm index')
    LiedLfos.bind('wsyn_fm_envelope',   'wsyn_fm_envelope',  -5, 5, 'w/syn fm envelope')
    LiedLfos.bind('wdel_feedback',      'wdel_feedback',      0, 1, 'w/del feedback')
    LiedLfos.bind('wdel_filter_cutoff', 'wdel_filter_cutoff', 0, 1, 'w/del filter cutoff')
end
```

**Lines 107-115**: 6 LFOs for crow / w/syn / w/del parameters. These are GLOBAL (not per-cell) because the corresponding crow params are global (one w/syn device, one w/del device).

The LFO target IDs (`'wsyn_lpg_speed'`, etc.) match the corresponding crow params declared in `schicksalslied.lua`'s crow params group. The LFOs drive those global params, which in turn send ii commands to the devices.

## 8. Module return

```lua
return LiedLfos
```

**Line 117**: standard return.

## Summary

`lib/lied_lfos.lua` is a thin wrapper over Norns's LFO library. The patterns to internalize:

- **Pre-bind everything with depth=0**: the cost of an inactive LFO is negligible, so binding upfront is fine even for hundreds of LFOs.
- **Strong reference table** (`LiedLfos.bound`) to keep LFO objects alive against GC.
- **One `LiedLfos.bind` call per LFO**: the consistent signature makes the bulk-binding loops above straightforward.
- **Group structure mirrors the params surface**: one LFO group per voice family (row_2_voice_lfos, sampler_lfos, oneshot_lfos, crow_lfos).
- **Range matching**: each LFO's min/max matches the target param's controlspec.

Total LFOs bound in this build:
- 160 row-2 voice LFOs.
- 64 sampler LFOs.
- 52 one-shot LFOs.
- 6 crow LFOs.

**Total: 282 LFOs available.** All inert at script start; the user enables individual LFOs via their state params.

To add a new LFO target, the work is: identify the target param ID, pick the right group function, add one `LiedLfos.bind(...)` line. Done. The dynamic-visibility/state/depth machinery comes for free from the LFO library.
