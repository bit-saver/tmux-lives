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

set -g FRAG (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t | string collect)
t "fragment binds modal key (popup)" yes (string match -q '*bind-key -n M-m display-popup*cat.fish modal*' -- "$FRAG"; and echo yes; or echo no)
t "fragment binds modal key (menu fallback)" yes (string match -q '*bind-key -n M-m run-shell*modal-menu*' -- "$FRAG"; and echo yes; or echo no)
t "fragment binds scratch key" yes (string match -q '*bind-key -n M-t run-shell*cat.fish scratch*' -- "$FRAG"; and echo yes; or echo no)
# empty modal/scratch keys -> no such binds
set -g FRAG2 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 '' '' | string collect)
t "no modal bind when key empty" no (string match -q '*cat.fish modal*' -- "$FRAG2"; and echo yes; or echo no)
t "no scratch bind when key empty" no (string match -q '*cat.fish scratch*' -- "$FRAG2"; and echo yes; or echo no)

set -g FRAGR (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r | string collect)
t "fragment modal bind passes keys" yes (string match -q "*cat.fish modal '#{client_name}' 'M-m' 'M-t' 'M-r' 'M-s'*" -- "$FRAGR"; and echo yes; or echo no)
t "modal popup is borderless (-B)" yes (string match -q '*display-popup -B -E*' -- "$FRAGR"; and echo yes; or echo no)
t "modal popup sized to the menu (not 64%)" yes (string match -q '*-w 34 -h 15*' -- "$FRAGR"; and not string match -q '*64%*' -- "$FRAGR"; and echo yes; or echo no)
t "fragment binds M-r to resize-enter" yes (string match -q '*bind-key -n M-r run-shell*resize-enter*' -- "$FRAGR"; and echo yes; or echo no)
t "fragment defines resize key-table" yes (string match -q '*bind-key -T tmuxlives-resize*' -- "$FRAGR"; and echo yes; or echo no)
t "resize table arrow re-enters (sticky)" yes (string match -q '*tmuxlives-resize Left*scratch-resize L*switch-client -T tmuxlives-resize*' -- "$FRAGR"; and echo yes; or echo no)
t "resize table esc returns to root" yes (string match -q '*tmuxlives-resize Escape*switch-client -T root*' -- "$FRAGR"; and echo yes; or echo no)
set -g FRAGR0 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t '' | string collect)
t "no M-r bind when resize key empty" no (string match -q '*resize-enter*' -- "$FRAGR0"; and echo yes; or echo no)
# rendered fragment still parses on a real -L server
set -g rsock tli-rz-$fish_pid
command tmux -L $rsock new-session -d 2>/dev/null
printf '%s\n' "$FRAGR" | string replace -a '/x/cat.fish' '/tmp/nope.fish' > /tmp/tli-rzfrag-$fish_pid.conf
t "resize fragment parses (source-file rc0)" 0 (command tmux -L $rsock source-file /tmp/tli-rzfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $rsock kill-server 2>/dev/null; rm -f /tmp/tli-rzfrag-$fish_pid.conf

# status-bar toggle binds + state-file sourcing
set -g FRAGS (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s | string collect)
t "fragment binds status-pos key" yes (string match -q '*bind-key -n C-M-a run-shell*status-pos-toggle*' -- "$FRAGS"; and echo yes; or echo no)
t "fragment binds status-vis key" yes (string match -q '*bind-key -n C-M-s run-shell*status-vis-toggle*' -- "$FRAGS"; and echo yes; or echo no)
t "fragment sources the state file" yes (string match -q '*if-shell*tmux-lives-state.conf*source-file*tmux-lives-state.conf*' -- "$FRAGS"; and echo yes; or echo no)
set -g FRAGS0 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r '' '' | string collect)
t "no status-pos bind when key empty" no (string match -q '*status-pos-toggle*' -- "$FRAGS0"; and echo yes; or echo no)
t "no status-vis bind when key empty" no (string match -q '*status-vis-toggle*' -- "$FRAGS0"; and echo yes; or echo no)
# the full fragment (with the status binds) still parses on a real -L server
set -g rsock2 tli-sb-$fish_pid
command tmux -L $rsock2 new-session -d 2>/dev/null
printf '%s\n' "$FRAGS" | string replace -a '/x/cat.fish' '/tmp/nope.fish' >/tmp/tli-sbfrag-$fish_pid.conf
t "status fragment parses (source-file rc0)" 0 (command tmux -L $rsock2 source-file /tmp/tli-sbfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $rsock2 kill-server 2>/dev/null; rm -f /tmp/tli-sbfrag-$fish_pid.conf

# --- status-bar overhaul: fragment carries the new bar + keeps the plumbing ---
# Render with a color so status-style is emitted; fake cat path -> host-kind/status-format
# substitutions yield empty (render silences their stderr), but the option NAMES are present.
set -g BAR (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s | string collect)
t "fragment sets status-format[0]" yes (string match -q '*set -g status-format[0]*' -- "$BAR"; and echo yes; or echo no)
t "fragment still sets status-right with the tick" yes (string match -q '*set -g status-right*tick*' -- "$BAR"; and echo yes; or echo no)
t "fragment window-status-format tints the claude window" yes (string match -q "*set -g window-status-format '#{?#{==:#{window_name},claude}*" -- "$BAR"; and string match -q '*#{@tmux_lives_claude_color}*' -- "$BAR"; and echo yes; or echo no)
t "fragment sets window-status-separator bullet" yes (string match -q '*window-status-separator*•*' -- "$BAR"; and echo yes; or echo no)
t "fragment seeds @tmux_lives_claude_color (quoted hex)" yes (string match -q "*set -g @tmux_lives_claude_color '#D97757'*" -- "$BAR"; and echo yes; or echo no)
t "fragment seeds @tmux_lives_heal_interval" yes (string match -q '*set -g @tmux_lives_heal_interval 120*' -- "$BAR"; and echo yes; or echo no)
t "fragment current-format keeps bold + tints claude" yes (string match -q '*window-status-current-format*#[bold]*#{?#{==:#{window_name},claude}*' -- "$BAR"; and echo yes; or echo no)
t "fragment seeds host-kind + glyph + accent @options" yes (string match -q '*@tmux_lives_host_kind*' -- "$BAR"; and string match -q '*@tmux_lives_glyph_remote*' -- "$BAR"; and string match -q '*@tmux_lives_prefix_color*' -- "$BAR"; and echo yes; or echo no)
# cap bg must be QUOTED so a #rrggbb hex is not swallowed as a tmux comment (empty value).
t "fragment cap bg derives from the shellfish color (quoted)" yes (string match -q "*@tmux_lives_cap_bg '#5793f0'*" -- "$BAR"; and echo yes; or echo no)
t "fragment still sets status-style (shellfish color)" yes (string match -q '*set -g status-style*' -- "$BAR"; and echo yes; or echo no)
# rendered fragment (fake cat path, empty computed values) must PARSE on a private -L socket
set -g sfsock tli-bar-$fish_pid
command tmux -L $sfsock new-session -d 2>/dev/null
printf '%s\n' $BAR > /tmp/tli-barfrag-$fish_pid.conf
t "bar fragment parses (source-file rc0)" 0 (command tmux -L $sfsock source-file /tmp/tli-barfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $sfsock kill-server 2>/dev/null; rm -f /tmp/tli-barfrag-$fish_pid.conf
# resolution 3: render with the REAL categorizer so status-format[0] is the actual Task-1
# string (non-empty), and prove that string is valid tmux config on a live -L server.
set -g realcat $plugindir/functions/tmux-categorize.fish
set -g BARR (__tmux_lives_render_fragment $realcat S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s | string collect)
t "real status-format[0] is non-empty" yes (string match -q '*◇ RESIZE ◇*' -- "$BARR"; and echo yes; or echo no)
set -g brsock tli-barr-$fish_pid
command tmux -L $brsock new-session -d 2>/dev/null
printf '%s\n' $BARR > /tmp/tli-barrfrag-$fish_pid.conf
t "real bar fragment parses (source-file rc0)" 0 (command tmux -L $brsock source-file /tmp/tli-barrfrag-$fish_pid.conf 2>/dev/null; echo $status)
# the #rrggbb cap bg must SURVIVE the source (an unquoted # would be eaten as a comment ->
# empty value even though source-file still returns rc0). Assert the live option is the hex.
t "real: cap bg option stored non-empty hex" "#5793f0" (command tmux -L $brsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "real: status-format[0] stored non-empty" 1 (test -n (command tmux -L $brsock show -gv status-format[0] 2>/dev/null); and echo 1; or echo 0)
command tmux -L $brsock kill-server 2>/dev/null; rm -f /tmp/tli-barrfrag-$fish_pid.conf
# baseline no longer owns the layout (fragment's status-format[0] does)
set -g BT (__tmux_lives_baseline_template | string collect)
t "baseline no longer sets status-left" yes (string match -q '*set -g status-left *' -- "$BT"; and echo no; or echo yes)
t "baseline no longer sets window-status-format" yes (string match -q '*window-status-format*' -- "$BT"; and echo no; or echo yes)
t "baseline still sets the clock @var" yes (string match -q '*@tmux_lives_status_right*' -- "$BT"; and echo yes; or echo no)
t "baseline keeps status-right-length (referenced by the new right zone)" yes (string match -q '*status-right-length*' -- "$BT"; and echo yes; or echo no)
# derive helper: just the bg hex of the derived status-style
t "derive_status_bg: lighter #1f6feb" "#5793f0" (__tmux_lives_derive_status_bg "#1f6feb" 0)
t "derive_status_bg: darker #1f6feb"  "#1753b0" (__tmux_lives_derive_status_bg "#1f6feb" 1)
t "derive_status_bg: named -> empty"  ""        (__tmux_lives_derive_status_bg "red" 0)

# write_fragment must refuse to render a fragment pointing at a nonexistent categorizer
# (a bad $__fish_config_dir, e.g. a test's temp dir) so a stray call can't corrupt the live file
t "write_fragment guards a missing categorizer" yes (string match -q '*test -f $cat*return*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)

# setup keys flags persist universals
set -e tmux_lives_modal_key; set -e tmux_lives_scratch_key
functions -c __tmux_lives_write_fragment __wf_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --modal-key M-m --scratch-key M-t
t "keys --modal-key persists" M-m "$tmux_lives_modal_key"
t "keys --scratch-key persists" M-t "$tmux_lives_scratch_key"
functions -e __tmux_lives_write_fragment; functions -c __wf_bak __tmux_lives_write_fragment; functions -e __wf_bak
set -e tmux_lives_modal_key; set -e tmux_lives_scratch_key

set -e tmux_lives_resize_key
functions -c __tmux_lives_write_fragment __wf3_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --resize-key M-r
t "keys --resize-key persists" M-r "$tmux_lives_resize_key"
functions -e __tmux_lives_write_fragment; functions -c __wf3_bak __tmux_lives_write_fragment; functions -e __wf3_bak
set -e tmux_lives_resize_key

set -e tmux_lives_status_pos_key; set -e tmux_lives_status_vis_key
functions -c __tmux_lives_write_fragment __wf4_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --status-pos-key C-M-a --status-vis-key C-M-s
t "keys --status-pos-key persists" C-M-a "$tmux_lives_status_pos_key"
t "keys --status-vis-key persists" C-M-s "$tmux_lives_status_vis_key"
functions -e __tmux_lives_write_fragment; functions -c __wf4_bak __tmux_lives_write_fragment; functions -e __wf4_bak
set -e tmux_lives_status_pos_key; set -e tmux_lives_status_vis_key
t "help documents --status-pos-key" yes (string match -q '*--status-pos-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "help documents --status-vis-key" yes (string match -q '*--status-vis-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "setup help still fits 80 cols framed" yes (set -l mx 0; for l in (__tmux_lives_setup_help_lines); set -l w (string length --visible -- $l); test $w -gt $mx; and set mx $w; end; test (math "$mx + 4") -le 80; and echo yes; or echo no)

set -l fragbc (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" | string collect)
t "fragment has client-attached hook" 1 (string match -q '*client-attached*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook calls on-attach"     1 (string match -q '*on-attach*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook passes client_pid"   1 (string match -q '*on-attach*#{client_pid}*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook passes client_tty"   1 (string match -q '*#{client_tty}*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment bakes the color"          1 (string match -q '*#1f6feb*' -- "$fragbc"; and echo 1; or echo 0)
set -l fragnc (__tmux_lives_render_fragment /X/cat.fish S M-s '' | string collect)
t "hook present without a color"      1 (string match -q '*client-attached*on-attach*' -- "$fragnc"; and echo 1; or echo 0)
t "3-arg call still renders the hook" 1 (string match -q '*client-attached*' -- (__tmux_lives_render_fragment /X/cat.fish S M-s | string collect); and echo 1; or echo 0)

set -l fragss (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" 0 | string collect)
t "fragment status-style lighter" 1 (string match -q '*set -g status-style bg=#5793f0,fg=#c9dcfa*' -- "$fragss"; and echo 1; or echo 0)
set -l fragssi (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" 1 | string collect)
t "fragment status-style darker"  1 (string match -q '*status-style bg=#1753b0*' -- "$fragssi"; and echo 1; or echo 0)
set -l fragssn (__tmux_lives_render_fragment /X/cat.fish S M-s "" 0 | string collect)
t "no color -> no status-style"   0 (string match -q '*status-style*' -- "$fragssn"; and echo 1; or echo 0)
t "no color -> hook still there"  1 (string match -q '*client-attached*' -- "$fragssn"; and echo 1; or echo 0)

set -l fragsr (__tmux_lives_render_fragment /X/cat.fish S M-s "" 0 | string collect)
t "fragment sources user config"  1 (string match -q '*source-file*.tmux-lives.conf*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment default status-right var" 1 (string match -q '*set -g @tmux_lives_status_right*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment status-right uses T:@var" 1 (string match -q '*set -g status-right "#{T:@tmux_lives_status_right}*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment status-right keeps tick"  1 (string match -q "*#{T:@tmux_lives_status_right}#(fish*tick '')*" -- "$fragsr"; and echo 1; or echo 0)
t "fragment drops old -ga status-right" 0 (string match -q '*set -ga status-right*' -- "$fragsr"; and echo 1; or echo 0)
set -g FRAGT (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 | string collect)
t "tick call bakes the bar color" yes (string match -q "*cat.fish tick '#1f6feb'*" -- "$FRAGT"; and echo yes; or echo no)
set -g FRAGT0 (__tmux_lives_render_fragment /x/cat.fish S M-s "" 0 | string collect)
t "tick call empty color when unset" yes (string match -q "*cat.fish tick ''*" -- "$FRAGT0"; and echo yes; or echo no)
set -g FRAGT2 (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 | string collect)
t "client-session-changed hook re-titles" yes (string match -q "*client-session-changed*cat.fish retitle*" -- "$FRAGT2"; and echo yes; or echo no)

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

# setup color: stores the universal var + bakes into the re-rendered fragment
set -l cfrag /tmp/tli-colorfrag-$fish_pid.conf
functions --copy __tmux_lives_write_fragment __tmux_lives_wf_orig  # save the real one for later blocks
function __tmux_lives_write_fragment --description 'test stub: render to a temp path'
    __tmux_lives_render_fragment /X/cat.fish S M-s (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) > /tmp/tli-colorfrag-$fish_pid.conf
end
# This block mutates the REAL universal var tmux_lives_bar_color (the command sets -U).
# Save the user's value and restore it at the end so the suite never clobbers a configured color.
set -l _bc_had 0
set -l _bc_val
if set -q tmux_lives_bar_color
    set _bc_had 1
    set _bc_val $tmux_lives_bar_color
end
set -e tmux_lives_bar_color
set -l _si_had 0
set -l _si_val
if set -q tmux_lives_status_invert
    set _si_had 1
    set _si_val $tmux_lives_status_invert
end
set -e tmux_lives_status_invert
t "color: empty when unset" 1 (string match -q '*none*' -- (__tmux_lives_color_cmd); and echo 1; or echo 0)
__tmux_lives_color_cmd "#ff8800" >/dev/null
t "color: stored in universal var" "#ff8800" "$tmux_lives_bar_color"
t "color: baked into fragment" 1 (string match -q '*#ff8800*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
__tmux_lives_color_cmd "" >/dev/null
t "color: cleared to empty" "" "$tmux_lives_bar_color"
__tmux_lives_color_cmd "#1f6feb" -i >/dev/null
t "color -i: invert var = 1"     "1" "$tmux_lives_status_invert"
t "color -i: fragment darker"    1 (string match -q '*status-style bg=#1753b0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
__tmux_lives_color_cmd "#1f6feb" >/dev/null
t "color no -i: invert var = 0"  "0" "$tmux_lives_status_invert"
t "color: fragment lighter"      1 (string match -q '*status-style bg=#5793f0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
t "color show: reports lighter"  1 (string match -q '*status bar: lighter*' -- (__tmux_lives_color_cmd | string collect); and echo 1; or echo 0)
t "color -i no color: rc1"       1 (__tmux_lives_color_cmd -i >/dev/null 2>&1; echo $status)
__tmux_lives_color_cmd "" >/dev/null
t "color: rejects unsafe value (rc1)" 1 (__tmux_lives_color_cmd "bad';x" >/dev/null 2>&1; echo $status)
t "color: unsafe value not stored"    "" "$tmux_lives_bar_color"
t "color: accepts rgb() with spaces"  0 (__tmux_lives_color_cmd "rgb(255, 0, 0)" >/dev/null 2>&1; echo $status)
__tmux_lives_color_cmd "" >/dev/null
# Bare-hex normalization test block: stubs write_fragment to avoid live mutations + sets
# __fish_config_dir to nonexistent path so recolor's test-f guard short-circuits.
set -g __old_fcd $__fish_config_dir
set -g __fish_config_dir /tmp/tcz-nofish-$fish_pid
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
functions -c __tmux_lives_write_fragment __wf2_bak
function __tmux_lives_write_fragment; end
__tmux_lives_color_cmd 1f6feb >/dev/null
t "bare 6-hex normalized to #1f6feb" "#1f6feb" "$tmux_lives_bar_color"
t "normalized hex yields non-empty status-style" yes (test -n (__tmux_lives_derive_status "$tmux_lives_bar_color" 0); and echo yes; or echo no)
__tmux_lives_color_cmd abc >/dev/null
t "bare 3-hex normalized to #abc" "#abc" "$tmux_lives_bar_color"
__tmux_lives_color_cmd "#deadbe" >/dev/null
t "already-hashed hex untouched" "#deadbe" "$tmux_lives_bar_color"
__tmux_lives_color_cmd red >/dev/null
t "named colour untouched" red "$tmux_lives_bar_color"
functions -e __tmux_lives_write_fragment; functions -c __wf2_bak __tmux_lives_write_fragment; functions -e __wf2_bak
set -g __fish_config_dir $__old_fcd; set -e __old_fcd
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
functions -e __tmux_lives_write_fragment; functions --copy __tmux_lives_wf_orig __tmux_lives_write_fragment; functions -e __tmux_lives_wf_orig
if test $_bc_had -eq 1
    set -U tmux_lives_bar_color $_bc_val
else
    set -e tmux_lives_bar_color
end
if test $_si_had -eq 1
    set -U tmux_lives_status_invert $_si_val
else
    set -e tmux_lives_status_invert
end
rm -f $cfrag

# setup color --apply: reapply stored color live (status-style via the socket seam; recolor guarded)
set -g apsock tli-apply-$fish_pid
command tmux -L $apsock new-session -d 2>/dev/null
set -gx tmux_lives_tmux_socket $apsock
set -g __old_fcd2 $__fish_config_dir
set -g __fish_config_dir /tmp/tcz-nofish2-$fish_pid   # recolor's test -f guard short-circuits
set -l _abc_had 0; set -l _abc_val
if set -q tmux_lives_bar_color; set _abc_had 1; set _abc_val $tmux_lives_bar_color; end
set -l _asi_had 0; set -l _asi_val
if set -q tmux_lives_status_invert; set _asi_had 1; set _asi_val $tmux_lives_status_invert; end
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
t "color --apply with no color: rc1" 1 (__tmux_lives_color_cmd --apply >/dev/null 2>&1; echo $status)
set -U tmux_lives_bar_color "#1f6feb"; set -U tmux_lives_status_invert 0
__tmux_lives_color_cmd --apply >/dev/null
t "color --apply sets derived status-style live" 1 (string match -q '*bg=#5793f0*' -- (command tmux -L $apsock show -gv status-style); and echo 1; or echo 0)
t "color -a rejects an extra color arg (rc1)" 1 (__tmux_lives_color_cmd -a "#abc" >/dev/null 2>&1; echo $status)
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
if test $_abc_had -eq 1; set -U tmux_lives_bar_color $_abc_val; end
if test $_asi_had -eq 1; set -U tmux_lives_status_invert $_asi_val; end
set -g __fish_config_dir $__old_fcd2; set -e __old_fcd2
set -e tmux_lives_tmux_socket
command tmux -L $apsock kill-server 2>/dev/null

# help + verify mention color
t "setup help lists color" 1 (string match -q '*color*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "setup help documents color --apply/-a" 1 (string match -q '*-a*reapply*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "verify reports bar color" 1 (string match -q '*bar color*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
t "verify reports status direction" 1 (string match -q '*status bar:*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
t "help color row mentions -i" 1 (string match -q '*color*-i*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)

# baseline file: seed-once + conf add
set -g tmux_lives_baseline_conf /tmp/tli-baseline-$fish_pid.conf
rm -f $tmux_lives_baseline_conf
t "baseline: path honors seam" "$tmux_lives_baseline_conf" (__tmux_lives_baseline_path)
__tmux_lives_seed_baseline (__tmux_lives_baseline_path)
t "baseline: seeded file exists" 1 (test -e $tmux_lives_baseline_conf; and echo 1; or echo 0)
# layout (status-left / window-status-*) is now owned by the fragment's status-format[0];
# the baseline only keeps the clock @var + status-right-length it feeds.
t "baseline: no longer seeds status-left" 1 (string match -q '*set -g status-left*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 0; or echo 1)
t "baseline: seeds status-right var" 1 (string match -q '*@tmux_lives_status_right*%-I:%M*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
t "baseline: no longer seeds window-status-current" 1 (string match -q '*window-status-current-style*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 0; or echo 1)
t "baseline: keeps commented mouse"  1 (string match -q '*# set -g mouse off*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
printf '# hand edit\n' >> $tmux_lives_baseline_conf
__tmux_lives_seed_baseline (__tmux_lives_baseline_path)
t "baseline: seed never overwrites" 1 (string match -q '*hand edit*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
# conf add/reset call `tmux source-file` — pin it to a throwaway -L socket so the suite
# never reconfigures the user's real tmux server (README: tests never touch the real server).
set -g tmux_lives_tmux_socket tli-conf-$fish_pid
command tmux -L $tmux_lives_tmux_socket new-session -d 2>/dev/null
__tmux_lives_conf_cmd add 'set -g mouse off' >/dev/null
t "baseline: conf add appends line" 1 (grep -qF 'set -g mouse off' $tmux_lives_baseline_conf; and echo 1; or echo 0)
t "baseline: conf add with no cmd rc1" 1 (__tmux_lives_conf_cmd add >/dev/null 2>&1; echo $status)
printf 'set -g @user_edit 1\n' > $tmux_lives_baseline_conf
__tmux_lives_conf_cmd reset >/dev/null
t "conf reset: backup has user edit" 1 (string match -q '*@user_edit*' -- (cat "$tmux_lives_baseline_conf.bak" | string collect); and echo 1; or echo 0)
t "conf reset: file restored to template" 1 (string match -q '*@tmux_lives_status_right*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
command tmux -L $tmux_lives_tmux_socket kill-server 2>/dev/null
set -e tmux_lives_tmux_socket
rm -f "$tmux_lives_baseline_conf.bak"
t "baseline: conf (no arg) shows path" 1 (string match -q "*$tmux_lives_baseline_conf*" -- (__tmux_lives_conf_cmd | string collect); and echo 1; or echo 0)
rm -f $tmux_lives_baseline_conf
set -e tmux_lives_baseline_conf
# help + verify mention conf/baseline
t "setup help lists conf" 1 (string match -q '*conf*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "help conf row shows reset" 1 (string match -q '*conf*reset*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "verify reports baseline" 1 (string match -q '*baseline*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)

# status color derivation: lighten/darken + auto-contrast fg + parse scope
t "derive: lighter #1f6feb"  "bg=#5793f0,fg=#c9dcfa" (__tmux_lives_derive_status "#1f6feb" 0)
t "derive: darker  #1f6feb"  "bg=#1753b0,fg=#b5c8e6" (__tmux_lives_derive_status "#1f6feb" 1)
t "derive: short hex == long" (__tmux_lives_derive_status "#1199ff" 0) (__tmux_lives_derive_status "#19f" 0)
t "derive: rgb() == hex"      (__tmux_lives_derive_status "#1f6feb" 0) (__tmux_lives_derive_status "rgb(31, 111, 235)" 0)
t "derive: light base tinted" "bg=#fff2a6,fg=#524d35" (__tmux_lives_derive_status "#ffee88" 0)
t "derive: dark base tinted"  "bg=#4c5864,fg=#c6cacd" (__tmux_lives_derive_status "#102030" 0)
t "derive: named -> empty" "" (__tmux_lives_derive_status "red" 0)
t "derive: empty -> empty"  "" (__tmux_lives_derive_status "" 0)

# post-update auto-refresh: a fisher update re-renders the fragment IFF one already exists,
# so new wiring (e.g. the client-attached hook) lands without a manual `tmux-lives setup`.
set -g tmux_lives_fragment_file /tmp/tli-pufrag-$fish_pid.conf
t "fragment: path honors seam" "$tmux_lives_fragment_file" (__tmux_lives_fragment_path)
functions --copy __tmux_lives_write_fragment __tmux_lives_wf_real
function __tmux_lives_write_fragment; set -g _wf_called 1; end
set -g _tmux_lives_updating 1    # suppress the post-update note during the test
rm -f $tmux_lives_fragment_file
set -g _wf_called 0
_tmux_lives_post_update
t "post-update: no fragment -> no re-render" 0 $_wf_called
echo x > $tmux_lives_fragment_file
set _wf_called 0
_tmux_lives_post_update
t "post-update: fragment exists -> re-render" 1 $_wf_called
set -e _tmux_lives_updating
functions -e __tmux_lives_write_fragment
functions --copy __tmux_lives_wf_real __tmux_lives_write_fragment
functions -e __tmux_lives_wf_real
rm -f $tmux_lives_fragment_file
set -e tmux_lives_fragment_file

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

# ---------------------------------------------------------------------
# __tmux_lives_box — rounded, orange-bordered frame around stdin lines
# ---------------------------------------------------------------------
function vis; string replace -ra '\x1b\[[0-9;]*m' '' -- "$argv[1]"; end
set -l bx (printf 'alpha\nbb\n' | __tmux_lives_box 'T')
t "box top: rounded corner + title"  1 (string match -rq '^╭─ T ─' -- (vis "$bx[1]"); and echo 1; or echo 0)
t "box top: closes with corner"      1 (string match -q '*╮' -- (vis "$bx[1]"); and echo 1; or echo 0)
t "box content framed by bars"       1 (string match -q '*│*alpha*│*' -- (vis "$bx[2]"); and echo 1; or echo 0)
t "box bottom: rounded rule"         1 (string match -rq '^╰─+╯$' -- (vis "$bx[-1]"); and echo 1; or echo 0)
t "box border is orange (208)"       1 (string match -q '*38;5;208*' -- "$bx[1]"; and echo 1; or echo 0)
set -l w_top (string length --visible (vis "$bx[1]"))
set -l w_mid (string length --visible (vis "$bx[2]"))
set -l w_bot (string length --visible (vis "$bx[-1]"))
t "box rows aligned (top=content)"   1 (test "$w_top" = "$w_mid"; and echo 1; or echo 0)
t "box rows aligned (bot=content)"   1 (test "$w_bot" = "$w_mid"; and echo 1; or echo 0)
t "box width fits widest line"       9 "$w_mid"

# help CONTENT/order asserted on the unframed lines; framed output is $hbox
set -l hlp (__tmux_lives_help_lines | string collect)
set -l hbox (tmux-lives | string collect)
# alias-first layout: "<alias>  <command> <args>   <description>"; help row removed
t "help: help row removed"      0 (string match -q '*show this help*' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: u update"       1 (string match -rq '(?m)^u +update\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: n new"          1 (string match -rq '(?m)^n +new\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: a attach"       1 (string match -rq '(?m)^a +attach\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: p picker"       1 (string match -rq '(?m)^p +picker\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: f fix"          1 (string match -rq '(?m)^f +fix\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: c categorize"   1 (string match -rq '(?m)^c +categorize\b' -- "$hlp"; and echo 1; or echo 0)
t "alias-first: x close"        1 (string match -rq '(?m)^x +close\b' -- "$hlp"; and echo 1; or echo 0)
t "close help shows x only"     0 (string match -q '*, q*' -- "$hlp"; and echo 1; or echo 0)
t "setup has no alias (indented)" 1 (string match -rq '(?m)^ +setup <command>' -- "$hlp"; and echo 1; or echo 0)
t "clear has no alias (indented)" 1 (string match -rq '(?m)^ +clear ' -- "$hlp"; and echo 1; or echo 0)
t "help shows setup args"       1 (string match -rq 'setup <command> \[options\]' -- "$hlp"; and echo 1; or echo 0)
t "setup desc points to -h"     1 (string match -rq 'setup <command> \[options\].*setup -h' -- "$hlp"; and echo 1; or echo 0)
t "help lists setup subcmds"    1 (string match -q '*install · verify · teardown · keys · auto*' -- "$hlp"; and echo 1; or echo 0)
t "help drops start"            0 (string match -q '*start*' -- "$hlp"; and echo 1; or echo 0)
t "help drops fixssh"           0 (string match -q '*fixssh*' -- "$hlp"; and echo 1; or echo 0)
t "help drops top verify"       0 (string match -q '*verify, v*' -- "$hlp"; and echo 1; or echo 0)
# order: setup -> update -> session cluster (asserted via unique description text)
t "order setup before update"   1 (string match -rq '(?s)setup <command>.*update the plugin' -- "$hlp"; and echo 1; or echo 0)
t "order update before session" 1 (string match -rq '(?s)update the plugin.*create a new session' -- "$hlp"; and echo 1; or echo 0)
t "session workflow order"      1 (string match -rq '(?s)create a new session.*attach to a session.*open the session switcher.*repair the SSH.*re-categorize.*kill idle.*current session and exit' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"  1 (test "$hbox" = (tmux-lives -h | string collect); and echo 1; or echo 0)
# the user-facing help is framed in a rounded orange box titled "tmux-lives"
t "help framed: top corner"     1 (string match -q '*╭*' -- "$hbox"; and echo 1; or echo 0)
t "help framed: bottom corner"  1 (string match -q '*╰*' -- "$hbox"; and echo 1; or echo 0)
t "help framed: title in edge"  1 (string match -rq '╭─ tmux-lives ─' -- (vis "$hbox"); and echo 1; or echo 0)
t "help framed: orange border"  1 (string match -q '*38;5;208*' -- "$hbox"; and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown command returns 1" 1 $status
# routing: stub an IN-SCOPE helper (teardown is defined in this file) + confirm dispatch
functions -c __tmux_lives_teardown __tl_td_real
function __tmux_lives_teardown; set -g _tl_routed teardown; end
set -g _tl_routed ''
tmux-lives setup teardown
t "routes setup teardown -> helper" "teardown" "$_tl_routed"
functions -e __tmux_lives_teardown; functions -c __tl_td_real __tmux_lives_teardown
# command aliases route to the right action (picker/fix helpers live in
# conf.d/tmux.fish, not sourced here — define fresh stubs, so no backup/restore noise)
function __tmux_lives_picker; set -g _tl_a picker; end
function __tmux_lives_fix; set -g _tl_a fix; end
set -g _tl_a ''; tmux-lives p;      t "alias p -> picker"  picker "$_tl_a"
set -g _tl_a ''; tmux-lives picker; t "verb picker routes" picker "$_tl_a"
set -g _tl_a ''; tmux-lives f;      t "alias f -> fix"     fix "$_tl_a"
set -g _tl_a ''; tmux-lives fix;    t "verb fix routes"    fix "$_tl_a"
# categorize: re-run the categorizer (real __tmux_categorize lives in conf.d/tmux.fish, not sourced here — stub)
function __tmux_categorize; set -g _tl_a categorize; end
set -g _tl_a ''; tmux-lives categorize; t "verb categorize routes" categorize "$_tl_a"
set -g _tl_a ''; tmux-lives c;          t "alias c -> categorize"  categorize "$_tl_a"
functions -e __tmux_categorize
# hidden shortcut: setup subcommands also work at top level (NOT shown in help)
functions -c __tmux_lives_setup_dispatch __tl_sd_real
function __tmux_lives_setup_dispatch; set -g _tl_sd "$argv"; end
set -g _tl_sd ''; tmux-lives auto status; t "hidden: auto -> setup auto"      "auto status" "$_tl_sd"
set -g _tl_sd ''; tmux-lives verify;      t "hidden: verify -> setup verify"  "verify" "$_tl_sd"
set -g _tl_sd ''; tmux-lives v;           t "hidden: v -> setup verify"       "v" "$_tl_sd"
set -g _tl_sd ''; tmux-lives install;     t "hidden: install -> setup"        "install" "$_tl_sd"
set -g _tl_sd ''; tmux-lives i;           t "hidden: i -> setup install"      "i" "$_tl_sd"
set -g _tl_sd ''; tmux-lives teardown;    t "hidden: teardown -> setup"       "teardown" "$_tl_sd"
set -g _tl_sd ''; tmux-lives keys;        t "hidden: keys -> setup keys"      "keys" "$_tl_sd"
functions -e __tmux_lives_setup_dispatch; functions -c __tl_sd_real __tmux_lives_setup_dispatch
# update routes (real __tmux_lives_update is in this file — back it up around the stub)
functions -q __tmux_lives_update; and functions -c __tmux_lives_update __tl_upd_real
function __tmux_lives_update; set -g _tl_a update; end
set -g _tl_a ''; tmux-lives u;      t "alias u -> update"  update "$_tl_a"
set -g _tl_a ''; tmux-lives update; t "verb update routes" update "$_tl_a"
functions -e __tmux_lives_update; functions -q __tl_upd_real; and functions -c __tl_upd_real __tmux_lives_update
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
functions -e __tmux_lives_picker __tmux_lives_fix
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
t "setup help framed (box)"     1 (string match -q '*╭*' -- "$sh"; and echo 1; or echo 0)
t "setup help title in edge"    1 (string match -rq '╭─ tmux-lives setup ─' -- (vis "$sh"); and echo 1; or echo 0)
# tightened so the framed setup help fits an 80-col terminal (was up to 104 cols)
set -l sh_w 0
for l in (tmux-lives setup)
    set -l w (string length --visible (vis "$l"))
    test $w -gt $sh_w; and set sh_w $w
end
t "setup help fits 80 cols"     1 (test $sh_w -le 80; and echo 1; or echo 0)
tmux-lives setup bogus 2>/dev/null; t "setup unknown rc1" 1 $status
functions -e __tmux_lives_setup; functions -c __tl_setup_real __tmux_lives_setup
# keys persistence
set -e tmux_lives_prefix_key
functions -c __tmux_lives_write_fragment __tl_wf_bak 2>/dev/null
function __tmux_lives_write_fragment; end
tmux-lives setup keys -p C-a
t "setup keys -p persists" "C-a" "$tmux_lives_prefix_key"
set -e tmux_lives_prefix_key
# Keep __tmux_lives_write_fragment STUBBED through the post-update NOTE tests below: they
# call the REAL _tmux_lives_post_update, and the real write_fragment writes the LIVE
# ~/.config/tmux/tmux-lives.conf + reloads the user's running tmux server. The note/handler
# tests don't need a real render. Restored after the last _tmux_lives_post_update call.

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
# tmux-lives update — wraps `fisher update bit-saver/tmux-lives` and reports
# whether the installed files actually changed. fisher is ALWAYS stubbed.
# ---------------------------------------------------------------------
set -g _tld /tmp/tli-upd-$fish_pid
printf 'one\n' > $_tld
set -l d1 (__tmux_lives_digest $_tld)
printf 'two\n' >> $_tld
t "digest changes with content"        1 (test "$d1" != (__tmux_lives_digest $_tld); and echo 1; or echo 0)
# watch our temp file; no-op fisher -> nothing changed -> "already up to date"
set -g tmux_lives_update_files $_tld
# no-op fisher that PRINTS noise but changes nothing -> noise withheld, "up to date"
function fisher; set -g _tl_fish (string join ' ' $argv); echo "Fetching bit-saver/tmux-lives"; end
set -g _tl_fish ''
set -l u_same (__tmux_lives_update | string collect)
t "update calls fisher update <plugin>"      "update bit-saver/tmux-lives" "$_tl_fish"
t "update: up to date when unchanged"        1 (string match -q '*already up to date*' -- "$u_same"; and echo 1; or echo 0)
t "update: withholds noise when unchanged"   0 (string match -q '*Fetching*' -- "$u_same"; and echo 1; or echo 0)
# fisher that prints noise AND changes the file -> release the noise + "updated"
function fisher; echo "Fetching bit-saver/tmux-lives"; printf 'changed\n' >> $tmux_lives_update_files; end
set -l u_diff (__tmux_lives_update | string collect)
t "update: reports change"                   1 (string match -q '*updated*' -- "$u_diff"; and echo 1; or echo 0)
t "update: change hints exec fish"           1 (string match -q '*exec fish*' -- "$u_diff"; and echo 1; or echo 0)
t "update: releases fisher output on change" 1 (string match -q '*Fetching*' -- "$u_diff"; and echo 1; or echo 0)
# fisher failure -> surface its output (stderr) and propagate the exit code
function fisher; echo "fisher boom"; return 7; end
set -l u_err (__tmux_lives_update 2>&1 | string collect)
t "update: surfaces output on failure"       1 (string match -q '*fisher boom*' -- "$u_err"; and echo 1; or echo 0)
__tmux_lives_update >/dev/null 2>&1
t "update: propagates fisher exit code"      7 $status
functions -e fisher
set -e tmux_lives_update_files
rm -f $_tld
# the generic post-update note is silenced while `tmux-lives update` reports for itself
set -g _tmux_lives_updating 1
t "post-update note silent under flag"  "" (_tmux_lives_post_update | string collect)
set -e _tmux_lives_updating
# Restore the real write_fragment now that the post-update note tests are done.
functions -q __tl_wf_bak; and begin; functions -e __tmux_lives_write_fragment; functions -c __tl_wf_bak __tmux_lives_write_fragment; end

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
