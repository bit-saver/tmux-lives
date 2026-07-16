# Theme engine v3 — Phases 2+3: always-on cutover + theme picker

**Date:** 2026-07-16
**Status:** approved (decisions resolved with the user in-session; picker layout A chosen via visual companion) — ready for implementation planning
**Extends:** `2026-07-16-theme-gradient-map-engine-design.md` (the engine model; Phase 1 shipped to main @ `698cc74`)
**Supersedes at ship time:** every v2 cap-engine spec (`2026-07-12-cap-color-formulas-design.md`, `2026-07-12-cap-color-oklch-redesign-design.md`, `2026-07-13-cap-picker-polish-design.md`, `2026-07-13-cap-picker-v2-design.md`, `2026-07-14-cap-picker-marker-design.md`) — prune them (repo + vault) when this branch merges.

## Summary

Make the gradient map the **always-on** engine and give it the picker. Phase 2 flips the default (`tmux_lives_theme` unset → `mono`), deletes the entire v2 geometric-harmony engine, migrates the old `cap*` universals, and reroutes the ShellFish tab OSC through the `tabs` role. Phase 3 replaces the cap-picker with the **theme picker** (layout A: scheme catalog + live fake-bar preview). One branch, one deploy: after `fisher update` the user lands on a mono-themed bar and tunes everything from the picker — resolving the "args aren't listed / unsure what values" complaint that motivated this.

## Resolved decisions (2026-07-16, do not re-litigate)

1. **Always-on.** Every seeded bar renders from the gradient map; default scheme `mono`. The v2 geometric machinery is deleted.
2. **`off` = legacy escape hatch.** `theme off` survives as a stored token: derived status bar (`__tmux_lives_derive_status`) + neutral cap (`colour238` + contrast fg) + `default`-seeded role options — the pre-v3 appearance with no geometric palette behind it.
3. **Migration = reset to mono + one-line notice.** No nearest-arc aliasing. `cap_vividness` maps 1:1 (`subtle`→`soft`, others unchanged); `cap_key`→`theme_key` (same bind, now the theme picker); `cap`/`cap_wheel`/`cap_role` erased.
4. **Picker = layout A** (list + live bar preview), chosen from three mocked layouts rendered with the user's real palettes.
5. Carried from Phase 1: role→`t` ladder and arc direction stay easily adjustable (the user's withheld placement/ordering tweak is still expected after live use); mode indicators stay static; claude-coral window tint stays.

## Phase 2 — always-on cutover

### Semantics

- `__tmux_lives_key tmux_lives_theme mono` becomes the effective read everywhere (fragment render, `theme_apply_live`, CLI no-arg state). Unset = `mono`.
- `setup theme off` now **stores** the token `off` (`set -U tmux_lives_theme off`) instead of erasing; the fragment and `theme_apply_live` treat `off` (or an unusable seed) as the **legacy branch**: `status-style` from `derive_status`, `@tmux_lives_cap_bg colour238` + contrast fg, `@tmux_lives_bar_bg` = derived bg (`colour236` fallback), the five role options seeded `default`/`''`. A stored scheme with no seed also falls back to this branch (unchanged from Phase 1's guard behavior).
- `setup theme <scheme>` no longer needs the no-seed error to block always-on defaults — the error stays only for the explicit-scheme command path (you can't *choose* a scheme without a seed; the *default* mono with no seed just renders legacy until a seed exists).

### Removal list (delete, with tests)

- Install side: `__tmux_lives_palette`, `__tmux_lives_target_hue`, `__tmux_lives_interp7`, `__tmux_lives_rgb_to_ryb_hue`, `__tmux_lives_ryb_to_rgb_hue`, `__tmux_lives_hsl_hue`, `__tmux_lives_hsl_to_rgb`, `__tmux_lives_cap_valid`, `__tmux_lives_cap_list`, `__tmux_lives_cap_picker`, `__tmux_lives_cap_apply_live`, `__tmux_lives_cap_cmd`; `setup cap` dispatch case + help row; the top-level hidden-shortcut list is untouched (cap was never in it).
- Categorizer side: `__tcz_cap_families`, `__tcz_cap_restore`, `__tcz_cap_swatch_line`, `__tcz_cap_sep`, `__tcz_cap_dma`, `__tcz_cap_inert`, `__tcz_cap_picker` (+ its nested helpers), the `cap-picker` verb. **`__tcz_theme` (the tl UI-chrome palette) stays** — the new picker uses it.
- Fragment argv **renumbered** (all call sites + tests are ours): 1-11 unchanged (`cat pkey skey color invert modalkey scratchkey resizekey statusposkey statusviskey cursorstyle`), then `12 themekey` (was 15 capkey), `13 theme`, `14 themephase`, `15 themeviv`, `16 themeshape`, `17 themeease`, `18 themerange`. The old 12 cap / 13 vividness / 14 wheel / 16 caprole slots are gone.
- `setup keys --cap-key` → `--theme-key`; universal `tmux_lives_cap_key` → `tmux_lives_theme_key` (default `M-k`).
- The engine-facts test block that mirrored `__tcz_cap_inert` (install suite) goes with the cluster; Phase-1 theme tests stay.

### Migration shim

In `_tmux_lives_post_update` (runs on every `fisher update`), **idempotent** — acts only when any old universal exists:

- `tmux_lives_cap_vividness` set and `tmux_lives_theme_vividness` unset → map (`subtle`→`soft`, `balanced`/`vivid` verbatim).
- `tmux_lives_cap_key` set and `tmux_lives_theme_key` unset → copy verbatim.
- Erase `tmux_lives_cap`, `tmux_lives_cap_vividness`, `tmux_lives_cap_wheel`, `tmux_lives_cap_role`, `tmux_lives_cap_key`.
- If a cap scheme was erased, print one line: `tmux-lives: cap scheme '<x>' has no v3 equivalent — theme is mono; tune with 'tmux-lives setup theme'`.
- `tmux_lives_theme` itself is left alone (unset = mono; a Phase-1 tester's stored scheme survives).

### ShellFish tabs role

- The single source of the effective tab colour becomes the live option `@tmux_lives_tabs_color` (seeded by the fragment since Phase 1: tabs-role sample when themed, `''` under legacy/off). `__tcz_recolor` resolves it first (capture+quote; empty-cache gotcha) and falls back to its colour argument (the baked raw seed) when empty — so themed bars tint ShellFish tabs with the `tabs` sample and `off` keeps the raw seed, with zero changes to the dedup/heal/emit plumbing (they receive whatever `__tcz_recolor` resolved).
- Touchpoints all flow through `__tcz_recolor` already (on-attach force, tick dedup, heal backstop, `setup color`/`--apply` force) — only the resolution point changes.
- `setup color` keeps its name and flags; messaging calls the value the **seed** ("seed set to #… (drives the theme + ShellFish tabs)").

## Phase 3 — the theme picker (layout A)

### Surface

- New categorizer verb `theme-picker` + `__tcz_theme_picker` cluster in `functions/tmux-categorize.fish` (zero new files). Popup ~**52×24** at all three entry points: the `themekey` fragment bind (`M-k`), `__tcz_modal_run` case `k` (modal legend row renamed "theme"), and `setup theme` **no-arg inside tmux** (outside tmux it prints the current state, as today; the state print moves behind that gate).
- Layout, top to bottom, frame exactly filling the popup (v2 lessons: final row without `\n`; fixed visible widths; single-quoted hexes irrelevant here but SGR resets bounded):
  1. Title edge: `╭─ theme ─ preview …╮`.
  2. **Fake bar preview** (1 row): host cap (glyph + `host_short`) with slant, window list (`claude` in coral, an inactive name in the `windows` colour, current name bold in `text`), `•` separators in `sep`, centre `✦ name` (`✦` in `cap`, name in `text`), right slant + clock cap — all truecolor SGR from the **cursor row's** palette, cap fg via `contrast_fg`. Re-rendered on every cursor move / knob change.
  3. Info line: `seed #…… · phase +N° · <vividness> · <shape> · <ease>`.
  4. Separator `├──┤`.
  5. **11 rows**: the 10 schemes (`▐` selection marker + 7-swatch strip + name) + `off — legacy look` (single derived-bg swatch band).
  6. Separator, two footer key lines (`↑↓ scheme · ←→ phase · v vivid · s shape · e ease` / `b seed · enter apply · esc close`), status line, bottom edge.

### Behavior

- **Restore-on-open:** cursor lands on the stored scheme (or `off`); knobs initialize from the universals.
- **`↑↓`** move (skip nothing — every row is real); preview re-renders from cached palettes (no subprocess).
- **`←→` phase:** coalesce — drain all buffered arrow presses into one net delta (**5° per press**), update the info line immediately, then ONE `fish -c` recompute of the cursor scheme's palette (net-delta coalescing is semantically lossless here, unlike the reverted switcher input-coalescing). Phase applies to the whole catalog on the next full reload.
- **`v`/`s`/`e`:** cycle vividness (soft→balanced→vivid), shape (arc/flat), ease (linear/cubic); each triggers a full batch reload (one `fish -c` computing all 10 palettes — the `__tcz_cap_reload` pattern) + preview redraw.
- **`b` seed:** cooked `read` on the popup tty (modal `b` precedent), validated by `__tmux_lives_seed_hex` shape rules; applies **immediately** via `setup color` (which re-renders the fragment + recolors ShellFish), then a full palette reload. Status line notes the seed changed even if the user then Escapes.
- **Enter:** apply via the CLI — `tmux-lives setup theme <scheme> --phase N --vividness V --shape S --ease E` (all effective values, idempotent), output silenced (`>/dev/null 2>&1`, the v2 flash lesson). On the `off` row: `setup theme off`.
- **Esc/q:** close without applying (except a `b` seed change, which already applied — stated on the status line).
- **Range** stays CLI-only (no `r` key — YAGNI).

### Data flow

Init: one config-loaded `fish -c` echoes seed(hex), theme, phase, vividness, shape, ease, range (via `__tmux_lives_key` + `__tmux_lives_seed_hex`). Batch: one `fish -c` loops the 10 scheme tokens calling `__tmux_lives_theme_palette` (+ `__tmux_lives_contrast_fg` per cap) into per-scheme caches; the scheme token list lives in ONE place install-side (a `__tmux_lives_theme_schemes` helper both `theme_valid`/`theme_list` and the picker batch use — kills the duplicated-token-list smell found in the v2 reload).

## Help + docs

- `__tmux_lives_setup_help_lines`: the `theme` entry follows the house style — command row plus one indented row per flag with values and defaults, no ellipsis:
  `theme [<scheme>|list|off]   gradient-map bar theme; no-arg=picker` then `--phase <deg>` / `--vividness soft|balanced|vivid` / `--shape arc|flat` / `--ease linear|cubic` / `--range <L0,L1>` rows with `(default: …)` notes. The `cap` row is deleted; `keys` row `--cap-key` becomes `--theme-key`.
- README: theming section updated (always-on, picker, migration note); cap section removed. CLAUDE.md status updated at merge.

## Testing

- Pure: migration shim (all combinations of old universals, idempotency), legacy-branch render values, argv renumbering (fragment tests updated wholesale), `__tmux_lives_theme_schemes` single source, `__tcz_recolor` tabs-color resolution (set/empty/fallback), picker line builders (preview row, scheme row, off row — fixed visible widths at every state), restore index.
- `-L` socket: fragment parse + `show -gv` for legacy and themed modes; recolor resolution against a live option; CLI off/scheme round-trips.
- Removal: suites must show zero references to deleted function names (grep guard), and the install suite's deleted cap sections go with them.
- Interactive raw-tty loop, cooked `b` read, live popup geometry: runtime-only — the user's live smoke after `fisher update` (finally through the picker, which was the point).

## Out of scope

Phase 4 items (harmonized mode indicators, per-hue lightness nudge, extra presets); a range key in the picker; per-tab ShellFish theming beyond the single OSC; any change to the engine math or role ladder (that waits for the user's live placement/ordering feedback).
