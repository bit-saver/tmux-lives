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
tmux-lives setup <command> [options]   install / verify / teardown / keys / auto (see: tmux-lives setup -h)
tmux-lives update, u                   update the plugin via fisher (says if already up to date)

tmux-lives new, n [name]               start a new session (optional name)
tmux-lives attach, a <name> [-t]       attach to a session (-t takes it)
tmux-lives picker, p [-t]              open the session switcher (-t takes it)
tmux-lives fix, f                      repair the SSH agent socket
tmux-lives categorize, c               re-categorize sessions (fix a bad name)
tmux-lives clear [-q|-x]               kill idle sessions (-q/-x also exits)
tmux-lives close, x, q                 kill the current session and exit
```

Create your own short aliases as desired, e.g. `alias ts="tmux-lives picker"`.

### ShellFish tab color & non-ShellFish baseline

A `client-attached` hook colors ShellFish tabs on attach (the OSC escape goes directly to that client's tty — other clients see nothing) and re-applies a baseline config for every non-ShellFish client. `setup color` also derives a global tmux **status bar** tint from the ShellFish color — lighter by default (`-i`/`--invert` for darker), visible to all clients; status text auto-tints to the bar color. `setup color --apply` (short `-a`) reapplies the currently-stored color to both surfaces — the ShellFish tab OSC and the tmux status bar — without retyping it (handy if a new tab came up without the color).

```fish
tmux-lives setup color "#1f6feb"            # set this server's ShellFish toolbar color
tmux-lives setup color "#1f6feb" -i         # darker status bar
tmux-lives setup color                      # show the current color
tmux-lives setup color --apply              # reapply stored color live (tab OSC + status bar)
tmux-lives setup color ""                   # clear it

tmux-lives setup conf                       # show / seed ~/.tmux-lives.conf
tmux-lives setup conf edit                  # open it in $EDITOR
tmux-lives setup conf add "set -g mouse off"  # append a tmux command
tmux-lives setup conf reset                 # restore defaults (backs up to .bak)
```

`~/.tmux-lives.conf` is the general tmux-lives config — sourced by the managed fragment at load (every client) and re-applied on every non-ShellFish attach. It is seeded once with active status-bar polish: `❯ #{session_name}` on the left, longer name lengths, a 12-hour month-first clock in `@tmux_lives_status_right`, and bold current window. Edit it freely; `tmux-lives setup conf reset` backs up your version to `.bak` and restores the defaults. The `client-attached` hook lives in the managed fragment, so it reaches a host when `tmux-lives setup install` (re)renders it — setting a color via `tmux-lives setup color …` re-renders automatically.

### Theming (gradient map)

The status bar is themed by a gradient map: your seed (`setup color`) IS the status-bar background, verbatim; the other six UI roles (separators · tabs · active · windows · cap · text), each pinned at a lightness, sample one hue-arc gradient that clusters around it. A **scheme is a set of companion colors for the seed** — the seed itself is always the status-bar background, in every scheme; the companions cluster around it (gentle lightness offsets, hue/chroma do the differentiating) and only the text color jumps for contrast. Default scheme: `mono`.

    tmux-lives setup theme               # the picker (M-k / M-m k do the same):
                                         # scheme catalog + a live preview of YOUR bar
    tmux-lives setup theme list          # print every scheme as a 7-swatch strip
    tmux-lives setup theme warm --phase 30
    tmux-lives setup theme off           # the legacy look (derived bar, neutral cap)

Schemes: `mono` · `warm` · `cool` · `span` · `wide` · `aurora` · `sunset` · `fire` · `complement` · `full`. Knobs: `--phase <deg>`, `--vividness soft|balanced|vivid`, `--shape arc|flat`, `--ease linear|cubic`, `--contrast auto|lighter|darker` (which side the companions/text sit on; `auto` picks by seed lightness), `--rotate 0-4` (cycles which companion role gets which computed color). ShellFish tabs wear the `tabs` role; roles are live `@options` (`@tmux_lives_sep_fg`, `@tmux_lives_text_fg`, …) — retune with `tmux set -g @tmux_lives_… '#hex'`; the `windows` colour rides `status-style fg`. Upgrading from the old cap-color engine: your `cap` settings migrate automatically (scheme resets to `mono` — the models differ; `M-k` now opens the theme picker). Upgrading from the v3 polarity model: `--polarity`/`--range` are gone (replaced by `--contrast`/`--rotate` above) — `fisher update` erases the old settings automatically, with a one-line notice.

The picker (`setup theme`, `M-k`, or `M-m k`) shows a ShellFish tab chip when a ShellFish client is attached, a live bar preview, and labeled adjustment/scheme zones with a key legend: `↑↓` scheme · `←→` phase · `v` vividness · `s` shape · `e` ease · `d` contrast · `o` rotate · `b` seed (opens RGB sliders — `t` inside for typed hex) · `a` apply preview (live, unsaved) · `⏎` save · `r` reset knobs · `Esc`/`q` revert and close.

### In-tmux command surface (launcher + scratch split + resize)

When a full-screen program occupies your pane, a few bindings let you drive tmux-lives without leaving it:

**Command launcher (`M-m`)** — a `display-popup` that draws a colored, categorized legend, then acts on a **single keypress** and closes: `p` picker · `n` new · `c` clear · `g` categorize · `t` scratch toggle · `r` resize (enters resize mode) · `b` set bar color (typed-input prompt) · `k` theme (opens the theme picker) · `Esc`/`q` close. Each action runs *after* the popup closes, so its result is visible (the picker/theme picker open once the launcher is gone — tmux doesn't allow a popup inside a popup). Falls back to a `display-menu` when `display-popup` is unavailable.

**Scratch split toggle (`M-t`)** — splits a throwaway shell pane beside the active pane (marked `@tmux_lives_scratch`). Press again to refocus the original pane and kill the scratch.

**Scratch resize mode (`M-r`)** — with a scratch pane open, enters a native tmux key-table (the panes stay fully visible, unlike a popup): arrows resize the scratch, `h`/`w` switch it side-by-side vs stacked, `x` closes it, `Esc`/`Enter` exit. Also reachable via the launcher's `r` key. If no scratch pane exists yet, it nudges you to open one first.

**Status-bar toggles (`C-M-a` / `C-M-s`)** — `Ctrl+Opt+A` flips the status bar between top and bottom; `Ctrl+Opt+S` hides/shows it. The chosen value is stored in `~/.config/tmux/tmux-lives-state.conf` (machine-owned) and reapplied on every load, so it survives new sessions and reboots. Configure or disable the keys with `setup keys --status-pos-key <k>` / `--status-vis-key <k>` (`''` disables).

**Colored picker preview** — the picker's right-pane preview shows the target session's real colors (`capture-pane -e` with ANSI-aware truncation), matching tmux's native `choose-tree`. A key-legend footer row spells out the controls: `↑↓` move · `⏎` switch · `x` kill · `Esc` close.

Configure or disable the binds via `setup keys`:

```fish
tmux-lives setup keys --modal-key M-m    # default (command launcher)
tmux-lives setup keys --scratch-key M-t  # default (scratch toggle)
tmux-lives setup keys --resize-key M-r   # default (scratch resize mode)
tmux-lives setup keys --status-pos-key C-M-a  # default (status bar top/bottom)
tmux-lives setup keys --status-vis-key C-M-s  # default (status bar hide/show)
tmux-lives setup keys --theme-key M-k    # default (theme picker)
tmux-lives setup keys --modal-key ''     # disable a bind
```

These binds become live on your next `fisher update` / `tmux-lives update`. If any of `M-m`, `M-t`, `M-r`, `M-k`, `C-M-a`, or `C-M-s` collide with an existing terminal or tmux bind, rebind or disable them before updating.

## Uninstall

```fish
tmux-lives setup teardown
fisher remove bit-saver/tmux-lives
```

## Layout

- `conf.d/tmux.fish` — runtime (categorize, switcher, prune, restore, hooks)
- `functions/tmux-categorize.fish` — the categorizer (invoked by tmux as a script)
- `conf.d/tmux-lives-install.fish` — `tmux-lives` dispatcher + the `setup` group (install/verify/teardown/keys/auto)
- `tests/` — isolated test suites (`-L` sockets; never touch the real server)
- `docs/superpowers/` — design spec + implementation plan

See `docs/superpowers/specs/` for the design.
