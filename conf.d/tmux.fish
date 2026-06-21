# =====================================================================
# Auto-tmux: attach SSH logins to tmux, manage sessions, allow disable.
# Single source of truth. See docs/superpowers/specs/2026-06-09-auto-tmux-design.md
# =====================================================================

# ---- defaults (overridable by pre-set globals/universals) ----
set -q tmux_auto_sentinel; or set -g tmux_auto_sentinel "$HOME/.config/tmux/disable-auto"
set -q tmux_auto_stale_hours; or set -g tmux_auto_stale_hours 48
set -q tmux_auto_ghost_minutes; or set -g tmux_auto_ghost_minutes 5
set -q tmux_categorize_script; or set -g tmux_categorize_script "$__fish_config_dir/functions/tmux-categorize.fish"

# ---- selection ----
function __tmux_pick_candidates_from --description 'Read "attached last_attached name" lines; echo detached names, MRU first'
    set -l TAB (printf '\t')
    while read -l line
        test -n "$line"; or continue
        set -l f (string split -m 2 ' ' -- $line)
        test (count $f) -ge 3; or continue
        test "$f[1]" = 0; or continue                 # detached only
        set -l t $f[2]
        string match -qr '^[0-9]+$' -- "$t"; or set t 0
        printf '%s\t%s\n' $t $f[3]
    end | sort -t $TAB -k1,1nr | cut -f2-
end

function __tmux_pick_session --description 'Echo the MRU detached GENERAL session to resume, or nothing'
    for s in (tmux list-sessions -F '#{session_attached} #{session_last_attached} #{session_name}' 2>/dev/null \
                  | __tmux_pick_candidates_from)
        if __tmux_session_is_idle "$s"
            echo $s
            return
        end
    end
end

# ---- prune ----
function __tmux_session_is_idle --argument-names session --description 'True if every pane in the session runs only a shell'
    set -l panes (tmux list-panes -s -t $session -F '#{pane_current_command}' 2>/dev/null)
    # No panes reported (query failed or session vanished mid-prune): treat as
    # NOT idle so prune never kills a session it could not actually inspect.
    test -n "$panes[1]"; or return 1
    for cmd in $panes
        contains -- $cmd fish bash sh zsh dash; or return 1
    end
    return 0
end

function __tmux_prune --description 'Kill detached, idle-shell sessions older than tmux_auto_stale_hours'
    set -l now (set -q tmux_auto_now; and echo $tmux_auto_now; or date +%s)
    set -l cutoff (math "$now - $tmux_auto_stale_hours * 3600")
    for line in (tmux list-sessions -F '#{session_attached} #{session_activity} #{session_name}' 2>/dev/null)
        set -l f (string split -m 2 ' ' -- $line)
        test (count $f) -ge 3; or continue
        test "$f[1]" = 0; or continue                 # detached
        string match -qr '^[0-9]+$' -- "$f[2]"; or continue
        test "$f[2]" -lt "$cutoff"; or continue       # stale
        __tmux_session_is_idle "$f[3]"; or continue   # idle shell only
        tmux kill-session -t "$f[3]" 2>/dev/null
    end
end

# ---- categorize (logic lives in functions/tmux-categorize.fish) ----
# Spike result (2026-06-11, tmux 3.3a): a bare attach DOES immediately adopt the new
# client's size — the stale-dimensions bug therefore comes from a lingering ShellFish
# ghost re-taking "latest" status with later activity, so detaching stale clients
# before attach/switch remains the correct fix.
function __tmux_categorize --description 'Run a categorize pass (classify + rename all sessions)'
    env tmux_auto_ghost_minutes=$tmux_auto_ghost_minutes \
        fish --no-config $tmux_categorize_script categorize 2>/dev/null
end

function __tmux_detach_ghosts --argument-names session --description 'Detach stale (ghost) clients from a session'
    test -n "$session"; or return 0
    env tmux_auto_ghost_minutes=$tmux_auto_ghost_minutes \
        fish --no-config $tmux_categorize_script ghosts "$session" 2>/dev/null
end

# ---- restore helpers ----
function __tmux_resurrect_dir --description 'Resolve the resurrect save directory'
    if set -q tmux_resurrect_dir              # explicit override / test seam
        echo $tmux_resurrect_dir
        return
    end
    set -l d (tmux show-option -gqv @resurrect-dir 2>/dev/null)
    test -n "$d"; and echo $d; or echo "$HOME/.local/share/tmux/resurrect"
end

function __tmux_saved_claude_sessions --argument-names save --description 'Echo saved session names whose pane ran claude (resumable breadcrumbs)'
    test -e "$save"; or return
    # resurrect pane lines are tab-delimited: field 2 = session, field 10 = command.
    awk -F '\t' '$1 == "pane" && $10 == "claude" { print $2 }' "$save" 2>/dev/null | sort -u
end

function __tmux_dispose_restored --description 'Post-restore: keep claude breadcrumbs (unstamped) + live work (stamped); kill the idle rest'
    # Login restore is HEADLESS: resurrect never relaunches programs (verified
    # 2026-06-12 post-incident), so every session returns as bare shells and the
    # SAVE FILE decides what was worth keeping.
    set -l crumbs (__tmux_saved_claude_sessions (__tmux_resurrect_dir)/last)
    for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
        if contains -- $s $crumbs
            # Claude breadcrumb: a bare shell at the project cwd, ready for
            # `claude -r`. Deliberately UNSTAMPED so the ownership guard
            # preserves its meaningful name instead of reverting it to a number.
            continue
        end
        if __tmux_session_is_idle "$s"
            tmux kill-session -t "=$s" 2>/dev/null
        else
            tmux set-option -t "$s" @tmux_auto_name "$s" 2>/dev/null
        end
    end
end

function __tmux_restore --description 'First post-reboot login: restore the resurrect snapshot, then dispose live-idle sessions'
    # Start the server WITH a throwaway holder session rather than a bare `start-server`.
    # A freshly start-servered EMPTY server races exit-empty (default on) and dies before
    # restore.sh can populate it ("server exited unexpectedly"); a holder session keeps the
    # server alive deterministically. This matches resurrect's own design (it expects a
    # non-empty server and cleans up its placeholder "0" via handle_session_0). The holder
    # is killed once real sessions exist, and is never in the save file so prune ignores it.
    set -l holder __tmux_restore_holder_$fish_pid   # pid-suffixed so it can never match a saved session name
    tmux -u new-session -d -s $holder 2>/dev/null
    set -q tmux_resurrect_dir; and tmux set-option -g @resurrect-dir "$tmux_resurrect_dir"
    if not test -e (__tmux_resurrect_dir)/last
        tmux kill-session -t "$holder" 2>/dev/null
        return
    end
    tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/restore.sh
    # wait until restore finishes creating real sessions (up to ~5s)
    for i in (seq 50)
        test (tmux list-sessions 2>/dev/null | count) -gt 1; and break
        sleep 0.1
    end
    tmux kill-session -t "$holder" 2>/dev/null
    # Relaunched programs (nvim/tail/... via @resurrect-processes) appear via send-keys a
    # beat after restore.sh returns; settle before judging live state.
    sleep 1
    __tmux_dispose_restored
end

# ---- predicates ----
function __tmux_auto_enabled --description 'False if auto-tmux is disabled via sentinel or TMUX_AUTO=0'
    set -q TMUX_AUTO; and test "$TMUX_AUTO" = 0; and return 1
    test -e "$tmux_auto_sentinel"; and return 1
    return 0
end

# ---- context gate ----
function __tmux_should_autostart --description 'True when an SSH login should auto-attach tmux'
    set -q SSH_CONNECTION; or return 1
    set -q TMUX; and return 1
    command -q tmux; or return 1
    __tmux_auto_enabled
end

function __tmux_trace_in_function --description 'True if a stack-trace blob shows an enclosing function (e.g. fisher sourcing conf.d), i.e. NOT a genuine top-level startup'
    string match -q '*in function*' -- "$argv"
end

# ---- orchestrator ----
function __tmux_autostart --description 'Restore (first login after reboot), categorize, prune, then attach or create'
    command -q tmux; or return
    if not tmux has-session 2>/dev/null     # no server yet → first login after a reboot
        __tmux_restore
    end
    __tmux_categorize
    __tmux_prune
    set -l target (__tmux_pick_session)
    if test -n "$target"
        __tmux_detach_ghosts "$target"
        # -d guards the pick-to-exec race only; targets are detached generals, so this
        # kicks no one in practice (accepted race-window exception to no-blanket-kick).
        exec tmux -u attach-session -d -t "=$target"
    else
        exec tmux -u new-session
    end
end

# ---- user commands ----
function __tmux_lives_switch --description 'Categorized tmux session switcher / creator. ts [name]'
    if not command -q tmux
        echo "tmux not installed" >&2
        return 1
    end
    if test (count $argv) -gt 0
        # Sanitize like every system-applied name (spaces/:/. break tmux targets).
        set -l name (fish --no-config $tmux_categorize_script slug $argv[1])
        __tmux_detach_ghosts "$name"
        if set -q TMUX
            tmux new-session -d -s "$name" 2>/dev/null
            tmux switch-client -t "=$name"
        else
            tmux new-session -A -s "$name"
        end
        return
    end
    if set -q TMUX
        set -l client (tmux display-message -p '#{client_name}' 2>/dev/null)
        env tmux_auto_ghost_minutes=$tmux_auto_ghost_minutes \
            fish --no-config $tmux_categorize_script open-switcher "$client"
        return
    end
    # No server yet (local shell, post-reboot): cold-start the full flow.
    if not tmux has-session 2>/dev/null
        __tmux_autostart   # restore → categorize → prune → pick/create → exec attach
        return             # defensive: __tmux_autostart execs; only reached if stubbed (tests)
    end
    # Outside tmux: truth-up names, then grouped numbered list, then attach.
    fish --no-config $tmux_categorize_script categorize 2>/dev/null
    set -l lines (fish --no-config $tmux_categorize_script overview)
    if test (count $lines) -eq 0
        echo "No sessions. Create one with: tmux-lives switch <name>"
        return 1
    end
    set -l TAB (printf '\t')
    set -l names
    set -l group ''
    set -l i 0
    for line in $lines
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        if test "$f[2]" != "$group"
            set group $f[2]
            # Same palette as the display-menu headers (ff8700 ≈ tmux colour208 orange).
            set -l hcol ff8700
            test "$group" = running; and set hcol cyan
            test "$group" = general; and set hcol green
            set_color --bold $hcol; echo "$group:"; set_color normal
        end
        set i (math $i + 1)
        set -a names $f[1]
        set -l att ''
        test "$f[3]" = 1; and set att '  [attached]'
        printf '  %2d) %s%s\n' $i "$f[5]" "$att"
    end
    echo
    read -P 'switch to: ' pick
    string match -qr '^[0-9]+$' -- "$pick"
    and test "$pick" -ge 1 -a "$pick" -le (count $names)
    or return 0
    __tmux_detach_ghosts "$names[$pick]"
    tmux attach-session -t "=$names[$pick]"
end

# ---- rename hooks (inside tmux only) ----
function __tmux_rename_on_preexec --on-event fish_preexec --description 'Instant claude rename when you launch it'
    set -q TMUX; or return 0
    string match -qr '^\s*claude(\s|$)' -- "$argv[1]"; or return 0
    set -l raw (string match -r -- '--name\s+(.+)$' "$argv[1]")[2]
    # Drop trailing flags (" --resume", " -r") — same rule as __tcz_cmdline_name.
    set raw (string replace -r '(\s+--?\S+)+$' '' -- "$raw")
    fish --no-config $tmux_categorize_script claim "$TMUX_PANE" "$raw" "$PWD" >/dev/null 2>&1 &
    disown
end

function __tmux_categorize_on_postexec --on-event fish_postexec --description 'Re-categorize after each command (reverts on exit)'
    set -q TMUX; or return 0
    fish --no-config $tmux_categorize_script categorize >/dev/null 2>&1 &
    disown
end

function __tmux_lives_auto --description 'Control auto-tmux: on|off|status|toggle'
    switch "$argv[1]"
        case off
            mkdir -p (path dirname "$tmux_auto_sentinel")
            touch "$tmux_auto_sentinel"
            echo "auto-tmux: OFF (sentinel: $tmux_auto_sentinel). Affects future logins only."
        case on
            rm -f "$tmux_auto_sentinel"
            echo "auto-tmux: ON"
        case toggle
            if test -e "$tmux_auto_sentinel"
                __tmux_lives_auto on
            else
                __tmux_lives_auto off
            end
        case '' status
            if __tmux_auto_enabled
                echo "auto-tmux: ON"
            else if set -q TMUX_AUTO; and test "$TMUX_AUTO" = 0
                echo "auto-tmux: OFF (TMUX_AUTO=0 in this shell)"
            else
                echo "auto-tmux: OFF (sentinel: $tmux_auto_sentinel)"
            end
        case '*'
            echo "usage: tmux-lives auto on|off|status|toggle" >&2
            return 1
    end
end

function __tmux_lives_fixssh --description 'Refresh SSH_AUTH_SOCK and friends from the tmux session environment'
    if not set -q TMUX
        echo "tmux-lives fixssh: not inside tmux" >&2
        return 1
    end
    for var in SSH_AUTH_SOCK SSH_CONNECTION SSH_CLIENT DISPLAY
        set -l line (tmux show-environment $var 2>/dev/null)
        if string match -q "$var=*" -- $line
            set -gx $var (string replace -r "^$var=" '' -- $line)
        end
    end
end

function __tmux_lives_take --argument-names session --description 'Force-take a tmux session, detaching any (ghost) client'
    if test -z "$session"
        tmux list-sessions 2>/dev/null
        return
    end
    tmux -u attach-session -d -t "$session"
end

# ---- trigger (interactive SSH logins only) ----
# Skip when this file is being SOURCED from within a function — fisher re-sources
# conf.d on install/update, and that is never a genuine login; letting
# __tmux_autostart exec tmux there would hijack the install (no summary, partial
# state). A real top-level startup source has no enclosing function in the trace.
if status is-interactive; and not __tmux_trace_in_function (status print-stack-trace | string collect); and __tmux_should_autostart
    __tmux_autostart
end
