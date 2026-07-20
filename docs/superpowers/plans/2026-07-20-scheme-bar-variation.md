# Scheme Bar Variation (v3.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Schemes present varied dominant colors — bar = a curated cell on the seed's depth row, cap derived from the bar by the calibrated kin-cap family rule, seed verbatim on tabs, accents from a rotating arc ring, text contrasting the actual bar.

**Architecture:** Engine-side (`conf.d/tmux-lives-install.fish`): two new pure tables (`__tmux_lives_theme_barpos`, `__tmux_lives_theme_kincap`), a new `__tmux_lives_theme_ring`, and a rewritten `__tmux_lives_theme_palette` derivation behind the SAME signature and 7-role output contract (fragment/CLI/apply-live untouched). Picker-side (`functions/tmux-categorize.fish`): the batch cache stores the ring so display-side rotation stays free, and `__tcz_thp_rotpal` permutes only the accent fields.

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's `t` harness.

**Spec:** `docs/superpowers/specs/2026-07-20-scheme-bar-variation-design.md` — read it first (the kin-cap family table and calibration record live there).

## Global Constraints

- Deploy = the user's `fisher update` ONLY; never touch `~/.config/fish/` or user universals outside test guards; never kill a running suite; tmux-driving tests pin the socket seam.
- fish gotchas (guard-enforced): NO command substitution inside quoted math strings (capture into a var first — the z-shake bug); `"$x[(math …)]"` banned; zero-output substitution as a bare `set` arg vanishes (capture-and-quote); no comparisons inside `math`; SGR via printf-captured vars; comments must not contain the literal `fish -c` nor quote banned patterns literally.
- Exact values from the spec: bar row = seed L ± ≤ 0.05 (recipe ΔL), clamp [0.05, 0.95]; kin-cap family offsets olive/green(90–160°)=+20, teal(160–210°)=+30, blue(210–280°)=+25, purple(280–330°)=+18 with muted C 0.05 default, warm/earth(40–90°)=+40, red/pink(330–40°)=+15; cap ΔL = 0.10 (dir: lighter for bar L < 0.55, else darker); muted caps only with ΔL ≥ 0.08 (0.10 satisfies); scheme capC overrides: span 0.04, full 0.05; `mono` bar == seed VERBATIM (lowercased, never resampled); tabs == seed verbatim (non-mono), mono tabs = ring position 1; rotation permutes ONLY sep/active/windows (ring positions via `((i - 1 - rot) % 5 + 5) % 5 + 1`); text = contrast side of the BAR (L = barL + dir·0.45 clamp [0.05,0.97], C 0.03, dir auto: barL < 0.55 → lighter).
- User-facing word is **scheme** (never palette/token in copy).
- Suites: `fish tests/test-tmux-install.fish` / `test-tmux-categorize.fish`; cross-check with `fish --no-config` (plain runs are flattered by the live fisher install); full gate `fish -c 'for t in tests/test-*.fish; fish $t; end'` both configs.
- Commit per task; push at branch completion.

## File Structure

- `conf.d/tmux-lives-install.fish` — Tasks 1–2 (tables, ring, palette).
- `functions/tmux-categorize.fish` — Task 3 (picker cache/rotpal).
- `tests/test-tmux-install.fish`, `tests/test-tmux-categorize.fish` — per task.
- `README.md`, `CLAUDE.md` — Task 4.

Branch: `git checkout -b feat/scheme-bar-variation` (from current `main`).

---

### Task 1: Pure tables — `__tmux_lives_theme_barpos` + `__tmux_lives_theme_kincap`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add both functions directly after `__tmux_lives_theme_arc` (~L603)
- Test: `tests/test-tmux-install.fish` (theme-engine section)

**Interfaces:**
- Consumes: `__tmux_lives_hex_to_rgb01`, `__tmux_lives_rgb_to_oklch`, `__tmux_lives_oklch_hex`, `__tmux_lives_norm360`.
- Produces (Task 2 consumes EXACTLY):
  - `__tmux_lives_theme_barpos <scheme>` → `seed` (mono) OR three lines: `t_bar`, `ΔL_bar`, `capC` (capC line may be empty). Unknown scheme → nothing.
  - `__tmux_lives_theme_kincap <barhex> [capC]` → one cap hex; empty capC → bar's own C (except purple family → 0.05).

- [ ] **Step 1: Failing tests** (in the install suite's theme section, inside its existing guards):

```fish
# --- v3.2 pure tables ---
set -l bp (__tmux_lives_theme_barpos warm)
t "barpos warm three lines" 3 (count $bp)
t "barpos warm t" 0.85 $bp[1]
t "barpos mono is the seed sentinel" seed (__tmux_lives_theme_barpos mono | string collect)
t "barpos span carries muted capC" 0.04 (__tmux_lives_theme_barpos span)[3]
t "barpos full carries muted capC" 0.05 (__tmux_lives_theme_barpos full)[3]
t "barpos fire lands warm-side" 0.05 (__tmux_lives_theme_barpos fire)[1]
t "barpos unknown -> nothing" 0 (count (__tmux_lives_theme_barpos nope))
# kincap: family offsets + depth step + muted rules
function __tlt_okl --argument-names hex
    set -l rgb (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]
end
set -l bar '#157058'   # teal family (H~173)
set -l cap (__tmux_lives_theme_kincap $bar)
set -l bo (__tlt_okl $bar)
set -l co (__tlt_okl $cap)
set -l dh (math "$co[3] - $bo[3]")
test $dh -gt 180; and set dh (math "$dh - 360")
test $dh -lt -180; and set dh (math "$dh + 360")
t "kincap teal offset +30 blueward" 1 (test $dh -ge 25 -a $dh -le 35; and echo 1; or echo 0)
t "kincap dark bar -> lighter cap" 1 (test (math "$co[1] - $bo[1]") -ge 0.06; and echo 1; or echo 0)
set -l capw (__tmux_lives_theme_kincap '#80551d')   # warm family
set -l cwo (__tlt_okl $capw)
set -l bwo (__tlt_okl '#80551d')
set -l dhw (math "$cwo[3] - $bwo[3]")
t "kincap warm offset ~+40" 1 (test $dhw -ge 33 -a $dhw -le 47; and echo 1; or echo 0)
set -l capp (__tmux_lives_theme_kincap '#6f5086')   # purple family, no capC arg
set -l cpo (__tlt_okl $capp)
t "kincap purple defaults muted" 1 (test $cpo[2] -le 0.07; and echo 1; or echo 0)
set -l capm (__tmux_lives_theme_kincap '#566829' 0.04)
set -l cmo (__tlt_okl $capm)
t "kincap honors explicit capC" 1 (test $cmo[2] -le 0.06; and echo 1; or echo 0)
set -l capl (__tmux_lives_theme_kincap '#c9d3b0')   # LIGHT bar -> darker cap
set -l clo (__tlt_okl $capl)
set -l blo (__tlt_okl '#c9d3b0')
t "kincap light bar -> darker cap" 1 (test (math "$blo[1] - $clo[1]") -ge 0.06; and echo 1; or echo 0)
functions -e __tlt_okl
```

- [ ] **Step 2: Run.** `fish tests/test-tmux-install.fish` — FAIL (functions undefined).

- [ ] **Step 3: Implement** (after `__tmux_lives_theme_arc`):

```fish
function __tmux_lives_theme_barpos --argument-names scheme --description 'v3.2 per-scheme bar recipe (calibrated 2026-07-20): "seed" for mono (bar = the seed verbatim), else three lines t_bar / dL_bar / capC ("" = cap wears the bar chroma). Bar samples the scheme arc at t_bar on the SEED-DEPTH row (seed L + dL_bar). Unknown scheme -> nothing.'
    switch $scheme
        case mono;       echo seed
        case warm;       printf '%s\n' 0.85 -0.03 ''
        case cool;       printf '%s\n' 0.15 -0.02 ''
        case span;       printf '%s\n' 0.30 0.02 0.04
        case wide;       printf '%s\n' 0.70 -0.04 ''
        case aurora;     printf '%s\n' 0.50 0.03 ''
        case sunset;     printf '%s\n' 0.90 -0.05 ''
        case fire;       printf '%s\n' 0.05 -0.03 ''
        case complement; printf '%s\n' 1.0 -0.02 ''
        case full;       printf '%s\n' 0.50 0 0.05
    end
end

function __tmux_lives_theme_kincap --argument-names barhex capc --description 'v3.2 kin-cap: derive the endcap FROM the bar so the dominant pair is good by construction (calibrated family offsets: olive/green +20, teal +30 blueward, blue +25, purple +18 muted, warm/earth +40, red/pink +15; cap L = bar L +/- 0.10 toward the light side of a dark bar; capc overrides chroma, purple defaults muted 0.05).'
    set -l rgb (__tmux_lives_hex_to_rgb01 $barhex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l H $ok[3]
    set -l off 15
    if test $H -ge 40; and test $H -lt 90
        set off 40
    else if test $H -ge 90; and test $H -lt 160
        set off 20
    else if test $H -ge 160; and test $H -lt 210
        set off 30
    else if test $H -ge 210; and test $H -lt 280
        set off 25
    else if test $H -ge 280; and test $H -lt 330
        set off 18
        test -n "$capc"; or set capc 0.05
    end
    set -l C $ok[2]
    test -n "$capc"; and set C $capc
    set -l dir 1
    test $ok[1] -ge 0.55; and set dir -1
    set -l capL (math "$ok[1] + $dir * 0.10")
    test $capL -lt 0.05; and set capL 0.05
    test $capL -gt 0.95; and set capL 0.95
    __tmux_lives_oklch_hex $capL $C (__tmux_lives_norm360 (math "$H + $off"))
end
```

- [ ] **Step 4: Run.** Install suite plain + `--no-config` — new tests PASS, nothing else disturbed.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): v3.2 pure tables — per-scheme bar recipes + calibrated kin-cap"`

---

### Task 2: Ring + rewritten palette derivation

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — new `__tmux_lives_theme_ring` before `__tmux_lives_theme_palette`; rewrite `__tmux_lives_theme_palette`'s body (~L619-668; signature UNCHANGED)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: Task 1 tables; existing `__tmux_lives_theme_arc/_roles/_sample`, `__tmux_lives_norm360`, `__tmux_lives_oklch_hex`, converters.
- Produces (Task 3 consumes EXACTLY):
  - `__tmux_lives_theme_ring <seedHex> <scheme> <phase> <vividness> <shape> <ease> <contrast>` → 5 arc-sample hexes (rotate-independent; the accent ring). Bad seed/scheme → nothing.
  - `__tmux_lives_theme_palette` — same 8-arg signature, same 7-line output (bar sep tabs active windows cap text), new derivation. Phase MOVES non-mono bars (it shifts the arc the bar samples); rotation NEVER moves bar/cap/tabs/text.

- [ ] **Step 1: Failing tests.** UPDATE the v3.1 pins that the new model deliberately changes, ADD the v3.2 contract (all inside the theme section's guards; `__tlt_L` helper pattern already exists there — recreate if the section deleted it):

Update/delete these existing tests:
- `"v31 bar IS the seed verbatim (lowercased)"` → keep but run against `mono` (not `wide`).
- `"v31 bar identical across schemes"` → DELETE (the point of v3.2 is that it's false).
- `"v31 phase never moves the bar"` → change to mono-only; ADD a non-mono positive test.
- `"v31 rot1 sep wears rot0 cap"` / `"v31 rot1 tabs wears rot0 sep"` / `"v31 rot1 cap wears rot0 windows"` → DELETE (cap/tabs no longer rotate); replaced below.

Add:

```fish
# --- v3.2 derivation contract ---
function __tlt_okl2 --argument-names hex
    set -l rgb (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]
end
set -l seedhex '#576733'
set -l so (__tlt_okl2 $seedhex)
# mono: bar == seed verbatim; non-mono: bar on the seed-depth row, NOT the seed
set -l pm (__tmux_lives_theme_palette $seedhex mono 0 balanced arc linear auto 0)
t "v32 mono bar is the seed verbatim" $seedhex $pm[1]
set -l pw (__tmux_lives_theme_palette $seedhex wide 0 balanced arc linear auto 0)
t "v32 wide bar differs from the seed" 0 (test "$pw[1]" = $seedhex; and echo 1; or echo 0)
set -l bo (__tlt_okl2 $pw[1])
t "v32 bar sits on the seed-depth row" 1 (test (math "abs($bo[1] - $so[1])") -le 0.06; and echo 1; or echo 0)
# tabs = seed verbatim (non-mono); mono tabs = ring pos 1
t "v32 tabs wear the seed" $seedhex $pw[3]
set -l ring (__tmux_lives_theme_ring $seedhex mono 0 balanced arc linear auto)
t "v32 ring has five samples" 5 (count $ring)
t "v32 mono tabs = ring pos 1" $ring[1] $pm[3]
# phase moves a non-mono bar; never the mono bar
set -l pw90 (__tmux_lives_theme_palette $seedhex wide 90 balanced arc linear auto 0)
t "v32 phase moves the wide bar" 0 (test "$pw90[1]" = "$pw[1]"; and echo 1; or echo 0)
set -l pm90 (__tmux_lives_theme_palette $seedhex mono 90 balanced arc linear auto 0)
t "v32 phase never moves the mono bar" $seedhex $pm90[1]
# rotation permutes ONLY sep/active/windows; bar/cap/tabs/text pinned
set -l r0 (__tmux_lives_theme_palette $seedhex wide 0 balanced arc linear auto 0)
set -l r2 (__tmux_lives_theme_palette $seedhex wide 0 balanced arc linear auto 2)
t "v32 rotation pins bar"  "$r0[1]" "$r2[1]"
t "v32 rotation pins tabs" "$r0[3]" "$r2[3]"
t "v32 rotation pins cap"  "$r0[6]" "$r2[6]"
t "v32 rotation pins text" "$r0[7]" "$r2[7]"
t "v32 rotation moves sep" 0 (test "$r0[2]" = "$r2[2]"; and echo 1; or echo 0)
# accents come from the ring via the perm index
set -l ringw (__tmux_lives_theme_ring $seedhex wide 0 balanced arc linear auto)
t "v32 rot0 sep = ring1" $ringw[1] $r0[2]
t "v32 rot0 active = ring2" $ringw[2] $r0[4]
t "v32 rot0 windows = ring3" $ringw[3] $r0[5]
t "v32 rot2 sep = ring4" $ringw[4] $r2[2]
# text contrasts the BAR
set -l to (__tlt_okl2 $r0[7])
t "v32 text on the bar's contrast side" 1 (test (math "abs($to[1] - $bo[1])") -ge 0.38; and echo 1; or echo 0)
# acceptance predicate across schemes x a seed panel (family offsets + dL band)
set -l pass 1
for ps in '#576733' '#223344' '#d8cfa8' '#808080' '#d02090'
    for tok in (__tmux_lives_theme_schemes)
        set -l pp (__tmux_lives_theme_palette $ps $tok 0 balanced arc linear auto 0)
        test (count $pp) -eq 7; or begin; set pass 0; break; end
        set -l pb (__tlt_okl2 $pp[1])
        set -l pc (__tlt_okl2 $pp[6])
        set -l pdh (math "$pc[3] - $pb[3]")
        test $pdh -gt 180; and set pdh (math "$pdh - 360")
        test $pdh -lt -180; and set pdh (math "$pdh + 360")
        set -l pdl (math "abs($pc[1] - $pb[1])")
        test (math "abs($pdh)") -le 50; or set pass 0
        test $pdl -ge 0.055; or set pass 0
        test $pdl -le 0.125; or set pass 0
    end
end
t "v32 acceptance predicate holds across the seed panel" 1 $pass
functions -e __tlt_okl2
```

- [ ] **Step 2: Run.** FAIL (ring undefined; old derivation).

- [ ] **Step 3: Implement.** New ring function (before the palette):

```fish
function __tmux_lives_theme_ring --argument-names seedHex scheme phase vividness shape ease contrast --description 'v3.2 accent ring: the 5 arc samples at the companion ladder (rotate-independent) -> 5 hexes one per line. Rotation cycles this ring onto sep/active/windows display-side; the ring is also the mono tabs source. Bad seed/scheme -> nothing.'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l arc (__tmux_lives_theme_arc "$scheme")
    test (count $arc) -eq 2; or return
    test -n "$phase"; or set phase 0
    test -n "$shape"; or set shape arc
    test -n "$ease"; or set ease linear
    test -n "$contrast"; or set contrast auto
    set -l cmax 0.105
    switch "$vividness"
        case soft;  set cmax 0.075
        case vivid; set cmax 0.130
    end
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l dir 1
    switch "$contrast"
        case darker
            set dir -1
        case lighter
            set dir 1
        case '*'
            test $ok[1] -ge 0.55; and set dir -1
    end
    for rt in (__tmux_lives_theme_roles)
        set -l parts (string split ' ' $rt)
        set -l L (math "$ok[1] + $dir * $parts[3]")
        test $L -lt 0.05; and set L 0.05
        test $L -gt 0.95; and set L 0.95
        set -l hx (__tmux_lives_theme_sample $parts[2] $L $ok[3] $arc[1] $arc[2] $phase $ok[2] $cmax $shape $ease)
        test -n "$hx"; or return
        printf '%s\n' $hx
    end
end
```

Rewritten `__tmux_lives_theme_palette` body (same signature/docstring updated; validation prologue as today):

```fish
function __tmux_lives_theme_palette --argument-names seedHex scheme phase vividness shape ease contrast rotate --description 'v3.2: seed + scheme/knobs -> 7 role hexes (bar sep tabs active windows cap text). Bar = the scheme recipe cell on the SEED-DEPTH row (mono = the seed verbatim); cap = kin-cap from the bar; tabs = the seed verbatim (mono: ring pos 1); sep/active/windows = the rotated accent ring; text contrasts the BAR. Rotation touches accents only. Non-hex seed or unknown scheme -> nothing.'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l bp (__tmux_lives_theme_barpos "$scheme")
    test (count $bp) -ge 1; or return
    set -l ring (__tmux_lives_theme_ring $seedHex "$scheme" "$phase" "$vividness" "$shape" "$ease" "$contrast")
    test (count $ring) -eq 5; or return
    string match -qr '^[0-4]$' -- "$rotate"; or set rotate 0
    test -n "$phase"; or set phase 0
    set -l cmax 0.105
    switch "$vividness"
        case soft;  set cmax 0.075
        case vivid; set cmax 0.130
    end
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l arc (__tmux_lives_theme_arc "$scheme")
    # bar: the recipe cell on the seed-depth row (mono: the seed verbatim)
    set -l bar (string lower -- $seedHex)
    set -l capc ''
    if test "$bp[1]" != seed
        set -l Lb (math "$ok[1] + $bp[2]")
        test $Lb -lt 0.05; and set Lb 0.05
        test $Lb -gt 0.95; and set Lb 0.95
        set bar (__tmux_lives_theme_sample $bp[1] $Lb $ok[3] $arc[1] $arc[2] $phase $ok[2] $cmax "$shape" "$ease")
        test -n "$bar"; or return
        set capc $bp[3]
    end
    set -l cap (__tmux_lives_theme_kincap $bar "$capc")
    test -n "$cap"; or return
    # tabs: home base — the seed verbatim; mono would duplicate the bar, so ring 1
    set -l tabs (string lower -- $seedHex)
    test "$bp[1]" = seed; and set tabs $ring[1]
    # accents: rotated ring positions 1..3 -> sep active windows
    set -l acc
    for i in 1 2 3
        set -l j (math "(($i - 1 - $rotate) % 5 + 5) % 5 + 1")
        set -a acc $ring[$j]
    end
    # text: the BAR's contrast side
    set -l bo2 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $bar))
    set -l tdir 1
    test $bo2[1] -ge 0.55; and set tdir -1
    set -l Lt (math "$bo2[1] + $tdir * 0.45")
    test $Lt -lt 0.05; and set Lt 0.05
    test $Lt -gt 0.97; and set Lt 0.97
    set -l text (__tmux_lives_oklch_hex $Lt 0.03 (__tmux_lives_norm360 (math "$bo2[3] + $arc[2] + $phase")))
    printf '%s\n' $bar $acc[1] $tabs $acc[2] $acc[3] $cap $text
end
```

NB `(__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $bar))` — nested substitution passing a 3-element list as 3 args is valid fish; if the reviewer prefers, capture the rgb list first (house style). The old body's support-loop and rotation-of-supports code is fully replaced; delete it.

- [ ] **Step 4: Run.** `fish tests/test-tmux-install.fish` AND `fish --no-config tests/test-tmux-install.fish` — ALL PASS (update any other stale v3.1 assertions the run surfaces — e.g. fragment tests asserting specific role hexes — to the new derivation's actual values, keeping their INTENT; list every such edit in the report).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): v3.2 palette — recipe bar on the seed row, kin-cap, seed tabs, accent ring"`

---

### Task 3: Picker — ring-aware cache + accent-only rotpal

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_rotpal` (~L1278), `__tcz_thp_reload` (~L1430), the anchor open-time palette call site does NOT change (it passes real rotate to the engine)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Task 2's `__tmux_lives_theme_ring` + palette semantics.
- Produces: `__tcz_thp_rotpal <rotate> <pal> <ring>` — pal fields 2 (sep), 4 (active), 5 (windows) replaced from the rotated ring; fields 1/3/6/7 untouched; non-7-field pal or non-5-field ring → pal unchanged. Reload caches `tok|pal0|ring|capfg|tabsfg` per scheme (fgs now rotation-independent — cap/tabs are pinned).

- [ ] **Step 1: Failing tests** (categorize suite; it already sources the engine):

```fish
# --- v3.2 rotpal: accents only, ring-fed ---
set -l vseed '#576733'
set -l vpal0 (__tmux_lives_theme_palette $vseed wide 0 balanced arc linear auto 0)
set -l vring (__tmux_lives_theme_ring $vseed wide 0 balanced arc linear auto)
set -l vp0 (string join ' ' $vpal0)
set -l vr (string join ' ' $vring)
for r in 0 1 2 3 4
    set -l eng (__tmux_lives_theme_palette $vseed wide 0 balanced arc linear auto $r)
    set -l engs (string join ' ' $eng)
    t "v32 rotpal parity r=$r" "$engs" (__tcz_thp_rotpal $r "$vp0" "$vr")
end
t "v32 rotpal degrades without a ring" "$vp0" (__tcz_thp_rotpal 2 "$vp0" '')
```

Also UPDATE the old rotpal tests (they assert the v3.1 permute-5-supports behavior against the OLD engine — the parity loop above replaces them; delete the stale block) and the reload fg-pick tests (`"fg pick: cap fg matches rotated pal"` etc.) — cap/tabs fgs are rotation-independent now; replace with:

```fish
set -l vrot3 (__tcz_thp_rotpal 3 "$vp0" "$vr")
set -l vrot3f (string split ' ' -- $vrot3)
t "v32 rotpal pins the cap field" $vpal0[6] $vrot3f[6]
t "v32 rotpal pins the tabs field" $vpal0[3] $vrot3f[3]
```

- [ ] **Step 2: Run.** FAIL (rotpal has the old signature/behavior).

- [ ] **Step 3: Implement.**

```fish
function __tcz_thp_rotpal --argument-names rotate pal ring --description 'v3.2 display-side rotation: replace pal fields 2/4/5 (sep active windows) from the rotated 5-sample accent ring (same perm index as the engine); bar/tabs/cap/text pinned. Malformed pal/ring -> pal unchanged.'
    set -l p (string split ' ' -- $pal)
    set -l g (string split ' ' -- $ring)
    if test (count $p) -ne 7; or test (count $g) -ne 5
        printf '%s' "$pal"
        return
    end
    string match -qr '^[0-4]$' -- "$rotate"; or set rotate 0
    set -l slots 2 4 5
    for i in 1 2 3
        set -l j (math "(($i - 1 - $rotate) % 5 + 5) % 5 + 1")
        set p[$slots[$i]] $g[$j]
    end
    printf '%s' (string join ' ' $p)
end
```

`__tcz_thp_reload`: the compute branch calls BOTH `__tmux_lives_theme_palette … $contrast 0` and `__tmux_lives_theme_ring … $contrast` per scheme; blob line becomes `tok|pal0|ring|capfg|tabsfg` (capfg = `contrast_fg` of pal0 field 6, tabsfg = of field 3 — both captured-and-quoted); the post-fetch loop applies `__tcz_thp_rotpal $rotate "$f[2]" "$f[3]"` for pals and reads the two fgs verbatim (no perm index math — delete the old `jc`/`jt` blocks).

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` plain + `--no-config` — ALL PASS.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): picker rotation is ring-fed and accent-only (bar/cap/tabs pinned)"`

---

### Task 4: Docs + full-suite gate

**Files:**
- Modify: `README.md` (Theming section), `CLAUDE.md` (theme paragraph append)

- [ ] **Step 1: README.** Rewrite the Theming section's model paragraph: schemes now offer VARIED dominant colors — each scheme places its bar at a different hue on your seed's depth; the endcaps are derived from the bar by a calibrated pairing rule so the dominant pair always works; your seed itself always appears (the ShellFish tabs wear it, and `mono` IS it); accents rotate with `o`; text stays contrast-safe automatically. Keep "scheme" vocabulary; don't rewrap unrelated content.

- [ ] **Step 2: CLAUDE.md.** Append one dense sentence to the theme paragraph: v3.2 scheme-bar-variation (spec `2026-07-20-scheme-bar-variation-design.md`) — grid model, per-scheme bar recipes on the seed-depth row (`__tmux_lives_theme_barpos`), calibrated kin-cap family rule (`__tmux_lives_theme_kincap`, 4-round visual-companion study, 9/10 acceptance vs 5/10 pre-rule), seed verbatim on tabs, accent ring + accents-only rotation (`__tmux_lives_theme_ring`, picker rotpal ring-fed), text contrasts the bar; live smoke pending.

- [ ] **Step 3: THE GATE.** `fish -c 'for t in tests/test-*.fish; fish $t; end'` AND the `--no-config` variant — all 8 suites ALL PASS; report both.

- [ ] **Step 4: Commit.** `git add -A && git commit -m "docs: v3.2 scheme bar variation — README/CLAUDE.md"`

---

## Post-plan (not tasks)

- Final whole-branch review (opus) → finishing-a-development-branch (merge to main + push).
- Runtime-only, user live smoke after `fisher update`: the ten schemes on the real bar + ShellFish tabs wearing the seed, phase now steering the bar hue, rotate shuffling accents only, anchor flip-flop across genuinely different bars.
