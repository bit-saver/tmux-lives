#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1] => got [$argv[3]]"; end; end

set -l frag (__tmux_lives_render_fragment /X/cat.fish S M-s | string collect)
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
t "fragment binds prefix S"        1 (string match -q '*bind-key S display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment binds no-prefix M-s"   1 (string match -q '*bind-key -n M-s display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment menu fallback both"    1 (string match -q '*bind-key -n M-s run-shell*' -- "$frag"; and echo 1; or echo 0)
set -l fragc (__tmux_lives_render_fragment /X/cat.fish C-a C-s | string collect)
t "fragment custom prefix key"     1 (string match -q '*bind-key C-a display-popup*' -- "$fragc"; and echo 1; or echo 0)
t "fragment custom switcher key"   1 (string match -q '*bind-key -n C-s display-popup*' -- "$fragc"; and echo 1; or echo 0)
set -l fragp (__tmux_lives_render_fragment /X/cat.fish S '' | string collect)
t "disabled switcher: no -n bind"  0 (string match -q '*bind-key -n*' -- "$fragp"; and echo 1; or echo 0)
t "disabled switcher: prefix kept" 1 (string match -q '*bind-key S display-popup*' -- "$fragp"; and echo 1; or echo 0)
set -l frags (__tmux_lives_render_fragment /X/cat.fish '' M-s | string collect)
t "disabled prefix: no prefix bind" 0 (string match -q '*bind-key S *' -- "$frags"; and echo 1; or echo 0)
# resolver
set -U _tl_k C-x
t "key: set var wins"   "C-x" (__tmux_lives_key _tl_k S)
set -U _tl_k ''
t "key: empty disables" ""    (__tmux_lives_key _tl_k S)
set -e _tl_k
t "key: unset -> default" "S" (__tmux_lives_key _tl_k S)

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
t "help lists setup"     1 (string match -q '*setup *' -- "$hlp"; and echo 1; or echo 0)
t "help lists verify, v"  1 (string match -q '*verify, v*' -- "$hlp"; and echo 1; or echo 0)
t "help lists switch, s"  1 (string match -q '*switch, s *' -- "$hlp"; and echo 1; or echo 0)
t "help lists take, t"    1 (string match -q '*take, t *' -- "$hlp"; and echo 1; or echo 0)
t "help lists fixssh, f"  1 (string match -q '*fixssh, f*' -- "$hlp"; and echo 1; or echo 0)
t "help lists auto"       1 (string match -q '*auto *' -- "$hlp"; and echo 1; or echo 0)
t "help USAGE header"     1 (string match -q '*USAGE*' -- "$hlp"; and echo 1; or echo 0)
t "help mentions --prefix-key"   1 (string match -q '*--prefix-key*' -- "$hlp"; and echo 1; or echo 0)
t "help mentions --switcher-key" 1 (string match -q '*--switcher-key*' -- "$hlp"; and echo 1; or echo 0)
t "help shows -p short flag"     1 (string match -q '*-p, --prefix-key*' -- "$hlp"; and echo 1; or echo 0)
t "help shows -s short flag"     1 (string match -q '*-s, --switcher-key*' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"  1 (test "$hlp" = (tmux-lives -h | string collect); and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown command returns 1" 1 $status
# routing: stub an IN-SCOPE helper (teardown is defined in this file) + confirm dispatch
functions -c __tmux_lives_teardown __tl_td_real
function __tmux_lives_teardown; set -g _tl_routed teardown; end
set -g _tl_routed ''
tmux-lives teardown
t "routes teardown -> helper" "teardown" "$_tl_routed"
functions -e __tmux_lives_teardown; functions -c __tl_td_real __tmux_lives_teardown
# command aliases route to the right action (switch/take/fixssh helpers live in
# conf.d/tmux.fish, not sourced here — define fresh stubs, so no backup/restore noise)
t "alias v -> verify" 1 (tmux-lives v 2>/dev/null | string match -q '*switcher keys*'; and echo 1; or echo 0)
function __tmux_lives_switch; set -g _tl_a switch; end
function __tmux_lives_take;   set -g _tl_a take;   end
function __tmux_lives_fixssh; set -g _tl_a fixssh; end
set -g _tl_a ''; tmux-lives s;     t "alias s -> switch" switch "$_tl_a"
set -g _tl_a ''; tmux-lives t foo; t "alias t -> take"   take   "$_tl_a"
set -g _tl_a ''; tmux-lives f;     t "alias f -> fixssh" fixssh "$_tl_a"
functions -e __tmux_lives_switch __tmux_lives_take __tmux_lives_fixssh
# setup flag parsing persists the universal vars (stub the heavy setup body)
functions -c __tmux_lives_setup __tl_setup_real
function __tmux_lives_setup; end
set -e tmux_lives_prefix_key tmux_lives_switcher_key
tmux-lives setup --prefix-key C-a --switcher-key C-s
t "flag persists prefix-key"   "C-a" "$tmux_lives_prefix_key"
t "flag persists switcher-key" "C-s" "$tmux_lives_switcher_key"
set -e tmux_lives_prefix_key tmux_lives_switcher_key
tmux-lives setup -p C-b -s C-t
t "short -p persists" "C-b" "$tmux_lives_prefix_key"
t "short -s persists" "C-t" "$tmux_lives_switcher_key"
set -e tmux_lives_prefix_key tmux_lives_switcher_key
functions -e __tmux_lives_setup; functions -c __tl_setup_real __tmux_lives_setup

# Content — call handlers directly (fish does NOT capture emit handler stdout).
set -l inst (_tmux_lives_post_install | string collect)
t "install msg names tmux-lives setup"  1 (string match -q '*tmux-lives setup*' -- "$inst"; and echo 1; or echo 0)
t "install msg points to full help"        1 (string match -q '*to see all commands*' -- "$inst"; and echo 1; or echo 0)
t "install msg drops separate verify step"  0 (string match -q '*tmux-lives verify*' -- "$inst"; and echo 1; or echo 0)
set -l upd (_tmux_lives_post_update | string collect)
t "update msg says exec fish"     1 (string match -q '*exec fish*' -- "$upd"; and echo 1; or echo 0)
# Wiring — the dashed --on-event names are actually registered.
functions --handlers | grep -qE 'tmux-lives-install_install[[:space:]]+_tmux_lives_post_install'
t "install handler wired to dashed event" 0 $status
functions --handlers | grep -qE 'tmux-lives-install_update[[:space:]]+_tmux_lives_post_update'
t "update handler wired to dashed event"  0 $status

# ---------------------------------------------------------------------
# __tmux_lives_reload: source the conf into a RUNNING tmux (so `setup` needs no
# manual reload), no-op when no server (fresh host). Isolated tmux via a PATH
# shim (-L socket) — never touches the real server.
# ---------------------------------------------------------------------
set -g rlsock tli-reload-$fish_pid
set -g rlshim /tmp/tli-shim-$fish_pid
mkdir -p $rlshim
printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $rlsock > $rlshim/tmux
chmod +x $rlshim/tmux
set -g rl_path_save $PATH
set -gx PATH $rlshim $PATH
tmux kill-server 2>/dev/null
t "reload: no server -> rc 0 no-op" 0 (__tmux_lives_reload /tmp/nope-$fish_pid.conf; echo $status)
set -l rlconf /tmp/tli-reload-$fish_pid.conf
printf 'set -g @tl_reloaded yes\n' > $rlconf
tmux new-session -d -s rl
__tmux_lives_reload $rlconf
t "reload: sources conf into live server" "yes" (tmux show-option -gv @tl_reloaded)
tmux kill-server 2>/dev/null
set -gx PATH $rl_path_save
rm -rf $rlshim $rlconf

test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
