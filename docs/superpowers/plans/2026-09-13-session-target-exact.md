# Exact Session Targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every tmux `-t` that names a session by NAME for a window/pane/option command resolves to exactly that session, even when another session has a WINDOW of the same name.

**Architecture:** tmux 3.3a reads a bare `claude` (and even `=claude`) as a WINDOW target first, searched in whichever session it treats as current; only the form `=name:` makes the whole string an exact SESSION match. `__tcz_session_target` becomes a pure one-liner returning `=name:` for every name (no tmux call, no id lookup), `__tcz_pane_target` is deleted and its callers use `__tcz_session_target`, and the four hand-built targets in `conf.d/tmux.fish` use the same form inline.

**Tech Stack:** fish 4.7, tmux 3.3a, the repo's own `tests/test-*.fish` gate.

**Spec:** none — bugfix. Root cause and evidence: `~/.claude/session-data/2026-09-13-tmux-lives-session.tmp` and memory `project_tmux_target_quirks.md` (FIFTH quirk). The measurements that chose `=name:` over the handoff's `$id` idea are in **Evidence** below; they supersede the handoff's fix shape.

## Evidence (measured 2026-09-13 on `tmux -L <probe> -f /dev/null`, tmux 3.3a)

Fixture: session `claude` (window `main`), session `other` whose window is named `claude`, `other` carrying `@x OTHER`. With the ambiguity triggered:

| target | show-option @x | set-option lands on | display-message | list-panes -s | capture-pane |
|---|---|---|---|---|---|
| `claude` (bare) | `OTHER` ✗ | `other` ✗ | `other` ✗ | `other` ✗ | — |
| `=claude` | — | — | — | `other` ✗ | — |
| `=claude:` | empty ✓ | `claude` ✓ | `claude` ✓ | `claude` ✓ | `claude`'s pane ✓ |
| `$id` | empty ✓ | — | `claude` ✓ | `claude` ✓ | ✓ |

- `=0:` resolves the session NAMED `0` for all five commands, where bare `0` and `=0` both hit another session. So `=name:` also replaces today's numeric `$id` lookup.
- `=my proj:` (space) works. tmux rewrites `:` in a session name to `_` and rejects `.`, so a session name never contains the target separators.
- `=nosuch:` fails cleanly (`set-option` rc 1, "no such session") — it never falls through to another session. `=cla:` does NOT prefix-match `claude`.
- Session-typed commands are NOT affected and stay as they are: `has-session`, `rename-session -t =name`, `kill-session`, `switch-client -t =name`, `list-clients -t =name` all resolved correctly.
- **Which session tmux treats as current decides whether the bare form misresolves.** With `TMUX`/`TMUX_PANE` erased, the most recently created session is current, so the collision appears when the window-collider is created LAST. With `TMUX` inherited from another server it appeared in the opposite order. Every collision fixture below therefore erases `TMUX`/`TMUX_PANE` AND runs in both creation orders, AND asserts that the fixture reproduced the ambiguity at least once — so the test can never go silently vacuous.

## Global Constraints

- **Never deploy.** No `cp` into `~/.config/fish`, no edits to `~/.tmux.conf`, no `set -U`. Commit on the branch; the user runs `fisher update`.
- **Do NOT use `$id`, and do NOT use `=name` without the trailing colon** for any option/window/pane command. `=name:` is the chosen form (Evidence).
- **Leave session-typed `=name` sites untouched**: `has-session`, `rename-session`, `kill-session`, `switch-client`, `list-clients`, `attach`.
- **Zero new files** in `conf.d/` or `functions/`. Test code goes in the existing suites.
- **No new tmux calls on the tick path.** `tests/test-tmux-tick-calls.fish` must stay green; the only permitted change there is the pinned `EXPECT_WRITES` text named in Task 1.
- **Run suites in the FOREGROUND with an explicit `timeout: 600000`.** Never wrap a suite in a shell `timeout`. **If a Bash call comes back saying it was backgrounded, do not wait for it — abandon it and re-run it in the foreground with the explicit timeout.**
- Report failures with `grep -E '^FAIL'`, never `tail -1`. `test-tmux-categorize.fish` and `test-tmux-auto.fish` print no pass count — judge them by the absence of `FAIL` lines plus the `ALL PASS` trailer.
- **Capture-first:** assign every command substitution to a variable before passing it to `t`. A `t "…" x (undefined_fn)` aborts the whole statement silently and the suite still says `ALL PASS`.
- **Never `git checkout` to revert a mutation.** Copy the file first, restore from the copy, prove byte-identity with `diff`.
- The agent Bash tool runs **zsh**: quote any argument starting with `=` (zsh expands `=word`), and a non-matching glob aborts the whole command.
- Collision fixtures create their FIRST session with `-f /dev/null` (a `-L` server otherwise loads `~/.tmux.conf`).
- Commits: conventional (`fix:`/`test:`), no attribution trailer.
- **Briefs in this repo have repeatedly contained defects. If the code disagrees with this plan, the code wins — say so in your report with the evidence.** Every new assertion must be shown FAILING against the pre-fix code before the fix is written (Step 2 of each task); report the actual RED lines verbatim.

---

### Task 1: `__tcz_session_target` returns `=name:`; `__tcz_pane_target` is removed

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_session_target` (currently `:766-781`), delete `__tcz_pane_target` (`:783-789`), its callers at `:303`, `:641`, `:1194`, the hand-built `list-panes -t "=$session"` at `:1223` (`__tcz_commandeer`), and every comment/docstring that describes the old shapes (find them with the grep in Step 5).
- Test: `tests/test-tmux-categorize.fish` — replace the `pane_target` block (currently `:1343-1359`, starts with the comment `# PANE/CAPTURE targets need a different shape`), and the two `__tcz_pane_target` calls at `:1717-1718`.
- Test: `tests/test-tmux-tick-calls.fish` — `EXPECT_WRITES` (currently `:519-525`).

**Interfaces:**
- Produces: `__tcz_session_target <name>` → prints `=<name>:`. Pure: never calls tmux, never reads the memo. Used for every option (`set-option`/`show-option`), window/pane (`list-panes`, `display-message`) and `capture-pane` target built from a session name.
- Removes: `__tcz_pane_target`. No caller may remain anywhere in `conf.d/`, `functions/`, `tests/`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-categorize.fish`, delete the whole block from the comment line `# PANE/CAPTURE targets need a different shape than option targets` through its closing `cleanup` (the `set -e pt0` / `cleanup` pair just before `# ...and the pane lookups themselves must read the RIGHT session's panes.`), and put this in its place:

```fish
# __tcz_session_target: ONE exact-session form for every -t that names a session.
# tmux 3.3a reads a bare "claude" -- and even "=claude" -- as a WINDOW target first,
# searched in whichever session it treats as current, so a session NAMED claude can
# resolve to another session's WINDOW named claude (every Claude window is). The
# trailing ":" makes the whole string the SESSION part; "=" makes it exact. Numeric
# names need no special case in this form ("=0:" is the session named 0).
set -g __tsc_called 0
function tmux; set -g __tsc_called 1; end
set -l st_word (__tcz_session_target claude)
set -l st_num (__tcz_session_target 0)
set -l st_space (__tcz_session_target 'my proj')
set -l st_dollar (__tcz_session_target '$1')
functions -e tmux
t "session_target: an ordinary name becomes an exact SESSION target" "=claude:" "$st_word"
t "session_target: a numeric name uses the same form, no id lookup" "=0:" "$st_num"
t "session_target: a name with a space survives whole" "=my proj:" "$st_space"
t "session_target: keys off the original name, not a resolved shape" '=$1:' "$st_dollar"
t "session_target: makes no tmux call" 0 "$__tsc_called"
set -e __tsc_called

# ...and end to end: a session named "claude" next to a session whose WINDOW is named
# "claude". Built in both creation orders with TMUX/TMUX_PANE erased, because which
# session tmux treats as current decides whether a bare target misresolves.
function __tsc_build --argument-names order --description 'collision fixture: session claude (window main, no display, pane prints MARK-TARGET) + session other (WINDOW named claude, display OTHER-DISPLAY, pane prints MARK-OTHER). order = target-first|target-last'
    command tmux -L $sock kill-server 2>/dev/null
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
    end
    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
    if test "$order" = target-first
        command tmux -L $sock -f /dev/null new-session -d -x 120 -y 40 -s claude -n main 'echo MARK-TARGET; exec sleep 600'
        command tmux -L $sock new-session -d -x 120 -y 40 -s other -n claude 'echo MARK-OTHER; exec sleep 600'
    else
        command tmux -L $sock -f /dev/null new-session -d -x 120 -y 40 -s other -n claude 'echo MARK-OTHER; exec sleep 600'
        command tmux -L $sock new-session -d -x 120 -y 40 -s claude -n main 'echo MARK-TARGET; exec sleep 600'
    end
    sleep 0.3
    set -l ids (command tmux -L $sock list-sessions -F '#{session_id} #{session_name}')
    set -g __tsc_tid (string match -r '^\S+(?= claude$)' -- $ids)
    set -g __tsc_oid (string match -r '^\S+(?= other$)' -- $ids)
    command tmux -L $sock set-option -t "$__tsc_oid" @tmux_lives_display OTHER-DISPLAY
end

set -q TMUX; and set -g __tsc_saved_tmux $TMUX
set -q TMUX_PANE; and set -g __tsc_saved_pane $TMUX_PANE
set -e TMUX; set -e TMUX_PANE
set -g __tsc_collides 0
for order in target-first target-last
    __tsc_build $order
    set -l built (test -n "$__tsc_tid" -a -n "$__tsc_oid"; and echo yes; or echo no)
    t "collision[$order]: fixture built both sessions" yes "$built"
    # Independent of the helper: does THIS order reproduce tmux's ambiguity at all?
    set -l bare (command tmux -L $sock show-option -qv -t claude @tmux_lives_display)
    test "$bare" = OTHER-DISPLAY; and set -g __tsc_collides 1

    set -l got (tmux show-option -qv -t (__tcz_session_target claude) @tmux_lives_display)
    t "collision[$order]: a read through the target reaches session claude, not other" "" "$got"

    tmux set-option -t (__tcz_session_target claude) @tsc_probe W 2>/dev/null
    set -l landed (command tmux -L $sock list-sessions -F '#{session_name}=#{@tsc_probe}' | string match '*=W' | string join ,)
    t "collision[$order]: a write through the target lands on session claude only" "claude=W" "$landed"

    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
    set -l snaprow (__tcz_snapshot claude)
    set -l snapname (string split -f1 \t -- "$snaprow[1]")
    t "collision[$order]: a narrowed snapshot walks session claude's own panes" claude "$snapname"

    set -l cap (__tcz_popup_preview claude 80 10 | string match -r 'MARK-[A-Z]+')
    t "collision[$order]: the picker preview captures session claude's pane" MARK-TARGET "$cap[1]"

    # categorize's claimed branch must clear a stale display on claude ITSELF. other's
    # display is emptied first, so a mis-aimed unset is a silent no-op there and the
    # stale value on claude is what survives.
    command tmux -L $sock set-option -t "$__tsc_tid" @tmux_lives_name Ext
    command tmux -L $sock set-option -t "$__tsc_tid" @tmux_lives_display STALE
    command tmux -L $sock set-option -u -t "$__tsc_oid" @tmux_lives_display
    __tcz_categorize >/dev/null 2>&1
    set -l after (command tmux -L $sock show-option -qv -t "$__tsc_tid" @tmux_lives_display)
    t "collision[$order]: categorize clears the stale display on session claude itself" "" "$after"
end
t "collision: the fixture reproduced tmux's session/window ambiguity in at least one order" 1 "$__tsc_collides"
set -q __tsc_saved_tmux; and set -gx TMUX $__tsc_saved_tmux
set -q __tsc_saved_pane; and set -gx TMUX_PANE $__tsc_saved_pane
set -e __tsc_saved_tmux __tsc_saved_pane __tsc_collides __tsc_tid __tsc_oid
functions -e __tsc_build
cleanup
```

Then, at the two lines that currently read `set -l pane0 (tmux list-panes -t (__tcz_pane_target 0) -F '#{pane_id}')` and `set -l pane1 (tmux list-panes -t (__tcz_pane_target 1) -F '#{pane_id}')`, replace `__tcz_pane_target` with `__tcz_session_target` (same arguments).

In `tests/test-tmux-tick-calls.fish`, replace the `EXPECT_WRITES` value with:

```fish
set -l EXPECT_WRITES "rename-session -t =0 -- alpha
rename-session -t =1 -- beta
set-option -t =0: @tmux_lives_claude Task Alpha
set-option -t =alpha: @tmux_auto_name alpha
set-option -t =alpha: @tmux_lives_display alpha · Task Alpha
set-option -t =beta: @tmux_auto_name beta
set-option -t =beta: @tmux_lives_display beta"
```

The two `rename-session` lines are unchanged on purpose (session-typed, already exact).

- [ ] **Step 2: Run the tests to verify they fail on the pre-fix code**

Run (foreground, `timeout: 600000`): `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`

Expected RED, at minimum: the four shape assertions (`=claude:`, `=0:`, `=my proj:`, `=$1:`), `makes no tmux call`, and — in at least one of the two orders — the read, write, snapshot and categorize collision assertions. `collision: the fixture reproduced … at least one order` must be `ok` (if it FAILs, the fixture does not trigger the bug on this host — stop and report; do not proceed with a vacuous test). If the preview assertion passes pre-fix in both orders, keep it and label it in your report as a non-regression guard rather than a discriminator. (The two retargeted `list-panes` lines at the claim-collision test still work pre-fix — `__tcz_session_target 0` returns the old `$id` shape there — so that test stays green in Step 2; that is expected.)

Run (foreground, `timeout: 600000`): `fish tests/test-tmux-tick-calls.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`

Expected RED: only `equivalence baseline: the set of option writes is byte-identical…`.

Paste the FAIL lines verbatim into your report.

- [ ] **Step 3: Implement**

Replace `__tcz_session_target` and `__tcz_pane_target` (currently `:766-789`) with exactly one function:

```fish
function __tcz_session_target --argument-names session --description 'the -t target for any option (set-option/show-option), window/pane (list-panes, display-message) or capture-pane command that names a session BY NAME: "=<name>:". tmux 3.3a reads a bare name -- and even "=name" -- as a WINDOW target first, searched in whichever session it treats as current, so a session NAMED claude resolved to another session'"'"'s WINDOW named claude (every Claude window is) and categorize wrote displays onto the wrong session. The trailing ":" makes the whole string the SESSION part of the target and "=" makes that match exact; the same form resolves a purely numeric name correctly (bare "0" and "=0" do not), and a missing session fails cleanly instead of falling through. Pure: no tmux call. Session-typed commands (has-session, rename-session, kill-session, switch-client, list-clients) take "=name" and do not need this. Residual: tmux still reads a $<digits>-shaped string as a session ID, so a session literally named "$1" is unaddressable by any form.'
    printf '=%s:\n' "$session"
end
```

Then:
- `:303` (`__tcz_tmux_pane_fetch`), `:641` (`__tcz_snapshot`), `:1194` (`__tcz_pick_general`): `__tcz_pane_target` → `__tcz_session_target`.
- `:1223` (`__tcz_commandeer`): `tmux list-panes -t "=$session" -F …` → `tmux list-panes -t (__tcz_session_target "$session") -F …`.
- Do not change any `has-session`/`rename-session`/`kill-session`/`switch-client`/`list-clients` line.

- [ ] **Step 4: Run the tests to verify they pass**

Run, each as its own foreground Bash call with `timeout: 600000`:
- `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`, no FAIL
- `fish --no-config tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → same
- `fish tests/test-tmux-tick-calls.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`
- `fish tests/test-tmux-popup.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`

If any OTHER tick-calls assertion changed (for example a pinned call count dropping because a numeric session no longer issues its own `list-sessions`), do not edit it to match: report the exact FAIL line and what the call log shows, and stop.

- [ ] **Step 5: Remove every stale description of the old shapes**

Run: `grep -rn '__tcz_pane_target' conf.d functions tests` → must print NOTHING (a leftover call in a test aborts its statement silently and the suite still passes).

Run: `grep -n 'session_target\|bare name\|bare-name\|=name\|\$id' functions/tmux-categorize.fish` and read every hit. Rewrite each comment/docstring that says option commands take a bare name, that numeric names map to `$id`, that pane commands take `=name`, or that `capture-pane` needs "the bare-name/id shape" — it must describe `=name:` instead, or be deleted if it no longer says anything. Known sites: the `__tcz_tmux_sess_index` docstring (`:244`, "never a __tcz_session_target-resolved id"), the comment above `:641` in `__tcz_snapshot`, the comment at `:881-886` in `__tcz_categorize`, the comment at `:1438-1440` in `__tcz_popup_preview`, and the comments near `:4036`, `:4158-4165`, `:4199`, `:4210`. Do NOT write the literal text of any banned shape in a way that a grep guard would match — describe it, and re-run the full categorize suite after editing comments.

Re-run the four suites from Step 4. Same expected results.

- [ ] **Step 6: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish tests/test-tmux-tick-calls.fish
git commit -m "fix(categorize): target sessions as =name: so a window name cannot capture them

A bare session name, and even =name, is read by tmux 3.3a as a WINDOW
target first. Every Claude window is named claude, so the session named
claude read and wrote another session's @tmux_lives_display. =name: is
the exact-session form for option, pane and capture commands alike, and
also resolves numeric names, so __tcz_session_target becomes pure and
__tcz_pane_target is removed."
```

---

### Task 2: the hand-built targets in `conf.d/tmux.fish`

**Files:**
- Modify: `conf.d/tmux.fish` — `__tmux_session_is_idle` (`list-panes -s -t $session`, currently `:38`), `__tmux_dispose_restored` (two `set-option -t "$s" @tmux_auto_name` lines, currently `:117` and `:123`), `__tmux_lives_close` (`set-option -t "$cur" detach-on-destroy on`, currently `:387`).
- Test: `tests/test-tmux-auto.fish` — new block directly after the `# Idle predicate` block (the one ending `t "is_idle: program session not idle" …` / `cleanup`).

**Interfaces:**
- Consumes: nothing from Task 1 at runtime. `conf.d/tmux.fish` cannot call `__tcz_session_target` (the categorizer runs as a separate script), so these sites spell the same `"=$name:"` form inline.
- Produces: no new functions.

Why this matters more than the tab title: `__tmux_session_is_idle` decides what `__tmux_prune` and `__tmux_dispose_restored` KILL. With the bare target, a busy session named `claude` is judged by another session's panes, and if that other session is an idle shell the busy one is killed.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-auto.fish`, directly after the `# Idle predicate` block's `cleanup`, add:

```fish
# ---------------------------------------------------------------------
# Session-vs-window name collision (2026-09-13). Every Claude window is named
# "claude", so a bare -t claude can resolve to ANOTHER session's window of that
# name -- and the idle check decides what prune/dispose KILL. Built in both
# creation orders with TMUX/TMUX_PANE erased, because which session tmux treats
# as current decides whether the bare form misresolves.
# ---------------------------------------------------------------------
function __tac_build --argument-names order target_cmd other_cmd --description 'session claude (window main) + session other (WINDOW named claude); an empty cmd means an idle shell pane'
    cleanup
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
    end
    set -l tc; test -n "$target_cmd"; and set tc $target_cmd
    set -l oc; test -n "$other_cmd"; and set oc $other_cmd
    if test "$order" = target-first
        command tmux -L $sock -f /dev/null new-session -d -s claude -n main $tc
        command tmux -L $sock new-session -d -s other -n claude $oc
    else
        command tmux -L $sock -f /dev/null new-session -d -s other -n claude $oc
        command tmux -L $sock new-session -d -s claude -n main $tc
    end
    sleep 0.3
end

set -q TMUX; and set -g __tac_saved_tmux $TMUX
set -q TMUX_PANE; and set -g __tac_saved_pane $TMUX_PANE
set -e TMUX; set -e TMUX_PANE
set -g __tac_collides 0
set -g __tac_rdir /tmp/test-tac-rdir-$fish_pid
mkdir -p $__tac_rdir
for order in target-first target-last
    # busy "claude", idle-shell "other"
    __tac_build $order 'sleep 1000' ''
    set -l bare (command tmux -L $sock list-panes -s -t claude -F '#{session_name}' 2>/dev/null)
    test "$bare[1]" = other; and set -g __tac_collides 1
    set -l busy (__tmux_session_is_idle claude; echo $status)
    t "collision[$order]: a busy session named claude is not idle" 1 "$busy"

    # dispose (nothing saved -> no breadcrumbs) must keep and stamp the busy one
    set -gx tmux_resurrect_dir $__tac_rdir
    __tmux_dispose_restored
    set -e tmux_resurrect_dir
    set -l kept (command tmux -L $sock has-session -t =claude 2>/dev/null; and echo yes; or echo no)
    t "collision[$order]: dispose keeps the busy session named claude" yes "$kept"

    # idle "claude", busy "other": the idle one must still read as idle
    __tac_build $order '' 'sleep 1000'
    set -l idle (__tmux_session_is_idle claude; echo $status)
    t "collision[$order]: an idle session named claude is idle" 0 "$idle"

    # both busy: dispose stamps each session with its OWN name
    __tac_build $order 'sleep 1000' 'sleep 1000'
    set -gx tmux_resurrect_dir $__tac_rdir
    __tmux_dispose_restored
    set -e tmux_resurrect_dir
    set -l stamps (command tmux -L $sock list-sessions -F '#{session_name}=#{@tmux_auto_name}' | sort | string join ,)
    t "collision[$order]: dispose stamps each busy session with its own name" "claude=claude,other=other" "$stamps"

    # close aimed at "claude" must set detach-on-destroy on claude, never on other
    __tac_build $order 'sleep 1000' 'sleep 1000'
    set -gx TMUX fake
    function __tmux_lives_current_session; echo claude; end
    __tmux_lives_close 2>/dev/null
    functions -e __tmux_lives_current_session
    set -e TMUX
    set -l gone (command tmux -L $sock has-session -t =claude 2>/dev/null; and echo yes; or echo no)
    t "collision[$order]: close kills session claude" no "$gone"
    set -l dod (command tmux -L $sock show-options -v -t other detach-on-destroy 2>/dev/null)
    t "collision[$order]: close leaves other's detach-on-destroy untouched" "" "$dod"
end
t "collision: the fixture reproduced tmux's session/window ambiguity in at least one order" 1 "$__tac_collides"
set -q __tac_saved_tmux; and set -gx TMUX $__tac_saved_tmux
set -q __tac_saved_pane; and set -gx TMUX_PANE $__tac_saved_pane
rm -rf $__tac_rdir
set -e __tac_saved_tmux __tac_saved_pane __tac_collides __tac_rdir
functions -e __tac_build
cleanup
```

Note the final `show-options -v -t other` deliberately uses a bare `other`: no window is named `other`, so it is unambiguous, and `show-options` without `-g` reports only an option set locally on that session.

- [ ] **Step 2: Run the tests to verify they fail on the pre-fix code**

Run (foreground, `timeout: 600000`): `fish tests/test-tmux-auto.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`

Expected: `collision: the fixture reproduced … at least one order` is `ok` (if it FAILs, stop and report — the fixture does not trigger the bug here). In at least one order, RED on: `a busy session named claude is not idle`, `dispose keeps the busy session named claude`, `dispose stamps each busy session with its own name`. The `close` pair runs with `TMUX=fake`; if neither order turns `close leaves other's detach-on-destroy untouched` RED, keep it and label it a non-regression guard in your report. `an idle session named claude is idle` is expected to go RED too in the colliding order (the bare form judges it by `other`'s busy pane). Pre-flight already confirmed the Step 4 grep matches exactly the four sites (`:38`, `:117`, `:123`, `:387`) on the pre-fix code. Paste the FAIL lines verbatim.

- [ ] **Step 3: Implement**

In `conf.d/tmux.fish`:

`__tmux_session_is_idle`:
```fish
function __tmux_session_is_idle --argument-names session --description 'True if every pane in the session runs only a shell'
    # "=name:" is the exact-SESSION target. A bare name is read as a WINDOW
    # target first, so a session named claude was judged by ANOTHER session's
    # window named claude -- and this verdict decides what prune/dispose kill.
    set -l panes (tmux list-panes -s -t "=$session:" -F '#{pane_current_command}' 2>/dev/null)
```
(the rest of the function unchanged)

`__tmux_dispose_restored`: both `tmux set-option -t "$s" @tmux_auto_name "$s" 2>/dev/null` lines → `tmux set-option -t "=$s:" @tmux_auto_name "$s" 2>/dev/null`.

`__tmux_lives_close`: `tmux set-option -t "$cur" detach-on-destroy on 2>/dev/null` → `tmux set-option -t "=$cur:" detach-on-destroy on 2>/dev/null`.

Leave every `kill-session`, `has-session`, `switch-client`, `attach` line as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Each as its own foreground Bash call with `timeout: 600000`:
- `fish tests/test-tmux-auto.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`
- `fish --no-config tests/test-tmux-auto.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`
- `fish tests/test-tmux-restore.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` → `ALL PASS`

Then: `grep -nE 'tmux (set-option|show-option|list-panes|display-message|capture-pane) .*-t "?\$' conf.d/tmux.fish` → must print nothing (every remaining name-built target of those commands now starts with `=`).

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux.fish tests/test-tmux-auto.fish
git commit -m "fix(prune): exact session targets in the idle check, stamps and close

__tmux_session_is_idle used a bare session name, which tmux 3.3a reads as a
WINDOW target first. A busy session named claude could be judged by another
session's idle window named claude, and prune/dispose would kill it. The
@tmux_auto_name stamps and close's detach-on-destroy had the same flaw."
```
