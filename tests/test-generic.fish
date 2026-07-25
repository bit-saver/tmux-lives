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
set -l hits (grep -rnE 'bitsaver|/home/[a-z]|/Users/|user@1000|su - bitsaver' \
    $plugindir/conf.d $plugindir/functions 2>/dev/null)
if test -n "$hits"
    echo "FAIL: host-specifics found:"; printf '%s\n' $hits; echo "FAILED"
else
    echo "ALL PASS (1)"
end
