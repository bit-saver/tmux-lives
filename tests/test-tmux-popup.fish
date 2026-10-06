#!/usr/bin/env fish
# Tests for the pure popup-switcher helpers in functions/tmux-categorize.fish.
# Run: fish tests/test-tmux-popup.fish
# Pure tests only — sources the script with tmux_categorize_test set (no gcc, no real tmux).

if not set -q TMUX_LIVES_TEST_UVARS; or test "$TMUX_LIVES_TEST_UVARS" != "$XDG_CONFIG_HOME"
    set -l d (mktemp -d /tmp/tmux-lives-uv.XXXXXX)
    if test -z "$d"; or not test -d "$d"
        echo "FATAL: cannot create an isolated universal store; refusing to run" >&2
        exit 1
    end
    set -gx TMUX_LIVES_TEST_UVARS $d
    set -gx XDG_CONFIG_HOME $d
    set -l fishargs
    test (count $fish_function_path) -gt 0; or set fishargs --no-config
    set -l fish_bin (status fish-path)
    $fish_bin $fishargs (path resolve (status filename)) $argv
    set -l rc $status
    rm -rf $d
    exit $rc
end
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

# ---------------------------------------------------------------------
# __tcz_popup_truncate
# ---------------------------------------------------------------------
t "truncate long adds ellipsis" "hell…" (__tcz_popup_truncate "hello world" 5)
t "truncate exact unchanged"    "hello" (__tcz_popup_truncate "hello" 5)
t "truncate short unchanged"    "hi"    (__tcz_popup_truncate "hi" 5)
t "truncate width 1 -> ellipsis" "…"    (__tcz_popup_truncate "hello" 1)
# wide characters occupy 2 display COLUMNS but count as 1 char: truncation must bound
# columns, not char count. Regression: a ✅-banner session overflowed the preview pane
# by 1 col, wrapping the row and scrolling the whole popup frame.
t "truncate bounds columns (emoji in window)" ok \
    (test (string length --visible (__tcz_popup_truncate "aaaaa✅bbbbb" 7)) -le 7; and echo ok; or echo OVER)
t "truncate bounds columns (CJK)"             ok \
    (test (string length --visible (__tcz_popup_truncate "日本語テストです" 6)) -le 6; and echo ok; or echo OVER)
t "truncate wide char straddling boundary"    ok \
    (test (string length --visible (__tcz_popup_truncate "abc✅def" 5)) -le 5; and echo ok; or echo OVER)

# ANSI-aware: SGR escapes are zero-width, never split, reset before the …
set -g E (printf '\e')
set -g T_FIT (printf '\e[31mhi\e[0m')
t "trunc keeps fitting colored text verbatim" "$T_FIT" (__tcz_popup_truncate "$T_FIT" 10)
set -g T_LONG (printf '\e[31mabcdefghij\e[0m')
set -g T_CUT (__tcz_popup_truncate "$T_LONG" 5)
t "trunc honors visible width (5) ignoring escapes" 5 (string length --visible -- "$T_CUT")
t "trunc resets colour before …" yes (printf '%s' "$T_CUT" | string match -qr '\x1b\[0m…$'; and echo yes; or echo no)
t "trunc leaves no broken escape" "abcd…" (vis "$T_CUT")
# characterization (pins exact output across the perf rewrite of the slow path)
t "trunc plain long -> budget+…"        "abcdefghi…"           (__tcz_popup_truncate "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ" 10)
t "trunc keeps SGR runs before the cut" (printf 'aaa\e[31mbb\e[0m…')  (__tcz_popup_truncate (printf 'aaa\e[31mbbbbbbbbbb\e[0mccc') 6)
t "trunc wide chars after an SGR run"   (printf '\e[32m日本\e[0m…')    (__tcz_popup_truncate (printf '\e[32m日本語テストです') 6)
# perf guard: truncate must NOT cost O(line length) with per-char builtin calls. The
# wall-clock timing of this (<300ms/50 calls on a heavy colored line) moved to the
# hand-run tests/truncate-perf.fish (chore-hygiene item 2) -- it flaked ~2 runs in 3
# under normal host load, which does not belong in the gate. Run it by hand: fish
# tests/truncate-perf.fish.

# ---------------------------------------------------------------------
# __tcz_popup_list_lines (v3): the claude section (an orange rail beside a gold box per
# directory and the gray older box), then general; every line exactly listwidth columns
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
set -g FX (printf 'cp\tclaude/projects\t2\t0\tcp · task') \
    (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf 'cw\tclaude/workspace\t1\t0\tcw') \
    (printf 'older\tolder\t0\t3\t...older (3)') \
    (printf 'g1\tgeneral\t0\t0\tg1') \
    (printf 'g2\tgeneral\t1\t0\tg2')
# Lines: [1] claude rule [2] projects box [3] cp [4] pi [5] rail [6] workspace box [7] cw [8] rail
# [9] older box [10] ...older (3) [11] rail [12] general rule [13] g1 [14] g2
set -g L (printf '%s\n' $FX | __tcz_popup_list_lines 40 -1 '')
set -l lw
for l in $L; set -a lw (string length --visible -- (vis "$l")); end
t "v3 list: 14 lines, every one 40 columns" "14 40" "$(count $L) $(printf '%s\n' $lw | sort -u | string join ,)"
t "v3 list: records each row's line and the first line its window keeps (its section or box rule when it opens one)" "3 4 7 10 13 14|1 4 6 9 12 14" "$__tcz_pl_line|$__tcz_pl_first"
t "v3 list: the claude rule opens the section, bold orange" 1 (string match -qr '^\e\[1;38;5;208m╭── claude ─+\e\[0m$' -- $L[1]; and echo 1; or echo 0)
set -l orail (printf '\e[38;5;208m│')
set -l rail 1
for i in (seq 2 11)
    string match -q -- "$orail*" $L[$i]; or set rail 0
end
t "v3 list: the orange rail runs down beside the whole claude section (lines 2-11)" 1 $rail
t "v3 list: a box rule: its name centered, ╮ two columns in" "│ "(string repeat -n 13 ─)" projects "(string repeat -n 13 ─)"╮ " (vis $L[2])
t "v3 list: the box rule is bold gold" 1 (string match -q -- '*1;38;5;178m*' $L[2]; and echo 1; or echo 0)
t "v3 list: the next box centers its own name" "│ "(string repeat -n 12 ─)" workspace "(string repeat -n 13 ─)"╮ " (vis $L[6])
t "v3 list: a box's rail runs one row past its last member, with no corner" "│"(string repeat -n 37 ' ')"│ " (vis $L[5])
t "v3 list: ... in gold" 1 (string match -q -- '*38;5;178m│*' $L[5]; and echo 1; or echo 0)
t "v3 list: the older box rule is wordless" "│ "(string repeat -n 36 ─)"╮ " (vis $L[9])
t "v3 list: ... and bold gray" 1 (string match -q -- '*1;38;5;8m*' $L[9]; and echo 1; or echo 0)
t "v3 list: the older row reads ...older (3) in gray, beside the gray rail" 1 (string match -q -- '*38;5;8m...older (3)*38;5;8m│*' $L[10]; and echo 1; or echo 0)
t "v3 list: the general rule opens general, bold green" 1 (string match -qr '^\e\[1;38;5;2m╭── general ─+\e\[0m$' -- $L[12]; and echo 1; or echo 0)
t "v3 list: a general row spans the list beside the green rail" 1 (string match -qr '^│ g1 +$' -- (vis $L[13]); and string match -q -- (printf '\e[38;5;2m│')'*' $L[13]; and echo 1; or echo 0)
t "v3 list: a boxed row: the marker flush right, just before the box's rail" 1 (string match -qr '^│ cp · task +\[here\] │ $' -- (vis $L[3]); and echo 1; or echo 0)
t "v3 list: a general row's marker sits at the list's edge" 1 (string match -qr '^│ g2 +\[attached\]$' -- (vis $L[14]); and echo 1; or echo 0)
t "v3 list: an idle project is muted -- its name, then its age" 1 (string match -q -- '*38;5;247mpi*38;5;243m · 2d*' $L[4]; and echo 1; or echo 0)
set -l nobot 1
for l in $L; string match -qr '[╰╯└┘]' -- $l; and set nobot 0; end
t "v3 list: no bottom borders anywhere" 1 $nobot

function __tcp_band --description '"first-last" columns of argv[1] on the selection band (__tcz_theme sel-bg); 0-0 when none'
    set -l bg (__tcz_theme sel-bg)
    set -l on 0; set -l col 0; set -l first 0; set -l last 0
    for tok in (string match -ar '\e\[[0-9;]*m|[^\e]' -- "$argv[1]")
        if string match -qr '^\e\[' -- "$tok"
            test "$tok" = "$bg"; and set on 1
            string match -qr '^\e\[(0|49)?m$' -- "$tok"; and set on 0
            continue
        end
        set col (math $col + 1)
        test $on -eq 1; or continue
        test $first -eq 0; and set first $col
        set last $col
    end
    echo "$first-$last"
end
set -l Ls (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 '')
t "v3 list: a selected boxed row: an orange ▐, the band stops before the box's rail" "1 1-38" "$(string match -q -- '*38;5;208m▐*' $Ls[3]; and echo 1; or echo 0) $(__tcp_band $Ls[3])"
set -l Lo (printf '%s\n' $FX | __tcz_popup_list_lines 40 3 '')
t "v3 list: the older row's pointer is orange (it is in claude)" 1 (string match -q -- '*38;5;208m▐*' $Lo[10]; and echo 1; or echo 0)
set -l Lg (printf '%s\n' $FX | __tcz_popup_list_lines 40 4 '')
t "v3 list: a selected general row: a green ▐, the band spans the list" "1 1-40" "$(string match -q -- '*38;5;2m▐*' $Lg[13]; and echo 1; or echo 0) $(__tcp_band $Lg[13])"
functions -e __tcp_band
set -l Lc (printf '%s\n' $FX | __tcz_popup_list_lines 40 0 cw)
t "v3 list: the current session off the pointer: a yellow ❯ in the rail cell, a yellow [current] before the box's rail" 1 (string match -qr '^❯ cw +\[current\] │ $' -- (vis $Lc[7]); and string match -q -- (printf '\e[38;5;179m❯')'*' $Lc[7]; and string match -q -- (printf '*\e[38;5;179m[current]')'*' $Lc[7]; and echo 1; or echo 0)
set -l Lcs (printf '%s\n' $FX | __tcz_popup_list_lines 40 2 cw)
t "v3 list: the current session under the pointer: ▐ takes the rail cell, the name stays yellow, [current] goes dim" 1 (string match -qr '^▐ cw +\[current\] │ $' -- (vis $Lcs[7]); and string match -q -- (printf '*\e[38;5;179mcw')'*' $Lcs[7]; and string match -q -- (printf '*\e[2m[current]')'*' $Lcs[7]; and echo 1; or echo 0)
set -l lrow (__tcz_popup_list_row 40 1 '' $FX[1])
t "v3 list: the drawer draws a row as the list does (selected, boxed)" "$Ls[3]" "$lrow"
# Only a live row can be current: the older row and an idle project never take the marker, even when a session shares the name.
function __tcp_iscur --description '1 when argv[1] carries [current] or the current session'"'"'s ❯, else 0'
    string match -q -- '*[current]*' "$argv[1]"; or string match -q -- '*❯*' "$argv[1]"; and echo 1; or echo 0
end
set -l cgO (__tcp_iscur (vis (__tcz_popup_list_row 40 0 older (printf 'older\tolder\t0\t3\tolder (3)'))))
set -l cgP (__tcp_iscur (vis (__tcz_popup_list_row 40 0 cp (printf 'cp\tprojects\t0\t0\tcp · 2d'))))
set -l cgL (__tcp_iscur (vis (__tcz_popup_list_row 40 0 older (printf 'older\tgeneral\t0\t0\tolder'))))
set -l cgB (__tcp_iscur (vis (__tcz_popup_list_row 40 0 cp (printf 'cp\tclaude/projects\t0\t0\tcp'))))
t "v3 list: only a live row is current -- not the older row (a session named older is current), not an idle project of the same name; a live row, either section, is" "0 0 1 1" "$cgO $cgP $cgL $cgB"
functions -e __tcp_iscur
# Narrow and long: rows truncate with …, a marker that leaves the name no room is dropped, and every line keeps the width.
set -l LN (printf '%s\n' (printf 'averylongsessionname\tclaude/other\t1\t0\taverylongsessionname') (printf 'averylongsession2\tgeneral\t1\t0\taverylongsession2') | __tcz_popup_list_lines 12 0 '')
set -l lnw
for l in $LN; set -a lnw (string length --visible -- (vis "$l")); end
t "v3 list: at 12 columns every line keeps the width (6 lines)" "6 12" "$(count $LN) $(printf '%s\n' $lnw | sort -u | string join ,)"
t "v3 list: a narrow row drops its marker and truncates its name" 1 (string match -q -- '*…*' (vis $LN[3]); and not string match -q -- '*attached*' (vis $LN[3]); and echo 1; or echo 0)
set -l LL (printf 'supercalifragilistic\tclaude/projects\t1\t0\tsupercalifragilisticexpialidocious\n' | __tcz_popup_list_lines 30 -1 '')
t "v3 list: a long boxed name truncates with … and keeps its marker before the rail" "30 1" "$(string length --visible -- (vis $LL[3])) $(string match -qr '….*\[attached\] │ $' -- (vis $LL[3]); and echo 1; or echo 0)"
set -l LE (printf 'sx\tgeneral\t0\t0\tok✅done\n' | __tcz_popup_list_lines 20 0 '')
t "v3 list: a wide-character name keeps the row 20 columns" 20 (string length --visible -- (vis $LE[2]))

# ---------------------------------------------------------------------
# __tcz_popup_clip — the BOTTOM h lines (most recent last), trailing blank
# lines stripped, bottom-anchored (blank rows on top), each truncated to w cols.
# The very bottom of the preview must be the session's most recent line.
# ---------------------------------------------------------------------
set -g CB (printf 'l1\nl2\nl3\nl4\n' | __tcz_popup_clip 10 2)
t "clip keeps h lines"            2      (count $CB)
t "clip bottom row = most recent" "l4"   (vis "$CB[2]")
t "clip shows the TAIL not head"  "l3"   (vis "$CB[1]")
# trailing blank lines stripped so the bottom is real content, not whitespace
set -g CT (printf 'top\nmid\nlast\n\n\n' | __tcz_popup_clip 10 2)
t "clip strips trailing blanks"   "last" (vis "$CT[2]")
t "clip row above the bottom"     "mid"  (vis "$CT[1]")
# short content bottom-anchored: padded to h with blank rows ON TOP, content at bottom
set -g CS (printf 'only\n' | __tcz_popup_clip 10 3)
t "clip pads to exactly h rows"   3      (count $CS)
t "clip pins content to last row" "only" (vis "$CS[3]")
t "clip top row blank when short" ""     "$CS[1]"
# width truncation still applies, measured in COLUMNS (wide-char aware)
set -g CW (printf 'aaaaa✅bbbbb\n' | __tcz_popup_clip 7 1)
t "clip truncates to w columns"   ok     (test (string length --visible "$CW[1]") -le 7; and echo ok; or echo OVER)
# __tcz_popup_preview must target through __tcz_session_target's exact "=name:"
# form, not plainly -- a bare or unslashed "=name" target can resolve against
# another session's WINDOW of the same name (see __tcz_session_target's own
# docstring). Non-empty-extraction check first so the body assertion below
# cannot pass vacuously against an empty $PV.
set -g PV (functions __tcz_popup_preview | string collect)
t "preview extraction is non-empty" yes (test -n "$PV"; and echo yes; or echo no)
t "preview targets through __tcz_session_target" yes (string match -q '*-t (__tcz_session_target*' -- "$PV"; and echo yes; or echo no)
t "preview pipes through clip"  yes (string match -q '*__tcz_popup_clip*' -- "$PV"; and echo yes; or echo no)

# clip: an SGR-only trailing line counts as blank, so real content is bottom-anchored
set -g CBE (printf 'real\n%s[0m\n' $E | __tcz_popup_clip 10 2)
t "clip treats SGR-only line as blank"  real (vis "$CBE[2]")
# clip: each content line ends with a reset so colour can't bleed into the divider
set -g CRS (printf '%s[31mhot\n' $E | __tcz_popup_clip 10 1)
t "clip line ends with reset"  yes (printf '%s' "$CRS[1]" | string match -qr '\x1b\[0m$'; and echo yes; or echo no)
# preview now captures WITH escapes
set -g PVE (functions __tcz_popup_preview | string collect)
t "preview uses capture-pane -e"  yes (string match -q '*capture-pane -e*' -- "$PVE"; and echo yes; or echo no)
t "preview still pipes through clip"  yes (string match -q '*__tcz_popup_clip*' -- "$PVE"; and echo yes; or echo no)
# strip helper
t "strip_sgr removes colour"  abc (__tcz_strip_sgr (printf '%s[31mabc%s[0m' $E $E))

# ---------------------------------------------------------------------
# __tcz_popup_emit — a whole paint separates rows by real newlines (regression)
# command-sub `(printf '\n')` strips trailing newlines → all rows on one line
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
# A trailing newline after the last row would scroll a full-height popup up one row each
# repaint, dropping the top line and flashing. 8 rows -> exactly 7 newlines, none trailing.
set -g __tcz_pe_prev; set -g __tcz_pe_force 1
__tcz_popup_emit (seq 8) > /tmp/tcz-emit-$fish_pid
set -g ENL (wc -l < /tmp/tcz-emit-$fish_pid | string trim)
rm -f /tmp/tcz-emit-$fish_pid
set -g __tcz_pe_prev; set -g __tcz_pe_force 1
t "emit: a whole paint puts newlines between rows only (8 rows, 7 newlines)" 7 "$ENL"

# --- frame: a selection below the fold scrolls into view ---
set -g SCM
for i in (seq 12)
    set -a SCM (printf 's%s\tgeneral\t0\t0\trow%s' $i $i)
end
set -g SCD (__tcz_popup_frame 11 20 0 8 '' -- $SCM)
t "frame: the selected row is on screen when the list overflows" 1 (string match -q '*▐ row12*' -- (vis "$SCD"); and echo 1; or echo 0)
set -g SCT (__tcz_popup_frame 0 20 0 8 '' -- $SCM)
t "frame: a selection above the fold stays top-anchored (non-regression)" 1 (string match -q '*╭── general*' -- (vis "$SCT[1]"); and echo 1; or echo 0)

# --- frame: ↑ below the fold moves the pointer; the list scrolls only at the window's top ---
set -e __tcz_pd_top
set -l s11 (__tcz_popup_frame 11 20 0 8 '' -- $SCM)
set -l s10 (__tcz_popup_frame 10 20 0 8 '' -- $SCM)
set -l s10p (string match -q '*▐ row11*' -- (vis "$s10"); and echo 1; or echo 0)
t "frame: ↑ below the fold moves the pointer, the window stays" "1 1" (test -n "$s11[1]" -a "$s11[1]" = "$s10[1]"; and echo 1; or echo 0)" $s10p"
set -l s03 (__tcz_popup_frame 3 20 0 8 '' -- $SCM)
t "frame: the window scrolls up once the pointer passes its top" 1 (string match -q '*▐ row4*' -- (vis "$s03[1]"); and echo 1; or echo 0)
set -e __tcz_pd_top

# --- frame: the list memo draws exactly what a full build draws ---
# The reference is the frame's list as it was built before the memo: the whole list with the pointer,
# the window walked from the first row (its own top, __tcp_ref_top). No preview column: the memo is the list's.
function __tcp_frame_ref --description '__tcp_frame_ref <sel> <listw> <rows> <current> -- <model lines...>'
    set -l sel $argv[1]; set -l listw $argv[2]; set -l rows $argv[3]; set -l current $argv[4]
    set -e argv[1..5]
    # The whole list with the pointer drawn in place; the window walked from its own top.
    set -l left (printf '%s\n' $argv | __tcz_popup_list_lines $listw $sel "$current")
    set -l top 0
    if test (count $left) -gt $rows
        set -l k (math "min($sel + 1, "(count $__tcz_pl_line)")")
        set -l line $__tcz_pl_line[$k]; set -l first $__tcz_pl_first[$k]
        set -q __tcp_ref_top; and set top $__tcp_ref_top
        test $first -le $top; and set top (math $first - 1)
        test $line -gt (math $top + $rows); and set top (math $line - $rows)
        set -l maxtop (math (count $left) - $rows)
        test $top -gt $maxtop; and set top $maxtop
        test $top -lt 0; and set top 0
    end
    set -g __tcp_ref_top $top
    set -l blankL (string repeat -n $listw ' ')
    for r in (seq $rows)
        set -l li (math $r + $top)
        set -l lseg $blankL
        test $li -le (count $left); and set lseg $left[$li]
        printf '%s\e[K\n' "$lseg"
    end
end
# 15 model rows, 14 drawn: junk has fewer than 5 fields and is skipped by both builds.
set -g MM (printf 'c1\tclaude/projects\t0\t0\tc1') (printf 'c2\tclaude/projects\t0\t0\tc2') \
    (printf 'c3\tclaude/workspace\t0\t0\tc3')
for i in 1 2 3 4; set -a MM (printf '/p/w%s\tworkspace\t0\t0\tw%s · 2h' $i $i); end
for i in 1 2 3; set -a MM (printf '/p/o%s\tother\t0\t0\to%s · 3d' $i $i); end
set -a MM (printf 'older\tolder\t0\t2\t...older (2)') (printf 'r1\tgeneral\t1\t0\trunning one') \
    (printf 'cur\tgeneral\t0\t0\tcur') junk (printf 'g2\tgeneral\t2\t0\tg2 with a display long enough to be cut')
functions -c __tcz_popup_list_lines __tcp_ll_bak
set -g LLREC /tmp/tcz-llrec-$fish_pid
rm -f $LLREC
function __tcz_popup_list_lines
    echo $argv[2] >> $LLREC
    __tcp_ll_bak $argv
end
set -g __tcp_n 0; set -g __tcp_d 0; set -g __tcp_p 0; set -g __tcp_s 0
function __tcp_memo_cmp --argument-names sel listw current --description 'build one frame both ways and count: compared, differing, with a pointer, scrolled'
    set -l a (__tcz_popup_frame $sel $listw 0 8 "$current" -- $MM | string collect)
    set -l b (__tcp_frame_ref $sel $listw 8 "$current" -- $MM | string collect)
    set -g __tcp_n (math $__tcp_n + 1)
    test "$a" = "$b"; or set -g __tcp_d (math $__tcp_d + 1)
    string match -q '*▐*' -- "$a"; and set -g __tcp_p (math $__tcp_p + 1)
    test "$__tcz_pd_top" -gt 0; and set -g __tcp_s (math $__tcp_s + 1)
end
set -e __tcz_pd_top; set -e __tcp_ref_top; set -e __tcz_pf_lkey
for s in (seq 0 14); __tcp_memo_cmp $s 20 cur; end
for s in (seq 14 -1 0); __tcp_memo_cmp $s 20 cur; end
set MM[5] (printf '/p/w2\tworkspace\t0\t0\tw2 · 5h')                  # one row's text changes
for s in 8 9 10; __tcp_memo_cmp $s 20 cur; end
for s in 4 5; __tcp_memo_cmp $s 20 ''; end                           # the current session changes
for s in 0 13 14 3 7; __tcp_memo_cmp $s 26 ''; end                   # the width changes; jumps
set -l mbuilds (string match -- -1 (cat $LLREC) | count)
set -l mscrolled (test $__tcp_s -gt 0; and echo 1; or echo 0)
t "frame: the list memo draws exactly what a full build draws (sweeps, a changed row, current, width, jumps), built once per input" "40 0 37 1 4" "$__tcp_n $__tcp_d $__tcp_p $mscrolled $mbuilds"
functions -e __tcz_popup_list_lines
functions -c __tcp_ll_bak __tcz_popup_list_lines
functions -e __tcp_ll_bak __tcp_memo_cmp __tcp_frame_ref
rm -f $LLREC
set -e __tcz_pd_top; set -e __tcp_ref_top

# --- landing: the painter skips an unchanged frame and diffs a changed one ---
set -g LPM (printf '/tmp/tcz-pa\tother\t0\t%s\tpa · 2h' (math (date +%s) - 7200)) \
    (printf '/tmp/tcz-pb\tother\t0\t%s\tpb · 5h' (math (date +%s) - 18000))
functions -c __tcz_popup_frame __tcp_frame_bak
set -g FREC /tmp/tcz-frec-$fish_pid
set -g LPOUT /tmp/tcz-lpout-$fish_pid
rm -f $FREC $LPOUT
function __tcz_popup_frame
    echo built >> $FREC
    __tcp_frame_bak $argv
end
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 1 24 80 0 landing '' -- $LPM > $LPOUT
set -l lp1 (test (wc -c < $LPOUT) -gt 0; and echo 1; or echo 0)
set -l lprows (count $__tcz_pe_prev)
set -l lpborder (string match -q '*─┴─*' -- "$__tcz_pe_prev[23]"; and echo 1; or echo 0)
set -l lplegend (string match -q '*n*new*r*resume*' -- (vis "$__tcz_pe_prev[24]"); and echo 1; or echo 0)
t "paint: 24 rows -- the frame, a border with ┴ under the divider, then the legend with n new" "24 1 1" "$lprows $lpborder $lplegend"
__tcz_landing_paint 1 24 80 0 landing '' -- $LPM > $LPOUT
set -l lp2rc $status
set -l lp2bytes (wc -c < $LPOUT | string trim)
set -l lpbuilt (count (cat $FREC 2>/dev/null))
t "paint: an unchanged frame is neither rebuilt nor emitted" "1 1 0 1" "$lp1 $lp2rc $lp2bytes $lpbuilt"
# A move between two project rows: only the rows that differ are emitted.
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 24 80 0 landing '' -- $LPM > /dev/null
set -l fa (__tcp_frame_bak 0 33 46 22 '' -- $LPM)
set -l fb (__tcp_frame_bak 1 33 46 22 '' -- $LPM)
set -l fdiff
for i in (seq (count $fb))
    test "$fa[$i]" = "$fb[$i]"; or set -a fdiff $i
end
__tcz_landing_paint 1 24 80 0 landing '' -- $LPM > $LPOUT
set -l lpemitted (string match -rag '\e\[([0-9]+);1H' -- (cat $LPOUT))
set -l lpfull (string match -q '*'(printf '\e[H')'*' -- (cat $LPOUT | string collect); and echo 1; or echo 0)
set -l lpsome (test (count $fdiff) -gt 0 -a (count $fdiff) -lt 22; and echo 1; or echo 0)
set -l lpsame (test "$lpemitted" = "$fdiff"; and echo 1; or echo 0)
t "paint: a move between two project rows emits only the changed rows" "1 1 0" "$lpsome $lpsame $lpfull"
functions -e __tcz_popup_frame
functions -c __tcp_frame_bak __tcz_popup_frame
functions -e __tcp_frame_bak
rm -f $FREC $LPOUT
set -e __tcz_lp_key

# --- paint: the badge, and every row of a 100x30 frame ---
functions -c __tcz_popup_preview __tcp_preview_bak
function __tcz_popup_preview; printf 'PV-%s\n' $argv[1]; end
function tmux; end
set -g BM (printf 'cp\tclaude/projects\t1\t0\tcp') (printf '/h/projects/pi\tprojects\t0\t0\tpi · 2d') \
    (printf 'g1\tgeneral\t0\t0\tg1') (printf 'g2\tgeneral\t0\t0\tg2')
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 30 100 0 landing '' -- $BM > /dev/null
set -l bl $__tcz_pe_prev
set -l bdiv 0
for r in $bl[1..28]
    set -l v (vis "$r")
    test (string length --visible -- (string sub -l 40 -- "$v")) -eq 40; and test (string sub -s 41 -l 1 -- "$v") = '│'; and set bdiv (math $bdiv + 1)
end
t "paint 100x30: 30 rows; the list column is 40 wide with the divider at column 41 on all 28 frame rows" "30 28" "$(count $bl) $bdiv"
t "paint: the landing legend opens with an orange LANDING badge" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;208m LANDING \e[0m')'*' $bl[30]; and echo 1; or echo 0) $(string match -q -- ' LANDING  ↑↓ move*' (vis $bl[30]); and echo 1; or echo 0)"
t "paint: no esc close on the landing" 0 (string match -q -- '*esc close*' (vis $bl[30]); and echo 1; or echo 0)
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 2 30 100 0 switch g2 -- $BM > /dev/null
set -l sl $__tcz_pe_prev
t "paint: the switcher's legend opens with a teal SWITCHING badge and ends with esc close" "1 1" "$(string match -q -- (printf '\e[1;7;38;5;37m SWITCHING \e[0m')'*' $sl[30]; and echo 1; or echo 0) $(string match -q -- ' SWITCHING  ↑↓ move*esc close*' (vis $sl[30]); and echo 1; or echo 0)"
# The pointer is on g1 and the current session is g2: the marker follows <current>, not the pointer.
set -l slv
for r in $sl[1..28]; set -a slv (vis "$r"); end
set -l slptr (string match -- '*▐ g1*' $slv)
set -l slcur (string match -- '*[current]*' $slv)
t "paint: the switcher marks the current session (g2, off the pointer) and not the pointer row (g1)" "1 0 1 1" "$(count $slptr) $(string match -q -- '*[current]*' $slptr; and echo 1; or echo 0) $(count $slcur) $(string match -q -- '*❯ g2*[current]*' $slcur; and echo 1; or echo 0)"
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
functions -e tmux __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak

# --- landing: the preview column for project rows ---
# __tcz_popup_preview is stubbed to a recorder: a project row must never
# reach capture-pane, and this suite must never reach a real tmux server.
functions -c __tcz_popup_preview __tcp_preview_bak
set -g PREC /tmp/tcz-prec-$fish_pid
rm -f $PREC
function __tcz_popup_preview
    echo $argv >> $PREC
end
set -g LDlive (printf 'alpha\tgeneral\t0\t0\talpha')
set -g LDproj (printf '/tmp/tcz-some/proj\tother\t0\t%s\tproj · 2h' (math (date +%s) - 7200))
set -g LDold (printf 'older\tolder\t0\t2\tolder (2)')
__tcz_popup_frame 0 20 30 8 '' -- $LDproj $LDlive >/dev/null
__tcz_popup_frame 0 20 30 8 '' -- $LDold $LDlive >/dev/null
set -l prec_proj (cat $PREC 2>/dev/null)
t "frame: a project row or the older row never calls capture-pane" "" "$prec_proj"
set -l dproj (__tcz_popup_frame 0 20 30 8 '' -- $LDproj $LDlive | string join \n)
set dproj (vis "$dproj" | string join \n)
t "frame: a project row previews its folder" 1 (string match -q '*/tmp/tcz-some/proj*' -- "$dproj"; and echo 1; or echo 0)
rm -f $PREC
__tcz_popup_frame 1 20 30 8 '' -- $LDproj $LDlive >/dev/null
set -l prec_live (cat $PREC 2>/dev/null)
t "frame: a live row still previews its session (non-regression)" "alpha 30 8" "$prec_live"
rm -f $PREC
__tcz_popup_frame 0 20 30 8 '' -- (printf 'older\tgeneral\t0\t0\tolder') >/dev/null
set -l prec_lvo (cat $PREC 2>/dev/null)
t "frame: a live session named older still previews its session (the older row is told by category, not name)" "older 30 8" "$prec_lvo"
rm -f $PREC
functions -e __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak

# --- landing: a held move rebuilds the list only; the preview catches up when input is quiet ---
# __tcz_popup_preview and tmux are stubbed to recorders: this suite never reaches a tmux server.
functions -c __tcz_popup_preview __tcp_preview_bak
set -g PREC2 /tmp/tcz-prec2-$fish_pid
set -g TREC /tmp/tcz-trec-$fish_pid
rm -f $PREC2 $TREC; touch $PREC2 $TREC
function __tcz_popup_preview
    echo $argv[1] >> $PREC2
    printf 'PV-%s\n' $argv[1]
end
set -g HM (printf 'alpha\tgeneral\t0\t0\talpha') (printf 'beta\tgeneral\t0\t0\tbeta')
set -g __tcz_pf_keep 0
set -l hf1 (__tcz_popup_frame 0 20 30 8 '' -- $HM | string join \n)
set -g __tcz_pf_keep 1
set -l hf2 (__tcz_popup_frame 1 20 30 8 '' -- $HM | string join \n)
set -g __tcz_pf_keep 0
set -l hf3 (__tcz_popup_frame 1 20 30 8 '' -- $HM | string join \n)
set -l hcalls (cat $PREC2 | string join ,)
set -l hkept (string match -q '*PV-alpha*' -- "$hf2"; and string match -q '*▐ beta*' -- (vis "$hf2"); and echo 1; or echo 0)
set -l hnew (string match -q '*PV-beta*' -- "$hf3"; and echo 1; or echo 0)
t "frame: with __tcz_pf_keep the pointer moves and the preview column is reused, not captured" "alpha,beta 1 1" "$hcalls $hkept $hnew"
function tmux; echo $argv >> $TREC; end
set -g __tcz_pe_prev; set -g __tcz_pe_force 1; set -e __tcz_lp_key
__tcz_landing_paint 0 24 80 0 landing '' -- $HM > /dev/null
rm -f $PREC2 $TREC; touch $PREC2 $TREC
__tcz_landing_paint 1 24 80 1 landing '' -- $HM > /dev/null
set -l hpheld (cat $TREC | string match -e capture-pane | count)
set -l hpprev (cat $PREC2 | count)
__tcz_landing_paint 1 24 80 0 landing '' -- $HM > /dev/null
set -l hpquiet $status
set -l hpafter (cat $TREC | string match -e capture-pane | count)
set -l hpprev2 (cat $PREC2 | count)
functions -e tmux
t "paint: a held move captures nothing and keeps the preview; the quiet repaint of that row is not skipped, and captures" "0 0 0 1 1" "$hpheld $hpprev $hpquiet $hpafter $hpprev2"
rm -f $PREC2 $TREC
set -e __tcz_lp_key
functions -e __tcz_popup_preview
functions -c __tcp_preview_bak __tcz_popup_preview
functions -e __tcp_preview_bak

# --- landing: __tcz_landing_info ---
set -l linow (date +%s)
set -l li1 (__tcz_landing_info (printf '/p/x\tother\t0\t%s\tx · 2h' (math $linow - 7200)) 40 8)
set li1 (vis "$li1")
t "landing_info: project shows its folder" 1 (string match -q '*/p/x*' -- "$li1"; and echo 1; or echo 0)
t "landing_info: project shows its age" 1 (string match -q '*2h*' -- "$li1"; and echo 1; or echo 0)
t "landing_info: project names both keys" 1 (string match -q '*--continue*--resume*' -- "$li1"; and echo 1; or echo 0)
set -l li4 (__tcz_landing_info (printf 'older\tolder\t0\t3\tolder (3)') 40 8)
set li4 (vis "$li4")
t "landing_info: the older row says how many, how old, and what Enter does" 1 (string match -q '*3 older projects*over 3w ago*show them*' -- "$li4"; and echo 1; or echo 0)
set -l li3 (__tcz_landing_info (printf '/a/very/long/folder/path/that/overflows\tother\t0\t%s\tpath · 2h' $linow) 12 2)
t "landing_info: never more than h lines" 2 (count $li3)
set -l li3w 0
for l in $li3
    set -l w (string length --visible -- (vis "$l"))
    test $w -gt $li3w; and set li3w $w
end
t "landing_info: every line fits w" 1 (test $li3w -le 12 -a $li3w -gt 0; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# __tcz_popup_readkey — must accept SS3 (\eOA/\eOB) cursor keys, not only CSI
# (\e[A/\e[B); many terminals/tmux send SS3 in application-cursor-keys mode.
# Piped input has no tty (the stty calls no-op) but the byte parsing is what we test.
# ---------------------------------------------------------------------
t "readkey SS3 up"   up   (printf '\eOA' | __tcz_popup_readkey 2>/dev/null)
t "readkey SS3 down" down (printf '\eOB' | __tcz_popup_readkey 2>/dev/null)
t "readkey CSI up"   up   (printf '\e[A' | __tcz_popup_readkey 2>/dev/null)
t "readkey CSI down" down (printf '\e[B' | __tcz_popup_readkey 2>/dev/null)
t "readkey j=down"   down (printf 'j'    | __tcz_popup_readkey 2>/dev/null)
t "readkey k=up"     up   (printf 'k'    | __tcz_popup_readkey 2>/dev/null)
t "readkey x=kill"   kill (printf 'x'    | __tcz_popup_readkey 2>/dev/null)
t "readkey q=cancel" cancel (printf 'q'  | __tcz_popup_readkey 2>/dev/null)

# left/right (cap-picker's direction flip): CSI arrows + h/l, added alongside j/k/up/down.
t "readkey h=left"   left  (printf 'h'    | __tcz_popup_readkey 2>/dev/null)
t "readkey l=right"  right (printf 'l'    | __tcz_popup_readkey 2>/dev/null)
t "readkey CSI left"  left  (printf '\e[D' | __tcz_popup_readkey 2>/dev/null)
t "readkey CSI right" right (printf '\e[C' | __tcz_popup_readkey 2>/dev/null)

# n: the landing app's new-shell key. The reader is shared, so the theme picker must
# have no case for it (it stays a harmless no-op there, as `other` was). Bodies captured first.
set -l rkn (printf 'n' | __tcz_popup_readkey 2>/dev/null)
t "readkey n=n (landing: a new shell)" n "$rkn"
set -l rkthp (functions __tcz_theme_picker | string collect)
set -l rkland (functions __tcz_landing | string collect)
set -l rkg1 (string match -qr '\bcase .*\bn\b' -- "$rkland"; and echo 1; or echo 0)
set -l rkg3 (string match -qr '\bcase n\b' -- "$rkthp"; and echo 1; or echo 0)
t "readkey n: the landing loop has a case for n; the theme picker has none" "1 0" "$rkg1 $rkg3"

# --- landing: the border between the list and the legend ---
set -l lb1 (vis (__tcz_landing_border 33 46 80))
set -l lb2 (vis (__tcz_landing_border 50 0 50))
set -l lb3 (vis (__tcz_landing_border 58 1 60))
t "border: cols-1 wide with ┴ under the divider (col 34 at 80 cols)" "79 ┴" "$(string length -- "$lb1") $(string sub -s 34 -l 1 -- "$lb1")"
t "border: no preview, no ┴" "49 0" "$(string length -- "$lb2") $(string match -q '*┴*' -- "$lb2"; and echo 1; or echo 0)"
t "border: a one-column preview still draws the whole rule" "59 ┴" "$(string length -- "$lb3") $(string sub -s 59 -l 1 -- "$lb3")"

# ---------------------------------------------------------------------
# command modal — pure helpers
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# command launcher legend (design B: categorized + keybind table)
# ---------------------------------------------------------------------
function flat --description 'collapse a fish list (multiline) to one SGR-stripped space-joined string'
    set -l s (string join ' ' $argv)
    string replace -a (printf '\n') ' ' -- (vis "$s")
end
set -g LG (flat (__tcz_modal_legend 1 M-m M-t M-r M-s))
t "legend title tmux-lives"     yes (string match -q '*tmux-lives*' -- "$LG"; and echo yes; or echo no)
t "legend session header"       yes (string match -q '*session*' -- "$LG"; and echo yes; or echo no)
t "legend scratch header"       yes (string match -q '*scratch*' -- "$LG"; and echo yes; or echo no)
t "legend config header"        yes (string match -q '*config*' -- "$LG"; and echo yes; or echo no)
t "legend says picker not switcher" yes (string match -q '*picker*' -- "$LG"; and string match -q '*switcher*' -- "$LG"; and echo no; or echo yes)
t "legend command keys p/n/c/g" yes (string match -q '*p*picker*n*new*' -- "$LG"; and string match -q '*c*clear*g*categorize*' -- "$LG"; and echo yes; or echo no)
t "legend scratch cmds t/r"     yes (string match -q '*t*toggle*r*resize*' -- "$LG"; and echo yes; or echo no)
t "legend config cmd b"         yes (string match -q '*b*bar color*' -- "$LG"; and echo yes; or echo no)
t "legend keys table shows binds+fns" yes (string match -q '*M-m*menu*M-r*resize*' -- "$LG"; and string match -q '*M-t*scratch*M-s*picker*' -- "$LG"; and echo yes; or echo no)
t "legend keys table honors configured binds" yes (string match -q '*C-a*menu*' -- (flat (__tcz_modal_legend 1 C-a M-t M-r M-s)); and echo yes; or echo no)
t "legend esc close"            yes (string match -q '*esc*close*' -- "$LG"; and echo yes; or echo no)
# every legend line must render at the same visible width so the borders line up
set -g LGW
for l in (__tcz_modal_legend 1 M-m M-t M-r M-s)
    set -a LGW (string length --visible -- (vis "$l"))
end
t "legend lines all equal width (aligned pipes)" 1 (printf '%s\n' $LGW | sort -u | wc -l | string trim)
# session header uses the picker's muted yellow-orange (179), not plain orange (208)
t "session header is picker-yellow (179)" yes (string match -q '*38;5;179m session*' -- (__tcz_modal_legend 1 M-m M-t M-r M-s | string collect); and echo yes; or echo no)

t "action p -> picker" picker (__tcz_modal_action p)
t "action n -> new" new (__tcz_modal_action n)
t "action c -> clear" clear (__tcz_modal_action c)
t "action g -> categorize" categorize (__tcz_modal_action g)
t "action t -> scratch" scratch (__tcz_modal_action t)
t "action r -> resize" resize (__tcz_modal_action r)
t "action b -> color" color (__tcz_modal_action b)
t "action esc -> close" close (__tcz_modal_action esc)
t "action q -> close" close (__tcz_modal_action q)
t "action z -> noop" noop (__tcz_modal_action z)

t "readkey p" p (printf 'p' | __tcz_modal_readkey 2>/dev/null)
t "readkey r" r (printf 'r' | __tcz_modal_readkey 2>/dev/null)
t "readkey n" n (printf 'n' | __tcz_modal_readkey 2>/dev/null)
t "readkey enter" enter (printf '\r' | __tcz_modal_readkey 2>/dev/null)
t "readkey bare esc" esc (printf '\e' | __tcz_modal_readkey 2>/dev/null)

# ---------------------------------------------------------------------
# modal display-menu fallback: builder emits label/key/command triples
# ---------------------------------------------------------------------
set -g MM (__tcz_modal_menu_args | string collect)
t "menu-args lists new" yes (string match -q '*new session*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists scratch" yes (string match -q '*scratch*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists bar color" yes (string match -q '*bar color*' -- "$MM"; and echo yes; or echo no)
t "menu-args binds key n to new" yes (string match -qr 'new session\nn\n' -- "$MM"; and echo yes; or echo no)
t "menu-args labels picker not switcher" yes (string match -qr 'picker\ns\n' -- "$MM"; and not string match -qr 'switcher\ns\n' -- "$MM"; and echo yes; or echo no)

test $FAIL -eq 0; and echo ALL PASS; or echo SOME FAILED
exit $FAIL
