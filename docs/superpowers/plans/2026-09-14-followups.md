# Follow-ups (attach title, dashed names, v5 removal, test nits) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close four small open items: an unidentified client gets its tab title on attach, Claude session names containing " - " are no longer cut, the dead v5 theme engine is deleted, and two deferred test nits from the exact-session-targets branch are fixed.

**Architecture:** Four independent tasks, each its own commit. Tasks 1-2 and 4 touch `functions/tmux-categorize.fish` / its tests and `tests/test-tmux-auto.fish`; Task 3 touches `conf.d/tmux-lives-install.fish` and `tests/test-tmux-install.fish` (and any other suite that references v5 functions).

**Tech Stack:** fish 4.7, tmux 3.3a, the repo's `tests/test-*.fish` gate.

**Spec:** none — maintenance. Authority: `CLAUDE.md` "Open" list, the 2026-09-13 whole-branch review's deferred minors, and the controller's evidence below.

## Evidence (controller, 2026-09-14)

- **Attach title.** `__tcz_on_attach` (`functions/tmux-categorize.fish`, `function __tcz_on_attach`) calls `__tcz_retitle` only in its `shellfish` and `iterm2` branches. `__tcz_retitle` itself is terminal-agnostic since 2026-09-11 (it titles every attached client). So a client whose terminal is unidentifiable waits up to one `status-interval` (15 s) for a title.
- **Dashed names.** `__tcz_title_name` strips `' - .*$'` from a Claude pane title. That strip dates from the categorizer's first version (commit `c2a9729`, 2026-06-17), when Claude Code titled panes `<name> - <current task>` (the test `"✳ Tasker Editor 14 - Reword task"` pins it). Live pane titles on 2026-09-14, Claude Code 2.1.266-2.1.270, macwork + rocket, all panes including an actively-working one: `✳ HS - Bitwarden 2`, `✳ Claude - Repo 8`, `✳ myEMS - Work 3`, `✳ Pingy Android - Part 35`, `✳ Pingy - Mac 4`, `✳ Sounds 6`, `✳ Watchface 51`, `✳ TMUX Setup 34` — every title equals the session's `--name` (or the resumed session's name) with **no task suffix**. The strip now only damages names containing " - ": the `claude -c` session titled `✳ Pingy - Mac 4` displays as `pingy-mac · Pingy`.
- **v5 cluster.** In `conf.d/tmux-lives-install.fish`, every production reference to these functions is inside the cluster itself: `__tmux_lives_theme_palette` (0 prod refs), `__tmux_lives_theme_valid` (0), `__tmux_lives_theme_accents` (1, from `_palette`), `__tmux_lives_theme_curve` (1, from `_palette`), `__tmux_lives_theme_reldef` (1, from `_curve`), `__tmux_lives_theme_catalog` (2, from `_catalog_default`/`_catalog_rest`), `__tmux_lives_theme_catalog_default` (0), `__tmux_lives_theme_catalog_rest` (0). **`__tmux_lives_theme_relationships` STAYS**: it is also called by `__tmux_lives_migrate_v4`'s reset branch (~`:2442`), which old installs still run. Test references (lines): `_palette` 21, `_valid` 2, `_accents` 3, `_relationships` 7, `_curve` 26, `_reldef` 12, `_catalog` 30, `_catalog_default` 14, `_catalog_rest` 3.
- **Deferred minors (2026-09-13 review).** (a) `tests/test-tmux-auto.fish`'s close collision assertion cannot catch `=name` without the colon (the misrouted `set-option` errors, `other` stays untouched, the assertion passes). (b) `tests/test-tmux-categorize.fish`'s `__tsc_build` extracts session ids with a PCRE lookahead where the file otherwise splits on a literal separator.

## Global Constraints

- **Never deploy.** No edits under `~/.config/fish`, `~/.tmux.conf`, no `set -U`. Commit on the branch; the user runs `fisher update`.
- **Zero new files** in `conf.d/` or `functions/`.
- **No new tmux calls on the tick path;** `tests/test-tmux-tick-calls.fish` must stay green unchanged.
- **Tests first.** Every new or changed assertion is shown FAILING against the pre-fix code (or, for Task 4a, against the named mutation) before the fix; paste the FAIL lines verbatim in the report. Task 3 is a deletion — its "RED" is the inventory proof described in that task.
- **Foreground suites, explicit `timeout: 600000`,** never `run_in_background`, never a shell `timeout`. If a Bash call comes back backgrounded, abandon it and re-run in the foreground. Filter with `grep -E '^FAIL|ALL PASS|SOME FAILED'`.
- **Capture-first:** assign every command substitution to a variable before passing it to `t` (an undefined function inside `t "…" x (fn)` aborts silently and the suite still says ALL PASS).
- **Never `git checkout` to revert a mutation;** copy first, restore from the copy, prove byte-identity with `diff`.
- The Bash tool runs **zsh**: quote arguments beginning with `=`; a non-matching glob aborts the whole command; loops use zsh syntax or run via fish.
- Commits: conventional, no attribution trailer.
- **Briefs in this repo have repeatedly contained defects. If the code disagrees with the brief, the code wins — say so with evidence.**

---

### Task 1: every attaching client gets its title immediately

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_on_attach`.
- Test: `tests/test-tmux-categorize.fish` — the `# on-attach:` block near the top (currently ~`:160-195`).

**Interfaces:** none new. `__tcz_on_attach <pid> <tty> [color]` keeps its signature; colour emission stays terminal-gated (`shellfish`/`iterm2` only), baseline re-source stays `'*'`-only.

- [ ] **Step 1: Write the failing test**

Directly after the existing assertion `t "on-attach: iTerm2 does not source baseline" …` and its `command tmux -L $sock kill-server 2>/dev/null`, add:

```fish
# Every attaching client gets its title at once -- title emission is terminal-agnostic
# (__tcz_retitle), only the colour escapes are gated. An unidentifiable client used to
# wait up to one status-interval for its first title.
set -l oat /tmp/tcz-oa-title-$fish_pid
rm -f $oat; touch $oat
functions -c __tcz_session_title __tcz_oa_st_bak
function __tcz_session_title; echo "oa-title-$argv[1]"; end
function tmux
    switch "$argv[1]"
        case list-clients
            printf '999\t%s\tsOA\n' "$oat"
        case '*'
            return 0
    end
end
set -g tmux_lives_fake_environ "TERM=xterm"
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_on_attach 999 $oat ''
set -l oatitle (cat $oat | string collect)
t "on-attach: an unidentifiable client is titled immediately" yes (string match -q '*oa-title-sOA*' -- "$oatitle"; and echo yes; or echo no)
rm -f $oat; touch $oat
set -g tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_on_attach 999 $oat "#abcdef"
set -l oatitle2 (cat $oat | string collect)
t "on-attach: a ShellFish client is still titled" yes (string match -q '*oa-title-sOA*' -- "$oatitle2"; and echo yes; or echo no)
functions -e tmux
functions -e __tcz_session_title; functions -c __tcz_oa_st_bak __tcz_session_title; functions -e __tcz_oa_st_bak
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
rm -f $oat
```

(Verify `__tcz_tmux_clients`' format against the code: the retitle test near `# retitle: per-client loop` stubs `list-clients` as `pid<TAB>tty<TAB>session`; use the same. If `tmux_lives_fake_environ` is not the seam `__tcz_client_terminal` reads, use whatever the neighbouring on-attach tests use.)

- [ ] **Step 2: Run to verify it fails**

`fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` (foreground, `timeout: 600000`). Expected: FAIL on `on-attach: an unidentifiable client is titled immediately`; the ShellFish companion passes (non-regression guard).

- [ ] **Step 3: Implement**

In `__tcz_on_attach`, remove the two `__tcz_retitle` calls from the `shellfish` and `iterm2` branches and call `__tcz_retitle` once after the `switch … end`, before `return 0`. Update the function's `--description` so it no longer implies titling is ShellFish/iTerm2-only (e.g. "ShellFish/iTerm2 -> set bar/tab colour; other -> re-apply the non-ShellFish baseline; every client -> retitle"). Keep the baseline-path comment.

- [ ] **Step 4: Run to verify it passes**

`fish tests/test-tmux-categorize.fish …` and `fish --no-config tests/test-tmux-categorize.fish …` → ALL PASS, no FAIL. Also `fish tests/test-tmux-shellfish.fish …` → ALL PASS.

- [ ] **Step 5: Commit** — `fix(attach): title every attaching client, not only identified terminals`

---

### Task 2: a Claude session name containing " - " is kept whole

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_title_name` (~`:70-78`).
- Test: `tests/test-tmux-categorize.fish` — the `title:` assertions (~`:347-350`, and `:570`).

- [ ] **Step 1: Write the failing test**

Replace `t "title: task suffix dropped"    "Tasker Editor 14"  (__tcz_title_name "✳ Tasker Editor 14 - Reword task")` with:

```fish
# Claude Code once titled panes "<name> - <current task>" and this stripped the task. Current
# Claude Code (2.1.26x, measured 2026-09-14) titles a pane with the session name alone, and names
# themselves contain " - " ("Pingy - Mac 4"), so the strip only ever cut real names.
set -l tn_dash (__tcz_title_name "✳ Pingy - Mac 4")
t "title: a dash inside the name is kept" "Pingy - Mac 4" "$tn_dash"
set -l tn_dash2 (__tcz_title_name "✳ Pingy Android - Part 35")
t "title: a multi-word name with a dash is kept" "Pingy Android - Part 35" "$tn_dash2"
```

Also search the suites for any other assertion that depends on the strip: `grep -rn ' - ' tests/test-tmux-categorize.fish | grep -i 'title\|claude'` and any fixture pane title containing " - " whose expected display drops the suffix (e.g. collision/display fixtures, `__tcz_display_name` tests, `--name`-less claude fixtures). List each in the report; update only those whose expectation encodes the strip, with a one-line comment.

- [ ] **Step 2: Run to verify it fails** — both new assertions FAIL pre-fix (`got [Pingy]` / `got [Pingy Android]`).

- [ ] **Step 3: Implement** — delete the line `set t (string replace -r ' - .*$' '' -- "$t")` from `__tcz_title_name`. Leave the glyph-prefix handling and the alnum check unchanged.

- [ ] **Step 4: Run to verify it passes** — categorize suite in both fish modes → ALL PASS; `fish tests/test-tmux-tick-calls.fish …` → ALL PASS.

- [ ] **Step 5: Commit** — `fix(title): keep " - " inside a Claude session name`

---

### Task 3: delete the dead v5 theme engine

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — delete `__tmux_lives_theme_palette`, `__tmux_lives_theme_valid`, `__tmux_lives_theme_accents`, `__tmux_lives_theme_curve`, `__tmux_lives_theme_reldef`, `__tmux_lives_theme_catalog`, `__tmux_lives_theme_catalog_default`, `__tmux_lives_theme_catalog_rest`, plus any comment block that exists only to document them. **Keep `__tmux_lives_theme_relationships`** and update its `--description` to say it survives for `__tmux_lives_migrate_v4`'s reset branch (the CLI/list/picker consumers it names are gone).
- Test: every suite referencing a deleted function (mostly `tests/test-tmux-install.fish`).

- [ ] **Step 1: Prove the inventory before deleting (this task's RED)**

For each of the eight names: `grep -nw -- NAME conf.d/*.fish functions/*.fish` and show that every non-definition, non-comment hit lies inside another function on the list. Then do the same for `__tmux_lives_theme_relationships` and show a caller outside the list (`__tmux_lives_migrate_v4`). Also list every helper those eight call (`grep -o '__tmux_lives_[a-z0-9_]*'` over their bodies) and, for each helper, whether it has callers outside the eight — a helper with NO remaining caller after deletion is reported (not deleted) unless it is unambiguously v5-only by its own `--description`; then it is deleted too and listed. Check `__tmux_lives_theme_accents`' "live-tunable via @options": for each `@tmux_lives_*` option it reads, report whether anything else reads or seeds it; do not change fragment seeding in this task — list any option that becomes read-by-nothing.

Paste the proof tables in the report.

- [ ] **Step 2: Classify the tests**

For every test line referencing a deleted function, classify the enclosing test block: (A) it tests v5 behaviour only → delete the block; (B) it uses a v5 function as a fixture or oracle for a LIVE function → retarget it to a live equivalent if one obviously exists, else report it and stop (NEEDS_CONTEXT); (C) it is a source-shape guard naming the function (e.g. "no caller of _palette") → delete if it only guards v5, report if it guards something live. Put the classification table in the report. Record the pre-change pass counts of every affected suite (`test-tmux-install.fish` prints a count).

- [ ] **Step 3: Delete**

Delete the functions and the class-A/C test blocks. Run `grep -rnw -e __tmux_lives_theme_palette -e __tmux_lives_theme_valid -e __tmux_lives_theme_accents -e __tmux_lives_theme_curve -e __tmux_lives_theme_reldef -e __tmux_lives_theme_catalog -e __tmux_lives_theme_catalog_default -e __tmux_lives_theme_catalog_rest conf.d functions tests README.md` → must print nothing (comments included: a leftover call inside a test would abort silently). `CLAUDE.md` and `docs/history/` may still mention them; do not edit those.

- [ ] **Step 4: Verify**

Full gate, both modes, each mode its own foreground call with `timeout: 600000`: all 9 suites ALL PASS. Report the new `test-tmux-install.fish` counts for both modes (they will drop; the plain/`--no-config` delta must still be exactly 1) and state that the drop equals the number of assertions in the deleted blocks (show the arithmetic). Also run `fish -n conf.d/tmux-lives-install.fish` and `fish --no-config -c 'source conf.d/tmux-lives-install.fish; functions -q __tmux_lives_theme_render; and echo render-ok; functions -q __tmux_lives_theme_relationships; and echo rel-ok'`.

- [ ] **Step 5: Commit** — `refactor(theme): delete the dead v5 engine` with a body listing the deleted functions, the kept `_relationships` and why, and the test blocks removed.

---

### Task 4: two deferred test nits

**Files:**
- Test: `tests/test-tmux-auto.fish` — the `collision[$order]` loop's close pair.
- Test: `tests/test-tmux-categorize.fish` — `__tsc_build`.

- [ ] **Step 1 (4a): make the close assertion discriminate a colon-less target**

In the auto suite's collision loop, replace the close block (from `set -gx TMUX fake` through the `close leaves other's detach-on-destroy untouched` assertion) so that `kill-session` is intercepted and the option can be read on `claude` itself:

```fish
    # close aimed at "claude" must set detach-on-destroy on claude itself, never on other.
    # Intercept kill-session so claude survives long enough to read the option back.
    __tac_build $order 'sleep 1000' 'sleep 1000'
    functions -c tmux __tac_tmux_bak
    function tmux
        test "$argv[1]" = kill-session; and return 0
        command tmux -L $sock $argv
    end
    set -gx TMUX fake
    function __tmux_lives_current_session; echo claude; end
    __tmux_lives_close 2>/dev/null
    functions -e __tmux_lives_current_session
    set -e TMUX
    functions -e tmux; functions -c __tac_tmux_bak tmux; functions -e __tac_tmux_bak
    set -l dod_t (command tmux -L $sock show-options -v -t '=claude:' detach-on-destroy 2>/dev/null)
    t "collision[$order]: close sets detach-on-destroy on session claude itself" on "$dod_t"
    set -l dod (command tmux -L $sock show-options -v -t other detach-on-destroy 2>/dev/null)
    t "collision[$order]: close leaves other's detach-on-destroy untouched" "" "$dod"
```

The separate `close kills session claude` assertion moves out of the loop body's intercepted section: keep one un-intercepted close run (the existing `__tac_build … __tmux_lives_close … has-session -t =claude` → `no`) so the kill itself stays covered. Adjust so each assertion runs exactly once per order. `sock`, `__tac_build`, and the suite's `tmux` function are as defined in that file — verify.

Prove with mutations (copy → mutate → run auto suite → restore → `diff`): (i) `__tmux_lives_close`'s target changed to `"=$cur"` (no colon) → `close sets detach-on-destroy on session claude itself` FAILs; (ii) changed to bare `"$cur"` → FAILs in at least one order.

- [ ] **Step 2 (4b): split instead of lookahead**

In `__tsc_build`, replace the two `string match -r '^\S+(?= claude$)' -- $ids` / `(?= other$)` extractions with a loop over `$ids` that `string split ' '`s each line and assigns `$p[1]` when `$p[2]` is `claude` / `other`. The fixture-built assertion (`collision[$order]: fixture built both sessions`) must still pass in both orders.

- [ ] **Step 3: Verify** — auto and categorize suites, both fish modes → ALL PASS.

- [ ] **Step 4: Commit** — `test: make the close collision check see a colon-less target; split ids instead of lookahead`
