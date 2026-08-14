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
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1] => got [$argv[3]]"; end; end

# Start a private, config-free server; optionally source $conf into it; attach a real pty
# client; report whether tmux granted that client the Sync capability. Capabilities are
# resolved at ATTACH and never revisited, so the config MUST be sourced before attaching —
# getting that order wrong silently measures nothing. Polls for the client rather than
# sleeping a fixed interval.
function __tls_client_sync --argument-names sock conf
    command tmux -L $sock -f /dev/null new-session -d 'sleep 20' 2>/dev/null
    test -n "$conf"; and command tmux -L $sock source-file $conf 2>/dev/null
    env TERM=xterm-256color script -qec "tmux -L $sock attach" /dev/null >/dev/null 2>&1 &
    set -l n 0
    while test $n -lt 25; and test (command tmux -L $sock list-clients 2>/dev/null | count) -eq 0
        sleep 0.2
        set n (math $n + 1)
    end
    set -l line (command tmux -L $sock info 2>/dev/null | string match -r '.*Sync:.*')
    command tmux -L $sock kill-server 2>/dev/null
    if test -z "$line[1]"
        echo unknown
    else if string match -q '*missing*' -- "$line[1]"
        echo missing
    else
        echo present
    end
end

set -l frag (__tmux_lives_render_fragment /X/cat.fish S M-s | string collect)
t "fragment has categorizer path" 1 (string match -q '*/X/cat.fish*' -- "$frag"; and echo 1; or echo 0)
t "fragment has update-environment" 1 (string match -q '*update-environment*LC_TERMINAL*' -- "$frag"; and echo 1; or echo 0)
t "fragment has commandeer hook" 1 (string match -q '*client-session-changed*' -- "$frag"; and echo 1; or echo 0)
t "fragment has resurrect plugin" 1 (string match -q '*tmux-plugins/tmux-resurrect*' -- "$frag"; and echo 1; or echo 0)
t "fragment status-interval" 1 (string match -q '*status-interval 15*' -- "$frag"; and echo 1; or echo 0)
# Ported from tmux-sensible, which the user is dropping. It loads via TPM AFTER our
# fragment, so it silently won every conflict (it was overriding our status-interval 15
# with its own 5). Only these two are worth keeping; the rest of sensible was either
# already set by the user's own config or is being let go deliberately.
# escape-time is a SERVER option (-s), not a session option — -g would be wrong.
t "fragment sets escape-time 0 on the server" 1 (string match -q '*set -s escape-time 0*' -- "$frag"; and echo 1; or echo 0)
t "fragment sets focus-events on"             1 (string match -q '*set -g focus-events on*' -- "$frag"; and echo 1; or echo 0)
t "fragment sets display-time 4000"           1 (string match -q '*set -g display-time 4000*' -- "$frag"; and echo 1; or echo 0)
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

# --- fragment is re-sourced on EVERY reload: it must not accumulate, and it must
# --- not evict interpolations it did not author -------------------------------
# `set -ga update-environment` appends unconditionally, so a bare append grows without
# bound — 54 copies of each name observed on a host with ~18 days of uptime. And a bare
# `set -g status-right` DISCARDS whatever is there; tmux-continuum schedules its autosave
# by prepending #(continuum_save.sh) and the bar's refresh IS its scheduler, so evicting
# it stops session snapshots permanently and silently (observed: 52h, ten live sessions).
# Sourced on a private -f /dev/null socket, with the tpm run-line stripped so the test
# does not drag the real plugin set into the test server.
set -l uesock tli-ue-$fish_pid
set -l uefile /tmp/tli-ue-$fish_pid.conf
# Point the baseline/state seams at paths that do not exist, so the rendered fragment's
# `if-shell [ -f … ] source-file` lines are no-ops. Without this the test server sources
# the DEVELOPER's live ~/.tmux-lives.conf and state file, making these assertions depend
# on their machine's config.
set -g tmux_lives_baseline_conf /nonexistent/tli-baseline-$fish_pid.conf
set -g tmux_lives_state_file /nonexistent/tli-state-$fish_pid.conf
__tmux_lives_render_fragment $plugindir/functions/tmux-categorize.fish S M-s '#1f6feb' \
    | string match -v -- '*tpm/tpm*' > $uefile
set -e tmux_lives_baseline_conf
set -e tmux_lives_state_file
command tmux -L $uesock -f /dev/null new-session -d 2>/dev/null
# a plugin got there first
command tmux -L $uesock set -g status-right '#(FOREIGN_HOOK)' 2>/dev/null
for _i in 1 2 3
    command tmux -L $uesock source-file $uefile 2>/dev/null
end
set -l ue (command tmux -L $uesock show -gv update-environment 2>/dev/null | string split ' ')
t "update-environment: exactly one LC_TERMINAL after 3 sources"         1 (count (string match -r '^LC_TERMINAL$' -- $ue))
t "update-environment: exactly one LC_TERMINAL_VERSION after 3 sources" 1 (count (string match -r '^LC_TERMINAL_VERSION$' -- $ue))
set -l sr (command tmux -L $uesock show -gv status-right 2>/dev/null)
t "status-right: a foreign hook survives the fragment"  1 (string match -q '*FOREIGN_HOOK*' -- "$sr"; and echo 1; or echo 0)
t "status-right: our own part is installed"             1 (string match -q '*@tmux_lives_status_right*' -- "$sr"; and echo 1; or echo 0)
# Pin marker->tick ADJACENCY in one pattern (the assignment this replaced pinned it, and
# two independent substring checks would not), and pin that a NON-EMPTY baked colour
# actually reaches the installed tick — the fragment-text assertion alone can't show that.
t "status-right: the clock @var is adjacent to the tick" 1 (string match -q "*#{T:@tmux_lives_status_right}#(fish --no-config *tick '#1f6feb')*" -- "$sr"; and echo 1; or echo 0)
t "status-right: our part appears exactly once"         1 (count (string match -ra '@tmux_lives_status_right' -- "$sr"))
t "status-right: the foreign hook appears exactly once" 1 (count (string match -ra 'FOREIGN_HOOK' -- "$sr"))
command tmux -L $uesock kill-server 2>/dev/null; rm -f $uefile
# And the fragment must no longer carry either unconditional form. Anchor at the START
# of a LINE and keep the render as a LIST (no `string collect`): the guarded append
# legitimately contains `set -ga update-environment` as if-shell's then-command, so a
# bare substring ban would fire on the fix itself. The two positive assertions below
# are what stop all four passing vacuously if the render ever returns nothing.
set -l uelines (__tmux_lives_render_fragment /X/cat.fish S M-s)
t "fragment: no UNGUARDED update-environment append" 0 (count (string match -r '^set -ga update-environment' -- $uelines))
t "fragment: no UNGUARDED status-right assignment"   0 (count (string match -r '^set -g status-right ' -- $uelines))
t "fragment: update-environment appends are guarded" 2 (count (string match -r '^if-shell .*grep -qx LC_TERMINAL.*set -ga update-environment' -- $uelines))
t "fragment: status-right is installed via the verb" 1 (count (string match -r '^run-shell .*status-right-install' -- $uelines))

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
t "fragment still installs status-right (now via the verb)" yes (string match -q '*status-right-install*' -- "$BAR"; and echo yes; or echo no)
# v3.3: claude windows render like any other window (coloring removed 2026-07-21)
t "fragment window-status-format is plain" yes (string match -q "*set -g window-status-format '#W'*" -- "$BAR"; and echo yes; or echo no)
t "fragment sets window-status-separator bullet" yes (string match -q '*window-status-separator*•*' -- "$BAR"; and echo yes; or echo no)
t "fragment drops @tmux_lives_claude_color" no (string match -q '*claude_color*' -- "$BAR"; and echo yes; or echo no)
t "fragment seeds @tmux_lives_heal_interval" yes (string match -q '*set -g @tmux_lives_heal_interval 120*' -- "$BAR"; and echo yes; or echo no)
t "fragment current-format keeps bold + active role, no claude tint" yes (string match -q "*set -g window-status-current-format '#[bold]#[fg=#{@tmux_lives_active_fg}]#W#[fg=default]#[nobold]'*" -- "$BAR"; and echo yes; or echo no)
# picker-legibility-autoapply Task 6: active was computed by the engine and
# pushed to @tmux_lives_active_fg on every apply, but no format string read
# it — it rendered nowhere in any session. Pointing the current-window
# format at it (instead of text_fg) gives it a consumer.
#
# NB the brief's own draft of this coverage ("current window wears the
# active role" yes, a bare '*@tmux_lives_active_fg*' substring match against
# $FRAG) is VACUOUS — proven pre-implementation: @tmux_lives_active_fg is
# already seeded unconditionally by every fragment render (the role @option
# assignment a few lines above window-status-current-format), so the
# substring is present whether or not anything reads it, both before and
# after this fix. The test above already covers "current window wears the
# active role" precisely (the byte-exact current-format string), so the
# vacuous duplicate is dropped rather than kept alongside it.
t "fragment seeds host-kind + glyph + accent @options" yes (string match -q '*@tmux_lives_host_kind*' -- "$BAR"; and string match -q '*@tmux_lives_glyph_remote*' -- "$BAR"; and string match -q '*@tmux_lives_prefix_color*' -- "$BAR"; and echo yes; or echo no)
# cap bg is now a flat legacy neutral (theme off / no usable seed) — the v2 palette-accent
# cap wiring (argv[12..16] cap/vividness/wheel/role) is gone; only bar_bg/status-style remain.
t "fragment cap bg is the legacy neutral (quoted)" yes (string match -q "*@tmux_lives_cap_bg 'colour238'*" -- "$BAR"; and echo yes; or echo no)
t "fragment seeds @tmux_lives_bar_bg (= bar bg, for the slant transition)" yes (string match -q "*@tmux_lives_bar_bg '#5793f0'*" -- "$BAR"; and echo yes; or echo no)
t "fragment still sets status-style (shellfish color)" yes (string match -q '*set -g status-style*' -- "$BAR"; and echo yes; or echo no)
# cursor-style (arg 11): a steady style fixes the ShellFish cursor flicker; '' leaves tmux alone
set -g FRAGCUR (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block | string collect)
t "fragment seeds cursor-style when set" yes (string match -q '*set -g cursor-style block*' -- "$FRAGCUR"; and echo yes; or echo no)
set -g FRAGNOCUR (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s '' | string collect)
t "fragment omits cursor-style when unset" yes (string match -q '*cursor-style*' -- "$FRAGNOCUR"; and echo no; or echo yes)

# --- sync terminal-feature (arg 21) ------------------------------------------------
# tmux decides PER CLIENT, at attach, whether a terminal can buffer synchronized output,
# and it decides from its own terminal identification — it never asks the client. It
# recognises Ghostty but not ShellFish, so it wrote every Claude frame unwrapped and
# ShellFish painted ~21 cursor hide/show pairs a second (the 2026-08-06 strobing).
# Telling tmux the terminal can sync is the fix. GATED to tmux >= 3.7: only there does
# the capability map to DECSET 2026 (3.3a emits the older iTerm2 DCS form), and only
# there can the bug occur — 3.3a never answers the DECRQM query, so Claude never turns
# sync on. See [[shellfish-cursor-flicker]].
set -g SYNCBASE /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono bar derived 0
set -g FRAGSYNC (__tmux_lives_render_fragment $SYNCBASE 'xterm*' | string collect)
set -g FRAGNOSYNC (__tmux_lives_render_fragment $SYNCBASE '' | string collect)
t "fragment emits the sync terminal-feature when set" yes (string match -q "*set -as terminal-features 'xterm*:sync'*" -- "$FRAGSYNC"; and echo yes; or echo no)
t "fragment gates the sync feature behind a tmux version check" yes (string match -q '*if-shell*sort -V*terminal-features*' -- "$FRAGSYNC"; and echo yes; or echo no)
t "fragment omits the sync feature when unset" yes (string match -q '*:sync*' -- "$FRAGNOSYNC"; and echo no; or echo yes)

# The version gate must ENABLE at >=3.7 and SKIP below it. A silently-wrong gate would
# disable the fix with no visible symptom, which is precisely how this bug hid before —
# so drive the REAL probe extracted from the fragment against stubbed `tmux -V` output.
set -g SYNCGATE (string match -r "if-shell '([^']*)' \"set -as terminal-features" -- "$FRAGSYNC")
t "sync gate probe is extractable from the fragment" yes (test (count $SYNCGATE) -ge 2; and test -n "$SYNCGATE[2]"; and echo yes; or echo no)
set -g gatedir /tmp/tli-gate-$fish_pid
mkdir -p $gatedir
for ver in 3.3a 3.6a 3.7 3.7b 3.10 4.0
    printf '#!/bin/sh\necho "tmux %s"\n' $ver > $gatedir/tmux
    chmod +x $gatedir/tmux
    set -l want skip
    contains -- $ver 3.7 3.7b 3.10 4.0; and set want enable
    t "sync gate on tmux $ver" $want (env PATH="$gatedir:$PATH" sh -c "$SYNCGATE[2]" >/dev/null 2>&1; and echo enable; or echo skip)
end
rm -rf $gatedir

# DIRECT proof the emitted command actually grants the capability. A string match alone
# is not enough: tmux stores an unknown feature name silently (verified — a deliberately
# bogus `xterm*:notafeature` is accepted without error), so a typo would pass a grep and
# ship a dead fix. Source the real emitted command onto a private server, attach a pty
# client, and read the capability back — with a control proving the assertion can fail.
if command -q script
    set -g SYNCCMD (string match -r 'set -as terminal-features [^"]*' -- "$FRAGSYNC")
    set -g syncconf /tmp/tli-sync-$fish_pid.conf
    printf '%s\n' "$SYNCCMD[1]" > $syncconf
    t "attached client has no Sync capability by default (control)" missing (__tls_client_sync tli-sync0-$fish_pid '')
    t "the emitted command grants an attached client the Sync capability" present (__tls_client_sync tli-sync1-$fish_pid $syncconf)
    rm -f $syncconf
else
    echo "SKIP: util-linux `script` unavailable — sync capability behaviour untested"
end

# The sync line nests single quotes inside double quotes inside a tmux command, and the
# shell probe carries $(...) and its own double quotes. A `source-file rc0` check CANNOT
# police that: tmux returns 0 and writes NOTHING to stderr for a malformed line (verified
# against a deliberately broken variant). So assert the EFFECT instead — source the real
# emitted line with only the version predicate swapped for `true`, and read the option
# back. This host is 3.3a, where the real gate is false, hence the swap.
set -g syncfrag /tmp/tli-syncfrag-$fish_pid.conf
set -g syncsock tli-syncparse-$fish_pid
set -g SYNCLINE (string match -r "if-shell '[^']*' .*terminal-features.*" -- "$FRAGSYNC")
printf '%s\n' (string replace -r "if-shell '[^']*'" "if-shell 'true'" -- "$SYNCLINE[1]") > $syncfrag
command tmux -L $syncsock -f /dev/null new-session -d 2>/dev/null
command tmux -L $syncsock source-file $syncfrag 2>/dev/null
t "emitted sync line, gate forced true, really sets the feature" yes (command tmux -L $syncsock show -gv terminal-features | string match -q '*:sync*'; and echo yes; or echo no)
command tmux -L $syncsock kill-server 2>/dev/null; rm -f $syncfrag

# --- Task 1: knobs removed, sync arg renumbered 21 -> 17 -------------------------
# The four knobs are gone, so syncterm is positional 17. Pre-change, position 17 is
# themeviv and syncterm is empty, so NO sync line is emitted — that is the failure
# this pins. A silently-disabled sync feature has no rc and no visible symptom.
set -g FRAG17 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono bar derived 0 'xterm*' | string collect)
t "sync is positional 17 after the knobs are removed" yes (string match -q "*set -as terminal-features 'xterm*:sync'*" -- "$FRAG17"; and echo yes; or echo no)

# --- picker-seed-section Task 1: the picker opens at a percentage height, not a fixed 26 ----------
# A popup taller than the client FAILS to open on tmux 3.3a ("height too large") —
# it does not clamp. So the height must be a percentage, which always fits.
set -g FRAGH (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono bar derived 0 'xterm*' | string collect)
t "theme-picker bind uses a percentage height" yes (string match -q '*-w 52 -h 85%*' -- "$FRAGH"; and echo yes; or echo no)
t "theme-picker bind no longer pins 26 rows" no (string match -q '*-w 52 -h 26*' -- "$FRAGH"; and echo yes; or echo no)

# The engine must produce the SAME colours as before — this is a refactor, not a
# derivation change. Pinned as literal hexes so it cannot drift silently.
set -g P5 (__tmux_lives_theme_palette '#5f772b' amber bar derived 0)
t "palette still returns 7 roles from 5 args" 7 (count $P5)
t "palette bar unchanged by the refactor" '#44502f' $P5[1]

# apply_live's explicit form is now exactly 4 args.
t "apply_live explicit form documents 4 args" yes (string match -q '*4 args*' -- (functions __tmux_lives_theme_apply_live | string collect); and echo yes; or echo no)

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
# the legacy neutral cap bg must SURVIVE the source (quoted, so it isn't eaten as a comment).
t "real: cap bg option stored (legacy neutral)" colour238 (command tmux -L $brsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "real: status-format[0] stored non-empty" 1 (test -n (command tmux -L $brsock show -gv status-format[0] 2>/dev/null); and echo 1; or echo 0)
command tmux -L $brsock kill-server 2>/dev/null; rm -f /tmp/tli-barrfrag-$fish_pid.conf
# baseline no longer owns the layout (fragment's status-format[0] does)
set -g BT (__tmux_lives_baseline_template | string collect)
t "baseline no longer sets status-left" yes (string match -q '*set -g status-left *' -- "$BT"; and echo no; or echo yes)
t "baseline no longer sets window-status-format" yes (string match -q '*window-status-format*' -- "$BT"; and echo no; or echo yes)
t "baseline still sets the clock @var" yes (string match -q '*@tmux_lives_status_right*' -- "$BT"; and echo yes; or echo no)
t "baseline keeps status-right-length (referenced by the new right zone)" yes (string match -q '*status-right-length*' -- "$BT"; and echo yes; or echo no)
t "baseline clock is date-first (date then time)" yes (string match -q '*@tmux_lives_status_right "%b %-d · %-I:%M %p*' -- "$BT"; and echo yes; or echo no)
# derive helper: just the bg hex of the derived status-style
t "derive_status_bg: lighter #1f6feb" "#5793f0" (__tmux_lives_derive_status_bg "#1f6feb" 0)
t "derive_status_bg: darker #1f6feb"  "#1753b0" (__tmux_lives_derive_status_bg "#1f6feb" 1)
t "derive_status_bg: named -> empty"  ""        (__tmux_lives_derive_status_bg "red" 0)
# OKLCH conversion core (validated reference values; lock fish output if ±1)
set -g OK (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 "#ff0000"))
t "oklch #ff0000 L" "0.627955" $OK[1]
t "oklch #ff0000 C" "0.257684" $OK[2]
t "oklch #ff0000 H" "29.233916" $OK[3]
t "oklch_hex round-trips #ff0000" "#ff0000" (__tmux_lives_oklch_hex $OK[1] $OK[2] $OK[3])
t "oklch_hex round-trips #36442d" "#36442d" (__tmux_lives_oklch_hex 0.367244 0.042157 133.601539)
# gamut clamp never exceeds target, stays in range
t "gamut_chroma caps at target" 1 (set -l c (__tmux_lives_gamut_chroma 0.62 30 0.19); test (math -s5 "min($c,0.19)") = (math -s5 "$c"); and echo 1; or echo 0)
# WCAG contrast fg (new OKLCH-era helper; crossover 0.179 relative luminance)
t "contrast_fg dark cap -> light" "#f5f5f5" (__tmux_lives_contrast_fg "#36442d")
t "contrast_fg vivid mid -> dark" "#111111" (__tmux_lives_contrast_fg "#f66336")
t "contrast_fg near-white -> dark" "#111111" (__tmux_lives_contrast_fg "#e0e0e0")

t "contrast_fg dark cap -> light" "#f5f5f5" (__tmux_lives_contrast_fg "#755789")
t "contrast_fg light cap -> dark" "#111111" (__tmux_lives_contrast_fg "#e0e0e0")

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

# dedicated M-k theme-picker keybind (argv[12] = theme_key)
set -g CK (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block M-k | string collect)
t "fragment binds the theme-picker key" yes (string match -q "*bind-key -n M-k display-popup -B -E -w 52 -h 85% -- fish --no-config*theme-picker*" -- "$CK"; and echo yes; or echo no)
set -g CK0 (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block '' | string collect)
t "empty theme-key omits the bind" 1 (string match -q '*theme-picker*' -- "$CK0"; and echo 0; or echo 1)

set -e tmux_lives_theme_key
functions -c __tmux_lives_write_fragment __wftk_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --theme-key M-j
t "keys --theme-key persists" M-j "$tmux_lives_theme_key"
t "keys rejects the retired --cap-key" 1 (__tmux_lives_keys_cmd --cap-key M-k 2>/dev/null; echo $status)
functions -e __tmux_lives_write_fragment; functions -c __wftk_bak __tmux_lives_write_fragment; functions -e __wftk_bak
set -e tmux_lives_theme_key

t "setup help documents --theme-key" yes (string match -q '*--theme-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)

t "setup help: theme row says picker" yes (string match -q '*theme*no-arg=picker*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "setup help: every theme flag listed" yes (begin; set -l h (__tmux_lives_setup_help_lines | string collect); string match -q '*--place*bar|tabs|cap*' -- $h; and string match -q '*--mode*literal|derived*' -- $h; and string match -q '*--phase <deg>*' -- $h; end; and echo yes; or echo no)
t "setup help: --rotate retired from theme row" no (string match -q '*--rotate*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "setup help: the four inert theme knobs are gone" no (string match -qr -- '--(vividness|shape|ease|contrast)' (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "setup help fits the 80-col frame" 0 (count (__tmux_lives_setup_help_lines | string match -re '.{77,}'))

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
# status-right is no longer ASSIGNED here — it is installed by the categorizer verb so a
# foreign #() hook (tmux-continuum's autosave) survives a re-source. That the installed
# value really does carry T:@var AND the tick is asserted end-to-end on a live socket
# above, which is a stronger check than the string match this replaces.
t "fragment delegates status-right to the verb" 1 (string match -q '*run-shell*status-right-install*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment drops old -ga status-right" 0 (string match -q '*set -ga status-right*' -- "$fragsr"; and echo 1; or echo 0)
set -g FRAGT (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 | string collect)
t "install call bakes the bar color" yes (string match -q "*status-right-install '#1f6feb'*" -- "$FRAGT"; and echo yes; or echo no)
set -g FRAGT0 (__tmux_lives_render_fragment /x/cat.fish S M-s "" 0 | string collect)
t "install call empty color when unset" yes (string match -q "*status-right-install ''*" -- "$FRAGT0"; and echo yes; or echo no)
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
t "color show: seed wording when unset" "seed: (none)" (__tmux_lives_color_cmd)
set -l _setmsg (__tmux_lives_color_cmd "#ff8800")
t "color: stored in universal var" "#ff8800" "$tmux_lives_bar_color"
t "color: baked into fragment" 1 (string match -q '*#ff8800*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
t "color: set message says seed" "tmux-lives: seed set to #ff8800 (drives the theme + ShellFish tabs; status bar lighter)" "$_setmsg"
set -l _clearmsg (__tmux_lives_color_cmd "")
t "color: cleared to empty" "" "$tmux_lives_bar_color"
t "color: cleared message says seed" "tmux-lives: seed cleared" "$_clearmsg"
__tmux_lives_color_cmd "#1f6feb" -i >/dev/null
t "color -i: invert var = 1"     "1" "$tmux_lives_status_invert"
t "color -i: fragment darker"    1 (string match -q '*status-style bg=#1753b0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
__tmux_lives_color_cmd "#1f6feb" >/dev/null
t "color no -i: invert var = 0"  "0" "$tmux_lives_status_invert"
t "color: fragment lighter"      1 (string match -q '*status-style bg=#5793f0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
t "color show: reports lighter"  1 (string match -q '*status bar: lighter*' -- (__tmux_lives_color_cmd | string collect); and echo 1; or echo 0)
t "color show: seed label with value" "seed: #1f6feb (status bar: lighter)" (__tmux_lives_color_cmd)
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
# tmux_lives_theme is always-on (Task 1): a live value on the dev box (e.g. a scheme the
# user actually configured) would route --apply through __tmux_lives_theme_apply_live
# instead of the plain v2 derive this block tests -> clear/restore like its siblings.
set -l _ath_had 0; set -l _ath_val
if set -q tmux_lives_theme; set _ath_had 1; set _ath_val $tmux_lives_theme; end
set -U tmux_lives_theme off
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
t "color --apply with no color: rc1" 1 (__tmux_lives_color_cmd --apply >/dev/null 2>&1; echo $status)
set -U tmux_lives_bar_color "#1f6feb"; set -U tmux_lives_status_invert 0
set -l _applymsg (__tmux_lives_color_cmd --apply)
t "color --apply sets derived status-style live" 1 (string match -q '*bg=#5793f0*' -- (command tmux -L $apsock show -gv status-style); and echo 1; or echo 0)
t "color --apply message says reapplied seed" "tmux-lives: reapplied seed #1f6feb" "$_applymsg"
t "color -a rejects an extra color arg (rc1)" 1 (__tmux_lives_color_cmd -a "#abc" >/dev/null 2>&1; echo $status)
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert; set -e tmux_lives_theme
if test $_abc_had -eq 1; set -U tmux_lives_bar_color $_abc_val; end
if test $_asi_had -eq 1; set -U tmux_lives_status_invert $_asi_val; end
if test $_ath_had -eq 1; set -U tmux_lives_theme $_ath_val; end
set -g __fish_config_dir $__old_fcd2; set -e __old_fcd2
set -e tmux_lives_tmux_socket
command tmux -L $apsock kill-server 2>/dev/null

# help + verify mention color
t "setup help lists color" 1 (string match -q '*color*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "setup help documents color --apply/-a" 1 (string match -q '*-a*reapply*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
# verify's color lines read the LIVE universals — pin them so the asserts are
# machine-independent (found 2026-07-16: an aborted earlier run had leaked a cleared
# bar_color, and these two tests were the only ones that noticed).
set -g _vfy_names tmux_lives_bar_color tmux_lives_status_invert
set -g _vfy_had
set -g _vfy_saved
for n in $_vfy_names
    if set -q $n
        set -a _vfy_had 1
        set -a _vfy_saved "$$n"
    else
        set -a _vfy_had 0
        set -a _vfy_saved ""
    end
    set -e $n
end
set -U tmux_lives_bar_color '#5793f0'
set -U tmux_lives_status_invert 0
t "verify reports bar color" 1 (string match -q '*bar color*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
t "verify reports status direction" 1 (string match -q '*status bar:*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
for i in (seq (count $_vfy_names))
    set -e $_vfy_names[$i]
    test $_vfy_had[$i] -eq 1; and set -U $_vfy_names[$i] $_vfy_saved[$i]
end
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

# theme_arc/barpos/kincap/kintabs/roles/sample/ring + their v3.1/v3.2/v3.3 unit
# tests (bar/palette-recipe internals) retired with the v3 gradient-map engine —
# see __tmux_lives_theme_curve/_accents (v4) and their tests below.

# Task 2: seed parsing (css -> #rrggbb; named colors have no derivable hue -> empty)
t "seed_hex passthrough" "#485b3c" (__tmux_lives_seed_hex "#485b3c")
t "seed_hex lowercases"  "#485b3c" (__tmux_lives_seed_hex "#485B3C")
t "seed_hex short hex"   "#4488cc" (__tmux_lives_seed_hex "#48c")
t "seed_hex rgb()"       "#1f6feb" (__tmux_lives_seed_hex "rgb(31, 111, 235)")
t "seed_hex named -> empty" 0 (count (__tmux_lives_seed_hex red))
t "seed_hex empty -> empty" 0 (count (__tmux_lives_seed_hex ""))
t "derive_status still parses rgb() after the refactor" 1 (string match -q 'bg=#*' -- (__tmux_lives_derive_status "rgb(31,111,235)" 0); and echo 1; or echo 0)
t "derive_status unchanged on hex" "bg=#76846d,fg=#d3d8d0" (__tmux_lives_derive_status "#485b3c" 0)
# --- theme engine v3: fragment renders the gradient-map roles ----------------
# theme OFF (argv 17 absent): v2 values + neutral role seeds
set -g TOFF (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k | string collect)
t "off: v2 status-style survives" yes (string match -q '*set -g status-style bg=#*' -- "$TOFF"; and echo yes; or echo no)
t "off: sep_fg seeded default"  yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: text_fg seeded default" yes (string match -q '*set -g @tmux_lives_text_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: mark_fg seeded default" yes (string match -q '*set -g @tmux_lives_mark_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: active_fg seeded default" yes (string match -q '*set -g @tmux_lives_active_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: cap is the legacy neutral (v2 engine gone)" yes (string match -q "*set -g @tmux_lives_cap_bg 'colour238'*" -- "$TOFF"; and echo yes; or echo no)
# theme ON: every role @option carries its gradient sample
set -g TON (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k ember bar derived '' | string collect)
set -g TONPAL (__tmux_lives_theme_palette "#485b3c" ember bar derived 0)
t "on: status-style = bar+windows samples" yes (string match -q "*set -g status-style bg=$TONPAL[1],fg=$TONPAL[5]*" -- "$TON"; and echo yes; or echo no)
t "on: bar_bg is the bar sample (quoted)" yes (string match -q "*set -g @tmux_lives_bar_bg '$TONPAL[1]'*" -- "$TON"; and echo yes; or echo no)
t "on: sep_fg role"   yes (string match -q "*set -g @tmux_lives_sep_fg '$TONPAL[2]'*" -- "$TON"; and echo yes; or echo no)
t "on: tabs_color emitted (Phase-2 consumer)" yes (string match -q "*set -g @tmux_lives_tabs_color '$TONPAL[3]'*" -- "$TON"; and echo yes; or echo no)
t "on: active_fg emitted (paints the current window)" yes (string match -q "*set -g @tmux_lives_active_fg '$TONPAL[4]'*" -- "$TON"; and echo yes; or echo no)
t "on: cap_bg is the cap sample" yes (string match -q "*set -g @tmux_lives_cap_bg '$TONPAL[6]'*" -- "$TON"; and echo yes; or echo no)
t "on: cap_fg stays readable" yes (string match -q "*set -g @tmux_lives_cap_fg '"(__tmux_lives_contrast_fg $TONPAL[6])"'*" -- "$TON"; and echo yes; or echo no)
# v3.3: the ✦ mark is the seed's home base, not the cap sample
t "on: mark_fg is the seed verbatim" yes (string match -q "*set -g @tmux_lives_mark_fg '#485b3c'*" -- "$TON"; and echo yes; or echo no)
t "on: text_fg role" yes (string match -q "*set -g @tmux_lives_text_fg '$TONPAL[7]'*" -- "$TON"; and echo yes; or echo no)
t "on: no claude_color anywhere" no (string match -q '*claude_color*' -- "$TON"; and echo yes; or echo no)
# the four knobs are gone; phase is argv 16 (place/mode are argv 14-15) and is the
# one remaining value that moves the curve.
set -g TONK (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k ember bar derived 90 | string collect)
set -g TONKPAL (__tmux_lives_theme_palette "#485b3c" ember bar derived 90)
t "on: phase reaches the palette" yes (string match -q "*set -g @tmux_lives_cap_bg '$TONKPAL[6]'*" -- "$TONK"; and echo yes; or echo no)
# a theme with an unusable seed falls back to the whole v2 path
set -g TBAD (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k ember | string collect)
t "on+no seed: v2 fallback cap" yes (string match -q "*set -g @tmux_lives_cap_bg 'colour238'*" -- "$TBAD"; and echo yes; or echo no)
t "on+no seed: role seeds default" yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TBAD"; and echo yes; or echo no)
# 'off' token renders the legacy branch; write_fragment's default is mono
set -g TOFFTOK (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k off | string collect)
t "off token renders legacy status-style" yes (string match -q '*set -g status-style bg=#*' -- "$TOFFTOK"; and string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TOFFTOK"; and echo yes; or echo no)
t "off token renders legacy cap" yes (string match -q "*set -g @tmux_lives_cap_bg '*" -- "$TOFFTOK"; and echo yes; or echo no)
t "write_fragment defaults the theme to mono" yes (string match -q '*tmux_lives_theme mono*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_key" yes (string match -q '*tmux_lives_theme_key M-k*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_place" yes (string match -q '*tmux_lives_theme_place bar*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_mode" yes (string match -q '*tmux_lives_theme_mode derived*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment has no rotate arg leakage" no (string match -q '*theme_rotate*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)

# --- write_fragment's call-site ARGUMENT ORDER must match render_fragment's
# positional reads. The existence-only checks just above (943-947) only prove each
# lookup is PRESENT somewhere in the source — they cannot see a shift. Proven by
# mutation: re-inserting a single extra (__tmux_lives_key ...) lookup ahead of the
# tmux_lives_sync_terminals one shifts syncterm from position 17 to 18; the
# fragment then emits `set -as terminal-features 'auto:sync'` (a glob matching no
# real TERM), and tmux accepts an unknown terminal-feature name with NO error and
# NO exit code — synchronized output silently dies, no symptom until a user's
# cursor starts strobing.
#
# HAZARD: the REAL __tmux_lives_write_fragment writes to the LIVE
# $HOME/.config/tmux/tmux-lives.conf, rewires the live ~/.tmux.conf, and (via
# __tmux_lives_reload) talks to whatever tmux server sits on the default socket —
# none of which this suite's XDG_CONFIG_HOME isolation touches. So the real
# function is never invoked here. Instead the exact render_fragment call-site LINE
# is extracted from the function's own live source text and eval'd in isolation
# under stubs, with disposable local $cat/$fragment — proving the real call
# site's argument order without any of the writer's side effects.
set -g wf17src (functions __tmux_lives_write_fragment)
set -g wf17line
for _wf17_l in $wf17src
    string match -q -- '*__tmux_lives_render_fragment $cat*> $fragment*' -- $_wf17_l
    and set -a wf17line $_wf17_l
end
set -e _wf17_l
t "write_fragment's render_fragment call site is extractable" 1 (count $wf17line)

functions -c __tmux_lives_render_fragment __wf17_rf_bak
functions -c __tmux_lives_key __wf17_key_bak
function __tmux_lives_render_fragment
    set -g _WF17_ARGV $argv
end
function __tmux_lives_key
    echo $argv[1]
end
set -l cat /nonexistent-wf17-cat
set -l fragment /tmp/tli-wf17-$fish_pid.conf
set -g _WF17_ARGV
eval $wf17line
functions -e __tmux_lives_render_fragment; functions -c __wf17_rf_bak __tmux_lives_render_fragment; functions -e __wf17_rf_bak
functions -e __tmux_lives_key; functions -c __wf17_key_bak __tmux_lives_key; functions -e __wf17_key_bak
rm -f $fragment
set -e wf17src; set -e wf17line

t "write_fragment's call site passes exactly 17 args to render_fragment" 17 (count $_WF17_ARGV)
t "write_fragment's call site: arg 17 is tmux_lives_sync_terminals" tmux_lives_sync_terminals "$_WF17_ARGV[17]"
set -e _WF17_ARGV

# themed fragment parses on a real -L server and the options land
set -g thfsock tli-th-$fish_pid
command tmux -L $thfsock new-session -d 2>/dev/null
printf '%s\n' "$TON" | string replace -a '/x/cat.fish' '/tmp/nope.fish' > /tmp/tli-thfrag-$fish_pid.conf
t "themed fragment parses (source-file rc0)" 0 (command tmux -L $thfsock source-file /tmp/tli-thfrag-$fish_pid.conf 2>/dev/null; echo $status)
t "themed @text_fg lands" "$TONPAL[7]" (command tmux -L $thfsock show -gv @tmux_lives_text_fg 2>/dev/null)
t "themed status-style lands" "bg=$TONPAL[1],fg=$TONPAL[5]" (command tmux -L $thfsock show -gv status-style 2>/dev/null)
command tmux -L $thfsock kill-server 2>/dev/null; rm -f /tmp/tli-thfrag-$fish_pid.conf

# --- theme engine v3: CLI + live apply ---------------------------------------
# Save/clear EVERY universal this section touches at the TOP (the cap_role lesson:
# the CLI reads them on every apply — a user's live value would skew earlier asserts).
# NB also includes the old v2 cap universals (tmux_lives_cap/_wheel/_vividness/_role):
# the v2 engine itself is gone (task 2), but these names are left in the save/restore
# list defensively — harmless if untouched, and cheap insurance against a future
# regression that starts reading them again.
set -g _th_names tmux_lives_theme tmux_lives_theme_phase tmux_lives_theme_vividness tmux_lives_theme_shape tmux_lives_theme_ease tmux_lives_theme_range tmux_lives_theme_polarity tmux_lives_theme_contrast tmux_lives_theme_rotate tmux_lives_bar_color tmux_lives_status_invert tmux_lives_cap tmux_lives_cap_wheel tmux_lives_cap_vividness tmux_lives_cap_role tmux_lives_theme_place tmux_lives_theme_mode
set -g _th_had
set -g _th_saved
for n in $_th_names
    if set -q $n
        set -a _th_had 1
        set -a _th_saved "$$n"
    else
        set -a _th_had 0
        set -a _th_saved ""
    end
    set -e $n
end

# The v3 arc tokens (warm/cool/span/wide/aurora/sunset/fire/complement/full) named a
# model that no longer exists — v4 replaced arcs with signed relationships, and v5
# replaced the curve wholesale. __tmux_lives_theme_schemes was their only home and had
# zero production callers; its own test asserted the retired list, so it was dead code
# testing dead code. Guard the NAMES rather than the function, so reintroducing any of
# them anywhere in the install file is caught, not just a same-named function.
# NB $src is not defined until much further down this file; referencing it here would
# expand to an empty path and the grep would pass vacuously. Use $plugindir (line 18).
set -g _v3names (grep -cE '\b(aurora|sunset|complement)\b' $plugindir/conf.d/tmux-lives-install.fish)
t "retired v3 arc names are gone from the install source" 0 $_v3names
t "theme_schemes is gone" 0 (functions -q __tmux_lives_theme_schemes; and echo 1; or echo 0)

# dispatcher routes + help row
functions -c __tmux_lives_theme_cmd __thc_bak
# NB the echo is QUOTED ("THEME:$argv"): fish's cartesian-product expansion of an unquoted
# prefix concatenated with a multi-element list (THEME:$argv with $argv = (warm x)) yields
# TWO args ("THEME:warm" "THEME:x"), which echo then space-joins into "THEME:warm THEME:x"
# — not the single "THEME:warm x" this assertion checks for the argv[2..]-forwarding.
function __tmux_lives_theme_cmd; echo "THEME:$argv"; end
t "setup dispatch routes theme" "THEME:warm x" (__tmux_lives_setup_dispatch theme warm x)
functions -e __tmux_lives_theme_cmd; functions -c __thc_bak __tmux_lives_theme_cmd; functions -e __thc_bak
t "setup help lists theme" yes (string match -q '*theme [<rel>*bar theme*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)

# v4: theme-cmd/apply/list surface — relationships, --place/--mode, --rotate retired.
functions -c __tmux_lives_write_fragment __wfth_bak
function __tmux_lives_write_fragment; end

# no-arg shows state; validation refuses before mutating
# no-arg: outside tmux (or no display-popup) -> state print, unchanged
set -g _tmx_had 0
set -q TMUX; and set _tmx_had 1; and set -g _tmx_save $TMUX
set -e TMUX
set -e tmux_lives_theme
t "theme no-arg outside tmux prints the mono default" yes (string match -q 'theme: mono*' -- (__tmux_lives_theme_cmd | string collect); and echo yes; or echo no)
test $_tmx_had -eq 1; and set -gx TMUX $_tmx_save
t "theme no-arg opens the picker in tmux" yes (string match -q '*display-popup -B -E -w 52 -h 85%*theme-picker*' -- (functions __tmux_lives_theme_cmd | string collect); and echo yes; or echo no)
set -U tmux_lives_bar_color '#485b3c'
t "theme: invalid relationship rejected" 1 (__tmux_lives_theme_cmd wat 2>/dev/null; echo $status)
t "theme: invalid relationship leaves the universal unset" 0 (set -q tmux_lives_theme; and echo 1; or echo 0)
t "theme: invalid place rejected" 1 (__tmux_lives_theme_cmd ember --place middle 2>/dev/null; echo $status)
t "theme: invalid place mutates nothing" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "theme: invalid mode rejected" 1 (__tmux_lives_theme_cmd ember --mode dyed 2>/dev/null; echo $status)
t "theme: invalid mode mutates nothing" 0 (set -q tmux_lives_theme_mode; and echo 1; or echo 0)
t "theme: --place low rejected"  1 (__tmux_lives_theme_cmd ember --place low 2>/dev/null; echo $status)
t "theme: --place high rejected" 1 (__tmux_lives_theme_cmd ember --place high 2>/dev/null; echo $status)
t "theme: --place error names the three survivors" 1 (__tmux_lives_theme_cmd ember --place low 2>&1 | string match -q '*bar, tabs, cap*'; and echo 1; or echo 0)
t "theme: --place low mutates nothing" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "theme: --rotate error no longer offers low/high" 0 (__tmux_lives_theme_cmd ember --rotate 2 2>&1 | string match -q '*low*'; and echo 1; or echo 0)
t "theme: invalid phase rejected" 1 (__tmux_lives_theme_cmd ember --phase x 2>/dev/null; echo $status)
t "theme: invalid phase mutates nothing" 0 (set -q tmux_lives_theme; and echo 1; or echo 0)
t "theme: invalid vividness rejected" 1 (__tmux_lives_theme_cmd --vividness max 2>/dev/null; echo $status)
t "theme: invalid shape rejected" 1 (__tmux_lives_theme_cmd --shape round 2>/dev/null; echo $status)
t "theme: invalid ease rejected" 1 (__tmux_lives_theme_cmd --ease bounce 2>/dev/null; echo $status)
t "theme: --rotate is gone" 1 (__tmux_lives_theme_cmd ember --rotate 2 2>/dev/null; echo $status)
t "theme: --rotate error mentions --place" 1 (__tmux_lives_theme_cmd ember --rotate 2 2>&1 | string match -q '*--place*'; and echo 1; or echo 0)

# --- Task 2: the four inert knobs are rejected, not silently accepted ------------
# Verified inert before removal: swinging all four to their extremes produced
# byte-identical palettes on all 35 catalog rows. Accepting a flag that does
# nothing is exactly the state being cleaned up, so these must ERROR.
t "theme: --vividness is gone" 1 (__tmux_lives_theme_cmd ember --vividness vivid 2>/dev/null; echo $status)
t "theme: --shape is gone"     1 (__tmux_lives_theme_cmd ember --shape flat 2>/dev/null; echo $status)
t "theme: --ease is gone"      1 (__tmux_lives_theme_cmd ember --ease cubic 2>/dev/null; echo $status)
t "theme: --contrast is gone"  1 (__tmux_lives_theme_cmd ember --contrast darker 2>/dev/null; echo $status)
t "theme: --vividness error says it never did anything" 1 (__tmux_lives_theme_cmd ember --vividness vivid 2>&1 | string match -q '*never affected*'; and echo 1; or echo 0)

# Existence first: an undefined function inside a `t` substitution aborts the
# statement silently and the suite still reports ALL PASS.
t "migrate_v51 exists" 0 (functions -q __tmux_lives_migrate_v51; echo $status)
set -U tmux_lives_theme_vividness vivid
set -U tmux_lives_theme_shape flat
set -U tmux_lives_theme_ease cubic
set -U tmux_lives_theme_contrast darker
__tmux_lives_migrate_v51 >/dev/null 2>&1
t "migrate_v51 erases vividness" 0 (set -q tmux_lives_theme_vividness; and echo 1; or echo 0)
t "migrate_v51 erases shape"     0 (set -q tmux_lives_theme_shape; and echo 1; or echo 0)
t "migrate_v51 erases ease"      0 (set -q tmux_lives_theme_ease; and echo 1; or echo 0)
t "migrate_v51 erases contrast"  0 (set -q tmux_lives_theme_contrast; and echo 1; or echo 0)
# Guarded by `functions -q`, not a bare call: an undefined function inside a command
# substitution aborts the assignment silently, leaving $_m51 UNSET — and an unset var
# expands to '' in double quotes, which spuriously equals the expected '' below and
# passes for the wrong reason. The guard forces a real, visible failure pre-implementation.
if functions -q __tmux_lives_migrate_v51
    set -g _m51 (__tmux_lives_migrate_v51 2>&1 | string collect)
else
    set -g _m51 __migrate_v51_missing__
end
t "migrate_v51 is silent when there is nothing to erase" '' "$_m51"
t "post_update chains migrate_v51" yes (string match -q '*__tmux_lives_migrate_v51*' -- (functions _tmux_lives_post_update | string collect); and echo yes; or echo no)

# --- drop-autoapply-debounce-seed Task 1: retire tmux_lives_theme_autoapply ------
# Auto-apply-on-dwell (the theme-picker A toggle) was cancelled outright, not
# defaulted off — the user tried it live and found it too disruptive. A
# session that pressed A left tmux_lives_theme_autoapply set; erase it.
t "migrate_v52 exists" 0 (functions -q __tmux_lives_migrate_v52; echo $status)
set -U tmux_lives_theme_autoapply 0
__tmux_lives_migrate_v52 >/dev/null 2>&1
t "migrate_v52 erases the autoapply universal" 0 (set -q tmux_lives_theme_autoapply; and echo 1; or echo 0)
# Guarded by `functions -q`, matching the migrate_v51 pattern above: an undefined
# function inside a command substitution aborts the assignment silently, leaving
# $_m52 UNSET — and an unset var expands to '' in double quotes, which would
# spuriously equal the expected '' below and pass for the wrong reason.
if functions -q __tmux_lives_migrate_v52
    set -g _m52 (__tmux_lives_migrate_v52 2>&1 | string collect)
else
    set -g _m52 __migrate_v52_missing__
end
t "migrate_v52 is silent when there is nothing to erase (idempotent)" '' "$_m52"
t "post_update chains migrate_v52" yes (string match -q '*__tmux_lives_migrate_v52*' -- (functions _tmux_lives_post_update | string collect); and echo yes; or echo no)

set -e tmux_lives_bar_color
t "theme: a relationship without a seed refuses" 1 (__tmux_lives_theme_cmd ember 2>/dev/null; echo $status)
set -U tmux_lives_bar_color '#485b3c'

# v4 gallery catalog: 28 curated schemes, 12 flagged default, each a valid engine input
t "catalog has 35 entries" 35 (count (__tmux_lives_theme_catalog))
t "catalog default is 14"  14 (count (__tmux_lives_theme_catalog_default))
t "catalog entries are 5 fields" 5 (count (string split '|' (__tmux_lives_theme_catalog | head -1)))
t "catalog default subset of all" 1 (test (count (__tmux_lives_theme_catalog | string match -r '\|1$')) -eq 14; and echo 1; or echo 0)
# every recipe is a valid engine input -> 7-hex palette
set -l bad 0
for e in (__tmux_lives_theme_catalog)
    set -l f (string split '|' $e)
    set -l p (__tmux_lives_theme_palette '#5f772b' $f[2] $f[3] $f[4] 0)
    test (count $p) -eq 7; or set bad (math $bad + 1)
end
t "every catalog recipe yields 7 hexes" 0 $bad
t "theme list names ember glow" 1 (string match -q '*ember glow*' -- (__tmux_lives_theme_list | string collect); and echo 1; or echo 0)

# --- catalog composition (2026-07-28 weeding pass) ------------------------------------
# The seed was verbatim at bar (glow) and cap (core) but NEVER at tabs — 0 of the 28 rows
# the catalog held at the time — so the "chip" tier exists to close that. (The ember-at-cap
# cut this section used to argue from the deleted taper's chroma-clamp behavior; that
# reasoning no longer applies to this engine. What survives below — "cap placement holds
# exactly 4" plus the four named cap-row presence assertions — pins the 4 cap-row NAMES
# exactly, but matches by NAME (`^amber deep\|`, etc.), not by recipe, so it would not by
# itself catch a row still named e.g. "amber deep" whose underlying relationship field had
# been changed to ember.)
t "catalog: tabs+literal tier exists (the chip tier)" 1 (test (count (__tmux_lives_theme_catalog | string match -r '\|tabs\|literal\|')) -ge 1; and echo 1; or echo 0)
t "catalog: amber chip present" 1 (string match -q '*amber chip|amber|tabs|literal*' -- (__tmux_lives_theme_catalog | string collect); and echo 1; or echo 0)
t "catalog: sage chip present" 1 (string match -q '*sage chip|sage|tabs|literal*' -- (__tmux_lives_theme_catalog | string collect); and echo 1; or echo 0)
t "catalog: coral chip is a default" 1 (string match -q '*coral chip*' -- (__tmux_lives_theme_catalog_default | string collect); and echo 1; or echo 0)
# Tier composition, pinned EXACTLY. bar and tabs are symmetric (8 relationships x
# derived/literal each) because both are now first-class dominant placements — EXCEPT
# mono, which has no tabs row (see below); cap survives as a 4-row accent-led minority,
# split across the literal/derived groups by Task 8's reorder (core in the literal
# half, deep in the derived half — see the "literal groups first" section below).
t "catalog: soft is 8 (bar derived)"   8 (count (__tmux_lives_theme_catalog | string match -r '\|bar\|derived\|'))
t "catalog: glow is 8 (bar literal)"   8 (count (__tmux_lives_theme_catalog | string match -r '\|bar\|literal\|'))
t "catalog: slate is 7 (tabs derived)" 7 (count (__tmux_lives_theme_catalog | string match -r '\|tabs\|derived\|'))
t "catalog: chip is 8 (tabs literal)"  8 (count (__tmux_lives_theme_catalog | string match -r '\|tabs\|literal\|'))
t "catalog: cap placement holds exactly 4" 4 (count (__tmux_lives_theme_catalog | string match -r '\|cap\|'))
# mono is structurally exempt from "both large placements": mono's signed travel is 0,
# so anchoring the bar and anchoring the tabs are literally the same operation — a
# mono|tabs|derived row could only ever duplicate mono|bar|derived, which is exactly
# the byte-identical duplicate ("mono slate") a prior weeding pass removed. No OTHER
# relationship has zero travel, so no other relationship is exempt.
t "catalog: every relationship appears at both large placements (mono exempt)" 0 (set -l bad 0; for r in wheat mint amber sage ember teal coral; for pl in bar tabs; test (count (__tmux_lives_theme_catalog | string match -r "\|$r\|$pl\|")) -eq 2; or set bad (math $bad + 1); end; end; echo $bad)
# the exemption is specifically the tabs|derived (slate) tier — mono keeps its
# tabs|literal (chip) row, which is NOT a duplicate: literal mode pins the seed's exact
# L/C to whichever role is placed, so mono chip (seed pinned at tabs) differs from mono
# glow (seed pinned at bar) even though both share mono's single hue.
t "catalog: mono absent from tabs-derived (would dup mono soft)" 0 (count (__tmux_lives_theme_catalog | string match -r '\|mono\|tabs\|derived\|'))
t "catalog: mono still present at tabs-literal (chip; legitimately distinct)" 1 (count (__tmux_lives_theme_catalog | string match -r '\|mono\|tabs\|literal\|'))
t "catalog: mono slate removed (was a byte-identical dup of mono soft)" 0 (string match -q '*mono slate*' -- (__tmux_lives_theme_catalog | string collect); and echo 1; or echo 0)
# all four cap rows exist in the catalog, but only 2 of the 4 (amber deep,
# sage core — see "curated cap rows" below) are curated defaults; coral deep
# and teal core are catalog-only, reachable via `m`/More Schemes.
t "catalog: amber deep present" 1 (count (__tmux_lives_theme_catalog | string match -r '^amber deep\|'))
t "catalog: coral deep present" 1 (count (__tmux_lives_theme_catalog | string match -r '^coral deep\|'))
t "catalog: sage core present"  1 (count (__tmux_lives_theme_catalog | string match -r '^sage core\|'))
t "catalog: teal core present"  1 (count (__tmux_lives_theme_catalog | string match -r '^teal core\|'))
t "catalog: cap rows in defaults" 2 (count (__tmux_lives_theme_catalog_default | string match -r '\|cap\|'))
# Task 8 reordered tiers to group literal-before-derived, so cap is no longer one
# contiguous block at the tail: core (cap, literal) sorts last within the literal
# half (right after chip), and deep (cap, derived) sorts last within the derived
# half (the very end of the catalog). Both fail pre-fix (0, not the pinned 2).
t "catalog: rows 17-18 are the core tier (cap literal, closing the literal half)" 2 (count (string match -r '\|cap\|literal\|' -- (__tmux_lives_theme_catalog)[17..18]))
t "catalog: the last 2 rows are the deep tier (cap derived, closing the derived half)" 2 (count (string match -r '\|cap\|derived\|' -- (__tmux_lives_theme_catalog)[-2..-1]))
# the 14 curated default NAMES after Task 4 rebalance toward tabs — this
# label used to say "unchanged", which was already wrong when written: it
# pins the rebalanced set, not a pre-rebalance baseline.
t "catalog: default names after the tabs rebalance" "amber deep amber slate amber soft coral chip ember slate mint chip mono soft sage chip sage core sage glow teal glow teal slate wheat slate wheat soft" (__tmux_lives_theme_catalog_default | string replace -r '\|.*' '' | sort | string join ' ')
t "catalog: wheat chip exists (tabs literal kept)" 1 (count (__tmux_lives_theme_catalog | string match -r '\|wheat\|tabs\|literal\|'))
t "catalog: wheat soft is a default" 1 (string match -q '*wheat soft*' -- (__tmux_lives_theme_catalog_default | string collect); and echo 1; or echo 0)
t "catalog: mint chip is a default" 1 (string match -q '*mint chip*' -- (__tmux_lives_theme_catalog_default | string collect); and echo 1; or echo 0)

# --- Task 4: curated 14 rebalanced toward tabs ----------------------------------
# The tab bar is the dominant surface on screen; tabs placement is where a scheme
# reaches it, and it was 2 of the 14 rows shown on open. Pin the composition
# EXACTLY — a `>=` bound passed against the pre-cut catalog during the 2026-07-28
# weeding pass and hid a real composition change.
set -g CD4 (__tmux_lives_theme_catalog_default)
t "curated set is still 14" 14 (count $CD4)
t "curated bar rows"  5 (printf '%s\n' $CD4 | awk -F'|' '$3=="bar"'  | count)
t "curated tabs rows" 7 (printf '%s\n' $CD4 | awk -F'|' '$3=="tabs"' | count)
t "curated cap rows"  2 (printf '%s\n' $CD4 | awk -F'|' '$3=="cap"'  | count)
# Counts alone cannot see a swap — pin the names too.
set -g CD4N (printf '%s\n' $CD4 | awk -F'|' '{print $1}' | sort | string join ',')
t "curated names" 'amber deep,amber slate,amber soft,coral chip,ember slate,mint chip,mono soft,sage chip,sage core,sage glow,teal glow,teal slate,wheat slate,wheat soft' "$CD4N"
# Every relationship must still be reachable from the opening view.
for r in mono wheat mint amber ember coral sage teal
    set -l hits (printf '%s\n' $CD4 | awk -F'|' -v r=$r '$2==r' | count)
    t "curated covers $r" yes (test $hits -ge 1; and echo yes; or echo no)
end

# --- Task 5: the non-default rows, as their own list ----------------------------
t "catalog_rest exists" 0 (functions -q __tmux_lives_theme_catalog_rest; echo $status)
set -g CR5 (__tmux_lives_theme_catalog_rest)
t "catalog_rest returns the other 21" 21 (count $CR5)
t "catalog_rest + default = the whole catalog" (__tmux_lives_theme_catalog | count) (math (count $CR5) + (__tmux_lives_theme_catalog_default | count))
# Non-regression guard: passes vacuously pre-fix (empty set vs 14 curated = 0 common rows,
# expects 0) and after (21 distinct rows vs 14 curated = still 0 common). Catches future
# regressions if either set is computed incorrectly. Not a fix-discriminator.
t "catalog_rest and default do not overlap" 0 (comm -12 (printf '%s\n' $CR5 | sort | psub) (__tmux_lives_theme_catalog_default | sort | psub) | count)
t "catalog_rest preserves catalog order" yes (test "$CR5[1]" = (__tmux_lives_theme_catalog | string match -rv '\|1$' | head -1); and echo yes; or echo no)

# --- Task 7: expanding APPENDS, it does not reshuffle ----------------------------
# The full catalog is in TIER order, so the curated rows are scattered through it;
# swapping the row source wholesale is what made expanding "completely rewrite the
# entire list". Composing default-then-rest keeps the first 14 exactly where they
# were, which is the actual fix — preserving the cursor by name treated a symptom.
set -g ORD7 (__tmux_lives_theme_catalog_default) (__tmux_lives_theme_catalog_rest)
t "composed list is the whole catalog" 35 (count $ORD7)
t "composed list has no duplicates" 35 (printf '%s\n' $ORD7 | sort -u | count)
set -g CDN7 (__tmux_lives_theme_catalog_default | awk -F'|' '{print $1}' | string join ',')
set -g ORDN7 (printf '%s\n' $ORD7[1..14] | awk -F'|' '{print $1}' | string join ',')
t "first 14 of the composed list are the curated 14, in order" "$CDN7" "$ORDN7"

# --- Task 8: catalog ordered seed-literal first ----------------------------------
# The user is comparing seed-literal schemes against seed-derived ones as groups
# ("I may be noticing trends between the seed-figurative schemes and the
# seed-literal schemes") and asked, when offered the choice, for "seed literal
# first". Literal is the PRIMARY sort: all 18 literal rows (glow/chip/core) precede
# all 17 derived rows (soft/slate/deep), with the bar -> tabs -> cap progression
# preserved inside each half. Pure reorder — same 35 rows, same 14 curated, only
# __tmux_lives_theme_catalog's row SEQUENCE changed; _default and _rest are both
# filters over it, so both inherit the new order for free.
set -g CAT8 (__tmux_lives_theme_catalog)
t "catalog is still 35 rows" 35 (count $CAT8)
t "catalog still has 14 defaults" 14 (count (__tmux_lives_theme_catalog_default))
t "18 rows are literal, 17 are derived" '18 17' (string join ' ' (count (string match -r '\|literal\|' -- $CAT8)) (count (string match -r '\|derived\|' -- $CAT8)))
# literal rows all precede derived rows: the LAST literal index must be less than
# the FIRST derived index (a stronger check than counting — it fails if even one
# row is out of place, not just if the totals are off).
set -g __t8_lastlit 0
set -g __t8_firstder 999
for i in (seq (count $CAT8))
    set -l f (string split '|' -- $CAT8[$i])
    if test "$f[4]" = literal
        set __t8_lastlit $i
    else if test $i -lt $__t8_firstder
        set __t8_firstder $i
    end
end
t "every literal row precedes every derived row" 1 (test $__t8_lastlit -lt $__t8_firstder; and echo 1; or echo 0)
t "the first catalog row is literal" literal (string split '|' -- $CAT8[1])[4]
t "the last catalog row is derived" derived (string split '|' -- $CAT8[-1])[4]
# bar -> tabs -> cap progression preserved inside each half (glow/chip/core, then
# soft/slate/deep) — spot-check via the placement of the first row of each tier.
t "row 1 (start of literal half) is bar-placed (glow)" bar (string split '|' -- $CAT8[1])[3]
t "row 9 (after 8 glow rows) is tabs-placed (chip)" tabs (string split '|' -- $CAT8[9])[3]
t "row 17 (after 8 chip rows) is cap-placed (core)" cap (string split '|' -- $CAT8[17])[3]
t "row 19 (start of derived half) is bar-placed (soft)" bar (string split '|' -- $CAT8[19])[3]
t "row 27 (after 8 soft rows) is tabs-placed (slate)" tabs (string split '|' -- $CAT8[27])[3]
t "row 34 (after 7 slate rows) is cap-placed (deep)" cap (string split '|' -- $CAT8[34])[3]
# _default and _rest are filters over the (now reordered) catalog, so the default
# NAMES and count are unaffected by Task 8 — already pinned exactly by "catalog:
# default names after the tabs rebalance" above (still passing, sorted so
# order-independent), which is the discriminator for "did the default SET survive
# the reorder", not a new assertion here.
set -e __t8_lastlit
set -e __t8_firstder

# list renders one row per catalog entry (28), each with a 7-cell truecolor strip
t "theme list has 35 rows" 35 (count (__tmux_lives_theme_list))
t "theme list rows carry truecolor swatches" 35 (count (string match -r '48;2;' (__tmux_lives_theme_list)))

# live apply on the -L seam
set -g _th_fcd $__fish_config_dir
set -g __fish_config_dir /tmp/th-noconf-$fish_pid
set -g thsock tlt-$fish_pid
command tmux -L $thsock new-session -d 2>/dev/null
set -gx tmux_lives_tmux_socket $thsock
__tmux_lives_theme_cmd ember --place cap --mode literal --phase 30 >/dev/null
t "theme cmd persists relationship" ember "$tmux_lives_theme"
t "theme cmd persists place" cap "$tmux_lives_theme_place"
t "theme cmd persists mode" literal "$tmux_lives_theme_mode"
t "theme cmd persists phase" 30 "$tmux_lives_theme_phase"
set -g THP (__tmux_lives_theme_palette '#485b3c' ember cap literal 30)
t "theme live-applies bar_bg" "$THP[1]" (command tmux -L $thsock show -gv @tmux_lives_bar_bg 2>/dev/null)
t "theme live-applies sep_fg" "$THP[2]" (command tmux -L $thsock show -gv @tmux_lives_sep_fg 2>/dev/null)
t "theme live-applies tabs_color" "$THP[3]" (command tmux -L $thsock show -gv @tmux_lives_tabs_color 2>/dev/null)
t "theme live-applies active_fg" "$THP[4]" (command tmux -L $thsock show -gv @tmux_lives_active_fg 2>/dev/null)
t "theme live-applies cap_bg" "$THP[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "theme live-applies text_fg" "$THP[7]" (command tmux -L $thsock show -gv @tmux_lives_text_fg 2>/dev/null)
# apply-live pushes the seed verbatim as the mark color, not the cap sample
t "theme live-applies mark_fg = seed" '#485b3c' (command tmux -L $thsock show -gv @tmux_lives_mark_fg 2>/dev/null)
t "theme live-applies status-style" "bg=$THP[1],fg=$THP[5]" (command tmux -L $thsock show -gv status-style 2>/dev/null)
# a pathological --phase is normalized mod 360 before storage (norm360 hang guard)
__tmux_lives_theme_cmd --phase 100000360 >/dev/null
t "huge phase normalized mod 360" 280 "$tmux_lives_theme_phase"
# off: v2 values return, role seeds neutralize, cap writes work again
__tmux_lives_theme_cmd off >/dev/null
t "off stores the off token" off "$tmux_lives_theme"
t "off restores the v2 status-style" (__tmux_lives_derive_status '#485b3c' 0) (command tmux -L $thsock show -gv status-style 2>/dev/null)
t "off resets text_fg to default" default (command tmux -L $thsock show -gv @tmux_lives_text_fg 2>/dev/null)
t "off pushes the neutral legacy cap" colour238 (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "off pushes the legacy cap fg" "#f5f5f5" (command tmux -L $thsock show -gv @tmux_lives_cap_fg 2>/dev/null)
# unset (not just 'off') applies mono — always-on's actual default. Also reset the knobs
# this section mutated above (place->cap, mode->literal, phase->280, vividness->vivid) back
# to their own defaults so THMONO's assumed bar/derived/0/balanced actually matches what
# __tmux_lives_theme_apply_live reads.
set -e tmux_lives_theme
set -e tmux_lives_theme_place
set -e tmux_lives_theme_mode
set -e tmux_lives_theme_phase
set -e tmux_lives_theme_vividness
__tmux_lives_theme_apply_live
set -g THMONO (__tmux_lives_theme_palette '#485b3c' mono bar derived 0)
t "unset theme applies mono (always-on)" "$THMONO[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
# Task 6 controller scope: the 4-arg apply-live path (the picker's `a`-preview and
# esc-revert path) writes no state — direct-call it twice with only phase flipped
# and confirm a derived color actually moves (same seed/relationship/place/mode).
# Task 1 removed vividness/shape/ease/contrast entirely (they were accepted-but-inert),
# so phase is the only knob left that moves a role color here.
__tmux_lives_theme_apply_live sage bar derived 0
set -g THEME_CAP_A (command tmux -L $tmux_lives_tmux_socket show -gv @tmux_lives_cap_bg 2>/dev/null)
__tmux_lives_theme_apply_live sage bar derived 180
set -g THEME_CAP_B (command tmux -L $tmux_lives_tmux_socket show -gv @tmux_lives_cap_bg 2>/dev/null)
t "apply-live 4-arg phase-0 cap_bg non-empty" 1 (test -n "$THEME_CAP_A"; and echo 1; or echo 0)
t "apply-live 4-arg phase-180 cap_bg non-empty" 1 (test -n "$THEME_CAP_B"; and echo 1; or echo 0)
t "apply-live 4-arg phase 0 vs 180 differ" 1 (test "$THEME_CAP_A" != "$THEME_CAP_B"; and echo 1; or echo 0)
command tmux -L $thsock kill-server 2>/dev/null
set -e tmux_lives_tmux_socket
set -g __fish_config_dir $_th_fcd

functions -e __tmux_lives_write_fragment; functions -c __wfth_bak __tmux_lives_write_fragment; functions -e __wfth_bak

# coarse perf guard (environment-tolerant, like the truncate guard): one
# in-process 10-scheme batch must complete well under a second.
set -l _pt0 (date +%s%N)
for _tok in (__tmux_lives_theme_relationships)
    __tmux_lives_theme_palette '#485b3c' $_tok bar derived 0 >/dev/null
end
set -l _pt1 (date +%s%N)
set -l _ptms (math "($_pt1 - $_pt0) / 1000000")
t "perf: in-process 10-palette batch < 1000ms" 1 (test $_ptms -lt 1000; and echo 1; or echo 0)

# universal-variable semantics that broke the picker save path (2026-07-17):
# `fish --no-config` neither reads nor writes universal variables — a set -U
# there is process-local and invisible to every other fish. The picker fix
# routes universal-touching actions through a config-loaded `fish -c` child;
# these tests document BOTH halves of the mechanism.
set -e __tl_test_uprobe 2>/dev/null
fish --no-config -c 'set -U __tl_test_uprobe direct' 2>/dev/null
t "no-config set -U is invisible cross-process" 0 (fish -c 'set -q __tl_test_uprobe; and echo 1; or echo 0')
fish --no-config -c 'fish -c "set -U __tl_test_uprobe viachild"' 2>/dev/null
t "config-loaded child set -U persists" viachild (fish -c 'echo $__tl_test_uprobe')
fish -c 'set -e __tl_test_uprobe' 2>/dev/null
t "uprobe cleaned up" 0 (fish -c 'set -q __tl_test_uprobe; and echo 1; or echo 0')

# restore the saved universals (bottom of the section — the socket seam is unpinned by now)
for i in (seq (count $_th_names))
    set -e $_th_names[$i]
    test $_th_had[$i] -eq 1; and set -U $_th_names[$i] $_th_saved[$i]
end

# ---- v4: relationship table ----
t "relationships list" "mono wheat amber ember coral mint sage teal" (__tmux_lives_theme_relationships | string join ' ')
t "reldef wheat warm 20"  -20  (__tmux_lives_theme_reldef wheat)
t "reldef mint cool 20"   20   (__tmux_lives_theme_reldef mint)
t "reldef mono is flat"   0    (__tmux_lives_theme_reldef mono)
t "reldef amber warm 40"  -40  (__tmux_lives_theme_reldef amber)
t "reldef ember warm 72"  -72  (__tmux_lives_theme_reldef ember)
t "reldef coral warm 100" -100 (__tmux_lives_theme_reldef coral)
t "reldef sage cool 40"   40   (__tmux_lives_theme_reldef sage)
t "reldef teal cool 72"   72   (__tmux_lives_theme_reldef teal)
t "reldef unknown empty"  ""   (__tmux_lives_theme_reldef nope)
t "valid ember" 0 (__tmux_lives_theme_valid ember; echo $status)
t "valid junk"  1 (__tmux_lives_theme_valid junk; echo $status)

# ---- update staleness: which shells actually need `exec fish` ----
# fisher sources the plugin's files into the shell that ran the update, so THAT shell is
# already current. Every other running shell keeps its old definitions. And sourcing cannot
# UNSET a function, so a removed/renamed one lingers even in the updating shell. Two
# independent signals, so the post-update note can say which applies.

# pure: tmux pane shells other than our own, from `list-panes` output
set -l panes "111 Alpha fish" "222 Beta claude" "333 Gamma fish" "444 Alpha fish"
t "stale shells: excludes our own pane pid" "Alpha Gamma Alpha" (__tmux_lives_stale_shells 222 $panes | string join ' ')
t "stale shells: none when only our own"    ""                  (__tmux_lives_stale_shells 111 "111 Alpha fish" | string join ' ')
t "stale shells: empty input is empty"      ""                  (__tmux_lives_stale_shells 111 | string join ' ')
t "stale shells: a pane running claude still counts (its shell is stale too)" 1 (contains Beta (__tmux_lives_stale_shells 999 $panes); and echo 1; or echo 0)

# pure: names present in the old set but gone from the new one
t "removed: finds a dropped name" "__gone" (__tmux_lives_removed_functions "__a
__gone
__b" "__a
__b" | string join ' ')
t "removed: none when unchanged" "" (__tmux_lives_removed_functions "__a
__b" "__a
__b" | string join ' ')
t "removed: additions are not removals" "" (__tmux_lives_removed_functions "__a" "__a
__new" | string join ' ')
t "removed: empty old set (first run) reports nothing" "" (__tmux_lives_removed_functions "" "__a" | string join ' ')

# the shipped-function scan reads `function <name>` from the installed files
t "shipped fns includes a known one" 1 (contains __tmux_lives_state_path (__tmux_lives_shipped_functions $plugindir); and echo 1; or echo 0)
t "shipped fns are sorted+unique"    1 (set -l f (__tmux_lives_shipped_functions $plugindir); test (count $f) -eq (count (printf '%s\n' $f | sort -u)); and echo 1; or echo 0)
t "shipped fns exist at all"         1 (test (count (__tmux_lives_shipped_functions $plugindir)) -gt 20; and echo 1; or echo 0)
t "shipped fns picks up the categorizer too" 1 (contains __tcz_categorize (__tmux_lives_shipped_functions $plugindir); and echo 1; or echo 0)

# state file, seam-overridable like the other state paths
set -g tmux_lives_funcs_file /tmp/tl-funcs-$fish_pid
t "funcs path honours the seam" /tmp/tl-funcs-$fish_pid (__tmux_lives_funcs_path)
set -e tmux_lives_funcs_file
t "funcs path default sits beside the other state" 1 (string match -q '*/.config/tmux/*' -- (__tmux_lives_funcs_path); and echo 1; or echo 0)

# the note must never tell the updating shell to restart when nothing was removed
# NB the note may still say "exec fish" here — for the OTHER shells. What it must not do is
# tell the shell you are standing in to restart, which is the "here too" advice.
t "note: does not tell THIS shell to restart when nothing was removed" 0 (string match -q '*here too*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" | string collect); and echo 1; or echo 0)
t "note: DOES tell this shell to restart when something was removed" 1 (string match -q '*here too*' -- (__tmux_lives_update_note 1 "__gone" "" | string collect); and echo 1; or echo 0)
t "note: names the other stale sessions" 1 (string match -q '*Alpha*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" | string collect); and echo 1; or echo 0)
t "note: flags exec fish HERE when a function was removed" 1 (string match -q '*exec fish*' -- (__tmux_lives_update_note 1 "__gone" "" | string collect); and echo 1; or echo 0)
t "note: names the removed function" 1 (string match -q '*__gone*' -- (__tmux_lives_update_note 1 "__gone" "" | string collect); and echo 1; or echo 0)
t "note: says nothing about other shells when there are none" 0 (string match -q '*other*' -- (__tmux_lives_update_note 1 "" "" | string collect); and echo 1; or echo 0)
t "note: uses `exec fish`, never a personal alias" 0 (string match -q '*exf*' -- (__tmux_lives_update_note 1 "__gone" "Alpha" | string collect); and echo 1; or echo 0)

# ---- v5: kin-cap family table ----
# Fitted in the 2026-07-20 calibration study (4 rounds, user as blind subject, ~84% of
# judgments explained; the rule-generated validation batch scored 9/10 vs 5/10 pre-rule).
# Restored from the v3.3 kincap rule the v4 rewrite deleted.
# The function must EXIST. Without this, every assertion below is invisible: when a
# command substitution calls an undefined function fish aborts the whole statement, so
# `t` never runs, nothing prints, and — because the aborted `t` call also skips the
# fail counter — this suite still says ALL PASS. This suite DOES count ($pass/$fail,
# reported at the bottom of the file); the count only catches this class of bug if
# someone diffs it against a prior run, since a silently-skipped `t` still reports
# ALL PASS on its own.
t "family fn exists" 1 (functions -q __tmux_lives_theme_family; and echo 1; or echo 0)
set -l f60 (__tmux_lives_theme_family 60)
t "family warm/earth 40"           40 "$f60"
set -l f125 (__tmux_lives_theme_family 125)
t "family olive/green 20"          20 "$f125"
set -l f185 (__tmux_lives_theme_family 185)
t "family teal 30"                 30 "$f185"
set -l f240 (__tmux_lives_theme_family 240)
t "family blue 25"                 25 "$f240"
set -l f300 (__tmux_lives_theme_family 300)
t "family purple 18"               18 "$f300"
set -l f10 (__tmux_lives_theme_family 10)
t "family red low 15"              15 "$f10"
set -l f350 (__tmux_lives_theme_family 350)
t "family red high 15"             15 "$f350"
set -l f40 (__tmux_lives_theme_family 40)
t "family lower bound 40 is warm"  40 "$f40"
set -l f90 (__tmux_lives_theme_family 90)
t "family upper bound 90 is olive" 20 "$f90"
set -l f485 (__tmux_lives_theme_family 485)
t "family wraps past 360"          20 "$f485"

# ---- the ink is NOT part of the big-area rewrite: pin it byte-identical ----
# __tmux_lives_theme_accents is deliberately untouched (the user's instruction: "the ink
# isn't what needs changing currently"). These four hexes are its output at a fixed bar,
# captured from the pre-rewrite engine. If a later refactor drifts the ink, this fails.
set -l ink (__tmux_lives_theme_accents '#405733' '#6cb040')
t "ink returns 4"  4         (count $ink)
t "ink sep"        '#7f8a78' $ink[1]
t "ink active"     '#cfdcc9' $ink[2]
t "ink windows"    '#a0b198' $ink[3]
t "ink text"       '#cfdcc8' $ink[4]
# the cap argument is declared and unused — documented as intentional for now, not a bug
# to fix in this cycle. Changing the cap must not change the ink.
set -l ink2 (__tmux_lives_theme_accents '#405733' '#ff0000')
t "ink is independent of the cap argument" "$ink" "$ink2"

# ---- v5: curve — two large areas and a bridge ----
function _oklch_of --argument-names hex   # -> "L C H"
    set -l r (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $r[1] $r[2] $r[3]
end
function _dhue --argument-names a b       # circular |a-b| in degrees
    set -l d (math "abs($a - $b)")
    test $d -gt 180; and set d (math "360 - $d")
    echo $d
end
set -l seed '#5f772b'          # L .533  C .106  H 124.7 -> family 20
set -l so (_oklch_of $seed)
set -l tri (__tmux_lives_theme_curve $seed ember bar derived 0)
t "curve returns 3" 3 (count $tri)
for i in 1 2 3
    t "curve role $i is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $tri[$i]; and echo 1; or echo 0)
end

# ANCHOR INVARIANCE — the placed large area never moves between relationships.
# This is the whole point of the rewrite: there is always something to defer to.
set -l anchor_bar
set -l anchor_tabs
for r in mono wheat mint amber sage ember teal coral
    set -l pb (__tmux_lives_theme_curve $seed $r bar derived 0)
    set -l pt (__tmux_lives_theme_curve $seed $r tabs derived 0)
    set -a anchor_bar $pb[1]
    set -a anchor_tabs $pt[2]
end
t "anchor: the bar is invariant at place=bar"   1 (test (count (printf '%s\n' $anchor_bar | sort -u)) -eq 1; and echo 1; or echo 0)
t "anchor: the tabs are invariant at place=tabs" 1 (test (count (printf '%s\n' $anchor_tabs | sort -u)) -eq 1; and echo 1; or echo 0)
set -l abo (_oklch_of $anchor_bar[1])
set -l dseed (_dhue $abo[3] $so[3])
t "anchor: the bar holds the seed hue" 1 (test $dseed -lt 2; and echo 1; or echo 0)

# TRAVEL — the OTHER large area sits |sd| away from the anchor.
# Tolerance 2 deg: assertions run on RENDERED hexes, which quantise to 8-bit sRGB and
# gamut-clamp. This loop only exercises place=bar; measured worst error there at this
# seed is 0.732351 deg. For the record (not asserted by this loop): place=tabs worst is
# 0.994518 deg, place=cap worst is 1.069721 deg — over half the 2 deg tolerance, a
# thinner margin than the old "0.99 deg" comment here implied.
set -l travbad 0
for r in mono wheat mint amber sage ember teal coral
    set -l sd (__tmux_lives_theme_reldef $r)
    set -l p (__tmux_lives_theme_curve $seed $r bar derived 0)
    set -l hb (_oklch_of $p[1])
    set -l ht (_oklch_of $p[2])
    set -l got (_dhue $ht[3] $hb[3])
    set -l want (math "abs($sd)")
    set -l err (math "abs($got - $want)")
    test $err -lt 2; or set travbad (math $travbad + 1)
end
t "travel: the tab bar sits |sd| from the bar" 0 $travbad

# BRIDGE — |Hcap - Hbar| == max(|sd|/2, family(Hbar)).
# Deliberately NOT "the cap lies between the bar and the tabs": at low travel the family
# floor dominates, so at mono the tabs sit at the bar's hue while the cap sits `family`
# away from it. The floor is the guarantee the endcap never collapses into the bar.
# Measured worst error at this seed is 0.93 deg.
set -l bridgebad 0
for pl in bar tabs
    for r in mono wheat mint amber sage ember teal coral
        set -l sd (__tmux_lives_theme_reldef $r)
        set -l p (__tmux_lives_theme_curve $seed $r $pl derived 0)
        set -l hb (_oklch_of $p[1])
        set -l hc (_oklch_of $p[3])
        set -l fam (__tmux_lives_theme_family $hb[3])
        set -l want (math "max(abs($sd) / 2, $fam)")
        set -l got (_dhue $hc[3] $hb[3])
        set -l err (math "abs($got - $want)")
        test $err -lt 2; or set bridgebad (math $bridgebad + 1)
    end
end
t "bridge: the cap sits max(|sd|/2, family) from the bar" 0 $bridgebad
set -l mp (__tmux_lives_theme_curve $seed mono bar derived 0)
set -l mhb (_oklch_of $mp[1])
set -l mhc (_oklch_of $mp[3])
set -l mfloor (_dhue $mhc[3] $mhb[3])
t "bridge: the cap never collapses into the bar at mono" 1 (test $mfloor -gt 15; and echo 1; or echo 0)

# BRIDGE DIRECTION — the assertions above measure an UNSIGNED circular distance, so an
# inverted `dir` sign would pass all of them. Pin the actual side: the cap sits on the
# side of the bar TOWARD the tabs. At place=bar the signed Hcap-Hbar matches sd's sign;
# at place=tabs it is the OPPOSITE sign, because there the tabs sit at -sd from the bar
# (the bar is the role that travelled), so "toward the tabs" flips too.
function _sdhue --argument-names a b   # signed a-b folded to (-180, 180]
    set -l d (math "$a - $b")
    while test $d -gt 180
        set d (math "$d - 360")
    end
    while test $d -le -180
        set d (math "$d + 360")
    end
    echo $d
end
t "_sdhue helper exists" 1 (functions -q _sdhue; and echo 1; or echo 0)
set -l cb (__tmux_lives_theme_curve $seed coral bar derived 0)
set -l cbb (_oklch_of $cb[1]); set -l cbc (_oklch_of $cb[3])
t "bridge dir: coral bar sits toward the tabs (negative, sd<0)" 1 (test (_sdhue $cbc[3] $cbb[3]) -lt 0; and echo 1; or echo 0)
set -l ct (__tmux_lives_theme_curve $seed coral tabs derived 0)
set -l ctb (_oklch_of $ct[1]); set -l ctc (_oklch_of $ct[3])
t "bridge dir: coral tabs is the opposite sign (positive)" 1 (test (_sdhue $ctc[3] $ctb[3]) -gt 0; and echo 1; or echo 0)
set -l tb (__tmux_lives_theme_curve $seed teal bar derived 0)
set -l tbb (_oklch_of $tb[1]); set -l tbc (_oklch_of $tb[3])
t "bridge dir: teal bar sits toward the tabs (positive, sd>0)" 1 (test (_sdhue $tbc[3] $tbb[3]) -gt 0; and echo 1; or echo 0)
set -l tt (__tmux_lives_theme_curve $seed teal tabs derived 0)
set -l ttb (_oklch_of $tt[1]); set -l ttc (_oklch_of $tt[3])
t "bridge dir: teal tabs is the opposite sign (negative)" 1 (test (_sdhue $ttc[3] $ttb[3]) -lt 0; and echo 1; or echo 0)

# DEPTH — fixed per role, never moves. Hue differentiates, lightness coheres.
set -l dp (__tmux_lives_theme_curve $seed teal bar derived 0)
set -l dLb (_oklch_of $dp[1])
set -l dLt (_oklch_of $dp[2])
set -l dLc (_oklch_of $dp[3])
t "depth: the bar is darker than the tab bar" 1 (test $dLb[1] -lt $dLt[1]; and echo 1; or echo 0)
set -l capstep (math "abs($dLc[1] - $dLb[1])")
t "depth: the cap is one 0.10 step off the bar" 1 (test $capstep -gt 0.08; and test $capstep -lt 0.12; and echo 1; or echo 0)

# MONO IS UNCHANGED — the two large areas are byte-identical to the pre-rewrite engine.
# The tab chroma constant 0.0713 is exactly what the deleted taper produced at zero
# travel (capC 0.115 * 0.62), so mono's ramp did not move. Verified at three seeds.
set -l m (__tmux_lives_theme_curve $seed mono bar derived 0)
t "mono bar unchanged by the rewrite"  '#44502f' $m[1]
t "mono tabs unchanged by the rewrite" '#5e7239' $m[2]

# LITERAL — the placed role renders the seed's exact hex.
set -l lb (__tmux_lives_theme_curve $seed coral bar literal 0)
set -l lt (__tmux_lives_theme_curve $seed coral tabs literal 0)
t "curve literal bar = seed"  '#5f772b' $lb[1]
t "curve literal tabs = seed" '#5f772b' $lt[2]

# PHASE — pin the ACTUAL contract, not the spec's earlier (disproven) claim that phase
# rotates all three hues uniformly. The freeze depends on which role is pinned to the
# seed, not on `mode` alone: at `place=bar --mode literal` (exercised below) the endcap
# bridges from the RENDERED bar, which IS the seed hex here, carrying no phase, so the
# cap is FROZEN — a consequence of honouring `literal`, not a bug to "fix". That freeze
# does NOT generalize to every `literal` combination: at `place=tabs --mode literal` the
# tabs carry the seed instead, but the bar the endcap bridges from is still derived, so
# the endcap follows `phase` normally (the entire `chip` tier); at `place=cap --mode
# literal` the cap itself is the seed-pinned anchor (not something read off the bar) and
# freezes the same way `place=bar --mode literal` does. In `derived` mode at any
# placement the anchor role is computed rather than pinned, so it carries `phase` too,
# and the family floor (looked up at that phase-rotated hue) can cross a family band, so
# all three roles move. See docs/superpowers/specs/2026-08-01-theme-big-area-scheme-design.md.
set -l pl0  (__tmux_lives_theme_curve $seed teal bar literal 0)
set -l pl60 (__tmux_lives_theme_curve $seed teal bar literal 60)
t "phase literal: cap is frozen"      $pl0[3] $pl60[3]
t "phase literal: tabs still rotates" 1 (test "$pl0[2]" != "$pl60[2]"; and echo 1; or echo 0)
set -l pd0  (__tmux_lives_theme_curve $seed teal bar derived 0)
set -l pd60 (__tmux_lives_theme_curve $seed teal bar derived 60)
t "phase derived: bar moves"  1 (test "$pd0[1]" != "$pd60[1]"; and echo 1; or echo 0)
t "phase derived: tabs moves" 1 (test "$pd0[2]" != "$pd60[2]"; and echo 1; or echo 0)
t "phase derived: cap moves"  1 (test "$pd0[3]" != "$pd60[3]"; and echo 1; or echo 0)

# bad inputs -> nothing
t "curve bad seed empty" 0 (count (__tmux_lives_theme_curve 'notahex' ember bar derived 0))
t "curve bad rel empty"  0 (count (__tmux_lives_theme_curve $seed nope bar derived 0))

# the taper is gone — grep the SOURCE, not the runtime function table (a `functions -q`
# check would falsely differ between plain fish, which loads the developer's live fisher
# install, and `fish --no-config`, which does not).
t "endcap taper gone" 0 (grep -c '__tmux_lives_theme_taper' $plugindir/conf.d/tmux-lives-install.fish)

# ---- v5: cap placement — the seed on the endcap, the bar solved backwards ----
# The accent-led minority. Neither large area is anchored here; the endcap is.
set -l cp (__tmux_lives_theme_curve $seed amber cap derived 0)
t "cap placement returns 3" 3 (count $cp)
set -l cpo (_oklch_of $cp[3])
set -l cperr (_dhue $cpo[3] $so[3])
t "cap placement: the cap carries the seed hue" 1 (test $cperr -lt 2; and echo 1; or echo 0)
set -l cpl (__tmux_lives_theme_curve $seed coral cap literal 0)
t "cap placement literal = seed exactly" '#5f772b' $cpl[3]
# literal at cap must pin ONLY the cap — the bar is still derived
t "cap placement literal leaves the bar derived" 0 (test "$cpl[1]" = '#5f772b'; and echo 1; or echo 0)
# the bar is solved BACK from the seed by the family separation, so it is NOT at the seed hue
set -l cpb (_oklch_of $cp[1])
set -l cpbd (_dhue $cpb[3] $so[3])
t "cap placement: the bar steps off the seed hue" 1 (test $cpbd -gt 15; and echo 1; or echo 0)
# the cap is the anchor here, so it is the invariant one
set -l capbad 0
for r in mono wheat mint amber sage ember teal coral
    set -l p (__tmux_lives_theme_curve $seed $r cap derived 0)
    set -l o (_oklch_of $p[3])
    set -l d (_dhue $o[3] $so[3])
    test $d -lt 2; or set capbad (math $capbad + 1)
end
t "cap placement: the cap holds the seed hue in every relationship" 0 $capbad
# and the two large areas still sit |sd| apart
set -l cptrav 0
for r in mono wheat mint amber sage ember teal coral
    set -l sd (__tmux_lives_theme_reldef $r)
    set -l p (__tmux_lives_theme_curve $seed $r cap derived 0)
    set -l hb (_oklch_of $p[1])
    set -l ht (_oklch_of $p[2])
    set -l got (_dhue $ht[3] $hb[3])
    set -l want (math "abs($sd)")
    set -l err (math "abs($got - $want)")
    test $err -lt 2; or set cptrav (math $cptrav + 1)
end
t "cap placement: the large areas still sit |sd| apart" 0 $cptrav

# ---- v4: accents + palette ----
set -l pal (__tmux_lives_theme_palette $seed ember bar derived 0)
t "palette returns 7" 7 (count $pal)
for i in 1 2 3 4 5 6 7
    t "palette role $i is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $pal[$i]; and echo 1; or echo 0)
end
# the trio matches the curve for the same inputs (order: bar[1] tabs[3] cap[6])
set -l tri (__tmux_lives_theme_curve $seed ember bar derived 0)
t "palette bar = curve bar"   $tri[1] $pal[1]
t "palette tabs = curve tabs" $tri[2] $pal[3]
t "palette cap = curve cap"   $tri[3] $pal[6]
# windows (status-style fg, on the dark bar) must be light for contrast
set -l wok (_oklch_of $pal[5])
t "palette windows is light" 1 (test $wok[1] -gt 0.60; and echo 1; or echo 0)
t "palette bad seed empty" 0 (count (__tmux_lives_theme_palette nope ember bar derived 0))
# the retired v3 builders are gone — grep the SOURCE file, not the runtime
# function table. A `functions -q` check would falsely fail under plain `fish`
# (which loads the developer's LIVE fisher install of the old code, distinct
# from this branch's source) while passing under `fish --no-config`; grepping
# the source is environment-independent and green under both configs.
t "v3 arc gone"    0 (grep -c '__tmux_lives_theme_arc' $plugindir/conf.d/tmux-lives-install.fish)
t "v3 kincap gone" 0 (grep -c '__tmux_lives_theme_kincap' $plugindir/conf.d/tmux-lives-install.fish)
t "v3 ring gone"   0 (grep -c '__tmux_lives_theme_ring' $plugindir/conf.d/tmux-lives-install.fish)
t "v3 barpos gone" 0 (grep -c '__tmux_lives_theme_barpos' $plugindir/conf.d/tmux-lives-install.fish)
# tmux_lives_theme_rotate must not appear anywhere in the install source EXCEPT
# inside __tmux_lives_migrate_v4's own body (it retires the universal there).
# awk strips the migrate_v4 and migrate_v31 function bodies (their closing
# `end` is unindented, col 0 — nested if/for `end`s inside are indented and
# don't match `^end$`) before grepping what remains. The start pattern is
# anchored with a trailing space so it matches only `__tmux_lives_migrate_v4
# --description`, not `__tmux_lives_migrate_v41 --description` too (an
# unanchored prefix match would otherwise re-trigger the skip range at v41's
# def line and swallow its body as well — harmless for THIS guard today since
# v41 never mentions the rotate universal, but not what the range is meant to
# skip).
t "no rotate universal outside migration" 0 (awk '/^function __tmux_lives_migrate_v4 /,/^end$/ {next} /^function __tmux_lives_migrate_v31/,/^end$/ {next} {print}' $plugindir/conf.d/tmux-lives-install.fish | grep -c 'tmux_lives_theme_rotate')
t "help theme row mentions place" 1 (__tmux_lives_setup_help_lines | string match -q '*place*'; and echo 1; or echo 0)

# v2 engine deletion (task 2): the geometric-harmony cap engine + its CLI are gone —
# only __tmux_lives_theme_* + the OKLCH core + derive_status remain.
t "v2 engine gone from the install file" 0 (grep -cE '__tmux_lives_(palette|target_hue|interp7|rgb_to_ryb_hue|ryb_to_rgb_hue|hsl_hue|hsl_to_rgb|cap_valid|cap_list|cap_picker|cap_apply_live|cap_cmd)\b' $plugindir/conf.d/tmux-lives-install.fish)
t "setup dispatch no longer routes cap" 1 (__tmux_lives_setup_dispatch cap mono 2>/dev/null >/dev/null; echo $status)
# --- v2 -> v3 migration shim -------------------------------------------------
set -g _mig_names tmux_lives_cap tmux_lives_cap_vividness tmux_lives_cap_wheel tmux_lives_cap_role tmux_lives_cap_key tmux_lives_theme_vividness tmux_lives_theme_key
set -g _mig_had
set -g _mig_saved
for n in $_mig_names
    if set -q $n
        set -a _mig_had 1
        set -a _mig_saved "$$n"
    else
        set -a _mig_had 0
        set -a _mig_saved ""
    end
    set -e $n
end
set -U tmux_lives_cap square
set -U tmux_lives_cap_vividness subtle
set -U tmux_lives_cap_wheel ryb
set -U tmux_lives_cap_role dim
set -U tmux_lives_cap_key M-j
set -g MIGOUT (__tmux_lives_migrate_v2)
t "migrate: cap scheme erased" 0 (set -q tmux_lives_cap; and echo 1; or echo 0)
t "migrate: wheel erased" 0 (set -q tmux_lives_cap_wheel; and echo 1; or echo 0)
t "migrate: role erased" 0 (set -q tmux_lives_cap_role; and echo 1; or echo 0)
t "migrate: cap_key erased" 0 (set -q tmux_lives_cap_key; and echo 1; or echo 0)
t "migrate: cap_key -> theme_key" M-j "$tmux_lives_theme_key"
t "migrate: one notice naming the old scheme" yes (string match -q "*cap scheme 'square' has no v3 equivalent*" -- "$MIGOUT"; and echo yes; or echo no)
# v2 no longer writes theme_vividness at all — it is a retired universal (erased,
# not carried, by migrate_v51 if anything ever sets it). A legacy cap_vividness
# must not resurrect it, even transiently within a single migrate_v2 call.
t "migrate: does not resurrect theme_vividness" 0 (set -q tmux_lives_theme_vividness; and echo 1; or echo 0)
# idempotent: a second run is silent and changes nothing
t "migrate: second run silent" 0 (count (__tmux_lives_migrate_v2))
t "migrate: still no theme_vividness after rerun" 0 (set -q tmux_lives_theme_vividness; and echo 1; or echo 0)
# Simulate a legacy install hitting the FULL post-update migration chain (not just
# v2 in isolation): a fresh cap_vividness must never resurrect theme_vividness
# anywhere along v2..v51, and the still-live cap_key -> theme_key carryover must
# keep working alongside it.
set -e tmux_lives_theme_key
set -U tmux_lives_cap_vividness vivid
set -U tmux_lives_cap_key M-j
__tmux_lives_migrate_v2 >/dev/null
__tmux_lives_migrate_v31 >/dev/null
__tmux_lives_migrate_v4 >/dev/null
__tmux_lives_migrate_v41 >/dev/null
__tmux_lives_migrate_v51 >/dev/null
t "migrate chain: legacy cap_vividness never resurrects theme_vividness" 0 (set -q tmux_lives_theme_vividness; and echo 1; or echo 0)
t "migrate chain: cap_key -> theme_key carryover still works" M-j "$tmux_lives_theme_key"
# post_update runs the shim before the re-render
t "post_update calls the shim first" yes (string match -q '*__tmux_lives_migrate_v2*' -- (functions _tmux_lives_post_update | string collect); and echo yes; or echo no)
for i in (seq (count $_mig_names))
    set -e $_mig_names[$i]
    test $_mig_had[$i] -eq 1; and set -U $_mig_names[$i] $_mig_saved[$i]
end

# --- v5 fragment argv: 13 theme(relationship) 14 place 15 mode 16 phase
# (the four knobs — vividness/shape/ease/contrast — are retired as of Task 1;
# see [[theme-engine-v3-gradient-map]]).
set -l fr0 (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k ember bar derived 0 | string collect)
# phase DOES move the curve (bar/tabs/cap hues), so it moves the cap role too.
set -l frp (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k ember bar derived 90 | string collect)
set -l cap0 (string match -r "@tmux_lives_cap_bg '[^']*'" -- "$fr0")
set -l capp (string match -r "@tmux_lives_cap_bg '[^']*'" -- "$frp")
t "fragment phase changes the cap" 0 (test "$cap0" = "$capp"; and echo 1; or echo 0)
# the bar is not the seed verbatim for non-mono relationships in 'derived' mode
# (it's a curve sample) — assert the fragment's status-style bg matches whatever
# the palette actually derives for ember, not the raw seed.
set -l fr0pal (__tmux_lives_theme_palette '#485B3C' ember bar derived 0)
t "fragment bar bg matches the derived bar" 1 (string match -q "*status-style bg=$fr0pal[1]*" -- "$fr0"; and echo 1; or echo 0)
# post_update runs the v3.1 shim right after the v2 shim
t "post_update calls the v31 shim" yes (string match -q '*__tmux_lives_migrate_v31*' -- (functions _tmux_lives_post_update | string collect); and echo yes; or echo no)
# v3.1 migration erases the dead universals (guarded: save/restore around)
set -l _sv_pol; set -q tmux_lives_theme_polarity; and set _sv_pol $tmux_lives_theme_polarity
set -l _sv_rng; set -q tmux_lives_theme_range; and set _sv_rng $tmux_lives_theme_range
set -U tmux_lives_theme_polarity light
set -U tmux_lives_theme_range 0.10,0.90
__tmux_lives_migrate_v31 >/dev/null
t "migrate v31 erases polarity" 0 (set -q tmux_lives_theme_polarity; and echo 1; or echo 0)
t "migrate v31 erases range" 0 (set -q tmux_lives_theme_range; and echo 1; or echo 0)
t "migrate v31 idempotent + quiet" '' (__tmux_lives_migrate_v31 | string collect)
set -q _sv_pol[1]; and set -U tmux_lives_theme_polarity $_sv_pol
set -q _sv_rng[1]; and set -U tmux_lives_theme_range $_sv_rng
# grep-guards: the dead knobs leave zero traces in the install source
set -l src (cat $plugindir/conf.d/tmux-lives-install.fish | string collect)
t "guard: no themepolarity in source" 0 (string match -q '*themepolarity*' -- "$src"; and echo 1; or echo 0)
t "guard: no themerange in source" 0 (string match -q '*themerange*' -- "$src"; and echo 1; or echo 0)
t "guard: no theme_lrange in source" 0 (string match -q '*theme_lrange*' -- "$src"; and echo 1; or echo 0)
t "guard: no --polarity flag in source" 0 (string match -q '*--polarity*' -- "$src"; and echo 1; or echo 0)

# --- v4: migration ----
set -l _m_saved
for v in tmux_lives_theme tmux_lives_theme_rotate tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_bar_color
    set -q $v; and set -a _m_saved "$v=$$v"; set -e $v
end
set -U tmux_lives_bar_color '#5f772b'
set -U tmux_lives_theme complement   # a retired v3 scheme
set -U tmux_lives_theme_rotate 3
__tmux_lives_migrate_v4 >/dev/null
t "migrate keeps seed"    "#5f772b" $tmux_lives_bar_color
t "migrate resets scheme" mono      $tmux_lives_theme
t "migrate sets place"    bar       $tmux_lives_theme_place
t "migrate sets mode"     derived   $tmux_lives_theme_mode
t "migrate erases rotate" 0         (set -q tmux_lives_theme_rotate; and echo 1; or echo 0)
# idempotent-quiet: a second run right after the retired-scheme migration
# above (complement -> mono already landed) prints no notice
t "migrate v4 second run silent" '' (__tmux_lives_migrate_v4 | string collect)
# idempotent: a valid v4 relationship is left alone
set -U tmux_lives_theme ember
__tmux_lives_migrate_v4 >/dev/null
t "migrate leaves v4 rel" ember $tmux_lives_theme
# 'off' is left alone entirely — no scheme reset, and place/mode never get set
set -e tmux_lives_theme_place tmux_lives_theme_mode
set -U tmux_lives_theme off
__tmux_lives_migrate_v4 >/dev/null
t "migrate leaves off alone"       off $tmux_lives_theme
t "migrate off: place stays unset" 0   (set -q tmux_lives_theme_place; and echo 1; or echo 0)
set -e tmux_lives_theme tmux_lives_theme_rotate tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_bar_color
for kv in $_m_saved
    set -l p (string split '=' $kv); set -U $p[1] $p[2]
end

# --- v4.1: place low/high retirement ---------------------------------------------
set -U tmux_lives_theme_place low
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: low -> bar" bar $tmux_lives_theme_place
set -U tmux_lives_theme_place high
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: high -> bar" bar $tmux_lives_theme_place
set -U tmux_lives_theme_place tabs
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: tabs is left alone" tabs $tmux_lives_theme_place
set -U tmux_lives_theme_place cap
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: cap is left alone" cap $tmux_lives_theme_place
set -U tmux_lives_theme_place low
__tmux_lives_migrate_v41 >/dev/null
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41 is idempotent" bar $tmux_lives_theme_place
set -e tmux_lives_theme_place
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: an unset place stays unset" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "post-update runs migrate v41" 1 (awk '/^function _tmux_lives_post_update/,/^end$/' $plugindir/conf.d/tmux-lives-install.fish | grep -c '__tmux_lives_migrate_v41')
t "help place row drops low/high" 0 (__tmux_lives_setup_help_lines | string match -q '*low|high*'; and echo 1; or echo 0)
# The retired tokens survive ONLY inside the migration that retires them. awk strips
# that function body (its closing `end` is unindented at column 0; nested if/for `end`s
# are indented and do not match) before grepping what remains. Two shapes are banned:
# the switch form `low high` and the help/error form `low|high`.
# NB this grep matches COMMENTS too — if you need to explain the retirement anywhere
# else in the install file, describe it, don't spell either shape out.
t "no low/high switch token outside the migration" 0 (awk '/^function __tmux_lives_migrate_v41/,/^end$/ {next} {print}' $plugindir/conf.d/tmux-lives-install.fish | grep -c 'low high')
t "no low/high help token outside the migration"   0 (awk '/^function __tmux_lives_migrate_v41/,/^end$/ {next} {print}' $plugindir/conf.d/tmux-lives-install.fish | grep -cF 'low|high')

# --- Gallery picker rewrite, Task 5: the list went from a fixed 6-row
# relationship list to a WINDOWED WIN=8 scheme list (Tasks 2-4), so the frame
# grew from 22 to 24 rows — 16 static chrome/off/anchor rows + WIN=8 scheme
# rows, a CONSTANT total regardless of the 12-vs-28 catalog size — recounted
# directly off the draw loop's `set -a lines` call sites. Picker current-zone
# + legend-grid refinement, Task 3 (2026-07-25): the current zone's own
# `├─ current ─┤` zsep (+1) and the legend grid's 2->3-row growth (+1) grew
# the frame AGAIN, 24->26 rows (18 static + WIN=8). 52x26 popup geometry at
# every open site; guard every stale height (27 was the v3.1/Phase-2-Tasks-
# 1-4 value, 24 was this task's own pre-current-zone/legend-grid value, 22
# was the pre-windowing value, 20 an even older stray).
# picker-seed-section Task 1 (2026-08-07): 26 was itself a FIXED number,
# which cannot survive a client shorter than it (a popup taller than the
# client refuses to open on 3.3a — no clamp). -h is now a percentage at
# every open site and the scheme window is derived from the popup's own
# reported size at open time, so 26 joins 27/24/22/20 as a stale literal. ---
t "fragment theme-picker bind is 52 wide, height is a percentage" 1 (string match -q '*-w 52 -h 85%*theme-picker*' -- "$fr0"; and echo 1; or echo 0)
t "install: no stale theme popup height (26)" 0 (string match -q '*-w 52 -h 26*' -- "$src"; and echo 1; or echo 0)
t "install: no stale theme popup height (27)" 0 (string match -q '*-w 52 -h 27*' -- "$src"; and echo 1; or echo 0)
t "install: no stale theme popup height (24)" 0 (string match -q '*-w 52 -h 24*' -- "$src"; and echo 1; or echo 0)
t "install: no stale theme popup height (22)" 0 (string match -q '*-w 52 -h 22*' -- "$src"; and echo 1; or echo 0)
t "install: no stale theme popup height (20)" 0 (string match -q '*-w 52 -h 20*' -- "$src"; and echo 1; or echo 0)

t "setup help no longer lists cap" no (string match -q '*cap [<scheme>]*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)

# --- v3.3 Task 2: the ✦ mark is the seed's home base; claude window coloring
# is removed. Reuse $fr0 (already the ember/bar/derived/balanced/arc/linear/auto
# render from the v4 fragment argv section above) and $src (the full source text).
t "fragment mark_fg is the seed verbatim" 1 (string match -q "*@tmux_lives_mark_fg '#485b3c'*" -- "$fr0"; and echo 1; or echo 0)
t "fragment window-status-format is plain (v3.3 render)" 1 (string match -q "*set -g window-status-format '#W'*" -- "$fr0"; and echo 1; or echo 0)
t "fragment drops claude_color" 0 (string match -q '*claude_color*' -- "$fr0"; and echo 1; or echo 0)
t "guard: no claude_color in install source" 0 (string match -q '*claude_color*' -- "$src"; and echo 1; or echo 0)
t "guard: _th_names covers theme_place" 1 (contains tmux_lives_theme_place $_th_names; and echo 1; or echo 0)
t "guard: _th_names covers theme_mode" 1 (contains tmux_lives_theme_mode $_th_names; and echo 1; or echo 0)

# --- universal-variable isolation (2026-07-25) ---------------------------
# The suite drives the real CLI, which really does `set -U`. Without the
# re-exec guard at the top of this file those writes hit the user's live
# ~/.config/fish/fish_variables. These assertions prove the guard is active;
# if it ever regresses they fail instead of silently eating the user's config.
t "isolation: guard sentinel is set" 1 (set -q TMUX_LIVES_TEST_UVARS; and echo 1; or echo 0)
t "isolation: sentinel matches XDG_CONFIG_HOME" 1 (test "$TMUX_LIVES_TEST_UVARS" = "$XDG_CONFIG_HOME"; and echo 1; or echo 0)
t "isolation: store is not the real config dir" 1 (test "$XDG_CONFIG_HOME" != "$HOME/.config"; and echo 1; or echo 0)

set -U tmux_lives_isolation_probe probe-(random)
# Holds in BOTH fish modes and is the assertion that actually matters.
t "isolation: probe never reaches the real store" 0 (grep -q tmux_lives_isolation_probe $HOME/.config/fish/fish_variables 2>/dev/null; and echo 1; or echo 0)
# `fish --no-config` persists NO universals at all, so only assert the probe
# landed in the temp store when running under a config-loaded fish.
if test (count $fish_function_path) -gt 0
    t "isolation: probe landed in the temp store" 1 (grep -q tmux_lives_isolation_probe $XDG_CONFIG_HOME/fish/fish_variables 2>/dev/null; and echo 1; or echo 0)
end
set -e tmux_lives_isolation_probe

# --- Task 1: the idle predicate ---------------------------------------------
t "is_idle: function exists" 1 (functions -q __tmux_lives_shell_is_idle; and echo 1; or echo 0)
# No controlling tty -> tpgid is -1 -> must report NOT idle. "Unsure" has to mean
# "do not print", because every wrong answer here corrupts someone's editor frame.
set -g __t1_notty (fish --no-config -c "set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo IDLE; or echo BUSY" 2>/dev/null)
t "is_idle: no controlling tty reports BUSY" BUSY "$__t1_notty"

# At a prompt the shell owns the tty; inside a foreground child it does not.
# `timeout` is mandatory: an interactive fish outlives its -C command and a
# bare wait would hang the suite.
set -g __t1_pty (timeout 20 script -qfec "fish --no-config -i -C 'set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo AT-PROMPT-IDLE; or echo AT-PROMPT-BUSY; exit'" /dev/null 2>/dev/null | tr -d '\r')
t "is_idle: at a prompt with a tty reports IDLE" 1 (string match -q '*AT-PROMPT-IDLE*' -- "$__t1_pty"; and echo 1; or echo 0)

test $fail -eq 0; and echo "ALL PASS ($pass)"; or begin; echo "FAILED ($fail)"; exit 1; end
