# ts live-preview switcher + session-UX refresh — design

- **Date:** 2026-06-18
- **Status:** draft for review
- **Repo:** `tmux-lives` (the fisher plugin). This is a **behavior-change** enhancement (distinct from the spec-1 extraction and the future macOS port).
- **Goal:** Upgrade the `ts` / `prefix S` switcher to show a **live pane preview** beside the categorized list (the thing `prefix s`/`w` `choose-tree` gives), while keeping the tailored look we built — plus three smaller UX tweaks.

## Components

Four cohesive pieces, all in the plugin:

1. **fzf-in-`display-popup` switcher with live preview** (the main work).
2. **Header restyle** — `── name ─────…` (2-dash lead-in + full-width rule).
3. **Current session in muted yellow** (replaces the dim treatment).
4. **`gen-N` general-session naming** (was bare numbers).

## Current state (what we're changing)

- `functions/tmux-categorize.fish`:
  - `__tcz_overview` → snapshot sorted claude>running>general, MRU within group (one line: `name⇥category⇥attached⇥last⇥display`). **Reused unchanged** as the switcher's data source.
  - `__tcz_menu_args` → formats overview into `display-menu` triples; builds the `──── claude ────` headers and the `#[dim]…[current]` marker. **Modified** (header restyle + yellow current).
  - `__tcz_menu` → `tmux display-menu`. **Kept as the fallback** when fzf is absent.
  - `__tcz_switch <session> <client>` → ghost-detach then `switch-client -c`. **Reused unchanged** as the accept action.
  - `__tcz_free_number` / `__tcz_owned` / `__tcz_new_general` → general naming + ownership. **Modified** for `gen-N`.
- `conf.d/tmux.fish` `ts` → inside tmux calls the `menu` subcommand; outside tmux prints a grouped numbered list. **Modified** to route through the new dispatcher inside tmux (outside-tmux path unchanged but shows new `gen-N` names automatically).
- The `prefix S` binding lives in the fragment rendered by `__tmux_lives_render_fragment` (in `conf.d/tmux-lives-install.fish`). **Modified** to open the switcher dispatcher.

## Component 1 — fzf live-preview switcher

**Entry + fallback.** A new categorizer subcommand `open-switcher <client>` is the single entry point for both `ts` (inside tmux) and `prefix S`. It decides:
- **fzf present** (`command -q fzf`): open `tmux display-popup -E` running the new `fzfpick <client>` subcommand.
- **fzf absent** (e.g. a fresh Mac): fall back to today's `__tcz_menu` (`display-menu`) — unchanged behavior, digit-jump intact.

This keeps the no-fzf case fully working and is the macOS-portability seam.

**`fzfpick <client>`** (runs inside the popup):
1. `__tcz_categorize` truth-up (as the menu already does).
2. Build the fzf input from `__tcz_overview`: one line per row, `TAB`-delimited as `<session>⇥<display-label>`, where the display-label carries ANSI color (category palette, `[current]`/`[attached]` markers, muted-yellow current). Category **separator rows** are emitted as `⇥<colored "── claude ─────…">` with an **empty** session field.
3. Run fzf, styled to NOT look like default fzf:
   - `--ansi --delimiter '\t' --with-nth 2` (match/show the label; keep the session in field 1 for preview + accept).
   - `--layout=reverse-list` (claude at top, prompt at bottom — matches the mockup).
   - `--preview 'tmux capture-pane -ep -t "={1}"'` + `--preview-window 'right,50%,border-left'` — live content of the highlighted session's active pane (`-e` keeps its colors; empty field 1 on a separator → blank preview).
   - Custom chrome: `--prompt 'switch ❯ '`, a custom `--pointer`, `--info inline` (or hidden), and a `--color` palette matching ours (orange/cyan/green accents, blue prompt). Exact flags tuned against a real render (see Testing).
4. On accept: read field 1 of the chosen line; if non-empty (not a separator), call `__tcz_switch <session> <client>` (ghost-detach + `switch-client -c <client>`). Empty field (separator) or Esc → no-op, popup closes.

**Client plumbing.** The popup is opened with the choosing client baked in (`#{client_name}` from the binding, or `ts`'s own client), so `__tcz_switch` can target it with `switch-client -c`. (Same reason the current menu passes `#{client_name}` — never put the target in tmux's own string layer.)

**Interaction.** Type-to-filter (fzf), `↑↓`/`ctrl-j/k` move, `⏎` switch, `esc` cancel. Digit-jump (1–9) is dropped in the fzf path (it conflicts with filtering and is moot now that general sessions aren't bare numbers); the `display-menu` fallback keeps digit-jump. Known minor: the cursor can land on a (no-op) separator row — fzf has no non-navigable rows; acceptable.

## Component 2 — header restyle

In `__tcz_menu_args` (and the `fzfpick` separator builder, sharing one helper), category headers become: a **2-dash lead-in**, the name, then a rule filling the **entire remaining width** — `── claude ─────────────…`. Replaces today's fixed 4-dash lead-in + partial trailing rule. Same per-category palette (claude colour208/orange, running cyan, general green).

## Component 3 — current session in muted yellow

In `__tcz_menu_args` and the fzf label builder, the current session's row uses **muted yellow** (tmux `colour143` ≈ `#afaf5f`) for the name + `[current]` marker, replacing the `#[dim]` treatment. Keep the `▸` pointer and the `[current]` text.

## Component 4 — `gen-N` general naming

- `__tcz_free_number` → produces `gen-N` (smallest free N, stable once assigned). (Rename to `__tcz_free_gen` or keep the name; implementation detail.)
- `__tcz_owned` recognizes general sessions by **both** `^gen-\d+$` and the legacy `^\d+$`, so existing bare-numeric general sessions are still adopted and get **auto-renamed to `gen-N` on the next categorize pass** (the categorizer re-derives owned names — no manual migration).
- `__tcz_new_general` uses the new namer.
- This composes cleanly with type-to-filter (typing `gen` narrows to general sessions).

## Testing

The interactive fzf TUI itself isn't unit-testable, but every piece around it is — and the existing suites already isolate via `-L` sockets + PATH shims.

- **List/label builder** (new helper + `fzfpick` input): assert the emitted lines — session in field 1, colored label in field 2, separator rows have an empty field 1, current row carries the yellow style, names show `gen-N`. (extends `test-tmux-categorize.fish`)
- **Header restyle:** assert the `── name ─────…` format (2-dash lead-in, full-width rule) from the shared header helper.
- **Fallback decision:** `open-switcher` chooses popup-vs-menu by `command -q fzf` — test both by shimming `fzf` present/absent on PATH.
- **`gen-N` naming + ownership:** update `test-tmux-categorize.fish`'s general-naming assertions to `gen-N`; assert `__tcz_owned` accepts both `gen-N` and legacy numeric; assert a numeric general session is re-derived to `gen-N`.
- **Accept action:** `__tcz_switch` is already exercised; add a case that a separator row (empty field 1) is a no-op.
- **Manual (the look):** a real `display-popup`+fzf render screenshot for final styling approval + tuning — the user cares about the tailored look; this is the one step tests can't cover.

All automated suites must stay `ALL PASS`. fzf 0.38 is installed locally; the plugin treats fzf as optional (graceful fallback).

## Files touched

- `functions/tmux-categorize.fish` — new `open-switcher`/`fzfpick` subcommands + shared header helper; `__tcz_menu_args` restyle; `gen-N` naming/ownership; dispatch in `__tcz_main`.
- `conf.d/tmux.fish` — `ts` routes through `open-switcher` inside tmux.
- `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment`: `prefix S` opens the switcher; update the install test if the rendered `bind-key S` line changes.
- `tests/test-tmux-categorize.fish` (+ maybe `test-tmux-install.fish` for the fragment) — assertions above.

## Out of scope

- The outside-tmux `ts` numbered list keeps its current format (no popup/preview without a tmux client); it shows `gen-N` automatically.
- macOS port (separate spec). The fzf-optional fallback is the only macOS-relevant seam here.

## Open questions

None outstanding — design approved in brainstorming (look v2, auto-rename existing general sessions, type-to-filter).
