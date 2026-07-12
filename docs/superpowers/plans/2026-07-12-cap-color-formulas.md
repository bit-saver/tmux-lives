# Cap-color formulas — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Let the powerline cap ("secondary") color be generated from the bar ("primary") by a chosen color-theory formula (mono/analogous/complementary/split/triadic), pickable from a swatch popup or a `setup cap` CLI, stored in universal `tmux_lives_cap`.

**Architecture:** Pure fish HSL derivation (`__tmux_lives_cap_hue`, `__tmux_lives_cap_from_formula`, `__tmux_lives_contrast_fg`) in `conf.d/tmux-lives-install.fish` next to `__tmux_lives_derive_cap_bg`. The fragment reads `tmux_lives_cap` (new render argv[12]) and seeds `@tmux_lives_cap_bg`/`@tmux_lives_cap_fg` from it. A `setup cap` command + a `cap-picker` popup (categorizer) are the two selection surfaces, both writing `tmux_lives_cap` and applying live.

**Tech Stack:** fish (`math` for HSL); tmux 3.3a; existing `-L`-socket + stub harnesses; reuse the switcher popup (`__tcz_popup*`).

## Global Constraints

- fish; tmux 3.3a; no new deps.
- Front-facing name is **`cap`** (command `setup cap`, universal `tmux_lives_cap`); internal derived options stay `@tmux_lives_cap_bg`/`@tmux_lives_cap_fg`.
- **Tokens:** `mono` (default), `complementary`, `analogous+`/`analogous-`, `split+`/`split-`, `triadic+`/`triadic-`, or a literal `#rrggbb`. Unknown/empty → `mono`.
- **`mono` = the CURRENT `__tmux_lives_derive_cap_bg`, unchanged** (adaptive brightness shade). Only the hue families are new.
- **HSL formula** (hue families): RGB→HSL, `H'=(H+deg) mod 360`, `S'=max(S,0.22)`, `L'` = `L + (1-L)*0.28` if `L<0.5` else `L*0.72`, HSL→RGB. Match Python `colorsys` (reference hexes below). **If fish rounds a channel ±1 vs the reference, lock the fish value** (a pure function's own output is the truth) and note it.
- Colors emitted into tmux/fragment are **single-quoted** (`#hex` unquoted = tmux comment).
- Isolation: `-L` sockets / stubs only; run `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`.
- Do NOT deploy. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

**Reference values** (bar `#36442d` unless noted; from `colorsys`):
`cap_hue 180=#755789 · +30=#57895d · -30=#838957 · +150=#5d5789 · +210=#895783 · +120=#576b89 · -120=#89576b`. `mono #36442d→#687362`. `contrast_fg #755789→#f4f7f4 (dark→light), #e0e0e0→#1c1c1c (light→dark), #36442d→#f4f7f4`.

---

## Task 1: pure HSL derivation (`__tmux_lives_cap_hue`, `_from_formula`, `_contrast_fg`)

**Files:** Modify `conf.d/tmux-lives-install.fish` (after `__tmux_lives_derive_cap_bg`); Test `tests/test-tmux-install.fish`.

**Interfaces:** `__tmux_lives_cap_hue <#rrggbb> <deg>` → `#rrggbb` (hue-rotated + adaptive lightness). `__tmux_lives_cap_from_formula <bar#hex> <token>` → `#rrggbb` (routes literal-hex / `mono`→`derive_cap_bg` / hue families). `__tmux_lives_contrast_fg <#hex>` → `#f4f7f4` or `#1c1c1c` by luminance.

- [ ] **Step 1 — failing tests** (add near the `derive_cap_bg` tests):
```fish
t "cap_hue complementary" "#755789" (__tmux_lives_cap_hue "#36442d" 180)
t "cap_hue analogous+"    "#57895d" (__tmux_lives_cap_hue "#36442d" 30)
t "cap_hue triadic-"      "#89576b" (__tmux_lives_cap_hue "#36442d" -120)
t "cap_from_formula mono == derive_cap_bg" (__tmux_lives_derive_cap_bg "#36442d") (__tmux_lives_cap_from_formula "#36442d" mono)
t "cap_from_formula complementary" "#755789" (__tmux_lives_cap_from_formula "#36442d" complementary)
t "cap_from_formula analogous- token" "#838957" (__tmux_lives_cap_from_formula "#36442d" analogous-)
t "cap_from_formula literal hex passthrough" "#123456" (__tmux_lives_cap_from_formula "#36442d" "#123456")
t "cap_from_formula unknown -> mono" (__tmux_lives_derive_cap_bg "#36442d") (__tmux_lives_cap_from_formula "#36442d" wat)
t "contrast_fg dark cap -> light" "#f4f7f4" (__tmux_lives_contrast_fg "#755789")
t "contrast_fg light cap -> dark" "#1c1c1c" (__tmux_lives_contrast_fg "#e0e0e0")
```

- [ ] **Step 2 — run, verify FAIL** (`fish tests/test-tmux-install.fish` → `SOME FAILED`).

- [ ] **Step 3 — implement** (add to `conf.d/tmux-lives-install.fish`). Parse `#rrggbb` like `derive_status`. HSL per `colorsys`:
```fish
function __tmux_lives_contrast_fg --argument-names hex --description 'cap bg hex -> readable fg: light on a dark cap, dark on a light cap'
    set -l m (string match -rg '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$' -- (string lower -- $hex))
    test (count $m) -eq 3; or begin; echo '#f4f7f4'; return; end
    set -l L (math "round(0.299*0x$m[1] + 0.587*0x$m[2] + 0.114*0x$m[3])")
    test $L -lt 140; and echo '#f4f7f4'; or echo '#1c1c1c'
end

function __tmux_lives_cap_hue --argument-names hex deg --description 'bar #rrggbb + hue degrees -> cap #rrggbb (HSL rotate + adaptive lightness; colorsys algorithm)'
    set -l m (string match -rg '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$' -- (string lower -- $hex))
    test (count $m) -eq 3; or return 0
    set -l r (math "0x$m[1]/255"); set -l g (math "0x$m[2]/255"); set -l b (math "0x$m[3]/255")
    set -l mx (math "max($r,$g,$b)"); set -l mn (math "min($r,$g,$b)")
    set -l L (math "($mx+$mn)/2")
    set -l H 0; set -l S 0
    if test (math "$mx - $mn") != 0
        if test (math "$L <= 0.5") -eq 1
            set S (math "($mx-$mn)/($mx+$mn)")
        else
            set S (math "($mx-$mn)/(2-$mx-$mn)")
        end
        set -l rc (math "($mx-$r)/($mx-$mn)"); set -l gc (math "($mx-$g)/($mx-$mn)"); set -l bc (math "($mx-$b)/($mx-$mn)")
        if test "$r" = "$mx"
            set H (math "$bc-$gc")
        else if test "$g" = "$mx"
            set H (math "2+$rc-$bc")
        else
            set H (math "4+$gc-$rc")
        end
        set H (math "($H/6) % 1"); test (math "$H < 0") -eq 1; and set H (math "$H+1")
    end
    # rotate + floor S + adaptive L
    set H (math "($H + $deg/360) % 1"); test (math "$H < 0") -eq 1; and set H (math "$H+1")
    set S (math "max($S,0.22)")
    if test (math "$L < 0.5") -eq 1
        set L (math "$L+(1-$L)*0.28")
    else
        set L (math "$L*0.72")
    end
    # HSL -> RGB
    set -l m2; if test (math "$L <= 0.5") -eq 1; set m2 (math "$L*(1+$S)"); else; set m2 (math "$L+$S-$L*$S"); end
    set -l m1 (math "2*$L-$m2")
    printf '#%02x%02x%02x' (__tmux_lives_hue2rgb $m1 $m2 (math "$H+1/3")) (__tmux_lives_hue2rgb $m1 $m2 $H) (__tmux_lives_hue2rgb $m1 $m2 (math "$H-1/3"))
end

function __tmux_lives_hue2rgb --argument-names m1 m2 h --description 'colorsys _v helper -> 0-255 channel'
    set h (math "$h % 1"); test (math "$h < 0") -eq 1; and set h (math "$h+1")
    set -l v $m1
    if test (math "$h < 1/6") -eq 1
        set v (math "$m1+($m2-$m1)*$h*6")
    else if test (math "$h < 0.5") -eq 1
        set v $m2
    else if test (math "$h < 2/3") -eq 1
        set v (math "$m1+($m2-$m1)*(2/3-$h)*6")
    end
    math "round($v*255)"
end

function __tmux_lives_cap_from_formula --argument-names hex token --description 'bar #rrggbb + cap token -> cap #rrggbb (literal-hex | mono->derive_cap_bg | hue family)'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$token"; and begin; echo (string lower -- $token); return; end
    switch "$token"
        case complementary; __tmux_lives_cap_hue $hex 180
        case analogous+; __tmux_lives_cap_hue $hex 30
        case analogous-; __tmux_lives_cap_hue $hex -30
        case split+; __tmux_lives_cap_hue $hex 150
        case split-; __tmux_lives_cap_hue $hex 210
        case triadic+; __tmux_lives_cap_hue $hex 120
        case triadic-; __tmux_lives_cap_hue $hex -120
        case '*'; __tmux_lives_derive_cap_bg $hex   # mono + unknown fallback
    end
end
```
(NB: `math` supports `max`/`min`/`%`. If a `cap_hue` reference channel differs ±1, lock the fish value and note it — deterministic pure fn.)

- [ ] **Step 4 — run, verify PASS**; then full suite `for t in tests/test-*.fish; fish $t; end` (8× ALL PASS).
- [ ] **Step 5 — commit** (`feat(cap): pure HSL cap-color formulas (hue rotation + contrast fg)`).

---

## Task 2: fragment integration (derive cap from `tmux_lives_cap`)

**Files:** Modify `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment`: read argv[12], derive cap_bg via formula + cap_fg via contrast; call site ~line 198); Test `tests/test-tmux-install.fish`.

**Interfaces:** Consumes Task 1. `__tmux_lives_render_fragment` argv[12] = `cap` token.

- [ ] **Step 1 — failing tests** (mirror the existing cap_bg fragment test; note the current fixed `@tmux_lives_cap_fg colour231` becomes derived):
```fish
# formula-driven cap: bar #1f6feb -> bar_bg #5793f0; complementary -> cap_hue(#5793f0,180)
set -g FC (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block complementary | string collect)
t "fragment cap_bg from formula" yes (string match -q "*set -g @tmux_lives_cap_bg '"(__tmux_lives_cap_from_formula "#5793f0" complementary)"'*" -- "$FC"; and echo yes; or echo no)
t "fragment cap_fg auto-derived (not fixed colour231)" yes (string match -q "*set -g @tmux_lives_cap_fg '"(__tmux_lives_contrast_fg (__tmux_lives_cap_from_formula "#5793f0" complementary))"'*" -- "$FC"; and echo yes; or echo no)
# default mono keeps the current shade
set -g FM (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono | string collect)
t "fragment mono cap_bg == derive_cap_bg" yes (string match -q "*@tmux_lives_cap_bg '#81aef4'*" -- "$FM"; and echo yes; or echo no)
```
(Update the existing `real: cap bg option stored non-empty hex` / `fragment cap bg is the adaptive shade` tests: with no arg-12 they default `mono` → still `#81aef4`; keep those green, add the `cap-*` argv12.)

- [ ] **Step 2 — run, verify FAIL.**
- [ ] **Step 3 — implement:** add `set -l cap $argv[12]` to `__tmux_lives_render_fragment`'s arg block; replace the cap_bg computation:
```fish
    set -l capbg (__tmux_lives_cap_from_formula $barbg $cap)
    test -n "$capbg"; or set capbg colour238
    ...
    set -a f "set -g @tmux_lives_cap_bg '$capbg'"
    set -a f "set -g @tmux_lives_cap_fg '"(__tmux_lives_contrast_fg $capbg)"'"   # replaces the fixed colour231 line
```
Add `(__tmux_lives_key tmux_lives_cap mono)` as the 12th arg at the render call site (~line 198). Remove the old `@tmux_lives_cap_fg colour231` seed line.
- [ ] **Step 4 — run PASS + full suite.**  **Step 5 — commit.**

---

## Task 3: `setup cap` CLI (`<token>` | `list` | no-arg picker)

**Files:** Modify `conf.d/tmux-lives-install.fish` (new `__tmux_lives_cap_cmd`; wire into the `setup` dispatch next to `color`); Test `tests/test-tmux-install.fish`.

**Interfaces:** `tmux-lives setup cap <token>` → validate, `set -U tmux_lives_cap <token>`, apply live (`@tmux_lives_cap_bg`/`_fg` on the `tmux_lives_tmux_socket` seam, like `setup color --apply`). `setup cap list` → tokens + ANSI truecolor swatch each (from the current bar). `setup cap` (no arg) → `tmux display-popup … cap-picker` (Task 4).

- [ ] **Step 1 — failing tests** (pin the live-set to a `-L` socket via `tmux_lives_tmux_socket`, mirror the `color --apply` tests): `setup cap complementary` sets `tmux_lives_cap` and writes `@tmux_lives_cap_bg`=cap_from_formula(barbg,complementary) live; `setup cap list` output contains each token name + a `\e[48;2;` truecolor swatch; an invalid token errors non-zero without setting the universal.
- [ ] **Step 2 — FAIL.**  **Step 3 — implement** `__tmux_lives_cap_cmd` (token whitelist incl. `#hex`; read the live bar via the derived status-style bg or `tmux_lives_bar_color`; ANSI `\e[48;2;R;G;Bm  \e[0m` swatch). Wire `case cap` into the setup verb dispatch. **Step 4 — PASS + suite.**  **Step 5 — commit.**

---

## Task 4: `cap-picker` popup (swatches + direction flip)

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_cap_families`, `__tcz_cap_flip`, `__tcz_cap_swatch_line`, `__tcz_cap_picker`; verb `cap-picker` in `__tcz_main`); optional keybind seam; Test `tests/test-tmux-categorize.fish`.

**Interfaces (pure, testable):** `__tcz_cap_families` → ordered token list (`mono complementary analogous+ split+ triadic+` — the `+` families are the shown default; flip toggles to `-`). `__tcz_cap_flip <token>` → toggles `+`↔`-` (no-op for `mono`/`complementary`). `__tcz_cap_swatch_line <bar#hex> <token> <selected0/1>` → a styled row string (marker + name + truecolor swatch of `cap_from_formula`). `__tcz_cap_picker <client>` → the interactive popup (reuse `__tcz_popup`'s raw-key readkey/draw/scroll loop): ↑↓/jk move, ←→/hl flip direction on the highlighted row (redraw), Enter apply (= `setup cap <token>` path), Esc/q cancel.

- [ ] **Step 1 — failing tests** (pure helpers only; the raw-tty loop is manual-smoke like the switcher): `__tcz_cap_families` returns the 5 families in order; `__tcz_cap_flip analogous+` → `analogous-`, `__tcz_cap_flip mono` → `mono`; `__tcz_cap_swatch_line "#36442d" complementary 1` contains the selected marker + `#755789` (or its truecolor bg) + "complementary".
- [ ] **Step 2 — FAIL.**  **Step 3 — implement** the pure helpers + `__tcz_cap_picker` (mirror `__tcz_open_switcher`/`__tcz_popup`), add `case cap-picker` to `__tcz_main`. `setup cap` no-arg (Task 3) launches it via `display-popup -E "fish --no-config $cat cap-picker '#{client_name}'"`. **Step 4 — PASS + full suite.**  **Step 5 — commit.**

- [ ] **Manual smoke (runtime, after `tl update`):** picker opens with live swatches; ↑↓ moves; ←→ flips direction and the swatch updates; Enter applies (bar caps recolor live); `setup cap list` swatches; `setup cap triadic-` applies; a hue cap keeps readable text (contrast fg).

## Self-Review

Spec coverage: 5 formulas + tokens → Task 1 dispatcher; mono==current → Task 1 (`case '*'`→derive_cap_bg); HSL + contrast fg → Task 1; storage/integration → Task 2; CLI + list → Task 3; picker + flip + swatches → Task 4; literal-hex escape → Task 1. Testing/isolation throughout. Names consistent: `__tmux_lives_cap_hue`/`_from_formula`/`_contrast_fg`, `__tcz_cap_families`/`_flip`/`_swatch_line`/`_picker`, universal `tmux_lives_cap`, argv[12].
