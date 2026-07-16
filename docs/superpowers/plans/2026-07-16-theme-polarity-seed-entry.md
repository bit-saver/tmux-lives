# Theme Polarity + Seed-Entry UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the seed-brightness auto-inversion with an explicit `--polarity dark|light` knob (default dark, picker `d` toggle), and replace the picker's cooked seed `read` with a raw-mode hex editor showing a live swatch + extracted-hue readout.

**Architecture:** The palette gains a 9th explicit arg; every consumer (fragment argv 19, CLI, apply-live, list, picker) threads it. The picker's `b` sub-mode becomes a raw-tty line editor using a new byte-classifier (`__tcz_thp_readchar`), computing swatch/hue only at parse-complete via one install-side `fish -c`. Spec: `docs/superpowers/specs/2026-07-16-theme-polarity-seed-entry-design.md`.

**Tech Stack:** fish 4.7.1, tmux 3.3a; existing theme engine + picker (main @ 09d899c).

## Global Constraints

- Polarity: `dark`|`light`, `''`=dark everywhere; `light` swaps L endpoints; the `$ok[1] -ge 0.60` auto-inversion is DELETED (seed contributes hue only).
- Fragment argv map extends to **19 `themepolarity`**; nothing reads beyond 19.
- Info line format (locked): `<seed> · <%+d°> · <vividness> · <shape> · <ease> · <polarity>` — no `seed ` label; drawn WITHOUT the leading space so the 50-col worst case (`#ccff44 · +300° · balanced · flat · linear · light`) fits IW exactly.
- Seed entry: raw reads only (no `read -l` anywhere in the picker); `#` implied; Enter applies only 3/6-digit hex; hue/swatch computed once per parse-complete, never per keystroke; prompt copy contains "hue".
- fish gotchas as ever: no quoted math-index (grep-guard exists); capture+quote; `printf '%s\n'` multi-returns; NEVER interrupt a suite run (aborts leak real universals).
- Suite: `fish -c 'for t in tests/test-*.fish; fish $t; end'` — 8× ALL PASS before each commit.
- Line refs are vs main @ 09d899c; anchor by code.

---

### Task 1: Engine + CLI + fragment polarity

**Files:** Modify `conf.d/tmux-lives-install.fish` (`__tmux_lives_theme_palette`, `__tmux_lives_render_fragment` argv block + palette call, `__tmux_lives_write_fragment` call tail, `__tmux_lives_theme_apply_live`, `__tmux_lives_theme_list`, `__tmux_lives_theme_cmd` [state print, flag parse, validation, persist, echo], `__tmux_lives_setup_help_lines` theme block). Test: `tests/test-tmux-install.fish`.

**Interfaces — Produces:** `__tmux_lives_theme_palette <seedHex> <scheme> <phase> <vividness> <l0> <l1> <shape> <ease> [<polarity>]`; universal `tmux_lives_theme_polarity`; `setup theme --polarity dark|light`; fragment argv 19.

- [ ] **Step 1 (RED): tests.** In the theme sections of `tests/test-tmux-install.fish`:

(a) REPLACE the light-seed test (`t "light seed inverts the ramp" …` and its `TPALL` setup) with:

```fish
# polarity is explicit: a bright seed still ramps DARK by default; light swaps ends
set -g TPALL (__tmux_lives_theme_palette "#e8e0d0" mono 0 balanced 0.20 0.92 arc linear)
t "bright seed still ramps dark by default" 1 (test (_tl2 $TPALL[1]) -lt (_tl2 $TPALL[7]); and echo 1; or echo 0)
set -g TPLIGHT (__tmux_lives_theme_palette "#485b3c" mono 0 balanced 0.20 0.92 arc linear light)
t "polarity light inverts the ramp" 1 (test (_tl2 $TPLIGHT[1]) -gt (_tl2 $TPLIGHT[7]); and echo 1; or echo 0)
t "polarity dark == default" (string join ' ' (__tmux_lives_theme_palette "#485b3c" mono 0 balanced 0.20 0.92 arc linear dark)) (string join ' ' (__tmux_lives_theme_palette "#485b3c" mono 0 balanced 0.20 0.92 arc linear))
```

(NB `_tl2` is defined/erased around the existing block — keep the new tests inside that window, re-adding the helper if the block order forces it.)

(b) CLI (inside the `_th_names` guard — ADD `tmux_lives_theme_polarity` to `_th_names`):

```fish
t "theme: invalid polarity rejected" 1 (__tmux_lives_theme_cmd --polarity dim 2>/dev/null; echo $status)
__tmux_lives_theme_cmd --polarity light >/dev/null
t "theme cmd persists polarity" light "$tmux_lives_theme_polarity"
set -g THPL (__tmux_lives_theme_palette '#485b3c' warm 90 vivid 0.20 0.92 arc linear light)
t "polarity reaches apply-live" "$THPL[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
# reset to the default so the later default-dark assertions (off/mono) hold
set -e tmux_lives_theme_polarity
__tmux_lives_theme_apply_live
```

(place after the existing `lone knob re-applies live` assertion, while the socket seam is still pinned and theme=warm/phase=90/viv=vivid are in effect; note the expected palette mirrors those stored knobs). Also extend the no-arg state-print assertion (`'theme: mono*'` test's companion line check) with:

```fish
t "theme no-arg prints polarity" yes (string match -q '*polarity: dark*' -- (__tmux_lives_theme_cmd | string collect); and echo yes; or echo no)
```

(same TMUX-unset guard; `tmux_lives_theme_polarity` cleared by the section guard → default dark).

(c) Fragment:

```fish
set -g TPOL (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k warm '' '' '' '' '' light | string collect)
set -g TPOLPAL (__tmux_lives_theme_palette "#485b3c" warm 0 balanced 0.20 0.92 arc linear light)
t "fragment argv19 polarity reaches the palette" yes (string match -q "*set -g @tmux_lives_cap_bg '$TPOLPAL[6]'*" -- "$TPOL"; and echo yes; or echo no)
t "write_fragment passes theme_polarity" yes (string match -q '*tmux_lives_theme_polarity dark*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
```

(d) Help: extend the flag-listing assertion with `--polarity`:

```fish
t "setup help documents --polarity" yes (string match -q '*--polarity*dark|light*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
```

- [ ] **Step 2:** run install suite → the new tests FAIL.

- [ ] **Step 3: implement.**

(a) `__tmux_lives_theme_palette`: signature comment + `--argument-names … ease polarity`; default `test -n "$polarity"; or set polarity dark` beside the other defaults; REPLACE the auto-inversion block

```fish
    # light seed -> inverted ramp (dark text end): the spec's required text-legibility fix.
    if test $ok[1] -ge 0.60
```

with

```fish
    # polarity is EXPLICIT (dark|light; default dark) — the old seed-brightness
    # auto-inversion is gone: the seed contributes HUE only (2026-07-16 live smoke:
    # a bright seed flipped the whole bar light, surprising the user).
    if test "$polarity" = light
```

(the swap body stays; `$ok[1]` becomes unused — the seed OKLCH read stays for `$ok[3]`).

(b) `__tmux_lives_render_fragment`: add `set -l themepolarity $argv[19]   # dark|light ('' = dark)` after the argv[18] line; append `"$themepolarity"` to the `__tmux_lives_theme_palette` call.

(c) `__tmux_lives_write_fragment`: append `(__tmux_lives_key tmux_lives_theme_polarity dark)` to the render call.

(d) `__tmux_lives_theme_apply_live` and `__tmux_lives_theme_list`: append `(__tmux_lives_key tmux_lives_theme_polarity dark)` to their palette calls (list: read it once into `set -l pol …` above the loop).

(e) `__tmux_lives_theme_cmd`: add `--polarity` to the parse loop (`set -l pol; set -l have_pol 0` … `case --polarity; set i (math $i + 1); set pol $argv[$i]; set have_pol 1`); validation block

```fish
    if test $have_pol -eq 1
        switch "$pol"
            case dark light
            case '*'
                echo "tmux-lives setup theme: invalid polarity '$pol' — valid: dark, light" >&2
                return 1
        end
    end
```

persist `test $have_pol -eq 1; and set -U tmux_lives_theme_polarity $pol`; echo `test $have_pol -eq 1; and echo "tmux-lives: theme polarity set to $pol"`; state print gains `polarity: $tpol` (read via `__tmux_lives_key tmux_lives_theme_polarity dark`) appended to the knobs line.

(f) Help block: add after the `--range` row:

```fish
        "      --polarity <p>        bar polarity dark|light (default: dark)" \
```

- [ ] **Step 4:** install suite ALL PASS. **Step 5:** full suite; commit `feat(theme): explicit --polarity dark|light (auto-inversion removed)`.

---

### Task 2: Picker polarity — `d` toggle, info line, apply

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_popup_readkey` [+`d`], `__tcz_thp_info` [new signature/format], `__tcz_theme_picker` [init 10th line + `polarity` local, info draw call, `case d`, Enter apply]). Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_thp_info <seed> <phase> <viv> <shape> <ease> <polarity>` → `<seed> · <%+d°> · <viv> · <shape> · <ease> · <polarity>`; readkey token `d`.

- [ ] **Step 1 (RED): tests.** Update `t "thp_info line"` to:

```fish
t "thp_info line" "#485b3c · +30° · vivid · arc · linear · dark" (__tcz_thp_info "#485b3c" 30 vivid arc linear dark)
t "thp_info worst case fits IW" 50 (string length --visible -- (__tcz_thp_info "#ccff44" 300 balanced flat linear light))
```

Add structure asserts near the picker block:

```fish
t "readkey knows d" yes (string match -q '*case 64*' -- (functions __tcz_popup_readkey | string collect); and echo yes; or echo no)
t "picker has a polarity toggle" yes (string match -q '*case d*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker apply passes polarity" yes (string match -q '*--polarity*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
```

- [ ] **Step 2:** categorize suite → new tests FAIL.

- [ ] **Step 3: implement.**

(a) `__tcz_popup_readkey`: add `case 64; echo d; return` beside the `s/e/b` cases (0x64 = `d`; no collision — the switcher ignores unknown tokens).

(b) `__tcz_thp_info` becomes:

```fish
function __tcz_thp_info --argument-names seed phase viv shape ease polarity --description 'pure: the picker info line (no label; worst case exactly 50 cols)'
    printf '%s · %+d° · %s · %s · %s · %s' "$seed" "$phase" "$viv" "$shape" "$ease" "$polarity"
end
```

(c) `__tcz_theme_picker`: add `set -l polarity dark` beside the other locals; `__tcz_thp_init` gains a 10th echo line `echo (__tmux_lives_key tmux_lives_theme_polarity dark)` (AFTER the derive_status line — so existing indexes 1-9 are untouched) and `test (count $init) -ge 10; and test -n "$init[10]"; and set polarity $init[10]`; BOTH `__tcz_thp_reload` and `__tcz_thp_reload_one` append `$polarity` to their `fish -c` arg lists and `$argv[8]`→`$argv[8]` usage gains `$argv[9]` (reload_one) / the loop palette call gains `$argv[8]` (reload — match each function's existing positional tail exactly, adding polarity LAST); the info draw line becomes

```fish
        set -a lines (__tcz_thp_ln (__tcz_theme muted)(__tcz_thp_info "$seed" "$phase" "$viv" "$shape" "$ease" "$polarity")$RST $IW $BORDER $RST)
```

(no leading space); footer key row 1 gains `· $KEY"d"$RST$MUTED dark/light` (verify the row still fits 50 — shorten `vivid`→`viv` in that row if not); `case d`:

```fish
            case d
                test "$polarity" = dark; and set polarity light; or set polarity dark
                __tcz_thp_reload
```

Enter apply gains `--polarity $polarity`:

```fish
        fish -c 'tmux-lives setup theme $argv[1] --phase $argv[2] --vividness $argv[3] --shape $argv[4] --ease $argv[5] --polarity $argv[6]' "$apply" "$phase" "$viv" "$shape" "$ease" "$polarity" >/dev/null 2>&1
```

- [ ] **Step 4:** categorize suite ALL PASS. **Step 5:** full suite; commit `feat(theme): picker polarity — d toggle, info field, apply threading`.

---

### Task 3: Raw-mode seed entry (live swatch + hue readout)

**Files:** Modify `functions/tmux-categorize.fish` (new `__tcz_thp_readchar` near the builders; rewrite the picker's `case b`). Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_thp_readchar` → one of `<hexchar>`|`hash`|`back`|`enter`|`esc`|`other`.

- [ ] **Step 1 (RED): tests.**

```fish
t "thp_readchar exists with hex classification" yes (string match -q '*0-9a-fA-F*' -- (functions __tcz_thp_readchar | string collect); and echo yes; or echo no)
t "picker b-case is raw (no cooked read)" no (string match -q '*read -l val*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker b-case teaches hue-only" yes (string match -q '*hue*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker b-case uses readchar" yes (string match -q '*__tcz_thp_readchar*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
```

- [ ] **Step 2:** RED. **Step 3: implement.**

(a) New function after `__tcz_thp_restore`:

```fish
function __tcz_thp_readchar --description 'seed-entry raw byte -> <hexchar>|hash|back|enter|esc|other (dd HEAD-of-pipeline; tty already raw)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo esc; return; end
    switch "$b"
        case 0d 0a; echo enter; return
        case 1b; echo esc; return
        case 7f 08; echo back; return
        case 23; echo hash; return
    end
    set -l ch (printf '%b' "\\x$b" 2>/dev/null)
    if string match -qr -- '^[0-9a-fA-F]$' "$ch"
        echo $ch
        return
    end
    echo other
end
```

(b) Replace the whole `case b` block body with:

```fish
            case b
                # raw-mode hex entry (replaces the cooked read + its leaked `read>`
                # prompt). Live swatch + extracted-hue readout at parse-complete —
                # the seed contributes its HUE only, so SAY so on the line.
                set -l buf (string replace -r '^#' '' -- $seed)
                set -l cand ''
                set -l hue ''
                set -l entering 1
                printf '\e[2J'
                while test $entering -eq 1
                    set cand ''
                    set hue ''
                    set -l b6 $buf
                    string match -qr '^[0-9a-fA-F]{3}$' -- $buf; and set b6 (string sub -l 1 -- $buf)(string sub -l 1 -- $buf)(string sub -s 2 -l 1 -- $buf)(string sub -s 2 -l 1 -- $buf)(string sub -s 3 -l 1 -- $buf)(string sub -s 3 -l 1 -- $buf)
                    if string match -qr '^[0-9a-fA-F]{6}$' -- $b6
                        set cand "#"(string lower -- $b6)
                        set hue (fish -c 'set -l rgb (__tmux_lives_hex_to_rgb01 $argv[1]); set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]); printf "%.0f" $ok[3]' $cand 2>/dev/null)
                    end
                    set -l sw '  '
                    set -l swbg (__tcz_thp_bg "$cand")
                    test -n "$swbg"; and set sw "$swbg  "(printf '\e[0m')
                    set -l huetxt '—'
                    test -n "$hue"; and set huetxt "$hue°"
                    printf '\e[H seed (only its HUE drives the theme)\e[K\n #%s_ %s hue %s\e[K\n enter apply · esc cancel\e[K' "$buf" "$sw" "$huetxt"
                    printf '\e[J'
                    set -l tok (__tcz_thp_readchar)
                    switch $tok
                        case back
                            test -n "$buf"; and set buf (string sub -e -1 -- $buf)
                        case enter
                            if test -n "$cand"
                                fish -c 'tmux-lives setup color $argv[1]' "$cand" >/dev/null 2>&1
                                __tcz_thp_init
                                __tcz_thp_reload
                                set note "seed applied: $seed"
                            end
                            set entering 0
                        case esc
                            set entering 0
                        case hash other
                            # ignored ('#' is implied)
                        case '*'
                            # $tok IS the typed hex character
                            test (string length -- $buf) -lt 6; and set buf "$buf"(string lower -- $tok)
                    end
                end
                printf '\e[2J'
```


- [ ] **Step 4:** categorize ALL PASS. **Step 5:** full suite; commit `feat(theme): raw-mode seed entry — live swatch + hue readout (hue-only contract on the line)`.

---

## Verification

Suites 8×; structure greps green; headless: `__tcz_thp_info` widths; palette polarity property tests. Live smoke (user): `d` flips the whole catalog dark↔light; `b` shows swatch+hue while typing; same-hue seed changes now visibly explained by the hue readout. RGB sliders = next wave (official agenda).
