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

return LiedLfos
