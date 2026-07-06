# ShellFish Tab Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each ShellFish tab a title `<host>: <dir> [(C)]` by writing the standard OSC 2 title escape directly to each ShellFish client's tty, refreshed on attach, session-change, and the ~15s tick.

**Architecture:** Mirror the existing bar-color emit path. Pure title builders (`__tcz_hostname`/`__tcz_dir_display`/`__tcz_format_title`) → an emitter (`__tcz_emit_title`, OSC 2 to tty) and a per-client re-titler (`__tcz_retitle`, iterates ShellFish clients and titles each from its own session) → wired into the `tick` verb, `__tcz_on_attach`, and a `client-session-changed` fragment hook.

**Tech Stack:** fish shell, tmux 3.3a, the ShellFish OSC-to-tty path.

## Global Constraints

- **Test runner:** `fish tests/test-<suite>.fish`. Full gate: `fish -c 'for t in tests/test-*.fish; fish $t; end'` — every suite prints `ALL PASS`, 0 FAIL (ignorable known flake: `test-tmux-restore.fish` may emit one stderr "no server running…" line; `test-tmux-categorize.fish` has an occasional `cmdline: found via child pgrep` timing flake — re-run to confirm green).
- **Hard isolation invariant:** no test may touch the live default-socket tmux server or universals. Mirror the existing recolor block (`tests/test-tmux-categorize.fish:563-599`): a `function tmux` stub, temp files as ttys (`$tt1`/`$tt2`), `tmux_lives_fake_environ` for ShellFish detection, and `tmux_lives_hostname` as the host seam. The fragment-render test is pure (render-to-string).
- **OSC 2 (exact):** `printf '\033]2;%s\a' "$title" > $tty` — plain OSC 2 (no tmux passthrough), direct to the client tty, exactly like `__tcz_emit_barcolor` (`functions/tmux-categorize.fish:97-100`).
- **Title format (exact):** `<host>: <dir>` with ` (C)` appended iff claude runs in the session. host = `hostname -s` (seam/cache `tmux_lives_hostname`); dir = `$HOME` → `~`, else `basename`; `(C)` = session-wide claude (any pane, via `__tcz_pane_is_claude`).
- **ShellFish-gated** via `__tcz_client_is_shellfish` (`functions/tmux-categorize.fish:92-95`). Non-ShellFish clients are untouched.
- fish `math` has NO comparison operators — use `test`.
- Commit trailer (verbatim): `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Do NOT deploy (no `fisher`); do NOT edit `~/.config/fish`, `~/.config/tmux`, or `~/.tmux.conf`.
- Branch: `feat/shellfish-tab-title` (already checked out; the spec is committed there).

## File Structure

- `functions/tmux-categorize.fish` — all new functions (`__tcz_hostname`, `__tcz_dir_display`, `__tcz_format_title`, `__tcz_emit_title`, `__tcz_session_has_claude`, `__tcz_session_title`, `__tcz_retitle`), the `retitle` verb, the tick re-emit, and the `__tcz_on_attach` re-title. Placed next to their bar-color siblings.
- `conf.d/tmux-lives-install.fish` — one line added to the `client-session-changed` hook in `__tmux_lives_render_fragment`.
- `tests/test-tmux-categorize.fish` — title-builder + emit + retitle tests.
- `tests/test-tmux-install.fish` — fragment-render assertion.
- `CLAUDE.md` — one documenting sentence.

---

### Task 1: Pure title builders

**Files:**
- Modify: `functions/tmux-categorize.fish` (add three functions near `__tcz_emit_barcolor`, ~line 100)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_hostname` → short hostname (cache/seam `tmux_lives_hostname`); `__tcz_dir_display <path>` → `~` for `$HOME` else basename; `__tcz_format_title <host> <dir> <is_claude>` → `"<host>: <dir>"` + ` (C)` when `<is_claude>` is `1`.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish`, near the top-level helper tests (after the existing `__tcz_emit_barcolor` tests, ~line 105), add:

```fish
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
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_hostname`/`__tcz_dir_display`/`__tcz_format_title` are undefined (`SOME FAILED`).

- [ ] **Step 3: Implement the three functions.** In `functions/tmux-categorize.fish`, immediately after `__tcz_emit_barcolor` (ends ~line 100), add:

```fish
function __tcz_hostname --description 'short hostname (cache + test seam: tmux_lives_hostname)'
    if not set -q tmux_lives_hostname; or test -z "$tmux_lives_hostname"
        set -g tmux_lives_hostname (hostname -s 2>/dev/null)
        test -n "$tmux_lives_hostname"; or set -g tmux_lives_hostname (uname -n 2>/dev/null | string split -f1 .)
    end
    echo $tmux_lives_hostname
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
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS — the five new assertions `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(title): pure title builders (hostname, dir_display, format_title)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Emit + per-client re-title

**Files:**
- Modify: `functions/tmux-categorize.fish` (add near `__tcz_recolor`, ~line 1008)
- Test: `tests/test-tmux-categorize.fish` (inside/after the recolor block, ~line 599)

**Interfaces:**
- Consumes: `__tcz_hostname`, `__tcz_dir_display`, `__tcz_format_title` (Task 1); `__tcz_client_is_shellfish` (existing, `:92-95`); `__tcz_pane_is_claude` (existing, `:121-137`).
- Produces: `__tcz_emit_title <tty> <title>` (writes OSC 2, empty-title no-op); `__tcz_session_has_claude <session>` (any pane runs claude); `__tcz_session_title <session>` → `"<host>: <dir>[ (C)]"`; `__tcz_retitle` (titles every attached ShellFish client from its own `#{client_session}`).

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish`, immediately AFTER the recolor block's last teardown `set -e tmux_lives_fake_environ` (~line 599), add:

```fish
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
        case display-message   # __tcz_session_title reads only #{pane_current_path}
            echo /home/x/workspace/tmux-lives
        case list-panes        # __tcz_session_has_claude reads cmd\tpid per pane
            printf '%s\n' $tcz_test_panes
    end
end
set -g __tcz_oldhome $HOME; set -g HOME /home/x; set -g tmux_lives_hostname macwork
set -g tcz_test_panes (printf 'fish\t999')
t "session_has_claude false for shells" no (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title no claude" "macwork: tmux-lives" (__tcz_session_title sA)
set -g tcz_test_panes (printf 'claude\t999')
t "session_has_claude true with a claude pane" yes (__tcz_session_has_claude sA; and echo yes; or echo no)
t "session_title with claude" "macwork: tmux-lives (C)" (__tcz_session_title sA)
functions -e tmux
set -g HOME $__tcz_oldhome; set -e __tcz_oldhome; set -e tmux_lives_hostname; set -e tcz_test_panes

# retitle: per-client loop, ShellFish-gated. Stub session_title + list-clients.
set -g rt1 /tmp/tcz-rt1-$fish_pid; set -g rt2 /tmp/tcz-rt2-$fish_pid
rm -f $rt1 $rt2; touch $rt1 $rt2
functions -c __tcz_session_title __tcz_st_bak
function __tcz_session_title; echo "macwork: dirX"; end
function tmux
    test "$argv[1]" = list-clients; and printf '111\t%s\tsA\n222\t%s\tsB\n' "$rt1" "$rt2"
end
set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_retitle
t "retitle titles shellfish client 1" yes (string match -q '*dirX*' -- (cat $rt1 | string collect); and echo yes; or echo no)
t "retitle titles shellfish client 2" yes (string match -q '*dirX*' -- (cat $rt2 | string collect); and echo yes; or echo no)
rm -f $rt1; touch $rt1
set -gx tmux_lives_fake_environ "TERM=xterm"
__tcz_retitle
t "retitle skips non-shellfish client" no (test -s $rt1; and echo yes; or echo no)
functions -e tmux; functions -e __tcz_session_title; functions -c __tcz_st_bak __tcz_session_title; functions -e __tcz_st_bak
set -e tmux_lives_fake_environ
rm -f $rt1 $rt2
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_emit_title`/`__tcz_session_has_claude`/`__tcz_session_title`/`__tcz_retitle` undefined.

- [ ] **Step 3: Implement the emit + retitle functions.** In `functions/tmux-categorize.fish`, immediately after `__tcz_recolor` (ends ~line 1008), add:

```fish
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

function __tcz_session_title --argument-names session --description 'session -> "<host>: <dir>[ (C)]" (active-pane dir; session-wide claude)'
    test -n "$session"; or return 0
    set -l path (tmux display-message -p -t "=$session" '#{pane_current_path}' 2>/dev/null)
    set -l claude 0
    __tcz_session_has_claude $session; and set claude 1
    __tcz_format_title (__tcz_hostname) (__tcz_dir_display $path) $claude
end

function __tcz_retitle --description 'emit each attached ShellFish client its own OSC 2 title (per client session)'
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}$TAB#{client_session}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        set -l session $parts[3]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; or continue
        __tcz_emit_title $tty (__tcz_session_title $session)
    end
end
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS — the new assertions `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(title): OSC 2 emit + per-client retitle (session-scoped)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Wire it up (verb, tick, on-attach, fragment) + docs

**Files:**
- Modify: `functions/tmux-categorize.fish` (`__tcz_main` verb + `tick` case + `__tcz_on_attach`)
- Modify: `conf.d/tmux-lives-install.fish` (the `client-session-changed` hook, ~line 85)
- Modify: `CLAUDE.md`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tcz_retitle` (Task 2).
- Produces: `__tcz_main retitle` re-titles all ShellFish clients; the `tick` verb re-titles every ~15s; `client-attached` (via `__tcz_on_attach`) and `client-session-changed` re-title.

- [ ] **Step 1: Write the failing fragment test.** In `tests/test-tmux-install.fish`, in the fragment-render section (near the existing tick/hook assertions), add:

```fish
set -g FRAGT2 (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 | string collect)
t "client-session-changed hook re-titles" yes (string match -q "*client-session-changed*cat.fish retitle*" -- "$FRAGT2"; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — the rendered `client-session-changed` hook has no `retitle` yet (`FAILED`).

- [ ] **Step 3: Add the `retitle` verb + tick re-emit + on-attach re-title.** In `functions/tmux-categorize.fish`:

(a) The `tick` case in `__tcz_main` (currently `:1083-1086`) — add the retitle line:

```fish
        case tick
            __tcz_categorize >/dev/null 2>&1
            test -n "$argv[2]"; and __tcz_recolor $argv[2]
            __tcz_retitle
            return 0
```

(b) Add a `retitle` verb to `__tcz_main` — immediately after the `case recolor` arm (`:1115-1116`):

```fish
        case retitle
            __tcz_retitle
```

(c) `__tcz_on_attach` (`:987-996`) — re-title ShellFish clients after the bar color. Change the ShellFish branch:

```fish
    if __tcz_client_is_shellfish $pid
        __tcz_emit_barcolor $tty $color
        __tcz_retitle
```

- [ ] **Step 4: Add `retitle` to the `client-session-changed` fragment hook.** In `conf.d/tmux-lives-install.fish`, the hook currently (`:85-89`) reads:

```fish
    set -a f "set-hook -g client-session-changed {"
    set -a f "    if-shell -F '#{m:shellfish-*,#{client_session}}' {"
    set -a f "        run-shell \"fish --no-config $cat commandeer '#{client_name}' '#{client_session}'\""
    set -a f "    }"
    set -a f "}"
```

Insert a `retitle` run-shell as the first line inside the hook:

```fish
    set -a f "set-hook -g client-session-changed {"
    set -a f "    run-shell \"fish --no-config $cat retitle\""
    set -a f "    if-shell -F '#{m:shellfish-*,#{client_session}}' {"
    set -a f "        run-shell \"fish --no-config $cat commandeer '#{client_name}' '#{client_session}'\""
    set -a f "    }"
    set -a f "}"
```

- [ ] **Step 5: Run the fragment test + the categorize suite.**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS — `client-session-changed hook re-titles` `ok`, `ALL PASS`.
Run: `fish tests/test-tmux-categorize.fish`
Expected: `ALL PASS` (the tick/on-attach changes don't regress; the retitle in the tick is exercised where the tick block runs against the stubs).

- [ ] **Step 6: Document in CLAUDE.md.** In the status-bar/ShellFish paragraph (near the `__tcz_recolor` / tick self-heal sentence), add:

```
ShellFish tabs also get a per-tab TITLE via OSC 2 written straight to the client tty (`__tcz_emit_title`, mirroring `__tcz_emit_barcolor`): `<host>: <dir> [(C)]` — `hostname -s` (seam `tmux_lives_hostname`), the client session's active-pane dir basename (`$HOME`→`~`), and ` (C)` when any pane runs claude. `__tcz_retitle` iterates `list-clients` (carrying `#{client_session}`) and titles each ShellFish client from its own session; wired on `client-attached` (via `__tcz_on_attach`), a `client-session-changed` fragment hook, and the ~15s tick (`retitle` verb).
```

- [ ] **Step 7: Full gate + confirm no live leak.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'` → all 8 suites `ALL PASS`, 0 FAIL (ignore the restore-suite stderr flake; re-run the categorize suite once if the `cmdline` timing flake shows).
Run: `grep -c retitle ~/.config/tmux/tmux-lives.conf` → confirms the suite did NOT rewrite your live fragment (its value is your deployed state, not a test write).

- [ ] **Step 8: Commit.**

```bash
git add functions/tmux-categorize.fish conf.d/tmux-lives-install.fish tests/test-tmux-install.fish CLAUDE.md
git commit -m "feat(title): wire retitle into tick, on-attach, and client-session-changed

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** OSC 2 to client tty (`__tcz_emit_title`, T2) ✓; per-client/per-view retitle (`__tcz_retitle` carrying `#{client_session}`, T2) ✓; content `<host>: <dir> [(C)]` with hostname/dir/claude (T1 builders + `__tcz_session_title`, T2) ✓; refresh on attach (on-attach, T3) / session-change (fragment hook, T3) / tick (T3) ✓; ShellFish-gated (`__tcz_client_is_shellfish`) ✓; pure `__tcz_format_title` split for testability ✓; isolation via stubs + `tmux_lives_hostname` + `tmux_lives_fake_environ` (all tasks) ✓; docs (T3) ✓. Non-goals (no toggle, no non-ShellFish title, no window-switch hook) correctly omitted.
- **Placeholder scan:** none — every step carries exact code/commands.
- **Type/name consistency:** `__tcz_hostname`/`__tcz_dir_display`/`__tcz_format_title` (T1) are consumed verbatim by `__tcz_session_title` (T2); `__tcz_retitle` (T2) is the single entry the verb/tick/on-attach/fragment (T3) all call; the emit is `__tcz_emit_title <tty> <title>` everywhere; the fragment verb `retitle` matches `__tcz_main`'s `case retitle`.
