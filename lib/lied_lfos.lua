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

local LFO = require 'lfo'
local LiedLfos = {}

-- Storage for the LFO objects (so they survive past init scope, for inspection)
LiedLfos.bound = {}

-- Bind an LFO that drives target_param_id when active.
-- label_for_separator is the human-readable label shown ABOVE this LFO's
-- 15 params in the menu (e.g., "cell 1 amp", "sampler 3 cutoff").
-- The library auto-adds a separator labeled with this string before the
-- 15 LFO params.
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

-- ────────────────────────────────────────────────────────────────────────
-- ROW-2 VOICE LFOS — 10 LFOs per cell × 16 cells = 160 LFOs.
-- Each LFO entry occupies 1 separator + 15 params = 16 menu entries.
-- Group capacity: 160 × 16 = 2560.
-- ────────────────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────────────────
-- SAMPLER LFOS — 4 LFOs × 16 samplers = 64 LFOs. Capacity: 64 × 16 = 1024.
-- ────────────────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────────────────
-- ONE-SHOT LFOS — 4 LFOs × 13 one-shots = 52 LFOs. Capacity: 52 × 16 = 832.
-- ────────────────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────────────────
-- CROW LFOS — 6 LFOs. Capacity: 6 × 16 = 96.
-- ────────────────────────────────────────────────────────────────────────
function LiedLfos.add_crow_lfos_group()
    params:add_group('crow_lfos', 'crow LFOs', 6 * 16)
    LiedLfos.bind('wsyn_lpg_speed',     'wsyn_lpg_speed',    -5, 5, 'w/syn lpg speed')
    LiedLfos.bind('wsyn_lpg_symmetry',  'wsyn_lpg_symmetry', -5, 5, 'w/syn lpg symmetry')
    LiedLfos.bind('wsyn_fm_index',      'wsyn_fm_index',      0, 5, 'w/syn fm index')
    LiedLfos.bind('wsyn_fm_envelope',   'wsyn_fm_envelope',  -5, 5, 'w/syn fm envelope')
    LiedLfos.bind('wdel_feedback',      'wdel_feedback',      0, 1, 'w/del feedback')
    LiedLfos.bind('wdel_filter_cutoff', 'wdel_filter_cutoff', 0, 1, 'w/del filter cutoff')
end

return LiedLfos
