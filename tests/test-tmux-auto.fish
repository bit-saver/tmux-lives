#!/usr/bin/env fish
# Test harness for auto-tmux (conf.d/tmux.fish).
# Run: fish tests/test-tmux-auto.fish
# Uses an isolated tmux server on a private socket; never touches your real sessions.

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
set -g sock test-autotmux-$fish_pid
set -g plugindir (path resolve (status dirname)/..)

# ---- isolation prologue ---------------------------------------------------
# This shell runs inside the user's live tmux, and any SUBPROCESS that calls a
# bare `tmux` (a categorizer verb, a child fish) would reach his real server.
# So isolation is structural rather than a per-test convention:
#   - PATH: a `tmux` script pinned to this suite's -L socket ahead of the real one
#   - TMUX / TMUX_PANE erased: TMUX outranks -L and TMUX_TMPDIR for a bare call
#   - tmux_categorize_script: a recorder stub; a test that needs the real script
#     opts in explicitly ($real_cat_path)
#   - claude-project discovery seams: temp paths; the real cache is bracketed
set -g __tac_realtmux (command -s tmux)
if test -z "$__tac_realtmux"
    echo "FATAL: no tmux on PATH; refusing to run" >&2
    exit 1
end
set -g __tac_shim $TMUX_LIVES_TEST_UVARS/shim
mkdir -p $__tac_shim
printf '#!/bin/sh\nexec %s -L %s -f /dev/null "$@"\n' $__tac_realtmux $sock > $__tac_shim/tmux
chmod +x $__tac_shim/tmux
set -gx PATH $__tac_shim $PATH
set -e TMUX
set -e TMUX_PANE
set -g real_cat_path $plugindir/functions/tmux-categorize.fish
set -g __tac_cat_stub $TMUX_LIVES_TEST_UVARS/cat-stub.fish
printf '#!/usr/bin/env fish\nprintf "%%s\\n" "$argv" >> %s/cat-calls.log\n' $TMUX_LIVES_TEST_UVARS > $__tac_cat_stub
# Checked at the end for this run's footprint (not its mtime: the user's own landing apps rewrite it).
set -g __tac_real_proj_cache "$HOME/.cache/tmux-lives/projects.tsv"
set -g __tac_real_proj_rows_before (cat "$__tac_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
set -gx tmux_lives_claude_projects_dir $TMUX_LIVES_TEST_UVARS/claude-projects
set -g __tac_proj_root $tmux_lives_claude_projects_dir
set -gx tmux_lives_project_cache $TMUX_LIVES_TEST_UVARS/projects.tsv
# Landing needs the managed fragment; run as a set-up host unless a test says not.
set -g tmux_lives_fragment_file $TMUX_LIVES_TEST_UVARS/fragment.conf
touch $tmux_lives_fragment_file

# Every bare `tmux` in the harness AND in the sourced functions lands on the test
# server (the PATH script above adds -L and -f /dev/null, so a fresh server never
# loads ~/.tmux.conf). Kept as a function so tests can wrap it with `functions -c`.
function tmux
    command tmux $argv
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
set -gx tmux_categorize_script $__tac_cat_stub
source $plugindir/conf.d/tmux.fish

# Self-check: a subprocess's bare `tmux` really is pinned to this suite's socket
# (and not the user's live one), or every isolation claim above is vacuous.
cleanup
set -l iso_sock (env -u TMUX sh -c 'tmux new-session -d -s iso-probe && tmux display-message -p -t iso-probe "#{socket_path}"')
t "isolation: a subprocess's bare tmux hits this suite's own socket" "$sock" (path basename -- "$iso_sock")
t "isolation: TMUX is erased for the whole suite" 0 (set -q TMUX; and echo 1; or echo 0)
cleanup

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

# pick_session must never return a landing session. Both are idle bare shells
# that were never attached, so their MRU keys tie at 0 and sort falls back to
# comparing the whole line ascending: "_landing-9" ahead of "shellL" whatever
# the creation order. Unfixed code therefore picks the landing session.
tmux new-session -d -s _landing-9
tmux new-session -d -s shellL
t "pick_session: never returns a landing session" "shellL" (__tmux_pick_session)
cleanup
# The only idle candidate is a landing session: nothing is picked at all.
tmux new-session -d -s _landing-9
tmux new-session -d -s progL 'sleep 1000'
t "pick_session: a landing session as the only idle candidate -> empty" "" (__tmux_pick_session)
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
# Session-vs-window name collision (2026-09-13). Every Claude window is named
# "claude", so a bare -t claude can resolve to ANOTHER session's window of that
# name -- and the idle check decides what prune/dispose KILL. Built in both
# creation orders with TMUX/TMUX_PANE erased, because which session tmux treats
# as current decides whether the bare form misresolves.
# ---------------------------------------------------------------------
function __tac_build --argument-names order target_cmd other_cmd --description 'session claude (window main) + session other (WINDOW named claude); an empty cmd means an idle shell pane'
    cleanup
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
    end
    set -l tc; test -n "$target_cmd"; and set tc $target_cmd
    set -l oc; test -n "$other_cmd"; and set oc $other_cmd
    if test "$order" = target-first
        command tmux -L $sock -f /dev/null new-session -d -s claude -n main $tc
        command tmux -L $sock new-session -d -s other -n claude $oc
    else
        command tmux -L $sock -f /dev/null new-session -d -s other -n claude $oc
        command tmux -L $sock new-session -d -s claude -n main $tc
    end
    sleep 0.3
end

set -q TMUX; and set -g __tac_saved_tmux $TMUX
set -q TMUX_PANE; and set -g __tac_saved_pane $TMUX_PANE
set -e TMUX; set -e TMUX_PANE
set -g __tac_collides 0
set -g __tac_rdir /tmp/test-tac-rdir-$fish_pid
mkdir -p $__tac_rdir
# Non-regression: this loop's __tmux_lives_close calls assert the pre-landing
# direct path (detach-on-destroy on the exact session, then kill), which only
# runs with landing off. (Isolation no longer depends on this: see the prologue.)
set -g tmux_lives_landing off
for order in target-first target-last
    # busy "claude", idle-shell "other"
    __tac_build $order 'sleep 1000' ''
    set -l bare (command tmux -L $sock list-panes -s -t claude -F '#{session_name}' 2>/dev/null)
    test "$bare[1]" = other; and set -g __tac_collides 1
    set -l busy (__tmux_session_is_idle claude; echo $status)
    t "collision[$order]: a busy session named claude is not idle" 1 "$busy"

    # dispose (nothing saved -> no breadcrumbs) must keep and stamp the busy one
    set -gx tmux_resurrect_dir $__tac_rdir
    __tmux_dispose_restored
    set -e tmux_resurrect_dir
    set -l kept (command tmux -L $sock has-session -t =claude 2>/dev/null; and echo yes; or echo no)
    t "collision[$order]: dispose keeps the busy session named claude" yes "$kept"

    # idle "claude", busy "other": the idle one must still read as idle
    __tac_build $order '' 'sleep 1000'
    set -l idle (__tmux_session_is_idle claude; echo $status)
    t "collision[$order]: an idle session named claude is idle" 0 "$idle"

    # both busy: dispose stamps each session with its OWN name
    __tac_build $order 'sleep 1000' 'sleep 1000'
    set -gx tmux_resurrect_dir $__tac_rdir
    __tmux_dispose_restored
    set -e tmux_resurrect_dir
    set -l stamps (command tmux -L $sock list-sessions -F '#{session_name}=#{@tmux_auto_name}' | sort | string join ,)
    t "collision[$order]: dispose stamps each busy session with its own name" "claude=claude,other=other" "$stamps"

    # a claude BREADCRUMB (saved pane ran claude) named claude, next to other whose window is claude
    __tac_build $order '' 'sleep 1000'
    printf 'pane\tclaude\t0\t1\t:*\t0\tmain\t:/tmp\t1\tclaude\t:\n' > $__tac_rdir/last
    set -gx tmux_resurrect_dir $__tac_rdir
    __tmux_dispose_restored
    set -e tmux_resurrect_dir
    rm -f $__tac_rdir/last
    set -l cstamps (command tmux -L $sock list-sessions -F '#{session_name}=#{@tmux_auto_name}' | sort | string join ,)
    t "collision[$order]: dispose stamps a breadcrumb named claude on itself" "claude=claude,other=other" "$cstamps"

    # close aimed at "claude" must set detach-on-destroy on claude itself, never on other.
    # Intercept kill-session so claude survives long enough to read the option back.
    __tac_build $order 'sleep 1000' 'sleep 1000'
    functions -c tmux __tac_tmux_bak
    function tmux
        test "$argv[1]" = kill-session; and return 0
        command tmux -L $sock $argv
    end
    set -gx TMUX fake
    function __tmux_lives_current_session; echo claude; end
    __tmux_lives_close 2>/dev/null
    functions -e __tmux_lives_current_session
    set -e TMUX
    functions -e tmux; functions -c __tac_tmux_bak tmux; functions -e __tac_tmux_bak
    set -l dod_t (command tmux -L $sock show-options -v -t '=claude:' detach-on-destroy 2>/dev/null)
    t "collision[$order]: close sets detach-on-destroy on session claude itself" on "$dod_t"
    set -l dod (command tmux -L $sock show-options -v -t other detach-on-destroy 2>/dev/null)
    t "collision[$order]: close leaves other's detach-on-destroy untouched" "" "$dod"

    # close, uninterrupted: the kill itself must actually happen.
    __tac_build $order 'sleep 1000' 'sleep 1000'
    set -gx TMUX fake
    function __tmux_lives_current_session; echo claude; end
    __tmux_lives_close 2>/dev/null
    functions -e __tmux_lives_current_session
    set -e TMUX
    set -l gone (command tmux -L $sock has-session -t =claude 2>/dev/null; and echo yes; or echo no)
    t "collision[$order]: close kills session claude" no "$gone"
end
set -e tmux_lives_landing
t "collision: the fixture reproduced tmux's session/window ambiguity in at least one order" 1 "$__tac_collides"
set -q __tac_saved_tmux; and set -gx TMUX $__tac_saved_tmux
set -q __tac_saved_pane; and set -gx TMUX_PANE $__tac_saved_pane
rm -rf $__tac_rdir
set -e __tac_saved_tmux __tac_saved_pane __tac_collides __tac_rdir
functions -e __tac_build
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

# Scenario B2: a stale, detached, idle landing session is not prune's business
# (the tick sweep owns landing sessions).
cleanup
tmux new-session -d -s _landing-4
set -gx tmux_auto_now (math (date +%s) + 8640000)   # +100 days: stale
__tmux_prune
set -e tmux_auto_now
t "prune: a stale idle landing session survives" yes \
    (tmux has-session -t "=_landing-4" 2>/dev/null; and echo yes; or echo no)
cleanup

# Scenario C: a same-pass race -- the session vanishes between the idle check
# and prune's own kill. An unquoted kill-session -t target then PREFIX-matches,
# so "claude" disappearing must not also take "claude-2" down with it. Stub the
# idle check so checking "claude" performs the race itself (kills =claude via
# an exact target, simulating another actor winning the race) and reports
# idle; checking anything else (claude-2) reports NOT idle, so claude-2 is
# never a legitimate prune target on its own -- only the prefix-match hazard
# can kill it.
cleanup
tmux new-session -d -s claude
tmux new-session -d -s claude-2
set -gx tmux_auto_now (math (date +%s) + 8640000)   # +100 days: both stale
functions -c __tmux_session_is_idle __tac_idle_bak
function __tmux_session_is_idle --argument-names session
    if test "$session" = claude
        tmux kill-session -t "=claude" 2>/dev/null
        return 0
    end
    return 1
end
__tmux_prune
functions -e __tmux_session_is_idle
functions -c __tac_idle_bak __tmux_session_is_idle
functions -e __tac_idle_bak
set -e tmux_auto_now
t "prune: a same-pass race removing claude does not prefix-kill claude-2" yes \
    (tmux has-session -t "=claude-2" 2>/dev/null; and echo yes; or echo no)
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
# A restored _landing-2 that even LOOKS like a save-time claude breadcrumb
# (so it lands in $crumbs too) must still be purged -- the landing check
# has to run before, not after, the crumb check.
printf 'pane\t_landing-2\t0\t1\t:*\t0\t✦ Landing\t:/home/bitsaver\t1\tclaude\t:claude --name Landing\n' >> $rdir_d/last
set -gx tmux_resurrect_dir $rdir_d
tmux new-session -d -s crumbS
tmux new-session -d -s liveS 'sleep 1000'
tmux new-session -d -s deadS
tmux new-session -d -s _landing-2
__tmux_dispose_restored
t "dispose: breadcrumb + live kept, idle killed, landing purged despite looking like a crumb" "crumbS,liveS" (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
# Stamped like every other kept session (2026-08-30). Unstamped meant the
# ownership guard froze the name AND blocked the display write, so a restored
# breadcrumb could never track its pane once naming moved to the pane's cwd.
t "dispose: breadcrumb is stamped, so it can still be renamed later" "crumbS" (tmux show-option -qv -t crumbS @tmux_auto_name)
t "dispose: live work stamped" "liveS" (tmux show-option -qv -t liveS @tmux_auto_name)
set -e tmux_resurrect_dir
rm -rf $rdir_d
cleanup

# M-2: a landing session a client is already on (a login during the boot-time
# restore window) is live, not restored -- killing it would end that login.
set -gx tmux_resurrect_dir $TMUX_LIVES_TEST_UVARS/rdir-m2
mkdir -p $tmux_resurrect_dir
tmux new-session -d -s _landing-3
tmux new-session -d -s _landing-4
sleep 30 | env SHELL=/bin/sh TERM=xterm-256color script -qec "tmux attach -t =_landing-4" /dev/null >/dev/null 2>&1 &
set -l m2pids (jobs -p)
set -l m2att 0
for i in (seq 25)
    set -l c (command tmux -L $sock list-clients -t =_landing-4 2>/dev/null)
    test -n "$c"; and set m2att 1; and break
    sleep 0.2
end
__tmux_dispose_restored
set -l m2left (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
t "M-2: dispose keeps a landing session with a client on it, purges the clientless one" "1 _landing-4" "$m2att $m2left"
for p in $m2pids; kill $p 2>/dev/null; end
set -e tmux_resurrect_dir
rm -rf $TMUX_LIVES_TEST_UVARS/rdir-m2
cleanup

# ---------------------------------------------------------------------
# picker inside tmux runs the categorizer SUBPROCESS `open-switcher <client> [--take]`
# (the __tcz_* helpers are not autoloaded into the interactive shell, so the real code
# must shell out — can't stub them in-shell). Point tmux_categorize_script at a recorder
# and inspect the args it received.
cleanup
tmux new-session -d -s pk1
set -gx TMUX fake
set -g real_cat $tmux_categorize_script
set -g pk_rec /tmp/picker-rec-$fish_pid
set -g pk_stub /tmp/picker-stub-$fish_pid.fish
set -g tmux_categorize_script $pk_stub
printf '#!/usr/bin/env fish\nprintf "%%s\\n" $argv > %s\n' $pk_rec > $pk_stub
__tmux_lives_picker
t "picker inside calls open-switcher subcmd" "open-switcher" (head -1 $pk_rec 2>/dev/null)
t "picker (no -t) omits --take"              "no"  (grep -qx -- --take $pk_rec 2>/dev/null; and echo yes; or echo no)
__tmux_lives_picker -t
t "picker -t threads --take to open-switcher" "yes" (grep -qx -- --take $pk_rec 2>/dev/null; and echo yes; or echo no)
set -g tmux_categorize_script $real_cat
rm -f $pk_stub $pk_rec
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# fish_postexec must NARROW the pass to this pane's session. It fires after
# every command in every shell, backgrounded and disowned so passes overlap
# rather than serialize -- measured on macwork as the dominant driver of load
# (holding client count constant and removing only command activity cut process
# spawns by 86%). A command run in this pane cannot change another session's
# classification, so the whole-server pass it used to do was N times the
# necessary work by construction. Nothing covered the argument, so dropping it
# would silently revert to a full pass with the gate still green.
# ---------------------------------------------------------------------
set -gx TMUX fake
set -gx TMUX_PANE '%99'
set -g pe_rec /tmp/postexec-rec-$fish_pid
set -g pe_stub /tmp/postexec-stub-$fish_pid.fish
set -g real_cat2 $tmux_categorize_script
set -g tmux_categorize_script $pe_stub
printf '#!/usr/bin/env fish\nprintf "%%s\\n" $argv > %s\n' $pe_rec > $pe_stub
__tmux_categorize_on_postexec
sleep 0.5
t "postexec: dispatches the categorize verb"        "categorize" (head -1 $pe_rec 2>/dev/null)
t "postexec: passes the pane so the pass is narrowed" '%99'      (sed -n 2p $pe_rec 2>/dev/null)
set -g tmux_categorize_script $real_cat2
rm -f $pe_stub $pe_rec
set -e TMUX_PANE
set -e TMUX
cleanup

# M6: outside-tmux picker -t must include --take in the popup command string.
# Inspect __tmux_lives_picker source: when $take is set, it appends "$take" to $pop.
# Verify by reading the function source directly.
set -l picker_src (functions __tmux_lives_picker | string collect)
t "picker -t outside-tmux: take appended to pop command" "yes" \
    (string match -q '*test -n "$take"; and set pop "$pop $take"*' -- "$picker_src"; and echo yes; or echo no)

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
# Opts IN to the real categorizer (the `slug` verb): the suite default is a stub.
# Safe: the script's own bare tmux calls land on the suite socket (prologue).
set -g tmux_categorize_script $real_cat_path
cleanup
tmux new-session -d -s foo
set -e TMUX
set -gx TMUX fake
t "new: existing name errors (rc1)" "1" (__tmux_lives_new foo 2>/dev/null; echo $status)
__tmux_lives_new bar 2>/dev/null
t "new: creates named session" "yes" (tmux has-session -t =bar 2>/dev/null; and echo yes; or echo no)
# I3: no-name branch inside tmux must create a new session (gen-N or numeric).
# switch-client no-ops headless (no real client) — that's fine; assert creation only.
set -l sess_before (tmux list-sessions -F '#{session_name}' 2>/dev/null | count)
__tmux_lives_new 2>/dev/null
set -l sess_after (tmux list-sessions -F '#{session_name}' 2>/dev/null | count)
t "new: no-name inside tmux creates a session" "yes" (test $sess_after -gt $sess_before; and echo yes; or echo no)

# Creation cwd: a session is born where you were. Both in-tmux branches
# inherit the invoking shell's cwd instead of forcing the home directory,
# so `tmux-lives new` from a project pane starts in that project.
set -l ncdir /tmp/tl-newcwd-$fish_pid
mkdir -p $ncdir
set -l nc_saved $PWD
set -l nc_before (tmux list-sessions -F '#{session_name}' 2>/dev/null)
# The no-name branch calls __tmux_categorize, which SHELLS OUT -- and this
# suite's tmux shim is a fish function, which does not reach a subprocess.
# Today that is saved only by the bogus TMUX set above making the subprocess's
# tmux fail to connect at all. Stub it rather than lean on that coincidence:
# the assertion below is about the birth directory, not about categorizing.
functions -c __tmux_categorize __tl_cwd_cat_bak
function __tmux_categorize; end
cd $ncdir
__tmux_lives_new proj 2>/dev/null
__tmux_lives_new 2>/dev/null
cd $nc_saved
functions -e __tmux_categorize; functions -c __tl_cwd_cat_bak __tmux_categorize
t "new: a named session is born in the invoking cwd" "$ncdir" \
    (tmux list-panes -t =proj -F '#{pane_start_path}' 2>/dev/null)
set -l nc_created
for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
    test "$s" = proj; and continue
    contains -- $s $nc_before; or set nc_created $s
end
t "new: the no-name session is born in the invoking cwd" "$ncdir" \
    (tmux list-panes -t "=$nc_created" -F '#{pane_start_path}' 2>/dev/null)
rm -rf $ncdir

set -e TMUX
cleanup

# the no-name switch must target the session it CREATED even after __tmux_categorize
# renames it (numeric -> gen-N). Bug: identifying by name -> switch -t "=<old#>" fails
# ("can't find session: N"); fix identifies by the stable #{session_id}.
tmux new-session -d -s base
set -gx TMUX fake
functions -c __tmux_categorize __tl_cat_bak
function __tmux_categorize  # mimic the categorizer renaming owned (numeric) sessions
    for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
        string match -qr '^[0-9]+$' -- $s; and tmux rename-session -t "=$s" gen-$s
    end
end
functions -c tmux __tl_tmux_bak
function tmux  # intercept switch-client to capture its target session
    test "$argv[1]" = switch-client; and begin
        set -g _sw_target $argv[3]; return 0
    end
    command tmux -L $sock -f /dev/null $argv
end
set -g _sw_target ''
__tmux_lives_new 2>/dev/null
functions -e tmux; functions -c __tl_tmux_bak tmux
t "new no-name: switch targets a live session" "yes" (test -n "$_sw_target"; and tmux has-session -t "$_sw_target" 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_categorize; functions -c __tl_cat_bak __tmux_categorize
set -e TMUX
cleanup

# The two outside-tmux branches replace the process, so they cannot be driven
# the way the two above are. These are SOURCE-SHAPE checks over the whole
# function body, and that is all they are: they prove no creation site passes
# an explicit -c and that nothing in the body chdirs before creating a
# session. They do NOT prove a session lands anywhere -- the two behavioural
# assertions above do that, for the two in-tmux branches only.
#
# Both checks read the WHOLE extracted body, not just the `new-session` lines.
# An earlier version greped only those lines for the substring HOME, which a
# bare `cd $HOME` inserted anywhere above them evaded completely (verified:
# the suite stayed ALL PASS). Since those two branches exec and have no
# behavioural coverage, this grep is the only guard there is.
#
# Whole-line comments are stripped, trailing ones deliberately are NOT: one of
# these call sites carries a tmux format in single quotes whose first character
# is the same one that starts a fish comment, and stripping to end-of-line
# would swallow that entire line out of the count.
set -l nl_src (awk '/^function __tmux_lives_new/,/^end$/' $plugindir/conf.d/tmux.fish | string replace -r '^\s*#.*$' '')
t "new: the body extraction is non-empty (this guard is not vacuous)" "yes" \
    (test (count $nl_src) -gt 10; and echo yes; or echo no)
t "new: all four creation sites are still present" "4" \
    (printf '%s\n' $nl_src | grep -c 'new-session')
# The -c FLAG, not the substring HOME: -c is the only way new-session pins a
# birth directory, so this matches the property instead of one spelling of it.
t "new: no creation site passes an explicit -c" "0" \
    (printf '%s\n' $nl_src | grep 'new-session' | grep -cE '(^|[[:space:]])-c([[:space:]]|$)')
t "new: the body never chdirs before creating a session" "0" \
    (printf '%s\n' $nl_src | grep -cE '(^|[[:space:];&|(])cd([[:space:]]|$)')

# ---------------------------------------------------------------------
# attach: missing-session errors; existing inside tmux switches.
cleanup
tmux new-session -d -s keep
set -gx TMUX fake
t "attach: missing errors (rc1)"  "1" (__tmux_lives_attach nope 2>/dev/null; echo $status)
t "attach: no name errors (rc1)"  "1" (__tmux_lives_attach 2>/dev/null; echo $status)
set -e TMUX
cleanup
set -g tmux_categorize_script $__tac_cat_stub

# ---------------------------------------------------------------------
# close: kills the current session; outside tmux errors. Non-regression: run
# with landing OFF, the direct-kill path these assertions describe. With the
# default (on) close delegates to session-close (tested separately below).
cleanup
set -g tmux_lives_landing off
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
set -e tmux_lives_landing
cleanup

# close (landing on, the default): delegate to the categorizer's session-close
# verb -- Task 6 already built and tested __tcz_session_close for this. The
# categorizer is stubbed so the call is recorded rather than performed.
cleanup
tmux new-session -d -s cur2
set -gx TMUX fake
function __tmux_lives_current_session; echo cur2; end
set -g real_cat3 $tmux_categorize_script
set -g cl_rec /tmp/close-rec-$fish_pid
set -g cl_stub /tmp/close-stub-$fish_pid.fish
set -g tmux_categorize_script $cl_stub
printf '#!/usr/bin/env fish\nprintf "%%s\\n" $argv > %s\n' $cl_rec > $cl_stub
__tmux_lives_close
t "close (landing on): delegates to session-close"       "session-close" (head -1 $cl_rec 2>/dev/null)
t "close (landing on): passes the current session name"  "cur2"          (sed -n 2p $cl_rec 2>/dev/null)
t "close (landing on): the kill itself is session-close's job, not ours" "yes" (tmux has-session -t =cur2 2>/dev/null; and echo yes; or echo no)
# A session-close that FAILS (categorizer broken or missing) must not strand the
# user in a session they asked to close: fall back to the direct kill.
printf '#!/usr/bin/env fish\nexit 1\n' > $cl_stub
__tmux_lives_close
t "close (landing on): a failing session-close falls back to the direct kill" "no" (tmux has-session -t =cur2 2>/dev/null; and echo yes; or echo no)
# M-3: without the managed fragment nothing would ever clean a landing session up.
printf '#!/usr/bin/env fish\nprintf "%%s\\n" $argv > %s\n' $cl_rec > $cl_stub
rm -f $cl_rec
tmux new-session -d -s cur2
set -l cl_frag $tmux_lives_fragment_file
set -g tmux_lives_fragment_file $TMUX_LIVES_TEST_UVARS/no-such-fragment.conf
__tmux_lives_close
set -l cl_called (test -e $cl_rec; and echo called; or echo absent)
set -l cl_alive (tmux has-session -t =cur2 2>/dev/null; and echo yes; or echo no)
t "M-3: close (landing on, no fragment) kills directly, no session-close" "absent no" "$cl_called $cl_alive"
set -g tmux_lives_fragment_file $cl_frag
set -g tmux_categorize_script $real_cat3
rm -f $cl_stub $cl_rec
functions -e __tmux_lives_current_session
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# clear: kills idle sessions, keeps current + non-idle; never touches landing.
cleanup
tmux new-session -d -s idleA
tmux new-session -d -s idleB
tmux new-session -d -s busy 'sleep 1000'
tmux new-session -d -s _landing-3
set -gx TMUX fake
function __tmux_lives_current_session; echo idleA; end
__tmux_lives_clear
t "clear: idle non-current killed" "no"  (tmux has-session -t =idleB 2>/dev/null; and echo yes; or echo no)
t "clear: current kept"            "yes" (tmux has-session -t =idleA 2>/dev/null; and echo yes; or echo no)
t "clear: non-idle kept"           "yes" (tmux has-session -t =busy 2>/dev/null; and echo yes; or echo no)
t "clear: landing session survives" "yes" (tmux has-session -t =_landing-3 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_lives_current_session
set -e TMUX
cleanup

# ---------------------------------------------------------------------
# shell picker key: Alt+<switcher key> at a bare prompt, outside tmux.
#
# fish binds alt-s to "prepend sudo" by default (--preset, and it recalls the
# PREVIOUS commandline when the current one is empty) -- verified on a pty.
# That is the annoyance this replaces. Inside tmux the key never reaches the
# shell, because tmux's root-table `bind -n M-s` consumes it first.
#
# NB every actual value is captured into a variable BEFORE `t` sees it. A call
# to an undefined function placed DIRECTLY inside `t` aborts the whole
# statement -- `t` never runs, nothing prints, and this suite still reports
# ALL PASS. Capture-first makes the RED phase real.
# ---------------------------------------------------------------------

set -l has_builder (functions -q __tmux_lives_fish_key; and echo 1; or echo 0)
set -l has_action  (functions -q __tmux_lives_shell_key; and echo 1; or echo 0)
t "shell key: __tmux_lives_fish_key is defined"  1 $has_builder
t "shell key: __tmux_lives_shell_key is defined" 1 $has_action

set -l k_s     (__tmux_lives_fish_key M-s)
set -l k_m     (__tmux_lives_fish_key M-m)
set -l k_upper (__tmux_lives_fish_key M-S)
set -l k_digit (__tmux_lives_fish_key M-1)
set -l k_ctrl  (__tmux_lives_fish_key C-M-a)
set -l k_empty (__tmux_lives_fish_key '')
set -l k_bare  (__tmux_lives_fish_key S)
set -l k_word  (__tmux_lives_fish_key M-Space)
t "shell key: M-s translates to alt-s"            alt-s "$k_s"
t "shell key: M-m translates to alt-m"            alt-m "$k_m"
t "shell key: case is preserved (M-S -> alt-S)"   alt-S "$k_upper"
t "shell key: digits translate (M-1 -> alt-1)"    alt-1 "$k_digit"
t "shell key: C-M-a is untranslatable -> nothing" ""    "$k_ctrl"
t "shell key: '' (disabled) -> nothing"           ""    "$k_empty"
t "shell key: bare S (no modifier) -> nothing"    ""    "$k_bare"
t "shell key: M-Space (multi-char) -> nothing"    ""    "$k_word"

# Behavioural: no grep can see a keypress, so drive a real pty.
#
# THREE things here are load-bearing; each was found by the harness failing to
# discriminate, and removing any one makes these assertions vacuous:
#
#  1. $XDG_DATA_HOME must be redirected. fish history lives there and this
#     suite's isolation guard covers XDG_CONFIG_HOME ONLY, so without this
#     every simulated keypress lands in the user's REAL fish_history
#     (test-tmux-install.fish:2348 compensates the same way). Bracketed below.
#  2. History must be SEEDED. fish's preset prepends sudo to the PREVIOUS
#     commandline; with an empty history it is a no-op, so "no longer prepends
#     sudo" would pass even against unfixed code. Measured: empty history ->
#     Alt+S does nothing at all.
#  3. `sudo` must be FAKED onto PATH. The preset gates on `command -q sudo`, so
#     a fake satisfies it -- and executing the recalled line then hits our stub
#     instead of blocking on a real password prompt until the timeout.
set -l real_hist $HOME/.local/share/fish/fish_history
set -l hist_before (md5sum $real_hist 2>/dev/null | string split ' ')[1]

set -l ptydir /tmp/tl-shellkey-$fish_pid
rm -rf $ptydir; mkdir -p $ptydir/fish/conf.d $ptydir/bin $ptydir/data/fish
# fish's builtin printf does NOT honour `--` as an option terminator -- it
# takes `--` itself as the format string and discards the rest, so a `printf --
# '<yaml>'` here silently writes a 2-byte file containing only "--". Measured:
# that left the seed genuinely empty, and the sudo-prepend assertions below
# passed whether or not the production binding worked. Omit `--`.
printf '- cmd: echo tlprobe\n  when: 1700000000\n' > $ptydir/data/fish/fish_history
# `sudo` is a real binary, so a PATH stub shadows it. `tmux-lives` is NOT --
# the plugin defines it as a FUNCTION, and fish resolves functions before
# $PATH, so a stub binary is silently ignored and the real dispatcher runs
# (it tried to start a tmux server). The stub must be a function, defined
# AFTER the plugin is sourced so it wins.
printf '#!/bin/sh\necho SUDO_CALLED:"$@"\n' > $ptydir/bin/sudo
chmod +x $ptydir/bin/sudo

function _shellkey_setup --description 'write the pty harness config: <dir> <key|default> <emacs|vi>'
    set -l d $argv[1]
    set -l keyval $argv[2]
    set -l bindings $argv[3]
    begin
        printf 'set -gx TMUX_AUTO 0\n'
        # conf.d is sourced BEFORE config.fish, so the key has to be set here,
        # not there, or tmux.fish reads the default before we can override it.
        test "$keyval" = default; or printf 'set -g tmux_lives_switcher_key %s\n' (string escape -- "$keyval")
        printf 'source %s/conf.d/tmux-lives-install.fish\n' $_tl_plugindir
        printf 'source %s/conf.d/tmux.fish\n' $_tl_plugindir
        printf 'function tmux-lives; echo SHELLKEY_FIRED:$argv; end\n'
    end > $d/fish/conf.d/tl.fish
    if test "$bindings" = vi
        printf 'function fish_user_key_bindings\n    fish_vi_key_bindings\nend\n' > $d/fish/config.fish
    else
        rm -f $d/fish/config.fish
    end
end
set -g _tl_plugindir $plugindir
_shellkey_setup $ptydir default emacs

function _shellkey_press --description 'press Alt+S at a real fish prompt; echo what happened'
    set -l d $argv[1]
    set -l mode $argv[2]
    begin
        if test "$mode" = guard
            # Type something, THEN Alt+S, then Enter. Enter (not Ctrl-C) is
            # load-bearing: Ctrl-C cancels the execution `commandline -f execute`
            # queues, so the scenario produced nothing whether the guard was
            # there or not -- a vacuous test, caught by mutating the guard away.
            # With the guard, the line still says `echo typed-input` and Enter
            # runs it; without it, the line is replaced and the picker fires.
            printf 'echo typed-input\033s\nexit\n'
        else
            printf '\033s\nexit\n'
        end
    end | timeout 30 env TERM=dumb XDG_CONFIG_HOME=$d XDG_DATA_HOME=$d/data \
        PATH="$d/bin:$PATH" script -qec "fish -i" /dev/null 2>&1 | tr -d '\r'
end
# TERM=dumb is a 38x speedup, not a shortcut: on a pty nobody is driving, fish
# waits out unanswered terminal-capability queries for ~10.4s per spawn, and
# there are five spawns here. Measured 10424ms -> 275ms with identical results.
# Verified NOT to cost sensitivity: the full mutation battery still catches every
# mutation under it, including the sudo-hijack control.

set -l pty_out (_shellkey_press $ptydir run | string collect)
# Match the VERB, not just the marker. The stub echoes `SHELLKEY_FIRED:$argv`,
# so a bare '*SHELLKEY_FIRED*' passes even if the dispatched verb is wrong --
# swapping `picker` for `clear` (a real sibling verb that KILLS idle sessions)
# left the whole gate green. Review-caught.
set -l fired (string match -q '*SHELLKEY_FIRED:picker*' -- "$pty_out"; and echo yes; or echo no)
set -l sudoed (string match -q '*SUDO_CALLED*' -- "$pty_out"; and echo yes; or echo no)
t "shell key: Alt+S runs the picker at a bare prompt" yes $fired
t "shell key: Alt+S no longer hijacks the prompt with sudo" no $sudoed

# VI BINDINGS. fish's preset occupies insert/default/visual; a binding added in
# default mode alone is listed but never fires, because a vi prompt starts in
# INSERT. Being listed is not being reachable -- the same distinction that made
# the emacs check meaningful. Review-caught: without `bind -M insert` the sudo
# hijack persists for vi users AND the picker never opens.
_shellkey_setup $ptydir default vi
set -l vi_out (_shellkey_press $ptydir run | string collect)
set -l vi_fired (string match -q '*SHELLKEY_FIRED:picker*' -- "$vi_out"; and echo yes; or echo no)
set -l vi_sudoed (string match -q '*SUDO_CALLED*' -- "$vi_out"; and echo yes; or echo no)
t "shell key: fires under vi bindings (insert mode)" yes $vi_fired
t "shell key: no sudo hijack under vi bindings"      no  $vi_sudoed

# EMPTY KEY = disabled. The translator returns nothing and the caller must not
# call `bind` with an empty first argument -- doing so prints
# "bind: cannot parse key '__tmux_lives_shell_key'" to stderr on EVERY
# interactive shell start. The translator's '' case is unit-tested, but nothing
# bound the guard at the bind SITE until now. Review-caught.
_shellkey_setup $ptydir '' emacs
set -l off_out (_shellkey_press $ptydir run | string collect)
set -l off_err (string match -q '*cannot parse key*' -- "$off_out"; and echo yes; or echo no)
set -l off_fired (string match -q '*SHELLKEY_FIRED*' -- "$off_out"; and echo yes; or echo no)
t "shell key: empty key emits no bind error at startup" no $off_err
t "shell key: empty key really disables the binding"    no $off_fired
_shellkey_setup $ptydir default emacs

# The picker execs into tmux, so firing it over typed input would destroy that
# input with no way back. Guard: act only at an empty prompt. Without this test
# the guard is a correct line bound by nothing -- a one-line deletion removes it
# with the whole gate still green.
set -l guard_out (_shellkey_press $ptydir guard | string collect)
set -l guard_fired (string match -q '*SHELLKEY_FIRED*' -- "$guard_out"; and echo yes; or echo no)
# Only command OUTPUT matches contiguously -- typed characters are rendered with
# cursor-movement escapes interleaved between them, so the echoed input never
# appears as one string. `typed-input` here is echo's output, proving the line
# survived intact and ran.
set -l guard_kept (string match -q '*typed-input*' -- "$guard_out"; and echo yes; or echo no)
t "shell key: does NOT fire over typed input" no  $guard_fired
t "shell key: typed input survives and still runs" yes $guard_kept

# Control: the harness must be able to report the OTHER state, or the two
# assertions above prove nothing.
rm -f $ptydir/fish/conf.d/tl.fish
set -l ctl_out (_shellkey_press $ptydir run | string collect)
set -l ctl_sudo (string match -q '*SUDO_CALLED*' -- "$ctl_out"; and echo yes; or echo no)
set -l ctl_fired (string match -q '*SHELLKEY_FIRED*' -- "$ctl_out"; and echo yes; or echo no)
t "shell key CONTROL: without the plugin, Alt+S does hijack with sudo" yes $ctl_sudo
t "shell key CONTROL: without the plugin, the picker does not run"     no  $ctl_fired

set -l hist_after (md5sum $real_hist 2>/dev/null | string split ' ')[1]
t "shell key: the pty harness left the real fish_history untouched" "$hist_before" "$hist_after"

functions -e _shellkey_press _shellkey_setup
set -e _tl_plugindir
rm -rf $ptydir

# ---------------------------------------------------------------------
# Landing (Task 7): identity and kill switch.
# ---------------------------------------------------------------------
set -l sl1 (__tmux_is_landing _landing-1; echo $status)
t "is_landing (shell side)" 0 "$sl1"
set -l sl2 (__tmux_is_landing landing-1; echo $status)
t "is_landing (shell side): look-alike without the underscore" 1 "$sl2"
set -e tmux_lives_landing
set -l le1 (__tmux_landing_enabled; echo $status)
t "landing enabled by default" 0 "$le1"
set -g tmux_lives_landing off
set -l le2 (__tmux_landing_enabled; echo $status)
t "landing off honoured" 1 "$le2"
set -e tmux_lives_landing

# The kill-switch rule must agree with the install side's
# __tmux_lives_landing_enabled (+ its unset-defaults-on __tmux_lives_key),
# which this suite does not otherwise load: only literal "on" is on, unset
# defaults to on, and everything else -- including a garbage stored value --
# is off. The brief's own formula (`!= off`) disagrees with that rule on a
# garbage value, so this proves agreement directly rather than trusting docs.
# The renderer is the third opinion, fed the value exactly as write_fragment feeds it.
source $plugindir/conf.d/tmux-lives-install.fish
set -l lbase /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k off 0.55 0.11 0.50 deep 'xterm*'
for v in on off UNSET no ''
    if test "$v" = UNSET
        set -e tmux_lives_landing
    else
        set -g tmux_lives_landing $v
    end
    set -l shell_side (__tmux_landing_enabled; and echo 1; or echo 0)
    set -l install_side (__tmux_lives_landing_enabled (__tmux_lives_key tmux_lives_landing on); and echo 1; or echo 0)
    set -l frag (__tmux_lives_render_fragment $lbase (__tmux_lives_key tmux_lives_landing on) | string collect)
    set -l render_side (string match -q '*set -g remain-on-exit on*' -- "$frag"; and echo 1; or echo 0)
    t "landing rule agrees: shell, status and renderer ('$v')" "$install_side $install_side" "$shell_side $render_side"
end
set -e tmux_lives_landing

# M-3: the shell side's fragment path mirrors the one _tmux_lives_post_update checks.
set -l fp_keep $tmux_lives_fragment_file
set -e tmux_lives_fragment_file
set -l fp_shell (__tmux_fragment_path)
t "fragment path agrees with the install side (default)" (__tmux_lives_fragment_path) "$fp_shell"
set -g tmux_lives_fragment_file /x/frag.conf
set -l fp_shell2 (__tmux_fragment_path)
t "fragment path agrees with the install side (seam)" (__tmux_lives_fragment_path) "$fp_shell2"
set -g tmux_lives_fragment_file $fp_keep

# ---------------------------------------------------------------------
# The exec sites, behaviourally. __tmux_autostart and the outside-tmux picker
# REPLACE the process, so each runs for real in a child fish against
#   - a recorder `tmux` first on PATH: it appends its argv, joined with "|" so
#     a mis-split argv shows, to a log and never runs tmux (every call
#     succeeds, so the server looks up and restore is skipped), and
#   - a stub categorizer whose `landing-new` prints a fixed name.
# The LAST recorded call is the exec. `env -u TMUX` keeps the child from
# tmux's own idea of a server; the recorder means there is no server anyway.
# ---------------------------------------------------------------------
set -g ex_root $TMUX_LIVES_TEST_UVARS/exec
set -g ex_bin $ex_root/bin
set -g ex_log $ex_root/tmux-calls.log
set -g ex_cat $ex_root/cat-stub.fish
mkdir -p $ex_bin
printf '#!/bin/sh\nIFS="|"\necho "$*" >> %s\nexit 0\n' $ex_log > $ex_bin/tmux
chmod +x $ex_bin/tmux
printf '#!/usr/bin/env fish\nswitch "$argv[1]"\n    case landing-new\n        switch "$TL_STUB_MODE"\n            case empty\n            case junk\n                echo boom\n            case \'*\'\n                echo _landing-7\n        end\n    case new-general\n        echo gen-4\nend\n' > $ex_cat

set -g __tac_frag $tmux_lives_fragment_file
function __tac_exec --argument-names landing catscript mode --description '__tac_exec <landing: unset|on|off|..> <categorizer> <stub mode> <fn args...>: run the call in a child fish against the recorder tmux; print the last recorded tmux call'
    set -l call $argv[4..]
    rm -f $ex_log; touch $ex_log
    set -l lenv
    test "$landing" = unset; or set lenv tmux_lives_landing=$landing
    env -u TMUX -u TMUX_PANE PATH=(string join : $ex_bin $PATH) TMUX_AUTO=0 \
        tmux_categorize_script=$catscript TL_STUB_MODE=$mode $lenv \
        tmux_lives_fragment_file=$__tac_frag \
        fish --no-config -c "source $plugindir/conf.d/tmux.fish; $call" >/dev/null 2>&1
    tail -n 1 $ex_log
end
function __tac_exec_log_landing --description 'yes if any recorded tmux call mentions a landing session'
    string match -q '*_landing*' -- (cat $ex_log | string collect); and echo yes; or echo no
end

set -l a_unset (__tac_exec unset $ex_cat name __tmux_autostart)
t "autostart (landing unset): attaches the landing session it created" "-u|attach-session|-t|=_landing-7" "$a_unset"
set -l a_on (__tac_exec on $ex_cat name __tmux_autostart)
t "autostart (landing on): attaches the landing session it created" "-u|attach-session|-t|=_landing-7" "$a_on"
set -l a_off (__tac_exec off $ex_cat name __tmux_autostart)
t "autostart (landing off): the legacy new-session, no landing" "-u|new-session" "$a_off"
t "autostart (landing off): nothing landing was ever touched" no (__tac_exec_log_landing)
set -l a_no (__tac_exec no $ex_cat name __tmux_autostart)
t "autostart (garbage switch value): off, the legacy new-session" "-u|new-session" "$a_no"
# Nothing usable from the categorizer: never exec a command line built from
# empty or junk output -- fall through to the legacy path.
set -l a_missing (__tac_exec on /nonexistent/cat.fish name __tmux_autostart)
t "autostart (categorizer missing): falls through to the legacy new-session" "-u|new-session" "$a_missing"
t "autostart (categorizer missing): no landing command exec'd" no (__tac_exec_log_landing)
set -l a_empty (__tac_exec on $ex_cat empty __tmux_autostart)
t "autostart (landing-new prints nothing): falls through to the legacy new-session" "-u|new-session" "$a_empty"
set -l a_junk (__tac_exec on $ex_cat junk __tmux_autostart)
t "autostart (landing-new prints junk): falls through to the legacy new-session" "-u|new-session" "$a_junk"
t "autostart (landing-new prints junk): no attach built from it" no (string match -q '*boom*' -- (cat $ex_log | string collect); and echo yes; or echo no)

set -l p_unset (__tac_exec unset $ex_cat name __tmux_lives_picker)
t "picker outside tmux (landing unset): attaches the landing session it created" "-u|attach-session|-t|=_landing-7" "$p_unset"
set -l p_on (__tac_exec on $ex_cat name __tmux_lives_picker)
t "picker outside tmux (landing on): attaches the landing session it created" "-u|attach-session|-t|=_landing-7" "$p_on"
set -l p_off (__tac_exec off $ex_cat name __tmux_lives_picker)
t "picker outside tmux (landing off): the legacy take + popup, no landing" 1 (string match -q -- "-u|attach-session|-d|-t|=gen-4|;|*" "$p_off"; and echo 1; or echo 0)
t "picker outside tmux (landing off): the legacy popup opens switch mode" 1 (string match -q -- "*display-popup -B -E -w 100% -h 100% -- fish --no-config * landing switch ''" "$p_off"; and echo 1; or echo 0)
t "picker outside tmux (landing off): nothing landing was ever touched" no (__tac_exec_log_landing)
set -l p_empty (__tac_exec on $ex_cat empty __tmux_lives_picker)
t "picker outside tmux (landing-new prints nothing): falls through to the legacy path" 1 (string match -q -- "-u|attach-session|-d|-t|=gen-4|;|*" "$p_empty"; and echo 1; or echo 0)
# -t/--take is the user explicitly asking to take a session over: the legacy path.
set -l p_take (__tac_exec on $ex_cat name __tmux_lives_picker -t)
t "picker outside tmux -t (landing on): legacy take-over, popup carries --take" 1 (string match -q -- "-u|attach-session|-d|-t|=gen-4|;|*landing switch '' --take" "$p_take"; and echo 1; or echo 0)
t "picker outside tmux -t (landing on): no landing was created" no (__tac_exec_log_landing)
set -l p_take2 (__tac_exec on $ex_cat name __tmux_lives_picker --take)
t "picker outside tmux --take (landing on): legacy take-over" 1 (string match -q -- "-u|attach-session|-d|-t|=gen-4|;|*landing switch '' --take" "$p_take2"; and echo 1; or echo 0)
# M-3: no managed fragment (before setup install, or after teardown) means no
# tick sweep and no pane-died respawn, so landing would leak: the legacy path.
set -g __tac_frag $ex_root/no-such-fragment.conf
set -l a_nofrag (__tac_exec on $ex_cat name __tmux_autostart)
t "M-3: autostart (landing on, no fragment): the legacy new-session" "-u|new-session" "$a_nofrag"
t "M-3: autostart (landing on, no fragment): nothing landing was touched" no (__tac_exec_log_landing)
set -l p_nofrag (__tac_exec on $ex_cat name __tmux_lives_picker)
t "M-3: picker outside tmux (landing on, no fragment): the legacy path" 1 (string match -q -- "-u|attach-session|-d|-t|=gen-4|;|*" "$p_nofrag"; and echo 1; or echo 0)
t "M-3: picker outside tmux (landing on, no fragment): nothing landing was touched" no (__tac_exec_log_landing)
set -g __tac_frag $tmux_lives_fragment_file
functions -e __tac_exec __tac_exec_log_landing

# ---------------------------------------------------------------------
# Hygiene: nothing this suite made outside its own throwaway dir, and no footprint of this run in the
# REAL project-discovery cache. Its mtime proves nothing: every landing app on this host rewrites it. A leak
# from this run shows as either
# - a row (in the file or a stray <cache>.XXXXXX temp) whose transcript dir is under this run's seam root,
#   or whose folder is one of this run's /tmp fixtures, or
# - a cache that had rows and now has none: this suite's seam root is empty, so a leak writes an empty file.
# ---------------------------------------------------------------------
function __tac_proj_leaks --argument-names cache root fre --description 'print each row of <cache>, or of a temp beside it, that this run wrote (transcript dir under <root>, the seam, or a folder matching <fre>, this suite'"'"'s own fixtures), then "checked"'
    if test -z "$root"; or test -z "$fre"; or test -z "$fish_pid"
        echo "refusing: no seam root, fixture pattern or pid to match on"; return
    end
    for f in $cache $cache.*
        test -f $f; or continue
        test $f = $cache; or string match -rq '\.[A-Za-z0-9]{6}$' -- $f; or continue
        # A production temp can vanish between the glob and the read: skip it, but report one it cannot read.
        test -r $f; or begin; test -e $f; and echo "$f: unreadable"; continue; end
        cat $f 2>/dev/null | while read -l line
            set -l r (string split \t -- $line)
            string match -q -- "$root/*" "$r[1]"; or string match -rq -- $fre "$r[-1]"; or continue
            echo "$f: $line"
        end
    end
    echo checked
end
set -l __tac_proj_fre "^/tmp/(tl|tac|test)-[^/]*-$fish_pid(/|\$)"
# Positive control: a stray temp holding one row from the seam and one fixture folder, beside a real row.
set -l lk $TMUX_LIVES_TEST_UVARS/leakprobe.tsv
printf '# tmux-lives projects v2\n/home/u/.claude/projects/-real\t1\t/home/u/real\n/home/u/.claude/projects/-tmp\t4\t/tmp/claude-1000/x/scratchpad-%s\n/home/u/.claude/projects/-v2\t5\t5\t/home/u/v2\n' $fish_pid > $lk
printf '%s/-x\t2\t/elsewhere\n/home/u/.claude/projects/-y\t3\t/tmp/tac-y-%s\n/home/u/.claude/projects/-z\t6\t6\t/tmp/tac-z-%s\n' $__tac_proj_root $fish_pid $fish_pid > $lk.Ab12Cd
set -l lkout (__tac_proj_leaks $lk $__tac_proj_root $__tac_proj_fre)
t "isolation: the leak check finds this run's three rows (old and v2 shapes) in a stray temp and passes real ones, even a /tmp one ending in this pid" "4 checked" "$(count $lkout) $lkout[-1]"
rm -f $lk $lk.Ab12Cd
set -l __tac_rows_after (cat "$__tac_real_proj_cache" 2>/dev/null | string match -v -- '#*' | count)
set -l __tac_emptied unknown
if string match -qr '^[0-9]+$' -- "$__tac_real_proj_rows_before"
    set __tac_emptied no
    test $__tac_real_proj_rows_before -gt 0; and test $__tac_rows_after -eq 0; and set __tac_emptied yes
end
t "isolation: the real project cache was not emptied or removed by this suite" no "$__tac_emptied"
set -l __tac_leaks (__tac_proj_leaks "$__tac_real_proj_cache" "$__tac_proj_root" $__tac_proj_fre)
t "isolation: the real project cache and its temps hold no row from this suite" checked "$__tac_leaks"
functions -e __tac_proj_leaks
cleanup

# ---------------------------------------------------------------------
if test $FAIL -eq 0
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
end
