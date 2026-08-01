# Theme — big-area scheme derivation — design

Status: approved in brainstorm 2026-08-01 (visual companion mock `14-big-area-scheme.html`, rendered at the live seed `#4f8728`). Replaces the v4 curve derivation. The CLI surface, the 9-arg palette contract, the fragment argv positions, the seven role `@options`, the picker, and the ShellFish/iTerm2 tab emission are all **unchanged**. The ink (`__tmux_lives_theme_accents`) is **deliberately untouched**.

## Why

A scheme is supposed to read as "a palette built around the seed". It doesn't, and the cause is mechanical: **the endcap is the only role that travels the relationship's full hue distance.**

In `__tmux_lives_theme_curve`, the three roles sit at fixed curve positions — bar `t=0`, tabs `t=0.42`, cap `t=1` — and the hue at each is `H0 + sd·t`. So the cap absorbs the entire travel `sd` while the bar (at `t=0`) absorbs none. At `place=bar` the anchor re-anchoring makes `H0 = sH`, so the bar's hue is *exactly the seed's hue in every relationship* and the tab bar moves by only 42% of the travel.

Measured at seed `#4f8728`, `place=bar`, `mode=derived`, across all eight relationships:

| role | mono | sage | teal | coral |
|---|---|---|---|---|
| bar | `#405733` | `#405733` | `#405733` | `#405733` |
| tabs | `#547b3d` | `#3b7e50` | `#537767` | `#776e4e` |
| cap | `#6cb040` | `#00b496` | `#509ca6` | `#b87e6f` |

The bar is byte-identical in all eight. The tab bar barely separates. The endcap swings from bright green to bright teal to rust. **A scheme is therefore defined by the smallest swath on screen — a ~14-column endcap — while the two largest areas stay put.**

The supporting inks compound it: `__tmux_lives_theme_accents` declares `capHex` and never references it, computing `sep`/`active`/`windows`/`text` as lightness tints of the *bar's* hue at fixed chroma. Where the bar is invariant, so are they. That is not being changed here (see Non-goals) — it is recorded because it explains why nothing on the bar moved.

The user's framing, which scopes this work: everything derives from the seed at its placement, so a scheme should show *"a subtle but natural tendency to complement one colour more than the others"* — and the anchor should be the status bar or the tab bar, *"since they are the largest swaths of colour"*. Explicitly: **shift focus away from the endcaps and onto the placements that are truly driving the schemes.**

## The design

### 1. Two large areas and a bridge

The seed anchors one large area. The relationship sets how far the **other** large area travels from it. The endcap bridges between them.

```
place = bar     Hbar  = sH              Htabs = sH + sd
place = tabs    Htabs = sH              Hbar  = sH + sd
place = cap     Hbar  = sH − capΔ       Htabs = Hbar + sd      (cap carries the seed)
```

`sd` is the signed hue travel from `__tmux_lives_theme_reldef` (unchanged: `mono 0 · wheat −20 · mint +20 · amber −40 · sage +40 · ember −72 · teal +72 · coral −100`; negative is warm). `phase` is added uniformly to all three hues, preserving its existing meaning as a whole-palette rotation.

**Depth is fixed per role and never moves.** The bar is the dark ground, the tab bar one step lighter, the endcap one step off the bar. Hue differentiates; lightness coheres. This is the monotonic-ramp result from `[[palette-design-findings]]` — 76% of surveyed palettes are monotonic lightness ramps.

| role | lightness | chroma |
|---|---|---|
| bar | `0.40 + Ldamp` | `0.045 · Cscale` |
| tabs | `0.51 + Ldamp` | `0.071 · Cscale` |
| cap | `Lbar ± 0.10` (lighter iff `Lbar < 0.55`) | `Cbar` |

`Ldamp` and `Cscale` are carried over from the v4 curve unchanged — `Ldamp = clamp(0.5·(sL − 0.51), ±0.10)`, `Cscale = clamp(0.5·(sC/0.078 − 1) + 1, 0.6, 1.4)` — so a light or saturated seed still shapes the ramp. All lightnesses clamp to `[0.05, 0.95]`; chroma is gamut-clamped by `__tmux_lives_oklch_hex` as today.

The tab-bar chroma constant `0.071` is the value the deleted taper produced at zero travel (`capC 0.115 × 0.62`), so `mono` renders unchanged at that role.

### 2. The bridge rule

The endcap travels **half as far as the tab bar**, but never sits closer to the bar than the calibrated minimum separation for the bar's hue family:

```
half  = sd / 2                       (place = tabs: half = −sd / 2, so the cap comes back toward the tabs)
dir   = sign(half), +1 when half = 0
capΔ  = dir · max(|half|, family(Hbar))
Hcap  = Hbar + capΔ
```

So the endcap always echoes the scheme — which matters on a terminal with no tab bar, where the status bar is the only surface — and never leads it.

`family(hue)` is the **kin-cap family table fitted in the 2026-07-20 calibration study** (four rounds, user as blind subject, ~84% of judgments explained; the rule-generated validation batch scored 9/10 against 5/10 pre-rule). It was deleted in the v4 rewrite; this restores it in the role it was actually fitted for — bar and endcap judged as a pair.

| bar hue (OKLCH) | offset |
|---|---|
| 40–90° warm/earth | +40 |
| 90–160° olive/green | +20 |
| 160–210° teal | +30 |
| 210–280° blue | +25 |
| 280–330° purple | +18 |
| otherwise (red/pink) | +15 |

The study also fixed `ΔL(bar, cap) ∈ [0.06, 0.12]`, with muted caps (chroma 0.03–0.05) needing `ΔL ≥ 0.08`. The design's `ΔL 0.10` at `Ccap = Cbar` satisfies both.

**Cap placement** is the one case where the cap is not a bridge: it carries the seed (verbatim in `literal`, at cap depth/chroma with the seed's hue in `derived`), and the bar is solved backwards as `sH − capΔ`. Because `capΔ` depends on the bar's own hue, which is what we are solving for, the family offset is evaluated **at the seed's hue** — a deliberate single-pass approximation, deterministic and testable, not an iteration.

### 3. `literal` mode

Unchanged in meaning: the **placed** role renders the seed's exact hex, lowercased, never an OKLCH round-trip (which can drift a channel). The bridge is computed from the *rendered* bar so `literal` is honoured.

### 4. Retirements

- **`__tmux_lives_theme_taper` is deleted.** It existed solely to mute far-travelled endcaps past a direction-dependent knee. The endcap no longer travels far, so there is nothing to mute. This also removes the ember-knee constant (`62` warm / `40` cool) that cost a full debugging cycle — ember sat exactly on the knee, so `max(0, ΔH − knee)` was zero and the loudest relationship was the only one escaping the treatment.
- **`--place low|high` is retired.** They mean "partway along the curve" and this model has no curve to sit partway along. Neither has ever had a catalog row; the CLI was the only route. `__tmux_lives_migrate_v41` rewrites a stored `low`/`high` to `bar` with a one-line notice, idempotent, in the shape of v4's `--rotate` retirement. The CLI validator rejects them with a message naming `bar|tabs|cap`.

### 5. Catalog

Bar and tab placements become symmetric, since both are now first-class dominant placements. Cap-placed schemes survive as a deliberate **accent-led minority, ordered last**.

| tier | recipe | rows |
|---|---|---|
| `soft` | bar, derived | 8 |
| `glow` | bar, literal | 8 |
| `slate` | tabs, derived | 8 |
| `chip` | tabs, literal | 8 |
| `deep` | cap, derived | 2 |
| `core` | cap, literal | 2 |

**36 rows.** The four cap rows are the ones already curated as defaults: `amber deep`, `coral deep`, `sage core`, `teal core`.

The existing gaps in `slate` (5 rows) and `chip` (3 rows) were weeded against the *old* derivation, where a tabs-placed scheme moved the tab bar by only 42% of the travel. Those verdicts do not transfer, so the gaps are filled and the set is re-weeded from live use rather than pre-emptively.

Tier order is `soft glow slate chip deep core` — already the shipped order, so the "cap rows last" requirement needs no change.

Defaults: 14, spread across the safe→wild ladder in both dominant placements, plus the four cap rows.

## What deliberately does not change

- **The ink.** `__tmux_lives_theme_accents` is untouched — the user's explicit instruction: *"the ink isn't what needs changing currently. It should just keep doing the way it does."* A regression test pins its output byte-identical so a later refactor cannot drift it silently.
- **`active` stays dead.** `@tmux_lives_active_fg` is computed, pushed by both the fragment and `theme_apply_live`, and **read by nothing**. Removing it would ripple through the 7-role palette contract, the fragment argv, `apply_live`, and the picker's 7-cell swatch strips for zero visible gain. It stays, documented as dead.
- **Cap ink** (`@tmux_lives_cap_fg`) remains `__tmux_lives_contrast_fg` of the cap — flat WCAG black or white, not a palette role.
- The CLI surface (`setup theme <rel> --place --mode --phase …`), the 9-arg `__tmux_lives_theme_palette` signature, the fragment argv positions 12–18, the seven role `@options`, `__tmux_lives_theme_apply_live`'s two modes, the picker (both palette call sites stay 9-arg), and the ShellFish/iTerm2 OSC tab emission.

## Testing

Property assertions over hex pins wherever the property is the point, so a retune does not invalidate the suite.

**Engine (`tests/test-tmux-install.fish`):**
- **Anchor invariance** — at `place=bar` the bar hex is identical across all eight relationships; at `place=tabs` the tabs hex is.
- **Travel** — the tab-bar hue differs from the bar hue by the relationship's `|sd|` (within rounding), in the signed direction.
- **Bridge** — for `place=bar` and `place=tabs`, `|Hcap − Hbar|` equals `max(|sd|/2, family(Hbar))` exactly, on the travel's side (the `+` side when travel is zero). Note this is deliberately *not* "the cap lies between the bar and the tabs": at low travel the family floor dominates, so at `mono` the tabs sit at the bar's hue while the cap sits `family` away from it. The floor is the guarantee that the endcap never collapses into the bar.
- **Depth ramp** — `Lbar < Ltabs`, and `|Lcap − Lbar| ≈ 0.10`.
- **Literal** — the placed role equals the seed hex exactly, for each of the three placements.
- **Cap placement** — the cap carries the seed; the bar sits `capΔ` back from it.
- **Ink regression** — `__tmux_lives_theme_accents` output byte-identical to the pre-change values at a fixed seed.
- **Catalog composition** — 36 rows, 14 defaults, per-tier counts pinned **exactly** (a `>=` bound passed on the pre-cut catalog in the last weeding pass and caught nothing).
- **Migration** — `low`/`high` → `bar`, idempotent; a stored `bar`/`tabs`/`cap` is left alone.

**Guards (`tests/test-tmux-install.fish`):**
- `__tmux_lives_theme_taper` appears nowhere in the install file.
- No `low`/`high` place tokens outside the migration function (the `awk`-carve-out idiom already used for `tmux_lives_theme_rotate`).

Both fish modes (plain and `--no-config`), all eight suites green.

## Non-goals

- **The ink derivation.** `__tmux_lives_theme_accents` is cap-blind by construction — `sep`/`active`/`windows`/`text` are lightness tints of the bar hue, so where the bar is invariant they are too. Under this design the bar *does* move at `place=tabs` and `place=cap`, so the inks move with it; at `place=bar` they stay fixed, by design, because the anchor is fixed. Revisit only if live use says so.
- **`--vividness`, `--shape`, `--ease`, `--contrast` stay inert** — accepted, stored in universals, displayed in the picker, and reaching nothing. Named here because **vividness is the natural future home for a boldness dial**: it would scale the big areas' chroma, which is the lever if the far end of the ladder (sage/teal/coral at a saturated seed) proves too strong in live use.
- **A 20° relationship at seed-literal**, and any change to the relationship set.
- **Picker changes.** The gallery picker renders whatever the catalog and engine produce; it needs no edit.

## Open, for live judgment

- Whether the far end of the ladder is too bold on a large area at a saturated seed. The mock made the trade-off visible — today puts loud colour in a small endcap, this puts bold colour in a large area — but the verdict needs the real bar.
- Whether the filled `slate`/`chip` tiers all earn their place, and which four cap rows the accent-led minority should actually be.
