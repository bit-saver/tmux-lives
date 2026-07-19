# Picker Anchor Row + Shake Key + Lit-First Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The theme picker pins the user's persisted theme as a frozen, re-appliable anchor row (with a `❯` current indicator on the matching list row), gains a `z` shake key (random scheme + phase + rotate), and lights the changed knob field up BEFORE the recompute starts.

**Architecture:** All changes in `functions/tmux-categorize.fish` — pure-builder extensions first (`__tcz_thp_row`/`__tcz_thp_off_row` current flag, kv multi-field flash, readkey `z`), then the picker loop (anchor snapshot + 0-based-anchor indexing + 27-row frame), then the `z` dispatch + legend, then the nested `__tcz_thp_litkv` repaint. The engine and CLI are untouched.

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's `t "<desc>" <expected> <got>` harness.

**Spec:** `docs/superpowers/specs/2026-07-19-picker-anchor-shake-design.md` — read it first.

## Global Constraints

- Deploy = the user's `fisher update` ONLY; never touch `~/.config/fish/` or the user's universals outside test guards; never kill a running suite; tests driving `tmux` pin the socket seam.
- **fish --no-config (the picker's runtime) neither READS nor WRITES universal variables** — every universal-touching action goes through a config-loaded `fish -c` child. The picker-body `fish -c` count is guard-pinned at 7; Task 2's anchor/else split of `case a` adds one TEXTUAL site (still one subprocess per user action), so Task 2 updates the guard's expected count to **8** deliberately, with a comment. No other task may change it.
- fish gotchas: `"$x[(math …)]"` BANNED (unquoted/via-var); zero-output command substitution as a bare `set` argument VANISHES (capture-and-quote); no comparisons inside `math`; SGR escapes via printf-captured vars only; drain loops re-assert stty INSIDE each iteration; frame last row without `\n`; comments must not contain the literal `fish -c` (inflates the count guard).
- Exact values: current-marker SGR = `\e[38;5;179m` (COPY of the switcher's `$YEL` — do not invent a shade); frame = EXACTLY **27** rows; popup `-w 52 -h 27` at ALL THREE open sites; shake = `z` (readkey byte `7a`); shake randomizes `sel (random 1 $n)`, `phase (math "(random 0 71) * 5")`, `rotate (random 0 4)`; multi-flash separator = a single space; kv rows sit at frame rows 5-8.
- Suites: `fish tests/test-tmux-categorize.fish`; full gate `fish -c 'for t in tests/test-*.fish; fish $t; end'` AND the same under `fish --no-config -c` (plain runs can be flattered by the live fisher install).
- Commit after every task; push at branch completion.

## File Structure

- `functions/tmux-categorize.fish` — all four tasks.
- `tests/test-tmux-categorize.fish` — all new tests.
- `README.md`, `CLAUDE.md` — folded into Task 4.

Branch: `git checkout -b feat/picker-anchor-shake` (from current `main`).

---

### Task 1: Builders — row `current` flag, off-row name/current args, kv multi-flash, readkey `z`

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_row` (~L1090), `__tcz_thp_off_row` (~L1108), `__tcz_thp_kv` (~L1192 — the flash-match lines), `__tcz_popup_readkey` (~L769 docstring + byte cases)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces (Tasks 2-3 consume EXACTLY):
  - `__tcz_thp_row <hexes> <name> <selected> [current]` — `current` = 1 prefixes the name with `❯ ` in `\e[38;5;179m`; +2 visible cols; works with and without selection.
  - `__tcz_thp_off_row <barhex> <selected> [name] [current]` — arg 3 overrides the default label `off — legacy look`; arg 4 = the same `❯ ` prefix.
  - `__tcz_thp_kv <w> <flashfield> [<label> <value>]…` — `flashfield` is now a SPACE-JOINED LIST; a pair flashes when its lowercased label is contained in the split list.
  - `__tcz_popup_readkey`: byte `7a` → token `z`.

- [ ] **Step 1: Write the failing tests** (beside the existing thp-builder tests):

```fish
# --- anchor-wave builders ---
set -l CURM (printf '\e[38;5;179m')
set -l rowc (__tcz_thp_row '#111111 #222222 #333333 #444444 #555555 #666666 #777777' wide 0 1)
t "row current flag adds the chevron" 1 (string match -q '*❯ wide*' -- (__tcz_strip_sgr "$rowc"); and echo 1; or echo 0)
t "row current chevron wears the switcher yellow" 1 (string match -q "*$CURM*" -- "$rowc"; and echo 1; or echo 0)
set -l rown (__tcz_thp_row '#111111 #222222 #333333 #444444 #555555 #666666 #777777' wide 0)
t "row without current has no chevron" 0 (string match -q '*❯*' -- "$rown"; and echo 1; or echo 0)
t "row current is exactly 2 cols wider" (math (string length --visible -- (__tcz_strip_sgr "$rown"))" + 2") (string length --visible -- (__tcz_strip_sgr "$rowc"))
set -l offc (__tcz_thp_off_row '#5c6b52' 0 'off · current' 1)
t "off-row name override + chevron" 1 (string match -q '*❯ off · current*' -- (__tcz_strip_sgr "$offc"); and echo 1; or echo 0)
set -l offd (__tcz_thp_off_row '#5c6b52' 0)
t "off-row default label unchanged" 1 (string match -q '*off — legacy look*' -- (__tcz_strip_sgr "$offd"); and echo 1; or echo 0)
# kv multi-field flash
set -l FLASH (__tcz_theme flash)
set -l kvm (__tcz_thp_kv 50 'phase rotate' phase '+15°' rotate 2 ease linear)
t "kv multi-flash lights phase" 1 (string match -q "*$FLASH*PHASE*" -- "$kvm[1]"; and echo 1; or echo 0)
t "kv multi-flash lights rotate" 1 (string match -q "*$FLASH*ROTATE*" -- "$kvm[1]"; and echo 1; or echo 0)
t "kv multi-flash spares ease" 0 (string match -q "*$FLASH*EASE*" -- "$kvm[1]"; and echo 1; or echo 0)
set -l kvs (__tcz_thp_kv 50 phase phase '+15°' rotate 2 ease linear)
t "kv single-token flash still works" 1 (string match -q "*$FLASH*PHASE*" -- "$kvs[1]"; and echo 1; or echo 0)
t "readkey z" z (echo -n z | __tcz_popup_readkey)
```

- [ ] **Step 2: Run.** `fish tests/test-tmux-categorize.fish` — new tests FAIL (extra args ignored → no chevron; multi-token flashfield matches nothing; `z` → `other`).

- [ ] **Step 3: Implement.**
  - `__tcz_thp_row`: add `current` to `--argument-names`; before the final printf build the prefix (captured SGRs, per the quoting rule):

```fish
    set -l curpre ''
    if test "$current" = 1
        set -l CUR (printf '\e[38;5;179m')   # the switcher's ❯ yellow — keep identical
        set -l R2 (printf '\e[0m')
        set curpre "$CUR❯ $R2"
    end
    printf '%s%s %s%s%s%s' "$marker" "$cells" "$curpre" "$namecol" "$name" (__tcz_theme reset)
```

    (The existing printf is `'%s%s %s%s%s'` with marker/cells/namecol/name/reset — insert `$curpre` between the space and `$namecol` exactly as shown. The selected-row SELBG re-wrap in the draw loop replaces every reset with reset+SELBG, so the chevron's `$R2` keeps the band intact — same mechanism the marker already relies on.)
  - `__tcz_thp_off_row`: add `name current` to `--argument-names`; default the label:

```fish
    test -n "$name"; or set name 'off — legacy look'
```

    and apply the same `curpre` block before its name segment. Update both docstrings.
  - `__tcz_thp_kv`: replace the single-field match

```fish
        set -l FL ''
        test -n "$flashfield"; and string match -qi -- "$flashfield" $rest[1]; and set FL (__tcz_theme flash)
```

    with the list form:

```fish
        set -l FL ''
        if test -n "$flashfield"
            set -l lab_lc (string lower -- $rest[1])
            contains -- $lab_lc (string split ' ' -- (string lower -- $flashfield)); and set FL (__tcz_theme flash)
        end
```

  - `__tcz_popup_readkey`: add `case 7a; echo z; return` beside the letters, comment `# z (theme-picker: shake)`; add `z` to the docstring token list.

- [ ] **Step 4: Run.** All new tests PASS; whole categorize suite ALL PASS (plain + `--no-config`).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): row/off-row current flag, kv multi-field flash, readkey z"`

---

### Task 2: Anchor row — snapshot, indexing, 27-row frame

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker` (snapshot after init ~L1600, DELETE `__tcz_thp_restore` ~L1248 + its call ~L1602, draw block ~L1636-1700, up/down/a/enter arms ~L1720-1815, docstring), popup heights: `conf.d/tmux-lives-install.fish` themekey bind + CLI open, `functions/tmux-categorize.fish` modal `k` site
- Test: `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish` (height greps)

**Interfaces:**
- Consumes: Task 1 builders.
- Produces: index contract for Tasks 3-4 — `sel` 0 = anchor, 1..`$n` = scheme rows (`$toks[$sel]` directly), `$n + 1` = off. Anchor locals: `anch_scheme anch_phase anch_viv anch_shape anch_ease anch_contrast anch_rotate anchpal anchfg anchtabsfg` (all set once at open).

- [ ] **Step 1: Failing tests** (static pins — the loop is runtime-only):

```fish
# --- anchor row: static pins ---
set -l pk (functions __tcz_theme_picker | string collect)
t "picker snapshots the anchor after init" 1 (string match -q '*set -l anch_scheme $theme*' -- "$pk"; and echo 1; or echo 0)
t "picker anchor palette computed once at open" 1 (string match -q '*__tmux_lives_theme_palette $seed $anch_scheme*' -- "$pk"; and echo 1; or echo 0)
t "picker cursor starts on the anchor" 1 (string match -q '*set -l sel 0*' -- "$pk"; and echo 1; or echo 0)
t "picker anchor enter saves the snapshot" 1 (string match -q '*set apply $anch_scheme*' -- "$pk"; and echo 1; or echo 0)
t "picker anchor a-preview uses snapshot args" 1 (string match -q '*$anch_scheme $anch_phase $anch_viv $anch_shape $anch_ease $anch_contrast $anch_rotate*' -- "$pk"; and echo 1; or echo 0)
t "thp_restore is gone" 0 (functions -q __tcz_thp_restore; and echo 1; or echo 0)
set -l catsrc3 (cat $catfile | string collect)
t "picker popup is 52x27 (modal open site)" 1 (string match -q '*-w 52 -h 27*' -- "$catsrc3"; and echo 1; or echo 0)
t "no stale 52x26 popups" 0 (string match -q '*-w 52 -h 26*' -- "$catsrc3"; and echo 1; or echo 0)
```

Also DELETE the three `thp_restore` tests (~L1035-1037), and UPDATE the existing `"guard: exactly 7 action-site subprocesses"` test to expect **8** — rename it `"guard: exactly 8 action-site subprocesses"` and add the comment `# 8 = init + a-anchor + a-list + esc-revert + 2 seed applies + 2 saves (the case-a anchor/else split is 2 textual sites, still one subprocess per press)`. In `tests/test-tmux-install.fish`, update the two height assertions (fragment bind + no-stale grep) from 26 to 27:

```fish
t "fragment theme-picker bind is 52x27" 1 (string match -q '*-h 27*theme-picker*' -- "$fr0"; and echo 1; or echo 0)
t "install: no stale theme popup height" 0 (string match -q '*-w 52 -h 26*' -- "$insrc"; and echo 1; or echo 0)
```

(Find the existing `-h 26` assertions by grepping the install suite and replace them — do not leave both.)

- [ ] **Step 2: Run.** New pins FAIL.

- [ ] **Step 3: Implement in `__tcz_theme_picker`** (each item's exact code):
  1. DELETE `function __tcz_thp_restore … end` (whole function). Replace `set -l sel (__tcz_thp_restore "$theme" $toks)` with:

```fish
    # anchor snapshot: the persisted theme, frozen for this picker session
    set -l anch_scheme $theme
    set -l anch_phase $phase
    set -l anch_viv $viv
    set -l anch_shape $shape
    set -l anch_ease $ease
    set -l anch_contrast $contrast
    set -l anch_rotate $rotate
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    if test "$anch_scheme" != off
        set -l ap (__tmux_lives_theme_palette $seed $anch_scheme $anch_phase $anch_viv $anch_shape $anch_ease $anch_contrast $anch_rotate)
        if test (count $ap) -eq 7
            set -l apj (string join ' ' $ap)
            set anchpal "$apj"
            set -l af (__tmux_lives_contrast_fg "$ap[6]")
            test -n "$af"; and set anchfg "$af"
            set -l atf (__tmux_lives_contrast_fg "$ap[3]")
            test -n "$atf"; and set anchtabsfg "$atf"
        end
    end
    set -l sel 0
```

  2. **Cursor-row palette block** (replaces the current `if test $sel -lt $n … else … end` around ~L1636):

```fish
        set -l curpal ''
        set -l curfg '#f5f5f5'
        if test $sel -eq 0; and test -n "$anchpal"
            set curpal $anchpal
            set curfg $anchfg
        else if test $sel -ge 1; and test $sel -le $n
            set curpal $pals[$sel]
            set -l cf $fgs[$sel]
            test -n "$cf"; and set curfg $cf
        else
            set -l lb "$legacy"
            test -n "$lb"; or set lb '#444444'
            set curpal "$lb #6b6b6b #6b6b6b #6b6b6b #9a9a9a #444444 #d3d8d0"
            set curfg '#f5f5f5'
        end
```

     (An anchor with EMPTY `anchpal` — off/no-seed — falls to the legacy `else` because the first condition requires non-empty `anchpal`. Note the `sel -eq 0` + empty-anchpal case must reach the legacy branch: write the conditions exactly as shown — `else if $sel -ge 1 -and -le $n` keeps sel 0 falling through.)
  3. **curtabsfg block**: replace `if test $sel -lt $n … tfidx …` with:

```fish
        set -l curtabsfg '#f5f5f5'
        if test $sel -eq 0
            set curtabsfg $anchtabsfg
        else if test $sel -ge 1; and test $sel -le $n
            set curtabsfg "$tabsfgs[$sel]"
        end
```

  4. **Draw: anchor row** — insert directly after the `scheme ·` zsep line, before the `for i in (seq $n)` loop:

```fish
        set -l anchflag 0
        test $sel -eq 0; and set anchflag 1
        set -l anchrow ''
        if test -n "$anchpal"
            set anchrow (__tcz_thp_row "$anchpal" "$anch_scheme · current" $anchflag 1)
        else
            set anchrow (__tcz_thp_off_row "$legacy" $anchflag "$anch_scheme · current" 1)
        end
        if test $anchflag -eq 1
            set anchrow (string replace -a -- "$RST" "$RST$SELBG" "$anchrow")
            set anchrow "$SELBG$anchrow$RST"
        end
        set -a lines (__tcz_thp_ln "$anchrow" $IW $BORDER $RST)
```

  5. **List loop reindex + indicator** — the `for i in (seq $n)` body becomes:

```fish
            set -l selflag 0
            test $i -eq $sel; and set selflag 1
            set -l curflag 0
            test "$toks[$i]" = "$anch_scheme"; and set curflag 1
            set -l row (__tcz_thp_row "$pals[$i]" $toks[$i] $selflag $curflag)
```

     (SELBG wrap lines unchanged.) **Off row**: `test $sel -eq (math $n + 1); and set offflag 1`.
  6. **up/down bounds**: `case down` becomes `test $sel -lt (math $n + 1); and set sel (math $sel + 1)` (up unchanged — floor 0 is now the anchor).
  7. **`case a`**:

```fish
            case a
                if test $sel -eq 0
                    fish -c '__tmux_lives_theme_apply_live $argv' $anch_scheme $anch_phase $anch_viv $anch_shape $anch_ease $anch_contrast $anch_rotate >/dev/null 2>&1
                    set previewed 1
                    set note "● previewing $anch_scheme (current) — ⏎ save · esc revert"
                else
                    set -l ptok off
                    test $sel -le $n; and set ptok $toks[$sel]
                    fish -c '__tmux_lives_theme_apply_live $argv' $ptok $phase $viv $shape $ease $contrast $rotate >/dev/null 2>&1
                    set previewed 1
                    set note "● previewing $ptok — ⏎ save · esc revert"
                end
```

  8. **`case enter`**:

```fish
            case enter
                if test $sel -eq 0
                    set apply $anch_scheme
                    set phase $anch_phase; set viv $anch_viv; set shape $anch_shape
                    set ease $anch_ease; set contrast $anch_contrast; set rotate $anch_rotate
                else if test $sel -le $n
                    set apply $toks[$sel]
                else
                    set apply off
                end
                break
```

     (An anchor whose `anch_scheme` is `off` flows to the post-loop `test "$apply" = off` branch naturally.)
  9. **Docstring**: mention the anchor row (`❯ <scheme> · current`, frozen snapshot, cursor starts there), the `❯` list indicator, and `-h 27`; the frame is EXACTLY 27 rows.
  10. **The three open sites** → `-w 52 -h 27` (fragment themekey bind + CLI no-arg in `conf.d/tmux-lives-install.fish`, modal `k` in this file).

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` + `fish tests/test-tmux-install.fish`, both also `--no-config` — ALL PASS.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): picker anchor row — frozen current-theme snapshot, ❯ indicator, 27-row frame"`

---

### Task 3: Shake key + legend

**Files:**
- Modify: `functions/tmux-categorize.fish` — picker dispatch (new `case z` after `case b`), legend rows (~3 lines), picker docstring key list
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Task 2 index contract (`sel` 1..`$n` = scheme rows); Task 1 multi-flash + `z` token.
- Produces: `case z` for Task 4 to add its litkv call to.

- [ ] **Step 1: Failing tests:**

```fish
set -l pk2 (functions __tcz_theme_picker | string collect)
t "picker has a shake arm" 1 (string match -q '*case z*' -- "$pk2"; and echo 1; or echo 0)
t "shake rerolls the scheme row" 1 (string match -q '*set sel (random 1 $n)*' -- "$pk2"; and echo 1; or echo 0)
t "shake rerolls phase in 5° steps" 1 (string match -q '*(random 0 71) \* 5*' -- "$pk2"; and echo 1; or echo 0)
t "shake rerolls rotate" 1 (string match -q '*set rotate (random 0 4)*' -- "$pk2"; and echo 1; or echo 0)
t "shake flashes both fields" 1 (string match -q "*set flashfield 'phase rotate'*" -- "$pk2"; and echo 1; or echo 0)
t "legend advertises z shake" 1 (string match -q '*z shake*' -- (__tcz_strip_sgr (__tcz_legend_row 12 d contrast o rotate z shake b seed)); and echo 1; or echo 0)
t "picker legend dropped the nav hint" 0 (string match -q '*↑↓*scheme*' -- "$pk2"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run.** FAIL (no `case z`; legend still has `↑↓ scheme`).

- [ ] **Step 3: Implement.** Dispatch (after `case b`):

```fish
            case z
                # shake: one press -> a radically different combo. Scheme +
                # placement reroll; taste knobs (viv/shape/ease/contrast) kept.
                set sel (random 1 $n)
                set phase (math "(random 0 71) * 5")
                set rotate (random 0 4)
                set flashfield 'phase rotate'
                __tcz_thp_reload
```

Legend rows become:

```fish
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 '←→' phase v vivid s shape e ease) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 d contrast o rotate z shake b seed) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 a apply '⏎' save r reset esc close) $IW $BORDER $RST)
```

Docstring: add `z shake (random scheme+phase+rotate)` to the key list.

- [ ] **Step 4: Run.** Categorize suite ALL PASS (plain + `--no-config`).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): z shake — random scheme+phase+rotate in one press"`

---

### Task 4: Lit-first repaint + docs + gate

**Files:**
- Modify: `functions/tmux-categorize.fish` — new nested `__tcz_thp_litkv` (beside `__tcz_thp_init`/`__tcz_thp_reload`), calls in the knob arms; `README.md`; `CLAUDE.md`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: everything prior; kv rows are frame rows 5-8 (title 1, tab strip 2, preview 3, zsep 4 — the anchor row sits at 10 and does not shift them).

- [ ] **Step 1: Failing tests:**

```fish
set -l pk3 (functions __tcz_theme_picker | string collect)
t "litkv helper defined" 1 (string match -q '*function __tcz_thp_litkv*' -- "$pk3"; and echo 1; or echo 0)
t "litkv paints kv rows 5-8 atomically" 1 (string match -q '*2026h\e\[5;1H*' -- (string replace -a -- \e '\e' "$pk3"); and echo 1; or echo 0)
t "litkv called from every knob arm" 12 (count (string match -ar '__tcz_thp_litkv' -- "$pk3"))
```

(The row-address test escapes ESC for matching; if the replace form fights you, match the two plain substrings `2026h` and `5;1H` in one `string match -q '*2026h*5;1H*'` instead — same intent, note it in the report.)

- [ ] **Step 2: Run.** FAIL.

- [ ] **Step 3: Implement.** Nested helper (after `__tcz_thp_reload`'s `end`, before `__tcz_thp_hexentry`):

```fish
    function __tcz_thp_litkv --no-scope-shadowing --description 'lit-first feedback: repaint the kv zone (frame rows 5-8) with the CURRENT knob values + flash BEFORE the recompute runs — the changed field lights up instantly and stays lit until the batch lands'
        set -l seedchip (__tcz_thp_bg "$seed")(__tcz_thp_fg "$seedfg")"$seed"(printf '\e[0m')
        set -l k1 (__tcz_thp_kv $IW "$flashfield" seed "$seedchip" phase "+$phase°" vividness "$viv" shape "$shape")
        set -l k2 (__tcz_thp_kv $IW "$flashfield" contrast "$contrast" rotate "$rotate" ease "$ease")
        set -l l1 (__tcz_thp_ln "$k1[1]" $IW $BORDER $RST)
        set -l l2 (__tcz_thp_ln "$k1[2]" $IW $BORDER $RST)
        set -l l3 (__tcz_thp_ln "$k2[1]" $IW $BORDER $RST)
        set -l l4 (__tcz_thp_ln "$k2[2]" $IW $BORDER $RST)
        printf '\e[?2026h\e[5;1H%s\e[K\e[6;1H%s\e[K\e[7;1H%s\e[K\e[8;1H%s\e[K\e[?2026l' "$l1" "$l2" "$l3" "$l4"
    end
```

(`IW`/`BORDER`/`RST` and the knob vars are the picker's loop-locals — `--no-scope-shadowing` reaches them; they are all declared before the while loop. The command substitutions strip `__tcz_thp_ln`'s trailing newline, so cursor addressing stays exact.)

Add `__tcz_thp_litkv` immediately AFTER the `set flashfield …` line and BEFORE `__tcz_thp_reload` in these 11 arms: `left`, `right` (after the drain + phase update), `v`, `V`, `s S`, `e E`, `d`, `D`, `o`, `O`, `z`. Total occurrences incl. the definition = 12 (the count the test pins).

- [ ] **Step 4: Docs.** README picker paragraph: add — the top row of the scheme list is your current theme (`❯ <scheme> · current`, frozen at its saved knobs — select it and press `a` to flip back for comparison); `z` shakes up a random scheme/phase/rotate; changed values light up blue immediately, before the strips recompute. CLAUDE.md theme paragraph: append one dense sentence (anchor row + ❯ indicator + 52×27, `z` shake random scheme/phase/rotate, multi-field flash, `__tcz_thp_litkv` lit-first repaint of kv rows 5-8, `__tcz_thp_restore` deleted; spec `2026-07-19-picker-anchor-shake-design.md`; live smoke pending).

- [ ] **Step 5: THE GATE.** `fish -c 'for t in tests/test-*.fish; fish $t; end'` AND the `--no-config` variant — all 8 suites ALL PASS; report both.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat(theme): lit-first kv repaint before recompute + docs"`

---

## Post-plan (not tasks)

- Final whole-branch review (opus), then finishing-a-development-branch (merge to main + push).
- Runtime-only, user live smoke after `fisher update`: anchor flip-flop feel (`a` on anchor vs candidate), ❯ visibility, `z` shake quality, lit-first perceived latency on the Mac, 27-row geometry at all three sites.
