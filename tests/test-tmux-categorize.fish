#!/usr/bin/env fish
# Tests for custom/scripts/tmux-categorize.fish (auto-tmux v2 categorizer).
# Run: fish ~/.config/fish/custom/scripts/test-tmux-categorize.fish
# Pure tests source the script with tmux_categorize_test set (main dispatch suppressed).
# Integration tests use an isolated socket via a PATH shim (propagates to subprocesses)
# plus a fake `claude` binary so the real detection path is exercised.

set -g FAIL 0
set -g sock test-tcz-$fish_pid
set -g shimdir /tmp/tcz-shim-$fish_pid
set -g plugindir (path resolve (status dirname)/..)

mkdir -p $shimdir
printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $sock > $shimdir/tmux
chmod +x $shimdir/tmux
# Fake claude: compiled binary so pane_current_command shows "claude" (not "sh"),
# stays running, and /proc/pid/cmdline carries all args (incl. --name ...).
command -q gcc; or begin; echo 'ABORT: gcc required to build the fake claude'; exit 1; end
printf '#include <unistd.h>\nint main(void){while(1)sleep(1);return 0;}\n' | \
    gcc -x c - -o $shimdir/claude
set -gx PATH $shimdir $PATH
# shimdir/tmux + shimdir/claude are used by integration tests added in later tasks.

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end
function cleanup
    command tmux -L $sock kill-server 2>/dev/null
    rm -f /tmp/tmux-(id -u)/$sock
end

set -g tmux_categorize_test 1
source $plugindir/functions/tmux-categorize.fish

# ---------------------------------------------------------------------
# Pure-ish: __tcz_pane_is_claude (cmd fast-path + sh/comm fallback)
# ---------------------------------------------------------------------
t "is_claude: cmd claude -> yes" "0" (__tcz_pane_is_claude claude 1; echo $status)
$shimdir/claude --enable-auto-mode &
set -l icpid $last_pid
sleep 0.2
t "is_claude: sh wrapper + comm -> yes" "0" (__tcz_pane_is_claude sh $icpid; echo $status)
t "is_claude: fish pane -> no" "1" (__tcz_pane_is_claude fish $icpid; echo $status)
kill $icpid 2>/dev/null

# ---------------------------------------------------------------------
# Pure: name helpers
# ---------------------------------------------------------------------
t "slug: spaces -> dashes"        "TMUX-Setup-2"      (__tcz_slugify "TMUX Setup 2")
t "slug: dots/colons stripped"    "a-b-c"             (__tcz_slugify "a.b:c")
t "slug: trims edge dashes"       "mid-dle"           (__tcz_slugify "  mid dle! ")
t "slug: empty -> session"        "session"           (__tcz_slugify "...")
t "title: glyph stripped"         "TMUX Setup 2"      (__tcz_title_name "✳ TMUX Setup 2")
t "title: spinner stripped"       "TMUX Setup 2"      (__tcz_title_name "⠂ TMUX Setup 2")
t "title: task suffix dropped"    "Tasker Editor 14"  (__tcz_title_name "✳ Tasker Editor 14 - Reword task")
t "title: garbage -> empty"       ""                  (__tcz_title_name "Gi=1,a=q;")
t "freenum: empty -> 0"           "0"                 (__tcz_free_number)
t "freenum: skips used"           "2"                 (__tcz_free_number 0 1 work 5)
t "unique: free name unchanged"   "lnav"              (__tcz_unique lnav work 0)
t "unique: collision suffixed"    "lnav-2"            (__tcz_unique lnav lnav work)
t "unique: counts up"             "lnav-3"            (__tcz_unique lnav lnav lnav-2)
t "slug: already clean -> unchanged"   "lnav"          (__tcz_slugify "lnav")
t "slug: multi-arg joined"             "foo-bar"       (__tcz_slugify foo bar)
t "slug: leading dash stripped"        "foo"           (__tcz_slugify "-foo")
t "title: variation-selector glyph ok" "TMUX Setup 2"  (__tcz_title_name "✳️ TMUX Setup 2")
t "unique: desired ending in -2"       "lnav-2-2"      (__tcz_unique lnav-2 lnav-2)

# ---------------------------------------------------------------------
# __tcz_cmdline_name: --name extraction from a live (fake) claude process
# ---------------------------------------------------------------------
$shimdir/claude --enable-auto-mode --name TMUX Setup 2 &
set -l fakepid $last_pid
sleep 0.2
t "cmdline: --name extracted (multi-word)" "TMUX Setup 2" (__tcz_cmdline_name $fakepid)
kill $fakepid 2>/dev/null
$shimdir/claude --enable-auto-mode &
set -l fakepid2 $last_pid
sleep 0.2
t "cmdline: no --name -> empty" "" (__tcz_cmdline_name $fakepid2)
kill $fakepid2 2>/dev/null
t "cmdline: bogus pid -> empty" "" (__tcz_cmdline_name 99999999)

$shimdir/claude --enable-auto-mode --name Flag Tail --resume &
set -l fakepid3 $last_pid
sleep 0.2
t "cmdline: trailing flags stripped" "Flag Tail" (__tcz_cmdline_name $fakepid3)
kill $fakepid3 2>/dev/null
# child path: pass the PARENT pid; claude is its direct child (pgrep -P branch)
fish -c "$shimdir/claude --enable-auto-mode --name Child Test & sleep 3" &
set -l parentpid $last_pid
sleep 0.4
t "cmdline: found via child pgrep" "Child Test" (__tcz_cmdline_name $parentpid)
kill $parentpid 2>/dev/null
pkill -f 'Child Test' 2>/dev/null

# ---------------------------------------------------------------------
# __tcz_snapshot (integration, isolated socket via PATH shim)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s c1 "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s r1 -c /tmp 'sleep 1000'
tmux new-session -d -s g1 -c $HOME
sleep 0.5     # let pane_current_command settle
t "snap: categories"  "c1	claude,g1	general,r1	running" \
    (__tcz_snapshot | cut -f1,2 | sort | string join ',')
t "snap: claude display from --name" "TMUX Setup 2" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f5)
t "snap: running display = command"  "sleep" \
    (__tcz_snapshot | string match -e 'r1	*' | cut -f5)
t "snap: general display = ~cwd"     "~" \
    (__tcz_snapshot | string match -e 'g1	*' | cut -f5)
t "snap: detached flag"              "0" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f3)
# display fallbacks: no --name -> gated title; unusable title -> claude-<cwd>
cleanup
mkdir -p /tmp/tcz-myproj-$fish_pid
tmux new-session -d -s c_title "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_title: -T "✳ My Work Project"
tmux new-session -d -s c_cwd -c /tmp/tcz-myproj-$fish_pid "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_cwd: -T ""
sleep 0.5
t "snap: claude display from title" "My Work Project" \
    (__tcz_snapshot | string match -e 'c_title	*' | cut -f5)
t "snap: claude display from cwd"   "claude-tcz-myproj-$fish_pid" \
    (__tcz_snapshot | string match -e 'c_cwd	*' | cut -f5)
rm -rf /tmp/tcz-myproj-$fish_pid
cleanup
t "snap: no server -> empty" "" (__tcz_snapshot | string join ',')

# ---------------------------------------------------------------------
# __tcz_categorize (integration)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0 "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s 1 'sleep 1000'
tmux new-session -d -s 2
tmux new-session -d -s handname 'sleep 1000'      # unowned non-numeric -> guard protects
sleep 0.5
__tcz_categorize
t "cat: claude renamed to slug"  "yes" (tmux has-session -t =TMUX-Setup-2 2>/dev/null; and echo yes; or echo no)
t "cat: claude stamped"          "TMUX-Setup-2" (tmux show-option -qv -t TMUX-Setup-2 @tmux_auto_name)
t "cat: running renamed to cmd"  "yes" (tmux has-session -t =sleep 2>/dev/null; and echo yes; or echo no)
t "cat: numeric general kept"    "yes" (tmux has-session -t =2 2>/dev/null; and echo yes; or echo no)
t "cat: hand-named protected"    "yes" (tmux has-session -t =handname 2>/dev/null; and echo yes; or echo no)
t "cat: idempotent (no churn)"   "" (__tcz_categorize | string join ',')

# revert: owned claude-named session whose claude died -> numeric
tmux kill-session -t =TMUX-Setup-2
tmux new-session -d -s stale-claude
tmux set-option -t stale-claude @tmux_auto_name stale-claude
__tcz_categorize
t "cat: owned idle reverts to number" "0" \
    (tmux list-sessions -F '#{session_name}' | string match -r '^[0-9]+$' | sort -n | head -n1)

# collision: two OWNED (numeric) claude sessions with the same --name
cleanup
tmux new-session -d -s 0 "$shimdir/claude --name Same Name"
tmux new-session -d -s 1 "$shimdir/claude --name Same Name"
sleep 0.5
__tcz_categorize
t "cat: collision suffixed" "Same-Name,Same-Name-2" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
# guard: a hand-NAMED claude session is never renamed
tmux new-session -d -s myclaude "$shimdir/claude --name Steal"
sleep 0.5
__tcz_categorize
t "cat: hand-named claude protected" "yes" \
    (tmux has-session -t =myclaude 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# lifecycle: rename when claude starts in a shell pane, revert when it exits
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0
tmux send-keys -t 0 "$shimdir/claude --enable-auto-mode --name Lifecycle" Enter
sleep 0.8
__tcz_categorize
t "cat: lifecycle rename via shell pane" "yes" (tmux has-session -t =Lifecycle 2>/dev/null; and echo yes; or echo no)
t "cat: lifecycle used the fake binary" "yes" \
    (pgrep -af -- '--name Lifecycle' | string match -q "*$shimdir*"; and echo yes; or echo no)
# Kill the claude process directly (SIGTERM; C-c/SIGINT is absorbed by fish job control).
set -l lcpid (tmux list-panes -t Lifecycle -F '#{pane_pid}' 2>/dev/null)
pkill -TERM -P $lcpid 2>/dev/null; or kill -TERM $lcpid 2>/dev/null
sleep 0.5
__tcz_categorize
t "cat: lifecycle revert to numeric" "yes" (tmux has-session -t =0 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# __tcz_overview: claude -> running -> general, MRU within group
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s g1
tmux new-session -d -s r1 'sleep 1000'
tmux new-session -d -s c1 "$shimdir/claude --name Zed"
sleep 0.5
t "overview: group order" "claude,running,general" \
    (__tcz_overview | cut -f2 | string join ',')
cleanup

# ---------------------------------------------------------------------
# Ghosts: pure cutoff filter + live no-op safety
# ---------------------------------------------------------------------
t "ghosts_from: stale client listed"  "old"  (printf 'old\t100\nfresh\t900\n' | __tcz_ghosts_from 500 | string join ',')
t "ghosts_from: fresh kept"           ""     (printf 'fresh\t900\n' | __tcz_ghosts_from 500 | string join ',')
t "ghosts_from: junk line skipped"    ""     (printf 'bad\tnotnum\n' | __tcz_ghosts_from 500 | string join ',')
cleanup
tmux new-session -d -s lonely
t "ghosts: clientless session no-op (rc 0)" "0" (__tcz_ghosts lonely; echo $status)
# NOTE: the actual tmux detach-client branch is untestable in a headless harness
# (list-clients is always empty without a real terminal). __tcz_ghosts_from, which
# selects the candidates, is tested above; live behavior is verified at deployment.
cleanup

# ---------------------------------------------------------------------
# __tcz_menu_args (pure): overview lines -> display-menu argv triples
# ---------------------------------------------------------------------
set -l ov (printf 'Zed-1\tclaude\t1\t900\tZed\nlnav\trunning\t0\t800\tlnav\n3\tgeneral\t0\t0\t~\n')
# Collect via while-read (NOT command substitution): the header triples contain
# empty key/command lines that must survive as empty list elements.
set -l args
printf '%s\n' $ov | __tcz_menu_args | while read -l a
    set -a args "$a"
end
t "menu: 3 headers + 3 items, 3 args each" "18" (count $args)
t "menu: first header disabled (- prefix)" "-" (string sub -l 1 -- $args[1])
# Headers: color-coded (orange/cyan/green), name left-anchored after a 4-dash
# lead-in, trailing rule to the menu width. Indicators are bracketed and
# right-aligned at a common column (widest base "lnav"=4 +2 → col 6; widest
# label "Zed   [attached]"=16; +4 key chrome → rule width 20).
t "menu: claude header orange left-anchored" "-#[fg=colour208,bold]──── claude ────────#[default]" $args[1]
t "menu: running header cyan left-anchored"  "-#[fg=cyan,bold]──── running ───────#[default]"      $args[7]
t "menu: general header green left-anchored" "-#[fg=green,bold]──── general ───────#[default]"     $args[13]
t "menu: claude label right-aligned [attached]" "Zed   [attached]" $args[4]
t "menu: numeric shortcut keys" "1" $args[5]
# Selection runs ONE run-shell -> `switch` subcommand (ghosts + switch-client with
# proper argv). Brace-quoted {=name} targets are FORBIDDEN: tmux 3.3a parses them
# as command blocks at selection time -> "unknown command: =name" in the status bar.
t "menu: item runs the switch subcommand" "yes" \
    (string match -q "*tmux-categorize.fish switch 'Zed-1' *" -- $args[6]; and echo yes; or echo no)
t "menu: item passes the choosing client" "yes" \
    (string match -q '*#{client_name}*' -- $args[6]; and echo yes; or echo no)
t "menu: no brace-quoted target (parse bug)" "no" \
    (string match -q '*{=*' -- $args[6]; and echo yes; or echo no)

# Regression: special-char (hand-named) sessions survive all quoting layers
set -l args_sq
printf "foo'bar\tclaude\t0\t900\tfoo'bar\n" | __tcz_menu_args | while read -l a
    set -a args_sq "$a"
end
t "menu: quote-name switch arg sh-escaped" "yes" \
    (string match -q "*switch 'foo'\\''bar' *" -- $args_sq[6]; and echo yes; or echo no)
t "menu: quote-name no braces either" "no" \
    (string match -q '*{=*' -- $args_sq[6]; and echo yes; or echo no)

# Current-session marker: passed as an argument so the builder stays pure.
set -l ov_cur (printf 'Zed-1\tclaude\t1\t900\tZed\nlnav\trunning\t0\t800\tlnav\n')
set -l args_cur
printf '%s\n' $ov_cur | __tcz_menu_args Zed-1 | while read -l a
    set -a args_cur "$a"
end
t "menu: current gets dim right-aligned [current]" "#[dim]▸ Zed  [current]#[default]" $args_cur[4]
t "menu: non-current rows unchanged"    "lnav"                             $args_cur[10]
set -l args_bogus
printf '%s\n' $ov_cur | __tcz_menu_args nosuch | while read -l a
    set -a args_bogus "$a"
end
t "menu: unknown current leaves labels alone" "Zed   [attached]" $args_bogus[4]

# ---------------------------------------------------------------------
# __tcz_claim (integration): instant claude rename from preexec data
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "My Project" /tmp
t "claim: renamed from raw name" "yes" (tmux has-session -t =My-Project 2>/dev/null; and echo yes; or echo no)
t "claim: stamped"               "My-Project" (tmux show-option -qv -t My-Project @tmux_auto_name)
__tcz_claim $pane "" /tmp/someproj
t "claim: empty raw -> claude-cwd" "yes" (tmux has-session -t =claude-someproj 2>/dev/null; and echo yes; or echo no)
tmux rename-session -t =claude-someproj handpick
__tcz_claim $pane "Steal Attempt" /tmp
t "claim: guard protects hand-rename" "yes" (tmux has-session -t =handpick 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# Dispatcher + tick silence (subprocess — exercises the real entrypoint)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0 'sleep 1000'
t "main: tick emits nothing"  "" (fish --no-config $plugindir/functions/tmux-categorize.fish tick | string join ',')
t "main: tick renamed via subprocess" "yes" (tmux has-session -t =sleep 2>/dev/null; and echo yes; or echo no)
t "main: slug subcommand" "prod-debug" (fish --no-config $plugindir/functions/tmux-categorize.fish slug "prod:debug")
# switch subcommand: headless (no client) must degrade silently, rc 0
cleanup
tmux new-session -d -s sw1
t "switch: headless degrades silently (rc 0)" "0" (__tcz_switch sw1 ''; echo $status)
cleanup
t "main: bad subcommand rc=1" "1" (fish --no-config $plugindir/functions/tmux-categorize.fish bogus 2>/dev/null; echo $status)
cleanup

# ---------------------------------------------------------------------
# __tcz_pick_general + __tcz_commandeer (ShellFish springboard bounce).
# Headless caveat: switch-client always fails without a real client, which is
# exactly what lets us pin the failure-path guarantees (springboard preserved,
# fallback session cleaned up). The success path is verified live.
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s busy 'sleep 1000'
tmux new-session -d -s shellfish-8
sleep 0.3
t "newgen: creates smallest-free general" "0" (__tcz_new_general)
t "pickgen: MRU detached general, springboard excluded" "0" (__tcz_pick_general shellfish-8)
t "commandeer: non-shellfish name no-op" "0" (__tcz_commandeer /dev/null busy; echo $status)
tmux new-session -d -s shellfish-9 'sleep 1000'
sleep 0.3
__tcz_commandeer /dev/null shellfish-9
t "commandeer: busy shellfish untouched" "yes" (tmux has-session -t =shellfish-9 2>/dev/null; and echo yes; or echo no)
__tcz_commandeer /dev/pts/nonexistent shellfish-8
t "commandeer: failed switch keeps springboard" "yes" (tmux has-session -t =shellfish-8 2>/dev/null; and echo yes; or echo no)
t "commandeer: target untouched on failed switch" "yes" (tmux has-session -t =0 2>/dev/null; and echo yes; or echo no)
tmux kill-session -t 0
__tcz_commandeer /dev/pts/nonexistent shellfish-8
t "commandeer: fallback session cleaned up on failed switch" "busy,shellfish-8,shellfish-9" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
cleanup

# ---------------------------------------------------------------------
# The shell list must match __tmux_session_is_idle in conf.d/tmux.fish.
# ---------------------------------------------------------------------
set -l confd_list (string match -r 'contains -- \$cmd ([a-z ]+); or return' < $plugindir/conf.d/tmux.fish)[2]
t "shell lists in sync" "$__tcz_shells" "$confd_list"

rm -rf $shimdir
if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
