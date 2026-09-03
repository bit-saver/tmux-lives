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

# I-3 (whole-branch review): protect two REAL host files this suite must never write
# to from any future call site that forgets to seam its path -- both have already
# been hit by exactly that class of bug once (the funcs-file truncation caught in
# the Task 4 review, C-1; the fish-history leak caught here as I-1). The isolation
# guard above only redirects $XDG_CONFIG_HOME (the universal-variable store); $HOME
# itself is untouched, so both of these real paths resolve the same way inside this
# run as outside it -- which is exactly why they need their own protection.
#
# REWORKED 2026-08-19: the original version md5'd the whole file at start and end and
# asserted byte-identity. That measures "did the file's overall state change", not "did
# THIS SUITE write here" -- and the developer works continuously in other panes while
# this ~90s suite runs, so fish_history gets a new line from typing that has nothing to
# do with this run. The guard failed at random with nothing wrong (e.g. got
# [dc0700147a24384011044225adc0731f]), each time costing a real investigation before
# being dismissed -- the exact "trains a re-run-until-green reflex" failure mode this
# repo's own notes warn about, and worse than no guard because the next REAL leak would
# get waved through too. Fixed by checking this run's OWN FOOTPRINT instead.
#
# fish_history: every fixture this suite creates is named /tmp/tli-<label>-$fish_pid (grep
# this file -- dozens of call sites all share that shape). $fish_pid is this process's own
# pid, unique to this run; it cannot appear in the file unless something IN THIS RUN typed
# a command naming one of its own fixtures -- which is exactly the shape of the leak that
# hit 99 times before (a send-keys command landing in a real, unseamed XDG_DATA_HOME, see
# I-1 below). A human typing in another pane cannot produce that string, so this is
# specific to the suite without losing sensitivity to the leak it exists to catch --
# though "without losing sensitivity" overstates it: this greps for the literal
# "tli-...$fish_pid" shape, so a future leak whose command text carries no fixture
# name would be invisible to it. Both current send-keys payloads this suite guards
# against embed such a path, so it discriminates today, but a new leaky call site
# with different wording would slip past silently.
function __ti_guard_history_ok --argument-names p --description 'true (rc0) unless p carries a fixture trace from THIS run. A MISSING file (fresh box, no shell history yet) is fine, not a failure -- there is nothing there for this run to have leaked into, same as empty==empty under the md5 check this replaced.'
    test -f "$p"; or return 0
    not grep -qE -- "tli-[A-Za-z0-9_.-]*$fish_pid" "$p" 2>/dev/null
end

# tmux-lives-funcs is a different shape: it is not appended to, it is unconditionally
# OVERWRITTEN by __tmux_lives_write_funcs with __tmux_lives_shipped_functions's whole
# output, so there is no per-run fixture string to grep for the way there is in a log.
# But its failure mode is just as specific: __tmux_lives_shipped_functions falls back to
# $__fish_config_dir when unseamed, which under this suite's own outer XDG_CONFIG_HOME
# re-exec resolves inside this run's throwaway temp dir -- no conf.d there to read -- so
# an unseamed write FROM THIS SUITE always truncates the file near-empty. That is exactly
# the shape the Task-4 C-1 bug produced. A genuinely concurrent legitimate write (the
# human running a real `fisher update`/`tmux-lives update` on this machine mid-suite)
# always yields a healthy list (currently ~215 lines; elsewhere in this suite this file's
# own content is asserted >20), so it cannot trip a floor check -- only an actual
# suite-caused truncation can. 50 is comfortably below any real list and comfortably
# above the near-empty truncation the bug produced.
function __ti_guard_funcs_ok --argument-names p existed_before --description 'true (rc0) unless p (which existed_before) went missing or was truncated by THIS run'
    if test "$existed_before" != 1
        return 0
    end
    test -f "$p"; or return 1
    set -l n (count (string split \n -- (cat "$p" 2>/dev/null)))
    test "$n" -ge 50
end
set -g __ti_guard_funcs "$HOME/.config/tmux/tmux-lives-funcs"
set -g __ti_guard_history "$HOME/.local/share/fish/fish_history"
set -g __ti_guard_funcs_existed_before (test -f "$__ti_guard_funcs"; and echo 1; or echo 0)

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

# --- sync terminal-feature (arg 18) ------------------------------------------------
# tmux decides PER CLIENT, at attach, whether a terminal can buffer synchronized output,
# and it decides from its own terminal identification — it never asks the client. It
# recognises Ghostty but not ShellFish, so it wrote every Claude frame unwrapped and
# ShellFish painted ~21 cursor hide/show pairs a second (the 2026-08-06 strobing).
# Telling tmux the terminal can sync is the fix. GATED to tmux >= 3.7: only there does
# the capability map to DECSET 2026 (3.3a emits the older iTerm2 DCS form), and only
# there can the bug occur — 3.3a never answers the DECRQM query, so Claude never turns
# sync on. See [[shellfish-cursor-flicker]].
set -g SYNCBASE /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep
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

# --- Task 1 (v5): knobs removed, sync arg renumbered 21 -> 17. Theme v6 surface
# Task 3 renumbered it AGAIN, 17 -> 18: the v5 four-field theme (theme/place/mode/
# phase) grew to the v6 five-field recipe (theme/lspan/peakc/peakpos/arrangement),
# pushing syncterm one further right. Pre-change (this mutation), position 18 is
# arrangement and syncterm is empty, so NO sync line is emitted — that is the
# failure this pins. A silently-disabled sync feature has no rc and no visible symptom.
set -g FRAG17 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep 'xterm*' | string collect)
t "sync is positional 18 after the v6 recipe adds a fifth theme field" yes (string match -q "*set -as terminal-features 'xterm*:sync'*" -- "$FRAG17"; and echo yes; or echo no)

# --- theme-v6-surface Task 3: the fragment carries a v6 recipe ------------------
# argv 18 is syncterm — it MOVED from 17 when the recipe grew from four fields
# to five. A renderer/writer mismatch here is silent, so pin the position and
# pin that the line it drives still appears.
set -g A6FRAG (__tmux_lives_render_fragment /tmp/cat.fish S M-s '#5fab40' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep 'xterm*')
t "fragment: syncterm at argv 18 still emits the sync feature line" 1 (string match -q '*xterm*:sync*' -- "$A6FRAG"; and echo 1; or echo 0)
t "fragment: a themed render sets status-style from the v6 palette" 1 (string match -q '*set -g status-style bg=#434841*' -- "$A6FRAG"; and echo 1; or echo 0)
# NB the brief's own pattern omits the single-quoting the codebase requires around
# every color @option (an unquoted #hex is read as a tmux COMMENT — see the
# "QUOTE the values" note above __tmux_lives_render_fragment's @tmux_lives_bar_bg
# line); a bare `#434841` with no quotes never appears in the real output, so the
# pattern below carries the quotes the emitted line actually has.
t "fragment: the recipe reaches the bar bg option" 1 (string match -q "*@tmux_lives_bar_bg '#434841'*" -- "$A6FRAG"; and echo 1; or echo 0)
# An empty mode still means legacy, exactly as an empty relationship did.
set -g A6FRAGOFF (__tmux_lives_render_fragment /tmp/cat.fish S M-s '#5fab40' 0 M-m M-t M-r C-M-a C-M-s block M-k off 0.55 0.11 0.50 deep 'xterm*')
# Same quoting correction as above — an unquoted pattern would never match ANY
# real output (themed or not) and this "0" would pass vacuously for the wrong
# reason, proving nothing about the off-path specifically.
t "fragment: theme off still takes the legacy path" 0 (string match -q "*@tmux_lives_bar_bg '#434841'*" -- "$A6FRAGOFF"; and echo 1; or echo 0)
t "fragment: theme off still emits the sync feature line" 1 (string match -q '*xterm*:sync*' -- "$A6FRAGOFF"; and echo 1; or echo 0)

# --- picker-seed-section Task 1: the picker opens at a percentage height, not a fixed 26 ----------
# A popup taller than the client FAILS to open on tmux 3.3a ("height too large") —
# it does not clamp. So the height must be a percentage, which always fits.
set -g FRAGH (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep 'xterm*' | string collect)
t "theme-picker bind uses a percentage height" yes (string match -q '*-w 52 -h 85%*' -- "$FRAGH"; and echo yes; or echo no)
t "theme-picker bind no longer pins 26 rows" no (string match -q '*-w 52 -h 26*' -- "$FRAGH"; and echo yes; or echo no)

# The engine must produce the SAME colours as before — this is a refactor, not a
# derivation change. Pinned as literal hexes so it cannot drift silently.
set -g P5 (__tmux_lives_theme_palette '#5f772b' amber bar derived 0)
t "palette still returns 7 roles from 5 args" 7 (count $P5)
t "palette bar unchanged by the refactor" '#44502f' $P5[1]

# apply_live's explicit form is now exactly 5 args (the v6 recipe).
t "apply_live explicit form documents 5 args" yes (string match -q '*5 args*' -- (functions __tmux_lives_theme_apply_live | string collect); and echo yes; or echo no)

# --- theme-v6-surface Task 4: apply_live and theme list render v6 ------------------
# The suite runs under a redirected XDG_CONFIG_HOME with no universals, so
# tmux_lives_bar_color reads EMPTY and apply_live would take its legacy branch —
# nothing to do with this change. Shadow the seed for this block only (a `set -g`
# beats a `set -U` read for this process, the same mechanism the picker's seed
# preview already relies on).
set -g tmux_lives_bar_color '#5fab40'
set -g A6SOCK "tl6-$fish_pid"
command tmux -f /dev/null -L $A6SOCK new-session -d -s probe -c $HOME 'sleep 60' 2>/dev/null
set -g tmux_lives_tmux_socket $A6SOCK
__tmux_lives_theme_apply_live mono 0.55 0.11 0.50 deep
t "apply_live: 5 args push the v6 palette's bar" '#434841' (command tmux -L $A6SOCK show -gv @tmux_lives_bar_bg 2>/dev/null)
t "apply_live: 5 args push the v6 palette's cap" '#638557' (command tmux -L $A6SOCK show -gv @tmux_lives_cap_bg 2>/dev/null)
t "apply_live: 5 args push the v6 palette's tabs" '#53654d' (command tmux -L $A6SOCK show -gv @tmux_lives_tabs_color 2>/dev/null)
t "apply_live: the mark stays the seed verbatim" (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color '')) (command tmux -L $A6SOCK show -gv @tmux_lives_mark_fg 2>/dev/null)
t "list v6: one line per catalog row" 42 (__tmux_lives_theme_list | count)
# NB the brief's own pattern uses CAPTURING groups, which fish's `string match -r`
# prints as extra output lines (whole match + each group) — 3 lines per input line
# here, so the brief's literal pattern counts 126, not 42. Non-capturing groups
# (?:...) keep the count at one line per match, which is what "one per catalog
# row" actually means.
t "list v6: every line names its scheme" 42 (__tmux_lives_theme_list | string match -r '(?:mono|analogous|complementary|split|triadic|tetradic|square) (?:deep|bright|centre|split|stack|accent)' | count)
command tmux -L $A6SOCK kill-server 2>/dev/null
set -e tmux_lives_tmux_socket
set -e tmux_lives_bar_color

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
# _tmux_lives_post_update calls __tmux_lives_write_funcs UNCONDITIONALLY, and its default
# path falls back to the REAL $HOME/.config/tmux/tmux-lives-funcs -- this seam is what
# keeps every direct call below off the real host file (see C-1 in the Task 4 review).
set -g tmux_lives_funcs_file /tmp/tli-pufrag-funcs-$fish_pid
rm -f $tmux_lives_fragment_file $tmux_lives_funcs_file
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
rm -f $tmux_lives_fragment_file $tmux_lives_funcs_file
set -e tmux_lives_fragment_file
set -e tmux_lives_funcs_file

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

# _tmux_lives_post_update calls __tmux_lives_write_funcs UNCONDITIONALLY, and its default
# path falls back to the REAL $HOME/.config/tmux/tmux-lives-funcs -- seamed here for every
# direct call in this whole section (through the end-to-end wrapper cases below), not just
# the ones a reviewer happened to name (see C-1 in the Task 4 review: an unseamed call here
# silently truncates the real ~209-name record, defeating removal-detection on a live host).
set -g tmux_lives_funcs_file /tmp/tli-pu-funcs-$fish_pid
rm -f $tmux_lives_funcs_file

# I-2 (whole-branch review): __tmux_lives_stale_sessions (called both directly by
# _tmux_lives_post_update below and via __tmux_lives_update -> __tmux_lives_update_note
# in the e2e cases further down) has no test seam of its own -- the ONE seam that
# exists, tmux_lives_tmux_socket, is BROKEN (conf.d/tmux-lives-install.fish:1209 builds
# `set -l tm "command tmux -L $sock"` as a single quoted string, and fish does not
# word-split it, so `$tm list-panes ...` tries to run a command literally named
# "command tmux -L <sock>" and fails with "Unknown command" -- confirmed, and isolated
# to this one function; every other seam site in the file uses the correct
# `if set -q ...; and set tm "command tmux -L $sock"` form split across two lines). So
# every call in this whole section queries the REAL default tmux server. On a clean
# host, in CI, or any time `tmux kill-server` has been run, that returns nothing, and
# the note's entire "Other shells ..." line goes missing -- failing three positive
# assertions below outright and making two negative ones pass VACUOUSLY (nothing
# printed, not "the right thing was printed and this phrase wasn't in it"). Fixed the
# test-only way, per the review: stub the wrapper with a fixed, host-independent
# two-name list for this whole block, restored once the block is done.
functions -c __tmux_lives_stale_sessions __tl_ss_bak 2>/dev/null
function __tmux_lives_stale_sessions
    printf '%s\n' alpha beta
end

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
# Under the flag the handler hands its verdict to the wrapper via a plain global
# instead of printing -- confirm it actually got set, then clear it so it can't
# leak into anything below (mirrors how _tmux_lives_updating itself is cleared).
t "post-update: hands autoreloaded to the wrapper via a plain global" 1 (set -q _tmux_lives_autoreloaded; and echo 1; or echo 0)
set -e _tmux_lives_autoreloaded
set -e _tmux_lives_updating

# ---------------------------------------------------------------------
# End-to-end: __tmux_lives_update (the `tmux-lives update` wrapper) must ALSO
# report the handler's autoreload verdict in the note IT prints -- not just the
# generic one _tmux_lives_post_update prints directly (proven above). Before
# this fix the wrapper always called __tmux_lives_update_note with only 3 args,
# so even though the token bump (and therefore the real auto-reload in other
# shells) happens unconditionally inside the handler, the wrapper's own note
# kept telling the user to restart shells that had already refreshed.
#
# Real fisher emits the update event SYNCHRONOUSLY, in the same shell, mid-
# `fisher update` -- so these fisher stubs call the REAL _tmux_lives_post_update
# themselves to reproduce that, rather than asserting on the carrier variable in
# isolation. __tmux_lives_write_fragment is still the no-op stub from above;
# tmux_lives_funcs_file is still the seam set above this whole section, so
# __tmux_lives_write_funcs (unconditional, inside the handler) never touches the
# real ~/.config/tmux/tmux-lives-funcs here either.

# Case 1: a token already exists (other shells carry the handler) and the
# update genuinely changes the watched files -- the wrapper's note must say
# so, in the qualified wording (never the unqualified "refreshed", which is
# the whole reason this task exists: a busy pane hasn't re-sourced yet).
set -g tmux_lives_update_files /tmp/tli-upd-e2e1-$fish_pid
printf 'one\n' > $tmux_lives_update_files
set -U tmux_lives_reload_token (__tmux_lives_digest $tmux_lives_update_files)
function fisher
    printf 'two\n' >> $tmux_lives_update_files
    _tmux_lives_post_update >/dev/null 2>&1
end
set -l u_e2e1 (__tmux_lives_update | string collect)
t "wrapper e2e: token pre-existing + real change -> reports auto-refresh" 1 (string match -q '*refreshed automatically*' -- "$u_e2e1"; and echo 1; or echo 0)
# Precondition for the negative check below (I-2): without this, an empty stale-
# sessions list (real tmux, no server/panes) would make the whole "Other shells"
# line vanish, and the negative check would pass for the wrong reason -- nothing
# printed at all, not the right thing printed minus this one phrase.
t "wrapper e2e: note actually names the stale sessions (precondition)" 1 (string match -q '*alpha*' -- "$u_e2e1"; and echo 1; or echo 0)
t "wrapper e2e: does not send you to restart shells that already refreshed" 0 (string match -q '*in each*' -- "$u_e2e1"; and echo 1; or echo 0)
t "wrapper e2e: carrier does not leak past the call" 0 (set -q _tmux_lives_autoreloaded; and echo 1; or echo 0)
functions -e fisher
set -e tmux_lives_reload_token
set -e tmux_lives_update_files
rm -f /tmp/tli-upd-e2e1-$fish_pid

# Case 2: the WRAPPER's own before/after digest sees a real change (so it still
# prints a note), but the HANDLER's own digest check finds nothing NEW relative
# to the already-stored token (pre-seeded here to match what the file is about
# to become, as if a previous run had already recorded it) -- so no NEW
# auto-reload signal actually went out. The note must still give the old
# advice: the carrier must not go stale and falsely claim a refresh just
# because *something* changed and a note got printed.
set -g tmux_lives_update_files /tmp/tli-upd-e2e2-$fish_pid
printf 'aaa\n' > $tmux_lives_update_files
printf 'bbb\n' >> $tmux_lives_update_files
set -l e2e2_y (__tmux_lives_digest $tmux_lives_update_files)
set -U tmux_lives_reload_token $e2e2_y   # pre-caught-up
printf 'aaa\n' > $tmux_lives_update_files   # revert so the wrapper's before != after
function fisher
    printf 'bbb\n' >> $tmux_lives_update_files   # aaa -> aaa+bbb again, mid "update"
    _tmux_lives_post_update >/dev/null 2>&1
end
set -l u_e2e2 (__tmux_lives_update | string collect)
t "wrapper e2e: no-new-change case still reports the update happened" 1 (string match -q '*updated*' -- "$u_e2e2"; and echo 1; or echo 0)
t "wrapper e2e: no-new-change case keeps the old exec-fish advice"    1 (string match -q '*in each*' -- "$u_e2e2"; and echo 1; or echo 0)
# Precondition for the negative check below (I-2) -- see Case 1's comment above.
t "wrapper e2e: no-new-change note actually names the stale sessions (precondition)" 1 (string match -q '*alpha*' -- "$u_e2e2"; and echo 1; or echo 0)
t "wrapper e2e: no-new-change case does not claim a refresh"          0 (string match -q '*refreshed automatically*' -- "$u_e2e2"; and echo 1; or echo 0)
t "wrapper e2e: token truly unchanged (no NEW auto-reload signal)"    "$e2e2_y" "$tmux_lives_reload_token"
functions -e fisher
set -e tmux_lives_reload_token
set -e tmux_lives_update_files
rm -f /tmp/tli-upd-e2e2-$fish_pid

# Case 3: the universal opt-out (tmux_lives_autoreload = 0) is set -- shared by
# every one of the user's shells, including this one, per
# __tmux_lives_shell_reload. A real digest change still flows through the real
# handler and the token still bumps (harmless: every handler no-ops on it while
# opted out), but NO shell's handler will actually re-source while it's active,
# so the note must not claim one did. Reproduced by the Task 4 review: before
# this fix the wrapper still printed "refreshed automatically" here.
set -U tmux_lives_autoreload 0
set -g tmux_lives_update_files /tmp/tli-upd-e2e3-$fish_pid
printf 'one\n' > $tmux_lives_update_files
set -U tmux_lives_reload_token (__tmux_lives_digest $tmux_lives_update_files)
function fisher
    printf 'two\n' >> $tmux_lives_update_files
    _tmux_lives_post_update >/dev/null 2>&1
end
set -l u_e2e3 (__tmux_lives_update | string collect)
set -l e2e3_new (__tmux_lives_digest $tmux_lives_update_files)
# Precondition for the negative check below (I-2) -- see Case 1's comment above.
t "wrapper e2e: opted-out note actually names the stale sessions (precondition)" 1 (string match -q '*alpha*' -- "$u_e2e3"; and echo 1; or echo 0)
t "wrapper e2e: opted out -> does not claim a refresh"       0 (string match -q '*refreshed automatically*' -- "$u_e2e3"; and echo 1; or echo 0)
t "wrapper e2e: opted out -> keeps the old exec-fish advice" 1 (string match -q '*in each*' -- "$u_e2e3"; and echo 1; or echo 0)
t "wrapper e2e: opted out -> token still bumps (harmless)"   "$e2e3_new" "$tmux_lives_reload_token"
functions -e fisher
set -e tmux_lives_autoreload
set -e tmux_lives_reload_token
set -e tmux_lives_update_files
rm -f /tmp/tli-upd-e2e3-$fish_pid

set -e tmux_lives_funcs_file
rm -f /tmp/tli-pu-funcs-$fish_pid

# Restore the real __tmux_lives_stale_sessions (I-2 stub) now that the post-update
# note tests are done.
functions -e __tmux_lives_stale_sessions
functions -c __tl_ss_bak __tmux_lives_stale_sessions
functions -e __tl_ss_bak

# --- the tmux_lives_tmux_socket seam actually works here ---------------------
# It did not. The function built `set -l tm "command tmux -L $sock"` as ONE
# STRING and then ran `$tm list-panes`; fish does not word-split, so the whole
# string became the command name and every seamed call died with
# `Unknown command: 'command tmux -L …'` plus a stack trace to stderr, returning
# empty. Every OTHER seam site in this file uses the correct `if set -q` form, so
# this one function was the odd one out -- and it is the only mechanism that can
# point stale-session detection at a test server instead of the user's real one.
# TWO sessions, deliberately. With only one, `display-message -p '#{pane_pid}'`
# on an unattached server returns that sole session's own pane pid, so the
# function correctly excludes it as "ours" and reports nothing — which looks
# like the seam failing when it is actually working.
set -g __ti_seam_sock tli-seam-$fish_pid
command tmux -L $__ti_seam_sock -f /dev/null new-session -d -s SeamProbe 'sleep 120' 2>/dev/null
command tmux -L $__ti_seam_sock new-session -d -s SeamOther 'sleep 120' 2>/dev/null
set -g tmux_lives_tmux_socket $__ti_seam_sock

# 1. It must not spray fish diagnostics. A real child process is needed to
#    capture them: an in-process 2> redirect does not catch fish's own errors.
set -g __ti_seam_err (fish --no-config -c "set -g tmux_categorize_test 1
    source $plugindir/conf.d/tmux-lives-install.fish
    set -g tmux_lives_tmux_socket $__ti_seam_sock
    __tmux_lives_stale_sessions" 2>&1 >/dev/null | string collect)
t "seam: stale_sessions produces no fish diagnostics when seamed" "" "$__ti_seam_err"

# 2. And it must actually reach the seamed server. Asking for panes other than
#    our own on a server whose only pane IS ours yields nothing, so the positive
#    signal is that the call succeeds and the session is visible to that socket.
set -g __ti_seam_sees (command tmux -L $__ti_seam_sock list-sessions -F '#{session_name}' 2>/dev/null | sort | string join ',')
t "seam: the probe server is reachable on the seamed socket" SeamOther,SeamProbe "$__ti_seam_sees"
set -g __ti_seam_out (__tmux_lives_stale_sessions 2>/dev/null | string collect)
t "seam: stale_sessions reaches the SEAMED server, not the real one" 1 (string match -qr 'Seam(Probe|Other)' -- "$__ti_seam_out"; and echo 1; or echo 0)
# And it must NOT be quietly reporting the user's real server instead — the
# failure this whole fix exists to prevent was a seam that silently did nothing.
t "seam: no session from the real default server leaks in" 0 (string match -q '*Checkup*' -- "$__ti_seam_out"; and echo 1; or echo 0)

set -e tmux_lives_tmux_socket
command tmux -L $__ti_seam_sock kill-server 2>/dev/null

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
# --- theme engine v6 (theme-v6-surface Task 3): fragment renders the recipe roles ----
# theme OFF (argv 18 absent): v2 values + neutral role seeds
set -g TOFF (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k | string collect)
t "off: v2 status-style survives" yes (string match -q '*set -g status-style bg=#*' -- "$TOFF"; and echo yes; or echo no)
t "off: sep_fg seeded default"  yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: text_fg seeded default" yes (string match -q '*set -g @tmux_lives_text_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: mark_fg seeded default" yes (string match -q '*set -g @tmux_lives_mark_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: active_fg seeded default" yes (string match -q '*set -g @tmux_lives_active_fg default*' -- "$TOFF"; and echo yes; or echo no)
t "off: cap is the legacy neutral (v2 engine gone)" yes (string match -q "*set -g @tmux_lives_cap_bg 'colour238'*" -- "$TOFF"; and echo yes; or echo no)
# theme ON: every role @option carries its v6 recipe sample ('mono deep' = the
# migration default, measured at this seed via __tmux_lives_theme_render)
set -g TON (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep | string collect)
set -g TONPAL (__tmux_lives_theme_render "#485b3c" mono 0.55 0.11 0.50 deep)
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
# v6 has no v5-style hue phase; peakpos (argv 16) is the recipe field that moves the
# ramp — and with it the whole downstream palette, cap included — while mode/lspan/
# peakc/arrangement stay fixed.
set -g TONK (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.20 deep | string collect)
set -g TONKPAL (__tmux_lives_theme_render "#485b3c" mono 0.55 0.11 0.20 deep)
t "on: peakpos reaches the palette" yes (string match -q "*set -g @tmux_lives_cap_bg '$TONKPAL[6]'*" -- "$TONK"; and echo yes; or echo no)
# a theme with an unusable seed falls back to the whole v2 path
set -g TBAD (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono | string collect)
t "on+no seed: v2 fallback cap" yes (string match -q "*set -g @tmux_lives_cap_bg 'colour238'*" -- "$TBAD"; and echo yes; or echo no)
t "on+no seed: role seeds default" yes (string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TBAD"; and echo yes; or echo no)
# 'off' token renders the legacy branch; write_fragment's default is mono
set -g TOFFTOK (__tmux_lives_render_fragment /x/cat.fish S M-s "#485b3c" 0 M-m M-t M-r C-M-a C-M-s block M-k off | string collect)
t "off token renders legacy status-style" yes (string match -q '*set -g status-style bg=#*' -- "$TOFFTOK"; and string match -q '*set -g @tmux_lives_sep_fg default*' -- "$TOFFTOK"; and echo yes; or echo no)
t "off token renders legacy cap" yes (string match -q "*set -g @tmux_lives_cap_bg '*" -- "$TOFFTOK"; and echo yes; or echo no)
t "write_fragment defaults the theme to mono" yes (string match -q '*tmux_lives_theme mono*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_key" yes (string match -q '*tmux_lives_theme_key M-k*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_lspan" yes (string match -q '*tmux_lives_theme_lspan 0.55*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_peakc" yes (string match -q '*tmux_lives_theme_peakc 0.11*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_peakpos" yes (string match -q '*tmux_lives_theme_peakpos 0.50*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment passes theme_arrangement" yes (string match -q '*tmux_lives_theme_arrangement deep*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)
t "write_fragment has no rotate arg leakage" no (string match -q '*theme_rotate*' -- (functions __tmux_lives_write_fragment | string collect); and echo yes; or echo no)

# --- write_fragment's call-site ARGUMENT ORDER must match render_fragment's
# positional reads. The existence-only checks just above (943-947) only prove each
# lookup is PRESENT somewhere in the source — they cannot see a shift. Proven by
# mutation: re-inserting a single extra (__tmux_lives_key ...) lookup ahead of the
# tmux_lives_sync_terminals one shifts syncterm from position 18 to 19; the
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

t "write_fragment's call site passes exactly 18 args to render_fragment" 18 (count $_WF17_ARGV)
t "write_fragment's call site: arg 18 is tmux_lives_sync_terminals" tmux_lives_sync_terminals "$_WF17_ARGV[18]"
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
# theme_list renders the v6 catalog now (Task 4); "ember glow" was a v5 catalog
# name and no longer appears. "mono deep" is the v6 catalog's one hand-placed row.
t "theme list names mono deep" 1 (string match -q '*mono deep*' -- (__tmux_lives_theme_list | string collect); and echo 1; or echo 0)

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
# v6 catalog is 42 rows (was 35 under v5).
t "theme list has 42 rows" 42 (count (__tmux_lives_theme_list))
t "theme list rows carry truecolor swatches" 42 (count (string match -r '48;2;' (__tmux_lives_theme_list)))

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
# theme-v6-surface Task 4: __tmux_lives_theme_cmd is still v5 (Task 5 migrates the
# CLI) and stores "ember" into the SAME tmux_lives_theme universal that apply_live's
# 0-arg path (which theme_cmd triggers as a side effect, via __tmux_lives_write_fragment
# + __tmux_lives_theme_apply_live) now reads as a v6 HARMONY MODE. "ember" is not one
# of mono/analogous/complementary/split/triadic/tetradic/square, so
# __tmux_lives_theme_render returns nothing and apply_live correctly falls through to
# its legacy branch — the same branch the "off" block below documents with literal
# constants. This asserts that real, current ground truth (a real, if temporary,
# consequence of this task's own change) rather than the stale v5-vs-v5 comparison
# ("$THP", computed via the old __tmux_lives_theme_palette) it replaces.
t "theme live-applies bar_bg (legacy: relationship isn't a v6 mode)" (__tmux_lives_derive_status_bg '#485b3c' 0) (command tmux -L $thsock show -gv @tmux_lives_bar_bg 2>/dev/null)
t "theme live-applies sep_fg (legacy)" default (command tmux -L $thsock show -gv @tmux_lives_sep_fg 2>/dev/null)
t "theme live-applies tabs_color (legacy)" '' (command tmux -L $thsock show -gv @tmux_lives_tabs_color 2>/dev/null)
t "theme live-applies active_fg (legacy)" default (command tmux -L $thsock show -gv @tmux_lives_active_fg 2>/dev/null)
t "theme live-applies cap_bg (legacy)" colour238 (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
t "theme live-applies text_fg (legacy)" default (command tmux -L $thsock show -gv @tmux_lives_text_fg 2>/dev/null)
# the legacy branch resets the mark to default too — it does not push the seed verbatim.
t "theme live-applies mark_fg (legacy)" default (command tmux -L $thsock show -gv @tmux_lives_mark_fg 2>/dev/null)
t "theme live-applies status-style (legacy)" (__tmux_lives_derive_status '#485b3c' 0) (command tmux -L $thsock show -gv status-style 2>/dev/null)
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
# to their own defaults so THMONO's assumed recipe actually matches what
# __tmux_lives_theme_apply_live's 0-arg (universal-reading) path reads.
set -e tmux_lives_theme
set -e tmux_lives_theme_place
set -e tmux_lives_theme_mode
set -e tmux_lives_theme_phase
set -e tmux_lives_theme_vividness
__tmux_lives_theme_apply_live
# theme-v6-surface Task 4: apply_live's 0-arg path now reads the v6 recipe universals
# (tmux_lives_theme/_lspan/_peakc/_peakpos/_arrangement), all unset here so it falls
# to their defaults mono/0.55/0.11/0.50/deep — render THAT with __tmux_lives_theme_render
# (v6), not the old __tmux_lives_theme_palette (v5); "mono" names the same idea in both
# engines but the engines produce different hexes for it, so comparing against the v5
# function would compare two different colours by coincidence of a shared name.
set -g THMONO (__tmux_lives_theme_render '#485b3c' mono 0.55 0.11 0.50 deep)
t "unset theme applies mono (always-on)" "$THMONO[6]" (command tmux -L $thsock show -gv @tmux_lives_cap_bg 2>/dev/null)
# theme-v6-surface Task 4 controller scope: the explicit 5-arg apply-live path (the
# picker's `a`-preview and esc-revert path) writes no state — direct-call it twice with
# only mode flipped and confirm a derived color actually moves (same seed/lspan/peakc/
# peakpos/arrangement). This replaces the old 4-arg "phase" version (v5's `sage bar
# derived 0/180`): v6 has no phase knob, and passing 4 args to the new contract no
# longer means "explicit" at all (any count other than 5 reads the universals) — both
# old calls would silently read the SAME universal state and could never differ.
__tmux_lives_theme_apply_live mono 0.55 0.11 0.50 deep
set -g THEME_CAP_A (command tmux -L $tmux_lives_tmux_socket show -gv @tmux_lives_cap_bg 2>/dev/null)
__tmux_lives_theme_apply_live analogous 0.55 0.11 0.50 deep
set -g THEME_CAP_B (command tmux -L $tmux_lives_tmux_socket show -gv @tmux_lives_cap_bg 2>/dev/null)
t "apply-live 5-arg mono cap_bg non-empty" 1 (test -n "$THEME_CAP_A"; and echo 1; or echo 0)
t "apply-live 5-arg analogous cap_bg non-empty" 1 (test -n "$THEME_CAP_B"; and echo 1; or echo 0)
t "apply-live 5-arg mono vs analogous differ" 1 (test "$THEME_CAP_A" != "$THEME_CAP_B"; and echo 1; or echo 0)
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

# --- Task 4: the note's auto-reload branch -----------------------------------
# NB the match string is "refreshed automatically", NOT "refreshed". Today's very
# first note line already reads "tmux config refreshed + reloaded", so a bare
# `*refreshed*` PASSES against the unchanged function and proves nothing —
# verified before this plan shipped.
t "note: says other shells refreshed themselves when autoreloaded" 1 (string match -q '*refreshed automatically*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" 1 | string collect); and echo 1; or echo 0)
t "note: does NOT tell you to exec fish in each when autoreloaded" 0 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" 1 | string collect); and echo 1; or echo 0)
# The bootstrap branch: absent 4th arg keeps today's advice, which is correct on
# the first update because those shells have no handler yet.
t "note: keeps the exec fish advice when NOT autoreloaded" 1 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" | string collect); and echo 1; or echo 0)
# A REMOVED function still needs a real restart everywhere -- re-sourcing cannot
# unset one in the other shells either, so auto-reload does not rescue this case.
t "note: still advises exec fish elsewhere when a function was removed, even autoreloaded" 1 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "__gone" "Alpha" 1 | string collect); and echo 1; or echo 0)

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

# --- v6 fragment argv (theme-v6-surface Task 3): 13 theme(mode) 14 lspan 15 peakc
# 16 peakpos 17 arrangement (the v5 four-field theme — place/mode/phase, plus the
# vividness/shape/ease/contrast knobs retired at v5 Task 1 — is gone from the
# fragment; see [[theme-engine-v6]]).
set -l fr0 (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep | string collect)
# peakpos DOES move the ramp (bar/sep/tabs/... hues and chroma profile), so it moves the cap role too.
set -l frp (__tmux_lives_render_fragment /X/cat.fish S M-s '#485B3C' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.20 deep | string collect)
set -l cap0 (string match -r "@tmux_lives_cap_bg '[^']*'" -- "$fr0")
set -l capp (string match -r "@tmux_lives_cap_bg '[^']*'" -- "$frp")
t "fragment peakpos changes the cap" 0 (test "$cap0" = "$capp"; and echo 1; or echo 0)
# the bar is a ramp sample, not the seed verbatim — assert the fragment's
# status-style bg matches whatever the recipe actually renders, not the raw seed.
set -l fr0pal (__tmux_lives_theme_render '#485B3C' mono 0.55 0.11 0.50 deep)
t "fragment bar bg matches the rendered bar" 1 (string match -q "*status-style bg=$fr0pal[1]*" -- "$fr0"; and echo 1; or echo 0)
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
# is removed. Reuse $fr0 (already the mono/0.55/0.11/0.50/deep v6 recipe render
# from the fragment argv section above) and $src (the full source text).
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

# Review fix I-1: no prior assertion could tell a right /proc/<pid>/stat field
# index from a wrong one -- a reviewer mutation (pgrp field[3] -> session
# field[4]) left `ALL PASS` unchanged. A same-process cross-check (this test
# runner's own $fish_pid against `ps -o tpgid=,pgid=`) was tried first and
# does NOT discriminate: in every sandbox tried, a shell that is its own
# session leader (true of this test runner, and true of the function's real
# caller -- a tmux pane's shell) has pgrp == session by construction, so
# field[3] and field[4] read the same number regardless of which is used.
# Confirmed by direct /proc inspection before building this (see the task
# report). The mutation is only OBSERVABLE on a process that is (a) not its
# own session leader, so pgrp and session genuinely differ, and (b) has a
# positive tpgid, since the function's own `test "$tp" -gt 0; or return 1`
# guard short-circuits before ever reaching the pg comparison otherwise --
# both of which require a real controlling tty. So: an isolated tmux pane
# (real pty, real job control) runs a plain fish; a DIRECTLY TYPED nested
# `fish -c` (sent via `send-keys`, not sourced from a file -- fish only
# hands a job its own process group for commands entered at a live prompt)
# gets its own pgrp via real job control while inheriting the PANE's session
# id, which differs from its own pgrp by construction -- and since it is the
# live foreground job while it runs, tpgid == its own pgrp, giving a
# genuine positive tp with a genuinely wrong candidate (session) to confuse
# it with. That nested fish sources the real install file, calls the SHIPPED
# function on itself, and separately recomputes the same check from `ps` on
# its own pid, so a wrong field index makes the two disagree while a right
# one makes them agree. Linux-only by construction: the function's macOS
# branch already reads `ps` directly, so a cross-check there would just be
# `ps` agreeing with itself -- not attempted.
set -l idlesock tli-idle-$fish_pid
set -l idleready /tmp/tli-idle-ready-$fish_pid
set -l idleresult /tmp/tli-idle-result-$fish_pid
rm -f $idleready $idleresult
command tmux -L $idlesock -f /dev/null new-session -d -x 100 -y 30 "fish --no-config -i -C 'touch $idleready'" 2>/dev/null
set -l n 0
while not test -e $idleready; and test $n -lt 100
    sleep 0.1
    set n (math $n + 1)
end
set -l idlecmd "fish --no-config -c 'source $plugindir/conf.d/tmux-lives-install.fish; set -l fn BUSY; __tmux_lives_shell_is_idle; and set fn IDLE; set -l o (ps -o tpgid=,pgid= -p \$fish_pid | string trim | string split -n \" \"); set -l ps BUSY; test \"\$o[1]\" = \"\$o[2]\"; and set ps IDLE; echo \"FN=\$fn PS=\$ps\" > $idleresult'"
command tmux -L $idlesock send-keys -t 0:0.0 "$idlecmd" Enter 2>/dev/null
set -l n2 0
while not test -e $idleresult; and test $n2 -lt 100
    sleep 0.1
    set n2 (math $n2 + 1)
end
command tmux -L $idlesock kill-server 2>/dev/null
set -l idleout (test -e $idleresult; and cat $idleresult; or echo '')
rm -f $idleready $idleresult
# Review fix N-1: $idlefn and $idleps are both extracted from this SAME
# $idleout, so a harness that produces no output (pane never came up,
# send-keys missed, job control unavailable) leaves both empty and "" = ""
# would otherwise pass -- the same blind-spot class as I-1, relocated onto
# harness failure instead of a field index. Assert non-empty first, so a
# dead harness fails loudly here instead of vacuously agreeing below.
t "is_idle: pty harness produced output" 1 (test -n "$idleout"; and echo 1; or echo 0)
set -l idlefn (string match -r 'FN=(\w+)' -- "$idleout")[2]
set -l idleps (string match -r 'PS=(\w+)' -- "$idleout")[2]
t "is_idle: /proc field parse agrees with an independent ps -o tpgid=,pgid= reading" "$idleps" "$idlefn"

# No controlling tty -> tpgid is -1 -> must report NOT idle. "Unsure" has to mean
# "do not print", because every wrong answer here corrupts someone's editor frame.
set -g __t1_notty (fish --no-config -c "set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo IDLE; or echo BUSY" 2>/dev/null)
t "is_idle: no controlling tty reports BUSY" BUSY "$__t1_notty"

# At a prompt the shell owns the tty; inside a foreground child it does not.
# `timeout` is mandatory: an interactive fish outlives its -C command and a
# bare wait would hang the suite.
set -g __t1_pty (timeout 20 script -qfec "fish --no-config -i -C 'set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo AT-PROMPT-IDLE; or echo AT-PROMPT-BUSY; exit'" /dev/null 2>/dev/null | tr -d '\r')
t "is_idle: at a prompt with a tty reports IDLE" 1 (string match -q '*AT-PROMPT-IDLE*' -- "$__t1_pty"; and echo 1; or echo 0)

# --- Task 2: the reload handler ----------------------------------------------
# NAMED __tmux_lives_shell_reload, NOT __tmux_lives_reload. The plan's own text
# names it __tmux_lives_reload, but that name is ALREADY TAKEN (~line 282 of
# conf.d/tmux-lives-install.fish) by "source the tmux conf into a running
# server", called from __tmux_lives_write_fragment on every `setup color`/`setup
# theme`/etc. Defining a second `function __tmux_lives_reload` would silently
# REDEFINE it -- fish does not error on function redefinition -- breaking live
# tmux reloads for every config command with no symptom until someone noticed
# their bar stopped updating. Confirmed by grep before this task was built; see
# the task-2 report. The guard below pins that the pre-existing function is
# untouched.
t "shell_reload: did not clobber the pre-existing tmux-conf reload" 1 (string match -q '*tmux source-file*' -- (functions __tmux_lives_reload | string collect); and echo 1; or echo 0)
t "shell_reload: handler exists" 1 (functions -q __tmux_lives_shell_reload; and echo 1; or echo 0)
set -g __t2_body (functions __tmux_lives_shell_reload | string collect)
t "shell_reload: registered on the token variable" 1 (string match -q '*--on-variable tmux_lives_reload_token*' -- "$__t2_body"; and echo 1; or echo 0)
t "shell_reload: bails when not interactive" 1 (string match -q '*status is-interactive*' -- "$__t2_body"; and echo 1; or echo 0)
t "shell_reload: honours the opt-out" 1 (string match -q '*tmux_lives_autoreload*' -- "$__t2_body"; and echo 1; or echo 0)
# It must re-source the two conf.d files and NOT functions/tmux-categorize.fish,
# which is only ever invoked as a script (see the spec for why).
# `functions <name>` prints the DESCRIPTION as well as the body, so a raw
# $__t2_body match is defeated by any coincidental self-mention -- not only in
# the description (the categorizer-filename trap this repo has hit nine
# times), but also in an ordinary explanatory COMMENT inside the body itself:
# the comment two lines below the dedup marker literally says "Re-sourcing
# tmux-lives-install.fish below redefines THIS function...", which alone
# satisfies a raw *tmux-lives-install.fish* match even with the real
# reference deleted from the for-loop -- proven by mutation while fixing this
# review round (see the task-2 report). $__t2_bodyonly strips every comment
# line (`^\s*#`) and the description line, leaving only the executable code,
# so both file-reference assertions below use it.
set -g __t2_bodyonly (functions __tmux_lives_shell_reload | string match -v -r '^\s*#|--description' | string collect)
t "shell_reload: re-sources tmux.fish" 1 (string match -q '*conf.d/tmux.fish*' -- "$__t2_bodyonly"; and echo 1; or echo 0)
t "shell_reload: re-sources the install file" 1 (string match -q '*tmux-lives-install.fish*' -- "$__t2_bodyonly"; and echo 1; or echo 0)
t "shell_reload: body-only extraction is non-empty" 1 (test -n "$__t2_bodyonly"; and echo 1; or echo 0)
t "shell_reload: does NOT source the categorizer" 0 (string match -q '*tmux-categorize*' -- "$__t2_bodyonly"; and echo 1; or echo 0)
t "shell_reload: gates the notice on the idle predicate" 1 (string match -q '*__tmux_lives_shell_is_idle*' -- "$__t2_bodyonly"; and echo 1; or echo 0)
# The controller's original justification for idempotency ("one set -U fires
# the handler twice") was a measurement artefact and has been retracted -- see
# the spec. The real reason is structural: step 3 re-sources the file that
# DEFINES this handler, while it is running, re-registering the --on-variable
# binding mid-dispatch. The body must not repeat the retracted claim.
t "shell_reload: body does not repeat the retracted double-fire claim" 0 (string match -qi '*measured*firing*handler*twice*' -- "$__t2_body"; and echo 1; or echo 0)

# The structural checks above cannot see event delivery, re-source effects, or
# self-redefinition safety (Task 2 Step 4) -- that needs a real pty and a
# second fish process sharing the same universal-variable store.
#
# A dedicated, isolated $XDG_CONFIG_HOME (fish/conf.d holding copies of the two
# plugin conf.d files) is required here -- distinct from this whole suite's own
# outer isolation guard -- because the READER shell must actually autoload the
# handler from conf.d for the event to have anywhere to land. It shares nothing
# with the outer suite's universal store.
#
# The reader is a real interactive fish attached to an isolated -L tmux pane
# (this suite's established pattern for genuine pty behaviour, e.g. the
# is_idle cross-check above). A marker function is appended to the reader's
# OWN COPY of tmux-lives-install.fish and its definition changed ON DISK mid
# run, so "the changed body is live afterwards" proves a real re-source
# happened, not just that the handler ran. The setter is a config-loaded (NOT
# --no-config -- a no-config `set -U` is process-local and invisible to every
# other fish, proven above at "no-config set -U is invisible cross-process")
# `fish -c` sharing the same XDG_CONFIG_HOME, run OUTSIDE the pane so its own
# stdout can never land in the captured pane output -- it also loads the
# handler and fires it on itself, but `status is-interactive; or return` bails
# before it does anything observable.
set -l shsock tli-shreload-$fish_pid
set -l shhome (mktemp -d /tmp/tli-shreload-home.XXXXXX)
mkdir -p $shhome/fish/conf.d
cp $plugindir/conf.d/tmux.fish $shhome/fish/conf.d/tmux.fish
cp $plugindir/conf.d/tmux-lives-install.fish $shhome/fish/conf.d/tmux-lives-install.fish
printf '\nfunction __tli_reload_probe\n    echo V1\nend\n' >> $shhome/fish/conf.d/tmux-lives-install.fish
set -l shready /tmp/tli-shreload-ready-$fish_pid
set -l shrc /tmp/tli-shreload-rc-$fish_pid
rm -f $shready $shrc
# I-1 (whole-branch review): fish history lives under $XDG_DATA_HOME, which this
# suite's own outer isolation guard does not redirect (it only redirects
# $XDG_CONFIG_HOME, for the universal-variable store). This reader is plain
# `fish` on purpose -- deliberately NOT --no-config, so it autoloads the handler
# from conf.d -- and every `send-keys` below lands real keystrokes, so without
# this it writes into the developer's REAL ~/.local/share/fish/fish_history on
# every run (measured: 99 hits for the marker name before this fix). Task 1's
# own pty harness never hit this because it uses `fish --no-config -i`, which
# fish never persists history for.
command tmux -L $shsock -f /dev/null new-session -d -x 100 -y 30 "env XDG_CONFIG_HOME=$shhome XDG_DATA_HOME=$shhome/data fish -i -C 'touch $shready'" 2>/dev/null
set -l n 0
while not test -e $shready; and test $n -lt 100
    sleep 0.1
    set n (math $n + 1)
end
t "shell_reload: reader pane reached an interactive prompt" 1 (test -e $shready; and echo 1; or echo 0)

# Change the marker on disk, THEN fire the token -- the order that matters:
# capabilities/definitions must be stale on disk before the event, or the test
# cannot tell "re-sourced" from "loaded fresh".
sed -i 's/echo V1/echo V2/' $shhome/fish/conf.d/tmux-lives-install.fish
env XDG_CONFIG_HOME=$shhome fish -c 'set -U tmux_lives_reload_token T1' 2>/dev/null

function __t2_notice_count --argument-names sock
    set -l cap (command tmux -L $sock capture-pane -p -S -100 -t 0:0.0 2>/dev/null)
    string match -a '*↻ tmux-lives reloaded*' -- $cap | count
end

# Poll for the notice, then ask the still-running reader (via send-keys, this
# suite's established mechanism for a genuinely-typed follow-up command -- see
# the is_idle cross-check) to report its OWN live definition of the marker.
set -l n2 0
while test (__t2_notice_count $shsock) -lt 1; and test $n2 -lt 60
    sleep 0.2
    set n2 (math $n2 + 1)
end
command tmux -L $shsock send-keys -t 0:0.0 "echo MARKER=(__tli_reload_probe) > $shrc" Enter 2>/dev/null
set -l n3 0
while not test -e $shrc; and test $n3 -lt 60
    sleep 0.1
    set n3 (math $n3 + 1)
end
t "shell_reload: pty harness produced a marker readback" 1 (test -e $shrc; and echo 1; or echo 0)
set -l shmarker (test -e $shrc; and cat $shrc; or echo '')
t "shell_reload: the changed definition is live in the already-running shell" "MARKER=V2" "$shmarker"
t "shell_reload: notice appears exactly once for one real token change" 1 (__t2_notice_count $shsock)

# Idempotency, for its real reason: re-sourcing this file redefines the
# handler WHILE IT RUNS, re-registering the --on-variable binding mid
# dispatch (Step 4). Setting the SAME value again must not re-notice --
# proves the dedup marker actually gates, not just that it exists in the body.
env XDG_CONFIG_HOME=$shhome fish -c 'set -U tmux_lives_reload_token T1' 2>/dev/null
sleep 1
t "shell_reload: repeating the SAME value does not re-notice" 1 (__t2_notice_count $shsock)

# And Step 4's actual question: did the self-redefinition survive intact, or
# did fish error/re-enter/lose the binding? A GENUINELY new value must still
# notice -- if it does not, the handler died silently the first time it
# redefined itself.
env XDG_CONFIG_HOME=$shhome fish -c 'set -U tmux_lives_reload_token T2' 2>/dev/null
set -l n4 0
while test (__t2_notice_count $shsock) -lt 2; and test $n4 -lt 60
    sleep 0.2
    set n4 (math $n4 + 1)
end
t "shell_reload: self-redefinition survives -- a later value still notices" 2 (__t2_notice_count $shsock)

command tmux -L $shsock kill-server 2>/dev/null
rm -rf $shhome $shready $shrc
functions -e __t2_notice_count

# --- Task 3: the update trigger ---------------------------------------------
# Line-number helper. The obvious idiom for this — measuring the length of a
# lazy `(?s)^.*?needle` match — is BROKEN: `string match -r` returns more than
# one element there, so `string length` yields a LIST and the numeric compare
# dies with "Integer 5 in '5 30' followed by non-digit". Verified before this
# plan shipped; do not "simplify" back to it.
function __t3_lineno --argument-names hay needle
    set -l ls (string split \n -- $hay)
    for i in (seq (count $ls))
        if string match -q "*$needle*" -- $ls[$i]
            echo $i
            return
        end
    end
    echo 0
end

set -g __t3_body (functions _tmux_lives_post_update | string collect)
t "trigger: sets the reload token" 1 (string match -q '*set -U tmux_lives_reload_token*' -- "$__t3_body"; and echo 1; or echo 0)
t "trigger: only sets when the digest changed" 1 (string match -q '*__tmux_lives_digest*' -- "$__t3_body"; and echo 1; or echo 0)

# PLACEMENT IS LOAD-BEARING: below the _tmux_lives_updating early return, plain
# `fisher update` would refresh other shells while `tmux-lives update` silently
# would not. Both line numbers must be FOUND (0 means "not present", which would
# make the ordering compare true for the wrong reason).
set -g __t3_tok (__t3_lineno "$__t3_body" 'set -U tmux_lives_reload_token')
set -g __t3_ret (__t3_lineno "$__t3_body" 'set -q _tmux_lives_updating')
t "trigger: the token line was found" 1 (test "$__t3_tok" -gt 0; and echo 1; or echo 0)
t "trigger: the early-return line was found" 1 (test "$__t3_ret" -gt 0; and echo 1; or echo 0)
t "trigger: fires ABOVE the _tmux_lives_updating early return" 1 (test "$__t3_tok" -gt 0 -a "$__t3_ret" -gt 0 -a "$__t3_tok" -lt "$__t3_ret"; and echo 1; or echo 0)

# Behavioural pair, run under this suite's own isolated universal store (the
# outer XDG_CONFIG_HOME re-exec guard at the top of the file). The fragment
# seam is pointed at a path that does not exist, so __tmux_lives_write_fragment
# never runs — this must never touch the real ~/.config/tmux/tmux-lives.conf —
# and _tmux_lives_updating is set around every direct call so the generic note
# (which shells out to tmux for stale-session names) never fires either. The
# funcs seam is the same protection for __tmux_lives_write_funcs, which runs
# UNCONDITIONALLY inside the handler and otherwise falls back to the REAL
# ~/.config/tmux/tmux-lives-funcs (see C-1 in the Task 4 review).
set -g tmux_lives_fragment_file /tmp/tli-t3frag-$fish_pid.conf
rm -f $tmux_lives_fragment_file
set -g tmux_lives_funcs_file /tmp/tli-t3funcs-$fish_pid
rm -f $tmux_lives_funcs_file
set -g tmux_lives_update_files /tmp/tli-t3upd-$fish_pid
printf 'one\n' > $tmux_lives_update_files
set -l __t3_dg1 (__tmux_lives_digest $tmux_lives_update_files)

# already equal to the current digest -> invoking the trigger must NOT change it
set -U tmux_lives_reload_token $__t3_dg1
set -g _tmux_lives_updating 1
_tmux_lives_post_update >/dev/null 2>&1
set -e _tmux_lives_updating
t "trigger: unchanged digest leaves the token alone" "$__t3_dg1" "$tmux_lives_reload_token"

# digest now differs (file content changed) -> invoking the trigger must update it
printf 'two\n' >> $tmux_lives_update_files
set -l __t3_dg2 (__tmux_lives_digest $tmux_lives_update_files)
t "trigger: file change actually changes the digest" 1 (test "$__t3_dg1" != "$__t3_dg2"; and echo 1; or echo 0)
set -g _tmux_lives_updating 1
_tmux_lives_post_update >/dev/null 2>&1
set -e _tmux_lives_updating
t "trigger: changed digest updates the token" "$__t3_dg2" "$tmux_lives_reload_token"

# token absent entirely (first update shipping the feature) -> trigger must set it
set -e tmux_lives_reload_token
set -g _tmux_lives_updating 1
_tmux_lives_post_update >/dev/null 2>&1
set -e _tmux_lives_updating
t "trigger: absent token gets set" "$__t3_dg2" "$tmux_lives_reload_token"

set -e tmux_lives_reload_token
set -e tmux_lives_update_files
set -e tmux_lives_fragment_file
set -e tmux_lives_funcs_file
rm -f /tmp/tli-t3upd-$fish_pid /tmp/tli-t3frag-$fish_pid.conf /tmp/tli-t3funcs-$fish_pid
functions -e __t3_lineno

# I-3 guard, closing the bracket opened at the top of this file: neither real file
# may carry a trace of THIS run's own fixtures, no matter which call site (existing
# or future) forgot to seam its path. See the doc comment at the top of the file for
# why this is a footprint check now, not a whole-file identity check.
t "guard: real tmux-lives-funcs untouched by this run" 1 (__ti_guard_funcs_ok $__ti_guard_funcs $__ti_guard_funcs_existed_before; and echo 1; or echo 0)
t "guard: real fish_history untouched by this run" 1 (__ti_guard_history_ok $__ti_guard_history; and echo 1; or echo 0)
functions -e __ti_guard_funcs_ok __ti_guard_history_ok

# --- socket hygiene ---------------------------------------------------------
# Every `-L` server this suite starts is killed, but tmux leaves the SOCKET FILE
# behind, and this file starts ~20 of them per run. They accumulated to 1543 in
# /tmp/tmux-<uid>/ before anyone noticed. Killing a server does not unlink its
# socket, so the sweep has to be explicit. Every socket this suite creates
# carries $fish_pid, which is this (re-exec'd) process, so the glob cannot touch
# another run's files or the user's own `default`.
set -l __ti_sockdir /tmp/tmux-(id -u)
# FAIL CLOSED before globbing. If $fish_pid were ever empty, `*$fish_pid*`
# collapses to `**` and matches EVERY file in this directory — including the
# user's own `default` socket, which would drop their live tmux server's socket
# file. $fish_pid is a fish-protected special variable and cannot currently be
# empty, but a future refactor swapping in a less-protected PID variable would
# silently turn this line into a directory-wide wipe. Same fail-closed shape as
# the XDG_CONFIG_HOME guard at the top of this file.
if test -z "$fish_pid"; or test -z "$__ti_sockdir"
    echo "FATAL: refusing to sweep sockets without a pid-scoped glob" >&2
    exit 1
end
# Anchored on the `-<pid>` suffix every socket in this file uses, so a run whose
# pid is a substring of another's (445722 vs 1445722) cannot delete the other's
# live sockets. Anchoring narrows the collision surface; it does not eliminate
# it, and this suite is not designed to run concurrently with itself.
rm -f $__ti_sockdir/*-$fish_pid 2>/dev/null
# Self-checking: prove the sweep actually matched this run's names rather than
# silently globbing nothing (the failure mode that let this go unnoticed).
set -l __ti_leftover (count (string match -r ".*$fish_pid.*" -- (ls $__ti_sockdir 2>/dev/null)))
t "hygiene: this run leaves no tmux socket files behind" 0 $__ti_leftover

# --- v6 harmony: hue anchors ------------------------------------------------
# The v5 relationships (mono/wheat/amber/ember/coral/mint/sage/teal) are all
# signed hue TRAVEL along an arc, so they structurally cannot produce separated
# hue families — measured, 21 of 24 relationship x placement combinations yield
# exactly one family. Triadic and square need hues to JUMP. This is that table.
set -g A6MONO (__tmux_lives_theme_anchors 120 mono)
t "anchors: mono is one hue" 1 (count $A6MONO)
t "anchors: mono returns the seed hue" 120 "$A6MONO[1]"

set -g A6ANA (__tmux_lives_theme_anchors 120 analogous)
t "anchors: analogous is three hues" 3 (count $A6ANA)
t "anchors: the seed hue is ALWAYS anchor one" 120 "$A6ANA[1]"
t "anchors: analogous reaches -30" 90 "$A6ANA[2]"
t "anchors: analogous reaches +30" 150 "$A6ANA[3]"

set -g A6COMP (__tmux_lives_theme_anchors 120 complementary)
t "anchors: complementary is two hues" 2 (count $A6COMP)
t "anchors: complementary seed is anchor one" 120 "$A6COMP[1]"
t "anchors: complementary is opposite" 300 "$A6COMP[2]"

set -g A6SPLIT (__tmux_lives_theme_anchors 120 split)
t "anchors: split is three hues" 3 (count $A6SPLIT)
t "anchors: split seed is anchor one" 120 "$A6SPLIT[1]"
t "anchors: split lands at +150" 270 "$A6SPLIT[2]"
t "anchors: split lands at +210" 330 "$A6SPLIT[3]"

set -g A6TRI (__tmux_lives_theme_anchors 120 triadic)
t "anchors: triadic is three hues" 3 (count $A6TRI)
t "anchors: triadic seed is anchor one" 120 "$A6TRI[1]"
t "anchors: triadic is evenly spaced" 240 "$A6TRI[2]"
t "anchors: triadic wraps the third" 0 "$A6TRI[3]"

set -g A6TET (__tmux_lives_theme_anchors 120 tetradic)
t "anchors: tetradic is four hues" 4 (count $A6TET)
t "anchors: tetradic seed is anchor one" 120 "$A6TET[1]"
set -g A6SQ (__tmux_lives_theme_anchors 120 square)
t "anchors: square is four hues" 4 (count $A6SQ)
t "anchors: square seed is anchor one" 120 "$A6SQ[1]"
t "anchors: square is evenly spaced" 210 "$A6SQ[2]"

# wrap-around must be handled, not left negative or past 360
set -g A6WRAP (__tmux_lives_theme_anchors 10 analogous)
t "anchors: a negative offset wraps into range" 340 "$A6WRAP[2]"
set -g A6WRAP2 (__tmux_lives_theme_anchors 350 square)
t "anchors: an over-360 offset wraps into range" 80 "$A6WRAP2[2]"

t "anchors: an unknown mode returns nothing" 0 (count (__tmux_lives_theme_anchors 120 nonsense))

# --- v6 ramp: lightness span, peak chroma, peak position ---------------------
# These three are INDEPENDENT dimensions, not one "intensity" axis. Measured on
# the users 16 coolors palettes: peakC vs Lspan r = -0.29, peakC vs peakPos
# +0.25, Lspan vs peakPos +0.06. No evidence any pair moves together.
set -g R6 (__tmux_lives_theme_ramp 0.50 0.40 0.15 0.5 7)
t "ramp: returns n pairs" 7 (count $R6)

set -g R6L (for p in $R6; echo (string split ' ' -- $p)[1]; end)
set -g R6C (for p in $R6; echo (string split ' ' -- $p)[2]; end)

# lightness is monotonic dark -> light
set -g R6MONO 1
for i in (seq 2 7)
    set -l __r6pi (math $i - 1)
    test "$R6L[$i]" -gt "$R6L[$__r6pi]"; or set -g R6MONO 0
end
t "ramp: lightness is monotonic" 1 $R6MONO

# the span is honoured
t "ramp: span is honoured" 1 (test (math "abs(($R6L[7] - $R6L[1]) - 0.40)") -lt 0.01; and echo 1; or echo 0)

# the seeds own L falls INSIDE the window — this is how the seed stops being
# hue-only, which is the v5 defect this whole cycle exists to fix
t "ramp: the seed's L is inside the window" 1 (test "$R6L[1]" -le 0.50 -a "$R6L[7]" -ge 0.50; and echo 1; or echo 0)

# chroma peaks where peakPos asks
set -g R6MAXI 1
for i in (seq 2 7)
    test "$R6C[$i]" -gt "$R6C[$R6MAXI]"; and set -g R6MAXI $i
end
t "ramp: chroma peaks mid-ramp when asked to" 4 $R6MAXI
t "ramp: the peak reaches peakC" 1 (test (math "abs($R6C[$R6MAXI] - 0.15)") -lt 0.005; and echo 1; or echo 0)

set -g R6LO (__tmux_lives_theme_ramp 0.50 0.40 0.15 0.0 7)
set -g R6LOC (for p in $R6LO; echo (string split ' ' -- $p)[2]; end)
t "ramp: peakPos 0 peaks at the dark end" 1 (test "$R6LOC[1]" -gt "$R6LOC[7]"; and echo 1; or echo 0)
set -g R6HI (__tmux_lives_theme_ramp 0.50 0.40 0.15 1.0 7)
set -g R6HIC (for p in $R6HI; echo (string split ' ' -- $p)[2]; end)
t "ramp: peakPos 1 peaks at the light end" 1 (test "$R6HIC[7]" -gt "$R6HIC[1]"; and echo 1; or echo 0)

# the three dimensions must be INDEPENDENT: changing one must not move another
set -g R6A (__tmux_lives_theme_ramp 0.50 0.40 0.05 0.5 7)
set -g R6B (__tmux_lives_theme_ramp 0.50 0.40 0.25 0.5 7)
set -g R6AL (for p in $R6A; echo (string split ' ' -- $p)[1]; end)
set -g R6BL (for p in $R6B; echo (string split ' ' -- $p)[1]; end)
t "ramp: changing peak chroma does NOT move lightness" "$R6AL" "$R6BL"
set -g R6C1 (__tmux_lives_theme_ramp 0.50 0.20 0.15 0.5 7)
set -g R6C2 (__tmux_lives_theme_ramp 0.50 0.70 0.15 0.5 7)
set -g R6C1C (for p in $R6C1; echo (string split ' ' -- $p)[2]; end)
set -g R6C2C (for p in $R6C2; echo (string split ' ' -- $p)[2]; end)
t "ramp: changing lightness span does NOT move chroma" "$R6C1C" "$R6C2C"

# clamping: a window that would run off either end shifts rather than shrinking
set -g R6DARK (__tmux_lives_theme_ramp 0.10 0.60 0.15 0.5 7)
set -g R6DL (for p in $R6DARK; echo (string split ' ' -- $p)[1]; end)
t "ramp: a dark seed's window stays in gamut" 1 (test "$R6DL[1]" -ge 0.05; and echo 1; or echo 0)
t "ramp: ...and keeps its full span" 1 (test (math "abs(($R6DL[7] - $R6DL[1]) - 0.60)") -lt 0.01; and echo 1; or echo 0)
set -g R6LIGHT (__tmux_lives_theme_ramp 0.95 0.60 0.15 0.5 7)
set -g R6GL (for p in $R6LIGHT; echo (string split ' ' -- $p)[1]; end)
t "ramp: a light seed's window stays in gamut" 1 (test "$R6GL[7]" -le 0.97; and echo 1; or echo 0)
t "ramp: ...and a light seed keeps its full span too" 1 (test (math "abs(($R6GL[7] - $R6GL[1]) - 0.60)") -lt 0.01; and echo 1; or echo 0)

# --- v6 arrangement: ramp positions -> roles ---------------------------------
# Roles, in order: bar sep tabs active windows cap text.

# The shared ramp-index table: the ONE home of the six patterns' index lists,
# so __tmux_lives_theme_arrange (which permutes with it) and
# __tmux_lives_theme_constrain (which will select the text-floor swap partner
# with it) cannot drift apart.
t "rampidx: deep" "1 4 2 6 5 3 7" (string join ' ' (__tmux_lives_theme_rampidx deep))
t "rampidx: bright" "4 5 3 7 6 2 1" (string join ' ' (__tmux_lives_theme_rampidx bright))
t "rampidx: centre" "3 5 2 6 7 4 1" (string join ' ' (__tmux_lives_theme_rampidx centre))
t "rampidx: split" "1 3 4 5 6 2 7" (string join ' ' (__tmux_lives_theme_rampidx split))
t "rampidx: stack" "2 5 3 6 4 1 7" (string join ' ' (__tmux_lives_theme_rampidx stack))
t "rampidx: accent" "3 5 4 6 2 1 7" (string join ' ' (__tmux_lives_theme_rampidx accent))
t "rampidx: unknown pattern yields nothing" "" (string join ' ' (__tmux_lives_theme_rampidx nosuch))
t "rampidx: defined" 1 (functions -q __tmux_lives_theme_rampidx; and echo 1; or echo 0)

set -g A6PATS (__tmux_lives_theme_arrangements)
t "arrange: there are exactly six patterns" 6 (count $A6PATS)

# every pattern must be a genuine permutation of 1..7 — a duplicated index would
# silently drop a colour and repeat another, which looks plausible on screen.
# This fixture is WIDE (L 0.115 to 0.961) for historical reasons only: before
# the contrast floor moved out of arrange into __tmux_lives_theme_constrain, a
# narrow fixture could make the floor's stage two REPLACE a colour inside
# arrange itself, breaking the permutation this assertion checks. arrange is
# now a pure permutation UNCONDITIONALLY regardless of fixture width — see
# "arrange: is a pure permutation even on a narrow fixture" below, proven on a
# narrow one. Nothing requires this fixture to stay wide any more; it simply
# was never revisited.
#
# Cardinality (count -eq 7) and uniqueness (sort -u -eq 7) do NOT prove a
# permutation -- they hold just as well if a colour-substituting stage
# fabricates colours that merely happen to be distinct from each other.
# Proven, against the swap-selection logic that has since moved into
# __tmux_lives_theme_constrain (conf.d/tmux-lives-install.fish:738, `if test
# $best -ne 7` forced to `if false`): patterns `stack` and `accent` emit
# #a5a5a5 and #d6d6d6 on this exact fixture -- neither is an input colour --
# while count and sort -u both still read 7 and the whole suite stays ALL
# PASS. Membership is the check that actually distinguishes a reordering from
# a fabrication.
set -g A6PERMFIX '#050505' '#333333' '#5a5a5a' '#808080' '#a6a6a6' '#cccccc' '#f2f2f2'
set -g A6PERMOK 1
for p in $A6PATS
    set -l out (__tmux_lives_theme_arrange $p $A6PERMFIX)
    test (count $out) -eq 7; or set -g A6PERMOK 0
    test (count (printf '%s\n' $out | sort -u)) -eq 7; or set -g A6PERMOK 0
    for h in $out
        contains -- $h $A6PERMFIX; or set -g A6PERMOK 0
    end
end
t "arrange: every pattern is a permutation, no colour dropped or repeated" 1 $A6PERMOK

# THE one hard rule: text must clear a lightness-contrast floor against bar.
# Fed seven near-identical colours, no arrangement can satisfy it naturally, so
# this proves the floor is ENFORCED rather than merely usually true.
set -g A6FLAT (__tmux_lives_theme_arrange deep '#303030' '#313131' '#323232' '#333333' '#343434' '#353535' '#363636')
t "arrange: a flat input still returns seven" 7 (count $A6FLAT)

set -g A6FLOOROK 1
for p in $A6PATS
    set -l out (__tmux_lives_theme_constrain (__tmux_lives_theme_arrange $p '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac'))
    set -l lbar (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l ltxt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[7]))
    test (math "abs($ltxt[1] - $lbar[1])") -ge 0.40; or set -g A6FLOOROK 0
end
t "constrain: text clears the contrast floor in EVERY pattern" 1 $A6FLOOROK

# ...and specifically for the two a swap alone CANNOT rescue. These two fail
# unless stage two exists, so they are what prove it runs.
for p in centre accent
    set -l out (__tmux_lives_theme_constrain (__tmux_lives_theme_arrange $p '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac'))
    set -l lbar (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l ltxt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[7]))
    t "constrain: a mid-ramp bar still gets legible text ($p)" 1 (test (math "abs($ltxt[1] - $lbar[1])") -ge 0.40; and echo 1; or echo 0)
end

t "arrange: an unknown pattern returns nothing" 0 (count (__tmux_lives_theme_arrange nonsense '#111111' '#222222' '#333333' '#444444' '#555555' '#666666' '#777777'))

# the patterns must actually differ — six names mapping to one order would be
# the v5 failure in miniature
set -g A6DISTINCT (for p in $A6PATS; __tmux_lives_theme_arrange $p '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac' | string join ','; end | sort -u | count)
t "arrange: the six patterns produce six distinct orderings" 6 $A6DISTINCT

# C1a (rendered-output check — a SECONDARY, corroborating signal, NOT a
# guarantee): does the composed pipeline — the real stage-one swap and
# stage-two push, both live — put a high ramp index on a big role for the
# six SHIPPED tables? Checking on rendered output means the swap CAN mask a
# genuine table violation before this loop ever inspects it, and it
# demonstrably does for more than one violation shape. The real guarantee
# is the TABLE-level assertion below, which has no `arrange` call, no
# rendering and no swap anywhere in its path — nothing left that can mask
# anything.
#
# A monotonic grey ramp (tried first) let the swap rescue ANY misplaced
# extreme index: mutating `stack` to put ramp index 7 on `cap` produced no
# failure, because the swap's own "furthest from bar" search is drawn to
# exactly the shape a violation takes (a light colour on a big role IS the
# most-distant-from-bar candidate) and relocated it into `text` first.
#
# The CURRENT fixture (indices 1-4 clustered; 5 and 6 placed strongly
# outside the cluster; 7 placed only mildly outside it) closes that specific
# gap — it correctly exposes an index-7-shaped violation, and matches the
# raw table exactly, no contamination, for all six shipped patterns — but a
# review brute-force sweep of all 34 single-swap mutations across the six
# patterns found FOUR that STILL self-heal: on `bright` and `centre`, when
# the misplaced index is 6 rather than 7 (two were run live against the
# real suite with no failure, then restored byte-identically — see the task
# report). The mechanism is structural, not a fixture-design mistake: the
# swap always picks whichever candidate sits furthest from bar, and since
# the TABLE decides which colour lands on which position, no choice of
# seven fixture colours can guarantee an extreme value never sits on a big
# role — this has now been demonstrated from both directions (an index-7
# violation defeats a monotonic ramp; an index-6 violation defeats THIS
# fixture). No further fixture engineering is planned here. This block is
# kept anyway because it costs nothing and still proves something real —
# that the six shipped tables, run through the real pipeline, do not
# currently exhibit the violation as tested here — just not a general
# guarantee against a future violation of any shape.
set -g A6BIGOK 1
for pat in (__tmux_lives_theme_arrangements)
    # Recover the index list by feeding seven distinguishable hexes through
    # arrange (rendered output, per the caveats above — the table-level
    # assertion below reads the switch block's source instead).
    set -l fix '#7a7a7a' '#7e7e7e' '#767676' '#828282' '#1a1a1a' '#f2f2f2' '#c0c0c0'
    set -l out (__tmux_lives_theme_arrange $pat $fix)
    for r in 1 3 6
        for p in (seq 7)
            if test "$out[$r]" = "$fix[$p]"
                test $p -gt 4; and set -g A6BIGOK 0
            end
        end
    end
end
t "arrange: no big role draws a ramp index above 4 (rendered output, not a complete guard)" 1 $A6BIGOK

# C1b (table check — the assertion that actually PINS the invariant): parse
# the switch block directly out of __tmux_lives_theme_rampidx — the shared
# table __tmux_lives_theme_arrange now consumes rather than owns, extracted
# out to its own function so constrain's text-floor swap can read the same
# indices without a second copy — rather than calling it. Extracting a
# source region with awk and parsing it is an established idiom in this file
# (see the migrate_v4/migrate_v41 body-exclusion greps above) — the brief's
# claim that "the list lives inside a switch the test cannot read" is simply
# not true here. With no `arrange` call, no rendering and no stage-one swap
# anywhere in the path, nothing can mask a violation the way the
# rendered-output check above demonstrably can.
set -g A6TBLRAW (awk '/^    switch "\$pattern"$/,/^    end$/' $plugindir/conf.d/tmux-lives-install.fish)

set -g A6TBLNAMES
set -g A6TBLLISTS
set -l pending ''
for line in $A6TBLRAW
    set -l cm (string match -rg '^\s*case (\w+)$' -- $line)
    if test -n "$cm"
        set pending $cm
        continue
    end
    # __tmux_lives_theme_rampidx emits its index list via `printf '%s\n' ...`
    # rather than `set idx ...` (the extraction target moved when the table
    # was pulled out of __tmux_lives_theme_arrange), so the capture matches
    # that literal prefix instead.
    set -l im (string match -rg "^\s*printf '%s\\\\n' (.+)\$" -- $line)
    if test -n "$im"; and test -n "$pending"
        set -a A6TBLNAMES $pending
        set -a A6TBLLISTS (string join ' ' -- $im)
        set pending ''
    end
end

# Guard against vacuity FIRST — the specific failure mode this approach
# brings with it, and one this repo has shipped more than once: a renamed
# function, a moved block, or a changed indent makes the awk range match
# NOTHING, and an assertion built on an empty list can pass by matching
# nothing rather than by checking anything. These two counts are real
# numbers, not booleans defaulted true, so an empty or partial extraction
# fails LOUDLY here (0 != 6) rather than passing vacuously — proven by
# pointing the same extraction at a marker that does not exist and getting
# zero raw lines and zero parsed names (see the task report).
t "table: exactly six patterns were parsed" 6 (count $A6TBLNAMES)
t "table: exactly six index lists were parsed" 6 (count $A6TBLLISTS)

# Cardinality alone does not prove a permutation (the same caution as
# A6PERMOK above) — verify EVERY parsed list is a genuine reordering of 1-7
# before trusting position membership within it. Guarded against indexing a
# malformed (non-7-element) list when computing A6TBLBIGOK below: an empty
# `test` argument throws rather than failing quietly, so a malformed list
# is scored as a violation directly instead of risking stderr noise.
set -g A6TBLPERMOK 1
set -g A6TBLBIGOK 1
for i in (seq (count $A6TBLLISTS))
    set -l vals (string split ' ' -- $A6TBLLISTS[$i])
    test (count $vals) -eq 7; or set -g A6TBLPERMOK 0
    test (count (printf '%s\n' $vals | sort -u)) -eq 7; or set -g A6TBLPERMOK 0
    for v in $vals
        contains -- $v 1 2 3 4 5 6 7; or set -g A6TBLPERMOK 0
    end
    if test (count $vals) -eq 7
        for r in 1 3 6
            test "$vals[$r]" -gt 4; and set -g A6TBLBIGOK 0
        end
    else
        set -g A6TBLBIGOK 0
    end
end
t "table: each parsed list is a genuine permutation of 1-7" 1 $A6TBLPERMOK

# THE invariant, checked on the table itself: bar (1), tabs (3) and cap (6)
# never hold a ramp index above 4. Nothing in this path can mask a
# violation the way the rendered-output check above can.
t "table: no big role (bar/tabs/cap) holds a ramp index above 4" 1 $A6TBLBIGOK

# Stage two only GUARANTEES hue; chroma is REQUESTED, not preserved — a grey
# fixture (used above) has no hue to preserve, so this needs a COLOURFUL one.
# Built with the SAME lightness profile as the floor fixture above, giving
# real chroma and a distinct hue at every ramp position.
set -g A6CHEX
set -g A6CHUES
for spec in '0.173048 0.05 20' '0.285016 0.05 80' '0.386656 0.05 140' '0.481931 0.05 200' '0.572684 0.05 260' '0.659958 0.05 300' '0.744429 0.05 340'
    set -l p (string split ' ' -- $spec)
    set -a A6CHEX (__tmux_lives_oklch_hex $p[1] $p[2] $p[3])
    set -l oi (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6CHEX[-1]))
    set -a A6CHUES $oi[3]
end
set -g A6CSRC (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6CHEX[1]))
set -g A6COUT (__tmux_lives_theme_constrain (__tmux_lives_theme_arrange centre $A6CHEX))
set -g A6CBAR (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6COUT[1]))
set -g A6CTXT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6COUT[7]))

t "constrain: stage two actually moved lightness (precondition for the next two)" 1 (test (math "abs($A6CTXT[1] - $A6CBAR[1])") -ge 0.40; and echo 1; or echo 0)
# NOT a general guarantee — renamed from "stage two preserves chroma" because
# it isn't one. This fixture's push lands at a lightness where sRGB still has
# chroma headroom, so the loss happens to be tiny here; it is NOT tiny in
# general. Proof the claim was false: changing ONLY this fixture's bar
# lightness (index 4) from 0.481931 to 0.560000 — still an ordinary in-range
# value, production code untouched — pushes text to L 0.97 instead of L 0.89
# and the SAME assertion (same 0.01 tolerance) measures a 70% chroma loss and
# fails. Near white or black, sRGB simply has nowhere for chroma to go; see
# the corrected docstring on __tmux_lives_theme_arrange and the sweep below,
# which pins the property that IS always true instead. Unaffected by WHICH
# raw index becomes text's pre-push source (see the next block): every
# A6CHEX entry shares the same chroma (0.05), so the comparison holds no
# matter which candidate the swap picks.
t "arrange: stage two's chroma request happens to survive at this bar lightness (NOT a general guarantee)" 1 (test (math "abs($A6CTXT[2] - $A6CSRC[2])") -lt 0.01; and echo 1; or echo 0)

# WHICH raw index becomes text's pre-push source is NOT pinned to index 1 —
# that was only ever true because stage one's swap did not fire for this
# fixture under the OLD `centre` table. Re-indexing `centre` (this task, to
# keep big roles off the light half of the ramp) moved bar close enough to
# text that the swap NOW fires here: text's real pre-push source becomes
# whichever of the six non-bar candidates sits furthest from bar in
# lightness, and this fixture's re-index made that index 7, not index 1
# (measured directly: the final hue lands at ~340 degrees, matching index
# 7's H=340, not index 1's H=20). A comparison hardcoded to index 1 broke as
# a direct result — the BEHAVIOUR stayed correct throughout (measured hue
# drift ~0.25 degrees against whichever candidate actually fed stage two),
# only the test's assumed source was wrong.
#
# A first fix matched the final hue against whichever of the seven KNOWN
# candidate hues it landed nearest to (they are 40-60 degrees apart, far
# wider than stage two's own ~1-degree drift or this assertion's 2-degree
# tolerance) and was REJECTED on review: with only 7 known constants, a
# regression in the swap's own selection loop (now inside
# __tmux_lives_theme_constrain, conf.d/tmux-lives-install.fish:728-737) that
# simply picks the WRONG
# candidate still lands the output almost exactly on THAT candidate's own
# hue — push preserves whatever hue it is handed — so a nearest-hue check
# cannot tell "stage one picked the correct candidate" from "stage one
# picked a different, but still known, candidate". That needs ZERO hue
# corruption to slip through, which is worse than the bug this assertion
# exists to catch.
#
# Fixed instead by REIMPLEMENTING production's own selection rule here.
# A6CLITL holds the same literal L constants used to build A6CHEX above (not
# the round-tripped OKLCH values, to mirror exactly what production itself
# compares). Bar's own raw index is derived by finding whichever constant is
# closest to the ACTUALLY MEASURED $A6CBAR[1] — round-trip quantisation is a
# small fraction of the real gaps between the seven constants, so this is
# unambiguous — then the winner is whichever of the OTHER six indices has
# the MAXIMUM lightness distance from bar: exactly the two-line selection
# __tmux_lives_theme_arrange's stage-one swap performs (mathematically
# equivalent to it, not just similar — production's loop starts its "best"
# at text's own original distance and only replaces it on a strictly larger
# one found among the other five, which is the same result as a plain
# argmax over all six non-bar candidates). The assertion then checks the
# final hue against THAT specific candidate's hue, not merely the nearest
# known one. This does reimplement a slice of production's own logic in the
# test, which this file otherwise avoids — done here because it is the only
# way to tell "the correct candidate won" from "a different, but still
# known, candidate won", a distinction proximity-to-output can never make.
set -g A6CLITL 0.173048 0.285016 0.386656 0.481931 0.572684 0.659958 0.744429
set -g A6CBARIDX 1
set -l bestbd 999
for i in (seq 7)
    set -l d (math "abs($A6CLITL[$i] - $A6CBAR[1])")
    if test "$d" -lt "$bestbd"
        set bestbd $d
        set A6CBARIDX $i
    end
end
set -g A6CWINIDX $A6CBARIDX
set -l bestwd -1
for i in (seq 7)
    test $i -eq $A6CBARIDX; and continue
    set -l d (math "abs($A6CLITL[$i] - $A6CBAR[1])")
    if test "$d" -gt "$bestwd"
        set bestwd $d
        set A6CWINIDX $i
    end
end
set -l A6CDH (math "abs($A6CTXT[3] - $A6CHUES[$A6CWINIDX])")
test "$A6CDH" -gt 180; and set A6CDH (math "360 - $A6CDH")
t "constrain: stage two preserves hue (within tolerance)" 1 (test "$A6CDH" -lt 2; and echo 1; or echo 0)

# NOT redundant with the sweep immediately below, despite both now routing
# through `__tmux_lives_theme_constrain (__tmux_lives_theme_arrange centre
# ...)` with the same 2-degree tolerance: the sweep deliberately RIGS its own
# fixture so index 1 wins the stage-one swap by construction at every step
# (every other candidate is pinned to bar's OWN lightness that step, so its
# distance to bar is ~0), which isolates stage two's PUSH from stage one's
# SWAP decision entirely — it proves push preserves hue in general,
# independent of what the swap does. The block above rigs nothing: it is
# the one place in the suite where a real, un-rigged bar/candidate
# relationship reaches the swap, and — since the fix above independently
# reimplements the swap's own selection rule to know which candidate SHOULD
# win — it now also proves the swap actually picked that candidate, not
# merely that push preserved whatever hue it happened to be handed. That is
# still not an independent proof the selection rule ITSELF is sound: the
# test's reimplementation and production's own logic are the same two-line
# rule, stated twice, and a shared latent bug in the rule would pass both.
# It proves production's real behaviour matches its own documented
# algorithm for one real, unrigged case; the sweep proves the push half in
# isolation, over a range — but only because its OWN call site also routes
# through constrain. It shipped calling bare `arrange` instead: post-move
# that performs no swap and no push, `centre` maps role 7 to raw index 1
# unconditionally, so `txt` and `src` were the same colour through the same
# functions on every iteration and `dh` could not fail no matter what the
# push did. A tautology, not a proof — caught in review, fixed by the same
# wrap used everywhere else in this file.

# The property that IS universal is hue preservation — prove it across a
# SWEEP of bar lightnesses, not a single point. Fixture: text's candidate
# (index 1) is pinned at L 0.15/C 0.05/H 20 for every step; every OTHER
# candidate (indices 2,3,5,6,7) is set to bar's OWN lightness (index 4) each
# step, so it always loses the swap's "furthest from bar" contest by
# construction (its distance to bar is ~0, while index 1's is not) —
# guaranteeing text's source is index 1 on every step regardless of where bar
# sits, so the sweep isolates stage two's PUSH behaviour from the swap.
set -g A6HSWEEP_OK 1
for barL in 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90
    set -l hx
    for spec in "0.15 0.05 20" "$barL 0.05 80" "$barL 0.05 140" "$barL 0.05 200" "$barL 0.05 260" "$barL 0.05 300" "$barL 0.05 340"
        set -l p (string split ' ' -- $spec)
        set -a hx (__tmux_lives_oklch_hex $p[1] $p[2] $p[3])
    end
    set -l src (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $hx[1]))
    set -l out (__tmux_lives_theme_constrain (__tmux_lives_theme_arrange centre $hx))
    set -l txt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[7]))
    set -l dh (math "abs($txt[3] - $src[3])")
    test "$dh" -gt 180; and set dh (math "360 - $dh")
    test "$dh" -lt 2; or set -g A6HSWEEP_OK 0
end
t "constrain: stage two preserves hue across a sweep of bar lightnesses (0.20-0.90)" 1 $A6HSWEEP_OK

# arrange is a PURE permutation: every output colour is one of the inputs, even
# for a fixture narrow enough that the contrast floor would otherwise fire.
# This is what the recovery-based mapping tests depend on.
set -g A6PURE 1
set -g A6NARROW '#4a4a4a' '#565656' '#626262' '#6e6e6e' '#7a7a7a' '#868686' '#929292'
for pat in (__tmux_lives_theme_arrangements)
    for h in (__tmux_lives_theme_arrange $pat $A6NARROW)
        contains -- $h $A6NARROW; or set -g A6PURE 0
    end
end
t "arrange: is a pure permutation even on a narrow fixture" 1 $A6PURE
# ...and the floor still happens, just later: render must still enforce it.
set -g A6RF (__tmux_lives_theme_render '#5f772b' mono 0.30 0.12 0.5 centre)
set -g A6RFB (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6RF[1]))
set -g A6RFT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6RF[7]))
t "render: the text-contrast floor is still enforced after the move" 1 (test (math "abs($A6RFT[1] - $A6RFB[1])") -ge 0.40; and echo 1; or echo 0)

# --- v6 render: the three stages composed -----------------------------------
set -g V6 (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep)
t "render: returns seven role hexes" 7 (count $V6)
set -g V6HEXOK 1
for h in $V6
    string match -qr '^#[0-9a-f]{6}$' -- $h; or set -g V6HEXOK 0
end
t "render: every role is a valid lowercase hex" 1 $V6HEXOK

t "render: a non-hex seed returns nothing" 0 (count (__tmux_lives_theme_render 'notacolour' mono 0.40 0.15 0.5 deep))
t "render: an unknown mode returns nothing" 0 (count (__tmux_lives_theme_render '#5f772b' nonsense 0.40 0.15 0.5 deep))
t "render: an unknown arrangement returns nothing" 0 (count (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 nonsense))

# THE headline: the seed's own LIGHTNESS must now reach the output. In v5 the
# seed contributed hue and nothing else. Seed CHROMA deliberately still does not
# reach the output — peakC is authoritative, per Global Constraints, so a saved
# scheme renders identically whatever the seed's saturation. Do not add an
# assertion demanding seed chroma move the palette; it would contradict the
# design (measured: two seeds identical in H and L but C 0.03 vs 0.12 render the
# same palette to within one hex unit of round-trip noise).
set -g V6A (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep)
set -g V6B (__tmux_lives_theme_render '#5f7fbb' mono 0.40 0.15 0.5 deep)
t "render: a different seed HUE changes the palette" 1 (test "$V6A" != "$V6B"; and echo 1; or echo 0)
# The two seeds are HUE-MATCHED on purpose (#1b2602 H 124.94, #a5b58c H 125.13
# — 0.19 degrees apart) so only lightness varies. An earlier draft used #1a2010
# and #dfe8c8, which differ by 5.4 degrees of hue, so "the palettes differ" could
# be satisfied by the hue difference alone and proved nothing about lightness.
# And string inequality is a weak claim: assert the resulting lightness WINDOWS
# are disjoint. Measured: 0.058-0.459 for the dark seed, 0.550-0.962 for the
# light one.
set -g V6DARK (__tmux_lives_theme_render '#1b2602' mono 0.40 0.15 0.5 deep)
set -g V6LIGHT (__tmux_lives_theme_render '#a5b58c' mono 0.40 0.15 0.5 deep)
# The narrowed "own lightness still places the small roles" + "big roles no
# longer drag pale" assertion pair for this fixture lives further down, after
# __t6_bounds is defined (it measures the big-three bound directly) — see the
# "constrain: big-role lightness clamp" section below the palette-bounds
# helpers. $V6DARK/$V6LIGHT stay defined here, unchanged, for that use.

# the recipe fields must each move the output
t "render: peak chroma moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.04 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.24 0.5 deep | string join ','); and echo 1; or echo 0)
t "render: lightness span moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.20 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.70 0.15 0.5 deep | string join ','); and echo 1; or echo 0)
t "render: peak position moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.0 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 1.0 deep | string join ','); and echo 1; or echo 0)
t "render: arrangement moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 split | string join ','); and echo 1; or echo 0)
t "render: mode moves the palette" 1 (test (__tmux_lives_theme_render '#5f772b' mono 0.40 0.15 0.5 deep | string join ',') != (__tmux_lives_theme_render '#5f772b' triadic 0.40 0.15 0.5 deep | string join ','); and echo 1; or echo 0)

# Round-robin distribution: with a multi-hue mode, adjacent ramp positions must
# carry DIFFERENT hues, which is what makes a multi-hue palette cohere.
#
# Hue families need a TOLERANCE, never distinct rounded hues. Every colour
# round-trips through sRGB and the gamut clamp shifts each one slightly, so a
# MONO palette also reports seven distinct rounded hues. Measured directly
# against this task's own Step 5 mutation: counting rounded hues gives 7 for the
# correct round-robin AND 7 for the all-one-anchor mutation — it discriminates
# nothing at all. Clustering with a 25-degree gap gives, through the full
# pipeline including arrange: mono 1/1, complementary 2/1, triadic 3/1,
# analogous 3/1, split 3/1, square 4/1, tetradic 4/1 (correct/mutated).
#
# __t6_families is defined HERE and reused by Task 5's range guard — one
# clustering implementation, not two.
#
# CIRCULAR, not linear: a plain sort-and-split treats 0 and 360 as maximally
# far apart instead of the same point, so an anchor whose two round-robin
# renders land on OPPOSITE sides of the seam (e.g. 359.76 and 0.24, 0.48
# degrees apart in reality) gets reported as two separate families. Measured
# through the real render pipeline by sweeping every integer seed hue 0-359
# through every mode and comparing the linear count against the mode's own
# anchor count (ground truth, since round-robin + the chroma floor never
# produces more or fewer chromatic families than there are anchors): 7 of
# 2520 hue/mode combinations over-count, all of them exactly this seam
# crossing. Regression assertions for four of them sit right below.
function __t6_families --description 'v6 test helper: seven hexes -> hue-family count. Clusters the CHROMATIC hues (C >= 0.020; a near-grey has no meaningful hue) with a 25-degree gap, treated CIRCULARLY (0 and 360 are the same point) so two renders of one anchor landing on opposite sides of the seam are not counted as separate families. Shared by the round-robin assertion and Task 5s range guard.'
    set -l chro
    for h in $argv
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        test "$o[2]" -ge 0.020; and set -a chro $o[3]
    end
    set -l n (count $chro)
    if test $n -eq 0
        echo 0
        return
    end
    if test $n -eq 1
        echo 1
        return
    end
    set -l sorted (printf '%s\n' $chro | sort -g)
    # n hues on a circle have n gaps, not n-1 -- the WRAP gap, from the
    # largest sorted value back around through 360/0 to the smallest, is a
    # real gap too, and it is exactly the one a linear sort-and-split never
    # computes at all.
    set -l gaps
    for i in (seq 1 $n)
        if test $i -eq $n
            set -a gaps (math "(360 - $sorted[$n]) + $sorted[1]")
        else
            # Capture the index FIRST: a command substitution inside a quoted
            # list subscript is a fish "Invalid index value" ERROR, banned in
            # this repo.
            set -l j (math "$i + 1")
            set -a gaps (math "$sorted[$j] - $sorted[$i]")
        end
    end
    # The largest of the n circular gaps IS the seam: excluding only it from
    # the split count is equivalent to rotating the circle so clustering
    # starts right after it, without ever building a rotated (and therefore
    # non-monotonic, wraparound-broken) array to walk linearly.
    set -l maxgap -1
    set -l maxidx $n
    for i in (seq 1 $n)
        if test "$gaps[$i]" -gt "$maxgap"
            set maxgap $gaps[$i]
            set maxidx $i
        end
    end
    set -l f 1
    for i in (seq 1 $n)
        test $i -eq $maxidx; and continue
        test "$gaps[$i]" -gt 25; and set f (math "$f + 1")
    end
    echo $f
end

# --- palette bounds ----------------------------------------------------------
# Bounds separating the palettes the user picked from the ones they rejected,
# derived from the liked set only and checked against the rejects as a holdout.
# See docs/superpowers/specs/2026-08-28-palette-constraints-design.md.
#   1. peak chroma           0.105 <= pk <= 0.180   (NOT enforced here — see below)
#   2. big-three mean chroma        <= 0.095
#   3. big-three max lightness      <= 0.70
# Roles are bar sep tabs active windows cap text; the big three are 1, 3 and 6.
#
# Bound 1 is deliberately NOT part of __t6_inbounds. At a dark seed the sRGB
# gamut caps peak chroma at 0.082 however much the recipe requests, so no engine
# change can satisfy it — it is the catalog's job to pick a workable peakC.
# __t6_bounds still REPORTS it so the surface plan can check it later.
function __t6_bounds --description 'v6 test helper: seven role hexes -> "<peakC> <big3meanC> <big3maxL>". The measuring instrument for the palette bounds.'
    # Arity guard, matching its sibling __t6_env: the big-three walk below is
    # `for i in 1 3 6`, which THROWS on short input rather than reporting
    # anything a caller can act on. A caller that lost a role wants a zeroed
    # measurement it can assert against, not a stack trace.
    test (count $argv) -eq 7; or begin
        echo "0 0 0"
        return
    end
    set -l Ls
    set -l Cs
    for h in $argv
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        set -a Ls $o[1]
        set -a Cs $o[2]
    end
    set -l pk 0
    for c in $Cs
        test "$c" -gt "$pk"; and set pk $c
    end
    set -l bigL 0
    for i in 1 3 6
        test "$Ls[$i]" -gt "$bigL"; and set bigL $Ls[$i]
    end
    printf '%s %s %s\n' $pk (math "($Cs[1] + $Cs[3] + $Cs[6]) / 3") $bigL
end

function __t6_inbounds --description 'v6 test helper: 1 if the seven hexes satisfy the two ENGINE-enforced bounds (big-three chroma and lightness). Bound 1 is the catalog s job and is excluded on purpose.'
    set -l b (string split ' ' -- (__t6_bounds $argv))
    test "$b[2]" -gt 0.095; and echo 0; and return
    test "$b[3]" -gt 0.70; and echo 0; and return
    echo 1
end

# The helper must measure, not merely run.
set -g B6M (string split ' ' -- (__t6_bounds '#4b4f48' '#82ab62' '#5d6c52' '#c9e0bb' '#a7c591' '#6f8b5b' '#c9e0bb'))
t "bounds: helper returns three fields" 3 (count $B6M)
# ...and it must survive short input rather than throwing out of `for i in 1 3 6`.
t "bounds: short input is measured as zeroes, not a stack trace" "0 0 0" (__t6_bounds '#4b4f48' '#82ab62' '#5d6c52')
t "bounds: peak chroma is the palette maximum, not the first role" 1 (test "$B6M[1]" -gt 0.10; and echo 1; or echo 0)
t "bounds: big-three max lightness ignores the small roles" 1 (test "$B6M[3]" -lt 0.70; and echo 1; or echo 0)

# The three sanity assertions above ride on the REFERENCE fixture, whose small
# roles (sep, active, windows, text) all happen to sit under the 0.70 bound
# too - proven by mutation: swapping the big-three index set from 1/3/6 to a
# contiguous 1/2/3 leaves the whole suite green, because sep's L (0.694) is
# higher than cap's (0.602) but still under 0.70. So nothing above actually
# PINS that the big three ARE bar/tabs/cap; a future "simplification" of that
# index set would silently start measuring the wrong three roles with every
# assertion above still passing.
#
# This fixture exists for ONE purpose: pin the index set itself, and it must
# NOT be folded into the reference fixture above - the reference fixture's
# job is the peakC/meanC/maxL sanity numbers, and its small roles being
# under-bound is exactly what makes it unable to do this job too. Big three
# (bar/tabs/cap, roles 1/3/6) are all comfortably dark (L 0.37-0.44, measured);
# sep (role 2, a SMALL role) is comfortably light (L 0.88, reusing the same
# light hex the reference/holdout fixtures already use for their light
# roles) - light enough that swapping it into the big three breaches 0.70 by
# a wide margin (0.88 vs 0.70), not a near-miss like the reference fixture's
# sep. Measured against BOTH index sets directly: big3maxL is 0.4396 at the
# real 1/3/6 and 0.8798 at the mutated 1/2/3.
set -g B6IDX (string split ' ' -- (__t6_bounds '#3d4238' '#c9e0bb' '#4a5744' '#7d9470' '#9fb692' '#3f4a3a' '#c9e0bb'))
t "bounds: big-three index set is bar/tabs/cap, not a contiguous window" 1 (test "$B6IDX[3]" -lt 0.70; and echo 1; or echo 0)
t "bounds: the index-set fixture also passes via __t6_inbounds" 1 (__t6_inbounds '#3d4238' '#c9e0bb' '#4a5744' '#7d9470' '#9fb692' '#3f4a3a' '#c9e0bb')

# HOLDOUT. Rejected by the user in live judgement, NOT used to derive anything.
# The pale-pink triadic violates bound 3 (big-three lightness 0.88) and the
# over-hot triadic violates bound 2 (big-three chroma 0.126); both are engine
# bounds. The flat foundation violates only bound 1, so it is asserted against
# __t6_bounds directly rather than through __t6_inbounds.
t "bounds holdout: the pale-pink triadic fails" 0 (__t6_inbounds '#4b4f48' '#96787b' '#f9c9cc' '#91a484' '#a0bddd' '#5d6875' '#c9e0bb')
t "bounds holdout: the over-hot triadic fails" 0 (__t6_inbounds '#b71445' '#65aeff' '#5b9a00' '#ffbac0' '#65a3ea' '#2d2424' '#c9e0bb')
set -g B6FLAT (string split ' ' -- (__t6_bounds '#4b4f48' '#8b9684' '#5c6c51' '#9eb38f' '#9eb38f' '#6d8b55' '#c3d9b4'))
t "bounds holdout: the flat foundation is under the peak-chroma floor" 1 (test "$B6FLAT[1]" -lt 0.105; and echo 1; or echo 0)
# ...and the palette they love must pass, or the bounds are simply wrong.
t "bounds: the reference mono passes the engine bounds" 1 (__t6_inbounds '#4b4f48' '#82ab62' '#5d6c52' '#c9e0bb' '#a7c591' '#6f8b5b' '#c9e0bb')

# --- constrain: big-role lightness clamp (bound 3) ---------------------------
# C1b: no arrangement table can fix a window that sits entirely above the
# bound. Measured: at a light seed with a narrow span, ramp index 1 reaches
# L 0.77. The clamp is what makes bound 3 unconditional.
set -g A6LIGHT (__tmux_lives_theme_render '#dfe8c8' mono 0.20 0.14 0.5 deep)
t "constrain: a light seed still yields seven roles" 7 (count $A6LIGHT)
set -g A6LB (string split ' ' -- (__t6_bounds $A6LIGHT))
# TWO-SIDED on purpose. The upper half is the bound; the lower half is what
# makes the assertion able to see an over-shooting clamp. Moving ONLY the
# nudge loop's exit test to 0.55 is invisible to every "did not fire" check
# below — that loop is unreachable unless the clamp fires — and it left the
# suite at ALL PASS while dumping every clamped big role a tenth of a unit
# darker than the bound requires. Measured here: 0.694068, hard against the
# 0.695 target; under that mutation it lands near 0.55.
t "constrain: a light seed's big roles stay under the lightness bound" 1 (test "$A6LB[3]" -le 0.70; and echo 1; or echo 0)
t "constrain: the clamp lands AT the bound rather than overshooting past it" 1 (test "$A6LB[3]" -gt 0.60; and echo 1; or echo 0)
# ...and the clamp must not fire when it is not needed. "Did not fire" has to be
# BYTE IDENTITY, not a bound check: this assertion used to read
# `$A6NB[3] -le 0.70`, which is precisely what a clamp that DID fire
# guarantees — a duplicate of the bound assertion two lines up, dressed as its
# opposite. Two over-firing mutations proved it blind: clamping at 0.55, and
# moving only the loop exit to 0.55, each left the suite at ALL PASS while
# changing 1,414 of 3,024 renders.
#
# Byte identity through the WHOLE of constrain is the right instrument here and
# not an over-reach: for this fixture the chroma clamp and no-white leave the
# big roles alone too (only text moves), so any difference in roles 1/3/6 means
# a clamp fired on a palette that did not need one.
function __t6_prearrange --argument-names seedHex mode Lspan peakC peakPos arrangement --description 'v6 test helper: everything __tmux_lives_theme_render does UP TO but not including constrain — anchors, ramp, round-robin, arrange — so a test can compare what constrain was handed against what it emitted. Its own fidelity is asserted below rather than assumed: constrain(prearrange(r)) must equal render(r).'
    set -l s (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 "$seedHex"))
    set -l anchors (__tmux_lives_theme_anchors $s[3] "$mode")
    set -l pairs (__tmux_lives_theme_ramp $s[1] "$Lspan" "$peakC" "$peakPos" 7)
    set -l na (count $anchors)
    set -l hexes
    for i in (seq 7)
        set -l lc (string split ' ' -- $pairs[$i])
        # Capture the index FIRST — a command substitution inside a quoted list
        # subscript is a fish "Invalid index value" ERROR, banned in this repo.
        set -l ai (math "(($i - 1) % $na) + 1")
        set -l ah $anchors[$ai]
        set -a hexes (__tmux_lives_oklch_hex $lc[1] $lc[2] $ah)
    end
    __tmux_lives_theme_arrange "$arrangement" $hexes
end
#
# The FIXTURE is load-bearing too, and the obvious one does not work: at
# #5f772b/mono/0.55/0.11/0.5/deep the big roles (1/3/6) enter at L 0.259 /
# 0.351 / 0.441, so a clamp mutated to 0.55 still does not fire on them and
# byte identity holds either way — measured, both mutations stayed ALL PASS
# against that fixture.
# The fixture must sit BETWEEN the mutated threshold and the real one, so the
# guard below pins that window rather than leaving it to be re-broken silently.
set -g A6NOFIRE_PRE (__t6_prearrange '#87cb48' mono 0.45 0.13 0.4 deep)
set -g A6NOFIRE_POST (__tmux_lives_theme_constrain $A6NOFIRE_PRE)
# The helper must reproduce render's own pipeline, or the comparison is against
# a palette constrain never saw.
set -g A6NOFIRE_REF (__tmux_lives_theme_render '#87cb48' mono 0.45 0.13 0.4 deep)
t "constrain: the pre-constrain helper reproduces render's pipeline" 1 (test "$A6NOFIRE_POST" = "$A6NOFIRE_REF"; and echo 1; or echo 0)
set -g A6NOFIRE_MAXL 0
for i in 1 3 6
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6NOFIRE_PRE[$i]))
    test "$o[1]" -gt "$A6NOFIRE_MAXL"; and set -g A6NOFIRE_MAXL $o[1]
end
t "constrain: the no-fire fixture enters close under the clamp, not far below it" 1 (test "$A6NOFIRE_MAXL" -gt 0.60; and test "$A6NOFIRE_MAXL" -lt 0.695; and echo 1; or echo 0)
set -g A6NOFIRE 1
for i in 1 3 6
    test "$A6NOFIRE_PRE[$i]" = "$A6NOFIRE_POST[$i]"; or set -g A6NOFIRE 0
end
t "constrain: a normal seed is untouched by the lightness clamp" 1 $A6NOFIRE

# The seed's lightness still places the palette, but the BIG roles are now
# clamped so a light seed cannot drag the large surfaces pale. The claim
# therefore narrows to the small roles (2 sep, 4 active, 5 windows, 7 text).
# $V6DARK/$V6LIGHT are the hue-matched pair set far above, before this
# section — unchanged from their original definition.
#
# Narrowed AGAIN by task 6 (no-white): text (7) is dropped from this set.
# Its lightness is governed by the contrast floor against bar, not by the
# seed — and the floor's light-side ceiling is now 0.88, so the light
# direction is only reachable when bar <= 0.48 (up = bar + 0.40 <= 0.88).
# V6LIGHT's own bar sits at L 0.550, so up = 0.95 > 0.88 and the floor
# correctly falls to the dark side (measured: text lands at L 0.142) even
# though the seed itself is light — the floor overriding the seed here is
# the no-white rule doing its job, not a defect in either.
set -g V6DARKMAXL 0
for i in 2 4 5
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $V6DARK[$i]))
    test "$o[1]" -gt "$V6DARKMAXL"; and set -g V6DARKMAXL $o[1]
end
set -g V6LIGHTMINL 1
for i in 2 4 5
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $V6LIGHT[$i]))
    test "$o[1]" -lt "$V6LIGHTMINL"; and set -g V6LIGHTMINL $o[1]
end
t "render: the seeds own LIGHTNESS still places the small roles" 1 (test "$V6DARKMAXL" -lt "$V6LIGHTMINL"; and echo 1; or echo 0)
set -g V6LIGHTB (string split ' ' -- (__t6_bounds $V6LIGHT))
t "render: but a light seed no longer drags the big roles pale" 1 (test "$V6LIGHTB[3]" -le 0.70; and echo 1; or echo 0)

# Review-caught MINOR: the paragraph above narrowed a claim by hand-verified
# prose alone ("V6LIGHT's own bar sits at L 0.550... text lands at L 0.142")
# with nothing pinning the surprising part real: a LIGHT seed whose bar
# exceeds ~0.48 gets its own text forced DARK, not light. Make it an
# assertion rather than a comment.
set -g V6LIGHTTXT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $V6LIGHT[7]))
t "render: a light seed with bar > 0.48 still gets DARK text, not light" 1 (test "$V6LIGHTTXT[1]" -lt 0.30; and echo 1; or echo 0)

# Review-caught IMPORTANT: the clamp only ever passes the ROLE's OWN measured
# chroma/hue into __tmux_lives_oklch_hex, but that function gamut-clamps
# internally, and the sRGB ceiling at L 0.70 is lower than at the pre-clamp
# lightness and is hue-dependent, not monotonic. So "hue and chroma survive"
# is not fully true — hue does (drift stays under 0.5 degrees even under gamut
# pressure), chroma does not always (a saturated, light big role pulled down
# to 0.70 can lose real chroma when the new, lower ceiling is the binding
# constraint — see the comment above the clamp in production for the measured
# worst case). What CAN be pinned is the common case: when the recipe stays
# inside the catalog's own peakC range and the gamut has headroom at both
# lightnesses, chroma should survive the clamp materially intact rather than
# being silently discarded. Direct fixtures via __tmux_lives_theme_constrain,
# not through render/arrange — role 1 (bar) is never touched by the floor
# stage below (only out[7], and only out[2..6] as swap candidates), so
# inspecting out[1] after constrain isolates the lightness clamp's effect on
# chroma from everything else in this function.
#
# Swept across three widely separated hues so this is not cherry-picked at one
# point on the wheel; each iteration also proves the clamp actually FIRED
# (source L > 0.70, result L <= 0.70), so the gap check cannot pass vacuously
# on a fixture that never reached the clamp.
#
# Tolerance 0.01 absolute: measured drift for a genuinely in-gamut role is
# ~0.0004-0.0011 (an order-of-magnitude margin below 0.01), while a
# constructed near-gamut-edge case measured up to ~0.04 absolute — so 0.01 is
# loose enough to absorb ordinary float/gamut noise but tight enough to catch
# a regression that discards the requested chroma outright.
set -g A6CGAP_OK 1
for H in 60 120 240
    set -l srchex (__tmux_lives_oklch_hex 0.83 0.11 $H)
    set -l srclc (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $srchex))
    set -l fix $srchex '#82ab62' '#5d6c52' '#c9e0bb' '#a7c591' '#6f8b5b' '#c9e0bb'
    set -l out (__tmux_lives_theme_constrain $fix)
    set -l postlc (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    test "$srclc[1]" -gt 0.70; or set -g A6CGAP_OK 0
    test "$postlc[1]" -le 0.70; or set -g A6CGAP_OK 0
    set -l gap (math "abs($postlc[2] - $srclc[2])")
    test "$gap" -le 0.01; or set -g A6CGAP_OK 0
end
t "constrain: chroma survives materially intact when the gamut allows it" 1 $A6CGAP_OK

# --- constrain: big-role chroma clamp (bound 2) -------------------------------
# Bound 2: the three large surfaces must not compete. Scale their chroma down
# together, preserving their relative structure rather than flattening them.
set -g A6HOT (string split ' ' -- (__t6_bounds (__tmux_lives_theme_render '#87cb48' triadic 0.62 0.14 0.5 centre)))
t "constrain: big-three chroma is held under the bound" 1 (test "$A6HOT[2]" -le 0.095; and echo 1; or echo 0)
# The clamp must SCALE, not flatten: the three keep their relative order.
set -g A6SCALED (__tmux_lives_theme_render '#87cb48' triadic 0.62 0.14 0.5 centre)
set -g A6SC1 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6SCALED[1]))
set -g A6SC3 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6SCALED[3]))
t "constrain: the clamp scales rather than flattening (big roles still differ)" 1 (test (math "abs($A6SC1[2] - $A6SC3[2])") -gt 0.005; and echo 1; or echo 0)
# The peak belongs on a SMALL role. deep puts ramp index 4 - where peakPos 0.5
# peaks - on sep, so a vivid recipe keeps its peak.
set -g A6VIV (string split ' ' -- (__t6_bounds (__tmux_lives_theme_render '#7a00ff' triadic 0.65 0.26 0.5 deep)))
t "constrain: a vivid recipe still reaches high chroma when its peak is on a small role" 1 (test "$A6VIV[1]" -ge 0.22; and echo 1; or echo 0)

# ...and scaling chroma must not undo the LIGHTNESS bound the previous stage
# just established. Re-encoding a role at a new chroma re-quantises it to 8-bit
# sRGB, which moves its lightness: measured, #00ffff/square/0.35/0.14/0.3/centre
# left role 6 at L 0.699986 after the lightness clamp and L 0.70124 after the
# chroma clamp. The clamp's target therefore carries 0.005 of headroom - see
# the comment on the clamp itself. These three combinations breached bound 3
# before that headroom existed; the shipped probe grid missed them because its
# third recipe asked for peakC 0.13 rather than 0.14.
set -g A6ERODE_OK 1
for pat in bright centre accent
    test (__t6_inbounds (__tmux_lives_theme_render '#87cb48' square 0.45 0.14 0.4 $pat)) -eq 1; or set -g A6ERODE_OK 0
end
t "constrain: the chroma clamp does not erode the lightness bound" 1 $A6ERODE_OK

# --- constrain: no white (C3) --------------------------------------------------
# C3: no role may be a near-neutral near-white. A tinted light colour is fine.
function __t6_nowhite_ok --description 'v6 test helper: 1 if no role is a near-neutral near-white'
    for h in $argv
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        test "$o[1]" -gt 0.88; and echo 0; and return
        if test "$o[1]" -gt 0.72
            test "$o[2]" -lt 0.055; and echo 0; and return
        end
    end
    echo 1
end
# square/centre at the user's own seed rendered cap #f8f3fb - L 0.97, chroma 0.008.
t "nowhite: the square recipe has no near-white role" 1 (__t6_nowhite_ok (__tmux_lives_theme_render '#87cb48' square 0.62 0.14 0.5 centre))
t "nowhite: a wide-span mono has no near-white role" 1 (__t6_nowhite_ok (__tmux_lives_theme_render '#5f772b' mono 0.70 0.14 0.5 bright))
# ...and no-white must not cost legibility: the floor still holds.
set -g A6NWF (__tmux_lives_theme_render '#5f772b' mono 0.70 0.14 0.5 bright)
set -g A6NWB (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6NWF[1]))
set -g A6NWT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6NWF[7]))
t "nowhite: the contrast floor still holds after the cap" 1 (test (math "abs($A6NWT[1] - $A6NWB[1])") -ge 0.40; and echo 1; or echo 0)

# Review-caught IMPORTANT: no-white ran before the floor, but neither of the
# floor's OWN two exit paths re-checked its result against the no-white
# bounds. The nudge loop only ever checked the 0.40 gap, and the fallback
# beneath it still targeted a literal 0.97. A live counter-example: bar sits
# at L 0.4798, so up = 0.8798 stays under the 0.88 ceiling and the loop tries
# the light side — but the round trip of that target lands 0.000215 short of
# the 0.40 gap, and every subsequent +0.01 nudge is immediately reclamped
# back to the SAME 0.88 candidate (identical hex, ten times), so the loop
# makes zero progress and falls through to the fallback, which used to emit
# a literal-0.97 near-white with no re-check at all.
t "nowhite: a stuck stage-two nudge does not fall through to white" 1 (__t6_nowhite_ok (__tmux_lives_theme_constrain '#475996' '#585b9b' '#554a88' '#695290' '#694681' '#7f5289' '#7c4778'))

# Review-caught IMPORTANT (miniature form): the loop's EARLY-BREAK exit is
# verified only against the 0.40 gap, never against the 0.88 ceiling itself —
# a target placed AT 0.88 can round trip UP past it (the mirror image of the
# stuck-loop case above, which rounds DOWN). Measured: this recipe's text
# lands at L 0.88045, a hair over the ceiling, on the loop's successful exit.
t "nowhite: the loop's early-break exit does not overshoot the ceiling" 1 (__t6_nowhite_ok (__tmux_lives_theme_render '#5f772b' mono 0.35 0.10 0.1 centre))

# Review-caught IMPORTANT (round 3): the C3 re-check above fixed no-white but
# introduced the mirror bug on the OTHER hard rule -- it clamps L down to
# satisfy the ceiling and never re-checks whether that clamp just eroded the
# 0.40 contrast floor it is not allowed to trade away. Live counter-example:
# bar L 0.479426, and the round-tripped candidate before C3 sits at
# L 0.880866 (0.000866 over the ceiling) -- clamping it down lands text at
# L 0.874739, gap 0.395313, under the floor. Both bounds must hold together.
function __t6_floor_ok --description 'v6 test helper: 1 if role 1 (bar) and role 7 (text) clear the 0.40 contrast gap'
    set -l b (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[1]))
    set -l t (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $argv[7]))
    test (math "abs($t[1] - $b[1])") -ge 0.40; and echo 1; or echo 0
end
set -g A6EROD (__tmux_lives_theme_render '#475996' mono 0.30 0.12 0.3 bright)
t "nowhite: the C3 clamp does not erode the contrast floor it must not trade away" 1 (__t6_floor_ok $A6EROD)
t "nowhite: the C3-clamp-erosion recipe also stays clear of white" 1 (__t6_nowhite_ok $A6EROD)

# --- constrain: C2, the floor's swap may only draw from the SMALL roles -------
# Spec constraint C2. The swap trades text for whichever colour sits furthest
# in lightness from bar — and if the candidate set includes a BIG role, the
# colour it receives in exchange is text's, which can be light. That promotes a
# large surface to the light end and breaks bound 3 in the one stage that runs
# after every clamp, so nothing downstream can catch it.
#
# The candidates are therefore 2 4 5 (sep, active, windows), never (seq 2 6).
# This is asserted at constrain's own contract boundary rather than through a
# rendered recipe on purpose: no shipped arrangement table reaches it today
# (swept, `best` is only ever 7, 5, 4 or 2), so a render-level assertion would
# pass vacuously and prove nothing. The table is exactly what a future task
# edits, which is why C2 is a property of constrain, not of the six tables.
#
# The fixture: bar L 0.659, text L 0.880 (gap 0.220, so the floor fires), and
# cap the furthest thing from bar at L 0.100. With big roles in the candidate
# set the swap picks cap, and cap comes back holding text's L 0.880 — measured,
# a big role emitted at L 0.879756, breaching bound 3 by 0.18 from an input
# whose big roles all entered at or below L 0.659.
set -g A6C2 (__tmux_lives_oklch_hex 0.66 0.05 140) (__tmux_lives_oklch_hex 0.55 0.09 140) (__tmux_lives_oklch_hex 0.60 0.05 140) (__tmux_lives_oklch_hex 0.50 0.08 140) (__tmux_lives_oklch_hex 0.45 0.07 140) (__tmux_lives_oklch_hex 0.10 0.04 140) (__tmux_lives_oklch_hex 0.8798 0.08 140)
# The fixture must actually reach the swap, or the assertion below is vacuous:
# every big role starts under the bound, and bar and text start inside the floor.
set -g A6C2IN 1
for i in 1 3 6
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6C2[$i]))
    test "$o[1]" -le 0.70; or set -g A6C2IN 0
end
set -g A6C2B (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6C2[1]))
set -g A6C2T (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6C2[7]))
test (math "abs($A6C2T[1] - $A6C2B[1])") -lt 0.40; or set -g A6C2IN 0
t "constrain C2: the swap fixture enters in bounds and inside the floor" 1 $A6C2IN
set -g A6C2OUT (__tmux_lives_theme_constrain $A6C2)
t "constrain C2: the floor's swap never promotes a big role to the light end" 1 (__t6_inbounds $A6C2OUT)
# ...and the floor it exists to serve still holds on the same fixture.
t "constrain C2: restricting the candidates still satisfies the contrast floor" 1 (__t6_floor_ok $A6C2OUT)

# --- constrain: the floor's swap partner is selected STRUCTURALLY, not by
# --- float argmax over measured lightness -------------------------------
# The swap picks text's partner by argmax over measured lightness. 188 of
# 2,142 floor-firing rows sit within 0.0005 of a tie; a flip exchanges a
# whole colour between two roles (worst measured 0.36 in lightness), and
# since a scheme is stored as a recipe, a future engine constant would
# silently repaint a theme the user had already chosen. Ramp indices are
# integers and distinct by construction, so selecting on them cannot tie.
#
# The discriminator is the `bright` arrangement — it is the only pattern
# where `text` sits at the dark end (ramp 1) while `bar` sits mid-ramp
# (ramp 4), which is the one genuine tie. Distances from bar's own ramp
# index, candidates being text (incumbent) and the small roles 2 sep /
# 4 active / 5 windows; a candidate must STRICTLY beat text.
#   deep   bar@1: text 6, sep 3, active 5, windows 4  -> text, no swap
#   bright bar@4: text 3, sep 1, active 3, windows 2  -> text (active ties, loses)
#   centre bar@3: text 2, sep 2, active 3, windows 4  -> windows, SWAP
#   split  bar@1: text 6, sep 2, active 4, windows 5  -> text, no swap
#   stack  bar@2: text 5, sep 3, active 4, windows 2  -> text, no swap
#   accent bar@3: text 4, sep 2, active 3, windows 1  -> text, no swap
set -g A6SWAPFIX (__tmux_lives_theme_render '#5fab40' mono 0.28 0.26 0.25 bright)
# Under the OLD float rule this renders #7aa26c #7cb568 #69945a #338000
# #9dbc93 #5e8550 #192c10 — active receives text's dark, saturated colour.
# Under the structural rule active keeps its light #b0c9a6 and stage two
# synthesises text instead. Both satisfy all three bounds, so the sibling
# assertions below test what they claim rather than failing incidentally.
t "swap: structural selection changes bright" "#7aa26c #7cb568 #69945a #b0c9a6 #9dbc93 #5e8550 #0d2c00" (string join ' ' $A6SWAPFIX)
t "swap: the changed bright palette still satisfies the engine bounds" 1 (__t6_inbounds $A6SWAPFIX)
t "swap: the changed bright palette still clears the contrast floor" 1 (__t6_floor_ok $A6SWAPFIX)
t "swap: the changed bright palette is not near-white anywhere" 1 (__t6_nowhite_ok $A6SWAPFIX)
# Five of six arrangements are byte-identical under both rules, so a
# rendered-output assertion on them proves nothing about which rule ran.
# These pin that they did NOT move.
t "swap: deep is unmoved by the structural rule" "#434841 #73a561 #53654d #bed8b5 #9abd8d #638557 #c6e1ba" (string join ' ' (__tmux_lives_theme_render '#5fab40' mono 0.55 0.11 0.50 deep))

# render() must pass the arrangement into constrain(). Comparing render's
# output against constrain-called-WITH-the-pattern over the SAME pre-arranged
# input diverges the moment render stops passing it: the left side stays
# structural while render falls back to the float rule. The earlier form
# compared render to a render-derived global and so held for ANY deterministic
# engine — it could not fail.
t "swap: render passes the arrangement through to constrain" (string join ' ' (__tmux_lives_theme_constrain (__t6_prearrange '#5fab40' mono 0.28 0.26 0.25 bright) bright)) (string join ' ' (__tmux_lives_theme_render '#5fab40' mono 0.28 0.26 0.25 bright))

# The seam bug is not hypothetical: these four seeds are real, reproducible
# over-counts against the OLD linear-sort implementation (found by the sweep
# described above), re-verified directly against it (mono #a33460 -> 2,
# triadic #5b6c00 -> 4, triadic #006a9d -> 4, square #435ab8 -> 5, all wrong)
# before being pinned here against the fixed one.
t "families: mono at a seed hue of exactly 0 is still one family (seam)" 1 (__t6_families (__tmux_lives_theme_render '#a33460' mono 0.40 0.18 0.5 deep))
t "families: triadic at seed hue ~120 stays three families across the seam" 3 (__t6_families (__tmux_lives_theme_render '#5b6c00' triadic 0.40 0.18 0.5 deep))
t "families: triadic at seed hue ~240 stays three families across the seam" 3 (__t6_families (__tmux_lives_theme_render '#006a9d' triadic 0.40 0.18 0.5 deep))
t "families: square at seed hue ~270 stays four families across the seam" 4 (__t6_families (__tmux_lives_theme_render '#435ab8' square 0.40 0.18 0.3 deep))

set -g V6TRI (__tmux_lives_theme_render '#5f772b' triadic 0.40 0.18 0.5 deep)
t "render: round-robin gives a triadic palette three hue families" 3 (__t6_families $V6TRI)
set -g V6SQ (__tmux_lives_theme_render '#5f772b' square 0.40 0.18 0.5 deep)
t "render: round-robin gives a square palette four hue families" 4 (__t6_families $V6SQ)
set -g V6MONO (__tmux_lives_theme_render '#5f772b' mono 0.40 0.18 0.5 deep)
t "render: mono stays one hue family" 1 (__t6_families $V6MONO)

# The family COUNT above still cannot see round-robin's actual ORDERING, and
# three separate mutations prove it. Visiting the anchors in REVERSE is still
# round-robin and leaves every family count identical. CONTIGUOUS blocks — the
# exact thing round-robin exists to prevent — still yield three families at
# triadic and fail only at square, so half the count assertions passed for the
# wrong reason. And blocks chosen to preserve anchor MULTIPLICITY (1 1 1 2 2 3 3)
# would evade a multiplicity check too. So pin the documented mapping itself:
# ramp position p must carry hue anchor ((p - 1) % na) + 1.
#
# render returns ROLE order, so recover ramp order first by asking arrange where
# seven distinguishable inputs land. DERIVED, never hardcoded — the pattern's
# index list lives inside a switch the test cannot read, and a hardcoded inverse
# would rot silently if the pattern were ever retuned. The fixture is WIDE for
# historical reasons: before the contrast floor moved out of arrange into
# __tmux_lives_theme_constrain, that width kept the swap alone satisfying the
# floor so stage two never fired and no colour got replaced inside arrange.
# arrange has no text floor at all any more — it is a pure permutation
# unconditionally, regardless of fixture width — so a replaced colour can no
# longer break the recovery here; the fixture's integrity is still asserted
# rather than assumed, just no longer for that reason.
set -g V6FIX '#1d1d1d' '#3a3a3a' '#575757' '#747474' '#919191' '#aeaeae' '#f2f2f2'
set -g V6PERM (__tmux_lives_theme_arrange deep $V6FIX)
set -g V6FIXOK 1
for h in $V6PERM
    contains -- $h $V6FIX; or set -g V6FIXOK 0
end
t "render: the permutation-recovery fixture survives arrange intact" 1 $V6FIXOK
set -g V6IDX
for r in (seq 7)
    for p in (seq 7)
        test "$V6PERM[$r]" = "$V6FIX[$p]"; and set -a V6IDX $p
    end
end
t "render: the recovery resolved all seven ramp positions" 7 (count $V6IDX)

function __t6_mapping_ok --argument-names seedHex mode --description 'v6 test helper: render <seedHex> in <mode> with the deep arrangement, recover ramp order through the $V6IDX map built above, and return 1 only if ramp position p carries hue anchor ((p - 1) % na) + 1. Tolerance is 10 degrees rather than something tighter because the ramps two end positions sit at the chroma floor (0.012), where the sRGB round trip shifts hue by a couple of degrees — measured worst case 2.7, and the smallest real anchor separation is 30, so 10 has margin on both sides.'
    set -l pal (__tmux_lives_theme_render "$seedHex" "$mode" 0.40 0.18 0.5 deep)
    test (count $pal) -eq 7; or begin
        echo 0
        return
    end
    set -l s (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 "$seedHex"))
    set -l anchors (__tmux_lives_theme_anchors $s[3] "$mode")
    set -l na (count $anchors)
    set -l ramp
    for p in (seq 7)
        for r in (seq 7)
            test "$V6IDX[$r]" -eq "$p"; and set -a ramp $pal[$r]
        end
    end
    for p in (seq 7)
        # Capture the index FIRST: a command substitution inside a quoted list
        # subscript is a fish "Invalid index value" ERROR, banned in this repo.
        set -l want (math "(($p - 1) % $na) + 1")
        set -l wh $anchors[$want]
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $ramp[$p]))
        set -l d (math "abs($o[3] - $wh)")
        test "$d" -gt 180; and set d (math "360 - $d")
        test "$d" -le 10; or begin
            echo 0
            return
        end
    end
    echo 1
end

t "render: triadic maps ramp positions onto anchors round-robin" 1 (__t6_mapping_ok '#5f772b' triadic)
t "render: square maps ramp positions onto anchors round-robin" 1 (__t6_mapping_ok '#5f772b' square)
t "render: analogous maps ramp positions onto anchors round-robin" 1 (__t6_mapping_ok '#5f772b' analogous)
t "render: complementary maps ramp positions onto anchors round-robin" 1 (__t6_mapping_ok '#5f772b' complementary)

# determinism — the same recipe must always render the same palette, or a saved
# scheme could not be trusted
t "render: the same recipe renders identically twice" (__tmux_lives_theme_render '#5f772b' square 0.55 0.19 0.3 accent | string join ',') (__tmux_lives_theme_render '#5f772b' square 0.55 0.19 0.3 accent | string join ',')

# --- v6 range guard ---------------------------------------------------------
# THE regression guard for the actual v5 failure. Measured on v5 across all 24
# relationship x placement combinations at one seed: peak chroma spanned 0.001
# (0.084-0.085) and lightness span was byte-identical at 0.47-0.47. The whole
# 708-assertion suite passed. Nothing measured RANGE, so nothing could see it.
#
# Sample a spread of recipes and assert the OUTPUT ENVELOPE is genuinely wide.
# The users own liked palettes span peak chroma 0.044-0.247 and lightness span
# 0.20-0.69; the engine must be able to cover that, or it has the same defect
# wearing different code.
function __t6_env --description 'render a recipe and print "<peakC> <Lspan_ramp> <huefamilies> <Lspan_full>" measured back out of the seven hexes. Lspan_ramp covers the SIX non-text roles; Lspan_full covers all seven. See the comment below for why the recipe assertions use the ramp span.'
    set -l pal (__tmux_lives_theme_render $argv)
    test (count $pal) -eq 7; or begin; echo "0 0 0 0"; return; end
    # No Hs accumulator: hue is __t6_families' business, and an unread list here
    # would just be dead code.
    set -l Ls; set -l Cs
    for h in $pal
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        set -a Ls $o[1]; set -a Cs $o[2]
    end
    set -l maxC 0
    for c in $Cs; test "$c" -gt "$maxC"; and set maxC $c; end
    set -l minL 1; set -l maxL 0
    for l in $Ls
        test "$l" -lt "$minL"; and set minL $l
        test "$l" -gt "$maxL"; and set maxL $l
    end
    # TWO lightness spans, because they answer different questions.
    #
    # Lspan_full (all seven roles) is what is on screen, and it is FLOORED near
    # 0.40 for every recipe that exists — the one hard rule forces `text` to sit
    # 0.40 from `bar`, so when the ramp is too narrow to supply that gap,
    # arrange's stage two manufactures it. Measured across all six arrangements
    # at a requested span of 0.20: 0.4008 0.4014 0.4779 0.4008 0.4433 0.4655.
    # An assertion of the form "a narrow recipe has a narrow FULL span" is
    # therefore unsatisfiable for any recipe whatsoever — the first draft of
    # this task asserted < 0.35 and could never have gone green.
    #
    # Lspan_ramp (the six non-text roles) is the span the RECIPE controls, and
    # it tracks the request cleanly — measured, requested 0.10/0.20/0.30/0.40/
    # 0.50/0.60 yields 0.083/0.167/0.251/0.334/0.415/0.501, a consistent 5/6 of
    # the request because dropping the text role drops one of seven positions.
    # The recipe assertions below use this one. Do NOT "fix" the discrepancy by
    # loosening the text floor: legibility is the one thing the spec calls
    # correctness rather than taste.
    set -l rampL
    for h in $pal[1..6]
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        set -a rampL $o[1]
    end
    set -l rsorted (printf '%s\n' $rampL | sort -g)
    # Hue families need a TOLERANCE, not distinct rounded hues — every colour
    # round-trips through sRGB and the gamut clamp shifts each one slightly, so
    # even a MONO palette reports seven distinct rounded hues. __t6_families
    # (defined in Task 4) does the 25-degree clustering; call it rather than
    # inlining a second copy of the same logic.
    set -l fam (__t6_families $pal)
    printf '%s %s %s %s\n' $maxC (math "$rsorted[-1] - $rsorted[1]") $fam (math "$maxL - $minL")
end

# NB the VIVID probe uses a PURPLE seed deliberately. Peak chroma is capped by
# the sRGB gamut and that cap is hue-dependent: requesting 0.26 yields 0.260 at
# purple, 0.254 at red and 0.240 at pink, but only 0.153 at green and 0.140 at
# cyan. peakC is a REQUEST, not a guarantee. A green seed here would make the
# high-end assertion unsatisfiable through no fault of the engine — which is
# exactly what the first draft of this plan did.
set -g E6MUTED (string split ' ' -- (__t6_env '#5f772b' mono 0.25 0.04 0.5 deep))
# deep, not accent: bound 2 scales big-role chroma down, so a recipe whose peak
# lands on a big role no longer reaches the high end. The peak belongs on a
# small role — which is where it sits in the palette the user likes most.
set -g E6VIVID (string split ' ' -- (__t6_env '#7a00ff' triadic 0.65 0.26 0.5 deep))

t "range: a muted recipe stays muted" 1 (test "$E6MUTED[1]" -lt 0.08; and echo 1; or echo 0)
t "range: a vivid recipe actually reaches high chroma" 1 (test "$E6VIVID[1]" -gt 0.20; and echo 1; or echo 0)
t "range: peak chroma spans a REAL interval, not v5's 0.001" 1 (test (math "$E6VIVID[1] - $E6MUTED[1]") -gt 0.10; and echo 1; or echo 0)

# Field 2 is the RAMP span (six non-text roles) — the span the recipe actually
# controls. Thresholds are measured, not guessed: the muted recipe yields
# 0.2099 and the vivid one 0.5417. Every one of these still rejects v5, which
# measures 0.4676-0.4684 under BOTH span definitions.
t "range: a narrow recipe has a narrow lightness span" 1 (test "$E6MUTED[2]" -lt 0.30; and echo 1; or echo 0)
t "range: a wide recipe has a wide lightness span" 1 (test "$E6VIVID[2]" -gt 0.50; and echo 1; or echo 0)
t "range: lightness span VARIES, unlike v5's identical 0.47" 1 (test (math "$E6VIVID[2] - $E6MUTED[2]") -gt 0.20; and echo 1; or echo 0)

# ...and the cross-subsystem interaction that forced the two-span split above:
# even when the ramp is far too narrow to supply it, the FULL palette still
# spans at least the text floor, because arrange manufactures the gap. Nothing
# else in the suite pins the ramp and the hard rule meeting each other.
t "range: the text floor widens the full palette even on a narrow ramp" 1 (test "$E6MUTED[4]" -ge 0.40; and echo 1; or echo 0)

t "range: mono yields one hue family" 1 "$E6MUTED[3]"
set -g E6SQ (string split ' ' -- (__t6_env '#5f772b' square 0.70 0.19 0.3 split))
t "range: square yields four hue families" 4 "$E6SQ[3]"
t "range: triadic yields more than one" 1 (test "$E6VIVID[3]" -gt 1; and echo 1; or echo 0)

# The envelope must COVER the neighbourhood of the user's liked palettes, which
# span peak chroma 0.044-0.247 and lightness span 0.20-0.69. Held as a holdout,
# never as training data: the question they answered was "do I like these
# colours", not "should this be a scheme".
#
# Widened from 0.06 by the no-white fix (review-caught): E6MUTED's own text
# role is pushed to L~0.81 by the PRE-EXISTING legibility floor regardless of
# the recipe's requested chroma, and once C3 correctly re-checks BOTH of the
# floor's exit paths, that pushed-light role can no longer stay near-neutral
# — it is floored at C 0.055 and the hex round trip can nudge it up further.
# Measured across six seeds at this exact recipe: 0.055-0.061, never lower.
# This is a structural floor, not a fluke of one seed: any sufficiently
# muted recipe whose ramp gets a role pushed light for legibility now has
# its peak chroma bounded below by ~0.06, not by whatever the recipe asked
# for. 0.07 keeps real margin above the measured band while still meaning
# "low end" against E6VIVID's 0.26.
#
# NB (review-caught): this 0.0605 measured floor sits ABOVE the 0.044 low
# end of the user's own liked-palette holdout quoted two paragraphs up. That
# gap is a legitimate, accepted cost of the no-white rule -- the user chose
# it knowingly (see [[never-white-and-muted-is-a-destination]]) -- not a
# defect, and not something a future fix should try to close by loosening
# the no-white chroma floor. Do not read the 0.07 bound here as evidence the
# engine still reaches 0.044; it no longer can, once a role is pushed light.
t "range: the envelope reaches the low end of the users liked palettes" 1 (test "$E6MUTED[1]" -le 0.07; and echo 1; or echo 0)
t "range: the envelope reaches the high end of the users liked palettes" 1 (test "$E6VIVID[1]" -ge 0.22; and echo 1; or echo 0)

# The gamut cap is hue-dependent and that is CORRECT — sRGB cannot hold high
# chroma at every hue. Pin it so nobody later "fixes" the green case by
# uncapping the clamp and shipping out-of-gamut colours.
set -g E6GREEN (string split ' ' -- (__t6_env '#5f772b' mono 0.45 0.26 0.5 deep))
set -g E6PURPLE (string split ' ' -- (__t6_env '#7a00ff' mono 0.45 0.26 0.5 deep))
t "range: the same requested chroma is gamut-capped differently by hue" 1 (test (math "$E6PURPLE[1] - $E6GREEN[1]") -gt 0.05; and echo 1; or echo 0)

# --- Task 7: the bounds guard across arrangements and seeds ------------------
# The regression guard for the palette constraints. Every arrangement, at seeds
# spanning the space that broke things: the user's own, a dark one, a light one,
# a saturated one, a desaturated one. Bound 1 is excluded by construction -
# see __t6_inbounds - because the gamut, not the engine, decides it.
set -g A6FAILS
for seed in '#87cb48' '#5f772b' '#2f6fb3' '#7a00ff' '#dfe8c8' '#1a2010'
    for pat in (__tmux_lives_theme_arrangements)
        for recipe in 'mono 0.55 0.11 0.5' 'triadic 0.62 0.14 0.5' 'square 0.45 0.13 0.4'
            set -l rc (string split ' ' -- $recipe)
            set -l pal (__tmux_lives_theme_render $seed $rc[1] $rc[2] $rc[3] $rc[4] $pat)
            if test (count $pal) -ne 7
                set -a A6FAILS "$seed/$rc[1]/$pat:norender"
                continue
            end
            test (__t6_inbounds $pal) -eq 1; or set -a A6FAILS "$seed/$rc[1]/$pat"
            # no-white belongs in the ratchet too, and specifically because its
            # LIGHTNESS half had no coverage at all: disabling only the L > 0.88
            # branch (leaving the chroma floor intact) left the whole suite at
            # ALL PASS while 703 of 3,024 swept renders breached no-white, some
            # at L 0.97. Every targeted `nowhite:` assertion picks a recipe
            # where the CHROMA branch sets the changed flag and the nudge loop
            # enforces the ceiling as a side effect, so none of them can see the
            # lightness branch. 678 of those violations already carried
            # C >= 0.055, so only the lightness cap can rescue them — and the
            # first is this grid's own first seed and first recipe.
            test (__t6_nowhite_ok $pal) -eq 1; or set -a A6FAILS "$seed/$rc[1]/$pat:white"
        end
    end
end
t "bounds: every arrangement satisfies the engine bounds and no-white at every probe seed" 0 (count $A6FAILS)
# Surface WHICH combinations failed - a bare count sends the next reader hunting.
test (count $A6FAILS) -eq 0; or echo "  bounds failures: $A6FAILS"

# --- Task 2: the v6 catalog ---------------------------------------------------
t "catalog v6: 42 rows" 42 (count (__tmux_lives_theme_catalog_v6))
t "catalog v6: 14 curated" 14 (count (__tmux_lives_theme_catalog_v6_default))
t "catalog v6: 28 in the rest" 28 (count (__tmux_lives_theme_catalog_v6_rest))
t "catalog v6: default + rest is the whole catalog" 42 (math (count (__tmux_lives_theme_catalog_v6_default)) + (count (__tmux_lives_theme_catalog_v6_rest)))
t "catalog v6: every row has 7 fields" 42 (__tmux_lives_theme_catalog_v6 | while read -l l; test (count (string split '|' -- $l)) -eq 7; and echo x; end | count)
t "catalog v6: names are unique" 42 (__tmux_lives_theme_catalog_v6 | string split -f1 '|' | sort -u | count)
t "catalog v6: all 7 modes present" 7 (__tmux_lives_theme_catalog_v6 | string split -f2 '|' | sort -u | count)
t "catalog v6: all 6 arrangements present" 6 (__tmux_lives_theme_catalog_v6 | string split -f6 '|' | sort -u | count)
t "catalog v6: the curated 14 cover all 6 arrangements" 6 (__tmux_lives_theme_catalog_v6_default | string split -f6 '|' | sort -u | count)
t "catalog v6: the curated 14 cover all 7 modes" 7 (__tmux_lives_theme_catalog_v6_default | string split -f2 '|' | sort -u | count)
t "recipe: mono deep is the known-liked classic" "mono 0.55 0.11 0.50 deep" (string join ' ' (__tmux_lives_theme_recipe 'mono deep'))
t "recipe: an unknown name yields nothing" "" (string join ' ' (__tmux_lives_theme_recipe 'no such scheme'))
t "recipe: defined" 1 (functions -q __tmux_lives_theme_recipe; and echo 1; or echo 0)

# Value-dimension spread is the property that stops this catalog recreating the
# v5 collapse (35 catalog rows, one palette shape with the hue nudged), so
# assert it directly rather than trusting the generation. All three are 4, not
# 3: the 41 generated rows use three values each (Lspan {0.30, 0.50, 0.70},
# peakC {0.13, 0.15, 0.17}, peakPos {0.35, 0.55, 0.75}), and mono deep — the
# hand-placed row — contributes a fourth of each (0.55, 0.11, 0.50). A value of
# 3 anywhere means a generated row was mistyped or mono deep was normalised
# onto the grid, which would lose the user's favourite palette.
t "catalog v6: Lspan is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f3 '|' | sort -u | count)
t "catalog v6: peakC is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f4 '|' | sort -u | count)
t "catalog v6: peakPos is spread, not pinned" 4 (__tmux_lives_theme_catalog_v6 | string split -f5 '|' | sort -u | count)

# Every catalog recipe must satisfy ALL THREE bounds at several seeds. Bound 1
# is the catalog's own contract — __t6_inbounds excludes it on purpose because
# no clamp can raise a rendered peak the sRGB gamut has capped.
set -g A6CATFAIL 0
set -g A6CATN 0
for s in '#5fab40' '#b7410e' '#2f6fb3'
    for e in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' -- $e)
        set -l p (__tmux_lives_theme_render $s $f[2] $f[3] $f[4] $f[5] $f[6])
        set -g A6CATN (math $A6CATN + 1)
        if test (count $p) -ne 7
            set -g A6CATFAIL (math $A6CATFAIL + 1)
            continue
        end
        set -l b (string split ' ' -- (__t6_bounds $p))
        if test "$b[1]" -lt 0.105; or test "$b[1]" -gt 0.180
            set -g A6CATFAIL (math $A6CATFAIL + 1)
        else if test (__t6_inbounds $p) -ne 1
            set -g A6CATFAIL (math $A6CATFAIL + 1)
        end
    end
end
# The vacuity guard: without this, a loop that silently rendered nothing would
# report zero failures on the assertion below and pass.
t "catalog v6: every recipe renders at all three seeds" 126 $A6CATN
t "catalog v6: every recipe satisfies all three bounds at all three seeds" 0 $A6CATFAIL

test $fail -eq 0; and echo "ALL PASS ($pass)"; or begin; echo "FAILED ($fail)"; exit 1; end
