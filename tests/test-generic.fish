#!/usr/bin/env fish
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
set -g plugindir (path resolve (status dirname)/..)
set -l hits (grep -rnE 'bitsaver|/home/[a-z]|/Users/|user@1000|su - bitsaver' \
    $plugindir/conf.d $plugindir/functions 2>/dev/null)
if test -n "$hits"
    echo "FAIL: host-specifics found:"; printf '%s\n' $hits; echo "FAILED"
    exit 1
end

# Every test suite MUST carry the universal-isolation guard. Without it, a
# suite that drives the real CLI writes set -U straight into the user's live
# ~/.config/fish/fish_variables. Fish binds its universal store at startup,
# so the guard has to re-exec — it cannot be applied from inside the script.
set -l unguarded
for f in $plugindir/tests/test-*.fish
    grep -q 'if not set -q TMUX_LIVES_TEST_UVARS' $f; or set -a unguarded (path basename $f)
end
if test -n "$unguarded"
    echo "FAIL: test files missing the universal-isolation guard:"; printf '  %s\n' $unguarded; echo "FAILED"
    exit 1
end

# Every tmux PATH shim (a printf line that execs the real tmux binary against an
# isolated -L socket) must pin -f /dev/null, or the server it starts loads the
# user's ~/.tmux.conf -- and with it the live installed tmux-lives fragment's
# client-session-changed/client-attached hooks, which then race the test.
set -l shim_hits (grep -n 'exec /usr/bin/tmux' $plugindir/tests/test-tmux-*.fish)
if test (count $shim_hits) -lt 2
    echo "FAIL: expected at least 2 tmux PATH shim lines under tests/test-tmux-*.fish, found "(count $shim_hits); echo "FAILED"
    exit 1
end
set -l unsafe_shims
for hit in $shim_hits
    string match -q '*-f /dev/null*' -- "$hit"; or set -a unsafe_shims $hit
end
if test -n "$unsafe_shims"
    echo "FAIL: tmux PATH shim(s) missing -f /dev/null (would load ~/.tmux.conf):"
    printf '  %s\n' $unsafe_shims
    echo "FAILED"
    exit 1
end

echo "ALL PASS (3)"
