# `lib/midi_feedback.lua` — Line-by-Line

The MIDI controller feedback module. **127 lines**. Keeps every MIDI-mapped parameter's controller (for example a Midi Fighter Twister with LED rings) showing the parameter's current value, whoever changed it.

Conceptual context: [chapter 19](19-schicksalslied.lua.md) (where `init`, `resend` and `cleanup` are called). The module is independent of [chapter 16](16-midi_role.lua.md) (MIDI out role) and [chapter 17](17-midi_input.lua.md) (MIDI keyboard voice); section 9 explains why they cannot collide.

Sections:

1. Header: why norns' own echo is not enough (lines 1-17)
2. State and captured constants (lines 19-32)
3. `cc_for`: the inverse mapping (lines 34-53)
4. `param_for` (lines 55-59)
5. `sync`: the polling pass (lines 61-78)
6. `on_midi`: not echoing the controller back (lines 80-99)
7. `resend` (lines 101-105)
8. `init` (lines 107-118)
9. `cleanup` (lines 120-125)
10. Module return (line 127)

## 1. Header: why norns' own echo is not enough

```lua
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
```

**Lines 1-17**: the header comment. It is the whole design in miniature.

In the norns PARAMETERS > MAP page each mapping has an `echo` option. When it is on, norns sends the param's value back out as a CC so the controller's ring follows. The catch is *where* norns does that. In norns' `paramset.lua`, `ParamSet:delta` (the path a norns encoder takes) finishes with `if midi_prm.echo then ... midi.vports[port]:cc(...)`. `ParamSet:set` and `ParamSet:set_raw` do not: they just call `param:set`, which runs the param's action and nothing else. The only other echo is in `ParamSet:add`, which fires once when a param is declared.

That leaves a lot of changes with no echo at all:

- a **PSET load** (`ParamSet:read` sets values with `params:set`),
- **LFOs** (they write through `params:set`),
- the **grid** and the script's own code (`params:set` / `params:set_raw`),
- the norns **params menu** when the change goes through `set` rather than `delta`.

The controller goes stale and the next physical turn jumps the param to wherever the ring was. Hence the approach: instead of hooking each source of change, **compare, regularly, what the controller was last told against what the param is now**.

`★ Insight ─────────────────────────────────────`
**Polling catches every source of change by construction.** Hooking `params:set` would need a wrapper on every param action and every code path that bypasses actions (LFOs write straight into param values). The poll does not care *how* a value changed, only *that* it differs from what the controller holds. The cost is up to 1/15 s of latency, which is invisible on an LED ring.

**It applies to every mapping, not only those with the `echo` flag.** Echo is a norns opt-in for one narrow case. Feedback here is unconditional: a mapped param is a param the controller should mirror.
`─────────────────────────────────────────────────`

## 2. State and captured constants

```lua
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
```

**Lines 19-32**: module state and a few locals.

- `RATE` is the pass frequency, 15 per second.
- `last[id]` is the CC value the controller currently holds for param `id`, whether we sent it or the controller sent it to us. This is the "sync" bookkeeping the whole module revolves around.
- `where[id]` records *which* port, channel and CC that value went to, packed into one number (`(dev * 17 + ch) * 128 + cc`, see section 5). If the user re-maps a param to a different knob, `where` no longer matches and the value is sent again to the new place. A single number avoids building a table (and garbage) per param per pass.
- `timer`, `prior_event` and `prior_add` hold the metro and the two norns functions this module wraps, so `cleanup` can put them back.
- The `T_*` locals capture the param type constants once. `params` is a global, but a local costs one register lookup instead of a table access in a loop that runs 15 times a second. `floor` is localized for the same reason.

## 3. `cc_for`: the inverse mapping

```lua
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
```

**Lines 34-53**: given a param and its map entry `pm`, compute the CC value that would make norns' MAP handler produce the param's current value.

norns' `menu_midi_event` turns an incoming CC into a param value in two steps: clamp the CC to `in_lo..in_hi`, then `linlin` it onto `out_lo..out_hi`. For controls and tapers it then calls `params:set_raw(r, s)`, so `out_lo..out_hi` is a range of the *raw* 0-1 position. For numbers and options it rounds and calls `params:set`; for binaries it calls `params:delta`. `cc_for` runs that backwards:

1. Pick the matching quantity: `p:get_raw()` for control and taper (so a log-curved cutoff or amp ring tracks the knob position, not the Hz or dB value), `p:get()` for number, option and (non-trigger) binary. Anything else (text, trigger, file, separator) returns `nil` and is skipped.
2. Turn that into a 0-1 fraction of the map's output range. `span` is negative when the map is **inverted** (`out_hi` below `out_lo`); the division handles that without a special case, and the fraction is still 0 at the `out_lo` end and 1 at the `out_hi` end. A zero-width range gives 0 instead of dividing by zero.
3. Clamp the fraction to 0-1. A param can sit outside the mapped window (the user narrowed the out range after setting the value), and the CC must stay in `in_lo..in_hi`.
4. Scale onto `in_lo..in_hi` and round to the nearest integer with `floor(x + 0.5)`.

The result is an integer CC, which is exactly what MIDI can carry. Note it is a *function of the param's value*, not a stored value: after a PSET load or an LFO tick the answer changes by itself.

## 4. `param_for`

```lua
-- The mapped param, or nil if the map names a param this script doesn't have.
local function param_for(id)
    local i = params.lookup[id]
    return i and params.params[i]
end
```

**Lines 55-59**: look a param up by id. `params.lookup[id]` is the index into `params.params`; the function returns the param object, or `nil` when the map names a param this script does not have (the pmap file is per script but can hold entries from older versions).

Only `on_midi` uses it. `sync` inlines the same two lookups, as its own comment says, to avoid a function call per mapping per pass.

## 5. `sync`: the polling pass

```lua
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
```

**Lines 61-78**: the heart of the module. Once per tick it walks `norns.pmap.data` (the table of every mapping, keyed by param id).

- **Line 62** captures `params.lookup`, `params.params` and `norns.pmap.rev` (the reverse map `rev[dev][ch][cc] -> id`) into locals once per pass.
- **Lines 64-65**: skip entries whose param no longer exists, and entries `cc_for` cannot compute (`v` is `nil`).
- **Lines 67-68** build the destination number `to`. The 17 is deliberate: channels run 1-16, so `dev * 17 + ch` is unique per device/channel pair, and `* 128 + cc` makes the whole triple unique.
- **Lines 69-71**: send when either the value or the destination changed **and** the reverse map says this CC really belongs to this param.

That last check matters. When you open a param on the MAP page, norns creates a map entry immediately with a placeholder (default CC 100, channel 1) so you can edit it, *before* MIDI learn assigns anything. Without the `rev[dev][ch][cc] == id` test, opening the MAP page on a param would blast CC 100 values at whatever really lives on CC 100. The reverse map only contains assignments norns has actually committed, so an unassigned placeholder is never sent.

- **Line 72**: `midi.vports[dev]:cc(cc, v, ch)`. A vport with nothing plugged in just drops the message, so no connection check is needed.
- **Line 73** records what the controller now holds.
- **Line 74** updates `pm.value`. For **relative ("accum") maps** norns does not scale the incoming CC at all; it keeps its own running position in `pm.value` and moves it by one per detent (see `menu_midi_event`: `d.value = clamp(d.value + v, in_lo, in_hi)`). If the param is changed elsewhere, that stored position goes stale and the next detent would start from the old spot. Setting `pm.value = v` keeps norns' notion of the encoder position equal to the param's. (For absolute maps the field is unused, so the write is harmless.)

Because everything is gated on `v ~= last[id] or to ~= where[id]`, a steady-state pass sends nothing at all.

`★ Insight ─────────────────────────────────────`
**Every param is read through the same path, so LFOs animate the ring.** A mapped param under an LFO changes value continuously; each change that moves the rounded CC is sent. That is accepted behaviour: the ring shows what the param is doing. Only values whose rounded CC changes cost a message, so a slow LFO sends far fewer than 15 messages a second.

**No allocation per pass.** The loop creates no tables, closures or strings. On a Raspberry Pi class device, steady garbage from a 15 Hz loop is exactly what shows up later as a GC stall, so the code is written to produce none.
`─────────────────────────────────────────────────`

## 6. `on_midi`: not echoing the controller back

```lua
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
```

**Lines 80-99**: replaces norns' handler for incoming mapped CCs (`norns.menu_midi_event`, installed in `init`).

When a CC arrives *from* the controller, norns sets the param. If the poll then sent that value back, two things go wrong:

1. **The encoder is yanked mid-turn.** The ring is moving under the user's fingers; a reply a moment later fights it.
2. **Stepped params get trapped.** Take an option param with 3 choices mapped over the default CC range 0-127. norns converts CC `v` to `1 + 2*v/127` and rounds, so option 2 owns CCs 32 to 95. The user turns the encoder slowly and reaches CC 40: the param becomes option 2. The poll computes the CC *for option 2*, which is 64 (the middle of the step), and sends it back, and the ring jumps from 40 to 64. Keep turning: 65, 66 ... the next pass pulls it back to 64 each time it differs. The encoder can never travel far enough to reach CC 96 and option 3. The controller has been told a different position than the one it is physically at.

So after norns handles a CC, the wrapper records the CC **as received** in effect: it stores `cc_for` of the param's new value in `last`, so the next pass sees `v == last[id]` and stays quiet. The controller keeps its own position; only changes that came from elsewhere are sent out.

Walking the code:

- **Lines 84-86** work out, *before* calling norns, which param (if any) this CC was mapped to. The `- 175` turns status byte `0xB0 + channel - 1` into channel 1-16; any other status gives a number outside 1-16 and `rev` becomes `false`.
- **Line 87** runs norns' original handler, so everything norns does (set the param, learn, redraw the menu) still happens.
- **Lines 88-91** bail out if the message was not a mapped CC.
- **Lines 92-95**: if the CC maps to the *same* param after the call as before it (`id == before`), norns just applied a turn. Mark that param in sync using the value norns derived.
- **Lines 96-98**: if the mapping *changed* during the call, norns just MIDI-learned this CC onto a param (the MAP page assigned it). Setting `last[id] = nil` forces the next pass to send the param's real value to the new knob, which is exactly what the user wants when they have just assigned it: the ring should jump to the current value.

## 7. `resend`

```lua
-- Forget what the controllers hold, so the next pass sends every mapped
-- value (after a PSET load, or when a device is plugged in).
function MidiFeedback.resend()
    for id in pairs(last) do last[id] = nil end
end
```

**Lines 101-105**: forget everything the controllers are believed to hold. Because `sync` sends whenever `v ~= last[id]`, clearing `last` makes the next pass send every mapped value. The loop deletes keys in place instead of replacing the table with `{}`, which keeps the reference stable and allocates nothing. (Assigning `nil` to an existing field during `pairs` is explicitly allowed by Lua.)

It is called in two places: at the end of `params.action_read` (a PSET load changes many values through `params:set`, which the poll would also catch, but a resend guarantees the controller is refreshed even if a loaded value happens to equal the previous one) and from the `midi.add` hook below (a controller plugged in later has never been told anything).

## 8. `init`

```lua
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
```

**Lines 107-120**: install the feedback.

- **Line 108** makes `init` idempotent: if `prior_event` is already set, the module is running.
- **Lines 109-110** save norns' handler and put `on_midi` in its place. norns calls `norns.menu_midi_event` through the global table, so replacing the field is enough.
- **Lines 111-117** wrap `midi.add`, the function norns calls when a MIDI device is plugged in while the script runs. The wrapper calls the original first and then `resend()`, so a Twister plugged in after the script started gets every value: `last` is cleared, and the next pass sends. A second `resend()` two seconds later (a one-off `clock.run`) covers a controller that was still starting up when the first burst arrived.
- **Lines 118-119** create the 15 Hz metro. `metro.init` returns `nil` when all of norns' metros are in use; the guard keeps `init` from erroring in that case (feedback is simply off). The first pass runs about 1/15 s after `init`, so a freshly loaded script bangs out all of its mapped values almost immediately.

`★ Insight ─────────────────────────────────────`
**Wrapping instead of replacing.** norns has one `menu_midi_event` and one `midi.add`; other code (the menu, other mods) depends on them. Saving the prior function and calling it first means this module only *adds* behaviour. It is the same capture-then-chain idiom used for `clock_tempo` and `monitor_level` in chapter 19.
`─────────────────────────────────────────────────`

## 9. `cleanup`

```lua
function MidiFeedback.cleanup()
    if timer then timer:stop(); timer = nil end
    if prior_event then                             -- only undo what init did
        norns.menu_midi_event = prior_event
        midi.add = prior_add
        prior_event, prior_add = nil, nil
    end
end
```

**Lines 122-129**: undo everything `init` did, in order: stop and drop the metro, restore `norns.menu_midi_event`, restore `midi.add`. This matters because norns does not reload its core between scripts. If the wrappers stayed installed, the next script would run through this script's `on_midi`, which would then be sending CCs from a stale `norns.pmap` walk.

The `if prior_event` guard means calling `cleanup` without `init` (or twice) is harmless: only what `init` actually installed is put back. norns' own `midi.cleanup()` also resets `midi.add` when a script unloads, so the two agree.

### Why this cannot interfere with the other MIDI modules

- **MIDI input (`midi_input.lua`)**: it does `midi.connect(n)` and sets the port's `event`, its note handler. norns calls that handler first and `norns.menu_midi_event` afterwards, for every incoming message. The wrapper does not touch the port's handler, passes every message to norns' original first, and for anything but a CC does one comparison and returns, so a note has already reached the voice before the wrapper sees it. Free-playing a TriSin from a keyboard while the grid sequences is unaffected, and a keyboard knob can still be mapped like any other controller.
- **MIDI out role (`midi_role.lua`)**: the role sends note on and off to a vport. Feedback sends only CCs, and only for mapped params and only when a value changed. The two never share state. If the same device is the note destination *and* a mapped controller, the CCs are ordinary traffic on the same cable.
- **CPU**: per keyboard note the wrapper adds one comparison (about 50 ns on a laptop). Notes from the sequencer and the MIDI role never pass through it.

## 10. Module return

```lua
return MidiFeedback
```

**Line 131**: standard return. The three functions used by the script are `init`, `resend` and `cleanup`; everything else is local.

## CPU cost

The user had just finished a CPU-reduction pass, so this module is built to cost almost nothing:

- **15 Hz**, not 30 or 60. Rings are slow; this is enough.
- **No allocation in a pass that sends nothing.** Locals are captured, the loop is `pairs` over an existing table, destinations are packed into one integer, and nothing builds tables or strings. No garbage means no GC pressure from the poll; only an actual MIDI send allocates, inside norns.
- **Sends only on change.** In steady state a pass does arithmetic and comparisons, no MIDI I/O. MIDI messages happen only when a value or a mapping changed.
- **Cheap per-mapping work.** One `lookup`, one `get`/`get_raw`, a handful of arithmetic operations.

Measured with a stand-in harness on a laptop, one pass over 64 mappings takes about 25-30 microseconds. A Raspberry Pi CM3+ class device runs roughly 10-20 times slower than a laptop core, so expect on the order of 0.3-0.6 ms per pass, or under 1 percent of one core at 15 Hz (a typical 16-32 mappings: well under half that). The number grows linearly with the mapping count, and mapping nothing makes the pass an empty loop.

## Summary

`midi_feedback.lua` is a small polling layer that makes mapped controllers mirror param state:

- norns' `echo` fires only from `params:delta`; PSETs, LFOs, the grid and `params:set` never echo, so the controller drifts.
- A **15 Hz poll** over `norns.pmap.data` compares each param's computed CC to the last one sent or received, and sends only when they differ.
- `cc_for` is the **inverse of norns' scaling**: raw 0-1 for control and taper, the value itself for number, option and binary, inverted ranges handled by the sign of the span.
- **Controller turns are never echoed**: `norns.menu_midi_event` is wrapped so the param is marked in sync. This avoids yanking encoders mid-turn and trapping stepped params on one step.
- **MIDI learn** clears the entry so the new knob gets the current value; **unassigned placeholders** (default CC 100) are skipped via the reverse map.
- **Relative maps** keep `pm.value` equal to the param.
- **`resend`** runs after a PSET load and when a device is plugged in; **`cleanup`** puts norns' handlers back.

To extend it: add a new param type by extending the type test in `cc_for` and checking how `menu_midi_event` sets that type; to change the polling rate, change `RATE` (the rest is rate-independent).
