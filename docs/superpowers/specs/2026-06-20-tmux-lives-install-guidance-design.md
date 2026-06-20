# tmux-lives install guidance + `tmux-lives` help command

- **Date:** 2026-06-20
- **Status:** Implemented (Linux suites green)
- **Project:** tmux-lives (fisher plugin)
- **Component:** install/setup layer (`conf.d/tmux-lives-install.fish`)

## Background

`fisher install bit-saver/tmux-lives` is silent beyond fisher's own "Installing …" line. A new
user has no in-terminal signal that the plugin needs a second step (`tmux-setup` wires
`~/.tmux.conf` + TPM/resurrect/continuum — fisher only deploys the fish files), nor any
discoverable list of what commands exist. The README documents this, but nobody reads the README
mid-install.

Two additions fix discoverability: a post-install/update message that tells you the next step, and
a `tmux-lives` help command that lists every command and when to use it.

**Fisher event mechanism (confirmed from `~/.config/fish/functions/fisher.fish`).** Fisher does not
emit a single plugin-level event. For each `.fish` file it deploys, it sources the file and — for
files under `conf.d/` — emits `<conf.d-filename>_<event>`, where `<event>` is `install` on a fresh
install and `update` when the plugin was already present (`emit {$name}_$event`, `$name` = the
conf.d basename). So this plugin's `conf.d/tmux-lives-install.fish` triggers
`tmux-lives-install_install` / `tmux-lives-install_update`, and `conf.d/tmux.fish` triggers
`tmux_install` / `tmux_update`. This matches tide's model (`conf.d/_tide_init.fish` →
`function _tide_init_install --on-event _tide_init_install`). We attach handlers ONLY to the
`tmux-lives-install_*` events so the message fires exactly once. (`_uninstall` exists too; unused
here.)

## Decision

Two pieces, both added to the **existing** `conf.d/tmux-lives-install.fish` (zero net-new files, per
the file-hygiene preference). No existing command's behavior changes; the help command only *lists*
the existing `tmux-*` / `ts` / `tmuxauto` commands — it does not wrap or dispatch to them.

### 1. `tmux-lives` help command

`tmux-lives` with no args, or `help` / `-h` / `--help`, prints the grouped command list to stdout and
returns 0. Any other argument prints `tmux-lives: unknown command '<arg>'` plus the same help to
stderr and returns 1. Exact output:

```
tmux-lives — categorized tmux sessions + persistence (fisher plugin)

Setup / lifecycle:
  tmux-setup      wire ~/.tmux.conf + TPM/resurrect/continuum (run once on a new host;
                  macOS: no launchd units — persistence via continuum + first-access restore)
  tmux-status     check install health across every layer
  tmux-teardown   remove the wiring (TPM plugins left in place)

Daily use:
  ts [name]       switch/create a categorized session — popup inside tmux;
                  with no name and no server, cold-starts your restored sessions
  tmuxauto …      on | off | status | toggle  — control auto-attach on login
  tmtake <name>   force-take a session (detach a stale/ghost client)
  fixssh          refresh SSH_AUTH_SOCK inside a reattached session
```

### 2. Post-install / update messages

Two fisher event handlers in the same file. They share a one-line "see `tmux-lives`" footer helper
to avoid copy drift.

- `--on-event tmux-lives-install_install` (fresh install) prints to stdout:
  ```
  ✓ tmux-lives installed. To finish on a new host:
      tmux-setup     # wire tmux + plugins
      tmux-status    # verify
    then open a new tmux window. Run `tmux-lives` to see all commands.
  ```
- `--on-event tmux-lives-install_update` (on `fisher update`) prints to stdout:
  ```
  ✓ tmux-lives updated — open a new shell (exec fish) to load it. Run `tmux-lives` to see all commands.
  ```

The handler functions are underscore-prefixed (e.g. `_tmux_lives_post_install` /
`_tmux_lives_post_update`) and defined in `conf.d/tmux-lives-install.fish`, which fisher sources
before emitting — so the handler is registered when the event fires.

## Constraints

- **File hygiene (hard).** Zero net-new files in `conf.d/` or `functions/`. The help command and
  both event handlers live in the existing `conf.d/tmux-lives-install.fish`. Underscore-prefix the
  internal handlers; `tmux-lives` is the one new user-facing command (verified free of collisions
  against the live fish functions, alongside `tmux-help`/`tl`).
- **No behavior change to existing commands.** `tmux-setup`/`teardown`/`status`, `ts`, `tmuxauto`,
  `tmtake`, `fixssh` are untouched. All eight suites stay green.
- **Pure fish.** No new dependency.

## Architecture / files touched

- `conf.d/tmux-lives-install.fish` — add `function tmux-lives` (help), `_tmux_lives_post_install`
  (`--on-event tmux-lives-install_install`), `_tmux_lives_post_update`
  (`--on-event tmux-lives-install_update`), and a small shared footer helper. (existing file)
- `tests/test-tmux-install.fish` — add assertions. (existing file)
- Docs: `README.md` Install section mentions `tmux-lives` for the command list; `CLAUDE.md`
  command/keymap note.

## Testing

Append to `tests/test-tmux-install.fish` (sourced already; `t` assert helper in scope):

- **Help content:** `tmux-lives` output contains each command name (`tmux-setup`, `tmux-status`,
  `tmux-teardown`, `ts`, `tmuxauto`, `tmtake`, `fixssh`) and both group headers (`Setup / lifecycle`,
  `Daily use`).
- **Help aliases:** `tmux-lives help`, `tmux-lives -h`, `tmux-lives --help` each print the same body
  and return 0.
- **Unknown arg:** `tmux-lives bogus` returns 1.
- **Event wiring (the one real risk — dashed event name):** after sourcing the file, `emit
  tmux-lives-install_install` produces output containing `tmux-setup`, and `emit
  tmux-lives-install_update` produces output containing `exec fish`. This proves the
  `--on-event tmux-lives-install_*` handlers actually fire with the dashed event name.
- All existing suites still print their pass line.

## Out of scope (YAGNI)

- No subcommand dispatch (`tmux-lives setup` → `tmux-setup` wrappers) — the `tmux-*` commands already
  exist; the help command only lists them.
- No `_uninstall` message.
- No completions file for `tmux-lives` (would be a net-new `completions/` file; not worth it for a
  help command).
