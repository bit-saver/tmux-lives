# Picker Colour Order (Option A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The theme picker's `o` colour ordering reads as a gradient — hue family first (the seed's own family kept together), lightest to darkest inside each family, near-greys last — and costs a sixth of what it costs today.

**Architecture:** Only `__tcz_thp_sortkey` changes shape: instead of a 7-block key built from every role, the key is built from the `tabs` role alone — group (coloured / grey / unusable), then a 30° hue bucket centred on the seed, then lightness descending. `__tcz_thp_order` keeps its contract (1-based indices, stable, ties on original index) and its caller in `__tcz_theme_picker` is untouched.

**Tech Stack:** fish 4.7, the repo's `tests/test-*.fish` gate.

**Spec:** none — a user decision plus controller measurement, below.

## Evidence and decision (controller, 2026-09-14/15)

- The user asked why `o` shows no gradient. Measured at their seed `#78b34c`: the current key is tabs-hue-first but compares hue at 0.001° precision, so the lightness tie-breaker never runs; families arrive in coarse hue steps with light and dark interleaved, and because the hue distance runs 0°→360° clockwise from the seed, the seed's own family splits between the top (0.0–0.5°) and the bottom (359.7–360.0°) of the list.
- The user reviewed three orderings rendered as real tab-colour strips and chose **Option A**: hue family, then light → dark, near-greys grouped last.
- **Cost, measured on rocket** (fish 4.7, 42-scheme catalog, seed `#78b34c`): `__tcz_thp_order` takes **363 ms**, of which `__tcz_thp_sortkey` is **349 ms** — it converts 7 hexes per palette (294 OKLCH conversions). Converting only the `tabs` hex of each palette takes **61 ms**. The order is recomputed on every list rebuild (`__tcz_thp_reload`: opening the picker, `o`, `m`, `M`, applying a seed), so this is a per-rebuild cost on a path the user reports as laggy.
- Every catalog `tabs` hue sits at a harmony anchor offset (a multiple of 30° from the seed), so a 30° bucket centred on the seed puts each family in exactly one bucket.

## Global Constraints

- **Never deploy.** No edits under `~/.config/fish`, `~/.tmux.conf`, no `set -U`. Commit on the branch; the user runs `fisher update`.
- **Zero new files** in `conf.d/` or `functions/`.
- `__tcz_thp_order`'s contract is unchanged: 1-based indices, one per input palette, complete permutation, stable (ties break on the original index). Its caller applies the permutation to five index-parallel arrays and refuses a short permutation — do not change that.
- **Tests first**: every new assertion is shown FAILING against the pre-fix code; paste the FAIL lines verbatim.
- **Foreground suites, explicit `timeout: 600000`**, never `run_in_background`, never a shell `timeout`; if a call comes back backgrounded, abandon it and re-run in the foreground. Filter with `grep -E '^FAIL|ALL PASS|SOME FAILED'`.
- **Capture-first** before `t`; a fish function cannot see its caller's `set -l` locals.
- Never `git checkout`/`git stash` to undo experiments; copy the file, restore from the copy, prove with `diff`.
- The Bash tool runs **zsh**: quote args starting with `=`; non-matching globs abort; loops in zsh syntax or via fish.
- `tests/test-tmux-popup.fish` carries a known flaky wall-clock assertion ("truncate heavy colored line is fast"); it fails ~2 of 3 runs on `main` too. Re-run once and report both runs; it is not yours to fix.
- Commits: conventional, no attribution trailer.
- **Briefs in this repo have repeatedly contained defects. If the code disagrees with this plan, the code wins — say so in your report with evidence.**

---

### Task 1: Option A sort key

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_sortkey` (~`:1846-1870`) and its docstring; `__tcz_thp_order`'s docstring if it describes the key's shape (~`:1872`).
- Test: `tests/test-tmux-categorize.fish` — the `T6` ordering block (~`:8845-8885`), plus any later assertion that depends on the key's internals.

**Interfaces:**
- Produces: `__tcz_thp_sortkey <seedhue> <space-joined 7 hexes>` → one fixed-width lexicographically sortable key string. `__tcz_thp_order <seedhex> <palette>…` → 1-based indices, unchanged contract.

- [ ] **Step 1: Write the failing tests**

Replace the `T6` block's key-shape assertions (keep any that still hold, e.g. determinism) and add these. Reuse the file's existing fixture style; build palettes as 7 space-joined hexes where only position 3 (`tabs`) matters.

```fish
# Option A ordering (2026-09-15): the key is built from the `tabs` role ALONE —
# group (coloured / near-grey / unusable), then a 30-degree hue bucket CENTRED on the
# seed hue, then lightness DESCENDING. Centring is what stops the seed's own family
# splitting between the top and bottom of the list; bucketing is what lets lightness
# decide inside a family (the old key compared hue at 0.001 degrees, so its lightness
# tie-breaker never ran).
function __t6a_pal --argument-names tabs --description 'a 7-hex palette whose tabs (role 3) is <tabs>; other roles fixed and irrelevant to the key'
    echo "#101010 #202020 $tabs #303030 #404040 #505050 #606060"
end
# seed hue 134 (a green seed, matching the user's #78b34c)
set -g T6SEED '#78b34c'
# same family as the seed, one light one dark: light must come first
set -g T6L (__t6a_pal '#9fd07f')
set -g T6D (__t6a_pal '#3d5b28')
t "T6A: inside one hue family the lighter tabs sorts first" "1 2" (string join ' ' (__tcz_thp_order $T6SEED "$T6L" "$T6D"))
t "T6A: and the reverse input order gives the same result" "2 1" (string join ' ' (__tcz_thp_order $T6SEED "$T6D" "$T6L"))
# a tabs hue a few degrees BELOW the seed hue must stay in the seed's own bucket,
# not wrap to the end of the list. #6c9451 is ~0.1 deg below; a far family (purple)
# must sort after both.
set -g T6BELOW (__t6a_pal '#6c9451')
set -g T6FAR (__t6a_pal '#9d72b3')
t "T6A: a tabs hue just below the seed stays with the seed family" "1 2" (string join ' ' (__tcz_thp_order $T6SEED "$T6BELOW" "$T6FAR"))
# near-grey tabs (chroma < 0.05) go last whatever their hue
set -g T6GREY (__t6a_pal '#77876d')
t "T6A: a near-grey tabs sorts after every coloured one" "2 1" (string join ' ' (__tcz_thp_order $T6SEED "$T6GREY" "$T6FAR"))
# unusable tabs sorts last of all
set -g T6BAD (__t6a_pal 'notahex')
t "T6A: an unusable tabs sorts last" "1 2" (string join ' ' (__tcz_thp_order $T6SEED "$T6FAR" "$T6BAD"))
# stability: equal keys keep input order
set -g T6SAME (__t6a_pal '#9d72b3')
t "T6A: identical palettes keep their input order" "1 2" (string join ' ' (__tcz_thp_order $T6SEED "$T6FAR" "$T6SAME"))
```

Verify each expectation against the real hues before trusting it: compute each fixture's OKLCH with `__tmux_lives_hex_to_rgb01` + `__tmux_lives_rgb_to_oklch` in a throwaway `fish --no-config` and put the numbers in your report. If a fixture does not have the chroma/lightness/hue relationship the assertion assumes, change the fixture (not the assertion) and say so.

Keep the existing `T6: order is deterministic across repeated calls` assertion. Delete or rewrite any assertion that pins the OLD key's internals (e.g. one that depends on a 7-block walk order or on bar breaking a tabs tie) — list each in the report with why.

- [ ] **Step 2: Run to verify they fail**

`fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` (foreground, `timeout: 600000`). Expect the new light-before-dark and grey-last assertions to FAIL against the current key. Paste the FAIL lines.

- [ ] **Step 3: Implement**

Rewrite `__tcz_thp_sortkey` to build the key from the `tabs` hex (position 3) only:

```fish
function __tcz_thp_sortkey --argument-names seedhue hexes --description 'pure: a fixed-width lexicographically-sortable key for one palette, built from the `tabs` role ALONE (the widest block on the swatch strip and the one that covers most of a real ShellFish screen). Three fields: GROUP (0 coloured, 1 near-grey below chroma 0.05 — its hue is not visible so hue ordering would read as noise, 2 unusable/non-hex), then a 30-degree HUE BUCKET measured clockwise from the seed hue and CENTRED on it (bucket 0 is -15..+15 degrees, so the seed own family never splits across the ends of the list), then LIGHTNESS DESCENDING so each family reads light -> dark. The previous key walked all seven roles and compared hue at 0.001 degrees, so its lightness field never broke a tie and families rendered as a jumble; it also cost 349ms per list rebuild against 61ms for this one (42-scheme catalog, measured 2026-09-14).'
    set -l pal (string split ' ' -- "$hexes")
    set -l h ''
    test (count $pal) -ge 3; and set h "$pal[3]"
    if not string match -qr '^#[0-9a-fA-F]{6}$' -- "$h"
        # Unusable: sort last. Shape-check BEFORE converting — __tmux_lives_hex_to_rgb01
        # has no check of its own and fish's math diagnostics go straight to stderr,
        # which lands in the middle of the popup frame this helper draws inside.
        printf '2%02d%08.3f\n' 99 999.999
        return
    end
    set -l rgb (__tmux_lives_hex_to_rgb01 "$h")
    set -l o (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l group 0
    test (math "$o[2] < 0.05") -eq 1; and set group 1
    set -l d (math "($o[3] - $seedhue + 360) % 360")
    set -l bucket (math "floor((($d + 15) % 360) / 30)")
    printf '%d%02d%08.3f\n' $group $bucket (math "(1 - $o[1]) * 1000")
end
```

Check every detail against the code before committing: that `__tmux_lives_rgb_to_oklch` returns `L C H` in that order; that fish's `math` has `floor` and `%` behaving as used here (test at the command line with a negative-ish case, e.g. `d` = 350); that `%08.3f` is wide enough for the largest value (1000.000 needs 8). Fix the code and say so if any assumption is wrong. A near-grey's bucket still comes from its hue — that is fine, greys are already segregated by the group field, and computing it keeps the key uniform.

- [ ] **Step 4: Run to verify they pass, and measure**

- `fish tests/test-tmux-categorize.fish …` and `fish --no-config tests/test-tmux-categorize.fish …` → ALL PASS.
- Measure before/after: in a throwaway `fish --no-config` script, source `conf.d/tmux-lives-install.fish` and (with `set -g tmux_categorize_test 1`) `functions/tmux-categorize.fish`, render all catalog rows at seed `#78b34c`, and time `__tcz_thp_order` over the 42 palettes with `date +%s%N`. Report the new figure against the recorded 363 ms baseline. Re-measure the baseline yourself from a copy of the pre-change file if you want the comparison on the same load.
- Print the resulting order at that seed (scheme name, tabs hex, hue-from-seed, L, C) and paste it in the report so the controller can eyeball that it reads light → dark inside each family, with greys last.

- [ ] **Step 5: Full gate**

Both modes, each its own foreground call with `timeout: 600000`. Expect 9/9 ALL PASS, install 842 plain / 841 `--no-config`, popup flake per Global Constraints.

- [ ] **Step 6: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): order schemes by hue family, then light to dark

The o ordering compared hue at 0.001 degrees across all seven roles, so its
lightness tie-breaker never ran and the seed's own family split across the
ends of the list. The key now uses the tabs role alone: coloured before
near-grey before unusable, a 30-degree hue bucket centred on the seed, then
lightness descending. It also drops the per-rebuild cost from 349ms to about
60ms on a 42-scheme catalog."
```
