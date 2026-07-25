# Theme gallery picker — design

Status: approved in brainstorm 2026-07-24 (visual-companion mockups 01–06). Supersedes the **model-B** interaction of `2026-07-24-theme-v4-picker-design.md` (which shipped to main @ `4ac685d`). The v4 **engine, CLI, and palette signature are unchanged** — this redesigns only the picker's list/knob model.

## Why

The shipped v4 picker (model B) lists the 6 relationships at the current `place`/`mode`. Live use surfaced two problems, both confirmed against real engine output for the user's seed `#5f772b`:

1. **At the default `place=bar`, the relationships barely differ.** `place=bar` anchors the seed to the bar, so the bar is identical (`#44502f` derived) across all six relationships, and sep/active/windows/text are identical too — only `tabs` and `cap` move (2 of 7 roles). The list reads as "samey."
2. **The bold, seed-departing schemes exist but are hidden.** `literal` mode (seed at full chroma) and `cap`/`tabs` placement (which re-anchors the bar to an exotic hue — teal, blue, brown) already produce vivid, convention-breaking looks. Model B buries them behind knobs.

The user's verdict: the color math is good and most liked schemes cluster near the seed (a feature), but the picker should **also surface bolder alternatives, and more of them**, as a browsable set. The chosen shape is a **curated gallery**: a flat, scrollable list of named finished schemes ordered near-seed → bold.

## Model — curated catalog, no per-axis knobs

The picker becomes a **flat list of catalog entries**. Each entry is a **recipe** — a `(relationship, place, mode)` triple — rendered live for the current seed by the existing `__tmux_lives_theme_palette`. The recipes and names are fixed; the colors compute from the seed, so the gallery adapts to any seed.

This replaces model B's "list = one axis, place/mode = knobs" with "list = a designed set of schemes." Consequences:

- **`place`/`mode` are no longer knobs** — each is baked into its catalog entry. The `p`/`P`/`m` (place/mode/mode) dispatch from the shipped picker is removed.
- **Remaining knobs: `seed` (`b`) and `phase` (`←→`).** Phase shifts the hue of every entry (a global tweak); seed opens the RGB-slider / typed-hex entry as today.
- **The engine and `setup theme` CLI do not change.** Saving an entry runs `tmux-lives setup theme <relationship> --place <place> --mode <mode>` (plus `--phase`), silenced — the same one-child-per-save pattern the shipped picker already uses. The full 48-combo space (including the deep cuts this catalog omits) stays reachable via that CLI.

## The catalog

A single ordered catalog of **28 distinct schemes**, defined install-side (so the picker and the CLI's `setup theme list` share one source of truth). Ordered **near-seed → bold** across five tiers:

| tier | recipe pattern | character |
|---|---|---|
| **soft** | `<rel> · bar · derived` | muted, near-seed bar; relationships differ by cap only |
| **glow** | `<rel> · bar · literal` | bar at full seed chroma (bright); punchy caps |
| **slate** | `<rel> · tabs · derived` | bar shifts to a teal-green/olive family |
| **deep** | `<rel> · cap · derived` | bar re-anchored to an exotic hue (teal/blue/brown) |
| **core** | `<rel> · cap · literal` | exotic bar + the seed itself as the cap accent |

The 28 = the non-identical members of `{6 relationships} × {soft, glow, slate, deep, core}` (mono collapses several placements to identical palettes, so mono contributes only `soft`, `glow`, `core`). Entries whose full 7-role palette is byte-identical to an already-included entry are dropped. The deliberately-omitted combos (`low`/`high` lightness variants, `tabs · literal` near-dupes) remain CLI-only.

**Default view = a curated 12.** The picker opens showing 12 of the 28, spanning the tiers. Proposed default 12 (near-seed → bold; each entry carries a `default` flag in the catalog):

1. `mono soft` — the seed, muted baseline
2. `amber soft` — warm cap hint
3. `coral soft` — rosy cap hint
4. `ember glow` — bright green + orange cap
5. `sage glow` — bright + emerald cap
6. `teal glow` — bright + teal cap
7. `ember slate` — teal-green bar
8. `amber deep` — teal bar
9. `ember deep` — deep-teal bar
10. `coral deep` — blue bar
11. `sage core` — amber bar + seed cap
12. `teal core` — brown/umber bar + seed cap

The exact 12 is a curation choice, easily changed by flipping `default` flags; it is **not** load-bearing on the design. This list is the starting point, tunable at spec review and later.

**Expand-to-all.** A key — **`m`** ("more") — toggles the list between the 12 defaults and all 28; the same key collapses back. The current selection is preserved across the toggle where possible (keep the highlighted entry selected; otherwise clamp). The zone label reflects the mode (`schemes · 12 curated` vs `schemes · all 28`).

**Naming.** Character names of the form `<relationship> <tier-word>` (`ember glow`, `ember deep`, `teal core`) — seed-independent and systematic, matching what the user approved in mockup 06. The literal recipe (`ember · cap · derived`) shows dim on the right of each row. (Poetic per-scheme names — "coral marine", "teal umber" — are a possible later polish, not part of this cut.)

## The picker surface

Reuses the shipped picker's frame, preview, and input machinery; only the list model and key map change.

- **Frame:** the 52-wide `display-popup`, rounded tl-theme border, tab chip + fake-bar preview at top (the preview and chip track the highlighted entry; **tabs role stays quiet** — no change to its derivation).
- **List:** one row per visible catalog entry — `❯`-marker · name · 7-role swatch strip · dim recipe. A fixed-height scrolling window (≈7 rows) with `▲n`/`▼n` overflow markers; the list scrolls as the selection moves (as the session switcher already does). `↑↓`/`jk` move; `Home`/`End` jump to ends (optional).
- **`❯` current marker** on whichever visible row matches the persisted theme's `(relationship, place, mode)`; none if the persisted theme is a non-catalog CLI combo.
- **`off` row** (legacy look) and the **anchor row** (the persisted theme frozen at open, at the bottom, for revert-compare) — unchanged behavior from the shipped picker.
- **Keys:** `↑↓`/`jk` move · `←→` phase (5°/press, coalesced) · `b` seed entry · `m` expand/collapse · `z` shake (random entry from all 28) · `a` apply-preview (push the highlighted palette live via the 8-arg `__tmux_lives_theme_apply_live`, no save) · `⏎` save (config-loaded child → `setup theme <rel> --place --mode --phase`, silenced) · `esc`/`q` revert to the persisted theme and close.

## Geometry

The frame stays a fixed height with the list as a scrolling window (unlike the shipped picker, whose height was exactly the row count). Because the list is windowed (12 or 28 entries, ~7 shown), the popup height is constant regardless of catalog size. Target a fixed `-h` that fits: chip + preview + adjustments (seed/phase) + the ~7-row list window + off + anchor + legend + borders. The exact-height emit contract (rows `1..-2` with `\n`, last without) still holds; `-h` must equal the emitted row count. Pin it at all three open sites (`M-k` bind, `setup theme` no-arg, `M-m k`) + test pins, as in the shipped picker.

## What changes in code

All in `functions/tmux-categorize.fish` (the picker) plus a small install-side catalog:

- **New install-side catalog** in `conf.d/tmux-lives-install.fish`: an accessor returning the 28 ordered entries as `name|relationship|place|mode|default` records (or equivalent), and a helper to filter the default-12. `setup theme list` renders from it. This is the shared source of truth.
- **Picker `_reload`:** iterate the catalog (defaults or all, per the expand state) instead of the relationship axis; for each entry call the existing 9-arg `__tmux_lives_theme_palette $seed <rel> <place> <mode> $phase $viv $shape $ease $contrast` (viv/shape/ease/contrast read once from stored universals, as today). Cache key becomes `"$seed|$phase|$expanded"`.
- **Picker `_init`:** drop the `place`/`mode` reads as picker knobs (they're per-entry now); keep seed/phase/the stored viv/shape/ease/contrast pass-through.
- **Key dispatch:** remove `p`/`P`/`m`/`M` place/mode cycling; add `m` expand/collapse; keep `←→` phase, `b`, `z`, `a`, `⏎`, `esc`. `z` shake randomizes the selected catalog index (and optionally phase).
- **Save/apply:** the selected entry supplies `(rel, place, mode)`; apply-preview and save pass those. The anchor row saves its frozen snapshot.
- **Windowed list render + scroll** (new vs the shipped picker, which drew every row): a scroll offset following the selection, `▲`/`▼` overflow markers.

## Testing

Same reality as the shipped picker: pure builders + source-grep structural guards + a **0-stderr `--no-config`** categorize run + geometry pins; the interactive loop is runtime-only (user live smoke).

- Pure-builder / accessor tests: the catalog accessor returns 28 records; the default filter returns 12; every record's `(rel, place, mode)` is a valid engine input (spot-check a sample palette is 7 non-empty hexes).
- Grep guards: the picker body iterates the catalog accessor (not `__tmux_lives_theme_relationships` directly for the list), has no `p`/`P` place-cycle or `case m`-as-mode dispatch (now `m` = expand), still uses the 9-arg palette, no 8-arg calls, no re-introduced `__tmux_lives_theme_ring`/`_rotate`/`_rotpal`.
- Windowed-scroll builder: given a selection index and window size, the visible slice + overflow counts are correct at the ends and middle.
- `setup theme list` renders the catalog names.
- Live smoke (user, after `fisher update`): the 12 open by default; `m` expands to 28 and collapses; `↑↓` scroll with correct windowing; `←→` phase; `b` seed; `z` shake; `a`/`⏎`/anchor; `esc` revert; the 22-ish-row frame at all three open sites; tabs stay quiet.

## Open items

- **The default 12** is a curation starting point — reorder/swap freely at review or later via the `default` flags. Not load-bearing.
- **Expand key = `m`.** Free after the place/mode knobs are removed; confirm no readkey collision in live smoke. Configurable if desired.
- **Poetic per-scheme names** (marine/umber/emerald) are deferred polish; the systematic `<rel> <tier>` names ship first.
- **`z` shake scope:** randomizes over all 28 (not just the visible 12) so shake can surprise with a bold one — confirm that's the wanted behavior.
- **Anchor when the persisted theme is a non-catalog CLI combo:** the anchor row still shows it (frozen), but no list row gets the `❯` marker — acceptable.
