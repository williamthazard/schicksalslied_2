-- lib/midi_feedback.lua — keep MIDI-mapped controllers (e.g. a Midi
-- Fighter Twister) showing each param's current value.
--
-- norns' own MAP "echo" only sends when a norns encoder turns a param
-- (params:delta). PSET loads, LFOs, the grid and the script change params
-- through params:set, which never echoes, so the controller went stale and
-- the next turn jumped. Instead, 15 times a second this walks the MIDI map
-- and sends a mapped param's CC whenever its value no longer matches the
-- last one sent. Every mapped param gets this, echo on or not.
--
-- Turns that arrive FROM the controller are not sent back: norns' handler
-- for mapped CCs (norns.menu_midi_event) is wrapped so a param the
-- controller just set counts as in sync. Echoing it would pull an encoder
-- back mid-turn, and on stepped params trap it on one step.
--
-- Cost per pass: one loop over the mapped params, no allocation; MIDI is
-- sent only for values that changed.

local MidiFeedback = {}

local RATE = 15          -- passes per second

local last = {}          -- param id -> CC value the controller holds (sent or received)
local where = {}         -- param id -> port/channel/CC that value went to, as one number
local timer = nil
local prior_event = nil
local prior_add = nil

-- norns param types a CC can set (captured once; params is global)
local T_NUMBER, T_OPTION, T_CONTROL = params.tNUMBER, params.tOPTION, params.tCONTROL
local T_TAPER, T_BINARY = params.tTAPER, params.tBINARY
local floor = math.floor

-- The CC value norns' map turns into param p's current value: the inverse
-- of menu_midi_event's scaling (raw 0-1 for controls and tapers, the value
-- itself for numbers, options and toggles). nil for a param a CC can't set
-- (text, triggers, files).
local function cc_for(p, pm)
    local t, val = p.t, nil
    if t == T_CONTROL or t == T_TAPER then
        val = p:get_raw()
    elseif t == T_NUMBER or t == T_OPTION or (t == T_BINARY and p.behavior ~= 'trigger') then
        val = p:get()
    else
        return nil
    end
    local lo = pm.out_lo
    local span = pm.out_hi - lo                     -- negative for an inverted map
    local frac = span ~= 0 and (val - lo) / span or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local in_lo = pm.in_lo
    return floor(in_lo + frac * (pm.in_hi - in_lo) + 0.5)
end

-- The mapped param, or nil if the map names a param this script doesn't have.
local function param_for(id)
    local i = params.lookup[id]
    return i and params.params[i]
end

local function sync()
    local lookup, plist, rev = params.lookup, params.params, norns.pmap.rev
    for id, pm in pairs(norns.pmap.data) do
        local i = lookup[id]                        -- param_for, inlined: this runs 15x/s
        local v = i and cc_for(plist[i], pm)
        if v then
            local dev, ch, cc = pm.dev, pm.ch, pm.cc
            local to = (dev * 17 + ch) * 128 + cc
            -- The reverse-map check skips an entry norns made when a MAP page
            -- opened but hasn't assigned yet (default CC 100, controls nothing).
            if (v ~= last[id] or to ~= where[id]) and rev[dev][ch][cc] == id then
                midi.vports[dev]:cc(cc, v, ch)    -- no-op if nothing is plugged in
                last[id], where[id] = v, to
                pm.value = v        -- norns' position for relative ("accum") maps
            end
        end
    end
end

-- Runs norns' handler, then marks the param a controller just set as in
-- sync. A CC that norns has just MIDI-learned is marked out of sync
-- instead, so the next pass sends the param's real value to the new knob.
local function on_midi(data, dev)
    local ch = (data[1] or 0) - 175                 -- 1-16 for a CC message
    local rev = ch >= 1 and ch <= 16 and norns.pmap.rev[dev] and norns.pmap.rev[dev][ch]
    local before = rev and rev[data[2]]
    prior_event(data, dev)
    if not rev then return end
    local id = rev[data[2]]
    local pm = id and norns.pmap.data[id]
    if not pm then return end
    if id == before then
        local p = param_for(id)
        last[id] = p and cc_for(p, pm)
        where[id] = (pm.dev * 17 + pm.ch) * 128 + pm.cc
    else
        last[id] = nil
    end
end

-- Forget what the controllers hold, so the next pass sends every mapped
-- value (after a PSET load, or when a device is plugged in).
function MidiFeedback.resend()
    for id in pairs(last) do last[id] = nil end
end

function MidiFeedback.init()
    if prior_event then return end                  -- already running
    prior_event = norns.menu_midi_event
    norns.menu_midi_event = on_midi
    prior_add = midi.add
    midi.add = function(dev)
        if prior_add then prior_add(dev) end
        -- Again 2 s later, in case the device was still starting up.
        MidiFeedback.resend()
        clock.run(function() clock.sleep(2); MidiFeedback.resend() end)
    end
    timer = metro.init(sync, 1 / RATE)
    if timer then timer:start() end                 -- nil only if norns is out of metros
end

function MidiFeedback.cleanup()
    if timer then timer:stop(); timer = nil end
    if prior_event then                             -- only undo what init did
        norns.menu_midi_event = prior_event
        midi.add = prior_add
        prior_event, prior_add = nil, nil
    end
end

return MidiFeedback
