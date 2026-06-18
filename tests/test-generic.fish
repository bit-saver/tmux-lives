#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
set -l hits (grep -rnE 'bitsaver|/home/[a-z]|/Users/|user@1000|su - bitsaver' \
    $plugindir/conf.d $plugindir/functions 2>/dev/null)
if test -n "$hits"
    echo "FAIL: host-specifics found:"; printf '%s\n' $hits; echo "FAILED"
else
    echo "ALL PASS (1)"
end
