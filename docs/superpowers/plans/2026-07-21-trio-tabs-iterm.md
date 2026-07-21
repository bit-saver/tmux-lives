# Trio Tabs + iTerm2 Mirroring (v3.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabs derive as kin of the bar+cap pair (one harmonious trio), the seed's home base moves to the ✦ mark, fire's blue bar becomes warm, the claude window loses its coral tint, and iTerm2 tabs mirror the ShellFish look (per-theme color + title).

**Architecture:** Engine (`conf.d/tmux-lives-install.fish`): pure `__tmux_lives_theme_kintabs` + palette tabs swap + fire barpos + fragment edits (mark=seed, claude decolor). Categorizer (`functions/tmux-categorize.fish`): preview decolor, `__tcz_client_terminal` detection, `__tcz_emit_itermtab`, iTerm branches beside every ShellFish emission site.

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's `t` harness, `tmux_lives_fake_environ` seam.

**Spec:** `docs/superpowers/specs/2026-07-21-trio-tabs-iterm-design.md` — read it first.

## Global Constraints

- Deploy = user's `fisher update` ONLY; no user-universal writes outside guards; never kill a suite; tmux-driving tests pin the socket seam; `fish --no-config` cross-checks (plain runs flattered by the live install).
- fish gotchas (guard-enforced): no command substitution inside quoted math (capture first); `"$x[(math …)]"` banned; zero-output substitution as a bare set arg vanishes (capture-and-quote); no comparisons in `math`; SGR/OSC escapes via printf format strings or printf-captured vars; comments must not contain `fish -c` or banned-pattern literals.
- Exact values: kintabs hue = barH + circularΔH(bar→cap)/2; L = barL + dir·0.16 (dir: +1 if barL < 0.55 else −1), clamp [0.05,0.95]; C = the CAP's C. fire barpos: t 0.05 → **0.95** (ΔL −0.03, capC '' unchanged). Trio predicate: ΔH(bar,tabs) ≤ 30°, ΔL(bar,tabs) ∈ [0.10,0.22], |tabsC − capC| ≤ 0.02. iTerm tab OSC: `\e]6;1;bg;red;brightness;R\a` (+green/+blue, decimal 0-255); reset `\e]6;1;bg;*;default\a`. `LC_TERMINAL` values: `ShellFish` → `shellfish`, `iTerm2` → `iterm2`, else `other`.
- Vocabulary: "scheme"; user-facing copy never says palette/token.
- Commit per task; push at branch completion.

## File Structure

- `conf.d/tmux-lives-install.fish` — Tasks 1-2.
- `functions/tmux-categorize.fish` — Tasks 2 (preview decolor) and 3.
- `tests/test-tmux-install.fish`, `tests/test-tmux-categorize.fish` — per task.
- `README.md`, `CLAUDE.md` — Task 4.

Branch: `git checkout -b feat/trio-tabs-iterm` (from current `main`).

---

### Task 1: Engine — `__tmux_lives_theme_kintabs`, palette tabs swap, fire fix

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — new `__tmux_lives_theme_kintabs` after `__tmux_lives_theme_kincap`; the palette's tabs derivation (~L780, search `tabs: home base`); `__tmux_lives_theme_barpos` fire line
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: existing converters + `__tmux_lives_theme_kincap`/`_barpos`/`_palette`.
- Produces: `__tmux_lives_theme_kintabs <barhex> <caphex>` → one tabs hex (empty on non-hex input). Palette output contract unchanged (7 roles); tabs is now kin-derived for ALL schemes incl. mono (the mono-ring1 special case is DELETED).

- [ ] **Step 1: Failing tests.** In the install suite's theme section: UPDATE `"v32 tabs wear the seed"` and DELETE `"v32 mono tabs = ring pos 1"`; add:

```fish
# --- v3.3 kin-ramp trio ---
function __tlt_okl3 --argument-names hex
    set -l rgb (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3]
end
set -l kt (__tmux_lives_theme_kintabs '#157058' '#1c868e')
t "kintabs returns a hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- "$kt"; and echo 1; or echo 0)
set -l bo3 (__tlt_okl3 '#157058')
set -l co3 (__tlt_okl3 '#1c868e')
set -l to3 (__tlt_okl3 $kt)
set -l dhbt (math "$to3[3] - $bo3[3]")
test $dhbt -gt 180; and set dhbt (math "$dhbt - 360")
test $dhbt -lt -180; and set dhbt (math "$dhbt + 360")
set -l dhbc (math "$co3[3] - $bo3[3]")
test $dhbc -gt 180; and set dhbc (math "$dhbc - 360")
test $dhbc -lt -180; and set dhbc (math "$dhbc + 360")
t "kintabs hue is halfway to the cap" 1 (test (math "abs($dhbt - $dhbc / 2)") -le 3; and echo 1; or echo 0)
t "kintabs one step lighter than a dark bar" 1 (test (math "$to3[1] - $bo3[1]") -ge 0.14 -a (math "$to3[1] - $bo3[1]") -le 0.18; and echo 1; or echo 0)
t "kintabs wears the cap chroma" 1 (test (math "abs($to3[2] - $co3[2])") -le 0.02; and echo 1; or echo 0)
t "kintabs empty on junk" 0 (count (__tmux_lives_theme_kintabs red '#1c868e'))
# palette: tabs are kin for EVERY scheme (mono too); trio predicate on the panel
set -l seedhex3 '#576733'
set -l pw3 (__tmux_lives_theme_palette $seedhex3 wide 0 balanced arc linear auto 0)
t "v33 tabs no longer wear the seed" 0 (test "$pw3[3]" = $seedhex3; and echo 1; or echo 0)
set -l pm3 (__tmux_lives_theme_palette $seedhex3 mono 0 balanced arc linear auto 0)
set -l ring3 (__tmux_lives_theme_ring $seedhex3 mono 0 balanced arc linear auto)
t "v33 mono tabs are kin too (ring1 special case gone)" 0 (test "$pm3[3]" = "$ring3[1]"; and echo 1; or echo 0)
t "v33 mono tabs = kintabs(bar,cap)" (__tmux_lives_theme_kintabs $pm3[1] $pm3[6]) $pm3[3]
set -l trio_ok 1
for ps in '#576733' '#223344' '#d8cfa8' '#7e8280' '#d02090'
    for tok in (__tmux_lives_theme_schemes)
        set -l pp (__tmux_lives_theme_palette $ps $tok 0 balanced arc linear auto 0)
        test (count $pp) -eq 7; or begin; set trio_ok 0; break; end
        set -l pb (__tlt_okl3 $pp[1])
        set -l pt (__tlt_okl3 $pp[3])
        set -l pc (__tlt_okl3 $pp[6])
        set -l d1 (math "$pt[3] - $pb[3]")
        test $d1 -gt 180; and set d1 (math "$d1 - 360")
        test $d1 -lt -180; and set d1 (math "$d1 + 360")
        test (math "abs($d1)") -le 30; or set trio_ok 0
        set -l dl (math "abs($pt[1] - $pb[1])")
        test $dl -ge 0.10; or set trio_ok 0
        test $dl -le 0.22; or set trio_ok 0
        test (math "abs($pt[2] - $pc[2])") -le 0.02; or set trio_ok 0
    end
end
t "v33 trio predicate holds across the seed panel" 1 $trio_ok
# fire is warm now
set -l pf3 (__tmux_lives_theme_palette $seedhex3 fire 0 balanced arc linear auto 0)
set -l fo3 (__tlt_okl3 $pf3[1])
t "v33 fire bar lands warm gold" 1 (test $fo3[3] -ge 60 -a $fo3[3] -le 110; and echo 1; or echo 0)
t "barpos fire t is 0.95" 0.95 (__tmux_lives_theme_barpos fire)[1]
functions -e __tlt_okl3
```

(Also update the existing `"barpos fire lands warm-side" 0.05` pin → expect `0.95`; delete/adjust any pin capturing fire's old blue bar hex.)

- [ ] **Step 2: Run.** `fish tests/test-tmux-install.fish` — FAIL.

- [ ] **Step 3: Implement.** After `__tmux_lives_theme_kincap`:

```fish
function __tmux_lives_theme_kintabs --argument-names barhex caphex --description 'v3.3 trio: the tab-bar color as kin of the bar+cap pair — hue halfway from bar to cap (circular), L one step (0.16) toward the light side of a dark bar, chroma from the cap (muted caps -> muted tabs). The ShellFish/iTerm tab strip stacks directly on the status bar, so the pair must satisfy the calibrated kinship rule by construction.'
    set -l brgb (__tmux_lives_hex_to_rgb01 $barhex)
    test (count $brgb) -eq 3; or return
    set -l bo (__tmux_lives_rgb_to_oklch $brgb[1] $brgb[2] $brgb[3])
    set -l crgb (__tmux_lives_hex_to_rgb01 $caphex)
    test (count $crgb) -eq 3; or return
    set -l co (__tmux_lives_rgb_to_oklch $crgb[1] $crgb[2] $crgb[3])
    set -l dh (math "$co[3] - $bo[3]")
    test $dh -gt 180; and set dh (math "$dh - 360")
    test $dh -lt -180; and set dh (math "$dh + 360")
    set -l dir 1
    test $bo[1] -ge 0.55; and set dir -1
    set -l L (math "$bo[1] + $dir * 0.16")
    test $L -lt 0.05; and set L 0.05
    test $L -gt 0.95; and set L 0.95
    __tmux_lives_oklch_hex $L $co[2] (__tmux_lives_norm360 (math "$bo[3] + $dh / 2"))
end
```

(NB `__tmux_lives_hex_to_rgb01` on junk: check its actual behavior — if it returns nothing the `count -eq 3` guard returns empty as the test expects; if it errors, guard with a hex regex like kincap's callers instead. Match the file's existing convention.)

Palette: replace

```fish
    # tabs: home base — the seed verbatim; mono would duplicate the bar, so ring 1
    set -l tabs (string lower -- $seedHex)
    test "$bp[1]" = seed; and set tabs $ring[1]
```

with

```fish
    # tabs: kin of the bar+cap pair (v3.3 trio — the tab strip stacks on the bar)
    set -l tabs (__tmux_lives_theme_kintabs $bar $cap)
    test -n "$tabs"; or return
```

Barpos: `case fire;       printf '%s\n' 0.95 -0.03 ''` (docstring: fire = the warm arc end).

- [ ] **Step 4: Run.** Install suite plain + `--no-config` — ALL PASS. Run the categorize suite once: any tabs-related pins there (picker fg contract etc.) surface — update stale expectations preserving intent; list in report.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): v3.3 kin-ramp tabs — one harmonious trio; fire bar lands warm"`

---

### Task 2: Mark = seed home base + claude decolor (fragment, apply-live, preview)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — fragment render (~L96-101 window-status conditionals, ~L137 claude_color seed, mark_fg line ~L127) + `__tmux_lives_theme_apply_live` mark push (~L800s)
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_preview` (~L1169 coral)
- Test: `tests/test-tmux-install.fish`, `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Task 1 palette (unchanged shape).
- Produces: fragment + apply-live emit `@tmux_lives_mark_fg` = the SEED hex (themed branch; legacy branch unchanged); `window-status-format` = plain `#W`; `window-status-current-format` = `#[bold]#[fg=#{@tmux_lives_text_fg}]#W#[fg=default]#[nobold]`; no `@tmux_lives_claude_color` anywhere; preview renders `claude` in the windows-role color like any window.

- [ ] **Step 1: Failing tests.** Install suite (fragment section — reuse its existing themed render var, e.g. `$fr0`-style):

```fish
# v3.3: the ✦ mark is the seed's home base; claude coloring removed
set -l fr33 (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k wide 0 balanced arc linear auto 0 | string collect)
t "fragment mark_fg is the seed verbatim" 1 (string match -q "*@tmux_lives_mark_fg '#485b3c'*" -- "$fr33"; and echo 1; or echo 0)
t "fragment window-status-format is plain" 1 (string match -q "*set -g window-status-format '#W'*" -- "$fr33"; and echo 1; or echo 0)
t "fragment drops claude_color" 0 (string match -q '*claude_color*' -- "$fr33"; and echo 1; or echo 0)
set -l insrc33 (cat $plugindir/conf.d/tmux-lives-install.fish | string collect)
t "guard: no claude_color in install source" 0 (string match -q '*claude_color*' -- "$insrc33"; and echo 1; or echo 0)
```

Categorize suite:

```fish
t "guard: preview coral gone" 0 (string match -q '*D97757*' -- (cat $catfile | string collect); and echo 1; or echo 0)
```

Check for apply-live mark coverage: add (inside the socket-pinned apply-live block, following its existing pattern):

```fish
t "apply-live mark_fg is the seed" '#485b3c' (command tmux -L $thsock show -gv @tmux_lives_mark_fg)
```

(Adapt the socket var/seed to the section's actual fixture values — read the surrounding tests.)

- [ ] **Step 2: Run.** FAIL.

- [ ] **Step 3: Implement.**
  - Fragment: `window-status-format` line → `set -a f "set -g window-status-format '#W'"`; `window-status-current-format` → `set -a f "set -g window-status-current-format '#[bold]#[fg=#{@tmux_lives_text_fg}]#W#[fg=default]#[nobold]'"`; DELETE the `@tmux_lives_claude_color` seed line and the tint comment block (~L96-99), replacing with a one-line comment `# claude windows render like any other (coloring removed 2026-07-21; the ✦ presence mark remains)`; the themed mark line → `set -a f "set -g @tmux_lives_mark_fg '$seedhex'"` (the themed branch has `$seedhex` in scope; legacy branch unchanged).
  - Apply-live: `__tmux_lives_theme_push @tmux_lives_mark_fg $tpal[6]` → `__tmux_lives_theme_push @tmux_lives_mark_fg $seed` (apply-live's `$seed` local).
  - Preview (`__tcz_thp_preview`): delete `set -l coral (__tcz_thp_fg '#D97757')`; the `claude` segment renders with `$winfg` (the windows-role fg already computed there) instead of `$coral`.
  - Sweep stale claude-color mentions: any fragment/README comment naming coral in these files' touched regions (full README pass is Task 4).

- [ ] **Step 4: Run.** Both suites plain + `--no-config` — ALL PASS (fix any stale window-status pins the run surfaces; list in report).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): seed home base moves to the ✦ mark; claude window coloring removed"`

---

### Task 3: iTerm2 mirroring — detection + emission + wiring

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_client_terminal` beside `__tcz_client_is_shellfish` (~L94); new `__tcz_emit_itermtab` beside `__tcz_emit_barcolor`; iTerm branches in `__tcz_recolor`, `__tcz_on_attach`, `__tcz_retitle` (read each function fully first — mirror its ShellFish branch shape, incl. dedup-cache reads/writes and force/dedup modes)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: existing `__tcz_pid_environ` (+ `tmux_lives_fake_environ` seam), `__tcz_tab_color`, `__tcz_emit_key/_get/_set` dedup caches, `__tcz_session_title`.
- Produces: `__tcz_client_terminal <pid>` → `shellfish|iterm2|other`; `__tcz_client_is_shellfish <pid>` → wrapper (`test (__tcz_client_terminal $pid) = shellfish`); `__tcz_emit_itermtab <tty> <hex>` → the OSC 6 triplet (reset form on non-hex).

- [ ] **Step 1: Failing tests** (follow the existing `__tcz_client_is_shellfish` seam-test pattern for the environ stubs):

```fish
# --- v3.3 iTerm2 mirroring ---
set -g tmux_lives_fake_environ 'LC_TERMINAL=iTerm2'
t "client_terminal detects iTerm2" iterm2 (__tcz_client_terminal 4242)
t "is_shellfish false for iTerm2" 1 (__tcz_client_is_shellfish 4242; echo $status)
set -g tmux_lives_fake_environ 'LC_TERMINAL=ShellFish'
t "client_terminal detects ShellFish" shellfish (__tcz_client_terminal 4242)
t "is_shellfish wrapper still true" 0 (__tcz_client_is_shellfish 4242; echo $status)
set -g tmux_lives_fake_environ 'TERM=xterm-256color'
t "client_terminal other" other (__tcz_client_terminal 4242)
set -e tmux_lives_fake_environ
# emit_itermtab escape bytes (write to a temp file standing in for the tty)
set -l tf (mktemp)
__tcz_emit_itermtab $tf '#576733'
set -l want (printf '\e]6;1;bg;red;brightness;87\a\e]6;1;bg;green;brightness;103\a\e]6;1;bg;blue;brightness;51\a' | string escape)
t "itermtab triplet exact" "$want" (cat $tf | string escape)
__tcz_emit_itermtab $tf notahex
set -l wantr (printf '\e]6;1;bg;*;default\a' | string escape)
t "itermtab reset on non-hex" "$wantr" (cat $tf | string escape)
rm -f $tf
# wiring pins: each emission path has an iterm2 branch
set -l catsrc4 (cat $catfile | string collect)
t "recolor handles iterm2" 1 (string match -qr '(?s)function __tcz_recolor.*iterm2.*^end' -- "$catsrc4"; and echo 1; or echo 0)
t "on-attach handles iterm2" 1 (string match -qr '(?s)function __tcz_on_attach.*iterm2.*^end' -- "$catsrc4"; and echo 1; or echo 0)
t "retitle handles iterm2" 1 (string match -qr '(?s)function __tcz_retitle.*iterm2.*^end' -- "$catsrc4"; and echo 1; or echo 0)
```

(The `(?s)…^end` body-scoped regexes are approximate — tighten to the same body-extraction style the suite already uses (`awk '/^function X/,/^end$/'`) if the multiline form misbehaves; note the choice in the report. Verify `#576733` → R=87 G=103 B=51 decimal.)

- [ ] **Step 2: Run.** FAIL.

- [ ] **Step 3: Implement.**

```fish
function __tcz_client_terminal --argument-names pid --description 'client pid -> shellfish|iterm2|other, from LC_TERMINAL in the client process environ (__tcz_pid_environ; tmux_lives_fake_environ seam). The terminals that take per-tab color/title escapes.'
    set -l lct (__tcz_pid_environ $pid | string match -r '^LC_TERMINAL=(.*)$')
    set -l val ''
    test (count $lct) -ge 2; and set val $lct[2]
    switch "$val"
        case ShellFish
            echo shellfish
        case iTerm2
            echo iterm2
        case '*'
            echo other
    end
end
```

`__tcz_client_is_shellfish` body → `test (__tcz_client_terminal $argv[1]) = shellfish` (keep its docstring, note the wrapper). NB: read the CURRENT is_shellfish implementation first — if its environ parsing differs (e.g. exact-match `string match -q 'LC_TERMINAL=ShellFish'`), port that exact parsing into `__tcz_client_terminal` so behavior is identical for the shellfish case.

```fish
function __tcz_emit_itermtab --argument-names tty hex --description 'write iTerm2 tab-color escapes (OSC 6 triplet) to a client tty; non-hex -> the reset escape. The iTerm side of the ShellFish bar-color mirror.'
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$hex")
    if test (count $m) -eq 3
        set -l r (math "0x$m[1]")
        set -l g (math "0x$m[2]")
        set -l b (math "0x$m[3]")
        printf '\e]6;1;bg;red;brightness;%d\a\e]6;1;bg;green;brightness;%d\a\e]6;1;bg;blue;brightness;%d\a' $r $g $b > $tty 2>/dev/null
    else
        printf '\e]6;1;bg;*;default\a' > $tty 2>/dev/null
    end
end
```

Wiring — for each of `__tcz_recolor`, `__tcz_on_attach`, `__tcz_retitle`: READ the whole function, find where it branches on `__tcz_client_is_shellfish` (or equivalent), and restructure to `switch (__tcz_client_terminal $pid)`: `case shellfish` = the existing branch VERBATIM; `case iterm2` = the same flow with `__tcz_emit_itermtab $tty (__tcz_tab_color …)` instead of the ShellFish bar-color emit and the SAME OSC 2 title emit + the SAME dedup-cache reads/writes (the cache stores the resolved color/title, terminal-agnostic); `case '*'` = the existing non-ShellFish behavior (incl. the baseline re-source in on-attach — iterm2 must NOT trigger the baseline step, only the emissions; structure on-attach so iterm2 emits color+title then skips baseline). Where a function takes the color as an arg (the tick's baked `'$color'`), the iterm2 branch resolves via `__tcz_tab_color` the same way the shellfish branch does. Preserve force/dedup modes exactly.

- [ ] **Step 4: Run.** Categorize suite plain + `--no-config`; install suite once; then the full 8-suite gate once — ALL PASS.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): iTerm2 tabs mirror the ShellFish look — OSC 6 tab color + title per client"`

---

### Task 4: Docs + full-suite gate

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: README.** Theming section: tabs now derive with the bar and endcaps as one harmonious trio (halfway hue, one step lighter, cap's chroma); your seed's home base is the ✦ mark (plus `mono` and the picker's anchor row); iTerm2 tabs get the theme color + title automatically (same detection as ShellFish, via `LC_TERMINAL`); the claude window renders like any other window (the ✦/`(C)` presence indicators remain). Remove any coral/claude-color mention. "scheme" vocabulary; no unrelated rewrap.

- [ ] **Step 2: CLAUDE.md.** Append one dense sentence to the theme paragraph: v3.3 trio (spec `2026-07-21-trio-tabs-iterm-design.md`) — kin-ramp tabs (`__tmux_lives_theme_kintabs`, user-picked from a live-computed stacked mock; mono-ring1 case gone), mark_fg = seed home base, fire barpos 0.05→0.95 (spec-authoring bug: wrong arc end shipped a BLUE fire bar), claude coral removed (presence ✦ stays), iTerm2 mirroring (`__tcz_client_terminal` + `__tcz_emit_itermtab` OSC 6 triplet, wired beside every ShellFish emission incl. dedup/heal; baseline re-source untouched for iterm2); live smoke pending.

- [ ] **Step 3: THE GATE.** `fish -c 'for t in tests/test-*.fish; fish $t; end'` AND the `--no-config` variant — all 8 ALL PASS; report both.

- [ ] **Step 4: Commit.** `git add -A && git commit -m "docs: v3.3 trio + iTerm2 mirroring — README/CLAUDE.md"`

---

## Post-plan (not tasks)

- Final whole-branch review (opus) → finishing-a-development-branch (merge + push).
- Live smoke (user, after `fisher update`): the stacked trio on ShellFish, iTerm2 tab color+title over SSH, warm fire, plain claude window, ✦ in seed color; plus the still-pending v3.2 items (varied bars, phase-as-bar-knob).
