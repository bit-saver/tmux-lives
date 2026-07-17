# RGB Slider Seed Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `b` in the theme picker opens an RGB slider screen (↑↓ channel, ←→ ±8 coalesced, live swatch/hex/hue, Enter apply, Esc cancel, `t` = the existing typed-hex editor).

**Architecture:** `__tcz_thp_readchar` grows `up|down|left|right|t` tokens (its ESC/CSI branch already reads the bytes); a pure `__tcz_thp_slider` row builder is unit-tested; the picker's `case b` body (the hex editor) is EXTRACTED verbatim into a nested `__tcz_thp_hexentry`, and a new nested `__tcz_thp_sliders` becomes the `b` entry point. Spec: `docs/superpowers/specs/2026-07-16-seed-slider-picker-design.md`.

**Tech Stack:** fish 4.7.1; existing picker machinery (main @ 73a730e + this branch's spec commit).

## Global Constraints

- Slider row: fixed **39** visible cols = marker(1) + label(1) + space + 32-cell bar + space + 3-char right-aligned value; filled cells wear the channel's pure color AT the current value (`#%02x0000` etc.), remainder = `·` gap cells in `muted`.
- ±8 per press, clamped 0-255; drain-coalescing with the per-iteration `stty min 0 time 0` re-assert (the readkey-CSI lesson); hue recomputed via ONE install-side `fish -c` per adjust-settle (`stale` flag), never per press; swatch/hex pure-local.
- The hex editor's behavior is UNCHANGED — extraction must be verbatim; its switch gains `case t up down left right` (ignored) so the NEW readchar tokens can never be appended into the hex buffer.
- The existing test `picker drain re-asserts non-blocking each iteration` counts drain loops in the `__tcz_theme_picker` listing: it goes **2 → 3** (the slider drain joins the two phase drains).
- All established fish gotchas (var-capture before compound strings; no quoted math-index; `$$vn` indirection via a plain var, never `$$names[$chan]`); NEVER interrupt a suite run; 8× ALL PASS before each commit.

---

### Task 1: readchar tokens + `__tcz_thp_slider` builder + hex-editor guard

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_thp_readchar`; new `__tcz_thp_slider` after `__tcz_thp_restore`; the hex-entry switch's ignore-case). Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_thp_readchar` additionally → `up|down|left|right|t`. `__tcz_thp_slider <label R|G|B> <value 0-255> <selected 0|1>` → one 39-col row.

- [ ] **Step 1 (RED): tests** (near the existing thp tests):

```fish
t "thp_slider width fixed at 39" 39 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)))
t "thp_slider width holds at extremes+selected" 78 (math (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider G 0 1)))" + "(string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider B 255 1))))
t "thp_slider gap cells at 0" 32 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 0 0)) | count)
t "thp_slider gap cells at 128" 16 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)) | count)
t "thp_slider gap cells at 255" 0 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 255 0)) | count)
t "thp_slider selected carries ▐" yes (string match -q '*▐*' -- (__tcz_thp_slider R 10 1); and echo yes; or echo no)
t "readchar classifies arrows + t" yes (begin; set -l l (functions __tcz_thp_readchar | string collect); string match -q '*case 41; echo up*' -- $l; and string match -q '*case 44; echo left*' -- $l; and string match -q '*case 74; echo t*' -- $l; end; and echo yes; or echo no)
t "hex entry ignores the new tokens" yes (string match -q '*case hash other t up down left right*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
```

- [ ] **Step 2:** RED run (`fish tests/test-tmux-categorize.fish`).

- [ ] **Step 3: implement.**

(a) `__tcz_thp_readchar`: in the first switch add `case 74; echo t; return                       # t (slider screen: type hex)` after the `hash` case; in the ESC/CSI branch replace

```fish
        if test "$b2" = 5b; or test "$b2" = 4f
            echo other; return                       # arrow: ignored, not cancel
        end
```

with

```fish
        if test "$b2" = 5b; or test "$b2" = 4f
            switch "$b3"
                case 41; echo up; return
                case 42; echo down; return
                case 43; echo right; return
                case 44; echo left; return
            end
            echo other; return
        end
```

(update the function description: `-> <hexchar>|hash|back|enter|esc|up|down|left|right|t|other`; refresh the comment that says arrows are "simply IGNORED" — they are now classified; the HEX EDITOR ignores them, the slider screen consumes them).

(b) In the picker's hex-entry switch, `case hash other` becomes `case hash other t up down left right` (comment: `# ignored in hex entry ('#' implied; arrows/t are slider-screen tokens)`).

(c) New builder after `__tcz_thp_restore`:

```fish
function __tcz_thp_slider --argument-names label value selected --description 'pure: one RGB slider row = marker(1)+label(1)+space+32-cell bar+space+3-char value; filled cells wear the channel color AT the value (intensity visible), gaps are muted ·; fixed 39 visible cols'
    set -l fill (math "round($value * 32 / 255)")
    test $fill -gt 32; and set fill 32
    test $fill -lt 0; and set fill 0
    set -l chanhex '#000000'
    switch $label
        case R; set chanhex (printf '#%02x0000' $value)
        case G; set chanhex (printf '#00%02x00' $value)
        case B; set chanhex (printf '#0000%02x' $value)
    end
    set -l bar ''
    if test $fill -gt 0
        set -l bg (__tcz_thp_bg "$chanhex")
        set -l cells (string repeat -n $fill ' ')
        set bar "$bg$cells"(printf '\e[0m')
    end
    set -l rest (math "32 - $fill")
    if test $rest -gt 0
        set -l gapc (string repeat -n $rest '·')
        set -l MUT (__tcz_theme muted)
        set -l RS (__tcz_theme reset)
        set bar "$bar$MUT$gapc$RS"
    end
    set -l marker ' '
    set -l labcol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set labcol (__tcz_theme key)
    end
    set -l valtxt (string pad -w 3 -- $value)
    set -l VC (__tcz_theme value)
    set -l RS2 (__tcz_theme reset)
    printf '%s%s%s%s %s %s%s%s' "$marker" "$labcol" "$label" "$RS2" "$bar" "$VC" "$valtxt" "$RS2"
end
```

- [ ] **Step 4:** GREEN. **Step 5:** full suite; commit `feat(theme): slider row builder + readchar arrow/t tokens (hex entry guarded)`.

---

### Task 2: slider screen, `b` reroute, hexentry extraction, docs

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_theme_picker`: extract `__tcz_thp_hexentry`, add `__tcz_thp_sliders`, reroute `case b`, extend the cleanup `functions -e` list, refresh the picker docstring `b` clause), `README.md` (one sentence in the theming section: `b` opens RGB sliders, `t` inside types hex). Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Consumes:** Task 1's builder + tokens; existing `__tcz_thp_init/_reload`, apply path.

- [ ] **Step 1 (RED): tests:**

```fish
t "picker b opens the sliders" yes (string match -q '*case b\n*__tcz_thp_sliders*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders route t to the hex editor" yes (string match -q '*case t\n*__tcz_thp_hexentry*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders apply composes a hex" yes (string match -q '*#%02x%02x%02x*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders erased on exit" yes (begin; set -l l (functions __tcz_theme_picker | string collect); string match -q '*functions -e __tcz_thp_sliders*' -- $l; and string match -q '*functions -e __tcz_thp_hexentry*' -- $l; end; and echo yes; or echo no)
```

and CHANGE the drain-count expectation from 2 to 3 in `t "picker drain re-asserts non-blocking each iteration"`.

(NB the two `case …\n*` patterns above match against the `functions` listing's real indentation — if `string match` globbing of `\n` proves unreliable, use `string match -r` with `case b\s+__tcz_thp_sliders`-style regexes instead; the intent each must lock: `case b`'s body calls `__tcz_thp_sliders`, and the sliders' `case t` calls `__tcz_thp_hexentry`.)

- [ ] **Step 2:** RED.

- [ ] **Step 3: implement** inside `__tcz_theme_picker`:

(a) Define, next to `__tcz_thp_reload_one`, the extraction: `function __tcz_thp_hexentry --no-scope-shadowing --description 'typed-hex seed entry (raw; live swatch + hue at parse-complete)'` whose body is the CURRENT `case b` block content VERBATIM (from `set -l buf (string replace -r '^#' '' -- $seed)` through the final `printf '\e[2J'`), unchanged except it now lives in the function.

(b) Define after it:

```fish
    function __tcz_thp_sliders --no-scope-shadowing --description 'RGB slider seed screen: ↑↓ channel, ←→ ±8 (coalesced), t typed hex, ⏎ apply, esc cancel'
        set -l r 58
        set -l g 58
        set -l b 58
        set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$seed")
        if test (count $m) -eq 3
            set r (math "0x$m[1]")
            set g (math "0x$m[2]")
            set b (math "0x$m[3]")
        end
        set -l chan 1
        set -l hue ''
        set -l stale 1
        set -l sliding 1
        printf '\e[2J'
        while test $sliding -eq 1
            set -l hex (printf '#%02x%02x%02x' $r $g $b)
            if test $stale -eq 1
                set hue (fish -c 'set -l rgb (__tmux_lives_hex_to_rgb01 $argv[1]); set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]); printf "%.0f" $ok[3]' $hex 2>/dev/null)
                set stale 0
            end
            set -l swbg (__tcz_thp_bg "$hex")
            set -l sw "$swbg  "(printf '\e[0m')
            set -l huetxt '—'
            test -n "$hue"; and set huetxt "$hue°"
            set -l s1 0
            set -l s2 0
            set -l s3 0
            switch $chan
                case 1; set s1 1
                case 2; set s2 1
                case 3; set s3 1
            end
            set -l row1 (__tcz_thp_slider R $r $s1)
            set -l row2 (__tcz_thp_slider G $g $s2)
            set -l row3 (__tcz_thp_slider B $b $s3)
            printf '\e[?2026h\e[H seed sliders (only its HUE drives the theme)\e[K\n %s %s · hue %s\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n ↑↓ channel · ←→ adjust · t type hex · ⏎ apply · esc cancel\e[K' "$sw" "$hex" "$huetxt" "$row1" "$row2" "$row3"
            printf '\e[J\e[?2026l'
            set -l tok (__tcz_thp_readchar)
            switch $tok
                case up
                    test $chan -gt 1; and set chan (math $chan - 1)
                case down
                    test $chan -lt 3; and set chan (math $chan + 1)
                case left right
                    set -l delta -8
                    test "$tok" = right; and set delta 8
                    while true
                        stty min 0 time 0 2>/dev/null
                        set -l k2 (__tcz_thp_readchar)
                        switch "$k2"
                            case left; set delta (math $delta - 8)
                            case right; set delta (math $delta + 8)
                            case '*'; break
                        end
                    end
                    stty min 1 time 0 2>/dev/null
                    set -l names r g b
                    set -l vn $names[$chan]
                    set -l cur $$vn
                    set cur (math "$cur + $delta")
                    test $cur -lt 0; and set cur 0
                    test $cur -gt 255; and set cur 255
                    set $vn $cur
                    set stale 1
                case t
                    __tcz_thp_hexentry
                    set sliding 0
                case enter
                    fish -c 'tmux-lives setup color $argv[1]' (printf '#%02x%02x%02x' $r $g $b) >/dev/null 2>&1
                    __tcz_thp_init
                    __tcz_thp_reload
                    set note "seed applied: $seed"
                    set sliding 0
                case esc
                    set sliding 0
            end
        end
        printf '\e[2J'
    end
```

(NB the single-key `case left right` shared head then split drain is intentionally NOT used here — this combined form is fine because `$tok` distinguishes the initial direction, unlike the phase drains where the brief split them; keep as written.)

(c) `case b` in the main loop becomes exactly:

```fish
            case b
                __tcz_thp_sliders
```

(d) The exit block's `functions -e` list gains `__tcz_thp_hexentry` and `__tcz_thp_sliders`.

(e) Picker docstring `b` clause → `b set seed (RGB sliders; t = typed hex with live swatch + hue)`. README theming section: extend the picker sentence with `— b opens RGB sliders for the seed (t inside for typed hex)`.

- [ ] **Step 4:** GREEN (categorize). **Step 5:** full suite; commit `feat(theme): RGB slider seed screen — b opens sliders, t drops to typed hex`.

---

## Verification

Suites 8×; slider-width tests; the drain-count test at 3; structure greps. Live smoke (user): `b` → sliders track ←→ smoothly with the swatch/hex/hue updating on settle, `t` → typed hex still works, Enter applies, Esc backs out clean.
