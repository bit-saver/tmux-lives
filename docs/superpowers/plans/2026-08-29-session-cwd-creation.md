# Session Cwd and Project Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the session-cwd cycle — verify the already-built pane-cwd naming half actually discriminates, then add the creation half so a session is born where you were.

**Architecture:** Two independent rules. Naming reads the active pane's cwd (built on this branch, gate-green, unverified by mutation). Creation inherits the invoking shell's cwd at the four `__tmux_lives_new` sites, with `__tcz_new_general` moving the other way and pinning `$HOME` explicitly because a commandeered springboard tab has no invoking cwd worth honouring.

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's own test harnesses (`-L` socket seam, PATH shim, `XDG_CONFIG_HOME` re-exec guard).

**Spec:** `docs/superpowers/specs/2026-08-19-project-from-pane-cwd-design.md`

## Global Constraints

- **Branch:** `feat/project-from-pane-cwd`, already merged up to `main` at `514a504`. Do not create a new branch; do not merge to `main` until every task is done and reviewed.
- **Gate:** `for t in tests/test-*.fish; fish $t; end`, then again with `fish --no-config`. **Run each mode as its own Bash call, in the FOREGROUND, with an explicit `timeout: 600000`.** Never wrap the suite in a shell `timeout` — it truncates with no trailer and reads as a false clean.
- **If a Bash call reports it was backgrounded, abandon it and re-run in the foreground.** Do not wait on it. This has stalled seven subagents on this project.
- **Capture failures with `grep -E '^FAIL'`, never `tail -1`.** `tail -1` hides which assertion fired.
- **Gate baseline as of `514a504`: 9/9 `ALL PASS` both modes, `test-tmux-install.fish` 798 plain / 797 `--no-config`.** The 1-count delta is BY DESIGN — one isolation assertion is gated on plain fish. Not a regression; do not "fix" it.
- **Every new assertion must be shown FAILING against the pre-change code before you trust it.** Briefs in this repo have repeatedly contained defective assertions — vacuous, unsatisfiable, self-contradictory, and once outright backwards. If the code disagrees with this plan, the code wins: say so in your report rather than forcing the plan's number.
- **Never `git checkout` to revert a mutation.** Restore from a file copy taken immediately before that mutation, then prove byte-identity with `diff`. A stale copy reverts everything newer than the copy, not just the mutation.
- **Describe a banned shape, never spell it.** Grep-based guards in this repo match comments and docstrings too; this project has tripped that trap nine times.
- **Never deploy.** Finished work reaches the live `~/.config/fish/` only via the user's own `fisher update`. Do not `cp` anything into `conf.d/` or `functions/`, and do not edit `~/.tmux.conf`.
- **Harness note, measured during this plan's pre-flight and load-bearing for Task 3:** `tests/test-tmux-auto.fish:27` routes bare `tmux` through a fish **function**, and its comment claims that covers "the harness AND the sourced functions". It does not reach **subprocesses** — proven directly: inside a shell with that shim, `fish --no-config -c 'tmux list-sessions'` returns the user's REAL sessions. `__tmux_categorize` shells out, so any test driving it can reach the live server. Today the one call site that does (line 251) is saved only by `TMUX=fake`, which makes the subprocess's tmux fail to connect to a socket named `fake`. That is a coincidence, not isolation. **Do not add a test to that suite which shells out to the categorizer without either stubbing it or keeping `TMUX` set to a bogus value.**
- **Sweep leaked sockets after heavy runs:** the suites leave `-L` socket files in `/tmp/tmux-1000/`. Remove ones matching `tcz-*`, `tli-*`, `test-tcz*`, `test-autotmux-*`. **Never touch `default`**, and leave `neurotest*` alone — another project's.

---

### Task 1: Prove the inherited naming coverage discriminates

The pane-cwd half was built in an interrupted session and has never been mutation-tested. The suite is green, but green proves nothing about whether the assertions would notice a regression — three separate times on this project an implementation was correct while its guard was decorative, and each was found by mutating rather than reading. This task changes no production code unless a mutation survives.

**Files:**
- Read/mutate then restore: `functions/tmux-categorize.fish`
- Modify only if a mutation survives: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a verdict the later tasks rely on — that naming from the pane cwd is genuinely covered. No new functions.

- [ ] **Step 1: Record the baseline**

Run the gate, plain fish only, and record the trailer lines:

```bash
cd ~/workspace/tmux-lives && fish -c 'for t in tests/test-*.fish; echo "=== $t"; fish $t; end' 2>&1 | grep -E '^===|^FAIL|ALL PASS'
```

Expected: 9 suites, all `ALL PASS`, `test-tmux-install.fish` at 798.

- [ ] **Step 2: Take a restore copy**

```bash
cp functions/tmux-categorize.fish /tmp/tcz-mutbase-$$.fish
```

Take a **fresh copy immediately before each mutation below**, not one copy for all four.

- [ ] **Step 3: Mutation A — `__tcz_categorize` reads the session path again**

At `functions/tmux-categorize.fish:882`, the categorize path calls `__tcz_project_name (__tcz_tmux_activepath "$cur")`. Change `__tcz_tmux_activepath` to `__tcz_tmux_sess_path` — the memo that still holds `#{session_path}`, which is exactly the pre-branch behaviour this cycle exists to reverse.

Run only the categorize suite:

```bash
cd ~/workspace/tmux-lives && fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS'
```

Expected: **FAIL**, and specifically the `cd-rename:` group at `tests/test-tmux-categorize.fish:984-993`. Record which assertions fired.

Restore and prove it:

```bash
cp /tmp/tcz-mutbase-$$.fish functions/tmux-categorize.fish && diff /tmp/tcz-mutbase-$$.fish functions/tmux-categorize.fish && echo RESTORED
```

- [ ] **Step 4: Mutation B — `__tcz_snapshot`'s own path accumulator**

Re-copy first. At `functions/tmux-categorize.fish:694`, the snapshot path calls `__tcz_project_name "$cpath[$i]"`. Change the argument to the empty string `""`, which makes every session project-less.

Run the categorize suite. Expected: **FAIL** — and note whether the failures are the snapshot/display group rather than only `cd-rename:`. If the ONLY failures are ones already caught by Mutation A, that is a coverage gap: the snapshot's own naming path is not independently pinned. Record it.

Restore and prove byte-identity.

- [ ] **Step 5: Mutation C — `__tcz_claim`'s instant rename**

Re-copy first. At `functions/tmux-categorize.fish:3596`, `__tcz_claim` calls `__tcz_project_name "$cwd"`. Change the argument to `"$HOME"`, which is on the generic-directory list, so the claim path silently stops naming anything.

Run the categorize suite. Expected: **FAIL**, including the claim assertion at `tests/test-tmux-categorize.fish:1565` ("claim: never named for the session's original (pre-cd) project"). If that assertion still passes, it passes for the wrong reason — record it.

Restore and prove byte-identity.

- [ ] **Step 6: Mutation D — `__tcz_session_title` falls back to the fixed creation dir**

Re-copy first. Inside `__tcz_session_title`, the body reads `set -l path (__tcz_tmux_activepath "$session")` with a live `display-message` fallback on the next line. Change the memo call to `__tcz_tmux_sess_path` **and** change the fallback's format from `#{pane_current_path}` to `#{session_path}` — both, so the mutation is not silently rescued by the fallback.

Run the categorize suite. Expected: **FAIL**, including the window-selection assertion at `tests/test-tmux-categorize.fish:2415`.

Restore and prove byte-identity.

- [ ] **Step 7: Close any gap a surviving mutation exposed**

For each mutation that left the suite green, write the assertion that would have caught it, in `tests/test-tmux-categorize.fish` beside the existing group for that path. Re-apply that mutation, show the new assertion FAILS, restore, show it PASSES. If all four mutations discriminated, write no test — say so and move on. **Do not add an assertion that duplicates one already firing.**

- [ ] **Step 8: Confirm the tree is clean, then commit only if Step 7 added something**

```bash
cd ~/workspace/tmux-lives && git status --porcelain
```

If Step 7 added nothing, expect empty output and commit nothing. Otherwise:

```bash
git add tests/test-tmux-categorize.fish
git commit -m "test(naming): pin the pane-cwd path a surviving mutation could reach"
```

- [ ] **Step 9: Report**

State, per mutation: what you changed, which named assertions failed, and that the restore was byte-identical. A mutation that survived is the finding; say so plainly rather than reporting four green restores as success.

---

### Task 2: `__tcz_new_general` pins `$HOME`

A fresh ShellFish tab is commandeered onto a session created here. This site passes no `-c` today, so it inherits its caller's cwd — and on the `client-attached` path that caller is a `run-shell`, measured on an isolated socket to execute at the **tmux server's** cwd. That is wherever the server happened to be started (currently this repo), so under pane-cwd naming a fresh tab would come up named `tmux-lives` until the user `cd`s.

**Files:**
- Modify: `functions/tmux-categorize.fish:1135` (inside `__tcz_new_general`)
- Test: `tests/test-tmux-categorize.fish`, in the `__tcz_pick_general` + `__tcz_commandeer` block that begins at line 1724

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `__tcz_new_general` keeps its existing contract — creates a detached session named with the smallest free `gen-N` and echoes that name. Only the created session's start directory changes.

- [ ] **Step 1: Write the failing test**

Insert immediately after the existing `t "newgen: creates smallest-free general" …` assertion at `tests/test-tmux-categorize.fish:1734`:

```fish
# Creation cwd: a commandeered springboard tab has no invoking cwd worth
# honouring, so this site pins the home directory explicitly rather than
# inheriting its caller's. On the client-attached path that caller is a
# run-shell, which executes at the tmux SERVER's cwd -- an artifact of
# wherever the server was started, and under pane-cwd naming it would
# surface as a spurious project name on a brand-new tab.
set -l ngdir /tmp/tcz-ngcwd-$fish_pid
mkdir -p $ngdir
set -l ng_saved $PWD
cd $ngdir
set -l ng_name (__tcz_new_general)
cd $ng_saved
t "newgen: born in \$HOME, not the caller's cwd" "$HOME" \
    (tmux list-panes -t "=$ng_name" -F '#{pane_start_path}' 2>/dev/null)
tmux kill-session -t "=$ng_name" 2>/dev/null
rm -rf $ngdir
```

The `cd` is reverted on the very next line because `$plugindir` and other paths in this suite are resolved relative to the run directory. `tmux` here is the suite's PATH shim, so it reaches the isolated socket.

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/workspace/tmux-lives && fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS'
```

Expected: `FAIL - newgen: born in $HOME, not the caller's cwd: expected [/home/bitsaver] got [/tmp/tcz-ngcwd-<pid>]`. If it passes here, the assertion is not discriminating — stop and report rather than proceeding.

- [ ] **Step 3: Make the change**

At `functions/tmux-categorize.fish:1135`, the line reads:

```fish
    tmux new-session -d -s "$name" 2>/dev/null; and echo $name
```

Change it to:

```fish
    tmux new-session -d -c "$HOME" -s "$name" 2>/dev/null; and echo $name
```

Extend the function's description to say why, in the same voice as its neighbours: that the home directory is pinned deliberately because the caller's cwd here is a `run-shell` at the server's cwd, not anywhere the user chose.

- [ ] **Step 4: Run it and watch it pass**

```bash
cd ~/workspace/tmux-lives && fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS'
```

Expected: `ALL PASS`.

- [ ] **Step 5: Run the full gate, both modes, foreground, explicit timeout**

Two separate Bash calls:

```bash
cd ~/workspace/tmux-lives && fish -c 'for t in tests/test-*.fish; echo "=== $t"; fish $t; end' 2>&1 | grep -E '^===|^FAIL|ALL PASS'
```

```bash
cd ~/workspace/tmux-lives && fish --no-config -c 'for t in tests/test-*.fish; echo "=== $t"; fish --no-config $t; end' 2>&1 | grep -E '^===|^FAIL|ALL PASS'
```

Expected: 9/9 `ALL PASS` both modes, install 798 / 797.

- [ ] **Step 6: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "fix(naming): a commandeered tab is born at home, not at the server's cwd"
```

---

### Task 3: `__tmux_lives_new` inherits the invoking cwd

Four sites force `$HOME`. `tmux-lives new` issued from a project pane should be born in that project. Two of the four are in-tmux and drivable; two `exec` and are not, so they get a source-shape assertion that says plainly what it does and does not prove.

**Files:**
- Modify: `conf.d/tmux.fish:225`, `:233`, `:245`, `:247` (all inside `__tmux_lives_new`)
- Test: `tests/test-tmux-auto.fish`, in the `new:` block that begins at line 243

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: `__tmux_lives_new [name]` keeps its contract — errors rc1 on an existing name, creates and switches inside tmux, execs outside. Only the created session's start directory changes.

- [ ] **Step 1: Write the failing tests**

Insert after the existing no-name assertion at `tests/test-tmux-auto.fish:252` (`t "new: no-name inside tmux creates a session" …`), before the `set -e TMUX` that closes that block:

```fish
# Creation cwd: a session is born where you were. Both in-tmux branches
# inherit the invoking shell's cwd instead of forcing the home directory,
# so `tmux-lives new` from a project pane starts in that project.
set -l ncdir /tmp/tl-newcwd-$fish_pid
mkdir -p $ncdir
set -l nc_saved $PWD
set -l nc_before (tmux list-sessions -F '#{session_name}' 2>/dev/null)
# The no-name branch calls __tmux_categorize, which SHELLS OUT -- and this
# suite's tmux shim is a fish function, which does not reach a subprocess.
# Today that is saved only by the bogus TMUX set above making the subprocess's
# tmux fail to connect at all. Stub it rather than lean on that coincidence:
# the assertion below is about the birth directory, not about categorizing.
functions -c __tmux_categorize __tl_cwd_cat_bak
function __tmux_categorize; end
cd $ncdir
__tmux_lives_new proj 2>/dev/null
__tmux_lives_new 2>/dev/null
cd $nc_saved
functions -e __tmux_categorize; functions -c __tl_cwd_cat_bak __tmux_categorize
t "new: a named session is born in the invoking cwd" "$ncdir" \
    (tmux list-panes -t =proj -F '#{pane_start_path}' 2>/dev/null)
set -l nc_created
for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
    test "$s" = proj; and continue
    contains -- $s $nc_before; or set nc_created $s
end
t "new: the no-name session is born in the invoking cwd" "$ncdir" \
    (tmux list-panes -t "=$nc_created" -F '#{pane_start_path}' 2>/dev/null)
rm -rf $ncdir
```

Then, after that block's `cleanup`, add the structural assertions covering all four sites including the two that `exec`:

```fish
# The two outside-tmux branches replace the process, so they cannot be driven
# the way the two above are. This asserts their argument construction instead
# -- weaker on purpose, and stated as such: it proves the source no longer
# forces a directory, not that a session lands anywhere.
#
# Whole-line comments are stripped, trailing ones deliberately are NOT: one of
# these call sites carries a tmux format in single quotes whose first character
# is the same one that starts a fish comment, and stripping to end-of-line
# would swallow that entire line out of the count.
set -l nl_src (awk '/^function __tmux_lives_new/,/^end$/' $plugindir/conf.d/tmux.fish | string replace -r '^\s*#.*$' '')
t "new: the body extraction is non-empty (this guard is not vacuous)" "yes" \
    (test (count $nl_src) -gt 10; and echo yes; or echo no)
t "new: all four creation sites are still present" "4" \
    (printf '%s\n' $nl_src | grep -c 'new-session')
t "new: no creation site forces a fixed directory" "0" \
    (printf '%s\n' $nl_src | grep 'new-session' | grep -c 'HOME')
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd ~/workspace/tmux-lives && fish tests/test-tmux-auto.fish 2>&1 | grep -E '^FAIL|ALL PASS'
```

Expected: four FAILs — both `born in the invoking cwd` assertions reporting `expected [/tmp/tl-newcwd-<pid>] got [/home/bitsaver]`, and `no creation site forces a fixed directory` reporting `expected [0] got [4]`. The non-empty and count-of-four guards must PASS at this point; if either fails, the `awk` range is wrong and every assertion built on it is worthless — stop and report.

- [ ] **Step 3: Make the change**

In `conf.d/tmux.fish`, remove `-c "$HOME"` from all four sites, leaving everything else on each line untouched:

```fish
            tmux new-session -d -s "$name"
```

```fish
            set -l sid (tmux new-session -dP -F '#{session_id}')
```

```fish
        exec tmux -u new-session -A -s "$name"
```

```fish
        exec tmux -u new-session
```

Update the function's description — it currently says the session is created in the home directory, which stops being true here.

- [ ] **Step 4: Run them and watch them pass**

```bash
cd ~/workspace/tmux-lives && fish tests/test-tmux-auto.fish 2>&1 | grep -E '^FAIL|ALL PASS'
```

Expected: `ALL PASS`.

- [ ] **Step 5: Run the full gate, both modes, foreground, explicit timeout**

Same two commands as Task 2 Step 5. Expected: 9/9 `ALL PASS` both modes, install 798 / 797.

Pay attention to `test-tmux-install.fish`: it stubs `__tmux_lives_new` at line 852 and erases it at 855, so it should be unaffected. If its count moves at all, investigate before committing rather than accepting a new number.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux.fish tests/test-tmux-auto.fish
git commit -m "feat(naming): a session is born where you were"
```

---

### Task 4: Record the cycle

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-project-from-pane-cwd-design.md` (status line only)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the verdicts and gate numbers from Tasks 1-3.
- Produces: nothing code depends on.

- [ ] **Step 1: Flip the spec's status**

Change the status line from `APPROVED, NOT BUILT` to `SHIPPED`, with the date and the merge commit. Leave the rest of the spec as written — it describes how the thing works and stays as the reference.

- [ ] **Step 2: Add the CLAUDE.md paragraph**

Append to the narrative in the established voice and level of detail. It must carry, at minimum:

- That naming now reads the active pane's cwd via a git-root walk (`__tcz_git_root`, `test -d` in a loop, never a `git` subprocess), reversing decisions N3 and N9 of the 2026-08-18 naming design.
- That `session_path` is a **strictly dominated** input — it equals the pane path until a `cd` and is stale after one — with the measured evidence: seven of eight macwork sessions and five of six rocket sessions sat at `~`, and one was actively misleading.
- That **the creation change fixes none of the sessions that started this cycle.** Five of six rocket sessions were born at `~` and reached their project by `cd`. Anyone reading the creation change as the headline fix will be confused about why nothing improved.
- That `__tcz_new_general` moved the *other* way and pins `$HOME`, because `run-shell` executes at the tmux **server's** cwd — measured on an isolated socket — so a commandeered tab would otherwise be named after wherever the server was started.
- Whatever Task 1's mutation battery found, including any mutation that survived.
- The final gate numbers from Task 3 Step 5, and that the install-suite plain/`--no-config` delta of 1 is by design.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-08-19-project-from-pane-cwd-design.md
git commit -m "docs(claude): record the session-cwd cycle"
```

---

## After the tasks

Per the standing branch-completion default, once every task is reviewed and the gate is green on the branch: merge to `main` locally, re-verify the gate on the merged result, push, delete the feature branch. Do not open a PR and do not ask which option.

Then tell the user the work is on `main` and that it reaches their machine on their next `fisher update` — a Claude session never deploys.

Two things are live-only and cannot be gated here, so name them as pending smoke rather than claiming them done:

- A real ShellFish tab retitling as you `cd` between projects, and a fresh tab still coming up at home.
- Whether a session renaming on every `cd` is pleasant in practice. The spec accepts it and the user confirmed it, but nobody has lived with it yet.
