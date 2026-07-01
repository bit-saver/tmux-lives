# Design — in-tmux modal redesign (launcher + resize mode)

**Date:** 2026-06-30
**Status:** Designed (awaiting user review → writing-plans)
**Builds on / supersedes the interactive parts of:** Feature 2 (`__tcz_modal*`, shipped in cce47a7..d1bcc3d). The colored preview, scratch toggle, `setup color` normalize/recolor, and the `M-t`/`M-s` binds stay; this redesigns the **command modal** and adds a **scratch resize mode**.

## Why (root cause from live use)

The shipped `M-m` modal is a fish `display-popup` that draws a legend and **loops**, reading keys and acting while it stays open. In practice its keypresses "don't work" — but the reader is fine (verified: keys are received). The real fault is that its actions can't work from inside a popup overlay:

- **`s` (switcher) is silently dead** — it tries to open a `display-popup` while the modal popup is already open, and **tmux rejects popup-in-popup** (verified: the inner popup does not run, no error).
- **`categorize` / `clear`** produce no visible feedback.
- **`scratch` toggle** creates the split *behind* the popup — invisible until it closes.
- **`new` / `switcher`** just dismiss the popup, feeling like nothing happened.

So the popup-that-stays-open is the wrong shape for a command launcher. This redesign makes it a **single-shot launcher** (pick → close → act, visibly) and moves live scratch resizing to a **native key-table mode** where the panes stay visible.

## Goals

- Every command reachable from `M-m` produces a visible, correct result.
- The picker (renamed from "switcher") opens reliably from the launcher.
- Live scratch resize/orient works while watching the panes.
- The launcher looks polished (user-approved design B) and doubles as a keybind cheatsheet.
- No test touches the user's live tmux server (the project's hard isolation invariant).

## Non-goals (YAGNI)

- Keeping the modal open to chain multiple commands (the single-shot model is deliberate).
- A rich popup for the resize-mode key hints (a popup would re-capture keys and re-hide the panes — the exact bug being fixed); the resize hint is a status-line message.
- Renaming the internal `__tcz_open_switcher` / `__tcz_popup` functions (churn); only the **user-facing** label changes to "picker".

## Binds (all configurable via `setup keys`, `''` disables)

- `M-m` → launcher popup (`tmux_lives_modal_key`, existing)
- `M-t` → scratch toggle (`tmux_lives_scratch_key`, existing — unchanged)
- `M-r` → scratch resize mode (`tmux_lives_resize_key`, **new**, default `M-r`)
- `M-s` / `prefix S` → picker (existing binds; relabeled)

## Part A — Launcher popup (single-shot)

`__tcz_modal` is rewritten from a loop to **draw once, read one key, dispatch, exit**. It runs in `display-popup -E` as now. Flow: resolve the client (as today), `stty` raw, hide cursor, draw the legend once, read one keystroke via the existing `__tcz_modal_readkey`, map it with `__tcz_modal_action`, run the action, restore the tty, exit. No loop, no redraw, no stay/close bookkeeping.

Per-key behavior (the "close-then-run" mechanics — each avoids the popup-overlay traps):

- **`p` picker** — issue `tmux run-shell -b 'fish --no-config $cat open-switcher "$client"'`, then exit. The `-b` background run-shell fires *after* the launcher popup has closed, so the picker's `display-popup` is no longer nested. (`run-shell -b`-deferred popup opening is an existing pattern in this repo — `__tmux_lives_picker`'s outside-tmux path.)
- **`n` new · `c` clear · `g` categorize** — run the CLI verb via `fish -c 'tmux-lives <verb>'` (or the categorizer directly for categorize), emit a one-line status confirmation with `tmux display-message` (e.g. `tmux-lives: categorized` / `cleared N idle`), then exit. The confirmation is the visible feedback since the popup is gone.
- **`t` scratch toggle** — run `__tcz_scratch "$client"`, then exit → the split is visible once the popup closes.
- **`r` resize…** — enter the scratch resize mode (Part C) via `resize-enter`, then exit the popup; if no scratch exists it emits the same nudge as `M-r`. (So resize mode is reachable both from the launcher and directly via `M-r`.)
- **`b` bar color** — prompt for the CSS value *inside the popup* with the cooked read (restore cooked tty, `read -l`, restore), run `tmux-lives setup color <value>`, then exit. (No nested popup / no hidden effect — the status bar is visible after close. This reuses the color sub-state that already works.)
- **`esc` / `q`** — exit (no action).

Any unmapped key exits without acting (a launcher should not trap the user).

## Part B — Launcher aesthetic (approved: design B + two-column table footer)

A fish-drawn box (so the rich look is possible), rendered by `__tcz_modal_legend`:

```
╭─ tmux-lives ─────────────────╮
│ session ─────────────────── │
│   p picker    n new        │
│   c clear     g categorize │
│ scratch ─────────────────── │
│   t toggle    r resize…    │
│ config ──────────────────── │
│   b bar color              │
│ ─ keys ──────────────────── │
│  M-m menu     M-r resize    │
│  M-t scratch  M-s picker    │
│  esc close                  │
╰────────────────────────────╯
```

- Rounded border in muted orange; title `tmux-lives` in the top edge (orange).
- Category headers **session / scratch / config** as full-width rules colored orange / cyan / green (the switcher's category palette: 208 / cyan / green).
- Command keys in orange (256-color 208), labels in default fg.
- A `─ keys ─` rule, then a **two-column table** of the global binds with their functions — muted key + faint label, two pairs per row. The `r resize…` command entry (ellipsis) signals it enters a mode.
- The keys table reflects the *effective* binds (reads the configured `tmux_lives_modal_key` / `_scratch_key` / `_resize_key` / `_switcher_key`), so it stays accurate after `setup keys`.

`__tcz_modal_legend` stays a pure function (renders the ANSI box to stdout given the effective key names + whether a scratch exists — `r resize…` shown always, or dimmed when no scratch). Unit-tested headless like today.

## Part C — Scratch resize mode (`M-r`) — native key-table

Entered by the `M-r` bind; operates on the marked scratch pane with the panes fully visible.

- **Entry:** the `M-r` bind runs a categorizer subcommand `resize-enter <client>`: if `__tcz_scratch_pane` is non-empty → `tmux switch-client -c <client> -T tmuxlives-resize` and show the hint; else `tmux display-message 'tmux-lives: no scratch pane — <scratch-key> to create'`.
- **Key table** `tmuxlives-resize` (rendered into the managed fragment): `Up/Down/Left/Right` → resize the scratch (`resize-pane` on the marked pane) and **re-enter the table** (sticky); `h` → side-by-side orient; `w` → stacked orient (both via `__tcz_scratch_orient`); `x` → kill the scratch and exit; `Escape`/`Enter` → exit (return to root table) and clear the hint. Each resize/orient binding re-issues the hint.
- **Resize/orient helpers:** new thin categorizer verbs `scratch-resize <L|R|U|D>` (finds `__tcz_scratch_pane`, `resize-pane -t <id> -<dir> <step>`) and reuse `__tcz_scratch_orient`. Steps: 4 cols horizontal, 2 rows vertical (matching the shipped modal-run resize).
- **Hint:** a status-line message via `tmux display-message -d 0 '↔ resize · h/w split · x close · esc done'`, re-shown on each key (`-d 0` = until the next key). (Alternative if `-d 0` misbehaves on 3.3a: a temporary status-left segment set on enter and cleared on exit — decided in pre-flight.)

## Part D — Picker rename

User-facing "switcher" → "picker" wherever the user sees it: the launcher label + footer, the `display-menu` fallback labels, and the docs. The `p` launcher key and the existing `M-s` / `prefix S` binds open it. Internal function names (`__tcz_open_switcher`, `__tcz_popup`) are unchanged.

## Part E — display-menu fallback

When `display-popup` is unavailable, `__tcz_modal_menu` / `__tcz_modal_menu_args` remain the fallback and are updated: label "switcher" → "picker"; drop the in-modal resize entries (resize is `M-r`-only); a native `display-menu` already does close-then-run and can open the picker, so no nesting concern there.

## Part F — Config surface

`setup keys` gains `--resize-key <key>` (universal `tmux_lives_resize_key`, default `M-r`), baked into the fragment on render, `''` to disable — consistent with `--modal-key` / `--scratch-key`. `__tmux_lives_render_fragment` gains the `M-r` bind + the `tmuxlives-resize` key table, and passes the resize key through from `__tmux_lives_write_fragment`.

## Architecture / where things live

- `functions/tmux-categorize.fish`: rewrite `__tcz_modal` (single-shot launcher); redesign `__tcz_modal_legend` (design B + table footer, effective-key aware); simplify `__tcz_modal_action` (drop the in-popup arrow/orient/scratch-close tokens — live resize moves to the `M-r` key-table; keep `new clear categorize picker scratch resize color close noop`, where `resize` enters the mode); remove `__tcz_modal_run`'s loop role (fold dispatch into `__tcz_modal`, or keep a slimmer `__tcz_modal_run` for the non-picker actions); add `__tcz_resize_enter`, `__tcz_scratch_resize`; `resize-enter` / `scratch-resize` cases in `__tcz_main`; update `__tcz_modal_menu_args` labels.
- `conf.d/tmux-lives-install.fish`: `__tmux_lives_render_fragment` emits the `M-r` bind + the `tmuxlives-resize` key-table block; `__tmux_lives_write_fragment` resolves+passes `tmux_lives_resize_key`; `__tmux_lives_keys_cmd` gains `--resize-key`; `__tmux_lives_setup_help_lines` documents it.

## Testing & isolation (hard invariant)

- Pure helpers (`__tcz_modal_legend`, `__tcz_modal_action`) unit-tested headless in `tests/test-tmux-popup.fish` (assert design-B content: category headers, the table footer with effective binds, the picker label).
- `__tcz_scratch_resize` / `resize-enter` / `__tcz_scratch_orient` integration-tested against a throwaway `tmux -L` server via the PATH shim (like the shipped scratch tests) — assert the marked pane resizes / a no-scratch entry emits the nudge and does not switch key-tables.
- Fragment render assertions in `tests/test-tmux-install.fish`: the `M-r` bind, the `tmuxlives-resize` key-table lines, and the `--resize-key` flag; empty resize key ⇒ no such bind. Reuse the existing render-with-explicit-keys pattern.
- The single-shot `__tcz_modal` dispatch is source-asserted + its non-picker effects socket-tested (the raw-tty popup itself is runtime-verified, as with the switcher). Every server-mutating test uses the `-L` seam; the suite must leave the live fragment/server/universals untouched (guard against the write_fragment/post-update leak fixed in 5832b30).

## Pre-flight items for the plan (tmux 3.3a — validate before building)

- `run-shell -b 'fish … open-switcher'` issued from inside the launcher popup opens the picker **after** the launcher closes (no nesting). Fallback: a brief detach/re-open or a keybinding chain.
- The cooked `read` for `b` (bar color) inside `display-popup -E` (raw → cooked → raw).
- `switch-client -c <client> -T tmuxlives-resize` from a `run-shell`, the sticky re-enter pattern, and the `display-message -d 0` hint (vs a status-segment) on 3.3a.
- `new` / `picker` via `fish -c 'tmux-lives …'` / deferred open correctly switch the underlying client from the popup.
- Collision-free default for `M-r`.
