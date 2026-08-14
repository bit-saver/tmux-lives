# Theme picker — responsiveness, seed zone, and default list — Design

**Date:** 2026-08-13
**Status:** approved, not built
**Supersedes:** `2026-08-08-picker-legibility-and-autoapply-design.md`, `2026-08-07-picker-seed-section-design.md`

## Problem

The user's verdict after running the shipped picker live: *"It's kind of unusable unless you're really slow with it."* Two reported symptoms, plus three layout/behaviour asks.

> "Tapping down at a quick pace and then up results in the selector to keep going down for a moment before going up."

> "On the seed picker, single presses are fine, but holding down causes it to jerk a couple times and then go dark until you let go."

### Root cause, measured

The frame is far more expensive than the record claimed. Measured on rocket at the user's real geometry (62-row client → 52-row popup):

| state | ms/frame |
|---|---|
| browsing, curated 14 | 128 |
| browsing, expanded 35 | 266 |
| editing the seed | 142 |

`CLAUDE.md` and the last whole-branch review both say "~90 ms". That figure predates the popup moving from a fixed `-h 26` to `-h 85%`, which took visible rows from 10 to 36. Nobody re-measured after that change.

**The cost is the NUMBER of fish command substitutions, not the cost of any one builder.** Measured unit costs on this host:

| operation | cost |
|---|---|
| plain function call | 0.0057 ms |
| **function call inside `(…)`** | **0.108 ms** — 19× more |
| `(math …)` | 0.071 ms |
| `(string repeat …)` | 0.032 ms |

`__tcz_thp_cells` runs ~17 substitutions internally and is 96% of a scheme row (5.4 ms of 5.6 ms). `__tcz_thp_row` additionally calls `__tcz_theme` 2–5 times per row for colours that are **constant for the whole frame** and already hoisted at the top of the draw block.

At 266 ms/frame the list advances ~4 rows/second while a key is held. Rapid tapping is roughly 8/second. That is the whole of symptom 1: input queues faster than frames render, so the cursor lags the fingers by (queue length × frame time). A secondary contributor — the drain's `case up down` is direction-blind and discards a queued `up` while processing a `down`, so a reversal can be swallowed outright.

Symptom 2 is a straightforward gap: **the `case up down` arm has a drain only in its non-editing branch.** The editing branch (↑↓ selects the R/G/B channel) has none, so every autorepeat byte gets its own 142 ms full-frame rebuild, unbounded. `chan` clamps to 1–3, which is the "jerk a couple times"; everything after that is hundreds of identical queued frames.

### Why not partial repaint

Considered and rejected. Partial repaint optimises **emission**; the cost is **construction**. Rebuilding 35 rows and cleverly emitting 2 still pays the 135 ms. It would also restructure the draw loop, break the whole-frame synchronized-output model, and force a rewrite of the 26-row frame proof — this suite's strongest guard. Caching delivers the same "only two rows changed" benefit by not doing the work, at materially lower risk.

Measured, row loop, 35 schemes:

| approach | row loop | vs today |
|---|---|---|
| today | 135.3 ms | — |
| memoize `__tcz_thp_cells` | 12.5 ms | 10.8× |
| **+ cache the rendered row** | **2.2 ms** | **61×** |

Rebuilding one genuinely-dirty row costs 0.66 ms. A cursor move dirties exactly two.

## Design

### 1. Memoize the pure row builders

Every `__tcz_thp_*` builder is pure. Cache each one's rendered output in a global keyed by its inputs.

**Key construction must use plain string interpolation only.** A key built with `(string replace …)` costs two substitutions per lookup and eats the win — this is what separated probe 8's 0.06 ms/row lookup from probe 5's. Keys are therefore built from values that are already valid in a fish variable name (integers and flags), never from palette strings, which contain `#` and spaces.

**Scheme rows** key on `<index>_<selected>_<current>`. Index is a safe key only because the palette arrays and the caches are invalidated together — see below.

**Static rows** (preview bar, tab chip, seed zone, legend, both state rows) key on their own real inputs.

**Invalidation has exactly one home: `__tcz_thp_reload`.** That is precisely when the palette arrays change. Pure-function memoization needs nothing further, because the key encodes every input the builder reads.

Two consequences that follow from keying on full inputs, and are worth stating so nobody adds redundant invalidation:

- The `current` marker flag is part of the row key, so saving a new theme yields a different key and a correct row with no invalidation needed.
- `m` (expand/collapse) shifts indices, which **would** make an index-keyed entry stale. It is safe only because `m` already calls `__tcz_thp_reload` before reading `$n`. This is a load-bearing invariant: **nothing may mutate `toks`/`pals`/`fgs`/`tabsfgs`/`recipes` without going through `__tcz_thp_reload`.** It gets its own test.

The first frame after a settle pays full cost (~135 ms), alongside the 310–800 ms palette batch it already pays. Every frame after is a cache hit. Memory is bounded by one seed's worth of entries.

### 2. One held-key rule for all three paths

| path | today | after |
|---|---|---|
| list `↑↓` | discard, one row per frame | rule unchanged, now fast |
| edit-mode `↑↓` (channel) | **no drain at all** | discard, one step per frame |
| edit-mode `←→` (slider) | **sums the burst** | discard, one step per frame |

Summing is what makes the slider skip renders and overshoot: intermediate values are never drawn, so there is nothing to stop on. One step per frame, with frames cheap, gives visible iteration that stops on release.

**The drain invariant is load-bearing and already tested:** every `while true` in the picker except the main event loop must re-assert `stty min 0 time …` *inside* the loop, on the very next line. `__tcz_popup_readkey`'s CSI branch leaves the tty blocking on return, and a drain read after it hangs — this was hit for real once. The existing test asserts that (total `while true` loops − compliant ones) equals 1. A compliant new drain leaves that figure at 1; the assertion's expected value does not change, which is the point of it.

**Direction-blindness is deliberately left alone.** The drain's `case up down` matches both tokens and discards either, so a queued `up` is swallowed while a `down` is being processed. At today's 128–266 ms frames this is a real contributor to "keeps going down before going up". At single-digit-ms frames a reversal will essentially always land in its own frame, so the added branch would be dead weight. Revisit only if the symptom survives the performance work.

### 3. Seed zone — colour block 2 rows → 3

Current idle layout is three rows: a `├─ seed ─┤` separator; a first block row carrying the 12-column colour block plus the bold hex and the muted `hue X° · L Y · C Z` readout to its right; and a second block row that is block only.

New layout: the block becomes **three rows**. The hex moves off to the right and into the **middle** block row, centred within the 12 columns, painted in the picker's existing contrast-aware `seedfg`. The `hue/L/C` readout stays beside the block on that same middle row.

Row-count effects:

| | before | after |
|---|---|---|
| seed zone, idle | 3 rows | 4 rows |
| seed zone, editing | 8 rows | 9 rows |
| `STATIC_IDLE` | 16 | **17** |
| `STATIC_EDIT` | 21 | **22** |
| admission floor | 24 popup / 29 client rows | **25 popup / 30 client rows** |

The 62-row client is unaffected. Note the width situation *improves*: the old first block row was a fixed ~50 visible columns (block + hex + readout) and only honoured `w` at `w >= 50`; removing the hex from it leaves block + readout ≈ 41 columns, which `__tcz_thp_ln` pads normally.

### 4. List — all 35 by default

- The default view shows all 35 catalog rows.
- The `More Schemes` rule stays, as a divider marking the curated 14 above from the other 21 below.
- `m` reverses meaning: it now **collapses** to the curated 14.
- Ordering: **seed-literal rows before derived rows, within each group.** The curated 14 remain above the divider and the other 21 below; literal/derived is the secondary sort, not the top-level split. (Confirmed with the user, whose two answers could otherwise be read as conflicting.)

At the new `STATIC_IDLE` of 17, a 52-row popup gives `WIN` 35 against 36 virtual rows (35 schemes + 1 header), so the list scrolls by exactly one row. This is fine: scrolling changes *which* cached indices are drawn, not their contents, so every row is still a cache hit.

## Testing

This repo's consistent failure mode is defective assertions in the plan rather than defective implementations — four consecutive builds. Requirements:

1. **Every assertion must be run against the pre-fix code and shown to FAIL** before it is trusted. State this in each task brief.
2. **The cache tests must use a call counter, not a grep.** Wrap a counter around the underlying builder and assert the number of real invocations per simulated frame — 2 dirty rows, not 35. This is the same discriminator used for the seed-debounce fix, and it is the only shape that catches a "fix" that caches but still recomputes.
3. **Transparency test:** cached output must be byte-identical to the uncached builder's, on both miss and hit.
4. **Invalidation test:** change the seed, and assert rows render the *new* palette. A cache that never invalidates passes every other test.
5. **The `reload` invariant test:** assert no code path mutates the palette arrays outside `__tcz_thp_reload`.
6. **Timing behaviour needs a pty harness.** Grep-shaped assertions cannot see timing — the 2026-08-01 held-arrow stall was invisible to all nine per-task reviews and was caught only by a pty harness with a simulated redraw cost. The edit-mode drain needs one.
7. **The frame-row proof** reads `STATIC_IDLE`/`STATIC_EDIT` out of the source by regex, so it follows the change automatically. But the explicit literal pins at `test-tmux-categorize.fish:2666-2667` compare against `16`/`21` and must be updated to `17`/`22`, as must the floor pins.
8. **The caches are process globals, and the suite sources the categorizer once.** Entries therefore persist across assertions within a suite run, which can mask a bug or leak state between unrelated tests. Every test that exercises a cached builder must clear the caches first, and that clearing helper is itself part of the implementation, not the test file's private business.

### Known landmines

- Grep guards match **comments**. Describing a banned shape in prose has tripped them nine times in this repo. Describe, never spell.
- The suite's `test-tmux-categorize.fish` has no pass counter, so an undefined function called directly inside a `t` invocation aborts the statement silently and still reports `ALL PASS`. Capture into a variable first.
- The 16-run gate exceeds the Bash tool's 120 s default and is **auto-backgrounded**. Subagents must be told to pass `timeout: 300000` explicitly.
- Copying only a test file to a scratch directory breaks its `$plugindir` self-location and yields confidently false readings. Use full-tree copies for mutation work.
- A guard that measures one dimension is blind to the other. The frame proof counts row *elements* and cannot see display *columns*.

## Out of scope

- **The derivation redesign.** Six of seven roles resolve to only 11 distinct values across 35 catalog rows; 18 pairs differ in exactly one role, always `tabs`. The user's instruction is explicit: *"I don't want to 'cut' the look-alikes, I want to improve our machinery so that it doesn't even produce them."* That is its own brainstorm → spec → plan cycle.
- **Palette-generator research.** The user has asked for a shortlist of external generators worth deconstructing, which they will evaluate by hand. Separate task.
