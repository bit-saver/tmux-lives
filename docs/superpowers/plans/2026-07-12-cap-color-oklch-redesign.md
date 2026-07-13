# Cap-color OKLCH palette engine — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Replace cap-color v1's muddy HSL derivation with a perceptual **OKLCH palette engine** that generates a value-structured, harmonious palette from the bar color; wire the palette's **accent** role to the powerline cap; and ship the picker/CLI/`M-m`/border/rename around it.

**Architecture:** Pure fish OKLCH conversion + a role-structured palette generator in `conf.d/tmux-lives-install.fish` (validated in a fish 4.7.1 prototype — code embedded below verbatim). The render fragment computes the palette and seeds `@tmux_lives_cap_bg` (=accent) / `@tmux_lives_cap_fg` (=WCAG contrast). `setup cap` + the `cap-picker` popup select a **formula** (which produces the palette); an `M-m` modal entry opens the picker. Phase 2 (whole-bar theming) is a later plan — this one only consumes the `accent` role.

**Tech Stack:** fish 4.7.1 `math` (has `atan2`/`sin`/`cos`; no `cbrt`); tmux 3.3a; existing `-L`-socket + stub test harnesses; reuse the switcher popup + modal.

## Global Constraints

- fish + tmux 3.3a, no new deps. Only touch `conf.d/tmux-lives-install.fish`, `functions/tmux-categorize.fish`, `tests/test-tmux-install.fish`, `tests/test-tmux-categorize.fish`.
- **Front-facing name is `formula`** (rename v1's `<token>`); universal stays `tmux_lives_cap`. New universals `tmux_lives_cap_vividness` (`subtle|balanced|vivid`, default `vivid`), `tmux_lives_cap_wheel` (`ryb|perceptual`, default `ryb`).
- **Formulas & offsets** (degrees, applied on the chosen wheel): `mono` 0 · `complementary` 180 · `analogous+`/`-` +30/−30 · `split+`/`-` +150/−150 · `triadic+`/`-` +120/−120 · `tetradic` 90. Literal `#rrggbb` → accent verbatim. Unknown/empty → `mono`.
- **Palette roles / targets** (OKLCH): `text` = base-hue L0.90 C0.02 · `dim` = base-hue L0.47 C0.055 · `muted` = secondary-hue L0.58 C0.11 · `accent` = primary-hue L0.68 C(0.19×vividness). Vividness scale: `subtle` 0.55 · `balanced` 0.80 · `vivid` 1.0.
- **Fish `math` gotchas (verified — obey all):** no comparisons inside `math` (`math "$x<0.5"` throws) → branch with `test` (float-capable). No `cbrt` → `x^(1/3)` (only for x≥0; forward LMS is ≥0 so safe; inverse cube `x^3` is safe for negatives). `%` is integer-only → wrap hue with `while test … ; set h (math "$h±360"); end`. Command substitution splits on **newlines** → multi-value returns use `printf "%s\n" $a $b $c` and callers capture into a list var and index (`set -l r (fn); $r[1]`), NEVER `set -l a b c (fn)`. `math "0x"(string sub …)` concatenates fine.
- Colors emitted into fragment **text** are single-quoted (unquoted `#hex` = tmux comment → silent-empty option that still `source-file`s rc0). Any `set -a f "…"` value that concatenates a command substitution must be **captured into a var first** (a zero-output substitution collapses the whole arg to empty).
- Isolation: `-L` sockets / stubs / the `tmux_lives_tmux_socket` seam only — never the user's default server. `set -U` tests must **save/clear/restore** the universal (no leak). Run `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`.
- Do NOT deploy. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Reference values** (from the validated prototype; lock the fish output as truth if a channel differs ±1): `#ff0000` → OKLCH `L=0.627955 C=0.257684 H=29.233916`, round-trips to `#ff0000`. `#36442d` → `L=0.367244 C=0.042157 H=133.601539`. Palette `#36442d`, RYB, vivid — base-hue roles `dim #4b6244 · text #d8e1d5`; **`triadic-`** (the loved one) → `accent(−120) #f66336 · muted(+120) #8769b0`; `triadic+` → `accent(+120) #b075f7 · muted(−120) #b1614a`; `mono` → `accent #52b22d`. `contrast_fg`: `#f66336 → #111111`, `#36442d → #f5f5f5`.

---

## Task 1: OKLCH conversion core + WCAG contrast fg

**Files:** Modify `conf.d/tmux-lives-install.fish` (add after the existing `__tmux_lives_derive_cap_bg`, ~line 458; **replace** the existing `__tmux_lives_contrast_fg`, ~line 462). Test `tests/test-tmux-install.fish` (near the `derive_cap_bg` tests, ~line 124).

**Interfaces — Produces:**
- `__tmux_lives_rgb_to_oklch r g b` → prints `L`, `C`, `H`(deg 0–360) one per line (rgb in 0–1).
- `__tmux_lives_oklch_to_linrgb L C H` → prints linear r,g,b (unclamped) one per line.
- `__tmux_lives_gamut_chroma L H Ctarget` → max in-gamut chroma ≤ Ctarget (12-iter bisection).
- `__tmux_lives_oklch_hex L C H` → `#rrggbb` (chroma gamut-clamped, gamma-encoded, clipped).
- `__tmux_lives_hex_to_rgb01 hex` → r,g,b (0–1) one per line.
- `__tmux_lives_contrast_fg hex` → `#111111` (light-ish bg) or `#f5f5f5` (dark bg), WCAG crossover 0.179. **Replaces v1's luminance-140 version.**
- Helpers: `__tmux_lives_lin_decode`, `__tmux_lives_lin_encode`, `__tmux_lives_clip01`, `__tmux_lives_linrgb_to_hex`, `__tmux_lives_in_gamut`, `__tmux_lives_norm360`, and a `set -g __tmux_lives_pi (math "atan2(0,-1)")` at source time.

- [ ] **Step 1 — failing tests** (add near the `derive_cap_bg` tests). Note the `t` helper is `t <desc> <expected> <actual>`:
```fish
# OKLCH round-trip (validated reference values; lock fish output if ±1)
set -g OK (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 "#ff0000"))
t "oklch #ff0000 L" "0.627955" $OK[1]
t "oklch #ff0000 C" "0.257684" $OK[2]
t "oklch #ff0000 H" "29.233916" $OK[3]
t "oklch_hex round-trips #ff0000" "#ff0000" (__tmux_lives_oklch_hex $OK[1] $OK[2] $OK[3])
t "oklch_hex round-trips #36442d" "#36442d" (__tmux_lives_oklch_hex 0.367244 0.042157 133.601539)
# gamut clamp never exceeds target, stays in range
t "gamut_chroma caps at target" 1 (test (__tmux_lives_gamut_chroma 0.62 30 0.19) '<=' 0.19; and echo 1; or echo 0)
# WCAG contrast fg
t "contrast_fg dark cap -> light" "#f5f5f5" (__tmux_lives_contrast_fg "#36442d")
t "contrast_fg vivid mid -> dark" "#111111" (__tmux_lives_contrast_fg "#f66336")
t "contrast_fg near-white -> dark" "#111111" (__tmux_lives_contrast_fg "#e0e0e0")
```
(The `<=` numeric compare in fish `test` needs `test A -le B`; use `test (math "$x<=0.19")` is invalid — instead assert with `test (count ...)`; simplest: `t "gamut ≤ target" 1 (set -l c (__tmux_lives_gamut_chroma 0.62 30 0.19); test "$c" -le 0.19; and echo 1; or echo 0)`.)

- [ ] **Step 2 — run, verify FAIL** (`fish tests/test-tmux-install.fish` → `FAILED`).

- [ ] **Step 3 — implement.** Add near the top of the file (module scope): `set -g __tmux_lives_pi (math "atan2(0, -1)")`. Then add these functions (validated prototype, renamed — copy verbatim):
```fish
function __tmux_lives_lin_decode --argument c
    if test $c -le 0.04045; math "$c / 12.92"; else; math "(($c + 0.055) / 1.055) ^ 2.4"; end
end
function __tmux_lives_lin_encode --argument c   # c already clipped to [0,1]
    if test $c -le 0.0031308; math "$c * 12.92"; else; math "1.055 * ($c ^ (1 / 2.4)) - 0.055"; end
end
function __tmux_lives_clip01 --argument v
    if test $v -lt 0; echo 0; return; end
    if test $v -gt 1; echo 1; return; end
    echo $v
end
function __tmux_lives_hex_to_rgb01 --argument hex
    set -l h (string replace -r '^#' '' $hex)
    printf "%s\n" (math "0x"(string sub -s 1 -l 2 $h)"/255") (math "0x"(string sub -s 3 -l 2 $h)"/255") (math "0x"(string sub -s 5 -l 2 $h)"/255")
end
function __tmux_lives_linrgb_to_hex --argument r g b
    set -l re (__tmux_lives_clip01 (__tmux_lives_lin_encode (__tmux_lives_clip01 $r)))
    set -l ge (__tmux_lives_clip01 (__tmux_lives_lin_encode (__tmux_lives_clip01 $g)))
    set -l be (__tmux_lives_clip01 (__tmux_lives_lin_encode (__tmux_lives_clip01 $b)))
    printf "#%02x%02x%02x\n" (math "round($re*255)") (math "round($ge*255)") (math "round($be*255)")
end
function __tmux_lives_rgb_to_oklch --argument r g b
    set -l rl (__tmux_lives_lin_decode $r); set -l gl (__tmux_lives_lin_decode $g); set -l bl (__tmux_lives_lin_decode $b)
    set -l l (math "0.4122214708*$rl + 0.5363325363*$gl + 0.0514459929*$bl")
    set -l m (math "0.2119034982*$rl + 0.6806995451*$gl + 0.1073969566*$bl")
    set -l s (math "0.0883024619*$rl + 0.2817188376*$gl + 0.6299787005*$bl")
    set -l lp (math "$l ^ (1/3)"); set -l mp (math "$m ^ (1/3)"); set -l sp (math "$s ^ (1/3)")
    set -l L (math "0.2104542553*$lp + 0.7936177850*$mp - 0.0040720468*$sp")
    set -l a (math "1.9779984951*$lp - 2.4285922050*$mp + 0.4505937099*$sp")
    set -l b (math "0.0259040371*$lp + 0.7827717662*$mp - 0.8086757660*$sp")
    set -l C (math "sqrt($a^2 + $b^2)")
    set -l H (math "atan2($b, $a) * 180 / $__tmux_lives_pi")
    if test $H -lt 0; set H (math "$H + 360"); end
    printf "%s\n" $L $C $H
end
function __tmux_lives_oklch_to_linrgb --argument L C H
    set -l Hrad (math "$H * $__tmux_lives_pi / 180")
    set -l a (math "$C * cos($Hrad)"); set -l b (math "$C * sin($Hrad)")
    set -l lp (math "$L + 0.3963377774*$a + 0.2158037573*$b")
    set -l mp (math "$L - 0.1055613458*$a - 0.0638541728*$b")
    set -l sp (math "$L - 0.0894841775*$a - 1.2914855480*$b")
    set -l l (math "$lp ^ 3"); set -l m (math "$mp ^ 3"); set -l s (math "$sp ^ 3")
    printf "%s\n" (math "4.0767416621*$l - 3.3077115913*$m + 0.2309699292*$s") (math "-1.2684380046*$l + 2.6097574011*$m - 0.3413193965*$s") (math "-0.0041960863*$l - 0.7034186147*$m + 1.7076147010*$s")
end
function __tmux_lives_in_gamut --argument r g b
    for v in $r $g $b
        if test $v -lt 0; echo 0; return; end
        if test $v -gt 1; echo 0; return; end
    end
    echo 1
end
function __tmux_lives_gamut_chroma --argument L H Ctarget
    set -l rgb (__tmux_lives_oklch_to_linrgb $L $Ctarget $H)
    if test (__tmux_lives_in_gamut $rgb[1] $rgb[2] $rgb[3]) -eq 1; echo $Ctarget; return; end
    set -l lo 0; set -l hi $Ctarget
    for i in (seq 1 12)
        set -l mid (math "($lo + $hi) / 2")
        set -l rgb2 (__tmux_lives_oklch_to_linrgb $L $mid $H)
        if test (__tmux_lives_in_gamut $rgb2[1] $rgb2[2] $rgb2[3]) -eq 1; set lo $mid; else; set hi $mid; end
    end
    echo $lo
end
function __tmux_lives_oklch_hex --argument L C H
    set -l Cg (__tmux_lives_gamut_chroma $L $H $C)
    set -l rgb (__tmux_lives_oklch_to_linrgb $L $Cg $H)
    __tmux_lives_linrgb_to_hex $rgb[1] $rgb[2] $rgb[3]
end
function __tmux_lives_norm360 --argument h
    set -l hh $h
    while test $hh -lt 0; set hh (math "$hh + 360"); end
    while test $hh -ge 360; set hh (math "$hh - 360"); end
    echo $hh
end
```
**Replace** the existing `__tmux_lives_contrast_fg` with:
```fish
function __tmux_lives_contrast_fg --argument hex
    set -l rgb (__tmux_lives_hex_to_rgb01 $hex)
    set -l Lrel (math "0.2126*"(__tmux_lives_lin_decode $rgb[1])" + 0.7152*"(__tmux_lives_lin_decode $rgb[2])" + 0.0722*"(__tmux_lives_lin_decode $rgb[3]))
    if test $Lrel -gt 0.179; echo "#111111"; else; echo "#f5f5f5"; end
end
```
(If any prior test asserted v1's `#1c1c1c`/`#f4f7f4` from `__tmux_lives_contrast_fg`, update it to `#111111`/`#f5f5f5`. Search first: `grep -n contrast_fg tests/test-tmux-install.fish`.)

- [ ] **Step 4 — run PASS + full suite** (`for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`). If a `cap_hue` reference differs ±1, lock the fish value in the test and note it.
- [ ] **Step 5 — commit** (`feat(cap): OKLCH conversion core + WCAG contrast fg`).

---

## Task 2: hue targeting (RYB/perceptual) + palette generator

**Files:** Modify `conf.d/tmux-lives-install.fish` (after Task 1's functions). Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Task 1. **Produces:**
- `__tmux_lives_target_hue baseHex offset wheel` → OKLCH target hue (deg). `wheel` = `ryb`|`perceptual`.
- `__tmux_lives_palette baseHex formula wheel vividness` → prints the 5 role hexes one per line in order **`bg dim muted accent text`** (bg = baseHex verbatim).

- [ ] **Step 1 — failing tests:**
```fish
# triadic- is the palette the user chose (warm accent). Roles order: bg dim muted accent text
set -g PAL (__tmux_lives_palette "#36442d" "triadic-" ryb vivid)
t "palette bg is base"      "#36442d" $PAL[1]
t "palette dim"             "#4b6244" $PAL[2]
t "palette muted (triadic- secondary = +120)" "#8769b0" $PAL[3]
t "palette accent (triadic- primary = -120)"  "#f66336" $PAL[4]
t "palette text"            "#d8e1d5" $PAL[5]
# flip swaps primary/secondary: triadic+ accent is the violet
t "triadic+ accent (primary = +120)" "#b075f7" (set -l p (__tmux_lives_palette "#36442d" "triadic+" ryb vivid); echo $p[4])
# mono accent = base hue at the accent target
t "mono accent" "#52b22d" (set -l p (__tmux_lives_palette "#36442d" mono ryb vivid); echo $p[4])
# literal hex passthrough -> accent verbatim
t "palette #hex accent passthrough" "#123456" (set -l p (__tmux_lives_palette "#36442d" "#123456" ryb vivid); echo $p[4])
# unknown formula -> mono
t "palette unknown == mono accent" "#52b22d" (set -l p (__tmux_lives_palette "#36442d" wat ryb vivid); echo $p[4])
```
(Reference hexes are the validated prototype output for base `#36442d`, RYB, vivid — from the plan's Global Constraints. Regenerate/lock if fish differs ±1.)

- [ ] **Step 2 — run, verify FAIL.**

- [ ] **Step 3 — implement.** Add the RYB-wheel helpers (validated prototype, renamed — copy verbatim): `__tmux_lives_interp7`, `__tmux_lives_rgb_to_ryb_hue`, `__tmux_lives_ryb_to_rgb_hue`, `__tmux_lives_hsl_hue`, `__tmux_lives_hsl_to_rgb` (bodies exactly as `interp_piecewise`/`rgb_hue_to_ryb_hue`/`ryb_hue_to_rgb_hue`/`hsl_hue_from_rgb01`/`hsl_to_rgb01` in the prototype). Then:
```fish
function __tmux_lives_target_hue --argument baseHex offset wheel
    set -l rgb (__tmux_lives_hex_to_rgb01 $baseHex)
    if test "$wheel" = perceptual
        set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
        __tmux_lives_norm360 (math "$ok[3] + $offset")
    else
        set -l rgbHue (__tmux_lives_hsl_hue $rgb[1] $rgb[2] $rgb[3])
        set -l rybHue2 (__tmux_lives_norm360 (math (__tmux_lives_rgb_to_ryb_hue $rgbHue)" + $offset"))
        set -l rgbHue2 (__tmux_lives_ryb_to_rgb_hue $rybHue2)
        set -l pure (__tmux_lives_hsl_to_rgb $rgbHue2 1 0.5)
        set -l ok (__tmux_lives_rgb_to_oklch $pure[1] $pure[2] $pure[3])
        echo $ok[3]
    end
end
function __tmux_lives_palette --argument baseHex formula wheel vividness
    # vividness -> accent chroma multiplier
    set -l vm 1.0
    switch "$vividness"
        case subtle; set vm 0.55
        case balanced; set vm 0.80
    end
    set -l Cacc (math "0.19 * $vm")
    # base-hue roles
    set -l bh (__tmux_lives_target_hue $baseHex 0 $wheel)
    set -l text (__tmux_lives_oklch_hex 0.90 0.02 $bh)
    set -l dim (__tmux_lives_oklch_hex 0.47 0.055 $bh)
    # literal #hex escape hatch -> accent verbatim, neutral muted
    if string match -qr '^#[0-9a-fA-F]{6}$' -- "$formula"
        printf "%s\n" $baseHex $dim (__tmux_lives_oklch_hex 0.58 0.11 $bh) (string lower -- $formula) $text
        return
    end
    # formula -> primary/secondary offsets
    set -l po 0; set -l so 0
    switch "$formula"
        case complementary;  set po 180; set so 0
        case analogous+;     set po 30;  set so -30
        case analogous-;     set po -30; set so 30
        case split+;         set po 150; set so -150
        case split-;         set po -150; set so 150
        case triadic+;       set po 120; set so -120
        case triadic-;       set po -120; set so 120
        case tetradic;       set po 180; set so 90
        case '*';            set po 0;   set so 0   # mono + unknown
    end
    set -l ah (__tmux_lives_target_hue $baseHex $po $wheel)
    set -l mh (__tmux_lives_target_hue $baseHex $so $wheel)
    set -l accent (__tmux_lives_oklch_hex 0.68 $Cacc $ah)
    set -l muted (__tmux_lives_oklch_hex 0.58 0.11 $mh)
    printf "%s\n" $baseHex $dim $muted $accent $text
end
```
- [ ] **Step 4 — run PASS + full suite.**  **Step 5 — commit** (`feat(cap): RYB/perceptual hue targeting + role-structured palette generator`).

---

## Task 3: fragment integration (accent → cap; vividness/wheel argv)

**Files:** Modify `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment` arg block ~lines 12–23 and cap seed ~lines 75–85; the `__tmux_lives_write_fragment` call site ~line 205). Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Task 2. `__tmux_lives_render_fragment` gains argv[13]=`vividness`, argv[14]=`wheel`.

- [ ] **Step 1 — failing tests** (mirror the existing cap_bg fragment tests; the accent for `#1f6feb` bar → its derived bar_bg `#5793f0`, complementary, vivid):
```fish
set -g FC (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block complementary vivid ryb | string collect)
t "fragment cap_bg = palette accent" yes (set -l p (__tmux_lives_palette "#5793f0" complementary ryb vivid); string match -q "*set -g @tmux_lives_cap_bg '"$p[4]"'*" -- "$FC"; and echo yes; or echo no)
t "fragment cap_fg = contrast of accent" yes (set -l p (__tmux_lives_palette "#5793f0" complementary ryb vivid); string match -q "*set -g @tmux_lives_cap_fg '"(__tmux_lives_contrast_fg $p[4])"'*" -- "$FC"; and echo yes; or echo no)
```
Update the existing `$BAR`/`$FRAGCUR`/`$brsock` cap_bg tests: with no argv[12–14] the formula defaults `mono` and cap_bg becomes the OKLCH mono accent (NOT the old `#81aef4` shade) — recompute the expected value as `(set -l p (__tmux_lives_palette "#5793f0" mono ryb vivid); echo $p[4])` and update those assertions to it (mono changes by design; keep them green with the new value).

- [ ] **Step 2 — FAIL.**  **Step 3 — implement:** add `set -l vividness $argv[13]`, `set -l wheel $argv[14]` (defaulting empties: `test -n "$vividness"; or set vividness vivid` / `test -n "$wheel"; or set wheel ryb`) to the arg block. Replace the cap computation:
```fish
    set -l pal (__tmux_lives_palette $barbg $cap $wheel $vividness)
    set -l capbg $pal[4]
    test -n "$capbg"; or set capbg colour238
    set -l capfg (__tmux_lives_contrast_fg $capbg)
    ...
    set -a f "set -g @tmux_lives_cap_bg '$capbg'"
    set -a f "set -g @tmux_lives_cap_fg '$capfg'"
```
Add `(__tmux_lives_key tmux_lives_cap_vividness vivid)` and `(__tmux_lives_key tmux_lives_cap_wheel ryb)` as argv[13]/[14] at the render call site (after the argv[12] `tmux_lives_cap` added in v1).
- [ ] **Step 4 — PASS + full suite.**  **Step 5 — commit** (`feat(cap): render cap from OKLCH palette accent (vividness+wheel argv)`).

---

## Task 4: `setup cap` CLI — formula|list|--vividness|--wheel + rename

**Files:** Modify `conf.d/tmux-lives-install.fish` (`__tmux_lives_cap_cmd`; `__tmux_lives_setup_help_lines` cap row; the three `setup cap` error strings). Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Tasks 2–3. `tmux-lives setup cap <formula>` / `list` / `--vividness <v>` / `--wheel <w>`.

- [ ] **Step 1 — failing tests** (pin live writes to a `-L` socket via `tmux_lives_tmux_socket`; **save/clear/restore** `tmux_lives_cap`, `tmux_lives_cap_vividness`, `tmux_lives_cap_wheel` like the existing `color --apply`/bar-color block does):
```fish
# setup cap complementary sets the universal + live cap_bg = palette accent
t "setup cap sets universal" complementary (set -Ux tmux_lives_tmux_socket … ; __tmux_lives_cap_cmd complementary >/dev/null; echo $tmux_lives_cap)
t "setup cap applies accent live" 1 (set -l p (__tmux_lives_palette <barbg> complementary ryb vivid); test (command tmux -L $sock show -gv @tmux_lives_cap_bg) = $p[4]; and echo 1; or echo 0)
t "setup cap --vividness sets it" subtle (__tmux_lives_cap_cmd --vividness subtle >/dev/null; echo $tmux_lives_cap_vividness)
t "setup cap --wheel sets it" perceptual (__tmux_lives_cap_cmd --wheel perceptual >/dev/null; echo $tmux_lives_cap_wheel)
t "setup cap list has a formula + truecolor swatch" 1 (string match -q '*complementary*' -- (__tmux_lives_cap_cmd list); and string match -q '*\e[48;2;*' -- (__tmux_lives_cap_cmd list); and echo 1; or echo 0)
t "invalid formula errors, no set" 1 (set -e tmux_lives_cap; __tmux_lives_cap_cmd wat 2>/dev/null; and echo bad; or begin; set -q tmux_lives_cap; and echo bad; or echo 1; end)
t "setup help says formula not token" 1 (string match -q '*formula*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**  **Step 3 — implement** `__tmux_lives_cap_cmd`: parse `--vividness <v>`/`--wheel <w>` flags (validate against `subtle|balanced|vivid` / `ryb|perceptual`, `set -U`, apply live) and positional `<formula>` (validate against the formula whitelist incl. `#hex`; `set -U tmux_lives_cap`; compute `barbg` like Task 3; `set -g @tmux_lives_cap_bg`/`_fg` live via the `tmux_lives_tmux_socket` seam). `list` prints each formula's palette (`\e[48;2;R;G;Bm  \e[0m` swatches for dim/muted/accent) against the current bar. Rename the help row to `cap [<formula>] [list]  cap color from a theory formula; no-arg = picker` and the three error strings' `<token>`→`<formula>`. Keep the no-arg → picker launch from v1.
- [ ] **Step 4 — PASS + full suite.**  **Step 5 — commit** (`feat(cap): setup cap formula|list|--vividness|--wheel + <formula> rename`).

---

## Task 5: picker overhaul — framed border, palette strips, v/w controls

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_cap_families`, `__tcz_cap_flip`, `__tcz_cap_swatch_line` → palette-strip line; `__tcz_cap_picker` loop; add a self-drawn frame). Test `tests/test-tmux-categorize.fish`.

**Interfaces — Consumes** the CLI (Enter applies via `fish -c 'tmux-lives setup cap …'`). Pure helpers stay testable.

- [ ] **Step 1 — failing tests** (pure helpers only; raw-tty loop is manual smoke): `__tcz_cap_families` returns `mono complementary analogous+ split+ triadic+ tetradic`; `__tcz_cap_flip triadic+`→`triadic-`, `__tcz_cap_flip tetradic`→`tetradic` (no-op), `__tcz_cap_flip mono`→`mono`; `__tcz_cap_swatch_line` given a precomputed palette-strip (dim/muted/accent hexes) + formula + selected flag contains the selection marker, the formula name, and a `\e[48;2;` swatch for each of the 3 strip colors.
- [ ] **Step 2 — FAIL.**  **Step 3 — implement:** add `tetradic` to `__tcz_cap_families`; `__tcz_cap_flip` no-op for `mono`/`complementary`/`tetradic`. `__tcz_cap_swatch_line` renders a 3-cell palette strip (dim·muted·accent, precomputed) + marker + name. `__tcz_cap_picker`: batch-compute each formula's palette via one config-loaded `fish -c` (`for f in <families>; tmux-lives … ` — actually call a small `fish -c` that sources config and runs `__tmux_lives_palette $bar $f $wheel $vividness` per family+direction); draw a self-drawn orange `╭─ cap color ─╮` frame (mirror `__tcz_popup_draw`'s box at ~line 831–848) + footer ` ↑↓ move · ←→ flip · v vivid · w wheel · ⏎ apply · esc`; keys ↑↓/jk, ←→/hl flip (cache re-select), `v` cycle vividness, `w` toggle wheel (both recompute the batch), Enter → `fish -c 'tmux-lives setup cap $argv[1]' "$formula"` (+ the current vividness/wheel via `--vividness`/`--wheel` first), Esc/q cancel. Reuse `__tcz_popup_readkey` (left/right already added in v1).
- [ ] **Step 4 — PASS + full suite** (confirm `test-tmux-popup.fish` still green).  **Step 5 — commit** (`feat(cap): picker palette strips + framed border + vividness/wheel controls`).

---

## Task 6: `M-m` modal "cap color" entry

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_modal_legend`, `__tcz_modal_action`, `__tcz_modal_run`, and `__tcz_modal_menu`/`_menu_args` fallback). Test `tests/test-tmux-categorize.fish`.

**Interfaces — Consumes** the `cap-picker` verb (opened via deferred `run-shell`, like the modal's `p` picker).

- [ ] **Step 1 — failing tests:** `__tcz_modal_action k` → `cap` (new action token); `__tcz_modal_legend …` output contains `cap color`; the `display-menu` fallback args (`__tcz_modal_menu_args`) include a `cap color` row bound to `k`.
- [ ] **Step 2 — FAIL.**  **Step 3 — implement:** add `case k; echo cap` to `__tcz_modal_action`; add a `k cap color` row to `__tcz_modal_legend` (config header, mirroring `b bar color`); add `case cap; tmux run-shell -b "fish --no-config $__tcz_self cap-picker '$client'"` (deferred, like the `p` picker) to `__tcz_modal_run`; add the `cap color` `k` row to `__tcz_modal_menu_args`.
- [ ] **Step 4 — PASS + full suite.**  **Step 5 — commit** (`feat(cap): M-m modal 'k' cap-color entry opens the picker`).

- [ ] **Manual smoke (runtime, after `tl update`):** picker opens framed with live palette strips; ↑↓/←→/`v`/`w` work; Enter recolors the cap live; `M-m` → `k` opens it; `setup cap list` palette swatches; a hue cap keeps readable text.

## Self-Review

Spec coverage: OKLCH engine → Task 1; hue wheels + palette roles → Task 2; accent→cap fragment → Task 3; CLI + rename + vividness/wheel → Task 4; picker strips/border/controls → Task 5; M-m entry → Task 6. Migration (mono changes) handled in Task 3's test updates. Phase 2 whole-bar theming is out of scope (separate plan). Names consistent: `__tmux_lives_{rgb_to_oklch,oklch_to_linrgb,gamut_chroma,oklch_hex,contrast_fg,target_hue,palette}`, roles order `bg dim muted accent text`, universals `tmux_lives_cap`/`_vividness`/`_wheel`, argv[13]/[14]. Test isolation (`-L` socket + universal save/restore) in Task 4. All fish gotchas in Global Constraints.
