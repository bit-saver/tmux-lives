#!/usr/bin/env fish
# Hand-run timing measurement for __tcz_popup_truncate on a heavily-colored line.
#
# WHY THIS IS NOT tests/test-tmux-popup.fish's ASSERTION ANY MORE AND IS NOT NAMED
# tests/test-*.fish: it used to be a gate assertion there ("truncate heavy colored line is
# fast (<300ms/50)"), but a wall-clock bound inside the gate is exactly what this repo's own
# CLAUDE.md says the gate refuses -- timing under shared-host load is not a deterministic
# signal. Measured by the controller on 2026-09-14: it failed about 2 runs in 3 on `main`
# under normal host load (302ms, 314ms, 337ms against its 300ms limit). tests/tick-rate-ab.fish
# is the established pattern for this shape of work: a hand-run script, deliberately NOT named
# tests/test-*.fish, so `for t in tests/test-*.fish; fish $t; end` never picks it up and
# tests/test-generic.fish's isolation-guard sweep (which globs that same tests/test-*.fish
# pattern) never looks at it either.
#
# Run by hand: fish tests/truncate-perf.fish
#
# No self-re-exec isolation guard, matching tests/tick-rate-ab.fish: sourcing
# functions/tmux-categorize.fish with tmux_categorize_test set (below) only defines functions
# and a few `set -g`s -- it makes zero `set -U` calls, so there is no universal-store seam
# here to isolate from the real one.
#
# WHAT IT GUARDS: truncate must not cost O(line length) with per-char builtin calls. The old
# slow path was ~12ms/call on a wide colored pane -> ~130ms/redraw (24 rows) -> a laggy
# picker (dev-box calibrated: old slow path ~586ms/50 calls). This prints the measured time
# for 50 calls against a 40-segment, 256-color line rather than asserting a fixed bound --
# read the number, don't gate on it.

set -g plugindir (path resolve (status dirname)/..)
set -g tmux_categorize_test 1
source $plugindir/functions/tmux-categorize.fish

set -g HEAVY ''
for hi in (seq 40)
    set HEAVY "$HEAVY"(printf '\e[38;5;%smword%s ' (math "$hi % 256") $hi)
end

set -g TR_S (date +%s%N)
for hi in (seq 50)
    __tcz_popup_truncate "$HEAVY" 40 >/dev/null
end
set -g TR_MS (math "round(("(date +%s%N)" - $TR_S)/1000000)")

echo "TRUNCATE: 50 calls on a 40-segment 256-color line = $TR_MS""ms (dev-box calibrated: old slow path ~586ms/50; current fast path is usually well under 300ms but will vary with host load -- that variance is exactly why this moved out of the gate)"
