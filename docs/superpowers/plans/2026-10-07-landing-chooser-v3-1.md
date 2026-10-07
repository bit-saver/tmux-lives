# Landing Chooser v3.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the chooser's header (badge and key legend, then a thin line) to the top, draw the badge, header line and list/preview divider in the mode color (coral 203 landing, teal 37 switching), list live Claude sessions directly under the `claude` rule (most recently attached first, in no box), give every section and box a right rail, and make the older row read `▸ older (N)`.

**Architecture:** The model (`__tcz_landing_model`) keeps its five-field rows; a live claude session's category becomes plain `claude` and those rows come first, in the overview's order. The row drawer (`__tcz_popup_list_row`) gives every row the same geometry, a right rail two columns in whose color says where the row lives; `__tcz_popup_list_lines` drops the rail row after directory boxes (only the older box keeps one) and ends each section rule in `╮`. `__tcz_landing_paint` emits the legend on row 1, the header line (`__tcz_landing_border`, reworked) on row 2 and the frame below; the mode color reaches the header line and the frame's divider as an explicit argument, and the three frame glyphs live in one top-of-file list so the spec's box-drawing fallback is a one-line change.

**Tech Stack:** fish 4 (`fish --no-config` scripts), tmux 3.3a (rocket) / 3.7b (macwork), the repo's own fish test suites.

**Spec:** `docs/superpowers/specs/2026-09-26-landing-session-design.md`. Read the Status line's v3.1 sentence, "The landing app" → "Layout (v3.1)" and "Drawing (v3.1)", "## Switch mode (v3)" (the mode-color bullet), the Testing bullet "Layout (v3.1)", and the first Open item (the glyph check). The approved mockups' generator is `artifacts/mockgen/chooser-v3/gen18.py` (with `gen16.py`, `gen14.py`, `gen.py`; rocket only, gitignored): `gen16.list_lines(..., rail=2, older=OLDER["O2"], grail=True)` over `live_first(MODEL)` is the list geometry this plan implements. Where `gen18.py` still draws the `🭽`/`▏` junction (C2), the spec's glyph test E wins: `▕` (U+2595) for the junction and the divider (`artifacts/glyphtest.fish`, the last two blocks).

## Global Constraints

- ⛔ **LIVE-SERVER RULE.** Every agent shell runs inside the user's LIVE tmux: `$TMUX` names his real server and `TMUX` beats `TMUX_TMPDIR`. Every tmux command you type names its socket (`command tmux -L <name>` / `-S <path>`) or runs inside a suite that pins one; never a bare `tmux`, never a bare `kill-server`. A review agent killed the live server this way on 2026-09-29 (`docs/2026-09-29-review-agent-killed-live-tmux-server.md`).
- ⛔ **Never deploy.** No `fisher install/update`, no `cp` into `~/.config/fish/`, no edits to `~/.tmux.conf`, no `set -U`. Commit to the branch; the user deploys with his own `fisher update`.
- Any ad-hoc run of the landing app or the theme engine outside a suite exports `tmux_lives_render_cache_dir`, `tmux_lives_claude_projects_dir` and `tmux_lives_project_cache` to temp paths first.
- **Gate:** each suite is its own FOREGROUND Bash call with `timeout: 600000`, plain then `--no-config`. Never run two suites in parallel.
  - `fish tests/test-<name>.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('` (and the same with `fish --no-config`)
  - the popup suite only as `env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish [--no-config] tests/test-tmux-popup.fish`. `artifacts/` is gitignored: in a fresh worktree create the stub first: `mkdir -p artifacts/notmux && printf '#!/bin/sh\nexit 1\n' > artifacts/notmux/tmux && chmod +x artifacts/notmux/tmux`
  - never wrap a suite in shell `timeout`; never judge by `tail -1`
  - if a Bash call reports it was backgrounded, do not wait for it: abandon it and re-run in the foreground with the explicit timeout
- Baseline at `main` `4e66a6b`: 9/9 `ALL PASS` in both modes; `test-tmux-install.fish` 962 plain / 961 `--no-config` (the 1-count delta is BY DESIGN — do not "fix" it), `test-generic.fish` 3, `test-tmux-status.fish` 4. No task here touches the install suite: the pair stays 962/961; if it changes, stop and report.
- **Briefs in this repo have contained defects every build** (unsatisfiable or vacuous assertions, off-by-one geometry, a fixture whose natural order made the wrong answer coincide with the right one, a false RED claim). If the code disagrees with this plan, the code wins: say so in your report with the evidence.
- Every new or changed assertion is shown to FAIL against the pre-change code (RED), except the ones a task names as non-regression guards. Capture into a variable first: an undefined function called directly inside `t` aborts the statement silently and the suite still reports `ALL PASS`. Ask of every fixture: would a plausible wrong implementation land on the same row or value?
- Mutation checks use full-tree scratch copies (`cp -a` of the repo into the scratchpad), never `git checkout`/`git stash` on the working tree; re-take the copy immediately before each mutation.
- Code comments are brief: what a reader needs now. History, dates and measurements go in the commit message. American spelling in new comments and prose (color, gray). A `--description` states the caller's contract in under ~400 characters.
- No new files in `conf.d/` or `functions/`. Names are `__tcz_*` (categorizer); test helpers `__tcp_*` (popup suite) and `__tcg_*` (categorize suite), each erased (`functions -e`) after its last use.
- The frame glyphs are spelled once in code (`__tcz_landing_frame_glyphs`) and once in tests (the single assertion that pins the list); every other assertion reads the list. The mode colors 203 and 37 are spelled only in `__tcz_landing_paint` (and in tests).
- fish traps that return a wrong answer instead of an error (CLAUDE.md → "Traps"):
  - a zero-output command substitution collapses the whole enclosing argument: capture into a variable, use it quoted
  - `printf --` is not an option terminator
  - `string match -r` with a prefix pattern returns the matched substring
  - `"$var[...]"` in double quotes is list indexing (spell an escape via `(printf '\e[0m')` or a variable, never `"$E[0m"`)
  - never iterate `(seq (count $x))` where the count can be 0: macOS `seq 0` prints `1 0`
- No new `case` labels in `__tcz_landing` (the categorize suite extracts theme-picker arms with awk patterns keyed on exact 12-space `case …` lines).
- Run the repo's own checks only; there is no formatter or linter for fish here.

## Rulings taken for the user (recorded in the spec in Task 4)

- `x`'s y/n confirm takes the legend's place on row 1 (it overwrote the bottom legend row before); its text and orange 208 are unchanged.
- In the narrow layout (no preview column, under 60 columns) there is no divider, and row 2 is a plain line across the legend's width.
- The `claude` rule ends in `╮` even when no live session is listed: the orange corner then sits directly above the first box rule's gold `╮`.
- The frame learns the mode color as an explicit argument: `__tcz_popup_frame` and `__tcz_landing_border` take a 256-color number, and only `__tcz_landing_paint` maps the mode to coral or teal. A global would be a hidden input to a function the popup suite calls 16 times on its own, and would carry one mode's color into the next call.
- The three frame glyphs are one top-of-file list, `__tcz_landing_frame_glyphs` (header line, junction, divider), and the tests read it; the spec's box-drawing fallback (`─ ┬ │`) is that list plus the one assertion that pins it.

## What already exists

Everything this plan changes extends code that is already there (lines at `4e66a6b`; find by name, lines drift):

- `__tcz_landing_groups`, `__tcz_landing_idle_categories` — `functions/tmux-categorize.fish:18`, `:20`: the top-of-file constant lists the new glyph list sits beside.
- `__tcz_landing_group_of` — `functions/tmux-categorize.fish:80`: stays; after Task 1 only the idle projects call it (one call per refresh, `:1637`).
- `__tcz_tmux_activepath` — `functions/tmux-categorize.fish:328`: Task 1 removes the model's call (`:1590`); its other callers (`:953`, `:5104`) keep it.
- `__tcz_overview` — `functions/tmux-categorize.fish:1045`: claude rows first, most recently attached first (`sort -k2,2nr` on `session_last_attached`); the model keeps that order for live claude rows.
- `__tcz_landing_model` — `functions/tmux-categorize.fish:1546`: the rows; Task 1 changes the live claude category, the order and the older row's text.
- `__tcz_landing_paint` — `functions/tmux-categorize.fish:1717`: the frame, the border and the legend through `__tcz_popup_emit`; Task 3 reorders them and adds the mode color.
- `__tcz_landing_border` — `functions/tmux-categorize.fish:1748`: the cols-1 rule with a junction over the divider; Task 3 makes it the header line (glyphs and color as arguments of the same shape).
- `__tcz_landing` — `functions/tmux-categorize.fish:1787`: the loop; its `case kill` prompt (`:1992`) moves to row 1; its landing-off branch (`:2003`) is the code the folded carry-in's test pins.
- `__tcz_landing_ready` — `functions/tmux-categorize.fish:1324`: unchanged; called by the kill arm.
- `__tcz_popup_layout` — `functions/tmux-categorize.fish:2070`: list and preview widths; unchanged.
- `__tcz_popup_list_row` — `functions/tmux-categorize.fish:2132` and `__tcz_popup_list_lines` — `:2192`: the row drawer and the list walk (records `__tcz_pl_row/_line/_first`); Task 2 changes their geometry.
- `__tcz_legend_row` — `functions/tmux-categorize.fish:2297` and `__tcz_popup_emit` — `:2397`: unchanged. The theme picker (`__tcz_theme_picker`, `:3292`) uses only these two of the functions named here, so it is untouched.
- `__tcz_popup_list_memo` — `functions/tmux-categorize.fish:2432`: unchanged; copies the records to `__tcz_pf_rrow/_rline/_rfirst`.
- `__tcz_popup_frame` — `functions/tmux-categorize.fish:2444`: the frame; Task 3 adds the divider color argument.
- `tests/test-tmux-popup.fish`: the list block `:86–177` (`__tcp_band` `:129`), the memo-equivalence test `:257–322` (fixture `MM` `:286–291`), the painter tests `:324–366`, the badge paint test `:368–398` (fixture `BM` `:372`), the frame preview tests `:400–470`, the border tests `:521–527`.
- `tests/test-tmux-categorize.fish`: the model test `:9982–10038` (`:10014`, `:10016`), `__tcg_gm_shape` `:10041`, the v3 model block `:10100–10138`, the e2e helpers `:10141–10174` (`__tcg_screen_has`, `__tcg_client_on`, `__tcg_ready` …), the older-row e2e `:10299–10360`, the x/d e2e `:10362–10391`, the x-on-claude e2e `:10432–10448`, the switch-mode helpers `:10455–10487` (`__tcg_swroom`, `__tcg_swstart`, `__tcg_swat`, `__tcg_swgone`), the hookless switch e2e `:10535–10551`, the switch-older e2e `:10578–10594`, the switcher stderr probe `:10596–10609`, the switcher resize e2e (c) `:11618–11644`.

## New names and files

No new files (this plan document aside) and no new functions in code. New names, each because the existing code cannot hold it:

- `__tcz_landing_frame_glyphs` (top-of-file global list: header line, junction, divider): two functions draw the frame glyphs (`__tcz_landing_border`, `__tcz_popup_frame`), and the spec's fallback must change them in one place; a top-of-file constant list is this file's idiom for that (`__tcz_shells`, `__tcz_landing_groups`).
- The category value `claude` replaces `claude/<group>`: a live claude row no longer lives in a group, so the group suffix has nothing to say. Not a new concept, the overview's own category name.
- A `<color>` parameter on `__tcz_popup_frame` (after `<current>`) and on `__tcz_landing_border` (last): new parameters, not names; see the ruling on the mode color.
- `__tcp_cell` (popup-suite helper): reads one cell's glyph and its 256-color. `vis` drops colors and `__tcp_band` reads only the selection band, so neither can pin a rail's color at a column.

## Carry-ins from the v3 build

- **Folded into Task 3:** the hookless switch e2e sets the test server's `detach-on-destroy off`, so the landing-off branch's session-level `detach-on-destroy on` is exercised (as the e2e stands, a server's default is already `on`, so deleting that line would keep the suite green). Task 3 edits the same `case kill` arm (the prompt row).
- **Not folded:** `artifacts/focus.sh`'s prelude lacking `__tcg_swat` (a gitignored local tool, no commit can carry it; to run the bind e2e through it, add the switch-mode block that defines the helper to its arguments); tying the `__tcz_landing_ready` test's hook line to the real rendered fragment (that helper and its test are untouched here).

## Values derived, not measured (pre-flight these first)

The popup suite results below (RED lists, GREEN, mutations) were measured on a full-tree scratch copy with this plan's code; the categorize suite was not run while planning (it starts tmux servers). Pre-flight before dispatching:

1. Task 1's model shape `claude:cw claude:co claude:cp claude:cx projects:pi workspace:wi older:older general:rn general:gg`: it rests on each `script` attach setting `session_last_attached` (as `__tcg_swroom`'s "b is the newest session" already relies on), so the three attached sessions get three different seconds and the never-attached `cx` (last_attached 0) sorts last.
2. Task 1's RED set in the categorize suite: how far the older-row e2e cascades once its pointer loop misses the row.
3. Task 3's categorize edits: the row-1 prompt glob `'  kill 0 ?  (y/n)*'`, the resize e2e's `"1 1 0 29 sw>zz"`, the stderr probe with its `╭── claude` glob, the hookless e2e with `detach-on-destroy off`, and the mutations named in Task 3 Step 8 for them.
4. Task 4's `wc -c CLAUDE.md`: measured on a copy at 39,905 → 39,990 with this plan's text (39,961 once the merge sha replaces the branch sentence).

---

### Task 1: The model's v3.1 rows

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_landing_model` (~:1546–1653): its description line, the live-row loop (~:1577–1598), the output block (~:1644–1652)
- Test: `tests/test-tmux-categorize.fish` (~:10014, ~:10016, ~:10045, the v3 model block ~:10100–10138, the older-row e2e ~:10302–10337, ~:10432, ~:10589)

**Interfaces:**
- Produces: model rows `target\tcategory\tmark\tlast\tdisplay` whose category is one of `claude` (a live claude session), `<group>` (an idle project; unchanged), `older` (display `▸ older (N)`), `general` (every other live session, running folded in). Order: every `claude` row in the overview's order (most recently attached first), then for each group in `$__tcz_landing_groups` order its idle rows (newest first), then the older row, then the `general` rows (overview order). Live rows keep fields 3–5 exactly as before.
- Until Task 2 lands, the v3 drawer reads `claude` as a box name and draws the live rows in a gold box headed `claude`; expected, and gone after Task 2.

- [ ] **Step 1: Update the model assertions and the e2e fallout (RED)**

In `tests/test-tmux-categorize.fish`:

1. The model test (`# --- landing: the model (real server, real pty clients, fixture projects) ---`, ~:10014 and ~:10016): `"lmc claude/other 1"` → `"lmc claude 1"`, and `"lmr claude/other 0"` → `"lmr claude 0"`.

2. `__tcg_gm_shape` (~:10045): `case general 'claude/*'` → `case general claude`.

3. Replace the whole block from `# --- chooser v3: a live claude session sits in its project's group box, before the group's idle` through the `cleanup` line right before `# --- landing: the running app, driven through a real pty client ---` (~:10100–10138) with:

```fish
# --- chooser v3.1: the live claude sessions come first, most recently attached first, in no box; then each
# group's idle projects; the older row ends the claude section; running folds into general, which comes last ---
# - three clients attach to cp, co and cw, 1.2 s apart (last_attached has 1 s resolution); cx is never attached
# - most recently attached first reads cw co cp cx; by name it would read co cp cw cx, by group (v3) cp cw co cx
# - HOME is redirected around the model call, so cp and cw sit below the fixture's group roots: a model that
#   still grouped live sessions would order them by group
# - the stale discovery row makes the older row exist, so its place (after the projects, before general) is pinned
set -l m3home /tmp/tcz-m3h-$fish_pid
set -l m3home_save $HOME
mkdir -p $m3home/projects/cp $m3home/workspace/ww $m3home/projects/pi $m3home/workspace/wi
fresh_server
command tmux -L $sock new-session -d -s cp -c $m3home/projects/cp "$shimdir/claude --name cp"
command tmux -L $sock new-session -d -s cw -c $m3home/workspace/ww "$shimdir/claude --name cw"
command tmux -L $sock new-session -d -s cx -c /tmp "$shimdir/claude --name cx"
command tmux -L $sock new-session -d -s co -c /tmp "$shimdir/claude --name co"
command tmux -L $sock new-session -d -s rn -c /tmp 'sleep 600'
command tmux -L $sock new-session -d -s gg -c /tmp
command tmux -L $sock kill-session -t =0
for s in cp co cw
    sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =$s" /dev/null >/dev/null 2>&1 &
    for i in (seq 25)
        set -l m3cl (command tmux -L $sock list-clients -t "=$s" -F '#{client_name}' 2>/dev/null)
        test -n "$m3cl"; and break
        sleep 0.2
    end
    sleep 1.2
end
set -l m3pids (jobs -p)
set -l m3now (date +%s)
set -l m3disc (printf '%s\t%s' $m3home/projects/pi (math $m3now - 60)) \
    (printf '%s\t%s' $m3home/workspace/wi (math $m3now - 120)) \
    (printf '%s\t%s' /tmp/tcz-m3-stale (math $m3now - 30 \* 86400))
set -gx HOME $m3home
set -l m3 (__tcz_landing_model x -- $m3disc)
set -gx HOME $m3home_save
set -l m3shape
for r in $m3
    set -l f (string split \t -- $r)
    set -a m3shape "$f[2]:"(path basename -- $f[1])
end
t "model v3.1: the live claude sessions first, most recently attached first; then each group's idle projects; then the older row; then general, running folded in, last" "claude:cw claude:co claude:cp claude:cx projects:pi workspace:wi older:older general:rn general:gg" "$m3shape"
set -l m3old (__tcz_landing_model x -- (printf '%s\t%s' /tmp/tcz-m3-stale (math $m3now - 30 \* 86400)))
t "model v3.1: the older row reads ▸ older (N)" 1 (string match -q -- 'older'\t'older'\t'0'\t'1'\t'▸ older (1)' $m3old; and echo 1; or echo 0)
for p in $m3pids; kill $p 2>/dev/null; end
rm -rf $m3home
cleanup
```

   The busy check keeps `pi` and `wi` listed (no claude runs in either), and `/tmp/tcz-m3-stale` is neither generic nor busy; if either stops holding, pick another fixture path and say so.

4. The older-row e2e (`# The older row: Enter reveals the hidden projects in their groups, …`, ~:10299). Its comment's list order changes; replace these five comment lines:

```fish
# HOME is redirected (exported before the server starts, so the landing pane inherits it). The list goes from
# [pv (projects), older (live), fresh (other), ...older (1)] to [pv, ph (workspace, the one revealed), older,
# fresh]: the revealed row sits above the older row's old slot (a pointer that did not move cannot pass) and
# below the first project row (a pointer sent to the first project row, not the first row the reveal added,
# cannot pass).
```

   with:

```fish
# HOME is redirected (exported before the server starts, so the landing pane inherits it). The list goes from
# [older (live), pv (projects), fresh (other), ▸ older (1)] to [older, pv, ph (workspace, the one revealed),
# fresh]: the revealed row sits above the older row's old slot (a pointer that did not move cannot pass) and
# below the first project row (a pointer sent to the first project row, not the first row the reveal added,
# cannot pass).
```

   and in the same test both `'*▐ ...older (1)*'` globs (~:10332, ~:10337) become `'*▐ ▸ older (1)*'`. (Index check, 0-based, with `zz` already added when Enter is pressed: `[older, zz, pv, fresh, ▸ older (1)]` → `[older, zz, pv, ph, fresh]`; `ph` at 3 is neither the older row's old slot 4 nor the first project row 2, so both of the comment's discriminations still hold. The two never-attached claude sessions tie on last_attached 0 and sort by name, `older` before `zz`.)

5. ~:10432: `# x on a live claude row asks first, like any live row (its category is claude/<group> now). The claude` → `# x on a live claude row asks first, like any live row (its category is claude). The claude`.

6. ~:10589: `set -l swoold (string match -q -- '*...older (1)*' $swoscr; and echo 1; or echo 0)` → `set -l swoold (string match -q -- '*▸ older (1)*' $swoscr; and echo 1; or echo 0)`.

7. Check: `grep -n 'claude/' tests/test-tmux-categorize.fish | grep -v '\.claude/'` lists only the four unrelated lines (~:126 and ~:2176, claude's install paths; ~:2531 and ~:2547, function and field names), and `grep -n '\.\.\.older' tests/test-tmux-categorize.fish` lists nothing.

- [ ] **Step 2: Run the categorize suite; confirm the RED set**

Run (foreground, `timeout: 600000`): `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`

Expected FAIL (fix-discriminators): `model: a live row with a client from another device -> mark 1`, `model: a live row with no client -> mark 0`, both `model v3.1:` assertions, `app: after a refresh adds a row above it, the pointer stays on the older row …` (the pointer loop never finds `▐ ▸ older (1)`), and `switch: a session named older is current -- the older row is listed …`. The older-row e2e's later assertions (`app: Enter on the older row reveals it …`, `app: x on the older row or on a project row asks nothing …`) may fail with it, since its pointer is not on the older row. Nothing outside those four blocks (the model test, the v3.1 model block, the older-row e2e, the switch-older e2e) fails; `app: a project 21+ days old hides behind an older (1) row …` passes before and after (its glob `*older (1)*` matches both texts: a non-regression guard).

- [ ] **Step 3: The model's live rows**

In `__tcz_landing_model`, replace the `function __tcz_landing_model …` line with:

```fish
function __tcz_landing_model --argument-names self --description '__tcz_landing_model <self> [--all] [-- <discovery rows>]: rows "target\tcategory\tmark\tlast\tdisplay" for the chooser of <self> (mark 2 = a client of my device is on it, 1 = some client). Live claude sessions (claude, most recently attached first); each group'"'"'s idle projects (<group>); "▸ older (N)" (--all lists them); the other live sessions (general). "--" passes discovery rows in.'
```

Replace

```fish
    # Live rows: a claude session goes to its project's group, everything else to general.
```

with

```fish
    # Live rows in the overview's order: a claude session goes to the claude section, everything else to general.
```

and replace

```fish
        if test "$f[2]" = claude
            # The overview's snapshot has filled the active-pane memo __tcz_tmux_activepath reads.
            set -l cwd (__tcz_tmux_activepath $f[1])
            set -l proj
            test -n "$cwd"; and set proj (__tcz_claude_project_of "$cwd")
            set -l g (__tcz_landing_group_of "$proj")
            set -a crows (printf '%s\tclaude/%s\t%s\t%s\t%s' $f[1] $g $mark $f[4] "$f[5]")
        else
```

with

```fish
        if test "$f[2]" = claude
            set -a crows (printf '%s\tclaude\t%s\t%s\t%s' $f[1] $mark $f[4] "$f[5]")
        else
```

- [ ] **Step 4: The model's output order and the older row's text**

Replace

```fish
    # The claude section, group by group; within one, discovery's newest-first order holds.
    for g in $__tcz_landing_groups
        string match -- "*$TAB"claude/"$g$TAB*" $crows
        string match -- "*$TAB$g$TAB*" $prows
    end
    test $nold -gt 0; and printf 'older\tolder\t0\t%s\t...older (%s)\n' $nold $nold
```

with

```fish
    # The claude section: the live sessions, then group by group the idle projects (discovery's newest-first order).
    for r in $crows
        printf '%s\n' $r
    end
    for g in $__tcz_landing_groups
        string match -- "*$TAB$g$TAB*" $prows
    end
    test $nold -gt 0; and printf 'older\tolder\t0\t%s\t▸ older (%s)\n' $nold $nold
```

(The loop, not `printf '%s\n' $crows`: with no live claude session that would print one empty line, an empty row.) Then check nothing became dead: `grep -n '__tcz_tmux_activepath\|__tcz_landing_group_of\|__tcz_claude_project_of' functions/tmux-categorize.fish` still shows callers of all three outside the model's removed lines (activepath ~:953 and ~:5104; group_of in the model's idle-project line; project_of in discovery and the busy check).

- [ ] **Step 5: Run the categorize suite, then the full gate**

Categorize suite (both modes): the Step 2 failures pass. Then all 9 suites, both modes: 9/9 `ALL PASS`; install 962/961.

- [ ] **Step 6: Mutation check (report the results)**

On a full-tree scratch copy, one at a time, run the categorize suite and report which assertions fail:
1. Sort the live claude rows by name (`set crows (printf '%s\n' $crows | sort)` before the output) → `model v3.1: the live claude sessions first, …` fails (co cp cw cx).
2. Print the idle projects before the live rows (swap the `for r in $crows` loop below the group loop) → the same assertion fails.
3. Keep `...older (%s)` in the older row's printf → `model v3.1: the older row reads ▸ older (N)` fails, and so do the older-row and switch-older e2e assertions that look for `▸ older (1)`.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): v3.1 model rows -- live claude sessions first, most recently attached, in no group; the older row reads ▸ older (N)"
```

---

### Task 2: Draw the v3.1 list

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_list_row` (~:2132–2190) and `__tcz_popup_list_lines` (~:2192–2253), both whole functions
- Test: `tests/test-tmux-popup.fish` — the list block (~:86–177), the `MM` fixture (~:286–291), the `BM` fixture (~:372)

**Interfaces:**
- Consumes (Task 1): the categories `claude`, `<group>`, `older`, `general`.
- Produces: `__tcz_popup_list_row <listwidth> <sel> <current> <row>` (signature unchanged) → one line, exactly `<listwidth>` visible columns, every row the same geometry (0-based columns, list width `w`): col 0 the section's rail `│` (orange 208; green 2 in general), the pointer `▐` or the current session's `❯`; col 1 blank; cols 2..w-4 the text, a marker flush right ending at col w-4; col w-3 blank; col w-2 the right rail `│` (orange 208 for `claude`, gold 178 for a group, gray 245 for `older`, green 2 for `general`); col w-1 blank. The selection band covers cols 0..w-3. The older row's text is gray 247.
- Produces: `__tcz_popup_list_lines <listwidth> <selidx> <current>` (signature and records `__tcz_pl_row/_line/_first` unchanged). A section rule is `╭── <word> `, `─` to col w-3, `╮` at col w-2, a blank (bold, 208 or 2); a list too narrow for that draws the word alone, cut or padded to the width. A box rule is as in v3, with the older box's rule gray 245. The only rail row left is the one after the older box (orange `│` at col 0, gray 245 `│` at col w-2).

- [ ] **Step 1: Replace the v3 list tests with v3.1 ones (RED)**

In `tests/test-tmux-popup.fish`, replace everything from the header comment `# __tcz_popup_list_lines (v3): the claude section …` (its opening `# ----` line, ~:86) through the `v3 list: a wide-character name keeps the row 20 columns` assertion (~:177) with:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_list_lines (v3.1): the claude section (live sessions under its rule, a gold box per
# directory, the gray older box), then general; a right rail beside every section and box; every
# line exactly listwidth columns
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
set -g FX (printf 'cp\tclaude\t2\t0\tcp · task') \
    (printf 'cw\tclaude\t1\t0\tcw') \
    (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf '/h/workspace/wi\tworkspace\t0\t0\twi · 1w') \
    (printf 'older\tolder\t0\t3\t▸ older (3)') \
    (printf 'g1\tgeneral\t0\t0\tg1') \
    (printf 'g2\tgeneral\t1\t0\tg2')
# Lines: [1] claude rule [2] cp [3] cw [4] projects box [5] pi [6] workspace box [7] wi [8] older box
# [9] ▸ older (3) [10] the older box's rail [11] general rule [12] g1 [13] g2
set -g L (printf '%s\n' $FX | __tcz_popup_list_lines 40 -1 '')
set -l lw
for l in $L; set -a lw (string length --visible -- (vis "$l")); end
t "v3.1 list: 13 lines, every one 40 columns" "13 40" "$(count $L) $(printf '%s\n' $lw | sort -u | string join ,)"
t "v3.1 list: records each row's line and the first line its window keeps (its section or box rule when it opens one)" "2 3 5 7 9 12 13|1 3 4 6 8 11 13" "$__tcz_pl_line|$__tcz_pl_first"
function __tcp_cell --argument-names line col --description '"<256-color><glyph>" at visible column <col> of <line>: the last 38;5;N set before it, - after a reset'
    set -l fg -; set -l c 0
    for tok in (string match -ar '\e\[[0-9;]*m|[^\e]' -- "$line")
        if string match -qr '^\e\[' -- "$tok"
            set -l n (string match -rg '38;5;([0-9]+)' -- "$tok")
            test -n "$n"; and set fg $n
            string match -qr '^\e\[(0|39)?m$' -- "$tok"; and set fg -
            continue
        end
        set c (math $c + 1)
        test $c -eq $col; and echo "$fg$tok"; and return 0
    end
    return 1
end
# Every line's first column (a section's rail or its rule's corner) and its 39th (a right rail or a rule's ╮).
set -l lc1; set -l lc39
for l in $L
    set -a lc1 (__tcp_cell $l 1)
    set -a lc39 (__tcp_cell $l 39)
end
t "v3.1 list: the left rail -- orange down the whole claude section, green down general" "208╭ 208│ 208│ 208│ 208│ 208│ 208│ 208│ 208│ 208│ 2╭ 2│ 2│" "$lc1"
t "v3.1 list: the right rail -- orange beside the live sessions down to the first box rule, gold per box ending at its last member, the gray older box's one row past its row, green beside general" "208╮ 208│ 208│ 178╮ 178│ 178╮ 178│ 245╮ 245│ 245│ 2╮ 2│ 2│" "$lc39"
t "v3.1 list: the claude rule opens the section, bold orange, its ╮ two columns in" 1 (string match -qr '^\e\[1;38;5;208m╭── claude ─+╮\e\[0m $' -- $L[1]; and echo 1; or echo 0)
t "v3.1 list: the live sessions sit directly under the claude rule, in no box, markers just inside the right rail" "1 1" "$(string match -qr '^│ cp · task +\[here\] │ $' -- (vis $L[2]); and echo 1; or echo 0) $(string match -qr '^│ cw +\[attached\] │ $' -- (vis $L[3]); and echo 1; or echo 0)"
t "v3.1 list: a box rule: its name centered, ╮ two columns in" "│ "(string repeat -n 13 ─)" projects "(string repeat -n 13 ─)"╮ " (vis $L[4])
t "v3.1 list: the box rule is bold gold" 1 (string match -q -- '*1;38;5;178m*' $L[4]; and echo 1; or echo 0)
t "v3.1 list: the next box's rule follows its last member directly, its own name centered" "│ "(string repeat -n 12 ─)" workspace "(string repeat -n 13 ─)"╮ " (vis $L[6])
t "v3.1 list: the older box rule is wordless" "│ "(string repeat -n 36 ─)"╮ " (vis $L[8])
t "v3.1 list: ... and bold gray 245" 1 (string match -q -- '*1;38;5;245m*' $L[8]; and echo 1; or echo 0)
t "v3.1 list: the older row reads ▸ older (3) in gray 247" 1 (string match -q -- '*38;5;247m▸ older (3)*' $L[9]; and echo 1; or echo 0)
t "v3.1 list: the older box's rail runs one row past its row, with no corner" "│"(string repeat -n 37 ' ')"│ " (vis $L[10])
t "v3.1 list: the general rule opens general, bold green, its ╮ two columns in" 1 (string match -qr '^\e\[1;38;5;2m╭── general ─+╮\e\[0m $' -- $L[11]; and echo 1; or echo 0)
t "v3.1 list: general rows sit between the green rails, a marker just inside the right one" "1 1" "$(string match -qr '^│ g1 +│ $' -- (vis $L[12]); and echo 1; or echo 0) $(string match -qr '^│ g2 +\[attached\] │ $' -- (vis $L[13]); and echo 1; or echo 0)"
t "v3.1 list: an idle project is muted -- its name, then its age" 1 (string match -q -- '*38;5;247mpi*38;5;243m · 2d*' $L[5]; and echo 1; or echo 0)
set -l nobot 1
for l in $L; string match -qr '[╰╯└┘]' -- $l; and set nobot 0; end
t "v3.1 list: no bottom borders anywhere" 1 $nobot

function __tcp_band --description '"first-last" columns of argv[1] on the selection band (__tcz_theme sel-bg); 0-0 when none'
    set -l bg (__tcz_theme sel-bg)
    set -l on 0; set -l col 0; set -l first 0; set -l last 0
    for tok in (string match -ar '\e\[[0-9;]*m|[^\e]' -- "$argv[1]")
        if string match -qr '^\e\[' -- "$tok"
            test "$tok" = "$bg"; and set on 1
            string match -qr '^\e\[(0|49)?m$' -- "$tok"; and set on 0
            continue
        end
        set col (math $col + 1)
        test $on -eq 1; or continue
        test $first -eq 0; and set first $col
        set last $col
    end
    echo "$first-$last"
end
# The pointer takes the left rail's cell in its section's color; the band stops before the right rail in every section.
set -l Ls (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 '')
set -l Lp (printf '%s\n' $FX | __tcz_popup_list_lines 40 2 '')
set -l Lo (printf '%s\n' $FX | __tcz_popup_list_lines 40 4 '')
set -l Lg (printf '%s\n' $FX | __tcz_popup_list_lines 40 5 '')
set -l lsel (__tcp_cell $Ls[2] 1) (__tcp_band $Ls[2]) (__tcp_cell $Lp[5] 1) (__tcp_band $Lp[5]) \
    (__tcp_cell $Lo[9] 1) (__tcp_band $Lo[9]) (__tcp_cell $Lg[12] 1) (__tcp_band $Lg[12])
t "v3.1 list: the pointer -- orange on a live session, a project and the older row, green in general; the band 1-38 on each" "208▐ 1-38 208▐ 1-38 208▐ 1-38 2▐ 1-38" "$lsel"
functions -e __tcp_band
set -l Lc (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 cw)
t "v3.1 list: the current session off the pointer: a yellow ❯ in the rail cell, a yellow [current] just inside the right rail" 1 (string match -qr '^❯ cw +\[current\] │ $' -- (vis $Lc[3]); and string match -q -- (printf '\e[38;5;179m❯')'*' $Lc[3]; and string match -q -- (printf '*\e[38;5;179m[current]')'*' $Lc[3]; and echo 1; or echo 0)
set -l Lcs (printf '%s\n' $FX | __tcz_popup_list_lines 40 1 cw)
t "v3.1 list: the current session under the pointer: ▐ takes the rail cell, the name stays yellow, [current] goes dim" 1 (string match -qr '^▐ cw +\[current\] │ $' -- (vis $Lcs[3]); and string match -q -- (printf '*\e[38;5;179mcw')'*' $Lcs[3]; and string match -q -- (printf '*\e[2m[current]')'*' $Lcs[3]; and echo 1; or echo 0)
set -l lrow (__tcz_popup_list_row 40 1 '' $FX[1])
t "v3.1 list: the drawer draws a row as the list does (selected, live)" "$Ls[2]" "$lrow"
# Only a live row can be current: the older row and an idle project never take the marker, even when a session shares the name.
function __tcp_iscur --description '1 when argv[1] carries [current] or the current session'"'"'s ❯, else 0'
    string match -q -- '*[current]*' "$argv[1]"; or string match -q -- '*❯*' "$argv[1]"; and echo 1; or echo 0
end
set -l cgO (__tcp_iscur (vis (__tcz_popup_list_row 40 0 older (printf 'older\tolder\t0\t3\tolder (3)'))))
set -l cgP (__tcp_iscur (vis (__tcz_popup_list_row 40 0 cp (printf 'cp\tprojects\t0\t0\tcp · 2d'))))
set -l cgL (__tcp_iscur (vis (__tcz_popup_list_row 40 0 older (printf 'older\tgeneral\t0\t0\tolder'))))
set -l cgB (__tcp_iscur (vis (__tcz_popup_list_row 40 0 cp (printf 'cp\tclaude\t0\t0\tcp'))))
t "v3.1 list: only a live row is current -- not the older row (a session named older is current), not an idle project of the same name; a live row, either section, is" "0 0 1 1" "$cgO $cgP $cgL $cgB"
functions -e __tcp_iscur
# Narrow and long: rows truncate with …, a marker that leaves the name no room is dropped, and every line keeps the width.
set -l LN (printf '%s\n' (printf 'averylongsessionname\tclaude\t1\t0\taverylongsessionname') (printf 'averylongsession2\tgeneral\t1\t0\taverylongsession2') | __tcz_popup_list_lines 12 0 '')
set -l lnw
for l in $LN; set -a lnw (string length --visible -- (vis "$l")); end
t "v3.1 list: at 12 columns every line keeps the width (4 lines)" "4 12" "$(count $LN) $(printf '%s\n' $lnw | sort -u | string join ,)"
t "v3.1 list: a narrow row drops its marker and truncates its name" 1 (string match -q -- '*…*' (vis $LN[2]); and not string match -q -- '*attached*' (vis $LN[2]); and echo 1; or echo 0)
set -l LL (printf 'supercalifragilistic\tclaude\t1\t0\tsupercalifragilisticexpialidocious\n' | __tcz_popup_list_lines 30 -1 '')
t "v3.1 list: a long live name truncates with … and keeps its marker before the right rail" "30 1" "$(string length --visible -- (vis $LL[2])) $(string match -qr '….*\[attached\] │ $' -- (vis $LL[2]); and echo 1; or echo 0)"
set -l LE (printf 'sx\tgeneral\t0\t0\tok✅done\n' | __tcz_popup_list_lines 20 0 '')
t "v3.1 list: a wide-character name keeps the row 20 columns" 20 (string length --visible -- (vis $LE[2]))
functions -e __tcp_cell
```

Then, in the memo-equivalence test's fixture (~:286–291), the live rows become `claude` and the older row's text changes:

```fish
set -g MM (printf 'c1\tclaude\t0\t0\tc1') (printf 'c2\tclaude\t0\t0\tc2') \
    (printf 'c3\tclaude\t0\t0\tc3')
```

and `(printf 'older\tolder\t0\t2\t...older (2)')` → `(printf 'older\tolder\t0\t2\t▸ older (2)')`. Its expected `"40 0 37 1 4"` is unchanged (measured): 40 compares, 0 differing, 37 with a pointer, scrolled (the list is 20 lines in an 8-row window), 4 builds. `MM[5]` is still `/p/w2`.

And in the badge paint test (~:372) `(printf 'cp\tclaude/projects\t1\t0\tcp')` → `(printf 'cp\tclaude\t1\t0\tcp')` (fixture hygiene; that test passes either way until Task 3).

Check: `grep -n 'claude/' tests/test-tmux-popup.fish` lists nothing.

- [ ] **Step 2: Run the popup suite; confirm the RED set**

Run: `env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish --no-config tests/test-tmux-popup.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`

Expected (measured against `4e66a6b`'s drawer): 23 FAILs, every `v3.1 list:` assertion except three non-regression guards that pass before and after: `no bottom borders anywhere`, `only a live row is current …`, `a wide-character name keeps the row 20 columns`. The memo-equivalence test passes before and after (it compares the memo with a full build of the same drawer: a non-regression guard). The old drawer reads `claude` as a box name, so `the drawer draws a row as the list does` fails on the row index, not on the drawing.

- [ ] **Step 3: Rewrite `__tcz_popup_list_row`**

Replace the whole function with:

```fish
function __tcz_popup_list_row --argument-names listwidth sel current row --description 'pure: one chooser row, exactly <listwidth> columns, between its section'"'"'s rail and a right rail two columns in: orange beside a live claude session, gold in a directory box, gray for the older row, green in general. <sel> = 1: the ▐ pointer in its section'"'"'s color, on a band that stops before the right rail. <current>: the session marked [current].'
    set -l f (string split -m 4 \t -- "$row")
    set -l name "$f[1]"; set -l cat "$f[2]"; set -l att "$f[3]"; set -l disp "$f[5]"
    # Section color (rail, pointer) and right-rail color; the text stops three columns short: a gap, the right rail, a blank.
    set -l sc 208; set -l rc 178; set -l textw (math $listwidth - 5)
    if test "$cat" = general
        set sc 2; set rc 2
    else if test "$cat" = claude
        set rc 208
    else if test "$cat" = older
        set rc 245
    end
    # Only a live row can be current: the older row and an idle project are no session.
    set -l iscur 0
    test -n "$current"; and test "$name" = "$current"; and not contains -- "$cat" $__tcz_landing_idle_categories; and set iscur 1
    set -l mk ''
    if test $iscur -eq 1
        set mk '[current]'
    else if test "$att" = 2
        set mk '[here]'
    else if test "$att" = 1
        set mk '[attached]'
    end
    # The marker sits flush right; it is dropped when the name would get no room.
    set -l namespace $textw
    if test -n "$mk"
        set namespace (math $textw - (string length -- "$mk") - 1)
        if test $namespace -lt 1
            set mk ''; set namespace $textw
        end
    end
    test $namespace -lt 1; and set namespace 1
    set -l shown (__tcz_popup_truncate "$disp" $namespace)
    set -l pad (math $namespace - (string length --visible -- "$shown"))
    test $pad -lt 0; and set pad 0
    set -l pads (string repeat -n $pad ' ')
    # Idle projects are muted (the name, then its age), the older row gray, the current session yellow.
    set -l text "$shown"
    if contains -- "$cat" $__tcz_landing_groups
        set -l nl (string length -- (string replace -r ' · [^·]*$' '' -- "$disp"))
        set -l nm (string sub -l $nl -- "$shown")
        set -l age (string sub -s (math $nl + 1) -- "$shown")
        set text (printf '\e[38;5;247m%s\e[38;5;243m%s\e[39m' "$nm" "$age")
    else if test "$cat" = older
        set text (printf '\e[38;5;247m%s\e[39m' "$shown")
    else if test $iscur -eq 1
        set text (printf '\e[38;5;179m%s\e[39m' "$shown")
    end
    set -l mkpart ''
    if test -n "$mk"
        set mkpart (printf ' \e[2m%s\e[22m' $mk)
        test $iscur -eq 1; and test "$sel" != 1; and set mkpart (printf ' \e[38;5;179m%s\e[39m' $mk)
    end
    # The rail cell: the pointer on the band, the current session's ❯, or the section's rail.
    set -l lead (printf '\e[38;5;%sm│\e[39m ' $sc)
    test $iscur -eq 1; and set lead (printf '\e[38;5;179m❯\e[39m ')
    test "$sel" = 1; and set lead (printf '%s\e[38;5;%sm▐\e[39m ' (__tcz_theme sel-bg) $sc)
    printf '%s%s%s%s \e[0m\e[38;5;%sm│\e[0m \n' "$lead" "$text" "$pads" "$mkpart" $rc
end
```

(The diff against the v3 function: the color block (`bc` becomes `rc`, set for every category, and general's text width is the same as every row's), the older row's text color 8 → 247, and the tail printed for every row.)

- [ ] **Step 4: Rewrite `__tcz_popup_list_lines`**

Replace the whole function with:

```fish
function __tcz_popup_list_lines --argument-names listwidth selidx current --description 'landing rows (stdin) -> the chooser list, every line <listwidth> wide: the claude section (live sessions, a box per directory, the older box), then general; a right rail beside every section and box, no bottom borders. Pointer on row #<selidx> (-1: none); <current> marked. Records each drawn row, its line and the first line its window keeps in __tcz_pl_row, __tcz_pl_line and __tcz_pl_first.'
    test -n "$listwidth"; and test "$listwidth" -gt 0 2>/dev/null; or set listwidth 30
    test -n "$selidx"; or set selidx 0
    set -g __tcz_pl_row; set -g __tcz_pl_line; set -g __tcz_pl_first
    # A rail ends at its last row; only the older box's runs one row further, before general.
    set -l gap (string repeat -n (math "max(0, $listwidth - 3)") ' ')
    set -l oldrail (printf '\e[38;5;208m│\e[0m%s\e[38;5;245m│\e[0m ' "$gap")
    set -l sect ''; set -l box ''; set -l n 0; set -l idx 0
    while read -l row
        set -l f (string split -m 4 \t -- $row)
        test (count $f) -ge 5; or continue
        # Sections: general, else claude. Boxes: an idle project's group, and the older row's own.
        set -l rsect claude; set -l rbox $f[2]
        test "$f[2]" = general; and set rsect general
        contains -- "$f[2]" claude general; and set rbox ''
        set -l first 0
        if test "$box" = older; and test "$rbox" != older
            printf '%s\n' "$oldrail"
            set n (math $n + 1)
        end
        if test "$rsect" != "$sect"
            set -l c 208
            test $rsect = general; and set c 2
            set -l lead "╭── $rsect "
            set -l fill (math $listwidth - (string length -- "$lead") - 2)
            if test $fill -gt 0
                set -l rule (string repeat -n $fill ─)
                printf '\e[1;38;5;%sm%s%s╮\e[0m \n' $c "$lead" "$rule"
            else
                # Too narrow for the rule: the word alone, cut or padded to the width.
                set -l cut (__tcz_popup_truncate "$lead" $listwidth)
                set -l pad (string repeat -n (math $listwidth - (string length --visible -- "$cut")) ' ')
                printf '\e[1;38;5;%sm%s\e[0m%s\n' $c "$cut" "$pad"
            end
            set n (math $n + 1); set first $n
        end
        if test -n "$rbox"; and test "$rbox" != "$box"
            # The box rule runs from the rail's gap to the ╮ two columns in, the name centered in it.
            set -l c 178; set -l word " $rbox "
            if test "$rbox" = older
                set c 245; set word ''
            end
            set -l span (math "max(0, $listwidth - 4)")
            set word (__tcz_popup_truncate "$word" $span)
            set -l wl (string length --visible -- "$word")
            set -l lh (math "floor(($span - $wl) / 2)")
            set -l lrule (string repeat -n $lh ─)
            set -l rrule (string repeat -n (math $span - $wl - $lh) ─)
            printf '\e[38;5;208m│\e[0m \e[1;38;5;%sm%s%s%s╮\e[0m \n' $c "$lrule" "$word" "$rrule"
            set n (math $n + 1)
            test $first -gt 0; or set first $n
        end
        set sect $rsect; set box $rbox
        set -l s 0
        test $idx -eq $selidx; and set s 1
        __tcz_popup_list_row $listwidth $s "$current" "$row"
        set n (math $n + 1)
        test $first -gt 0; or set first $n
        set -a __tcz_pl_row "$row"; set -a __tcz_pl_line $n; set -a __tcz_pl_first $first
        set idx (math $idx + 1)
    end
    if test "$box" = older
        printf '%s\n' "$oldrail"
    end
end
```

- [ ] **Step 5: Run the popup suite, then the full gate**

Popup suite, both modes: `ALL PASS` (measured on a scratch copy with Tasks 1–2's code). Then all 9 suites, both modes: 9/9 `ALL PASS`, install 962/961. The categorize suite needs no change in this task: its landing globs read the rail cell and the name (`│ zz`, `▐ s1`, `^▐ (\S+)`), which every row still starts with; its integration test that feeds the overview straight into the drawer (~:770, categories `claude`/`running`/`general`) only asks that `r1` and `g1` show. If anything there fails, report it.

- [ ] **Step 6: Mutation check (report the results)**

On a full-tree scratch copy, one at a time, each turns exactly the named assertions red (measured):
1. The rail row after every box (`if test -n "$box"; and test "$rbox" != "$box"` in place of the older-only test) → `13 lines`, `records …`, both rail strips, and the box/older/general line assertions behind the shift (12 FAILs).
2. Live rows' right rail gold (`set rc 178` in the `claude` arm) → only `the right rail -- …`.
3. The older row's text in 8 → only `the older row reads ▸ older (3) in gray 247`.
4. A section rule without its corner (`─` for `╮` in the rule's printf) → `the right rail -- …`, `the claude rule …`, `the general rule …`.
5. The band over the right rail (drop the `\e[0m` before the rail in `__tcz_popup_list_row`'s last printf) → only `the pointer -- … the band 1-38 on each`.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(landing): draw the v3.1 list -- live sessions under the claude rule, a right rail on every section and box, the gray older box"
```

---

### Task 3: The header on top and the mode-colored frame

**Files:**
- Modify: `functions/tmux-categorize.fish` — a top-of-file constant after `__tcz_landing_idle_categories` (~:20); `__tcz_landing_paint` (~:1717, whole function); `__tcz_landing_border` (~:1748, whole function); `__tcz_landing`'s `case kill` prompt (~:1992); `__tcz_popup_frame`'s head (~:2444–2449)
- Test: `tests/test-tmux-popup.fish` (every `__tcz_popup_frame` / `__tcp_frame_bak` call; the painter test ~:338–356; the badge paint block ~:368–398; the border block ~:521–527); `tests/test-tmux-categorize.fish` (the x/d e2e ~:10369–10374; the hookless switch e2e ~:10535–10539; the stderr probe ~:10597–10603; the switcher resize e2e (c) ~:11636–11642)

**Interfaces:**
- Consumes (Task 2): `__tcz_popup_list_lines` and `__tcz_popup_list_row` as above.
- Produces: `__tcz_landing_frame_glyphs` = header line, junction, divider (`▔ ▕ ▕`).
- Produces: `__tcz_popup_frame <sel> <listw> <prevw> <rows> <current> <color> -- <model lines...>`: the divider (`$__tcz_landing_frame_glyphs[3]`) in 256-color `<color>`.
- Produces: `__tcz_landing_border <listw> <prevw> <cols> <color>`: the header line, `<cols> - 1` wide, `$__tcz_landing_frame_glyphs[1]` with `[2]` at column `<listw> + 1` (1-based) when `<prevw>` > 0, in `<color>`.
- Produces: `__tcz_landing_paint` (signature unchanged) emits row 1 the badge and legend (coral 203 `LANDING`; teal 37 `SWITCHING` … `esc close`), row 2 the header line, rows 3..`<rows>` the frame (`<rows>` − 2 rows, as before).
- `x`'s confirm prompt is written on row 1.

- [ ] **Step 1: Popup-suite tests (RED)**

In `tests/test-tmux-popup.fish`:

1. Delete the line `functions -e __tcp_cell` right after the `v3.1 list: a wide-character name keeps the row 20 columns` assertion (the helper now lives until the paint block erases it).

2. Every frame call gains the divider color `203` before its `--` (16 sites, two of them through the recorder copy `__tcp_frame_bak`):
   - `__tcz_popup_frame 11 20 0 8 '' -- $SCM` (two sites), `… 0 20 0 8 '' -- $SCM`, `… 10 20 0 8 '' -- $SCM`, `… 3 20 0 8 '' -- $SCM` → `… '' 203 -- $SCM`
   - in `__tcp_memo_cmp`: `__tcz_popup_frame $sel $listw 0 8 "$current" -- $MM` → `… "$current" 203 -- $MM`
   - `__tcp_frame_bak 0 33 46 22 '' -- $LPM` and `__tcp_frame_bak 1 33 46 22 '' -- $LPM` → `… '' 203 -- $LPM`
   - `__tcz_popup_frame 0 20 30 8 '' -- $LDproj $LDlive` (two sites), `… 0 20 30 8 '' -- $LDold $LDlive`, `… 1 20 30 8 '' -- $LDproj $LDlive`, `… 0 20 30 8 '' -- (printf 'older\tgeneral\t0\t0\tolder')` → `… '' 203 -- …`
   - `__tcz_popup_frame 0 20 30 8 '' -- $HM` and the two `… 1 20 30 8 '' -- $HM` → `… '' 203 -- $HM`

   Check: `grep -c ' 203 -- ' tests/test-tmux-popup.fish` is 16, and `grep -n "__tcz_popup_frame\|__tcp_frame_bak [0-9]" tests/test-tmux-popup.fish | grep -v ' 203 -- '` lists only the four `functions -c` / `function` / `functions -e` lines of the painter test's recorder.

3. The painter test (`# --- landing: the painter skips an unchanged frame and diffs a changed one ---`): replace

```fish
set -l lpborder (string match -q '*─┴─*' -- "$__tcz_pe_prev[23]"; and echo 1; or echo 0)
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[24]"); and echo 1; or echo 0)
t "paint: 24 rows -- the frame, a border with ┴ under the divider, then the legend with n new" "24 1 1" "$lprows $lpborder $lplegend"
```

   with

```fish
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[1]"); and echo 1; or echo 0)
set -l lpline (string match -q -- "*$__tcz_landing_frame_glyphs[1]$__tcz_landing_frame_glyphs[2]$__tcz_landing_frame_glyphs[1]*" "$__tcz_pe_prev[2]"; and echo 1; or echo 0)
t "paint: 24 rows -- the legend with n new, the header line with its junction, then the frame" "24 1 1" "$lprows $lplegend $lpline"
```

   and in the same test the frame now starts on screen row 3:

```fish
    test "$fa[$i]" = "$fb[$i]"; or set -a fdiff $i
```

   →

```fish
    test "$fa[$i]" = "$fb[$i]"; or set -a fdiff (math $i + 2)          # the frame starts on screen row 3
```

4. Replace the badge paint block, from `# --- paint: the badge, and every row of a 100x30 frame ---` through the `set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key` line right before `functions -e tmux __tcz_popup_preview`, with the block below (the three lines from `functions -e tmux __tcz_popup_preview` on stay as they are):

```fish
# --- paint: the header (badge and legend, then the header line) over a mode-colored divider, every row of a 100x30 frame ---
functions -c __tcz_popup_preview __tcp_preview_bak
function __tcz_popup_preview; printf 'PV-%s\n' $argv[1]; end
function tmux; end
set -g BM (printf 'cp\tclaude\t1\t0\tcp') (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf 'g1\tgeneral\t0\t0\tg1') (printf 'g2\tgeneral\t0\t0\tg2')
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
functions -e __tcp_cell
```

   (The list column at 100 columns is 40: `__tcz_popup_layout 100` → `40 59`, so the divider is column 41 and the header line is 40 + 1 + 58 = 99 wide.)

5. Replace the border block, from `# --- landing: the border between the list and the legend ---` through its three `t "border: …"` assertions, with:

```fish
# --- landing: the header line under the badge and legend ---
set -l g $__tcz_landing_frame_glyphs
set -l lb0 (__tcz_landing_border 33 46 80 203)
set -l lb1 (vis "$lb0")
set -l lb2 (vis (__tcz_landing_border 50 0 50 203))
set -l lb3 (vis (__tcz_landing_border 58 1 60 37))
set -l lbw1 (string repeat -n 33 $g[1])$g[2](string repeat -n 45 $g[1])
set -l lbw2 (string repeat -n 49 $g[1])
set -l lbw3 (string repeat -n 58 $g[1])$g[2]
t "header line: cols-1 wide, the junction over the divider (col 34 at 80 cols), in the color given" "1 1" "$(test "$lb1" = "$lbw1"; and echo 1; or echo 0) $(string match -q -- (printf '\e[38;5;203m')'*' "$lb0"; and echo 1; or echo 0)"
t "header line: no preview, no junction" "$lbw2" "$lb2"
t "header line: a one-column preview keeps the junction as its last cell" "$lbw3" "$lb3"
```

- [ ] **Step 2: Categorize-suite tests (RED)**

In `tests/test-tmux-categorize.fish`:

1. The x/d e2e (`# x asks first (n keeps, y kills); d detaches the tab and removes the landing session.`): replace

```fish
set -l la3ask (__tcg_screen_has "=$la3:" '*kill 0 ?*' 30; and echo 1; or echo 0)
command tmux -L $sock send-keys -t "=$la3:" n
sleep 0.5
set -l la3kept (command tmux -L $sock has-session -t =0 2>/dev/null; and echo 1; or echo 0)
t "app: x asks before killing, and n keeps the session" "1 1" "$la3ask $la3kept"
```

   with

```fish
set -l la3ask (__tcg_screen_has "=$la3:" '*kill 0 ?*' 30; and echo 1; or echo 0)
set -l la3top (command tmux -L $sock capture-pane -p -t "=$la3:")[1]
command tmux -L $sock send-keys -t "=$la3:" n
sleep 0.5
set -l la3kept (command tmux -L $sock has-session -t =0 2>/dev/null; and echo 1; or echo 0)
t "app: x asks before killing, on row 1 where the legend was, and n keeps the session" "1 1 1" "$la3ask $(string match -q -- '  kill 0 ?  (y/n)*' "$la3top"; and echo 1; or echo 0) $la3kept"
```

2. The hookless switch e2e (the folded carry-in): replace

```fish
# - the landing kill switch: a server without the landing pane-died hook (landing off) closes the session the old way
#   -- the client detaches, no landing session is made. show-hooks lists the bare hook name even when unset.
__tcg_swroom a
set -l swpids (jobs -p)
```

   with

```fish
# - the landing kill switch: a server without the landing pane-died hook (landing off) closes the session the old way
#   -- the client detaches, no landing session is made. show-hooks lists the bare hook name even when unset.
# - the server's own detach-on-destroy is off, so only the app's session-level on detaches the client
__tcg_swroom a
command tmux -L $sock set -g detach-on-destroy off
set -l swpids (jobs -p)
```

3. The switcher stderr probe (`# - fish's own errors never reach the switcher's popup: …`). Its anchor `'"$legend" (math $cols - 1))'` still matches the new emit line, but mid-statement: the copy would then emit only the legend and the test would stay green on a broken copy. Retarget it to the end of the emit line, and make the drawn check see the frame, not only the legend:

```fish
string replace -- '"$legend" (math $cols - 1))' '"$legend" (math $cols - 1)); __tcg_probe_nosuchcmd' < $lcat > $swq
```

   →

```fish
string replace -- '$cols $mc) $frame' '$cols $mc) $frame; __tcg_probe_nosuchcmd' < $lcat > $swq
```

   and

```fish
set -l swqdrawn (__tcg_screen_has "=sw:" '*SWITCHING*' 80; and echo 1; or echo 0)
```

   →

```fish
set -l swqdrawn (__tcg_screen_has "=sw:" '*╭── claude*' 80; and echo 1; or echo 0)
```

   (`__tcg_swroom` starts the claude session `cl`, so the frame's first rule is `╭── claude`. The test's `swqinj` = 1 guard proves the new anchor matches exactly one line.)

4. The switcher resize e2e (c): replace

```fish
for r in $sws[1..29]
    string match -qr '^[│┴]$' -- (string sub -s 34 -l 1 -- $r); and set swdiv (math $swdiv + 1)
    string match -q '*↑↓*' -- (string sub -l 33 -- $r); and set swinlist (math $swinlist + 1)
end
set -l swtop (string match -qr '^╭── ' -- "$sws[1]"; and echo 1; or echo 0)
set -l swlast (string match -qr '^ SWITCHING  ↑↓ move ' -- "$sws[30]"; and echo 1; or echo 0)
t "switcher: shrunk to 80x30, one step draws at the new size (list's top rule on row 1; the legend on row 30, not in the list on rows 1-29; the divider at column 34 on all 29 list rows, the last one the border's ┴; the step moved sw to zz)" "1 1 0 29 sw>zz" "$swtop $swlast $swinlist $swdiv $sw0>$swsel"
```

   with

```fish
for r in $sws[2..30]
    set -l c34 (string sub -s 34 -l 1 -- $r)
    contains -- "$c34" $__tcz_landing_frame_glyphs[2..3]; and set swdiv (math $swdiv + 1)
    string match -q '*↑↓*' -- (string sub -l 33 -- $r); and set swinlist (math $swinlist + 1)
end
set -l swhead (string match -qr '^ SWITCHING  ↑↓ move ' -- "$sws[1]"; and echo 1; or echo 0)
set -l swtop (string match -qr '^╭── ' -- "$sws[3]"; and echo 1; or echo 0)
t "switcher: shrunk to 80x30, one step draws at the new size (the legend on row 1, not in the list on rows 2-30; the list's top rule on row 3; the junction and the divider at column 34 on rows 2-30; the step moved sw to zz)" "1 1 0 29 sw>zz" "$swhead $swtop $swinlist $swdiv $sw0>$swsel"
```

   (`c34` is captured and quoted: an empty cell must not let `contains` take the first glyph as its key.)

- [ ] **Step 3: Run both suites; confirm the RED set**

Popup suite (measured against Task 2's code): 16 FAILs. Fix-discriminators: `paint: 24 rows -- the legend …`, `paint: a move between two project rows emits only the changed rows`, `frame glyphs: …`, `paint 100x30: …`, `paint: row 1 opens with a coral LANDING badge …`, `paint: row 2 is the coral header line …`, `paint: the switcher's row 1 …`, `paint: the switcher's header line and divider are teal …`, and the three `header line:` assertions. The five `frame:` preview assertions (`a project row or the older row never calls capture-pane`, `a project row previews its folder`, `a live row still previews its session`, `a live session named older …`, `with __tcz_pf_keep …`) fail only because the old frame takes the new `203` as its `--` and the real `--` as a model row: call-site fallout, non-regression guards in intent. Passing before and after: `paint: an unchanged frame is neither rebuilt nor emitted`, `paint: no esc close on the landing`, `paint: the switcher marks the current session …`, the scroll and memo tests.

Categorize suite: expected FAIL `app: x asks before killing, on row 1 where the legend was, …`, `switch: a fish error in its loop never reaches the screen …` (the new anchor is absent from the old code: `swqinj` 0), `switcher: shrunk to 80x30 …`. The hookless e2e passes before and after: a non-regression guard, whose discrimination Step 8 shows by mutation.

- [ ] **Step 4: The frame glyphs and the frame's divider color**

After the `set -g __tcz_landing_idle_categories …` line (~:20), add:

```fish
# The landing frame's glyphs, drawn in the mode color: the header line, its junction over the divider, the divider.
# Eighth blocks; for a terminal that lacks them, the box-drawing set ─ ┬ │ draws the same frame.
set -g __tcz_landing_frame_glyphs ▔ ▕ ▕
```

In `__tcz_popup_frame`, replace the `function __tcz_popup_frame …` line with

```fish
function __tcz_popup_frame --description '__tcz_popup_frame <sel> <listw> <prevw> <rows> <current> <color> -- <model lines...>: <rows> lines, each ending in erase-to-EOL, the divider in 256-color <color>. An overflowing list scrolls only to keep the selection in view (the window top persists in __tcz_pd_top). With __tcz_pf_keep = 1 the preview column is the last one built (__tcz_pf_right) if its size still matches: the landing app'"'"'s held moves.'
```

(406 characters, the old one's 391 plus the color), and

```fish
    set -l sel $argv[1]; set -l listw $argv[2]; set -l prevw $argv[3]; set -l rows $argv[4]; set -l current $argv[5]
    set -e argv[1..6]                  # argv[6] is the literal '--' separator
```

→

```fish
    set -l sel $argv[1]; set -l listw $argv[2]; set -l prevw $argv[3]; set -l rows $argv[4]; set -l current $argv[5]
    set -l color $argv[6]
    set -e argv[1..7]                  # argv[7] is the literal '--' separator
```

and

```fish
    set -l DIV (printf '\e[38;5;240m│\e[0m')
```

→

```fish
    set -l DIV (printf '\e[38;5;%sm%s\e[0m' $color $__tcz_landing_frame_glyphs[3])
```

- [ ] **Step 5: The header line**

Replace the whole `__tcz_landing_border` with:

```fish
function __tcz_landing_border --argument-names listw prevw cols color --description 'pure: the header line under the badge and key legend: <cols> - 1 wide (as the legend) in 256-color <color>, with the junction over the list/preview divider when there is a preview (glyphs: __tcz_landing_frame_glyphs)'
    set -l g $__tcz_landing_frame_glyphs
    set -l w (math $cols - 1)
    set -l line (string repeat -n $w $g[1])
    if test $prevw -gt 0; and test $listw -lt $w
        # Quoted: a zero-width repeat is an empty list, which would empty an unquoted concatenation.
        set -l left (string repeat -n $listw $g[1])
        set -l right (string repeat -n (math $w - $listw - 1) $g[1])
        set line "$left$g[2]$right"
    end
    printf '\e[38;5;%sm%s\e[0m' $color "$line"
end
```

- [ ] **Step 6: Paint the header on top, and the prompt on row 1**

Replace the whole `__tcz_landing_paint` with:

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> <hold> <mode> <current> -- <model lines...>: paint the badge and key legend (SWITCHING and esc close when <mode> is switch, else LANDING), the header line and the frame, framed in the mode color, through the diff emitter. <hold> = 1: a held move, no capture, the preview kept. <current>: the session marked [current]. Returns 1, building nothing, when nothing shown changed.'
    set -l sel $argv[1]; set -l rows $argv[2]; set -l cols $argv[3]; set -l hold $argv[4]
    set -l mode $argv[5]; set -l current $argv[6]
    set -e argv[1..7]
    set -l model $argv
    set -l lay (__tcz_popup_layout $cols | string split ' ')
    set -l cap
    set -l f (string split -m 2 \t -- $model[(math $sel + 1)])
    if test "$hold" != 1; and test $lay[2] -gt 0; and test -n "$f[1]"; and not contains -- "$f[2]" $__tcz_landing_idle_categories
        set cap (tmux capture-pane -e -p -t (__tcz_session_target "$f[1]") 2>/dev/null)
    end
    # <hold> is in the key: the quiet repaint after a hold, same row, must not be skipped.
    set -l key (string join \n -- $sel $rows $cols $hold "$mode" "$current" $model $cap | string collect)
    if test "$__tcz_pe_force" != 1; and set -q __tcz_lp_key; and test "$key" = "$__tcz_lp_key"
        return 1
    end
    set -g __tcz_lp_key "$key"
    # The mode color says which app this is: coral for the landing app, teal for the switcher over a session.
    set -l mc 203; set -l badge LANDING
    set -l keys '↑↓' move '⏎' open n new r resume x kill d detach
    if test "$mode" = switch
        set mc 37; set badge SWITCHING
        set -a keys esc close
    end
    set -g __tcz_pf_keep $hold
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) "$current" $mc -- $model)
    set -g __tcz_pf_keep 0
    set -l legend (printf '\e[1;7;38;5;%sm %s \e[0m' $mc $badge)(__tcz_legend_row 10 $keys)
    __tcz_popup_emit (__tcz_popup_truncate "$legend" (math $cols - 1)) (__tcz_landing_border $lay[1] $lay[2] $cols $mc) $frame
end
```

In `__tcz_landing`'s `case kill` arm, the prompt takes the legend's row:

```fish
                printf '\e[%s;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' $rows "$row[1]"
```

→

```fish
                printf '\e[1;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' "$row[1]"
```

(The comment on the next line, `# the prompt overwrote the legend`, stays true.)

- [ ] **Step 7: Run both suites, then the full gate**

Popup suite, both modes: `ALL PASS` (measured). Categorize suite, both modes: the Step 3 failures pass. Then all 9 suites, both modes: 9/9 `ALL PASS`, install 962/961.

- [ ] **Step 8: Mutation check (report the results)**

On a full-tree scratch copy, one at a time. Popup suite (measured, each fails exactly these):
1. The divider ignores its color (`203` for `$color` in `DIV`) → only `the switcher's header line and divider are teal …`.
2. The header line ignores its color (`240` in its printf) → `row 2 is the coral header line …`, `the switcher's header line and divider are teal …`, `header line: cols-1 wide … in the color given`.
3. The legend back at the bottom (`__tcz_popup_emit $frame (…border…) (…legend…)`) → the 24-row, move-diff, 100x30, row 1/row 2 and switcher assertions (7 FAILs).
4. No junction (`$g[1]` for `$g[2]` in the border) → the 24-row, row 2, switcher-teal and two `header line:` assertions.
5. The landing badge kept orange (`set -l mc 208`) → `paint 100x30 …`, `row 1 …`, `row 2 …`.

Categorize suite (derived, not measured while planning; report what you see):

6. The prompt back on `$rows` → `app: x asks before killing, on row 1 …`.
7. Drop `tmux set-option -t (__tcz_session_target $row[1]) detach-on-destroy on \;` from the landing-off branch → the hookless e2e fails (the client moves to another session instead of detaching).
8. The test's anchor reverted to `'"$legend" (math $cols - 1))'` → `switch: a fish error in its loop never reaches the screen …` fails on `swqdrawn` (the copy paints only the legend).

- [ ] **Step 9: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): the header on top and the mode-colored frame -- coral landing, teal switching; the x prompt on row 1"
```

---

### Task 4: Docs

**Files:**
- Modify: `README.md` (~:54, ~:58, ~:163), `CLAUDE.md` ("Landing session", "Current state"), `docs/superpowers/specs/2026-09-26-landing-session-design.md` (Status line, Open items)

**Interfaces:** none (no code paths change).

- [ ] **Step 1: README (one paragraph per line, as the file keeps it)**

In the "Landing page" paragraph (~:54):
- `` `claude` comes first: your live Claude sessions and the Claude projects that are not running right now, in a box per directory by where they live: `projects` (`~/projects`), `workspace` (`~/workspace`), `work` (`~/Work`) and `other`. Inside a box the live sessions come first (marked `[here]` when this device already has a tab on one, `[attached]` when only another device does), then the idle projects, newest conversation first. `` → `` `claude` comes first: your live Claude sessions, most recently attached first (marked `[here]` when this device already has a tab on one, `[attached]` when only another device does), then the Claude projects that are not running right now, in a box per directory by where they live: `projects` (`~/projects`), `workspace` (`~/workspace`), `work` (`~/Work`) and `other`, newest conversation first. ``
- `` hides in a final `...older (N)` box `` → `` hides in a final `▸ older (N)` box ``
- `` A `LANDING` badge starts the key legend at the bottom. `` → `` A coral `LANDING` badge opens the key legend at the top, and a thin line in the same color runs under the legend and down between the list and the preview. ``

In the switcher paragraph (~:58): `` with a `SWITCHING` badge in place of `LANDING`. `` → `` with a teal `SWITCHING` badge, line and divider in place of the coral `LANDING` ones. ``

"Colored picker preview" (~:163): `A key-legend footer row spells out the controls` → `A key-legend row at the top spells out the controls`.

- [ ] **Step 2: CLAUDE.md (budget 40,000 bytes; it is at 39,905)**

Run `wc -c CLAUDE.md` before and after and report both. The edits below prune the v2 sentence they replace; measured on a copy they take the file to 39,990. If your result is over 40,000, prune further before committing (candidates: sentences that restate a memory file, keeping its `[[pointer]]`); never remove a standing decision or a live trap.

1. "Landing session", its opening sentence: `` per-tab `_landing-N` chooser (a `claude` section of directory boxes, then `general`). `` → `` per-tab `_landing-N` chooser (`claude`: live sessions, a box per directory; then `general`). ``

2. Replace the `**v3**` bullet

```
- **v3** — the model's category carries the layout: `claude/<group>` live claude, `<group>` idle, `older`,
  `general` (running folded in, last). `__tcz_popup_list_row` draws a row; `__tcz_popup_list_lines` records
  `__tcz_pl_row/_line/_first`, which `__tcz_popup_list_memo` copies to `__tcz_pf_rrow/_rline/_rfirst` for the
  frame. `landing switch <client> [--take]` = the switcher: no settle, Esc/actions close it, `x` on the
  current session lands the client; badge per mode.
```

   with

```
- **v3.1** — the category carries the layout: `claude` live (overview order), `<group>` idle, `older`,
  `general` (running folded in, last). `__tcz_popup_list_row` draws a row, each with a right rail;
  `__tcz_popup_list_lines` records `__tcz_pl_row/_line/_first`, which the memo copies to `__tcz_pf_r*` for the
  frame. Paint: legend, `__tcz_landing_border`, frame; the mode color (203/37) is their argument, the glyphs
  `__tcz_landing_frame_glyphs`. `landing switch <client> [--take]` = the switcher: no settle, Esc/actions
  close it, `x` on the current session lands the client.
```

3. Replace the "Current state" heading and its first paragraph

```
## Current state — 2026-10-06

Chooser v2 is deployed and device-confirmed (2026-10-04). **Chooser v3 built (merged
`f4395b9`), awaiting `fisher update` on both machines;** then the workspace-TUI sidebar.
Mockups: claude-mock `06`–`12`; generator in `artifacts/mockgen/chooser-v3/`.
```

   with (today's date in the heading)

```
## Current state — 2026-10-07

**Chooser v3.1 built on branch `feat/landing-chooser-v3-1`, awaiting merge and `fisher update` on both
machines;** then the workspace-TUI sidebar. Mockups: claude-mock `06`–`18`; generators in
`artifacts/mockgen/chooser-v3/`.
```

- [ ] **Step 3: The spec**

- Status line: `**Chooser v3.1** (approved 2026-10-07 from mockups `14`–`18`, not built)` → `**Chooser v3.1** (approved 2026-10-07 from mockups `14`–`18`; built on branch `feat/landing-chooser-v3-1`, awaiting merge and `fisher update`)` (the merge step fills in the sha).
- Under "## Open items", after the `Rulings taken while building v3 (settled, not open):` sub-list, add:

```
- Rulings taken while building v3.1 (settled, not open):
  - `x`'s y/n confirm takes the legend's place on row 1 (it overwrote the bottom legend row before); its text and orange are unchanged.
  - In the narrow layout (no preview column, under 60 columns) there is no divider, and row 2 is a plain line across the legend's width.
  - The `claude` rule ends in `╮` even when no live session is listed: the orange corner then sits directly above the first box rule's gold one.
  - The frame learns the mode color as an argument of the header line and the frame; only the painter maps the mode to coral or teal.
  - The three frame glyphs are one list in the categorizer (`__tcz_landing_frame_glyphs`), and the tests read it: the box-drawing fallback is that list plus the one test that pins it.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-09-26-landing-session-design.md
git commit -m "docs: chooser v3.1 in README, CLAUDE.md and the landing spec"
```

---

### Task 5: Fit review

- [ ] **Step 1:** Invoke the `fit-review` skill on the branch with base = the commit that adds this plan (`main` at the commit whose subject is `docs(plan): landing chooser v3.1 -- header on top, mode-colored frame, unboxed live sessions, rails`; `git log -1 --format=%h -- docs/superpowers/plans/2026-10-07-landing-chooser-v3-1.md` on `main`). The style guide's vocabulary line still reads "category = live `claude/<group>` or `general`": it is stale after Task 1, and the fit review updates it. A fit pass that refactors is a fix wave: a scoped re-review of what it changed and the full gate (9 suites, both modes) before merging.

### After the plan (controller)

- **Before merge — the spec's glyph check:** ask the user to run `fish ~/workspace/tmux-lives/artifacts/glyphtest.fish` in iTerm2 and in Ghostty on macwork (an ssh session to rocket is fine: the terminal draws the glyphs) and say whether block E draws `▔` and `▕`. If either terminal lacks one: `set -g __tcz_landing_frame_glyphs ─ ┬ │` and the pinning assertion's expected `"─ ┬ │"`, run the popup and categorize suites in both modes, commit `fix(landing): the box-drawing frame glyphs -- <terminal> lacks the eighth blocks`. Record the result in the spec's first Open item either way.
- Merge `feat/landing-chooser-v3-1` into `main` locally, push, fill the merge sha into the spec Status (`merged to `main` at `<sha>`, awaiting `fisher update``) and CLAUDE.md "Current state" (`**Chooser v3.1 built (merged `<sha>`), awaiting `fisher update` on both machines;** then the workspace-TUI sidebar.`), delete this plan file (`git rm`), commit and push.
- Republish the spec to the vault: `vault-publish --type project --project "$(cat .vault-project)" docs/superpowers/specs/2026-09-26-landing-session-design.md --title "Landing Session - Design"`, reflow the vault copy to one line per paragraph (if the publish exits 3 because the last vault copy was reflowed, diff the vault copy against the reflowed previous source; force only when that is the whole difference), and give the `obsidian://open?vault=Vault&file=Notes%2FProjects%2FTmux-lives%2FLanding%20Session%20-%20Design` link.
- Ask the user to `fisher update` on both machines and smoke-test: a new ShellFish tab (coral header and divider, live Claude sessions at the top, `▸ older (N)`), `Alt+S` inside a session (teal), and `x` on a live row (the prompt on row 1).

## Spec coverage

| Spec requirement (v3.1) | Where |
|---|---|
| Live claude sessions first, most recently attached, no box; idle projects by box; running in general | Task 1 `model v3.1: the live claude sessions first, …` |
| `▸ older (N)` in 247, its box rule and rail 245, one rail row beneath it | Task 1 `model v3.1: the older row reads …`; Task 2 `the older box rule …`, `… bold gray 245`, `the older row reads ▸ older (3) in gray 247`, `the older box's rail runs one row past its row …` |
| `╭── claude ───…╮` orange; left rail down the section; right rail beside the live rows ending at the first box rule | Task 2 `the claude rule …`, `the left rail -- …`, `the right rail -- …` |
| Gold box rules, name centered, `╮`; the rail ends at the box's last member; the next rule follows directly | Task 2 `a box rule …`, `the next box's rule follows its last member directly …`, `the right rail -- …` |
| `general` with rails both sides, the same height; no bottom borders | Task 2 `the general rule …`, `general rows sit between the green rails …`, both rail strips, `no bottom borders anywhere` |
| Pointer color per section; band stops at the right rail; marker just inside it | Task 2 `the pointer -- …`, `the live sessions sit directly under …`, `general rows sit …` |
| Header: badge + legend row 1, mode-colored `▔` line row 2 across the legend's width, junction `▕` | Task 3 `paint: row 1 …`, `paint: row 2 …`, the `header line:` assertions |
| Divider `▕` in the mode color from row 2 down, both modes; list and preview from row 3 | Task 3 `paint 100x30 …`, `the switcher's header line and divider are teal …`, the resize e2e |
| Every frame row's width and the frame's row count | Task 3 `paint 100x30: 30 rows; … 40 wide …`, `paint: 24 rows …`; Task 2 `13 lines, every one 40 columns` |
| Mode color coral 203 / teal 37 for badge, line and divider | Task 3 `paint: row 1 …` (203), `the switcher's row 1 …` (37), mutations 1, 2, 5 |
| Glyph fallback is a one-place change | Task 3 `frame glyphs: …` + the global; controller's pre-merge glyph check |
