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

### ShellFish/iTerm2 tab color & baseline

A `client-attached` hook colors ShellFish and iTerm2 tabs on attach — detected via `LC_TERMINAL` (`ShellFish` / `iTerm2`), the color+title escapes go straight to that client's tty, other clients see nothing — and re-applies a baseline config for every other client. `setup color` also derives a global tmux **status bar** tint from the ShellFish color — lighter by default (`-i`/`--invert` for darker), visible to all clients; status text auto-tints to the bar color. `setup color --apply` (short `-a`) reapplies the currently-stored color to both surfaces — the client's tab OSC (ShellFish or iTerm2) and the tmux status bar — without retyping it (handy if a new tab came up without the color).

```fish
tmux-lives setup color "#1f6feb"            # set this server's tab/toolbar color (ShellFish + iTerm2)
tmux-lives setup color "#1f6feb" -i         # darker status bar
tmux-lives setup color                      # show the current color
tmux-lives setup color --apply              # reapply stored color live (tab OSC + status bar)
tmux-lives setup color ""                   # clear it

tmux-lives setup conf                       # show / seed ~/.tmux-lives.conf
tmux-lives setup conf edit                  # open it in $EDITOR
tmux-lives setup conf add "set -g mouse off"  # append a tmux command
tmux-lives setup conf reset                 # restore defaults (backs up to .bak)
```

`~/.tmux-lives.conf` is the general tmux-lives config — sourced by the managed fragment at load (every client) and re-applied on every attach from a client that isn't ShellFish or iTerm2. It is seeded once with active status-bar polish: `❯ #{session_name}` on the left, longer name lengths, a 12-hour month-first clock in `@tmux_lives_status_right`, and bold current window. Edit it freely; `tmux-lives setup conf reset` backs up your version to `.bak` and restores the defaults. The `client-attached` hook lives in the managed fragment, so it reaches a host when `tmux-lives setup install` (re)renders it — setting a color via `tmux-lives setup color …` re-renders automatically.

### Cursor flicker inside tmux

Two unrelated things make a terminal's cursor strobe inside tmux, and the managed fragment handles both.

The first is tmux re-emitting the cursor *style* on every redraw, which some terminals repaint on each time. Pinning a **steady** style makes the re-emission invisible; the fragment sets `cursor-style` from `tmux_lives_cursor_style` (default `block`; `''` leaves tmux's own default alone).

The second only shows up with a full-screen TUI doing continuous work. tmux decides, per client and only at attach time, whether a terminal can buffer **synchronized output** — and it decides from its own terminal identification, never by asking the client. Terminals it doesn't recognise get every frame written unwrapped, so each intermediate state is painted, including the cursor hide/show pair in every frame. The fragment tells tmux the terminal can sync, via `tmux_lives_sync_terminals` (default `xterm*`; `''` disables):

```fish
set -U tmux_lives_sync_terminals ''        # disable
set -U tmux_lives_sync_terminals 'xterm*'  # default
```

This is **gated to tmux 3.7 and newer** for two reasons: only there does the capability map to DECSET 2026 (older tmux emits an iTerm2-specific DCS form instead), and only there can the problem occur at all — older tmux never reports mode 2026 as available, so applications never turn synchronized output on in the first place. On tmux 3.3a the line is present but inert.

Both settings apply to clients that attach *after* the fragment loads. tmux never revisits a client's capabilities once it has attached, so an already-open terminal keeps its old behaviour until it reconnects.

### Theming

A theme is your **seed** colour (set with `setup color`) plus three choices about what to do with it.

The two large areas on screen — the tmux status bar and the ShellFish/iTerm2 tab strip — are what actually carry a scheme. The seed anchors one of them, a **relationship** says how far the other travels in hue, and the endcap bridges between them at half that travel, floored so it can never collapse into the bar. Depth is fixed per role, so hue does the differentiating and lightness does the cohering.

**Relationship** is a signed hue travel — warm in one direction, cool in the other: `mono` (no travel) · `wheat` · `amber` · `ember` · `coral` (increasingly warm) · `mint` · `sage` · `teal` (increasingly cool).

**Placement** (`--place`) picks which large area the seed anchors: `bar` or `tabs`. There is also `cap`, an accent-led minority where the seed lands on the endcap and the bar is solved backwards from it.

**Mode** (`--mode`) is whether the anchored role wears your seed *exactly* (`literal`) or uses it as a basis with lightness and chroma normalised (`derived`).

```fish
tmux-lives setup theme                      # the picker (M-k / M-m k do the same)
tmux-lives setup theme list                 # every catalog scheme as a 7-swatch strip
tmux-lives setup theme amber --place tabs --mode literal
tmux-lives setup theme off                  # legacy look: derived bar, neutral cap
```

The picker works from a **catalog** of 35 named recipes. Each name is a relationship plus a tier that encodes the placement and mode: `soft` (bar, derived) · `glow` (bar, literal) · `slate` (tabs, derived) · `chip` (tabs, literal) · `deep` (cap, derived) · `core` (cap, literal). So `amber chip` is amber travel, anchored at the tabs, wearing your seed verbatim.

Seven roles get colours — `bar`, `sep`, `tabs`, `active`, `windows`, `cap`, `text`. ShellFish and iTerm2 tabs wear the `tabs` role. All are live `@options` (`@tmux_lives_sep_fg`, `@tmux_lives_text_fg`, …), so `tmux set -g @tmux_lives_… '#hex'` retunes one without re-rendering anything; the `windows` colour rides `status-style fg`.

**A known limitation, stated plainly:** the four supporting roles (`sep`, `active`, `windows`, `text`) currently derive from the bar alone and ignore the endcap entirely. A scheme therefore moves the bar/tabs/cap trio far more than it moves the trim — across all 35 catalog rows, six of the seven roles resolve to only 11 distinct values. Redesigning that derivation is planned; until then, expect schemes to differ mainly in the large areas.

#### The picker

`setup theme` with no arguments, `M-k`, or `M-m k` all open it. It shows a ShellFish tab chip when a ShellFish client is attached, a live preview of your bar, and a permanent seed section above the scheme list. **The popup's height adapts to your terminal** — it opens at 85% of your client's height rather than a fixed size, because a popup taller than the client refuses to open at all on tmux 3.3a rather than clamping to fit. So how many schemes you can see without scrolling depends on how tall your terminal is and whether you're editing the seed — a 62-row client gets a 52-row popup (85% of 62, floored), which shows roughly 35 schemes while browsing and 30 while editing; a short window just scrolls more, and a client under 30 rows won't open the picker at all (measured: 29 rows yields a 24-row popup and is refused, 30 rows yields 25 and is admitted).

Each row is a swatch strip, one colored cell per role, ordered by how much of your actual screen that role covers rather than by the engine's internal palette order: `tabs` gets the widest cells because it covers roughly 1.8x the area of `bar` on a real ShellFish client, then `bar`, then `cap`; a blank column marks the boundary before the four trim roles — `windows`, `sep`, `text`, `active` — that get one cell each. The selected row's marker is a left-half block (`▌`), not a right-half one — same width and height, but because the frame's own `│` inks the centre of its cell, the left-half glyph leaves half a column clear on **both** sides of the marker instead of crowding the first swatch.

The seed section is 4 rows while you're browsing and grows to 9 while you're editing it. Press `b` to enter edit mode: `↑↓` pick the R/G/B channel, `←→` move it by ±8, `⏎` keeps the change and leaves edit mode, `esc` leaves edit mode **without closing the picker** and puts the seed back to what it was when you pressed `b`. The scheme list below shifts when you toggle `b`, since the taller editor eats into it — a deliberate trade for a roomier editor over a list that never moves. Outside edit mode, `↑↓`/`←→` steer the scheme list instead, and `⇥` is ignored while you're editing. From edit mode, `t` opens a typed-hex entry screen with its own border (the picker popup itself has none, so an unframed screen used to float on your scrollback); `esc`/`⏎` there return you to edit mode rather than out of the picker.

Moving a channel redraws only the seed zone — the slider bar and the hex/hue/L/C readouts — and costs nothing else; the scheme strips and the `current` row stay on the old seed while you're actively adjusting. About 700ms after the last channel keypress, the whole batch (every visible strip plus the `current` row) regenerates in one pass — a full batch is 310-800ms depending on whether 14 or 35 rows are visible, too slow to pay on every keystroke, so it waits for you to actually stop rather than paying that cost on each press.

The keys are:

`↑↓` move · `⇞⇟` page · `b` edit seed · `m` curated · `z` shake · `⇥` current/off · `a` apply · `⏎` save · `esc` close.

`a` applies a scheme live without saving it, so you can audition; `⏎` commits. Outside edit mode, `esc` reverts whatever you were previewing — including an uncommitted seed change — and closes. A seed edit never reaches the real bar on its own: dragging a channel only ever updates the picker's own scheme strips (after the ~700ms pause above), and only an explicit `a` or `⏎` counts as adoption — configuration stays private until you ask for it. A ShellFish/iTerm2 tab's colour updates the moment you preview or revert, rather than lagging behind the ~15-second status-bar tick in either direction.

The list opens on the full 35-entry catalog; a `More Schemes` header still marks where the curated 14 (5 bar-placed, 7 tabs-placed, 2 cap-placed) end and the other 21 begin, so you can always see which rows are curated. **`m` now collapses the list down to just the curated 14** rather than expanding it — press it again to bring the rest back. `z` jumps to a random row anywhere in the full catalog, expanding first if you'd collapsed.

Your current theme and the `off` entry live in a second, untitled list at the bottom, reached with `⇥`. The current row is a live readout: its label is highlighted only while the theme you have saved is genuinely what is on the bar. Select it and press `a` to flip back to it for comparison against whatever you are auditioning.

#### Retired settings

`--vividness`, `--shape`, `--ease` and `--contrast` were accepted, stored and displayed for several versions but never affected the output — verified byte-identical across every catalog row at every value. They now error, and `fisher update` erases the stored values with a one-line notice. `--rotate` went with the v4 engine (`--place` replaced it); `--polarity` and `--range` went before that. Old `cap`-engine settings migrate automatically on update.

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
