#!/usr/bin/env fish
# Tests for functions/tmux-categorize.fish (auto-tmux v2 categorizer).
# Run: fish tests/test-tmux-categorize.fish
# Pure tests source the script with tmux_categorize_test set (main dispatch suppressed).
# Integration tests use an isolated socket via a PATH shim (propagates to subprocesses)
# plus a fake `claude` binary so the real detection path is exercised.

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
# iTerm2 client -> color written to the tty too (mirrors the ShellFish flow)
rm -f $oaf
set -g tmux_lives_fake_environ "LC_TERMINAL=iTerm2"
__tcz_on_attach 999 $oaf "#abcdef"
t "on-attach: iTerm2 writes color" "0" (test -s $oaf; echo $status)
# iTerm2 client -> baseline is NOT re-sourced (only true non-mirrored 'other' clients get it)
command tmux -L $sock new-session -d -s oa2 2>/dev/null
command tmux -L $sock set -g @tl_oa presourced 2>/dev/null
__tcz_on_attach 999 /dev/null ''
t "on-attach: iTerm2 does not source baseline" "presourced" (command tmux -L $sock show -gv @tl_oa 2>/dev/null)
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

# --- bare-number -t targeting (tmux 3.3a) -------------------------------------------
# set-option/show-option resolve a BARE NUMBER in -t as the CURRENT session, NOT the
# session NAMED that number (verified: with alpha=$0, "0"=$1, zulu=$2, a write aimed at
# -t 0 landed on zulu). Fresh sessions are named 0,1,2..., so every option lookup for one
# hits a DIFFERENT session. Worst case: that session carries @tmux_lives_name, the numeric
# one is misread as claimed, and it is skipped -> permanently stranded at its numeric name,
# re-failing every pass. Reproduced live before the fix.
cleanup
tmux new-session -d -s 0 "$shimdir/claude --name Numeric Claude"
tmux new-session -d -s claimant
tmux set-option -t claimant @tmux_lives_name "Claimed By App"
sleep 0.5
__tcz_categorize
t "cat: numeric session not stranded by another session's claim" "yes" \
    (tmux has-session -t =Numeric-Claude 2>/dev/null; and echo yes; or echo no)
t "cat: the claiming session keeps its own name" "yes" \
    (tmux has-session -t =claimant 2>/dev/null; and echo yes; or echo no)

# ...and a numeric session's claude identity must land on ITSELF, not on a neighbour.
cleanup
tmux new-session -d -s 0 "$shimdir/claude --name Cross Write"
tmux new-session -d -s neighbour
sleep 0.5
__tcz_set_claude_opt 0
set -g sid0 ''
for l in (tmux list-sessions -F '#{session_name} #{session_id}' 2>/dev/null)
    set -l p (string split ' ' -- $l)
    test "$p[1]" = 0; and set -g sid0 $p[2]
end
t "set_claude_opt: numeric session gets its OWN claude name" "Cross Write" \
    (tmux show-option -qv -t "$sid0" @tmux_lives_claude 2>/dev/null)
t "set_claude_opt: the neighbour is untouched" "" \
    (tmux show-option -qv -t neighbour @tmux_lives_claude 2>/dev/null)
set -e sid0
cleanup

# PANE/CAPTURE targets need a different shape than option targets: they want exact-match
# "=name", which options reject. But for a NUMERIC name even "=0" mis-resolves (it returned
# a neighbour's panes), so those callers need the $id too. __tcz_pane_target encodes that.
tmux new-session -d -s 0 'sleep 1000'
tmux new-session -d -s other-idle
sleep 0.3
set -g pt0 (__tcz_pane_target 0)
t "pane_target: numeric name resolves to a session id" "yes" (string match -qr '^\$[0-9]+$' -- "$pt0"; and echo yes; or echo no)
t "pane_target: ordinary name keeps exact-match =" "=other-idle" (__tcz_pane_target other-idle)
# The decision keys off the ORIGINAL name, not the shape of the resolved string — the
# sniff this replaced ('does the result start with $?') misfired on a session NAMED "$1".
# NB this only pins the shape we emit. tmux itself still resolves a $<digits>-shaped
# target as an ID even with the "=" prefix, so a session literally named "$1" cannot be
# addressed reliably by ANY target form. Out of reach here; documented, not claimed fixed.
t "pane_target: keys off the original name, not the resolved shape" '=$1' (__tcz_pane_target '$1')
set -e pt0
cleanup

# ...and the pane lookups themselves must read the RIGHT session's panes.
tmux new-session -d -s 0 "$shimdir/claude --name Numeric Pane"
tmux new-session -d -s plain-shell
sleep 0.5
t "has_claude: numeric session running claude is detected" "yes" (__tcz_session_has_claude 0; and echo yes; or echo no)
t "has_claude: the neighbour is correctly claude-free" "no" (__tcz_session_has_claude plain-shell; and echo yes; or echo no)
cleanup

# capture-pane does NOT accept the "=name" form that list-panes tolerates — it errors
# "can't find pane: =name" — so the preview needs the bare-name/id shape instead. Routing
# it through the pane-target helper blanked the picker preview for EVERY non-numeric
# session (i.e. almost all of them). End-to-end, because the pre-existing guard only
# greps the source for a literal '-t "=' and passed vacuously through the helper.
tmux new-session -d -s preview-me 'echo PREVIEW_MARKER; sleep 500'
sleep 0.5
set -g prev (__tcz_popup_preview preview-me 40 6 | string collect)
t "popup_preview: renders a NON-numeric session" "yes" (string match -q '*PREVIEW_MARKER*' -- "$prev"; and echo yes; or echo no)
set -e prev
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

# no-blanket-kick: a plain switch must NOT disturb other clients. Ghost-detach
# evicts any client idle > tmux_auto_ghost_minutes, so running it on every pick
# silently "takes" sessions the user only meant to visit. It must be gated on
# --take, like `tmux-lives attach -t` already is (conf.d/tmux.fish:344-348).
# Spying on the emitted tmux commands looks like the better test but is VACUOUS
# here: headless, list-clients returns nothing, so __tcz_ghosts never reaches its
# detach-client call and a "no detach-client was issued" assertion passes whether
# or not the gate exists (verified — it passed against the unfixed code). The
# invocation itself is the only non-vacuous seam, so spy on that.
tmux new-session -d -s gsw
functions -c __tcz_ghosts __tcz_ghosts_bak
function __tcz_ghosts; set -g __g_called 1; end
set -g __g_called 0
__tcz_switch gsw ''
t "switch: plain switch does NOT ghost-detach" "0" "$__g_called"
functions -e __tcz_ghosts
functions -c __tcz_ghosts_bak __tcz_ghosts
functions -e __tcz_ghosts_bak
set -e __g_called
# The --take path is observable by command-spy where the plain path is not:
# __tcz_switch issues detach-client -s itself, unconditionally, rather than
# behind an (always-empty headless) list-clients loop.
function tmux; set -a __t_cmds "$argv"; command tmux -L $sock $argv; end
set -g __t_cmds
__tcz_switch gsw '' --take
t "switch: --take detaches the session's clients" "1" \
    (string match -qr 'detach-client -s' -- "$__t_cmds"; and echo 1; or echo 0)
functions -e tmux
set -e __t_cmds
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
# pid -> direct children. `pgrep -P` rescans all of /proc per call (~140 ms on
# a busy Docker host with 400+ processes); /proc/<pid>/task/*/children is a
# single read (~2 ms). The tick called pgrep 10x, which was 77% of its 1.9 s
# runtime and kept ~2 cores busy. The ps branch stays for non-Linux.
# ---------------------------------------------------------------------
sleep 30 &
set -g kidpid $last_pid
t "pid_children /proc finds the child" 1 (contains -- $kidpid (__tcz_pid_children $fish_pid); and echo 1; or echo 0)
set -g tcz_force_ps 1
t "pid_children fallback finds the child" 1 (contains -- $kidpid (__tcz_pid_children $fish_pid); and echo 1; or echo 0)
set -e tcz_force_ps
t "pid_children /proc and fallback agree" (__tcz_pid_children $fish_pid | sort | string join ',') (begin; set -g tcz_force_ps 1; __tcz_pid_children $fish_pid | sort | string join ','; set -e tcz_force_ps; end)
t "pid_children empty pid -> empty"    ""  (__tcz_pid_children "")
t "pid_children childless pid -> empty" "" (__tcz_pid_children $kidpid)
kill $kidpid 2>/dev/null
set -e kidpid

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
    (string match -q '*display-popup -B -E -w 52 -h 85%*theme-picker*' -- (functions __tcz_modal_run | string collect); and echo yes; or echo no)
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
# __tcz_theme title — section separators in dimmed orange
# ---------------------------------------------------------------------
# The brand orange pulled down ~18%: distinct from the frame rule AND from the
# undimmed brand the picker uses for its own `theme` title in the top border.
t "theme title role is the dimmed orange" (printf '\e[38;2;210;120;42m') (__tcz_theme title)
set -g ZS (__tcz_thp_zsep 40 schemes (__tcz_theme border) (__tcz_theme reset))
t "zsep label wears the title role" 1 (string match -q '*'(__tcz_theme title)'*' -- "$ZS"; and echo 1; or echo 0)
t "zsep label no longer wears muted"  0 (string match -q '*'(__tcz_theme muted)'*' -- "$ZS"; and echo 1; or echo 0)
t "zsep is still exactly w visible cols" 42 (string length --visible -- "$ZS")
# an empty label still falls through to the plain rule
t "zsep with no label is the plain rule" 42 (string length --visible -- (__tcz_thp_zsep 40 '' (__tcz_theme border) (__tcz_theme reset)))

# ---------------------------------------------------------------------
# __tcz_status_right_merge — pure: keep a FOREIGN #() hook, replace ours
# ---------------------------------------------------------------------
# tmux-continuum schedules its autosave by prepending #(continuum_save.sh) to
# status-right — the status bar's refresh IS its scheduler, there is no daemon.
# A bare `set -g status-right` in the fragment discards it, and autosave stops
# permanently and silently. Recovery today is accidental: it only works because
# ~/.tmux.conf happens to source the fragment BEFORE the tpm run-line, so tpm
# re-sources continuum.tmux, which re-prepends — and even that is skipped when
# continuum's own `another_tmux_server_running` guard trips.
# The function must EXIST. Without this, every assertion below is invisible: when a
# command substitution calls an undefined function fish aborts the whole statement, so
# `t` never runs, nothing prints, and this suite (no pass counter) still says ALL PASS.
t "srm the function exists" 1 (functions -q __tcz_status_right_merge; and echo 1; or echo 0)
set -g OURS '#{T:@tmux_lives_status_right}#(cat.fish tick)'
# a foreign hook already present is kept, ours goes after it
t "srm keeps a foreign hook" "#(FOREIGN)$OURS" (__tcz_status_right_merge '#(FOREIGN)' "$OURS")
# re-merging an already-merged value is idempotent (the fragment re-sources often)
t "srm is idempotent" "#(FOREIGN)$OURS" (__tcz_status_right_merge "#(FOREIGN)$OURS" "$OURS")
# tmux's DEFAULT status-right carries no #() and must be replaced, not preserved
t "srm drops tmux's default" "$OURS" (__tcz_status_right_merge '"#{=21:pane_title}" %H:%M %d-%b-%y' "$OURS")
# empty / unset current
t "srm handles an empty current" "$OURS" (__tcz_status_right_merge '' "$OURS")
# a value that is already exactly ours stays exactly ours
t "srm handles an exact match" "$OURS" (__tcz_status_right_merge "$OURS" "$OURS")
# a foreign hook with NO marker present (first install after a plugin got there first)
t "srm keeps a foreign hook with no marker" "#(FOREIGN)$OURS" (__tcz_status_right_merge '#(FOREIGN)' "$OURS")
# ours may have been rendered with a DIFFERENT baked colour — the old one is replaced,
# not accumulated (this is what `setup color` relies on)
t "srm replaces a stale rendering of ours" "#(FOREIGN)$OURS" (__tcz_status_right_merge '#(FOREIGN)#{T:@tmux_lives_status_right}#(cat.fish tick OLDCOLOR)' "$OURS")
# several stacked hooks are all kept
t "srm keeps multiple foreign hooks" "#(A)#(B)$OURS" (__tcz_status_right_merge '#(A)#(B)' "$OURS")
# a hook with surrounding whitespace still qualifies
t "srm tolerates whitespace around hooks" "  #(A) $OURS" (__tcz_status_right_merge '  #(A) ' "$OURS")
# a user's DECORATED status-right is dropped, not welded on forever: keeping
# `#(uptime) %H:%M` would paint their clock beside ours with no way to remove it
t "srm drops a decorated foreign value" "$OURS" (__tcz_status_right_merge '#(uptime) %H:%M' "$OURS")
# CONTRACT: only a PREFIX is preserved. continuum prepends (verified in continuum.tmux),
# so this covers the real case; a plugin using `set -ga status-right` would be dropped.
t "srm keeps only a prefix, not a suffix" "$OURS" (__tcz_status_right_merge "$OURS#(APPENDED)" "$OURS")
# KNOWN LIMIT: a group ends at its first ')', so a hook whose command contains a literal
# ')' is not recognised. Pinned so the behaviour is a decision, not a surprise.
t "srm known limit: a hook containing ) is dropped" "$OURS" (__tcz_status_right_merge '#(echo (x))' "$OURS")

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
functions -q __tcz_client_terminal; and functions -c __tcz_client_terminal __tcz_ct_bak
function __tcz_client_terminal; echo shellfish; end   # every client is ShellFish
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
functions -e tmux __tcz_emit_barcolor __tcz_client_terminal
functions -q __tcz_ebc_bak; and functions -c __tcz_ebc_bak __tcz_emit_barcolor; and functions -e __tcz_ebc_bak
functions -q __tcz_ct_bak; and functions -c __tcz_ct_bak __tcz_client_terminal; and functions -e __tcz_ct_bak
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
# --- title fallback: claude is usually started WITHOUT --name (e.g. `claude -c`), so
#     __tcz_cmdline_name returns nothing and @tmux_lives_claude stayed empty. The centre
#     identity then fell back to session_name — a SLUG (spaces become dashes) which is also
#     frozen for unstamped restored breadcrumbs, so it showed e.g. "TMUX-Setup-18" while the
#     live title said "TMUX Setup 21". The readable name is right there in the pane title,
#     and __tcz_categorize already trusts the title to name the session.
set -g tcz_claude_panes (printf 'claude\t4242\t⠂ TMUX Setup 21')
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; end
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt falls back to the pane title when there is no --name" yes (string match -q '*@tmux_lives_claude*TMUX Setup 21*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# --name still WINS when present (stable flag beats a volatile title)
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; echo opus; end
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt prefers --name over the pane title" yes (string match -q '*@tmux_lives_claude*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# an untrusted title (no leading glyph word) must NOT become the name
set -g tcz_claude_panes (printf 'claude\t4242\tbare-title')
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; end
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt ignores an unparseable title" yes (test -z "$CLAUDE_SET"; and echo yes; or echo no)
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
# __tcz_thp_off_row is retired (picker-second-list Task 3) — its fixed
# natural-width contract has no equivalent under __tcz_thp_staterow's
# always-exactly-w model; that invariant is covered by the staterow block
# further down instead of being pinned here.
t "thp_preview is exactly 50 cols" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "$THX" "#111111" rocket Monitoring 50)))
t "thp_preview holds width on long names" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "$THX" "#111111" a-very-long-host An-Extremely-Long-Session-Name 50)))
# a malformed role hex must degrade to uncolored text, never collapse a segment
t "thp_preview holds width on a malformed hex" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "#0e190d wat #6e6e22 #8b8130 #998a3e #b59e59 #ffdeba" "#111111" rocket Monitoring 50)))
t "thp_preview holds width when cap hex is bad" 50 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_preview "#0e190d #4c5620 #6e6e22 #8b8130 #998a3e colour238 #ffdeba" "#111111" rocket Monitoring 50)))
t "readkey knows s/e/b" yes (string match -q '*case 73*' -- (functions __tcz_popup_readkey | string collect); and string match -q '*case 65*' -- (functions __tcz_popup_readkey | string collect); and string match -q '*case 62*' -- (functions __tcz_popup_readkey | string collect); and echo yes; or echo no)
t "readkey knows d" yes (string match -q '*case 64*' -- (functions __tcz_popup_readkey | string collect); and echo yes; or echo no)
t "readkey a" a (echo -n a | __tcz_popup_readkey)
t "readkey o" o (echo -n o | __tcz_popup_readkey)
t "readkey r" r (echo -n r | __tcz_popup_readkey)

# --- shift-reverse readkey tokens (Task 4) ---
t "readkey V" V (echo -n V | __tcz_popup_readkey)
t "readkey S" S (echo -n S | __tcz_popup_readkey)
t "readkey E" E (echo -n E | __tcz_popup_readkey)
t "readkey D" D (echo -n D | __tcz_popup_readkey)
t "readkey O" O (echo -n O | __tcz_popup_readkey)

# --- Theme v4 picker rewrite (Phase 2), Task 3: readkey must deliver p/P/m/M.
# Without an explicit case, readkey's catch-all returns "other" for any byte —
# so the theme-picker's new p/P/m/M dispatch arms would be unreachable dead
# code without these mappings. ---
t "readkey p" p (echo -n p | __tcz_popup_readkey)
t "readkey P" P (echo -n P | __tcz_popup_readkey)
t "readkey m" m (echo -n m | __tcz_popup_readkey)
t "readkey M" M (echo -n M | __tcz_popup_readkey)

# --- v3.1 picker builders (Task 5) ---
set -l zs (__tcz_thp_zsep 50 'adjustments · apply to all schemes' "" "")
set -l zsp (__tcz_strip_sgr "$zs")
t "zsep total width w+2" 52 (string length --visible -- (string trim -- "$zsp"))
t "zsep carries the label" 1 (string match -q '*adjustments · apply to all schemes*' -- "$zsp"; and echo 1; or echo 0)
set -l boldon (printf '\e[1m')
t "zsep label is bold" 1 (string match -q "*$boldon*" -- "$zs"; and echo 1; or echo 0)
set -l zse (__tcz_thp_zsep 50 '' "" "")
t "zsep empty label = plain sep" (__tcz_thp_sep 50 "" "") "$zse"
# --- change-flash (Task 3): flash role + timeout readkey ---
t "theme flash role" (printf '\e[38;2;95;168;232m') (__tcz_theme flash)
t "readkey timeout mode" timeout (printf '' | __tcz_popup_readkey timeout)
t "readkey EOF still cancels by default" cancel (printf '' | __tcz_popup_readkey)

# --- anchor-wave builders (Task 1); picker-second-list Task 5: the ❯ chevron
# is retired — the current entry is marked by rendering its NAME in brand
# bold instead (the same language as the second list's `current` label).
set -l CURM (printf '\e[38;5;179m')
set -l BRANDB (__tcz_theme brand)(printf '\e[1m')
set -l rowc (__tcz_thp_row '#111111 #222222 #333333 #444444 #555555 #666666 #777777' wide 0 1)
t "row current flag renders the name in brand bold" 1 (string match -q "*$BRANDB"wide"*" -- "$rowc"; and echo 1; or echo 0)
t "row current no longer wears the switcher yellow" 0 (string match -q "*$CURM*" -- "$rowc"; and echo 1; or echo 0)
set -l rown (__tcz_thp_row '#111111 #222222 #333333 #444444 #555555 #666666 #777777' wide 0)
t "row without current has no chevron" 0 (string match -q '*❯*' -- "$rown"; and echo 1; or echo 0)
t "row current is the same width as without (no glyph added)" 0 (math (string length --visible -- (__tcz_strip_sgr "$rowc")) - (string length --visible -- (__tcz_strip_sgr "$rown")))
set -l rowcs (__tcz_thp_row '#111111 #222222 #333333 #444444 #555555 #666666 #777777' wide 1 1)
t "row current+selected: selection styling wins over brand bold" 0 (string match -q "*$BRANDB*" -- "$rowcs"; and echo 1; or echo 0)
# picker-second-list Task 3: __tcz_thp_off_row is retired. Its old combined
# "❯ <name> · current" chevron text is replaced by __tcz_thp_staterow's
# separate name/label columns — the chevron is gone by design, not just moved.
set -l offc (__tcz_thp_staterow 50 (__tcz_thp_band '#5c6b52') 'off · current' myrole 0 1)
t "staterow replaces off-row's chevron text with a name/label split" 1 (string match -q '*off · current*myrole*' -- (__tcz_strip_sgr "$offc"); and echo 1; or echo 0)
t "staterow off-style row never renders a chevron" 0 (string match -q '*❯*' -- (__tcz_strip_sgr "$offc"); and echo 1; or echo 0)
t "readkey z" z (echo -n z | __tcz_popup_readkey)
# picker current-zone refinement, Task 2: c jumps to/from the current zone.
t "readkey c" c (echo -n c | __tcz_popup_readkey)

# tab STRIP: a full-width fake ShellFish tab bar (active bold title + faint ⋯
# tabs behind │ separators) — replaces the old single title chip (user: the
# preview should show the TAB BAR the tabs role paints, 2026-07-19)
set -l ts (__tcz_thp_tabstrip '#626f55' '#111111' 'rocket: tmux-lives (C)' 50)
t "tabstrip is exactly w cols" 50 (string length --visible -- (__tcz_strip_sgr "$ts"))
t "tabstrip carries the active title" 1 (string match -q '*rocket: tmux-lives (C)*' -- (__tcz_strip_sgr "$ts"); and echo 1; or echo 0)
t "tabstrip shows inactive tabs" 1 (string match -q '*│*⋯*│*⋯*' -- (__tcz_strip_sgr "$ts"); and echo 1; or echo 0)
set -l _tsb (printf '\e[1m')
t "tabstrip active tab is bold" 1 (string match -q "*$_tsb*" -- "$ts"; and echo 1; or echo 0)
t "tabstrip empty without tabs color" '' (__tcz_thp_tabstrip '' '#111111' 'x' 50 | string collect)
t "tabstrip empty without title" '' (__tcz_thp_tabstrip '#626f55' '#111111' '' 50 | string collect)
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

# ---------------------------------------------------------------------
# __tcz_thp_cells / __tcz_thp_band — swatches with a top gap
# ---------------------------------------------------------------------
# A terminal cannot shave pixels, but ▇ (U+2587, lower seven-eighths) drawn in the
# role colour leaves one eighth of the cell clear at the TOP, so stacked strips
# stop reading as one solid block. Foreground glyph, NOT a background fill.
t "cells fn exists" 1 (functions -q __tcz_thp_cells; and echo 1; or echo 0)
t "band fn exists"  1 (functions -q __tcz_thp_band; and echo 1; or echo 0)
set -g CELLS (__tcz_thp_cells '#112233 #223344 #334455 #445566 #556677 #667788 #778899')
t "cells is 14 visible cols" 14 (string length --visible -- "$CELLS")
t "cells uses the seven-eighths block" 14 (count (string match -ra '▇' -- "$CELLS"))
t "cells sets FOREGROUND, not background" 0 (count (string match -ra '48;2;' -- "$CELLS"))
t "cells carries each role colour" 1 (string match -q '*38;2;17;34;51*' -- "$CELLS"; and echo 1; or echo 0)
# a non-hex cell degrades to a blank gap, keeping the strip aligned
t "cells degrades non-hex to blanks" 14 (string length --visible -- (__tcz_thp_cells '#112233 nope #334455 #445566 #556677 #667788 #778899'))
set -g BAND (__tcz_thp_band '#5f772b')
t "band is 14 visible cols" 14 (string length --visible -- "$BAND")
t "band uses the same glyph"  14 (count (string match -ra '▇' -- "$BAND"))
t "band degrades non-hex to blanks" 14 (string length --visible -- (__tcz_thp_band nope))
# and the scheme row still measures the same as before
t "row strip is still 14 cols inside the row" 1 (string match -q '*▇▇*' -- (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 0 0); and echo 1; or echo 0)

# ---------------------------------------------------------------------
# __tcz_thp_staterow — the second list's row: name left, role label RIGHT
# ---------------------------------------------------------------------
t "staterow fn exists" 1 (functions -q __tcz_thp_staterow; and echo 1; or echo 0)
set -g SR (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'mono soft' current 0 1)
t "staterow is exactly w visible cols" 50 (string length --visible -- "$SR")
t "staterow shows the name" 1 (string match -q '*mono soft*' -- "$SR"; and echo 1; or echo 0)
t "staterow shows the label" 1 (string match -q '*current*' -- "$SR"; and echo 1; or echo 0)
# the label ends one column short of the border: exactly one trailing space
t "staterow label ends one col short" 1 (string match -qr 'current(\e\[[0-9;]*m)* $' -- "$SR"; and echo 1; or echo 0)
# live -> the label is bold in brand; not live -> muted
t "staterow live label wears brand" 1 (string match -q '*'(__tcz_theme brand)'current*' -- "$SR"; and echo 1; or echo 0)
set -g SRD (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'mono soft' current 0 0)
t "staterow not-live label wears muted" 1 (string match -q '*'(__tcz_theme muted)'current*' -- "$SRD"; and echo 1; or echo 0)
t "staterow not-live is still w cols" 50 (string length --visible -- "$SRD")
# selection puts the ▐ marker in brand and brightens the name
set -g SRS (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'legacy look' off 1 0)
t "staterow selected shows the marker" 1 (string match -q '*▐*' -- "$SRS"; and echo 1; or echo 0)
t "staterow selected is still w cols" 50 (string length --visible -- "$SRS")
# width holds for a long name and a short label, and vice versa
t "staterow long name still w cols" 50 (string length --visible -- (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'a-very-long-scheme-name-here' off 0 0))
# review finding 7: the pad-floor-of-1 above meant nlen+llen > w-18 used to
# push the printed row PAST w (__tcz_thp_ln, the caller's frame wrapper,
# pads to w but never truncates) — which wraps in the fixed-height popup and
# silently adds a physical row, exactly what the 26-row frame proof exists to
# prevent and, being an element count rather than a display-column
# measurement, cannot see. Unreachable with today's catalog (longest name is
# 11 cols) but an absurdly long name must still measure exactly w.
t "staterow absurdly long name still measures exactly w" 50 (string length --visible -- (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') (string repeat -n 40 x) current 0 0))
# it accepts a full 7-role strip too — the current row shows its real palette
t "staterow accepts a 7-role strip" 50 (string length --visible -- (__tcz_thp_staterow 50 (__tcz_thp_cells '#112233 #223344 #334455 #445566 #556677 #667788 #778899') 'mono soft' current 0 1))
# and the retired builder is gone (catfile isn't defined until further down
# the suite, so pin it locally here rather than forward-reference it)
set -l catfile $plugindir/functions/tmux-categorize.fish
t "off_row builder is gone" 0 (grep -c '__tcz_thp_off_row' $catfile)

# --- theme picker loop (interactive body = live smoke; wiring + structure tested) ---
t "main routes theme-picker" yes (string match -q '*case theme-picker*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
# Gallery picker rewrite, Task 2: _reload batches via the catalog now, not
# the v4 relationship list directly (superseded — see the "Gallery picker
# rewrite, Task 2" section further down for the catalog-wiring guards).
t "picker batches palettes via the catalog" yes (string match -q '*__tmux_lives_theme_catalog*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker applies through the CLI, silenced" yes (string match -q '*tmux-lives setup theme*>/dev/null 2>&1*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
# The phase arrows retired with the phase field; the SAME drain now serves ↑↓
# (and pgup/pgdn), which is what a held arrow needed all along — it used to
# queue one redraw per autorepeat press and scroll on for seconds after
# release. ↑↓ no longer SUM the drained burst into one net move (that traded
# the backlog for undrawn intermediate positions and an overshoot on
# release, Task 8) — they swallow it, moving one row per render cycle.
t "picker up/down drain swallows without accumulating" yes (begin; string match -q '*case up down*' -- (functions __tcz_theme_picker | string collect); and not string match -q '*case up down; set gap 1*' -- (functions __tcz_theme_picker | string collect); end; and echo yes; or echo no)
t "picker pages by WIN, not a literal" yes (string match -q '*case pgup; set steps (math "$steps - $WIN"); set gap 1*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker has no phase-delta arm left" no (string match -q '*math $delta + 5*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker restores the terminal on signals" yes (string match -q '*__tcz_thp_cleanup*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
# Theme v4 picker rewrite (Phase 2), Task 3: the contrast toggle (case d) and
# its --contrast/--rotate save flags are retired — 'd' is now free (place/mode
# moved to p/P/m/M), and the engine's --rotate flag ERRORS return 1, so the
# old save silently failed on every ⏎ before this fix.
t "picker contrast toggle (case d) retired" yes (not string match -qr 'case d\b' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker save no longer sends contrast/rotate" yes (begin; not string match -q '*--contrast*' -- (functions __tcz_theme_picker | string collect); and not string match -q '*--rotate*' -- (functions __tcz_theme_picker | string collect); end; and echo yes; or echo no)
t "picker frame: last row printed without newline" yes (string match -q '*$lines[1..-2]*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
# readkey's ESC/CSI-arrow branch leaves the tty in `min 1 time 0` (blocking) on
# return, so each drain iteration must re-assert non-blocking BEFORE reading —
# otherwise the second buffered read blocks forever (empirically confirmed hang).
# NB this specific literal (a gap-less "stty min 0 time 0") lives ONLY in the
# seed RGB-slider's ←→ drain (__tcz_thp_sliders) — a separate loop in a
# separate function from the ↑↓/pgup/pgdn drain below, which uses a variable
# gap ($gap) and has its own, differently-scoped pin further down ("picker
# drain re-asserts non-blocking inside the loop"). This test used to be named
# as if it covered that drain; it never did — renamed to say what it actually
# checks rather than retired, since the slider hang guard has no other cover.
t "picker seed-slider drain re-asserts non-blocking each iteration" 1 (string match -a -r 'while true(?=\n\s+stty min 0 time 0)' -- (functions __tcz_theme_picker | string collect) | count)
# The ↑↓/pgup/pgdn drain must NEVER escalate on the arrow arm: it only breaks
# on a poll TIMEOUT, so a gap=1 (~100ms) wait never times out while autorepeat
# keeps delivering faster than that — no redraw, no movement, until release
# (measured on this host: 2 rows moved in 2s of holding, at a 61ms redraw
# cost). Pages DO still escalate — they are discrete keypresses, never
# autorepeated in practice, so coalescing a burst of them is safe. A single
# press still settles instantly either way (first pass is gap=0).
t "picker drain re-asserts non-blocking inside the loop" 1 (string match -a -r 'while true(?=\n\s+stty min 0 time \$gap)' -- (functions __tcz_theme_picker | string collect) | count)
t "picker drain: arrows do not escalate, pages do" yes (begin; not string match -q '*case up down; set gap 1*' -- (functions __tcz_theme_picker | string collect); and test (count (string match -ar 'set gap 1' -- (functions __tcz_theme_picker | string collect))) -eq 2; end; and echo yes; or echo no)

# --- Gallery picker rewrite, Task 4: shake key (z) rewritten -------------
# Supersedes the earlier relationship-axis picker's shake (dae0155/3395e6d),
# which rerolled scheme+place+mode+phase independently. The gallery shake is
# simpler: place/mode are now baked into each catalog entry's recipe, so
# shaking only needs to (a) expand to the full 28-entry catalog (so any
# entry is reachable) and (b) land the cursor on a random entry — place/
# mode/phase follow automatically at apply/save time via the recipe + the
# live phase knob (case a/enter, Task 4 below).
set -l pk2 (functions __tcz_theme_picker | string collect)
t "picker has a shake arm" 1 (string match -q '*case z*' -- "$pk2"; and echo 1; or echo 0)
t "shake expands the catalog" 1 (string match -q '*case z*set expanded 1*' -- "$pk2"; and echo 1; or echo 0)
# fish landmine guard (2026-07-20 live bug, still relevant): capture random
# into a var BEFORE using it as an index — never inline it into quoted math.
t "shake captures random into a var first" 1 (string match -q '*set -l zi (random 0 (math $n - 1))*' -- "$pk2"; and echo 1; or echo 0)
# The bound must be DERIVED, never a literal: it was `random 0 27`, taken BEFORE the
# reload, so when the catalog grew past 28 the tail silently became unreachable.
t "shake bound is derived, not a literal" 0 (string match -qr 'random 0 [0-9]' -- "$pk2"; and echo 1; or echo 0)
t "shake selects the captured index" 1 (string match -q '*set sel $zi*' -- "$pk2"; and echo 1; or echo 0)
t "shake reloads BEFORE rolling (bound sees the expanded list)" 1 (string match -q '*set expanded 1*__tcz_thp_reload*set n (count $toks)*set -l zi (random 0 (math $n - 1))*set sel $zi*' -- "$pk2"; and echo 1; or echo 0)
t "shake no longer rerolls place/mode independently" yes (begin; not string match -q '*set place $places[$pi]*' -- "$pk2"; and not string match -q '*set mode $modes[$mi]*' -- "$pk2"; end; and echo yes; or echo no)

t "legend advertises z shake" 1 (string match -q '*z shake*' -- (__tcz_strip_sgr (__tcz_legend_row 12 '←→' phase m more z shake)); and echo 1; or echo 0)
# picker current-zone + legend-grid refinement, Task 1: the picker's legend
# is now the __tcz_thp_leg 3x3 grid (see the dedicated section below), which
# RE-ADDS the ↑↓ nav hint dropped here by the earlier gallery-picker-rewrite
# Task 4 (it had no room in the 2-row fixed-pitch layout). Superseded — the
# "dropped the nav hint" contract from that task no longer holds by design;
# real coverage now lives in "picker legend names nav (up/down move)" below.

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
# `pgrep -P` rescans all of /proc per call. It survives ONLY as the non-Linux
# fallback inside __tcz_pid_children; no call site may reintroduce it. Scoped by
# stripping that one function body, so the guard can't be satisfied by deleting
# the fallback and can't fire on the helper's own comment.
t "no pgrep -P outside __tcz_pid_children" 0 (awk '/^function __tcz_pid_children/,/^end$/ {next} {print}' $catfile | grep -c 'pgrep -P')
t "__tcz_pid_children keeps its fallback"  1 (awk '/^function __tcz_pid_children/,/^end$/' $catfile | grep -c '^ *pgrep -P')
# fish performs NO command substitution inside double quotes: `math "(random …) * 5"`
# hands math the LITERAL text (Unknown-function stderr into the popup) and the failed
# substitution leaves an EMPTY LIST that vanishes from unquoted arg lists downstream
# (2026-07-20 z-shake live bug: error spam + all-black palettes). Capture into a var
# BEFORE the math; this guard bans substitution-looking calls inside quoted math.
t "guard: no command substitution inside quoted math" 0 (count (string match -ar 'math "[^"]*\((?:random|date|count|string|math) ' -- (cat $catfile | string collect)))
# live-smoke regressions (2026-07-16): a QUOTED math-index ("$pals[(math ...)]") is an
# fish "Invalid index value" ERROR that sprays a 3-line stderr trace into the popup on
# EVERY draw (frame scrolls out + flicker + empty preview palette); the title edge must
# span the full inner width like every other row; and the frame must paint atomically
# (DECSET 2026, the __tcz_popup_draw pattern) or each redraw visibly flickers.
t "picker: no quoted math-index anywhere in the categorizer" 0 (grep -c '"\$[a-z]*\[(math' $catfile)
t "picker: title edge spans the full inner width" yes (string match -q '*$IW - 18*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "picker: draw wrapped in synchronized output" yes (string match -q '*2026h*' -- (functions __tcz_theme_picker | string collect); and string match -q '*2026l*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# perf fix + universal-persistence fix: the HOT path (reload/draw/readouts)
# is in-process, but every universal-TOUCHING action must go through a
# config-loaded `fish -c` subprocess — `fish --no-config` (the picker's
# runtime) neither READS nor WRITES universal variables, so an in-process
# `set -U`/`__tmux_lives_key` is silently wrong (2026-07-17 live bug: seed
# invisible, saves lost). Extract the function body (top-level `end` closes
# it; nested helpers' `end`s are indented).
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
set -l rbody (string match -r '(?s)function __tcz_thp_reload.*?\n    end' -- "$pbody")
t "guard: hot-path reload has no fish -c" 0 (string match -q '*fish -c*' -- "$rbody"; and echo 1; or echo 0)
t "guard: reload has no universal reads" 0 (string match -q '*__tmux_lives_key*' -- "$rbody"; and echo 1; or echo 0)
# picker-second-list Task 5 fix round: case a's second-list branch split
# from one site (anchor-or-off, sharing a call) into two (a-current, a-off),
# since off now needs its OWN apply_live call (`off bar derived`) rather than
# falling out of the old sel-linear else branch. 8 -> 9 sites.
# Task 7 (Esc restores the seed): the two seed-screen commits are GONE — the
# RGB-slider and typed-hex screens no longer touch the universal at all, they
# only reload the in-process preview — so those 2 sites drop out. A single
# NEW site takes their place: the exit path now commits the seed once, on
# save, only if it moved. Net -2 +1 = 9 -> 8.
t "guard: exactly 8 action-site subprocesses" 8 (count (string match -ar 'fish -c' -- "$pbody"))
# 8 = init + a-current + a-off + a-list + esc-revert + seed-commit-on-save + 2 saves (case-a's 3 branches are 3 textual sites, still one subprocess per press)
t "guard: picker sources the engine" 1 (string match -q '*conf.d/tmux-lives-install.fish*' -- "$pbody"; and echo 1; or echo 0)

# --- Task 7: the reload composes, it does not swap the row source ----------------
set -g RB7 (awk '/function __tcz_thp_reload/,/^    end$/' $catfile | string collect)
t "reload body extraction is non-empty" 1 (test -n "$RB7"; and echo 1; or echo 0)
t "reload composes with catalog_rest" yes (string match -q '*__tmux_lives_theme_catalog_rest*' -- "$RB7"; and echo yes; or echo no)
t "reload no longer swaps to the whole catalog wholesale" 0 (string match -ra 'set rows \(__tmux_lives_theme_catalog\)' -- "$RB7" | count)

# The two source-greps above are defeatable: e.g. appending catalog_rest BUT
# also prepending it ahead of the curated rows still contains the string
# "catalog_rest" and still avoids the banned wholesale-swap shape, so both
# checks pass while the "curated 14 first, then the rest" contract the More
# Schemes header depends on is broken. Prove composition DIRECTLY instead: eval
# the real function body (function definitions are global in fish regardless
# of where `function` runs) so __tcz_thp_reload becomes callable, then call it
# normally (not eval'd) from a throwaway wrapper that declares the locals it
# reads ($seed/$phase/$expanded) and writes ($toks/$pals/$fgs/$tabsfgs/
# $recipes/$cachekeys/$cacheblobs) — --no-scope-shadowing means the call
# operates directly on the wrapper's own locals, exactly as it does when
# called from inside __tcz_theme_picker's loop.
eval $RB7
function __t7_reload_compose --description 'call the REAL __tcz_thp_reload with expanded=1 against a throwaway scope; prints the composed $toks, one per line'
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    set -l cachekeys
    set -l cacheblobs
    set -l seed '#5f772b'
    set -l phase 0
    set -l expanded 1
    __tcz_thp_reload
    printf '%s\n' $toks
end
set -g TOKS7 (__t7_reload_compose)
t "reload composed, expanded: all 35 catalog rows present" 35 (count $TOKS7)
set -g DEFNAMES7
for e in (__tmux_lives_theme_catalog_default)
    set -a DEFNAMES7 (string split '|' -- $e)[1]
end
t "reload composed: exactly 14 curated names in catalog_default" 14 (count $DEFNAMES7)
t "reload composed: curated 14 come first, in catalog-default order" (string join \x1e -- $DEFNAMES7) (string join \x1e -- $TOKS7[1..14])

# --- Theme v4 picker rewrite (Phase 2), Task 1: engine wiring in _reload/_init ---
# _reload/_init must consume the v4 engine (__tmux_lives_theme_palette — 9-arg
# when this task shipped; theme-surface-cleanup Task 3 later dropped the four
# inert vividness/shape/ease/contrast trailers, so it's 5-arg now, see the Task 5
# arity guard below) instead of the deleted v3 machinery (theme_schemes/theme_ring/rotpal/the
# rotate universal). $pbody is the already-extracted __tcz_theme_picker
# function body from the guard block above. NB the relationship-list-iteration
# part of this contract is itself superseded by the Gallery picker rewrite's
# Task 2 (further down) — the picker now iterates catalog rows, not
# __tmux_lives_theme_relationships directly.
# Gallery picker rewrite, Task 2 (2026-07-24) further supersedes this: the
# relationship list is no longer referenced directly in the picker body at
# all (it comes in per-row via the catalog) — see the "Gallery picker
# rewrite, Task 2" guards further down for the current contract.
t "picker no longer iterates relationships directly" 0 (string match -q '*__tmux_lives_theme_relationships*' -- "$pbody"; and echo 1; or echo 0)
t "picker drops v3 schemes"       0 (string match -q '*__tmux_lives_theme_schemes*'      -- "$pbody"; and echo 1; or echo 0)
t "picker drops deleted ring"     0 (string match -q '*__tmux_lives_theme_ring*'         -- "$pbody"; and echo 1; or echo 0)
t "picker drops rotpal"           0 (string match -q '*__tcz_thp_rotpal*'                -- "$pbody"; and echo 1; or echo 0)
# Task 5: __tcz_thp_rotpal was the v3.2 display-side rotation-permutation
# builder — module-level (not nested in the picker, so not part of the
# helper-erase teardown block), left dangling once Task 1 dropped its
# _reload call and Task 3 dropped the o/O rotate keys. Confirmed zero callers
# anywhere in functions/ or conf.d/ before removal; the function is now gone
# entirely (not merely uncalled).
t "rotpal function fully removed" 0 (functions -q __tcz_thp_rotpal; and echo 1; or echo 0)
# Gallery picker rewrite, Task 2: place/mode are no longer LIVE picker knobs
# — _init originally dropped their universal reads entirely (per-catalog-
# entry fields now, read out of each row in _reload). Gallery Task 4 found
# that was too aggressive: the anchor snapshot (the persisted theme, frozen
# at open) still needs the PERSISTED place/mode to build its own recipe, so
# _init re-reads them (see the "anchor reads persisted place/mode" guards
# above) — just never as something a knob mutates during the loop. The
# universals themselves always existed for the CLI (conf.d/tmux-lives-
# install.fish, --place/--mode flags) — this guard is scoped to $pbody only.
t "picker drops rotate universal" 0 (string match -q '*tmux_lives_theme_rotate*' -- "$pbody"; and echo 1; or echo 0)

# Task 5: every __tmux_lives_theme_palette call in the picker body must carry
# the full v4 signature (seed relationship place mode phase) — a regression
# to a shorter call would silently drop a param and desync the preview from
# what the engine actually renders. theme-surface-cleanup Task 3 (2026-08-06)
# dropped the four inert vividness/shape/ease/contrast trailers the engine
# never read, so the honest contract is 5 args, not the old 9. Extract each
# call's argument text (everything between the function name and the closing
# paren of its command substitution) and count space-separated tokens, rather
# than a substring match, so this guard actually goes red if either call
# loses an arg.
set -l palcalls (string match -ar '.*__tmux_lives_theme_palette \$.*' -- (string split \n -- "$pbody"))
t "picker has exactly 2 palette calls" 2 (count $palcalls)
for pc in $palcalls
    set -l argtail (string replace -r '.*__tmux_lives_theme_palette ' '' -- $pc)
    set -l argstr (string replace -r '\).*' '' -- $argtail)
    set -l nargs (count (string split ' ' -- $argstr))
    t "palette call is 5-arg: $argstr" 5 $nargs
end

# --- Gallery picker rewrite, Task 2: _reload/_init consume the catalog ------
# Supersedes the "Task 1" engine-wiring section above (relationship-axis v4
# picker): the picker no longer treats place/mode as top-level knobs — they
# are now per-catalog-entry fields, read out of __tmux_lives_theme_catalog /
# __tmux_lives_theme_catalog_default rows in _reload. The palette signature
# itself is unchanged in shape (still relationship/place/mode positionally,
# just sourced from a catalog row instead of picker vars) — theme-surface-
# cleanup Task 3 shortened it 9->5 args, dropping the inert trailers.
t "picker uses catalog"             1 (string match -q '*__tmux_lives_theme_catalog*' -- "$pbody"; and echo 1; or echo 0)
t "picker default-12 accessor"      1 (string match -q '*__tmux_lives_theme_catalog_default*' -- "$pbody"; and echo 1; or echo 0)
t "picker drops relationships iter" 0 (string match -q '*for tok in (__tmux_lives_theme_relationships)*' -- "$pbody"; and echo 1; or echo 0)
t "picker has recipes array"        1 (string match -q '*recipes*' -- "$pbody"; and echo 1; or echo 0)
t "picker has expanded state"       1 (string match -q '*expanded*' -- "$pbody"; and echo 1; or echo 0)
t "picker still 5-arg palette"      1 (string match -q '*__tmux_lives_theme_palette $seed *$phase)*' -- "$pbody"; and echo 1; or echo 0)

# --- Gallery picker rewrite, Task 3: windowed scrolling list + linear nav ---
# __tcz_thp_window <sel> <total> <winsize> -> "<start> <count>", the 0-based
# first visible index + how many rows to draw, clamped so sel stays visible
# and the window never overruns total. Pure; module-level (not nested inside
# __tcz_theme_picker, so it is NOT part of the picker's --no-scope-shadowing
# helper teardown at the end of the function).
t "window: fits, no scroll"    "0 5"  (__tcz_thp_window 0 5 8)
t "window: top of long list"   "0 8"  (__tcz_thp_window 2 28 8)
# NB: "$sel - $winsize / 2" divides FIRST (8/2=4), so sel=12 centers at
# start=12-4=8 — pinning the literal transcribed formula's actual output,
# not a naively-centered "9" some other halving would give.
t "window: scrolled middle"    "8 8"  (__tcz_thp_window 12 28 8)
t "window: clamped at bottom"  "20 8" (__tcz_thp_window 27 28 8)
t "window: sel always visible" 1 (set -l w (__tcz_thp_window 15 28 8); set -l s (string split ' ' $w); test 15 -ge $s[1] -a 15 -lt (math $s[1] + $s[2]); and echo 1; or echo 0)
# fish's `math` is FLOATING-POINT division, not integer — an ODD winsize
# makes "$winsize / 2" land on .5 for EVERY sel, so an un-truncated start
# would be fractional on every non-clamped call, and a fractional
# $toks[$idx] downstream is a fish "Invalid index value" ERROR (live-
# breaking, not cosmetic; this is how the bug was originally caught, back
# when the render loop's $WIN was 7 — Task 5 moved the real WIN to 8, but
# the pure function must stay correct for ANY winsize, odd or even). Pins
# the --scale=0 truncation fix with an odd winsize=7 and a start that must
# land on a clean integer (12 - 7/2 = 8.5 -> truncated 8).
t "window: odd winsize stays integer (no fractional start)" "8 7" (__tcz_thp_window 12 28 7)
# --scale=0 truncates -0.5 toward zero to the STRING "-0", which the old
# `-lt 0` clamp didn't catch (`test -0 -lt 0` is false) -> caller's
# `string split ' ' -- "-0 7"` errored on "-0" as an unknown option.
t "window: sel=3 no -0 start" "0 7" (__tcz_thp_window 3 12 7)

# --- Theme v4 picker rewrite (Phase 2), Task 2: adjustments zone (place/mode)
# + the 6-relationship list ---
# Scope narrowly to the actual kv-zone regions rather than the whole $pbody:
# "place"/"mode" already appear elsewhere in the picker (var decls, v4
# _reload's cache key + the __tmux_lives_theme_relationships call), and
# "vividness"/"rotate" legitimately survive in the function docstring + the
# o/O/r/z dispatch (Tasks 3-5 territory) — so a whole-body substring check
# would either pass trivially before this edit or never go green after it.
# Anchor on the actual zsep call sites (non-greedy across the draw-loop kv
# lines) and the litkv function body.
# NB: string match -r's multi-line match output gets auto-split-then-space-
# joined by the enclosing command substitution unless piped through `string
# collect` (same "capture then quote" class of landmine as the rest of this
# file) — without it, embedded newlines vanish and a later `string split \n`
# sees one flattened line instead of several.
set -l zonebody (string match -r '(?s)__tcz_thp_zsep \$IW .adjustments.*?__tcz_thp_zsep \$IW' -- "$pbody" | string collect)
# Gallery rewrite Task 4 supersedes this Task 2 zone content: place/mode are
# no longer top-level knobs (they come from the selected catalog entry's
# recipe), so the adjustments zone shrinks further to seed + phase only.
t "zone drops place"       0 (string match -q '*place*'     -- "$zonebody"; and echo 1; or echo 0)
t "zone drops mode"        0 (string match -q '*mode*'      -- "$zonebody"; and echo 1; or echo 0)
t "zone drops vividness"   0 (string match -q '*vividness*' -- "$zonebody"; and echo 1; or echo 0)
t "zone drops rotate lbl"  0 (string match -q '*rotate*'    -- "$zonebody"; and echo 1; or echo 0)
# the brief's own regex for this ("kv .*place .\$place") is VACUOUS: a bare
# mid-pattern `$` in PCRE is an end-of-subject anchor, so `.*place .$place`
# can never match ANYTHING regardless of what the code says (verified: both
# a string containing `place "$place"` and one without it return no-match).
# Assert the real thing instead — the exact literal call text is gone.
t "zone drops place kv" 0 (string match -q '*seed "$seedchip" place "$place" mode "$mode"*' -- "$pbody"; and echo 1; or echo 0)
# Task 2 review Minor (folded in Task 5): the old form nested an uncollected
# greedy `string match -r` directly as a bare command-substitution argument —
# it worked, but relied on argument-splitting incidentals rather than an
# explicit gate. Conform to the zonebody/litbody discipline two lines above:
# a bounded, non-greedy regex piped through `string collect`, captured into
# its own var first.
# Task 5 cleanup: the label itself was ALSO stale — "relationship · hue-
# travels for your seed" described the pre-gallery relationship-axis picker;
# the gallery list is a list of curated SCHEMES (catalog entries). Genuine
# gate: this assertion was RED against the old "relationship" text before
# the rename. picker-second-list Task 5 (later) went further and made the
# rule BARE — no subtitle, no overflow markers — so the label match now
# targets the bare `schemes` token directly (no leading quote character).
set -l schemelabelbody (string match -r '(?s)__tcz_thp_zsep \$IW schemes.*?\)' -- "$pbody" | string collect)
t "list label is schemes" 1 (string match -q '*schemes*' -- "$schemelabelbody"; and echo 1; or echo 0)
t "list label drops stale relationship text" 0 (string match -q '*hue-travels for your seed*' -- "$pbody"; and echo 1; or echo 0)
t "adjustments label drops 'apply to all schemes'" 0 (string match -q '*apply to all schemes*' -- "$pbody"; and echo 1; or echo 0)
# __tcz_thp_kv and __tcz_thp_litkv are GONE: when phase was hidden, the zone
# (initially with 3 rows: zsep + label row + value row) collapsed to 2 rows
# (zsep + one horizontal row), and the kv builder was no longer needed.
t "picker has no lit-first repaint" 0 (string match -q '*__tcz_thp_litkv*' -- "$pbody"; and echo 1; or echo 0)
# The "zone renders seed label and value inline" check that used to live here
# (a grep of $pbody for the literal tokens 'configuration' and 'SEED')
# stopped tracking the render the moment picker-seed-section Task 3 replaced
# the single inline row with the fixed 8-row __tcz_thp_seedzone: the zsep
# label is now lowercase 'seed' and the readout row is a bare bold hex with
# no label, but both old literals still survive elsewhere in this function's
# own docstring/comments, so the grep kept reporting ok against a render it
# no longer described. Replaced with a real content check against the
# eval'd draw block (__t9_frame_text) — see "seed zone separator renders" /
# "seed hex renders in the zone" near that harness's own definition further
# down this file (the harness isn't defined yet at this point in the script).

# --- Gallery picker rewrite, Task 4: key dispatch — recipe-based
# apply/save (place+mode come from the SELECTED catalog entry's recipe, not
# user-cycled knobs), m repurposed to expand/collapse the 12->28 catalog, z
# shake picks a random catalog row. Supersedes the earlier v4-relationship-
# axis picker's p/P place-mode-cycle, m/M mode-toggle, and r reset keys
# (dae0155/45b66ed), which this task deletes outright. Final key map: up/
# down/jk move, left/right phase, b seed, m expand/collapse, z shake, a
# apply, enter save, esc/q close. $pbody is the already-extracted
# __tcz_theme_picker function body (defined above, Task 1 section).
t "no place-cycle key"         0 (string match -qr 'case p\b' -- "$pbody"; and echo 1; or echo 0)
t "no place-cycle-reverse key" 0 (string match -qr 'case P\b' -- "$pbody"; and echo 1; or echo 0)
t "no mode-toggle key"         0 (string match -qr 'case m M\b' -- "$pbody"; and echo 1; or echo 0)
t "no reset key"               0 (string match -qr 'case r\b' -- "$pbody"; and echo 1; or echo 0)
t "no vividness key"           0 (string match -qr 'case v\b' -- "$pbody"; and echo 1; or echo 0)
t "no rotate key"              0 (string match -qr 'case o\b' -- "$pbody"; and echo 1; or echo 0)
t "m is expand"                1 (string match -q '*expanded*' -- "$pbody"; and string match -qr 'case m\b' -- "$pbody"; and echo 1; or echo 0)
t "expand toggles the flag"    1 (string match -q '*test "$expanded" = 1; and set expanded 0; or set expanded 1*' -- "$pbody"; and echo 1; or echo 0)
# picker-second-list Task 5: off/current left the linear sel range entirely
# (they now live on sel2, a separate list), so the post-expand clamp target
# moved from n+1 (old off/anchor tail) to n-1 (the new last scheme row).
t "expand clamps sel to the last scheme row" 1 (string match -q '*set -l lastrow (math $n - 1)*test $sel -gt $lastrow; and set sel $lastrow*' -- "$pbody"; and echo 1; or echo 0)
t "save reads recipes"         1 (string match -q '*recipes[*' -- "$pbody"; and echo 1; or echo 0)
t "apply-preview derives from recipe" 1 (string match -qr '(?s)case a\b.*?recipes\[' -- "$pbody"; and echo 1; or echo 0)
t "save derives from recipe"          1 (string match -qr '(?s)case enter\b.*?recipes\[' -- "$pbody"; and echo 1; or echo 0)
t "save passes --place" 1 (string match -q '*--place*' -- "$pbody"; and echo 1; or echo 0)
t "save passes --mode"  1 (string match -q '*--mode*'  -- "$pbody"; and echo 1; or echo 0)
# fish landmine guard: no command substitution inside quoted math (z-shake)
t "shake captures random first" 0 (count (string match -ar 'math "[^"]*\(random' -- "$pbody"))
# anchor snapshot: place/mode Task 2 dropped as picker-level READS turn out to
# still be needed — the anchor's own (relationship, place, mode) tuple must
# reflect the PERSISTED theme, not the (now-deleted) live place/mode knobs.
t "anchor reads persisted place" 1 (string match -q '*tmux_lives_theme_place*' -- "$pbody"; and echo 1; or echo 0)
t "anchor reads persisted mode"  1 (string match -q '*tmux_lives_theme_mode*'  -- "$pbody"; and echo 1; or echo 0)

# --- Theme v4 picker rewrite (Phase 2), Task 4: anchor place/mode snapshot +
# v4 legend. Task 3 left a forward reference — its case-a/case-enter sel-0
# (anchor) branches already read $anch_place/$anch_mode (see lines using
# `$anch_place`/`$anch_mode` in the apply/save arms) — so those vars must be
# CAPTURED here for the picker to even parse. A whole-$pbody substring check
# for "anch_place"/"place" would pass VACUOUSLY even before this task's
# edits: "place"/"mode" already pervade $pbody (adjustments zone, Task 2/3
# dispatch), and the literal substring "anch_place" already appears at the
# Task-3 forward-reference sites. Scope narrowly instead: (a) the anchor
# SNAPSHOT declaration block itself (bounded by its own comment through the
# first post-snapshot var), and (b) the actual __tcz_thp_ln-wrapped
# legend-row draw calls (not the whole file/function body).
set -l anchsnap (awk '/anchor snapshot: the persisted theme/,/set -l anchpal/' $catfile | string collect)
t "anchor snapshots place" 1 (string match -q '*set -l anch_place*' -- "$anchsnap"; and echo 1; or echo 0)
t "anchor snapshots mode"  1 (string match -q '*set -l anch_mode*'  -- "$anchsnap"; and echo 1; or echo 0)
t "anchor drops rotate"    0 (string match -q '*anch_rotate*' -- "$anchsnap"; and echo 1; or echo 0)
# the anchor's OWN palette-build call must also carry the v4 signature (seed
# relationship place mode phase) — the same v3-breakage Task 1 fixed for the
# main list. theme-surface-cleanup Task 3 shortened this 9->5 args, dropping
# the inert vividness/shape/ease/contrast trailers. Checked against the full
# $pbody since this exact call text is unique to this site.
t "anchor palette call is 5-arg (place+mode, drops rotate)" 1 (string match -q '*__tmux_lives_theme_palette $seed $anch_scheme $anch_place $anch_mode $anch_phase)*' -- "$pbody"; and echo 1; or echo 0)

# picker current-zone + legend-grid refinement, Task 1: the two fixed-pitch
# __tcz_legend_row calls (was 2, itself "was 3" before the gallery rewrite)
# are folded into ONE __tcz_thp_leg 3-col grid call — see the dedicated
# section below for the row-count/content coverage that replaces this.
set -l leglines (string match -r -- "__tcz_thp_leg .*" $pbody)
t "legend is built via a single __tcz_thp_leg call" 1 (count $leglines)
# Gallery rewrite Task 4: place/mode are no longer knobs, so the legend no
# longer names them (m is repurposed to expand — see "legend names more").
t "legend drops place" 0 (string match -q '*place*' -- $leglines; and echo 1; or echo 0)
t "legend drops mode"  0 (string match -q '*mode*'  -- $leglines; and echo 1; or echo 0)
t "legend names more"  1 (string match -q '*more*' -- $leglines; and echo 1; or echo 0)
t "legend names shake" 1 (string match -q '*shake*' -- $leglines; and echo 1; or echo 0)
t "legend drops contrast"  0 (string match -qr 'contrast' -- $leglines; and echo 1; or echo 0)
t "legend drops vividness" 0 (string match -qr 'vivid'    -- $leglines; and echo 1; or echo 0)
# brief's literal guard: no __tcz_legend_row call anywhere in the categorizer
# still names the retired rotate knob (this scope is whole-file, but genuine:
# before this task exactly one legend_row call names "rotate").
t "legend drops rotate" 0 (string match -qr 'rotate' -- (awk '/__tcz_legend_row/' $catfile | string collect); and echo 1; or echo 0)

# --- picker v4 — 26-row windowed frame, key-map + dead-knob guards ---
set -l catsrc (cat $catfile | string collect)
t "guard: no theme_polarity in categorizer" 0 (string match -q '*tmux_lives_theme_polarity*' -- "$catsrc"; and echo 1; or echo 0)
t "guard: no theme_range in categorizer" 0 (string match -q '*tmux_lives_theme_range*' -- "$catsrc"; and echo 1; or echo 0)
# Gallery picker rewrite, Task 5: the fixed 6-relationship-row list (Tasks
# 1-4 predecessor) became a WINDOWED WIN=8 scheme list, so the frame grew
# 22->24 rows. Picker current-zone + legend-grid refinement, Task 3
# (2026-07-25): the current zone gained its own `├─ current ─┤` zsep (+1)
# and the legend grid grew 2->3 rows (+1), so the frame grew AGAIN 24->26 —
# the emitted-row count was recounted directly off the draw loop's
# `set -a lines` call sites. 2026-07-29: seed+phase moved from two stacked
# kv pairs onto ONE space-between row pair, freeing 2 static rows, which
# went to the WINDOW rather than shrinking the frame (the catalog had just
# grown 28->37, later re-weeded to 35 — see the mono-slate dedup fix). So
# the split was 15 static (chrome/off/current-zsep/anchor/legend×3) +
# WIN=11 scheme rows = 26 — SAME total, CONSTANT across the 14-vs-35
# catalog size. The exact-height contract (rows 1..-2 with \n,
# last without) demands -h == emitted; 27/24/22/20 are stale everywhere.
# picker-seed-section Task 1 (2026-08-07): 26 was a FIXED number, which
# cannot survive a shorter client (a popup taller than the client refuses to
# open on 3.3a). -h is now a percentage and WIN is derived from the popup's
# own reported size at open time — see the WINSRC block below, which pins
# the discriminators for that change. 26/27/24/22/20 are now ALL stale.
t "picker popup: no stale 52x26 anywhere" 0 (string match -q '*-w 52 -h 26*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x27 anywhere" 0 (string match -q '*-w 52 -h 27*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x24 anywhere" 0 (string match -q '*-w 52 -h 24*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x22 anywhere" 0 (string match -q '*-w 52 -h 22*' -- "$catsrc"; and echo 1; or echo 0)
t "picker popup: no stale 52x20 anywhere" 0 (string match -q '*-w 52 -h 20*' -- "$catsrc"; and echo 1; or echo 0)
# "picker draw loop: WIN is 11" is retired here, not merely renamed: it pinned
# the OLD hardcoded literal as the CORRECT state, which is now the exact thing
# being removed. The WINSRC block immediately below is its replacement.

# --- Task 1: WIN is derived from the popup height ------------------------------
set -g WINSRC (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$WINSRC"; and echo 1; or echo 0)
t "picker no longer hardcodes a window size" 0 (string match -ra 'set -l WIN 11' -- "$WINSRC" | count)
t "picker reads its own popup size" 1 (string match -qr 'stty size' -- "$WINSRC"; and echo 1; or echo 0)
t "no open site still pins 26 rows" 0 (grep -c -- '-w 52 -h 26' $catfile)

# --- picker-seed-section Task 2: preview and cancel emit the tab OSC directly ---
# Without this the tab lags the status bar by up to one status-interval (15s) in
# BOTH directions, so ESC appears not to restore. Force mode, not dedup: the dedup
# cache would suppress a restore that returns to an already-emitted value.
set -g PB2 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB2"; and echo 1; or echo 0)
t "picker emits the tab colour on preview/cancel" yes (string match -qr '__tcz_recolor' -- "$PB2"; and echo yes; or echo no)
t "picker's recolor calls are force, not dedup" 0 (string match -ra '__tcz_recolor[^\n]*dedup' -- "$PB2" | count)

# --- picker-seed-section Task 3: the seed zone ------------------------------------
# FIXED height whether idle or editing, so toggling edit mode never makes the
# scheme list jump. Idle shows readouts in the three rows that become sliders.
t "seedzone exists" 0 (functions -q __tcz_thp_seedzone; echo $status)
set -g SZ (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 0 1 95 119 43)
t "seedzone is exactly 8 rows" 8 (count $SZ)
for i in (seq 8)
    set -l v (string replace -ra '\x1b\[[0-9;]*m' '' -- "$SZ[$i]")
    # w + 2: the border glyphs are part of every row in this frame.
    t "seedzone row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
t "seedzone shows the hex when idle" yes (string match -q '*5f772b*' -- (string join ' ' $SZ); and echo yes; or echo no)
# The anti-jump property: editing must not change the row count.
set -g SZE (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 1 95 119 43)
t "seedzone is 8 rows while editing too" 8 (count $SZE)
t "editing renders bars, idle does not" yes (test "$SZ[6]" != "$SZE[6]"; and echo yes; or echo no)

# --- Task 3: the retired knobs are gone from the picker -------------------------
# Bounded to the picker body: these names legitimately survive nowhere else in
# this file, but an unbounded grep would also match unrelated prose.
set -g PBODY3 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker: no vividness local"  0 (string match -ra 'set -l viv ' -- "$PBODY3" | count)
t "picker: no shape local"      0 (string match -ra 'set -l shape ' -- "$PBODY3" | count)
t "picker: no ease local"       0 (string match -ra 'set -l ease ' -- "$PBODY3" | count)
t "picker: no contrast local"   0 (string match -ra 'set -l contrast ' -- "$PBODY3" | count)
t "picker: no anch_viv"         0 (string match -ra 'anch_viv' -- "$PBODY3" | count)
# Positive counterpart: the palette calls must still EXIST, so the guards above
# cannot be satisfied by deleting the calls outright.
t "picker: still has exactly 2 palette calls" 2 (string match -ra '__tmux_lives_theme_palette ' -- "$PBODY3" | count)

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

# --- anchor row: static pins ---
set -l pk (functions __tcz_theme_picker | string collect)
t "picker snapshots the anchor after init" 1 (string match -q '*set -l anch_scheme $theme*' -- "$pk"; and echo 1; or echo 0)
t "picker anchor palette computed once at open" 1 (string match -q '*__tmux_lives_theme_palette $seed $anch_scheme*' -- "$pk"; and echo 1; or echo 0)
t "picker cursor starts on the top scheme (sel 0)" 1 (string match -q '*set -l sel 0*' -- "$pk"; and echo 1; or echo 0)
t "picker anchor enter saves the snapshot" 1 (string match -q '*set apply $anch_scheme*' -- "$pk"; and echo 1; or echo 0)
# the apply_live preview form is relationship place mode phase —
# anch_place/anch_mode read the anchor's own persisted place/mode.
# theme-surface-cleanup Task 3 (2026-08-06) dropped the inert trailing
# viv/shape/ease/contrast args this call used to carry.
t "picker anchor a-preview uses snapshot args" 1 (string match -q '*$anch_scheme $anch_place $anch_mode $anch_phase*' -- "$pk"; and echo 1; or echo 0)
t "thp_restore is gone" 0 (functions -q __tcz_thp_restore; and echo 1; or echo 0)
# picker-second-list Task 5: off and the current/anchor row moved into a
# SECOND list at the bottom (its own cursor, sel2, reached with ⇥ — see the
# "second list + ⇥ focus" section further down). Draw order within it is now
# current BEFORE off (was off then anchor, pre-Task-5) — the current row is
# the var $currow, and off keeps its old var name $offrow.
t "picker draws the second list: current before off" 1 (string match -qr '(?s)set -a lines \(__tcz_thp_ln "\$currow".*set -a lines \(__tcz_thp_ln "\$offrow"' -- "$pk"; and echo 1; or echo 0)
# one vismap call now — inside the step loop, so a multi-row jump reuses the SAME
# clamp as a single press (the current zone stays out of the ↑↓ walk).
t "picker up/down go through vismap" 1 (count (string match -ar '__tcz_thp_vismap \$sel \$n' -- "$pk"))
t "picker steps through vismap in a loop" 1 (string match -q '*for _i in (seq (math "abs($steps)"))*' -- "$pk"; and echo 1; or echo 0)
# picker-second-list Task 5: off and current/anchor left the ↑↓ order
# ENTIRELY — they are no longer sel values at all (n and n+1 respectively);
# they live on sel2, a separate list reached only via ⇥ (dispatch, tested in
# the "second list + ⇥ focus" section further down). vismap's down-clamp
# moved from n (off) to n-1 (the last scheme) — off is not a stop anymore.
# "vismap down clamps at n (off), not n+1" (a call with sel=10=n) is DELETED
# outright, not rewritten: sel=n is now simply an out-of-range input for this
# n=10 convention, and the concept it pinned — off as a walkable stop — no
# longer exists. The equivalent in-range coverage (n=5, both directions,
# every sel 0..n-1) lives in the "second list + ⇥ focus" section's
# "vismap never yields n" test.
t "vismap: down from last scheme stays (off left the walk)" 9 (__tcz_thp_vismap 9 10 down)
t "vismap: an out-of-range sel still clamps to n-1" 9 (__tcz_thp_vismap 11 10 down)
# up has NO upper clamp by design — it only ever decrements or floors at 0
# (see __tcz_thp_vismap's description) — so these two still return their
# pre-Task-5 values verbatim; only their framing ("current zone", "off") is
# retired, since sel=n/n+1 are no longer meaningful positions to begin with.
t "vismap: up decrements without an upper clamp" 10 (__tcz_thp_vismap 11 10 up)
t "vismap: up from n decrements to n-1" 9 (__tcz_thp_vismap 10 10 up)
t "vismap: up from scheme 0 stays" 0 (__tcz_thp_vismap 0 10 up)
t "vismap: plain moves work" 3 (__tcz_thp_vismap 2 10 down)

# --- Gallery picker rewrite, Task 4: preview-palette lookup + list marker go
# LINEAR (sel 0..n-1 scheme / n off / n+1 anchor), matching Task 3's vismap.
# Pre-Task-4 the lookup used the OLD numbering (sel 0 = anchor, 1..n =
# schemes 1-indexed, >n = off) and the marker compared row NAME to the
# anchor RELATIONSHIP — always false, since $toks holds catalog entry names
# ("ember glow") while $anch_scheme holds a relationship ("ember").
t "marker compares the full recipe, not the name" 1 (string match -q '*test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"*' -- "$pk"; and echo 1; or echo 0)
t "marker no longer compares toks to anch_scheme" 0 (string match -q '*test "$toks[$idx]" = "$anch_scheme"*' -- "$pk"; and echo 1; or echo 0)
t "preview indexes pals at the captured sel+1" 1 (string match -q '*set -l pi (math $sel + 1)*set curpal $pals[$pi]*' -- "$pk"; and echo 1; or echo 0)
# picker-second-list Task 5 fix round: the preview lookup's off/current branch
# is no longer `test $sel -eq $n; or test -z "$anchpal"` (retired along with
# every other consumer of the linear sel range) — it now branches on
# `focus`/`sel2` like the rest of the second-list consumers (case a, case
# enter). Empty anchpal still falls through to the same legacy/off palette.
t "preview second-list branch checks sel2 and anchpal" 1 (string match -q '*test $sel2 -eq 0; and test -n "$anchpal"*' -- "$pk"; and echo 1; or echo 0)

set -l catsrc3 (cat $catfile | string collect)
# picker current-zone + legend-grid refinement, Task 3 (2026-07-25): 52x26 is
# now the CURRENT correct popup geometry (was a stale v3.1/Phase-2 value
# guarded against here pre-windowing) — the "no stale 52x24" guard above
# (picker v4 section) now plays that role for the value THIS task retires.

# --- Task 4: lit-first kv repaint before recompute ---
set -l pk3 (functions __tcz_theme_picker | string collect)
# The lit-first kv repaint is retired: its only callers were the ←→ phase arms.
t "no orphaned litkv definition" 0 (string match -q '*function __tcz_thp_litkv*' -- "$pk3"; and echo 1; or echo 0)
t "no orphaned litkv cleanup" 0 (string match -q '*functions -e __tcz_thp_litkv*' -- "$pk3"; and echo 1; or echo 0)
# the anchor keeps the PERSISTED phase even though the picker pins its working
# phase at 0 — otherwise confirming your own theme would silently zero it.
t "anchor snapshots the persisted phase" 1 (string match -q '*set -l anch_phase $persisted_phase*' -- "$pk3"; and echo 1; or echo 0)
t "persisted phase is loaded from init" 1 (string match -q '*set persisted_phase $init*' -- "$pk3"; and echo 1; or echo 0)

# --- v3.3 Task 2: preview decolor — claude renders in the windows-role fg,
# not the old static coral. ---
t "guard: preview coral gone" 0 (string match -q '*D97757*' -- (cat $catfile | string collect); and echo 1; or echo 0)
set -l pvbody (functions __tcz_thp_preview | string collect)
t "guard: preview no longer defines a coral var" 0 (string match -q '*coral*' -- "$pvbody"; and echo 1; or echo 0)
t "preview claude segment uses the windows-role fg" 1 (string match -q '*"$barbg $winfg""claude*' -- "$pvbody"; and echo 1; or echo 0)

# --- v3.3 Task 3: iTerm2 mirroring — detection + emission + wiring ---
set -g tmux_lives_fake_environ 'LC_TERMINAL=iTerm2'
t "client_terminal detects iTerm2" iterm2 (__tcz_client_terminal 4242)
t "is_shellfish false for iTerm2" 1 (__tcz_client_is_shellfish 4242; echo $status)
set -g tmux_lives_fake_environ 'LC_TERMINAL=ShellFish'
t "client_terminal detects ShellFish" shellfish (__tcz_client_terminal 4242)
t "is_shellfish wrapper still true" 0 (__tcz_client_is_shellfish 4242; echo $status)
set -g tmux_lives_fake_environ 'TERM=xterm-256color'
t "client_terminal other" other (__tcz_client_terminal 4242)
set -e tmux_lives_fake_environ
# emit_itermtab escape bytes (write to a temp file standing in for the tty)
set -l tf (mktemp)
__tcz_emit_itermtab $tf '#576733'
set -l want (printf '\e]6;1;bg;red;brightness;87\a\e]6;1;bg;green;brightness;103\a\e]6;1;bg;blue;brightness;51\a' | string escape)
t "itermtab triplet exact" "$want" (cat $tf | string escape)
__tcz_emit_itermtab $tf notahex
set -l wantr (printf '\e]6;1;bg;*;default\a' | string escape)
t "itermtab reset on non-hex" "$wantr" (cat $tf | string escape)
rm -f $tf
# wiring pins: each emission path has an iterm2 branch. The brief's sketched
# `(?s)function X.*iterm2.*^end` form does NOT match here — `(?s)` (DOTALL) lets
# `.` cross newlines but does NOT imply `(?m)` (MULTILINE), so `^end` still only
# anchors to the start of the WHOLE string, never to a mid-file line start; it
# never matches. Body-scoped via the suite's established `awk '/^function X/,/^end$/'`
# style instead (already used above for __tcz_theme_picker/__tcz_thp_reload).
set -l recolor_body (awk '/^function __tcz_recolor/,/^end$/' $catfile | string collect)
set -l onattach_body (awk '/^function __tcz_on_attach/,/^end$/' $catfile | string collect)
set -l retitle_body (awk '/^function __tcz_retitle/,/^end$/' $catfile | string collect)
t "recolor handles iterm2" 1 (string match -q '*iterm2*' -- "$recolor_body"; and echo 1; or echo 0)
t "on-attach handles iterm2" 1 (string match -q '*iterm2*' -- "$onattach_body"; and echo 1; or echo 0)
t "retitle handles iterm2" 1 (string match -q '*iterm2*' -- "$retitle_body"; and echo 1; or echo 0)

# --- picker current-zone + legend-grid refinement, Task 1: __tcz_thp_leg
# aligned legend grid (cross-row column widths). The bug this replaces: the
# old two-call __tcz_legend_row wiring computed each ROW's cell widths
# independently, so column 3 landed at a different x on every row. The new
# builder takes ALL <key,desc> pairs at once and sizes each column by the
# MAX width across every row, so descriptions line up regardless of which
# row's icon happens to be longer.
set -l L (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake c current  a apply '⏎' save esc close)
t "leg emits 3 rows" 3 (count $L)
set -l lp1 (__tcz_strip_sgr $L[1])
set -l lp2 (__tcz_strip_sgr $L[2])
set -l lp3 (__tcz_strip_sgr $L[3])
# Exact plain-text rows — the strongest cross-row-alignment gate: had any
# column's width been computed per-row instead of as the max over all rows,
# these literal strings would NOT match (concrete, hand/script-verified
# offsets, not derived from the implementation itself).
t "leg row1 exact text" ' ↑↓ move    ⇞⇟ page    b   seed   ' "$lp1"
t "leg row2 exact text" ' m  more    z  shake   c   current' "$lp2"
t "leg row3 exact text" ' a  apply   ⏎  save    esc close  ' "$lp3"
# Column-3 desc starts at the SAME visible offset (col 28) on every row —
# the defining cross-row-alignment property, checked directly by position.
t "leg col3 desc aligns row1" seed    (string sub -s 28 -l 4 -- "$lp1")
t "leg col3 desc aligns row2" current (string sub -s 28 -l 7 -- "$lp2")
t "leg col3 desc aligns row3" close   (string sub -s 28 -l 5 -- "$lp3")
# Column-1 and column-2 descs likewise align across rows (offsets 5 and 16).
t "leg col1 desc aligns row1" move  (string sub -s 5 -l 4 -- "$lp1")
t "leg col1 desc aligns row2" more  (string sub -s 5 -l 4 -- "$lp2")
t "leg col1 desc aligns row3" apply (string sub -s 5 -l 5 -- "$lp3")
t "leg col2 desc aligns row1" page (string sub -s 16 -l 4 -- "$lp1")
t "leg col2 desc aligns row2" shake (string sub -s 16 -l 5 -- "$lp2")
t "leg col2 desc aligns row3" save  (string sub -s 16 -l 4 -- "$lp3")
# icon<->desc gap is exactly 1 space, checked on an UNPADDED cell (col2,
# row1: key width 2 == keyw, desc width 5 == descw, so the single space
# between them is purely the separator, not incidental padding).
t "leg icon-desc gap is 1 space" '⇞⇟ page' (string sub -s 13 -l 7 -- "$lp1")
# each row fits inside the picker's IW (50)
t "leg row1 fits IW" 1 (test (string length --visible -- "$lp1") -le 50; and echo 1; or echo 0)
t "leg row2 fits IW" 1 (test (string length --visible -- "$lp2") -le 50; and echo 1; or echo 0)
t "leg row3 fits IW" 1 (test (string length --visible -- "$lp3") -le 50; and echo 1; or echo 0)
# colors sourced from the shared theme accessor (consistent with every other
# picker element) — key tan, desc muted
t "leg key colored" 1 (string match -q '*38;2;245;207;138*' -- "$L[1]"; and echo 1; or echo 0)
t "leg desc muted"  1 (string match -q '*38;2;154;138;114*' -- "$L[1]"; and echo 1; or echo 0)
# malformed input (odd pair count) guard: no output
t "leg guards odd pair count" 0 (count (__tcz_thp_leg 3 a b c))

# picker wiring: the legend is now ONE __tcz_thp_leg 3-col call (9 pairs),
# not two fixed-pitch __tcz_legend_row calls — supersedes the pre-gallery-
# refinement assertions below that grepped for the old call pattern.
set -l pbody2 (functions __tcz_theme_picker | string collect)
set -l leggrid (string match -r -- "__tcz_thp_leg 3 .*" $pbody2)
t "picker legend is a single __tcz_thp_leg 3-col call" 1 (count $leggrid)
# scoped to the two RETIRED bottom-legend calls specifically (pitch 12/9) —
# NOT a whole-body absence check, since __tcz_theme_picker's inline seed
# screens (b/t) still legitimately call the shared __tcz_legend_row at
# pitch 14 (out of scope for this task; left untouched).
t "picker drops the old pitch-12 legend_row call" 0 (string match -q '*__tcz_legend_row 12*' -- "$pbody2"; and echo 1; or echo 0)
t "picker drops the old pitch-9 legend_row call"  0 (string match -q '*__tcz_legend_row 9*'  -- "$pbody2"; and echo 1; or echo 0)
t "picker seed-screen legend_row (pitch 14) untouched" 1 (string match -q '*__tcz_legend_row 14*' -- "$pbody2"; and echo 1; or echo 0)
t "picker legend names nav (up/down move)" 1 (string match -q '*↑↓*move*' -- "$leggrid"; and echo 1; or echo 0)
# picker-second-list Task 5: the c key is retired; the legend now advertises
# ⇥ for current/off (the second list), not a bare "current" reached by c.
t "picker legend names current/off (tab)" 1 (string match -q '*current/off*' -- "$leggrid"; and echo 1; or echo 0)
t "picker legend still names more"  1 (string match -q '*more*' -- "$leggrid"; and echo 1; or echo 0)
t "picker legend still names shake" 1 (string match -q '*shake*' -- "$leggrid"; and echo 1; or echo 0)
t "picker legend still drops place" 0 (string match -q '*place*' -- "$leggrid"; and echo 1; or echo 0)
t "picker legend still drops mode"  0 (string match -q '*mode*'  -- "$leggrid"; and echo 1; or echo 0)

# --- picker current-zone + legend-grid refinement, Task 2: the ❯ list marker
# gated on phase as well as recipe. Superseded by picker-second-list Task 5
# for the jump-key/zsep coverage: the current zone is no longer a pinned
# sel-n+1 tail reached by pressing c — it is a row in a SECOND list, reached
# by ⇥, tested in the "second list + ⇥ focus" section further down (readkey's
# tab token, `focus`/`sel2`, `case tab`, the untitled zsep, "current/off" in
# the legend). ---
set -l pk2 (functions __tcz_theme_picker | string collect)
t "picker has case c (retired, superseded by tab)" 0 (string match -qr 'case c\b' -- "$pk2"; and echo 1; or echo 0)
t "tab toggles focus between list and state" 1 (string match -q '*test $focus = list; and set focus state; or set focus list*' -- (string replace -ra '\s+' ' ' -- "$pk2"); and echo 1; or echo 0)
t "marker gates on phase" 1 (string match -q '*test "$phase" = "$anch_phase"*' -- "$pk2"; and echo 1; or echo 0)
# the titled `├─ current ─┤` zsep is retired (the second list is untitled);
# in its place, the second list gets its OWN untitled zsep — count 2 total,
# the pre-existing blank separator before the legend plus this new one.
# NB: match PER LINE, not against the whole multi-line $pk2 — a glob match
# against the whole string returns the whole string as its one "match",
# which command substitution then re-splits on newlines, making `count`
# report the picker's total LINE count instead of the occurrence count.
t "second list gets its own untitled zsep" 2 (count (string match -- "*zsep \$IW ''*" -- (string split \n -- "$pk2")))
# named risk (task brief): __tcz_popup_readkey is SHARED with the session
# switcher — its dispatch switch must have NO case c, so the token stays
# a harmless no-op there instead of accidentally doing something. Still true
# post-Task-5: readkey keeps mapping the 'c' byte to the token "c" (just
# unused in the picker now), and the switcher never had a case for it.
set -l switcher_body (functions __tcz_popup | string collect)
t "switcher has no case c (readkey's c token is a safe no-op there)" 0 (string match -qr 'case c\b' -- "$switcher_body"; and echo 1; or echo 0)

# --- picker current-zone + legend-grid refinement, Task 3: geometry recount
# (26-row frame -- see the "picker v4 — 26-row windowed frame" section above
# for the -h/-w/WIN pins), the frame-encloses invariant, adjustments-zone
# alignment, and a consolidated pass over the dead-code/key guards the brief
# calls out (most already exist from Tasks 1-2 and the earlier gallery-
# rewrite cycle; this section is the single consolidated checkpoint).

# Frame-encloses: the current/anchor row and every legend row must be
# wrapped in __tcz_thp_ln (padded to IW + │...│-framed), same as every other
# content row -- and the bottom border (╰...╯) must be the LAST `set -a
# lines` emission in the draw loop (nothing appends after it).
# picker-second-list Task 5: the anchor row was renamed $currow (it lives in
# the second list now, alongside $offrow — also frame-enclosed, unchanged).
t "current row is frame-enclosed (thp_ln)" 1 (string match -q '*set -a lines (__tcz_thp_ln "$currow" $IW $BORDER $RST)*' -- "$pk2"; and echo 1; or echo 0)
t "off row is frame-enclosed (thp_ln)" 1 (string match -q '*set -a lines (__tcz_thp_ln "$offrow" $IW $BORDER $RST)*' -- "$pk2"; and echo 1; or echo 0)
t "legend rows are frame-enclosed (thp_ln)" 1 (string match -qr '(?s)for lline in \(__tcz_thp_leg.*set -a lines \(__tcz_thp_ln "\$lline" \$IW \$BORDER \$RST\)' -- "$pk2"; and echo 1; or echo 0)
set -l allsetlines (string match -ar 'set -a lines.*' -- "$pk2")
t "bottom border is the last emitted line" 1 (string match -q '*╰*' -- "$allsetlines[-1]"; and echo 1; or echo 0)

# --- configuration zone: seedrow flash affordance ---
# The configuration zone renders SEED label + value on one row. The label wears
# the flash role when the user is editing the seed (flashfield = seed), else muted.
set -g SRW (__tcz_thp_seedrow seed 'CHIP')
set -g SRN (__tcz_thp_seedrow '' 'CHIP')
t "seedrow flashes the label when flagged" 1 (string match -q '*'(__tcz_theme flash)'SEED*' -- "$SRW"; and echo 1; or echo 0)
t "seedrow label is muted when not flagged" 1 (string match -q '*'(__tcz_theme muted)'SEED*' -- "$SRN"; and echo 1; or echo 0)
t "seedrow carries no flash SGR when not flagged" 0 (string match -q '*'(__tcz_theme flash)'*' -- "$SRN"; and echo 1; or echo 0)
t "seedrow flash is width-neutral" (string length --visible -- "$SRN") (string length --visible -- "$SRW")
t "seedrow shows the value" 1 (string match -q '*CHIP*' -- "$SRN"; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# layout history: this section once checked a horizontal SEED-label+value
# row via source-text greps for 'configuration'/'SEED' — superseded by
# picker-seed-section Task 3's fixed 8-row __tcz_thp_seedzone (lowercase
# 'seed' separator, no label on the readout row). Those two checks moved to
# real content assertions against __t9_frame_text ("seed zone separator
# renders" / "seed hex renders in the zone", near that harness's own
# definition further down this file — see the note at the old inline-row
# site above for why they couldn't just be fixed in place).
# ---------------------------------------------------------------------
set -g PK (functions __tcz_theme_picker | string collect)
t "the old adjustments title is gone" 0 (string match -q '*adjustments*' -- "$PK"; and echo 1; or echo 0)
t "the two-row kv builder is gone"     0 (grep -c '__tcz_thp_kv' $catfile)
t "the spread builder is gone"         0 (grep -c '__tcz_thp_spread' $catfile)
# picker-seed-section Task 1: WIN is derived from the popup's own reported
# height, not a hardcoded literal — "scheme window is 11 rows" retired above
# (WINSRC block) in favor of this same fact, checked here via the $PK
# extraction mechanism instead of raw source text.
t "scheme window is no longer a hardcoded literal" 0 (string match -ra 'set -l WIN 11' -- "$PK" | count)
t "WIN is defined exactly once"        1 (count (string match -ra 'set -l WIN ' -- "$PK"))
t "no stale WIN 10"                    0 (string match -q '*set -l WIN 10*' -- "$PK"; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# second list + ⇥ focus
# ---------------------------------------------------------------------
# readkey gains one token. Safe for the SHARED switcher: __tcz_popup's dispatch
# has cases only for up/down/enter/kill/cancel and NO case '*', so an unlisted
# token is silently ignored there — the same argument that covered p/P/m/M and c.
t "readkey maps 0x09 to tab" 1 (string match -q '*case 09*tab*' -- (functions __tcz_popup_readkey | string collect); and echo 1; or echo 0)
set -g POPBODY (functions __tcz_popup | string collect)
t "switcher has no tab arm"   0 (string match -q '*case tab*' -- "$POPBODY"; and echo 1; or echo 0)
t "switcher still has no catch-all" 0 (string match -q "*case '*'*" -- "$POPBODY"; and echo 1; or echo 0)

# vismap now clamps to the SCHEME list only — off left it, so n is no longer a stop
t "vismap down stops at n-1" 4 (__tcz_thp_vismap 4 5 down)
t "vismap up stops at 0"     0 (__tcz_thp_vismap 0 5 up)
t "vismap walks normally"    3 (__tcz_thp_vismap 2 5 down)
t "vismap never yields n"    0 (set -l bad 0; for s in 0 1 2 3 4; for d in up down; test (__tcz_thp_vismap $s 5 $d) -ge 5; and set bad 1; end; end; echo $bad)

set -g PK2 (functions __tcz_theme_picker | string collect)
t "picker tracks focus"      1 (string match -q '*set -l focus list*' -- "$PK2"; and echo 1; or echo 0)
t "picker tracks sel2"       1 (string match -q '*set -l sel2 0*' -- "$PK2"; and echo 1; or echo 0)
t "picker has a tab arm"     1 (string match -q '*case tab*' -- "$PK2"; and echo 1; or echo 0)
## Brief's literal pattern here was '*case c*' — that ALSO matches "case cancel"
## (a substring, not a whole word), so it can never read 0 regardless of whether the
## "case c" arm exists — verified: `string match -q '*case c*' -- 'case cancel'`
## returns true. Fixed to the word-boundary regex the rest of this file already
## uses for the identical check (e.g. the consolidated guard below).
t "the c key is retired"     0 (string match -qr 'case c\b' -- "$PK2"; and echo 1; or echo 0)
t "legend offers current/off" 1 (string match -q '*current/off*' -- "$PK2"; and echo 1; or echo 0)
t "legend drops the c entry"  0 (string match -q '*c current*' -- "$PK2"; and echo 1; or echo 0)
# the schemes rule loses its subtitle and scroll counts
t "schemes rule is bare"      0 (string match -q '*near-seed*' -- "$PK2"; and echo 1; or echo 0)
t "no scroll-count marks"     0 (string match -q '*▲*' -- "$PK2"; and echo 1; or echo 0)
# the second list's rule is untitled
t "second list rule is untitled" 0 (string match -q "*__tcz_thp_zsep \$IW 'current'*" -- "$PK2"; and echo 1; or echo 0)
# no chevrons anywhere, and the retired switcher-yellow is gone with them
t "no chevron in the picker"  0 (count (string match -ra '❯' -- "$PK2"))
# Scoped to $PK2 (the picker's own body) this was VACUOUS: 38;5;179 never
# lived in __tcz_theme_picker at all — only in __tcz_thp_row/__tcz_thp_off_row
# (the off_row builder is already gone, checked above) — so it read 0 at the
# pre-branch commit too and could never have caught a regression. Re-scoped to
# the WHOLE FILE, minus the two unrelated legitimate uses of the same accent
# colour (__tcz_popup_list_lines' switcher pointer, __tcz_modal_legend's
# launcher accent) via awk range-deletion, so a reintroduction anywhere in the
# picker actually fails this.
set -l without179 (awk '
    /^function __tcz_popup_list_lines/ {skip=1}
    /^function __tcz_modal_legend/ {skip=1}
    skip && /^end$/ {skip=0; next}
    !skip {print}
' $plugindir/functions/tmux-categorize.fish | string collect)
t "switcher-yellow retired (whole file, minus its two legitimate uses)" 0 (count (string match -ra '38;5;179' -- "$without179"))

# ---------------------------------------------------------------------
# fix round: the three consumers of the OLD linear sel range (preview
# palette lookup, case a, case enter) are rewired to branch on `focus`/
# `sel2` too — the movement rewiring alone left `sel == $n` and
# `sel == (math $n + 1)` UNREACHABLE, silently dead-ending the second list's
# preview/apply/save paths.
# ---------------------------------------------------------------------
set -g PK5 (functions __tcz_theme_picker | string collect)
# Bounded, not whole-body: a plain '*case a*focus = state*' / '*case enter*
# focus = state*' glob against the WHOLE $PK5 is VACUOUS — verified against
# the pre-fix body, both read "ok" there. Two reasons: (1) "case enter" occurs
# THREE times in this function's source — once in the real dispatch, twice
# more in nested `function ... end` DEFINITIONS earlier in the body
# (__tcz_thp_hexentry / __tcz_thp_sliders' seed-entry loops) — so a bare
# substring search can latch onto the wrong one; (2) "focus = state" already
# appears earlier in the body regardless of whether case a/enter were ever
# fixed (the up/down dispatch and the second-list draw both have it). Bound
# to the region between "case a" and "case cancel" — both occur EXACTLY ONCE
# in this function (verified), so the region between them is unambiguously
# the real case-a/case-enter dispatch arms and nothing else.
set -l dispatch_tail (string match -r '(?s)case a\b.*?case cancel\b' -- "$PK5" | string collect)
t "apply branches on focus" 1 (string match -qr '(?s)case a\b.*?focus = state.*?case enter\b' -- "$dispatch_tail"; and echo 1; or echo 0)
t "save branches on focus"  1 (string match -qr '(?s)case enter\b.*?focus = state' -- "$dispatch_tail"; and echo 1; or echo 0)
t "off is reachable from the second list" 1 (string match -q '*set apply off*' -- "$dispatch_tail"; and echo 1; or echo 0)
# Same vacuity risk for the preview lookup: "curpal" and "focus = state" each
# recur elsewhere in the body too. "curpal" only spans the cursor-row-palette
# block itself — bound from its first assignment to the next statement after
# the block (`set -l ptoks`, unique, immediately follows it) instead.
set -l curpalblock (string match -r '(?s)set -l curpal .*?set -l ptoks' -- "$PK5" | string collect)
t "preview palette branches on focus" 1 (string match -q '*focus = state*' -- "$curpalblock"; and echo 1; or echo 0)
# no consumer may still read the retired sel range — this is the guard that would
# have caught all three sites at once
t "no surviving reads of the retired sel range" 0 (count (string match -ra 'sel -eq \$n|sel -eq \(math \$n \+ 1\)' -- "$PK5"))

# ---------------------------------------------------------------------
# `current` is a live-state readout, not a static label
# ---------------------------------------------------------------------
set -g PK3 (functions __tcz_theme_picker | string collect)
# previewed is three-valued: 0 none, 1 a LISTED scheme, 2 the current row.
# Bounded to the current-row branch alone (case a's sel2 -eq 0 arm) so a fix
# that flips the WRONG branch to previewed 2 can't pass by coincidence — a
# bare `case a\b` substring is unsafe here: a comment two arms up literally
# reads "case a/enter" and would be matched instead of the real case label.
set -l currowblock (string match -r '(?ms)^ *case a$.*?sel2 -eq 0\b.*?else\b' -- "$PK3" | string collect)
t "current-row preview sets previewed 2"           1 (string match -q '*set previewed 2*' -- "$currowblock"; and echo 1; or echo 0)
t "current-row preview no longer sets previewed 1" 0 (string match -q '*set previewed 1*' -- "$currowblock"; and echo 1; or echo 0)
# the off row and the listed-scheme branch both still set previewed 1 —
# exactly twice across the whole apply arm now that the current row moved
# to 2 (regression guard: the two OTHER sites must stay put).
set -l applyarm (string match -r '(?ms)^ *case a$.*?^ *case enter$' -- "$PK3" | string collect)
t "off and listed-scheme previews both stay at previewed 1" 2 (count (string match -ar 'set previewed 1' -- (string split \n -- "$applyarm")))
t "exactly one site sets previewed 2"                        1 (count (string match -ar 'set previewed 2' -- (string split \n -- "$applyarm")))
# islive is computed from previewed, not the Task 5 placeholder alone. A
# bare '*set -l islive*' (or even '*set -l islive 1*') substring already
# matches the placeholder by itself, both before AND after this fix — the
# real fix's init line is still literally "set -l islive 1", now followed
# by a narrowing test — so a plain substring check can never go RED here.
# Anchored instead to the actual adjacency: the init line immediately
# followed by the narrowing line.
t "islive is derived from previewed" 1 (string match -qr 'set -l islive 1\s*\n\s*test \$previewed -eq 1; and set islive 0' -- "$PK3"; and echo 1; or echo 0)
t "islive is false only for a listed preview" 1 (string match -q '*test $previewed -eq 1*islive 0*' -- "$PK3"; and echo 1; or echo 0)
# the revert on cancel must still fire for BOTH preview kinds
t "cancel reverts for any preview" 1 (string match -q '*test $previewed -ne 0*' -- "$PK3"; and echo 1; or echo 0)
# and the Task 5 placeholder — islive pinned to 1 with nothing computing it
# — is gone. Anchored to the OLD adjacency (the placeholder directly
# followed by the zsep call, nothing narrowing in between), which only the
# unfixed code exhibits — a bare '*set -l islive 1*' substring would still
# match the fixed code's own init line and could never go GREEN.
t "the islive placeholder is gone" 0 (string match -qr 'set -l islive 1\s*\n\s*set -a lines \(__tcz_thp_zsep' -- "$PK3"; and echo 1; or echo 0)

# Consolidated guards: case c retired (picker-second-list Task 5 — superseded
# by tab); the retired axis keys/functions stay gone; the titled current zsep
# is retired along with it (superseded by the second list's own untitled
# zsep + __tcz_thp_leg wiring, both in place); vismap never hands back n (off
# left the walk entirely, not just n+1); the palette call-site count is still
# 2 (arity is pinned separately by the per-call arg-count loop at ~line 1654).
t "consolidated guard: case c retired (superseded by tab)" 0 (string match -qr 'case c\b' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: no case p (retired)"  0 (string match -qr 'case p\b' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: no theme_ring"        0 (string match -q '*__tmux_lives_theme_ring*' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: no rotpal"            0 (string match -q '*__tcz_thp_rotpal*' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: no --rotate flag"     0 (string match -q '*--rotate*' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: titled current zsep retired" 0 (string match -q "*__tcz_thp_zsep \$IW 'current'*" -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: uses __tcz_thp_leg"   1 (string match -q '*__tcz_thp_leg 3*' -- "$pk2"; and echo 1; or echo 0)
t "consolidated guard: vismap never yields n (off left the walk)" 1 (test (__tcz_thp_vismap 10 10 down) -eq 9; and test (__tcz_thp_vismap 11 10 down) -eq 9; and echo 1; or echo 0)
t "consolidated guard: exactly 2 palette call sites" 2 (count (string match -ar '.*__tmux_lives_theme_palette \$.*' -- (string split \n -- "$pk2")))

# ---------------------------------------------------------------------
# Esc restores the seed: the seed screens are preview-only, ⏎ commits
# ---------------------------------------------------------------------
# The RGB-slider and typed-hex screens used to commit immediately via the
# CLI colour setter, which writes the universal, re-renders the fragment and
# applies live — so Esc had nothing to restore to, and since every role
# derives from the seed, the whole scheme looked unrestored too even with
# its own universals intact. Now the screens only mutate the in-picker
# $seed var and reload the in-process preview; ⏎ at the top level commits,
# and cancel restores both the theme AND the seed.
set -l catfile $plugindir/functions/tmux-categorize.fish
set -g SLB (functions __tcz_theme_picker | string collect)
# the anchor snapshot carries the seed so cancel can restore it
t "anchor snapshot captures the seed" 1 (string match -q '*set -l anch_seed $seed*' -- "$SLB"; and echo 1; or echo 0)
# live preview shadows the universal in the child rather than writing it
t "preview shadows the seed in the child" 1 (string match -q '*set -g tmux_lives_bar_color*' -- "$SLB"; and echo 1; or echo 0)
# Bounded, not whole-body: same vacuity risk as the earlier "dispatch_tail"
# checks — a bare '*case a*' substring would also catch the "(case a/enter"
# comment inside the z-shake key's explanation, two arms up. Anchored to the
# whole line instead ("^ *case a$"), which only the real dispatch arm is.
set -l casea (string match -r '(?ms)^ *case a$.*?^ *case cancel$' -- "$SLB" | string collect)
t "all three case-a previews shadow the seed" 3 (count (string match -ar 'set -g tmux_lives_bar_color' -- "$casea"))
set -l cancelblock (string match -r '(?ms)^ *case cancel$.*?^ *end$' -- "$SLB" | string collect)
t "cancel restores by shadowing the anchor seed" 1 (string match -q "*__tmux_lives_theme_apply_live' \"\$anch_seed\"*" -- "$cancelblock"; and echo 1; or echo 0)
# saving commits the seed — exactly once, in the EXIT path, never in a seed
# screen. awk scopes the two seed screens out first (both are NESTED
# functions indented 4 spaces — verified non-empty below rather than trusted
# blind); the commit call must survive only outside them.
set -g SEEDSCREENS (awk '/^    function __tcz_thp_sliders/,/^    end$/' $catfile; awk '/^    function __tcz_thp_hexentry/,/^    end$/' $catfile | string collect)
t "seed-screen extraction is non-empty (sliders+hexentry)" 1 (test (string length -- "$SEEDSCREENS") -gt 0; and echo 1; or echo 0)
t "no setup-color commit inside the seed screens" 0 (count (string match -ra 'setup color' -- "$SEEDSCREENS"))
# NB the brief's whole-body version of this check ("seed screens do not run
# setup color", asserted 0 against $SLB rather than $SEEDSCREENS) is
# self-contradictory with the very next test below once the exit-path commit
# exists — $SLB legitimately contains exactly one "setup color" after this
# fix, not zero. Dropped in favor of the two SEEDSCREENS-scoped checks above,
# which is what it actually meant to test.
t "exactly one setup-color commit in the whole picker" 1 (count (string match -ra 'setup color' -- "$SLB"))
t "the commit is guarded on a changed seed" 1 (string match -q '*"$seed" != "$anch_seed"*' -- "$SLB"; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# review finding 2: anchpal (the `current` row's own palette) was computed
# ONCE, before the loop, from whatever seed the picker opened with. Every
# SCHEME row already re-derives from $seed via __tcz_thp_reload; the current
# row's band did not — its band, and the top preview/tab chip whenever the
# cursor sat on it, kept rendering the OLD seed after a seed preview even
# though `a`/`⏎` had already moved on to the new one. __tcz_thp_reanchor
# factors this out so it can run again anywhere $seed changes.
# ---------------------------------------------------------------------
t "reanchor function exists" 1 (string match -q '*function __tcz_thp_reanchor*' -- "$SLB"; and echo 1; or echo 0)
t "reanchor runs once at open, right after its own definition" 1 (string match -qr '(?s)function __tcz_thp_reanchor.*?\n    end\n    __tcz_thp_reanchor\n' -- "$SLB"; and echo 1; or echo 0)
t "both seed screens reanchor immediately after reload" 2 (count (string match -ar '__tcz_thp_reload\n\s*__tcz_thp_reanchor' -- "$SEEDSCREENS"))
t "reanchor is erased on exit like its seed-screen siblings" 1 (string match -q '*functions -e __tcz_thp_reanchor*' -- "$SLB"; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# held ↑↓ rate-limits with DISCARD, it does not accumulate
# ---------------------------------------------------------------------
set -g DRAIN (string match -r '(?s)case up down pgup pgdn.*?case tab' -- (functions __tcz_theme_picker | string collect))
t "the drain arm was found" 1 (test -n "$DRAIN"; and echo 1; or echo 0)
# a queued up/down must NOT add to steps — that is the accumulate-and-jump bug
t "queued arrows do not accumulate" 0 (count (string match -ra 'case up;   set steps \(math "\$steps - 1"\)' -- "$DRAIN"))
# a queued up/down must not RE-ARM the drain's ~100ms poll either — the loop
# only exits on a poll TIMEOUT, so escalating here (the pre-fix "case up
# down; set gap 1") meant a held key never redrew at all until release.
# Superseded/deduplicated the old "queued arrows are swallowed" test, which
# pinned the same literal this one now pins the absence of, at a different
# scope than the whole-body "picker drain: arrows do not escalate, pages do".
t "queued arrows do not escalate the gap" 0 (string match -q '*case up down; set gap 1*' -- "$DRAIN"; and echo 1; or echo 0)
# ...and the page arms still do — losing this would silently regress Task 8's
# page-coalescing property ("pages still coalesce" just below).
t "page arms still escalate the gap" 2 (count (string match -ar 'set gap 1' -- "$DRAIN"))
# pages DO still coalesce — they are discrete and not autorepeated
t "pages still coalesce" 1 (string match -q '*case pgup;*steps*WIN*' -- "$DRAIN"; and echo 1; or echo 0)
# the drain-hang guard must survive: readkey's CSI branch leaves the tty BLOCKING
t "drain re-asserts non-blocking inside the loop" 1 (string match -q '*while true*stty min 0 time $gap*' -- "$DRAIN"; and echo 1; or echo 0)
t "drain restores blocking on exit" 1 (string match -q '*stty min 1 time 0*' -- "$DRAIN"; and echo 1; or echo 0)

# ---------------------------------------------------------------------
# Task 9 — prove the frame is exactly 26 rows, in every state, DIRECTLY.
#
# The brief's own Step 1 gave five grep-style assertions (WIN==11,
# __tcz_thp_leg 3-col, "two untitled rules", popup height ==26, no stale
# height). Checked each against the current tree before trusting it (the
# coordinator flagged four earlier waves of defective assertions on this
# branch). All five are individually CORRECT, but four of the five DUPLICATE
# tests Tasks 4-6 already shipped: "scheme window is 11 rows" (WIN==11),
# "picker legend is a single __tcz_thp_leg 3-col call" (the legend-cols
# check), "second list gets its own untitled zsep" (the two-untitled-rules
# count), and "picker popup is 52x26 (modal open site)" (the height check) —
# all above in this file. Re-adding them under new names would be bloat with
# no new discriminating power, so only the genuine strengthening is kept: a
# single broad regex over stale heights 10-19/20-25/27-29, which the four
# existing discrete 27/24/22/20 literals above do not cover (e.g. 21/23/25/
# 28/29/10-19).
# picker-seed-section Task 1: -h is now a percentage everywhere, so EVERY
# fixed 2-digit -h literal 10-29 is stale, including 26 (deliberately
# excluded from the range above at the time it was still current).
set -l catsrc9 (cat $catfile | string collect)
t "frame: no stale popup heights (broad)" 0 (count (string match -ra '\-w 52 \-h (2[0-9]|1[0-9])' -- "$catsrc9"))

# The actual Step-1 deliverable: a DIRECT count of what the draw loop emits,
# not indirect evidence (a `set -a lines` site count, or reading the WIN
# literal). Every __tcz_thp_* row builder the draw calls (ln/zsep/leg/row/
# staterow/window/tabstrip/preview/seedrow/cells/band) is a TOP-LEVEL
# function in this file, not nested inside __tcz_theme_picker — so the real
# per-iteration draw block (from the cursor-row palette lookup through the
# bottom border) can be extracted VERBATIM from the live file and evaluated
# against real input state, with zero reimplementation of the row-building
# logic. `eval`, not `source`: fish's `source` opens its OWN local scope (a
# `set -l` inside a sourced file does not survive the source call returning
# — verified against a minimal repro), so `set -l lines` inside the
# extracted block would vanish before it could be counted; `eval` runs
# inline in the calling scope, which is what lets $lines survive.
set -g DRAWTEXT9 (awk '/set -l curpal/,/╰/' $catfile | string collect)
t "frame: draw-block extraction is non-empty" 1 (test -n "$DRAWTEXT9"; and echo 1; or echo 0)

function __t9_frame_rows --argument-names focus sel2 n sel previewed anch_scheme anchpal flashfield expanded ndefault rows --description 'eval the REAL draw block against a given picker state; returns the row count it produced. flashfield is included for completeness (it guards color/timing of the read AFTER the draw, not row count) rather than because this range reads it today. expanded/ndefault are Task 8 additions (More Schemes header + virtual-row window); omitted by pre-Task-8 callers, which leaves them empty and reproduces the pre-header behavior exactly. picker-seed-section Task 1: rows is the popup height WIN is derived from (WIN = rows - 21, matching the real function — picker-seed-section Task 3 raised STATIC 15->21 when the seed became a fixed 8-row zone, and this copy was updated to match); defaults to 26 (todays fixed size) when omitted, so every pre-Task-1 caller keeps pinning exactly what it always has.'
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l IW 50
    test -n "$rows"; or set rows 26
    set -l WIN (math "$rows - 21")
    set -l host somehost
    set -l chiptitle ''
    set -l note 'a note'
    set -l seed '#5f772b'
    set -l seedfg '#f5f5f5'
    set -l phase 0
    set -l legacy '#444444'
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    for i in (seq $n)
        set -a toks "scheme$i"
        set -a pals '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
        set -a fgs '#f5f5f5'
        set -a tabsfgs '#f5f5f5'
        set -a recipes 'mono|bar|derived'
    end
    eval $DRAWTEXT9
    set -g __t9_last_lines $lines
    count $lines
end

function __t9_frame_text --description 'same eval as __t9_frame_rows, but returns the rendered rows so CONTENT can be asserted, not just the row count'
    __t9_frame_rows $argv >/dev/null
    printf '%s\n' $__t9_last_lines
end

set -l PAL9 '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'

# --- picker-seed-section Task 3 (review fix): the seed zone's RENDERED content --
# Two source-text greps further up this file used to stand in for this (the
# "zone renders seed inline" / "zone is titled configuration" / "SEED label
# and value share one row" checks) by matching the picker's SOURCE for the
# literal tokens 'configuration' and 'SEED'. That genuinely tracked the
# render before this task: the zone separator's label WAS 'configuration'
# and __tcz_thp_seedrow DID print a SEED label. picker-seed-section Task 3's
# __tcz_thp_seedzone wiring renders neither any more — the separator label
# is lowercase 'seed' and the readout row is a bare bold hex with no label —
# but both old literals happen to survive elsewhere in this function's own
# docstring/comments, so the old greps kept reporting ok against a render
# they no longer described. These assert the REAL draw block output
# (__t9_frame_text, the same eval-based harness the frame proof below uses)
# instead, and had to move here because that harness isn't defined until
# this point in the file. Seed value matches __t9_frame_rows's own fixed
# harness state ('#5f772b').
set -l seedframe (string join \n -- (__t9_frame_text list 0 14 0 0 mono "$PAL9" ''))
set -l seedframev (__tcz_strip_sgr "$seedframe")
t "seed zone separator renders" yes (string match -q '*├─ seed*' -- "$seedframev"; and echo yes; or echo no)
t "seed hex renders in the zone" yes (string match -q '*#5f772b*' -- "$seedframev"; and echo yes; or echo no)

# Every meaningfully distinct draw path: the window's top/bottom clamp at
# both catalog sizes, which list has focus, which second-list row is
# selected, all three `previewed` values, the persisted-theme-off edge case
# (anchpal genuinely empty, exactly as the real init leaves it), and an
# active change-flash.
t "frame: 26 rows — scheme list, window top, n=14"      26 (__t9_frame_rows list  0 14 0  0 mono "$PAL9" '')
t "frame: 26 rows — scheme list, window bottom, n=14"   26 (__t9_frame_rows list  0 14 13 0 mono "$PAL9" '')
t "frame: 26 rows — scheme list, mid, n=37 (larger than the 35-row catalog)"  26 (__t9_frame_rows list  0 37 20 0 mono "$PAL9" '')
t "frame: 26 rows — scheme list, end, n=37 (larger than the 35-row catalog)"  26 (__t9_frame_rows list  0 37 36 0 mono "$PAL9" '')
t "frame: 26 rows — second list, current selected"      26 (__t9_frame_rows state 0 14 0  0 mono "$PAL9" '')
t "frame: 26 rows — second list, off selected"          26 (__t9_frame_rows state 1 14 0  0 mono "$PAL9" '')
t "frame: 26 rows — previewing a listed scheme (1)"     26 (__t9_frame_rows list  0 14 0  1 mono "$PAL9" '')
t "frame: 26 rows — previewing the current row (2)"     26 (__t9_frame_rows state 0 14 0  2 mono "$PAL9" '')
t "frame: 26 rows — persisted theme off, anchpal empty" 26 (__t9_frame_rows state 0 14 0  0 off  ''      '')
t "frame: 26 rows — seed change-flash active"           26 (__t9_frame_rows list  0 14 0  0 mono "$PAL9" seed)

# --- Task 8: frame stays 26 with the header, and the header exists only expanded --
# The harness evals the REAL draw block, so it cannot drift from the implementation.
t "frame: 26 rows — expanded, header on screen"     26 (__t9_frame_rows list 0 35 13 0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — expanded, scrolled past header" 26 (__t9_frame_rows list 0 35 30 0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — expanded, top of list"          26 (__t9_frame_rows list 0 35 0  0 mono "$PAL9" '' 1 14)
# sel=34 is the very last of the 35 catalog rows: the window clamps against
# the end (same clamped start as sel=30 above) and the row loop reaches
# idx=35 — toks[35], the highest valid index into a 35-element $toks. An
# off-by-one in the virtual-row math (vtotal/vsel) is most likely to surface
# exactly here, not at the mid-list states above.
t "frame: 26 rows — expanded, very bottom"          26 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14)
t "frame: 26 rows — collapsed is unchanged"         26 (__t9_frame_rows list 0 14 0  0 mono "$PAL9" '' 0 14)

# --- picker-seed-section Task 1: WIN is derived from the popup height, not fixed --
# The real function reads its own popup height via `stty size` and sets
# WIN = rows - 21; __t9_frame_rows now takes that same rows value and derives WIN
# identically, so these prove the frame still emits EXACTLY its height at sizes
# other than todays fixed 26. picker-seed-section Task 3 raised STATIC 15->21 (the
# seed became a fixed 8-row zone) and this harness's own WIN formula + the floor
# below were updated to match — the two are independent copies of the same
# number, and letting them disagree is exactly what made every one of these
# fail uniformly by 6 (the STATIC delta) until this edit landed. NB the "52 rows"
# case no longer also demonstrates the Step-4b padding branch the way it did
# pre-Task-3 (WIN shrank 37->31, now below the 36-row expanded virtual list it
# used to exceed) — padding is still exercised structurally by the window loop
# (it always fills to WIN, real rows or blanks), just not by this particular size.
t "frame: emits exactly its height — 26 rows (today's size)" 26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26)
t "frame: emits exactly its height — 39 rows"                39 (__t9_frame_rows list 0 35 0 1 mono "$PAL9" '' 1 14 39)
t "frame: emits exactly its height — 52 rows"                52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52)
t "frame: emits exactly its height — 24 rows (the floor)"    24 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 24)

# --- picker-seed-section Task 3 (review fix): restore coverage for the padding branch --
# None of the four sizes above satisfies vtotal <= WIN any more (raising STATIC
# 15->21 shrank WIN at every one of them below the collapsed n=14 catalog's virtual
# total), so Task 1's blank-row padding block (__tcz_theme_picker, the winpad loop
# right after the scheme window) had lost ALL coverage — deleting it outright still
# left every assertion above green. This closes that gap directly: n=14 unexpanded
# (vtotal=14) at rows=40 gives WIN=19, which DOES exceed vtotal, so the window loop
# draws all 14 real rows and the padding branch must fill the remaining 5 with blank
# framed rows for the total to reach 40 at all.
t "frame: emits exactly its height — 40 rows (drives the padding branch, WIN=19 > n=14)" 40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40)

# The header must appear ONLY when expanded, and only while it's still inside
# the scrolled window — this is the fix-discriminator.
t "header absent when collapsed" 0 (__t9_frame_text list 0 14 5 0 mono "$PAL9" '' 0 14 | string match -ra 'More Schemes' | count)
t "header present when expanded near the boundary" 1 (__t9_frame_text list 0 35 13 0 mono "$PAL9" '' 1 14 | string match -ra 'More Schemes' | count)
# Same scrolled-past state as "expanded, scrolled past header" above (sel=30):
# only the collapsed case was ever asserted header-free before this.
t "header absent when expanded and scrolled past" 0 (__t9_frame_text list 0 35 30 0 mono "$PAL9" '' 1 14 | string match -ra 'More Schemes' | count)

# --- Task 9: collapsing from below the header, run for real -----------------
# Task 8's coverage of "collapsing lands sel/n in range" was a SOURCE-TEXT
# GREP over the case-m handler (see the RB7-style "reload composes"
# assertions above), not an execution — grep cannot see whether $sel actually
# ends up in bounds after the toggle. Extract the case-m body itself with awk
# (same technique as $RB7 above) and eval it for real, starting EXPANDED with
# the cursor on a hidden row (sel=30 is index 31 of 35 — inside the 21
# appended "rest" rows, since ndefault=14), then pressing m once.
set -g CASEM9 (awk '/case m$/,/set flashfield/' $catfile | string collect)
t "case-m body extraction is non-empty" 1 (test -n "$CASEM9"; and echo 1; or echo 0)
# `case` is a switch-only builtin: eval'ing the extracted body alone is a
# RUNTIME error ("'case' builtin not inside of switch block"), because eval
# parses its argument as an independent script — a REAL switch statically
# wrapped around the eval CALL does not splice into it (a switch's direct
# child must itself be a literal `case` at parse time, and $CASEM9 is only
# known at runtime). So the switch wrapper has to be part of the SAME
# eval'd string as the case-m body, not a real switch surrounding the call.
set -g CASEM9WRAP "switch m
$CASEM9
end"
function __t9_case_m --description 'run the REAL case-m handler (via $CASEM9WRAP) against a throwaway scope that declares every local the body reads or writes, with the REAL __tcz_thp_reload already global (eval\'d from $RB7 above). Starts EXPANDED (14 curated + 21 more) with sel=30, presses m once (collapse), prints "<sel>\n<n>".'
    set -l seed '#5f772b'
    set -l phase 0
    set -l expanded 1
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    set -l cachekeys
    set -l cacheblobs
    set -l flashfield ''
    __tcz_thp_reload
    set -l n (count $toks)
    set -l sel 30
    eval $CASEM9WRAP
    printf '%s\n' $sel $n
end
set -g CASEMRES9 (__t9_case_m)
t "case m collapse from a hidden row: sel lands in range, not stale" 13 $CASEMRES9[1]
t "case m collapse from a hidden row: n reflects the collapsed catalog" 14 $CASEMRES9[2]

# ---------------------------------------------------------------------
# review finding 3: `islive` ignored a previewed-but-uncommitted seed change,
# and never credited previewing the off row when the persisted theme is
# genuinely off. Driven through the REAL draw block via $DRAWTEXT9 (same
# technique as the frame proof above, since `islive` is a `set -l` local to
# that same loop and `eval` — not `source` — lets it survive for inspection)
# rather than re-implementing the liveness logic to test against.
# ---------------------------------------------------------------------
function __t9_islive --argument-names focus sel2 n sel previewed anch_scheme seed anch_seed --description 'eval the REAL draw block against a given picker state; returns the $islive it produced.'
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l IW 50
    set -l WIN 11
    set -l host somehost
    set -l chiptitle ''
    set -l note 'a note'
    set -l seedfg '#f5f5f5'
    set -l phase 0
    set -l legacy '#444444'
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    set -l anchpal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
    test "$anch_scheme" = off; and set anchpal ''
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    for i in (seq $n)
        set -a toks "scheme$i"
        set -a pals '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
        set -a fgs '#f5f5f5'
        set -a tabsfgs '#f5f5f5'
        set -a recipes 'mono|bar|derived'
    end
    set -l flashfield ''
    eval $DRAWTEXT9
    echo $islive
end
t "islive: unchanged seed, no preview -> live"                     1 (__t9_islive list  0 14 0 0 mono '#111111' '#111111')
t "islive: previewed seed change, no apply yet -> NOT live"        0 (__t9_islive list  0 14 0 0 mono '#111111' '#222222')
t "islive: previewing a listed scheme -> not live"                 0 (__t9_islive list  0 14 0 1 mono '#111111' '#111111')
t "islive: previewing the current row itself -> live"              1 (__t9_islive state 0 14 0 2 mono '#111111' '#111111')
t "islive: previewing off while persisted is off -> live"          1 (__t9_islive state 1 14 0 1 off  '#111111' '#111111')
t "islive: previewing off while persisted is a scheme -> not live" 0 (__t9_islive state 1 14 0 1 mono '#111111' '#111111')

# ---------------------------------------------------------------------
# review finding 4: the state row must name the CATALOG ENTRY whose recipe
# matches the anchor (e.g. "mono soft"), not the bare relationship (e.g.
# "mono") — several catalog rows share a relationship, so the row whose whole
# job is "what do I have" would otherwise be ambiguous about place/mode.
# Falls back to the bare relationship when no catalog row matches (e.g. a
# CLI-only --place low|high config, which has no catalog row at all).
# ---------------------------------------------------------------------
function __t9_anchname --argument-names anch_scheme anch_place anch_mode --description 'eval the REAL draw block with a caller-controlled catalog (toks/recipes) and return the $anchname it resolved for the state row.'
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l IW 50
    set -l WIN 11
    set -l host somehost
    set -l chiptitle ''
    set -l note 'a note'
    set -l seed '#5f772b'
    set -l seedfg '#f5f5f5'
    set -l phase 0
    set -l legacy '#444444'
    set -l anch_phase 0
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    set -l anchpal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
    test "$anch_scheme" = off; and set anchpal ''
    set -l focus state
    set -l sel2 0
    set -l sel 0
    set -l previewed 0
    set -l toks catalogA catalogB
    set -l pals '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6' '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
    set -l fgs '#f5f5f5' '#f5f5f5'
    set -l tabsfgs '#f5f5f5' '#f5f5f5'
    set -l recipes 'mono|bar|derived' 'sage|high|derived'
    set -l n 2
    set -l flashfield ''
    eval $DRAWTEXT9
    echo $anchname
end
t "current row names the catalog entry, not the bare relationship" catalogA (__t9_anchname mono bar derived)
t "current row names a different catalog entry sharing no relationship" catalogB (__t9_anchname sage high derived)
t "current row falls back to the relationship when no catalog row matches" sage (__t9_anchname sage low derived)

# --- Task 6: the More Schemes group header --------------------------------------
# A row INSIDE the list, not a frame element: the user rejected the section-border
# form because it "would make it look far too separate" and broke the single-list
# feel. So no border connectors, and it must measure like any other list row.
t "grouphdr exists" 0 (functions -q __tcz_thp_grouphdr; echo $status)
set -g GH6 (__tcz_thp_grouphdr 50 'More Schemes')
set -g GH6V (string replace -ra '\x1b\[[0-9;]*m' '' -- "$GH6")
t "grouphdr is exactly 50 visible cols" 50 (string length --visible -- "$GH6V")
t "grouphdr carries the label" yes (string match -q '*More Schemes*' -- "$GH6V"; and echo yes; or echo no)
t "grouphdr leaves col 1 blank (never selectable)" ' ' (string sub -s 1 -l 1 -- "$GH6V")
t "grouphdr has no border connectors" 0 (string match -ra '[├┤]' -- "$GH6V" | count)
t "grouphdr keeps a blank column before the right edge" ' ' (string sub -s 50 -l 1 -- "$GH6V")
t "grouphdr is one line" 1 (count $GH6)

rm -rf $shimdir
if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
