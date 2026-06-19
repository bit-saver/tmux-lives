# ts Popup Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fzf session switcher with a hand-rolled, pure-fish two-pane `display-popup` TUI: categorized list + always-on live `capture-pane` preview, non-selectable headers, full-width category rules, flush-right indicators.

**Architecture:** All logic stays in the existing `functions/tmux-categorize.fish` (the categorizer/switcher, run via `fish --no-config`). Pure render/layout helpers (`__tcz_popup_layout`, `__tcz_popup_truncate`, `__tcz_popup_clip`, `__tcz_popup_list_lines`) are unit-tested; the interactive shell (`__tcz_popup`, `__tcz_popup_draw`, `__tcz_popup_readkey`) is a thin layer over them, verified by a live smoke test. The fzf path is deleted; `display-menu` (`__tcz_menu`) remains as the no-`display-popup` fallback. The `prefix S` binding moves to the popup in the fragment (`conf.d/tmux-lives-install.fish`).

**Tech Stack:** fish 4.x, tmux 3.3a, `stty` (POSIX), ANSI SGR escapes. No new runtime dependency. Existing fish test harness (`tests/*.fish`, isolated `tmux -L` sockets + PATH shims).

## Global Constraints

- **Pure fish, no new dependency.** Only `tmux`, `stty`, and ANSI escapes. No fzf, no compiled binary.
- **File hygiene: ZERO new files in `conf.d/` or `functions/`.** All new functions go in the existing `functions/tmux-categorize.fish`. Underscore-prefix all helpers (`__tcz_popup_*`). The only new file in the repo is `tests/test-tmux-popup.fish` (a `tests/` file, not a config-browse dir).
- **tmux 3.3a quirk:** `capture-pane -t` REJECTS the `=name` exact-match prefix — always use plain `-t "$name"` (switch-client/rename/has/kill keep `=`, but capture-pane must not).
- **Two locked aesthetics (test-enforced, not preferences):** (1) category header rules fill to **exactly `listwidth`** visible columns at any size; (2) `[current]`/`[attached]` indicators are **flush-right** — last char at column `listwidth`, name truncated with `…` on collision.
- **Palette (match the existing menu):** claude `\e[1;38;5;208m` (orange, bold), running `\e[1;38;5;6m` (cyan), general `\e[1;38;5;2m` (green), current-session name `\e[38;5;179m` (muted yellow), markers `\e[2m` (dim), selected pointer `\e[38;5;208m▌`, selected-row background `\e[48;5;236m`.
- **All 7 existing suites + the new one must print `ALL PASS`** after every task: `for t in tests/test-*.fish; fish $t; end`.
- **Never run `tmux-setup` / the popup against the live server in automated steps** — use isolated `-L` sockets / throwaway invocations. The live render (Task 7) is the deliberate, user-driven exception.

---

### Task 1: `__tcz_popup_layout` (pane-width math)

**Files:**
- Create: `tests/test-tmux-popup.fish`
- Modify: `functions/tmux-categorize.fish` (add `__tcz_popup_layout` near the other switcher helpers, e.g. just before `__tcz_open_switcher` at line ~451)

**Interfaces:**
- Produces: `__tcz_popup_layout <cols>` → echoes one line `"<listwidth> <previewwidth>"`. List ≈ 42% of cols, clamped to [20,40]; 1 col reserved for the divider; if `cols < 60`, previewwidth is `0` (list-only) and listwidth is `cols`.

- [ ] **Step 1: Write the failing test** — create `tests/test-tmux-popup.fish`:

```fish
#!/usr/bin/env fish
# Tests for the pure popup-switcher helpers in functions/tmux-categorize.fish.
# Run: fish tests/test-tmux-popup.fish
# Pure tests only — sources the script with tmux_categorize_test set (no gcc, no real tmux).

set -g FAIL 0
set -g plugindir (path resolve (status dirname)/..)

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end

# strip SGR escapes so we can assert on visible width/content
function vis --description 'strip ANSI SGR from argv[1]'
    string replace -ra '\x1b\[[0-9;]*m' '' -- "$argv[1]"
end

set -g tmux_categorize_test 1
source $plugindir/functions/tmux-categorize.fish

# ---------------------------------------------------------------------
# __tcz_popup_layout: cols -> "listwidth previewwidth"
# ---------------------------------------------------------------------
t "layout 80 -> list 33, prev 46"   "33 46" (__tcz_popup_layout 80)
t "layout 120 -> list clamped 40"   "40 79" (__tcz_popup_layout 120)
t "layout 50 (narrow) -> no preview" "50 0" (__tcz_popup_layout 50)
t "layout 0/invalid -> defaults 80" "33 46" (__tcz_popup_layout 0)

test $FAIL -eq 0; and echo ALL PASS; or echo SOME FAILED
exit $FAIL
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_popup_layout` is undefined (the layout assertions error/fail).

- [ ] **Step 3: Implement `__tcz_popup_layout`** in `functions/tmux-categorize.fish` (just above `__tcz_open_switcher`):

```fish
function __tcz_popup_layout --argument-names cols --description 'cols -> "listwidth previewwidth" (preview 0 when too narrow)'
    test -n "$cols"; and test "$cols" -gt 0 2>/dev/null; or set cols 80
    if test $cols -lt 60
        echo "$cols 0"
        return 0
    end
    set -l list (math "floor($cols * 42 / 100)")
    test $list -lt 20; and set list 20
    test $list -gt 40; and set list 40
    set -l prev (math "$cols - $list - 1")
    test $prev -lt 1; and set prev 1
    echo "$list $prev"
end
```

- [ ] **Step 4: Run, verify it passes**

Run: `fish tests/test-tmux-popup.fish`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-popup.fish && git commit -qm "feat: __tcz_popup_layout — popup pane-width math + test scaffold"
```

---

### Task 2: `__tcz_popup_truncate` (width-aware ellipsis)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add below `__tcz_popup_layout`)
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces: `__tcz_popup_truncate <text> <width>` → `text` if its length ≤ width, else first `width-1` chars + `…` (for width 1, just `…`). Assumes `text` has no ANSI.

- [ ] **Step 1: Write the failing test** — append before the final `test $FAIL...` line in `tests/test-tmux-popup.fish`:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_truncate
# ---------------------------------------------------------------------
t "truncate long adds ellipsis" "hell…" (__tcz_popup_truncate "hello world" 5)
t "truncate exact unchanged"    "hello" (__tcz_popup_truncate "hello" 5)
t "truncate short unchanged"    "hi"    (__tcz_popup_truncate "hi" 5)
t "truncate width 1 -> ellipsis" "…"    (__tcz_popup_truncate "hello" 1)
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_popup_truncate` undefined.

- [ ] **Step 3: Implement** in `functions/tmux-categorize.fish`:

```fish
function __tcz_popup_truncate --argument-names text width --description 'truncate text to width visible chars with trailing … (no ANSI in text)'
    test -n "$width"; and test "$width" -gt 0 2>/dev/null; or begin; echo ''; return 0; end
    if test (string length -- "$text") -le $width
        echo -- "$text"
        return 0
    end
    test $width -eq 1; and begin; echo -- '…'; return 0; end
    echo -- (string sub -l (math "$width - 1") -- "$text")"…"
end
```

- [ ] **Step 4: Run, verify it passes**

Run: `fish tests/test-tmux-popup.fish`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-popup.fish && git commit -qm "feat: __tcz_popup_truncate — width-aware ellipsis"
```

---

### Task 3: `__tcz_popup_list_lines` (the categorized list + locked aesthetics)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add below `__tcz_popup_truncate`)
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Consumes: overview lines on **stdin** — TAB-delimited `name⇥category⇥attached⇥last_attached⇥display` (the output of `__tcz_overview`). `__tcz_popup_truncate` (Task 2).
- Produces: `__tcz_popup_list_lines <listwidth> <selidx> <current>` → ANSI visual lines: a full-width colored rule at each category boundary, then one row per session. `selidx` is the 0-based **session** ordinal (headers are not counted, so they are unreachable). Every emitted line is **exactly `listwidth` visible columns**; markers are flush-right; the row at `selidx` gets the orange `▌` pointer + `\e[48;5;236m` background; the session whose name equals `current` is shown in muted yellow.

- [ ] **Step 1: Write the failing test** — append to `tests/test-tmux-popup.fish`:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_list_lines — full-width rules + flush-right markers + pointer
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
set -g OV \
    "claude-x$TAB"claude"$TAB"1"$TAB"100"$TAB"claude-x" \
    "neuro$TAB"running"$TAB"0"$TAB"90"$TAB"nvim" \
    "gen-1$TAB"general"$TAB"0"$TAB"80"$TAB"gen-1  ~/w"
# selidx 1 (neuro) selected; current = neuro
set -g L (printf '%s\n' $OV | __tcz_popup_list_lines 30 1 neuro)
# order: [1]claude rule [2]claude-x row [3]running rule [4]neuro row [5]general rule [6]gen-1 row
t "rule fills to listwidth 30"        30   (string length (vis $L[1]))
t "rule starts with category name"    yes  (string match -q '── claude *' (vis $L[1]); and echo yes; or echo no)
t "rule is all box-drawing fill"      yes  (string match -qr '^── claude ─+$' (vis $L[1]); and echo yes; or echo no)
t "attached row width = listwidth"    30   (string length (vis $L[2]))
t "attached marker flush-right"       yes  (string match -qr '\[attached\]$' (vis $L[2]); and echo yes; or echo no)
t "selected row carries ▌ pointer"    yes  (string match -q '*▌*' -- $L[4]; and echo yes; or echo no)
t "current row marker flush-right"    yes  (string match -qr '\[current\]$' (vis $L[4]); and echo yes; or echo no)
t "current row width = listwidth"     30   (string length (vis $L[4]))
t "plain row padded to listwidth"     30   (string length (vis $L[6]))
# aesthetics must scale to any width:
set -g L40 (printf '%s\n' $OV | __tcz_popup_list_lines 40 0 '')
t "rule scales to listwidth 40"       40   (string length (vis $L40[1]))
# long name truncates with … when it would collide with the marker:
set -g OVlong "supercalifragilistic$TAB"running"$TAB"1"$TAB"50"$TAB"supercalifragilisticexpialidocious"
set -g LL (printf '%s\n' $OVlong | __tcz_popup_list_lines 24 0 '')
t "long name truncated with ellipsis" yes  (string match -q '*…*' (vis $LL[2]); and echo yes; or echo no)
t "truncated row still flush-right"   yes  (string match -qr '\[attached\]$' (vis $LL[2]); and echo yes; or echo no)
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_popup_list_lines` undefined.

- [ ] **Step 3: Implement** in `functions/tmux-categorize.fish`:

```fish
function __tcz_popup_list_lines --argument-names listwidth selidx current --description 'overview (stdin) -> ANSI visual list: full-width category rules + session rows (pointer on #selidx, markers flush-right at listwidth)'
    set -l TAB (printf '\t')
    set -l RST (printf '\e[0m')
    set -l FGDEF (printf '\e[39m')      # reset fg only (keeps background)
    set -l DIMON (printf '\e[2m'); set -l DIMOFF (printf '\e[22m')
    set -l YEL (printf '\e[38;5;179m')
    set -l ORG (printf '\e[38;5;208m')
    set -l SELBG (printf '\e[48;5;236m')
    test -n "$listwidth"; and test "$listwidth" -gt 0 2>/dev/null; or set listwidth 30
    test -n "$selidx"; or set selidx 0
    set -l group ''
    set -l idx 0
    while read -l line
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l name "$f[1]"; set -l cat "$f[2]"; set -l att "$f[3]"; set -l disp "$f[5]"
        # category rule (full width to listwidth)
        if test "$cat" != "$group"
            set group "$cat"
            set -l c 208
            test "$cat" = running; and set c 6
            test "$cat" = general; and set c 2
            set -l word "── $cat "
            set -l wl (string length -- "$word")
            if test $wl -ge $listwidth
                printf '%s%s%s\n' (printf '\e[1;38;5;%sm' $c) (__tcz_popup_truncate "$word" $listwidth) $RST
            else
                printf '%s%s%s%s\n' (printf '\e[1;38;5;%sm' $c) "$word" (string repeat -n (math "$listwidth - $wl") ─) $RST
            end
        end
        # marker
        set -l mk ''
        if test -n "$current"; and test "$name" = "$current"
            set mk '[current]'
        else if test "$att" = 1
            set mk '[attached]'
        end
        set -l mlen (string length -- "$mk")
        # name field width = listwidth - 2 (pointer area) - (gap+marker if any)
        set -l namespace (math "$listwidth - 2")
        test $mlen -gt 0; and set namespace (math "$namespace - $mlen - 1")
        test $namespace -lt 1; and set namespace 1
        set -l shown (__tcz_popup_truncate "$disp" $namespace)
        set -l pad (math "$namespace - "(string length -- "$shown"))
        test $pad -lt 0; and set pad 0
        set -l pads (string repeat -n $pad ' ')
        set -l gap ''; test $mlen -gt 0; and set gap ' '
        set -l iscur 0; test -n "$current"; and test "$name" = "$current"; and set iscur 1
        if test "$idx" = "$selidx"
            # selected row: full-width background band, fg-only color changes
            set -l nmpart "$shown$pads"
            test $iscur -eq 1; and set nmpart "$YEL$shown$FGDEF$pads"
            set -l mkpart ''
            test $mlen -gt 0; and set mkpart "$gap$DIMON$mk$DIMOFF"
            printf '%s%s▌%s %s%s%s\n' $SELBG $ORG $FGDEF "$nmpart" "$mkpart" $RST
        else
            set -l nmpart "$shown$pads"
            test $iscur -eq 1; and set nmpart "$YEL$shown$RST$pads"
            set -l mkpart ''
            test $mlen -gt 0; and set mkpart "$gap$DIMON$mk$RST"
            printf '  %s%s\n' "$nmpart" "$mkpart"
        end
        set idx (math $idx + 1)
    end
end
```

- [ ] **Step 4: Run, verify it passes**

Run: `fish tests/test-tmux-popup.fish`
Expected: `ALL PASS`. (If a width assertion is off by the pointer/gap accounting, adjust `namespace` math — the invariant is `2 + namespace + (mlen>0 ? 1+mlen : 0) == listwidth`.)

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-popup.fish && git commit -qm "feat: __tcz_popup_list_lines — full-width rules, flush-right markers, pointer"
```

---

### Task 4: `__tcz_popup_clip` + `__tcz_popup_preview` (preview content)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add below `__tcz_popup_list_lines`)
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces:
  - `__tcz_popup_clip <w> <h>` — stdin lines → first `h` lines, each truncated to `w` (via `__tcz_popup_truncate`). Pure.
  - `__tcz_popup_preview <session> <w> <h>` — `tmux capture-pane -p -t "<session>"` (plain `-t`, no `=`; no `-e` so output is layout-safe plain text) piped through `__tcz_popup_clip`. Thin shell.

- [ ] **Step 1: Write the failing test** — append to `tests/test-tmux-popup.fish`:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_clip — first h lines, truncated to w
# ---------------------------------------------------------------------
set -g CLIP (printf 'aaaa\nbbbbbbbb\ncccc\ndddd\n' | __tcz_popup_clip 4 2)
t "clip limits to h lines"   2      (count $CLIP)
t "clip keeps short line"    "aaaa" "$CLIP[1]"
t "clip truncates wide line" "bbb…" "$CLIP[2]"
# __tcz_popup_preview must target plainly (no '=' prefix) and use clip
set -g PV (functions __tcz_popup_preview | string collect)
t "preview has no '=' target"   no  (string match -q '*-t "=*' -- "$PV"; and echo yes; or echo no)
t "preview pipes through clip"  yes (string match -q '*__tcz_popup_clip*' -- "$PV"; and echo yes; or echo no)
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_popup_clip` / `__tcz_popup_preview` undefined.

- [ ] **Step 3: Implement** in `functions/tmux-categorize.fish`:

```fish
function __tcz_popup_clip --argument-names w h --description 'stdin lines -> first h lines, each truncated to w'
    test -n "$w"; and test "$w" -gt 0 2>/dev/null; or set w 40
    test -n "$h"; and test "$h" -gt 0 2>/dev/null; or set h 20
    set -l i 0
    while read -l l
        test $i -ge $h; and break
        __tcz_popup_truncate "$l" $w
        set i (math $i + 1)
    end
end

function __tcz_popup_preview --argument-names session w h --description 'plain capture-pane of session active pane, clipped to w×h'
    test -n "$session"; or return 0
    tmux capture-pane -p -t "$session" 2>/dev/null | __tcz_popup_clip $w $h
end
```

- [ ] **Step 4: Run, verify it passes**

Run: `fish tests/test-tmux-popup.fish`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-popup.fish && git commit -qm "feat: __tcz_popup_clip + __tcz_popup_preview — layout-safe preview content"
```

---

### Task 5: Interactive loop + wiring; remove the fzf path

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_popup_readkey`, `__tcz_popup_draw`, `__tcz_popup`; rewrite `__tcz_open_switcher`; in `__tcz_main` replace the `fzfpick` case with `popup`; update the usage string (line ~522) and the header subcommands comment (line 5). **Delete** `__tcz_fzf_lines` (line ~232) and `__tcz_fzfpick` (line ~459).
- Modify: `tests/test-tmux-categorize.fish` — delete the fzf blocks (the `__tcz_fzf_lines` tests ~349-366, the `__tcz_fzfpick` tests ~370-372, and the `__tcz_open_switcher` fzf-toggle tests ~375-394) and replace with the popup-switcher tests below.

**Interfaces:**
- Consumes: `__tcz_popup_layout`, `__tcz_popup_list_lines`, `__tcz_popup_preview`, `__tcz_overview`, `__tcz_categorize`, `__tcz_switch`, `__tcz_menu`.
- Produces: subcommand `popup <client>` → `__tcz_popup <client>`; `__tcz_open_switcher <client>` opens `display-popup … popup` (the popup TUI).

- [ ] **Step 1: Replace the fzf tests in `tests/test-tmux-categorize.fish`.** Delete lines ~349-394 (everything from the `# __tcz_fzf_lines (pure)` comment through the `switcher: no fzf -> display-menu` assertion) and paste in their place:

```fish
# ---------------------------------------------------------------------
# popup switcher wiring (the pure render helpers are covered by
# tests/test-tmux-popup.fish; here we assert the dispatch + entry points)
# ---------------------------------------------------------------------
t "no leftover __tcz_fzf_lines" absent (functions -q __tcz_fzf_lines; and echo present; or echo absent)
t "no leftover __tcz_fzfpick"   absent (functions -q __tcz_fzfpick; and echo present; or echo absent)

# open-switcher opens a display-popup running the `popup` subcommand for the client.
# Shim tmux: make `list-commands` advertise display-popup (so the capability
# probe passes), and echo everything else so nothing actually launches.
set -g sw_shim /tmp/tcz-sw-$fish_pid
mkdir -p $sw_shim
printf '#!/bin/sh\nif [ "$1" = list-commands ]; then echo display-popup; else echo "TMUX:$*"; fi\n' > $sw_shim/tmux; chmod +x $sw_shim/tmux
set -g sw_path_save $PATH
set -gx PATH $sw_shim $PATH
set -g sw_out (__tcz_open_switcher c1)
set -gx PATH $sw_path_save
t "open-switcher uses display-popup" yes (string match -q '*display-popup*' -- "$sw_out"; and echo yes; or echo no)
t "open-switcher runs popup subcmd"  yes (string match -q '*popup c1*' -- "$sw_out"; and echo yes; or echo no)
rm -rf $sw_shim

# dispatcher routes `popup`, not `fzfpick`
set -g main_src (functions __tcz_main | string collect)
t "dispatcher has popup case"    yes (string match -q '*case popup*' -- "$main_src"; and echo yes; or echo no)
t "dispatcher dropped fzfpick"   no  (string match -q '*fzfpick*' -- "$main_src"; and echo yes; or echo no)
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_fzf_lines`/`__tcz_fzfpick` still present; `open-switcher` still uses `command -q fzf`; dispatcher still has `fzfpick`.

- [ ] **Step 3: Edit `functions/tmux-categorize.fish`.**

(a) Delete the whole `__tcz_fzf_lines` function (the block starting `function __tcz_fzf_lines …` ~line 232).

(b) Delete the whole `__tcz_fzfpick` function (~line 459).

(c) Replace `__tcz_open_switcher` with:

```fish
function __tcz_open_switcher --argument-names client --description 'open the two-pane popup switcher (display-menu fallback if display-popup is unsupported)'
    if tmux list-commands 2>/dev/null | grep -q display-popup
        tmux display-popup -E -w 80% -h 70% -- fish --no-config $__tcz_self popup "$client"
    else
        __tcz_menu
    end
end
```

(d) Add the interactive functions (place them just before `__tcz_open_switcher`):

```fish
function __tcz_popup_readkey --description 'read one keystroke -> up|down|enter|cancel|other (raw tty already set)'
    set -l c
    if not read -n1 -l c
        echo cancel; return            # EOF
    end
    test -z "$c"; and begin; echo enter; return; end   # newline delimiter consumed
    switch "$c"
        case j; echo down; return
        case k; echo up; return
        case q; echo cancel; return
    end
    test "$c" = (printf '\r'); and begin; echo enter; return; end
    if test "$c" = (printf '\e')
        # bare ESC vs CSI arrow: non-blocking follow-read (deci-second timeout)
        stty min 0 time 1
        set -l c2; read -n1 -l c2 2>/dev/null
        set -l c3; test "$c2" = '['; and read -n1 -l c3 2>/dev/null
        stty min 1 time 0
        if test "$c2" = '['
            switch "$c3"
                case A; echo up; return
                case B; echo down; return
            end
            echo other; return
        end
        echo cancel; return
    end
    echo other
end

function __tcz_popup_draw --description '__tcz_popup_draw <sel> <listw> <prevw> <rows> <current> -- <model lines...>: paint one frame'
    set -l sel $argv[1]; set -l listw $argv[2]; set -l prevw $argv[3]; set -l rows $argv[4]; set -l current $argv[5]
    set -e argv[1..6]                  # argv[6] is the literal '--' separator
    set -l model $argv
    set -l TAB (printf '\t')
    set -l DIV (printf '\e[38;5;240m│\e[0m')
    set -l left (printf '%s\n' $model | __tcz_popup_list_lines $listw $sel "$current")
    set -l right
    if test $prevw -gt 0
        set -l selname (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
        set right (__tcz_popup_preview "$selname" $prevw $rows)
    end
    set -l blankL (string repeat -n $listw ' ')
    set -l buf (printf '\e[H')
    for r in (seq $rows)
        set -l lseg $blankL
        test $r -le (count $left); and set lseg $left[$r]
        set -l line $lseg
        if test $prevw -gt 0
            set -l rseg ''
            test $r -le (count $right); and set rseg $right[$r]
            set line "$lseg$DIV$rseg"
        end
        set buf "$buf$line"(printf '\e[K')
        test $r -lt $rows; and set buf "$buf"(printf '\n')
    end
    printf '%s\e[J' "$buf"
end

function __tcz_popup --argument-names client --description 'two-pane session switcher (runs inside display-popup)'
    __tcz_categorize >/dev/null 2>&1
    set -l current (tmux display-message -c "$client" -p '#{session_name}' 2>/dev/null)
    test -n "$current"; or set current (tmux display-message -p '#{session_name}' 2>/dev/null)
    set -l TAB (printf '\t')
    set -l model (__tcz_overview)
    set -l n (count $model)
    test $n -gt 0; or return 0
    set -l size (stty size 2>/dev/null | string split ' ')
    set -l rows $size[1]; set -l cols $size[2]
    test -n "$rows"; and test "$rows" -gt 0 2>/dev/null; or set rows 24
    test -n "$cols"; and test "$cols" -gt 0 2>/dev/null; or set cols 80
    set -l lay (string split ' ' (__tcz_popup_layout $cols))
    set -l listw $lay[1]; set -l prevw $lay[2]
    # start on the current session if present
    set -l sel 0
    for i in (seq $n)
        if test (string split -m 1 $TAB -- $model[$i])[1] = "$current"
            set sel (math $i - 1); break
        end
    end
    set -l saved (stty -g)
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J'
    set -l result ''
    while true
        __tcz_popup_draw $sel $listw $prevw $rows "$current" -- $model
        switch (__tcz_popup_readkey)
            case up
                test $sel -gt 0; and set sel (math $sel - 1)
            case down
                test $sel -lt (math $n - 1); and set sel (math $sel + 1)
            case enter
                set result (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
                break
            case cancel
                break
        end
    end
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    test -n "$result"; and __tcz_switch "$result" "$client"
    return 0
end
```

(e) In `__tcz_main`, replace:

```fish
        case fzfpick
            __tcz_fzfpick $argv[2]
```

with:

```fish
        case popup
            __tcz_popup $argv[2]
```

(f) Update the usage string (the `case '*'` echo) to read `…|open-switcher|popup|claim|…` (replace `fzfpick` with `popup`), and update the header comment on line 5 the same way.

- [ ] **Step 4: Syntax-check + run both affected suites**

Run: `fish -n functions/tmux-categorize.fish && fish tests/test-tmux-categorize.fish && fish tests/test-tmux-popup.fish`
Expected: no syntax errors; both suites print `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish && git commit -qm "feat: pure-fish two-pane popup switcher; remove fzf path"
```

---

### Task 6: Fragment — `prefix S` opens the popup

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment`, lines ~21-23)
- Test: `tests/test-tmux-install.fish` (lines 13-14)

**Interfaces:**
- Produces: the `~/.config/tmux/tmux-lives.conf` fragment binds `prefix S` to `display-popup … popup` when `display-popup` is supported, else to the `menu` run-shell.

- [ ] **Step 1: Update the failing assertions** in `tests/test-tmux-install.fish` (replace lines 13-14):

```fish
t "fragment binds S via display-popup guard" 1 (string match -q '*if-shell*display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment binds S to popup subcommand"     1 (string match -q '*display-popup*popup*' -- "$frag"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run, verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — the fragment still says `command -v fzf` / `fzfpick`.

- [ ] **Step 3: Edit the fragment** in `conf.d/tmux-lives-install.fish` — replace the three `if-shell 'command -v fzf …'` lines (21-23) with:

```fish
        "if-shell 'tmux list-commands 2>/dev/null | grep -q display-popup' \\" \
        "    \"bind-key S display-popup -E -w 80% -h 70% -- fish --no-config $cat popup '#{client_name}'\" \\" \
        "    \"bind-key S run-shell 'fish --no-config $cat menu'\"" \
```

- [ ] **Step 4: Run, verify it passes**

Run: `fish tests/test-tmux-install.fish`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish && git commit -qm "feat: prefix S opens the pure-fish popup switcher (display-popup guarded)"
```

---

### Task 7: Docs, supersession, full + live verification

**Files:**
- Modify: `CLAUDE.md`, `README.md` (switcher wording: fzf → pure-fish two-pane popup), `docs/auto-tmux.md` if present in the repo (switcher section).
- Modify: `docs/superpowers/specs/2026-06-18-ts-live-preview-switcher-design.md` and `docs/superpowers/plans/2026-06-18-ts-live-preview-switcher.md` — add a top-of-file note: `> SUPERSEDED 2026-06-18 by docs/superpowers/specs/2026-06-18-ts-popup-switcher-design.md (fzf dropped for a pure-fish two-pane popup).`
- Create (verification artifact): `artifacts/screenshots/` (gitignored) for the live render.

- [ ] **Step 1: Update prose.** In `CLAUDE.md` (lines ~8-15) and `README.md`, replace fzf descriptions of the switcher with: "`prefix S`/`ts` open a pure-fish two-pane `display-popup` (categorized list + live `capture-pane` preview, non-selectable headers); `display-menu` is the no-`display-popup` fallback." Remove the "fzf has no non-selectable rows" known-constraint line. Add the supersession notes to the two old fzf docs.

- [ ] **Step 2: Ensure `artifacts/` is gitignored.**

Run: `grep -q '^/artifacts/' .gitignore 2>/dev/null || printf '/artifacts/\n' >> .gitignore`
Expected: `.gitignore` contains `/artifacts/`.

- [ ] **Step 3: Full automated suite — must be green.**

Run: `cd ~/workspace/tmux-lives && for t in tests/test-*.fish; echo "== $t =="; fish $t; end`
Expected: every suite ends `ALL PASS`.

- [ ] **Step 4: Live smoke test (the one manual gate).** Against an **isolated** tmux server (NOT the live one), create a few sessions across categories and open the popup, capturing a screenshot for review:

```bash
S=tlpopup
tmux -L $S -u new-session -d -s gen-1
tmux -L $S -u new-session -d -s nvim    'nvim'
tmux -L $S -u new-session -d -s claude-x 'cat'
# open the popup in a client attached to this server (run from a real terminal/tab):
tmux -L $S -u attach \; display-popup -E -w 80% -h 70% -- fish --no-config functions/tmux-categorize.fish popup "$(tmux -L $S display-message -p '#{client_name}')"
```

Verify by eye + screenshot to `artifacts/screenshots/`:
- category rules run **full width** to the divider at this popup size;
- `[current]`/`[attached]` sit **flush-right**;
- arrow keys **and** `j`/`k` move; the cursor **never lands on a header**;
- the preview pane updates as you move and shows the highlighted session;
- `Enter` switches; `Esc`/`q` cancels with no switch.

If raw-key handling misbehaves in the real terminal, iterate on `__tcz_popup_readkey` (the `stty min/time` toggle) — `j`/`k`/`q` must work even if arrows don't. Tear down: `tmux -L $S kill-server`.

- [ ] **Step 5: User sign-off on the look,** then commit.

```bash
cd ~/workspace/tmux-lives && git add CLAUDE.md README.md .gitignore docs/auto-tmux.md docs/superpowers/specs/2026-06-18-ts-live-preview-switcher-design.md docs/superpowers/plans/2026-06-18-ts-live-preview-switcher.md && git commit -qm "docs: popup switcher — refresh guides, supersede fzf spec/plan"
```

---

## Notes / Known limitations

- **No scroll.** Lists longer than the popup height are clipped (session counts are small — YAGNI). If this ever bites, add a scroll offset to `__tcz_popup`/`__tcz_popup_draw`.
- **Plain-text preview.** `capture-pane -p` (no `-e`) keeps the two-pane layout reliable; colored preview would need ANSI-aware width truncation (deferred).
- **Interactive loop is not unit-tested** by design — Task 7's live smoke is its gate. Everything it depends on (layout, list rendering, truncation, clip) is unit-tested in `tests/test-tmux-popup.fish`.
- **`open-switcher` fallback** uses `tmux list-commands | grep -q display-popup`; the fragment carries the same guard so `prefix S` degrades to `display-menu` on a tmux too old for `display-popup`.
- **Two deliberate simplifications vs the spec:** (1) the spec's `__tcz_popup_selectable` helper is unnecessary — `selidx` indexes *sessions* directly, so headers are unreachable by construction. (2) The spec asked for a single shared palette helper; because `__tcz_menu_args` emits tmux `#[fg=…]` markup while the popup emits raw ANSI `\e[…m` (different syntaxes), they can't share literal strings — instead the **numeric codes** (208/6/2/179/240/236) are the single source of truth, pinned in Global Constraints. Keep them in sync by hand.
