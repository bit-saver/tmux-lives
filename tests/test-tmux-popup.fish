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
t "rule starts with category name"    yes  (string match -q '── claude *' (vis $L[1]); and echo yes; or echo no)
t "rule is all box-drawing fill"      yes  (string match -qr "^── claude ─+\$" (vis $L[1]); and echo yes; or echo no)
t "attached row width = listwidth"    30   (string length (vis $L[2]))
t "attached marker flush-right"       yes  (string match -qr "\[attached\]\$" (vis $L[2]); and echo yes; or echo no)
t "selected row carries ▌ pointer"    yes  (string match -q '*▌*' -- $L[4]; and echo yes; or echo no)
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

# narrow width: marker dropped (not overflowed), row stays exactly listwidth
set -g TAB (printf '\t')
set -g OVnarrow (printf 'sess-attached%srunning%s1%s50%saverylongsessionname' $TAB $TAB $TAB $TAB)
set -g LNarrow (printf '%s\n' $OVnarrow | __tcz_popup_list_lines 12 0 '')
t "narrow row stays exactly listwidth" 12 (string length (vis $LNarrow[2]))

test $FAIL -eq 0; and echo ALL PASS; or echo SOME FAILED
exit $FAIL
