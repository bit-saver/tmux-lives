# Landing Header Top Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the landing app a new row 1, a `─` line in the mode color (coral 203 landing, teal 37 switching) across the legend's width, so the badge and key legend sit between two lines; the frame gives up one row, `x`'s y/n prompt follows the legend to row 2, and a page key still steps one frame height less one row.

**Architecture:** `__tcz_landing_paint` already hands its rows to `__tcz_popup_emit` in screen order (legend, header line, frame). It gains one row in front: the top line, built inline beside the legend from the new fourth entry of `__tcz_landing_frame_glyphs`; the frame it asks `__tcz_popup_frame` for shrinks from `rows - 2` to `rows - 3` rows. In `__tcz_landing`, the `case kill` prompt moves from row 1 to row 2 and the page arms step `max(1, rows - 4)`. `__tcz_landing_header_line`, `__tcz_popup_frame` and `__tcz_popup_emit` are untouched.

**Tech Stack:** fish 4 (`fish --no-config` scripts), tmux 3.3a (rocket) / 3.7b (macwork), the repo's own fish test suites.

**Spec:** `docs/superpowers/specs/2026-09-26-landing-session-design.md`. Read the Status line's "Header top line" sentence; "Drawing (v3.1)" → the **Mode color** and **Header** bullets; "## Switch mode (v3)" → the teal bullet; "## Testing" → "Layout (v3.1)"; "## Open items" → "Rulings taken while building v3.1" (the `x` prompt, the narrow layout) and "Rulings for the header top line". The approved rendering is variant B on mockup page 19: `artifacts/mockgen/chooser-v3/gen19.py` (`variant("B")` → `top_line("─", …)`; rocket only, gitignored) — the real v3.1 paint at `rows - 1` under a new first row of `─` × (cols − 1) in the mode color, the last column blank, no junction.

## Global Constraints

- ⛔ **LIVE-SERVER RULE.** Every agent shell runs inside the user's LIVE tmux: `$TMUX` names his real server and `TMUX` beats `TMUX_TMPDIR`. Every tmux command you type names its socket (`command tmux -f /dev/null -L <name>` / `-S <path>`) or runs inside a suite that pins one; never a bare `tmux`, never a bare `kill-server`. A review agent killed the live server this way on 2026-09-29 (`docs/2026-09-29-review-agent-killed-live-tmux-server.md`). Put this rule in every sub-agent prompt.
- ⛔ **Never deploy.** No `fisher install/update`, no `cp` into `~/.config/fish/`, no edits to `~/.tmux.conf`, no `set -U`. Work on branch `feat/landing-top-line` (in a worktree, per superpowers:using-git-worktrees) and commit there; the user deploys with his own `fisher update`.
- Any ad-hoc run of the landing app outside a suite exports `tmux_lives_render_cache_dir`, `tmux_lives_claude_projects_dir` and `tmux_lives_project_cache` to temp paths first. Never `find /` on this host (CIFS mounts hang it). The Bash tool runs zsh: quote `=word`, and a non-matching glob aborts the command.
- **Gate:** each suite is its own FOREGROUND Bash call with `timeout: 600000`, plain then `--no-config`. **Never run two suites at once.**
  - `fish tests/test-<name>.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('` (and the same with `fish --no-config`)
  - the popup suite only as `env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish [--no-config] tests/test-tmux-popup.fish`. `artifacts/` is gitignored: in a fresh worktree create the stub first: `mkdir -p artifacts/notmux && printf '#!/bin/sh\nexit 1\n' > artifacts/notmux/tmux && chmod +x artifacts/notmux/tmux`
  - never wrap a suite in shell `timeout`; never judge by `tail -1`
  - if a Bash call reports it was backgrounded, do not start anything else and do not judge a partial read. While planning, the harness backgrounded every categorize run (~6 min) at 180 s despite `timeout: 600000`, so re-running in the foreground only repeats that, and killing a run mid-way leaks its test servers. Instead: send the suite to a log (`fish tests/test-tmux-categorize.fish > <scratch>/cat.log 2>&1`), let a backgrounded run finish untouched, and judge the log with the grep above once its completion notice arrives.
  - afterwards `/tmp/tmux-1000/` holds only `default` and `neurotest*` (sweep leaked `-L` sockets; never touch `default`).
- Baseline at `main` `95f22eb` (9/9 `ALL PASS` both modes per CLAUDE.md; measured while planning: popup 140 `ok`, categorize 1718 (the RED run's 1719 assertions less the new e2e (d))). `test-tmux-install.fish` 962 plain / 961 `--no-config` (the 1-count delta is BY DESIGN — do not "fix" it), `test-generic.fish` 3, `test-tmux-status.fish` 4. No task here touches the install suite: the pair stays 962/961; if it changes, stop and report.
- **Known flake, not this change:** `switch: x on the current session closes it the landing way -- … and the switcher exits` failed in 1 of 8 categorize runs while planning (the RED run, on the pre-change code) on its last field (`__tcg_swgone`, a 3 s poll for the switcher's session to go), and passed in the 7 runs with this plan's code. It tests `case kill`'s y path and the switcher's exit, which this plan does not change, not the prompt's row. If it fails for you, re-run the suite once before investigating, and report it either way.
- **Briefs in this repo have contained defects every build** (unsatisfiable or vacuous assertions, off-by-one geometry, a fixture whose natural order made the wrong answer coincide with the right one, a false RED claim). If the code disagrees with this plan, the code wins: say so in your report with the evidence.
- Every new or changed assertion is shown to FAIL against the pre-change code (RED), except the ones a step names as non-regression guards. Capture into a variable first: an undefined function called directly inside `t` aborts the statement silently and the suite still reports `ALL PASS`. Ask of every fixture: would a plausible wrong implementation land on the same row or value?
- Mutation checks use full-tree scratch copies (`cp -a` of the repo into the scratchpad), never `git checkout`/`git stash` on the working tree; re-take the copy immediately before each mutation.
- Code comments are brief: what a reader needs now. History, dates and measurements go in the commit message. American spelling in new comments and prose (color, gray). A `--description` states the caller's contract in under ~400 characters (the painter's is 414 today and 407 after this plan).
- No new files in `conf.d/` or `functions/`, and no new functions: this change extends the painter and the loop. Test helpers are `__tcp_*` (popup suite) and `__tcg_*` (categorize suite), each erased (`functions -e`) after its last use; this plan adds none.
- The frame glyphs are spelled once in code (`__tcz_landing_frame_glyphs`, four entries after this plan) and once in tests (the single assertion that pins the list, `"▔ ▕ ▕ ─"`); every other assertion reads the list. The mode colors 203 and 37 are spelled only in `__tcz_landing_paint` (and in tests).
- fish traps that return a wrong answer instead of an error (CLAUDE.md → "Traps"):
  - a zero-output command substitution collapses the whole enclosing argument: capture into a variable, use it quoted
  - the tests pass a glyph from the list quoted (`string repeat -n 99 -- "$g[4]"`): against the pre-change three-entry list, an unquoted `$g[4]` would vanish from the argument list, while the quoted one is an empty string and the comparison fails cleanly
  - `printf --` is not an option terminator
  - `string match -r` with a prefix pattern returns the matched substring
  - `"$var[...]"` in double quotes is list indexing (spell an escape via `(printf '\e[0m')` or a variable, never `"$E[0m"`)
  - never iterate `(seq (count $x))` where the count can be 0: macOS `seq 0` prints `1 0`
- No new `case` labels in `__tcz_landing` (the categorize suite extracts theme-picker arms with awk patterns keyed on exact 12-space `case …` lines). This plan adds a comment line inside the `case pgup` arm, not a label.
- Run the repo's own checks only; there is no formatter or linter for fish here.

## Rulings taken for the user

The spec settles the design (its "Rulings for the header top line"). Two implementation choices it leaves to the plan:

- The top line is built inline in `__tcz_landing_paint`, beside the legend it sits over, not by a helper: it is one colored repeat of one glyph with no junction to place, and a helper would exist only for its tests (style guide §8). The painter's tests pin it. `__tcz_landing_header_line` stays the one line helper because it places the junction.
- The page step keeps its `max(1, …)` floor: `max(1, rows - 4)`, the spec's "one frame height less one row" with the frame at `rows - 3`.

## What already exists

Lines at `95f22eb`; find by content, lines drift.

- `__tcz_landing_frame_glyphs` — `functions/tmux-categorize.fish:21-23`: the top-of-file list (header line, junction, divider) and its two-line comment. The top line becomes its fourth entry, so `[1]`–`[3]` keep their meaning everywhere they are read (`__tcz_landing_header_line`, `__tcz_popup_frame`'s `DIV`, both suites).
- `__tcz_landing_paint` — `:1717`: builds the frame (`(math $rows - 2)`, `:1742`), the legend (`:1744`) and emits `legend, header line, frame` (`:1745`).
- `__tcz_landing_header_line` — `:1748`: unchanged. `__tcz_popup_layout` (`:2071`), `__tcz_legend_row` (`:2301`), `__tcz_popup_truncate`: unchanged.
- `__tcz_landing` — `:1788`: `case pgup`/`case pgdn` (`:1958-1961`, step `max(1, $rows - 3)`); `case kill`'s prompt (`:1993`, `\e[1;1H`) and the `set -g __tcz_pe_force 1` after it (its comment, "the prompt overwrote the legend", stays true).
- `__tcz_popup_emit` — `:2401`: unchanged. It emits its arguments as screen rows 1..n (a partial paint addresses row `i` as `\e[i;1H`) and repaints whole when the row count changes, so a fourth header row needs nothing from it.
- `__tcz_popup_frame` — `:2448`: unchanged; it draws exactly `<rows>` lines (none when `<rows>` ≤ 0).
- `tests/test-tmux-popup.fish`: `__tcp_cell` (`:106`, erased at `:426`), the painter test block (`:341-383`), the paint block (`:385-429`, fixture `BM` `:389`), the header-line block (`:552-563`, unchanged: it calls the helper directly).
- `tests/test-tmux-categorize.fish`: `cleanup` (`:82`), `fresh_server` (`:105`), `$lcat` (`:9564`), `__tcg_screen_has` (`:10148`), the x/d e2e (`:10369-10400`), the switcher stderr probe (`:10613-10625`), `__tcg_cap` (`:11522`, erased at `:11664`), the switcher resize e2e (c) (`:11635-11662`).

## New names and files

None. The glyph list gains an entry; the tests gain local variables only.

## Measured while planning

On full-tree scratch copies of `95f22eb` with this plan's exact edits (applied by script, each find-block asserted unique):

| Run | Popup suite | Categorize suite (plain) |
|---|---|---|
| RED: Steps 1–2 only | 11 FAIL, 132 ok | 3 FAIL (and the known flake, once), 1715 ok |
| GREEN: Steps 1–6 | `ALL PASS` 143 ok, both modes | `ALL PASS` 1719 ok, both modes |
| Mutations (Step 8) | measured, each listed | measured: mutations 8–11, each listed |

The other seven suites were not run while planning (no change reaches them); the gate in Step 7 runs them.

---

### Task 1: The top line, the prompt on row 2, the page step

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_landing_frame_glyphs` and its comment (~:21-23); `__tcz_landing_paint` (~:1717-1746: the `--description` and the last five lines); `__tcz_landing`'s `case pgup`/`case pgdn` (~:1958-1961) and `case kill` prompt (~:1993)
- Test: `tests/test-tmux-popup.fish` (the painter test ~:353-376; the paint block ~:385-425); `tests/test-tmux-categorize.fish` (the x/d e2e ~:10378-10389; the switcher resize e2e (c) ~:11653-11662, and a new e2e (d) right after it)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `__tcz_landing_frame_glyphs` = `▔ ▕ ▕ ─` (header line, junction, divider, top line).
- Produces: `__tcz_landing_paint` (signature unchanged) emits row 1 the top line (`$__tcz_landing_frame_glyphs[4]` × (cols − 1) in the mode color: 203 landing, 37 switch), row 2 the badge and legend, row 3 the header line (`__tcz_landing_header_line`), rows 4..`<rows>` the frame (`<rows>` − 3 rows).
- Produces: `x`'s y/n prompt is written on row 2; PgUp/PgDn step `max(1, rows - 4)` rows.

- [ ] **Step 1: Popup-suite tests (RED)**

In `tests/test-tmux-popup.fish`, five replacements.

1. The painter test (`# --- landing: the painter skips an unchanged frame and diffs a changed one ---`): row 1 is now the top line, the legend row 2, the header line row 3. At 80 columns the top line is 79 wide.

Replace

```fish
set -l lprows (count $__tcz_pe_prev)
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[1]"); and echo 1; or echo 0)
set -l lpline (string match -q -- "*$__tcz_landing_frame_glyphs[1]$__tcz_landing_frame_glyphs[2]$__tcz_landing_frame_glyphs[1]*" "$__tcz_pe_prev[2]"; and echo 1; or echo 0)
t "paint: 24 rows -- the legend with n new, the header line with its junction, then the frame" "24 1 1" "$lprows $lplegend $lpline"
```

with

```fish
set -l lprows (count $__tcz_pe_prev)
set -l lptw (string repeat -n 79 -- "$__tcz_landing_frame_glyphs[4]")
set -l lptvis (vis "$__tcz_pe_prev[1]")
set -l lptop (test "$lptvis" = "$lptw"; and echo 1; or echo 0)
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[2]"); and echo 1; or echo 0)
set -l lpline (string match -q -- "*$__tcz_landing_frame_glyphs[1]$__tcz_landing_frame_glyphs[2]$__tcz_landing_frame_glyphs[1]*" "$__tcz_pe_prev[3]"; and echo 1; or echo 0)
t "paint: 24 rows -- the top line, the legend with n new, the header line with its junction, then the frame" "24 1 1 1" "$lprows $lptop $lplegend $lpline"
```

2. The same test's move diff: the frame is now 21 rows (24 − 3) and starts on screen row 4.

Replace

```fish
set -l fa (__tcp_frame_bak 0 33 46 22 '' 203 -- $LPM)
set -l fb (__tcp_frame_bak 1 33 46 22 '' 203 -- $LPM)
set -l fdiff
for i in (seq (count $fb))
    test "$fa[$i]" = "$fb[$i]"; or set -a fdiff (math $i + 2)          # the frame starts on screen row 3
end
```

with

```fish
set -l fa (__tcp_frame_bak 0 33 46 21 '' 203 -- $LPM)
set -l fb (__tcp_frame_bak 1 33 46 21 '' 203 -- $LPM)
set -l fdiff
for i in (seq (count $fb))
    test "$fa[$i]" = "$fb[$i]"; or set -a fdiff (math $i + 3)          # the frame starts on screen row 4
end
```

3. And its "fewer rows than the frame" bound:

Replace

```fish
set -l lpsome (test (count $fdiff) -gt 0 -a (count $fdiff) -lt 22; and echo 1; or echo 0)
```

with

```fish
set -l lpsome (test (count $fdiff) -gt 0 -a (count $fdiff) -lt 21; and echo 1; or echo 0)
```

4. The paint block's heading:

Replace

```fish
# --- paint: the header (badge and legend, then the header line) over a mode-colored divider, every row of a 100x30 frame ---
```

with

```fish
# --- paint: the header (the top line, badge and legend, then the header line) over a mode-colored divider, every row of a 100x30 frame ---
```

5. The paint block itself, from the glyph pin through the reset line right before `functions -e __tcp_cell` (the lines from `functions -e __tcp_cell` on stay as they are). At 100 columns `__tcz_popup_layout` gives `40 59`: the divider is column 41, and the top line, legend and header line are 99 wide (40 + 1 + 58). At 50 columns there is no preview (`50 0`): the header line has no junction and both lines are 49 wide. The frame's first line at sel 0 over `BM` is the `╭── claude` rule. Row 3's column 1 tells the header line (`▔`) from a frame row (the rule's `╭`): the junction and the divider are the same glyph (`▕`), so column 41 alone cannot.

Replace

```fish
t "frame glyphs: the header line, its junction, the divider (the box-drawing fallback changes only this list)" "▔ ▕ ▕" "$__tcz_landing_frame_glyphs"
set -l g $__tcz_landing_frame_glyphs
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 30 100 0 landing '' -- $BM > /dev/null
set -l bl $__tcz_pe_prev
set -l bdiv 0
for r in $bl[3..30]
    set -l dc (__tcp_cell $r 41)
    test (string length --visible -- (string sub -l 40 -- (vis "$r"))) -eq 40; and test "$dc" = "203$g[3]"; and set bdiv (math $bdiv + 1)
end
t "paint 100x30: 30 rows; the frame on rows 3-30, its list column 40 wide with the coral divider at column 41 on all 28" "30 28" "$(count $bl) $bdiv"
t "paint: row 1 opens with a coral LANDING badge, then the legend" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;203m LANDING \e[0m')'*' $bl[1]; and echo 1; or echo 0) $(string match -q -- ' LANDING  ↑↓ move*' (vis $bl[1]); and echo 1; or echo 0)"
t "paint: no esc close on the landing" 0 (string match -q -- '*esc close*' (vis $bl[1]); and echo 1; or echo 0)
set -l bhead (__tcp_cell $bl[2] 1) (__tcp_cell $bl[2] 41)
set -l bvis (vis $bl[2])
set -l bwant (string repeat -n 40 $g[1])$g[2](string repeat -n 58 $g[1])
t "paint: row 2 is the coral header line, as wide as the legend's 99 columns, its junction over the divider" "203$g[1] 203$g[2] 1" "$bhead $(test "$bvis" = "$bwant"; and echo 1; or echo 0)"
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 2 30 100 0 switch g2 -- $BM > /dev/null
set -l sl $__tcz_pe_prev
t "paint: the switcher's row 1 opens with a teal SWITCHING badge and ends with esc close" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;37m SWITCHING \e[0m')'*' $sl[1]; and echo 1; or echo 0) $(string match -q -- ' SWITCHING  ↑↓ move*esc close*' (vis $sl[1]); and echo 1; or echo 0)"
set -l sdiv 0
for r in $sl[3..30]
    set -l dc (__tcp_cell $r 41)
    test "$dc" = "37$g[3]"; and set sdiv (math $sdiv + 1)
end
set -l sjunc (__tcp_cell $sl[2] 41)
t "paint: the switcher's header line and divider are teal (the junction, then all 28 frame rows)" "37$g[2] 28" "$sjunc $sdiv"
# The pointer is on g1 and the current session is g2: the marker follows <current>, not the pointer.
set -l slv
for r in $sl[3..30]; set -a slv (vis "$r"); end
set -l slptr (string match -- '*▐ g1*' $slv)
set -l slcur (string match -- '*[current]*' $slv)
t "paint: the switcher marks the current session (g2, off the pointer) and not the pointer row (g1)" "1 0 1 1" "$(count $slptr) $(string match -q -- '*[current]*' $slptr; and echo 1; or echo 0) $(count $slcur) $(string match -q -- '*❯ g2*[current]*' $slcur; and echo 1; or echo 0)"
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
```

with

```fish
t "frame glyphs: the header line, its junction, the divider, the top line (the box-drawing fallback changes only this list)" "▔ ▕ ▕ ─" "$__tcz_landing_frame_glyphs"
set -l g $__tcz_landing_frame_glyphs
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 30 100 0 landing '' -- $BM > /dev/null
set -l bl $__tcz_pe_prev
set -l bdiv 0
for r in $bl[4..30]
    set -l dc (__tcp_cell $r 41)
    test (string length --visible -- (string sub -l 40 -- (vis "$r"))) -eq 40; and test "$dc" = "203$g[3]"; and set bdiv (math $bdiv + 1)
end
set -l bfirst (string match -q -- '╭── claude*' (vis "$bl[4]"); and echo 1; or echo 0)
t "paint 100x30: 30 rows; the frame on rows 4-30 (the claude rule on row 4), its list column 40 wide with the coral divider at column 41 on all 27" "30 1 27" "$(count $bl) $bfirst $bdiv"
set -l btw (string repeat -n 99 -- "$g[4]")
set -l btop (__tcp_cell $bl[1] 1) (__tcp_cell $bl[1] 41) (__tcp_cell $bl[1] 99)
set -l btvis (vis "$bl[1]")
t "paint: row 1 is the coral top line, as wide as the legend's 99 columns, with no junction over the divider" "203$g[4] 203$g[4] 203$g[4] 1" "$btop $(test "$btvis" = "$btw"; and echo 1; or echo 0)"
t "paint: row 2 opens with a coral LANDING badge, then the legend" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;203m LANDING \e[0m')'*' $bl[2]; and echo 1; or echo 0) $(string match -q -- ' LANDING  ↑↓ move*' (vis $bl[2]); and echo 1; or echo 0)"
t "paint: no esc close on the landing" 0 (string match -q -- '*esc close*' (vis $bl[2]); and echo 1; or echo 0)
set -l bhead (__tcp_cell $bl[3] 1) (__tcp_cell $bl[3] 41)
set -l bvis (vis $bl[3])
set -l bwant (string repeat -n 40 $g[1])$g[2](string repeat -n 58 $g[1])
t "paint: row 3 is the coral header line, as wide as the legend's 99 columns, its junction over the divider" "203$g[1] 203$g[2] 1" "$bhead $(test "$bvis" = "$bwant"; and echo 1; or echo 0)"
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 2 30 100 0 switch g2 -- $BM > /dev/null
set -l sl $__tcz_pe_prev
set -l stop (__tcp_cell $sl[1] 1) (__tcp_cell $sl[1] 99)
set -l stvis (vis "$sl[1]")
t "paint: the switcher's row 1 is the teal top line, 99 columns" "37$g[4] 37$g[4] 1" "$stop $(test "$stvis" = "$btw"; and echo 1; or echo 0)"
t "paint: the switcher's row 2 opens with a teal SWITCHING badge and ends with esc close" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;37m SWITCHING \e[0m')'*' $sl[2]; and echo 1; or echo 0) $(string match -q -- ' SWITCHING  ↑↓ move*esc close*' (vis $sl[2]); and echo 1; or echo 0)"
set -l sdiv 0
for r in $sl[4..30]
    set -l dc (__tcp_cell $r 41)
    test "$dc" = "37$g[3]"; and set sdiv (math $sdiv + 1)
end
set -l sjunc (__tcp_cell $sl[3] 1) (__tcp_cell $sl[3] 41)
t "paint: the switcher's header line and divider are teal (row 3's line and junction, then all 27 frame rows)" "37$g[1] 37$g[2] 27" "$sjunc $sdiv"
# The pointer is on g1 and the current session is g2: the marker follows <current>, not the pointer.
set -l slv
for r in $sl[4..30]; set -a slv (vis "$r"); end
set -l slptr (string match -- '*▐ g1*' $slv)
set -l slcur (string match -- '*[current]*' $slv)
t "paint: the switcher marks the current session (g2, off the pointer) and not the pointer row (g1)" "1 0 1 1" "$(count $slptr) $(string match -q -- '*[current]*' $slptr; and echo 1; or echo 0) $(count $slcur) $(string match -q -- '*❯ g2*[current]*' $slcur; and echo 1; or echo 0)"
# Under 60 columns there is no preview: the same plain top line, and a header line with no junction.
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 30 50 0 landing '' -- $BM > /dev/null
set -l nl $__tcz_pe_prev
set -l ntw (string repeat -n 49 -- "$g[4]")
set -l nhw (string repeat -n 49 -- "$g[1]")
set -l ntvis (vis "$nl[1]")
set -l nhvis (vis "$nl[3]")
t "paint 50x30 (no preview): 30 rows; row 1 the plain coral top line, row 3 the plain header line, 49 columns each" "30 203$g[4] 1 1" "$(count $nl) $(__tcp_cell $nl[1] 1) $(test "$ntvis" = "$ntw"; and echo 1; or echo 0) $(test "$nhvis" = "$nhw"; and echo 1; or echo 0)"
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
```

- [ ] **Step 2: Categorize-suite tests (RED)**

In `tests/test-tmux-categorize.fish`, three replacements.

1. The x/d e2e (`# x asks first (n keeps, y kills); d detaches the tab and removes the landing session.`): the prompt is read on row 2

Replace

```fish
set -l la3top (command tmux -L $sock capture-pane -p -t "=$la3:")[1]
```

with

```fish
set -l la3top (command tmux -L $sock capture-pane -p -t "=$la3:")[2]
```

2. … and the header comes back on row 2 after `n`:

Replace

```fish
# After n the badge and legend repaint over the prompt on row 1.
set -l la3back 0
for i in (seq 30)
    set -l la3row1 (command tmux -L $sock capture-pane -p -t "=$la3:")[1]
    string match -q -- ' LANDING *' "$la3row1"; and begin; set la3back 1; break; end
    sleep 0.1
end
t "app: x asks before killing, on row 1 where the legend was, n keeps the session, and the header comes back after n" "1 1 1 1" "$la3ask $(string match -q -- '  kill 0 ?  (y/n)*' "$la3top"; and echo 1; or echo 0) $la3kept $la3back"
```

with

```fish
# After n the badge and legend repaint over the prompt on row 2.
set -l la3back 0
for i in (seq 30)
    set -l la3row2 (command tmux -L $sock capture-pane -p -t "=$la3:")[2]
    string match -q -- ' LANDING *' "$la3row2"; and begin; set la3back 1; break; end
    sleep 0.1
end
t "app: x asks before killing, on row 2 where the legend was, n keeps the session, and the header comes back after n" "1 1 1 1" "$la3ask $(string match -q -- '  kill 0 ?  (y/n)*' "$la3top"; and echo 1; or echo 0) $la3kept $la3back"
```

3. The switcher resize e2e (c) moves down one row, and a new e2e (d) after it pins the page step. In (c) at 80 columns the list is 33 wide, so the junction and divider are column 34 on rows 3–30 (28 rows) and the top line is 79 `─` (capture-pane drops the blank last column). In (d) the pane is 10 rows: the frame is 7, a page is 6. Its sessions run `sh` and the switcher runs `fish`, both shells, so all thirteen are `general` with no attach time, and the overview's sort falls back to the whole line: `p10`…`p21`, then `sw` (index 12, where the switcher's pointer opens, on `[current]`). PgUp, PgUp, PgDn visit indexes 6, 0, 6 (`p16 p10 p16`); today's step (7) visits 5, 0, 7 (`p15 p10 p17`). Each key is read separately so that fixing only one arm still fails: PgUp alone shows in the first read, PgDn alone in the last.

Replace

```fish
for r in $sws[2..30]
    set -l c34 (string sub -s 34 -l 1 -- $r)
    contains -- "$c34" $__tcz_landing_frame_glyphs[2..3]; and set swdiv (math $swdiv + 1)
    string match -q '*↑↓*' -- (string sub -l 33 -- $r); and set swinlist (math $swinlist + 1)
end
set -l swhead (string match -qr '^ SWITCHING  ↑↓ move ' -- "$sws[1]"; and echo 1; or echo 0)
set -l swtop (string match -qr '^╭── ' -- "$sws[3]"; and echo 1; or echo 0)
t "switcher: shrunk to 80x30, one step draws at the new size (the legend on row 1, not in the list on rows 2-30; the list's top rule on row 3; the junction and the divider at column 34 on rows 2-30; the step moved sw to zz)" "1 1 0 29 sw>zz" "$swhead $swtop $swinlist $swdiv $sw0>$swsel"
command tmux -L $sock send-keys -t $sww[2] Escape
cleanup
```

with

```fish
for r in $sws[3..30]
    set -l c34 (string sub -s 34 -l 1 -- $r)
    contains -- "$c34" $__tcz_landing_frame_glyphs[2..3]; and set swdiv (math $swdiv + 1)
    string match -q '*↑↓*' -- (string sub -l 33 -- $r); and set swinlist (math $swinlist + 1)
end
set -l swline (string repeat -n 79 -- "$__tcz_landing_frame_glyphs[4]")
set -l swline (test "$sws[1]" = "$swline"; and echo 1; or echo 0)
set -l swhead (string match -qr '^ SWITCHING  ↑↓ move ' -- "$sws[2]"; and echo 1; or echo 0)
set -l swtop (string match -qr '^╭── ' -- "$sws[4]"; and echo 1; or echo 0)
t "switcher: shrunk to 80x30, one step draws at the new size (the top line on row 1; the legend on row 2, not in the list on rows 3-30; the list's top rule on row 4; the junction and the divider at column 34 on rows 3-30; the step moved sw to zz)" "1 1 1 0 28 sw>zz" "$swline $swhead $swtop $swinlist $swdiv $sw0>$swsel"
command tmux -L $sock send-keys -t $sww[2] Escape
cleanup

# (d) A page key steps one frame height less one row: in a 10-row pane the frame is 7 rows, so a page is 6.
# Twelve shell sessions p10-p21 and the switcher's own sw, none attached: general lists them by name, sw last.
fresh_server
for i in (seq 10 21)
    command tmux -L $sock new-session -d -s p$i -c /tmp sh
end
command tmux -L $sock kill-session -t =0
set -l pgw (command tmux -L $sock new-session -d -s sw -x 80 -y 10 -c /tmp -P -F '#{window_id} #{pane_id}' fish --no-config $lcat landing switch '' | string split ' ')
__tcg_screen_has $pgw[2] '*SWITCHING*' 50
set -l pgseen (__tcg_cap $pgw[2] | string match -rg '^▐ (\S+)')
for k in PageUp PageUp PageDown
    set -l was $pgseen[-1]
    command tmux -L $sock send-keys -t $pgw[2] $k
    set -l now $was
    for i in (seq 30)
        set now (__tcg_cap $pgw[2] | string match -rg '^▐ (\S+)')
        test -n "$now"; and test "$now" != "$was"; and break
        sleep 0.1
    end
    set -a pgseen "$now"
end
t "switcher: a page key steps one frame height less one row (a 10-row pane: a 7-row frame, so 6 rows; from sw: PgUp, PgUp, PgDn)" "sw p16 p10 p16" "$pgseen"
command tmux -L $sock send-keys -t $pgw[2] Escape
cleanup
```

The switcher stderr probe (`# - fish's own errors never reach the switcher's popup: …`) needs no edit: its anchor `'$cols $mc) $frame'` still ends the emit line, whose new first argument is `"$top"`. Its `swqinj` = 1 check is the guard that the anchor still matches exactly one line.

- [ ] **Step 3: Run both suites; confirm the RED set**

Popup suite (measured: 11 FAIL, 132 ok):
- `paint: 24 rows -- the top line, …` (got `24 0 0 0`)
- `paint: a move between two project rows emits only the changed rows` (got `1 0 0`: the old code emits the frame from row 3)
- `frame glyphs: …, the top line (…)` (got `▔ ▕ ▕`)
- `paint 100x30: 30 rows; the frame on rows 4-30 …` (got `30 0 27`)
- `paint: row 1 is the coral top line, …`
- `paint: row 2 opens with a coral LANDING badge, then the legend` (got `0 0`)
- `paint: row 3 is the coral header line, …` (got `208╭ 203▕ 0`)
- `paint: the switcher's row 1 is the teal top line, 99 columns`
- `paint: the switcher's row 2 opens with a teal SWITCHING badge …` (got `0 0`)
- `paint: the switcher's header line and divider are teal (row 3's …)` (got `208╭ 37▕ 27`)
- `paint 50x30 (no preview): 30 rows; row 1 the plain coral top line, …`

Named non-regression guards, passing before and after: `paint: an unchanged frame is neither rebuilt nor emitted`, `paint: no esc close on the landing` (an absence check), `paint: the switcher marks the current session (g2, …)` (content over the frame rows), the three `header line:` assertions (the helper is unchanged).

Categorize suite (measured): 3 FAIL, 1715 ok:
- `app: x asks before killing, on row 2 where the legend was, …` (got `1 0 1 0`: the prompt is on row 1, and row 2 never shows ` LANDING `)
- `switcher: shrunk to 80x30, one step draws at the new size (the top line on row 1; …)` (got `0 0 0 0 28 sw>zz`)
- `switcher: a page key steps one frame height less one row (…)` (got `sw p15 p10 p17`; measured as mutation 9, which restores today's page code: the RED run itself had the first, PgUp-only draft of this test, which got `sw>p15`)

The RED run also failed the known flake (`switch: x on the current session closes it the landing way …`, on its last field); it passed in the seven later runs.

Named non-regression guard: `switch: a fish error in its loop never reaches the screen (…)` (`swqinj` 1 on the unchanged anchor).

- [ ] **Step 4: The glyph list**

In `functions/tmux-categorize.fish`:

Replace

```fish
# The landing frame's glyphs, drawn in the mode color: the header line, its junction over the divider, the divider.
# Eighth blocks; for a terminal that lacks them, the box-drawing set ─ ┬ │ draws the same frame.
set -g __tcz_landing_frame_glyphs ▔ ▕ ▕
```

with

```fish
# The landing frame's glyphs, drawn in the mode color: the header line, its junction over the divider, the divider,
# the top line. The first three are eighth blocks; for a terminal that lacks them, ─ ┬ │ draw the same frame.
set -g __tcz_landing_frame_glyphs ▔ ▕ ▕ ─
```

- [ ] **Step 5: The painter**

In the `function __tcz_landing_paint …` line, the description's middle phrase (the line stays one line; the whole description goes from 414 to 407 characters):

Replace

```fish
paint the badge and key legend (SWITCHING and esc close when <mode> is switch, else LANDING), the header line and the frame, framed in the mode color, through the diff emitter.
```

with

```fish
paint the top line, badge and key legend (SWITCHING and esc close when <mode> is switch, else LANDING), header line and frame in the mode color through the diff emitter.
```

and its last five lines:

Replace

```fish
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) "$current" $mc -- $model)
    set -g __tcz_pf_keep 0
    set -l legend (printf '\e[1;7;38;5;%sm %s \e[0m' $mc $badge)(__tcz_legend_row 10 $keys)
    __tcz_popup_emit (__tcz_popup_truncate "$legend" (math $cols - 1)) (__tcz_landing_header_line $lay[1] $lay[2] $cols $mc) $frame
```

with

```fish
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 3) "$current" $mc -- $model)
    set -g __tcz_pf_keep 0
    # Three header rows over the frame: the top line, the badge and legend, the header line.
    set -l top (printf '\e[38;5;%sm%s\e[0m' $mc (string repeat -n (math $cols - 1) $__tcz_landing_frame_glyphs[4]))
    set -l legend (printf '\e[1;7;38;5;%sm %s \e[0m' $mc $badge)(__tcz_legend_row 10 $keys)
    __tcz_popup_emit "$top" (__tcz_popup_truncate "$legend" (math $cols - 1)) (__tcz_landing_header_line $lay[1] $lay[2] $cols $mc) $frame
```

(`$__tcz_landing_frame_glyphs[4]` unquoted is safe here: the list is defined at the top of the same file. At `cols` 1 the repeat is zero-width and the row is an empty colored string, which the emitter erases to end of line.)

- [ ] **Step 6: The page step and the prompt row in `__tcz_landing`**

Replace

```fish
                set sel (math "max(0, $sel - max(1, $rows - 3))")
            case pgdn
                test $n -gt 0; and set sel (math "min($n - 1, $sel + max(1, $rows - 3))")
```

with

```fish
                # A page is one frame height (rows - 3) less one row.
                set sel (math "max(0, $sel - max(1, $rows - 4))")
            case pgdn
                test $n -gt 0; and set sel (math "min($n - 1, $sel + max(1, $rows - 4))")
```

Replace

```fish
                printf '\e[1;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' "$row[1]"
```

with

```fish
                printf '\e[2;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' "$row[1]"
```

- [ ] **Step 7: Run both suites, then the full gate**

Popup suite, both modes: `ALL PASS`, 143 `ok` (measured). Categorize suite, both modes: `ALL PASS` (measured: 1719 `ok` in both modes). Then all 9 suites, both modes: 9/9 `ALL PASS`, install 962/961, generic 3, status 4. Sweep `/tmp/tmux-1000/` afterwards.

- [ ] **Step 8: Mutation check (report the results)**

On a full-tree scratch copy of the Step 6 tree, one at a time; each must fail exactly the assertions listed (measured while planning).

Popup suite:
1. No top line (`__tcz_popup_emit` without `"$top"`; the frame stays `rows - 3`) → 10 FAILs: every popup FAIL in Step 3 except `frame glyphs: …`.
2. The frame not shrunk (`(math $rows - 2)`) → `paint: 24 rows …` (25 rows), `paint 100x30: …`, `paint 50x30 …` (31 rows).
3. The top line always coral (`203` for `$mc` in its printf) → only `paint: the switcher's row 1 is the teal top line, 99 columns`.
4. The top line full width (`$cols` for `(math $cols - 1)`) → `paint: 24 rows …`, `paint: row 1 is the coral top line, …`, `paint: the switcher's row 1 …`, `paint 50x30 …`.
5. The glyph spelled inline (`─` in the painter, the list left at `▔ ▕ ▕`) → `frame glyphs: …`, `paint: 24 rows …`, `paint: row 1 …`, `paint: the switcher's row 1 …`, `paint 50x30 …` (the tests read the glyph from the list).
6. The top line drawn with the header line's glyph (`[1]` for `[4]`) → `paint: 24 rows …`, `paint: row 1 …`, `paint: the switcher's row 1 …`, `paint 50x30 …`.
7. The top line under the legend (the emitter's first two arguments swapped) → `paint: 24 rows …`, `paint: row 1 …`, `paint: row 2 …`, `paint: the switcher's row 1 …`, `paint: the switcher's row 2 …`, `paint 50x30 …`.

Categorize suite:
8. The prompt back on row 1 (`\e[1;1H`) → only `app: x asks before killing, on row 2 where the legend was, …` (got `1 0 1 1`: row 2 keeps the legend, so only the prompt read catches it).
9. Both page arms back at `max(1, $rows - 3)` (today's page code) → only `switcher: a page key steps one frame height less one row (…)` (got `sw p15 p10 p17`).
10. Only PgUp back at `rows - 3` → the same assertion (got `sw p15 p10 p16`).
11. Only PgDn back at `rows - 3` → the same assertion (got `sw p16 p10 p17`).

Mutations 1, 2, 4 and 7 also move rows the categorize suite reads (the resize e2e (c), the x/d e2e); that was not run while planning.

- [ ] **Step 9: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): a mode-colored ─ top line above the badge -- the frame gives up a row, the x prompt follows the legend to row 2, a page is rows - 4"
```

---

### Task 2: Docs

**Files:**
- Modify: `README.md` (~:54, ~:58), `CLAUDE.md` ("Landing session" v3.1 bullet, "Current state"), `docs/superpowers/specs/2026-09-26-landing-session-design.md` (Status line)

**Interfaces:** none (no code paths change).

- [ ] **Step 1: README (one paragraph per line, as the file keeps it)**

In the landing paragraph (~:54), its last sentence:

```
A coral `LANDING` badge opens the key legend at the top, and a thin line in the same color runs under the legend and down between the list and the preview.
```

→

```
A coral line runs across the top, a coral `LANDING` badge opens the key legend under it, and a thin line in the same color runs under the legend and down between the list and the preview.
```

In the switcher paragraph (~:58): `` with a teal `SWITCHING` badge, line and divider in place of the coral `LANDING` ones. `` → `` with a teal `SWITCHING` badge, lines and divider in place of the coral `LANDING` ones. ``

- [ ] **Step 2: CLAUDE.md (budget 40,000 bytes; it is at 39,953)**

Run `wc -c CLAUDE.md` before and after and report both. Measured on a copy, the two edits below take it to 39,986 (39,972 once the merge sha replaces the branch name). If your result is over 40,000, prune before committing (candidates: sentences that restate a memory file, keeping its `[[pointer]]`); never remove a standing decision or a live trap.

1. In the "Landing session" `**v3.1**` bullet, replace

```
  `__tcz_pf_rrow/_rline/_rfirst`. Paint: legend, `__tcz_landing_header_line`, frame (the last two take the mode
  color, 203/37); glyphs: `__tcz_landing_frame_glyphs`.
```

with

```
  `__tcz_pf_rrow/_rline/_rfirst`. Paint: top line, legend, `__tcz_landing_header_line`, frame, in the mode
  color (203/37); glyphs: `__tcz_landing_frame_glyphs`.
```

2. Replace the "Current state" heading and its first paragraph

```
## Current state — 2026-10-08

**Chooser v3.1 built (merged `9fd64a5`), awaiting `fisher update` on both
machines;** then the workspace-TUI sidebar. Mockups `06`–`18`; generators in `artifacts/mockgen/chooser-v3/`.
```

with (today's date in the heading; your branch's name if it is not `feat/landing-top-line`)

```
## Current state — 2026-11-05

**Chooser v3.1 (merged `9fd64a5`) and its top line (branch `feat/landing-top-line`) built, awaiting `fisher
update` on both machines;** then the workspace-TUI sidebar. Mockups `06`–`19` in `artifacts/mockgen/chooser-v3/`.
```

- [ ] **Step 3: The spec's Status line**

`**Header top line** (approved 2026-11-05 from mockup `19`, variant B; not built)` → `**Header top line** (approved 2026-11-05 from mockup `19`, variant B; built on branch `feat/landing-top-line`, awaiting merge and `fisher update`)` (the merge step fills in the sha). The rest of the spec already describes the built state; change nothing else.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-09-26-landing-session-design.md
git commit -m "docs: the landing header top line in README, CLAUDE.md and the landing spec"
```

---

### Task 3: Fit review

- [ ] **Step 1:** Invoke the `fit-review` skill on the branch with base = the commit that adds this plan (`main` at the commit whose subject is `docs(plan): landing header top line -- a mode-colored ─ row above the badge`; `git log -1 --format=%h -- docs/superpowers/plans/2026-11-05-landing-header-top-line.md` on `main`). The style guide's vocabulary line still reads "landing = per-tab `_landing-N` chooser …: row 1 badge+legend, row 2 header line, then the frame": it is stale after Task 1 (row 1 the top line, row 2 badge+legend, row 3 header line), and the fit review updates it. A fit pass that refactors is a fix wave: a scoped re-review of what it changed and the full gate (9 suites, both modes) before merging.

### After the plan (controller)

- Merge `feat/landing-top-line` into `main` locally, push, fill the merge sha into the spec Status (`built (merged to `main` at `<sha>`), awaiting `fisher update``) and CLAUDE.md "Current state" (`**Chooser v3.1 (merged `9fd64a5`) and its top line (merged `<sha>`) built, awaiting `fisher update` on both machines;**`), delete this plan file (`git rm`), commit and push.
- Republish the spec to the vault (`vault-publish` skill): `vault-publish --type project --project "$(cat .vault-project)" docs/superpowers/specs/2026-09-26-landing-session-design.md --title "Landing Session - Design"`, reflow the vault copy to one line per paragraph (if the publish exits 3 because the last vault copy was reflowed, diff the vault copy against the reflowed previous source; force only when that is the whole difference), and give the `obsidian://open?vault=Vault&file=Notes%2FProjects%2FTmux-lives%2FLanding%20Session%20-%20Design` link.
- Ask the user to `fisher update` on both machines and smoke-test: a new ShellFish tab (a coral `─` line above the `LANDING` badge, the legend between it and the `▔` line), `Alt+S` inside a session (the same in teal), `x` on a live row (the prompt on row 2, the top line still above it), and PgDn/PgUp on a long list.

## Spec coverage

| Spec requirement | Where |
|---|---|
| Row 1: the top line, `─` (U+2500) in the mode color across the legend's width (cols − 1), no junction | Task 1 `paint: row 1 is the coral top line, …` (columns 1, 41, 99 and the whole row), `paint: 24 rows …`; mutations 4, 5, 6 |
| The top line teal in switch mode | Task 1 `paint: the switcher's row 1 is the teal top line, 99 columns`, the resize e2e (c); mutation 3 |
| Row 2: badge and legend; row 3: the `▔` header line with its `▕` junction; the divider from row 3 down; list and preview from row 4 | Task 1 `paint: row 2 …`, `paint: row 3 …`, `paint 100x30 …` (the rule on row 4, 27 divider rows), the switcher's row 2 and row 3 assertions, the resize e2e (c); mutation 7 |
| The frame gives up one row (`rows − 3`) | Task 1 `paint 100x30: 30 rows …`, `paint: 24 rows …`, `paint 50x30 …` (30 rows each); mutations 1, 2 |
| The narrow layout (< 60 columns) gets the same plain top line | Task 1 `paint 50x30 (no preview) …` |
| `─` is the fourth entry of `__tcz_landing_frame_glyphs`; the one pinning test pins four glyphs | Task 1 `frame glyphs: …`; mutation 5 |
| `x`'s y/n prompt on row 2, the legend's row | Task 1 `app: x asks before killing, on row 2 …`; mutation 8 |
| Page up/down: one frame height less one row | Task 1 `switcher: a page key steps one frame height less one row …`; mutations 9, 10, 11 |
| README, CLAUDE.md and the spec's Status describe the built state | Task 2 |
