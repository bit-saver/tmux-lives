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
tmux-lives setup     # wires ~/.tmux.conf, TPM plugins, and the systemd units
tmux-lives status    # verify the install across every layer
```

On Linux (systemd) `tmux-lives setup` also installs save-on-shutdown + restore-at-boot units. On macOS there are no launchd units — persistence is provided by tmux-continuum's autosave plus restore on your first `tmux-lives switch` / SSH login.

Open a new tmux window afterward so the managed fragment is picked up.

Run `tmux-lives` at any time to list all commands and when to use each. After `fisher install` you'll see a one-line reminder.

## Commands

All functionality is under one unified command:

```
tmux-lives setup [--prefix-key K] [--switcher-key K]   wire ~/.tmux.conf + TPM/resurrect/continuum;
                                                        set switcher keys (defaults: prefix S, Opt+s=M-s;
                                                        empty value disables that bind)
tmux-lives status                                       check install health (incl. switcher keys)
tmux-lives teardown                                     remove the wiring (TPM plugins left in place)
tmux-lives switch [name]                                switch/create a categorized session
tmux-lives auto on|off|status|toggle                    control auto-attach on SSH login
tmux-lives take <name>                                  force-take a session (detach a stale/ghost client)
tmux-lives fixssh                                       refresh SSH_AUTH_SOCK inside a reattached session
```

Create your own short aliases as desired, e.g. `alias ts="tmux-lives switch"`.

## Uninstall

```fish
tmux-lives teardown
fisher remove bit-saver/tmux-lives
```

## Layout

- `conf.d/tmux.fish` — runtime (categorize, switcher, prune, restore, hooks)
- `functions/tmux-categorize.fish` — the categorizer (invoked by tmux as a script)
- `conf.d/tmux-lives-install.fish` — `tmux-lives` unified command (setup/status/teardown + dispatcher)
- `tests/` — isolated test suites (`-L` sockets; never touch the real server)
- `docs/superpowers/` — design spec + implementation plan

See `docs/superpowers/specs/` for the design.
