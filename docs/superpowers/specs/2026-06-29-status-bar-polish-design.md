# Design — status bar polish + general user config file

**Date:** 2026-06-29
**Status:** Designed (awaiting user review → writing-plans)
**Builds on:** the shipped ShellFish bar-color + status-style feature (`setup color`, `__tmux_lives_derive_status`).

## Summary

Three coupled improvements to the tmux-lives status bar:

1. **Tinted status text** — replace the palette-dependent named `white`/`black` status fg (which renders as "tan" in warm terminal palettes) with a **true-hex tinted shade of the bar's own hue** (lighter/darker by luminance, blended 68% toward white/black). Visible hue, still clearly light/dark, palette-independent.
2. **A general user config file** — promote `~/.tmux-lives.conf` from a non-ShellFish-only baseline to the **general tmux-lives customization file**: sourced by the fragment **at load** (applies to every client) *and* still re-sourced on non-ShellFish attach. TL seeds it with active status-bar polish; the user owns it thereafter.
3. **Status-bar content polish** (seeded into that file) — longer names, a clean `status-left`, a `status-right` with 12-hour / month-first time and no pane-title spinner cruft, and a highlighted current window.

Plus a **`setup conf reset`** command to restore the TL defaults (backing up the user's version first).

## Goals

- Status text is readable and palette-independent on any configured bar color, with a visible hue tint (the "Light tint" the user chose).
- One user-owned, TL-seeded file holds the editable status-bar (and other) customizations, applied to both client types; the user can edit it and restore defaults.
- The categorize `tick`, the color-derived `status-style`, and continuum's autosave hook all keep working unchanged.

## Non-goals

- Per-segment theming beyond status-left / status-right / window-status-current (YAGNI).
- Making every status option a `setup` flag — the file IS the config surface.
- Re-rendering the user's status content on every TL update — seed-once, user-owned (TL won't auto-push status tweaks).

## Part A — Tinted status text (`__tmux_lives_derive_status`)

The fg changes from named `white`/`black` to a **hex tint of the derived bar color**, blended toward white (dark bar) or black (light bar) by `f = 0.68`:

- Compute integer luminance of the *derived bar* `L = round(0.299r + 0.587g + 0.114b)`.
- **Dark bar** (`L ≤ 140`): `fg_c = round(c + (255 − c) × 0.68)` per channel.
- **Light bar** (`L > 140`): `fg_c = round(c × 0.32)` per channel.
- Emit `bg=#rrggbb,fg=#rrggbb` (both true hex).

**Verified reference vectors** (used as test expectations):

| input | invert | output |
|---|---|---|
| `#1f6feb` | 0 | `bg=#5793f0,fg=#c9dcfa` |
| `#1f6feb` | 1 | `bg=#1753b0,fg=#b5c8e6` |
| `#ffee88` | 0 | `bg=#fff2a6,fg=#524d35` |
| `#102030` | 0 | `bg=#4c5864,fg=#c6cacd` |
| `#87af00` (user) | 1 | `bg=#658300,fg=#ced7ad` |

Unparseable/empty input still echoes nothing (status-style omitted). This is the only change to Part A — the bar derivation, parsing, and `setup color [-i]` are unchanged.

## Part B — `~/.tmux-lives.conf` as the general config file

### Sourcing

The managed fragment, at load, **sources `~/.tmux-lives.conf` if it exists** (guarded: `if-shell '[ -f ~/.tmux-lives.conf ]' 'source-file ~/.tmux-lives.conf'`). The existing non-ShellFish-attach re-source (`__tcz_on_attach` baseline branch) is unchanged. So the file applies to every client at load and re-asserts on non-ShellFish attach.

### The `status-right` layering problem and the `@`-var fix

`status-right` is composed from three contributors: continuum's `#(continuum_save.sh)` (prepended when TPM runs), TL's `#(… tick)`, and the user's visible content. A re-source of the general file on non-ShellFish attach must **not** wipe the tick/continuum. So the user does **not** set `status-right` directly; instead the file sets a tmux user option:

```tmux
set -g @tmux_lives_status_right "%-I:%M %p · %b %-d "
```

and the **fragment** wires it once, wrapping the var ref in the **`T:` (strftime) modifier**:

```tmux
set -g status-right "#{T:@tmux_lives_status_right}#(fish --no-config <cat> tick)"
```

**The `T:` is required** (verified empirically): a bare `#{@tmux_lives_status_right}` interpolates the var *after* the status bar's strftime pass, so `%-I` etc. would render literally; `#{T:@var}` applies strftime directly to the var's value, so the time expands. tmux re-evaluates this on every refresh, so editing the var (or re-sourcing the file) updates the visible time live (verified: changing the var → render shows the new time), while the tick stays attached and continuum still prepends its save (the file never sets `status-right` itself, so a re-source can't wipe them). The fragment also sets a **default** `@tmux_lives_status_right` (`"%-I:%M %p · %b %-d "`) before sourcing the file, so a missing/empty file still yields a sensible status-right (never blank). This replaces the current guarded `set -ga status-right "#(… tick)"` append (which also drops the tmux-default `pane_title` spinner cruft — desired).

`status-left`, the lengths, and the window-status styles have no such layering, so the file sets them **directly** (re-source-safe, idempotent).

## Part C — Seeded status-bar polish

`__tmux_lives_seed_baseline` seeds the file (when absent) with **active** polish + a commented non-ShellFish-baseline section:

```tmux
# ~/.tmux-lives.conf — your general tmux-lives config.
# Sourced when tmux-lives loads (every client) and re-applied when a NON-ShellFish
# client attaches. Edit freely; `tmux-lives setup conf reset` restores these defaults.

# --- status bar ---
set -g status-left " ❯ #{session_name} "
set -g status-left-length 40
set -g status-right-length 60
# status-right content goes through this var so tmux-lives can keep the categorize
# tick + continuum autosave attached (it sets the actual status-right). 12h, month-first:
set -g @tmux_lives_status_right "%-I:%M %p · %b %-d "
# make the active window stand out
set -g window-status-format         " #I:#W "
set -g window-status-current-format " #I:#W "
set -g window-status-current-style  "bold"

# --- non-ShellFish baseline (re-applied when a non-ShellFish client attaches) ---
# Settings ShellFish's integration forces that you want undone for other clients.
# Example:
# set -g mouse off
```

(`window-status-current-style "bold"` reads against the colored bar; it does not set a fg color, so it inherits the bar's text styling.)

## Part D — `setup conf reset`

`tmux-lives setup conf reset` restores the TL defaults non-destructively:

1. If `~/.tmux-lives.conf` exists, copy it to `~/.tmux-lives.conf.bak`.
2. Write the seed template (force — the same content `__tmux_lives_seed_baseline` would seed).
3. `tmux source-file` it live (if a server is running) and report: `restored defaults; previous version saved to ~/.tmux-lives.conf.bak`.

Honors the `tmux_lives_baseline_conf` test seam (backup path = `<seam>.bak`). Joins the existing `setup conf` / `conf edit` / `conf add`; the help row updates to `conf [edit|add <cmd>|reset]`.

## Components (zero new files)

- `conf.d/tmux-lives-install.fish`
  - `__tmux_lives_derive_status` — tinted hex fg (Part A).
  - `__tmux_lives_render_fragment` — source `~/.tmux-lives.conf` (guarded) at load; set default `@tmux_lives_status_right`; set `status-right "#{@tmux_lives_status_right}#(… tick)"` (replaces the old guarded append).
  - `__tmux_lives_seed_baseline` — the new active-polish template (Part C).
  - `__tmux_lives_conf_cmd` — add `reset` (Part D) + help row.
- No categorizer change (the `on-attach` non-ShellFish branch already re-sources the file).
- Docs: README + CLAUDE.md.

## Testing

- **Tinted fg** (`tests/test-tmux-install.fish`): update the existing derive assertions to the Part-A reference vectors; add the user-color cases.
- **Fragment**: contains `source-file ~/.tmux-lives.conf` (guarded); `status-right` references `#{T:@tmux_lives_status_right}` (with the `T:` modifier) and the tick; a default `@tmux_lives_status_right` is set; the old `pane_title` append is gone. Smoke (live tmux socket): rendered fragment `source-file` rc=0; `#{T;=/60:status-right}` renders the expanded time (strftime verified) with the tick token preserved.
- **Seed**: the seeded file contains the active polish (`@tmux_lives_status_right`, `status-left`, `window-status-current-style`) and the commented mouse example; seed is still idempotent (never overwrites an existing file).
- **`conf reset`**: with the `tmux_lives_baseline_conf` seam → edits a temp file, `reset` writes the template back and leaves a `.bak` with the prior contents; rc 0.
- **Help/verify**: `conf` help row shows `reset`; framed `setup -h` ≤ 80 visible columns.

## Caveats / live-verify

- **Layered `status-right`**: final string is `#(continuum_save)` + `#{T:@tmux_lives_status_right}` + `#(tick)`. The strftime expansion and var re-evaluation are verified; the continuum prepend and the tick render no visible text — the live-verify is just that autosave + categorize still fire on a real attach.
- **Existing `~/.tmux-lives.conf`**: a user with the *old* commented-only file won't get the active polish until `setup conf reset` (the fragment's default `@tmux_lives_status_right` still gives them a sensible time; status-left/lengths/window-current fall back to tmux defaults until reset). Documented.
- **Contrast on mid-tone bars**: the Light tint (f=0.68) on a medium bar (e.g. the user's `#658300` → `#ced7ad`, ~2.9:1) is below the 4.5:1 WCAG mark — an accepted, user-chosen tradeoff for the tinted look.
- Deployment is the user's `fisher update` (auto-re-renders the fragment) + a one-time `setup conf reset` if they already have an old baseline file; a Claude session never deploys.
