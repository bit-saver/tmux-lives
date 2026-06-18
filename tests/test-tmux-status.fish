#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1]"; end; end
set -l out (__tmux_lives_status_lines | string collect)
t "checks fragment"    1 (string match -q '*fragment*'    -- "$out"; and echo 1; or echo 0)
t "checks categorizer" 1 (string match -q '*categorizer*' -- "$out"; and echo 1; or echo 0)
t "emits OK or MISSING" 1 (string match -qr 'OK|MISSING' -- "$out"; and echo 1; or echo 0)
test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
