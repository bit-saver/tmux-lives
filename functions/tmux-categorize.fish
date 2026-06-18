#!/usr/bin/env fish
# tmux-categorize: live-state session classification, naming, overview, menu, ghost-detach.
# Runs under `fish --no-config` (fast, no conf.d side effects — safe inside tmux #()).
# Spec: docs/superpowers/specs/2026-06-11-tmux-categorized-sessions-design.md
# Subcommands: categorize | tick | overview | menu | open-switcher <client> | fzfpick <client> | claim <pane> <raw> <cwd> | ghosts <session> | switch <session> <client> | commandeer <client> <session> | slug <text...>
# Tests source this file with tmux_categorize_test set, which suppresses the dispatcher.

# Shell list — MUST match __tmux_session_is_idle in conf.d/tmux.fish (test-enforced).
set -g __tcz_shells fish bash sh zsh dash
set -g __tcz_self (path resolve (status filename))

function __tcz_slugify --description 'argv -> tmux-safe session name ([A-Za-z0-9-])'
    # Callers must pass slugs with -- / -t "=$slug" style protection when handing them to tmux
    # (slug never starts with - after trim, but the contract should be explicit).
    set -l s (string join ' ' -- $argv)
    set s (string replace -ra '[^A-Za-z0-9-]+' '-' -- "$s")
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

function __tcz_cmdline_name --description 'pane_pid -> claude --name value (checks pid + direct children)'
    test -n "$argv[1]"; or return
    # A pid could be recycled between pgrep and the comm read; worst case is a harmless miss.
    for pid in $argv[1] (pgrep -P $argv[1] 2>/dev/null)
        test "$(cat /proc/$pid/comm 2>/dev/null)" = claude; or continue
        set -l cmd (string split0 < /proc/$pid/cmdline 2>/dev/null | string join ' ')
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
    # tmux runs string commands via `sh -c`; a script named claude then reports
    # pane_current_command=sh while the kernel comm is claude.
    test "$argv[1]" = sh; or return 1
    test "$(cat /proc/$argv[2]/comm 2>/dev/null)" = claude
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

function __tcz_fzf_lines --argument-names current --description 'overview lines -> session\tANSI-label for fzf: full-width colored separators (empty session field) + rows with right-aligned, uniformly-dimmed [current]/[attached] markers'
    set -l TAB (printf '\t')
    set -l RST (printf '\e[0m')
    set -l DIM (printf '\e[2m')               # markers: dim grey, same for current + attached
    set -l YEL (printf '\e[38;5;179m')        # current session name: dim yellow (143 read as green)
    # Pass 1: collect rows; measure the widest display name so markers align in one column.
    set -l rs; set -l rc; set -l rn; set -l rm; set -l rcur
    set -l maxn 0
    while read -l line
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        set -l nm "$f[5]"; set -l mk ''; set -l cur 0
        if test -n "$current"; and test "$f[1]" = "$current"
            set cur 1; set nm "▸ $f[5]"; set mk '[current]'
        else if test "$f[3]" = 1
            set mk '[attached]'
        end
        set -a rs "$f[1]"; set -a rc "$f[2]"; set -a rn "$nm"; set -a rm "$mk"; set -a rcur $cur
        set -l w (string length -- "$nm")
        test $w -gt $maxn; and set maxn $w
    end
    set -l markcol (math $maxn + 2)
    # Pass 2: separators use a long rule fzf truncates at the pane edge (full width);
    # markers are padded to markcol (computed on the plain name; ANSI is zero-width).
    set -l group ''
    for i in (seq (count $rs))
        if test "$rc[$i]" != "$group"
            set group "$rc[$i]"
            set -l c 208
            test "$group" = running; and set c 6
            test "$group" = general; and set c 2
            set -l hdr (printf '\e[1;38;5;%sm' $c)
            printf '%s%s── %s %s%s\n' $TAB "$hdr" "$group" (string repeat -n 160 ─) "$RST"
        end
        set -l nm "$rn[$i]"
        set -l pad (math "$markcol - "(string length -- "$nm"))
        test $pad -lt 1; and set pad 1
        set -l gap (string repeat -n $pad ' ')
        set -l label "$nm$gap"
        test "$rcur[$i]" = 1; and set label "$YEL$nm$RST$gap"
        set -l mk "$rm[$i]"
        test -n "$mk"; and set mk "$DIM$mk$RST"
        printf '%s%s%s%s\n' "$rs[$i]" $TAB "$label" "$mk"
    end
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

function __tcz_switch --argument-names session client --description 'switch <session> <client>: ghost-detach, then switch the choosing client'
    test -n "$session"; or return 0
    __tcz_ghosts "$session"
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

function __tcz_open_switcher --argument-names client --description 'open the switcher: fzf display-popup if available, else display-menu'
    if command -q fzf
        tmux display-popup -E -w 80% -h 70% -- fish --no-config $__tcz_self fzfpick "$client"
    else
        __tcz_menu
    end
end

function __tcz_fzfpick --argument-names client --description 'fzf session picker (runs inside the display-popup); switch on accept'
    __tcz_categorize >/dev/null 2>&1
    set -l current (tmux display-message -c "$client" -p '#{session_name}' 2>/dev/null)
    test -n "$current"; or set current (tmux display-message -p '#{session_name}' 2>/dev/null)
    set -l TAB (printf '\t')
    set -l choice (__tcz_overview | __tcz_fzf_lines "$current" | fzf \
        --ansi --delimiter $TAB --with-nth 2 --layout=reverse-list \
        --prompt 'switch ❯ ' --pointer '▌' --info inline \
        --preview 'tmux capture-pane -ep -t {1}' \
        --preview-window 'right,62%,border-left' --no-scrollbar \
        --color 'bg:-1,fg:-1,hl:208,fg+:15,bg+:236,hl+:208,pointer:208,prompt:81,info:240,border:240,gutter:-1')
    test -n "$choice"; or return 0
    set -l sess (string split -m 1 $TAB -- $choice)[1]
    test -n "$sess"; or return 0    # separator row -> no-op
    __tcz_switch "$sess" "$client"
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
            __tcz_open_switcher $argv[2]
        case fzfpick
            __tcz_fzfpick $argv[2]
        case claim
            __tcz_claim $argv[2..]
        case ghosts
            __tcz_ghosts $argv[2]
        case switch
            __tcz_switch $argv[2..]
        case commandeer
            __tcz_commandeer $argv[2..]
        case slug
            __tcz_slugify $argv[2..]
        case '*'
            echo "usage: tmux-categorize.fish categorize|tick|overview|menu|open-switcher|fzfpick|claim|ghosts|switch|commandeer|slug" >&2
            return 1
    end
end

if not set -q tmux_categorize_test
    test (count $argv) -gt 0; or return 0
    __tcz_main $argv
end
