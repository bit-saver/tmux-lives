# Design — Feature 2: drive tmux-lives from inside tmux

**Date:** 2026-06-30
**Status:** Designed (awaiting user review → writing-plans)
**Builds on:** the shipped popup switcher (`__tcz_popup` and the `__tcz_popup_*` render helpers), the `display-menu` fallback (`__tcz_menu` / `__tcz_menu_args`), the managed-fragment renderer (`__tmux_lives_render_fragment`), and the `setup keys` configurable-bind model.

## Summary

When a tmux pane runs Claude Code (or any full-screen TUI), the shell underneath is not at a prompt, so `tmux-lives <verb>` can't be typed. Feature 2 makes the daily tmux-lives actions reachable from inside any pane via tmux key bindings, and adds a throwaway "scratch" shell beside the busy pane. Three components, built in this order:

1. **Colored popup preview** — the switcher's right-pane preview shows the target session's real colors (warm-up; self-contained).
2. **In-tmux command modal** — a key-capturing `display-popup` that is the unified in-tmux command surface: a colored legend, single-key actions, no prefix and no key-collision problem. `display-menu` becomes its no-popup fallback. Plus a couple of dedicated top-level binds for the highest-use actions.
3. **Claude scratch split** — a one-key toggle that splits a shell beside the active pane (marked on creation) and, pressed again, removes it and refocuses the original pane. Managed from the modal (resize / orientation / close).

All code lands in `functions/tmux-categorize.fish` (the existing modal/popup/menu home) plus wiring in the managed fragment (`conf.d/tmux-lives-install.fish`). Zero new files (one-file-per-feature convention).

## Goals

- Every daily tmux-lives action is reachable while a pane is busy with a full-screen program, with no prefix-key scarcity or collision worries (single keys live inside the modal).
- The switcher preview is color-faithful, matching the native `choose-tree` preview, without breaking the existing column-aware truncation/clipping.
- A scratch shell is one key away beside Claude and one key away from gone, cleanly, without disturbing other panes.
- The bind keys are configurable through `setup keys` (universal vars baked into the fragment), consistent with the existing prefix/switcher binds. The user owns aliasing/config; nothing is hand-edited.
- The full suite stays green with zero stderr and never mutates the user's live tmux server.

## Non-goals (YAGNI)

- Exposing shell-mutating verbs (`fix`, `update`) in the modal — `fix` mutates the calling shell's environment and `update` is interactive; both are shell-only by nature.
- A full theming/config UI in the modal — only `bar color` takes typed input; everything else is a fixed single-key action. Other config (`conf`, `keys`, `auto`) stays at the shell.
- Persisting scratch geometry or supporting multiple simultaneous scratch panes per window — one ephemeral scratch per window.
- Making the scratch split Claude-session-only — it is available in any window (the pane marking makes removal precise regardless).

## Part A — Colored popup preview

`__tcz_popup_preview` currently runs `tmux capture-pane -p` (strips all escapes → monochrome). The native picker shows color because tmux renders the live pane itself; the TL preview re-captures as text.

**Change:** capture with escapes and make the downstream render ANSI-aware.

- `__tcz_popup_preview`: `tmux capture-pane -p` → `tmux capture-pane -e -p` (`-e` includes SGR color/attribute escape sequences).
- `__tcz_popup_truncate` (documented today as "no ANSI in text"): becomes ANSI-aware. When measuring width and slicing character-by-character, treat `\e[…m` (and `\e]…` OSC) sequences as zero display columns and never cut in the middle of one. When it truncates, append a reset (`\e[0m`) before the `…` so an open color cannot bleed into the `│` divider or the next column.
- `__tcz_popup_clip`: its "drop trailing blank lines" test must strip SGR before calling `string trim`, so an escape-only line still counts as blank (preserves bottom-anchoring).
- Each emitted preview line ends with a reset so the divider and the following row start from a clean state.
- The left list pane (`__tcz_popup_list_lines`, our own ANSI) is unaffected; only the captured-preview path changes.

**Decision:** the truncation ellipsis `…` is **neutral** (reset emitted before it), not inheriting the last visible cell's color.

**Tests** (extend `tests/test-tmux-popup.fish`, which already has the `vis` SGR-stripper and `string length --visible`): feed `__tcz_popup_truncate` / `__tcz_popup_clip` fixtures containing embedded `\e[…m` sequences and assert (1) visible width is unchanged by the escapes, (2) no line is cut mid-escape, (3) every emitted line ends with a reset, (4) an escape-only line is treated as blank by the clip's trailing-blank trim.

## Part B — In-tmux command modal

A new subcommand renders a key-capturing modal in a `display-popup -E`, reusing `__tcz_popup_readkey` (raw-byte key reader) and the existing draw/synchronized-update approach.

**Dispatch:** add `modal` to `__tcz_main`; implement `__tcz_modal` plus render/handler helpers alongside the existing `__tcz_popup_*` family.

**Rendering:** a compact, colored legend box (rounded border, category/orange accents matching the switcher) listing the available single-key actions:

- `n` — new categorized session (closes modal, then `tmux-lives new`)
- `c` — clear idle sessions (`tmux-lives clear`; modal stays open, refreshes)
- `g` — re-categorize (`tmux-lives categorize`; stays open)
- `s` — open the switcher popup (closes modal, then the switcher)
- `t` — toggle the scratch split (see Part C; stays open if it can refresh)
- `b` — set the bar color (input sub-state, below)
- `esc` / `q` — close the modal

The modal **stays open after non-context-changing actions** (clear, categorize, scratch toggle/resize) so actions can be chained; **context-changing actions** (`new`, `switcher`) close the modal first, then run, since they switch the client/session.

**Bar-color input sub-state (`b`):** the modal switches its own input mode — restore a cooked tty line read, show a prompt line in the legend (`bar color (css) · esc cancels`), `read` a line with fish, run `tmux-lives setup color <value>` (sets the universal var + re-renders the fragment + reloads), then return to raw-key legend mode. The modal owns the input; no tmux `command-prompt` is needed. An empty line or Esc cancels. Because `setup color` now re-emits the ShellFish OSC immediately (Part E), the tab color updates live from the modal rather than waiting for the next attach.

**Dispatch mechanism:** actions shell out via `fish --no-config $__tcz_self <verb>` or issue `tmux` commands directly, the same pattern `__tcz_menu_args` already uses for the switcher.

**Fallback:** when `display-popup` is unavailable, `__tcz_menu` is extended to list these same actions, mirroring the popup-vs-menu branch already in `__tcz_open_switcher` (`if tmux list-commands … | grep -q display-popup`).

**Dedicated top-level binds:** the fragment binds an open-modal key and a scratch-toggle key at the root/prefix level (configurable — Part D), alongside the existing switcher key. These are the muscle-memory shortcuts for the highest-use actions; everything else lives in the modal.

**Tests:** the legend renderer and the key→action mapping are unit-tested headless (no real tmux), like the existing `__tcz_popup_*` helpers — assert the legend lists the expected keys and that each key dispatches the expected verb/command string. The `__tcz_menu` fallback gains the new entries (assert via the menu-args triples).

## Part C — Claude scratch split

A new `scratch` subcommand implementing a **toggle** against the current window:

- **Remove path:** if the window contains a pane with the user option `@tmux_lives_scratch` set to `1`, kill that pane and refocus the previously-active pane. tmux re-balances the layout automatically, so the original pane reclaims the space.
- **Create path:** otherwise `split-window` a shell beside the active pane, `set -p @tmux_lives_scratch 1` on the new pane, and focus it. The shell is tmux's `default-command` (falls back to the user's `$SHELL`).

**Defaults:** vertical split (side-by-side), ~33% width.

**Marking:** the `@tmux_lives_scratch` pane option is the sole source of truth for "which pane is the scratch," so removal is precise and independent of layout, focus, or how many other panes exist.

**Modal management (when a scratch exists):** inside the modal, arrow keys `resize-pane` the scratch, `h`/`w` swap its orientation (implemented by killing and re-splitting — acceptable because the scratch is ephemeral), and `x` closes it. Live redraw of the panes *behind* the popup during resize is validated in the plan's pre-flight; if tmux 3.3a does not redraw under an open popup, the resize still applies and is visible when the modal closes — not a blocker.

**Binding:** a dedicated top-level toggle key (Part D) and `t` in the modal.

**Tests:** integration-tested against a throwaway `tmux -L` server (socket seam / PATH shim): create → assert one marked pane exists and is focused; toggle again → assert the marked pane is gone and focus returned; a stray unmarked pane is never killed.

## Part D — Config surface (`setup keys`)

Extend `__tmux_lives_keys_cmd` / `setup keys` with `--modal-key` and `--scratch-key`, persisted as universal vars (e.g. `tmux_lives_modal_key`, `tmux_lives_scratch_key`) and baked into the fragment on every render — exactly the model used by `--prefix-key` (`tmux_lives_prefix_key`, default `S`) and `--switcher-key` (`tmux_lives_switcher_key`, default `M-s`). Defaults to be chosen during planning (must avoid colliding with the existing prefix/switcher binds and common tmux defaults). No new config file; no hand-edited binds.

The fragment renderer (`__tmux_lives_render_fragment`) gains the open-modal and scratch-toggle `bind-key` lines (prefix and/or root table), wrapped in the same `display-popup`-capability `if-shell` guard as the switcher so the menu fallback is wired when popups are unavailable.

## Part E — `setup color` robustness (supports the modal's bar-color action)

Two fixes to `__tmux_lives_color_cmd` (`conf.d/tmux-lives-install.fish:357`), both surfaced while validating the modal's `b` action against real ShellFish behavior:

1. **Immediate ShellFish re-emit.** Today `setup color` re-renders the fragment and updates the global `status-style` live, but the ShellFish toolbar OSC (`__tcz_emit_barcolor`) only fires from the `client-attached` hook (`__tcz_on_attach`), so an already-attached ShellFish tab keeps its old color until it re-attaches. (Observed symptom: a fresh ShellFish connect showed no tab color until a *new session* was created — the new attach was the only thing that re-ran the hook with the now-baked color.) Fix: after `__tmux_lives_write_fragment`, iterate the currently-attached clients (`tmux list-clients -F '#{client_pid} #{client_tty}'`) and emit the OSC to every ShellFish one, reusing `__tcz_client_is_shellfish` + `__tcz_emit_barcolor`. Those helpers live in `functions/tmux-categorize.fish`, so the color command invokes a new categorizer subcommand (`recolor <color>`) through the existing `fish --no-config $cat <verb>` dispatch. Clearing the color is a no-op emit (as today).

2. **Bare-hex normalization.** A hashless hex (`1f6feb`) passes the charset validation (`:379`) but fails `__tmux_lives_derive_status`'s `#`-anchored parse, silently producing an empty `status-style`. Fix: before storing, if the value is a bare 3- or 6-digit hex (`^#?[0-9a-fA-F]{3}$` or `^#?[0-9a-fA-F]{6}$`) lacking a leading `#`, prepend it. Named colors, `rgb(...)`, and `color(p3 ...)` don't match the bare-hex pattern and are untouched. The normalized value is what gets stored, baked into the fragment, and sent to ShellFish.

**Tests:** `recolor` emits the OSC to a faked ShellFish client and skips non-ShellFish ones (extends the `tmux_lives_fake_environ` + tty-capture patterns in `tests/test-tmux-categorize.fish`); `setup color 1f6feb` stores `#1f6feb` and yields a non-empty derived `status-style` (extends the color tests in `tests/test-tmux-install.fish`).

## Architecture / where things live

- `functions/tmux-categorize.fish`: new `__tcz_modal` (+ render/handler/input-sub-state helpers), `__tcz_scratch`, and `__tcz_recolor`; `modal`, `scratch`, and `recolor` added to `__tcz_main`; `__tcz_menu_args` extended for the fallback; `__tcz_popup_preview` / `__tcz_popup_truncate` / `__tcz_popup_clip` made ANSI-aware. Reuses `__tcz_client_is_shellfish` + `__tcz_emit_barcolor` for the re-emit.
- `conf.d/tmux-lives-install.fish`: `__tmux_lives_render_fragment` emits the new binds; `__tmux_lives_keys_cmd` / `setup` help gains `--modal-key` / `--scratch-key`; `__tmux_lives_color_cmd` normalizes bare hex and invokes `recolor` after re-render; effective-key resolution via the existing `__tmux_lives_key` helper.
- Reuse, don't reinvent: the modal borrows `__tcz_popup_readkey`, the synchronized-update draw, the box/border styling, and the popup-vs-menu capability branch already present for the switcher.

## Testing & isolation (non-negotiable)

Every new server-mutating command (`split-window`, `kill-pane`, `resize-pane`, `select-pane`/`switch-client`, the `bind-key` lines exercised via render assertions) is tested through the `-L`-socket seam (`tmux_lives_tmux_socket`, as `__tmux_lives_conf_source` already does) or the PATH `tmux` shim (as `tests/test-tmux-categorize.fish` already does) **from the start**. Pure render/draw/key-mapping helpers are unit-tested headless with no tmux server. The suite (`for t in tests/test-*.fish; fish $t; end`) must stay green with zero stderr and must never reconfigure the user's live default-socket server.

## Pre-flight items for the plan

- Confirm tmux 3.3a behavior: does a pane redraw live *under* an open `display-popup` during `resize-pane`? Determines whether scratch resize is watch-live or apply-on-close.
- Confirm the cooked-tty line `read` round-trip inside a `display-popup -E` (raw → cooked → raw) for the bar-color input sub-state.
- Choose collision-free defaults for `--modal-key` / `--scratch-key`.
- Confirm `set -p @tmux_lives_scratch` + `#{@tmux_lives_scratch}` lookup across panes works as expected on 3.3a for the toggle's find step.
