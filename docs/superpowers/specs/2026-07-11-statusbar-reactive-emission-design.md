# Status-bar reactive OSC emission + Claude accent color — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorm), pending plan
**Branch (to be):** `fix/statusbar-reactive-emission`
**Base:** `main` @ `7eb4893`

## Motivation

Two status-bar issues surfaced in live ShellFish use:

1. **Cursor flicker.** The status-right tick (`#(… tick …)`, every `status-interval`) re-emits the ShellFish tab title (OSC 2) and bar color (OSC 6) **directly to the client tty, unconditionally, every cycle** — even when nothing changed. ShellFish repaints its title/toolbar on each, flickering the terminal cursor. Confirmed by bisection: `status off` stops it; a plain `status-right '%H:%M:%S'` (redraw but no `#(tick)`) also stops it → the **OSC writes**, not the redraw, are the cause. This predates the status-bar overhaul (retitle/recolor shipped early July).

2. **Claude window color.** The user wants the left-hand `claude` window name rendered in Claude's brand orange, statically — independent of the per-host ShellFish-derived bar color.

## Part 1 — Reactive OSC emission

### Principle

Emit an OSC **only when the value actually changed for that tab.** The periodic tick stays (it is the only way to catch changes tmux gives no event for — the active pane's cwd via `cd`, and a pane starting/stopping Claude), but it becomes a change-detector, not a broadcaster. Steady state → zero writes → zero flicker.

### Emit paths

- **Forced emit** — unconditional, and **updates the cache** after writing. Used by discrete, intentional events where one write is acceptable and desirable: the `client-attached` hook (`on-attach`), the `client-session-changed` hook (`retitle`), `setup color`, and the backstop. Because forced emits refresh the cache, the next tick sees no change and stays silent (no double flicker).
- **Dedup'd emit** — used by the **tick** only. For each attached ShellFish client it computes the target title (from the client's session) and color, compares each to the per-tty cache, writes only the fields that differ, and updates the cache. This is the path that was spamming.

### Per-tty cache

- Stored as tmux **global options keyed by sanitized tty** — e.g. `/dev/pts/11` → `@tmux_lives_emit_pts11`. In-memory (no file I/O), server-lifetime.
- Holds the last-emitted title and color for that tty (one option each, or a single delimited value).
- **pts reuse** (a detached pts number is later reused by a new client): the `client-attached` hook force-emits and rewrites the cache on every attach, so a reused pts always gets a fresh value and correct cache. No detach-time pruning required; stale entries for gone ttys are harmless (a handful of tiny strings) and are overwritten on reuse.

### Backstop (silently-dropped values)

The dedup path cannot re-heal a tab that already received the correct value and then **lost it without a re-attach** — the iOS suspend/resume, ShellFish toolbar repaint, or mosh reconnect cases (tmux still considers the client attached, so no `client-attached` fires; the cache still says "sent"). To cover these:

- Every `@tmux_lives_heal_interval` seconds (**default 120**, `0` disables), the tick does **one unconditional color-only re-emit** per ShellFish tty (forced path), then resets the timer.
- Color-only because the title refreshes itself frequently enough via the dedup path; the static bar color is the value most likely to be silently dropped.
- Timer state: a global option (e.g. `@tmux_lives_heal_at`, next-heal epoch); the tick (fish) compares against `date +%s`.
- Cost: ~1 faint blip per interval per tab (≈24× less than the current every-5s), tunable/off.

### Components touched (`functions/tmux-categorize.fish`)

- `__tcz_emit_title` / `__tcz_emit_barcolor` — unchanged low-level tty writers.
- New cache helpers: sanitize-tty→key, get/set the cached (title,color) for a tty.
- `__tcz_recolor` / `__tcz_retitle` — remain the **forced** emitters (used by hooks / `setup color` / backstop); they now also update the cache when they emit.
- New **dedup'd tick emitter** (emit-if-changed per client) — called by `case tick` in place of the current unconditional `__tcz_recolor` + `__tcz_retitle`.
- `case tick` — call the dedup'd emitter; run the backstop check.

Reactive triggers (hooks, `setup color`) are unchanged in *when* they fire; they now refresh the cache as a side effect.

### Config knobs (live `@options`)

- `@tmux_lives_heal_interval` — backstop seconds (default `120`, `0` = off).
- `status-interval` no longer drives flicker; the fragment keeps `15`. The user's live-set `5` becomes harmless post-fix (it only affects how quickly a `cd`/claude-toggle is reflected). No change forced.

## Part 2 — Claude accent color

- New `@tmux_lives_claude_color` (default Claude coral **`#D97757`**), seeded by the fragment; independent of `@tmux_lives_cap_bg`/status-style.
- `window-status-format` / `window-status-current-format` gain a conditional: when `#{window_name}` equals `claude`, render `#W` in `@tmux_lives_claude_color`, resetting the foreground afterward so the separator/other windows are unaffected. Position unchanged; the current window stays bold.
- Exact match on `claude` (the common auto-rename output); transient `[dead]`/`[tmux]` variants are out of scope.

## Testing

- **Dedup decision** (pure/stubbable, existing tmux-stub style): given a cache value and a computed value, the tick emitter writes only changed fields; a forced emit always writes and updates the cache. Assert emit-call counts via stubbed `__tcz_emit_*`.
- **Backstop timer:** given `now` and a stored next-heal epoch, the tick decides to re-emit and advances the timer; disabled when interval `0`.
- **Cache key sanitization:** `/dev/pts/11` → a valid option name.
- **Part 2:** fragment-render test asserts `@tmux_lives_claude_color` is seeded and the window-status formats contain the conditional; a live `-L`-socket render asserts a `claude`-named window carries the orange fg and a non-claude window does not.

## Isolation & deployment

- Tests never touch the live server: private `-L` sockets or the `tmux` stub, per the isolation invariant (`tmux_lives_tmux_socket` seam where install-side).
- Deploy is the user's `fisher update` only; no live mutation from a session.

## Non-goals

- No new tmux hooks for cwd/claude changes (tmux exposes none; the dedup'd poll is the intended mechanism).
- No change to the identity/`✦` logic (shipped `7eb4893`), the powerline caps, or the clock.
- Not attempting to query ShellFish's current toolbar state (impossible); the backstop is unconditional by necessity.
