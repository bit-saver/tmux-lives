# Theme v4 picker (Phase 2) — design

Status: approved in brainstorm 2026-07-24, not yet planned or built. Supersedes the Picker section of `2026-07-23-theme-relationship-placement-design.md` (which sketched "approach A"; this chooses B — see Model).

## Why

Theme v4 Phase 1 (main @ `a49d226`) shipped the install-side engine, CLI, fragment, and migration, but intentionally deferred the picker. The picker (`__tcz_theme_picker` + the `__tcz_thp_*` cluster in `functions/tmux-categorize.fish`) is still v3-shaped and is **broken** on any v4 install: it iterates `__tmux_lives_theme_schemes` (the old 10-name list), calls `__tmux_lives_theme_palette` with the retired 8-arg signature and v3 scheme names (→ empty → blank swatches), calls the **deleted** `__tmux_lives_theme_ring`, and reads the retired `tmux_lives_theme_rotate`. Opening `M-k` / `setup theme` (no arg) / `M-m k` shows the old scheme list with blank swatches. This rewrites the picker for the v4 model.

## Model — B (relationships as the list, place/mode as knobs)

The v4 theme space is 48 palettes: 6 relationships × 5 placements × 2 modes (with `low`/`high` forcing derived, so 6 × 8 effective place/mode cells). A picker shows a slice. Two models were mocked live:

- **A** — the list is one relationship's 8 placements; relationship is a knob. Makes placement prominent; comparing relationships requires cycling.
- **B (chosen)** — the list is the 6 relationships (each at the current place/mode); place and mode are knobs. Makes relationship-picking-by-eye prominent (the workflow the calibration used); placement is a knob you turn.

The user chose B with low conviction and an explicit instruction: **build B, but keep A reachable** — "try one, see how it plays out, try the other if there are doubts."

**Switchability seam (a first-class requirement).** A and B differ only in which axis is the *list* and which are *knobs*; the underlying palette data is identical. The picker must separate "what populates the list" from "what the knobs hold" behind a clean seam, so flipping B→A (or adding an A/B toggle) is a small change, not a rewrite. Concretely: a single `list_axis` notion (relationship, in B) and a `knob` set (place, mode, phase, in B) — `_reload` builds the list rows by iterating the list axis at the fixed knob values. In A the axis and one knob swap. Keep the row-render and draw code axis-agnostic (a row is `<label> <7-swatch strip>` regardless of what the label names).

## The picker surface (B)

**List:** the 6 relationships `mono amber ember coral sage teal`, each rendered as its 7-role swatch strip (`bar sep tabs active windows cap text`) at the current `place`/`mode`. `↑↓`/`jk` moves; the persisted relationship is marked `❯`. Below the list: the `off` row (legacy look) and the **anchor row** (the persisted `(relationship, place, mode)` frozen at open, at the bottom, for A/B comparison — unchanged behavior from v3.1/v3.2).

**Knobs (adjustments zone):**
- `place` — `bar tabs cap low high`, cycled with `p` (shift `P` reverses). Turning it re-renders all 6 rows.
- `mode` — `literal derived`, cycled with `m` (shift `M`). `low`/`high` force `derived` (the CLI already enforces this; the picker should skip `literal` when place is `low`/`high`, or show it greyed).
- `phase` — degrees, `←→` (5°/press, coalesced), as today.
- `seed` — `b` opens the RGB sliders / typed-hex entry, as today.

**Removed from the picker:** `rotate` (retired engine-wide) and the `vividness`/`shape`/`ease`/`contrast` knobs. In Phase 1 only `phase` shapes the curve, so those four are no-op knobs — they are **hidden from the picker** (not deferred/greyed; simply not shown). They remain CLI-settable via `setup theme … --vividness …`. Net: a simpler picker than v3.

**Kept as-is (adapted):** `z` shake (now randomizes relationship + place + mode + phase), the flash / lit-first feedback on knob changes, the live preview bar + ShellFish/iTerm tab chip, `a` apply-preview (live, no save), `⏎` save, `r` reset knobs, `Esc`/`q` revert+close, the anchor snapshot + `❯` marker, and the raw-tty input machinery (readkey, drain-coalescing, DECSET-2026 atomic paint, signal-handler cleanup).

**Literal indication.** In A, `✦` marked the literal rows. In B, mode is a knob, so there is no per-row literal distinction — all rows share the current mode. When `mode = literal`, optionally overlay `✦` on the placed-role swatch cell of each row (the cell that renders the seed verbatim); minor polish, not required for the first cut. The status-bar `✦` mark (seed home base) is unrelated and unchanged.

**Save/apply semantics.** `⏎` on a relationship row persists `(that relationship, current place, current mode)` via the config-loaded child calling `tmux-lives setup theme <rel> --place <place> --mode <mode>` (plus `--phase`), silenced — the same one-child-per-action pattern the picker already uses (the process runs under `--no-config`, which can't write universals). The anchor row saves its frozen snapshot verbatim. `a` apply-preview pushes the live palette to the bar via `__tmux_lives_theme_apply_live` without saving.

## The engine-call fix (in `__tcz_thp_reload`)

Regardless of A/B, `_reload` must be rewritten to the v4 engine:
- iterate `__tmux_lives_theme_relationships` (not `_theme_schemes`);
- call the 9-arg `__tmux_lives_theme_palette $seed $rel $place $mode $phase $viv $shape $ease $contrast`, where `$viv/$shape/$ease/$contrast` are the values `_init` READ from the stored universals (defaults `balanced/arc/linear/auto`) — the picker no longer lets you *change* them, but it passes the stored values through so the preview stays faithful and matches what the CLI would render;
- **delete** the `__tmux_lives_theme_ring` call and the `__tcz_thp_rotpal` rotation permutation (v4 accents come from the palette's own 7 roles — there is no separate ring, and no rotation);
- the reload cache key becomes `"$seed|$place|$mode|$phase"` (relationship is the list axis, iterated; the removed knobs drop out).

`_init` drops the `tmux_lives_theme_rotate` read and adds `tmux_lives_theme_place` (default `bar`) / `tmux_lives_theme_mode` (default `derived`) reads. The anchor snapshot captures `place`/`mode` instead of `rotate`.

## Testing

The picker's pure builders are unit-testable in `test-tmux-categorize.fish` (the existing pattern); the interactive loop is runtime-only (live smoke).
- Pure-builder tests for any new/changed row/label builders and the `_reload` blob shape (6 rows, 7-role palettes, place/mode in the cache key).
- **Grep guards** (env-independent, source-based): the picker body contains no `__tmux_lives_theme_ring`, no `__tmux_lives_theme_schemes`, no `__tmux_lives_theme_rotpal`/`_rotate`, and no 8-arg palette call; `fish -c` count in the picker body stays pinned (universal writes go through config-loaded children).
- A `fish --no-config` run of the categorize suite must be **0 stderr bytes** (the Phase-1 review caught a broken v3 block spraying stderr; the picker rewrite must not reintroduce that).
- Live smoke (user, after the build ships): the 6 relationships render with correct swatches, `p`/`m` re-render, `phase`/`z`/`b`/anchor/apply/save all work, `M-k` and `setup theme` no-arg both open it.

## Open items

- **A/B verdict is provisional.** B ships first; if it doesn't feel right in use, the switchability seam makes A (or a toggle) a cheap follow-up. Do not over-invest in B-specific cleverness that the seam would have to unwind.
- **`p`/`m` key choice.** `p`/`m` are mnemonic and free (rotate's `o` and the four removed-knob keys `v/s/e/d` are all freed). Confirm no collision with the raw-tty readchar classification during live smoke.
- **Literal `✦`-on-cell overlay** is optional polish, not required for the first cut.
- The four hidden knobs (`vividness/shape/ease/contrast`) are no-ops until a future phase wires them to the curve; that is out of scope here and not promised.
