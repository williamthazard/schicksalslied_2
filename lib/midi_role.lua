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

-- Build the device list from midi.vports. Called once at Midi.init().
-- Each vport may have a name like "norns" (built-in) or "OP-1 field" (USB);
-- empty vports get a "port N" placeholder so the option list always has
-- 4 entries (matching Norns's vport count).
function Midi.build_device_list()
    local devices = {}
    for i = 1, #midi.vports do
        local n = midi.vports[i].name
        table.insert(devices, n ~= "none" and n or ('port ' .. i))
    end
    return devices
end

-- Initialize MIDI: connect to the device at the current midi_device param.
-- Called from schicksalslied.lua's init() AFTER add_params + params:bang.
function Midi.init()
    Midi.connect_device(params:get('midi_device') or 1)
end

-- (Re-)connect to the MIDI device at vport index n.
-- Called from the midi_device param action.
function Midi.connect_device(n)
    Midi.device = midi.connect(n)
    print(string.format('MIDI: connected vport %d (%s)',
        n, Midi.device.name or 'unknown'))
end

-- Dispatch a MIDI note event for the cell at (x, y).
-- Called from cell_roles.lua's MIDI role dispatcher.
-- seq is the cell's sequins-byte-reader function.
function Midi.dispatch(x, y, seq)
    if Midi.device == nil then return end
    local Roles = include 'lib/cell_roles'
    local cell_id = string.format("%d_%d", x, y)
    local channel = params:get('cell_' .. x .. '_2_midi_channel') or 1
    local note = Roles.quantize_note(seq() % 32 + 49)  -- MIDI 49..80, scale-snapped
    local vel = math.min(127, seq() % 32 + 49)  -- velocity range 49..80
    -- Note-off any previously-active note from this cell. Use the PREVIOUS
    -- channel (which may differ from current if channel changed mid-sequence)
    -- so the off lands on the same channel the on was sent to.
    -- Note: Norns MIDI signature is dev:note_off(note, vel, ch); vel may be nil.
    local prev = Midi.active_notes[cell_id]
    if prev then
        Midi.device:note_off(prev.note, nil, prev.channel)
    end
    Midi.active_notes[cell_id] = { note = note, channel = channel }
    Midi.device:note_on(note, vel, channel)
    -- Schedule note-off after gate time. Capture note + channel in the
    -- closure so the off always targets the on's exact pair, even if a
    -- subsequent dispatch replaces active_notes[cell_id].
    -- Gate time is a single global param (modeled on awake's simpler
    -- "one gate control" approach — per-cell gate was over-engineered).
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

-- All-notes-off — iterate tracked active_notes and send a note_off for each.
-- Cleaner than blasting CC 123 on all 16 channels (which would interfere
-- with other scripts/processes sharing the device).
function Midi.all_notes_off()
    if Midi.device == nil then return end
    for _, entry in pairs(Midi.active_notes) do
        Midi.device:note_off(entry.note, nil, entry.channel)
    end
    Midi.active_notes = {}
end

-- Channel-change handler. When a cell's MIDI channel changes mid-sequence,
-- note-off the cell's currently-active note (on the OLD channel) so it
-- doesn't get stranded when we start sending to a new channel.
-- Called from the per-cell midi_channel param action.
function Midi.on_channel_change(x, y)
    local cell_id = string.format("%d_%d", x, y)
    local entry = Midi.active_notes[cell_id]
    if entry and Midi.device then
        Midi.device:note_off(entry.note, nil, entry.channel)
        Midi.active_notes[cell_id] = nil
    end
end

return Midi
