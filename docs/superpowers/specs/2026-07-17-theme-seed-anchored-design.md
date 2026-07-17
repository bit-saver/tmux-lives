# Theme v3.1: seed-anchored palette + picker layout A

**Date:** 2026-07-17 (from the user's live smoke of the v3 picker)
**Status:** approved in-session — core decisions made by the user
**Amends:** `2026-07-16-theme-gradient-map-engine-design.md` (role ladder + polarity sections)
**Supersedes:** the polarity model of `2026-07-16-theme-polarity-seed-entry-design.md`
(its raw-entry machinery survives; its "seed = hue only" contract does not)

## Problems (observed live)

1. **The bar is always near-black (or near-white).** Roles are pinned to absolute
   slots on a 0.20→0.92 lightness ramp; `bar` owns t=0.00, so it renders L≈0.20
   regardless of seed — and the chroma floor (C .030) makes it nearly grey too.
   `light` polarity just swaps the ramp ends → L≈0.92. "Dark/light basically
   means choose black or white."
2. **The seed is invisible.** It donates hue only; its lightness and chroma are
   discarded, so the picked color never appears anywhere in the rendered theme.
   Same-hue seed changes are no-ops; an RGB slider picking a color whose R/G/B
   mostly don't matter is incoherent.
3. **The scheme concept drifted.** The intent was: a scheme = a collection of
   companion colors that pair well with the seed, seed included. The absolute
   ramp made schemes free-floating gradients the seed never touched.
4. Picker UX (user list): unlabeled values, unclear global-vs-scheme knob scope,
   no apply-without-saving, no reset, no color-placement control, tiny seed
   swatch, run-on key legends.

## Core model change: the seed IS the bar

`__tmux_lives_theme_palette` output stays 7 role hexes (bar sep tabs active
windows cap text), but the derivation changes:

- **bar = the seed, exactly** (OKLCH untouched; phase/schemes/vividness never
  move it). The RGB sliders become honest: all three channels land on the bar.
- **Direction** `dir` (which side companions + text sit on):
  - `auto` (default): seed L < 0.55 → +1 (companions lighter, text light);
    else −1 (darker, text dark).
  - forced `lighter` / `darker` override auto (user taste for mid seeds).
- **Supporting roles cluster near the seed** — gentle ΔL offsets, hue/chroma do
  the differentiation (non-text elements don't need extreme lightness
  contrast). Defaults, in the ONE adjustable ladder function (successor of
  `__tmux_lives_theme_roles`, now `<role> <t> <dL>` per line):

  | role | t (arc position) | ΔL |
  |---|---|---|
  | sep | 0.15 | +0.06·dir |
  | tabs | 0.30 | +0.10·dir |
  | active | 0.50 | +0.15·dir |
  | windows | 0.60 | +0.17·dir |
  | cap | 0.80 | +0.22·dir |

  L clamped to [0.05, 0.95].
- **text jumps to the contrast side**: L = clamp(Ls + dir·0.45, 0.05, 0.97),
  C 0.03, hue at arc end (t=1.0). Auto always keeps ≥~0.42 ΔL (threshold 0.55
  splits the room; the clamp can shave at most ~0.03); a FORCED direction is
  honored even when the clamp shaves contrast — the user's override wins,
  they can see the result.
- **Hue**: role hue = seedH + a0 + (a1−a0)·ease(t) + phase. Scheme arcs
  (`mono`…`full`), `--phase`, and `--ease linear|cubic` are unchanged — but
  they now move ONLY companions; the bar hue is immune.
- **Chroma anchors at the seed**: arc shape → C(t) = Cs + (cmax − Cs)·sin(π·t)
  (ends near the seed's own chroma, peak mid-arc at the vividness target);
  flat shape → C = cmax for all supports. cmax per vividness unchanged
  (soft .075 / balanced .105 / vivid .130). text C fixed 0.03.
- **Rotation** `rot ∈ 0..4`: cyclically permutes the five COMPUTED support
  colors across (sep tabs active windows cap) — role_i takes
  sample[((i − rot) mod 5) + 1]. Compute-then-permute (permuting the ladder
  params instead would be a no-op). bar and text never rotate. ShellFish tabs
  wear whatever the `tabs` role holds after rotation.
- Unchanged: `off` legacy branch, scheme-with-no-seed → legacy branch,
  `__tmux_lives_theme_schemes`, gamut clamp, `contrast_fg` for the cap fg.

**Restored concept (user-stated, goes in the docs):** a scheme is a set of
companions for the seed; the seed appears in every scheme. Scheme identity
lives in strip cells 2–7; cell 1 is identical on every row BY DESIGN.

### Saved alternatives (not chosen — revisit if seed-as-bar disappoints live)

- **B. Seed slots by lightness:** keep a full dark→light ramp but bend it to
  pass exactly through the seed at its own L; the nearest role renders the
  seed; the bar keeps a dark slot. (Seed visible, bar still dark.)
- **C. Hue-only seed + bar-L knob:** keep the hue-only contract, add an
  explicit bar-lightness knob; seed picker becomes hue-only. (Exact color
  still never appears.)

## Picker: layout A (mocked + approved via visual companion 2026-07-17)

Popup grows **52×20 → 52×26** at ALL THREE open sites (fragment `themekey`
bind, `__tmux_lives_theme_cmd` no-arg, `__tcz_modal_run` `k`). Frame = exactly
26 rows (final row without `\n` — the top-border scroll gotcha).

Rows (title/bottom borders included in the 26):

1. top border: `╭─ theme ─ preview ─…╮` (title **bold**)
2. **ShellFish tab chip row** (reserved; see below)
3. fake status-bar preview row (existing `__tcz_thp_preview`, from the
   cursor row's palette)
4. zone separator `├─ adjustments · apply to all schemes ─…┤` (label **bold**)
5. labels row 1 (muted, uppercase): `SEED PHASE VIVIDNESS SHAPE`
6. values row 1: seed hex rendered ON its own swatch bg · `+N°` · vividness ·
   shape
7. labels row 2: `CONTRAST ROTATE EASE`
8. values row 2: `auto|lighter|darker` · `0..4` · ease
9. zone separator `├─ scheme · companion sets for the seed ─…┤` (**bold**)
10–19. ten scheme rows (marker + 7×2-col strip + name)
20. `off — legacy look` row
21. zone separator
22–24. key legend, THREE rows of FOUR aligned key/label columns:
    `↑↓ scheme · ←→ phase · v vividness · s shape` /
    `e ease · d contrast · o rotate · b seed` /
    `a apply · ⏎ save · r reset · esc close`
25. status/note row
26. bottom border

Layout decisions from the mock review:

- Zone titles (and the frame title) render **bold** (SGR 1).
- The **selection band darkens** — near-black distinct from any scheme color
  (it read as "part of the scheme" at the current grey). This changes the
  SHARED `sel-bg` value in the tl theme palette (`__tcz_theme`), so the
  session picker's band darkens too (consistent chrome); the `▐` brand marker
  stays the primary selection cue in both.
- Labels sit ABOVE their values, columns aligned across both rows of each
  pair. The old one-line `__tcz_thp_info` format is retired.

### Global-vs-scheme clarity (structural answer)

ALL knobs are global (they are universals); only ↑↓ selection is per-row. The
zone separators say so in prose ("apply to all schemes" / "companion sets for
the seed"), and **every knob change now batch-recomputes ALL scheme strips**
(today `←→` phase recomputes only the cursor row, leaving the other strips
stale — that artifact fed the confusion; the drain-coalescing is kept, the
settle triggers the full batch reload).

### Apply / save / revert semantics

- **`a` apply**: pushes the cursor scheme + current knobs to the live bar as
  tmux `@options` only (via the apply-live path with explicit values) — NO
  universals, NO fragment rewrite. Status row:
  `● previewing <scheme> — not saved yet · ⏎ save · esc revert`.
- **`⏎` save**: persists via the CLI (universals + fragment + live apply),
  silenced, as today. Closes.
- **`esc`/`q`**: if a live preview is active, re-apply the PERSISTED state
  first, then close. Cancel is always safe.
- **`r` reset**: knobs → defaults (phase 0, vividness balanced, shape arc,
  ease linear, contrast auto, rotate 0). The SEED is not touched. Like any
  knob change, nothing persists until ⏎.
- **`o` rotate**: cycles rot 0→4→0; ROTATE field + strips + preview update.
- **`d` contrast**: cycles auto → lighter → darker.

### ShellFish tab chip (preview row 2)

- Detected ONCE at picker open: iterate `list-clients` (pid + tty) →
  `__tcz_client_is_shellfish` (the production detection that colors real
  tabs; `tmux_lives_fake_environ` seam keeps it testable).
- Detected → render a chip in the **tabs role color** with the real title the
  active session would get (`__tcz_session_title` output), e.g.
  `rocket: tmux-lives (C)`; contrast fg via `contrast_fg`.
- Not detected → the row renders empty (geometry is static; the Mac simply
  shows nothing). If detection disappoints live, fallback is a one-line flip
  to always-show, or a toggle — deferred until evidence.

### Seed screens (sliders + typed hex): big swatch

- The slider screen gains a **large swatch block** (4 rows × ~12 cols) beside
  readouts: hex (bold), `hue N° · L 0.NN · chroma 0.NNN`, and the copy
  "rendered as-is on the bar; companions derive from it" (replaces the old
  "only its HUE drives the theme" contract line — that contract is gone).
- The typed-hex screen gets the same enlarged swatch treatment at
  parse-complete (readouts extend from hue-only to hue/L/chroma).
- Slider mechanics unchanged (↑↓ channel, ←→ ±8 coalesced, t typed hex,
  ⏎ apply via `setup color`, esc cancel; stty re-assert INSIDE drain loops).

## Shared key-legend convention (all popups)

One footer style everywhere: aligned key column (tan `key` role) + label
column (muted), fixed pitch, N pairs per row — a pure builder in the
categorizer (testable with `string length --visible`). Applied to:

- theme picker (3 rows × 4 pairs, above),
- seed slider screen (`↑↓ channel · ←→ adjust · t type hex` / `⏎ apply ·
  esc cancel`),
- typed-hex screen,
- **session picker** (`__tcz_popup`): gains a one-row legend it currently
  lacks — `↑↓ move · ⏎ switch · x kill · esc close` (costs one preview row).

The `M-m` launcher legend is already tabular — untouched.

## CLI / storage / plumbing

- `setup theme` flags: **`--contrast auto|lighter|darker`** (new universal
  `tmux_lives_theme_contrast`, default `auto`) and **`--rotate <0-4>`** (new
  universal `tmux_lives_theme_rotate`, default `0`) REPLACE `--polarity` and
  `--range`. `--phase`, `--vividness`, `--shape`, `--ease` unchanged.
  Validate-all-before-mutate as today; no-arg state print, `theme list`, and
  apply-live carry the new knobs.
- `__tmux_lives_theme_palette` signature: `seedHex scheme phase vividness
  shape ease contrast rotate` (lrange args die with `--range`).
- Fragment argv stays 19 slots: **18 = themecontrast, 19 = themerotate**
  (replacing themerange/themepolarity). The 7 role `@options` are unchanged in
  shape — rotation/contrast are palette INPUTS, already folded into the role
  colors the fragment and `theme_apply_live` emit.
- **Migration** (idempotent, in `_tmux_lives_post_update`, same pattern as the
  v2→v3 shim): erase `tmux_lives_theme_polarity` and `tmux_lives_theme_range`
  (their meanings do not survive the model change; contrast starts `auto`,
  rotate `0` for everyone), one notice line.
- Copy updates: `__tcz_theme_picker` docstring, slider/hex screen titles,
  setup-help theme row (`--contrast`/`--rotate` replace `--polarity`; range
  gone), README Theming section (incl. the restored scheme concept), CLAUDE.md.

## Testing (repo conventions: TDD, isolated sockets, seams)

- **Engine** (install suite): bar hex == seed hex EXACTLY for every scheme ×
  contrast × rotation; support ΔL ladder signs/clamps; auto threshold at
  L 0.55 both sides; forced direction honored; text ΔL floor (auto paths);
  chroma anchor (grey seed → low-C companions near ends); rotation is an
  exact cyclic permutation of the 5 support colors (compute-then-permute
  pinned by comparing rot r against rot 0 reindexed); phase/vividness never
  move the bar.
- **CLI**: `--contrast`/`--rotate` validation + persistence + state print;
  `--polarity`/`--range` now unknown flags; migration erases the two dead
  universals idempotently.
- **Picker pure builders**: labeled kv zone rows (label/value column
  alignment, widths ≤ IW), legend builder (pitch, visible widths), tab chip
  builder (chip + empty variants), status row, geometry (frame exactly 26
  rows, last row no `\n`).
- **Seams**: `tmux_lives_tmux_socket` for apply-live; `tmux_lives_fake_environ`
  for chip detection; universal save/clear guards at the TOP of touched test
  sections (the 2026-07-14 leak lesson); never kill a running suite.
- **Grep-guards**: quoted-math-index ban stays green; add one pinning zero
  references to the dead `tmux_lives_theme_polarity`/`_range` in source.
- Runtime-only (deferred to user live smoke): raw-tty feel of `a`/`o`/`d`/`r`,
  chip on a real ShellFish attach, 52×26 at the three open sites.

## Out of scope

- Phase 4 harmonized mode indicators (unchanged, still optional).
- Always-show/toggle for the tab chip (only if detection fails live).
- Whole-bar re-theming beyond the existing roles; `M-m` launcher legend.

## Doc lifecycle

After this ships: prune `2026-07-16-theme-polarity-seed-entry-design.md`
(vault + repo, user-confirmed) — its polarity model is dead and its seed-entry
UX is re-specified here. The gradient-map engine spec stays (base model:
arcs, sampler, off-mode, fragment plumbing) with this spec as the amendment.
