# Theme Engine v6 — Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v6 generative core — harmony, ramp, arrangement — as pure functions with a proven expressive range, without wiring it to anything.

**Architecture:** Three pure stages behind one entry point. `__tmux_lives_theme_anchors` turns a seed hue and a harmony mode into 1-4 hue angles. `__tmux_lives_theme_ramp` lays `n` `(L, C)` pairs using lightness span, peak chroma and peak position as independent dimensions. `__tmux_lives_theme_arrange` maps the resulting colours onto the seven roles under a single hard rule. `__tmux_lives_theme_render` composes them.

**Tech Stack:** fish 4.7.1. No new dependencies, no new files.

**Spec:** `docs/superpowers/specs/2026-08-23-theme-engine-v6-design.md`

## Why this plan stops at the core

The spec covers two separable subsystems: the generative core, and the surface that exposes it (catalog of recipes, `setup theme` CLI, the rendered fragment, migration, and the picker's roll). This plan is the **core only**.

That split is deliberate, not arbitrary. The core is verifiable on its own — pure functions, no tmux server — and the decisive question is whether the engine's output envelope actually covers the range the current one cannot reach. **If it doesn't, we find out before touching the fragment, the CLI or the picker.** Wiring a core that turns out to have the same collapse would be the expensive mistake.

`__tmux_lives_theme_palette` and the whole v5 cluster stay live and untouched throughout this plan. Nothing this plan builds is reachable from production yet. The surface plan swaps the three production callers (`conf.d/tmux-lives-install.fish:115`, `:936`, `:975`), converts the catalog to recipes, and deletes v5.

## Global Constraints

- **Zero new files.** Everything lands in `conf.d/tmux-lives-install.fish` and `tests/test-tmux-install.fish`.
- **Nothing in the v5 cluster may change**: `__tmux_lives_theme_palette`, `_curve`, `_barpos`, `_family`, `_kincap`, `_accents`, `_reldef`, `_catalog`, `_apply_live`, `_cmd`. They stay byte-identical. This plan is purely additive.
- **Reuse, do not reimplement:** `__tmux_lives_hex_to_rgb01` (`:560`), `__tmux_lives_rgb_to_oklch` (`:570`), `__tmux_lives_oklch_hex` (`:611`, already gamut-clamps via `__tmux_lives_gamut_chroma`), `__tmux_lives_norm360` (`:616`).
- **The seed's hue is always anchor one**, in every mode.
- **The seed's chroma is NOT a ramp input.** The recipe's `peakC` is authoritative so a saved scheme renders identically whatever the seed's saturation. Seed chroma biases the *roll*, which is the surface plan's concern, not this one.
- **One hard rule in arrangement:** `text` must clear a lightness-contrast floor against `bar`. Nothing else is constrained — over-constraining is what produced the collapse this design exists to escape.
- Gate before every commit: `for t in tests/test-*.fish; fish $t; end` and again with `fish --no-config`. All 9 suites `ALL PASS`. `test-tmux-install.fish` reports **708 plain / 707 `--no-config`** today — **that 1-count delta is BY DESIGN**, one isolation assertion is gated on plain fish. Both numbers rise as this plan adds assertions; the delta stays 1.

### Operational notes — read before dispatching or implementing

- **Briefs in this repo have contained defects, including in this plan.** If the code disagrees with the brief, **the code wins** — say so in your report rather than following the brief into a bug.
- **Prove every assertion FAILS before the change.** An assertion nobody has seen fail is not evidence.
- **`fish`'s `math` has no comparison operators.** `math "$a > $b"` is an error, not a boolean. Use `test "$a" -gt "$b"` — fish's `test` handles floats natively.
- **`fish`'s builtin `printf` ignores `--`.** It takes `--` as the format string and discards the rest, silently.
- Pass an explicit **`timeout: 600000`** on any Bash call running the gate; the 120s default silently backgrounds it. **If a call reports it was backgrounded, abandon it and re-run in the foreground** — waiting has stalled seven agents on this project.
- **Never run the suite under a shell `timeout`** — it truncates with no trailer and no visible failures, a false clean.
- Capture FAIL lines with `grep -E '^FAIL'`, never `tail -1`.
- The Bash tool runs **zsh**, not bash.
- **Never `git checkout` to revert a mutation** — restore from a file copy taken immediately before, and `diff` to prove byte-identity.
- **Do not dispatch subagents.**

---

### Task 1: Harmony — hue anchors

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_anchors` immediately after `__tmux_lives_norm360` (`:616-621`), keeping the hue helpers together.
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_norm360 <deg>` → a hue wrapped into `[0,360)`.
- Produces: `__tmux_lives_theme_anchors <hue> <mode>` → 1-4 hue angles, one per line, each already wrapped. Returns nothing (and status 1) for an unknown mode. Tasks 4 consumes it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-tmux-install.fish`, immediately before the final trailer block (`if test $fail -eq 0`). Find it with `grep -n 'ALL PASS' tests/test-tmux-install.fish`.

```fish
# --- v6 harmony: hue anchors ------------------------------------------------
# The v5 relationships (mono/wheat/amber/ember/coral/mint/sage/teal) are all
# signed hue TRAVEL along an arc, so they structurally cannot produce separated
# hue families — measured, 21 of 24 relationship x placement combinations yield
# exactly one family. Triadic and square need hues to JUMP. This is that table.
set -g A6MONO (__tmux_lives_theme_anchors 120 mono)
t "anchors: mono is one hue" 1 (count $A6MONO)
t "anchors: mono returns the seed hue" 120 "$A6MONO[1]"

set -g A6ANA (__tmux_lives_theme_anchors 120 analogous)
t "anchors: analogous is three hues" 3 (count $A6ANA)
t "anchors: the seed hue is ALWAYS anchor one" 120 "$A6ANA[1]"
t "anchors: analogous reaches -30" 90 "$A6ANA[2]"
t "anchors: analogous reaches +30" 150 "$A6ANA[3]"

set -g A6COMP (__tmux_lives_theme_anchors 120 complementary)
t "anchors: complementary is two hues" 2 (count $A6COMP)
t "anchors: complementary is opposite" 300 "$A6COMP[2]"

set -g A6SPLIT (__tmux_lives_theme_anchors 120 split)
t "anchors: split is three hues" 3 (count $A6SPLIT)
t "anchors: split lands at +150" 270 "$A6SPLIT[2]"
t "anchors: split lands at +210" 330 "$A6SPLIT[3]"

set -g A6TRI (__tmux_lives_theme_anchors 120 triadic)
t "anchors: triadic is three hues" 3 (count $A6TRI)
t "anchors: triadic is evenly spaced" 240 "$A6TRI[2]"
t "anchors: triadic wraps the third" 0 "$A6TRI[3]"

set -g A6TET (__tmux_lives_theme_anchors 120 tetradic)
t "anchors: tetradic is four hues" 4 (count $A6TET)
set -g A6SQ (__tmux_lives_theme_anchors 120 square)
t "anchors: square is four hues" 4 (count $A6SQ)
t "anchors: square is evenly spaced" 210 "$A6SQ[2]"

# wrap-around must be handled, not left negative or past 360
set -g A6WRAP (__tmux_lives_theme_anchors 10 analogous)
t "anchors: a negative offset wraps into range" 340 "$A6WRAP[2]"
set -g A6WRAP2 (__tmux_lives_theme_anchors 350 square)
t "anchors: an over-360 offset wraps into range" 80 "$A6WRAP2[2]"

t "anchors: an unknown mode returns nothing" 0 (count (__tmux_lives_theme_anchors 120 nonsense))
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' | head -20`

Expected: every `anchors:` assertion fails, because the function does not exist. Confirm the trailer reports `FAILED (n)`, not `ALL PASS`.

- [ ] **Step 3: Implement**

Insert after `__tmux_lives_norm360`'s closing `end` in `conf.d/tmux-lives-install.fish`:

```fish
function __tmux_lives_theme_anchors --argument-names hue mode --description 'v6 harmony: a seed hue + a harmony mode -> 1-4 hue angles, wrapped into [0,360). Hues ONLY — no lightness, no chroma; those are the ramps job. The seeds own hue is always anchor one in every mode, so the seed anchors the palette rather than merely influencing it. This replaces the v5 signed-travel relationships, which walk an arc and therefore cannot produce SEPARATED hue families: triadic and square need hues to jump. Unknown mode -> nothing, status 1.'
    set -l offs
    switch "$mode"
        case mono
            set offs 0
        case analogous
            # 0 first, not -30: the seed must be anchor ONE in every mode.
            set offs 0 -30 30
        case complementary
            set offs 0 180
        case split
            set offs 0 150 210
        case triadic
            set offs 0 120 240
        case tetradic
            set offs 0 60 180 240
        case square
            set offs 0 90 180 270
        case '*'
            return 1
    end
    for o in $offs
        __tmux_lives_norm360 (math "$hue + $o")
    end
end
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'` — expect no output.

- [ ] **Step 5: Mutation-check**

Take a file copy first: `cp conf.d/tmux-lives-install.fish /tmp/t1.fish`.

Change `analogous`'s offsets from `0 -30 30` to `-30 0 30`. Run the suite. **Expect `anchors: the seed hue is ALWAYS anchor one` to FAIL.** This is the one property a careless reordering would silently break. Restore from the copy and `diff` to prove byte-identity.

- [ ] **Step 6: Full gate and commit**

```bash
for m in "" "--no-config"; do for t in tests/test-*.fish; do out=$(fish $m "$t" </dev/null 2>&1); printf "%-32s %-11s %s\n" "$(basename $t)" "${m:-plain}" "$(echo "$out" | tail -1)"; echo "$out" | grep -E "^FAIL" | sed "s/^/   >> /"; done; done
```

Expect 9 suites × 2 modes `ALL PASS`, delta still 1. Pass `timeout: 600000`.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v6 harmony — hue anchors

The full classical set, hues only. The seed is anchor one in every mode
so it anchors the palette rather than merely influencing it. Replaces
signed hue travel, which walks an arc and cannot separate hue families."
```

---

### Task 2: Ramp — the value structure

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_ramp` immediately after `__tmux_lives_theme_anchors`.
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `__tmux_lives_theme_ramp <seedL> <Lspan> <peakC> <peakPos> <n>` → `n` lines, each `"<L> <C>"` space-separated, ordered dark to light. Task 4 consumes it.

**Why this task is the point of the whole cycle.** Measured on the v5 engine across all 24 relationship × placement combinations at one seed: peak chroma varies by **0.001** (0.084–0.085) and lightness span is **byte-identical** at 0.47. This function is where that becomes a real range.

- [ ] **Step 1: Write the failing tests**

```fish
# --- v6 ramp: lightness span, peak chroma, peak position ---------------------
# These three are INDEPENDENT dimensions, not one "intensity" axis. Measured on
# the users 16 coolors palettes: peakC vs Lspan r = -0.29, peakC vs peakPos
# +0.25, Lspan vs peakPos +0.06. No evidence any pair moves together.
set -g R6 (__tmux_lives_theme_ramp 0.50 0.40 0.15 0.5 7)
t "ramp: returns n pairs" 7 (count $R6)

set -g R6L (for p in $R6; echo (string split ' ' -- $p)[1]; end)
set -g R6C (for p in $R6; echo (string split ' ' -- $p)[2]; end)

# lightness is monotonic dark -> light
set -g R6MONO 1
for i in (seq 2 7)
    set -g R6PREV (math $i - 1)
    test "$R6L[$i]" -gt "$R6L[$R6PREV]"; or set -g R6MONO 0
end
t "ramp: lightness is monotonic" 1 $R6MONO

# the span is honoured
t "ramp: span is honoured" 1 (test (math "abs(($R6L[7] - $R6L[1]) - 0.40)") -lt 0.01; and echo 1; or echo 0)

# the seeds own L falls INSIDE the window — this is how the seed stops being
# hue-only, which is the v5 defect this whole cycle exists to fix
t "ramp: the seed's L is inside the window" 1 (test "$R6L[1]" -le 0.50 -a "$R6L[7]" -ge 0.50; and echo 1; or echo 0)

# chroma peaks where peakPos asks
set -g R6MAXI 1
for i in (seq 2 7)
    test "$R6C[$i]" -gt "$R6C[$R6MAXI]"; and set -g R6MAXI $i
end
t "ramp: chroma peaks mid-ramp when asked to" 4 $R6MAXI
t "ramp: the peak reaches peakC" 1 (test (math "abs($R6C[$R6MAXI] - 0.15)") -lt 0.005; and echo 1; or echo 0)

set -g R6LO (__tmux_lives_theme_ramp 0.50 0.40 0.15 0.0 7)
set -g R6LOC (for p in $R6LO; echo (string split ' ' -- $p)[2]; end)
t "ramp: peakPos 0 peaks at the dark end" 1 (test "$R6LOC[1]" -gt "$R6LOC[7]"; and echo 1; or echo 0)
set -g R6HI (__tmux_lives_theme_ramp 0.50 0.40 0.15 1.0 7)
set -g R6HIC (for p in $R6HI; echo (string split ' ' -- $p)[2]; end)
t "ramp: peakPos 1 peaks at the light end" 1 (test "$R6HIC[7]" -gt "$R6HIC[1]"; and echo 1; or echo 0)

# the three dimensions must be INDEPENDENT: changing one must not move another
set -g R6A (__tmux_lives_theme_ramp 0.50 0.40 0.05 0.5 7)
set -g R6B (__tmux_lives_theme_ramp 0.50 0.40 0.25 0.5 7)
set -g R6AL (for p in $R6A; echo (string split ' ' -- $p)[1]; end)
set -g R6BL (for p in $R6B; echo (string split ' ' -- $p)[1]; end)
t "ramp: changing peak chroma does NOT move lightness" "$R6AL" "$R6BL"
set -g R6C1 (__tmux_lives_theme_ramp 0.50 0.20 0.15 0.5 7)
set -g R6C2 (__tmux_lives_theme_ramp 0.50 0.70 0.15 0.5 7)
set -g R6C1C (for p in $R6C1; echo (string split ' ' -- $p)[2]; end)
set -g R6C2C (for p in $R6C2; echo (string split ' ' -- $p)[2]; end)
t "ramp: changing lightness span does NOT move chroma" "$R6C1C" "$R6C2C"

# clamping: a window that would run off either end shifts rather than shrinking
set -g R6DARK (__tmux_lives_theme_ramp 0.10 0.60 0.15 0.5 7)
set -g R6DL (for p in $R6DARK; echo (string split ' ' -- $p)[1]; end)
t "ramp: a dark seed's window stays in gamut" 1 (test "$R6DL[1]" -ge 0.05; and echo 1; or echo 0)
t "ramp: ...and keeps its full span" 1 (test (math "abs(($R6DL[7] - $R6DL[1]) - 0.60)") -lt 0.01; and echo 1; or echo 0)
set -g R6LIGHT (__tmux_lives_theme_ramp 0.95 0.60 0.15 0.5 7)
set -g R6GL (for p in $R6LIGHT; echo (string split ' ' -- $p)[1]; end)
t "ramp: a light seed's window stays in gamut" 1 (test "$R6GL[7]" -le 0.97; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify they fail**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' | head -20`. Every `ramp:` assertion fails.

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_theme_ramp --argument-names seedL Lspan peakC peakPos n --description 'v6 value structure: <n> (L, C) pairs, dark to light, one per line as "<L> <C>". Lightness spreads across a window of width <Lspan> positioned so the SEEDS OWN L falls inside it — that is how the seed stops being hue-only, which is the v5 defect this replaces (there, seed chroma and lightness were discarded entirely and every saturated seed converged on the same bar). Chroma peaks at <peakPos> (0 = darkest end, 1 = lightest) with maximum <peakC>, falling toward a floor away from the peak. The three are INDEPENDENT by design and by test: measured on 16 real palettes, peakC vs Lspan r = -0.29, so collapsing them into one "intensity" axis would be wrong.'
    test "$n" -lt 2; and return 1
    # Centre the window on the seed, then SHIFT (never shrink) to stay in gamut,
    # so a dark or light seed keeps the span the recipe asked for.
    set -l half (math "$Lspan / 2")
    set -l lo (math "$seedL - $half")
    set -l hi (math "$seedL + $half")
    if test "$lo" -lt 0.05
        set hi (math "$hi + (0.05 - $lo)")
        set lo 0.05
    end
    if test "$hi" -gt 0.97
        set lo (math "$lo - ($hi - 0.97)")
        set hi 0.97
    end
    test "$lo" -lt 0.05; and set lo 0.05
    set -l step (math "($hi - $lo) / ($n - 1)")
    # Chroma floor: away from the peak the ramp relaxes toward this rather than
    # to zero, so a muted recipe still reads as tinted rather than grey.
    set -l cfloor 0.012
    set -l far (math "max($peakPos, 1 - $peakPos)")
    test "$far" -lt 0.0001; and set far 1
    for i in (seq $n)
        set -l L (math "$lo + $step * ($i - 1)")
        set -l tpos (math "($i - 1) / ($n - 1)")
        set -l d (math "abs($tpos - $peakPos)")
        set -l frac (math "1 - ($d / $far)")
        test "$frac" -lt 0; and set frac 0
        set -l C (math "$cfloor + ($peakC - $cfloor) * $frac")
        test "$C" -lt 0; and set C 0
        printf '%s %s\n' $L $C
    end
end
```

- [ ] **Step 4: Run and verify they pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'` — expect no output.

- [ ] **Step 5: Mutation-check the independence claim**

`cp conf.d/tmux-lives-install.fish /tmp/t2.fish` first.

Make chroma depend on the span — change `set -l C (math "$cfloor + ($peakC - $cfloor) * $frac")` to `set -l C (math "($cfloor + ($peakC - $cfloor) * $frac) * $Lspan")`. Run the suite. **Expect `ramp: changing lightness span does NOT move chroma` to FAIL.** Restore and `diff`.

This is the assertion that stops the three dimensions quietly re-coupling, which is exactly how v5's knobs became inert.

- [ ] **Step 6: Full gate and commit**

Gate as Task 1 Step 6, `timeout: 600000`.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v6 ramp — independent lightness span, peak chroma, peak position

Where muted-versus-radical actually lives. The window is positioned so
the seed's own L falls inside it, so the seed contributes more than hue
for the first time. The three dimensions are independent by test, not
just by intent — v5's four knobs were accepted, stored, displayed and
never reached the engine."
```

---

### Task 3: Arrangement — roles, and the one hard rule

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_arrange` immediately after `__tmux_lives_theme_ramp`.
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 directly; it takes already-built hexes.
- Produces:
  - `__tmux_lives_theme_arrangements` → the six pattern names, one per line, in a fixed order.
  - `__tmux_lives_theme_arrange <pattern> <hex1> … <hex7>` → the same seven hexes reordered into role order `bar sep tabs active windows cap text`, one per line, with the text-contrast floor enforced. Unknown pattern → nothing, status 1.
- Task 4 consumes both.

**The six patterns.** Inputs arrive dark-to-light (ramp order). Each pattern is a list of seven ramp indices; position `i` in the list is the ramp index that becomes role `i`, where roles are `bar sep tabs active windows cap text` in that order.

| pattern | indices | intent |
|---|---|---|
| `deep` | `1 4 2 6 5 3 7` | bar darkest, tabs just above it, text lightest |
| `bright` | `7 4 6 2 3 5 1` | inverted — a light bar with dark text |
| `centre` | `4 2 3 6 5 7 1` | bar mid-ramp, the extremes go to cap and text |
| `split` | `1 3 6 4 5 2 7` | bar dark and tabs light — the two large areas maximally separated |
| `stack` | `2 5 3 6 4 7 1` | bar and tabs adjacent — a tight dominant pair |
| `accent` | `3 5 4 6 2 7 1` | cap takes the extreme; both large areas sit mid-ramp |

Every list is a permutation of `1..7`; Step 1 asserts that rather than trusting the table.

- [ ] **Step 1: Write the failing tests**

```fish
# --- v6 arrangement: ramp positions -> roles ---------------------------------
# Roles, in order: bar sep tabs active windows cap text.
set -g A6PATS (__tmux_lives_theme_arrangements)
t "arrange: there are exactly six patterns" 6 (count $A6PATS)

# every pattern must be a genuine permutation of 1..7 — a duplicated index would
# silently drop a colour and repeat another, which looks plausible on screen
set -g A6PERMOK 1
for p in $A6PATS
    set -l out (__tmux_lives_theme_arrange $p '#111111' '#222222' '#333333' '#444444' '#555555' '#666666' '#777777')
    test (count $out) -eq 7; or set -g A6PERMOK 0
    test (count (printf '%s\n' $out | sort -u)) -eq 7; or set -g A6PERMOK 0
end
t "arrange: every pattern is a permutation, no colour dropped or repeated" 1 $A6PERMOK

# THE one hard rule: text must clear a lightness-contrast floor against bar.
# Fed seven near-identical colours, no arrangement can satisfy it naturally, so
# this proves the floor is ENFORCED rather than merely usually true.
set -g A6FLAT (__tmux_lives_theme_arrange deep '#303030' '#313131' '#323232' '#333333' '#343434' '#353535' '#363636')
t "arrange: a flat input still returns seven" 7 (count $A6FLAT)

set -g A6FLOOROK 1
for p in $A6PATS
    set -l out (__tmux_lives_theme_arrange $p '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac')
    set -l lbar (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l ltxt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[7]))
    test (math "abs($ltxt[1] - $lbar[1])") -ge 0.40; or set -g A6FLOOROK 0
end
t "arrange: text clears the contrast floor in EVERY pattern" 1 $A6FLOOROK

t "arrange: an unknown pattern returns nothing" 0 (count (__tmux_lives_theme_arrange nonsense '#111111' '#222222' '#333333' '#444444' '#555555' '#666666' '#777777'))

# the patterns must actually differ — six names mapping to one order would be
# the v5 failure in miniature
set -g A6DISTINCT (for p in $A6PATS; __tmux_lives_theme_arrange $p '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac' | string join ','; end | sort -u | count)
t "arrange: the six patterns produce six distinct orderings" 6 $A6DISTINCT
```

- [ ] **Step 2: Run and verify they fail**

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_theme_arrangements --description 'v6: the six arrangement pattern names, fixed order. A fixed enumerable set rather than one of 7! orderings, so the roll space is a known size and every pattern is testable.'
    printf '%s\n' deep bright centre split stack accent
end

function __tmux_lives_theme_arrange --argument-names pattern --description 'v6: seven ramp-ordered hexes (dark to light) in $argv[2..8] -> the same seven reordered into role order bar sep tabs active windows cap text. Each pattern is a permutation of ramp indices; position i names the ramp index that becomes role i. Enforces the ONE hard rule — text must clear a 0.40 OKLCH lightness gap against bar — by swapping text to whichever remaining colour is furthest from bar when the pattern alone does not satisfy it. Nothing else is constrained: over-constraining is what collapsed v5 to a single destination. Unknown pattern -> nothing, status 1.'
    set -l hexes $argv[2..8]
    test (count $hexes) -eq 7; or return 1
    set -l idx
    switch "$pattern"
        case deep
            set idx 1 4 2 6 5 3 7
        case bright
            set idx 7 4 6 2 3 5 1
        case centre
            set idx 4 2 3 6 5 7 1
        case split
            set idx 1 3 6 4 5 2 7
        case stack
            set idx 2 5 3 6 4 7 1
        case accent
            set idx 3 5 4 6 2 7 1
        case '*'
            return 1
    end
    set -l out
    for i in $idx
        set -a out $hexes[$i]
    end
    # The floor. Role 1 is bar, role 7 is text.
    set -l lb (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l lt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[7]))
    if test (math "abs($lt[1] - $lb[1])") -lt 0.40
        # Find the colour furthest in lightness from bar and swap it into text,
        # preserving the permutation (the displaced colour takes text's old slot)
        # so no colour is dropped or duplicated.
        set -l best 7
        set -l bestd (math "abs($lt[1] - $lb[1])")
        for i in (seq 2 6)
            set -l li (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$i]))
            set -l d (math "abs($li[1] - $lb[1])")
            if test "$d" -gt "$bestd"
                set best $i
                set bestd $d
            end
        end
        if test $best -ne 7
            set -l tmp $out[7]
            set out[7] $out[$best]
            set out[$best] $tmp
        end
    end
    printf '%s\n' $out
end
```

- [ ] **Step 4: Run and verify they pass**

- [ ] **Step 5: Mutation-check the floor**

`cp conf.d/tmux-lives-install.fish /tmp/t3.fish` first.

Delete the entire `if test (math "abs($lt[1] - $lb[1])") -lt 0.40 … end` block. Run the suite. **Expect `arrange: text clears the contrast floor in EVERY pattern` to FAIL.** Restore and `diff`.

Then re-take the copy and change `deep`'s indices from `1 4 2 6 5 3 7` to `1 4 2 6 5 3 3`. **Expect `arrange: every pattern is a permutation` to FAIL.** Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

Gate as Task 1 Step 6, `timeout: 600000`.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v6 arrangement — six patterns, one hard rule

Six named permutations of ramp position onto role, so arrangement is a
free source of variety rather than 7! orderings. Text must clear a 0.40
lightness gap against bar; nothing else is constrained, because
over-constraining is what collapsed v5 to a single destination."
```

---

### Task 4: Render — compose the three stages

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_render` immediately after `__tmux_lives_theme_arrange`.
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_anchors`, `__tmux_lives_theme_ramp`, `__tmux_lives_theme_arrange` from Tasks 1-3; `__tmux_lives_hex_to_rgb01`, `__tmux_lives_rgb_to_oklch`, `__tmux_lives_oklch_hex` from the existing OKLCH core.
- Produces: `__tmux_lives_theme_render <seedHex> <mode> <Lspan> <peakC> <peakPos> <arrangement>` → seven hexes in role order `bar sep tabs active windows cap text`, one per line. Non-hex seed, unknown mode or unknown arrangement → nothing. Task 5 and the surface plan consume it.

**Hue distribution.** Ramp positions map onto anchors **round-robin**: with four anchors the seven positions cycle `1,2,3,4,1,2,3`. Contiguous blocks were rejected — round-robin guarantees adjacent lightnesses carry *different* hues, which is what makes a multi-hue palette read as one palette rather than three separate ramps. `mono` has one anchor and every position shares it, correctly and with no special case.

- [ ] **Step 1: Write the failing tests**

```fish
# --- v6 render: the three stages composed -----------------------------------
set -g V6 (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep)
t "render: returns seven role hexes" 7 (count $V6)
set -g V6HEXOK 1
for h in $V6
    string match -qr '^#[0-9a-f]{6}$' -- $h; or set -g V6HEXOK 0
end
t "render: every role is a valid lowercase hex" 1 $V6HEXOK

t "render: a non-hex seed returns nothing" 0 (count (__tmux_lives_theme_render 'notacolour' mono 0.40 0.15 0.5 deep))
t "render: an unknown mode returns nothing" 0 (count (__tmux_lives_theme_render '#5f772b' nonsense 0.40 0.15 0.5 deep))
t "render: an unknown arrangement returns nothing" 0 (count (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 nonsense))

# THE headline: the seed's own chroma and lightness must now reach the output.
# In v5 they were discarded — seeds #80ff00 (C 0.264) and #7a00ff (C 0.293) both
# produced a bar at C 0.063. Only hue survived.
set -g V6A (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep)
set -g V6B (__tmux_lives_theme_render '#5f7fbb' mono 0.40 0.15 0.5 deep)
t "render: a different seed HUE changes the palette" 1 (test "$V6A" != "$V6B"; and echo 1; or echo 0)
set -g V6DARK (__tmux_lives_theme_render '#1a2010' mono 0.40 0.15 0.5 deep)
set -g V6LIGHT (__tmux_lives_theme_render '#dfe8c8' mono 0.40 0.15 0.5 deep)
t "render: a different seed LIGHTNESS changes the palette" 1 (test "$V6DARK" != "$V6LIGHT"; and echo 1; or echo 0)

# the recipe fields must each move the output
t "render: peak chroma moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.04 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.24 0.5 deep | string join ','); and echo 1; or echo 0)
t "render: lightness span moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.20 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.70 0.15 0.5 deep | string join ','); and echo 1; or echo 0)
t "render: peak position moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.0 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 1.0 deep | string join ','); and echo 1; or echo 0)
t "render: arrangement moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 split | string join ','); and echo 1; or echo 0)
t "render: mode moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' triadic 0.40 0.15 0.5 deep | string join ','); and echo 1; or echo 0)

# round-robin distribution: with a multi-hue mode, adjacent ramp positions must
# carry DIFFERENT hues, which is what makes a multi-hue palette cohere
set -g V6TRI (__tmux_lives_theme_render '#5f772b' triadic 0.40 0.18 0.5 deep)
set -g V6HUES (for h in $V6TRI; set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h)); echo $o[3]; end)
t "render: a triadic palette carries more than one hue" 1 (test (count (printf '%s\n' $V6HUES | sort -u)) -gt 1; and echo 1; or echo 0)

# determinism — the same recipe must always render the same palette, or a saved
# scheme could not be trusted
t "render: the same recipe renders identically twice" (__tmux_lives_theme_render '#5f772b' square 0.55 0.19 0.3 accent | string join ',') (__tmux_lives_theme_render '#5f772b' square 0.55 0.19 0.3 accent | string join ',')
```

- [ ] **Step 2: Run and verify they fail**

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_theme_render --argument-names seedHex mode Lspan peakC peakPos arrangement --description 'v6 entry point: a seed plus a RECIPE (mode, lightness span, peak chroma, peak position, arrangement) -> seven role hexes in order bar sep tabs active windows cap text. Composes the three pure stages: anchors gives 1-4 hues, ramp gives seven (L, C) pairs, arrange maps them onto roles under the text-contrast floor. Ramp positions take anchors ROUND-ROBIN (four anchors -> 1,2,3,4,1,2,3) so adjacent lightnesses carry different hues — contiguous blocks would read as several separate ramps rather than one palette. mono has a single anchor and needs no special case. Deterministic: the same recipe always renders the same palette, which is what lets a scheme be stored as a recipe rather than as seven hexes. Non-hex seed / unknown mode / unknown arrangement -> nothing.'
    set -l rgb (__tmux_lives_hex_to_rgb01 "$seedHex")
    test (count $rgb) -eq 3; or return
    set -l s (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    test (count $s) -eq 3; or return
    set -l anchors (__tmux_lives_theme_anchors $s[3] "$mode")
    test (count $anchors) -ge 1; or return
    set -l pairs (__tmux_lives_theme_ramp $s[1] "$Lspan" "$peakC" "$peakPos" 7)
    test (count $pairs) -eq 7; or return
    set -l na (count $anchors)
    set -l hexes
    for i in (seq 7)
        set -l lc (string split ' ' -- $pairs[$i])
        # round-robin: 1,2,..,na,1,2,..
        set -l ai (math "(($i - 1) % $na) + 1")
        set -a hexes (__tmux_lives_oklch_hex $lc[1] $lc[2] $anchors[$ai])
    end
    __tmux_lives_theme_arrange "$arrangement" $hexes
end
```

- [ ] **Step 4: Run and verify they pass**

- [ ] **Step 5: Mutation-check round-robin**

`cp conf.d/tmux-lives-install.fish /tmp/t4.fish` first.

Replace the round-robin index with a constant first anchor: change `set -l ai (math "(($i - 1) % $na) + 1")` to `set -l ai 1`. Run the suite. **Expect `render: a triadic palette carries more than one hue` to FAIL** — this is the mutation that silently turns every multi-hue mode back into mono, which is precisely the v5 collapse. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

Gate as Task 1 Step 6, `timeout: 600000`.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v6 render — compose harmony, ramp and arrangement

A seed plus a recipe renders seven roles deterministically, which is
what lets a scheme be stored as a recipe rather than as seven hexes:
change the seed and every saved scheme re-derives.

Ramp positions take hue anchors round-robin so adjacent lightnesses
carry different hues. Not wired to anything yet — v5 stays live."
```

---

### Task 5: The range guard — prove the collapse cannot recur

**Files:**
- Test: `tests/test-tmux-install.fish` only. **No production change in this task.**

**Interfaces:**
- Consumes: `__tmux_lives_theme_render` from Task 4.
- Produces: nothing consumed downstream. This is the regression guard for the actual failure.

**Why this task exists and is not optional.** The v5 engine's defect was invisible to a 708-assertion suite: across all 24 relationship × placement combinations, peak chroma varied by **0.001** and lightness span was **byte-identical** at 0.47. Every existing test passed. No assertion anywhere measured the engine's expressive *range*, so the collapse was undetectable. This task is that assertion.

- [ ] **Step 1: Write the failing tests**

```fish
# --- v6 range guard ---------------------------------------------------------
# THE regression guard for the actual v5 failure. Measured on v5 across all 24
# relationship x placement combinations at one seed: peak chroma spanned 0.001
# (0.084-0.085) and lightness span was byte-identical at 0.47-0.47. The whole
# 708-assertion suite passed. Nothing measured RANGE, so nothing could see it.
#
# Sample a spread of recipes and assert the OUTPUT ENVELOPE is genuinely wide.
# The users own liked palettes span peak chroma 0.044-0.247 and lightness span
# 0.20-0.69; the engine must be able to cover that, or it has the same defect
# wearing different code.
function __t6_env --description 'render a recipe and print "<peakC> <Lspan> <huefamilies>" measured back out of the seven hexes'
    set -l pal (__tmux_lives_theme_render $argv)
    test (count $pal) -eq 7; or begin; echo "0 0 0"; return; end
    set -l Ls; set -l Cs; set -l Hs
    for h in $pal
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        set -a Ls $o[1]; set -a Cs $o[2]; set -a Hs $o[3]
    end
    set -l maxC 0
    for c in $Cs; test "$c" -gt "$maxC"; and set maxC $c; end
    set -l minL 1; set -l maxL 0
    for l in $Ls
        test "$l" -lt "$minL"; and set minL $l
        test "$l" -gt "$maxL"; and set maxL $l
    end
    # Hue families need a TOLERANCE, not distinct rounded hues. Measured: mono
    # reports FOUR distinct rounded hues, because every colour round-trips
    # through sRGB and the gamut clamp shifts each one slightly. Cluster with a
    # 25-degree gap instead — that gives mono 1, analogous 3, triadic 3,
    # square 4, which is what the modes actually mean.
    set -l chro
    for i in (seq 7)
        test "$Cs[$i]" -ge 0.020; and set -a chro $Hs[$i]
    end
    set -l fam 0
    if test (count $chro) -gt 0
        set -l sorted (printf '%s\n' $chro | sort -g)
        set fam 1
        for i in (seq 2 (count $sorted))
            # Capture the index FIRST: a command substitution inside a quoted
            # list subscript is a fish "Invalid index value" ERROR. This repo
            # bans the shape and I tripped it writing this very helper.
            set -l prev (math $i - 1)
            set -l gap (math "$sorted[$i] - $sorted[$prev]")
            test "$gap" -gt 25; and set fam (math $fam + 1)
        end
    end
    printf '%s %s %s\n' $maxC (math "$maxL - $minL") $fam
end

# NB the VIVID probe uses a PURPLE seed deliberately. Peak chroma is capped by
# the sRGB gamut and that cap is hue-dependent: requesting 0.26 yields 0.260 at
# purple, 0.254 at red and 0.240 at pink, but only 0.153 at green and 0.140 at
# cyan. peakC is a REQUEST, not a guarantee. A green seed here would make the
# high-end assertion unsatisfiable through no fault of the engine — which is
# exactly what the first draft of this plan did.
set -g E6MUTED (string split ' ' -- (__t6_env '#5f772b' mono 0.25 0.04 0.5 deep))
set -g E6VIVID (string split ' ' -- (__t6_env '#7a00ff' triadic 0.65 0.26 0.5 accent))

t "range: a muted recipe stays muted" 1 (test "$E6MUTED[1]" -lt 0.08; and echo 1; or echo 0)
t "range: a vivid recipe actually reaches high chroma" 1 (test "$E6VIVID[1]" -gt 0.20; and echo 1; or echo 0)
t "range: peak chroma spans a REAL interval, not v5's 0.001" 1 (test (math "$E6VIVID[1] - $E6MUTED[1]") -gt 0.10; and echo 1; or echo 0)

t "range: a narrow recipe has a narrow lightness span" 1 (test "$E6MUTED[2]" -lt 0.35; and echo 1; or echo 0)
t "range: a wide recipe has a wide lightness span" 1 (test "$E6VIVID[2]" -gt 0.55; and echo 1; or echo 0)
t "range: lightness span VARIES, unlike v5's identical 0.47" 1 (test (math "$E6VIVID[2] - $E6MUTED[2]") -gt 0.20; and echo 1; or echo 0)

t "range: mono yields one hue family" 1 "$E6MUTED[3]"
set -g E6SQ (string split ' ' -- (__t6_env '#5f772b' square 0.70 0.19 0.3 split))
t "range: square yields four hue families" 4 "$E6SQ[3]"
t "range: triadic yields more than one" 1 (test "$E6VIVID[3]" -gt 1; and echo 1; or echo 0)

# The envelope must COVER the neighbourhood of the user's liked palettes, which
# span peak chroma 0.044-0.247 and lightness span 0.20-0.69. Held as a holdout,
# never as training data: the question they answered was "do I like these
# colours", not "should this be a scheme".
t "range: the envelope reaches the low end of the users liked palettes" 1 (test "$E6MUTED[1]" -le 0.06; and echo 1; or echo 0)
t "range: the envelope reaches the high end of the users liked palettes" 1 (test "$E6VIVID[1]" -ge 0.22; and echo 1; or echo 0)

# The gamut cap is hue-dependent and that is CORRECT — sRGB cannot hold high
# chroma at every hue. Pin it so nobody later "fixes" the green case by
# uncapping the clamp and shipping out-of-gamut colours.
set -g E6GREEN (string split ' ' -- (__t6_env '#5f772b' mono 0.45 0.26 0.5 deep))
set -g E6PURPLE (string split ' ' -- (__t6_env '#7a00ff' mono 0.45 0.26 0.5 deep))
t "range: the same requested chroma is gamut-capped differently by hue" 1 (test (math "$E6PURPLE[1] - $E6GREEN[1]") -gt 0.05; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they FAIL against v5's shape**

These assertions pass against a correct Task 4. To prove they are not decorative, verify they would have caught v5. Add this temporary probe to a scratch file (**not** the suite) and run it:

```fish
# /tmp/v5check.fish
set -g __fish_config_dir /home/bitsaver/.config/fish
source conf.d/tmux-lives-install.fish 2>/dev/null
for combo in 'mono bar' 'coral cap' 'teal tabs'
    set -l f (string split ' ' -- $combo)
    set -l pal (__tmux_lives_theme_palette '#5f772b' $f[1] $f[2] derived 0)
    set -l maxC 0; set -l minL 1; set -l maxL 0
    for h in $pal
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        test "$o[2]" -gt "$maxC"; and set maxC $o[2]
        test "$o[1]" -lt "$minL"; and set minL $o[1]
        test "$o[1]" -gt "$maxL"; and set maxL $o[1]
    end
    printf 'v5 %-12s peakC %s  Lspan %s\n' "$combo" $maxC (math "$maxL - $minL")
end
```

Run: `fish /tmp/v5check.fish`. Expected: peak chroma around 0.084-0.085 and lightness span 0.47 for every combination — well inside the bounds the new assertions reject. **Record the output verbatim in your report**; it is the evidence that the guard discriminates. Then `rm /tmp/v5check.fish`.

- [ ] **Step 3: Run the suite and verify the guard passes on v6**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'` — expect no output.

If any `range:` assertion fails, **that is the plan's most important possible outcome**: it means the v6 engine has the same collapse and the surface plan must not be started. Report the measured numbers rather than adjusting the thresholds to pass.

- [ ] **Step 4: Mutation-check the guard**

`cp conf.d/tmux-lives-install.fish /tmp/t5.fish` first.

Re-create the v5 collapse: in `__tmux_lives_theme_ramp`, replace `set -l C (math "$cfloor + ($peakC - $cfloor) * $frac")` with `set -l C 0.084`. Run the suite. **Expect the peak-chroma range assertions to FAIL.** Restore and `diff`.

Then re-take the copy and pin the span: replace `set -l half (math "$Lspan / 2")` with `set -l half 0.235`. **Expect the lightness-span assertions to FAIL.** Restore and `diff`.

Both mutations reproduce v5's exact measured behaviour. If either leaves the suite green, the guard is decorative — say so plainly rather than proceeding.

- [ ] **Step 5: Full gate and commit**

Gate as Task 1 Step 6, `timeout: 600000`.

```bash
git add tests/test-tmux-install.fish
git commit -m "test(theme): pin the v6 engine's expressive range

v5's defect was invisible to a 708-assertion suite: peak chroma varied
by 0.001 across all 24 relationship x placement combinations and
lightness span was byte-identical at 0.47. Nothing measured range, so
nothing could see it.

Both mutations that reproduce v5's exact numbers now fail this guard."
```

---

## Verification before calling this done

Invoke `superpowers:verification-before-completion`. Evidence, not assertions:

- 9 suites × 2 modes, all `ALL PASS`, FAIL lines captured. `test-tmux-install.fish` is at 708/707 before this plan; report the new counts and confirm the delta is still exactly 1.
- All six mutation results verbatim, each with a post-restore `diff` shown empty.
- The v5 probe output from Task 5 Step 2, verbatim.
- Confirmation that `__tmux_lives_theme_palette` and the rest of the v5 cluster are **byte-identical** to their state at the plan's base commit: `git diff <base> -- conf.d/tmux-lives-install.fish | grep -c '^-'` should show only removals that are part of the additions' context, and a direct `functions`-level comparison of `__tmux_lives_theme_palette` should be unchanged.

## What this plan does NOT do, and what comes next

Not built here: the catalog of recipes, the curated shortlist, `setup theme`'s CLI surface, the fragment's call site, `__tmux_lives_migrate_v6`, the picker's roll, and the deletion of v5. Those are the surface plan, written after this core's range guard passes.

**The manual check worth doing before starting the surface plan** — it needs a human eye and is not automatable: render a spread of v6 recipes at the user's own seed and look at whether the muted end still produces the dim style they explicitly like, and whether the vivid end reaches something they would call radical. The engine must do **both**. If it can only do one, the ramp bounds need revisiting before anything is wired.
