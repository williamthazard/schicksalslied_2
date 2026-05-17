-- lib/midi_input.lua — MIDI keyboard input → play a TriSin or Ringer voice
-- Allocates a SEPARATE SC voice instance (cellId = 'midi_input_voice') that is
-- not driven by the grid sequencer. Note-on plays the voice at the MIDI note's
-- frequency; note-off gates off (for TriSin) or is ignored (Ringer self-frees).

local MusicUtil = require 'musicutil'
local MidiInput = {}

-- The voice's special cell id (passed to engine.trisin_trigger etc.)
MidiInput.CELL_ID = 'midi_input_voice'

MidiInput.device = nil
MidiInput.role = 'TriSin'  -- current role; mirrors midi_input_role param

-- Track active notes per (note, channel) → voice_key so note_off can target the
-- right voice. For TriSin we use round-robin voice keys 1..8.
MidiInput.active_notes = {}
MidiInput.rr_counter = 0

function MidiInput.build_device_list()
    local devices = {}
    for i = 1, #midi.vports do
        local n = midi.vports[i].name
        table.insert(devices, n ~= "none" and n or ('port ' .. i))
    end
    return devices
end

function MidiInput.init()
    -- Allocate voice with the role from params
    MidiInput.set_role((params:get('midi_input_role') or 1))
    MidiInput.connect_device((params:get('midi_input_device') or 1))
end

function MidiInput.connect_device(n)
    if MidiInput.device then MidiInput.device.event = nil end
    MidiInput.device = midi.connect(n)
    MidiInput.device.event = function(msg) MidiInput.handle_event(msg) end
    print(string.format('MIDI INPUT: connected vport %d (%s)', n, MidiInput.device.name or 'unknown'))
end

function MidiInput.set_role(role_idx)
    local new_role = ({ 'TriSin', 'Ringer' })[role_idx] or 'TriSin'
    if new_role == MidiInput.role and MidiInput._allocated then return end
    -- Free previous instance if role is changing
    if MidiInput._allocated then
        if MidiInput.role == 'TriSin' then
            engine.trisin_free(MidiInput.CELL_ID)
        elseif MidiInput.role == 'Ringer' then
            engine.ringer_free(MidiInput.CELL_ID)
        end
        MidiInput.active_notes = {}
    end
    MidiInput.role = new_role
    -- Allocate new instance
    if new_role == 'TriSin' then
        engine.trisin_alloc(MidiInput.CELL_ID)
    elseif new_role == 'Ringer' then
        engine.ringer_alloc(MidiInput.CELL_ID)
    end
    MidiInput._allocated = true
    MidiInput._reapply_voice_params()
    print('MIDI INPUT: role = ' .. new_role)
end

-- Push all per-voice params from the midi_input_* params to the freshly
-- allocated SC instance.
function MidiInput._reapply_voice_params()
    local shared = { 'amp', 'amp_slew', 'pan', 'pan_slew',
                     'dry_send', 'reverb_send', 'delay_send', 'granular_send' }
    for _, k in ipairs(shared) do
        local pid = 'midi_input_' .. k
        if params.lookup[pid] then params:set(pid, params:get(pid)) end
    end
    if MidiInput.role == 'TriSin' then
        local trisin_only = {
            'attack', 'release', 'attack_curve', 'release_curve',
            'fm_carrier_ratio', 'fm_modulator_ratio', 'fm_index', 'fm_iscale',
            'fm_env_attack', 'fm_env_release', 'fm_env_attack_curve', 'fm_env_release_curve',
            'cutoff', 'cutoff_env', 'resonance', 'freq_slew',
        }
        for _, k in ipairs(trisin_only) do
            local pid = 'midi_input_' .. k
            if params.lookup[pid] then params:set(pid, params:get(pid)) end
        end
    elseif MidiInput.role == 'Ringer' then
        local pid = 'midi_input_decay'
        if params.lookup[pid] then params:set(pid, params:get(pid)) end
    end
end

function MidiInput.handle_event(msg)
    local d = midi.to_msg(msg)
    -- Channel filter: 0 = omni (accept all channels), else exact match
    local ch_filter = params:get('midi_input_channel') or 0
    if ch_filter ~= 0 and d.ch ~= ch_filter then return end
    if d.type == 'note_on' and d.vel > 0 then
        MidiInput._note_on(d.note, d.vel, d.ch)
    elseif d.type == 'note_off' or (d.type == 'note_on' and d.vel == 0) then
        MidiInput._note_off(d.note, d.ch)
    end
end

function MidiInput._note_on(note, vel, ch)
    local freq = MusicUtil.note_num_to_freq(note)
    if MidiInput.role == 'TriSin' then
        -- Round-robin a voice key for polyphony
        MidiInput.rr_counter = (MidiInput.rr_counter % 8) + 1
        local voice_key = tostring(MidiInput.rr_counter)
        MidiInput.active_notes[note .. '_' .. ch] = voice_key
        engine.trisin_trigger(MidiInput.CELL_ID, voice_key, freq)
    elseif MidiInput.role == 'Ringer' then
        -- Ringer is perc; allocate fresh on each note (envelope auto-frees)
        MidiInput.rr_counter = (MidiInput.rr_counter % 8) + 1
        local voice_key = tostring(MidiInput.rr_counter)
        engine.ringer_trigger(MidiInput.CELL_ID, voice_key, freq)
    end
end

function MidiInput._note_off(note, ch)
    -- For TriSin: gate off by re-triggering with t_gate=0 isn't exposed; the
    -- existing trigger sets t_gate=1. To gate off, we'd need a new engine
    -- command. For now, the note rings out via its envelope's release.
    -- (Future: add engine.trisin_gate_off command if needed.)
    -- For Ringer: it self-frees via doneAction:2, nothing to do.
    MidiInput.active_notes[note .. '_' .. ch] = nil
end

function MidiInput.cleanup()
    if MidiInput.device then
        MidiInput.device.event = nil
    end
    if MidiInput._allocated then
        if MidiInput.role == 'TriSin' then
            engine.trisin_free(MidiInput.CELL_ID)
        elseif MidiInput.role == 'Ringer' then
            engine.ringer_free(MidiInput.CELL_ID)
        end
        MidiInput._allocated = false
    end
end

return MidiInput
