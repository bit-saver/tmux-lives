# Design — "Neurotto CLI" session identity (`@tmux_lives_name` display override)

**Date:** 2026-07-07
**Status:** Designed (approved in brainstorming → writing-plans next)
**Repos:** tmux-lives (`functions/tmux-categorize.fish`, the popup switcher) + neurotto (`x/cli.sh` and its sibling scripts)
**Relates to:** the ShellFish tab title (feature a, shipped 2026-07-06) — the title will consume the same display name.

## Why

Live diagnosis (2026-07-07) showed the user's own work-sessions renamed to `tail` / `tail-2`, each **owned** by the categorizer (`@tmux_auto_name` matched). Cause: the neurotto CLI, run from *inside* an existing tmux session, adds a window (`neurotto_cli_window`) whose **log-tail pane** (`tail -f`) becomes the session's first non-shell command → the categorizer names the whole session `tail`. The tail process is lifecycle-independent and orphans, so the name lingers. A dedicated session (the from-shell path) is left alone by the categorizer, so the fix is to make the CLI *always* its own session — and give it a proper name.

Goal: run `cli` anywhere → one canonical session shown as **"Neurotto CLI"** (internally slugged `cli`), your work sessions never hijacked.

## Goals

- The neurotto CLI is one dedicated session, created-or-switched from both a plain shell and inside tmux; it never adds a window to (and renames) the user's work session.
- Humans see **"Neurotto CLI"** for it — in the popup switcher, the categorize overview, and the ShellFish tab title — while the machinery keeps a stable slug (`cli`) to target and reap.
- A general safety net so a pager/tailer pane can never again name a session `tail`/`less`/etc.
- No test touches the live tmux server (the project's hard isolation invariant).

## Non-goals (YAGNI)

- Not solving the orphaned-tail reaping itself (separate Track-B robustness item) — the dedicated-session model makes it irrelevant to *naming*.
- No general user-facing "rename any session" UI — `@tmux_lives_name` is an option apps/users set, not a new command.
- No change to how claude sessions are named.

## Design

### Part 1 — tmux-lives: `@tmux_lives_name` display override

The categorizer already emits a per-session `display` distinct from the tmux session `name` (`__tcz_snapshot` → `name \t category \t attached \t last_attached \t display`; the switcher shows `display`, switches by `name`). Add a highest-priority source for `display`:

- **In `__tcz_snapshot`:** if a session has option `@tmux_lives_name` set (non-empty), its `display` is that value verbatim (ahead of claude/running/general logic). Read it in the per-session pass alongside the existing pane format.
- **In `__tcz_categorize` (rename logic):** a session with `@tmux_lives_name` set is treated as **claimed** — the categorizer does **not** `rename-session` it (its tmux name/slug is left exactly as the app set it). This mirrors the existing "leave un-owned/hand-named sessions alone" guard.
- **Switcher / overview:** already render `display`, so "Neurotto CLI" appears there for free once `display` carries it; the switch target stays the slug `name`. (Confirm the switcher labels by `display` and targets by `name` — it already separates them.)
- **Feature-(a) ShellFish title:** `__tcz_session_title` uses `@tmux_lives_name` for the `<middle>` when set (instead of the dir basename) → the tab reads `<host>: Neurotto CLI [(C)]`.

Net: `@tmux_lives_name "X"` makes a session read as **X** everywhere a human looks, with the tmux name untouched.

### Part 2 — tmux-lives: boring-command deprioritization

A general safety net (protects any app, not just neurotto): when `__tcz_snapshot` picks the `running` name from the first non-shell pane command, it skips a **boring list** `tail less watch cat more bat` (a `set -l __tcz_boring …` beside `$__tcz_shells`). A session whose only non-shell commands are boring gets no `firstcmd` → falls through to the `general` category → named by its directory basename. So a stray `tail -f` pane can never name a session `tail` again.

### Part 3 — neurotto: one dedicated "Neurotto CLI" session

`x/cli.sh` (and the scripts that target the session) change from "window-in-current-session when inside tmux" to **always one dedicated session**:

- **Slug:** the dedicated session is named **`cli`** (replacing `neurotto_cli_session` as the stable target slug). The `cli` command is unchanged.
- **Create-or-switch:** on `cli`, if session `cli` exists → attach (from shell) or `switch-client -t "=cli"` (from inside tmux); else create it (server + 2-pane window) then attach/switch. So both entry paths converge on the same session; running it from inside tmux switches you to it rather than hijacking your session.
- **Display name:** immediately set `tmux set-option -t "=cli" @tmux_lives_name "Neurotto CLI"`. tmux-lives then shows "Neurotto CLI" in the switcher + tab title; neurotto keeps targeting `cli`.
- **Script updates:** the sibling scripts that reference `neurotto_cli_session` (and the malformed `:neurotto_cli_window` probe in `src/cli/index.ts`) retarget the `cli` slug via `-t "=cli"`. The internal window name (`neurotto_cli_window`, used by `kill.sh`/`resize.sh` pattern-matches) can stay as-is (it's an internal marker, not user-visible) to minimize churn.

## Where things live

- **tmux-lives** `functions/tmux-categorize.fish`: `@tmux_lives_name` read in `__tcz_snapshot` (display) + the rename guard in `__tcz_categorize`; `__tcz_session_title` uses it; the `$__tcz_boring` list + the deprioritization in `__tcz_snapshot`.
- **tmux-lives** popup switcher (`conf.d/tmux.fish` / the categorizer's popup): confirm it labels by `display` and targets by `name` (likely already true; adjust only if it conflates them).
- **neurotto** `x/cli.sh`: the create-or-switch flow + the `@tmux_lives_name` set; `x/kill.sh`, `x/toggle.sh`, `x/resize.sh`, `x/tmux.sh`, `src/cli/index.ts`: retarget `cli`.

## Testing & isolation (hard invariant)

- **tmux-lives** (fish, `-L` socket seam / stubs, no live-server touch): `@tmux_lives_name` set on a stub/`-L` session → `__tcz_snapshot` `display` == the value AND `__tcz_categorize` does not rename it; a session with a `tail` pane → not named `tail` (dir fallback); `__tcz_session_title` returns `<host>: Neurotto CLI` when `@tmux_lives_name` is set. Reuse the recolor/categorize stub harness.
- **neurotto** (`x/cli.sh`): the create-or-switch logic is integration/tmux-shaped; test the branch decision against a private `-L` socket where feasible (seam like the tmux-lives pattern), else cover by the live smoke. The malformed `has-session` probe fix in `index.ts` is unit-checkable.

## Rollout

Two independent deploys: tmux-lives via the user's `fisher update`; neurotto via its normal `deploy`. Order: ship the tmux-lives mechanism first (harmless without a consumer), then neurotto. Live smoke: run `cli` from a shell and from inside tmux → both land on one session shown "Neurotto CLI" (slug `cli`), your work sessions stay put, and a lone `tail -f` elsewhere no longer names its session `tail`.

## Decisions / open questions

- **Display "Neurotto CLI" / slug `cli` / command `cli`** — decoupled (per the user): humans see the title-case name, machines target the slug.
- **Boring list** = `tail less watch cat more bat` (extendable).
- **`@tmux_lives_name` is authoritative** — it overrides category naming and suppresses the rename; it does not need to be slug-safe (it's display-only).
- Cross-repo: one spec, but the plan may split into a tmux-lives plan and a neurotto plan (each independently shippable; tmux-lives first).
