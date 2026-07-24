# Theme v4 Picker (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the theme picker (`__tcz_theme_picker` + `__tcz_thp_*` in `functions/tmux-categorize.fish`) for the v4 engine using model B — the 6 relationships as the list, `place`/`mode` as knobs — un-breaking `M-k` / `setup theme` (no arg) / `M-m k`.

**Architecture:** All work is in `functions/tmux-categorize.fish`, in and around the `__tcz_theme_picker` function (starts line ~1427) and its nested helpers `__tcz_thp_init`/`_reload`/`_litkv` plus the draw loop and key dispatch. The install-side v4 engine (`__tmux_lives_theme_relationships`, the 9-arg `__tmux_lives_theme_palette`, etc., shipped in main @ `a49d226`) is consumed unchanged. The picker sources that engine once at open (already does) and runs its hot path in-process; universal-touching actions go through config-loaded `fish -c` children (already the pattern). No install-side changes.

**Tech Stack:** fish 4.x, tmux 3.3a, the `tests/test-tmux-categorize.fish` harness (bespoke `t` assertion helper, `-L` sockets, pure-builder unit tests + source-grep structural guards). The picker's interactive loop is runtime-only — verified by source-greps + a 0-stderr suite run + live smoke, not unit tests.

## Global Constraints

- **Deploy is the user's `fisher update` only** — edit → test → commit → push → stop. Never `cp` into `~/.config/fish` or `set -U` the user's universals. Smoke-test with a `-L` socket and `set -g`, NEVER `set -Ux` (a prior session leaked `tmux_lives_bar_color` this way).
- **Run the categorize suite under BOTH `fish` and `fish --no-config`**, and it must be **0 stderr bytes** under `--no-config`: `fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; wc -c < /tmp/se.txt` → `0`. (The v4 Phase-1 final review caught a broken block spraying a `Unknown command: __tmux_lives_theme_ring` trace; this rewrite must leave zero such traces.)
- **The v4 engine signatures** (consume, do not change): `__tmux_lives_theme_relationships` → 6 names `mono amber ember coral sage teal` (one per line); `__tmux_lives_theme_palette <seed> <relationship> <place> <mode> <phase> <viv> <shape> <ease> <contrast>` → 7 hexes `bar sep tabs active windows cap text`; there is **no** `__tmux_lives_theme_ring` (deleted) and **no** rotation. `place ∈ {bar,tabs,cap,low,high}`, `mode ∈ {literal,derived}`, `low`/`high` force derived.
- **Model B + switchability seam:** the list is populated by iterating ONE axis (relationships) at the fixed knob values (place/mode/phase); keep "what fills the list" and "what the knobs hold" cleanly separated so a future B→A flip is small. Row-render/draw code stays axis-agnostic (`<label> <7-swatch strip>`).
- **Hidden knobs:** the picker does NOT show or change `vividness/shape/ease/contrast` — it READS their stored values in `_init` and passes them through to the palette (so the preview is faithful), but exposes no knob for them. `rotate` is gone entirely.
- **fish landmines:** `math` has NO comparison operators — use `test $x -lt/-gt`; NO command substitution inside quoted `math`; a zero-output command substitution used as a bare arg VANISHES (capture into a var, then quote); `"$x[(math …)]"` errors; `\e` is not interpreted in fish quoted strings — bold/SGR must be `printf`-captured vars. Nested picker helpers use `--no-scope-shadowing` and are erased at the end of `__tcz_theme_picker` (lines ~1993-1998) — keep that teardown in sync if you add/rename one.

---

## File Structure

Single file: `functions/tmux-categorize.fish`. Key anchors (verify with `grep -n` before editing — line numbers drift):
- `__tcz_theme_picker` function + docstring: ~1427. Nested `_init` ~1449, `_reload` ~1486, `_litkv` ~1522, `_hexentry` ~1532, `_sliders` ~1585, `_cleanup` ~1698; the helper-erase block ~1993.
- Draw loop: ~1723; adjustments-zone `__tcz_thp_kv` calls ~1767-1772 and in `_litkv` ~1524-1525; list render ~1774-1808; legend rows ~1810-1812; key dispatch cases ~1837-1985.
- Pure builders (module-level, before the picker): `__tcz_thp_row` ~1150, `_off_row` ~1174, `_kv` ~1252, `_vismap` ~1340, `_rotpal` ~1366.

Tests: `tests/test-tmux-categorize.fish` (pure-builder tests + source-grep guards; find the theme-picker test region with `grep -n 'theme_picker\|thp_' tests/test-tmux-categorize.fish`).

---

## Task 1: v4 engine wiring in `_reload` + `_init` (un-break the swatches)

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_reload` (~1486-1521), `__tcz_thp_init` (~1449-1478).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_relationships`, the 9-arg `__tmux_lives_theme_palette`, `__tmux_lives_contrast_fg`.
- Produces: after this task, `_reload` populates `toks` with the 6 relationship names and `pals` with their 7-role v4 palettes at the current `place`/`mode`/`phase`; `_init` reads `place`/`mode` and drops `rotate`. The picker-level vars `place`/`mode` exist.

**Changes:**
- In `__tcz_theme_picker`, replace the `set -l rotate 0` var (~1445) with `set -l place bar` and `set -l mode derived`.
- `_init` (~1449): in the `fish -c` init block, DROP the `echo (__tmux_lives_key tmux_lives_theme_rotate 0)` line and ADD `echo (__tmux_lives_key tmux_lives_theme_place bar)` and `echo (__tmux_lives_key tmux_lives_theme_mode derived)` (after the theme line, before the derive_status line — keep the positional unpacking below in sync). Update the `set … $init[N]` unpacking so `place`/`mode` are assigned and `rotate` is gone; the `legacy`/`seedfg` indices shift by the net change (dropped 1, added 2 → +1).
- `_reload` (~1486): rewrite the batch:
  - cache key becomes `set -l key "$seed|$place|$mode|$phase"` (was `"$seed|$phase|$viv|$shape|$ease|$contrast"`).
  - iterate `for tok in (__tmux_lives_theme_relationships)` (was `__tmux_lives_theme_schemes`).
  - `set -l p (__tmux_lives_theme_palette $seed $tok $place $mode $phase $viv $shape $ease $contrast)` (9-arg; `$viv/$shape/$ease/$contrast` are the stored values `_init` read).
  - DELETE the `__tmux_lives_theme_ring` call and the `$g`/`gj` ring handling; the blob line becomes `"$tok|$pj|$capfg|$tabsfg"` (no ring field).
  - DELETE the `__tcz_thp_rotpal` call in the blob-replay loop (~1516) — `pals` gets `$f[2]` directly (the palette); the fg fields shift down by one (`$f[3]`/`$f[4]` → `$f[3]`/`$f[4]` after dropping the ring field, so re-index: blob is now `tok|pal|capfg|tabsfg`, so `f[1]=tok f[2]=pal f[3]=capfg f[4]=tabsfg`).

**Steps:**
- [ ] **Step 1: Write the failing grep tests** (add to the picker test region in `tests/test-tmux-categorize.fish`):

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker uses v4 relationships"      1 (string match -q '*__tmux_lives_theme_relationships*' -- "$pbody"; and echo 1; or echo 0)
t "picker drops v3 schemes"           0 (string match -q '*__tmux_lives_theme_schemes*'      -- "$pbody"; and echo 1; or echo 0)
t "picker drops deleted ring"         0 (string match -q '*__tmux_lives_theme_ring*'         -- "$pbody"; and echo 1; or echo 0)
t "picker drops rotpal"               0 (string match -q '*__tcz_thp_rotpal*'                -- "$pbody"; and echo 1; or echo 0)
t "picker reads place universal"      1 (string match -q '*tmux_lives_theme_place*'  -- "$pbody"; and echo 1; or echo 0)
t "picker reads mode universal"       1 (string match -q '*tmux_lives_theme_mode*'   -- "$pbody"; and echo 1; or echo 0)
t "picker drops rotate universal"     0 (string match -q '*tmux_lives_theme_rotate*' -- "$pbody"; and echo 1; or echo 0)
```

(`$catfile` is defined near the top of the theme-picker test region — confirm with `grep -n 'set -l catfile\|set catfile' tests/test-tmux-categorize.fish`; if absent in scope, add `set -l catfile $plugindir/functions/tmux-categorize.fish` before these lines.)

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -iE 'picker (uses|drops|reads)'`
Expected: several FAIL (schemes/ring/rotpal/rotate still present, relationships/place/mode absent).

- [ ] **Step 3: Implement** the `_reload`/`_init` changes above.

- [ ] **Step 4: Verify green + 0 stderr**

Run:
```bash
fish tests/test-tmux-categorize.fish 2>&1 | tail -1
fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; echo "stderr bytes: $(wc -c < /tmp/se.txt)"
```
Expected: `ALL PASS`, `stderr bytes: 0`. Also spot-check the palettes are non-empty: source the engine and confirm `__tmux_lives_theme_palette '#5f772b' ember bar derived 0 balanced arc linear auto` returns 7 hexes (this is what the picker now feeds its rows).

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "fix(picker): v4 engine wiring — relationships + 9-arg palette, drop ring/rotate"
```

---

## Task 2: Adjustments zone + 6-relationship list (model B surface)

**Files:**
- Modify: `functions/tmux-categorize.fish` — the draw loop's adjustments-zone `__tcz_thp_kv` calls (~1767-1772), `__tcz_thp_litkv` (~1522-1531), and the zone-separator label (~1766).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `place`/`mode`/`phase`/`seed`/`viv`… vars from Task 1. `__tcz_thp_kv` (pure, unchanged signature: `<w> <flashfield> <label> <value> …`).
- Produces: the adjustments zone shows `seed`, `place`, `mode`, `phase` (no rotate/viv/shape/ease/contrast); the list still renders one row per `toks` entry (now 6 relationships) via the existing `__tcz_thp_row` path.

**Changes:**
- The adjustments zone currently renders two kv lines: `kv1 = seed/phase/vividness/shape` and `kv2 = contrast/rotate/ease`. Replace with the v4 set. Recommended: `kv1 = seed <chip> · place <place> · mode <mode>`, `kv2 = phase +<phase>°`. Keep it to the same two kv lines so the 27-row frame geometry is unchanged (the list shrank from 10→6, so there is slack; the frame height can stay 27 or shrink — see Task 5). Update BOTH the draw-loop kv calls AND the matching `_litkv` kv calls (they must render the same fields or the lit-first flash paints stale labels).
- Update the zone-separator label at ~1766 from `'adjustments · apply to all schemes'` to `'adjustments'` (or similar) — it no longer applies to "all schemes".
- Update the list zone-separator (~1773) from `'scheme · companion sets for the seed'` to `'relationship · hue-travels for your seed'`.
- The list loop (~1774) already iterates `seq $n` over `toks` and calls `__tcz_thp_row "$pals[$i]" $toks[$i] …`; with Task 1, `toks` is the 6 relationships and `pals` their v4 palettes, so this works unchanged. `$n` = `count $toks` = 6 — confirm `$n` is derived from `count $toks` (grep for `set -l n`); if it's hardcoded or from `theme_schemes`, fix it to `count $toks`.

**Steps:**
- [ ] **Step 1: Write the failing tests**

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "zone shows place"      1 (string match -q '*place*' -- "$pbody"; and echo 1; or echo 0)
t "zone shows mode"       1 (string match -q '*mode*'  -- "$pbody"; and echo 1; or echo 0)
t "zone drops vividness"  0 (string match -q '*vividness*' -- "$pbody"; and echo 1; or echo 0)
t "zone drops rotate lbl" 0 (string match -q '*rotate*'    -- "$pbody"; and echo 1; or echo 0)
t "list label is relationship" 1 (string match -q '*relationship*' -- "$pbody"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run to verify it fails** — `fish tests/test-tmux-categorize.fish 2>&1 | grep -iE 'zone|list label'` → FAILs.

- [ ] **Step 3: Implement** the kv/label changes in the draw loop AND `_litkv`.

- [ ] **Step 4: Verify** — suite `ALL PASS` both configs, 0 stderr (as Task 1 Step 4). The pure-builder `__tcz_thp_kv` tests should still pass (its signature is unchanged).

- [ ] **Step 5: Commit** — `git commit -m "feat(picker): v4 adjustments zone (place/mode) + relationship list"`

---

## Task 3: Key dispatch — place/mode knobs, drop retired keys, adapt z-shake + apply/save

**Files:**
- Modify: `functions/tmux-categorize.fish` — the key-dispatch `switch` in the draw loop (~1837-1985), and the picker docstring (~1427).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `place`/`mode`/`phase` vars, `__tmux_lives_theme_relationships` (for shake), the config-loaded-child save path.
- Produces: the final key map — `↑↓/jk` relationship, `p/P` place, `m/M` mode, `←→` phase, `b` seed, `z` shake, `a` apply, `⏎` save, `r` reset, `Esc/q` close. No `v/V/s/e/d/D/o/O`.

**Changes (in the `switch $tok` dispatch):**
- DELETE the cases: `v`, `V`, `s S`, `e E`, `d`, `D`, `o`, `O` (vividness/shape/ease/contrast/rotate — lines ~1884-1938). Each currently sets a var, then `set flashfield <field>`, `__tcz_thp_litkv`, `__tcz_thp_reload`.
- ADD a `case p` / `case P` pair cycling `place` through `bar → tabs → cap → low → high → bar` (P reverses), following the exact shape of the deleted `d`/`D` contrast cycle (mutate `place`, `set flashfield place`, `__tcz_thp_litkv`, `__tcz_thp_reload`). NB when `place` becomes `low`/`high`, force `set mode derived` (the engine forces it; keep the picker consistent so the preview matches the save).
- ADD a `case m` / `case M` toggling `mode` between `literal` and `derived` (following the `s S` shape-toggle shape). When `place` is `low`/`high`, `m` is a no-op (or snaps back to derived) — those placements are derived-only.
- `case r` (reset knobs, ~1940): reset `phase 0`, `place bar`, `mode derived` (drop the viv/shape/ease/contrast/rotate resets).
- `case z` (shake, ~1948): capture randoms into vars first (fish does NO command substitution inside quoted math — `set -l zp (random 0 71); set phase (math "$zp * 5")`), then randomize: a random relationship (pick `toks[(random 1 (count $toks))]` → set `sel` to that index), a random `place` (from the 5), a random `mode` (literal/derived, but derived if place low/high), and phase. Set `flashfield` to the changed set (space-joined), `__tcz_thp_litkv`, `__tcz_thp_reload`.
- `case a` (apply-preview, ~1963) and `case enter` (save, ~1975): the palette/apply calls must pass `place`/`mode`. Apply-preview calls `__tmux_lives_theme_apply_live $rel $place $mode $phase $viv $shape $ease $contrast` (8-arg preview path — matches the install-side `apply_live` preview arm). Save (Enter) runs the config-loaded child `fish -c 'tmux-lives setup theme $argv[1] --place $argv[2] --mode $argv[3] --phase $argv[4]' <rel> <place> <mode> <phase>` silenced. For the ANCHOR row (sel 0), save/apply its frozen snapshot (Task 4 supplies the anchor's `place`/`mode`).
- Update the `__tcz_theme_picker` docstring to describe the v4 keys.

**Steps:**
- [ ] **Step 1: Write the failing tests**

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "key p cycles place"  1 (string match -qr 'case p\b' -- "$pbody"; and echo 1; or echo 0)
t "key m cycles mode"   1 (string match -qr 'case m\b' -- "$pbody"; and echo 1; or echo 0)
t "no vividness key"    0 (string match -qr 'case v\b' -- "$pbody"; and echo 1; or echo 0)
t "no rotate key"       0 (string match -qr 'case o\b' -- "$pbody"; and echo 1; or echo 0)
t "save passes --place" 1 (string match -q '*--place*' -- "$pbody"; and echo 1; or echo 0)
t "save passes --mode"  1 (string match -q '*--mode*'  -- "$pbody"; and echo 1; or echo 0)
# fish landmine guard: no command substitution inside quoted math (z-shake)
t "shake captures random first" 0 (count (string match -ar 'math "[^"]*\(random' -- "$pbody"))
```

- [ ] **Step 2: Run to verify it fails** — FAILs on the added/removed cases.
- [ ] **Step 3: Implement** the dispatch changes + docstring.
- [ ] **Step 4: Verify** — suite `ALL PASS` both configs, 0 stderr.
- [ ] **Step 5: Commit** — `git commit -m "feat(picker): v4 keys — p/m place/mode, drop retired knobs, place/mode save"`

---

## Task 4: Anchor snapshot + save semantics + legend

**Files:**
- Modify: `functions/tmux-categorize.fish` — the anchor-snapshot capture (grep `anch_` near the picker open), the anchor render (~1796-1808), the legend rows (~1810-1812).
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `place`/`mode` from Task 1; the anchor-snapshot vars (`anch_scheme`, `anch_phase`, …).
- Produces: the anchor captures `place`/`mode` (drops `rotate`); the legend reflects the v4 keys.

**Changes:**
- Find the anchor snapshot (grep `set -l anch_scheme` / `anch_rotate`). Replace `anch_rotate` capture with `anch_place`/`anch_mode` (snapshot the persisted place/mode at open). The anchor label is `$anch_scheme · current` — keep, or extend to `$anch_scheme <place>/<mode> · current` if it fits the row width (optional).
- The anchor's apply/save (in Task 3's `a`/`enter` handling for sel 0) uses `$anch_scheme $anch_place $anch_mode $anch_phase`.
- Legend rows (~1810-1812): rewrite to the v4 keys. Recommended two rows via `__tcz_legend_row` (pitch 12): row1 `←→ phase · p place · m mode · z shake`, row2 `b seed · a apply · ⏎ save · r reset · esc close`. Keep within the frame width (the `__tcz_legend_row` builder measures visible width; test the geometry in Task 5).

**Steps:**
- [ ] **Step 1: Write the failing tests**

```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "anchor snapshots place" 1 (string match -q '*anch_place*' -- "$pbody"; and echo 1; or echo 0)
t "anchor drops rotate"    0 (string match -q '*anch_rotate*' -- "$pbody"; and echo 1; or echo 0)
t "legend names place"     1 (string match -q '*place*' -- "$pbody"; and echo 1; or echo 0)
t "legend drops rotate"    0 (string match -qr 'rotate' -- (awk '/__tcz_legend_row/' $catfile | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** — suite `ALL PASS` both configs, 0 stderr.
- [ ] **Step 5: Commit** — `git commit -m "feat(picker): v4 anchor place/mode snapshot + legend"`

---

## Task 5: Guards, geometry, cleanup, full suite green + 0 stderr

**Files:**
- Modify: `functions/tmux-categorize.fish` (frame-height/geometry if the row count changed the 27-row frame), `tests/test-tmux-categorize.fish` (guards + geometry pins).
- Test: whole categorize suite + full 8-suite run.

**Changes:**
- The list shrank 10 relationships-rows → 6, so the frame is shorter by 4 content rows. Decide: keep the popup at 52×27 (extra blank rows) or shrink to fit (e.g. 52×23). Whichever — the frame builder emits rows `1..-2` with `\n` and the last row without (the exact-height contract; a mismatch scrolls the top border off, the 2026-07-14 bug). Update the `-w 52 -h <N>` at the picker's launch site(s) (`__tmux_lives_cap_picker`/`M-k` fragment bind/`__tcz_modal_run` `k` — grep `theme-picker` / `-h 27`) AND any `-h 27` geometry pin in the tests to the chosen height. Recommend shrinking to fit for a tighter picker; if unsure, keep 27 (safe, just roomier).
- Add the consolidated grep guards (idempotent even if earlier tasks added subsets): picker body has no `__tmux_lives_theme_ring`/`_schemes`/`_rotpal`/`theme_rotate`/`case o`/`case v`; has `__tmux_lives_theme_relationships` + the 9-arg palette + `case p`/`case m`.
- If `__tcz_thp_rotpal` is now unused anywhere (grep the whole file), DELETE the function + its unit tests (it was the v3.2 rotation permutation; v4 has no rotation). Confirm nothing else calls it first.

**Steps:**
- [ ] **Step 1: Write the geometry + guard tests** (pin the chosen `-h <N>` at all launch sites; the consolidated guards above).
- [ ] **Step 2: Run to verify** any geometry mismatch fails.
- [ ] **Step 3: Implement** geometry + guards + any `_rotpal` removal.
- [ ] **Step 4: Full acceptance gate** — run BOTH:
```bash
fish -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish $t 2>&1 | tail -1; end'
fish --no-config -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish --no-config $t 2>&1 | tail -1; end'
fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; echo "stderr: $(wc -c < /tmp/se.txt)"
```
Expected: every suite `ALL PASS` both configs; `stderr: 0`. Confirm no `tmux_lives_*` universal leak (before/after a run identical).
- [ ] **Step 5: Commit** — `git commit -m "chore(picker): v4 geometry, guards, remove dead rotpal, suite green"`

---

## Live smoke (user, after the build ships via fisher update — not automatable)

- `M-k`, `setup theme` (no arg), and `M-m k` all open the picker; the 6 relationships render with correct, non-blank swatches.
- `p`/`m` re-render all rows; `low`/`high` force derived; `←→` phase; `z` shake; `b` seed sliders + typed hex; anchor row + `❯`; `a` apply-preview; `⏎` save persists `(relationship, place, mode)` and the bar updates.
- No stray key does nothing-visible (verify `v/s/e/d/o` are inert, not error). No cursor flicker / stderr in the popup.

## Self-Review

**Spec coverage:** Model B list + place/mode knobs → Tasks 1-3. Switchability seam (list-axis vs knobs separated in `_reload`) → Task 1. Hidden knobs (read stored, no UI) → Tasks 1-3. Kept features (anchor/z-shake/seed-slider/flash/preview) → Tasks 3-4 + unchanged code. Engine-call fix → Task 1. Save via `setup theme --place --mode` → Task 3. 0-stderr guard → every task's Step 4 + Task 5. Grep guards → each task + Task 5. Geometry → Task 5. ✦-on-cell literal overlay → spec says optional/first-cut-skip, so no task (documented omission, not a gap).

**Placeholder scan:** the picker's interactive loop is not unit-testable, so several tasks verify via source-greps + 0-stderr + live smoke rather than behavioral asserts — this is the codebase's established picker-testing reality (the existing tests do the same), not a placeholder. The exact kv-line wording and legend text are left to the implementer within the stated fields (a style choice, not an under-specification).

**Type/name consistency:** `place`/`mode` picker vars introduced in Task 1, consumed in 2-4; `anch_place`/`anch_mode` in Task 4 mirror the Task-1 vars; the palette is the 9-arg v4 signature everywhere; `__tcz_thp_rotpal` removed only in Task 5 after all callers are gone (Task 1 stops calling it, Task 5 deletes it).

## Open items (carry into review)

- **A/B is provisional** (spec). Keep the `_reload` list-axis/knob seam clean; don't bury B-specific assumptions in the row-render/draw code.
- **Frame height** (Task 5): shrink-to-fit vs keep-27 is a judgment call — either is correct as long as the exact-height emit contract holds.
- **`p`/`m` key collisions** with the raw-tty readchar classification — live-smoke check (spec open item).
- The interactive loop is runtime-only; the plan's confidence rests on source-greps + 0-stderr + the user's live smoke.
