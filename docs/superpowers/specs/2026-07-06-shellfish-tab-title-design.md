# Design — ShellFish tab title (settitle / OSC 2)

**Date:** 2026-07-06
**Status:** Designed (approved in brainstorming → writing-plans next)
**Repo:** tmux-lives (`functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`)
**Builds on:** the ShellFish per-client emit path — `__tcz_emit_barcolor` (OSC to `#{client_tty}`), `__tcz_recolor` (per-client `list-clients` loop), the `client-attached`→`on-attach` hook, and the ~15s status-right tick.

## Why

ShellFish tabs default to an uninformative title. ShellFish's shell integration added a `settitle` helper that sets the tab/window title via the **standard OSC 2** escape (`\033]2;<title>\a`; inside tmux it wraps in a passthrough DCS, but that's only for interactive use). tmux-lives already knows, per session, the program / directory / claude-state, and already emits the ShellFish bar color directly to each client's tty. A tab title is the same shape of emission — so each ShellFish tab can show `<host>: <dir> [(C)]` and always tell you where you are.

## Goals

- Each attached ShellFish tab shows `<host>: <dir> [(C)]` — short hostname, the active pane's directory basename, and ` (C)` when claude runs in that session. E.g. `macwork: tmux-lives (C)`, `rocket: neurotto`.
- The title reflects **that tab's** current session (per-client), and refreshes on attach, on session-switch (instant), and on the ~15s tick (drift/self-heal) — the same resilience model as the bar color.
- Zero effect on non-ShellFish clients.
- No test touches the live tmux server / universals (the project's hard isolation invariant).

## Non-goals (YAGNI)

- No `setup title on/off` config surface yet (always-on for ShellFish; a toggle is a trivial later add, deferred).
- No user-templatable format — the format is fixed (`<host>: <dir> [(C)]`).
- No title for non-ShellFish terminals (OSC 2 would work universally, but the request is ShellFish and we keep parity with the bar-color gating; universal titles are a possible later extension).
- No instant refresh on *window* switch within a session — the ≤15s tick covers it (only cross-session switch gets a dedicated hook).

## Design

### Emission — mirror the bar-color path

Two new categorizer functions, siblings of `__tcz_emit_barcolor` / `__tcz_recolor`:

- **`__tcz_emit_title <tty> <title>`** — write plain OSC 2 straight to the client tty:
  `printf '\033]2;%s\a' "$title" > $tty`.
  Direct-to-device (not tmux passthrough), exactly like `__tcz_emit_barcolor` — so it reaches the real ShellFish terminal even though the process runs inside tmux. An empty title is a no-op guard.
- **`__tcz_retitle`** — iterate every attached client, filter to ShellFish, emit each client's own title:
  `tmux list-clients -F "#{client_pid}\t#{client_tty}\t#{client_session}"` → for each, `__tcz_client_is_shellfish $pid`; if so, `__tcz_emit_title $tty (__tcz_session_title $session)`.
  (Same loop as `__tcz_recolor`, extended to carry `#{client_session}` so the title is per-tab.)

### Title content — `__tcz_session_title <session>`

Builds `<host>: <dir> [(C)]` for a given session:
- **host** — `hostname -s` (short name; works on Linux + macOS), read once and cached in a script-scoped/universal var (`tmux_lives_hostname`) to avoid a subprocess per emit.
- **dir** — the session's active-window active-pane `#{pane_current_path}`, taken to `basename`, with `$HOME` shown as `~`.
- **(C)** — appended when the session is a claude session, reusing `__tcz_pane_is_claude` over the session's panes (session-wide, matching the existing claude *category*, so the flag means "claude is running in this session" regardless of which window is focused).

The pure string assembly is split into **`__tcz_format_title <host> <dir> <is_claude>`** (no tmux/I-O) so it is unit-testable; `__tcz_session_title` does the tmux queries then calls it.

### When it fires (resilience triggers)

- **`client-attached`** — the existing hook already calls `on-attach` (bar color). Extend so a ShellFish attach also re-titles (simplest: the hook additionally invokes the `retitle` verb; `__tcz_retitle` is idempotent).
- **`client-session-changed`** — new hook → `retitle`. Fires when a tab switches sessions (e.g. via the switcher's `switch-client`), so the title updates instantly instead of waiting for the tick.
- **the ~15s tick** — the `status-right` tick already runs `tick` every `status-interval`; its `tick` verb re-emits the bar color, and will also `__tcz_retitle`. This is the drift/self-heal net (catches `cd`, window switches, missed hooks) within ~15s.
- (The existing `fish_postexec` categorize path may also trigger a retitle to catch `cd` faster — optional, decided in the plan.)

### Where things live

- **`functions/tmux-categorize.fish`** — new `__tcz_emit_title`, `__tcz_retitle`, `__tcz_session_title`, `__tcz_format_title`, an `__tcz_hostname` cache helper; the `tick` case additionally calls `__tcz_retitle`; new `retitle` verb in `__tcz_main`; `__tcz_on_attach` also re-titles ShellFish clients.
- **`conf.d/tmux-lives-install.fish`** — `__tmux_lives_render_fragment` adds a `client-session-changed` hook running `… retitle`; the `client-attached` block is otherwise unchanged (its `on-attach` call now re-titles after the bar color). The tick call already runs `tick`, which now covers titles (no new fragment argument needed — the title needs no baked value, unlike the color).

## Testing & isolation (hard invariant)

Mirror the bar-color suite; nothing touches the live default-socket server (use the `tmux_lives_tmux_socket` / PATH-shim seam, `tmux_lives_fake_environ` for ShellFish detection, temp files as ttys):
- **`__tcz_format_title`** — pure: assert `format_title macwork tmux-lives 1` → `macwork: tmux-lives (C)`; no-claude → `rocket: neurotto`.
- **`__tcz_emit_title`** — writes `\033]2;<title>\a` to a temp "tty" file; assert the file contains the OSC 2 + the title.
- **`__tcz_retitle`** — stub `tmux list-clients`, inject `tmux_lives_fake_environ=LC_TERMINAL=ShellFish`, write to temp ttys; assert the ShellFish client's file gets the title and the non-ShellFish client's does not. (Reuse the existing recolor stub harness; the `tick` re-emit test extends the same block.)
- **Fragment render** (`tests/test-tmux-install.fish`) — assert the rendered fragment contains the `client-session-changed` hook with `retitle`, and that `on-attach`/tick wiring reaches the title path.

## Rollout

Ships via the user's `fisher update` (never a Claude deploy). Runtime smoke on ShellFish: open a tab → title shows `<host>: <dir>`; switch to a claude session → `(C)` appears and the dir updates instantly; `cd` / new tab → title tracks within ~15s; a non-ShellFish client's title is untouched.

## Decisions / open questions

- **ShellFish-gated, always-on** — no config toggle for now (deferred; trivial to add as `setup title on/off`).
- **(C) = session-wide claude** (any pane), **dir = active pane cwd**, `$HOME`→`~`.
- **host = `hostname -s`**, cached in `tmux_lives_hostname`.
- Cross-session switch is instant (hook); window switch / `cd` refresh within ≤15s (tick), acceptable.
