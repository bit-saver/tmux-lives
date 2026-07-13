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
    echo '#{?#{!=:#{@tmux_lives_claude},},✦ #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{@tmux_lives_claude}},#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}}'
end

function __tcz_status_format --description 'pure: the status-format[0] string (all tunables are @options; right zone renders status-right so tick/continuum survive)'
    # PUA glyphs via codepoints (never paste literal PUA): powerline slants.
    set -l slantR (printf '\U0000e0b0')   # right-pointing, closes a left-anchored cap
    set -l slantL (printf '\U0000e0b2')   # left-pointing, opens a right-anchored cap
    # The cap background follows the mode: prefix -> prefix color, resize -> resize color, else the base cap bg.
    set -l capbg '#{?client_prefix,#{@tmux_lives_prefix_color},#{?#{==:#{client_key_table},tmuxlives-resize},#{@tmux_lives_resize_color},#{@tmux_lives_cap_bg}}}'
    set -l glyph '#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}'
    set -l win '#{W:#{T:window-status-format}#{?window_end_flag,,#{window-status-separator}},#{T:window-status-current-format}#{?window_end_flag,,#{window-status-separator}}}'
    set -l id (__tcz_status_identity)
    # host cap (far left): styled segment + slant into the bar, then the window list (flat)
    set -l hostcap "#[fg=#{@tmux_lives_cap_fg},bg=$capbg] $glyph #{host_short} #[fg=$capbg,bg=#{@tmux_lives_bar_bg},none]$slantR#[default]"
    # centre: prefix chevron, else resize badge, else identity
    set -l centre "#{?client_prefix,❯ ,}#{?#{==:#{client_key_table},tmuxlives-resize},◇ RESIZE ◇  #[fg=#{@tmux_lives_cap_fg}]arrows move · x kill · esc/enter done,$id}"
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
    printf '%s\n' \
        'new session'    n "run-shell 'fish -c \"tmux-lives new\"'" \
        'clear idle'     c "run-shell 'fish -c \"tmux-lives clear\"'" \
        'categorize'     g "run-shell 'fish --no-config $__tcz_self tick'" \
        'picker'         s "run-shell 'fish --no-config $__tcz_self open-switcher'" \
        'cap color'      k "command-prompt -p 'cap formula:' 'run-shell \"fish -c \\\"tmux-lives setup cap %%\\\"\"'" \
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
    set -l SELBG (printf '\e[48;5;236m')
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

function __tcz_popup_readkey --description 'read one keystroke -> up|down|left|right|v|w|enter|cancel|kill|other'
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
    test -z "$b"; and begin; echo cancel; return; end          # EOF
    switch "$b"
        case 6a; echo down; return                  # j
        case 6b; echo up; return                    # k
        case 68; echo left; return                  # h
        case 6c; echo right; return                 # l
        case 76; echo v; return                      # v (cap-picker: cycle vividness)
        case 77; echo w; return                      # w (cap-picker: toggle wheel)
        case 71; echo cancel; return                # q
        case 78; echo kill; return                  # x
        case 0d 0a; echo enter; return              # CR / LF
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
                set -a lines (__tcz_ml_ln "   $O"k"$T cap color" "   k cap color" $IW $OD $T)
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
        case k; echo cap
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
        case cap
            # Defer: run AFTER this popup closes; open cap-picker in its OWN popup
            # (the cap-picker verb runs INSIDE a popup, unlike open-switcher which
            # opens one itself — so we must wrap it here). Mirrors __tmux_lives_cap_picker.
            tmux run-shell -b "tmux display-popup -B -E -w 34 -h 15 -- fish --no-config $__tcz_self cap-picker '$client'" 2>/dev/null
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
        __tcz_popup_draw $sel $listw $prevw $rows "$current" -- $model
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

function __tcz_cap_families --description 'pure: ordered cap-color family tokens shown in the picker (directional families default to their + side; ←→ flips it; tetradic has no direction, same as mono/complementary)'
    printf '%s\n' mono complementary analogous+ split+ triadic+ tetradic
end

function __tcz_cap_restore --argument-names formula --description 'pure: 0-based index of the families entry whose base matches <formula>''s base (trailing +/- stripped), or -1 if none (e.g. #hex/unknown)'
    set -l families $argv[2..]
    set -l base (string replace -r -- '[+-]$' '' $formula)
    for i in (seq (count $families))
        set -l fbase (string replace -r -- '[+-]$' '' $families[$i])
        if test "$fbase" = "$base"
            math $i - 1
            return
        end
    end
    echo -1
end

function __tcz_cap_flip --argument-names token --description 'pure: toggle a directional cap token +<->-; no-op for mono/complementary (they have no direction)'
    switch "$token"
        case '*+'
            string replace -r '\+$' - -- $token
        case '*-'
            string replace -r -- '-$' + $token
        case '*'
            echo $token
    end
end

function __tcz_cap_swatch_line --argument-names dimhex mutedhex accenthex token selected --description 'pure: one cap-picker row = selection marker + a 3-cell palette strip (dim·muted·accent, ALREADY-COMPUTED truecolor swatches) + <token> name. Never calls the install-side palette engine (see the --no-config runtime note on __tcz_cap_picker) — the three hexes are precomputed by the caller (mirrors __tmux_lives_cap_list''s strip rendering).'
    set -l RST (printf '\e[0m')
    set -l ORG (printf '\e[38;5;208m')
    set -l SELBG (printf '\e[48;5;236m')
    # 3-cell truecolor strip; each blank/unparseable hex degrades to a neutral
    # two-space gap instead of crashing (e.g. no bar color configured yet).
    set -l strip ''
    for hex in $dimhex $mutedhex $accenthex
        set -l cell '  '
        set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- "$hex")
        test (count $m) -eq 3; and set cell (printf '\e[48;2;%d;%d;%dm  \e[0m' (math "0x$m[1]") (math "0x$m[2]") (math "0x$m[3]"))
        set strip "$strip$cell"
    end
    set -l name (printf '%-13s' "$token")
    if test "$selected" = 1
        printf '%s%s▐%s %s %s%s' $SELBG $ORG $RST "$strip" "$name" $RST
    else
        printf '  %s %s' "$strip" "$name"
    end
end

function __tcz_cap_picker --argument-names client --description 'interactive cap-color picker: palette-strip rows (dim·muted·accent truecolor swatches per formula) inside a self-drawn orange frame; ↑↓/jk move, ←→/hl flip the highlighted family''s direction (cache lookup, no subprocess), v cycles vividness (subtle→balanced→vivid), w toggles the hue wheel (ryb↔perceptual) — both trigger a batch recompute; Enter applies (tmux-lives setup cap <token> --vividness <v> --wheel <w>), Esc/q cancels. Runs INSIDE a display-popup already opened by __tmux_lives_cap_picker (task 3) — this function does not open its own popup or provide a display-menu fallback (that gate already lives at the CLI layer, before the popup opens).'
    # RUNTIME CONSTRAINT: this whole script runs as `fish --no-config` (see the file
    # header), so install-side __tmux_lives_* functions (palette, key, derive_status_bg, …)
    # are NOT loaded here. Batch-compute the palette STRIP (dim/muted/accent) for EVERY
    # directional token in ONE config-loaded `fish -c` subprocess (which DOES load conf.d)
    # up front, so the install-side __tmux_lives_palette engine stays the single source of
    # truth. v/w change the dim/muted/accent math for every family, so they re-run the
    # whole batch (__tcz_cap_reload below); flipping a family's direction is a pure cache
    # lookup — both the + and - variants are always present in the batch.
    set -l init (fish -c '
        echo (__tmux_lives_derive_status_bg (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))
        echo (__tmux_lives_key tmux_lives_cap_wheel ryb)
        echo (__tmux_lives_key tmux_lives_cap_vividness vivid)
        echo (__tmux_lives_key tmux_lives_cap mono)' 2>/dev/null)
    set -l bar ''; test (count $init) -ge 1; and set bar $init[1]
    test -n "$bar"; or set bar '#3a3a3a'   # no bar color configured yet -> neutral default (mirrors `setup cap list`)
    set -l wheel ''; test (count $init) -ge 2; and set wheel $init[2]
    test -n "$wheel"; or set wheel ryb
    set -l vividness ''; test (count $init) -ge 3; and set vividness $init[3]
    test -n "$vividness"; or set vividness vivid
    set -l capformula ''; test (count $init) -ge 4; and set capformula $init[4]
    test -n "$capformula"; or set capformula mono

    set -l toks; set -l dims; set -l muteds; set -l accents
    function __tcz_cap_reload --no-scope-shadowing --description 'refill the palette-strip cache (toks/dims/muteds/accents) for every directional cap token, at the current bar/wheel/vividness — the one fish -c that talks to __tmux_lives_palette (re-run on v/w change).'
        set toks; set dims; set muteds; set accents
        for line in (fish -c '
            for tok in mono complementary analogous+ analogous- split+ split- triadic+ triadic- tetradic
                set -l p (__tmux_lives_palette $argv[1] $tok $argv[2] $argv[3])
                test (count $p) -eq 5; or set p "" "" "" "" ""
                printf "%s %s %s %s\n" $tok $p[2] $p[3] $p[4]
            end' $bar $wheel $vividness 2>/dev/null)
            set -l f (string split ' ' -- $line)
            test -n "$f[1]"; or continue
            set -a toks $f[1]
            set -a dims $f[2]
            set -a muteds $f[3]
            set -a accents $f[4]
        end
    end
    __tcz_cap_reload

    set -l families (__tcz_cap_families)
    set -l n (count $families)
    set -l sel 0
    set -l ridx (__tcz_cap_restore $capformula $families)
    if test $ridx -ge 0
        set sel $ridx
        set families[(math $sel + 1)] $capformula
    end
    set -l saved (stty -g)
    # Restore the terminal even if the popup is killed mid-loop (mirrors __tcz_popup).
    set -g __tcz_cap_saved $saved
    function __tcz_cap_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_cap_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    # frame helpers — mirror __tcz_modal_legend's box (orange border, ╭─ title ─╮ / ╰─╯)
    # and its __tcz_ml_ln padder; padding is computed from the SGR-stripped visible
    # length and passed as a QUOTED variable, never an inline (string repeat -n 0 …)
    # spliced straight into printf's arg list — an empty repeat there yields ZERO args
    # and silently drops the trailing fields (the __tmux_lives_box gotcha).
    set -l IW 30
    set -l O (printf '\e[38;5;208m'); set -l OD (printf '\e[38;5;130m')
    set -l T (printf '\e[0m')
    function __tcz_cap_ln --argument-names content w od t --description 'pad an ALREADY-COLORED content string to visible width w (via __tcz_strip_sgr) and wrap it in the orange-bordered frame'
        set -l vis (__tcz_strip_sgr "$content")
        set -l pad (math "$w - "(string length -- "$vis"))
        test $pad -lt 0; and set pad 0
        set -l padstr (string repeat -n $pad ' ')
        printf '%s│%s%s│%s\n' $od "$content$t$padstr" $od $t
    end
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J'
    set -l result ''
    while true
        set -l lines
        set -a lines $OD"╭─ "$O"cap color"$OD" "(string repeat -n (math "$IW - 12") ─)"╮"$T
        for i in (seq $n)
            set -l tok $families[$i]
            set -l idx (contains -i -- $tok $toks)
            set -l dimhex ''; set -l mutedhex ''; set -l accenthex ''
            if test -n "$idx"
                set dimhex $dims[$idx]; set mutedhex $muteds[$idx]; set accenthex $accents[$idx]
            end
            set -l selflag 0
            test $i -eq (math $sel + 1); and set selflag 1
            set -a lines (__tcz_cap_ln (__tcz_cap_swatch_line "$dimhex" "$mutedhex" "$accenthex" $tok $selflag) $IW $OD $T)
        end
        set -a lines $OD"╰"(string repeat -n $IW ─)"╯"$T
        printf '\e[H'
        printf '%s\e[K\n' $lines
        printf '\e[K\n ↑↓ move  ←→ flip\e[K\n v vivid  w wheel\e[K\n ⏎ apply  esc cancel\e[K\n [%s / %s]\e[K\e[J' $wheel $vividness
        switch (__tcz_popup_readkey)
            case up
                test $sel -gt 0; and set sel (math $sel - 1)
            case down
                test $sel -lt (math $n - 1); and set sel (math $sel + 1)
            case left right
                set families[(math $sel + 1)] (__tcz_cap_flip $families[(math $sel + 1)])
            case v
                switch "$vividness"
                    case subtle;   set vividness balanced
                    case balanced; set vividness vivid
                    case '*';      set vividness subtle
                end
                __tcz_cap_reload
            case w
                if test "$wheel" = ryb
                    set wheel perceptual
                else
                    set wheel ryb
                end
                __tcz_cap_reload
            case enter
                set result $families[(math $sel + 1)]
                break
            case cancel
                break
        end
    end
    functions -e __tcz_cap_cleanup
    functions -e __tcz_cap_reload
    functions -e __tcz_cap_ln
    set -e __tcz_cap_saved
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    test -n "$result"; and fish -c 'tmux-lives setup cap $argv[1] --vividness $argv[2] --wheel $argv[3]' "$result" "$vividness" "$wheel" 2>/dev/null
    return 0
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

function __tcz_on_attach --argument-names pid tty color --description 'on-attach <client_pid> <client_tty> [color]: ShellFish -> set bar color; else re-apply the non-ShellFish baseline'
    if __tcz_client_is_shellfish $pid
        __tcz_emit_barcolor $tty $color
        __tcz_emit_set $tty color $color
        __tcz_retitle
    else
        # Baseline path default mirrors __tmux_lives_baseline_path in conf.d/tmux-lives-install.fish — keep in sync.
        set -l baseline (set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf")
        test -e $baseline; and tmux source-file $baseline 2>/dev/null
    end
    return 0
end

function __tcz_recolor --argument-names color mode --description 'emit the ShellFish bar-color OSC to attached ShellFish clients. mode=dedup emits only when the color changed for that tty; else force. Updates the per-tty cache on emit.'
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
    tmux split-window -h -p 33 2>/dev/null
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
    tmux split-window $flag -p 33 2>/dev/null
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
        case cap-picker
            __tcz_cap_picker $argv[2..]
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
            echo "usage: tmux-categorize.fish categorize|tick|overview|menu|open-switcher|popup|claim|ghosts|switch|commandeer|on-attach|slug|new-general" >&2
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
