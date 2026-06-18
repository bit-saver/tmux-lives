#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1] => got [$argv[3]]"; end; end

set -l frag (__tmux_lives_render_fragment /X/cat.fish | string collect)
t "fragment has categorizer path" 1 (string match -q '*/X/cat.fish*' -- "$frag"; and echo 1; or echo 0)
t "fragment has update-environment" 1 (string match -q '*update-environment*LC_TERMINAL*' -- "$frag"; and echo 1; or echo 0)
t "fragment has commandeer hook" 1 (string match -q '*client-session-changed*' -- "$frag"; and echo 1; or echo 0)
t "fragment has resurrect plugin" 1 (string match -q '*tmux-plugins/tmux-resurrect*' -- "$frag"; and echo 1; or echo 0)
t "fragment status-interval" 1 (string match -q '*status-interval 15*' -- "$frag"; and echo 1; or echo 0)
t "fragment menu bind" 1 (string match -q '*bind-key S*' -- "$frag"; and echo 1; or echo 0)
t "fragment LC_TERMINAL_VERSION" 1 (string match -q '*LC_TERMINAL_VERSION*' -- "$frag"; and echo 1; or echo 0)

set -l u (__tmux_lives_save_unit_text alice 1234 | string collect)
t "unit uid"       1 (string match -q '*user@1234.service*' -- "$u"; and echo 1; or echo 0)
t "unit user"      1 (string match -q '*su - alice*' -- "$u"; and echo 1; or echo 0)
t "unit no bitsaver" 0 (string match -q '*bitsaver*' -- "$u"; and echo 1; or echo 0)

set -l ru (__tmux_lives_restore_unit_text alice 1234 | string collect)
t "restore unit uid"   1 (string match -q '*user@1234.service*' -- "$ru"; and echo 1; or echo 0)
t "restore unit user"  1 (string match -q '*su - alice*' -- "$ru"; and echo 1; or echo 0)
t "restore no bitsaver" 0 (string match -q '*bitsaver*' -- "$ru"; and echo 1; or echo 0)

set -l tc /tmp/tli-$fish_pid.conf
printf 'set -g foo 1\nrun \'~/.tmux/plugins/tpm/tpm\'\n' > $tc
__tmux_lives_ensure_source_line $tc /frag.conf
__tmux_lives_ensure_source_line $tc /frag.conf
t "source-line added once" 1 (grep -c 'source-file /frag.conf' $tc)
set -l n (string split : (grep -n 'source-file /frag.conf' $tc))[1]
set -l m (string split : (grep -n 'tpm/tpm' $tc))[1]
t "source-line before tpm" 1 (test $n -lt $m; and echo 1; or echo 0)
rm -f $tc

set -l tc2 /tmp/tlt-$fish_pid.conf
printf 'source-file /frag.conf\nrun \'~/.tmux/plugins/tpm/tpm\'\n' > $tc2
__tmux_lives_remove_source_line $tc2 /frag.conf
t "source-line removed" 0 (grep -c 'source-file /frag.conf' $tc2)
__tmux_lives_remove_source_line $tc2 /frag.conf
t "remove idempotent" 0 (grep -c 'source-file /frag.conf' $tc2)
rm -f $tc2

test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
