# Theme v6 — palette constraints

**Status:** design, approved in principle 2026-08-28. Not built.

**Supersedes nothing.** The v6 core engine (`docs/superpowers/specs/2026-08-23-theme-engine-v6-design.md`) is unchanged and remains the authority on how a palette is *generated*. This spec adds the constraints that decide whether a generated palette is *acceptable*, and makes two structural corrections to the arrangement stage so the engine can satisfy them.

## The problem

The v6 core proved the engine has range — bar chroma spans 0.011-0.26 where v5 was pinned near 0.063. But range alone does not make a palette good, and across three rounds of live judgement the user rejected most of what the engine produced, in terms that resisted every structural theory: *"there's always ONE colour that doesn't fit"*, *"they look so odd and separate"*, *"everything is less cohesive"*.

Three separate hypotheses were built, rendered and refuted:

1. **Far hues must stay off the big areas.** Refuted: the user called a four-hue-family palette with two far hues on big areas "the best looking" thing on the page.
2. **Bright light accents over dark big areas read as disconnected.** Refuted by measurement: their favourite palette has the *largest* accent-to-big-area lightness gap of anything shown (+0.28).
3. **Force one hue family for cohesion.** Refuted flatly: the result was judged **less** cohesive.

All three were assistant-generated hypotheses. The rule that survived was derived the other way round — from the palettes the user had already praised.

## The rule

Three numeric bounds, measured on the OKLCH values of the seven rendered role colours.

| # | bound | prevents |
|---|---|---|
| **1** | peak chroma across all seven roles is **>= 0.105 and <= 0.180** | below: muddy, no focal point. above: blazing, fights itself |
| **2** | mean chroma of `bar`, `tabs`, `cap` is **<= 0.095** | the three large surfaces competing for attention |
| **3** | max lightness among `bar`, `tabs`, `cap` is **<= 0.70** | a pale large surface, which reads as belonging to a different palette |

Roles, for reference, in engine order: `bar sep tabs active windows cap text`. The "big three" are `bar`, `tabs` and `cap` — the filled surfaces. The rest are text drawn on them.

### Hue placement is not a constraint

This is the counter-intuitive result and it is the one that unblocked the work. **Hue family count across the six liked palettes runs 1, 2, 1, 4, 3, 3.** Monochrome and four-family palettes are both liked. Which role carries which hue does not predict acceptance.

The decisive experiment: the exact hue the user called *"just awful"* was placed on `tabs` twice, changing only lightness — at L 0.51 (`#7d5c5f`, a dusty rose) and at L 0.88 (`#fac9cd`, the pale pink originally rejected). The dusty rose is acceptable; the pale pink is not. Same hue, same role.

That retroactively explains the entire confusing record. A four-family square palette passed and a three-family triadic palette failed because nothing was ever counting hues — bound 3 was checking whether a large surface had gone pale.

## Evidence

**Derivation set — six palettes the user praised in their own words**, measured:

- peak chroma **0.110 - 0.173**
- big-three mean chroma **0.044 - 0.088**
- big-three max lightness **0.60 - 0.66** (a notably tight band)

**Holdout — every palette the user rejected** violates at least one bound, with **zero overlap** on bound 1:

| rejected palette | peak chroma | big-3 mean C | big-3 max L | violates |
|---|---|---|---|---|
| triadic quiet (the pale pink) | 0.056 | 0.031 | **0.88** | 1 (low), 3 |
| triadic vivid | 0.191 | **0.126** | 0.62 | 1 (high), 2 |
| the flat "mono + gray" foundation | 0.085 | 0.048 | 0.60 | 1 (low) |

**Falsification — seven perturbations off a known-good palette, each changing exactly one property, with the prediction written down before the user looked. All seven predictions were correct**, including the pink pair above.

**Seed robustness.** `mono 0.55 / 0.11 / 0.5 / deep` satisfies all three bounds at **six of seven** very different seeds — green `#87cb48`, olive `#5f772b`, rust `#b7410e`, blue `#2f6fb3`, purple `#7a00ff`, gold `#c9a227`. The seventh, a fully neutral gray `#4a4a4a`, fails bound 1 at peak chroma 0.078, because a seed with no chroma gives the ramp no hue to build on. See Open questions.

## Why cohesion is a curve, not uniformity

The third refuted hypothesis is worth recording as a design constraint in its own right, because it is the one a future reader is most likely to re-attempt.

Forcing all seven roles into one hue family at similar chroma produced a palette the user called *less* cohesive than the multi-hue one it replaced. The cause, measured: in the liked palette, `sep` — the tiny `•` separators between window names — carries **the highest chroma in the entire palette at 0.110**. Flattening the palette crushed it to 0.029 and collapsed `active` and `windows` onto an identical value. The big three were nearly unchanged; everything broken was in the small roles.

A liked palette runs dark low-chroma `bar` -> `tabs` -> `cap` -> a saturated peak at `sep` -> light tips. Every role is a distinct point on one arc. Replacing that arc with a plateau of similar mid-tones reads as muddy.

**`__tmux_lives_theme_ramp` already generates exactly this curve** — `peakC` and `peakPos` are its controls. The failed experiment bypassed it and hand-assigned per-role constants. The rule that follows: **never hand-assign role colours; always sample the ramp.** Bound 1 is, in effect, a constraint on where the ramp's peak may sit.

## What changes in the engine

### C1 — big roles draw from the dark end of the ramp

Bound 3 is currently violated *by construction*. Of the six arrangements, only `deep` keeps all three big roles on low ramp positions:

| arrangement | bar | tabs | cap | highest big role |
|---|---|---|---|---|
| **deep** | 1 | 2 | 3 | cap @ 3 |
| bright | 7 | 6 | 5 | **bar @ 7** |
| centre | 4 | 3 | 7 | **cap @ 7** |
| split | 1 | 6 | 2 | **tabs @ 6** |
| stack | 2 | 3 | 7 | **cap @ 7** |
| accent | 3 | 4 | 7 | **cap @ 7** |

Ramp positions 6 and 7 are where L 0.88-0.97 lives. Five of six arrangements place a large surface there.

`deep` is also the arrangement behind the mono palette the user repeatedly called their favourite. That is not a coincidence worth ignoring.

**The constraint:** every arrangement must place `bar`, `tabs` and `cap` on ramp indices whose lightness satisfies bound 3. The simplest formulation, and the one this spec proposes: **no big role may take ramp index 6 or 7.** Arrangements that violate this are either re-indexed or removed.

Whether the catalog keeps six arrangements or fewer is deliberately left open — see Open questions.

### C2 — the text-floor swap may not promote a big role

`__tmux_lives_theme_arrange` enforces `text` clearing 0.40 OKLCH lightness from `bar`, in two stages, the first being a swap of `text` with whichever remaining colour is furthest in lightness from `bar`.

That swap picks its partner from the actual data, so **the same named arrangement produces different role-to-lightness mappings for different palettes.** Measured at one seed: `centre` puts `cap` at L 0.35 in one palette and L 0.97 in another. The mapping is not stable, which is why this defect was hard to see and why a named arrangement could not be reasoned about.

**The constraint:** the swap may only choose `text`'s partner from the small roles (`sep`, `active`, `windows`). It may never swap a big role to the light end.

This narrows the swap's options, so stage two (pushing `text`'s lightness directly) will fire more often. That is acceptable — stage two already exists, is tested, and preserves hue.

### C3 — no white

Already settled independently: the light end must not resolve to a near-neutral near-white. A light colour that is genuinely tinted is not "white"; a near-neutral one is. This interacts with bound 3 (which keeps big surfaces off the light end entirely) but is not subsumed by it, because `text` and the small roles may still be light.

Proposed thresholds, to be confirmed against renders rather than argued: no role above **L 0.88**, and any role above **L 0.72** carries at least **C 0.055**.

## What does not change

- `__tmux_lives_theme_anchors`, `__tmux_lives_theme_ramp` and `__tmux_lives_theme_render` keep their signatures and behaviour.
- Harmony modes stay as they are. Hue is not constrained.
- The v5 cluster stays live and byte-identical. Nothing here is reachable from production until the surface plan runs.

## Open questions

1. **Do the bounds' exact values survive a wider derivation set?** They rest on six liked palettes at one seed. Their *existence* is well-supported; the specific numbers are the least certain part of this spec. The bounds above are deliberately widened from the measured ranges (e.g. 0.105-0.180 against a measured 0.110-0.173) to avoid over-fitting.
2. **How many arrangements survive C1?** Re-indexing all six preserves variety but changes palettes the user has not seen. Keeping only compliant ones is honest but may leave too few.
3. **Does bound 2 need a floor as well as a ceiling?** Every liked palette sits at 0.044 or above, but nothing yet tests whether a big-three mean below that is bad on its own or only as a symptom of a low peak.
4. **The neutral-seed case.** A fully desaturated seed cannot satisfy bound 1, because there is no hue to build chroma on. Either such seeds are rejected at input, or the engine substitutes a hue. Not decided.

## Testing

The bounds are directly assertable on rendered output, which makes this unusually testable for colour work — the v6 range guard already demonstrates the pattern.

- **Bounds guard.** For every catalog recipe at several seeds, assert all three bounds hold. This is the regression guard for the entire spec.
- **Structural guard for C1.** Assert no arrangement places `bar`, `tabs` or `cap` on ramp index 6 or 7. This must be checked against the arrangement table itself, not inferred from rendered output, so a future arrangement cannot be added that violates it silently.
- **Stability guard for C2.** Assert the role-to-ramp-index mapping for a given arrangement is identical across several different palettes. This is the assertion that would have caught the swap defect.
- **Holdout.** The three rejected palettes recorded above must fail the bounds guard. If a change ever makes them pass, the bounds have been loosened too far.

Every guard must be proven to fail before the corresponding change, per this project's standing practice.
