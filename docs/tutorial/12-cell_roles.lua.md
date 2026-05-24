# Chapter 12 — `lib/cell_roles.lua`

The role registry + dispatch table + lazy SC voice allocation. **346 source lines.** By the end of this chapter the chain from clock fire → role lookup → engine OSC call → audio is complete on the Lua side. The script can play sound.

Chapter 11 ended with the sequencer firing `dispatch_fn(x, y)` 64 times per beat (more if there are fast cells). This chapter builds the `dispatch_fn` that gets called: a role enum (11 voice roles you can assign to a row-2 cell), a per-cell dispatch table mapping each role string to its byte-to-musical-value handler, the lazy SC voice allocation pattern (`ensure_allocated`), round-robin polyphony tracking, and the dispatch flow for sampler trigger/rate cells and one-shot cells.

## Header and imports

```lua
-- lib/cell_roles.lua — schicksalslied 2.0 role dispatch + lazy allocation
-- Owns: role enum, dispatch table, lazy alloc of SC voice instances per cell

local MusicUtil = require 'musicutil'
local Looper = include 'lib/wtape_looper'
local Midi = include 'lib/midi_role'
local Roles = {}
```

**Lines 1-7**: file header and three imports.

- **`MusicUtil`** — Norns's music-theory library. Used for `note_num_to_freq` and the scale-snapping functions.
- **`Looper`** — the w/tape looper choreography (`lib/wtape_looper.lua`). The `w/tape looper` role dispatcher delegates here.
- **`Midi`** — the MIDI-out role (`lib/midi_role.lua`). The `MIDI` role dispatcher delegates here.

The `Roles = {}` module table starts empty; subsequent code populates it.

## Pitch quantization

```lua
function Roles.quantize_note(midi_note)
    local scale_idx = params:get('scale_mode')
    if scale_idx == nil or scale_idx == 1 then
        return midi_note  -- chromatic / pre-params-init = no quantization
    end
    local root = (params:get('root_note') or 1) - 1
    local scale = MusicUtil.generate_scale_of_length(root,
        MusicUtil.SCALES[scale_idx - 1].name, 128)
    return MusicUtil.snap_note_to_array(midi_note, scale)
end
```

**Lines 18-28**: pitch quantization. Every pitched role calls this after computing the raw byte-derived MIDI note.

1. **Read `scale_mode`**: option-type param. Index 1 = chromatic (no quantization); higher indices map to entries in `MusicUtil.SCALES`.
2. **Early return** for chromatic mode or pre-init nil. The function returns the input unchanged — full chromatic byte mapping preserved.
3. **Read `root_note`**: 1-based 1..12 (C..B). Convert to 0-based for MusicUtil.
4. **Build a 128-note scale**: `generate_scale_of_length(root, name, length)`. The `scale_idx - 1` accounts for the offset (option index 2 corresponds to `MusicUtil.SCALES[1]`).
5. **Snap**: `snap_note_to_array(note, scale)` finds the nearest note in the scale to the input MIDI note.

`★ Insight ─────────────────────────────────────`
**Why generate the scale on every call instead of caching?** Because scale and root can both change at runtime via params. Caching would require invalidation logic; the regeneration is fast (sub-millisecond for a 128-note scale).

**This is the script's only point where "byte → note" becomes "byte → scale-snapped note."** The byte math (`byte % 32 + 49`) produces an unquantized MIDI note; this function reshapes it. Same byte stream produces different musical material depending on scale.
`─────────────────────────────────────────────────`

## The 11 roles, the default per-column assignments

```lua
Roles.ENUM = {
    'TriSin', 'Ringer', 'crow 1+2', 'crow 3+4',
    'JF', 'JF run', 'JF quantize',
    'w/syn', 'w/del', 'w/tape looper', 'MIDI',
}

Roles.ROW_2_DEFAULTS = {
    'TriSin', 'TriSin', 'TriSin', 'TriSin',
    'Ringer', 'Ringer', 'Ringer', 'Ringer',
    'TriSin', 'TriSin', 'TriSin', 'TriSin',
    'Ringer', 'Ringer', 'Ringer', 'Ringer',
}

Roles.cell_role = {}

function Roles.init()
    for x = 1, 16 do
        Roles.cell_role[x] = Roles.ROW_2_DEFAULTS[x]
    end
end
```

**Lines 35-65**: the canonical role list, per-column defaults, and the per-cell role state.

`Roles.ENUM` is **the source of truth** for available roles. Order matters — the params menu uses these as option indices. Adding a new role means: append to ENUM + add a matching entry in `dispatch_row_2`.

`Roles.ROW_2_DEFAULTS` is the per-column default — alternating blocks of 4 TriSin / 4 Ringer. Mirrors the naherinlied default, gives the user a useful out-of-the-box setup.

`Roles.cell_role[x]` is the live state for column x's current role. Read by `Roles.dispatch` to look up the role; written by the `cell_X_2_role` param's action.

`Roles.init()` populates the cell_role table from defaults. Called from `schicksalslied.lua:init()`.

## The cell ID helper

```lua
function Roles.cell_id(x, y)
    return string.format("%d_%d", x, y)
end
```

**Lines 72-74**: format a cell coordinate as a string. Used as the key in SC voice instance dictionaries.

## Lazy SC voice allocation (`ensure_allocated`)

```lua
Roles.allocated = {}

function Roles.ensure_allocated(x, y)
    if y ~= 2 then return end
    local cell_id = Roles.cell_id(x, y)
    local role = Roles.cell_role[x]
    if Roles.allocated[cell_id] == role then return end
    if Roles.allocated[cell_id] then
        local prev = Roles.allocated[cell_id]
        if prev == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif prev == 'Ringer' then
            engine.ringer_free(cell_id)
        end
        Roles.allocated[cell_id] = nil
    end
    if role == 'TriSin' then
        engine.trisin_alloc(cell_id)
        Roles.allocated[cell_id] = role
    elseif role == 'Ringer' then
        engine.ringer_alloc(cell_id)
        Roles.allocated[cell_id] = role
    end
end
```

**Lines 89-116**: lazy SC voice allocation. Called at the top of every row-2 dispatcher.

The function is **idempotent** — calling it for an already-allocated cell does nothing. The logic:

1. **Row-2 only**: return immediately if not row 2. Samplers/one-shots have their own allocation flow.
2. **Already-correct case**: if the recorded allocation matches the current role, nothing to do.
3. **Role-changed case**: free the previous SC voice (if it was TriSin or Ringer). Clear the allocated entry.
4. **Allocate fresh** for the current role, recording the role string in `Roles.allocated`.

For crow / JF / w/* / MIDI roles, no SC instance is needed (those use crow/ii calls directly). The function intentionally has no `elseif` branches for them — falls through silently.

`Roles.allocated[cell_id]` serves as both the "is allocated?" flag AND the "allocated as what role?" record. One value, two purposes.

## Tearing down at cleanup (`free_all`)

```lua
function Roles.free_all()
    for cell_id, role in pairs(Roles.allocated) do
        if role == 'TriSin' then
            engine.trisin_free(cell_id)
        elseif role == 'Ringer' then
            engine.ringer_free(cell_id)
        end
    end
    Roles.allocated = {}
end
```

**Lines 119-128**: free every allocated SC voice. Called from `schicksalslied.lua:cleanup()`.

Iterate the allocated table, free each voice according to its role, then reset the table.

`★ Insight ─────────────────────────────────────`
**Symmetry between `ensure_allocated` and `free_all`**: same role string lookup, same engine commands, mirrored across alloc/free. This symmetry is what makes voice management reliable — every alloc has a matching free.

**Why not have `Roles.free_one(cell_id)` for symmetry with ensure_allocated?** Because the only consumer is `cleanup()`, which always frees everything. A per-cell free would invite use cases we haven't designed for (e.g., partial cleanup during a role-change). For role changes, `ensure_allocated` handles the free-then-alloc internally.
`─────────────────────────────────────────────────`

## Setting up the dispatch table

```lua
Roles.Sequencer = nil

Roles.rr_counter = {}
Roles.polyphony = {}

local function next_voice_key(cell_id, default_poly)
    local poly = Roles.polyphony[cell_id] or default_poly or 4
    Roles.rr_counter[cell_id] = ((Roles.rr_counter[cell_id] or 0) % poly) + 1
    return Roles.rr_counter[cell_id]
end

Roles.looper_running = {}
```

**Lines 138-153**: setup for the dispatch table.

- **`Roles.Sequencer = nil`**: a forward-reference. Set by `schicksalslied.lua:init()` to the canonical Sequencer module. Used by dispatchers to read `Roles.Sequencer.Seq[x][y]` and `Roles.Sequencer.get_value(...)`.
- **`Roles.rr_counter`** and **`Roles.polyphony`**: per-cell round-robin state. The dispatcher reads `rr_counter` to pick the next voice key; the user sets `polyphony` via params to control how many voice slots are cycled through.
- **`next_voice_key(cell_id, default_poly)`**: increment the cell's counter (mod polyphony) and return. `Roles.polyphony[cell_id] or default_poly or 4` — three-level fallback in case the polyphony param hasn't been set.
- **`Roles.looper_running`**: per-cell flag for w/tape looper re-entry guard.

## The 11 row-2 dispatchers

```lua
Roles.dispatch_row_2 = {
```

**Line 156**: open the dispatch table. The 11 role strings are keys; the functions are values.

### TriSin

```lua
    ['TriSin'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)
        local cell_id = Roles.cell_id(x, y)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local note = Roles.quantize_note(seq() % 32 + 49 + offset)
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.trisin_trigger(cell_id, voice_key, freq)
    end,
```

**Lines 158-166**: the TriSin dispatcher. Walk:

1. **Ensure the SC voice exists** (lazy alloc).
2. **Build the cell_id** string.
3. **Read the pitch offset** param (default 0).
4. **Read one byte, compute MIDI note**: `byte % 32 + 49 + offset`. The `% 32` makes 'A' (65) and 'a' (97) both map to 1; the `+ 49` shifts to musical range (50-81 ish).
5. **Quantize** to the global scale.
6. **Convert** MIDI to Hz.
7. **Pick a voice key** via round-robin (default polyphony 4).
8. **Fire**.

### Ringer

```lua
    ['Ringer'] = function(x, y, seq)
        Roles.ensure_allocated(x, y)
        local cell_id = Roles.cell_id(x, y)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local note = Roles.quantize_note(seq() % 32 + 49 + offset)
        local freq = MusicUtil.note_num_to_freq(note)
        local voice_key = next_voice_key(cell_id, 4)
        engine.ringer_trigger(cell_id, voice_key, freq)
    end,
```

**Lines 168-176**: identical to TriSin except for the engine command name. Same byte math, same quantization, same polyphony.

### Crow 1+2

```lua
    ['crow 1+2'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.output[1].volts = pitch_note / 12
        crow.output[1].slew = (seq() % 32 + 1) / 300
        crow.output[2].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[2].dyn.release = (seq() % 32 + 1) / 40
        crow.output[2]()
    end,
```

**Lines 178-187**: crow 1+2 consumes 4 bytes per fire.

- **`seq() % 32 + 1`**: shifts byte 0-31 to 1-32. Different scale from TriSin (`+ 49`) because crow uses volts, not MIDI notes. The math produces a smaller range better suited to v/oct CV (1-32 covers ~2.67 octaves at 1 V/oct).
- **`crow.output[1].volts = pitch_note / 12`** — divide by 12 because 1 V/oct = 12 semitones. So MIDI note 24 → 2 V (octave 1 above C0 = MIDI 12 = 1 V).
- **`crow.output[1].slew = byte / 300`** — slew time in seconds. Range 0.0033 to 0.42 sec.
- **`crow.output[2].dyn.attack = byte / 40`** — attack time. Range 0.025 to 3.175 sec.
- **`crow.output[2].dyn.release`** — release time, same range.
- **`crow.output[2]()`** — trigger the envelope on output 2. (The trailing parens are crow's syntax for "fire this output's envelope.")

### Crow 3+4

```lua
    ['crow 3+4'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.output[3].volts = pitch_note / 12
        crow.output[3].slew = (seq() % 32 + 1) / 300
        crow.output[4].dyn.attack = (seq() % 32 + 1) / 40
        crow.output[4].dyn.release = (seq() % 32 + 1) / 40
        crow.output[4]()
    end,
```

**Lines 189-197**: identical to crow 1+2 but on outputs 3 and 4.

`★ Insight ─────────────────────────────────────`
**Two crow roles let you run two independent crow voices** off two separate cells. Cell A on `crow 1+2` drives outputs 1 (pitch CV) + 2 (gate+env). Cell B on `crow 3+4` drives outputs 3 + 4. Different texts → different sequences on each crow pair.

**`crow.output[N]()` is the trigger syntax** — calling the output as a function fires its envelope. This is distinct from `crow.output[N].volts = X` (which sets a CV value) or `crow.output[N].dyn.attack = X` (which sets envelope params).
`─────────────────────────────────────────────────`

### JF (synthesis mode)

```lua
    ['JF'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        local level = seq() % 5 + 1
        crow.ii.jf.play_note(pitch_note / 12, level)
    end,
```

**Lines 199-204**: Just Friends in synthesis mode. 2 bytes per fire.

- **`pitch_note / 12`** — v/oct pitch.
- **`level = seq() % 5 + 1`** — amplitude 1-5. (JF's `play_note` takes a 1-5 level.)
- **`crow.ii.jf.play_note(volts, level)`** — fires a note on JF via ii.

### JF run

```lua
    ['JF run'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.jf.run(pitch_note / 12)
    end,
```

**Lines 206-210**: JF's RUN input via ii. 1 byte per fire.

`crow.ii.jf.run(voltage)` is the virtual-voltage-to-RUN-jack command. The voltage modulates JF's RUN-input parameter (gestalt, oscillator pitch in synthesis mode, etc.).

### JF quantize

```lua
    ['JF quantize'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.jf.quantize(pitch_note / 12)
    end,
```

**Lines 212-216**: JF's quantize command. 1 byte per fire.

`crow.ii.jf.quantize(voltage)` sets JF's internal quantizer (geode mode) to snap to the given voltage's note class. Lets the user dynamically reshape JF's quantization grid in time with the cell's text.

### w/syn

```lua
    ['w/syn'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        local level = seq() % 5 + 1
        crow.ii.wsyn.play_note(pitch_note / 12, level)
    end,
```

**Lines 218-223**: w/syn synthesizer. 2 bytes per fire (pitch + level). Same pattern as JF.

### w/del

```lua
    ['w/del'] = function(x, y, seq)
        local offset = params:get('cell_' .. x .. '_2_pitch_offset') or 0
        local pitch_note = Roles.quantize_note(seq() % 32 + 1 + offset)
        crow.ii.wdel.time(0)
        crow.ii.wdel.freq(pitch_note / 12)
        crow.ii.wdel.pluck(seq() % 5 + 1)
    end,
```

**Lines 225-231**: w/del karplus-strong mode. 2 bytes per fire (pitch + pluck level).

- **`wdel.time(0)`** — zero the delay time. With time = 0, the delay's internal feedback loop becomes a karplus-strong string synthesizer.
- **`wdel.freq(pitch_note / 12)`** — set the loop frequency (= the synthesized note's pitch).
- **`wdel.pluck(level)`** — trigger the pluck at the given level (1-5).

### w/tape looper

```lua
    ['w/tape looper'] = function(x, y, seq)
        local cell_id = Roles.cell_id(x, y)
        if Roles.looper_running[cell_id] then return end
        Roles.looper_running[cell_id] = true
        clock.run(function()
            Looper.run(seq)
            Roles.looper_running[cell_id] = false
        end)
    end,
```

**Lines 233-241**: w/tape looper with re-entry guard.

1. **Re-entry guard**: if a looper coroutine is already running for this cell, do nothing. Without the guard, fast retriggers would stack overlapping coroutines, all fighting for w/tape ii bandwidth.
2. **Set the flag** before spawning. Then spawn a coroutine via `clock.run`.
3. **Inside the coroutine**: call `Looper.run(seq)` (the choreography in wtape_looper.lua). When it finishes, clear the flag.

The looper's Looper.run consumes many bytes and takes many beats. The guard ensures only one looper per cell runs at a time.

### MIDI

```lua
    ['MIDI'] = function(x, y, seq)
        Midi.dispatch(x, y, seq)
    end,
}
```

**Lines 243-246**: simple delegation to `midi_role.dispatch`. The MIDI module handles its own state (active notes, channel routing, etc.).

## Sampler trigger + rate dispatchers

```lua
local function sampler_slot_for(x, y)
    local base = (y == 4) and 0 or 8
    return base + (math.floor(x / 2) + 1)
end
```

**Lines 250-253**: compute the sampler slot for a (col, row) coordinate.

- Row 4: base 0. Trigger cells are at odd cols 1, 3, 5, ..., 15 → slots 1-8.
- Row 6: base 8. Trigger cells at odd cols → slots 9-16.

The formula `base + (math.floor(x / 2) + 1)`:
- For col 1: `floor(1/2) + 1 = 1`. base + 1 = 1 (row 4) or 9 (row 6).
- For col 3: `floor(3/2) + 1 = 2`. → slot 2 or 10.
- Etc.

```lua
local function dispatch_sampler_trigger(x, y, seq)
    local slot = sampler_slot_for(x, y)
    local cell_id = Roles.cell_id(x, y)
    local poly = Roles.polyphony[cell_id] or 1
    local voice_key = next_voice_key(cell_id, poly)
    local pos_value = Roles.Sequencer.get_value(x, y, 'position')
    local dur_value = Roles.Sequencer.get_value(x, y, 'duration')
    local start_pos, end_pos
    if pos_value == nil then
        start_pos = util.clamp(util.linlin(32, 126, 0, 0.9, seq()), 0, 0.9)
    else
        start_pos = pos_value
    end
    if dur_value == nil then
        end_pos = start_pos + util.clamp(util.linlin(32, 126, 0.001, 0.1, seq()), 0.001, 0.1)
    else
        end_pos = start_pos + dur_value
    end
    local rate_value = Roles.Sequencer.get_value(x + 1, y, 'rate')
    local rate
    if rate_value == nil then
        rate = 1
    else
        rate = rate_value
    end
    engine.sampler_trigger(slot, voice_key, start_pos, end_pos, rate)
end
```

**Lines 255-284**: sampler trigger dispatch.

1. **Compute slot, cell_id, voice key**.
2. **Read position value** from value_mode (defined in chapter 11). If nil (lied mode), derive from byte: `util.linlin(32, 126, 0, 0.9, seq())` maps a printable byte to a position in [0, 0.9].
3. **Read duration value**. If nil, derive from byte: `util.linlin(32, 126, 0.001, 0.1, seq())` maps to [0.001, 0.1] (a small slice).
4. **Compute end_pos** as start + duration. Capped via `util.clamp` to ensure validity.
5. **Read rate** from the PAIRED rate cell (at `x + 1, y` — the rate cell is the even col to the right). If nil (lied mode), use 1 (the dispatch_sampler_rate at every tick will set the actual rate; this is just the trigger's rate hint).
6. **Fire the engine command**.

```lua
local function dispatch_sampler_rate(x, y, seq)
    local slot = sampler_slot_for(x - 1, y)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        rate = seq() / 36
    else
        rate = rate_value
    end
    engine.sampler_set_param(slot, 'rate', rate)
end
```

**Lines 286-296**: sampler rate dispatch. Even-col cells in rows 4/6.

- **`sampler_slot_for(x - 1, y)`** — the paired trigger cell is one col to the LEFT (odd col).
- **Read rate from value_mode**. If nil, derive: `seq() / 36` produces ~0.89 to 3.5 for printable bytes — typical playback rate range.
- **`engine.sampler_set_param(slot, 'rate', rate)`** — DOES NOT trigger; just sets the slot's rate param. The next trigger from the trigger cell will pick up this rate.

## The one-shot dispatcher

```lua
local function dispatch_oneshot_trigger(x, y, seq)
    local slot = x
    local cell_id = Roles.cell_id(x, y)
    local voice_key = next_voice_key(cell_id, 1)
    local rate_value = Roles.Sequencer.get_value(x, y, 'rate')
    local rate
    if rate_value == nil then
        rate = seq() / 36
    else
        rate = rate_value
    end
    engine.oneshot_trigger(slot, voice_key, rate)
end
```

**Lines 301-313**: one-shot trigger. Simpler than sampler:

- **`slot = x`**: one-shots are in row 8 cols 1-13, slot directly maps to col.
- **Default polyphony 1**: one-shots typically don't need polyphony (percussive samples).
- **Read rate or derive from byte**.
- **Fire**.

No position/duration — one-shots play the whole buffer through.

## Top-level dispatch: row-based routing

```lua
function Roles.dispatch(x, y)
    local seq = Roles.Sequencer.Seq[x][y]
    local seq_fn = function() return seq() end

    if y == 2 then
        local role = Roles.cell_role[x]
        local fn = Roles.dispatch_row_2[role]
        if fn then fn(x, y, seq_fn) end
    elseif y == 4 or y == 6 then
        if x % 2 == 1 then
            dispatch_sampler_trigger(x, y, seq_fn)
        else
            dispatch_sampler_rate(x, y, seq_fn)
        end
    elseif y == 8 then
        if x <= 13 then
            dispatch_oneshot_trigger(x, y, seq_fn)
        end
    end
end
```

**Lines 322-345**: the entry point. Called by `Sequencer.dispatch_fn(x, y)` on every fire.

1. **Get the Sequins** for this cell.
2. **Wrap into `seq_fn = function() return seq() end`**: a callable that returns the next byte. Passing this to dispatchers makes the API cleaner — dispatchers don't need to know about the Sequins object.
3. **Row-based dispatch**:
   - Row 2: look up role, dispatch to row_2 table.
   - Row 4/6: odd col → trigger; even col → rate.
   - Row 8 cols 1-13: one-shot trigger.
4. **Row 8 cols 14-16**: no-op (mic/granular toggles handled by their state-param actions).

## Summary

`cell_roles.lua` is the dispatch layer. Three roles for the file:

- **The canonical role registry** (`Roles.ENUM`, `Roles.ROW_2_DEFAULTS`).
- **Lazy SC voice allocation** for TriSin/Ringer cells.
- **The dispatch table** mapping role strings to byte→musical-value functions.

To add a new row-2 role:

1. Append the role string to `Roles.ENUM`.
2. Add a matching entry in `Roles.dispatch_row_2`.
3. Update `voice_params.lua:ROLE_NAMES` to match.
4. Update `_update_row2_visibility` to handle the new role's param visibility.
5. If the role needs an SC voice, extend `ensure_allocated`'s alloc + free branches.

Adding a new role at the byte→musical level is straightforward; the rest of the system just sees a new string in the role enum and renders the corresponding params menu entry.
