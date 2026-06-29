# Design — tmux status bar color derived from the ShellFish color

**Date:** 2026-06-29
**Status:** Designed (awaiting user review → writing-plans)
**Builds on:** the shipped ShellFish bar-color feature (`2026-06-27-shellfish-barcolor-design.md`, `setup color`).

## Summary

Extend `tmux-lives setup color <css>` so it also colors the **tmux status bar** with a shade *derived* from the ShellFish color — lighter by default, darker with `-i`/`--invert`. The status bar is a single global tmux option (`status-style`), so every client (ShellFish and plain terminals alike) sees the server's color identity, while the ShellFish *tab* keeps the pure per-client color. The status bar is currently the tmux **default** (`bg=green`) and is set by nothing in the user's config — so claiming it is conflict-free.

## Goals

1. One knob: `tmux-lives setup color <css>` drives both the per-client ShellFish tab color (existing) and the global status-bar shade (new), keeping them in sync from a single source of truth.
2. The status shade is a *related but distinct* color: the ShellFish color lightened 25% toward white (default), or darkened 25% (`-i`).
3. Status **text** stays readable: its fg auto-contrasts (black/white) to the derived bar by luminance.
4. Graceful and safe: works for hex / `rgb()` colors; for colors we can't parse to RGB, the tab color still works and the status bar is left untouched. Clearing the color restores the tmux default bar.

## Non-goals

- Per-client status bars (impossible — `status-style` is one global server option).
- Restyling `window-status` / `status-left` / `status-right` segments (only the overall bar `status-style` bg+fg). A later increment could tune the current-window highlight.
- Named-color (`red`) or `color(p3 …)` / `hsl()` derivation (graceful skip; can add a small named→hex lookup later if wanted).

## The formula (chosen via visual companion 2026-06-29)

Per RGB channel `c` (0–255), derive the status `bg`:

- **Default (lighter):** `c' = round(c + (255 − c) × 0.25)`
- **`-i` / `--invert` (darker):** `c' = round(c × 0.75)`

Emit `bg` as `#rrggbb`. Choose the status **fg** by luminance of the derived bar:

- `L = (0.299·r + 0.587·g + 0.114·b) / 255`
- `fg = black` if `L > 0.55`, else `fg = white` (tmux-native named colors).

So a light derived bar gets black text; a dark one gets white — and `-i` (darker bar) naturally flips the text light, which is the intended "switches around" behavior.

## Input parsing (color → RGB)

`__tmux_lives_derive_status` accepts the same value `setup color` already stores and parses:

- `#rrggbb` → the three byte pairs.
- `#rgb` → expand each nibble (`#19f` → `#1199ff`).
- `rgb(r, g, b)` (and `rgba(...)`, alpha ignored) → the three integers, clamped 0–255.
- Anything else (named, `color(p3 …)`, `hsl(…)`, empty) → **unparseable** → the helper echoes nothing; the fragment omits the `status-style` line entirely (bar stays at tmux default).

(`setup color`'s existing charset validation already rejects shell-dangerous input before this point.)

## Command surface

`tmux-lives setup color [<css>] [-i|--invert]` (and the hidden top-level `tmux-lives color …`):

- `setup color` (no args) → print the current color **and** direction, e.g. `bar color: #1f6feb (status bar: lighter)` / `... (status bar: darker)` / `bar color: (none)`.
- `setup color <css>` → set color, direction = **lighter** (invert off).
- `setup color <css> -i` → set color, direction = **darker** (invert on).
- `setup color ""` → clear the color (and the status-style line); the bar returns to the tmux default.

Direction persists as a universal var `tmux_lives_status_invert` (`1`/`0`/unset), set every time a color is set. Re-run with or without `-i` to change direction (no separate toggle — keeps parsing predictable and testable).

## Architecture / components (zero new files)

All in `conf.d/tmux-lives-install.fish`:

- **`__tmux_lives_derive_status <color> <invert>`** — parse `<color>` to RGB; if unparseable, echo nothing and return. Else apply the lighter/darker formula (`<invert>` = `1` → darker), compute the contrast fg, and echo exactly `bg=#rrggbb,fg=black` or `bg=#rrggbb,fg=white`. Pure and total — the unit under test.
- **`__tmux_lives_render_fragment`** — gains a 5th arg `invert` (after `color`). After the existing `status-right` block, compute `set -l ss (__tmux_lives_derive_status $color $invert)` and, when non-empty, append `set -a f "set -g status-style $ss"`. (The line is omitted when no color is set or the color is unparseable, so the bar stays default.)
- **`__tmux_lives_write_fragment`** — passes `(__tmux_lives_key tmux_lives_status_invert 0)` as the new 5th arg, alongside the existing bar-color arg.
- **`__tmux_lives_color_cmd`** — parse argv into an optional color positional + the `-i`/`--invert` flag; on a set, store `tmux_lives_bar_color` (existing) and `set -U tmux_lives_status_invert` to the flag; re-render via `__tmux_lives_write_fragment` (existing). No-arg path prints color + direction. Charset validation unchanged.
- **`__tmux_lives_status_lines`** (`verify`) — the existing bar-color line gains the direction, e.g. `OK bar color: #1f6feb (status bar: lighter)`.
- **`__tmux_lives_setup_help_lines`** — the `color` row becomes `color [<css>] [-i]   ShellFish tab color (+ status bar; -i darker)` (kept ≤ the 80-col frame).

## Data flow

`setup color #1f6feb -i` → validate → `set -U tmux_lives_bar_color "#1f6feb"`, `set -U tmux_lives_status_invert 1` → `__tmux_lives_write_fragment` → `__tmux_lives_render_fragment … "#1f6feb" 1` → bakes the `client-attached` hook (existing) **and** `set -g status-style bg=#1753b0,fg=white` → `__tmux_lives_reload` sources it into the running server. (`#1f6feb` = `(31,111,235)`; ×0.75 = `(23,83,176)` = `#1753b0`, luminance ≈ 0.30 → `fg=white`; illustrative.)

## Testing strategy (extends `tests/test-tmux-install.fish`)

- **Formula (lighter):** `__tmux_lives_derive_status "#1f6feb" 0` → assert exact `bg=#…,fg=…` for the lightened value (hand-computed expected).
- **Formula (darker):** `__tmux_lives_derive_status "#1f6feb" 1` → assert the darkened `bg` + the flipped `fg`.
- **Short hex + rgb():** `#19f` and `rgb(31, 111, 235)` parse to the same result as their `#rrggbb` equivalents.
- **Contrast fg:** a light base (e.g. `#ffee88`) → `fg=black`; a dark base (e.g. `#102030`) → `fg=white`.
- **Unparseable → empty:** `__tmux_lives_derive_status "red" 0` and `"" 0` echo nothing.
- **Fragment integration:** `__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" 0` contains a `set -g status-style bg=#` line; with color `""` it contains **no** `status-style` line; the `client-attached` hook is still present in both.
- **Command:** `setup color "#1f6feb" -i` stores the color + `tmux_lives_status_invert=1` and the re-rendered fragment carries the darker `status-style`; `setup color "#1f6feb"` stores invert=0 and the lighter one; no-arg shows color + direction. (Reuse the Task-5 pattern: stub `__tmux_lives_write_fragment` to a temp path and **save/restore both** `tmux_lives_bar_color` and `tmux_lives_status_invert` so the suite never clobbers real universal vars.)
- **Help/verify:** `color` help row mentions `-i`; `verify` reports the direction; framed setup help stays ≤ 80 visible columns.

## Caveats

- Global option: with both a ShellFish and a plain client attached, the status bar (one value) is shared — by design it shows the server identity to both; only the *tab* color is per-client.
- Deployment unchanged: the line lands via `fisher update` (now auto-re-renders the fragment) or any `setup` action; a Claude session never deploys.
- Live-verify item: the actual rendered bar color + text contrast on a real terminal (the formula + contrast are unit-tested, but final look is a visual check).
