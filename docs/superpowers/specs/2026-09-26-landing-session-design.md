# Landing Session — Design

Status: shipped in `main` `7528599` and deployed on rocket and macwork; the type-ahead fix and idle cadence are in `main` `8f39db7`. Approved 2026-09-26. **Chooser v2** (approved 2026-10-01; deployed and confirmed 2026-10-04, with the settle-window fix `89661c4`): interactive-only discovery with worktree/subfolder mapping and the generic-folder list, four project groups, the 21-day `older (N)` row, `n` for a new shell, the legend border, and held-arrow scrolling without per-step preview capture. **Chooser v3** (approved 2026-10-05) built on branch `feat/landing-chooser-v3`, awaiting merge and `fisher update`: the nested layout (claude and general as the two sections, directory boxes inside claude, a boxed `...older (N)`), a `LANDING` / `SWITCHING` badge, and the in-session switcher replaced by the same app in a full-screen popup ("Switch mode", below). Chosen from mockups `06`–`12` on the claude-mock page (layout E1, badge teal).

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
- **Landing app** — `fish --no-config $cat landing`: a full-pane chooser built from the popup picker's renderer and key loop (the two-pane switcher, `__tcz_popup`, was removed in v3).

## Entry points

| Path | Today | New |
|---|---|---|
| Login autostart | attach MRU detached general, else new session | `landing-new` (detached; a lost name race retries with a fresh name), then `exec tmux attach-session -t =_landing-N`; if that yields no name, today's path |
| New ShellFish tab (`__tcz_commandeer`) | switch to MRU detached general or a new `gen-N`, kill the springboard | create `_landing-N`, switch the client to it, kill the springboard |
| `tmux-lives picker` outside tmux | attach MRU general, open the popup | same as login (landing *is* the picker); `picker -t` / `--take` keeps the take-over path |
| The tab's session closes | client detaches (`detach-on-destroy on`) | client moves to a new landing session (next section) |
| `tmux-lives close` | kill session, client detaches | `session-close`: move the session's clients to landing sessions, then kill it (falls back to a direct kill) |

Unchanged: `tmux-lives new` and `tmux-lives attach <name>`. The in-session picker keys (`M-s`, `prefix S`) and `tmux-lives picker` inside tmux open the landing app in switch mode (v3, "Switch mode" below); before v3 they opened the two-pane popup switcher, whose `x` killed without landing the victim's tabs. `clear -x` goes through `close`, so with landing on it lands the tab instead of exiting.

## When a session closes

Measured 2026-09-26 on tmux 3.3a, isolated sockets with a real pty client:

- **`detach-on-destroy off` — rejected.** tmux moves the client to the most recently used other session before any hook runs: a transient duplicate attach, the exact problem. `#{client_last_session}` was also empty in the hook.
- **`remain-on-exit on` + a `pane-died` hook — adopted.** The hook fires while the dying session still exists with its client still on it; switching the client to landing and then killing the session never touches another session.

The `pane-died` handler (`fish --no-config $cat pane-died <pane> <session>`) is registered with `#{q:pane_id}` / `#{q:session_name}` quoting (a session name with an apostrophe would otherwise break the shell line and leave the pane dead forever) and a `|| tmux kill-pane` fallback, so a handler that cannot run at all (fish or the categorizer gone) still closes the pane. The handler resolves the session (its id and current name) from the pane at run time and never trusts the hook's `<session>`: a tick can rename the session between the pane's death and the handler, and a missed name left the pane dead forever. For the same reason the categorizer never renames a session whose active pane is dead (its empty path means closing, not project-less). Its rules:

1. Dead pane in a landing session → `respawn-pane -k` with the landing command (the app comes back; a bare `-k` would re-run whatever the pane last ran).
2. Dead pane in any other session, other live panes remain → `kill-pane` it (normal close behaviour).
3. Last live pane of a non-landing session → `session-close`: for each attached client, create a landing session and switch the client to it; then kill the session. `session-close` is the one helper shared with `tmux-lives close` and the app's `x`.

`detach-on-destroy` stays `on`, so a session killed any other way (a hand-typed `tmux kill-session`, ShellFish's GUI kill) detaches its tabs — never moves them somewhere random.

⚠ `remain-on-exit` is global. `tmux-lives setup teardown` and the kill switch (below) must restore it along with removing the hook.

Measured the same way on tmux 3.7b (macwork), 2026-09-26: identical — the hook fired with the client attached (`clients=1`), the client moved straight to landing, the session was gone, and no other session was touched. (macOS test harness note: a backgrounded `script` does not attach a client there, and ssh without a tty leaves `TERM` unset; a python `pty.fork()` client with `TERM` set does.)

## Landing lifecycle

- **Create** — `__tcz_landing_new [client]`: pick `_landing-N`, `new-session -d -s _landing-N -c $HOME` running the app; with a client, `switch-client -c <client> -t =_landing-N` in the same tmux invocation (so the sweep can never see it clientless). Two tabs can pick the same free name at once: the loser retries with a fresh name, and a failed switch removes only the session this call created, by its id.
- **Leave** — after the app switches its client elsewhere, it kills its own session once no tab is left on it.
- **Sweep** — the status tick kills any `_landing-*` session with no attached client, covering tabs that closed or detached while on landing (up to ~25 s: the 15 s tick plus the 10 s young-session guard). It spares landing sessions younger than 10 s: `landing-new` creates detached and the shell attaches a moment later. It reads the per-pass session memo, so a pass with no clientless landing session costs zero tmux calls.
- **Respawn** — the app never exits on its own; an exit or crash is caught by `pane-died` rule 1. After a `fisher update`, `__tmux_lives_landing_respawn` (called from `_tmux_lives_post_update`) respawns every live landing pane so it runs the new code.
- **Misuse** — a new window or split inside a landing session (landing-guarded `after-new-window` / `after-split-window` hooks, `landing-evict`) is removed, and the client gets a new general session in `$HOME` instead: asking landing for a shell gives you a real session. The now-clientless landing session is left to the sweep. With no client attached, only the pane is removed; no session is created.

## The landing app

Layout (v3) — the popup picker's renderer, full pane: a LIST column, a PREVIEW column (a capture of the selected session's pane, or what Enter does for a project row), a border, and the key legend.

1. **claude** — every live Claude session and every idle Claude project, in **directory boxes** by where the project lives, in this order: `projects` (`~/projects/*`), `workspace` (`~/workspace/*`, rocket only), `work` (`~/Work/*`), `other` (everything else — `~/.claude`, `~/.config/fish`, `~/.hammerspoon/…`, `~/docker/…`). A box with no rows is not shown. A live session's box comes from its active pane's cwd through the same folder → project mapping discovery uses (a cwd that maps to no project goes to `other`). Inside a box: live sessions first (bright name, device marks), then idle projects, newest conversation first (muted name, `· <age>`). Markers on live rows:
   - `[here]` — already attached from this device;
   - `[attached]` — attached from another device only.
   Device identity = the SSH client address in the client's environment (`SSH_CONNECTION`, first field): macwork `192.168.68.35`, iPad `10.0.30.120` on rocket; no `SSH_CONNECTION` = `local`. Read via the existing `__tcz_pid_environ` (`/proc` on Linux, `ps eww` on macOS).
2. **Older** — the last part of the claude section: projects whose last interactive conversation is more than 21 days old are hidden behind one row, `...older (N)`, in its own box; Enter on it reveals them in their boxes until the app restarts.
3. **general** — every other live session (the former `running` category folds in here; a running command shows its session's name as today). Landing sessions are hidden.

Drawing (v3, layout E1 of the mockups):
- `claude` opens with `╭── claude ───…` in orange 208, left-aligned, and an orange rail `│` in the list's first column runs down beside everything in the section. `general` is drawn the same way in green 2. No bottom borders: a section, box or rail just ends.
- A directory box opens with a gold 178 rule whose centered word is the directory name (`──── projects ────╮`); a gold rail `│` runs down the right side of the list column beside the box's rows and continues one row past its last member, then ends with no corner. Rows inside a box are left-aligned.
- The older box is drawn like a directory box in gray 8, with no word on its rule; its row reads `...older (N)`.
- The pointer `▐` replaces the selected row's piece of the left rail, in the color of its section (orange 208 anywhere in claude, the older row included; green 2 in general); the selection background stops at a box's right rail.
- The key legend begins with an inverse badge: `LANDING` (orange 208) in landing mode, `SWITCHING` (teal 37) in switch mode.
- A list taller than the pane scrolls as today (the boxes cost a row each: a 30-row pane holds about seven fewer rows than v2's flat list).

A border line separates the key legend from the list and the preview above it.

Keys:
- `↑↓` / `jk` move; PgUp/PgDn page. While a move key is held, only the list repaints; the preview is captured once input has been quiet for 0.2 s (the tty read timer counts tenths of a second; the capture is what made each held step slow).
- `Enter` — attach (live) · `claude --continue` (project) · reveal older.
- `n` — a new general session in `$HOME` (replaces the former "new shell" row).
- `r` — on a project row, start `claude --resume` (Claude's own conversation picker).
- `x` — kill a live session (the picker's confirm). Its attached tabs land first (`session-close`), as for any closing session; with landing off (no landing `pane-died` hook on the server) the session is killed and its tabs detach, as `tmux-lives close` does.
- `d` — detach this tab from tmux, then kill this (now clientless) landing session. (`q` and Esc are one token in the shared key reader, and Esc must not detach — so both are no-ops in landing mode; in switch mode they close the switcher.)
- **Typed-ahead or pasted text never acts.** A key acts only when it arrives alone: after reading one, the app checks without blocking whether more input is already pending. If it is, a move (`↑↓`, `jk`, PgUp, PgDn) keeps the held-key rule — one step per frame, queued repeats discarded, and a different key read past them is handled on the next turn under this same check. Any other key means the bytes were typed ahead or pasted (ShellFish types `cd "<dir>"` + Enter into every new tab, where `d` would detach and Enter would attach), so input is drained until 0.3 s pass with none, and nothing acts: a tail that straggles in, such as an Enter 50 ms behind the text, is part of the same burst. An LF right behind an Enter (CR LF) is part of that Enter, not a burst. The key reader itself is unchanged: the check lives in the landing loop. Type-ahead sent one character at a time with typing-like gaps cannot be told from typing, and acts.
- **Settle window.** Until the app has seen one quiet second after its first paint, every key but a move is drained and ignored: type-ahead that arrives in several chunks, before a person could have read the chooser. Moves (arrows, `j`/`k`, page keys) act as they do after it, one step per frame, and do not end the window: they never leave the landing, and a typed-ahead `j` must not open it to the Enter behind it. Each chunk restarts the second, but the window closes 2 s after the first paint however many keys keep coming. The clock is read at the first paint and on keys inside the window only (`/proc/uptime` on Linux, no fork; perl on macOS), never on the idle path. A quiet second ends in an ordinary refresh.

Refresh: re-snapshot live sessions every 3 s while idle (the key read times out) and immediately after any action. Once 60 s pass with no keypress, the read waits 15 s instead: an idle tab cost ~1.5% of a core at 3 s and ~0.3% at 15 s (measured on a two-session test server). Every key counts, including moves, actions and drained bursts, since a person is there; the key that ends an idle spell refreshes at once, the idle-project list included, and restores 3 s. The idle time is the app's own sum of read timeouts since its last key, so it needs no clock and no tmux call, and it can only run late, by the refresh work between reads (measured: 15 s refreshes began 62.5 s after the last key). Test seams `tmux_lives_landing_idle_after` and `tmux_lives_landing_idle_refresh` (seconds, defaults 60 and 15) are read at app start. The idle-project list is re-read only every 10th pass and after an action (running claude panes are still checked every pass), so a newly idle project can show up to 30 s late, or 150 s on an idle tab. The frame goes through the popup's diff emitter and is skipped when nothing shown changed: an idle refresh writes nothing to the terminal.

Switching: `switch-client -c <my client> -t =<target>`, where my client is, in landing mode, the most recently active client attached to my session (`__tcz_landing_client`, read at action time; a tab can share the session through a GUI session list or a hand attach), and in switch mode the client the switcher was opened for. Then, in landing mode, kill my own session once no other tab is on it; switch mode never kills its own session, it only closes the switcher.

## Switch mode (v3)

The in-session switcher is the landing app itself. `M-s`, `prefix S` and `tmux-lives picker` inside tmux open it full screen, with no window border, over the client's current session: `display-popup -B -E -w 100% -h 100%` running the categorizer's landing verb in switch mode for that client (the verb takes the mode and the client name; the client comes from `#{client_name}` or is resolved inside the popup, as the two-pane switcher did). The two-pane popup switcher (`__tcz_popup`) is removed; the `display-menu` fallback for a tmux without `display-popup` stays as it is.

Differences from landing mode — everything else (layout, discovery, keys, input rules, idle cadence, diff painting) is the same code:
- The badge reads `SWITCHING` (teal 37).
- The client's current session is listed (in landing mode the app's own session is the landing session, which is hidden) and marked as the two-pane switcher marked it: a yellow `❯` in its rail cell and a yellow `[current]` tag in place of the device mark. The pointer starts on it. On that row the pointer's `▐` covers the `❯`; the yellow name and `[current]` still identify it.
- No settle window: the switcher opens on a keypress, and ShellFish's typed-ahead `cd` only reaches new tabs. The burst rule stays.
- `Enter` on a live session switches this client to it and closes the switcher; on a project it starts `claude --continue` there (`r`: `--resume`) and switches; `n` starts a new general session and switches; `x` kills a live session through `session-close` (its tabs land, the current session included — this client then lands too; with landing off its tabs detach instead); `d` detaches this client; `q`/Esc close the switcher. The legend adds `esc close`.
- Nothing is created or killed for the switcher itself: no `_landing-N`, and the popup closes when the app exits.

## Claude project discovery

- **Source** — the directories under `~/.claude/projects/`. For each: its newest **interactive** `*.jsonl` transcript — `"entrypoint":"cli"`, or no `entrypoint` field (older files). Headless runs (`sdk-cli`, `sdk-py`: `claude -p`, review harnesses) and GUI apps (`claude-desktop`, `claude-vscode`) never make a project: on 2026-10-01 they were the source of every wrong row (`tmp`, `~`, a watchface worktree, `~/Work`). The first `"cwd":"…"` value in that transcript is the project's real folder (the directory name is a lossy slug). Keep only folders that exist.
- **Folder → project** — a git worktree counts as its main repository (`<folder>/.git` is a file whose `gitdir:` reads `<repo>/.git/worktrees/<name>`; parsed, no fork), and a folder inside a git repo counts as the repo's root. Never a project: `$HOME`, `/`, temp folders (`/tmp`, `/var/tmp`, `/private/tmp`, `/private/var/tmp`, `/var/folders/*`, `$TMPDIR`) and the group roots themselves (`~/projects`, `~/workspace`, `~/Work`). The same generic list serves `__tcz_project_name`, which missed macOS's `/private/tmp`.
- **Not `~/.claude.json`** — 176 KB of JSON, fish has no JSON parser, and macOS has no `jq` by default.
- **Not running** — drop a project when a live pane runs claude with that folder (or its git root, or a worktree of it: the mapping discovery uses) as its cwd, or — for a project that is not a git repo (e.g. `~/Work/myEMS`, whose `api/` and `web/` are separate repos) — anywhere inside it.
- **Order** — newest transcript first; show a relative age.
- **Cost** — one `awk` per changed directory reads each transcript up to its first `cwd` line, by `getline` (awk's main loop aborts the whole run on an unreadable file). A directory named after a folder that is never a project is skipped unread: rocket's `/tmp` one holds a thousand headless transcripts. The cache, `$XDG_CACHE_HOME/tmux-lives/projects.tsv` (seam `tmux_lives_project_cache`; the transcript root has its own seam, `tmux_lives_claude_projects_dir`), opens with the line `# tmux-lives projects v2` (a file without it is ignored whole), then tab-separated `dir`, its newest transcript's mtime (the key), the newest interactive transcript's mtime, and that transcript's `cwd`. A directory is re-read only when its key changes, and the cache rewritten only when something changed. Measured on rocket: 155 ms cold and 43 ms warm, against 180 ms and 88 ms before. The file shares its directory with the theme render cache, whose prune deletes only its own `<digits>-<hex6>.tsv` files.
- **Start** — `new-session -d -c <folder>` (the categorizer names it from the folder, as for any session, so it is addressed by its session id), `send-keys 'claude --continue' Enter`, switch, and leave once no tab is left on the landing. The shell stays after Claude exits, as today. `r` sends `claude --resume` instead.

## Exclusions everywhere else

Landing sessions (by reserved name) are excluded from:

- categorize, rename, `@tmux_lives_display` / `@tmux_lives_claude` writes;
- snapshot and overview (the chooser's model, fallback menu);
- `__tmux_pick_session`, `__tcz_pick_general`, `prune`, `clear` and idle-kill, restore disposal;
- tab titles — a landing tab gets the fixed title `[<h>] landing`.

tmux-resurrect has no per-session exclusion, so snapshots will contain landing sessions. On restore, tmux-lives kills any restored `_landing-*` session (by name — options are not restored) that has no client on it: one with a client belongs to a login made during the restore window.

Tab colour is untouched.

## Configuration

- Universal `tmux_lives_landing`, default `on`; `tmux-lives setup landing on|off|status`. Only the literal `on` is on; unset means on; any other value, including a set-but-empty one, is off — the same rule in the renderer, `status` and the shell side.
- Landing also needs the managed fragment: its tick sweep and `pane-died` hook are what clean landing sessions up. With no fragment (before `setup install`, or after teardown with auto still on), login, the outside-tmux picker and `close` take the legacy path.
- `off` = today's behaviour exactly: auto-pick general sessions, detach on close, no `remain-on-exit`, no `pane-died` hook. The switch exists because this feature governs every attach.
- No new key bindings.

## Platforms

- rocket: tmux 3.3a (measured above).
- macwork: tmux 3.7b (measured, identical).
- macOS has no `/proc`: device identity through `ps eww` (existing helper).

## Testing

- Isolated `-L … -f /dev/null` servers with real pty clients (`script`, run with `env SHELL=/bin/sh` and a long-lived silent stdin), as the existing attach-hook tests do. Every suite that can start a landing app exports the discovery seams, so no test reads `~/.claude/projects` or writes `~/.cache/tmux-lives`.
- Close path: the last pane exits → the client lands on a new `_landing-N` and never on another session, and the closed session is gone; a non-last pane exits → only that pane goes, client unmoved; the landing app exits → respawned; a session name with an apostrophe still closes (`#{q:}`); the `|| kill-pane` fallback closes the pane when the handler cannot run.
- Entry points: `__tcz_commandeer` creates and switches in one call; autostart and the outside-tmux picker are run in a child fish against a recorder `tmux` on `PATH` and a stub categorizer, and the last recorded call is the `exec` (landing on, off, no name, categorizer missing, `picker -t`). `test-tmux-auto.fish` pins bare `tmux` to its own socket by construction.
- The app: real-client tests drive it with keystrokes (`Enter`, `d`, `x`, `q`/Esc no-ops, held `j` and held arrows), sent once the settle window has passed, and the diff emitter is asserted to write nothing on an unchanged frame. Type-ahead goes in through the client's own keyboard (a FIFO held open read-write on the pty client's stdin; `send-keys` would skip the client): ShellFish's `cd "<dir>"` + CR, a burst ending in Enter, a move burst followed by text, and lone keys in the settle window all leave the tab on its landing, and a lone `d` after a quiet second still detaches. An Enter 50 ms behind the text is still part of the burst, CR LF opens the selected row, and lone `d` taps under a second apart are drained only until 2 s after the first paint. Moves act in the window: tapped and held Down move the pointer, a move does not end the window (a lone CR after it is drained), and the preview follows a move 0.2 s after input goes quiet. Idle cadence: with the seams at 2 s and 6 s and the model builder stubbed to record each refresh, an idle app refreshes 6 s apart, and a key refreshes at once (re-reading the project list) and again 3 s later. The suites' real-cache brackets look for this run's footprint (a row from its seam root or its own fixture folders, a cache emptied during the run), not an mtime: the user's own landing apps rewrite `projects.tsv` mid-run. The app's stderr goes to `/dev/null` (the pane command wraps it in `sh -c`): the diff painter never repaints an unchanged row, so error text would otherwise stay on screen.
- Discovery: a fixture projects directory (seam) with slugs, transcripts and mtimes — cwd extraction, the exists-locally filter, running-exclusion, ordering, cache hit and miss, no rewrite when nothing changed; headless and GUI transcripts ignored, worktree and subfolder mapping, generic and group-root directories never read, an unreadable transcript skipped, a cache without the v2 header discarded.
- Layout (v3): pure rendering tests pin the section and box structure (orange claude rail beside the whole section, centered gold box rules ending in `╮`, the right rail one row past the last member with no corner, the gray older box, no bottom borders), the pointer's color per section, the selection stopping at a right rail, both badges, and every frame row's width and the frame's row count; the model places a live claude session in the box its cwd maps to, live before idle within a box, and folds `running` into general.
- Switch mode: an e2e on an isolated server opens the app in switch mode for a real pty client inside a session: the current session is listed and marked `[current]` with the pointer on it, Enter on another session moves the client there and the popup is gone, Esc closes it with the client unmoved, `x` on the current session lands this client (with no landing `pane-died` hook on the server it detaches it instead, and no landing session is made), no settle window (an Enter right after opening acts), and the fragment's switcher binds open switch mode.
- Exclusions: categorize, snapshot, pickers, prune, clear and restore ignore `_landing-*`; the sweep spares young sessions and costs zero tmux calls when clean by construction; the tick-calls suite pins one `list-sessions` per pass.
- Kill switch `off`: the pre-existing close tests run with landing off and every existing suite stays green unchanged; install-side tests cover the fragment render, `setup landing`, teardown restore and the post-update respawn.

## Open items

- Measure what ShellFish does when its tmux client exits (reconnect into a new springboard, or close the tab). Informs the "killed some other way" path, not the design.
- Enter on a project row runs `claude --continue` in the mapped project folder (the repo root, or a worktree's main repository), while Claude keys conversations by exact cwd: when the newest interactive conversation ran in a subfolder or in a worktree that still exists, `--continue` resumes a different conversation than the row's age describes. None is affected on rocket's data as of 2026-10-03.
- Rulings taken while building v3 (settled, not open):
  - Within `general`, the former `running` sessions keep their place ahead of the other general sessions (the overview's order), not interleaved by recency.
  - The switch-mode legend keeps the landing legend's 10-column pitch behind its badge, so `esc close` is clipped below 83 columns (the landing legend's `d detach` already clipped below about 61 columns; the badge moves that to about 70).
  - Enter on a live row goes through `__tcz_switch` in both modes; `--take` (`tmux-lives picker -t` inside tmux) is carried into switch mode, so taking a session over still works there.
  - In switch mode Enter, `n` and `r` close the switcher even when the switch fails (the client stays where it was).
  - `M-s` pressed on a landing tab opens the switcher over the landing page; it is not special-cased (the abandoned landing session is swept like any clientless one).
  - The stderr re-exec the theme-picker verb does for its popup is one shared helper, `__tcz_quiet_exec` (marker `__tcz_quiet`, replacing `__tcz_thp_quiet`), used by both popup verbs.
  - A live Claude session's box comes from its session's active pane's folder (the same folder its displayed project name comes from), not from whichever pane runs claude.
  - The switcher resolves its client the way the other popup binds (modal, theme picker) do: the binds pass a literal `#{client_name}` (display-popup does not expand it), and the app takes the most recently active client, the one that just pressed the key (measured with a second, later-attached client).
