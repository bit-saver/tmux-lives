#!/usr/bin/env fish
# tmux-categorize: live-state session classification, naming, overview, menu, ghost-detach.
# Runs under `fish --no-config` (fast, no conf.d side effects — safe inside tmux #()).
# Spec: docs/superpowers/specs/2026-06-11-tmux-categorized-sessions-design.md
# Subcommands: categorize | tick | overview | menu | open-switcher <client> | popup <client> | claim <pane> <raw> <cwd> | ghosts <session> | switch <session> <client> | commandeer <client> <session> | slug <text...>
# Tests source this file with tmux_categorize_test set, which suppresses the dispatcher.

# Shell list — MUST match __tmux_session_is_idle in conf.d/tmux.fish (test-enforced).
set -g __tcz_shells fish bash sh zsh dash
# Boring pager/tailer commands: don't count as "running" for naming purposes.
set -g __tcz_boring tail less watch cat more bat
set -g __tcz_self (path resolve (status filename))

function __tcz_slugify --description 'argv -> tmux-safe session name ([A-Za-z0-9-])'
    # Callers must pass slugs with -- / -t "=$slug" style protection when handing them to tmux
    # (slug never starts with - after trim, but the contract should be explicit).
    set -l s (string join ' ' -- $argv)
    # Collapse every run of non-alphanumerics — INCLUDING dashes — to a single dash,
    # so an explicit name like "Foo - Bar" slugs to "Foo-Bar", not "Foo---Bar".
    set s (string replace -ra '[^A-Za-z0-9]+' '-' -- "$s")
    set s (string trim -c - -- "$s")
    test -n "$s"; and echo $s; or echo session
end

function __tcz_title_name --description 'claude pane title -> display name, or empty if unusable'
    # A trusted claude title always begins with a leading status-glyph WORD
    # (one or more non-space codepoints) followed by a space.
    # If that prefix is absent the title cannot be reliably parsed, so return nothing.
    string match -qr '^\S+\s' -- "$argv[1]"; or return
    set -l t (string replace -r '^\S+\s+' '' -- "$argv[1]")
    set t (string replace -r ' - .*$' '' -- "$t")
    string match -qr '[A-Za-z0-9]' -- "$t"; and echo $t
end

function __tcz_free_gen --description 'argv = taken names -> smallest free gen-N (N from 1)'
    set -l n 1
    while contains -- "gen-$n" $argv
        set n (math $n + 1)
    end
    echo "gen-$n"
end

function __tcz_unique --description '__tcz_unique <desired> <taken...> -> collision-free name'
    set -l desired $argv[1]
    set -l taken $argv[2..]
    if not contains -- $desired $taken
        echo $desired
        return
    end
    set -l n 2
    while contains -- "$desired-$n" $taken
        set n (math $n + 1)
    end
    echo "$desired-$n"
end

function __tcz_pid_comm --description 'pid -> executable name (portable: /proc on Linux, ps elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    if test -r /proc/$pid/comm; and not set -q tcz_force_ps
        cat /proc/$pid/comm 2>/dev/null
    else
        set -l c (ps -o comm= -p $pid 2>/dev/null | string trim)
        # `--`: a login shell's comm is "-fish"/"-bash"; without it path basename
        # parses the leading dash as an option and errors (macOS pane shells).
        test -n "$c"; and path basename -- $c
    end
end

function __tcz_pid_cmdline --description 'pid -> space-joined argv (portable: /proc on Linux, ps elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    if test -r /proc/$pid/cmdline; and not set -q tcz_force_ps
        string split0 < /proc/$pid/cmdline 2>/dev/null | string join ' '
    else
        ps -o args= -p $pid 2>/dev/null | string trim
    end
end

function __tcz_pid_environ --description 'pid -> environment KEY=VALUE lines (portable: /proc on Linux, ps elsewhere; test seam tmux_lives_fake_environ)'
    if set -q tmux_lives_fake_environ
        printf '%s\n' $tmux_lives_fake_environ
        return
    end
    set -l pid $argv[1]
    test -n "$pid"; or return
    if test -r /proc/$pid/environ; and not set -q tcz_force_ps
        tr '\0' '\n' < /proc/$pid/environ 2>/dev/null
    else
        ps eww -p $pid 2>/dev/null
    end
end

function __tcz_pid_children --description 'pid -> direct child pids (portable: /proc on Linux, pgrep elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    # `pgrep -P` walks every entry in /proc on each call, so it costs whatever the
    # host's process count costs — measured at ~140 ms on a 400-process Docker host
    # versus ~2 ms for this read. The tick called it 10x, which was 77% of a 1.9 s
    # tick and kept ~2 cores busy. Union across task/*: a multi-threaded process
    # forks from whichever thread ran, and `children` is per-thread. An unmatched
    # glob yields no iterations silently, which matters because this function's
    # stderr would land in the status bar.
    if test -d /proc/$pid/task; and not set -q tcz_force_ps
        for f in /proc/$pid/task/*/children
            string split -n ' ' <$f 2>/dev/null
        end
    else
        pgrep -P $pid 2>/dev/null
    end
end

function __tcz_client_terminal --argument-names pid --description 'client pid -> shellfish|iterm2|other, from LC_TERMINAL in the client process environ (__tcz_pid_environ; tmux_lives_fake_environ seam). The terminals that take per-tab color/title escapes.'
    # Substring match: works for Linux per-line environ AND macOS single-line `ps eww`.
    set -l env (__tcz_pid_environ $pid)
    if string match -q '*LC_TERMINAL=ShellFish*' -- $env
        echo shellfish
    else if string match -q '*LC_TERMINAL=iTerm2*' -- $env
        echo iterm2
    else
        echo other
    end
end

function __tcz_client_is_shellfish --argument-names pid --description 'true if the client process environment contains LC_TERMINAL=ShellFish (wrapper: __tcz_client_terminal = shellfish)'
    test (__tcz_client_terminal $pid) = shellfish
end

function __tcz_emit_barcolor --argument-names tty color --description 'write the ShellFish setbarcolor OSC for <color> to <tty> (non-passthrough; client-tty level)'
    test -n "$color"; or return 0
    printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' "$color" | base64 | string join '') > $tty
end

function __tcz_emit_itermtab --argument-names tty hex --description 'write iTerm2 tab-color escapes (OSC 6 triplet) to a client tty; non-hex -> the reset escape. The iTerm side of the ShellFish bar-color mirror.'
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$hex")
    if test (count $m) -eq 3
        set -l r (math "0x$m[1]")
        set -l g (math "0x$m[2]")
        set -l b (math "0x$m[3]")
        printf '\e]6;1;bg;red;brightness;%d\a\e]6;1;bg;green;brightness;%d\a\e]6;1;bg;blue;brightness;%d\a' $r $g $b > $tty 2>/dev/null
    else
        printf '\e]6;1;bg;*;default\a' > $tty 2>/dev/null
    end
end

function __tcz_emit_key --argument-names tty --description 'sanitize a client tty into an @option-safe key (/dev/pts/9 -> devpts9)'
    string replace -ra '[^a-zA-Z0-9]' '' -- "$tty"
end
function __tcz_emit_get --argument-names tty field --description 'read the last-emitted <field> (title|color) cached for <tty>'
    tmux show -gv @tmux_lives_emit_(__tcz_emit_key $tty)_$field 2>/dev/null
end
function __tcz_emit_set --argument-names tty field value --description 'cache the last-emitted <field> (title|color) for <tty>'
    tmux set -g @tmux_lives_emit_(__tcz_emit_key $tty)_$field "$value" 2>/dev/null
end

function __tcz_hostname --description 'short hostname (cache + test seam: tmux_lives_hostname)'
    if not set -q tmux_lives_hostname; or test -z "$tmux_lives_hostname"
        set -g tmux_lives_hostname (hostname -s 2>/dev/null)
        test -n "$tmux_lives_hostname"; or set -g tmux_lives_hostname (uname -n 2>/dev/null | string split -f1 .)
    end
    echo $tmux_lives_hostname
end

function __tcz_host_kind --description 'remote|local: universal tmux_lives_host_kind override, else SSH env, else local'
    if set -q tmux_lives_host_kind; and test -n "$tmux_lives_host_kind"
        echo $tmux_lives_host_kind; return
    end
    if test -n "$SSH_CONNECTION"; or test -n "$SSH_TTY"
        echo remote; return
    end
    echo local
end

function __tcz_dir_display --argument-names path --description 'path -> display dir: $HOME as ~, else basename'
    test -n "$path"; or return 0
    test "$path" = "$HOME"; and echo '~'; or basename -- "$path"
end

function __tcz_format_title --description 'host, dir, is_claude(0/1) -> "<host>: <dir>[ (C)]"'
    set -l s "$argv[1]: $argv[2]"
    test "$argv[3]" = 1; and set s "$s (C)"
    echo $s
end

function __tcz_status_identity --description 'pure: the centre identity format. Collapsed so a claude session shows ONE readable "✦ name" (@tmux_lives_name, else the claude --name) — NOT "slug ✦ name" (the session slug is slugify(--name), so the old append-form doubled it). Non-claude: @tmux_lives_name, else session_name.'
    # claude session (@tmux_lives_claude set): "✦ " + (@tmux_lives_name if set, else the claude name).
    # otherwise: @tmux_lives_name if set, else the session slug. No mark, no doubling.
    echo '#{?#{!=:#{@tmux_lives_claude},},#[fg=#{@tmux_lives_mark_fg}]✦#[fg=#{@tmux_lives_text_fg}] #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{@tmux_lives_claude}},#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}}'
end

function __tcz_status_right_merge --argument-names current ours --description 'pure: merge our status-right content with any FOREIGN #() interpolation already there -> "<foreign prefix><ours>". The prefix is whatever precedes our marker, kept ONLY when it contains a #( command interpolation — so tmux\'s DEFAULT status-right is replaced while a plugin hook survives. Why: tmux-continuum schedules its autosave by PREPENDING #(continuum_save.sh) to status-right; the status bar refresh IS its scheduler (no daemon, no timer), so a bare `set -g status-right` discards it and session snapshots stop permanently and silently.'
    set -l marker '#{T:@tmux_lives_status_right}'
    # Truncate at the marker (regex-escaped — it is full of format punctuation).
    # No match leaves $current intact, which is what we want when the marker is
    # absent: a plugin may have set status-right before we ever ran.
    set -l re (string escape --style=regex -- "$marker")
    set -l pre (string replace -r -- "$re"'.*$' '' "$current")
    # Keep the prefix ONLY if it is nothing but command interpolations and space.
    # A looser "contains #(" test would weld a user's own decorated status-right on
    # forever — `#(uptime) %H:%M` would render their clock next to ours with no way
    # to remove it. tmux's DEFAULT status-right has no #() at all and is dropped here,
    # which is the point: otherwise we'd paint the default clock beside our own.
    # KNOWN LIMIT: a group ends at its first `)`, so a hook whose command contains a
    # literal `)` is not recognised and gets dropped. Still strictly better than the
    # assignment this replaces, which preserved nothing at all. Test pins the shape.
    string match -qr '^(\s*#\([^)]*\)\s*)+$' -- "$pre"; or set pre ''
    printf '%s\n' "$pre$ours"
end

function __tcz_status_right_install --argument-names color --description 'install our status-right content without discarding a foreign #() hook. Called from the managed fragment via run-shell (plain run-shell is SYNCHRONOUS in tmux 3.3a, so the value lands before the fragment finishes sourcing).'
    # Must reproduce byte-for-byte what the fragment used to assign, so that a
    # re-install replaces our old rendering rather than stacking a second copy —
    # this is what `setup color` relies on when the baked colour changes.
    set -l ours (string join '' '#{T:@tmux_lives_status_right}' \
        '#(fish --no-config ' $__tcz_self ' tick ' "'$color'" ')')
    set -l cur (tmux show -gv status-right 2>/dev/null)
    tmux set -g status-right (__tcz_status_right_merge "$cur" "$ours")
end

function __tcz_status_format --description 'pure: the status-format[0] string (all tunables are @options; right zone renders status-right so tick/continuum survive)'
    # PUA glyphs via codepoints (never paste literal PUA): powerline slants.
    set -l slantR (printf '\U0000e0b0')   # right-pointing, closes a left-anchored cap
    set -l slantL (printf '\U0000e0b2')   # left-pointing, opens a right-anchored cap
    # The cap background follows the mode: prefix -> prefix color, resize -> resize color, else the base cap bg.
    set -l capbg '#{?client_prefix,#{@tmux_lives_prefix_color},#{?#{==:#{client_key_table},tmuxlives-resize},#{@tmux_lives_resize_color},#{@tmux_lives_cap_bg}}}'
    set -l glyph '#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}'
    set -l win '#{W:#{T:window-status-format}#{?window_end_flag,,#{T:window-status-separator}},#{T:window-status-current-format}#{?window_end_flag,,#{T:window-status-separator}}}'
    set -l id (__tcz_status_identity)
    # host cap (far left): styled segment + slant into the bar, then the window list (flat)
    set -l hostcap "#[fg=#{@tmux_lives_cap_fg},bg=$capbg] $glyph #{host_short} #[fg=$capbg,bg=#{@tmux_lives_bar_bg},none]$slantR#[default]"
    # centre: prefix chevron, else resize badge, else identity
    set -l centre "#{?client_prefix,❯ ,}#{?#{==:#{client_key_table},tmuxlives-resize},◇ RESIZE ◇  #[fg=#{@tmux_lives_cap_fg}]arrows move · x kill · esc/enter done,#[fg=#{@tmux_lives_text_fg}]$id#[fg=default]}"
    # clock cap (far right): slant opening the cap, then status-right (tick + continuum live here)
    set -l clockcap "#[fg=$capbg,bg=#{@tmux_lives_bar_bg}]$slantL#[fg=#{@tmux_lives_cap_fg},bg=$capbg] #{T;=/#{status-right-length}:status-right} #[default]"
    echo "#[align=left]$hostcap $win#[align=centre]$centre#[align=right]$clockcap"
end

function __tcz_cmdline_name --description 'pane_pid -> claude --name value (checks pid + direct children)'
    test -n "$argv[1]"; or return
    # A pid could be recycled between the children read and the comm read; worst case is a harmless miss.
    for pid in $argv[1] (__tcz_pid_children $argv[1])
        test "$(__tcz_pid_comm $pid)" = claude; or continue
        set -l cmd (__tcz_pid_cmdline $pid)
        set -l m (string match -r -- '--name\s+(.+)$' "$cmd")
        if test (count $m) -ge 2
            # Drop trailing flags (" --resume", " -r"). A name's " - Word" tail is safe:
            # the dash there is followed by a space, which --?\S+ cannot match.
            set -l name (string replace -r '(\s+--?\S+)+$' '' -- $m[2])
            if test -n "$name"
                echo $name
                return
            end
        end
    end
end

function __tcz_pane_is_claude --description 'cmd + pane_pid -> is this pane running claude?'
    test "$argv[1]" = claude; and return 0
    # A plain interactive shell in the foreground is not claude. `sh` is the
    # exception: tmux runs string commands via `sh -c`, so a script named claude
    # reports pane_current_command=sh while the process comm is claude.
    if contains -- "$argv[1]" $__tcz_shells
        test "$argv[1]" = sh; or return 1
    end
    # Otherwise inspect the pane pid and its children for a process whose comm is
    # claude. Covers the sh -c wrapper and macOS, where tmux reports the native
    # installer's version-named binary (~/.local/share/claude/versions/X.Y.Z) as
    # pane_current_command while the real claude process is a child of the pane shell.
    for pid in $argv[2] (__tcz_pid_children $argv[2])
        test "$(__tcz_pid_comm $pid)" = claude; and return 0
    end
    return 1
end

function __tcz_snapshot --description 'one line per session: name\tcategory\tattached\tlast_attached\tdisplay'
    set -l pane_fmt (printf '#{session_name}\t#{pane_current_command}\t#{pane_pid}\t#{pane_current_path}\t#{pane_title}')
    set -l sess_fmt (printf '#{session_name}\t#{session_attached}\t#{session_last_attached}\t#{@tmux_lives_name}')
    set -l panes (tmux list-panes -a -F $pane_fmt 2>/dev/null)
    test -n "$panes[1]"; or return
    set -l TAB (printf '\t')
    # Per-session aggregation. list-panes -a arrives in session/window/pane order,
    # so "first" below honors the lowest-window-then-pane rule from the spec.
    set -l names; set -l cats; set -l firstcmd; set -l cpid; set -l cpath; set -l ctitle; set -l gpath
    for line in $panes
        set -l f (string split -m 4 $TAB -- $line)    # title is last; keep embedded tabs
        test (count $f) -ge 4; or continue
        set -l s $f[1]
        set -l i (contains -i -- $s $names)
        if test -z "$i"
            set -a names $s; set -a cats general; set -a firstcmd ''
            set -a cpid ''; set -a cpath ''; set -a ctitle ''; set -a gpath $f[4]
            set i (count $names)
        end
        # pane_current_command may report "sh" even when the pane_pid comm is "claude"
        # (tmux runs commands via sh -c and doesn't always update pane_current_command).
        # Check both the reported command and the actual /proc comm of the pane pid.
        set -l is_claude 0
        __tcz_pane_is_claude $f[2] $f[3]; and set is_claude 1
        if test $is_claude -eq 1
            set cats[$i] claude
            if test -z "$cpid[$i]"
                set cpid[$i] $f[3]; set cpath[$i] $f[4]; set ctitle[$i] "$f[5]"
            end
        else if not contains -- $f[2] $__tcz_shells; and not contains -- $f[2] $__tcz_boring
            test "$cats[$i]" = claude; or set cats[$i] running
            test -z "$firstcmd[$i]"; and set firstcmd[$i] $f[2]
        end
    end
    # attached / last_attached lookup
    set -l snames; set -l satt; set -l slast; set -l sdisp
    for line in (tmux list-sessions -F $sess_fmt 2>/dev/null)
        set -l f (string split -m 3 $TAB -- $line)
        test (count $f) -ge 3; or continue
        set -a snames $f[1]; set -a satt $f[2]; set -a slast $f[3]
        set -a sdisp (test (count $f) -ge 4; and echo $f[4]; or echo '')
    end
    for i in (seq (count $names))
        set -l att 0
        set -l last 0
        set -l j (contains -i -- $names[$i] $snames)
        if test -n "$j"
            test "$satt[$j]" = 0; or set att 1
            string match -qr '^[0-9]+$' -- "$slast[$j]"; and set last $slast[$j]
        end
        set -l display
        switch $cats[$i]
            case claude
                set display (__tcz_cmdline_name $cpid[$i])
                test -n "$display"; or set display (__tcz_title_name "$ctitle[$i]")
                test -n "$display"; or set display claude-(path basename -- $cpath[$i])
            case running
                set display $firstcmd[$i]
            case general
                if test "$gpath[$i]" = "$HOME"
                    set display '~'
                else if string match -q "$HOME/*" -- $gpath[$i]
                    set display '~'(string sub -s (math (string length -- "$HOME") + 1) -- $gpath[$i])
                else
                    set display $gpath[$i]
                end
        end
        test -n "$j"; and test -n "$sdisp[$j]"; and set display "$sdisp[$j]"
        printf '%s\t%s\t%s\t%s\t%s\n' $names[$i] $cats[$i] $att $last "$display"
    end
end

function __tcz_session_target --argument-names session --description 'a -t target that is SAFE for set-option/show-option. tmux 3.3a resolves a BARE NUMBER as the CURRENT session, not the session NAMED that number (verified: with alpha=$0, "0"=$1, zulu=$2, a write aimed at -t 0 landed on zulu), so map a numeric name to its unambiguous $id. Non-numeric names pass straight through WITHOUT a tmux call — this runs per session per tick.'
    if not string match -qr '^[0-9]+$' -- "$session"
        echo $session
        return
    end
    set -l TAB (printf '\t')
    for line in (tmux list-sessions -F "#{session_name}$TAB#{session_id}" 2>/dev/null)
        set -l p (string split $TAB -- $line)
        if test "$p[1]" = "$session"
            echo $p[2]
            return
        end
    end
    # Unresolvable (no server / raced away): fall back to the name — no worse than before.
    echo $session
end

function __tcz_pane_target --argument-names session --description 'a -t target for PANE/CAPTURE commands (list-panes, capture-pane). Those need exact-match "=name", which option commands reject — but for a NUMERIC name even "=0" mis-resolves (it returns another session panes), so those fall back to the unambiguous $id. Keyed off the ORIGINAL name, never the shape of the resolved string (that sniff misfired on a session NAMED "$1"). Caveat: tmux resolves a $<digits>-shaped target as an ID even with "=", so a session literally named "$1" is unaddressable by any form — out of reach here.'
    if string match -qr '^[0-9]+$' -- "$session"
        __tcz_session_target "$session"
    else
        echo "=$session"
    end
end

function __tcz_owned --description 'true if we may rename: name == @tmux_auto_name, or purely numeric'
    set -l cur $argv[1]
    string match -qr '^(gen-)?[0-9]+$' -- "$cur"; and return 0
    # Empirically verified (tmux 3.3a): `show-option -t "=name"` returns empty even on success;
    # use the bare name form instead.
    set -l rec (tmux show-option -qv -t "$cur" @tmux_auto_name 2>/dev/null)
    test "$rec" = "$cur"
end

function __tcz_categorize --description 'rename every owned session to its live-state name'
    set -l TAB (printf '\t')
    for line in (__tcz_snapshot)
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l cur $f[1]
        __tcz_set_claude_opt $cur
        # A session with an explicit @tmux_lives_name is claimed by an app; leave its slug alone.
        # Target via __tcz_session_target: a fresh session is named 0/1/2..., and a BARE
        # NUMBER in -t resolves to the CURRENT session — so this used to read a DIFFERENT
        # session's claim and, when that one was claimed, skip the numeric session forever
        # (stranding it at its numeric name, re-failing every pass).
        set -l claimed (tmux show-option -qv -t (__tcz_session_target "$cur") @tmux_lives_name 2>/dev/null)
        test -n "$claimed"; and continue
        set -l desired
        switch $f[2]
            case claude running
                set desired (__tcz_slugify "$f[5]")
            case general
                # gen-N general names are stable once assigned: set at revert time, never
                # renumbered/compacted on later passes. This is BY DESIGN — do not "fix" by adding
                # compaction. (Legacy bare-numeric names are NOT stable here — they fall through
                # below and get promoted to gen-N; only gen-N is skipped.)
                string match -qr '^gen-[0-9]+$' -- "$cur"; and continue
                # desired gen-N computed below against current names
        end
        # Ownership guard applies to ALL categories: never rename a hand-named session.
        __tcz_owned "$cur"; or continue
        set -l others
        for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
            test "$s" != "$cur"; and set -a others $s
        end
        test -n "$desired"; or set desired (__tcz_free_gen $others)
        set desired (__tcz_unique $desired $others)
        test "$desired" = "$cur"; and continue
        tmux has-session -t "=$cur" 2>/dev/null; or continue   # concurrency re-check
        # exact-name match wins over prefix matching since we always pass full existing names
        tmux rename-session -t "=$cur" -- "$desired" 2>/dev/null; or continue
        # Stamp with one silent retry: a lost stamp would permanently freeze the name
        # (ownership guard would treat it as hand-named), so one retry is cheap insurance.
        set -l stamptgt (__tcz_session_target "$desired")
        tmux set-option -t "$stamptgt" @tmux_auto_name "$desired" 2>/dev/null
        or tmux set-option -t "$stamptgt" @tmux_auto_name "$desired" 2>/dev/null
    end
end

function __tcz_overview --description 'snapshot sorted claude>running>general, MRU within group'
    set -l TAB (printf '\t')
    for line in (__tcz_snapshot)
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l rank 2
        test "$f[2]" = claude; and set rank 0
        test "$f[2]" = running; and set rank 1
        printf '%s\t%s\t%s\n' $rank $f[4] "$line"
    end | sort -t $TAB -k1,1n -k2,2nr | cut -f3-
end

function __tcz_ghosts_from --argument-names cutoff --description 'stdin "client\tactivity" -> clients older than cutoff'
    set -l TAB (printf '\t')
    while read -l line
        set -l f (string split $TAB -- $line)
        test (count $f) -ge 2; or continue
        string match -qr '^[0-9]+$' -- "$f[2]"; or continue
        test "$f[2]" -lt "$cutoff"; and echo $f[1]
    end
end

function __tcz_ghosts --argument-names session --description 'detach stale clients from a session'
    test -n "$session"; or return 0
    set -l gm 5
    set -q tmux_auto_ghost_minutes; and set gm $tmux_auto_ghost_minutes
    set -l now (date +%s)
    set -q tmux_auto_now; and set now $tmux_auto_now
    set -l fmt (printf '#{client_name}\t#{client_activity}')
    # list-clients -t "=$session": the = exact-name prefix works on tmux 3.3a (verified empirically).
    for c in (tmux list-clients -t "=$session" -F $fmt 2>/dev/null | __tcz_ghosts_from (math "$now - $gm * 60"))
        tmux detach-client -t "$c" 2>/dev/null
    end
    return 0
end

function __tcz_menu_args --argument-names current --description 'stdin overview lines (+ optional current session to mark) -> argv triples for display-menu'
    set -l TAB (printf '\t')
    # Pass 1: collect entries. Bases (display names) and indicators are kept
    # separate so indicators can be right-aligned at a common column next to
    # tmux's key column. Indicators are bracketed to look distinct from keys.
    set -l e_names
    set -l e_cats
    set -l e_bases
    set -l e_inds
    set -l e_dim
    set -l maxbase 0
    while read -l line
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l base "$f[5]"
        set -l ind ''
        set -l dim 0
        if test -n "$current"; and test "$f[1]" = "$current"
            # The session this client is sitting in: dimmed, marked, [current].
            # Menu item names are tmux formats, so #[dim]/#[default] style it.
            set base "▸ $f[5]"
            set ind '[current]'
            set dim 1
        else if test "$f[3]" = 1
            set ind '[attached]'
        end
        set -a e_names $f[1]
        set -a e_cats $f[2]
        set -a e_bases "$base"
        set -a e_inds "$ind"
        set -a e_dim $dim
        set -l w (string length -- "$base")
        test $w -gt $maxbase; and set maxbase $w
    end
    # Indicators start two columns past the widest base; build final labels and
    # measure the widest one for the header rule width.
    set -l indcol (math $maxbase + 2)
    set -l e_labels
    set -l maxw 0
    for i in (seq (count $e_names))
        set -l label "$e_bases[$i]"
        set -l w (string length -- "$label")
        if test -n "$e_inds[$i]"
            set label "$label"(string repeat -n (math "$indcol - $w") ' ')"$e_inds[$i]"
            set w (math "$indcol + "(string length -- "$e_inds[$i]"))
        end
        test "$e_dim[$i]" = 1; and set label "#[fg=colour143]$label#[default]"
        set -a e_labels "$label"
        test $w -gt $maxw; and set maxw $w
    end
    # Header rule width: widest label + the key chrome tmux adds (" (1)" ≈ 4 cols).
    set -l total (math $maxw + 4)
    # Pass 2: emit header/item triples.
    set -l key 0
    set -l group ''
    for i in (seq (count $e_names))
        if test "$e_cats[$i]" != "$group"
            set group $e_cats[$i]
            # Color-coded per category (user palette: claude orange, running cyan,
            # general green; colour208 because tmux has no named orange).
            set -l hcol colour208
            test "$group" = running; and set hcol cyan
            test "$group" = general; and set hcol green
            # 2-dash lead-in, name, trailing rule filling to the menu edge.
            set -l word "── $group "
            set -l right (math "$total - "(string length -- "$word"))
            test $right -lt 2; and set right 2
            printf '%s\n%s\n%s\n' \
                "-#[fg=$hcol,bold]$word"(string repeat -n $right ─)"#[default]" '' ''
        end
        set key (math $key + 1)
        # keys 1-9 jump directly; later items are arrow-selectable only
        set -l keystr $key
        test $key -gt 9; and set keystr ''
        # Escape the session name for each quoting layer it crosses:
        # sh single-quote context inside run-shell: ' -> '\''
        set -l sn_sh (string replace -a "'" "'\\''" -- "$e_names[$i]")
        # tmux outer double-quote context around the run-shell arg: " -> \"
        set -l sn_dq (string replace -a '"' '\\"' -- "$sn_sh")
        # ONE run-shell does ghosts + switch-client with proper argv. Never put the
        # target in tmux's own string layer: {=name} parses as a command block at
        # selection time ("unknown command: =name"). #{client_name} expands to the
        # choosing client so the script can target it with switch-client -c.
        printf '%s\n%s\n%s\n' "$e_labels[$i]" "$keystr" \
            "run-shell \"fish --no-config $__tcz_self switch '$sn_dq' '#{client_name}'\""
    end
end

function __tcz_menu --description 'open the categorized session switcher (needs an attached client)'
    __tcz_categorize >/dev/null 2>&1     # picker truth-up: names current before listing
    # while-read, not command substitution: header triples carry EMPTY key/command
    # elements that $(...) would drop.
    # Resolve the invoking client's session: run-shell (prefix S) has client
    # context; from `ts` the inherited $TMUX_PANE steers display-message.
    set -l current (tmux display-message -p '#{session_name}' 2>/dev/null)
    set -l args
    __tcz_overview | __tcz_menu_args $current | while read -l a
        set -a args "$a"
    end
    test (count $args) -gt 0; or return 0
    tmux display-menu -T ' switch session ' -- $args
end

function __tcz_modal_menu_args --description 'display-menu triples (label/key/command) for the command-modal fallback'
    # Each action is a label, a shortcut key, and a tmux command. CLI verbs run via
    # `fish -c`; categorizer-native verbs re-enter this script ($__tcz_self).
    # NB: no "theme" row here — this menu is the fallback for tmux builds WITHOUT
    # display-popup, so a row that itself opens a display-popup could never work
    # (Task 8 review carry-over). The CLI (`tmux-lives setup theme list`/knobs) is
    # the no-popup surface for that build instead.
    printf '%s\n' \
        'new session'    n "run-shell 'fish -c \"tmux-lives new\"'" \
        'clear idle'     c "run-shell 'fish -c \"tmux-lives clear\"'" \
        'categorize'     g "run-shell 'fish --no-config $__tcz_self tick'" \
        'picker'         s "run-shell 'fish --no-config $__tcz_self open-switcher'" \
        'scratch toggle' t "run-shell 'fish --no-config $__tcz_self scratch'" \
        'bar color'      b "command-prompt -p 'bar color (css):' 'run-shell \"fish -c \\\"tmux-lives setup color %%\\\"\"'"
end

function __tcz_modal_menu --argument-names client --description 'display-menu fallback for the command modal (no display-popup)'
    set -l args
    __tcz_modal_menu_args | while read -l a
        set -a args "$a"
    end
    test (count $args) -gt 0; or return 0
    tmux display-menu -T ' tmux-lives ' -- $args
end

function __tcz_switch --argument-names session client --description 'switch <session> <client> [--take]: switch the choosing client to <session>; other clients are left alone unless --take, which detaches them all'
    test -n "$session"; or return 0
    # no-blanket-kick (conf.d/tmux.fish:176): visiting a session must not evict
    # anyone. This used to call __tcz_ghosts unconditionally, dropping any client
    # idle > tmux_auto_ghost_minutes (5) — so a plain pick silently "took" sessions
    # the user only meant to switch to. Removed rather than gated: under --take,
    # detach-client -s already drops EVERY client on the session, a strict superset
    # of the idle ones ghost-detach would pick. Matches `tmux-lives attach -t`.
    # TRADE-OFF: ghost-detach's original job was evicting a stale client whose size
    # squashed the session (the "stale Claude TUI size" fix). This was its only
    # load-bearing call site, so that no longer happens on a plain switch — use
    # --take (or `tmux-lives picker -t`) when a stale client is sizing you down.
    test "$argv[3]" = --take; and tmux detach-client -s "=$session" 2>/dev/null
    if test -n "$client"
        tmux switch-client -c "$client" -t "=$session" 2>/dev/null
    else
        tmux switch-client -t "=$session" 2>/dev/null
    end
    return 0
end

function __tcz_pick_general --argument-names exclude --description 'MRU detached general session, optionally excluding one'
    # Deliberately lean (no snapshot/display-name//proc work): the ShellFish
    # springboard flash lasts exactly as long as this function runs.
    set -l TAB (printf '\t')
    set -l fmt (printf '#{session_attached}\t#{session_last_attached}\t#{session_name}')
    for line in (tmux list-sessions -F $fmt 2>/dev/null | sort -t $TAB -k2,2nr)
        set -l f (string split -m 2 $TAB -- $line)
        test (count $f) -ge 3; or continue
        test "$f[1]" = 0; or continue                  # detached only
        test "$f[3]" != "$exclude"; or continue
        # general = at least one pane, every pane a bare shell (fail-safe: an
        # un-inspectable session is never picked)
        set -l cmds (tmux list-panes -s -t (__tcz_pane_target "$f[3]") -F '#{pane_current_command}' 2>/dev/null)
        test -n "$cmds[1]"; or continue
        set -l idle 1
        for cmd in $cmds
            contains -- $cmd $__tcz_shells; or begin
                set idle 0
                break
            end
        end
        test $idle -eq 1; or continue
        echo $f[3]
        return
    end
end

function __tcz_new_general --description 'Create a detached general session named with the smallest free gen-N; echo its name'
    set -l name (__tcz_free_gen (tmux list-sessions -F '#{session_name}' 2>/dev/null))
    tmux new-session -d -s "$name" 2>/dev/null; and echo $name
end

function __tcz_commandeer --argument-names client session --description 'commandeer <client> <session>: bounce a fresh ShellFish springboard onto a real session'
    # ShellFish (tmux toggle ON) creates each tab as `new-session -s shellfish-N`
    # with no -A: the session is a disposable landing pad. Bounce the client to
    # the MRU detached general session (plain-login parity) and dispose of the
    # springboard. Only ever touches FRESH, BARE shellfish-N sessions.
    string match -qr '^shellfish-[0-9]+$' -- "$session"; or return 0
    set -l cmds (tmux list-panes -t "=$session" -F '#{pane_current_command}' 2>/dev/null)
    test (count $cmds) -eq 1; or return 0
    contains -- $cmds[1] $__tcz_shells; or return 0
    set -l created 0
    set -l target (__tcz_pick_general "$session")
    if test -z "$target"
        set target (__tcz_new_general)
        set created 1
    end
    test -n "$target"; or return 0
    __tcz_ghosts "$target"
    # Dispose of the springboard only after a SUCCESSFUL switch — on failure the
    # client is still sitting on it. Clean up our own fallback session likewise.
    if tmux switch-client -c "$client" -t "=$target" 2>/dev/null
        tmux kill-session -t "=$session" 2>/dev/null
    else if test $created -eq 1
        tmux kill-session -t "=$target" 2>/dev/null
    end
    return 0
end

function __tcz_popup_layout --argument-names cols --description 'cols -> "listwidth previewwidth" (preview 0 when too narrow)'
    test -n "$cols"; and test "$cols" -gt 0 2>/dev/null; or set cols 80
    if test $cols -lt 60
        echo "$cols 0"
        return 0
    end
    set -l list (math "floor($cols * 42 / 100)")
    test $list -lt 20; and set list 20
    test $list -gt 40; and set list 40
    set -l prev (math "$cols - $list - 1")
    test $prev -lt 1; and set prev 1
    echo "$list $prev"
end

function __tcz_popup_truncate --argument-names text width --description 'truncate text to <width> DISPLAY COLUMNS with trailing … (wide/zero-width AND SGR-aware; never cuts mid-escape; resets colour before the …)'
    test -n "$width"; and test "$width" -gt 0 2>/dev/null; or begin; echo ''; return 0; end
    # Fast path: already fits. `string length --visible` ignores SGR escapes.
    if test (string length --visible -- "$text") -le $width
        echo -- "$text"
        return 0
    end
    set -l ESC (printf '\e')
    set -l budget (math "$width - 1")
    # Tokenize into SGR/CSI escapes (zero display width, copied verbatim) and plain-text
    # runs in ONE regex pass, then accumulate by RUN. This avoids the per-character
    # `string length --visible`/`math` calls that made the old slow path O(line length)
    # (~12ms/call on a wide colored pane -> ~130ms per 24-row preview redraw -> a laggy
    # picker). Only a run that straddles the budget is walked, and only when it holds
    # wide/zero-width chars. `capture-pane -e` emits SGR only, so a lone ESC (no `[`)
    # falls through as its own token and is treated as zero-width, never split.
    set -l out ''
    set -l acc 0
    set -l sawsgr 0
    for tok in (string match -a -r '\e\[[0-9;?]*[A-Za-z]|[^\e]+|\e' -- "$text")
        if test (string sub -l 1 -- "$tok") = "$ESC"
            set out "$out$tok"; set sawsgr 1
            continue
        end
        set -l vw (string length --visible -- "$tok")
        if test (math "$acc + $vw") -le $budget
            set out "$out$tok"; set acc (math "$acc + $vw")
            continue
        end
        # this run overflows the budget: keep as many display columns as still fit
        set -l need (math "$budget - $acc")
        test $need -le 0; and break
        if test (string length -- "$tok") -eq $vw
            set out "$out"(string sub -l $need -- "$tok")     # all width-1 -> exact slice
        else
            for c in (string split '' -- "$tok")              # wide/zero-width -> walk this run only
                set -l cw (string length --visible -- "$c")
                test (math "$acc + $cw") -gt $budget; and break
                set out "$out$c"; set acc (math "$acc + $cw")
            end
        end
        break
    end
    set -l rst ''
    test $sawsgr -eq 1; and set rst (printf '\e[0m')
    echo -- "$out$rst…"
end

function __tcz_popup_list_lines --argument-names listwidth selidx current --description 'overview (stdin) -> ANSI visual list: full-width category rules + session rows (pointer on #selidx, markers flush-right at listwidth)'
    set -l TAB (printf '\t')
    set -l RST (printf '\e[0m')
    set -l FGDEF (printf '\e[39m')      # reset fg only (keeps background)
    set -l DIMON (printf '\e[2m'); set -l DIMOFF (printf '\e[22m')
    set -l YEL (printf '\e[38;5;179m')
    set -l ORG (printf '\e[38;5;208m')
    set -l SELBG (__tcz_theme sel-bg)
    test -n "$listwidth"; and test "$listwidth" -gt 0 2>/dev/null; or set listwidth 30
    test -n "$selidx"; or set selidx 0
    set -l group ''
    set -l idx 0
    while read -l line
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l name "$f[1]"; set -l cat "$f[2]"; set -l att "$f[3]"; set -l disp "$f[5]"
        set -l c 208
        test "$cat" = running; and set c 6
        test "$cat" = general; and set c 2
        set -l BORD (printf '\e[38;5;%sm' $c)   # category left-border (non-bold)
        # category rule (full width to listwidth)
        if test "$cat" != "$group"
            set group "$cat"
            set -l hdr (printf '\e[1;38;5;%sm' $c)
            set -l word "── $cat "
            set -l wl (string length -- "$word")
            set -l lead (math "1 + $wl")            # corner + word
            if test $lead -ge $listwidth
                printf '%s%s%s\n' $hdr (__tcz_popup_truncate "╭$word" $listwidth) $RST
            else
                printf '%s╭%s%s%s\n' $hdr "$word" (string repeat -n (math "$listwidth - $lead") ─) $RST
            end
        end
        # marker
        set -l mk ''
        if test -n "$current"; and test "$name" = "$current"
            set mk '[current]'
        else if test "$att" = 1
            set mk '[attached]'
        end
        set -l mlen (string length -- "$mk")
        # name field width = listwidth - 2 (pointer area) - (gap+marker if any)
        # If the marker + gap would leave no room for the name, drop the marker
        # instead of overflowing (guarantees every row is exactly listwidth wide).
        set -l namespace (math "$listwidth - 2")
        if test $mlen -gt 0
            set -l ns_with_mk (math "$namespace - $mlen - 1")
            if test $ns_with_mk -lt 1
                set mk ''; set mlen 0
            else
                set namespace $ns_with_mk
            end
        end
        test $namespace -lt 1; and set namespace 1
        set -l shown (__tcz_popup_truncate "$disp" $namespace)
        set -l pad (math "$namespace - "(string length --visible -- "$shown"))
        test $pad -lt 0; and set pad 0
        set -l pads (string repeat -n $pad ' ')
        set -l gap ''; test $mlen -gt 0; and set gap ' '
        set -l iscur 0; test -n "$current"; and test "$name" = "$current"; and set iscur 1
        if test "$idx" = "$selidx"
            # selected row: full-width background band, fg-only color changes
            set -l nmpart "$shown$pads"
            test $iscur -eq 1; and set nmpart "$YEL$shown$FGDEF$pads"
            set -l mkpart ''
            test $mlen -gt 0; and set mkpart "$gap$DIMON$mk$DIMOFF"
            printf '%s%s▐%s %s%s%s\n' $SELBG $ORG $FGDEF "$nmpart" "$mkpart" $RST
        else
            set -l bchar │
            set -l bordc $BORD
            if test $iscur -eq 1
                set bchar '❯'                              # current: right chevron in the border
                set bordc $YEL
            end
            set -l nmpart "$shown$pads"
            test $iscur -eq 1; and set nmpart "$YEL$shown$RST$pads"
            set -l mkpart ''
            if test $mlen -gt 0
                if test $iscur -eq 1
                    set mkpart "$gap$YEL$mk$RST"           # current: yellow [current], no dim/bold
                else
                    set mkpart "$gap$DIMON$mk$RST"
                end
            end
            printf '%s%s%s %s%s\n' $bordc $bchar $RST "$nmpart" "$mkpart"
        end
        set idx (math $idx + 1)
    end
end

function __tcz_strip_sgr --description 'strip ANSI SGR (colour) escapes from argv[1]'
    string replace -ra '\x1b\[[0-9;]*m' '' -- "$argv[1]"
end

function __tcz_popup_clip --argument-names w h --description 'stdin lines -> the BOTTOM h lines (trailing blanks stripped, newest last), each truncated to w cols, top-padded with blanks to exactly h so the most recent line sits on the last row (bottom-anchored)'
    test -n "$w"; and test "$w" -gt 0 2>/dev/null; or set w 40
    test -n "$h"; and test "$h" -gt 0 2>/dev/null; or set h 20
    set -l lines
    while read -l l
        set -a lines "$l"
    end
    # drop trailing blank (whitespace-only, ignoring colour) lines so the last kept line is real
    while test (count $lines) -gt 0; and test -z (string trim -- (__tcz_strip_sgr "$lines[-1]"))
        set -e lines[-1]
    end
    set -l n (count $lines)
    # keep only the most recent h lines (the tail — what's happening now)
    if test $n -gt $h
        set lines $lines[(math "$n - $h + 1")..-1]
        set n $h
    end
    # bottom-anchor: blank rows on top so the newest line lands on the last row
    set -l pad (math "$h - $n")
    if test $pad -gt 0
        for i in (seq $pad)
            echo ''
        end
    end
    set -l RST (printf '\e[0m')
    for l in $lines
        printf '%s%s\n' (__tcz_popup_truncate "$l" $w) $RST
    end
end

function __tcz_popup_preview --argument-names session w h --description 'colored capture-pane (-e) of session active pane, clipped to w×h'
    test -n "$session"; or return 0
    # __tcz_session_target, NOT __tcz_pane_target: capture-pane REJECTS the "=name" form
    # that list-panes tolerates ("can't find pane: =name"), so it needs the bare-name/id
    # shape. Using the pane shape here blanked the preview for every non-numeric session.
    tmux capture-pane -e -p -t (__tcz_session_target "$session") 2>/dev/null | __tcz_popup_clip $w $h
end

function __tcz_legend_row --argument-names pitch --description 'pure: one aligned key-legend row — argv[2..] = <key> <label> pairs; each cell = key (key color) + space + label (muted) padded to <pitch> visible cols; leading space. The shared footer convention for every tmux-lives popup.'
    set -l KEY (__tcz_theme key)
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l out ' '
    set -l rest $argv[2..]
    while test (count $rest) -ge 2
        set -l cell "$rest[1] $rest[2]"
        set -l pad (math "$pitch - "(string length --visible -- "$cell"))
        test $pad -lt 0; and set pad 0
        set -l padstr (string repeat -n $pad ' ')
        set out "$out$KEY$rest[1]$RST $MUT$rest[2]$RST$padstr"
        set -e rest[1..2]
    end
    printf '%s' "$out"
end

function __tcz_popup_readkey --argument-names mode --description 'read one keystroke -> up|down|pgup|pgdn|left|right|v|w|V|s|S|e|E|d|D|o|O|p|P|m|M|a|r|b|t|z|c|tab|enter|cancel|kill|timeout|other; with mode=timeout an empty read returns timeout instead of cancel'
    # Read RAW bytes with an inline `dd | … | read` pipeline. Why not simpler:
    #  - fish `read` on the tty runs fish's line editor and SWALLOWS arrow escape
    #    sequences (treats them as cursor-move), so they never reach us.
    #  - dd reads bytes verbatim, but it must be the HEAD of a pipeline in this
    #    function — a command substitution `(dd …)` inside a function that is a
    #    pipe's RHS does NOT inherit the piped stdin (fish quirk). `… | read VAR`
    #    sets VAR in scope. Bytes are compared as hex.
    # left/right (h/l + CSI C/D) and v/w are only consumed by the cap-picker's
    # direction-flip / vividness / wheel controls; __tcz_popup's switch has no
    # matching case for any of them so it silently ignores them there (same as
    # any other token its cases don't list).
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    if test -z "$b"
        test "$mode" = timeout; and echo timeout; or echo cancel
        return
    end
    switch "$b"
        case 6a; echo down; return                  # j
        case 6b; echo up; return                    # k
        case 68; echo left; return                  # h
        case 6c; echo right; return                 # l
        case 76; echo v; return                      # v (cap-picker: cycle vividness)
        case 77; echo w; return                      # w (cap-picker: toggle wheel)
        case 73; echo s; return                      # s (theme-picker: chroma shape)
        case 65; echo e; return                      # e (theme-picker: hue ease)
        case 62; echo b; return                      # b (theme-picker: set seed)
        case 74; echo t; return                      # t (theme-picker: typed hex, from edit mode)
        case 64; echo d; return                      # d (theme-picker: cycle contrast)
        case 61; echo a; return                      # a (theme-picker: apply preview)
        case 6f; echo o; return                      # o (theme-picker: rotate placement)
        case 72; echo r; return                      # r (theme-picker: reset knobs)
        case 7a; echo z; return                      # z (theme-picker: shake)
        case 63; echo c; return                      # c (theme-picker: retired — unused, harmless no-op)
        case 09; echo tab; return                    # TAB (theme-picker: switch lists)
        case 71; echo cancel; return                # q
        case 78; echo kill; return                  # x
        case 0d 0a; echo enter; return              # CR / LF
        case 56; echo V; return                      # V (theme-picker: vividness backward)
        case 53; echo S; return                      # S (theme-picker: shape toggle)
        case 45; echo E; return                      # E (theme-picker: ease toggle)
        case 44; echo D; return                      # D (theme-picker: contrast backward)
        case 4f; echo O; return                      # O (theme-picker: rotate backward)
        case 70; echo p; return                      # p (theme-picker: cycle seed placement)
        case 50; echo P; return                      # P (theme-picker: cycle placement backward)
        case 6d; echo m; return                      # m (theme-picker: toggle mode)
        case 4d; echo M; return                      # M (theme-picker: toggle mode, same as m)
    end
    if test "$b" = 1b                                # ESC
        # bare ESC vs CSI (\e[…) / SS3 (\eO…) arrow: non-blocking follow-read
        stty min 0 time 1 2>/dev/null
        set -l b2 ''
        dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b2
        set -l b3 ''
        set -l b4 ''
        if test "$b2" = 5b; or test "$b2" = 4f       # [ or O
            dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b3
            # PgUp/PgDn are ESC [ 5 ~ / ESC [ 6 ~ — consume the trailing '~' HERE,
            # while the tty is still non-blocking. Restoring stty first and then
            # reading would block forever when the byte is absent.
            if test "$b3" = 35; or test "$b3" = 36
                dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b4
            end
        end
        stty min 1 time 0 2>/dev/null
        if test "$b2" = 5b; or test "$b2" = 4f
            switch "$b3"
                case 41; echo up; return             # A (up)
                case 42; echo down; return           # B (down)
                case 43; echo right; return          # C (right)
                case 44; echo left; return           # D (left)
                case 35; echo pgup; return           # 5~ (page up)
                case 36; echo pgdn; return           # 6~ (page down)
            end
            echo other; return
        end
        echo cancel; return                          # bare ESC
    end
    echo other
end

function __tcz_popup_draw --description '__tcz_popup_draw <sel> <listw> <prevw> <rows> <current> -- <model lines...>: paint one frame'
    set -l sel $argv[1]; set -l listw $argv[2]; set -l prevw $argv[3]; set -l rows $argv[4]; set -l current $argv[5]
    set -e argv[1..6]                  # argv[6] is the literal '--' separator
    set -l model $argv
    set -l TAB (printf '\t')
    set -l DIV (printf '\e[38;5;240m│\e[0m')
    set -l left (printf '%s\n' $model | __tcz_popup_list_lines $listw $sel "$current")
    set -l right
    if test $prevw -gt 0
        set -l selname (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
        set right (__tcz_popup_preview "$selname" $prevw $rows)
    end
    set -l blankL (string repeat -n $listw ' ')
    set -l out
    for r in (seq $rows)
        set -l lseg $blankL
        test $r -le (count $left); and set lseg $left[$r]
        set -l line $lseg
        if test $prevw -gt 0
            set -l rseg ''
            test $r -le (count $right); and set rseg $right[$r]
            set line "$lseg$DIV$rseg"
        end
        set -a out "$line"(printf '\e[K')
    end
    # Synchronized update (DECSET 2026) so the whole frame commits atomically — no
    # tearing/flash between list and preview. Newlines BETWEEN rows only: a trailing
    # newline after the last row scrolls a full-height popup up one (dropping the top
    # line). Unsupported terminals ignore the 2026 private mode harmlessly.
    printf '\e[?2026h\e[H'
    test (count $out) -gt 1; and printf '%s\n' $out[1..-2]
    printf '%s' $out[-1]
    printf '\e[J\e[?2026l'
end

function __tcz_modal_legend --argument-names has_scratch modalkey scratchkey resizekey switcherkey --description 'pure: the command-launcher legend box (design B: categorized commands + keybind table). Keys passed in so it reflects the effective binds.'
    set -l O (printf '\e[38;5;208m'); set -l OD (printf '\e[38;5;130m')  # orange, dim-orange border
    set -l YO (printf '\e[38;5;179m')             # muted yellow-orange (the picker's accent)
    set -l CY (printf '\e[36m'); set -l GR (printf '\e[32m')
    set -l T (printf '\e[0m')
    set -l KG (printf '\e[38;5;245m')             # keys-footer label: soft grey (was muddy dim)
    set -l IW 30                                  # inner width (between the borders)
    # one bordered line: colored content + its visible twin, padded to IW so
    # EVERY line is the same width and the borders line up. Pad via a QUOTED
    # var — an inline (string repeat -n 0 …) yields ZERO args and shifts
    # printf's fields, collapsing the full-width rules to "││".
    function __tcz_ml_ln --no-scope-shadowing --argument-names colored vis w od t
        set -l pad (math "$w - "(string length -- "$vis")); test $pad -lt 0; and set pad 0
        set -l padstr (string repeat -n $pad ' ')
        printf '%s│%s%s│%s\n' $od "$colored$t$padstr" $od $t
    end
    set -l lines
    # top border with title
    set -a lines $OD"╭─ "$O"tmux-lives"$OD" "(string repeat -n (math "$IW - 13") ─)"╮"$T
    for spec in "session:$YO" "scratch:$CY" "config:$GR" "keys:$KG"
        set -l lab (string split -f1 : $spec); set -l col (string split -f2 : $spec)
        set -l rv " $lab "(string repeat -n (math "$IW - 3 - "(string length -- $lab)) ─)" "
        set -a lines (__tcz_ml_ln "$col$rv" "$rv" $IW $OD $T)
        switch $lab
            case session
                set -a lines (__tcz_ml_ln "   $O"p"$T picker    $O"n"$T new" "   p picker    n new" $IW $OD $T)
                set -a lines (__tcz_ml_ln "   $O"c"$T clear     $O"g"$T categorize" "   c clear     g categorize" $IW $OD $T)
            case scratch
                set -a lines (__tcz_ml_ln "   $O"t"$T toggle    $O"r"$T resize…" "   t toggle    r resize…" $IW $OD $T)
            case config
                set -a lines (__tcz_ml_ln "   $O"b"$T bar color" "   b bar color" $IW $OD $T)
                set -a lines (__tcz_ml_ln "   $O""k theme""$T" "   k theme" $IW $OD $T)
            case keys
                set -a lines (__tcz_ml_ln "   $O$modalkey$KG menu     $O$resizekey$KG resize" "   $modalkey menu     $resizekey resize" $IW $OD $T)
                set -a lines (__tcz_ml_ln "   $O$scratchkey$KG scratch  $O$switcherkey$KG picker" "   $scratchkey scratch  $switcherkey picker" $IW $OD $T)
                set -a lines (__tcz_ml_ln "   $O"esc"$KG close" "   esc close" $IW $OD $T)
        end
    end
    set -a lines $OD"╰"(string repeat -n $IW ─)"╯"$T
    functions -e __tcz_ml_ln
    printf '%s\n' $lines
end

function __tcz_modal_action --argument-names key --description 'pure: launcher keyname -> action token (single-shot; resize-mode gating is in __tcz_resize_enter)'
    switch "$key"
        case p; echo picker
        case n; echo new
        case c; echo clear
        case g; echo categorize
        case t; echo scratch
        case r; echo resize
        case b; echo color
        case k; echo theme
        case esc q; echo close
        case '*'; echo noop
    end
end

function __tcz_modal_readkey --description 'read one keystroke -> keyname (launcher letters; enter/esc parsed)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo close; return; end          # EOF
    switch "$b"
        case 0d 0a; echo enter; return
        case 70; echo p; return
        case 6e; echo n; return
        case 63; echo c; return
        case 67; echo g; return
        case 74; echo t; return
        case 72; echo r; return
        case 62; echo b; return
        case 6b; echo k; return
        case 71; echo q; return
        case 1b; echo esc; return
    end
    echo other
end

function __tcz_modal_run --argument-names action client --description 'perform one launcher action (single-shot; the popup exits right after)'
    switch "$action"
        case picker
            # Defer: run AFTER this popup closes, so the picker popup is not nested.
            tmux run-shell -b "fish --no-config $__tcz_self open-switcher '$client'" 2>/dev/null
        case theme
            # Defer: run AFTER this popup closes; open the theme picker in its OWN popup
            # (the theme-picker verb runs INSIDE a popup, unlike open-switcher which
            # opens one itself — so we must wrap it here).
            tmux run-shell -b "tmux display-popup -B -E -w 52 -h 85% -- fish --no-config $__tcz_self theme-picker '$client'" 2>/dev/null
        case new
            fish -c 'tmux-lives new' 2>/dev/null
        case clear
            fish -c 'tmux-lives clear' 2>/dev/null
            tmux display-message 'tmux-lives: cleared idle sessions' 2>/dev/null
        case categorize
            __tcz_categorize >/dev/null 2>&1
            tmux display-message 'tmux-lives: categorized' 2>/dev/null
        case scratch
            __tcz_scratch "$client"
        case resize
            __tcz_resize_enter "$client"
        case color
            # cooked-read prompt handled by the loop-free __tcz_modal (needs the tty); no-op here
        case close noop
            # nothing
    end
end

function __tcz_modal --argument-names client modalkey scratchkey resizekey switcherkey --description 'single-shot command launcher (runs inside display-popup): draw legend, read ONE key, act, exit'
    if test -z "$client"; or string match -q '*#{*' -- "$client"
        set client (tmux display-message -p '#{client_name}' 2>/dev/null)
    end
    test -n "$modalkey"; or set modalkey M-m
    test -n "$scratchkey"; or set scratchkey M-t
    test -n "$resizekey"; or set resizekey M-r
    test -n "$switcherkey"; or set switcherkey M-s
    set -l sp (__tcz_scratch_pane)
    set -l has 0; test -n "$sp[1]"; and set has 1
    set -l saved (stty -g)
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J\e[H'
    __tcz_modal_legend $has $modalkey $scratchkey $resizekey $switcherkey
    set -l action (__tcz_modal_action (__tcz_modal_readkey))
    if test "$action" = color
        stty "$saved" 2>/dev/null
        printf '\e[2J\e[H bar color (empty=skip): '
        set -l val ''
        read -l val
        test -n "$val"; and fish -c 'tmux-lives setup color $argv[1]' "$val" 2>/dev/null
    else
        __tcz_modal_run $action "$client"
    end
    stty $saved 2>/dev/null
    printf '\e[?25h\e[2J\e[H'
    return 0
end

function __tcz_popup --argument-names client --description 'two-pane session switcher (runs inside display-popup)'
    set -l take ''
    contains -- --take $argv; and set take --take
    __tcz_categorize >/dev/null 2>&1
    # display-popup does NOT format-expand argv after `--`, so a bind passing
    # '#{client_name}' delivers it literally. Resolve the real client from inside
    # the popup when the arg is empty or still an unexpanded format — otherwise
    # switch-client -c gets a bogus client and the switch silently fails.
    if test -z "$client"; or string match -q '*#{*' -- "$client"
        set client (tmux display-message -p '#{client_name}' 2>/dev/null)
    end
    set -l current (tmux display-message -c "$client" -p '#{session_name}' 2>/dev/null)
    test -n "$current"; or set current (tmux display-message -p '#{session_name}' 2>/dev/null)
    set -l TAB (printf '\t')
    set -l model (__tcz_overview)
    set -l n (count $model)
    test $n -gt 0; or return 0
    set -l size (stty size 2>/dev/null | string split ' ')
    set -l rows $size[1]; set -l cols $size[2]
    test -n "$rows"; and test "$rows" -gt 0 2>/dev/null; or set rows 24
    test -n "$cols"; and test "$cols" -gt 0 2>/dev/null; or set cols 80
    set -l lay (string split ' ' (__tcz_popup_layout $cols))
    set -l listw $lay[1]; set -l prevw $lay[2]
    # start on the current session if present
    set -l sel 0
    for i in (seq $n)
        if test (string split -m 1 $TAB -- $model[$i])[1] = "$current"
            set sel (math $i - 1); break
        end
    end
    set -l saved (stty -g)
    # Restore the terminal even if the popup is killed mid-loop (SIGINT/SIGTERM).
    # __tcz_popup runs in a dedicated `fish --no-config` popup process, so this
    # global handler lives only for the popup's lifetime.
    set -g __tcz_popup_saved $saved
    function __tcz_popup_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_popup_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J'
    set -l result ''
    while true
        __tcz_popup_draw $sel $listw $prevw (math $rows - 1) "$current" -- $model
        printf '\e[%s;1H\e[K%s' $rows (__tcz_legend_row 12 '↑↓' move '⏎' switch x kill esc close)
        switch (__tcz_popup_readkey)
            case up
                test $sel -gt 0; and set sel (math $sel - 1)
            case down
                test $sel -lt (math $n - 1); and set sel (math $sel + 1)
            case enter
                set result (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
                break
            case kill
                # x: confirm on the bottom row, then kill + refresh the list
                set -l target (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
                if test -n "$target"
                    printf '\e[%s;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' $rows "$target"
                    set -l ans ''
                    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read ans
                    if test "$ans" = 79; or test "$ans" = 59   # y / Y
                        tmux kill-session -t "=$target" 2>/dev/null
                        set model (__tcz_overview)
                        set n (count $model)
                        test $n -gt 0; or break
                        test $sel -ge $n; and set sel (math $n - 1)
                    end
                end
            case cancel
                break
        end
    end
    functions -e __tcz_popup_cleanup
    set -e __tcz_popup_saved
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    test -n "$result"; and __tcz_switch "$result" "$client" $take
    return 0
end

function __tcz_open_switcher --argument-names client --description 'open the two-pane popup switcher (display-menu fallback if display-popup is unsupported)'
    if tmux list-commands 2>/dev/null | grep -q display-popup
        # Build argv as a list so --take stays a SEPARATE token (concatenating it onto
        # "$client" would deliver one bogus "client --take" arg to the popup process).
        set -l cmd fish --no-config $__tcz_self popup "$client"
        contains -- --take $argv; and set -a cmd --take
        tmux display-popup -E -w 80% -h 70% -- $cmd
    else
        __tcz_menu
    end
end

# --- theme picker (v3): pure builders. The interactive loop is __tcz_theme_picker. ---
function __tcz_thp_fg --argument-names hex --description 'hex -> truecolor foreground SGR; empty output for non-hex'
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$hex")
    test (count $m) -eq 3; and printf '\e[38;2;%d;%d;%dm' (math "0x$m[1]") (math "0x$m[2]") (math "0x$m[3]")
end
function __tcz_thp_bg --argument-names hex --description 'hex -> truecolor background SGR; empty output for non-hex'
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$hex")
    test (count $m) -eq 3; and printf '\e[48;2;%d;%d;%dm' (math "0x$m[1]") (math "0x$m[2]") (math "0x$m[3]")
end

function __tcz_thp_cells --argument-names hexes --description 'pure: the 7x2-col gradient strip (14 visible cols). Each cell is ▇ (U+2587, lower seven-eighths) drawn in the role colour rather than a filled cell, so one eighth stays clear at the TOP and vertically adjacent strips stop merging into one block (2026-08-01). Non-hex cells degrade to blank gaps so the strip stays aligned.'
    set -l cells ''
    for hex in (string split ' ' -- "$hexes")
        set -l fg (__tcz_thp_fg "$hex")
        if test -n "$fg"
            set cells "$cells$fg▇▇"(printf '\e[0m')
        else
            set cells "$cells  "
        end
    end
    printf '%s\n' "$cells"
end

function __tcz_thp_band --argument-names hex --description 'pure: a 14-col band in one colour, drawn with the same ▇ top gap as __tcz_thp_cells so the second list lines up with the scheme list. Non-hex -> 14 blanks.'
    set -l fg (__tcz_thp_fg "$hex")
    if test -z "$fg"
        printf '%s\n' '              '
        return
    end
    printf '%s\n' "$fg"(string repeat -n 14 ▇)(printf '\e[0m')
end

function __tcz_thp_row --argument-names hexes name selected current --description 'pure: one scheme row = marker(1) + 7×2-col gradient strip(14) + space + name; <hexes> space-joined; non-hex cells degrade to blank gaps; <current> = 1 renders the name in brand bold (the current entry), unless the row is also the cursor, where the selection styling wins'
    set -l cells (__tcz_thp_cells "$hexes")
    set -l marker ' '
    set -l namecol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set namecol (__tcz_theme sel-fg)(printf '\e[1m')
    end
    # The current entry is marked by its NAME, in brand bold — the same language as
    # the second list's `current` label. The old ❯ prefix is gone: it sat on a row
    # that is never the cursor while wearing a glyph that means "cursor".
    if test "$current" = 1; and test "$selected" != 1
        set namecol (__tcz_theme brand)(printf '\e[1m')
    end
    printf '%s%s %s%s%s' "$marker" "$cells" "$namecol" "$name" (__tcz_theme reset)
end
function __tcz_thp_staterow --argument-names w cells name label selected live --description 'pure: one SECOND-LIST row, exactly <w> visible cols: marker(1) + <cells>(14) + space(1) + <name> left-aligned + pad + <label> flush right + one trailing space. <cells> is pre-rendered (__tcz_thp_cells for a palette, __tcz_thp_band for a single colour) so both lists draw their 14 columns identically. <live> = 1 renders the label BOLD in `brand` — it means this really is what is on the bar right now, which is the readout that replaced the chevron; otherwise muted.'
    set -l marker ' '
    set -l namecol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set namecol (__tcz_theme sel-fg)(printf '\e[1m')
    end
    set -l labcol (__tcz_theme muted)
    set -l labon ''
    if test "$live" = 1
        set labcol (__tcz_theme brand)
        set labon (printf '\e[1m')
    end
    # marker(1) + cells(14) + space(1) + name + pad + label + trailing space(1)
    set -l llen (string length --visible -- "$label")
    # Truncate the NAME so the row is structurally incapable of overflowing
    # <w>: __tcz_thp_ln (the caller's frame wrapper) pads to w but never
    # truncates, and the old pad-floor-of-1 let a too-long name+label push the
    # printed row past w — which wraps in a fixed-height popup and silently
    # adds a physical row, exactly what the 26-row frame proof exists to catch
    # (and, being an element count rather than a display-column measurement,
    # cannot see). Unreachable with today's catalog (longest name is 11 cols)
    # but made impossible rather than merely unlikely.
    set -l maxnlen (math "$w - 18 - $llen")
    test $maxnlen -lt 0; and set maxnlen 0
    set -l nlen (string length --visible -- "$name")
    test $nlen -gt $maxnlen; and set name (string sub -l $maxnlen -- "$name"); and set nlen $maxnlen
    set -l pad (math "$w - 17 - $nlen - $llen")
    test $pad -lt 1; and set pad 1
    # Capture the repeat into a var and interpolate it QUOTED: a zero-output command
    # substitution used as a bare argument VANISHES from the arg list and shifts every
    # later printf field. The -lt 1 floor also catches math's "-0" STRING.
    set -l padstr (string repeat -n $pad ' ')
    printf '%s%s %s%s%s%s%s%s%s \n' \
        "$marker" "$cells" \
        "$namecol" "$name" (__tcz_theme reset) \
        "$padstr" \
        "$labon$labcol" "$label" (__tcz_theme reset)
end
function __tcz_thp_preview --argument-names hexes capfg host name w --description 'pure: the fake status-bar row from 7 role hexes (bar sep tabs active windows cap text) + cap fg — host cap, windows, ✦ identity, clock cap; EXACTLY <w> visible cols (host/name truncated, gaps computed)'
    set -l p (string split ' ' -- "$hexes")
    set -l slR (printf '\U0000e0b0')
    set -l slL (printf '\U0000e0b2')
    set -l glyph (printf '\U0000ea7a')
    set -l R (printf '\e[0m')
    # width budget: fixed segments max out at 47 visible cols (host<=6, name<=10),
    # so the two computed gaps always land the row at EXACTLY w=50; the final
    # truncate call is a pure backstop.
    set host (string sub -l 6 -- "$host")
    set name (string sub -l 10 -- "$name")
    set -l capbg (__tcz_thp_bg "$p[6]")
    set -l barbg (__tcz_thp_bg "$p[1]")
    set -l capfgS (__tcz_thp_fg "$capfg")
    set -l capfgc (__tcz_thp_fg "$p[6]")
    set -l sepfg (__tcz_thp_fg "$p[2]")
    set -l winfg (__tcz_thp_fg "$p[5]")
    set -l textfg (__tcz_thp_fg "$p[7]")
    set -l left "$capbg$capfgS $glyph $host $R$barbg$capfgc$slR$R"
    set -l leftv " x $host x"   # glyph + slant are 1 col each
    set -l win "$barbg $winfg""claude$sepfg • $winfg""edit$R"
    set -l winv " claude • edit"
    set -l mid "$barbg$capfgc✦ $textfg$name$R"
    set -l midv "✦ $name"
    set -l right "$barbg$capfgc$slL$R$capbg$capfgS 9:41 AM $R"
    set -l rightv "x 9:41 AM "
    set -l used (math (string length --visible -- "$leftv")" + "(string length --visible -- "$winv")" + "(string length --visible -- "$midv")" + "(string length --visible -- "$rightv"))
    set -l gaptotal (math "$w - $used")
    test $gaptotal -lt 2; and set gaptotal 2
    set -l g1 (math "floor($gaptotal / 2)")
    set -l g2 (math "$gaptotal - $g1")
    set -l gap1 "$barbg"(string repeat -n $g1 ' ')"$R"
    set -l gap2 "$barbg"(string repeat -n $g2 ' ')"$R"
    set -l row "$left$win$gap1$mid$gap2$right"
    # backstop clamps to exactly w visible cols; the gap math lands there already
    __tcz_popup_truncate "$row" $w
end
function __tcz_thp_ln --argument-names content w od t --description 'pad ALREADY-COLORED content to visible width w and wrap it in the themed frame (│…│)'
    set -l vis (__tcz_strip_sgr "$content")
    set -l pad (math "$w - "(string length --visible -- "$vis"))
    test $pad -lt 0; and set pad 0
    set -l padstr (string repeat -n $pad ' ')
    printf '%s│%s%s│%s\n' $od "$content$t$padstr" $od $t
end
function __tcz_thp_sep --argument-names w od t --description 'the frame mid separator (├──┤)'
    printf '%s├%s┤%s\n' $od (string repeat -n $w ─) $t
end
function __tcz_thp_zsep --argument-names w label od t --description 'pure: zone separator ├─ <label> ─…┤ (BOLD title-role label; empty label -> plain __tcz_thp_sep). od = border SGR, t = reset.'
    if test -z "$label"
        __tcz_thp_sep $w $od $t
        return
    end
    set -l MUT (__tcz_theme title)
    set -l len (string length --visible -- "$label")
    set -l fill (math "$w - 3 - $len")
    test $fill -lt 0; and set fill 0
    set -l fillstr (string repeat -n $fill ─)
    printf '%s├─ \e[1m%s%s\e[22m%s %s┤%s\n' $od $MUT "$label" $od "$fillstr" $t
end
function __tcz_thp_grouphdr --argument-names w label --description 'pure: an in-list group header, exactly <w> visible cols — col 1 blank (a scheme row carries its selection marker there; this row is never selectable), then ──, the BOLD label in the title role, then ─ fill stopping one column short of w so a blank column separates the rule from the right border. Deliberately NOT __tcz_thp_zsep: that form connects to the frame with ├ ┤ and reads as a separate section, which the user rejected.'
    set -l TIT (__tcz_theme title)
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l len (string length --visible -- "$label")
    # 1 blank + 2 dashes + 1 space + label + 1 space + fill + 1 trailing blank = w
    set -l fill (math "$w - 6 - $len")
    test $fill -lt 0; and set fill 0
    set -l fillstr (string repeat -n $fill ─)
    printf ' %s──%s \e[1m%s%s\e[22m%s %s%s %s' $MUT $RST $TIT "$label" $RST $MUT "$fillstr" $RST
end
function __tcz_thp_tabstrip --argument-names tabshex tabsfg title w --description 'pure: fake ShellFish tab BAR — a full-<w>-col band in the tabs-role color: the active tab (bold <title>) plus two faint ⋯ tabs behind │ separators, mimicking the real iOS tab strip the tabs role paints. EMPTY when tabshex is non-hex or title is empty (the reserved preview row renders blank).'
    set -l bg (__tcz_thp_bg "$tabshex")
    test -n "$bg"; or return
    test -n "$title"; or return
    # fixed furniture is 10 visible cols: ' '+title+' '+'│ ⋯ │ ⋯ '
    set -l maxt (math "$w - 10")
    set title (string sub -l $maxt -- "$title")
    set -l fgS (__tcz_thp_fg "$tabsfg")
    set -l B1 (printf '\e[1m')
    set -l FA (printf '\e[2m')
    set -l NI (printf '\e[22m')
    set -l RST (printf '\e[0m')
    set -l used (math "10 + "(string length --visible -- "$title"))
    set -l pad (math "$w - $used")
    test $pad -lt 0; and set pad 0
    set -l padstr (string repeat -n $pad ' ')
    printf '%s%s %s%s%s %s│ ⋯ │ ⋯ %s%s%s' "$bg" "$fgS" "$B1" "$title" "$NI" "$FA" "$NI" "$padstr" "$RST"
end
function __tcz_thp_seedrow --argument-names flashfield seedchip --description 'pure: the configuration zone row — the SEED label beside its value. The label wears the `flash` role while <flashfield> is `seed` (the change-flash affordance), else `muted`.'
    set -l seedlab (__tcz_theme muted)
    test "$flashfield" = seed; and set seedlab (__tcz_theme flash)
    printf '%sSEED%s   %s' "$seedlab" (__tcz_theme reset) "$seedchip"
end
function __tcz_thp_shellfish --description 'true iff any attached client is ShellFish — the production detection (__tcz_client_is_shellfish; tmux_lives_fake_environ seam applies), checked ONCE at picker open.'
    for pid in (tmux list-clients -F '#{client_pid}' 2>/dev/null)
        __tcz_client_is_shellfish $pid; and return 0
    end
    return 1
end
function __tcz_thp_slider --argument-names label value selected --description 'pure: one RGB slider row = marker(1)+label(1)+space+32-cell bar+space+3-char value; filled cells wear the channel color AT the value (intensity visible), gaps are muted ·; fixed 39 visible cols'
    set -l fill (math "round($value * 32 / 255)")
    test $fill -gt 32; and set fill 32
    test $fill -lt 0; and set fill 0
    set -l chanhex '#000000'
    switch $label
        case R; set chanhex (printf '#%02x0000' $value)
        case G; set chanhex (printf '#00%02x00' $value)
        case B; set chanhex (printf '#0000%02x' $value)
    end
    set -l bar ''
    if test $fill -gt 0
        set -l bg (__tcz_thp_bg "$chanhex")
        set -l cells (string repeat -n $fill ' ')
        set bar "$bg$cells"(printf '\e[0m')
    end
    set -l rest (math "32 - $fill")
    if test $rest -gt 0
        set -l gapc (string repeat -n $rest '·')
        set -l MUT (__tcz_theme muted)
        set -l RS (__tcz_theme reset)
        set bar "$bar$MUT$gapc$RS"
    end
    set -l marker ' '
    set -l labcol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set labcol (__tcz_theme key)
    end
    set -l valtxt (string pad -w 3 -- $value)
    set -l VC (__tcz_theme value)
    set -l RS2 (__tcz_theme reset)
    printf '%s%s%s%s %s %s%s%s' "$marker" "$labcol" "$label" "$RS2" "$bar" "$VC" "$valtxt" "$RS2"
end
function __tcz_thp_vismap --argument-names sel n dirn --description 'pure: move the picker cursor one step within the SCHEME list — scheme_0 … scheme_{n-1} (sel 0..n-1). up = max(0, sel-1); down = min(n-1, sel+1). The second list (current + off) is a SEPARATE list with its own cursor, reached only with ⇥, so this never leaves the scheme range.'
    set -l vp $sel
    if test "$dirn" = up
        set vp (math $vp - 1)
        test $vp -lt 0; and set vp 0
    else
        set vp (math $vp + 1)
        set -l last (math $n - 1)
        test $last -lt 0; and set last 0
        test $vp -gt $last; and set vp $last
    end
    echo $vp
end
function __tcz_thp_window --argument-names sel total winsize --description 'pure: window a long list -> "<start> <count>" (0-based first visible index + rows to draw), clamped so sel stays visible and the window never overruns total'
    if test $total -le $winsize
        echo "0 $total"; return
    end
    # --scale=0: fish's `math` is floating-point, not integer division — an
    # ODD winsize (e.g. 7) makes `winsize / 2` land on .5 for EVERY sel, so an
    # un-truncated $start would be fractional on every non-clamped call. That
    # fractional string then blows up downstream ($toks[$idx] -> fish "Invalid
    # index value") — truncate here so start is always a clean integer.
    set -l start (math --scale=0 "$sel - $winsize / 2")
    # --scale=0 truncates toward zero, so a fractional negative like -0.5
    # becomes the STRING "-0" — not "0". `test -0 -lt 0` is false (string
    # "-0" numerically equals 0), so the old `-lt 0` clamp let "-0" through
    # uncaught, and the caller's `string split ' ' -- "-0 7"` then errors
    # ("-0: unknown option", -0 parsed as a flag). `-le 0` catches -0 too;
    # the harmless 0 -> 0 case still no-ops.
    test $start -le 0; and set start 0
    set -l maxstart (math "$total - $winsize")
    test $start -gt $maxstart; and set start $maxstart
    echo "$start $winsize"
end

function __tcz_thp_swatch --argument-names hex hue L C --description 'pure: 4-line big seed swatch — 12-col color band + readouts (hex bold / hue·L·chroma / the seed-IS-the-bar copy). Non-hex hex -> blank band, empty text.'
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l band '            '
    set -l bg (__tcz_thp_bg "$hex")
    test -n "$bg"; and set band "$bg            $RST"
    set -l t1 ''
    set -l t2 ''
    if test -n "$bg"
        set t1 (printf '\e[1m%s\e[22m' "$hex")
        set t2 "$MUT""hue $hue° · L $L · chroma $C$RST"
    end
    printf '%s\n' "$band  $t1" "$band  $t2" "$band  $MUT""rendered as-is on the bar;$RST" "$band  $MUT""companions derive from it$RST"
end
function __tcz_thp_seedzone --argument-names w hex hue L C editing chan r g b --description 'pure: the seed configuration zone — a FIXED 8-row, fully-framed section (a zone separator labelled seed + the 4-row __tcz_thp_swatch band + 3 rows that read out hex/hue·L/chroma while editing=0, or three __tcz_thp_slider R/G/B bars — the one at <chan> marked selected — while editing=1). Every row is exactly w+2 visible cols, border glyphs included (like __tcz_thp_zsep/__tcz_thp_ln); rows 1-5 are IDENTICAL in both states, so toggling edit mode never resizes the scheme window below it — only rows 6-8 change. Reuses __tcz_thp_swatch/__tcz_thp_slider rather than re-deriving them; each row is wrapped in __tcz_thp_ln, which pads short content to w itself. Callers append the 8-line result to their own `lines` verbatim — it already carries the frame borders, so do not re-wrap it in __tcz_thp_ln.'
    set -l BORDER (__tcz_theme border)
    set -l RST (__tcz_theme reset)
    set -l lines
    set -a lines (__tcz_thp_zsep $w seed $BORDER $RST)
    for row in (__tcz_thp_swatch "$hex" "$hue" "$L" "$C")
        set -a lines (__tcz_thp_ln "$row" $w $BORDER $RST)
    end
    if test "$editing" = 1
        set -l s1 0
        set -l s2 0
        set -l s3 0
        test "$chan" = 1; and set s1 1
        test "$chan" = 2; and set s2 1
        test "$chan" = 3; and set s3 1
        set -l row1 (__tcz_thp_slider R $r $s1)
        set -l row2 (__tcz_thp_slider G $g $s2)
        set -l row3 (__tcz_thp_slider B $b $s3)
        set -a lines (__tcz_thp_ln "$row1" $w $BORDER $RST)
        set -a lines (__tcz_thp_ln "$row2" $w $BORDER $RST)
        set -a lines (__tcz_thp_ln "$row3" $w $BORDER $RST)
    else
        set -l MUT (__tcz_theme muted)
        set -l RS (__tcz_theme reset)
        set -l hexbold (printf '\e[1m%s\e[22m' "$hex")
        set -a lines (__tcz_thp_ln "$hexbold" $w $BORDER $RST)
        set -a lines (__tcz_thp_ln "$MUT""hue $hue° · L $L$RS" $w $BORDER $RST)
        set -a lines (__tcz_thp_ln "$MUT""chroma $C$RS" $w $BORDER $RST)
    end
    printf '%s\n' $lines
end
function __tcz_thp_readchar --description 'seed-entry raw byte -> <hexchar>|hash|back|enter|esc|up|down|left|right|t|other (dd HEAD-of-pipeline; tty already raw)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo esc; return; end
    switch "$b"
        case 0d 0a; echo enter; return
        case 7f 08; echo back; return
        case 23; echo hash; return
        case 74; echo t; return                       # t (slider screen: type hex)
    end
    if test "$b" = 1b                                # ESC
        # bare ESC vs CSI (\e[…) / SS3 (\eO…) arrow: non-blocking follow-read,
        # mirroring __tcz_popup_readkey's pattern above. Without this, a bare
        # `1b` returned `esc` immediately and leaked the following `[`+letter
        # bytes, which the outer picker's loop then read as an ↑↓ keystroke
        # and moved the scheme selection out from under seed entry. Arrows are
        # now CLASSIFIED (up/down/left/right); the hex editor still ignores
        # them (ignore-case below), while the slider screen consumes them. A
        # genuine bare ESC still aborts entry.
        stty min 0 time 1 2>/dev/null
        set -l b2 ''
        dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b2
        set -l b3 ''
        if test "$b2" = 5b; or test "$b2" = 4f       # [ or O
            dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b3
        end
        stty min 1 time 0 2>/dev/null
        if test "$b2" = 5b; or test "$b2" = 4f
            switch "$b3"
                case 41; echo up; return
                case 42; echo down; return
                case 43; echo right; return
                case 44; echo left; return
            end
            echo other; return
        end
        echo esc; return                              # bare ESC
    end
    set -l ch (printf '%b' "\\x$b" 2>/dev/null)
    if string match -qr -- '^[0-9a-fA-F]$' "$ch"
        echo $ch
        return
    end
    echo other
end

function __tcz_thp_leg --argument-names cols --description 'pure: cross-row-aligned legend grid — argv[2..] = <key> <desc> pairs, `cols` pairs per row, row-major. Column widths are the MAX key/desc visible-width over ALL rows (not per-row) — the fix for the old __tcz_legend_row-per-row wiring, where each rows cell widths were sized independently and column 3 landed at a different x on every row. Each cell = key (key color, padded to the columns keyw) + 1 space + desc (muted, padded to the columns descw); cells joined by a 3-space gap; each row prefixed by 1 space. Prints one line per grid row.'
    set -l pairs $argv[2..-1]
    set -l n (count $pairs)
    test (math "$n % 2") -eq 0; or return 1     # malformed: odd key/desc count
    set -l npairs (math "$n / 2")
    set -l keys
    set -l descs
    for i in (seq 1 2 $n)
        set -a keys $pairs[$i]
        set -a descs $pairs[(math $i + 1)]
    end
    # column widths = MAX over ALL rows — the whole point: this is what makes
    # descriptions line up column-to-column regardless of a shorter/longer
    # icon on some other row. fish math has no max()/comparison op, so track
    # it via test+set (NOT `math max`).
    set -l keyw
    set -l descw
    for c in (seq 1 $cols)
        set -a keyw 0
        set -a descw 0
    end
    for i in (seq 1 $npairs)
        set -l col (math "($i - 1) % $cols + 1")
        set -l kw (string length --visible -- $keys[$i])
        set -l dw (string length --visible -- $descs[$i])
        test $kw -gt $keyw[$col]; and set keyw[$col] $kw
        test $dw -gt $descw[$col]; and set descw[$col] $dw
    end
    set -l KC (__tcz_theme key)
    set -l DC (__tcz_theme muted)
    set -l RS (__tcz_theme reset)
    set -l line ' '
    for i in (seq 1 $npairs)
        set -l col (math "($i - 1) % $cols + 1")
        # pad from the PLAIN glyph width, THEN colorize (SGR has 0 visible width)
        set -l kpad (string pad -r -w $keyw[$col] -- $keys[$i])
        set -l dpad (string pad -r -w $descw[$col] -- $descs[$i])
        set -l cell "$KC$kpad$RS $DC$dpad$RS"
        if test $col -eq 1
            set line "$line$cell"
        else
            set line "$line   $cell"
        end
        # emit a line every `cols` cells — a counter/modulo, NOT a precomputed
        # row count via --scale=0 division (that ROUNDS).
        if test $col -eq $cols
            printf '%s\n' "$line"
            set line ' '
        end
    end
    test "$line" != ' '; and printf '%s\n' "$line"    # trailing partial row, if any
end

function __tcz_theme_picker --argument-names client --description 'interactive theme picker (gallery model): tab-chip + fake-bar preview, a seed configuration zone, then a windowed scrollable list of CURATED catalog entries (14 default, m expands to all 35) — each entry is a full recipe (relationship + seed placement + mode) baked into the catalog, never user-cycled — plus a second, UNTITLED list at the bottom holding the current theme and off (the current row is a frozen snapshot of the persisted theme, taken once at open). Two lists, two cursors: sel (0..n-1) walks the scheme list via __tcz_thp_vismap (clamped to n-1); sel2 (0 = current, 1 = off) walks the second list. focus (list/state) tracks which list ↑↓/jk steers; ⇥ toggles it, and ↑↓ never crosses between them. The current entrys NAME renders in brand bold (matching the second-list current label) whichever row matches the anchor recipe (relationship AND place AND mode) AND the live phase — it clears the moment phase is nudged. b seed (RGB sliders; t drops to typed hex), m expand/collapse the catalog 14<->35 (reloads and clamps sel to the new length), z shake (jump to a random row across the full 35-entry catalog, expanding first), a apply preview (no save; a scheme/off row previews its own recipe at the live phase, the current row previews its own frozen recipe plus its phase snapshot — vividness/shape/ease/contrast were removed, provably inert, never reached the engine), enter save (via the CLI, silenced — the selected rows recipe plus the live phase; the current row saves its snapshot verbatim), Esc/q revert+close. The earlier relationship-axis pickers p/P place-cycle, m/M mode-toggle, and r reset keys are RETIRED — place and mode now come from the selected catalog entrys recipe, never a user-cycled knob. Runs INSIDE a display-popup (-w 52 -h 85%); the frame always emits exactly as many rows as the popup — 21 static chrome/seed-zone/second-list/legend rows + a scheme window derived from the popup'"'"'s own reported height (WIN = rows - 21, read via `stty size`; a popup taller than the client refuses to open on tmux 3.3a rather than clamping, so a fixed row count could not survive a shorter client). The window holds WIN virtual rows regardless of the 14-vs-35 catalog size — when expanded one of them is spent on the More Schemes group header rather than a scheme, and when the catalog is shorter than WIN the remainder is padded with blank framed rows so the frame still ends exactly at the popup'"'"'s bottom.'
    # This script runs under fish --no-config: the install-side engine is sourced
    # ONCE below so the HOT path (palette batch, draw, readouts) runs in-process
    # (no per-keypress subprocess spawn — the 2026-07-17 live lag, brutal on
    # macOS). BUT --no-config neither READS nor WRITES universal variables, so
    # every universal-touching ACTION (init state read, a-preview, esc-revert,
    # seed applies, ⏎ saves) goes through a config-loaded fish child —
    # one subprocess per user action, never per keypress. This file's only
    # top-level statement is a guarded pi global, so sourcing is side-effect-free.
    set -l __tcz_engine "$__fish_config_dir/conf.d/tmux-lives-install.fish"
    test -r $__tcz_engine; and source $__tcz_engine
    set -l seed ''
    set -l theme mono
    set -l phase 0
    # The picker's WORKING phase is pinned at 0 (hidden knob). The PERSISTED
    # phase is kept separately so the `current` row can still snapshot what you
    # actually have — otherwise confirming your own theme would silently zero it.
    set -l persisted_phase 0
    set -l expanded 0
    # Where the curated rows end and the appended ones begin. Constant for the
    # session; the reload composes default-then-rest in exactly this order.
    set -l ndefault (count (__tmux_lives_theme_catalog_default))
    set -l legacy ''
    set -l seedfg '#f5f5f5'
    # place/mode: READ-ONLY picker state — populated once by __tcz_thp_init
    # from the PERSISTED universals, consumed only by the anchor snapshot
    # (below). Nothing in the interactive loop mutates them anymore: place/
    # mode now come from the SELECTED catalog entry's recipe (see $recipes),
    # not a user-cycled knob.
    set -l place bar
    set -l mode derived
    set -l previewed 0
    function __tcz_thp_init --no-scope-shadowing
        # Universal reads MUST go through a config-loaded child: this process
        # runs --no-config, which neither READS nor WRITES universal variables
        # (2026-07-17 live bug: in-process reads saw no seed at all). One
        # subprocess at open + per save action; the hot path stays in-process.
        set -l init (fish -c '
            echo (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ""))
            echo (__tmux_lives_key tmux_lives_theme mono)
            echo (__tmux_lives_key tmux_lives_theme_phase 0)
            echo (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))
            echo (__tmux_lives_contrast_fg (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color "")))
            echo (__tmux_lives_key tmux_lives_theme_place bar)
            echo (__tmux_lives_key tmux_lives_theme_mode derived)' 2>/dev/null)
        test (count $init) -ge 1; and set seed $init[1]
        test (count $init) -ge 2; and test -n "$init[2]"; and set theme $init[2]
        # $phase stays pinned at 0 — hidden knob, so every SCHEME row previews and
        # saves at 0, and a stored non-zero phase resets when you save a scheme
        # (intended: a different SEED is the better lever). The persisted value is
        # captured separately for the anchor snapshot so the `current` row still
        # means "exactly what you have now" rather than silently zeroing it.
        test (count $init) -ge 3; and test -n "$init[3]"; and set persisted_phase $init[3]
        set legacy ''
        test (count $init) -ge 4; and set legacy (string replace -rf '.*bg=([^,]+).*' '$1' -- "$init[4]")
        set seedfg '#f5f5f5'
        test (count $init) -ge 5; and test -n "$init[5]"; and set seedfg $init[5]
        # place/mode: read for the anchor snapshot ONLY (see the top-level
        # comment on the `place`/`mode` decls).
        test (count $init) -ge 6; and test -n "$init[6]"; and set place $init[6]
        test (count $init) -ge 7; and test -n "$init[7]"; and set mode $init[7]
        test -n "$seed"; or set seed '#3a3a3a'   # no seed yet: neutral, so the picker still teaches
    end
    __tcz_thp_init
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    set -l cachekeys
    set -l cacheblobs
    function __tcz_thp_reload --no-scope-shadowing --description 'batch: catalog entries (14 default / 35 all) + fgs, in-process; v5 engine results cached by knob-state key (seed/phase/expanded)'
        set toks; set pals; set fgs; set tabsfgs; set recipes
        set -l key "$seed|$phase|$expanded"
        set -l blob ''
        set -l ci (contains -i -- "$key" $cachekeys)
        if test -n "$ci"
            set blob $cacheblobs[$ci]
        else
            set -l lines
            # Expanding APPENDS the rest under a header rather than swapping the
            # row source: the full catalog is in tier order, so a wholesale swap
            # scatters the curated rows and you lose track of what you have seen.
            set -l rows (__tmux_lives_theme_catalog_default)
            test "$expanded" = 1; and set -a rows (__tmux_lives_theme_catalog_rest)
            for e in $rows
                set -l f (string split '|' -- $e)
                set -l p (__tmux_lives_theme_palette $seed $f[2] $f[3] $f[4] $phase)
                test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
                # cap/tabs are pinned (fields 6/3 of pal) -> compute their fgs once
                set -l capfg (__tmux_lives_contrast_fg "$p[6]")
                set -l tabsfg (__tmux_lives_contrast_fg "$p[3]")
                set -l pj (string join ' ' $p)
                set -l recipe "$f[2]|$f[3]|$f[4]"
                set -a lines "$f[1]|$pj|$capfg|$tabsfg|$recipe"
            end
            set -l bj (string join \x1e $lines)
            set blob "$bj"
            set -a cachekeys "$key"
            set -a cacheblobs "$blob"
        end
        for line in (string split \x1e -- $blob)
            # -m 4: caps the split at 4 pipes so the recipe (field 5, itself
            # "relationship|place|mode") keeps its embedded |s intact — this
            # only holds because fields 1-4 (name/palette/capfg/tabsfg) are
            # themselves guaranteed pipe-free; a pipe creeping into any of
            # them would shift the split and corrupt the recipe field.
            set -l f (string split -m 4 '|' -- $line)   # recipe is last; keep embedded |
            test -n "$f[1]"; or continue
            set -a toks $f[1]
            set -a pals "$f[2]"
            set -a fgs "$f[3]"
            set -a tabsfgs "$f[4]"
            set -a recipes "$f[5]"
        end
    end
    function __tcz_thp_hexentry --no-scope-shadowing --description 'typed-hex seed entry (raw; live swatch + hue/L/chroma readouts at parse-complete). Framed like every other picker screen (picker-seed-section Task 5): the popup itself opens with display-popup -B, so tmux draws no border of its own — an unframed screen used to float on the users scrollback. Reuses __tcz_thp_ln/__tcz_theme border rather than hand-rolling a new frame style; $BORDER/$RST/$BRAND/$IW are the callers own (shared via --no-scope-shadowing, already set before the interactive loop that can reach here).'
        set -l buf (string replace -r '^#' '' -- $seed)
        set -l cand ''
        set -l hue ''
        set -l okl ''
        set -l okc ''
        set -l entering 1
        # Top-border title, measured the same way __tcz_thp_zsep measures its own
        # label — pieces summed into a length rather than a hardcoded fill count,
        # so it can never silently drift out of step with $IW.
        set -l htA "╭─ "
        set -l htWord seed
        set -l htB " ─ typed hex "
        set -l heB1 (printf '\e[1m')
        set -l heB0 (printf '\e[22m')
        set -l htlen (math (string length -- $htA)+(string length -- $htWord)+(string length -- $htB)+1)
        set -l htfill (math "$IW + 2 - $htlen")
        test $htfill -lt 0; and set htfill 0
        # Capture the repeat into a var FIRST and interpolate it QUOTED — the same
        # zero-output-substitution hazard __tcz_thp_zsep's own $fillstr guards
        # against: at fill=0, `string repeat -n 0 ─` emits nothing, and splicing
        # that directly into this concatenation (no intervening var) would make
        # the WHOLE right-hand side a zero-element list, silently vanishing the
        # entire top border row instead of just its dash fill.
        set -l htfillstr (string repeat -n $htfill ─)
        set -l hetop $BORDER$htA$heB1$BRAND$htWord$heB0$BORDER$htB"$htfillstr╮"$RST
        set -l hebot $BORDER"╰"(string repeat -n $IW ─)"╯"$RST
        printf '\e[2J'
        while test $entering -eq 1
            set cand ''
            set hue ''
            set okl ''
            set okc ''
            set -l b6 $buf
            string match -qr '^[0-9a-fA-F]{3}$' -- $buf; and set b6 (string sub -l 1 -- $buf)(string sub -l 1 -- $buf)(string sub -s 2 -l 1 -- $buf)(string sub -s 2 -l 1 -- $buf)(string sub -s 3 -l 1 -- $buf)(string sub -s 3 -l 1 -- $buf)
            if string match -qr '^[0-9a-fA-F]{6}$' -- $b6
                set cand "#"(string lower -- $b6)
                set -l rgb (__tmux_lives_hex_to_rgb01 $cand)
                set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
                set -l ro (printf '%.0f %.2f %.3f' $ok[3] $ok[1] $ok[2])
                set -l rop (string split ' ' -- "$ro")
                set hue "$rop[1]"; set okl "$rop[2]"; set okc "$rop[3]"
            end
            set -l sw4 (__tcz_thp_swatch "$cand" "$hue" "$okl" "$okc")
            set -l leg (__tcz_legend_row 14 '⏎' apply esc cancel)
            set -l hdrrow (printf ' %sseed — this IS the bar color%s' "$heB1" "$heB0")
            set -l bufrow (printf ' #%s_' "$buf")
            set -l helines
            set -a helines $hetop
            set -a helines (__tcz_thp_ln "$hdrrow" $IW $BORDER $RST)
            set -a helines (__tcz_thp_ln "$bufrow" $IW $BORDER $RST)
            set -a helines (__tcz_thp_ln '' $IW $BORDER $RST)
            for row in $sw4
                set -a helines (__tcz_thp_ln "$row" $IW $BORDER $RST)
            end
            set -a helines (__tcz_thp_ln '' $IW $BORDER $RST)
            set -a helines (__tcz_thp_ln "$leg" $IW $BORDER $RST)
            set -a helines $hebot
            # Synchronized update (DECSET 2026), same atomic-paint pattern as the
            # main frame below — commits the entry paint in one go. Newlines
            # BETWEEN rows only (the __tcz_popup_draw / main-frame convention): a
            # trailing newline after the last row scrolls the top border off.
            printf '\e[?2026h\e[H'
            test (count $helines) -gt 1; and printf '%s\e[K\n' $helines[1..-2]
            printf '%s\e[K' $helines[-1]
            printf '\e[J\e[?2026l'
            set -l tok (__tcz_thp_readchar)
            switch $tok
                case back
                    test -n "$buf"; and set buf (string sub -e -1 -- $buf)
                case enter
                    if test -n "$cand"
                        # PREVIEW ONLY — ⏎ at the top level is what commits. Writing the
                        # universal here is why Esc could not restore the seed: it was
                        # already gone, and every role derives from it, so the scheme
                        # looked unrestored too even with its own universals intact.
                        set seed $cand
                        set seedfg (__tmux_lives_contrast_fg "$seed")
                        __tcz_thp_reload
                        __tcz_thp_reanchor
                        set note "seed previewed: $seed"
                        set flashfield seed
                    end
                    set entering 0
                case esc
                    set entering 0
                case hash other t up down left right
                    # ignored in hex entry ('#' implied; arrows/t are slider-screen tokens)
                case '*'
                    # $tok IS the typed hex character
                    test (string length -- $buf) -lt 6; and set buf "$buf"(string lower -- $tok)
            end
        end
        printf '\e[2J'
    end
    function __tcz_thp_sliders --no-scope-shadowing --description 'RGB slider seed screen: ↑↓ channel, ←→ ±8 (coalesced), t typed hex, ⏎ apply, esc cancel'
        set -l r 58
        set -l g 58
        set -l b 58
        set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$seed")
        if test (count $m) -eq 3
            set r (math "0x$m[1]")
            set g (math "0x$m[2]")
            set b (math "0x$m[3]")
        end
        set -l chan 1
        set -l hue ''
        set -l okl ''
        set -l okc ''
        set -l stale 1
        set -l sliding 1
        printf '\e[2J'
        while test $sliding -eq 1
            set -l hex (printf '#%02x%02x%02x' $r $g $b)
            if test $stale -eq 1
                set -l rgb (__tmux_lives_hex_to_rgb01 $hex)
                set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
                set -l ro (printf '%.0f %.2f %.3f' $ok[3] $ok[1] $ok[2])
                set -l rop (string split ' ' -- "$ro")
                set hue "$rop[1]"; set okl "$rop[2]"; set okc "$rop[3]"
                set stale 0
            end
            set -l s1 0
            set -l s2 0
            set -l s3 0
            switch $chan
                case 1; set s1 1
                case 2; set s2 1
                case 3; set s3 1
            end
            set -l row1 (__tcz_thp_slider R $r $s1)
            set -l row2 (__tcz_thp_slider G $g $s2)
            set -l row3 (__tcz_thp_slider B $b $s3)
            set -l sw4 (__tcz_thp_swatch $hex "$hue" "$okl" "$okc")
            set -l leg1 (__tcz_legend_row 14 '↑↓' channel '←→' adjust t 'type hex')
            set -l leg2 (__tcz_legend_row 14 '⏎' apply esc cancel)
            printf '\e[?2026h\e[H \e[1mseed — this IS the bar color\e[22m\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n%s\e[K\n%s\e[K' "$row1" "$row2" "$row3" $sw4[1] $sw4[2] $sw4[3] $sw4[4] "$leg1" "$leg2"
            printf '\e[J\e[?2026l'
            set -l tok (__tcz_thp_readchar)
            switch $tok
                case up
                    test $chan -gt 1; and set chan (math $chan - 1)
                case down
                    test $chan -lt 3; and set chan (math $chan + 1)
                case left right
                    set -l delta -8
                    test "$tok" = right; and set delta 8
                    while true
                        stty min 0 time 0 2>/dev/null
                        set -l k2 (__tcz_thp_readchar)
                        switch "$k2"
                            case left; set delta (math $delta - 8)
                            case right; set delta (math $delta + 8)
                            case '*'; break
                        end
                    end
                    stty min 1 time 0 2>/dev/null
                    set -l names r g b
                    set -l vn $names[$chan]
                    set -l cur $$vn
                    set cur (math "$cur + $delta")
                    test $cur -lt 0; and set cur 0
                    test $cur -gt 255; and set cur 255
                    set $vn $cur
                    set stale 1
                case t
                    __tcz_thp_hexentry
                    set sliding 0
                case enter
                    # PREVIEW ONLY — ⏎ at the top level is what commits. Writing the
                    # universal here is why Esc could not restore the seed: it was
                    # already gone, and every role derives from it, so the scheme
                    # looked unrestored too even with its own universals intact.
                    set seed (printf '#%02x%02x%02x' $r $g $b)
                    set seedfg (__tmux_lives_contrast_fg "$seed")
                    __tcz_thp_reload
                    __tcz_thp_reanchor
                    set note "seed previewed: $seed"
                    set flashfield seed
                    set sliding 0
                case esc
                    set sliding 0
            end
        end
        printf '\e[2J'
    end
    __tcz_thp_reload
    set -l n (count $toks)          # n = catalog rows (14/35); the scheme list is sel 0..n-1
    # anchor snapshot: the persisted theme, frozen for this picker session
    set -l anch_seed $seed
    set -l anch_scheme $theme
    set -l anch_phase $persisted_phase
    set -l anch_place $place
    set -l anch_mode $mode
    # Two-list model. The scheme list owns `sel` (0..n-1); the second list — the
    # current theme and off — owns `sel2` (0 = current, 1 = off). ⇥ moves between
    # them and ↑↓ never crosses. This replaces the old linear order, where off was
    # sel n and the current row was an sel n+1 tail reachable only by pressing c.
    set -l focus list
    set -l sel2 0
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    # Recomputes anchpal/anchfg/anchtabsfg for the CURRENT $seed against the
    # frozen anchor recipe (anch_scheme/place/mode/phase — these never change
    # after the snapshot above). --no-scope-shadowing so it mutates the
    # caller's vars directly, same as reload does
    # for toks/pals/fgs/tabsfgs. Call once here AND again after any seed edit
    # (hexentry/sliders' ⏎) — every OTHER row already re-derives from $seed
    # via __tcz_thp_reload; without this, the `current` row's band, and the
    # top preview/tab chip whenever the cursor sits on it, silently kept
    # rendering the OLD seed while `a`/`⏎` had already moved on to the new one.
    function __tcz_thp_reanchor --no-scope-shadowing
        set anchpal ''
        set anchfg '#f5f5f5'
        set anchtabsfg '#f5f5f5'
        if test "$anch_scheme" != off
            set -l ap (__tmux_lives_theme_palette $seed $anch_scheme $anch_place $anch_mode $anch_phase)
            if test (count $ap) -eq 7
                set -l apj (string join ' ' $ap)
                set anchpal "$apj"
                set -l af (__tmux_lives_contrast_fg "$ap[6]")
                test -n "$af"; and set anchfg "$af"
                set -l atf (__tmux_lives_contrast_fg "$ap[3]")
                test -n "$atf"; and set anchtabsfg "$atf"
            end
        end
    end
    __tcz_thp_reanchor
    set -l sel 0
    # Seed edit mode (Task 4): editing=1 shows the seedzone's R/G/B sliders
    # instead of its readouts and reroutes ↑↓/←→ to them (see the seedzone
    # draw call and the arrow dispatch below). chan selects which channel
    # (1=R/2=G/3=B) ←→ moves. editseed captures $seed at the moment editing
    # is entered, so esc has something to revert to that is scoped to the
    # CURRENT edit session — not the picker-open anchor ($anch_seed, which
    # the outer Esc/cancel path still owns).
    set -l editing 0
    set -l chan 1
    set -l editseed ''
    set -l saved (stty -g)
    set -g __tcz_thp_saved $saved
    function __tcz_thp_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_thp_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    set -l IW 50
    # Window size lives out here so BOTH the draw loop and the key dispatch (which
    # pages by it) see one value — a second literal would drift.
    # The popup opens at a PERCENTAGE height, because a popup taller than the client
    # does not clamp on tmux 3.3a — it refuses to open. So the picker cannot know its
    # height in advance and must ask. `stty size` reports the popup's real dimensions
    # ($LINES/$COLUMNS are not exported into a popup). One derived quantity; every
    # other measurement in this function stays fixed.
    # picker-seed-section Task 3: the seed became a fixed 8-row section (was 1
    # row behind its own zsep, sharing the 'configuration' zsep before it) —
    # net +6 static rows: top border · tab chip · preview bar · [seed zone:
    # zsep + 4-row swatch + 3 readout/slider rows] · schemes zsep ·
    # second-list zsep · current · off · blank zsep · legend×3 · note ·
    # bottom border = 21.
    set -l STATIC 21
    set -l dims (stty size 2>/dev/null | string split ' ')
    set -l rows 26
    test (count $dims) -ge 1; and test -n "$dims[1]"; and set rows $dims[1]
    set -l WIN (math "$rows - $STATIC")
    if test $WIN -lt 3
        # Too short to draw a usable list. Say so plainly rather than rendering a
        # frame that overflows and scrolls its own top border away.
        printf '\e[2J\e[H tmux-lives: window too short for the theme picker\n (needs %s rows, has %s)\n' (math "$STATIC + 3") $rows
        stty $saved 2>/dev/null
        return 0
    end
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l host (__tcz_hostname)
    set -l sf 0
    __tcz_thp_shellfish; and set sf 1
    set -l chiptitle ''
    if test $sf -eq 1
        set -l cursess (tmux display-message -p '#{session_name}' 2>/dev/null)
        test -n "$cursess"; and set chiptitle (__tcz_session_title $cursess)
    end
    set -l note ''
    set -l flashfield ''
    # picker-seed-section Task 6 fix round 1: a batch reload/reanchor is owed
    # whenever a live channel edit has happened but the picker hasn't yet
    # settled. This is DELIBERATELY separate from $flashfield — flashfield is
    # a purely cosmetic highlight flag (its only consumer, __tcz_thp_seedrow,
    # has been unreferenced since Task 3) that several OTHER arms clear on
    # their own unrelated keypresses (m/z/tab) with no idea it also carries a
    # recompute obligation. Coupling the two meant those arms silently
    # cancelled a pending batch. seeddirty is cleared ONLY where it is
    # consumed, in the settle block below.
    set -l seeddirty 0
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J'
    set -l apply ''
    while true
        # cursor row palette — two lists, two lookups. focus=list: sel is
        # LINEAR 0..n-1 into $pals/$fgs/$tabsfgs (1-indexed, so capture sel+1
        # into a var FIRST — a math() expression written directly inside a
        # quoted subscript is a fish "Invalid index value" ERROR, not a valid
        # index). focus=state: sel2 selects within the second list — 0 =
        # current (the anchor snapshot; an EMPTY anchpal, e.g. the persisted
        # theme was off/no-seed, falls through to the legacy branch), 1 = off
        # (legacy colors).
        set -l curpal ''
        set -l curfg '#f5f5f5'
        set -l curtabsfg '#f5f5f5'
        if test $focus = state
            # second list: sel2 0 = current (the anchor snapshot), 1 = off (legacy colors)
            if test $sel2 -eq 0; and test -n "$anchpal"
                set curpal $anchpal
                set curfg $anchfg
                set curtabsfg $anchtabsfg
            else
                set -l lb "$legacy"
                test -n "$lb"; or set lb '#444444'
                set curpal "$lb #6b6b6b #6b6b6b #6b6b6b #9a9a9a #444444 #d3d8d0"
                set curfg '#f5f5f5'
            end
        else
            set -l pi (math $sel + 1)
            set curpal $pals[$pi]
            set -l cf $fgs[$pi]
            test -n "$cf"; and set curfg $cf
            set curtabsfg "$tabsfgs[$pi]"
        end
        set -l ptoks (string split ' ' -- $curpal)
        set -l curtabs "$ptoks[3]"
        set -l B1 (printf '\e[1m')
        set -l B0 (printf '\e[22m')
        # NB: fish does NOT interpret \e inside quoted strings (only printf does) —
        # the bold SGRs must be printf-captured vars, never "\e[1m" literals.
        set -l lines
        set -a lines $BORDER"╭─ $B1"$BRAND"theme$B0"$BORDER" ─ preview "(string repeat -n (math "$IW - 18") ─)"╮"$RST
        # capture-then-quote: __tcz_thp_tabstrip prints NOTHING when non-ShellFish (the
        # common case) — a zero-output command substitution used as a bare argument
        # VANISHES from the arg list, so __tcz_thp_ln would silently get 3 args
        # instead of 4 (content=$IW, w=$BORDER, ...) and spray math/test errors into
        # the popup on every redraw. Capture into a var first, then quote it.
        set -l chip (__tcz_thp_tabstrip "$curtabs" "$curtabsfg" "$chiptitle" $IW)
        set -a lines (__tcz_thp_ln "$chip" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_thp_preview "$curpal" "$curfg" "$host" Monitoring $IW) $IW $BORDER $RST)
        # picker-seed-section Task 3: the seed is a FIXED 8-row section (zsep +
        # 4-row swatch + 3 readout/slider rows), not the old single zsep+row —
        # see __tcz_thp_seedzone. Task 4 wires the real in-place edit-mode
        # toggle (editing/chan below), so this call now passes the live
        # state instead of a literal 0/1. hue/L/C and r/g/b are recomputed
        # from $seed every redraw (in-process fish math, no subprocess
        # spawn) — Task 3's own point in doing this was that the edit-mode
        # flip needs no extra plumbing here, and that holds: a ←→ channel
        # move (below) mutates $seed itself, and this block picks it up on
        # the very next redraw. The zone arrives already framed (zsep +
        # __tcz_thp_ln rows), so it is appended to lines verbatim — wrapping
        # it in __tcz_thp_ln again would double the border.
        set -l seedm (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$seed")
        set -l seedr 0
        set -l seedg 0
        set -l seedb 0
        if test (count $seedm) -eq 3
            set seedr (math "0x$seedm[1]")
            set seedg (math "0x$seedm[2]")
            set seedb (math "0x$seedm[3]")
        end
        set -l seedrgb01 (__tmux_lives_hex_to_rgb01 $seed)
        set -l seedoklch (__tmux_lives_rgb_to_oklch $seedrgb01[1] $seedrgb01[2] $seedrgb01[3])
        set -l seedro (printf '%.0f %.2f %.3f' $seedoklch[3] $seedoklch[1] $seedoklch[2])
        set -l seedrop (string split ' ' -- "$seedro")
        set -a lines (__tcz_thp_seedzone $IW "$seed" "$seedrop[1]" "$seedrop[2]" "$seedrop[3]" $editing $chan $seedr $seedg $seedb)
        # Windowed scrolling list: only the SCHEME rows scroll; the second list
        # (current + off) is pinned below, always drawn. sel can never exceed
        # n-1 (vismap clamps it there), so the window anchor no longer needs a
        # clamp for an off/anchor cursor position — that clamp is dead, removed.
        # The frame is 21 static rows (border/chip/preview/seed-zone[zsep+
        # swatch×4+3 readout-or-slider rows]/schemes-zsep/second-list-zsep/
        # current/off/blank-zsep/legend×3/note/bottom-border) + WIN scheme
        # rows = rows (the popup's own reported height, see STATIC above).
        # Virtual rows = schemes + the More Schemes header when expanded. sel indexes
        # SCHEMES only, so it can never land on the header and vismap needs no change:
        # stepping over it falls out of the model instead of being a special case that
        # ↑↓, PgUp/PgDn, z and the collapse clamp would each have to repeat.
        set -l vtotal $n
        set -l vsel $sel
        if test "$expanded" = 1
            set vtotal (math $n + 1)
            test $sel -ge $ndefault; and set vsel (math $sel + 1)
        end
        set -l win (__tcz_thp_window $vsel $vtotal $WIN)
        set -l ws (string split ' ' $win)
        set -l start $ws[1]
        set -l count $ws[2]
        # Bare `schemes`: the subtitle and the scroll-position overflow counts are
        # gone at the user request. KNOWN COST, accepted: those counts were the only
        # cue that the list scrolls at all. It still scrolls; you just cannot see how much.
        set -a lines (__tcz_thp_zsep $IW schemes $BORDER $RST)
        if test $count -gt 0
            for i in (seq $start (math $start + $count - 1))
                if test "$expanded" = 1; and test $i -eq $ndefault
                    set -a lines (__tcz_thp_ln (__tcz_thp_grouphdr $IW 'More Schemes') $IW $BORDER $RST)
                    continue
                end
                set -l si $i
                if test "$expanded" = 1; and test $i -gt $ndefault
                    set si (math $i - 1)
                end
                set -l idx (math $si + 1)
                set -l selflag 0
                test $focus = list; and test $si -eq $sel; and set selflag 1
                set -l curflag 0
                test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"; and test "$phase" = "$anch_phase"; and set curflag 1
                set -l row (__tcz_thp_row "$pals[$idx]" $toks[$idx] $selflag $curflag)
                if test $selflag -eq 1
                    set row (string replace -a -- "$RST" "$RST$SELBG" "$row")
                    set row "$SELBG$row$RST"
                end
                set -a lines (__tcz_thp_ln "$row" $IW $BORDER $RST)
            end
        end
        # WIN is now derived from the popup's own height (see STATIC/rows above), so
        # it routinely exceeds the list — __tcz_thp_window returns "0 <total>" (fewer
        # than WIN rows) whenever total <= WIN, and the loop above then draws fewer
        # than WIN rows with nothing to fill the rest. Pad with blank framed rows so
        # the frame always ends exactly at the popup's bottom, not short of it.
        set -l winpad (math "$WIN - $count")
        if test $winpad -gt 0
            for i in (seq 1 $winpad)
                set -a lines (__tcz_thp_ln '' $IW $BORDER $RST)
            end
        end
        # ── second list: the current theme and off. Untitled: no word covers both,
        # and the user would rather have none than a bad one. ⇥ moves the cursor here.
        # `current` is lit only while the persisted theme really is what is applied
        # (spec §6: no preview in effect, OR the preview in effect is the current
        # row's own recipe).
        set -l islive 1
        test $previewed -eq 1; and set islive 0
        # A previewed-but-uncommitted seed (b/hexentry, no `a` yet) also diverges
        # from what's persisted, regardless of $previewed — the row it's drawn
        # against (via __tcz_thp_reanchor) already tracks the new seed, so the
        # label would otherwise claim live for a bar that is not actually saved.
        test "$seed" != "$anch_seed"; and set islive 0
        # Previewing the off row IS "the current row's own recipe" when the
        # persisted theme really is off — off has no place/mode/phase to diverge
        # on, so that preview and the current row render identically.
        if test $previewed -eq 1; and test "$anch_scheme" = off; and test $focus = state; and test $sel2 -eq 1
            set islive 1
        end
        set -a lines (__tcz_thp_zsep $IW '' $BORDER $RST)
        set -l curflag2 0
        test $focus = state; and test $sel2 -eq 0; and set curflag2 1
        set -l anchcells (__tcz_thp_band "$legacy")
        test -n "$anchpal"; and set anchcells (__tcz_thp_cells "$anchpal")
        # The state row names the CATALOG ENTRY (e.g. "mono soft"), not the bare
        # relationship (e.g. "mono") — several catalog rows share a relationship,
        # so the row whose whole job is "what do I have" would otherwise be
        # ambiguous about place/mode. Look up the entry whose recipe matches the
        # anchor; fall back to the bare relationship when nothing matches (e.g. a
        # CLI-only config with no catalog row at all, such as
        # `tmux-lives setup theme amber --place cap --mode literal` — amber has a
        # cap row (amber deep) but only at derived mode).
        set -l anchname $anch_scheme
        set -l anchrecipe "$anch_scheme|$anch_place|$anch_mode"
        set -l ari (contains -i -- "$anchrecipe" $recipes)
        test -n "$ari"; and set anchname $toks[$ari]
        set -l currow (__tcz_thp_staterow $IW "$anchcells" "$anchname" current $curflag2 $islive)
        if test $curflag2 -eq 1
            set currow (string replace -a -- "$RST" "$RST$SELBG" "$currow")
            set currow "$SELBG$currow$RST"
        end
        set -a lines (__tcz_thp_ln "$currow" $IW $BORDER $RST)
        set -l offflag 0
        test $focus = state; and test $sel2 -eq 1; and set offflag 1
        set -l offrow (__tcz_thp_staterow $IW (__tcz_thp_band "$legacy") 'legacy look' off $offflag 0)
        if test $offflag -eq 1
            set offrow (string replace -a -- "$RST" "$RST$SELBG" "$offrow")
            set offrow "$SELBG$offrow$RST"
        end
        set -a lines (__tcz_thp_ln "$offrow" $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW '' $BORDER $RST)
        for lline in (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake '⇥' current/off  a apply '⏎' save esc close)
            set -a lines (__tcz_thp_ln "$lline" $IW $BORDER $RST)
        end
        set -a lines (__tcz_thp_ln " $MUTED$note$RST" $IW $BORDER $RST)
        set -a lines $BORDER"╰"(string repeat -n $IW ─)"╯"$RST
        # Synchronized update (DECSET 2026): commit the whole frame atomically so a
        # redraw never flickers mid-paint (the __tcz_popup_draw pattern; unsupported
        # terminals ignore the private mode harmlessly).
        printf '\e[?2026h\e[H'
        test (count $lines) -gt 1; and printf '%s\e[K\n' $lines[1..-2]
        printf '%s\e[K' $lines[-1]
        printf '\e[J\e[?2026l'
        set -l tok
        if test -n "$flashfield"; or test "$seeddirty" = 1
            # flash active and/or a batch reload is owed: wait up to ~0.5s;
            # on timeout clear the flash and/or run the owed batch. A real
            # key is handled exactly like the blocking read. seeddirty must
            # be checked here TOO (not just flashfield) — picker-seed-section
            # Task 6 fix round 1: m/z/tab clear flashfield on their own
            # unrelated keypresses, and if this branch were gated on
            # flashfield alone, clearing it would also stop the timed poll
            # from ever running again, so a batch left owed after one of
            # those arms would never fire — the picker falls to a plain
            # blocking read instead and the deferred catch-up is silently
            # lost until the next seed edit (or never, if none comes).
            stty min 0 time 5 2>/dev/null
            set tok (__tcz_popup_readkey timeout)
            stty min 1 time 0 2>/dev/null
            if test "$tok" = timeout
                set flashfield ''
                if test "$seeddirty" = 1
                    # picker-seed-section Task 6: input has settled — no key
                    # arrived within ~0.5s of the last live channel edit.
                    # Batch reload the remaining visible strips (schemes
                    # list) now, plus reanchor so the current row's band
                    # tracks the new seed too (its own comment explains why:
                    # nothing else recomputes it). Cheap even when this flash
                    # came from something else (a hexentry/sliders commit
                    # already reloaded synchronously) — reload's cache is
                    # keyed on the seed, so an unchanged seed hits cache
                    # instead of paying the 310-800ms batch again. Gated on
                    # seeddirty, not flashfield: see its own declaration
                    # comment above for why the two must stay independent.
                    __tcz_thp_reload
                    __tcz_thp_reanchor
                    set seeddirty 0
                end
                continue
            end
        else
            set tok (__tcz_popup_readkey)
        end
        switch $tok
            case up down pgup pgdn
                if test "$editing" = 1
                    # Edit mode: ↑↓ pick the R/G/B channel; there is no list to
                    # page here, so pgup/pgdn are ignored while editing.
                    switch $tok
                        case up
                            test $chan -gt 1; and set chan (math $chan - 1)
                        case down
                            test $chan -lt 3; and set chan (math $chan + 1)
                    end
                else
                    # Drain, then move ONE row. The drain is what prevents the original
                    # defect — an unbounded redraw backlog that kept scrolling for seconds
                    # after release — but it must not COUNT what it swallows. Re-assert
                    # non-blocking INSIDE the loop: readkey's CSI branch leaves the tty
                    # blocking on return, and a drain read after it hangs (hit for real once).
                    set -l steps 0
                    switch $tok
                        case up;   set steps -1
                        case down; set steps 1
                        case pgup; set steps (math "0 - $WIN")
                        case pgdn; set steps $WIN
                    end
                    set -l gap 0
                    while true
                        stty min 0 time $gap 2>/dev/null
                        set -l k2 (__tcz_popup_readkey)
                        switch "$k2"
                            # SWALLOW queued autorepeats without counting them. Summing the
                            # burst (the 2026-07-29 form) moved many rows per redraw, so the
                            # intermediate positions were never drawn and release landed on
                            # the accumulated total rather than the last row you saw. One row
                            # per render cycle instead: a held key scrolls at whatever rate
                            # the terminal can actually paint, and release stops where it is.
                            # NB do not escalate `gap` here: the loop only breaks on a POLL
                            # TIMEOUT, so a gap=1 (~100ms) wait never times out while
                            # autorepeat keeps delivering faster than that — no redraw, no
                            # movement, until release, when exactly one row applies (measured:
                            # 2 rows moved in 2s of holding, at a 61ms redraw cost). A gap=0
                            # poll still drains whatever the terminal has already buffered, so
                            # the anti-backlog property survives without ever blocking on it.
                            case up down
                            # pages DO coalesce — discrete, not autorepeated in practice
                            case pgup; set steps (math "$steps - $WIN"); set gap 1
                            case pgdn; set steps (math "$steps + $WIN"); set gap 1
                            case '*';  break
                        end
                    end
                    stty min 1 time 0 2>/dev/null
                    if test $focus = state
                        # the second list is two rows; clamp within it
                        set sel2 (math "$sel2 + $steps")
                        test $sel2 -lt 0; and set sel2 0
                        test $sel2 -gt 1; and set sel2 1
                    else
                        set -l dir down
                        test $steps -lt 0; and set dir up
                        for _i in (seq (math "abs($steps)"))
                            set sel (__tcz_thp_vismap $sel $n $dir)
                        end
                    end
                end
            # ←→ move the seed's selected R/G/B channel, but ONLY while editing —
            # outside edit mode they stay unbound, same as they were when phase
            # (their old occupant) was hidden: a different seed is the better
            # lever than a knob nobody reaches for. Coalesced the same way the
            # retired standalone sliders screen did it — a burst of autorepeat
            # collapses to one net delta rather than one delta per byte.
            case left right
                if test "$editing" = 1
                    set -l delta -8
                    test "$tok" = right; and set delta 8
                    while true
                        stty min 0 time 0 2>/dev/null
                        set -l k2 (__tcz_popup_readkey)
                        switch "$k2"
                            case left;  set delta (math "$delta - 8")
                            case right; set delta (math "$delta + 8")
                            case '*';   break
                        end
                    end
                    stty min 1 time 0 2>/dev/null
                    set -l names seedr seedg seedb
                    set -l vn $names[$chan]
                    set -l cur $$vn
                    set cur (math "$cur + $delta")
                    test $cur -lt 0; and set cur 0
                    test $cur -gt 255; and set cur 255
                    set $vn $cur
                    set seed (printf '#%02x%02x%02x' $seedr $seedg $seedb)
                    # picker-seed-section Task 6: recompute ONLY the cursor's own
                    # scheme row here (~40ms) — a full batch reload across the
                    # visible strips is 310-800ms (14/35 rows), which a held key
                    # cannot afford per step. The seed is passed as a variable
                    # (never a literal), matching the engine call's other sites —
                    # a source-text guard elsewhere counts them and is sensitive
                    # to exactly this shape, so do not spell that shape out here
                    # even in prose. The seed zone and preview bar need no
                    # separate repaint call: both already re-derive from $seed
                    # on every redraw (see the draw loop above), same as the
                    # cursor row's own $curpal lookup does from $pals below —
                    # updating pals/fgs/tabsfgs here is exactly what that
                    # lookup reads on the very next frame. seeddirty (not
                    # flashfield) is what defers the expensive batch (reload +
                    # reanchor) to the settle block below — flashfield is a
                    # separate, purely cosmetic flag that other arms (m/z/tab)
                    # clear on their own unrelated keypresses; seeddirty
                    # survives that and is cleared only once the batch it
                    # tracks actually runs, so a held key never queues more
                    # than one cheap recompute per step and the deferred
                    # catch-up cannot be silently cancelled by an intervening
                    # keypress.
                    set -l pi (math $sel + 1)
                    set -l rc (string split '|' -- $recipes[$pi])
                    set -l p (__tmux_lives_theme_palette $seed $rc[1] $rc[2] $rc[3] $phase)
                    if test (count $p) -eq 7
                        set pals[$pi] (string join ' ' $p)
                        set fgs[$pi] (__tmux_lives_contrast_fg "$p[6]")
                        set tabsfgs[$pi] (__tmux_lives_contrast_fg "$p[3]")
                    end
                    set flashfield seed
                    set seeddirty 1
                end
            case m
                # expand/collapse the catalog: 14 curated rows <-> all 35.
                # Reload FIRST so $n reflects the NEW list length before the
                # sel clamp below runs (an un-reloaded $n would clamp against
                # the stale count). Place/mode/reset (p/P/m-M/r) are RETIRED —
                # this m is a different key (expand), not the old mode toggle.
                # Remember WHICH scheme the cursor is on, not its index: expanding
                # interleaves the hidden rows between the curated ones, so a kept
                # index lands on an unrelated scheme and you lose your place while
                # browsing. Re-find the same row by name in the new list instead.
                set -l keep ''
                if test $sel -lt $n
                    # Compute the index into a VAR first. Inlining an arithmetic
                    # expression inside a quoted list subscript makes fish reject it
                    # with "Invalid index value" and spray a stack trace into the
                    # popup; a guard test greps for that shape, and it matches
                    # comments too — so do not spell the shape out even in prose.
                    set -l ki (math "$sel + 1")
                    set keep "$toks[$ki]"
                end
                test "$expanded" = 1; and set expanded 0; or set expanded 1
                __tcz_thp_reload
                set n (count $toks)
                if test -n "$keep"
                    set -l found (contains -i -- "$keep" $toks)
                    # collapsing can drop the row entirely (it was a hidden one) —
                    # fall back to the clamp below rather than guessing a neighbour.
                    test -n "$found"; and set sel (math $found - 1)
                end
                set -l lastrow (math $n - 1)
                test $lastrow -lt 0; and set lastrow 0
                test $sel -gt $lastrow; and set sel $lastrow
                set flashfield ''
            case b
                # Toggles the seedzone between readouts and its R/G/B sliders —
                # ignored while focus is on the second list, which has no seed
                # of its own to edit. Entering captures $editseed so esc (below)
                # has this edit session's starting point to revert to; leaving
                # via b needs no such capture — every ←→ move already commits
                # straight into $seed (see case left right), so there is
                # nothing left to "keep".
                if test $focus != state
                    if test "$editing" = 1
                        set editing 0
                    else
                        set editing 1
                        set chan 1
                        set editseed $seed
                    end
                end
            case t
                # A detour within edit mode, not a separate destination: on
                # ⏎/esc __tcz_thp_hexentry just returns here, and neither it
                # nor this arm touches $editing, so it is still 1 afterward —
                # the next redraw shows the sliders again, seed and all (the
                # draw section re-derives seedr/g/b from $seed every frame,
                # so a hexentry commit is picked up with no extra plumbing).
                # Idle (editing=0) it's a no-op, symmetric with b's own gate.
                test "$editing" = 1; and __tcz_thp_hexentry
            case z
                # shake: land on a random row across the FULL catalog. RELOAD
                # BEFORE ROLLING so the bound is the real expanded size — the
                # roll used to be a hardcoded upper bound taken before the
                # reload, which silently stopped covering the tail when the
                # catalog grew (9 rows became unreachable). Never reintroduce
                # a literal bound here — a guard test greps for one, and it
                # matches comments too, so do not spell one out even in prose. Place/mode are not knobs to
                # reroll — they're baked into each row's RECIPE (case a/enter
                # derive them from $recipes) — so shake only needs an index.
                # Capture random into a var FIRST: fish performs NO command
                # substitution inside double-quoted math, so writing the roll
                # directly as a math() argument would hand math the LITERAL
                # unexpanded text (stderr into the popup) and vanish the
                # assignment downstream (2026-07-20 live bug).
                set expanded 1
                __tcz_thp_reload
                set n (count $toks)
                set -l zi (random 0 (math $n - 1))
                set sel $zi
                set focus list
                set flashfield ''
            case tab
                # move between the two lists. `c` is retired: a key meaning "current"
                # that lands on current, from which you arrow to off, promises one
                # thing and does another. ⇥ carries no such claim and toggles back.
                # Ignored while editing (Task 4 review Minor, folded in here): the
                # second list has no seed of its own, and letting ⇥ through moved
                # focus to `state` while `editing` still owned ↑↓/←→ — the second
                # list's cursor drew as selected but arrows kept moving the RGB
                # channel, ⏎ exited edit mode instead of acting on the state row,
                # and b (itself focus-gated) could no longer get back. One key
                # (b) recovers it, but the fix is one line, same gate as b's own.
                if test "$editing" != 1
                    test $focus = list; and set focus state; or set focus list
                    set flashfield ''
                end
            # previewed: 0 none, 1 a LISTED scheme, 2 the current row. The distinction
            # matters because previewing the current row still leaves the persisted
            # theme on the bar — so `current` stays lit. It is never reset: `cancel`
            # needs it to know a revert is owed.
            case a
                if test $focus = state
                    if test $sel2 -eq 0
                        fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $anch_scheme $anch_place $anch_mode $anch_phase >/dev/null 2>&1
                        set -l tabhex (__tcz_tab_color '')
                        test -n "$tabhex"; and __tcz_recolor "$tabhex"
                        set previewed 2
                        set note "● previewing $anch_scheme (current) — ⏎ save · esc revert"
                    else
                        fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" off bar derived $phase >/dev/null 2>&1
                        set -l tabhex (__tcz_tab_color '')
                        test -n "$tabhex"; and __tcz_recolor "$tabhex"
                        set previewed 1
                        set note "● previewing off — ⏎ save · esc revert"
                    end
                else
                    set -l pi (math $sel + 1)
                    set -l rc (string split '|' -- $recipes[$pi])
                    set -l rel $rc[1]
                    set -l rplace $rc[2]
                    set -l rmode $rc[3]
                    fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $rel $rplace $rmode $phase >/dev/null 2>&1
                    set -l tabhex (__tcz_tab_color '')
                    test -n "$tabhex"; and __tcz_recolor "$tabhex"
                    set previewed 1
                    set note "● previewing $rel — ⏎ save · esc revert"
                end
            case enter
                if test "$editing" = 1
                    # ⏎ while editing keeps the change and leaves edit mode —
                    # nothing more to do: every ←→ move already committed
                    # straight into $seed, so there is no staged value to
                    # apply here (the esc/q arm just below IS different — it
                    # does have something to undo).
                    set editing 0
                else
                    if test $focus = state
                        if test $sel2 -eq 0
                            set apply $anch_scheme
                            set phase $anch_phase
                            set place $anch_place
                            set mode $anch_mode
                        else
                            set apply off
                        end
                    else
                        set -l pi (math $sel + 1)
                        set -l rc (string split '|' -- $recipes[$pi])
                        set apply $rc[1]
                        set place $rc[2]
                        set mode $rc[3]
                    end
                    break
                end
            case cancel
                if test "$editing" = 1
                    # BEGIN edit-esc
                    # Leaves edit mode only — the picker stays open. This arm
                    # never exits the read loop: esc while editing reverts the
                    # seed to what it was when edit mode was entered, it does
                    # not close the picker (contrast the plain esc/q below,
                    # which does exit and reverts all the way to $anch_seed).
                    set seed $editseed
                    set editing 0
                    set seeddirty 1
                    set note ''
                    # END edit-esc
                else
                    # Restore BOTH. Restoring the theme alone is what made this look
                    # broken: every role derives from the seed, so a correct theme
                    # rendered against a changed seed still is not what you started with.
                    if test $previewed -ne 0; or test "$seed" != "$anch_seed"
                        fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live' "$anch_seed" >/dev/null 2>&1
                        set -l tabhex (__tcz_tab_color '')
                        test -n "$tabhex"; and __tcz_recolor "$tabhex"
                    end
                    break
                end
        end
    end
    functions -e __tcz_thp_cleanup
    functions -e __tcz_thp_init
    functions -e __tcz_thp_reload
    functions -e __tcz_thp_reanchor
    functions -e __tcz_thp_hexentry
    functions -e __tcz_thp_sliders
    set -e __tcz_thp_saved
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    # Commit the seed only if it actually moved — the CLI call below re-renders
    # the fragment, and every fragment write re-sources status-right.
    if test -n "$apply"; and test "$seed" != "$anch_seed"
        fish -c 'tmux-lives setup color $argv[1]' "$seed" >/dev/null 2>&1
    end
    if test "$apply" = off
        fish -c 'tmux-lives setup theme off' >/dev/null 2>&1
    else if test -n "$apply"
        fish -c 'tmux-lives setup theme $argv[1] --place $argv[2] --mode $argv[3] --phase $argv[4]' "$apply" "$place" "$mode" "$phase" >/dev/null 2>&1
    end
    return 0
end

function __tcz_theme --argument-names role --description 'tl theme palette -> truecolor SGR for a named role (brand/border/title/key/muted/value/mark/flash/sel-bg/sel-fg/reset)'
    switch $role
        case brand;  printf '\e[38;2;255;138;31m'
        case border; printf '\e[38;2;168;106;44m'
        case key;    printf '\e[38;2;245;207;138m'
        case muted;  printf '\e[38;2;154;138;114m'
        # section-separator titles: the brand orange pulled down ~18%. Distinct from
        # `border` (which would blend the label into the rule it sits on) and from
        # `brand` (which the top border's own `theme` title already uses).
        case title;  printf '\e[38;2;210;120;42m'
        case value;  printf '\e[38;2;111;199;184m'
        # mark: a TRUE neutral grey for the active-column rule. Intentionally neither `key`
        # (tan — the ▐ selector; sharing it read as a colour collision) nor `muted` (a WARM
        # tan-grey). The rule sits inside the swatch strip, so it must recede from the
        # colour story rather than join it; neutral grey also stays legible both ways —
        # darker than a light swatch, lighter than a dark one.
        case mark;   printf '\e[38;2;138;138;138m'
        # change-flash blue (picker configuration zone; 2026-07-17 UX request)
        case flash;  printf '\e[38;2;95;168;232m'
        case sel-bg; printf '\e[48;2;25;25;19m'     # near-black band: must read as CHROME, never as one of the scheme colors beside it (2026-07-17 picker feedback)
        case sel-fg; printf '\e[38;2;242;239;233m'
        case reset;  printf '\e[0m'
    end
end

function __tcz_claim --description 'claim <pane> <raw-name> <cwd>: instant claude rename (preexec)'
    test -n "$argv[1]"; or return 0
    set -l cur (tmux display-message -pt "$argv[1]" '#{session_name}' 2>/dev/null)
    test -n "$cur"; or return 0
    __tcz_owned "$cur"; or return 0
    set -l base $argv[2]
    test -n "$base"; or set base claude-(path basename -- "$argv[3]")
    set -l desired (__tcz_slugify "$base")
    test "$desired" = "$cur"; and return 0
    set -l others
    for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
        test "$s" != "$cur"; and set -a others $s
    end
    set desired (__tcz_unique $desired $others)
    tmux rename-session -t "=$cur" -- "$desired" 2>/dev/null; or return 0
    # stamp + one silent retry (a lost stamp would freeze the name as hand-named)
    set -l stamptgt (__tcz_session_target "$desired")
    tmux set-option -t "$stamptgt" @tmux_auto_name "$desired" 2>/dev/null
    or tmux set-option -t "$stamptgt" @tmux_auto_name "$desired" 2>/dev/null
end

function __tcz_tab_color --argument-names fallback --description 'effective ShellFish tab colour: the live tabs-role @option (@tmux_lives_tabs_color, set by the themed fragment) when non-empty, else <fallback> (the baked seed / legacy)'
    set -l eff (tmux show -gv @tmux_lives_tabs_color 2>/dev/null)
    test -n "$eff"; and echo $eff; or echo $fallback
end

function __tcz_on_attach --argument-names pid tty color --description 'on-attach <client_pid> <client_tty> [color]: ShellFish/iTerm2 -> set bar/tab color + retitle; else re-apply the non-ShellFish baseline (iTerm2 gets the emissions but, like ShellFish, must NOT trigger the baseline re-source).'
    switch (__tcz_client_terminal $pid)
        case shellfish
            set -l eff (__tcz_tab_color "$color")
            __tcz_emit_barcolor $tty $eff
            __tcz_emit_set $tty color $eff
            __tcz_retitle
        case iterm2
            set -l eff (__tcz_tab_color "$color")
            __tcz_emit_itermtab $tty $eff
            __tcz_emit_set $tty color $eff
            __tcz_retitle
        case '*'
            # Baseline path default mirrors __tmux_lives_baseline_path in conf.d/tmux-lives-install.fish — keep in sync.
            set -l baseline (set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf")
            test -e $baseline; and tmux source-file $baseline 2>/dev/null
    end
    return 0
end

function __tcz_recolor --argument-names color mode --description 'emit the ShellFish bar-color / iTerm2 tab-color OSC to attached clients of either kind. mode=dedup emits only when the color changed for that tty; else force. Updates the per-tty cache on emit (the cache stores the resolved color, terminal-agnostic — shared by both kinds).'
    set color (__tcz_tab_color "$color")
    test -n "$color"; or return 0
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        test -n "$tty"; or continue
        switch (__tcz_client_terminal $pid)
            case shellfish
                set -l cached (__tcz_emit_get $tty color)
                test "$mode" = dedup; and test "$color" = "$cached"; and continue
                __tcz_emit_barcolor $tty $color
                __tcz_emit_set $tty color $color
            case iterm2
                set -l cached (__tcz_emit_get $tty color)
                test "$mode" = dedup; and test "$color" = "$cached"; and continue
                __tcz_emit_itermtab $tty $color
                __tcz_emit_set $tty color $color
            case '*'
                continue
        end
    end
end

function __tcz_heal_due --argument-names now --description 'true (rc0) when the color-only backstop is due: @tmux_lives_heal_interval>0 and now>=@tmux_lives_heal_at (unset=due); advances @tmux_lives_heal_at to now+interval. interval 0 (or unset->120) gates it.'
    set -l interval (tmux show -gv @tmux_lives_heal_interval 2>/dev/null)
    test -n "$interval"; or set interval 120
    test "$interval" -gt 0 2>/dev/null; or return 1
    set -l at (tmux show -gv @tmux_lives_heal_at 2>/dev/null)
    if test -z "$at"; or test "$now" -ge "$at" 2>/dev/null
        tmux set -g @tmux_lives_heal_at (math $now + $interval) 2>/dev/null
        return 0
    end
    return 1
end

function __tcz_emit_title --argument-names tty title --description 'write the OSC 2 title escape for <title> to <tty> (non-passthrough; client-tty level)'
    test -n "$title"; or return 0
    printf '\033]2;%s\a' "$title" > $tty
end

function __tcz_session_has_claude --argument-names session --description 'true if any pane in the session runs claude'
    set -l TAB (printf '\t')
    for line in (tmux list-panes -s -t (__tcz_pane_target "$session") -F "#{pane_current_command}$TAB#{pane_pid}" 2>/dev/null)
        set -l p (string split $TAB -- $line)
        __tcz_pane_is_claude "$p[1]" "$p[2]"; and return 0
    end
    return 1
end

function __tcz_set_claude_opt --argument-names session --description 'set @tmux_lives_claude on <session> = its claude --name, else the pane title via __tcz_title_name (empty if no claude pane / unparseable title). Options are targeted via __tcz_session_target (a bare-number -t would hit the CURRENT session).'
    test -n "$session"; or return
    set -l TAB (printf '\t')
    set -l name ''
    # A purely numeric session name is unreliable in EVERY -t, not just options: with
    # sessions "0" and "neighbour", `list-panes -t "=0"` returns NEIGHBOUR's panes (the
    # "=" exact prefix does not rescue it) while `-t $id` is correct. So resolve once and
    # use the id for both lookups; a non-numeric name keeps the exact-match "=" it needs
    # for panes, and the bare form options require.
    set -l tgt (__tcz_session_target "$session")
    set -l ptgt (__tcz_pane_target "$session")
    for line in (tmux list-panes -s -t "$ptgt" -F "#{pane_current_command}$TAB#{pane_pid}$TAB#{pane_title}" 2>/dev/null)
        # -m 2: the title is last and may contain tabs.
        set -l parts (string split -m 2 $TAB -- $line)
        test "$parts[1]" = claude; or continue
        set name (__tcz_cmdline_name $parts[2])
        # claude is usually started WITHOUT --name (e.g. `claude -c`), so the cmdline
        # yields nothing and the readable name lives in the pane title instead —
        # the same source __tcz_categorize already slugifies for the session name.
        # Without this the option stayed empty and the status-bar centre fell back to
        # session_name: a slug (spaces -> dashes), and a frozen one for unstamped
        # restored breadcrumbs. --name still wins: a flag beats a volatile title.
        if test -z "$name"; and test (count $parts) -ge 3
            set name (__tcz_title_name "$parts[3]")
        end
        test -n "$name"; and break
    end
    # Dedup: only write when the value actually CHANGED. An unconditional set every tick /
    # fish_postexec forces a redraw of the bar (@tmux_lives_claude is status-read), which makes
    # tmux re-emit the cursor style → ShellFish cursor flicker (see [[shellfish-cursor-flicker]]).
    # Capture+quote the current value (empty -> zero-word subst would throw; the empty-cache gotcha).
    # $tgt (resolved above) is ID-safe: a bare-number -t hits the CURRENT session, so a
    # numeric session's identity used to be read from, and written onto, another session.
    set -l cur (tmux show-option -qv -t "$tgt" @tmux_lives_claude 2>/dev/null)
    test "$name" = "$cur"; and return
    tmux set-option -t "$tgt" @tmux_lives_claude "$name" 2>/dev/null
end

function __tcz_session_title --argument-names session --description 'session -> "<host>: <dir>[ (C)]" (active-pane dir; session-wide claude)'
    test -n "$session"; or return 0
    # NB: `display-message -t "=$session" '#{pane_current_path}'` returns EMPTY in tmux
    # 3.3a (the =exact-target quirk — see [[tmux-target-quirks]]); list-panes honors = AND
    # resolves the active pane's path. Filter to the active pane of the session's window.
    set -l path (tmux list-panes -t (__tcz_pane_target "$session") -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | string match -rv '^$')
    set -l claude 0
    __tcz_session_has_claude $session; and set claude 1
    set -l name (tmux show-option -qv -t (__tcz_session_target "$session") @tmux_lives_name 2>/dev/null)
    test -n "$name"; or set name (__tcz_dir_display $path)
    __tcz_format_title (__tcz_hostname) "$name" $claude
end

function __tcz_retitle --argument-names mode --description 'emit each attached ShellFish/iTerm2 client its own OSC 2 title (title emission is identical for both terminal kinds — only the color-emit call differs, in __tcz_recolor/__tcz_on_attach). mode=dedup emits only when the title changed for that tty; else force. Updates the per-tty cache on emit.'
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}$TAB#{client_session}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        set -l session $parts[3]
        test -n "$tty"; or continue
        switch (__tcz_client_terminal $pid)
            case shellfish iterm2
                set -l title (__tcz_session_title $session)
                test -n "$title"; or continue
                set -l cached (__tcz_emit_get $tty title)
                test "$mode" = dedup; and test "$title" = "$cached"; and continue
                __tcz_emit_title $tty $title
                __tcz_emit_set $tty title $title
            case '*'
                continue
        end
    end
end

function __tcz_scratch_pane --description 'echo the marked scratch pane id in the current window (empty if none)'
    tmux list-panes -F '#{?#{==:#{@tmux_lives_scratch},1},#{pane_id},}' 2>/dev/null | string match -rv '^$'
end

function __tcz_scratch --description 'toggle a marked scratch shell pane beside the active pane (create+focus, or refocus origin + kill)'
    set -l existing (__tcz_scratch_pane)
    if test -n "$existing[1]"
        set -l origin (tmux show-options -wqv @tmux_lives_scratch_origin 2>/dev/null)
        test -n "$origin"; and tmux select-pane -t "$origin" 2>/dev/null
        tmux kill-pane -t "$existing[1]" 2>/dev/null
        tmux set-window-option -qu @tmux_lives_scratch_origin 2>/dev/null
        return 0
    end
    set -l origin (tmux list-panes -F '#{?#{pane_active},#{pane_id},}' 2>/dev/null | string match -rv '^$')
    test -n "$origin[1]"; and tmux set-window-option @tmux_lives_scratch_origin "$origin[1]" 2>/dev/null
    tmux split-window -h -p 45 2>/dev/null
    tmux set -p @tmux_lives_scratch 1 2>/dev/null
    return 0
end

function __tcz_write_state --description 'persist the live status-position + visibility to the state file (seam: tmux_lives_state_file; default mirrors __tmux_lives_state_path — keep in sync)'
    set -l pos (tmux show -gv status-position 2>/dev/null); test -n "$pos"; or set pos bottom
    set -l vis (tmux show -gv status 2>/dev/null); test -n "$vis"; or set vis on
    set -l state (set -q tmux_lives_state_file; and echo $tmux_lives_state_file; or echo "$HOME/.config/tmux/tmux-lives-state.conf")
    mkdir -p (path dirname $state) 2>/dev/null
    printf 'set -g status-position %s\nset -g status %s\n' $pos $vis >$state
end
function __tcz_status_pos_toggle --description 'flip status-position top<->bottom, apply live + persist'
    set -l new bottom; test (tmux show -gv status-position 2>/dev/null) = bottom; and set new top
    tmux set -g status-position $new 2>/dev/null
    __tcz_write_state
end
function __tcz_status_vis_toggle --description 'flip status on<->off, apply live + persist'
    set -l new off; test (tmux show -gv status 2>/dev/null) = off; and set new on
    tmux set -g status $new 2>/dev/null
    __tcz_write_state
end

function __tcz_scratch_orient --argument-names dir --description 'recreate the scratch pane with a new orientation (h=side-by-side, w=stacked)'
    set -l p (__tcz_scratch_pane)
    test -n "$p[1]"; or return 0
    set -l flag -h; test "$dir" = w; and set flag -v
    tmux kill-pane -t "$p[1]" 2>/dev/null
    tmux split-window $flag -p 45 2>/dev/null
    tmux set -p @tmux_lives_scratch 1 2>/dev/null
    return 0
end

function __tcz_scratch_resize --argument-names dir --description 'resize the marked scratch pane (L/R = 4 cols, U/D = 2 rows)'
    set -l p (__tcz_scratch_pane)
    test -n "$p[1]"; or return 0
    switch "$dir"
        case L; tmux resize-pane -t "$p[1]" -L 4 2>/dev/null
        case R; tmux resize-pane -t "$p[1]" -R 4 2>/dev/null
        case U; tmux resize-pane -t "$p[1]" -U 2 2>/dev/null
        case D; tmux resize-pane -t "$p[1]" -D 2 2>/dev/null
    end
end

function __tcz_resize_enter --argument-names client --description 'enter the native scratch resize key-table if a scratch exists; else nudge'
    set -l p (__tcz_scratch_pane)
    if test -z "$p[1]"
        tmux display-message 'tmux-lives: no scratch pane — press the scratch key to create one' 2>/dev/null
        return 0
    end
    test -n "$client"; and tmux switch-client -c "$client" -T tmuxlives-resize 2>/dev/null; or tmux switch-client -T tmuxlives-resize 2>/dev/null
    tmux display-message -d 0 'scratch:  ←→↑↓ resize · h/w split · x close · esc done' 2>/dev/null
end

function __tcz_main
    switch "$argv[1]"
        case categorize
            __tcz_categorize
        case tick
            __tcz_categorize >/dev/null 2>&1
            test -n "$argv[2]"; and __tcz_recolor $argv[2] dedup
            __tcz_retitle dedup
            test -n "$argv[2]"; and __tcz_heal_due (date +%s); and __tcz_recolor $argv[2]
            return 0
        case overview
            __tcz_overview
        case menu
            __tcz_menu
        case open-switcher
            __tcz_open_switcher $argv[2..]
        case popup
            __tcz_popup $argv[2..]
        case theme-picker
            __tcz_theme_picker $argv[2..]
        case scratch
            __tcz_scratch $argv[2..]
        case scratch-resize
            __tcz_scratch_resize $argv[2]
        case scratch-orient
            __tcz_scratch_orient $argv[2]
        case scratch-kill
            # kill-only: only toggle when a scratch actually exists, so a
            # stray/unguarded call can never CREATE one (guarded pane-id form).
            set -l p (__tcz_scratch_pane); test -n "$p[1]"; and __tcz_scratch
        case resize-enter
            __tcz_resize_enter $argv[2..]
        case status-pos-toggle
            __tcz_status_pos_toggle
        case status-vis-toggle
            __tcz_status_vis_toggle
        case modal
            __tcz_modal $argv[2..]
        case modal-menu
            __tcz_modal_menu $argv[2..]
        case recolor
            __tcz_recolor $argv[2..]
        case retitle
            __tcz_retitle
        case claim
            __tcz_claim $argv[2..]
        case ghosts
            __tcz_ghosts $argv[2]
        case switch
            __tcz_switch $argv[2..]
        case commandeer
            __tcz_commandeer $argv[2..]
        case on-attach
            __tcz_on_attach $argv[2..]
        case slug
            __tcz_slugify $argv[2..]
        case new-general
            __tcz_new_general
        case host-kind
            __tcz_host_kind
        case status-format
            __tcz_status_format
        case status-right-install
            __tcz_status_right_install "$argv[2]"
        case '*'
            echo "usage: tmux-categorize.fish categorize|tick|overview|menu|open-switcher|popup|theme-picker|modal|modal-menu|scratch|scratch-resize|scratch-orient|scratch-kill|resize-enter|status-pos-toggle|status-vis-toggle|recolor|retitle|claim|ghosts|switch|commandeer|on-attach|slug|new-general|host-kind|status-format|status-right-install" >&2
            return 1
    end
end

# Script entrypoint. This file lives in functions/, so fisher SOURCES it on
# install/update — a top-level `return` here would propagate out of fisher's own
# function and abort the install (files copied, but no events emitted and no
# summary). So gate the dispatcher with a single `if` and NO top-level return:
# run only when invoked as a script (args present) and not under test.
if not set -q tmux_categorize_test; and test (count $argv) -gt 0
    __tcz_main $argv
end
