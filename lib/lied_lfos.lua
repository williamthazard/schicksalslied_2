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
-- Each LFO call adds 13 params (state, shape, depth, phase, offset, min, max,
-- baseline, mode, clocked rate, free rate, reset, reset_target) — auto-named
-- via lfo_<lfo_id>_* pattern by the library.
function LiedLfos.bind(lfo_id, target_param_id, min, max)
    local lfo = LFO:add{
        shape  = 'sine',
        min    = min or 0,
        max    = max or 1,
        depth  = 0,
        mode   = 'clocked',
        period = 4,
        action = function(scaled, raw)
            params:set(target_param_id, scaled)
        end,
    }
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

return LiedLfos
