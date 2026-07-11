# Status-bar Reactive OSC Emission + Claude Accent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the status-bar tick from writing OSC title/bar-color escapes to the ShellFish tty every cycle (the cursor-flicker cause) by emitting only when a value changed, with a rare color-only backstop; and color the left-hand `claude` window name in a static brand orange.

**Architecture:** Cache the last title/color emitted **per tty** in tmux global options. The ~5–15s tick becomes a change-detector (dedup: emit only on difference); discrete events (attach / session-change / `setup color` / backstop) keep force-emitting and refresh the cache. A color-only re-emit every `@tmux_lives_heal_interval` seconds (default 120) heals tabs that silently dropped their color with no re-attach. Separately, a new `@tmux_lives_claude_color` tints the `claude` window name independent of the ShellFish theme.

**Tech Stack:** fish; tmux 3.3a global user-options as the per-tty cache; the existing `-L`-socket + `tmux`-stub test harnesses.

## Global Constraints

- **fish shell**; target **tmux 3.3a**; no new external dependencies.
- **Preserve the plumbing:** the tick still runs `__tcz_categorize` + emits; `status-right`/`status-format[0]`/`status-style`/continuum are unchanged. Only the *emit gating* changes.
- **Emit paths:** *forced* = unconditional + updates the cache (hooks `client-attached`/`client-session-changed`, `setup color`, backstop). *dedup* = emit only when the value differs from the per-tty cache (the tick only).
- **Per-tty cache:** tmux **global** options keyed by a sanitized tty (`@tmux_lives_emit_<key>_title` / `_color`). In-memory, no file I/O.
- **pts reuse** is handled by the forced emit on `client-attached` refreshing the cache; no detach-time pruning.
- **Backstop:** color-only, every `@tmux_lives_heal_interval` s (default **120**, `0` disables). Timer state in `@tmux_lives_heal_at` (next-heal epoch); the tick (fish) compares `date +%s`.
- **Claude accent:** `@tmux_lives_claude_color` default **`#D97757`**, quoted when emitted (unquoted `#hex` is a tmux comment → empty option). Exact match on `window_name == claude`.
- **Isolation invariant:** no test touches the live default socket — private `-L` sockets or the `tmux` stub only. Run the suite with `for t in tests/test-*.fish; fish $t; end` — all 8 end `ALL PASS`.
- **Do NOT deploy.** Edit → test → commit. The user runs `fisher update`.
- **Commit trailer:** end every commit with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- **`functions/tmux-categorize.fish`** — new cache helpers (`__tcz_emit_key`/`_get`/`_set`) near the emit functions (~line 99); `__tcz_recolor` (1065) and `__tcz_retitle` (1117) gain a `mode` arg + cache updates; `__tcz_on_attach` (1053) caches its direct barcolor emit; new `__tcz_heal_due` (backstop timer); `case tick` in `__tcz_main` (~1203) switches to dedup + backstop.
- **`conf.d/tmux-lives-install.fish`** — `__tmux_lives_render_fragment` seeds `@tmux_lives_heal_interval` + `@tmux_lives_claude_color` and makes `window-status-format`/`-current-format` conditional on `window_name == claude`.
- **Tests:** `tests/test-tmux-categorize.fish` (dedup + backstop, tmux-stub style), `tests/test-tmux-install.fish` (fragment seeds + window-status conditional + `-L` parse).

---

## Task 1: per-tty emit cache + dedup mode

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_emit_key`/`_get`/`_set`; add `mode` + cache to `__tcz_recolor` (1065-1075) and `__tcz_retitle` (1117-1128); cache the direct emit in `__tcz_on_attach` (1055).
- Test: `tests/test-tmux-categorize.fish` (new block)

**Interfaces:**
- Produces: `__tcz_emit_key <tty>` → option-safe key; `__tcz_emit_get <tty> title|color` → cached value; `__tcz_emit_set <tty> title|color <value>` → caches it. `__tcz_recolor <color> [mode]` and `__tcz_retitle [mode]`: `mode=dedup` emits only on change; anything else (incl. empty) forces. Both update the cache on emit.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish` (near the other recolor/retitle tests; self-contained block):

```fish
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
        case show; echo $DEDUP_color            # show -gv @..._color
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: `emit_key …` fails (`__tcz_emit_key` unknown) and the `recolor dedup …`/`caches …` lines fail (no `mode`, no caching). `SOME FAILED`.

- [ ] **Step 3: Implement the cache helpers**

Add to `functions/tmux-categorize.fish` immediately after `__tcz_emit_barcolor` (before `__tcz_hostname`/the other helpers ~line 104):

```fish
function __tcz_emit_key --argument-names tty --description 'sanitize a client tty into an @option-safe key (/dev/pts/9 -> devpts9)'
    string replace -ra '[^a-zA-Z0-9]' '' -- "$tty"
end
function __tcz_emit_get --argument-names tty field --description 'read the last-emitted <field> (title|color) cached for <tty>'
    tmux show -gv @tmux_lives_emit_(__tcz_emit_key $tty)_$field 2>/dev/null
end
function __tcz_emit_set --argument-names tty field value --description 'cache the last-emitted <field> (title|color) for <tty>'
    tmux set -g @tmux_lives_emit_(__tcz_emit_key $tty)_$field "$value" 2>/dev/null
end
```

- [ ] **Step 4: Add `mode` + caching to `__tcz_recolor` and `__tcz_retitle`**

Replace `__tcz_recolor` (currently 1065-1075) with:

```fish
function __tcz_recolor --argument-names color mode --description 'emit the ShellFish bar-color OSC to attached ShellFish clients. mode=dedup emits only when the color changed for that tty; else force. Updates the per-tty cache on emit.'
    test -n "$color"; or return 0
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; or continue
        test "$mode" = dedup; and test "$color" = (__tcz_emit_get $tty color); and continue
        __tcz_emit_barcolor $tty $color
        __tcz_emit_set $tty color $color
    end
end
```

Replace `__tcz_retitle` (currently 1117-1128) with:

```fish
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
        test "$mode" = dedup; and test "$title" = (__tcz_emit_get $tty title); and continue
        __tcz_emit_title $tty $title
        __tcz_emit_set $tty title $title
    end
end
```

In `__tcz_on_attach` (line 1055), cache the direct barcolor emit so the first tick doesn't re-fire. Change:

```fish
        __tcz_emit_barcolor $tty $color
        __tcz_retitle
```
to:
```fish
        __tcz_emit_barcolor $tty $color
        __tcz_emit_set $tty color $color
        __tcz_retitle
```

(The `__tcz_retitle` call here stays force — an attach is a discrete event, and forcing refreshes the cache for a reused pts.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the `emit_key …`/`recolor …` lines `ok`; `ALL PASS`.

- [ ] **Step 6: Run the full suite; fix any stub that now needs the cache calls**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: all 8 `ALL PASS`. If a pre-existing recolor/retitle test fails because its `tmux` stub doesn't tolerate the new `show`/`set` cache calls, add a catch-all `case '*'` (and, if it asserts the *count* of emits, note the cache `set` is a separate `tmux set` call, not an emit). Do not weaken an emit assertion — only make the stub tolerate the extra cache calls.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(bar): per-tty emit cache + dedup mode (emit only on change)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: tick uses dedup + color-only backstop

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_heal_due`; rewrite `case tick` (~1203-1207).
- Test: `tests/test-tmux-categorize.fish` (new block)

**Interfaces:**
- Consumes: `__tcz_recolor`/`__tcz_retitle` (Task 1).
- Produces: `__tcz_heal_due <now_epoch>` — returns 0 (due) when `@tmux_lives_heal_interval` > 0 and `now >= @tmux_lives_heal_at` (unset = due), advancing `@tmux_lives_heal_at` to `now + interval`; returns 1 (not due) otherwise, including interval `0`. Default interval 120 when the option is unset.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`:

```fish
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: `heal …` lines fail (`__tcz_heal_due` unknown). `SOME FAILED`.

- [ ] **Step 3: Implement `__tcz_heal_due`**

Add to `functions/tmux-categorize.fish` (near `__tcz_recolor`):

```fish
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
```

- [ ] **Step 4: Rewrite `case tick`**

In `__tcz_main`, replace the `case tick` body (currently):
```fish
        case tick
            __tcz_categorize >/dev/null 2>&1
            test -n "$argv[2]"; and __tcz_recolor $argv[2]
            __tcz_retitle
            return 0
```
with:
```fish
        case tick
            __tcz_categorize >/dev/null 2>&1
            test -n "$argv[2]"; and __tcz_recolor $argv[2] dedup
            __tcz_retitle dedup
            test -n "$argv[2]"; and __tcz_heal_due (date +%s); and __tcz_recolor $argv[2]
            return 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the `heal …` lines `ok`; `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: all 8 `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(bar): tick emits dedup'd + color-only heal backstop (kills the 5s OSC flicker)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: fragment — seed heal-interval + claude-color; tint the `claude` window

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (@option seeds ~72-77; window-status lines 64-65).
- Test: `tests/test-tmux-install.fish` (extend the status-bar fragment block; update the existing `window-status-format '#W'` assertion).

**Interfaces:**
- Consumes: the fragment's existing `set -a f` accumulation.
- Produces: a fragment that seeds `@tmux_lives_heal_interval 120` and `@tmux_lives_claude_color '#D97757'`, and whose `window-status-format`/`-current-format` render the name in `@tmux_lives_claude_color` when `window_name == claude`.

- [ ] **Step 1: Write the failing tests**

First, UPDATE the existing names-only assertion in `tests/test-tmux-install.fish` (find it: `grep -n "window-status-format names-only" tests/test-tmux-install.fish`). Replace that single `t …` line with:

```fish
t "fragment window-status-format tints the claude window" yes (string match -q "*set -g window-status-format '#{?#{==:#{window_name},claude}*" -- "$BAR"; and string match -q '*#{@tmux_lives_claude_color}*' -- "$BAR"; and echo yes; or echo no)
```

Then add, in the same status-bar fragment block (where `$BAR` is the rendered fragment string — mirror the block's existing render call, e.g. `set -g BAR (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s | string collect)`):

```fish
t "fragment seeds @tmux_lives_claude_color (quoted hex)" yes (string match -q "*set -g @tmux_lives_claude_color '#D97757'*" -- "$BAR"; and echo yes; or echo no)
t "fragment seeds @tmux_lives_heal_interval" yes (string match -q '*set -g @tmux_lives_heal_interval 120*' -- "$BAR"; and echo yes; or echo no)
t "fragment current-format keeps bold + tints claude" yes (string match -q '*window-status-current-format*#\[bold\]*#{?#{==:#{window_name},claude}*' -- "$BAR"; and echo yes; or echo no)
```

(If the existing block already renders `$BAR`/`$FRAGS` once, reuse that variable instead of re-rendering.)

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: the new/updated `fragment …` lines fail. `SOME FAILED`.

- [ ] **Step 3: Implement — seed the two @options**

In `__tmux_lives_render_fragment` (`conf.d/tmux-lives-install.fish`), after the `@tmux_lives_resize_color` seed (line 75), add:

```fish
    set -a f "set -g @tmux_lives_claude_color '#D97757'"   # Claude coral; static, independent of the ShellFish bar color
    set -a f "set -g @tmux_lives_heal_interval 120"        # color-only self-heal backstop seconds (0 = off)
```

- [ ] **Step 4: Implement — tint the `claude` window name**

Replace the two window-status lines (currently 64-65):
```fish
    set -a f "set -g window-status-format '#W'"
    set -a f "set -g window-status-current-format '#[bold]#W#[nobold]'"
```
with:
```fish
    # tint the auto-named `claude` window in @tmux_lives_claude_color; reset fg after so the
    # separator / other windows are unaffected. Position unchanged; current stays bold.
    set -a f "set -g window-status-format '#{?#{==:#{window_name},claude},#[fg=#{@tmux_lives_claude_color}]#W#[fg=default],#W}'"
    set -a f "set -g window-status-current-format '#[bold]#{?#{==:#{window_name},claude},#[fg=#{@tmux_lives_claude_color}]#W#[fg=default],#W}#[nobold]'"
```

- [ ] **Step 5: Run the install suite**

Run: `fish tests/test-tmux-install.fish`
Expected: the new `fragment …` lines `ok`; the existing `-L`-socket parse test (rendered fragment sources rc0) still passes; `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: all 8 `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(bar): seed heal-interval + claude-color; tint the claude window name

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual smoke (runtime-only — after the user's `fisher update`)

- Flicker: with the scratch pane open or Claude streaming, the cursor no longer blinks in steady state; the tab title/color still update within a few seconds on a `cd` / claude start-stop / `setup color`.
- Backstop: `tmux set -g @tmux_lives_heal_interval 10` → a faint color re-emit every ~10s; `0` → none. Restore to 120.
- Claude accent: the left-hand `claude` window name renders in coral `#D97757`; `tmux set -g @tmux_lives_claude_color '#7dd3fc'` retints it live with no re-render; non-`claude` windows are unaffected.

---

## Self-Review

**Spec coverage:** dedup emit-on-change → Task 1 (`mode`); per-tty cache → Task 1 (`__tcz_emit_key/_get/_set`); forced paths update cache → Task 1 (recolor/retitle/on-attach); tick dedup + backstop → Task 2 (`case tick` + `__tcz_heal_due`); `@tmux_lives_heal_interval` knob → Task 2 (read) + Task 3 (seed); Claude accent `@tmux_lives_claude_color` + `claude`-window tint → Task 3; pts-reuse via forced attach → Task 1 (on-attach force + cache); isolation/tests → stub + `-L` throughout. ✓

**Placeholder scan:** every step has concrete code/commands + expected output; no TBD/TODO.

**Type/name consistency:** `__tcz_emit_key`/`_get`/`_set`, `__tcz_recolor <color> [mode]`, `__tcz_retitle [mode]`, `__tcz_heal_due <now>`, option names `@tmux_lives_emit_<key>_title|_color`, `@tmux_lives_heal_interval`, `@tmux_lives_heal_at`, `@tmux_lives_claude_color` are used identically across tasks.
