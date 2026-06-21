# tmux-lives unified command + configurable switcher keys

- **Date:** 2026-06-21
- **Status:** Implemented (Linux suites green; Mac live-smoke pending)
- **Project:** tmux-lives (fisher plugin)
- **Component:** command surface (`conf.d/tmux-lives-install.fish` + `conf.d/tmux.fish`)

## Background

The plugin currently exposes a scatter of standalone commands: `tmux-setup`, `tmux-teardown`, `tmux-status` (admin, in `conf.d/tmux-lives-install.fish`) and `ts`, `tmuxauto`, `tmtake`, `fixssh` (daily, in `conf.d/tmux.fish`), plus a `tmux-lives` help command that only *lists* them. The switcher keybinding is hardcoded in the managed fragment as `prefix S` only; the no-prefix `Opt+s` (`bind -n M-s`) has to be hand-added to `~/.tmux.conf`.

Two problems: (1) the switcher keys aren't configurable or fully managed — `Opt+s` is a manual line the user must track; (2) the command surface is a set of "random commands to know" with no single discovery point.

Decision (with the user): collapse everything under one `tmux-lives <command>` dispatcher with a comprehensive help page, and make the switcher keys configured entirely through `tmux-lives setup` (persisted, nothing hand-maintained). The user creates their own short aliases (e.g. `ts`); the plugin does not ship aliases.

## Decision

### 1. Single `tmux-lives <command>` dispatcher

`tmux-lives` becomes the only user-facing command. Bare `tmux-lives` (or `help` / `-h` / `--help`) prints the grouped help to stdout (exit 0); an unknown command prints `tmux-lives: unknown command '<x>'` + the help to stderr (exit 1).

| Command | Replaces | Behavior |
|---|---|---|
| `tmux-lives setup [--prefix-key K] [--switcher-key K]` | `tmux-setup` | wire `~/.tmux.conf` + TPM/resurrect/continuum; configure + persist switcher keys |
| `tmux-lives status` | `tmux-status` | health across every layer, including the active switcher keys |
| `tmux-lives teardown` | `tmux-teardown` | remove the wiring (TPM plugins left in place) |
| `tmux-lives switch [name]` | `ts` | switch/create a categorized session |
| `tmux-lives auto on\|off\|status\|toggle` | `tmuxauto` | control auto-attach on SSH login |
| `tmux-lives take <name>` | `tmtake` | force-take a session (detach a stale/ghost client) |
| `tmux-lives fixssh` | `fixssh` | refresh `SSH_AUTH_SOCK` inside a reattached session |

The standalone names (`tmux-setup`, `ts`, `tmuxauto`, `tmtake`, `fixssh`, `tmux-teardown`, `tmux-status`) are **removed** — canonical access is `tmux-lives <verb>`. The user aliases their own shortcuts.

### 2. Configurable switcher keys (via `setup`, persisted)

- `--prefix-key K` → prefix-table bind (`bind-key <K>` → `prefix <K>`). Default **`S`**.
- `--switcher-key K` → direct/no-prefix bind (`bind-key -n <K>`). Default **`M-s`** (Opt+s).
- Empty value disables that bind: `tmux-lives setup --switcher-key ''`.
- Persistence: a passed flag writes a fish **universal variable** (`tmux_lives_prefix_key` / `tmux_lives_switcher_key`) — machine-managed state the command reads/writes, never a hand-edited line. `setup` with no key flags keeps the persisted value; first-ever run with none uses the defaults. So a plain `tmux-lives setup` binds **both `prefix S` and `Opt+s`** out of the box.
- Distinguish unset (→ default) from set-empty (→ disabled): use `set -q` for existence, then the value (empty = disabled).

### 3. The help page (single discovery point)

Bare `tmux-lives` prints a grouped list — Setup/lifecycle and Daily — one concise line per command, including the `setup` key flags, and a closing tip that the user can alias shortcuts. Exact text in the plan; it must name every command and both groups.

### 4. Fragment

`__tmux_lives_render_fragment` takes the categorizer path **plus the two resolved keys** and emits a brace-block `if-shell` (display-popup → `popup`, else → `menu`) containing one `bind-key <prefix-key>` and one `bind-key -n <switcher-key>` per branch, **omitting** whichever key is empty/disabled. Keeping the keys as function arguments keeps `render_fragment` pure and unit-testable. The TPM `run` line and everything else in the fragment are unchanged.

## Constraints

- **Zero net-new files in `conf.d/` or `functions/`.** The dispatcher and help live in the existing `conf.d/tmux-lives-install.fish`; the daily helpers stay in `conf.d/tmux.fish`. Existing function bodies are renamed in place to `__tmux_lives_*` helpers. Tests stay in `tests/`.
- **Internal callers unaffected.** Autostart uses `__tmux_autostart` (internal); the tmux fragment binds call the categorizer script directly (not `ts`); the commandeer hook calls the categorizer. None reference the user commands, so the rename is safe.
- **Sourcing order is irrelevant.** fish sources `tmux-lives-install.fish` before `tmux.fish`, but the dispatcher resolves helper calls at invocation time (after both are sourced), so it can call `__tmux_lives_switch` etc. defined in `tmux.fish`.
- **Pure fish.** No new dependency.
- **Accepted breaking change:** the standalone command names go away (the user re-aliases). The live Linux host keeps working (autostart + fragment binds don't depend on the command names); only user-typed names change.

## Architecture / files touched

- `conf.d/tmux.fish` — rename `ts`→`__tmux_lives_switch`, `tmuxauto`→`__tmux_lives_auto`, `tmtake`→`__tmux_lives_take`, `fixssh`→`__tmux_lives_fixssh` (bodies unchanged). (existing file)
- `conf.d/tmux-lives-install.fish` — rename `tmux-setup`→`__tmux_lives_setup`, `tmux-teardown`→`__tmux_lives_teardown`; expand the existing `tmux-lives` function into the dispatcher (subcommand routing + help + `setup` key-flag parsing → persist universal vars); `render_fragment` gains the two key params; `__tmux_lives_status_lines` gains a switcher-keys line; the post-install/update messages reference `tmux-lives setup`/`status`. (existing file)
- `README.md`, `CLAUDE.md` — update the command surface to `tmux-lives <verb>`.
- `tests/test-tmux-install.fish`, `tests/test-tmux-auto.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-status.fish` — update calls from standalone names to `__tmux_lives_*` helpers / `tmux-lives <verb>`; add the new assertions.

## Testing

- **Dispatcher routing:** bare/`help`/`-h`/`--help` print help listing every command (exit 0); unknown command → stderr + exit 1; each subcommand routes to its helper (verify by stubbing the helper to emit a marker, e.g. `status`, `switch`).
- **Key config (pure):** `render_fragment cat S M-s` emits both binds; custom keys emit custom binds; `render_fragment cat '' M-s` omits the prefix bind (and vice-versa); both branches (popup + menu) carry the binds.
- **Key persistence/resolution:** a focused parser helper maps `--prefix-key/--switcher-key` flags → the universal vars; key resolution distinguishes unset (default) from set-empty (disabled). (The heavy `setup` integration — git clones — is verified live, as today.)
- **Status:** `__tmux_lives_status_lines` includes the switcher-keys line reflecting the resolved keys.
- **Existing suites:** updated to the renamed helpers / `tmux-lives <verb>` and all stay green.
- **Mac live-smoke (user):** `tmux-lives setup` binds `prefix S` + `Opt+s`; `tmux-lives setup --switcher-key C-s` rebinds; `tmux-lives status` shows the keys; `tmux-lives switch` works.

## Out of scope (YAGNI)

- Shipping aliases (`ts`, `tl`) — the user creates their own.
- Per-subcommand `--help` (the single grouped help page is the discovery point).
- Configuring keys outside `setup` (e.g. a top-level `tmux-lives --switcher-key`) — keys are a setup concern (they re-render the fragment), so they live on `setup`.
- Multiple alternate keys (one prefix bind + one direct bind is enough).
