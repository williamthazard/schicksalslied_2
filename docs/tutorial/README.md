# schicksalslied 2.0 — Developer Tutorial

A step-by-step guide to building schicksalslied 2.0 from scratch. Every line of code in the repository is reproduced and explained somewhere in these chapters. By the end, you will have built a working copy of the script — not a simplified toy, but the real thing.

## How this is organized

20 numbered chapters that read linearly. Each chapter is either:

- **A prerequisite chapter** (01, 02, 09, 20) — establishes concepts or workflow without walking a specific file.
- **A per-file chapter** (03-08, 10-19) — covers exactly one source file, explaining its architecture and walking through every line.

The chapters are organized in a build-from-the-bottom order: SuperCollider DSP first (chapters 02-08), then Norns Lua control side (chapters 09-19), then deployment + debugging (chapter 20).

If you want the full paint-by-numbers experience, read 01 through 20 in order, typing along. If you're already familiar with parts of the project and need targeted reference, jump to the chapter for the file you're working in.

## Chapter index

| # | Chapter | Source file | What it covers |
|---|---|---|---|
| 01 | [Introduction](01-introduction.md) | (none) | Architecture, dev loop, repo tour, environment setup |
| 02 | [SuperCollider Fundamentals](02-sc-fundamentals.md) | (none) | Buses, groups, SynthDefs, real-time vs heap memory |
| 03 | [Lied.sc](03-Lied.sc.md) | `lib/Lied.sc` | The SC kernel: buses, FX chain, granular delay, voice instance management |
| 04 | [Engine_Lied.sc](04-Engine_Lied.sc.md) | `lib/Engine_Lied.sc` | Crone wrapper exposing the kernel to Norns via OSC |
| 05 | [TriSin.sc](05-TriSin.sc.md) | `lib/TriSin.sc` | FM voice class — triangle carrier + sine modulator |
| 06 | [Ringer.sc](06-Ringer.sc.md) | `lib/Ringer.sc` | Pinged-resonant voice class |
| 07 | [Sampler.sc](07-Sampler.sc.md) | `lib/Sampler.sc` | Looping sample voice with A/B Phasor crossfade |
| 08 | [OneShot.sc](08-OneShot.sc.md) | `lib/OneShot.sc` | One-shot sample voice |
| 09 | [Norns Lua Foundations](09-lua-foundations.md) | (none) | Params, clocks, sequins, grid/screen idioms |
| 10 | [timing.lua](10-timing.lua.md) | `lib/timing.lua` | Musical-fraction lookup tables for option-type params |
| 11 | [sequencer.lua](11-sequencer.lua.md) | `lib/sequencer.lua` | Per-cell Sequins state + clock loops + 4 sequencer modes |
| 12 | [cell_roles.lua](12-cell_roles.lua.md) | `lib/cell_roles.lua` | Role registry + dispatch + lazy SC voice allocation |
| 13 | [voice_params.lua](13-voice_params.lua.md) | `lib/voice_params.lua` | Per-cell/per-slot params + dynamic visibility + cell string params |
| 14 | [grid_grain_params.lua](14-grid_grain_params.lua.md) | `lib/grid_grain_params.lua` | Granular delay params block |
| 15 | [lied_lfos.lua](15-lied_lfos.lua.md) | `lib/lied_lfos.lua` | LFO binding wrapper |
| 16 | [midi_role.lua](16-midi_role.lua.md) | `lib/midi_role.lua` | MIDI-out role implementation |
| 17 | [midi_input.lua](17-midi_input.lua.md) | `lib/midi_input.lua` | MIDI keyboard input → dedicated voice |
| 18 | [wtape_looper.lua](18-wtape_looper.lua.md) | `lib/wtape_looper.lua` | w/tape looper choreography |
| 19 | [schicksalslied.lua](19-schicksalslied.lua.md) | `schicksalslied.lua` | Top-level script: init, params, grid, screen, panic, cleanup |
| 20 | [Deployment and Debugging](20-deployment-debugging.md) | (none) | Deploy flow, common failure modes, the TICK probe, what to check first |

## Reading paths

**Linear (recommended for first read):**

01 → 20 in order. Each chapter builds on the previous. By chapter 11 you have a complete SC engine; by chapter 19 you have a complete Lua control side; chapter 20 finalizes deployment.

**SC-first (you already know Norns Lua):**

01 → 02 → 03 → 04 → 05 → 06 → 07 → 08, then skim 09 → 11 → 12 → 13 → 19 → 20.

**Lua-first (you already write SuperCollider):**

01 → 09 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19 → 20, then loop back to 02-08 to understand the engine your Lua talks to.

**Targeted lookup:**

Need to understand a specific file? Find the chapter from the index above. Each chapter is self-contained enough to read standalone — though it assumes the architectural framing from chapter 01 and the relevant prerequisite chapter (02 for SC files, 09 for Lua files).

## Prerequisites

You will need:

- A working Norns (any model).
- A monome grid (optional but useful for verifying behavior).
- A USB keyboard.
- A development workstation with SSH access to Norns and SuperCollider IDE installed.
- Familiarity with at least one general-purpose programming language. Lua and SuperCollider's sclang are both unusual languages; their idioms are taught here, but the assumption is you've programmed before.

The Norns Studies on [monome.org](https://monome.org/docs/norns/studies/) are excellent prerequisite reading if you're newer to Norns. Studies 0-3 give you the foundation that this tutorial's chapter 09 assumes.

## How to read each chapter

Per-file chapters follow the same shape:

1. **Header**: source file name, line count, summary.
2. **Why this exists**: brief architectural framing — where this file fits in the three-tier architecture.
3. **Section index**: numbered list of major sections with source line ranges.
4. **The walkthrough**: each section reproduces the source in a code block, followed by line-by-line explanation. `★ Insight` callouts mark non-obvious idioms.
5. **Checkpoint**: a runnable test that verifies the layer works.
6. **Summary + extension guide**: patterns to internalize + how to extend the file.

Code blocks reproduce the exact source from this repository. When you type along, your local copy should match line-for-line.

## A note on accuracy

I (the LLM that wrote this) committed to never inventing facts about the codebase. If a comment or attribution feels uncertain, check the source. If you find a discrepancy between the tutorial and the source, the source is authoritative — please file an issue or send a correction.

Happy building.
