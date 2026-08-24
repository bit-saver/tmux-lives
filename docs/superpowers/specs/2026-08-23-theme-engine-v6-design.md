# Theme engine v6 — harmony, ramp, arrangement

**Status: APPROVED, NOT BUILT** (2026-08-23). Replaces the v4/v5 curve engine (`__tmux_lives_theme_curve`, `_barpos`, `_family`, `_kincap`, `_accents`). Absorbs the open task recorded as "the accents are scheme-blind".

## The problem, measured

Across **all 24** relationship × placement combinations at one seed:

| | v5 engine | the user's 10 liked coolors palettes |
|---|---|---|
| hue families | **1** (21 of 24; three reach 3) | 1–4, mean 2.0 |
| peak chroma | **0.084 – 0.085** | 0.044 – 0.247 |
| lightness span | **0.47 – 0.47** | 0.20 – 0.69 |

Peak chroma varies by **0.001** across every scheme the engine ships, and lightness span is **byte-identical** in all 24. The catalog's 35 rows are one palette shape with the hue nudged.

The seed's own chroma and lightness are discarded entirely — only its hue survives. Measured: seed `#80ff00` (C 0.264, L 0.89) and seed `#7a00ff` (C 0.293, L 0.52) both produce a bar at **C 0.063**, L 0.50 and 0.41. Every saturated seed converges.

**The defect is fixedness, not dimness.** The user explicitly likes the muted style and is defending it: *"this is me defending the dim muted schemes because I actually do like that style. But I think we need an engine that is capable of generating those as well as the 'radical' ones coolors generates."* Raising the chroma ceiling would merely relocate the single destination and cost them a style they want. The target is that chroma and lightness spread become dimensions a scheme controls, with the seed anchoring hue **and** contributing its own L and C.

### What coolors does that we don't

Eight generate modes — mono, analogous, complementary, split-complementary, triadic, tetradic, square, and Auto, which rolls one at random. **The harmony rule chooses only hues; the generator then lays a value structure over them.** Its per-colour pages show hue rotations largely bare, and the user finds those markedly less likable than the generator's output — which is them having already A/B'd hue-variation-alone against hue-plus-value-structure.

tmux-lives has the hue half and pins the value structure. That is the entire gap.

### Two knobs we already named and never wired

`--vividness`, `--shape`, `--ease` and `--contrast` were exactly chroma level, chroma peak position, ramp easing and lightness span. They were accepted, stored, shown in the picker, and **never reached the engine** — swinging all four to their extremes produced byte-identical palettes on all 35 catalog rows. They were removed on 2026-08-06 as proven dead. The names were right; the wiring never existed.

## What the labelled data can and cannot support

The user supplied 10 liked and 6 disliked coolors palettes. **The question they answered was "do I like these colours?" — not "should this be a tmux-lives scheme?"** They flagged the risk themselves: *"What worries me is that all our schemes are going to start looking like the palettes I picked."*

**No scalar feature separates the two groups.** Lightness range 0.52 vs 0.50, peak chroma 0.146 vs 0.117, hue spread 202° vs 146°, hue families 2.0 vs 1.5, near-neutral count 0.7 vs 2.0 — every one overlaps and each has a counterexample. Sixteen examples with a use-case-dependent label cannot support a fitted preference model, and none is used as one.

**What the set does support, needing no separation at all:** peak chroma across all 16 runs 0.009 / median 0.144 / max 0.255, and **11 of 16 exceed the v5 engine's entire ceiling of 0.100** — several of them palettes the user *disliked*. We do not generate poor palettes from a reasonable space; we generate from a space that excludes nearly everything coolors makes, good and bad alike.

**Independence of the value dimensions, measured on the same 16:** peak chroma vs lightness span **r = −0.29**; peak chroma vs chroma-peak position **+0.25**; lightness span vs peak position **+0.06**. No evidence any pair moves together, so intensity must not be collapsed into a single axis. Only 6 of 16 peak mid-ramp, so the "chroma arcs through the middle" finding from the earlier colorhunt scrape is a property of *gradient* palettes specifically and does not generalise — corrected here.

The 16 are retained as a **holdout**, never training data.

## Architecture

Three stages, each pure, each independently testable without a tmux server.

### 1. Harmony — hues only

`__tmux_lives_theme_anchors <seedHue> <mode>` → 1–4 hue angles, nothing else. The seed's hue is always anchor one, so the seed anchors every mode.

| mode | anchors |
|---|---|
| `mono` | `h` |
| `analogous` | `h−30, h, h+30` |
| `complementary` | `h, h+180` |
| `split` | `h, h+150, h+210` |
| `triadic` | `h, h+120, h+240` |
| `tetradic` | `h, h+60, h+180, h+240` |
| `square` | `h, h+90, h+180, h+270` |

This replaces the signed-travel relationships (`mono`/`wheat`/`amber`/`ember`/`coral`/`mint`/`sage`/`teal`). Those are all analogous-to-complementary hue *travel* along an arc and structurally cannot produce separated hue families; triadic and square require hues to **jump**, not travel.

**`--phase` is dropped.** It rotated hue, which is what the seed now does, and the user had already pinned it to zero on the grounds that changing the seed is the better lever.

### 2. Ramp — where muted-versus-radical lives

`__tmux_lives_theme_ramp <seedL> <Lspan> <peakC> <peakPos> <n>` → `n` `(L, C)` pairs.

The seed's **chroma** is deliberately *not* a ramp input. The recipe's `peakC` is authoritative, so a saved scheme renders identically whatever the seed's own saturation. The seed's chroma instead **biases the roll** (see below): a vivid seed rolls vivid recipes more often. That way picking a bright colour visibly does something, without the seed overriding a scheme the user deliberately chose.

Lightness spreads across a window of width `Lspan`, positioned so **the seed's own L falls inside it**. That is how the seed stops being hue-only. Chroma follows a curve peaking at `peakPos` along the ramp with maximum `peakC`, tapering toward both ends.

Sampling bounds, taken from the measured corpus: `Lspan` **0.20–0.76**, `peakC` **0.01–0.26**, `peakPos` **0.00–1.00**. Those bounds are what let the core reach `93b7be…` at peak chroma 0.044 and `494947-35ff69…` at 0.247 from the same machine.

L values are clamped to `[0.05, 0.97]` and chroma is gamut-clamped by the existing `__tmux_lives_gamut_chroma`, which is correct and stays.

### 3. Arrangement

The seven `(L, C)` pairs are distributed over the hue anchors **round-robin by ramp position** — with four anchors the seven positions cycle `1,2,3,4,1,2,3` — and the resulting seven colours are mapped onto the roles `bar sep tabs active windows cap text`.

Round-robin is chosen over contiguous blocks because it guarantees that adjacent lightnesses carry *different* hues, which is what makes a multi-hue palette read as multi-hue rather than as three separate ramps. With `mono` there is one anchor and every position shares it, which is correct and needs no special case.

Arrangement is a **fixed set of exactly six named permutation patterns**, each a mapping from ramp position to role, so the set stays enumerable and testable rather than being one of `7!` orderings. The six are named and pinned in the implementation plan; the count is fixed here so the roll space is a known size.

**One hard rule and only one: `text` must clear a contrast floor against `bar`.** If the chosen arrangement fails it, `text` is moved to the contrasting end of the ramp. Nothing else is constrained.

Over-constraining is what produced the single destination this design exists to escape, so the floor is deliberately minimal and the curated shortlist (below) is what guarantees something good is on screen rather than a generation-time filter.

Arrangement is also a free source of variety: the same seven colours arranged differently is a genuinely different scheme, so the roll space is larger than harmony × value alone.

**All seven roles are genuinely generated.** In v5, `sep`, `active`, `windows` and `text` were low-chroma tints of the bar's hue — `__tmux_lives_theme_accents` declared a `capHex` argument and never referenced it — which is why six of seven roles resolved to only **11 distinct values across all 35 catalog rows**. That is absorbed here rather than deferred again.

## A scheme is a recipe, not a palette

A scheme stores `(mode, Lspan, peakC, peakPos, arrangement)` — never seven hexes. Change the seed and every saved scheme re-derives around the new colour, which is the seeded behaviour the user asked for: *"if you were to make it less random, and focus on a seed color like we do for the schemes, I still would not like all of them, but a more than average number I would like."*

Rolls are reproducible because the recipe is the identity.

## Surface: roll, on a curated floor

`z` becomes a real roll across the whole space — pick a mode, three value parameters and an arrangement — rather than a jump within a fixed list.

**The roll is biased by the seed's chroma.** `peakC` is sampled from the measured 0.01–0.26 envelope, weighted toward the seed's own chroma, so a vivid seed produces vivid recipes more often and a muted seed muted ones — while both remain able to reach the whole range. `Lspan`, `peakPos`, mode and arrangement are sampled uniformly. The bias lives only in sampling: once a recipe exists it renders deterministically from its own fields.

The list still **opens on a curated shortlist** of roughly 14 hand-picked recipes, exactly as today, so there is always something good before anything is rolled. The catalog is the floor; the roll is the ceiling. Nothing is lost relative to the current surface.

## White

The user: *"I will NEVER pick a palette with white in it. But that's absolute bias."* Then, correcting an over-strong reading of that: *"I wasn't actually banning the color white… I don't want you to exclude white altogether, that's a little ridiculous. BUT, I have a feeling there just won't end up being many palettes with white."*

**No white filter is built.** White remains reachable where the ramp genuinely produces it, and is expected to be rare as an outcome of the design rather than a rule bolted onto it.

Worth noting the v5 engine already produced near-whites in two roles regardless of seed: `text` measured L 0.86–0.95 at C 0.030 and `active` L 0.88 at C 0.030, pinned at that chroma for every seed. Under v6 both are generated from the harmony and carry real hue, so they become tinted lights rather than off-whites — which is also what Radix (greys at chroma 0.010–0.019, within 15–27° of their accent) and Material 3 (neutrals as a fraction of source chroma) do.

## Migration

The stored `(relationship, place, mode)` has no v6 equivalent — those concepts are gone. `__tmux_lives_migrate_v6` **resets to a curated default and prints one line saying so, preserving the seed.** No mapping to a "nearest" v6 recipe is attempted, because none would be trustworthy and the user has stated that mid-development theme loss does not bother them.

## Testing

Harmony and ramp are pure: unit tests, no tmux server.

- **Harmony** — exact hue sets per mode; the seed's hue is always anchor one; wrap-around at 360 is correct.
- **Ramp** — lightness is monotonic across the returned pairs; the span is honoured; chroma peaks where `peakPos` asks; the seed's L falls inside the window; clamping holds at both extremes.
- **Arrangement** — a property test over a large sample of rolls: the text-contrast floor holds **every** time. Each named permutation pattern is pinned.

Two guards matter more than the rest.

**The range guard.** Across the catalog, assert that peak chroma spans a real interval and that lightness span genuinely varies. These measure **0.001** and **0.47–0.47** today — the exact numbers that revealed the collapse — and no existing test would have caught it. This is the regression guard for the actual failure, not a proxy for it.

**The holdout.** The user's ten liked palettes, as a reachability check: can the engine, given an appropriate seed, land in their neighbourhood? It must **also** still produce the muted schemes the user is defending. If it can only do one, it is not done.

Every assertion must be shown to fail against the pre-change engine before it is trusted, per this repo's standing rule.

## Scope

**Replaced:** `__tmux_lives_theme_curve`, `_barpos`, `_family`, `_kincap`, `_accents`, `_reldef`, and the signed-relationship vocabulary.

**Kept untouched — correct and well-tested:** the OKLCH conversions (`hex_to_rgb01`, `rgb_to_oklch`, `oklch_to_linrgb`, `oklch_hex`), `gamut_chroma`, `contrast_fg`, `theme_push`, `theme_apply_live`'s option-writing, the fragment renderer, and the picker's draw and input machinery.

The catalog, picker, fragment and CLI all keep working against a palette function with the same seven-role output signature.

## Explicitly not doing

- Fitting scheme generation to the 16 labelled palettes.
- A white filter.
- Any chroma or hue coherence constraint beyond the text-contrast floor.
- Reviving `--vividness` / `--shape` / `--ease` / `--contrast` as user-facing flags. Their concepts return as recipe fields; the flags do not, because the user wants schemes that work without tweaking.
- The ShellFish/iTerm2 OSC emission path, the status-bar format, or anything outside palette generation.
