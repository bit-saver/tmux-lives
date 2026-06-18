#!/usr/bin/env fish
# ShellFish integration: tmux LC_TERMINAL passthrough.
#
# Scope: tmux-lives plugin only.
#   KEPT:   tmux update-environment / LC_TERMINAL passthrough assertions (tmux-side behavior)
#   REMOVED: shellfish.fish helper-function and ambient-behavior assertions — those test
#            conf.d/shellfish.fish which stays in ~/.config/fish, not in this plugin.
#
# Diagnosed/fixed 2026-06-14:
#  tmux drops LC_TERMINAL (absent from default update-environment) -> inside tmux
#  it read blank and conf.d/shellfish.fish never activated. Fix: add it to
#  update-environment (see ~/.tmux.conf). Proven below on an isolated -L server.
#
# Fully isolated: a private `tmux -L` socket. Never touches the real tmux server.

set -g FAIL 0
set -g sock test-shellfish-$fish_pid

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end
function cleanup
    tmux -L $sock kill-server 2>/dev/null
    rm -f /tmp/tmux-(id -u)/$sock
end

# --- tmux passthrough mechanism (characterization: control reproduces the bug) ---
function sess_lcterm --description 'sess_lcterm <session> -> value|empty'
    tmux -L $sock show-environment -t $argv[1] 2>/dev/null \
        | string replace -rf '^LC_TERMINAL=' ''
end

env -u LC_TERMINAL tmux -L $sock -f /dev/null new-session -d -s holder
env LC_TERMINAL=ShellFish tmux -L $sock new-session -d -s ctrl
t "tmux: default update-environment drops LC_TERMINAL (bug)" "" (sess_lcterm ctrl)
tmux -L $sock set -ga update-environment LC_TERMINAL
env LC_TERMINAL=ShellFish tmux -L $sock new-session -d -s fixed
t "tmux: with LC_TERMINAL in update-environment, it propagates" "ShellFish" (sess_lcterm fixed)

cleanup

# --- Config: the rendered fragment must carry the passthrough line ---
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -l frag (__tmux_lives_render_fragment /tmp/cat.fish | string collect)
t "config: rendered fragment adds LC_TERMINAL to update-environment" "yes" \
    (string match -q '*update-environment*LC_TERMINAL*' -- "$frag"; and echo yes; or echo no)

if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
