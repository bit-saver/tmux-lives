#!/usr/bin/env fish
# The invariant harness for the tick-call-batching cycle (2026-08-19, task 1 of 6).
# See docs/superpowers/specs/2026-08-19-tick-tmux-call-batching-design.md and
# docs/superpowers/plans/2026-08-19-tick-call-batching.md -- this file is "the
# measurement every later task is judged by" that plan's task 1 asks for.
#
# What it builds and checks:
#   1. An isolated-socket harness (shim recipe from the design doc's handoff, plus
#      -L per this repo's own isolation convention) that counts real `tmux` client
#      invocations for one `tick` pass.
#   2. The O(1)-in-session-count property: run tick against a 2-session and a
#      6-session fixture; the delta must not grow with N. Documented here as a
#      currently-TRUE fact (today's tick is NOT O(1) -- see the "today:" assertion
#      below) rather than a hard ceiling, so this file stays green through the
#      early tasks of the cycle and the later tasks that actually batch the reads
#      flip it -- see task-1-report.md for why a hard ceiling was rejected.
#   3. A client-count companion measurement: three of the 44 calls the design doc
#      measured scale with CLIENTS, not sessions, and a session-only fixture can't
#      see that -- so this attaches real pty clients (tagged ShellFish via
#      LC_TERMINAL) rather than skip it.
#   4. Mutation tests proving the counting mechanism itself is sensitive (a
#      same-size control collapses to zero delta; stubbing one call away drops the
#      count) -- "a harness that cannot distinguish states is worse than none."
#   5. A coverage guard: every session in a multi-session fixture must actually
#      be renamed and stamped, not merely leave the delta looking flat -- closes
#      a gaming hole where truncating __tcz_categorize's session loop collapses
#      the delta to 0 without the equivalence baseline (below) noticing.
#   6. An equivalence baseline: __tcz_snapshot, __tcz_overview and the option
#      writes (including renames) a pass emits, pinned byte-identical on a fixed
#      fixture. Later tasks in the cycle must reproduce this exactly -- a
#      batching refactor that quietly changes a value is worse than the cost it
#      fixes.
#
# No production code changes here. This is a test-only commit.

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
set -g __tcb_sockdir /tmp/tmux-(id -u)
source $plugindir/conf.d/tmux-lives-install.fish

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end

set -g tmux_categorize_test 1
source $plugindir/functions/tmux-categorize.fish

# ---------------------------------------------------------------------
# Harness plumbing
# ---------------------------------------------------------------------

set -g __tcb_paths
function __tcb_track --argument-names p --description 'remember a dir/file this run created, for the hygiene sweep at the bottom'
    set -ga __tcb_paths $p
end

function __tcb_make_shim --argument-names dir sock log --description 'write a logging tmux shim at <dir>/tmux: appends every invocation'"'"'s argv (one line) to <log>, then execs the real binary against the isolated -L <sock> server. This is the handoff'"'"'s recipe (printf argv >> LOG; exec tmux "$@") with -L added for isolation, per this repo'"'"'s own convention (a fixture must never touch the live/default server).'
    mkdir -p $dir
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s\nexec /usr/bin/tmux -L %s "$@"\n' $log $sock > $dir/tmux
    chmod +x $dir/tmux
end

function __tcb_sessions --argument-names sock n --description 'fresh -L <sock> server with <n> throwaway sessions tcb1..tcbN, each -f /dev/null with an explicit pane command (sleep) -- never the bare login shell, which would load the users real fish config and its live tmux-lives hooks. Every call here carries -f /dev/null defensively, though only the server-starting one actually matters (config is read once, at server start).'
    command tmux -L $sock kill-server 2>/dev/null
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
    end
    for i in (seq $n)
        command tmux -L $sock -f /dev/null new-session -d -s "tcb$i" -c /tmp "sleep 300" 2>/dev/null
    end
    sleep 0.3
end

function __tcb_tick_calls --argument-names dir sock log color --description 'run one `tick <color>` as a fresh subprocess (matching the handoff recipe exactly: PATH-shimmed fish --no-config <script> tick <color>) against the isolated <sock> server, and return the number of tmux invocations the shim logged.'
    : > $log
    env PATH="$dir:$PATH" fish --no-config $plugindir/functions/tmux-categorize.fish tick "$color" >/dev/null 2>&1
    if test -f $log
        string trim -- (wc -l < $log)
    else
        echo 0
    end
end

function __tcb_kill --argument-names sock --description 'kill an isolated test server, ignoring absence'
    command tmux -L $sock kill-server 2>/dev/null
    return 0
end

set -g __tcb_bgpids

# ---------------------------------------------------------------------
# 1. The primary invariant: does the call count grow with session count?
# ---------------------------------------------------------------------
# "Assert the property, not a number" (design doc): a fixed ceiling drifts with
# fixture size and invites re-tuning the fixture until green. What matters is the
# DELTA between a small and a large fixture -- that is what O(1) vs O(n) actually
# looks like, and it is what a batching refactor (tasks 2-5 of the cycle) should
# collapse toward zero regardless of which exact fixture size someone re-runs this
# against later.

set -l s2dir /tmp/tcz-tcb-s2-$fish_pid
set -l s2sock tcz-tcb-s2-$fish_pid
set -l s2log /tmp/tcz-tcb-s2log-$fish_pid
__tcb_track $s2dir; __tcb_track $s2log
__tcb_make_shim $s2dir $s2sock $s2log
__tcb_sessions $s2sock 2
set -l n2 (__tcb_tick_calls $s2dir $s2sock $s2log '#112233')
__tcb_kill $s2sock

set -l s6dir /tmp/tcz-tcb-s6-$fish_pid
set -l s6sock tcz-tcb-s6-$fish_pid
set -l s6log /tmp/tcz-tcb-s6log-$fish_pid
__tcb_track $s6dir; __tcb_track $s6log
__tcb_make_shim $s6dir $s6sock $s6log
__tcb_sessions $s6sock 6
set -l n6 (__tcb_tick_calls $s6dir $s6sock $s6log '#112233')
__tcb_kill $s6sock

set -l delta_sessions (math $n6 - $n2)
echo "MEASURED tick tmux-call count: 2-session fixture=$n2  6-session fixture=$n6  delta=$delta_sessions"

t "sanity: the 2-session fixture actually issued tmux calls" 1 (test $n2 -gt 0; and echo 1; or echo 0)
t "sanity: the 6-session fixture actually issued tmux calls" 1 (test $n6 -gt 0; and echo 1; or echo 0)

# The invariant this whole cycle exists to satisfy. A "small constant" per the
# design doc's own wording -- generous enough to absorb minor per-pass overhead,
# far too tight for anything that still scales per-session.
set -l SMALL_CONST 3

# FLIPPED (tick-call-batching task 4): the pane-walk batching (the last
# per-session list-panes call, in __tcz_set_claude_opt) collapsed the measured
# delta 4 -> 0 -- see task-4-report.md. Was "O(sessions)" (delta > SMALL_CONST)
# through tasks 1-3; the delta is now comfortably at/under SMALL_CONST, so this
# now GATES on the property rather than merely documenting it: a regression
# back to a per-session tmux call fails this loudly instead of silently.
t "tick tmux-call count vs session count is O(1), not O(sessions)" \
    "O(1)" \
    (test $delta_sessions -gt $SMALL_CONST; and echo "O(sessions)"; or echo "O(1)")

# ---------------------------------------------------------------------
# 2. Sensitivity self-tests: prove the counting mechanism itself is real.
# "A harness that cannot distinguish states is worse than none" -- Method, task-1
# brief. Two techniques, both from that brief: a same-size control (two fixtures
# that differ in NOTHING relevant must measure equal), and a mutation (stub one
# call away and confirm the count drops).
# ---------------------------------------------------------------------

# --- same-size control: two INDEPENDENT 2-session fixtures must measure equal ---
set -l cAdir /tmp/tcz-tcb-cA-$fish_pid
set -l cAsock tcz-tcb-cA-$fish_pid
set -l cAlog /tmp/tcz-tcb-cAlog-$fish_pid
__tcb_track $cAdir; __tcb_track $cAlog
__tcb_make_shim $cAdir $cAsock $cAlog
__tcb_sessions $cAsock 2
set -l nA (__tcb_tick_calls $cAdir $cAsock $cAlog '#112233')
__tcb_kill $cAsock

set -l cBdir /tmp/tcz-tcb-cB-$fish_pid
set -l cBsock tcz-tcb-cB-$fish_pid
set -l cBlog /tmp/tcz-tcb-cBlog-$fish_pid
__tcb_track $cBdir; __tcb_track $cBlog
__tcb_make_shim $cBdir $cBsock $cBlog
__tcb_sessions $cBsock 2
set -l nB (__tcb_tick_calls $cBdir $cBsock $cBlog '#112233')
__tcb_kill $cBsock

t "harness control: two independent same-size (2-session) fixtures measure identically" "$nA" "$nB"

# --- mutation: stub one call away in-process, confirm the count strictly drops ---
# In-process (not a subprocess) on purpose: only a redefinition inside THIS fish
# process can stub a function, and the PATH-shim mechanism works identically for
# an in-process `tmux` call as for a subprocess one (fish resolves `tmux` via
# PATH at call time regardless of process boundary).
set -l mdir /tmp/tcz-tcb-m-$fish_pid
set -l msock tcz-tcb-m-$fish_pid
set -l mlog /tmp/tcz-tcb-mlog-$fish_pid
__tcb_track $mdir; __tcb_track $mlog
__tcb_make_shim $mdir $msock $mlog

set -l oldpath $PATH
set -gx PATH $mdir $PATH

# A FRESH __tcb_sessions rebuild before EACH measurement, not one fixture reused
# for both ticks: killing and recreating the server also resets
# @tmux_lives_heal_at to unset, so heal is due=true in both the baseline and the
# mutated run. Without this, a second tick against the SAME already-ticked
# fixture is naturally cheaper regardless of any stub (heal_due's own dedup:
# the first call sets @tmux_lives_heal_at ~120s out, so the second call is no
# longer due) -- confirmed by hand while building this: comparing two ticks
# against one fixture measured a drop even with heal_due wired straight through
# to its own original body. Two independent, equally-fresh fixtures is what
# isolates the stub as the only variable.
__tcb_sessions $msock 2
: > $mlog
__tcz_main tick '#112233' >/dev/null 2>&1
set -l m_before 0
test -f $mlog; and set m_before (string trim -- (wc -l < $mlog))

# Stub __tcz_heal_due away (always "not due"): removes its own internal
# `show -gv @tmux_lives_heal_interval` read AND short-circuits the tick's
# second, force-mode __tcz_recolor call (which itself issues a `list-clients`) --
# a real, multi-call reduction, not a no-op stub.
functions -c __tcz_heal_due __tcb_heal_due_orig
function __tcz_heal_due
    return 1
end
__tcb_sessions $msock 2
: > $mlog
__tcz_main tick '#112233' >/dev/null 2>&1
set -l m_after 0
test -f $mlog; and set m_after (string trim -- (wc -l < $mlog))
functions -e __tcz_heal_due
functions -c __tcb_heal_due_orig __tcz_heal_due
functions -e __tcb_heal_due_orig

set -gx PATH $oldpath
__tcb_kill $msock

echo "MEASURED mutation self-test: before=$m_before after(heal stubbed away)=$m_after"
t "harness mutation: stubbing one call away strictly drops the measured count" 1 \
    (test $m_after -lt $m_before; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# 3. Client-count companion: three of the 44 calls the design doc measured scale
# with CLIENTS, not sessions (per-client show-option/list-panes reads inside
# __tcz_recolor/__tcz_retitle's client loops) -- a session-only fixture cannot
# see that dimension. Real pty clients, tagged ShellFish via LC_TERMINAL (the
# only client kind those loops do per-client work for; a plain/bare client is
# classified "other" and only ever contributes to the flat list-clients call).
# Attaching real clients turned out to be practical here (this repo's suite
# already has the `script -qec "tmux attach"` pattern for exactly this), so this
# is not skipped -- but see the coverage note below for what it does NOT cover.
# ---------------------------------------------------------------------

function __tcb_attach --argument-names sock target --description 'attach one real ShellFish-tagged pty client to <target> on <sock>; backgrounds the attach (tracked in __tcb_bgpids for cleanup) and polls (no sleep-only wait) until list-clients grows by one, up to ~5s'
    set -l before (command tmux -L $sock list-clients 2>/dev/null | count)
    env LC_TERMINAL=ShellFish TERM=xterm-256color script -qec "tmux -L $sock attach -t $target" /dev/null >/dev/null 2>&1 &
    set -ga __tcb_bgpids $last_pid
    for i in (seq 25)
        test (command tmux -L $sock list-clients 2>/dev/null | count) -gt $before; and break
        sleep 0.2
    end
end

set -l cldir /tmp/tcz-tcb-cl-$fish_pid
set -l clsock tcz-tcb-cl-$fish_pid
set -l cllog /tmp/tcz-tcb-cllog-$fish_pid
__tcb_track $cldir; __tcb_track $cllog
__tcb_make_shim $cldir $clsock $cllog
__tcb_sessions $clsock 2

__tcb_attach $clsock tcb1
set -l ncl1 (__tcb_tick_calls $cldir $clsock $cllog '#112233')

# Reset the heal backstop between the two measurements, same fix as the
# mutation self-test above and for the identical reason: the FIRST tick call
# armed @tmux_lives_heal_at ~120s out, so without this reset the SECOND
# measurement's force-mode __tcz_recolor (and its list-clients call) would be
# silently skipped as "not due yet" -- undercounting the 3-client measurement
# by exactly the amount the extra client work it exists to detect would have
# cost. Caught in review: this fix landed in the mutation self-test but not
# here, on first cut -- same confound, same file, missed in the sibling
# section. Reproduced pre-fix: ncl3=38 (delta 9); with this reset, ncl3=47
# (delta 18) -- roughly double, and the true baseline this section should be
# quoting for the client-batching task's ratchet.
command tmux -L $clsock set-option -gu @tmux_lives_heal_at 2>/dev/null

__tcb_attach $clsock tcb2
__tcb_attach $clsock tcb2
set -l ncl3 (__tcb_tick_calls $cldir $clsock $cllog '#112233')

__tcb_kill $clsock
for p in $__tcb_bgpids
    kill $p 2>/dev/null
end
set -g __tcb_bgpids

set -l delta_clients (math $ncl3 - $ncl1)
echo "MEASURED tick tmux-call count: 1-client fixture=$ncl1  3-client fixture=$ncl3  delta=$delta_clients"

t "sanity: the 1-client fixture actually issued tmux calls" 1 (test $ncl1 -gt 0; and echo 1; or echo 0)
t "sanity: the 3-client fixture actually issued tmux calls" 1 (test $ncl3 -gt 0; and echo 1; or echo 0)

# STILL O(clients) after task 5 -- deliberately NOT flipped, and this is not a
# gap task 5 left behind: it batched the per-tty emit-cache reads (folded into
# __tcz_tmux_load's existing show -g, task 2's table -- zero extra calls) and
# merged the two list-clients calls into one shared __tcz_tmux_clients memo,
# which is what dropped delta 12 -> 6 measured here. What is left is NOT a
# read that could be batched away: on this fixture (fresh client attaches, so
# the per-tty emit cache starts genuinely empty) every newly-attached client
# costs 3 unavoidable tmux WRITES -- __tcz_recolor's dedup pass (color changed
# from unset), __tcz_retitle's dedup pass (title changed from unset), and the
# heal backstop's own force-mode __tcz_recolor pass (always writes,
# unconditionally, by design) -- and a write cannot be folded into a batched
# READ. 3 calls/client * 2 extra clients = 6, already above SMALL_CONST on its
# own. The one remaining LIVE read, @tmux_lives_display (1 call/client, see
# __tcz_session_title's own docstring for why task 5 left it live), was
# measured too: even removing it entirely leaves delta ~4, still above
# SMALL_CONST=3. So this classification was never going to flip this cycle
# purely from read-batching, independent of the display decision -- see
# task-5-report.md for the measurement this comment summarizes.
t "today: tick tmux-call count vs ShellFish/iTerm2 client count (deliberately still O(clients); see comment above)" \
    "O(clients)" \
    (test $delta_clients -gt $SMALL_CONST; and echo "O(clients)"; or echo "O(1)")

# Coverage note (explicit, per the task-1 brief's "an honest gap is worth more
# than a silent one"): this measures ONLY ShellFish/iTerm2-classified clients,
# because __tcz_client_terminal (via __tcz_pid_environ's real /proc read on
# Linux) is what __tcz_recolor/__tcz_retitle key their per-client loops on -- a
# plain pty attach with no LC_TERMINAL never enters that branch and would not
# demonstrate the scaling this section exists to catch. It does not attempt a
# ShellFish-classified client at varying session AND client counts together --
# that combination was judged not to add information the two separate deltas
# above don't already carry.

# ---------------------------------------------------------------------
# 4. Coverage guard: every session in the multi-session fixture must actually
# be PROCESSED -- renamed and stamped -- not merely leave the call-count delta
# looking flat.
#
# Closes a real gaming hole a reviewer found: patching __tcz_categorize's
# session loop to `break` after 2 iterations collapses the session-count delta
# 16->0 (section 1 above would wrongly flip to "O(1)") AND leaves the
# equivalence baseline (section 5 below) byte-identical -- because
# __tcz_snapshot/__tcz_overview report whatever the CURRENT server state
# happens to be, regardless of whether categorize actually visited a given
# session this pass, and the equivalence fixture's 3rd/4th sessions
# (gen-1, claimed-app) produce no write either way, processed or silently
# skipped. Neither existing check can tell "processed" from "silently
# skipped" apart for those two, which is exactly what let a break-after-2 loop
# hide behind both.
#
# This fixture is built so a truncation is NOT silent: every session is
# purely numeric (owned, per __tcz_owned's numeric fast path) with NO project
# (-c /tmp, excluded by __tcz_project_name's own contract: HOME/tmp/var-tmp
# return empty) -- so a correctly-running pass falls through to the gen-N
# branch and renames EVERY one of them off its numeric name, stamping
# @tmux_auto_name to match. A session still sitting at its original numeric
# name, or stamped to something other than its OWN current name, means
# __tcz_categorize never actually reached it -- independent of whatever the
# call-count delta or the (unrelated) equivalence fixture happen to show.
# ---------------------------------------------------------------------

set -l covdir /tmp/tcz-tcb-cov-$fish_pid
set -l covsock tcz-tcb-cov-$fish_pid
set -l covlog /tmp/tcz-tcb-covlog-$fish_pid
__tcb_track $covdir; __tcb_track $covlog
__tcb_make_shim $covdir $covsock $covlog

set -l COV_N 6
command tmux -L $covsock kill-server 2>/dev/null
for i in (seq 50)
    command tmux -L $covsock list-sessions >/dev/null 2>&1; or break
end
for i in (seq 0 (math $COV_N - 1))
    command tmux -L $covsock -f /dev/null new-session -d -s "$i" -c /tmp "sleep 300" 2>/dev/null
end
sleep 0.3

env PATH="$covdir:$PATH" fish --no-config $plugindir/functions/tmux-categorize.fish tick '#112233' >/dev/null 2>&1

set -l cov_names (command tmux -L $covsock list-sessions -F '#{session_name}' 2>/dev/null)
set -l cov_renamed 0
set -l cov_stamped 0
for n in $cov_names
    string match -qr '^gen-[0-9]+$' -- "$n"; and set cov_renamed (math $cov_renamed + 1)
    set -l stamp (command tmux -L $covsock show-option -qv -t "$n" @tmux_auto_name 2>/dev/null)
    test "$stamp" = "$n"; and set cov_stamped (math $cov_stamped + 1)
end
command tmux -L $covsock kill-server 2>/dev/null

echo "MEASURED coverage: $COV_N sessions built, $cov_renamed renamed off-numeric, $cov_stamped correctly self-stamped"
t "coverage: every session in the multi-session fixture was renamed off its numeric name" "$COV_N" "$cov_renamed"
t "coverage: every session in the multi-session fixture was stamped, matching its own new name" "$COV_N" "$cov_stamped"

# ---------------------------------------------------------------------
# 5. Equivalence baseline: __tcz_snapshot, __tcz_overview, and the option writes
# a tick pass emits, pinned byte-identical on a fixed, fully deterministic
# fixture. Later tasks in this cycle (which DO change the read path) must
# reproduce every one of these exactly -- "a batching refactor that quietly
# changes a value is worse than the cost it fixes."
#
# Why an assertion here rather than a committed golden file: the fixture that
# PRODUCES these values and the values themselves live in the same file and the
# same diff, so they cannot drift apart the way a separately-committed golden
# file and its generator can. Re-running this file always recomputes the actual
# side; the expected side is the literal captured below, by hand, against
# unmodified production code, at commit time -- and it stays fixed exactly
# because the fixture that produces it is fully deterministic: the SOCKET and
# PARENT project directory are $fish_pid-suffixed (so concurrent runs don't
# collide), but the values that actually reach the output -- session names,
# project directory BASENAMES, the claude --name -- never depend on $fish_pid or
# any other per-run value.
#
# Scope, stated explicitly: this fixture attaches NO clients, so it excludes the
# per-tty emit caches (@tmux_lives_emit_<tty>_title/_color) from the baseline --
# a real client's tty device path (e.g. /dev/pts/N) is not reproducible across
# runs/hosts, so a byte-identical comparison of THOSE writes is not meaningful
# here. The client-batching task later in this cycle is the natural place to
# extend this baseline to clients, using a normalized/masked tty representation.
# @tmux_lives_heal_interval is pre-set to 0 so the heal branch's
# `@tmux_lives_heal_at (date +%s)+interval` write -- the one genuinely
# time-dependent write reachable in a pass -- never fires; every other write
# below is a pure function of the fixture.
# ---------------------------------------------------------------------

set -g __tcb_eqdir /tmp/tcz-tcb-eq-$fish_pid
set -g __tcb_eqsock tcz-tcb-eq-$fish_pid
set -g __tcb_eqlog /tmp/tcz-tcb-eqlog-$fish_pid
# Pid-suffixed PARENT only -- the LEAF names (alpha/beta) are what actually reach
# __tcz_project_name (path basename), so they stay fixed and the fixture's
# session-path derived output is deterministic across runs and hosts.
set -g __tcb_eqproj /tmp/tcz-tcb-eqproj-$fish_pid
__tcb_track $__tcb_eqdir; __tcb_track $__tcb_eqlog; __tcb_track $__tcb_eqproj

__tcb_make_shim $__tcb_eqdir $__tcb_eqsock $__tcb_eqlog
rm -rf $__tcb_eqproj
mkdir -p $__tcb_eqproj/alpha $__tcb_eqproj/beta

command -q gcc; or begin; echo 'ABORT: gcc required to build the fake claude for the equivalence fixture'; exit 1; end
printf '#include <unistd.h>\nint main(void){while(1)sleep(1);return 0;}\n' | \
    gcc -x c - -o $__tcb_eqdir/claude

command tmux -L $__tcb_eqsock kill-server 2>/dev/null
for i in (seq 50)
    command tmux -L $__tcb_eqsock list-sessions >/dev/null 2>&1; or break
end
# "0" and "1": fresh numeric names, exactly what every fresh tmux session gets in
# production -- exercises the owned/renamed/stamped/display-synced path.
command tmux -L $__tcb_eqsock -f /dev/null new-session -d -s 0 -c $__tcb_eqproj/alpha \
    "$__tcb_eqdir/claude --enable-auto-mode --name 'Task Alpha'" 2>/dev/null
command tmux -L $__tcb_eqsock -f /dev/null new-session -d -s 1 -c $__tcb_eqproj/beta \
    "sleep 300" 2>/dev/null
# gen-1: already-stable general session, no project (HOME) -- exercises the
# "stable gen-N, no rename attempted" bailout.
command tmux -L $__tcb_eqsock -f /dev/null new-session -d -s gen-1 -c $HOME "sleep 300" 2>/dev/null
# claimed-app: an external @tmux_lives_name claim -- exercises the "claimed,
# never renamed" bailout. A boring/pager command (__tcz_boring), not a shell and
# not "sleep", so it categorizes general rather than running -- deliberately a
# different category from beta, for coverage.
command tmux -L $__tcb_eqsock -f /dev/null new-session -d -s claimed-app -c /tmp "tail -f /dev/null" 2>/dev/null
command tmux -L $__tcb_eqsock set-option -t claimed-app @tmux_lives_name "My App CLI" 2>/dev/null
command tmux -L $__tcb_eqsock set -g @tmux_lives_heal_interval 0 2>/dev/null
sleep 0.4

set -l oldpath2 $PATH
set -gx PATH $__tcb_eqdir $PATH

: > $__tcb_eqlog
__tcz_main tick '#112233' >/dev/null 2>&1

set -l eq_snapshot (__tcz_snapshot | string collect)
set -l eq_overview (__tcz_overview | string collect)
# rename-session is included alongside the @option writes: a session's name is
# also state a batching refactor could silently change (or silently fail to
# change), and it is exactly the kind of state a loop that silently skips a
# session would leave stale -- narrowing this to "set-option|set" only, as an
# earlier cut of this file did, would miss that class of drift entirely.
set -l eq_writes (grep -E '^(set-option|set|rename-session) ' $__tcb_eqlog | sort | string collect)

set -gx PATH $oldpath2
command tmux -L $__tcb_eqsock kill-server 2>/dev/null

set -l EXPECT_SNAPSHOT "alpha	claude	0	0	alpha · Task Alpha
beta	running	0	0	beta
claimed-app	general	0	0	My App CLI
gen-1	running	0	0	gen-1"

set -l EXPECT_OVERVIEW "alpha	claude	0	0	alpha · Task Alpha
beta	running	0	0	beta
gen-1	running	0	0	gen-1
claimed-app	general	0	0	My App CLI"

set -l EXPECT_WRITES "rename-session -t =0 -- alpha
rename-session -t =1 -- beta
set-option -t \$0 @tmux_lives_claude Task Alpha
set-option -t alpha @tmux_auto_name alpha
set-option -t alpha @tmux_lives_display alpha · Task Alpha
set-option -t beta @tmux_auto_name beta
set-option -t beta @tmux_lives_display beta"

t "equivalence baseline: __tcz_snapshot is byte-identical to today's pinned output" "$EXPECT_SNAPSHOT" "$eq_snapshot"
t "equivalence baseline: __tcz_overview is byte-identical to today's pinned output" "$EXPECT_OVERVIEW" "$eq_overview"
t "equivalence baseline: the set of option writes is byte-identical to today's pinned output" "$EXPECT_WRITES" "$eq_writes"

# ---------------------------------------------------------------------
# Hygiene: sweep every -L socket and shim/log/project dir THIS run created,
# scoped to this run's own $fish_pid, failing closed rather than globbing
# broadly if that pid were ever empty (it cannot be -- fish-protected -- but the
# guard encodes the invariant rather than relying on that, matching
# test-tmux-install.fish's own sweep).
# ---------------------------------------------------------------------

for p in $__tcb_bgpids
    kill $p 2>/dev/null
end

if test -z "$fish_pid"; or test -z "$__tcb_sockdir"
    echo "FATAL: refusing to sweep sockets without a pid-scoped glob" >&2
    exit 1
end
rm -f $__tcb_sockdir/*-$fish_pid 2>/dev/null
set -l __tcb_leftover_socks (count (string match -r ".*$fish_pid.*" -- (ls $__tcb_sockdir 2>/dev/null)))
t "hygiene: this run leaves no tmux socket files behind" 0 $__tcb_leftover_socks

set -l __tcb_leftover_paths 0
for p in $__tcb_paths
    if string match -qr "^/tmp/tcz-tcb-[a-zA-Z0-9]+-$fish_pid\$" -- "$p"
        rm -rf $p
    end
    test -e "$p"; and set __tcb_leftover_paths (math $__tcb_leftover_paths + 1)
end
t "hygiene: this run leaves no shim/log/project dirs behind" 0 $__tcb_leftover_paths

if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
