# tmux-lives

Categorized tmux session automation + persistence, packaged as a [fisher](https://github.com/jorgebucaran/fisher) plugin for fish.

It keeps tmux sessions self-categorizing (claude / running / general), auto-attaches the right one on login, prunes stale shells, persists across reboots (tmux-resurrect/continuum), and coexists with the ShellFish iOS app.

## Install

```fish
fisher install <owner>/tmux-lives
tmux-setup     # wires ~/.tmux.conf, TPM plugins, and the systemd units
tmux-status    # verify the install across every layer
```

Open a new tmux window afterward so the managed fragment is picked up.

## Uninstall

```fish
tmux-teardown
fisher remove <owner>/tmux-lives
```

## Layout

- `conf.d/tmux.fish` — runtime (categorize, switcher `ts`, prune, restore, hooks)
- `functions/tmux-categorize.fish` — the categorizer (invoked by tmux as a script)
- `conf.d/tmux-lives-install.fish` — `tmux-setup` / `tmux-teardown` / `tmux-status`
- `tests/` — isolated test suites (`-L` sockets; never touch the real server)
- `docs/superpowers/` — design spec + implementation plan

See `docs/superpowers/specs/` for the design.
