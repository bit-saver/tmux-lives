# Theme v3.2: scheme bar variation — grid model, kin-cap rule, calibrated

**Date:** 2026-07-20 (design + a 4-round live calibration study with the user
as subject, via the visual companion)
**Status:** approved in-session; generated batch scored 9/10 acceptance
(pre-rule batch scored 5/10)
**Extends:** `2026-07-17-theme-seed-anchored-design.md` (the seed-anchored
engine stays; this changes WHICH cells the dominant roles sample)

## Problem (user-stated)

v3.1 pins bar = seed verbatim in EVERY scheme, so all ten schemes share one
bar color and differ only in companions — no scheme ever presents a
different dominant color, and most schemes failed the user's "ooo" test
(5/10 acceptable). Goal: schemes are the best varied palettes FOR a seed —
including varied bars — and are good BY CONSTRUCTION, not by tweaking.

## The grid model (conceptual frame — the user's own)

The engine's sampler already takes hue-position and lightness independently:
a cell = (hue H, lightness L). v3.1 only ever walked one line (the companion
ladder). v3.2 makes cell selection explicit:

- **bar** = a curated cell on the SEED-DEPTH row: per-scheme hue, L = seed L
  ± ≤ 0.05, chroma anchored at seed C (sine arc, cmax per vividness).
  `mono` keeps bar = seed VERBATIM (never resampled).
- **cap** = derived FROM THE BAR by the kin-cap rule (below) — the dominant
  pair cannot clash.
- **tabs** = the seed VERBATIM (home base: the user's color visible in every
  scheme, on the ShellFish tab bar). When bar == seed (mono), tabs takes the
  first arc sample instead (no duplicate).
- **sep / active / windows** = arc-sample accents (wild hues live where
  pixels are few), positions taken from the rotated sample ring.
- **text** = contrast side of the ACTUAL BAR (derivation input changes from
  seed to bar), C 0.03.

## The kin-cap rule (fitted from 31 judgments, ~84% explained)

Cap = bar hue + family offset, capL = barL + dir·ΔL, capC per variant:

| bar family (OKLCH hue) | offset | notes |
|---|---|---|
| olive/green (~90–160) | ±15–25° | both directions fine |
| teal (~160–210) | +25–35° | BLUE-ward only (negative rejected) |
| warm/earth (~40–90) | +35–50° | toward olive/gold; widest tolerance |
| purple (~280–330) | ±15–20° | muted cap (C .04–.05); noisiest family |

- ΔL ∈ [0.06, 0.12] — never flat (flat pairs tested unreliable).
- capC = barC (default) OR muted 0.03–0.05, and a muted cap REQUIRES
  ΔL ≥ 0.08 (muted + small step reads murky — rejected in testing).
- Acceptance predicate (documented + tested): a generated (bar, cap) pair
  must satisfy the family table + ΔL band + muted-step constraint.

## Per-scheme bar recipes (curated table, one function)

`<scheme> <t_bar> <ΔL_bar>` — bar hue from the scheme's arc at t_bar, on the
seed-depth row. Values validated in the round-4 batch (user seed #576733):
mono seed-verbatim · warm .85/−.03 · cool .15/−.02 · span .30/+.02 ·
wide .70/−.04 · aurora .50/+.03 · sunset .90/−.05 · **fire: retuned toward
the WARM end of its arc** (round-4's sole reject rendered green — a
near-triplet with mono/span/cool; move t_bar so fire's bar lands
red/ember-side, e.g. t ≈ 0.05 of its 130→−44 arc) · complement 1.0/−.02 ·
full .50/0. Cap family offsets resolved from the bar's resulting hue at
generation time (the table above), with muted-cap variants for span
(C .04) and full (C .05).

## Rotation redefinition

The 5 arc samples form a ring; `rotate 0-4` cycles the ring; accent roles
(sep, active, windows) read positions 1–3 of the rotated ring. Bar, cap,
tabs (seed), and text NEVER rotate. (v3.1 rotated cap/tabs too — now both
are pinned by derivation, so rotation touches only the small-area accents.)

## Unchanged

7-role output contract (bar sep tabs active windows cap text) → fragment
argv, @options, apply-live, CLI flags, universals, picker/anchor/shake
machinery, `off` legacy branch, migration (none needed). Cap fg still
`contrast_fg(cap)`.

## Engine changes (all in `conf.d/tmux-lives-install.fish`)

- `__tmux_lives_theme_barpos <scheme>` — the curated bar-recipe table.
- `__tmux_lives_theme_kincap <barhex>` — family lookup + offset → cap hex
  (+ its muted variants where the scheme table says).
- `__tmux_lives_theme_palette` — same signature, new derivation: bar cell,
  kin cap, seed→tabs, ring accents, bar-contrast text.
- Tests: bar-on-seed-row (|barL − seedL| ≤ 0.05 across schemes × seeds);
  mono bar == seed verbatim; tabs == seed verbatim (non-mono); the
  acceptance predicate holds for EVERY scheme × a seed panel (dark, light,
  grey, vivid seeds); text contrasts vs bar (not seed); rotation permutes
  only accents (bar/cap/tabs/text fixed across rotate 0-4); `off`
  unchanged.

## Calibration record (methodology + data, for posterity)

4 rounds via the visual companion, user as subject, blind numbered tiles:
R1 12 tiles (typed votes) → hue-distance is primary, threshold 25–45°
somewhere, flats surprisingly liked. R2 12 tiles → family-dependent
tolerance discovered (olive ≤25, teal ≤35, earth ≤50), muted caps win,
flats REVERSED (dropped as unreliable). R3 validation (9 predicted-good +
3 decoys) → 6/9 + 2/3, refinements: muted needs ΔL ≥ .08, teal
direction-sensitivity, purple noise. R4 the generated batch → **9/10
accepted vs 5/10 pre-rule.** Raw keys in `.superpowers/sdd/calibration-key.md`
(session scratch); this summary is the durable record. Single-subject
caveat acknowledged — the family table lives in one function for later
recalibration.

## Out of scope

Persisting per-user calibration profiles; light-seed direction flips
(dir logic already handles); pattern generalization beyond bar/cap/accent
selection (the grid frame supports it later); picker changes (strips render
whatever the palette returns).
