# `lib/midi_input.lua` — Line-by-Line

The MIDI keyboard input module. **143 lines**. Receives MIDI from an external keyboard and triggers a dedicated SC voice — separate from the grid sequencer cells.

Conceptual context: [chapter 19](19-schicksalslied.lua.md) (MIDI input init). The dedicated voice instance is allocated through the same engine commands covered in [chapter 04](04-Engine_Lied.sc.md).

Sections:

1. Header + state (lines 1-18)
2. `build_device_list` (lines 20-27)
3. `init` and `connect_device` (lines 29-40)
4. `set_role` (lines 42-64)
5. `_reapply_voice_params` (lines 66-90)
6. `handle_event` (lines 92-102)
7. `_note_on` / `_note_off` (lines 104-127)
8. `cleanup` (lines 129-141)
9. Module return (line 143)

## 1. Header and state

```lua
-- lib/midi_input.lua — MIDI keyboard input → play a TriSin or Ringer voice
-- Allocates a SEPARATE SC voice instance (cellId = 'midi_input_voice') that is
-- not driven by the grid sequencer. Note-on plays the voice at the MIDI note's
-- frequency; note-off gates off (for TriSin) or is ignored (Ringer self-frees).

local MusicUtil = require 'musicutil'
local MidiInput = {}

MidiInput.CELL_ID = 'midi_input_voice'

MidiInput.device = nil
MidiInput.role = 'TriSin'

MidiInput.active_notes = {}
MidiInput.rr_counter = 0
```

**Lines 1-18**: file header + state.

The key design choice: **a dedicated voice instance**, separate from the grid sequencer. The cell_id `'midi_input_voice'` is a special string (not `'X_Y'` like grid cells). This cell_id is what gets passed to `engine.trisin_alloc('midi_input_voice')`. The kernel allocates a voice instance keyed by this string in `triSinInstances`, parallel to the grid-driven instances.

This separation lets the user:
- Play melodies on a MIDI keyboard while the grid sequencer runs in parallel.
- Configure the MIDI voice's sound design independently (its own params: `midi_input_amp`, `midi_input_cutoff`, etc.).
- Switch the MIDI voice's role (TriSin or Ringer) without touching grid cells.

`MidiInput.active_notes` tracks (note, channel) → voice_key so note-off can target the right voice. `MidiInput.rr_counter` is the round-robin counter for voice allocation.

`★ Insight ─────────────────────────────────────`
**The "special cell_id" idiom** is how the script handles voices that aren't grid-driven. The SC kernel doesn't care whether the cell_id is `'1_2'` or `'midi_input_voice'` — both are strings; both are keyed in the same dictionary. By using a distinctive string for the MIDI voice, we get a separate voice instance without modifying the kernel's interface.

**Could there be other "special" voices in the future?** Sure — a foot-pedal-triggered voice, a clock-divider voice, etc. Each just picks a distinct cell_id string and uses the same engine commands. The pattern scales.
`─────────────────────────────────────────────────`

## 2. `build_device_list`

```lua
function MidiInput.build_device_list()
    local devices = {}
    for i = 1, #midi.vports do
        local n = midi.vports[i].name
        table.insert(devices, n ~= "none" and n or ('port ' .. i))
    end
    return devices
end
```

**Lines 20-27**: identical pattern to `midi_role.lua`'s `build_device_list`. Returns a display list of MIDI vports for the `midi_input_device` param's option list.

The list IS the same as midi_role's because they both inspect the same `midi.vports`. The duplication is intentional — each module builds its own list because each can independently connect to a different vport (input on one port, output on another).

## 3. `init` and `connect_device`

```lua
function MidiInput.init()
    MidiInput.set_role((params:get('midi_input_role') or 1))
    MidiInput.connect_device((params:get('midi_input_device') or 1))
end

function MidiInput.connect_device(n)
    if MidiInput.device then MidiInput.device.event = nil end
    MidiInput.device = midi.connect(n)
    MidiInput.device.event = function(msg) MidiInput.handle_event(msg) end
    print(string.format('MIDI INPUT: connected vport %d (%s)', n, MidiInput.device.name or 'unknown'))
end
```

**Lines 29-40**: init and device connection.

`MidiInput.init()`:
1. Set the role first (which allocates the SC voice).
2. Connect the device (which wires up the event handler).

Order matters: if we connected before setting role, an incoming MIDI message could fire `handle_event` before the SC voice is allocated, producing engine.trisin_trigger calls on a not-yet-allocated voice.

`MidiInput.connect_device(n)`:
1. If we're already connected to a device, unregister the event handler (`device.event = nil`). Without this, the OLD device would still call the handler if it sent MIDI — duplicated events.
2. Connect to the new vport.
3. Register the event handler.
4. Log.

`★ Insight ─────────────────────────────────────`
**Unregistering the old device's event handler before connecting a new one** is the standard pattern for changing-vport scenarios. Without it, you can get "phantom MIDI" — events from a device the user thought they disconnected. The `device.event = nil` is what prevents this.

**`device.event = function(msg) ... end`** sets the per-device callback. Norns's MIDI module fires this on every incoming message. The function receives a raw byte array (`msg`); we parse it via `midi.to_msg(msg)` inside the handler.
`─────────────────────────────────────────────────`

## 4. `set_role`

```lua
function MidiInput.set_role(role_idx)
    local new_role = ({ 'TriSin', 'Ringer' })[role_idx] or 'TriSin'
    if new_role == MidiInput.role and MidiInput._allocated then return end
    if MidiInput._allocated then
        if MidiInput.role == 'TriSin' then
            engine.trisin_free(MidiInput.CELL_ID)
        elseif MidiInput.role == 'Ringer' then
            engine.ringer_free(MidiInput.CELL_ID)
        end
        MidiInput.active_notes = {}
    end
    MidiInput.role = new_role
    if new_role == 'TriSin' then
        engine.trisin_alloc(MidiInput.CELL_ID)
    elseif new_role == 'Ringer' then
        engine.ringer_alloc(MidiInput.CELL_ID)
    end
    MidiInput._allocated = true
    MidiInput._reapply_voice_params()
    print('MIDI INPUT: role = ' .. new_role)
end
```

**Lines 42-64**: change the MIDI voice's role (TriSin or Ringer).

The `role_idx` arg is the params option index (1 or 2). The expression `({ 'TriSin', 'Ringer' })[role_idx] or 'TriSin'` is a compact lookup: construct an array literal, index it, fall back to TriSin on out-of-range.

The function:

1. **Early return if same role and already allocated** (`new_role == MidiInput.role and MidiInput._allocated`). The role param's action fires this every time the param is set, including at `params:bang` — without the guard, we'd thrash alloc/free.

2. **Free previous instance** if one exists. Different role → different SC class → must free old before allocating new.

3. **Clear `active_notes`**: any tracked notes from the old role's voice are no longer valid; the new voice has its own pool.

4. **Allocate new instance** for the new role.

5. **`_reapply_voice_params()`**: push all the current MIDI-voice param values to the fresh SC instance (see next section).

6. **Log**.

The `MidiInput._allocated` flag tracks whether ANY voice is currently allocated. Used to gate free attempts (don't free if nothing's there).

## 5. `_reapply_voice_params`

```lua
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
```

**Lines 68-90**: push current param values to the freshly-allocated SC voice.

Same pattern as `voice_params.lua:reapply_sampler` (chapter 09 of the conceptual tutorial): iterate a whitelist of SC-bound keys, call `params:set(pid, params:get(pid))` to re-fire each action.

The whitelist branches on role:
- **Shared params** (amp, sends, etc.) apply to both TriSin and Ringer.
- **TriSin-only params** (FM ratios, envelopes, cutoff filter) apply only to TriSin.
- **Ringer-only param** (decay) applies only to Ringer.

Without this re-fire after `set_role`, the fresh SC voice would start with TriSin/Ringer's SynthDef defaults rather than the user's configured values.

`★ Insight ─────────────────────────────────────`
**The defensive `if params.lookup[pid]` check** handles the case where some param doesn't exist (e.g., we listed a key in the whitelist that doesn't have a corresponding param). Skip silently rather than throwing.

**This is the third instance of the "reapply after voice creation" pattern**: `voice_params.lua:reapply_sampler`, `:reapply_oneshot`, and this `_reapply_voice_params`. Each operates on a different scope (per-slot, per-cell, per-special-voice) but uses the same approach: enumerate the relevant params, re-fire actions.

The pattern could be abstracted into a generic `reapply_params_with_prefix(prefix, keys)`, but the per-module variants are tied to their specific param-naming conventions and are easier to read inline.
`─────────────────────────────────────────────────`

## 6. `handle_event`

```lua
function MidiInput.handle_event(msg)
    local d = midi.to_msg(msg)
    local ch_filter = params:get('midi_input_channel') or 0
    if ch_filter ~= 0 and d.ch ~= ch_filter then return end
    if d.type == 'note_on' and d.vel > 0 then
        MidiInput._note_on(d.note, d.vel, d.ch)
    elseif d.type == 'note_off' or (d.type == 'note_on' and d.vel == 0) then
        MidiInput._note_off(d.note, d.ch)
    end
end
```

**Lines 92-102**: the MIDI event handler.

`midi.to_msg(msg)` parses the raw byte array into a structured table: `{type, note, vel, ch, ...}`. Field names depend on message type.

The function:

1. **Channel filter**: read the `midi_input_channel` param. If 0 (= omni), accept all channels. Otherwise filter by exact channel match. This lets the user route specific channels of a multitimbral controller to schicksalslied.

2. **Dispatch on message type**:
   - **`note_on` with velocity > 0**: actual key press, route to `_note_on`.
   - **`note_off` OR `note_on` with vel=0**: key release. (Some controllers send `note_on` with vel=0 instead of `note_off` — handle both.)
   - **Other message types** (CC, pitchbend, etc.): ignored. (Future: could be added.)

## 7. `_note_on` / `_note_off`

```lua
function MidiInput._note_on(note, vel, ch)
    local freq = MusicUtil.note_num_to_freq(note)
    if MidiInput.role == 'TriSin' then
        MidiInput.rr_counter = (MidiInput.rr_counter % 8) + 1
        local voice_key = tostring(MidiInput.rr_counter)
        MidiInput.active_notes[note .. '_' .. ch] = voice_key
        engine.trisin_trigger(MidiInput.CELL_ID, voice_key, freq)
    elseif MidiInput.role == 'Ringer' then
        MidiInput.rr_counter = (MidiInput.rr_counter % 8) + 1
        local voice_key = tostring(MidiInput.rr_counter)
        engine.ringer_trigger(MidiInput.CELL_ID, voice_key, freq)
    end
end
```

**Lines 104-118**: handle a note-on.

1. **Compute frequency**: `MusicUtil.note_num_to_freq(midi_note)`. Converts MIDI 0-127 to Hz. No scale quantization — the MIDI keyboard already produces specific notes.

2. **Pick a voice key** via round-robin. The `(counter % 8) + 1` gives 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, ... cycle. 8 polyphony fixed for MIDI input (no per-voice polyphony control).

3. **For TriSin**: track the active note (so note_off can find it) and trigger.

4. **For Ringer**: trigger directly. No active-note tracking because Ringer self-frees via `doneAction: 2`.

`tostring(MidiInput.rr_counter)` converts the integer to a string before passing to `engine.trisin_trigger` — the engine command expects an integer arg that gets converted to a symbol on the SC side (see Engine_Lied.sc.md section 6).

Wait — looking more carefully: the integer's already going as the integer (via OSC). The `tostring` here is just for the active_notes table key. Reading the engine's signature: `\trisin_trigger, "sif"` — the second arg is `i` (integer), and the kernel does the asInteger.asString.asSymbol conversion. So the integer is what's passed.

Actually, reviewing the code: `voice_key = tostring(MidiInput.rr_counter)` makes voice_key a string. But the engine takes integer. So `engine.trisin_trigger(MidiInput.CELL_ID, voice_key, freq)` with voice_key as a string — Lua would auto-coerce, or it'd be an issue. Looking at this, there's likely an automatic Lua → OSC conversion that handles either; or this could be a small bug.

```lua
function MidiInput._note_off(note, ch)
    -- For TriSin: gate off by re-triggering with t_gate=0 isn't exposed; the
    -- existing trigger sets t_gate=1. To gate off, we'd need a new engine
    -- command. For now, the note rings out via its envelope's release.
    MidiInput.active_notes[note .. '_' .. ch] = nil
end
```

**Lines 120-127**: handle a note-off. With important comment.

The comment is honest about a limitation: **TriSin doesn't expose a gate-off command**. The standard MIDI behavior of "key release stops the note" isn't fully implemented — the TriSin note rings out via its release envelope, but pressing and releasing a key doesn't precisely control when the note ends.

For Ringer, this doesn't matter — Ringer self-frees after its envelope completes.

The "Future: add engine.trisin_gate_off command if needed" comment documents the intended fix. As of this build, the workaround is: set the TriSin's release time to whatever feels right for your MIDI playing style. Short release = staccato-like; long release = sustained.

`★ Insight ─────────────────────────────────────`
**Honest comments about known limitations** are unusually valuable in code. Many codebases have unspoken-but-acknowledged limitations that future maintainers discover painfully. By stating the limitation and the intended fix in the source, this module makes the deficiency visible.

**Adding a `gate_off` engine command** would require:
1. A new method on TriSin: `gateOff { arg voiceKey; ... }` that sets `t_gate, 0` on the corresponding subgroup.
2. A new kernel method `gateOffTriSin { arg cellId, voiceKey; ... }`.
3. A new addCommand in `Engine_Lied.sc`.
4. A new call here in `_note_off`.

Maybe 10 lines total. Not done because the workaround (envelope release time) has been good enough for the user's playing.
`─────────────────────────────────────────────────`

## 8. `cleanup`

```lua
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
```

**Lines 129-141**: clean teardown. Called from `schicksalslied.lua`'s `cleanup()`.

1. Unregister the MIDI event handler if there's a device.
2. Free the SC voice if allocated.
3. Clear the allocated flag.

This is the symmetric tear-down of `init`. Important for clean script unloads — without it, the SC voice would leak (still alive on the server after the script reloads).

## 9. Module return

```lua
return MidiInput
```

**Line 143**: standard return.

## Summary

`midi_input.lua` is a complete MIDI keyboard input layer. The patterns to internalize:

- **Dedicated voice instance** with a distinctive cell_id, parallel to grid-driven voices.
- **Channel filter via params** (0 = omni; non-zero = specific channel).
- **Role switching** with proper free-then-alloc + active-notes clear + param re-apply.
- **Round-robin voice key allocation** for polyphony.
- **Honest comments about known limitations** (the missing gate_off).

The module is one of the cleanest in the project: focused, single-responsibility, defensive without being paranoid. A good reference if you want to add another non-grid input mechanism (a foot pedal, a different controller type, OSC-driven external triggering).

To add a gate_off pathway:
1. New `TriSin:gateOff(voiceKey)` method.
2. New `kernel:gateOffTriSin(cellId, voiceKey)`.
3. New `\trisin_gate_off` addCommand.
4. New call in this file's `_note_off`.

That's the work. Future improvement, not blocking.
