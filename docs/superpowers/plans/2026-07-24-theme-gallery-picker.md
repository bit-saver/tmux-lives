# Theme Gallery Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the theme picker's model-B list (6 relationships + place/mode knobs) with a curated **gallery** — a flat scrolling list of named `(relationship, place, mode)` catalog schemes, opening on 12 and expanding to 28 with `m`.

**Architecture:** A new install-side **catalog** (28 ordered schemes, 12 flagged default) is the single source of truth, consumed by both the CLI (`setup theme list`) and the picker. The picker rewrites its list to iterate the catalog (default-12 or all-28), adds a **windowed scroll** (the one new mechanism — the shipped picker drew every row exact-height), drops the place/mode knobs (baked into each entry), and saves the selected entry's recipe through the unchanged `setup theme` CLI. The v4 engine and palette signature are untouched.

**Tech Stack:** fish 4.x, tmux 3.3a, the `tests/test-tmux-{categorize,install}.fish` harness (bespoke `t` assertion helper, `-L` sockets, pure-builder unit tests + source-grep structural guards). The picker's interactive loop is runtime-only — verified by source-greps + a 0-stderr `--no-config` run + geometry pins + the user's live smoke.

## Global Constraints

- **Deploy is the user's `fisher update` only** — edit → test → commit → push → stop. Never `cp` into `~/.config/fish`; never `set -U`/`set -Ux` a `tmux_lives_*` universal in tests. Smoke-test live-apply with a `-L` socket + `set -gx tmux_lives_tmux_socket`, NEVER `set -Ux`.
- **Run the categorize suite under BOTH `fish` and `fish --no-config`; it must be 0 stderr bytes under `--no-config`:** `fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; wc -c < /tmp/se.txt` → `0`. Run the full 8-suite gate before finishing.
- **Engine unchanged (consume, do not modify):** `__tmux_lives_theme_palette <seed> <relationship> <place> <mode> <phase> <vividness> <shape> <ease> <contrast>` → 7 hexes `bar sep tabs active windows cap text`. `place ∈ {bar,tabs,cap,low,high}`, `mode ∈ {literal,derived}`. `setup theme <rel> --place <p> --mode <m> [--phase N]` persists; `--rotate` is gone (errors).
- **The catalog is the shared source of truth.** 28 ordered schemes across 5 tiers (soft=bar·derived, glow=bar·literal, slate=tabs·derived, deep=cap·derived, core=cap·literal); mono contributes only soft/glow/core (its other placements are byte-identical). Exactly 12 carry `default=1`. Names are `<relationship> <tier-word>`.
- **fish landmines** (real defects if present): `math` has NO comparison operators — use `test $x -lt/-gt`; NO command substitution inside a quoted `math "…"` (capture to a var first); a zero-output command substitution used as a bare arg VANISHES (capture into a var, then quote); `"$x[(math …)]"` is an error; `\e` is NOT interpreted in fish quoted strings — SGR/escapes must be `printf`-captured into a var; a multi-line `string match -r` result assigned in `(…)` without `| string collect` flattens newlines to spaces. Nested picker helpers use `--no-scope-shadowing` and are erased at the end of `__tcz_theme_picker` — keep that teardown in sync if you add/rename one.
- **Line numbers below WILL have drifted** — verify every anchor with `grep -n` before editing.

---

## File Structure

- `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_catalog` + `__tmux_lives_theme_catalog_default`; rewrite `__tmux_lives_theme_list` (@ ~856) to render the catalog. (The v4 engine functions above it are untouched.)
- `functions/tmux-categorize.fish` — the picker `__tcz_theme_picker` (@ ~1416) and its nested `__tcz_thp_init` (~1439) / `_reload` (~1478) / `_litkv` (~1510); the draw loop + key dispatch (~1820-1960); the anchor snapshot (~1660-1674); a new pure module-level `__tcz_thp_window`.
- `tests/test-tmux-install.fish` — catalog + list tests, geometry pins.
- `tests/test-tmux-categorize.fish` — window-helper unit tests + picker source-grep guards.

---

## Task 1: Install-side catalog + `setup theme list`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add two functions near the other `__tmux_lives_theme_*` accessors (after `__tmux_lives_theme_relationships` @ ~706); rewrite `__tmux_lives_theme_list` @ ~856.
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_catalog` → 28 lines `name|rel|place|mode|default`; `__tmux_lives_theme_catalog_default` → the 12 lines with `default=1`. Both consumed by Task 2 (picker) and by `__tmux_lives_theme_list`.

**Changes:**

- [ ] **Step 1: Write the failing tests** (add to the theme section of `tests/test-tmux-install.fish`; find it with `grep -n 'theme_relationships\|__tmux_lives_theme_list' tests/test-tmux-install.fish`):

```fish
t "catalog has 28 entries" 28 (count (__tmux_lives_theme_catalog))
t "catalog default is 12"  12 (count (__tmux_lives_theme_catalog_default))
t "catalog entries are 5 fields" 5 (count (string split '|' (__tmux_lives_theme_catalog | head -1)))
t "catalog default subset of all" 1 (test (count (__tmux_lives_theme_catalog | string match -r '\\|1\$')) -eq 12; and echo 1; or echo 0)
# every recipe is a valid engine input -> 7-hex palette
set -l bad 0
for e in (__tmux_lives_theme_catalog)
    set -l f (string split '|' $e)
    set -l p (__tmux_lives_theme_palette '#5f772b' $f[2] $f[3] $f[4] 0 balanced arc linear auto)
    test (count $p) -eq 7; or set bad (math $bad + 1)
end
t "every catalog recipe yields 7 hexes" 0 $bad
t "theme list names ember glow" 1 (string match -q '*ember glow*' -- (__tmux_lives_theme_list | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run to verify it fails** — `fish tests/test-tmux-install.fish 2>&1 | grep -iE 'catalog|theme list names'` → FAILs (functions undefined; list has no such name).

- [ ] **Step 3: Implement.** Add after `__tmux_lives_theme_relationships`:

```fish
function __tmux_lives_theme_catalog --description 'v4 gallery catalog: 28 schemes as name|relationship|place|mode|default (1 = in the curated default 12), ordered near-seed -> bold across tiers soft/glow/slate/deep/core. Shared source of truth for the picker + setup theme list.'
    printf '%s\n' \
        'mono soft|mono|bar|derived|1'   'amber soft|amber|bar|derived|1'  'coral soft|coral|bar|derived|1' \
        'ember soft|ember|bar|derived|0' 'sage soft|sage|bar|derived|0'    'teal soft|teal|bar|derived|0' \
        'mono glow|mono|bar|literal|0'   'amber glow|amber|bar|literal|0'  'ember glow|ember|bar|literal|1' \
        'coral glow|coral|bar|literal|0' 'sage glow|sage|bar|literal|1'    'teal glow|teal|bar|literal|1' \
        'amber slate|amber|tabs|derived|0' 'ember slate|ember|tabs|derived|1' 'coral slate|coral|tabs|derived|0' \
        'sage slate|sage|tabs|derived|0'   'teal slate|teal|tabs|derived|0' \
        'amber deep|amber|cap|derived|1' 'ember deep|ember|cap|derived|1'  'coral deep|coral|cap|derived|1' \
        'sage deep|sage|cap|derived|0'   'teal deep|teal|cap|derived|0' \
        'mono core|mono|cap|literal|0'   'amber core|amber|cap|literal|0'  'ember core|ember|cap|literal|0' \
        'coral core|coral|cap|literal|0' 'sage core|sage|cap|literal|1'    'teal core|teal|cap|literal|1'
end

function __tmux_lives_theme_catalog_default --description 'the curated 12: catalog rows flagged default=1'
    __tmux_lives_theme_catalog | string match -r '\|1$'
end
```

Then rewrite `__tmux_lives_theme_list` (@ ~856) to iterate the catalog instead of relationships — for each entry, compute its palette at the current seed/knobs and print `<name>  <7-role gradient strip>`. Preserve the existing strip-rendering helper the old body used (read it first: `grep -n 'function __tmux_lives_theme_list' -A25 conf.d/tmux-lives-install.fish`); only the loop source changes from `__tmux_lives_theme_relationships` to `__tmux_lives_theme_catalog` (split each line on `|` for name/rel/place/mode).

- [ ] **Step 4: Verify** — `fish tests/test-tmux-install.fish 2>&1 | tail -1` → `ALL PASS`; re-run the two catalog counts; `fish --no-config tests/test-tmux-install.fish 2>&1 | tail -1` → `ALL PASS`.

- [ ] **Step 5: Commit** — `git commit -am "feat(theme): gallery catalog (28 schemes, 12 default) + setup theme list"`

---

## Task 2: Picker `_reload`/`_init` consume the catalog

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_init` (~1439), `__tcz_thp_reload` (~1478), and the picker-level var block (~1435-1477, where `place`/`mode` are declared).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_catalog`, `__tmux_lives_theme_catalog_default`, the 9-arg `__tmux_lives_theme_palette`, `__tmux_lives_contrast_fg`.
- Produces: after this task `_reload` populates `toks` (entry names), `pals` (palettes), `fgs`/`tabsfgs`, and a NEW parallel array `recipes` (`"<rel>|<place>|<mode>"` per visible entry), from the default-12 or all-28 per the picker-level `expanded` var. `$n = count $toks` (12 or 28).

**Changes:**
- In `__tcz_theme_picker`, in the var block, REPLACE the `set -l place …` / `set -l mode …` picker knobs with `set -l expanded 0` (0 = show the default 12, 1 = all 28). (place/mode are per-entry now — `_reload` reads them from each catalog line, not from picker vars.)
- `__tcz_thp_init` (~1439): remove the `place`/`mode` universal reads (they are no longer picker knobs); keep `seed`/`phase`/`viv`/`shape`/`ease`/`contrast`/`legacy`/`seedfg`. Re-index the `init[N]` unpack for the two dropped fields (COUNT the echo lines vs unpack indices and confirm they match — a silent off-by-one corrupts state).
- `__tcz_thp_reload` (~1478): rewrite the batch —
  - cache key: `set -l key "$seed|$phase|$expanded"` (was `"$seed|$place|$mode|$phase"`).
  - source rows: `set -l rows (__tmux_lives_theme_catalog_default); test "$expanded" = 1; and set rows (__tmux_lives_theme_catalog)`.
  - iterate `for e in $rows`: `set -l f (string split '|' $e)`; then `set -l p (__tmux_lives_theme_palette $seed $f[2] $f[3] $f[4] $phase $viv $shape $ease $contrast)`.
  - append `$f[1]` (name) to `toks`, `"$f[2]|$f[3]|$f[4]"` to `recipes`, and the palette + fgs to `pals`/`fgs`/`tabsfgs` using the SAME storage convention the current `_reload` uses (read it first; keep the blob/replay shape, just add the `recipes` field). Declare `recipes` in the erase/reset alongside `toks`/`pals`.

**Steps:**
- [ ] **Step 1: Write the failing tests:**

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker uses catalog"           1 (string match -q '*__tmux_lives_theme_catalog*' -- "$pbody"; and echo 1; or echo 0)
t "picker default-12 accessor"    1 (string match -q '*__tmux_lives_theme_catalog_default*' -- "$pbody"; and echo 1; or echo 0)
t "picker drops relationships iter" 0 (string match -q '*for tok in (__tmux_lives_theme_relationships)*' -- "$pbody"; and echo 1; or echo 0)
t "picker has recipes array"      1 (string match -q '*recipes*' -- "$pbody"; and echo 1; or echo 0)
t "picker has expanded state"     1 (string match -q '*expanded*' -- "$pbody"; and echo 1; or echo 0)
t "picker still 9-arg palette"    1 (string match -q '*__tmux_lives_theme_palette $seed *$phase $viv $shape $ease $contrast*' -- "$pbody"; and echo 1; or echo 0)
```
(`$catfile` is defined in the picker test region — confirm with `grep -n 'set -l catfile' tests/test-tmux-categorize.fish`.)

- [ ] **Step 2: Run to verify it fails** — FAILs (still iterates relationships; no recipes/expanded).
- [ ] **Step 3: Implement** the `_init`/`_reload`/var-block changes above.
- [ ] **Step 4: Verify** — `fish tests/test-tmux-categorize.fish 2>&1 | tail -1` → `ALL PASS`; `fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; wc -c </tmp/se.txt` → `0`. Spot-check the engine feeds the rows: source the engine and confirm `__tmux_lives_theme_palette '#5f772b' ember cap derived 0 balanced arc linear auto` returns 7 hexes.
- [ ] **Step 5: Commit** — `git commit -am "feat(picker): consume gallery catalog in _reload/_init (recipes + expanded, drop place/mode knobs)"`

---

## Task 3: Windowed scrolling list + linear navigation

**Files:**
- Create (module-level, before `__tcz_theme_picker`): `functions/tmux-categorize.fish` — `__tcz_thp_window`.
- Modify: the list-render section of the draw loop (find with `grep -n 'for i in (seq' functions/tmux-categorize.fish` near the picker), the navigation (`__tcz_thp_vismap` @ ~1344 and its `up`/`down` callers @ ~1826-1828).
- Test: `tests/test-tmux-categorize.fish`

**Why:** the catalog is 12 or 28 rows but the popup shows only a handful. The shipped picker drew every row (exact height); the gallery needs a fixed-size window that scrolls to keep the selection visible, with `▲`/`▼` overflow counts.

**Interfaces:**
- Produces: `__tcz_thp_window <sel> <total> <winsize>` → prints `<start> <count>` — the first visible row index (0-based) and how many rows to draw, clamped so `sel` is always within `[start, start+count)` and the window never runs past `total`. Consumed by the list render.

**Changes:**
- Navigation model becomes **linear**: visual order is `scheme_0 … scheme_{n-1}, off, anchor` (anchor last). `sel` ranges `0 … n+1` (`n` = `count $toks`; `sel=n` is the off row, `sel=n+1` is the anchor). Replace the `__tcz_thp_vismap` special "anchor at sel 0 / bottom" logic with a plain clamp: `up` → `max(0, sel-1)`, `down` → `min(n+1, sel+1)`. (Keep `__tcz_thp_vismap` as the function name and signature `<sel> <n> <dirn>` so the callers at ~1826-1828 need no change; just simplify its body to the linear clamp over `0..n+1`. Update its `--description`.)
- **Only the SCHEMES scroll; `off` + `anchor` are PINNED below the window, always drawn** (the spec's "anchor at the bottom, for revert-compare" — it must stay visible while you browse). Window the schemes: `set -l winsel $sel; test $winsel -gt (math $n - 1); and set winsel (math $n - 1)` (clamp the off/anchor selections to the last scheme for windowing); `set -l win (__tcz_thp_window $winsel $n $WIN)`; `set -l ws (string split ' ' $win); set -l start $ws[1]; set -l count $ws[2]`. Draw scheme rows `start … start+count-1` (highlight the one matching `$sel`), then ALWAYS draw the `off` row (highlight if `sel==n`) and the `anchor` row (highlight if `sel==n+1`) below. Add a `▲<above>` when `start>0` and `▼<below>` when `start+count<n` (hidden scheme counts) on the scheme-zone separator or legend line — kept so the frame height stays fixed.
- `$WIN` (visible SCHEME rows) is a fixed constant chosen in Task 5 with the geometry; use a named `set -l WIN 7` here and let Task 5 tune it. The frame height is then chrome + `$WIN` + off(1) + anchor(1) — independent of 12 vs 28.

**Steps:**
- [ ] **Step 1: Write the failing unit tests** (pure helper — add near the other `__tcz_thp_*` builder tests):

```fish
t "window: fits, no scroll"    "0 5"  (__tcz_thp_window 0 5 8)
t "window: top of long list"   "0 8"  (__tcz_thp_window 2 28 8)
t "window: scrolled middle"    "9 8"  (__tcz_thp_window 12 28 8)
t "window: clamped at bottom"  "20 8" (__tcz_thp_window 27 28 8)
t "window: sel always visible" 1 (set -l w (__tcz_thp_window 15 28 8); set -l s (string split ' ' $w); test 15 -ge $s[1] -a 15 -lt (math $s[1] + $s[2]); and echo 1; or echo 0)
```
(These pin a concrete scroll policy — window follows sel, clamped to `[0, total-winsize]`; adjust the expected `"9 8"`/`"20 8"` if you choose a different centering, but keep "sel always visible" green.)

- [ ] **Step 2: Run to verify it fails** — `__tcz_thp_window` undefined → FAIL.
- [ ] **Step 3: Implement** `__tcz_thp_window` (pure; `math` for arithmetic, `test` for compares — no `math` comparison operators):

```fish
function __tcz_thp_window --argument-names sel total winsize --description 'pure: window a long list -> "<start> <count>" (0-based first visible index + rows to draw), clamped so sel stays visible and the window never overruns total'
    if test $total -le $winsize
        echo "0 $total"; return
    end
    set -l start (math "$sel - $winsize / 2")
    test $start -lt 0; and set start 0
    set -l maxstart (math "$total - $winsize")
    test $start -gt $maxstart; and set start $maxstart
    echo "$start $winsize"
end
```
Then wire the list render + linear `__tcz_thp_vismap` as described.

- [ ] **Step 4: Verify** — unit tests `ALL PASS`; full categorize suite `ALL PASS` both configs; `--no-config` 0 stderr.
- [ ] **Step 5: Commit** — `git commit -am "feat(picker): windowed scrolling list + linear nav (__tcz_thp_window)"`

---

## Task 4: Key dispatch, expand, shake, recipe save, anchor + marker, adjustments zone

**Files:**
- Modify: `functions/tmux-categorize.fish` — the key-dispatch `switch` (~1820-1960), the anchor snapshot (~1660-1674), the adjustments-zone kv calls + `__tcz_thp_litkv` (~1510), the `❯`-marker comparison in the list render, the `__tcz_theme_picker` docstring (~1416).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `recipes` (Task 2), `$expanded`, `__tcz_thp_reload`, the anchor snapshot vars.
- Produces: final key map — `↑↓/jk` move · `←→` phase · `b` seed · `m` expand/collapse · `z` shake · `a` apply · `⏎` save · `esc/q` close.

**Changes (in the dispatch `switch`):**
- DELETE `case p` (~1872), `case P`, `case m M` (~1896), and `case r` (place/mode/reset knobs — grep `case r` to confirm its line). place/mode/reset no longer exist.
- ADD `case m`: toggle expand — `test "$expanded" = 1; and set expanded 0; or set expanded 1`; then clamp `sel` to the new list length (`set -l nn (count (test "$expanded" = 1; and __tmux_lives_theme_catalog; or __tmux_lives_theme_catalog_default))` won't work mid-loop — instead reload first, then clamp against the new `$n`). Concretely: flip `expanded`, call `__tcz_thp_reload`, then `set n (count $toks)`, then `test $sel -gt (math $n + 1); and set sel (math $n + 1)`. Set `flashfield ''`.
- `case z` (shake, ~1912): set `expanded 1` (so a bold pick is reachable), then `set -l zi (random 0 27)` and `set sel $zi` (a random scheme index over all 28 — capture the random into a var FIRST, never inside quoted `math`); reload; `set flashfield ''`.
- `case a` (apply-preview, ~1933) and `case enter` (save, ~1945): derive the target from the selection —
  - if `sel` is a scheme row (`test $sel -lt $n`): `set -l rc (string split '|' $recipes[(math $sel + 1)])`; `set -l rel $rc[1]; set -l place $rc[2]; set -l mode $rc[3]`.
  - if `sel` is the off row (`test $sel -eq $n`): target is `off`.
  - if `sel` is the anchor row (`test $sel -eq (math $n + 1)`): use `$anch_scheme $anch_place $anch_mode`.
  - apply-preview: `fish -c '__tmux_lives_theme_apply_live $argv' $rel $place $mode $phase $viv $shape $ease $contrast >/dev/null 2>&1` (8-arg preview form; for `off` call `__tmux_lives_theme_apply_live off …` or the theme-off path as the shipped picker does).
  - save (`enter`): assemble `$apply`/`$place`/`$mode`/`$phase` for the post-loop `fish -c 'tmux-lives setup theme $argv[1] --place $argv[2] --mode $argv[3] --phase $argv[4]' "$apply" "$place" "$mode" "$phase"` (the shipped save invocation already lives just after the loop — grep `setup theme $argv` to find it; it already takes `--place/--mode/--phase`, so only the SELECTION→(rel,place,mode) derivation changes).
- **Anchor snapshot** (~1660-1674): it already captures `anch_place`/`anch_mode` (the shipped picker added them). Keep those. The anchor's own palette-build call (~1674) stays 9-arg. No change needed beyond confirming it still compiles once place/mode are no longer picker vars (the anchor reads the PERSISTED place/mode from `__tcz_thp_init`'s universal reads — but Task 2 removed those reads! So RE-ADD a one-time read of the persisted `place`/`mode` universals in the anchor-snapshot block: `set -l anch_place (__tmux_lives_key tmux_lives_theme_place bar)` / `set -l anch_mode (__tmux_lives_key tmux_lives_theme_mode derived)` — the anchor needs the persisted values even though they're not live knobs).
- **`❯` marker:** in the list render, mark a scheme row when its `recipes[i]` equals the persisted `"$anch_scheme|$anch_place|$anch_mode"` (grep the current marker comparison `= "$anch_scheme"` and replace with the recipe compare).
- **Adjustments zone:** reduce to seed + phase only (drop the place/mode kv). Update BOTH the draw-loop `__tcz_thp_kv` calls AND `__tcz_thp_litkv` so they render the same fields.
- Update the `__tcz_theme_picker` docstring to the gallery model + key map.

**Steps:**
- [ ] **Step 1: Write the failing tests:**

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "no place-cycle key"     0 (string match -qr 'case p\b' -- "$pbody"; and echo 1; or echo 0)
t "m is expand"            1 (string match -q '*expanded*' -- "$pbody"; and string match -qr 'case m\b' -- "$pbody"; and echo 1; or echo 0)
t "save reads recipes"     1 (string match -q '*recipes[*' -- "$pbody"; and echo 1; or echo 0)
t "save passes --place"    1 (string match -q '*--place*' -- "$pbody"; and echo 1; or echo 0)
t "anchor reads persisted place" 1 (string match -q '*tmux_lives_theme_place*' -- "$pbody"; and echo 1; or echo 0)
t "shake captures random first"  0 (count (string match -ar 'math "[^"]*\(random' -- "$pbody"))
t "zone drops place kv"    0 (string match -qr "kv .*place .\$place" -- "$pbody"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the dispatch/anchor/marker/zone/docstring changes.
- [ ] **Step 4: Verify** — categorize suite `ALL PASS` both configs; `--no-config` 0 stderr.
- [ ] **Step 5: Commit** — `git commit -am "feat(picker): gallery keys — m expand, z shake, recipe save, ❯ marker, seed/phase zone"`

---

## Task 5: Geometry, consolidated guards, full suite green

**Files:**
- Modify: `functions/tmux-categorize.fish` (popup `-h` if the windowed frame's row count changed; docstring), the three open sites + test pins; `tests/test-tmux-categorize.fish` + `tests/test-tmux-install.fish` (guards + geometry pins).
- Test: whole categorize suite + full 8-suite gate.

**Changes:**
- **Geometry:** the frame is now chrome + `$WIN` scheme rows (fixed window) + off(1) + anchor(1) — the off/anchor rows are PINNED below the window (Task 3), so they are extra, not inside `$WIN`. Re-read the draw loop and count the exact emitted `set -a lines` rows: chrome (borders, tab chip, preview, adjustments seps + seed/phase kv, scheme-zone sep, legend/overflow, note) + `$WIN` + 2. Pick `$WIN` so the total is a clean height, then set `-h <total>` at all three open sites (`grep -n '52 -h 22\|-h 22' conf.d/tmux-lives-install.fish functions/tmux-categorize.fish`) AND every test geometry pin (`grep -n '52x22\|-h 22\|52x2' tests/`). HARD CONSTRAINT: `-h` must be **≥** the emitted row count; `== ` is the tight ideal; `<` scrolls the top border (the 2026-07-14 bug). The draw emits rows `1..-2` with `\n`, the last without.
- **Consolidated grep guards** (idempotent): picker body uses `__tmux_lives_theme_catalog`; has `case m` (expand) + `recipes`; has NO `case p`/`case P`; still has NO `__tmux_lives_theme_ring`/`__tcz_thp_rotpal`/`tmux_lives_theme_rotate`; every `__tmux_lives_theme_palette` call is 9-arg.
- If `__tcz_thp_vismap`'s old special-order tests exist and now assert the removed behavior, update them to the linear clamp; do not weaken.

**Steps:**
- [ ] **Step 1: Write the geometry + guard tests** (pin the chosen `-h <N>` at all sites; the consolidated guards).
- [ ] **Step 2: Run to verify** any geometry mismatch fails.
- [ ] **Step 3: Implement** geometry + guards.
- [ ] **Step 4: Full acceptance gate:**
```bash
fish -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish $t 2>&1 | tail -1; end'
fish --no-config -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish --no-config $t 2>&1 | tail -1; end'
fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; echo "stderr: $(wc -c < /tmp/se.txt)"
```
Expected: every suite `ALL PASS` both configs; `stderr: 0`. Confirm no `tmux_lives_*` universal leak.
- [ ] **Step 5: Commit** — `git commit -am "chore(picker): gallery geometry, guards, full suite green"`

---

## Live smoke (user, after `fisher update` — not automatable)

- `M-k` / `setup theme` (no arg) / `M-m k` open the gallery on the 12; the swatches are non-blank.
- `↑↓` scroll with correct windowing + `▲`/`▼` markers; `m` expands to 28 and collapses back (selection preserved/clamped); `←→` phase; `b` seed; `z` shake lands on a (possibly bold) scheme; `a` apply-preview; `⏎` save persists `(rel, place, mode)` and the bar updates; anchor row + `❯` on the persisted scheme; `esc` revert. Tabs stay quiet. No stray key errors; no cursor flicker / stderr in the popup.
- `setup theme list` shows the 28 catalog names.

## Self-Review

**Spec coverage:** catalog + list → Task 1; gallery list (default-12 / all-28) → Task 2; windowed scroll → Task 3; `m` expand / `z` shake-over-28 / recipe save / `❯` marker / seed+phase knobs → Task 4; geometry + guards → Task 5. Quiet tabs → no change (engine untouched). Character names → Task 1 catalog. Engine/CLI unchanged → asserted (9-arg palette guard, no engine files beyond the catalog accessor). Escape hatch (`m` expand + CLI) → Tasks 4 + 1.

**Placeholder scan:** the exact `$WIN`/`-h` values are computed in Task 5 from the real row count (a measurement, not a placeholder — the shipped picker's Task 5 did the same); the default-12 membership is concrete in Task 1's catalog. No TBDs.

**Type/name consistency:** `__tmux_lives_theme_catalog`/`_catalog_default` (Task 1) consumed verbatim in Tasks 2/4/5; `recipes` array introduced in Task 2, read in Task 4; `expanded` introduced Task 2, toggled Task 4; `__tcz_thp_window <sel> <total> <winsize>` (Task 3) called in the list render; the anchor persisted-place/mode read (Task 4) mirrors the universals `tmux_lives_theme_place`/`_mode`.

## Open items (carry into review)

- **Anchor persisted place/mode:** Task 2 removes the picker-knob reads of `tmux_lives_theme_place`/`_mode`, and Task 4 re-adds a one-time read in the anchor block. Verify the anchor still shows the correct persisted scheme (its `❯` marker matches).
- **`$WIN` / geometry** (Task 5): only the schemes scroll; off + anchor are pinned below the window, so the frame height is chrome + `$WIN` + 2, independent of 12 vs 28. Confirm the exact-height contract holds and the anchor stays visible while scrolling.
- The interactive loop is runtime-only; confidence rests on source-greps + 0-stderr + the user's live smoke.
