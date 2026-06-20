# tmux-lives macOS Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux-lives fully functional on macOS — portable claude-detection, runtime-only persistence (no launchd units), and a bare-`ts` cold-start — with zero Linux regression.

**Architecture:** Three small, independent changes, all in existing files. (A) the install layer's non-systemd branch becomes intentional runtime-only messaging via two pure helpers; (B) `/proc` reads in the categorizer move behind two portable helpers that fall back to `ps`; (C) `ts` cold-starts the full autostart flow when no server is running.

**Tech Stack:** fish 3.x+, tmux 3.3a+, POSIX `ps`/`cat`/`stty`/`pgrep`. Pure fish, no new dependency or file.

## Global Constraints

- **Zero net-new files in `conf.d/` or `functions/`** — new helpers go in the existing `functions/tmux-categorize.fish` and `conf.d/tmux-lives-install.fish`; new tests go in existing `tests/` files. Underscore-prefix every new helper.
- **No Linux regression** — components A and B are behaviorally byte-identical on Linux; component C intentionally changes one rare edge (bare `ts`, no server) on both platforms. All eight existing suites must still print their pass line.
- **Pure fish, stock-macOS tools only** — `tmux`, `ps`, `cat`, `stty`, `pgrep`, fish builtins.
- **Commits** — follow repo style (`feat:` / `fix:` / `docs:` / `test:` prefix); end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Repo works direct-to-`main`; push after each commit.
- **Run all suites:** `for t in tests/test-*.fish; fish $t; end` (each prints `ALL PASS` / `ALL PASS (N)`).

---

### Task 1: Portable claude-detection (`/proc` → `ps`)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add two helpers above `__tcz_cmdline_name` at line 53; reroute the three `/proc` reads at lines 57, 58, 77)
- Test: `tests/test-tmux-categorize.fish` (append a new assertion block)

**Interfaces:**
- Produces:
  - `__tcz_pid_comm <pid>` → echoes the process executable name (e.g. `fish`, `claude`); empty string on a gone/invalid pid. Linux: `/proc/$pid/comm`; else: basename of `ps -o comm=`.
  - `__tcz_pid_cmdline <pid>` → echoes the space-joined argv; empty on failure. Linux: `/proc/$pid/cmdline`; else: `ps -o args=`.
  - Both honor a `tcz_force_ps` global (when set, take the `ps` branch even on Linux) — a testability seam, mirroring the existing `tmux_categorize_test` seam.

- [ ] **Step 1: Write the failing test**

Append after the existing `__tcz_pane_is_claude` block in `tests/test-tmux-categorize.fish` (it is already sourced with `tmux_categorize_test 1`, and `$fish_pid` / `t` are in scope):

```fish
# ---------------------------------------------------------------------
# Portable pid inspection (B): /proc and ps branches must agree on Linux
# ---------------------------------------------------------------------
t "pid_comm /proc -> fish"      "fish" (__tcz_pid_comm $fish_pid)
t "pid_cmdline /proc has fish"  "1"    (string match -q '*fish*' -- (__tcz_pid_cmdline $fish_pid); and echo 1; or echo 0)
set -g tcz_force_ps 1
t "pid_comm ps -> fish"         "fish" (__tcz_pid_comm $fish_pid)
t "pid_cmdline ps has fish"     "1"    (string match -q '*fish*' -- (__tcz_pid_cmdline $fish_pid); and echo 1; or echo 0)
set -e tcz_force_ps
t "pid_comm empty pid -> empty" ""     (__tcz_pid_comm "")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL lines for the new assertions (e.g. `__tcz_pid_comm` is an unknown command / empty output), and the suite ends with `SOME FAILED`.

- [ ] **Step 3: Add the two helpers**

Insert immediately before `function __tcz_cmdline_name` (currently line 53) in `functions/tmux-categorize.fish`:

```fish
function __tcz_pid_comm --description 'pid -> executable name (portable: /proc on Linux, ps elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    if test -r /proc/$pid/comm; and not set -q tcz_force_ps
        cat /proc/$pid/comm 2>/dev/null
    else
        set -l c (ps -o comm= -p $pid 2>/dev/null | string trim)
        test -n "$c"; and path basename $c
    end
end

function __tcz_pid_cmdline --description 'pid -> space-joined argv (portable: /proc on Linux, ps elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    if test -r /proc/$pid/cmdline; and not set -q tcz_force_ps
        string split0 < /proc/$pid/cmdline 2>/dev/null | string join ' '
    else
        ps -o args= -p $pid 2>/dev/null | string trim
    end
end
```

- [ ] **Step 4: Reroute the three `/proc` reads through the helpers**

In `__tcz_cmdline_name`, change the loop body (lines 57-58) from:

```fish
        test "$(cat /proc/$pid/comm 2>/dev/null)" = claude; or continue
        set -l cmd (string split0 < /proc/$pid/cmdline 2>/dev/null | string join ' ')
```

to:

```fish
        test "$(__tcz_pid_comm $pid)" = claude; or continue
        set -l cmd (__tcz_pid_cmdline $pid)
```

In `__tcz_pane_is_claude`, change the last line (line 77) from:

```fish
    test "$(cat /proc/$argv[2]/comm 2>/dev/null)" = claude
```

to:

```fish
    test "$(__tcz_pid_comm $argv[2])" = claude
```

- [ ] **Step 5: Run the categorize suite to verify it passes**

Run: `fish tests/test-tmux-categorize.fish`
Expected: every line `ok   - …`, ending with `ALL PASS`. The existing fake-`claude` integration assertions must still pass (proves the `/proc` reroute is behavior-preserving on Linux).

- [ ] **Step 6: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat: portable claude-detection — /proc reads behind __tcz_pid_comm/_cmdline (ps fallback for macOS)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 2: Runtime-only service-layer messaging

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add two pure helpers; reword the `tmux-setup` non-systemd `else` at lines 98-100; add an `else` to the systemd block in `__tmux_lives_status_lines` at lines 137-139)
- Test: `tests/test-tmux-install.fish` (append assertions)

**Interfaces:**
- Produces:
  - `__tmux_lives_persistence_note` → echoes the macOS/non-systemd setup note (no "spec 2"; mentions continuum + first `ts`/SSH restore).
  - `__tmux_lives_persistence_status` → echoes one `OK …` status line describing the macOS persistence model.

- [ ] **Step 1: Write the failing test**

Append before the final `test $fail -eq 0; …` line in `tests/test-tmux-install.fish`:

```fish
set -l pn (__tmux_lives_persistence_note)
t "note mentions continuum"      1 (string match -q '*continuum*' -- "$pn"; and echo 1; or echo 0)
t "note mentions restore"        1 (string match -q '*restore*' -- "$pn"; and echo 1; or echo 0)
t "note drops 'spec 2'"          0 (string match -q '*spec 2*' -- "$pn"; and echo 1; or echo 0)
set -l ps (__tmux_lives_persistence_status)
t "status is an OK line"         1 (string match -q 'OK *' -- "$ps"; and echo 1; or echo 0)
t "status mentions continuum"    1 (string match -q '*continuum*' -- "$ps"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL lines for the new assertions (`__tmux_lives_persistence_note` unknown / empty), suite ends with `FAILED (N)`.

- [ ] **Step 3: Add the two pure helpers**

Insert near the other `__tmux_lives_*` helpers in `conf.d/tmux-lives-install.fish` (e.g. just before `function tmux-setup`):

```fish
function __tmux_lives_persistence_note --description 'macOS/non-systemd persistence model (for tmux-setup)'
    echo "no systemd — persistence via continuum autosave + restore on first ts/SSH login"
end

function __tmux_lives_persistence_status --description 'macOS/non-systemd persistence status line'
    echo "OK persistence via continuum autosave + first-access restore"
end
```

- [ ] **Step 4: Wire the helpers into `tmux-setup` and `tmux-status`**

In `tmux-setup`, replace the `else` body (lines 98-100):

```fish
    else
        echo "tmux-setup: no systemd — skipping service layer (macOS/launchd is spec 2)"
    end
```

with:

```fish
    else
        echo "tmux-setup: "(__tmux_lives_persistence_note)
    end
```

In `__tmux_lives_status_lines`, change the systemd block (lines 137-139) from:

```fish
    if type -q systemctl
        systemctl is-enabled tmux-resurrect-save.service >/dev/null 2>&1; and set -a r "OK save service enabled"; or set -a r "MISSING save service (run tmux-setup)"
    end
```

to:

```fish
    if type -q systemctl
        systemctl is-enabled tmux-resurrect-save.service >/dev/null 2>&1; and set -a r "OK save service enabled"; or set -a r "MISSING save service (run tmux-setup)"
    else
        set -a r (__tmux_lives_persistence_status)
    end
```

- [ ] **Step 5: Run the install suite to verify it passes**

Run: `fish tests/test-tmux-install.fish`
Expected: all `ok`/`t` assertions pass, ending with `ALL PASS (N)`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: runtime-only persistence on macOS — intentional non-systemd note + status line (no launchd units)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 3: bare-`ts` cold-start

**Files:**
- Modify: `conf.d/tmux.fish` (add a no-server guard at the top of `ts`'s outside-tmux branch, after line 198)
- Test: `tests/test-tmux-auto.fish` (append a block before the final cleanup/exit)

**Interfaces:**
- Consumes: `__tmux_autostart` (existing; restore→categorize→prune→pick/create→`exec` attach — never returns in production).
- Produces: `ts` (no arg, outside tmux, no server) now invokes `__tmux_autostart` instead of printing "No sessions". A defensive `return` follows the call so a test stub (which does not `exec`) cannot fall through to the real categorize subprocess.

- [ ] **Step 1: Write the failing test**

Append before the final `# ---` / `cleanup` / exit block in `tests/test-tmux-auto.fish`:

```fish
# ---------------------------------------------------------------------
# Component C: bare `ts` cold-starts the full flow when no server runs.
# (Stub __tmux_autostart; the real one execs and never returns.)
# ---------------------------------------------------------------------
cleanup
set -e TMUX
functions -c __tmux_autostart __tmux_autostart_real
function __tmux_autostart; set -g g_autostart_fired 1; end
set -g g_autostart_fired 0
ts
t "ts cold-starts autostart when no server" "1" "$g_autostart_fired"
functions -e __tmux_autostart
functions -c __tmux_autostart_real __tmux_autostart
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-auto.fish`
Expected: `FAIL - ts cold-starts autostart when no server: expected [1] got [0]` (today bare `ts` with no server prints "No sessions" and never calls `__tmux_autostart`), suite ends with `SOME FAILED`.

- [ ] **Step 3: Add the cold-start guard to `ts`**

In `conf.d/tmux.fish`, in `ts`, the outside-tmux section currently begins (line 199):

```fish
    # Outside tmux: truth-up names, then grouped numbered list, then attach.
    fish --no-config $tmux_categorize_script categorize 2>/dev/null
```

Insert the guard immediately above that comment (after the `if set -q TMUX … end` block that ends at line 198):

```fish
    # No server yet (local shell, post-reboot): cold-start the full flow.
    if not tmux has-session 2>/dev/null
        __tmux_autostart   # restore → categorize → prune → pick/create → exec attach
        return             # defensive: __tmux_autostart execs; only reached if stubbed (tests)
    end
```

- [ ] **Step 4: Run the auto suite to verify it passes**

Run: `fish tests/test-tmux-auto.fish`
Expected: `ok   - ts cold-starts autostart when no server`, suite ends with `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux.fish tests/test-tmux-auto.fish
git commit -m "feat: bare ts cold-starts __tmux_autostart when no server (local/macOS launch; both platforms)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 4: Docs + full-suite verification

**Files:**
- Modify: `CLAUDE.md` (status line: macOS port done), `README.md` (Install: note macOS has no systemd units; persistence via continuum + first-access restore)
- Modify: `docs/superpowers/specs/2026-06-20-tmux-lives-macos-port-design.md` (Status → Implemented)

- [ ] **Step 1: Run the full suite — everything green (regression gate)**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: each of the eight suites prints its pass line (`ALL PASS` / `ALL PASS (N)`); no `FAIL`/`SOME FAILED`. This is the no-Linux-regression proof for Tasks 1-3.

- [ ] **Step 2: Update `README.md` Install section**

Under the `## Install` / `tmux-setup` description, add a line noting platform behavior:

```markdown
On Linux (systemd) `tmux-setup` also installs save-on-shutdown + restore-at-boot units. On macOS there are no launchd units — persistence is provided by tmux-continuum's autosave plus restore on your first `ts` / SSH login.
```

- [ ] **Step 3: Update `CLAUDE.md` status**

Change the macOS line in the **Remaining** / status section from "macOS port (spec 2 — …) pending" to reflect that spec 2 is implemented (runtime-only persistence + `/proc`→`ps` detection + bare-`ts` cold-start; live Mac smoke pending). Keep it to the existing terse style.

- [ ] **Step 4: Flip the spec Status to Implemented**

In `docs/superpowers/specs/2026-06-20-tmux-lives-macos-port-design.md`, change `- **Status:** Approved (design)` to `- **Status:** Implemented (Linux suites green; Mac live-smoke pending)`.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md docs/superpowers/specs/2026-06-20-tmux-lives-macos-port-design.md
git commit -m "docs: mark macOS port implemented (CLAUDE.md, README, spec status)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

- [ ] **Step 6: Re-publish the updated spec + README to the vault**

Re-run `vault-publish` on the spec (and README if it qualifies) so the vault copy reflects the Implemented status; reflow the vault copy to single-line paragraphs (no hard wrap).

---

## Post-implementation (out of plan, user-owned)

**Mac live-smoke (required before claiming macOS "done"):** on the Mac — (1) launch `claude` in a pane and confirm the session categorizes as `claude` (exercises the `ps` detection branch); (2) from a plain shell with no server, run `ts` and confirm it cold-starts/attaches; (3) reboot, then `ts` / SSH and confirm session skeletons restore. This is the platform path that cannot be exercised on the Linux dev host.

## Self-review notes

- **Spec coverage:** A → Task 2; B → Task 1; C → Task 3; testing strategy (dual-branch `ps`, pure-fn messaging, `-L` socket decision test, all-suites-green) → Tasks 1-4; docs → Task 4; Mac smoke → Post-implementation. launchd rejection needs no task (it's a non-goal).
- **Placeholders:** none — every code/test step shows the actual fish.
- **Type/name consistency:** `__tcz_pid_comm` / `__tcz_pid_cmdline` (Task 1), `__tmux_lives_persistence_note` / `__tmux_lives_persistence_status` (Task 2), `tcz_force_ps` seam — used identically wherever referenced.
