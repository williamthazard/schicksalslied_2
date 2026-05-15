---schicksalslied 2.0
---
---a poetry sequencer
---
---type to enter text, ENTER to stage,
---grid row 3/5/7 press to assign,
---grid row 2/4/6/8 toggle to fire.
---
---K1: panic (free all sounds)
---K2: pause/resume (clock-quantized)
---K3: tap tempo
---
---version 2.0.0

engine.name = 'Lied'

local Sequencer  = include 'lib/sequencer'
local Roles      = include 'lib/cell_roles'
local MusicUtil  = require 'musicutil'
Midi_Role        = include 'lib/midi_role'
local Grain      = include 'lib/grid_grain_params'

-- ========================================================================
-- GLOBAL STATE — text input + history
-- ========================================================================
Displayed_String = ""    -- live typing buffer
My_String        = ""    -- staged line, set by ENTER and row-1 release
History          = {}    -- typed + file-loaded lines, indexed 1..N
History_Index    = 0
New_Line         = false
Needs_Restart    = false -- legacy from 1.x's FormantTriPTR install; always false in 2.0

-- ========================================================================
-- GRID + SCREEN
-- ========================================================================
G                = grid.connect()

-- Hotplug handlers — fire when a grid is connected/disconnected at runtime.
-- Without grid.add, if the user plugs in a grid AFTER script init, the LEDs
-- stay dark until the first grid press (which sets Grid_Dirty via G.key).
grid.add = function(dev)
    G = grid.connect()
    Grid_Dirty = true
    print('grid connected: ' .. (dev.name or 'unknown'))
end

grid.remove = function(dev)
    print('grid disconnected: ' .. (dev.name or 'unknown'))
end

Grid_Dirty       = true

-- K1/K2/K3 state for tap-tempo
Tap_Tempo_Times  = {}

-- ========================================================================
-- CROW INIT FUNCTION
-- ========================================================================
function crow_reinit()
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
            table.insert(History, line)
        end
    end
    Grid_Dirty = true
    redraw()
end

-- ========================================================================
-- KEYBOARD HANDLER (spec §11 — two-variable text input model)
-- ========================================================================

keyboard.char = function(character)
    if #Displayed_String < 200 then
        Displayed_String = Displayed_String .. character
    end
end

keyboard.code = function(code, val)
    if val == 0 then return end
    if code == 'BACKSPACE' then
        Displayed_String = Displayed_String:sub(1, -2)
    elseif code == 'UP' then
        if #History == 0 then return end
        if New_Line then
            History_Index = #History - 1
            New_Line = false
        else
            History_Index = util.clamp(History_Index - 1, 0, #History)
        end
        Displayed_String = History[History_Index + 1] or ""
    elseif code == 'DOWN' then
        if #History == 0 or History_Index == nil then return end
        History_Index = util.clamp(History_Index + 1, 0, #History)
        if History_Index == #History then
            Displayed_String = ""
            New_Line = true
        else
            Displayed_String = History[History_Index + 1] or ""
        end
    elseif code == 'ENTER' and #Displayed_String > 0 then
        -- ENTER promotes Displayed_String to My_String, adds to History,
        -- clears Displayed_String (per spec §7 text input flow)
        My_String = Displayed_String
        table.insert(History, Displayed_String)
        Displayed_String = ""
        History_Index = #History
        New_Line = true
        Grid_Dirty = true
    elseif keyboard.ctrl() then
        -- Ctrl chord: remove last History entry, clear Displayed_String
        table.remove(History, #History)
        History_Index = #History
        Displayed_String = ""
        Grid_Dirty = true
    end
end

-- ========================================================================
-- GRID HANDLER (spec §3 + §11)
-- ========================================================================

G.key = function(x, y, z)
    Sequencer.Momentary[x][y] = (z == 1)
    Grid_Dirty = true

    if y == 1 then
        -- History row
        if x + 16 * (y - 1) > #History then return end
        if z == 1 then
            -- Press: append history[x + 16*(y-1)] to Displayed_String
            My_String = Displayed_String .. History[x + 16 * (y - 1)]
            Displayed_String = My_String
        else
            -- Release: check if any other row-1 buttons are still held
            local any_held = false
            for col = 1, 16 do
                if Sequencer.Momentary[col][1] then any_held = true; break end
            end
            if any_held then return end
            -- All released — set My_String from current Displayed_String
            if #Displayed_String > 0 then
                My_String = Displayed_String
            end
            Displayed_String = ""
            New_Line = true
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
        -- Assign row: press assigns My_String to the cell at (x, y-1)
        if z == 1 then
            if #My_String > 0 then
                Sequencer.assign(x, y - 1, My_String)
            end
        end
    end
end

-- ========================================================================
-- GRID LED RENDERING (spec §11 brightness table)
-- ========================================================================

function grid_redraw()
    G:all(0)
    -- Row 1: history slots. 0 if empty, 4 if filled, 15 if held
    for x = 1, 16 do
        local idx = x  -- slot index = col for row 1
        if idx <= #History then
            G:led(x, 1, 4)
        end
        if Sequencer.Momentary[x][1] then
            G:led(x, 1, 15)
        end
    end
    -- Rows 2/4/6/8 (toggle rows): 0 idle, 15 toggled-on, 15 held.
    -- When Paused, toggled-on dims to 6.
    for x = 1, 16 do
        for y = 2, 8, 2 do
            if Sequencer.Toggled[x][y] then
                local level = Sequencer.Paused and 6 or 15
                G:led(x, y, level)
            end
            if Sequencer.Momentary[x][y] then
                G:led(x, y, 15)
            end
        end
    end
    -- Rows 3/5/7 (momentary): 4 idle, 15 held
    for x = 1, 16 do
        for y = 3, 7, 2 do
            G:led(x, y, 4)
            if Sequencer.Momentary[x][y] then
                G:led(x, y, 15)
            end
        end
    end
    G:refresh()
end

-- ========================================================================
-- SCREEN REDRAW (spec §11 two-string layout)
-- ========================================================================

function redraw()
    screen.clear()
    screen.level(10)

    -- Input box at the bottom (y 50-64)
    screen.rect(2, 50, 125, 14)
    screen.stroke()
    screen.move(5, 59)
    screen.text("> " .. Displayed_String)

    -- History items above (up to 4-5 lines, scrolling up)
    for i = 1, 5 do
        if not (History_Index - i >= 0) then break end
        screen.move(5, 55 - 10 * i)
        screen.text(History[History_Index - i + 1] or "")
    end

    screen.update()
end

-- ========================================================================
-- HARDWARE KEYS (K1 / K2 / K3 — spec §11)
-- ========================================================================

local function tap_tempo()
    local now = util.time()
    -- If the last tap was more than 3 seconds ago, start fresh
    if #Tap_Tempo_Times > 0 and (now - Tap_Tempo_Times[#Tap_Tempo_Times]) > 3 then
        Tap_Tempo_Times = {}
    end
    table.insert(Tap_Tempo_Times, now)
    if #Tap_Tempo_Times > 4 then
        table.remove(Tap_Tempo_Times, 1)
    end
    if #Tap_Tempo_Times >= 2 then
        local intervals = {}
        for i = 2, #Tap_Tempo_Times do
            table.insert(intervals, Tap_Tempo_Times[i] - Tap_Tempo_Times[i - 1])
        end
        local avg = 0
        for _, v in ipairs(intervals) do avg = avg + v end
        avg = avg / #intervals
        local bpm = 60 / avg
        bpm = util.clamp(bpm, 20, 400)
        bpm = math.floor(bpm + 0.5)  -- round to nearest integer
        params:set('clock_tempo', bpm)
        print(string.format('tap tempo: %d bpm', bpm))
    end
end

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
    -- MIDI: send all-notes-off via Midi_Role's tracked active-note list.
    -- Cleaner than CC123 blast — only stops notes WE sent.
    Midi_Role.all_notes_off()
    -- Note: w/syn and w/del don't expose direct silence verbs. Their voices
    -- decay naturally via internal envelopes. Clearing Toggled (above) is
    -- the main mitigation — no new triggers will reach them.
    -- Mark grid dirty so the LEDs reflect the now-cleared toggle state
    Grid_Dirty = true
    print('PANIC: silenced everything')
end

function key(n, z)
    if z == 0 then return end
    if n == 1 then
        panic()
    elseif n == 2 then
        Sequencer.toggle_pause()
        Grid_Dirty = true
    elseif n == 3 then
        tap_tempo()
    end
end

function enc(n, d)
    -- Reserved for future use; no encoder actions in Sub-plan B
end

-- ========================================================================
-- GLOBAL RANDOMIZE
-- ========================================================================
-- Triggered by the global_randomize param. Iterates every cell + sampler +
-- one-shot + granular param and randomizes within reasonable bounds.
-- The per-family randomize functions are defined in lib/voice_params (added
-- in Sub-plan C Task 5.1). Until that module exists, this function calls
-- functions that don't yet exist — calling Global_Randomize will fail at
-- runtime until those tasks complete. (Wiring the param now keeps the menu
-- structure stable; the action callback gracefully fails until then.)
function Global_Randomize()
    local ok, VoiceParams = pcall(require, 'lib/voice_params')
    if not ok then
        print('Global_Randomize: lib/voice_params not yet present, skipping')
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
    -- ────────────────────────────────────────────────────────────────────
    -- GLOBAL GROUP (spec §9)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('global', 8)

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
        action = function() Sequencer.toggle_pause(); Grid_Dirty = true; end,
    }
    params:add{
        type = 'trigger',
        id = 'tap_tempo_param',
        name = 'tap tempo',
        action = tap_tempo,
    }
    params:add{
        type = 'trigger',
        id = 'global_randomize',
        name = 'global randomize',
        action = function() Global_Randomize() end,
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

    -- ────────────────────────────────────────────────────────────────────
    -- CROW GROUP (spec §8)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('crow', 10)

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
    params:add_group('midi', 3)

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
        options = Midi_Role.build_device_list(),
        default = 1,
        action = function(n)
            Midi_Role.all_notes_off()  -- clean up before switching devices
            Midi_Role.connect_device(n)
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
    -- ROW-2 CELLS GROUP (16 cells × 26 params + 4 bulk triggers = 420)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('row_2_cells', 16 * 26 + 4)
    do
        local VoiceParams = require 'lib/voice_params'
        for x = 1, 16 do
            VoiceParams.add_row2_cell_block(x)
        end
        params:add{
            type = 'trigger',
            id = 'row_2_set_all_trisin',
            name = 'row 2: all TriSin',
            action = function()
                for x = 1, 16 do params:set('cell_' .. x .. '_2_role', 1) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'row_2_set_all_ringer',
            name = 'row 2: all Ringer',
            action = function()
                for x = 1, 16 do params:set('cell_' .. x .. '_2_role', 2) end
            end,
        }
        params:add{
            type = 'trigger',
            id = 'row_2_set_default_mix',
            name = 'row 2: default mix',
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
            name = 'row 2: randomize roles',
            action = function()
                for x = 1, 16 do
                    params:set('cell_' .. x .. '_2_role', math.random(1, 11))
                end
            end,
        }
    end

    -- ────────────────────────────────────────────────────────────────────
    -- SAMPLERS GROUP (16 slots × 10 params + 1 randomize-all = 161)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('samplers', 16 * 10 + 1)
    do
        local VoiceParams = require 'lib/voice_params'
        for slot = 1, 16 do
            -- File param (PSET-savable, triggers buffer load on path set)
            params:add{
                type = 'file',
                id = 'sampler_' .. slot .. '_file',
                name = 'sampler ' .. slot .. ' file',
                action = function(path)
                    if path == nil or path == '' or path == '-' then
                        engine.sampler_clear(slot)
                    else
                        engine.sampler_load(slot, path)
                    end
                end,
            }
            -- 9 voice params from the helper
            VoiceParams.add_sampler_block(slot)
        end
        params:add{
            type = 'trigger',
            id = 'samplers_randomize_all',
            name = 'randomize all samplers',
            action = function()
                for slot = 1, 16 do
                    VoiceParams.randomize_sampler(slot)
                end
            end,
        }
    end
    -- ────────────────────────────────────────────────────────────────────
    -- ONE-SHOT SAMPLERS GROUP (13 slots × 10 params + 1 randomize-all = 131)
    -- ────────────────────────────────────────────────────────────────────
    params:add_group('one_shot_samplers', 13 * 10 + 1)
    do
        local VoiceParams = require 'lib/voice_params'
        for slot = 1, 13 do
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
            VoiceParams.add_oneshot_block(slot)
        end
        params:add{
            type = 'trigger',
            id = 'oneshots_randomize_all',
            name = 'randomize all one-shots',
            action = function()
                for slot = 1, 13 do
                    VoiceParams.randomize_oneshot(slot)
                end
            end,
        }
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
    end)

    Midi_Role.init()

    Sequencer.start_all_clocks()

    -- Screen redraw timer at 15fps
    Screen_Metro = metro.init()
    Screen_Metro.time = 1/15
    Screen_Metro.event = function() redraw() end
    Screen_Metro:start()

    -- Grid redraw timer at 30fps
    Grid_Metro = metro.init()
    Grid_Metro.time = 1/30
    Grid_Metro.event = function()
        if Grid_Dirty then
            grid_redraw()
            Grid_Dirty = false
        end
    end
    Grid_Metro:start()

    -- Fire-decay tick for LED flash on currently-firing cells (15fps)
    Fire_Decay_Metro = metro.init()
    Fire_Decay_Metro.time = 1/15
    Fire_Decay_Metro.event = function()
        for x = 1, 16 do
            for y = 2, 8, 2 do
                if Sequencer.Fire_Decay[x][y] > 0 then
                    Sequencer.Fire_Decay[x][y] = Sequencer.Fire_Decay[x][y] - 1
                    Grid_Dirty = true
                end
            end
        end
    end
    Fire_Decay_Metro:start()

    crow_reinit()

    print('schicksalslied 2.0 ready')
end

-- ========================================================================
-- CLEANUP
-- ========================================================================
function cleanup()
    Sequencer.stop_all_clocks()
    Roles.free_all()
    if Screen_Metro then Screen_Metro:stop() end
    if Grid_Metro then Grid_Metro:stop() end
    if Fire_Decay_Metro then Fire_Decay_Metro:stop() end
    G:all(0)
    G:refresh()
end
