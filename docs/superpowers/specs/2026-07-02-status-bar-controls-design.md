# Design — status-bar controls (position/visibility toggles + color apply)

**Date:** 2026-07-02
**Status:** Designed (awaiting user review → writing-plans)
**Builds on:** the ShellFish bar-color + status-style feature (`setup color`, `__tcz_recolor`, `__tmux_lives_derive_status`) and the managed-fragment / `~/.tmux-lives.conf` config surfaces.

## Why

Two independent, related asks about the status bar:

1. **Runtime toggles for status-bar position and visibility, persisted.** The user wants `Ctrl+Opt+A` to flip the status bar between top and bottom and `Ctrl+Opt+S` to hide/show it, and the chosen value must survive into every session — including a fresh tmux server after a reboot. tmux options don't persist across server restarts on their own, so a persisted value must be reapplied on load.
2. **A manual "apply" for the stored bar color.** After a ShellFish `Cmd+T` (new tab, same host/dir) the per-server toolbar color sometimes isn't reapplied. Root-causing that reliably needs the iPad and is deferred. Independent of the fix, the user wants an easy command that re-applies the *currently stored* color to both surfaces (the ShellFish toolbar OSC and the tmux `status-style`) without retyping it.

## Goals

- One global status-position (top/bottom) and one global status visibility (on/off), toggled by keys, persisted across server restarts, reapplied on every load.
- A one-shot `setup color --apply` that reapplies the stored color live to both the ShellFish toolbar and the tmux status bar, with no persistence change and no full re-render/reload.
- Zero test touches the live tmux server / fragment / universals (the project's hard isolation invariant).

## Non-goals (YAGNI)

- Per-session status position/visibility (this is one global value; "reapplied for every session" = a single shared value). Confirmed with the user.
- Re-rendering the whole managed fragment on every toggle (a toggle is a frequent runtime action; it stays cheap).
- Fixing the Cmd+T bar-color root cause here — that's deferred until the iPad diagnostic; `--apply` is the interim escape hatch and a reusable building block for the eventual fix.

## Part 1 — Status-bar position/visibility toggles (storage: a managed state file)

### State file

- Path: `~/.config/tmux/tmux-lives-state.conf` (machine-owned; **not** the user-authored `~/.tmux-lives.conf`).
- Contents: exactly two lines —
  ```
  set -g status-position <top|bottom>
  set -g status <on|off>
  ```
- It does not exist until the first toggle. Before any toggle, tmux's defaults (bottom / on) apply.
- Test seam: `tmux_lives_state_file` overrides the path (like `tmux_lives_fragment_file` / `tmux_lives_baseline_conf`).

### Reapplied on load

`__tmux_lives_render_fragment` emits, near the end of its status setup:
```
if-shell '[ -f <state> ]' 'source-file <state>'
```
Placed **after** the fragment's own status options so the persisted values win. The rendered `<state>` path is the resolved state-file path; `__tmux_lives_write_fragment` passes it through (or the render helper resolves it), and it carries a "keep in sync with the categorizer" comment (same discipline as the baseline path).

### Toggle verbs (categorizer)

The keybinds fire `run-shell 'fish --no-config <cat> <verb>'`, so the toggles are categorizer verbs:

- `status-pos-toggle` → `__tcz_status_pos_toggle`: read live `status-position` (`tmux show -gv status-position`), flip top↔bottom, `tmux set -g status-position <new>`, then rewrite the state file.
- `status-vis-toggle` → `__tcz_status_vis_toggle`: read live `status` (`tmux show -gv status`), flip on↔off, `tmux set -g status <new>`, then rewrite the state file.

Both call a shared `__tcz_write_state` helper that reads the **current live values of both** options and writes both lines, so the file always mirrors reality regardless of which key was pressed. `__tcz_write_state` resolves the path via the `tmux_lives_state_file` seam (default `$HOME/.config/tmux/tmux-lives-state.conf`), mirroring the install side. New `__tcz_main` cases: `status-pos-toggle`, `status-vis-toggle`.

### Keys (configurable, consistent with the existing binds)

- `setup keys --status-pos-key <k>` → universal `tmux_lives_status_pos_key`, default `C-M-a`, `''` disables.
- `setup keys --status-vis-key <k>` → universal `tmux_lives_status_vis_key`, default `C-M-s`, `''` disables.
- Baked into the fragment as `bind-key -n <key> run-shell 'fish --no-config <cat> status-pos-toggle'` (and `…-vis-toggle`), guarded by `test -n "$key"`, same as the scratch/resize binds. `C-M-s` (Ctrl+Opt+S) is distinct from the picker's `M-s` (Opt+s) — no collision.
- `__tmux_lives_setup_help_lines` documents both flags (kept within the 80-col framed page).

## Part 2 — `setup color --apply` (short `-a`)

`__tmux_lives_color_cmd` gains an `--apply` / `-a` mode:

- Resolve the stored color (`tmux_lives_bar_color`). If unset/empty → print a short notice (`tmux-lives: no bar color set`) and return without acting.
- Reapply live to both surfaces, no persistence change, no fragment re-render/reload:
  - **tmux status bar:** `tmux set -g status-style (__tmux_lives_derive_status $color $invert)` (invert from `tmux_lives_status_invert`), matching what the fragment bakes.
  - **ShellFish toolbar:** shell out to the categorizer `recolor` verb (`__tcz_recolor $color`), which emits the `settoolbar` OSC to every attached ShellFish client — the same path `setup color <css>` already uses.
- `--apply` takes no color argument; it is mutually exclusive with a positional `<css>` (passing both is an error). `-i`/`--invert` is unaffected.
- Hidden top-level shortcut already routes `color`, so `tmux-lives color --apply` works too.

## Architecture / where things live

- `functions/tmux-categorize.fish`: add `__tcz_status_pos_toggle`, `__tcz_status_vis_toggle`, `__tcz_write_state` (state-path seam); dispatch `status-pos-toggle` / `status-vis-toggle` in `__tcz_main`.
- `conf.d/tmux-lives-install.fish`:
  - `__tmux_lives_render_fragment`: emit the two toggle binds (guarded) + the `if-shell … source-file <state>` line; gains the state key args.
  - `__tmux_lives_write_fragment`: resolve + pass the two key universals and the state path.
  - `__tmux_lives_state_path`: new helper (honors `tmux_lives_state_file`, default `$HOME/.config/tmux/tmux-lives-state.conf`).
  - `__tmux_lives_keys_cmd`: `--status-pos-key` / `--status-vis-key` cases.
  - `__tmux_lives_setup_help_lines`: document both flags.
  - `__tmux_lives_color_cmd`: the `--apply` / `-a` mode.

## Testing & isolation (hard invariant)

- Toggle verbs are integration-tested against a throwaway `-L` server via the PATH shim (like the scratch tests): press-equivalent call flips the live option and writes the state file to a `tmux_lives_state_file` temp path; assert the option value and the file contents. The suite must never touch the real server/state file.
- Fragment render assertions (`tests/test-tmux-install.fish`): the two guarded toggle binds, the `if-shell … source-file <state>` line, empty-key ⇒ no bind; `--status-pos-key` / `--status-vis-key` persist their universals (stub `__tmux_lives_write_fragment`, save/restore the universals).
- `setup color --apply`: stub `__tmux_lives_write_fragment`, stub/guard the categorizer shell-out, drive `status-style` through the `-L` socket seam or assert the derived value; save/restore `tmux_lives_bar_color` / `tmux_lives_status_invert`; assert the no-color-set notice path. No live mutation.

## Pre-flight items for the plan (tmux 3.3a — validate before building)

- `bind-key -n C-M-a` / `C-M-s` parse and fire (Ctrl+Opt syntax).
- `show -gv status-position` returns `top`/`bottom`; `set -g status-position top` works.
- `show -gv status` returns `on`/`off` (not `1`/`0`); `set -g status off` works.
- `if-shell '[ -f … ]' 'source-file …'` for the state file, sourced after the fragment's status setup, overrides correctly.
- `set -g status-style` applied live by `--apply` takes effect without a reload.
