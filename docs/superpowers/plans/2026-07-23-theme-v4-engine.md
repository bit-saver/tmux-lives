# Theme v4 Engine + CLI Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v3.3 bar/tabs/cap derivation (`arc`/`barpos`/`kincap`/`kintabs`/`ring`/`rotate`) with the calibrated v4 model — a curve selected by a signed **relationship**, a seed **placement**, a **mode** (literal/derived), and an endcap **taper** — exposed through `tmux-lives setup theme` and baked into the managed fragment.

**Architecture:** All work is install-side in `conf.d/tmux-lives-install.fish` (pure OKLCH builders + the `setup theme` CLI + fragment render + migration). The existing OKLCH primitives (`__tmux_lives_oklch_hex`, `_rgb_to_oklch`, `_hex_to_rgb01`, `_norm360`, `_contrast_fg`) are reused unchanged. The 7-role output contract (`bar sep tabs active windows cap text`) and every downstream consumer (`status-style`, the `@tmux_lives_*` options, `__tcz_status_format`) are preserved, so the fragment and status bar keep working. The theme picker (`functions/tmux-categorize.fish`, `__tcz_thp_*`) is **out of scope** — Phase 2.

**Tech Stack:** fish 4.x, tmux 3.3a, the repo's `tests/test-*.fish` harness (bespoke `t` assertion helpers, `-L`-socket isolation, `set -U` save/clear/restore).

## Global Constraints

- **Deploy is the user's `fisher update` only** — never `cp` into `~/.config/fish` or set the user's universals to "ship" anything. Edit → test → commit → push → stop.
- **Run the suite under BOTH `fish` and `fish --no-config`** — plain runs are flattered by the live fisher install shadowing removed functions. A task is not green until both pass.
- **Never kill a running suite** — aborted runs leak the machine's real universals (the suites `set -U`).
- **fish landmines** (all previously bit this repo): `math` has NO comparison operators (`math "$a >= $b"` errors — branch with `test`); NO command substitution inside double-quoted `math` (`math "(random) * 5"` takes the literal text — capture into a `$var` first); a zero-output command substitution used as a bare argument VANISHES from the arg list (capture into a var, then use); `"$x[(math …)]"` is an "Invalid index value" error (capture the index first); an unmatched glob yields zero loop iterations silently; `set -l H …` at a script's top level is NOT visible inside a called function (pass it as an argument).
- **Grep-guard placement:** a guard referencing `$catfile`/source paths must appear AFTER that variable is defined in the test file, or it silently passes against an empty path.
- **OKLCH primitive signatures** (reuse, do not reimplement): `__tmux_lives_oklch_hex <L> <C> <H>` → `#rrggbb`; `__tmux_lives_hex_to_rgb01 <#rrggbb>` → `r g b` (3 lines); `__tmux_lives_rgb_to_oklch <r> <g> <b>` → `L C H` (3 lines); `__tmux_lives_norm360 <deg>` → `[0,360)`; `__tmux_lives_contrast_fg <#rrggbb|colourN>` → `#111111`|`#f5f5f5`.
- **Seed reference used throughout the spec:** `#5f772b` → OKLCH `L≈0.533 C≈0.106 H≈124.7`.

---

## File Structure

- `conf.d/tmux-lives-install.fish` — all engine, CLI, fragment, migration changes.
  - Replace: `__tmux_lives_theme_arc`, `_barpos`, `_kincap`, `_kintabs`, `_roles`, `_ring` (v3 trio + accent-ring derivation).
  - Rewrite signature: `__tmux_lives_theme_palette`.
  - Add: `__tmux_lives_theme_relationships`, `_reldef`, `_taper`, `_curve`, `_accents`, `_migrate_v4`.
  - Modify: `_theme_valid`, `_theme_apply_live`, `_theme_list`, `_theme_cmd`, `__tmux_lives_render_fragment`, `_tmux_lives_post_update`.
  - Keep untouched: `_theme_sample` is superseded but leave removal to the task that stops calling it; `_theme_push` unchanged.
- `tests/test-tmux-install.fish` — all new/changed test cases.

**Universals (v4):** `tmux_lives_theme` (relationship name; default `mono`), `tmux_lives_theme_place` (default `bar`), `tmux_lives_theme_mode` (default `derived`), plus the carried-over `tmux_lives_theme_phase|_vividness|_shape|_ease|_contrast`. **Retired:** `tmux_lives_theme_rotate`.

**Accent decision (spec-completion, uncalibrated, live-tunable):** `sep/active/windows` are lightness tints on the bar hue, `text` is the bar's contrast side (as v3.2). Exact L values live as constants in `__tmux_lives_theme_accents` and reach the user as the existing `@tmux_lives_sep_fg/_active_fg/_text_fg` options.

---

## Task 1: Relationship table (`_relationships`, `_reldef`, `_valid`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add `__tmux_lives_theme_relationships`, `__tmux_lives_theme_reldef`; rewrite `__tmux_lives_theme_valid`; the v3 `__tmux_lives_theme_schemes` is replaced by `_relationships`).
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces:
  - `__tmux_lives_theme_relationships` → the relationship names, one per line: `mono amber ember coral sage teal`.
  - `__tmux_lives_theme_reldef <name>` → one signed integer = signed hue travel (warm negative, cool positive): `mono 0`, `amber -40`, `ember -72`, `coral -100`, `sage 40`, `teal 72`. Unknown name → nothing (empty output, the failure signal).
  - `__tmux_lives_theme_valid <token>` → status 0 iff `<token>` is a relationship name.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-install.fish` (after the existing theme-engine tests; find them with `grep -n theme_palette tests/test-tmux-install.fish`):

```fish
# ---- v4: relationship table ----
t "relationships list" "mono amber ember coral sage teal" (__tmux_lives_theme_relationships | string join ' ')
t "reldef mono is flat"   0    (__tmux_lives_theme_reldef mono)
t "reldef amber warm 40"  -40  (__tmux_lives_theme_reldef amber)
t "reldef ember warm 72"  -72  (__tmux_lives_theme_reldef ember)
t "reldef coral warm 100" -100 (__tmux_lives_theme_reldef coral)
t "reldef sage cool 40"   40   (__tmux_lives_theme_reldef sage)
t "reldef teal cool 72"   72   (__tmux_lives_theme_reldef teal)
t "reldef unknown empty"  ""   (__tmux_lives_theme_reldef nope)
t "valid ember" 0 (__tmux_lives_theme_valid ember; echo $status)
t "valid junk"  1 (__tmux_lives_theme_valid junk; echo $status)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `Unknown command: __tmux_lives_theme_relationships` (and the `reldef`/`valid` assertions fail).

- [ ] **Step 3: Write minimal implementation**

In `conf.d/tmux-lives-install.fish`, replace `__tmux_lives_theme_schemes` with:

```fish
function __tmux_lives_theme_relationships --description 'v4 relationship names (signed hue travels), one per line — the ONE home of the list (CLI validation, list, picker all consume it)'
    printf '%s\n' mono amber ember coral sage teal
end

function __tmux_lives_theme_reldef --argument-names name --description 'v4 relationship -> signed hue travel in degrees (warm negative, cool positive); unknown -> nothing'
    switch "$name"
        case mono;  echo 0
        case amber; echo -40
        case ember; echo -72
        case coral; echo -100
        case sage;  echo 40
        case teal;  echo 72
    end
end
```

Rewrite `__tmux_lives_theme_valid`:

```fish
function __tmux_lives_theme_valid --argument-names token --description 'true if token is a v4 relationship name'
    contains -- "$token" (__tmux_lives_theme_relationships)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS (`ALL PASS (N)`).

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 relationship table (signed named travels)"
```

---

## Task 2: Endcap taper (`_taper`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add `__tmux_lives_theme_taper`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: nothing.
- Produces: `__tmux_lives_theme_taper <signeddrift>` → three lines `capC capL tabsC`. Knee is direction-dependent (warm = negative drift, knee 72; cool = positive drift, knee 40). Past the knee, chroma and lightness ramp down to a floor; `tabsC = capC * 0.62`.

Formula (copy verbatim):
```
adrift = abs(signeddrift)
knee   = 72 if signeddrift < 0 else 40      # warm reaches further than cool
excess = max(0, adrift - knee)
capC   = clamp(0.115 - 0.0025*excess, 0.055, 0.115)
capL   = clamp(0.66  - 0.001 *excess, 0.62,  0.66)
tabsC  = capC * 0.62
```

- [ ] **Step 1: Write the failing test**

```fish
# ---- v4: endcap taper ----
# near relationships stay vivid; far ones hit the muted floor
t "taper mono vivid C"    0.115 (__tmux_lives_theme_taper 0    | sed -n 1p)
t "taper mono vivid L"    0.66  (__tmux_lives_theme_taper 0    | sed -n 2p)
t "taper ember vivid C"   0.115 (__tmux_lives_theme_taper -72  | sed -n 1p)   # warm knee 72: excess 0
t "taper sage vivid C"    0.115 (__tmux_lives_theme_taper 40   | sed -n 1p)   # cool knee 40: excess 0
t "taper coral floor C"   0.055 (__tmux_lives_theme_taper -100 | sed -n 1p)   # warm excess 28 -> below floor -> clamp
t "taper coral floor L"   0.62  (__tmux_lives_theme_taper -100 | sed -n 2p)
t "taper teal floor C"    0.055 (__tmux_lives_theme_taper 72   | sed -n 1p)   # cool excess 32 -> floor
t "taper tabsC follows"   1     (set -l l (__tmux_lives_theme_taper 72); test (math "abs($l[3] - $l[1]*0.62) < 0.0001") = 1; and echo 1; or echo 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `Unknown command: __tmux_lives_theme_taper`.

- [ ] **Step 3: Write minimal implementation**

Add near the other v4 builders:

```fish
function __tmux_lives_theme_taper --argument-names signeddrift --description 'v4 endcap taper (calibrated 2026-07-23): past a direction-dependent knee (72 warm / 40 cool) the endcap chroma AND lightness ramp down to a floor so a far hue stops clashing with the muted dark bar -> "capC capL tabsC". Near relationships stay vivid.'
    set -l ad (math "abs($signeddrift)")
    set -l knee 40
    test $signeddrift -lt 0; and set knee 72
    set -l excess (math "max(0, $ad - $knee)")
    set -l capC (math "0.115 - 0.0025 * $excess")
    test (math "$capC < 0.055") = 1; and set capC 0.055
    test (math "$capC > 0.115") = 1; and set capC 0.115
    set -l capL (math "0.66 - 0.001 * $excess")
    test (math "$capL < 0.62") = 1; and set capL 0.62
    test (math "$capL > 0.66") = 1; and set capL 0.66
    printf '%s\n' $capC $capL (math "$capC * 0.62")
end
```

Note: `test $signeddrift -lt 0` uses integer `test` (drifts are whole degrees) — correct and avoids the `math` comparison landmine.

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 endcap chroma/lightness taper"
```

---

## Task 3: The curve — bar/tabs/cap trio (`_curve`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add `__tmux_lives_theme_curve`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_reldef`, `__tmux_lives_theme_taper`, the OKLCH primitives.
- Produces: `__tmux_lives_theme_curve <seedHex> <relationship> <place> <mode> <phase>` → three hexes `bar tabs cap`, one per line. Non-hex seed or unknown relationship → nothing.

Algorithm:
1. Validate `seedHex` is `#rrggbb`; else return nothing.
2. `sd = reldef(relationship)`; if empty → return nothing.
3. Seed OKLCH → `sL sC sH`.
4. **Derived-mode ramp anchors** (base curve, with damped seed influence):
   - `Ldamp = clamp(0.5*(sL - 0.51), -0.10, 0.10)` — applied to every role's L target.
   - `Cscale = clamp(0.5*(sC/0.078 - 1) + 1, 0.6, 1.4)` — scales the chroma targets (damped around the 0.078 reference).
   - taper: `capC capL tabsC = taper(sd)`.
   - bar:  `Lbar = clamp(0.40 + Ldamp, .05,.95)`, `Cbar = 0.045*Cscale`, `Hbar = norm360(sH + phase)`.
   - tabs: `Ltabs = clamp(0.51 + Ldamp, .05,.95)`, `Ctabs = tabsC*Cscale`, `Htabs = norm360(sH + sd*0.42 + phase)`.
   - cap:  `Lcap  = clamp(capL + Ldamp, .05,.95)`, `Ccap = capC*Cscale`, `Hcap  = norm360(sH + sd + phase)`.
5. **Placement + mode.** `place ∈ {bar,tabs,cap,low,high}`; `low`/`high` force derived. Let `tplace` be the seed's position: `bar 0`, `tabs .42`, `cap 1`, `low .25`, `high .75`. The seed's hue anchor becomes `sH - sd*tplace` so that role's hue lands on `sH` (the seed's own hue) — i.e. re-anchor the whole curve so the placed position carries the seed hue. Recompute the three role hues with the re-anchored `H0 = sH - sd*tplace`: `Hrole = norm360(H0 + sd*trole + phase)`.
6. **Literal mode** (only meaningful for `place ∈ {bar,tabs,cap}`): the placed role additionally renders the seed's exact `sL`/`sC` (not just its hue). Set that role's `L = sL`, `C = sC`. The other two roles keep their derived L/C but their hues already re-anchor through the placed position (step 5), so the ramp stays coherent. Clamp all L to `[.05,.95]`.
7. Emit `bar tabs cap`.

- [ ] **Step 1: Write the failing test**

The calibration generators used a fixed ramp; derived mode adds damped seed L/C, so exact-hex pins would be brittle. Assert **properties** for derived roles (family/ranges via OKLCH) and keep **exact** only where the spec demands it — literal placement renders the seed verbatim. Helper (define once near the top of the test file if not already present):

```fish
function _oklch_of --argument-names hex   # -> "L C H"
    set -l r (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $r[1] $r[2] $r[3]
end
```

```fish
# ---- v4: curve (bar/tabs/cap) ----
set -l seed '#5f772b'
set -l so (_oklch_of $seed)          # 0.533 0.106 124.7
set -l tri (__tmux_lives_theme_curve $seed ember bar derived 0)
t "curve returns 3" 3 (count $tri)
t "curve bar is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $tri[1]; and echo 1; or echo 0)
t "curve cap is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $tri[3]; and echo 1; or echo 0)
# bar: dark olive family — near the seed hue, dark, modest chroma
set -l bo (_oklch_of $tri[1])
t "curve bar dark"          1 (test (math "$bo[1] > 0.37") = 1; and test (math "$bo[1] < 0.46") = 1; and echo 1; or echo 0)
t "curve bar near seed hue" 1 (test (math "abs($bo[3] - $so[3]) < 6") = 1; and echo 1; or echo 0)
# ember cap: warm side (~72 deg toward gold), still vivid
set -l co (_oklch_of $tri[3])
t "curve ember cap warm"  1 (test (math "abs($co[3] - ($so[3] - 72)) < 8") = 1; and echo 1; or echo 0)
t "curve ember cap vivid" 1 (test (math "$co[2] > 0.10") = 1; and echo 1; or echo 0)
# coral: tapered -> the cap is muted (lower chroma than a vivid cap)
set -l cco (_oklch_of (__tmux_lives_theme_curve $seed coral bar derived 0)[3])
t "curve coral cap muted" 1 (test (math "$cco[2] < 0.09") = 1; and echo 1; or echo 0)
# literal cap: the endcap renders the seed's EXACT hex
set -l tril (__tmux_lives_theme_curve $seed ember cap literal 0)
t "curve literal cap = seed" "#5f772b" $tril[3]
# literal bar: the bar renders the seed's EXACT hex
set -l trilb (__tmux_lives_theme_curve $seed ember bar literal 0)
t "curve literal bar = seed" "#5f772b" $trilb[1]
# bad inputs -> nothing
t "curve bad seed empty" 0 (count (__tmux_lives_theme_curve 'notahex' ember bar derived 0))
t "curve bad rel empty"  0 (count (__tmux_lives_theme_curve $seed nope bar derived 0))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `Unknown command: __tmux_lives_theme_curve`.

- [ ] **Step 3: Write minimal implementation**

```fish
function __tmux_lives_theme_curve --argument-names seedHex relationship place mode phase --description 'v4 core: seed + relationship(signed travel) + placement + mode -> bar tabs cap (3 hexes). Derived: seed hue anchors the re-anchored curve, seed L/C damped into the ramp; literal: the placed role renders the seed verbatim. Endcap tapered. Non-hex seed / unknown relationship -> nothing.'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l sd (__tmux_lives_theme_reldef "$relationship")
    test -n "$sd"; or return
    test -n "$phase"; or set phase 0
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l sL $ok[1]; set -l sC $ok[2]; set -l sH $ok[3]
    # damped seed influence on the derived ramp
    set -l Ldamp (math "0.5 * ($sL - 0.51)")
    test (math "$Ldamp < -0.10") = 1; and set Ldamp -0.10
    test (math "$Ldamp > 0.10") = 1; and set Ldamp 0.10
    set -l Cscale (math "0.5 * ($sC / 0.078 - 1) + 1")
    test (math "$Cscale < 0.6") = 1; and set Cscale 0.6
    test (math "$Cscale > 1.4") = 1; and set Cscale 1.4
    set -l tp (__tmux_lives_theme_taper $sd)  # capC capL tabsC
    # placement: re-anchor so the placed position carries the seed hue
    set -l tplace 0
    switch "$place"
        case tabs; set tplace 0.42
        case cap;  set tplace 1
        case low;  set tplace 0.25; set mode derived
        case high; set tplace 0.75; set mode derived
        case '*';  set tplace 0
    end
    set -l H0 (math "$sH - $sd * $tplace")
    # role L/C/H (derived)
    set -l Lbar (math "0.40 + $Ldamp")
    set -l Ltabs (math "0.51 + $Ldamp")
    set -l Lcap (math "$tp[2] + $Ldamp")
    set -l Cbar (math "0.045 * $Cscale")
    set -l Ctabs (math "$tp[3] * $Cscale")
    set -l Ccap (math "$tp[1] * $Cscale")
    set -l Hbar (__tmux_lives_norm360 (math "$H0 + $sd * 0 + $phase"))
    set -l Htabs (__tmux_lives_norm360 (math "$H0 + $sd * 0.42 + $phase"))
    set -l Hcap (__tmux_lives_norm360 (math "$H0 + $sd * 1 + $phase"))
    # clamp the three L values (unrolled — avoids the $$var-indirection gotcha)
    test (math "$Lbar < 0.05") = 1; and set Lbar 0.05
    test (math "$Lbar > 0.95") = 1; and set Lbar 0.95
    test (math "$Ltabs < 0.05") = 1; and set Ltabs 0.05
    test (math "$Ltabs > 0.95") = 1; and set Ltabs 0.95
    test (math "$Lcap < 0.05") = 1; and set Lcap 0.05
    test (math "$Lcap > 0.95") = 1; and set Lcap 0.95
    set -l bar (__tmux_lives_oklch_hex $Lbar $Cbar $Hbar)
    set -l tabs (__tmux_lives_oklch_hex $Ltabs $Ctabs $Htabs)
    set -l cap (__tmux_lives_oklch_hex $Lcap $Ccap $Hcap)
    # literal: the placed role renders the seed's EXACT hex (verbatim, not a
    # recompute — an OKLCH round-trip can drift a channel). The re-anchor above
    # already lands that role's derived hue on the seed hue, so the ramp stays
    # coherent; this just pins L and C to the seed too.
    if test "$mode" = literal
        set -l s (string lower -- $seedHex)
        switch "$place"
            case bar;  set bar $s
            case tabs; set tabs $s
            case cap;  set cap $s
        end
    end
    printf '%s\n' $bar $tabs $cap
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS. The assertions are property-based (hue/lightness/chroma ranges + exact seed for literal), so they do not depend on the exact damping constants. To eyeball the actual colors: `fish -c 'source conf.d/tmux-lives-install.fish; __tmux_lives_theme_curve "#5f772b" ember bar derived 0'` should print a dark olive bar, a muted olive tab, and a warm gold cap.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 curve — placement + mode + damped ramp"
```

---

## Task 4: Accents + palette assembly (`_accents`, rewrite `_palette`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add `__tmux_lives_theme_accents`; rewrite `__tmux_lives_theme_palette`; delete `__tmux_lives_theme_arc`, `_barpos`, `_kincap`, `_kintabs`, `_roles`, `_ring`, `_sample`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_curve`, the OKLCH primitives.
- Produces:
  - `__tmux_lives_theme_accents <barHex> <capHex>` → four hexes `sep active windows text`, one per line. `active/windows/sep` are lightness tints on the bar hue (bright/mid/dim, contrast side of the bar); `text` is the bar's far contrast side (as v3.2). Constants: active L 0.88, windows L 0.74, sep L 0.62, all C 0.03 at the bar hue but flipped to the light side when the bar is light; text L = barL±0.45.
  - `__tmux_lives_theme_palette <seedHex> <relationship> <place> <mode> <phase> <vividness> <shape> <ease> <contrast>` → **7 hexes** `bar sep tabs active windows cap text`, one per line (the unchanged downstream contract). Non-hex seed / unknown relationship → nothing. `vividness/shape/ease/contrast` are accepted for signature compatibility and future use; in Phase 1 only `phase` shapes the curve (document this in the description).

- [ ] **Step 1: Write the failing test**

```fish
# ---- v4: accents + palette ----
set -l seed '#5f772b'
set -l pal (__tmux_lives_theme_palette $seed ember bar derived 0 balanced arc linear auto)
t "palette returns 7" 7 (count $pal)
for i in 1 2 3 4 5 6 7
    t "palette role $i is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $pal[$i]; and echo 1; or echo 0)
end
# the trio matches the curve for the same inputs (order: bar[1] tabs[3] cap[6])
set -l tri (__tmux_lives_theme_curve $seed ember bar derived 0)
t "palette bar = curve bar"   $tri[1] $pal[1]
t "palette tabs = curve tabs" $tri[2] $pal[3]
t "palette cap = curve cap"   $tri[3] $pal[6]
# windows (status-style fg, on the dark bar) must be light for contrast
set -l wrgb (__tmux_lives_hex_to_rgb01 $pal[5])
set -l wok (__tmux_lives_rgb_to_oklch $wrgb[1] $wrgb[2] $wrgb[3])
t "palette windows is light" 1 (test (math "$wok[1] > 0.60") = 1; and echo 1; or echo 0)
t "palette bad seed empty" 0 (count (__tmux_lives_theme_palette nope ember bar derived 0 balanced arc linear auto))
# the retired v3 builders are gone
t "arc retired"    "" (functions -q __tmux_lives_theme_arc; and echo present)
t "kincap retired" "" (functions -q __tmux_lives_theme_kincap; and echo present)
t "ring retired"   "" (functions -q __tmux_lives_theme_ring; and echo present)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — palette still has the old 8-arg signature / `__tmux_lives_theme_accents` undefined / retired builders still present.

- [ ] **Step 3: Write minimal implementation**

Add:

```fish
function __tmux_lives_theme_accents --argument-names barHex capHex --description 'v4 accents: sep active windows text as lightness tints/contrast off the bar (uncalibrated, live-tunable via @options). -> sep active windows text (4 hexes).'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$barHex"; or return
    set -l brgb (__tmux_lives_hex_to_rgb01 $barHex)
    set -l bo (__tmux_lives_rgb_to_oklch $brgb[1] $brgb[2] $brgb[3])
    set -l bH $bo[3]
    # tints sit on the contrast side of the bar (light on a dark bar)
    set -l active  (__tmux_lives_oklch_hex 0.88 0.03 $bH)
    set -l windows (__tmux_lives_oklch_hex 0.74 0.04 $bH)
    set -l sep     (__tmux_lives_oklch_hex 0.62 0.03 $bH)
    if test (math "$bo[1] >= 0.55") = 1
        set active  (__tmux_lives_oklch_hex 0.16 0.03 $bH)
        set windows (__tmux_lives_oklch_hex 0.30 0.04 $bH)
        set sep     (__tmux_lives_oklch_hex 0.42 0.03 $bH)
    end
    set -l tdir 1
    test (math "$bo[1] >= 0.55") = 1; and set tdir -1
    set -l Lt (math "$bo[1] + $tdir * 0.45")
    test (math "$Lt < 0.05") = 1; and set Lt 0.05
    test (math "$Lt > 0.97") = 1; and set Lt 0.97
    set -l text (__tmux_lives_oklch_hex $Lt 0.03 $bH)
    printf '%s\n' $sep $active $windows $text
end

function __tmux_lives_theme_palette --argument-names seedHex relationship place mode phase vividness shape ease contrast --description 'v4: seed + relationship/place/mode/knobs -> 7 role hexes (bar sep tabs active windows cap text). bar/tabs/cap = the curve (relationship travel, seed placement, mode, endcap taper); sep/active/windows/text = tints/contrast off the bar. Phase 1: only phase shapes the curve; vividness/shape/ease/contrast are accepted for signature stability. Non-hex seed / unknown relationship -> nothing.'
    set -l tri (__tmux_lives_theme_curve "$seedHex" "$relationship" "$place" "$mode" "$phase")
    test (count $tri) -eq 3; or return
    set -l acc (__tmux_lives_theme_accents $tri[1] $tri[3])
    test (count $acc) -eq 4; or return
    # order: bar sep tabs active windows cap text
    printf '%s\n' $tri[1] $acc[1] $tri[2] $acc[2] $acc[3] $tri[3] $acc[4]
end
```

Then DELETE the v3 functions no longer referenced: `__tmux_lives_theme_arc`, `__tmux_lives_theme_barpos`, `__tmux_lives_theme_kincap`, `__tmux_lives_theme_kintabs`, `__tmux_lives_theme_roles`, `__tmux_lives_theme_ring`, `__tmux_lives_theme_sample`. (Grep first: `grep -n '__tmux_lives_theme_\(arc\|barpos\|kincap\|kintabs\|roles\|ring\|sample\)' conf.d/tmux-lives-install.fish` — after this task the only hits should be the `function` definitions you are deleting.)

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS. `--no-config` matters here — it does not see the live fisher install, so a lingering reference to a deleted function surfaces.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 palette assembly + accents; retire v3 trio/ring builders"
```

---

## Task 5: CLI (`_theme_cmd`, `_theme_apply_live`, `_theme_list`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_theme_cmd`, `_theme_apply_live`, `_theme_list`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_palette` (9-arg), `__tmux_lives_theme_relationships`, `__tmux_lives_theme_valid`.
- Produces (CLI): `tmux-lives setup theme <relationship>|list|list <rel>|off [--place bar|tabs|cap|low|high] [--mode literal|derived] [--phase <deg>] [--vividness …] [--shape …] [--ease …] [--contrast …]`. `--rotate` is removed and errors with a pointer to `--place`. Sets universals `tmux_lives_theme` (relationship), `tmux_lives_theme_place`, `tmux_lives_theme_mode`, plus the carried-over knob universals.
- Produces (internal): `__tmux_lives_theme_apply_live` — the preview path now takes **8** positional args `relationship place mode phase viv shape ease contrast` (was 7); the universal path reads `tmux_lives_theme_place`/`_mode` and no longer reads `_rotate`.

- [ ] **Step 1: Write the failing test**

```fish
# ---- v4: CLI ----
# save/clear/restore the universals this section writes (guard at TOP of the section)
set -l _t_saved
for v in tmux_lives_theme tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_theme_rotate
    set -q $v; and set -a _t_saved "$v=$$v"; set -e $v
end
set -x tmux_lives_tmux_socket tli-v4-$fish_pid   # pin live tmux writes to a throwaway socket

t "theme sets relationship" 0 (__tmux_lives_theme_cmd ember >/dev/null; echo $status)
t "theme persisted"    ember (set -q tmux_lives_theme; and echo $tmux_lives_theme)
t "theme place flag"   0 (__tmux_lives_theme_cmd coral --place cap --mode literal >/dev/null; echo $status)
t "place persisted"    cap     $tmux_lives_theme_place
t "mode persisted"     literal $tmux_lives_theme_mode
t "invalid rel errors" 1 (__tmux_lives_theme_cmd bogus 2>/dev/null; echo $status)
t "invalid place errs" 1 (__tmux_lives_theme_cmd ember --place middle 2>/dev/null; echo $status)
t "rotate is gone"     1 (__tmux_lives_theme_cmd ember --rotate 2 2>/dev/null; echo $status)
t "rotate err mentions place" 1 (__tmux_lives_theme_cmd ember --rotate 2 2>&1 | string match -q '*--place*'; and echo 1; or echo 0)
t "list runs"          0 (__tmux_lives_theme_cmd list >/dev/null; echo $status)

set -e tmux_lives_tmux_socket
set -e tmux_lives_theme tmux_lives_theme_place tmux_lives_theme_mode
for kv in $_t_saved
    set -l p (string split '=' $kv); set -U $p[1] $p[2]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `--place`/`--mode` unrecognised (treated as relationship), `--rotate` still accepted, relationship validation message lists old schemes.

- [ ] **Step 3: Write minimal implementation**

In `__tmux_lives_theme_cmd`: add `place`/`mode` accumulators and cases; remove the `--rotate` case and add an explicit error case for it; update the invalid-relationship message to list the six relationship names; validate `place ∈ {bar,tabs,cap,low,high}` and `mode ∈ {literal,derived}`; persist `tmux_lives_theme_place`/`tmux_lives_theme_mode`; drop the `--rotate` persistence. In the no-arg state print, replace `rotate:` with `place:`/`mode:`.

```fish
# inside the arg loop, replace the --rotate case with:
            case --place
                set i (math $i + 1); set place $argv[$i]; set have_place 1
            case --mode
                set i (math $i + 1); set mode $argv[$i]; set have_mode 1
            case --rotate
                echo "tmux-lives setup theme: --rotate was removed in v4 — use --place bar|tabs|cap|low|high to move the seed instead" >&2
                return 1
```

```fish
# validation (after the scheme validation, before persisting):
    if test $have_place -eq 1
        switch "$place"
            case bar tabs cap low high
            case '*'
                echo "tmux-lives setup theme: invalid place '$place' — valid: bar, tabs, cap, low, high" >&2
                return 1
        end
    end
    if test $have_mode -eq 1
        switch "$mode"
            case literal derived
            case '*'
                echo "tmux-lives setup theme: invalid mode '$mode' — valid: literal, derived" >&2
                return 1
        end
    end
```

```fish
# persistence (replace the rotate line):
    test $have_place -eq 1; and set -U tmux_lives_theme_place $place
    test $have_mode -eq 1; and set -U tmux_lives_theme_mode $mode
```

Update the invalid-relationship message:

```fish
        echo "tmux-lives setup theme: invalid relationship '$scheme' — valid: "(__tmux_lives_theme_relationships | string join ', ')" (or: list, off)" >&2
```

In `__tmux_lives_theme_apply_live`: change the preview arm to `test (count $argv) -eq 8` and unpack `relationship place mode phase viv shape ease contrast`; the universal arm reads `tmux_lives_theme_place`/`_mode` (defaults `bar`/`derived`) instead of `_rotate`; both arms call the 9-arg palette `__tmux_lives_theme_palette $seed $theme $place $mode $phase $viv $shape $ease $contrast`.

In `__tmux_lives_theme_list`: iterate `__tmux_lives_theme_relationships`, read `place`/`mode` universals (defaults), call the 9-arg palette.

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS. Confirm the throwaway `-L` socket left no trace: `tmux -L tli-v4-* kill-server 2>/dev/null` is not needed if the socket name was unique per `$fish_pid`, but verify no `tmux_lives_*` universals were leaked (`set -U | grep tmux_lives_theme` should show only your restored originals).

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 CLI — --place/--mode, retire --rotate"
```

---

## Task 6: Fragment render (argv place/mode, drop rotate)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment`, `__tmux_lives_write_fragment`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_palette` (9-arg).
- Produces: the fragment bakes the resolved 7 role `@options` from the v4 palette. Argv positions **13–19** change: `13 theme(relationship)`, `14 place`, `15 mode`, `16 phase`, `17 vividness`, `18 shape`, `19 ease`, `20 contrast`. (Verify current numbering first: `grep -n 'set -l theme ' conf.d/tmux-lives-install.fish` and the argv doc block at the top of `__tmux_lives_render_fragment`. Adjust these positions to whatever is actually current — the requirement is: add `place` and `mode`, remove `rotate`, keep the rest.)

- [ ] **Step 1: Write the failing test**

```fish
# ---- v4: fragment ----
set -l frag (__tmux_lives_render_fragment /path/cat S M-s '#5f772b' 0 M-m M-t M-r C-M-a C-M-s block M-k ember bar derived 0 balanced arc linear auto | string collect)
t "fragment sets tabs_color" 1 (string match -q '*@tmux_lives_tabs_color*' -- $frag; and echo 1; or echo 0)
t "fragment sets mark_fg seed" 1 (string match -q '*@tmux_lives_mark_fg*#5f772b*' -- $frag; and echo 1; or echo 0)
t "fragment has no rotate arg leakage" 1 (not string match -q '*theme_rotate*' -- $frag; and echo 1; or echo 0)
```

(The exact positional argument list in the call above must match the real `__tmux_lives_render_fragment` signature after this task — copy it from the function's `set -l` header.)

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — argument count/positions mismatch or the palette call errors.

- [ ] **Step 3: Write minimal implementation**

In `__tmux_lives_render_fragment`: update the argv doc block and `set -l` unpacking to insert `place` (14) and `mode` (15) and remove `rotate`; shift the theme knob positions accordingly. Where the fragment computes the themed palette, call `__tmux_lives_theme_palette $seedhex $theme $place $mode $phase $themeviv $themeshape $themeease $themecontrast`. Update `__tmux_lives_write_fragment` to pass `tmux_lives_theme_place`/`_mode` (defaults `bar`/`derived`) in place of `_rotate`.

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS. Also run the fragment `source-file` parse test that already exists (`grep -n 'source-file' tests/test-tmux-install.fish`) to confirm the rendered fragment still parses on a real `-L` server.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 fragment — bake place/mode, drop rotate"
```

---

## Task 7: Migration shim (`_migrate_v4`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add `__tmux_lives_migrate_v4`; call it from `_tmux_lives_post_update`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: nothing.
- Produces: `__tmux_lives_migrate_v4` — idempotent. Preserves `tmux_lives_bar_color` (the seed). Erases `tmux_lives_theme_rotate`. If `tmux_lives_theme` holds a retired v3 scheme name (anything not in `__tmux_lives_theme_relationships` and not `off`), reset it to `mono` and set `tmux_lives_theme_place mono`… no — set `tmux_lives_theme_place bar` and `tmux_lives_theme_mode derived`. Prints one notice line when it changed anything.

- [ ] **Step 1: Write the failing test**

```fish
# ---- v4: migration ----
set -l _m_saved
for v in tmux_lives_theme tmux_lives_theme_rotate tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_bar_color
    set -q $v; and set -a _m_saved "$v=$$v"; set -e $v
end
set -U tmux_lives_bar_color '#5f772b'
set -U tmux_lives_theme complement   # a retired v3 scheme
set -U tmux_lives_theme_rotate 3
__tmux_lives_migrate_v4 >/dev/null
t "migrate keeps seed"    "#5f772b" $tmux_lives_bar_color
t "migrate resets scheme" mono      $tmux_lives_theme
t "migrate sets place"    bar       $tmux_lives_theme_place
t "migrate sets mode"     derived   $tmux_lives_theme_mode
t "migrate erases rotate" 0         (set -q tmux_lives_theme_rotate; and echo 1; or echo 0)
# idempotent: a valid v4 relationship is left alone
set -U tmux_lives_theme ember
__tmux_lives_migrate_v4 >/dev/null
t "migrate leaves v4 rel" ember $tmux_lives_theme
set -e tmux_lives_theme tmux_lives_theme_rotate tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_bar_color
for kv in $_m_saved
    set -l p (string split '=' $kv); set -U $p[1] $p[2]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `Unknown command: __tmux_lives_migrate_v4`.

- [ ] **Step 3: Write minimal implementation**

```fish
function __tmux_lives_migrate_v4 --description 'idempotent on fisher update: preserve the seed, retire tmux_lives_theme_rotate, and map a retired v3 scheme name onto v4 (mono/bar/derived). One notice when it changes anything.'
    set -l changed 0
    if set -q tmux_lives_theme_rotate
        set -e tmux_lives_theme_rotate
        set changed 1
    end
    if set -q tmux_lives_theme
        if test "$tmux_lives_theme" != off; and not contains -- "$tmux_lives_theme" (__tmux_lives_theme_relationships)
            set -U tmux_lives_theme mono
            set -U tmux_lives_theme_place bar
            set -U tmux_lives_theme_mode derived
            set changed 1
        end
    end
    test $changed -eq 1; and echo "tmux-lives: theme migrated to v4 (relationships + placement); your seed color is preserved — see 'tmux-lives setup theme list'"
end
```

Call it from `_tmux_lives_post_update` alongside the existing `__tmux_lives_migrate_v2`/`_v31` (find them: `grep -n migrate conf.d/tmux-lives-install.fish`), before the fragment re-render.

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-install.fish` then `fish --no-config tests/test-tmux-install.fish`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): v4 migration shim — preserve seed, retire rotate"
```

---

## Task 8: Cleanup guards + help + full-suite green

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (setup-help `theme` row), `tests/test-tmux-install.fish` (grep guards)
- Test: `tests/test-tmux-install.fish`, whole suite

**Interfaces:**
- Consumes: everything above.
- Produces: grep guards pinning the v3 removals; corrected help text; a green suite under both configs.

- [ ] **Step 1: Write the failing tests (grep guards + help)**

```fish
set -l instfile $plugindir/conf.d/tmux-lives-install.fish
t "v3 arc gone"    0 (grep -c '__tmux_lives_theme_arc' $instfile)
t "v3 kincap gone" 0 (grep -c '__tmux_lives_theme_kincap' $instfile)
t "v3 ring gone"   0 (grep -c '__tmux_lives_theme_ring' $instfile)
t "v3 barpos gone" 0 (grep -c '__tmux_lives_theme_barpos' $instfile)
t "no rotate universal outside migration" 0 (awk '/^function __tmux_lives_migrate_v4/,/^end$/ {next} /^function __tmux_lives_migrate_v31/,/^end$/ {next} {print}' $instfile | grep -c 'tmux_lives_theme_rotate')
t "help theme row mentions place" 1 (__tmux_lives_setup_help_lines | string match -q '*place*'; and echo 1; or echo 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL on any lingering reference and on the help row.

- [ ] **Step 3: Implement**

Remove any stray v3 references the guards catch. Update the setup-help `theme` row (find it: `grep -n 'theme' conf.d/tmux-lives-install.fish` inside `__tmux_lives_setup_help_lines`) to enumerate the v4 flags, e.g. `theme <rel>|list|off   set the bar theme (--place --mode --phase --vividness --shape --ease --contrast)`, re-padded to keep the 80-column box (the box measures with `string length --visible`).

- [ ] **Step 4: Run the WHOLE suite, both configs**

Run:
```bash
fish -c 'for t in tests/test-*.fish; echo "--- $t"; fish $t 2>&1 | tail -1; end'
fish --no-config -c 'for t in tests/test-*.fish; echo "--- $t"; fish --no-config $t 2>&1 | tail -1; end'
```
Expected: every suite `ALL PASS` under both. In particular `test-tmux-categorize.fish` must stay green — it exercises the fragment/status path indirectly; if it references a removed function, that surfaces here.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "chore(theme): v4 cleanup — grep guards, help row, full suite green"
```

---

## Self-Review

**1. Spec coverage.**
- Relationship (signed named) → Task 1. ✓
- Endcap taper (direction-dependent knee, chroma+lightness floor) → Task 2. ✓
- Curve: placement + mode + damped seed L/C → Task 3. ✓
- Coverage guarantee (literal seed at each placeable role) → Task 3 literal mode; the *8-row catalog* that expresses the guarantee in the UI is Phase 2 (picker), noted below. The engine supports every (place, mode) combination the catalog needs. ✓ (engine) / deferred (UI).
- 7-role palette + accents → Task 4. ✓
- CLI (`--place`/`--mode`, `--rotate` removed, list) → Task 5. ✓
- Fragment argv → Task 6. ✓
- Migration (preserve seed, discard scheme, land on mono/bar/derived) → Task 7. ✓
- Grep guards / help → Task 8. ✓
- **Deferred to Phase 2 (picker plan):** the 8-row list UI, ✦ literal markers, the `l` relationship key, `--place`-in-picker, and the picker's own migration of the old geometry. Called out here so it is not mistaken for a gap.

**2. Placeholder scan.** No "TBD"/"handle edge cases"/"similar to Task N" — each task carries its own code. The one soft spot is the reference hexes in Tasks 3–4, which are pinned to calibration output with an explicit "verify and update only if the family holds" instruction; that is a deliberate tolerance, not a placeholder.

**3. Type consistency.** `__tmux_lives_theme_palette` is 9-arg `(seed relationship place mode phase vividness shape ease contrast)` in Tasks 4, 5, 6 consistently. `_curve` is 5-arg `(seed relationship place mode phase)` in Tasks 3, 4. `_taper` returns `capC capL tabsC` (Task 2) consumed positionally in Task 3. `_accents` returns `sep active windows text` (Task 4) reassembled into the `bar sep tabs active windows cap text` order in the palette. Universals `tmux_lives_theme_place`/`_mode` are written in Task 5, read in Tasks 5/6, migrated in Task 7. Consistent.

## Open risks (carry into review, not blockers)

- **Damping vs. the calibrated look.** The calibration generators used a fixed ramp (no seed L/C influence); derived mode adds damped seed lightness (`Ldamp`) and chroma (`Cscale`). For the reference seed `#5f772b` (C≈0.106) `Cscale≈1.18`, so the derived palette runs ~18% more saturated than the calibration tiles. Tests assert properties, not exact hexes, so this does not fail them — but when `setup theme list` is eyeballed on the real bar (before Phase 2), if the palette reads more saturated than the approved mockups, the fix is to reduce the `Cscale` damping factor (or drop chroma damping, keeping only lightness — the user's damping decision was explicitly about lightness). Flagged, not blocking.
- **`vividness/shape/ease/contrast`** are accepted by the palette but only `phase` shapes the Phase-1 curve. They are retained for signature stability and picker compatibility; wiring them to the curve (e.g. vividness scaling `Cscale`) is a deliberate later refinement, flagged in the spec's open items.
- **Accent constants** are uncalibrated; they reach the user as tunable `@options`, so live adjustment needs no code change.

## Execution Handoff

Phase 2 (the theme picker in `functions/tmux-categorize.fish`) gets its own plan after this engine lands and its `setup theme list` output has been eyeballed on the real bar.
