# Theme picker — current-zone + legend-grid refinement — design

Status: approved in brainstorm 2026-07-25 (visual companion mock `07-current-zone.html`). A refinement of the **gallery picker** (branch `feat/theme-gallery-picker`, built + whole-branch-reviewed, not yet merged). Builds ON that branch so the whole picker merges together. The v4 theme **engine, CLI, catalog, and windowing are unchanged** — this reshapes the picker's current-scheme handling and the legend layout only.

## Why

Two live-feedback refinements to the just-built gallery picker:

1. **The "current" scheme shouldn't sit in the browsable list.** Today it's the last row in the linear `↑↓` order (`sel = n+1`), so you can scroll into it without realizing it's just your existing theme, and it reads as if the knobs affect it. It should be **pulled out into its own separated zone**, reachable by a dedicated key rather than by scrolling.
2. **The bottom key legend lost its aligned grid.** The columns don't line up across rows (each legend row was rendered independently at a fixed pitch, so per-row icon widths shifted every column). It should be a **neat table**: icon+description attached (≈1 space), columns of those aligned, with separation between columns.

## The design

### 1. Separated "current" zone + a `c` jump key

- The **current scheme** (the anchor snapshot — the persisted theme frozen at open) moves out of the `↑↓` navigation range into its own section at the bottom, introduced by a border-title separator **`├─ current ─┤`** (same `__tcz_thp_zsep` treatment as `adjustments`/`schemes`), with the current scheme rendered as a single row below it.
- **`↑↓` now spans only `sel 0..n` — the schemes (`0..n-1`) plus the `off` row (`n`).** It can no longer wander into the current zone. `off` stays a normal scrollable choice (user-confirmed).
- **`c`** jumps the cursor to the current zone (a selection state `sel = n+1`, reachable ONLY via `c`, never by `↑↓`). Pressing `c` again — or `↑↓` — returns to the list (`↑` → the `off` row `n`; `↓` → the top scheme `0`). While on the current zone, `a` apply-previews it and `⏎` saves it (i.e. re-applies / reverts to your current theme).
- `__tcz_thp_vismap` (the `↑↓` clamp) changes from `0..n+1` to **`0..n`**; the `n+1` (current) position is set/left only by the `c` handler. The current row is drawn unconditionally (pinned, always visible for revert-compare) regardless of the scheme window's scroll position.

### 2. The `❯` current-marker: recipe **and** phase

The in-list `❯` marks a scheme row **only when it renders identically to the persisted theme** — recipe AND the live phase:

```
test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"
    and test "$phase" = "$anch_phase"
    and set curflag 1
```

It is cursor-independent (a property of the row, not the selection). The moment anything differs — a different scheme, or the phase knob nudged away from the persisted phase — the marker disappears. (`vividness/shape/ease/contrast` are inert in the current engine and not editable in the picker, so they need not enter the comparison; phase is the only live knob that can make a listed recipe diverge from the persisted theme.) The separated current zone always shows the persisted theme regardless; the `❯` is only the "a listed scheme happens to equal your current theme right now" indicator.

### 3. `▲N ▼N` scroll counts on the schemes rule

The hidden-scheme counts (schemes scrolled above/below the window) live on the **schemes** separator, right-aligned — `├─ schemes · near-seed → bold ─── ▲2 ▼4 ─┤` — scoped to the scheme list they describe. (This is where the built picker already puts them; keep it, just confirm they're clearly on the schemes rule, not on the current zone.)

### 4. The legend as an aligned grid (cross-row column widths)

Replace the fixed-pitch, one-row-at-a-time `__tcz_legend_row` with a builder that renders the **whole legend as one aligned table**. The layout model (user-specified):

- Each cell is an **`<icon> <desc>` unit**: the key glyph, ~1 space, the description — attached, close together.
- **Columns of those units align**: within a column, the icons align AND the descriptions align. Because icons vary in width (`↑↓`, `esc`, single letters), each column pads its icons to that **column's** widest icon, then 1 space, then the description — so descriptions line up.
- **Column widths are the MAX across ALL rows**, never per-row. (The bug was per-row grids: a narrower row's columns shrank left, so column 3 started at a different x on each row. The fix is one shared grid / shared column widths.)
- **Separation between column-groups** is larger than the icon↔desc gap (attached units are close; separate columns are spaced).

Concretely, the legend is a fixed set of rows × columns of `(key, desc)` cells:

```
↑↓ move     ←→ phase    b   seed
m  more     z  shake    c   current
a  apply    ⏎  save     esc close
```

The builder takes the grid (rows of `key|desc` pairs), computes per-column `keyw = max visible-width of keys in that column over all rows` and `descw = max visible-width of descs`, then formats each cell as `<key padded to keyw> <1 space> <desc>` and joins columns with a fixed gap. Visible widths use `string length --visible` (the glyphs + any SGR); keys render in the `key` tl-theme color, descs muted. This same cross-row alignment discipline is applied to the **adjustments zone** (seed/phase) so its labels/values align too.

The final legend key map: `↑↓ move · ←→ phase · b seed` / `m more · z shake · c current` / `a apply · ⏎ save · esc close`.

### 5. The frame encloses all content

Every content row — including the current-zone rows and every legend row — is wrapped by the frame (`│ … │` via `__tcz_thp_ln`), and the box's bottom border is emitted after the last legend row. (The built picker already does this via `__tcz_thp_ln`; the requirement is to keep the new rows inside the frame and not let any row render outside it.)

## Geometry

The current zone adds a `├─ current ─┤` separator + one row (was one pinned anchor row → +1), and the legend is now a fixed 3 rows (was 2 → +1), so the frame grows by ~2 rows. Recount the exact emitted `set -a lines` rows and set `-h` to match (exact-height contract: emit rows `1..-2` with `\n`, last without; `-h` must EQUAL the emitted count or the top border scrolls). Keep it ≤ ~28 so it fits typical terminals; reduce `WIN` (the scheme-window size, currently 8) if needed to stay in budget. Pin `-h` at all three open sites (`M-k` bind, `setup theme` no-arg, `M-m k`) + the test geometry pins.

## What changes in code

All in `functions/tmux-categorize.fish` (the picker):

- **`__tcz_thp_vismap`**: clamp `↑↓` to `0..n` (drop `n+1`).
- **`c` key**: new dispatch arm toggling `sel` to/from `n+1` (current); `a`/`⏎` on `sel==n+1` act on the frozen anchor snapshot (as they already do for the anchor).
- **Draw loop**: render `off` (sel `n`) at the end of the scrollable list; then a `├─ current ─┤` zsep; then the current scheme row (drawn unconditionally); then the legend. The `❯` marker gains the phase comparison.
- **New legend builder** (pure, module-level, e.g. `__tcz_thp_legend`): cross-row column-width alignment; replaces the `__tcz_legend_row` calls in the picker. (Leave `__tcz_legend_row` if other callers exist — grep; the switcher/seed screens may use it. If so, keep the old builder for them and add the new grid builder for the picker legend, OR upgrade `__tcz_legend_row` if all callers benefit — decide at plan time.)
- **Adjustments zone**: apply the same column alignment (likely minor — `__tcz_thp_kv` already aligns).
- **Docstring + geometry**: update the `__tcz_theme_picker` docstring (current-zone + `c` key + legend), recount `-h`.

## Testing

Same reality as the rest of the picker: pure-builder unit tests + source-grep structural guards + a 0-stderr `--no-config` categorize run + geometry pins + the user's live smoke.

- **Pure-builder tests for the new legend builder**: given a multi-row grid with varying icon widths, assert every column's descriptions start at the same visible offset across all rows (cross-row alignment), the icon↔desc gap is 1, and the total row width fits `IW`. A regression test for the exact `↑↓/m/a`, `←→/z/⏎`, `b/c/esc` grid.
- **`__tcz_thp_vismap`**: `↑↓` clamps at `n` (off), never reaches `n+1`.
- **Grep guards**: the picker has a `case c` (current jump); the `❯`-marker condition includes the `$phase = $anch_phase` test; the current zone uses a `├─ current ─┤` zsep; the legend uses the new builder.
- **Geometry pins** at the chosen `-h`.
- **0-stderr** `--no-config` categorize run; full 8-suite gate both configs.
- Live smoke (user, after `fisher update`): `c` jumps to/from current; `↑↓` can't reach current; the current zone is border-titled and always visible; the `❯` appears only on an identical-render row and clears on a phase nudge; the legend is a clean aligned table; the frame encloses everything.

## Open items

- **`c` key** — free (the picker's live keys are `↑↓/←→/b/m/z/a/⏎/esc`); confirm no readchar collision at live smoke.
- **Legend builder scope** — new builder for the picker vs upgrading the shared `__tcz_legend_row` — decided at plan time after grepping callers.
- **`WIN` vs `-h`** — if the +2 rows push the popup past a comfortable height, drop `WIN` from 8 to 7; a plan/geometry-task judgment call.
