# Auto-refreshing stale shells after an update — Design

**Date:** 2026-08-14
**Status:** approved, not built

## Problem

`fisher update` sources the new plugin files into the shell that ran it. Every *other* running fish shell keeps the old function definitions until it is restarted. Today the plugin detects those shells (`__tmux_lives_stale_sessions`) and tells the user to run `exec fish` in each — advice that is correct, tedious, and impossible to follow in a pane running Claude, since `exec fish` cannot run while a foreground program owns the terminal.

The user asked whether the updater could do it for them, and anticipated the obvious objection themselves: *"If it uses send-keys I suppose that wouldn't work for claude sessions though, right?"*

## Why not send-keys

Correct. `send-keys` writes into the pane's tty as if typed, so in a Claude pane it lands in Claude's input box and submits it.

It *is* gateable — `pane_current_command` reports what a pane is running, and `__tmux_lives_stale_shells` already parses that field — but two problems survive the gate. A shell sitting at a prompt with half-typed input gets `exec fish` appended to whatever the user had started typing. And `pane_current_command` reads `fish` for a running fish *script* too, so "idle at a prompt" is not reliably detectable from it.

## The mechanism, measured

Fish fires `--on-variable` handlers on a **universal** variable in shells that are **already running**, when a *different* shell sets it. Verified directly in an isolated `XDG_CONFIG_HOME`:

| question | measured |
|---|---|
| Does the handler fire in an already-running idle shell? | **Yes** |
| Does it fire while the shell has a **foreground child**? | **No — deferred until the child exits** |
| How many times does one `set -U` fire it? | **2** in the observed run — so the handler must be idempotent |
| Does setting the **same value** still fire it? | **Yes** — the event gives no free change-detection |

> **⚠️ The second row was WRONG in the first version of this spec, and the correction changes what a user observes.** It originally read "Yes — one firing while a 12 s `sleep` held the foreground", and the design was built on a Claude pane refreshing *immediately*. That measurement was a **false positive**: the probe registered its handler in `conf.d`, so the separate `fish -c 'set -U …'` process that fired the event **loaded the same handler and fired it on itself**. The firing counted as "during" came from the setter, not from the shell under test.
>
> Caught by Task 1's implementer, who could not reproduce the result with a handler defined only in the live session, and confirmed independently by logging `$fish_pid` in the handler: during the job only the setter's pid appears; the interactive shell's pid appears 13 s later, when `sleep 15` finished. The implementer also ruled out a notification-latency explanation by repeating it with `--on-signal USR1`, a mechanistically different delivery path, and seeing the same deferral. **Fish is single-threaded and dispatches no handler of any kind until control returns to its main loop.**

**What the correction does and does not change.** The feature still works and still needs no `send-keys`: a shell running Claude refreshes **the moment Claude exits**, with no user action. What changes is the timing claim — *"refreshes immediately"* was wrong — and the justification for the idle check.

**The idle predicate is no longer the mechanism that prevents output landing mid-frame; fish's scheduler already guarantees that.** It is kept as a cheap guard for the cases the scheduler does not cover (no controlling tty, a background job holding the terminal) and because it costs one `/proc` read. It should not be described as load-bearing.

The fourth row means change-detection has to live in the emitter, not the event.

Re-sourcing a live shell is already safe by construction here: `__tmux_should_autostart` returns early on `set -q TMUX`, and `conf.d/tmux.fish`'s startup trigger carries a stack-trace guard that exists precisely because fisher re-sources `conf.d` on every install and update.

## Design

### 1. `__tmux_lives_shell_is_idle` — the predicate everything rests on

Returns true when the shell owns its terminal, i.e. no child is in the foreground. The test is the terminal's foreground process group versus the shell's own: Linux reads `tpgid` and `pgrp` from `/proc/$fish_pid/stat`; macOS uses `ps -o tpgid=,pgid= -p $fish_pid`. This mirrors the `__tcz_pid_comm` / `__tcz_pid_cmdline` portability pattern already used by the categorizer.

**With no controlling tty (`tpgid` of `-1`) it returns false.** "Unsure" must mean "do not print" — every failure of this predicate is a corrupted frame in someone's editor.

Known edge, accepted: a long-running fish *function* forks nothing, so fish itself stays in the foreground and the shell reads as idle. Fish dispatches events between statements, so the window is small.

### 2. `__tmux_lives_reload` — the handler

Registered `--on-variable tmux_lives_reload_token`. In order:

1. Return unless `status is-interactive`.
2. Return if `tmux_lives_autoreload` is `0`.
3. Re-source **only** `conf.d/tmux.fish` and `conf.d/tmux-lives-install.fish`. Nothing else in the user's config is touched.

   **Why not `functions/tmux-categorize.fish`, which fisher also replaces.** It is never autoloaded — every call site invokes it as a script (`fish --no-config $tmux_categorize_script <verb>`, resolved once at `conf.d/tmux.fish:10`), and a repo-wide grep finds zero bare-name invocations. A script run reads the file from disk each time, so a running shell cannot hold a stale categorizer. Re-sourcing it into an interactive shell would instead *define* ~104 `__tcz_*` functions that shell has never needed.

   Worth recording because it is unintuitive and was verified rather than assumed: **fish does not reload an autoloaded function when its file changes on disk.** A shell that had autoloaded the categorizer would keep the old definitions for its whole life. That is not reachable today, but it is the reason this decision must be revisited if any call site ever switches to the bare function name.
4. If `__tmux_lives_shell_is_idle`, print one line and `commandline -f repaint` so fish redraws its prompt beneath the notice. Otherwise print nothing.

**Idempotency is a requirement, not a nicety** — one `set -U` was measured firing the handler twice.

### 3. The trigger

In `_tmux_lives_post_update`, **before** the `set -q _tmux_lives_updating; and return` early return. That placement is load-bearing: below it, plain `fisher update` would refresh other shells while `tmux-lives update` silently would not, and the difference would be invisible until someone noticed the two paths disagreeing.

Compute a fresh `__tmux_lives_digest` over the installed files and `set -U tmux_lives_reload_token` **only when it differs from the stored token**. Since the event fires even on an unchanged value, this is the only thing preventing a no-op update — and fisher always re-fetches, so no-op updates are the common case — from refreshing every shell and printing in every idle one.

### 4. The note stops lying

`__tmux_lives_update_note` currently ends with "Other shells still run the old version: … — run `exec fish` in each." Once shells refresh themselves that is wrong, but it is *right* exactly once: on the first update carrying this feature, the already-open shells have no handler.

The updating shell can tell the two apart, because it knows whether `tmux_lives_reload_token` existed **before** it set it:

- **previously unset** → first update with the feature → keep today's `exec fish` advice, which is still true.
- **previously set** → those shells carry the handler → report that they refreshed, and drop the instruction.

The removed-function warning is unchanged in both branches. Sourcing cannot unset a function, so a removal still needs a real `exec fish` in the updating shell.

### Opt-out

`tmux_lives_autoreload`; `set -U tmux_lives_autoreload 0` disables. Default on.

**Recorded rather than slipped past:** this is a third `set -U`-only knob, alongside `tmux_lives_cursor_style` and `tmux_lives_sync_terminals`, and it cuts against the standing preference that configuration lives in the `setup` command. The user chose consistency with the existing two over growing this spec; gathering all three into `setup` is a later pass.

## Testing

- **The predicate needs a real pty.** Idle shell → true; shell with a foreground child → false. No grep-shaped assertion can see this, and it is the one component whose failure has a visible cost.
- **The handler:** fires in an already-running shell; re-sources (a function changed on disk is live afterwards); is idempotent across repeated firings; is **silent** when a foreground child is running; prints exactly one line when idle; honours the opt-out.
- **The trigger:** fires on `fisher update` *and* on `tmux-lives update`; does **not** fire when the digest is unchanged.
- **The note:** both branches render correctly — bootstrap (token previously unset) and steady state — and the removed-function warning survives in each.

### Landmines specific to this repo

- `tests/test-tmux-categorize.fish` has no pass counter: an undefined function called directly inside a `t` invocation aborts the statement, prints nothing, and the suite still reports `ALL PASS`. Capture into a variable first.
- Tests must never write to the user's real universal store. Every suite opens with the `XDG_CONFIG_HOME` self-re-exec guard; `set -U tmux_lives_reload_token` in a test would otherwise reach the live store and fire handlers in the user's real shells.
- The agent Bash tool runs **zsh**: MULTIOS corrupts `cmd 2>&1 >/dev/null | wc -c` stderr counts (wrap in `bash -c`), and non-matching globs abort the command.
- A pty probe that `wait`s on an interactive fish will hang, because the shell outlives its sourced command. Bound every pty harness with `timeout` and never block on it.

## Limitations that will remain

1. **Removed or renamed functions still require `exec fish`.** Sourcing cannot unset. Already detected by `__tmux_lives_removed_functions`; the note keeps warning about it.
2. **The first update after this ships does not reach already-open shells** — they have no handler yet. Handled honestly by the note's bootstrap branch rather than papered over.
3. **Printing when idle is a deliberate risk the user accepted.** If the predicate is ever wrong, the notice corrupts whatever is drawing. The agreed fallback is switching the handler to always-silent, which is a one-line change.

## Out of scope

- Anything using `send-keys`.
- Refreshing other plugins or the user's own functions — this re-sources only the two files fisher replaced.
- Giving the three `set -U`-only knobs a `setup` home.
