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
Grid_Dirty       = true

-- K1/K2/K3 state for tap-tempo
Tap_Tempo_Times  = {}

-- ========================================================================
-- CROW INIT FUNCTION
-- ========================================================================
function crow_reinit()
    crow.input[1].mode('clock')
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
-- PARAMS (minimal set — Sub-plan C wires the full menu)
-- ========================================================================
local function add_params()
    -- Crow setup
    params:add{
        type = 'trigger',
        id = 'reinit_crow',
        name = 're-init crow modules',
        action = crow_reinit,
    }
    params:add{
        type = 'control',
        id = 'wsyn_voices',
        name = 'w/syn voices',
        controlspec = controlspec.new(1, 4, 'lin', 1, 4, ''),
        action = function(v) crow.ii.wsyn.voices(v) end,
    }
    -- Sampler file params (16 slots) — Sub-plan A's Lied loads via engine.sampler_load
    for slot = 1, 16 do
        params:add{
            type = 'file',
            id = 'sampler_' .. slot .. '_file',
            name = 'sampler ' .. slot,
            action = function(path)
                if path == nil or path == '' or path == '-' then
                    engine.sampler_clear(slot)
                else
                    engine.sampler_load(slot, path)
                end
            end,
        }
    end
    -- One-shot file params (13 slots)
    for slot = 1, 13 do
        params:add{
            type = 'file',
            id = 'oneshot_' .. slot .. '_file',
            name = 'one-shot ' .. slot,
            action = function(path)
                if path == nil or path == '' or path == '-' then
                    engine.oneshot_clear(slot)
                else
                    engine.oneshot_load(slot, path)
                end
            end,
        }
    end
    -- Text file load
    params:add{
        type = 'file',
        id = 'text_file',
        name = 'text file',
        action = load_text_file,
    }
    -- Row 8 cols 14-16 "on amp" defaults
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

    -- Staged line indicator at y≈40 — only show if My_String is non-empty AND
    -- different from Displayed_String (avoid redundant display right after ENTER)
    if #My_String > 0 and My_String ~= Displayed_String then
        screen.move(5, 40)
        screen.text("* " .. My_String)
    end

    -- History items above (up to 4-5 lines, scrolling up)
    for i = 1, 5 do
        if not (History_Index - i >= 0) then break end
        screen.move(5, 32 - 10 * (i - 1))
        screen.text(History[History_Index - i + 1] or "")
    end

    screen.update()
end

-- ========================================================================
-- HARDWARE KEYS (K1 / K2 / K3 — spec §11)
-- ========================================================================

local function tap_tempo()
    local now = util.time()
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
        params:set('clock_tempo', bpm)
        print(string.format('tap tempo: %.1f bpm', bpm))
    end
end

local function panic()
    Roles.free_all()
    crow.ii.jf.run(0)
    print('PANIC: freed all voices')
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
-- INIT
-- ========================================================================
function init()
    Sequencer.init()
    Roles.init()
    Roles.Sequencer = Sequencer
    Sequencer.dispatch_fn = function(x, y) Roles.dispatch(x, y) end

    add_params()
    params:bang()

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
