---schicksalslied 2.0
---
---a poetry sequencer
---
---type to enter text, ENTER to stage,
---grid row 3/5/7 press to assign,
---grid row 2/4/6/8 toggle to fire.
---
---K1: (unused)       E1: scroll history
---K2: append history E2: global amp
---K3: enter          E3: bpm
---
---version 2.0.0

engine.name = 'Lied'

local Sequencer  = include 'lib/sequencer'
local Roles      = include 'lib/cell_roles'
local MusicUtil  = require 'musicutil'
local Midi       = include 'lib/midi_role'
local Grain      = include 'lib/grid_grain_params'

-- ========================================================================
-- MODULE-LEVEL LOCALS — text input + history
-- ========================================================================
local displayed_string = ""    -- live typing buffer
local my_string        = ""    -- staged line, set by ENTER and row-1 release
local history          = {}    -- typed + file-loaded lines, indexed 1..N
local history_index    = 0
local new_line         = false
local needs_restart    = false -- legacy from 1.x's FormantTriPTR install; always false in 2.0

-- ========================================================================
-- GRID + SCREEN
-- ========================================================================
local g = grid.connect()

-- Metro handles — declared here so both init() and cleanup() can see them.
local screen_metro, grid_metro, fire_decay_metro


-- grid_dirty stays a global (sequencer.lua's toggle_pause writes to it)
grid_dirty = true

-- Hotplug handlers — fire when a grid is connected/disconnected at runtime.
-- Without grid.add, if the user plugs in a grid AFTER script init, the LEDs
-- stay dark until the first grid press (which sets grid_dirty via g.key).
grid.add = function(dev)
    g = grid.connect()
    grid_dirty = true
    print('grid connected: ' .. (dev.name or 'unknown'))
end

grid.remove = function(dev)
    print('grid disconnected: ' .. (dev.name or 'unknown'))
end

-- ========================================================================
-- CROW INIT FUNCTION
-- ========================================================================
local function crow_reinit()
    crow.input[1].mode('clock')
    crow.ii.pullup(true)
    crow.ii.jf.mode(1)
    crow.ii.jf.run_mode(1)
    crow.ii.jf.tick(clock.get_tempo())
    crow.ii.wtape.timestamp(1)
    crow.ii.wtape.freq(0)
    crow.ii.wtape.play(0)
    crow.ii.wdel.mod_rate(0)
    crow.ii.wdel.mod_amount(0)
    crow.ii.wsyn.ar_mode(1)
    crow.ii.wsyn.voices(params:get('wsyn_voices') or 4)
    crow.ii.wsyn.patch(1, 1)
    crow.ii.wsyn.patch(2, 2)
    -- AR envelope action shape for crow outputs 2 and 4 (used by
    -- 'crow 1+2' and 'crow 3+4' role dispatchers); per-cell only
    -- updates the dyn.* variables, not the action string.
    crow.output[2].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
    crow.output[4].action = "{to(5,dyn{attack=1}), to(0,dyn{release=1})}"
    print('crow re-initialized')
end

-- ========================================================================
-- HISTORY + TEXT FILE LOADING
-- ========================================================================
local function load_text_file(path)
    if path == nil or path == '' or path == '-' then return end
    io.input(path)
    for line in io.lines() do
        if #line > 0 then
            table.insert(history, line)
        end
    end
    grid_dirty = true
    redraw()
end

-- ========================================================================
-- KEYBOARD HANDLER (spec §11 — two-variable text input model)
-- ========================================================================

keyboard.char = function(character)
    if #displayed_string < 200 then
        displayed_string = displayed_string .. character
    end
end

keyboard.code = function(code, val)
    if val == 0 then return end
    if code == 'BACKSPACE' then
        displayed_string = displayed_string:sub(1, -2)
    elseif code == 'UP' then
        if #history == 0 then return end
        if new_line then
            history_index = #history - 1
            new_line = false
        else
            history_index = util.clamp(history_index - 1, 0, #history)
        end
        displayed_string = history[history_index + 1] or ""
    elseif code == 'DOWN' then
        if #history == 0 or history_index == nil then return end
        history_index = util.clamp(history_index + 1, 0, #history)
        if history_index == #history then
            displayed_string = ""
            new_line = true
        else
            displayed_string = history[history_index + 1] or ""
        end
    elseif code == 'ENTER' and #displayed_string > 0 then
        -- ENTER promotes displayed_string to my_string, adds to history,
        -- clears displayed_string (per spec §7 text input flow)
        my_string = displayed_string
        table.insert(history, displayed_string)
        displayed_string = ""
        history_index = #history
        new_line = true
        grid_dirty = true
    elseif keyboard.ctrl() then
        -- Ctrl chord: remove last history entry, clear displayed_string
        table.remove(history, #history)
        history_index = #history
        displayed_string = ""
        grid_dirty = true
    end
end

-- ========================================================================
-- GRID HANDLER (spec §3 + §11)
-- ========================================================================

g.key = function(x, y, z)
    Sequencer.Momentary[x][y] = (z == 1)
    grid_dirty = true

    if y == 1 then
        -- History row
        if x + 16 * (y - 1) > #history then return end
        if z == 1 then
            -- Press: append history[x + 16*(y-1)] to displayed_string
            my_string = displayed_string .. history[x + 16 * (y - 1)]
            displayed_string = my_string
        else
            -- Release: check if any other row-1 buttons are still held
            local any_held = false
            for col = 1, 16 do
                if Sequencer.Momentary[col][1] then any_held = true; break end
            end
            if any_held then return end
            -- All released — set my_string from current displayed_string
            if #displayed_string > 0 then
                my_string = displayed_string
            end
            displayed_string = ""
            new_line = true
        end

    elseif y == 2 or y == 4 or y == 6 or y == 8 then
        -- Toggle row
        if z == 1 then
            -- Row 8 cols 14-16: special on/off for mic/granular amps
            if y == 8 and x >= 14 and x <= 16 then
                Sequencer.Toggled[x][y] = not Sequencer.Toggled[x][y]
                local on_value
                local set_fn
                if x == 14 then
                    on_value = params:get('mic_to_delay_amp')
                    set_fn = function(v) engine.set_mic_amp(v) end
                elseif x == 15 then
                    on_value = params:get('granular_out_amp')
                    set_fn = function(v) engine.set_granular_out_amp(v) end
                else  -- x == 16
                    on_value = params:get('mic_dry_amp')
                    set_fn = function(v) engine.set_mic_dry_amp(v) end
                end
                set_fn(Sequencer.Toggled[x][y] and on_value or 0)
            else
                -- Regular sequencer toggle
                Sequencer.Toggled[x][y] = not Sequencer.Toggled[x][y]
                if y == 2 and Sequencer.Toggled[x][y] then
                    Roles.ensure_allocated(x, y)
                end
            end
        end

    elseif y == 3 or y == 5 or y == 7 then
        -- Assign row: press assigns my_string to the cell at (x, y-1)
        if z == 1 then
            if #my_string > 0 then
                Sequencer.assign(x, y - 1, my_string)
            end
        end
    end
end

-- ========================================================================
-- GRID LED RENDERING (spec §11 brightness table)
-- ========================================================================

function grid_redraw()
    if g == nil then return end  -- no grid connected
    g:all(0)
    -- Row 1: history slots. 0 if empty, 4 if filled, 15 if held
    for x = 1, 16 do
        local idx = x  -- slot index = col for row 1
        if idx <= #history then
            g:led(x, 1, 4)
        end
        if Sequencer.Momentary[x][1] then
            g:led(x, 1, 15)
        end
    end
    -- Rows 2/4/6/8 (toggle rows): 0 idle, 15 toggled-on, 15 held.
    -- When Paused, toggled-on dims to 6.
    for x = 1, 16 do
        for y = 2, 8, 2 do
            if Sequencer.Toggled[x][y] then
                local level = Sequencer.Paused and 6 or 15
                g:led(x, y, level)
            end
            if Sequencer.Momentary[x][y] then
                g:led(x, y, 15)
            end
        end
    end
    -- Rows 3/5/7 (momentary): 4 idle, 15 held
    for x = 1, 16 do
        for y = 3, 7, 2 do
            g:led(x, y, 4)
            if Sequencer.Momentary[x][y] then
                g:led(x, y, 15)
            end
        end
    end
    g:refresh()
end

-- ========================================================================
-- SCREEN REDRAW (spec §11 two-string layout)
-- ========================================================================

function redraw()
    screen.clear()
    screen.aa(0)
    screen.line_width(1)
    screen.level(10)

    -- Input box at the bottom (y 50-64)
    screen.rect(2, 50, 125, 14)
    screen.stroke()
    screen.move(5, 59)
    screen.text("> " .. displayed_string)

    -- History items above (up to 4-5 lines, scrolling up).
    -- i == 1 is the line at history_index (selected by E1): draw brighter.
    for i = 1, 5 do
        if not (history_index - i >= 0) then break end
        screen.level(i == 1 and 15 or 4)
        screen.move(5, 55 - 10 * i)
        screen.text(history[history_index - i + 1] or "")
    end
    screen.level(10)  -- restore for input box

    screen.update()
end

-- ========================================================================
-- HARDWARE KEYS (K2 / K3 — K1 reserved for Norns system back/menu)
-- ========================================================================

local function panic()
    -- Clear all toggle state so the sequencer stops dispatching
    for x = 1, 16 do
        for y = 2, 8, 2 do
            Sequencer.Toggled[x][y] = false
        end
    end
    -- Free SC voice instances (will be re-allocated lazily when user re-toggles cells)
    Roles.free_all()
    -- Clear w/tape looper running flags
    Roles.looper_running = {}
    -- Silence the persistent granular delay chain + mic passthrough
    engine.set_mic_amp(0)
    engine.set_mic_dry_amp(0)
    engine.set_granular_out_amp(0)
    engine.set_fb_amp(0)
    -- Fully free the granular chain (frees ~50-70% baseline CPU; user must
    -- re-toggle row 8 col 14/15/16 to bring it back)
    engine.free_granular()
    -- Hard-stop in-flight sampler and one-shot playback
    engine.silence_all_samplers()
    engine.silence_all_oneshots()
    -- Stop crow / JF
    crow.ii.jf.run(0)
    -- Stop w/tape playback explicitly
    crow.ii.wtape.play(0)
    -- Zero crow CV outputs (1..4) to halt any in-flight envelope-driven CVs.
    -- AR envelopes already release naturally; this guarantees the final value.
    for n = 1, 4 do
        crow.output[n].volts = 0
    end
    -- MIDI: send all-notes-off via Midi's tracked active-note list.
    -- Cleaner than CC123 blast — only stops notes WE sent.
    Midi.all_notes_off()
    -- Note: w/syn and w/del don't expose direct silence verbs. Their voices
    -- decay naturally via internal envelopes. Clearing Toggled (above) is
    -- the main mitigation — no new triggers will reach them.
    -- Mark grid dirty so the LEDs reflect the now-cleared toggle state
    grid_dirty = true
    print('PANIC: silenced everything')
end

function key(n, z)
    if z == 0 then return end  -- act on press, not release
    -- K1 is intentionally unhandled — Norns's system-level hold-K1-to-exit
    -- behavior is preserved; short-press K1 does nothing in this script.

    if n == 2 then
        -- K2: append the currently-selected history line to displayed_string.
        -- Mirrors the row-1 grid press semantics. history_index is updated by E1.
        if #history > 0 and history_index >= 1 and history_index <= #history then
            my_string = displayed_string .. history[history_index]
            displayed_string = my_string
            grid_dirty = true
        end

    elseif n == 3 then
        -- K3: ENTER — promote displayed_string to my_string, add to history,
        -- clear displayed_string. Same as keyboard ENTER (spec §7 text input flow).
        if #displayed_string > 0 then
            my_string = displayed_string
            table.insert(history, displayed_string)
            displayed_string = ""
            history_index = #history
            new_line = true
            grid_dirty = true
        end
    end
end

function enc(n, d)
    if n == 1 then
        -- E1: scroll history index. Provides visual highlight via redraw.
        if #history == 0 then return end
        history_index = util.clamp(history_index + d, 0, #history)
        grid_dirty = true
        -- (does NOT modify displayed_string — K2 commits the selection)

    elseif n == 2 then
        -- E2: global amp
        params:delta('global_amp', d)

    elseif n == 3 then
        -- E3: BPM
        params:delta('clock_tempo', d)
    end
end

-- ========================================================================
-- GLOBAL RANDOMIZE
-- ========================================================================
-- Triggered by the global_randomize param. Iterates every cell + sampler +
-- one-shot + granular param and randomizes within reasonable bounds.
-- The per-family randomize functions are defined in lib/voice_params (added
-- in Sub-plan C Task 5.1). Until that module exists, this function calls
-- functions that don't yet exist — calling global_randomize will fail at
-- runtime until those tasks complete. (Wiring the param now keeps the menu
-- structure stable; the action callback gracefully fails until then.)
local function global_randomize()
    local ok, VoiceParams = pcall(require, 'lib/voice_params')
    if not ok then
        print('global_randomize: lib/voice_params not yet present, skipping')
        return
    end
    for x = 1, 16 do VoiceParams.randomize_row2_cell(x) end
    for slot = 1, 16 do VoiceParams.randomize_sampler(slot) end
    for slot = 1, 13 do VoiceParams.randomize_oneshot(slot) end
    VoiceParams.randomize_granular()
    print('GLOBAL RANDOMIZE: applied')
end

-- ========================================================================
-- PARAMS (Sub-plan C global group + full menu)
-- ========================================================================
local function add_params()
    params:add_separator('schicksalslied_top', 'SCHICKSALSLIED')

    -- ────────────────────────────────────────────────────────────────────
    -- GLOBAL GROUP (spec §9)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('global', 'global', 9)

    params:add{
        type = 'file',
        id = 'text_file',
        name = 'text file',
        action = load_text_file,
    }
    params:add{
        type = 'trigger',
        id = 'panic',
        name = 'panic',
        action = panic,
    }
    params:add{
        type = 'trigger',
        id = 'pause_resume',
        name = 'pause / resume',
        action = function() Sequencer.toggle_pause(); grid_dirty = true; end,
    }
    params:add{
        type = 'trigger',
        id = 'global_randomize',
        name = 'global randomize',
        action = function() global_randomize() end,
    }
    params:add{
        type = 'trigger',
        id = 'reset_all_seq_modes',
        name = 'reset all seq modes',
        action = function() Sequencer.reset_all_seq_modes_to_default() end,
    }
    -- Scale + root for quantizing pitched dispatchers (TriSin, Ringer, crow,
    -- JF, w/syn, w/del, MIDI). Default = chromatic + C = no quantization,
    -- matching schicksalslied 1.x's historical behavior. Built dynamically
    -- from MusicUtil.SCALES; index 1 is the special 'chromatic' (pass-through).
    -- The Roles.quantize_note helper lands in Task 2.4.
    params:add{
        type = 'option',
        id = 'scale_mode',
        name = 'scale',
        options = (function()
            local list = { 'chromatic' }
            for i = 1, #MusicUtil.SCALES do
                table.insert(list, MusicUtil.SCALES[i].name)
            end
            return list
        end)(),
        default = 1,
    }
    params:add{
        type = 'option',
        id = 'root_note',
        name = 'root note',
        options = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' },
        default = 1,
    }
    params:add{
        type = 'control',
        id = 'global_amp',
        name = 'global amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) engine.set_out_amp(v) end,
    }
    params:add{
        type = 'trigger',
        id = 'reset_all_value_modes_to_lied',
        name = 'reset all value modes to lied',
        action = function()
            -- Set every value_kind's mode to 1 (lied)
            for y = 4, 6, 2 do
                for x = 1, 15, 2 do
                    params:set(string.format('cell_%d_%d_position_mode', x, y), 1)
                    params:set(string.format('cell_%d_%d_duration_mode', x, y), 1)
                end
                for x = 2, 16, 2 do
                    params:set(string.format('cell_%d_%d_rate_mode', x, y), 1)
                end
            end
            for x = 1, 13 do
                params:set(string.format('cell_%d_8_rate_mode', x), 1)
            end
        end,
    }

    -- ────────────────────────────────────────────────────────────────────
    -- CROW GROUP (spec §8)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('crow', 'crow', 10)

    params:add{
        type = 'trigger',
        id = 'reinit_crow',
        name = 're-init crow modules',
        action = crow_reinit,
    }
    params:add{
        type = 'number',
        id = 'wsyn_voices',
        name = 'w/syn voices',
        min = 1, max = 4, default = 4,
        action = function(v) crow.ii.wsyn.voices(v) end,
    }
    params:add{
        type = 'control',
        id = 'wsyn_lpg_speed',
        name = 'w/syn lpg speed',
        controlspec = controlspec.new(-5, 5, 'lin', 0.01, 0, ''),
        action = function(v) crow.ii.wsyn.lpg_time(v) end,
    }
    params:add{
        type = 'control',
        id = 'wsyn_lpg_symmetry',
        name = 'w/syn lpg symmetry',
        controlspec = controlspec.new(-5, 5, 'lin', 0.01, 0, ''),
        action = function(v) crow.ii.wsyn.lpg_symmetry(v) end,
    }
    params:add{
        type = 'control',
        id = 'wsyn_fm_index',
        name = 'w/syn fm index',
        controlspec = controlspec.new(0, 5, 'lin', 0.01, 0, ''),
        action = function(v) crow.ii.wsyn.fm_index(v) end,
    }
    params:add{
        type = 'control',
        id = 'wsyn_fm_envelope',
        name = 'w/syn fm envelope',
        controlspec = controlspec.new(-5, 5, 'lin', 0.01, 0, ''),
        action = function(v) crow.ii.wsyn.fm_env(v) end,
    }
    params:add{
        type = 'number',
        id = 'wsyn_fm_num',
        name = 'w/syn fm num',
        min = 1, max = 16, default = 2,
        action = function(v)
            crow.ii.wsyn.fm_ratio(v, params:get('wsyn_fm_deno'))
        end,
    }
    params:add{
        type = 'number',
        id = 'wsyn_fm_deno',
        name = 'w/syn fm deno',
        min = 1, max = 16, default = 1,
        action = function(v)
            crow.ii.wsyn.fm_ratio(params:get('wsyn_fm_num'), v)
        end,
    }
    params:add{
        type = 'control',
        id = 'wdel_feedback',
        name = 'w/del feedback',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0, ''),
        action = function(v) crow.ii.wdel.feedback(v) end,
    }
    params:add{
        type = 'control',
        id = 'wdel_filter_cutoff',
        name = 'w/del filter cutoff',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 1, ''),
        action = function(v) crow.ii.wdel.filter(v) end,
    }

    -- ────────────────────────────────────────────────────────────────────
    -- MIDI GROUP (spec §3 — MIDI role; patterned on tehn/awake.lua)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('midi', 'midi', 3)

    -- Device list built dynamically from midi.vports — option indices match
    -- vport numbers, so params:get returns a value usable directly with
    -- midi.connect(n). Built ONCE at add_params time; if the user plugs in
    -- a new device after init, they must restart the script to see it
    -- in the option list (matches awake.lua's idiom; norns doesn't expose
    -- a vport-change callback).
    params:add{
        type = 'option',
        id = 'midi_device',
        name = 'midi out device',
        options = Midi.build_device_list(),
        default = 1,
        action = function(n)
            Midi.all_notes_off()  -- clean up before switching devices
            Midi.connect_device(n)
        end,
    }
    params:add{
        type = 'number',
        id = 'midi_default_channel',
        name = 'midi default channel',
        min = 1, max = 16, default = 1,
    }
    -- Global note-off delay (in seconds) for every MIDI cell. Awake uses
    -- clock-relative percentage; for schicksalslied where each cell has its
    -- own seq_mode-driven rate, an absolute-time gate is simpler than
    -- computing "percentage of next step" (which would require lookahead).
    params:add{
        type = 'control',
        id = 'midi_gate_time',
        name = 'midi gate time',
        controlspec = controlspec.new(0.01, 5, 'exp', 0.001, 0.1, 's'),
    }

    -- ────────────────────────────────────────────────────────────────────
    -- GRANULAR DELAY GROUP (spec §6)
    -- ────────────────────────────────────────────────────────────────────
    Grain.add_params()
    -- Master amps live in the granular_delay group too. Add them AFTER
    -- Grain.add_params() so they appear at the top of the group (under the
    -- 'master amps' separator that grid_grain_params.lua creates).
    params:add{
        type = 'control',
        id = 'mic_to_delay_amp',
        name = 'mic to delay amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
    }
    params:add{
        type = 'control',
        id = 'granular_out_amp',
        name = 'granular out amp',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0.3, ''),
    }
    params:add{
        type = 'control',
        id = 'mic_dry_amp',
        name = 'mic dry amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 0.5, ''),
    }

    -- ────────────────────────────────────────────────────────────────────
    -- MASTER FX GROUP — delay + reverb controls
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('master_fx', 'master fx', 7)

    params:add{
        type = 'option',
        id = 'delay_sync',
        name = 'delay sync',
        options = { 'free', '1/16', '1/8', '1/4', '1/2', '1', '2', '4' },
        default = 1,  -- 'free'
        action = function(idx)
            if idx == 1 then  -- free
                params:show('delay_time')
                engine.set_delay_time(params:get('delay_time'))
            else
                params:hide('delay_time')
                -- Map option idx 2..8 to beats {0.0625, 0.125, 0.25, 0.5, 1, 2, 4}
                local beats_for_idx = { 0.0625, 0.125, 0.25, 0.5, 1, 2, 4 }
                local beats = beats_for_idx[idx - 1]
                engine.set_delay_time(beats * clock.get_beat_sec())
            end
            _menu.rebuild_params()
        end,
    }
    params:add{
        type = 'control',
        id = 'delay_time',
        name = 'delay time',
        controlspec = controlspec.new(0.01, 2, 'lin', 0.01, 0.3, 's'),
        action = function(v)
            if params:get('delay_sync') == 1 then  -- only apply in free mode
                engine.set_delay_time(v)
            end
            -- in beat-sync modes, delay_sync's action is the authority
        end,
    }
    params:add{
        type = 'control',
        id = 'delay_decay',
        name = 'delay decay',
        controlspec = controlspec.new(0.01, 10, 'lin', 0.01, 0.5, 's'),
        action = function(v) engine.set_delay_decay(v) end,
    }
    params:add{
        type = 'control',
        id = 'delay_amp',
        name = 'delay amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) engine.set_delay_amp(v) end,
    }
    params:add{
        type = 'control',
        id = 'reverb_room',
        name = 'reverb room',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0.5, ''),
        action = function(v) engine.set_reverb_room(v) end,
    }
    params:add{
        type = 'control',
        id = 'reverb_damp',
        name = 'reverb damp',
        controlspec = controlspec.new(0, 1, 'lin', 0.01, 0.5, ''),
        action = function(v) engine.set_reverb_damp(v) end,
    }
    params:add{
        type = 'control',
        id = 'reverb_amp',
        name = 'reverb amp',
        controlspec = controlspec.new(0, 2, 'lin', 0.01, 1, ''),
        action = function(v) engine.set_reverb_amp(v) end,
    }

    -- ────────────────────────────────────────────────────────────────────
    -- ROW-2 CELLS GROUP (16 cells × 42 params + 1 separator/cell + 4 bulk = 692)
    -- Each cell: 1 separator + 1 role + 14 seq_mode + 7 shared + 16 TriSin + 1 Ringer + 1 MIDI + 1 randomize = 42
    -- shared: amp, amp_slew, pan, pan_slew, polyphony, bus_routing, granular_send
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('row_2_cells', 'synths', 16 * 43 + 4)
    do
        local VoiceParams = include 'lib/voice_params'
        for x = 1, 16 do
            params:add_separator('row_2_cell_' .. x .. '_separator', 'cell ' .. x)
            VoiceParams.add_row2_cell_block(x)
        end
        params:add{
            type = 'trigger',
            id = 'row_2_set_all_trisin',
            name = 'synths: all TriSin',
            action = function()
                for x = 1, 16 do params:set('cell_' .. x .. '_2_role', 1) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'row_2_set_all_ringer',
            name = 'synths: all Ringer',
            action = function()
                for x = 1, 16 do params:set('cell_' .. x .. '_2_role', 2) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'row_2_set_default_mix',
            name = 'synths: default mix',
            action = function()
                for x = 1, 16 do
                    params:set('cell_' .. x .. '_2_role',
                        VoiceParams._default_role_index(x))
                end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'row_2_randomize_roles',
            name = 'synths: randomize roles',
            action = function()
                for x = 1, 16 do
                    params:set('cell_' .. x .. '_2_role', math.random(1, 11))
                end
            end,
        }
    end

    -- ────────────────────────────────────────────────────────────────────
    -- LOOPING SAMPLERS GROUP
    -- Each slot: 1 separator + 1 file + 10 voice + 1 trigger-cell sep + 14 trigger seq_mode
    --            + 13 position value_mode + 13 duration value_mode
    --            + 1 rate-cell sep + 14 rate seq_mode + 13 rate value_mode = 81
    -- voice: amp, amp_slew, cutoff, resonance, pan, pan_slew, polyphony, bus_routing,
    --        granular_send, randomize = 10
    -- 16 slots × 81 + 4 bulk triggers = 1300
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('samplers', 'looping samplers', 16 * 81 + 4)
    do
        local VoiceParams = include 'lib/voice_params'
        for slot = 1, 16 do
            local trigger_col, trigger_row, rate_col, rate_row
            if slot <= 8 then
                trigger_col = (slot * 2) - 1
                trigger_row = 4
                rate_col    = slot * 2
                rate_row    = 4
            else
                trigger_col = ((slot - 8) * 2) - 1
                trigger_row = 6
                rate_col    = (slot - 8) * 2
                rate_row    = 6
            end

            params:add_separator('sampler_' .. slot .. '_separator', 'looping sampler ' .. slot)
            params:add{
                type = 'file',
                id = 'sampler_' .. slot .. '_file',
                name = 'looping sampler ' .. slot .. ' file',
                action = function(path)
                    if path == nil or path == '' or path == '-' then
                        engine.sampler_clear(slot)
                    else
                        engine.sampler_load(slot, path)
                    end
                end,
            }
            VoiceParams.add_sampler_block(slot)  -- 9 voice params

            params:add_separator(
                string.format('sampler_%d_trigger_cell_separator', slot),
                string.format('trigger cell (%d,%d)', trigger_col, trigger_row))
            VoiceParams.add_cell_seq_mode_block(trigger_col, trigger_row)         -- 14
            VoiceParams.add_cell_value_mode_block(trigger_col, trigger_row, 'position', 0, 0.9)   -- 13
            VoiceParams.add_cell_value_mode_block(trigger_col, trigger_row, 'duration', 0.001, 0.1) -- 13

            params:add_separator(
                string.format('sampler_%d_rate_cell_separator', slot),
                string.format('rate cell (%d,%d)', rate_col, rate_row))
            VoiceParams.add_cell_seq_mode_block(rate_col, rate_row)               -- 14
            VoiceParams.add_cell_value_mode_block(rate_col, rate_row, 'rate', -16, 16)            -- 13
        end

        -- 4 bulk triggers
        params:add{
            type = 'trigger',
            id = 'samplers_randomize_all',
            name = 'randomize all looping samplers',
            action = function()
                for slot = 1, 16 do VoiceParams.randomize_sampler(slot) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'randomize_all_sampler_positions',
            name = 'randomize all looping sampler positions',
            action = function()
                for y = 4, 6, 2 do
                    for x = 1, 15, 2 do
                        params:set(string.format('cell_%d_%d_position_fixed_value', x, y),
                            math.random())
                    end
                end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'randomize_all_sampler_durations',
            name = 'randomize all looping sampler durations',
            action = function()
                for y = 4, 6, 2 do
                    for x = 1, 15, 2 do
                        params:set(string.format('cell_%d_%d_duration_fixed_value', x, y),
                            0.001 + math.random() * 0.099)
                    end
                end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'randomize_all_sampler_rates',
            name = 'randomize all looping sampler rates',
            action = function()
                for y = 4, 6, 2 do
                    for x = 2, 16, 2 do
                        params:set(string.format('cell_%d_%d_rate_fixed_value', x, y),
                            -16 + math.random() * 32)
                    end
                end
            end,
        }
    end

    -- ────────────────────────────────────────────────────────────────────
    -- ONE-SHOT SAMPLERS GROUP
    -- Each slot: 1 separator + 1 file + 10 voice + 14 seq_mode + 13 rate value_mode = 39
    -- voice: amp, amp_slew, cutoff, resonance, pan, pan_slew, polyphony, bus_routing,
    --        granular_send, randomize = 10
    -- 13 slots × 39 + 2 bulk triggers = 509
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('one_shot_samplers', 'one-shot samplers', 13 * 39 + 2)
    do
        local VoiceParams = include 'lib/voice_params'
        for slot = 1, 13 do
            params:add_separator('oneshot_' .. slot .. '_separator', 'one-shot ' .. slot)
            params:add{
                type = 'file',
                id = 'oneshot_' .. slot .. '_file',
                name = 'one-shot ' .. slot .. ' file',
                action = function(path)
                    if path == nil or path == '' or path == '-' then
                        engine.oneshot_clear(slot)
                    else
                        engine.oneshot_load(slot, path)
                    end
                end,
            }
            VoiceParams.add_oneshot_block(slot)                               -- 9
            VoiceParams.add_cell_seq_mode_block(slot, 8)                      -- 14
            VoiceParams.add_cell_value_mode_block(slot, 8, 'rate', -16, 16)   -- 13
        end

        -- 2 bulk triggers
        params:add{
            type = 'trigger',
            id = 'oneshots_randomize_all',
            name = 'randomize all one-shots',
            action = function()
                for slot = 1, 13 do VoiceParams.randomize_oneshot(slot) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'randomize_all_oneshot_rates',
            name = 'randomize all one-shot rates',
            action = function()
                for x = 1, 13 do
                    params:set(string.format('cell_%d_8_rate_fixed_value', x),
                        -16 + math.random() * 32)
                end
            end,
        }
    end

    -- ────────────────────────────────────────────────────────────────────
    -- LFOs — 4 separate top-level groups (one per category) so Norns's UI
    -- doesn't freeze when scrolling through 4000+ entries in a single group.
    -- ────────────────────────────────────────────────────────────────────
    do
        local LiedLfos = include 'lib/lied_lfos'
        LiedLfos.add_row_2_lfos_group()
        LiedLfos.add_sampler_lfos_group()
        LiedLfos.add_oneshot_lfos_group()
        LiedLfos.add_crow_lfos_group()
    end

end

-- ========================================================================
-- INIT
-- ========================================================================
function init()
    Sequencer.init()
    Roles.init()
    Roles.Sequencer = Sequencer
    Sequencer.dispatch_fn = function(x, y) Roles.dispatch(x, y) end

    add_params()
    params:bang()

    -- Push initial beat_sec to SC, then re-push on every clock_tempo change.
    engine.set_beat_sec(clock.get_beat_sec())
    params:set_action('clock_tempo', function(bpm)
        engine.set_beat_sec(clock.get_beat_sec())
        -- if delay is beat-synced, re-fire delay_sync action so the seconds
        -- value pushed to SC reflects the new tempo
        if params.lookup['delay_sync'] ~= nil and params:get('delay_sync') ~= 1 then
            params:set('delay_sync', params:get('delay_sync'))  -- re-fires action
        end
    end)

    Midi.init()

    -- After params:bang, force-fire each cell role action so initial visibility
    -- is correct (params:bang fires actions but params:hide may not propagate
    -- to the menu redraw on first boot — explicitly re-setting each role does).
    for x = 1, 16 do
        local role_idx = params:get('cell_' .. x .. '_2_role')
        params:set('cell_' .. x .. '_2_role', role_idx)
    end

    -- Refresh seq_mode visibility for all sequencer-enabled cells.
    -- Row 8 cols 14-16 are mic/granular on/off toggles (NOT sequencer cells),
    -- so they have no seq_mode params — skip them.
    for y = 2, 8, 2 do
        local max_x = (y == 8) and 13 or 16
        for x = 1, max_x do
            local mode_idx = params:get('cell_' .. x .. '_' .. y .. '_seq_mode')
            params:set('cell_' .. x .. '_' .. y .. '_seq_mode', mode_idx)
        end
    end
    -- Refresh value_mode visibility (sampler trigger cells)
    for y = 4, 6, 2 do
        for x = 1, 15, 2 do
            for _, kind in ipairs({ 'position', 'duration' }) do
                local pid = 'cell_' .. x .. '_' .. y .. '_' .. kind .. '_mode'
                params:set(pid, params:get(pid))
            end
        end
        for x = 2, 16, 2 do
            local pid = 'cell_' .. x .. '_' .. y .. '_rate_mode'
            params:set(pid, params:get(pid))
        end
    end
    for x = 1, 13 do
        local pid = 'cell_' .. x .. '_8_rate_mode'
        params:set(pid, params:get(pid))
    end

    Sequencer.start_all_clocks()

    -- Screen redraw timer at 15fps
    screen_metro = metro.init()
    screen_metro.time = 1/15
    screen_metro.event = function() redraw() end
    screen_metro:start()

    -- Grid redraw timer at 30fps
    grid_metro = metro.init()
    grid_metro.time = 1/30
    grid_metro.event = function()
        if grid_dirty then
            grid_redraw()
            grid_dirty = false
        end
    end
    grid_metro:start()

    -- Fire-decay tick for LED flash on currently-firing cells (15fps)
    fire_decay_metro = metro.init()
    fire_decay_metro.time = 1/15
    fire_decay_metro.event = function()
        for x = 1, 16 do
            for y = 2, 8, 2 do
                if Sequencer.Fire_Decay[x][y] > 0 then
                    Sequencer.Fire_Decay[x][y] = Sequencer.Fire_Decay[x][y] - 1
                    grid_dirty = true
                end
            end
        end
    end
    fire_decay_metro:start()

    crow_reinit()

    print('schicksalslied 2.0 ready')
end

-- ========================================================================
-- CLEANUP
-- ========================================================================
function cleanup()
    Sequencer.stop_all_clocks()
    Roles.free_all()
    if screen_metro then screen_metro:stop() end
    if grid_metro then grid_metro:stop() end
    if fire_decay_metro then fire_decay_metro:stop() end
    g:all(0)
    g:refresh()
end
