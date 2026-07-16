# Theme engine v3 — gradient-map design

**Date:** 2026-07-16
**Status:** approved (design); pending spec review
**Supersedes:** the cap-color OKLCH v2 engine (geometric hue-harmony schemes + `cap_role`)
**Research:** [[palette-design-findings]] (100-agent verified study + local OKLCH measurement + colorhunt.co/gradient analysis, n=120)

## Summary

Replace the cap/theme engine's **geometric hue-harmony** model (complementary/triadic/split/tetradic/square rotations, each role assigned an independent hue at a fixed L/C) with a **gradient map**: a fixed set of UI **roles**, each pinned at a **lightness**, sampling a single **hue-arc gradient** derived from the user's seed. The number of colours is always exactly the number of roles; a role's hue is a function of its lightness (`hue = f(lightness)`), so "which colour goes where" is never arbitrary — it falls out of the value structure.

A theme is fully described by: **seed** (anchor hue + neutral), **scheme** (the gradient's arc — how wide a slice of the wheel), **phase** (rotate the arc — `←→`), and **knobs** (chroma, lightness range, chroma/hue shape). Everything from a subtle monochrome gradient to a full-circle rainbow is one point in this space, and every point is cohesive **by construction** because a monotonic lightness ramp is the cohesion mechanism (verified: 20/25 colorhunt palettes wider than 140° of hue are clean lightness ramps).

## Why the current engine fails

The v2 engine varies **hue and lightness and chroma simultaneously and independently** across roles — a ~10× chroma spread (0.02→0.19) at rotated hues — which is the precise inverse of every shipped design system studied. Geometric hue-wheel harmony (complementary/triadic/…) appears in **zero** shipped systems (Radix's generator = 0 hits for those terms; Nord's accents fit no rotation off any anchor; IBM Carbon **tried** computational generation and rejected it with our exact symptom: "colours that don't differentiate; too many landing dark"). What real systems do instead is a **value ramp at controlled hue/chroma**; a colorhunt "gradient" palette is a **monotonic lightness ramp through a hue window** (76% monotonic; 58% with chroma arcing to a mid-ramp peak). See [[palette-design-findings]] for the full evidence and the honest gaps.

## The model

### Roles and lightness anchors

A fixed ordered set of **roles**, each with a **lightness position** `t ∈ [0,1]` (0 = darkest, 1 = lightest). These `t` values ARE the "greyscale" the gradient maps onto.

| role | `t` | element(s) it colours |
|---|---|---|
| `bar` | 0.00 | tmux status-bar background (the trough) |
| `sep` | 0.32 | window separator, dim structural marks |
| `tabs` | 0.45 | the ShellFish toolbar colour (one OSC per client) |
| `active` | 0.55 | powerline mid-segment / active-window emphasis (provisional — may fold into `windows`/`text`) |
| `windows` | 0.60 | **all** inactive window names — ONE colour (never per-window) |
| `cap` | 0.70 | powerline cap background + `✦` identity mark (the accent) |
| `text` | 1.00 | current-window name (bold), centre identity text |

Notes:
- `windows` is a single role — the bar must never rainbow one colour per window.
- **Cap foreground is derived, not a role**: `cap_fg = contrast_fg(cap_bg)` (existing WCAG helper), so the accent text stays readable regardless of the cap's hue.
- The exact role list and `t` values are the primary thing to lock in review (§Open decisions #1); `active` in particular may be redundant.
- The ShellFish tab bar is a **single** settable colour (its OSC), so it maps to exactly one role (`tabs`). Active/inactive tab shading is ShellFish's own; we do not control it.

### The three curves

Given a seed and a scheme, the gradient is three coordinated functions of `t`:

- **Lightness** `L(t) = L0 + (L1−L0)·t` — monotonic ramp. Default `L0=0.20`, `L1=0.92`. This is the cohesion guarantee and is **never** violated (no role may take a colour of the wrong lightness — see §Rotation limit).
- **Hue** `H(t) = Hstart + (Hend−Hstart)·ease(t) + phase` — sweeps the arc across the ramp. `ease` is identity by default; an eased variant (e.g. `t³`) concentrates the hue shift toward the light end (matches the measured colorhunt reference `H: 141→130→130→83`).
- **Chroma** `C(t)` — an **arc with floors**: rises from `C0` at the dark end to `Cmax` at the peak, falls to `C1` at the light end. Default `C0=0.030`, `Cmax=0.120`, `C1=0.075`, peak at `t≈0.62` (near `cap`, making the cap the most-saturated point = the accent). Floors keep the ends tinted, never pure grey.

Each role samples `(L(t), C(t), H(t))` at its own `t`, then OKLCH→sRGB with the existing gamut clamp. Seven roles → seven colours.

### Scheme (the arc)

A **scheme** defines the gradient's arc as `(start, end)` hue **offsets relative to the seed's hue** (offset 0 = the seed). Width `= |end − start|` = how much of the wheel the gradient covers; sign = sweep direction (warm-first vs cool-first). Named presets (offsets, indicative — final values in the plan):

| scheme | arc offsets | character |
|---|---|---|
| `mono` | `0 → +45` | one colour, warm tail — the calm default |
| `warm` | `+8 → −64` | green → gold |
| `cool` | `+60 → −8` | teal → green |
| `span` | `+60 → −60` | teal → green → gold (seed centred) |
| `wide` | `+95 → −75` | blue → green → amber |
| `aurora` | `+120 → +30` | all-cool blue → cyan (seed absent) |
| `sunset` | `+150 → −90` | purple → teal → green → gold → peach |
| `fire` | `+130 → −44` | navy → red → coral → yellow highlight |
| `complement` | `+180 → −30` | seed's opposite in the trough |
| `full` | `0 → +360` | the whole wheel; seed bookends dark & light |

The seed need not appear in every scheme (`aurora` is all-cool). The seed always anchors the offset reference, the ShellFish base, and the neutral fallback.

### Phase (rotate — `←→`)

**Phase** is a hue offset added to the whole gradient. It rotates *which hue lands on each lightness slot* without touching the lightness structure. For `full`, the slice (the whole wheel) is unchanged and phase just rotates which element is green/blue/red/… For a narrower arc, phase slides the arc to a new part of the wheel (hue-shifts the whole theme). Continuous; `←→` nudges a few degrees per press. This reuses the picker key freed by removing `cap_role`.

### Rotation limit (the one honest constraint)

A colour cannot move to a role of the wrong lightness — the `bar` must stay dark or it stops being a readable background; `text` must stay light. So phase rotates hues **around** the fixed lightness ladder, never **across** it. Within that, any rotation is valid.

### Knobs (live-tunable)

- **chroma / vividness** — scales `Cmax` (e.g. soft 0.075 · balanced 0.105 · vivid 0.130).
- **lightness range** — `L0`/`L1` (trough depth / peak brightness; a "contrast" control).
- **chroma shape** — arc (mid-ramp pop) vs flat (even, truer rainbow).
- **hue easing** — linear vs eased (`t³`) hue distribution.

Schemes choose the arc + a default phase/direction; knobs reshape L/C/easing. The two are orthogonal.

## Element → role mapping

- **ShellFish toolbar**: `tabs` role, emitted as the existing `setbarcolor` OSC per client. `setup color` becomes a **seed** setter: it stores the seed; the emitted tab colour is the `tabs`-role sample, not the raw seed. (This changes the ShellFish path — the OSC value is now derived, not verbatim.)
- **tmux status bar** (`__tcz_status_format` + fragment `@options`): `bar` → status bg; `sep` → separators; `active` → current-window emphasis / powerline mid; `windows` → inactive window names; `cap` → cap bg + `✦`; `text` → current-window name + centre identity + cap fg base.
- **Static (not themed)**: prefix/resize mode indicators stay their fixed amber/orange — a mode alarm's job is to break the theme. Optionally **harmonised** toward the seed via M3's shipped `Blend.harmonize` (`rotation = min(Δhue·0.5, 15°)`, chroma & lightness preserved) so they lean into the theme without losing their alarm identity. Default: keep static; harmonize is a possible knob.

## Removed / renamed

- **Removed**: `cap_role` (the dim/muted/accent cap-column choice) + its universal + fragment argv + `setup cap --role`; the entire `__tcz_cap_inert` inert-marking cluster (it existed only to warn that `dim` made the scheme inert — moot once there are no palette roles to pick a cap from); all geometric-harmony scheme machinery (offset tables for complementary/triadic/split/tetradic/square as *harmony* — the arc offsets above are a different, simpler mechanism); the fixed per-role L/C constants.
- **Renamed**: `cap` → `theme` throughout the user surface — `setup cap` → `setup theme`, "cap-picker" → theme picker, universal `tmux_lives_cap*` → `tmux_lives_theme*`. The powerline "cap" element keeps its internal name; only the *feature* is "theme".
- **Kept**: the OKLCH core (`__tmux_lives_oklch_hex`, `rgb_to_oklch`, `target_hue`, gamut clamp, `contrast_fg`), the seed/`setup color` mechanism, the fragment/`@option` live-tunable architecture, the `-L`-socket test seam.

## Perceptual caveats (honest gaps)

The research's Q3 (Helmholtz-Kohlrausch, hue-dependent chroma ceilings, gamut mapping) **failed verification** — no evidence-backed formula exists; practitioners appear to hand-tune via exception tables. Consequences we accept and must handle:
- **Gamut clamping is hue-dependent.** At high lightness, warm hues reach higher chroma than blues; the clamp already handles this, but a requested `Cmax` may render lower at some hues. Acceptable — the ramp still reads correctly (verified in the mocks).
- **Equal OKLCH lightness ≠ equal apparent lightness** across hues (measured: L=0.68 spans sRGB luminance 135–150). We do not correct for this in v3; flagged for a possible per-hue lightness nudge later.
- **`text` must become luminance-adaptive.** The old `text` at fixed L0.90 is invisible on a *light* seed (contrast 8/255). The ramp's `L1` and the seed's own lightness must cooperate so the light end stays readable on the actual bar; on a light seed the ramp should invert (dark text end). This is a required fix, not optional.

## Picker UI

The picker is redesigned around the new controls: **scheme** (the arc — a list or a width slider), **phase** (`←→`), and the **knobs**. The gradient-map visual (a gradient strip with role sample-markers, as mocked) is the natural picker centrepiece. Detailed picker layout is deferred to its own design pass during planning — the current v2 cap-picker (flat scheme list + `←→` role-shift + `v`/`w`) is replaced, not extended.

## Testing

- **Pure engine** (install side, unit-tested): the sampler `sample(t, …) → hex`; monotonic-L assertion across roles; chroma-floor assertion (ends never pure grey); phase-rotation invariants (lightness unchanged under phase; hue offset applied); scheme arc math; luminance-adaptive `text` on light vs dark seeds; gamut-clamp behaviour at known-hard hues.
- **Fragment render** (`-L`-socket parse + `show -gv @…`): every role `@option` non-empty; single-quoted hex survives `source-file`; ShellFish `tabs`-role OSC derives correctly.
- **Picker draw**: source-grep guards (raw-tty loop is manual-smoke, as established).
- **Migration**: existing `tmux_lives_cap*` universals map to the new `theme*` set without loss.

## Migration

Existing users have `tmux_lives_cap` (scheme), `tmux_lives_cap_vividness`, `tmux_lives_cap_wheel`, `tmux_lives_cap_role`, `tmux_lives_cap_key`. A one-time shim on `fisher update`: rename `cap*`→`theme*` where meaningful; map old scheme tokens to nearest new scheme (or default to `mono`); **drop** `cap_role` (no equivalent); keep the keybind. Old geometric scheme names (`complementary`/`triadic±`/…) either alias to the nearest arc preset or reset to `mono` with a one-line notice. The user's live seed (`setup color`) is unchanged.

## Phasing

Large enough to build in stages (each shippable, subagent-driven, TDD):
- **Phase 1 — engine + tmux bar.** The gradient-map sampler, role set, scheme/phase/knob params, wire all tmux status roles, `text` luminance fix. Ships a working themed bar via the CLI (`setup theme <scheme>`, `--phase`, knobs). No picker changes yet.
- **Phase 2 — ShellFish + rename + migration.** `setup color`→seed, `tabs`-role OSC, `cap`→`theme` rename, migration shim, remove `cap_role`/inert cluster.
- **Phase 3 — picker redesign.** The gradient-map picker (scheme/phase/knobs, strip + markers).
- **Phase 4 (optional) — harmonize mode indicators**, per-hue lightness nudge, additional presets.

## Open decisions (for spec review)

1. **Role set + `t` anchors** — is the 7-role set right, and the `t` order/values? Notably: should `cap` be the lightest/most-saturated point rather than `t=0.70`?
2. **Cap chroma bump** — keep the chroma peak at the cap (accent pops) or let the cap be a plain sample?
3. **Default scheme** on first install — `mono` (calm) vs something with visible colour (`span`)?
4. **Mode indicators** — keep static, or harmonize toward the seed by default?
5. The user is **withholding one further thought** until seeing Phase 1 live — expect one more tweak after the first real render.

## Out of scope

- Per-hue apparent-lightness correction (Helmholtz-Kohlrausch) — deferred, no verified formula.
- ML/learned palette generation (the Huemint-style approach) — unverified, not pursued.
- Theming anything beyond the status bar + ShellFish tab colour.
