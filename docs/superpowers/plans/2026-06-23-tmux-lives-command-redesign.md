# tmux-lives Command-Surface Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tmux-lives command surface with single-responsibility verbs (`picker`/`attach`/`new`/`close`/`clear`) and a nested `setup` group (`install`/`verify`/`teardown`/`keys`/`auto`), removing `start` and `take`.

**Architecture:** Session verbs live in `conf.d/tmux.fish`; the `tmux-lives` dispatcher + `setup` sub-dispatcher + help + install/config live in `conf.d/tmux-lives-install.fish`; the popup gains an optional `--take` thread in `functions/tmux-categorize.fish`. New verbs that can start the server first call a shared `__tmux_ensure_server` (restore-if-none) to preserve macOS persistence.

**Tech Stack:** fish 3.x+ functions, tmux 3.3a, fisher plugin. Tests are fish scripts using isolated `-L` tmux sockets and stubbed functions.

## Global Constraints

- tmux floor: **3.3a** (brace-block `set-hook`/`if-shell` syntax).
- fish floor: **3.x**.
- One `conf.d` file per feature; **zero new files** under `conf.d/`/`functions/` — extend the three existing source files (see `feedback_fish_function_conventions`).
- Helper naming: user-facing dispatch helpers are `__tmux_lives_*`; categorizer internals are `__tcz_*`; auto-tmux internals are `__tmux_*`.
- Tests: never touch the real tmux server — always an isolated `-L <socket>` (function shim in `test-tmux-auto.fish`, or `command tmux -L`).
- Aliases after this change: `p`=picker, `a`=attach, `n`=new, `x`/`q`=close, `f`=fixssh; inside `setup`: `i`=install, `v`=verify. Freed: `s`, `t`, top-level `v`.
- Run the full suite after each task: `for t in tests/test-*.fish; fish $t; end` (or `fish -c '...'`). All suites must end `ALL PASS`.

**Reused existing helpers (defined in the repo; do not redefine):**
- `__tmux_restore` (`conf.d/tmux.fish`) — start server + restore resurrect snapshot + dispose idle. No args.
- `__tmux_autostart` (`conf.d/tmux.fish`) — restore-if-none → categorize → prune → `exec` attach MRU general / create.
- `__tmux_session_is_idle <session>` — true if every pane runs only a shell.
- `__tmux_detach_ghosts <session>` — detach stale clients.
- `__tmux_categorize` — run a categorize pass (renames owned sessions).
- `__tcz_switch <session> <client>` (`functions/tmux-categorize.fish`) — ghost-detach + switch-client.
- `__tcz_open_switcher <client>` — open the popup (display-popup, menu fallback).
- `__tmux_lives_render_fragment <cat> <pkey> <skey>`, `__tmux_lives_ensure_source_line <conf> <frag>`, `__tmux_lives_key <varname> <default>`, `__tmux_lives_status_lines`, `__tmux_lives_auto <subcmd>`, `__tmux_lives_fixssh` (unchanged bodies).

---

### Task 1: `__tmux_ensure_server` (restore-on-first-access helper)

**Files:**
- Modify: `conf.d/tmux.fish` (add the function near `__tmux_autostart`)
- Test: `tests/test-tmux-auto.fish`

**Interfaces:**
- Produces: `__tmux_ensure_server` — no args; if a tmux server is running, returns 0 (no-op); else runs `__tmux_restore`. Returns 0.

- [ ] **Step 1: Write the failing test** — append before the final `cleanup`/summary block in `tests/test-tmux-auto.fish`:

```fish
# __tmux_ensure_server: no-op when a server runs; restores when none.
functions -c __tmux_restore __tl_restore_bak
function __tmux_restore; set -g g_restored 1; end
cleanup
set -g g_restored 0
__tmux_ensure_server
t "ensure_server: no server -> restores" "1" "$g_restored"
tmux new-session -d -s live
set -g g_restored 0
__tmux_ensure_server
t "ensure_server: server up -> no restore" "0" "$g_restored"
cleanup
functions -e __tmux_restore; functions -c __tl_restore_bak __tmux_restore
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep ensure_server`
Expected: `FAIL - ensure_server: no server -> restores` (function undefined).

- [ ] **Step 3: Write minimal implementation** — in `conf.d/tmux.fish`, immediately before `function __tmux_autostart`:

```fish
function __tmux_ensure_server --description 'Start the tmux server, restoring the saved snapshot if none is running'
    tmux list-sessions >/dev/null 2>&1; and return 0
    __tmux_restore
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep ensure_server`
Expected: both `ok   - ensure_server: ...`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux.fish tests/test-tmux-auto.fish
git commit -m "feat: __tmux_ensure_server (restore snapshot on first access)"
```

---

### Task 2: popup `--take` thread

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_open_switcher`, `__tcz_popup`, `__tcz_switch`, `__tcz_main` (`open-switcher`/`popup` cases)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces:
  - `__tcz_open_switcher <client> [--take]` — appends `--take` to the popup invocation when set.
  - `__tcz_popup <client> [--take]` — on select, passes take through to `__tcz_switch`.
  - `__tcz_switch <session> <client> [--take]` — when `--take`, runs `tmux detach-client -s "=<session>"` before `switch-client`.

- [ ] **Step 1: Write the failing test** — in `tests/test-tmux-categorize.fish`, in the "popup switcher wiring" block (near the `__tcz_open_switcher` shim test), add after the existing `open-switcher` assertions:

```fish
set -gx PATH $sw_shim $PATH
set -g sw_take (__tcz_open_switcher c1 --take)
set -gx PATH $sw_path_save
t "open-switcher threads --take" yes (string match -q '*popup c1 --take*' -- "$sw_take"; and echo yes; or echo no)
```

(The existing `$sw_shim` echoes `TMUX:$*`, so the popup command line is observable.)

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep 'threads --take'`
Expected: `FAIL` (no `--take` in output).

- [ ] **Step 3: Write minimal implementation** in `functions/tmux-categorize.fish`:

Replace `__tcz_open_switcher`:

```fish
function __tcz_open_switcher --argument-names client --description 'open the two-pane popup switcher (display-menu fallback if display-popup is unsupported)'
    set -l take ''
    contains -- --take $argv; and set take ' --take'
    if tmux list-commands 2>/dev/null | grep -q display-popup
        tmux display-popup -E -w 80% -h 70% -- fish --no-config $__tcz_self popup "$client"$take
    else
        __tcz_menu
    end
end
```

In `__tcz_popup`, change the signature line and the final switch call:

```fish
function __tcz_popup --argument-names client --description 'two-pane session switcher (runs inside display-popup)'
    set -l take ''
    contains -- --take $argv; and set take --take
```

and the last action line (currently `test -n "$result"; and __tcz_switch "$result" "$client"`):

```fish
    test -n "$result"; and __tcz_switch "$result" "$client" $take
```

In `__tcz_switch` (read its current body first), add take handling: before the `switch-client`, when `$argv[3]` = `--take`, run `tmux detach-client -s "=$argv[1]" 2>/dev/null`.

In `__tcz_main`, pass through extra args:

```fish
        case open-switcher
            __tcz_open_switcher $argv[2..]
        case popup
            __tcz_popup $argv[2..]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -1`
Expected: `ALL PASS (...)`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat: popup --take thread (detach other clients on select)"
```

---

### Task 3: `new` command

**Files:**
- Modify: `conf.d/tmux.fish` (add `__tmux_lives_new`)
- Modify: `conf.d/tmux-lives-install.fish` (route `new`/`n` in the `tmux-lives` dispatcher)
- Test: `tests/test-tmux-auto.fish` (behavior), `tests/test-tmux-install.fish` (routing)

**Interfaces:**
- Consumes: `__tmux_ensure_server` (Task 1).
- Produces: `__tmux_lives_new [name]` — create a categorized session with cwd `$HOME`; optional slugified `name` (error if it already exists); inside tmux → create detached + `switch-client`; outside tmux → `__tmux_ensure_server` then `exec` attach.

- [ ] **Step 1: Write the failing behavior test** in `tests/test-tmux-auto.fish` (after Task 1's block):

```fish
# new: collision errors; inside tmux creates + switches; no-name -> general session.
cleanup
tmux new-session -d -s foo
set -e TMUX
set -gx TMUX fake
t "new: existing name errors (rc1)" "1" (__tmux_lives_new foo 2>/dev/null; echo $status)
__tmux_lives_new bar 2>/dev/null
t "new: creates named session" "yes" (tmux has-session -t =bar 2>/dev/null; and echo yes; or echo no)
set -e TMUX
cleanup
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep '^FAIL.*new:'`
Expected: FAILs (function undefined).

- [ ] **Step 3: Implement `__tmux_lives_new`** in `conf.d/tmux.fish` (in the `# ---- user commands ----` section):

```fish
function __tmux_lives_new --description 'Create a new categorized session in $HOME. tmux-lives new [name]'
    if not command -q tmux
        echo "tmux not installed" >&2
        return 1
    end
    set -l name
    test (count $argv) -gt 0; and set name (fish --no-config $tmux_categorize_script slug $argv[1])
    if test -n "$name"; and tmux has-session -t "=$name" 2>/dev/null
        echo "tmux-lives new: session '$name' already exists — use: tmux-lives attach $name" >&2
        return 1
    end
    if set -q TMUX
        if test -n "$name"
            tmux new-session -d -c "$HOME" -s "$name"
            tmux switch-client -t "=$name"
        else
            tmux new-session -d -c "$HOME"
            __tmux_categorize
        end
        return
    end
    __tmux_ensure_server
    if test -n "$name"
        exec tmux -u new-session -A -c "$HOME" -s "$name"
    else
        exec tmux -u new-session -c "$HOME"
    end
end
```

(No-name inside tmux: the new detached session is numeric; `__tmux_categorize` renames it to `gen-N`. No-name outside tmux: a fresh numeric session attaches; the next tick categorizes it.)

- [ ] **Step 4: Route it** in `conf.d/tmux-lives-install.fish` `tmux-lives` dispatcher — add a case:

```fish
        case new n
            __tmux_lives_new $argv[2..]
```

- [ ] **Step 5: Add the routing test** in `tests/test-tmux-install.fish` (in the alias-routing block, add a stub + assertions):

```fish
function __tmux_lives_new; set -g _tl_a new; end
set -g _tl_a ''; tmux-lives n;   t "alias n -> new"  new "$_tl_a"
set -g _tl_a ''; tmux-lives new; t "verb new routes" new "$_tl_a"
functions -e __tmux_lives_new
```

(Place these alongside the existing start/picker stub lines; remember to add `__tmux_lives_new` to the `functions -e` cleanup line if you batch them.)

- [ ] **Step 6: Run tests**

Run: `fish tests/test-tmux-auto.fish 2>&1 | tail -1; fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: both `ALL PASS (...)`.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-auto.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives new [name] — fresh categorized session in \$HOME"
```

---

### Task 4: `attach` command

**Files:**
- Modify: `conf.d/tmux.fish` (add `__tmux_lives_attach`)
- Modify: `conf.d/tmux-lives-install.fish` (route `attach`/`a`)
- Test: `tests/test-tmux-auto.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_ensure_server` (Task 1).
- Produces: `__tmux_lives_attach <name> [-t]` — attach to an EXISTING session (error if missing); `-t` detaches other clients first; inside tmux → `switch-client`; outside tmux → `__tmux_ensure_server` then `exec` attach.

- [ ] **Step 1: Write the failing behavior test** in `tests/test-tmux-auto.fish`:

```fish
# attach: missing-session errors; existing inside tmux switches.
cleanup
tmux new-session -d -s keep
set -gx TMUX fake
t "attach: missing errors (rc1)"  "1" (__tmux_lives_attach nope 2>/dev/null; echo $status)
t "attach: no name errors (rc1)"  "1" (__tmux_lives_attach 2>/dev/null; echo $status)
set -e TMUX
cleanup
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep '^FAIL.*attach:'`
Expected: FAILs.

- [ ] **Step 3: Implement `__tmux_lives_attach`** in `conf.d/tmux.fish`:

```fish
function __tmux_lives_attach --description 'Attach to an existing session. tmux-lives attach <name> [-t]'
    if not command -q tmux
        echo "tmux not installed" >&2
        return 1
    end
    set -l take 0
    set -l name
    for a in $argv
        switch $a
            case -t --take
                set take 1
            case '*'
                set name $a
        end
    end
    if test -z "$name"
        echo "tmux-lives attach: needs a session name" >&2
        return 1
    end
    set name (fish --no-config $tmux_categorize_script slug $name)
    if set -q TMUX
        if not tmux has-session -t "=$name" 2>/dev/null
            echo "tmux-lives attach: no session '$name' — use: tmux-lives new $name" >&2
            return 1
        end
        test $take -eq 1; and tmux detach-client -s "=$name" 2>/dev/null
        tmux switch-client -t "=$name"
        return
    end
    __tmux_ensure_server
    if not tmux has-session -t "=$name" 2>/dev/null
        echo "tmux-lives attach: no session '$name' — use: tmux-lives new $name" >&2
        return 1
    end
    if test $take -eq 1
        exec tmux -u attach-session -d -t "=$name"
    else
        exec tmux -u attach-session -t "=$name"
    end
end
```

- [ ] **Step 4: Route it** in the dispatcher:

```fish
        case attach a
            __tmux_lives_attach $argv[2..]
```

- [ ] **Step 5: Add routing test** in `tests/test-tmux-install.fish`:

```fish
function __tmux_lives_attach; set -g _tl_a attach; end
set -g _tl_a ''; tmux-lives a foo;      t "alias a -> attach"  attach "$_tl_a"
set -g _tl_a ''; tmux-lives attach foo; t "verb attach routes" attach "$_tl_a"
functions -e __tmux_lives_attach
```

- [ ] **Step 6: Run tests**

Run: `fish tests/test-tmux-auto.fish 2>&1 | tail -1; fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: both `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-auto.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives attach <name> [-t]"
```

---

### Task 5: `close` command

**Files:**
- Modify: `conf.d/tmux.fish` (add `__tmux_lives_close`)
- Modify: `conf.d/tmux-lives-install.fish` (route `close`/`x`/`q`)
- Test: `tests/test-tmux-auto.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_close` — inside tmux: kill the current session and detach the client to the shell (always exit, even with other sessions); outside tmux: error rc1.

**Implementation note (verify live):** "kill current + always exit" relies on `detach-on-destroy`. tmux's default is `on` (client detaches when its session is destroyed) but a global override could change it. Set it on the client just before killing to be safe: `tmux set-option -t "=$cur" detach-on-destroy on \; kill-session -t "=$cur"`. If 3.3a rejects chaining set-option with kill-session, run them as two commands. Verify against an isolated server during Step 4 that, with a SECOND session present, the client returns to the shell (not switched).

- [ ] **Step 1: Write the failing behavior test** in `tests/test-tmux-auto.fish` (kill-session is observable; the detach itself needs a real client, so assert the session is gone + rc):

```fish
# close: kills the current session; outside tmux errors.
cleanup
t "close: outside tmux errors (rc1)" "1" (begin; set -e TMUX; __tmux_lives_close 2>/dev/null; echo $status; end)
tmux new-session -d -s cur
tmux new-session -d -s other
set -gx TMUX fake
# Stub the current-session lookup so the headless test has a deterministic target.
function __tmux_lives_current_session; echo cur; end
__tmux_lives_close 2>/dev/null
t "close: current session killed" "no" (tmux has-session -t =cur 2>/dev/null; and echo yes; or echo no)
t "close: other session kept" "yes" (tmux has-session -t =other 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_lives_current_session
set -e TMUX
cleanup
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep '^FAIL.*close:'`
Expected: FAILs.

- [ ] **Step 3: Implement** in `conf.d/tmux.fish` — a tiny seam for the current session (so it's stubbable) + the command:

```fish
function __tmux_lives_current_session --description 'Name of the session this client is attached to'
    tmux display-message -p '#{session_name}' 2>/dev/null
end

function __tmux_lives_close --description 'Kill the current session and return to the shell. tmux-lives close'
    if not set -q TMUX
        echo "tmux-lives close: not inside a tmux session" >&2
        return 1
    end
    set -l cur (__tmux_lives_current_session)
    test -n "$cur"; or return 1
    tmux set-option -t "=$cur" detach-on-destroy on 2>/dev/null
    tmux kill-session -t "=$cur" 2>/dev/null
end
```

- [ ] **Step 4: Route it** in the dispatcher:

```fish
        case close x q
            __tmux_lives_close
```

- [ ] **Step 5: Add routing test** in `tests/test-tmux-install.fish`:

```fish
function __tmux_lives_close; set -g _tl_a close; end
set -g _tl_a ''; tmux-lives x;     t "alias x -> close" close "$_tl_a"
set -g _tl_a ''; tmux-lives q;     t "alias q -> close" close "$_tl_a"
set -g _tl_a ''; tmux-lives close; t "verb close routes" close "$_tl_a"
functions -e __tmux_lives_close
```

- [ ] **Step 6: Run tests + live-verify the detach**

Run: `fish tests/test-tmux-auto.fish 2>&1 | tail -1; fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: both `ALL PASS`. (The detach-to-shell-with-other-sessions behavior is verified manually on the live host after deploy; note it in the commit if you confirm it.)

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-auto.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives close (x/q) — kill current session and exit"
```

---

### Task 6: `clear` command

**Files:**
- Modify: `conf.d/tmux.fish` (add `__tmux_lives_clear`)
- Modify: `conf.d/tmux-lives-install.fish` (route `clear`)
- Test: `tests/test-tmux-auto.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_session_is_idle <session>`, `__tmux_lives_current_session` (Task 5), `__tmux_lives_close` (Task 5).
- Produces: `__tmux_lives_clear [--exit|--quit|-q|-x]` — kill every idle (general) session except the current; with the flag, also `__tmux_lives_close`.

- [ ] **Step 1: Write the failing behavior test** in `tests/test-tmux-auto.fish`:

```fish
# clear: kills idle sessions, keeps current + non-idle.
cleanup
tmux new-session -d -s idleA
tmux new-session -d -s idleB
tmux new-session -d -s busy 'sleep 1000'
set -gx TMUX fake
function __tmux_lives_current_session; echo idleA; end
__tmux_lives_clear
t "clear: idle non-current killed" "no"  (tmux has-session -t =idleB 2>/dev/null; and echo yes; or echo no)
t "clear: current kept"            "yes" (tmux has-session -t =idleA 2>/dev/null; and echo yes; or echo no)
t "clear: non-idle kept"           "yes" (tmux has-session -t =busy 2>/dev/null; and echo yes; or echo no)
functions -e __tmux_lives_current_session
set -e TMUX
cleanup
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep '^FAIL.*clear:'`
Expected: FAILs.

- [ ] **Step 3: Implement** in `conf.d/tmux.fish`:

```fish
function __tmux_lives_clear --description 'Kill idle sessions, keeping the current one. tmux-lives clear [--exit|-q|-x]'
    if not command -q tmux
        echo "tmux not installed" >&2
        return 1
    end
    tmux list-sessions >/dev/null 2>&1; or return 0
    set -l do_exit 0
    for a in $argv
        contains -- $a --exit --quit -q -x; and set do_exit 1
    end
    set -l cur ''
    set -q TMUX; and set cur (__tmux_lives_current_session)
    for s in (tmux list-sessions -F '#{session_name}' 2>/dev/null)
        test "$s" = "$cur"; and continue
        __tmux_session_is_idle "$s"; and tmux kill-session -t "=$s" 2>/dev/null
    end
    if test $do_exit -eq 1; and set -q TMUX
        __tmux_lives_close
    end
end
```

- [ ] **Step 4: Route it** in the dispatcher:

```fish
        case clear
            __tmux_lives_clear $argv[2..]
```

- [ ] **Step 5: Add routing test** in `tests/test-tmux-install.fish`:

```fish
function __tmux_lives_clear; set -g _tl_a clear; end
set -g _tl_a ''; tmux-lives clear; t "verb clear routes" clear "$_tl_a"
functions -e __tmux_lives_clear
```

- [ ] **Step 6: Run tests**

Run: `fish tests/test-tmux-auto.fish 2>&1 | tail -1; fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: both `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-auto.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives clear [--exit] — prune idle sessions, keep current"
```

---

### Task 7: `picker` rework (no name, `-t`, outside-tmux auto-open)

**Files:**
- Modify: `conf.d/tmux.fish` (`__tmux_lives_picker`)
- Modify: `conf.d/tmux-lives-install.fish` (route already `picker p` — confirm it passes `$argv[2..]`)
- Test: `tests/test-tmux-auto.fish` (replace the existing picker tests)

**Interfaces:**
- Consumes: `__tmux_ensure_server`, `__tcz_open_switcher <client> [--take]`.
- Produces: `__tmux_lives_picker [-t]` — inside tmux: open the popup (`--take` when `-t`); outside tmux: `__tmux_ensure_server` → attach (MRU general / create) → auto-open the popup.

**Outside-tmux auto-open (verify live):** the popup needs an attached client, so it can't open from a bare shell. Approach to implement and verify on tmux 3.3a / macOS: pick the target (reuse `__tmux_pick_session`; if empty, create one), then attach AND queue the popup on the freshly-attached client, e.g.:

```fish
exec tmux -u attach-session -d -t "=$target" \; run-shell -d 0 "tmux display-popup -E -w 80% -h 70% -- fish --no-config $tmux_categorize_script popup ''$takearg"
```

If `attach \; run-shell` does not reliably fire the popup on the new client in 3.3a, FALL BACK to plain `__tmux_autostart` (attach only) and rely on `Opt+s`. Decide during Step 4 with a live check; document the choice in the commit message.

- [ ] **Step 1: Update the existing picker tests** in `tests/test-tmux-auto.fish` — replace the two "picker auto-attaches" assertions so they reflect the reworked path (inside tmux opens the switcher; outside tmux ensures the server then attaches). Stub `__tcz_open_switcher` and `__tmux_ensure_server`/`__tmux_autostart`:

```fish
# picker: inside tmux opens the switcher (with --take on -t); outside tmux gets you in.
cleanup
functions -c __tcz_open_switcher __tl_os_bak 2>/dev/null
function __tcz_open_switcher; set -g g_sw "$argv"; end
set -gx TMUX fake
set -g g_sw ''; __tmux_lives_picker;    t "picker inside opens switcher" "yes" (string match -q '*' -- "$g_sw"; and echo yes; or echo no)
set -g g_sw ''; __tmux_lives_picker -t; t "picker -t threads take"      "yes" (string match -q '*--take*' -- "$g_sw"; and echo yes; or echo no)
set -e TMUX
functions -e __tcz_open_switcher; functions -q __tl_os_bak; and functions -c __tl_os_bak __tcz_open_switcher
cleanup
```

(Outside-tmux exec path is not unit-testable — it execs; verify it live in Step 4.)

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-auto.fish 2>&1 | grep '^FAIL.*picker'`
Expected: FAILs (picker still has the old body / doesn't thread take).

- [ ] **Step 3: Rework `__tmux_lives_picker`** in `conf.d/tmux.fish` — replace the whole function with:

```fish
function __tmux_lives_picker --description 'Open the categorized session switcher. tmux-lives picker [-t]'
    if not command -q tmux
        echo "tmux not installed" >&2
        return 1
    end
    set -l take ''
    contains -- -t $argv; or contains -- --take $argv; and set take --take
    if set -q TMUX
        set -l client (tmux display-message -p '#{client_name}' 2>/dev/null)
        env tmux_auto_ghost_minutes=$tmux_auto_ghost_minutes \
            fish --no-config $tmux_categorize_script open-switcher "$client" $take
        return
    end
    # Outside tmux: get into a session, then open the popup on the new client.
    __tmux_ensure_server
    __tmux_categorize
    set -l target (__tmux_pick_session)
    test -n "$target"; or set target (fish --no-config $tmux_categorize_script new-general)
    __tmux_detach_ghosts "$target"
    set -l pop "tmux display-popup -E -w 80% -h 70% -- fish --no-config $tmux_categorize_script popup ''"
    exec tmux -u attach-session -d -t "=$target" \; run-shell -b "$pop"
end
```

(Confirm `new-general` is the categorizer subcommand that prints a fresh `gen-N` name; it is — `__tcz_new_general`. If `attach \; run-shell -b` does not fire the popup live, replace the final two lines with `__tmux_autostart` per the fallback note.)

- [ ] **Step 4: Run tests + live-verify the outside-tmux popup**

Run: `fish tests/test-tmux-auto.fish 2>&1 | tail -1`
Expected: `ALL PASS`. Then live-verify on the host (or note it deferred): from a bare shell, `tmux-lives picker` attaches and opens the popup.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux.fish tests/test-tmux-auto.fish
git commit -m "feat: picker reworked — no name arg, -t take, auto-open popup outside tmux"
```

---

### Task 8: `setup` group (sub-dispatcher, help, nest verify/teardown/keys/auto)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — new `__tmux_lives_setup_help`, `__tmux_lives_keys_cmd`, `__tmux_lives_setup_dispatch`; factor `__tmux_lives_write_fragment`; change the `tmux-lives` dispatcher's `setup` case; remove top-level `verify`/`teardown`/`auto` cases
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces:
  - `__tmux_lives_write_fragment` — render the fragment + ensure the source line + reload tmux (factored out of the current `__tmux_lives_setup`).
  - `__tmux_lives_keys_cmd [-p K] [-s K]` — bare: print current keys; with flags: persist the universal var(s), then `__tmux_lives_write_fragment`.
  - `__tmux_lives_setup_help` — the setup-group help text.
  - `__tmux_lives_setup_dispatch <subcmd> [args]` — route `install`/`i`→`__tmux_lives_setup`, `verify`/`v`→status lines, `teardown`→`__tmux_lives_teardown`, `keys`→`__tmux_lives_keys_cmd`, `auto`→`__tmux_lives_auto`; bare/`-h`/`--help`/`help`→`__tmux_lives_setup_help`; unknown→stderr+help+rc1.

- [ ] **Step 1: Write failing routing tests** in `tests/test-tmux-install.fish` — replace the old top-level `setup --prefix-key` flag tests and the `alias v -> verify` test with the nested form:

```fish
# setup group routing
functions -c __tmux_lives_setup __tl_setup_real
function __tmux_lives_setup; set -g _tl_s install; end
function __tmux_lives_teardown; set -g _tl_s teardown; end 2>/dev/null
set -g _tl_s ''; tmux-lives setup install; t "setup install routes" install "$_tl_s"
set -g _tl_s ''; tmux-lives setup i;       t "setup i -> install"  install "$_tl_s"
t "setup verify shows keys" 1 (tmux-lives setup verify 2>/dev/null | string match -q '*switcher keys*'; and echo 1; or echo 0)
set -l sh (tmux-lives setup | string collect)
t "bare setup shows setup help" 1 (string match -q '*install, i*' -- "$sh"; and echo 1; or echo 0)
t "setup -h equals bare setup"  1 (test "$sh" = (tmux-lives setup -h | string collect); and echo 1; or echo 0)
t "setup help lists keys"  1 (string match -q '*keys*' -- "$sh"; and echo 1; or echo 0)
t "setup help lists auto"  1 (string match -q '*auto on*' -- "$sh"; and echo 1; or echo 0)
tmux-lives setup bogus 2>/dev/null; t "setup unknown rc1" 1 $status
functions -e __tmux_lives_setup; functions -c __tl_setup_real __tmux_lives_setup
# keys persistence
set -e tmux_lives_prefix_key
functions -c __tmux_lives_write_fragment __tl_wf_bak 2>/dev/null
function __tmux_lives_write_fragment; end
tmux-lives setup keys -p C-a
t "setup keys -p persists" "C-a" "$tmux_lives_prefix_key"
set -e tmux_lives_prefix_key
functions -q __tl_wf_bak; and begin; functions -e __tmux_lives_write_fragment; functions -c __tl_wf_bak __tmux_lives_write_fragment; end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL.*setup'`
Expected: FAILs.

- [ ] **Step 3: Factor `__tmux_lives_write_fragment`** out of the current `__tmux_lives_setup`. Read the current `__tmux_lives_setup` body; move the fragment-render + `__tmux_lives_ensure_source_line` + the `__tmux_lives_reload` portion into:

```fish
function __tmux_lives_write_fragment --description 'Render the managed fragment, wire ~/.tmux.conf, reload tmux'
    set -l cat "$__fish_config_dir/functions/tmux-categorize.fish"
    set -l tmuxdir "$HOME/.config/tmux"
    set -l fragment "$tmuxdir/tmux-lives.conf"
    mkdir -p $tmuxdir
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) > $fragment
    __tmux_lives_ensure_source_line "$HOME/.tmux.conf" $fragment
    __tmux_lives_reload
end
```

Then have `__tmux_lives_setup` call `__tmux_lives_write_fragment` in place of those inline lines (keep its plugin-clone + systemd + echo steps).

- [ ] **Step 4: Add `__tmux_lives_keys_cmd`, `__tmux_lives_setup_help`, `__tmux_lives_setup_dispatch`:**

```fish
function __tmux_lives_keys_cmd --description 'tmux-lives setup keys [-p K] [-s K]'
    if test (count $argv) -eq 0
        echo "switcher keys: prefix="(__tmux_lives_key tmux_lives_prefix_key S)"  no-prefix="(__tmux_lives_key tmux_lives_switcher_key M-s)
        return 0
    end
    set -l changed 0
    while test (count $argv) -ge 2
        switch $argv[1]
            case -p --prefix-key
                set -U tmux_lives_prefix_key $argv[2]; set changed 1; set -e argv[1..2]
            case -s --switcher-key
                set -U tmux_lives_switcher_key $argv[2]; set changed 1; set -e argv[1..2]
            case '*'
                echo "tmux-lives setup keys: unknown option '$argv[1]'" >&2; return 1
        end
    end
    if test (count $argv) -gt 0
        echo "tmux-lives setup keys: incomplete option '$argv[1]'" >&2; return 1
    end
    test $changed -eq 1; and __tmux_lives_write_fragment
end

function __tmux_lives_setup_help --description 'tmux-lives setup command list'
    printf '%s\n' \
        'tmux-lives setup — install & configuration' \
        '' \
        '  install, i                  wire ~/.tmux.conf + TPM/resurrect/continuum (+ systemd on Linux)' \
        '  verify, v                   install health + the active switcher keys' \
        '  teardown                    remove the wiring (plugin & TPM kept)' \
        '  keys                        show the current switcher keys' \
        "    -p, --prefix-key <key>    switcher bind in the prefix table   (default: S) ('' to disable)" \
        "    -s, --switcher-key <key>  switcher bind without prefix        (default: M-s = Opt+s) ('' to disable)" \
        '  auto on|off|toggle|status   auto-attach to tmux on SSH login'
end

function __tmux_lives_setup_dispatch
    switch "$argv[1]"
        case '' help -h --help
            __tmux_lives_setup_help
        case install i
            __tmux_lives_setup
        case verify v
            echo "tmux-lives verify:"
            __tmux_lives_status_lines | sed 's/^/  /'
        case teardown
            __tmux_lives_teardown
        case keys
            __tmux_lives_keys_cmd $argv[2..]
        case auto
            __tmux_lives_auto $argv[2..]
        case '*'
            echo "tmux-lives setup: unknown command '$argv[1]'" >&2
            __tmux_lives_setup_help >&2
            return 1
    end
end
```

- [ ] **Step 5: Rewire the top-level dispatcher** in `conf.d/tmux-lives-install.fish` — change `case setup` to route into the group and remove the standalone `verify v` / `teardown` / `auto` cases (they live under setup now). Delete `__tmux_lives_setup_cmd` (replaced by `__tmux_lives_keys_cmd`):

```fish
        case setup
            __tmux_lives_setup_dispatch $argv[2..]
```

- [ ] **Step 6: Run tests**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: nest install/verify/teardown/keys/auto under 'tmux-lives setup'"
```

---

### Task 9: remove `start`/`take`, rewrite main help, finalize dispatcher

**Files:**
- Modify: `conf.d/tmux.fish` (delete `__tmux_lives_start`, `__tmux_lives_take`)
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_help` rewrite; dispatcher: drop `start s` + `take t`; update the `tmux-lives` `--description`)
- Test: `tests/test-tmux-install.fish` (replace old help/alias assertions), `tests/test-tmux-auto.fish` (remove `start` behavior tests)

**Interfaces:**
- Produces: final `tmux-lives` dispatcher cases — `'' help -h --help`, `picker p`, `attach a`, `new n`, `close x q`, `clear`, `fixssh f`, `setup`, `*`(unknown→help+rc1).

- [ ] **Step 1: Update tests** — in `tests/test-tmux-install.fish`, replace the main-help assertions to expect the new flat surface and drop `start`/`take`:

```fish
t "help lists picker, p"  1 (string match -q '*picker, p*' -- "$hlp"; and echo 1; or echo 0)
t "help lists attach, a"  1 (string match -q '*attach, a*' -- "$hlp"; and echo 1; or echo 0)
t "help lists new, n"     1 (string match -q '*new, n*' -- "$hlp"; and echo 1; or echo 0)
t "help lists close"      1 (string match -q '*close, x, q*' -- "$hlp"; and echo 1; or echo 0)
t "help lists clear"      1 (string match -q '*clear*' -- "$hlp"; and echo 1; or echo 0)
t "help lists setup ptr"  1 (string match -q '*tmux-lives setup -h*' -- "$hlp"; and echo 1; or echo 0)
t "help drops start"      0 (string match -q '*start*' -- "$hlp"; and echo 1; or echo 0)
t "help drops top verify" 0 (string match -q '*verify, v*' -- "$hlp"; and echo 1; or echo 0)
```

Delete the now-obsolete assertions that referenced `start, s`, `take, t`, top-level `verify, v`, top-level `auto`, and the `alias s -> start`/`alias t -> take` routing lines + their stubs. In `tests/test-tmux-auto.fish`, delete the `__tmux_lives_start` behavior block (Task added earlier this session) since the function is removed.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: FAILs on the new help assertions.

- [ ] **Step 3: Rewrite `__tmux_lives_help`** in `conf.d/tmux-lives-install.fish`:

```fish
function __tmux_lives_help --description 'tmux-lives command list'
    printf '%s\n' \
        'tmux-lives — categorized tmux sessions, switcher & persistence' \
        '' \
        'USAGE' \
        '  tmux-lives <command> [options]' \
        '' \
        '  picker, p [-t]              open the session switcher (-t takes it)' \
        '  attach, a <name> [-t]       attach to a session (-t takes it)' \
        '  new, n [name]               start a new session (optional name)' \
        '  close, x, q                 kill the current session and exit' \
        '  clear [-q|-x]               kill idle sessions (-q/-x also exits)' \
        '  fixssh, f                   repair the SSH agent socket' \
        '  setup                       install / verify / keys / auto — run `tmux-lives setup -h`' \
        '' \
        'help                          show this help  (-h, --help)'
end
```

- [ ] **Step 4: Finalize the dispatcher** — the `tmux-lives` function's switch body becomes exactly:

```fish
    switch "$cmd"
        case '' help -h --help
            __tmux_lives_help
        case picker p
            __tmux_lives_picker $argv[2..]
        case attach a
            __tmux_lives_attach $argv[2..]
        case new n
            __tmux_lives_new $argv[2..]
        case close x q
            __tmux_lives_close
        case clear
            __tmux_lives_clear $argv[2..]
        case fixssh f
            __tmux_lives_fixssh
        case setup
            __tmux_lives_setup_dispatch $argv[2..]
        case '*'
            echo "tmux-lives: unknown command '$cmd'" >&2
            __tmux_lives_help >&2
            return 1
    end
```

Update the function description to `'tmux-lives: unified command — picker/attach/new/close/clear/fixssh/setup'`. In `conf.d/tmux.fish`, delete `__tmux_lives_start` and `__tmux_lives_take`.

- [ ] **Step 5: Run the full suite**

Run: `fish -c 'for t in tests/test-*.fish; echo ">>> $t"; fish $t | tail -1; end'`
Expected: every suite `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-install.fish tests/test-tmux-auto.fish
git commit -m "feat: finalize redesigned surface — drop start/take, flat main help"
```

---

### Task 10: docs (README + CLAUDE.md)

**Files:**
- Modify: `README.md` (command table)
- Modify: `CLAUDE.md` (status line — verb list + aliases)

- [ ] **Step 1: Update `README.md`** — replace the command block under "## Commands" with the new flat surface + a `setup` line:

```
tmux-lives picker, p [-t]             open the session switcher (-t takes it)
tmux-lives attach, a <name> [-t]      attach to a session (-t takes it)
tmux-lives new, n [name]              start a new session (optional name)
tmux-lives close, x, q                kill the current session and exit
tmux-lives clear [-q|-x]              kill idle sessions (-q/-x also exits)
tmux-lives fixssh, f                  repair the SSH agent socket
tmux-lives setup                      install / verify / keys / auto (see: tmux-lives setup -h)
```

Update the install example to `tmux-lives setup install` and any `tmux-lives verify` → `tmux-lives setup verify` / `switch`/`start` references.

- [ ] **Step 2: Update `CLAUDE.md`** — in the Status line, change the verb list to `picker/attach/new/close/clear/fixssh + setup{install,verify,teardown,keys,auto}` and the alias map to `p/a/n/x/q/f`; note `start`/`take` removed, `verify`/`teardown`/`auto`/keys nested under `setup`.

- [ ] **Step 3: Publish the README to the vault**

Run: `vault-publish --type docs $PWD/README.md --title "Tmux-lives Plugin - README"`
Expected: `Published: …`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: README + CLAUDE for the redesigned command surface"
```

---

## Self-Review

**Spec coverage:** picker/attach/new/close/clear (Tasks 7/4/3/5/6), `-t` take (Tasks 2/4/7), setup group + keys + auto (Task 8), restore-on-first-access (Task 1, consumed by 3/4/7), remove start/take + flat help (Task 9), docs (Task 10). All spec sections map to a task.

**Open verification items (call out, don't silently skip):** (a) `close` detach-to-shell with other sessions present — verified live, not in the headless suite; (b) `picker` outside-tmux auto-open popup — `attach \; run-shell` must be confirmed on 3.3a, documented fallback to `__tmux_autostart`. Both are flagged in their tasks with explicit fallbacks.

**Deployment:** verbs are plugin code → live via `fisher update` + `exec fish`. No fragment change in this plan, so no `setup install` re-run is required for the redesign itself.
