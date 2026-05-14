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
