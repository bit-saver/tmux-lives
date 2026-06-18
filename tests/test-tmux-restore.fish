#!/usr/bin/env fish
# Integration: resurrect save -> kill -> __tmux_restore round-trip, fully isolated.
# A `tmux` PATH shim makes resurrect's bash scripts target our private socket, and
# tmux_resurrect_dir points at a temp save dir. Never touches the real tmux server.
#
# Disposal contract (2026-06-12, post-incident): login restore is HEADLESS, so
# resurrect never relaunches anything — every session returns as bare shells.
# The SAVE FILE therefore decides: save-time-claude sessions are kept as
# UNSTAMPED breadcrumb shells (name + cwd preserved, resume with `claude -r`);
# everything else live-idle is killed.

set -g FAIL 0
set -g sock test-restore-$fish_pid
set -g shimdir /tmp/tmuxrestore-shim-$fish_pid
set -g rdir /tmp/tmuxrestore-rdir-$fish_pid
set -g plugindir (path resolve (status dirname)/..)

mkdir -p $shimdir $rdir
printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $sock > $shimdir/tmux
chmod +x $shimdir/tmux
# Fake claude (comm = "claude"): the breadcrumb candidate must be a real
# claude-running pane at save time.
command -q gcc; or begin; echo 'ABORT: gcc required to build the fake claude'; exit 1; end
printf '#include <unistd.h>\nint main(void){while(1)sleep(1);return 0;}\n' | \
    gcc -x c - -o $shimdir/claude
set -gx PATH $shimdir $PATH           # all tmux calls (fish + restore.sh subprocess) hit our socket
set -gx tmux_resurrect_dir $rdir
set -gx TMUX_AUTO 0                    # keep the startup trigger dormant on source
set -gx tmux_categorize_script $plugindir/functions/tmux-categorize.fish

source $plugindir/conf.d/tmux.fish

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end
function cleanup
    tmux kill-server 2>/dev/null
    rm -f /tmp/tmux-(id -u)/$sock
    rm -rf $shimdir $rdir
end

# ---- Save: claude breadcrumb candidate + unrecoverable app + idle shell ----
tmux new-session -d -s Neuro-X "$shimdir/claude --enable-auto-mode --name Neuro X"
tmux new-session -d -s gone 'sleep 1000'
tmux new-session -d -s scratch
sleep 0.5     # let pane_current_command settle before saving
tmux set-option -g @resurrect-dir $rdir
bash ~/.tmux/plugins/tmux-resurrect/scripts/save.sh
t "save: snapshot written" "yes" (test -e $rdir/last; and echo yes; or echo no)
t "save: claude pane recorded" "Neuro-X" \
    (awk -F '\t' '$1=="pane" && $10=="claude" {print $2}' $rdir/last | sort -u | string join ',')

# Simulate the nightly reboot.
tmux kill-server
sleep 0.5   # brief settle after kill-server before the server socket clears

# ---- Restore via the REAL function: headless, everything returns as shells ----
__tmux_restore
t "restore: claude breadcrumb survives, others killed" "Neuro-X" \
    (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
t "restore: breadcrumb is a bare shell" "yes" \
    (tmux list-panes -t Neuro-X -F '#{pane_current_command}' | string match -qr '^(fish|bash|sh|zsh|dash)$'; and echo yes; or echo no)
t "restore: breadcrumb unstamped (guard keeps its name)" "" \
    (tmux show-option -qv -t Neuro-X @tmux_auto_name)

cleanup
if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
