# Theme v6 Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the v6 theme engine render the user's actual bar — it is merged, constrained and gated but has no production caller — and give it a catalog, a CLI, a migration, and a picker that can roll.

**Architecture:** Five production call sites move from `__tmux_lives_theme_palette` (v5: seed + relationship/place/mode/phase) to `__tmux_lives_theme_render` (v6: seed + a five-field recipe). A recipe is `(mode, Lspan, peakC, peakPos, arrangement)` and is the stored identity of a theme; a catalog name is a label resolved by lookup, never stored. The v5 engine stays defined but unreferenced. One pre-requisite engine change lands first: the text-floor swap's partner selection becomes structural so a stored recipe cannot silently repaint itself later.

**Tech Stack:** fish 4.7.1, tmux 3.3a (rocket) / 3.7b (macwork), OKLCH colour maths already in `conf.d/tmux-lives-install.fish`.

**Spec:** `docs/superpowers/specs/2026-09-02-theme-v6-surface-design.md` (read it first; it carries the measurements each decision rests on). Its two companions remain authoritative for the engine itself: `docs/superpowers/specs/2026-08-23-theme-engine-v6-design.md` (generation) and `docs/superpowers/specs/2026-08-28-palette-constraints-design.md` (acceptability).

## Global Constraints

- **Never deploy.** Finished changes reach `~/.config/fish/` only via the user's own `fisher update`. No `cp` into `conf.d/`, no editing `~/.tmux.conf`, no `set -U` to make something live.
- **Gate:** `for t in tests/test-*.fish; fish $t; end`, then again with `fish --no-config`. Each mode is its OWN foreground Bash call with an explicit `timeout: 600000`. Never wrap the suite in a shell `timeout` — it truncates with no trailer and reads as a false clean. Capture failures with `grep -E '^FAIL'`, never `tail -1`.
- **Baseline before any change:** 9/9 `ALL PASS` both modes; `test-tmux-install.fish` **839 plain / 838 `--no-config`**. The 1-count delta is BY DESIGN (one isolation assertion is gated on plain fish). Do not "fix" it.
- **Every assertion must be shown to FAIL before its change.** If it passes pre-change, it is not testing the change — say so and fix the assertion, do not proceed.
- **Grep guards match COMMENTS.** Never spell a banned shape in prose near its own guard. Bound every body-grep to a variable defined ABOVE it and pair it with a positive count, or it passes vacuously when the path expands empty.
- **The bash tool runs zsh.** A non-matching glob aborts the whole command; use `find … -delete`. Wrap stderr byte counts in `bash -c`.
- Palette bounds, exact values: peak chroma across the seven roles in **0.105-0.180** (bound 1, catalog's contract, NOT engine-enforced); mean chroma of `bar`/`tabs`/`cap` **<= 0.095** (bound 2); max lightness of those three **<= 0.70**, clamped to **0.695** for quantisation headroom (bound 3). Do not tidy 0.695 to 0.70.
- Role order everywhere is `bar sep tabs active windows cap text`; the "big three" are indices 1, 3, 6.

## File Structure

| File | Responsibility in this plan |
|---|---|
| `conf.d/tmux-lives-install.fish` | Engine, catalog, fragment renderer/writer, `setup theme` CLI, migration. All install-side work lands here — the file is large but this project keeps one conf.d file per feature and splitting it is out of scope. |
| `functions/tmux-categorize.fish` | The theme picker (`__tcz_theme_picker` and its `__tcz_thp_*` helpers). Recipe plumbing and the roll. |
| `tests/test-tmux-install.fish` | Engine, catalog, fragment, CLI and migration assertions. |
| `tests/test-tmux-categorize.fish` | Picker assertions. |
| `CLAUDE.md` | Cycle narrative, and the prune that keeps it under budget. |

---

### Task 1: The text-floor swap becomes structural

The swap picks `text`'s partner by argmax over measured lightness. 188 of 2,142 floor-firing rows sit within 0.0005 of a tie; a flip exchanges a whole colour between two roles (worst measured 0.36 in lightness), and since a scheme is stored as a recipe, a future engine constant would silently repaint a theme the user had already chosen. Ramp indices are integers and distinct by construction, so selecting on them cannot tie.

Measured consequence (5,865 paired renders, four seeds): **388 palettes change, 6.6%, ALL of them in the `bright` arrangement**. Zero bound-2, bound-3 or contrast-floor regressions. Text chroma median 0.0594 -> 0.0591.

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_arrange` (~line 690), `__tmux_lives_theme_constrain` (~line 717), the swap loop at ~918, and `__tmux_lives_theme_render`'s call at ~1156
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_rampidx <pattern>` -> seven integers, one per role, giving that role's ramp index. Unknown pattern -> nothing, status 1.
- Produces: `__tmux_lives_theme_constrain <7 hexes> [pattern]` — the pattern is a NEW optional 8th argument. Without it, behaviour is byte-identical to today.

- [ ] **Step 1: Write the failing test for the shared ramp-index table**

Add to `tests/test-tmux-install.fish`, in the v6 engine section near the other `arrange` assertions:

```fish
t "rampidx: deep" "1 4 2 6 5 3 7" (string join ' ' (__tmux_lives_theme_rampidx deep))
t "rampidx: bright" "4 5 3 7 6 2 1" (string join ' ' (__tmux_lives_theme_rampidx bright))
t "rampidx: centre" "3 5 2 6 7 4 1" (string join ' ' (__tmux_lives_theme_rampidx centre))
t "rampidx: split" "1 3 4 5 6 2 7" (string join ' ' (__tmux_lives_theme_rampidx split))
t "rampidx: stack" "2 5 3 6 4 1 7" (string join ' ' (__tmux_lives_theme_rampidx stack))
t "rampidx: accent" "3 5 4 6 2 1 7" (string join ' ' (__tmux_lives_theme_rampidx accent))
t "rampidx: unknown pattern yields nothing" "" (string join ' ' (__tmux_lives_theme_rampidx nosuch))
t "rampidx: defined" 1 (functions -q __tmux_lives_theme_rampidx; and echo 1; or echo 0)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: the `rampidx:` assertions FAIL — the function does not exist. Note that a command substitution calling an undefined function makes fish abort the whole statement, so these may print nothing at all rather than a diff; the `rampidx: defined` assertion is there precisely so at least one line reports a real `FAIL`.

- [ ] **Step 3: Extract the table into one function and have `arrange` consume it**

In `conf.d/tmux-lives-install.fish`, insert immediately BEFORE `__tmux_lives_theme_arrange`:

```fish
function __tmux_lives_theme_rampidx --argument-names pattern --description 'v6: an arrangement pattern -> its seven ramp indices, position i naming the ramp index that becomes role i (bar sep tabs active windows cap text). THE one home of the table: __tmux_lives_theme_arrange permutes with it and __tmux_lives_theme_constrain selects the text-floor swap partner with it, so the two cannot drift. Unknown pattern -> nothing, status 1.'
    switch "$pattern"
        case deep
            printf '%s\n' 1 4 2 6 5 3 7
        case bright
            printf '%s\n' 4 5 3 7 6 2 1
        case centre
            printf '%s\n' 3 5 2 6 7 4 1
        case split
            printf '%s\n' 1 3 4 5 6 2 7
        case stack
            printf '%s\n' 2 5 3 6 4 1 7
        case accent
            printf '%s\n' 3 5 4 6 2 1 7
        case '*'
            return 1
    end
end
```

Then replace the whole `switch "$pattern" … end` block inside `__tmux_lives_theme_arrange` with:

```fish
    set -l idx (__tmux_lives_theme_rampidx "$pattern")
    test (count $idx) -eq 7; or return 1
```

- [ ] **Step 4: Run the tests and confirm they pass, with `arrange` unchanged**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' ; echo "rc=$status"`
Expected: no `FAIL` lines. Every pre-existing `arrange` assertion must still pass — the extraction is behaviour-preserving, so a single `arrange` failure here means the table was mistyped.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "refactor(theme): one home for the arrangement ramp-index table"
```

- [ ] **Step 6: Write the failing test for structural selection**

The discriminator is the `bright` arrangement — it is the only pattern where `text` sits at the dark end (ramp 1) while `bar` sits mid-ramp (ramp 4), which is the one genuine tie. Add:

```fish
# The swap partner is now a per-pattern CONSTANT derived from ramp indices,
# so it cannot tie and no engine constant can flip it. Distances from bar's
# own ramp index, candidates being text (incumbent) and the small roles
# 2 sep / 4 active / 5 windows; a candidate must STRICTLY beat text.
#   deep   bar@1: text 6, sep 3, active 5, windows 4  -> text, no swap
#   bright bar@4: text 3, sep 1, active 3, windows 2  -> text (active ties, loses)
#   centre bar@3: text 2, sep 2, active 3, windows 4  -> windows, SWAP
#   split  bar@1: text 6, sep 2, active 4, windows 5  -> text, no swap
#   stack  bar@2: text 5, sep 3, active 4, windows 2  -> text, no swap
#   accent bar@3: text 4, sep 2, active 3, windows 1  -> text, no swap
set -g A6SWAPFIX (__tmux_lives_theme_render '#5fab40' mono 0.28 0.26 0.25 bright)
# Under the OLD float rule this renders #7aa26c #7cb568 #69945a #338000
# #9dbc93 #5e8550 #192c10 — active receives text's dark, saturated colour.
# Under the structural rule active keeps its light #b0c9a6 and stage two
# synthesises text instead. Both satisfy all three bounds, so the sibling
# assertions below test what they claim rather than failing incidentally.
t "swap: structural selection changes bright" "#7aa26c #7cb568 #69945a #b0c9a6 #9dbc93 #5e8550 #0d2c00" (string join ' ' $A6SWAPFIX)
t "swap: the changed bright palette still satisfies the engine bounds" 1 (__t6_inbounds $A6SWAPFIX)
t "swap: the changed bright palette still clears the contrast floor" 1 (__t6_floor_ok $A6SWAPFIX)
t "swap: the changed bright palette is not near-white anywhere" 1 (__t6_nowhite_ok $A6SWAPFIX)
# Five of six arrangements are byte-identical under both rules, so a
# rendered-output assertion on them proves nothing about which rule ran.
# These pin that they did NOT move.
t "swap: deep is unmoved by the structural rule" "#434841 #73a561 #53654d #bed8b5 #9abd8d #638557 #c6e1ba" (string join ' ' (__tmux_lives_theme_render '#5fab40' mono 0.55 0.11 0.50 deep))
```

⚠ Both expected hex strings were measured against a working prototype of this exact change and re-verified live, at seed `#5fab40`. They are not guesses. If either differs when you run it, **that difference is a finding — report it rather than editing the assertion to match.** A first-choice fixture (`mono 0.50 0.17 0.55 bright`) was discarded during planning precisely because it rendered IDENTICALLY under both rules and so discriminated nothing; do not substitute a different recipe without checking it actually differs.

- [ ] **Step 7: Run it and confirm it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: `swap: structural selection changes bright` FAILS (current lightness rule gives a different palette). The four sibling assertions on bounds/floor/no-white should already PASS — they describe properties both rules satisfy, and are here to prove the new rule breaks nothing, not to drive it.

- [ ] **Step 8: Implement structural selection**

In `__tmux_lives_theme_constrain`, change the arity handling at the top:

```fish
    set -l out $argv[1..7]
    test (count $out) -eq 7; or return 1
    # Optional 8th arg: the arrangement pattern. Production (render) ALWAYS
    # passes it. Direct callers with a synthetic fixture have no arrangement
    # and fall back to the lightness rule below, which is the only thing
    # available without ramp information.
    set -l pat "$argv[8]"
```

Then replace the swap-selection loop (the `for i in 2 4 5` block that compares `$d` against `$bestd`) with:

```fish
        # Selection is STRUCTURAL when the pattern is known: ramp indices are
        # integers and distinct by construction, so there is no tie to sit on
        # and no engine constant can flip which colour becomes text. The float
        # argmax it replaces had 188 of 2,142 floor-firing rows within 0.0005
        # of a tie, and a flip EXCHANGES two roles' colours (worst measured
        # 0.36 in lightness) — which would silently repaint a stored recipe.
        # Mirrors the float rule exactly: text is the incumbent and a
        # candidate must STRICTLY beat it.
        set -l ridx (__tmux_lives_theme_rampidx "$pat")
        if test (count $ridx) -eq 7
            set -l bd (math "abs($ridx[7] - $ridx[1])")
            for i in 2 4 5
                set -l d (math "abs($ridx[$i] - $ridx[1])")
                if test "$d" -gt "$bd"
                    set best $i
                    set bd $d
                end
            end
        else
            for i in 2 4 5
                set -l li (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$i]))
                set -l d (math "abs($li[1] - $lb[1])")
                if test "$d" -gt "$bestd"
                    set best $i
                    set bestd $d
                end
            end
        end
```

And in `__tmux_lives_theme_render`, change the call at ~line 1156 from `__tmux_lives_theme_constrain $pal` to:

```fish
    __tmux_lives_theme_constrain $pal $arrangement
```

- [ ] **Step 9: Run the tests and confirm they pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`. In particular the eight pre-existing direct-fixture `constrain` call sites (lines ~2722, ~2732, ~2880, ~3011, ~3302, ~3387, ~3456, ~3512) pass no pattern and MUST be unaffected — if any moved, the fallback branch is wrong.

- [ ] **Step 10: Add the guard that production always passes the pattern**

The fallback keeps the unstable path reachable, so a future edit could silently drop the argument at the render call site and revert the defect with the whole suite green. The `bright` hex assertion in Step 6 is that guard; make it explicit:

```fish
# If render ever stops passing the pattern, constrain silently falls back to
# the float rule and this is the ONLY assertion that notices — five of six
# arrangements are byte-identical under both rules.
t "swap: render passes the arrangement through to constrain" 1 (test (string join ' ' (__tmux_lives_theme_render '#5fab40' mono 0.28 0.26 0.25 bright)) = "$A6SWAPFIX"; and echo 1; or echo 0)
```

- [ ] **Step 11: Prove the guard by mutation**

Temporarily revert `__tmux_lives_theme_render`'s call to `__tmux_lives_theme_constrain $pal` (drop the pattern). Run the suite.
Expected: `swap: structural selection changes bright` FAILS.
Then restore from a copy taken beforehand and prove byte-identity with `diff`. **Never `git checkout` to revert a mutation while work is uncommitted** — it reverts to HEAD and destroys the implementation.

- [ ] **Step 12: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): select the text-floor swap partner structurally, not by float argmax"
```

---

### Task 2: The v6 catalog

42 rows — the complete grid of 7 harmony modes x 6 arrangements, one tuned recipe per cell — with 14 flagged as the curated default view. Generated, not hand-picked, and explicitly disposable: the names are descriptive (`<mode> <arrangement>`) rather than evocative precisely so they teach the space and are cheap to replace after real use.

Provenance, so a later reader can regenerate rather than guess: candidates came from a 3,402-render sweep at three seeds (`#5fab40`, `#b7410e`, `#2f6fb3`) over `Lspan` {0.30, 0.50, 0.70} x `peakC` {0.13, 0.15, 0.17} x `peakPos` {0.35, 0.55, 0.75} x all modes x all arrangements. 997 of 1,134 recipes satisfied all three bounds at ALL three seeds. Selection kept only those with a bound-1 margin >= 0.010 (909 remained, covering all 42 cells), then greedily filled cells preferring the least-used `(Lspan, peakC, peakPos)` triple — so the value dimensions spread evenly (14/14/13, 13/14/14, 13/14/14 across 27 distinct triples) instead of collapsing onto one shape, which is the v5 defect this engine exists to escape. Minimum pairwise palette distance is 0.174 summed over seven roles, so no two rows are duplicates.

`mono deep` is the one hand-placed row: it is `mono 0.55 / 0.11 / 0.50 / deep`, the palette the user repeatedly identified as their favourite. It passes all three bounds at all three seeds but with a bound-1 margin of only **0.0050**, against >= 0.0113 for every other row. It is kept because it is known-liked, not because it is robust, and it is the migration target.

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add beside the v5 catalog functions (~line 1285)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_render` (Task 1's signature is unchanged).
- Produces: `__tmux_lives_theme_catalog_v6` -> 42 lines `name|mode|lspan|peakc|peakpos|arrangement|default`
- Produces: `__tmux_lives_theme_catalog_v6_default` -> the 14 flagged rows, in catalog order
- Produces: `__tmux_lives_theme_catalog_v6_rest` -> the other 28, in catalog order
- Produces: `__tmux_lives_theme_recipe <name>` -> five fields `mode lspan peakc peakpos arrangement`, one per line; unknown name -> nothing, status 1

- [ ] **Step 1: Write the failing tests**

```fish
t "catalog v6: 42 rows" 42 (count (__tmux_lives_theme_catalog_v6))
t "catalog v6: 14 curated" 14 (count (__tmux_lives_theme_catalog_v6_default))
t "catalog v6: 28 in the rest" 28 (count (__tmux_lives_theme_catalog_v6_rest))
t "catalog v6: default + rest is the whole catalog" 42 (math (count (__tmux_lives_theme_catalog_v6_default)) + (count (__tmux_lives_theme_catalog_v6_rest)))
t "catalog v6: every row has 7 fields" 42 (__tmux_lives_theme_catalog_v6 | while read -l l; test (count (string split '|' -- $l)) -eq 7; and echo x; end | count)
t "catalog v6: names are unique" 42 (__tmux_lives_theme_catalog_v6 | string split -f1 '|' | sort -u | count)
t "catalog v6: all 7 modes present" 7 (__tmux_lives_theme_catalog_v6 | string split -f2 '|' | sort -u | count)
t "catalog v6: all 6 arrangements present" 6 (__tmux_lives_theme_catalog_v6 | string split -f6 '|' | sort -u | count)
t "catalog v6: the curated 14 cover all 6 arrangements" 6 (__tmux_lives_theme_catalog_v6_default | string split -f6 '|' | sort -u | count)
t "catalog v6: the curated 14 cover all 7 modes" 7 (__tmux_lives_theme_catalog_v6_default | string split -f2 '|' | sort -u | count)
t "recipe: mono deep is the known-liked classic" "mono 0.55 0.11 0.50 deep" (string join ' ' (__tmux_lives_theme_recipe 'mono deep'))
t "recipe: an unknown name yields nothing" "" (string join ' ' (__tmux_lives_theme_recipe 'no such scheme'))
t "recipe: defined" 1 (functions -q __tmux_lives_theme_recipe; and echo 1; or echo 0)
```

Value-dimension spread is the property that stops this catalog recreating the v5 collapse, so assert it directly rather than trusting the generation:

```fish
t "catalog v6: Lspan is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f3 '|' | sort -u | count)
t "catalog v6: peakC is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f4 '|' | sort -u | count)
t "catalog v6: peakPos is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f5 '|' | sort -u | count)
```

(All three are **4**, not 3: the generated rows use three values each — Lspan {0.30, 0.50, 0.70}, peakC {0.13, 0.15, 0.17}, peakPos {0.35, 0.55, 0.75} — and `mono deep`, the hand-placed row, contributes a fourth of each: 0.55, 0.11 and 0.50 respectively. Verified against the literal table above; a value of 3 anywhere means a generated row was mistyped or `mono deep` was normalised onto the grid, which would lose the user's favourite palette.)

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: the `catalog v6:` and `recipe:` assertions FAIL.

- [ ] **Step 3: Add the catalog**

```fish
function __tmux_lives_theme_catalog_v6 --description 'v6 catalog: 42 schemes as name|mode|lspan|peakc|peakpos|arrangement|default (1 = in the curated 14). The COMPLETE 7-mode x 6-arrangement grid, one tuned recipe per cell, so nothing is arbitrary and curation later REMOVES rather than guesses. Names are descriptive (<mode> <arrangement>) on purpose: the set is provisional, generated rather than hand-picked, and meant to teach the space until real use replaces it. Generated from a 3,402-render sweep at three seeds keeping only recipes that satisfy all three bounds at ALL of them with a bound-1 margin >= 0.010, then filling cells by least-used (Lspan, peakC, peakPos) triple so the VALUE dimensions spread instead of collapsing onto one shape — collapse being precisely the v5 defect v6 exists to escape. mono deep is the one hand-placed row (the users repeatedly-favourite palette); its bound-1 margin is 0.0050 against >= 0.0113 everywhere else, so it is the least robust row in the catalog and is kept for being liked, not for being safe.'
    printf '%s\n' \
        'mono deep|mono|0.55|0.11|0.50|deep|1' \
        'mono bright|mono|0.50|0.17|0.55|bright|1' \
        'mono centre|mono|0.30|0.15|0.75|centre|0' \
        'mono split|mono|0.70|0.13|0.35|split|0' \
        'mono stack|mono|0.70|0.15|0.55|stack|0' \
        'mono accent|mono|0.30|0.17|0.75|accent|0' \
        'analogous deep|analogous|0.50|0.17|0.35|deep|0' \
        'analogous bright|analogous|0.70|0.13|0.55|bright|0' \
        'analogous centre|analogous|0.50|0.15|0.75|centre|1' \
        'analogous split|analogous|0.30|0.13|0.55|split|1' \
        'analogous stack|analogous|0.30|0.17|0.35|stack|0' \
        'analogous accent|analogous|0.70|0.15|0.75|accent|0' \
        'complementary deep|complementary|0.50|0.13|0.35|deep|0' \
        'complementary bright|complementary|0.30|0.17|0.55|bright|0' \
        'complementary centre|complementary|0.50|0.13|0.75|centre|0' \
        'complementary split|complementary|0.70|0.15|0.35|split|0' \
        'complementary stack|complementary|0.70|0.17|0.75|stack|1' \
        'complementary accent|complementary|0.30|0.15|0.35|accent|1' \
        'split deep|split|0.50|0.13|0.55|deep|1' \
        'split bright|split|0.70|0.17|0.55|bright|1' \
        'split centre|split|0.30|0.13|0.75|centre|0' \
        'split split|split|0.50|0.15|0.55|split|0' \
        'split stack|split|0.70|0.17|0.35|stack|0' \
        'split accent|split|0.30|0.15|0.55|accent|0' \
        'triadic deep|triadic|0.50|0.17|0.75|deep|0' \
        'triadic bright|triadic|0.70|0.13|0.75|bright|0' \
        'triadic centre|triadic|0.30|0.15|0.75|centre|1' \
        'triadic split|triadic|0.30|0.13|0.35|split|1' \
        'triadic stack|triadic|0.50|0.15|0.35|stack|0' \
        'triadic accent|triadic|0.70|0.17|0.55|accent|0' \
        'tetradic deep|tetradic|0.50|0.17|0.35|deep|0' \
        'tetradic bright|tetradic|0.30|0.13|0.55|bright|0' \
        'tetradic centre|tetradic|0.70|0.15|0.75|centre|0' \
        'tetradic split|tetradic|0.50|0.13|0.55|split|0' \
        'tetradic stack|tetradic|0.30|0.17|0.35|stack|1' \
        'tetradic accent|tetradic|0.50|0.15|0.75|accent|1' \
        'square deep|square|0.70|0.17|0.35|deep|1' \
        'square bright|square|0.70|0.13|0.75|bright|1' \
        'square centre|square|0.50|0.15|0.55|centre|0' \
        'square split|square|0.30|0.13|0.75|split|0' \
        'square stack|square|0.30|0.15|0.35|stack|0' \
        'square accent|square|0.50|0.17|0.55|accent|0'
end

function __tmux_lives_theme_catalog_v6_default --description 'v6: the curated 14 — catalog rows flagged default=1. Two arrangements per mode, chosen so all seven modes AND all six arrangements are reachable from a cold open.'
    __tmux_lives_theme_catalog_v6 | string match -r '\|1$'
end

function __tmux_lives_theme_catalog_v6_rest --description 'v6: the 28 non-curated rows, in catalog order. The picker appends these under the More Schemes header so the curated rows keep their positions.'
    __tmux_lives_theme_catalog_v6 | string match -r '\|0$'
end

function __tmux_lives_theme_recipe --argument-names name --description 'v6: a catalog scheme NAME -> its five recipe fields (mode lspan peakc peakpos arrangement), one per line. The name is a label resolved by lookup and is never stored — the recipe is the identity. Unknown name -> nothing, status 1.'
    for e in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' -- $e)
        if test "$f[1]" = "$name"
            printf '%s\n' $f[2] $f[3] $f[4] $f[5] $f[6]
            return 0
        end
    end
    return 1
end
```

- [ ] **Step 4: Run and confirm the tests pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`.

- [ ] **Step 5: Add the bounds guard across the whole catalog**

This is the catalog's contract and the regression guard for the entire spec. Bound 1 is deliberately absent from `__t6_inbounds` (the gamut decides it, so the engine cannot enforce it) and therefore has to be asserted HERE:

```fish
# Every catalog recipe must satisfy ALL THREE bounds at several seeds. Bound 1
# is the catalog's own contract — __t6_inbounds excludes it on purpose because
# no clamp can raise a rendered peak the sRGB gamut has capped.
set -g A6CATFAIL 0
set -g A6CATN 0
for s in '#5fab40' '#b7410e' '#2f6fb3'
    for e in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' -- $e)
        set -l p (__tmux_lives_theme_render $s $f[2] $f[3] $f[4] $f[5] $f[6])
        set -g A6CATN (math $A6CATN + 1)
        if test (count $p) -ne 7
            set -g A6CATFAIL (math $A6CATFAIL + 1)
            continue
        end
        set -l b (string split ' ' -- (__t6_bounds $p))
        if test "$b[1]" -lt 0.105; or test "$b[1]" -gt 0.180
            set -g A6CATFAIL (math $A6CATFAIL + 1)
        else if test (__t6_inbounds $p) -ne 1
            set -g A6CATFAIL (math $A6CATFAIL + 1)
        end
    end
end
t "catalog v6: every recipe renders at all three seeds" 126 $A6CATN
t "catalog v6: every recipe satisfies all three bounds at all three seeds" 0 $A6CATFAIL
```

The `A6CATN` assertion is the vacuity guard: without it, a loop that silently rendered nothing would report zero failures and pass.

- [ ] **Step 6: Run it, and prove it is not vacuous**

Run the suite; expect no `FAIL`. Then temporarily change one catalog row's `peakc` to `0.05` and re-run.
Expected: `catalog v6: every recipe satisfies all three bounds at all three seeds` FAILS with a non-zero count. Restore from a file copy and `diff` to prove byte-identity.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): the v6 catalog — the complete 7x6 grid, 14 curated"
```

---

### Task 3: The fragment carries a recipe

⚠ **This task is the sharpest hazard in the plan.** `__tmux_lives_render_fragment` reads argv positionally and `__tmux_lives_write_fragment` writes them positionally. Replacing four theme fields with five renumbers `syncterm` from **17 to 18**, and a mismatch between the two functions is **SILENT** — no error, no non-zero status. It last cost the `terminal-features xterm*:sync` line, whose absence has no symptom until the ShellFish cursor strobe returns days later.

**The renderer edit and the writer edit are ONE commit. Never split them.**

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (argv block at lines 14-32, the themed branch at ~112-118), `__tmux_lives_write_fragment` (line 299)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_render`, `__tmux_lives_theme_recipe` (Task 2)
- Produces: fragment argv **13** mode, **14** lspan, **15** peakc, **16** peakpos, **17** arrangement, **18** syncterm

- [ ] **Step 1: Write the failing tests**

```fish
# argv 18 is syncterm — it MOVED from 17 when the recipe grew from four fields
# to five. A renderer/writer mismatch here is silent, so pin the position and
# pin that the line it drives still appears.
set -g A6FRAG (__tmux_lives_render_fragment /tmp/cat.fish S M-s '#5fab40' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep 'xterm*')
t "fragment: syncterm at argv 18 still emits the sync feature line" 1 (string match -q '*xterm*:sync*' -- "$A6FRAG"; and echo 1; or echo 0)
t "fragment: a themed render sets status-style from the v6 palette" 1 (string match -q '*set -g status-style bg=#434841*' -- "$A6FRAG"; and echo 1; or echo 0)
t "fragment: the recipe reaches the bar bg option" 1 (string match -q '*@tmux_lives_bar_bg #434841*' -- "$A6FRAG"; and echo 1; or echo 0)
# An empty mode still means legacy, exactly as an empty relationship did.
set -g A6FRAGOFF (__tmux_lives_render_fragment /tmp/cat.fish S M-s '#5fab40' 0 M-m M-t M-r C-M-a C-M-s block M-k off 0.55 0.11 0.50 deep 'xterm*')
t "fragment: theme off still takes the legacy path" 0 (string match -q '*@tmux_lives_bar_bg #434841*' -- "$A6FRAGOFF"; and echo 1; or echo 0)
t "fragment: theme off still emits the sync feature line" 1 (string match -q '*xterm*:sync*' -- "$A6FRAGOFF"; and echo 1; or echo 0)
```

⚠ `#434841` is `mono 0.55/0.11/0.50/deep` at seed `#5fab40` (measured). Confirm it against the real render before relying on it.

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: the `fragment:` assertions FAIL — argv 13-17 currently mean relationship/place/mode/phase/syncterm, so the render either produces a v5 palette or drops the sync line.

- [ ] **Step 3: Renumber the renderer**

Replace lines 28-32 of `conf.d/tmux-lives-install.fish`:

```fish
    set -l theme $argv[13]        # v6 harmony mode ('' or 'off' = legacy; write_fragment passes the effective default mono)
    set -l tlspan $argv[14]       #   14 lspan       lightness span
    set -l tpeakc $argv[15]       #   15 peakc       peak chroma
    set -l tpeakpos $argv[16]     #   16 peakpos     chroma peak position along the ramp
    set -l tarr $argv[17]         #   17 arrangement ramp-position-to-role pattern
    set -l syncterm $argv[18]     #   18 syncterm    TERM glob told to use synchronized output ('' = off)
```

And the themed branch at ~115:

```fish
        test -n "$seedhex"; and set tpal (__tmux_lives_theme_render $seedhex "$theme" "$tlspan" "$tpeakc" "$tpeakpos" "$tarr")
```

- [ ] **Step 4: Renumber the writer, in the SAME edit**

Replace the four theme arguments in `__tmux_lives_write_fragment`'s single long `__tmux_lives_render_fragment` call (line 299) — the tail currently reads `… (__tmux_lives_key tmux_lives_theme mono) (__tmux_lives_key tmux_lives_theme_place bar) (__tmux_lives_key tmux_lives_theme_mode derived) (__tmux_lives_key tmux_lives_theme_phase 0) (__tmux_lives_key tmux_lives_sync_terminals 'xterm*') > $fragment` — with:

```fish
(__tmux_lives_key tmux_lives_theme mono) (__tmux_lives_key tmux_lives_theme_lspan 0.55) (__tmux_lives_key tmux_lives_theme_peakc 0.11) (__tmux_lives_key tmux_lives_theme_peakpos 0.50) (__tmux_lives_key tmux_lives_theme_arrangement deep) (__tmux_lives_key tmux_lives_sync_terminals 'xterm*') > $fragment
```

The five defaults are `mono deep`'s recipe — the migration target — so a host with no stored recipe renders the known-liked palette rather than nothing.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`. The pre-existing fragment assertions (key binds, state file, baseline, status-right) must all still pass — they read argv 1-12, which did not move.

- [ ] **Step 6: Prove the silent-failure guard works**

Temporarily change ONLY the renderer's `syncterm` back to `$argv[17]`, leaving the writer alone. Run the suite.
Expected: `fragment: syncterm at argv 18 still emits the sync feature line` FAILS. This is the whole point of the assertion — without it this mutation is invisible. Restore from a file copy and `diff`.

- [ ] **Step 7: Commit — renderer and writer together**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): the fragment carries a v6 recipe, and syncterm moves to argv 18"
```

---

### Task 4: `apply_live` and `theme list` render v6

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_apply_live` (~1459), `__tmux_lives_theme_list` (~1501)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_apply_live` with **exactly 5 positional args** = `mode lspan peakc peakpos arrangement` pushes THOSE instead of the universals (the picker preview path, writes no state). With 0 args it reads the universals. Any other count is treated as 0.

- [ ] **Step 1: Write the failing tests**

```fish
set -g A6SOCK "tl6-$fish_pid"
command tmux -f /dev/null -L $A6SOCK new-session -d -s probe -c $HOME 'sleep 60' 2>/dev/null
set -g tmux_lives_tmux_socket $A6SOCK
__tmux_lives_theme_apply_live mono 0.55 0.11 0.50 deep
t "apply_live: 5 args push the v6 palette's bar" '#434841' (command tmux -L $A6SOCK show -gv @tmux_lives_bar_bg 2>/dev/null)
t "apply_live: 5 args push the v6 palette's cap" '#638557' (command tmux -L $A6SOCK show -gv @tmux_lives_cap_bg 2>/dev/null)
t "apply_live: 5 args push the v6 palette's tabs" '#53654d' (command tmux -L $A6SOCK show -gv @tmux_lives_tabs_color 2>/dev/null)
t "apply_live: the mark stays the seed verbatim" (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color '')) (command tmux -L $A6SOCK show -gv @tmux_lives_mark_fg 2>/dev/null)
t "list v6: one line per catalog row" 42 (__tmux_lives_theme_list | count)
t "list v6: every line names its scheme" 42 (__tmux_lives_theme_list | string match -r '(mono|analogous|complementary|split|triadic|tetradic|square) (deep|bright|centre|split|stack|accent)' | count)
command tmux -L $A6SOCK kill-server 2>/dev/null
set -e tmux_lives_tmux_socket
```

⚠ The three hexes assume the suite's seed is `#5fab40`. The suite runs under a redirected `XDG_CONFIG_HOME` with no universals, so `tmux_lives_bar_color` will be EMPTY and `apply_live` will take its legacy branch. **Set the seed for this block explicitly** (`set -g tmux_lives_bar_color '#5fab40'` before, `set -e` after) — a `set -g` shadows the universal for this process only, which is the same mechanism the picker's seed preview already relies on.

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: the `apply_live:` and `list v6:` assertions FAIL — `apply_live` currently expects 4 args and `theme_list` iterates the v5 catalog.

- [ ] **Step 3: Rewrite `apply_live`'s argument handling and palette call**

```fish
    set -l theme; set -l tlspan; set -l tpeakc; set -l tpeakpos; set -l tarr
    if test (count $argv) -eq 5
        set theme $argv[1]; set tlspan $argv[2]; set tpeakc $argv[3]; set tpeakpos $argv[4]; set tarr $argv[5]
    else
        set theme (__tmux_lives_key tmux_lives_theme mono)
        set tlspan (__tmux_lives_key tmux_lives_theme_lspan 0.55)
        set tpeakc (__tmux_lives_key tmux_lives_theme_peakc 0.11)
        set tpeakpos (__tmux_lives_key tmux_lives_theme_peakpos 0.50)
        set tarr (__tmux_lives_key tmux_lives_theme_arrangement deep)
    end
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    set -l tpal
    if test "$theme" != off; and test -n "$seed"
        set tpal (__tmux_lives_theme_render $seed "$theme" "$tlspan" "$tpeakc" "$tpeakpos" "$tarr")
    end
```

Everything below (`test (count $tpal) -eq 7`, the nine `__tmux_lives_theme_push` calls, the legacy fallback) is UNCHANGED — the palette shape is the same seven roles in the same order.

- [ ] **Step 4: Rewrite `theme_list`**

```fish
function __tmux_lives_theme_list --description 'tmux-lives setup theme list: every v6 catalog scheme + a 7-role strip at the current seed'
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    test -n "$seed"; or set seed '#3a3a3a'   # no seed configured yet -> neutral so strips still render
    for entry in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' $entry)
        set -l pal (__tmux_lives_theme_render $seed $f[2] $f[3] $f[4] $f[5] $f[6])
        test (count $pal) -eq 7; or continue
        set -l strip
        for hex in $pal
            set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $hex)
            test (count $m) -eq 3; or continue
            set -a strip (printf '\e[48;2;%d;%d;%dm  \e[0m' (math "0x$m[1]") (math "0x$m[2]") (math "0x$m[3]"))
        end
        printf '%s %-20s %s\n' (string join '' $strip) $f[1] $pal[6]
    end
end
```

The name column widens from 11 to 20 because v6 names are longer (`complementary bright` is 20 characters).

- [ ] **Step 5: Run and confirm the tests pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): apply_live and theme list render v6 recipes"
```

---

### Task 5: The CLI

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_cmd` (~1523), and the `cap`/`theme` rows of `__tmux_lives_setup_help_lines`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_recipe`, `__tmux_lives_theme_catalog_v6` (Task 2); `__tmux_lives_theme_apply_live` (Task 4)

- [ ] **Step 1: Write the failing tests**

```fish
t "cli: a catalog name is accepted" 0 (__tmux_lives_theme_cmd 'mono deep' >/dev/null 2>&1; echo $status)
t "cli: an unknown name is rejected" 1 (__tmux_lives_theme_cmd 'no such scheme' >/dev/null 2>&1; echo $status)
t "cli: an unknown name names the scheme in the error" 1 (__tmux_lives_theme_cmd 'no such scheme' 2>&1 >/dev/null | string match -q '*no such scheme*'; and echo 1; or echo 0)
t "cli: --place is rejected" 1 (__tmux_lives_theme_cmd 'mono deep' --place bar >/dev/null 2>&1; echo $status)
t "cli: --mode is rejected" 1 (__tmux_lives_theme_cmd 'mono deep' --mode literal >/dev/null 2>&1; echo $status)
t "cli: --phase is rejected" 1 (__tmux_lives_theme_cmd 'mono deep' --phase 30 >/dev/null 2>&1; echo $status)
t "cli: --place says what replaced it" 1 (__tmux_lives_theme_cmd --place bar 2>&1 >/dev/null | string match -q '*recipe*'; and echo 1; or echo 0)
t "cli: setting a scheme stores all five recipe fields" "mono 0.55 0.11 0.50 deep" (__tmux_lives_theme_cmd 'mono deep' >/dev/null 2>&1; string join ' ' $tmux_lives_theme $tmux_lives_theme_lspan $tmux_lives_theme_peakc $tmux_lives_theme_peakpos $tmux_lives_theme_arrangement)
t "cli: off is still off" off (__tmux_lives_theme_cmd off >/dev/null 2>&1; echo $tmux_lives_theme)
```

⚠ These write universals. The suite's `XDG_CONFIG_HOME` re-exec guard makes that safe — but only because the guard is present. Do NOT add a save/restore dance around them; that is the pattern the guard replaced.
⚠ `__tmux_lives_theme_cmd` calls `__tmux_lives_write_fragment`, which writes `~/.config/tmux/tmux-lives.conf` under the REAL `$HOME`. Stub `__tmux_lives_write_fragment` and `__tmux_lives_theme_apply_live` for this block, as the existing CLI tests in this file already do, and restore them afterwards with `functions -e`.

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: the `cli:` assertions FAIL — the parser still validates a v5 relationship.

- [ ] **Step 3: Rewrite the parser**

Replace the flag `switch` arms and the validation block. The retired-flag arms follow the shape already used for `--rotate`:

```fish
            case --place --mode --phase
                echo "tmux-lives setup theme: $argv[$i] was removed in v6 — a scheme is now a recipe (mode, lightness span, peak chroma, peak position, arrangement) chosen by name; see 'tmux-lives setup theme list'" >&2
                return 1
```

Validation becomes a catalog lookup:

```fish
    set -l rec
    if test $have_scheme -eq 1
        set rec (__tmux_lives_theme_recipe "$scheme")
        if test (count $rec) -ne 5
            echo "tmux-lives setup theme: unknown scheme '$scheme' — see 'tmux-lives setup theme list' (or: off)" >&2
            return 1
        end
        set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
        if test -z "$seed"
            echo "tmux-lives setup theme: no seed color — set one first: tmux-lives setup color '#rrggbb' (hex or rgb(); named colors have no derivable hue)" >&2
            return 1
        end
    end
```

And the write:

```fish
    if test $have_scheme -eq 1
        set -U tmux_lives_theme $rec[1]
        set -U tmux_lives_theme_lspan $rec[2]
        set -U tmux_lives_theme_peakc $rec[3]
        set -U tmux_lives_theme_peakpos $rec[4]
        set -U tmux_lives_theme_arrangement $rec[5]
    end
    __tmux_lives_write_fragment
    __tmux_lives_theme_apply_live
    test $have_scheme -eq 1; and echo "tmux-lives: theme set to $scheme"
```

The no-argument state print becomes:

```fish
        set -l cur (__tmux_lives_key tmux_lives_theme mono)
        test "$cur" = off; and echo "theme: off (legacy bar colors)"; or begin
            echo "theme: $cur "(__tmux_lives_key tmux_lives_theme_arrangement deep)
            echo "  span: "(__tmux_lives_key tmux_lives_theme_lspan 0.55)"   peak chroma: "(__tmux_lives_key tmux_lives_theme_peakc 0.11)"   peak at: "(__tmux_lives_key tmux_lives_theme_peakpos 0.50)
        end
        return 0
```

- [ ] **Step 4: Update the setup help row**

Change the `theme` row of `__tmux_lives_setup_help_lines` to describe schemes rather than relationships. **The framed help page must still fit 80 columns** — `__tmux_lives_box` measures with `string length --visible`, and the existing test that asserts the width will catch an overrun. Keep the description under the width the neighbouring rows use.

- [ ] **Step 5: Run and confirm the tests pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`, including the pre-existing help-page width assertion.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): setup theme takes a v6 scheme name; place/mode/phase retired"
```

---

### Task 6: Migration

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_migrate_v6` beside `_v52` (~2063), chain it in `_tmux_lives_post_update` (~2079)
- Test: `tests/test-tmux-install.fish`

- [ ] **Step 1: Write the failing tests**

```fish
set -U tmux_lives_theme amber
set -U tmux_lives_theme_place cap
set -U tmux_lives_theme_mode derived
set -U tmux_lives_theme_phase 0
set -U tmux_lives_bar_color '#5fab40'
__tmux_lives_migrate_v6 >/dev/null 2>&1
t "migrate v6: the seed is preserved" '#5fab40' "$tmux_lives_bar_color"
t "migrate v6: place is erased" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "migrate v6: mode is erased" 0 (set -q tmux_lives_theme_mode; and echo 1; or echo 0)
t "migrate v6: phase is erased" 0 (set -q tmux_lives_theme_phase; and echo 1; or echo 0)
t "migrate v6: the theme becomes the default recipe" "mono 0.55 0.11 0.50 deep" (string join ' ' $tmux_lives_theme $tmux_lives_theme_lspan $tmux_lives_theme_peakc $tmux_lives_theme_peakpos $tmux_lives_theme_arrangement)
set -g A6MIG1 (string join ' ' $tmux_lives_theme $tmux_lives_theme_lspan $tmux_lives_theme_peakc $tmux_lives_theme_peakpos $tmux_lives_theme_arrangement)
__tmux_lives_migrate_v6 >/dev/null 2>&1
t "migrate v6: idempotent" "$A6MIG1" (string join ' ' $tmux_lives_theme $tmux_lives_theme_lspan $tmux_lives_theme_peakc $tmux_lives_theme_peakpos $tmux_lives_theme_arrangement)
t "migrate v6: a second run is silent" "" (__tmux_lives_migrate_v6 2>&1)
set -U tmux_lives_theme off
__tmux_lives_migrate_v6 >/dev/null 2>&1
t "migrate v6: off is left alone" off "$tmux_lives_theme"
t "migrate v6: chained on post-update" 1 (functions __tmux_lives_migrate_v6 >/dev/null; and string match -q '*__tmux_lives_migrate_v6*' -- (functions _tmux_lives_post_update | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: `migrate v6:` assertions FAIL — the function does not exist.

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_migrate_v6 --description 'v5.2 -> v6: relationship/place/mode/phase have no v6 meaning — a scheme is a five-field RECIPE now, and no mapping from the old vocabulary would be trustworthy. Reset to the curated default (mono deep, the palette the user identified as their favourite) and PRESERVE THE SEED, which is the one thing that carries over. Leaves `off` alone. Scope-less `set -e`, like _v51/_v52: a scoped `set -e -U` silently no-ops under `fish --no-config`. Idempotent; runs on fisher update.'
    # Already migrated if the recipe fields exist; nothing stored at all is a
    # fresh install, which needs no notice either.
    set -q tmux_lives_theme_arrangement; and return 0
    set -q tmux_lives_theme_place; or set -q tmux_lives_theme_mode; or set -q tmux_lives_theme_phase; or set -q tmux_lives_theme; or return 0
    set -e tmux_lives_theme_place
    set -e tmux_lives_theme_mode
    set -e tmux_lives_theme_phase
    if test "$tmux_lives_theme" = off
        return 0
    end
    set -U tmux_lives_theme mono
    set -U tmux_lives_theme_lspan 0.55
    set -U tmux_lives_theme_peakc 0.11
    set -U tmux_lives_theme_peakpos 0.50
    set -U tmux_lives_theme_arrangement deep
    echo "tmux-lives: theme engine v6 — your old scheme has no v6 equivalent, so it is reset to 'mono deep' (your seed color is unchanged). Browse the rest with 'tmux-lives setup theme list' or the picker."
    return 0
end
```

⚠ The `off` early-return sits AFTER the three erases on purpose: an `off` install may still carry a stale `place`/`mode`/`phase`, and leaving them behind would defeat idempotency on the next run.

- [ ] **Step 4: Chain it**

Add `__tmux_lives_migrate_v6` after `__tmux_lives_migrate_v52` in `_tmux_lives_post_update`.

- [ ] **Step 5: Run and confirm the tests pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): migrate v5 relationship/place/mode/phase to a v6 recipe"
```

---

### Task 7: The picker carries five-field recipes

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker` state init (~2447-2500), `__tcz_thp_reload` (~2506), `__tcz_thp_reanchor` (~2693), `__tcz_thp_apply_and_recolor` (~2400), `__tcz_thp_apply_now`, the list-side `case enter` save (~3510)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_catalog_v6_default`, `_rest`, `__tmux_lives_theme_recipe` (Task 2); `__tmux_lives_theme_apply_live` with five args (Task 4)
- Produces: `$recipes[i]` is now `mode|lspan|peakc|peakpos|arrangement` (five fields, was three)

- [ ] **Step 1: Write the failing tests**

The picker is an interactive raw-tty loop and cannot be driven end to end here, so assert on the source shape — bounded to the function body, with a positive count so it cannot pass vacuously:

```fish
set -g A6PICK (functions __tcz_theme_picker | string collect)
t "picker: sources the v6 catalog" 1 (string match -q '*__tmux_lives_theme_catalog_v6_default*' -- "$A6PICK"; and echo 1; or echo 0)
t "picker: no v5 catalog call remains" 0 (string match -q '*__tmux_lives_theme_catalog_default*' -- (string replace -a '__tmux_lives_theme_catalog_v6_default' 'X' -- "$A6PICK"); and echo 1; or echo 0)
t "picker: no v5 palette call remains" 0 (string match -q '*__tmux_lives_theme_palette*' -- "$A6PICK"; and echo 1; or echo 0)
t "picker: renders through the v6 entry point" 1 (string match -q '*__tmux_lives_theme_render*' -- "$A6PICK"; and echo 1; or echo 0)
t "picker: body was actually captured" 1 (test (string length "$A6PICK") -gt 2000; and echo 1; or echo 0)
set -g A6APPLY (functions __tcz_thp_apply_and_recolor | string collect)
t "apply_and_recolor: body was actually captured" 1 (test (string length "$A6APPLY") -gt 200; and echo 1; or echo 0)
t "apply_and_recolor: no phase argument remains" 0 (string match -q '*anch_phase*' -- "$A6APPLY"; and echo 1; or echo 0)
```

The `body was actually captured` assertions are the vacuity guards: `functions` on a missing name yields the empty string, against which every `string match` returns false and every "no X remains" assertion passes.

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'`
Expected: the `picker:` assertions FAIL.

- [ ] **Step 3: Replace the state variables**

In `__tcz_theme_picker`, replace the `place`/`mode`/`phase`/`persisted_phase` locals with the recipe fields, and rewrite `__tcz_thp_init`'s child read:

```fish
    set -l seed ''
    set -l theme mono
    set -l tlspan 0.55
    set -l tpeakc 0.11
    set -l tpeakpos 0.50
    set -l tarr deep
    # The anchor snapshot: the persisted recipe frozen at open, which the
    # `current` row renders and which esc reverts to. anch_name is the catalog
    # name that recipe resolves to, or EMPTY when it resolves to none — which
    # is exactly what a rolled theme does once Task 8 lands, and is why the
    # save path cannot assume a name exists.
    set -l anch_theme mono
    set -l anch_lspan 0.55
    set -l anch_peakc 0.11
    set -l anch_peakpos 0.50
    set -l anch_arr deep
    set -l anch_name ''
    set -l expanded 1
    set -l ndefault (count (__tmux_lives_theme_catalog_v6_default))
    set -l legacy ''
    set -l previewed 0
```

```fish
        set -l init (fish -c '
            echo (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ""))
            echo (__tmux_lives_key tmux_lives_theme mono)
            echo (__tmux_lives_key tmux_lives_theme_lspan 0.55)
            echo (__tmux_lives_key tmux_lives_theme_peakc 0.11)
            echo (__tmux_lives_key tmux_lives_theme_peakpos 0.50)
            echo (__tmux_lives_key tmux_lives_theme_arrangement deep)
            echo (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))' 2>/dev/null)
        test (count $init) -ge 1; and set seed $init[1]
        test (count $init) -ge 2; and test -n "$init[2]"; and set theme $init[2]
        test (count $init) -ge 3; and test -n "$init[3]"; and set tlspan $init[3]
        test (count $init) -ge 4; and test -n "$init[4]"; and set tpeakc $init[4]
        test (count $init) -ge 5; and test -n "$init[5]"; and set tpeakpos $init[5]
        test (count $init) -ge 6; and test -n "$init[6]"; and set tarr $init[6]
        set legacy ''
        test (count $init) -ge 7; and set legacy (string replace -rf '.*bg=([^,]+).*' '$1' -- "$init[7]")
        test -n "$seed"; or set seed '#3a3a3a'
        # Freeze the anchor from the values just read, then reverse-look-up its
        # catalog name. A recipe matching no row leaves anch_name empty.
        set anch_theme $theme; set anch_lspan $tlspan; set anch_peakc $tpeakc
        set anch_peakpos $tpeakpos; set anch_arr $tarr
        set anch_name ''
        for e in (__tmux_lives_theme_catalog_v6)
            set -l f (string split '|' -- $e)
            if test "$f[2]" = "$theme"; and test "$f[3]" = "$tlspan"; and test "$f[4]" = "$tpeakc"; and test "$f[5]" = "$tpeakpos"; and test "$f[6]" = "$tarr"
                set anch_name $f[1]
                break
            end
        end
```

⚠ The `legacy` field MOVED from `init[4]` to `init[7]`. The picker has been bitten by exactly this before — a removed echo line silently shifted `place`/`mode` by one. Count the `echo` lines against the reads before running anything.

- [ ] **Step 4: Rewrite the reload's row build**

In `__tcz_thp_reload`, replace the catalog rows and the palette call:

```fish
            set -l rows (__tmux_lives_theme_catalog_v6_default)
            test "$expanded" = 1; and set -a rows (__tmux_lives_theme_catalog_v6_rest)
            for e in $rows
                set -l f (string split '|' -- $e)
                set -l p (__tmux_lives_theme_render $seed $f[2] $f[3] $f[4] $f[5] $f[6])
                test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
                set -l capfg (__tmux_lives_contrast_fg "$p[6]")
                set -l tabsfg (__tmux_lives_contrast_fg "$p[3]")
                set -l pj (string join ' ' $p)
                set -l recipe "$f[2]|$f[3]|$f[4]|$f[5]|$f[6]"
                set -a lines "$f[1]|$pj|$capfg|$tabsfg|$recipe"
            end
```

The cache key must lose `phase` and gain nothing — it is already keyed on seed and expanded, both of which still exist. **Do not add the recipe fields to the key**: they vary per ROW, not per picker state, and adding them would make the key unbounded and defeat the cache.

- [ ] **Step 5: Rewrite the anchor, apply and save paths**

`__tcz_thp_apply_and_recolor` keeps its `<seed> [args…]` shape; only the argument count changes (5 recipe fields instead of 4 relationship fields). `__tcz_thp_apply_now`'s three branches become:

```fish
        if test $focus = state
            if test $sel2 -eq 0
                __tcz_thp_apply_and_recolor "$seed" $anch_theme $anch_lspan $anch_peakc $anch_peakpos $anch_arr
                set previewed 2
                set note "● previewing $anch_theme $anch_arr (live) — ⏎ save · esc revert"
            else
                __tcz_thp_apply_and_recolor "$seed" off 0.55 0.11 0.50 deep
                set previewed 1
                set note "● previewing off — ⏎ save · esc revert"
            end
        else
            set -l pi (math $sel + 1)
            set -l rc (string split '|' -- $recipes[$pi])
            __tcz_thp_apply_and_recolor "$seed" $rc[1] $rc[2] $rc[3] $rc[4] $rc[5]
            set previewed 1
            set note "● previewing $toks[$pi] — ⏎ save · esc revert"
        end
```

The save path (`case enter`, list branch) sets `$apply` to the selected row's NAME (`$toks[$pi]`) rather than a relationship, because the CLI now takes a name. Replace the `set apply $rc[1]` / `set place` / `set mode` trio with `set apply $toks[$pi]`, and the state-row branch with `set apply $anch_name`, where `$anch_name` is captured at open by reverse-looking-up the persisted recipe in the catalog.

⚠ If the persisted recipe matches no catalog row — which a rolled theme will not, once Task 8 lands — `$anch_name` is empty and the current row cannot be saved by name. Handle it: when `$anch_name` is empty, save by writing the five universals directly through the same `fish -c` child the preview uses, rather than through the CLI.

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`. The frame-row proof (which extracts the draw block and counts `$lines`) must still report the same row count — this task changes no geometry.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): carry five-field v6 recipes end to end"
```

---

### Task 8: The roll and its history

`z` currently jumps to a random row of the catalog. It becomes a genuine roll across the recipe space, sampling the measured ridge rather than the v6 spec's documented envelope: uniform sampling of `peakC` 0.01-0.26 satisfies bound 1 only **34.6%** of the time, while `peakC` 0.13-0.18 with `peakPos` 0.3-0.85 measures ~95%, so a roll costs about one render rather than three.

**Files:**
- Modify: `functions/tmux-categorize.fish` — the `case z` arm (~3398), plus new picker state
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_render`, `__t6`-style bounds are NOT available at runtime, so the roll measures bound 1 itself.
- Produces: `__tmux_lives_theme_roll <seedHex> [chromaBias]` -> five recipe fields, one per line. Always returns a renderable recipe.

- [ ] **Step 1: Write the failing tests**

```fish
t "roll: defined" 1 (functions -q __tmux_lives_theme_roll; and echo 1; or echo 0)
t "roll: returns five fields" 5 (count (__tmux_lives_theme_roll '#5fab40'))
t "roll: the mode is a real harmony mode" 1 (contains -- (__tmux_lives_theme_roll '#5fab40')[1] mono analogous complementary split triadic tetradic square; and echo 1; or echo 0)
t "roll: the arrangement is a real arrangement" 1 (contains -- (__tmux_lives_theme_roll '#5fab40')[5] (__tmux_lives_theme_arrangements); and echo 1; or echo 0)
# 40 rolls must all render and all satisfy bound 1. This is the assertion that
# matters: a roll that can produce a rejected palette defeats the whole point.
set -g A6ROLLBAD 0
set -g A6ROLLN 0
for i in (seq 40)
    set -l r (__tmux_lives_theme_roll '#5fab40')
    set -g A6ROLLN (math $A6ROLLN + 1)
    set -l p (__tmux_lives_theme_render '#5fab40' $r[1] $r[2] $r[3] $r[4] $r[5])
    if test (count $p) -ne 7
        set -g A6ROLLBAD (math $A6ROLLBAD + 1)
        continue
    end
    set -l b (string split ' ' -- (__t6_bounds $p))
    if test "$b[1]" -lt 0.105; or test "$b[1]" -gt 0.180; set -g A6ROLLBAD (math $A6ROLLBAD + 1); end
end
t "roll: forty rolls all happened" 40 $A6ROLLN
t "roll: forty rolls all satisfy bound 1" 0 $A6ROLLBAD
t "roll: terminates when nothing passes" 5 (count (__tmux_lives_theme_roll '#4a4a4a'))
```

⚠ `__t6_bounds` lives in `tests/test-tmux-install.fish`, not the categorize suite. Put the roll's engine-side tests in `test-tmux-install.fish` (where the engine and its helpers already are) and keep only the picker-wiring assertions in `test-tmux-categorize.fish`.

- [ ] **Step 2: Run and confirm failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: `roll:` assertions FAIL — the function does not exist.

- [ ] **Step 3: Implement the roll**

```fish
function __tmux_lives_theme_roll --argument-names seedHex --description 'v6: sample a recipe from the MEASURED acceptable ridge and return its five fields. Sampling the v6 core spec s documented envelope (peakC 0.01-0.26 uniform) satisfies bound 1 only 34.6% of the time; the region is a diagonal ridge that INVERTS — below peakC ~0.10 nothing passes at any position, and above ~0.20 the middle fails while the ends pass, because a mid-ramp peak sits where the gamut has headroom and overshoots the ceiling while an end peak is clipped back into range. peakC 0.13-0.18 x peakPos 0.3-0.85 measures ~95%, so this costs about one render. Rejects and resamples on a bound-1 miss, capped; on exhaustion returns the last candidate rather than nothing, because refusing to render is a worse outcome than one slightly-off palette.'
    set -l modes mono analogous complementary split triadic tetradic square
    set -l arrs (__tmux_lives_theme_arrangements)
    set -l r
    for attempt in (seq 8)
        set -l m $modes[(random 1 (count $modes))]
        set -l a $arrs[(random 1 (count $arrs))]
        # Capture random into a var FIRST: fish performs NO command substitution
        # inside double-quoted math, so an inline roll would hand math the
        # LITERAL unexpanded text.
        set -l rs (random 30 70)
        set -l rc (random 130 180)
        set -l rp (random 30 85)
        set -l sp (math "$rs / 100")
        set -l pc (math "$rc / 1000")
        set -l po (math "$rp / 100")
        set r $m $sp $pc $po $a
        set -l p (__tmux_lives_theme_render $seedHex $m $sp $pc $po $a)
        test (count $p) -eq 7; or continue
        set -l peak 0
        for hx in $p
            set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $hx))
            test "$o[2]" -gt "$peak"; and set peak $o[2]
        end
        if test "$peak" -ge 0.105; and test "$peak" -le 0.180
            printf '%s\n' $r
            return 0
        end
    end
    printf '%s\n' $r
    return 0
end
```

- [ ] **Step 4: Wire it into the picker with history**

Replace the `case z` arm. The roll no longer moves the cursor within the list — it produces a recipe that is not in the catalog — so it becomes its own selectable state alongside `current` and `off`:

```fish
            case z
                set -l r (__tmux_lives_theme_roll "$seed")
                if test (count $r) -eq 5
                    # Bounded history so "the second one was better" is
                    # recoverable. Session-local and deliberately not
                    # persisted: naming and saving a roll permanently is a
                    # separate, deferred feature — the user's own reason being
                    # that naming carries a commitment cost.
                    set -a rollhist (string join '|' $r)
                    test (count $rollhist) -gt 12; and set rollhist $rollhist[2..]
                    set rollat (count $rollhist)
                    set focus roll
                    __tcz_thp_apply_and_recolor "$seed" $r[1] $r[2] $r[3] $r[4] $r[5]
                    set previewed 1
                    set note "● roll $rollat/"(count $rollhist)" — ↑↓ step back · ⏎ save · esc revert"
                end
                set flashfield ''
```

Declare `set -l rollhist` and `set -l rollat 0` beside the other picker state. Then, in the `↑↓` dispatch, add a third focus arm alongside the existing `list` and `state` ones:

```fish
            else if test $focus = roll
                set rollat (math $rollat + $step)
                test $rollat -lt 1; and set rollat 1
                test $rollat -gt (count $rollhist); and set rollat (count $rollhist)
```

`focus roll` is only reachable after a roll has happened, so `$rollhist` is never empty when this arm runs — but clamp both ends anyway rather than relying on that, because `⇥` can leave and re-enter the state. `⇥` cycles `list -> state -> roll -> list` when `$rollhist` is non-empty and `list -> state -> list` when it is empty.

Give `case a` and `case enter` a matching `focus roll` branch that applies (respectively saves) `$rollhist[$rollat]` split on `|`.

⚠ Saving a roll goes through the five-universal write path from Task 7 Step 5, NOT the CLI — a rolled recipe has no catalog name.

- [ ] **Step 5: Run both suites and confirm they pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'` and `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'`
Expected: no `FAIL`. The frame-row proof must still report the same count — the roll adds a selectable state but no new frame row, since it reuses the note line.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish functions/tmux-categorize.fish tests/
git commit -m "feat(picker): z rolls the real recipe space, with a session-local history"
```

---

### Task 9: Full gate, no-v5-caller guard, and docs

- [ ] **Step 1: Add the guard that no production code calls the v5 engine**

```fish
set -g A6SRC (cat $plugindir/conf.d/tmux-lives-install.fish | string collect)
set -g A6CAT (cat $plugindir/functions/tmux-categorize.fish | string collect)
t "v5: install source was captured" 1 (test (string length "$A6SRC") -gt 10000; and echo 1; or echo 0)
t "v5: categorize source was captured" 1 (test (string length "$A6CAT") -gt 10000; and echo 1; or echo 0)
t "v5: the categorizer no longer calls theme_palette" 0 (string match -q '*__tmux_lives_theme_palette*' -- "$A6CAT"; and echo 1; or echo 0)
# The v5 engine stays DEFINED — deleting it is a separate, trivially
# revertible commit once v6 has proven itself live — but must have no
# CALLERS. Count only lines that are neither the definition nor a comment;
# a plain occurrence count would include the definition and any prose
# mentioning the name, and would break the moment a comment is reworded.
t "v5: theme_palette has no callers left in the install file" 0 (string split '\n' -- "$A6SRC" | string match -r '__tmux_lives_theme_palette' | string match -rv '^\s*#' | string match -rv '^function ' | count)
t "v5: theme_palette is still defined" 1 (string split '\n' -- "$A6SRC" | string match -r '^function __tmux_lives_theme_palette' | count)
```

The `source was captured` pair is the vacuity guard — `$plugindir` is defined at the top of this suite, but this project has been bitten seven times by a body-grep against a variable that expanded empty.

- [ ] **Step 2: Run the full gate, plain fish**

Run as its own foreground call with `timeout: 600000`:
`for t in tests/test-*.fish; fish $t; end 2>&1 | grep -E '^FAIL|ALL PASS|passed'`
Expected: 9/9 `ALL PASS`, no `FAIL` lines.

- [ ] **Step 3: Run the full gate, `--no-config`**

Run as its own foreground call with `timeout: 600000`:
`for t in tests/test-*.fish; fish --no-config $t; end 2>&1 | grep -E '^FAIL|ALL PASS|passed'`
Expected: 9/9 `ALL PASS`. `test-tmux-install.fish`'s count should be exactly one lower than the plain run — that delta is BY DESIGN.

- [ ] **Step 4: Sweep leaked test sockets**

```bash
find /tmp/tmux-1000 -name 'tl6-*' -delete
```
Never touch `default`; leave `neurotest*` alone, it belongs to another project.

- [ ] **Step 5: Update `CLAUDE.md`**

Rewrite the "Theme engine — where it actually stands" section: v6 is now wired, the three call sites are gone, the catalog is 42 rows / 14 curated, the recipe is the stored identity, `--place`/`--mode`/`--phase` are retired, and the tie-break is structural. **Delete the v5 narrative it replaces** rather than appending beside it — `CLAUDE.md` is pruned, not append-only, and its budget is ~40 KB. Run `wc -c CLAUDE.md` and report the before/after.

- [ ] **Step 6: Delete this plan**

Plans are task lists for work that has shipped; git is their archive.

```bash
git rm docs/superpowers/plans/2026-09-02-theme-v6-surface.md
```

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "docs(theme): the v6 surface cycle"
git push
```

- [ ] **Step 8: Tell the user to run `fisher update`**

Their bar will visibly change: the stored `amber / cap / derived` has no v6 equivalent and resets to `mono deep`. Their seed `#5fab40` survives. **Never deploy on their behalf.**
