# Landing Session — Design

Status: implemented on `feat/landing-session` (rehearsed on a throwaway server with a real pty client); awaiting the whole-branch review, merge and the user's `fisher update`. Approved 2026-09-26. Plan: `docs/superpowers/plans/2026-09-26-landing-session.md`. Themes and schemes are on hold while this is built.

## Problem

- Nearly every Claude session runs inside tmux-lives, and most are attached from two devices at once: the iPad (ShellFish) and the Mac (iTerm2 / Ghostty).
- Whenever tmux-lives picks a session automatically, a tab can land on an existing session — including a Claude project whose Claude is not running right now — so one device ends up attached twice to the same session.
- The automatic picks today:
  - login (`__tmux_autostart` → `__tmux_pick_session`): attach the most recently used detached "general" session, else create one;
  - a new ShellFish tab (`__tcz_commandeer` → `__tcz_pick_general`): bounce the springboard to the same kind of session, else create `gen-N`;
  - `tmux-lives picker` run outside tmux: the same pick, then open the popup.
- Both pickers treat any session whose panes all sit at a shell prompt as free. A Claude project whose Claude has exited, or a restored breadcrumb, qualifies. (Read from the code; not yet measured as the cause of every duplicate.)
- `gen-N` sessions pile up as entry points.

## Goal

Every automatic entry into tmux, and every tab whose session closes, lands on a **landing page**: a private, per-tab session running a full-screen chooser. Nothing auto-attaches a tab to an existing work session.

Not in scope: ShellFish's built-in GUI session picker (outside our control), theme work (on hold), the iTerm2 "Host" tab label.

## Concepts

- **Landing session** — one per client (tab). Reserved name `_landing-N`, N the smallest free integer. `__tcz_slugify` only emits `[A-Za-z0-9-]`, so an underscore name can never collide with a project session. The name is the whole identity — it survives a restore and needs no tmux call to test. One window, one pane, running the landing app.
- **Why one per client.** A tmux pane is shared by every client attached to its session. One shared landing screen would show the iPad and the Mac the same menu, and could not tell which device pressed Enter. With one client per landing session, "my client" is simply the only client attached to my session.
- **Landing app** — `fish --no-config $cat landing`: a full-pane chooser built from the existing popup picker (`__tcz_popup`) renderer and key loop.

## Entry points

| Path | Today | New |
|---|---|---|
| Login autostart | attach MRU detached general, else new session | `landing-new` (detached; a lost name race retries with a fresh name), then `exec tmux attach-session -t =_landing-N`; if that yields no name, today's path |
| New ShellFish tab (`__tcz_commandeer`) | switch to MRU detached general or a new `gen-N`, kill the springboard | create `_landing-N`, switch the client to it, kill the springboard |
| `tmux-lives picker` outside tmux | attach MRU general, open the popup | same as login (landing *is* the picker); `picker -t` / `--take` keeps the take-over path |
| The tab's session closes | client detaches (`detach-on-destroy on`) | client moves to a new landing session (next section) |
| `tmux-lives close` | kill session, client detaches | `session-close`: move the session's clients to landing sessions, then kill it (falls back to a direct kill) |

Unchanged: `tmux-lives new`, `tmux-lives attach <name>`, and the in-session picker keys (`M-s`, `prefix S`), which keep opening the popup — including that popup's own `x`, which kills without landing the victim's tabs. `clear -x` goes through `close`, so with landing on it lands the tab instead of exiting.

## When a session closes

Measured 2026-09-26 on tmux 3.3a, isolated sockets with a real pty client:

- **`detach-on-destroy off` — rejected.** tmux moves the client to the most recently used other session before any hook runs: a transient duplicate attach, the exact problem. `#{client_last_session}` was also empty in the hook.
- **`remain-on-exit on` + a `pane-died` hook — adopted.** The hook fires while the dying session still exists with its client still on it; switching the client to landing and then killing the session never touches another session.

The `pane-died` handler (`fish --no-config $cat pane-died <pane> <session>`) is registered with `#{q:pane_id}` / `#{q:session_name}` quoting (a session name with an apostrophe would otherwise break the shell line and leave the pane dead forever) and a `|| tmux kill-pane` fallback, so a handler that cannot run at all (fish or the categorizer gone) still closes the pane. Its rules:

1. Dead pane in a landing session → `respawn-pane -k` with the landing command (the app comes back; a bare `-k` would re-run whatever the pane last ran).
2. Dead pane in any other session, other live panes remain → `kill-pane` it (normal close behaviour).
3. Last live pane of a non-landing session → `session-close`: for each attached client, create a landing session and switch the client to it; then kill the session. `session-close` is the one helper shared with `tmux-lives close` and the app's `x`.

`detach-on-destroy` stays `on`, so a session killed any other way (a hand-typed `tmux kill-session`, ShellFish's GUI kill) detaches its tabs — never moves them somewhere random.

⚠ `remain-on-exit` is global. `tmux-lives setup teardown` and the kill switch (below) must restore it along with removing the hook.

Measured the same way on tmux 3.7b (macwork), 2026-09-26: identical — the hook fired with the client attached (`clients=1`), the client moved straight to landing, the session was gone, and no other session was touched. (macOS test harness note: a backgrounded `script` does not attach a client there, and ssh without a tty leaves `TERM` unset; a python `pty.fork()` client with `TERM` set does.)

## Landing lifecycle

- **Create** — `__tcz_landing_new [client]`: pick `_landing-N`, `new-session -d -s _landing-N -c $HOME` running the app; with a client, `switch-client -c <client> -t =_landing-N` in the same tmux invocation (so the sweep can never see it clientless). Two tabs can pick the same free name at once: the loser retries with a fresh name, and a failed switch removes only the session this call created, by its id.
- **Leave** — after the app switches its client elsewhere, it kills its own session once no tab is left on it.
- **Sweep** — the status tick kills any `_landing-*` session with no attached client, covering tabs that closed or detached while on landing (≤ 15 s). It spares landing sessions younger than 10 s: `landing-new` creates detached and the shell attaches a moment later. It reads the per-pass session memo, so a pass with no clientless landing session costs zero tmux calls.
- **Respawn** — the app never exits on its own; an exit or crash is caught by `pane-died` rule 1.
- **Misuse** — a new window or split inside a landing session (landing-guarded `after-new-window` / `after-split-window` hooks, `landing-evict`) is removed, and the client gets a new general session in `$HOME` instead: asking landing for a shell gives you a real session. The now-clientless landing session is left to the sweep.

## The landing app

Layout — the popup picker's renderer, full pane:

1. **Live sessions** — the picker's grouped list (claude / running / general) with the preview. Landing sessions are hidden. Markers:
   - `[here]` — already attached from this device;
   - `[attached]` — attached from another device only.
   Device identity = the SSH client address in the client's environment (`SSH_CONNECTION`, first field): macwork `192.168.68.35`, iPad `10.0.30.120` on rocket; no `SSH_CONNECTION` = `local`. Read via the existing `__tcz_pid_environ` (`/proc` on Linux, `ps eww` on macOS).
2. **Claude projects — not running** — next section. Row: project name, age of its last conversation.
3. **New shell** — a new general session in `$HOME`.

Keys:
- `↑↓` / `jk` move.
- `Enter` — attach (live) · `claude --continue` (project) · new shell.
- `r` — on a project row, start `claude --resume` (Claude's own conversation picker).
- `x` — kill a live session (the picker's confirm). Its attached tabs land first (`session-close`), as for any closing session.
- `d` — detach this tab from tmux, then kill this (now clientless) landing session. (`q` and Esc are one token in the shared key reader, and Esc must not detach — so both are no-ops here.)

Refresh: re-snapshot live sessions every 3 s while idle (the key read times out) and immediately after any action. The idle-project list is re-read only every 10th pass and after an action (running claude panes are still checked every pass), so a newly idle project can show up to 30 s late. The frame goes through the popup's diff emitter and is skipped when nothing shown changed: an idle refresh writes nothing to the terminal.

Switching: `switch-client -c <my client> -t =<target>`, where my client is `list-clients -t =<my session>: -F '#{client_name}'`, read at action time. Then kill my own session.

## Claude project discovery

- **Source** — the directories under `~/.claude/projects/`. For each: its newest `*.jsonl` transcript; the first `"cwd":"…"` value in it is the project's real folder (the directory name is a lossy slug). Measured on rocket: 73 directories, 30 resolve to a folder that exists locally — the rest are macwork paths (the store syncs across machines) or deleted folders. Keep only folders that exist.
- **Not `~/.claude.json`** — 176 KB of JSON, fish has no JSON parser, and macOS has no `jq` by default.
- **Not running** — drop a project when a live pane runs claude with that folder (or its git root) as its cwd.
- **Order** — newest transcript first; show a relative age.
- **Cost** — about one fork per directory to read a transcript head. Cache `dir|mtime|folder` lines in `$XDG_CACHE_HOME/tmux-lives/projects.tsv` (seam `tmux_lives_project_cache`; the transcript root has its own seam, `tmux_lives_claude_projects_dir`); re-read a directory only when its newest transcript's mtime changes, and rewrite the cache only when something changed. The file shares its directory with the theme render cache, whose prune deletes only its own `<digits>-<hex6>.tsv` files.
- **Start** — `new-session -d -c <folder>` (the categorizer names it from the folder, as for any session, so it is addressed by its session id), `send-keys 'claude --continue' Enter`, switch, and leave once no tab is left on the landing. The shell stays after Claude exits, as today. `r` sends `claude --resume` instead.

## Exclusions everywhere else

Landing sessions (by reserved name) are excluded from:

- categorize, rename, `@tmux_lives_display` / `@tmux_lives_claude` writes;
- snapshot and overview (popup picker, fallback menu);
- `__tmux_pick_session`, `__tcz_pick_general`, `prune` and idle-kill, restore disposal;
- tab titles — a landing tab gets the fixed title `[<h>] landing`.

tmux-resurrect has no per-session exclusion, so snapshots will contain landing sessions. On restore, tmux-lives kills any restored `_landing-*` session (by name — options are not restored).

Tab colour is untouched.

## Configuration

- Universal `tmux_lives_landing`, default `on`; `tmux-lives setup landing on|off|status`.
- `off` = today's behaviour exactly: auto-pick general sessions, detach on close, no `remain-on-exit`, no `pane-died` hook. The switch exists because this feature governs every attach.
- No new key bindings.

## Platforms

- rocket: tmux 3.3a (measured above).
- macwork: tmux 3.7b (measured, identical).
- macOS has no `/proc`: device identity through `ps eww` (existing helper).

## Testing

- Isolated `-L … -f /dev/null` servers with real pty clients (`script -qfec`), as the existing attach-hook tests do.
- Close path: the last pane exits → the client lands on a new `_landing-N` and never on another session (a `client-session-changed` log shows only the landing session), and the closed session is gone; a non-last pane exits → only that pane goes, client unmoved; the landing app exits → respawned.
- Entry points: `__tcz_commandeer` and autostart create a landing session (autostart's `exec` stubbed).
- Discovery: a fixture projects directory (seam) with slugs, transcripts and mtimes — cwd extraction, the exists-locally filter, running-exclusion, ordering, cache hit and miss.
- Exclusions: categorize, snapshot, pickers, prune and restore ignore `_landing-*`.
- Kill switch `off`: every existing suite stays green unchanged.

## Open items

- Measure what ShellFish does when its tmux client exits (reconnect into a new springboard, or close the tab). Informs the "killed some other way" path, not the design.
