# Theme Engine v3 — Gradient Map, Phase 1 (engine + tmux bar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the geometric-harmony cap engine's role in the tmux bar with a gradient map — 7 UI roles pinned at lightnesses sampling one hue-arc from the seed — shipped as an opt-in `tmux-lives setup theme <scheme>` CLI that themes the whole tmux status bar; the v2 cap engine stays byte-identical while the theme is off.

**Architecture:** A pure sampler (`hue = f(lightness)`: three coordinated curves L/C/H of `t`) plus a 7-role palette function live install-side next to the kept OKLCH core. The managed fragment gains argv 17–22 and, when a theme scheme is set, renders every bar element from the palette via live-tunable `@options`; the categorizer's pure `__tcz_status_format`/`__tcz_status_identity` builders reference three new role `@options` that the v2 path seeds to `default` (a no-op style), so one format string serves both modes. Spec: `docs/superpowers/specs/2026-07-16-theme-gradient-map-engine-design.md` (approved; decisions resolved — do NOT re-litigate them).

**Tech Stack:** fish 4.7.1, tmux 3.3a, existing OKLCH core (`__tmux_lives_oklch_hex` / `__tmux_lives_rgb_to_oklch` / `__tmux_lives_gamut_chroma` / `__tmux_lives_contrast_fg` in `conf.d/tmux-lives-install.fish:470-552`). No new dependencies, no new files.

## Global Constraints

- **Curve constants (locked by the spec; "final values in the plan" = these):** `L0=0.20`, `L1=0.92`; chroma floors `C0=0.030` (dark end), `C1=0.075` (light end); `Cmax` by vividness: `soft=0.075`, `balanced=0.105`, `vivid=0.130` (**default `balanced`**); chroma peak at `t=0.5`; hue ease `cubic` = `t³` (default `linear`); light-seed ramp inversion when the seed's OKLCH `L ≥ 0.60`.
- **Role ladder (locked; lives in ONE function so spec decision #5 stays tunable):** `bar 0.00 · sep 0.32 · tabs 0.45 · active 0.55 · windows 0.60 · cap 0.70 · text 1.00`. `windows` is ONE colour for all inactive window names; cap fg is derived via `__tmux_lives_contrast_fg`, never a role.
- **Arc presets (locked):** mono `0→45`, warm `8→−64`, cool `60→−8`, span `60→−60`, wide `95→−75`, aurora `120→30`, sunset `150→−90`, fire `130→−44`, complement `180→−30`, full `0→360`. Hue space is OKLCH (v3 has NO wheel knob — the RYB/HSL helpers are v2-only).
- **Resolved spec decisions (do not re-litigate):** cap = plain sample, no chroma bump; mode indicators (prefix/resize amber) stay static; the claude-coral window tint and the `@tmux_lives_claude_color` option stay (semantic mark, like the mode alarms); do NOT pre-solve the user's withheld colour-placement/ordering thought — keep role→t and hue direction adjustable.
- **v2 stays live:** with `tmux_lives_theme` unset, the rendered fragment and status-format must be *visually* identical to today. The only string changes in off-mode are the ones Tasks 3–4 list explicitly (style wrappers that expand to `fg=default` no-ops). The v2 engine (palette/cap/picker) is NOT removed — that's Phase 2.
- **Zero new files** in `conf.d/` or `functions/` — engine + CLI go in `conf.d/tmux-lives-install.fish`, builder edits in `functions/tmux-categorize.fish`, tests in the existing suites.
- **fish gotchas (each has bitten this repo — treat as law):**
  - NO comparisons inside `math` — branch with float-capable `test` (`test $t -le 0.5` works on floats).
  - Multi-value returns: `printf '%s\n' a b` (one per line) — command substitution splits on NEWLINES; `echo "0 45"` is ONE element.
  - Capture a command substitution into a var BEFORE concatenating into `set -a f "…"` or an `echo` argument — a zero-output substitution collapses the whole argument to nothing.
  - `test -n (cmd)` is TRUE when cmd prints nothing (zero args) — capture into a var and quote: `set -l x (cmd); test -n "$x"`.
  - Single-quote `#rrggbb` values in fragment lines — an unquoted standalone `#hex` is a tmux COMMENT (option silently empty, `source-file` still rc0). `bg=#hex` (prefixed) is safe — matches the shipped `status-style` line.
  - `%` is integer-only — wrap hues with the existing `__tmux_lives_norm360` (while+test).
  - Functions that may return nothing (e.g. `__tmux_lives_seed_hex`) are safe to capture as lists (`count` 0) but must never feed `test -n` unquoted.
- **Test isolation:** any live tmux mutation goes through the `tmux_lives_tmux_socket` seam onto a throwaway `-L` server; save/clear ALL universals a section touches at the TOP of the section and restore at the BOTTOM (the cap_role lesson: the CLI reads them on EVERY apply); stub `__tmux_lives_write_fragment` (the `functions -c` idiom at `tests/test-tmux-install.fish:181-186`) around every CLI call that could reach it; point `__fish_config_dir` at a nonexistent dir while calling `__tmux_lives_color_cmd --apply` so its categorizer `recolor` short-circuits.
- **Suite:** `for t in tests/test-*.fish; fish $t; end` — all 8 suites must print `ALL PASS` before every commit.
- **Commits:** `feat(theme): …` prefix; commit per task; do NOT deploy (the user runs `fisher update`).
- Line numbers below are as of branch `feat/theme-gradient-map` @ `891ba31`; later tasks shift them — anchor by the quoted code, not the number.

## File Structure

- `conf.d/tmux-lives-install.fish` — gains: `__tmux_lives_seed_hex` (css→hex parser, inserted before `__tmux_lives_derive_status` ~419); the v3 engine block (`__tmux_lives_theme_arc`, `__tmux_lives_theme_roles`, `__tmux_lives_theme_sample`, `__tmux_lives_theme_lrange`, `__tmux_lives_theme_palette`) after `__tmux_lives_palette` (~686); the CLI block (`__tmux_lives_theme_valid`, `__tmux_lives_theme_push`, `__tmux_lives_theme_apply_live`, `__tmux_lives_theme_list`, `__tmux_lives_theme_cmd`) after `__tmux_lives_cap_cmd` (~917); themed branch in `__tmux_lives_render_fragment` (argv 17–22); guards in `__tmux_lives_cap_apply_live` / `__tmux_lives_color_cmd --apply`; `theme` in `__tmux_lives_setup_dispatch` + a help row.
- `functions/tmux-categorize.fish` — 3 surgical string edits in `__tcz_status_format` (149-165) and `__tcz_status_identity` (143-147).
- `tests/test-tmux-install.fish` — new sections (engine, palette, fragment, CLI), inserted before the final summary block.
- `tests/test-tmux-categorize.fish` — builder assertions updated + added (762-792 region).
- `README.md`, `CLAUDE.md` — Task 6.

## New universals (all set by `setup theme`, read via `__tmux_lives_key`)

`tmux_lives_theme` (scheme; unset/empty = theme OFF), `tmux_lives_theme_phase` (deg, default 0), `tmux_lives_theme_vividness` (soft|balanced|vivid, default balanced), `tmux_lives_theme_shape` (arc|flat, default arc), `tmux_lives_theme_ease` (linear|cubic, default linear), `tmux_lives_theme_range` ("L0,L1", default "0.20,0.92").

## New/changed `@options`

Themed: `@tmux_lives_bar_bg`/`@tmux_lives_cap_bg`/`@tmux_lives_cap_fg` (existing names, gradient samples) + new `@tmux_lives_sep_fg`, `@tmux_lives_tabs_color` (emitted, consumed in Phase 2), `@tmux_lives_active_fg` (emitted, provisional — nothing consumes it yet), `@tmux_lives_mark_fg` (the ✦), `@tmux_lives_text_fg`. Off-mode seeds the four new fg options to `default` and `@tmux_lives_tabs_color` to `''`.

---

### Task 1: Gradient-map core — `__tmux_lives_theme_arc` + `__tmux_lives_theme_roles` + `__tmux_lives_theme_sample`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (insert a new section immediately after `__tmux_lives_palette` ends, currently line 686)
- Test: `tests/test-tmux-install.fish` (new section immediately before the suite's final summary block — search for `ALL PASS`)

**Interfaces:**
- Consumes: `__tmux_lives_oklch_hex L C H → #rrggbb` (existing), `__tmux_lives_norm360 h → deg` (existing), `__tmux_lives_rgb_to_oklch r g b → L\nC\nH` (existing, tests only).
- Produces: `__tmux_lives_theme_arc <scheme>` → two lines `start` `end` (hue offsets in degrees; unknown scheme → no output). `__tmux_lives_theme_roles` → 7 lines `"<role> <t>"` in order `bar sep tabs active windows cap text`. `__tmux_lives_theme_sample <t> <seedH> <a0> <a1> <phase> <l0> <l1> <cmax> <shape> <ease>` → one `#rrggbb` line.

- [ ] **Step 1: Write the failing tests** — append to `tests/test-tmux-install.fish` just before the final summary block:

```fish
# --- theme engine v3 (gradient map): arc presets + role ladder + sampler -----
t "theme_arc mono"       "0 45"    (__tmux_lives_theme_arc mono | string join ' ')
t "theme_arc warm"       "8 -64"   (__tmux_lives_theme_arc warm | string join ' ')
t "theme_arc cool"       "60 -8"   (__tmux_lives_theme_arc cool | string join ' ')
t "theme_arc span"       "60 -60"  (__tmux_lives_theme_arc span | string join ' ')
t "theme_arc wide"       "95 -75"  (__tmux_lives_theme_arc wide | string join ' ')
t "theme_arc aurora"     "120 30"  (__tmux_lives_theme_arc aurora | string join ' ')
t "theme_arc sunset"     "150 -90" (__tmux_lives_theme_arc sunset | string join ' ')
t "theme_arc fire"       "130 -44" (__tmux_lives_theme_arc fire | string join ' ')
t "theme_arc complement" "180 -30" (__tmux_lives_theme_arc complement | string join ' ')
t "theme_arc full"       "0 360"   (__tmux_lives_theme_arc full | string join ' ')
t "theme_arc unknown -> empty" 0 (count (__tmux_lives_theme_arc nope))
t "theme_roles count" 7 (count (__tmux_lives_theme_roles))
t "theme_roles ladder" "bar 0.00|sep 0.32|tabs 0.45|active 0.55|windows 0.60|cap 0.70|text 1.00" (__tmux_lives_theme_roles | string join '|')

# sampler properties, verified through the OKLCH core itself (seed hue = the user's green)
set -g THSEED (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 "#485b3c"))
function _tl; set -l ok (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[1])); echo $ok[1]; end
function _tc; set -l ok (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[1])); echo $ok[2]; end
function _th; set -l ok (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[1])); echo $ok[3]; end
set -g TS0 (__tmux_lives_theme_sample 0    $THSEED[3] 0 45 0 0.20 0.92 0.105 arc linear)
set -g TS5 (__tmux_lives_theme_sample 0.5  $THSEED[3] 0 45 0 0.20 0.92 0.105 arc linear)
set -g TS1 (__tmux_lives_theme_sample 1.00 $THSEED[3] 0 45 0 0.20 0.92 0.105 arc linear)
t "sample emits a hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- "$TS0"; and echo 1; or echo 0)
t "sample t=0 lands at L0 (±0.02)" 1 (test (math "abs("(_tl $TS0)" - 0.20)") -lt 0.02; and echo 1; or echo 0)
t "sample t=1 lands at L1 (±0.02)" 1 (test (math "abs("(_tl $TS1)" - 0.92)") -lt 0.02; and echo 1; or echo 0)
t "sample L is monotonic" 1 (test (_tl $TS0) -lt (_tl $TS5); and test (_tl $TS5) -lt (_tl $TS1); and echo 1; or echo 0)
t "chroma floor: dark end tinted, never grey" 1 (test (_tc $TS0) -gt 0.015; and echo 1; or echo 0)
t "chroma arcs to a mid-ramp peak" 1 (test (_tc $TS5) -gt (_tc $TS0); and test (_tc $TS5) -gt (_tc $TS1); and echo 1; or echo 0)
set -g TSF (__tmux_lives_theme_sample 0 $THSEED[3] 0 45 0 0.20 0.92 0.105 flat linear)
t "flat shape lifts the dark end" 1 (test (_tc $TSF) -gt (_tc $TS0); and echo 1; or echo 0)
set -g TP0 (__tmux_lives_theme_sample 0.7 $THSEED[3] 0 45 0   0.20 0.92 0.105 arc linear)
set -g TP1 (__tmux_lives_theme_sample 0.7 $THSEED[3] 0 45 120 0.20 0.92 0.105 arc linear)
t "phase leaves L alone (±0.02)" 1 (test (math "abs("(_tl $TP1)" - "(_tl $TP0)")") -lt 0.02; and echo 1; or echo 0)
t "phase rotates H by ~120 (±8)" 1 (test (math "abs("(__tmux_lives_norm360 (math (_th $TP1)" - "(_th $TP0)))" - 120)") -lt 8; and echo 1; or echo 0)
set -g TEL (__tmux_lives_theme_sample 0.6 $THSEED[3] 0 90 0 0.20 0.92 0.105 arc linear)
set -g TEC (__tmux_lives_theme_sample 0.6 $THSEED[3] 0 90 0 0.20 0.92 0.105 arc cubic)
t "cubic ease trails linear mid-ramp" 1 (test (__tmux_lives_norm360 (math (_th $TEC)" - $THSEED[3]")) -lt (__tmux_lives_norm360 (math (_th $TEL)" - $THSEED[3]")); and echo 1; or echo 0)
functions -e _tl _tc _th
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -30`
Expected: FAILs for every `theme_arc`/`theme_roles`/`sample` test (unknown function → empty output), suite prints SOME FAILED.

- [ ] **Step 3: Implement** — insert after `__tmux_lives_palette`'s `end` (line 686) in `conf.d/tmux-lives-install.fish`:

```fish
# --- theme engine v3 (gradient map): roles sample ONE hue-arc by lightness ---
# spec: docs/superpowers/specs/2026-07-16-theme-gradient-map-engine-design.md
# A theme = seed + scheme (arc) + phase (rotate) + knobs (cmax/range/shape/ease).
function __tmux_lives_theme_arc --argument-names scheme --description 'v3 scheme -> hue-arc offsets off the seed hue, two lines: start end (deg); unknown -> nothing'
    switch "$scheme"
        case mono;       printf '%s\n' 0 45
        case warm;       printf '%s\n' 8 -64
        case cool;       printf '%s\n' 60 -8
        case span;       printf '%s\n' 60 -60
        case wide;       printf '%s\n' 95 -75
        case aurora;     printf '%s\n' 120 30
        case sunset;     printf '%s\n' 150 -90
        case fire;       printf '%s\n' 130 -44
        case complement; printf '%s\n' 180 -30
        case full;       printf '%s\n' 0 360
    end
end

function __tmux_lives_theme_roles --description 'v3 role ladder, "<role> <t>" per line — THE one place role->lightness lives (spec decision #5: keep adjustable)'
    printf '%s\n' 'bar 0.00' 'sep 0.32' 'tabs 0.45' 'active 0.55' 'windows 0.60' 'cap 0.70' 'text 1.00'
end

function __tmux_lives_theme_sample --argument-names t seedH a0 a1 phase l0 l1 cmax shape ease --description 'sample the gradient at t: L ramp l0->l1; hue arc a0->a1 (+phase) off seedH, eased; chroma arc C0 .030 -> cmax @0.5 -> C1 .075 (flat: cmax) -> #rrggbb'
    set -l L (math "$l0 + ($l1 - $l0) * $t")
    set -l et $t
    test "$ease" = cubic; and set et (math "$t ^ 3")
    set -l H (__tmux_lives_norm360 (math "$seedH + $a0 + ($a1 - $a0) * $et + $phase"))
    # chroma: an arc with FLOORS (ends tinted, never pure grey); no math comparisons — float test.
    set -l C $cmax
    if test "$shape" != flat
        if test $t -le 0.5
            set C (math "0.030 + ($cmax - 0.030) * ($t / 0.5)")
        else
            set C (math "$cmax - ($cmax - 0.075) * (($t - 0.5) / 0.5)")
        end
    end
    __tmux_lives_oklch_hex $L $C $H
end
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -5`
Expected: `ALL PASS` (pass count grows by 23).

- [ ] **Step 5: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — expect 8× ALL PASS.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): gradient-map core — arc presets, role ladder, sampler (v3 Phase 1)"
```

---

### Task 2: Seed parsing + `__tmux_lives_theme_palette` (7 roles, light-seed inversion)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — insert `__tmux_lives_seed_hex` immediately BEFORE `__tmux_lives_derive_status` (line 419); refactor `__tmux_lives_derive_status`'s parse block to use it; insert `__tmux_lives_theme_lrange` + `__tmux_lives_theme_palette` after `__tmux_lives_theme_sample` (Task 1's block)
- Test: `tests/test-tmux-install.fish` (extend the Task-1 section)

**Interfaces:**
- Consumes: Task 1's `__tmux_lives_theme_arc`/`__tmux_lives_theme_roles`/`__tmux_lives_theme_sample`; existing `__tmux_lives_rgb_to_oklch`, `__tmux_lives_hex_to_rgb01`.
- Produces: `__tmux_lives_seed_hex <css>` → `#rrggbb` or nothing (named colours → nothing). `__tmux_lives_theme_lrange <range>` → two lines `L0` `L1` (defaults `0.20` `0.92` on empty/garbage). `__tmux_lives_theme_palette <seedHex> <scheme> <phase> <vividness> <l0> <l1> <shape> <ease>` → 7 hex lines in role order `bar sep tabs active windows cap text`, or NOTHING on a non-hex seed / unknown scheme (callers fall back to v2). Empty knob args take the defaults.

- [ ] **Step 1: Write the failing tests** — append to the theme section in `tests/test-tmux-install.fish`:

```fish
# seed parsing (css -> #rrggbb; named colors have no derivable hue -> empty)
t "seed_hex passthrough" "#485b3c" (__tmux_lives_seed_hex "#485b3c")
t "seed_hex lowercases"  "#485b3c" (__tmux_lives_seed_hex "#485B3C")
t "seed_hex short hex"   "#4488cc" (__tmux_lives_seed_hex "#48c")
t "seed_hex rgb()"       "#1f6feb" (__tmux_lives_seed_hex "rgb(31, 111, 235)")
t "seed_hex named -> empty" 0 (count (__tmux_lives_seed_hex red))
t "seed_hex empty -> empty" 0 (count (__tmux_lives_seed_hex ""))
t "derive_status still parses rgb() after the refactor" 1 (string match -q 'bg=#*' -- (__tmux_lives_derive_status "rgb(31,111,235)" 0); and echo 1; or echo 0)
t "derive_status unchanged on hex" "bg=#76846d,fg=#d3d8d0" (__tmux_lives_derive_status "#485b3c" 0)
# lightness-range parsing
t "lrange default" "0.20 0.92" (__tmux_lives_theme_lrange "" | string join ' ')
t "lrange parses"  "0.30 0.85" (__tmux_lives_theme_lrange "0.30,0.85" | string join ' ')
t "lrange garbage -> default" "0.20 0.92" (__tmux_lives_theme_lrange "wat" | string join ' ')

# palette: 7 roles on the ramp
set -g TPAL1 (__tmux_lives_theme_palette "#485b3c" mono 0 balanced 0.20 0.92 arc linear)
t "theme_palette emits 7 roles" 7 (count $TPAL1)
t "theme_palette all hexes" 7 (count (string match -r '^#[0-9a-f]{6}$' $TPAL1))
function _tl2; set -l ok (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[1])); echo $ok[1]; end
set -g _mono_ok 1
for i in (seq 2 7)
    set -l prev (math $i - 1)
    test (_tl2 $TPAL1[$prev]) -lt (_tl2 $TPAL1[$i]); or set _mono_ok 0
end
t "theme_palette L strictly ascending (dark seed)" 1 $_mono_ok
# light seed (OKLCH L >= 0.60): ramp inverts — bar light, text dark (the required text fix)
set -g TPALL (__tmux_lives_theme_palette "#e8e0d0" mono 0 balanced 0.20 0.92 arc linear)
t "light seed inverts the ramp" 1 (test (_tl2 $TPALL[1]) -gt (_tl2 $TPALL[7]); and echo 1; or echo 0)
functions -e _tl2
# guards
t "theme_palette non-hex seed -> empty" 0 (count (__tmux_lives_theme_palette colour236 mono 0 balanced 0.20 0.92 arc linear))
t "theme_palette unknown scheme -> empty" 0 (count (__tmux_lives_theme_palette "#485b3c" wat 0 balanced 0.20 0.92 arc linear))
t "theme_palette empty knobs = defaults" (string join ' ' $TPAL1) (string join ' ' (__tmux_lives_theme_palette "#485b3c" mono '' '' '' '' '' ''))
```

Note on the locked `derive_status unchanged on hex` value: verify it against today's PRE-refactor output first (`fish -c 'source conf.d/tmux-lives-install.fish; __tmux_lives_derive_status "#485b3c" 0'` must print `bg=#76846d,fg=#d3d8d0`) — this test must pass BEFORE the refactor and stay passing after; byte-identity across the refactor is the contract. If the pre-refactor output differs from the locked string, lock the actual output instead and continue.

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -30`
Expected: FAILs on every `seed_hex`/`lrange`/`theme_palette` test.

- [ ] **Step 3: Implement.** Insert BEFORE `__tmux_lives_derive_status` (line 419):

```fish
function __tmux_lives_seed_hex --argument-names css --description 'css color (#rrggbb / #rgb / rgb()) -> #rrggbb, lowercased; anything else (named colors, color(p3 ...)) -> nothing'
    set -l color (string lower -- "$css")
    test -n "$color"; or return
    set -l m (string match -rg '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$' -- $color)
    if test (count $m) -eq 3
        echo $color
        return
    end
    set m (string match -rg '^#([0-9a-f])([0-9a-f])([0-9a-f])$' -- $color)
    if test (count $m) -eq 3
        echo "#$m[1]$m[1]$m[2]$m[2]$m[3]$m[3]"
        return
    end
    set m (string match -rg '^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)' -- $color)
    if test (count $m) -eq 3
        set -l r $m[1]; set -l g $m[2]; set -l b $m[3]
        for v in r g b
            set -l x $$v
            test "$x" -gt 255; and set $v 255
        end
        printf '#%02x%02x%02x\n' $r $g $b
    end
end
```

Refactor `__tmux_lives_derive_status`: replace its parse block (from `set -l color (string lower -- $argv[1])` down to the end of the `# clamp 0-255` loop, lines 420-444) with:

```fish
    set -l invert $argv[2]
    set -l hexin (__tmux_lives_seed_hex $argv[1])
    test -n "$hexin"; or return
    set -l m (string match -rg '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$' -- $hexin)
    set -l r (math "0x$m[1]"); set -l g (math "0x$m[2]"); set -l b (math "0x$m[3]")
```

(the 0-255 clamp now lives in `__tmux_lives_seed_hex`'s `rgb()` branch; the lighten/darken + tint code below stays untouched.)

Insert after `__tmux_lives_theme_sample`:

```fish
function __tmux_lives_theme_lrange --argument-names range --description '"L0,L1" -> two lines L0 L1; empty/garbage -> the 0.20 0.92 defaults'
    set -l rr (string split , -- "$range")
    if test (count $rr) -eq 2
        and string match -qr '^(0(\.[0-9]+)?|1(\.0+)?)$' -- $rr[1]
        and string match -qr '^(0(\.[0-9]+)?|1(\.0+)?)$' -- $rr[2]
        printf '%s\n' $rr[1] $rr[2]
        return
    end
    printf '%s\n' 0.20 0.92
end

function __tmux_lives_theme_palette --argument-names seedHex scheme phase vividness l0 l1 shape ease --description 'seed + scheme/phase/knobs -> 7 role hexes one per line (bar sep tabs active windows cap text); non-hex seed or unknown scheme -> nothing (callers fall back to v2)'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l arc (__tmux_lives_theme_arc "$scheme")
    test (count $arc) -eq 2; or return
    test -n "$phase"; or set phase 0
    test -n "$l0"; or set l0 0.20
    test -n "$l1"; or set l1 0.92
    test -n "$shape"; or set shape arc
    test -n "$ease"; or set ease linear
    set -l cmax 0.105
    switch "$vividness"
        case soft;  set cmax 0.075
        case vivid; set cmax 0.130
    end
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    # light seed -> inverted ramp (dark text end): the spec's required text-legibility fix.
    if test $ok[1] -ge 0.60
        set -l swap $l0
        set l0 $l1
        set l1 $swap
    end
    for rt in (__tmux_lives_theme_roles)
        set -l parts (string split ' ' $rt)
        set -l hx (__tmux_lives_theme_sample $parts[2] $ok[3] $arc[1] $arc[2] $phase $l0 $l1 $cmax $shape $ease)
        test -n "$hx"; or return
        printf '%s\n' $hx
    end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -5` — expect ALL PASS.

- [ ] **Step 5: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — 8× ALL PASS (the categorize/auto suites exercise derive_status indirectly through fragment rendering; any failure here means the refactor changed derive_status output — stop and fix, byte-identity is the contract).

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): 7-role gradient palette + css seed parsing (light-seed ramp inversion)"
```

---

### Task 3: Status-format builder role hooks (categorizer)

**Files:**
- Modify: `functions/tmux-categorize.fish:143-165` (`__tcz_status_identity`, `__tcz_status_format`)
- Test: `tests/test-tmux-categorize.fish:762-792` (builder + identity sections)

**Interfaces:**
- Consumes: nothing new — pure string builders.
- Produces: format strings referencing `@tmux_lives_text_fg` (centre identity + via Task 4 the current window), `@tmux_lives_mark_fg` (the ✦), and `#{T:window-status-separator}` (so a style-bearing separator value gets format-expanded). The v2 fragment seeds all of these to `default` (Task 4), so pre-theme rendering is visually unchanged. NB deploy safety: the fisher `_tmux_lives_post_update` handler re-renders the fragment whenever one exists, so the new format string and its option seeds always land together.

- [ ] **Step 1: Update + add the builder tests.** In `tests/test-tmux-categorize.fish`:

(a) The identity render tests (lines 787-792) render `$IDFMT` through a real `display-message -p`; style wrappers are NOT stripped by `-p`, so set the two new options on the test socket first and update the expected strings. Immediately before the `set -g IDFMT (__tcz_status_identity)` line (787) add:

```fish
command tmux -L $idsock set -g @tmux_lives_mark_fg default 2>/dev/null
command tmux -L $idsock set -g @tmux_lives_text_fg default 2>/dev/null
```

and change the two expectations (789, 792):

```fish
t "identity: claude session collapses to a single '✦ name'" "#[fg=default]✦#[fg=default] TMUX Setup 13" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
t "identity: @tmux_lives_name overrides the claude name (still ✦-marked)" "#[fg=default]✦#[fg=default] Neurotto CLI" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
```

(b) The static-pattern assertion at line 770 pins `✦ ` followed directly by the name ternary; update its pattern to the wrapped form:

```fish
t "sf identity uses the collapsed claude idiom (single readable ✦ mark)" yes (string match -q '*✦#[fg=#{@tmux_lives_text_fg}] #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{@tmux_lives_claude}}*' -- "$SF"; and echo yes; or echo no)
```

(c) Add three new assertions after line 770:

```fish
t "sf separator is format-expanded (T:)" yes (string match -q '*#{T:window-status-separator}*' -- "$SF"; and echo yes; or echo no)
t "sf centre identity wears the text role" yes (string match -q '*#[fg=#{@tmux_lives_text_fg}]#{?#{!=:#{@tmux_lives_claude},*' -- "$SF"; and echo yes; or echo no)
t "identity ✦ wears the mark role" yes (string match -q '*#[fg=#{@tmux_lives_mark_fg}]✦*' -- (__tcz_status_identity); and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -20`
Expected: the updated/new assertions FAIL (old strings still rendered).

- [ ] **Step 3: Implement** — three edits in `functions/tmux-categorize.fish`:

(a) `__tcz_status_identity` (line 146): wrap the ✦ in the mark role and hand back to the text role:

```fish
    echo '#{?#{!=:#{@tmux_lives_claude},},#[fg=#{@tmux_lives_mark_fg}]✦#[fg=#{@tmux_lives_text_fg}] #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{@tmux_lives_claude}},#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}}'
```

(b) `__tcz_status_format` line 156 — format-expand the separator (twice; this is what lets a separator value carry `#[fg=#{@…}]`, exactly the mechanism `#{T:window-status-format}` already uses for the claude tint):

```fish
    set -l win '#{W:#{T:window-status-format}#{?window_end_flag,,#{T:window-status-separator}},#{T:window-status-current-format}#{?window_end_flag,,#{T:window-status-separator}}}'
```

(c) `__tcz_status_format` line 161 — the centre identity wears the text role (mode branches untouched — decision #4):

```fish
    set -l centre "#{?client_prefix,❯ ,}#{?#{==:#{client_key_table},tmuxlives-resize},◇ RESIZE ◇  #[fg=#{@tmux_lives_cap_fg}]arrows move · x kill · esc/enter done,#[fg=#{@tmux_lives_text_fg}]$id#[fg=default]}"
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -5` — expect ALL PASS.

- [ ] **Step 5: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — 8× ALL PASS. (test-tmux-install's `window-status-separator*•*` wildcard still matches; if any other suite pins the exact old separator/identity strings, update it to the new literal shown above.)

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(theme): status-format role hooks — T: separator, text/mark fg @options"
```

---

### Task 4: Fragment renders the gradient-map roles (argv 17–22)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (argv declarations after line 31; the region lines 75-109) and `__tmux_lives_write_fragment` (line 226 call site)
- Test: `tests/test-tmux-install.fish` (extend the theme section)

**Interfaces:**
- Consumes: `__tmux_lives_seed_hex`, `__tmux_lives_theme_lrange`, `__tmux_lives_theme_palette` (Task 2), `__tmux_lives_contrast_fg` (existing).
- Produces: `__tmux_lives_render_fragment` argv 17-22 = `theme` `themephase` `themeviv` `themeshape` `themeease` `themerange` (all optional; absent/empty = v2). Themed fragments emit `status-style bg=<bar>,fg=<windows>` plus role `@options` (`@tmux_lives_sep_fg/_tabs_color/_active_fg/_mark_fg/_text_fg`, single-quoted hexes); off-mode seeds them `default`/`''`. `__tmux_lives_write_fragment` passes the six new universals.

- [ ] **Step 1: Write the failing tests** — append to the theme section of `tests/test-tmux-install.fish`:

```fish
# --- theme engine v3: fragment renders the gradient-map roles ----------------
# theme OFF (argv 17 absent): v2 values + neutral role seeds
set -g TOFF (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent | string collect)
t "off: v2 status-style survives" yes (string match -q '*set -g status-style bg=#*' -- "$TOFF"; and echo yes; or echo no)
t "off: sep_fg seeded default"  yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: text_fg seeded default" yes (string match -q '*set -g @tmux_lives_text_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: mark_fg seeded default" yes (string match -q '*set -g @tmux_lives_mark_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: active_fg seeded default" yes (string match -q '*set -g @tmux_lives_active_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: cap still the v2 accent" yes (string match -q "*set -g @tmux_lives_cap_bg '#*" -- "$TOFF"; and echo yes; or echo no)
# theme ON: every role @option carries its gradient sample
set -g TON (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent warm '' '' '' '' '' | string collect)
set -g TONPAL (__tmux_lives_theme_palette "#485b3c" warm 0 balanced 0.20 0.92 arc linear)
t "on: status-style = bar+windows samples" yes (string match -q "*set -g status-style bg=$TONPAL[1],fg=$TONPAL[5]*" -- "$TON"; and echo yes; or echo no)
t "on: bar_bg is the bar sample (quoted)" yes (string match -q "*set -g @tmux_lives_bar_bg '$TONPAL[1]'*" -- "$TON"; and echo yes; or echo no)
t "on: sep_fg role"   yes (string match -q "*set -g @tmux_lives_sep_fg '$TONPAL[2]'*" -- "$TON"; and echo yes; or echo no)
t "on: tabs_color emitted (Phase-2 consumer)" yes (string match -q "*set -g @tmux_lives_tabs_color '$TONPAL[3]'*" -- "$TON"; and echo yes; or echo no)
t "on: active_fg emitted (provisional)" yes (string match -q "*set -g @tmux_lives_active_fg '$TONPAL[4]'*" -- "$TON"; and echo yes; or echo no)
t "on: cap_bg is the cap sample" yes (string match -q "*set -g @tmux_lives_cap_bg '$TONPAL[6]'*" -- "$TON"; and echo yes; or echo no)
t "on: cap_fg stays readable" yes (string match -q "*set -g @tmux_lives_cap_fg '"(__tmux_lives_contrast_fg $TONPAL[6])"'*" -- "$TON"; and echo yes; or echo no)
t "on: mark_fg = cap sample" yes (string match -q "*set -g @tmux_lives_mark_fg '$TONPAL[6]'*" -- "$TON"; and echo yes; or echo no)
t "on: text_fg role" yes (string match -q "*set -g @tmux_lives_text_fg '$TONPAL[7]'*" -- "$TON"; and echo yes; or echo no)
t "on: claude coral stays (semantic mark)" yes (string match -q "*set -g @tmux_lives_claude_color '#D97757'*" -- "$TON"; and echo yes; or echo no)
# knobs flow through argv 18-22
set -g TONK (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent warm 90 vivid flat cubic 0.30,0.85 | string collect)
set -g TONKPAL (__tmux_lives_theme_palette "#485b3c" warm 90 vivid 0.30 0.85 flat cubic)
t "on: knobs reach the palette" yes (string match -q "*set -g @tmux_lives_cap_bg '$TONKPAL[6]'*" -- "$TONK"; and echo yes; or echo no)
# a theme with an unusable seed falls back to the whole v2 path
set -g TBAD (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent warm | string collect)
t "on+no seed: v2 fallback cap" yes (string match -q "*set -g @tmux_lives_cap_bg 'colour238'*" -- "$TBAD"; and echo yes; or echo no)
t "on+no seed: role seeds default" yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TBAD"; and echo yes; or echo no)
# themed fragment parses on a real -L server and the options land
set -g thfsock tli-th-$fish_pid
command tmux -L $thfsock new-session -d 2>/dev/null
printf '%s\n' "$TON" | string replace -a '/x/cat.fish' '/tmp/nope.fish' > /tmp/tli-thfrag-$fish_pid.conf
t "themed fragment parses (source-file rc0)" 0 (command tmux -L $thfsock source-file /tmp/tli-thfrag-$fish_pid.conf 2>/dev/null; echo $status)
t "themed @text_fg lands" "$TONPAL[7]" (command tmux -L $thfsock show -gv @tmux_lives_text_fg 2>/dev/null)
t "themed status-style lands" "bg=$TONPAL[1],fg=$TONPAL[5]" (command tmux -L $thfsock show -gv status-style 2>/dev/null)
command tmux -L $thfsock kill-server 2>/dev/null; rm -f /tmp/tli-thfrag-$fish_pid.conf
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -40`
Expected: all `off:`/`on:` theme-fragment tests FAIL (options absent from the render).

- [ ] **Step 3: Implement.** In `__tmux_lives_render_fragment`:

(a) After the `caprole` declaration + defaults (lines 31-34), add:

```fish
    set -l theme $argv[17]        # v3 gradient-map scheme ('' = theme off -> the v2 path below)
    set -l themephase $argv[18]   # hue phase in degrees ('' = 0)
    set -l themeviv $argv[19]     # soft|balanced|vivid ('' = balanced)
    set -l themeshape $argv[20]   # arc|flat ('' = arc)
    set -l themeease $argv[21]    # linear|cubic ('' = linear)
    set -l themerange $argv[22]   # "L0,L1" ('' = 0.20,0.92)
```

(b) Replace the region from `set -l ss (__tmux_lives_derive_status $color $invert)` (line 75) through the `@tmux_lives_claude_color` line (109) with:

```fish
    # --- theme engine v3 (gradient map, Phase 1): with a scheme in argv[17] the whole bar
    # renders from the 7-role gradient palette (bar sep tabs active windows cap text);
    # otherwise the v2 path is unchanged. Role->t lives in __tmux_lives_theme_roles.
    set -l tl (__tmux_lives_theme_lrange "$themerange")
    set -l tpal
    if test -n "$theme"
        set -l seedhex (__tmux_lives_seed_hex $color)
        test -n "$seedhex"; and set tpal (__tmux_lives_theme_palette $seedhex "$theme" "$themephase" "$themeviv" $tl[1] $tl[2] "$themeshape" "$themeease")
    end
    set -l themed 0
    test (count $tpal) -eq 7; and set themed 1
    if test $themed -eq 1
        # bar (t=0) is the trough bg; windows (t=.60) is the base fg all inactive names inherit
        set -a f "set -g status-style bg=$tpal[1],fg=$tpal[5]"
    else
        set -l ss (__tmux_lives_derive_status $color $invert)
        test -n "$ss"; and set -a f "set -g status-style $ss"
    end
    # --- status bar overhaul: names-only window list, @option-driven caps, status-format[0] ---
    # Layout lives in status-format[0] (built by the categorizer's pure `status-format` verb);
    # every knob is a live-tunable @option so `tmux set -g @tmux_lives_*` retints with no re-render.
    # tint the auto-named `claude` window in @tmux_lives_claude_color; reset fg after so the
    # separator / other windows are unaffected. Position unchanged; current stays bold.
    # The current window name + separator wear the v3 text/sep roles; the v2 path seeds those
    # @options to 'default' (a no-op style) so the pre-theme look is unchanged.
    set -a f "set -g window-status-format '#{?#{==:#{window_name},claude},#[fg=#{@tmux_lives_claude_color}]#W#[fg=default],#W}'"
    set -a f "set -g window-status-current-format '#[bold]#{?#{==:#{window_name},claude},#[fg=#{@tmux_lives_claude_color}]#W#[fg=default],#[fg=#{@tmux_lives_text_fg}]#W#[fg=default]}#[nobold]'"
    set -a f "set -g window-status-separator ' #[fg=#{@tmux_lives_sep_fg}]•#[fg=default] '"
    # cap/accent colors. Themed: bar/cap are gradient samples. v2: bar bg = the ShellFish-derived
    # status bg; the cap = the OKLCH palette's chosen role. __tmux_lives_palette self-guards a
    # non-hex baseHex (returns empty), so the colour236 fallback flows to the colour238 default.
    set -l barbg
    set -l capbg
    if test $themed -eq 1
        set barbg $tpal[1]
        set capbg $tpal[6]
    else
        set barbg (__tmux_lives_derive_status_bg $color $invert)   # the bar's own bg (status-style bg)
        test -n "$barbg"; or set barbg colour236
        # NB "$cap" is quoted: $argv[12] may be a ZERO-element list when render_fragment is called
        # with <12 args (several test sites do this); unquoted it would shift $wheel/$vividness left.
        # An empty scheme falls through __tmux_lives_palette's switch to its mono default.
        set -l pal (__tmux_lives_palette $barbg "$cap" $wheel $vividness)   # OKLCH role palette; accent = the cap
        set -l ridx 4
        switch $caprole
            case dim; set ridx 2
            case muted; set ridx 3
        end
        set capbg $pal[$ridx]
        test -n "$capbg"; or set capbg colour238
    end
    set -l capfg (__tmux_lives_contrast_fg $capbg)                # readable fg for whichever cap shade/hue was picked
    # QUOTE the values: an unquoted #rrggbb hex is read as a tmux COMMENT (option set to empty). Single
    # quotes keep the '#5793f0' bg intact (harmless around the colourNNN default too).
    set -a f "set -g @tmux_lives_bar_bg '$barbg'"                 # slant transition target (cap -> bar)
    set -a f "set -g @tmux_lives_cap_bg '$capbg'"
    set -a f "set -g @tmux_lives_cap_fg '$capfg'"
    if test $themed -eq 1
        set -a f "set -g @tmux_lives_sep_fg '$tpal[2]'"           # sep role (t=.32): the • separators
        set -a f "set -g @tmux_lives_tabs_color '$tpal[3]'"       # tabs role (t=.45): Phase 2 wires the ShellFish OSC
        set -a f "set -g @tmux_lives_active_fg '$tpal[4]'"        # active role (t=.55): provisional, unconsumed
        set -a f "set -g @tmux_lives_mark_fg '$tpal[6]'"          # the ✦ identity mark wears the cap sample
        set -a f "set -g @tmux_lives_text_fg '$tpal[7]'"          # text role (t=1.0): current window + centre identity
    else
        set -a f "set -g @tmux_lives_sep_fg default"
        set -a f "set -g @tmux_lives_tabs_color ''"
        set -a f "set -g @tmux_lives_active_fg default"
        set -a f "set -g @tmux_lives_mark_fg default"
        set -a f "set -g @tmux_lives_text_fg default"
    end
    set -a f "set -g @tmux_lives_prefix_color colour214"
    set -a f "set -g @tmux_lives_resize_color colour208"
    set -a f "set -g @tmux_lives_claude_color '#D97757'"   # Claude coral; static, independent of the ShellFish bar color
```

(c) In `__tmux_lives_write_fragment` (line 226), append six args to the `__tmux_lives_render_fragment` call, after `(__tmux_lives_key tmux_lives_cap_role accent)`:

```fish
(__tmux_lives_key tmux_lives_theme '') (__tmux_lives_key tmux_lives_theme_phase 0) (__tmux_lives_key tmux_lives_theme_vividness balanced) (__tmux_lives_key tmux_lives_theme_shape arc) (__tmux_lives_key tmux_lives_theme_ease linear) (__tmux_lives_key tmux_lives_theme_range 0.20,0.92)
```

(`__tmux_lives_key` always echoes — even an empty value yields one empty element, so argv positions never shift.)

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -5` — expect ALL PASS. If any pre-existing fragment assertion pins the exact old `window-status-current-format`/`window-status-separator` strings, update it to the new literals from step 3(b).

- [ ] **Step 5: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — 8× ALL PASS.

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): fragment renders the gradient-map roles (argv 17-22, v2-safe defaults)"
```

---

### Task 5: `setup theme` CLI + live apply + v2 coexistence guards

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — new CLI block after `__tmux_lives_cap_cmd` (line 917); guard at the top of `__tmux_lives_cap_apply_live` (line 804); themed branch in `__tmux_lives_color_cmd`'s `--apply` path (lines 713-720); `case theme` in `__tmux_lives_setup_dispatch` (after `case cap`, line 1045-1046); a `theme` row in `__tmux_lives_setup_help_lines` (after the `cap` row, line 1022)
- Test: `tests/test-tmux-install.fish` (extend the theme section)

**Interfaces:**
- Consumes: Tasks 1-4 (`__tmux_lives_theme_palette`, `__tmux_lives_theme_lrange`, `__tmux_lives_seed_hex`, `__tmux_lives_write_fragment`), existing `__tmux_lives_derive_status`/`_bg`, `__tmux_lives_cap_apply_live`, `__tmux_lives_key`.
- Produces: `tmux-lives setup theme [<scheme>|list|off] [--phase <deg>] [--vividness soft|balanced|vivid] [--shape arc|flat] [--ease linear|cubic] [--range <L0,L1>]`. `__tmux_lives_theme_push <opt> <val…>` (socket-seam tmux set). `__tmux_lives_theme_apply_live` (pushes theme values, or restores v2 values + `default` seeds when off). While a theme is active, `__tmux_lives_cap_apply_live` is a no-op and `setup color --apply` re-applies the THEME style.

- [ ] **Step 1: Write the failing tests** — append to the theme section of `tests/test-tmux-install.fish`:

```fish
# --- theme engine v3: CLI + live apply ---------------------------------------
# Save/clear EVERY universal this section touches at the TOP (the cap_role lesson:
# the CLI reads them on every apply — a user's live value would skew earlier asserts).
set -g _th_names tmux_lives_theme tmux_lives_theme_phase tmux_lives_theme_vividness tmux_lives_theme_shape tmux_lives_theme_ease tmux_lives_theme_range tmux_lives_bar_color tmux_lives_status_invert
set -g _th_had
set -g _th_saved
for n in $_th_names
    if set -q $n
        set -a _th_had 1
        set -a _th_saved "$$n"
    else
        set -a _th_had 0
        set -a _th_saved ""
    end
    set -e $n
end

# dispatcher routes + help row
functions -c __tmux_lives_theme_cmd __thc_bak
function __tmux_lives_theme_cmd; echo THEME:$argv; end
t "setup dispatch routes theme" "THEME:warm x" (__tmux_lives_setup_dispatch theme warm x)
functions -e __tmux_lives_theme_cmd; functions -c __thc_bak __tmux_lives_theme_cmd; functions -e __thc_bak
t "setup help lists theme" yes (string match -q '*theme*gradient-map*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)

functions -c __tmux_lives_write_fragment __wfth_bak
function __tmux_lives_write_fragment; end

# no-arg shows state; validation refuses before mutating
t "theme no-arg reports off" yes (string match -q '*theme: (off*' -- (__tmux_lives_theme_cmd | string collect); and echo yes; or echo no)
set -U tmux_lives_bar_color '#485b3c'
t "theme: invalid scheme rejected" 1 (__tmux_lives_theme_cmd wat 2>/dev/null; echo $status)
t "theme: invalid scheme leaves the universal unset" 0 (set -q tmux_lives_theme; and echo 1; or echo 0)
t "theme: invalid phase rejected" 1 (__tmux_lives_theme_cmd warm --phase x 2>/dev/null; echo $status)
t "theme: invalid phase mutates nothing" 0 (set -q tmux_lives_theme; and echo 1; or echo 0)
t "theme: invalid vividness rejected" 1 (__tmux_lives_theme_cmd --vividness max 2>/dev/null; echo $status)
t "theme: invalid shape rejected" 1 (__tmux_lives_theme_cmd --shape round 2>/dev/null; echo $status)
t "theme: invalid ease rejected" 1 (__tmux_lives_theme_cmd --ease bounce 2>/dev/null; echo $status)
t "theme: inverted range rejected" 1 (__tmux_lives_theme_cmd --range 0.9,0.2 2>/dev/null; echo $status)
set -e tmux_lives_bar_color
t "theme: a scheme without a seed refuses" 1 (__tmux_lives_theme_cmd warm 2>/dev/null; echo $status)
set -U tmux_lives_bar_color '#485b3c'

# list renders 10 schemes with 7-cell strips
t "theme list has 10 rows" 10 (count (__tmux_lives_theme_list))
t "theme list rows carry truecolor swatches" 10 (count (string match -r '48;2;' (__tmux_lives_theme_list)))

# live apply on the -L seam
set -g _th_fcd $__fish_config_dir
set -g __fish_config_dir /tmp/th-noconf-$fish_pid
set -g thsock tlt-$fish_pid
command tmux -L $thsock new-session -d 2>/dev/null
set -gx tmux_lives_tmux_socket $thsock
__tmux_lives_theme_cmd warm --phase 30 --vividness vivid >/dev/null
set -g THP (__tmux_lives_theme_palette '#485b3c' warm 30 vivid 0.20 0.92 arc linear)
t "theme cmd persists scheme" warm "$tmux_lives_theme"
t "theme cmd persists phase" 30 "$tmux_lives_theme_phase"
t "theme cmd persists vividness" vivid "$tmux_lives_theme_vividness"
t "theme live-applies cap_bg" "$THP[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "theme live-applies text_fg" "$THP[7]" (command tmux -L $thsock show -gv @tmux_lives_text_fg 2>/dev/null)
t "theme live-applies mark_fg" "$THP[6]" (command tmux -L $thsock show -gv @tmux_lives_mark_fg 2>/dev/null)
t "theme live-applies status-style" "bg=$THP[1],fg=$THP[5]" (command tmux -L $thsock show -gv status-style 2>/dev/null)
# v2 cap writes are inert while the theme owns the bar
__tmux_lives_cap_apply_live
t "cap apply is a no-op under a theme" "$THP[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
# setup color --apply re-applies the THEME, not the v2 derive
command tmux -L $thsock set -g status-style bg=red 2>/dev/null
__tmux_lives_color_cmd --apply >/dev/null
t "color --apply routes through the theme" "bg=$THP[1],fg=$THP[5]" (command tmux -L $thsock show -gv status-style 2>/dev/null)
# a lone knob call re-applies too
__tmux_lives_theme_cmd --phase 90 >/dev/null
set -g THP90 (__tmux_lives_theme_palette '#485b3c' warm 90 vivid 0.20 0.92 arc linear)
t "lone knob re-applies live" "$THP90[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
# off: v2 values return, role seeds neutralize, cap writes work again
__tmux_lives_theme_cmd off >/dev/null
t "off clears the universal" 0 (set -q tmux_lives_theme; and echo 1; or echo 0)
t "off restores the v2 status-style" (__tmux_lives_derive_status '#485b3c' 0) (command tmux -L $thsock show -gv status-style 2>/dev/null)
t "off resets text_fg to default" default (command tmux -L $thsock show -gv @tmux_lives_text_fg 2>/dev/null)
set -g THV2 (__tmux_lives_palette (__tmux_lives_derive_status_bg '#485b3c' 0) mono ryb vivid)
t "off hands the cap back to v2" "$THV2[4]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
command tmux -L $thsock kill-server 2>/dev/null
set -e tmux_lives_tmux_socket
set -g __fish_config_dir $_th_fcd

functions -e __tmux_lives_write_fragment; functions -c __wfth_bak __tmux_lives_write_fragment; functions -e __wfth_bak
# restore the saved universals (bottom of the section — the socket seam is unpinned by now)
for i in (seq (count $_th_names))
    set -e $_th_names[$i]
    test $_th_had[$i] -eq 1; and set -U $_th_names[$i] $_th_saved[$i]
end
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -40`
Expected: FAILs across the CLI section (`__tmux_lives_theme_cmd` undefined — the `functions -c` copy at the top errors too; that's fine, it passes once the function exists).

- [ ] **Step 3: Implement.** Insert after `__tmux_lives_cap_cmd`'s `end` (line 917):

```fish
# --- theme engine v3: user surface -------------------------------------------
function __tmux_lives_theme_valid --argument-names token --description 'true if token is a v3 gradient-map scheme'
    switch "$token"
        case mono warm cool span wide aurora sunset fire complement full
            return 0
    end
    return 1
end

function __tmux_lives_theme_push --description 'internal: tmux set -g <option> <value> honoring the tmux_lives_tmux_socket test seam'
    if set -q tmux_lives_tmux_socket
        command tmux -L $tmux_lives_tmux_socket set -g $argv 2>/dev/null
    else
        tmux set -g $argv 2>/dev/null
    end
end

function __tmux_lives_theme_apply_live --description 'internal: push the effective v3 theme (or the v2 values when the theme is off) to the live server'
    set -l theme (__tmux_lives_key tmux_lives_theme '')
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    set -l tpal
    if test -n "$theme"; and test -n "$seed"
        set -l tl (__tmux_lives_theme_lrange (__tmux_lives_key tmux_lives_theme_range 0.20,0.92))
        set tpal (__tmux_lives_theme_palette $seed "$theme" (__tmux_lives_key tmux_lives_theme_phase 0) (__tmux_lives_key tmux_lives_theme_vividness balanced) $tl[1] $tl[2] (__tmux_lives_key tmux_lives_theme_shape arc) (__tmux_lives_key tmux_lives_theme_ease linear))
    end
    if test (count $tpal) -eq 7
        __tmux_lives_theme_push status-style "bg=$tpal[1],fg=$tpal[5]"
        __tmux_lives_theme_push @tmux_lives_bar_bg $tpal[1]
        __tmux_lives_theme_push @tmux_lives_sep_fg $tpal[2]
        __tmux_lives_theme_push @tmux_lives_tabs_color $tpal[3]
        __tmux_lives_theme_push @tmux_lives_active_fg $tpal[4]
        __tmux_lives_theme_push @tmux_lives_cap_bg $tpal[6]
        __tmux_lives_theme_push @tmux_lives_cap_fg (__tmux_lives_contrast_fg $tpal[6])
        __tmux_lives_theme_push @tmux_lives_mark_fg $tpal[6]
        __tmux_lives_theme_push @tmux_lives_text_fg $tpal[7]
        return 0
    end
    # theme off (or no usable seed): restore the v2 values + neutral role seeds
    set -l ss (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0))
    test -n "$ss"; and __tmux_lives_theme_push status-style $ss
    set -l barbg (__tmux_lives_derive_status_bg (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0))
    test -n "$barbg"; or set barbg colour236
    __tmux_lives_theme_push @tmux_lives_bar_bg $barbg
    __tmux_lives_theme_push @tmux_lives_sep_fg default
    __tmux_lives_theme_push @tmux_lives_tabs_color ''
    __tmux_lives_theme_push @tmux_lives_active_fg default
    __tmux_lives_theme_push @tmux_lives_mark_fg default
    __tmux_lives_theme_push @tmux_lives_text_fg default
    __tmux_lives_cap_apply_live
end

function __tmux_lives_theme_list --description 'tmux-lives setup theme list: every scheme + a 7-role gradient strip at the current seed/knobs'
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    test -n "$seed"; or set seed '#3a3a3a'   # no seed configured yet -> neutral so strips still render
    set -l tl (__tmux_lives_theme_lrange (__tmux_lives_key tmux_lives_theme_range 0.20,0.92))
    set -l phase (__tmux_lives_key tmux_lives_theme_phase 0)
    set -l viv (__tmux_lives_key tmux_lives_theme_vividness balanced)
    set -l shape (__tmux_lives_key tmux_lives_theme_shape arc)
    set -l ease (__tmux_lives_key tmux_lives_theme_ease linear)
    for scheme in mono warm cool span wide aurora sunset fire complement full
        set -l pal (__tmux_lives_theme_palette $seed $scheme $phase $viv $tl[1] $tl[2] $shape $ease)
        test (count $pal) -eq 7; or continue
        set -l strip
        for hex in $pal
            set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $hex)
            test (count $m) -eq 3; or continue
            set -a strip (printf '\e[48;2;%d;%d;%dm  \e[0m' (math "0x$m[1]") (math "0x$m[2]") (math "0x$m[3]"))
        end
        printf '%s %-11s %s\n' (string join '' $strip) $scheme $pal[6]
    end
end

function __tmux_lives_theme_cmd --description 'tmux-lives setup theme [<scheme>|list|off] [--phase <deg>] [--vividness soft|balanced|vivid] [--shape arc|flat] [--ease linear|cubic] [--range <L0,L1>]: the v3 gradient-map bar theme'
    if test (count $argv) -eq 0
        set -l cur (__tmux_lives_key tmux_lives_theme '')
        test -n "$cur"; and echo "theme: $cur"; or echo "theme: (off — v2 cap colors active)"
        set -l tphase (__tmux_lives_key tmux_lives_theme_phase 0)
        set -l tviv (__tmux_lives_key tmux_lives_theme_vividness balanced)
        set -l tshape (__tmux_lives_key tmux_lives_theme_shape arc)
        set -l tease (__tmux_lives_key tmux_lives_theme_ease linear)
        set -l trange (__tmux_lives_key tmux_lives_theme_range 0.20,0.92)
        echo "  phase: $tphase   vividness: $tviv   shape: $tshape   ease: $tease   range: $trange"
        return 0
    end
    set -l scheme; set -l have_scheme 0
    set -l phase; set -l have_phase 0
    set -l viv; set -l have_viv 0
    set -l shape; set -l have_shape 0
    set -l ease; set -l have_ease 0
    set -l range; set -l have_range 0
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case list
                __tmux_lives_theme_list
                return
            case off
                set -e tmux_lives_theme
                __tmux_lives_write_fragment
                __tmux_lives_theme_apply_live
                echo "tmux-lives: theme off — v2 cap colors are back in charge"
                return 0
            case --phase
                set i (math $i + 1); set phase $argv[$i]; set have_phase 1
            case --vividness
                set i (math $i + 1); set viv $argv[$i]; set have_viv 1
            case --shape
                set i (math $i + 1); set shape $argv[$i]; set have_shape 1
            case --ease
                set i (math $i + 1); set ease $argv[$i]; set have_ease 1
            case --range
                set i (math $i + 1); set range $argv[$i]; set have_range 1
            case '*'
                set scheme $argv[$i]; set have_scheme 1
        end
        set i (math $i + 1)
    end
    # Validate everything before mutating any state (same contract as setup cap).
    if test $have_scheme -eq 1; and not __tmux_lives_theme_valid "$scheme"
        echo "tmux-lives setup theme: invalid scheme '$scheme' — valid: mono, warm, cool, span, wide, aurora, sunset, fire, complement, full (or: list, off)" >&2
        return 1
    end
    if test $have_phase -eq 1; and not string match -qr -- '^-?[0-9]+$' "$phase"
        echo "tmux-lives setup theme: invalid phase '$phase' — whole degrees, e.g. --phase -30" >&2
        return 1
    end
    if test $have_viv -eq 1
        switch "$viv"
            case soft balanced vivid
            case '*'
                echo "tmux-lives setup theme: invalid vividness '$viv' — valid: soft, balanced, vivid" >&2
                return 1
        end
    end
    if test $have_shape -eq 1
        switch "$shape"
            case arc flat
            case '*'
                echo "tmux-lives setup theme: invalid shape '$shape' — valid: arc, flat" >&2
                return 1
        end
    end
    if test $have_ease -eq 1
        switch "$ease"
            case linear cubic
            case '*'
                echo "tmux-lives setup theme: invalid ease '$ease' — valid: linear, cubic" >&2
                return 1
        end
    end
    if test $have_range -eq 1
        set -l rr (string split , -- "$range")
        set -l rok 0
        if test (count $rr) -eq 2
            and string match -qr '^(0(\.[0-9]+)?|1(\.0+)?)$' -- $rr[1]
            and string match -qr '^(0(\.[0-9]+)?|1(\.0+)?)$' -- $rr[2]
            and test $rr[1] -lt $rr[2]
            set rok 1
        end
        if test $rok -eq 0
            echo "tmux-lives setup theme: invalid range '$range' — L0,L1 in [0,1] with L0 < L1, e.g. --range 0.20,0.92" >&2
            return 1
        end
    end
    if test $have_scheme -eq 1
        set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
        if test -z "$seed"
            echo "tmux-lives setup theme: no seed color — set one first: tmux-lives setup color '#rrggbb' (hex or rgb(); named colors have no derivable hue)" >&2
            return 1
        end
    end
    test $have_phase -eq 1; and set -U tmux_lives_theme_phase $phase
    test $have_viv -eq 1; and set -U tmux_lives_theme_vividness $viv
    test $have_shape -eq 1; and set -U tmux_lives_theme_shape $shape
    test $have_ease -eq 1; and set -U tmux_lives_theme_ease $ease
    test $have_range -eq 1; and set -U tmux_lives_theme_range $range
    test $have_scheme -eq 1; and set -U tmux_lives_theme $scheme
    # Persist into the fragment AND apply live (no reattach): write_fragment re-renders +
    # reloads; apply_live covers a server the reload can't reach (and the test seam).
    __tmux_lives_write_fragment
    __tmux_lives_theme_apply_live
    test $have_scheme -eq 1; and echo "tmux-lives: theme set to $scheme"
    test $have_phase -eq 1; and echo "tmux-lives: theme phase set to $phase"
    test $have_viv -eq 1; and echo "tmux-lives: theme vividness set to $viv"
    test $have_shape -eq 1; and echo "tmux-lives: theme shape set to $shape"
    test $have_ease -eq 1; and echo "tmux-lives: theme ease set to $ease"
    test $have_range -eq 1; and echo "tmux-lives: theme range set to $range"
end
```

Guard at the TOP of `__tmux_lives_cap_apply_live` (first lines of the body, line 805):

```fish
    # v3 theme owns the whole bar while active — a v2 cap write must not clobber it.
    set -l _theme (__tmux_lives_key tmux_lives_theme '')
    test -n "$_theme"; and return 0
```

In `__tmux_lives_color_cmd`'s `--apply` path, replace the `set -l ss …` block (lines 713-720) with:

```fish
        set -l _theme (__tmux_lives_key tmux_lives_theme '')
        if test -n "$_theme"
            __tmux_lives_theme_apply_live
        else
            set -l ss (__tmux_lives_derive_status $c (__tmux_lives_key tmux_lives_status_invert 0))
            if test -n "$ss"
                if set -q tmux_lives_tmux_socket
                    command tmux -L $tmux_lives_tmux_socket set -g status-style $ss 2>/dev/null
                else
                    tmux set -g status-style $ss 2>/dev/null
                end
            end
        end
```

In `__tmux_lives_setup_dispatch`, after `case cap` (lines 1045-1046) add:

```fish
        case theme
            __tmux_lives_theme_cmd $argv[2..]
```

In `__tmux_lives_setup_help_lines`, after the `cap` row (line 1022) add:

```fish
        'theme [<scheme>|list|off]   gradient-map bar theme; --phase/--vividness/…' \
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -5` — expect ALL PASS.

- [ ] **Step 5: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — 8× ALL PASS. Also eyeball `set | grep tmux_lives_theme` afterward — the section must leave NO theme universals behind (the restore loop ran).

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): setup theme CLI — scheme/list/off + knobs, live apply, v2 coexistence guards"
```

---

### Task 6: Docs

**Files:**
- Modify: `README.md` (add a Theming subsection near the `setup color`/`setup cap` docs), `CLAUDE.md` (update the v3 forward-pointer paragraph: Phase 1 built on this branch)

**Interfaces:** none — documentation only.

- [ ] **Step 1: README.** Add under the setup/color documentation:

```markdown
### Theming (v3 gradient map — Phase 1)

`tmux-lives setup theme <scheme>` themes the whole tmux status bar from your seed
colour (`setup color`): seven UI roles (bar · separators · tabs · active · windows ·
cap · text), each pinned at a lightness, sample one hue-arc gradient derived from the
seed — cohesive by construction. The v2 cap engine keeps working until you opt in.

    tmux-lives setup theme list          # preview every scheme as a 7-swatch strip
    tmux-lives setup theme warm          # theme the bar (needs a seed: setup color '#485b3c')
    tmux-lives setup theme --phase 30    # rotate which hue lands on which element
    tmux-lives setup theme off           # back to the v2 cap colors

Schemes: `mono` (calm default) · `warm` · `cool` · `span` · `wide` · `aurora` ·
`sunset` · `fire` · `complement` · `full`. Knobs: `--vividness soft|balanced|vivid`,
`--shape arc|flat`, `--ease linear|cubic`, `--range L0,L1`. Every role is a live
`@option` (`@tmux_lives_sep_fg`, `@tmux_lives_text_fg`, …) — retune with
`tmux set -g @tmux_lives_… '#hex'`, no re-render. ShellFish tab colour + the picker
move to the gradient map in Phases 2-3.
```

- [ ] **Step 2: CLAUDE.md.** In the v3 paragraph (search `SUPERSEDED — v3 gradient-map redesign APPROVED, NOT BUILT`), change the status to note: Phase 1 (engine + tmux bar) BUILT on `feat/theme-gradient-map` — sampler/roles/palette install-side, fragment argv 17-22, `setup theme` CLI, opt-in via `tmux_lives_theme` (v2 untouched while off), coexistence guards in `cap_apply_live`/`color --apply`; Phases 2-4 (ShellFish/rename/migration, picker, harmonize) still pending. Keep it to a few sentences appended to the existing paragraph.

- [ ] **Step 3: Full suite + commit**

Run: `for t in tests/test-*.fish; fish $t; end` — 8× ALL PASS (docs must not break the generic leakage suite: no absolute home paths in examples).

```bash
git add README.md CLAUDE.md
git commit -m "docs(theme): README theming section + CLAUDE.md v3 Phase-1 status"
```

---

## Verification (whole branch, before merge)

- `for t in tests/test-*.fish; fish $t; end` → 8× ALL PASS.
- `fish -c 'source conf.d/tmux-lives-install.fish; set -U tmux_lives_bar_color "#485b3c"; __tmux_lives_theme_list'` renders 10 gradient strips (visual sanity of the arcs; then `set -e tmux_lives_bar_color` if it wasn't set before).
- Confirm no live mutation: `tmux show -gv @tmux_lives_text_fg` on the REAL server must error/return nothing new, and `~/.config/tmux/tmux-lives.conf` must be untouched (`git`-independent check: mtime).
- Runtime-only smoke (deferred to the user after `fisher update`, list in the handoff): `setup theme warm` on the live bar, role `@option` retunes, `theme off` restoring the v2 look, light-seed inversion on a real light seed.

## Explicitly out of scope (Phase 2-4 — do NOT build here)

ShellFish `tabs`-role OSC (`setup color` stays the raw-seed emitter), `cap`→`theme` rename + migration shim, removing `cap_role`/`__tcz_cap_inert`/geometric schemes, picker changes (`M-k`/`M-m k` still open the v2 cap-picker), harmonized mode indicators, per-hue lightness nudge.
