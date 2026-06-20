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
tmux-setup     # wires ~/.tmux.conf, TPM plugins, and the systemd units
tmux-status    # verify the install across every layer
```

On Linux (systemd) `tmux-setup` also installs save-on-shutdown + restore-at-boot units. On macOS there are no launchd units — persistence is provided by tmux-continuum's autosave plus restore on your first `ts` / SSH login.

Open a new tmux window afterward so the managed fragment is picked up.

Run `tmux-lives` at any time to list the commands and when to use each. After `fisher install` you'll see a one-line reminder to run `tmux-setup`.

## Uninstall

```fish
tmux-teardown
fisher remove bit-saver/tmux-lives
```

## Layout

- `conf.d/tmux.fish` — runtime (categorize, switcher `ts`, prune, restore, hooks)
- `functions/tmux-categorize.fish` — the categorizer (invoked by tmux as a script)
- `conf.d/tmux-lives-install.fish` — `tmux-setup` / `tmux-teardown` / `tmux-status`
- `tests/` — isolated test suites (`-L` sockets; never touch the real server)
- `docs/superpowers/` — design spec + implementation plan

See `docs/superpowers/specs/` for the design.
