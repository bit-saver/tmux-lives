#!/usr/bin/env fish
if not set -q TMUX_LIVES_TEST_UVARS
    set -l d (mktemp -d /tmp/tmux-lives-uv.XXXXXX)
    if test -z "$d"; or not test -d "$d"
        echo "FATAL: cannot create an isolated universal store; refusing to run" >&2
        exit 1
    end
    set -gx TMUX_LIVES_TEST_UVARS $d
    set -gx XDG_CONFIG_HOME $d
    set -l fishargs
    test (count $fish_function_path) -gt 0; or set fishargs --no-config
    fish $fishargs (path resolve (status filename)) $argv
    set -l rc $status
    rm -rf $d
    exit $rc
end
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1]"; end; end
set -l out (__tmux_lives_status_lines | string collect)
t "checks fragment"    1 (string match -q '*fragment*'    -- "$out"; and echo 1; or echo 0)
t "checks categorizer" 1 (string match -q '*categorizer*' -- "$out"; and echo 1; or echo 0)
t "emits OK or MISSING" 1 (string match -qr 'OK|MISSING' -- "$out"; and echo 1; or echo 0)
set -e tmux_lives_prefix_key tmux_lives_switcher_key
t "status shows switcher keys" 1 (__tmux_lives_status_lines | string match -q '*switcher keys: prefix=*'; and echo 1; or echo 0)
test $fail -eq 0; and echo "ALL PASS ($pass)"; or begin; echo "FAILED ($fail)"; exit 1; end
