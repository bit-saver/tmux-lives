# Design — ShellFish-aware client attach: per-server bar color + non-ShellFish baseline

**Date:** 2026-06-27
**Status:** Designed (awaiting user review → writing-plans)
**Scope:** Feature 1 of 2. Feature 2 ("drive tmux-lives from inside tmux — command menu + keybindings + Claude scratch split") is a separate spec.

## Summary

Add a tmux `client-attached` hook (installed by the tmux-lives managed fragment) that reacts to *which kind of client just attached*:

- **ShellFish client →** set this server's ShellFish toolbar/tab color (per-server color identity), by emitting the `setbarcolor` escape directly to the attaching client's tty.
- **Non-ShellFish client →** re-apply the user's own tmux settings from a user-owned file `~/.tmux-lives.conf`, so settings ShellFish's integration forced globally (notably `mouse on`) never *leak* into plain-terminal sessions.

The fish-side ShellFish integration (helper functions, OSC-7 cwd hook) is left strictly ON-only and untouched; this feature only manages the **bar color** (per-client, via the client tty) and the **tmux-side server options** (via the baseline file).

## Goals

1. When I connect to a server from ShellFish, its tab takes that server's configured color — automatically, on every attach, including reconnects and attaches to pre-existing sessions.
2. The color reaches only the ShellFish client, not a co-attached plain terminal.
3. When I connect from a non-ShellFish terminal, my own tmux preferences (e.g. `set -g mouse off`) are re-asserted and ShellFish's forced settings do not stick.
4. My preference file is user-owned and never clobbered by `tmux-lives setup` or by ShellFish.
5. Zero new files in `conf.d/`/`functions/` (one-file-per-feature convention); no dependency on the ShellFish-owned `shellfish.fish` being loaded.

## Non-goals (explicitly out of scope)

- Flipping the **fish-side** integration (functions, cwd OSC) on/off per client — it stays ON-only; it is shell-startup-bound and harmless when left on.
- Forcing `mouse on` on the ShellFish side — that remains ShellFish's own integration's job; this feature imposes no mouse opinion on the ShellFish branch.
- Per-client behavior for two clients attached to the **same** session simultaneously (see Limitations).
- Feature 2 (in-tmux command surface).

## Background and key mechanics

These were established/verified during brainstorming (2026-06-27) and drive the design.

**The ShellFish integration gate is startup-time and per-shell.** `~/.config/fish/conf.d/shellfish.fish` (ShellFish-authored, ~413 lines, regenerated on app updates) wraps essentially the whole integration in one `if test "$LC_TERMINAL" = "ShellFish"` block evaluated once when each fish shell sources conf.d. We cannot durably edit it and must not depend on its internal structure.

**Two kinds of state, different rules.** The integration sets (a) **tmux-side server options** — `set -g mouse on`, `set -g allow-passthrough on` — which live in the tmux server and are freely mutable at any time (`tmux set -g …`), independent of the startup gate; and (b) **fish-side shell state** — helper functions and the `update_terminal_cwd --on-variable PWD` hook — which are baked into each shell at birth and cannot be cleanly unloaded per-attach. This feature only touches (a).

**`setbarcolor` is a trivial, reproducible escape.** From the live definition: it emits `ESC ] 6 ; settoolbar://?ver=2&color=<base64(color)> BEL`, wrapped in tmux DCS passthrough (`ESC P tmux; ESC ESC ] … BEL ESC \`) only when emitted from *inside* a tmux pane. We reproduce this ourselves and therefore do not need the `shellfish.fish` function loaded.

**Writing to `#{client_tty}` is inherently per-client.** `#{client_tty}` is the tty tmux uses to talk to one specific client. Writing the color escape there reaches only that ShellFish tab, not a co-attached plain terminal. Because we write at the client-tty level (above tmux's pane multiplexing), we use the **non-passthrough** form `ESC ] 6 ; settoolbar://?ver=2&color=<base64> BEL` — the passthrough wrapper is only for pane→client forwarding.

**Detection is via the attaching client process's environment, not the session env.** Reading `LC_TERMINAL` from `/proc/<client_pid>/environ` (Linux) or `ps eww` (macOS) is race-free: the client process's environment is fixed at SSH-session creation. This sidesteps any ordering question about whether `client-attached` fires before/after tmux's `update-environment` populates the session env. (`update-environment` reflecting `LC_TERMINAL` into the session env is a conceptual fallback, not the chosen mechanism.)

## Architecture

One always-installed `client-attached` hook → one categorizer subcommand that branches on client type. All logic lives in the existing categorizer; the fragment only wires the hook; config lives in the existing install file. No new files.

### The hook (rendered into the managed fragment)

`__tmux_lives_render_fragment` (in `conf.d/tmux-lives-install.fish`) gains an always-present hook:

```tmux
set-hook -g client-attached {
    run-shell "fish --no-config <cat> on-attach '#{client_pid}' '#{client_tty}' '<color>'"
}
```

- `<cat>` is the categorizer path already interpolated elsewhere in the fragment.
- `<color>` is the configured per-server color (may be empty), baked in at render time — exactly how the switcher keys are baked in today. The hook is installed **unconditionally** (even with no color) because it also drives the non-ShellFish baseline branch.
- This coexists with the existing `client-session-changed` commandeer hook; they are independent tmux hooks.

### The categorizer subcommand `on-attach <client_pid> <client_tty> [color]`

New code in `functions/tmux-categorize.fish` (joins the existing subcommand dispatch alongside `categorize|commandeer|ghosts|…`):

1. `__tcz_client_is_shellfish <client_pid>` — true iff the client process's environment contains `LC_TERMINAL=ShellFish`.
2. **If ShellFish and a color is set:** `__tcz_emit_barcolor <client_tty> <color>` — write the non-passthrough escape to the tty.
3. **If not ShellFish:** if `~/.tmux-lives.conf` exists, `tmux source-file ~/.tmux-lives.conf`.

Helper decomposition (kept small and testable):

- `__tcz_pid_environ <pid>` — echo the process environment: `tr '\0' '\n' < /proc/<pid>/environ` on Linux (one `KEY=VALUE` per line); `ps eww -p <pid>` on macOS (env appended after the command on a single line). Reuses the existing `/proc`→`ps` platform split (`__tcz_pid_comm`/`__tcz_pid_cmdline`). A test seam variable (e.g. `tmux_lives_fake_environ`) short-circuits this to a literal string so detection is unit-testable without a real process.
- `__tcz_client_is_shellfish <pid>` — `string match -q '*LC_TERMINAL=ShellFish*' -- (__tcz_pid_environ <pid>)`. A **substring** match (not exact-line) deliberately, so it works for both shapes: the Linux per-line output and the macOS single-line `ps eww` output. ShellFish delivers exactly `LC_TERMINAL=ShellFish` (capital F), with a delimiter (newline/space/end) after it, so the substring match is unambiguous; `LC_TERMINAL_VERSION=…` does not false-match (different key prefix).
- `__tcz_emit_barcolor <tty> <color>` — `printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' <color> | base64) > <tty>`. Writing to a path makes it testable against a tempfile.

### Config surface 1 — per-server color (`tmux-lives setup color`)

Single value → universal var + fragment re-render, mirroring `setup keys`.

- `tmux-lives setup color` (no arg) → print the current color (or `(none)`).
- `tmux-lives setup color <css>` → `set -U tmux_lives_bar_color <css>`; `__tmux_lives_write_fragment` (re-renders + reloads). Accepts any CSS-style color ShellFish understands (`red`, `#1f6feb`, `rgb(…)`, `color(p3 …)`).
- `tmux-lives setup color ""` (empty) → unset/clear → no color emitted (hook stays installed for the baseline branch).

`__tmux_lives_render_fragment` reads `tmux_lives_bar_color` (via the existing `__tmux_lives_key` helper, default empty) and bakes it into the hook line.

### Config surface 2 — non-ShellFish baseline (`~/.tmux-lives.conf` + `tmux-lives setup conf`)

A **user-owned** tmux config file holding free-form tmux commands to enforce when a non-ShellFish client attaches. This is a deliberate exception to the usual "config via command/universal-var" pattern, justified because the data is an open-ended *list* of arbitrary tmux commands, not a single value — a `.conf` file is the natural container and `source-file` applies it directly.

- **Path:** `~/.tmux-lives.conf` (in `$HOME`, a deliberately-named sibling to the hand-maintained `~/.tmux.conf`).
- **Ownership:** seeded **once** with a commented template if absent (by `tmux-lives setup install`); **never overwritten** by setup — unlike the generated `~/.config/tmux/tmux-lives.conf` fragment. ShellFish never touches it.
- **Seed template:**
  ```tmux
  # tmux-lives baseline — re-applied whenever a NON-ShellFish client attaches.
  # Put tmux settings here that ShellFish's integration shouldn't get to keep.
  # Example:
  # set -g mouse off
  ```
- **Command proxy** (`__tmux_lives_conf_cmd`, convenience over hand-editing — hand-editing stays first-class):
  - `tmux-lives setup conf` → print the file path + its current contents.
  - `tmux-lives setup conf edit` → open it in `$EDITOR` (creating from the template first if absent).
  - `tmux-lives setup conf add '<tmux command>'` → append the line (create from template if absent) and `tmux source-file` it live.

### Help / dispatch wiring

- `__tmux_lives_setup_dispatch` gains `color` and `conf` cases.
- Both also join the hidden top-level shortcuts (`case install i verify v teardown keys auto color conf`) so `tmux-lives color …`/`tmux-lives conf …` work, consistent with `tmux-lives auto …`.
- `__tmux_lives_setup_help_lines` gains tight one-line entries for `color` and `conf` (must keep the framed page within 80 columns).
- `__tmux_lives_status_lines` (the `setup verify` output) gains lines for: configured color (or none), `~/.tmux-lives.conf` present/absent, and that the client-attached hook is wired.

## Behavior walkthroughs

- **Attach from ShellFish to any session (incl. pre-existing):** `client-attached` fires → `on-attach` reads the client's env → `LC_TERMINAL=ShellFish` → emits the color to that client's tty → the ShellFish tab takes the server color. Independent of whether the pane's shell ever ran `shellfish.fish`.
- **ShellFish tmux-toggle tab (`shellfish-N` springboard):** `client-attached` fires on the springboard attach → color emitted (client env still ShellFish). The existing commandeer hook (`client-session-changed`) then bounces the client to a real categorized session; the color persists on the tab (it's per-server). No conflict.
- **Attach from a plain terminal:** `on-attach` finds no `LC_TERMINAL=ShellFish` → if `~/.tmux-lives.conf` exists, sources it → e.g. `mouse` snaps back to the user's preference, undoing any `mouse on` a prior ShellFish shell forced.
- **Reconnect / re-attach:** `client-attached` fires again → idempotent re-emit / re-source.

## Testing strategy

Extends the existing `tests/test-tmux-*.fish` suites (sourcing the categorizer / install file with the startup trigger suppressed, as today). New/extended coverage:

- **Detection** — set the `tmux_lives_fake_environ` seam to `LC_TERMINAL=ShellFish` and to an empty/other value; assert `__tcz_client_is_shellfish` returns true/false accordingly.
- **Color emission** — call `__tcz_emit_barcolor <tempfile> "#1f6feb"`; assert the tempfile contains exactly `\033]6;settoolbar://?ver=2&color=<base64("#1f6feb")>\a` (deterministic bytes).
- **`on-attach` branching** — with the seam set ShellFish vs not, assert the ShellFish path writes the color to the given tty-path and the non-ShellFish path resolves the baseline file and only acts when it exists (the `tmux source-file` itself is left to live verification).
- **Color config** — `setup color <css>` sets `tmux_lives_bar_color` and the re-rendered fragment contains the color baked into the `on-attach` hook line; `setup color ""` clears it and the hook is still present.
- **Fragment render** — `__tmux_lives_render_fragment` emits exactly one `client-attached` hook calling `on-attach`, regardless of color.
- **Baseline file** — `setup conf add '…'` creates the file from the template when absent and appends; `setup install` seeds it once and a second `install` does not overwrite an edited file.
- **Help/verify** — `color` and `conf` appear in setup help; the framed setup page stays ≤ 80 columns; `verify` reports the new lines.

## Limitations and live-verification items

- **Simultaneous mixed clients:** `mouse` (and other global options) are a single server value; a ShellFish and a plain client attached to the same session at once share it — it follows whichever attached last. The baseline cleanly handles *sequential* use, not truly-simultaneous mixed clients.
- **Client-tty write race (verify live):** writing a single short OSC directly to `#{client_tty}` interleaves with tmux's own frame writes; it is atomic and self-delimited, so the risk is low, but this is the one thing to confirm visually on a real ShellFish attach.
- **macOS env read (verify live):** the `ps eww` environment read needs the pending live Mac smoke (consistent with the existing Mac-smoke TODO). `/proc` covers the Linux host.
- **Deployment:** per project policy, a Claude session never deploys; after merge to `main` the user runs `fisher update` + `exec fish`, then adds a color via `tmux-lives setup color …` and (optionally) a `~/.tmux-lives.conf`.

## Files touched (no new files)

- `conf.d/tmux-lives-install.fish` — render the `client-attached` hook (+ bake color) in `__tmux_lives_render_fragment`; `__tmux_lives_color_cmd`, `__tmux_lives_conf_cmd`; `setup` dispatch + hidden top-level cases; setup help lines; `verify` status lines; seed `~/.tmux-lives.conf` in `__tmux_lives_setup`.
- `functions/tmux-categorize.fish` — `__tcz_on_attach`, `__tcz_client_is_shellfish`, `__tcz_pid_environ`, `__tcz_emit_barcolor`; `on-attach` subcommand dispatch + usage string.
- `tests/test-tmux-install.fish`, `tests/test-tmux-categorize.fish` (and/or a focused suite) — the coverage above.
- `README.md`, `CLAUDE.md` — document `setup color`, `setup conf`, `~/.tmux-lives.conf`, and the client-attached behavior.
