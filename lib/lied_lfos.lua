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
--   2. Add it to the params menu via LFO:add{...}.
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

-- Bind an LFO that, when active, drives `target_param_id`.
-- LFO.new constructs the object (no params yet). lfo:add_params(id) is what
-- actually registers the 15 params per LFO into the currently-open group.
function LiedLfos.bind(lfo_id, target_param_id, min, max)
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
    lfo:add_params(lfo_id)
    LiedLfos.bound[lfo_id] = lfo
    return lfo
end

-- Convenience: bind a batch of LFOs from a config table.
-- config = { { lfo_id, target_param, min, max }, ... }
function LiedLfos.bind_batch(config)
    for _, entry in ipairs(config) do
        LiedLfos.bind(entry[1], entry[2], entry[3], entry[4])
    end
end

-- TriSin has many LFO-able params, Ringer has a few. Per spec §10, we bind
-- shared amp+pan once (works for both classes), plus TriSin-specific and
-- Ringer-specific. 10 LFOs per cell × 16 cells = 160 LFOs.
-- The library adds ~13 params per LFO; total ~2080 LFO params added by this
-- function.
function LiedLfos.bind_row_2_lfos()
    for x = 1, 16 do
        local prefix = 'cell_' .. x .. '_2_'
        LiedLfos.bind('cell_' .. x .. '_amp',         prefix .. 'amp',         0, 2)
        LiedLfos.bind('cell_' .. x .. '_pan',         prefix .. 'pan',        -1, 1)
        LiedLfos.bind('cell_' .. x .. '_attack',      prefix .. 'attack',      0, 5)
        LiedLfos.bind('cell_' .. x .. '_release',     prefix .. 'release',     0, 10)
        LiedLfos.bind('cell_' .. x .. '_cutoff',      prefix .. 'cutoff',     20, 18000)
        LiedLfos.bind('cell_' .. x .. '_resonance',   prefix .. 'resonance',   0, 4)
        LiedLfos.bind('cell_' .. x .. '_fm_index',    prefix .. 'fm_index',    0, 20)
        LiedLfos.bind('cell_' .. x .. '_fm_cratio',   prefix .. 'fm_carrier_ratio', 0.1, 16)
        LiedLfos.bind('cell_' .. x .. '_fm_mratio',   prefix .. 'fm_modulator_ratio', 0.1, 16)
        LiedLfos.bind('cell_' .. x .. '_decay',       prefix .. 'decay',     0.1, 20)
    end
end

function LiedLfos.bind_sampler_lfos()
    for slot = 1, 16 do
        local prefix = 'sampler_' .. slot .. '_'
        LiedLfos.bind('sampler_' .. slot .. '_amp',       prefix .. 'amp',        0, 2)
        LiedLfos.bind('sampler_' .. slot .. '_pan',       prefix .. 'pan',       -1, 1)
        LiedLfos.bind('sampler_' .. slot .. '_cutoff',    prefix .. 'cutoff',    20, 18000)
        LiedLfos.bind('sampler_' .. slot .. '_resonance', prefix .. 'resonance',  0, 4)
    end
end
-- 4 LFOs × 16 samplers = 64 sampler LFOs

function LiedLfos.bind_oneshot_lfos()
    for slot = 1, 13 do
        local prefix = 'oneshot_' .. slot .. '_'
        LiedLfos.bind('oneshot_' .. slot .. '_amp',       prefix .. 'amp',        0, 2)
        LiedLfos.bind('oneshot_' .. slot .. '_pan',       prefix .. 'pan',       -1, 1)
        LiedLfos.bind('oneshot_' .. slot .. '_cutoff',    prefix .. 'cutoff',    20, 18000)
        LiedLfos.bind('oneshot_' .. slot .. '_resonance', prefix .. 'resonance',  0, 4)
    end
end
-- 4 LFOs × 13 one-shots = 52 oneshot LFOs

function LiedLfos.bind_crow_lfos()
    LiedLfos.bind('wsyn_lpg_speed',     'wsyn_lpg_speed',    -5, 5)
    LiedLfos.bind('wsyn_lpg_symmetry',  'wsyn_lpg_symmetry', -5, 5)
    LiedLfos.bind('wsyn_fm_index',      'wsyn_fm_index',      0, 5)
    LiedLfos.bind('wsyn_fm_envelope',   'wsyn_fm_envelope',  -5, 5)
    LiedLfos.bind('wdel_feedback',      'wdel_feedback',      0, 1)
    LiedLfos.bind('wdel_filter_cutoff', 'wdel_filter_cutoff', 0, 1)
end
-- 6 crow LFOs (skipping fm_num and fm_deno — those are int-typed params)

return LiedLfos
