# Test Harness Universal Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for the test suite to read or write the user's real fish universal variables, so a suite run can never destroy their tmux-lives configuration.

**Architecture:** Every `tests/test-*.fish` gains a self-re-exec guard at the top that points `XDG_CONFIG_HOME` at a throwaway directory and relaunches itself under it. Fish binds its universal store at process startup, so the redirect cannot be applied from inside a running test — re-exec is the only mechanism. The guard is duplicated per file (not sourced from a helper) so each suite stays safe when run standalone. No file outside `tests/` is touched.

**Tech Stack:** fish 4.7.1 (shell + test language), tmux 3.3a, git. No build system, no test framework — suites are plain fish scripts with a `t` assertion helper.

## Global Constraints

- **Nothing outside `tests/` may be modified.** No change to `conf.d/`, `functions/`, the theme engine, the CLI, or any shipped behavior.
- **Never run `set -U`, `set -Ux`, or `set -e` against a real `tmux_lives_*` universal.** Ad-hoc verification in a terminal must not touch them. This is the exact rule whose violation caused the incident this plan fixes. The single carve-out is Task 1 Step 2, the red state of the first test — it runs the suite unguarded **by design**, to demonstrate the bug, with a recorded before-snapshot and a mandatory cleanup-and-verify immediately after. No other step may run an unguarded suite.
- **Never deploy.** Do not copy anything into `~/.config/fish/`. Commit and push only; the user deploys via `fisher update`.
- **The gate is all 8 suites green under BOTH `fish` and `fish --no-config`.** Dev loop: `fish -c 'for t in tests/test-*.fish; fish $t < /dev/null; end'` (the `< /dev/null` matters — a shared-stdin loop can hang).
- **Guard placement is immediately before each file's first executable statement** (after the shebang and any leading comment block), and specifically **above** the `gcc` availability checks in `test-tmux-categorize.fish` and `test-tmux-restore.fish`, so no code path can reach a `set -U` before isolation is active.
- **The guard text is byte-identical in all 8 files.** A structural test enforces this in Task 4.
- **Every task ends with the real store verified untouched:** `cksum ~/.config/fish/fish_variables` before and after must match. Record the value in the commit or task report.

The canonical guard, proven in both fish modes:

```fish
if not set -q TMUX_LIVES_TEST_UVARS
    set -l d (mktemp -d /tmp/tmux-lives-uv.XXXXXX)
    if test -z "$d"; or not test -d "$d"
        echo "FATAL: cannot create an isolated universal store; refusing to run" >&2
        exit 1
    end
    set -gx TMUX_LIVES_TEST_UVARS $d
    set -gx XDG_CONFIG_HOME $d
    set -l fishargs
    test (count $fish_function_path) -gt 0; or set fishargs --no-config
    fish $fishargs (path resolve (status filename)) $argv
    set -l rc $status
    rm -rf $d
    exit $rc
end
```

**Do not "simplify" the mode discriminator.** `test (count $fish_function_path) -gt 0` distinguishes plain fish (5) from `--no-config` (0) and is **store-independent**. The tempting `set -q __fish_initialized` is a trap: that variable is itself a *universal*, so in the re-exec'd child — whose store is deliberately fresh and empty — it reads unset under plain fish too, misclassifying every run as `--no-config` and silently destroying the dual-mode gate.

---

## File Structure

All changes are confined to `tests/`. No new files.

| File | Change |
| --- | --- |
| `tests/test-tmux-install.fish` | Guard; isolation-proof assertions; `exit` on failure count; `_th_names` gains two names |
| `tests/test-generic.fish` | Guard; `exit` on failure; structural check that all 8 suites carry the guard |
| `tests/test-tmux-status.fish` | Guard; `exit` on failure count |
| `tests/test-tmux-categorize.fish` | Guard only |
| `tests/test-tmux-popup.fish` | Guard only |
| `tests/test-tmux-auto.fish` | Guard only |
| `tests/test-tmux-restore.fish` | Guard only |
| `tests/test-tmux-shellfish.fish` | Guard only |

**Insertion anchors** (guard goes immediately before the listed line):

| File | Insert before line | That line is |
| --- | --- | --- |
| `test-generic.fish` | 2 | `set -g plugindir (path resolve (status dirname)/..)` |
| `test-tmux-status.fish` | 2 | `set -g plugindir (path resolve (status dirname)/..)` |
| `test-tmux-install.fish` | 2 | `set -g plugindir (path resolve (status dirname)/..)` |
| `test-tmux-categorize.fish` | 8 | `set -g FAIL 0` |
| `test-tmux-popup.fish` | 6 | `set -g FAIL 0` |
| `test-tmux-auto.fish` | 6 | `set -g FAIL 0` |
| `test-tmux-restore.fish` | 12 | `set -g FAIL 0` |
| `test-tmux-shellfish.fish` | 16 | `set -g FAIL 0` |

---

## Task 1: Isolation proof + guard in the install suite

The install suite is the one proven to destroy user configuration. It gets the guard and the assertions that prove the guard is live.

**Files:**
- Modify: `tests/test-tmux-install.fish` (guard before line 2; new assertions appended before the summary at line 1179)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the environment variable `TMUX_LIVES_TEST_UVARS` (absolute path to the throwaway config dir, equal to `$XDG_CONFIG_HOME` inside a guarded run). Tasks 2 and 4 rely on this exact name.

- [ ] **Step 1: Write the failing test**

Append immediately **before** the final summary line (`test $fail -eq 0; and echo "ALL PASS ($pass)"; ...`) at `tests/test-tmux-install.fish:1179`:

```fish
# --- universal-variable isolation (2026-07-25) ---------------------------
# The suite drives the real CLI, which really does `set -U`. Without the
# re-exec guard at the top of this file those writes hit the user's live
# ~/.config/fish/fish_variables. These assertions prove the guard is active;
# if it ever regresses they fail instead of silently eating the user's config.
t "isolation: guard sentinel is set" 1 (set -q TMUX_LIVES_TEST_UVARS; and echo 1; or echo 0)
t "isolation: sentinel matches XDG_CONFIG_HOME" 1 (test "$TMUX_LIVES_TEST_UVARS" = "$XDG_CONFIG_HOME"; and echo 1; or echo 0)
t "isolation: store is not the real config dir" 1 (test "$XDG_CONFIG_HOME" != "$HOME/.config"; and echo 1; or echo 0)

set -U tmux_lives_isolation_probe probe-(random)
# Holds in BOTH fish modes and is the assertion that actually matters.
t "isolation: probe never reaches the real store" 0 (grep -q tmux_lives_isolation_probe $HOME/.config/fish/fish_variables 2>/dev/null; and echo 1; or echo 0)
# `fish --no-config` persists NO universals at all, so only assert the probe
# landed in the temp store when running under a config-loaded fish.
if test (count $fish_function_path) -gt 0
    t "isolation: probe landed in the temp store" 1 (grep -q tmux_lives_isolation_probe $XDG_CONFIG_HOME/fish/fish_variables 2>/dev/null; and echo 1; or echo 0)
end
set -e tmux_lives_isolation_probe
```

- [ ] **Step 2: Run test to verify it fails**

This step runs the install suite **unguarded** — that is the point, it is the red state. Record the user's universals first so any damage is detectable and reversible:

```bash
cksum ~/.config/fish/fish_variables            # record this value
fish -c 'set -U | string match "tmux_lives_*"' | tee /tmp/uvars-before.txt
```

The eight names that must survive (`theme`, `bar_color`, `status_invert`, `theme_contrast`, `theme_ease`, `theme_phase`, `theme_shape`, `theme_vividness`) are all in the suite's own `_th_names` save list, so a run that completes restores them. **Do not interrupt this run** — an interrupted unguarded run is precisely the failure this plan exists to prevent.

```bash
fish tests/test-tmux-install.fish < /dev/null | tail -8
```

Expected: `FAILED (n)` with at least these lines:
```
FAIL: isolation: guard sentinel is set => got [0]
FAIL: isolation: sentinel matches XDG_CONFIG_HOME => got [0]
FAIL: isolation: store is not the real config dir => got [0]
```

**The `probe never reaches the real store` assertion will FAIL here too — meaning the probe DID reach your real store.** That is the bug, demonstrated. Immediately clean it up before continuing:

```bash
fish -c 'set -e tmux_lives_isolation_probe'
cksum ~/.config/fish/fish_variables            # must match the value recorded above
fish -c 'set -U | string match "tmux_lives_*"' | diff - /tmp/uvars-before.txt && echo "universals intact"
```

If that `diff` is not empty, **stop** and restore the missing values by hand before continuing — do not proceed with a damaged store.

- [ ] **Step 3: Write minimal implementation**

Insert the canonical guard (verbatim from Global Constraints) into `tests/test-tmux-install.fish` immediately before line 2 (`set -g plugindir …`), directly under the `#!/usr/bin/env fish` shebang.

- [ ] **Step 4: Run test to verify it passes**

```bash
cksum ~/.config/fish/fish_variables            # record
fish tests/test-tmux-install.fish < /dev/null | tail -3
fish --no-config tests/test-tmux-install.fish < /dev/null | tail -3
cksum ~/.config/fish/fish_variables            # must be unchanged
```

Expected: `ALL PASS (n)` in both modes, and the two `cksum` values identical. The count rises by **5 under plain fish** and **4 under `--no-config`** (the probe-landed-in-temp-store assertion is gated on plain fish), from a pre-task baseline of 464.

- [ ] **Step 5: Commit**

```bash
git add tests/test-tmux-install.fish
git commit -m "test(install): XDG universal-isolation guard + isolation-proof assertions

The suite drives the real CLI, so its set -U calls hit the user's live
fish_variables. A clean pass destroyed tmux_lives_theme_place/_mode every
run. The guard re-execs the suite under a throwaway XDG_CONFIG_HOME before
any test code runs; fish binds its universal store at startup, so this
cannot be done from inside the running script."
```

---

## Task 2: Guard the remaining seven suites

**Files:**
- Modify: `tests/test-generic.fish`, `tests/test-tmux-status.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-popup.fish`, `tests/test-tmux-auto.fish`, `tests/test-tmux-restore.fish`, `tests/test-tmux-shellfish.fish`

**Interfaces:**
- Consumes: the guard text and `TMUX_LIVES_TEST_UVARS` name from Task 1.
- Produces: all 8 suites guarded — the precondition for Task 4's structural check.

- [ ] **Step 1: Insert the guard into all seven files**

Insert the canonical guard verbatim at each file's anchor from the File Structure table. Two placements are load-bearing and easy to get wrong:

- `test-tmux-categorize.fish`: before line 8 (`set -g FAIL 0`) — this is **above** the `command -q gcc; or begin; …; exit 1; end` check on line 19. If the guard went below it, a machine without gcc would `exit 1` from an unguarded process.
- `test-tmux-restore.fish`: before line 12 (`set -g FAIL 0`) — same reasoning; its gcc check is on line 23.

- [ ] **Step 2: Verify each guarded suite still passes, both modes**

```bash
cksum ~/.config/fish/fish_variables            # record
fish -c 'for t in tests/test-*.fish; echo "── $t"; fish $t < /dev/null | tail -2; end'
fish -c 'for t in tests/test-*.fish; echo "── $t"; fish --no-config $t < /dev/null | tail -2; end'
cksum ~/.config/fish/fish_variables            # must be unchanged
```

Expected: every suite `ALL PASS` in both modes; the two `cksum` values identical.

- [ ] **Step 3: Verify the guard is actually engaging in each file**

```bash
fish -c 'for t in tests/test-*.fish; echo -n "$t: "; grep -c TMUX_LIVES_TEST_UVARS $t; end'
```

Expected: every file reports `1`.

- [ ] **Step 4: Verify no temp directories leak**

```bash
ls -d /tmp/tmux-lives-uv.* 2>/dev/null || echo "no leftovers"
```

Expected: `no leftovers`.

- [ ] **Step 5: Commit**

```bash
git add tests/test-generic.fish tests/test-tmux-status.fish tests/test-tmux-categorize.fish \
        tests/test-tmux-popup.fish tests/test-tmux-auto.fish tests/test-tmux-restore.fish \
        tests/test-tmux-shellfish.fish
git commit -m "test: XDG universal-isolation guard in the remaining 7 suites

Placed above the gcc availability checks in the categorize and restore
suites so no code path can exit from an unguarded process."
```

---

## Task 3: Suites must fail loudly

Three suites print `FAILED` but return 0, so an automated loop cannot tell green from red — and the guard's exit-code propagation is meaningless without this.

**Files:**
- Modify: `tests/test-tmux-install.fish:1179`, `tests/test-tmux-status.fish:12`, `tests/test-generic.fish:5-9`

**Interfaces:**
- Consumes: the guard from Tasks 1-2 (it propagates the child's exit code, which is what makes these codes visible to the caller).
- Produces: all 8 suites return non-zero on failure. No later task depends on this beyond the final gate.

- [ ] **Step 1: Verify the current broken behaviour**

```bash
fish tests/test-tmux-status.fish < /dev/null; echo "rc=$status"
```

Expected: `ALL PASS (4)` then `rc=0`. Now prove it lies — temporarily append a deliberately failing assertion to `tests/test-tmux-status.fish` before its summary line:

```fish
t "TEMPORARY deliberate failure" 1 0
```

```bash
fish tests/test-tmux-status.fish < /dev/null; echo "rc=$status"
```

Expected (the bug): prints `FAILED (1)` but still `rc=0`.

- [ ] **Step 2: Fix all three suites**

`tests/test-tmux-status.fish` — replace line 12:

```fish
test $fail -eq 0; and echo "ALL PASS ($pass)"; or begin; echo "FAILED ($fail)"; exit 1; end
```

`tests/test-tmux-install.fish` — replace line 1179 with the identical form:

```fish
test $fail -eq 0; and echo "ALL PASS ($pass)"; or begin; echo "FAILED ($fail)"; exit 1; end
```

`tests/test-generic.fish` — replace the `if`/`else` block at lines 5-9:

```fish
if test -n "$hits"
    echo "FAIL: host-specifics found:"; printf '%s\n' $hits; echo "FAILED"
    exit 1
else
    echo "ALL PASS (1)"
end
```

- [ ] **Step 3: Verify the failure is now signalled**

```bash
fish tests/test-tmux-status.fish < /dev/null; echo "rc=$status"
```

Expected: `FAILED (1)` and `rc=1`.

- [ ] **Step 4: Remove the temporary failing assertion and confirm green**

Delete the `TEMPORARY deliberate failure` line from `tests/test-tmux-status.fish`, then:

```bash
fish tests/test-tmux-status.fish < /dev/null; echo "rc=$status"
fish tests/test-generic.fish < /dev/null; echo "rc=$status"
fish tests/test-tmux-install.fish < /dev/null | tail -1; echo "rc=$status"
```

Expected: `ALL PASS` for each, `rc=0` for each.

- [ ] **Step 5: Commit**

```bash
git add tests/test-tmux-install.fish tests/test-tmux-status.fish tests/test-generic.fish
git commit -m "test: exit non-zero on failure in the three silent suites

install, status and generic ended on an echo, so they reported success to
the shell even while printing FAILED. Without this the guard's exit-code
propagation is inert and the dev loop cannot detect a red suite."
```

---

## Task 4: Structural guard, the `_th_names` hole, and the full gate

Locks the isolation in so it cannot be dropped later, closes the specific bookkeeping hole that deleted the user's theme placement, and proves the whole thing under the conditions that originally broke it.

**Files:**
- Modify: `tests/test-generic.fish` (new structural check), `tests/test-tmux-install.fish:780` (`_th_names`)

**Interfaces:**
- Consumes: `TMUX_LIVES_TEST_UVARS` (Task 1), all 8 suites guarded (Task 2), non-zero exits (Task 3).
- Produces: final state. Nothing depends on this task.

- [ ] **Step 1: Write the failing structural test**

In `tests/test-generic.fish`, after the existing host-specifics check and before the summary, add:

```fish
# Every test suite MUST carry the universal-isolation guard. Without it, a
# suite that drives the real CLI writes set -U straight into the user's live
# ~/.config/fish/fish_variables. Fish binds its universal store at startup,
# so the guard has to re-exec — it cannot be applied from inside the script.
set -l unguarded
for f in $plugindir/tests/test-*.fish
    grep -q 'TMUX_LIVES_TEST_UVARS' $f; or set -a unguarded (path basename $f)
end
if test -n "$unguarded"
    echo "FAIL: test files missing the universal-isolation guard:"; printf '  %s\n' $unguarded; echo "FAILED"
    exit 1
end
```

To confirm the check has teeth, temporarily delete the guard from `tests/test-tmux-popup.fish`, then:

```bash
fish tests/test-generic.fish < /dev/null; echo "rc=$status"
```

Expected: `FAIL: test files missing the universal-isolation guard:` listing `test-tmux-popup.fish`, then `FAILED`, `rc=1`.

- [ ] **Step 2: Restore the guard and confirm the check passes**

```bash
git checkout tests/test-tmux-popup.fish
fish tests/test-generic.fish < /dev/null; echo "rc=$status"
```

Expected: `ALL PASS (1)`, `rc=0`.

- [ ] **Step 3: Close the `_th_names` hole**

At `tests/test-tmux-install.fish:780`, append the two missing names to the end of the `set -g _th_names …` line:

```fish
set -g _th_names tmux_lives_theme tmux_lives_theme_phase tmux_lives_theme_vividness tmux_lives_theme_shape tmux_lives_theme_ease tmux_lives_theme_range tmux_lives_theme_polarity tmux_lives_theme_contrast tmux_lives_theme_rotate tmux_lives_bar_color tmux_lives_status_invert tmux_lives_cap tmux_lives_cap_wheel tmux_lives_cap_vividness tmux_lives_cap_role tmux_lives_theme_place tmux_lives_theme_mode
```

These were written at line 863 and erased at 894-895 while absent from this list — the exact hole that deleted the user's `sage/high/derived` placement on every clean run. With the guard active this is belt-and-braces only, which is why it is a one-line change rather than a rework.

Add a regression assertion next to the existing theme guards near the end of `tests/test-tmux-install.fish` (before the summary):

```fish
t "guard: _th_names covers theme_place" 1 (contains tmux_lives_theme_place $_th_names; and echo 1; or echo 0)
t "guard: _th_names covers theme_mode" 1 (contains tmux_lives_theme_mode $_th_names; and echo 1; or echo 0)
```

- [ ] **Step 4: Standalone-run proof — the path that caused the incident**

```bash
cksum ~/.config/fish/fish_variables            # record
fish tests/test-tmux-install.fish < /dev/null | tail -1
cksum ~/.config/fish/fish_variables            # must match
fish -c 'set -U | string match "tmux_lives_*"'
```

Expected: `ALL PASS (n)`, identical `cksum` values, and the user's universals listing unchanged — specifically still showing `tmux_lives_theme`, `tmux_lives_bar_color`, `tmux_lives_status_invert`, `tmux_lives_theme_contrast`, `tmux_lives_theme_ease`, `tmux_lives_theme_phase`, `tmux_lives_theme_shape`, `tmux_lives_theme_vividness`.

- [ ] **Step 5: Interrupt proof — the assertion the old design could never satisfy**

Use `timeout`, which sends SIGTERM on expiry — the same signal that a command timeout delivered during the original incident. Do **not** use a backgrounded job plus `sleep`; foreground `sleep` is blocked in the agent Bash tool.

```bash
cksum ~/.config/fish/fish_variables            # record
timeout 3 fish tests/test-tmux-install.fish < /dev/null; echo "killed with rc=$?"
cksum ~/.config/fish/fish_variables            # must match
fish -c 'set -U | string match "tmux_lives_*"'
```

Expected: `rc=124` (timeout fired mid-run), identical `cksum` values, and the universals listing unchanged. A SIGTERM mid-run — exactly what happened on 2026-07-25 — now leaves the real store untouched.

If the suite finishes in under 3 seconds it was never interrupted and the test is vacuous; lower the timeout until `rc=124` before accepting this step. Note a `/tmp/tmux-lives-uv.*` directory survives a kill; that is the documented, accepted trade-off — remove it by hand afterwards.

- [ ] **Step 6: Full gate, both modes**

```bash
cksum ~/.config/fish/fish_variables            # record
fish -c 'for t in tests/test-*.fish; echo "── $t"; fish $t < /dev/null | tail -2; end'
fish -c 'for t in tests/test-*.fish; echo "── $t"; fish --no-config $t < /dev/null | tail -2; end'
fish --no-config tests/test-tmux-categorize.fish < /dev/null 2>&1 >/dev/null | wc -c
cksum ~/.config/fish/fish_variables            # must match
```

Expected: all 8 suites `ALL PASS` in both modes; the categorize stderr byte count is `0`; the two `cksum` values identical. (`2>&1 >/dev/null` in that order sends stderr to the pipe and stdout to `/dev/null`, so `wc -c` counts stderr only — the order is deliberate, not a typo.)

- [ ] **Step 7: Commit**

```bash
git add tests/test-generic.fish tests/test-tmux-install.fish
git commit -m "test: structural guard for the isolation seam + close the _th_names hole

test-generic now fails if any tests/test-*.fish lacks the guard, so a new
suite cannot silently reintroduce the defect. _th_names gains
tmux_lives_theme_place and tmux_lives_theme_mode, which were written at
install:863 and erased at :894-895 while absent from the save list — the
hole that deleted the user's theme placement on every clean run."
```

---

## Definition of Done

- All 8 suites `ALL PASS` under `fish` and under `fish --no-config`.
- `cksum ~/.config/fish/fish_variables` identical before and after a full suite run, a standalone install-suite run, and a SIGTERM-killed run.
- `fish -c 'set -U | string match "tmux_lives_*"'` unchanged across all of the above.
- Removing the guard from any test file fails `tests/test-generic.fish` with a non-zero exit code.
- Deliberately failing an assertion in `install`, `status` or `generic` produces a non-zero exit code.
- The categorize suite under `--no-config` emits 0 bytes of stderr.
- Nothing outside `tests/` modified. Check against the plan's base commit (`c38b254`) rather than `main`, since the work may land on `main` directly and a `main`-relative diff would be trivially empty:

```bash
git diff --name-only c38b254..HEAD
```

Every path listed must start with `tests/` or `docs/`.

## Follow-ups (explicitly NOT in this plan)

After this lands, the user's own two actions can finally stick: `tmux-lives setup theme sage --place high --mode derived`, then `fisher update`. Also still open and out of scope: removing the ~80 lines of now-redundant save/restore bookkeeping; the `string split '=' $kv` truncation nit at `install:1147`; macOS verification of the `mktemp` template and whether `$TMPDIR` needs honouring; a periodic sweep for leaked `/tmp/tmux-lives-uv.*` directories; the picker cosmetic renames; and the `Cscale` saturation tuning.
