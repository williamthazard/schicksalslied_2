-- lib/wtape_looper.lua — schicksalslied 2.0 w/tape looper choreography
-- Ported from 1.x schicksalslied.lua:341-404 (the looper() function)
-- Rewired to consume bytes from a single cell's sequins via seq() instead
-- of the global C/J sequins-step calls from 1.x.
--
-- Called from cell_roles.lua's 'w/tape looper' dispatch.
-- Spec §8: preserved bit-for-bit; only the sequins source changed.

local Looper = {}

-- Run one full looper pass for a cell. Reads bytes from seq() (the cell's sequins).
-- All clock.sync calls remain — this runs inside a clock.run coroutine
-- spawned by cell_roles.dispatch_row_2['w/tape looper'].
function Looper.run(seq)
    crow.ii.wtape.loop_start(1)
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_end(1)
    if seq() < 17 then
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.loop_scale(seq() / seq())
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_next(seq() - seq())
            end
        end
    else
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.loop_next(seq() - seq())
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_scale(seq() / seq())
            end
        end
    end
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_active(0)
    for _ = 1, seq() do
        clock.sync(seq() / seq())
        crow.ii.wtape.seek((seq() - seq()) * 300)
    end
    for _ = 1, seq() do
        clock.sync(seq() / seq())
        crow.ii.wtape.loop_active(1)
        if seq() < 17 then
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_scale(seq() / seq())
                for _ = 1, seq() do
                    clock.sync(seq() / seq())
                    crow.ii.wtape.loop_next(seq() - seq())
                end
            end
        else
            for _ = 1, seq() do
                clock.sync(seq() / seq())
                crow.ii.wtape.loop_next(seq() - seq())
                for _ = 1, seq() do
                    clock.sync(seq() / seq())
                    crow.ii.wtape.loop_scale(seq() / seq())
                end
            end
        end
        clock.sync(seq() / seq())
        crow.ii.wtape.loop_active(0)
        for _ = 1, seq() do
            clock.sync(seq() / seq())
            crow.ii.wtape.seek((seq() - seq()) * 300)
        end
    end
end

return Looper
