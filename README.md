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

After an update, other running fish shells (and tmux panes) re-source themselves
automatically — instantly if they're sitting idle at a prompt, or as soon as a shell busy
with something in the foreground (e.g. Claude) returns to one. You only need to run
`exec fish` yourself in a shell when: the update removed or renamed a function (sourcing
can't unset one that no longer exists), or this is the very first update that carries the
auto-reload feature itself (already-open shells don't have the handler installed yet to
pick it up). The update note tells you which, if either, applies.

### ShellFish/iTerm2 tab color & baseline

A `client-attached` hook colors ShellFish and iTerm2 tabs on attach — detected via `LC_TERMINAL` (`ShellFish` / `iTerm2`), the color escape goes straight to that client's tty and no one else's, while the title escape goes to every attached client regardless of terminal — and re-applies a baseline config for every other client. `setup color` also derives a global tmux **status bar** tint from the ShellFish color — lighter by default (`-i`/`--invert` for darker), visible to all clients; status text auto-tints to the bar color. `setup color --apply` (short `-a`) reapplies the currently-stored color to both surfaces — the client's tab OSC (ShellFish or iTerm2) and the tmux status bar — without retyping it (handy if a new tab came up without the color).

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

A theme is your **seed** color (set with `setup color`) plus a catalog **scheme** — a named recipe of five fields that turns your one seed hue into all seven bar colors.

**Harmony mode** sets how many hue families the palette uses and how they're spaced, always anchored on the seed's own hue: `mono` (one hue) · `analogous` (three hues, ±30°) · `complementary` (two hues, 180° apart) · `split` (three hues: the direct hue plus both neighbors of its complement) · `triadic` (three hues, 120° apart) · `tetradic` (four hues, two complementary pairs) · `square` (four hues, 90° apart).

The other three recipe fields shape the value ramp those hues get painted onto: **lightness span** is how wide a lightness window the seven roles spread across, centered on the seed's own lightness; **peak chroma** is how saturated the most vivid point on that ramp gets; **peak position** is where in the window the chroma peaks (0 = the ramp's darkest end, 1 = its lightest). **Arrangement** is one of six fixed patterns — `deep` · `bright` · `centre` · `split` · `stack` · `accent` — that decide which point on the ramp lands on which of the seven roles (`bar sep tabs active windows cap text`); it only reorders colors, it never substitutes one.

```fish
tmux-lives setup theme                      # the picker (M-k / M-m k do the same)
tmux-lives setup theme list                 # every catalog scheme as a 7-swatch strip
tmux-lives setup theme 'mono deep'          # or unquoted: tmux-lives setup theme mono deep -- both work
tmux-lives setup theme off                  # legacy look: derived bar, neutral cap
```

The catalog is the complete 7-mode × 6-arrangement grid — 42 schemes, one recipe per cell — with 14 curated (two arrangements per mode, chosen so every mode and every arrangement is reachable from a cold open). The picker opens on all 42 and `m` collapses it to the 14. `--place`, `--mode` and `--phase` — the old flags for choosing where the seed anchored — are gone: a scheme's recipe already encodes that choice, so all three now just error and point you at `setup theme list`.

Seven roles get colors — `bar`, `sep`, `tabs`, `active`, `windows`, `cap`, `text`. ShellFish and iTerm2 tabs wear the `tabs` role. Six are live `@options` (`@tmux_lives_sep_fg`, `@tmux_lives_text_fg`, …), so `tmux set -g @tmux_lives_… '#hex'` retunes one without re-rendering anything; `windows` rides `status-style fg` directly rather than its own option.

#### The picker

`setup theme` with no arguments, `M-k`, or `M-m k` all open it. It shows a ShellFish tab chip when a ShellFish client is attached, a live preview of your bar, and a permanent seed section above the scheme list. **The popup's height adapts to your terminal** — it opens at 85% of your client's height rather than a fixed size, because a popup taller than the client refuses to open at all on tmux 3.3a rather than clamping to fit. So how many schemes you can see without scrolling depends on how tall your terminal is and whether you're editing the seed — a 62-row client gets a 52-row popup (85% of 62, floored), which shows roughly 35 schemes while browsing and 30 while editing; a short window just scrolls more, and a client under 30 rows won't open the picker at all (measured: 29 rows yields a 24-row popup and is refused, 30 rows yields 25 and is admitted).

Each row is a swatch strip, one colored cell per role, ordered by how much of your actual screen that role covers rather than by the engine's internal palette order: `tabs` gets the widest cells because it covers roughly 1.8x the area of `bar` on a real ShellFish client, then `bar`, then `cap`; a blank column marks the boundary before the four trim roles — `windows`, `sep`, `text`, `active` — that get one cell each. Press `o` to toggle sorting the list by color instead of catalog order. The selected row's marker is a left-half block (`▌`), not a right-half one — same width and height, but because the frame's own `│` inks the centre of its cell, the left-half glyph leaves half a column clear on **both** sides of the marker instead of crowding the first swatch.

The seed section is 4 rows while you're browsing and grows to 9 while you're editing it. Press `b` to enter edit mode: `↑↓` pick the R/G/B channel, `←→` move it by ±8 — a channel move only ever updates the seed shown in the color block, never a scheme strip. `a` rebuilds the scheme strips from the seed now showing and stays in the editor ("show me what this seed does"); `⏎` does the same rebuild and also leaves edit mode ("this is the seed — apply it and let me out"). `esc` leaves edit mode **without closing the picker** and puts the seed back to what it was when you pressed `b`. The scheme list below shifts when you toggle `b`, since the taller editor eats into it — a deliberate trade for a roomier editor over a list that never moves. Outside edit mode, `↑↓`/`←→` steer the scheme list instead, and `⇥` is ignored while you're editing. From edit mode, `t` opens a typed-hex entry screen with its own border (the picker popup itself has none, so an unframed screen used to float on your scrollback); `esc`/`⏎` there return you to edit mode rather than out of the picker.

Moving a channel does not redraw only the seed zone — every keypress still rebuilds the whole frame — but the scheme strips and the `current` row are served from a row cache and stay on the pre-edit seed the whole time you're dragging, so a slider move costs a frame redraw, not a re-render of every visible scheme. There is no recompute-after-a-pause any more — the cache is only rebuilt when you press `a` or `⏎`, never automatically.

The keys are:

`↑↓` move · `⇞⇟` page · `b` seed · `m` curated · `z` roll · `⇥` current/off · `a` apply · `⏎` save · `esc` close · `o` order · `M` mono.

`a` applies a scheme live without saving it, so you can audition; `⏎` commits. Outside edit mode, `esc` reverts whatever you were previewing — including an uncommitted seed change — and closes. A seed edit never reaches the real bar on its own: only an explicit `a` or `⏎` from the scheme list counts as adoption — configuration stays private until you ask for it. A ShellFish/iTerm2 tab's colour updates the moment you preview or revert, rather than lagging behind the ~15-second status-bar tick in either direction.

The list opens on the full 42-entry catalog. `m` collapses it down to just the curated 14 — press it again to bring the rest back. `M` swaps the whole list for a mono-only 36-row grid (the six mono catalog recipes crossed with all six arrangements); `m` is inert while `M` is on. `z` rolls a genuine recipe sampled from the measured-acceptable part of the full v6 space — not a catalog row at all — and pushes it into a session-local, 12-deep roll history; `⇥` cycles focus between the scheme list, the current/off list, and (once you've rolled at least once) that roll history, and `↑↓` steps back through past rolls while it has focus.

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
