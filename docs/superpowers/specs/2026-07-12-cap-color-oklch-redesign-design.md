# Cap-color OKLCH palette engine — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm), pending plan
**Base:** `main` @ `404e2a4` (cap-color v1 shipped)
**Supersedes:** the color-derivation engine of `2026-07-12-cap-color-formulas-design.md` (v1). v1's storage/CLI/picker surfaces are kept and extended; the muddy HSL derivation is replaced by a perceptual, palette-based engine.

## Motivation

Cap-color v1 rotates hue in **HSL** and reuses the bar's own low saturation, so a dark/desaturated bar (the user's `#36442d`) yields muddy caps and a "complement" that is muddy purple. Two facets were missing:

1. **Perceptual uniformity.** HSL's lightness/saturation don't match human vision, so hue rotation swings perceived brightness/vividness unpredictably. Fix: work in **OKLCH** (perceptually uniform, closed-form, fish-implementable — validated).
2. **A palette, not one flat accent.** v1 derives a single cap color at a fixed lightness. A scheme that reads as *harmonious* is a **coordinated multi-color palette with a value ramp** (dark → muted mids → vivid accent → light), the roles varying in lightness/chroma — not a menu of equally-bright single hues. Fix: a **role-structured palette generator**.

**Validated in fish 4.7.1:** the full OKLab/OKLCH pipeline round-trips sRGB bit-exact (`#ff0000` → OKLCH `L0.628 C0.258 H29.23` → `#ff0000`). Real palettes for `#36442d` (RYB) look harmonious — e.g. triadic accent `#f66336` (vivid orange-red), tetradic {`#516eb7` blue, `#ee5475` pink-red, `#bc6808` amber} on the green bg.

## Core principles

1. **Perceptual space (OKLCH).** Convert sRGB↔OKLCH via the canonical Ottosson pipeline; do all hue/chroma/lightness work there.
2. **Decouple the channels.** Only *hue* derives from the base; *chroma* and *lightness* are set to fixed **role targets**, never inherited. This is what lets a drab bar yield a vivid, legible accent (the 60‑30‑10 dominant/accent rule).
3. **Value-structured roles.** A palette is a set of roles at deliberately different (L, C), producing a dark→light ramp with one vivid pop. Uniform-lightness swatches never read as harmonious.

## The OKLCH engine (pure fish, `conf.d/tmux-lives-install.fish`)

Replaces v1's `__tmux_lives_cap_hue`. New pure functions:

- `__tmux_lives_srgb_to_oklch` / `__tmux_lives_oklch_to_srgb` — Ottosson matrices M1/M2 + gamma + cube-root, and the exact inverse. **Fish specifics (verified):** `math` has `atan2`/`sin`/`cos`; no `cbrt` → `x^(1/3)` (forward LMS ≥0 so safe; inverse cube is integer power, safe for negatives); no comparisons inside `math` → branch with `test` (float-capable); normalize hue to [0,360) via a `test` loop (no float `%`).
- `__tmux_lives_gamut_chroma L H Ctarget` — 12-iteration binary search reducing chroma until OKLCH(L,C,H) is in sRGB, keeping L and H exact (handles gamut-starved hues gracefully).
- `__tmux_lives_oklch_hex L C H` — build a `#rrggbb` from OKLCH at (L, gamut-clamped C, H).
- `__tmux_lives_contrast_fg hex` — WCAG relative luminance; `Lrel > 0.179 → #111111` else `#f5f5f5` (replaces v1's luminance-140 rule).
- Hue targeting, two modes: **RYB (default)** maps base hue onto the artist's wheel (green↔red, blue↔orange — expected complements), applies the harmony offset there, maps back, then reads the OKLCH hue of a pure color at that RGB hue (12-point piecewise-linear RGB↔RYB map). **perceptual** applies the offset directly on the base's OKLCH hue.

## The palette generator

`__tmux_lives_palette baseHex formula wheel vividness` → a set of named role hexes. **Roles (value ramp):**

| Role | Source hue | Target L | Target C | Use |
|---|---|---|---|---|
| `bg` | — (the base itself) | — | — | bar background (given) |
| `text` | base hue | 0.90 | 0.02 | light, readable on bg |
| `dim` | base hue | 0.47 | 0.055 | deeper muted surface |
| `muted` | formula's **secondary** partner hue | 0.58 | 0.11 | soft secondary accent |
| `accent` | formula's **primary** partner hue | 0.68 | 0.19×vividness | the vivid pop (the cap) |

**Formula → partner hues** (offsets on the chosen wheel; `±` flip swaps primary/secondary):

| Formula | Primary (accent) | Secondary (muted) |
|---|---|---|
| `mono` | base hue (tonal) | base hue, lighter |
| `complementary` | +180 | base hue (lighter tint) |
| `analogous+` / `-` | +30 / −30 | −30 / +30 |
| `split+` / `-` | +150 / −150 | −150 / +150 |
| `triadic+` / `-` | +120 / −120 | −120 / +120 |
| `tetradic` | +180 | +90 and +270 (two muted accents) |

`vividness` scales the accent chroma: `subtle` 0.55×, `balanced` 0.80×, `vivid` 1.0× (of the 0.19 target). Default **`vivid`** (validated as the good look; retunable live). Literal `#rrggbb` in `tmux_lives_cap` → accent = that hex verbatim (escape hatch, kept). Unknown/empty formula → `mono`.

## Scope: two phases

**Phase 1 (this plan) — generator + cap.** Build the OKLCH engine + palette generator; wire only the **`accent`** role to the cap (`@tmux_lives_cap_bg` = accent, `@tmux_lives_cap_fg` = contrast fg). Ship the picker/CLI/M-m/border/rename. The generator computes the full role set but only `accent` is consumed — Phase 2 is then a pure wiring job.

**Phase 2 (follow-up spec) — whole-bar theming.** Assign the remaining roles across bar elements: `✦` claude mark + prefix/resize mode colors ← `accent`/`muted`; session tag ← `muted`; window/identity text ← `text`; deeper regions ← `dim`. Seed each as an `@option` from the palette; the `status-format` consumes them. Gated behind a `tmux_lives_theme_bar` toggle (default off initially) so existing bars are undisturbed until opted in.

## Storage & integration

Universals (read at fragment render; applied live by CLI/picker via the `tmux_lives_tmux_socket` seam):
- **`tmux_lives_cap`** — formula token (default `mono`) or `#hex`. (Existing; reused.)
- **`tmux_lives_cap_vividness`** — `subtle|balanced|vivid` (default `vivid`).
- **`tmux_lives_cap_wheel`** — `ryb|perceptual` (default `ryb`).

`__tmux_lives_render_fragment` gains these as further positional args (after argv[12] `cap`); it computes the palette and seeds `@tmux_lives_cap_bg`/`_fg` (Phase 2 adds `@tmux_lives_palette_*`). All colors single-quoted (tmux-comment gotcha); every value captured into a var before `set -a` (zero-output-collapse gotcha).

## Selection surfaces

**CLI** (`__tmux_lives_cap_cmd`, extended): `setup cap <formula> | list | --vividness <v> | --wheel <w>`. `list` prints each formula's palette (bg/dim/muted/accent/text swatches) against the current bar. **Rename all user-facing `<token>` → `<formula>`** (help row + the three error strings).

**Picker** (`__tcz_cap_picker`, extended): a **framed** popup (fixes v1's borderless blend) with the switcher's orange `╭─ cap color ─╮` frame + footer.
- Rows = the formulas; each shows its live **palette strip** (dim·muted·accent swatches) computed for the current bar/vividness/wheel.
- **↑↓/jk** move · **←→/hl** flip a family's ± · **`v`** cycle vividness · **`w`** toggle wheel · **⏎** apply · **esc/q** cancel; footer shows effective vividness + wheel.
- Swatches batch-compute in one config-loaded `fish -c` (the `--no-config` boundary); `v`/`w` recompute, ←→ re-selects from cache. Enter applies via `fish -c 'tmux-lives setup cap …'`.

**Trigger** (new): a **`k` "cap color" entry in the `M-m` command modal** (beside "bar color") opens the picker via the deferred `run-shell` pattern — no new global key. Documented in the modal legend + `setup` help.

## Migration / back-compat

Existing `tmux_lives_cap` values stay valid (`complementary`, `triadic-`, `#hex`, …); their output changes muddy→vivid (the point). `mono` becomes an OKLCH tonal accent (base hue at the accent target) rather than v1's brightness shade — a deliberate, consistent change. Phase 2 theming is opt-in, so no existing bar changes until the user enables it.

## Testing

- **Engine:** OKLCH round-trip for known hexes (assert L/C/H + byte-exact return); `__tmux_lives_oklch_hex` known (L,C,H) → exact hex; `__tmux_lives_gamut_chroma` keeps a gamut-starved hue in range; `__tmux_lives_contrast_fg` crossover both directions. Lock fish output as truth where it diverges ±1 from a reference (deterministic pure fn).
- **Generator:** `__tmux_lives_palette #36442d triadic ryb vivid` → the exact five role hexes (reference values baked from the validated prototype); `±` flip swaps primary/secondary; `#hex` passthrough; unknown→mono.
- **Fragment:** seeds `@tmux_lives_cap_bg`/`_fg` from formula+vividness+wheel; parses on a `-L` socket; live `show -gv` non-empty hex.
- **CLI:** `setup cap complementary` / `--vividness` / `--wheel` set the universals + live `@options` via the socket seam, **universals saved/cleared/restored (no leak)**; `list` palette swatches; invalid formula errors non-zero.
- **Picker pure helpers:** formula list, flip, palette-strip line (precomputed hexes), vividness cycle, wheel toggle. Raw-tty loop = manual smoke.
- Isolation via `-L` sockets / stubs; 8× `ALL PASS`.

## Non-goals

- Not HCT/CAM16 (needs an iterative gamut solver; OKLCH gets ~90% closed-form).
- Not APCA contrast (WCAG luminance suffices; APCA is a future upgrade).
- No forced warm/orange formula (orange arrives legitimately via triadic/split accents).
- Phase 2 whole-bar theming is specified but **not built in this plan** (separate spec/plan); not per-client theming.

## Open choices (spec review)

1. **Default formula** — `mono` (conservative) vs a colored default like `analogous+`. Proposed: `mono`.
2. **Keep `perceptual` wheel** or ship RYB-only. Proposed: keep both, RYB default.
3. **Default vividness** — `vivid` proposed (the validated look).
