# tmux-lives

Categorized tmux session automation + persistence, packaged as a [fisher](https://github.com/jorgebucaran/fisher) plugin for fish.

It keeps tmux sessions self-categorizing (claude / running / general), auto-attaches the right one on login, prunes stale shells, persists across reboots (tmux-resurrect/continuum), and coexists with the ShellFish iOS app.

## Requirements

- tmux 3.3a or newer (the `set-hook` brace-block syntax used in the managed fragment requires it)
- fish 3.x+
- [fisher](https://github.com/jorgebucaran/fisher)
- git (for TPM plugin cloning)

## Install

```fish
fisher install bit-saver/tmux-lives
tmux-lives setup install     # wires ~/.tmux.conf + plugins, then reloads a running tmux
```

That's it — `tmux-lives setup install` reloads tmux for you if it's running (otherwise the wiring loads when tmux next starts). On Linux (systemd) it also installs save-on-shutdown + restore-at-boot units; on macOS there are no launchd units — persistence is tmux-continuum's autosave plus restore on your first SSH login.

Run `tmux-lives setup verify` anytime to check install health, and `tmux-lives` to list every command. After `fisher install` you'll see a one-line reminder.

## Commands

All functionality is under one unified command:

```
tmux-lives picker, p [-t]             open the session switcher (-t takes it)
tmux-lives attach, a <name> [-t]      attach to a session (-t takes it)
tmux-lives new, n [name]              start a new session (optional name)
tmux-lives close, x, q               kill the current session and exit
tmux-lives clear [-q|-x]              kill idle sessions (-q/-x also exits)
tmux-lives fixssh, f                  repair the SSH agent socket
tmux-lives setup                      install / verify / keys / auto (see: tmux-lives setup -h)
```

Create your own short aliases as desired, e.g. `alias ts="tmux-lives picker"`.

## Uninstall

```fish
tmux-lives teardown
fisher remove bit-saver/tmux-lives
```

## Layout

- `conf.d/tmux.fish` — runtime (categorize, switcher, prune, restore, hooks)
- `functions/tmux-categorize.fish` — the categorizer (invoked by tmux as a script)
- `conf.d/tmux-lives-install.fish` — `tmux-lives` unified command (setup/verify/teardown + dispatcher)
- `tests/` — isolated test suites (`-L` sockets; never touch the real server)
- `docs/superpowers/` — design spec + implementation plan

See `docs/superpowers/specs/` for the design.
