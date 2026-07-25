# Picker Current-Zone + Legend-Grid Refinement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine the gallery theme picker — pull the "current" scheme into its own `├─ current ─┤` section reachable by a `c` key (out of the `↑↓` flow), gate the `❯` in-list marker on recipe **and** phase, and rebuild the key legend as a cross-row-aligned grid.

**Architecture:** All in `functions/tmux-categorize.fish`, on branch `feat/theme-gallery-picker` (the built gallery picker, not yet merged). A new pure legend-grid builder replaces the picker's two `__tcz_legend_row` calls; the linear-sel model changes so `↑↓` spans schemes+off (`0..n`) and `c` reaches the current zone (`n+1`). The v4 engine, catalog, CLI, and windowing are unchanged.

**Tech Stack:** fish 4.x, tmux 3.3a, the `tests/test-tmux-{categorize,install}.fish` harness (bespoke `t` assertion, `-L` sockets, pure-builder unit tests + source-grep guards). The picker's interactive loop is runtime-only — verified by builders' unit tests + source-greps + a 0-stderr `--no-config` run + geometry pins + live smoke.

## Global Constraints

- **Deploy is the user's `fisher update` only** — edit → test → commit → push → stop. Never `cp` into `~/.config/fish`; never `set -U`/`set -Ux` any `tmux_lives_*` universal, **not even transiently in an ad-hoc verification command** (a mid-run `set -U` clobbered the user's live universals earlier). Verify by sourcing into a `fish --no-config -c` scratch with LOCAL vars, or a `-L` socket. If the full-suite `for` loop needs stdin isolation, redirect `< /dev/null`.
- **Run the categorize suite under BOTH `fish` and `fish --no-config`; 0 stderr bytes under `--no-config`.** Full 8-suite gate before finishing.
- **Sel model (the invariant everything depends on):** `n = count $toks` (12 default / 28 expanded). `sel 0..n-1` = scheme rows (index `sel+1` into `$recipes`/`$pals`), `sel==n` = off, `sel==n+1` = the CURRENT zone. `↑↓` (via `__tcz_thp_vismap`) spans only `0..n`; **`c` is the ONLY way to reach `n+1`**.
- **Engine/catalog/CLI/windowing unchanged.** Both `__tmux_lives_theme_palette` calls stay 9-arg.
- **fish landmines:** `math` has NO comparison operators and is FLOAT (use `test $x -lt/-gt`; `--scale=0` for integer, but note `--scale=0` ROUNDS and truncation of a negative gives the string `-0` which `test -0 -lt 0` treats as false — clamp with `-le 0`); NO command-sub inside quoted `math`; a zero-output command-sub as a bare arg VANISHES (capture to a var); `"$x[(math …)]"` ERRORS (capture the index first); `\e` is NOT interpreted in fish quoted strings (SGR must be `printf`-captured into a var); measure display width with `string length --visible`. Nested picker helpers use `--no-scope-shadowing` and are erased at the picker's end — keep that teardown in sync if you add/rename one. `__tcz_thp_leg` (Task 1) is MODULE-LEVEL (not nested) — not in that teardown.
- **Line numbers below WILL have drifted** — verify each with `grep -n` before editing.

---

## File Structure

- `functions/tmux-categorize.fish` — new module-level `__tcz_thp_leg` (before `__tcz_theme_picker` ~1438); `__tcz_thp_vismap` (~1344); `__tcz_popup_readkey` (~811, add `c`); the picker draw loop (WIN ~1814, off ~1843, anchor/current row ~1857, legend ~1867, the `❯`-marker `curflag` test) and key dispatch; the `__tcz_theme_picker` docstring.
- `conf.d/tmux-lives-install.fish` — the `-h` at the fragment bind (~163) and the CLI no-arg (~911); (modal-run `-h` is in `functions/tmux-categorize.fish` ~1003).
- `tests/test-tmux-{categorize,install}.fish` — builder unit tests, vismap test, source-grep guards, geometry pins.

The shared `__tcz_legend_row` (~794) stays for its single-row callers (switcher footer ~1097, seed screens ~1586/1654) — those are one row each, so the cross-row problem doesn't apply. Do NOT change them.

---

## Task 1: `__tcz_thp_leg` — cross-row-aligned legend grid + wire into the picker legend

**Files:** Create `__tcz_thp_leg` (module-level, before `__tcz_theme_picker`); modify the picker's legend calls (~1867). Test: `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Produces: `__tcz_thp_leg <cols> <key1> <desc1> <key2> <desc2> …` → prints one line per grid row (`cols` `key/desc` pairs per row, row-major). Column widths are the **max over ALL rows**: for column `j`, `keyw[j] = max visible-width of the keys in column j`, `descw[j] = max visible-width of the descs`. Each cell = `<key in key-color, padded to keyw[j]>` + 1 space + `<desc in muted, padded to descw[j]>`; cells joined by a 3-space gap; each row has a 1-space lead. So icons align, descriptions align, columns are separated — regardless of per-row icon width.

**Algorithm (write the fish; TDD it):**
1. `set -l pairs $argv[2..-1]`; cells = keys/descs split from the pairs (odd = key, even = desc). Guard: an odd `count` → return (malformed).
2. Compute `keyw[c]`/`descw[c]` for each column `c in 1..cols`: iterate cells, `col = ((i-1) % cols) + 1` (fish `math` supports `%`), track the max via `test $w -gt $keyw[$col]; and set keyw[$col] $w` (NO `math max`). Widths via `string length --visible -- $cell`.
3. SGR captured to vars (`\e` not interpreted in quotes): `set -l KC (printf '\e[38;2;245;207;138m')` (key color, tl `key` #f5cf8a), `set -l DC (printf '\e[38;2;124;135;112m')` (muted desc), `set -l RS (printf '\e[0m')`.
4. Pad from the PLAIN glyph width (SGR has 0 visible width): `set -l kpad (string pad -r -w $keyw[$col] -- $key)` then colorize `"$KC$kpad$RS"`; likewise desc. (Or compute the space count and append — either way pad by the visible-width deficit.)
5. Emit rows: loop cells, build the current row's cells, and start a new output line every `cols` cells (track a counter — do NOT precompute nrows via `--scale=0` division, which rounds; just wrap on `col == cols`). Join a row's cells with a 3-space gap, prefix 1 space, print the line.

**Picker wiring:** replace the two `__tcz_thp_ln (__tcz_legend_row 12 …) …` calls (~1867-1868) with a loop over `__tcz_thp_leg`'s output, each line wrapped by `__tcz_thp_ln`:
```fish
for lline in (__tcz_thp_leg 3 '↑↓' move '←→' phase b seed  m more z shake c current  a apply '⏎' save esc close)
    set -a lines (__tcz_thp_ln "$lline" $IW $BORDER $RST)
end
```
(9 pairs, 3 cols → 3 rows: `↑↓ move · ←→ phase · b seed` / `m more · z shake · c current` / `a apply · ⏎ save · esc close`. The `c current` label is new here; its handler is Task 2.)

**Steps:**
- [ ] **Step 1: Failing unit tests** (pure builder — the crux is cross-row alignment):
```fish
# 3x3 grid with varying icon widths; strip SGR, split into lines, assert each column's descriptions start at the SAME visible offset on every row.
set -l L (__tcz_thp_leg 3 '↑↓' move '←→' phase b seed  m more z shake c current  a apply '⏎' save esc close)
t "leg emits 3 rows" 3 (count $L)
# column-3 desc ("seed"/"current"/"close") starts at the same visible index on all 3 rows:
set -l off1 (string length --visible -- (string match -r '^(.*)close' -- (__tcz_strip_sgr $L[3]))[2])
# (Implementer: assert the visible index of the col-3 desc is identical across rows via __tcz_strip_sgr + index math; and that icon↔desc gap is 1, and each row's visible width ≤ IW. Pin the exact expected offsets.)
t "leg row fits IW" 1 (test (string length --visible -- (__tcz_strip_sgr $L[1])) -le 50; and echo 1; or echo 0)
```
(Use the existing `__tcz_strip_sgr` helper. Pin concrete expected column offsets so the test genuinely gates alignment.)
- [ ] **Step 2: Run → FAIL** (`__tcz_thp_leg` undefined).
- [ ] **Step 3: Implement** `__tcz_thp_leg` + wire into the picker legend.
- [ ] **Step 4: Verify** — unit tests pass; categorize suite `ALL PASS` both configs; `--no-config` 0 stderr.
- [ ] **Step 5: Commit** — `git commit -am "feat(picker): __tcz_thp_leg aligned legend grid (cross-row column widths) + 3x3 picker legend"`

---

## Task 2: Current zone + `c` jump key + vismap + `❯` phase gate

**Files:** `functions/tmux-categorize.fish` — `__tcz_thp_vismap` (~1344), `__tcz_popup_readkey` (~811), the draw loop's off/anchor/marker region (~1843-1867) and key dispatch, the docstring. Test: `tests/test-tmux-categorize.fish`.

**Changes:**
- **`__tcz_thp_vismap` (~1344):** clamp `↑↓` to `0..n` (was `0..n+1`): `down` → `min(n, sel+1)` (change the `vmax` from `math $n + 1` to `$n`); `up` unchanged (`max(0, sel-1)`). Update its `--description` (drop "anchor n+1" from the `↑↓` order — anchor is now `c`-only). Update its unit tests (grep `__tcz_thp_vismap` in the test file): `down` from `n` (off) stays `n`; `n+1` is never produced by vismap.
- **`__tcz_popup_readkey` (~811):** add a byte→token mapping for `c` (0x63 → `c`), following the exact pattern used for the other picker keys (`p`/`m`/etc). Extend the `--description` enum. **Named risk to verify:** the switcher `__tcz_popup` also consumes `__tcz_popup_readkey`; confirm its dispatch has NO `case c` (it doesn't — cases are up/down/enter/kill/cancel), so `c` remains a no-op there.
- **Key dispatch — add `case c`:** toggle the current zone. `if test $sel -eq (math $n + 1); set sel 0; else; set sel (math $n + 1); end` (jump to current, or back to the top scheme). `set flashfield ''`. (When on `n+1`, `↑` via vismap won't apply since vismap clamps to `n`; but the `up`/`down` arms call vismap with the current `sel` — from `n+1`, vismap `up`→`min(n, n+1-1)=n` (off), `down`→`min(n,n+2)=n`. So `↑↓` from the current zone returns to `off`. Acceptable; or special-case: from `n+1`, any `↑↓` → the list. Keep it simple: vismap naturally pulls `n+1` back to `n`.)
- **Draw loop — separate the current zone (~1843-1867):** keep the `off` row (sel `n`) at the end of the scrollable list. Then emit a **`├─ current ─┤`** zone separator (`__tcz_thp_zsep $IW 'current' $BORDER $RST`), then the current row (the existing anchor render at ~1857-1859, `__tcz_thp_row`/`__tcz_thp_off_row` with `"$anch_scheme · current"`), drawn UNCONDITIONALLY (pinned), with `anchflag = (test $sel -eq (math $n + 1))`. The current row is BELOW `off`, in its own titled section, then the legend follows.
- **`❯` marker phase gate (the `curflag` test in the scheme loop):** change
  `test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"; and set curflag 1`
  →
  `test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"; and test "$phase" = "$anch_phase"; and set curflag 1`.
- **Docstring:** update `__tcz_theme_picker` — `↑↓` = schemes + off; `c` = current zone; `❯` = recipe+phase match; legend keys.

**Steps:**
- [ ] **Step 1: Failing tests:**
```fish
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "vismap down clamps at n (off), not n+1" n (__tcz_thp_vismap 10 10 down)   # n=10: off=10, down stays 10
t "picker has case c"        1 (string match -qr 'case c\b' -- "$pbody"; and echo 1; or echo 0)
t "readkey maps c"           c (__tcz_popup_readkey </dev/null; …)            # implementer: feed byte 0x63, expect token c (mirror existing readkey byte tests)
t "marker gates on phase"    1 (string match -q '*= "$anch_phase"*' -- "$pbody"; and echo 1; or echo 0)
t "current zone zsep"        1 (string match -q '*zsep $IW *current*' -- "$pbody"; and echo 1; or echo 0)
```
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** vismap + readkey + `case c` + current-zone render + marker gate + docstring.
- [ ] **Step 4: Verify** — both configs `ALL PASS`, `--no-config` 0 stderr.
- [ ] **Step 5: Commit** — `git commit -am "feat(picker): current zone + c jump key (out of ↑↓ flow), ❯ recipe+phase marker"`

---

## Task 3: Adjustments-zone alignment, geometry, guards, full suite

**Files:** `functions/tmux-categorize.fish` (WIN/`-h`, adjustments zone, docstring), `conf.d/tmux-lives-install.fish` (`-h` × 2), tests (geometry pins + guards). Test: whole categorize + full 8-suite.

**Changes:**
- **Geometry recount:** the current zone added a `├─ current ─┤` sep (+1 vs the old single anchor row) and the legend went 2→3 rows (+1) → ~+2. Re-read the draw loop, count the exact emitted `set -a lines` rows (16 static was the gallery baseline; now `16 + 1 (current sep) + 1 (legend row) = 18` static + `WIN`). Choose `WIN` (keep 8 → `-h 26`, or drop to 7 → `-h 25`) so the total ≤ ~26. Set `-h <total>` at all three open sites (`grep -n '52 -h 24\|-h 24'`) + the test geometry pins; update stale-24 guards.
- **Adjustments-zone alignment:** confirm the seed/phase kv (`__tcz_thp_kv`) columns align; if the seed/phase labels/values are ragged, apply the same padding discipline (the `__tcz_thp_kv` builder already aligns label/value — likely a no-op; verify and note).
- **Consolidated grep guards:** picker has `case c` + the `❯` phase-gate + a `current` zsep + uses `__tcz_thp_leg`; `__tcz_thp_vismap` clamps at `n`; both palette calls still 9-arg; no `case p`/`ring`/`rotpal`/`rotate`.
- **Frame-encloses check:** a grep guard that the current-zone rows and legend rows go through `__tcz_thp_ln` (wrapped), and the bottom border is the last emitted line.

**Steps:**
- [ ] **Step 1: Geometry + guard tests** (pin the chosen `-h`; the consolidated guards).
- [ ] **Step 2: Run → any geometry mismatch fails.**
- [ ] **Step 3: Implement** geometry + zone alignment + guards.
- [ ] **Step 4: Full acceptance gate:**
```bash
fish -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish $t < /dev/null 2>&1 | tail -1; end'
fish --no-config -c 'for t in tests/test-*.fish; echo -n "$(basename $t): "; fish --no-config $t < /dev/null 2>&1 | tail -1; end'
fish --no-config tests/test-tmux-categorize.fish 2>/tmp/se.txt >/dev/null; echo "stderr: $(wc -c < /tmp/se.txt)"
```
Expected: every suite `ALL PASS` both configs; `stderr: 0`. Confirm no `tmux_lives_*` universal leak (snapshot before/after identical — and use `< /dev/null` so no killed-mid-run clobber).
- [ ] **Step 5: Commit** — `git commit -am "chore(picker): current-zone geometry (-h), zone alignment, guards, suite green"`

---

## Live smoke (user, after `fisher update`)

- `c` jumps the cursor to the `├─ current ─┤` zone and back; `↑↓` reaches schemes + `off` but never the current zone; the current row is border-titled, always visible.
- `❯` appears on a list row only when it renders identically to current (recipe + phase); nudging `←→` phase clears it; it's independent of the cursor.
- The legend is a clean aligned table (icons + descriptions column-aligned across all rows); the adjustments zone aligns; the frame encloses every row.
- The popup fits (no top-border scroll) at all three open sites.

## Self-Review

**Spec coverage:** separated current zone + `c` key + vismap → Task 2; `❯` recipe+phase → Task 2; `▲▼` on schemes rule → already built (Task 3 confirms, no change); cross-row legend grid → Task 1; adjustments alignment + frame-encloses + geometry → Task 3. Engine/catalog/CLI unchanged → asserted (9-arg guard, no engine edits).

**Placeholder scan:** the legend unit test's exact expected offsets and the readkey byte-test are marked "implementer: pin/mirror" — they must be filled with concrete values against the real builder/readkey (the existing tests show the pattern); `WIN`/`-h` is a Task-3 measurement. No silent TBDs in the logic.

**Type/name consistency:** `__tcz_thp_leg <cols> <pairs…>` (Task 1) wired in the same task; `case c` toggles `sel` to/from `n+1` consistent with vismap clamping at `n` (Task 2); the `curflag` phase gate uses `$phase`/`$anch_phase` (both already in scope). 

## Open items (carry into review)
- **`c` on the shared `__tcz_popup_readkey`** — verify the switcher no-op (named risk, Task 2).
- **`↑↓` from the current zone** returns to `off` (vismap pulls `n+1`→`n`) — acceptable per spec; confirm at live smoke it feels right (else special-case to jump to the top).
- **Legend builder offsets** — the unit test must pin real cross-row alignment, not a tautology.
