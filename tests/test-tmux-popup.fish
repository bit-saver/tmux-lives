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
