#!/usr/bin/env fish
# A/B measurement of the tick's INVOCATION RATE, not its per-invocation cost.
# Task 6 of the tick-call-batching cycle (2026-08-19/20). See
# docs/superpowers/specs/2026-08-19-tick-tmux-call-batching-design.md and
# .superpowers/sdd/2026-08-19-tick-call-batching/task-6-report.md.
#
# WHY THIS FILE IS NOT tests/test-tmux-tick-calls.fish's SIBLING AND IS NOT
# NAMED tests/test-*.fish: it samples wall-clock tick firings over a live
# window against real attached pty clients. That is inherently a measurement,
# not a deterministic assertion -- this repo's own gate explicitly rejects
# wall-clock assertions (a prior timing fence already flaked and trained a
# re-run-until-green reflex; see CLAUDE.md). Naming it outside `test-*.fish`
# keeps it out of `for t in tests/test-*.fish; fish $t; end` on purpose. Run it
# by hand: `fish tests/tick-rate-ab.fish`.
#
# WHAT IT MEASURES AND WHY THE METHOD DIFFERS FROM THE ORIGINAL RECIPE:
# the original finding (a handoff pruned after the fix shipped; see git history)
# sampled `pgrep -f 'tmux-categorize.fish tick'` every ~100-300ms for ~15s and
# counted distinct pids. That works when a tick's wall time is close to 1s (the
# ORIGINAL macwork pathology) -- the process lives long enough to be caught by
# several polls. It systematically UNDERCOUNTS a tick that completes in a few
# milliseconds (this cycle's batched tick), because a poll every 100ms has a
# low chance of ever overlapping a 5-10ms process. Confirmed empirically here:
# a naive pgrep-poll against the batched script returned 0 over an 8s window
# with 3 clients even though the wrapper-log method below (run in parallel
# logic, same conditions) reliably counted several real invocations in that
# window. Using an instrument that structurally favours "fast job -> fewer
# counted events" would bias this experiment toward confirming the hypothesis
# regardless of what is actually true -- exactly what the task brief warns
# against. So this script counts EXACTLY instead of sampling: status-right is
# pointed at a tiny wrapper that appends one timestamp line to a log file and
# then execs the real tick command, so every firing is recorded, none are
# missed, and no polling overhead is added to the thing being measured.
#
# SAFETY: every tmux call this script's fixtures make -- INCLUDING the ones
# the tick script issues INTERNALLY when tmux spawns it as a #() job -- must
# stay on the isolated -L socket, never the user's live default server. This
# needs one non-obvious step: the #() job is a child of the tmux SERVER
# process, not of this script, so a shimmed PATH only reaches it if the
# shimmed PATH was already part of the SERVER's own environment at the moment
# the server was forked (`set-environment` does not retroactively reach
# already-running server-spawned jobs). Verified empirically before relying on
# it: an unattached server never evaluates status-right at all (a #() job with
# no attached client simply never fires), and once a client is attached, a
# `#(which tmux)` job run against a server STARTED under a shimmed PATH does
# resolve to the shim. So every session-creating call below that starts a
# fresh server does so via `env PATH="$shim:$PATH" tmux -L ...`.
#
# THE HEADLINE FINDING, recorded in full in CLAUDE.md: the rate hypothesis
# (cost drops -> re-arm rate falls to ~clients/status-interval) holds at
# moderate concurrency (8 clients) but INVERTS at higher concurrency (16
# clients) -- the batched tick fires roughly 2x MORE often than the
# unbatched one, not less. Net system cost (invocations/sec * calls/invocation)
# still favours the batched tick at both scales, but by far less than the
# per-invocation call-count reduction alone implies at 16 clients. This file
# reproduces both data points; re-run it to re-verify.

set -g plugindir (path resolve (status dirname)/..)
set -g __tra_sockdir /tmp/tmux-(id -u)
set -g __tra_paths
set -g __tra_bgpids

set -g OLD_SCRIPT $HOME/.config/fish/functions/tmux-categorize.fish
set -g NEW_SCRIPT $plugindir/functions/tmux-categorize.fish

if not test -f $OLD_SCRIPT
    echo "SKIP: no installed categorizer at $OLD_SCRIPT -- nothing to compare against" >&2
    exit 0
end

function __tra_track --argument-names p
    set -ga __tra_paths $p
end

# Build a `tmux` shim that forces every invocation onto -L <sock>, regardless
# of what the caller (including a #() job the server itself spawns) passed.
function __tra_make_shim --argument-names dir sock
    mkdir -p $dir
    printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $sock > $dir/tmux
    chmod +x $dir/tmux
end

# Fresh -L <sock> server with <n> throwaway sessions tcb1..tcbN, started under
# the shimmed PATH so every #() job the server later spawns inherits it (see
# the safety note above) -- -f /dev/null, explicit pane command, matching this
# repo's isolation convention (never the bare login shell).
function __tra_sessions --argument-names shimdir sock n
    command tmux -L $sock kill-server 2>/dev/null
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
        sleep 0.05
    end
    env PATH="$shimdir:$PATH" tmux -L $sock -f /dev/null new-session -d -s tcb1 -c /tmp "sleep 900" 2>/dev/null
    for i in (seq 2 $n)
        command tmux -L $sock -f /dev/null new-session -d -s "tcb$i" -c /tmp "sleep 900" 2>/dev/null
    end
    sleep 0.3
end

# Attach one real ShellFish-tagged pty client to <target>, backgrounded and
# tracked, polling (no sleep-only wait) until list-clients grows -- same shape
# as tests/test-tmux-tick-calls.fish's __tcb_attach.
function __tra_attach --argument-names sock target
    set -l before (command tmux -L $sock list-clients 2>/dev/null | count)
    env LC_TERMINAL=ShellFish TERM=xterm-256color script -qec "tmux -L $sock attach -t $target" /dev/null >/dev/null 2>&1 &
    set -ga __tra_bgpids (jobs -lp | tail -1)
    for w in (seq 50)
        test (command tmux -L $sock list-clients 2>/dev/null | count) -gt $before; and break
        sleep 0.1
    end
end

function __tra_attach_n --argument-names sock nsess nclients
    for i in (seq $nclients)
        set -l idx (math "($i - 1) % $nsess + 1")
        __tra_attach $sock "tcb$idx"
    end
end

# --- Rate measurement: exact invocation counting via a logging wrapper -----
#
# status-right is pointed at a small fish wrapper that appends one timestamp
# line to $logf, then execs the real `<script> tick <color>` -- every firing
# is recorded exactly once, with no polling and no risk of missing a fast one.
function __tra_measure_rate --argument-names label script nsess nclients warmup window
    set -l sock "tcz-tra-$label-$fish_pid"
    set -l shimdir "/tmp/tcz-tra-shim-$label-$fish_pid"
    set -l wrapper "/tmp/tcz-tra-wrap-$label-$fish_pid.fish"
    set -l logf "/tmp/tcz-tra-log-$label-$fish_pid"
    __tra_track $shimdir; __tra_track $wrapper; __tra_track $logf

    __tra_make_shim $shimdir $sock
    printf '#!/usr/bin/env fish\ndate +%%s%%N >> %s\nexec fish --no-config %s tick $argv[1]\n' $logf $script > $wrapper
    chmod +x $wrapper

    __tra_sessions $shimdir $sock $nsess
    command tmux -L $sock set-option -g status-interval 15
    command tmux -L $sock set-option -g status-left ''
    command tmux -L $sock set-option -g status-right-length 80
    command tmux -L $sock set-option -g status-right "#(fish --no-config $wrapper '#112233')"

    __tra_attach_n $sock $nsess $nclients
    set -l attached (command tmux -L $sock list-clients 2>/dev/null | count)

    for i in (seq (math "$warmup * 10"))
        sleep 0.1
    end

    rm -f $logf
    for i in (seq (math "$window * 10"))
        sleep 0.1
    end
    set -l n (count (cat $logf 2>/dev/null))

    command tmux -L $sock kill-server 2>/dev/null
    set -l rate (math -s3 "$n / $window")
    set -l implied (math -s3 "$nclients / 15.0")
    if test $attached -ne $nclients
        echo "WARNING $label: only $attached of $nclients clients attached -- measurement below is not the requested fixture" >&2
    end
    # Diagnostics go to stderr, not stdout: the caller does `(func | tail -1)`
    # to pull just the trailing count, and anything else on stdout would be
    # silently swallowed by that pipe rather than shown.
    echo "RATE $label: nsess=$nsess nclients=$attached window=$window"s" invocations=$n rate=$rate/sec implied=$implied/sec" >&2
    echo $n
end

# --- Per-invocation call count at STEADY STATE, at the same scale ----------
#
# Three warmup ticks settle every claim/rename/dedup write, then the next
# tick's internal `tmux` calls are counted via the logging shim -- matching
# what tests/test-tmux-tick-calls.fish already measures at small fixtures,
# extended here to the same client counts the rate measurement uses, so the
# two numbers can be multiplied into one honest "total downstream tmux spawns
# per second" figure instead of quoting the per-invocation reduction alone.
function __tra_measure_callcount --argument-names label script nsess nclients
    set -l sock "tcz-tracc-$label-$fish_pid"
    set -l shimdir "/tmp/tcz-tracc-shim-$label-$fish_pid"
    set -l calllog "/tmp/tcz-tracc-log-$label-$fish_pid"
    __tra_track $shimdir; __tra_track $calllog

    mkdir -p $shimdir
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s\nexec /usr/bin/tmux -L %s "$@"\n' $calllog $sock > $shimdir/tmux
    chmod +x $shimdir/tmux

    __tra_sessions $shimdir $sock $nsess
    __tra_attach_n $sock $nsess $nclients
    set -l attached (command tmux -L $sock list-clients 2>/dev/null | count)
    sleep 5

    for w in 1 2 3
        env PATH="$shimdir:$PATH" fish --no-config $script tick '#112233' >/dev/null 2>&1
    end
    rm -f $calllog
    env PATH="$shimdir:$PATH" fish --no-config $script tick '#112233' >/dev/null 2>&1
    set -l n (count (cat $calllog 2>/dev/null))

    command tmux -L $sock kill-server 2>/dev/null
    # A healthy tick issues at least the 4 batched core reads even with zero
    # clients attached -- 0 here means the fixture never actually ran (check
    # that $script resolved to a real file first; this is what caught a
    # $plugindir-resolves-wrong mistake while developing this script -- see
    # CLAUDE.md), not a real measurement. Loud rather than silently trusting a
    # number that cannot occur in practice.
    if test $n -eq 0
        echo "WARNING $label: 0 calls recorded -- is \$script a real file? ($script)" >&2
    end
    if test $attached -ne $nclients
        echo "WARNING $label: only $attached of $nclients clients attached -- measurement below is not the requested fixture" >&2
    end
    echo "CALLCOUNT $label: nsess=$nsess nclients=$attached steady-state calls-per-invocation=$n" >&2
    echo $n
end

# ---------------------------------------------------------------------------
# Run both configurations, both scripts (always old-then-new; this script does
# not itself alternate order). Numbers recorded from this exact run are in
# task-6-report.md and CLAUDE.md; re-running will vary with host load but
# should reproduce the qualitative shape (moderate scale: rate falls; higher
# scale: rate rises). During development this shape was reproduced four times
# total across two host-load conditions, including once with old/new run in
# the OPPOSITE order by hand, specifically to rule out an ordering artifact --
# it held every time.
# ---------------------------------------------------------------------------

echo "=== moderate concurrency: 6 sessions / 8 clients ==="
set -l old8_n (__tra_measure_rate old8 $OLD_SCRIPT 6 8 20 30 | tail -1)
set -l new8_n (__tra_measure_rate new8 $NEW_SCRIPT 6 8 20 30 | tail -1)
set -l old8_calls (__tra_measure_callcount old8cc $OLD_SCRIPT 6 8 | tail -1)
set -l new8_calls (__tra_measure_callcount new8cc $NEW_SCRIPT 6 8 | tail -1)

echo "=== higher concurrency: 6 sessions / 16 clients ==="
set -l old16_n (__tra_measure_rate old16 $OLD_SCRIPT 6 16 20 30 | tail -1)
set -l new16_n (__tra_measure_rate new16 $NEW_SCRIPT 6 16 20 30 | tail -1)
set -l old16_calls (__tra_measure_callcount old16cc $OLD_SCRIPT 6 16 | tail -1)
set -l new16_calls (__tra_measure_callcount new16cc $NEW_SCRIPT 6 16 | tail -1)

echo ""
echo "=== SUMMARY (30s window; *_n = invocations over the window, not per-second) ==="
printf '%-10s %8s %8s %10s %10s %20s\n' scale old_n new_n old_calls new_calls "old->new net calls/sec"
set -l old8_net (math -s1 "$old8_calls * $old8_n / 30.0")
set -l new8_net (math -s1 "$new8_calls * $new8_n / 30.0")
set -l old16_net (math -s1 "$old16_calls * $old16_n / 30.0")
set -l new16_net (math -s1 "$new16_calls * $new16_n / 30.0")
printf '%-10s %8s %8s %10s %10s   %s -> %s\n' "8cl" "$old8_n" "$new8_n" "$old8_calls" "$new8_calls" "$old8_net" "$new8_net"
printf '%-10s %8s %8s %10s %10s   %s -> %s\n' "16cl" "$old16_n" "$new16_n" "$old16_calls" "$new16_calls" "$old16_net" "$new16_net"

# ---------------------------------------------------------------------
# Hygiene: kill any background attach processes, sweep every -L socket and
# shim/log/wrapper this run created, scoped to this run's own $fish_pid,
# failing closed rather than globbing broadly. Mirrors
# tests/test-tmux-tick-calls.fish's own sweep exactly.
# ---------------------------------------------------------------------

for p in $__tra_bgpids
    kill $p 2>/dev/null
end
pkill -f "script -qec tmux -L tcz-tra" 2>/dev/null

if test -z "$fish_pid"; or test -z "$__tra_sockdir"
    echo "FATAL: refusing to sweep sockets without a pid-scoped glob" >&2
    exit 1
end
rm -f $__tra_sockdir/*-$fish_pid
for p in $__tra_paths
    # NB the naming shape is tcz-tra(cc)?-<kind>-<label>-<pid>[.fish] -- three
    # dash-separated segments after the prefix, not one, so the middle needs
    # `.*` rather than `[a-zA-Z0-9]+` (which cannot span the extra hyphens and
    # silently matched nothing, leaking every run's shim/log/wrapper files
    # while still correctly wiping the socket glob above -- caught by
    # inspecting /tmp after a real run rather than trusting the sweep).
    if string match -qr "^/tmp/tcz-tra(cc)?-.*-$fish_pid(\.fish)?\$" -- "$p"
        rm -rf $p
    end
end

echo ""
echo "done"
