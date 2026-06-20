# tmux-lives macOS port — runtime-only persistence + portable detection

- **Date:** 2026-06-20
- **Status:** Approved (design)
- **Project:** tmux-lives (fisher plugin)
- **Component:** install/setup layer (`tmux-lives-install.fish`), categorizer
  (`tmux-categorize.fish`), `ts` launcher (`tmux.fish`)

## Background

tmux-lives is shipped and live on the Linux (systemd) host. `CLAUDE.md` has long flagged
"macOS = spec 2." The plugin already *installs* on macOS via fisher, but three Linux-isms stop
it from *functioning* there. A full scan of `conf.d/` + `functions/` confirms these are the
**only** portability issues — there is no `stat`, `sed -i`, `date -d`, `readlink -f`, or
`realpath`; `mktemp`, `id`, and `pgrep -P` are already portable.

1. **Service layer.** `tmux-setup` / `tmux-teardown` / `tmux-status` install and check systemd
   units inside `if type -q systemctl` branches (`tmux-lives-install.fish:89, 117, 137`). macOS
   has no systemd, so the service layer is simply skipped today (a stub `else` that says "spec
   2").
2. **Claude detection.** The categorizer reads `/proc/$pid/comm` and `/proc/$pid/cmdline`
   (`tmux-categorize.fish:57, 58, 77`) to decide whether a pane is running `claude`. macOS has
   no `/proc`, so categorization silently fails to detect claude sessions.
3. **Local launch gap.** Auto-attach is gated to interactive **SSH** logins
   (`tmux.fish:149, 304`). Sitting locally at the Mac in iTerm2/Cmux (a non-SSH shell), tmux-lives
   never engages; bare `ts` with no server running just prints
   `No sessions. Create one with: ts <name>`.

**Mac usage (confirmed with the user):** both SSH (from iPad / ShellFish) *and* local (iTerm2 /
Cmux). The user wants cross-reboot persistence parity with the Linux host.

## Decision

Three components, all in **existing** files (zero net-new `conf.d/` or `functions/` files, per the
file-hygiene preference). **No Linux behavior change** for components A and B; component C makes one
intentional, beneficial change to a rarely-hit Linux edge (accepted, applied on both platforms).

### A. Service layer → runtime-only (no launchd units)

macOS persistence is achieved entirely by the **existing runtime layer**, not by a launchd
service:

- **Save:** tmux-continuum's periodic autosave, already in the managed fragment
  (`@continuum-save-interval '15'`).
- **Restore:** first-access restore — `__tmux_autostart` → `__tmux_restore` (which runs when no
  server exists). This already fires on SSH login, and (via component C) on the first bare `ts`.

No `launchctl` units are installed. `tmux-setup` / `tmux-teardown` / `tmux-status` get refined
non-systemd branches:

- `tmux-setup`: the existing non-systemd `else` (`tmux-lives-install.fish:98-100`) is reworded from
  "…macOS/launchd is spec 2" to describe the real model:
  *"no systemd — persistence via continuum autosave + restore on first `ts`/SSH login."*
- `tmux-status`: add an `else` to the systemd block (`:137-139`) so macOS reports a real line —
  `OK persistence via continuum autosave + first-access restore` — instead of silently omitting
  the service line.
- `tmux-teardown`: no change needed; its systemd block (`:117-124`) already no-ops when `systemctl`
  is absent (nothing to remove on macOS).

The gate stays `type -q systemctl` (correct for both macOS and a non-systemd Linux). The systemd
unit-text functions (`__tmux_lives_save_unit_text`, `__tmux_lives_restore_unit_text`) are left
untouched — Linux-only.

**Why runtime-only (rejected: LaunchAgent / LaunchDaemon).** launchd has no clean "run on
shutdown" hook, so a shutdown-save unit is impossible to do well — save degrades to continuum's
≤15-min window regardless. And resurrect-restore only restores session/window/pane **skeletons**
(layout + cwd + captured text), never live processes (matches the Linux note: "headless restore
relaunches NOTHING"); since the runtime already rebuilds those skeletons on first access, a
boot-time daemon (LaunchDaemon, root, RunAtLoad) or login agent (LaunchAgent) would only make the
skeletons appear a few seconds earlier, at the cost of sudo and the fiddly root→user tmux launch.
Functional parity is reached without any launchd unit.

### B. Portable claude-detection (`/proc` → `ps`)

Two new helpers in `tmux-categorize.fish` abstract the three `/proc` reads; the Linux path stays
byte-identical (the helper auto-selects `/proc` whenever it is readable, which is always on Linux):

- `__tcz_pid_comm <pid>` → the executable name (empty on failure, `2>/dev/null`).
  - Linux: `cat /proc/$pid/comm`.
  - else (macOS): `ps`-based — the basename of the process executable.
- `__tcz_pid_cmdline <pid>` → the space-joined argv (empty on failure).
  - Linux: `string split0 < /proc/$pid/cmdline | string join ' '`.
  - else (macOS): `ps`-based full argv.
- Selection: `test -r /proc/$pid/comm` (per-call auto-detect; no global platform flag).

The exact `ps` invocation/flags are finalized under TDD + the user's Mac smoke (macOS `ps -o comm=`
returns a path, so it is basename'd; `claude` must resolve to comm `claude` the same way it does via
`/proc/comm` on Linux). The three call sites — `__tcz_cmdline_name` (`:56-58`) and
`__tcz_pane_is_claude` (`:77`) — route through the helpers. `pgrep -P` (`:56`) is already portable
and stays.

### C. bare-`ts` cold-start (both platforms)

In `ts`'s outside-tmux branch (`tmux.fish:199`), before building the overview list:

```fish
if not tmux has-session 2>/dev/null
    __tmux_autostart   # restore → categorize → prune → pick/create → exec attach
end
```

With no server, `ts` cold-starts the full flow (it `exec`s, so it never returns to the list code).
Because this is **explicit** user intent, it deliberately **ignores the `tmuxauto off` sentinel**
(the sentinel governs only the automatic login trigger, not manual `ts`; `__tmux_autostart` itself
does not check it). Everything else about `ts` is unchanged: inside tmux → popup switcher;
`ts <name>` → create/attach; bare `ts` *with* a server → the numbered grouped list. The old
"No sessions" message becomes a rare fallback (server up, zero sessions).

This is the one place Linux behavior changes: bare `ts` outside tmux with **no server** previously
printed `No sessions…` and now cold-starts. Rare on the Linux host (SSH login already auto-attaches)
and strictly more useful; applied on both platforms for consistency (no platform branch in `ts`).

## Constraints

- **File hygiene (hard).** Zero net-new files in `conf.d/` or `functions/`. The B helpers go in the
  existing `tmux-categorize.fish`; A edits the existing `tmux-lives-install.fish`; C edits the
  existing `tmux.fish`. Underscore-prefix the new helpers. New test assertions go into the existing
  `tests/` files where they fit; a new test file is added only if a component needs a clean home
  (`tests/` is not a config-browse dir, so a file there does not violate the hygiene rule).
- **No Linux regression.** A and B are byte-identical on the Linux runtime path; C's single edge
  change is intentional. The existing suites are the guard (see Testing).
- **Pure fish / no new dependency.** Only `tmux`, `ps`, `cat`, `stty`, `pgrep`, fish builtins —
  all present on stock macOS.

## Architecture / files touched

- `functions/tmux-categorize.fish` — add `__tcz_pid_comm`, `__tcz_pid_cmdline`; route
  `__tcz_cmdline_name` + `__tcz_pane_is_claude` through them. (existing file)
- `conf.d/tmux-lives-install.fish` — reword `tmux-setup` non-systemd note; add the macOS `else`
  line in `__tmux_lives_status_lines`. (existing file)
- `conf.d/tmux.fish` — add the no-server cold-start guard at the top of `ts`'s outside-tmux branch.
  (existing file)
- `tests/test-tmux-categorize.fish` (and/or `tests/test-tmux-install.fish`) — new assertions; a new
  test file only if a clean home is needed.
- Docs: this spec; the implementation plan; `CLAUDE.md` / `README.md` status updates (drop "macOS =
  spec 2" → "ported").

## Testing

- **B is fully testable on the Linux dev host** — `ps` exists on Linux too, so both branches can be
  exercised here: `__tcz_pid_comm $fish_pid` via `/proc` and via a forced-`ps` seam must both return
  `fish`; `__tcz_pid_cmdline $fish_pid` must contain `fish` on both paths. This gives real
  cross-branch coverage without a Mac. (Helper takes a testable seam to force the `ps` path.)
- **A**: pure-function assertions on the macOS messaging (the reworded note + the macOS status line),
  mirroring the existing systemd-unit-text tests in `test-tmux-install.fish`. Force the non-systemd
  path via the same seam pattern the install tests already use.
- **C**: on an isolated `-L` socket, assert the no-server → `__tmux_autostart` decision is reached;
  the `exec`/attach itself needs a tty, so it is covered by the Mac smoke, not a unit test.
- **All existing suites must still print `ALL PASS`** (`test-tmux-auto`, `test-tmux-restore`,
  `test-tmux-categorize`, `test-tmux-shellfish`, `test-tmux-install`, `test-tmux-status`,
  `test-generic`, `test-tmux-popup`) — this is the no-Linux-regression guard for A and B.
- **Mac live-smoke (user, on the target):** claude panes categorize correctly; `ts` cold-starts
  from a plain shell; reboot → `ts`/SSH restores the session skeletons. Mirrors how the Linux popup
  switcher was validated. This is a required, explicitly-flagged step — it is not skipped or proxied.

## Risks & mitigations

- **macOS `ps` comm/argv format differs from `/proc`.** `-o comm=` returns a path (basename it);
  argv from `ps` is space-joined and cannot perfectly reconstruct NUL-separated argv — acceptable,
  since the existing code already space-joins `cmdline` before extracting `--name`. Finalize flags
  under TDD + Mac smoke.
- **claude not detected on macOS** if its kernel comm differs from `claude` (e.g., a node wrapper).
  Same assumption the Linux `/proc/comm` path already makes; verified by the Mac smoke.
- **C surprises a Linux user** who relied on the "No sessions" message. Low risk (rare path, more
  useful behavior); documented in the changelog/CLAUDE.md.

## Out of scope (possible follow-ups)

- A richer launcher command (`restart`/`new` subcommands, "restart with certain arguments") — the
  user reframed their original ask into component C; the broader launcher is a separate spec if ever
  wanted.
- Reducing the plugin's total file count further (merging install into the runtime conf.d) — noted
  with the file-hygiene preference, not bundled here.
- launchd units (LaunchAgent/LaunchDaemon) — explicitly rejected above; revisit only if boot-time
  (pre-login) skeletons ever become a real need.
