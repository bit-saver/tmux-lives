# Landing Chooser v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The landing chooser lists only real, idle Claude projects — interactive conversations only, each mapped to its repository, grouped by where it lives, anything older than 21 days behind one `older (N)` row — and trades the "new shell" row for an `n` key, draws a border above the key legend, and stops capturing the preview on every step of a held arrow.

**Architecture:** All code is in `functions/tmux-categorize.fish`, the categorizer that runs as `fish --no-config` (the landing app is its `landing` verb). One shared path policy (`__tcz_generic_dir`, `__tcz_claude_project_of`) feeds session naming, project discovery and the busy check. Discovery gets an interactive-only reader (one `awk` per changed transcript directory) and a versioned cache. The model gets groups and the older row; the app loop gets the `n` key, the reveal, and a hold state that the painter and the frame use to skip the preview capture while a move key is held.

**Tech Stack:** fish 4.x (`fish --no-config` runtime), tmux 3.3a (rocket) and 3.7b (macwork), POSIX awk (gawk, mawk, macOS BWK awk: only `BEGIN`, `getline`, `match`, `index`, `close`), the repo's fish test suites (`tests/test-*.fish`).

**Spec:** `docs/superpowers/specs/2026-09-26-landing-session-design.md` — sections "The landing app" and "Claude project discovery"; its Status line names Chooser v2.

## Global Constraints

Every task's requirements include this section.

- ⛔ **Your shell runs inside the user's live tmux.** `TMUX` names his real server, and tmux honors `TMUX` over `TMUX_TMPDIR`; a review agent killed his server this way on 2026-09-29. Every ad-hoc tmux command — implementer and reviewer alike — names its socket (`-L name` / `-S path`); never a bare `kill-server`; kill what you start. A subprocess that could reach tmux runs with `env -u TMUX -u TMUX_PANE` and a `-L … -f /dev/null` PATH shim (the categorize and auto suites already do; copy their prologue for any probe). Clearing `TMUX` alone is not isolation: a bare `tmux` then talks to the default socket, which is the live server.
- **A Claude session never deploys.** Never copy into `~/.config/fish`, never edit `~/.tmux.conf`, never set universal variables to ship something. The user runs `fisher update`.
- **Tests never touch the real `~/.claude/projects` or `~/.cache/tmux-lives`.** Use the exported seams set at the top of each suite (`tmux_lives_claude_projects_dir`, `tmux_lives_project_cache`, `tmux_lives_render_cache_dir`). The real-cache brackets look for this run's footprint — seam rows, this suite's fixture folders, a cache left with no data rows — never an mtime: the user's own landing apps rewrite `projects.tsv` mid-run.
- **Running suites:** each suite as its own **foreground** Bash call with an explicit `timeout: 600000` — never in the background, never wrapped in a shell `timeout`. Filter with `grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('`, never `tail -1`. The popup suite runs with tmux unreachable (see Conventions). The gate is all nine suites in both modes:

  ```bash
  fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('       # one call per suite
  fish --no-config tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|FAILED \('
  ```

- **Baseline (HEAD `2b978b7`):** 9/9 `ALL PASS` in both modes; `test-tmux-install.fish` `ALL PASS (960)` plain / `(959)` `--no-config` (the one-count delta is by design); `test-generic.fish` `(3)`; `test-tmux-status.fish` `(4)`; the categorize, auto, popup, shellfish, restore and tick-calls suites print no count. This plan adds no install assertion: the counts stay 960 / 959. Sweep nothing in `/tmp/tmux-1000/` but this run's own `-L` sockets: never `default`, never `neurotest*`.
- **Keep the landing app's guarantees:** a key acts only alone (the type-ahead burst rule, drained to a 0.3 s gap; CR LF is one Enter); the settle window (a quiet second after the first paint, 2 s at most); the idle cadence (3 s, then 15 s after 60 s with no key; seams `tmux_lives_landing_idle_after` / `_idle_refresh`); diff painting (an idle refresh writes nothing); the shared key reader `__tcz_popup_readkey` unchanged except for the one `n` case Task 4 justifies.
- **Spec values, verbatim:** groups `projects` (`~/projects/*`), `workspace` (`~/workspace/*`), `work` (`~/Work/*`), `other` (everything else), in that order; a group with no rows is not shown; newest first within a group. A project whose last interactive conversation is more than 21 days old is hidden; one final row, `older (N)`, reveals them in their groups (Enter on it) until the app restarts. `n` starts a new general session in `$HOME`; the "new shell" row is removed. A border line separates the key legend from the list and the preview. While a move key is held only the list repaints; the preview is captured once input has been quiet (spec ~150 ms; this plan 0.2 s — Decisions 6). Interactive = `"entrypoint":"cli"`, or no `entrypoint` field (older files). Never a project: `$HOME`, `/`, `/tmp`, `/var/tmp`, `/private/tmp`, `/private/var/tmp`, `/var/folders/*`, `$TMPDIR`, and the group roots `~/projects`, `~/workspace`, `~/Work`.
- **`CLAUDE.md` stays under 40,000 bytes** (`wc -c CLAUDE.md`); whoever writes there prunes there.
- **Comments are brief:** what a reader of the code needs; measurements and history go in the commit message. New prose uses American spelling; existing identifiers and strings are left alone.
- **Branch and commits:** work on a branch `landing-chooser-v2` (a worktree, per superpowers:using-git-worktrees); one commit per task with the message given. Merging to `main` and pushing is the controller's finish step.

## Standing instructions for implementers and reviewers

1. Briefs in this repo have contained defects in every build. If the code disagrees with this plan, the code wins — say so in your report, quoting the line.
2. Prove every new assertion FAILS before its fix, and each for its own reason. Watch for one failure masking another: a command substitution that calls an undefined function aborts its whole statement silently, and several assertions can fail for one unrelated cause. Where a step names a mutation check, run it: copy the file aside, apply the mutation, run, restore from the copy, and prove the restore with `diff`.
3. Label non-regression guards in the assertion's description, `(non-regression)`: they pass before the change by design. The expected-failure lists below say which ones they are.
4. Never `git checkout` to revert while work is uncommitted — restore from a copy and `diff`.
5. Describe a banned shape in prose; never spell a pattern a guard counts. Task 1's guard counts the literal `/var/tmp` inside `__tcz_project_name` and `__tcz_landing_model`: no comment or description there may contain it.
6. When a test greps a capture, assert the capture is non-trivial first — a positive control in the same assertion, or a count of what was captured.
7. Capture before asserting: `set -l x (…)` on its own line, then `t "<desc>" <expected> "$x"`.

## Measured while planning (2026-10-01, rocket, real data read-only)

- Real transcripts: 1,182 readable `*.jsonl` in 73 directories. `entrypoint` = `sdk-cli` 1,051, `cli` 128, `claude-vscode` 3, absent 0. In every file the first `"cwd":"…"` is on the same line as the first `"entrypoint":"…"` (line 3–7). The `-tmp` directory alone holds 1,015 transcripts, all `sdk-cli`.
- One awk pass over the `-tmp` directory's heads takes 1.09 s — why directories named after a generic folder are skipped unread. One awk per remaining directory (29 directories, 141 heads) costs ~90 ms.
- New discovery against the current one on the real tree: cold 155 ms vs 180 ms, warm 43 ms vs 88 ms (the current warm path stats all 1,015 `-tmp` files every call). The new rows drop `/tmp`, `~`, `~/projects` and the sdk-only `~/projects/claude`.
- **gawk aborts the whole run on an unreadable or vanished input file** ("fatal: cannot open file"), skipping every later file. Hence `getline` inside `BEGIN`, which returns -1 and moves on.
- **A failed fish `<` redirect prints a warning that `2>/dev/null` cannot catch.** Hence `test -r` before reading a `.git` file.
- **tmux gives a new pane the PATH of the client that created it** (3.3a), not the global environment's — Task 2's M-7 test prepends to the test's own PATH around `__tcz_landing_new`.
- Frame cost with 31 live rows: `__tcz_popup_frame` 50 ms for a live row, of which the preview capture and clip are 23 ms; `__tcz_popup_list_lines` 20 ms; a bare `capture-pane` 3.4 ms. Holding Down over 80 sessions (Task 6's test, six runs): before the change 9.8–10.6 rows/s with ~30 captures during the hold; after it 10.1–13.2 rows/s with none. With 80 rows the list build dominates a step, so the rate gain is modest; the capture count is the robust signal, and a shorter real list gains more (the capture was 23 of 50 ms at 31 rows).

## Decisions this plan made where the spec was open

1. **Group rules read the group's name** (`── projects`, `── workspace`, `── work`, `── other`) in the idle-project color 5; the old `── idle claude` label goes. The `older (N)` row sits under a plain color-8 rule with no word: the row says what it is.
2. **A project row's category is its group** (`projects` / `workspace` / `work` / `other`, the list `__tcz_landing_groups`); the old `project` category is gone everywhere. The older row is `older\tolder\t0\t<N>\tolder (N)`.
3. **The generic list is equality** for `/`, `$HOME`, `/tmp`, `/var/tmp`, `/private/tmp`, `/private/var/tmp` and `$TMPDIR` (trailing slashes ignored), and **"anything below"** for `/var/folders` and `/private/var/folders`. A folder *inside* `/tmp` stays a project: the suites' fixtures live there.
4. **Group roots are excluded by discovery only** (`__tcz_claude_project_of` and the directory skip), not by `__tcz_generic_dir`: a pane sitting in `~/projects` still names its session `projects`, as today.
5. **The busy check uses discovery's mapping:** a claude in a worktree of repo R makes R busy. The spec says "its git root", but a worktree's git root is the worktree folder, which can never equal R.
6. **Quiet is 0.2 s, not 150 ms:** the tty read timer (`stty time`) counts tenths of a second, so the choice is 0.1 or 0.2; 0.2 errs toward never capturing mid-hold on a jittery iPad link. Every move starts a hold, so a single tap's preview also arrives 0.2 s later.
7. **"More than 21 days":** hidden when `now - mtime > 1814400`. The seam `tmux_lives_landing_older_after` counts seconds, like the idle seams.
8. **After Enter on `older (N)`** the pointer goes to the first row the reveal added.
9. **The chooser can now be empty** (no live session, no project): the pointer clamps to 0, never -1; Enter, `r` and `x` do nothing there; `n` still works.
10. **Cache v2:** first line `# tmux-lives projects v2`; a file without it is ignored whole. Rows: `dir`, the directory's newest transcript mtime (the validity key), the newest interactive transcript's mtime, and that transcript's raw `cwd` — mapped at read time, so a later policy change needs no new format. The theme render cache is untouched (its prune deletes only `<digits>-<hex6>.tsv`). During the seconds between a `fisher update` and the landing respawn, an old app and a new app can rewrite the file in turn; each discards the other's format, which costs re-reads, nothing else.
11. **Task order differs from the suggested one.** Keys and layout (Task 4) come before groups (Task 5), so `older (N)` is born the final row instead of being placed above a "new shell" row the next task deletes. The `$HOME`-dotfiles test is rewritten in Task 2, not Task 3: discovery v2 is what makes `$HOME` never a project, and the old test would fail from Task 2 on.

## Conventions used below

- Every assertion is the suite's `t "<desc>" <expected> "$captured"`.
- Every command runs from the worktree root. Agent shells reset the working directory between Bash calls, so start each call with `cd <worktree> &&`. The agent's Bash tool is zsh: a glob that matches nothing aborts the whole command there.
- Suite times on rocket: categorize ~4.5 min, install ~5 min, the other seven well under a minute together.
- "Find (exactly once)" blocks are exact text that occurs once in the named file; replace it with the block that follows. Line numbers drift: find by text. Insertions are given as "insert before / after the line …".
- **One-time setup** (in the worktree; `artifacts/` is gitignored): a tmux stub for the popup suite, and an optional focused runner for the categorize suite. The popup suite is pure and must never reach a tmux server; with the stub, any stray call fails instead of touching the live one.

```bash
mkdir -p artifacts/notmux
printf '#!/bin/sh\nexit 1\n' > artifacts/notmux/tmux && chmod +x artifacts/notmux/tmux
cat > artifacts/focus.sh <<'SH'
#!/bin/bash
# focus.sh "<first line>" "<stop line>" [...more pairs]: run those blocks of the categorize suite
# with its prologue (shim socket, fake claude, seams) and the landing-app helpers. Speed-up only.
cd "$(dirname "$0")/.." || exit 1
s=tests/test-tmux-categorize.fish; out=artifacts/focus.fish
blk() { awk -v a="$1" -v b="$2" 'index($0,a)==1{on=1} on && index($0,b)==1 && index($0,a)!=1{exit} on' "$s"; }
{
  awk '{print} /^function fresh_server/{f=1} f && /^end$/{exit}' "$s"
  echo 'set -g lcat $plugindir/functions/tmux-categorize.fish'
  blk '# --- landing: the running app, driven through a real pty client ---' '# q / Esc do nothing'
  while [ $# -ge 2 ]; do blk "$1" "$2"; shift 2; done
  cat <<'FOOT'
cleanup
string match -qr '^/tmp/tcz-shim-[0-9]+$' -- "$shimdir"; and rm -rf $shimdir
rm -rf $__tcg_rc_dir "$tmux_lives_claude_projects_dir" "$tmux_lives_project_cache"
for f in /tmp/tmux-(id -u)/*-$fish_pid; rm -f $f; end
test $FAIL -eq 0; and echo "ALL PASS"; or echo "SOME FAILED"
FOOT
} > "$out"
fish "$out" 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|^# |^SKIP'
SH
```

- **Popup suite command** (every popup run in this plan, gate included):

  ```bash
  env -u TMUX -u TMUX_PANE PATH=$PWD/artifacts/notmux:$PATH fish tests/test-tmux-popup.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'
  ```

- **Categorize suite command:** `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED|^# '` (~4.5 min). For the fail-first and pass steps you may instead run just the blocks you touched: `bash artifacts/focus.sh '<a block's first line>' '<the first line after it>' [more pairs]` — each argument is matched as a line prefix. A focused run never replaces the full suite and the gate before a commit.

## File map

| File | Tasks | Change |
|---|---|---|
| `functions/tmux-categorize.fish` | 1–6 | path policy; discovery v2; busy rule; `n`, border, empty list; groups, older row; held-move capture skip |
| `tests/test-tmux-categorize.fish` | 1–6 | new blocks per task; existing landing tests follow the new layout; real-cache bracket reads v2 rows |
| `tests/test-tmux-popup.fish` | 4–6 | pure rendering: border, `n`, groups, older row, held-move frame and painter |
| `tests/test-tmux-auto.fish`, `tests/test-tmux-install.fish` | 2 | real-cache bracket reads v2 rows (no new assertion) |
| `README.md`, `CLAUDE.md`, the spec | 7 | docs |

---

### Task 1: One generic-folder list, and a folder → project mapping

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_project_name` (replaced; three new functions follow it), one line in `__tcz_landing_model`'s busy loop, one comment in `__tcz_categorize`.
- Test: `tests/test-tmux-categorize.fish` — a new block right after the `__tcz_project_name` tests.

**Interfaces:**
- Consumes: `__tcz_git_root <path>` (existing: walks up to `$HOME` or `/`, prints the first folder holding a `.git` entry, file or directory, else nothing).
- Produces:
  - `__tcz_generic_dir <path>` — status 0 when `<path>` is never a project, else 1; prints nothing.
  - `__tcz_landing_group_roots` — prints `$HOME/projects`, `$HOME/workspace`, `$HOME/Work`, one per line, in group order.
  - `__tcz_claude_project_of <folder>` — prints the project folder (the enclosing repo root; for a linked worktree its main repository; else the folder itself), or nothing with status 1 when that is a generic folder or a group root. No subprocess.
  - `__tcz_project_name <path>` — same contract; now also empty for `/private/tmp`, `/private/var/tmp`, `$TMPDIR` and anything below `/var/folders`.

- [ ] **Step 1: Write the failing tests.** In `tests/test-tmux-categorize.fish`, find the end of the git-root / project-name tests:

```fish
rm -rf $grbase
set -e grbase
```

and insert after it (one blank line first):

```fish
# --- chooser v2: one generic-folder list (__tcz_generic_dir) for naming, discovery and the busy check ---
set -l gd_had_tmpdir (set -q TMPDIR; and echo 1; or echo 0)
set -l gd_tmpdir_save "$TMPDIR"
set -l gdt /tmp/tcz-gd-$fish_pid
rm -rf $gdt; mkdir -p $gdt/tmpdir/.git $gdt/tmpdir/sub
set -gx TMPDIR $gdt/tmpdir/
set -l gd1 (__tcz_project_name /private/tmp)
set -l gd2 (__tcz_project_name /private/var/tmp)
set -l gd3 (__tcz_project_name /var/folders/ab/cd1234/T)
set -l gd4 (__tcz_project_name /var/folders/ab/cd1234/T/scratch)
set -l gd5 (__tcz_project_name $gdt/tmpdir)
set -l gd6 (__tcz_project_name $gdt/tmpdir/sub)
set -l gd7 (__tcz_project_name /tmp/tcz-gd-plain)
if test $gd_had_tmpdir = 1; set -gx TMPDIR $gd_tmpdir_save; else; set -e TMPDIR; end
rm -rf $gdt
t "generic: macOS /private/tmp is not a project" "" "$gd1"
t "generic: /private/var/tmp is not a project" "" "$gd2"
t "generic: a /var/folders temp folder is not a project" "" "$gd3"
t "generic: nor is anything below /var/folders" "" "$gd4"
t "generic: \$TMPDIR (trailing slash and all) is not a project" "" "$gd5"
t "generic: a walk that lands on \$TMPDIR's .git found no repo (own basename)" sub "$gd6"
t "generic (non-regression): a folder inside /tmp is still a project" tcz-gd-plain "$gd7"
set -l gdp
for p in / '' $HOME $HOME/ /tmp/ /var/folders /private/var/folders/x/y
    __tcz_generic_dir "$p"; and set -a gdp y; or set -a gdp n
end
t "generic_dir: /, empty, \$HOME, \$HOME/, /tmp/, /var/folders, below /private/var/folders" "y y y y y y y" "$gdp"
set -l gdn (functions -q __tcz_generic_dir; and echo defined; or echo undefined)
for p in /tmp/x /var/foldersx $HOME/projects /privatetmp
    __tcz_generic_dir "$p"; and set -a gdn y; or set -a gdn n
end
t "generic_dir: a folder inside /tmp, a look-alike, a home subfolder" "defined n n n n" "$gdn"
set -l gdbody_list (functions __tcz_generic_dir 2>/dev/null | string collect)
set -l gdbody_name (functions __tcz_project_name | string collect)
set -l gdbody_model (functions __tcz_landing_model | string collect)
set -l gdl (string match -q '*/private/tmp*' -- "$gdbody_list"; and echo 1; or echo 0)
set -l gdn2 (string match -q '*/var/tmp*' -- "$gdbody_name"; and echo 1; or echo 0)
set -l gdm (string match -q '*/var/tmp*' -- "$gdbody_model"; and echo 1; or echo 0)
t "generic: the folder list is spelled once (naming and the busy check call __tcz_generic_dir)" "1 0 0" "$gdl $gdn2 $gdm"

# --- chooser v2: a conversation's folder -> its project (__tcz_claude_project_of) ---
set -l po /tmp/tcz-po-$fish_pid
rm -rf $po
mkdir -p $po/repo/.git/worktrees/wt $po/repo/.git/worktrees/wt2 $po/repo/.git/modules/mod $po/repo/sub/deep \
    $po/wt/src $po/wt2 $po/repo/.claude/worktrees/fade $po/repo/mod/x $po/plain/sub
printf 'gitdir: %s/repo/.git/worktrees/wt\n' $po > $po/wt/.git
printf 'gitdir: ../repo/.git/worktrees/wt2\n' > $po/wt2/.git
printf 'gitdir: %s/repo/.git/worktrees/fade\n' $po > $po/repo/.claude/worktrees/fade/.git
printf 'gitdir: ../.git/modules/mod\n' > $po/repo/mod/.git
set -l po1 (__tcz_claude_project_of $po/repo/sub/deep)
set -l po2 (__tcz_claude_project_of $po/wt/src)
set -l po3 (__tcz_claude_project_of $po/wt2)
set -l po4 (__tcz_claude_project_of $po/repo/.claude/worktrees/fade)
set -l po5 (__tcz_claude_project_of $po/repo/.claude/worktrees/gone)
set -l po6 (__tcz_claude_project_of $po/repo/mod/x)
set -l po7 (__tcz_claude_project_of $po/plain/sub)
t "project_of: a folder inside a repo -> the repo root" $po/repo "$po1"
t "project_of: a linked worktree -> its main repository" $po/repo "$po2"
t "project_of: a worktree with a relative gitdir -> its main repository" $po/repo "$po3"
t "project_of: a worktree kept inside its own repo (.claude/worktrees) -> that repo" $po/repo "$po4"
t "project_of: a removed worktree's folder walks up to its repo" $po/repo "$po5"
t "project_of: a submodule is its own project (its gitdir is no worktree)" $po/repo/mod "$po6"
t "project_of: no repo -> the folder itself" $po/plain/sub "$po7"
set -l pog
for p in $po/plain / /tmp /private/tmp $HOME
    set -l r (__tcz_claude_project_of $p)
    set -a pog "[$r]"
end
t "project_of: generic folders are never projects" "[$po/plain] [] [] [] []" "$pog"
set -g __tcz_po_home_save $HOME
set -g HOME $po/home
mkdir -p $HOME/.git $HOME/projects/foo $HOME/workspace $HOME/Work/myEMS/api/.git $HOME/Work/myEMS/api/src
set -l poh
for p in $HOME/projects/foo $HOME/projects $HOME/workspace $HOME/Work $HOME/Work/myEMS $HOME/Work/myEMS/api/src $HOME
    set -l r (__tcz_claude_project_of $p)
    set -a poh "[$r]"
end
set -g HOME $__tcz_po_home_save
set -e __tcz_po_home_save
t "project_of: group roots and a dotfiles \$HOME are never projects; what is inside them is" \
    "[$po/home/projects/foo] [] [] [] [$po/home/Work/myEMS] [$po/home/Work/myEMS/api] []" "$poh"
set -g pofork /tmp/tcz-po-forked-$fish_pid
rm -f $pofork
function git; touch $pofork; end
__tcz_claude_project_of $po/wt/src >/dev/null
functions -e git
t "project_of (non-regression): never forks a git subprocess" no (test -e $pofork; and echo yes; or echo no)
rm -f $pofork; set -e pofork
mkdir -p $po/locked
printf 'gitdir: %s/repo/.git/worktrees/wt\n' $po > $po/locked/.git
chmod 000 $po/locked/.git
if test -r $po/locked/.git
    echo "SKIP: project_of's unreadable .git needs a non-root run"
else
    set -l polk (fish --no-config -c "set -g tmux_categorize_test 1; source $plugindir/functions/tmux-categorize.fish; __tcz_claude_project_of $po/locked" 2>&1)
    t "project_of: an unreadable .git prints nothing and keeps its folder" $po/locked "$polk"
end
chmod 600 $po/locked/.git
rm -rf $po
```

- [ ] **Step 2: Run them and watch them fail.** `bash artifacts/focus.sh '# --- chooser v2: one generic-folder list' 'set -g dn1 '` (or the full suite). Expected: 19 `FAIL` lines — the six `generic:` assertions about `/private/tmp`, `/private/var/tmp`, `/var/folders` (two), `$TMPDIR`, and the walk onto `$TMPDIR`'s `.git`; both `generic_dir:` assertions (the second shows `undefined`); `generic: the folder list is spelled once` (`got [0 1 1]`); all seven single-folder `project_of:` assertions (`got []`); `project_of: generic folders are never projects`; `project_of: group roots and a dotfiles $HOME …`; `project_of: an unreadable .git …` (`Unknown command`). Passing by design: `generic (non-regression): a folder inside /tmp is still a project` and `project_of (non-regression): never forks a git subprocess`.

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

**Edit 1.1** — replace the whole of `__tcz_project_name` (its `function` line through its `end`) with the generic predicate, the new `__tcz_project_name`, the group roots and the folder → project mapping

Find (exactly once):

```fish
function __tcz_project_name --argument-names path --description 'the active pane'"'"'s cwd -> project name, or NOTHING when the directory carries no project meaning. Generic dirs ($HOME, /, /tmp, /var/tmp) deliberately yield empty so the caller falls back to gen-N rather than naming a session after your home directory or `tmp`. Otherwise: the basename of the nearest git root at or above <path> (__tcz_git_root, stopping at $HOME or /), else <path>'"'"'s own basename when no repo is found -- and a walk result that itself LANDS on a generic directory (a dotfiles repo at $HOME/.git, say) counts as no repo found, so it takes that same basename fallback rather than naming every subdirectory of home after home. The walk exists for exactly one measured case (a pane sitting in a subdirectory of a repo whose own basename is useless, e.g. .../pingy-android/user) and is a no-op everywhere else. Spaces are PRESERVED: this feeds the display layer, and the safe tmux name is slugified separately by the caller.'
    test -n "$path"; or return
    set -l p (string replace -r '/+$' '' -- "$path")
    test -n "$p"; or return              # "/" collapses to empty
    contains -- "$p" "$HOME" /tmp /var/tmp; and return
    set -l root (__tcz_git_root "$p")
    # A walk result that LANDS on a generic directory counts as "no repo found",
    # not as a project -- the same exclusion applied to the input path above,
    # applied again to what the walk returned. With a dotfiles repo at
    # $HOME/.git (an ordinary setup) every non-repo subdirectory of home would
    # otherwise resolve to the home directory's own basename, and __tcz_unique
    # would then collide them into name / name-2 / name-3: materially worse
    # than the gen-N they replace. Falling back to the OWN basename of <path>
    # rather than yielding nothing is the consistent reading -- "no repo found
    # -> basename" is this function's documented fallback. "/" is in this list but
    # not the input one because the input "/" already collapsed to empty above,
    # while the walk can genuinely return "/" for a /.git.
    contains -- "$root" "$HOME" / /tmp /var/tmp; and set root ''
    test -n "$root"; and set p "$root"
    path basename -- "$p"
end
```

Replace with:

```fish
function __tcz_generic_dir --argument-names path --description 'pure: true when <path> is a folder that is never a project -- /, $HOME, or a temp folder: /tmp, /var/tmp, /private/tmp, /private/var/tmp, $TMPDIR, or anything under /var/folders or /private/var/folders (macOS reports /tmp as /private/tmp). The one list shared by session naming, Claude project discovery and the chooser'"'"'s busy check.'
    set -l p (string replace -r '/+$' '' -- "$path")
    test -n "$p"; or return 0                  # "/" collapses to empty
    contains -- "$p" "$HOME" /tmp /var/tmp /private/tmp /private/var/tmp /var/folders /private/var/folders; and return 0
    set -l tmpdir (string replace -r '/+$' '' -- "$TMPDIR")
    test -n "$tmpdir"; and test "$p" = "$tmpdir"; and return 0
    string match -q -- '/var/folders/*' "$p"; or string match -q -- '/private/var/folders/*' "$p"
end

function __tcz_project_name --argument-names path --description 'the active pane'"'"'s cwd -> project name, or NOTHING when the directory carries no project meaning. A generic folder (__tcz_generic_dir: $HOME, /, the temp folders) deliberately yields empty so the caller falls back to gen-N rather than naming a session after your home directory or `tmp`. Otherwise: the basename of the nearest git root at or above <path> (__tcz_git_root, stopping at $HOME or /), else <path>'"'"'s own basename when no repo is found -- and a walk result that itself LANDS on a generic folder (a dotfiles repo at $HOME/.git, say) counts as no repo found, so it takes that same basename fallback rather than naming every subdirectory of home after home. The walk exists for exactly one measured case (a pane sitting in a subdirectory of a repo whose own basename is useless, e.g. .../pingy-android/user) and is a no-op everywhere else. Spaces are PRESERVED: this feeds the display layer, and the safe tmux name is slugified separately by the caller.'
    test -n "$path"; or return
    set -l p (string replace -r '/+$' '' -- "$path")
    __tcz_generic_dir "$p"; and return
    set -l root (__tcz_git_root "$p")
    # A walk that lands on a generic folder (a dotfiles repo at $HOME/.git) found no
    # repo: else every non-repo folder under home would be named after home, and
    # __tcz_unique would collide them into name / name-2 / name-3.
    test -n "$root"; and __tcz_generic_dir "$root"; and set root ''
    test -n "$root"; and set p "$root"
    path basename -- "$p"
end

function __tcz_landing_group_roots --description 'pure: the folders whose children make the chooser'"'"'s project groups, in group order -- ~/projects ~/workspace ~/Work. A root itself is never a project.'
    printf '%s\n' $HOME/projects $HOME/workspace $HOME/Work
end

function __tcz_claude_project_of --argument-names folder --description 'pure: a Claude conversation'"'"'s folder -> its project folder, or nothing. A folder inside a git repo -> the repo root; a linked worktree -> its main repository (its .git is a file reading `gitdir: <repo>/.git/worktrees/<name>`); never a generic folder (__tcz_generic_dir) or a group root (__tcz_landing_group_roots). No subprocess.'
    set -l p (string replace -r '/+$' '' -- "$folder")
    set -l roots (__tcz_landing_group_roots)
    set -l root (__tcz_git_root "$p")
    # A repo rooted at a generic folder or a group root (a dotfiles repo at $HOME) is no repo.
    if test -n "$root"; and not __tcz_generic_dir "$root"; and not contains -- "$root" $roots
        set p $root
        # test -r first: a failed `<` redirect prints a warning that 2>/dev/null cannot catch.
        if test -f "$p/.git"; and test -r "$p/.git"
            read -l line < "$p/.git"
            set -l gitdir (string replace -r '^gitdir:\s*' '' -- "$line")
            string match -q -- '/*' "$gitdir"; or set gitdir "$p/$gitdir"
            set -l main (string replace -rf '/\.git/worktrees/[^/]+/*$' '' -- (path normalize -- "$gitdir"))
            test -n "$main"; and set p $main
        end
    end
    __tcz_generic_dir "$p"; and return 1
    contains -- "$p" $roots; and return 1
    echo $p
end
```

**Edit 1.2** — in `__tcz_landing_model`'s busy loop, the shared predicate replaces the inline list

Find (exactly once):

```fish
        test -n "$root"; and not contains -- "$root" "$HOME" / /tmp /var/tmp; and set -a busy $root
```

Replace with:

```fish
        test -n "$root"; and not __tcz_generic_dir "$root"; and set -a busy $root
```

**Edit 1.3** — in `__tcz_categorize`, the comment above the `__tcz_project_name` call

Find (exactly once):

```fish
        # is right), never the running process/category (spec N8). Empty for
        # $HOME, /, /tmp, /var/tmp (and unreadable/empty paths) by
        # __tcz_project_name's own contract.
```

Replace with:

```fish
        # is right), never the running process/category (spec N8). Empty for
        # a generic folder (__tcz_generic_dir) and unreadable/empty paths by
        # __tcz_project_name's own contract.
```

- [ ] **Step 4: Run them and watch them pass.** Same command as Step 2: `ALL PASS`. Mutation checks (restore from a copy each time, prove with `diff`):
  - delete `; and test -r "$p/.git"` from `__tcz_claude_project_of` → only `project_of: an unreadable .git …` fails, its captured text a `warning: An error occurred while redirecting file …`;
  - delete the inner `if test -f "$p/.git" … end` block → exactly the three worktree assertions fail (`a linked worktree`, `a relative gitdir`, `kept inside its own repo`); the removed-worktree and submodule ones still pass.

- [ ] **Step 5: Gate.** Full categorize suite, then all nine suites in both modes (Global Constraints). Expected: 9/9 `ALL PASS` each mode; install `(960)` / `(959)`, generic `(3)`, status `(4)`.

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): one generic-folder list and a folder-to-project mapping" -m "__tcz_generic_dir is the single list of folders that are never a project: /, \$HOME, /tmp, /var/tmp, macOS /private/tmp and /private/var/tmp, \$TMPDIR, and anything below /var/folders. __tcz_project_name and the chooser's busy check now call it, so a macOS pane in /tmp (reported as /private/tmp) no longer names its session tmp.

__tcz_claude_project_of maps a Claude conversation's folder to its project: a folder inside a repo to the repo root, a linked worktree to its main repository (parsed from the .git file's gitdir line, no fork), never a generic folder or a group root (~/projects, ~/workspace, ~/Work). It reads a .git file only after test -r: a failed fish redirect prints a warning that 2>/dev/null cannot catch. Discovery and the busy check adopt it in the next two commits."
```

---

### Task 2: Discovery v2 — interactive conversations only, mapped to projects, cache v2

**Files:**
- Modify: `functions/tmux-categorize.fish` — replace the whole `__tcz_claude_projects` function; a new global `__tcz_proj_cache_head` just above it.
- Test: `tests/test-tmux-categorize.fish` — the real-cache bracket (top and hygiene sections), two existing discovery assertions, a new discovery block, the M-7 test (retargeted), the `$HOME`-dotfiles test (rewritten).
- Test: `tests/test-tmux-auto.fish`, `tests/test-tmux-install.fish` — the same real-cache bracket edits; no new assertion.

**Interfaces:**
- Consumes: `__tcz_claude_project_of`, `__tcz_landing_group_roots` (Task 1); `__tcz_claude_projects_dir`, `__tcz_claude_project_cache` (existing seams).
- Produces: `__tcz_claude_projects` — unchanged output shape, lines `folder\tmtime` newest first; `folder` is now a project folder that exists (Task 1's mapping of the newest interactive conversation's `cwd`), `mtime` that conversation's. Global `__tcz_proj_cache_head` = `# tmux-lives projects v2`. Cache rows `dir\tkey\tinteractive-mtime\tcwd`; the last two are empty for a directory with no interactive conversation.

- [ ] **Step 1: Write the failing tests and the bracket changes.**

In `tests/test-tmux-categorize.fish`:

**Edit 2a.1** — the real-cache bracket counts DATA rows (a v2 cache always has its header line)

Find (exactly once):

```fish
set -g __tcg_real_proj_rows_before (count (cat "$__tcg_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -g __tcg_real_proj_rows_before (cat "$__tcg_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2a.2**

Find (exactly once):

```fish
set -l __tcg_rows_after (count (cat "$__tcg_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -l __tcg_rows_after (cat "$__tcg_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2a.3** — leak check: the folder is the LAST field in both row shapes

Find (exactly once):

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[3]"; or continue
```

Replace with:

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[-1]"; or continue
```

**Edit 2a.4**

Find (exactly once):

```fish
printf '/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n' $fish_pid > $lk
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tcz-y-%s\n' $__tcg_proj_root $fish_pid > $lk.Ab12Cd
set -l lkout (__tcg_proj_leaks $lk $__tcg_proj_root $__tcg_proj_fre)
t "isolation: the leak check finds this run's two rows in a stray temp and passes real ones, even a /tmp one ending in this pid" "3 checked" "$(count $lkout) $lkout[-1]"
```

Replace with:

```fish
printf '# tmux-lives projects v2\n/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n/home/u/.claude/projects/-v2\t5\t5\t/home/u/v2\n' $fish_pid > $lk
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tcz-y-%s\n/home/u/.claude/projects/-z\t6\t6\t/tmp/tcz-z-%s\n' $__tcg_proj_root $fish_pid $fish_pid > $lk.Ab12Cd
set -l lkout (__tcg_proj_leaks $lk $__tcg_proj_root $__tcg_proj_fre)
t "isolation: the leak check finds this run's three rows (old and v2 shapes) in a stray temp and passes real ones, even a /tmp one ending in this pid" "4 checked" "$(count $lkout) $lkout[-1]"
```

**Edit 2a.5** — existing discovery tests: count data rows, not lines

Find (exactly once):

```fish
t "projects: cache written" 3 (count (cat $tmux_lives_project_cache))
```

Replace with:

```fish
set -l pjrows (cat $tmux_lives_project_cache | string match -v -- '#*')
set -l pjhead (head -n 1 $tmux_lives_project_cache)
t "projects: cache written, one row per directory under its v2 header" "3 # tmux-lives projects v2" "$(count $pjrows) $pjhead"
```

**Edit 2a.6**

Find (exactly once):

```fish
set -l cache_rows_after_removal (cat $tmux_lives_project_cache)
```

Replace with:

```fish
set -l cache_rows_after_removal (cat $tmux_lives_project_cache | string match -v -- '#*')
```

Still in `tests/test-tmux-categorize.fish`, insert after the line that ends the existing discovery tests,

```fish
rm -rf $pj /tmp/tcz-proj-a-$fish_pid /tmp/tcz-proj-b-$fish_pid $tmux_lives_project_cache
```

this block:

```fish

# --- chooser v2: discovery reads interactive conversations only and maps folders to projects ---
# Fixture directories: -mixed (an old interactive conversation in a, a newer headless run in b),
# -headless (headless and GUI runs only), -wt (a worktree of repo), -sub (a folder inside repo),
# -gen (a transcript whose cwd is /tmp), -tmp (named after /tmp: never read, whatever it holds).
set -l pj $tmux_lives_claude_projects_dir
set -l dv /tmp/tcz-dv-$fish_pid
rm -rf $pj $dv; rm -f $tmux_lives_project_cache
mkdir -p $pj/-mixed $pj/-headless $pj/-wt $pj/-sub $pj/-gen $pj/-tmp
mkdir -p $dv/a $dv/b $dv/c $dv/e $dv/repo/.git/worktrees/w1 $dv/repo/src/deep $dv/w1
printf 'gitdir: %s/repo/.git/worktrees/w1\n' $dv > $dv/w1/.git
printf '{"type":"summary"}\n{"entrypoint":"cli","cwd":"%s/a"}\n' $dv > $pj/-mixed/old.jsonl
printf '{"entrypoint":"sdk-cli","cwd":"%s/b"}\n' $dv > $pj/-mixed/new.jsonl
printf '{"entrypoint":"sdk-py","cwd":"%s/c"}\n' $dv > $pj/-headless/1.jsonl
printf '{"entrypoint":"claude-desktop","cwd":"%s/c"}\n' $dv > $pj/-headless/2.jsonl
printf '{"entrypoint":"claude-vscode","cwd":"%s/c"}\n' $dv > $pj/-headless/3.jsonl
printf '{"entrypoint":"cli","cwd":"%s/w1"}\n' $dv > $pj/-wt/s.jsonl
printf '{"cwd":"%s/repo/src/deep"}\n' $dv > $pj/-sub/s.jsonl
printf '{"entrypoint":"cli","cwd":"/tmp"}\n' > $pj/-gen/s.jsonl
printf '{"entrypoint":"cli","cwd":"%s/e"}\n' $dv > $pj/-tmp/s.jsonl
touch -d '3 hours ago' $pj/-mixed/old.jsonl
touch -d '1 hour ago' $pj/-mixed/new.jsonl
touch -d '2 hours ago' $pj/-wt/s.jsonl
touch -d '4 hours ago' $pj/-sub/s.jsonl
set -g __tcg_dvawk /tmp/tcz-dv-awk-$fish_pid
rm -f $__tcg_dvawk
function awk --description 'test recorder: count discovery awk runs'
    echo run >> $__tcg_dvawk
    command awk $argv
end
set -l dvrows (__tcz_claude_projects)
set -l dvcold (count (cat $__tcg_dvawk 2>/dev/null))
rm -f $__tcg_dvawk
set -l dvrows2 (__tcz_claude_projects)
set -l dvwarm (count (cat $__tcg_dvawk 2>/dev/null))
functions -e awk
rm -f $__tcg_dvawk; set -e __tcg_dvawk
set -l dvfolders (string split -f1 \t -- $dvrows)
t "discovery: interactive conversations only, each folder mapped to its project, newest first" "$dv/repo $dv/a" "$dvfolders"
set -l dvam (string match -- "$dv/a"\t'*' $dvrows | string split -f2 \t)
set -l dvrm (string match -- "$dv/repo"\t'*' $dvrows | string split -f2 \t)
set -l dvam_want (path mtime -- $pj/-mixed/old.jsonl)
set -l dvrm_want (path mtime -- $pj/-wt/s.jsonl)
t "discovery: a project's age is its newest interactive conversation (not a newer headless run; dedupe keeps the newest)" "$dvam_want $dvrm_want" "$dvam $dvrm"
t "discovery: one awk per directory read cold, none warm; the /tmp directory is never read" "5 0" "$dvcold $dvwarm"
t "discovery (non-regression): a warm call returns the same rows" "$dvrows" "$dvrows2"
set -l dvtmprow (string match -- "$pj/-tmp"\t'*' < $tmux_lives_project_cache)
set -l dvhead (head -n 1 $tmux_lives_project_cache)
t "discovery: the cache opens with its v2 header and has no row for the skipped directory" "# tmux-lives projects v2|" "$dvhead|$dvtmprow"

# A cache without the v2 header is discarded whole, even a row whose key still matches.
rm -rf $pj; rm -f $tmux_lives_project_cache
mkdir -p $pj/-old $dv/right $dv/wrong
printf '{"cwd":"%s/right"}\n' $dv > $pj/-old/s.jsonl
printf '%s\t%s\t%s\n' $pj/-old (path mtime -- $pj/-old/s.jsonl) $dv/wrong > $tmux_lives_project_cache
set -l dvold (__tcz_claude_projects | string split -f1 \t)
set -l dvhead2 (head -n 1 $tmux_lives_project_cache)
t "discovery: a cache from before v2 is discarded, not trusted" "$dv/right|# tmux-lives projects v2" "$dvold|$dvhead2"

# A group root is no project; directories named after a group root or $HOME are never read.
rm -rf $pj; rm -f $tmux_lives_project_cache
set -g __tcg_dv_home_save $HOME
set -g HOME $dv/home
mkdir -p $HOME/projects/p1 $HOME/Work/w1
set -l dvslug_root (string replace -ra '[^A-Za-z0-9]' '-' -- $HOME/projects)
set -l dvslug_home (string replace -ra '[^A-Za-z0-9]' '-' -- $HOME)
mkdir -p $pj/-groot $pj/$dvslug_root $pj/$dvslug_home $pj/-work
printf '{"cwd":"%s/projects"}\n' $HOME > $pj/-groot/s.jsonl
printf '{"cwd":"%s/projects/p1"}\n' $HOME > $pj/$dvslug_root/s.jsonl
printf '{"cwd":"%s/projects/p1"}\n' $HOME > $pj/$dvslug_home/s.jsonl
printf '{"cwd":"%s/Work/w1"}\n' $HOME > $pj/-work/s.jsonl
set -l dvgr (__tcz_claude_projects | string split -f1 \t)
set -g HOME $__tcg_dv_home_save
set -e __tcg_dv_home_save
t "discovery: a group root is no project; directories named after it or \$HOME are never read" "$dv/home/Work/w1" "$dvgr"

# An unreadable transcript is skipped; the others in its directory still count.
rm -rf $pj; rm -f $tmux_lives_project_cache
mkdir -p $pj/-locked $dv/d
printf '{"entrypoint":"cli","cwd":"%s/d"}\n' $dv > $pj/-locked/b.jsonl
printf '{"entrypoint":"cli","cwd":"%s/e"}\n' $dv > $pj/-locked/a.jsonl
touch -d '5 hours ago' $pj/-locked/b.jsonl
chmod 000 $pj/-locked/a.jsonl
if test -r $pj/-locked/a.jsonl
    echo "SKIP: discovery's unreadable transcript needs a non-root run"
else
    set -l dvlk (__tcz_claude_projects 2>&1 | string split -f1 \t)
    t "discovery: an unreadable newest transcript is skipped, silently, and an older one still counts" "$dv/d" "$dvlk"
end
chmod 600 $pj/-locked/a.jsonl
rm -rf $pj $dv; rm -f $tmux_lives_project_cache
```

Replace the M-7 test — everything from the line `# --- final fix M-7: stderr from the app loop never reaches its screen ---` up to, not including, the line `# --- final fix: held arrow keys (the ESC path) drain too ---` — with the block below (and one blank line after it). Its old trigger, an unreadable transcript making discovery's `head` print to stderr, no longer prints anything: the new reader skips such files silently, which would leave the guard vacuous.

```fish
# --- final fix M-7: stderr from the app loop never reaches its screen ---
# The diff painter never repaints an unchanged row, so error text would stay.
# Trigger: a `sort` first on the app's PATH that writes to stderr inside a pane (every refresh sorts).
fresh_server
set -l m7bin /tmp/tcz-m7-bin-$fish_pid
rm -rf $m7bin; mkdir -p $m7bin
printf '#!/bin/sh\nif [ -n "$TMUX_PANE" ]; then touch %s/ran; echo "M7 stderr from the app loop" >&2; fi\nexec /usr/bin/sort "$@"\n' $m7bin > $m7bin/sort
chmod +x $m7bin/sort
set -l m7
begin
    set -lx PATH $m7bin $PATH         # tmux gives a new pane the PATH of the client that created it
    set m7 (__tcz_landing_new)
end
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =$m7" /dev/null >/dev/null 2>&1 &
set -l m7pids (jobs -p)
__tcg_client_on $m7 >/dev/null
__tcg_ready "=$m7:" '*new shell*'
sleep 3.5                             # past one idle refresh: the first paint covers the first pass's text
set -l m7ran (test -e $m7bin/ran; and echo 1; or echo 0)
set -l m7err (command tmux -L $sock capture-pane -p -t "=$m7:" | string match -e 'M7 stderr' | count)
t "M-7: a failing command in the app loop leaves no text on its screen" "1 0" "$m7ran $m7err"
for p in $m7pids; kill $p 2>/dev/null; end
rm -rf $m7bin
cleanup
```

Replace the `$HOME`-dotfiles test — everything from the line `# --- landing fix round 1: a dotfiles repo at $HOME never marks $HOME busy ---` up to, not including, the line `# --- landing fix round 1: discovery sweeps its own stray temp files ---` — with the block below (and one blank line after it). With discovery v2, `$HOME` is never a project, so the old assertion ("the `$HOME` project stays listed") would fail; the guard it carried — a dotfiles repo at `$HOME` must not mark anything busy — moves to a project beside it.

```fish
# --- chooser v2: a claude below a $HOME dotfiles repo marks nothing else busy ---
fresh_server
set -l bh /tmp/tcz-bh-$fish_pid
mkdir -p $bh/.git $bh/sub $bh/proj
set -l pj $tmux_lives_claude_projects_dir
rm -rf $pj; rm -f $tmux_lives_project_cache
mkdir -p $pj/-proj
printf '{"cwd":"%s"}\n' $bh/proj > $pj/-proj/s.jsonl
command tmux -L $sock new-session -d -s bhc -c $bh/sub "$shimdir/claude --enable-auto-mode"
sleep 0.5
set -l bhm
begin
    set -lx HOME $bh
    set bhm (__tcz_landing_model x)
end
set -l bhlisted (string match -q -- $bh/proj\t'*' $bhm; and echo listed; or echo hidden)
t "model (non-regression): a claude below a \$HOME dotfiles repo leaves a project beside it listed" listed "$bhlisted"
rm -rf $pj $tmux_lives_project_cache $bh
cleanup
```

In `tests/test-tmux-auto.fish`:

**Edit 2b.1**

Find (exactly once):

```fish
set -g __tac_real_proj_rows_before (count (cat "$__tac_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -g __tac_real_proj_rows_before (cat "$__tac_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2b.2**

Find (exactly once):

```fish
set -l __tac_rows_after (count (cat "$__tac_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -l __tac_rows_after (cat "$__tac_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2b.3**

Find (exactly once):

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[3]"; or continue
```

Replace with:

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[-1]"; or continue
```

**Edit 2b.4**

Find (exactly once):

```fish
printf '/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n' $fish_pid > $lk
```

Replace with:

```fish
printf '# tmux-lives projects v2\n/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n/home/u/.claude/projects/-v2\t5\t5\t/home/u/v2\n' $fish_pid > $lk
```

**Edit 2b.5**

Find (exactly once):

```fish
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tac-y-%s\n' $__tac_proj_root $fish_pid > $lk.Ab12Cd
```

Replace with:

```fish
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tac-y-%s\n/home/u/.claude/projects/-z\t6\t6\t/tmp/tac-z-%s\n' $__tac_proj_root $fish_pid $fish_pid > $lk.Ab12Cd
```

**Edit 2b.6**

Find (exactly once):

```fish
t "isolation: the leak check finds this run's two rows in a stray temp and passes real ones, even a /tmp one ending in this pid" "3 checked" "$(count $lkout) $lkout[-1]"
```

Replace with:

```fish
t "isolation: the leak check finds this run's three rows (old and v2 shapes) in a stray temp and passes real ones, even a /tmp one ending in this pid" "4 checked" "$(count $lkout) $lkout[-1]"
```

In `tests/test-tmux-install.fish`:

**Edit 2c.1**

Find (exactly once):

```fish
set -g __til_real_proj_rows_before (count (cat "$__til_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -g __til_real_proj_rows_before (cat "$__til_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2c.2**

Find (exactly once):

```fish
set -l __til_rows_after (count (cat "$__til_real_proj_cache" 2>/dev/null))
```

Replace with:

```fish
set -l __til_rows_after (cat "$__til_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
```

**Edit 2c.3**

Find (exactly once):

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[3]"; or continue
```

Replace with:

```fish
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[-1]"; or continue
```

**Edit 2c.4**

Find (exactly once):

```fish
printf '/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n' $fish_pid > $lk
```

Replace with:

```fish
printf '# tmux-lives projects v2\n/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n/home/u/.claude/projects/-v2\t5\t5\t/home/u/v2\n' $fish_pid > $lk
```

**Edit 2c.5**

Find (exactly once):

```fish
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tli-y-%s\n' $__til_proj_root $fish_pid > $lk.Ab12Cd
```

Replace with:

```fish
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tli-y-%s\n/home/u/.claude/projects/-z\t6\t6\t/tmp/tli-z-%s\n' $__til_proj_root $fish_pid $fish_pid > $lk.Ab12Cd
```

**Edit 2c.6**

Find (exactly once):

```fish
t "isolation: the leak check finds this run's two rows in a stray temp and passes real ones, even a /tmp one ending in this pid" "3 checked" "$(count $lkout) $lkout[-1]"
```

Replace with:

```fish
t "isolation: the leak check finds this run's three rows (old and v2 shapes) in a stray temp and passes real ones, even a /tmp one ending in this pid" "4 checked" "$(count $lkout) $lkout[-1]"
```

- [ ] **Step 2: Run them and watch them fail.** `bash artifacts/focus.sh '# --- landing: claude project discovery ---' '# --- landing: claude project discovery — running-pane cwds ---' '# --- final fix M-7: stderr' '# --- final fix: held arrow keys' '# --- chooser v2: a claude below a $HOME dotfiles' '# --- landing fix round 1: discovery sweeps' "# --- hygiene: this suite's own claude-project-discovery seams" 'if test $FAIL -eq 0'` (or the full suite). Expected: 8 `FAIL` lines — `projects: cache written, one row per directory under its v2 header` (the first line is a row), and the seven new `discovery:` assertions except the warm-call one: `interactive conversations only …`, `a project's age …` (`got [ ]`), `one awk per directory …` (`got [0 0]`), `the cache opens with its v2 header …`, `a cache from before v2 is discarded …` (`got [<dv>/wrong|…]`), `a group root is no project …`, `an unreadable newest transcript …` (`got []`). Passing by design: `discovery (non-regression): a warm call returns the same rows`, the retargeted M-7 test, the rewritten dotfiles test, and the three isolation brackets. Then prove the brackets' new reading is needed: in the categorize suite's `__tcg_proj_leaks`, change `"$r[-1]"` back to `"$r[3]"` → `isolation: the leak check finds this run's three rows …` fails with `got [3 checked]`; restore and `diff`.

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`, replace the whole function `__tcz_claude_projects` — from its `function __tcz_claude_projects --description …` line through its closing `end`, just before `function __tcz_claude_cwds` — with:

```fish
# The discovery cache's first line. A cache without it is ignored whole: its rows mean something else.
set -g __tcz_proj_cache_head '# tmux-lives projects v2'

function __tcz_claude_projects --description 'lines "folder\tmtime" (epoch seconds), newest first -- one per Claude project that still exists, from INTERACTIVE conversations only. Each directory under __tcz_claude_projects_dir is a lossy slug: its project comes from its newest transcript whose first cwd line says "entrypoint":"cli" or has no entrypoint (older files) -- that line'"'"'s "cwd", mapped by __tcz_claude_project_of. Headless runs (sdk-cli, sdk-py) and GUI apps (claude-desktop, claude-vscode) never make a project, and a directory named after a generic folder or a group root is never read. Caches dir/key/mtime/cwd rows in __tcz_claude_project_cache under a version header, re-reading a directory only when its newest transcript of any kind changed, and rewriting the cache only when something did. Never fails discovery over a cache write it could not make.'
    set -l root (__tcz_claude_projects_dir)
    set -l cache (__tcz_claude_project_cache)
    set -l TAB (printf '\t')

    # Rows: dir, its newest transcript's mtime (the key), the newest interactive one's mtime, that one's cwd.
    set -l cdirs; set -l ckeys; set -l cias; set -l ccwds
    if test -r "$cache"
        set -l head 1
        while read -l line
            if test $head -eq 1
                test "$line" = "$__tcz_proj_cache_head"; or break
                set head 0
                continue
            end
            set -l f (string split -m 3 $TAB -- $line)
            test (count $f) -eq 4; or continue
            set -a cdirs $f[1]; set -a ckeys $f[2]; set -a cias $f[3]; set -a ccwds $f[4]
        end < $cache
    end

    # Directories named after a folder that is never a project are not read at all:
    # rocket's /tmp one holds a thousand headless transcripts. Claude names a directory
    # by turning every character but a letter or digit into a dash.
    set -l skip
    for g in / $HOME /tmp /var/tmp /private/tmp /private/var/tmp $TMPDIR (__tcz_landing_group_roots)
        set -a skip (string replace -ra '[^A-Za-z0-9]' '-' -- (string replace -r '(.)/+$' '$1' -- $g))
    end

    # One row per source directory, project or not: that is what gets cached, so a
    # directory with no interactive conversation is not re-read until it changes.
    # <changed>: a re-read happened, or the directory set itself moved.
    set -l ddirs; set -l dkeys; set -l dias; set -l dcwds
    set -l changed 0
    for dir in $root/*/
        set dir (string replace -r '/+$' '' -- $dir)
        set -l base (path basename -- $dir)
        contains -- $base $skip; and continue
        string match -q -- '-var-folders-*' $base; and continue
        string match -q -- '-private-var-folders-*' $base; and continue
        set -l files $dir/*.jsonl
        test (count $files) -gt 0; or continue
        set -l mtimes (path mtime -- $files)
        set -l key $mtimes[1]
        for m in $mtimes
            test "$m" -gt "$key"; and set key $m
        end

        set -l idx (contains -i -- "$dir" $cdirs)
        set -l ia ''; set -l cwd ''
        if test -n "$idx"; and test "$ckeys[$idx]" = "$key"
            set ia $cias[$idx]; set cwd $ccwds[$idx]
        else
            set changed 1
            # The only fork here: one awk reads every transcript up to its first cwd line and
            # prints "file\tcwd" for the interactive ones. getline, not awk's main loop: a file
            # that cannot be read is skipped, where the main loop would abort the whole run.
            set -l hits (awk '
                BEGIN {
                    for (i = 1; i < ARGC; i++) {
                        f = ARGV[i]
                        while ((getline line < f) > 0) {
                            if (index(line, "\"cwd\":\"") == 0) continue
                            e = ""
                            if (match(line, /"entrypoint":"[^"]*"/)) e = substr(line, RSTART + 14, RLENGTH - 15)
                            if (e == "" || e == "cli") {
                                match(line, /"cwd":"[^"]*"/)
                                print f "\t" substr(line, RSTART + 7, RLENGTH - 8)
                            }
                            break
                        }
                        close(f)
                    }
                }' $files)
            for hit in $hits
                set -l h (string split -m 1 $TAB -- $hit)
                set -l k (contains -i -- "$h[1]" $files)
                test -n "$k"; or continue
                test -n "$ia"; and test "$mtimes[$k]" -le "$ia"; and continue
                set ia $mtimes[$k]; set cwd "$h[2]"
            end
        end
        set -a ddirs $dir; set -a dkeys $key; set -a dias "$ia"; set -a dcwds "$cwd"
    end
    test (count $ddirs) -eq (count $cdirs); or set changed 1

    if test "$changed" = 1
        set -l cachedir (path dirname -- $cache)
        test -d "$cachedir"; or mkdir -p "$cachedir" 2>/dev/null
        # Temps are named after the cache file, so a sweep can only ever
        # touch this cache's own leftovers (a writer killed between mktemp
        # and mv -- a landing app whose session closes -- leaves one).
        set -l tmp (mktemp "$cache.XXXXXX" 2>/dev/null)
        if test -n "$tmp"
            begin
                printf '%s\n' $__tcz_proj_cache_head
                set -l i 0
                for d in $ddirs
                    set i (math $i + 1)
                    printf '%s\t%s\t%s\t%s\n' $d $dkeys[$i] "$dias[$i]" "$dcwds[$i]"
                end
            end > $tmp
            if mv $tmp "$cache" 2>/dev/null
                set -l strays $cache.*       # a glob in `set`: no match is no error
                set strays (string match -er '\.[A-Za-z0-9]{6}$' -- $strays)
                test (count $strays) -gt 0; and rm -f -- $strays
            end
        end
    end

    # Each conversation's folder -> its project (__tcz_claude_project_of); dedupe,
    # keeping the newest; drop a project whose folder no longer exists.
    set -l ufolders; set -l umtimes
    set -l i 0
    for cwd in $dcwds
        set i (math $i + 1)
        test -n "$cwd"; or continue
        set -l proj (__tcz_claude_project_of $cwd)
        test -n "$proj"; and test -d "$proj"; or continue
        set -l j (contains -i -- "$proj" $ufolders)
        if test -n "$j"
            test "$dias[$i]" -gt "$umtimes[$j]"; and set umtimes[$j] $dias[$i]
        else
            set -a ufolders $proj; set -a umtimes $dias[$i]
        end
    end

    test (count $ufolders) -gt 0; or return
    set -l rows
    set -l i 0
    for folder in $ufolders
        set i (math $i + 1)
        set -a rows "$folder$TAB$umtimes[$i]"
    end
    printf '%s\n' $rows | sort -t\t -k2,2nr
end
```

- [ ] **Step 4: Run them and watch them pass.** Same command as Step 2: `ALL PASS`. Mutation check: in `__tcz_landing_cmd` (top of the file) drop ` 2>/dev/null` from `landing 2>/dev/null` → the M-7 test fails with `got [1 2]` (the shim's text reaches the screen); restore and `diff`.

- [ ] **Step 5: Gate.** Full categorize suite, then all nine suites in both modes. Expected: unchanged counts — install `(960)` / `(959)`, generic `(3)`, status `(4)`, everything else `ALL PASS`.

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish tests/test-tmux-auto.fish tests/test-tmux-install.fish
git commit -m "feat(landing): discover projects from interactive conversations only" -m "A transcript directory's project now comes from its newest INTERACTIVE transcript: the first cwd line's entrypoint is cli, or absent (older files). Headless runs (sdk-cli, sdk-py: claude -p, review harnesses) and the desktop and VS Code apps never make a project; on 2026-10-01 they made every wrong row (/tmp, ~, a watchface worktree, ~/Work). Each cwd maps through __tcz_claude_project_of, so a worktree or a subfolder lists as its repository and a generic folder or group root never lists. Directories named after one of those are skipped unread: rocket's /tmp one holds 1,015 headless transcripts (1.09 s to read).

One awk per changed directory reads each transcript up to its first cwd line, by getline: awk's main loop aborts the whole run on an unreadable or vanished file (measured, gawk). On rocket's real tree: cold 155 ms vs 180 ms, warm 43 ms vs 88 ms.

projects.tsv is v2: a '# tmux-lives projects v2' first line, then dir, key mtime, interactive mtime, cwd. A cache without the header is ignored whole, so rows that meant 'newest transcript of any kind' are never trusted. The suites' real-cache brackets read the folder as a row's last field and count data rows under the header.

Tests: the M-7 stderr guard gets a trigger that still prints (a sort on the app's PATH; tmux gives a new pane its creating client's PATH), and the \$HOME-dotfiles guard moves to a project beside \$HOME, which can no longer be a project itself."
```

---

### Task 3: The busy check — worktrees, and projects that are not repositories

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_landing_model`: the busy set, and the loop over discovery rows.
- Test: `tests/test-tmux-categorize.fish` — a new block before Task 2's `$HOME`-dotfiles block.

**Interfaces:**
- Consumes: `__tcz_claude_cwds` (existing: the cwd of every pane running claude, one `list-panes -a` call), `__tcz_claude_project_of` (Task 1).
- Produces: `__tcz_landing_model <self> [-- <rows>]` (signature unchanged) hides a project when a claude pane's cwd is the project folder, maps to it (repo root, or a worktree's main repo), or — for a project folder with no `.git` of its own — lies anywhere below it.

- [ ] **Step 1: Write the failing tests.** In `tests/test-tmux-categorize.fish`, insert before the line `# --- chooser v2: a claude below a $HOME dotfiles repo marks nothing else busy ---`:

```fish
# --- chooser v2: which projects count as running (the busy check) ---
# Projects go to the model directly (-- rows); the claude panes run the suite's fake claude.
fresh_server
set -l bz /tmp/tcz-bz-$fish_pid
rm -rf $bz
mkdir -p $bz/nonrepo/api/.git $bz/nonrepo/api/src $bz/repo/.git/worktrees/w $bz/repo/vendor/lib/.git $bz/w/src $bz/quiet
printf 'gitdir: %s/repo/.git/worktrees/w\n' $bz > $bz/w/.git
command tmux -L $sock new-session -d -s bz1 -c $bz/nonrepo/api/src "$shimdir/claude --enable-auto-mode"
command tmux -L $sock new-session -d -s bz2 -c $bz/w/src "$shimdir/claude --enable-auto-mode"
sleep 0.5
set -l bznow (date +%s)
set -l bzm (__tcz_landing_model x -- (printf '%s\t%s' $bz/nonrepo $bznow) (printf '%s\t%s' $bz/repo $bznow) (printf '%s\t%s' $bz/quiet $bznow))
set -l bznr (string match -q -- "$bz/nonrepo"\t'*' $bzm; and echo listed; or echo hidden)
set -l bzwt (string match -q -- "$bz/repo"\t'*' $bzm; and echo listed; or echo hidden)
set -l bzq (string match -q -- "$bz/quiet"\t'*' $bzm; and echo listed; or echo hidden)
t "busy: a project that is no git repo runs when claude works anywhere below it (its api/ is a repo of its own)" "hidden listed" "$bznr $bzq"
t "busy: a repo runs when claude works in a linked worktree of it" "hidden listed" "$bzwt $bzq"
command tmux -L $sock kill-session -t =bz2
command tmux -L $sock new-session -d -s bz3 -c $bz/repo/vendor/lib "$shimdir/claude --enable-auto-mode"
sleep 0.5
set -l bzm2 (__tcz_landing_model x -- (printf '%s\t%s' $bz/repo $bznow))
set -l bzrepo (string match -q -- "$bz/repo"\t'*' $bzm2; and echo listed; or echo hidden)
t "busy (non-regression): a claude in a repo nested inside a repo project leaves that project listed" listed "$bzrepo"
rm -rf $bz
cleanup
```

- [ ] **Step 2: Run them and watch them fail.** `bash artifacts/focus.sh '# --- chooser v2: which projects count as running' '# --- landing fix round 1: discovery sweeps'`. Expected: 2 `FAIL` lines — `busy: a project that is no git repo runs …` and `busy: a repo runs when claude works in a linked worktree of it`, both `got [listed listed]`. Passing by design: `busy (non-regression): a claude in a repo nested inside a repo project …` and the dotfiles test.

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`, inside `__tcz_landing_model`:

**Edit 3.1**

Find (exactly once):

```fish
    # A project is running when a claude pane sits in its folder, or below it
    # in a repo rooted there. A generic root ($HOME via a dotfiles repo, /,
    # /tmp) is no project -- the same rule __tcz_project_name applies.
    set -l busy
    for cwd in (__tcz_claude_cwds)
        set -a busy $cwd
        set -l root (__tcz_git_root $cwd)
        test -n "$root"; and not __tcz_generic_dir "$root"; and set -a busy $root
    end
```

Replace with:

```fish
    # A project is running when a claude pane works on it:
    # - in its folder, or anywhere in the repo or worktree that maps to it (__tcz_claude_project_of);
    # - for a project that is no git repo (~/Work/myEMS, whose api/ and web/ are repos), anywhere below it.
    set -l cwds (__tcz_claude_cwds)
    set -l busy $cwds
    for cwd in $cwds
        set -l proj (__tcz_claude_project_of $cwd)
        test -n "$proj"; and set -a busy $proj
    end
```

**Edit 3.2**

Find (exactly once):

```fish
        test (count $f) -eq 2; or continue
        contains -- $f[1] $busy; and continue
        test -n "$now"; or set now (date +%s)
```

Replace with:

```fish
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
```

- [ ] **Step 4: Run them and watch them pass.** Same command: `ALL PASS`. Mutation check: replace `if not test -e "$f[1]/.git"` with `if true` → `busy (non-regression): a claude in a repo nested inside a repo project …` fails (`got [hidden]`); restore and `diff`.

- [ ] **Step 5: Gate.** Full categorize suite, then all nine suites in both modes; counts unchanged.

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): a project runs when claude works in its worktree or below a non-repo project" -m "The chooser's busy check maps each running claude's cwd through __tcz_claude_project_of, the mapping discovery uses, so a claude in a linked worktree hides its main repository: the worktree's own git root never equals the repo. A project that is no git repo (~/Work/myEMS, whose api/ and web/ are repos of their own) is busy when claude runs anywhere below it. A repo project keeps the old rule: a claude in a nested repo inside it does not hide it."
```

---

### Task 4: Keys and layout — `n` replaces the "new shell" row, a border above the legend, an empty list is safe

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_landing_model` (no new-shell row), `__tcz_landing_info`, `__tcz_popup_list_lines`, `__tcz_popup_frame`, `__tcz_landing_paint`, a new `__tcz_landing_border`, the `__tcz_landing` loop, `__tcz_popup_readkey`.
- Test: `tests/test-tmux-popup.fish`, `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Consumes: `__tcz_landing_new_shell <client>` (existing: a new general session in `$HOME`, removed again if the switch fails), `__tcz_legend_row`, `__tcz_popup_emit`, `__tcz_popup_frame`.
- Produces:
  - `__tcz_popup_readkey` returns the token `n` for the byte `n`. `__tcz_popup` and `__tcz_theme_picker` have no `case n`, so it stays a no-op there, as `other` was; in the theme picker's held-move drains an `n` ends the drain exactly as `other` did. The seed editor has its own reader and is untouched.
  - `__tcz_landing_border <listw> <prevw> <cols>` — prints one color-240 rule, `cols - 1` visible columns, with `┴` at column `listw + 1` when `prevw > 0`.
  - `__tcz_landing_paint <sel> <rows> <cols> -- <model>` paints `rows - 2` frame lines, the border, then the legend `↑↓ move  ⏎ open  n new  r resume  x kill  d detach`.
  - `__tcz_landing_model` emits no `new` row; the loop never leaves `sel` below 0.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-tmux-popup.fish`:

**Edit 4a.1** — list_lines: the landing list has no new-shell row any more

Find (exactly once):

```fish
set -g LLAND (printf '/p/x\tproject\t0\t0\tx · 2d\nnew\tnew\t0\t0\tnew shell\n' | __tcz_popup_list_lines 40 9 '')
```

Replace with:

```fish
set -g LLAND (printf '/p/x\tproject\t0\t0\tx · 2d\n' | __tcz_popup_list_lines 40 9 '')
```

**Edit 4a.2**

Find (exactly once):

```fish
t "list_lines: new rule is colour 8" 1 (string match -q '*38;5;8m╭── new ─*' -- "$LLAND[3]"; and echo 1; or echo 0)
```

Delete it, lines and all.

**Edit 4a.3** — paint: no new row; the frame is two rows shorter (border + legend)

Find (exactly once):

```fish
set -g LPM (printf '/tmp/tcz-pa\tproject\t0\t%s\tpa · 2h' (math (date +%s) - 7200)) \
    (printf '/tmp/tcz-pb\tproject\t0\t%s\tpb · 5h' (math (date +%s) - 18000)) \
    (printf 'new\tnew\t0\t0\tnew shell')
```

Replace with:

```fish
set -g LPM (printf '/tmp/tcz-pa\tproject\t0\t%s\tpa · 2h' (math (date +%s) - 7200)) \
    (printf '/tmp/tcz-pb\tproject\t0\t%s\tpb · 5h' (math (date +%s) - 18000))
```

**Edit 4a.4**

Find (exactly once):

```fish
__tcz_landing_paint 2 24 80 -- $LPM > $LPOUT
set -l lp1 (test (wc -c < $LPOUT) -gt 0; and echo 1; or echo 0)
__tcz_landing_paint 2 24 80 -- $LPM > $LPOUT
```

Replace with:

```fish
__tcz_landing_paint 1 24 80 -- $LPM > $LPOUT
set -l lp1 (test (wc -c < $LPOUT) -gt 0; and echo 1; or echo 0)
set -l lprows (count $__tcz_pe_prev)
set -l lpborder (string match -q '*─┴─*' -- "$__tcz_pe_prev[23]"; and echo 1; or echo 0)
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[24]"); and echo 1; or echo 0)
t "paint: 24 rows -- the frame, a border with ┴ under the divider, then the legend with n new" "24 1 1" "$lprows $lpborder $lplegend"
__tcz_landing_paint 1 24 80 -- $LPM > $LPOUT
```

**Edit 4a.5**

Find (exactly once):

```fish
set -l fa (__tcp_frame_bak 0 33 46 23 '' -- $LPM)
set -l fb (__tcp_frame_bak 1 33 46 23 '' -- $LPM)
```

Replace with:

```fish
set -l fa (__tcp_frame_bak 0 33 46 22 '' -- $LPM)
set -l fb (__tcp_frame_bak 1 33 46 22 '' -- $LPM)
```

**Edit 4a.6**

Find (exactly once):

```fish
set -l lpsome (test (count $fdiff) -gt 0 -a (count $fdiff) -lt 23; and echo 1; or echo 0)
```

Replace with:

```fish
set -l lpsome (test (count $fdiff) -gt 0 -a (count $fdiff) -lt 22; and echo 1; or echo 0)
```

**Edit 4a.7** — draw: no new rows

Find (exactly once):

```fish
# --- landing: the preview column for project and new rows ---
# __tcz_popup_preview is stubbed to a recorder: a project/new row must never
# reach capture-pane, and this suite must never reach a real tmux server.
```

Replace with:

```fish
# --- landing: the preview column for project rows ---
# __tcz_popup_preview is stubbed to a recorder: a project row must never
# reach capture-pane, and this suite must never reach a real tmux server.
```

**Edit 4a.8**

Find (exactly once):

```fish
set -g LDnew (printf 'new\tnew\t0\t0\tnew shell')
```

Delete it, lines and all.

**Edit 4a.9**

Find (exactly once):

```fish
__tcz_popup_draw 0 20 30 8 '' -- $LDnew $LDlive >/dev/null
set -l prec_new (cat $PREC 2>/dev/null)
t "draw: a new row never calls capture-pane" "" "$prec_new"
set -l dproj (__tcz_popup_draw 0 20 30 8 '' -- $LDproj $LDnew | string join \n)
```

Replace with:

```fish
__tcz_popup_draw 0 20 30 8 '' -- $LDproj $LDlive >/dev/null
set -l prec_proj (cat $PREC 2>/dev/null)
t "draw: a project row never calls capture-pane" "" "$prec_proj"
set -l dproj (__tcz_popup_draw 0 20 30 8 '' -- $LDproj $LDlive | string join \n)
```

**Edit 4a.10**

Find (exactly once):

```fish
__tcz_popup_draw 1 20 30 8 '' -- $LDnew $LDlive >/dev/null
```

Replace with:

```fish
__tcz_popup_draw 1 20 30 8 '' -- $LDproj $LDlive >/dev/null
```

**Edit 4a.11**

Find (exactly once):

```fish
set -l li2 (__tcz_landing_info (printf 'new\tnew\t0\t0\tnew shell') 40 8)
set li2 (vis "$li2")
t "landing_info: new shell shows a hint" 1 (string match -q '*shell*' -- "$li2"; and echo 1; or echo 0)
```

Delete it, lines and all.

**Edit 4a.12** — readkey n + guards + border, after the readkey block

Find (exactly once):

```fish
t "readkey CSI right" right (printf '\e[C' | __tcz_popup_readkey 2>/dev/null)
```

Replace with:

```fish
t "readkey CSI right" right (printf '\e[C' | __tcz_popup_readkey 2>/dev/null)

# n: the landing app's new-shell key. The reader is shared, so the other two pickers must
# have no case for it (it stays a harmless no-op there, as `other` was). Bodies captured first.
set -l rkn (printf 'n' | __tcz_popup_readkey 2>/dev/null)
t "readkey n=n (landing: a new shell)" n "$rkn"
set -l rkpop (functions __tcz_popup | string collect)
set -l rkthp (functions __tcz_theme_picker | string collect)
set -l rkland (functions __tcz_landing | string collect)
set -l rkg1 (string match -qr '\bcase .*\bn\b' -- "$rkland"; and echo 1; or echo 0)
set -l rkg2 (string match -qr '\bcase n\b' -- "$rkpop"; and echo 1; or echo 0)
set -l rkg3 (string match -qr '\bcase n\b' -- "$rkthp"; and echo 1; or echo 0)
t "readkey n: the landing loop has a case for n; the session switcher and theme picker have none" "1 0 0" "$rkg1 $rkg2 $rkg3"

# --- landing: the border between the list and the legend ---
set -l lb1 (vis (__tcz_landing_border 33 46 80))
set -l lb2 (vis (__tcz_landing_border 50 0 50))
set -l lb3 (vis (__tcz_landing_border 58 1 60))
t "border: cols-1 wide with ┴ under the divider (col 34 at 80 cols)" "79 ┴" "$(string length -- "$lb1") $(string sub -s 34 -l 1 -- "$lb1")"
t "border: no preview, no ┴" "49 0" "$(string length -- "$lb2") $(string match -q '*┴*' -- "$lb2"; and echo 1; or echo 0)"
t "border: a one-column preview still draws the whole rule" "59 ┴" "$(string length -- "$lb3") $(string sub -s 59 -l 1 -- "$lb3")"
```

In `tests/test-tmux-categorize.fish`, first these edits:

**Edit 4b.1** — model: no new-shell row

Find (exactly once):

```fish
t "model: the last row is new shell" (printf 'new\tnew\t0\t0\tnew shell') "$lm[-1]"
```

Replace with:

```fish
set -l lmnew (string match -- 'new'\t'new'\t'*' $lm)
set -l lmrows (count $lm)
t "model: no new-shell row (n starts one), in a model that has rows" "0 1" "$(count $lmnew) $(test $lmrows -gt 0; and echo 1; or echo 0)"
```

**Edit 4b.2**

Find (exactly once):

```fish
t "app: draws the chooser (a new shell row)" 1 "$ladrawn"
```

Replace with:

```fish
t "app: draws the chooser (its key legend)" 1 "$ladrawn"
```

**Edit 4b.3** — vanished session: the list goes empty, the pointer must come back

Find (exactly once):

```fish
# Enter on a session that vanished after the last snapshot: the switch fails,
# so the app must keep its own session (killing it would detach the tab).
```

Replace with:

```fish
# Enter on a session that vanished after the last snapshot: the switch fails,
# so the app must keep its own session (killing it would detach the tab). The
# list is then empty; the pointer must come back once a session appears.
```

**Edit 4b.4**

Find (exactly once):

```fish
set -l lavon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
set -l lavdraw (__tcg_screen_has "=$lav:" '*▐ new shell*' 50; and echo 1; or echo 0)
t "app: Enter on a vanished session keeps the tab on its landing session, still drawing" "$lav 1" "$lavon $lavdraw"
```

Replace with:

```fish
set -l lavon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
command tmux -L $sock new-session -d -s zz -c /tmp
set -l lavdraw (__tcg_screen_has "=$lav:" '*▐ zz*' 50; and echo 1; or echo 0)
t "app: Enter on a vanished session keeps the tab on its landing; from the empty list the pointer comes back" "$lav 1" "$lavon $lavdraw"
```

**Edit 4b.5** — failed move: n instead of the new-shell row; the stubs record that each mover was reached

Find (exactly once):

```fish
set -l fmcmd "set -g tmux_categorize_test 1; source $lcat; function __tcz_landing_start; return 1; end; function __tcz_landing_new_shell; return 1; end; __tcz_landing"
```

Replace with:

```fish
set -l fmrec /tmp/tcz-fmrec-$fish_pid
rm -f $fmrec
set -l fmcmd "set -g tmux_categorize_test 1; source $lcat; function __tcz_landing_start; echo start >> $fmrec; return 1; end; function __tcz_landing_new_shell; echo shell >> $fmrec; return 1; end; __tcz_landing"
```

**Edit 4b.6**

Find (exactly once):

```fish
for i in (seq 6)
    __tcg_screen_has "=_landing-7:" '*▐ new shell*' 5; and break
    command tmux -L $sock send-keys -t "=_landing-7:" j
end
command tmux -L $sock send-keys -t "=_landing-7:" Enter
sleep 1
set -l fmon2
```

Replace with:

```fish
command tmux -L $sock send-keys -t "=_landing-7:" n
sleep 1
set -l fmon2
```

**Edit 4b.7**

Find (exactly once):

```fish
t "app: a failed project start or new shell keeps the tab on its landing" "_landing-7 _landing-7" "$fmon1 $fmon2"
for p in $fmpids; kill $p 2>/dev/null; end
rm -rf $pj $tmux_lives_project_cache $fmf
```

Replace with:

```fish
set -l fmcalls (cat $fmrec 2>/dev/null | string join ' ')
t "app: a failed project start or new shell keeps the tab on its landing (both movers reached)" "_landing-7 _landing-7 start shell" "$fmon1 $fmon2 $fmcalls"
for p in $fmpids; kill $p 2>/dev/null; end
rm -rf $pj $tmux_lives_project_cache $fmf $fmrec
```

**Edit 4b.8** — PgDn ends on the last row (s5): there is no new-shell row below it

Find (exactly once):

```fish
set -l hk2 (__tcg_screen_has "=$hk:" '*▐ new shell*' 20; and echo 1; or echo 0)
```

Replace with:

```fish
set -l hk2 (__tcg_screen_has "=$hk:" '*▐ s5*' 20; and echo 1; or echo 0)
```

**Edit 4b.9** — typeahead j then text: a second session to move to

Find (exactly once):

```fish
# A move burst followed by text: the move steps once; the text read past it is a burst of its own, drained.
fresh_server
__tcg_kbd_client $tyk 0
```

Replace with:

```fish
# A move burst followed by text: the move steps once; the text read past it is a burst of its own, drained.
fresh_server
command tmux -L $sock new-session -d -s t2 -c /tmp
__tcg_kbd_client $tyk 0
```

**Edit 4b.10**

Find (exactly once):

```fish
set -l tyemoved (__tcg_screen_has "=$tye:" '*▐ new shell*' 1; and echo 1; or echo 0)
```

Replace with:

```fish
set -l tyemoved (__tcg_screen_has "=$tye:" '*▐ t2*' 1; and echo 1; or echo 0)
```

**Edit 4b.11**

Find (exactly once):

```fish
string match -rg '▐ (s[0-9]|new shell)')
```

Replace with:

```fish
string match -rg '▐ (s[0-9])')
```

Then replace the "Enter on new shell" test — everything from the line `# Enter on new shell: the client lands on a fresh gen-N. A live session` up to, not including, the line `# x asks first (n keeps, y kills); d detaches the tab and removes the landing session.` — with this block (and one blank line after it):

```fish
# n: a new general session in $HOME for this tab; its landing session goes.
fresh_server
set -l la2 (__tcz_landing_new)
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =$la2" /dev/null >/dev/null 2>&1 &
set -l la2pids (jobs -p)
__tcg_client_on $la2 >/dev/null
__tcg_ready "=$la2:" '*d detach*'
command tmux -L $sock send-keys -t "=$la2:" n
set -l la2on ''
for i in (seq 30)
    set la2on (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
    string match -q 'gen-*' -- "$la2on"; and break
    sleep 0.1
end
set -l la2gen (string match -q 'gen-*' -- "$la2on"; and echo 1; or echo 0)
set -l la2cwd (command tmux -L $sock display-message -p -t "=$la2on:" '#{pane_current_path}' 2>/dev/null)
set -l la2gone (command tmux -L $sock has-session -t "=$la2" 2>/dev/null; and echo 0; or echo 1)
t "app: n lands the client on a new gen session in \$HOME and its landing session goes" "1 $HOME 1" "$la2gen $la2cwd $la2gone"
for p in $la2pids; kill $p 2>/dev/null; end
cleanup
```

Finally, the chooser-is-drawn glob: every remaining `'*new shell*'` in `tests/test-tmux-categorize.fish` becomes `'*d detach*'` (the legend; drawn in the same paint as the list). Count first — after the edits above there must be exactly 19, and none afterwards:

```bash
grep -c "'\*new shell\*'" tests/test-tmux-categorize.fish        # 19
sed -i "s/'\*new shell\*'/'*d detach*'/g" tests/test-tmux-categorize.fish
grep -c "'\*new shell\*'" tests/test-tmux-categorize.fish        # 0
grep -c "'\*d detach\*'" tests/test-tmux-categorize.fish         # 20 (19 + the n test's own)
```

- [ ] **Step 2: Run them and watch them fail.** Popup suite: 6 `FAIL` lines — `paint: 24 rows -- the frame, a border …` (`got [24 0 0]`), `readkey n=n` (`got [other]`), `readkey n: the landing loop has a case for n …` (`got [0 0 0]`), and the three `border:` assertions (`got [0 …]`). Categorize suite (or `bash artifacts/focus.sh '# --- landing: the model (real server' "# --- hygiene: this suite's own shim dir"`): 5 `FAIL` lines — `model: no new-shell row (n starts one) …` (`got [1 1]`), `app: Enter on a vanished session … the pointer comes back` (`got [<landing> 0]`), `app: n lands the client on a new gen session …` (`got [0 … 0]`), `app: a failed project start or new shell keeps the tab … (both movers reached)` (`got [… start]`), `app: PgDn and PgUp move by pages` (`got [0 1]`). Every other landing test still passes: `d detach` is already in today's legend.

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

**Edit 4c.1** — model: no new-shell row

Find (exactly once):

```fish
live sessions (mark 2 = a client from my device is on it, 1 = some client is, 0 = none), then idle Claude projects, then new shell. Given
```

Replace with:

```fish
live sessions (mark 2 = a client from my device is on it, 1 = some client is, 0 = none), then idle Claude projects (n starts a new shell; there is no row for it). Given
```

**Edit 4c.2**

Find (exactly once):

```fish
        printf '%s\tproject\t0\t%s\t%s · %s\n' $f[1] $f[2] (path basename -- $f[1]) (__tcz_age (math $now - $f[2]))
    end
    printf 'new\tnew\t0\t0\tnew shell\n'
end
```

Replace with:

```fish
        printf '%s\tproject\t0\t%s\t%s · %s\n' $f[1] $f[2] (path basename -- $f[1]) (__tcz_age (math $now - $f[2]))
    end
end
```

**Edit 4c.3** — landing_info: project rows only

Find (exactly once):

```fish
function __tcz_landing_info --argument-names row w h --description 'the preview column for a project or new-shell row: what Enter does, clipped to <w> cols and <h> lines'
```

Replace with:

```fish
function __tcz_landing_info --argument-names row w h --description 'the preview column for a project row: what Enter does, clipped to <w> cols and <h> lines'
```

**Edit 4c.4**

Find (exactly once):

```fish
            set lines '' " $dir" " $MUT""last conversation $age$RST" '' ' ⏎ claude --continue' ' r claude --resume'
        case new
            set lines '' ' new shell' " $MUT""a new session in ~$RST"
    end
```

Replace with:

```fish
            set lines '' " $dir" " $MUT""last conversation $age$RST" '' ' ⏎ claude --continue' ' r claude --resume'
    end
```

**Edit 4c.5** — list_lines: no new category

Find (exactly once):

```fish
        test "$cat" = project; and set c 5      # landing: idle Claude projects
        test "$cat" = new; and set c 8          # landing: new shell
```

Replace with:

```fish
        test "$cat" = project; and set c 5      # landing: idle Claude projects
```

**Edit 4c.6** — frame: project rows preview their info

Find (exactly once):

```fish
        if contains -- "$f[2]" project new
            set right (__tcz_landing_info "$selrow" $prevw $rows)
```

Replace with:

```fish
        if test "$f[2]" = project
            set right (__tcz_landing_info "$selrow" $prevw $rows)
```

**Edit 4c.7** — paint

Find (exactly once):

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> -- <model lines...>: paint the landing frame, legend last, through the diff emitter.
```

Replace with:

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> -- <model lines...>: paint the landing frame, then a border, then the key legend, through the diff emitter.
```

**Edit 4c.8**

Find (exactly once):

```fish
    if test $lay[2] -gt 0; and not contains -- "$f[2]" project new
        set cap
```

Replace with:

```fish
    if test $lay[2] -gt 0; and test -n "$f[1]"; and test "$f[2]" != project
        set cap
```

**Edit 4c.9**

Find (exactly once):

```fish
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 1) '' -- $model)
    set -l legend (__tcz_legend_row 10 '↑↓' move '⏎' open r resume x kill d detach)
    __tcz_popup_emit $frame (__tcz_popup_truncate "$legend" (math $cols - 1))
end
```

Replace with:

```fish
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) '' -- $model)
    set -l legend (__tcz_legend_row 10 '↑↓' move '⏎' open n new r resume x kill d detach)
    __tcz_popup_emit $frame (__tcz_landing_border $lay[1] $lay[2] $cols) (__tcz_popup_truncate "$legend" (math $cols - 1))
end

function __tcz_landing_border --argument-names listw prevw cols --description 'pure: the rule between the landing list and its key legend: <cols> - 1 wide (as the legend), with ┴ under the list/preview divider when there is a preview'
    set -l w (math $cols - 1)
    set -l line (string repeat -n $w ─)
    if test $prevw -gt 0; and test $listw -lt $w
        # Quoted: a zero-width repeat is an empty list, which would empty an unquoted concatenation.
        set -l left (string repeat -n $listw ─)
        set -l right (string repeat -n (math $w - $listw - 1) ─)
        set line "$left┴$right"
    end
    printf '\e[38;5;240m%s\e[0m' "$line"
end
```

**Edit 4c.10** — loop: clamp the pointer (the list can now be empty), guard PgDn, n key

Find (exactly once):

```fish
            if test -n "$at"
                set sel (math $at - 1)
            else if test $sel -ge (count $model)
                set sel (math (count $model) - 1)
            end
```

Replace with:

```fish
            if test -n "$at"
                set sel (math $at - 1)
            else if test $sel -ge (count $model)
                set sel (math (count $model) - 1)
                test $sel -lt 0; and set sel 0          # an empty list: no row, never -1
            end
```

**Edit 4c.11**

Find (exactly once):

```fish
            case pgdn
                set sel (math "min($n - 1, $sel + max(1, $rows - 3))")
```

Replace with:

```fish
            case pgdn
                test $n -gt 0; and set sel (math "min($n - 1, $sel + max(1, $rows - 3))")
```

**Edit 4c.12**

Find (exactly once):

```fish
            case enter r
                set stale 1; set pass 0
                set -l client (__tcz_landing_client "$self")
                test -n "$client"; or continue
                switch $row[2]
                    case project
                        set -l how continue
                        test $tok = r; and set how resume
                        __tcz_landing_start $row[1] $how $client
                    case new
                        test $tok = enter; or continue
                        __tcz_landing_new_shell $client
                    case '*'
                        test $tok = enter; or continue
                        tmux switch-client -c $client -t "=$row[1]" 2>/dev/null
                end
```

Replace with:

```fish
            case enter r n
                set stale 1; set pass 0
                set -l client (__tcz_landing_client "$self")
                test -n "$client"; or continue
                if test $tok = n
                    __tcz_landing_new_shell $client
                else if test "$row[2]" = project
                    set -l how continue
                    test $tok = r; and set how resume
                    __tcz_landing_start $row[1] $how $client
                else
                    test $tok = enter; and test -n "$row[1]"; or continue
                    tmux switch-client -c $client -t "=$row[1]" 2>/dev/null
                end
```

**Edit 4c.13** — readkey: n

Find (exactly once):

```fish
function __tcz_popup_readkey --argument-names mode --description 'read one keystroke -> up|down|pgup|pgdn|left|right|v|w|V|s|S|e|E|d|D|o|O|p|P|m|M|a|r|b|t|z|c|tab|enter|cancel|kill|timeout|other;
```

Replace with:

```fish
function __tcz_popup_readkey --argument-names mode --description 'read one keystroke -> up|down|pgup|pgdn|left|right|v|w|V|s|S|e|E|d|D|o|O|p|P|m|M|a|r|b|t|z|c|n|tab|enter|cancel|kill|timeout|other;
```

**Edit 4c.14**

Find (exactly once):

```fish
        case 63; echo c; return                      # c (theme-picker: retired — unused, harmless no-op)
```

Replace with:

```fish
        case 63; echo c; return                      # c (theme-picker: retired — unused, harmless no-op)
        case 6e; echo n; return                      # n (landing: a new shell; no case in the other pickers)
```

- [ ] **Step 4: Run them and watch them pass.** Both suites: `ALL PASS`. Mutation check: delete the line `test $sel -lt 0; and set sel 0          # an empty list: no row, never -1` → only `app: Enter on a vanished session …` fails (`got [<landing> 0]`: the pointer stays at -1 after the list empties); restore and `diff`.

- [ ] **Step 5: Gate.** All nine suites in both modes; counts unchanged.

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): n for a new shell, a border above the legend" -m "The chooser's 'new shell' row is gone; n starts a new general session in \$HOME instead (__tcz_landing_new_shell, as the row did). The shared key reader maps the byte n to the token n; the session switcher and the theme picker have no case for it, so it stays a no-op there, as 'other' was, and the popup suite pins that.

A border (__tcz_landing_border, color 240 like the divider, with a ┴ under it) separates the key legend from the list and preview; the frame is two rows shorter.

With no row that always exists, the list can be empty: the pointer clamps to 0 instead of -1 (fish rejects the index 0, so a -1 pointer lost its row for good), PgDn ignores an empty list, and Enter on no row does nothing. Tests: the chooser-is-drawn glob is now the legend; the PgDn test ends on the last session; the failed-move test records that each mover was reached."
```

---

### Task 5: Project groups, and the `older (N)` row

**Files:**
- Modify: `functions/tmux-categorize.fish` — a file-level `__tcz_landing_groups`; `__tcz_landing_model`; new `__tcz_landing_group` and `__tcz_landing_older_after`; `__tcz_landing_info`; `__tcz_popup_list_lines`; `__tcz_popup_frame`; `__tcz_landing_paint`; the `__tcz_landing` loop.
- Test: `tests/test-tmux-popup.fish`, `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Consumes: `__tcz_landing_group_roots` (Task 1), `__tcz_landing_model` (Tasks 3–4), `__tcz_age <seconds>` (existing).
- Produces:
  - `__tcz_landing_groups` — global list `projects workspace work other` (display order; a project row's category).
  - `__tcz_landing_group <folder>` — prints `projects`, `workspace` or `work` for a folder below `~/projects`, `~/workspace` or `~/Work`, else `other`.
  - `__tcz_landing_older_after` — prints seconds: the seam `tmux_lives_landing_older_after` when it is a whole number, else `1814400` (21 days).
  - `__tcz_landing_model <self> [--all] [-- <rows>]` — project rows `<folder>\t<group>\t0\t<mtime>\t<basename> · <age>`, grouped in `__tcz_landing_groups` order, newest first within a group; without `--all`, projects older than the threshold are left out and counted in a final `older\tolder\t0\t<N>\tolder (N)`.
  - The loop: Enter on the older row rebuilds with `--all` until the app restarts and puts the pointer on the first row it revealed.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-tmux-popup.fish`:

**Edit 5a.1**

Find (exactly once):

```fish
set -l pr (printf '/p/x\tproject\t0\t0\tx · 2d\n' | __tcz_popup_list_lines 40 0 '' | string join \n)
```

Replace with:

```fish
set -l pr (printf '/p/x\tother\t0\t0\tx · 2d\n' | __tcz_popup_list_lines 40 0 '' | string join \n)
```

**Edit 5a.2**

Find (exactly once):

```fish
t "list_lines: project rule" 1 (string match -q '*── idle claude*' -- "$pr"; and echo 1; or echo 0)
```

Replace with:

```fish
t "list_lines: a project group's rule reads the group's name" 1 (string match -q '*── other *' -- "$pr"; and echo 1; or echo 0)
```

**Edit 5a.3**

Find (exactly once):

```fish
set -g LLAND (printf '/p/x\tproject\t0\t0\tx · 2d\n' | __tcz_popup_list_lines 40 9 '')
t "list_lines: project rule is colour 5" 1 (string match -q '*38;5;5m╭── idle claude *' -- "$LLAND[1]"; and echo 1; or echo 0)
set -l lpw (string length --visible -- (vis "$LLAND[1]"))
set -l lpf (string match -qr '^╭── idle claude ─+$' -- (vis "$LLAND[1]"); and echo 1; or echo 0)
t "list_lines: the idle claude rule fills to listwidth" "40 1" "$lpw $lpf"
t "list_lines: project row border is colour 5" 1 (string match -q '*38;5;5m│*' -- "$LLAND[2]"; and echo 1; or echo 0)
```

Replace with:

```fish
# [1] projects rule [2] a [3] other rule [4] b [5] older rule [6] older (3)
set -g LLAND (printf '/h/projects/a\tprojects\t0\t0\ta · 2d\n/h/x/b\tother\t0\t0\tb · 3d\nolder\tolder\t0\t3\tolder (3)\n' | __tcz_popup_list_lines 40 9 '')
t "list_lines: a project group's rule is color 5" 1 (string match -q '*38;5;5m╭── projects *' -- "$LLAND[1]"; and echo 1; or echo 0)
set -l lpw (string length --visible -- (vis "$LLAND[1]"))
set -l lpf (string match -qr '^╭── projects ─+$' -- (vis "$LLAND[1]"); and echo 1; or echo 0)
t "list_lines: the group rule fills to listwidth" "40 1" "$lpw $lpf"
t "list_lines: project row border is colour 5" 1 (string match -q '*38;5;5m│*' -- "$LLAND[2]"; and echo 1; or echo 0)
set -l lpo (string match -qr '^╭── other ─+$' -- (vis "$LLAND[3]"); and echo 1; or echo 0)
t "list_lines (non-regression): the next group opens its own rule" 1 "$lpo"
set -l lol8 (string match -q '*38;5;8m╭─*' -- "$LLAND[5]"; and echo 1; or echo 0)
set -l lolp (string match -qr '^╭─+$' -- (vis "$LLAND[5]"); and echo 1; or echo 0)
set -l lolr (string match -q '*older (3)*' -- (vis "$LLAND[6]"); and echo 1; or echo 0)
t "list_lines: the older row sits under a plain color-8 rule and reads older (N)" "1 1 1" "$lol8 $lolp $lolr"
```

**Edit 5a.4**

Find (exactly once):

```fish
set -g LPM (printf '/tmp/tcz-pa\tproject\t0\t%s\tpa · 2h' (math (date +%s) - 7200)) \
    (printf '/tmp/tcz-pb\tproject\t0\t%s\tpb · 5h' (math (date +%s) - 18000))
```

Replace with:

```fish
set -g LPM (printf '/tmp/tcz-pa\tother\t0\t%s\tpa · 2h' (math (date +%s) - 7200)) \
    (printf '/tmp/tcz-pb\tother\t0\t%s\tpb · 5h' (math (date +%s) - 18000))
```

**Edit 5a.5**

Find (exactly once):

```fish
set -g LDproj (printf '/tmp/tcz-some/proj\tproject\t0\t%s\tproj · 2h' (math (date +%s) - 7200))
__tcz_popup_draw 0 20 30 8 '' -- $LDproj $LDlive >/dev/null
set -l prec_proj (cat $PREC 2>/dev/null)
t "draw: a project row never calls capture-pane" "" "$prec_proj"
```

Replace with:

```fish
set -g LDproj (printf '/tmp/tcz-some/proj\tother\t0\t%s\tproj · 2h' (math (date +%s) - 7200))
set -g LDold (printf 'older\tolder\t0\t2\tolder (2)')
__tcz_popup_draw 0 20 30 8 '' -- $LDproj $LDlive >/dev/null
__tcz_popup_draw 0 20 30 8 '' -- $LDold $LDlive >/dev/null
set -l prec_proj (cat $PREC 2>/dev/null)
t "draw: a project row or the older row never calls capture-pane" "" "$prec_proj"
```

**Edit 5a.6**

Find (exactly once):

```fish
set -l li1 (__tcz_landing_info (printf '/p/x\tproject\t0\t%s\tx · 2h' (math $linow - 7200)) 40 8)
```

Replace with:

```fish
set -l li1 (__tcz_landing_info (printf '/p/x\tother\t0\t%s\tx · 2h' (math $linow - 7200)) 40 8)
```

**Edit 5a.7**

Find (exactly once):

```fish
set -l li3 (__tcz_landing_info (printf '/a/very/long/folder/path/that/overflows\tproject\t0\t%s\tpath · 2h' $linow) 12 2)
```

Replace with:

```fish
set -l li3 (__tcz_landing_info (printf '/a/very/long/folder/path/that/overflows\tother\t0\t%s\tpath · 2h' $linow) 12 2)
```

**Edit 5a.8**

Find (exactly once):

```fish
t "landing_info: project names both keys" 1 (string match -q '*--continue*--resume*' -- "$li1"; and echo 1; or echo 0)
```

Replace with:

```fish
t "landing_info: project names both keys" 1 (string match -q '*--continue*--resume*' -- "$li1"; and echo 1; or echo 0)
set -l li4 (__tcz_landing_info (printf 'older\tolder\t0\t3\tolder (3)') 40 8)
set li4 (vis "$li4")
t "landing_info: the older row says how many, how old, and what Enter does" 1 (string match -q '*3 older projects*over 3w ago*show them*' -- "$li4"; and echo 1; or echo 0)
```

In `tests/test-tmux-categorize.fish`, the model test's project row now carries its group:

```fish
t "model: an idle project row" "project 0 tcz-lm-idle-$fish_pid · 2h" (string split -f2,3,5 \t -- "$lmir" | string join ' ')
```

becomes

```fish
t "model: an idle project row (its category is its group)" "other 0 tcz-lm-idle-$fish_pid · 2h" (string split -f2,3,5 \t -- "$lmir" | string join ' ')
```

Insert before the line `# --- landing: the running app, driven through a real pty client ---`:

```fish

# --- chooser v2: projects grouped by where they live; old ones behind one row ---
set -g __tcg_lg_home_save $HOME
set -g HOME /h
set -l lgs (for p in /h/projects/a /h/projects/a/b /h/workspace/w /h/Work/k /h/projects /h/x /tmp/y; __tcz_landing_group $p; end)
set -g HOME $__tcg_lg_home_save
set -e __tcg_lg_home_save
t "group: by where the project lives (below ~/projects, ~/workspace, ~/Work), else other" "projects projects workspace work other other other" "$lgs"

function __tcg_gm_shape --description 'model rows -> "<category>:<folder basename>" per project row, "older:<N>" for the older row; live rows left out'
    for r in $argv
        set -l f (string split \t -- $r)
        switch $f[2]
            case claude running general
                continue
            case older
                echo "older:$f[4]"
            case '*'
                echo "$f[2]:"(path basename -- $f[1])
        end
    end
end
fresh_server
set -g __tcg_gm_home_save $HOME
set -l gm /tmp/tcz-gm-$fish_pid
set -g HOME $gm/home
set -l gmnow (date +%s)
set -l gmrows (printf '%s\t%s' $gm/oa (math $gmnow - 60)) \
    (printf '%s\t%s' $HOME/Work/ka (math $gmnow - 120)) \
    (printf '%s\t%s' $HOME/workspace/wa (math $gmnow - 180)) \
    (printf '%s\t%s' $HOME/projects/pa (math $gmnow - 240)) \
    (printf '%s\t%s' $HOME/projects/pold (math "$gmnow - 30 * 86400")) \
    (printf '%s\t%s' $gm/oold (math "$gmnow - 22 * 86400"))
set -l gmm (__tcz_landing_model x -- $gmrows)
set -l gmall (__tcz_landing_model x --all -- $gmrows)
set -g tmux_lives_landing_older_after 100
set -l gmseam (__tcz_landing_model x -- $gmrows)
set -e tmux_lives_landing_older_after
set -g HOME $__tcg_gm_home_save
set -e __tcg_gm_home_save
set -l gms1 (__tcg_gm_shape $gmm)
set -l gms2 (__tcg_gm_shape $gmall)
set -l gms3 (__tcg_gm_shape $gmseam)
t "model: projects by group in order (projects, workspace, work, other); 21+ days old behind one older row" "projects:pa workspace:wa work:ka other:oa older:2" "$gms1"
t "model: --all lists the old ones in their groups, newest first, and no older row" "projects:pa projects:pold workspace:wa work:ka other:oa other:oold" "$gms2"
t "model: the age limit is a seam (tmux_lives_landing_older_after, seconds)" "other:oa older:5" "$gms3"
functions -e __tcg_gm_shape
cleanup
```

Insert before the line `# x asks first (n keeps, y kills); d detaches the tab and removes the landing session.`:

```fish
# The older row: Enter reveals the hidden projects in their groups, pointer on the first one revealed.
# A live session literally named `older` sits above it: the pointer follows rows by target AND category.
fresh_server
command tmux -L $sock new-session -d -s older -c /tmp
set -l pj $tmux_lives_claude_projects_dir
set -l ol /tmp/tcz-ol-$fish_pid
rm -rf $pj $ol; rm -f $tmux_lives_project_cache
mkdir -p $pj/-fresh $pj/-stale $ol/tcz-ol-fresh-$fish_pid $ol/tcz-ol-stale-$fish_pid
printf '{"cwd":"%s/tcz-ol-fresh-%s"}\n' $ol $fish_pid > $pj/-fresh/s.jsonl
printf '{"cwd":"%s/tcz-ol-stale-%s"}\n' $ol $fish_pid > $pj/-stale/s.jsonl
touch -d '30 days ago' $pj/-stale/s.jsonl
set -l ola (__tcz_landing_new)
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =$ola" /dev/null >/dev/null 2>&1 &
set -l olpids (jobs -p)
__tcg_client_on $ola >/dev/null
__tcg_ready "=$ola:" '*d detach*'
set -l olrow (__tcg_screen_has "=$ola:" '*older (1)*' 1; and echo 1; or echo 0)
set -l olhid (__tcg_screen_has "=$ola:" "*tcz-ol-stale-$fish_pid*" 1; and echo 0; or echo 1)
t "app: a project 21+ days old hides behind an older (1) row" "1 1" "$olrow $olhid"
for i in (seq 8)
    __tcg_screen_has "=$ola:" '*▐ older (1)*' 5; and break
    command tmux -L $sock send-keys -t "=$ola:" j
end
command tmux -L $sock new-session -d -s zz -c /tmp
set -l olzz (__tcg_screen_has "=$ola:" '*│ zz*' 50; and echo 1; or echo 0)
set -l olkept (__tcg_screen_has "=$ola:" '*▐ older (1)*' 1; and echo 1; or echo 0)
t "app: after a refresh adds a row above it, the pointer stays on the older row (beside a live session named older)" "1 1" "$olzz $olkept"
command tmux -L $sock send-keys -t "=$ola:" Enter
set -l olshow (__tcg_screen_has "=$ola:" "*▐ tcz-ol-stale-$fish_pid*" 30; and echo 1; or echo 0)
set -l olgone (__tcg_screen_has "=$ola:" '*older (1)*' 1; and echo 0; or echo 1)
set -l olon (command tmux -L $sock list-clients -F '#{session_name}' 2>/dev/null)
t "app: Enter on the older row reveals it, pointer on it, the row gone, the tab still on its landing" "1 1 $ola" "$olshow $olgone $olon"
for p in $olpids; kill $p 2>/dev/null; end
rm -rf $pj $ol $tmux_lives_project_cache
cleanup
```

- [ ] **Step 2: Run them and watch them fail.** Popup suite: 11 `FAIL` lines — `list_lines: a project group's rule is color 5`, `list_lines: project row border is colour 5` (an existing description, left as it is), `list_lines: the older row sits under a plain color-8 rule …` (`got [0 0 1]`), `draw: a project row or the older row never calls capture-pane`, `draw: a project row previews its folder`, the five `landing_info:` project and size assertions (a category `other` row gets no lines yet), and `landing_info: the older row says how many …`. Passing by design: `list_lines: a project group's rule reads the group's name` and `list_lines (non-regression): the next group opens its own rule`. Categorize suite (or `bash artifacts/focus.sh '# --- landing: the model (real server' '# --- landing: the running app' '# The older row: Enter reveals' '# x asks first'`): 8 `FAIL` lines — `model: an idle project row (its category is its group)`, `group: by where the project lives …` (`got []`), the three `model:` group/older/seam assertions, and the three `app:` older-row assertions.

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

**Edit 5b.1** — the group list, next to the other file-level constants

Find (exactly once):

```fish
set -g __tcz_landing_cmd sh -c 'exec fish --no-config "$0" landing 2>/dev/null' $__tcz_self
```

Replace with:

```fish
set -g __tcz_landing_cmd sh -c 'exec fish --no-config "$0" landing 2>/dev/null' $__tcz_self
# The chooser's project groups, in display order: a project row's category is its group.
set -g __tcz_landing_groups projects workspace work other
```

**Edit 5b.2** — model

Find (exactly once):

```fish
function __tcz_landing_model --argument-names self --description '__tcz_landing_model <self> [-- <discovery rows>]: rows "target\tcategory\tmark\tlast\tdisplay" for the landing session <self> -- live sessions (mark 2 = a client from my device is on it, 1 = some client is, 0 = none), then idle Claude projects (n starts a new shell; there is no row for it). Given "--", the discovery rows ("folder\tmtime") are taken as passed instead of read here.'
    set -l TAB (printf '\t')
```

Replace with:

```fish
function __tcz_landing_model --argument-names self --description '__tcz_landing_model <self> [--all] [-- <discovery rows>]: rows "target\tcategory\tmark\tlast\tdisplay" for the landing session <self> -- live sessions (claude/running/general; mark 2 = a client from my device is on it, 1 = some client is, 0 = none), then idle Claude projects by group (the category is the group, __tcz_landing_groups), newest first within one. A project whose last conversation is older than __tcz_landing_older_after is left out and counted in one final row "older\tolder\t0\t<N>\tolder (N)"; --all lists those in their groups instead. n starts a new shell; there is no row for it. Given "--", the discovery rows ("folder\tmtime") are taken as passed instead of read here.'
    set -e argv[1]
    set -l all 0
    test "$argv[1]" = --all; and set all 1; and set -e argv[1]
    set -l TAB (printf '\t')
```

**Edit 5b.3**

Find (exactly once):

```fish
    set -l disc
    if test "$argv[2]" = --
        set disc $argv[3..]
    else
        set disc (__tcz_claude_projects)
    end
    set -l now
    for line in $disc
```

Replace with:

```fish
    set -l disc
    if test "$argv[1]" = --
        set disc $argv[2..]
    else
        set disc (__tcz_claude_projects)
    end
    set -l after (__tcz_landing_older_after)
    set -l now
    set -l pgroups; set -l prows
    set -l nold 0
    for line in $disc
```

**Edit 5b.4**

Find (exactly once):

```fish
        test -n "$now"; or set now (date +%s)
        printf '%s\tproject\t0\t%s\t%s · %s\n' $f[1] $f[2] (path basename -- $f[1]) (__tcz_age (math $now - $f[2]))
    end
end
```

Replace with:

```fish
        test -n "$now"; or set now (date +%s)
        if test $all -eq 0; and test (math $now - $f[2]) -gt $after
            set nold (math $nold + 1)
            continue
        end
        set -l g (__tcz_landing_group $f[1])
        set -a pgroups $g
        set -a prows (printf '%s\t%s\t0\t%s\t%s · %s' $f[1] $g $f[2] (path basename -- $f[1]) (__tcz_age (math $now - $f[2])))
    end
    # Groups in their fixed order; within one, discovery's newest-first order holds.
    for g in $__tcz_landing_groups
        set -l i 0
        for r in $prows
            set i (math $i + 1)
            test "$pgroups[$i]" = $g; and printf '%s\n' $r
        end
    end
    test $nold -gt 0; and printf 'older\tolder\t0\t%s\tolder (%s)\n' $nold $nold
end

function __tcz_landing_group --argument-names folder --description 'pure: the chooser group of a project folder -- projects, workspace or work for a folder below ~/projects, ~/workspace or ~/Work (__tcz_landing_group_roots, in order), else other'
    set -l roots (__tcz_landing_group_roots)
    for i in 1 2 3
        string match -q -- "$roots[$i]/*" "$folder"; and echo $__tcz_landing_groups[$i]; and return 0
    end
    echo other
end

function __tcz_landing_older_after --description 'pure: seconds after which an idle project hides behind the chooser'"'"'s older row: the seam tmux_lives_landing_older_after, else 21 days'
    if string match -qr '^[0-9]+$' -- "$tmux_lives_landing_older_after"
        echo $tmux_lives_landing_older_after
    else
        echo 1814400
    end
end
```

**Edit 5b.5** — landing_info: group rows and the older row

Find (exactly once):

```fish
function __tcz_landing_info --argument-names row w h --description 'the preview column for a project row: what Enter does, clipped to <w> cols and <h> lines'
```

Replace with:

```fish
function __tcz_landing_info --argument-names row w h --description 'the preview column for a project row or the older row: what Enter does, clipped to <w> cols and <h> lines'
```

**Edit 5b.6**

Find (exactly once):

```fish
    set -l lines
    switch "$f[2]"
        case project
            set -l dir $f[1]
            string match -q -- "$HOME/*" $dir; and set dir "~"(string sub -s (math (string length -- $HOME) + 1) -- $dir)
            set -l age (__tcz_age (math (date +%s) - $f[4]))
            test "$age" = now; or set age "$age ago"
            set lines '' " $dir" " $MUT""last conversation $age$RST" '' ' ⏎ claude --continue' ' r claude --resume'
    end
```

Replace with:

```fish
    set -l lines
    if contains -- "$f[2]" $__tcz_landing_groups
        set -l dir $f[1]
        string match -q -- "$HOME/*" $dir; and set dir "~"(string sub -s (math (string length -- $HOME) + 1) -- $dir)
        set -l age (__tcz_age (math (date +%s) - $f[4]))
        test "$age" = now; or set age "$age ago"
        set lines '' " $dir" " $MUT""last conversation $age$RST" '' ' ⏎ claude --continue' ' r claude --resume'
    else if test "$f[2]" = older
        set -l noun projects
        test "$f[4]" = 1; and set noun project
        set -l over (__tcz_age (__tcz_landing_older_after))
        set lines '' " $f[4] older $noun" " $MUT""last conversation over $over ago$RST" '' ' ⏎ show them'
    end
```

**Edit 5b.7** — list_lines

Find (exactly once):

```fish
        test "$cat" = project; and set c 5      # landing: idle Claude projects
```

Replace with:

```fish
        contains -- "$cat" $__tcz_landing_groups; and set c 5    # landing: idle Claude projects, by group
        test "$cat" = older; and set c 8                         # landing: the older row
```

**Edit 5b.8**

Find (exactly once):

```fish
            set -l word "── $cat "
            test "$cat" = project; and set word "── idle claude "
```

Replace with:

```fish
            set -l word "── $cat "
            test "$cat" = older; and set word ──       # a plain rule: the row says what it is
```

**Edit 5b.9** — frame + paint

Find (exactly once):

```fish
        if test "$f[2]" = project
            set right (__tcz_landing_info "$selrow" $prevw $rows)
```

Replace with:

```fish
        if contains -- "$f[2]" $__tcz_landing_groups older
            set right (__tcz_landing_info "$selrow" $prevw $rows)
```

**Edit 5b.10**

Find (exactly once):

```fish
    if test $lay[2] -gt 0; and test -n "$f[1]"; and test "$f[2]" != project
        set cap
```

Replace with:

```fish
    if test $lay[2] -gt 0; and test -n "$f[1]"; and not contains -- "$f[2]" $__tcz_landing_groups older
        set cap
```

**Edit 5b.11** — loop

Find (exactly once):

```fish
    set -l pending ''                 # a key the held-key drain read past
```

Replace with:

```fish
    set -l pending ''                 # a key the held-key drain read past
    set -l all                        # --all once the older row was opened: until the app restarts
    set -l shown                      # the targets listed when it was opened, to find the first revealed row
```

**Edit 5b.12**

Find (exactly once):

```fish
            set model (__tcz_landing_model "$self" -- $disc)
            set -l at (contains -i -- "$keep" (string replace -r '^([^\t]*\t[^\t]*)\t.*$' '$1' -- $model))
            if test -n "$at"
                set sel (math $at - 1)
            else if test $sel -ge (count $model)
                set sel (math (count $model) - 1)
                test $sel -lt 0; and set sel 0          # an empty list: no row, never -1
            end
```

Replace with:

```fish
            set model (__tcz_landing_model "$self" $all -- $disc)
            set -l at (contains -i -- "$keep" (string replace -r '^([^\t]*\t[^\t]*)\t.*$' '$1' -- $model))
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
```

**Edit 5b.13**

Find (exactly once):

```fish
            case enter r n
                set stale 1; set pass 0
```

Replace with:

```fish
            case enter r n
                if test $tok = enter; and test "$row[2]" = older
                    set all --all
                    set shown (string split -f1 \t -- $model)
                    set stale 1
                    continue
                end
                set stale 1; set pass 0
```

**Edit 5b.14**

Find (exactly once):

```fish
                else if test "$row[2]" = project
                    set -l how continue
```

Replace with:

```fish
                else if contains -- "$row[2]" $__tcz_landing_groups
                    set -l how continue
```

- [ ] **Step 4: Run them and watch them pass.** Both suites: `ALL PASS`.

- [ ] **Step 5: Gate.** All nine suites in both modes; counts unchanged.

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(landing): group idle projects by where they live; hide 21+ days behind older (N)" -m "Idle Claude projects list in four groups, in order: projects (~/projects), workspace (~/workspace), work (~/Work), other; a group with no rows is not shown, and each keeps discovery's newest-first order. A project row's category is its group (__tcz_landing_groups), so the list renderer draws one rule per group, named after it, in the idle-project color; the old 'project' category is gone.

A project whose last interactive conversation is more than 21 days old is left out and counted in one final row, older (N), under a plain color-8 rule. Enter on it rebuilds the model with --all until the app restarts and puts the pointer on the first project it revealed; the pointer still follows rows by target and category, so a live session named 'older' never takes the row's place. The age limit has a seam, tmux_lives_landing_older_after (seconds), like the idle seams."
```

---

### Task 6: A held arrow repaints the list only

> ⚠ **Controller note (2026-10-01): the drafted steps below measured only 9.8–10.6 → 10.1–13.2 rows/s.** The user's complaint ("holding up/down seems a bit sluggish") is about speed, and ~10 rows/s means each held step still costs ~80–100 ms with no preview capture at all. Do the steps below, then **profile one held step** (list build, model rebuild, paint, the burst/drain reads) and remove the dominant cost until a held Down reaches **≥ 25 rows/s** on the rocket test server — or report precisely what blocks it. Keep the picker Input rule (one step per frame, queued repeats discarded, never escalate the move poll) and the type-ahead/settle guarantees.

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_frame` (may keep the last preview column), `__tcz_landing_paint` (a `<hold>` argument), the `__tcz_landing` loop (the hold state).
- Test: `tests/test-tmux-popup.fish` — the four existing painter calls take `<hold>`; a new block. `tests/test-tmux-categorize.fish` — an end-to-end hold test that also prints the before/after rate.

**Interfaces:**
- Consumes: `__tcz_landing_paint`, `__tcz_popup_frame` (Tasks 4–5).
- Produces:
  - `__tcz_landing_paint <sel> <rows> <cols> <hold> -- <model>` — with `<hold>` = 1 it skips the capture and asks the frame to keep its preview column; `<hold>` is part of the skip key, so the quiet repaint of the same row is never skipped.
  - `__tcz_popup_frame` honors `__tcz_pf_keep` (set to `<hold>` by the painter around its call, reset to 0 after): when 1 and the preview size is unchanged, the right column is `__tcz_pf_right` (the last one built); otherwise it builds the column and stores `__tcz_pf_right` and `__tcz_pf_rdims` (`"<prevw> <rows>"`). The session switcher never sets it.
  - The loop: any move token sets `hold` 1; while held, the read waits 0.2 s; a timeout then clears the hold and repaints with the preview — the token `quiet`, which is neither a refresh nor idle time.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-tmux-popup.fish`, the painter now takes `<hold>` after `<cols>`. Its four existing calls,

```fish
__tcz_landing_paint 1 24 80 -- $LPM
__tcz_landing_paint 0 24 80 -- $LPM
```

(three of the first form, one of the second, each followed by a redirect) become `__tcz_landing_paint 1 24 80 0 -- $LPM` and `__tcz_landing_paint 0 24 80 0 -- $LPM`:

```bash
grep -c '__tcz_landing_paint [01] 24 80 -- \$LPM' tests/test-tmux-popup.fish      # 4
sed -i 's/__tcz_landing_paint \([01]\) 24 80 -- \$LPM/__tcz_landing_paint \1 24 80 0 -- $LPM/' tests/test-tmux-popup.fish
grep -c '__tcz_landing_paint [01] 24 80 0 -- \$LPM' tests/test-tmux-popup.fish    # 4
```

Then insert, after the three lines that end the "preview column for project rows" block,

```fish
functions -e __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak
```

(they occur once at this point; one blank line first) this block:

```fish

# --- landing: a held move rebuilds the list only; the preview catches up when input is quiet ---
# __tcz_popup_preview and tmux are stubbed to recorders: this suite never reaches a tmux server.
functions -c __tcz_popup_preview __tcp_preview_bak
set -g PREC2 /tmp/tcz-prec2-$fish_pid
set -g TREC /tmp/tcz-trec-$fish_pid
rm -f $PREC2 $TREC; touch $PREC2 $TREC
function __tcz_popup_preview
    echo $argv[1] >> $PREC2
    printf 'PV-%s\n' $argv[1]
end
set -g HM (printf 'alpha\tgeneral\t0\t0\talpha') (printf 'beta\tgeneral\t0\t0\tbeta')
set -g __tcz_pf_keep 0
set -l hf1 (__tcz_popup_frame 0 20 30 8 '' -- $HM | string join \n)
set -g __tcz_pf_keep 1
set -l hf2 (__tcz_popup_frame 1 20 30 8 '' -- $HM | string join \n)
set -g __tcz_pf_keep 0
set -l hf3 (__tcz_popup_frame 1 20 30 8 '' -- $HM | string join \n)
set -l hcalls (cat $PREC2 | string join ,)
set -l hkept (string match -q '*PV-alpha*' -- "$hf2"; and string match -q '*▐ beta*' -- (vis "$hf2"); and echo 1; or echo 0)
set -l hnew (string match -q '*PV-beta*' -- "$hf3"; and echo 1; or echo 0)
t "frame: with __tcz_pf_keep the pointer moves and the preview column is reused, not captured" "alpha,beta 1 1" "$hcalls $hkept $hnew"
function tmux; echo $argv >> $TREC; end
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 24 80 0 -- $HM > /dev/null
rm -f $PREC2 $TREC; touch $PREC2 $TREC
__tcz_landing_paint 1 24 80 1 -- $HM > /dev/null
set -l hpheld (cat $TREC | string match -e capture-pane | count)
set -l hpprev (cat $PREC2 | count)
__tcz_landing_paint 1 24 80 0 -- $HM > /dev/null
set -l hpquiet $status
set -l hpafter (cat $TREC | string match -e capture-pane | count)
set -l hpprev2 (cat $PREC2 | count)
functions -e tmux
t "paint: a held move captures nothing and keeps the preview; the quiet repaint of that row is not skipped, and captures" "0 0 0 1 1" "$hpheld $hpprev $hpquiet $hpafter $hpprev2"
rm -f $PREC2 $TREC
set -e __tcz_lp_key
functions -e __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak
```

In `tests/test-tmux-categorize.fish`, insert before the line `# --- typeahead: typed-ahead or pasted text never acts in the chooser ---`:

```fish
# --- chooser v2: a held arrow repaints the list only; the preview catches up once input is quiet ---
# 80 sessions whose panes each print MARK-<name>; the app records a timestamp per capture-pane call.
# Down is sent every ~20 ms, like key autorepeat. The rate line is the before/after measurement.
fresh_server
for i in (seq -w 1 80)
    command tmux -L $sock new-session -d -s h$i -c /tmp sh -c "printf 'MARK-h$i\n'; exec sleep 600"
end
command tmux -L $sock kill-session -t =0
set -l hrec /tmp/tcz-hrec-$fish_pid
rm -f $hrec
set -l hcmd "set -g tmux_categorize_test 1; source $lcat; function tmux; contains -- capture-pane \$argv; and date +%s%3N >> $hrec; command tmux \$argv; end; __tcz_landing"
command tmux -L $sock new-session -d -s _landing-5 -c $HOME fish --no-config -c "$hcmd"
sleep 40 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =_landing-5" /dev/null >/dev/null 2>&1 &
set -l hpids (jobs -p)
__tcg_client_on _landing-5 >/dev/null
__tcg_ready "=_landing-5:" '*▐ h01*'
set -l ht0 (date +%s%3N)
for i in (seq 60)
    command tmux -L $sock send-keys -t "=_landing-5:" Down
    sleep 0.02
end
set -l ht1 (date +%s%3N)
sleep 1
set -l hsel (command tmux -L $sock capture-pane -p -t "=_landing-5:" | string match -rg '▐ (h[0-9]+)')
set -l hshown (__tcg_screen_has "=_landing-5:" "*MARK-$hsel*" 20; and echo 1; or echo 0)
set -l hduring 0; set -l hafter 0
for ts in (cat $hrec 2>/dev/null)
    test $ts -ge $ht0; or continue
    if test $ts -le $ht1
        set hduring (math $hduring + 1)
    else
        set hafter (math $hafter + 1)
    end
end
set -l hsteps (math (string replace h '' -- "$hsel") - 1)
echo "# hold: $hsteps rows in "(math $ht1 - $ht0)" ms = "(math --scale 1 "$hsteps * 1000 / ($ht1 - $ht0)")" rows/s; captures during the hold $hduring, after $hafter"
set -l hquiet (test $hduring -le 2; and echo 1; or echo 0)
set -l hcaught (test $hafter -ge 1; and echo 1; or echo 0)
t "app: holding Down captures no preview until input is quiet (2 stragglers allowed), then captures" "1 1" "$hquiet $hcaught"
set -l hselok (string match -qr '^h[0-9]+$' -- "$hsel"; and echo 1; or echo 0)
t "app (non-regression): after release the preview shows the row the pointer is on" "1 1" "$hselok $hshown"
for p in $hpids; kill $p 2>/dev/null; end
rm -f $hrec
cleanup
```

- [ ] **Step 2: Run them and watch them fail.** Popup suite: 3 `FAIL` lines — `paint: a move between two project rows emits only the changed rows` (`got [1 0 0]`: today's painter reads the new `0` as its `--`), `frame: with __tcz_pf_keep …` (`got [alpha,beta,beta 0 1]`), `paint: a held move captures nothing …` (`got [1 1 1 2 1]`). Categorize (or `bash artifacts/focus.sh '# --- chooser v2: a held arrow repaints' '# --- typeahead: typed-ahead'`): 1 `FAIL` — `app: holding Down captures no preview until input is quiet …` (`got [0 1]`); the non-regression one passes. **Record the `# hold:` line** — the before rate (planning run: `16 rows in 1505 ms = 10.6 rows/s; captures during the hold 31, after 1`).

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

**Edit 6.1** — frame: optionally keep the last preview column

Find (exactly once):

```fish
the frame as <rows> lines, each ending in erase-to-EOL. An overflowing list scrolls only to keep the selection in view; the window top persists in __tcz_pd_top across calls.'
```

Replace with:

```fish
the frame as <rows> lines, each ending in erase-to-EOL. An overflowing list scrolls only to keep the selection in view; the window top persists in __tcz_pd_top across calls. With __tcz_pf_keep = 1 the preview column is the last one built (__tcz_pf_right) when its size still matches: the landing app'"'"'s held moves.'
```

**Edit 6.2**

Find (exactly once):

```fish
    set -l right
    if test $prevw -gt 0
        set -l selrow $model[(math $sel + 1)]
        set -l f (string split -m 2 $TAB -- $selrow)
        if contains -- "$f[2]" $__tcz_landing_groups older
            set right (__tcz_landing_info "$selrow" $prevw $rows)
        else
            set right (__tcz_popup_preview "$f[1]" $prevw $rows)
        end
    end
```

Replace with:

```fish
    set -l right
    if test $prevw -gt 0
        if test "$__tcz_pf_keep" = 1; and test "$__tcz_pf_rdims" = "$prevw $rows"
            set right $__tcz_pf_right
        else
            set -l selrow $model[(math $sel + 1)]
            set -l f (string split -m 2 $TAB -- $selrow)
            if contains -- "$f[2]" $__tcz_landing_groups older
                set right (__tcz_landing_info "$selrow" $prevw $rows)
            else
                set right (__tcz_popup_preview "$f[1]" $prevw $rows)
            end
            set -g __tcz_pf_right $right
            set -g __tcz_pf_rdims "$prevw $rows"
        end
    end
```

**Edit 6.3** — paint: <hold>

Find (exactly once):

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> -- <model lines...>: paint the landing frame, then a border, then the key legend, through the diff emitter.
```

Replace with:

```fish
function __tcz_landing_paint --description '__tcz_landing_paint <sel> <rows> <cols> <hold> -- <model lines...>: paint the landing frame, then a border, then the key legend, through the diff emitter. <hold> = 1 while a move key is held: only the list is rebuilt -- no capture, the preview column kept as it was.
```

**Edit 6.4**

Find (exactly once):

```fish
    set -l sel $argv[1]; set -l rows $argv[2]; set -l cols $argv[3]
    set -e argv[1..4]
    set -l model $argv
    set -l lay (__tcz_popup_layout $cols | string split ' ')
    set -l cap
    set -l f (string split -m 2 \t -- $model[(math $sel + 1)])
    if test $lay[2] -gt 0; and test -n "$f[1]"; and not contains -- "$f[2]" $__tcz_landing_groups older
        set cap (tmux capture-pane -e -p -t (__tcz_session_target "$f[1]") 2>/dev/null)
    end
    set -l key (string join \n -- $sel $rows $cols $model $cap | string collect)
```

Replace with:

```fish
    set -l sel $argv[1]; set -l rows $argv[2]; set -l cols $argv[3]; set -l hold $argv[4]
    set -e argv[1..5]
    set -l model $argv
    set -l lay (__tcz_popup_layout $cols | string split ' ')
    set -l cap
    set -l f (string split -m 2 \t -- $model[(math $sel + 1)])
    if test "$hold" != 1; and test $lay[2] -gt 0; and test -n "$f[1]"; and not contains -- "$f[2]" $__tcz_landing_groups older
        set cap (tmux capture-pane -e -p -t (__tcz_session_target "$f[1]") 2>/dev/null)
    end
    # <hold> is in the key: the quiet repaint after a hold, same row, must not be skipped.
    set -l key (string join \n -- $sel $rows $cols $hold $model $cap | string collect)
```

**Edit 6.5**

Find (exactly once):

```fish
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) '' -- $model)
    set -l legend
```

Replace with:

```fish
    set -g __tcz_pf_keep $hold
    set -l frame (__tcz_popup_frame $sel $lay[1] $lay[2] (math $rows - 2) '' -- $model)
    set -g __tcz_pf_keep 0
    set -l legend
```

**Edit 6.6** — loop

Find (exactly once):

```fish
    set -l pending ''                 # a key the held-key drain read past
```

Replace with:

```fish
    set -l pending ''                 # a key the held-key drain read past
    set -l hold 0                     # 1 after a move: repaint the list only until input is quiet
```

**Edit 6.7**

Find (exactly once):

```fish
        __tcz_landing_paint $sel $rows $cols -- $model
```

Replace with:

```fish
        __tcz_landing_paint $sel $rows $cols $hold -- $model
```

**Edit 6.8**

Find (exactly once):

```fish
            if test $settle -eq 1
                set wait 10
                test -n "$settle_t0"; or set settle_t0 (__tcz_now_ms)
            else if test $idle -ge $idle_after
```

Replace with:

```fish
            if test $settle -eq 1
                set wait 10
                test -n "$settle_t0"; or set settle_t0 (__tcz_now_ms)
            else if test $hold -eq 1
                set wait 2                # 0.2 s with no key ends a hold (stty counts tenths)
            else if test $idle -ge $idle_after
```

**Edit 6.9**

Find (exactly once):

```fish
            if test "$tok" = timeout
                set settle 0
                test $idle -lt $idle_after; and set idle (math $idle + $wait)
            else
```

Replace with:

```fish
            if test "$tok" = timeout; and test $hold -eq 1
                # Input went quiet after a move: repaint with the preview, without a refresh.
                set hold 0
                set tok quiet
            else if test "$tok" = timeout
                set settle 0
                test $idle -lt $idle_after; and set idle (math $idle + $wait)
            else
```

**Edit 6.10**

Find (exactly once):

```fish
        if test "$tok" != timeout
            # A key acts only alone.
```

Replace with:

```fish
        if not contains -- $tok timeout quiet
            # A key acts only alone.
```

**Edit 6.11**

Find (exactly once):

```fish
        set -l n (count $model)
        set -l row (string split \t -- $model[(math $sel + 1)])
        switch $tok
```

Replace with:

```fish
        contains -- $tok up down pgup pgdn; and set hold 1
        set -l n (count $model)
        set -l row (string split \t -- $model[(math $sel + 1)])
        switch $tok
```

- [ ] **Step 4: Run them and watch them pass.** Both: `ALL PASS`. **Record the `# hold:` line** — the after rate (planning runs: 10.1–13.2 rows/s, `captures during the hold 0, after 2`).

- [ ] **Step 5: Gate.** All nine suites in both modes; counts unchanged.

- [ ] **Step 6: Commit** — the message carries both `# hold:` lines from Steps 2 and 4, verbatim:

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "perf(landing): a held arrow repaints the list only; the preview follows once input is quiet" -m "Each held step used to capture the selected pane twice (the painter's skip key, then the frame's preview) and clip it: 23 of a live row's 50 ms frame with 31 rows. Now every move starts a hold: the painter skips its capture and the frame keeps the last preview column (__tcz_pf_keep / __tcz_pf_right), and the read waits 0.2 s; when it times out the hold ends and the row is repainted with its preview, without a refresh. stty counts tenths of a second, so the spec's ~150 ms became 0.2 s.

Holding Down over 80 sessions, Down every ~20 ms for 1.5 s:
before: <the # hold: line from Step 2>
after:  <the # hold: line from Step 4>"
```

(Replace the two `<…>` lines with the printed lines before committing.)

---

### Task 7: Docs — README, CLAUDE.md, the spec

**Files:**
- Modify: `README.md` (Landing page), `CLAUDE.md` (gate notes, test isolation, session naming, Landing session, current state; net −13 bytes), `docs/superpowers/specs/2026-09-26-landing-session-design.md` (Status line, keys, busy, cost, testing).

**Interfaces:** none (docs only).

- [ ] **Step 1: README.** In `README.md`:

**Edit 7a.1**

Find (exactly once):

```markdown
then Claude projects that are not running right now (newest conversation first, read from `~/.claude/projects`, only folders that still exist), then `new shell`.
```

Replace with:

```markdown
then Claude projects that are not running right now, in four groups by where they live: `projects` (`~/projects`), `workspace` (`~/workspace`), `work` (`~/Work`) and `other`, newest conversation first in each. Projects come from your interactive conversations in `~/.claude/projects` (not `claude -p` runs or the desktop and VS Code apps); a git worktree or a folder inside a repository counts as that repository, and your home folder, temp folders and the three group folders themselves never count. Only folders that still exist are listed. A project with no conversation in 21 days hides behind a final `older (N)` row; Enter on it shows them.
```

**Edit 7a.2**

Find (exactly once):

```markdown
Keys: `↑↓` (or `j`/`k`) move · `⏎` open the session, run `claude --continue` in the project, or start a new shell · `r` on a project row runs `claude --resume` instead ·
```

Replace with:

```markdown
Keys: `↑↓` (or `j`/`k`) move (hold one to scroll; the preview fills in when you let go) · `⏎` open the session, run `claude --continue` in the project, or show the older projects · `n` starts a new shell in your home folder · `r` on a project row runs `claude --resume` instead ·
```

- [ ] **Step 2: CLAUDE.md** (an agent-facing file: it keeps its ~105-column wrapping). In `CLAUDE.md`:

**Edit 7b.1**

Find (exactly once):

```markdown
  `test-tmux-status.fish` (4) report numbers; `test-tmux-popup.fish`'s timing assertion is now the
  hand-run `tests/truncate-perf.fish`.
```

Replace with:

```markdown
  `test-tmux-status.fish` (4) report numbers.
```

**Edit 7b.2**

Find (exactly once):

```markdown
`tmux_lives_claude_projects_dir` / `tmux_lives_project_cache` (auto, categorize, install do; install once
wrote the real `projects.tsv`). Real-cache brackets check this run's **footprint** (seam rows, its own
fixture folders, an emptied file), never an mtime: the user's landing apps rewrite `projects.tsv` mid-run.
```

Replace with:

```markdown
`tmux_lives_claude_projects_dir` / `tmux_lives_project_cache` (auto, categorize, install do). Real-cache
brackets check this run's **footprint** (seam rows, its own fixture folders — a row's last field — no data
rows left under the v2 header), never an mtime: the user's landing apps rewrite `projects.tsv` mid-run.
```

**Edit 7b.3**

Find (exactly once):

```markdown
- A generic walk result (`$HOME`, `/`, `/tmp`, `/var/tmp`) counts as "no repo found" and falls back to
  the path's own basename — else a dotfiles repo at `$HOME/.git` collides every non-project directory.
```

Replace with:

```markdown
- A generic walk result (`__tcz_generic_dir`) counts as "no repo found" and falls back to the path's own
  basename — else a dotfiles repo at `$HOME/.git` collides every non-project directory.
```

**Edit 7b.4**

Find (exactly once):

```markdown
per-tab `_landing-N` chooser (live sessions · idle Claude projects · new shell).
```

Replace with:

```markdown
per-tab `_landing-N` chooser (live sessions, then idle Claude projects by group).
```

**Edit 7b.5**

Find (exactly once):

```markdown
- **App** — diff-painted (an idle refresh writes nothing); live rows every 3 s (15 s after a minute with no
  key; seams `tmux_lives_landing_idle_after`/`_idle_refresh`), the idle-project list every 10th pass
  (cache `projects.tsv`; seams in "Test isolation");
  `d` detaches, `q`/Esc are no-ops (one token in `__tcz_popup_readkey`).
```

Replace with:

```markdown
- **App** — diff-painted (an idle refresh writes nothing); live rows every 3 s (15 s after a minute with no
  key; seams `tmux_lives_landing_idle_after`/`_idle_refresh`), projects every 10th pass. `n` new shell, `d`
  detaches, `q`/Esc no-ops (one `__tcz_popup_readkey` token). Held moves skip the capture (`__tcz_pf_keep`).
- **Projects** — category = group (`__tcz_landing_groups`); 21+ days → `older (N)` (seam
  `tmux_lives_landing_older_after`). Interactive transcripts only; awk reads them by `getline` (its main
  loop aborts on an unreadable file). `projects.tsv` v2: header + 4 fields.
```

**Edit 7b.6**

Find (exactly once):

```markdown
## Current state — 2026-09-29

**The landing session** (`7528599`) is deployed on both machines; its type-ahead fix and idle cadence are
merged on `main` and await the user's `fisher update`.
```

Replace with:

```markdown
## Current state — 2026-10-01

**Landing chooser v2** is merged on `main` and awaits the user's `fisher update`.
```

**Edit 7b.7**

Find (exactly once):

```markdown
- **Chooser v2** — approved 2026-10-01, spec updated, not built (see the spec's Status line).
```

Delete it, lines and all.

- [ ] **Step 3: The spec.** In `docs/superpowers/specs/2026-09-26-landing-session-design.md`:

**Edit 7c.1**

Find (exactly once):

```markdown
**Chooser v2 approved 2026-10-01, not yet built:** interactive-only discovery with worktree/subfolder mapping and the generic-folder list, four project groups, the 21-day `older (N)` row, `n` for a new shell, the legend border, and held-arrow scrolling without per-step preview capture (plan `docs/superpowers/plans/2026-10-01-landing-chooser-v2.md`).
```

Replace with:

```markdown
**Chooser v2 approved 2026-10-01 and built on `main`, awaiting the user's `fisher update`:** interactive-only discovery with worktree/subfolder mapping and the generic-folder list, four project groups, the 21-day `older (N)` row, `n` for a new shell, the legend border, and held-arrow scrolling without per-step preview capture.
```

**Edit 7c.2**

Find (exactly once):

```markdown
While a move key is held, only the list repaints; the preview is captured once input has been quiet for ~150 ms (the capture is what made each held step slow).
```

Replace with:

```markdown
While a move key is held, only the list repaints; the preview is captured once input has been quiet for 0.2 s (the tty read timer counts tenths of a second; the capture is what made each held step slow).
```

**Edit 7c.3**

Find (exactly once):

```markdown
drop a project when a live pane runs claude with that folder (or its git root) as its cwd,
```

Replace with:

```markdown
drop a project when a live pane runs claude with that folder (or its git root, or a worktree of it: the mapping discovery uses) as its cwd,
```

**Edit 7c.4**

Find (exactly once):

```markdown
- **Cost** — about one fork per directory to read a transcript head. Cache tab-separated `dir`, `mtime`, `folder` lines in `$XDG_CACHE_HOME/tmux-lives/projects.tsv` (seam `tmux_lives_project_cache`; the transcript root has its own seam, `tmux_lives_claude_projects_dir`); re-read a directory only when its newest transcript's mtime changes, and rewrite the cache only when something changed.
```

Replace with:

```markdown
- **Cost** — one `awk` per changed directory reads each transcript up to its first `cwd` line, by `getline` (awk's main loop aborts the whole run on an unreadable file). A directory named after a folder that is never a project is skipped unread: rocket's `/tmp` one holds a thousand headless transcripts. The cache, `$XDG_CACHE_HOME/tmux-lives/projects.tsv` (seam `tmux_lives_project_cache`; the transcript root has its own seam, `tmux_lives_claude_projects_dir`), opens with the line `# tmux-lives projects v2` (a file without it is ignored whole), then tab-separated `dir`, its newest transcript's mtime (the key), the newest interactive transcript's mtime, and that transcript's `cwd`. A directory is re-read only when its key changes, and the cache rewritten only when something changed. Measured on rocket: 155 ms cold and 43 ms warm, against 180 ms and 88 ms before.
```

**Edit 7c.5**

Find (exactly once):

```markdown
- Discovery: a fixture projects directory (seam) with slugs, transcripts and mtimes — cwd extraction, the exists-locally filter, running-exclusion, ordering, cache hit and miss, no rewrite when nothing changed.
```

Replace with:

```markdown
- Discovery: a fixture projects directory (seam) with slugs, transcripts and mtimes — cwd extraction, the exists-locally filter, running-exclusion, ordering, cache hit and miss, no rewrite when nothing changed; headless and GUI transcripts ignored, worktree and subfolder mapping, generic and group-root directories never read, an unreadable transcript skipped, a cache without the v2 header discarded.
```

- [ ] **Step 4: Verify.**

```bash
wc -c CLAUDE.md                                   # 39911 — must be under 40000
grep -c 'new shell' README.md                     # 1 (the n key)
grep -n 'idle claude\|then `new shell`' README.md CLAUDE.md docs/superpowers/specs/2026-09-26-landing-session-design.md    # nothing
grep -c 'not yet built' docs/superpowers/specs/2026-09-26-landing-session-design.md                                     # 0
```

- [ ] **Step 5: Commit.**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-09-26-landing-session-design.md
git commit -m "docs: landing chooser v2 -- README, CLAUDE.md, spec status" -m "README: the chooser's groups, the older (N) row, interactive-only discovery and the n key. CLAUDE.md: the landing section records the group categories, the older seam, the getline reader and the held-move capture skip; the generic list is __tcz_generic_dir; the real-cache brackets read v2 rows. Pruned in exchange: the superseded current-state paragraph and open item, and a gate note the layout table already carries (net -13 bytes, 39,911). Spec: Status line built and awaiting fisher update; the quiet window is 0.2 s; the busy check follows worktrees; the discovery cost and the v2 cache."
```

- [ ] **Step 6: Controller only, after the final review.** Re-publish the spec to the vault with the `vault-publish` skill (it lives there as `Tmux-lives/Landing Session - Design`; the vault copy is unwrapped). After the branch merges, delete this plan (`git rm docs/superpowers/plans/2026-10-01-landing-chooser-v2.md`) — plans are deleted once their work ships — and tell the user to run `fisher update` on both machines.

---

## Self-review (run while planning)

- **Spec coverage.** Interactive-only transcripts via `entrypoint` → Task 2. Worktree and subfolder → main repo → Tasks 1, 2. The generic list incl. macOS `/private/tmp`, shared with `__tcz_project_name` → Task 1. Group roots never a project → Tasks 1, 2. Non-repo busy rule → Task 3. Four groups in order, empty ones hidden → Task 5. 21 days, `older (N)`, reveal until restart → Task 5. `n` and no new-shell row → Task 4. Legend border → Task 4. Held-arrow preview deferral with a measured before/after → Task 6. Cache invalidation without touching the render cache → Task 2. README, CLAUDE.md within budget, spec Status → Task 7.
- **Replay.** Every edit above, applied in task order to a clean export of HEAD `2b978b7`, reproduces byte for byte the tree on which the gate ran 9/9 `ALL PASS` in both modes (install 960 / 959). The full categorize suite also passed at the Task 1, 2, 3 and 5 states; each task's new assertions were run against the previous task's state and fail exactly as Step 2 lists.
- **Names.** New names were checked for collisions across `functions/`, `conf.d/`, `tests/`, `README.md` and `docs/`: `__tcz_generic_dir`, `__tcz_claude_project_of`, `__tcz_landing_group_roots`, `__tcz_landing_group`, `__tcz_landing_groups`, `__tcz_landing_older_after`, `__tcz_landing_border`, `__tcz_proj_cache_head`, `__tcz_pf_keep`, `__tcz_pf_right`, `__tcz_pf_rdims`, `tmux_lives_landing_older_after` — none existed. Existing names this plan relies on, confirmed in the code: `__tcz_git_root`, `__tcz_project_name`, `__tcz_claude_projects_dir`, `__tcz_claude_project_cache`, `__tcz_claude_cwds`, `__tcz_age`, `__tcz_landing_new_shell`, `__tcz_landing_start`, `__tcz_landing_client`, `__tcz_landing_info`, `__tcz_landing_paint`, `__tcz_popup_frame`, `__tcz_popup_list_lines`, `__tcz_popup_emit`, `__tcz_popup_readkey`, `__tcz_legend_row`, `__tcz_landing_cmd`, and the suites' `fresh_server`, `cleanup`, `__tcg_ready`, `__tcg_screen_has`, `__tcg_client_on`, `__tcg_proj_leaks`.
- **Not settled from this host.** macOS was not exercised: BWK awk's `getline`/`match` and the `/private/tmp` and `/var/folders` paths are covered only by the pure tests, and the suites' `touch -d '… ago'` and `date +%s%3N` idioms are GNU (they predate this plan). A conversation held in a worktree now lists under its main repository, and Enter runs `claude --continue` there — which continues that folder's own latest conversation, not the worktree's: the spec's mapping, noted here because it is visible to the user.
