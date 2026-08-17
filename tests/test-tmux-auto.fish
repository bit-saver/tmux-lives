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
    command tmux -L $sock $argv
end
set -g _sw_target ''
__tmux_lives_new 2>/dev/null
functions -e tmux; functions -c __tl_tmux_bak tmux
t "new no-name: switch targets a live session" "yes" (test -n "$_sw_target"; and tmux has-session -t "$_sw_target" 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_categorize; functions -c __tl_cat_bak __tmux_categorize
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
printf -- '- cmd: echo tlprobe\n  when: 1700000000\n' > $ptydir/data/fish/fish_history
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
if test $FAIL -eq 0
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
end
