# `lib/midi_role.lua` — Line-by-Line

The MIDI-output role implementation. **110 lines**. Used by `cell_roles.lua`'s `dispatch_row_2['MIDI']` when a row-2 cell is configured to send MIDI notes to an external device.

Conceptual context: [chapter 12](12-cell_roles.lua.md) (where the MIDI role's dispatcher is registered) and [chapter 19](19-schicksalslied.lua.md) (MIDI init).

Sections:

1. Header + state (lines 1-17)
2. `build_device_list` (lines 19-30)
3. `init` and `connect_device` (lines 32-44)
4. `dispatch` — the main entry point (lines 46-84)
5. `all_notes_off` (lines 86-95)
6. `on_channel_change` (lines 97-108)
7. Module return (line 110)

## 1. Header and state

```lua
-- lib/midi_role.lua — MIDI output role state + dispatch
-- Owns: the connected MIDI device handle, per-cell active-note tracking.
-- Pattern modeled on tehn/awake.lua: dynamic vports list, per-note tracking
-- for clean note-offs, no all-channel CC123 blast.

local Midi = {}

-- The connected MIDI device (set by Midi.init / device-change action).
-- nil-safe so other modules (panic, dispatch) can check before calling.
Midi.device = nil

-- Per-cell active-note tracking. Keyed by cell_id ('1_2'); value is
-- { note=N, channel=C } for the currently-sounding note from that cell.
-- We use this both to note-off the previous note before retriggering, and
-- to drive panic's all_notes_off without resorting to a CC123 blast that
-- could step on other scripts sharing the device.
Midi.active_notes = {}
```

**Lines 1-17**: header + two state fields.

The header names two design choices:
1. **"Pattern modeled on tehn/awake.lua"** — the canonical Norns MIDI-out approach. Tehn's `awake` script is widely regarded as a reference implementation; following its patterns gives this script the same nice properties.
2. **"No all-channel CC123 blast"** — CC123 is the MIDI "all notes off" CC. Sending it on all 16 channels would silence everything on the connected device, which is too aggressive if you're running multiple scripts. Tracking individual active notes per cell lets us send precise note-off messages.

`Midi.device = nil` is the initial state. Set when `Midi.init` runs.

`Midi.active_notes = {}` is the tracking table. Keyed by cell_id string (`'1_2'`); each value is a `{ note, channel }` record.

`★ Insight ─────────────────────────────────────`
**Tracking active notes per cell solves multiple problems at once**:
1. **Clean retriggers**: when a cell fires its next note, send note_off for the previous one before note_on for the new one — otherwise you'd accumulate hanging notes on the receiver.
2. **Channel-aware note_off**: send note_off on the channel the original note_on was sent to. If the user changed channel mid-sequence, the previous note's off goes to the previous channel (not the current one).
3. **Precise panic**: enumerate active_notes and send a targeted note_off for each. No collateral damage to other MIDI traffic.

**The cost is O(N) state where N = cells using MIDI role.** Typically that's 0-3 cells; the memory is trivial. The benefit is correctness in edge cases that would otherwise produce hanging notes.
`─────────────────────────────────────────────────`

## 2. `build_device_list`

```lua
function Midi.build_device_list()
    local devices = {}
    for i = 1, #midi.vports do
        local n = midi.vports[i].name
        table.insert(devices, n ~= "none" and n or ('port ' .. i))
    end
    return devices
end
```

**Lines 23-30**: build a display list of available MIDI devices. Used to populate the `midi_device` param's option list.

`midi.vports` is Norns's global list of MIDI virtual ports. Norns shows 4 vports by default; each one can be assigned a real device via the system menu.

For each vport:
- If the name isn't "none", use the name (e.g., "OP-1 field").
- Otherwise use a placeholder "port N".

This way the option list always has exactly `#midi.vports` entries, and selecting a port works whether or not a device is currently assigned.

## 3. `init` and `connect_device`

```lua
function Midi.init()
    Midi.connect_device(params:get('midi_device') or 1)
end

function Midi.connect_device(n)
    Midi.device = midi.connect(n)
    print(string.format('MIDI: connected vport %d (%s)',
        n, Midi.device.name or 'unknown'))
end
```

**Lines 34-44**: initialize the module and connect to a vport.

`Midi.init()` reads the current value of `midi_device` (set by params:bang at script init) and calls `connect_device(n)`. Called from `schicksalslied.lua`'s init() AFTER `add_params + params:bang`. The ordering matters: we need the params to exist with their values populated before reading.

`Midi.connect_device(n)` uses `midi.connect(n)` to get a handle to vport n. Stores in `Midi.device`. Prints a diagnostic to the matron log so you can see which port the script connected to.

`midi.connect` always returns a handle, even for unassigned vports. Sending to an unassigned port is a no-op. So `Midi.device` is never nil after `init` — but the `nil-safe` checks elsewhere protect against the case where this module is used before `init` has been called.

## 4. `dispatch` — the main entry point

```lua
function Midi.dispatch(x, y, seq)
    if Midi.device == nil then return end
    local Roles = include 'lib/cell_roles'
    local cell_id = string.format("%d_%d", x, y)
    local channel = params:get('cell_' .. x .. '_2_midi_channel') or 1
    local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
    local note = Roles.quantize_note(seq() % 32 + 49 + offset)
    local vel = math.min(127, seq() % 32 + 49)
```

**Lines 49-59**: dispatcher start. Walk through:

- **Guard**: if no device, return immediately. Defensive against early use.
- **`include 'lib/cell_roles'`**: scoped to inside the function to avoid the circular dependency `cell_roles → midi_role → cell_roles`. The include is fresh per call but cheap. The function only uses `Roles.quantize_note`, which is a pure function — no cross-include identity issues.
- **`cell_id`**: the string ID for this cell.
- **`channel`**: read the per-cell MIDI channel param. Default 1.
- **`offset`**: read the per-cell pitch offset (in semitones). Default 0.
- **`note`**: read one byte from sequins, map to MIDI note range using `seq() % 32 + 49 + offset`, then quantize to the global scale.
- **`vel`**: read another byte, map to velocity 49-80, cap at 127.

The byte-to-note math is identical to TriSin's and Ringer's (chapter 08): `byte % 32 + 49` produces a MIDI note in 49-80 (C#3-G#5).

`★ Insight ─────────────────────────────────────`
**The "include inside the function" pattern** dodges Lua's circular-dependency limitation. `cell_roles.lua` requires `midi_role.lua` at its top level. If `midi_role.lua` required `cell_roles.lua` at its top level, you'd have a chicken-and-egg: cell_roles couldn't fully load until midi_role finished, but midi_role's top-level include needs cell_roles to be loaded.

Moving the include inside the function defers it. By the time `dispatch` is called, both modules have fully loaded; the include resolves to the already-cached table. The cost is one table lookup per dispatch (Norns's `include` does have an internal cache despite the surface-level "no caching" behavior — wait, actually it doesn't. See chapter 06 for the full story. The cost here is a fresh include per dispatch, but it's still cheap because the file is small and parsing is fast).

**A cleaner alternative**: declare a forward-reference `Midi.cell_roles_module = nil` at the top, set it from outside after both modules are loaded. The current approach is simpler at the cost of repeated includes per dispatch.
`─────────────────────────────────────────────────`

```lua
    local prev = Midi.active_notes[cell_id]
    if prev then
        Midi.device:note_off(prev.note, nil, prev.channel)
    end
    Midi.active_notes[cell_id] = { note = note, channel = channel }
    Midi.device:note_on(note, vel, channel)
```

**Lines 64-69**: send the note-off for any active note from this cell, then send the new note-on.

The `nil` in `note_off(prev.note, nil, prev.channel)` is the velocity arg. Norns's `midi:note_off(note, vel, ch)` accepts nil velocity (omits it from the MIDI message, which defaults to 64 on most receivers).

Updating `active_notes[cell_id]` BEFORE sending the note-on ensures the table reflects the new note immediately. If a panic fired between the table update and the note-on send (shouldn't happen, but defensive), the note-off would target the new note (which would harmlessly not exist yet on the receiver).

```lua
    local gate_time = params:get('midi_gate_time') or 0.1
    clock.run(function()
        clock.sleep(gate_time)
        Midi.device:note_off(note, nil, channel)
        local current = Midi.active_notes[cell_id]
        if current and current.note == note and current.channel == channel then
            Midi.active_notes[cell_id] = nil
        end
    end)
end
```

**Lines 75-84**: schedule the note-off after `gate_time` seconds.

The closure captures `note` and `channel` — the exact pair that was sent. So even if the user changes channel or the cell retriggers with a new note before the gate time expires, this closure's note_off targets the original on's exact channel and note.

After sending the off, the closure checks whether the current entry in `active_notes[cell_id]` still matches. If yes (no retrigger happened in the gate window), clear the entry. If no (a retrigger replaced the entry), leave it alone — the retrigger's own scheduled note_off will handle cleanup.

`clock.sleep(gate_time)` is wallclock, not beat-aligned. Note durations are typically not beat-aligned (they're user-defined release times).

`★ Insight ─────────────────────────────────────`
**The capture-then-check pattern** is the canonical way to schedule a cleanup that might be superseded:

```lua
clock.run(function()
    clock.sleep(delay)
    -- Do the cleanup, capturing the original state's matching identity:
    if current_state.id == captured_id then
        do_cleanup()
    end
end)
```

This pattern shows up wherever you have:
1. Some state that can change (`active_notes[cell_id]`).
2. A scheduled cleanup that depends on that state (note_off after gate_time).
3. The possibility that the state will change before the cleanup fires.

By capturing the identifying info in the closure AND checking it against current state at cleanup time, you ensure the cleanup only fires when appropriate.

**A subtle race condition** still exists: if a retrigger happens BETWEEN `clock.sleep(gate_time)` finishing and the closure's note_off being sent, that race could send a note_off after the new note_on. But the race window is microseconds (one matron event-loop tick) — too short to be heard.
`─────────────────────────────────────────────────`

## 5. `all_notes_off`

```lua
function Midi.all_notes_off()
    if Midi.device == nil then return end
    for _, entry in pairs(Midi.active_notes) do
        Midi.device:note_off(entry.note, nil, entry.channel)
    end
    Midi.active_notes = {}
end
```

**Lines 89-95**: enumerate active notes and send note_off for each. After: clear the table.

Called from panic handlers (in `schicksalslied.lua`'s panic flow). Cleanly silences every MIDI cell's currently-sounding note without affecting other notes the device might be playing from other sources.

The `pairs(Midi.active_notes)` iteration is non-deterministic order, which is fine — note-offs are independent and order doesn't matter.

## 6. `on_channel_change`

```lua
function Midi.on_channel_change(x, y)
    local cell_id = string.format("%d_%d", x, y)
    local entry = Midi.active_notes[cell_id]
    if entry and Midi.device then
        Midi.device:note_off(entry.note, nil, entry.channel)
        Midi.active_notes[cell_id] = nil
    end
end
```

**Lines 101-108**: handle a cell's MIDI channel changing mid-sequence.

Called from the `cell_X_2_midi_channel` param action (defined in `voice_params.lua`). The scenario: a cell is currently sounding a note on channel 5; the user changes the channel param to channel 7. Without this handler, the cell's currently-active note (on channel 5) would never get a note_off because all subsequent dispatches send on channel 7. The handler:

1. Look up the cell's currently-active note.
2. If found, send a note_off on the OLD channel (the one stored in `active_notes[cell_id].channel`).
3. Clear the active_notes entry.

After this, the next dispatch on this cell sends a note_on on the new channel cleanly.

`★ Insight ─────────────────────────────────────`
**The "note off on the OLD channel" detail is what makes this correct.** Without it, the user could create hanging notes by frequently switching channels: every channel change orphans a note on the old channel. By tracking the channel-of-record per cell, we ensure note_off always reaches the right destination.

**This is the kind of edge case** that's easy to overlook during initial implementation and easy to discover later when the user complains "my MIDI device has stuck notes." The handler being a separate function (rather than inlined into the channel param's action) makes it discoverable and testable.
`─────────────────────────────────────────────────`

## 7. Module return

```lua
return Midi
```

**Line 110**: standard return.

## Summary

`midi_role.lua` is a clean reference implementation of MIDI output for a sequenced script. The patterns to internalize:

- **Active-note tracking per source** for clean retriggers and panic.
- **Capture-then-check** for scheduled cleanups that might be superseded.
- **Note_off on the channel the note_on was sent to** — not the current channel.
- **All_notes_off via enumeration**, not CC123 blast — kind to other scripts sharing the device.
- **Defer-include for circular deps** when a module needs to reference another module that already references it.
- **Single global gate time** is simpler and (per the comment) deliberately less configurable than per-cell — the per-cell variant was tried and found over-engineered.

For adding new MIDI features (e.g., CC sends, program changes), this module is the right home. Add new functions following the same patterns: nil-safe device check, capture-then-check for any scheduled events, single global params for cross-cutting behavior.
