# Theme picker: current-theme anchor row + shake key + lit-first knob feedback

**Date:** 2026-07-19 (from the user's extended live use — the scheme system
itself is KEPT as-is by their explicit call)
**Status:** approved in-session (design presented and confirmed)
**Extends:** `2026-07-17-theme-seed-anchored-design.md`,
`2026-07-17-picker-performance-flash-design.md`

## Motivation (user-stated)

1. **(Priority)** The picker gives no indication of which scheme is currently
   applied, and knob-twiddling walks you away from it with no way back — you
   cannot A/B a candidate against your current theme.
2. Phase × scheme is a redundant, incremental exploration space (proven:
   schemes are phase-equivalent up to arc WIDTH; cool ≈ warm+52°, fire ≈
   wide+35°). Wanted: ONE press that produces a radically different combo.
3. Remaining knob lag is at the fish-math floor (~150 ms first visit / ~40 ms
   cached); the flash currently appears AFTER the recompute, so a press feels
   dead until the batch lands. Wanted: the changed field lights up FIRST and
   stays lit until the change completes.

## 1. Anchor row + current indicator

- **Snapshot at open:** immediately after `__tcz_thp_init`, capture the
  persisted state into anchor locals: `anch_scheme anch_phase anch_viv
  anch_shape anch_ease anch_contrast anch_rotate` (= the just-initialized
  knob values, before any twiddling). The snapshot NEVER changes during a
  picker session (Enter saves and closes; a fresh open re-snapshots).
- **Anchor strip, computed ONCE at open:** engine palette with the snapshot
  values (rotate included — pass `anch_rotate` straight to
  `__tmux_lives_theme_palette`; this is a one-shot call, not the hot path),
  plus its cap contrast fg. `off`, unset (→ `mono` via init defaults), or a
  scheme-with-no-seed render the legacy band exactly like the off row.
- **Row placement + label:** the anchor is the FIRST row of the scheme zone
  (directly under the `scheme ·` separator, above `mono`). Name:
  `<anch_scheme> · current` (e.g. `wide · current`), prefixed by the
  muted-yellow `❯` current marker (the switcher's convention). Rendered via
  `__tcz_thp_row`'s new `current` flag (below).
- **`__tcz_thp_row` gains an optional 4th arg `current`:**
  `__tcz_thp_row <hexes> <name> <selected> [current]` — when `current` = 1,
  the name is prefixed `❯ ` in the switcher's existing current-marker SGR
  (copy it from `__tcz_popup_list_lines` at implementation time — do not
  invent a new shade), independent of selection state. Width grows by
  exactly 2 visible cols on such rows.
- **Current indicator on the list:** the list row whose scheme token equals
  `anch_scheme` also renders with `current` = 1 (scheme-level marker; the
  exact knob snapshot lives in the anchor row).
- **Selection indexing:** anchor = index 0; the 10 scheme rows = 1..10; off =
  11. The cursor STARTS at 0 (the anchor). `__tcz_thp_restore` is DELETED
  (its job — restore-to-saved-scheme — is superseded by starting on the
  anchor); its tests go with it.
- **Cursor-row palette semantics:** when the cursor is on the anchor, the
  preview + tab strip render from the FROZEN anchor palette; `a` applies the
  SNAPSHOT via the 7-arg apply-live child
  (`fish -c '__tmux_lives_theme_apply_live $argv' $anch_scheme … $anch_rotate`);
  Enter saves the snapshot via the CLI child with the snapshot flags. On
  list/off rows, behavior is unchanged (current knobs). This is the
  flip-flop loop: candidate row + `a`, anchor row + `a`, repeat.
- **Geometry:** frame 26 → **27 rows** (row 10 = anchor; schemes 11-20; off
  21; zsep 22; legend 23-25; note 26; bottom 27). Popup `-w 52 -h 27` at ALL
  THREE open sites (fragment themekey bind, CLI no-arg open, modal `k`).
  The kv zone stays at rows 5-8 (lit-first depends on this).

## 2. Shake key — `z`

- `__tcz_popup_readkey`: byte case `7a → z` (docstring updated).
- Picker dispatch `case z`: cursor jumps to a random LIST row
  (`set sel (random 1 10)` — never the anchor or off), `set phase
  (math "(random 0 71) * 5")` (0-355° in 5° steps), `set rotate
  (random 0 4)`. Vividness/shape/ease/contrast untouched. Then flash both
  changed fields (`set flashfield 'phase rotate'`), lit-first repaint,
  `__tcz_thp_reload`.
- **Multi-field flash:** `flashfield` becomes a space-joined LIST.
  `__tcz_thp_kv`'s match changes from a single case-insensitive compare to:
  the pair flashes when its lowercased label is `contains`-ed in
  `(string split ' ' -- $flashfield)`. All existing single-token setters
  work unchanged.
- **Legend:** `z shake` replaces the `↑↓ scheme` hint (arrow nav is
  universal); rows become
  `←→ phase · v vivid · s shape · e ease` /
  `d contrast · o rotate · z shake · b seed` /
  `a apply · ⏎ save · r reset · esc close` (still 3 rows × 4 pairs,
  pitch 12).

## 3. Lit-first knob feedback

- New nested helper `__tcz_thp_litkv` (`--no-scope-shadowing`): rebuilds the
  two kv pairs from the CURRENT knob vars + `flashfield` and repaints frame
  rows 5-8 in place (`\e[5;1H` … `\e[8;1H`, each line via `__tcz_thp_ln`,
  the whole repaint wrapped in DECSET-2026 with `\e[K` per line — no full
  clear, no scroll).
- Every knob arm calls it AFTER updating the value + `flashfield` and BEFORE
  `__tcz_thp_reload`: `v/V s/S e/E d/D o/O`, the two `←→` arms (after drain
  settle), and `z`. The sequence per press: value updates + field lights up
  instantly → recompute runs (zone already lit) → full draw (flash still
  set) → the usual ~0.5 s timed clear.
- `r` (reset) and the seed screens keep their current behavior (no lit-first;
  `r` flashes nothing by design).

## Testing

- `__tcz_thp_row` current flag: `❯ ` prefix present iff flag set, in the
  current-marker SGR; visible width +2 exactly; selection × current all four
  combinations sane.
- kv multi-field flash: `'phase rotate'` flashes BOTH pairs and nothing
  else; single-token behavior unchanged; width-neutral test still holds.
- Readkey: `z` token; docstring lists it.
- Static guards: picker body contains `case z` with two `random` calls;
  `__tcz_thp_litkv` defined and called from the knob arms (pin a count);
  `-h 27` at all three open sites with zero stale `-h 26`;
  `__tcz_thp_restore` gone repo-wide (grep).
- Anchor semantics are loop-internal → static pins: `anch_scheme` captured
  after init; the anchor `a`/Enter branches reference the `anch_*` vars.
- Full 8-suite gate under plain AND `--no-config` fish.

## Out of scope

- Persisting shake results (they persist only via the normal `a`/⏎ flow).
- Reducing the recompute floor further; anchor-row live updates after ⏎
  (Enter closes the picker).
- Any change to the scheme/engine model (user: keep as-is).
