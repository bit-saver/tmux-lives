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

# automatic-rename-format: macOS reports claude's version-named binary as the window
# command (e.g. 2.1.185); map a version-like name (X.Y.Z) to "claude", pass others
# through. (No-op on Linux, where the command already reads "claude".)
set -l arf (__tmux_lives_render_fragment /X/cat.fish S M-s | string match -r '^set -g automatic-rename-format .*')
t "fragment sets automatic-rename-format" 1 (test -n "$arf"; and echo 1; or echo 0)
t "arf maps to claude"                    1 (string match -q '*claude*' -- "$arf"; and echo 1; or echo 0)
t "arf keeps pane_current_command"        1 (string match -q '*pane_current_command*' -- "$arf"; and echo 1; or echo 0)
set -g arsock tli-arf-$fish_pid
command tmux -L $arsock new-session -d 2>/dev/null
set -l arfmt (string replace 'set -g automatic-rename-format ' '' -- "$arf" | string trim -c "'")
t "tmux accepts the rendered format"      0 (command tmux -L $arsock set -g automatic-rename-format "$arfmt"; echo $status)
set -l fmt_v (string replace -a '#{pane_current_command}' '2.1.185' -- "$arfmt")
t "rendered format: version -> claude"  "claude" (command tmux -L $arsock display-message -p "$fmt_v")
set -l fmt_s (string replace -a '#{pane_current_command}' 'fish' -- "$arfmt")
t "rendered format: shell stays shell"  "fish"   (command tmux -L $arsock display-message -p "$fmt_s")
command tmux -L $arsock kill-server 2>/dev/null

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
t "help lists picker, p"  1 (string match -q '*picker, p*' -- "$hlp"; and echo 1; or echo 0)
t "help lists attach, a"  1 (string match -q '*attach, a*' -- "$hlp"; and echo 1; or echo 0)
t "help lists new, n"     1 (string match -q '*new, n*' -- "$hlp"; and echo 1; or echo 0)
t "help lists close"      1 (string match -q '*close, x, q*' -- "$hlp"; and echo 1; or echo 0)
t "help lists clear"      1 (string match -q '*clear*' -- "$hlp"; and echo 1; or echo 0)
t "help lists setup ptr"  1 (string match -q '*tmux-lives setup -h*' -- "$hlp"; and echo 1; or echo 0)
t "help drops start"      0 (string match -q '*start*' -- "$hlp"; and echo 1; or echo 0)
t "help drops top verify" 0 (string match -q '*verify, v*' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"  1 (test "$hlp" = (tmux-lives -h | string collect); and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown command returns 1" 1 $status
# routing: stub an IN-SCOPE helper (teardown is defined in this file) + confirm dispatch
functions -c __tmux_lives_teardown __tl_td_real
function __tmux_lives_teardown; set -g _tl_routed teardown; end
set -g _tl_routed ''
tmux-lives setup teardown
t "routes setup teardown -> helper" "teardown" "$_tl_routed"
functions -e __tmux_lives_teardown; functions -c __tl_td_real __tmux_lives_teardown
# command aliases route to the right action (picker/fixssh helpers live in
# conf.d/tmux.fish, not sourced here — define fresh stubs, so no backup/restore noise)
function __tmux_lives_picker; set -g _tl_a picker; end
function __tmux_lives_fixssh; set -g _tl_a fixssh; end
set -g _tl_a ''; tmux-lives p;      t "alias p -> picker"  picker "$_tl_a"
set -g _tl_a ''; tmux-lives picker; t "verb picker routes" picker "$_tl_a"
set -g _tl_a ''; tmux-lives f;      t "alias f -> fixssh"  fixssh "$_tl_a"
function __tmux_lives_new; set -g _tl_a new; end
set -g _tl_a ''; tmux-lives n;   t "alias n -> new"  new "$_tl_a"
set -g _tl_a ''; tmux-lives new; t "verb new routes" new "$_tl_a"
functions -e __tmux_lives_new
function __tmux_lives_attach; set -g _tl_a attach; end
set -g _tl_a ''; tmux-lives a foo;      t "alias a -> attach"  attach "$_tl_a"
set -g _tl_a ''; tmux-lives attach foo; t "verb attach routes" attach "$_tl_a"
functions -e __tmux_lives_attach
function __tmux_lives_close; set -g _tl_a close; end
set -g _tl_a ''; tmux-lives x;     t "alias x -> close" close "$_tl_a"
set -g _tl_a ''; tmux-lives q;     t "alias q -> close" close "$_tl_a"
set -g _tl_a ''; tmux-lives close; t "verb close routes" close "$_tl_a"
functions -e __tmux_lives_close
function __tmux_lives_clear; set -g _tl_a clear; end
set -g _tl_a ''; tmux-lives clear; t "verb clear routes" clear "$_tl_a"
functions -e __tmux_lives_clear
functions -e __tmux_lives_picker __tmux_lives_fixssh
# setup group routing
functions -c __tmux_lives_setup __tl_setup_real
function __tmux_lives_setup; set -g _tl_s install; end
function __tmux_lives_teardown; set -g _tl_s teardown; end 2>/dev/null
set -g _tl_s ''; tmux-lives setup install; t "setup install routes" install "$_tl_s"
set -g _tl_s ''; tmux-lives setup i;       t "setup i -> install"  install "$_tl_s"
t "setup verify shows keys" 1 (tmux-lives setup verify 2>/dev/null | string match -q '*switcher keys*'; and echo 1; or echo 0)
set -l sh (tmux-lives setup | string collect)
t "bare setup shows setup help" 1 (string match -q '*install, i*' -- "$sh"; and echo 1; or echo 0)
t "setup -h equals bare setup"  1 (test "$sh" = (tmux-lives setup -h | string collect); and echo 1; or echo 0)
t "setup help lists keys"  1 (string match -q '*keys*' -- "$sh"; and echo 1; or echo 0)
t "setup help lists auto"  1 (string match -q '*auto on*' -- "$sh"; and echo 1; or echo 0)
tmux-lives setup bogus 2>/dev/null; t "setup unknown rc1" 1 $status
functions -e __tmux_lives_setup; functions -c __tl_setup_real __tmux_lives_setup
# keys persistence
set -e tmux_lives_prefix_key
functions -c __tmux_lives_write_fragment __tl_wf_bak 2>/dev/null
function __tmux_lives_write_fragment; end
tmux-lives setup keys -p C-a
t "setup keys -p persists" "C-a" "$tmux_lives_prefix_key"
set -e tmux_lives_prefix_key
functions -q __tl_wf_bak; and begin; functions -e __tmux_lives_write_fragment; functions -c __tl_wf_bak __tmux_lives_write_fragment; end

# Content — call handlers directly (fish does NOT capture emit handler stdout).
set -l inst (_tmux_lives_post_install | string collect)
t "install msg names tmux-lives setup install" 1 (string match -q '*tmux-lives setup install*' -- "$inst"; and echo 1; or echo 0)
t "install msg points to full help"            1 (string match -q '*to see all commands*' -- "$inst"; and echo 1; or echo 0)
t "install msg drops separate verify step"     0 (string match -q '*tmux-lives verify*' -- "$inst"; and echo 1; or echo 0)
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
