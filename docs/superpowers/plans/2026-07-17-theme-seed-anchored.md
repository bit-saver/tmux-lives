# Theme v3.1 Seed-Anchored Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The theme engine renders the seed AS the status bar (companions cluster around it; only text jumps for contrast), and the theme picker becomes layout A: labeled global-adjustments zone, apply/reset/rotate keys, ShellFish tab chip, big seed swatch, and a shared aligned key-legend across popups.

**Architecture:** All engine/CLI/fragment/migration work lives in `conf.d/tmux-lives-install.fish`; all picker/legend work lives in `functions/tmux-categorize.fish` (house rule: ZERO new files). The palette keeps its 7-role output contract (bar sep tabs active windows cap text) so the fragment/@options plumbing is untouched in shape; `--contrast`/`--rotate` replace `--polarity`/`--range` end to end (CLI, universals, fragment argv 18/19, migration erasure).

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's `t "<desc>" <expected> <got>` test harness, `-L`-socket / `tmux_lives_fake_environ` seams.

**Spec:** `docs/superpowers/specs/2026-07-17-theme-seed-anchored-design.md` — read it first.

## Global Constraints

- **Deploy = the user's `fisher update` ONLY.** Never copy files into `~/.config/fish/`, never edit `~/.tmux.conf`, never `set -U` the user's real universals outside test save/restore guards.
- **Never kill a running test suite** — an aborted run leaks the user's real fish universals. New tests that touch universals MUST save/clear at the TOP of their section and restore at the BOTTOM.
- **Any test driving code that runs bare `tmux` must pin the `tmux_lives_tmux_socket` seam or a PATH shim** — never the user's live server.
- fish gotchas (all grep-guard- or review-enforced in this repo):
  - `"$x[(math …)]"` (double-quoted math list index) is an ERROR — index via a var, unquoted. The categorize suite grep-guard bans it file-wide.
  - A zero-output command substitution concatenated into a `set` argument collapses the WHOLE argument — capture into a var first, then concat the QUOTED var.
  - No comparisons inside `math` — branch with float-capable `test`.
  - `test "$x" = (cmd)` THROWS when cmd prints nothing — capture and quote: `set -l c (cmd); test "$x" = "$c"`.
  - Unquoted `#hex` in an emitted tmux option line is a COMMENT — single-quote color values in fragment lines.
  - Every raw-tty drain loop must re-assert `stty min 0 time 0` INSIDE each iteration (`__tcz_popup_readkey`/`__tcz_thp_readchar` CSI branches reset to blocking).
  - A full-height popup frame must emit its LAST row without `\n` (else the top border scrolls off). Guard `count -gt 1` before `printf '%s\e[K\n' $lines[1..-2]`.
- The Bash tool's shell is zsh: run suites as `fish tests/test-tmux-install.fish` (single file) or `fish -c 'for t in tests/test-*.fish; fish $t; end'` (all 8); quote `=`-prefixed args.
- Copy rules: user-facing word is **scheme** (not formula/token); contrast values are exactly `auto|lighter|darker`; rotate range is exactly `0-4`.
- Commit after every task; do NOT push mid-plan (push happens at branch completion).

## File Structure

- `conf.d/tmux-lives-install.fish` — Tasks 1–3 (engine, CLI, fragment+migration).
- `functions/tmux-categorize.fish` — Tasks 4–7 (tl palette, legend builder, switcher footer, picker builders + loop, seed screens).
- `tests/test-tmux-install.fish` — engine/CLI/fragment/migration tests.
- `tests/test-tmux-categorize.fish` — builder/readkey/guard tests.
- `README.md`, `CLAUDE.md` — Task 8.

Work on a feature branch: `git checkout -b feat/theme-seed-anchored` (from current `main`).

---

### Task 1: Engine — seed-anchored `__tmux_lives_theme_palette`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_roles` (~L605), `__tmux_lives_theme_sample` (~L609), `__tmux_lives_theme_lrange` (~L626, DELETE), `__tmux_lives_theme_palette` (~L637)
- Test: `tests/test-tmux-install.fish` (the existing "theme engine" section)

**Interfaces:**
- Consumes: existing `__tmux_lives_theme_arc`, `__tmux_lives_norm360`, `__tmux_lives_oklch_hex`, `__tmux_lives_hex_to_rgb01`, `__tmux_lives_rgb_to_oklch`.
- Produces (later tasks call these EXACT signatures):
  - `__tmux_lives_theme_roles` → 5 lines `"<role> <t> <dL>"` (supports only; bar/text live in palette)
  - `__tmux_lives_theme_sample <t> <L> <seedH> <a0> <a1> <phase> <cs> <cmax> <shape> <ease>` → one `#rrggbb`
  - `__tmux_lives_theme_palette <seedHex> <scheme> <phase> <vividness> <shape> <ease> <contrast> <rotate>` → 7 lines (bar sep tabs active windows cap text); empty on bad seed/scheme
  - `__tmux_lives_theme_lrange` NO LONGER EXISTS.

- [ ] **Step 1: Write the failing tests.** In `tests/test-tmux-install.fish`, find the theme-engine section (search `__tmux_lives_theme_palette`). DELETE every existing test that calls `__tmux_lives_theme_palette` with the OLD 9-arg signature or `__tmux_lives_theme_lrange` (they pin the dead model), and add:

```fish
# --- v3.1 seed-anchored palette ---
function __tlt_L --description 'test helper: hex -> OKLCH L'
    set -l rgb (__tmux_lives_hex_to_rgb01 $argv[1])
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    echo $ok[1]
end
set -l pal (__tmux_lives_theme_palette '#485B3C' wide 0 balanced arc linear auto 0)
t "v31 palette emits 7 roles" 7 (count $pal)
t "v31 bar IS the seed verbatim (lowercased)" '#485b3c' $pal[1]
set -l palm (__tmux_lives_theme_palette '#485B3C' mono 0 balanced arc linear auto 0)
t "v31 bar identical across schemes" "$pal[1]" "$palm[1]"
set -l palp (__tmux_lives_theme_palette '#485B3C' wide 90 balanced arc linear auto 0)
t "v31 phase never moves the bar" "$pal[1]" "$palp[1]"
t "v31 phase moves companions" 0 (test "$pal[2]" = "$palp[2]"; and echo 1; or echo 0)
# auto direction: dark seed ramps lighter (text L > bar L); light seed ramps darker
set -l pdark (__tmux_lives_theme_palette '#202020' mono 0 balanced arc linear auto 0)
set -l Lb (__tlt_L $pdark[1]); set -l Lt (__tlt_L $pdark[7])
t "v31 auto dark seed -> light text" 1 (test $Lt -gt $Lb; and echo 1; or echo 0)
set -l plight (__tmux_lives_theme_palette '#d8d8c8' mono 0 balanced arc linear auto 0)
set -l Lb2 (__tlt_L $plight[1]); set -l Lt2 (__tlt_L $plight[7])
t "v31 auto light seed -> dark text" 1 (test $Lt2 -lt $Lb2; and echo 1; or echo 0)
set -l dLt (math "abs($Lt - $Lb)")
t "v31 auto text dL floor >= 0.40" 1 (test $dLt -ge 0.40; and echo 1; or echo 0)
set -l palv (__tmux_lives_theme_palette '#485B3C' wide 0 vivid arc linear auto 0)
t "v31 vividness never moves the bar" "$pal[1]" "$palv[1]"
# forced direction wins
set -l pforce (__tmux_lives_theme_palette '#202020' mono 0 balanced arc linear darker 0)
set -l Lt3 (__tlt_L $pforce[7])
t "v31 forced darker honored on a dark seed" 1 (test $Lt3 -lt $Lb; and echo 1; or echo 0)
# rotation: exact cyclic permutation of the 5 support colors; bar/text pinned
set -l r0 (__tmux_lives_theme_palette '#485B3C' wide 0 balanced arc linear auto 0)
set -l r1 (__tmux_lives_theme_palette '#485B3C' wide 0 balanced arc linear auto 1)
t "v31 rot1 sep wears rot0 cap" "$r0[6]" "$r1[2]"
t "v31 rot1 tabs wears rot0 sep" "$r0[2]" "$r1[3]"
t "v31 rot1 cap wears rot0 windows" "$r0[5]" "$r1[6]"
t "v31 rotation pins the bar" "$r0[1]" "$r1[1]"
t "v31 rotation pins the text" "$r0[7]" "$r1[7]"
# support ladder: companions cluster (every support within 0.30 L of the seed)
set -l Ls (__tlt_L $r0[1])
set -l clustered 1
for i in 2 3 4 5 6
    set -l Li (__tlt_L $r0[$i])
    set -l dLi (math "abs($Li - $Ls)")
    test $dLi -le 0.30; or set clustered 0
end
t "v31 supports cluster near the seed" 1 $clustered
# bad inputs still fall through
t "v31 non-hex seed -> nothing" 0 (count (__tmux_lives_theme_palette red wide 0 balanced arc linear auto 0))
t "v31 unknown scheme -> nothing" 0 (count (__tmux_lives_theme_palette '#485B3C' nope 0 balanced arc linear auto 0))
functions -e __tlt_L
```

- [ ] **Step 2: Run to verify failure.** `fish tests/test-tmux-install.fish` — expect FAILs (old palette takes 9 positional args; new tests pass 8 and assert seed-as-bar).

- [ ] **Step 3: Implement.** Replace the four functions:

```fish
function __tmux_lives_theme_roles --description 'v3.1 support-role ladder, "<role> <t> <dL>" per line — THE one adjustable place (spec decision: keep tunable). bar (= the seed) and text (contrast side) are built in theme_palette, not here.'
    printf '%s\n' 'sep 0.15 0.06' 'tabs 0.30 0.10' 'active 0.50 0.15' 'windows 0.60 0.17' 'cap 0.80 0.22'
end

function __tmux_lives_theme_sample --argument-names t L seedH a0 a1 phase cs cmax shape ease --description 'sample the companion gradient at arc position t with ABSOLUTE lightness L: hue arc a0->a1 (+phase) off seedH, eased; chroma anchors at the seed (cs -> cmax sine arc; flat: cmax) -> #rrggbb'
    set -l et $t
    test "$ease" = cubic; and set et (math "$t ^ 3")
    set -l H (__tmux_lives_norm360 (math "$seedH + $a0 + ($a1 - $a0) * $et + $phase"))
    set -l C $cmax
    if test "$shape" != flat
        set C (math "$cs + ($cmax - $cs) * sin(3.141592653589793 * $t)")
    end
    __tmux_lives_oklch_hex $L $C $H
end

function __tmux_lives_theme_palette --argument-names seedHex scheme phase vividness shape ease contrast rotate --description 'seed + scheme/knobs -> 7 role hexes one per line (bar sep tabs active windows cap text). The bar IS the seed verbatim; companions cluster around it (gentle dL ladder, hue/chroma differentiate); text jumps to the contrast side. contrast auto|lighter|darker ('' = auto); rotate 0-4 permutes the COMPUTED support colors. Non-hex seed or unknown scheme -> nothing (callers fall back to legacy).'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l arc (__tmux_lives_theme_arc "$scheme")
    test (count $arc) -eq 2; or return
    test -n "$phase"; or set phase 0
    test -n "$shape"; or set shape arc
    test -n "$ease"; or set ease linear
    test -n "$contrast"; or set contrast auto
    string match -qr '^[0-4]$' -- "$rotate"; or set rotate 0
    set -l cmax 0.105
    switch "$vividness"
        case soft;  set cmax 0.075
        case vivid; set cmax 0.130
    end
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    # direction: which side companions + text sit on. auto derives from the
    # seed's own lightness (dark seed -> lighter companions/text; light -> darker).
    set -l dir 1
    switch "$contrast"
        case darker
            set dir -1
        case lighter
            set dir 1
        case '*'   # auto
            test $ok[1] -ge 0.55; and set dir -1
    end
    # bar = the seed, verbatim (never re-derived through an OKLCH round-trip)
    printf '%s\n' (string lower -- $seedHex)
    set -l sup
    for rt in (__tmux_lives_theme_roles)
        set -l parts (string split ' ' $rt)
        set -l L (math "$ok[1] + $dir * $parts[3]")
        test $L -lt 0.05; and set L 0.05
        test $L -gt 0.95; and set L 0.95
        set -l hx (__tmux_lives_theme_sample $parts[2] $L $ok[3] $arc[1] $arc[2] $phase $ok[2] $cmax $shape $ease)
        test -n "$hx"; or return
        set -a sup $hx
    end
    # rotation: permute the COMPUTED support colors across the roles —
    # permuting the ladder params instead would be a no-op.
    for i in 1 2 3 4 5
        set -l j (math "(($i - 1 - $rotate) % 5 + 5) % 5 + 1")
        printf '%s\n' $sup[$j]
    end
    set -l Lt (math "$ok[1] + $dir * 0.45")
    test $Lt -lt 0.05; and set Lt 0.05
    test $Lt -gt 0.97; and set Lt 0.97
    __tmux_lives_oklch_hex $Lt 0.03 (__tmux_lives_norm360 (math "$ok[3] + $arc[2] + $phase"))
end
```

DELETE `__tmux_lives_theme_lrange` entirely. NOTE: this temporarily breaks the four call sites (`theme_apply_live` L769, `theme_list` L802, `theme_cmd` L839, `render_fragment` L79) — Tasks 2–3 fix them; the suite sections covering those are adjusted there. If the suite run in Step 4 fails ONLY in those downstream sections, that is the expected staged state; the new engine tests must pass.

- [ ] **Step 4: Run.** `fish tests/test-tmux-install.fish` — all NEW `v31` tests PASS (downstream CLI/fragment failures expected until Tasks 2–3).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): seed-anchored palette — bar IS the seed, clustered companions, contrast dir + rotation"`

---

### Task 2: CLI — `--contrast` / `--rotate`; apply-live explicit args

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_apply_live` (~L764), `__tmux_lives_theme_list` (~L799), `__tmux_lives_theme_cmd` (~L821), `__tmux_lives_setup_help_lines` rows (~L1066-1072)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: Task 1 `__tmux_lives_theme_palette` (8-arg signature).
- Produces:
  - `__tmux_lives_theme_apply_live [<scheme> <phase> <viv> <shape> <ease> <contrast> <rotate>]` — with exactly 7 args pushes THOSE values (picker preview; NO state written); with none, reads universals as today.
  - Universals `tmux_lives_theme_contrast` (default `auto`), `tmux_lives_theme_rotate` (default `0`).
  - CLI flags `--contrast auto|lighter|darker`, `--rotate <0-4>`; `--phase/--vividness/--shape/--ease` unchanged; `--range`/`--polarity` GONE (they now fall into the scheme arm → "invalid scheme" error, which is acceptable UX).

- [ ] **Step 1: Failing tests.** In the install suite's theme-CLI section, FIRST extend the section's save/clear guard (at its TOP) to also save/clear `tmux_lives_theme_contrast` and `tmux_lives_theme_rotate` (and restore them at the section BOTTOM — mirror the existing `_capv`-style pattern used for the other theme universals). Delete tests asserting `--range`/`--polarity` behavior or the old state-print line. Add:

```fish
__tmux_lives_theme_cmd --contrast lighter >/dev/null
t "cli --contrast persists" lighter "$tmux_lives_theme_contrast"
__tmux_lives_theme_cmd --rotate 3 >/dev/null
t "cli --rotate persists" 3 "$tmux_lives_theme_rotate"
t "cli --contrast rejects junk" 1 (__tmux_lives_theme_cmd --contrast sideways >/dev/null 2>&1; echo $status)
t "cli --rotate rejects 5" 1 (__tmux_lives_theme_cmd --rotate 5 >/dev/null 2>&1; echo $status)
t "cli --polarity is gone" 1 (__tmux_lives_theme_cmd --polarity dark >/dev/null 2>&1; echo $status)
set -e tmux_lives_theme_contrast; set -e tmux_lives_theme_rotate
set -l st (__tmux_lives_theme_cmd | string collect)
t "state print shows contrast" 1 (string match -q '*contrast: auto*' -- "$st"; and echo 1; or echo 0)
t "state print shows rotate" 1 (string match -q '*rotate: 0*' -- "$st"; and echo 1; or echo 0)
t "state print drops polarity" 0 (string match -q '*polarity*' -- "$st"; and echo 1; or echo 0)
t "state print drops range" 0 (string match -q '*range*' -- "$st"; and echo 1; or echo 0)
set -l hl (__tmux_lives_setup_help_lines | string collect)
t "setup help documents --contrast" 1 (string match -q '*--contrast*' -- "$hl"; and echo 1; or echo 0)
t "setup help documents --rotate" 1 (string match -q '*--rotate*' -- "$hl"; and echo 1; or echo 0)
t "setup help drops --polarity" 0 (string match -q '*--polarity*' -- "$hl"; and echo 1; or echo 0)
```

NOTE: the state-print test path runs OUTSIDE tmux state mutation — but `__tmux_lives_theme_cmd --contrast lighter` calls `__tmux_lives_write_fragment` + `__tmux_lives_theme_apply_live`; keep the section's existing write_fragment STUB and `tmux_lives_tmux_socket` pin exactly as the current CLI tests do (copy their setup).

- [ ] **Step 2: Run.** `fish tests/test-tmux-install.fish` — new tests FAIL (unknown flags / old prints).

- [ ] **Step 3: Implement.**
  - `__tmux_lives_theme_apply_live`: new head (rest of the function body from `if test (count $tpal) -eq 7` down is UNCHANGED):

```fish
function __tmux_lives_theme_apply_live --description 'internal: push the effective v3 theme (or legacy when off/seedless) to the live server. With exactly 7 args (scheme phase viv shape ease contrast rotate) pushes THOSE values instead of the universals — the picker preview path; writes no state.'
    set -l theme; set -l phase; set -l viv; set -l shape; set -l ease; set -l contrast; set -l rotate
    if test (count $argv) -eq 7
        set theme $argv[1]; set phase $argv[2]; set viv $argv[3]; set shape $argv[4]
        set ease $argv[5]; set contrast $argv[6]; set rotate $argv[7]
    else
        set theme (__tmux_lives_key tmux_lives_theme mono)
        set phase (__tmux_lives_key tmux_lives_theme_phase 0)
        set viv (__tmux_lives_key tmux_lives_theme_vividness balanced)
        set shape (__tmux_lives_key tmux_lives_theme_shape arc)
        set ease (__tmux_lives_key tmux_lives_theme_ease linear)
        set contrast (__tmux_lives_key tmux_lives_theme_contrast auto)
        set rotate (__tmux_lives_key tmux_lives_theme_rotate 0)
    end
    set -l seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ''))
    set -l tpal
    if test "$theme" != off; and test -n "$seed"
        set tpal (__tmux_lives_theme_palette $seed "$theme" $phase $viv $shape $ease $contrast $rotate)
    end
```

  - `__tmux_lives_theme_list`: drop the `tl`/`pol` lines; read `set -l contrast (__tmux_lives_key tmux_lives_theme_contrast auto)` and `set -l rotate (__tmux_lives_key tmux_lives_theme_rotate 0)`; palette call becomes `(__tmux_lives_theme_palette $seed $scheme $phase $viv $shape $ease $contrast $rotate)`.
  - `__tmux_lives_theme_cmd`:
    - docstring: `'tmux-lives setup theme [<scheme>|list|off] [--phase <deg>] [--vividness soft|balanced|vivid] [--shape arc|flat] [--ease linear|cubic] [--contrast auto|lighter|darker] [--rotate <0-4>]: the v3 gradient-map bar theme'`
    - no-arg state print: drop `trange`/`tpol`; add `set -l tcon (__tmux_lives_key tmux_lives_theme_contrast auto)` and `set -l trot (__tmux_lives_key tmux_lives_theme_rotate 0)`; line becomes `echo "  phase: $tphase   vividness: $tviv   shape: $tshape   ease: $tease   contrast: $tcon   rotate: $trot"`.
    - parser: replace `case --range` / `case --polarity` arms with:

```fish
            case --contrast
                set i (math $i + 1); set con $argv[$i]; set have_con 1
            case --rotate
                set i (math $i + 1); set rot $argv[$i]; set have_rot 1
```

      (declare `set -l con; set -l have_con 0; set -l rot; set -l have_rot 0` with the other locals; delete `range`/`pol` locals.)
    - validation: replace the range/polarity blocks with:

```fish
    if test $have_con -eq 1
        switch "$con"
            case auto lighter darker
            case '*'
                echo "tmux-lives setup theme: invalid contrast '$con' — valid: auto, lighter, darker" >&2
                return 1
        end
    end
    if test $have_rot -eq 1; and not string match -qr '^[0-4]$' -- "$rot"
        echo "tmux-lives setup theme: invalid rotate '$rot' — 0-4" >&2
        return 1
    end
```

    - persistence + echoes: replace the range/pol lines with `test $have_con -eq 1; and set -U tmux_lives_theme_contrast $con`, `test $have_rot -eq 1; and set -U tmux_lives_theme_rotate $rot`, and echoes `"tmux-lives: theme contrast set to $con"` / `"tmux-lives: theme rotate set to $rot"`.
  - `__tmux_lives_setup_help_lines`: replace the `--range`/`--polarity` rows with (keep column padding identical to neighbors):

```fish
        "      --contrast <c>        companion side auto|lighter|darker (default: auto)" \
        "      --rotate <n>          rotate companion placement 0-4 (default: 0)" \
```

- [ ] **Step 4: Run.** `fish tests/test-tmux-install.fish` — CLI section PASSES (fragment section may still fail until Task 3).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): --contrast/--rotate CLI + apply-live explicit-args preview path (--polarity/--range removed)"`

---

### Task 3: Fragment argv 18/19 + v3.1 migration

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` docstring L14-34 + theme block L79-83, `__tmux_lives_write_fragment` call site L255, new `__tmux_lives_migrate_v31` after `__tmux_lives_migrate_v2` (~L1206), `_tmux_lives_post_update` (~L1212)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: Task 1 palette; Task 2 universals.
- Produces: `__tmux_lives_render_fragment` argv 18 = `themecontrast` ('' = auto), argv 19 = `themerotate` ('' = 0); `__tmux_lives_migrate_v31` (idempotent, called by `_tmux_lives_post_update` right after `__tmux_lives_migrate_v2`).

- [ ] **Step 1: Failing tests.** In the fragment section of the install suite, update any existing render calls that pass 19 args (positions 18/19 were range/polarity — grep the suite for `0.20,0.92` and `dark`/`light` in render calls and swap those positions to contrast/rotate values). Add:

```fish
# argv18/19 = contrast/rotate
set -l fr0 (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k wide 0 balanced arc linear auto 0 | string collect)
set -l fr1 (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k wide 0 balanced arc linear auto 1 | string collect)
set -l sep0 (string match -r "@tmux_lives_sep_fg '[^']*'" -- "$fr0")
set -l sep1 (string match -r "@tmux_lives_sep_fg '[^']*'" -- "$fr1")
t "fragment rotate changes the sep role" 0 (test "$sep0" = "$sep1"; and echo 1; or echo 0)
set -l frd (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k wide 0 balanced arc linear darker 0 | string collect)
set -l tx0 (string match -r "@tmux_lives_text_fg '[^']*'" -- "$fr0")
set -l txd (string match -r "@tmux_lives_text_fg '[^']*'" -- "$frd")
t "fragment contrast flips the text role" 0 (test "$tx0" = "$txd"; and echo 1; or echo 0)
t "fragment bar bg IS the seed" 1 (string match -q "*status-style bg=#485b3c*" -- "$fr0"; and echo 1; or echo 0)
# v3.1 migration erases the dead universals (guarded: save/restore around)
set -l _sv_pol; set -q tmux_lives_theme_polarity; and set _sv_pol $tmux_lives_theme_polarity
set -l _sv_rng; set -q tmux_lives_theme_range; and set _sv_rng $tmux_lives_theme_range
set -U tmux_lives_theme_polarity light
set -U tmux_lives_theme_range 0.10,0.90
__tmux_lives_migrate_v31 >/dev/null
t "migrate v31 erases polarity" 0 (set -q tmux_lives_theme_polarity; and echo 1; or echo 0)
t "migrate v31 erases range" 0 (set -q tmux_lives_theme_range; and echo 1; or echo 0)
t "migrate v31 idempotent + quiet" '' (__tmux_lives_migrate_v31 | string collect)
set -q _sv_pol[1]; and set -U tmux_lives_theme_polarity $_sv_pol
set -q _sv_rng[1]; and set -U tmux_lives_theme_range $_sv_rng
# grep-guards: the dead knobs leave zero traces in the install source
set -l src (cat $plugindir/conf.d/tmux-lives-install.fish | string collect)
t "guard: no themepolarity in source" 0 (string match -q '*themepolarity*' -- "$src"; and echo 1; or echo 0)
t "guard: no themerange in source" 0 (string match -q '*themerange*' -- "$src"; and echo 1; or echo 0)
t "guard: no theme_lrange in source" 0 (string match -q '*theme_lrange*' -- "$src"; and echo 1; or echo 0)
t "guard: no --polarity flag in source" 0 (string match -q '*--polarity*' -- "$src"; and echo 1; or echo 0)
```

(`tmux_lives_theme_polarity` itself still legitimately appears once — in the migrate erase list — so the guards target the render-side spellings + the flag + lrange, which must be zero.)

- [ ] **Step 2: Run.** FAIL (old argv semantics; migrate fn missing).

- [ ] **Step 3: Implement.**
  - Docstring L33-34: replace the two lines with `#   18 themecontrast  companion side auto|lighter|darker ('' = auto)` and `#   19 themerotate    companion placement rotation 0-4 ('' = 0)` (match the file's existing docstring comment style).
  - Body: `set -l themecontrast $argv[18]` / `set -l themerotate $argv[19]`; delete `set -l tl (__tmux_lives_theme_lrange "$themerange")` (L79); palette call: `set tpal (__tmux_lives_theme_palette $seedhex "$theme" "$themephase" "$themeviv" "$themeshape" "$themeease" "$themecontrast" "$themerotate")`.
  - `__tmux_lives_write_fragment` L255: replace the last two `__tmux_lives_key` args with `(__tmux_lives_key tmux_lives_theme_contrast auto) (__tmux_lives_key tmux_lives_theme_rotate 0)`.
  - New function after `__tmux_lives_migrate_v2`:

```fish
function __tmux_lives_migrate_v31 --description 'v3 -> v3.1 seed-anchored migration: polarity/range have no v3.1 meaning (the bar IS the seed; contrast defaults auto) — erase them (idempotent)'
    set -l had 0
    for old in tmux_lives_theme_polarity tmux_lives_theme_range
        set -q $old; and begin; set -e $old; set had 1; end
    end
    test $had -eq 1; and echo "tmux-lives: theme is now seed-anchored — polarity/range retired; contrast defaults to auto ('tmux-lives setup theme')"
    return 0
end
```

  - `_tmux_lives_post_update`: add `__tmux_lives_migrate_v31` on the line after `__tmux_lives_migrate_v2`.

- [ ] **Step 4: Run.** `fish tests/test-tmux-install.fish` — expect **ALL PASS** (install side is now coherent end to end).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): fragment argv 18/19 = contrast/rotate + v3.1 migration erases polarity/range"`

---

### Task 4: tl `sel-bg` darken + shared legend builder + session-picker footer

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme` (~L1614), new `__tcz_legend_row` near the other popup helpers (~L750, above `__tcz_popup_readkey`), `__tcz_popup` loop (~L1020-1047)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: existing `__tcz_theme`, `__tcz_strip_sgr`.
- Produces: `__tcz_legend_row <pitch> [<key> <label>]...` → ONE string: leading space + per-pair `key`(key color)+space+`label`(muted), each cell padded to `<pitch>` visible cols. Tasks 6–7 build every popup footer with it.

- [ ] **Step 1: Failing tests.** In `tests/test-tmux-categorize.fish` (which sources the categorizer with `tmux_categorize_test` set — follow the existing popup-builder tests' pattern):

```fish
# --- shared key-legend builder + darker sel-bg ---
set -l lg (__tcz_legend_row 12 '↑↓' move '⏎' switch x kill esc close)
set -l lgp (__tcz_strip_sgr "$lg")
t "legend row visible width = 1 + 4*pitch" 49 (string length --visible -- "$lgp")
t "legend row carries all labels" 1 (string match -q '*move*switch*kill*close*' -- "$lgp"; and echo 1; or echo 0)
t "legend key colored" 1 (string match -q '*38;2;245;207;138*' -- "$lg"; and echo 1; or echo 0)
t "sel-bg darkened" 1 (test (__tcz_theme sel-bg) = (printf '\e[48;2;25;25;19m'); and echo 1; or echo 0)
```

- [ ] **Step 2: Run.** `fish tests/test-tmux-categorize.fish` — FAIL (`__tcz_legend_row` undefined; old sel-bg 52;51;47).

- [ ] **Step 3: Implement.**
  - `__tcz_theme` `sel-bg` arm → `case sel-bg; printf '\e[48;2;25;25;19m'` with the comment: `# near-black band: must read as CHROME, never as one of the scheme colors beside it (2026-07-17 picker feedback)`.
  - New builder (note the CAPTURED pad var — a zero-output inline substitution would collapse the whole `set`):

```fish
function __tcz_legend_row --argument-names pitch --description 'pure: one aligned key-legend row — argv[2..] = <key> <label> pairs; each cell = key (key color) + space + label (muted) padded to <pitch> visible cols; leading space. The shared footer convention for every tmux-lives popup.'
    set -l KEY (__tcz_theme key)
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l out ' '
    set -l rest $argv[2..]
    while test (count $rest) -ge 2
        set -l cell "$rest[1] $rest[2]"
        set -l pad (math "$pitch - "(string length --visible -- "$cell"))
        test $pad -lt 0; and set pad 0
        set -l padstr (string repeat -n $pad ' ')
        set out "$out$KEY$rest[1]$RST $MUT$rest[2]$RST$padstr"
        set -e rest[1..2]
    end
    printf '%s' "$out"
end
```

  - `__tcz_popup`: give the switcher its missing footer — in the loop, change the draw call to reserve the bottom row and paint the legend after it:

```fish
        __tcz_popup_draw $sel $listw $prevw (math $rows - 1) "$current" -- $model
        printf '\e[%s;1H\e[K%s' $rows (__tcz_legend_row 12 '↑↓' move '⏎' switch x kill esc close)
```

    (The `x` kill-confirm prompt already paints over row `$rows`; the next loop iteration repaints the legend — no extra handling.)

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` — PASS. Also run `fish tests/test-tmux-popup.fish` (draw suite) — it must stay green (the draw function itself is untouched; only the rows argument at the one call site changed).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(popup): shared aligned key-legend builder + switcher footer; darker sel-bg chrome"`

---

### Task 5: Picker pure builders — kv zone, bold zone separator, tab chip, ShellFish probe

**Files:**
- Modify: `functions/tmux-categorize.fish` — new functions in the thp builder block (after `__tcz_thp_sep` ~L1158); extend `__tcz_thp_row`'s docstring only if touched
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_theme`, `__tcz_thp_bg`, `__tcz_thp_fg`, `__tcz_strip_sgr`, `__tcz_thp_sep`, `__tcz_client_is_shellfish`.
- Produces (Task 6 consumes EXACTLY):
  - `__tcz_thp_zsep <w> <label> <od> <t>` → separator line `├─ LABEL ─…┤`, label BOLD muted; empty label → plain `__tcz_thp_sep`.
  - `__tcz_thp_kv <w> [<label> <value>]...` → TWO lines (uppercase muted labels / values, aligned columns; values may carry SGR).
  - `__tcz_thp_chip <tabshex> <tabsfg> <title>` → chip string `" <title> "` on tabs bg with tabsfg, or EMPTY when tabshex non-hex or title empty.
  - `__tcz_thp_shellfish` → status 0 iff any attached client is ShellFish.

- [ ] **Step 1: Failing tests.**

```fish
# --- v3.1 picker builders ---
set -l zs (__tcz_thp_zsep 50 'adjustments · apply to all schemes' X Y)
set -l zsp (__tcz_strip_sgr "$zs")
t "zsep total width w+2" 52 (string length --visible -- (string trim -- "$zsp"))
t "zsep carries the label" 1 (string match -q '*adjustments · apply to all schemes*' -- "$zsp"; and echo 1; or echo 0)
set -l boldon (printf '\e[1m')
t "zsep label is bold" 1 (string match -q "*$boldon*" -- "$zs"; and echo 1; or echo 0)
set -l zse (__tcz_thp_zsep 50 '' X Y)
t "zsep empty label = plain sep" (__tcz_thp_sep 50 X Y) "$zse"
set -l kv (__tcz_thp_kv 50 seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv emits two lines" 2 (count $kv)
set -l l1 (__tcz_strip_sgr "$kv[1]")
set -l l2 (__tcz_strip_sgr "$kv[2]")
t "kv labels uppercased" 1 (string match -q '*SEED*PHASE*VIVIDNESS*SHAPE*' -- "$l1"; and echo 1; or echo 0)
t "kv values line carries values" 1 (string match -q '*#485b3c*+15°*balanced*arc*' -- "$l2"; and echo 1; or echo 0)
# columns align: each label starts at the same visible offset as its value
t "kv label/value columns align" (string match -rg '^( *)SEED' -- "$l1" | string length) (string match -rg '^( *)#485b3c' -- "$l2" | string length)
set -l ch (__tcz_thp_chip '#626f55' '#111111' 'rocket: tmux-lives (C)')
t "chip renders title on tabs bg" 1 (string match -q '*rocket: tmux-lives (C)*' -- (__tcz_strip_sgr "$ch"); and echo 1; or echo 0)
t "chip empty without tabs color" '' (__tcz_thp_chip '' '#111111' 'x' | string collect)
t "chip empty without title" '' (__tcz_thp_chip '#626f55' '#111111' '' | string collect)
# shellfish probe honors the fake-environ seam through a stubbed tmux
function tmux
    if contains -- list-clients $argv
        echo 4242
        return 0
    end
    command tmux $argv
end
set -g tmux_lives_fake_environ 'LC_TERMINAL=ShellFish'
t "shellfish probe true via seam" 0 (__tcz_thp_shellfish; echo $status)
set -g tmux_lives_fake_environ 'LC_TERMINAL=xterm'
t "shellfish probe false via seam" 1 (__tcz_thp_shellfish; echo $status)
set -e tmux_lives_fake_environ
functions -e tmux
```

(Adjust the two seam tests to the categorize suite's existing `tmux_lives_fake_environ` usage — copy the setup pattern from the existing `__tcz_client_is_shellfish` tests in this file.)

- [ ] **Step 2: Run.** FAIL (functions undefined).

- [ ] **Step 3: Implement** (all in the thp builder block):

```fish
function __tcz_thp_zsep --argument-names w label od t --description 'pure: zone separator ├─ <label> ─…┤ (BOLD muted label; empty label -> plain __tcz_thp_sep). od = border SGR, t = reset.'
    if test -z "$label"
        __tcz_thp_sep $w $od $t
        return
    end
    set -l MUT (__tcz_theme muted)
    set -l len (string length --visible -- "$label")
    set -l fill (math "$w - 3 - $len")
    test $fill -lt 0; and set fill 0
    set -l fillstr (string repeat -n $fill ─)
    printf '%s├─ \e[1m%s%s\e[22m%s %s┤%s\n' $od $MUT "$label" $od "$fillstr" $t
end

function __tcz_thp_kv --argument-names w --description 'pure: labeled adjustments pair — TWO lines (uppercase muted labels / values), columns aligned; argv[2..] = <label> <value> pairs, values may carry SGR (widths measured visible).'
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l lr ' '
    set -l vr ' '
    set -l rest $argv[2..]
    while test (count $rest) -ge 2
        set -l lab (string upper -- $rest[1])
        set -l vplain (__tcz_strip_sgr "$rest[2]")
        set -l lw (string length --visible -- "$lab")
        set -l vw (string length --visible -- "$vplain")
        set -l cw (math "max($lw, $vw) + 3")
        set -l lpad (string repeat -n (math "$cw - $lw") ' ')
        set -l vpad (string repeat -n (math "$cw - $vw") ' ')
        set lr "$lr$MUT$lab$RST$lpad"
        set vr "$vr$rest[2]$RST$vpad"
        set -e rest[1..2]
    end
    printf '%s\n%s\n' "$lr" "$vr"
end

function __tcz_thp_chip --argument-names tabshex tabsfg title --description 'pure: ShellFish tab chip " <title> " on the tabs-role color with the given fg; title truncated to 40 cols; EMPTY when tabshex is non-hex or title is empty (the reserved preview row renders blank).'
    set -l bg (__tcz_thp_bg "$tabshex")
    test -n "$bg"; or return
    test -n "$title"; or return
    set title (string sub -l 40 -- "$title")
    set -l fgS (__tcz_thp_fg "$tabsfg")
    set -l RST (printf '\e[0m')
    printf '%s%s %s %s' "$bg" "$fgS" "$title" "$RST"
end

function __tcz_thp_shellfish --description 'true iff any attached client is ShellFish — the production detection (__tcz_client_is_shellfish; tmux_lives_fake_environ seam applies), checked ONCE at picker open.'
    for pid in (tmux list-clients -F '#{client_pid}' 2>/dev/null)
        __tcz_client_is_shellfish $pid; and return 0
    end
    return 1
end
```

(`cw - lw` and `cw - vw` are ≥ 3, so the inline `string repeat` can never hit the zero-output-collapse hazard — but they are captured into vars anyway, matching house style.)

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` — PASS.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): picker v3.1 pure builders — kv zone, bold zsep, tab chip, shellfish probe"`

---

### Task 6: Picker loop — layout A, 26 rows, a/o/r/d keys, preview/revert

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_readkey` (~L767-781), `__tcz_theme_picker` (~L1245-1589: docstring, init, reload, DELETE reload_one, draw, key dispatch), the modal open site (~L928)
- Modify: `conf.d/tmux-lives-install.fish` — popup heights at the fragment bind (~L162) and CLI open (~L829)
- Test: `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: Task 1 palette (via config-loaded `fish -c`), Task 2 `__tmux_lives_theme_apply_live` explicit-args, Task 4 `__tcz_legend_row`, Task 5 `__tcz_thp_zsep`/`__tcz_thp_kv`/`__tcz_thp_chip`/`__tcz_thp_shellfish`, existing `__tcz_session_title`.
- Produces: `__tcz_popup_readkey` additionally returns `a`, `o`, `r`. Picker popup geometry contract: **-w 52 -h 26, frame EXACTLY 26 rows** at all three open sites.

- [ ] **Step 1: Failing tests.**

In `tests/test-tmux-categorize.fish` (readkey tests follow the existing byte-pipe pattern in this file):

```fish
t "readkey a" a (echo -n a | __tcz_popup_readkey)
t "readkey o" o (echo -n o | __tcz_popup_readkey)
t "readkey r" r (echo -n r | __tcz_popup_readkey)
set -l catsrc (cat $catfile | string collect)
t "guard: no theme_polarity in categorizer" 0 (string match -q '*tmux_lives_theme_polarity*' -- "$catsrc"; and echo 1; or echo 0)
t "guard: no theme_range in categorizer" 0 (string match -q '*tmux_lives_theme_range*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup is 52x26 (modal open site)" 1 (string match -q '*-w 52 -h 26*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x20 anywhere" 0 (string match -q '*-w 52 -h 20*' -- "$catsrc"; and echo 1; or echo 0)
```

In `tests/test-tmux-install.fish` (fragment section):

```fish
t "fragment theme-picker bind is 52x26" 1 (string match -q '*-h 26*theme-picker*' -- "$fr0"; and echo 1; or echo 0)
set -l insrc (cat $plugindir/conf.d/tmux-lives-install.fish | string collect)
t "install: no stale 52x20 theme popup" 0 (string match -q '*-w 52 -h 20*' -- "$insrc"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run both suites.** New tests FAIL.

- [ ] **Step 3: Implement `__tcz_popup_readkey` additions** — three new single-byte cases beside the existing ones (keep comment style):

```fish
        case 61; echo a; return                      # a (theme-picker: apply preview)
        case 6f; echo o; return                      # o (theme-picker: rotate placement)
        case 72; echo r; return                      # r (theme-picker: reset knobs)
```

- [ ] **Step 4: Rework `__tcz_theme_picker`.** Precise change list (the function keeps its overall shape — cleanup handlers, stty discipline, DECSET-2026 atomic paint, coalesced arrow drains all stay):

  1. **Docstring** → `'interactive theme picker (v3.1 layout A): tab-chip + fake-bar preview, labeled global-adjustments zone, 10 scheme rows + off row. ↑↓/jk move, ←→ phase (5°/press, coalesced), v vividness, s shape, e ease, d contrast (auto→lighter→darker), o rotate (0-4), b seed (RGB sliders; t typed hex), a apply preview (no save), ⏎ save (via the CLI, silenced), r reset knobs, Esc/q revert+close. Runs INSIDE a display-popup (-w 52 -h 26); the frame is EXACTLY 26 rows.'`
  2. **Locals**: replace `set -l tl1 0.20` / `set -l tl2 0.92` / `set -l polarity dark` with `set -l contrast auto` / `set -l rotate 0`; add `set -l seedfg '#f5f5f5'` and `set -l previewed 0`.
  3. **`__tcz_thp_init`** — the `fish -c` block's echo lines become (order matters; the index mapping below):

```fish
        set -l init (fish -c '
            echo (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ""))
            echo (__tmux_lives_key tmux_lives_theme mono)
            echo (__tmux_lives_key tmux_lives_theme_phase 0)
            echo (__tmux_lives_key tmux_lives_theme_vividness balanced)
            echo (__tmux_lives_key tmux_lives_theme_shape arc)
            echo (__tmux_lives_key tmux_lives_theme_ease linear)
            echo (__tmux_lives_key tmux_lives_theme_contrast auto)
            echo (__tmux_lives_key tmux_lives_theme_rotate 0)
            echo (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))
            echo (__tmux_lives_contrast_fg (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color "")))' 2>/dev/null)
```

     with the readers: 7→`contrast`, 8→`rotate`, 9→`legacy` (same regex), 10→`seedfg` (only when non-empty).
  4. **`__tcz_thp_reload`** — palette args + a 4th field (tabs contrast fg for the chip):

```fish
        for line in (fish -c '
            for tok in (__tmux_lives_theme_schemes)
                set -l p (__tmux_lives_theme_palette $argv[1] $tok $argv[2] $argv[3] $argv[4] $argv[5] $argv[6] $argv[7])
                test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
                printf "%s|%s|%s|%s\n" $tok (string join " " $p) (__tmux_lives_contrast_fg "$p[6]") (__tmux_lives_contrast_fg "$p[3]")
            end' $seed $phase $viv $shape $ease $contrast $rotate 2>/dev/null)
            set -l f (string split '|' -- $line)
            test -n "$f[1]"; or continue
            set -a toks $f[1]
            set -a pals "$f[2]"
            set -a fgs "$f[3]"
            set -a tabsfgs "$f[4]"
        end
```

     (declare `set -l tabsfgs` beside `toks/pals/fgs`; reset it in the function's clearing line.)
  5. **DELETE `__tcz_thp_reload_one`** (and its `functions -e` at the bottom). The `left`/`right` arms keep their coalescing drains exactly as-is but end with `__tcz_thp_reload` instead of `__tcz_thp_reload_one …` — every knob now refreshes ALL strips (the stale-row artifact was a design bug).
  6. **Chip inputs, once before the loop** (after `set -l host …`):

```fish
    set -l sf 0
    __tcz_thp_shellfish; and set sf 1
    set -l chiptitle ''
    if test $sf -eq 1
        set -l cursess (tmux display-message -p '#{session_name}' 2>/dev/null)
        test -n "$cursess"; and set chiptitle (__tcz_session_title $cursess)
    end
```

  7. **Draw block** — replace the current `lines` assembly (title → info → sep → rows → sep → two footer lines → note → bottom) with layout A, 26 rows. `curpal`/`curfg` selection logic stays; additionally derive the cursor row's tabs color + fg: `set -l curtabs (string split ' ' -- $curpal)[3]` is NOT allowed to use an inline quoted math index — it is a plain var split, fine; for the off row use the legacy band color and `curtabsfg '#f5f5f5'`:

```fish
        set -l ptoks (string split ' ' -- $curpal)
        set -l curtabs "$ptoks[3]"
        set -l curtabsfg '#111111'
        if test $sel -lt $n
            set -l tfidx (math $sel + 1)
            set curtabsfg "$tabsfgs[$tfidx]"
        end
        set -l seedchip (__tcz_thp_bg "$seed")(__tcz_thp_fg "$seedfg")"$seed"(printf '\e[0m')
        set -l B1 (printf '\e[1m')
        set -l B0 (printf '\e[22m')
        # NB: fish does NOT interpret \e inside quoted strings (only printf does) —
        # the bold SGRs must be printf-captured vars, never "\e[1m" literals.
        set -l lines
        set -a lines $BORDER"╭─ $B1"$BRAND"theme$B0"$BORDER" ─ preview "(string repeat -n (math "$IW - 18") ─)"╮"$RST
        set -a lines (__tcz_thp_ln (__tcz_thp_chip "$curtabs" "$curtabsfg" "$chiptitle") $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_thp_preview "$curpal" "$curfg" "$host" Monitoring $IW) $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW 'adjustments · apply to all schemes' $BORDER $RST)
        set -l kv1 (__tcz_thp_kv $IW seed "$seedchip" phase "+$phase°" vividness "$viv" shape "$shape")
        set -a lines (__tcz_thp_ln "$kv1[1]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln "$kv1[2]" $IW $BORDER $RST)
        set -l kv2 (__tcz_thp_kv $IW contrast "$contrast" rotate "$rotate" ease "$ease")
        set -a lines (__tcz_thp_ln "$kv2[1]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln "$kv2[2]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW 'scheme · companion sets for the seed' $BORDER $RST)
        # ... the existing 10 scheme rows + off row loop, UNCHANGED ...
        set -a lines (__tcz_thp_zsep $IW '' $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 '↑↓' scheme '←→' phase v vivid s shape) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 e ease d contrast o rotate b seed) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 a apply '⏎' save r reset esc close) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln " $MUTED$note$RST" $IW $BORDER $RST)
        set -a lines $BORDER"╰"(string repeat -n $IW ─)"╯"$RST
```

     Row count: 1 title + 1 chip + 1 preview + 1 zsep + 4 kv + 1 zsep + 10 schemes + 1 off + 1 zsep + 3 legend + 1 note + 1 bottom = **26**. The existing atomic-paint emitter (`lines[1..-2]` with `\n`, last row without) is unchanged. Footer wording note: `vivid` is deliberately short so every cell fits pitch 12 within IW 50; the labeled VIVIDNESS field above carries the full word.
  8. **Key dispatch**: `case d` becomes a three-state cycle + reload; add `o`, `a`, `r`; `enter`/`cancel` gain the preview semantics; `left`/`right` per item 5:

```fish
            case d
                switch "$contrast"
                    case auto;    set contrast lighter
                    case lighter; set contrast darker
                    case '*';     set contrast auto
                end
                __tcz_thp_reload
            case o
                set rotate (math "($rotate + 1) % 5")
                __tcz_thp_reload
            case r
                set phase 0; set viv balanced; set shape arc; set ease linear
                set contrast auto; set rotate 0
                set note 'knobs reset (not saved — ⏎ to save)'
                __tcz_thp_reload
            case a
                set -l ptok off
                test $sel -lt $n; and begin; set -l pi (math $sel + 1); set ptok $toks[$pi]; end
                fish -c '__tmux_lives_theme_apply_live $argv' $ptok $phase $viv $shape $ease $contrast $rotate >/dev/null 2>&1
                set previewed 1
                set note "● previewing $ptok — not saved · ⏎ save · esc revert"
            case enter
                if test $sel -lt $n
                    set apply $toks[(math $sel + 1)]
                else
                    set apply off
                end
                break
            case cancel
                if test $previewed -eq 1
                    fish -c __tmux_lives_theme_apply_live >/dev/null 2>&1
                end
                break
```

     (`$toks[(math $sel + 1)]` UNQUOTED — the sanctioned index form; the grep-guard bans only the quoted variant.)
  9. **Enter apply args** (after the loop, where the CLI is invoked): the flag list becomes `--phase $phase --vividness $viv --shape $shape --ease $ease --contrast $contrast --rotate $rotate` (drop `--polarity`).

- [ ] **Step 5: The three open sites** → `-w 52 -h 26`: `conf.d/tmux-lives-install.fish` L162 (fragment bind) and L829 (CLI no-arg), `functions/tmux-categorize.fish` L928 (modal `k`).

- [ ] **Step 6: Run both suites.** `fish tests/test-tmux-categorize.fish` and `fish tests/test-tmux-install.fish` — ALL PASS.

- [ ] **Step 7: Commit.** `git add -A && git commit -m "feat(theme): picker layout A — 26-row frame, labeled zones, tab chip, a/o/r keys, preview+revert"`

---

### Task 7: Seed screens — big swatch + shared legend

**Files:**
- Modify: `functions/tmux-categorize.fish` — new pure `__tcz_thp_swatch` in the builder block; `__tcz_thp_hexentry` (~L1315-1361) and `__tcz_thp_sliders` (~L1362-1441) draw sections
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_bg`, `__tcz_theme`, `__tcz_legend_row`.
- Produces: `__tcz_thp_swatch <hex> <hue> <L> <C>` → FOUR lines: 12-col color band + 2 spaces + text (line 1 hex bold; line 2 `hue N° · L 0.NN · chroma 0.NNN`; lines 3-4 the copy `rendered as-is on the bar;` / `companions derive from it`). Non-hex → four 12-col blank-gap lines with empty text.

- [ ] **Step 1: Failing tests.**

```fish
set -l sw (__tcz_thp_swatch '#485b3c' 134 0.45 0.054)
t "swatch emits 4 lines" 4 (count $sw)
t "swatch line1 carries bold hex" 1 (string match -q '*#485b3c*' -- (__tcz_strip_sgr "$sw[1]"); and echo 1; or echo 0)
t "swatch line2 readouts" 1 (string match -q '*hue 134° · L 0.45 · chroma 0.054*' -- (__tcz_strip_sgr "$sw[2]"); and echo 1; or echo 0)
t "swatch line3 copy" 1 (string match -q '*rendered as-is on the bar*' -- (__tcz_strip_sgr "$sw[3]"); and echo 1; or echo 0)
set -l swe (__tcz_thp_swatch '' '' '' '')
t "swatch non-hex still 4 lines" 4 (count $swe)
# the dead hue-only contract line is gone from the categorizer
set -l catsrc2 (cat $catfile | string collect)
t "guard: hue-only copy retired" 0 (string match -q '*only its HUE drives the theme*' -- "$catsrc2"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run.** FAIL.

- [ ] **Step 3: Implement.**

```fish
function __tcz_thp_swatch --argument-names hex hue L C --description 'pure: 4-line big seed swatch — 12-col color band + readouts (hex bold / hue·L·chroma / the seed-IS-the-bar copy). Non-hex hex -> blank band, empty text.'
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l band '            '
    set -l bg (__tcz_thp_bg "$hex")
    test -n "$bg"; and set band "$bg            $RST"
    set -l t1 ''
    set -l t2 ''
    if test -n "$bg"
        set t1 (printf '\e[1m%s\e[22m' "$hex")
        set t2 "$MUT""hue $hue° · L $L · chroma $C$RST"
    end
    printf '%s\n' "$band  $t1" "$band  $t2" "$band  $MUT""rendered as-is on the bar;$RST" "$band  $MUT""companions derive from it$RST"
end
```

  - **Sliders** (`__tcz_thp_sliders`): the readout `fish -c` on settle now returns three values — replace the `hue` computation with:

```fish
                set -l ro (fish -c 'set -l rgb (__tmux_lives_hex_to_rgb01 $argv[1]); set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]); printf "%.0f %.2f %.3f" $ok[3] $ok[1] $ok[2]' $hex 2>/dev/null)
                set -l rop (string split ' ' -- "$ro")
                set hue "$rop[1]"; set okl "$rop[2]"; set okc "$rop[3]"
```

    (declare `set -l okl ''` / `set -l okc ''` beside `hue`), and the frame printf becomes title + 3 sliders + blank + the 4 swatch lines + legend:

```fish
            set -l sw4 (__tcz_thp_swatch $hex "$hue" "$okl" "$okc")
            set -l leg1 (__tcz_legend_row 14 '↑↓' channel '←→' adjust t 'type hex')
            set -l leg2 (__tcz_legend_row 14 '⏎' apply esc cancel)
            printf '\e[?2026h\e[H \e[1mseed — this IS the bar color\e[22m\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n%s\e[K\n%s\e[K' "$row1" "$row2" "$row3" $sw4[1] $sw4[2] $sw4[3] $sw4[4] "$leg1" "$leg2"
            printf '\e[J\e[?2026l'
```

  - **Hex entry** (`__tcz_thp_hexentry`): same treatment — extend the parse-complete `fish -c` to the three-value readout (same snippet as above, on `$cand`), keep the buffer line, and replace the paint with:

```fish
                    set -l sw4 (__tcz_thp_swatch "$cand" "$hue" "$okl" "$okc")
                    set -l leg (__tcz_legend_row 14 '⏎' apply esc cancel)
                    printf '\e[?2026h\e[H \e[1mseed — this IS the bar color\e[22m\e[K\n #%s_\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n%s\e[K' "$buf" $sw4[1] $sw4[2] $sw4[3] $sw4[4] "$leg"
                    printf '\e[J\e[?2026l'
```

    (declare `okl`/`okc` locals; reset all three to `''` at the top of each loop iteration beside the existing `set cand ''`/`set hue ''`.)

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` — PASS.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): seed screens — big swatch block + hue/L/chroma readouts, shared legend footers"`

---

### Task 8: Docs + full-suite gate

**Files:**
- Modify: `README.md` (Theming section), `CLAUDE.md` (status paragraph)

- [ ] **Step 1: README Theming section.** Update to state: a scheme is a set of COMPANION colors for the seed — the seed itself IS the status-bar background in every scheme (v3.1); companions cluster around it and only text jumps for contrast; document `--contrast auto|lighter|darker` and `--rotate 0-4` (replacing `--polarity`/`--range` — note the automatic migration on `fisher update`); picker keys now include `a` apply-preview, `r` reset, `o` rotate, `d` contrast; the picker shows a ShellFish tab chip when a ShellFish client is attached.

- [ ] **Step 2: CLAUDE.md.** Append to the theme-v3 paragraph: v3.1 seed-anchored redesign (spec `2026-07-17-theme-seed-anchored-design.md`) — bar = seed verbatim, clustered companions, contrast auto/lighter/darker + rotate 0-4 (fragment argv 18/19; polarity/range erased by `__tmux_lives_migrate_v31`), picker layout A 52×26 (labeled kv zones, tab chip, a/o/r keys, preview/revert), shared `__tcz_legend_row` footers incl. the session switcher, big seed swatch. Note the pending live smoke.

- [ ] **Step 3: Full-suite gate.** `fish -c 'for t in tests/test-*.fish; fish $t; end'` — **all 8 suites ALL PASS** (this is the merge gate).

- [ ] **Step 4: Commit.** `git add -A && git commit -m "docs: theme v3.1 — seed-anchored README/CLAUDE.md"`

---

## Post-plan (not tasks)

- Final code review (opus) on the whole branch, then `superpowers:finishing-a-development-branch` (house default: merge to main + push).
- Ask the user before pruning `2026-07-16-theme-polarity-seed-entry-design.md` (repo + vault).
- Runtime-only, deferred to the user's live smoke after `fisher update`: raw-tty feel of a/o/r/d, chip on a real ShellFish attach, 52×26 geometry at all three sites, preview/revert on the real bar.
