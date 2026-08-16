# Trio geometry — bar / tabs / cap — design record and decision register

**Status: DESIGN RECORDED, NOT BUILT. Possibly superseded** — the user raised a competing proposition on 2026-08-16 before this reached a full spec. Everything below is complete enough to resume from without re-deriving anything. No code was changed; the prototype referenced here is throwaway scratch, never installed.

**Date:** 2026-08-16. **Supersedes nothing** (the v5 big-area spec at `2026-08-01-theme-big-area-scheme-design.md` stays — its curve model is still what ships). **Cycle name:** started as "the accents redesign", became "trio geometry" once measurement showed the accents were the smaller half of the problem.

## Why this exists

The backlog called for an "accents redesign" on the premise that `__tmux_lives_theme_accents` ignores its `capHex` argument, making sep/active/windows/text scheme-blind — recorded as the root cause of the user's "too samesey" complaint. That premise is true but is roughly a third of the story, and acting on it alone would have fixed almost nothing.

## What was measured (all at the user's live seed `#97cb38`, 35 catalog rows)

Confirmed against live code, not inferred: `__tmux_lives_theme_accents` declares `capHex` at `conf.d/tmux-lives-install.fish:635` and never references it in the body. All four supporting roles are computed at the bar's hue, varying only in lightness.

- **The ink carries zero independent information.** Across all 595 scheme pairs, the number that share a bar but differ in ink is **0**. It is a pure function of the bar, so it can never distinguish two schemes the bar does not already distinguish.
- **Fixing the ink would not have repaired a single collision.** The colliding rows (`mono/mint/sage glow`, etc.) share a bar *and* a cap, so any ink computed from bar+cap stays identical. The ink can only carry information present in its inputs.
- **18 scheme pairs share 2 of their 3 big colours**, involving 25 of 35 schemes. Independently reproduces a prior session's separately-derived "18 pairs differ in exactly one role, always tabs".
- **Distinct colours per placement:** bar 11/35, tabs 11/35, cap 18/35.
- **The endcap collapses onto the tab colour.** `dH(tabs, cap) = | |travel| − max(|travel|/2, family) |`, which is **exactly zero when `|travel| = family`**. In every `derived` row the two are also pinned to the same depth: `capL = barL + 0.10` and `tabsL = barL + 0.11`, a 0.01 gap, always, at every seed.
- **Systemic, not seed-specific.** Tested at five seed hues (green/warm/blue/purple/red): **8–12 of 35 schemes on every one**, with the collision simply moving to whichever relationship matches that hue's `family` value.
- The user's own live theme `wheat slate` is one of them: tabs `#738e4a` and cap `#76885e` share hue to **0.2°** and lightness to **0.008**, differing only in saturation.

**Root cause of the collapse, and it is a scope gap rather than a blunder:** the family table was fitted in the 2026-07-20 blind study on **bar + endcap tiles judged as a pair, with no tab bar present**. The floor therefore guarantees the cap clears the *bar* and says nothing about the *tabs* — and when travel is small, "clear of the bar" puts it on the tabs.

**The depth collision specifically is a v5 regression.** v3.3 had a genuine ramp: bar → cap (+0.10) → tabs (+0.16). The v5 rewrite set tabs to a fixed `L 0.51` and left cap at `barL + 0.10 = 0.50`; nothing flagged that those coincide.

## The model chosen

The endcap stops being a **bridge** (v5 places it at half the travel, *between* the two large areas) and becomes an **accent** that extends *beyond* the bar→tabs hue span, continuing in the direction the relationship travelled.

- `Hcap = Htabs + dir · k`, so `dH(tabs,cap) = k` and `dH(bar,cap) = |travel| + k` are both bounded below **by construction**. There is always room outside an arc; there is never a guarantee of room inside one. No floor, no clamp, no special case.
- **Depth: three absolute targets, monotonic** — `bar → tabs (+d1) → cap (+d2)`. Targets stay *absolute* rather than anchored to the placed role. Anchor-relative was tried in the prototype and produced near-white status bars whenever a bright seed was pinned to the tabs or cap (the user's seed is `L 0.79`); today's absolute targets are correct and are retained.
- **Mode reaches the cap** via chroma, so `literal` and `derived` differ in the big 3 rather than only in the placed role.

### Measured effect of the prototype, same seed

| | today | proposed |
|---|---|---|
| smallest tabs↔cap hue gap | 0.1° | **19.2°** |
| tabs↔cap lightness gap | 0.01 | **~0.11** |
| pairs sharing 2 of 3 big colours | 18 | **2** |
| pairs sharing all 3 | 0 | 0 |

The 2 survivors are `sage core = teal core` and `amber deep = coral deep`, both in the 4-row `place=cap` minority — see D7.

## Decision register

The point of this table is operational: when the built thing is criticised, look up the symptom, and the alternatives are already listed. **Who** is `user` or `claude`; a `claude` decision is one the user explicitly delegated on 2026-08-16 ("I'd prefer to let you tackle all of these details… I'll decide once I start seeing what it will look like").

| ID | Decision | Who | Why | Alternatives if criticised | Symptom that points here |
|---|---|---|---|---|---|
| D1 | cmux is out of scope; design for the full ShellFish surface | user | "I won't be picking a scheme based on how it looks in cmux" | reinstate the cmux veto; add a bar+cap-only check | schemes look wrong in cmux/iTerm |
| D2 | The ink stays a pure function of the bar; it gets a "look its best" pass only, not a variety role | user | "accents are never the focus… I assume they're based on the bigger colors" | let ink take a hue pull toward the cap; give ink its own scheme input | supporting colours feel disconnected or samey |
| D3 | Target metric is "no two schemes repeat 2 of 3 big colours" | user | "little to no repetition of 2 colors in the same placements" | tighten to distinct-per-placement (bar/tabs/cap each 35/35); loosen to all-3-only | two schemes still feel like one |
| D4 | Restructure the geometry first, calibrate afterwards | user | a study fits constants inside a model and cannot tell you the model is wrong; the depth collision is structural | calibrate first on the current engine | the restructure lands somewhere nobody likes |
| D5 | Calibration happens against **live criticism after shipping**, not a blind tile study before it | claude | user prefers to judge the running thing; blind study becomes the fallback | run the 4-round blind tile protocol as originally planned | live iteration fails to converge |
| D6 | Endcap is an **accent beyond the pair**, not a bridge between it | claude (user picked from 3 options, "going with your recommended") | collision becomes impossible by construction rather than clamped away; 60-30-10 puts the distinct hue on the smallest surface | keep the bridge + enforce clearance; solve all three under explicit constraints | endcaps feel disconnected from the bar/tabs pair |
| D7 | Accept 2 residual `place=cap` pairs rather than special-casing them | claude | at that placement the cap is pinned to the seed and one of the pair must sit at the fixed offset from it, so same-direction relationships share 2 roles | scale `k` with `|travel|`; drop a `cap` tier row; give `place=cap` its own offset rule | `sage core`/`teal core` or `amber deep`/`coral deep` look identical |
| D8 | Depth ramp order: bar darkest → tabs → cap lightest | claude | monotonic ramp is the single most reproducible cohesion mechanism in the palette research (76% of well-regarded palettes) | cap between bar and tabs (today); tabs lightest (v3.3) | the endcap reads as too bright / floating |
| D9 | Depth targets stay **absolute**, not anchored to the placed role | claude | anchor-relative produced near-white status bars for bright seeds; measured in the prototype | anchor-relative with a clamp; hybrid | dark themes feel washed out, or literal placements look wrong |
| D10 | `d1 = 0.11`, `d2 = 0.11` | claude — **placeholder** | `d1` is today's shipped value; `d2` chosen to match it for a even ramp | any values; make them hue-dependent | the three bands feel unevenly spaced |
| D11 | Accent offset `k = family(seedHue)` | claude — **placeholder** | reuses the calibrated per-hue table as a starting magnitude, in a new role | constant `k`; `k` scaling with `|travel|`; refit per hue band | endcaps too close to, or too far from, the tab colour |
| D12 | Accent direction continues the travel direction (beyond the tabs) | claude | keeps the relationship's character; the accent extends the gesture rather than opposing it | opposite side; always beyond the dominant surface regardless of placement | endcap hue feels arbitrary relative to the scheme |
| D13 | At `travel = 0` (mono) the accent direction defaults to `+1` | claude | the pair is one hue so direction is undefined; `+1` matches today's mono behaviour | `-1`; per-seed rule | mono's endcap sits on the wrong side |
| D14 | Mode reaches the cap via **chroma** (`literal` ×1.35) | claude | without it `chip` and `slate` share bar and cap by construction — 7 of the 18 pairs | via depth; via hue; not at all (accept the pairs) | literal and derived variants feel like the same scheme |
| D15 | Cap chroma base raised from the bar's `0.045` to the tabs' `0.0713` | claude | today the accent is the *dullest* of the three, which is backwards for an accent | raise further; keep the bar's | endcaps look muddy / insufficiently distinct |
| D16 | Calibration target is the user's taste ("do you like it"), not defensible harmony | claude | resolves a question carried unanswered since 2026-08-07; the generator has exactly one user, who picks schemes for their own use | fit to harmony principles and accept schemes they like less | schemes are pleasant but not *theirs* |
| D17 | Caps travel further than before; v5's deleted taper is **not** reinstated | claude | the taper existed to mute far-travelled *bridges*, which no longer exist; muting pre-emptively would undo the fix | reinstate a taper; cap the maximum accent offset | bold relationships (teal, coral) read as garish |

**Placeholders (D10, D11, D15) are explicitly not defended.** They were chosen to make the geometry legible in a mockup, not because they are right. They are the first things to move under criticism.

## Not yet decided

- The ink's "look its best" pass (D2) has no concrete design. Minimum bar: verify contrast against the new bar lightnesses, since the ramp moves them.
- Whether `place=cap` keeps 4 catalog rows at all, given D7.
- Blast radius and test strategy were never written. `__tmux_lives_theme_curve` (`conf.d/tmux-lives-install.fish:813-909`) is the single function that changes; `__tmux_lives_theme_accents` (`:635`) is untouched under D2.

## Testing notes for whoever builds this

- **The `mono` regression anchor must move deliberately, not accidentally.** v5 pinned `mono` byte-identical to the pre-rewrite engine at both large areas (`#44502f` / `#5e7239`); this change alters the cap, so that anchor needs restating rather than deleting.
- Tolerances on rendered hexes are **2°**, because they quantise to 8-bit sRGB and gamut-clamp.
- Assert the two structural guarantees directly, since they are the whole point: `dH(tabs,cap) ≥ k` and `dH(bar,cap) ≥ k` for every catalog row at several seeds.
- Per this repo's standing lesson, prove every assertion FAILS against the pre-change engine before trusting it, and mutation-test the guards rather than reading them.

## Artifacts

- Mockup (today vs proposed, 20 comparisons, faithful ShellFish facsimile): `~/.claude-mock-shared/tmux-lives/content/trio-accent.html`, served at `https://tmux-lives.claude.lan`.
- Throwaway prototype and measurement probes: session scratchpad, `proto-trio.fish`, `measure-big3.fish`, `measure-within.fish`, `tabscap.fish`, `seeds.fish`. Not installed, not committed.
