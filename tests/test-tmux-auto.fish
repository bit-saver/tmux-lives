#!/usr/bin/env fish
# Test harness for auto-tmux (conf.d/tmux.fish).
# Run: fish tests/test-tmux-auto.fish
# Uses an isolated tmux server on a private socket; never touches your real sessions.

set -g FAIL 0
set -g sock test-autotmux-$fish_pid
set -g plugindir (path resolve (status dirname)/..)

# Route every bare `tmux` call (in the harness AND in the sourced functions) to the test server.
function tmux
    command tmux -L $sock $argv
end

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

# Load the functions WITHOUT firing the startup trigger (TMUX_AUTO=0 disables it).
set -gx TMUX_AUTO 0
set -gx tmux_categorize_script $plugindir/functions/tmux-categorize.fish
source $plugindir/conf.d/tmux.fish

# ---------------------------------------------------------------------
# Selection (pure): __tmux_pick_candidates_from reads "attached last_attached name"
# lines and emits detached session names, most-recently-attached first.
# ---------------------------------------------------------------------
t "candidates: empty input -> empty"  ""            (printf '' | __tmux_pick_candidates_from | string join ',')
t "candidates: attached skipped"      ""            (printf '1 100 busy\n' | __tmux_pick_candidates_from | string join ',')
t "candidates: MRU first"             "newer,older" (printf '1 999 busy\n0 50 older\n0 200 newer\n' | __tmux_pick_candidates_from | string join ',')
t "candidates: spaces preserved"      "my work"     (printf '0 10 my work\n' | __tmux_pick_candidates_from | string join ',')
t "candidates: junk time -> 0"        "z,a"         (printf '0 junk a\n0 5 z\n' | __tmux_pick_candidates_from | string join ',')

# Selection (integration): only GENERAL (all-shell) detached sessions are eligible.
cleanup
tmux new-session -d -s shellY
tmux new-session -d -s progY 'sleep 1000'
t "pick_session: skips running, picks idle" "shellY" (__tmux_pick_session)
tmux kill-session -t shellY
t "pick_session: no idle detached -> empty" "" (__tmux_pick_session)
cleanup

# ---------------------------------------------------------------------
# Idle predicate
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s shellX
tmux new-session -d -s progX 'sleep 1000'
t "is_idle: shell-only session is idle"   "0" (__tmux_session_is_idle shellX; echo $status)
t "is_idle: program session not idle"     "1" (__tmux_session_is_idle progX; echo $status)
cleanup

# ---------------------------------------------------------------------
# Prune: detached + idle-shell + stale-by-age, protecting programs
# ---------------------------------------------------------------------
# Scenario A: now far in the future => every session is past the 48h cutoff.
cleanup
tmux new-session -d -s idleA
tmux new-session -d -s progA 'sleep 1000'
set -gx tmux_auto_now (math (date +%s) + 8640000)   # +100 days
__tmux_prune
t "prune: stale idle killed, program kept" "progA" (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')

# Scenario B: now in the past => nothing is stale, nothing killed.
tmux new-session -d -s idleB
set -gx tmux_auto_now 0
__tmux_prune
t "prune: fresh sessions untouched" "idleB,progA" (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
set -e tmux_auto_now
cleanup

# ---------------------------------------------------------------------
# Enable predicate
# ---------------------------------------------------------------------
set -e TMUX_AUTO
set -gx tmux_auto_sentinel /tmp/test-autotmux-sentinel-$fish_pid
rm -f $tmux_auto_sentinel
t "enabled: default on"            "0" (__tmux_auto_enabled; echo $status)
touch $tmux_auto_sentinel
t "enabled: sentinel disables"     "1" (__tmux_auto_enabled; echo $status)
rm -f $tmux_auto_sentinel
set -gx TMUX_AUTO 0
t "enabled: TMUX_AUTO=0 disables"  "1" (__tmux_auto_enabled; echo $status)
set -e TMUX_AUTO

# ---------------------------------------------------------------------
# Context gate
# ---------------------------------------------------------------------
set -e SSH_CONNECTION
set -e TMUX
t "should_autostart: no SSH -> false"      "1" (__tmux_should_autostart; echo $status)
set -gx SSH_CONNECTION "1.2.3.4 5 6.7.8.9 22"
set -gx TMUX /tmp/fake,1,0
t "should_autostart: inside tmux -> false" "1" (__tmux_should_autostart; echo $status)
set -e TMUX
t "should_autostart: ssh+enabled -> true"  "0" (__tmux_should_autostart; echo $status)
set -e SSH_CONNECTION

# ---------------------------------------------------------------------
# tmuxauto on/off/status
# ---------------------------------------------------------------------
rm -f $tmux_auto_sentinel
__tmux_lives_auto off >/dev/null
t "tmuxauto off creates sentinel" "yes" (test -e $tmux_auto_sentinel; and echo yes; or echo no)
__tmux_lives_auto on >/dev/null
t "tmuxauto on removes sentinel"  "no"  (test -e $tmux_auto_sentinel; and echo yes; or echo no)
rm -f $tmux_auto_sentinel

# ---------------------------------------------------------------------
# Restore disposal: save-time-claude sessions are kept as UNSTAMPED breadcrumb
# shells; other live-idle restores are killed; live work is kept AND stamped.
# ---------------------------------------------------------------------
cleanup
set -g rdir_d /tmp/test-rdird-$fish_pid
mkdir -p $rdir_d
printf 'pane\tcrumbS\t0\t1\t:*\t0\t✳ Crumb\t:/home/bitsaver\t1\tclaude\t:claude --name Crumb\n' > $rdir_d/last
set -gx tmux_resurrect_dir $rdir_d
tmux new-session -d -s crumbS
tmux new-session -d -s liveS 'sleep 1000'
tmux new-session -d -s deadS
__tmux_dispose_restored
t "dispose: breadcrumb + live kept, idle killed" "crumbS,liveS" (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
t "dispose: breadcrumb left unstamped" "" (tmux show-option -qv -t crumbS @tmux_auto_name)
t "dispose: live work stamped" "liveS" (tmux show-option -qv -t liveS @tmux_auto_name)
set -e tmux_resurrect_dir
rm -rf $rdir_d
cleanup

# ---------------------------------------------------------------------
# picker: inside tmux opens the switcher (with --take on -t); outside tmux gets you in.
cleanup
functions -c __tcz_open_switcher __tl_os_bak 2>/dev/null
function __tcz_open_switcher; set -g g_sw "$argv"; end
set -gx TMUX fake
set -g g_sw ''; __tmux_lives_picker;    t "picker inside opens switcher" "yes" (string match -q '*' -- "$g_sw"; and echo yes; or echo no)
set -g g_sw ''; __tmux_lives_picker -t; t "picker -t threads take"      "yes" (string match -q '*--take*' -- "$g_sw"; and echo yes; or echo no)
set -e TMUX
functions -e __tcz_open_switcher; functions -q __tl_os_bak; and functions -c __tl_os_bak __tcz_open_switcher
cleanup

# ---------------------------------------------------------------------
# Autostart guard: the trigger must NOT fire when conf.d/tmux.fish is SOURCED
# from within a function (fisher install/update re-sources conf.d) — only at a
# genuine top-level startup source. __tmux_trace_in_function is the pure matcher
# behind that guard; the inline `status print-stack-trace` capture is verified on
# a real host. `string match` returns 0 on match (an enclosing function present).
# ---------------------------------------------------------------------
t "trace-guard: fisher-source trace detected" "0" \
    (__tmux_trace_in_function "from sourcing file /x/conf.d/tmux.fish in function 'fisher'"; echo $status)
t "trace-guard: startup trace (no function) passes" "1" \
    (__tmux_trace_in_function "from sourcing file /x/conf.d/tmux.fish"; echo $status)
t "trace-guard: empty trace passes" "1" (__tmux_trace_in_function ""; echo $status)

# ---------------------------------------------------------------------
# __tmux_lives_start: SSH-style auto-attach on demand.
#   inside tmux  -> note only (must NOT call autostart / exec)
#   outside tmux -> delegates to __tmux_autostart (real one execs; stub to observe)
# ---------------------------------------------------------------------
functions -c __tmux_autostart __tl_as_bak
function __tmux_autostart; set -g _tl_started 1; end
set -g _tl_started 0
set -gx TMUX fake-$fish_pid
__tmux_lives_start >/dev/null 2>&1
t "start: inside tmux skips autostart" "0" "$_tl_started"
set -e TMUX
set _tl_started 0
__tmux_lives_start >/dev/null 2>&1
t "start: outside tmux runs autostart" "1" "$_tl_started"
functions -e __tmux_autostart; functions -c __tl_as_bak __tmux_autostart

# __tmux_ensure_server: no-op when a server runs; restores when none.
functions -c __tmux_restore __tl_restore_bak
function __tmux_restore; set -g g_restored 1; end
cleanup
set -g g_restored 0
__tmux_ensure_server
t "ensure_server: no server -> restores" "1" "$g_restored"
tmux new-session -d -s live
set -g g_restored 0
__tmux_ensure_server
t "ensure_server: server up -> no restore" "0" "$g_restored"
cleanup
functions -e __tmux_restore; functions -c __tl_restore_bak __tmux_restore

# ---------------------------------------------------------------------
# new: collision errors; inside tmux creates + switches; no-name -> general session.
cleanup
tmux new-session -d -s foo
set -e TMUX
set -gx TMUX fake
t "new: existing name errors (rc1)" "1" (__tmux_lives_new foo 2>/dev/null; echo $status)
__tmux_lives_new bar 2>/dev/null
t "new: creates named session" "yes" (tmux has-session -t =bar 2>/dev/null; and echo yes; or echo no)
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# attach: missing-session errors; existing inside tmux switches.
cleanup
tmux new-session -d -s keep
set -gx TMUX fake
t "attach: missing errors (rc1)"  "1" (__tmux_lives_attach nope 2>/dev/null; echo $status)
t "attach: no name errors (rc1)"  "1" (__tmux_lives_attach 2>/dev/null; echo $status)
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# close: kills the current session; outside tmux errors.
cleanup
t "close: outside tmux errors (rc1)" "1" (begin; set -e TMUX; __tmux_lives_close 2>/dev/null; echo $status; end)
tmux new-session -d -s cur
tmux new-session -d -s other
set -gx TMUX fake
# Stub the current-session lookup so the headless test has a deterministic target.
function __tmux_lives_current_session; echo cur; end
__tmux_lives_close 2>/dev/null
t "close: current session killed" "no" (tmux has-session -t =cur 2>/dev/null; and echo yes; or echo no)
t "close: other session kept" "yes" (tmux has-session -t =other 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_lives_current_session
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# clear: kills idle sessions, keeps current + non-idle.
cleanup
tmux new-session -d -s idleA
tmux new-session -d -s idleB
tmux new-session -d -s busy 'sleep 1000'
set -gx TMUX fake
function __tmux_lives_current_session; echo idleA; end
__tmux_lives_clear
t "clear: idle non-current killed" "no"  (tmux has-session -t =idleB 2>/dev/null; and echo yes; or echo no)
t "clear: current kept"            "yes" (tmux has-session -t =idleA 2>/dev/null; and echo yes; or echo no)
t "clear: non-idle kept"           "yes" (tmux has-session -t =busy 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_lives_current_session
set -e TMUX
cleanup

# ---------------------------------------------------------------------
if test $FAIL -eq 0
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
end
