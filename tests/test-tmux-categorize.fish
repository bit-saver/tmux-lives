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
    # tick-call-batching task 4: the per-pass memo (session @options AND, as of
    # this task, the pane walk) is keyed by SESSION NAME, and this suite reuses
    # short names ("sA", "0", "alpha", ...) across many independently-built real
    # -L $sock fixtures. Without this, a name fetched against an EARLIER fixture
    # could satisfy a later __tcz_tmux_panes/__tcz_tmux_sess_* lookup against a
    # DIFFERENT real session that merely happens to share the name, silently
    # serving stale data instead of querying the fixture actually under test.
    # cleanup already means "the tmux state below this point may be completely
    # different" -- flushing here makes that true for the in-process read memo
    # too, mirroring __tcz_main's own flush-per-pass discipline.
    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
    # Same reasoning as cleanup's own flush, immediately above -- see its comment.
    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
# __tcz_tmux_load / __tcz_tmux_flush / __tcz_tmux_global / __tcz_tmux_unquote
# (tick-call-batching task 2): __tcz_ps_load's sibling — one `tmux show -g`
# snapshot per pass, memoized into per-key globals, instead of a separate
# `show -gv @tmux_lives_<key>` call for every read.
# ---------------------------------------------------------------------
fresh_server
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g @tmux_lives_tabs_color '#1f6feb' 2>/dev/null
command tmux set -g @tmux_lives_heal_interval 42 2>/dev/null
t "tmux_global reads a hex-color key (tmux quotes it on the leading #)" "#1f6feb" (__tcz_tmux_global tabs_color)
t "tmux_global reads a bare-integer key" "42" (__tcz_tmux_global heal_interval)
t "tmux_global returns empty for a key that was never set" "" (__tcz_tmux_global heal_at)

# Memoization: a server-side change made AFTER the load must stay invisible
# until the next explicit flush — this is the whole point of batching (one
# read serves every accessor call for the rest of the pass), so proving the
# memo does NOT self-refresh is as important as proving it loads correctly.
command tmux set -g @tmux_lives_tabs_color '#abcdef' 2>/dev/null
t "tmux_global is memoized: a change after load stays invisible until flushed" "#1f6feb" (__tcz_tmux_global tabs_color)
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "tmux_global sees the change once flushed" "#abcdef" (__tcz_tmux_global tabs_color)

# The actual point of task 2 (extended by task 3): three accessor calls for
# three different GLOBAL keys, after one flush, must cost exactly TWO `tmux`
# invocations, not six — one `show -g` for every global key, PLUS one
# `list-sessions -F` (tick-call-batching task 3's session-scoped half, loaded
# by the same __tcz_tmux_load and therefore paid on this same first touch even
# though nothing here reads a session-scoped field). Was ONE invocation before
# task 3 added the session half.
set -g tgshim /tmp/tcz-tgshim-$fish_pid; set -g tglog /tmp/tcz-tglog-$fish_pid
rm -rf $tgshim $tglog; mkdir -p $tgshim $tglog
printf '#!/bin/bash\necho x >> %s/calls\nexec /usr/bin/tmux -L %s "$@"\n' $tglog $sock > $tgshim/tmux
chmod +x $tgshim/tmux
set -g tg_path_save $PATH
set -gx PATH $tgshim $PATH
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_tmux_global tabs_color >/dev/null
__tcz_tmux_global heal_interval >/dev/null
__tcz_tmux_global heal_at >/dev/null
set -l tg_calls 0
test -f $tglog/calls; and set tg_calls (string trim -- (wc -l < $tglog/calls))
t "tmux_global: three accessor calls after one flush cost exactly two tmux invocations (show -g + list-sessions)" 2 $tg_calls
set -gx PATH $tg_path_save
rm -rf $tgshim $tglog
# This test's own accessor calls just loaded the memo from THIS block's real
# $sock server state at whatever point in the suite this runs -- flush so that
# snapshot cannot leak into any later test that forgets to flush before its
# own first memo-backed read (this bit once: every downstream __tcz_snapshot
# assertion failed en masse until this flush was added here).
functions -q __tcz_tmux_flush; and __tcz_tmux_flush

# __tcz_tmux_unquote round-tripped against REAL tmux escaping, not hand-built
# escape sequences (which this codebase has gotten subtly wrong before) —
# tmux itself produces the `show -g` quoting, so proving __tcz_tmux_global
# agrees with a direct `show -gv` on the SAME key for a variety of values is
# a stronger, less error-prone check than asserting a specific quoted string.
# Includes values beyond what any @tmux_lives_* key actually uses today
# (semicolon, space, an embedded+doubled backslash) as bonus coverage; the two
# genuinely out-of-scope shapes (a $, and a value tmux single-quote-wraps) are
# pinned separately below as a documented, known gap rather than asserted here.
fresh_server
for v in '#1f6feb' plain42 '' 'a;b' 'has space' 'back\slash'
    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
    command tmux set -g @tmux_lives_rt_test "$v" 2>/dev/null
    set -l want (command tmux show -gv @tmux_lives_rt_test 2>/dev/null)
    functions -q __tcz_tmux_flush; and __tcz_tmux_flush
    set -l got (__tcz_tmux_global rt_test)
    t "tmux_unquote agrees with a direct show -gv for value: '$v'" "$want" "$got"
end

# Known, documented limitation, pinned rather than silent: neither is reachable
# for tabs_color/heal_interval/heal_at (always a bare integer or a #-led hex —
# proven above), so __tcz_tmux_unquote's docstring says it does not attempt
# either. A future change here is judged against what actually happens today,
# not a guess at it.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g @tmux_lives_rt_test 'a$b' 2>/dev/null
t "tmux_unquote known gap: a \$ inside double quotes is not unescaped" 'a\$b' (__tcz_tmux_global rt_test)
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g @tmux_lives_rt_test 'quote"inside' 2>/dev/null
t "tmux_unquote known gap: tmux's single-quote wrap is not recognised" "'quote\"inside'" (__tcz_tmux_global rt_test)

command tmux set -g -u @tmux_lives_rt_test 2>/dev/null
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux -L $sock kill-server 2>/dev/null

# glob, not regex (the trap __tcz_ps_flush's own comment documents): a plain
# per-key sentinel must be gone after flush. This is the exact class of bug a
# `string match -r '^__tcz_tmux_'` mutation reintroduces — verified by hand:
# `string match -r` on a bare prefix pattern returns the MATCHED SUBSTRING
# (the literal "__tcz_tmux_" three times over, for three real names), so
# `set -e` on that erases a variable that does not exist while every real
# entry -- including this sentinel -- silently survives.
set -g __tcz_tmux_g_probe_999999 SENTINEL
set -g __tcz_tmux_loaded 1
__tcz_tmux_flush
t "tmux_flush clears a real per-key entry" "" "$__tcz_tmux_g_probe_999999"
t "tmux_flush clears the loaded sentinel too" 0 (set -q __tcz_tmux_loaded; and echo 1; or echo 0)

# pure: __tcz_tmux_unquote's own contract, independent of any tmux process
t "tmux_unquote: bare token passes through unchanged" "abc123" (__tcz_tmux_unquote "abc123")
t "tmux_unquote: two single quotes is the empty-value marker" "" (__tcz_tmux_unquote "''")

# ---------------------------------------------------------------------
# tabs-role resolution (v3 Phase 2): __tcz_tab_color resolves the live
# @tmux_lives_tabs_color option (seeded by the themed fragment, tabs-role
# sample when themed / '' under the legacy look) over the baked-in
# fallback; __tcz_recolor/__tcz_on_attach route through it.
#
# __tcz_tab_color now reads through __tcz_tmux_load's per-PASS memo (tick-
# call-batching task 2: nine `show -gv @tmux_lives_…` calls collapse to one
# `tmux show -g`) -- so unlike a live `show -gv`, a second call inside this
# same fish process will NOT see a state change unless the memo is flushed
# first. __tcz_main flushes on every entry (production is always one pass per
# process), but these three assertions call __tcz_tab_color directly, so each
# state change below gets its own explicit flush -- same idiom this file
# already uses for __tcz_ps_flush around the ps snapshot.
# ---------------------------------------------------------------------
fresh_server
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g -u @tmux_lives_tabs_color 2>/dev/null
t "tab_color falls back when option unset" "#999999" (__tcz_tab_color "#999999")
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g @tmux_lives_tabs_color '#6e6e22' 2>/dev/null
t "tab_color prefers the live tabs role" "#6e6e22" (__tcz_tab_color "#999999")
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
command tmux set -g @tmux_lives_tabs_color '' 2>/dev/null
t "tab_color: empty option falls back" "#999999" (__tcz_tab_color "#999999")
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
set -g pn1 (__tcz_project_name /home/bitsaver/projects/neurotto)
set -g pn2 (__tcz_project_name /home/bitsaver/workspace/tmux-lives/)
set -g pn3 (__tcz_project_name "$HOME")
set -g pn4 (__tcz_project_name /tmp)
set -g pn5 (__tcz_project_name /)
set -g pn6 (__tcz_project_name "")
set -g pn7 (__tcz_project_name "/home/bitsaver/My Project")
t "project: basename of a project dir"        "neurotto"   "$pn1"
t "project: trailing slash ignored"           "tmux-lives" "$pn2"
t "project: \$HOME is not a project"          ""           "$pn3"
t "project: /tmp is not a project"            ""           "$pn4"
t "project: / is not a project"               ""           "$pn5"
t "project: empty path is not a project"      ""           "$pn6"
t "project: spaces survive (display layer)"   "My Project" "$pn7"
set -g dn1 (__tcz_display_name claude  neurotto "Fix the picker lag")
set -g dn2 (__tcz_display_name claude  neurotto "")
set -g dn3 (__tcz_display_name claude  ""        "Fix the picker lag")
set -g dn4 (__tcz_display_name running neuro     node)
set -g dn5 (__tcz_display_name general neuro     "")
set -g dn6 (__tcz_display_name general ""        "")
t "display: claude is project then task"      "neurotto · Fix the picker lag" "$dn1"
t "display: claude with no task is project"   "neurotto"                      "$dn2"
t "display: no project falls back to task"    "Fix the picker lag"            "$dn3"
t "display: running IGNORES the process name" "neuro"                         "$dn4"
t "display: general is the project"           "neuro"                         "$dn5"
t "display: nothing to show -> empty"         ""                              "$dn6"

# ---------------------------------------------------------------------
# __tcz_dup_ordinal: pure duplicate-ordinal suffix (spec 2026-08-19). argv
# rows are "claimed\tname\tdisplay" (display LAST/greedy, so an embedded
# literal tab in a claim survives -- same convention __tcz_snapshot itself
# uses for field 5, see the "literal tab" test further down).
# ---------------------------------------------------------------------
t "dup: the function exists" 1 (functions -q __tcz_dup_ordinal; and echo 1; or echo 0)
t "dup: a single session gets no ordinal" "tmux-lives" \
    (__tcz_dup_ordinal (printf '0\talpha\ttmux-lives'))
set -g do2 (__tcz_dup_ordinal (printf '0\tzulu\ttmux-lives') (printf '0\talpha\ttmux-lives'))
t "dup: two duplicates, row 1 (zulu, sorted 2nd) -> [2]" "tmux-lives [2]" "$do2[1]"
t "dup: two duplicates, row 2 (alpha, sorted 1st) -> [1]" "tmux-lives [1]" "$do2[2]"
set -g do3 (__tcz_dup_ordinal (printf '0\tcarol\tX') (printf '0\talice\tX') (printf '0\tbob\tX'))
t "dup: triple duplicate, row 1 (carol, sorted 3rd) -> [3]" "X [3]" "$do3[1]"
t "dup: triple duplicate, row 2 (alice, sorted 1st) -> [1]" "X [1]" "$do3[2]"
t "dup: triple duplicate, row 3 (bob, sorted 2nd) -> [2]"   "X [2]" "$do3[3]"
set -g do5 (__tcz_dup_ordinal (printf '0\ts1\tneurotto · Fix the lag') (printf '0\ts2\tneurotto'))
t "dup: a claude task display isn't grouped with a bare-project sibling (row 1)" "neurotto · Fix the lag" "$do5[1]"
t "dup: a claude task display isn't grouped with a bare-project sibling (row 2)" "neurotto" "$do5[2]"
set -g do4 (__tcz_dup_ordinal (printf '1\tclaimed\tSame') (printf '0\tother\tSame'))
t "dup: a claimed row is never renumbered" "Same" "$do4[1]"
t "dup: a claimed row is excluded from a sibling's own group count too" "Same" "$do4[2]"
set -e do2 do3 do4 do5

# ---------------------------------------------------------------------
# __tcz_display_current: pure write-guard tolerance for a bracketed
# duplicate ordinal (spec 2026-08-19) -- <computed> <stored> <narrowed>.
# The tick (__tcz_snapshot, unnarrowed) owns ordinal assignment; a narrowed
# fish_postexec pass composes a bare display and must not treat that as a
# change, or every command would strip the tick's suffix right back off --
# the exact per-tick set-option churn on an option the status bar reads
# that caused the ShellFish cursor-flicker bug elsewhere in this file.
# ---------------------------------------------------------------------
t "dispcur: the function exists" 1 (functions -q __tcz_display_current; and echo 1; or echo 0)
t "dispcur: exact match, narrowed -> current" 0 (__tcz_display_current "X" "X" 1; echo $status)
t "dispcur: exact match, unnarrowed -> current" 0 (__tcz_display_current "X" "X" ""; echo $status)
# THE genuinely new behavior -- these are RED against a stub/exact-match-only
# comparison, since "X" != "X [1]".
t "dispcur: narrowed pass tolerates a single-digit ordinal" 0 \
    (__tcz_display_current "X" "X [1]" 1; echo $status)
t "dispcur: narrowed pass tolerates a multi-digit ordinal" 0 \
    (__tcz_display_current "X" "X [12]" 1; echo $status)
# Guards / non-regression pins below -- NOT expected to be red pre-fix (a
# naive exact-match comparison already rewrites in every one of these
# cases too); kept and mutation-tested so a future over-broad tolerance
# regex can't silently swallow a real change.
t "dispcur: unnarrowed pass does NOT tolerate a stale ordinal (must heal within one tick)" 1 \
    (__tcz_display_current "X" "X [1]" ""; echo $status)
t "dispcur: narrowed pass does not swallow a genuinely different base (over-correction guard)" 1 \
    (__tcz_display_current "Y" "X [1]" 1; echo $status)
t "dispcur: narrowed pass rejects trailing garbage after the bracket" 1 \
    (__tcz_display_current "X" "X [1] extra" 1; echo $status)
t "dispcur: narrowed pass rejects a non-digit inside the brackets" 1 \
    (__tcz_display_current "X" "X [abc]" 1; echo $status)
t "dispcur: narrowed pass requires the space before the bracket" 1 \
    (__tcz_display_current "X" "X[1]" 1; echo $status)

# ---------------------------------------------------------------------
# __tcz_unquote: undo a typed `claude --name "..."` surrounding quote pair
# before it reaches the display -- the preexec-captured raw text is the
# command line AS TYPED (quotes and all), while the tick's own extraction
# (/proc argv) never carries them, so without this the instant claim
# display and the tick's display visibly disagree for one tick.
# ---------------------------------------------------------------------
t "unquote: double-quoted pair stripped"    "Fix the picker lag" (__tcz_unquote '"Fix the picker lag"')
t "unquote: single-quoted pair stripped"    "Fix the picker lag" (__tcz_unquote "'Fix the picker lag'")
t "unquote: no quotes -> unchanged"         "Fix the picker lag" (__tcz_unquote "Fix the picker lag")
t "unquote: unmatched leading quote -> unchanged" '"Fix the picker lag' (__tcz_unquote '"Fix the picker lag')
t "unquote: mismatched quote types -> unchanged"  '"Fix the picker lag'"'" (__tcz_unquote '"Fix the picker lag'"'")
t "unquote: interior quote (not surrounding) -> unchanged" 'Fix "the" picker' (__tcz_unquote 'Fix "the" picker')
t "unquote: empty quoted pair -> empty"     ""                    (__tcz_unquote '""')
t "unquote: empty input -> empty"           ""                    (__tcz_unquote "")
t "unquote: single quote char alone -> unchanged" '"' (__tcz_unquote '"')
# Matching first/last chars that are NOT quote characters must never strip —
# this is the specific check that distinguishes "surrounding quotes" from
# "any matching bookend char", and nothing above exercises it.
t "unquote: matching non-quote bookend chars -> unchanged" 'aFix the picker laga' (__tcz_unquote 'aFix the picker laga')

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
# c1/c_title pin -c $HOME (a generic, excluded dir) so their display isolates
# the --name/title extraction under test from project-name composition, which
# has its own dedicated coverage below (snapshot: running session displays
# the PROJECT) and in the __tcz_project_name/__tcz_display_name unit tests.
tmux new-session -d -s c1 -c $HOME "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s r1 -c /tmp 'sleep 1000'
tmux new-session -d -s g1 -c $HOME
sleep 0.5     # let pane_current_command settle
t "snap: categories"  "c1	claude,g1	general,r1	running" \
    (__tcz_snapshot | cut -f1,2 | sort | string join ',')
t "snap: claude display from --name" "TMUX Setup 2" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f5)
# Re-scoped 2026-08-18 (fix wave): a project/task-less display is NOT the
# empty string these used to pin — __tcz_display_name returns nothing, but
# __tcz_snapshot now falls back to the tmux session name so field 5 is never
# blank (a blank field desyncs __tcz_menu_args' display-menu argv and blanks
# a picker row). The user-visible outcome is the row shows the session name.
t "snap: running display falls back to the session name for a generic (excluded) cwd" "r1" \
    (__tcz_snapshot | string match -e 'r1	*' | cut -f5)
t "snap: general display falls back to the session name for a generic (excluded) cwd" "g1" \
    (__tcz_snapshot | string match -e 'g1	*' | cut -f5)
t "snap: detached flag"              "0" \
    (__tcz_snapshot | string match -e 'c1	*' | cut -f3)

# --- __tcz_popup_list_lines (integration, item 1 regression coverage): a
# no-project session must render a NON-BLANK row, not just a padded border
# with nothing readable in it. Reuses the still-live r1/g1 fixture above.
set -l povl (__tcz_overview | __tcz_popup_list_lines 30 0 '' | string join "\n")
t "popup: no-project running row is non-blank (shows the session name)" yes \
    (string match -q '*r1*' -- "$povl"; and echo yes; or echo no)
t "popup: no-project general row is non-blank (shows the session name)" yes \
    (string match -q '*g1*' -- "$povl"; and echo yes; or echo no)

# --- __tcz_menu_args / display-menu (integration, item 1 regression coverage):
# a no-project session's item label must never be empty. An empty menu-item
# NAME is tmux's own SEPARATOR shape (name only; key/command are meant to be
# omitted for it) — so tmux silently consumes the NEXT triple's key/command as
# belonging to that empty-named separator, desyncing every remaining item and
# erroring on the trailing incomplete group. Reproduced live pre-fix: rc=1,
# "not enough arguments" — the WHOLE menu refuses to open for one detached
# no-project session. This needs a REAL attached client: tmux only walks the
# item list after resolving a target client, so a clientless call fails
# earlier with "no current client" regardless of the args, which would mask
# this bug entirely. Dedicated minimal fixture (one no-project session) so
# the item's array index is unambiguous: header (1-3) + item (4-6). Started
# with -f /dev/null and a plain `sleep`, NOT the bare login shell: the shell
# defaults to the user's own REAL (fisher-installed) fish config, whose live
# tmux-lives hooks fire the instant a real client attaches and genuinely
# destabilize this throwaway socket — reproduced (server gone within ~1s of
# attach) and confirmed fixed by both changes together.
cleanup
tmux -f /dev/null new-session -d -s g2 -c $HOME 'sleep 60'
sleep 0.5
set -l menu_args2
__tcz_overview | __tcz_menu_args | while read -l a
    set -a menu_args2 "$a"
end
t "menu: no-project session label is non-empty" "yes" \
    (test -n "$menu_args2[4]"; and echo yes; or echo no)
env TERM=xterm-256color script -qec "tmux attach" /dev/null >/dev/null 2>&1 &
set -l menu_n 0
while test $menu_n -lt 25; and test (tmux list-clients 2>/dev/null | count) -eq 0
    sleep 0.2
    set menu_n (math $menu_n + 1)
end
set -l menu_client (tmux list-clients -F '#{client_name}' 2>/dev/null | head -1)
set -l menu_out (tmux display-menu -c "$menu_client" -- $menu_args2 2>&1)
set -l menu_rc $status
t "menu: real display-menu opens for a no-project session (rc 0)" "0" "$menu_rc"
t "menu: no 'not enough arguments' desync" "" \
    (string match -e 'not enough arguments' -- "$menu_out")
set -e menu_args2 menu_client menu_out menu_rc menu_n
cleanup

# display fallbacks: no --name -> gated title; unusable title with a project dir -> project name
cleanup
mkdir -p /tmp/tcz-myproj-$fish_pid
tmux new-session -d -s c_title -c $HOME "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_title: -T "✳ My Work Project"
tmux new-session -d -s c_cwd -c /tmp/tcz-myproj-$fish_pid "$shimdir/claude --enable-auto-mode"
tmux select-pane -t c_cwd: -T ""
sleep 0.5
t "snap: claude display from title" "My Work Project" \
    (__tcz_snapshot | string match -e 'c_title	*' | cut -f5)
t "snap: claude display from cwd"   "tcz-myproj-$fish_pid" \
    (__tcz_snapshot | string match -e 'c_cwd	*' | cut -f5)
rm -rf /tmp/tcz-myproj-$fish_pid
cleanup
t "snap: no server -> empty" "" (__tcz_snapshot | string join ',')

# tick-call-batching task 4 follow-up: the two assertions just above exercise
# __tcz_snapshot's OWN local title aggregation ($ctitle, used for the DISPLAY
# field) -- a separate mechanism from the NEW shared pane-walk memo
# (__tcz_tmux_pane_title, populated by __tcz_snapshot's prefill and consumed by
# __tcz_set_claude_opt via __tcz_tmux_panes). Nothing above touches @tmux_lives_claude,
# so nothing above can catch a broken title stash on the memo side -- confirmed
# unable to: mutating `set -ga __tcz_tmux_pane_title "$f[5]"` to always store empty
# left all 1161 pre-follow-up assertions green. This one goes through the real
# __tcz_categorize -> __tcz_snapshot (prefill) -> __tcz_set_claude_opt path with a
# claude pane that has NO --name (so the readable name can only come from the
# TITLE, via the memo) and checks the option __tcz_set_claude_opt actually writes.
cleanup
tmux new-session -d -s titleclaude -c $HOME "$shimdir/claude --enable-auto-mode"
tmux select-pane -t titleclaude: -T "✳ Title Only Task"
sleep 0.5
__tcz_categorize
t "categorize: a claude name sourced from the pane TITLE (no --name) reaches @tmux_lives_claude via the snapshot prefill" \
    "Title Only Task" (tmux show-option -qv -t titleclaude @tmux_lives_claude 2>/dev/null)
cleanup

# ---------------------------------------------------------------------
# Boring-command deprioritization: a session whose only non-shell pane
# command is a pager/tailer (tail/less/watch/cat/more/bat) must NOT count
# as "running" — it falls through to general (dir-named). A session
# running a real program must still be categorized "running" (guard
# must not over-reach).
# ---------------------------------------------------------------------
cleanup
# Separate project dirs for b1/real1 (not the original shared one): sharing a
# dir made them a duplicate-display PAIR once the 2026-08-19 ordinal feature
# landed, which would have suffixed b1's display and broken the "= dir
# basename" assertion below for a reason unrelated to what it tests. Keeping
# them apart preserves this fixture's original, narrower intent.
mkdir -p $HOME/tcz-boring-$fish_pid $HOME/tcz-real-$fish_pid
tmux new-session -d -s b1 -c $HOME/tcz-boring-$fish_pid 'tail -f /dev/null'
tmux new-session -d -s real1 -c $HOME/tcz-real-$fish_pid "node -e 'setInterval(function(){}, 1000)'"
sleep 0.5
t "snap: boring command -> general (not running)" "general" \
    (__tcz_snapshot | string match -e 'b1	*' | cut -f2)
t "snap: boring display = dir basename (not tail)" "tcz-boring-$fish_pid" \
    (__tcz_snapshot | string match -e 'b1	*' | cut -f5)
t "snap: real program -> still running (guard doesn't over-reach)" "running" \
    (__tcz_snapshot | string match -e 'real1	*' | cut -f2)
rm -rf $HOME/tcz-boring-$fish_pid $HOME/tcz-real-$fish_pid
cleanup

# ---------------------------------------------------------------------
# __tcz_snapshot displays the PROJECT (dir basename), never the process
# name, for a running session — the naming redesign's first wiring.
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-proj-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-proj-$fish_pid 'sleep 500'
sleep 0.5
set -g snap_disp (__tcz_snapshot | string match -e '0	*' | cut -f5)
set -g snap_arity (__tcz_snapshot | head -1 | awk -F'\t' '{print NF}')
t "snapshot: running session displays the PROJECT, not the command" "tcz-proj-$fish_pid" "$snap_disp"
t "snapshot: row still has exactly 5 fields"                        5 "$snap_arity"
rm -rf $HOME/tcz-proj-$fish_pid
cleanup

# End-to-end "project · task" composition through __tcz_snapshot itself — the
# spec's headline example (a claude session gets "<project> · <task>"). Task 2
# unit-tests __tcz_display_name's composition directly; this is the only place
# that proves it actually survives field 5, the -m 4 greedy split, and every
# consumer, for a REAL claude session with both a project dir and a --name.
cleanup
mkdir -p $HOME/tcz-ptask-$fish_pid
tmux new-session -d -s pt -c $HOME/tcz-ptask-$fish_pid "$shimdir/claude --enable-auto-mode --name Fix the picker lag"
sleep 0.5
t "snapshot: claude project · task composition, end to end" "tcz-ptask-$fish_pid · Fix the picker lag" \
    (__tcz_snapshot | string match -e 'pt	*' | cut -f5)
rm -rf $HOME/tcz-ptask-$fish_pid
cleanup

# ---------------------------------------------------------------------
# __tcz_snapshot: duplicate displays get a bracketed ordinal (spec
# 2026-08-19). Two sessions started in the same project compose the SAME
# display -- the picker and tab title must still tell them apart.
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-dupdisp-$fish_pid
tmux new-session -d -s zulu -c $HOME/tcz-dupdisp-$fish_pid 'sleep 500'
tmux new-session -d -s alpha -c $HOME/tcz-dupdisp-$fish_pid 'sleep 500'
sleep 0.5
t "snap: duplicate, sorted-first session name -> [1]" "tcz-dupdisp-$fish_pid [1]" \
    (__tcz_snapshot | string match -e 'alpha	*' | cut -f5)
t "snap: duplicate, sorted-second session name -> [2]" "tcz-dupdisp-$fish_pid [2]" \
    (__tcz_snapshot | string match -e 'zulu	*' | cut -f5)
tmux kill-session -t "=zulu"
sleep 0.3
t "snap: dropping back to one member removes the ordinal" "tcz-dupdisp-$fish_pid" \
    (__tcz_snapshot | string match -e 'alpha	*' | cut -f5)
rm -rf $HOME/tcz-dupdisp-$fish_pid
cleanup

mkdir -p $HOME/tcz-triple-$fish_pid
tmux new-session -d -s cc -c $HOME/tcz-triple-$fish_pid 'sleep 500'
tmux new-session -d -s aa -c $HOME/tcz-triple-$fish_pid 'sleep 500'
tmux new-session -d -s bb -c $HOME/tcz-triple-$fish_pid 'sleep 500'
sleep 0.5
t "snap: triple duplicate, ordinal by sorted name (aa -> [1])" "tcz-triple-$fish_pid [1]" \
    (__tcz_snapshot | string match -e 'aa	*' | cut -f5)
t "snap: triple duplicate, ordinal by sorted name (bb -> [2])" "tcz-triple-$fish_pid [2]" \
    (__tcz_snapshot | string match -e 'bb	*' | cut -f5)
t "snap: triple duplicate, ordinal by sorted name (cc -> [3])" "tcz-triple-$fish_pid [3]" \
    (__tcz_snapshot | string match -e 'cc	*' | cut -f5)
rm -rf $HOME/tcz-triple-$fish_pid
cleanup

# A claude session's task-qualified display cannot collide with a bare
# sibling's project-only display -- the whole point of the task half
# (equality is on the DISPLAY, not the project — spec's own example).
mkdir -p $HOME/tcz-nodupe-$fish_pid
tmux new-session -d -s ndc -c $HOME/tcz-nodupe-$fish_pid "$shimdir/claude --enable-auto-mode --name Some Task"
tmux new-session -d -s ndb -c $HOME/tcz-nodupe-$fish_pid 'sleep 500'
sleep 0.5
t "snap: a claude task display is never suffixed against a bare-project sibling" "tcz-nodupe-$fish_pid · Some Task" \
    (__tcz_snapshot | string match -e 'ndc	*' | cut -f5)
t "snap: the bare-project sibling is never suffixed either" "tcz-nodupe-$fish_pid" \
    (__tcz_snapshot | string match -e 'ndb	*' | cut -f5)
rm -rf $HOME/tcz-nodupe-$fish_pid
cleanup

# A @tmux_lives_name claim is a deliberate name and is never renumbered, even
# when it happens to be byte-equal to a sibling's composed project display --
# and it is excluded from the sibling's own group count too (the sibling is
# now the SOLE unclaimed session with that display, so it stays bare as well).
mkdir -p $HOME/tcz-claimdup-$fish_pid
tmux new-session -d -s claimant2 -c $HOME/tcz-claimdup-$fish_pid 'sleep 500'
tmux set-option -t claimant2 @tmux_lives_name "tcz-claimdup-$fish_pid"
tmux new-session -d -s plainsib -c $HOME/tcz-claimdup-$fish_pid 'sleep 500'
sleep 0.5
t "snap: a claimed session keeps its claim verbatim, no ordinal" "tcz-claimdup-$fish_pid" \
    (__tcz_snapshot | string match -e 'claimant2	*' | cut -f5)
t "snap: the claim is excluded from the sibling's own group count" "tcz-claimdup-$fish_pid" \
    (__tcz_snapshot | string match -e 'plainsib	*' | cut -f5)
rm -rf $HOME/tcz-claimdup-$fish_pid
cleanup

# The suffixing pass only runs on an UNNARROWED call: a narrowed pass sees
# just its own session and cannot detect a sibling, so it must compose a
# BARE display even when a real duplicate exists (the whole reason
# __tcz_categorize's write needs the [N]-tolerant comparison at all).
mkdir -p $HOME/tcz-narrowdup-$fish_pid
tmux new-session -d -s dupA -c $HOME/tcz-narrowdup-$fish_pid 'sleep 500'
tmux new-session -d -s dupB -c $HOME/tcz-narrowdup-$fish_pid 'sleep 500'
sleep 0.5
t "snap: unnarrowed pass suffixes a real duplicate" "yes" \
    (string match -qr ' \[[0-9]+\]$' -- (__tcz_snapshot | string match -e 'dupA	*' | cut -f5); and echo yes; or echo no)
t "snap: narrowed pass over the SAME duplicate leaves the display bare" "tcz-narrowdup-$fish_pid" \
    (__tcz_snapshot dupA | cut -f5)
rm -rf $HOME/tcz-narrowdup-$fish_pid
cleanup

# ---------------------------------------------------------------------
# __tcz_categorize (integration)
# ---------------------------------------------------------------------
cleanup
# session "0" now needs a REAL project dir, not -c $HOME: Task 4 makes the tmux
# NAME come from the project alone, never the --name/task, so a $HOME-pinned
# claude session no longer renames to its --name slug -- it falls to gen-N
# like everything else with no project (see the C5 controller correction).
# session "2" is explicitly pinned to $HOME (a generic, excluded dir) rather
# than left unpinned: unpinned, it inherits THIS test run's own cwd, which
# (invoked from the repo root, as documented) is a REAL project ("tmux-lives")
# under Task 4 and would rename itself right past the gen-N fallback this
# test exists to check -- silently, since the assertion below only checks
# that *some* gen-N session exists, not which one earned it.
mkdir -p $HOME/tcz-run-$fish_pid $HOME/tcz-claude-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claude-$fish_pid "$shimdir/claude --enable-auto-mode --name TMUX Setup 2"
tmux new-session -d -s 1 -c $HOME/tcz-run-$fish_pid 'sleep 1000'
tmux new-session -d -s 2 -c $HOME
tmux new-session -d -s handname 'sleep 1000'      # unowned non-numeric -> guard protects
sleep 0.5
__tcz_categorize
t "cat: claude renamed to its project (never the --name slug)" "yes" \
    (tmux has-session -t "=tcz-claude-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "cat: claude stamped" "tcz-claude-$fish_pid" (tmux show-option -qv -t "tcz-claude-$fish_pid" @tmux_auto_name)
t "cat: claude display still carries the task" "tcz-claude-$fish_pid · TMUX Setup 2" \
    (tmux show-option -qv -t "tcz-claude-$fish_pid" @tmux_lives_display)
t "cat: running renamed to project" "yes" (tmux has-session -t "=tcz-run-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "cat: numeric general (no project) renamed to gen-N" "yes" (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
t "cat: hand-named protected"    "yes" (tmux has-session -t =handname 2>/dev/null; and echo yes; or echo no)
t "cat: idempotent (no churn)"   "" (__tcz_categorize | string join ',')

# C1: a second pass over an already-correctly-named session must NOT drop its
# display. The no-op rename short-circuit (desired == cur) must skip only the
# rename+stamp, never the display sync -- else a session keeps its display for
# exactly one pass and loses it forever after (the defect the brief's own
# tests, run only once, cannot see).
__tcz_categorize
t "cat: display survives a second (no-op) pass" "tcz-claude-$fish_pid · TMUX Setup 2" \
    (tmux show-option -qv -t "tcz-claude-$fish_pid" @tmux_lives_display)
rm -rf $HOME/tcz-run-$fish_pid $HOME/tcz-claude-$fish_pid

# revert: owned claude-named session whose claude died -> numeric. Pinned to
# $HOME (not left unpinned) so it specifically exercises the no-project
# fallback rather than picking up the repo root as its own project.
tmux kill-session -t "=tcz-claude-$fish_pid"
tmux new-session -d -s stale-claude -c $HOME
tmux set-option -t stale-claude @tmux_auto_name stale-claude
__tcz_categorize
t "cat: owned idle reverts to gen-N" "gen-1" \
    (tmux list-sessions -F '#{session_name}' | string match -r '^gen-[0-9]+$' | sort -V | head -n1)
# The assertion above only proves SOME gen-N session exists (gen-1 was already
# taken by session "2"), not that stale-claude itself reverted -- tighten
# with a direct check that its own old name is gone.
t "cat: stale-claude specifically was renamed off its old name" "no" \
    (tmux has-session -t =stale-claude 2>/dev/null; and echo yes; or echo no)

# C4: a non-claude, non-shell process with no project must land on gen-N,
# never the literal token "session" -- __tcz_slugify's own fallback for an
# EMPTY input. The old switch-based code called __tcz_slugify on the
# (project-less) DISPLAY, which composes to "" here, and __tcz_slugify ""
# hands back "session" instead of leaving room for the gen-N fallback below
# it -- a session named "session" would never again be recognized as
# unnamed. This implementation never calls __tcz_slugify on an empty string:
# an empty project skips straight past it to __tcz_free_gen.
cleanup
tmux new-session -d -s 3 -c $HOME "node -e 'setInterval(function(){}, 1000)'"
sleep 0.5
__tcz_categorize
t "cat: no-project running lands on gen-N, never the literal 'session'" "yes" \
    (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
t "cat: no-project running is never named the literal 'session'" "no" \
    (tmux has-session -t =session 2>/dev/null; and echo yes; or echo no)

# collision: two OWNED (numeric) claude sessions sharing one project dir. The
# --name no longer feeds the tmux name at all (project does), so this now
# needs a shared project dir to produce a collision; the --name stays only to
# prove the DISPLAY half still distinguishes the two via the task.
cleanup
mkdir -p $HOME/tcz-collision-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-collision-$fish_pid "$shimdir/claude --name Same Name"
tmux new-session -d -s 1 -c $HOME/tcz-collision-$fish_pid "$shimdir/claude --name Same Name"
sleep 0.5
__tcz_categorize
t "cat: collision suffixed" "tcz-collision-$fish_pid,tcz-collision-$fish_pid-2" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
rm -rf $HOME/tcz-collision-$fish_pid
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
# -c pins to a real project dir (not $HOME): the assertion needs the session to
# actually RENAME (proving it wasn't wrongly skipped as claimed), and under
# Task 4 a $HOME-pinned session no longer renames to its --name slug at all.
cleanup
mkdir -p $HOME/tcz-numsess-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-numsess-$fish_pid "$shimdir/claude --name Numeric Claude"
tmux new-session -d -s claimant
tmux set-option -t claimant @tmux_lives_name "Claimed By App"
sleep 0.5
__tcz_categorize
t "cat: numeric session not stranded by another session's claim" "yes" \
    (tmux has-session -t "=tcz-numsess-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "cat: the claiming session keeps its own name" "yes" \
    (tmux has-session -t =claimant 2>/dev/null; and echo yes; or echo no)
rm -rf $HOME/tcz-numsess-$fish_pid

# --- @tmux_lives_display staleness + the neurotto-protecting claim guard -----------
# From the task brief, Step 1, essentially verbatim. The C1 second-pass-persistence
# assertion lives in the main "cat:" block above, not duplicated here.
cleanup
mkdir -p $HOME/tcz-cat-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-cat-$fish_pid 'sleep 500'
tmux new-session -d -s 1 'sleep 500'                      # started in the harness cwd
sleep 0.5
__tcz_categorize
t "categorize: session named for its project" "yes" \
    (tmux has-session -t "=tcz-cat-$fish_pid" 2>/dev/null; and echo yes; or echo no)
set -g cat_disp (tmux show-option -qv -t "tcz-cat-$fish_pid" @tmux_lives_display)
t "categorize: display option written" "tcz-cat-$fish_pid" "$cat_disp"

# STALENESS: a hand-rename must drop the display, or the picker keeps the old name.
tmux rename-session -t "=tcz-cat-$fish_pid" "My Project"
__tcz_categorize
set -g stale_disp (tmux show-option -qv -t "My Project" @tmux_lives_display)
t "categorize: hand-rename clears the stale display" "" "$stale_disp"
t "categorize: hand-rename still sticks" "yes" \
    (tmux has-session -t "=My Project" 2>/dev/null; and echo yes; or echo no)

# THE REGRESSION THAT WOULD BREAK NEUROTTO.
tmux new-session -d -s claimed 'sleep 500'
tmux set-option -t claimed @tmux_lives_name "Neurotto CLI"
__tcz_categorize
t "categorize: an app claim still suppresses renaming" "yes" \
    (tmux has-session -t "=claimed" 2>/dev/null; and echo yes; or echo no)
set -g claim_disp (tmux show-option -qv -t claimed @tmux_lives_display)
t "categorize: a claimed session carries no display" "" "$claim_disp"

# COLLISION: the project-derived name must still go through __tcz_unique. The
# spec promises `neurotto` / `neurotto-2`; nothing tested it.
cleanup
mkdir -p $HOME/tcz-dup-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-dup-$fish_pid 'sleep 500'
tmux new-session -d -s 1 -c $HOME/tcz-dup-$fish_pid 'sleep 500'
sleep 0.5
__tcz_categorize
t "categorize: two sessions in one project collide safely" "yes" \
    (tmux has-session -t "=tcz-dup-$fish_pid-2" 2>/dev/null; and echo yes; or echo no)
t "categorize: no duplicate session names" "yes" \
    (test (tmux list-sessions -F '#{session_name}' | count) -eq (tmux list-sessions -F '#{session_name}' | sort -u | count); and echo yes; or echo no)
rm -rf $HOME/tcz-dup-$fish_pid $HOME/tcz-cat-$fish_pid
cleanup

# --- I1: anti-churn -- a second pass over an UNCHANGED server must emit ZERO
# @tmux_lives_display set-option calls, not merely leave the end-state
# unchanged. This is the property that guards against reintroducing the
# per-tick set-option churn that caused the ShellFish cursor flicker (fixed at
# __tcz_set_claude_opt by this same dedup discipline). Spy on the emitted tmux
# commands rather than inferring from end state -- the idiom already used
# above for "switch: --take detaches the session's clients".
cleanup
mkdir -p $HOME/tcz-churn-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-churn-$fish_pid 'sleep 500'
sleep 0.5
__tcz_categorize   # first pass: establishes steady state (rename + display write)
function tmux; set -a __t_cmds "$argv"; command tmux -L $sock $argv; end
set -g __t_cmds
__tcz_categorize   # second pass over an otherwise-unchanged server
functions -e tmux
t "cat: steady-state second pass writes zero @tmux_lives_display options" "0" \
    (count (string match -r 'set-option.*@tmux_lives_display' -- $__t_cmds))
set -e __t_cmds
rm -rf $HOME/tcz-churn-$fish_pid
cleanup

# --- N1: THE churn assertion that matters (spec 2026-08-19) -- a narrowed
# fish_postexec-style pass over a session whose stored @tmux_lives_display is
# already "<computed> [N]" must emit ZERO set-option calls. Without the
# [N]-tolerant comparison in __tcz_categorize, this fires on EVERY command:
# postexec writes the bare display, the tick writes it back suffixed, the
# next command writes the bare display again -- the exact per-tick
# set-option churn on an option the status bar reads that caused the
# ShellFish cursor-flicker bug. Spy on emitted tmux commands, not end state:
# a green suite without this assertion proves nothing, since the whole
# failure mode is an extra write nobody sees.
cleanup
mkdir -p $HOME/tcz-dupchurn-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-dupchurn-$fish_pid 'sleep 500'
tmux new-session -d -s 1 -c $HOME/tcz-dupchurn-$fish_pid 'sleep 500'
sleep 0.5
__tcz_categorize   # unnarrowed: renames both, stamps a bracketed ordinal on each
set -g dc_name1 "tcz-dupchurn-$fish_pid"
set -g dc_name2 "tcz-dupchurn-$fish_pid-2"
set -g dc_disp1 (tmux show-option -qv -t "$dc_name1" @tmux_lives_display)
set -g dc_disp2 (tmux show-option -qv -t "$dc_name2" @tmux_lives_display)
t "dup: unnarrowed tick suffixes the first member"  "yes" \
    (string match -qr ' \[[0-9]+\]$' -- "$dc_disp1"; and echo yes; or echo no)
t "dup: unnarrowed tick suffixes the second member" "yes" \
    (string match -qr ' \[[0-9]+\]$' -- "$dc_disp2"; and echo yes; or echo no)
t "dup: the two ordinals are distinct" "yes" \
    (test "$dc_disp1" != "$dc_disp2"; and echo yes; or echo no)
function tmux; set -a __t_cmds "$argv"; command tmux -L $sock $argv; end
set -g __t_cmds
__tcz_categorize "$dc_name1"   # narrowed pass over the already-suffixed member
functions -e tmux
t "dup: narrowed pass over an already-suffixed session writes zero @tmux_lives_display options" "0" \
    (count (string match -r 'set-option.*@tmux_lives_display' -- $__t_cmds))
set -e __t_cmds dc_name1 dc_name2 dc_disp1 dc_disp2
rm -rf $HOME/tcz-dupchurn-$fish_pid
cleanup

# --- N2: the over-correction guard, end to end (spec: "a stored X [1] when
# the computed display is Y must still be rewritten"). A narrowed pass must
# still heal a stale display that merely LOOKS like "<something> [N]" but
# whose base does not match the freshly computed one.
cleanup
mkdir -p $HOME/tcz-guard-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-guard-$fish_pid 'sleep 500'
sleep 0.5
__tcz_categorize   # unnarrowed: singleton, no ordinal
set -g gd_name "tcz-guard-$fish_pid"
tmux set-option -t "$gd_name" @tmux_lives_display "Stale Unrelated [1]"
__tcz_categorize "$gd_name"   # narrowed pass: computed display is "$gd_name", bare
set -g gd_disp (tmux show-option -qv -t "$gd_name" @tmux_lives_display)
t "dup: a stale display shaped like '<other> [N]' is still rewritten (no over-tolerance)" "$gd_name" "$gd_disp"
set -e gd_name gd_disp
rm -rf $HOME/tcz-guard-$fish_pid
cleanup

# --- M1: the claim-path clear, with a session that GENUINELY had a display
# first -- not the vacuous shape above (THE REGRESSION THAT WOULD BREAK
# NEUROTTO block claims a session that was never named/displayed by
# categorize at all, so deleting that clear leaves the suite green). This is
# spec line 103's exact scenario: an app claims a session the categorizer
# previously named AND displayed.
cleanup
mkdir -p $HOME/tcz-claim1-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claim1-$fish_pid 'sleep 500'
sleep 0.5
__tcz_categorize
set -g m1_disp (tmux show-option -qv -t "tcz-claim1-$fish_pid" @tmux_lives_display)
t "cat: M1 fixture genuinely has a display before the claim" "tcz-claim1-$fish_pid" "$m1_disp"
tmux set-option -t "tcz-claim1-$fish_pid" @tmux_lives_name "Claimed After Naming"
__tcz_categorize
set -g m1_disp2 (tmux show-option -qv -t "tcz-claim1-$fish_pid" @tmux_lives_display)
t "cat: a claim arriving AFTER naming still clears the display" "" "$m1_disp2"
set -e m1_disp m1_disp2
rm -rf $HOME/tcz-claim1-$fish_pid
cleanup

# --- M2: the stable-gen-N clear, with a genuinely-present prior display. A
# gen-N session can never legitimately EARN a display through production code
# (post-M3 fix below, it has no project by definition) -- so this simulates a
# stale value, the kind a manual poke, a migration, or an old fisher version
# could leave behind, to prove the categorizer still cleans it up on its
# regular bailout pass rather than only ever seeing an already-empty option.
cleanup
tmux new-session -d -s gen-1 -c $HOME
tmux set-option -t gen-1 @tmux_auto_name gen-1
tmux set-option -t gen-1 @tmux_lives_display "stale leftover value"
sleep 0.3
__tcz_categorize
set -g m2_disp (tmux show-option -qv -t gen-1 @tmux_lives_display)
t "cat: stable gen-N clears a stale display on its bailout pass" "" "$m2_disp"
t "cat: stable gen-N session itself is untouched (still gen-1)" "yes" \
    (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
set -e m2_disp
cleanup

# --- M3: the success-path write is gated on $proj, not just $f[5] -- a
# no-project claude session still composes a non-empty (task-only) display in
# __tcz_display_name, and writing it here would give a gen-N-bound session a
# display for exactly one pass before the very next tick's stable-gen-N
# bailout clears it right back out: a spurious write/unset pair for a session
# the spec's own table says should carry no display at all. Spy on the FIRST
# pass itself (not a second pass) to prove the write never happens even once,
# not merely that dedup hides it afterward.
cleanup
tmux new-session -d -s 0 -c $HOME "$shimdir/claude --enable-auto-mode --name No Project Task"
sleep 0.5
function tmux; set -a __t_cmds "$argv"; command tmux -L $sock $argv; end
set -g __t_cmds
__tcz_categorize
functions -e tmux
t "cat: no-project claude session never gets a display write, not even pass 1" "0" \
    (count (string match -r 'set-option.*@tmux_lives_display' -- $__t_cmds))
t "cat: no-project claude session is still renamed to gen-N" "yes" \
    (tmux has-session -t =gen-1 2>/dev/null; and echo yes; or echo no)
set -e __t_cmds
cleanup

# --- M4: a transient failure of the batched project/display lookup ALONE
# (not the rest of the tmux server -- list-sessions/list-panes elsewhere in
# the same pass keep succeeding) must not rename every owned session to
# gen-N for a tick. Intercept ONLY that one list-sessions call.
cleanup
tmux new-session -d -s alpha -c $HOME 'sleep 1000'
tmux new-session -d -s bravo -c $HOME 'sleep 1000'
tmux set-option -t alpha @tmux_auto_name alpha
tmux set-option -t bravo @tmux_auto_name bravo
sleep 0.3
function tmux
    if string match -qr -- 'list-sessions.*@tmux_lives_display' "$argv"
        return 0
    end
    command tmux -L $sock $argv
end
__tcz_categorize
functions -e tmux
t "cat: a failed batched lookup renames NEITHER session (fails closed)" "alpha,bravo" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
cleanup

# --- M5 (fix wave 2026-08-18): the __tcz_snapshot empty-display fallback
# (item 1 -- field 5 falls back to the tmux name so the picker/menu never see
# a blank row/label) must NEVER leak into @tmux_lives_display. This is the
# TRUE empty-display case M3 didn't cover: M3's fixture is a claude session
# with a task, so __tcz_display_name still returns something non-empty
# there. A general session in a generic (excluded) cwd is the case where
# __tcz_display_name returns NOTHING and __tcz_snapshot's field 5 becomes
# the fallback session name. Prove the categorize write stays gated on
# $proj (not on whether field 5 is populated), so this session's
# @tmux_lives_display stays genuinely unset even though the snapshot row
# feeding it is not blank.
cleanup
tmux new-session -d -s 0 -c $HOME
sleep 0.5
set -g m5_snap (__tcz_snapshot | string match -e '0	*' | cut -f5)
t "M5: snapshot field 5 IS the session-name fallback, not empty" "0" "$m5_snap"
__tcz_categorize
set -g m5_disp (tmux show-option -qv -t gen-1 @tmux_lives_display)
t "M5: no-project general session still carries no @tmux_lives_display after categorize" "" "$m5_disp"
set -e m5_snap m5_disp
cleanup

# --- narrowed categorize (fish_postexec) --------------------------------------------
# A command run in pane X cannot change the classification of session Y, so the
# postexec hook's full server-wide pass does N times the necessary work BY
# CONSTRUCTION. Narrowing it filters the expensive half — one `list-panes -s -t`
# and one session's pid inspection instead of `-a` across everything. The ~15s
# tick stays unnarrowed as the backstop for anything genuinely cross-session.
#
# THE SAFETY PROPERTY, and the reason this is safe at all: __tcz_categorize
# derives its collision-avoidance universe ($others) from a FRESH
# `tmux list-sessions`, NOT from the snapshot. So filtering the snapshot cannot
# shrink the name universe and cannot produce duplicate session names. The last
# assertion here is what pins that; without it, narrowing would be a rename bug.
cleanup
tmux new-session -d -s alpha 'sleep 1000'
tmux new-session -d -s bravo 'sleep 1000'
# STAMPED as owned. A hand-named session is protected by the ownership guard and
# would never be renamed by ANY pass, narrowed or not -- which made the first cut
# of these assertions vacuous (they passed against unnarrowed code).
tmux set-option -t alpha @tmux_auto_name alpha
tmux set-option -t bravo @tmux_auto_name bravo
sleep 0.5
t "snapshot: unfiltered sees every session"      2 (__tcz_snapshot | count)
t "snapshot: filtered sees only its own session" 1 (__tcz_snapshot alpha | count)
t "snapshot: filtered row is the right session"  "alpha" (__tcz_snapshot alpha | cut -f1)
t "snapshot: unknown session filter -> empty"    0 (__tcz_snapshot nosuchsession | count)

# Only the named session gets recategorized; the other keeps its old name.
__tcz_categorize alpha
t "narrowed: the target was recategorized"   "no"  (tmux has-session -t =alpha 2>/dev/null; and echo yes; or echo no)
t "narrowed: the other session is untouched" "yes" (tmux has-session -t =bravo 2>/dev/null; and echo yes; or echo no)
cleanup

# Collision avoidance must still consult sessions OUTSIDE the filter: `target`
# wants the project-derived name `tcz-collide-$fish_pid`, which an unfiltered
# session already holds (a literal name, standing in for another session that
# independently computed the same slug).
mkdir -p $HOME/tcz-collide-$fish_pid
tmux new-session -d -s target -c $HOME/tcz-collide-$fish_pid 'sleep 1000'
tmux new-session -d -s tcz-collide-$fish_pid 'sleep 1000'
tmux set-option -t target @tmux_auto_name target
sleep 0.5
__tcz_categorize target
t "narrowed: the outside session kept its name" "yes" \
    (tmux has-session -t "=tcz-collide-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "narrowed: target dodged the outside name"    "yes" \
    (tmux has-session -t "=tcz-collide-$fish_pid-2" 2>/dev/null; and echo yes; or echo no)
t "narrowed: no duplicate session names"        "yes" \
    (test (tmux list-sessions -F '#{session_name}' 2>/dev/null | count) -eq (tmux list-sessions -F '#{session_name}' 2>/dev/null | sort -u | count); and echo yes; or echo no)
rm -rf $HOME/tcz-collide-$fish_pid
cleanup

# ...and a numeric session's claude identity must land on ITSELF, not on a neighbour.
cleanup
tmux new-session -d -s 0 "$shimdir/claude --name Cross Write"
tmux new-session -d -s neighbour
sleep 0.5
# tick-call-batching task 3: __tcz_set_claude_opt's dedup read is now served from
# the per-pass session memo, so it must be fresh for sessions "0"/"neighbour" --
# flush any load an earlier test in this suite left cached before they existed.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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

# tick-call-batching task 4: the pane-walk memo is keyed by SESSION NAME, and this
# suite reuses short names ("probe", "0", "sA", ...) across many independently-built
# real -L $sock fixtures. Reusing the SAME name for a claude-then-no-claude pair
# across a cleanup boundary is what actually discriminates cleanup's own
# __tcz_tmux_flush (added this task) from a coincidence: the block above measures
# "0" claude -> yes THEN "0" claude-free never reused after it, so it cannot tell a
# fresh read from a stale one still saying "yes" from an earlier fixture. This one
# can, in both directions.
tmux new-session -d -s probe "$shimdir/claude --name Probe One"
sleep 0.4
t "has_claude: fresh fixture (with claude)" "yes" (__tcz_session_has_claude probe; and echo yes; or echo no)
cleanup
tmux new-session -d -s probe 'sleep 1000'
sleep 0.4
t "has_claude: same session NAME, rebuilt claude-free -- must not read the earlier fixture's cached yes" "no" \
    (__tcz_session_has_claude probe; and echo yes; or echo no)
cleanup
tmux new-session -d -s probe "$shimdir/claude --name Probe Two"
sleep 0.4
t "has_claude: same session NAME, rebuilt WITH claude again -- must not read the middle fixture's cached no" "yes" \
    (__tcz_session_has_claude probe; and echo yes; or echo no)
cleanup

# fresh_server's own flush is the SAME fix as cleanup's, for the SAME reason -- not
# mere symmetry, a reproducible bug with a completely realistic trigger: fresh_server
# creates its one session with NO explicit -s name, so tmux auto-numbers it, and a
# fresh server's first (only) session is ALWAYS named "0". Two consecutive
# fresh_server calls therefore reuse the name "0" for two entirely different real
# sessions, exactly like the "probe" pair above but via the OTHER helper.
fresh_server
tmux send-keys -t 0 "$shimdir/claude --name Zero Round A" Enter
sleep 0.6
t "has_claude: fresh_server round A, session 0 (with claude)" "yes" (__tcz_session_has_claude 0; and echo yes; or echo no)
fresh_server
sleep 0.4
t "has_claude: fresh_server round B, same auto-numbered name 0, claude-free -- must not read round A's cached yes" "no" \
    (__tcz_session_has_claude 0; and echo yes; or echo no)
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

# A @tmux_lives_name claim containing a literal tab must survive whole as the
# greedy last field, not get truncated at the embedded tab — this is exactly
# the property the position-4 (path) / greedy-position-5 (claim) split exists
# to preserve. NOT a RED discriminator: pre-change, the claim was ALREADY the
# greedy last field, so this passed before Task 3 too. It is a deliberate
# non-regression guard, pinned because the reviewer had to construct this case
# by hand to verify it. cut -f5 cannot be used here (it would itself split on
# the embedded tab); split the same way production does instead.
cleanup
set -l TAB (printf '\t')
set -l claim (printf 'Left\tRight')
tmux new-session -d -s 44 'sleep 1000'
tmux set-option -t 44 @tmux_lives_name "$claim"
sleep 0.5
set -l tabline (__tcz_snapshot | string match -e '44	*')
set -l tabfields (string split -m 4 $TAB -- $tabline)
t "snap: a claim containing a literal tab survives whole in field 5" "$claim" "$tabfields[5]"
cleanup

# ---------------------------------------------------------------------
# lifecycle: rename when claude starts in a shell pane, revert when it exits.
# UNDER TASK 4 THE TMUX NAME NO LONGER REVERTS -- it is pinned to the project
# for the session's whole life (project doesn't change when a process
# starts/stops), so the old "-c $HOME -> renamed to the --name slug -> reverts
# to gen-N" story is gone: $HOME has no project, so a $HOME-pinned session
# would sit at gen-N throughout with no transition to observe at all (that
# was verified, not assumed -- see the C5 controller correction). Re-pointed
# at a real project dir, this now exercises what DOES change across the
# lifecycle: the NAME stays put while the DISPLAY gains/drops the task.
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-lifecycle-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-lifecycle-$fish_pid
tmux send-keys -t 0 "$shimdir/claude --enable-auto-mode --name Lifecycle" Enter
sleep 0.8
__tcz_categorize
t "cat: lifecycle rename via shell pane" "yes" \
    (tmux has-session -t "=tcz-lifecycle-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "cat: lifecycle used the fake binary" "yes" \
    (pgrep -af -- '--name Lifecycle' | string match -q "*$shimdir*"; and echo yes; or echo no)
t "cat: lifecycle display carries the task while claude runs" "tcz-lifecycle-$fish_pid · Lifecycle" \
    (tmux show-option -qv -t "tcz-lifecycle-$fish_pid" @tmux_lives_display)
# Kill the claude process directly (SIGTERM; C-c/SIGINT is absorbed by fish job control).
set -l lcpid (tmux list-panes -t "tcz-lifecycle-$fish_pid" -F '#{pane_pid}' 2>/dev/null)
pkill -TERM -P $lcpid 2>/dev/null; or kill -TERM $lcpid 2>/dev/null
sleep 0.5
__tcz_categorize
t "cat: lifecycle NAME stays pinned to the project after claude exits" "yes" \
    (tmux has-session -t "=tcz-lifecycle-$fish_pid" 2>/dev/null; and echo yes; or echo no)
# THIS is the steady-state-freshness guard for C1's shipped structure (dedup
# intact, display sync merely decoupled from the rename short-circuit) --
# NOT "cat: display survives a second (no-op) pass" above, which only proves
# an UNCHANGING value persists and passes just as well if the write stays
# nested behind the short-circuit (verified: it does, since with the value
# unchanging pass 2 never touches the option either way). Here the DESIRED
# VALUE changes between passes (task present -> task gone) while the tmux
# NAME does not, which only a decoupled write can track. Do not weaken this
# one thinking it cosmetic -- it is load-bearing for C1.
t "cat: lifecycle DISPLAY drops the task once claude exits" "tcz-lifecycle-$fish_pid" \
    (tmux show-option -qv -t "tcz-lifecycle-$fish_pid" @tmux_lives_display)
rm -rf $HOME/tcz-lifecycle-$fish_pid
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
# __tcz_claim (integration): instant claude rename from preexec data.
# Task 5b: this must land on exactly the PROJECT slug the next categorize
# pass would produce (spec N1) -- never the raw --name/task text, even
# transiently -- so there is nothing left to flap. <raw> feeds only the
# display's task half now; the third (cwd) argument is gone (session_path
# is fetched from tmux itself, per spec N3 -- the pane's $PWD follows `cd`
# and the session path does not).
# ---------------------------------------------------------------------

# RED (pre-fix), proven against the unmodified function: it renamed straight
# to the raw task text's slug ("Fix the picker lag" -> Fix-the-picker-lag),
# ignoring the project entirely -- reproduced 0 -> Fix-the-picker-lag before
# this change; see task-5b-report.md for the failing run.
cleanup
mkdir -p $HOME/tcz-claim-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claim-$fish_pid
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "Fix the picker lag"
t "claim: instant rename lands on the project, not the raw task text" "yes" \
    (tmux has-session -t "=tcz-claim-$fish_pid" 2>/dev/null; and echo yes; or echo no)
t "claim: never took the raw task text as the tmux name" "no" \
    (tmux has-session -t =Fix-the-picker-lag 2>/dev/null; and echo yes; or echo no)
t "claim: stamped to the project slug" "tcz-claim-$fish_pid" \
    (tmux show-option -qv -t "tcz-claim-$fish_pid" @tmux_auto_name)
t "claim: display is project (dot) task" "tcz-claim-$fish_pid · Fix the picker lag" \
    (tmux show-option -qv -t "tcz-claim-$fish_pid" @tmux_lives_display)
rm -rf $HOME/tcz-claim-$fish_pid

# Item 2 (fix wave 2026-08-18): a typed `claude --name "Fix the picker lag"`
# is captured by the preexec hook's regex as the LITERAL quoted text, quotes
# included -- that is the design's own headline example, and the only way to
# type a multi-word name. __tcz_claim must not let those quotes leak into the
# display: the tick's own extraction (/proc argv, already shell-parsed) never
# carries them, so an unstripped quote pair would visibly disagree with the
# tick for as long as the tick takes to overwrite it.
cleanup
mkdir -p $HOME/tcz-claimq-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claimq-$fish_pid
set -l paneq (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $paneq '"Fix the picker lag"'
t "claim: quoted --name strips the surrounding quotes from the display" \
    "tcz-claimq-$fish_pid · Fix the picker lag" \
    (tmux show-option -qv -t "tcz-claimq-$fish_pid" @tmux_lives_display)
rm -rf $HOME/tcz-claimq-$fish_pid

# Generic dir ($HOME, per __tcz_project_name's own contract): no project ->
# do nothing at all, and specifically never fall back to "claude-<cwd>" --
# Task 3 deleted that fallback in __tcz_snapshot; this is its twin here.
cleanup
tmux new-session -d -s 0 -c $HOME
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "Some Task"
t "claim: no project -> name untouched" "yes" (tmux has-session -t =0 2>/dev/null; and echo yes; or echo no)
# FORWARD-ONLY GUARD, no pre-fix RED: pre-fix code renamed the session (to
# "Some-Task"), so "no claude-<cwd> name exists" was unobservable there by
# construction -- it passed for the wrong reason, not because the fallback
# was already gone. Kept as a guard against a future regression, not a
# discriminator of this one.
t "claim: no project -> never falls back to claude-<cwd>" "no" \
    (tmux list-sessions -F '#{session_name}' | string match -qr '^claude-'; and echo yes; or echo no)
# FORWARD-ONLY GUARD, no pre-fix RED: same reason -- pre-fix, session "0" no
# longer exists under that name once renamed, so this reads an empty lookup
# on a name that isn't there rather than proving no display was written.
t "claim: no project -> no display written" "" (tmux show-option -qv -t 0 @tmux_lives_display)
# Empty raw specifically -- this is the exact input shape that used to build
# "claude-<basename>" (the deleted fallback); with no project either, nothing
# should happen at all.
__tcz_claim $pane ""
t "claim: no project + empty raw -> still untouched, no fallback name" "yes" \
    (tmux has-session -t =0 2>/dev/null; and echo yes; or echo no)

# Ownership guard: a hand-named session is never touched by the claim path
# (non-regression -- this guard already existed pre-fix; kept exercised
# under the new call shape).
cleanup
mkdir -p $HOME/tcz-claim-guard-$fish_pid
tmux new-session -d -s handpick -c $HOME/tcz-claim-guard-$fish_pid
set -l pane (tmux list-panes -t handpick -F '#{pane_id}')
__tcz_claim $pane "Steal Attempt"
t "claim: ownership guard protects a hand-named session" "yes" \
    (tmux has-session -t =handpick 2>/dev/null; and echo yes; or echo no)
rm -rf $HOME/tcz-claim-guard-$fish_pid

# External claim (@tmux_lives_name): unrelated to the `claim` VERB (the name
# collision is coincidental), but the claim PATH must still respect it, same
# as __tcz_categorize. This is NEW coverage -- the pre-fix function never
# checked @tmux_lives_name at all, and __tcz_owned's purely-numeric check
# would otherwise wave a fresh externally-claimed session straight through.
cleanup
mkdir -p $HOME/tcz-claim-ext-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claim-ext-$fish_pid
tmux set-option -t 0 @tmux_lives_name "Neurotto CLI"
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "Some Task"
t "claim: an external @tmux_lives_name claim blocks the rename" "yes" \
    (tmux has-session -t =0 2>/dev/null; and echo yes; or echo no)
rm -rf $HOME/tcz-claim-ext-$fish_pid

# Collision: two owned sessions sharing one project dir -> second gets -2.
cleanup
mkdir -p $HOME/tcz-claim-dup-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claim-dup-$fish_pid
tmux new-session -d -s 1 -c $HOME/tcz-claim-dup-$fish_pid
set -l pane0 (tmux list-panes -t (__tcz_pane_target 0) -F '#{pane_id}')
set -l pane1 (tmux list-panes -t (__tcz_pane_target 1) -F '#{pane_id}')
__tcz_claim $pane0 "First"
__tcz_claim $pane1 "Second"
t "claim: collision suffixed" "tcz-claim-dup-$fish_pid,tcz-claim-dup-$fish_pid-2" \
    (tmux list-sessions -F '#{session_name}' | sort | string join ',')
rm -rf $HOME/tcz-claim-dup-$fish_pid

# THE FLAP, end to end: after claim, a following __tcz_categorize performs no
# further rename. This is the assertion that actually encodes the point of
# the task -- it must discriminate a pre-fix regression, not just confirm a
# steady state, so the raw task text's slug is chosen to DIFFER from the
# project: if claim ever again landed on the raw slug, categorize's very next
# pass would rename it out from under this assertion, and $claim_name would
# stop matching $cat_name. Mutation-checked (see report) by reverting the fix
# and confirming this specific assertion goes red.
cleanup
mkdir -p $HOME/tcz-claim-flap-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-claim-flap-$fish_pid
set -l pane (tmux list-panes -t 0 -F '#{pane_id}')
__tcz_claim $pane "Totally Different Task Text"
set -g claim_name (tmux display-message -p -t "$pane" '#{session_name}')
__tcz_categorize
set -g cat_name (tmux display-message -p -t "$pane" '#{session_name}')
t "claim: name after claim equals name after the next categorize (no flap)" \
    "$claim_name" "$cat_name"
t "claim: that steady name is the project, not the raw task text" \
    "tcz-claim-flap-$fish_pid" "$claim_name"
rm -rf $HOME/tcz-claim-flap-$fish_pid
cleanup

# ---------------------------------------------------------------------
# Dispatcher + tick silence (subprocess — exercises the real entrypoint)
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-tick-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-tick-$fish_pid 'sleep 1000'
t "main: tick emits nothing"  "" (fish --no-config $plugindir/functions/tmux-categorize.fish tick | string join ',')
t "main: tick renamed via subprocess" "yes" (tmux has-session -t "=tcz-tick-$fish_pid" 2>/dev/null; and echo yes; or echo no)
rm -rf $HOME/tcz-tick-$fish_pid
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
# Regression (macOS): a login shell's comm starts with a dash ("-fish"). `path
# basename` must get `--` or fish parses "-fish" as an option and errors, so
# __tcz_pid_comm returns empty and claude detection on the pane shell breaks.
# The shim now emits a `pid ppid comm` row because the fallback reads a shared
# `ps -Ao pid=,ppid=,comm=` snapshot rather than `ps -o comm= -p <pid>`; the
# GUARANTEE under test is unchanged — a dash-prefixed comm must survive intact.
set -g psshim /tmp/tcz-psshim-$fish_pid
mkdir -p $psshim
# The SECOND row is what actually exercises `path basename`. On Linux `comm` is
# already bare, so basename is a no-op and deleting it left the whole gate green
# (review-caught). macOS `comm` is a FULL PATH — that is the only case the call
# exists for, and it was covered by nothing.
printf '#!/bin/sh\nprintf "%%s\\n" "12345 1 -fish" "12346 1 /Users/u/.local/state/claude/versions/1.2.3/claude"\n' > $psshim/ps
chmod +x $psshim/ps
set -g ps_path_save $PATH
set -gx PATH $psshim $PATH
set -g tcz_force_ps 1
functions -q __tcz_ps_flush; and __tcz_ps_flush
t "pid_comm: dash-prefixed comm survives" "-fish" (__tcz_pid_comm 12345 2>/dev/null)
t "pid_comm: macOS full-path comm is basenamed" "claude" (__tcz_pid_comm 12346 2>/dev/null)
functions -q __tcz_ps_flush; and __tcz_ps_flush
set -e tcz_force_ps
set -gx PATH $ps_path_save
rm -rf $psshim

# ---------------------------------------------------------------------
# macOS pgrep -> sysmond storm (handoff docs/2026-08-17-handoff-pgrep-sysmond-macos.md)
#
# On macOS there is no /proc, so EVERY call takes the fallback branch, and
# /usr/bin/pgrep there links libsysmon.dylib -- it delegates enumeration to the
# /usr/libexec/sysmond ROOT DAEMON, which walks every process and every thread
# per request. Measured on macwork: ~4 of 14 cores, 0.4% idle. /bin/ps is
# libsysmon-clean, so on macOS the intuition inverts -- pgrep is the expensive
# primitive and ps is the cheap one.
#
# The CPU symptom is unreproducible on Linux (pgrep scans /proc in-process and
# never touches a daemon), so SPAWN COUNT is the portable invariant that
# actually encodes the bug. Reproduced here at 56 spawns per tick with
# tcz_force_ps set, against 0 on the native /proc path.
# ---------------------------------------------------------------------
set -g spshim /tmp/tcz-spawnshim-$fish_pid
set -g splog /tmp/tcz-spawnlog-$fish_pid
rm -rf $spshim $splog; mkdir -p $spshim $splog
printf '#!/bin/sh\necho x >> %s/ps\nexec /bin/ps "$@"\n' $splog > $spshim/ps
printf '#!/bin/sh\necho x >> %s/pgrep\nexec /usr/bin/pgrep "$@"\n' $splog > $spshim/pgrep
chmod +x $spshim/ps $spshim/pgrep
# Gather the probe pids BEFORE the shim goes on PATH — otherwise the harness's
# own `ps` is counted against the helpers and the bound measures the wrong thing.
set -g sp_pids (ps -Ao pid= 2>/dev/null | string trim | head -12)
set -g sp_path_save $PATH
set -gx PATH $spshim $PATH
set -g tcz_force_ps 1
functions -q __tcz_ps_flush; and __tcz_ps_flush
for p in $sp_pids
    __tcz_pid_comm $p >/dev/null 2>&1
    __tcz_pid_cmdline $p >/dev/null 2>&1
    __tcz_pid_children $p >/dev/null 2>&1
end
set -g sp_ps 0; test -f $splog/ps; and set sp_ps (string trim -- (wc -l < $splog/ps))
set -g sp_pgrep 0; test -f $splog/pgrep; and set sp_pgrep (string trim -- (wc -l < $splog/pgrep))
t "pid helpers: fallback spawns NO pgrep (macOS sysmond path)" 0 $sp_pgrep
# BOUNDED BOTH WAYS. `0 -le 2` is true, so an upper bound alone passes when the
# helpers do nothing at all — making all three a bare `return` satisfied both of
# these (review-caught). The lower bound plus a real-value check below is what
# makes them mean "one snapshot happened", not "nothing happened".
t "pid helpers: fallback is O(1) ps spawns, not O(pids)" 1 (test $sp_ps -ge 1 -a $sp_ps -le 2; and echo 1; or echo 0)
t "pid helpers: the probe loop actually resolved something" 1 (test -n (__tcz_pid_comm $fish_pid); and echo 1; or echo 0)
set -e tcz_force_ps
set -gx PATH $sp_path_save
rm -rf $spshim $splog

# The snapshot must not change what the helpers RETURN -- only how many
# processes they spawn getting there. `fish -c 'sleep …' &` is deliberately a
# parent WITH a child (fish forks sleep), so children has something to find.
fish -c 'sleep 5' &
set -g kidparent $last_pid
sleep 0.4
set -g kids_proc (__tcz_pid_children $kidparent 2>/dev/null | sort | string join ,)
set -g comm_proc (__tcz_pid_comm $kidparent)
set -g cmd_proc (__tcz_pid_cmdline $kidparent)
set -g tcz_force_ps 1
functions -q __tcz_ps_flush; and __tcz_ps_flush
set -g kids_ps (__tcz_pid_children $kidparent 2>/dev/null | sort | string join ,)
set -g comm_ps (__tcz_pid_comm $kidparent)
set -g cmd_ps (__tcz_pid_cmdline $kidparent)
set -e tcz_force_ps
t "pid_children: snapshot agrees with /proc" "$kids_proc" "$kids_ps"
t "pid_comm: snapshot agrees with /proc"     "$comm_proc" "$comm_ps"
# cmdline had only a `*fish*` substring check, so storing the whole ps line —
# pid glued onto the front of every command line — stayed green (review-caught).
# Compared as a SET of tokens: /proc joins argv with single spaces while ps
# preserves the original spacing, so a byte comparison would be brittle for the
# wrong reason.
# The strengthening above shipped its own hole: `fish -c 'sleep 5'` puts a `-c`
# token in the data, and `string join` parses its ARGUMENTS for options with no
# `--` to stop it — both sides threw `unknown option -c`, both substitutions
# collapsed to "", and "" = "" passed unconditionally on every run (silent on
# stderr in a `2>&1` capture, visible on a bare run). The comment above already
# tells this story once — a reviewer catching a weak assertion, replaced by
# something weaker still — so this is a repeat of the pattern, not a new one.
t "pid_cmdline: snapshot agrees with /proc (tokens)" (string join ' ' -- (string split -n ' ' -- "$cmd_proc")) (string join ' ' -- (string split -n ' ' -- "$cmd_ps"))
t "pid_cmdline: does not leak the pid column" 0 (string match -qr '^\s*'$kidparent'\s' -- "$cmd_ps"; and echo 1; or echo 0)
t "pid_children: found a real child to compare" 1 (test -n "$kids_proc"; and echo 1; or echo 0)
kill $kidparent 2>/dev/null

# The snapshot's lifetime is one PASS. __tcz_main flushes on entry so a
# long-lived caller can never be served a stale table -- plant a sentinel in the
# table, run a harmless verb, and it must be gone. Without this the flush is a
# correct line bound by nothing: removing it broke no assertion at all.
# ONE SENTINEL PER TABLE. A single comm sentinel left a flush that erases
# comm+args+loaded but NOT kids fully green (review-caught) — which is verbatim
# the unbounded stale/duplicate pid growth the original `string match -r` bug
# produced. Each table needs its own or the flush is only partly pinned.
set -g __tcz_ps_comm_999999 SENTINEL
set -g __tcz_ps_args_999999 SENTINEL
set -g __tcz_ps_kids_999999 SENTINEL
set -g __tcz_ps_environ_999999 SENTINEL
# Same property, same reason, for the tmux global-@option table __tcz_tmux_load
# added (tick-call-batching task 2) -- __tcz_main must flush it on entry too, or
# a long-lived caller could be served a global @option snapshot from a PRIOR
# pass. Its own sentinel: __tcz_tmux_flush is glob-based (__tcz_tmux_*), so this
# also re-covers the loaded flag by construction (same prefix).
set -g __tcz_tmux_g_probe_999999 SENTINEL
set -g __tcz_tmux_loaded 1
__tcz_main host-kind >/dev/null 2>&1
t "__tcz_main flushes the comm table on entry"    "" "$__tcz_ps_comm_999999"
t "__tcz_main flushes the args table on entry"    "" "$__tcz_ps_args_999999"
t "__tcz_main flushes the kids table on entry"    "" "$__tcz_ps_kids_999999"
t "__tcz_main flushes the environ table on entry" "" "$__tcz_ps_environ_999999"
t "__tcz_main flushes the tmux global-@option table on entry" "" "$__tcz_tmux_g_probe_999999"
t "__tcz_main flushes the tmux loaded sentinel on entry" 0 (set -q __tcz_tmux_loaded; and echo 1; or echo 0)
set -e __tcz_ps_comm_999999 __tcz_ps_args_999999 __tcz_ps_kids_999999 __tcz_ps_environ_999999 __tcz_tmux_g_probe_999999

# PLATFORM GATE, not per-pid readability. The gate was `test -r /proc/$pid/comm`,
# so a pid that exits mid-pass fell through to the fallback ON LINUX and built
# the entire snapshot — measured 188ms against 2.5ms, and it contradicted the
# claim that the /proc path was untouched. Either gate passed the whole suite,
# so nothing pinned it (review-caught).
fish -c 'true' &
set -g deadpid $last_pid
wait 2>/dev/null
functions -q __tcz_ps_flush; and __tcz_ps_flush
__tcz_pid_comm $deadpid >/dev/null 2>&1
__tcz_pid_children $deadpid >/dev/null 2>&1
t "a dead pid does NOT build the ps table on Linux" 0 (set -q __tcz_ps_loaded; and echo 1; or echo 0)
t "a dead pid still resolves to empty"              "" (__tcz_pid_comm $deadpid 2>/dev/null)
set -e deadpid

# __tcz_pid_environ is a FOURTH helper of the same per-pid shape, which the
# macwork handoff did not list. It is called TWICE per attached client in one
# pass — 18 of the 20 ps spawns left after the snapshot landed. It does not link
# libsysmon so it is not the sysmond storm, but the repeat is free to remove:
# memoize per pid, in the same per-pass table, cleared by the same flush.
# NB `ps eww` output is deliberately NOT pre-snapshotted for all pids — that
# would carry every process's entire environment.
set -g eshim /tmp/tcz-eshim-$fish_pid
set -g elog /tmp/tcz-elog-$fish_pid
rm -rf $eshim $elog; mkdir -p $eshim $elog
printf '#!/bin/sh\necho x >> %s/ps\nexec /bin/ps "$@"\n' $elog > $eshim/ps
chmod +x $eshim/ps
set -g e_path_save $PATH
set -gx PATH $eshim $PATH
set -g tcz_force_ps 1
functions -q __tcz_ps_flush; and __tcz_ps_flush
set -g env1 (__tcz_pid_environ $fish_pid 2>/dev/null | string collect)
set -g e_after1 (string trim -- (wc -l < $elog/ps))
set -g env2 (__tcz_pid_environ $fish_pid 2>/dev/null | string collect)
set -g e_after2 (string trim -- (wc -l < $elog/ps))
t "pid_environ: second call for the same pid spawns nothing" "$e_after1" "$e_after2"
t "pid_environ: memoized value matches the first read" "$env1" "$env2"
t "pid_environ: still returns something real" 1 (string match -q '*PATH*' -- "$env1"; and echo 1; or echo 0)
set -e tcz_force_ps
set -gx PATH $e_path_save
rm -rf $eshim $elog

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
# The fallback now reads a per-PASS ps snapshot, so a process spawned after the
# snapshot was taken is invisible to it — exactly as a process spawned after a
# `pgrep` call was invisible to that call. __tcz_main flushes on entry so each
# real pass starts fresh; this suite runs many scenarios in ONE process, so it
# has to flush explicitly wherever it spawns something mid-scenario.
functions -q __tcz_ps_flush; and __tcz_ps_flush
t "pid_children fallback finds the child" 1 (contains -- $kidpid (__tcz_pid_children $fish_pid); and echo 1; or echo 0)
set -e tcz_force_ps
functions -q __tcz_ps_flush; and __tcz_ps_flush
# Compared against a THIRD-PARTY parent, not $fish_pid. Taking the snapshot runs
# `ps` as a child of whichever shell runs it, so asking that same shell for its
# own children legitimately yields one more pid than /proc does (which spawns
# nothing). That artifact is impossible in production — lookups target pane pids,
# never the categorizer's own — so comparing self-children would be testing the
# harness rather than the helper.
fish -c 'sleep 5' &
set -g agreeparent $last_pid
sleep 0.4
t "pid_children /proc and fallback agree" (__tcz_pid_children $agreeparent | sort | string join ',') (begin; set -g tcz_force_ps 1; __tcz_ps_flush; __tcz_pid_children $agreeparent | sort | string join ','; set -e tcz_force_ps; end)
t "pid_children agree-test had a real child" 1 (test -n (__tcz_pid_children $agreeparent | string join ','); and echo 1; or echo 0)
kill $agreeparent 2>/dev/null
set -e agreeparent
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
# __tcz_recolor resolves @tmux_lives_tabs_color via __tcz_tab_color's memoized
# read (tick-call-batching task 2) -- flush so this section's direct calls
# (bypassing __tcz_main's own flush-on-entry) see the real, isolated test
# server's current (unset) tabs_color rather than a table some earlier
# section's assertions left behind.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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

# session_has_claude / session_title via a tmux stub (switch on subcommand).
# __tcz_session_title reads #{session_path} (the session's start dir,
# single-valued), not list-panes' active-pane pane_current_path, and consults
# @tmux_lives_display between the claim and the dir fallback.
#
# tick-call-batching task 3: __tcz_session_title's @tmux_lives_name read comes
# from the batched per-pass session memo (__tcz_tmux_load's `list-sessions -F`).
# tick-call-batching task 4: #{session_path} is now served from that SAME memo
# (__tcz_tmux_sess_path) instead of a live display-message call, and
# __tcz_session_has_claude's pane walk is now served from the shared per-pass
# pane memo (__tcz_tmux_panes) instead of its own list-panes call -- so the
# `case list-sessions` row below now carries $tcz_test_path in the real
# session_path position (4), and `case display-message` is gone (nothing
# calls it here any more). EVERY simulated state change below (panes OR path
# OR name) needs an explicit __tcz_tmux_flush before the next
# __tcz_session_has_claude/__tcz_session_title call, or that call would see a
# STALE memoized value instead of the one just set (same idiom this file
# already uses for __tcz_tmux_global/__tcz_heal_due). @tmux_lives_display
# stays a live show-option read, deliberately NOT migrated (see
# __tcz_session_title's own docstring for why), so it needs no such flush.
function tmux
    switch "$argv[1]"
        case list-panes
            printf '%s\n' $tcz_test_panes    # __tcz_session_has_claude: cmd\tpid per pane
        case show-option
            echo $tcz_test_display           # @tmux_lives_display override (still live)
        case list-sessions
            # session_path (4) and @tmux_lives_name (8, last, greedy) are the
            # only fields __tcz_session_title reads from this row; the rest
            # (attached/last_attached/claude/auto_name/display) are unused.
            printf 'sA\t0\t0\t%s\t\t\t\t%s\n' $tcz_test_path $tcz_test_name
    end
end
set -g __tcz_oldhome $HOME; set -g HOME /home/x; set -g tmux_lives_hostname macwork
set -g tcz_test_panes (printf 'fish\t999')
set -g tcz_test_path /home/x/workspace/tmux-lives
set -g tcz_test_name ''
set -g tcz_test_display ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "session_has_claude false for shells" no (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title no claude" "macwork: tmux-lives" (__tcz_session_title sA)
set -g tcz_test_panes (printf 'claude\t999')
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "session_has_claude true with a claude pane" yes (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title with claude" "macwork: tmux-lives (C)" (__tcz_session_title sA)
set -g tcz_test_panes (printf 'fish\t999')
set -g tcz_test_display 'My Project'
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "session_title honors @tmux_lives_display over dir" "macwork: My Project" (__tcz_session_title sA)
set -g tcz_test_name 'Neurotto CLI'
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "session_title honors @tmux_lives_name over display and dir" "macwork: Neurotto CLI" (__tcz_session_title sA)
functions -e tmux
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
set -g HOME $__tcz_oldhome; set -e __tcz_oldhome; set -e tmux_lives_hostname; set -e tcz_test_panes; set -e tcz_test_path; set -e tcz_test_name; set -e tcz_test_display

# empty session path must not shift args (arg-shift guard)
function tmux
    switch "$argv[1]"
        case list-panes
            printf 'claude\t999\n'           # session has claude
        case list-sessions
            printf 'sA\t0\t0\t\t\t\t\t\n'     # empty session_path (4), empty name (8)
    end
end
set -g __tcz_oldhome $HOME; set -g HOME /home/x; set -g tmux_lives_hostname macwork
t "session_title empty path keeps the (C) flag (no arg-shift)" "macwork:  (C)" (__tcz_session_title sA)
functions -e tmux
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
t "sf identity honors @tmux_lives_name then @tmux_lives_display then session_name" yes (string match -q '*#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{?#{!=:#{@tmux_lives_display},},#{@tmux_lives_display},#{session_name}}}*' -- "$SF"; and echo yes; or echo no)
t "sf identity uses the collapsed claude idiom (single readable ✦ mark)" yes (string match -q '*✦#[fg=#{@tmux_lives_text_fg}] #{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{?#{!=:#{@tmux_lives_display},},#{@tmux_lives_display},#{@tmux_lives_claude}}}*' -- "$SF"; and echo yes; or echo no)
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
# __tcz_status_identity returns a tmux format string, and a grep cannot tell a
# working #{?...} nesting from a malformed one — tmux does not error on a bad
# format, it silently renders literal text or nothing, and source-file returns
# rc 0 with zero stderr even on a bad line (this repo has shipped that exact class
# of bug once already: an unquoted #hex value tmux read as a comment). The grep
# checks below are necessary but not sufficient; expanding the format through a
# REAL tmux (display-message -p, the same expansion path the status bar uses) is
# what actually proves the three-level precedence — claim, then display, then the
# original fallback — on both the claude and non-claude branches.
set -g ident (__tcz_status_identity)
t "identity: consults the display option" 1 (string match -q '*@tmux_lives_display*' -- "$ident"; and echo 1; or echo 0)
t "identity: the claim still appears first" 1 (test (string match -r '@tmux_lives_name' -- "$ident" | count) -ge 1; and echo 1; or echo 0)
set -e ident

set -g idsock tli-id-$fish_pid
command tmux -L $idsock new-session -d -s TMUX-Setup-13 2>/dev/null
command tmux -L $idsock new-session -d -s gen-1 2>/dev/null
command tmux -L $idsock new-session -d -s disp-only 2>/dev/null
command tmux -L $idsock set -g @tmux_lives_mark_fg default 2>/dev/null
command tmux -L $idsock set -g @tmux_lives_text_fg default 2>/dev/null
set -g IDFMT (__tcz_status_identity)
command tmux -L $idsock set-option -t TMUX-Setup-13 @tmux_lives_claude "TMUX Setup 13" 2>/dev/null
t "identity: claude session collapses to a single '✦ name'" "#[fg=default]✦#[fg=default] TMUX Setup 13" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
t "identity: non-claude session shows its name only" "gen-1" (command tmux -L $idsock display-message -p -t gen-1 "$IDFMT" 2>/dev/null)
# non-claude: display wins over the session_name fallback
command tmux -L $idsock set-option -t disp-only @tmux_lives_display "Proj A" 2>/dev/null
t "identity: non-claude display wins over session_name" "Proj A" (command tmux -L $idsock display-message -p -t disp-only "$IDFMT" 2>/dev/null)
# non-claude: the claim still wins over display, not just over the old fallback
command tmux -L $idsock set-option -t disp-only @tmux_lives_name "Claimed" 2>/dev/null
t "identity: non-claude claim wins over display" "Claimed" (command tmux -L $idsock display-message -p -t disp-only "$IDFMT" 2>/dev/null)
# claude: display wins over the claude-name fallback
command tmux -L $idsock set-option -t TMUX-Setup-13 @tmux_lives_display "Proj B · task" 2>/dev/null
t "identity: claude display wins over the claude name" "#[fg=default]✦#[fg=default] Proj B · task" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
# claude: the claim still wins over display
command tmux -L $idsock set-option -t TMUX-Setup-13 @tmux_lives_name "Neurotto CLI" 2>/dev/null
t "identity: @tmux_lives_name overrides the claude name (still ✦-marked)" "#[fg=default]✦#[fg=default] Neurotto CLI" (command tmux -L $idsock display-message -p -t TMUX-Setup-13 "$IDFMT" 2>/dev/null)
command tmux -L $idsock kill-server 2>/dev/null
set -e idsock; set -e IDFMT

# real-tmux integration: __tcz_session_title must resolve the SESSION's start dir
# (#{session_path}), not the active pane's live cwd, and must consult
# @tmux_lives_display before falling back to the dir. Two things this proves:
# (1) REGRESSION (2026-07-09): `display-message -t "=$session" '#{pane_current_path}'`
#     returns EMPTY in tmux 3.3a (the =exact-target quirk), so ShellFish tab titles
#     rendered "<host>:  (C)" with a BLANK dir. Reading #{session_path} fixes it, but
#     display-message rejects the "=name" form OUTRIGHT — verified empirically it
#     returns nothing at all ("format 'session_path' not found" under -v), not just
#     for pane-scoped formats — so this now targets via __tcz_session_target (bare
#     name / $id), the same helper the neighbouring show-option calls already use.
# (2) a shell `cd` inside the pane used to relabel the tab, because the old lookup
#     read the active pane's LIVE cwd; #{session_path} is the session's fixed START
#     dir, so a `cd` no longer moves the title. As a side effect this also fixes a
#     latent multi-window bug nobody chose: `list-panes -t session` (no -s) resolves
#     to a single target-window — the session's CURRENTLY SELECTED one, verified to
#     return exactly one row, not one per window — so the old lookup made the tab
#     TRACK whichever window was selected; switching windows relabeled the tab.
#     #{session_path} is fixed at session creation and does not move with selection.
# The stub tests above can't catch a real-tmux targeting quirk, so drive a private
# -L socket, following the suite's existing pattern.
set -g tsock tcz-title-$fish_pid
set -g twdir /tmp/tcz-titledir-$fish_pid
rm -rf $twdir; mkdir -p $twdir/deep
command tmux -L $tsock -f /dev/null new-session -d -s realsess -c $twdir 2>/dev/null
# ts1's pane cd's into deep/ right after the session starts. No send-keys: typing
# into a real interactive shell would land in the operator's actual fish_history
# (XDG_DATA_HOME isn't covered by the suite's isolation guard, and this exact class
# of leak has hit this repo twice already). Baking the cd into the pane's own start
# command writes no history at all and settles near-instantly.
command tmux -L $tsock -f /dev/null new-session -d -s ts1 -c $twdir "cd $twdir/deep; exec sleep 60" 2>/dev/null
sleep 0.3
function tmux; command tmux -L $tsock $argv; end
set -g tmux_lives_hostname boxhost
# tick-call-batching task 3: __tcz_session_title's @tmux_lives_name read is now
# served from the per-pass session memo -- flush before the first read against
# this fresh $tsock server, so nothing an earlier test cached leaks in here.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "session_title resolves the session's start dir (real tmux)" "boxhost: "(basename $twdir) (__tcz_session_title realsess)
t "title: pinned to the session start dir, not the pane cwd after a cd" "boxhost: "(basename $twdir) (__tcz_session_title ts1)
command tmux -L $tsock set-option -t ts1 @tmux_lives_display "My Project" 2>/dev/null
t "title: honors @tmux_lives_display over the dir" "boxhost: My Project" (__tcz_session_title ts1)
command tmux -L $tsock set-option -t ts1 @tmux_lives_name "Claimed" 2>/dev/null
# @tmux_lives_name is memoized (unlike @tmux_lives_display just above, which
# stays a live read) -- the write above happened after the memo was loaded, so
# it must be flushed or this read would see the pre-write empty name instead.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "title: the claim still wins over display" "boxhost: Claimed" (__tcz_session_title ts1)

# multi-window regression: __tcz_session_title must stay stable across window
# selection. This is the bug the #{session_path} fix actually resolves (see the
# corrected docstring/comment above) — `list-panes -t <session>` without -s
# resolves to a single target-window, the CURRENTLY SELECTED one, so the old
# lookup made the tab TRACK whichever window was selected. Judged on whether the
# property could silently regress, not on whether it is currently correct: none
# of the single-window fixtures above (realsess, ts1) can catch a future
# "simplification" back toward a window-scoped lookup, because they never have
# more than one window.
mkdir -p $twdir/mw-start $twdir/mw-w1 $twdir/mw-w2
command tmux -L $tsock -f /dev/null new-session -d -s mw -c $twdir/mw-start 2>/dev/null
command tmux -L $tsock -f /dev/null new-window -t mw -c $twdir/mw-w1 2>/dev/null
command tmux -L $tsock -f /dev/null new-window -t mw -c $twdir/mw-w2 2>/dev/null
sleep 0.2
# session "mw" postdates the memo load above -- flush so its (never-claimed, so
# expected-empty either way, but this should not rely on that coincidence)
# @tmux_lives_name read comes from a snapshot that actually contains it.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "title: multi-window baseline is the session's own start dir" "boxhost: mw-start" (__tcz_session_title mw)
command tmux -L $tsock select-window -t mw:1 2>/dev/null
t "title: unchanged after selecting a different window" "boxhost: mw-start" (__tcz_session_title mw)
command tmux -L $tsock select-window -t mw:2 2>/dev/null
t "title: unchanged after selecting a third window" "boxhost: mw-start" (__tcz_session_title mw)

functions -e tmux
command tmux -L $tsock kill-server 2>/dev/null
set -e tmux_lives_hostname; set -e tsock; rm -rf $twdir; set -e twdir
functions -q __tcz_tmux_flush; and __tcz_tmux_flush

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
            # __tcz_tab_color, which since tick-call-batching task 2 reads a
            # memoized ONE-SHOT bulk `show -g` (argv[2] = -g) rather than a
            # per-key `show -gv @key` (argv[2] = -gv) -- keep the two shapes
            # distinct or the tabs-role lookup would alias onto $DEDUP_color
            # (the per-tty cache, still read per-key/unbatched) and skew this
            # dedup test.
            if test "$argv[2]" = -g
                echo "@tmux_lives_tabs_color ''"
            else
                echo $DEDUP_color            # show -gv @..._color (per-tty cache)
            end
        case set; set -g DEDUP_color "$argv[-1]"  # set -g @..._color <val>
        case '*'
    end
end
# __tcz_tab_color's bulk read is memoized per pass -- flush so THIS section's
# stub (not whatever an earlier section left behind) is what gets loaded.
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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

# ---------------------------------------------------------------------
# staleness: a value written mid-pass is visible to a same-pass read after it
# (tick-call-batching task 5's explicit "add a staleness test"). Against a
# REAL tmux server, not a stub -- a stub could accidentally answer correctly
# without the memo'"'"'s write-through actually doing anything; this exercises
# __tcz_emit_set's real tmux write AND its in-process memo write together,
# and __tcz_emit_get's read of __tcz_tmux_global -> __tcz_tmux_load's real
# `show -g` + __tcz_tmux_unquote parse for the cross-pass case.
# ---------------------------------------------------------------------
set -g stsock tcz-stale-$fish_pid
command tmux -L $stsock new-session -d -s stale-sess 2>/dev/null
sleep 0.2
function tmux; command tmux -L $stsock $argv; end
functions -q __tcz_tmux_flush; and __tcz_tmux_flush

set -g STTY /dev/pts/77
t "staleness: an unset emit key reads empty before any write" "" (__tcz_emit_get $STTY color)

__tcz_emit_set $STTY color '#abc123'
# THE staleness assertion: write mid-pass, then read the SAME key right
# after -- no flush between the write and this read -- must see the value
# just written, not whatever was cached (nothing, here) before the write.
t "staleness: a value written mid-pass is visible to a same-pass read after it" '#abc123' (__tcz_emit_get $STTY color)

# a write only touches its own key -- an unrelated tty's cache is untouched
t "staleness: a write does not leak into an unrelated cached key" "" (__tcz_emit_get /dev/pts/78 color)

# a SECOND write to the SAME key is visible immediately too, not just the first
__tcz_emit_set $STTY color '#def456'
t "staleness: a second same-pass write is visible immediately as well" '#def456' (__tcz_emit_get $STTY color)

# cross-pass: flushing and reloading must pick up what was actually persisted
# to the real tmux option, not just the in-process memo half -- proves
# __tcz_emit_set's tmux write and its memo write-through agree with each
# other, not merely that the memo half looks right in isolation.
__tcz_tmux_flush
t "staleness: the write also reached real tmux, not only the in-process memo" '#def456' (__tcz_emit_get $STTY color)

functions -e tmux
command tmux -L $stsock kill-server 2>/dev/null
set -e stsock; set -e STTY
functions -q __tcz_tmux_flush; and __tcz_tmux_flush

# ---------------------------------------------------------------------
# real end-to-end: a session RENAMED by __tcz_categorize mid-pass still gets
# a correctly-composed title for its already-attached client, in the SAME
# `tick` pass (tick-call-batching task 5). This is the concrete scenario the
# read-after-write audit exists to catch: __tcz_tmux_clients loads AFTER
# __tcz_categorize's renames (own docstring), so #{client_session} in this
# pass'"'"'s client memo is the NEW name -- but __tcz_tmux_sess_path/_name are
# still keyed by the OLD (pre-rename) name in the session memo loaded at pass
# start, since Task 5 did not add rename-tracking to that memo (see
# __tcz_session_title'"'"'s own docstring for why -- deliberately left live).
# Proven safe here, not assumed: the ONLY thing that triggers a rename
# (a non-empty project) is also exactly what makes __tcz_categorize write
# @tmux_lives_display for that SAME session in the SAME pass, and
# __tcz_session_title'"'"'s live (never-memoized) display read picks that up
# directly by the session'"'"'s NEW name -- short-circuiting before the stale
# path/name memo lookups would ever be consulted.
#
# The project dir'"'"'s own basename is a WEAK discriminator on its own -- it is
# by definition identical to __tcz_dir_display'"'"'s bare-name fallback, so a
# fixture with no task suffix cannot tell "resolved via the live display read"
# apart from "coincidentally fell through to the dir fallback and got the same
# string anyway" (caught in review: an earlier cut of this fixture used a bare
# sleep pane and passed even with the live display read stubbed out from under
# it). A claude pane with --name adds a " · <task>" suffix the dir fallback
# cannot produce, which is what actually discriminates the two paths.
# ---------------------------------------------------------------------
cleanup
mkdir -p $HOME/tcz-rn-$fish_pid
tmux new-session -d -s 0 -c $HOME/tcz-rn-$fish_pid "$shimdir/claude --enable-auto-mode --name Fix the thing"
sleep 0.3
env LC_TERMINAL=ShellFish TERM=xterm-256color script -qec "tmux attach -t 0" /dev/null >/dev/null 2>&1 &
set -l rn_n 0
while test $rn_n -lt 25; and test (tmux list-clients 2>/dev/null | count) -eq 0
    sleep 0.2
    set rn_n (math $rn_n + 1)
end
set -g tmux_lives_hostname rntest
set -l rn_tty (tmux list-clients -F '#{client_tty}')
__tcz_main tick '#445566' >/dev/null 2>&1
set -l rn_names (tmux list-sessions -F '#{session_name}')
set -l rn_key (__tcz_emit_key $rn_tty)
set -l rn_title (tmux show-option -gqv @tmux_lives_emit_"$rn_key"_title)
t "rename-mid-pass: the session was actually renamed off its numeric name" "tcz-rn-$fish_pid" "$rn_names"
t "rename-mid-pass: the attached client's title carries the task suffix (proves the live display read, not the stale-name dir fallback)" "rntest: tcz-rn-$fish_pid · Fix the thing (C)" "$rn_title"
set -e tmux_lives_hostname
rm -rf $HOME/tcz-rn-$fish_pid
cleanup

# ---------------------------------------------------------------------
# rename-mid-pass, project-less counterpart (fix wave 2026-08-19): the
# claude+display fixture above is proven safe only because __tcz_categorize
# writes @tmux_lives_display for that SAME session in the SAME pass, and
# __tcz_session_title's live (never-memoized) display read short-circuits
# before the stale-by-old-name path/name memo lookups are ever consulted.
# A project-less rename (numeric -> gen-N, __tcz_categorize's stable-gen-N
# bailout) writes NO display at all, so nothing short-circuits: the
# fallback #{session_path} lookup DOES get consulted, and it is
# __tcz_tmux_sess_path -- the per-pass memo loaded before this rename and
# still keyed by the pre-rename numeric name. Reproduced pre-fix: the
# attached client's IN-PASS title read "<host>: " (blank dir, a by-name
# lookup miss) instead of "<host>: ~".
#
# Started with -f /dev/null and a plain `sleep`, same reasoning as the g2
# fixture above: this is the FIRST new-session after `cleanup` kills the
# server, so it is what actually starts the new server process and decides
# whether it loads the user's REAL (fisher-installed) ~/.tmux.conf. Without
# -f /dev/null that real config's own live tmux-lives hooks fire the instant
# the real client attaches below and race-rename this throwaway session
# using a DIFFERENT (installed, possibly older) categorizer before our own
# __tcz_main tick ever runs -- reproduced: session ended up named "sleep"
# (the pane's running command, the installed version's naming scheme) and
# every assertion below failed against a session that no longer existed
# under this name.
# ---------------------------------------------------------------------
cleanup
tmux -f /dev/null new-session -d -s 0 -c $HOME 'sleep 500'
sleep 0.3
env LC_TERMINAL=ShellFish TERM=xterm-256color script -qec "tmux attach -t 0" /dev/null >/dev/null 2>&1 &
set -l pl_n 0
while test $pl_n -lt 25; and test (tmux list-clients 2>/dev/null | count) -eq 0
    sleep 0.2
    set pl_n (math $pl_n + 1)
end
set -g tmux_lives_hostname pltest
set -l pl_tty (tmux list-clients -F '#{client_tty}')
__tcz_main tick '#445566' >/dev/null 2>&1
set -l pl_names (tmux list-sessions -F '#{session_name}')
set -l pl_key (__tcz_emit_key $pl_tty)
set -l pl_title (tmux show-option -gqv @tmux_lives_emit_"$pl_key"_title)
t "rename-mid-pass, project-less: the session was promoted off its numeric name" "gen-1" "$pl_names"
t "rename-mid-pass, project-less: the attached client's IN-PASS title carries the real dir, not a blank one left by the stale-by-old-name path memo" "pltest: ~" "$pl_title"
set -e tmux_lives_hostname
cleanup

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
# tick-call-batching task 3: __tcz_set_claude_opt's dedup read now comes from the
# batched per-pass session memo, not a live show-option call -- so the stub grew a
# `case list-sessions` row (replacing `case show-option`) carrying $CLAUDE_CUR, and
# EVERY simulated state change below needs an explicit __tcz_tmux_flush before the
# next __tcz_set_claude_opt call, or that call would read a STALE memoized value
# instead of the $CLAUDE_CUR just set (same idiom already used elsewhere in this
# file for __tcz_tmux_global/__tcz_heal_due).
set -g CLAUDE_SET ''
set -g CLAUDE_CUR ''
function tmux
    switch "$argv[1]"
        case set-option
            set -g CLAUDE_SET "$argv"   # capture the last set-option
        case list-sessions
            # session_name/attached/last_attached/path/auto_name/display/name are
            # unused by __tcz_set_claude_opt -- only the claude field (position 5,
            # not greedy-last) matters here.
            printf 'sA\t0\t0\t\t%s\t\t\t\n' $CLAUDE_CUR
        case list-panes
            printf '%s\n' $tcz_claude_panes
    end
end
set -g tcz_claude_panes (printf 'claude\t4242')
functions -c __tcz_cmdline_name __tcz_cmdline_name_bak
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; echo opus; end
# changed (cur empty -> opus): sets
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt writes @tmux_lives_claude when it changed" yes (string match -q '*set-option*sA*@tmux_lives_claude*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# unchanged (cur already opus): SKIPS the set (no redraw)
set -g CLAUDE_CUR opus; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt skips the set when unchanged (no needless redraw)" yes (test -z "$CLAUDE_SET"; and echo yes; or echo no)
# claude went away (cur opus, now non-claude -> ''): sets (clears)
set -g tcz_claude_panes (printf 'fish\t4242')
set -g CLAUDE_CUR opus; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt clears @tmux_lives_claude when a claude went away" yes (string match -q '*@tmux_lives_claude*' -- "$CLAUDE_SET"; and not string match -q '*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# already empty non-claude: SKIPS
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt falls back to the pane title when there is no --name" yes (string match -q '*@tmux_lives_claude*TMUX Setup 21*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# tick-call-batching task 4: a title containing a literal embedded tab must survive
# the round trip through the new pane memo (__tcz_tmux_pane_fetch splits -m 2 so
# title stays the greedy-last field -> __tcz_tmux_panes re-serializes it verbatim,
# tab included, via printf -> __tcz_set_claude_opt splits -m 2 again) exactly as it
# did with the direct list-panes call this replaced -- same property this file
# already pins for @tmux_lives_name's own greedy-last field (see the "Left\tRight"
# test near the numeric-session block above), now proven for the pane TITLE path.
set -l TABtc (printf '\t')
set -l titletab (printf '⠂ Left\tRight')
set -l wantfrag (printf 'Left%sRight' $TABtc)
set -g tcz_claude_panes (printf 'claude\t4242\t%s' $titletab)
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt: a pane title containing a literal tab survives whole" "yes" \
    (string match -q "*@tmux_lives_claude*$wantfrag*" -- "$CLAUDE_SET"; and echo yes; or echo no)
# --name still WINS when present (stable flag beats a volatile title)
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; echo opus; end
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt prefers --name over the pane title" yes (string match -q '*@tmux_lives_claude*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
# an untrusted title (no leading glyph word) must NOT become the name
set -g tcz_claude_panes (printf 'claude\t4242\tbare-title')
functions -e __tcz_cmdline_name; function __tcz_cmdline_name; end
set -g CLAUDE_CUR ''; set -g CLAUDE_SET ''
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_set_claude_opt sA
t "set_claude_opt ignores an unparseable title" yes (test -z "$CLAUDE_SET"; and echo yes; or echo no)
functions -e tmux; functions -e __tcz_cmdline_name; functions -c __tcz_cmdline_name_bak __tcz_cmdline_name; functions -e __tcz_cmdline_name_bak; set -e tcz_claude_panes; set -e CLAUDE_SET; set -e CLAUDE_CUR
functions -q __tcz_tmux_flush; and __tcz_tmux_flush

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
            # __tcz_heal_due now reads BOTH keys off one memoized bulk `show -g`
            # (argv = (show -g), no per-key argv[3] to switch on) -- emit the
            # bulk-line shape the real `tmux show -g` uses, one option per line,
            # value bare (no quoting needed: these are always plain integers).
            # An unset heal_at must be ABSENT from the bulk dump, matching real
            # tmux's own "unset custom option never appears" behaviour.
            echo "@tmux_lives_heal_interval $HEAL_interval"
            test -n "$HEAL_at"; and echo "@tmux_lives_heal_at $HEAL_at"
        case set
            string match -q '*heal_at' -- "$argv[3]"; and set -g HEAL_at "$argv[-1]"
        case '*'
    end
end
# Each __tcz_heal_due call below is a direct call (not through __tcz_main, so
# no automatic flush-on-entry) and this block deliberately exercises a
# SEQUENCE of states -- unset, just-scheduled, before-schedule, at-schedule,
# disabled -- so the memoized bulk read must be flushed before EVERY call, or
# a later call in the sequence would silently see an earlier call's snapshot
# (the exact read-after-write staleness hazard __tcz_tmux_load introduces).
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "heal due when unset (schedules)" 0 (__tcz_heal_due 1000; echo $status)
t "heal_at advanced to now+interval" 1120 "$HEAL_at"
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "heal not due before the interval" 1 (__tcz_heal_due 1100; echo $status)
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
t "heal due at/after the schedule" 0 (__tcz_heal_due 1120; echo $status)
set -g HEAL_interval 0
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
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
t "thp_row lead is 18 visible cols + name" (math 18 + 4) (string length --visible -- (__tcz_strip_sgr (__tcz_thp_row "$THX" warm 0)))
t "thp_row selected keeps the width" (math 18 + 4) (string length --visible -- (__tcz_strip_sgr (__tcz_thp_row "$THX" warm 1)))
t "thp_row selected carries the ▌ marker" yes (string match -q '*▌*' -- (__tcz_thp_row "$THX" warm 1); and echo yes; or echo no)
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
# picker-legibility-autoapply Task 6: cells widened 15 -> 16 (active earns a
# fourth trim cell, now that window-status-current-format reads it).
t "cells is 16 visible cols" 16 (string length --visible -- "$CELLS")
# Inked cells move 14 -> 15 (5+4+2+1+1+1+1) now that active is drawn too —
# the 16th column is the tier gap. This count now DOES discriminate the
# active-cell addition, on top of its original job as a non-regression
# guard that the seven-eighths glyph is still what draws a cell.
t "cells still uses the seven-eighths block" 15 (count (string match -ra '▇' -- "$CELLS"))
t "cells sets FOREGROUND, not background" 0 (count (string match -ra '48;2;' -- "$CELLS"))
t "cells carries each role colour" 1 (string match -q '*38;2;17;34;51*' -- "$CELLS"; and echo 1; or echo 0)
# a non-hex cell degrades to a blank gap, keeping the strip aligned
t "cells degrades non-hex to blanks" 16 (string length --visible -- (__tcz_thp_cells '#112233 nope #334455 #445566 #556677 #667788 #778899'))
set -g BAND (__tcz_thp_band '#5f772b')
t "band is 16 visible cols" 16 (string length --visible -- "$BAND")
# band has no tier gap (it is one colour end to end), so unlike the cells
# glyph-count guard above, this DOES move with the width: 15 -> 16.
t "band uses the same glyph, now 16 wide" 16 (count (string match -ra '▇' -- "$BAND"))
t "band blank fallback is 16 visible cols" 16 (string length --visible -- (__tcz_thp_band nope))

# --- ordering and widths, asserted on the RENDERED strip -----------------------
# Each role gets a distinguishable colour so a run length is unambiguous.
# Order is by on-screen area: tabs bar cap · gap · windows sep text · active.
set -g W1 (__tcz_thp_cells '#010101 #020202 #030303 #040404 #050505 #060606 #070707')
set -g W1V (__tcz_strip_sgr "$W1")
t "strip: tabs leads with 5 cells" 1 (string match -qr '^(\e\[[0-9;]*m)*[^\e]*▇{5}' -- "$W1"; and echo 1; or echo 0)
# fg colour order proves WHICH role sits where, independent of run length.
set -g W1SEQ (string join ' ' (string match -ra '38;2;[0-9]+;[0-9]+;[0-9]+' -- "$W1"))
t "strip: role order is tabs bar cap windows sep text active" \
  "38;2;3;3;3 38;2;1;1;1 38;2;6;6;6 38;2;5;5;5 38;2;2;2;2 38;2;7;7;7 38;2;4;4;4" "$W1SEQ"
t "strip: active (#040404) now appears, as the trailing trim cell" 1 (string match -ra '38;2;4;4;4' -- "$W1" | count)
# The tier gap is 1 column wide per the mapping table (5+4+2+1+1+1+1+1=16), so
# exactly one blank CHARACTER appears, never two adjacent — a single-space
# pattern is the only one this can ever match. (Caught pre-implementation:
# the brief's own draft used a two-space pattern, which cannot match a
# 1-column gap and would fail both before AND after the fix.)
t "strip: exactly one blank tier column" 1 (string match -ra ' ' -- "$W1V" | count)
# and the scheme row still shows ink cells inside it (unaffected by the reorder)
t "row strip still shows ink cells inside the row" 1 (string match -q '*▇▇*' -- (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 0 0); and echo 1; or echo 0)

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
# selection puts the ▌ marker in brand and brightens the name
set -g SRS (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'legacy look' off 1 0)
t "staterow selected shows the marker" 1 (string match -q '*▌*' -- "$SRS"; and echo 1; or echo 0)
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

# --- Task 2: marker glyph and band extent ---------------------------------------
# ▌ (U+258C, LEFT half block) replaces ▐ (U+2590, RIGHT half). Same width and
# height; the ink moves to the left of the cell, which buys half a column of
# clearance from the first swatch without spending a column on it.
set -g R2 (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 1 0)
t "row: selected marker is the left half block" 1 (string match -q '*▌*' -- "$R2"; and echo 1; or echo 0)
t "row: the right half block is gone" 0 (string match -ra '▐' -- "$R2" | count)
set -g S2 (__tcz_thp_staterow 50 (__tcz_thp_band '#112233') current live 1 1)
t "staterow: selected marker is the left half block" 1 (string match -q '*▌*' -- "$S2"; and echo 1; or echo 0)
t "staterow: the right half block is gone" 0 (string match -ra '▐' -- "$S2" | count)
# Unselected rows must carry no marker ink at all, only its column.
set -g R2U (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 0 0)
t "row: unselected row has no marker glyph" 0 (string match -ra '▌|▐' -- "$R2U" | count)
# __tcz_thp_slider carries the identical marker line — all three sit in column 1
# of the same frame (scheme row, state row, slider row), so a mismatched glyph
# in any one of them would read as a bug even though the slider's own layout
# doesn't need the extra clearance.
t "thp_slider selected marker is the left half block" 1 (string match -q '*▌*' -- (__tcz_thp_slider R 10 1); and echo 1; or echo 0)
t "thp_slider: the right half block is gone" 0 (string match -ra '▐' -- (__tcz_thp_slider R 10 1) | count)

# --- Task 1: the scheme-row cache -----------------------------------------
# The discriminator is a CALL COUNT, not a grep. A "fix" that caches but still
# rebuilds every row passes any string-shaped assertion and fails this one.
set -g __t1_calls 0
functions --copy __tcz_thp_row_uncached __t1_real
function __tcz_thp_row_uncached
    set -g __t1_calls (math $__t1_calls + 1)
    __t1_real $argv
end

set -g __t1_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
__tcz_thp_cacheclear

# transparency: cached output must equal uncached, on miss AND on hit
set -g __t1_a (__t1_real "$__t1_pal" 'mono soft' 0 0 | string escape)
set -g __t1_b (__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 | string escape)
set -g __t1_c (__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 | string escape)
t "rowcache: cached output matches uncached (miss)" "$__t1_a" "$__t1_b"
t "rowcache: cached output matches uncached (hit)"  "$__t1_a" "$__t1_c"

# the hit did no work
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 >/dev/null
t "rowcache: a cache hit calls the builder zero times" 0 $__t1_calls

# a cursor move dirties exactly TWO rows out of 35
__tcz_thp_cacheclear
for i in (seq 35)
    __tcz_thp_row "$__t1_pal" "scheme$i" (test $i -eq 5; and echo 1; or echo 0) 0 $i >/dev/null
end
set -g __t1_calls 0
for i in (seq 35)
    __tcz_thp_row "$__t1_pal" "scheme$i" (test $i -eq 6; and echo 1; or echo 0) 0 $i >/dev/null
end
t "rowcache: moving the cursor one row rebuilds exactly 2 rows" 2 $__t1_calls

# no key -> no caching, byte-identical to the original builder
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 >/dev/null
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 >/dev/null
t "rowcache: omitting the key bypasses the cache entirely" 2 $__t1_calls

# invalidation: clearing forces a rebuild
__tcz_thp_cacheclear
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 >/dev/null
t "rowcache: cacheclear forces a rebuild" 1 $__t1_calls

functions --erase __tcz_thp_row_uncached
functions --copy __t1_real __tcz_thp_row_uncached

# --- Task 2: the static-row cache ------------------------------------------
# Once scheme rows are cached (Task 1), the FRAME-CONSTANT rows dominate a
# redraw: the preview bar, the tab chip, the seed zone, the legend, the two
# second-list rows, and the legacy band feeding two of those. Same
# discriminator as Task 1 throughout: a call COUNT, not a grep.
set -g __t2_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'

# -- preview: hexes capfg host name w [cachekey] --
set -g __t2_calls 0
functions --copy __tcz_thp_preview_uncached __t2_prev_real
function __tcz_thp_preview_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_prev_real $argv
end
__tcz_thp_cacheclear
set -g __t2_a (__t2_prev_real "$__t2_pal" '#f5f5f5' somehost Monitoring 50 | string escape)
set -g __t2_b (__tcz_thp_preview "$__t2_pal" '#f5f5f5' somehost Monitoring 50 k1 | string escape)
t "staticcache: preview cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_preview "$__t2_pal" '#f5f5f5' somehost Monitoring 50 k1 >/dev/null
t "staticcache: preview hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_preview "$__t2_pal" '#f5f5f5' somehost Monitoring 50 >/dev/null
__tcz_thp_preview "$__t2_pal" '#f5f5f5' somehost Monitoring 50 >/dev/null
t "staticcache: preview omitting the key bypasses the cache" 2 $__t2_calls
functions --erase __tcz_thp_preview_uncached
functions --copy __t2_prev_real __tcz_thp_preview_uncached

# -- tabstrip: tabshex tabsfg title w [cachekey] --
# tabstrip's uncached builder returns STATUS 1 (not 0) on its early-return
# paths (non-hex tabshex, empty title) — the common non-ShellFish case. Proved
# live before this shipped: `test -z "$cachekey"; and BUILDER; and return`
# (Task 1's exact `and`-chain shape) silently falls through to the cache-WRITE
# branch whenever BUILDER returns nonzero, even with cachekey empty — which
# would have broken "no key -> always uncached" on every non-ShellFish redraw.
# The two blocks below cover the normal path and that early-return path
# separately.
set -g __t2_calls 0
functions --copy __tcz_thp_tabstrip_uncached __t2_tab_real
function __tcz_thp_tabstrip_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_tab_real $argv
end
__tcz_thp_cacheclear
set -g __t2_a (__t2_tab_real '#98b3a0' '#f5f5f5' my-session 50 | string escape)
set -g __t2_b (__tcz_thp_tabstrip '#98b3a0' '#f5f5f5' my-session 50 k1 | string escape)
t "staticcache: tabstrip cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_tabstrip '#98b3a0' '#f5f5f5' my-session 50 k1 >/dev/null
t "staticcache: tabstrip hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_tabstrip '#98b3a0' '#f5f5f5' my-session 50 >/dev/null
__tcz_thp_tabstrip '#98b3a0' '#f5f5f5' my-session 50 >/dev/null
t "staticcache: tabstrip omitting the key bypasses the cache" 2 $__t2_calls
# the early-return (status 1) path, unkeyed: must still call through every time
set -g __t2_calls 0
__tcz_thp_tabstrip notahex '#f5f5f5' my-session 50 >/dev/null
__tcz_thp_tabstrip notahex '#f5f5f5' my-session 50 >/dev/null
t "staticcache: tabstrip early-return path still bypasses cache unkeyed" 2 $__t2_calls
functions --erase __tcz_thp_tabstrip_uncached
functions --copy __t2_tab_real __tcz_thp_tabstrip_uncached

# -- seedzone: w hex hue L C editing chan r g b [cachekey] --
set -g __t2_calls 0
functions --copy __tcz_thp_seedzone_uncached __t2_sz_real
function __tcz_thp_seedzone_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_sz_real $argv
end
__tcz_thp_cacheclear
set -g __t2_a (__t2_sz_real 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 | string escape)
set -g __t2_b (__tcz_thp_seedzone 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 k1 | string escape)
t "staticcache: seedzone cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_seedzone 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 k1 >/dev/null
t "staticcache: seedzone hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_seedzone 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 >/dev/null
__tcz_thp_seedzone 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 >/dev/null
t "staticcache: seedzone omitting the key bypasses the cache" 2 $__t2_calls
functions --erase __tcz_thp_seedzone_uncached
functions --copy __t2_sz_real __tcz_thp_seedzone_uncached

# -- staterow: w cells name label selected live [cachekey] --
set -g __t2_calls 0
functions --copy __tcz_thp_staterow_uncached __t2_sr_real
function __tcz_thp_staterow_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_sr_real $argv
end
__tcz_thp_cacheclear
set -g __t2_cells (__tcz_thp_cells "$__t2_pal")
set -g __t2_a (__t2_sr_real 50 "$__t2_cells" 'mono soft' current 1 1 | string escape)
set -g __t2_b (__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 1 1 cur_1_1 | string escape)
t "staticcache: staterow cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 1 1 cur_1_1 >/dev/null
t "staticcache: staterow hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 1 1 >/dev/null
__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 1 1 >/dev/null
t "staticcache: staterow omitting the key bypasses the cache" 2 $__t2_calls
functions --erase __tcz_thp_staterow_uncached
functions --copy __t2_sr_real __tcz_thp_staterow_uncached
# collision proof: both production call sites (currow/offrow) can carry
# selected=0 live=0 AT ONCE (browsing the scheme list, no preview active)
# despite different cells/name/label — a bare "<selected>_<live>" cachekey
# (the brief's literal formula) would let one serve the other's cached
# content. The call sites prefix a row-identity token ("cur_"/"off_")
# instead; this proves that actually separates them.
__tcz_thp_cacheclear
set -g __t2_cur (__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 0 0 cur_0_0 | string escape)
set -g __t2_off (__tcz_thp_staterow 50 (__tcz_thp_band '#444444') 'legacy look' off 0 0 off_0 | string escape)
t "staticcache: staterow cur/off share no slot despite equal selected_live" no (test "$__t2_cur" = "$__t2_off"; and echo yes; or echo no)

# -- band: hex [cachekey] --
set -g __t2_calls 0
functions --copy __tcz_thp_band_uncached __t2_band_real
function __tcz_thp_band_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_band_real $argv
end
__tcz_thp_cacheclear
set -g __t2_a (__t2_band_real '#444444' | string escape)
set -g __t2_b (__tcz_thp_band '#444444' band | string escape)
t "staticcache: band cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_band '#444444' band >/dev/null
t "staticcache: band hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_band '#444444' >/dev/null
__tcz_thp_band '#444444' >/dev/null
t "staticcache: band omitting the key bypasses the cache" 2 $__t2_calls
functions --erase __tcz_thp_band_uncached
functions --copy __t2_band_real __tcz_thp_band_uncached

# -- leg: cols <key desc>... [--cachekey=X] --
# leg's uncached builder ALSO returns nonzero (status 1) whenever the pair
# count divides evenly into <cols> with no trailing partial row — proved
# live for the exact browsing-legend shape below (9 pairs / cols 3). Same
# and-chain hazard as tabstrip, plus a second hazard the brief's own key
# formula ran into: an odd/even PARITY test cannot tell "1 pair + a trailing
# key" apart from a genuinely malformed odd pair count with no key intended,
# and a pre-existing test ("leg guards odd pair count") already covers that
# malformed case — an unambiguous "--cachekey=X" sentinel is used instead.
set -g __t2_calls 0
functions --copy __tcz_thp_leg_uncached __t2_leg_real
function __tcz_thp_leg_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_leg_real $argv
end
__tcz_thp_cacheclear
set -g __t2_a (__t2_leg_real 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close | string escape)
set -g __t2_b (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close --cachekey=0 | string escape)
t "staticcache: leg cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close --cachekey=0 >/dev/null
t "staticcache: leg hit calls the builder zero times" 0 $__t2_calls
set -g __t2_calls 0
__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close >/dev/null
__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close >/dev/null
t "staticcache: leg omitting the key bypasses the cache" 2 $__t2_calls
# the pre-existing malformed-input guard must still work: an odd pair count
# with no --cachekey= sentinel is NOT mistaken for a keyed call.
t "staticcache: leg still guards a genuinely odd pair count" 0 (count (__tcz_thp_leg 3 a b c))
functions --erase __tcz_thp_leg_uncached
functions --copy __t2_leg_real __tcz_thp_leg_uncached

# -- cacheclear reaches every new __tcz_sc_ cache, not just some of them --
__tcz_thp_cacheclear
__tcz_thp_preview "$__t2_pal" '#f5f5f5' somehost Monitoring 50 k1 >/dev/null
__tcz_thp_tabstrip '#98b3a0' '#f5f5f5' my-session 50 k1 >/dev/null
__tcz_thp_seedzone 50 '#5f772b' 96 0.42 0.054 0 1 95 119 43 k1 >/dev/null
__tcz_thp_staterow 50 "$__t2_cells" 'mono soft' current 1 1 cur_1_1 >/dev/null
__tcz_thp_band '#444444' band >/dev/null
__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed m more z shake '⇥' current/off a apply '⏎' save esc close --cachekey=0 >/dev/null
t "staticcache: all six builders populate __tcz_sc_ entries" 6 (count (set --names | string match -er '^__tcz_sc_'))
__tcz_thp_cacheclear
t "staticcache: cacheclear erases every __tcz_sc_ entry" 0 (count (set --names | string match -er '^__tcz_sc_'))

# --- Task 3: the swatch-strip cache -----------------------------------------
# __tcz_thp_cells costs 5.4ms and is 96% of an uncached scheme row (5.6ms).
# After Task 1 it only runs for the two ROWS a cursor move leaves row-cache
# dirty (their <selected> changed, not their <hexes>) -- this task memoizes
# it too so those two rows stop paying the swatch-strip cost on every move.
# Same discriminator as Tasks 1/2: a call COUNT, not a grep.
set -g __t3_calls 0
functions --copy __tcz_thp_cells_uncached __t3_real
function __tcz_thp_cells_uncached
    set -g __t3_calls (math $__t3_calls + 1)
    __t3_real $argv
end
__tcz_thp_cacheclear
set -g __t3_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
set -g __t3_a (__t3_real "$__t3_pal" | string escape)
set -g __t3_b (__tcz_thp_cells "$__t3_pal" 3 | string escape)
set -g __t3_c (__tcz_thp_cells "$__t3_pal" 3 | string escape)
t "cellcache: cached matches uncached (miss)" "$__t3_a" "$__t3_b"
t "cellcache: cached matches uncached (hit)"  "$__t3_a" "$__t3_c"
set -g __t3_calls 0
__tcz_thp_cells "$__t3_pal" 3 >/dev/null
t "cellcache: a hit calls the builder zero times" 0 $__t3_calls
set -g __t3_calls 0
__tcz_thp_cells "$__t3_pal" >/dev/null
__tcz_thp_cells "$__t3_pal" >/dev/null
t "cellcache: omitting the key bypasses the cache" 2 $__t3_calls
# invalidation: clearing forces a rebuild (Task 1/2 convention)
__tcz_thp_cacheclear
set -g __t3_calls 0
__tcz_thp_cells "$__t3_pal" 3 >/dev/null
t "cellcache: cacheclear forces a rebuild" 1 $__t3_calls
# __tcz_thp_cacheclear's regex ('^__tcz_(?:cc|rc|sc)_') already anticipated a
# "cc" (cells cache) namespace before this task existed -- prove it actually
# reaches a real __tcz_cc_ entry rather than assuming the regex was right.
__tcz_thp_cacheclear
__tcz_thp_cells "$__t3_pal" 3 >/dev/null
t "cellcache: populates a __tcz_cc_ entry" 1 (count (set --names | string match -er '^__tcz_cc_'))
__tcz_thp_cacheclear
t "cellcache: cacheclear erases every __tcz_cc_ entry" 0 (count (set --names | string match -er '^__tcz_cc_'))
functions --erase __tcz_thp_cells_uncached
functions --copy __t3_real __tcz_thp_cells_uncached

# real call-site guard: __tcz_thp_row_uncached must pass its OWN <cachekey>
# straight through to __tcz_thp_cells -- a test that hand-builds a key and
# calls __tcz_thp_cells directly (all the cellcache: assertions above) cannot
# see whether the ACTUAL call site inside __tcz_thp_row_uncached does this
# (Task 2s review found exactly this class of gap: six correct wrappers,
# four call-site mutations that still passed every hand-keyed test). Two row
# calls at the SAME index but a DIFFERENT <selected> are both ROW-cache
# MISSES (Task 1 keys rows by index_selected_current), yet <hexes> for that
# index is unchanged, so the cells builder should still run only once.
# Proven live: reverting __tcz_thp_row_uncacheds call site to
# `__tcz_thp_cells "$hexes"` (dropping the key) makes this 2, with every
# cellcache: assertion above still ALL PASS.
set -g __t3_calls2 0
functions --copy __tcz_thp_cells_uncached __t3_real2
function __tcz_thp_cells_uncached
    set -g __t3_calls2 (math $__t3_calls2 + 1)
    __t3_real2 $argv
end
__tcz_thp_cacheclear
__tcz_thp_row "$__t3_pal" schemeA 0 0 7 >/dev/null
__tcz_thp_row "$__t3_pal" schemeA 1 0 7 >/dev/null
t "cellcache: row_uncached forwards its cachekey to cells (call-site guard)" 1 $__t3_calls2
functions --erase __tcz_thp_cells_uncached
functions --copy __t3_real2 __tcz_thp_cells_uncached

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
# picker-partial-repaint Task 2: the whole-frame emission (and this guard's
# subject matter) moved out of __tcz_theme_picker's own source and into
# __tcz_popup_emit, which both picker frames now call — see the "the picker
# routes BOTH its frames through the emitter" block below for the guard that
# no inline paint remains in the picker itself. Renamed emit: … (fix round,
# Minor 3) so the name matches the function this now actually checks.
t "emit: last row printed without newline" yes (string match -q '*$argv[1..-2]*' -- (functions __tcz_popup_emit | string collect); and echo yes; or echo no)
# readkey's ESC/CSI-arrow branch leaves the tty in `min 1 time 0` (blocking) on
# return, so each drain iteration must re-assert non-blocking BEFORE reading —
# otherwise the second buffered read blocks forever (empirically confirmed hang).
# NB this specific literal (a gap-less "stty min 0 time 0") used to live ONLY in
# the orphaned seed RGB-slider's ←→ drain (__tcz_thp_sliders, still defined but
# unreferenced pending Task 5) — a separate loop in a separate function from the
# ↑↓/pgup/pgdn drain below, which uses a variable gap ($gap) and has its own,
# differently-scoped pin further down ("picker drain re-asserts non-blocking
# inside the loop"). picker-seed-section Task 4 added a SECOND occurrence of the
# same gap-less shape — the in-frame edit mode's own ←→ channel-value drain,
# in the main dispatch rather than the (then still orphaned) popup screen —
# so the count moved 1->2. picker-legibility-autoapply Task 6 deletes
# __tcz_thp_sliders outright, taking its own gap-less drain with it, so the
# count moves back 2->1 — the survivor is the in-frame edit's drain, the
# only one left. This test used to be named as if it covered the
# ↑↓/pgup/pgdn drain; it never did — renamed to say what it actually checks
# rather than retired, since the gap-less-drain hang guard has no other
# cover. picker-responsiveness Task 4 adds a SECOND occurrence again — the
# edit-mode ↑↓ channel-select drain, which the defect report required to
# stay gap-less (no `gap 1` escalation, same reasoning as the ↑↓/pgup/pgdn
# arm's own arrow case just below) — so the count moves 1->2 once more.
t "picker gap-less drains re-assert non-blocking each iteration" 2 (string match -a -r 'while true(?=\n\s+stty min 0 time 0)' -- (functions __tcz_theme_picker | string collect) | count)
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
# picker-legibility-autoapply Task 6: "seed entry paints atomically" is
# retired, not retargeted. It pinned one literal printf shape — DECSET 2026
# immediately followed by cursor-home, a space, and the bold "seed" open —
# and its own comment claimed "both the hexentry and sliders screens share
# this exact opening." Verified false for hexentry even before this
# deletion: hexentry opens its DECSET separately (`printf
# '\e[?2026h\e[H'`) from its content, which is built line-by-line via
# `$helines`/`__tcz_thp_ln` (it grew a real border in picker-seed-section
# Task 5), so the combined literal never matched hexentry's source — only
# sliders' single big printf had this exact shape. With sliders gone, the
# pattern cannot appear anywhere in the picker again; keeping the assertion
# would just be a permanent, and now misleadingly-named, vacuous "no" ->
# rewritten to "yes" by deleting the check rather than the coverage it
# never actually had.

# --- RGB slider seed picker (Task 1): readchar tokens + slider row builder ---
t "thp_slider width fixed at 39" 39 (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)))
t "thp_slider width holds at extremes+selected" 78 (math (string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider G 0 1)))" + "(string length --visible -- (__tcz_strip_sgr (__tcz_thp_slider B 255 1))))
t "thp_slider gap cells at 0" 32 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 0 0)) | count)
t "thp_slider gap cells at 128" 16 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 128 0)) | count)
t "thp_slider gap cells at 255" 0 (string match -a -r '·' -- (__tcz_strip_sgr (__tcz_thp_slider R 255 0)) | count)
t "thp_slider selected carries ▌" yes (string match -q '*▌*' -- (__tcz_thp_slider R 10 1); and echo yes; or echo no)
t "readchar classifies arrows + t" yes (begin; set -l l (functions __tcz_thp_readchar | string collect); string match -q '*case 41; echo up*' -- $l; and string match -q '*case 44; echo left*' -- $l; and string match -q '*case 74; echo t*' -- $l; end; and echo yes; or echo no)
t "hex entry ignores the new tokens" yes (string match -q '*case hash other t up down left right*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# --- RGB slider seed picker (Task 2): slider screen, b reroute, hexentry extraction ---
# picker-seed-section Task 4 retires the reroute this test used to pin: b no
# longer opens a separate popup screen, it toggles the seedzone's own in-frame
# edit mode (see the "Task 4: edit mode" block further down). __tcz_thp_sliders
# stays defined but loses its only caller here — expected, not a defect, until
# Task 5 gives it (and __tcz_thp_hexentry, reachable only through it today)
# a new one.
t "sliders apply composes a hex" yes (string match -q '*#%02x%02x%02x*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)
t "hexentry erased on exit" yes (string match -q '*functions -e __tcz_thp_hexentry*' -- (functions __tcz_theme_picker | string collect); and echo yes; or echo no)

# --- Task 6: dead builders gone, active wired ---------------------------------
# picker-legibility-autoapply Task 6: __tcz_thp_sliders lost its only caller
# when picker-seed-section Task 4 moved seed editing in-frame, and
# __tcz_thp_seedrow lost its only consumer the same way — both are deleted
# outright here, along with the sliders teardown line. Two reachability
# greps that used to sit just above ("b no longer opens the old sliders
# screen", "sliders route t to the hex editor") are retired, not retargeted:
# once the function itself is gone, grepping for a call to it is checking
# for something that structurally cannot exist — a permanent vacuous truth,
# not a live guard. "sliders erased on exit" is retargeted above to just
# __tcz_thp_hexentry (the only seed screen left to tear down); "sliders
# apply composes a hex" survives unmodified — the in-frame edit's own commit
# (~:2553) uses the identical printf shape, so the pattern still exists in
# the picker body for a different reason now.
set -l catfile $plugindir/functions/tmux-categorize.fish
t "sliders builder is gone" 0 (string match -ra 'function __tcz_thp_sliders' -- (cat $catfile | string collect) | count)
t "seedrow builder is gone" 0 (string match -ra 'function __tcz_thp_seedrow' -- (cat $catfile | string collect) | count)
t "no teardown for the removed sliders" 0 (string match -ra 'functions -e __tcz_thp_sliders' -- (cat $catfile | string collect) | count)
# active earns its cell only now that something paints it.
set -g CELLS7 (__tcz_thp_cells '#010101 #020202 #030303 #040404 #050505 #060606 #070707')
t "cells is 16 visible cols once active is drawn" 16 (string length --visible -- "$CELLS7")
t "active (#040404) now appears" 1 (string match -ra '38;2;4;4;4' -- "$CELLS7" | count)

# Grep-guards: the v2 cap-picker cluster and the install-side v2 palette engine
# it called must both be fully gone from the categorizer file.
set -l catfile $plugindir/functions/tmux-categorize.fish
t "v2 cap cluster gone from the categorizer" 0 (grep -c '__tcz_cap_' $catfile)
t "categorizer no longer names the v2 palette" 0 (grep -c '__tmux_lives_palette' $catfile)
# INVERTED 2026-08-17. This guard used to REQUIRE `pgrep -P` as the non-Linux
# fallback. It is now banned outright: on macOS /usr/bin/pgrep links
# libsysmon.dylib and delegates to the /usr/libexec/sysmond ROOT DAEMON, which
# walks every process AND thread per call — ~4 of 14 cores on macwork, 0.4%
# idle. /bin/ps is libsysmon-clean, so the non-Linux path reads one shared ps
# snapshot instead. Both halves are pinned, because each alone is defeatable:
# pgrep absent from any CODE line, AND the fallback still present (the original
# guard existed to stop someone "fixing" this by deleting the branch entirely).
# Comments are stripped first — this file now discusses pgrep at length, and a
# guard that greps its own prose is the trap this repo keeps walking into.
set -l __t_code (grep -v '^\s*#' $catfile | string collect)
t "pgrep is gone from the categorizer (macOS sysmond storm)" 0 (printf '%s\n' "$__t_code" | grep -c 'pgrep')
t "__tcz_pid_children keeps a non-Linux fallback" 1 (awk '/^function __tcz_pid_children/,/^end$/' $catfile | grep -c '__tcz_ps_load')
# Bare CALL sites only — a loose match also counts __tcz_ps_loaded (the sentinel)
# and the function's own definition, which is how this first read 7 instead of 3.
t "the ps snapshot feeds at least the three pid helpers" 1 (test (printf '%s\n' "$__t_code" | grep -cE '^ +__tcz_ps_load$') -ge 3; and echo 1; or echo 0)
# STRUCTURAL, deliberately, because this one CANNOT be pinned behaviourally on
# Linux: GNU ps does not truncate when writing to a pipe, so dropping `ww` is a
# no-op here and green either way. On macOS BSD ps sets termwidth 79 whenever no
# ioctl(TIOCGWINSZ) succeeds — always, for a `#()` status hook — and truncates
# the LAST column. macOS `comm` is a full path, and pid+ppid spend 12 of those
# columns, leaving 67; the developer's own claude path is 65. Two characters of
# margin, and crossing it kills claude detection silently and totally. The
# repo's own __tcz_pid_environ already carried `eww` for exactly this reason.
t "both snapshots carry -ww (BSD truncates the last column at 79 cols)" 2 (printf '%s\n' "$__t_code" | grep -c 'ps -A -ww -o')
t "pid_environ keeps eww, not e"                                        1 (printf '%s\n' "$__t_code" | grep -c 'ps eww -p')

# tick-call-batching task 2: the three literal-keyed global reads must be
# GONE from the categorizer (routed through __tcz_tmux_global instead). The
# per-tty emit-cache read was deliberately left alone by task 2 (see
# __tcz_tmux_load's OLD comment, since rewritten) -- task 5 is the one that
# routes it too, see the two guards right after this block.
t "tab_color no longer calls show -gv @tmux_lives_tabs_color directly" 0 (printf '%s\n' "$__t_code" | grep -c 'show -gv @tmux_lives_tabs_color')
t "heal_due no longer calls show -gv @tmux_lives_heal_interval directly" 0 (printf '%s\n' "$__t_code" | grep -c 'show -gv @tmux_lives_heal_interval')
t "heal_due no longer calls show -gv @tmux_lives_heal_at directly" 0 (printf '%s\n' "$__t_code" | grep -c 'show -gv @tmux_lives_heal_at')
t "tab_color routes through __tcz_tmux_global" 1 (awk '/^function __tcz_tab_color/,/^end$/' $catfile | grep -c '__tcz_tmux_global tabs_color')
t "heal_due routes through __tcz_tmux_global" 2 (awk '/^function __tcz_heal_due/,/^end$/' $catfile | grep -c '__tcz_tmux_global')

# tick-call-batching task 5: the per-tty emit-cache read is now ALSO routed
# through the shared global memo (it was already inside __tcz_tmux_load's one
# `show -g`, per that function's own docstring -- task 2 just never wired a
# reader to it, pending this task's write-after-read audit). No more direct
# `show -gv @tmux_lives_emit_...` anywhere in the file.
t "the per-tty emit-cache read no longer calls show -gv directly" 0 (printf '%s\n' "$__t_code" | grep -c 'show -gv @tmux_lives_emit_')
t "emit_get routes through __tcz_tmux_global" 1 (awk '/^function __tcz_emit_get/,/^end$/' $catfile | grep -c '__tcz_tmux_global emit_')
# emit_set still WRITES tmux directly (a write can't be batched away — see the
# CLAUDE.md map, "2 writes, stay") AND write-throughs the same key into the
# memo so a later same-pass read (the staleness property) sees it.
t "emit_set still writes tmux directly" 1 (awk '/^function __tcz_emit_set/,/^end$/' $catfile | grep -c 'tmux set -g @tmux_lives_emit_')
t "emit_set write-throughs the memo entry for the same key it just wrote" 1 (awk '/^function __tcz_emit_set/,/^end$/' $catfile | grep -c 'set -g __tcz_tmux_g_emit_')
t "__tcz_main flushes both the ps and tmux tables, in order" yes (string match -qr '(?s)__tcz_ps_flush\s*\n\s*__tcz_tmux_flush' -- "$__t_code"; and echo yes; or echo no)
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
# picker-partial-repaint Task 2: same relocation as the guard above — the
# sync-output wrapping now lives in __tcz_popup_emit, which the picker calls
# for both its frames instead of writing the escapes itself. Fix round
# (Minor 4): a match-ANYWHERE check is satisfiable by only ONE of the
# emitter's two paint paths wrapping in sync — e.g. stripping the sync
# escapes from the partial-diff path alone still leaves a 2026h/2026l pair
# in the whole-frame fallback, and the old check would stay green.
# __tcz_popup_emit has exactly one 2026h/2026l PAIR per path (whole-frame
# and partial-diff), so requiring count 2 of each — not merely >=1 — is what
# actually proves both paths are covered independently. Renamed emit: …
# (Minor 3) to match the function this now checks.
set -g __t10b_emitlines (string split \n -- (functions __tcz_popup_emit | string match -rv '^\s*#' | string collect))
t "emit: both paint paths wrap in synchronized output (2026h)" 2 (string match -r '2026h' -- $__t10b_emitlines | count)
t "emit: both paint paths wrap in synchronized output (2026l)" 2 (string match -r '2026l' -- $__t10b_emitlines | count)

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
# picker-legibility-autoapply Task 5: case a's three apply-preview sites moved
# verbatim into __tcz_thp_apply_now (shared with the settle-timeout auto-
# apply — same text, same count, just relocated), and the A toggle added ONE
# new site (the set -U write). Net +1 = 8 -> 9. drop-autoapply-debounce-seed
# Task 1 removed the A toggle and its write site outright (not merely the
# settle-timeout caller — the toggle itself is gone). Net -1 = 9 -> 8.
# tick-call-batching task 2 review fix: the 4 write-then-recolor sites
# (a-current, a-off, a-list, esc-revert) moved OUT of __tcz_theme_picker's own
# body into a shared top-level helper, __tcz_thp_apply_and_recolor, so the
# flush this fix needed (a write from a fish -c CHILD is invisible to the
# picker's own __tcz_tmux_load memo, which never re-fires across the picker's
# one long-lived while-true pass) lives in exactly one place instead of four.
# 8 -> 4 remaining directly in $pbody (init + seed-commit-on-save + 2 saves);
# the other 4 are now pinned separately, against the helper's OWN body, below.
t "guard: exactly 4 action-site subprocesses remain directly in the picker body" 4 (count (string match -ar 'fish -c' -- "$pbody"))
# 4 = init + seed-commit-on-save + 2 saves
set -l aarbody (awk '/^function __tcz_thp_apply_and_recolor/,/^end$/' $catfile | string collect)
t "guard: apply_and_recolor body extraction is non-empty" 1 (test -n "$aarbody"; and echo 1; or echo 0)
t "guard: apply_and_recolor is exactly one action-site subprocess (the 4 old sites share it)" 1 (count (string match -ar 'fish -c' -- "$aarbody"))
t "guard: apply_and_recolor flushes the tmux memo right after its write, not before" yes (string match -qr '(?s)fish -c[^\n]*\n\s*__tcz_tmux_flush' -- "$aarbody"; and echo yes; or echo no)
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
# loses an arg. picker-seed-section Task 6 briefly added a third call (a
# direct per-keystroke recompute in case left/right); drop-autoapply-
# debounce-seed Task 2 removed it outright — a channel keypress now costs
# zero palette calls — so the count below is back to 2.
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
# picker-legibility-autoapply Task 4: the footer is now built via TWO
# __tcz_thp_leg calls, branched on $editing (idle/editing) — this block used
# to assume a single call. Isolate the idle-branch line (the only one that
# still names more/shake/place/mode) via a marker unique to it, so the rest
# of this block keeps testing exactly what it always tested; the editing
# branch's own content is asserted against the rendered frame further down
# (LEGI/LEGE).
set -l leglinesall (string match -ra -- "__tcz_thp_leg .*" $pbody)
t "legend is built via two __tcz_thp_leg calls (idle/editing)" 2 (count $leglinesall)
# Isolate via `shake` rather than the old `more` marker: picker-responsiveness-
# and-layout Task 7 renamed the idle branch's `m` pair to `curated` (m now
# collapses to the curated 14 by default; the picker opens on the full 35),
# so `more` no longer appears anywhere in the idle line. `shake` is untouched
# by that rename and still unique to the idle branch (absent from editing's).
set -l leglines (string match -r -- '.*shake.*' $leglinesall)
t "idle legend line isolated for the checks below" 1 (count $leglines)
# Gallery rewrite Task 4: place/mode are no longer knobs, so the legend no
# longer names them (m was repurposed to expand, then Task 7 flipped the
# default to open expanded and repurposed m again, to collapse — see
# "legend names curated").
t "legend drops place" 0 (string match -q '*place*' -- $leglines; and echo 1; or echo 0)
t "legend drops mode"  0 (string match -q '*mode*'  -- $leglines; and echo 1; or echo 0)
t "legend names curated" 1 (string match -q '*curated*' -- $leglines; and echo 1; or echo 0)
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
# SUPERSEDED by picker-legibility-autoapply Task 3, immediately below: the FIXED
# 8-row design (both states padded to 8 so the scheme list never shifted) is what
# the user reviewed live and rejected in favor of a compact idle zone (more
# schemes on screen) and a roomy edit zone (real slider breathing room), accepting
# that the list moves when you press b. `seedzone exists` survives unchanged
# (a bare existence check); everything else here is replaced by the row-inventory
# tests below.
t "seedzone exists" 0 (functions -q __tcz_thp_seedzone; echo $status)

# --- picker-responsiveness-and-layout Task 6: the seed zone is 4 rows idle,
# 9 editing (up from 3/8 — the colour block itself grew 2 -> 3 rows so the
# hex could move off the block's right side and into its own centre) -------
set -g SZI (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 0 1 95 119 43)
set -g SZE (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 1 95 119 43)
t "seedzone idle is 4 rows" 4 (count $SZI)
t "seedzone editing is 9 rows" 9 (count $SZE)
for i in (seq 4)
    set -l v (__tcz_strip_sgr "$SZI[$i]")
    t "idle row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
for i in (seq 9)
    set -l v (__tcz_strip_sgr "$SZE[$i]")
    t "editing row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
# Rows 1-4 are identical between states: only the slider block appears.
t "rows 1-4 are identical in both states" 1 (test "$SZI[1]$SZI[2]$SZI[3]$SZI[4]" = "$SZE[1]$SZE[2]$SZE[3]$SZE[4]"; and echo 1; or echo 0)
t "idle shows the hex" 1 (string match -q '*5f772b*' -- (string join ' ' $SZI); and echo 1; or echo 0)
t "idle shows the readouts beside it" 1 (string match -q '*hue*' -- (string join ' ' $SZI); and echo 1; or echo 0)
t "the retired copy is gone" 0 (string match -ra 'rendered as-is' -- (string join ' ' $SZE) | count)
# The hex renders INSIDE the middle block row (row 3 of the zone), not beside
# it: stripped of SGR, it must be preceded by only the block's own left
# padding (<=3 cols of whitespace after the border), not by the whole 12-col
# block plus a gap the way the old (row 2) placement was.
set -g SZI3 (__tcz_strip_sgr "$SZI[3]")
t "seedzone: the hex sits inside the block" 1 (string match -qr '^.\s{0,3}#5f772b' -- "$SZI3"; and echo 1; or echo 0)

# --- Task 6 fix round (review I1): the placement check above passed
# unchanged through three real mutations that each broke the actual point of
# this task — a dropped contrast fg (m2: hex silently renders in the
# terminal's default foreground on the seed background, the exact
# unreadable-at-a-mid-tone-seed case this task exists to prevent), a
# flush-left hex (m5: centring destroyed), and a dropped $bg reassertion
# after the hex (m6: the block's right pad loses its fill, a visible notch).
# All three left the full categorize suite at 961 ok / 0 FAIL. These three
# groups pin each property directly, each mutation-proven below to fail
# against its corresponding assertion(s) and pass against the other two —
# not just "some assertion somewhere fails."
#
# (1) the fg itself: a dark and a light seed must each show __tmux_lives_
# contrast_fg's own SGR immediately before the hex text (not just present
# somewhere in the row), and the two must differ. #1a1a2e/#f0e6d2 are
# comfortably on opposite sides of contrast_fg's WCAG crossover (0.179),
# so this is not a near-boundary pick that could flip on a rounding change.
set -g SZDARK (__tcz_thp_seedzone 50 '#1a1a2e' 250 0.15 0.05 0 1 26 26 46)
set -g SZLIGHT (__tcz_thp_seedzone 50 '#f0e6d2' 60 0.90 0.05 0 1 240 230 210)
set -g SZDARKFG (string match -rg '\e\[38;2;([0-9]+;[0-9]+;[0-9]+)m#1a1a2e' -- "$SZDARK[3]")
set -g SZLIGHTFG (string match -rg '\e\[38;2;([0-9]+;[0-9]+;[0-9]+)m#f0e6d2' -- "$SZLIGHT[3]")
t "seedzone: dark-seed fg extraction is non-empty" 1 (test -n "$SZDARKFG"; and echo 1; or echo 0)
t "seedzone: light-seed fg extraction is non-empty" 1 (test -n "$SZLIGHTFG"; and echo 1; or echo 0)
t "seedzone: dark seed's hex fg is 245;245;245 (contrast_fg's light value)" "245;245;245" "$SZDARKFG"
t "seedzone: light seed's hex fg is 17;17;17 (contrast_fg's dark value)" "17;17;17" "$SZLIGHTFG"
t "seedzone: dark and light hex fg colours differ" 1 (test "$SZDARKFG" != "$SZLIGHTFG"; and echo 1; or echo 0)
# (2) exact centring: the 12-col block interior, char for char, not just
# "somewhere in 0-3 leading cols" the way the placement check above allows.
set -g SZI3BLOCK (string sub -s 2 -l 12 -- "$SZI3")
t "seedzone: the 12-col block interior is exactly 2sp + hex + 3sp (centred)" "  #5f772b   " "$SZI3BLOCK"
# (3) the block's own background is RE-asserted after the hex's reset, so
# the trailing pad stays filled rather than reverting to the terminal
# default — counted in the RAW (un-stripped) row since stripping SGR would
# make a filled and an unfilled trailing pad look identical.
t "seedzone: the block's own background is reasserted after the hex (no notch in the right pad)" 2 (count (string match -ra '48;2;95;119;43' -- "$SZI[3]"))

# Blank rows surround the slider group and none divides it.
set -g SZE5 (__tcz_strip_sgr "$SZE[5]"); set -g SZE9 (__tcz_strip_sgr "$SZE[9]")
t "row 5 is blank" 1 (string match -qr '^│ *│$' -- "$SZE5"; and echo 1; or echo 0)
t "row 9 is blank" 1 (string match -qr '^│ *│$' -- "$SZE9"; and echo 1; or echo 0)
t "rows 6-8 all carry a channel bar" 3 (count (string match -ra 'R|G|B' -- (string join \n $SZE[6..8])))
# The selected channel tracks chan.
set -g SZC2 (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 2 95 119 43)
t "chan=1 marks row 6, not row 7" 1 (test "$SZE[6]" != "$SZC2[6]" -a "$SZE[7]" != "$SZC2[7]"; and echo 1; or echo 0)

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
# cannot be satisfied by deleting the calls outright. picker-seed-section
# Task 6's third (case left/right's direct per-keystroke recompute) is gone
# again — drop-autoapply-debounce-seed Task 2 removed it, back to 2.
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
# staticcache: the rendering logic lives in __tcz_thp_preview_uncached now,
# not __tcz_thp_preview (the memoizing front) — but review M-4 caught that
# inspecting ONLY _uncached would let a stray "coral" reappear in the 8-line
# wrapper itself and go unseen. Concatenate both bodies: the coral-absence
# check still means what it says for either function, and the claude-segment
# substring search below is unaffected either way (it's a plain substring
# match, not an exact-body comparison, so the wrapper's own text can't hide
# or fake a match).
set -l pvbody (functions __tcz_thp_preview __tcz_thp_preview_uncached | string collect)
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

# picker wiring: the footer is __tcz_thp_leg 3-col calls (9 pairs idle —
# picker-legibility-autoapply Task 5 briefly grew this to 10 with A auto;
# drop-autoapply-debounce-seed Task 1 removed that pair),
# not two fixed-pitch __tcz_legend_row calls — supersedes the pre-gallery-
# refinement assertions below that grepped for the old call pattern.
# picker-legibility-autoapply Task 4 split this into TWO calls branched on
# $editing; isolate the idle-branch one (the only one the checks below were
# ever about) the same way the $pbody block above does.
set -l pbody2 (functions __tcz_theme_picker | string collect)
set -l leggridall (string match -ra -- "__tcz_thp_leg 3 .*" $pbody2)
t "picker legend is built via two __tcz_thp_leg 3-col calls (idle/editing)" 2 (count $leggridall)
set -l leggrid (string match -r -- '.*shake.*' $leggridall)
t "picker legend (idle branch) is a __tcz_thp_leg 3-col call" 1 (count $leggrid)
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
# picker-responsiveness-and-layout Task 7: m's label moved more -> curated
# (the picker now opens expanded; m collapses to the curated 14).
t "picker legend names curated"     1 (string match -q '*curated*' -- "$leggrid"; and echo 1; or echo 0)
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
# picker-legibility-autoapply Task 4: the __tcz_thp_leg call(s) now feed a
# $leglines var branched on $editing, rather than being wrapped in the for
# loop's own command substitution directly — match from the for loop that
# consumes $leglines through the thp_ln emission, not from __tcz_thp_leg
# itself (which the leggrid/leglines checks above already cover).
t "legend rows are frame-enclosed (thp_ln)" 1 (string match -qr '(?s)for lline in \$leglines.*set -a lines \(__tcz_thp_ln "\$lline" \$IW \$BORDER \$RST\)' -- "$pk2"; and echo 1; or echo 0)
set -l allsetlines (string match -ar 'set -a lines.*' -- "$pk2")
t "bottom border is the last emitted line" 1 (string match -q '*╰*' -- "$allsetlines[-1]"; and echo 1; or echo 0)

# --- configuration zone: seedrow flash affordance (RETIRED) ---
# This section used to unit-test __tcz_thp_seedrow directly — an uppercase
# "SEED" label beside its value, flashing when flagged. Per the "layout
# history" note just below, that design was already superseded by
# picker-seed-section Task 3's __tcz_thp_seedzone (lowercase 'seed'
# separator, no label on the readout row) — seedrow kept being unit-tested
# in isolation even though nothing in __tcz_theme_picker called it anymore.
# picker-legibility-autoapply Task 6 deletes the orphaned builder outright,
# which retires this block with it.

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
# TWO times in this function's source (picker-legibility-autoapply Task 6
# deleted __tcz_thp_sliders' own "case enter" arm — a third occurrence,
# pre-deletion) — once in the real dispatch, once more in the nested
# `function ... end` DEFINITION earlier in the body (__tcz_thp_hexentry's
# seed-entry loop) — so a bare substring search can still latch onto the
# wrong one; (2) "focus = state" already
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
# picker-legibility-autoapply Task 5 moved this whole apply-preview body OUT
# of case a and into __tcz_thp_apply_now (originally shared with the
# settle-timeout auto-apply so the two paths could not drift apart;
# drop-autoapply-debounce-seed Task 1 removed the auto-apply caller and
# kept apply_now, renamed, as case a's sole body) — case a is now a
# one-line call site and no longer contains any of this logic. Bound to the
# function's own body instead of the old case-a block.
set -l aabody (string match -r '(?s)function __tcz_thp_apply_now.*?\n    end' -- "$PK3" | string collect)
t "apply_now body extraction is non-empty" 1 (test -n "$aabody"; and echo 1; or echo 0)
# final review (M1): the only existing __tcz_recolor guard (further down this
# file) greps the WHOLE picker body, so it stays green even with all three
# calls inside THIS function deleted — case cancel's own __tcz_recolor call
# satisfies it regardless. Scoped to aabody instead of the whole picker body.
# tick-call-batching task 2 review fix: the literal `and __tcz_recolor
# "$tabhex"` shape this used to match moved OUT of apply_now entirely, into
# the shared __tcz_thp_apply_and_recolor helper (so the flush the fix needed
# lives in one place, not four) — apply_now's own body now only ever CALLS
# that helper, once per branch, so the guard is scoped to counting those
# call sites instead of the (now relocated) recolor shape. Still bound to
# `bare call, not the --description text` the same way the old guard was:
# a plain substring count would also match the function's own docstring,
# which names __tcz_thp_apply_and_recolor too.
t "apply_now calls __tcz_thp_apply_and_recolor once per branch (current/off/scheme) — scoped to this function, not the whole picker body" 3 (count (string match -ar '^ +__tcz_thp_apply_and_recolor ' -- (string split \n -- "$aabody")))
# Bounded to the current-row branch alone (the sel2 -eq 0 arm) so a fix that
# flips the WRONG branch to previewed 2 can't pass by coincidence.
set -l currowblock (string match -r '(?ms)sel2 -eq 0\b.*?else\b' -- "$aabody" | string collect)
t "current-row preview sets previewed 2"           1 (string match -q '*set previewed 2*' -- "$currowblock"; and echo 1; or echo 0)
t "current-row preview no longer sets previewed 1" 0 (string match -q '*set previewed 1*' -- "$currowblock"; and echo 1; or echo 0)
# the off row and the listed-scheme branch both still set previewed 1 —
# exactly twice across the whole function now that the current row moved
# to 2 (regression guard: the two OTHER sites must stay put).
set -l applyarm $aabody
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
# left the walk entirely, not just n+1); the palette call-site count is back
# to 2 (picker-seed-section Task 6's direct per-keystroke call in case
# left/right is gone again — drop-autoapply-debounce-seed Task 2; arity is
# pinned separately by the per-call arg-count loop at ~line 1654).
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
# tick-call-batching task 2 review fix: the live-preview shadow, all three
# case-a call sites' shared shadow, and cancel's restore-by-shadow all moved
# OUT of __tcz_theme_picker's own body ($SLB, still used above/below for
# other checks) into the shared top-level helper __tcz_thp_apply_and_recolor
# — extracted fresh from source, since $SLB no longer contains any of this.
set -l aarbody2 (awk '/^function __tcz_thp_apply_and_recolor/,/^end$/' $catfile | string collect)
# live preview shadows the universal in the child rather than writing it
t "preview shadows the seed in the child" 1 (string match -q '*set -g tmux_lives_bar_color*' -- "$aarbody2"; and echo 1; or echo 0)
# The old "three case-a sites each shadow" count doesn't translate directly:
# there is now exactly ONE shadow site (the helper just checked above),
# shared by three call sites in apply_now — already pinned above by "apply_now
# calls __tcz_thp_apply_and_recolor once per branch", 3. Both halves of the
# original guarantee (one shadow mechanism; three branches wired to it) are
# still each pinned, just against the two functions separately now.
set -l cancelblock (string match -r '(?ms)^ *case cancel$.*?^ *end$' -- "$SLB" | string collect)
t "cancel restores by shadowing the anchor seed" 1 (string match -q '*__tcz_thp_apply_and_recolor "$anch_seed"*' -- "$cancelblock"; and echo 1; or echo 0)
# saving commits the seed — exactly once, in the EXIT path, never in a seed
# screen. awk scopes the seed screen out first (a NESTED function indented 4
# spaces — verified non-empty below rather than trusted blind); the commit
# call must survive only outside it.
#
# picker-legibility-autoapply Task 6: this used to scope out BOTH seed
# screens via two awk ranges concatenated in one command substitution
# (sliders' range first, unpiped; hexentry's range second, piped through
# `string collect`) — SEEDSCREENS, plural. Deleting __tcz_thp_sliders makes
# its awk range match nothing, so left as it was the variable would have
# silently shrunk to the hexentry body alone: still non-empty (the
# "extraction is non-empty" guard below cannot see a range that starts
# matching zero lines instead of failing outright), and the "no setup-color
# commit" guard would keep passing for a reason that no longer has anything
# to do with sliders. Rather than let coverage quietly halve under an
# unchanged name, this is re-scoped to hexentry only (the one seed screen
# left) and renamed singular to say so honestly.
set -g SEEDSCREEN (awk '/^    function __tcz_thp_hexentry/,/^    end$/' $catfile | string collect)
t "seed-screen extraction is non-empty (hexentry)" 1 (test (string length -- "$SEEDSCREEN") -gt 0; and echo 1; or echo 0)
t "no setup-color commit inside the seed screen" 0 (count (string match -ra 'setup color' -- "$SEEDSCREEN"))
# NB the brief's whole-body version of this check ("seed screens do not run
# setup color", asserted 0 against $SLB rather than $SEEDSCREEN) is
# self-contradictory with the very next test below once the exit-path commit
# exists — $SLB legitimately contains exactly one "setup color" after this
# fix, not zero. Dropped in favor of the two SEEDSCREEN-scoped checks above,
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
# picker-legibility-autoapply Task 6: the pre-existing "2" here was NOT "one
# match per screen" the way the old name implied — verified directly. The
# consuming pattern (reload, a literal embedded \n, then reanchor) makes
# each match itself span two lines; `count` on a captured `string match`
# doesn't count matches, it counts LINES in the captured output (fish's
# command substitution splits on newlines), so hexentry's one real pairing
# was already being counted as 2 on its own — and sliders' own identical
# pairing counted as 0, because the old $SEEDSCREENS concatenated sliders'
# half WITHOUT `string collect`, leaving it a list of individual lines with
# no embedded newline for a multi-line pattern to span. Two independent
# quirks landing on the same number by coincidence. Rewritten with a
# zero-width lookahead (matching the gap-less-drain guard's own technique
# above) so the match text stays single-line and `count` means what it
# says: exactly the one real pairing hexentry has.
t "the seed screen reanchors immediately after reload" 1 (count (string match -ar '__tcz_thp_reload(?=\n\s*__tcz_thp_reanchor)' -- "$SEEDSCREEN"))
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
# "picker legend (idle branch) is a __tcz_thp_leg 3-col call" (the legend-cols
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

# review finding 2: STATIC (the frame's static-row budget, "set -l STATIC 21")
# lives ABOVE the DRAWTEXT9 extraction range (it feeds WIN once, before the
# redraw loop DRAWTEXT9 is lifted from), so the harness restated its value as
# a bare literal instead of reading it — `grep STATIC tests/*.fish` finds it
# only in comments/docstrings. Mutation-proven: `set -l STATIC 20` in the real
# source left the whole categorize suite ALL PASS, while a real popup at that
# mutation overflows its own height by one row (the 2026-07-14
# top-border-scroll defect, exactly). Read the real value out of the function
# instead of restating it. The non-empty guard is mandatory: a missed
# extraction would silently make WIN — and every frame assertion below —
# garbage rather than merely wrong.
#
# picker-legibility-autoapply Task 3: the seed zone (3 rows idle, 8 editing —
# see __tcz_thp_seedzone above) makes the static budget MODE-DEPENDENT, so a
# single STATIC no longer describes the source. Extended from one extraction
# to two rather than rebuilt: the mechanism (read the real declaration out of
# the function, guard it non-empty, derive WIN from it inside
# __t9_frame_rows) is unchanged. picker-responsiveness-and-layout Task 6 grew
# the seed zone by one more row (3 -> 4 idle, 8 -> 9 editing — the colour
# block itself grew 2 -> 3 rows so the hex could move off the block's right
# side and into its own centre), moving STATIC_IDLE 16 -> 17 and STATIC_EDIT
# 21 -> 22 again — same numbers Task 5 briefly used, for an unrelated reason.
set -g STATIC9I (string match -rg 'set -l STATIC_IDLE (\d+)' -- "$SLB")
set -g STATIC9E (string match -rg 'set -l STATIC_EDIT (\d+)' -- "$SLB")
t "STATIC_IDLE extraction is non-empty" 1 (test -n "$STATIC9I"; and echo 1; or echo 0)
t "STATIC_EDIT extraction is non-empty" 1 (test -n "$STATIC9E"; and echo 1; or echo 0)
t "idle static is 17" 17 "$STATIC9I"
t "editing static is 22" 22 "$STATIC9E"

# Entering edit mode costs 5 window rows. A selection near the bottom of the
# expanded catalog must stay VISIBLE, and sel itself must not be moved to
# achieve it — the window scrolls, the cursor does not.
# window <sel> <total> <winsize> -> "<start> <count>"
set -g WI (string split ' ' -- (__tcz_thp_window 30 36 (math "52 - $STATIC9I")))
set -g WE (string split ' ' -- (__tcz_thp_window 30 36 (math "52 - $STATIC9E")))
t "idle window keeps sel=30 visible"    1 (test 30 -ge $WI[1] -a 30 -lt (math "$WI[1] + $WI[2]"); and echo 1; or echo 0)
t "editing window keeps sel=30 visible" 1 (test 30 -ge $WE[1] -a 30 -lt (math "$WE[1] + $WE[2]"); and echo 1; or echo 0)
t "the two windows differ (the zone really costs rows)" 1 (test "$WI[2]" != "$WE[2]"; and echo 1; or echo 0)

# --- picker-legibility-autoapply Task 3, review fix round: the open-time floor
# must guard BOTH modes, not just the one the picker opens in --------------
# Gating on STATIC_IDLE alone admits rows 19-20 (idle's WIN is comfortably >=3
# there), but pressing b immediately recomputes WIN against STATIC_EDIT and
# goes negative — the window and padding math both collapse and the frame
# overflows a 19- or 20-row popup, scrolling its own top border away. The
# real fix has to be read out of the source, not re-implemented: extract the
# real floor-check block (BEGIN/END floor-check) and eval it with rows/
# STATIC_IDLE/STATIC_EDIT seeded from the STATIC9I/STATIC9E extraction above,
# for real popup heights.
set -g FLOORBLOCK9 (string match -r '# BEGIN floor-check(.|\n)*?# END floor-check' -- "$SLB" | string collect)
t "floor-check extraction is non-empty" 1 (test -n "$FLOORBLOCK9"; and echo 1; or echo 0)
function __t9_floor --argument-names rows --description 'eval the REAL open-time floor-check block (BEGIN/END floor-check, extracted from __tcz_theme_picker) against the given popup height, with STATIC_IDLE/STATIC_EDIT seeded from the real STATIC9I/STATIC9E source extraction. saved is seeded empty (stty "" 2>/dev/null errors quietly to /dev/null — harmless, since only the admit/reject signal matters, not the terminal-restore side effect). The evald block itself is stdout-redirected to /dev/null so its own "window too short" printf (a real, intentional side effect of the reject path) does not leak into the captured result — only the echo below, OUTSIDE the redirected eval, is what the caller sees. Prints "admit" if the block falls through (the picker would open); prints nothing if it return 0s (the picker would refuse to open, exactly like the real too-short bail) — a bare `return` inside an evald block returns from the enclosing function, same as if it were written here directly.'
    set -l saved ''
    set -l STATIC_IDLE $STATIC9I
    set -l STATIC_EDIT $STATIC9E
    eval $FLOORBLOCK9 >/dev/null
    echo admit
end
# The direct discriminator: at rows 19/20/23 the OLD (STATIC_IDLE-only) gate
# admits, which is the bug — pressing b at those sizes then overflows.
# picker-legibility-autoapply Task 5 briefly moved STATIC_EDIT 21 -> 22 (the
# extra legend row for A auto), which moved the floor to rows 25.
# drop-autoapply-debounce-seed Task 1 removed that pair and put STATIC_EDIT
# back to 21, restoring the pre-Task-5 threshold: rows 24 (STATIC_EDIT + 3)
# was the admitted floor once more, one row lower than the Task-5 threshold.
# picker-responsiveness-and-layout Task 6 grows STATIC_EDIT 21 -> 22 again —
# same new number as Task 5's, but for an unrelated reason (a third
# seed-block row, not a legend pair) — moving the floor back to 25: rows 24
# now REJECTS (it used to be the admitted floor) and 25 is admitted instead.
t "floor: rows 19 is rejected (below STATIC_EDIT + 3)" '' (__t9_floor 19)
t "floor: rows 20 is rejected (below STATIC_EDIT + 3)" '' (__t9_floor 20)
t "floor: rows 23 is rejected (below STATIC_EDIT + 3)" '' (__t9_floor 23)
t "floor: rows 24 is rejected (below STATIC_EDIT + 3, Task 6 raised the floor 24 -> 25)" '' (__t9_floor 24)
t "floor: rows 25 is admitted (Task 6 raised the floor 24 -> 25)" admit (__t9_floor 25)

function __t9_frame_rows --argument-names focus sel2 n sel previewed anch_scheme anchpal flashfield expanded ndefault rows editing chan notearg --description 'eval the REAL draw block against a given picker state; returns the row count it produced. flashfield is included for completeness (it guards color/timing of the read AFTER the draw, not row count) rather than because this range reads it today. expanded/ndefault are Task 8 additions (More Schemes header + virtual-row window); omitted by pre-Task-8 callers, which leaves them empty and reproduces the pre-header behavior exactly. picker-seed-section Task 1: rows is the popup height WIN is derived from; defaults to 26 (todays fixed size) when omitted, so every pre-Task-1 caller keeps pinning exactly what it always has. picker-legibility-autoapply Task 3: WIN = rows - STATIC_IDLE or STATIC_EDIT depending on <editing>, matching the real function, both read out of it rather than restated — see STATIC9I/STATIC9E above. review finding 3: editing/chan (default 0/1, idle/R) are the seed-zones own edit-mode state, passed positionally to __tcz_thp_seedzone inside DRAWTEXT9 — every pre-finding-3 caller omits them and gets the same idle default the real picker opens in, so nothing here drifts for them. final review (I1): notearg is a trailing addition — empty/omitted reproduces every earlier callers own hardcoded "a note" exactly — that lets a caller feed the draw blocks REAL note-row line (__tcz_thp_ln " $MUTED$note$RST" ...) an arbitrary string, to prove the I1 truncation fix structurally caps it rather than trusting todays wording to stay short.'
    # Task 1's row cache is keyed by index alone, and this harness reuses the
    # same indices across states with different synthetic palettes/selection —
    # clear it first so no state sees a row memoized by an earlier one.
    __tcz_thp_cacheclear
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l IW 50
    test -n "$rows"; or set rows 26
    test -n "$editing"; or set editing 0
    test -n "$chan"; or set chan 1
    set -l static9 $STATIC9I
    test "$editing" = 1; and set static9 $STATIC9E
    set -l WIN (math "$rows - $static9")
    set -l host somehost
    set -l chiptitle ''
    set -l note 'a note'
    test -n "$notearg"; and set note $notearg
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
    # picker-legibility-autoapply Task 4: leglines is the real draw block's own
    # legend-row array (set leglines (…) / set -a leglines … inside DRAWTEXT9,
    # branched on $editing) — exposed the same way $lines already is, so the
    # legend's padded row count can be asserted against what the real function
    # actually produced rather than a second, independent __tcz_thp_leg call.
    set -g __t9_last_leglines $leglines
    count $lines
end

function __t9_frame_text --description 'same eval as __t9_frame_rows, but returns the rendered rows so CONTENT can be asserted, not just the row count'
    __t9_frame_rows $argv >/dev/null
    printf '%s\n' $__t9_last_lines
end

# --- review I-1: a NO-CACHECLEAR draw harness, for two-frame walks -----------
# __t9_frame_rows clears the cache at the top of every call, which is correct
# for the isolation it was built for (many synthetic states reusing the same
# scheme-row INDICES) but also means it can never observe a STALE cache
# entry surviving from a previous redraw within the same reload-generation —
# exactly the failure mode of three of the six draw-block cache keys
# (__tcz_thp_preview/tabstrip's curidx, __tcz_thp_seedzone's seedkey, and
# __tcz_thp_leg's --cachekey= sentinel), none of which any existing
# single-frame assertion could catch: verified by mutating each call site in
# turn and confirming the full pre-I-1 suite (922 assertions) stayed ALL
# PASS. __t9_draw_nocc is __t9_frame_rows with that one line removed — same
# body otherwise, same STATIC9I/STATIC9E/DRAWTEXT9 sourcing, same
# $__t9_last_lines/$__t9_last_leglines side globals — plus a trailing
# <seedarg> (default #5f772b, matching every pre-I-1 callers hardcoded seed)
# so the seedkey guard can vary the colour a genuine channel drag would
# produce; every other positional keeps __t9_frame_rows own defaulting
# exactly.
function __t9_draw_nocc --argument-names focus sel2 n sel previewed anch_scheme anchpal flashfield expanded ndefault rows editing chan notearg seedarg
    # review M-3: this local-scope setup is a SECOND, independent copy of
    # __t9_frame_rows's own (this one adds only <seedarg> and drops the
    # __tcz_thp_cacheclear call). Nothing ties them together — a future task
    # that adds a local the real draw block (DRAWTEXT9) reads must update
    # BOTH functions by hand, or this one silently evals against a stale
    # scope and gives a confidently-wrong reading with no signal.
    set -l BORDER (__tcz_theme border)
    set -l BRAND (__tcz_theme brand)
    set -l KEY (__tcz_theme key)
    set -l MUTED (__tcz_theme muted)
    set -l SELBG (__tcz_theme sel-bg)
    set -l RST (__tcz_theme reset)
    set -l IW 50
    test -n "$rows"; or set rows 26
    test -n "$editing"; or set editing 0
    test -n "$chan"; or set chan 1
    set -l static9 $STATIC9I
    test "$editing" = 1; and set static9 $STATIC9E
    set -l WIN (math "$rows - $static9")
    set -l host somehost
    set -l chiptitle ''
    set -l note 'a note'
    test -n "$notearg"; and set note $notearg
    set -l seed '#5f772b'
    test -n "$seedarg"; and set seed $seedarg
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
    set -g __t9_last_leglines $leglines
    count $lines
end
function __t9_draw_nocc_text --description 'same as __t9_frame_text, but via __t9_draw_nocc (no cacheclear) -- for I-1s two-frame walks'
    __t9_draw_nocc $argv >/dev/null
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

# --- final review (I1): the note row is structurally incapable of overflowing --
# Reproduced pre-fix: with the OLD "(current)" wording, __tcz_thp_ln pads short
# content but never truncates long content, so previewing `current` at a
# 5-letter relationship (wheat/amber/ember/coral) drew a 51-visible-column note
# (leading space included) into a 50-column frame -- 53 cols total including both
# borders, one past the popup's 52 -- which wraps and scrolls the top border off
# screen. Fixed two ways: the wording was shortened ("(current)" -> "(live)", so
# every real relationship name now fits with margin) AND the draw site itself now
# truncates via __tcz_popup_truncate, so no note -- not just today's -- can ever
# push the row past IW. Proven here directly against the REAL draw block with a
# note far longer than anything the picker actually emits: the row must still
# come out at exactly IW+2 (both borders), never more.
set -g NOTEROWS1 (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1 (string repeat -n 200 x))
set -g NOTEROW1V (__tcz_strip_sgr "$NOTEROWS1[-2]")
t "an absurdly long note still renders a row of exactly IW+2 (52) visible columns" 52 (string length --visible -- "$NOTEROW1V")
t "an absurdly long note is truncated with a trailing ellipsis, not silently dropped or wrapped" yes (string match -q '*…*' -- "$NOTEROW1V"; and echo yes; or echo no)
# A short note (well under IW) must still render byte-for-byte through
# __tcz_popup_truncate's own fast path (unchanged), not accidentally get
# clipped by an off-by-one in the new draw-site wrapping.
set -g NOTEROWS2 (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1 'short note')
set -g NOTEROW2V (__tcz_strip_sgr "$NOTEROWS2[-2]")
t "a short note still renders in full, unclipped" yes (string match -q '*short note*' -- "$NOTEROW2V"; and echo yes; or echo no)
t "a short note's row is still exactly IW+2 (52) visible columns (padded, not shrunk)" 52 (string length --visible -- "$NOTEROW2V")

# --- final review (I1): every note the picker can actually emit fits, by
# construction, not by luck -- enumerated from the SOURCE, not retyped ---------
# Extracts every literal `set note "..."` the real picker body contains (a
# future wording tweak changes what this list holds too, so the assertion
# tracks the actual strings rather than a snapshot of today's). Two of the
# four contain a $anch_scheme or $rel interpolation -- substituted with the
# REAL relationship domain (__tmux_lives_theme_relationships, the ONE home of
# that list) plus "off" (the only non-relationship value $anch_scheme can
# hold), so a future relationship with a longer name is covered automatically,
# not just today's set. $seed is substituted with a worst-case 7-char hex
# literal (every real seed is exactly 7 chars, '#' + 6 hex digits). The draw
# site always prepends exactly one space (" $MUTED$note$RST"), so that is
# added before comparing against IW (50). picker-legibility-autoapply Task 5
# briefly added two more notes (A-on/A-off) that made this boundary tight (49
# raw chars, 50 with the leading space); drop-autoapply-debounce-seed Task 1
# removed both along with the rest of auto-apply, so the four surviving
# templates are seed-preview/current/off/scheme — the >= 4 floor and the
# per-template width check both stay meaningful regardless.
set -g NOTELITERALS9 (string match -ar 'set note "[^"]*"' -- (string split \n -- "$pk2") | string replace -r '^set note "(.*)"$' '$1')
t "note-literal extraction found at least the 4 known notes (seed-preview/current/off/scheme)" yes (test (count $NOTELITERALS9) -ge 4; and echo yes; or echo no)
set -g NOTEDOMAIN9 off (__tmux_lives_theme_relationships)
for tmpl in $NOTELITERALS9
    set -l worst 0
    if string match -q '*$anch_scheme*' -- "$tmpl"; or string match -q '*$rel*' -- "$tmpl"
        for v in $NOTEDOMAIN9
            set -l s (string replace -a '$anch_scheme' "$v" -- "$tmpl")
            set s (string replace -a '$rel' "$v" -- "$s")
            set -l w (math (string length --visible -- "$s")" + 1")
            test $w -gt $worst; and set worst $w
        end
    else if string match -q '*$seed*' -- "$tmpl"
        set -l s (string replace -a '$seed' '#ffffff' -- "$tmpl")
        set worst (math (string length --visible -- "$s")" + 1")
    else
        set worst (math (string length --visible -- "$tmpl")" + 1")
    end
    t "note fits within IW (50) at its worst case, leading space included: \"$tmpl\"" yes (test $worst -le 50; and echo yes; or echo no)
end
# end of the name. Extracted from the REAL draw block (__t9_frame_text), asserted
# on rendered output rather than on the styling source.
set -g BANDROW (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 | string match -r '.*▌.*')
t "band row extraction is non-empty" 1 (test -n "$BANDROW"; and echo 1; or echo 0)
set -g BANDVIS (__tcz_strip_sgr "$BANDROW")
t "selected row is exactly the inner width plus both borders" 52 (string length --visible -- "$BANDVIS")
# sel-bg must still be the active background when the final inner column is drawn.
# __tcz_thp_ln unconditionally re-asserts the FRAME border color right before the
# closing │ (its own printf format), so a reset is NEVER literally adjacent to │
# regardless of whether the band reaches the edge — "\e[0m│" is unsatisfiable and
# would pass vacuously on both sides of this fix (proven: mutation-checked below).
# The real signature of the bug is unstyled padding: a bare reset directly
# followed by a plain SPACE, with no color escape between them. sel-bg re-asserts
# right after every internal reset (the existing replace-all pass), so the ONLY
# place a reset can be followed straight by a space is the trailing pad — exactly
# where the pre-fix code left it unstyled.
t "band survives to the right border" 0 (string match -ra '\e\[0m ' -- "$BANDROW" | count)

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
# WIN = rows - STATIC_IDLE (17, idle mode — every call below is editing=0);
# __t9_frame_rows now takes that same rows value and derives WIN
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
# picker-legibility-autoapply Task 5 briefly moved the real admission floor
# to 25 (STATIC_EDIT 21 -> 22); drop-autoapply-debounce-seed Task 1 restored
# it to 24, and picker-responsiveness-and-layout Task 6 moved it back to 25
# (STATIC_EDIT 21 -> 22 again, for an unrelated reason — a third seed-block
# row, not a legend pair). This call is idle mode either way (WIN = 24 -
# STATIC_IDLE = 7, comfortably positive) so it stays a plain non-collapsed
# size check regardless of where the admission floor itself sits.
t "frame: emits exactly its height — 24 rows"    24 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 24)

# --- picker-seed-section Task 3 (review fix): restore coverage for the padding branch --
# None of the four sizes above satisfies vtotal <= WIN any more (raising STATIC
# 15->21 shrank WIN at every one of them below the collapsed n=14 catalog's virtual
# total), so Task 1's blank-row padding block (__tcz_theme_picker, the winpad loop
# right after the scheme window) had lost ALL coverage — deleting it outright still
# left every assertion above green. This closes that gap directly: n=14 unexpanded
# (vtotal=14) at rows=40 gives WIN=23 (40 - STATIC_IDLE 17), which DOES exceed
# vtotal, so the window loop draws all 14 real rows and the padding branch must
# fill the remaining 9 with blank framed rows for the total to reach 40 at all.
t "frame: emits exactly its height — 40 rows (drives the padding branch, WIN=23 > n=14)" 40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40)

# --- picker-legibility-autoapply Task 3: the frame proof, extended to BOTH modes --
# Every size above only ever exercised editing=0 (the harness's own default).
# STATIC is now mode-dependent, so the frame must still emit exactly its height
# while editing too — at the same sizes, plus the 40-row idle padding case
# repeated in editing (WIN 40-22=18 against a 14-row list still exceeds it,
# so the padding branch is exercised in both modes, not just idle) and a
# dedicated editing floor (WIN 24-22=2; picker-responsiveness-and-layout
# Task 6 moved STATIC_EDIT back to 22, for an unrelated reason).
t "frame: 26 rows idle"      26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1)
t "frame: 26 rows editing"   26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 1)
t "frame: 40 rows idle"      40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40 0 1)
t "frame: 40 rows editing"   40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40 1 1)
t "frame: 52 rows idle"      52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52 0 1)
t "frame: 52 rows editing"   52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52 1 1)
# 24-22=2, still positive (not collapsed) even at STATIC_EDIT 22 — but 24 is
# no longer the real admission floor: Task 6 moved it to 25 (see the
# FLOORBLOCK9/__t9_floor tests above). This harness has no floor check of its
# own, so it still draws a (real-picker-unreachable) 24-row frame correctly.
t "frame: 24 rows editing"             24 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 24 1 1)

# --- review fix round: rows 19/20 editing, supplementary evidence -----------
# NOT a discriminator for the open-time floor fix (the floor check lives
# OUTSIDE this draw-only extraction — see the FLOORBLOCK9/__t9_floor tests
# above, which are the real before/after proof). This is a fixed structural
# fact of the widget instead, unchanged by the floor fix either way: below
# STATIC_EDIT, editing's window AND padding math both go negative, so the
# frame collapses to exactly STATIC_EDIT (21 — picker-legibility-autoapply
# Task 5 briefly moved it to 22; drop-autoapply-debounce-seed Task 1 restored
# it to 21; picker-responsiveness-and-layout Task 6 moved it back to 22, for
# an unrelated reason — a third seed-block row, not a legend pair) rows
# regardless of how far under it <rows> falls — which is exactly why the
# floor above must refuse these sizes rather than let the picker ever reach
# them.
t "frame: 19 rows editing collapses to STATIC_EDIT (unreachable once the floor is fixed)" 22 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 19 1 1)
t "frame: 20 rows editing collapses to STATIC_EDIT (unreachable once the floor is fixed)" 22 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 20 1 1)

# The header must appear ONLY when expanded, and only while it's still inside
# the scrolled window — this is the fix-discriminator.
t "header absent when collapsed" 0 (__t9_frame_text list 0 14 5 0 mono "$PAL9" '' 0 14 | string match -ra 'More Schemes' | count)
t "header present when expanded near the boundary" 1 (__t9_frame_text list 0 35 13 0 mono "$PAL9" '' 1 14 | string match -ra 'More Schemes' | count)
# Same scrolled-past state as "expanded, scrolled past header" above (sel=30):
# only the collapsed case was ever asserted header-free before this.
t "header absent when expanded and scrolled past" 0 (__t9_frame_text list 0 35 30 0 mono "$PAL9" '' 1 14 | string match -ra 'More Schemes' | count)

# --- final review Finding 3: bind the __tcz_thp_seedzone call's positional
# order (…$editing $chan…) with RENDERED CONTENT, not just a row count.
# __t9_frame_rows used to declare neither editing nor chan at all, so the
# real call at functions/tmux-categorize.fish:2117 silently reduced from 10
# args to 8 (this repos own zero-output-argument-vanishing hazard) —
# editing/chan landed on garbage from downstream positionals, and nothing
# here noticed because BOTH of __tcz_thp_seedzone's branches emit exactly 8
# lines regardless. editing=1/chan=2 is the case that actually discriminates
# a swap at the call site: at chan=1 a swap is invisible (editing=1/chan=1
# swapped is still 1/1), but at chan=2 a swap hands __tcz_thp_seedzone
# editing=2/chan=1 — `test "$editing" = 1` is then false, so it falls to the
# IDLE readout branch and the sliders vanish outright, matching the live
# symptom exactly ("←→ silently keeps moving the now-invisible channel").
set -l frameC1raw (string join \n -- (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 1))
set -l frameC1 (__tcz_strip_sgr "$frameC1raw")
t "seed-zone edit render: chan=1 marks the R slider" yes (string match -q '*▌R*' -- "$frameC1"; and echo yes; or echo no)
t "seed-zone edit render: chan=1 does not mark G" no (string match -q '*▌G*' -- "$frameC1"; and echo yes; or echo no)

set -l frameC2raw (string join \n -- (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 2))
set -l frameC2 (__tcz_strip_sgr "$frameC2raw")
t "seed-zone edit render: chan=2 marks the G slider, binding the editing/chan call order" yes (string match -q '*▌G*' -- "$frameC2"; and echo yes; or echo no)
t "seed-zone edit render: chan=2 does not mark R" no (string match -q '*▌R*' -- "$frameC2"; and echo yes; or echo no)

# --- picker-legibility-autoapply Task 4: the legend tells the truth in each mode --
# The reported "enter closes the whole picker" bug lives here, not in the
# dispatch: case enter already gates on $editing and only clears the mode —
# the dispatch is correct. The footer was STATIC, so while editing it kept
# advertising ⏎ save / esc close and named none of the channel keys. ⏎
# silently left edit mode (nothing looked saved), and a second ⏎ then saved
# and closed for real. Asserted against the RENDERED frame (__t9_frame_text),
# not source text — see the band/header assertions above for why a source
# grep would not have caught this class of bug.
set -g LEGI (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1 | string collect)
set -g LEGE (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 1 | string collect)
# __t9_frame_rows (the last call underlying LEGE, editing=1) also exposes the
# REAL leglines array the draw block produced, via __t9_last_leglines — so
# the row-count assertion below binds to what the implementation actually
# emitted, not a second, independent __tcz_thp_leg call that could drift
# from it.
set -g LEGEROWS $__t9_last_leglines
t "idle legend extraction is non-empty" 1 (test -n "$LEGI"; and echo 1; or echo 0)
t "editing legend extraction is non-empty" 1 (test -n "$LEGE"; and echo 1; or echo 0)
t "editing legend names the channel keys" 1 (string match -q '*channel*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend names adjust" 1 (string match -q '*adjust*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend names type hex" 1 (string match -q '*type hex*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend says keep, not save" 1 (string match -q '*keep*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend does not advertise close" 0 (string match -ra 'close' -- "$LEGE" | count)
t "idle legend still advertises save and close" 1 (string match -q '*save*' -- "$LEGI"; and string match -q '*close*' -- "$LEGI"; and echo 1; or echo 0)
t "idle legend does not name channels" 0 (string match -ra 'channel' -- "$LEGI" | count)

# ⚠️ the row count is load-bearing, not cosmetic: STATIC_IDLE/STATIC_EDIT
# (Task 3) each bake in a FIXED legend row count, so a legend that grows or
# shrinks per mode silently breaks the frame's total row count, with the
# cause hidden three sections away from the symptom. Assert it explicitly so
# the suite enforces the constraint rather than the next person remembering
# it. picker-legibility-autoapply Task 5 briefly added A auto as the
# browsing legend's tenth pair — measured: 9 pairs render 3 rows at cols=3,
# 10 spill a partial row and render 4 — so both modes moved 3 -> 4 (editing's
# own pad grew from one blank row to two to match).
# drop-autoapply-debounce-seed Task 1 removed auto-apply and that pair with
# it, so browsing is back to 9 pairs / 3 rows and editing's pad is back to
# one blank row.
t "browsing legend is 3 rows" 3 (count (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m curated z shake '⇥' current/off  a apply '⏎' save esc close))
t "editing legend is padded to the same 3 rows" 3 (count $LEGEROWS)

# --- review I-1: the six draw-block cache keys, unguarded --------------------
# The reviewer proved all six call-site key EXPRESSIONS (not just the
# wrapper mechanics Task 1/2's own staticcache: tests already cover) are
# unguarded: four separate one-line mutations of the CALL SITE each
# reintroduce a real, visible bug and leave the full suite at ALL PASS. These
# four guards close that gap. Per the review's own instruction, each was
# proven to FAIL against its corresponding mutation before being trusted —
# see the fix report appended to task-2-report.md for the verbatim
# before/after runs; that proof is not repeated here as inline comments
# would just be unverified prose.

# I-1 guard 1 (staterow): the two production call sites can carry
# selected=0/live=0 AT ONCE (any browsing frame — focus=list — has
# curflag2=0 and offflag=0 by construction), and currow renders FIRST — so a
# reverted bare "<selected>_<live>" key collides WITHIN one frame, no
# two-frame walk needed: offrow's lookup hits currow's already-cached slot
# and 'legacy look' (offrow's own name, unique in the whole frame) never
# renders at all.
set -l frameStaterow (__t9_frame_text list 0 14 5 0 mono "$PAL9" '' '' '' 52 0 1 '')
t "frame: browsing shows the off row exactly once (staterow key collision guard)" 1 (string match -ra 'legacy look' -- $frameStaterow | count)

# I-1 guard 2 (preview/tabstrip curidx): a two-frame walk, cache never
# cleared between them — frame A primes the cache at focus=list sel=5, frame
# B tabs to the second list (state, off) with sel left at the SAME 5 (the
# real picker never resets sel on a focus change). A reverted curidx="$sel"
# key means frame B's preview/tabstrip lookups hit frame A's cache
# (identical $sel) and keep showing the SCHEME's bar bg (48;2;68;80;47 — the
# bar role of the harness's own PAL9, #44502f) instead of recomputing the
# legacy/off bg (48;2;68;68;68 — the harness's own $legacy, #444444). Search
# the RAW frame text (SGR intact): both codes are themselves the literal
# substring being asserted on, and __tcz_strip_sgr would delete them.
__tcz_thp_cacheclear
__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 0 1 '' >/dev/null
set -l frameOff (string join \n -- (__t9_draw_nocc_text state 1 14 5 0 mono "$PAL9" '' '' '' 52 0 1 ''))
t "frame: tabbing to off recomputes the preview bar to the legacy bg (curidx guard)" yes (string match -q '*48;2;68;68;68*' -- "$frameOff"; and echo yes; or echo no)
t "frame: tabbing to off does not keep the scheme's bar bg (curidx guard)" no (string match -q '*48;2;68;80;47*' -- "$frameOff"; and echo yes; or echo no)

# I-1 guard 3 (seedzone seedkey): a two-frame walk, cache never cleared —
# frame A primes editing=1/chan=1 at seed #5f772b, frame B keeps
# editing/chan identical but drags the colour to #c7772b (a real channel
# move, R 95->199). A reverted seedkey="$editing"_"$chan" (dropping r/g/b)
# means frame B hits frame A's cache and the readout FREEZES on 5f772b —
# the seed sections entire purpose.
__tcz_thp_cacheclear
__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 1 1 '' '#5f772b' >/dev/null
set -l frameSeedB (string join \n -- (__t9_draw_nocc_text list 0 14 5 0 mono "$PAL9" '' '' '' 52 1 1 '' '#c7772b'))
t "frame: a channel drag updates the seed readout (seedkey guard)" yes (string match -q '*c7772b*' -- "$frameSeedB"; and echo yes; or echo no)

# I-1 guard 4 (leg --cachekey=$editing): a two-frame walk, cache never
# cleared — frame A renders browsing (editing=0, its own real 3-row legend),
# frame B switches to editing with everything else unchanged. A reverted
# constant sentinel (e.g. "--cachekey=x" at both call sites) means frame B's
# leg call hits frame A's cached BROWSING legend (3 lines) instead of
# computing its own 2-row editing legend — and the editing branch ALWAYS
# appends one more blank line on top of whatever leglines held, so the stale
# 3-line browsing legend becomes 4 elements instead of the intended 3,
# overflowing the exact-height frame by one row (52 -> 53, into a 52-row
# popup — this repos own top-border-scrolls-off failure mode).
__tcz_thp_cacheclear
__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 0 1 '' >/dev/null
set -l editRows (__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 1 1 '')
t "frame: switching to editing after browsing still emits exactly 52 rows (leg key guard)" 52 $editRows

# I-1 guard 5 (cells cachekey passthrough, Task 3): a two-frame walk, cache
# never cleared -- frame A renders the full 14-row scheme list at sel=5
# (populating a __tcz_cc_ entry for every index). Frame B moves the cursor
# to sel=6 with everything else unchanged: exactly two rows (indices 6 and
# 7, 1-based) become ROW-cache MISSES (their <selected> flag flipped, Task
# 1s own index_selected_current key), but neither index's <hexes> changed,
# so __tcz_thp_row_uncacheds OWN __tcz_thp_cells lookup should HIT the
# __tcz_cc_ slot frame A already populated for those same indices -- this is
# the entire saving Task 3 exists for (the brief's "still runs for the two
# genuinely-dirty rows on every cursor move" cost this closes). anch_scheme=
# off / anchpal='' keeps the second-lists OWN uncached __tcz_thp_cells call
# (functions/tmux-categorize.fish, the "current" rows anchcells line, outside
# Task 3s scope) from also incrementing the spy every frame and confounding
# the count -- with anchpal non-empty this test would need to expect 1, not
# 0, and could not tell "always uncached" apart from "cached correctly plus
# one unrelated always-uncached call" as cleanly. Proven live: reverting
# __tcz_thp_row_uncacheds call site to `__tcz_thp_cells "$hexes"` (dropping
# the key) makes frame B rebuild cells for both dirty rows (count 2) while
# every direct cellcache: assertion above still stays ALL PASS -- proof this
# guard catches what a hand-keyed direct call cannot.
set -g __t3_calls3 0
functions --copy __tcz_thp_cells_uncached __t3_real3
function __tcz_thp_cells_uncached
    set -g __t3_calls3 (math $__t3_calls3 + 1)
    __t3_real3 $argv
end
__tcz_thp_cacheclear
__t9_draw_nocc list 0 14 5 0 off '' '' '' '' 52 0 1 '' >/dev/null
set -g __t3_calls3 0
__t9_draw_nocc list 0 14 6 0 off '' '' '' '' 52 0 1 '' >/dev/null
t "frame: moving the cursor reuses the swatch cache for the two now-dirty rows (cells key guard)" 0 $__t3_calls3
functions --erase __tcz_thp_cells_uncached
functions --copy __t3_real3 __tcz_thp_cells_uncached

# I-1 guard 6 (anchcells cachekey, Task 3 fix round): the second-lists own
# "current" row swatch (functions/tmux-categorize.fish:~2359, `test -n
# "$anchpal"; and set anchcells (__tcz_thp_cells "$anchpal" anchcells)`) was
# LEFT OUT of Task 3s original scope and shipped uncached -- it fired on
# every single redraw whenever a theme is set (anchpal non-empty), which is
# the live case for this user. Fixed with the exact __tcz_thp_band "$legacy"
# band precedent two lines above it: a FRAME-CONSTANT key ("anchcells") is
# correct because anchpal only ever changes inside __tcz_thp_reanchor, and
# every one of its three call sites (the hex-entry commit, the picker-open
# init, and the debounced seed-edit settle) is immediately preceded by
# __tcz_thp_reload, whose own first line is __tcz_thp_cacheclear -- so any
# stale __tcz_cc_anchcells entry is always erased in the same beat anchpal
# moves to a new value; verified by reading every reanchor call site, not
# assumed. A two-frame walk, cache never cleared, anchpal UNCHANGED between
# frames (a plain redraw with no reload in between -- the common case):
# frame A populates __tcz_cc_anchcells, frame B must reuse it, not rebuild
# it. Proven live below (see the report): reverting the call site to
# `__tcz_thp_cells "$anchpal"` (dropping the key) makes frame B rebuild it
# every time.
set -g __t3b_calls 0
functions --copy __tcz_thp_cells_uncached __t3b_real
function __tcz_thp_cells_uncached
    set -g __t3b_calls (math $__t3b_calls + 1)
    __t3b_real $argv
end
__tcz_thp_cacheclear
__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 0 1 '' >/dev/null
set -g __t3b_calls 0
__t9_draw_nocc list 0 14 5 0 mono "$PAL9" '' '' '' 52 0 1 '' >/dev/null
t "frame: the current rows swatch is reused across an unchanged-anchpal redraw (anchcells key guard)" 0 $__t3b_calls
functions --erase __tcz_thp_cells_uncached
functions --copy __t3b_real __tcz_thp_cells_uncached

# --- __tcz_popup_emit: differential frame emission ---------------------------
# The picker repainted its whole 52-row frame on every keypress: 12,697 bytes
# to communicate a 747-byte change. Fine locally, unusable over the iPad's SSH
# link. See docs/superpowers/specs/2026-08-21-picker-partial-repaint-design.md.
function __t10_emit --description 'run __tcz_popup_emit with the given rows and return what it emitted, AS CAPTURED. The split fish performs on the command substitution is deliberate and is the assertion signal: the whole-frame path writes a newline BETWEEN rows so it yields one element per row, while a differential paint is cursor-addressed with no newlines and yields exactly one. Verified against real fish.'
    __tcz_popup_emit $argv
end

function __t10_emit_bytes --description 'byte count of what __tcz_popup_emit emitted for the given rows. Goes through a file so no shell layer can reshape the bytes being counted.'
    set -l f (mktemp)
    __tcz_popup_emit $argv >$f
    set -l n (wc -c <$f | string trim)
    rm -f $f
    echo $n
end

function __t10_reset --description 'clear the emitters state so a test starts from a known first-paint'
    set -e __tcz_pe_prev
    set -e __tcz_pe_force
    set -e __tcz_pe_partial
end

set -g __t10_exists (functions -q __tcz_popup_emit; and echo 1; or echo 0)
t "emit: __tcz_popup_emit is defined" 1 $__t10_exists

# (a) WIRE FORMAT — pinned against a hand-written expected string, no parser.
# The partial path has no newlines, so it captures as a single element and can
# be compared exactly. This is the assertion that stops the test and the
# implementation from sharing a wrong assumption about the escape shape.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null           # first paint, discarded
set -g __t10_part (__t10_emit AAA XXX CCC)        # row 2 only
set -g __t10_want (printf '\e[?2026h\e[2;1HXXX\e[K\e[?2026l')
t "emit: one changed row emits exactly one addressed write" "$__t10_want" "$__t10_part"
t "emit: a partial paint captures as a single element (no newlines)" 1 (count $__t10_part)

# (b) FIRST PAINT IS FULL. Three rows, three elements.
__t10_reset
set -g __t10_first (__t10_emit AAA BBB CCC)
t "emit: the first paint is a whole-frame paint" 3 (count $__t10_first)

# (c) NOTHING CHANGED — emits nothing at all.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_same (__t10_emit_bytes AAA BBB CCC)
t "emit: an identical frame emits zero bytes" 0 $__t10_same

# (d) ROW-COUNT CHANGE forces a full paint (the geometry guard).
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_grew (__t10_emit AAA BBB CCC DDD)
t "emit: a different row count forces a whole-frame paint" 4 (count $__t10_grew)

# (e) FORCE flag.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __tcz_pe_force 1
set -g __t10_forced (__t10_emit AAA BBB CCC)
t "emit: __tcz_pe_force repaints in full even when nothing changed" 3 (count $__t10_forced)
t "emit: a full paint clears the force flag" 0 "$__tcz_pe_force"

# (f) PARTIAL flag drives Task 3's self-heal, so pin both transitions.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_pf_full "$__tcz_pe_partial"
__tcz_popup_emit AAA XXX CCC >/dev/null
set -g __t10_pf_part "$__tcz_pe_partial"
t "emit: a full paint leaves __tcz_pe_partial 0" 0 "$__t10_pf_full"
t "emit: a partial paint sets __tcz_pe_partial 1" 1 "$__t10_pf_part"

# (g) EMPTY ROWS survive. If fish ever dropped an empty element from the saved
# frame the row COUNT would shift and every later diff would be garbage. This
# guards a fish behaviour the emitter depends on, not the emitter itself.
__t10_reset
__tcz_popup_emit AAA '' CCC >/dev/null
set -g __t10_emptycount (count $__tcz_pe_prev)
t "emit: an empty row is preserved in the saved frame" 3 $__t10_emptycount

# (h) REAL GEOMETRY — the number this whole change exists for. Two consecutive
# frames at the user's actual size (62-row client -> 52-row popup, expanded
# catalog, one-row cursor move), via the same __t9_draw_nocc harness the frame
# proof uses, which evals the REAL draw block rather than a reimplementation.
# Measured today: the full frame is 12,697 bytes and 747 of them change.
# The 2000 threshold is deliberately loose — it must not go red because a
# layout tweak alters a row's width — but it is nowhere near loose enough for
# a whole-frame repaint to slip through. $PAL9 is the synthetic palette the
# frame proof above already uses; it is script-scoped and in scope here.
__t10_reset
set -g __t10_g1 (__t9_draw_nocc_text list 0 35 21 0 mono "$PAL9" '' 1 14 52 0 1)
set -g __t10_g2 (__t9_draw_nocc_text list 0 35 22 0 mono "$PAL9" '' 1 14 52 0 1)
t "emit: the real-geometry fixture really is 52 rows" 52 (count $__t10_g1)
__tcz_popup_emit $__t10_g1 >/dev/null
set -g __t10_gbytes (__t10_emit_bytes $__t10_g2)
t "emit: a one-row cursor move at real geometry stays under 2000 bytes" 1 (test "$__t10_gbytes" -lt 2000; and echo 1; or echo 0)
t "emit: ...and is not zero, i.e. the two fixture frames really do differ" 1 (test "$__t10_gbytes" -gt 0; and echo 1; or echo 0)

# --- __tcz_popup_emit: end-to-end screen EQUIVALENCE -------------------------
# The spec requires TWO assertions "because neither is sufficient alone":
# byte reduction (assertion h above) and equivalence. Byte reduction alone
# cannot tell an emitter that DROPS a changed row from a correct one — both
# read as "under 2000 bytes". Equivalence is a pure screen MODEL: paint frame
# A in full, apply frame B's EMITTED bytes to the model (parsing the real
# \e[<n>;1H addresses, not reimplementing the diff), and assert the model now
# equals B rendered in full. That is the property that actually matters — a
# partial paint must produce the same screen a full repaint would.
#
# Final-review finding: no assertion anywhere in this file performs TWO
# partial paints back to back, so a stale-model bug (the emitter's own
# __tcz_pe_prev never advancing on the partial path) can ship invisibly —
# `down` then `up` would emit nothing at all and leave the wrong row
# highlighted. The chained block below closes that gap.
function __t10_eq_emit_raw --description 'emit rows via __tcz_popup_emit and return exactly what it wrote, as ONE raw string — via a file, so no shell layer reshapes the bytes'
    set -l f (mktemp)
    __tcz_popup_emit $argv >$f
    set -l s (cat $f | string collect --no-trim-newlines)
    rm -f $f
    printf '%s' "$s"
end

function __t10_eq_apply --description '__t10_eq_apply <raw>: apply cursor-addressed writes (\e[<n>;1H<text>\e[K) parsed out of <raw> onto the __t10_eq_screen list, mutating it in place. A partial paint has no other escape shape to produce — see assertion (a) above, which pins the wire format this depends on. -ra with capture groups interleaves matches as full, group1, group2, full, group1, group2, ... (verified against real fish before trusting it here).'
    set -l raw $argv[1]
    set -l pairs (string match -ra '\x1b\[([0-9]+);1H(.*?)\x1b\[K' -- "$raw")
    set -l i 1
    while test $i -le (count $pairs)
        set -l idx $pairs[(math "$i + 1")]
        set -l txt $pairs[(math "$i + 2")]
        set -g __t10_eq_screen[$idx] "$txt"
        set i (math "$i + 3")
    end
end

function __t10_eq_case --description '__t10_eq_case <label>: paint __t10_eq_A in full, emit __t10_eq_B differentially, apply the emitted bytes to a model seeded from A, and assert the model now equals B exactly, row for row.'
    set -l label $argv[1]
    set -g __t10_eq_screen $__t10_eq_A
    set -l raw (__t10_eq_emit_raw $__t10_eq_B)
    __t10_eq_apply "$raw"
    set -l diffcount 0
    for i in (seq 52)
        test "$__t10_eq_screen[$i]" = "$__t10_eq_B[$i]"; or set diffcount (math $diffcount + 1)
    end
    t "emit: equivalence — $label — partial paint reproduces the full frame exactly (rows wrong)" 0 $diffcount
end

# Frame variants at the user's real geometry (52-row popup), covering the
# transitions a live session actually makes: a cursor move, entering/editing/
# leaving seed mode, collapsing/expanding the catalog, switching list focus,
# a changed note, and a changed seed swatch. $PAL9/$DRAWTEXT9 are the same
# script-scoped fixtures the frame proof and assertion (h) above already use.
set -g EQA        (__t9_draw_nocc_text list  0 35 21 0 mono "$PAL9" '' 1 14 52 0 1)
set -g EQB        (__t9_draw_nocc_text list  0 35 22 0 mono "$PAL9" '' 1 14 52 0 1)
set -g EQEDIT     (__t9_draw_nocc_text list  0 35 21 0 mono "$PAL9" '' 1 14 52 1 1)
set -g EQEDIT2    (__t9_draw_nocc_text list  0 35 21 0 mono "$PAL9" '' 1 14 52 1 2)
set -g EQCOLLAPSE (__t9_draw_nocc_text list  0 14 5  0 mono "$PAL9" '' '' '' 52 0 1)
set -g EQSTATE    (__t9_draw_nocc_text state 0 35 21 0 mono "$PAL9" '' 1 14 52 0 1)
set -g EQNOTE     (__t9_draw_nocc_text list  0 35 21 0 mono "$PAL9" '' 1 14 52 0 1 'a different note entirely')
set -g EQSEED     (__t9_draw_nocc_text list  0 35 21 0 mono "$PAL9" '' 1 14 52 0 1 '' '#b04020')

for v in EQA EQB EQEDIT EQEDIT2 EQCOLLAPSE EQSTATE EQNOTE EQSEED
    t "emit: equivalence fixture $v is 52 rows" 52 (count $$v)
end

# Every transition: previous frame painted FULL first (fresh state), then the
# next diffed against it.
for pair in "cursor-move:EQA:EQB" "enter-edit:EQA:EQEDIT" "edit-channel:EQEDIT:EQEDIT2" "leave-edit:EQEDIT:EQA" "collapse:EQA:EQCOLLAPSE" "expand:EQCOLLAPSE:EQA" "focus-state:EQA:EQSTATE" "changed-note:EQA:EQNOTE" "changed-seed:EQA:EQSEED" "identity:EQA:EQA"
    set -l p (string split ':' -- $pair)
    set -g __t10_eq_A $$p[2]
    set -g __t10_eq_B $$p[3]
    set -e __tcz_pe_prev
    set -e __tcz_pe_force
    set -e __tcz_pe_partial
    __tcz_popup_emit $__t10_eq_A >/dev/null      # full first paint
    __t10_eq_case $p[1]
end

# --- chained: many consecutive partial paints, no intervening full ----------
# This is the assertion the stale-model mutation cannot pass: if
# __tcz_pe_prev never advances on the partial path, every diff after the
# first is computed against the wrong baseline and the chain drifts off the
# real screen instead of tracking it.
set -e __tcz_pe_prev; set -e __tcz_pe_force; set -e __tcz_pe_partial
__tcz_popup_emit $EQA >/dev/null
set -g __t10_eq_screen $EQA
for nxt in EQB EQEDIT EQEDIT2 EQA EQNOTE EQSEED EQCOLLAPSE EQSTATE EQA
    __t10_eq_apply (__t10_eq_emit_raw $$nxt)
end
set -g __t10_eq_chaindiff 0
for i in (seq 52)
    test "$__t10_eq_screen[$i]" = "$EQA[$i]"; or set __t10_eq_chaindiff (math $__t10_eq_chaindiff + 1)
end
t "emit: equivalence — 9 chained partial paints still land on the right screen" 0 $__t10_eq_chaindiff

# --- the full-paint path stays byte-identical to the pre-branch emission ----
function __t10_eq_oldpaint --description 'the pre-branch inline whole-frame emission, verbatim from 19416e3 — kept ONLY as a regression anchor for the assertion below'
    set -l rows $argv
    printf '\e[?2026h\e[H'
    test (count $rows) -gt 1; and printf '%s\e[K\n' $rows[1..-2]
    printf '%s\e[K' $rows[-1]
    printf '\e[J\e[?2026l'
end
set -g __t10_eq_f1 (mktemp); set -g __t10_eq_f2 (mktemp)
__t10_eq_oldpaint $EQA >$__t10_eq_f1
set -e __tcz_pe_prev; set -e __tcz_pe_force; set -e __tcz_pe_partial
__tcz_popup_emit $EQA >$__t10_eq_f2
t "emit: equivalence — full-paint path is byte-identical to the pre-branch emission" 0 (cmp -s $__t10_eq_f1 $__t10_eq_f2; echo $status)
rm -f $__t10_eq_f1 $__t10_eq_f2

# --- the picker routes BOTH its frames through the emitter -------------------
set -g __t10_body (functions __tcz_theme_picker | string match -rv '^\s*#' | string collect)
t "wiring: picker body extraction is non-empty" 1 (test -n "$__t10_body"; and echo 1; or echo 0)
set -g __t10_bodylines (string split \n -- "$__t10_body")

set -g __t10_calls (string match -r '__tcz_popup_emit ' -- $__t10_bodylines | count)
t "wiring: picker calls the emitter at both its frames" 2 $__t10_calls

set -g __t10_inline (string match -r '2026h' -- $__t10_bodylines | count)
t "wiring: no inline whole-frame paint remains in the picker" 0 $__t10_inline

# The emitter's memoized __tcz_pe_prev is process-global, but each of these
# three handovers hands the terminal to (or back from) a screen with
# DIFFERENT content that the emitter has no way to know about — the exact
# cross-call state-bleed class that broke __t9_hexentry_rows and
# __t9_hexentry_no_trailing_nl above when THEY shared emitter state across
# calls. Both forces are redundant-by-construction today (a fresh
# fish --no-config popup starts with __tcz_pe_prev unset, and the admission
# floor means the main frame's row count can never equal hex-entry's, so the
# geometry guard alone already forces a whole paint) — cheap insurance kept
# on purpose, not dead code to prune. Source-anchored, bounded to the picker
# body like the wiring guards above; Task 1 already proves the flag works
# behaviourally, so this only proves the picker still SETS it at all three
# handover sites plus the one entry-time reset.
# picker-partial-repaint Task 3 adds a FOURTH occurrence — the self-heal
# block's own `__tcz_pe_force 1` — which is not a handover at all (no screen
# hand-off happens; it forces a whole repaint of the SAME frame once input
# settles after a partial paint). Count widened 3 -> 4 to match; the
# self-heal block's own content is pinned separately below.
set -g __t10_forcecount (string match -r '__tcz_pe_force 1' -- $__t10_bodylines | count)
t "wiring: the picker forces a whole paint at all three handover sites, plus self-heal" 4 $__t10_forcecount

set -g __t10_prevreset (string match -r 'set -e __tcz_pe_prev' -- $__t10_bodylines | count)
t "wiring: the picker discards the emitter's stale frame at entry" 1 $__t10_prevreset

# NON-REGRESSION GUARD (correctly passes before AND after this task): the
# session switcher is deliberately out of scope. Its per-keypress content is a
# live capture-pane of a different session, so nearly every row genuinely
# differs and a diff would buy almost nothing. Do not report this as vacuous.
set -g __t10_swlines (string split \n -- (functions __tcz_popup_draw | string match -rv '^\s*#' | string collect))
t "wiring: the session switcher still paints whole frames" 1 (string match -r '2026h' -- $__t10_swlines | count)
t "wiring: the session switcher does not use the emitter" 0 (string match -r '__tcz_popup_emit' -- $__t10_swlines | count)

# --- the settle poll also heals a partially-painted screen -------------------
# NB: un-stripped body. The BEGIN/END markers are comments, so the
# comment-stripped $__t10_body from the wiring block above cannot see them.
set -g __t10_raw (functions __tcz_theme_picker | string collect)
t "self-heal: raw picker body extraction is non-empty" 1 (test -n "$__t10_raw"; and echo 1; or echo 0)

set -g __t10_heal (string match -r '# BEGIN self-heal(.|\n)*?# END self-heal' -- "$__t10_raw" | string collect)
t "self-heal: the marked block exists" 1 (test -n "$__t10_heal"; and echo 1; or echo 0)
t "self-heal: it forces a whole repaint" 1 (string match -q '*__tcz_pe_force 1*' -- "$__t10_heal"; and echo 1; or echo 0)
t "self-heal: it clears the partial flag, which is what stops it looping" 1 (string match -q '*__tcz_pe_partial 0*' -- "$__t10_heal"; and echo 1; or echo 0)

# The gate must arm on a partial paint IN ADDITION to the two existing
# conditions. flashfield and seeddirty are deliberately independent — three
# sibling key arms clear flashfield on unrelated keypresses, and coupling them
# once silently cancelled a pending seed batch. Assert all three survive.
set -g __t10_gate (string match -r 'if test -n "\$flashfield"; or test "\$seeddirty" = 1[^\n]*' -- "$__t10_raw" | string collect)
t "self-heal: the settle gate still tests flashfield and seeddirty" 1 (test -n "$__t10_gate"; and echo 1; or echo 0)
t "self-heal: the settle gate also arms on a partial paint" 1 (string match -q '*__tcz_pe_partial*' -- "$__t10_gate"; and echo 1; or echo 0)

# --- review I-2: a keyed call to a zero-output builder must emit ZERO bytes,
# not a stray blank line. __tcz_thp_tabstrip_uncached returns nothing on its
# early-return paths (non-hex tabshex — every non-ShellFish client — or an
# empty title); __tcz_thp_leg_uncached returns nothing when its remaining
# pairs are STILL malformed after a valid --cachekey= sentinel is stripped.
# `set -l x (cmd)` cannot see the difference (fish strips a trailing
# newline either way, collapsing "0 bytes" and "1 byte" to the same captured
# value) — piping straight to `wc -c` on the RAW stream is what the
# reviewer measured with, and what actually discriminates the bug.
set -l tabUncachedBytes (__tcz_thp_tabstrip_uncached notahex '#f5f5f5' title 50 | wc -c)
set -l tabCachedMiss (__tcz_thp_tabstrip notahex '#f5f5f5' title 50 zk1 | wc -c)
set -l tabCachedHit (__tcz_thp_tabstrip notahex '#f5f5f5' title 50 zk1 | wc -c)
t "staticcache: tabstrip keyed zero-output matches uncached (miss)" "$tabUncachedBytes" "$tabCachedMiss"
t "staticcache: tabstrip keyed zero-output matches uncached (hit)"  "$tabUncachedBytes" "$tabCachedHit"

set -l legUncachedBytes (__tcz_thp_leg_uncached 3 a b c | wc -c)
set -l legCachedMiss (__tcz_thp_leg 3 a b c --cachekey=zk1 | wc -c)
set -l legCachedHit (__tcz_thp_leg 3 a b c --cachekey=zk1 | wc -c)
t "staticcache: leg keyed zero-output (malformed+key) matches uncached (miss)" "$legUncachedBytes" "$legCachedMiss"
t "staticcache: leg keyed zero-output (malformed+key) matches uncached (hit)"  "$legUncachedBytes" "$legCachedHit"

# --- review M-5: the --cachekey= sentinel is collision-free by convention,
# not construction -- pinned, not fixed (disallowing that literal substring
# in every real description everywhere would be a worse trade than the
# limitation itself, which is not reachable from any production call site
# today: both real callers pass a fixed, hardcoded pair list).
t "staticcache: leg --cachekey= sentinel is convention not construction (known limitation)" '' (__tcz_thp_leg 2 k1 d1 k2 '--cachekey=oops')

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

# --- Task 4: edit mode ----------------------------------------------------------
set -g PB4 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB4"; and echo 1; or echo 0)
t "b toggles an edit mode" yes (string match -qr 'set editing' -- "$PB4"; and echo yes; or echo no)
t "arrows are mode-dependent" yes (string match -qr 'test "\$editing" = 1' -- "$PB4"; and echo yes; or echo no)
# The esc-in-edit-mode arm must clear the mode WITHOUT leaving the loop. Bound the
# grep to the arm itself: an unanchored multiline pattern over a 700-line body
# matches something the moment edit mode exists at all and proves nothing.
# Anchor on the two unique markers the implementation must place around it.
set -g ESCARM4 (string match -r 'BEGIN edit-esc(.|\n)*?END edit-esc' -- "$PB4")
t "edit-esc arm is uniquely anchored and non-empty" 1 (test -n "$ESCARM4"; and echo 1; or echo 0)
t "edit-esc arm clears the mode" 1 (string match -ra 'set editing 0' -- "$ESCARM4" | count)
t "edit-esc arm does not break the loop" 0 (string match -ra '\bbreak\b' -- "$ESCARM4" | count)
# The drain-hang guard is load-bearing and has been hit for real.
set -g DR4 (string match -ra 'stty min 0 time' -- "$PB4" | count)
t "drain loops re-assert non-blocking mode" yes (test $DR4 -ge 2; and echo yes; or echo no)

# --- Task 4 review fix: behavioural coverage for the arrow/toggle/esc dispatch ----
# Review finding: every assertion above is a SOURCE-TEXT GREP over $PB4 — none of
# them RUN the dispatch. The reviewer mutation-proved all 9 stay green under 5 real
# breakages (deleting the editing branch from case up/down/pgup/pgdn, deleting case
# left/right's editing guard, breaking the 255 clamp, swapping `set seed $editseed`
# for `set seed $anch_seed` in the esc arm, and unbinding the toggle from case b) —
# because e.g. the literal text `test "$editing" = 1` still occurs elsewhere even
# after the branch that matters is deleted. Same technique as $RB7/$CASEM9/$DRAWTEXT9
# above: extract the real arms by content-bounded awk range, assert each extraction
# is non-empty FIRST (an empty range makes every guard built on it vacuous — the
# same reasoning the BEGIN/END edit-esc markers exist for), stub
# __tcz_popup_readkey from a scripted token queue plus a no-op stty, and eval the
# wrapped arm for real against seeded locals. eval, not source: source opens its own
# local scope, so a `set -l` inside would not survive the call returning — these
# arms mutate the CALLER's locals (chan/seedr/seedg/seedb/seed/sel/sel2), which only
# works through eval running inline in the harness function's own scope.
#
# Extraction variables that a later-defined harness function references via `eval`
# MUST be `-g` (global) — a top-level `set -l` is invisible inside a function
# defined afterward (no dynamic scoping in fish). This bit during development: an
# early draft declared one extraction `-l`, and `eval` of an unset variable is a
# silent no-op (zero arguments) — no error, no crash, just the arm never running at
# all. Caught only by printing the "before"/"after" value and seeing them identical.
set -g ARROWUD9 (awk '/^            case left right$/{exit} /^            case up down pgup pgdn$/{f=1} f{print}' $catfile | string collect)
t "up/down arm extraction is non-empty" 1 (test -n "$ARROWUD9"; and echo 1; or echo 0)
set -g ARROWLR9 (awk '/^            case m$/{exit} /^            case left right$/{f=1} f{print}' $catfile | string collect)
t "left/right arm extraction is non-empty" 1 (test -n "$ARROWLR9"; and echo 1; or echo 0)
# `case` is switch-only (same constraint CASEM9WRAP documents above): the two arms
# extracted separately have to be spliced into ONE literal `switch $tok ... end`
# string and eval'd together, mirroring their real adjacency in the file — a real
# switch wrapping the eval CALL does not splice into it, since a switch's direct
# child must be a literal `case` at parse time and the body is only known at
# runtime. `\$tok` stays UNexpanded here (backslash-escaped) so it re-resolves at
# eval time against whichever `$tok` the calling harness function set that call —
# unlike $CASEM9WRAP's hardcoded "switch m", this wrapper is reused across many
# different token scenarios.
set -g ARROW9WRAP "switch \$tok
$ARROWUD9
$ARROWLR9
end"

set -g __t9_real_readkey (functions __tcz_popup_readkey | string collect)
function __tcz_popup_readkey --description 'test stub, temporarily REPLACING the real __tcz_popup_readkey (restored from $__t9_real_readkey below): pops the next token off the global $__t9_rkq queue each call (simulating a drain loop''s buffered reads); returns "other" once exhausted — a safe, deterministic drain terminator regardless of how many tokens a scenario actually queued.'
    if test (count $__t9_rkq) -gt 0
        echo $__t9_rkq[1]
        set -g __t9_rkq $__t9_rkq[2..-1]
    else
        echo other
    end
end
function stty
    # no-op: the real stty targets the actual terminal device, which has no
    # meaningful state to assert on here and may not even be present under the
    # test harness. The extracted arms call it only to toggle blocking mode
    # around a scripted read, which the stub queue above makes irrelevant.
end

function __t9_arrow --argument-names tok editing chan seedhex focus sel sel2 --description 'eval the REAL up/down/pgup/pgdn + left/right dispatch arms (via $ARROW9WRAP) against a throwaway scope that declares every local either arm reads or writes. Trailing argv (argv[8..]) seeds the readkey queue a drain loop consumes AFTER the initial keypress — e.g. two more "right" tokens simulates a 3-press held burst. Prints "<chan>\n<seedr>\n<seedg>\n<seedb>\n<seed>\n<sel>\n<sel2>" (one per line, so a caller can index a single field OR quote the whole capture for a space-joined equality check — both are used by the assertions below).'
    set -l seedr 0
    set -l seedg 0
    set -l seedb 0
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $seedhex)
    if test (count $m) -eq 3
        set seedr (math "0x$m[1]")
        set seedg (math "0x$m[2]")
        set seedb (math "0x$m[3]")
    end
    set -l seed $seedhex
    set -l WIN 5
    set -l n 5
    set -g __t9_rkq $argv[8..-1]
    eval $ARROW9WRAP
    printf '%s\n' $chan $seedr $seedg $seedb $seed $sel $sel2
end

# Mode gate, both directions, for ↑↓ (item 1a/1b): active at editing=1 (chan moves,
# nothing else does), inert at editing=0 (chan is untouched, the pre-existing
# scheme-cursor logic runs exactly as before — proving the gate doesn't regress the
# code it wraps, not just that it exists).
set -g R_UD_UP1 (__t9_arrow up 1 2 '#5f772b' list 0 0)
t "editing=1: up moves chan down by one"        "1 95 119 43 #5f772b 0 0" "$R_UD_UP1"
set -g R_UD_DOWN1 (__t9_arrow down 1 2 '#5f772b' list 0 0)
t "editing=1: down moves chan up by one"        "3 95 119 43 #5f772b 0 0" "$R_UD_DOWN1"
set -g R_UD_DOWN0 (__t9_arrow down 0 2 '#5f772b' list 0 0)
t "editing=0: down leaves chan untouched, sel still moves" "2 95 119 43 #5f772b 1 0" "$R_UD_DOWN0"

# chan floor/ceiling at 1..3 (item: floor/ceiling), still under the active gate.
set -g R_CHFLOOR (__t9_arrow up 1 1 '#5f772b' list 0 0)
t "editing=1: chan floors at 1 (up from 1 stays 1)"   "1 95 119 43 #5f772b 0 0" "$R_CHFLOOR"
set -g R_CHCEIL (__t9_arrow down 1 3 '#5f772b' list 0 0)
t "editing=1: chan ceilings at 3 (down from 3 stays 3)" "3 95 119 43 #5f772b 0 0" "$R_CHCEIL"

# pgup/pgdn are no-ops while editing (item: pgup/pgdn no-ops) — there is no list to
# page; chan, seed, and sel/sel2 must all be exactly what they were.
set -g R_PGUP (__t9_arrow pgup 1 2 '#5f772b' list 0 0)
t "editing=1: pgup is a no-op"   "2 95 119 43 #5f772b 0 0" "$R_PGUP"
set -g R_PGDN (__t9_arrow pgdn 1 2 '#5f772b' list 0 0)
t "editing=1: pgdn is a no-op"   "2 95 119 43 #5f772b 0 0" "$R_PGDN"

# Mode gate, both directions, for ←→ (item 1c/1d): active at editing=1 (the seed
# channel moves), inert at editing=0 (the whole arm is a no-op — nothing moves).
set -g R_LR_RIGHT1 (__t9_arrow right 1 1 '#000000' list 0 0)
t "editing=1: right moves the R channel by +8" "1 8 0 0 #080000 0 0" "$R_LR_RIGHT1"
set -g R_LR_LEFT1 (__t9_arrow left 1 1 '#080000' list 0 0)
t "editing=1: left moves the R channel by -8"  "1 0 0 0 #000000 0 0" "$R_LR_LEFT1"
set -g R_LR_RIGHT0 (__t9_arrow right 0 1 '#000000' list 0 0)
t "editing=0: right is a no-op — seed unchanged" "1 0 0 0 #000000 0 0" "$R_LR_RIGHT0"

# ±8 per press (item) is the single-press cases directly above (8 and -8).
# picker-responsiveness Task 5: the coalescing drain used to SUM each queued
# token into delta (three "right" presses summing to +24), which meant a
# burst applied one large jump with no intermediate value ever drawn — there
# was nothing to stop on. It now DISCARDS the queued tokens instead, so a
# held key steps exactly once per frame regardless of burst depth: three
# coalesced right presses still move only +8, identical to a single press.
set -g R_LR_COALESCE (__t9_arrow right 1 1 '#000000' list 0 0 right right)
t "editing=1: three coalesced right presses still move only +8, not +24" "1 8 0 0 #080000 0 0" "$R_LR_COALESCE"

# Both clamps (item), plus hex well-formedness after each (item) — this is the
# direct discriminator for the reviewer's mutation 3 (255 -> 9999): an unclamped
# 258 prints as 3 hex digits ("102"), so $seed stops matching ^#[0-9a-f]{6}$ even
# before the numeric channel-value assertion catches the wrong number.
set -g R_LR_CLAMPHI (__t9_arrow right 1 1 '#fa0000' list 0 0)
t "editing=1: R channel clamps at the 255 ceiling (250+8)" "1 255 0 0 #ff0000 0 0" "$R_LR_CLAMPHI"
t "editing=1: seed stays a well-formed 6-hex-digit colour after the 255 clamp" yes (string match -qr '^#[0-9a-fA-F]{6}$' -- $R_LR_CLAMPHI[5]; and echo yes; or echo no)
set -g R_LR_CLAMPLO (__t9_arrow left 1 1 '#050000' list 0 0)
t "editing=1: R channel clamps at the 0 floor (5-8)" "1 0 0 0 #000000 0 0" "$R_LR_CLAMPLO"
t "editing=1: seed stays a well-formed 6-hex-digit colour after the 0 clamp" yes (string match -qr '^#[0-9a-fA-F]{6}$' -- $R_LR_CLAMPLO[5]; and echo yes; or echo no)

eval $__t9_real_readkey
functions -e stty

# case b (the toggle) and the edit-esc arm (esc's revert), run for real. The
# extraction's own existence is the discriminator for the reviewer's mutation 5
# (moving the toggle off case b onto some other key): if `case b` no longer appears
# literally at this indentation, the awk range below finds nothing and the
# non-empty assertion fails — the same mechanism that makes an empty range
# dangerous elsewhere is what catches this mutation.
set -g CASEB9 (awk '/^            case z$/{exit} /^            case b$/{f=1} f{print}' $catfile | string collect)
t "case-b body extraction is non-empty" 1 (test -n "$CASEB9"; and echo 1; or echo 0)
set -g CASEB9WRAP "switch \$tok
$CASEB9
end"
function __t9_caseb --argument-names focus editing seed --description 'eval the REAL case-b toggle body against seeded locals (chan/editseed start at sentinel values so an untouched-vs-touched distinction is visible; rows/STATIC_IDLE/STATIC_EDIT are seeded too — picker-legibility-autoapply Task 3s toggle now recomputes WIN on every press, and an unseeded rows/STATIC would make that a math error against undefined locals rather than a clean no-op). Prints "<editing> <chan> <editseed>".'
    set -l tok b
    set -l chan 9
    set -l editseed START
    set -l rows 52
    set -l STATIC_IDLE $STATIC9I
    set -l STATIC_EDIT $STATIC9E
    eval $CASEB9WRAP
    printf '%s %s %s\n' $editing $chan $editseed
end
set -g R_B_ENTER (__t9_caseb list 0 '#123456')
t "case b: entering sets editing=1, resets chan to 1, captures editseed from seed" "1 1 #123456" "$R_B_ENTER"
set -g R_B_LEAVE (__t9_caseb list 1 '#123456')
t "case b: a second press while editing clears editing, leaves chan/editseed untouched" "0 9 START" "$R_B_LEAVE"
set -g R_B_STATE (__t9_caseb state 0 '#123456')
t "case b: ignored entirely while focus is on the second list" "0 9 START" "$R_B_STATE"

# Task 3 (this plan): the toggle must RECOMPUTE WIN, not leave a stale value —
# a stale WIN is invisible to the frame proof, which always derives its own.
# WIN starts at an impossible sentinel (0, which cannot equal either real
# computed value at rows=52) so any post-eval value proves the arm wrote it,
# not that it happened to already agree by coincidence.
function __t9_caseb_win --argument-names editing --description 'eval the REAL case-b toggle body with WIN seeded to a sentinel, to prove the toggle recomputes it rather than leaving it stale. rows/STATIC_IDLE/STATIC_EDIT match the real function via the STATIC9I/STATIC9E extraction above. Prints the resulting $WIN.'
    set -l tok b
    set -l focus list
    set -l chan 9
    set -l editseed START
    set -l seed '#5f772b'
    set -l rows 52
    set -l STATIC_IDLE $STATIC9I
    set -l STATIC_EDIT $STATIC9E
    set -l WIN 0
    eval $CASEB9WRAP
    echo $WIN
end
t "case b: entering edit mode recomputes WIN (not left stale)" (math "52 - $STATIC9E") (__t9_caseb_win 0)
t "case b: leaving edit mode recomputes WIN (not left stale)" (math "52 - $STATIC9I") (__t9_caseb_win 1)

# The esc arm's own extraction, but eval-safe rather than grep-safe: $ESCARM4 above
# (unquoted `string match -r`) is a 10-element LIST — command substitution splits a
# multi-line match into one element per line — which is fine for a substring grep
# (quoting it re-joins with SPACES, and word boundaries survive that) but wrong for
# eval (space-joining would fold every comment into the code that follows it on the
# same "line"). `string collect` re-joins with real newlines instead, matching every
# other eval'd extraction on this file. The pattern also has to include the leading
# "# " — matching bare "BEGIN edit-esc" (skipping the comment marker, which
# $ESCARM4's pattern does) makes the FIRST eval'd line a bogus command invocation
# ("Unknown command: BEGIN") that still happens to leave the rest of the arm
# runnable, but prints an ugly trace on every green run for no reason.
set -g ESCBODY9 (string match -r '# BEGIN edit-esc(.|\n)*?# END edit-esc' -- "$PB4" | string collect)
t "edit-esc arm extraction (eval-safe) is non-empty" 1 (test -n "$ESCBODY9"; and echo 1; or echo 0)
function __t9_esc --argument-names seed editseed anch_seed --description 'eval the REAL edit-esc arm against seeded locals where editseed and anch_seed deliberately differ, so a swap between them is visible. rows/STATIC_IDLE are seeded so the arms own WIN recompute (picker-legibility-autoapply Task 3) does not spray a math error against undefined locals. Prints the resulting $seed.'
    set -l editing 1
    set -l rows 26
    set -l STATIC_IDLE $STATIC9I
    eval $ESCBODY9
    echo $seed
end
# This is the direct discriminator for the reviewer's mutation 4 (swapping
# `set seed $editseed` for `set seed $anch_seed`): editseed and anch_seed are
# deliberately different values below, so a swap changes the printed result.
t "esc restores from editseed, not anch_seed" '#111111' (__t9_esc '#999999' '#111111' '#222222')

# Task 3 (this plan): esc-while-editing must ALSO recompute WIN — the third of
# the three mode-change sites (b, ⏎, esc). Same sentinel technique as case b's
# WIN proof above: WIN starts at 0, which cannot equal the real idle value at
# rows=26, so any other value proves the arm wrote it.
function __t9_esc_win --description 'eval the REAL edit-esc arm with WIN seeded to a sentinel, to prove it recomputes rather than leaving WIN stale. Prints the resulting $WIN.'
    set -l editing 1
    set -l seed '#999999'
    set -l editseed '#111111'
    set -l anch_seed '#222222'
    set -l rows 26
    set -l STATIC_IDLE $STATIC9I
    set -l WIN 0
    eval $ESCBODY9
    echo $WIN
end
t "esc while editing recomputes WIN (not left stale)" (math "26 - $STATIC9I") (__t9_esc_win)

# review fix round: the identical hole existed at the THIRD mode-change site,
# case enter's editing branch (⏎ while editing) — found not by a test but by
# re-reading the diff, which is not a substitute for one. None of the 28
# `eval $…` sites in this file extracted that sub-range, so nothing would
# have caught it: commenting out its WIN recompute left both this suite and
# test-tmux-install.fish fully green. Same extraction technique as case b/esc
# — BEGIN/END markers around just the editing=1 branch (not the else, which
# ends in `break` and cannot be eval'd standalone outside a loop).
set -g ENTERBODY9 (string match -r '# BEGIN enter-edit(.|\n)*?# END enter-edit' -- "$SLB" | string collect)
t "enter-edit arm extraction is non-empty" 1 (test -n "$ENTERBODY9"; and echo 1; or echo 0)
function __t9_enter_win --description 'eval the REAL enter-while-editing arm (BEGIN/END enter-edit) with WIN seeded to a sentinel, to prove it recomputes rather than leaving WIN stale — same sentinel technique as case b/esc above. Prints the resulting $WIN.'
    set -l editing 1
    set -l rows 26
    set -l STATIC_IDLE $STATIC9I
    set -l WIN 0
    eval $ENTERBODY9
    echo $WIN
end
t "enter while editing recomputes WIN (not left stale)" (math "26 - $STATIC9I") (__t9_enter_win)

# --- Task 5: typed hex is framed ------------------------------------------------
# The picker opens with display-popup -B, so tmux draws NO border; every screen
# must draw its own or it floats on the scrollback.
set -g HB5 (awk '/function __tcz_thp_hexentry/,/^    end$/' $catfile | string collect)
t "hexentry body extraction is non-empty" 1 (test -n "$HB5"; and echo 1; or echo 0)
t "hexentry draws its own border" yes (string match -qr '╭|╰' -- "$HB5"; and echo yes; or echo no)

# The grep above is a floor, not a ceiling — it would pass just as well with a
# border glyph sitting in an unrelated comment. Prove the RENDERED FRAME is
# actually bordered, at the SAME width as the rest of the picker (IW+2 = 52),
# on every row: eval-define the real extracted function (the `function …
# end` wrapper registers it globally, exactly like sourcing does for every
# other builder in this file), stub __tcz_thp_readchar so the entering-loop
# reads a scripted "esc" and exits after painting exactly one frame, and seed
# every outer-scope local __tcz_thp_hexentry closes over via
# --no-scope-shadowing (BORDER/RST/BRAND/IW/seed/note/flashfield —
# __tcz_theme_picker sets all of these before its loop can ever reach here;
# picker-responsiveness-and-layout Task 6 (fix round) deleted the dead
# seedfg local that used to be in this list too — this harness's own now-inert
# `set -l seedfg` pre-declaration is left in place deliberately, not an
# oversight: it costs nothing and touching every eval-harness's scope
# mirroring for a variable that was never actually read by any extracted
# fragment is scope creep this fix round was told to avoid).
eval $HB5
t "hexentry is now a real callable function" 0 (functions -q __tcz_thp_hexentry; echo $status)

set -g __t9h_real_readchar (functions __tcz_thp_readchar | string collect)
function __tcz_thp_readchar --description 'test stub, temporarily REPLACING the real __tcz_thp_readchar (restored from $__t9h_real_readchar below): pops the next token off $__t9h_rkq; returns esc once exhausted so the entering-loop always terminates regardless of how many tokens a scenario queued.'
    if test (count $__t9h_rkq) -gt 0
        echo $__t9h_rkq[1]
        set -g __t9h_rkq $__t9h_rkq[2..-1]
    else
        echo esc
    end
end

function __t9_hexentry_rows --argument-names iw --description 'run the REAL __tcz_thp_hexentry for exactly one drawn frame (the queued token is a single "esc", so the entering-loop exits immediately after its first paint) and print each frame ROW, one per output line, SGR left intact (callers strip it as needed). <iw> parameterizes $IW (default 50, the shipped width) — a second call at a different width is what proves the fill is genuinely computed from $IW rather than a value the reviewer could replace with a literal and still see ALL PASS. Captures the actual synchronized-update PAINT rather than peeking at $helines — $helines is a -l local of the WHILE loop inside __tcz_thp_hexentry; that block scope closes before this harness gets control back, so the rendered bytes are the only thing left to assert on, which is also the more faithful check: it is what the user would actually see. Uses PLAIN `string collect` throughout its peeling — see __t9_hexentry_no_trailing_nl below for why `--no-trim-newlines` does NOT belong in this particular pipeline.'
    test -n "$iw"; or set iw 50
    set -l seed '#5f772b'
    set -l seedfg '#f5f5f5'
    set -l note ''
    set -l flashfield ''
    set -l BORDER (__tcz_theme border)
    set -l RST (__tcz_theme reset)
    set -l BRAND (__tcz_theme brand)
    set -l IW $iw
    set -g __t9h_rkq esc
    # picker-partial-repaint Task 2: __tcz_thp_hexentry now paints through
    # __tcz_popup_emit, which memoizes the previous frame GLOBALLY across
    # calls. Two calls at different widths (IW=50 then IW=70) produce the
    # SAME row count, so without a reset the second call would see an
    # unchanged geometry and diff against the first call's frame instead of
    # painting whole — a partial paint has no \e[H/\e[J markers and no \n
    # row separators, which this harness's literal peel below depends on.
    # Force a fresh whole-frame paint every call, matching what this harness
    # has always assumed.
    set -e __tcz_pe_prev
    set -g __tcz_pe_force 1
    set -l out (__tcz_thp_hexentry | string collect)
    # Peel the four wrapper escapes by EXACT literal match, in the order they
    # were printed (leading full-screen clear · sync-update open+home · the
    # single frame's rows, \n-joined · sync-update close · trailing full-screen
    # clear) — what remains is exactly "<row1>\e[K\n<row2>\e[K\n…<rowN>\e[K".
    # `string replace` on a multi-line STRING returns one OUTPUT ITEM PER
    # INPUT LINE rather than one joined string — re-collect after every call,
    # or the next replace's `"$out"` re-joins those items with SPACES (fish's
    # quoting rule for a multi-element var), silently eating the very
    # newlines the row split below depends on. Bit this for real while
    # writing this test: without `| string collect` here, the row count came
    # back 2 (one giant space-joined row) instead of 11.
    #
    # PLAIN `string collect` (no --no-trim-newlines) is deliberate here, not
    # an oversight: `string replace`/`string match` process a multi-line
    # STRING one line at a time and re-echo EVERY line — including the
    # last — with its OWN trailing newline, an artifact of the tool's own
    # per-record convention, not a property of the content. Plain `string
    # collect` trims exactly that one artifact newline back off after each
    # step, which is what makes this 4-step peel reconstruct the original
    # content correctly. Tried --no-trim-newlines on every step first: it
    # preserves those FOUR artifact newlines right along with any genuine
    # one, so even the CORRECT (non-mutated) implementation came back as 11
    # real rows plus 4 fully empty ones — a false positive on every run, not
    # a discriminator. See __t9_hexentry_no_trailing_nl for the check that
    # actually needs to see a genuine trailing newline, and why it works by
    # testing the untouched raw capture directly instead of trying to make
    # this extraction pipeline serve double duty.
    set out (string replace -- (printf '\e[2J') '' "$out" | string collect)
    set out (string replace -- (printf '\e[?2026h\e[H') '' "$out" | string collect)
    set out (string replace -- (printf '\e[J\e[?2026l') '' "$out" | string collect)
    set out (string replace -- (printf '\e[2J') '' "$out" | string collect)
    for row in (string split \n -- "$out")
        string replace -- (printf '\e[K') '' "$row"
    end
end

function __t9_hexentry_no_trailing_nl --description 'run the REAL __tcz_thp_hexentry for one frame and check the RAW captured stdout DIRECTLY — no string replace/match extraction — for a newline sitting immediately before the synchronized-update close marker (\e[J\e[?2026l). That exact shape is what a reintroduced `printf "%s\e[K\n" $helines[-1]` mutation (the top-border-scroll defect: the extra \n pushes the cursor one row past the popup, scrolling the top border off) would produce; the correct implementation prints the last row via `printf "%s\e[K" …` with no trailing \n, so the byte immediately before the close marker is K, never a newline. Deliberately does NOT reuse __t9_hexentry_rows own peeling: string replace/match echo every processed line with their OWN trailing newline (see the comment on that function) and --no-trim-newlines would preserve those artifacts too, not just a genuine one — proven while building this fix (a toy 3-line round trip through string match -rg with --no-trim-newlines came back with two EXTRA \n bytes appended, not the one genuine content byte). A single string match -q existence check on the untouched raw capture sidesteps the whole class: nothing here gets split, re-echoed, or reassembled. Prints yes/no.'
    set -l seed '#5f772b'
    set -l seedfg '#f5f5f5'
    set -l note ''
    set -l flashfield ''
    set -l BORDER (__tcz_theme border)
    set -l RST (__tcz_theme reset)
    set -l BRAND (__tcz_theme brand)
    set -l IW 50
    set -g __t9h_rkq esc
    # picker-partial-repaint Task 2 fix round: same cross-call state-bleed as
    # __t9_hexentry_rows above — this runs AFTER HEROWS5 has already primed
    # __tcz_pe_prev with an IDENTICAL IW=50/seed=#5f772b frame, so without a
    # reset the emitter finds zero dirty rows and emits nothing at all (just
    # __tcz_thp_hexentry's own leading/trailing \e[2J) — the close marker this
    # assertion searches for is then simply absent, and `string match -q`
    # reports "no" unconditionally, whether or not a trailing-newline
    # regression exists. Force a fresh whole-frame paint, matching what this
    # harness has always assumed.
    set -e __tcz_pe_prev
    set -g __tcz_pe_force 1
    set -l out (__tcz_thp_hexentry | string collect --no-trim-newlines)
    string match -qr '\n\x1b\[J\x1b\[\?2026l' -- "$out"; and echo yes; or echo no
end

set -g HEROWS5 (__t9_hexentry_rows)
# hdr + buf + blank + swatch(4) + blank + legend = 9 content rows, plus the
# top and bottom border rows = 11. ("top+8+bottom" undercounted the content
# by one row — the two blank spacer rows are each their own row, not one
# shared blank — this repo fixed the same class of off-by-one label at a2f2218.)
t "hexentry paints the expected row count (top+9+bottom)" 11 (count $HEROWS5)
# The direct discriminator for a reintroduced trailing newline after the last
# row — see __t9_hexentry_no_trailing_nl for why it checks the untouched raw
# capture rather than $HEROWS5 (this extraction pipeline can't safely surface
# that signal — see __t9_hexentry_rows' own comment on why).
t "hexentry has no trailing empty row (top-border-scroll defect class)" no (__t9_hexentry_no_trailing_nl)
set -g HEBAD5 0
for row in $HEROWS5
    set -l vis (__tcz_strip_sgr "$row")
    string match -qr '^[╭╰│]' -- "$vis"; or set HEBAD5 (math $HEBAD5 + 1)
    string match -qr '[╮╯│]$' -- "$vis"; or set HEBAD5 (math $HEBAD5 + 1)
    test (string length --visible -- "$vis") -eq 52; or set HEBAD5 (math $HEBAD5 + 1)
end
t "every hexentry row opens+closes on a frame glyph and is 52 cols wide" 0 $HEBAD5
t "hexentry top border carries the seed title" yes (string match -q '*seed*' -- (__tcz_strip_sgr $HEROWS5[1]); and echo yes; or echo no)

# Second width (Minor 5): IW=50 alone can't distinguish a genuinely
# parameterized fill from one where every $IW inside __tcz_thp_hexentry was
# replaced by a literal — both render identically AT 50. IW=70 (row width 72)
# is a value nothing in the function could coincidentally hardcode to and
# still pass the IW=50 checks above.
set -g HEROWS5W (__t9_hexentry_rows 70)
t "hexentry row count holds at a second width (IW=70)" 11 (count $HEROWS5W)
set -g HEBAD5W 0
for row in $HEROWS5W
    set -l vis (__tcz_strip_sgr "$row")
    test (string length --visible -- "$vis") -eq 72; or set HEBAD5W (math $HEBAD5W + 1)
end
t "every row is 72 cols wide at IW=70 (fill genuinely tracks \$IW)" 0 $HEBAD5W

eval $__t9h_real_readchar
functions -e __tcz_thp_hexentry

# named risk (same convention as the existing c/tab guards above): readkey is
# SHARED with the session switcher, so the new 't' mapping must (a) actually
# work through the real reader, not just in an eval'd fragment that presets
# $tok and bypasses it entirely, and (b) stay a safe no-op in the switcher,
# whose own dispatch must have NO case t. $POPBODY is the switcher's body,
# already captured above (picker-second-list Task 5's ⇥ guard section).
t "readkey maps 0x74 to t" t (echo -n t | __tcz_popup_readkey)
t "switcher has no case t (readkey's t token is a safe no-op there)" 0 \
    (string match -qr 'case t\b' -- "$POPBODY"; and echo 1; or echo 0)

# --- Task 5: t (from edit mode) reaches the hex editor; editing stays 1 ----------
set -g CASET5 (awk '/^            case z$/{exit} /^            case t$/{f=1} f{print}' $catfile | string collect)
t "case-t body extraction is non-empty" 1 (test -n "$CASET5"; and echo 1; or echo 0)
set -g CASET5WRAP "switch \$tok
$CASET5
end"
# __tcz_thp_hexentry is stubbed here too (a marker, not the real screen) — this
# block is about REACHABILITY (does case t call it, and only while editing),
# not about hexentry's own content, which the block above already covers.
function __tcz_thp_hexentry --description 'test stub: records that it was reached'
    set -g __t9_hexentry_called 1
end
function __t9_caset --argument-names editing --description 'eval the REAL case-t arm against a seeded editing flag. Prints "<reached 0|1> <editing>" — editing is read back out so a future regression that clears it around the hexentry call is caught, not just assumed.'
    set -g __t9_hexentry_called 0
    set -l tok t
    eval $CASET5WRAP
    printf '%s %s\n' $__t9_hexentry_called $editing
end
t "case t: editing=1 opens the hex editor, editing stays 1" "1 1" (__t9_caset 1)
t "case t: editing=0 is a no-op" "0 0" (__t9_caset 0)
functions -e __tcz_thp_hexentry

# --- Task 5 (Step 4b): tab is gated while editing --------------------------------
# Task 4 review Minor, folded into this task: case tab was not gated by editing,
# so ⇥ mid-edit moved focus to the second list while editing still owned ↑↓/←→ —
# the state row drew as selected but arrows kept moving the RGB channel, ⏎ exited
# edit mode instead of acting on the state row, and b (itself focus-gated) could
# no longer reach back to close it. Recoverable in one keypress, hence Minor, but
# the fix is one line and this task is already in the same dispatch.
set -g CASETAB5 (awk '/^            case a$/{exit} /^            case tab$/{f=1} f{print}' $catfile | string collect)
t "case-tab body extraction is non-empty" 1 (test -n "$CASETAB5"; and echo 1; or echo 0)
set -g CASETAB5WRAP "switch \$tok
$CASETAB5
end"
function __t9_casetab --argument-names editing focus --description 'eval the REAL case-tab arm against a seeded editing/focus pair. Prints the resulting focus.'
    set -l tok tab
    set -l flashfield START
    eval $CASETAB5WRAP
    echo $focus
end
t "case tab: editing=1 cannot change focus away from list" list (__t9_casetab 1 list)
t "case tab: editing=1 cannot change focus away from state" state (__t9_casetab 1 state)
t "case tab: editing=0 still toggles list->state (non-regression)" state (__t9_casetab 0 list)
t "case tab: editing=0 still toggles state->list (non-regression)" list (__t9_casetab 0 state)

# =====================================================================
# drop-autoapply-debounce-seed Task 2: a channel keypress costs a redraw and
# NOTHING else. picker-seed-section Task 6 (superseded here) had a channel
# keypress recompute the cursor's OWN scheme inline (~40ms) on top of the
# redraw; the user tried the resulting build live and found even that felt
# sluggish stacked on the frame cost, and asked to debounce the seed
# entirely instead — zero palette work until input actually pauses. The
# batch (all visible strips + the anchor row) still runs once, but only
# after a 700ms settle poll (was 500ms).
# =====================================================================
set -l catfile $plugindir/functions/tmux-categorize.fish

# --- Step 1: the per-keystroke palette recompute is gone -------------------------
# picker-seed-section Task 6 added a third call site (a direct per-keystroke
# recompute in case left/right); drop-autoapply-debounce-seed Task 2 removes
# it outright, back to the original 2 (the batch reload and the anchor).
set -g EB6 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$EB6"; and echo 1; or echo 0)
# Count call sites rather than pattern-matching across lines. A multiline regex over
# a 700-line body is fragile and hard to prove non-vacuous; a count is neither.
t "picker back to exactly 2 palette call sites" 2 (string match -ra '__tmux_lives_theme_palette ' -- "$EB6" | count)
# Perf fence retained: one palette call must stay well under a redraw budget —
# still relevant to the batch's own cost, just no longer paid per keystroke.
set -g T6A (date +%s%N)
__tmux_lives_theme_palette '#5f772b' amber bar derived 0 >/dev/null
set -g T6B (date +%s%N)
t "one palette is under 150ms" yes (test (math "($T6B - $T6A) / 1000000") -lt 150; and echo yes; or echo no)

# --- Step 4b: strengthen the drain invariant --------------------------------------
# The suite pins the drain-loop count by exact literal pattern (1 with a literal
# `time 0`, 1 with `time $gap` — see :1448/:1456 above; picker-legibility-
# autoapply Task 6 took the literal-`time 0` count from 2 to 1 when it deleted
# __tcz_thp_sliders' own gap-less drain), which cannot see a NEW drain that
# omits the mandatory in-loop stty reassertion under some OTHER pattern (e.g.
# a literal `time 1`). A relative invariant closes that class: of the
# picker's 3 `while true` loops, exactly 2 are immediately followed, on
# their own next line, by SOME in-loop `stty min 0 time ...` reassertion — the
# exception is the main event loop, which does its own timed read further down
# its body, not on the line right after `while true`. (Both counts moved
# 4->3 / 3->2 with the sliders deletion; the invariant itself — total minus
# safe — stays 1, verified directly rather than assumed.)
set -l wt_total (count (string match -ar 'while true' -- (string split \n -- "$EB6")))
set -l wt_safe (string match -a -r 'while true(?=\n\s+stty min 0 time )' -- "$EB6" | count)
t "drain invariant: exactly one while-true loop (the main event loop) lacks an immediate in-loop stty reassertion" 1 (math "$wt_total - $wt_safe")

# --- Step 3 + 4: extract the (Task-6-updated) left/right arm and the flashfield-
# timeout settle block, and drive both for real via eval against a throwaway
# scope. eval, not source: source opens its own local scope, so a `set -l`
# inside would not survive the call returning (same rationale as $ARROW9WRAP
# above). Both extractions are content-anchored, not line-numbered, so later
# tasks' line drift is safe.
# fix round 1 (Minor 1): non-empty alone cannot see the inverse of the
# vacuity class this branch has hit repeatedly — if an exit anchor ever
# drifted (renamed, deleted), awk's range would run to literal EOF instead
# of stopping: still non-empty, but silently wrong (everything after the
# start, including every later case arm and the picker's own teardown
# calls). `f &&` before the exit test (rather than an unconditional exit
# pattern) additionally guards against the exit text ever matching BEFORE
# the start anchor is seen — not a live risk today (both anchors are
# verified unique at their indentation), but it costs nothing and is the
# same defensive shape used to catch the accidental-anchor-capture class
# elsewhere in this file. Both anchors' non-empty checks are paired with a
# negative-containment check against content known to sit well past the
# intended boundary, so a runaway extraction fails loudly instead of
# silently overrunning.
set -g ARROWLR6 (awk '/^            case left right$/{f=1} f && /^            case m$/{exit} f{print}' $catfile | string collect)
t "left/right arm extraction is non-empty (task 6)" 1 (test -n "$ARROWLR6"; and echo 1; or echo 0)
t "left/right arm extraction stopped before case m (did not run to EOF)" 0 (string match -q '*case m*' -- "$ARROWLR6"; and echo 1; or echo 0)
t "left/right arm extraction did not run all the way to the picker's teardown" 0 (string match -q '*functions -e __tcz_thp_reload*' -- "$ARROWLR6"; and echo 1; or echo 0)
set -g ARROWLR6WRAP "switch \$tok
$ARROWLR6
end"
# The flashfield-timeout block ("has input settled?") sits between the frame
# draw and the main switch; `set -l tok` through the line before `switch $tok`
# is unique in the file at this indentation.
set -g SETTLE6 (awk '/^        set -l tok$/{f=1} f && /^        switch \$tok$/{exit} f{print}' $catfile | string collect)
t "settle-block extraction is non-empty (task 6)" 1 (test -n "$SETTLE6"; and echo 1; or echo 0)
t "settle-block extraction stopped before the main switch (did not run to EOF)" 0 (string match -q '*case m*' -- "$SETTLE6"; and echo 1; or echo 0)
t "settle-block extraction did not run all the way to the picker's teardown" 0 (string match -q '*functions -e __tcz_thp_reload*' -- "$SETTLE6"; and echo 1; or echo 0)
# drop-autoapply-debounce-seed Task 2: pin the debounce VALUE, not merely
# that some stty reassertion exists — the drain-invariant guard above (and
# Task 4's DR4 below) only count occurrences of "stty min 0 time", which
# would pass just as happily on a `time 5` -> `time 10` slip as on the
# intended `time 5` -> `time 7` move. A literal substring on the extracted
# block is exact: "time 7 2>/dev/null" cannot also match "time 70 ..." or
# "time 5 ...", so this is sensitive to the actual tenths-of-a-second value.
t "settle poll is the new 700ms value (time 7)" 1 (string match -q '*stty min 0 time 7 2>/dev/null*' -- "$SETTLE6"; and echo 1; or echo 0)
t "settle poll is no longer the old 500ms value (time 5)" 0 (string match -q '*stty min 0 time 5 2>/dev/null*' -- "$SETTLE6"; and echo 1; or echo 0)

# Stub __tcz_popup_readkey (queue-based, same convention as $ARROW9WRAP's own
# harness above) and stty (no-op — no real tty to assert on under the
# harness) for the duration of these two arms' tests; both are restored below.
set -g __t6_real_readkey (functions __tcz_popup_readkey | string collect)
function __tcz_popup_readkey --description 'test stub (picker-seed-section Task 6): pops the next token off $__t6_rkq each call, "other" once exhausted.'
    if test (count $__t6_rkq) -gt 0
        echo $__t6_rkq[1]
        set -g __t6_rkq $__t6_rkq[2..-1]
    else
        echo other
    end
end
function stty
    # no-op: same rationale as the $ARROW9WRAP harness above — the extracted
    # arms toggle blocking mode around a scripted read, irrelevant here.
end
# __tcz_thp_reload stubbed as a call counter — the Step 3 discriminator IS
# that the per-keystroke path must NOT call it (a mistaken implementation
# that called the batch every keystroke would still move the cursor row
# correctly, so only a call-count assertion catches that class).
set -g __t6_reload_calls 0
function __tcz_thp_reload --description 'test stub (picker-seed-section Task 6): counts calls instead of recomputing the batch.'
    set -g __t6_reload_calls (math $__t6_reload_calls + 1)
end

# __tmux_lives_theme_palette ALSO stubbed as a call counter here — this IS
# the Task 2 discriminator: a channel keypress must cost ZERO palette calls,
# not merely skip the batch reload. A mistaken implementation that still
# recomputed the cursor row inline would leave pals[1] looking plausible
# while still failing this count, which is why it is a dedicated counter and
# not inferred from pals[1] alone. The real engine implementation is
# captured first and restored immediately after the two assertion blocks
# below (RES6A/RES6B), before anything downstream needs a real result.
set -g __t6_real_palette (functions __tmux_lives_theme_palette | string collect)
t "captured the real engine palette function before stubbing it" 1 (test -n "$__t6_real_palette"; and echo 1; or echo 0)
set -g __t6_pal_calls 0
function __tmux_lives_theme_palette --description 'test stub (drop-autoapply-debounce-seed Task 2): counts calls instead of computing a palette.'
    set -g __t6_pal_calls (math $__t6_pal_calls + 1)
end

function __t6_arrow --argument-names tok seedhex --description 'eval the REAL (Task-2-updated) case left/right arm against a throwaway scope seeded with one real catalog recipe (mono|bar|derived) at sel=0/pi=1, editing=1, chan=1 fixed (the arm is a no-op at editing=0, already covered by Task 4/5 tests, not this task''s concern). Trailing argv seeds the readkey queue a held key would drain — a burst of "right right" simulates two more autorepeat presses beyond the initial one. Prints "<pals[1]>\x1e<flashfield>\x1e<seed>\x1e<reload_calls>\x1e<seeddirty>\x1e<pal_calls>".'
    set -l editing 1
    set -l chan 1
    set -l sel 0
    set -l seedr 0
    set -l seedg 0
    set -l seedb 0
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $seedhex)
    if test (count $m) -eq 3
        set seedr (math "0x$m[1]")
        set seedg (math "0x$m[2]")
        set seedb (math "0x$m[3]")
    end
    set -l seed $seedhex
    set -l phase 0
    set -l flashfield ''
    set -l seeddirty 0
    set -l recipes 'mono|bar|derived'
    set -l pals 'stale stale stale stale stale stale stale'
    set -l fgs '#000000'
    set -l tabsfgs '#000000'
    set -g __t6_reload_calls 0
    set -g __t6_pal_calls 0
    set -g __t6_rkq $argv[3..-1]
    eval $ARROWLR6WRAP
    printf '%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\n' "$pals[1]" "$flashfield" "$seed" "$__t6_reload_calls" "$seeddirty" "$__t6_pal_calls"
end

set -g RES6A (__t6_arrow right '#000000')
set -g f6a (string split \x1e -- $RES6A)
# drop-autoapply-debounce-seed Task 2: the cursor's own scheme strip is no
# longer touched by a channel keypress at all — it stays on the stale
# placeholder until a real batch reload runs (the settle tests below).
t "channel edit leaves the scheme strip untouched (stale placeholder survives)" yes (test "$f6a[1]" = 'stale stale stale stale stale stale stale'; and echo yes; or echo no)
t "channel edit sets flashfield to seed (drives the settle timeout below)" seed "$f6a[2]"
t "channel edit's seed reflects the +8 delta (the redraw-only part still works)" '#080000' "$f6a[3]"
t "channel edit does not call the batch reload" 0 "$f6a[4]"
# fix round 1 (Important 1, still true): the batch is owed via a DEDICATED
# flag, not flashfield alone — flashfield is cleared by other arms (m/z/tab)
# that have no idea it also carries this obligation, which would otherwise
# silently cancel the deferred reload+reanchor. Assert the dedicated flag
# directly.
t "channel edit marks the seed dirty (independent of flashfield)" 1 "$f6a[5]"
# THE discriminator: zero palette calls, not just "no batch reload call" —
# a mistaken implementation could skip the batch while still recomputing the
# cursor row inline, which only this count catches.
t "channel edit calls __tmux_lives_theme_palette exactly 0 times" 0 "$f6a[6]"

# A held key: the drain now DISCARDS queued presses rather than summing them
# (picker-responsiveness Task 5 — see the R_LR_COALESCE test above for the
# same fix on the $ARROW9WRAP harness), and the arm still costs zero palette
# calls regardless of burst size — the whole point of debouncing is that a
# hold is exactly as cheap as a single tap.
set -g RES6B (__t6_arrow right '#000000' right right)
set -g f6b (string split \x1e -- $RES6B)
t "a 3-press coalesced burst still moves only +8, not +24" '#080000' "$f6b[3]"
t "a coalesced burst still leaves the scheme strip untouched" yes (test "$f6b[1]" = 'stale stale stale stale stale stale stale'; and echo yes; or echo no)
t "a coalesced burst still does not call the batch reload" 0 "$f6b[4]"
t "a coalesced burst also marks the seed dirty" 1 "$f6b[5]"
t "a coalesced burst still calls __tmux_lives_theme_palette exactly 0 times" 0 "$f6b[6]"

# Restore the real engine palette function before anything downstream needs
# a real result — the settle-block/BAND/e2e tests further down all depend on
# it, via the real reload/reanchor once those are restored in their own turn.
functions -e __tmux_lives_theme_palette
eval $__t6_real_palette

# --- Step 4: input settling triggers exactly one batch reload + reanchor --------
set -g __t6_reanchor_calls 0
function __tcz_thp_reanchor --description 'test stub (picker-seed-section Task 6): counts calls instead of recomputing the anchor row.'
    set -g __t6_reanchor_calls (math $__t6_reanchor_calls + 1)
end
function __t6_settle --argument-names flash dirty queued --description 'eval the REAL flashfield-timeout block (Step 4, fix round 1) with $flashfield and $seeddirty seeded independently (fix round 1 made them independent flags on purpose) and a stubbed readkey returning <queued>. Wrapped in a bounded for-loop, not source: the extracted body itself calls `continue` on the timeout path, which is only valid inside a loop, and a SECOND pass is expected on a genuine timeout with a still-nonempty flashfield-or-seeddirty condition already false (both cleared by the first pass), the block falls to its own else-branch real read — bounded so a coding mistake cannot spin forever. Prints "<reload_calls> <reanchor_calls> <flashfield> <seeddirty>".'
    set -l flashfield $flash
    set -l seeddirty $dirty
    set -l tok ''
    set -g __t6_reload_calls 0
    set -g __t6_reanchor_calls 0
    set -g __t6_rkq $queued
    for _pass in 1 2 3 4 5
        eval $SETTLE6
        break
    end
    printf '%s %s %s %s\n' $__t6_reload_calls $__t6_reanchor_calls "$flashfield" "$seeddirty"
end

set -g RES6T (__t6_settle seed 1 timeout)
set -g f6t (string split ' ' -- $RES6T)
t "settle (no key within ~0.7s) calls the batch reload exactly once" 1 "$f6t[1]"
t "settle (no key within ~0.7s) calls reanchor exactly once"         1 "$f6t[2]"
t "settle clears flashfield"                                         '' "$f6t[3]"
t "settle clears seeddirty"                                          0 "$f6t[4]"

# fix round 1 (Important 1) — the core of the fix: seeddirty alone, WITHOUT
# flashfield, must still drive the timed poll and fire the batch. This is
# exactly the state m/z/tab leave things in (they clear flashfield but never
# touch seeddirty) — before the fix this branch was gated on flashfield
# alone, so an empty flashfield meant no timed poll ever ran again and the
# owed batch was lost until another seed edit.
set -g RES6D (__t6_settle '' 1 timeout)
set -g f6d (string split ' ' -- $RES6D)
t "settle fires on seeddirty alone (flashfield already empty)" 1 "$f6d[1]"
t "settle's reanchor also fires on seeddirty alone"             1 "$f6d[2]"
t "settle clears seeddirty even when flashfield started empty"  0 "$f6d[4]"

# Negative control: neither flag set -> no timed poll at all (falls to a
# blocking read instead), so the batch cannot fire. Queueing "timeout" here
# is harmless noise (the stub returns it as if it were a real keystroke); the
# only thing under test is that reload/reanchor stay at 0.
set -g RES6N (__t6_settle '' 0 timeout)
set -g f6n (string split ' ' -- $RES6N)
t "settle does nothing when neither flashfield nor seeddirty is set" "0 0" "$f6n[1] $f6n[2]"

set -g RES6K (__t6_settle seed 1 b)
set -g f6k (string split ' ' -- $RES6K)
t "a real key within the flash window does not call the batch reload" 0 "$f6k[1]"
t "a real key within the flash window does not call reanchor"         0 "$f6k[2]"
t "a real key within the flash window leaves flashfield alone (dispatch handles it normally)" seed "$f6k[3]"
t "a real key within the flash window leaves seeddirty owed (dispatch handles it normally)" 1 "$f6k[4]"

# Restore reload/reanchor to their REAL implementations for the remaining
# tests below — readkey/stty stay stubbed a little longer (the end-to-end
# test just below still needs them for the two extracted arms' own internal
# drains); both are restored at the very end of this section.
functions -e __tcz_thp_reload
eval $RB7
functions -e __tcz_thp_reanchor
set -g RA6 (awk '/function __tcz_thp_reanchor/,/^    end$/' $catfile | string collect)
t "reanchor body extraction is non-empty (task 6)" 1 (test -n "$RA6"; and echo 1; or echo 0)
eval $RA6

# --- Step 4: the current row's rendered band actually changes after a seed edit --
# Behavioural, not a grep for the call: __tcz_thp_reanchor exists precisely so
# the current row's band tracks a changed seed (its own comment says so). Prove
# it END TO END, no stubs on reload/reanchor this time — the REAL case
# left/right arm followed by the REAL flashfield-timeout settle block, exactly
# as the picker sequences them across two loop iterations — then render the
# SAME 15-col strip __tcz_theme_picker itself builds at its current-row draw
# site (__tcz_thp_cells "$anchpal") and diff the actual ANSI text against what
# the un-edited seed produces.
function __t6_band --argument-names seedhex --description 'eval the REAL __tcz_thp_reanchor against a fixed anchor recipe (mono|bar|derived, phase 0) for the given seed directly (no dispatch), then render the current-row''s band exactly as __tcz_theme_picker does at its own current-row draw site (~line 2190). Prints the rendered (ANSI) 15-col strip. Used both as the end-to-end test''s "before" baseline and standalone below to confirm reanchor itself is seed-sensitive.'
    set -l seed $seedhex
    set -l anch_scheme mono
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    __tcz_thp_reanchor
    __tcz_thp_cells "$anchpal"
end
function __t6_e2e --argument-names old_seed --description 'end to end: the REAL case left/right arm moves the seed one channel-press (chan=1, +8), then the REAL flashfield-timeout block runs a genuine settle (queued token "timeout") — no reload/reanchor stubs, both real. Anchor recipe fixed at mono|bar|derived/phase 0, matching the anchor snapshot the picker takes at open. Prints the rendered current-row band AFTER settling.'
    set -l editing 1
    set -l chan 1
    set -l sel 0
    set -l seedr 0
    set -l seedg 0
    set -l seedb 0
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $old_seed)
    if test (count $m) -eq 3
        set seedr (math "0x$m[1]")
        set seedg (math "0x$m[2]")
        set seedb (math "0x$m[3]")
    end
    set -l seed $old_seed
    set -l phase 0
    set -l flashfield ''
    set -l seeddirty 0
    set -l recipes 'mono|bar|derived'
    set -l pals 'stale stale stale stale stale stale stale'
    set -l fgs '#000000'
    set -l tabsfgs '#000000'
    set -l anch_scheme mono
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    set -l tok right
    set -g __t6_rkq
    eval $ARROWLR6WRAP
    set -l tok ''
    set -g __t6_rkq timeout
    for _pass in 1 2 3 4 5
        eval $SETTLE6
        break
    end
    __tcz_thp_cells "$anchpal"
end
set -g BAND6BEFORE (__t6_band '#000000')
set -g BAND6AFTER (__t6_e2e '#000000')
set -g BAND6EXPECTED (__t6_band '#080000')
t "end-to-end band is non-empty after a real channel edit + settle" yes (test -n "$BAND6AFTER"; and echo yes; or echo no)
t "end-to-end: the current row's band actually changes after a live seed edit settles" no (test "$BAND6BEFORE" = "$BAND6AFTER"; and echo yes; or echo no)
# The "differs from before" check above is defeatable: a settle path that never
# reaches reanchor at all would leave $anchpal empty, and __tcz_thp_cells("")
# degrades to a 2-char blank strip (measured) — trivially different from the
# real 154-char band above, but for the wrong reason. Pin the EXACT expected
# band instead: a direct reanchor call for the seed the edit should have
# produced (#000000 + one chan-1 press = #080000, same arithmetic case-left/
# right itself performs).
t "end-to-end: the settled band matches a direct reanchor call for the edited seed" "$BAND6EXPECTED" "$BAND6AFTER"

set -g BAND6A (__t6_band '#5f772b')
set -g BAND6B (__t6_band '#772b5f')
t "reanchor's band is non-empty for a real seed" yes (test -n "$BAND6A"; and echo yes; or echo no)
t "current row's rendered band changes after the seed changes" no (test "$BAND6A" = "$BAND6B"; and echo yes; or echo no)

# --- Step 4 fix round 1 (Important 1): a follow-up keypress must not cancel
# the deferred batch -----------------------------------------------------
# Reviewer repro: → m, → z, and → b ⇥ all left the current row's band stale
# for the rest of the picker session, because flashfield — cleared by these
# three unrelated arms with no idea it also carried a recompute obligation —
# used to be the SOLE signal gating the settle path. seeddirty (this fix
# round) is untouched by all three, so the deferred batch survives them.
# Extract the arms these sequences dispatch through and drive them for real
# — reload/reanchor both real (not stubbed) here, same as the base
# end-to-end test above, since m/z's own pre-existing reload call needs the
# real catalog to do anything meaningful.
set -g CASEM6   (awk '/^            case b$/{exit} /^            case m$/{f=1} f{print}' $catfile | string collect)
set -g CASEB6   (awk '/^            case t$/{exit} /^            case b$/{f=1} f{print}' $catfile | string collect)
set -g CASEZ6   (awk '/^            case tab$/{exit} /^            case z$/{f=1} f{print}' $catfile | string collect)
set -g CASETAB6 (awk '/^            case a$/{exit} /^            case tab$/{f=1} f{print}' $catfile | string collect)
# case cancel (esc/q) is a distinct case label from case a/enter/m/b/z/tab, and
# "case cancel" itself is NOT unique in the file (the switcher __tcz_popup has
# its own, earlier one) — a plain start/exit awk pair the way CASETAB6 does it
# would risk landing on the wrong one. Disambiguate with a two-flag state
# machine: only start capturing once "case a" (unique in the file) has already
# been seen, so the "case cancel" that trips f=1 is guaranteed to be this
# picker's own.
set -g CASECANCEL6 (awk '/^            case a$/{seen=1} seen && /^            case cancel$/{f=1} f && /^        end$/{exit} f{print}' $catfile | string collect)
t "case-m body extraction is non-empty (task 6)"      1 (test -n "$CASEM6"; and echo 1; or echo 0)
t "case-b body extraction is non-empty (task 6)"      1 (test -n "$CASEB6"; and echo 1; or echo 0)
t "case-z body extraction is non-empty (task 6)"      1 (test -n "$CASEZ6"; and echo 1; or echo 0)
t "case-tab body extraction is non-empty (task 6)"    1 (test -n "$CASETAB6"; and echo 1; or echo 0)
t "case-cancel body extraction is non-empty (task 6)" 1 (test -n "$CASECANCEL6"; and echo 1; or echo 0)
t "case-cancel extraction is the edit-esc arm, not the switchers own cancel" 1 (string match -q '*BEGIN edit-esc*' -- "$CASECANCEL6"; and echo 1; or echo 0)
set -g SEQ6WRAP "switch \$tok
$ARROWLR6
$CASEM6
$CASEB6
$CASEZ6
$CASETAB6
$CASECANCEL6
end"

function __t6_seq --argument-names old_seed --description 'end to end (fix round 1): the REAL case left/right arm (one chan-1 press, +8) followed by the REAL follow-up arm(s) named in argv[2..] ("m"/"z"/"b"/"tab", each dispatched via $SEQ6WRAP), then the REAL flashfield-timeout settle block run to a genuine timeout — reload/reanchor both real. Anchor recipe fixed at mono|bar|derived/phase 0, matching the anchor snapshot the picker takes at open. rows/STATIC_IDLE/STATIC_EDIT are seeded so a dispatched b (which recomputes WIN — picker-legibility-autoapply Task 3) does not spray a math error against undefined locals. Prints the rendered current-row band AFTER the whole sequence settles.'
    set -l editing 1
    set -l chan 1
    set -l sel 0
    set -l focus list
    set -l editseed ''
    set -l rows 52
    set -l STATIC_IDLE $STATIC9I
    set -l STATIC_EDIT $STATIC9E
    set -l seedr 0
    set -l seedg 0
    set -l seedb 0
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $old_seed)
    if test (count $m) -eq 3
        set seedr (math "0x$m[1]")
        set seedg (math "0x$m[2]")
        set seedb (math "0x$m[3]")
    end
    set -l seed $old_seed
    set -l phase 0
    set -l expanded 0
    set -l flashfield ''
    set -l seeddirty 0
    set -l recipes 'mono|bar|derived'
    set -l toks 'mono soft'
    set -l pals 'stale stale stale stale stale stale stale'
    set -l fgs '#000000'
    set -l tabsfgs '#000000'
    set -l n 1
    set -l ndefault 1
    set -l anch_scheme mono
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    # Step 1: a real channel edit (chan=1, +8) — the seed is now dirty.
    set -l tok right
    set -g __t6_rkq
    eval $SEQ6WRAP
    # Step 2: the follow-up sequence, one dispatched key per argv element.
    for k in $argv[2..-1]
        set tok $k
        set -g __t6_rkq
        eval $SEQ6WRAP
    end
    # Step 3: settle — a genuine timeout, queued once.
    set tok ''
    set -g __t6_rkq timeout
    for _pass in 1 2 3 4 5
        eval $SETTLE6
        break
    end
    __tcz_thp_cells "$anchpal"
end

# Every sequence starts from the same seed (#000000) and the same single
# chan-1 press (+8), so the fresh band any of them should settle to is the
# SAME one $BAND6EXPECTED already pins above — reused, not recomputed.
set -g SEQ6_M    (__t6_seq '#000000' m)
set -g SEQ6_Z    (__t6_seq '#000000' z)
set -g SEQ6_BTAB (__t6_seq '#000000' b tab)
t "→ m then settle: the current row's band ends up fresh, not stale"      "$BAND6EXPECTED" "$SEQ6_M"
t "→ z then settle: the current row's band ends up fresh, not stale"      "$BAND6EXPECTED" "$SEQ6_Z"
t "→ b ⇥ then settle: the current row's band ends up fresh, not stale"    "$BAND6EXPECTED" "$SEQ6_BTAB"

# --- final review Finding 1: esc while editing must re-arm the deferred
# recompute, not just revert $seed --------------------------------------
# None of m/z/b-tab above dispatch through case cancel (it is its own case
# label — a different arm entirely), so they cannot cover this. The pre-fix
# edit-esc arm reverted $seed to $editseed but touched neither seeddirty nor
# flashfield's settle-gate consumer, so the settle block's `if test
# "$seeddirty" = 1` never fired and every strip kept rendering the ABANDONED
# edited seed for the rest of the session even though $seed itself had
# reverted. editseed is pre-seeded to old_seed here (mirroring what the real
# `b` arm captures before any channel move), so the revert has a real prior
# value to land back on.
function __t6_esc_seq --argument-names old_seed --description 'end to end (Finding 1 fix): b →→→→ settle esc settle, matching the reviewers own repro row. A single right-then-immediate-esc is NOT enough to expose this bug: the arrow arm sets seeddirty itself, and esc pre-fix leaves it untouched (not cleared, not re-armed) — so a settle right after esc alone would fire "by accident" off the arrow press own flag and hide the defect. The real failure needs seeddirty to have already been DISCHARGED (cleared to 0 by a real settle) before esc runs, exactly as it is after a hexentry commit or a prior settle in the live repro. Sequence: (1) one real channel edit (chan=1, +8) — seed becomes the EDITED value, seeddirty=1; (2) a real settle — batch reload/reanchor run for the EDITED seed, seeddirty clears to 0; (3) the REAL case-cancel arm (tok=cancel, the token both esc and q map to) reverts $seed to $editseed=old_seed; (4) a second real settle. Pre-fix, step 4 settle gate is false (both flags already clear) so it never recomputes — the abandoned EDITED seeds palette survives. Post-fix, the case-cancel arm re-arms seeddirty in step 3, so step 4 recomputes for the REVERTED seed. Prints "<current-row band>\x1e<first scheme strips pals entry>" after both settles.'
    set -l editing 1
    set -l chan 1
    set -l sel 0
    set -l focus list
    set -l editseed $old_seed
    set -l rows 52
    set -l STATIC_IDLE $STATIC9I
    set -l STATIC_EDIT $STATIC9E
    set -l seedr 0
    set -l seedg 0
    set -l seedb 0
    set -l m (string match -rg '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$' -- $old_seed)
    if test (count $m) -eq 3
        set seedr (math "0x$m[1]")
        set seedg (math "0x$m[2]")
        set seedb (math "0x$m[3]")
    end
    set -l seed $old_seed
    set -l phase 0
    set -l expanded 0
    set -l flashfield ''
    set -l seeddirty 0
    set -l recipes 'mono|bar|derived'
    set -l toks 'mono soft'
    set -l pals 'stale stale stale stale stale stale stale'
    set -l fgs '#000000'
    set -l tabsfgs '#000000'
    set -l n 1
    set -l ndefault 1
    set -l anch_scheme mono
    set -l anch_place bar
    set -l anch_mode derived
    set -l anch_phase 0
    set -l anchpal ''
    set -l anchfg '#f5f5f5'
    set -l anchtabsfg '#f5f5f5'
    # Step 1: a real channel edit (chan=1, +8) — the seed becomes dirty.
    set -l tok right
    set -g __t6_rkq
    eval $SEQ6WRAP
    # Step 2: settle — discharges the batch for the EDITED seed, clearing
    # seeddirty back to 0 (exactly what a hexentry commit or an earlier
    # settle already does before the esc in the live repro).
    set tok ''
    set -g __t6_rkq timeout
    for _pass in 1 2 3 4 5
        eval $SETTLE6
        break
    end
    # Step 3: esc while editing, with seeddirty already discharged — the fix
    # under test.
    set tok cancel
    set -g __t6_rkq
    eval $SEQ6WRAP
    # Step 4: settle again — a genuine timeout, queued once.
    set tok ''
    set -g __t6_rkq timeout
    for _pass in 1 2 3 4 5
        eval $SETTLE6
        break
    end
    printf '%s\x1e%s\n' (__tcz_thp_cells "$anchpal") "$pals[1]"
end

function __t6_pal1 --argument-names seedhex --description 'direct control (Finding 1 fix): the REAL __tcz_thp_reload for the given seed (phase 0, unexpanded), no dispatch — returns the first catalog rows rendered palette (pals[1]), the scheme-strip counterpart to __t6_band, above, own current-row check.'
    set -l seed $seedhex
    set -l phase 0
    set -l expanded 0
    set -l toks
    set -l pals
    set -l fgs
    set -l tabsfgs
    set -l recipes
    __tcz_thp_reload
    echo $pals[1]
end

set -g SEQ6_ESC (__t6_esc_seq '#000000')
set -g f6esc (string split \x1e -- $SEQ6_ESC)
t "→ esc then settle: the current row's band reverts to the pre-edit seed, not the abandoned edit" "$BAND6BEFORE" "$f6esc[1]"
set -g expected6esc (__t6_pal1 '#000000')
t "→ esc then settle: a scheme strip also reverts to the pre-edit seed, not the abandoned edit" "$expected6esc" "$f6esc[2]"

# Restore what this section stubbed.
eval $__t6_real_readkey
functions -e stty
functions -e __tcz_thp_reanchor

# --- picker-legibility-autoapply Task 5, RETIRED by drop-autoapply-debounce-seed
# Task 1: auto-apply on dwell is cancelled outright ------------------------
# The user tried d68deb0 live and reported it "wayyyy too much… everything
# is so lacking in responsivity" — their instruction was to cancel the
# feature, not default it off. These assertions claim the machinery is
# ABSENT. That inverts the usual TDD shape: every one of them FAILS against
# the pre-removal source (case 41 mapped to A in readkey's outer switch,
# case A existed and wrote tmux_lives_theme_autoapply, applydue was armed
# by the movement/m/z arms and consumed by the settle branch) and only
# PASSES once the removal below lands.

# A (byte 0x41) must no longer be mapped in readkey's OUTER switch — only
# the ESC-branch `case 41; echo up` (0x41 as the final byte of ESC [ A, the
# up arrow) may remain, and a bare A now falls through to the switch's own
# default, other.
t "readkey no longer maps 0x41 to A — falls through to other" other (printf A | __tcz_popup_readkey)
# ESC [ A must still resolve to up — the discriminator that this removal did
# not collaterally touch the ESC-branch's own, separate case 41.
t "ESC [ A still resolves to up (the ESC-branch case 41 is untouched)" up (printf '\x1b[A' | __tcz_popup_readkey)
# Exactly one case 41 should remain inside __tcz_popup_readkey itself (the
# ESC-branch up-arrow) — two would mean the outer-switch mapping is back;
# zero would mean the up arrow broke too.
t "readkey has exactly one case 41 left (the ESC-branch up arrow)" 1 (count (string match -ar 'case 41' -- (functions __tcz_popup_readkey | string collect)))

set -g PB9 (functions __tcz_theme_picker | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB9"; and echo 1; or echo 0)
t "picker has no case A arm" 0 (string match -qr 'case A\b' -- "$PB9"; and echo 1; or echo 0)
t "picker no longer reads or writes the autoapply universal" 0 (string match -q '*tmux_lives_theme_autoapply*' -- "$PB9"; and echo 1; or echo 0)
t "picker no longer declares an autoapply local" 0 (string match -ra 'set -l autoapply\b' -- "$PB9" | count)
t "picker no longer has an applydue variable anywhere" 0 (string match -ra 'applydue' -- "$PB9" | count)
# The browsing legend no longer advertises A auto (the tenth pair is gone —
# see the "browsing legend is 3 rows" arithmetic assertions above).
t "browsing legend no longer names A auto" 0 (string match -ra "'A' auto" -- "$PB9" | count)
# fix round 1 (Important 3): the four previewed/note assertions above all
# grep the FUNCTION body, not case a's own reachable span — proven
# insufficient with two one-token mutations, neither of which touches the
# function's own text: (a) replacing case a's body with `true` (the `a` key
# silently dead) and (b) dropping `--no-scope-shadowing` off
# __tcz_thp_apply_now's definition (the `a` arm, its only caller, becomes
# erroring no-ops, since the function then gets its own fresh scope and
# can no longer reach the caller's $focus/$sel/$previewed/$note at all).
t "case a calls __tcz_thp_apply_now" 1 (string match -qr '(?ms)^ *case a$\n *__tcz_thp_apply_now$' -- "$PB9"; and echo 1; or echo 0)
# Behavioural, not another grep: eval the REAL extracted function body
# ($aabody, from the "current is a live-state readout" section above) and
# call it for real, with fish/__tcz_tab_color/__tcz_recolor stubbed so no
# subprocess or live OSC emission actually fires. Checking that $previewed/
# $note change IN THE CALLER'S OWN SCOPE is what only --no-scope-shadowing
# makes possible — without it this whole block still runs, but previewed
# and note stay exactly as seeded (previewed 0 vs error, both wrong).
# tick-call-batching task 2 review fix: `fish` shadows a real BINARY, so a
# bare `functions -e fish` correctly un-shadows it (PATH resolution takes
# back over — nothing to restore). __tcz_tab_color/__tcz_recolor are
# themselves SOURCE-DEFINED fish functions with no such fallback: a bare
# `function __tcz_tab_color; ...; end` here REPLACES the real one loaded at
# this file's own `source functions/tmux-categorize.fish`, and the later
# bare `functions -e __tcz_tab_color` was found (while building the
# regression test just below) to erase that replacement into NOTHING rather
# than reveal the original — leaving both functions permanently undefined
# for the rest of this file. Pre-existing, harmless only because nothing
# after this block used to call either again; backed up and restored
# properly now, matching this file's own established convention elsewhere
# (functions -c ORIGINAL ORIGINAL_bak / functions -c ORIGINAL_bak ORIGINAL).
function fish; end
functions -c __tcz_tab_color __tcz_tab_color_apply_now_bak
function __tcz_tab_color; echo ''; end
functions -c __tcz_recolor __tcz_recolor_apply_now_bak
function __tcz_recolor; end
eval $aabody
set -l focus list
set -l sel 0
set -l seed '#5f772b'
set -l phase 0
set -l recipes 'mono|bar|derived'
set -l previewed 0
set -l note ''
__tcz_thp_apply_now
t "calling the real apply_now changes previewed in the caller (proves --no-scope-shadowing)" 1 "$previewed"
t "calling the real apply_now changes note in the caller too" 1 (test -n "$note"; and echo 1; or echo 0)
functions -e __tcz_thp_apply_now fish __tcz_tab_color __tcz_recolor
functions -c __tcz_tab_color_apply_now_bak __tcz_tab_color; functions -e __tcz_tab_color_apply_now_bak
functions -c __tcz_recolor_apply_now_bak __tcz_recolor; functions -e __tcz_recolor_apply_now_bak

# ---------------------------------------------------------------------
# CRITICAL review fix (tick-call-batching task 2): __tcz_thp_apply_and_recolor
# writes @tmux_lives_tabs_color from a fish -c CHILD, then reads it straight
# back via __tcz_tab_color to push the OSC. The theme picker's while-true
# loop is the one genuinely long-lived pass in this codebase -- __tcz_tmux_load
# never re-fires across the whole session -- so without a flush right after
# the write, a SECOND apply in the same session would read back the FIRST
# apply's memoized value: pressing `a` on one scheme then another would freeze
# the user's ShellFish/iTerm2 tab colour at the first. The stub two blocks up
# (`function __tcz_tab_color; echo ''; end`) is exactly what hid this — the
# real accessor never met the real memo there. This test uses BOTH for real,
# against a real isolated -L server, and is mutation-proven below (comment
# out the flush, confirm both new assertions go red).
#
# __tcz_thp_apply_and_recolor's fish -c child needs a REAL, config-loaded
# fish that can autoload __tmux_lives_theme_apply_live -- unlike this whole
# suite's own outer isolation guard (a throwaway XDG_CONFIG_HOME with no
# fish/conf.d in it, deliberately, so THIS process's own set -U calls never
# touch the real store), so a second, dedicated throwaway XDG_CONFIG_HOME
# with just a copy of the plugin's conf.d/tmux-lives-install.fish (NOT
# conf.d/tmux.fish -- that file's autostart/session wiring is irrelevant here
# and no top-level statement in tmux-lives-install.fish needs it; verified by
# reading the file — its only top-level line seeds a harmless math constant)
# is swapped in for the two calls only, then restored.
set -l aarsock tcz-aar-$fish_pid
set -l aarhome (mktemp -d /tmp/tcz-aar-home.XXXXXX)
mkdir -p $aarhome/fish/conf.d
cp $plugindir/conf.d/tmux-lives-install.fish $aarhome/fish/conf.d/tmux-lives-install.fish
set -l aardir /tmp/tcz-aar-shim-$fish_pid
rm -rf $aardir; mkdir -p $aardir
printf '#!/bin/bash\nexec /usr/bin/tmux -L %s "$@"\n' $aarsock > $aardir/tmux
chmod +x $aardir/tmux
command tmux -L $aarsock kill-server 2>/dev/null
for i in (seq 50)
    command tmux -L $aarsock list-sessions >/dev/null 2>&1; or break
end
command tmux -L $aarsock -f /dev/null new-session -d -s aar 2>/dev/null
sleep 0.2

set -l aar_path_save $PATH
set -l aar_xdg_save $XDG_CONFIG_HOME
set -gx PATH $aardir $PATH
set -gx XDG_CONFIG_HOME $aarhome
functions -q __tcz_tmux_flush; and __tcz_tmux_flush
__tcz_thp_apply_and_recolor '#111111' mono bar derived 0
set -l aar_first (__tcz_tab_color '')
__tcz_thp_apply_and_recolor '#222222' mono bar derived 0
set -l aar_second (__tcz_tab_color '')
set -l aar_live (command tmux -L $aarsock show -gv @tmux_lives_tabs_color 2>/dev/null)
set -gx PATH $aar_path_save
set -gx XDG_CONFIG_HOME $aar_xdg_save
command tmux -L $aarsock kill-server 2>/dev/null
rm -rf $aardir $aarhome

t "apply_and_recolor: two successive applies both actually reach the real server" 1 (test -n "$aar_first"; and test -n "$aar_second"; and echo 1; or echo 0)
t "apply_and_recolor: the second apply's read differs from the first (not stale)" yes (test "$aar_first" != "$aar_second"; and echo yes; or echo no)
t "apply_and_recolor: the second read matches the real live value, not the first" "$aar_live" "$aar_second"

# --- Task 4: edit-mode ↑↓ channel select must drain -------------------------
# The non-editing branch of `case up down pgup pgdn` already drains held
# repeats (see its own in-source comment); the editing branch (↑↓ picks the
# R/G/B channel) did not, so every autorepeat byte got its own full-frame
# rebuild. `chan` clamps at 1-3, which is why it read live as "jerk a
# couple times and then go dark until you let go".
set -l catfile $plugindir/functions/tmux-categorize.fish

# dispatcher-caught defect #1: the brief's own extraction range-matched on
# TWO bare `case` lines (`/case up down pgup pgdn/,/^            case left
# right$/`), which is not valid fish outside a switch block ("'case'
# builtin not inside of switch block") -- and `eval` still returns status 0
# on that parse error, so a plain non-empty check would PASS VACUOUSLY
# while the body underneath never ran at all. Skip the opening case line
# and stop before the closing one instead.
set -g EDITARM (awk '/^            case up down pgup pgdn$/{f=1;next} /^            case left right$/{exit} f' $catfile | string collect)
t "editarm extraction is non-empty" 1 (test -n "$EDITARM"; and echo 1; or echo 0)
t "editarm extraction does not begin with a bare case line (the range-match trap)" 0 (string match -qr '^\s*case\b' -- (string split \n -- "$EDITARM")[1]; and echo 1; or echo 0)
t "editarm extraction stopped before case left right (did not run past the arm)" 0 (string match -q '*case left right*' -- "$EDITARM"; and echo 1; or echo 0)
# Prove the extraction actually evals as a real switch-body fragment, not
# just that it is non-empty text -- the whole point of the trap above.
#
# fix (coordinator review): checking `$status` after `eval` does NOT
# discriminate here. `eval` runs its argument IN-PROCESS (no subprocess is
# forked), and fish routes a parse-time diagnostic through its own
# interpreter error channel rather than through the calling command's
# stderr fd -- confirmed directly: `eval "not_a_real_command_xyz"
# 2>$errfile` still prints the error to the real terminal and leaves the
# captured file at 0 bytes, for a broken body exactly as much as a clean
# one. The original version of this guard only asserted the probe printed
# "ok", which it did unconditionally regardless of whether the eval
# actually parsed -- fed the brief's own broken range-match extraction, it
# still printed "ok". Real fd redirection only works against a genuine
# child PROCESS, so this shells out to a throwaway `fish --no-config`
# child (a true subprocess, so `2>` on it captures real stderr) and
# asserts its captured stderr is empty. The child gets its own seed locals
# (same shape as the in-process behavioural harness below) plus stubs for
# every production function the extracted body calls: __tcz_popup_readkey,
# stty, and __tcz_thp_vismap -- the last one is needed ONLY here, since a
# --no-config child has no autoload path back into this plugin's own
# functions/ directory the way the rest of this suite (which sources it)
# does. Because the child is fully isolated, there is nothing of the
# parent's to save/restore around it, unlike the old in-process version.
function __t4_evalcheck --argument-names body --description 'run <body> as a real child fish --no-config process and print the byte count captured from its stderr -- 0 means it parsed and ran cleanly, nonzero means a parse/runtime error fired.'
    set -l scriptfile (mktemp)
    set -l errfile (mktemp)
    printf '%s\n' \
        'set -l editing 0' \
        'set -l chan 1' \
        'set -l tok up' \
        'set -l focus list' \
        'set -l sel 0' \
        'set -l sel2 0' \
        'set -l n 1' \
        'set -l WIN 1' \
        'function __tcz_popup_readkey; echo cancel; end' \
        'function stty; end' \
        'function __tcz_thp_vismap; echo 0; end' \
        >$scriptfile
    printf '%s\n' $body >>$scriptfile
    fish --no-config $scriptfile 2>$errfile
    set -l errbytes (wc -c <$errfile | string trim)
    command rm -f $scriptfile $errfile
    echo $errbytes
end
t "editarm extraction evals cleanly in a real child process (zero stderr bytes)" 0 (__t4_evalcheck "$EDITARM")
functions -e __t4_evalcheck

# dispatcher-caught defect #2: the brief's own drain-count assertion counts
# "while true" + immediate "stty min 0 time " matches across the WHOLE arm
# ($EDITARM), which already contains the NON-editing branch's own
# pre-existing, compliant drain -- so the count reads 1 before a single
# line of this task lands, and `t ... 1 $__t4_drains` PASSES VACUOUSLY
# pre-fix. Confirmed directly against the pre-fix source. Worse, once the
# editing branch gets its OWN compliant drain the arm-wide count becomes 2,
# so the brief's literal assertion (still expecting 1) would then FAIL
# post-fix -- backwards. Scope the count to the editing branch alone
# (between its own `if test "$editing" = 1` and the matching `else`) so it
# only reads a drain if THIS branch has one.
set -g EDITONLY (awk '
    /^            case up down pgup pgdn$/ {arm=1}
    arm && /^                if test "\$editing" = 1$/ {f=1; next}
    f && /^                else$/ {exit}
    f {print}
' $catfile | string collect)
t "editonly extraction is non-empty" 1 (test -n "$EDITONLY"; and echo 1; or echo 0)
t "editonly extraction stopped before the else (did not spill into the non-editing branch)" 0 (string match -q '*Drain, then move ONE row*' -- "$EDITONLY"; and echo 1; or echo 0)
set -g __t4_drains (string match -a -r 'while true(?=\n\s+stty min 0 time )' -- "$EDITONLY" | count)
t "editing branch itself has a compliant drain" 1 $__t4_drains

# Behavioural half: drive the REAL extracted arm with a stubbed reader that
# hands it a queued burst, and assert both that the burst was consumed and
# that `chan` advanced only once. Genuine discriminator: pre-fix the arm
# never reads past the first key, so the stub still has queued tokens left.
set -g __t4_queue down down down down
set -g __t4_fed 0
function __t4_readkey
    set -g __t4_fed (math $__t4_fed + 1)
    if test $__t4_fed -le (count $__t4_queue)
        echo $__t4_queue[$__t4_fed]
    else
        echo cancel
    end
end
function __t4_run
    # dispatcher-caught defect #3: `functions --copy OLD NEW` errors if NEW
    # already exists ("Function 'NEW' already exists. Cannot create copy of
    # 'OLD'") -- confirmed directly. The brief's harness copied the stub
    # straight over the still-live __tcz_popup_readkey without erasing it
    # first, which would abort here rather than swap the reader in.
    functions --copy __tcz_popup_readkey __t4_saved_readkey
    functions -e __tcz_popup_readkey
    functions --copy __t4_readkey __tcz_popup_readkey
    function stty; end
    set -l editing 1
    set -l chan 1
    set -l tok down
    set -l focus list
    set -l sel 0
    set -l sel2 0
    set -l n 35
    set -l WIN 31
    eval $EDITARM
    functions -e stty
    functions -e __tcz_popup_readkey
    functions --copy __t4_saved_readkey __tcz_popup_readkey
    functions -e __t4_saved_readkey
    echo "$chan $__t4_fed"
end
set -g __t4_res (string split ' ' -- (__t4_run))
t "editarm: chan advances exactly one step for a held burst" 2 "$__t4_res[1]"
t "editarm: the drain consumed the whole queued burst" 5 "$__t4_res[2]"
functions -e __t4_readkey __t4_run

# --- Task 5: the slider drain must DISCARD, not accumulate ------------------
# The seed's ←→ channel-value drain (added by Task 4 alongside the editing-mode
# ↑↓ channel-select drain) reads queued autorepeat but ACCUMULATES each queued
# key into delta (`set delta (math "$delta - 8")` / `+ 8`), so a burst applies
# one large jump and no intermediate value is ever drawn -- there is nothing
# to stop on. The list's own drain (case up down, non-editing) already
# discards instead of summing (see its 2026-07-29 fix, "accumulated meant a
# held key scrolls faster" above); this task makes the seed slider follow the
# same rule: exactly one 8-unit step per frame regardless of queue depth.
#
# dispatcher-caught defect: the brief's own extraction range-matches on TWO
# bare `case` lines (`/^case left right$/,/^case m$/`), which is not valid
# fish outside a switch block ("'case' builtin not inside of switch block"),
# and `eval` still returns status 0 on that parse error -- so a plain non-
# empty/contains check would PASS VACUOUSLY while nothing underneath the
# range ever actually ran. Skip the opening case line and stop before the
# closing one instead, the same technique Task 4 used for EDITARM.
set -g LRARM (awk '/^            case left right$/{f=1;next} /^            case m$/{exit} f' $catfile | string collect)
t "lrarm extraction is non-empty" 1 (test -n "$LRARM"; and echo 1; or echo 0)
t "lrarm extraction does not begin with a bare case line (the range-match trap)" 0 (string match -qr '^\s*case\b' -- (string split \n -- "$LRARM")[1]; and echo 1; or echo 0)
t "lrarm extraction stopped before case m (did not run past the arm)" 0 (string match -q '*case m*' -- "$LRARM"; and echo 1; or echo 0)

# The accumulating forms must be gone from the drain body.
set -g __t5_acc (string match -a -r 'set delta \(math' -- "$LRARM" | count)
t "lrarm: the drain no longer accumulates delta" 0 $__t5_acc

# Prove the extraction actually evals as a real switch-body fragment, not just
# that it is non-empty text -- same discriminator Task 4 established: $status
# after an in-process `eval` does NOT see a parse error (fish routes it
# through the interpreter's own error channel, not the calling command's
# stderr fd), so this shells out to a throwaway `fish --no-config` child (a
# real subprocess, so `2>` on it captures real stderr) with stubs for every
# production function/local the extracted body touches.
function __t5_evalcheck --argument-names body --description 'run <body> as a real child fish --no-config process and print the byte count captured from its stderr -- 0 means it parsed and ran cleanly, nonzero means a parse/runtime error fired.'
    set -l scriptfile (mktemp)
    set -l errfile (mktemp)
    printf '%s\n' \
        'set -l editing 1' \
        'set -l chan 1' \
        'set -l tok right' \
        'set -l seedr 100' \
        'set -l seedg 100' \
        'set -l seedb 100' \
        'set -l seed "#646464"' \
        'set -l flashfield ""' \
        'set -l seeddirty 0' \
        'function __tcz_popup_readkey; echo cancel; end' \
        'function stty; end' \
        >$scriptfile
    printf '%s\n' $body >>$scriptfile
    fish --no-config $scriptfile 2>$errfile
    set -l errbytes (wc -c <$errfile | string trim)
    command rm -f $scriptfile $errfile
    echo $errbytes
end
t "lrarm extraction evals cleanly in a real child process (zero stderr bytes)" 0 (__t5_evalcheck "$LRARM")
functions -e __t5_evalcheck

# Behavioural half: drive the REAL extracted arm with a stubbed reader holding
# four queued `right`s, and assert the channel moved by exactly one 8-unit
# step rather than five. Genuine discriminator: pre-fix (summing) this yields
# 140 -- seedr starts at 100, delta initialises to 8 (tok=right), and four
# queued rights each add 8 more (100 + 8 + 8*4 = 140); post-fix (discarding)
# it yields 108 (100 + 8, the queued rights swallowed without effect).
set -g __t5_queue right right right right
set -g __t5_fed 0
function __t5_readkey
    set -g __t5_fed (math $__t5_fed + 1)
    if test $__t5_fed -le (count $__t5_queue)
        echo $__t5_queue[$__t5_fed]
    else
        echo cancel
    end
end
function __t5_run
    # dispatcher-caught defect: `functions --copy OLD NEW` errors if NEW
    # already exists -- erase the live __tcz_popup_readkey before copying the
    # stub over it (Task 4 hit and fixed the same trap for EDITARM's harness).
    functions --copy __tcz_popup_readkey __t5_saved_readkey
    functions -e __tcz_popup_readkey
    functions --copy __t5_readkey __tcz_popup_readkey
    function stty; end
    set -l editing 1
    set -l chan 1
    set -l tok right
    set -l seedr 100
    set -l seedg 100
    set -l seedb 100
    set -l seed '#646464'
    set -l flashfield ''
    set -l seeddirty 0
    eval $LRARM
    functions -e stty
    functions -e __tcz_popup_readkey
    functions --copy __t5_saved_readkey __tcz_popup_readkey
    functions -e __t5_saved_readkey
    echo $seedr
end
set -g __t5_r (__t5_run)
t "lrarm: a held burst moves the channel one step, not five" 108 "$__t5_r"
functions -e __t5_readkey __t5_run

# --- picker-responsiveness-and-layout Task 7: the picker opens on the full
# catalog (35), m now collapses to the curated 14 instead of expanding to 35.
# The brief's own legend assertion (grepping for the quoted literal 'm
# expand') is vacuous: the real pair is `m more` (unquoted, bare words), so
# that pattern matches nothing before OR after this change. Assert against
# the real text instead: the new pair must read `m curated`, and the old `m
# more` must be gone.
set -g SLB7 (functions __tcz_theme_picker | string collect)
set -g __t7_init (string match -rg 'set -l expanded (\d)' -- "$SLB7")
t "picker opens expanded" 1 "$__t7_init"
set -g __t7_legnew (string match -a -r 'm curated' -- "$SLB7" | count)
t "legend says m curated" 1 $__t7_legnew
set -g __t7_legold (string match -a -r 'm more' -- "$SLB7" | count)
t "legend no longer says m more" 0 $__t7_legold

# --- whole-branch review (33a0fc2..19ae7bc), I-1: the reload invariant has
# no test ---------------------------------------------------------------
# The spec (docs/superpowers/specs/2026-08-13-picker-responsiveness-and-
# layout-design.md:73) names this explicitly and says "It gets its own
# test" — the plan's self-review wrongly credited Task 1 Step 5 with
# covering it; Step 5 only wires __tcz_thp_cacheclear into
# __tcz_thp_reload's first line, it adds no assertion. The reviewer proved
# it consequential by mutation: adding one line inside `case tab` that
# writes `set pals[1] '...'` directly makes the picker render stale colours
# indefinitely (the row cache misses on the selflag flip that follows a tab
# press, but the swatch-cell cache — keyed by the unchanged scheme INDEX —
# still hits, so both layers serve old ink), while the whole pre-existing
# suite stays ALL PASS. Not a shipped bug — every real assignment site was
# traced and is correct — but a missing guard on the invariant that is what
# makes the bare-integer cache key legal in the first place.
#
# __tcz_thp_reload is a NESTED closure inside __tcz_theme_picker, so a
# "picker body" extraction CONTAINS the reload body verbatim, and every
# assignment inside reload is counted twice if compared naively. The
# invariant instead holds iff the whole-picker-body count of qualifying
# assignment LINES equals the reload-body-only count — i.e. there are ZERO
# such lines anywhere in the picker OUTSIDE __tcz_thp_reload. Both regions
# are bounded the same way $RB7 already is above: an awk range ending at
# the column-0 `end` for the outer function, or the 4-space-indented `end`
# that closes a --no-scope-shadowing nested one (this file's own
# indentation convention: a function's closing `end` sits at the same
# indent as its own `function` keyword). Each extracted region is then
# split into real lines before matching, so `^...` anchors against every
# individual line — no (?m) multiline mode needed, and no risk of a
# multi-line blob silently matching only at its very start.
set -l catfile $plugindir/functions/tmux-categorize.fish
set -l RWPBODY (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "I-1: picker body extraction is non-empty" 1 (test -n "$RWPBODY"; and echo 1; or echo 0)
set -l RWRBODY (awk '/function __tcz_thp_reload/,/^    end$/' $catfile | string collect)
t "I-1: reload body extraction is non-empty" 1 (test -n "$RWRBODY"; and echo 1; or echo 0)
set -l RWPLINES (string split -- \n -- "$RWPBODY")
set -l RWRLINES (string split -- \n -- "$RWRBODY")
set -l RWPCOUNT (count (string match -ar '^\s*set (?:-a )?(?:toks|pals|fgs|tabsfgs|recipes)\b' -- $RWPLINES))
set -l RWRCOUNT (count (string match -ar '^\s*set (?:-a )?(?:toks|pals|fgs|tabsfgs|recipes)\b' -- $RWRLINES))
t "I-1: reload invariant — every toks/pals/fgs/tabsfgs/recipes write is inside __tcz_thp_reload" yes (test "$RWPCOUNT" -eq "$RWRCOUNT"; and echo yes; or echo no)

# Companion pin: anchpal is the same shape of hazard — its readers elsewhere
# in the picker assume it is always freshly computed for the current
# anchor, which is only true if every write is confined to
# __tcz_thp_reanchor itself. Its three call sites (~:1981, :2041, :2497)
# may only CALL it, never assign anchpal directly.
set -l RWANCHORBODY (awk '/function __tcz_thp_reanchor/,/^    end$/' $catfile | string collect)
t "I-1: reanchor body extraction is non-empty" 1 (test -n "$RWANCHORBODY"; and echo 1; or echo 0)
set -l RWANCHORLINES (string split -- \n -- "$RWANCHORBODY")
set -l RWPANCHCOUNT (count (string match -ar '^\s*set (?:-a )?anchpal\b' -- $RWPLINES))
set -l RWRANCHCOUNT (count (string match -ar '^\s*set (?:-a )?anchpal\b' -- $RWANCHORLINES))
t "I-1: anchpal writes are confined to __tcz_thp_reanchor" yes (test "$RWPANCHCOUNT" -eq "$RWRANCHCOUNT"; and echo yes; or echo no)


# --- hygiene: this suite's own shim dir ------------------------------------
# $shimdir holds a COMPILED fake `claude` and was never removed — 43 stale dirs
# had accumulated on the dev host across two days. Same class as the socket leak
# swept in 3e40826, and the same fail-closed shape: an empty $fish_pid would make
# this a much broader path, and $fish_pid is fish-protected so it cannot be
# empty, but the guard encodes the invariant rather than relying on that.
if test -n "$fish_pid"; and string match -qr '^/tmp/tcz-shim-[0-9]+$' -- "$shimdir"
    rm -rf $shimdir
end
t "hygiene: this run leaves no shim dir behind" 0 (test -e "$shimdir"; and echo 1; or echo 0)

if test $FAIL -eq 0
    echo "ALL PASS"; exit 0
else
    echo "SOME FAILED"; exit 1
end
