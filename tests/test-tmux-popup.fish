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

# ---------------------------------------------------------------------
# __tcz_popup_list_lines — full-width rules + flush-right markers + pointer
# ---------------------------------------------------------------------
set -g OV \
    (printf 'claude-x\tclaude\t1\t100\tclaude-x') \
    (printf 'neuro\trunning\t0\t90\tnvim') \
    (printf 'gen-1\tgeneral\t0\t80\tgen-1  ~/w')
# selidx 1 (neuro) selected; current = neuro
set -g L (printf '%s\n' $OV | __tcz_popup_list_lines 30 1 neuro)
# order: [1]claude rule [2]claude-x row [3]running rule [4]neuro row [5]general rule [6]gen-1 row
t "rule fills to listwidth 30"        30   (string length (vis $L[1]))
t "rule starts with category name"    yes  (string match -q '╭── claude *' (vis $L[1]); and echo yes; or echo no)
t "rule is all box-drawing fill"      yes  (string match -qr "^╭── claude ─+\$" (vis $L[1]); and echo yes; or echo no)
t "attached row width = listwidth"    30   (string length (vis $L[2]))
t "attached marker flush-right"       yes  (string match -qr "\[attached\]\$" (vis $L[2]); and echo yes; or echo no)
t "non-selected row has │ border"     yes  (string match -q '│ *' (vis $L[2]); and echo yes; or echo no)
t "border is category-colored"        yes  (string match -q '*38;5;208*│*' -- $L[2]; and echo yes; or echo no)
t "selected row carries ▐ pointer"    yes  (string match -q '*▐*' -- $L[4]; and echo yes; or echo no)
t "current row marker flush-right"    yes  (string match -qr "\[current\]\$" (vis $L[4]); and echo yes; or echo no)
t "current row width = listwidth"     30   (string length (vis $L[4]))
t "plain row padded to listwidth"     30   (string length (vis $L[6]))
# aesthetics must scale to any width:
set -g L40 (printf '%s\n' $OV | __tcz_popup_list_lines 40 0 '')
t "rule scales to listwidth 40"       40   (string length (vis $L40[1]))
# long name truncates with … when it would collide with the marker:
set -g OVlong (printf 'supercalifragilistic\trunning\t1\t50\tsupercalifragilisticexpialidocious')
set -g LL (printf '%s\n' $OVlong | __tcz_popup_list_lines 24 0 '')
t "long name truncated with ellipsis" yes  (string match -q '*…*' (vis $LL[2]); and echo yes; or echo no)
t "truncated row still flush-right"   yes  (string match -qr "\[attached\]\$" (vis $LL[2]); and echo yes; or echo no)
# a display name with a wide char: the row must still be exactly listwidth COLUMNS
# (padding measured in display columns, not characters)
set -g OVemoji (printf 'sx\tgeneral\t0\t0\tok✅done')
set -g LE (printf '%s\n' $OVemoji | __tcz_popup_list_lines 20 0 '')
t "emoji-name row = listwidth columns" 20 (string length --visible (vis $LE[2]))

# narrow width: marker dropped (not overflowed), row stays exactly listwidth
set -g TAB (printf '\t')
set -g OVnarrow (printf 'sess-attached%srunning%s1%s50%saverylongsessionname' $TAB $TAB $TAB $TAB)
set -g LNarrow (printf '%s\n' $OVnarrow | __tcz_popup_list_lines 12 0 '')
t "narrow row stays exactly listwidth" 12 (string length (vis $LNarrow[2]))

# current session (NOT the selected row): yellow ❯ chevron in the border column +
# yellow name + flush-right [current]. sel=0 (aaa selected, ▐); current=bbb.
set -g CURO (printf 'aaa%sgeneral%s0%s0%saaa\nbbb%sgeneral%s0%s0%sbbb' $TAB $TAB $TAB $TAB $TAB $TAB $TAB $TAB)
set -g CURL (printf '%s\n' $CURO | __tcz_popup_list_lines 30 0 bbb)
# CURL[1]=general header, CURL[2]=aaa (selected ▐), CURL[3]=bbb (current ❯)
t "current row border is ❯ chevron"  yes (string match -q '❯ *' (vis $CURL[3]); and echo yes; or echo no)
t "current row ends with [current]"  yes (string match -qr "\[current\]\$" (vis $CURL[3]); and echo yes; or echo no)
t "current chevron is muted-yellow"  yes (string match -q '*38;5;179*❯*' -- $CURL[3]; and echo yes; or echo no)
t "current row width = listwidth"    30  (string length (vis $CURL[3]))
t "selected row still ▐ (not ❯)"     yes (string match -q '*▐*' -- $CURL[2]; and echo yes; or echo no)

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
# __tcz_popup_preview must target plainly (no '=' prefix) and use clip
set -g PV (functions __tcz_popup_preview | string collect)
t "preview has no '=' target"   no  (string match -q '*-t "=*' -- "$PV"; and echo yes; or echo no)
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
# __tcz_popup_draw — rows must be separated by real newlines (regression)
# command-sub `(printf '\n')` strips trailing newlines → all rows on one line
# previewwidth=0 avoids capture-pane so no real tmux needed
# ---------------------------------------------------------------------
set -g TAB (printf '\t')
set -g DM1 (printf 'alpha\tclaude\t1\t100\talpha')
set -g DM2 (printf 'beta\tgeneral\t0\t80\tbeta')
# __tcz_popup_draw <sel> <listw> <prevw> <rows> <current> -- <model...>
set -g DF (__tcz_popup_draw 0 20 0 8 '' -- $DM1 $DM2)
t "draw emits multiple lines (real newlines)" yes (test (count $DF) -ge 8; and echo yes; or echo no)

# draw must NOT emit a trailing newline after the last of `rows` lines: a full-height
# popup would scroll up one row each redraw, dropping the top line (the claude-header
# bug) and flashing. rows=8 -> exactly 7 newlines (between the 8 rows), none trailing.
__tcz_popup_draw 0 20 0 8 '' -- $DM1 $DM2 > /tmp/tcz-draw-$fish_pid
set -g DNL (wc -l < /tmp/tcz-draw-$fish_pid | string trim)
rm -f /tmp/tcz-draw-$fish_pid
t "draw has no trailing newline (rows-1)" 7 "$DNL"

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

# ---------------------------------------------------------------------
# command modal — pure helpers
# ---------------------------------------------------------------------
function flat --description 'collapse a fish list (multiline) to one SGR-stripped space-joined string'
    set -l s (string join ' ' $argv)
    string replace -a (printf '\n') ' ' -- (vis "$s")
end
set -g LEG0 (flat (__tcz_modal_legend 0))
t "legend has new/clear/categorize" yes (string match -q '*new*clear*categorize*' -- "$LEG0"; and echo yes; or echo no)
t "legend has switcher/scratch/bar color" yes (string match -q '*switcher*scratch*bar color*' -- "$LEG0"; and echo yes; or echo no)
t "legend(0) hides resize row" no (string match -q '*resize*' -- "$LEG0"; and echo yes; or echo no)
set -g LEG1 (flat (__tcz_modal_legend 1))
t "legend(1) shows resize row" yes (string match -q '*resize*split*close*' -- "$LEG1"; and echo yes; or echo no)

t "action n -> new" new (__tcz_modal_action n 0)
t "action c -> clear" clear (__tcz_modal_action c 0)
t "action g -> categorize" categorize (__tcz_modal_action g 0)
t "action s -> switcher" switcher (__tcz_modal_action s 0)
t "action t -> scratch" scratch (__tcz_modal_action t 0)
t "action b -> color" color (__tcz_modal_action b 0)
t "action esc -> close" close (__tcz_modal_action esc 0)
t "action q -> close" close (__tcz_modal_action q 0)
t "action x no-scratch -> noop" noop (__tcz_modal_action x 0)
t "action x with-scratch -> scratch-close" scratch-close (__tcz_modal_action x 1)
t "action left with-scratch -> resize-left" resize-left (__tcz_modal_action left 1)
t "action h with-scratch -> orient-h" orient-h (__tcz_modal_action h 1)
t "action unknown -> noop" noop (__tcz_modal_action z 0)

t "readkey n" n (printf 'n' | __tcz_modal_readkey 2>/dev/null)
t "readkey x" x (printf 'x' | __tcz_modal_readkey 2>/dev/null)
t "readkey enter" enter (printf '\r' | __tcz_modal_readkey 2>/dev/null)
t "readkey CSI up" up (printf '\e[A' | __tcz_modal_readkey 2>/dev/null)
t "readkey CSI left" left (printf '\e[D' | __tcz_modal_readkey 2>/dev/null)
t "readkey bare esc" esc (printf '\e' | __tcz_modal_readkey 2>/dev/null)

# ---------------------------------------------------------------------
# modal display-menu fallback: builder emits label/key/command triples
# ---------------------------------------------------------------------
set -g MM (__tcz_modal_menu_args | string collect)
t "menu-args lists new" yes (string match -q '*new session*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists scratch" yes (string match -q '*scratch*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists bar color" yes (string match -q '*bar color*' -- "$MM"; and echo yes; or echo no)
t "menu-args binds key n to new" yes (string match -qr 'new session\nn\n' -- "$MM"; and echo yes; or echo no)

test $FAIL -eq 0; and echo ALL PASS; or echo SOME FAILED
exit $FAIL
