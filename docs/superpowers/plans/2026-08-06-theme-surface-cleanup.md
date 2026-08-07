# Theme Surface Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete four knobs that never did anything, rebalance the picker's opening 14 toward tabs placement, and make `m` append a labelled "More Schemes" group instead of reshuffling the whole list.

**Architecture:** Three independent parts against two files. Part 1 shrinks `__tmux_lives_theme_palette` from 9 parameters to 5 and renumbers the fragment argv (the sync arg moves 21 → 17). Part 2 flips `default` flags in the catalog. Part 3 composes the picker list as curated-then-rest with a display-only header row, so the header is never selectable and needs no skip logic.

**Tech Stack:** fish shell; tmux 3.3a (rocket) / 3.7b (macwork); no build step; tests are fish scripts driven by a `t` assertion helper.

**Spec:** `docs/superpowers/specs/2026-08-06-theme-surface-cleanup-design.md`

## Global Constraints

- **The gate is 8 suites printing `ALL PASS` under BOTH `fish` and `fish --no-config`.** Run: `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do fish $m "$t" </dev/null | tail -1; done; done'`
- Baseline before this plan: `test-tmux-install.fish` at **591 (plain) / 590 (--no-config)**. The 1-count delta is BY DESIGN (one isolation assertion is gated on plain fish) — never "fix" it.
- `tests/test-tmux-popup.fish` has one timing assertion that fails under machine load. Re-run before treating it as real.
- **Every assertion must be shown FAILING against the pre-change code before it is trusted.** State the observed failure in the commit or report. This repo has produced four separate waves of vacuous assertions; treat the plan's own tests as the most likely defect.
- **An undefined function called directly inside a `t` command substitution aborts the whole statement** — `t` never runs, nothing prints, and a suite with no pass counter still reports ALL PASS. Every new function gets a `functions -q <name>; echo $status` existence assertion, and actual-values are captured into a variable first.
- **Never spell a banned grep shape in a comment.** Guards match comments too; this repo has tripped that five times. Describe the shape, never write it.
- **ZERO new files** in `conf.d/` or `functions/`. Add functions to the existing feature files.
- Popup stays **52×26**; the draw must emit exactly 26 rows in every state.
- `fish --no-config` neither reads nor writes universals. Picker hot paths stay arg-driven; only action sites spawn a config-loaded child.
- Do NOT deploy. Commit and push; the user runs `fisher update` themselves.
- Do not run test suites in the background — run them in the foreground and cite the output.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `conf.d/tmux-lives-install.fish` | engine, CLI, fragment renderer, catalog, migrations | 1, 2, 4, 5 |
| `functions/tmux-categorize.fish` | picker: builders + interactive loop | 3, 6, 7, 8 |
| `tests/test-tmux-install.fish` | install-side assertions | 1, 2, 4, 5 |
| `tests/test-tmux-categorize.fish` | picker assertions incl. the 26-row frame proof | 3, 6, 7, 8 |
| `README.md`, `CLAUDE.md` | user-facing + project docs | 9 |

---

### Task 1: Shrink the palette signature and renumber the fragment argv

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_palette` (657), `__tmux_lives_theme_apply_live` (921-941), `__tmux_lives_theme_list` (968-982), `__tmux_lives_render_fragment` (14-40, 119), `__tmux_lives_write_fragment` (285)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_palette <seedHex> <relationship> <place> <mode> <phase>` → 7 hexes, order `bar sep tabs active windows cap text`. `__tmux_lives_theme_apply_live <relationship> <place> <mode> <phase>` (exactly 4 args) or no args.
- Produces: `__tmux_lives_render_fragment` takes **17** positionals; position 17 is `syncterm`.

**Why this is atomic:** fish silently ignores arguments past `--argument-names`, so shrinking a signature by removing *trailing* parameters leaves existing 9-arg callers working. The fragment argv is different — removing 17-20 shifts `syncterm` from 21 to 17, and if the renderer and `write_fragment` disagree the fragment renders with sync silently disabled. No error, no rc, no symptom until a cursor strobes. Renderer and writer move together.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-install.fish`, immediately after the existing sync block (search for `emitted sync line, gate forced true`):

```fish
# --- Task 1: knobs removed, sync arg renumbered 21 -> 17 -------------------------
# The four knobs are gone, so syncterm is positional 17. Pre-change, position 17 is
# themeviv and syncterm is empty, so NO sync line is emitted — that is the failure
# this pins. A silently-disabled sync feature has no rc and no visible symptom.
set -g FRAG17 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono bar derived 0 'xterm*' | string collect)
t "sync is positional 17 after the knobs are removed" yes (string match -q "*set -as terminal-features 'xterm*:sync'*" -- "$FRAG17"; and echo yes; or echo no)

# The engine must produce the SAME colours as before — this is a refactor, not a
# derivation change. Pinned as literal hexes so it cannot drift silently.
set -g P5 (__tmux_lives_theme_palette '#5f772b' amber bar derived 0)
t "palette still returns 7 roles from 5 args" 7 (count $P5)
t "palette bar unchanged by the refactor" '#44502f' $P5[1]

# apply_live's explicit form is now exactly 4 args.
t "apply_live explicit form documents 4 args" yes (string match -q '*4 args*' -- (functions __tmux_lives_theme_apply_live | string collect); and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -10`

Expected: `FAIL: sync is positional 17 after the knobs are removed => got [no]` and `FAIL: apply_live explicit form documents 4 args => got [no]`. The two palette assertions should already PASS — they are non-regression guards, not fix-discriminators, and that is correct. If `palette bar unchanged` fails, STOP: the baseline hex is wrong for this machine's engine and must be re-measured with `fish -c 'source conf.d/tmux-lives-install.fish; __tmux_lives_theme_palette "#5f772b" amber bar derived 0 balanced arc linear auto'` before continuing.

- [ ] **Step 3: Shrink `__tmux_lives_theme_palette`**

Replace the `--argument-names` list and description (line 657):

```fish
function __tmux_lives_theme_palette --argument-names seedHex relationship place mode phase --description 'v5: seed + relationship/place/mode/phase -> 7 role hexes (bar sep tabs active windows cap text). bar/tabs/cap = the curve (relationship travel, seed placement, mode, the bridged endcap); sep/active/windows/text = tints/contrast off the bar. Non-hex seed / unknown relationship -> nothing.'
```

The body is unchanged — it already only passes `$seedHex $relationship $place $mode $phase` to `__tmux_lives_theme_curve`.

- [ ] **Step 4: Shrink `__tmux_lives_theme_apply_live`**

Replace lines 921-941's head:

```fish
function __tmux_lives_theme_apply_live --description 'internal: push the effective v5 theme (or legacy when off/seedless) to the live server. With exactly 4 args (relationship place mode phase) pushes THOSE values instead of the universals — the picker preview path; writes no state.'
    set -l theme; set -l place; set -l mode; set -l phase
    if test (count $argv) -eq 4
        set theme $argv[1]; set place $argv[2]; set mode $argv[3]; set phase $argv[4]
    else
        set theme (__tmux_lives_key tmux_lives_theme mono)
        set place (__tmux_lives_key tmux_lives_theme_place bar)
        set mode (__tmux_lives_key tmux_lives_theme_mode derived)
        set phase (__tmux_lives_key tmux_lives_theme_phase 0)
    end
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    set -l tpal
    if test "$theme" != off; and test -n "$seed"
        set tpal (__tmux_lives_theme_palette $seed "$theme" "$place" "$mode" $phase)
    end
```

- [ ] **Step 5: Update `__tmux_lives_theme_list`**

Delete the four knob reads (lines 972-976, `viv`/`shape`/`ease`/`contrast`) and change the palette call:

```fish
        set -l pal (__tmux_lives_theme_palette $seed $rel $place $mode $phase)
```

- [ ] **Step 6: Renumber the fragment argv**

In `__tmux_lives_render_fragment`, delete the four declarations at 31-35 (`themeviv`, `themeshape`, `themeease`, `themecontrast`) and renumber `syncterm`:

```fish
    set -l syncterm $argv[17]     #   17 syncterm    TERM glob told to use synchronized output ('' = off)
```

Update the palette call at line 119:

```fish
        test -n "$seedhex"; and set tpal (__tmux_lives_theme_palette $seedhex "$theme" "$place" "$mode" "$themephase")
```

- [ ] **Step 7: Update `__tmux_lives_write_fragment` in the SAME commit**

Line 285 — remove the four `__tmux_lives_key` lookups so `sync_terminals` lands at position 17:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) (__tmux_lives_key tmux_lives_modal_key M-m) (__tmux_lives_key tmux_lives_scratch_key M-t) (__tmux_lives_key tmux_lives_resize_key M-r) (__tmux_lives_key tmux_lives_status_pos_key C-M-a) (__tmux_lives_key tmux_lives_status_vis_key C-M-s) (__tmux_lives_key tmux_lives_cursor_style block) (__tmux_lives_key tmux_lives_theme_key M-k) (__tmux_lives_key tmux_lives_theme mono) (__tmux_lives_key tmux_lives_theme_place bar) (__tmux_lives_key tmux_lives_theme_mode derived) (__tmux_lives_key tmux_lives_theme_phase 0) (__tmux_lives_key tmux_lives_sync_terminals 'xterm*') > $fragment
```

- [ ] **Step 8: Fix the existing tests that pass 21 args**

Search the install suite for render calls with the long arg list (`grep -n "balanced arc linear auto" tests/test-tmux-install.fish`) and drop those four tokens from each. The `SYNCBASE` variable defined for the earlier sync tests is one of them.

- [ ] **Step 9: Run the full gate**

Run: `bash -c 'for m in "" "--no-config"; do echo "mode ${m:-plain}"; for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'`

Expected: 8 `ALL PASS` in both modes. Record the new install-suite counts.

- [ ] **Step 10: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "refactor(theme): palette takes 5 args; fragment sync arg moves to 17"
```

---

### Task 2: Reject the four flags and erase their universals

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_cmd` (994-1145), new `__tmux_lives_migrate_v51`, `_tmux_lives_post_update` chain
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the shrunk signatures already landed.
- Produces: `__tmux_lives_migrate_v51` — no args, idempotent, erases four universals.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-install.fish` near the existing `--rotate is gone` assertions (search for `theme: --rotate is gone`):

```fish
# --- Task 2: the four inert knobs are rejected, not silently accepted ------------
# Verified inert before removal: swinging all four to their extremes produced
# byte-identical palettes on all 35 catalog rows. Accepting a flag that does
# nothing is exactly the state being cleaned up, so these must ERROR.
t "theme: --vividness is gone" 1 (__tmux_lives_theme_cmd ember --vividness vivid 2>/dev/null; echo $status)
t "theme: --shape is gone"     1 (__tmux_lives_theme_cmd ember --shape flat 2>/dev/null; echo $status)
t "theme: --ease is gone"      1 (__tmux_lives_theme_cmd ember --ease cubic 2>/dev/null; echo $status)
t "theme: --contrast is gone"  1 (__tmux_lives_theme_cmd ember --contrast darker 2>/dev/null; echo $status)
t "theme: --vividness error says it never did anything" 1 (__tmux_lives_theme_cmd ember --vividness vivid 2>&1 | string match -q '*never affected*'; and echo 1; or echo 0)

# Existence first: an undefined function inside a `t` substitution aborts the
# statement silently and the suite still reports ALL PASS.
t "migrate_v51 exists" 0 (functions -q __tmux_lives_migrate_v51; echo $status)
set -U tmux_lives_theme_vividness vivid
set -U tmux_lives_theme_shape flat
set -U tmux_lives_theme_ease cubic
set -U tmux_lives_theme_contrast darker
__tmux_lives_migrate_v51 >/dev/null 2>&1
t "migrate_v51 erases vividness" 0 (set -q tmux_lives_theme_vividness; and echo 1; or echo 0)
t "migrate_v51 erases shape"     0 (set -q tmux_lives_theme_shape; and echo 1; or echo 0)
t "migrate_v51 erases ease"      0 (set -q tmux_lives_theme_ease; and echo 1; or echo 0)
t "migrate_v51 erases contrast"  0 (set -q tmux_lives_theme_contrast; and echo 1; or echo 0)
set -g _m51 (__tmux_lives_migrate_v51 2>&1 | string collect)
t "migrate_v51 is silent when there is nothing to erase" '' "$_m51"
t "post_update chains migrate_v51" yes (string match -q '*__tmux_lives_migrate_v51*' -- (functions _tmux_lives_post_update | string collect); and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -20`

Expected: the four `is gone` assertions fail with `got [0]` (the CLI currently accepts them and returns success), the error-text assertion fails with `got [0]`, `migrate_v51 exists` fails with `got [1]`, and the four erase assertions fail with `got [1]` because nothing erased them. Confirm you see **all** of these — if `migrate_v51 exists` is the only failure, the later assertions aborted rather than ran, which is the documented trap.

- [ ] **Step 3: Replace the four flag cases with errors**

In `__tmux_lives_theme_cmd`'s argument loop, replace the four `case` arms (1040-1047):

```fish
            case --vividness --shape --ease --contrast
                echo "tmux-lives setup theme: $argv[$i] was removed in v5.1 — it never affected the output" >&2
                return 1
```

- [ ] **Step 4: Remove their state and echoes**

Delete the `viv`/`shape`/`ease`/`con` declarations and their `have_*` flags at the top of the function, the four `set -U` lines (1126-1129), and the four confirmation echoes (1142-1144, `theme vividness/shape/ease/contrast set to`).

- [ ] **Step 5: Add the migration**

Immediately after `__tmux_lives_migrate_v41`:

```fish
function __tmux_lives_migrate_v51 --description 'v5 -> v5.1: vividness/shape/ease/contrast were accepted, stored and displayed but never reached the curve — verified byte-identical output across all 35 catalog rows at every value. Erase them; there is no value worth carrying because no value ever meant anything. Idempotent; runs on fisher update.'
    set -l had 0
    for v in tmux_lives_theme_vividness tmux_lives_theme_shape tmux_lives_theme_ease tmux_lives_theme_contrast
        if set -q $v
            set -e -U $v
            set had 1
        end
    end
    test $had -eq 1; and echo "tmux-lives: theme vividness/shape/ease/contrast retired — they never affected the output"
    return 0
end
```

- [ ] **Step 6: Chain it in `_tmux_lives_post_update`**

```fish
    __tmux_lives_migrate_v41
    __tmux_lives_migrate_v51
```

- [ ] **Step 7: Update the setup help row**

Find the `theme` row in `__tmux_lives_setup_help_lines` and drop `vividness`/`shape`/`ease`/`contrast` from its argument summary, re-padding so the framed page still fits 80 columns.

- [ ] **Step 8: Run the full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): reject the four inert knobs and erase their universals"
```

---

### Task 3: Drop the knob locals from the picker

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker` init (1600-1605), reload palette call (1678), anchor palette call (1891), three apply-live sites (2220, 2224, 2234)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_palette` (5 args) and `__tmux_lives_theme_apply_live` (4 args) from Task 1.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-categorize.fish` in the picker section (search for `picker v4 — 26-row windowed frame`, ~1790). ⚠️ That location is **below** the `set -l catfile …` at ~1520, which is required: `catfile` is `set -l`, and a guard placed above its definition expands to an empty path and passes vacuously.

```fish
# --- Task 3: the retired knobs are gone from the picker -------------------------
# Bounded to the picker body: these names legitimately survive nowhere else in
# this file, but an unbounded grep would also match unrelated prose.
set -g PBODY3 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker: no vividness local"  0 (string match -ra 'set -l viv ' -- "$PBODY3" | count)
t "picker: no shape local"      0 (string match -ra 'set -l shape ' -- "$PBODY3" | count)
t "picker: no ease local"       0 (string match -ra 'set -l ease ' -- "$PBODY3" | count)
t "picker: no contrast local"   0 (string match -ra 'set -l contrast ' -- "$PBODY3" | count)
t "picker: no anch_viv"         0 (string match -ra 'anch_viv' -- "$PBODY3" | count)
# Positive counterpart: the palette calls must still EXIST, so the guards above
# cannot be satisfied by deleting the calls outright.
t "picker: still has exactly 2 palette calls" 2 (string match -ra '__tmux_lives_theme_palette ' -- "$PBODY3" | count)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -10`

Expected: the five "no X" assertions fail with counts of 1 or more; `still has exactly 2 palette calls` passes (non-regression guard).

- [ ] **Step 3: Delete the locals**

Remove lines 1602-1605 (`set -l viv balanced` / `shape arc` / `ease linear` / `contrast auto`) and the corresponding `anch_viv`/`anch_shape`/`anch_ease`/`anch_contrast` declarations and assignments in `__tcz_thp_init` and the anchor snapshot.

- [ ] **Step 4: Shorten the palette calls**

Line 1678 (reload) and line 1891 (anchor):

```fish
                set -l p (__tmux_lives_theme_palette $seed $f[2] $f[3] $f[4] $phase)
```

```fish
            set -l ap (__tmux_lives_theme_palette $seed $anch_scheme $anch_place $anch_mode $anch_phase)
```

- [ ] **Step 5: Shorten the three apply-live sites**

Lines 2220, 2224, 2234 — drop the four trailing tokens from each:

```fish
                        fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $anch_scheme $anch_place $anch_mode $anch_phase >/dev/null 2>&1
```

```fish
                        fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" off bar derived $phase >/dev/null 2>&1
```

```fish
                    fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $rel $rplace $rmode $phase >/dev/null 2>&1
```

Leave the no-arg revert at 2261 alone — it reads the universals and is unaffected.

- [ ] **Step 6: Verify the reload cache key still holds**

The cache key at line 1667 is `"$seed|$phase|$expanded"` and already omits the knobs. Confirm it is unchanged.

- [ ] **Step 7: Run the full gate and commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "refactor(picker): drop the retired vividness/shape/ease/contrast state"
```

---

### Task 4: Rebalance the curated 14 toward tabs

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_catalog` (the `|1` / `|0` flag on each row)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_catalog_default` still returns 14 rows, now split 5 bar / 7 tabs / 2 cap.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 4: curated 14 rebalanced toward tabs ----------------------------------
# The tab bar is the dominant surface on screen; tabs placement is where a scheme
# reaches it, and it was 2 of the 14 rows shown on open. Pin the composition
# EXACTLY — a `>=` bound passed against the pre-cut catalog during the 2026-07-28
# weeding pass and hid a real composition change.
set -g CD4 (__tmux_lives_theme_catalog_default)
t "curated set is still 14" 14 (count $CD4)
t "curated bar rows"  5 (printf '%s\n' $CD4 | awk -F'|' '$3=="bar"'  | count)
t "curated tabs rows" 7 (printf '%s\n' $CD4 | awk -F'|' '$3=="tabs"' | count)
t "curated cap rows"  2 (printf '%s\n' $CD4 | awk -F'|' '$3=="cap"'  | count)
# Counts alone cannot see a swap — pin the names too.
set -g CD4N (printf '%s\n' $CD4 | awk -F'|' '{print $1}' | sort | string join ',')
t "curated names" 'amber deep,amber slate,amber soft,coral chip,ember slate,mint chip,mono soft,sage chip,sage core,sage glow,teal glow,teal slate,wheat slate,wheat soft' "$CD4N"
# Every relationship must still be reachable from the opening view.
for r in mono wheat mint amber ember coral sage teal
    set -l hits (printf '%s\n' $CD4 | awk -F'|' -v r=$r '$2==r' | count)
    t "curated covers $r" yes (test $hits -ge 1; and echo yes; or echo no)
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -15`

Expected: `curated bar rows => got [8]`, `curated tabs rows => got [2]`, `curated cap rows => got [4]`, and `curated names` failing with the old set. `curated set is still 14` passes.

- [ ] **Step 3: Flip the flags**

In `__tmux_lives_theme_catalog`, set the trailing field to `1` for exactly these 14 rows and `0` for all others:

`mono soft`, `wheat soft`, `amber soft`, `sage glow`, `teal glow`, `mint chip`, `coral chip`, `wheat slate`, `amber slate`, `ember slate`, `sage chip`, `teal slate`, `amber deep`, `sage core`.

Rows losing their flag: `mint soft`, `coral soft`, `ember glow`, `amber chip`, `coral deep`, `teal core`.

- [ ] **Step 4: Run the full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): rebalance the curated 14 toward tabs placement"
```

---

### Task 5: Add `__tmux_lives_theme_catalog_rest`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — immediately after `__tmux_lives_theme_catalog_default`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_catalog_rest` — no args, returns the catalog rows NOT flagged default, in catalog order, one per line, same `name|rel|place|mode|flag` shape.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 5: the non-default rows, as their own list ----------------------------
t "catalog_rest exists" 0 (functions -q __tmux_lives_theme_catalog_rest; echo $status)
set -g CR5 (__tmux_lives_theme_catalog_rest)
t "catalog_rest returns the other 21" 21 (count $CR5)
t "catalog_rest + default = the whole catalog" (__tmux_lives_theme_catalog | count) (math (count $CR5) + (__tmux_lives_theme_catalog_default | count))
t "catalog_rest and default do not overlap" 0 (comm -12 (printf '%s\n' $CR5 | sort | psub) (__tmux_lives_theme_catalog_default | sort | psub) | count)
t "catalog_rest preserves catalog order" yes (test "$CR5[1]" = (__tmux_lives_theme_catalog | string match -rv '\|1$' | head -1); and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `catalog_rest exists => got [1]`, and the assertions after it fail or abort. If ONLY the existence assertion reports, the rest aborted on the undefined function — that is expected here and is why the existence check comes first.

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_theme_catalog_rest --description 'the non-curated catalog rows (21): everything NOT flagged default=1, in catalog order. The picker appends these under the More Schemes header when expanded, so the curated 14 keep their positions instead of being reshuffled into tier order.'
    # -v inverts; --entire is not needed with -v (it emits whole non-matching lines).
    __tmux_lives_theme_catalog | string match -rv '\|1$'
end
```

- [ ] **Step 4: Run the full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): add __tmux_lives_theme_catalog_rest"
```

---

### Task 6: Add the `__tcz_thp_grouphdr` row builder

**Files:**
- Modify: `functions/tmux-categorize.fish` — beside the other `__tcz_thp_*` pure builders (near `__tcz_thp_zsep`, ~1361)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_thp_grouphdr <w> <label>` → one line, exactly `w` visible columns. Column 1 blank, columns 2-3 `──`, space, bold label in the `title` role, space, `─` fill stopping one column short of `w`.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 6: the More Schemes group header --------------------------------------
# A row INSIDE the list, not a frame element: the user rejected the section-border
# form because it "would make it look far too separate" and broke the single-list
# feel. So no border connectors, and it must measure like any other list row.
t "grouphdr exists" 0 (functions -q __tcz_thp_grouphdr; echo $status)
set -g GH6 (__tcz_thp_grouphdr 50 'More Schemes')
set -g GH6V (string replace -ra '\x1b\[[0-9;]*m' '' -- "$GH6")
t "grouphdr is exactly 50 visible cols" 50 (string length --visible -- "$GH6V")
t "grouphdr carries the label" yes (string match -q '*More Schemes*' -- "$GH6V"; and echo yes; or echo no)
t "grouphdr leaves col 1 blank (never selectable)" ' ' (string sub -s 1 -l 1 -- "$GH6V")
t "grouphdr has no border connectors" 0 (string match -ra '[├┤]' -- "$GH6V" | count)
t "grouphdr keeps a blank column before the right edge" ' ' (string sub -s 50 -l 1 -- "$GH6V")
t "grouphdr is one line" 1 (count $GH6)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `grouphdr exists => got [1]` and the dependent assertions abort. Add the function stub returning an empty string, re-run, and confirm the width and content assertions now FAIL with real values rather than aborting — that proves they are live.

- [ ] **Step 3: Implement**

```fish
function __tcz_thp_grouphdr --argument-names w label --description 'pure: an in-list group header, exactly <w> visible cols — col 1 blank (a scheme row carries its selection marker there; this row is never selectable), then ──, the BOLD label in the title role, then ─ fill stopping one column short of w so a blank column separates the rule from the right border. Deliberately NOT __tcz_thp_zsep: that form connects to the frame with ├ ┤ and reads as a separate section, which the user rejected.'
    set -l TIT (__tcz_theme title)
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l len (string length --visible -- "$label")
    # 1 blank + 2 dashes + 1 space + label + 1 space + fill + 1 trailing blank = w
    set -l fill (math "$w - 6 - $len")
    test $fill -lt 0; and set fill 0
    set -l fillstr (string repeat -n $fill ─)
    printf ' %s──%s \e[1m%s%s\e[22m%s %s%s %s' $MUT $RST $TIT "$label" $RST $MUT "$fillstr" $RST
end
```

- [ ] **Step 4: Run the width assertion and adjust the arithmetic if needed**

Run: `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep grouphdr`

Expected: all `grouphdr` assertions PASS. If the width is off by one, fix the `- 6` term — do not fix the test.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): add the More Schemes group-header row builder"
```

---

### Task 7: Compose the picker list as curated-then-rest

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_reload` (1665-1690)
- Test: `tests/test-tmux-install.fish` (the composition contract — pure helpers) **and** `tests/test-tmux-categorize.fish` (that the reload actually uses it)

⚠️ **The two halves must go in different suites.** `$catfile` is defined only in `tests/test-tmux-categorize.fish` (three `set -l` definitions, at ~1407, ~1520 and ~2229) and does not exist in the install suite at all. A `$catfile` grep placed in the install suite expands to an empty path and passes **vacuously** — this repo has already shipped that exact bug twice. Put the source greps in the categorize suite, **below** a `catfile` definition.

**Interfaces:**
- Consumes: `__tmux_lives_theme_catalog_rest` from Task 5.
- Produces: when `expanded` is 1 the reload iterates `catalog_default` followed by `catalog_rest`; the boundary index is `(count of catalog_default)`.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 7: expanding APPENDS, it does not reshuffle ----------------------------
# The full catalog is in TIER order, so the curated rows are scattered through it;
# swapping the row source wholesale is what made expanding "completely rewrite the
# entire list". Composing default-then-rest keeps the first 14 exactly where they
# were, which is the actual fix — preserving the cursor by name treated a symptom.
set -g ORD7 (__tmux_lives_theme_catalog_default) (__tmux_lives_theme_catalog_rest)
t "composed list is the whole catalog" 35 (count $ORD7)
t "composed list has no duplicates" 35 (printf '%s\n' $ORD7 | sort -u | count)
set -g CDN7 (__tmux_lives_theme_catalog_default | awk -F'|' '{print $1}' | string join ',')
set -g ORDN7 (printf '%s\n' $ORD7[1..14] | awk -F'|' '{print $1}' | string join ',')
t "first 14 of the composed list are the curated 14, in order" "$CDN7" "$ORDN7"
```

And in `tests/test-tmux-categorize.fish`, in the picker section **below** an existing `set -l catfile …` line, assert the reload actually uses it:

```fish
# --- Task 7: the reload composes, it does not swap the row source ----------------
set -g RB7 (awk '/function __tcz_thp_reload/,/^    end$/' $catfile | string collect)
t "reload body extraction is non-empty" 1 (test -n "$RB7"; and echo 1; or echo 0)
t "reload composes with catalog_rest" yes (string match -q '*__tmux_lives_theme_catalog_rest*' -- "$RB7"; and echo yes; or echo no)
t "reload no longer swaps to the whole catalog wholesale" 0 (string match -ra 'set rows \(__tmux_lives_theme_catalog\)' -- "$RB7" | count)
```

The `extraction is non-empty` assertion is not decoration: an awk range that matches nothing yields an empty string, and every guard built on it then passes for the wrong reason.

- [ ] **Step 2: Run both suites and confirm the right things fail**

Run: `fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -6` and `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -6`

Expected: the two `reload` assertions in the **categorize** suite fail (`got [no]` and `got [1]`). The three composition assertions in the **install** suite PASS — they are contract guards on the pure helpers from Task 5 and correctly hold already. `reload body extraction is non-empty` must also pass; if it fails, the awk range is wrong and every guard under it is meaningless.

- [ ] **Step 3: Change the row source**

In `__tcz_thp_reload`, replace lines 1674-1675:

```fish
            # Expanding APPENDS the rest under a header rather than swapping the
            # row source: the full catalog is in tier order, so a wholesale swap
            # scatters the curated rows and you lose track of what you have seen.
            set -l rows (__tmux_lives_theme_catalog_default)
            test "$expanded" = 1; and set -a rows (__tmux_lives_theme_catalog_rest)
```

- [ ] **Step 4: Run the full gate and commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-install.fish
git commit -m "feat(picker): expanding appends the rest instead of reshuffling"
```

---

### Task 8: Draw the header and window over virtual rows

**Files:**
- Modify: `functions/tmux-categorize.fish` — the draw block (1995-2015), the `m` handler (2150-2180)
- Test: `tests/test-tmux-categorize.fish` — extend the 26-row frame proof (2297-2380)

**Interfaces:**
- Consumes: `__tcz_thp_grouphdr` (Task 6), the composed list (Task 7).
- Produces: no new public function. The draw gains a `ndefault` local (count of curated rows) and treats the list as `n + 1` virtual rows when expanded.

**Why no skip logic:** `sel` indexes schemes only. The header is a pure display insertion, so `sel` can never land on it and `__tcz_thp_vismap` needs no change at all. Down from the last curated row goes to the first of the rest; up does the reverse. A special case here would have to be repeated in `↑↓`, PgUp/PgDn, `z` and the collapse clamp, and one of those would eventually disagree.

- [ ] **Step 1: Extend the frame-proof harness, then write the failing test**

`__t9_frame_rows` currently takes `(focus sel2 n sel previewed anch_scheme anchpal flashfield)` and sets its own locals before `eval`-ing the extracted draw block. Add two parameters — `expanded` and `ndefault` — and set them as locals alongside the existing ones, so the evaluated block sees them exactly as the real draw does. Also publish the rendered rows so content can be asserted:

```fish
# inside __t9_frame_rows, after the eval and before returning the count:
    set -g __t9_last_lines $lines
```

```fish
function __t9_frame_text --description 'same eval as __t9_frame_rows, but returns the rendered rows so CONTENT can be asserted, not just the row count'
    __t9_frame_rows $argv >/dev/null
    printf '%s\n' $__t9_last_lines
end
```

Then add the assertions, in the same region as the existing frame tests so `$PAL9` (a `set -l` at ~2369) is still in scope:

```fish
# --- Task 8: frame stays 26 with the header, and the header exists only expanded --
# The harness evals the REAL draw block, so it cannot drift from the implementation.
t "frame: 26 rows — expanded, header on screen"     26 (__t9_frame_rows list 0 35 13 0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — expanded, scrolled past header" 26 (__t9_frame_rows list 0 35 30 0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — expanded, top of list"          26 (__t9_frame_rows list 0 35 0  0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — collapsed is unchanged"         26 (__t9_frame_rows list 0 14 0  0 mono "$PAL9" '' 0 14)

# The header must appear ONLY when expanded — this is the fix-discriminator.
t "header absent when collapsed" 0 (__t9_frame_text list 0 14 5 0 mono "$PAL9" '' 0 14 | string match -ra 'More Schemes' | count)
t "header present when expanded near the boundary" 1 (__t9_frame_text list 0 35 13 0 mono "$PAL9" '' 1 14 | string match -ra 'More Schemes' | count)
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -12`

Expected, stated precisely because these are NOT all fix-discriminators:

- The four `26 rows` assertions **PASS** already. The draw emits 26 rows today and must continue to; they are non-regression guards, and a guard that passes at both ends is correct, not vacuous.
- `header absent when collapsed` **PASSES** already (nothing draws a header yet) — also a non-regression guard.
- `header present when expanded near the boundary` **FAILS** with `got [0]`. This is the only fix-discriminator in the set, and it must be failing before you implement.

If that assertion passes at this step, something already renders the string and the test proves nothing — stop and find out what.

- [ ] **Step 3: Compute the curated boundary once**

The picker already sources `conf.d/tmux-lives-install.fish` at open, so the pure catalog helpers are callable in-process (no subprocess, no universals — safe under `--no-config`). The boundary never changes during a session, so compute it once beside the other picker locals in `__tcz_theme_picker`, near `set -l expanded 0`:

```fish
    # Where the curated rows end and the appended ones begin. Constant for the
    # session; the reload composes default-then-rest in exactly this order.
    set -l ndefault (count (__tmux_lives_theme_catalog_default))
```

- [ ] **Step 4: Add the virtual-row mapping to the draw**

Replace the window computation at line 1995:

```fish
        # Virtual rows = schemes + the More Schemes header when expanded. sel indexes
        # SCHEMES only, so it can never land on the header and vismap needs no change:
        # stepping over it falls out of the model instead of being a special case that
        # ↑↓, PgUp/PgDn, z and the collapse clamp would each have to repeat.
        set -l vtotal $n
        set -l vsel $sel
        if test "$expanded" = 1
            set vtotal (math $n + 1)
            test $sel -ge $ndefault; and set vsel (math $sel + 1)
        end
        set -l win (__tcz_thp_window $vsel $vtotal $WIN)
```

- [ ] **Step 5: Emit the header inside the row loop**

Replace the loop body so each virtual index maps to a header or a scheme:

```fish
            for i in (seq $start (math $start + $count - 1))
                if test "$expanded" = 1; and test $i -eq $ndefault
                    set -a lines (__tcz_thp_ln (__tcz_thp_grouphdr $IW 'More Schemes') $IW $BORDER $RST)
                    continue
                end
                set -l si $i
                if test "$expanded" = 1; and test $i -gt $ndefault
                    set si (math $i - 1)
                end
                set -l idx (math $si + 1)
                set -l selflag 0
                test $focus = list; and test $si -eq $sel; and set selflag 1
                set -l curflag 0
                test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"; and test "$phase" = "$anch_phase"; and set curflag 1
                set -l row (__tcz_thp_row "$pals[$idx]" $toks[$idx] $selflag $curflag)
                if test $selflag -eq 1
                    set row (string replace -a -- "$RST" "$RST$SELBG" "$row")
                    set row "$SELBG$row$RST"
                end
                set -a lines (__tcz_thp_ln "$row" $IW $BORDER $RST)
            end
```

- [ ] **Step 6: Clamp the cursor on collapse**

In the `m` handler, after the reload and `set n (count $toks)`, add:

```fish
                # Collapsing removes the rows below the header; if the cursor was
                # down there, land it on the last curated row rather than out of range.
                set -l lastn (math $n - 1)
                test $sel -gt $lastn; and set sel $lastn
                test $sel -lt 0; and set sel 0
```

- [ ] **Step 7: Run the full gate**

Expected: 8 `ALL PASS` in both modes. Then run the frame proof's sensitivity check — temporarily add one extra `set -a lines` inside the draw, confirm the counts report 27, and revert. A frame proof that cannot see an injected row is not a proof.

- [ ] **Step 8: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): draw the More Schemes header inside the scroll window"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md` (theming section), `CLAUDE.md` (new paragraph)

- [ ] **Step 1: Update the README theming section**

Remove `--vividness`, `--shape`, `--ease`, `--contrast` from the documented knob list. Document the picker's `m` behaviour: it appends a "More Schemes" group rather than replacing the list, and the curated set is 5 bar / 7 tabs / 2 cap.

**Note the section is stale beyond this change** — it still lists the retired v3 scheme names (`aurora`, `sunset`, `complement`) and advertises `--rotate`, which now exits 1. Fixing that is explicitly out of scope for this plan; do not expand into it. Mention it in the final report so it stays on the list.

- [ ] **Step 2: Add the CLAUDE.md paragraph**

Record: the four knobs removed and how their inertness was proven; the fragment argv renumber (sync 21 → 17) and why that pairing is the only atomic part; the curated rebalance; the More Schemes model and why the header needs no skip logic; and the deferred finding that six of seven roles take only 11 distinct values across 35 rows.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: record the theme surface cleanup"
```

---

## Final verification

- [ ] Full gate: 8 `ALL PASS` in BOTH modes; record final install-suite counts and confirm the plain/`--no-config` delta is still exactly 1.
- [ ] `fish -c 'set -U | string match "tmux_lives_*"'` — confirm no universal leaked and the four retired names are absent.
- [ ] Render the fragment and eyeball that the sync line is present and the four knob args are gone.
- [ ] Confirm nothing was deployed: `~/.config/fish/` is the user's to update via `fisher update`.
