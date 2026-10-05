# Landing Chooser v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redraw the landing chooser in the approved nested layout (layout E1), give it a `LANDING` / `SWITCHING` badge, and make the in-session switcher (`M-s`, `prefix S`, `tmux-lives picker` inside tmux) the same app full screen in a borderless popup, removing the two-pane switcher.

**Architecture:** The model (`__tcz_landing_model`) keeps its five-field rows and moves the layout facts into the category field (`claude/<group>` for a live claude session, `<group>` for an idle project, `older`, `general`). One row drawer (`__tcz_popup_list_row`) draws a single row in its section or box; `__tcz_popup_list_lines` walks the rows, adds the section rules, box rules and rail rows, and records where each row landed, which the list memo and the frame's window walk read instead of re-deriving it. The landing loop takes a `switch <client> [--take]` mode: same code, no settle window, the current session marked, and an action or Esc closes it.

**Tech Stack:** fish 4 (`fish --no-config` scripts), tmux 3.3a (rocket) / 3.7b (macwork), the repo's own fish test suites.

**Spec:** `docs/superpowers/specs/2026-09-26-landing-session-design.md`. Read the Status line and "The landing app" → "Layout (v3)" + "Drawing (v3)", "## Switch mode (v3)", and the Testing bullets "Layout (v3)" and "Switch mode". The approved rendering is mockup `09` (layout E1) and `12` (switching), copies in `artifacts/mockgen/chooser-v3/` (rocket only, gitignored). Its drawing code, `gen.py` → `e1_list()` / `entry5()` / `sub_box_header()` / `badged()`, is the geometry source: when this plan and that code disagree, the code is right and this plan has a defect.

## Global Constraints

- ⛔ **LIVE-SERVER RULE.** Every agent shell runs inside the user's LIVE tmux: `$TMUX` names his real server and `TMUX` beats `TMUX_TMPDIR`. Every tmux command you type names its socket (`command tmux -L <name>` / `-S <path>`) or runs inside a suite that pins one; never a bare `tmux`, never a bare `kill-server`. A review agent killed the live server this way on 2026-09-29 (`docs/2026-09-29-review-agent-killed-live-tmux-server.md`).
- ⛔ **Never deploy.** No `fisher install/update`, no `cp` into `~/.config/fish/`, no edits to `~/.tmux.conf`, no `set -U`. Commit to the branch; the user deploys with his own `fisher update`.
- Any ad-hoc run of the landing app or the theme engine outside a suite exports `tmux_lives_render_cache_dir`, `tmux_lives_claude_projects_dir` and `tmux_lives_project_cache` to temp paths first (an agent's run once deleted the user's real render-cache file).
- **Gate:** each suite is its own FOREGROUND Bash call with `timeout: 600000`, plain then `--no-config`:
  - `fish tests/test-<name>.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('` (and the same with `fish --no-config`)
  - the popup suite only as `env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish [--no-config] tests/test-tmux-popup.fish` (`artifacts/notmux/tmux` exits 1, so a stray tmux call fails instead of reaching a server)
  - never wrap a suite in shell `timeout`; never judge by `tail -1`
  - if a Bash call reports it was backgrounded, do not wait for it: abandon it and re-run in the foreground with the explicit timeout
- Baseline at `main` `8b2286e`: 9/9 `ALL PASS` in both modes; `test-tmux-install.fish` 960 plain / 959 `--no-config` (the 1-count delta is BY DESIGN — do not "fix" it), `test-generic.fish` 3, `test-tmux-status.fish` 4. If an install count changes, report the new pair.
- **Briefs in this repo have contained defects every build** (unsatisfiable or vacuous assertions, off-by-one geometry, a fixture whose natural order made the wrong answer coincide with the right one). If the code disagrees with this plan, the code wins: say so in your report with the evidence.
- Every new assertion is shown to FAIL against the pre-change code before the change (RED), except ones marked non-regression guards. Capture into a variable first: an undefined function called directly inside `t` aborts the statement silently and the suite still reports `ALL PASS`. Bound every body-grep and assert its extraction is non-empty. Ask of every fixture: would a plausible wrong implementation land on the same row or value?
- Mutation checks use full-tree scratch copies (`cp -a` of the repo into the scratchpad), never `git checkout`/`git stash` on the working tree, and the copy is re-taken immediately before each mutation.
- Code comments are brief: what a reader needs now. History, dates and measurements go in the commit message. American spelling in new comments and prose (color, behavior). A `--description` states the caller's contract in under ~400 characters.
- No new files in `conf.d/` or `functions/`. New functions go into the existing files, named `__tcz_*` (categorizer) or `__tmux_lives_*` / `__tmux_*` (conf.d). A function's own globals carry a two-letter owner prefix (`__tcz_pl_` for the list drawer, `__tcz_pf_` for the frame/memo).
- fish traps that return a wrong answer instead of an error (CLAUDE.md → "Traps"):
  - a zero-output command substitution collapses the whole enclosing argument: capture into a variable, use it quoted
  - `printf --` is not an option terminator
  - `string match -r` with a prefix pattern returns the matched substring
  - `"$var[...]"` in double quotes is list indexing (spell an escape via `(printf '\e[0m')` or a variable, never `"$E[0m"`)
  - never iterate `(seq (count $x))` where the count can be 0: macOS `seq 0` prints `1 0`
- New `case` labels in `__tcz_landing` are limited to `cancel`. The categorize suite extracts theme-picker arms with awk patterns keyed on exact 12-space lines (`case up down pgup pgdn`, `case left right`, `case a`, `case tab`, `case m`, `case t`, `case z`, `case b`, `case o`, `case M`); the landing loop must never contain one of those exact lines.
- Run the repo's own checks only; there is no formatter or linter for fish here.

## Rulings taken for the user (record them in the spec in Task 5)

- Within `general`, the former `running` sessions keep their place ahead of the other general sessions (the overview's order), not interleaved by recency.
- The switch-mode legend keeps the landing legend's 10-column pitch behind its badge, so `esc close` is clipped below 83 columns (the landing legend's `d detach` already clipped below ~61; the badge moves that to ~70).
- Enter on a live row goes through `__tcz_switch` in both modes (it was spelled inline in the landing loop); `--take` (`tmux-lives picker -t` inside tmux) is carried into switch mode, so taking a session over still works there.
- In switch mode Enter/`n`/`r` close the switcher even when the switch fails (the client simply stays where it was).
- `M-s` pressed on a landing tab opens the switcher over the lander; not special-cased (the abandoned landing session is swept like any clientless one).
- The stderr re-exec that the theme-picker verb does for its popup becomes one shared helper (`__tcz_quiet_exec`, marker `__tcz_quiet`, replacing `__tcz_thp_quiet`), used by both popup verbs.

## What already exists

Everything this plan changes extends code that is already there (line numbers at `8b2286e`; find by name, lines drift):

- `__tcz_landing_model` — `functions/tmux-categorize.fish:1527`: the rows the chooser lists; v3 changes their categories and order.
- `__tcz_landing_group_roots` — `functions/tmux-categorize.fish:74`: the group roots; the group rule that reads them is inline in the model today (~:1607–1611).
- `__tcz_claude_project_of` — `functions/tmux-categorize.fish:78`: folder → project folder; already used by discovery and the model's busy check.
- `__tcz_snapshot` — `functions/tmux-categorize.fish:666`: leaves each session's active-pane cwd in `__tcz_tmux_activepath_names` / `_paths` (`:739`), which the overview the model reads already computes.
- `__tcz_popup_list_lines` — `functions/tmux-categorize.fish:2039`: the list drawer (rules, rails, pointer, markers, the switcher's `❯ … [current]`).
- `__tcz_popup_list_memo` — `functions/tmux-categorize.fish:2311` and `__tcz_popup_frame` — `:2346`: the memoized list, the selected-row redraw, the window walk.
- `__tcz_landing_paint` — `functions/tmux-categorize.fish:1683`: frame, border, legend through `__tcz_popup_emit`.
- `__tcz_landing` — `functions/tmux-categorize.fish:1745`: the landing loop (settle window, burst rule, idle cadence, actions).
- `__tcz_switch` — `functions/tmux-categorize.fish:1194`: switch a client to a session, `--take` detaching the others.
- `__tcz_session_close` — `functions/tmux-categorize.fish:1298`: close a session the landing way.
- `__tcz_open_switcher` — `functions/tmux-categorize.fish:2635`, `__tcz_popup` — `:2556`, `__tcz_popup_draw` — `:2408`: the two-pane switcher this plan replaces.
- `__tcz_main` — `functions/tmux-categorize.fish:5214`: the verbs; `case theme-picker` (`:5243`) holds the stderr re-exec this plan shares.
- The switcher binds — `conf.d/tmux-lives-install.fish:59` and `:63`; `__tmux_lives_picker`'s outside-tmux legacy popup — `conf.d/tmux.fish:274`.

## New names and files

No new files (this plan document aside). New names, each because the existing code cannot hold it:

- `__tcz_landing_group_of` (function): the group rule is needed for live claude sessions too, not only idle projects; the model's inline loop would otherwise be spelled twice. It takes a list so the model makes one command substitution per refresh instead of one per row.
- `__tcz_popup_list_row` (function): the frame redraws only the selected row. v2 did that by feeding one row through `__tcz_popup_list_lines` and taking its last line; in v3 a row's line depends on the section and box around it, so one row has to be drawable on its own.
- `__tcz_pl_row`, `__tcz_pl_line`, `__tcz_pl_first` (globals, owned by `__tcz_popup_list_lines`): where each drawn row landed. The memo used to re-derive line numbers by mirroring the drawer's walk; with box rules and rail rows that mirror would be a second copy of the layout.
- `__tcz_pf_rfirst` (global, owned by the memo): replaces `__tcz_pf_wline` / `__tcz_pf_wfirst`, which were the mirrored walk.
- `__tcz_quiet_exec` (function) and `__tcz_quiet` (exported marker): the theme picker's re-exec (`__tcz_thp_quiet`) made shared, because the switcher is a second popup verb that needs it.
- The verb arguments `landing switch <client> [--take]`: switch mode of the existing `landing` verb, not a new verb.
- Test helpers `__tcp_band` (popup suite) and `__tcg_wait_detached` (categorize suite).

---

### Task 1: The model's v3 rows

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_landing_group_of` after `__tcz_landing_group_roots` (~:74); rewrite `__tcz_landing_model` (~:1527); the `case kill` guard in `__tcz_landing` (~:1912)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: model rows `target\tcategory\tmark\tlast\tdisplay` whose category is one of: `claude/<group>` (a live claude session; `<group>` from its active pane's project), `<group>` (an idle project; unchanged), `older` (display now `...older (N)`), `general` (every other live session, `running` folded in). Order: for each group in `$__tcz_landing_groups` order, that group's live claude rows (overview order) then its idle rows (newest first); then the older row; then the general rows (overview order). Live rows keep fields 3–5 exactly as v2 (mark, last_attached, display).
- Produces: `__tcz_landing_group_of <folder...>` → one group name per argument, one per line (`other` when below no group root; an empty argument → `other`).

- [ ] **Step 1: Update the existing model assertions and add the v3 ones (RED)**

In `tests/test-tmux-categorize.fish`:

1. The model test block (`# --- landing: the model (real server, real pty clients, fixture projects) ---`, ~:9976): `lmc` and `lmr` run claude in `/tmp/...` folders that map to no group, so their category becomes `claude/other`:

```fish
t "model: a live row with a client from another device -> mark 1" "lmc claude/other 1" (string split -f1,2,3 \t -- "$lmcr" | string join ' ')
...
t "model: a live row with no client -> mark 0" "lmr claude/other 0" (string split -f1,2,3 \t -- "$lmrr" | string join ' ')
```

2. `__tcg_gm_shape` (~:10035) skips live rows by category; live categories are now `general` and `claude/*`:

```fish
        switch $f[2]
            case general 'claude/*'
                continue
```

3. Insert this block immediately before the line `# --- landing: the running app, driven through a real pty client ---` (~:10094):

```fish
# --- chooser v3: a live claude session sits in its project's group box, before the group's idle
# projects; running folds into general, which comes last ---
# - HOME is redirected before the server starts, so the panes' cwds sit below the fixture's group roots
# - cw runs in a repo's subfolder: its box comes from the repo (workspace), not the subfolder
# - an implementation that misses the panes' cwds puts every claude session in other, which this fixture rejects
set -l m3home /tmp/tcz-m3h-$fish_pid
set -l m3home_save $HOME
mkdir -p $m3home/projects/cp $m3home/workspace/ww/.git $m3home/workspace/ww/sub $m3home/projects/pi $m3home/workspace/wi
set -gx HOME $m3home
fresh_server
command tmux -L $sock new-session -d -s cp -c $m3home/projects/cp "$shimdir/claude --name cp"
command tmux -L $sock new-session -d -s cw -c $m3home/workspace/ww/sub "$shimdir/claude --name cw"
command tmux -L $sock new-session -d -s co -c /tmp "$shimdir/claude --name co"
command tmux -L $sock new-session -d -s rn -c /tmp 'sleep 600'
command tmux -L $sock new-session -d -s gg -c /tmp
command tmux -L $sock kill-session -t =0
sleep 0.3
set -l m3now (date +%s)
set -l m3disc (printf '%s\t%s' $m3home/projects/pi (math $m3now - 60)) \
    (printf '%s\t%s' $m3home/workspace/wi (math $m3now - 120))
set -l m3 (__tcz_landing_model x -- $m3disc)
set -gx HOME $m3home_save
set -l m3shape
for r in $m3
    set -l f (string split \t -- $r)
    set -a m3shape "$f[2]:"(path basename -- $f[1])
end
t "model v3: per group its live claude sessions (by the active pane's project) then its idle projects; then general, running folded in, last" "claude/projects:cp projects:pi claude/workspace:cw workspace:wi claude/other:co general:rn general:gg" "$m3shape"
set -l m3old (__tcz_landing_model x -- (printf '%s\t%s' /tmp/tcz-m3-stale (math $m3now - 30 \* 86400)))
t "model v3: the older row reads ...older (N)" 1 (string match -q -- 'older'\t'older'\t'0'\t'1'\t'...older (1)' $m3old; and echo 1; or echo 0)
rm -rf $m3home
cleanup
```

   Note the busy check: `pi` and `wi` are not where any claude runs, so both stay listed. If `/tmp/tcz-m3-stale` would be hidden as busy or generic, pick another fixture path and say so.

4. Insert this block immediately before `# --- landing fix round 1: the idle app emits nothing ---` (~:10356):

```fish
# x on a live claude row asks first, like any live row (its category is claude/<group> now). The claude
# section comes first, so the pointer starts on kc; the prompt names the row's target.
fresh_server
set -l pj $tmux_lives_claude_projects_dir
rm -rf $pj; rm -f $tmux_lives_project_cache
command tmux -L $sock new-session -d -s kc -c /tmp "$shimdir/claude --name kc"
set -l kx (__tcz_landing_new)
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =$kx" /dev/null >/dev/null 2>&1 &
set -l kxpids (jobs -p)
__tcg_client_on $kx >/dev/null
__tcg_ready "=$kx:" '*d detach*'
command tmux -L $sock send-keys -t "=$kx:" x
set -l kxask (__tcg_screen_has "=$kx:" '*kill kc ?*' 30; and echo 1; or echo 0)
command tmux -L $sock send-keys -t "=$kx:" n
t "app: x on a live claude row asks before killing" 1 "$kxask"
for p in $kxpids; kill $p 2>/dev/null; end
cleanup
```

- [ ] **Step 2: Run the categorize suite and confirm the new assertions fail**

Run (foreground, `timeout: 600000`): `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`
Expected: FAIL on the two `model:` lines changed in Step 1.1, `model v3: ...` (both), and `app: x on a live claude row asks before killing`. Nothing else fails.

- [ ] **Step 3: Add `__tcz_landing_group_of`**

Insert after `__tcz_landing_group_roots` (~:76):

```fish
function __tcz_landing_group_of --description 'pure: project folders (argv) -> their chooser groups, one per line: the group of the first root each is below (__tcz_landing_group_roots), else other'
    set -l roots (__tcz_landing_group_roots)
    set -l gidx (seq (count $roots))
    for folder in $argv
        set -l g other
        for i in $gidx
            string match -q -- "$roots[$i]/*" "$folder"; and set g $__tcz_landing_groups[$i]; and break
        end
        echo $g
    end
end
```

- [ ] **Step 4: Rewrite `__tcz_landing_model`**

Replace the whole function (~:1527–1619) with:

```fish
function __tcz_landing_model --argument-names self --description '__tcz_landing_model <self> [--all] [-- <discovery rows>]: rows "target\tcategory\tmark\tlast\tdisplay" for the session <self> serves (mark 2 = a client from my device is on it, 1 = some client is). Per group: its live claude sessions (claude/<group>, from the active pane'"'"'s project), then its idle projects (<group>); then "...older (N)" (--all lists them instead); then every other live session (general). "--" passes the discovery rows in.'
    set -e argv[1]
    set -l all 0
    test "$argv[1]" = --all; and set all 1; and set -e argv[1]
    set -l TAB (printf '\t')
    set -l cpids; set -l csess
    set -l me; set -l meact -1
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_session}$TAB#{client_activity}" 2>/dev/null)
        set -l f (string split -m 2 $TAB -- $line)
        test (count $f) -eq 3; or continue
        set -a cpids $f[1]; set -a csess $f[2]
        # My client: the most recently active one on my session.
        if test "$f[2]" = "$self"; and test "$f[3]" -gt $meact 2>/dev/null
            set me (count $cpids); set meact $f[3]
        end
    end
    # Sessions another client from my device is on. Clients on landing
    # sessions are skipped: those sessions are never listed.
    set -l here
    if test -n "$me"
        set -l mine (__tcz_client_device $cpids[$me])
        set -l j 0
        for pid in $cpids
            set j (math $j + 1)
            test $j -eq $me; and continue
            __tcz_is_landing $csess[$j]; and continue
            contains -- $csess[$j] $here; and continue
            set -l dev (__tcz_client_device $pid)
            test "$dev" = "$mine"; and set -a here $csess[$j]
        end
    end
    # Live rows: a claude session goes to its project's group, everything else to general.
    set -l crows; set -l grows
    for line in (__tcz_overview)
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l mark 0
        if contains -- $f[1] $here
            set mark 2
        else if contains -- $f[1] $csess
            set mark 1
        end
        if test "$f[2]" = claude
            # The overview's snapshot leaves each session's active-pane cwd in __tcz_tmux_activepath_*.
            set -l i (contains -i -- $f[1] $__tcz_tmux_activepath_names)
            set -l proj
            test -n "$i"; and set proj (__tcz_claude_project_of "$__tcz_tmux_activepath_paths[$i]")
            set -l g (__tcz_landing_group_of "$proj")
            set -a crows (printf '%s\tclaude/%s\t%s\t%s\t%s' $f[1] $g $mark $f[4] "$f[5]")
        else
            set -a grows (printf '%s\tgeneral\t%s\t%s\t%s' $f[1] $mark $f[4] "$f[5]")
        end
    end
    # A project is running when a claude pane works on it:
    # - in its folder, or anywhere in the repo or worktree that maps to it (__tcz_claude_project_of);
    # - for a project that is no git repo (~/Work/myEMS, whose api/ and web/ are repos), anywhere below it.
    set -l cwds (__tcz_claude_cwds)
    set -l busy $cwds
    for cwd in $cwds
        set -l proj (__tcz_claude_project_of $cwd)
        test -n "$proj"; and set -a busy $proj
    end
    set -l disc
    if test "$argv[1]" = --
        set disc $argv[2..]
    else
        set disc (__tcz_claude_projects)
    end
    set -l after (__tcz_landing_older_after)
    set -l now
    set -l pf; set -l pm; set -l pa           # each listed project's folder, transcript mtime and age
    set -l nold 0
    for line in $disc
        set -l f (string split -m 1 $TAB -- $line)
        test (count $f) -eq 2; or continue
        contains -- $f[1] $busy; and continue
        if not test -e "$f[1]/.git"
            set -l below 0
            for cwd in $cwds
                string match -q -- "$f[1]/*" "$cwd"; and set below 1; and break
            end
            test $below -eq 1; and continue
        end
        test -n "$now"; or set now (date +%s)
        set -l secs (math $now - $f[2])
        if test $all -eq 0; and test $secs -gt $after
            set nold (math $nold + 1)
            continue
        end
        set -a pf $f[1]; set -a pm $f[2]; set -a pa (__tcz_age $secs)
    end
    set -l pg (__tcz_landing_group_of $pf)
    set -l prows
    set -l i 0
    for folder in $pf
        set i (math $i + 1)
        set -a prows (printf '%s\t%s\t0\t%s\t%s · %s' $folder $pg[$i] $pm[$i] (path basename -- $folder) $pa[$i])
    end
    # The claude section, group by group; within one, discovery's newest-first order holds.
    for g in $__tcz_landing_groups
        string match -- "*$TAB"claude/"$g$TAB*" $crows
        string match -- "*$TAB$g$TAB*" $prows
    end
    test $nold -gt 0; and printf 'older\tolder\t0\t%s\t...older (%s)\n' $nold $nold
    for r in $grows
        printf '%s\n' $r
    end
end
```

- [ ] **Step 5: The kill guard accepts every live row**

In `__tcz_landing`'s `case kill` arm (~:1912), replace

```fish
                contains -- $row[2] claude running general; or continue
```

with

```fish
                # Live rows only: a project or the older row has no session to kill.
                test -n "$row[1]"; and not contains -- "$row[2]" $__tcz_landing_groups older; or continue
```

- [ ] **Step 6: Fix the e2e fallout of the new order and the older row's text**

Run the categorize suite again. Known fallout, fix each in the test (never in the code):
- The older-row test (`# The older row: Enter reveals the hidden projects ...`, ~:10239): `'*▐ older (1)*'` (two sites) becomes `'*▐ ...older (1)*'`.
- The same test's "after a refresh adds a row above it" step creates `zz` as a plain shell, which in v3 is general and lands BELOW the older row, so the step no longer adds a row above it. Make `zz` a claude session so it lands in the `other` box above the older row, and keep its glob: `command tmux -L $sock new-session -d -s zz -c /tmp "$shimdir/claude --name zz"` (display `zz`: a claude session's display is its `--name` when the cwd is generic). Update the test's comment to say the row is added above, in the claude section.
- Any e2e whose pointer arithmetic assumed live sessions list first must start from an empty projects fixture (`set -l pj $tmux_lives_claude_projects_dir; rm -rf $pj; rm -f $tmux_lives_project_cache`): in v3 the claude section (idle projects included) is listed before general. Report every test you changed and why.

- [ ] **Step 7: Full gate**

All 9 suites, both modes (Global Constraints). Expected: 9/9 `ALL PASS` both modes; install 960/959 unchanged.

- [ ] **Step 8: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): v3 model rows -- live claude sessions in their project's group, general last"
```

---

### Task 2: Draw the nested layout

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_popup_list_row` before `__tcz_popup_list_lines` (~:2039); rewrite `__tcz_popup_list_lines`, `__tcz_popup_list_memo` (~:2311); the list part of `__tcz_popup_frame` (~:2346)
- Test: `tests/test-tmux-popup.fish` (the list section ~:86–170 and the memo section ~:256–329); `tests/test-tmux-categorize.fish` (the switcher-yellow guard ~:5242)

**Interfaces:**
- Consumes (Task 1): the v3 categories.
- Produces: `__tcz_popup_list_row <listwidth> <sel> <current> <row>` → one line, exactly `<listwidth>` visible columns. `<sel>` = 1 draws the pointer.
- Produces: `__tcz_popup_list_lines <listwidth> <selidx> <current>` (rows on stdin) → the list's lines, and as a side effect the globals `__tcz_pl_row` (each drawn row), `__tcz_pl_line` (its 1-based line) and `__tcz_pl_first` (the first line a window must show with it). Rows with fewer than 5 fields are skipped and get no entry; `<selidx>` counts drawn rows.
- Produces: the memo's globals `__tcz_pf_left`, `__tcz_pf_rrow`, `__tcz_pf_rline`, `__tcz_pf_rfirst`, `__tcz_pf_lkey`. `__tcz_pf_wline` and `__tcz_pf_wfirst` are gone.

**Geometry (0-based columns, list width `w`; from `gen.py` → `e1_list`):**
- Section rule: `╭── <word> ` then `─` to the end, bold, orange 208 (claude) or green 2 (general). Byte-identical to v2's rule.
- Box rule (claude section): col 0 the orange rail `│`; col 1 blank; cols 2..w-3 a bold rule (gold 178; gray 8 for `older`) with ` <name> ` centered (left fill `floor((span - len) / 2)`, span = w-4; `older` has no word); col w-2 `╮`; col w-1 blank.
- Boxed row: col 0 the orange rail (or the pointer / `❯`); col 1 blank; cols 2..w-4 the text, marker flush right ending at col w-4; col w-3 blank; col w-2 the box's rail `│` (178, or 8 for `older`); col w-1 blank. The selection band covers cols 0..w-3 only.
- Rail row, one after each box's last member: col 0 orange `│`, blanks, col w-2 the box's `│`, col w-1 blank. No corner, no bottom border anywhere.
- General row: col 0 green rail (or pointer); col 1 blank; text from col 2, marker flush right ending at col w-1; band across the whole width (as v2).
- Pointer `▐` in its section's color (208 anywhere in claude, `older` included; 2 in general). Current session off the pointer: yellow 179 `❯` in the rail cell, yellow name, yellow `[current]`; under the pointer: `▐`, yellow name, dim `[current]`.
- Text: live rows default color; idle projects name in 247 and ` · <age>` in 243; the older row in 8.

- [ ] **Step 1: Replace the v2 list tests with v3 ones (RED)**

In `tests/test-tmux-popup.fish`, replace everything from the header `# __tcz_popup_list_lines — full-width rules + flush-right markers + pointer` (~:86) through the end of the `LOLDN` assertion (~:170) with:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_list_lines (v3): the claude section (an orange rail beside a gold box per
# directory and the gray older box), then general; every line exactly listwidth columns
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
set -g FX (printf 'cp\tclaude/projects\t2\t0\tcp · task') \
    (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf 'cw\tclaude/workspace\t1\t0\tcw') \
    (printf 'older\tolder\t0\t3\t...older (3)') \
    (printf 'g1\tgeneral\t0\t0\tg1') \
    (printf 'g2\tgeneral\t1\t0\tg2')
# Lines: [1] claude rule [2] projects box [3] cp [4] pi [5] rail [6] workspace box [7] cw [8] rail
# [9] older box [10] ...older (3) [11] rail [12] general rule [13] g1 [14] g2
set -g L (printf '%s\n' $FX | __tcz_popup_list_lines 40 -1 '')
set -l lw
for l in $L; set -a lw (string length --visible -- (vis "$l")); end
t "v3 list: 14 lines, every one 40 columns" "14 40" "$(count $L) $(printf '%s\n' $lw | sort -u | string join ,)"
t "v3 list: records each row's line and the first line its window keeps (its section or box rule when it opens one)" "3 4 7 10 13 14|1 4 6 9 12 14" "$__tcz_pl_line|$__tcz_pl_first"
t "v3 list: the claude rule opens the section, bold orange" 1 (string match -qr '^\e\[1;38;5;208m╭── claude ─+\e\[0m$' -- $L[1]; and echo 1; or echo 0)
set -l orail (printf '\e[38;5;208m│')
set -l rail 1
for i in (seq 2 11)
    string match -q -- "$orail*" $L[$i]; or set rail 0
end
t "v3 list: the orange rail runs down beside the whole claude section (lines 2-11)" 1 $rail
t "v3 list: a box rule: its name centered, ╮ two columns in" "│ "(string repeat -n 13 ─)" projects "(string repeat -n 13 ─)"╮ " (vis $L[2])
t "v3 list: the box rule is bold gold" 1 (string match -q -- '*1;38;5;178m*' $L[2]; and echo 1; or echo 0)
t "v3 list: the next box centers its own name" "│ "(string repeat -n 12 ─)" workspace "(string repeat -n 13 ─)"╮ " (vis $L[6])
t "v3 list: a box's rail runs one row past its last member, with no corner" "│"(string repeat -n 37 ' ')"│ " (vis $L[5])
t "v3 list: ... in gold" 1 (string match -q -- '*38;5;178m│*' $L[5]; and echo 1; or echo 0)
t "v3 list: the older box rule is wordless" "│ "(string repeat -n 36 ─)"╮ " (vis $L[9])
t "v3 list: ... and bold gray" 1 (string match -q -- '*1;38;5;8m*' $L[9]; and echo 1; or echo 0)
t "v3 list: the older row reads ...older (3) in gray, beside the gray rail" 1 (string match -q -- '*38;5;8m...older (3)*38;5;8m│*' $L[10]; and echo 1; or echo 0)
t "v3 list: the general rule opens general, bold green" 1 (string match -qr '^\e\[1;38;5;2m╭── general ─+\e\[0m$' -- $L[12]; and echo 1; or echo 0)
t "v3 list: a general row spans the list beside the green rail" 1 (string match -qr '^│ g1 +$' -- (vis $L[13]); and string match -q -- (printf '\e[38;5;2m│')'*' $L[13]; and echo 1; or echo 0)
t "v3 list: a boxed row: the marker flush right, just before the box's rail" 1 (string match -qr '^│ cp · task +\[here\] │ $' -- (vis $L[3]); and echo 1; or echo 0)
t "v3 list: a general row's marker sits at the list's edge" 1 (string match -qr '^│ g2 +\[attached\]$' -- (vis $L[14]); and echo 1; or echo 0)
t "v3 list: an idle project is muted -- its name, then its age" 1 (string match -q -- '*38;5;247mpi*38;5;243m · 2d*' $L[4]; and echo 1; or echo 0)
set -l nobot 1
for l in $L; string match -qr '[╰╯└┘]' -- $l; and set nobot 0; end
t "v3 list: no bottom borders anywhere" 1 $nobot

# __tcp_band: the first and last visible column drawn on the selection band (__tcz_theme sel-bg)
function __tcp_band --description '"first-last" columns of argv[1] on the selection band; 0-0 when none'
    set -l on 0; set -l col 0; set -l first 0; set -l last 0
    for tok in (string match -ar '\e\[[0-9;]*m|[^\e]' -- "$argv[1]")
        if string match -qr '^\e\[' -- "$tok"
            string match -q -- '*48;2;25;25;19*' "$tok"; and set on 1
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
set -l Ls (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 '')
t "v3 list: a selected boxed row: an orange ▐, the band stops before the box's rail" "1 1-38" "$(string match -q -- '*38;5;208m▐*' $Ls[3]; and echo 1; or echo 0) $(__tcp_band $Ls[3])"
set -l Lo (printf '%s\n' $FX | __tcz_popup_list_lines 40 3 '')
t "v3 list: the older row's pointer is orange (it is in claude)" 1 (string match -q -- '*38;5;208m▐*' $Lo[10]; and echo 1; or echo 0)
set -l Lg (printf '%s\n' $FX | __tcz_popup_list_lines 40 4 '')
t "v3 list: a selected general row: a green ▐, the band spans the list" "1 1-40" "$(string match -q -- '*38;5;2m▐*' $Lg[13]; and echo 1; or echo 0) $(__tcp_band $Lg[13])"
set -l Lc (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 cw)
t "v3 list: the current session off the pointer: a yellow ❯ in the rail cell, a yellow [current] before the box's rail" 1 (string match -qr '^❯ cw +\[current\] │ $' -- (vis $Lc[7]); and string match -q -- (printf '\e[38;5;179m❯')'*' $Lc[7]; and string match -q -- (printf '*\e[38;5;179m[current]')'*' $Lc[7]; and echo 1; or echo 0)
set -l Lcs (printf '%s\n' $FX | __tcz_popup_list_lines 40 2 cw)
t "v3 list: the current session under the pointer: ▐ takes the rail cell, the name stays yellow, [current] goes dim" 1 (string match -qr '^▐ cw +\[current\] │ $' -- (vis $Lcs[7]); and string match -q -- (printf '*\e[38;5;179mcw')'*' $Lcs[7]; and string match -q -- (printf '*\e[2m[current]')'*' $Lcs[7]; and echo 1; or echo 0)
set -l lrow (__tcz_popup_list_row 40 1 '' $FX[1])
t "v3 list: the drawer draws a row as the list does (selected, boxed)" "$Ls[3]" "$lrow"
# Narrow and long: rows truncate with …, a marker that leaves the name no room is dropped, and every line keeps the width.
set -l LN (printf '%s\n' (printf 'averylongsessionname\tclaude/other\t1\t0\taverylongsessionname') (printf 'averylongsession2\tgeneral\t1\t0\taverylongsession2') | __tcz_popup_list_lines 12 0 '')
set -l lnw
for l in $LN; set -a lnw (string length --visible -- (vis "$l")); end
t "v3 list: at 12 columns every line keeps the width (6 lines)" "6 12" "$(count $LN) $(printf '%s\n' $lnw | sort -u | string join ,)"
t "v3 list: a narrow row drops its marker and truncates its name" 1 (string match -q -- '*…*' (vis $LN[3]); and not string match -q -- '*attached*' (vis $LN[3]); and echo 1; or echo 0)
set -l LL (printf 'supercalifragilistic\tclaude/projects\t1\t0\tsupercalifragilisticexpialidocious\n' | __tcz_popup_list_lines 30 -1 '')
t "v3 list: a long boxed name truncates with … and keeps its marker before the rail" "30 1" "$(string length --visible -- (vis $LL[3])) $(string match -qr '….*\[attached\] │ $' -- (vis $LL[3]); and echo 1; or echo 0)"
set -l LE (printf 'sx\tgeneral\t0\t0\tok✅done\n' | __tcz_popup_list_lines 20 0 '')
t "v3 list: a wide-character name keeps the row 20 columns" 20 (string length --visible -- (vis $LE[2]))
```

- [ ] **Step 2: Rewrite the memo-equivalence test's reference**

In the same file, replace `__tcp_frame_ref` and the `MM` fixture (~:259–298) with:

```fish
function __tcp_frame_ref --description '__tcp_frame_ref <sel> <listw> <rows> <current> -- <model lines...>'
    set -l sel $argv[1]; set -l listw $argv[2]; set -l rows $argv[3]; set -l current $argv[4]
    set -e argv[1..5]
    # The whole list with the pointer drawn in place; the window walked from its own top.
    set -l left (printf '%s\n' $argv | __tcz_popup_list_lines $listw $sel "$current")
    set -l top 0
    if test (count $left) -gt $rows
        set -l k (math "min($sel + 1, "(count $__tcz_pl_line)")")
        set -l line $__tcz_pl_line[$k]; set -l first $__tcz_pl_first[$k]
        set -q __tcp_ref_top; and set top $__tcp_ref_top
        test $first -le $top; and set top (math $first - 1)
        test $line -gt (math $top + $rows); and set top (math $line - $rows)
        set -l maxtop (math (count $left) - $rows)
        test $top -gt $maxtop; and set top $maxtop
        test $top -lt 0; and set top 0
    end
    set -g __tcp_ref_top $top
    set -l blankL (string repeat -n $listw ' ')
    for r in (seq $rows)
        set -l li (math $r + $top)
        set -l lseg $blankL
        test $li -le (count $left); and set lseg $left[$li]
        printf '%s\e[K\n' "$lseg"
    end
end
# 15 model rows, 14 drawn: junk has fewer than 5 fields and is skipped by both builds.
set -g MM (printf 'c1\tclaude/projects\t0\t0\tc1') (printf 'c2\tclaude/projects\t0\t0\tc2') \
    (printf 'c3\tclaude/workspace\t0\t0\tc3')
for i in 1 2 3 4; set -a MM (printf '/p/w%s\tworkspace\t0\t0\tw%s · 2h' $i $i); end
for i in 1 2 3; set -a MM (printf '/p/o%s\tother\t0\t0\to%s · 3d' $i $i); end
set -a MM (printf 'older\tolder\t0\t2\t...older (2)') (printf 'r1\tgeneral\t1\t0\trunning one') \
    (printf 'cur\tgeneral\t0\t0\tcur') junk (printf 'g2\tgeneral\t2\t0\tg2 with a display long enough to be cut')
```

and change the one-row-text-change line (~:318) to the new fixture's index of `w2`:

```fish
set MM[5] (printf '/p/w2\tworkspace\t0\t0\tw2 · 5h')                  # one row's text changes
```

Keep the rest of the block (the recorder wrapper, `__tcp_memo_cmp`, the sweeps, the final `t`) as it is. Its expected `"40 0 37 1 4"` still holds if the derivation is right (40 compares; 0 differing; 37 with a pointer, since sel 14 has no drawn row in 3 of the compares; scrolled; 4 builds); if the numbers you measure differ, re-derive them, say why, and prove the assertion still discriminates with one mutation: make the frame skip the selected-row redraw (the `set left[...]` line) and show `__tcp_d` goes above 0.

- [ ] **Step 3: Exempt the new drawer from the switcher-yellow guard**

In `tests/test-tmux-categorize.fish` (~:5242), the awk that strips the two legitimate users of `38;5;179` must strip the row drawer too, which now holds the current session's yellow:

```fish
set -l without179 (awk '
    /^function __tcz_popup_list_row/ {skip=1}
    /^function __tcz_popup_list_lines/ {skip=1}
    /^function __tcz_modal_legend/ {skip=1}
    skip && /^end$/ {skip=0; next}
    !skip {print}
' $plugindir/functions/tmux-categorize.fish | string collect)
```

Update the comment above it to name three legitimate uses. (It must stay green before and after this task: a non-regression guard.)

- [ ] **Step 4: Run the popup suite and confirm the v3 assertions fail**

Run: `env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish tests/test-tmux-popup.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`
Expected: FAIL on the `v3 list:` assertions (the v2 drawer has no boxes, no `__tcz_pl_*` records and no `__tcz_popup_list_row`) and on the memo test. Assertions that already hold under v2 (the claude rule, a general row) are non-regression guards; list which ones passed.

- [ ] **Step 5: Add `__tcz_popup_list_row`**

Insert before `__tcz_popup_list_lines`:

```fish
function __tcz_popup_list_row --argument-names listwidth sel current row --description 'pure: one chooser row, exactly <listwidth> columns. A general row spans the list beside the green rail; any other sits in a box of the claude section, between the orange rail and its box'"'"'s rail two columns in. <sel> = 1: the ▐ pointer in its section'"'"'s color, on a band that stops before a box'"'"'s rail. <current>: the session marked [current].'
    set -l f (string split -m 4 \t -- "$row")
    set -l name "$f[1]"; set -l cat "$f[2]"; set -l att "$f[3]"; set -l disp "$f[5]"
    # Section color (rail, pointer); a boxed row's text stops three columns short: a gap, its box's rail, a blank.
    set -l sc 208; set -l bc 178; set -l textw (math $listwidth - 5)
    if test "$cat" = general
        set sc 2; set bc ''; set textw (math $listwidth - 2)
    else if test "$cat" = older
        set bc 8
    end
    set -l iscur 0
    test -n "$current"; and test "$name" = "$current"; and set iscur 1
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
        set text (printf '\e[38;5;8m%s\e[39m' "$shown")
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
    set -l tail (printf '\e[0m')
    test -n "$bc"; and set tail (printf ' \e[0m\e[38;5;%sm│\e[0m ' $bc)
    printf '%s%s%s%s%s\n' "$lead" "$text" "$pads" "$mkpart" "$tail"
end
```

- [ ] **Step 6: Rewrite `__tcz_popup_list_lines`**

Replace the whole function with:

```fish
function __tcz_popup_list_lines --argument-names listwidth selidx current --description 'landing rows (stdin) -> the chooser list, every line <listwidth> wide: the claude section (an orange rail beside a box per directory and the older box), then general; no bottom borders. Pointer on row #<selidx> (-1: none); <current> marked. Records each drawn row, its line and the first line its window keeps in __tcz_pl_row, __tcz_pl_line and __tcz_pl_first.'
    test -n "$listwidth"; and test "$listwidth" -gt 0 2>/dev/null; or set listwidth 30
    test -n "$selidx"; or set selidx 0
    set -g __tcz_pl_row; set -g __tcz_pl_line; set -g __tcz_pl_first
    set -l gap (string repeat -n (math "max(0, $listwidth - 3)") ' ')
    set -l sect ''; set -l box ''; set -l boxc 178; set -l n 0; set -l idx 0
    while read -l row
        set -l f (string split -m 4 \t -- $row)
        test (count $f) -ge 5; or continue
        set -l rsect claude; set -l rbox (string replace -r '^claude/' '' -- $f[2])
        if test "$f[2]" = general
            set rsect general; set rbox ''
        end
        set -l first 0
        # A box ends one row past its last member: its rail, and no corner.
        if test -n "$box"; and test "$rbox" != "$box"
            printf '\e[38;5;208m│\e[0m%s\e[38;5;%sm│\e[0m \n' "$gap" $boxc
            set n (math $n + 1)
        end
        if test "$rsect" != "$sect"
            set -l c 208
            test $rsect = general; and set c 2
            set -l lead "╭── $rsect "
            set -l fill (math $listwidth - (string length -- "$lead"))
            if test $fill -gt 0
                set -l rule (string repeat -n $fill ─)
                printf '\e[1;38;5;%sm%s%s\e[0m\n' $c "$lead" "$rule"
            else
                set -l cut (__tcz_popup_truncate "$lead" $listwidth)
                printf '\e[1;38;5;%sm%s\e[0m\n' $c "$cut"
            end
            set n (math $n + 1); set first $n
        end
        if test -n "$rbox"; and test "$rbox" != "$box"
            # The box rule runs from the rail's gap to the ╮ two columns in, the name centered in it.
            set boxc 178; set -l word " $rbox "
            if test "$rbox" = older
                set boxc 8; set word ''
            end
            set -l span (math "max(0, $listwidth - 4)")
            set word (__tcz_popup_truncate "$word" $span)
            set -l wl (string length --visible -- "$word")
            set -l lh (math "floor(($span - $wl) / 2)")
            set -l lrule (string repeat -n $lh ─)
            set -l rrule (string repeat -n (math $span - $wl - $lh) ─)
            printf '\e[38;5;208m│\e[0m \e[1;38;5;%sm%s%s%s╮\e[0m \n' $boxc "$lrule" "$word" "$rrule"
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
    if test -n "$box"
        printf '\e[38;5;208m│\e[0m%s\e[38;5;%sm│\e[0m \n' "$gap" $boxc
    end
end
```

- [ ] **Step 7: The memo and the frame read the records**

Replace `__tcz_popup_list_memo` with:

```fish
function __tcz_popup_list_memo --argument-names listw current --description '__tcz_popup_list_memo <listw> <current> -- <model lines...>: the pointer-free list and where each row sits (__tcz_pf_left, __tcz_pf_rrow, __tcz_pf_rline, __tcz_pf_rfirst), rebuilt only when an input changes'
    set -e argv[1..3]                  # argv[3] is the literal '--' separator
    set -l key (string join \n -- $listw "$current" $argv | string collect)
    set -q __tcz_pf_lkey; and test "$key" = "$__tcz_pf_lkey"; and return 0
    # The list with no row selected; __tcz_popup_list_lines records where each drawn row landed.
    set -g __tcz_pf_left (printf '%s\n' $argv | __tcz_popup_list_lines $listw -1 "$current")
    set -g __tcz_pf_rrow $__tcz_pl_row
    set -g __tcz_pf_rline $__tcz_pl_line
    set -g __tcz_pf_rfirst $__tcz_pl_first
    set -g __tcz_pf_lkey "$key"
end
```

In `__tcz_popup_frame`, replace the selected-row redraw and the window walk's reads:

```fish
    if set -q __tcz_pf_rline[$si]
        set left[$__tcz_pf_rline[$si]] (__tcz_popup_list_row $listw 1 "$current" "$__tcz_pf_rrow[$si]")
    end
    # Window: the pointer moves first; the list scrolls only when the
    # selected row (with its section or box rule, when it opens one) would leave the window.
    set -l top 0
    if test (count $left) -gt $rows
        # A sel past the end walks to the last row, as a range would.
        set -l k (math "min($si, "(count $__tcz_pf_rline)")")
        set -l line $__tcz_pf_rline[$k]; set -l first $__tcz_pf_rfirst[$k]
```

(the rest of the window walk is unchanged). Check with `grep -rn '__tcz_pf_w' functions tests` that nothing reads the removed globals.

- [ ] **Step 8: Run the popup suite, then the full gate**

Popup suite first (both modes): every `v3 list:` assertion and the memo test pass. Then all 9 suites both modes. In the categorize suite, the e2e globs keyed on `▐ <name>` and `│ <name>` still hold (pointer, blank, name); fix any that do not and say which.

- [ ] **Step 9: Mutation check (report the results)**

On a full-tree scratch copy, one at a time, each must turn at least one named assertion red with the others green:
1. Draw the box rail row without the box's `│` (gap to the end instead) → `a box's rail runs one row past its last member`.
2. Move the band's reset after the box rail (`tail` = rail then reset) → `the band stops before the box's rail`.
3. Make the pointer always orange → `a selected general row: a green ▐`.
4. Record `first` as the row's own line always → `records each row's line ...`.

- [ ] **Step 10: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): draw the v3 nested layout -- claude and general, directory boxes, the older box"
```

---

### Task 3: The badge and switch mode

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_landing_paint` (~:1683); `__tcz_landing` (~:1745, whole function); add `__tcz_quiet_exec` before `__tcz_main`; `__tcz_main`'s `case theme-picker` and `case landing`
- Test: `tests/test-tmux-popup.fish` (the paint tests ~:331–373 and ~:407–445); `tests/test-tmux-categorize.fish` (a new e2e block)

**Interfaces:**
- Consumes (Task 2): `__tcz_popup_frame <sel> <listw> <prevw> <rows> <current> -- <model>` draws `<current>`'s marker.
- Produces: `__tcz_landing_paint <sel> <rows> <cols> <hold> <mode> <current> -- <model lines...>` (`<mode>` is `landing` or `switch`).
- Produces: the verb `landing [switch <client> [--take]]` → `__tcz_landing [switch <client> [--take]]`. Task 4's binds call `fish --no-config <cat> landing switch '#{client_name}'`.
- Produces: `__tcz_quiet_exec <verb argv...>`: re-execs the script once with stderr to `/dev/null` (marker `__tcz_quiet` exported), returns when already quiet.

- [ ] **Step 1: Paint tests (RED)**

In `tests/test-tmux-popup.fish`, every `__tcz_landing_paint <sel> <rows> <cols> <hold> -- ...` call gains `landing ''` after `<hold>` (the calls at ~:343, 349, 356, 363, 430, 432, 435), e.g. `__tcz_landing_paint 1 24 80 0 landing '' -- $LPM > $LPOUT`. Then add after the `paint: a move between two project rows ...` assertion's cleanup (~:373):

```fish
# --- paint: the badge, and every row of a 100x30 frame ---
functions -c __tcz_popup_preview __tcp_preview_bak
function __tcz_popup_preview; printf 'PV-%s\n' $argv[1]; end
function tmux; end
set -g BM (printf 'cp\tclaude/projects\t1\t0\tcp') (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf 'g1\tgeneral\t0\t0\tg1') (printf 'g2\tgeneral\t0\t0\tg2')
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 30 100 0 landing '' -- $BM > /dev/null
set -l bl $__tcz_pe_prev
set -l bdiv 0
for r in $bl[1..28]
    set -l v (vis "$r")
    test (string length --visible -- (string sub -l 40 -- "$v")) -eq 40; and test (string sub -s 41 -l 1 -- "$v") = '│'; and set bdiv (math $bdiv + 1)
end
t "paint 100x30: 30 rows; the list column is 40 wide with the divider at column 41 on all 28 frame rows" "30 28" "$(count $bl) $bdiv"
t "paint: the landing legend opens with an orange LANDING badge" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;208m LANDING \e[0m')'*' $bl[30]; and echo 1; or echo 0) $(string match -q -- ' LANDING  ↑↓ move*' (vis $bl[30]); and echo 1; or echo 0)"
t "paint: no esc close on the landing" 0 (string match -q -- '*esc close*' (vis $bl[30]); and echo 1; or echo 0)
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 2 30 100 0 switch g1 -- $BM > /dev/null
set -l sl $__tcz_pe_prev
t "paint: the switcher's legend opens with a teal SWITCHING badge and ends with esc close" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;37m SWITCHING \e[0m')'*' $sl[30]; and echo 1; or echo 0) $(string match -q -- ' SWITCHING  ↑↓ move*esc close*' (vis $sl[30]); and echo 1; or echo 0)"
t "paint: the switcher marks the current session" 1 (string match -q -- '*▐ g1*[current]*' (vis "$sl" | string join \n); and echo 1; or echo 0)
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
functions -e tmux __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak
```

Run the popup suite: the new paint assertions FAIL (no badge; the 7-argument call is read as the v2 signature). Measure rather than trust the arithmetic: if the list column at 100 columns is not 40 (`__tcz_popup_layout 100`), say so and use the measured width.

- [ ] **Step 2: Paint the badge and pass `<current>`**

Replace `__tcz_landing_paint` with:

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> <hold> <mode> <current> -- <model lines...>: paint the landing frame, a border, then the key legend behind its badge (LANDING; SWITCHING with esc close when <mode> is switch) through the diff emitter. <hold> = 1 while a move key is held: no capture, the preview kept. <current>: the session marked [current]. Returns 1, building nothing, when nothing shown changed.'
    set -l sel $argv[1]; set -l rows $argv[2]; set -l cols $argv[3]; set -l hold $argv[4]
    set -l mode $argv[5]; set -l current $argv[6]
    set -e argv[1..7]
    set -l model $argv
    set -l lay (__tcz_popup_layout $cols | string split ' ')
    set -l cap
    set -l f (string split -m 2 \t -- $model[(math $sel + 1)])
    if test "$hold" != 1; and test $lay[2] -gt 0; and test -n "$f[1]"; and not contains -- "$f[2]" $__tcz_landing_groups older
        set cap (tmux capture-pane -e -p -t (__tcz_session_target "$f[1]") 2>/dev/null)
    end
    # <hold> is in the key: the quiet repaint after a hold, same row, must not be skipped.
    set -l key (string join \n -- $sel $rows $cols $hold "$mode" "$current" $model $cap | string collect)
    if test "$__tcz_pe_force" != 1; and set -q __tcz_lp_key; and test "$key" = "$__tcz_lp_key"
        return 1
    end
    set -g __tcz_lp_key "$key"
    set -g __tcz_pf_keep $hold
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) "$current" -- $model)
    set -g __tcz_pf_keep 0
    # The badge says which app this is: the lander, or the switcher over a session.
    set -l badge (printf '\e[1;7;38;5;208m LANDING \e[0m')
    set -l keys '↑↓' move '⏎' open n new r resume x kill d detach
    if test "$mode" = switch
        set badge (printf '\e[1;7;38;5;37m SWITCHING \e[0m')
        set -a keys esc close
    end
    set -l legend "$badge"(__tcz_legend_row 10 $keys)
    __tcz_popup_emit $frame (__tcz_landing_border $lay[1] $lay[2] $cols) (__tcz_popup_truncate "$legend" (math $cols - 1))
end
```

Run the popup suite: all pass.

- [ ] **Step 3: The switch-mode e2e (RED)**

In `tests/test-tmux-categorize.fish`, insert immediately before `# --- landing fix round 1: the idle app emits nothing ---`:

```fish
# --- switch mode: the landing app as the switcher, run in a pane for a real client ---
# - client C sits on session a; the app runs in its own session sw, so capture-pane and send-keys reach it
# - a claude session cl lists first, so a pointer that did not start on the current session (a) cannot pass
# - general rows: a (attached, most recent), then b and sw by name
fresh_server
set -l pj $tmux_lives_claude_projects_dir
rm -rf $pj; rm -f $tmux_lives_project_cache
command tmux -L $sock new-session -d -s a -c /tmp
command tmux -L $sock new-session -d -s b -c /tmp
command tmux -L $sock new-session -d -s cl -c /tmp "$shimdir/claude --name cl"
command tmux -L $sock kill-session -t =0
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =a" /dev/null >/dev/null 2>&1 &
set -l swpids (jobs -p)
set -l swc (__tcg_client_on a)
command tmux -L $sock new-session -d -s sw -x 100 -y 30 -c /tmp fish --no-config $lcat landing switch $swc
set -l swdrawn (__tcg_screen_has "=sw:" '*SWITCHING*' 80; and echo 1; or echo 0)
set -l swscr (command tmux -L $sock capture-pane -p -t "=sw:")
set -l swcur (string match -q -- '*▐ a *[current]*' $swscr; and echo 1; or echo 0)
set -l swesc (string match -q -- '*esc close*' $swscr; and echo 1; or echo 0)
t "switch: the SWITCHING badge and esc close; the current session marked [current] with the pointer on it" "1 1 1" "$swdrawn $swesc $swcur"
# No settle window: a move and an Enter sent together right after the first paint both act (the lander would drain the Enter).
command tmux -L $sock send-keys -t "=sw:" j Enter
set -l swon ''
for i in (seq 30)
    set swon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
    test "$swon" = b; and break
    sleep 0.1
end
set -l swgone (command tmux -L $sock has-session -t =sw 2>/dev/null; and echo 0; or echo 1)
t "switch: no settle window -- j then Enter right after it opens move the client to b, and the switcher exits" "b 1" "$swon $swgone"
command tmux -L $sock new-session -d -s sw -x 100 -y 30 -c /tmp fish --no-config $lcat landing switch $swc
__tcg_screen_has "=sw:" '*SWITCHING*' 80 >/dev/null
command tmux -L $sock send-keys -t "=sw:" Escape
sleep 1
set -l sweon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
set -l swegone (command tmux -L $sock has-session -t =sw 2>/dev/null; and echo 0; or echo 1)
t "switch: Esc closes it, the client unmoved" "b 1" "$sweon $swegone"
command tmux -L $sock new-session -d -s sw -x 100 -y 30 -c /tmp fish --no-config $lcat landing switch $swc
__tcg_screen_has "=sw:" '*▐ b *[current]*' 80 >/dev/null
command tmux -L $sock send-keys -t "=sw:" x
__tcg_screen_has "=sw:" '*kill b ?*' 30 >/dev/null
command tmux -L $sock send-keys -t "=sw:" y
set -l swxon ''
for i in (seq 30)
    set swxon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
    string match -q '_landing-*' -- "$swxon"; and break
    sleep 0.1
end
set -l swxl (string match -q '_landing-*' -- "$swxon"; and echo 1; or echo 0)
set -l swxb (command tmux -L $sock has-session -t =b 2>/dev/null; and echo 0; or echo 1)
set -l swxgone (command tmux -L $sock has-session -t =sw 2>/dev/null; and echo 0; or echo 1)
t "switch: x on the current session closes it the landing way -- this client lands -- and the switcher exits" "1 1 1" "$swxl $swxb $swxgone"
for p in $swpids; kill $p 2>/dev/null; end
cleanup
```

Run the categorize suite: these four FAIL (the verb ignores `switch`: the app runs as a lander, no badge text, no `[current]`).

- [ ] **Step 4: Add `__tcz_quiet_exec` and route the verbs**

Insert before `function __tcz_main`:

```fish
function __tcz_quiet_exec --description 're-exec this verb (argv) once with its stderr to /dev/null, for the verbs that draw in a popup: fish writes its own errors past any in-process redirect, and there they would stay on screen. Returns at once when already quiet.'
    set -q __tcz_quiet; and return 0
    set -lx __tcz_quiet 1
    exec sh -c 'exec fish --no-config "$0" "$@" 2>/dev/null' $__tcz_self $argv
end
```

In `__tcz_main`, replace the `case theme-picker` arm's body and the `case landing` arm:

```fish
        case theme-picker
            __tcz_quiet_exec $argv
            __tcz_theme_picker $argv[2..]
```

```fish
        case landing
            # The landing pane's command already sends stderr nowhere; the switcher's popup does not.
            test "$argv[2]" = switch; and __tcz_quiet_exec $argv
            __tcz_landing $argv[2..]
```

Check: `grep -rn __tcz_thp_quiet functions conf.d tests` finds nothing.

- [ ] **Step 5: Switch mode in `__tcz_landing`**

Replace the whole function with this (unchanged lines are kept verbatim from the current function; the changes are the head, the paint call, the first-pass pointer, the enter/kill/d arms, the new cancel arm and the tail):

```fish
function __tcz_landing --argument-names mode client --description 'the landing app: a full-pane chooser that never exits on its own (q and Esc are no-ops; pane-died respawns a crash). `switch <client> [--take]`: the switcher, the same app in a popup over <client>'"'"'s session -- that session marked [current] under the pointer, no settle window; an action, d, q or Esc closes it.'
    set -l take ''
    contains -- --take $argv; and set take --take
    set -l current ''
    if test "$mode" = switch
        # display-popup does not expand a format after `--`: resolve the client from inside the popup.
        if test -z "$client"; or string match -q '*#{*' -- "$client"
            set client (tmux display-message -p '#{client_name}' 2>/dev/null)
        end
        set current (tmux display-message -c "$client" -p '#{session_name}' 2>/dev/null)
        test -n "$current"; or set current (tmux display-message -p '#{session_name}' 2>/dev/null)
    else
        set mode landing
        set client ''
    end
    # The session this app serves: its own landing session, or the one the switcher opened over.
    set -l self $current
    test $mode = landing; and set self (tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    set -l TAB (printf '\t')
    set -l saved (stty -g 2>/dev/null)
    stty -icanon -echo 2>/dev/null
    printf '\e[?25l\e[2J'
    set -g __tcz_pe_prev
    set -g __tcz_pe_force 1
    set -e __tcz_lp_key
    set -l model; set -l disc; set -l sel 0; set -l size ''
    set -l stale 1                    # re-snapshot on the next turn
    set -l pass 0                     # 0 = the idle-project list is due
    set -l pending ''                 # a key the held-key drain read past
    set -l hold 0                     # 1 after a move: repaint the list only until input is quiet
    set -l all                        # --all once the older row was opened: until the app restarts
    set -l shown                      # the targets listed when it was opened, to find the first revealed row
    set -l settle 1                   # only moves act until a quiet second after the first paint, 2 s at most
    test $mode = switch; and set settle 0     # the switcher opens on a keypress: nothing was typed ahead
    set -l settle_t0                  # the first paint, on __tcz_now_ms
    # Idle cadence: once idle_after seconds pass with no key, refresh every idle_refresh seconds (test
    # seams; 60 and 15). `idle` counts read timeouts in deciseconds, so it never runs ahead of the clock.
    set -l idle 0; set -l idle_after 600; set -l slow 150
    string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$tmux_lives_landing_idle_after"
    and set idle_after (math "round($tmux_lives_landing_idle_after * 10)")
    string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$tmux_lives_landing_idle_refresh"
    and set slow (math "min(255, max(1, round($tmux_lives_landing_idle_refresh * 10)))")
    while true
        # Live sessions re-snapshot every 3 s (15 s once idle) and after an action; the
        # idle-project list only every 10th pass and after an action (running
        # claude panes are still checked every pass). A move only repaints.
        if test $stale -eq 1
            __tcz_ps_flush
            __tcz_tmux_flush
            test $pass -eq 0; and set disc (__tcz_claude_projects)
            set pass (math "($pass + 1) % 10")
            # The pointer follows its row (target and category) when rows shift.
            set -l keep (string replace -r '^([^\t]*\t[^\t]*)\t.*$' '$1' -- $model[(math $sel + 1)])
            set model (__tcz_landing_model "$self" $all -- $disc)
            set -l at (contains -i -- "$keep" (string replace -r '^([^\t]*\t[^\t]*)\t.*$' '$1' -- $model))
            # The switcher opens on the current session.
            test -z "$keep"; and test -n "$current"; and set at (contains -i -- "$current" (string split -f1 \t -- $model))
            if test -n "$at"
                set sel (math $at - 1)
            else if test $sel -ge (count $model)
                set sel (math (count $model) - 1)
                test $sel -lt 0; and set sel 0          # an empty list: no row, never -1
            end
            if set -q shown[1]
                # The older row was opened: the pointer goes to the first project it revealed.
                set -l i 0
                for r in $model
                    set i (math $i + 1)
                    set -l rf (string split -m 2 \t -- $r)
                    contains -- "$rf[2]" $__tcz_landing_groups; or continue
                    contains -- "$rf[1]" $shown; and continue
                    set sel (math $i - 1)
                    break
                end
                set shown
            end
            set stale 0
        end
        set -l rows 24; set -l cols 80
        set -l sz (__tcz_tty_size); and set rows $sz[1]; and set cols $sz[2]
        if test "$rows $cols" != "$size"
            set size "$rows $cols"
            set -g __tcz_pe_force 1
        end
        __tcz_landing_paint $sel $rows $cols $hold $mode "$current" -- $model
        set -l tok $pending
        set pending ''
        if test -z "$tok"
            set -l wait 30
            test $settle -eq 1; and test -z "$settle_t0"; and set settle_t0 (__tcz_now_ms)
            if test $hold -eq 1
                set wait 2                # 0.2 s with no key ends a hold (stty counts tenths)
            else if test $settle -eq 1
                set wait 10
            else if test $idle -ge $idle_after
                set wait $slow
            end
            # readkey's Esc path leaves the tty blocking: re-arm the timeout every time.
            stty min 0 time $wait 2>/dev/null
            set tok (__tcz_popup_readkey timeout)
            if test "$tok" = timeout; and test $hold -eq 1
                # Input went quiet after a move: repaint with the preview, without a refresh.
                set hold 0
                set tok quiet
            else if test "$tok" = timeout
                set settle 0
                test $idle -lt $idle_after; and set idle (math $idle + $wait)
            else
                # Any key wakes an idle tab: refresh now (project list too), then back to 3 s.
                test $idle -ge $idle_after; and set stale 1; and set pass 0
                set idle 0
                # Keys that keep coming cannot hold the settle window open past 2 s. The clock is read
                # only here and at the first paint, never on the idle path.
                test $settle -eq 1; and test (math (__tcz_now_ms) - $settle_t0) -ge 2000; and set settle 0
            end
        end
        if not contains -- $tok timeout quiet
            # A key acts only alone. More input already pending means typed-ahead or pasted text (ShellFish
            # types `cd "<dir>"` + Enter into every new tab): drain it all, act on none. Moves are the
            # exception, in the settle window too: they never leave the landing, and do not end the window.
            stty min 0 time 0 2>/dev/null
            set -l k2
            if test "$tok" = enter
                # CR LF is one Return: an LF right behind the Enter is part of it, not a burst.
                set -l b ''
                dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
                set k2 timeout
                test -n "$b"; and set k2 other
                if test "$b" = 0a
                    stty min 0 time 0 2>/dev/null
                    set k2 (__tcz_popup_readkey timeout)
                end
            else
                set k2 (__tcz_popup_readkey timeout)
            end
            if contains -- $tok up down pgup pgdn
                # Held keys: discard queued repeats, one step per frame. A different key read past is
                # kept for the next turn, where this same check applies to it.
                while contains -- $k2 up down pgup pgdn
                    stty min 0 time 0 2>/dev/null
                    set k2 (__tcz_popup_readkey timeout)
                end
                test "$k2" = timeout; or set pending $k2
            else if test $settle -eq 1; or test "$k2" != timeout
                __tcz_tty_drain
                set tok drained
            end
        end
        contains -- $tok up down pgup pgdn; and set hold 1
        set -l n (count $model)
        set -l row (string split \t -- $model[(math $sel + 1)])
        switch $tok
            case timeout
                set stale 1
            case up
                test $sel -gt 0; and set sel (math $sel - 1)
            case down
                test $sel -lt (math $n - 1); and set sel (math $sel + 1)
            case pgup
                set sel (math "max(0, $sel - max(1, $rows - 3))")
            case pgdn
                test $n -gt 0; and set sel (math "min($n - 1, $sel + max(1, $rows - 3))")
            case enter r n
                if test $tok = enter; and test "$row[2]" = older
                    set all --all
                    set shown (string split -f1 \t -- $model)
                    set stale 1
                    continue
                end
                set stale 1; set pass 0
                # My client: the switcher's own, or the lander's tab, read at action time.
                set -l to $client
                test -n "$to"; or set to (__tcz_landing_client "$self")
                test -n "$to"; or continue
                if test $tok = n
                    __tcz_landing_new_shell $to
                else if contains -- "$row[2]" $__tcz_landing_groups
                    set -l how continue
                    test $tok = r; and set how resume
                    __tcz_landing_start $row[1] $how $to
                else
                    test $tok = enter; and test -n "$row[1]"; or continue
                    __tcz_switch $row[1] $to $take
                end
                # The switcher closes once it acted.
                test $mode = switch; and break
                # Leave once no tab is left here. A failed move leaves this tab
                # here, and killing an attached landing session would detach it.
                set -l others (tmux list-clients -t "=$self" -F '#{client_name}' 2>/dev/null)
                test (count $others) -eq 0; and tmux kill-session -t "=$self" 2>/dev/null
            case kill
                # Live rows only: a project or the older row has no session to kill.
                test -n "$row[1]"; and not contains -- "$row[2]" $__tcz_landing_groups older; or continue
                printf '\e[%s;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' $rows "$row[1]"
                set -g __tcz_pe_force 1       # the prompt overwrote the legend
                stty min 1 time 0 2>/dev/null
                set -l ans ''
                dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read ans
                if test "$ans" = 79; or test "$ans" = 59   # y / Y
                    # Its tabs land on landing, like any closing session.
                    __tcz_session_close $row[1]
                    # The switcher's own session is gone and its client landed: nothing is left to switch.
                    test "$row[1]" = "$current"; and break
                end
                set stale 1; set pass 0
            case d
                set stale 1; set pass 0
                set -l to $client
                test -n "$to"; or set to (__tcz_landing_client "$self")
                test -n "$to"; and tmux detach-client -t $to 2>/dev/null
                test $mode = switch; and break
                # A detached client can linger in the list for a moment: leave it out.
                set -l others (tmux list-clients -t "=$self" -F '#{client_name}' 2>/dev/null | string match -v -- "$to")
                test (count $others) -eq 0; and tmux kill-session -t "=$self" 2>/dev/null
            case cancel
                # q and Esc close the switcher; on the lander they do nothing.
                test $mode = switch; and break
        end
    end
    stty $saved 2>/dev/null
    printf '\e[?25h'
end
```

Diff the result against the pre-task function (`git diff`): every line outside the changed regions listed above must be unchanged. If the current function differs from what this step reproduces (a later fix), the current code wins: apply only the listed changes to it, and say so.

- [ ] **Step 6: Run, then the full gate**

Categorize suite: the four `switch:` assertions pass, and every existing `app:` and `typeahead:` assertion still passes (the landing path must be unchanged). Then all 9 suites, both modes. The theme picker's stray-output test (`theme picker: a fish error in its loop never reaches the screen`) exercises `__tcz_quiet_exec` for the theme picker and must stay green.

- [ ] **Step 7: Mutation check (report the results)**

On a scratch copy, one at a time:
1. Drop the first-pass `test -z "$keep"; ... set at ...` line → `the current session marked [current] with the pointer on it` fails.
2. Leave `settle` at 1 in switch mode → `no settle window` fails.
3. Remove `test "$row[1]" = "$current"; and break` → `x on the current session ... the switcher exits` fails.
4. Remove the `case cancel` arm → `Esc closes it` fails.

- [ ] **Step 8: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): the SWITCHING/LANDING badge and switch mode -- the landing app as the switcher"
```

---

### Task 4: Open the switcher as the landing app; remove the two-pane switcher

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — the two switcher binds in `__tmux_lives_render_fragment` (~:58–64)
- Modify: `functions/tmux-categorize.fish` — `__tcz_open_switcher` (~:2635); delete `__tcz_popup` (~:2556–2633) and `__tcz_popup_draw` (~:2408–2418); `__tcz_main` (`case popup`, the usage string); the file's header comment (line 5); `__tcz_popup_readkey`'s comment (~:2201–2204)
- Modify: `conf.d/tmux.fish` — `__tmux_lives_picker`'s outside-tmux legacy popup (~:274)
- Test: `tests/test-tmux-install.fish` (~:143–153), `tests/test-tmux-auto.fish` (~:961–970), `tests/test-tmux-categorize.fish` (~:2111–2138, ~:5136–5143, ~:5204–5210, ~:6626–6633, ~:7424–7431, ~:7660–7668, ~:8063–8066, ~:8380–8394, the switcher resize e2e ~:11300–11326, a new bind e2e before ~:11136), `tests/test-tmux-popup.fish` (~:216–245, ~:375–405, ~:486–496)

**Interfaces:**
- Consumes (Task 3): `fish --no-config <cat> landing switch <client> [--take]`.
- Produces: the fragment's `prefix S` / `M-s` binds and `__tcz_open_switcher` open `display-popup -B -E -w 100% -h 100% -- fish --no-config <cat> landing switch <client>`; `tmux-lives picker` outside tmux on the legacy path does the same with client `''` and `--take` when asked.

- [ ] **Step 1: Retarget the tests (RED)**

1. `tests/test-tmux-install.fish` ~:144: replace the vacuous `"fragment binds S to popup subcommand"` assertion (its glob matches any second display-popup line) with:

```fish
t "fragment: both switcher keys open the landing app in switch mode, full screen and borderless" 2 (string split \n -- "$frag" | string match -- "*bind-key*display-popup -B -E -w 100% -h 100% -- fish --no-config /X/cat.fish landing switch '#{client_name}'" | count)
t "fragment: the two-pane popup switcher is gone" 0 (string match -q -- '*-w 80% -h 70%*' "$frag"; and echo 1; or echo 0)
```

   The install counts become 961 plain / 960 `--no-config`; report what you measure.

2. `tests/test-tmux-auto.fish` ~:967 and ~:970: `*popup '' --take` becomes `*landing switch '' --take` in both globs. After the `p_off` assertion (~:961) add:

```fish
t "picker outside tmux (landing off): the legacy popup opens switch mode" 1 (string match -q -- "*display-popup -B -E -w 100% -h 100% -- fish --no-config * landing switch ''" "$p_off"; and echo 1; or echo 0)
```

   (`$p_off` is the `|`-joined argv the recorder saw; check how the `run-shell -b` argument appears in it and adjust the glob to that shape, keeping it specific.)

3. `tests/test-tmux-categorize.fish`:
   - ~:2125–2130, the open-switcher shim tests:

```fish
t "open-switcher uses display-popup" yes (string match -q '*display-popup*' -- "$sw_out"; and echo yes; or echo no)
t "open-switcher opens the landing app in switch mode, full screen and borderless" yes (string match -q '*|display-popup|-B|-E|-w|100%|-h|100%|--|fish|--no-config|*|landing|switch|c1' -- "$sw_out"; and echo yes; or echo no)
...
t "open-switcher threads --take (separate token)" yes (string match -q '*|landing|switch|c1|--take' -- "$sw_take"; and echo yes; or echo no)
```

     (the shim prints `TMUX` then `|arg` per argument, one line; if your glob needs its exact tail, measure `$sw_out`.)
   - ~:2136: `t "dispatcher has popup case" yes ...` becomes a behavioral check that the verb is gone:

```fish
t "dispatcher: the two-pane popup verb is gone (usage, rc 1)" 1 (fish --no-config $plugindir/functions/tmux-categorize.fish popup >/dev/null 2>&1; echo $status)
```

   - The readkey-token guards that read `functions __tcz_popup` (~:5142 `switcher_body`, ~:5208 `POPBODY`) would read an empty body once the function is gone and pass vacuously. Point them at the switcher's new home, with a non-empty guard:

```fish
set -l switcher_body (functions __tcz_landing | string collect)
t "switcher (the landing loop) body is non-empty" 1 (test -n "$switcher_body"; and echo 1; or echo 0)
t "switcher has no case c (readkey's c token is a safe no-op there)" 0 (string match -qr 'case c\b' -- "$switcher_body"; and echo 1; or echo 0)
```

```fish
set -g POPBODY (functions __tcz_landing | string collect)
```

     and update the comments above both to say the session switcher is the landing loop now. The `case t` guard (~:7429) reads `$POPBODY` and follows automatically.
   - ~:6626–6633: delete the two `wiring: the session switcher ...` assertions and their comment (the switcher no longer has its own painter; it paints through the emitter like the lander).
   - The awk comments at ~:7660–7665, ~:8063–8065 and ~:8380–8386 explain that `__tcz_popup` has an earlier `case enter` / `case cancel`. Reword them: the landing loop now has its own earlier `case cancel` (switch mode), which is why the extractions still start only after the theme picker's unique `case a`. Do not change the awk programs.
   - The switcher resize e2e (`# (c) The session switcher: the same shrink ...`, ~:11300): run the landing app in switch mode instead of the popup verb. Replace `fish --no-config $lcat popup` with `fish --no-config $lcat landing switch ''`, the two `'*esc close*'` readiness globs with `'*SWITCHING*'`, and the legend check with the badge (at 80 columns `esc close` is clipped — a ruling of this plan):

```fish
set -l swlast (string match -qr '^ SWITCHING  ↑↓ move ' -- "$sws[30]"; and echo 1; or echo 0)
```

     Keep its other assertions (rule on row 1, divider at column 34, the step `sw>zz`) and update its comment: the list is `sw` (current, `[current]`, the pointer starts on it) then `zz`.
   - Insert immediately before `functions -e __tcg_kbd_client __tcg_type __tcg_where __tcg_room __tcg_at` (~:11136):

```fish
# --- the fragment's M-s bind opens switch mode in a real popup ---
# - the bind line comes from the real fragment renderer; Alt+S (ESC s) is typed on the client's own keyboard
# - j then Enter in the popup move the client from a to b (the pointer started on a; cl lists first)
# - text typed after that reaches b's shell: the popup is gone
fresh_server
set -l pj $tmux_lives_claude_projects_dir
rm -rf $pj; rm -f $tmux_lives_project_cache
command tmux -L $sock new-session -d -s a -c /tmp
command tmux -L $sock new-session -d -s b -c /tmp sh
command tmux -L $sock new-session -d -s cl -c /tmp "$shimdir/claude --name cl"
command tmux -L $sock kill-session -t =0
set -l bkconf /tmp/tcz-bk-$fish_pid.conf
fish --no-config -c 'source $argv[1]; __tmux_lives_render_fragment $argv[2] S M-s' $plugindir/conf.d/tmux-lives-install.fish $lcat \
    | string match -e 'bind-key -n M-s display-popup' | string trim > $bkconf
set -l bkn (count < $bkconf)
command tmux -L $sock source-file $bkconf
set -l bkf /tmp/tcz-bkf-$fish_pid
__tcg_kbd_client $bkf a
set -l bkpids (jobs -p)
__tcg_client_on a >/dev/null
sleep 0.5
__tcg_type $bkf '\es'
sleep 1.5
__tcg_type $bkf j
sleep 0.4
__tcg_type $bkf '\r'
set -l bkon ''
for i in (seq 30)
    set bkon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
    test "$bkon" = b; and break
    sleep 0.1
end
sleep 0.5
__tcg_type $bkf 'echo POPGONE\r'
set -l bkgone (__tcg_screen_has "=b:" '*POPGONE*' 30; and echo 1; or echo 0)
t "switch: the fragment's M-s bind opens switch mode in a popup; j and Enter move the client to b; then the keyboard reaches b (the popup is gone)" "1 b 1" "$bkn $bkon $bkgone"
for p in $bkpids; kill $p 2>/dev/null; end
rm -f $bkconf $bkf
cleanup
```

     If `__tmux_lives_render_fragment` needs more than the install file (the child prints nothing, `bkn` is 0), find what it needs and source that too; the vacuity guard is `bkn` = 1.

4. `tests/test-tmux-popup.fish`:
   - ~:216–244: `__tcz_popup_draw` is going. The two "draw ... newline" assertions become one on the emitter:

```fish
set -g __tcz_pe_prev; set -g __tcz_pe_force 1
__tcz_popup_emit (seq 8) > /tmp/tcz-emit-$fish_pid
set -g ENL (wc -l < /tmp/tcz-emit-$fish_pid | string trim)
rm -f /tmp/tcz-emit-$fish_pid
set -g __tcz_pe_prev; set -g __tcz_pe_force 1
t "emit: a whole paint puts newlines between rows only (8 rows, 7 newlines)" 7 "$ENL"
```

     and the scroll assertions call `__tcz_popup_frame` with the same arguments in place of `__tcz_popup_draw` (`set -g SCD (__tcz_popup_frame 11 20 0 8 '' -- $SCM)` etc.), renamed `frame: ...`.
   - ~:387–401: the preview-routing assertions call `__tcz_popup_frame` in place of `__tcz_popup_draw` (same arguments), renamed `frame: ...`.
   - ~:490–496: drop `rkpop`; the assertion becomes `"readkey n: the landing loop has a case for n; the theme picker has none" "1 0" "$rkg1 $rkg3"`.

Run the install, auto, categorize and popup suites: the new and changed assertions FAIL (the binds still open `popup`, the verb still exists); list them.

- [ ] **Step 2: The binds and `__tcz_open_switcher`**

`conf.d/tmux-lives-install.fish`, in `__tmux_lives_render_fragment`:

```fish
    if test -n "$pkey"
        set -a popup "    bind-key $pkey display-popup -B -E -w 100% -h 100% -- fish --no-config $cat landing switch '#{client_name}'"
        set -a menu  "    bind-key $pkey run-shell 'fish --no-config $cat menu'"
    end
    if test -n "$skey"
        set -a popup "    bind-key -n $skey display-popup -B -E -w 100% -h 100% -- fish --no-config $cat landing switch '#{client_name}'"
        set -a menu  "    bind-key -n $skey run-shell 'fish --no-config $cat menu'"
    end
```

`functions/tmux-categorize.fish`:

```fish
function __tcz_open_switcher --argument-names client --description 'open the switcher: the landing app in switch mode, full screen in a borderless popup (display-menu fallback if display-popup is unsupported)'
    if tmux list-commands 2>/dev/null | grep -q display-popup
        # Build argv as a list so --take stays a SEPARATE token (concatenating it onto
        # "$client" would deliver one bogus "client --take" arg to the popup process).
        set -l cmd fish --no-config $__tcz_self landing switch "$client"
        contains -- --take $argv; and set -a cmd --take
        tmux display-popup -B -E -w 100% -h 100% -- $cmd
    else
        __tcz_menu
    end
end
```

`conf.d/tmux.fish`, `__tmux_lives_picker`'s legacy path:

```fish
    set -l pop "tmux display-popup -B -E -w 100% -h 100% -- fish --no-config $tmux_categorize_script landing switch ''"
    test -n "$take"; and set pop "$pop $take"
```

- [ ] **Step 3: Remove the two-pane switcher**

- Delete `__tcz_popup` and `__tcz_popup_draw` (whole functions). `__tcz_popup_cleanup` is defined inside `__tcz_popup` and goes with it.
- `__tcz_main`: delete the `case popup` arm; remove `|popup` from the usage string.
- Line 5's header comment: remove `popup <client> | ` from the subcommand list.
- `__tcz_popup_readkey`'s comment (~:2201–2204): "`__tcz_popup`'s switch has no matching case for any of them" → "the landing loop's switch has no case for them".
- Then: `grep -rnw -e __tcz_popup -e __tcz_popup_draw -e __tcz_popup_cleanup -e __tcz_popup_saved functions conf.d tests` finds nothing but comments you have just reworded (the `__tcz_popup_*` helpers that remain — `_frame`, `_list_*`, `_emit`, `_readkey`, `_layout`, `_truncate`, `_clip`, `_preview` — are expected).

- [ ] **Step 4: Full gate**

All 9 suites, both modes. Expected: 9/9 `ALL PASS`; install 961/960 (or the pair you measured and explained in Step 1).

- [ ] **Step 5: Mutation check (report the results)**

On a scratch copy, one at a time:
1. Restore the old `-w 80% -h 70%` on the `M-s` bind → the install fragment assertions fail.
2. Bind `M-s` to `landing` without `switch` → the bind e2e fails (the lander's settle window drains the Enter and nothing closes).

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish conf.d/tmux.fish functions/tmux-categorize.fish tests/
git commit -m "feat(landing): M-s, prefix S and tmux-lives picker open the landing app in switch mode; remove the two-pane switcher"
```

---

### Task 5: Carry-ins and docs

**Files:**
- Modify: `tests/test-tmux-categorize.fish` (`__tcg_ready` ~:10110, the three detach-wait loops ~:11000/~:11073/~:11126, the second `tysat` ~:11048)
- Modify: `README.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-09-26-landing-session-design.md`

**Interfaces:** none (no code paths change).

- [ ] **Step 1: Test carry-ins from the settle-fix fit review**

- `__tcg_ready`'s description: "input in its first second after the first paint is drained" → "non-move input in its first second after the first paint is drained".
- Fold the three identical detach waits into one helper, defined beside `__tcg_where` and erased with it:

```fish
function __tcg_wait_detached --description 'poll (≤ 3 s) until no client is attached'
    for i in (seq 30)
        set -l cl (command tmux -L $sock list-clients -F '#{client_name}' 2>/dev/null)
        test -z "$cl"; and return 0
        sleep 0.1
    end
    return 1
end
```

   Replace each `for i in (seq 30) ... end` detach wait with `__tcg_wait_detached` and add the name to the `functions -e __tcg_kbd_client ...` line.
- Rename the second `tysat` (~:11048, a session name; the first is a 1/0 flag) to `tysp` in its two uses.
- Run the categorize suite, both modes: green.

- [ ] **Step 2: README**

Update the landing and picker text to v3 (keep the README's style: one paragraph per line):
- `tmux-lives picker` (line ~35): "open the switcher (-t takes a session over)".
- "Landing page" (~:54–58): the chooser lists `claude` then `general`: inside claude, live Claude sessions and idle projects in a box per directory (`projects`, `workspace`, `work`, `other`), live first, then the `...older (N)` box; then every other live session under general. A `LANDING` badge starts the legend. Replace "the in-session picker (`M-s`, `prefix S`) is unchanged" with: `M-s`, `prefix S` and `tmux-lives picker` inside tmux open the same app full screen as the switcher — a `SWITCHING` badge, your current session marked `[current]` with the pointer on it; Enter, `n` or `r` act and close it, `x` kills (killing your own session lands your tab), `d` detaches, `q`/`Esc` close.
- "Colored picker preview" (~:161): the legend line becomes the switcher's (`↑↓` move · `⏎` open · `n` new · `r` resume · `x` kill · `d` detach · `esc` close).

- [ ] **Step 3: Spec**

- Status line: "**Chooser v3** (approved 2026-10-05) built on branch `feat/landing-chooser-v3`, awaiting merge and `fisher update`" (the merge step fills in the sha).
- Under "## Open items", after the two existing items, add a "Rulings taken while building v3" sub-list with the six rulings from this plan's "Rulings taken for the user".
- Fix the two now-stale references: "Concepts" → "Landing app — ... built from the existing popup picker (`__tcz_popup`) renderer and key loop" → "the popup picker's renderer and key loop (the two-pane switcher, `__tcz_popup`, was removed in v3)"; "Switch mode (v3)" → "as `__tcz_popup` does today" → "as the two-pane switcher did".

- [ ] **Step 4: CLAUDE.md (budget 40,000 bytes; it is at 39,990)**

Prune before adding; measure with `wc -c CLAUDE.md` before and after, and report both numbers. Changes:
- "Command surface": the keys line says `prefix S` / `M-s` open the switcher (the landing app in switch mode).
- "The picker (theme + session)": the session switcher is the landing app now; remove "The session switcher is deliberately **out of scope** — its cursor move changes nearly every row." and any other two-pane-switcher statement; `__tcz_thp_quiet` → `__tcz_quiet_exec` (shared by both popup verbs).
- "Landing session": add the v3 facts in at most four lines — category encoding (`claude/<group>` live, `<group>` idle, `older`, `general`), `__tcz_popup_list_row` + the `__tcz_pl_*` records the memo and window read, the `landing switch <client> [--take]` verb (no settle, Esc/actions close, `x` on the current session lands the client), the badge.
- "Current state": "Chooser v3 built (merged `<sha>` — filled in at merge), awaiting `fisher update` on both machines; then the workspace-TUI sidebar."
- Prune candidates, in this order: sentences that restate a memory file (keep the `[[pointer]]`), the chooser v2 detail that v3 supersedes, the "Shipped — the rules they left behind" bullets that duplicate sections above. Never remove a standing decision or a live trap.

- [ ] **Step 5: Commit**

```bash
git add tests/test-tmux-categorize.fish README.md CLAUDE.md docs/superpowers/specs/2026-09-26-landing-session-design.md
git commit -m "docs: chooser v3 in README, CLAUDE.md and the landing spec; test carry-ins"
```

---

### Task 6: Fit review

- [ ] **Step 1:** Invoke the `fit-review` skill on the branch with base = the commit before Task 1 (the branch point: `main` at the commit that adds this plan). A fit pass that refactors is a fix wave: a scoped re-review of what it changed and the full gate (9 suites, both modes) before merging.

### After the plan (controller)

- Merge `feat/landing-chooser-v3` into `main` locally, push, fill the merge sha into the spec Status and CLAUDE.md "Current state", delete this plan file (`git rm`), commit and push.
- Republish the spec to the vault: `vault-publish --type project --project "$(cat .vault-project)" docs/superpowers/specs/2026-09-26-landing-session-design.md --title "Landing Session - Design"`, reflow the vault copy to one line per paragraph (if the publish exits 3 because the last vault copy was reflowed, diff the vault copy against the reflowed previous source; force only when that is the whole difference), and give the `obsidian://open?vault=Vault&file=Notes%2FProjects%2FTmux-lives%2FLanding%20Session%20-%20Design` link.
- Ask the user to `fisher update` on both machines and smoke-test a new ShellFish tab (the lander's v3 layout) and Alt+S inside a session (the switcher).
