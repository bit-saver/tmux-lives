# ts switcher redesign — custom two-pane popup (pure-fish, no fzf)

- **Date:** 2026-06-18
- **Status:** Approved (design) — supersedes the fzf path in `2026-06-18-ts-live-preview-switcher-design.md`
- **Project:** tmux-lives (fisher plugin)
- **Component:** session switcher (`prefix S` / `ts`)

## Background

The current `prefix S` / `ts` switcher opens **fzf** inside a `display-popup` with a live
`capture-pane` preview, falling back to tmux `display-menu` when fzf is absent. Two flaws make
the fzf version unacceptable:

1. **Landable headers.** The `── claude ──` / `── running ──` / `── general ──` category rules
   are interspersed rows. fzf has no concept of a non-selectable interspersed row (only a static
   top header block via `--header`/`--header-lines`). The cursor can land on a rule, and
   selecting one fires `capture-pane` against an empty target, so the preview shows an error /
   garbage. **This cannot be fixed in fzf.**
2. **Look.** The `display-menu` palette (category-colored rules, muted-yellow current row) reads
   far better than the fzf rendering. (fzf *can* render arbitrary per-row ANSI, so the color gap
   is closeable — but flaw 1 is terminal, so fzf is dropped regardless.)

`display-menu` itself is not an option for the preview: it is modal, tmux-rendered, single
column, and exposes **no hover/highlight callback**, so a preview pane cannot be attached to it —
not side-by-side, and not even "press a key to preview the highlighted row."

## Decision

Replace the fzf path with a **hand-rolled two-pane popup TUI**, written in **pure fish**, run
inside `tmux display-popup`. We own the render and the key loop, which is the only way to get
**menu-quality colors + a live preview + truly non-selectable headers** at the same time.

Interaction (locked with the user):

- **Layout:** left = categorized session list, right = live `capture-pane` preview. Preview is
  **always on**.
- **Navigation:** `↑`/`↓` and `j`/`k` move to the next/previous *selectable* row (rules are
  skipped). **No type-to-filter, no digit jump, no g/G** — the session count never warrants them
  (YAGNI, confirmed by the user).
- **Commit/cancel:** `Enter` switches to the highlighted session; `Esc` / `q` cancels.

### Alternatives considered (rejected)

- **B — preview on demand (peek with a key, Esc back).** Same engine, list full-width until
  toggled. Rejected: the preview's whole value is being visible *while scanning*; a toggle re-adds
  a step.
- **C — tmux native `choose-tree -sZ`.** Free preview, near-zero code. Rejected: fixed tmux tree
  look — no category grouping, no colored `── rules ──`; loses exactly the look the user values.
- **Restyled fzf.** Rejected: cannot fix the landable-header bug (flaw 1).

## Constraints

- **Pure fish.** No compiled binary, no new runtime dependency. The only external commands are
  `tmux`, `stty` (POSIX; for terminal size + raw mode), and standard ANSI escapes. Keeps the
  plugin installable via fisher everywhere (macOS port is a separate spec).
- **File hygiene / consolidation (hard requirement).** The user browses `conf.d/` and
  `functions/` constantly and dislikes clutter ("tons of `__` files irk me"). Therefore:
  - **Zero new files in `functions/` or `conf.d/`.** Every new function for this feature is
    added to the **existing** `functions/tmux-categorize.fish` (all `__tcz_*` already live there)
    and the **existing** `conf.d/tmux-lives-install.fish` (the keybinding fragment).
  - New `__tcz_*` helpers stay underscore-prefixed (fish keeps them out of default command
    completion) and grouped with the other switcher functions in that one file.
  - The only net file change is the **test file** (in `tests/`, which is not a config-browse
    directory) — see Testing.

## Architecture

All within the existing switcher layer of `functions/tmux-categorize.fish`.

### Removed

- `__tcz_fzfpick`, `__tcz_fzf_lines`
- the `fzfpick` case in the `__tcz_main` dispatcher
- the `command -q fzf` branch in `__tcz_open_switcher`

### Dispatcher / entry

- **New subcommand `popup <client>`** in `__tcz_main` → `__tcz_popup <client>`.
- `__tcz_open_switcher <client>`: run the popup TUI when `display-popup` is supported (tmux ≥ 3.2)
  and stdout is a tty; otherwise fall back to the existing `__tcz_menu` (colors, no preview).
- **Fragment** (`conf.d/tmux-lives-install.fish`, `__tmux_lives_render_fragment`): change the
  `bind-key S` body from the fzf `display-popup … fzfpick` to
  `display-popup -E -w 80% -h 70% -- fish --no-config "$cat" popup '#{client_name}'`.
- `ts` (inside tmux) keeps invoking `__tcz_open_switcher`; `ts` **outside** tmux keeps its current
  numbered grouped-list path unchanged.

### Runtime flow (`__tcz_popup <client>`, runs in the popup pty)

1. `__tcz_categorize >/dev/null 2>&1` — truth-up names before listing (matches `__tcz_menu`).
2. Build the model from existing `__tcz_overview` (claude > running > general, MRU within group).
   Resolve the current session via `tmux display-message -p '#{session_name}'`.
3. Read terminal size from `stty size` (`rows cols`).
4. `__tcz_popup_layout <cols>` → list width / preview width.
5. Render the full frame once per keystroke (see Rendering), cursor hidden (`\e[?25l`).
6. Key loop (see Keys).
7. On `Enter`: restore tty + cursor, then call the existing `__tcz_switch <session> <client>`
   (which ghost-detaches stale clients, then `switch-client -c <client> -t =<session>`).
8. On `Esc`/`q`: restore tty + cursor, exit with no switch.

### New pure (testable) functions

- `__tcz_popup_layout <cols>` → `listwidth previewwidth`. List ≈ 46% of cols, clamped to a sane
  min; one column reserved for the vertical divider. Below a minimum total width, previewwidth =
  0 (list-only degrade).
- `__tcz_popup_list_lines <listwidth> <selidx> <current> <model…>` → emits one rendered line per
  model row (ANSI). Encodes the two locked aesthetics (below).
- `__tcz_popup_selectable <model…>` / next-index helper → indices of session rows (not rules);
  used to skip headers and to clamp at first/last.
- `__tcz_popup_truncate <text> <width>` → width-aware truncation with a trailing `…`.
- `__tcz_popup_preview <session> <w> <h>` → `tmux capture-pane -ep -t <name>` (**plain `-t`, no
  `=` prefix** — tmux 3.3a `capture-pane` rejects `=name`), each line truncated to `w`, first `h`
  lines, blank (not error) if the pane/session is gone.

The interactive key loop (`__tcz_popup`) is a thin shell over these pure functions.

## Rendering — acceptance criteria

Shared palette (extract once; **both** `__tcz_menu_args` and the popup read it so they never
drift): claude = `colour208` (orange, bold), running = `cyan`, general = `green`, current-session
name = muted yellow, markers = dim. Current-session yellow renders correctly as `#[fg=colour143]`
in the tmux-drawn menu; in the popup's raw-ANSI context the fzf path used `\e[38;5;179m` — pick
whichever reads as muted-yellow in the popup and verify visually during implementation.

Locked aesthetics (these are test assertions, not preferences):

1. **Category border + corner.** Each category opens with a header line `╭── <category> `
   followed by `─` repeated so the visible width equals **exactly `listwidth`**, colored by
   category (claude bold orange `208`, running bold cyan `6`, general bold green `2`). Every
   session row under it begins with a **category-colored `│` left border** in column 1 — the
   corner `╭` + the `│` verticals bracket the group.
2. **Header rules fill to the divider.** The header's trailing `─` run fills so the whole header
   (corner + `── cat ` + rule) is exactly `listwidth` visible columns, recomputed from the live
   popup size every render. No fixed-width rule that stops short.
3. **Indicators flush-right.** `[current]` / `[attached]` are padded so the marker's **last
   character sits at column `listwidth`**; the session name is truncated with `…` if it would
   collide with the marker.
4. **Selected row.** The category `│` border in column 1 becomes an **orange `▐` (right-half
   block, U+2590)** on a full-width grey background band (`48;5;236`). The band shows through the
   block's left half so the border reads continuous and the selected row bulges rightward; its
   left edge sits on the border line (no extra column — same border/block + space + title layout
   as non-selected rows). `▐` is chosen over `▌` so the fill lands right of the `│` column, and
   over `█` so the border line stays unbroken.
5. **Current session.** The column-1 border becomes a muted-yellow `❯` chevron (replacing the category `│`), the name is muted yellow (`38;5;179`), and the flush-right marker is `[current]` (also yellow). If the current session is also the selected row, the `▐` block wins (selected takes precedence in column 1).
6. **Headers are unreachable:** navigation only ever lands on session rows (`selidx` indexes
   sessions, so the cursor can never land on a header/border).

The column layout is: col 1 = border/block (`│` / `▐` / `╭` on headers), col 2 = space, col 3+ =
title. Lead-in is 2 columns (unchanged from the pre-border design), so the width invariant
`2 + namespace + (mlen>0 ? 1+mlen : 0) == listwidth` and the flush-right math are preserved.

## Keys

Raw input: save `stty -g`, set `stty -icanon -echo`, restore on every exit path and via a
SIGINT/SIGTERM cleanup handler (`function … --on-signal`).

- `j` / `Down`, `k` / `Up` → move to next/previous selectable row (clamp at ends).
- `Enter` (`\r` or `\n`) → switch.
- `x` → kill the highlighted session: a bottom-row `kill <name>? (y/n)` confirm; `y`/`Y` kills it and refreshes the list (popup stays open, selection clamps), anything else cancels.
- `Esc` / `q` → cancel.

The popup gets the client from the bind's `'#{client_name}'`, but `display-popup` does NOT format-expand argv after `--`, so it can arrive literally — `__tcz_popup` therefore resolves the client itself (`tmux display-message -p '#{client_name}'`) when the arg is empty or an unexpanded `#{…}`, otherwise `switch-client -c` would get a bogus client and silently fail.

**Read bytes with `dd`, NOT fish `read`.** On a real tty, fish's `read` runs fish's line editor,
which interprets arrow escape sequences (`\e[A`, `\eOA`) as cursor-movement and **swallows** them —
so `read` never returns the arrow bytes (verified live: `j`/`k` worked, arrows did nothing). The
reader instead reads one raw byte at a time via an inline `dd bs=1 count=1 | od -An -tx1 | string
trim | read VAR` pipeline (`dd` as the pipeline head sees the function's stdin; a command
substitution `(dd …)` inside a pipe-RHS function does **not** inherit that stdin — fish quirk).
Bytes are compared as hex. `Esc` vs arrow is disambiguated by toggling `stty min 0 time 1` (~0.1s)
for the follow bytes after `\e` (`1b`): `5b`/`4f` (`[`/`O`) → arrow; `41`/`42` (`A`/`B`) → up/down;
nothing → bare `Esc` (cancel). Both CSI (`\e[A`) and SS3 (`\eOA`, application-cursor-keys mode) are
handled. `j`/`k` remain the dependable primary keys.

## Edge cases

- No `display-popup` / non-tty → `__tcz_menu` fallback.
- Popup too narrow → previewwidth 0, list-only.
- Empty list → the popup returns immediately without opening (no special message). Practically unreachable inside tmux, since the invoking client's own session always lists.
- Single session → renders and switches normally.
- Highlighted row is the current session → `Enter` is a harmless no-op switch.
- Dead/missing pane → blank preview, never an error (the bug we are removing).

## Files touched

- `functions/tmux-categorize.fish` — remove fzf functions; add `__tcz_popup*`; new `popup`
  dispatcher case; update `__tcz_open_switcher`. (existing file)
- `conf.d/tmux-lives-install.fish` — fragment `bind-key S` body. (existing file)
- `tests/test-tmux-popup.fish` — **new** (in `tests/`, not a config-browse dir).
- Docs: this spec; the implementation plan; `CLAUDE.md`, `README.md`, `docs/auto-tmux.md` status
  updates; supersede the fzf decision note.

No new files in `functions/` or `conf.d/`.

## Testing

New `tests/test-tmux-popup.fish` drives the pure functions (this is how the aesthetics are
locked), sourcing the categorizer with `tmux_categorize_test=1`:

- header rules are exactly `listwidth` visible chars at several widths;
- markers are flush-right (last char at `listwidth`); name truncates with `…` on collision;
- `__tcz_popup_selectable` skips rules; next/prev clamps at first/last selectable row;
- `__tcz_popup_truncate` ellipsis triggers at the boundary;
- `__tcz_popup_layout` math (list/preview split, narrow degrade).

The interactive key loop is left untested (thin shell over tested functions). All existing suites
(`test-tmux-auto`, `test-tmux-restore`, `test-tmux-categorize`, `test-tmux-shellfish`,
`test-tmux-install`, `test-tmux-status`, `test-generic`) must still print `ALL PASS`.

## Risks & mitigations

- **Arrow-key portability.** ESC-sequence handling varies by terminal. Mitigation: `j`/`k` are
  first-class; arrows are best-effort via the follow-read.
- **`stty size` inside `display-popup`.** Must return the popup's size, not the underlying pane's.
  Verify on the host (tmux 3.3a) early; fall back to `$COLUMNS`/`$LINES` or a sane default if
  `stty size` misreports.
- **Flicker.** Build the whole frame as one string; write once per keystroke; hide the cursor.

## Out of scope (possible follow-ups)

- macOS port (separate spec): launchd vs the `type -q systemctl` seams.
- Cutover of the live `~/.config/fish` to the plugin.
- Reducing the plugin's total file count further (e.g., merging install into runtime conf.d) —
  noted with the file-hygiene preference but not bundled here.
