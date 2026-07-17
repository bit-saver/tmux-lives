#!/usr/bin/env fish
# Tests for functions/tmux-categorize.fish (auto-tmux v2 categorizer).
# Run: fish tests/test-tmux-categorize.fish
# Pure tests source the script with tmux_categorize_test set (main dispatch suppressed).
# Integration tests use an isolated socket via a PATH shim (propagates to subprocesses)
# plus a fake `claude` binary so the real detection path is exercised.

set -g FAIL 0
set -g sock test-tcz-$fish_pid
set -g shimdir /tmp/tcz-shim-$fish_pid
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish

mkdir -p $shimdir
printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $sock > $shimdir/tmux
chmod +x $shimdir/tmux
# Fake claude: compiled binary so pane_current_command shows "claude" (not "sh"),
# stays running, and /proc/pid/cmdline carries all args (incl. --name ...).
command -q gcc; or begin; echo 'ABORT: gcc required to build the fake claude'; exit 1; end
printf '#include <unistd.h>\nint main(void){while(1)sleep(1);return 0;}\n' | \
    gcc -x c - -o $shimdir/claude
set -gx PATH $shimdir $PATH
# shimdir/tmux + shimdir/claude are used by integration tests added in later tasks.

function t --description 'assert: t <desc> <expected> <actual>'
    if test "$argv[2]" = "$argv[3]"
        echo "ok   - $argv[1]"
    else
        echo "FAIL - $argv[1]: expected [$argv[2]] got [$argv[3]]"
        set -g FAIL 1
    end
end
function cleanup
    command tmux -L $sock kill-server 2>/dev/null
    rm -f /tmp/tmux-(id -u)/$sock
end

set -g tmux_categorize_test 1
source $plugindir/functions/tmux-categorize.fish

# Reset the test server to a single fresh session, race-free. A `new-session` issued
# right after `kill-server` can land on the still-dying old server (which then exits —
# seen as "server exited unexpectedly"), so the new session/pane vanishes. Poll until
# the old server is actually gone before creating the new one (condition, not sleep).
function fresh_server --description 'kill the test server, wait until it is gone, then create one fresh detached session'
    command tmux -L $sock kill-server 2>/dev/null
    for i in (seq 50)
        command tmux -L $sock list-sessions >/dev/null 2>&1; or break
    end
    command tmux -L $sock new-session -d -x 120 -y 40
end

# ---------------------------------------------------------------------
# Pure-ish: __tcz_pane_is_claude (cmd fast-path + sh/comm fallback)
# ---------------------------------------------------------------------
t "is_claude: cmd claude -> yes" "0" (__tcz_pane_is_claude claude 1; echo $status)
$shimdir/claude --enable-auto-mode &
set -l icpid $last_pid
sleep 0.2
t "is_claude: sh wrapper + comm -> yes" "0" (__tcz_pane_is_claude sh $icpid; echo $status)
t "is_claude: fish pane -> no" "1" (__tcz_pane_is_claude fish $icpid; echo $status)
kill $icpid 2>/dev/null
# macOS: the native installer's claude is a version-named binary
# (~/.local/share/claude/versions/X.Y.Z), so tmux reports pane_current_command as
# the version (e.g. 2.1.185), NOT 'claude' — and the real claude process is a CHILD
# of the pane shell. Detection must walk the pane pid's children (comm stays claude).
fish -c "$shimdir/claude --enable-auto-mode --name Mac Ver & sleep 3" &
set -l macpid $last_pid
sleep 0.4
t "is_claude: versioned cmd + claude child -> yes" "0" (__tcz_pane_is_claude 2.1.185 $macpid; echo $status)
kill $macpid 2>/dev/null
pkill -f 'Mac Ver' 2>/dev/null

# ---------------------------------------------------------------------
# ShellFish client detection (fake-environ seam + real /proc)
# ---------------------------------------------------------------------
set -g tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
t "is_shellfish: exact env -> yes" "0" (__tcz_client_is_shellfish 999; echo $status)
set -g tmux_lives_fake_environ "TERM=xterm-256color" "HOME=/home/x"
t "is_shellfish: no LC_TERMINAL -> no" "1" (__tcz_client_is_shellfish 999; echo $status)
set -g tmux_lives_fake_environ "TERM=xterm" "LC_TERMINAL=ShellFish" "PWD=/tmp"
t "is_shellfish: among many -> yes" "0" (__tcz_client_is_shellfish 999; echo $status)
set -g tmux_lives_fake_environ "LC_TERMINAL_VERSION=42"
t "is_shellfish: VERSION key only -> no" "1" (__tcz_client_is_shellfish 999; echo $status)
set -e tmux_lives_fake_environ
# real /proc read works (HOME is always present). Deliberately NOT asserting on
# LC_TERMINAL of self: the user's own ~/.tmux.conf global default can legitimately
# put LC_TERMINAL=ShellFish in a tmux pane's environ, which would flake a self-check.
t "pid_environ: reads real /proc" 1 (string match -q '*HOME=*' -- (__tcz_pid_environ $fish_pid); and echo 1; or echo 0)

# ---------------------------------------------------------------------
# Bar-color emission (deterministic bytes to a target path)
# ---------------------------------------------------------------------
set -l bcf /tmp/tcz-bar-$fish_pid
rm -f $bcf
__tcz_emit_barcolor $bcf "#1f6feb"
set -l bcwant (printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' '#1f6feb' | base64))
t "barcolor: exact escape bytes" "$bcwant" (cat $bcf)
rm -f $bcf
__tcz_emit_barcolor $bcf ""
t "barcolor: empty color writes nothing" "0" (test ! -s $bcf; echo $status)
rm -f $bcf
set -l bclong (string repeat -n 70 a)
__tcz_emit_barcolor $bcf $bclong
set -l bclongwant (printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' $bclong | base64 | string join ''))
t "barcolor: long color = single OSC" "$bclongwant" (cat $bcf)
rm -f $bcf

# --- title builders ---
set -g tmux_lives_hostname macwork
t "hostname uses the seam" macwork (__tcz_hostname)
set -g __tcz_oldhome $HOME; set -g HOME /home/x
t "dir_display basenames a path" tmux-lives (__tcz_dir_display /home/x/workspace/tmux-lives)
t "dir_display shows ~ for HOME" '~' (__tcz_dir_display /home/x)
set -g HOME $__tcz_oldhome; set -e __tcz_oldhome
t "format_title plain" "rocket: neurotto" (__tcz_format_title rocket neurotto 0)
t "format_title with claude" "macwork: tmux-lives (C)" (__tcz_format_title macwork tmux-lives 1)
set -e tmux_lives_hostname

# ---------------------------------------------------------------------
# on-attach: ShellFish branch colors the tty; non-ShellFish sources baseline
# ---------------------------------------------------------------------
set -l oaf /tmp/tcz-oa-$fish_pid
# ShellFish client -> color written to the tty path
rm -f $oaf
set -g tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_on_attach 999 $oaf "#abcdef"
t "on-attach: ShellFish writes color" "0" (test -s $oaf; echo $status)
# non-ShellFish client -> NO color written to the tty
rm -f $oaf
set -g tmux_lives_fake_environ "TERM=xterm"
__tcz_on_attach 999 $oaf "#abcdef"
t "on-attach: non-ShellFish writes no color" "0" (test ! -s $oaf; echo $status)
# non-ShellFish client -> the baseline file IS sourced (integration via the test socket)
set -l oabase /tmp/tcz-oa-baseline-$fish_pid.conf
echo 'set -g @tl_oa sourced' > $oabase
set -g tmux_lives_baseline_conf $oabase
command tmux -L $sock new-session -d -s oa 2>/dev/null
__tcz_on_attach 999 /dev/null ''
t "on-attach: non-ShellFish sources baseline" "sourced" (command tmux -L $sock show -gv @tl_oa 2>/dev/null)
command tmux -L $sock kill-server 2>/dev/null
# dispatch path: real `fish --no-config <cat> on-attach …` (seam must be EXPORTED to reach the child)
set -l oadf /tmp/tcz-oa-dispatch-$fish_pid
rm -f $oadf
set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
fish --no-config $plugindir/functions/tmux-categorize.fish on-attach 999 $oadf "#0a0a0a"
t "on-attach dispatch: ShellFish colors tty" "0" (test -s $oadf; echo $status)
set -e tmux_lives_fake_environ
rm -f $oadf
set -e tmux_lives_fake_environ
set -e tmux_lives_baseline_conf
rm -f $oaf $oabase

# ---------------------------------------------------------------------
# tabs-role resolution (v3 Phase 2): __tcz_tab_color resolves the live
# @tmux_lives_tabs_color option (seeded by the themed fragment, tabs-role
# sample when themed / '' under the legacy look) over the baked-in
# fallback; __tcz_recolor/__tcz_on_attach route through it.
# ---------------------------------------------------------------------
fresh_server
command tmux set -g -u @tmux_lives_tabs_color 2>/dev/null
t "tab_color falls back when option unset" "#999999" (__tcz_tab_color "#999999")
command tmux set -g @tmux_lives_tabs_color '#6e6e22' 2>/dev/null
t "tab_color prefers the live tabs role" "#6e6e22" (__tcz_tab_color "#999999")
command tmux set -g @tmux_lives_tabs_color '' 2>/dev/null
t "tab_color: empty option falls back" "#999999" (__tcz_tab_color "#999999")
command tmux set -g -u @tmux_lives_tabs_color 2>/dev/null
command tmux -L $sock kill-server 2>/dev/null
t "recolor resolves via tab_color" yes (string match -q '*__tcz_tab_color*' -- (functions __tcz_recolor | string collect); and echo yes; or echo no)
t "on-attach resolves via tab_color" yes (string match -q '*__tcz_tab_color*' -- (functions __tcz_on_attach | string collect); and echo yes; or echo no)

# ---------------------------------------------------------------------
# Pure: name helpers
# ---------------------------------------------------------------------
t "slug: spaces -> dashes"        "TMUX-Setup-2"      (__tcz_slugify "TMUX Setup 2")
t "slug: dots/colons stripped"    "a-b-c"             (__tcz_slugify "a.b:c")
t "slug: trims edge dashes"       "mid-dle"           (__tcz_slugify "  mid dle! ")
t "slug: empty -> session"        "session"           (__tcz_slugify "...")
t "title: glyph stripped"         "TMUX Setup 2"      (__tcz_title_name "✳ TMUX Setup 2")
t "title: spinner stripped"       "TMUX Setup 2"      (__tcz_title_name "⠂ TMUX Setup 2")
t "title: task suffix dropped"    "Tasker Editor 14"  (__tcz_title_name "✳ Tasker Editor 14 - Reword task")
t "title: garbage -> empty"       ""                  (__tcz_title_name "Gi=1,a=q;")
t "free_gen: empty -> gen-1"        "gen-1" (__tcz_free_gen)
t "free_gen: gen-1 taken -> gen-2"  "gen-2" (__tcz_free_gen gen-1)
t "free_gen: skips gaps"            "gen-2" (__tcz_free_gen gen-1 gen-3)
t "owned: gen-N"                    "0" (__tcz_owned gen-2; echo $status)
t "owned: legacy numeric"           "0" (__tcz_owned 4; echo $status)
t "owned: hand name (no stamp)"     "1" (__tcz_owned mydev; echo $status)
t "unique: free name unchanged"   "lnav"              (__tcz_unique lnav work 0)
t "unique: collision suffixed"    "lnav-2"            (__tcz_unique lnav lnav work)
t "unique: counts up"             "lnav-3"            (__tcz_unique lnav lnav lnav-2)
t "slug: already clean -> unchanged"   "lnav"          (__tcz_slugify "lnav")
t "slug: multi-arg joined"             "foo-bar"       (__tcz_slugify foo bar)
t "slug: leading dash stripped"        "foo"           (__tcz_slugify "-foo")
t "slug: ' - ' collapses to one dash"  "Pingy-Android-Part-12" (__tcz_slugify "Pingy Android - Part 12")
t "slug: repeated dashes collapse"     "a-b"           (__tcz_slugify "a -- b")
t "title: variation-selector glyph ok" "TMUX Setup 2"  (__tcz_title_name "✳️ TMUX Setup 2")
t "unique: desired ending in -2"       "lnav-2-2"      (__tcz_unique lnav-2 lnav-2)

# ---------------------------------------------------------------------
# __tcz_cmdline_name: --name extraction from a live (fake) claude process
# ---------------------------------------------------------------------
$shimdir/claude --enable-auto-mode --name TMUX Setup 2 &
set -l fakepid $last_pid
sleep 0.2
t "cmdline: --name extracted (multi-word)" "TMUX Setup 2" (__tcz_cmdline_name $fakepid)
kill $fakepid 2>/dev/null
$shimdir/claude --enable-auto-mode &
set -l fakepid2 $last_pid
sleep 0.2
t "cmdline: no --name -> empty" "" (__tcz_cmdline_name $fakepid2)
kill $fakepid2 2>/dev/null
t "cmdline: bogus pid -> empty" "" (__tcz_cmdline_name 99999999)

$shimdir/claude --enable-auto-mode --name Flag Tail --resume &
set -l fakepid3 $last_pid
sleep 0.2
t "cmdline: trailing flags stripped" "Flag Tail" (__tcz_cmdline_name $fakepid3)
kill $fakepid3 2>/dev/null
# child path: pass the PARENT pid; claude is its direct child (pgrep -P branch)
fish -c "$shimdir/claude --enable-auto-mode --name Child Test & sleep 3" &
set -l parentpid $last_pid
sleep 0.4
t "cmdline: found via child pgrep" "Child Test" (__tcz_cmdline_name $parentpid)
kill $parentpid 2>/dev/null
pkill -f 'Child Test' 2>/dev/null

# ---------------------------------------------------------------------
# __tcz_snapshot (integration, isolated socket via PATH shim)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s c1 "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s r1 -c /tmp 'sleep 1000'
tmux new-session -d -s g1 -c $HOME
sleep 0.5     # let pane_current_command settle
t "snap: categories"  "c1	claude,g1	general,r1	running" \
    (__tcz_snapshot | cut -f1,2 | sort | string join ',')
t "snap: claude display from --name" "TMUX Setup 2" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f5)
t "snap: running display = command"  "sleep" \
    (__tcz_snapshot | string match -e 'r1	*' | cut -f5)
t "snap: general display = ~cwd"     "~" \
    (__tcz_snapshot | string match -e 'g1	*' | cut -f5)
t "snap: detached flag"              "0" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f3)
# display fallbacks: no --name -> gated title; unusable title -> claude-<cwd>
cleanup
mkdir -p /tmp/tcz-myproj-$fish_pid
tmux new-session -d -s c_title "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_title: -T "✳ My Work Project"
tmux new-session -d -s c_cwd -c /tmp/tcz-myproj-$fish_pid "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_cwd: -T ""
sleep 0.5
t "snap: claude display from title" "My Work Project" \
    (__tcz_snapshot | string match -e 'c_title	*' | cut -f5)
t "snap: claude display from cwd"   "claude-tcz-myproj-$fish_pid" \
    (__tcz_snapshot | string match -e 'c_cwd	*' | cut -f5)
rm -rf /tmp/tcz-myproj-$fish_pid
cleanup
t "snap: no server -> empty" "" (__tcz_snapshot | string join ',')

# ---------------------------------------------------------------------
# Boring-command deprioritization: a session whose only non-shell pane
# command is a pager/tailer (tail/less/watch/cat/more/bat) must NOT count
# as "running" — it falls through to general (dir-named). A session
# running a real program must still be categorized "running" (guard
# must not over-reach).
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-boring-$fish_pid
tmux new-session -d -s b1 -c $HOME/tcz-boring-$fish_pid 'tail -f /dev/null'
tmux new-session -d -s real1 -c $HOME/tcz-boring-$fish_pid "node -e 'setInterval(function(){}, 1000)'"
sleep 0.5
t "snap: boring command -> general (not running)" "general" \
    (__tcz_snapshot | string match -e 'b1	*' | cut -f2)
t "snap: boring display = dir basename (not tail)" "~/tcz-boring-$fish_pid" \
    (__tcz_snapshot | string match -e 'b1	*' | cut -f5)
t "snap: real program -> still running (guard doesn't over-reach)" "running" \
    (__tcz_snapshot | string match -e 'real1	*' | cut -f2)
rm -rf $HOME/tcz-boring-$fish_pid
cleanup

# ---------------------------------------------------------------------
# __tcz_categorize (integration)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0 "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s 1 'sleep 1000'
tmux new-session -d -s 2
tmux new-session -d -s handname 'sleep 1000'      # unowned non-numeric -> guard protects
sleep 0.5
__tcz_categorize
t "cat: claude renamed to slug"  "yes" (tmux has-session -t =TMUX-Setup-2 2>/dev/null; and echo yes; or echo no)
t "cat: claude stamped"          "TMUX-Setup-2" (tmux show-option -qv -t TMUX-Setup-2 @tmux_auto_name)
t "cat: running renamed to cmd"  "yes" (tmux has-session -t =sleep 2>/dev/null; and echo yes; or echo no)
t "cat: numeric general renamed to gen-N" "yes" (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
t "cat: hand-named protected"    "yes" (tmux has-session -t =handname 2>/dev/null; and echo yes; or echo no)
t "cat: idempotent (no churn)"   "" (__tcz_categorize | string join ',')

# revert: owned claude-named session whose claude died -> numeric
tmux kill-session -t =TMUX-Setup-2
tmux new-session -d -s stale-claude
tmux set-option -t stale-claude @tmux_auto_name stale-claude
__tcz_categorize
t "cat: owned idle reverts to gen-N" "gen-1" \
    (tmux list-sessions -F '#{session_name}' | string match -r '^gen-[0-9]+$' | sort -V | head -n1)

# collision: two OWNED (numeric) claude sessions with the same --name
cleanup
tmux new-session -d -s 0 "$shimdir/claude --name Same Name"
tmux new-session -d -s 1 "$shimdir/claude --name Same Name"
sleep 0.5
__tcz_categorize
t "cat: collision suffixed" "Same-Name,Same-Name-2" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
# guard: a hand-NAMED claude session is never renamed
tmux new-session -d -s myclaude "$shimdir/claude --name Steal"
sleep 0.5
__tcz_categorize
t "cat: hand-named claude protected" "yes" \
    (tmux has-session -t =myclaude 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# @tmux_lives_name: explicit display override + claimed-session no-rename
# Session name is numeric (42) rather than the brief's "dev1" example: a
# non-numeric unstamped session is already protected by the pre-existing
# __tcz_owned guard, so the no-rename assertion would pass trivially either
# way. A numeric (owned) session WOULD be slug-renamed absent the new
# claimed-skip check, so this actually exercises it.
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 42 'sleep 1000'
tmux set-option -t 42 @tmux_lives_name "Neurotto CLI"
sleep 0.5
t "snap: @tmux_lives_name overrides display" "yes" \
    (__tcz_snapshot | string match -q '42	*	Neurotto CLI'; and echo yes; or echo no)
__tcz_categorize
t "cat: claimed session keeps its tmux name" "yes" \
    (tmux has-session -t =42 2>/dev/null; and echo yes; or echo no)
t "cat: claimed session not slug-renamed" "no" \
    (tmux has-session -t "=Neurotto-CLI" 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# lifecycle: rename when claude starts in a shell pane, revert when it exits
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0
tmux send-keys -t 0 "$shimdir/claude --enable-auto-mode --name Lifecycle" Enter
sleep 0.8
__tcz_categorize
t "cat: lifecycle rename via shell pane" "yes" (tmux has-session -t =Lifecycle 2>/dev/null; and echo yes; or echo no)
t "cat: lifecycle used the fake binary" "yes" \
    (pgrep -af -- '--name Lifecycle' | string match -q "*$shimdir*"; and echo yes; or echo no)
# Kill the claude process directly (SIGTERM; C-c/SIGINT is absorbed by fish job control).
set -l lcpid (tmux list-panes -t Lifecycle -F '#{pane_pid}' 2>/dev/null)
pkill -TERM -P $lcpid 2>/dev/null; or kill -TERM $lcpid 2>/dev/null
sleep 0.5
__tcz_categorize
t "cat: lifecycle revert to gen-N" "yes" (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# __tcz_overview: claude -> running -> general, MRU within group
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s g1
tmux new-session -d -s r1 'sleep 1000'
tmux new-session -d -s c1 "$shimdir/claude --name Zed"
sleep 0.5
t "overview: group order" "claude,running,general" \
    (__tcz_overview | cut -f2 | string join ',')
cleanup

# ---------------------------------------------------------------------
# Ghosts: pure cutoff filter + live no-op safety
# ---------------------------------------------------------------------
t "ghosts_from: stale client listed"  "old"  (printf 'old\t100\nfresh\t900\n' | __tcz_ghosts_from 500 | string join ',')
t "ghosts_from: fresh kept"           ""     (printf 'fresh\t900\n' | __tcz_ghosts_from 500 | string join ',')
t "ghosts_from: junk line skipped"    ""     (printf 'bad\tnotnum\n' | __tcz_ghosts_from 500 | string join ',')
cleanup
tmux new-session -d -s lonely
t "ghosts: clientless session no-op (rc 0)" "0" (__tcz_ghosts lonely; echo $status)
# NOTE: the actual tmux detach-client branch is untestable in a headless harness
# (list-clients is always empty without a real terminal). __tcz_ghosts_from, which
# selects the candidates, is tested above; live behavior is verified at deployment.
cleanup

# ---------------------------------------------------------------------
# __tcz_menu_args (pure): overview lines -> display-menu argv triples
# ---------------------------------------------------------------------
set -l ov (printf 'Zed-1\tclaude\t1\t900\tZed\nlnav\trunning\t0\t800\tlnav\n3\tgeneral\t0\t0\t~\n')
# Collect via while-read (NOT command substitution): the header triples contain
# empty key/command lines that must survive as empty list elements.
set -l args
printf '%s\n' $ov | __tcz_menu_args | while read -l a
    set -a args "$a"
end
t "menu: 3 headers + 3 items, 3 args each" "18" (count $args)
t "menu: first header disabled (- prefix)" "-" (string sub -l 1 -- $args[1])
# Headers: color-coded (orange/cyan/green), 2-dash lead-in ("── name "),
# trailing rule to the menu width. Indicators are bracketed and
# right-aligned at a common column (widest base "lnav"=4 +2 → col 6; widest
# label "Zed   [attached]"=16; +4 key chrome → rule width 20).
t "menu: claude header orange left-anchored" "-#[fg=colour208,bold]── claude ──────────#[default]" $args[1]
t "menu: running header cyan left-anchored"  "-#[fg=cyan,bold]── running ─────────#[default]"      $args[7]
t "menu: general header green left-anchored" "-#[fg=green,bold]── general ─────────#[default]"     $args[13]
t "menu: claude label right-aligned [attached]" "Zed   [attached]" $args[4]
t "menu: numeric shortcut keys" "1" $args[5]
# Selection runs ONE run-shell -> `switch` subcommand (ghosts + switch-client with
# proper argv). Brace-quoted {=name} targets are FORBIDDEN: tmux 3.3a parses them
# as command blocks at selection time -> "unknown command: =name" in the status bar.
t "menu: item runs the switch subcommand" "yes" \
    (string match -q "*tmux-categorize.fish switch 'Zed-1' *" -- $args[6]; and echo yes; or echo no)
t "menu: item passes the choosing client" "yes" \
    (string match -q '*#{client_name}*' -- $args[6]; and echo yes; or echo no)
t "menu: no brace-quoted target (parse bug)" "no" \
    (string match -q '*{=*' -- $args[6]; and echo yes; or echo no)

# Regression: special-char (hand-named) sessions survive all quoting layers
set -l args_sq
printf "foo'bar\tclaude\t0\t900\tfoo'bar\n" | __tcz_menu_args | while read -l a
    set -a args_sq "$a"
end
t "menu: quote-name switch arg sh-escaped" "yes" \
    (string match -q "*switch 'foo'\\''bar' *" -- $args_sq[6]; and echo yes; or echo no)
t "menu: quote-name no braces either" "no" \
    (string match -q '*{=*' -- $args_sq[6]; and echo yes; or echo no)

# Current-session marker: passed as an argument so the builder stays pure.
set -l ov_cur (printf 'Zed-1\tclaude\t1\t900\tZed\nlnav\trunning\t0\t800\tlnav\n')
set -l args_cur
printf '%s\n' $ov_cur | __tcz_menu_args Zed-1 | while read -l a
    set -a args_cur "$a"
end
t "menu: current gets yellow right-aligned [current]" "#[fg=colour143]▸ Zed  [current]#[default]" $args_cur[4]
t "menu: non-current rows unchanged"    "lnav"                             $args_cur[10]
set -l args_bogus
printf '%s\n' $ov_cur | __tcz_menu_args nosuch | while read -l a
    set -a args_bogus "$a"
end
t "menu: unknown current leaves labels alone" "Zed   [attached]" $args_bogus[4]

# New style: 2-dash lead-in header + muted-yellow current marker.
set -l TAB (printf '\t')
set -l ov_style "neuro"$TAB"claude"$TAB"0"$TAB"100"$TAB"neuro
mydev"$TAB"general"$TAB"1"$TAB"50"$TAB"mydev"
set -l margs (printf '%s\n' $ov_style | __tcz_menu_args neuro | string join "\n")
t "menu: 2-dash lead-in header"  "yes" (string match -q '*── claude *' -- "$margs"; and echo yes; or echo no)
t "menu: header rule to edge"    "yes" (string match -q '*── claude ────*' -- "$margs"; and echo yes; or echo no)
t "menu: current uses yellow"    "yes" (string match -q '*#[fg=colour143]*' -- "$margs"; and echo yes; or echo no)
t "menu: current not dimmed"     "no"  (string match -q '*#\[dim\]*' -- "$margs"; and echo yes; or echo no)

# ---------------------------------------------------------------------
# __tcz_claim (integration): instant claude rename from preexec data
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "My Project" /tmp
t "claim: renamed from raw name" "yes" (tmux has-session -t =My-Project 2>/dev/null; and echo yes; or echo no)
t "claim: stamped"               "My-Project" (tmux show-option -qv -t My-Project @tmux_auto_name)
__tcz_claim $pane "" /tmp/someproj
t "claim: empty raw -> claude-cwd" "yes" (tmux has-session -t =claude-someproj 2>/dev/null; and echo yes; or echo no)
tmux rename-session -t =claude-someproj handpick
__tcz_claim $pane "Steal Attempt" /tmp
t "claim: guard protects hand-rename" "yes" (tmux has-session -t =handpick 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# Dispatcher + tick silence (subprocess — exercises the real entrypoint)
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s 0 'sleep 1000'
t "main: tick emits nothing"  "" (fish --no-config $plugindir/functions/tmux-categorize.fish tick | string join ',')
t "main: tick renamed via subprocess" "yes" (tmux has-session -t =sleep 2>/dev/null; and echo yes; or echo no)
t "main: slug subcommand" "prod-debug" (fish --no-config $plugindir/functions/tmux-categorize.fish slug "prod:debug")
# switch subcommand: headless (no client) must degrade silently, rc 0
cleanup
tmux new-session -d -s sw1
t "switch: headless degrades silently (rc 0)" "0" (__tcz_switch sw1 ''; echo $status)
cleanup
t "main: bad subcommand rc=1" "1" (fish --no-config $plugindir/functions/tmux-categorize.fish bogus 2>/dev/null; echo $status)
cleanup

# ---------------------------------------------------------------------
# __tcz_pick_general + __tcz_commandeer (ShellFish springboard bounce).
# Headless caveat: switch-client always fails without a real client, which is
# exactly what lets us pin the failure-path guarantees (springboard preserved,
# fallback session cleaned up). The success path is verified live.
# ---------------------------------------------------------------------
cleanup
tmux new-session -d -s busy 'sleep 1000'
tmux new-session -d -s shellfish-8
sleep 0.3
t "newgen: creates smallest-free general" "gen-1" (__tcz_new_general)
t "pickgen: MRU detached general, springboard excluded" "gen-1" (__tcz_pick_general shellfish-8)
t "commandeer: non-shellfish name no-op" "0" (__tcz_commandeer /dev/null busy; echo $status)
tmux new-session -d -s shellfish-9 'sleep 1000'
sleep 0.3
__tcz_commandeer /dev/null shellfish-9
t "commandeer: busy shellfish untouched" "yes" (tmux has-session -t =shellfish-9 2>/dev/null; and echo yes; or echo no)
__tcz_commandeer /dev/pts/nonexistent shellfish-8
t "commandeer: failed switch keeps springboard" "yes" (tmux has-session -t =shellfish-8 2>/dev/null; and echo yes; or echo no)
t "commandeer: target untouched on failed switch" "yes" (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
tmux kill-session -t gen-1
__tcz_commandeer /dev/pts/nonexistent shellfish-8
t "commandeer: fallback session cleaned up on failed switch" "busy,shellfish-8,shellfish-9" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
cleanup

# ---------------------------------------------------------------------
# popup switcher wiring (the pure render helpers are covered by
# tests/test-tmux-popup.fish; here we assert the dispatch + entry points)
# ---------------------------------------------------------------------
t "no leftover __tcz_fzf_lines" absent (functions -q __tcz_fzf_lines; and echo present; or echo absent)
t "no leftover __tcz_fzfpick"   absent (functions -q __tcz_fzfpick; and echo present; or echo absent)

# open-switcher opens a display-popup running the `popup` subcommand for the client.
# Shim tmux: make `list-commands` advertise display-popup (so the capability
# probe passes), and echo everything else so nothing actually launches.
set -g sw_shim /tmp/tcz-sw-$fish_pid
mkdir -p $sw_shim
printf '#!/bin/sh\ncase "$*" in *list-commands*) echo display-popup;; *) printf "TMUX"; printf "|%%s" "$@"; echo;; esac\n' > $sw_shim/tmux; chmod +x $sw_shim/tmux
set -g sw_path_save $PATH
set -gx PATH $sw_shim $PATH
set -g sw_out (__tcz_open_switcher c1)
set -gx PATH $sw_path_save
t "open-switcher uses display-popup" yes (string match -q '*display-popup*' -- "$sw_out"; and echo yes; or echo no)
t "open-switcher runs popup subcmd"  yes (string match -q '*|popup|c1*' -- "$sw_out"; and echo yes; or echo no)
set -gx PATH $sw_shim $PATH
set -g sw_take (__tcz_open_switcher c1 --take)
set -gx PATH $sw_path_save
t "open-switcher threads --take (separate token)" yes (string match -q '*|popup|c1|--take*' -- "$sw_take"; and echo yes; or echo no)
rm -rf $sw_shim

# dispatcher routes `popup`, not `fzfpick`
set -g main_src (functions __tcz_main | string collect)
t "dispatcher has popup case"      yes (string match -q '*case popup*' -- "$main_src"; and echo yes; or echo no)
t "dispatcher dropped fzfpick"     no  (string match -q '*fzfpick*' -- "$main_src"; and echo yes; or echo no)
t "dispatcher has new-general case" yes (string match -q '*case new-general*' -- "$main_src"; and echo yes; or echo no)

# C1 functional: new-general subcommand via the real dispatcher creates a gen-N session
cleanup
tmux new-session -d -s existing
set -l ng_out (fish --no-config $plugindir/functions/tmux-categorize.fish new-general)
t "new-general: prints a gen-N name"    yes (string match -q 'gen-*' -- "$ng_out"; and echo yes; or echo no)
t "new-general: session actually exists" yes (tmux has-session -t "=$ng_out" 2>/dev/null; and echo yes; or echo no)
cleanup

# ---------------------------------------------------------------------
# The shell list must match __tmux_session_is_idle in conf.d/tmux.fish.
# ---------------------------------------------------------------------
set -l confd_list (string match -r 'contains -- \$cmd ([a-z ]+); or return' < $plugindir/conf.d/tmux.fish)[2]
t "shell lists in sync" "$__tcz_shells" "$confd_list"

# ---------------------------------------------------------------------
# Portable pid inspection (B): /proc and ps branches must agree on Linux
# ---------------------------------------------------------------------
t "pid_comm /proc -> fish"      "fish" (__tcz_pid_comm $fish_pid)
t "pid_cmdline /proc has fish"  "1"    (string match -q '*fish*' -- (__tcz_pid_cmdline $fish_pid); and echo 1; or echo 0)
set -g tcz_force_ps 1
t "pid_comm ps -> fish"         "fish" (__tcz_pid_comm $fish_pid)
t "pid_cmdline ps has fish"     "1"    (string match -q '*fish*' -- (__tcz_pid_cmdline $fish_pid); and echo 1; or echo 0)
set -e tcz_force_ps
t "pid_comm empty pid -> empty" ""     (__tcz_pid_comm "")
# Regression (macOS): a login shell's `ps -o comm=` starts with a dash ("-fish").
# `path basename` must get `--` or fish parses "-fish" as an option and errors,
# so __tcz_pid_comm returns empty and claude detection on the pane shell breaks.
set -g psshim /tmp/tcz-psshim-$fish_pid
mkdir -p $psshim
printf '#!/bin/sh\nprintf "%%s\\n" -fish\n' > $psshim/ps
chmod +x $psshim/ps
set -g ps_path_save $PATH
set -gx PATH $psshim $PATH
set -g tcz_force_ps 1
t "pid_comm: dash-prefixed comm survives" "-fish" (__tcz_pid_comm 12345 2>/dev/null)
set -e tcz_force_ps
set -gx PATH $ps_path_save
rm -rf $psshim

# ---------------------------------------------------------------------
# Regression: fisher SOURCES this file during install/update. A top-level
# `return` in the sourced file propagates out of fisher's OWN function and
# aborts the install (no post-install message, no fisher summary, files copied
# but fish_plugins not committed). Sourcing it inside a function — clean
# subshell so tmux_categorize_test is unset and argv is empty, exactly like
# fisher — MUST NOT abort the caller. (--no-config keeps the assertion from
# capturing interactive-config startup escapes, e.g. ShellFish's settoolbar OSC.)
# ---------------------------------------------------------------------
t "fisher-safe: sourcing categorizer doesn't abort caller" "CONTINUED" \
    (fish --no-config -c "function f; source $plugindir/functions/tmux-categorize.fish; echo CONTINUED; end; f")

# ---------------------------------------------------------------------
# scratch split toggle (uses the PATH tmux shim -> isolated -L $sock)
# ---------------------------------------------------------------------
fresh_server
__tcz_scratch
t "scratch create -> one marked pane" 1 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
t "scratch_pane echoes a pane id" yes (string match -qr '^%' -- (__tcz_scratch_pane); and echo yes; or echo no)
t "scratch create -> marked pane is active" 1 (command tmux -L $sock list-panes -F '#{?#{&&:#{pane_active},#{==:#{@tmux_lives_scratch},1}},1,}' | grep -c '^1$')
__tcz_scratch
t "scratch remove -> no marked panes" 0 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
t "scratch remove -> back to one pane" 1 (command tmux -L $sock list-panes | wc -l | string trim)
# orientation: recreate stacked, still exactly one marked pane
__tcz_scratch
__tcz_scratch_orient w
t "scratch_orient keeps one marked pane" 1 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
command tmux -L $sock kill-server 2>/dev/null
# split width: 45% (source-guard, live split-window is manual smoke)
t "scratch splits at 45%" 1 (functions __tcz_scratch | string match -q '*split-window*-p 45*'; and echo 1; or echo 0)
t "scratch orient splits at 45%" 1 (functions __tcz_scratch_orient | string match -q '*-p 45*'; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# launcher dispatch (__tcz_modal_run) — single-shot, close-then-run
# ---------------------------------------------------------------------
fresh_server
t "run scratch creates a marked pane" 1 (__tcz_modal_run scratch ''; command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
fresh_server
t "run categorize runs (no crash)" 0 (__tcz_modal_run categorize ''; echo $status)
t "run close is a no-op" 0 (__tcz_modal_run close ''; echo $status)
t "run picker uses deferred run-shell -b" yes (string match -q '*run-shell -b*open-switcher*' -- (functions __tcz_modal_run | string collect); and echo yes; or echo no)
command tmux -L $sock kill-server 2>/dev/null
# loop-free launcher wiring (interactive popup is runtime-verified)
set -g MSRC (functions __tcz_modal | string collect)
t "modal reads one key (no while loop)" yes (string match -q '*__tcz_modal_readkey*' -- "$MSRC"; and string match -q '*while true*' -- "$MSRC"; and echo no; or echo yes)
t "modal draws legend" yes (string match -q '*__tcz_modal_legend*' -- "$MSRC"; and echo yes; or echo no)
t "modal dispatches via run" yes (string match -q '*__tcz_modal_run*' -- "$MSRC"; and echo yes; or echo no)

# dispatch smoke test: modal-menu wiring in __tcz_main
set -g MAINSRC (functions __tcz_main | string collect)
t "main dispatches modal" yes (string match -q '*case modal*' -- "$MAINSRC"; and echo yes; or echo no)
t "main dispatches modal-menu" yes (string match -q '*modal-menu*' -- "$MAINSRC"; and echo yes; or echo no)
t "main dispatches scratch" yes (string match -q '*case scratch*' -- "$MAINSRC"; and echo yes; or echo no)

# ---------------------------------------------------------------------
# M-m modal "k" theme entry (Task 6): opens the theme picker (the verb itself
# lands in Task 8), mirroring picker/bar color's deferred-popup pattern
# ---------------------------------------------------------------------
t "modal action k -> theme" theme (__tcz_modal_action k)
t "modal readkey byte 6b (k) -> k" k (printf 'k' | __tcz_modal_readkey)
t "modal k opens the theme picker (deferred, own popup)" yes \
    (string match -q '*display-popup -B -E -w 52 -h 26*theme-picker*' -- (functions __tcz_modal_run | string collect); and echo yes; or echo no)
set -g LEGEND (__tcz_modal_legend 0 M-m M-t M-r M-s | string collect)
t "modal legend names the theme" yes (string match -q '*k theme*' -- "$LEGEND"; and echo yes; or echo no)
# display-menu is the no-display-popup fallback for tmux builds WITHOUT
# display-popup — so a theme row that itself opens a display-popup could never
# work there (Task 8 review carry-over). Dropped from the menu; the CLI
# (`tmux-lives setup theme list`/knobs) is the no-popup surface instead.
set -g MENUARGS (__tcz_modal_menu_args | string collect)
t "menu_args no longer offers a theme row (no-display-popup fallback can't use it)" no \
    (string match -q '*theme*theme-picker*' -- "$MENUARGS"; and echo yes; or echo no)

# ---------------------------------------------------------------------
# recolor: emit the ShellFish OSC to attached ShellFish clients
# ---------------------------------------------------------------------
set -g tt1 /tmp/tcz-tty1-$fish_pid; set -g tt2 /tmp/tcz-tty2-$fish_pid
rm -f $tt1 $tt2; touch $tt1 $tt2
function tmux
    if test "$argv[1]" = list-clients
        printf '111\t%s\n222\t%s\n' "$tt1" "$tt2"
    else
        command tmux $argv
    end
end
set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_recolor '#1f6feb'
t "recolor emits OSC to shellfish client 1" yes (test -s $tt1; and echo yes; or echo no)
t "recolor emits OSC to shellfish client 2" yes (test -s $tt2; and echo yes; or echo no)
t "recolor OSC carries settoolbar" yes (string match -q '*settoolbar*' -- (cat $tt1 | string collect); and echo yes; or echo no)
# non-shellfish env -> no emit
rm -f $tt1; touch $tt1
set -gx tmux_lives_fake_environ "TERM=xterm"
__tcz_recolor '#1f6feb'
t "recolor skips non-shellfish client" no (test -s $tt1; and echo yes; or echo no)
# tick re-emits the stored bar color (self-heal). Stub __tcz_categorize so the
# tick verb does NOT run the full categorize against the live server; reuse the
# recolor block's `tmux` list-clients stub + temp ttys ($tt1/$tt2) above.
functions -c __tcz_categorize __tcz_cat_bak
function __tcz_categorize; end
rm -f $tt1; touch $tt1; set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_main tick "#1f6feb"
t "tick re-emits color to shellfish client" yes (string match -q '*settoolbar*' -- (cat $tt1 | string collect); and echo yes; or echo no)
rm -f $tt1; touch $tt1
__tcz_main tick ''
t "tick with empty color does not emit" no (test -s $tt1; and echo yes; or echo no)
rm -f $tt1; touch $tt1
__tcz_main tick
t "bare tick (no color) does not emit" no (test -s $tt1; and echo yes; or echo no)
functions -e __tcz_categorize; functions -c __tcz_cat_bak __tcz_categorize; functions -e __tcz_cat_bak
set -e tmux_lives_fake_environ
functions -e tmux
rm -f $tt1 $tt2

# --- title emit ---
set -g ttl /tmp/tcz-title-$fish_pid; rm -f $ttl; touch $ttl
__tcz_emit_title $ttl "macwork: tmux-lives (C)"
# Match the literal OSC-2 introducer `]2;` + the title (single quotes don't interpret
# `\033`, so match the literal `]2;` that follows the ESC byte in the file, not the ESC).
t "emit_title writes OSC 2 + title" yes (string match -q '*]2;macwork: tmux-lives (C)*' -- (cat $ttl | string collect); and echo yes; or echo no)
rm -f $ttl; touch $ttl
__tcz_emit_title $ttl ""
t "emit_title empty is a no-op" no (test -s $ttl; and echo yes; or echo no)
rm -f $ttl

# session_has_claude / session_title via a tmux stub (switch on subcommand)
function tmux
    switch "$argv[1]"
        case list-panes
            if string match -q '*pane_current_path*' -- "$argv"
                echo $tcz_test_path              # __tcz_session_title: active-pane cwd
            else
                printf '%s\n' $tcz_test_panes    # __tcz_session_has_claude: cmd\tpid per pane
            end
        case show-option       # @tmux_lives_name override (empty = fall back to dir)
            echo $tcz_test_name
    end
end
set -g __tcz_oldhome $HOME; set -g HOME /home/x; set -g tmux_lives_hostname macwork
set -g tcz_test_panes (printf 'fish\t999')
set -g tcz_test_path /home/x/workspace/tmux-lives
set -g tcz_test_name ''
t "session_has_claude false for shells" no (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title no claude" "macwork: tmux-lives" (__tcz_session_title sA)
set -g tcz_test_panes (printf 'claude\t999')
t "session_has_claude true with a claude pane" yes (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title with claude" "macwork: tmux-lives (C)" (__tcz_session_title sA)
set -g tcz_test_panes (printf 'fish\t999')
set -g tcz_test_name 'Neurotto CLI'
t "session_title honors @tmux_lives_name over dir" "macwork: Neurotto CLI" (__tcz_session_title sA)
functions -e tmux
set -g HOME $__tcz_oldhome; set -e __tcz_oldhome; set -e tmux_lives_hostname; set -e tcz_test_panes; set -e tcz_test_path; set -e tcz_test_name

# empty active-pane path must not shift args (arg-shift guard)
function tmux
    switch "$argv[1]"
        case list-panes
            if string match -q '*pane_current_path*' -- "$argv"
                echo ''                          # empty active-pane path
            else
                printf 'claude\t999\n'           # session has claude
            end
    end
end
set -g __tcz_oldhome $HOME; set -g HOME /home/x; set -g tmux_lives_hostname macwork
t "session_title empty path keeps the (C) flag (no arg-shift)" "macwork:  (C)" (__tcz_session_title sA)
functions -e tmux
set -g HOME $__tcz_oldhome; set -e __tcz_oldhome; set -e tmux_lives_hostname

# ---------------------------------------------------------------------
# __tcz_status_format — pure status-format[0] builder
# ---------------------------------------------------------------------
set -g SF (__tcz_status_format)
t "sf has all three align zones" yes (string match -q '*#[align=left]*' -- "$SF"; and string match -q '*#[align=centre]*' -- "$SF"; and string match -q '*#[align=right]*' -- "$SF"; and echo yes; or echo no)
t "sf right zone renders status-right (tick/continuum preserved)" yes (string match -q '*#{T;=/#{status-right-length}:status-right}*' -- "$SF"; and echo yes; or echo no)
t "sf window list is names-only, no trailing sep" yes (string match -q '*#{W:*window_end_flag*window-status-separator*' -- "$SF"; and echo yes; or echo no)
t "sf window list template-expands the option" yes (string match -q '*#{T:window-status-format}*' -- "$SF"; and echo yes; or echo no)
t "sf identity honors @tmux_lives_name then session_name" yes (string match -q '*#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}*' -- "$SF"; and echo yes; or echo no)
t "sf identity uses the collapsed claude idiom (single readable ✦ mark)" yes (string match -q '*✦#[fg=#{@tmux_lives_text_fg}] #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{@tmux_lives_claude}}*' -- "$SF"; and echo yes; or echo no)
t "sf separator is format-expanded (T:)" yes (string match -q '*#{T:window-status-separator}*' -- "$SF"; and echo yes; or echo no)
t "sf centre identity wears the text role" yes (string match -q '*#[fg=#{@tmux_lives_text_fg}]#{?#{!=:#{@tmux_lives_claude},*' -- "$SF"; and echo yes; or echo no)
t "identity ✦ wears the mark role" yes (string match -q '*#[fg=#{@tmux_lives_mark_fg}]✦*' -- (__tcz_status_identity); and echo yes; or echo no)
t "sf host cap picks glyph by host_kind" yes (string match -q '*#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}*' -- "$SF"; and echo yes; or echo no)
t "sf host cap shows hostname" yes (string match -q '*#{host_short}*' -- "$SF"; and echo yes; or echo no)
t "sf prefix shows chevron via client_prefix" yes (string match -q '*#{?client_prefix,*❯*' -- "$SF"; and echo yes; or echo no)
t "sf resize badge via key-table" yes (string match -q '*#{?#{==:#{client_key_table},tmuxlives-resize},*◇ RESIZE ◇*' -- "$SF"; and echo yes; or echo no)
t "sf caps recolor on prefix/resize" yes (string match -q '*#{@tmux_lives_prefix_color}*' -- "$SF"; and string match -q '*#{@tmux_lives_resize_color}*' -- "$SF"; and string match -q '*#{@tmux_lives_cap_bg}*' -- "$SF"; and echo yes; or echo no)
# the powerline slants must taper the cap INTO the bar bg (not bg=default, which is a notch)
t "sf slants transition to @tmux_lives_bar_bg" yes (string match -q '*bg=#{@tmux_lives_bar_bg}*' -- "$SF"; and echo yes; or echo no)
t "sf caps no longer taper to bg=default" yes (string match -q '*bg=default*' -- "$SF"; and echo no; or echo yes)

# --- identity collapse (behavioral, private -L socket): a --name-derived claude
#     session shows a single readable "✦ name", NOT the redundant "slug ✦ name".
#     (Regression 2026-07-10: "TMUX-Setup-13 ✦ TMUX Setup 13" — session slug is
#     slugify(claude --name), so the old append-form doubled the identity.)
set -g idsock tli-id-$fish_pid
command tmux -L $idsock new-session -d -s TMUX-Setup-13 2>/dev/null
command tmux -L $idsock new-session -d -s gen-1 2>/dev/null
command tmux -L $idsock set -g @tmux_lives_mark_fg default 2>/dev/null
command tmux -L $idsock set -g @tmux_lives_text_fg default 2>/dev/null
set -g IDFMT (__tcz_status_identity)
command tmux -L $idsock set-option -t TMUX-Setup-13 @tmux_lives_claude "TMUX Setup 13" 2>/dev/null
t "identity: claude session collapses to a single '✦ name'" "#[fg=default]✦#[fg=default] TMUX Setup 13" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
t "identity: non-claude session shows its name only" "gen-1" (command tmux -L $idsock display-message -p -t gen-1 "$IDFMT" 2>/dev/null)
command tmux -L $idsock set-option -t TMUX-Setup-13 @tmux_lives_name "Neurotto CLI" 2>/dev/null
t "identity: @tmux_lives_name overrides the claude name (still ✦-marked)" "#[fg=default]✦#[fg=default] Neurotto CLI" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
command tmux -L $idsock kill-server 2>/dev/null
set -e idsock; set -e IDFMT

# real-tmux integration: __tcz_session_title must resolve the active pane's cwd.
# REGRESSION (2026-07-09): `display-message -t "=$session" '#{pane_current_path}'`
# returns EMPTY in tmux 3.3a (the =exact-target quirk — same family as set/show-option),
# so ShellFish tab titles rendered "<host>:  (C)" with a BLANK dir. The stub tests above
# can't catch a real-tmux targeting quirk, so drive a private -L socket. The fix reads the
# path via `list-panes -t "=$session"` (honors = AND resolves the pane path).
set -g tsock tcz-title-$fish_pid
set -g twdir /tmp/tcz-titledir-$fish_pid
rm -rf $twdir; mkdir -p $twdir
command tmux -L $tsock -f /dev/null new-session -d -s realsess -c $twdir 2>/dev/null
function tmux; command tmux -L $tsock $argv; end
set -g tmux_lives_hostname boxhost
t "session_title resolves active-pane cwd (real tmux, =target)" "boxhost: "(basename $twdir) (__tcz_session_title realsess)
functions -e tmux
command tmux -L $tsock kill-server 2>/dev/null
set -e tmux_lives_hostname; set -e tsock; rm -rf $twdir; set -e twdir

# retitle: per-client loop, ShellFish-gated. Stub session_title + list-clients.
set -g rt1 /tmp/tcz-rt1-$fish_pid; set -g rt2 /tmp/tcz-rt2-$fish_pid
rm -f $rt1 $rt2; touch $rt1 $rt2
functions -c __tcz_session_title __tcz_st_bak
function __tcz_session_title; echo "t-$argv[1]"; end
function tmux
    test "$argv[1]" = list-clients; and printf '111\t%s\tsA\n222\t%s\tsB\n' "$rt1" "$rt2"
end
set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_retitle
t "retitle titles shellfish client 1" yes (string match -q '*t-sA*' -- (cat $rt1 | string collect); and echo yes; or echo no)
t "retitle titles shellfish client 2" yes (string match -q '*t-sB*' -- (cat $rt2 | string collect); and echo yes; or echo no)
rm -f $rt1; touch $rt1
set -gx tmux_lives_fake_environ "TERM=xterm"
__tcz_retitle
t "retitle skips non-shellfish client" no (test -s $rt1; and echo yes; or echo no)
functions -e tmux; functions -e __tcz_session_title; functions -c __tcz_st_bak __tcz_session_title; functions -e __tcz_st_bak
set -e tmux_lives_fake_environ
rm -f $rt1 $rt2

# ---------------------------------------------------------------------
# per-tty emit dedup: the tick must emit only when the value changed
# ---------------------------------------------------------------------
set -g EMITTED
functions -q __tcz_emit_barcolor; and functions -c __tcz_emit_barcolor __tcz_ebc_bak
function __tcz_emit_barcolor; set -g EMITTED $EMITTED "c:$argv[2]"; end
functions -q __tcz_client_is_shellfish; and functions -c __tcz_client_is_shellfish __tcz_cis_bak
function __tcz_client_is_shellfish; return 0; end   # every client is ShellFish
set -g DEDUP_color ''
function tmux
    switch "$argv[1]"
        case list-clients; printf '111\t/dev/pts/9\n'
        case show
            # __tcz_recolor now resolves @tmux_lives_tabs_color (v3 Phase 2) via
            # __tcz_tab_color BEFORE the per-tty emit-cache read below -- keep the
            # two `show -gv` reads distinct or the tabs-role lookup would alias
            # onto $DEDUP_color (the per-tty cache) and skew this dedup test.
            if test "$argv[-1]" = @tmux_lives_tabs_color
                echo ''
            else
                echo $DEDUP_color            # show -gv @..._color (per-tty cache)
            end
        case set; set -g DEDUP_color "$argv[-1]"  # set -g @..._color <val>
        case '*'
    end
end
# key sanitization
t "emit_key strips non-alnum" devpts9 (__tcz_emit_key /dev/pts/9)
# force always emits + caches
__tcz_recolor '#111111'
t "recolor force emits" 'c:#111111' "$EMITTED[-1]"
t "recolor force caches the value" '#111111' "$DEDUP_color"
# dedup with cache == value -> skip
set -g EMITTED
__tcz_recolor '#111111' dedup
t "recolor dedup skips unchanged" '' "$EMITTED"
# dedup with a changed value -> emit + recache
__tcz_recolor '#222222' dedup
t "recolor dedup emits on change" 'c:#222222' "$EMITTED[-1]"
t "recolor dedup recaches" '#222222' "$DEDUP_color"
functions -e tmux __tcz_emit_barcolor __tcz_client_is_shellfish
functions -q __tcz_ebc_bak; and functions -c __tcz_ebc_bak __tcz_emit_barcolor; and functions -e __tcz_ebc_bak
functions -q __tcz_cis_bak; and functions -c __tcz_cis_bak __tcz_client_is_shellfish; and functions -e __tcz_cis_bak
set -e EMITTED; set -e DEDUP_color

# --- host-kind detection (seeds @tmux_lives_host_kind -> which glyph) ---
set -e tmux_lives_host_kind
set -l ssh_conn_save $SSH_CONNECTION
set -l ssh_tty_save $SSH_TTY
set -gx SSH_CONNECTION '10.0.0.5 40000 10.0.0.1 22'
set -e SSH_TTY
t "host_kind remote when SSH_CONNECTION set" remote (__tcz_host_kind)
set -e SSH_CONNECTION
set -e SSH_TTY
t "host_kind local with no ssh env" local (__tcz_host_kind)
set -gx tmux_lives_host_kind remote   # explicit override wins even locally
t "host_kind override wins" remote (__tcz_host_kind)
set -e tmux_lives_host_kind
# restore SSH env for later tests
if set -q ssh_conn_save; and test -n "$ssh_conn_save"; set -gx SSH_CONNECTION $ssh_conn_save; end
if set -q ssh_tty_save; and test -n "$ssh_tty_save"; set -gx SSH_TTY $ssh_tty_save; end
set -e ssh_conn_save ssh_tty_save

# --- @tmux_lives_claude population + DEDUP (only set-option when the value CHANGED; the
#     unconditional per-tick/per-command set forced needless bar redraws → ShellFish cursor flicker) ---
set -g CLAUDE_SET ''
set -g CLAUDE_CUR ''
function tmux
    switch "$argv[1]"
        case set-option
            set -g CLAUDE_SET "$argv"   # capture the last set-option
        case show-option
            echo "$CLAUDE_CUR"          # simulated current @tmux_lives_claude
        case list-panes
            printf '%s\n' $tcz_claude_panes
    end
end
set -g tcz_claude_panes (printf 'claude\t4242')
functions -c __tcz_cmdline_name __tcz_cmdline_name_bak
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; echo opus; end
# changed (cur empty -> opus): sets
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt writes @tmux_lives_claude when it changed" yes (string match -q '*set-option*sA*@tmux_lives_claude*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# unchanged (cur already opus): SKIPS the set (no redraw)
set -g CLAUDE_CUR opus; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt skips the set when unchanged (no needless redraw)" yes (test -z "$CLAUDE_SET"; and echo yes; or echo no)
# claude went away (cur opus, now non-claude -> ''): sets (clears)
set -g tcz_claude_panes (printf 'fish\t4242')
set -g CLAUDE_CUR opus; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt clears @tmux_lives_claude when a claude went away" yes (string match -q '*@tmux_lives_claude*' -- "$CLAUDE_SET"; and not string match -q '*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# already empty non-claude: SKIPS
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt skips when already empty (non-claude)" yes (test -z "$CLAUDE_SET"; and echo yes; or echo no)
functions -e tmux; functions -e __tcz_cmdline_name; functions -c __tcz_cmdline_name_bak __tcz_cmdline_name; functions -e __tcz_cmdline_name_bak; set -e tcz_claude_panes; set -e CLAUDE_SET; set -e CLAUDE_CUR

# ---------------------------------------------------------------------
# scratch resize verbs
# ---------------------------------------------------------------------
fresh_server
__tcz_scratch      # create a scratch so there are two panes
set -g w0 (command tmux -L $sock list-panes -F '#{pane_width}' | sort -n | head -1)
__tcz_scratch_resize L
set -g w1 (command tmux -L $sock list-panes -F '#{pane_width}' | sort -n | head -1)
t "scratch_resize changes a pane width" yes (test "$w0" != "$w1"; and echo yes; or echo no)
# resize-enter with a scratch switches the key table (assert via source: uses switch-client -T)
t "resize_enter uses tmuxlives-resize table" yes (string match -q '*switch-client*tmuxlives-resize*' -- (functions __tcz_resize_enter | string collect); and echo yes; or echo no)
t "resize_enter nudges when no scratch" yes (string match -q '*display-message*' -- (functions __tcz_resize_enter | string collect); and echo yes; or echo no)
# no-scratch: resize-enter must NOT error
fresh_server
t "resize_enter no-scratch is clean" 0 (__tcz_resize_enter ''; echo $status)
command tmux -L $sock kill-server 2>/dev/null
t "main dispatches scratch-resize" yes (string match -q '*scratch-resize*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
t "main dispatches resize-enter" yes (string match -q '*resize-enter*' -- (functions __tcz_main | string collect); and echo yes; or echo no)

# ---------------------------------------------------------------------
# status-bar toggles: flip the live option + persist to the state file
# ---------------------------------------------------------------------
set -g statefile /tmp/tcz-state-$fish_pid.conf
set -gx tmux_lives_state_file $statefile
rm -f $statefile
fresh_server
command tmux -L $sock set -g status-position bottom
__tcz_status_pos_toggle
t "pos toggle flips bottom->top (live)" top (command tmux -L $sock show -gv status-position)
t "pos toggle writes the state file" yes (test -f $statefile; and echo yes; or echo no)
t "state file records position top" yes (string match -q '*status-position top*' -- (cat $statefile | string collect); and echo yes; or echo no)
__tcz_status_pos_toggle
t "pos toggle flips top->bottom (live)" bottom (command tmux -L $sock show -gv status-position)
command tmux -L $sock set -g status on
__tcz_status_vis_toggle
t "vis toggle flips on->off (live)" off (command tmux -L $sock show -gv status)
t "state file records status off" yes (string match -q '*set -g status off*' -- (cat $statefile | string collect); and echo yes; or echo no)
__tcz_status_vis_toggle
t "vis toggle flips off->on (live)" on (command tmux -L $sock show -gv status)
t "state file always writes both lines" 2 (cat $statefile | grep -c '^set -g status')
t "main dispatches status-pos-toggle" yes (string match -q '*status-pos-toggle*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
t "main dispatches status-vis-toggle" yes (string match -q '*status-vis-toggle*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
command tmux -L $sock kill-server 2>/dev/null
set -e tmux_lives_state_file
rm -f $statefile

# ---------------------------------------------------------------------
# __tcz_heal_due — the color-only backstop timer
# ---------------------------------------------------------------------
set -g HEAL_at ''; set -g HEAL_interval 120
function tmux
    switch "$argv[1]"
        case show
            string match -q '*heal_interval' -- "$argv[3]"; and echo $HEAL_interval
            string match -q '*heal_at' -- "$argv[3]"; and echo $HEAL_at
        case set
            string match -q '*heal_at' -- "$argv[3]"; and set -g HEAL_at "$argv[-1]"
        case '*'
    end
end
t "heal due when unset (schedules)" 0 (__tcz_heal_due 1000; echo $status)
t "heal_at advanced to now+interval" 1120 "$HEAL_at"
t "heal not due before the interval" 1 (__tcz_heal_due 1100; echo $status)
t "heal due at/after the schedule" 0 (__tcz_heal_due 1120; echo $status)
set -g HEAL_interval 0
t "heal disabled when interval 0" 1 (__tcz_heal_due 999999; echo $status)
functions -e tmux; set -e HEAL_at; set -e HEAL_interval

# ---------------------------------------------------------------------
# tl theme palette (__tcz_theme). The v2 cap-picker cluster that consumed it —
# families/swatch-line/dma/inert/restore/sep + __tcz_cap_picker itself — was
# deleted in Task 6; __tcz_theme stays as the palette accessor for the v3
# theme picker (Task 8).
# ---------------------------------------------------------------------
t "theme brand is truecolor ff8a1f" 1 (test (__tcz_theme brand) = (printf '\e[38;2;255;138;31m'); and echo 1; or echo 0)
t "theme key is f5cf8a"    1 (test (__tcz_theme key)    = (printf '\e[38;2;245;207;138m'); and echo 1; or echo 0)
t "theme value is 6fc7b8"  1 (test (__tcz_theme value)  = (printf '\e[38;2;111;199;184m'); and echo 1; or echo 0)
t "theme selbg is 191913 bg" 1 (test (__tcz_theme sel-bg) = (printf '\e[48;2;25;25;19m'); and echo 1; or echo 0)
t "theme reset" 1 (test (__tcz_theme reset) = (printf '\e[0m'); and echo 1; or echo 0)
# `mark` is a neutral grey, distinct from both `key` (tan) and `muted` (warm
# tan-grey) — it read as a rule rather than part of the warm colour story when
# the (now-deleted) v2 swatch-line underlined an active column with it; kept
# distinct for whatever the v3 theme picker (Task 8) marks with it next.
t "theme mark is neutral grey 8a8a8a" 1 (test (__tcz_theme mark) = (printf '\e[38;2;138;138;138m'); and echo 1; or echo 0)
t "theme mark differs from key"   1 (test (__tcz_theme mark) != (__tcz_theme key); and echo 1; or echo 0)
t "theme mark differs from muted" 1 (test (__tcz_theme mark) != (__tcz_theme muted); and echo 1; or echo 0)

# --- shared key-legend builder + darker sel-bg ---
set -l lg (__tcz_legend_row 12 '↑↓' move '⏎' switch x kill esc close)
set -l lgp (__tcz_strip_sgr "$lg")
t "legend row visible width = 1 + 4*pitch" 49 (string length --visible -- "$lgp")
t "legend row carries all labels" 1 (string match -q '*move*switch*kill*close*' -- "$lgp"; and echo 1; or echo 0)
t "legend key colored" 1 (string match -q '*38;2;245;207;138*' -- "$lg"; and echo 1; or echo 0)
t "sel-bg darkened" 1 (test (__tcz_theme sel-bg) = (printf '\e[48;2;25;25;19m'); and echo 1; or echo 0)

# --- theme-picker pure builders ----------------------------------------------
set -g THX "#0e190d #4c5620 #6e6e22 #8b8130 #998a3e #b59e59 #ffdeba"
t "thp_fg hex -> SGR" yes (string match -q '*38;2;14;25;13*' -- (__tcz_thp_fg "#0e190d"); and echo yes; or echo no)
t "thp_fg non-hex -> empty" 0 (count (__tcz_thp_fg colour238))
t "thp_row lead is 16 visible cols + name" (math 16 + 4) (string length --visible -- (__tcz_strip_sgr (__tcz_thp_row "$THX" warm 0)))
t "thp_row selected keeps the width" (math 16 + 4) (string length --visible -- (__tcz_strip_sgr (__tcz_thp_row "$THX" warm 1)))
t "thp_row selected carries the ▐ marker" yes (string match -q '*▐*' -- (__tcz_thp_row "$THX" warm 1); and echo yes; or echo no)
t "thp_off_row width matches" 33 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_off_row "#76846d" 0)))
t "thp_preview is exactly 50 cols" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "$THX" "#111111" rocket Monitoring 50)))
t "thp_preview holds width on long names" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "$THX" "#111111" a-very-long-host An-Extremely-Long-Session-Name 50)))
# a malformed role hex must degrade to uncolored text, never collapse a segment
t "thp_preview holds width on a malformed hex" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "#0e190d wat #6e6e22 #8b8130 #998a3e #b59e59 #ffdeba" "#111111" rocket Monitoring 50)))
t "thp_preview holds width when cap hex is bad" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "#0e190d #4c5620 #6e6e22 #8b8130 #998a3e colour238 #ffdeba" "#111111" rocket Monitoring 50)))
t "thp_restore finds a scheme" 1 (__tcz_thp_restore warm mono warm cool)
t "thp_restore off -> after the schemes" 3 (__tcz_thp_restore off mono warm cool)
t "thp_restore unknown -> 0" 0 (__tcz_thp_restore wat mono warm cool)
t "readkey knows s/e/b" yes (string match -q '*case 73*' -- (functions __tcz_popup_readkey | string collect); and string match -q '*case 65*' -- (functions __tcz_popup_readkey | string collect); and string match -q '*case 62*' -- (functions __tcz_popup_readkey | string collect); and echo yes; or echo no)
t "readkey knows d" yes (string match -q '*case 64*' -- (functions __tcz_popup_readkey | string collect); and echo yes; or echo no)
t "readkey a" a (echo -n a | __tcz_popup_readkey)
t "readkey o" o (echo -n o | __tcz_popup_readkey)
t "readkey r" r (echo -n r | __tcz_popup_readkey)

# --- v3.1 picker builders (Task 5) ---
set -l zs (__tcz_thp_zsep 50 'adjustments · apply to all schemes' "" "")
set -l zsp (__tcz_strip_sgr "$zs")
t "zsep total width w+2" 52 (string length --visible -- (string trim -- "$zsp"))
t "zsep carries the label" 1 (string match -q '*adjustments · apply to all schemes*' -- "$zsp"; and echo 1; or echo 0)
set -l boldon (printf '\e[1m')
t "zsep label is bold" 1 (string match -q "*$boldon*" -- "$zs"; and echo 1; or echo 0)
set -l zse (__tcz_thp_zsep 50 '' "" "")
t "zsep empty label = plain sep" (__tcz_thp_sep 50 "" "") "$zse"
set -l kv (__tcz_thp_kv 50 '' seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv emits two lines" 2 (count $kv)
set -l l1 (__tcz_strip_sgr "$kv[1]")
set -l l2 (__tcz_strip_sgr "$kv[2]")
t "kv labels uppercased" 1 (string match -q '*SEED*PHASE*VIVIDNESS*SHAPE*' -- "$l1"; and echo 1; or echo 0)
t "kv values line carries values" 1 (string match -q '*#485b3c*+15°*balanced*arc*' -- "$l2"; and echo 1; or echo 0)
# columns align: each label starts at the same visible offset as its value
t "kv label/value columns align" (string match -rg '^( *)SEED' -- "$l1" | string length) (string match -rg '^( *)#485b3c' -- "$l2" | string length)

# --- change-flash (Task 3): flash role + timeout readkey + kv flash arg ---
t "theme flash role" (printf '\e[38;2;95;168;232m') (__tcz_theme flash)
t "readkey timeout mode" timeout (printf '' | __tcz_popup_readkey timeout)
t "readkey EOF still cancels by default" cancel (printf '' | __tcz_popup_readkey)
set -l FLASH (__tcz_theme flash)
set -l kvf (__tcz_thp_kv 50 vividness seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv flash colors the flagged label" 1 (string match -q "*$FLASH*VIVIDNESS*" -- "$kvf[1]"; and echo 1; or echo 0)
t "kv flash colors the flagged value" 1 (string match -q "*$FLASH*balanced*" -- "$kvf[2]"; and echo 1; or echo 0)
t "kv flash leaves others muted" 0 (string match -q "*$FLASH*SEED*" -- "$kvf[1]"; and echo 1; or echo 0)
set -l kvn (__tcz_thp_kv 50 '' seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv no-flash has no flash SGR" 0 (string match -q "*$FLASH*" -- "$kvn[1]$kvn[2]"; and echo 1; or echo 0)
# widths identical with and without flash
t "kv flash width-neutral" (string length --visible -- (__tcz_strip_sgr "$kvn[2]")) (string length --visible -- (__tcz_strip_sgr "$kvf[2]"))

set -l ch (__tcz_thp_chip '#626f55' '#111111' 'rocket: tmux-lives (C)')
t "chip renders title on tabs bg" 1 (string match -q '*rocket: tmux-lives (C)*' -- (__tcz_strip_sgr "$ch"); and echo 1; or echo 0)
t "chip empty without tabs color" '' (__tcz_thp_chip '' '#111111' 'x' | string collect)
t "chip empty without title" '' (__tcz_thp_chip '#626f55' '#111111' '' | string collect)
# shellfish probe honors the fake-environ seam (following __tcz_client_is_shellfish pattern)
# Stub tmux to return a fake client PID for list-clients
function tmux
    if contains -- list-clients $argv
        echo 9999
        return 0
    end
    command tmux $argv
end
set -g tmux_lives_fake_environ 'LC_TERMINAL=ShellFish'
t "shellfish probe true via seam" 0 (__tcz_thp_shellfish; echo $status)
set -g tmux_lives_fake_environ 'LC_TERMINAL=xterm'
t "shellfish probe false via seam" 1 (__tcz_thp_shellfish; echo $status)
set -e tmux_lives_fake_environ
functions -e tmux

# --- theme picker loop (interactive body = live smoke; wiring + structure tested) ---
t "main routes theme-picker" yes (string match -q '*case theme-picker*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
t "picker batches palettes via theme_schemes" yes (string match -q '*__tmux_lives_theme_schemes*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker applies through the CLI, silenced" yes (string match -q '*tmux-lives setup theme*>/dev/null 2>&1*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker coalesces phase in 5° steps" yes (string match -q '*math $delta + 5*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker restores the terminal on signals" yes (string match -q '*__tcz_thp_cleanup*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker has a contrast toggle" yes (string match -q '*case d*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker apply passes contrast+rotate" yes (string match -q '*--contrast*' -- (functions __tcz_theme_picker | string collect); and string match -q '*--rotate*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker frame: last row printed without newline" yes (string match -q '*$lines[1..-2]*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
# readkey's ESC/CSI-arrow branch leaves the tty in `min 1 time 0` (blocking) on
# return, so each drain iteration must re-assert non-blocking BEFORE reading —
# otherwise the second buffered read blocks forever (empirically confirmed hang).
t "picker drain re-asserts non-blocking each iteration" 3 (string match -a -r 'while true(?=\n\s+stty min 0 time 0)' -- (functions __tcz_theme_picker | string collect) | count)

# --- raw-mode seed entry (live swatch + hue readout) ---
t "thp_readchar exists with hex classification" yes (string match -q '*0-9a-fA-F*' -- (functions __tcz_thp_readchar | string collect); and echo yes; or echo no)
t "picker b-case is raw (no cooked read)" no (string match -q '*read -l val*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker b-case shows a hue readout" yes (string match -q '*hue*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker b-case uses readchar" yes (string match -q '*__tcz_thp_readchar*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
# Task 3 review fix: a bare `1b` used to return `esc` immediately, leaking the
# following `[`+letter bytes of an arrow keypress into the outer picker's ↑↓
# handling (the escape sequence's letter moved the scheme selection). readchar
# must now mirror __tcz_popup_readkey's non-blocking CSI/SS3 follow-read.
t "readchar disambiguates bare ESC from CSI" yes (string match -q '*5b*' -- (functions __tcz_thp_readchar | string collect); and string match -q '*min 0 time 1*' -- (functions __tcz_thp_readchar | string collect); and echo yes; or echo no)
# the entry-paint printf (seed prompt) must open its own DECSET 2026
# atomically, same as the main frame — pinned to the SPECIFIC printf that
# begins "2026h...H <bold>seed" (a bare '*2026h*' would also match the main
# frame's own synchronized-update wrapper and prove nothing). Task 7 grew the
# title to "seed — this IS the bar color" (bold-wrapped); both the hexentry
# and sliders screens share this exact opening.
t "seed entry paints atomically" yes (string match -qr -- '\\\\e\[\?2026h\\\\e\[H \\\\e\[1mseed' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# --- RGB slider seed picker (Task 1): readchar tokens + slider row builder ---
t "thp_slider width fixed at 39" 39 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)))
t "thp_slider width holds at extremes+selected" 78 (math (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider G 0 1)))" + "(string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider B 255 1))))
t "thp_slider gap cells at 0" 32 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 0 0)) | count)
t "thp_slider gap cells at 128" 16 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)) | count)
t "thp_slider gap cells at 255" 0 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 255 0)) | count)
t "thp_slider selected carries ▐" yes (string match -q '*▐*' -- (__tcz_thp_slider R 10 1); and echo yes; or echo no)
t "readchar classifies arrows + t" yes (begin; set -l l (functions __tcz_thp_readchar | string collect); string match -q '*case 41; echo up*' -- $l; and string match -q '*case 44; echo left*' -- $l; and string match -q '*case 74; echo t*' -- $l; end; and echo yes; or echo no)
t "hex entry ignores the new tokens" yes (string match -q '*case hash other t up down left right*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# --- RGB slider seed picker (Task 2): slider screen, b reroute, hexentry extraction ---
t "picker b opens the sliders" yes (string match -qr 'case b\s+__tcz_thp_sliders' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders route t to the hex editor" yes (string match -qr 'case t\s+__tcz_thp_hexentry' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders apply composes a hex" yes (string match -q '*#%02x%02x%02x*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "sliders erased on exit" yes (begin; set -l l (functions __tcz_theme_picker | string collect); string match -q '*functions -e __tcz_thp_sliders*' -- $l; and string match -q '*functions -e __tcz_thp_hexentry*' -- $l; end; and echo yes; or echo no)

# Grep-guards: the v2 cap-picker cluster and the install-side v2 palette engine
# it called must both be fully gone from the categorizer file.
set -l catfile $plugindir/functions/tmux-categorize.fish
t "v2 cap cluster gone from the categorizer" 0 (grep -c '__tcz_cap_' $catfile)
t "categorizer no longer names the v2 palette" 0 (grep -c '__tmux_lives_palette' $catfile)
# live-smoke regressions (2026-07-16): a QUOTED math-index ("$pals[(math ...)]") is an
# fish "Invalid index value" ERROR that sprays a 3-line stderr trace into the popup on
# EVERY draw (frame scrolls out + flicker + empty preview palette); the title edge must
# span the full inner width like every other row; and the frame must paint atomically
# (DECSET 2026, the __tcz_popup_draw pattern) or each redraw visibly flickers.
t "picker: no quoted math-index anywhere in the categorizer" 0 (grep -c '"\$[a-z]*\[(math' $catfile)
t "picker: title edge spans the full inner width" yes (string match -q '*$IW - 18*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker: draw wrapped in synchronized output" yes (string match -q '*2026h*' -- (functions __tcz_theme_picker | string collect); and string match -q '*2026l*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# perf fix: the picker must never spawn a fish subprocess per keypress —
# the engine is sourced in-process at open. Extract the function body
# (top-level `end` closes it; nested helpers' `end`s are indented).
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "guard: no fish -c inside the picker" 0 (string match -q '*fish -c*' -- "$pbody"; and echo 1; or echo 0)
t "guard: picker sources the engine" 1 (string match -q '*conf.d/tmux-lives-install.fish*' -- "$pbody"; and echo 1; or echo 0)

# --- Task 6: picker layout A — 26-row frame, a/o/r keys, dead-knob guards ---
set -l catsrc (cat $catfile | string collect)
t "guard: no theme_polarity in categorizer" 0 (string match -q '*tmux_lives_theme_polarity*' -- "$catsrc"; and echo 1; or echo 0)
t "guard: no theme_range in categorizer" 0 (string match -q '*tmux_lives_theme_range*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup is 52x26 (modal open site)" 1 (string match -q '*-w 52 -h 26*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x20 anywhere" 0 (string match -q '*-w 52 -h 20*' -- "$catsrc"; and echo 1; or echo 0)

# --- Task 7: seed screens — big swatch + shared legend ---
set -l sw (__tcz_thp_swatch '#485b3c' 134 0.45 0.054)
t "swatch emits 4 lines" 4 (count $sw)
t "swatch line1 carries bold hex" 1 (string match -q '*#485b3c*' -- (__tcz_strip_sgr "$sw[1]"); and echo 1; or echo 0)
t "swatch line2 readouts" 1 (string match -q '*hue 134° · L 0.45 · chroma 0.054*' -- (__tcz_strip_sgr "$sw[2]"); and echo 1; or echo 0)
t "swatch line3 copy" 1 (string match -q '*rendered as-is on the bar*' -- (__tcz_strip_sgr "$sw[3]"); and echo 1; or echo 0)
set -l swe (__tcz_thp_swatch '' '' '' '')
t "swatch non-hex still 4 lines" 4 (count $swe)
# the dead hue-only contract line is gone from the categorizer
set -l catsrc2 (cat $catfile | string collect)
t "guard: hue-only copy retired" 0 (string match -q '*only its HUE drives the theme*' -- "$catsrc2"; and echo 1; or echo 0)

# --- Task 2: batch cache + rotate as a display-side permutation ---
# rotate is a display-side permutation: parity with the engine for r=0..4
set -l base (__tmux_lives_theme_palette '#485b3c' wide 25 vivid arc cubic lighter 0)
set -l basestr (string join ' ' $base)
for r in 0 1 2 3 4
    set -l eng (__tmux_lives_theme_palette '#485b3c' wide 25 vivid arc cubic lighter $r)
    set -l engstr (string join ' ' $eng)
    t "rotpal parity r=$r" "$engstr" (__tcz_thp_rotpal $r "$basestr")
end

# post-rotation fg pick contract: the displayed cap/tabs fgs equal
# contrast_fg of the ROTATED pal's fields 6 and 3
set -l rot 2
set -l rp (__tcz_thp_rotpal $rot "$basestr")
set -l rpf (string split ' ' -- $rp)
set -l wantcap (__tmux_lives_contrast_fg "$rpf[6]")
set -l wanttabs (__tmux_lives_contrast_fg "$rpf[3]")
set -l basepf (string split ' ' -- $basestr)
set -l sfgs
for si in 2 3 4 5 6
    set -l sf (__tmux_lives_contrast_fg $basepf[$si])
    set -a sfgs "$sf"
end
set -l jc (math "((5 - 1 - $rot) % 5 + 5) % 5 + 1")
set -l jt (math "((2 - 1 - $rot) % 5 + 5) % 5 + 1")
t "fg pick: cap fg matches rotated pal" "$wantcap" "$sfgs[$jc]"
t "fg pick: tabs fg matches rotated pal" "$wanttabs" "$sfgs[$jt]"

rm -rf $shimdir
if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
