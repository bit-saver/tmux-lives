# Legibility floors and scheme ordering

Two independent changes, specced together because both land in the theme surface and both are cheap once the measurements below exist. Part A is a bug fix in the engine; Part B is a picker affordance. Neither depends on the other, and they can ship as separate branches if that reads better during planning.

A third idea — hand-composing a scheme by scrolling colours onto placements — is **deliberately deferred**; see "Deliberately not doing".

## The problem

**A. Accents can be illegible against the surface they are painted on.** The user reported it with a screenshot: window names rendered nearly invisible on the bar while the centre identity beside them read fine. Both are foregrounds on the same background, and only one of them is constrained.

The mechanism is `conf.d/tmux-lives-install.fish:122`:

```fish
set -a f "set -g status-style bg=$tpal[1],fg=$tpal[5]"
```

`windows` (role 5) is the default foreground for the entire status bar, painted straight onto `bar` (role 1). `__tmux_lives_theme_constrain`'s fourth stage enforces a 0.40 OKLCH lightness floor for `text` (role 7) **and for no other role**. Four foregrounds sit on `bar`; one of them is guaranteed legible.

| role | paints | consumer | constrained before this spec |
|---|---|---|---|
| `text` (7) | centre identity | `@tmux_lives_text_fg` | yes — 0.40 ΔL floor, two stages |
| `active` (4) | current window name, bold | `@tmux_lives_active_fg` | no |
| `windows` (5) | every other window name, and the bar's default fg | `status-style fg=` | **no — the reported bug** |
| `sep` (2) | the `•` window separators | `@tmux_lives_sep_fg` | no |
| ✦ mark | the claude presence glyph | `@tmux_lives_mark_fg` | no — and it is the **raw seed hex**, not a palette role |
| cap fg | host name, clock | `@tmux_lives_cap_fg` | yes, but by a different metric — `__tmux_lives_contrast_fg`, a WCAG luminance crossover picking `#111111`/`#f5f5f5` |

**B. Finding more of a colour you liked means hunting.** v6's variation is the feature — 3,024 distinct palettes where v5 had one shape with the hue nudged — but the catalog is ordered by construction (mode × arrangement grid), not by appearance. Landing on a `tabs` colour you like tells you nothing about where its relatives are in the list.

## Measurements this design rests on

All figures below are from **210 combinations — 5 seeds × all 42 catalog schemes** — rendered through the shipped engine. Seeds: `#485b3c` (the user's live seed), `#63abab`, `#87cb48` (the design's own calibration seed), `#7a00ff`, `#b03a48`. Contrast is measured against each render's own `bar`, on the **round-tripped hex**, not the requested value.

### Where the foregrounds actually sit

| role | ΔL min | ΔL mean | ΔL max | WCAG min | WCAG max |
|---|---|---|---|---|---|
| `text` | 0.400 | 0.450 | 0.700 | 3.04 | 13.32 |
| `active` | 0.148 | 0.301 | 0.585 | 1.62 | 9.59 |
| `windows` | **0.012** | 0.221 | 0.585 | **1.05** | 9.72 |
| `sep` | 0.048 | 0.180 | 0.352 | 1.10 | 4.49 |
| ✦ mark | **0.000** | 0.157 | 0.500 | **1.00** | 7.52 |

`text`'s floor works exactly — its minimum is 0.400 to three decimals, in 210 of 210. Every other foreground is unbounded below. `mark` reaches ΔL 0.000 / WCAG 1.00: the ✦ is sometimes *precisely* the bar colour. `sep` never once reaches the text floor.

The user's own live scheme, `square split` at `#485b3c`: `sep` 0.101 (WCAG 1.43), `mark` 0.151 (1.87), `active` 0.201 (2.37), `windows` 0.252 (2.90), `text` 0.410 (5.08).

### Why one floor for all four is not an option

Applying `text`'s 0.40 floor to all four foregrounds **moves 71.3% of role-instances by a mean of 0.215 lightness**, and **0 of 210 schemes currently clear it on all four**. That is not a clamp trimming outliers the way bounds 2 and 3 do — those bind in ~14% of renders — it is a rewrite of exactly the variation this engine exists to produce.

| shared floor | role-instances moved | mean move |
|---|---|---|
| 0.40 | 71.3% | 0.215 |
| 0.30 | 60.6% | 0.144 |
| 0.25 | 53.3% | 0.107 |
| 0.20 | 40.2% | 0.087 |
| 0.15 | 27.6% | 0.062 |

### Why the swap cannot be the mechanism

Only the four foreground roles are swappable — `bar`, `tabs` and `cap` are pinned by bounds 2 and 3 and may not move. Of those four colours, how many clear a text-grade 0.40 against their own bar:

| clearing 0.40 | combos | share |
|---|---|---|
| 0 of 4 | 0 | 0.0% |
| 1 of 4 | 140 | 66.7% |
| 2 of 4 | 55 | 26.2% |
| 3 of 4 | 15 | 7.1% |
| 4 of 4 | **0** | **0.0%** |

**A swap alone satisfies three text-grade roles in 7.1% of combos.** In two-thirds, exactly one colour clears — and that one is `text`, which clears only because stage two already nudged it there. The ramp does not contain enough separated colours to seat three text-grade roles, because bound 3 pins `bar` dark from below while the no-white rule caps the ramp from above.

At a **glyph-grade 0.15**, ≥3 of the four clear in **80.0%** of combos. So the swap earns its place for the glyph roles and as a free first pass everywhere; it is an optimisation, not the mechanism.

### The nudge is satisfiable, because it is bidirectional

`bar` lightness across the 210: min 0.095, p25 0.297, median 0.441, p75 0.524, max 0.695 (bound 3's ceiling, exactly).

`text` lightness is **bimodal** — 0.063 to 0.880 — because stage two moves it *away* from bar in whichever direction has room: **lighter in 138 cases, darker in 72**. A naive upward-only nudge would be unsatisfiable for a light bar (0.695 + 0.40 > 1.0); the existing bidirectional rule is not. This is load-bearing and must be preserved when the stage is generalised.

### Why OKLCH ΔL and not APCA or WCAG

Reference figures (`color-expert`): of all colour pairs, WCAG 3:1 passes 26.49%, WCAG 4.5:1 passes 11.98%, APCA Lc 60 passes 7.33%, APCA Lc 75 ("fluent reading") passes **1.57%**. A threshold that strict would force enormous movement on precisely the accent colours the user just praised.

ΔL is chosen because it is **consistent with the stage already in the file**, cheap in fish's `math`, and expressed in the space the whole engine already works in. Legibility is dominated by lightness separation; the reference's own summary is "legibility = lightness variation". WCAG ratios are reported alongside ΔL in the tests as a sanity reading, not as the enforced metric.

## Part A — legibility floors

### The staircase

Four floors, not one. This is the core decision, and it exists to prevent a specific failure: a single shared floor pushes `text`, `active` and `windows` all to `bar ± floor`, collapsing three roles onto two lightness values. That reproduces the "uniformity is the opposite of cohesion" result already recorded in this project — forcing similarity made a palette read as *less* cohesive, because the small roles carry the palette's curve.

| role | floor | rationale |
|---|---|---|
| `text` | **0.40** | unchanged. The centre identity — the thing read most, and the value already proven in production. |
| `active` | **0.32** | the current window name. Must read cleanly *and* stay visibly distinct from `windows` beside it. |
| `windows` | **0.26** | window names. The reported bug. |
| `sep` | **0.15** | the `•` separators — a glyph, needs to be seen, not read. |
| ✦ mark | **0.15** | same: a presence glyph. |

The ordering `text > active > windows > sep = mark` is itself an invariant and is asserted, so a later edit cannot silently flatten the staircase back into a wall.

These values are a **starting point calibrated against the distributions above**, not a derived truth. `active` at 0.32 and `windows` at 0.26 sit inside the measured spread of those roles (means 0.301 and 0.221), so roughly half of each role's instances already pass and the clamp trims rather than defines — the same relationship bounds 2 and 3 have to their roles. Expect to revisit them after live use.

### The mechanism

Generalise stage 4 of `__tmux_lives_theme_constrain` from "the text floor" to "the foreground floors". It becomes a loop over the four foreground roles in the order `text → active → windows → sep`, most-demanding first, so the scarce high-contrast colours are allocated to the roles that need them most.

Per role:

1. **Swap pass.** If the role fails its floor, look for another *foreground* role whose colour clears it, and exchange them. No colour is invented and the palette keeps all seven of its colours; only the role→colour mapping changes. `bar`/`tabs`/`cap` are never swap candidates. A swap must not push the donor role below *its* own floor — check both sides before committing.
2. **Nudge pass.** If no swap works, move the colour's OKLCH lightness to `bar ± floor`, preserving hue and chroma, choosing the direction with genuine gamut headroom. **Prefer UPWARD, falling back to downward only when the upward target would breach the 0.88 ceiling.**

> ⚠ **Corrected 2026-09-06, after measurement. This paragraph originally said "prefer downward when `bar` is mid-range", and that guidance is backwards.** It was reasoning from the ~0.003 of chroma margin the no-white rule leaves near L 0.88. The whole-branch review built all three variants and swept them: preferring upward (what shipped) gives severe chroma loss on 13.3% of `sep` and 13.8% of `active` renders with a 91.6% worst case; **preferring downward gives 15.2% / 23.3% and a 100% worst case**; picking whichever direction round-trips more chroma is a wash at 13.3% / 14.8%. `bar` is dark (median L 0.441), so "down" lands near black where chroma collapses entirely. The shipped code is the best of the three. Do not “fix” it toward this paragraph’s original wording.
3. **Verify the round-tripped hex.** 8-bit quantisation lands a target placed exactly on the floor just under it — measured at 0.001 short for `accent` during the v6 core work. The existing bounded nudge loop re-measures the real gap; reuse it rather than trusting the arithmetic.

`arrange` stays a pure permutation. Everything here is substitution, and substitution belongs in `constrain` — that is a standing decision and this design does not touch it.

### `mark` is not a palette role

The ✦ is `$seedhex`, injected at `conf.d/tmux-lives-install.fish:162`. It is not produced by `constrain` and is not covered by `render`'s seven-element contract.

**Do not widen that contract to eight.** `test (count $tpal) -eq 7` and its relatives appear in the fragment renderer, `theme_apply_live`, `theme_list` and several picker sites; changing the arity touches all of them for one glyph, and the v6 surface cycle already recorded the fragment-argv renumber as the sharpest hazard of its cycle.

Instead add one small pure helper — `__tmux_lives_theme_mark <bar> <seed>` — returning the seed, floored to 0.15 against bar by the same swap-less nudge rule. The fragment calls it at `:162`; the picker calls it wherever it composes its preview. One home for the rule, no interface churn.

### Interactions that will bite

- **no-white runs before the text floor today.** The generalised stage moves *more* roles, and can move them lighter. The existing C3 re-check (around `conf.d/tmux-lives-install.fish:1014`) must be extended to cover every role the new stage touches, not just `text`. An un-rechecked role is how a near-white foreground reaches the bar despite a hard exclusion.
- **Bounds 2 and 3 must not regress.** Those two clamps are already documented as fighting each other at the quantisation floor: re-encoding at lower lightness can round-trip to *higher* chroma below the gamut cusp. This stage runs after them and re-encodes four more roles. A non-regression assertion is mandatory, not optional.
- **Chroma loss — MEASURED, and accepted.** Pushing a colour to an extreme lightness costs chroma. Across the 210-combination sweep: **13.3% of `sep` renders and 13.8% of `active` renders lose more than half their requested chroma**, worst case 91.6%; `windows` (1.9%) and `text` (3.8%) are comparatively safe and gain chroma on net. Every severe loss comes from the **nudge**; the swap causes zero. The loss is intrinsic to moving lightness under a gamut ceiling — three mitigations were built and measured, and all three failed: preferring the dark direction is strictly worse (100% worst case), `sep` structurally cannot initiate a swap because it is last in the descending loop, and lowering `sep`'s floor removes only the mild losses so the *mean* loss rises. The only real lever is the floor values themselves. **Crucially, neither palette the user cares about is harmed**: `mono deep @ #485b3c` is byte-identical before and after, with `sep` keeping the 0.110 chroma peak that makes it cohere, and their live `square split` takes no severe loss on any role.
- **The stage order stays fixed.** Big-role lightness clamp → big-role chroma clamp → no-white → foreground floors last. Legibility is correctness and every earlier stage can still move `bar`.

## Part B — scheme ordering

### The sort key

`functions/tmux-categorize.fish:1873` lays the swatch strip out by measured on-screen area:

```fish
for pair in 3:5 1:4 6:2 0:1 5:1 2:1 7:1 4:1
```

That is **tabs(5 cols) · bar(4) · cap(2) · gap · windows · sep · text · active**. The sort walks the same blocks in the same left-to-right order, so the sort is legible off the strip the user is already looking at, with no explanation needed.

Each block contributes a **key pair**: *clockwise hue distance from the seed's own hue* (so the seed's family sorts first and the wheel is traversed once), then *lightness*. Pairs chain as successive tiebreakers: tabs hue, tabs L, bar hue, bar L, cap hue, cap L, and so on.

The lightness component is not decoration. Hue-only ordering is a known failure — it interleaves lights and darks, so a hue group reads as a jumble rather than a ramp. Adding L inside each block makes each group read as a progression.

The generic warning that there is no single correct linear order for a colour set does not apply here: the goal is **grouping by family**, not a perceptually smooth path, and a hue-major sort serves grouping exactly.

### The toggle and its universal

`o` — free. The picker currently dispatches arrows, `pgup`/`pgdn`, `j`/`k`, `m`, `b`, `t`, `z`, `tab`, `a`, `enter`, and `cancel` (`esc`/`q`).

It cycles `catalog` ⇄ `colour` and persists to a new universal `tmux_lives_theme_order`, read once at open by `__tcz_thp_init` and written on toggle through the same config-loaded `fish -c` child every other universal write in the picker uses. Default `catalog`, so an existing install opens exactly as it does today.

Writing a universal is configuration, not adoption — it touches no tmux option and emits no OSC — so it stays on the cheap side of the standing config/adoption split and needs no dwell gate.

### Cost, and the cache hazard

**Cost is near zero.** The hue and lightness keys are computed once per reload inside `__tcz_thp_reload`, which already renders all 42 schemes; toggling re-sorts an in-memory list and never re-renders.

**The hazard is the row cache.** `__tcz_thp_row` and `__tcz_thp_cells` are keyed by *scheme index*, and the memo's stated correctness argument is that "a scheme's hexes cannot change without a reload, and every reload goes through `__tcz_thp_cacheclear`". Reordering violates that premise directly: index 3 becomes a different scheme with no reload in between. The toggle **must** call `__tcz_thp_cacheclear`. Without it the picker paints stale rows and there is no other symptom — the frame is well-formed, just wrong.

### More Schemes

The `More Schemes` group header is removed. Under colour ordering it is meaningless — sorting interleaves curated and non-curated rows — and it costs one row of a popup where rows are the scarce resource and the admission floor is already computed against the stricter editing layout.

`m` itself stays. Collapsing to the curated 14 is a real filter and curation is still an open thread; only the header row goes. In `catalog` order the curated rows remain first, so the boundary is still implicit.

## Deliberately not doing

**Hand-composed schemes (the user's Idea 2) are deferred to their own spec.** Two reasons, both substantive:

1. **Part B may absorb much of it.** The stated motivation for sorting was "when you find a big-3 colour you like, you have to hunt through all the other variations to find more of that colour" — the same itch. How much of a manual composer is still wanted is a question best answered after using the sorted picker.
2. **It has a genuine dependency on Part A.** It would be the first thing in this system to store *actual colours* rather than a recipe, and the floors specified here must still run over a hand-picked combination — so a colour the user deliberately chose can come back altered. That is a UX question with no obvious right answer, and it is much easier to answer once the floors exist and have been felt on a real bar.

**Not switching the enforced metric to APCA or WCAG.** See the measurement section. ΔL is enforced; WCAG is reported in tests as a cross-check.

**Not widening `render` to eight outputs** for the ✦. See "`mark` is not a palette role".

**Not re-deriving `windows`/`active` from `bar`** the way `cap_fg` is. It would guarantee legibility with zero tuning, but two of seven roles would stop carrying palette colour — considered and rejected in favour of the staircase.

## Testing

The recurring failure mode in this repo is a **vacuous** assertion, and the second is a guard that is **green by sampling luck**. Both are addressed explicitly.

1. **Floor ratchet.** Sweep seeds × all 42 schemes; assert every foreground role clears its own floor, measured on the **round-tripped hex**. Must include a light seed and a dark seed, since `bar` lightness is what decides the nudge direction.
2. **Perturbation.** Move each of the four floors one step and prove the ratchet goes **red**. The bounds ratchet in this project passed while 46 renders breached; moving `peakC` one step turned it red. A sampling grid is not trusted until it has been perturbed.
3. **Staircase ordering.** Assert `text > active > windows > sep = mark` directly against the source table, with a **vacuity guard** — an empty extraction otherwise passes by matching nothing. Extract the table by line-anchored `awk`, never a bare grep, because grep guards in this repo match comments and have done so five separate times.
4. **Bidirectionality.** Assert that at least one fixture nudges *downward* and at least one *upward*. An upward-only implementation passes every floor assertion and is unsatisfiable for a light bar.
5. **Bound 2 / bound 3 non-regression** across the same sweep. These clamps are documented as fighting; this stage re-encodes four more roles after they run.
6. **Chroma-delta report** across the sweep, before and after, to settle the open chroma-loss risk with a number rather than a claim.
7. **`mark` helper** tested directly, including the case where seed and bar are the same colour (ΔL 0.000 was measured, so it is reachable, not hypothetical).
8. **Sort determinism.** The same catalog and seed must produce the same order every time; assert a stable total order with no ties left to chance, since the scheme list is what the row cache is keyed against.
9. **Cache invalidation.** Toggle order and assert the rendered rows actually correspond to the reordered schemes. This is the assertion that catches the stale-row hazard, and it must carry state forward twice — reorder, read, reorder back, read — because a stateful defect that survives one transition often fails on the second.
10. **Persistence.** `tmux_lives_theme_order` survives a picker close and reopen, and an unset universal defaults to `catalog`.

Every assertion is proven **failing before its fix**. Plan assertions are treated as suspect: the last cycle authored eleven defective ones into its own task briefs, all caught downstream.

## Open questions

None blocking. Two things to settle with real use rather than argument:

- The exact floor values for `active` and `windows`. Calibrated against measured distributions, not derived; expect adjustment once seen on a real bar.
- Whether `catalog` remains the right default order once colour ordering has been lived with.
