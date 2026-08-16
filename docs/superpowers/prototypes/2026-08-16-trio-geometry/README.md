# Trio geometry — frozen prototype and probes (2026-08-16)

**Frozen, not abandoned.** Work on this cycle stopped mid-design when a workflow proposition took priority. Everything needed to resume is here or in `../../specs/2026-08-16-trio-geometry-design.md`; nothing has to be re-derived. **No production code was changed** — the shipped engine is exactly as it was.

Originally scoped as "the accents redesign"; measurement showed the accents were the smaller half of the problem, so it became the trio geometry (bar / tabs / cap).

## Files

| file | what it is |
|---|---|
| `measure.fish` | All measurement probes, consolidated. Read-only and pure — `__tmux_lives_theme_palette` touches no universals and no tmux server, so it cannot affect a running install. |
| `proto-trio.fish` | **Throwaway prototype** of the proposed "accent outside the pair" geometry. Never installed. Sources the real engine for its OKLCH primitives and overrides only the trio derivation. |
| `check2.fish` | Runs the prototype across the catalog and prints the before/after metrics. |
| `mock.fish` | Regenerates the visual comparison. Writes to the claude-mock content dir. |
| `trio-accent.html` | The rendered mockup as it was shown — 20 today-vs-proposed comparisons, faithful ShellFish facsimile (46px tab strip at 50% width on a 23px status row, CSS-slant powerline caps). Committed because the claude-mock share is wiped by `claude-mock --reset`. |

## Running them

```fish
cd docs/superpowers/prototypes/2026-08-16-trio-geometry
fish measure.fish big3          # the target metric
fish measure.fish tabscap       # the collision, worst first
fish measure.fish seeds         # the systemic proof across five seed hues
fish measure.fish surfaces      # distinguishable appearances per terminal
fish measure.fish within        # closest pair inside one scheme
fish check2.fish                # prototype: before/after
fish mock.fish                  # regenerate the mockup
```

All take an optional seed argument; the default `#97cb38` is what the user was running when the study was done.

## The numbers, recorded so a thaw needs no re-run

Seed `#97cb38`, 35 catalog rows, against the engine at `e88eb7e`.

**Shipped engine:**

| measure | value |
|---|---|
| distinct per placement | bar **11**/35, tabs **11**/35, cap **18**/35 |
| pairs sharing all 3 big colours | 0 |
| pairs sharing 2 of 3 | **18** (involving 25 of 35 schemes) |
| pairs sharing a bar but differing in ink | **0** — the ink is a pure function of the bar |
| smallest tabs↔cap hue gap | **0.1°** |
| tabs↔cap lightness gap, derived rows | **0.01**, always |
| distinguishable in ShellFish / in cmux | 35 / **21** |

**Prototype (`proto-trio.fish`):**

| measure | value |
|---|---|
| pairs sharing 2 of 3 | **2** (`sage core = teal core`, `amber deep = coral deep` — both `place=cap`) |
| smallest tabs↔cap hue gap | **19.2°** |
| tabs↔cap lightness gap | ~0.11 |
| distinct per placement | bar 12, tabs 9, cap 18 |

**Systemic check** — schemes whose endcap is within 10° of the tab hue, by seed:

| seed | hue | family | hits |
|---|---|---|---|
| `#97cb38` | 127.3 | 20 | 12 / 35 |
| `#c9782f` | 58.6 | 40 | 8 / 35 |
| `#2f9ec9` | 228.9 | 25 | 8 / 35 |
| `#a8407f` | 346.2 | 15 | 8 / 35 |
| `#c94040` | 24.5 | 15 | 8 / 35 |

## Known gaps in the prototype

Not bugs to fix before resuming — deliberate limits of a throwaway.

- **`place=cap` is approximate.** It produces the 2 residual pairs (see `D7` in the spec). At that placement the cap is pinned to the seed and one of the pair must sit at the fixed accent offset from it, so relationships travelling the same direction share two roles.
- **Constants are placeholders**, chosen to make the geometry legible in a mockup, not defended: `P_D1 0.11`, `P_D2 0.11`, `P_CCAP 0.0713`, accent offset `k = family(seedHue)`, literal chroma ×1.35. These are spec entries `D10`, `D11`, `D15` and are the first things to move under criticism.
- **The ink is untouched.** Under `D2` it stays a pure function of the bar. It has had no "look its best" pass, and the ramp moves the bar's lightness, so its contrast should be re-checked whenever this resumes.
- `proto-trio.fish` **overrides nothing on disk** — it defines `proto_trio` alongside the real engine. Sourcing it in a shell is harmless.

## How to resume

1. Read `../../specs/2026-08-16-trio-geometry-design.md` — problem, model, and the 17-entry decision register.
2. Run `fish check2.fish` to confirm the numbers still reproduce against whatever the engine is by then.
3. The register's "alternatives if criticised" column is the menu; the "symptom" column is the index into it.
4. The build itself was never planned. `__tmux_lives_theme_curve` (`conf.d/tmux-lives-install.fish:813-909`) is the single function that changes.
