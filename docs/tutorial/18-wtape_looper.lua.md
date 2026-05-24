# `lib/wtape_looper.lua` — Line-by-Line

The w/tape looper role implementation. **74 lines** — the smallest source file in the project. Conceptual context: [chapter 12](12-cell_roles.lua.md) (where the looper role's dispatcher delegates here).

Despite its size, this file produces some of the wildest musical output in the script. It's a hand-crafted choreography of w/tape ii calls, with every parameter derived from cell bytes.

Sections:

1. Header (lines 1-9)
2. `Looper.run` choreography (lines 11-72)
3. Module return (lines 74)

## 1. Header

```lua
-- lib/wtape_looper.lua — schicksalslied 2.0 w/tape looper choreography
-- Ported from 1.x schicksalslied.lua:341-404 (the looper() function)
-- Rewired to consume bytes from a single cell's sequins via seq() instead
-- of the global C/J sequins-step calls from 1.x.
--
-- Called from cell_roles.lua's 'w/tape looper' dispatch.
-- Spec §8: preserved bit-for-bit; only the sequins source changed.

local Looper = {}
```

**Lines 1-9**: file header. Three key things:

1. **Ported from 1.x**: this is the same code as in schicksalslied 1.0, just adapted for the new per-cell sequins.
2. **"Preserved bit-for-bit"**: an explicit commitment not to refactor or "improve" this logic. The musical character of this role is the byte-driven chaos; rewriting it for clarity would change the sound.
3. **`seq()` is the byte source**: a callable passed in from `cell_roles.dispatch_row_2['w/tape looper']`. Each call returns the next byte from the cell's sequins.

The "bit-for-bit" commitment is unusual for a refactor. Most ports would clean up parts that look strange (the nested loops, the magic numbers). The decision NOT to clean up is editorial: schicksalslied's identity is partly defined by this specific choreography producing this specific kind of w/tape behavior. Changing it would produce different output.

`★ Insight ─────────────────────────────────────`
**"Preserve bit-for-bit" is a useful commitment to write down in a comment.** Future maintainers (including future-you) might be tempted to "clean up" code that looks dense or weird. The comment establishes that the weirdness is intentional and shouldn't be touched without a corresponding musical-judgment decision.

**The 1.x → 2.x port pattern**: this file is a great example of how to port code while changing one critical layer (here, the byte source). The original 1.x called global Sequins instances (`C` for crow, `J` for Just Friends, `S` for synth). 2.x replaces those with per-cell `seq()` calls passed as args. Same control flow, different source.
`─────────────────────────────────────────────────`

## 2. `Looper.run` choreography

```lua
function Looper.run(seq)
    crow.ii.wtape.loop_start(1)
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_end(1)
```

**Lines 14-17**: declare a loop region on w/tape track 1.

- **`loop_start(1)`** marks the start of loop region on track 1.
- **`clock.sync(seq() / seq())`** waits a number of beats. `seq() / seq()` reads two bytes and divides them — produces a beat duration anywhere from very tiny (e.g., 32/126 ≈ 0.25) to very large (e.g., 126/32 ≈ 3.94). At typical printable-ASCII bytes (32-126), the ratio falls roughly in [0.25, 4]. So the loop length is somewhere in that range, in beats.
- **`loop_end(1)`** marks the end of the loop region. Track 1 now has a defined loop spanning the just-elapsed duration.

This is the "carve out a loop from the tape" step. The loop's length is determined by 2 bytes from the cell's text.

```lua
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
```

**Lines 18-36**: a byte-driven branch into one of two nested-loop patterns.

**The branch condition**: `if seq() < 17`. This reads one byte; printable ASCII is 32-126, so the byte is almost always ≥ 17. The < 17 branch fires only when a byte is in the control-character range (0-16, very rare in normal text — usually appears for tab characters or various low control codes). So 99% of the time, the **else branch** runs.

But the < 17 branch is what makes the looper musically interesting — when the user includes special characters or hits a low byte, the choreography takes a different path. The two branches are similar in structure (nested for loops with `loop_scale` and `loop_next` calls), but their order differs.

The "then" branch:
1. Outer loop iterates `seq()` times (1-126 iterations, typically ~30-60).
2. Each outer iteration: wait `seq()/seq()` beats, set the playback `loop_scale` (speed multiplier).
3. Inner loop iterates `seq()` times.
4. Each inner iteration: wait, call `loop_next` with `seq() - seq()` (a signed byte difference, sometimes positive/sometimes negative).

The "else" branch swaps the inner and outer w/tape calls: it calls `loop_next` first, then enters an inner loop that calls `loop_scale`.

What this produces musically: a long sequence of speed-changes and position-jumps on the tape, paced by the cell's bytes. Loop_scale changes playback rate; loop_next jumps the playhead. The combination produces glitchy, evolving texture.

`★ Insight ─────────────────────────────────────`
**`crow.ii.wtape.loop_next(signed_value)`** advances the playhead position. Positive values advance; negative jump backward. `seq() - seq()` is the difference of two bytes — sometimes positive, sometimes negative, ranging from -94 to +94 (for printable ASCII). w/tape interprets this as a position offset.

**The script consumes a LOT of bytes per Looper.run.** Counting the seq() calls in even just the "then" branch: 1 (outer for-count) + 2 (sync) + 2 (loop_scale) + 1 (inner for-count) + 2 (sync) + 2 (loop_next) per inner iteration. If outer = 30 and inner = 30, that's ~1850 bytes consumed. The cell's sequins wraps around, so for a long cell string the looper reads through it multiple times.

**This is why the role is re-entry-guarded** in `cell_roles.lua`: a Looper.run can take many seconds (depending on byte values). New fires while one is in progress are skipped via `Roles.looper_running[cell_id]`. Without the guard, fast retrigger would stack looper coroutines, all fighting for w/tape ii bandwidth.
`─────────────────────────────────────────────────`

```lua
    clock.sync(seq() / seq())
    crow.ii.wtape.loop_active(0)
    for _ = 1, seq() do
        clock.sync(seq() / seq())
        crow.ii.wtape.seek((seq() - seq()) * 300)
    end
```

**Lines 37-42**: after the nested loops, deactivate the loop and do byte-driven seek operations.

- **`loop_active(0)`** turns OFF the loop (tape returns to normal playback).
- **The for loop** does N seek operations. `seek((seq() - seq()) * 300)` reads two bytes, subtracts (signed result), multiplies by 300. The result is a position offset in some w/tape unit; the multiplier 300 is empirically chosen for "interesting jump magnitudes."

This is the "scatter the playhead" segment. The user hears the tape jumping to different positions.

```lua
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
```

**Lines 43-72**: an OUTER for-loop that re-activates the loop and repeats the entire previous structure. This is a third nested level.

The structure mirrors lines 18-42:
- Activate loop (`loop_active(1)`).
- Same byte-branch and nested-loop choreography.
- Deactivate loop (`loop_active(0)`).
- Byte-driven seek loop.

But all of this is wrapped in an OUTER for-count derived from `seq()`. So the entire "activate, choreograph, deactivate, seek" pattern repeats N times.

By the end, the Looper.run has consumed dozens (sometimes hundreds) of bytes and produced many seconds (sometimes minutes) of w/tape activity.

## 3. Module return

```lua
return Looper
```

**Line 74**: standard module return.

## Summary

`wtape_looper.lua` is the script's most direct example of "byte stream as score." Every w/tape parameter is derived from a sequins byte; the cell's text quite literally choreographs the tape behavior.

What makes the file musically valuable:

- **Compounding randomness**: `seq() / seq()` produces ratios spanning ~4 orders of magnitude. The variability creates organic-feeling timing across the choreography.
- **Signed differences**: `seq() - seq()` produces positive AND negative values from the unsigned byte stream. The negative path is critical for the playhead's back-and-forth motion.
- **Multi-level nesting**: outer × middle × inner for-loops, each driven by bytes. The total iteration count compounds; even a short text produces extended choreography.
- **Bit-for-bit preservation**: the comment establishes a maintenance constraint. The musical character IS the specific control flow; refactoring would change the sound.

A useful debugging tactic: if you want to understand what a specific Looper.run will do, count the seq() calls in order and substitute byte values from your text. The output will be predictable from those bytes alone.

This is the entire file — 74 lines doing a lot of work.
