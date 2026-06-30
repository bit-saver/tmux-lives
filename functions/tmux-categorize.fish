#!/usr/bin/env fish
# tmux-categorize: live-state session classification, naming, overview, menu, ghost-detach.
# Runs under `fish --no-config` (fast, no conf.d side effects — safe inside tmux #()).
# Spec: docs/superpowers/specs/2026-06-11-tmux-categorized-sessions-design.md
# Subcommands: categorize | tick | overview | menu | open-switcher <client> | popup <client> | claim <pane> <raw> <cwd> | ghosts <session> | switch <session> <client> | commandeer <client> <session> | slug <text...>
# Tests source this file with tmux_categorize_test set, which suppresses the dispatcher.

# Shell list — MUST match __tmux_session_is_idle in conf.d/tmux.fish (test-enforced).
set -g __tcz_shells fish bash sh zsh dash
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
    set -l sess_fmt (printf '#{session_name}\t#{session_attached}\t#{session_last_attached}')
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
        else if not contains -- $f[2] $__tcz_shells
            test "$cats[$i]" = claude; or set cats[$i] running
            test -z "$firstcmd[$i]"; and set firstcmd[$i] $f[2]
        end
    end
    # attached / last_attached lookup
    set -l snames; set -l satt; set -l slast
    for line in (tmux list-sessions -F $sess_fmt 2>/dev/null)
        set -l f (string split $TAB -- $line)
        test (count $f) -ge 3; or continue
        set -a snames $f[1]; set -a satt $f[2]; set -a slast $f[3]
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
        'switcher'       s "run-shell 'fish --no-config $__tcz_self open-switcher'" \
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
    set -l BEL (printf '\a')
    set -l budget (math "$width - 1")
    set -l chars (string split '' -- "$text")
    set -l n (count $chars)
    set -l i 1
    set -l acc 0
    set -l out ''
    set -l sawsgr 0
    while test $i -le $n
        set -l ch $chars[$i]
        if test "$ch" = "$ESC"
            # Copy a whole escape sequence verbatim (zero display width). CSI/SGR ends
            # on a final byte in A-Z/a-z (the `m` of an SGR colour). `capture-pane -e`
            # emits SGR only, so OSC (`\e]…`, ST/BEL-terminated) is intentionally out of
            # scope here — the BEL check is a cheap guard, not full OSC parsing. Either
            # way, never split a sequence across the cut.
            set out "$out$ch"; set sawsgr 1; set i (math $i + 1)
            while test $i -le $n
                set -l c2 $chars[$i]
                set out "$out$c2"; set i (math $i + 1)
                if string match -qr '[A-Za-z]' -- "$c2"; or test "$c2" = "$BEL"
                    break
                end
            end
            continue
        end
        set -l cw (string length --visible -- "$ch")
        test (math "$acc + $cw") -gt $budget; and break
        set out "$out$ch"; set acc (math "$acc + $cw"); set i (math $i + 1)
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

function __tcz_popup_readkey --description 'read one keystroke -> up|down|enter|cancel|other'
    # Read RAW bytes with an inline `dd | … | read` pipeline. Why not simpler:
    #  - fish `read` on the tty runs fish's line editor and SWALLOWS arrow escape
    #    sequences (treats them as cursor-move), so they never reach us.
    #  - dd reads bytes verbatim, but it must be the HEAD of a pipeline in this
    #    function — a command substitution `(dd …)` inside a function that is a
    #    pipe's RHS does NOT inherit the piped stdin (fish quirk). `… | read VAR`
    #    sets VAR in scope. Bytes are compared as hex.
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo cancel; return; end          # EOF
    switch "$b"
        case 6a; echo down; return                  # j
        case 6b; echo up; return                    # k
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

function __tcz_modal_legend --argument-names has_scratch --description 'pure: the command-modal key legend (ANSI); scratch-management row only when a scratch exists'
    set -l O (printf '\e[38;5;208m')   # orange key accent
    set -l D (printf '\e[2m')          # dim
    set -l R (printf '\e[0m')
    set -l rows
    set -a rows "$O n$R new   $O c$R clear   $O g$R categorize"
    set -a rows "$O s$R switcher   $O t$R scratch   $O b$R bar color"
    test "$has_scratch" = 1; and set -a rows "$D scratch:$R $O ←→↑↓$R resize  $O h/w$R split  $O x$R close"
    set -a rows "$O esc$R close"
    printf '%s\n' $rows
end

function __tcz_modal_action --argument-names key has_scratch --description 'pure: modal keyname + scratch-state -> action token'
    switch "$key"
        case n; echo new
        case c; echo clear
        case g; echo categorize
        case s; echo switcher
        case t; echo scratch
        case b; echo color
        case esc q; echo close
        case x;     test "$has_scratch" = 1; and echo scratch-close; or echo noop
        case h;     test "$has_scratch" = 1; and echo orient-h; or echo noop
        case w;     test "$has_scratch" = 1; and echo orient-w; or echo noop
        case left;  test "$has_scratch" = 1; and echo resize-left; or echo noop
        case right; test "$has_scratch" = 1; and echo resize-right; or echo noop
        case up;    test "$has_scratch" = 1; and echo resize-up; or echo noop
        case down;  test "$has_scratch" = 1; and echo resize-down; or echo noop
        case '*';   echo noop
    end
end

function __tcz_modal_readkey --description 'read one keystroke -> keyname (letters as tokens; arrows/enter/esc parsed)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo close; return; end          # EOF
    switch "$b"
        case 0d 0a; echo enter; return
        case 6e; echo n; return
        case 63; echo c; return
        case 67; echo g; return
        case 73; echo s; return
        case 74; echo t; return
        case 62; echo b; return
        case 68; echo h; return
        case 77; echo w; return
        case 78; echo x; return
        case 71; echo q; return
    end
    if test "$b" = 1b                                          # ESC
        stty min 0 time 1 2>/dev/null
        set -l b2 ''
        dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b2
        set -l b3 ''
        if test "$b2" = 5b; or test "$b2" = 4f                 # [ or O
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
        echo esc; return
    end
    echo other
end

function __tcz_modal_run --argument-names action client --description 'run a modal action token; echo close|stay (color is returned for the loop input sub-state)'
    switch "$action"
        case new
            fish -c 'tmux-lives new' 2>/dev/null; echo close
        case clear
            fish -c 'tmux-lives clear' 2>/dev/null; echo stay
        case categorize
            __tcz_categorize >/dev/null 2>&1; echo stay
        case switcher
            __tcz_open_switcher "$client"; echo close
        case scratch scratch-close
            __tcz_scratch "$client"; echo stay
        case orient-h
            __tcz_scratch_orient h; echo stay
        case orient-w
            __tcz_scratch_orient w; echo stay
        case resize-left
            tmux resize-pane -t (__tcz_scratch_pane)[1] -L 4 2>/dev/null; echo stay
        case resize-right
            tmux resize-pane -t (__tcz_scratch_pane)[1] -R 4 2>/dev/null; echo stay
        case resize-up
            tmux resize-pane -t (__tcz_scratch_pane)[1] -U 2 2>/dev/null; echo stay
        case resize-down
            tmux resize-pane -t (__tcz_scratch_pane)[1] -D 2 2>/dev/null; echo stay
        case color
            echo color
        case close
            echo close
        case '*'
            echo stay
    end
end

function __tcz_modal --argument-names client --description 'key-capturing command modal (runs inside display-popup)'
    if test -z "$client"; or string match -q '*#{*' -- "$client"
        set client (tmux display-message -p '#{client_name}' 2>/dev/null)
    end
    set -l saved (stty -g)
    set -g __tcz_modal_saved $saved
    function __tcz_modal_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_modal_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    stty -icanon -echo min 1 time 0
    printf '\e[?25l'
    while true
        set -l sp (__tcz_scratch_pane)
        set -l has 0; test -n "$sp[1]"; and set has 1
        printf '\e[2J\e[H'
        __tcz_modal_legend $has
        set -l action (__tcz_modal_action (__tcz_modal_readkey) $has)
        set -l verdict (__tcz_modal_run $action "$client")
        if test "$verdict" = color
            stty "$saved" 2>/dev/null
            printf '\e[2J\e[H bar color (css), empty cancels: '
            set -l val ''
            read -l val
            stty -icanon -echo min 1 time 0 2>/dev/null
            test -n "$val"; and fish -c 'tmux-lives setup color $argv[1]' "$val" 2>/dev/null
        else if test "$verdict" = close
            break
        end
    end
    functions -e __tcz_modal_cleanup
    set -e __tcz_modal_saved
    stty $saved
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
    else
        # Baseline path default mirrors __tmux_lives_baseline_path in conf.d/tmux-lives-install.fish — keep in sync.
        set -l baseline (set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf")
        test -e $baseline; and tmux source-file $baseline 2>/dev/null
    end
    return 0
end

function __tcz_recolor --argument-names color --description 'emit the ShellFish bar-color OSC to every attached ShellFish client (so setup color updates tabs without a reattach)'
    test -n "$color"; or return 0
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; and __tcz_emit_barcolor $tty $color
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

function __tcz_scratch_orient --argument-names dir --description 'recreate the scratch pane with a new orientation (h=side-by-side, w=stacked)'
    set -l p (__tcz_scratch_pane)
    test -n "$p[1]"; or return 0
    set -l flag -h; test "$dir" = w; and set flag -v
    tmux kill-pane -t "$p[1]" 2>/dev/null
    tmux split-window $flag -p 33 2>/dev/null
    tmux set -p @tmux_lives_scratch 1 2>/dev/null
    return 0
end

function __tcz_main
    switch "$argv[1]"
        case categorize
            __tcz_categorize
        case tick
            __tcz_categorize >/dev/null 2>&1
            return 0
        case overview
            __tcz_overview
        case menu
            __tcz_menu
        case open-switcher
            __tcz_open_switcher $argv[2..]
        case popup
            __tcz_popup $argv[2..]
        case scratch
            __tcz_scratch $argv[2..]
        case modal
            __tcz_modal $argv[2..]
        case modal-menu
            __tcz_modal_menu $argv[2..]
        case recolor
            __tcz_recolor $argv[2..]
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
