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

function __tcz_client_is_shellfish --argument-names pid --description 'true if the client process environment contains LC_TERMINAL=ShellFish'
    # Substring match: works for Linux per-line environ AND macOS single-line `ps eww`.
    string match -q '*LC_TERMINAL=ShellFish*' -- (__tcz_pid_environ $pid)
end

function __tcz_emit_barcolor --argument-names tty color --description 'write the ShellFish setbarcolor OSC for <color> to <tty> (non-passthrough; client-tty level)'
    test -n "$color"; or return 0
    printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' "$color" | base64 | string join '') > $tty
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
    # A pid could be recycled between pgrep and the comm read; worst case is a harmless miss.
    for pid in $argv[1] (pgrep -P $argv[1] 2>/dev/null)
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
    for pid in $argv[2] (pgrep -P $argv[2] 2>/dev/null)
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
        set -l claimed (tmux show-option -qv -t "$cur" @tmux_lives_name 2>/dev/null)
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
        tmux set-option -t "$desired" @tmux_auto_name "$desired" 2>/dev/null
        or tmux set-option -t "$desired" @tmux_auto_name "$desired" 2>/dev/null
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

function __tcz_switch --argument-names session client --description 'switch <session> <client> [--take]: ghost-detach, then switch the choosing client; --take detaches all other clients first'
    test -n "$session"; or return 0
    __tcz_ghosts "$session"
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
        set -l cmds (tmux list-panes -s -t "=$f[3]" -F '#{pane_current_command}' 2>/dev/null)
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
    tmux capture-pane -e -p -t "$session" 2>/dev/null | __tcz_popup_clip $w $h
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

function __tcz_popup_readkey --argument-names mode --description 'read one keystroke -> up|down|left|right|v|w|V|s|S|e|E|d|D|o|O|a|r|b|enter|cancel|kill|timeout|other; with mode=timeout an empty read returns timeout instead of cancel'
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
        case 64; echo d; return                      # d (theme-picker: cycle contrast)
        case 61; echo a; return                      # a (theme-picker: apply preview)
        case 6f; echo o; return                      # o (theme-picker: rotate placement)
        case 72; echo r; return                      # r (theme-picker: reset knobs)
        case 71; echo cancel; return                # q
        case 78; echo kill; return                  # x
        case 0d 0a; echo enter; return              # CR / LF
        case 56; echo V; return                      # V (theme-picker: vividness backward)
        case 53; echo S; return                      # S (theme-picker: shape toggle)
        case 45; echo E; return                      # E (theme-picker: ease toggle)
        case 44; echo D; return                      # D (theme-picker: contrast backward)
        case 4f; echo O; return                      # O (theme-picker: rotate backward)
    end
    if test "$b" = 1b                                # ESC
        # bare ESC vs CSI (\e[…) / SS3 (\eO…) arrow: non-blocking follow-read
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
                case 41; echo up; return             # A (up)
                case 42; echo down; return           # B (down)
                case 43; echo right; return          # C (right)
                case 44; echo left; return           # D (left)
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
            tmux run-shell -b "tmux display-popup -B -E -w 52 -h 26 -- fish --no-config $__tcz_self theme-picker '$client'" 2>/dev/null
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
function __tcz_thp_row --argument-names hexes name selected --description 'pure: one scheme row = marker(1) + 7×2-col gradient strip(14) + space + name; <hexes> space-joined; non-hex cells degrade to blank gaps'
    set -l cells ''
    for hex in (string split ' ' -- "$hexes")
        set -l bg (__tcz_thp_bg "$hex")
        if test -n "$bg"
            set cells "$cells$bg  "(printf '\e[0m')
        else
            set cells "$cells  "
        end
    end
    set -l marker ' '
    set -l namecol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set namecol (__tcz_theme sel-fg)(printf '\e[1m')
    end
    printf '%s%s %s%s%s' "$marker" "$cells" "$namecol" "$name" (__tcz_theme reset)
end
function __tcz_thp_off_row --argument-names barhex selected --description 'pure: the "off — legacy look" row; one 14-col derived-bg band where the strip sits'
    set -l bg (__tcz_thp_bg "$barhex")
    set -l band '              '
    test -n "$bg"; and set band "$bg              "(printf '\e[0m')
    set -l marker ' '
    set -l namecol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set namecol (__tcz_theme sel-fg)(printf '\e[1m')
    end
    printf '%s%s %s%s%s' "$marker" "$band" "$namecol" 'off — legacy look' (__tcz_theme reset)
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
    set -l coral (__tcz_thp_fg '#D97757')
    set -l left "$capbg$capfgS $glyph $host $R$barbg$capfgc$slR$R"
    set -l leftv " x $host x"   # glyph + slant are 1 col each
    set -l win "$barbg $coral""claude$sepfg • $winfg""edit$R"
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
function __tcz_thp_zsep --argument-names w label od t --description 'pure: zone separator ├─ <label> ─…┤ (BOLD muted label; empty label -> plain __tcz_thp_sep). od = border SGR, t = reset.'
    if test -z "$label"
        __tcz_thp_sep $w $od $t
        return
    end
    set -l MUT (__tcz_theme muted)
    set -l len (string length --visible -- "$label")
    set -l fill (math "$w - 3 - $len")
    test $fill -lt 0; and set fill 0
    set -l fillstr (string repeat -n $fill ─)
    printf '%s├─ \e[1m%s%s\e[22m%s %s┤%s\n' $od $MUT "$label" $od "$fillstr" $t
end
function __tcz_thp_kv --argument-names w flashfield --description 'pure: labeled adjustments pair — TWO lines (uppercase muted labels / values), columns aligned; argv[3..] = <label> <value> pairs, values may carry SGR (widths measured visible); flashfield (case-insensitive label match, empty = none) renders that one pair in the flash role instead of muted/its own SGR.'
    set -l MUT (__tcz_theme muted)
    set -l RST (__tcz_theme reset)
    set -l lr ' '
    set -l vr ' '
    set -l rest $argv[3..]
    while test (count $rest) -ge 2
        set -l lab (string upper -- $rest[1])
        set -l vplain (__tcz_strip_sgr "$rest[2]")
        set -l lw (string length --visible -- "$lab")
        set -l vw (string length --visible -- "$vplain")
        set -l cw (math "max($lw, $vw) + 3")
        set -l lpad (string repeat -n (math "$cw - $lw") ' ')
        set -l vpad (string repeat -n (math "$cw - $vw") ' ')
        set -l FL ''
        test -n "$flashfield"; and string match -qi -- "$flashfield" $rest[1]; and set FL (__tcz_theme flash)
        if test -n "$FL"
            set lr "$lr$FL$lab$RST$lpad"
            set vr "$vr$FL$vplain$RST$vpad"
        else
            set lr "$lr$MUT$lab$RST$lpad"
            set vr "$vr$rest[2]$RST$vpad"
        end
        set -e rest[1..2]
    end
    printf '%s\n%s\n' "$lr" "$vr"
end
function __tcz_thp_chip --argument-names tabshex tabsfg title --description 'pure: ShellFish tab chip " <title> " on the tabs-role color with the given fg; title truncated to 40 cols; EMPTY when tabshex is non-hex or title is empty (the reserved preview row renders blank).'
    set -l bg (__tcz_thp_bg "$tabshex")
    test -n "$bg"; or return
    test -n "$title"; or return
    set title (string sub -l 40 -- "$title")
    set -l fgS (__tcz_thp_fg "$tabsfg")
    set -l RST (printf '\e[0m')
    printf '%s%s %s %s' "$bg" "$fgS" "$title" "$RST"
end
function __tcz_thp_shellfish --description 'true iff any attached client is ShellFish — the production detection (__tcz_client_is_shellfish; tmux_lives_fake_environ seam applies), checked ONCE at picker open.'
    for pid in (tmux list-clients -F '#{client_pid}' 2>/dev/null)
        __tcz_client_is_shellfish $pid; and return 0
    end
    return 1
end
function __tcz_thp_restore --argument-names scheme --description '<scheme> <tokens…> -> 0-based cursor index; "off" -> the row AFTER the tokens; unknown -> 0 (mono)'
    set -l toks $argv[2..]
    test "$scheme" = off; and begin; echo (count $toks); return; end
    set -l i (contains -i -- "$scheme" $toks)
    test -n "$i"; and echo (math $i - 1); or echo 0
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
function __tcz_thp_rotpal --argument-names rotate pal --description 'pure: apply the rotate permutation display-side — support fields 2..6 of a rotate-0 pal string cyclically shifted (same index math as the engine); bar (1) and text (7) fixed. Non-7-field input returned unchanged.'
    set -l p (string split ' ' -- $pal)
    test (count $p) -eq 7; or begin; printf '%s' "$pal"; return; end
    string match -qr '^[0-4]$' -- "$rotate"; or set rotate 0
    set -l out $p[1]
    for i in 1 2 3 4 5
        set -l j (math "(($i - 1 - $rotate) % 5 + 5) % 5 + 1")
        set -l k (math "$j + 1")
        set -a out $p[$k]
    end
    set -a out $p[7]
    printf '%s' (string join ' ' $out)
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

function __tcz_theme_picker --argument-names client --description 'interactive theme picker (v3.1 layout A): tab-chip + fake-bar preview, labeled global-adjustments zone, 10 scheme rows + off row. ↑↓/jk move, ←→ phase (5°/press, coalesced), v vividness, s shape, e ease, d contrast (auto→lighter→darker), o rotate (0-4), b seed (RGB sliders; t drops to typed hex), a apply preview (no save), ⏎ save (via the CLI, silenced), r reset knobs, Esc/q revert+close. Runs INSIDE a display-popup (-w 52 -h 26); the frame is EXACTLY 26 rows.'
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
    set -l viv balanced
    set -l shape arc
    set -l ease linear
    set -l contrast auto
    set -l rotate 0
    set -l legacy ''
    set -l seedfg '#f5f5f5'
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
            echo (__tmux_lives_key tmux_lives_theme_vividness balanced)
            echo (__tmux_lives_key tmux_lives_theme_shape arc)
            echo (__tmux_lives_key tmux_lives_theme_ease linear)
            echo (__tmux_lives_key tmux_lives_theme_contrast auto)
            echo (__tmux_lives_key tmux_lives_theme_rotate 0)
            echo (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))
            echo (__tmux_lives_contrast_fg (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color "")))' 2>/dev/null)
        test (count $init) -ge 1; and set seed $init[1]
        test (count $init) -ge 2; and test -n "$init[2]"; and set theme $init[2]
        test (count $init) -ge 3; and test -n "$init[3]"; and set phase $init[3]
        test (count $init) -ge 4; and test -n "$init[4]"; and set viv $init[4]
        test (count $init) -ge 5; and test -n "$init[5]"; and set shape $init[5]
        test (count $init) -ge 6; and test -n "$init[6]"; and set ease $init[6]
        test (count $init) -ge 7; and test -n "$init[7]"; and set contrast $init[7]
        test (count $init) -ge 8; and test -n "$init[8]"; and set rotate $init[8]
        set legacy ''
        test (count $init) -ge 9; and set legacy (string replace -rf '.*bg=([^,]+).*' '$1' -- "$init[9]")
        set seedfg '#f5f5f5'
        test (count $init) -ge 10; and test -n "$init[10]"; and set seedfg $init[10]
        test -n "$seed"; or set seed '#3a3a3a'   # no seed yet: neutral, so the picker still teaches
    end
    __tcz_thp_init
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l cachekeys
    set -l cacheblobs
    function __tcz_thp_reload --no-scope-shadowing --description 'batch: all 10 palettes + fgs, in-process; rotate-0 results cached by knob-state key, rotation applied as a display-side permutation (o never recomputes)'
        set toks; set pals; set fgs; set tabsfgs
        set -l key "$seed|$phase|$viv|$shape|$ease|$contrast"
        set -l blob ''
        set -l ci (contains -i -- "$key" $cachekeys)
        if test -n "$ci"
            set blob $cacheblobs[$ci]
        else
            set -l lines
            for tok in (__tmux_lives_theme_schemes)
                set -l p (__tmux_lives_theme_palette $seed $tok $phase $viv $shape $ease $contrast 0)
                test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
                # per-support contrast fgs (any support can rotate onto cap/tabs)
                set -l sfgs
                for si in 2 3 4 5 6
                    set -l sf (__tmux_lives_contrast_fg "$p[$si]")
                    set -a sfgs "$sf"
                end
                set -l pj (string join ' ' $p)
                set -l fj (string join ' ' $sfgs)
                set -a lines "$tok|$pj|$fj"
            end
            set -l bj (string join \x1e $lines)
            set blob "$bj"
            set -a cachekeys "$key"
            set -a cacheblobs "$blob"
        end
        for line in (string split \x1e -- $blob)
            set -l f (string split '|' -- $line)
            test -n "$f[1]"; or continue
            set -a toks $f[1]
            set -l rp (__tcz_thp_rotpal $rotate "$f[2]")
            set -a pals "$rp"
            # displayed cap = support position 5, tabs = position 2 (post-perm)
            set -l sfgs (string split ' ' -- $f[3])
            set -l jc (math "((5 - 1 - $rotate) % 5 + 5) % 5 + 1")
            set -l jt (math "((2 - 1 - $rotate) % 5 + 5) % 5 + 1")
            set -a fgs "$sfgs[$jc]"
            set -a tabsfgs "$sfgs[$jt]"
        end
    end
    function __tcz_thp_hexentry --no-scope-shadowing --description 'typed-hex seed entry (raw; live swatch + hue/L/chroma readouts at parse-complete)'
                set -l buf (string replace -r '^#' '' -- $seed)
                set -l cand ''
                set -l hue ''
                set -l okl ''
                set -l okc ''
                set -l entering 1
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
                    # Synchronized update (DECSET 2026), same atomic-paint pattern as the
                    # main frame below — commits the entry paint in one go.
                    printf '\e[?2026h\e[H \e[1mseed — this IS the bar color\e[22m\e[K\n #%s_\e[K\n\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n %s\e[K\n\e[K\n%s\e[K' "$buf" $sw4[1] $sw4[2] $sw4[3] $sw4[4] "$leg"
                    printf '\e[J\e[?2026l'
                    set -l tok (__tcz_thp_readchar)
                    switch $tok
                        case back
                            test -n "$buf"; and set buf (string sub -e -1 -- $buf)
                        case enter
                            if test -n "$cand"
                                fish -c 'tmux-lives setup color $argv[1]' "$cand" >/dev/null 2>&1
                                __tcz_thp_init
                                __tcz_thp_reload
                                set note "seed applied: $seed"
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
                    fish -c 'tmux-lives setup color $argv[1]' (printf '#%02x%02x%02x' $r $g $b) >/dev/null 2>&1
                    __tcz_thp_init
                    __tcz_thp_reload
                    set note "seed applied: $seed"
                    set flashfield seed
                    set sliding 0
                case esc
                    set sliding 0
            end
        end
        printf '\e[2J'
    end
    __tcz_thp_reload
    set -l n (count $toks)          # 10 scheme rows; index n (0-based) = the off row
    set -l sel (__tcz_thp_restore "$theme" $toks)
    set -l saved (stty -g)
    set -g __tcz_thp_saved $saved
    function __tcz_thp_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_thp_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    set -l IW 50
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
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J'
    set -l apply ''
    while true
        # cursor row palette (off row -> legacy colors: derived bar + plain text)
        set -l curpal ''
        set -l curfg '#f5f5f5'
        if test $sel -lt $n
            # index via a var, UNQUOTED: a double-quoted list index built from a
            # math substitution is a fish "Invalid index value" error (empty result
            # + a 3-line stderr trace into the popup EVERY draw — the 2026-07-16
            # live-smoke bug: frame scrolled out, flicker, colorless preview).
            set -l pidx (math $sel + 1)
            set curpal $pals[$pidx]
            set -l cf $fgs[$pidx]
            test -n "$cf"; and set curfg $cf
        else
            set -l lb "$legacy"
            test -n "$lb"; or set lb '#444444'
            set curpal "$lb #6b6b6b #6b6b6b #6b6b6b #9a9a9a #444444 #d3d8d0"
            set curfg '#f5f5f5'
        end
        set -l ptoks (string split ' ' -- $curpal)
        set -l curtabs "$ptoks[3]"
        set -l curtabsfg '#f5f5f5'
        if test $sel -lt $n
            set -l tfidx (math $sel + 1)
            set curtabsfg "$tabsfgs[$tfidx]"
        end
        set -l seedchip (__tcz_thp_bg "$seed")(__tcz_thp_fg "$seedfg")"$seed"(printf '\e[0m')
        set -l B1 (printf '\e[1m')
        set -l B0 (printf '\e[22m')
        # NB: fish does NOT interpret \e inside quoted strings (only printf does) —
        # the bold SGRs must be printf-captured vars, never "\e[1m" literals.
        set -l lines
        set -a lines $BORDER"╭─ $B1"$BRAND"theme$B0"$BORDER" ─ preview "(string repeat -n (math "$IW - 18") ─)"╮"$RST
        # capture-then-quote: __tcz_thp_chip prints NOTHING when non-ShellFish (the
        # common case) — a zero-output command substitution used as a bare argument
        # VANISHES from the arg list, so __tcz_thp_ln would silently get 3 args
        # instead of 4 (content=$IW, w=$BORDER, ...) and spray math/test errors into
        # the popup on every redraw. Capture into a var first, then quote it.
        set -l chip (__tcz_thp_chip "$curtabs" "$curtabsfg" "$chiptitle")
        set -a lines (__tcz_thp_ln "$chip" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_thp_preview "$curpal" "$curfg" "$host" Monitoring $IW) $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW 'adjustments · apply to all schemes' $BORDER $RST)
        set -l kv1 (__tcz_thp_kv $IW "$flashfield" seed "$seedchip" phase "+$phase°" vividness "$viv" shape "$shape")
        set -a lines (__tcz_thp_ln "$kv1[1]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln "$kv1[2]" $IW $BORDER $RST)
        set -l kv2 (__tcz_thp_kv $IW "$flashfield" contrast "$contrast" rotate "$rotate" ease "$ease")
        set -a lines (__tcz_thp_ln "$kv2[1]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln "$kv2[2]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW 'scheme · companion sets for the seed' $BORDER $RST)
        for i in (seq $n)
            set -l selflag 0
            test $i -eq (math $sel + 1); and set selflag 1
            set -l row (__tcz_thp_row "$pals[$i]" $toks[$i] $selflag)
            if test $selflag -eq 1
                set row (string replace -a -- "$RST" "$RST$SELBG" "$row")
                set row "$SELBG$row$RST"
            end
            set -a lines (__tcz_thp_ln "$row" $IW $BORDER $RST)
        end
        set -l offflag 0
        test $sel -eq $n; and set offflag 1
        set -l offrow (__tcz_thp_off_row "$legacy" $offflag)
        if test $offflag -eq 1
            set offrow (string replace -a -- "$RST" "$RST$SELBG" "$offrow")
            set offrow "$SELBG$offrow$RST"
        end
        set -a lines (__tcz_thp_ln "$offrow" $IW $BORDER $RST)
        set -a lines (__tcz_thp_zsep $IW '' $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 '↑↓' scheme '←→' phase v vivid s shape) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 e ease d contrast o rotate b seed) $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln (__tcz_legend_row 12 a apply '⏎' save r reset esc close) $IW $BORDER $RST)
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
        if test -n "$flashfield"
            # flash active: wait up to ~0.5s; on timeout clear the flash and
            # repaint. A real key is handled exactly like the blocking read.
            stty min 0 time 5 2>/dev/null
            set tok (__tcz_popup_readkey timeout)
            stty min 1 time 0 2>/dev/null
            if test "$tok" = timeout
                set flashfield ''
                continue
            end
        else
            set tok (__tcz_popup_readkey)
        end
        switch $tok
            case up
                test $sel -gt 0; and set sel (math $sel - 1)
            case down
                test $sel -lt $n; and set sel (math $sel + 1)
            case left
                # net-delta coalescing: drain buffered arrows into ONE recompute.
                # The readkey ESC/CSI-arrow branch leaves the tty in `min 1 time 0`
                # (blocking) on return, so each iteration re-asserts non-blocking
                # BEFORE reading — otherwise the second drain read blocks forever.
                set -l delta -5
                while true
                    stty min 0 time 0 2>/dev/null
                    set -l k2 (__tcz_popup_readkey)
                    switch "$k2"
                        case left;  set delta (math $delta - 5)
                        case right; set delta (math $delta + 5)
                        case '*';   break   # cancel = drained (EOF); anything else ends the burst
                    end
                end
                stty min 1 time 0 2>/dev/null
                set phase (math "((($phase + $delta) % 360) + 360) % 360")
                set flashfield phase
                __tcz_thp_reload
            case right
                set -l delta 5
                while true
                    stty min 0 time 0 2>/dev/null
                    set -l k2 (__tcz_popup_readkey)
                    switch "$k2"
                        case left;  set delta (math $delta - 5)
                        case right; set delta (math $delta + 5)
                        case '*';   break
                    end
                end
                stty min 1 time 0 2>/dev/null
                set phase (math "((($phase + $delta) % 360) + 360) % 360")
                set flashfield phase
                __tcz_thp_reload
            case v
                switch "$viv"
                    case soft;     set viv balanced
                    case balanced; set viv vivid
                    case '*';      set viv soft
                end
                set flashfield vividness
                __tcz_thp_reload
            case V
                switch "$viv"
                    case vivid;    set viv balanced
                    case balanced; set viv soft
                    case '*';      set viv vivid
                end
                set flashfield vividness
                __tcz_thp_reload
            case s S
                test "$shape" = arc; and set shape flat; or set shape arc
                set flashfield shape
                __tcz_thp_reload
            case e E
                test "$ease" = linear; and set ease cubic; or set ease linear
                set flashfield ease
                __tcz_thp_reload
            case d
                switch "$contrast"
                    case auto;    set contrast lighter
                    case lighter; set contrast darker
                    case '*';     set contrast auto
                end
                set flashfield contrast
                __tcz_thp_reload
            case D
                switch "$contrast"
                    case auto;    set contrast darker
                    case darker;  set contrast lighter
                    case '*';     set contrast auto
                end
                set flashfield contrast
                __tcz_thp_reload
            case o
                set rotate (math "($rotate + 1) % 5")
                set flashfield rotate
                __tcz_thp_reload
            case O
                set rotate (math "($rotate + 4) % 5")
                set flashfield rotate
                __tcz_thp_reload
            case r
                set phase 0; set viv balanced; set shape arc; set ease linear
                set contrast auto; set rotate 0
                set note 'knobs reset (not saved — ⏎ to save)'
                set flashfield ''
                __tcz_thp_reload
            case b
                __tcz_thp_sliders
            case a
                set -l ptok off
                test $sel -lt $n; and begin; set -l pi (math $sel + 1); set ptok $toks[$pi]; end
                fish -c '__tmux_lives_theme_apply_live $argv' $ptok $phase $viv $shape $ease $contrast $rotate >/dev/null 2>&1
                set previewed 1
                set note "● previewing $ptok — ⏎ save · esc revert"
            case enter
                if test $sel -lt $n
                    set apply $toks[(math $sel + 1)]
                else
                    set apply off
                end
                break
            case cancel
                if test $previewed -eq 1
                    fish -c __tmux_lives_theme_apply_live >/dev/null 2>&1
                end
                break
        end
    end
    functions -e __tcz_thp_cleanup
    functions -e __tcz_thp_init
    functions -e __tcz_thp_reload
    functions -e __tcz_thp_hexentry
    functions -e __tcz_thp_sliders
    set -e __tcz_thp_saved
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    if test "$apply" = off
        fish -c 'tmux-lives setup theme off' >/dev/null 2>&1
    else if test -n "$apply"
        fish -c 'tmux-lives setup theme $argv[1] --phase $argv[2] --vividness $argv[3] --shape $argv[4] --ease $argv[5] --contrast $argv[6] --rotate $argv[7]' "$apply" "$phase" "$viv" "$shape" "$ease" "$contrast" "$rotate" >/dev/null 2>&1
    end
    return 0
end

function __tcz_theme --argument-names role --description 'tl theme palette -> truecolor SGR for a named role (brand/border/key/muted/value/mark/flash/sel-bg/sel-fg/reset)'
    switch $role
        case brand;  printf '\e[38;2;255;138;31m'
        case border; printf '\e[38;2;168;106;44m'
        case key;    printf '\e[38;2;245;207;138m'
        case muted;  printf '\e[38;2;154;138;114m'
        case value;  printf '\e[38;2;111;199;184m'
        # mark: a TRUE neutral grey for the active-column rule. Intentionally neither `key`
        # (tan — the ▐ selector; sharing it read as a colour collision) nor `muted` (a WARM
        # tan-grey). The rule sits inside the swatch strip, so it must recede from the
        # colour story rather than join it; neutral grey also stays legible both ways —
        # darker than a light swatch, lighter than a dark one.
        case mark;   printf '\e[38;2;138;138;138m'
        # change-flash blue (picker adjustments zone; 2026-07-17 UX request)
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
    tmux set-option -t "$desired" @tmux_auto_name "$desired" 2>/dev/null
    or tmux set-option -t "$desired" @tmux_auto_name "$desired" 2>/dev/null
end

function __tcz_tab_color --argument-names fallback --description 'effective ShellFish tab colour: the live tabs-role @option (@tmux_lives_tabs_color, set by the themed fragment) when non-empty, else <fallback> (the baked seed / legacy)'
    set -l eff (tmux show -gv @tmux_lives_tabs_color 2>/dev/null)
    test -n "$eff"; and echo $eff; or echo $fallback
end

function __tcz_on_attach --argument-names pid tty color --description 'on-attach <client_pid> <client_tty> [color]: ShellFish -> set bar color; else re-apply the non-ShellFish baseline'
    if __tcz_client_is_shellfish $pid
        set -l eff (__tcz_tab_color "$color")
        __tcz_emit_barcolor $tty $eff
        __tcz_emit_set $tty color $eff
        __tcz_retitle
    else
        # Baseline path default mirrors __tmux_lives_baseline_path in conf.d/tmux-lives-install.fish — keep in sync.
        set -l baseline (set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf")
        test -e $baseline; and tmux source-file $baseline 2>/dev/null
    end
    return 0
end

function __tcz_recolor --argument-names color mode --description 'emit the ShellFish bar-color OSC to attached ShellFish clients. mode=dedup emits only when the color changed for that tty; else force. Updates the per-tty cache on emit.'
    set color (__tcz_tab_color "$color")
    test -n "$color"; or return 0
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; or continue
        set -l cached (__tcz_emit_get $tty color)
        test "$mode" = dedup; and test "$color" = "$cached"; and continue
        __tcz_emit_barcolor $tty $color
        __tcz_emit_set $tty color $color
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
    for line in (tmux list-panes -s -t "=$session" -F "#{pane_current_command}$TAB#{pane_pid}" 2>/dev/null)
        set -l p (string split $TAB -- $line)
        __tcz_pane_is_claude "$p[1]" "$p[2]"; and return 0
    end
    return 1
end

function __tcz_set_claude_opt --argument-names session --description 'set @tmux_lives_claude on <session> = its claude --name (empty if no claude pane). BARE name for set-option (=target quirk).'
    test -n "$session"; or return
    set -l TAB (printf '\t')
    set -l name ''
    for line in (tmux list-panes -s -t "=$session" -F "#{pane_current_command}$TAB#{pane_pid}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        test "$parts[1]" = claude; or continue
        set name (__tcz_cmdline_name $parts[2])
        test -n "$name"; and break
    end
    # Dedup: only write when the value actually CHANGED. An unconditional set every tick /
    # fish_postexec forces a redraw of the bar (@tmux_lives_claude is status-read), which makes
    # tmux re-emit the cursor style → ShellFish cursor flicker (see [[shellfish-cursor-flicker]]).
    # Capture+quote the current value (empty -> zero-word subst would throw; the empty-cache gotcha).
    # BARE name for show/set-option (=target quirk).
    set -l cur (tmux show-option -qv -t "$session" @tmux_lives_claude 2>/dev/null)
    test "$name" = "$cur"; and return
    tmux set-option -t "$session" @tmux_lives_claude "$name" 2>/dev/null
end

function __tcz_session_title --argument-names session --description 'session -> "<host>: <dir>[ (C)]" (active-pane dir; session-wide claude)'
    test -n "$session"; or return 0
    # NB: `display-message -t "=$session" '#{pane_current_path}'` returns EMPTY in tmux
    # 3.3a (the =exact-target quirk — see [[tmux-target-quirks]]); list-panes honors = AND
    # resolves the active pane's path. Filter to the active pane of the session's window.
    set -l path (tmux list-panes -t "=$session" -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | string match -rv '^$')
    set -l claude 0
    __tcz_session_has_claude $session; and set claude 1
    set -l name (tmux show-option -qv -t "$session" @tmux_lives_name 2>/dev/null)
    test -n "$name"; or set name (__tcz_dir_display $path)
    __tcz_format_title (__tcz_hostname) "$name" $claude
end

function __tcz_retitle --argument-names mode --description 'emit each attached ShellFish client its own OSC 2 title. mode=dedup emits only when the title changed for that tty; else force. Updates the per-tty cache on emit.'
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}$TAB#{client_session}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        set -l session $parts[3]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; or continue
        set -l title (__tcz_session_title $session)
        test -n "$title"; or continue
        set -l cached (__tcz_emit_get $tty title)
        test "$mode" = dedup; and test "$title" = "$cached"; and continue
        __tcz_emit_title $tty $title
        __tcz_emit_set $tty title $title
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
        case '*'
            echo "usage: tmux-categorize.fish categorize|tick|overview|menu|open-switcher|popup|theme-picker|modal|modal-menu|scratch|scratch-resize|scratch-orient|scratch-kill|resize-enter|status-pos-toggle|status-vis-toggle|recolor|retitle|claim|ghosts|switch|commandeer|on-attach|slug|new-general|host-kind|status-format" >&2
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
