# `lib/timing.lua` — Line-by-Line

The canonical musical-fraction lookup module. 120 lines. The smallest semantically-meaningful file in the project, and a clean example of how to expose a curated set of values to option-type params.

Conceptual context appears throughout the tutorial — most prominently [chapter 09](09-lua-foundations.md) (Norns params overview) and [chapter 13](13-voice_params.lua.md) (where these labels are consumed).

Sections:

1. Header comment (lines 1-14)
2. Module table (line 16)
3. `Timing.OPTIONS` — beat-duration values (lines 18-48)
4. `Timing.RATE_OPTIONS` — signed playback-rate values (lines 50-90)
5. Private helpers (lines 92-110)
6. Public accessors (lines 112-118)
7. Module return (line 120)

## 1. Header comment

```lua
-- lib/timing.lua — musical timing & rate option tables.
--
-- Timing controls (seq_mode fixed_value, step_N_duration, random_min/max,
-- phase, scale) and rate-kind value_mode controls (rate fixed_value,
-- step_N_value, random_min/max) are option-type params whose underlying
-- value is one of a curated set of musical fractions. This keeps every
-- intermediate scroll position musical — so even a fire caught mid-scroll
-- still lands on a sensible division — and makes triplets (1/3, 2/3, ...)
-- reachable, which a uniform 1/16-step controlspec could not.
--
-- Look up the float value from a stored option index via Timing.value(idx)
-- or Timing.rate_value(idx). Build the param's `options` list via
-- Timing.labels() / Timing.rate_labels(). Pick a default index for a
-- desired float via Timing.idx_for_value(v) / Timing.rate_idx_for_value(v).
```

**Lines 1-14**: a substantial header comment doing two things:

1. **Lists the consumers**: every Timing-driven param in the codebase. Useful for grep: if you want to find where Timing is used, this list points at the param families.
2. **Names the design rationale**: option-type instead of controlspec because (a) every intermediate scroll position should be musical, (b) triplets (1/3, 2/3) aren't reachable on a uniform 1/16-step grid.

The header also names the 6-function API: `labels()` / `value(idx)` / `idx_for_value(v)` for beats, and the parallel three for rates. That's the entire module.

`★ Insight ─────────────────────────────────────`
**File-header comments that name the API are unusually valuable for a Lua project.** Lua has no type system to tell you "this module exports these functions"; a careful header comment is the next best thing. The structure here — purpose, consumers, API — is a reusable template for documenting any helper module.

**The phrase "even a fire caught mid-scroll still lands on a sensible division"** is the design justification in 11 words. It's worth memorizing. The same principle applies to any user-controllable musical parameter: if intermediate values are unmusical, the user can't make musical mistakes during fast tweaks. Option-type with a curated list of musical values gives the user freedom to scroll without producing nonsense.
`─────────────────────────────────────────────────`

## 2. Module table

```lua
local Timing = {}
```

**Line 16**: empty module table. Populated below.

## 3. `Timing.OPTIONS` — beat-duration values

```lua
Timing.OPTIONS = {
    { label = '1/64',  value = 1/64 },
    { label = '1/32',  value = 1/32 },
    { label = '1/16',  value = 1/16 },
    { label = '1/12',  value = 1/12 },  -- 16th triplet
    { label = '1/8',   value = 1/8 },
    { label = '1/6',   value = 1/6 },   -- 8th triplet
    { label = '3/16',  value = 3/16 },  -- dotted 16th
    { label = '1/4',   value = 1/4 },
    { label = '1/3',   value = 1/3 },   -- quarter triplet
    { label = '3/8',   value = 3/8 },   -- dotted 8th
    { label = '1/2',   value = 1/2 },
    { label = '2/3',   value = 2/3 },
    { label = '3/4',   value = 3/4 },   -- dotted quarter
    { label = '1',     value = 1 },
    { label = '4/3',   value = 4/3 },
    { label = '3/2',   value = 3/2 },
    { label = '2',     value = 2 },
    { label = '8/3',   value = 8/3 },
    { label = '3',     value = 3 },     -- dotted half
    { label = '4',     value = 4 },
    { label = '6',     value = 6 },
    { label = '8',     value = 8 },
    { label = '12',    value = 12 },
    { label = '16',    value = 16 },
    { label = '24',    value = 24 },
    { label = '32',    value = 32 },
    { label = '64',    value = 64 },
}
```

**Lines 18-48**: 27 beat-duration values. **Monotonically increasing** by value from 1/64 to 64. Each entry is a `{ label, value }` table.

The labels are user-facing strings (what appears in the params menu); the values are the actual numbers used for `clock.sync(rate)` calls in `sequencer.lua`.

The selection isn't arbitrary. Reading the list, you can see the design:

- **Binary divisions**: 1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4, 8, 16, 32, 64 — the standard powers of 2.
- **Triplets**: 1/12 (16th-note triplet), 1/6 (8th-note triplet), 1/3 (quarter-note triplet), 2/3, 4/3, 8/3 — the 3-against-2 polyrhythm grid.
- **Dotted notes**: 3/16 (dotted 16th), 3/8 (dotted 8th), 3/4 (dotted quarter), 3/2 (dotted half), 3 (dotted whole).
- **Larger groupings**: 6 (a phrase length), 12, 24 — useful for slowly-evolving sequences.

These cover essentially every musically-useful subdivision a rhythmic sequencer might want. Bringing the cap from 64 down to 8 in the delay sync version (chapter 20) is what we did for the master delay — but the per-cell timing keeps the full range.

`★ Insight ─────────────────────────────────────`
**Why store label AND value as separate fields?** Because the labels can be more legible than the literal float values. The user sees `'1/3'`; the SC engine receives `0.333...`. Without the label, we'd have to format on the fly (and `string.format("%.3f", 1/3)` doesn't give `"1/3"`). The label is curated by hand.

**The monotonic ordering is what makes encoder scrolling feel natural.** Scrolling up always increases the rate value; scrolling down always decreases. If the list were unsorted (e.g., '1' first, then '1/4', then '4'), encoder turns would feel chaotic — values would jump around. Always order option-type params by their semantic value, not by their declaration order.

**The values use Lua's exact-fraction arithmetic** (`1/64`, `1/3`, etc.) rather than decimal approximations. These are computed at module-load time and stored as floats. The round-trip precision is fine for clock.sync purposes — 1/64 = 0.015625 has no precision loss in IEEE 754 doubles. But 1/3 = 0.333... does have rounding; sync(1/3) doesn't hit exact beat 1/3 multiples. The drift is sub-millisecond at typical tempos, inaudible.
`─────────────────────────────────────────────────`

## 4. `Timing.RATE_OPTIONS` — signed playback-rate values

```lua
Timing.RATE_OPTIONS = {
    { label = '-16',   value = -16    },
    { label = '-8',    value = -8     },
    { label = '-6',    value = -6     },
    { label = '-4',    value = -4     },
    { label = '-3',    value = -3     },
    { label = '-8/3',  value = -8/3   },
    { label = '-2',    value = -2     },
    { label = '-3/2',  value = -3/2   },
    { label = '-4/3',  value = -4/3   },
    { label = '-1',    value = -1     },
    { label = '-3/4',  value = -3/4   },
    { label = '-2/3',  value = -2/3   },
    { label = '-1/2',  value = -1/2   },
    { label = '-1/3',  value = -1/3   },
    { label = '-1/4',  value = -1/4   },
    { label = '-1/6',  value = -1/6   },
    { label = '-1/8',  value = -1/8   },
    { label = '-1/16', value = -1/16  },
    { label = '0',     value = 0      },
    { label = '1/16',  value = 1/16   },
    { label = '1/8',   value = 1/8    },
    { label = '1/6',   value = 1/6    },
    { label = '1/4',   value = 1/4    },
    { label = '1/3',   value = 1/3    },
    { label = '1/2',   value = 1/2    },
    { label = '2/3',   value = 2/3    },
    { label = '3/4',   value = 3/4    },
    { label = '1',     value = 1      },
    { label = '4/3',   value = 4/3    },
    { label = '3/2',   value = 3/2    },
    { label = '2',     value = 2      },
    { label = '8/3',   value = 8/3    },
    { label = '3',     value = 3      },
    { label = '4',     value = 4      },
    { label = '6',     value = 6      },
    { label = '8',     value = 8      },
    { label = '16',    value = 16     },
}
```

**Lines 52-90**: 37 playback-rate values. **Signed** (includes negatives), **includes 0**, and **monotonically increasing** from -16 (fastest reverse) through 0 (freeze) to 16 (fastest forward).

The comment notes: "Reads left-to-right on encoder scroll: most-negative to most-positive." So scrolling up takes you from reverse-fast through reverse-slow through freeze through forward-slow through forward-fast.

Why a separate list from `OPTIONS`? Two reasons:

1. **Negative values**: a sample player can play backwards; a sequencer cannot fire at "-1 beat between events." So `RATE_OPTIONS` includes negatives.
2. **Zero**: a sample player can freeze (rate 0); a sequencer can't sync at "0 beats apart" (infinite tempo). So `RATE_OPTIONS` includes 0.

The capping is also different: `RATE_OPTIONS` tops out at 16 (rather than 64 for `OPTIONS`). Playback rates above 16x are rarely musically useful; rate values above 16 produce extreme transposition (4 octaves up = rate 16).

The list is symmetric around 0, with the same values mirrored: -16 / 16, -8 / 8, -3/4 / 3/4, etc. The triplets (-8/3, -4/3, -2/3, -1/3, -1/6, then their positive counterparts) match the OPTIONS triplets.

`★ Insight ─────────────────────────────────────`
**Why have two lists with so much overlap?** Because the consumers are categorically different. A `cell_X_Y_seq_fixed_value` param is asking "how many beats between fires?" — that's positive. A `sampler_5_rate` param is asking "what playback speed?" — that's signed with 0 as freeze. Combining them into one list (with negatives in front of the same positive values) would force every consumer to know which subset they care about.

**The separation is also future-proofing**. If we ever need a third kind of musical option (e.g., MIDI ratio multipliers), we can add a third list without disrupting the existing two. Adding new option-type categories is mechanical: define the list, write `Timing.<name>_labels()` / `_value()` / `_idx_for_value()`, done.
`─────────────────────────────────────────────────`

## 5. Private helpers

```lua
local function labels_from(opts)
    local t = {}
    for i, opt in ipairs(opts) do t[i] = opt.label end
    return t
end
```

**Lines 92-96**: extract just the labels from an options table. Used to build the `options = { ... }` arg for Norns params.

The function constructs a fresh array (no shared mutation with the original `opts`). Returns labels in the same order as the source.

```lua
local function value_from(opts, idx)
    if idx == nil or idx < 1 or idx > #opts then return opts[1].value end
    return opts[idx].value
end
```

**Lines 98-101**: look up the value at index `idx`. Defensive bounds check: nil, less than 1, or greater than length all return `opts[1].value` (the first entry's value as a safe fallback).

The defensive fallback is important. `params:get(...)` could return nil during early init. Without the fallback, `opts[nil].value` would crash. With it, we get the smallest available value, which is harmless.

```lua
local function idx_for_value(opts, target)
    local best, best_diff = 1, math.huge
    for i, opt in ipairs(opts) do
        local diff = math.abs(opt.value - target)
        if diff < best_diff then best, best_diff = i, diff end
    end
    return best
end
```

**Lines 103-110**: nearest-neighbor lookup. Given a target float value, return the index of the entry whose value is closest. Used by the `_default_fixed_value` helpers in `voice_params.lua` — you specify "I want this cell to default to a 3-beat rate" and `idx_for_value` returns the index of the closest entry (which is exactly `3` if it's in the list).

The algorithm is O(N) linear scan with `math.huge` as the initial best_diff sentinel. For N = 27 (OPTIONS), this is trivial; for N = 37 (RATE_OPTIONS), still trivial. There's no need for a binary search.

`★ Insight ─────────────────────────────────────`
**`math.huge` is Lua's representation of positive infinity.** Useful as a "definitely-greater-than-anything" initial value for min-search algorithms. Compare to other languages: Python has `float('inf')`; JavaScript has `Infinity`; C has `HUGE_VAL` or `INFINITY`. Same concept.

**The "ALL three helpers are local functions outside the module table"** is intentional. They're implementation details — consumers don't need access. The public API is the six methods (`Timing.labels`, `Timing.value`, etc.) defined just below. The locals are scoped to the module file.
`─────────────────────────────────────────────────`

## 6. Public accessors

```lua
function Timing.labels()              return labels_from(Timing.OPTIONS) end
function Timing.value(idx)            return value_from(Timing.OPTIONS, idx) end
function Timing.idx_for_value(v)      return idx_for_value(Timing.OPTIONS, v) end

function Timing.rate_labels()         return labels_from(Timing.RATE_OPTIONS) end
function Timing.rate_value(idx)       return value_from(Timing.RATE_OPTIONS, idx) end
function Timing.rate_idx_for_value(v) return idx_for_value(Timing.RATE_OPTIONS, v) end
```

**Lines 112-118**: six one-liners exposing the API. Each calls a private helper with one of the two options tables.

The mirrored structure (three for beats, three for rates) is the entire user-facing surface. Consumers of this module use exactly these six functions; the underlying tables and helpers don't need to be accessed directly.

The functions are written as `function Timing.name() ... end` rather than the alternate `Timing.name = function() ... end` form. Both are equivalent in Lua; the script uses the first form for module methods.

## 7. Module return

```lua
return Timing
```

**Line 120**: standard Lua module return. `include 'lib/timing'` evaluates to this table.

## Summary

`lib/timing.lua` is the simplest "real" file in the project: two data tables and six pure functions. It's deliberately minimal — a single-responsibility module that encapsulates the curated set of musical fractions.

The patterns to internalize:

- **Curated option tables** (label/value pairs) for option-type params.
- **Monotonic ordering** so encoder scrolling feels natural.
- **Defensive bounds checks** in lookup functions (handle nil and out-of-range indices gracefully).
- **Separate tables for semantically different categories** (beats vs rates) — easier than encoding the difference inline.
- **Mirrored API** — three functions for each table, all sharing the same private helpers.

When adding a new musical category (e.g., MIDI ratios for harmonic locking), this file is the template:

1. Add `Timing.<NEW>_OPTIONS = { ... }` with monotonically-ordered entries.
2. Add `Timing.<new>_labels() / _value(idx) / _idx_for_value(v)` using the existing private helpers.
3. Update the header comment to list the new category's consumers.

Total cost: ~5 minutes of editing. The rest of the codebase can then use `Timing.<new>_*` exactly like `Timing.value` / `Timing.rate_value`.
