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
t "fragment binds S via display-popup guard" 1 (string match -q '*if-shell*display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment binds S to popup subcommand"     1 (string match -q '*display-popup*popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment fallback uses menu"   1 (string match -q '*run-shell*menu*' -- "$frag"; and echo 1; or echo 0)
t "fragment LC_TERMINAL_VERSION" 1 (string match -q '*LC_TERMINAL_VERSION*' -- "$frag"; and echo 1; or echo 0)
t "fragment runs tpm to load plugins" 1 (string match -q "*run '~/.tmux/plugins/tpm/tpm'*" -- "$frag"; and echo 1; or echo 0)

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

set -l pn (__tmux_lives_persistence_note)
t "note mentions continuum"      1 (string match -q '*continuum*' -- "$pn"; and echo 1; or echo 0)
t "note mentions restore"        1 (string match -q '*restore*' -- "$pn"; and echo 1; or echo 0)
t "note drops 'spec 2'"          0 (string match -q '*spec 2*' -- "$pn"; and echo 1; or echo 0)
set -l ps (__tmux_lives_persistence_status)
t "status is an OK line"         1 (string match -q 'OK *' -- "$ps"; and echo 1; or echo 0)
t "status mentions continuum"    1 (string match -q '*continuum*' -- "$ps"; and echo 1; or echo 0)

set -l hlp (tmux-lives | string collect)
t "help lists tmux-setup"     1 (string match -q '*tmux-setup*' -- "$hlp"; and echo 1; or echo 0)
t "help lists ts"             1 (string match -q '*ts [name]*' -- "$hlp"; and echo 1; or echo 0)
t "help lists tmuxauto"       1 (string match -q '*tmuxauto*' -- "$hlp"; and echo 1; or echo 0)
t "help has Setup header"     1 (string match -q '*Setup / lifecycle:*' -- "$hlp"; and echo 1; or echo 0)
t "help has Daily header"     1 (string match -q '*Daily use:*' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"       1 (test "$hlp" = (tmux-lives -h | string collect); and echo 1; or echo 0)
t "help 'help' alias works"   1 (string match -q '*tmux-setup*' -- (tmux-lives help | string collect); and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown arg returns 1"     1 $status
t "help hint names tmux-lives" 1 (string match -q '*tmux-lives*' -- (__tmux_lives_help_hint); and echo 1; or echo 0)

# Content — call handlers directly (fish does NOT capture emit handler stdout).
set -l inst (_tmux_lives_post_install | string collect)
t "install msg names tmux-setup"  1 (string match -q '*tmux-setup*' -- "$inst"; and echo 1; or echo 0)
t "install msg names tmux-status" 1 (string match -q '*tmux-status*' -- "$inst"; and echo 1; or echo 0)
set -l upd (_tmux_lives_post_update | string collect)
t "update msg says exec fish"     1 (string match -q '*exec fish*' -- "$upd"; and echo 1; or echo 0)
# Wiring — the dashed --on-event names are actually registered.
functions --handlers | grep -qE 'tmux-lives-install_install[[:space:]]+_tmux_lives_post_install'
t "install handler wired to dashed event" 0 $status
functions --handlers | grep -qE 'tmux-lives-install_update[[:space:]]+_tmux_lives_post_update'
t "update handler wired to dashed event"  0 $status

test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
