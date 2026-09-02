# Theme v6 — the production surface

**Status: APPROVED, NOT BUILT** (2026-09-02).

**Supersedes nothing.** `docs/superpowers/specs/2026-08-23-theme-engine-v6-design.md` remains the authority on how a palette is *generated*, and `docs/superpowers/specs/2026-08-28-palette-constraints-design.md` on what makes one *acceptable*. This spec is the third and last piece: how a person selects one, and how it reaches the bar. It corrects two claims in the v6 core spec where measurement disagreed with it — both called out inline.

## The problem

The v6 engine is complete, constrained, gated and merged, and **it renders nothing**. `__tmux_lives_theme_render` has no production caller — only tests. Three v5 call sites still paint the user's bar:

| site | what it does |
|---|---|
| `conf.d/tmux-lives-install.fish:115` | fragment render — the palette baked into `~/.config/tmux/tmux-lives.conf` |
| `conf.d/tmux-lives-install.fish:1472` | `__tmux_lives_theme_apply_live` — pushes the palette to a running server |
| `conf.d/tmux-lives-install.fish:1511` | `__tmux_lives_theme_list` — `setup theme list` |

Two more live in the picker (`functions/tmux-categorize.fish:2527`, `:2697`).

The signatures are not compatible, so this is not a swap:

```
v5:  __tmux_lives_theme_palette <seed> <relationship> <place> <mode> <phase>
v6:  __tmux_lives_theme_render  <seedHex> <mode> <Lspan> <peakC> <peakPos> <arrangement>
```

v5 takes a point in a small named space; v6 takes a **recipe**. The surface has to supply recipes, store one, migrate the old vocabulary, and let a person browse and roll them.

## Phasing, and why

**Wire first, curate live.** The engine ships to production this cycle with a *provisional* starter catalog, generated mechanically rather than hand-picked, and explicitly disposable. Curation happens afterwards, from real use.

The reason is a sequencing trap: a catalog cannot be curated well without seeing it on the real bar, and per this project's standing rule the judge is ShellFish's tab strip, not a mockup. Curating first would defer everything behind a judgement made at lower fidelity than the thing being judged. The starter set is a floor that guarantees something decent is on screen; it carries no claim to being good, so there is no pressure to defend it later.

## Measurements this design rests on

Four, all run before the spec was written, because each could have changed it. Harness in the session scratchpad; method is a grid sweep over the recipe space calling `__tmux_lives_theme_render` and measuring the rendered OKLCH.

**M1 — the documented sampling envelope is wrong, and by a lot.** The v6 core spec gives the roll's bounds as `Lspan` 0.20-0.76, `peakC` **0.01-0.26**, `peakPos` 0.00-1.00, sampled uniformly. Swept across 5,865 renders at four seeds, uniform sampling of that envelope satisfies bound 1 (rendered peak chroma in 0.105-0.180) only **34.6%** of the time — near-identically at every chromatic seed (36.0% / 35.9% / 34.7%) and slightly worse at a neutral one (31.6%).

**M2 — the acceptable region is a diagonal ridge, not a threshold, and it inverts.** Bound-1 pass rate over `(peakC, peakPos)` at seed `#5fab40`, 48 renders per cell:

| requested peakC | peakPos 0.0 | 0.15 | 0.3 | 0.5 | 0.7 | 0.85 | 1.0 |
|---|---|---|---|---|---|---|---|
| 0.08 | 0% | 0% | 0% | 0% | 0% | 0% | 0% |
| 0.11 | 52% | 54% | 75% | **100%** | 67% | 67% | 17% |
| 0.14 | 73% | 79% | 92% | **100%** | **100%** | **100%** | 71% |
| 0.17 | 88% | 88% | 83% | **100%** | **100%** | **100%** | **100%** |
| 0.20 | **100%** | 98% | 92% | 54% | 25% | 67% | 98% |
| 0.24 | 96% | 92% | **100%** | 54% | 25% | 25% | 65% |

Two separate mechanisms, pulling opposite ways. Below `peakC` ~0.10 nothing passes at any position: the rendered peak never reaches the 0.105 floor. Above ~0.20 the *middle* fails while the *ends* pass, because a peak placed mid-ramp sits where the sRGB gamut has headroom and so overshoots the 0.180 ceiling, whereas a peak at either end is clipped back into range by the gamut itself.

A single-variable reading of this is wrong and was nearly shipped: a first probe pinned `peakPos 0.5` and reported 100% pass at `peakC 0.12`, flatly contradicting M1's 0% at 0.11. The pinned variable was the whole explanation.

**Consequence:** the roll samples the ridge — `peakC` **0.13-0.18**, `peakPos` **0.3-0.85** — not the documented envelope. Measured pass rate in that box is ~95%, so a roll costs about one render (~85 ms) rather than three. This is a correction to the v6 core spec, not an addition to it.

**M3 — the seed-robust pool is large and well spread.** Of 1,512 recipes measured at all three chromatic seeds, **415 (27.4%)** satisfy bound 1 at *every* one of them, and all 415 render distinct palettes at the live seed. They spread evenly across all six arrangements (49-83 each) and all seven harmony modes (53-66 each). Requested `peakC` among them is confined to {0.16, 0.21, 0.26} — zero survivors at 0.01, 0.06 or 0.11, which is M1 seen from the other side. `Lspan` is even across 0.28/0.52/0.76.

So the starter fourteen is drawn from a pool of 415, not scraped from a handful of survivors.

**M4 — the tie-break fix is safe.** See "The tie-break" below.

## The tie-break

`__tmux_lives_theme_constrain`'s text-contrast floor first tries a **swap**: `text` exchanges colours with whichever small role (`sep`, `active`, `windows`) sits furthest in lightness from `bar`, keeping `text` itself as the incumbent and requiring a strict improvement to displace it.

That selection is an argmax over floats, and it is unstable. **Measured in the palette-constraints cycle and carried forward, not re-verified here:** 188 of 2,142 floor-firing rows sit within 0.0005 of a tie and 614 within 0.005. M4 below independently confirms the consequence — the two rules disagree on 6.6% of renders — which is the same phenomenon seen from the output side. A flip is not a small change — it **exchanges a whole colour between two roles**, measured worst case 0.36 in lightness. Because a scheme is stored as a recipe rather than as hexes, any future engine constant that moves a value by a thousandth would silently repaint a theme the user had already chosen and settled on.

**Decision: select by ramp index instead of measured lightness.** The ramp is monotonic in lightness by construction and `__tmux_lives_theme_arrange` is a pure permutation, so every role carries a known *integer* ramp position. Distances between integers are distinct by construction — there is no knife-edge to sit on and no constant that can flip it.

The selection collapses to a per-pattern constant, computable by inspection from the arrangement table:

| pattern | bar | sep | active | windows | text | furthest from bar | swaps? |
|---|---|---|---|---|---|---|---|
| deep | 1 | 4 | 6 | 5 | 7 | text (6) | no |
| bright | 4 | 5 | 7 | 6 | 1 | text (3), tie with active | no |
| centre | 3 | 5 | 6 | 7 | 1 | windows (4) | **yes, windows** |
| split | 1 | 3 | 5 | 6 | 7 | text (6) | no |
| stack | 2 | 5 | 6 | 4 | 7 | text (5) | no |
| accent | 3 | 5 | 6 | 2 | 7 | text (4) | no |

**Measured against the current behaviour (M4), 5,865 paired renders at four seeds:**

- **388 palettes differ — 6.6%**, and every one of them is in the `bright` arrangement (39.7% of its rows). The other five arrangements are byte-identical, all 4,887 rows.
- **Zero regressions.** Bound 2 breaches: 0 before, 0 after. Bound 3: 0 and 0. Contrast floor failures: 0 and 0.
- **Text chroma is unchanged** — median 0.0594 to 0.0591, mean 0.0570 to 0.0562. B is lower on 184 rows and higher on 99.

The concentration in `bright` is explained by the table above: it is the only pattern where `text` sits at the dark end (ramp 1) while `bar` sits mid-ramp (ramp 4), producing the one genuine tie. Elsewhere `text` is the extreme and wins outright under either rule.

The pre-registered worry was that a structural rule would pick worse partners, fire stage two more often, and cost `text` its chroma — stage two synthesizes a lightness and can lose 20-93% of requested chroma. Measured, that cost is ~1.4% of mean text chroma across the whole sweep, which is noise. The constraints spec had already accepted stage two firing more often as the price of constraint C2; this is the same trade at a smaller magnitude.

**Honest limitation, recorded rather than papered over:** this removes the instability *in the selection*, not everywhere. Stage two, the two clamps and the no-white pass all still contain threshold tests on continuous values, and a sufficiently large engine change can still move a palette. What it removes is the specific defect measured — a 29%-dense population of near-ties in the one place where crossing one exchanges entire colours between roles. No threshold-free formulation of the rest is proposed here, and none is needed: those stages *nudge* a colour, where the swap *exchanges* two.

## Storage and the CLI

**The recipe is the identity.** Five universals, matching the engine's five recipe fields, replacing the v5 four:

| universal | holds | replaces |
|---|---|---|
| `tmux_lives_theme` | harmony mode, or the literal `off` | same name, was a relationship |
| `tmux_lives_theme_lspan` | lightness span | — |
| `tmux_lives_theme_peakc` | peak chroma | — |
| `tmux_lives_theme_peakpos` | peak position | — |
| `tmux_lives_theme_arrangement` | arrangement pattern | `tmux_lives_theme_place`, `_mode` |
| — | — | `tmux_lives_theme_phase` (dropped: `--phase` is gone) |

Separate universals rather than one packed string, for consistency with every existing surface in this file and because `__tmux_lives_key` already reads them individually with defaults. `tmux_lives_theme` keeps its name so `off` keeps working unchanged.

A **catalog name is a label on a recipe, not a stored value.** The picker's `current` row already resolves a name by reverse lookup and continues to; storing the name as well would be a second source of truth, which this project has been bitten by before.

**CLI:**

```
tmux-lives setup theme <name>     apply a catalog scheme by name
tmux-lives setup theme list       every catalog scheme + a rendered strip
tmux-lives setup theme off        legacy bar colours, unchanged
tmux-lives setup theme            no args: open the picker inside tmux, else print state
```

`--place`, `--mode` and `--phase` are rejected with a message naming what happened, exactly as `--rotate`, `--vividness`, `--shape`, `--ease` and `--contrast` already are — that pattern is established in `__tmux_lives_theme_cmd` and this extends it rather than inventing anything.

**No new flags.** The four value knobs return as recipe *fields*, never as flags: the v6 core spec is explicit that the user wants schemes that work without tweaking, and the picker is where exploration belongs.

### The fragment argv renumber is the sharpest hazard in this cycle

The fragment currently carries `theme`, `place`, `mode` and `phase` at fixed argv positions read by `__tmux_lives_render_fragment` and written by `__tmux_lives_write_fragment`. Replacing four fields with five renumbers everything after them.

**A mismatch between those two functions is SILENT** — no error, no non-zero status. It last cost the `terminal-features xterm*:sync` line, whose absence has no symptom until the ShellFish cursor strobe returns days later. The renumber, the renderer and the writer are therefore **one atomic edit in one commit**, never split, and the plan must pin every downstream argv index by test.

## The starter catalog

Fourteen recipes, generated rather than chosen, from the 415-strong seed-robust pool (M3):

1. Keep only recipes satisfying bound 1 at all three chromatic seeds (the 415).
2. Drop near-duplicates: sort by recipe, and reject any candidate whose rendered palette at the live seed is within a summed per-role OKLCH distance of 0.10 of one already accepted. The threshold is a starting value, to be tuned once against the resulting spread rather than argued about — the requirement is that no two starter schemes look like each other, and 415 distinct palettes is ample headroom.
3. Fill by round-robin over the seven harmony modes, taking the highest-scoring remaining candidate from each in turn, so all seven are reachable from a cold open and no mode dominates. With fourteen slots that is two per mode. Break the second pass by arrangement, preferring an arrangement not yet used, so the six arrangements are also represented.
4. Default to `mono 0.55 / 0.11 / 0.5 / deep` — the recipe the user repeatedly identified as their favourite and the only one previously measured seed-robust across six of seven very different seeds.

⚠ The default's `peakC 0.11` sits **below** the ridge M2 identifies, where the pass rate at `peakPos 0.5` is 100% but falls away sharply either side. It is kept because it is a known-liked palette, not because it is representative — and the plan must assert it satisfies all three bounds at the shipping seed rather than assuming its history carries over.

Names are provisional and mine. They will be replaced by whatever survives real use, and nothing should be built that makes them expensive to change.

## The picker

Layout, geometry and keys are unchanged. `__tcz_thp_*` and the frame-row proof are untouched. Two behavioural changes:

**`z` becomes a real roll.** It samples a mode, an arrangement, and three value parameters from the M2 ridge, biased toward the seed's own chroma so a vivid seed rolls vivid recipes — the bias narrows the sampling box within the ridge rather than replacing it. A roll that fails bound 1 is rejected and re-rolled, capped at a small number of attempts, falling back to the last candidate rather than refusing to render. At ~95% acceptance the cap is close to unreachable.

**Rolls are remembered.** The picker keeps the rolls made while it is open in a bounded in-memory list and `↑↓` steps back through them, so "the second one was better" is recoverable. Nothing is persisted; save still writes the current recipe to the universals exactly as today.

**Deferred by user decision: naming and saving a roll permanently.** The user's own reason is the design input — *"I may be a bit shy to actually save anything unless it truly deserves a permanent seat."* Naming carries a commitment cost, and a prompt demanding a name at the moment of discovery is the wrong shape. When it is built it should promote a roll with one key and an auto-generated name, renameable later. Not this cycle.

## Migration

`__tmux_lives_migrate_v6`, chained after `_v52` in the existing idempotent-on-`fisher update` sequence:

- **Preserve `tmux_lives_bar_color`.** The seed is the one thing that carries over.
- Erase `tmux_lives_theme_place`, `_mode`, `_phase`.
- Rewrite `tmux_lives_theme` from a v5 relationship name to the default recipe, writing all five new universals.
- Leave `off` alone — it still means off.
- One notice line, once.

The user's live theme is `amber / cap / derived` at seed `#5fab40` (read 2026-09-02; the handoff's `wheat / bar / derived` is stale). Those concepts have no v6 equivalent, so it resets and their bar visibly changes. The v6 core spec already chose reset over a nearest-recipe mapping, on the grounds that no mapping would be trustworthy; the user has separately confirmed mid-development theme loss does not bother them. Flagged, not asked again.

## Deliberately not doing

- Naming and saving rolls (deferred above).
- Reviving `--vividness` / `--shape` / `--ease` / `--contrast` as flags.
- Touching the ShellFish/iTerm2 OSC emission path, `status-format[0]`, the tick, or anything outside palette generation and selection.
- Curating the catalog by eye this cycle.
- Fitting anything to the 16 labelled coolors palettes.
- Removing the v5 engine. It stays defined but unreferenced until the surface has been used in anger; deleting it is a separate, trivially revertible commit once v6 has proven itself live.

## Testing

**The bounds guard already exists** and is the main safety net: every catalog recipe at several seeds must satisfy the engine-enforced bounds. It extends to the new catalog unchanged.

New, and each must be shown to fail before its change:

- **Bound 1 across the catalog at several seeds.** Bound 1 is *not* engine-enforced by design — the gamut decides it — so it is the catalog's contract and belongs in the catalog's test, not in `__t6_inbounds`.
- **The tie-break is structural.** Assert the selection contains no comparison of measured lightness, and pin the per-pattern constant table against `__tmux_lives_theme_arrange`'s own tables so the two cannot drift. A rendered-output assertion cannot see this: five of six arrangements are byte-identical under both rules.
- **The `bright` regression set.** The 388 differing renders are the entire behavioural change; pin a sample of them by exact hex, since they are the only evidence the new rule is active at all.
- **Fragment argv.** Every index that moves gets an assertion. The failure mode is silent, so the absence of one is indistinguishable from success.
- **Migration.** Idempotent; preserves the seed; erases all three retired universals; writes five valid new ones; leaves `off` untouched. Run it twice and assert byte-identical universals.
- **The roll terminates.** Assert the attempt cap is honoured and that exhausting it yields a renderable palette rather than nothing.
- **No v5 caller remains.** Grep-guard that `__tmux_lives_theme_palette` has zero call sites outside its own definition and the v5 tests, bounded to a region and paired with a positive count so it cannot pass vacuously.

## Open questions

1. **Does the M2 ridge hold at other seeds?** It was mapped at one (`#5fab40`), 48 renders per cell. M1 and M3 sampled four and three seeds respectively and agree closely, so the ridge is unlikely to be seed-specific — but the sampler depends on it, and a cheap re-map at two more seeds during the build would settle it.
2. **Should the default's `peakC 0.11` be raised onto the ridge?** It is a known-liked palette sitting in a low-tolerance corner. Raising it would make it more robust and less what the user actually liked. Deliberately not decided here.
3. **What does the neutral-seed case do?** Carried unresolved from the constraints spec. A fully desaturated seed cannot reach bound 1 — measured 31.6% pass here versus ~36% at chromatic seeds, so it degrades rather than collapses. Reject at input, or substitute a hue, or accept the lower rate. Not decided.
