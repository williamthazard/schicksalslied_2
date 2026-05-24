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

local Timing = {}

-- Beat-duration values (positive, monotonic). Covers sub-beat divisions,
-- binary triplet and dotted notes, and powers up to whole-bar groupings.
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

-- Playback-rate values (signed). Negative = reverse; 0 = stopped; 1 = native.
-- Reads left-to-right on encoder scroll: most-negative to most-positive.
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

local function labels_from(opts)
    local t = {}
    for i, opt in ipairs(opts) do t[i] = opt.label end
    return t
end

local function value_from(opts, idx)
    if idx == nil or idx < 1 or idx > #opts then return opts[1].value end
    return opts[idx].value
end

local function idx_for_value(opts, target)
    local best, best_diff = 1, math.huge
    for i, opt in ipairs(opts) do
        local diff = math.abs(opt.value - target)
        if diff < best_diff then best, best_diff = i, diff end
    end
    return best
end

function Timing.labels()              return labels_from(Timing.OPTIONS) end
function Timing.value(idx)            return value_from(Timing.OPTIONS, idx) end
function Timing.idx_for_value(v)      return idx_for_value(Timing.OPTIONS, v) end

function Timing.rate_labels()         return labels_from(Timing.RATE_OPTIONS) end
function Timing.rate_value(idx)       return value_from(Timing.RATE_OPTIONS, idx) end
function Timing.rate_idx_for_value(v) return idx_for_value(Timing.RATE_OPTIONS, v) end

return Timing
