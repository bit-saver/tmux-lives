# Theme v6 — palette constraints

**Status:** SHIPPED on `feat/palette-constraints`, and this document has been amended to describe what actually shipped rather than what was proposed. Where the two differed, the code is authoritative and the difference is called out inline.

**Supersedes nothing.** The v6 core engine (`docs/superpowers/specs/2026-08-23-theme-engine-v6-design.md`) is unchanged and remains the authority on how a palette is *generated*. This spec adds the constraints that decide whether a generated palette is *acceptable*.

**Amended: the constraints do NOT live in the arrangement stage.** The original text called them "two structural corrections to the arrangement stage", and pre-flight on the plan showed that placing them there breaks eleven existing assertions: `__tmux_lives_theme_arrange` is contractually a PURE PERMUTATION, and several tests recover the role-to-ramp mapping by feeding it a fixture and observing where each colour lands — including the four that pin v6's round-robin hue mapping. Clamping and no-white SUBSTITUTE colours, which destroys that contract. They therefore ship in a new `__tmux_lives_theme_constrain`, applied by `__tmux_lives_theme_render` after arranging, which takes it from eleven breaks to six. `arrange` remains a pure permutation and no longer carries the text floor at all.

**Stage order inside `constrain` is load-bearing and fixed:** big-role lightness clamp -> big-role chroma clamp -> no-white -> text-contrast floor LAST, because legibility is correctness and every earlier stage can move `bar` or `text`.

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

**A static index rule is necessary but NOT sufficient, and this was measured rather than assumed.** The obvious formulation — "no big role may take ramp index 6 or 7" — does not hold, because the ramp window is positioned by the seed's own lightness. Worst-case lightness at each ramp index, swept across eight seeds and five lightness spans:

| ramp index | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| max L reached | **0.77** | 0.80 | 0.84 | 0.87 | 0.90 | 0.94 | 0.97 |

**Even index 1 can reach 0.77.** A light seed with a narrow span puts the entire window above the bound — at seed lightness 0.92 with span 0.20 the window is roughly [0.82, 0.97] and every position breaches. No arrangement table can fix that.

So the constraint has two parts:

**C1a — re-index the arrangements so `bar`, `tabs` and `cap` draw from ramp indices 1-4.** This removes the common case cheaply and statically, and is checkable against the arrangement table itself. Indices 5, 6 and 7 go to the small roles.

**C1b — clamp any big role that still exceeds the bound**, pulling its lightness down to it while keeping hue and chroma. This is the same mechanism the text floor already uses in its stage two, so it is a known, tested shape rather than new machinery. It handles the light-seed case that C1a structurally cannot.

**Amended: the clamp targets 0.695, not the 0.70 bound, and the extra 0.005 is quantisation headroom rather than a tightening of bound 3.** The clamp nudges until the ROUND-TRIPPED lightness clears; the chroma clamp then re-encodes those same three roles at a new chroma, and an 8-bit sRGB round trip at a different chroma moves lightness. Measured, `#00ffff square 0.35 0.14 0.3 centre` left `cap` at L 0.699986 after the lightness clamp and shipped it at L 0.70124 — 46 of 3,024 swept renders breached bound 3 this way. Re-checking bound 3 after the chroma clamp is the obvious fix and is the wrong one: it clears all 46 but introduces 6 bound-2 breaches (meanC 0.09503), because re-encoding at a lower lightness can round-trip to higher chroma below the gamut cusp. The two clamps genuinely fight at the quantisation floor, so the second one is given room instead. 0.005 is sized off the measured worst-case overshoot of 0.00124, roughly four times the margin needed.

C1b has a deliberate consequence worth stating plainly: **the big surfaces stay dark regardless of how light the seed is.** The seed's lightness continues to position the ramp and therefore shapes the small roles and the overall spread, but it no longer drags the large surfaces pale. That is the intended reading of bound 3 — a pale large surface was rejected at every seed it appeared at — but it does narrow v6's "the seed's lightness reaches the output" claim to the small roles at light seeds.

Whether the catalog keeps six arrangements or fewer is deliberately left open — see Open questions.

### C2 — the text-floor swap may not promote a big role

**Status: enforced.** `__tmux_lives_theme_constrain`'s swap loop reads `for i in 2 4 5`. This is recorded explicitly because C2 was DROPPED IN TRANSIT once already: the shipped loop was `for i in (seq 2 6)`, which includes `tabs` and `cap`, and the plan's self-review mis-mapped C2 onto the ordering task, which implements something else. No task report noticed, and the whole-branch review caught it. Restored in the review fix wave.

The text floor makes `text` clear 0.40 OKLCH lightness from `bar` in two stages, the first being a swap of `text` with whichever remaining colour is furthest in lightness from `bar`. (Amended: this lives in `constrain`, not in `arrange` — see the note at the top of this document.)

That swap picks its partner from the actual data, so **the same named arrangement produces different role-to-lightness mappings for different palettes.** Measured at one seed: `centre` puts `cap` at L 0.35 in one palette and L 0.97 in another. The mapping is not stable, which is why this defect was hard to see and why a named arrangement could not be reasoned about.

**The constraint:** the swap may only choose `text`'s partner from the small roles (`sep`, `active`, `windows`). It may never swap a big role to the light end.

The reason is that a swap is an EXCHANGE: a big role chosen as the partner does not merely give up its colour, it RECEIVES `text`'s, and `text` is often light. Demonstrated at `constrain`'s own contract boundary — `cap` emitted at L 0.879756 from an input whose big roles all entered at or below L 0.659, breaching bound 3 by 0.18. The floor runs last, after both clamps, so nothing downstream can catch that.

This narrows the swap's options, so stage two (pushing `text`'s lightness directly) will fire more often. That is acceptable — stage two already exists, is tested, and preserves hue.

**No shipped arrangement table reaches the unrestricted case today.** Swept over 3,024 renders, the swap's `best` is only ever 7, 5, 4 or 2, and restricting the range leaves all 3,024 renders byte-identical. That is a property of the current table, and the table is exactly what a future task edits — which is why C2 belongs to `constrain` rather than to the tables, and why its guard is written at the contract boundary rather than through a rendered recipe.

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
- **Structural guard for C1a.** Assert no arrangement places `bar`, `tabs` or `cap` on a ramp index above 4. This must be checked against the arrangement table itself, not inferred from rendered output, so a future arrangement cannot be added that violates it silently.
- **Behavioural guard for C1b.** Assert that a deliberately light seed with a narrow span — the case C1a cannot reach — still yields big roles under the bound. Without this the clamp could be deleted and every static check would stay green.
- **Contract-boundary guard for C2.** Amended: the proposed guard here was a stability check on the role-to-ramp-index mapping across several palettes. That is not what shipped, and it would not have worked — no recipe reaches the unrestricted case through the six shipped tables, so any guard driven by rendered output passes vacuously. What ships instead is an assertion on `__tmux_lives_theme_constrain` directly, with a fixture built to reach the swap (`bar` L 0.659, `text` L 0.880 so the floor fires, `cap` the furthest thing from `bar` at L 0.100), and a companion assertion proving that fixture entered in bounds and inside the floor so the outcome cannot pass for the wrong reason. It fails with `seq 2 6` restored.
- **No-white must ride the bounds guard, not only its own assertions.** Learned the hard way: disabling only the `L > 0.88` branch, leaving the chroma floor intact, left the entire suite green while 703 of 3,024 swept renders breached no-white, some at L 0.97. Every targeted no-white assertion happens to pick a recipe where the CHROMA branch sets the changed flag and the shared nudge loop enforces the ceiling as a side effect, so none of them can see the lightness branch at all.
- **"Did not fire" must be byte identity, and its fixture must sit between the mutated threshold and the real one.** A bound check dressed as its opposite (`max big L <= 0.70` under a comment saying the clamp must not fire) is exactly what a clamp that DID fire guarantees. And byte identity alone is not enough either: a fixture whose big roles enter far below the clamp is insensitive to any plausible over-firing mutation.
- **Holdout.** The three rejected palettes recorded above must fail the bounds guard. If a change ever makes them pass, the bounds have been loosened too far.

Every guard must be proven to fail before the corresponding change, per this project's standing practice.
