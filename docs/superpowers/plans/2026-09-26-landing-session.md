# Landing Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every automatic entry into tmux, and every tab whose session closes, lands on a private per-tab landing session running a full-screen chooser (live sessions, idle Claude projects, new shell).

**Architecture:** Landing sessions are ordinary tmux sessions named `_landing-N` (the name is the identity — `__tcz_slugify` never emits `_`). The categorizer gains the landing app, lifecycle verbs, a `pane-died` handler and Claude-project discovery; the managed fragment wires `remain-on-exit` + hooks behind a `tmux_lives_landing` kill switch; the shell side routes autostart / picker / close to landing.

**Tech Stack:** fish 4.7 (`fish --no-config` for the categorizer), tmux 3.3a (rocket) / 3.7b (macwork), the repo's own test harness (`tests/test-*.fish`, `t` assertions, `-L` sockets, `script -qec` pty clients).

**Spec:** `docs/superpowers/specs/2026-09-26-landing-session-design.md` — read it before any task.

## Global Constraints

- **A Claude session never deploys.** Edit → gate → commit. Never touch `~/.config/fish`, `~/.tmux.conf`, or the user's live tmux server. Tests use `-L` sockets only.
- **Landing identity = name.** `_landing-N`, N = smallest free integer ≥ 1. Test with `string match -q -- '_landing-*' "$name"`. No session option flag.
- **Kill switch:** universal `tmux_lives_landing`, values `on` | `off`, unset = `on`. `off` must reproduce today's behaviour exactly.
- **Target rule:** option/pane/capture commands use `=name:` (`__tcz_session_target`); session-typed commands (`has-session`, `kill-session`, `switch-client -t`, `list-clients -t`, `detach-client -s`) use `=name`. A just-created session is addressed by its `#{session_id}` (`$N`) — the categorizer may rename it.
- **Close path mechanism** (measured on 3.3a and 3.7b): `set -g remain-on-exit on` + `set-hook -g pane-died`. Never `detach-on-destroy off`.
- **Tick cost:** `tests/test-tmux-tick-calls.fish` pins one `show -g` and one `list-sessions` per tick and O(1) growth. The landing sweep must read the already-loaded session memo and issue **zero** tmux calls when no clientless landing session exists.
- **Help lines** stay under 77 chars; the framed help fits 80 columns (asserted in `test-tmux-install.fish`).
- **Comments:** brief; say what a reader needs. History and measurements go in commit messages.
- **Gate:** `for t in tests/test-*.fish; fish $t; end`, then again with `fish --no-config $t` — each mode its own foreground call with `timeout: 600000`. Filter with `grep -E '^FAIL|ALL PASS|SOME FAILED'`, never `tail -1`. Baseline today: 9/9 ALL PASS; install 889 plain / 888 `--no-config` on rocket.

### Standing instructions for every implementer

- **Briefs in this repo have contained defects in every build.** If the code disagrees with this plan, the code wins — say so in your report and adapt.
- **Prove every new assertion FAILS before the fix** (run it against the pre-change code and quote the FAIL line). Assertions that must pass both before and after (non-regression guards) are labelled as such.
- **Never background a command.** Pass an explicit `timeout: 600000` to every suite run. If a Bash call reports it was backgrounded, abandon it and re-run in the foreground.
- **Capture into a variable before asserting** (`set -l x (cmd); t "…" exp "$x"`) — a direct `(undefined_fn)` inside `t` aborts silently.
- **Never `git checkout` to revert** while work is uncommitted.
- **Where new categorize-suite sections go:** immediately before the first `# --- hygiene:` header near the end of `tests/test-tmux-categorize.fish`. Name the categorizer `$plugindir/functions/tmux-categorize.fish` (e.g. `set -l lcat …`) — the suite's `$catfile` is a script-local defined mid-file.
- **New verbs** go in `__tcz_main` and in its `usage:` line.
- **Landing sessions in tests:** a test that only needs a session *named* `_landing-N` creates it as a bare shell (`tmux new-session -d -s _landing-9`), never via the app. Sessions made by `__tcz_landing_new` run the app.

## Pre-flight corrections (2026-09-28)

A pre-flight of this plan against the code found 15 defects; the task text below is already corrected. The ones that change design:
- `__tcz_free_gen` is generalised to `__tcz_free_name <prefix> <taken…>` instead of adding a duplicate `__tcz_landing_free_name`.
- Task 1 adds the `landing` verb with a minimal `__tcz_landing` that never exits, so landing panes created by Tasks 1–5 stay alive; Task 6 replaces its body.
- `pane-died` rule 1 respawns with the explicit landing command: a bare `respawn-pane -k` re-runs whatever command the pane last ran.
- The discovery seams are exported suite-wide (Task 5), so landing apps started inside test servers never read `~/.claude/projects` or write `~/.cache/tmux-lives`.
- `landing-name` is pure: the shell side passes the session names in, so the subprocess makes no tmux call.

## File Structure

| File | Changes |
|---|---|
| `functions/tmux-categorize.fish` | landing identity/lifecycle, `pane-died` + evict handlers, sweep, commandeer branch, project discovery, landing app, list/draw extensions, new `__tcz_main` verbs |
| `conf.d/tmux-lives-install.fish` | fragment argv[19] `landing` + its lines, `setup landing`, help lines, post-update respawn, teardown restore |
| `conf.d/tmux.fish` | shell-side landing helpers; autostart / picker-outside / close routing; exclusions; restore disposal |
| `tests/test-tmux-categorize.fish` | Tasks 1, 2, 3, 5, 6 |
| `tests/test-tmux-install.fish` | Task 4 |
| `tests/test-tmux-auto.fish` | Task 7 |
| `README.md`, `CLAUDE.md` | Task 8 |

---

### Task 1: Landing identity, creation, exclusions (categorizer)

**Files:** Modify `functions/tmux-categorize.fish`; Test `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:**
- `__tcz_is_landing <name>` → status 0 iff `name` matches `_landing-*`. Pure.
- `__tcz_free_name <prefix> <taken…>` → prints `<prefix>-N`, smallest N ≥ 1 not among the taken names. Pure. **Replaces** `__tcz_free_gen` (C:79): rename it and add the prefix argument; update its two callers (C:909 `__tcz_free_gen $others` → `__tcz_free_name gen $others`; C:1189 in `__tcz_new_general`) and its three tests (suite ~578-580). Landing names come from `__tcz_free_name _landing …`.
- `__tcz_landing_cmd` — global set once next to `__tcz_self` (C:12): `"fish --no-config $__tcz_self landing"`. The one place the landing pane's command is spelled.
- `__tcz_landing_new [client]` → creates `_landing-N` running `$__tcz_landing_cmd` in `$HOME`; with `client`, switches that client to it **in the same tmux invocation**; prints the name.
- Verbs `landing-new [client]` and `landing`. `__tcz_landing` here is only a placeholder that never exits (`while true; sleep 3600; end`), so a landing pane stays alive until Task 6 replaces the body with the chooser.
- Exclusions: `__tcz_snapshot` output (hence `__tcz_overview`, `__tcz_categorize`, both pickers) and `__tcz_pick_general` skip landing sessions; `__tcz_session_title` returns `[<h>] landing` for one.

- [ ] **Step 1: Failing tests.** Add a section to `tests/test-tmux-categorize.fish` at the place the Standing instructions name (reuse `fresh_server`, `$sock`, the PATH shim). Also change the three `free_gen` tests (~578-580) to call `__tcz_free_name gen …` with the same expectations (non-regression, renamed).

```fish
# --- landing: identity, free name, create, exclusions ---
set -l il1 (__tcz_is_landing _landing-3; echo $status)
t "is_landing: reserved name" 0 "$il1"
set -l il2 (__tcz_is_landing tmux-lives; echo $status)
t "is_landing: project name" 1 "$il2"
set -l il3 (__tcz_is_landing landing-3; echo $status)
t "is_landing: look-alike without underscore" 1 "$il3"
set -l ln1 (__tcz_free_name _landing tmux-lives _landing-1 _landing-3)
t "free_name: smallest gap" _landing-2 "$ln1"
set -l ln2 (__tcz_free_name _landing)
t "free_name: empty server" _landing-1 "$ln2"
fresh_server
set -l made (__tcz_landing_new)
t "landing_new: prints the name" _landing-1 "$made"
set -l lcmd (command tmux -L $sock list-panes -t '=_landing-1:' -F '#{pane_start_command}')
t "landing_new: pane runs the landing verb" 1 (string match -q '*--no-config*landing*' -- "$lcmd"; and echo 1; or echo 0)
set -l ov (__tcz_overview | string split -f1 \t)
t "overview hides landing" 0 (contains -- _landing-1 $ov; and echo 1; or echo 0)
# pick_general: leave only landing sessions, one of them an idle bare shell
command tmux -L $sock new-session -d -s _landing-9
sleep 0.3
command tmux -L $sock kill-session -t =0
set -l pg (__tcz_pick_general)
t "pick_general never picks landing" "" "$pg"
set -g tmux_lives_hostname rocket
set -l lt (__tcz_session_title _landing-1)
t "landing tab title" "[r] landing" "$lt"
set -e tmux_lives_hostname
cleanup
```

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'` (timeout 600000). Expected: the new lines FAIL (functions undefined → empty captures; pre-fix `pick_general` returns `_landing-9`). Quote them in your report.

- [ ] **Step 2: Implement** near `__tcz_new_general` in `functions/tmux-categorize.fish`:

```fish
function __tcz_is_landing --argument-names name --description 'true if <name> is a landing session (_landing-N; slugs never contain _)'
    string match -q -- '_landing-*' "$name"
end

function __tcz_landing_new --argument-names client --description 'create a landing session running the landing app; with <client>, move it there in the same tmux call; print the name'
    set -l name (__tcz_free_name _landing (tmux list-sessions -F '#{session_name}' 2>/dev/null))
    if test -n "$client"
        tmux new-session -d -s $name -c $HOME $__tcz_landing_cmd \; switch-client -c "$client" -t "=$name" 2>/dev/null; or return 1
    else
        tmux new-session -d -s $name -c $HOME $__tcz_landing_cmd 2>/dev/null; or return 1
    end
    echo $name
end
```

`__tcz_free_name` is `__tcz_free_gen`'s body with `gen` replaced by `$argv[1]` and the taken list `$argv[2..]`.

Exclusions:
- `__tcz_snapshot` final output loop (`for i in (seq (count $names))` that prints the 5 fields): first line of the loop body `__tcz_is_landing $names[$i]; and continue`.
- `__tcz_pick_general` loop: after the `test (count $f) -ge 3` line, add `__tcz_is_landing $f[3]; and continue`.
- `__tcz_session_title`: after `test -n "$session"; or return 0`, add
  `__tcz_is_landing $session; and begin; __tcz_format_title (__tcz_hostname) landing ''; return 0; end`
  (check `__tcz_format_title`'s real argument order and the hostname helper name before writing this; adapt if they differ).
- `__tcz_main`: add `case landing-new` → `__tcz_landing_new $argv[2]` and `case landing` → `__tcz_landing`.

- [ ] **Step 3: Run** the categorize suite in both modes (two foreground calls). Expected: ALL PASS.
- [ ] **Step 4: Commit** `feat(landing): reserved _landing-N sessions — identity, creation, exclusions`.

---

### Task 2: Close path and landing guard (categorizer)

**Files:** Modify `functions/tmux-categorize.fish`; Test `tests/test-tmux-categorize.fish`.

**Interfaces — Consumes:** `__tcz_is_landing`, `__tcz_landing_new`, `__tcz_new_general <dir>` (prints the new session name).
**Produces:**
- `__tcz_pane_died <pane_id> <session>` + verb `pane-died`:
  1. landing session → `respawn-pane -k -t <pane> $__tcz_landing_cmd` (explicit: a bare `-k` re-runs whatever the pane last ran);
  2. other session with another live pane → `kill-pane -t <pane>`;
  3. last live pane → each attached client gets `__tcz_landing_new <client>`, then `kill-session -t =<session>`.
- `__tcz_landing_evict <pane_id> <session>` + verb `landing-evict`: for a landing session only — create a general session in `$HOME`, switch the landing's client there, kill `<pane>`.

- [ ] **Step 1: Failing tests** (real pty client; install the hook by hand on the test server — the fragment wiring is Task 4):

```fish
set -l lcat $plugindir/functions/tmux-categorize.fish
# --- landing: pane-died close path (real client) ---
fresh_server
command tmux -L $sock new-session -d -s victim -x 80 -y 24 'sleep 2'
command tmux -L $sock set -g remain-on-exit on
command tmux -L $sock set-hook -g pane-died "run-shell \"fish --no-config $lcat pane-died '#{pane_id}' '#{session_name}'\""
set -l seen /tmp/tcz-seen-$fish_pid; rm -f $seen
command tmux -L $sock set-hook -g client-session-changed "run-shell 'echo #{session_name} >> $seen'"
env TERM=xterm-256color script -qec "tmux attach -t =victim" /dev/null >/dev/null 2>&1 &
set -l n 0
while test $n -lt 40; and command tmux -L $sock has-session -t =victim 2>/dev/null; sleep 0.2; set n (math $n + 1); end
set -l now (command tmux -L $sock list-clients -F '#{session_name}')
t "close: client lands on a landing session" 1 (string match -q '_landing-*' -- "$now"; and echo 1; or echo 0)
t "close: dead session is gone" 1 (command tmux -L $sock has-session -t =victim 2>/dev/null; and echo 0; or echo 1)
set -l visited (cat $seen | string match -v victim | string match -v '_landing-*')
t "close: client never visited another session" "" "$visited"
kill $last_pid 2>/dev/null; rm -f $seen
cleanup

# --- landing: a non-last pane dies -> only that pane goes ---
fresh_server
command tmux -L $sock set -g remain-on-exit on
command tmux -L $sock split-window -t '=0:' 'sleep 1'
set -l dead (command tmux -L $sock list-panes -t '=0:' -F '#{pane_id} #{pane_start_command}' | string match '*sleep*' | string split -f1 ' ')
sleep 1.5
fish --no-config $lcat pane-died $dead 0
set -l nls (command tmux -L $sock has-session -t =0 2>/dev/null; echo $status)
t "non-last pane: session survives" 0 "$nls"
set -l nlp (command tmux -L $sock list-panes -t '=0:' | count)
t "non-last pane: dead pane removed" 1 "$nlp"
cleanup

# --- landing: a dead landing pane is respawned ---
fresh_server
set -l lnm (__tcz_landing_new)
set -l lp (command tmux -L $sock list-panes -t "=$lnm:" -F '#{pane_id}')
command tmux -L $sock set -g remain-on-exit on
command tmux -L $sock respawn-pane -k -t $lp 'true'
sleep 0.5
fish --no-config $lcat pane-died $lp $lnm
set -l lcmd2 (command tmux -L $sock list-panes -t "=$lnm:" -F '#{pane_dead} #{pane_start_command}')
t "landing pane respawned alive" 1 (string match -q '0 *landing*' -- "$lcmd2"; and echo 1; or echo 0)
cleanup
```

(The `script -qec` idiom and the client-wait loop match the suite's existing pty tests; `respawn-pane … 'true'` then waiting makes the pane dead under `remain-on-exit`, and its stored command is now `true` — which is why rule 1 must pass the landing command explicitly. If `pane_start_command` does not reflect a respawn command on 3.3a, assert on `#{pane_dead}` and the command separately — the code wins.)

Expected before the fix: the close test shows the client detached/no landing session; the handler verb is unknown. Quote the FAIL lines.

- [ ] **Step 2: Implement:**

```fish
function __tcz_pane_died --argument-names pane session --description 'pane-died hook: respawn a landing app; drop a dead pane; or move the clients of a closing session to landing, then kill it'
    test -n "$pane"; and test -n "$session"; or return 0
    if __tcz_is_landing $session
        tmux respawn-pane -k -t $pane $__tcz_landing_cmd 2>/dev/null
        return 0
    end
    set -l live (tmux list-panes -s -t (__tcz_session_target $session) -F '#{pane_dead}' 2>/dev/null | string match 0)
    if test (count $live) -gt 0
        tmux kill-pane -t $pane 2>/dev/null
        return 0
    end
    for c in (tmux list-clients -t "=$session" -F '#{client_name}' 2>/dev/null)
        __tcz_landing_new $c >/dev/null
    end
    tmux kill-session -t "=$session" 2>/dev/null
    return 0
end

function __tcz_landing_evict --argument-names pane session --description 'a window/split opened in a landing session: give its client a real session instead'
    __tcz_is_landing $session; or return 0
    set -l client (tmux list-clients -t "=$session" -F '#{client_name}' 2>/dev/null)[1]
    set -l gen (__tcz_new_general $HOME)
    test -n "$client"; and test -n "$gen"; and tmux switch-client -c "$client" -t "=$gen" 2>/dev/null
    tmux kill-pane -t $pane 2>/dev/null
    return 0
end
```

`__tcz_main`: `case pane-died` → `__tcz_pane_died $argv[2] $argv[3]`; `case landing-evict` → `__tcz_landing_evict $argv[2] $argv[3]`.

Add an evict test: landing session with a client-less split (`split-window -t "=$lnm:"`), run `fish --no-config $lcat landing-evict <newpane> $lnm`, assert the split is gone and a `gen-*` session exists.

- [ ] **Step 3: Run** the categorize suite, both modes. Expected ALL PASS.
- [ ] **Step 4: Commit** `feat(landing): pane-died close path and landing guard`.

---

### Task 3: Commandeer to landing, and the tick sweep (categorizer)

**Files:** Modify `functions/tmux-categorize.fish`; Test `tests/test-tmux-categorize.fish`, `tests/test-tmux-tick-calls.fish` (must stay green unchanged).

**Interfaces — Consumes:** `__tcz_landing_new`, `__tcz_is_landing`, the session memo (`__tcz_tmux_sess_names`, `__tcz_tmux_sess_attached` — confirm exact array names in `__tcz_tmux_load`).
**Produces:**
- `__tcz_commandeer <client> <session> [landing]` — third arg `on`/`off` (default `off` = today). With `on`: target = `__tcz_landing_new` (detached), then the existing switch + springboard kill.
- `__tcz_landing_sweep` — kill landing sessions with `attached = 0`, reading only the memo.

- [ ] **Step 1: Failing tests.**

```fish
# --- landing: commandeer lands a ShellFish springboard on landing ---
fresh_server
command tmux -L $sock new-session -d -s shellfish-1
sleep 0.3
functions -c tmux __tcz_tmux_bak 2>/dev/null
function tmux; test "$argv[1]" = switch-client; and return 0; command tmux -L $sock $argv; end
__tcz_commandeer fakeclient shellfish-1 on
functions -e tmux
set -l sess (command tmux -L $sock list-sessions -F '#{session_name}')
t "commandeer(on): a landing session exists" 1 (string match -q '_landing-*' -- $sess; and echo 1; or echo 0)
t "commandeer(on): springboard disposed" 0 (contains -- shellfish-1 $sess; and echo 1; or echo 0)
t "commandeer(on): no gen session created" 0 (string match -q 'gen-*' -- $sess; and echo 1; or echo 0)
cleanup

# --- landing: sweep kills only clientless landing sessions ---
fresh_server
__tcz_landing_new >/dev/null
__tcz_tmux_flush; __tcz_tmux_load
__tcz_landing_sweep
set -l sw1 (command tmux -L $sock has-session -t =_landing-1 2>/dev/null; and echo 0; or echo 1)
t "sweep: clientless landing killed" 1 "$sw1"
set -l sw2 (command tmux -L $sock has-session -t =0 2>/dev/null; echo $status)
t "sweep: other sessions untouched" 0 "$sw2"
cleanup
```

(Match the existing commandeer tests' switch-client shim at the suite's commandeer section; the existing default-path commandeer tests are the non-regression guard for `off`.)

- [ ] **Step 2: Implement.**
  - `__tcz_commandeer`: add `landing` to `--argument-names`; before `set -l target (__tcz_pick_general "$session")`, insert:

```fish
    if test "$landing" = on
        set -l target (__tcz_landing_new)
        test -n "$target"; or return 0
        tmux switch-client -c "$client" -t "=$target" 2>/dev/null; and tmux kill-session -t "=$session" 2>/dev/null
        return 0
    end
```

  - `__tcz_landing_sweep`:

```fish
function __tcz_landing_sweep --description 'kill landing sessions nobody is attached to (reads the per-pass session memo only)'
    __tcz_tmux_load
    for i in (seq (count $__tcz_tmux_sess_names))
        __tcz_is_landing $__tcz_tmux_sess_names[$i]; or continue
        test "$__tcz_tmux_sess_attached[$i]" = 0; and tmux kill-session -t "=$__tcz_tmux_sess_names[$i]" 2>/dev/null
    end
end
```

  - Tick: in `case tick`, after the `__tcz_categorize` line, add `__tcz_landing_sweep`.
  - `__tcz_main case commandeer` already passes `$argv[2..]` (C:4416) — no change needed there.
  - `__tcz_tmux_load` is a no-op once loaded this pass. If `__tcz_categorize` flushes the memo before the sweep runs, the reload costs a second `show -g` + `list-sessions` and tick-calls will fail — then read what the pass already loaded instead; the code wins.

- [ ] **Step 3: Run** categorize and **tick-calls** suites, both modes. Expected ALL PASS with tick-calls unchanged (the sweep issues no tmux call when nothing needs killing). If tick-calls fails, the sweep is reading tmux instead of the memo — fix the sweep, not the test.
- [ ] **Step 4: Commit** `feat(landing): ShellFish tabs land on landing; tick sweeps empty landing sessions`.

---

### Task 4: Fragment wiring, kill switch, setup command (install side)

**Files:** Modify `conf.d/tmux-lives-install.fish`; Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes:** verbs `pane-died`, `landing-evict`, commandeer's third arg.
**Produces:**
- `__tmux_lives_render_fragment` argv[19] `landing` (`on`/`off`); `__tmux_lives_write_fragment` passes `(__tmux_lives_key tmux_lives_landing on)` as argv[19].
- Fragment lines when `on`:
  - `set -g remain-on-exit on`
  - `set-hook -g pane-died "run-shell \"fish --no-config $cat pane-died '#{pane_id}' '#{session_name}'\""`
  - `set-hook -g after-new-window "if-shell -F '#{m:_landing-*,#{session_name}}' \"run-shell \\\"fish --no-config $cat landing-evict '#{pane_id}' '#{session_name}'\\\"\""` and the same for `after-split-window`.
  - the commandeer call inside the existing `client-session-changed` block gets a trailing ` on`.
- When `off`: `set -g remain-on-exit off`, `set-hook -gu pane-died`, `set-hook -gu after-new-window`, `set-hook -gu after-split-window`; commandeer gets ` off`.
- `__tmux_lives_landing_cmd on|off|status` — `setup landing …`; `on`/`off` set the universal and call `__tmux_lives_write_fragment`; `status`/no arg prints `landing: ON` / `landing: OFF`; anything else → `usage: tmux-lives setup landing on|off|status` on stderr, status 1.
- Help: a setup help row `'landing on|off|status       land every new tab on the chooser'` — 7 spaces, so the description starts in the same column as the `auto` row (I:2201); under 77 chars. Dispatcher `case landing`; add `landing` to the hidden top-level shortcut list.
- `_tmux_lives_post_update`: after re-rendering, respawn every live landing pane so it runs the new code: `for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null | string match '_landing-*'); tmux respawn-pane -k -t "=$s:" 2>/dev/null; end` (guard: only when a server is running).
- Teardown: after removing the source line, if a server is running: `tmux set -g remain-on-exit off; tmux set-hook -gu pane-died; tmux set-hook -gu after-new-window; tmux set-hook -gu after-split-window` (all `2>/dev/null`).

- [ ] **Step 1: Failing tests.** Use the suite's existing full-argv render form (see the `SYNCBASE` example near line 289) extended with a 19th arg:

```fish
set -l LBASE /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono 0.55 0.11 0.50 deep 'xterm*'
set -l fon (__tmux_lives_render_fragment $LBASE on | string collect)
set -l foff (__tmux_lives_render_fragment $LBASE off | string collect)
t "landing on: remain-on-exit on" 1 (string match -q '*set -g remain-on-exit on*' -- "$fon"; and echo 1; or echo 0)
t "landing on: pane-died hook" 1 (string match -q "*set-hook -g pane-died*cat.fish pane-died*#{pane_id}*#{session_name}*" -- "$fon"; and echo 1; or echo 0)
t "landing on: evict on new window" 1 (string match -q '*after-new-window*_landing-*landing-evict*' -- "$fon"; and echo 1; or echo 0)
t "landing on: evict on split" 1 (string match -q '*after-split-window*_landing-*landing-evict*' -- "$fon"; and echo 1; or echo 0)
t "landing on: commandeer told on" 1 (string match -q "*commandeer '#{client_name}' '#{client_session}' on*" -- "$fon"; and echo 1; or echo 0)
t "landing off: remain-on-exit off" 1 (string match -q '*set -g remain-on-exit off*' -- "$foff"; and echo 1; or echo 0)
t "landing off: pane-died hook unset" 1 (string match -q '*set-hook -gu pane-died*' -- "$foff"; and echo 1; or echo 0)
t "landing off: no pane-died handler" 0 (string match -q '*cat.fish pane-died*' -- "$foff"; and echo 1; or echo 0)
t "landing off: commandeer told off" 1 (string match -q "*commandeer '#{client_name}' '#{client_session}' off*" -- "$foff"; and echo 1; or echo 0)
```

Plus: source the `on` render into an isolated `-f /dev/null` server (the suite's existing source-into-server pattern, ~159-189) and assert `show -gv remain-on-exit` = `on` and `show-hooks -g` contains `pane-died` — a malformed line would be silently accepted by `source-file` otherwise. `setup landing` CLI tests with the universal isolated by the suite's re-exec guard: `status` default prints `landing: ON`; `off` then `status` prints `landing: OFF`; a bad arg returns 1. Help-width assertions already cover the new row.

Every existing assertion that renders with 18 args must keep passing: update those call sites to pass `on` as argv[19] only where they assert on commandeer text; elsewhere a missing argv[19] must behave as `on`. Grep `render_fragment` in the suite and account for every call site in your report.

Two existing assertions pin the arg count and **must be updated**, not worked around: `tests/test-tmux-install.fish:1634` ("passes exactly 18 args") → 19, and add a sibling to :1635 asserting arg 19 is `tmux_lives_landing`. Prove both FAIL before the implementation.

- [ ] **Step 2: Implement** per the Interfaces block. In `__tmux_lives_render_fragment`, read `set -l landing $argv[19]; test -n "$landing"; or set landing on`. Emit the `on`/`off` lines next to the existing hook block (I:219-227). Put the commandeer suffix on the existing line.
- [ ] **Step 3: Run** the install suite, both modes. Expected ALL PASS; report the new counts (889+N / 888+N).
- [ ] **Step 4: Commit** `feat(landing): fragment wiring and the tmux_lives_landing kill switch`.

---

### Task 5: Claude project discovery (categorizer)

**Files:** Modify `functions/tmux-categorize.fish`; Test `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:**
- `__tcz_claude_projects` → lines `folder\tmtime` (epoch seconds), newest first, folders that exist locally only.
  - Root: `$tmux_lives_claude_projects_dir`, default `$HOME/.claude/projects`.
  - Cache: `$tmux_lives_project_cache`, default `$XDG_CACHE_HOME/tmux-lives/projects.tsv` else `$HOME/.cache/tmux-lives/projects.tsv`; lines `dir\tmtime\tfolder`. A directory is re-read only when its newest transcript's mtime differs from the cached one.
- `__tcz_claude_cwds` → the cwd of every pane running claude (one `list-panes -a` call; uses `__tcz_pane_is_claude`).
- `__tcz_age <seconds>` → `now`, `5m`, `3h`, `2d`, `4w`.

⚠ Both seams resolve through `$HOME`. At the top of `tests/test-tmux-categorize.fish`, next to `tmux_lives_render_cache_dir` (~line 49), **export** both suite-wide: `set -gx tmux_lives_claude_projects_dir /tmp/tcg-projects-$fish_pid` and `set -gx tmux_lives_project_cache /tmp/tcg-projcache-$fish_pid.tsv`. Exported, they reach every test tmux server and so every landing app a later test starts (Task 6 makes that app real). In the hygiene section, remove both and bracket the real `~/.cache/tmux-lives/projects.tsv` (existence and mtime unchanged), mirroring the render-cache bracket. The discovery test below uses these values; it never sets or erases them.

- [ ] **Step 1: Failing tests.**

```fish
# --- landing: claude project discovery ---
set -l pj $tmux_lives_claude_projects_dir
rm -rf $pj; mkdir -p $pj/-a $pj/-b $pj/-gone /tmp/tcz-proj-a-$fish_pid /tmp/tcz-proj-b-$fish_pid
rm -f $tmux_lives_project_cache
printf '{"type":"summary"}\n{"cwd":"/tmp/tcz-proj-a-%s","x":1}\n' $fish_pid > $pj/-a/s1.jsonl
printf '{"cwd":"/tmp/tcz-proj-b-%s"}\n' $fish_pid > $pj/-b/s1.jsonl
printf '{"cwd":"/tmp/tcz-proj-gone-%s"}\n' $fish_pid > $pj/-gone/s1.jsonl
touch -d '2 hours ago' $pj/-a/s1.jsonl
touch -d '1 hour ago' $pj/-b/s1.jsonl
set -l rows (__tcz_claude_projects)
t "projects: gone folder dropped" 2 (count $rows)
t "projects: newest first" "/tmp/tcz-proj-b-$fish_pid" (string split -f1 \t -- $rows[1])
t "projects: cwd read past a non-cwd first line" "/tmp/tcz-proj-a-$fish_pid" (string split -f1 \t -- $rows[2])
t "projects: cache written" 3 (count (cat $tmux_lives_project_cache))
# s2 is written now, an hour newer than s1, so -b's newest mtime changes
printf '{"cwd":"/tmp/tcz-proj-a-%s"}\n' $fish_pid > $pj/-b/s2.jsonl
set -l rows2 (__tcz_claude_projects)
t "projects: newer transcript re-read" "/tmp/tcz-proj-a-$fish_pid" (string split -f1 \t -- $rows2[1])
t "projects: deduped by folder" 1 (count $rows2)
set -l a1 (__tcz_age 300); t "age: minutes" 5m "$a1"
set -l a2 (__tcz_age 10800); t "age: hours" 3h "$a2"
set -l a3 (__tcz_age 172800); t "age: days" 2d "$a3"
set -l a4 (__tcz_age 20); t "age: just now" now "$a4"
rm -rf $pj /tmp/tcz-proj-a-$fish_pid /tmp/tcz-proj-b-$fish_pid $tmux_lives_project_cache
```

(`touch -d` is GNU; the suite runs on rocket. If a macOS run of the suite is in scope, use `touch -t`.) Note `rows2`: after the new transcript in `-b` points at folder a, both dirs resolve to folder a — dedupe by folder, keeping the newest.

- [ ] **Step 2: Implement.** Use fish builtins: glob `$root/*/*.jsonl`, `path mtime`, `path dirname`; read a transcript head with `head -c 200000 -- $file | string match -rg '"cwd":"([^"]+)"'` (first match) — the only fork, on cache misses. Dedupe folders, keep the newest mtime, drop folders failing `test -d`, sort by mtime descending (`sort -t\t -k2,2nr` is acceptable — one fork). Write the cache with one `printf … > $tmp; mv $tmp $cache` (mkdir the directory first; never fail discovery over the cache).
  `__tcz_claude_cwds`: `tmux list-panes -a -F '#{pane_current_command}\t#{pane_pid}\t#{pane_current_path}'`; for each row where `__tcz_pane_is_claude cmd pid`, print the path.
- [ ] **Step 3: Run** categorize suite, both modes. ALL PASS.
- [ ] **Step 4: Commit** `feat(landing): discover idle Claude projects from their transcripts`.

---

### Task 6: The landing app (categorizer)

**Files:** Modify `functions/tmux-categorize.fish`; Test `tests/test-tmux-categorize.fish`, `tests/test-tmux-popup.fish` (list-lines is pure and tested there).

**Interfaces — Consumes:** `__tcz_overview`, `__tcz_claude_projects`, `__tcz_claude_cwds`, `__tcz_git_root`, `__tcz_age`, `__tcz_pid_environ`, `__tcz_new_general`, the popup helpers.
**Produces:**
- `__tcz_client_device <pid>` → first field of `SSH_CONNECTION` in the client environ, else `local`.
- `__tcz_landing_model <self-session>` → model rows `target\tcategory\tmark\tlast\tdisplay`:
  - live rows = `__tcz_overview` rows (landing already excluded), `mark` = `2` if a client on that session has my device, else `1` if any client is on it, else `0`;
  - project rows: `folder\tproject\t0\tmtime\t<basename> · <age>` for `__tcz_claude_projects` folders not in `__tcz_claude_cwds` (compare folder to each cwd and to its `__tcz_git_root`);
  - one final row `new\tnew\t0\t0\tnew shell`.
- `__tcz_popup_list_lines`: `mark 2` → `[here]`; category `project` (colour 5, rule word `idle claude`) and `new` (colour 8, rule word `new`). Popup behaviour unchanged for its own categories and marks 0/1.
- `__tcz_popup_draw`: when the selected row's category is `project` or `new`, the preview column shows `__tcz_landing_info <row> <w> <h>` (folder path + age, or a one-line hint) instead of `capture-pane`.
- `__tcz_landing_start <folder> continue|resume <client>` → `tmux new-session -d -c <folder> -P -F '#{session_id}'`, `send-keys -t <id> 'claude --continue' Enter` (or `--resume`), `switch-client -c <client> -t <id>`.
- `__tcz_landing` (verb `landing`) — the loop.

- [ ] **Step 1: Failing tests** — pure pieces only; the interactive loop is runtime-verified in Task 8.

In `tests/test-tmux-popup.fish` (pure):

(`vis` strips SGR from its **argument**, not stdin — join the rows first, then pass them.)

```fish
set -l here (printf 'alpha\tclaude\t2\t0\talpha\n' | __tcz_popup_list_lines 40 0 '' | string join \n)
set here (vis "$here" | string join \n)
t "list_lines: mark 2 renders [here]" 1 (string match -q '*[here]*' -- "$here"; and echo 1; or echo 0)
set -l att (printf 'alpha\tclaude\t1\t0\talpha\n' | __tcz_popup_list_lines 40 0 '' | string join \n)
set att (vis "$att" | string join \n)
t "list_lines: mark 1 still [attached] (non-regression)" 1 (string match -q '*[attached]*' -- "$att"; and echo 1; or echo 0)
set -l pr (printf '/p/x\tproject\t0\t0\tx · 2d\n' | __tcz_popup_list_lines 40 0 '' | string join \n)
set pr (vis "$pr" | string join \n)
t "list_lines: project rule" 1 (string match -q '*── idle claude*' -- "$pr"; and echo 1; or echo 0)
```

In `tests/test-tmux-categorize.fish` (stubbed tmux + fixtures):

```fish
# --- landing: device identity ---
set -g tmux_lives_fake_environ 'TERM=x' 'SSH_CONNECTION=10.0.30.120 49239 192.168.68.101 22'
set -l dv1 (__tcz_client_device 1)
t "device: ssh client address" 10.0.30.120 "$dv1"
set -g tmux_lives_fake_environ 'TERM=x'
set -l dv2 (__tcz_client_device 1)
t "device: local" local "$dv2"
set -e tmux_lives_fake_environ

# --- landing: start a project ---
set -g LREC /tmp/tcz-lrec-$fish_pid; rm -f $LREC
function tmux; echo $argv >> $LREC; test "$argv[1]" = new-session; and echo '$9'; return 0; end
__tcz_landing_start /tmp/projx continue cl1
functions -e tmux
set -l rec (cat $LREC)
t "start: new session in the folder, id captured" 1 (string match -q '*new-session -d -c /tmp/projx -P -F #{session_id}*' -- $rec; and echo 1; or echo 0)
t "start: claude --continue sent" 1 (string match -q '*send-keys -t $9 claude --continue Enter*' -- $rec; and echo 1; or echo 0)
t "start: client switched by id" 1 (string match -q '*switch-client -c cl1 -t $9*' -- $rec; and echo 1; or echo 0)
rm -f $LREC
```

Plus a `__tcz_landing_model` test on a real `-L` server with one claude-shim session and fixture projects under the suite-wide `$tmux_lives_claude_projects_dir` (Task 5; clean them up after, never erase the variable): assert the live row, a project row for an idle fixture folder, no project row for the folder the shim session runs in, and the trailing `new` row. Plus a draw test: a model whose row 1 is `new` renders without calling capture-pane (stub `__tcz_popup_preview` to append to a recorder; assert it was not called).

- [ ] **Step 2: Implement** `__tcz_client_device`, `__tcz_landing_model`, the list-lines and draw extensions, `__tcz_landing_info`, `__tcz_landing_start`, then the loop — it **replaces** the placeholder body of `__tcz_landing` from Task 1 (the `case landing` verb already exists):

```fish
function __tcz_landing --description 'the landing app: a full-pane chooser that never exits on its own'
    set -l self (tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    set -l saved (stty -g 2>/dev/null)
    stty -icanon -echo min 1 time 0 2>/dev/null
    printf '\e[?25l'
    set -l sel 0
    while true
        set -l model (__tcz_landing_model $self)
        test $sel -ge (count $model); and set sel (math (count $model) - 1)
        set -l sz (stty size 2>/dev/null | string split ' '); set -l rows 24; set -l cols 80
        test (count $sz) -eq 2; and set rows $sz[1]; and set cols $sz[2]
        set -l lay (__tcz_popup_layout $cols | string split ' ')
        __tcz_popup_draw $sel $lay[1] $lay[2] (math $rows - 1) '' -- $model
        printf '\e[%s;1H\e[K%s' $rows (__tcz_legend_row 10 '↑↓' move '⏎' open r resume x kill d detach)
        stty min 0 time 30 2>/dev/null
        set -l tok (__tcz_popup_readkey timeout)
        stty min 1 time 0 2>/dev/null
        set -l row (string split \t -- $model[(math $sel + 1)])
        set -l client (tmux list-clients -t "=$self" -F '#{client_name}' 2>/dev/null)[1]
        switch $tok
            case up;   test $sel -gt 0; and set sel (math $sel - 1)
            case down; test $sel -lt (math (count $model) - 1); and set sel (math $sel + 1)
            case enter r
                test -n "$client"; or continue
                switch $row[2]
                    case project
                        set -l how continue; test $tok = r; and set how resume
                        __tcz_landing_start $row[1] $how $client
                    case new
                        set -l gen (__tcz_new_general $HOME)
                        test -n "$gen"; and tmux switch-client -c $client -t "=$gen" 2>/dev/null
                    case '*'
                        test $tok = enter; or continue
                        tmux switch-client -c $client -t "=$row[1]" 2>/dev/null
                end
                tmux kill-session -t "=$self" 2>/dev/null
            case kill
                contains -- $row[2] claude running general; or continue
                printf '\e[%s;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' $rows "$row[1]"
                stty min 1 time 0 2>/dev/null
                set -l ans ''
                dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read ans
                if test "$ans" = 79; or test "$ans" = 59   # y / Y
                    tmux kill-session -t "=$row[1]" 2>/dev/null
                end
            case d
                test -n "$client"; and tmux detach-client -t $client 2>/dev/null
                tmux kill-session -t "=$self" 2>/dev/null
        end
    end
end
```

The `kill` arm mirrors the popup's (C `__tcz_popup`, the `kill` arm); the model is rebuilt at the top of the next iteration, so no refresh is needed there. `cancel` (q / Esc) is deliberately a no-op — the landing app never exits on its own.

⚠ `__tcz_popup_readkey`'s Esc path resets `stty min 1 time 0`; the loop re-asserts the timeout every iteration, so this is harmless — do not "fix" readkey.

- [ ] **Step 3: Run** categorize and popup suites, both modes. ALL PASS.
- [ ] **Step 4: Commit** `feat(landing): the landing app — live sessions, idle Claude projects, new shell`.

---

### Task 7: Shell side — route autostart, picker and close to landing

**Files:** Modify `conf.d/tmux.fish`; Test `tests/test-tmux-auto.fish`.

**Interfaces — Consumes:** categorizer verbs `landing-new`; universal `tmux_lives_landing`.
**Produces:**
- `__tmux_is_landing <name>` (same rule as the categorizer's), `__tmux_landing_enabled` (`test "$tmux_lives_landing" != off`).
- `__tmux_landing_argv` → the tmux argv that creates **and attaches** a new landing session: `-u new-session -s <free name> -c $HOME "fish --no-config $tmux_categorize_script landing"`. The free name comes from `fish --no-config $tmux_categorize_script landing-name <names…>`, where `__tmux_landing_argv` lists the session names itself (`tmux list-sessions -F '#{session_name}' 2>/dev/null`, in-shell, so the suite's `tmux` function shim covers it) and passes them in. Add that verb to the categorizer as a pure call: `case landing-name` → `__tcz_free_name _landing $argv[2..]` — the subprocess makes no tmux call.
- `__tmux_autostart`: when enabled, after restore → `exec tmux (__tmux_landing_argv)` (skip categorize-pick; keep restore and prune). `exec` cannot be stubbed in fish — test `__tmux_landing_argv`, and pin the exec line with a source-shape assertion bounded to the function body.
- `__tmux_lives_picker` outside tmux: when enabled → the same `exec`.
- `__tmux_lives_close`: when enabled → for each `tmux list-clients -t "=$cur" -F '#{client_name}'`, `fish --no-config $tmux_categorize_script landing-new $c`; then kill the session.
- Exclusions: `__tmux_pick_session` and `__tmux_lives_clear` skip landing; `__tmux_dispose_restored` **kills** any `_landing-*` session.

- [ ] **Step 1: Failing tests** in `tests/test-tmux-auto.fish` (the suite's function-shim `tmux` reaches only in-process calls — stub the categorizer script with the suite's recorder pattern where a subprocess is involved):

```fish
set -l sl1 (__tmux_is_landing _landing-1; echo $status)
t "is_landing (shell side)" 0 "$sl1"
set -e tmux_lives_landing
set -l le1 (__tmux_landing_enabled; echo $status)
t "landing enabled by default" 0 "$le1"
set -g tmux_lives_landing off
set -l le2 (__tmux_landing_enabled; echo $status)
t "landing off honoured" 1 "$le2"
set -e tmux_lives_landing
set -l la (__tmux_landing_argv)
t "landing argv creates and attaches" 1 (string match -q -- '-u new-session -s _landing-* -c * *--no-config*landing' "$la"; and echo 1; or echo 0)
set -l ab (functions __tmux_autostart | string collect)
t "autostart execs the landing argv when enabled" 1 (string match -q '*__tmux_landing_enabled*exec tmux (__tmux_landing_argv)*' -- "$ab"; and echo 1; or echo 0)
```

Plus: `__tmux_pick_session` on the test server never returns a `_landing-*` session (create one idle landing + one idle general; assert the general is picked); `__tmux_dispose_restored` with a fake resurrect save kills a restored `_landing-2` (extend the suite's existing disposal test); `close` with landing on calls `landing-new` for the session's client (recorder stub) and kills the session. With `tmux_lives_landing off`, the existing autostart/picker/close assertions stay green unchanged (non-regression).

- [ ] **Step 2: Implement** per Interfaces.
- [ ] **Step 3: Run** the auto, restore and categorize suites, both modes. ALL PASS.
- [ ] **Step 4: Commit** `feat(landing): autostart, picker and close land on the landing page`.

---

### Task 8: Full gate, docs, and a live-server rehearsal on a throwaway socket

**Files:** Modify `README.md`, `CLAUDE.md`, and the spec's status line (`docs/superpowers/specs/2026-09-26-landing-session-design.md`).

- [ ] **Step 1: Full gate**, both modes (two foreground calls). Expected 9/9 ALL PASS; record the new install counts.
- [ ] **Step 2: Rehearsal** (no live server): export `tmux_lives_claude_projects_dir` / `tmux_lives_project_cache` to a fixture dir first (the server's panes inherit them — never let the rehearsal read the real store or write the real cache), then start `tmux -L tl-rehearse -f <rendered fragment with the repo's cat path>` with a real pty client, and walk it: landing appears; Enter on a live session switches; `d` detaches; a session whose last pane exits lands the client on a fresh landing; `prefix c` inside landing evicts to a `gen-*`; an idle fixture project starts `claude --continue` (use the suite's fake claude on PATH). Record what you saw; kill the server; unlink the socket.
- [ ] **Step 3: Docs.** README: a "Landing page" section (what it is, keys, `setup landing on|off|status`). CLAUDE.md: replace nothing historical; add a short "Landing session" section (identity by name, close path mechanism, kill switch, exclusions list) and update the gate counts; stay within the ~40 KB budget (measure with `wc -c`, prune an equal amount if over).
- [ ] **Step 4: Commit** `docs(landing): README, CLAUDE.md`, then finish the branch (merge to `main`, push). The user deploys with `fisher update`; ask them to smoke-test on both machines.

---

## Self-review (done at authoring time)

- Spec coverage: entry points (Tasks 3, 7), close path (2, 4), lifecycle create/leave/sweep/respawn/misuse (1, 2, 3, 6), app layout/keys/refresh/switching (6), discovery (5), exclusions (1, 7), kill switch + teardown + post-update (4), platforms (measured; spec), testing (every task).
- Deviations from the spec, deliberate: identity is the name alone (no `@tmux_lives_landing` flag — the name survives restore and needs no tmux call); detach is `d`, not `q` (`__tcz_popup_readkey` maps `q` and Esc to the same token, and Esc must not detach). The spec is updated to match.
- Known risk to verify in Task 2: `#{pane_id}`/`#{session_name}` expansion inside `pane-died` (session name measured; pane id not yet) — the real-client test proves it.
