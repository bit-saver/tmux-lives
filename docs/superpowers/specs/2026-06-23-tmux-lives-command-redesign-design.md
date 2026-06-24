# tmux-lives — command-surface redesign (design)

Status: approved 2026-06-23, ready for implementation plan.

## Goal

Refine the `tmux-lives <verb>` surface into single-responsibility verbs and hide the install/configuration commands behind a `setup` group. Each verb does one obvious thing; the daily commands fit on one flat help screen with no section headers; `setup` is the single discovery point for install/config.

## Motivation

The current surface mixes concerns: `switch`/`picker` both opens the switcher AND creates/attaches by name AND cold-starts; `start` overlaps with creating; install/verify/teardown/key-flags clutter the top level. The redesign separates "get into a session" into distinct verbs (`new`, `attach`, `picker`), gives a dedicated tidy-up (`clear`) and exit (`close`), and moves install/config under `setup`.

## New command surface

### Top-level (daily) commands — flat list, no SESSION header

| Command | Behavior |
| --- | --- |
| `picker, p [-t]` | Open the popup switcher. `-t` = "take": the selected session detaches any other clients before switching. No name argument — the intent is to pick. Outside tmux: ensure the server (restore-if-none) → attach → auto-open the popup. |
| `attach, a <name> [-t]` | Attach to an EXISTING session by name; error if it doesn't exist. `-t` detaches other clients (take). Inside tmux: `switch-client`. Outside tmux: ensure the server → `exec` attach. |
| `new, n [name]` | Create a brand-new categorized session whose cwd is `$HOME`. Optional `name` (slugified) becomes the session name; without a name it's a general session named `gen-N`. Works inside or outside tmux (starts/ensures the server if needed). Drops you into it. |
| `close, x, q` | Kill the CURRENT session and return to the shell — always exit, even if other sessions exist. |
| `clear [--exit \| --quit \| -q \| -x]` | Kill every idle ("general") session — keep claude/running sessions AND your current session. With the flag, also kill the current session and exit (≈ `clear` + `close`). |
| `fixssh, f` | Repair `SSH_AUTH_SOCK` (and friends) after reconnecting. *(unchanged)* |
| `setup …` | Install & configuration group — see below. Bare `setup` (or `-h`/`--help`/`help`) prints the setup help. |
| `help, -h, --help` | Main help (lists the daily commands + a pointer to `tmux-lives setup -h`). |

### `setup` group

| Command | Behavior |
| --- | --- |
| `setup install, i` | The original `setup`: wire `~/.tmux.conf` + clone TPM/resurrect/continuum + (Linux) install systemd units, then reload tmux. |
| `setup verify, v` | Install-health check + the active switcher keys. |
| `setup teardown` | Remove the wiring (plugin & TPM left in place). |
| `setup keys` | Bare: show the current prefix + switcher keys. `-p/--prefix-key <key>`, `-s/--switcher-key <key>`: set them — persisted to the universal vars (`''` disables a bind), then regenerate the managed fragment and reload tmux so the new binds take effect (the same effect the old `setup --prefix-key` flow had). |
| `setup auto on\|off\|toggle\|status` | Control auto-attach to tmux on SSH login. *(moved from top-level)* |

### Removed / renamed / freed

- **Removed verbs:** `start` (replaced by `new`); `take` (folded into the `-t` flag on `picker`/`attach`).
- **Moved under `setup`:** `verify`, `teardown`, the key-flags (now `setup keys -p/-s`), and `auto`.
- **Behavior change:** bare `tmux-lives setup` no longer installs — it prints the setup help. Installing is now `tmux-lives setup install`.
- **Freed aliases:** `s` (was `start`), `t` (was `take`), top-level `v` (verify is now `setup verify, v`).
- **New aliases:** `attach→a`, `new→n` (consistent with the project's short-alias convention).

## Key behaviors and decisions

### Restore on first access (macOS persistence)

`start` was the only on-demand trigger for restoring the resurrect snapshot on macOS (it ran `__tmux_autostart → __tmux_restore` when no server existed). With `start` gone, that invariant moves into a shared helper:

```
__tmux_ensure_server  →  if no tmux server is running, run __tmux_restore
                         (starts the server, restores the snapshot, disposes idle shells)
```

`new`, `attach`, and `picker` each call `__tmux_ensure_server` before acting when invoked outside tmux. So whichever command you run first after a Mac reboot restores your saved sessions, then does its own thing (`new` drops you into a fresh session with the restored ones recoverable via `picker`). On Linux the server is already up at boot (systemd), so the helper is a no-op there. The SSH-login autostart (`__tmux_autostart`) is unchanged.

### `picker` outside tmux

The popup is a `display-popup`, which needs an attached client and cannot render from a bare shell. So outside tmux, `picker` ensures the server, attaches (MRU general or create), and auto-opens the popup. Implementation will attempt tmux command chaining (`… attach \; display-popup …` or an equivalent one-shot on the new client) and **verify it works on tmux 3.3a / macOS tmux**; if it can't be made to work cleanly, fall back to: attach only, and the user opens the popup with `Opt+s` / `prefix S`.

### `take` via `-t`

The retired `take` logic (detach a stale/other client from a target) becomes the `-t` flag:
- `attach <name> -t` → detach other clients from `<name>`, then attach/switch.
- `picker -t` → the popup's Enter-to-select detaches other clients from the chosen session before `switch-client`. This threads a `--take` flag from `tmux-lives picker -t` through `__tcz_open_switcher` into the popup process; the `Opt+s`/`prefix S` key bindings still open the popup in normal (non-take) mode.

### `close`

Always returns you to the shell. Kills the current session and detaches the client even when other sessions exist (via `detach-on-destroy` and/or an explicit detach — exact mechanism verified on 3.3a + macOS during implementation). Outside tmux: a friendly "not in a tmux session" message, exit non-zero.

### `clear`

Kills every **general** (idle-shell) session except the current one; keeps claude/running sessions and the current session. Idle detection reuses the existing categorization / `__tmux_session_is_idle`. With `--exit`/`--quit`/`-q`/`-x`, it additionally closes the current session and exits (always returns to the shell, like `close`) — this holds even if the current session is a claude/running one (you asked to leave). Outside tmux: clears idle sessions against the running server if one exists; no current session to keep/close.

### `new` / `attach` collisions

Crisp single-responsibility, symmetric:
- `new <name>` when `<name>` already exists → error ("session '<name>' already exists — use `attach <name>`"). `new` only creates.
- `attach <name>` when `<name>` doesn't exist → error ("no session '<name>' — use `new <name>`"). `attach` only attaches.
- `new` (no name) never collides — `gen-N` picks the lowest free index.
- A `new <name>` session keeps its hand-name (the categorizer's ownership guard never auto-renames it) but is still categorized for grouping in the picker.

## Architecture

- **Top-level dispatcher** (`tmux-lives`, in `conf.d/tmux-lives-install.fish`): routes the daily verbs + their aliases, the `setup` group, and `help`. Unknown verb → stderr + the main help + exit 1.
- **Setup sub-dispatcher** (new, e.g. `__tmux_lives_setup_dispatch`): routes `install/i`, `verify/v`, `teardown`, `keys`, `auto`; bare/`-h`/`--help`/`help` → setup help; unknown → stderr + setup help + exit 1.
- **Session helpers** (`conf.d/tmux.fish`):
  - new: `__tmux_lives_attach`, `__tmux_lives_new`, `__tmux_lives_close`, `__tmux_lives_clear`, `__tmux_ensure_server`.
  - changed: `__tmux_lives_picker` loses its `[name]` branch, gains `-t`, and gains the outside-tmux attach-then-popup path.
  - moved (routing only, body unchanged): `__tmux_lives_auto` is now reached via `setup auto`.
  - removed: `__tmux_lives_start`, `__tmux_lives_take` (its detach logic reused by `-t`).
- **Popup `--take`**: `__tcz_open_switcher` and the popup loop in `functions/tmux-categorize.fish` accept a take flag; on select, detach other clients from the target before `switch-client`.
- **Help text** lives in two functions: `__tmux_lives_help` (main) and a new `__tmux_lives_setup_help`.

## Help screens

Main (`tmux-lives`, `-h`, `--help`, `help`):

```
tmux-lives — categorized tmux sessions, switcher & persistence

USAGE
  tmux-lives <command> [options]

  picker, p [-t]              open the session switcher (-t takes it)
  attach, a <name> [-t]       attach to a session (-t takes it)
  new, n [name]               start a new session (optional name)
  close, x, q                 kill the current session and exit
  clear [-q|-x]               kill idle sessions (-q/-x also exits)
  fixssh, f                   repair the SSH agent socket
  setup                       install / verify / keys / auto — run `tmux-lives setup -h`

help                          show this help  (-h, --help)
```

Setup (`tmux-lives setup`, `setup -h`, `setup --help`, `setup help`):

```
tmux-lives setup — install & configuration

  install, i                  wire ~/.tmux.conf + TPM/resurrect/continuum (+ systemd on Linux)
  verify, v                   install health + the active switcher keys
  teardown                    remove the wiring (plugin & TPM kept)
  keys                        show the current switcher keys
    -p, --prefix-key <key>    switcher bind in the prefix table   (default: S) ('' to disable)
    -s, --switcher-key <key>  switcher bind without prefix        (default: M-s = Opt+s) ('' to disable)
  auto on|off|toggle|status   auto-attach to tmux on SSH login
```

## Testing

- **Routing** (`test-tmux-install.fish`): every top-level verb + alias routes to the right helper (stub the helpers); the `setup` group routes `install/i`, `verify/v`, `teardown`, `keys`, `auto`; bare `setup` and `setup -h` show setup help; unknown top-level and unknown setup verbs return 1; main help lists the daily verbs and points at `setup -h`; setup help lists the setup verbs.
- **Behavior** (`test-tmux-auto.fish`, isolated `-L` server + stubs):
  - `__tmux_ensure_server`: no-op when a server is running; runs `__tmux_restore` when none (stub `__tmux_restore`).
  - `new`/`attach`/`picker` outside tmux call `__tmux_ensure_server` first (stub it + `__tmux_autostart`/exec paths since they exec).
  - `new` collision errors; `attach` missing-session errors; `new` (no name) creates a general session.
  - `close` kills the current session and detaches (verified against an isolated server).
  - `clear` kills general sessions but keeps claude/running + current; `--exit` also closes current.
  - `-t` detaches other clients (reusing the take/detach logic).
- **Popup `--take`** (`test-tmux-categorize.fish` / `test-tmux-popup.fish`): the take flag threads through and the select path detaches before switching (assert the emitted command, headless).

Keep the suite green; no silent truncation of coverage.

## Deployment

Code change (verbs) → live via `fisher update` + `exec fish`. The `setup`-group help and routing are plugin code (no fragment change), so no `setup install` re-run is needed for the new commands themselves. (The earlier `automatic-rename-format` window fix still needs a `setup install` re-run to regenerate the fragment, but that's independent of this redesign.) Old muscle-memory verbs (`tmux-lives verify`, `tmux-lives start`, `tmux-lives take`) will hit "unknown command" — no migration hints (decided 2026-06-23); the main help makes the new layout discoverable.

## Out of scope (separate follow-up)

The **picker activity indicator** (active vs idle claude). Investigation showed output-recency (`session_activity`) is a misleading signal — a claude session waiting for input shows no recent output yet is active. The right signal/design is its own brainstorm after this redesign ships. The existing `claude` vs `general` categorization already distinguishes "claude running" from "just a shell in the directory."
