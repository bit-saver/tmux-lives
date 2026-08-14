# Shell Auto-reload After Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a `fisher update`, every other running fish shell refreshes the plugin's functions in place — including panes running Claude — instead of the user running `exec fish` in each one.

**Architecture:** The updater sets a universal variable; a `--on-variable` handler in every running shell re-sources the two `conf.d` files. No `send-keys`, so nothing is ever typed into a pane. A tty foreground-process-group check decides whether the shell is idle enough to print a notice.

**Tech Stack:** fish 4.7.1, tmux 3.3a. No new files, no dependencies.

## Global Constraints

- **One conf.d file per feature; ZERO net new files in `conf.d/` or `functions/`.** Everything here goes in the existing `conf.d/tmux-lives-install.fish`.
- **Never deploy.** Edit → test → commit → push, then stop. The user runs `fisher update` themselves.
- **The full gate is:** `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'` — run FOREGROUND with an explicit `timeout: 300000`. It exceeds the Bash tool's 120 s default and is otherwise auto-backgrounded, which has stalled six subagents across previous builds.
- **`test-tmux-install.fish` counts differ by exactly 1 between plain fish and `--no-config`.** BY DESIGN. Never "fix" it.
- **A test must never write to the user's real universal store.** Every suite opens with the `XDG_CONFIG_HOME` self-re-exec guard; a `set -U tmux_lives_reload_token` that escaped it would fire handlers in the user's live shells.
- **A pty probe that `wait`s on an interactive fish hangs** — the shell outlives its sourced command. Bound every pty harness with `timeout` and never block on it. (I hit this twice writing this plan.)
- **Every assertion in this plan must be run against the pre-fix code and shown to FAIL before it is trusted.** Nineteen plan defects were found across the previous eight-task build, every one by an implementer or reviewer. If an assertion passes before you make the change, that is a plan bug to report, never a test to soften.

---

## Measured facts this plan is built on

Verified directly in an isolated `XDG_CONFIG_HOME`, not assumed:

| fact | measured |
|---|---|
| `--on-variable` fires in an **already-running** shell | yes |
| it fires **while a foreground child is running** | yes — one firing while a 12 s `sleep` held the terminal |
| firings per single `set -U` | **2** — idempotency is mandatory |
| setting the **same value** still fires | yes — change-detection must live in the emitter |
| `/proc/<pid>/stat` with no tty | `tpgid -1` → predicate must report "not idle" |
| at a prompt with a tty | `tpgid == pgid` → idle |

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `conf.d/tmux-lives-install.fish` | the predicate, the handler, the trigger, the note | 1–4 |
| `tests/test-tmux-install.fish` | all assertions | 1–4 |

---

### Task 1: `__tmux_lives_shell_is_idle`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add beside the other `__tmux_lives_*` helpers, above `__tmux_lives_update_note`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_shell_is_idle` — no arguments, returns 0 when this shell owns its terminal (no foreground child), 1 otherwise and whenever it cannot tell.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 1: the idle predicate ---------------------------------------------
t "is_idle: function exists" 1 (functions -q __tmux_lives_shell_is_idle; and echo 1; or echo 0)
# No controlling tty -> tpgid is -1 -> must report NOT idle. "Unsure" has to mean
# "do not print", because every wrong answer here corrupts someone's editor frame.
set -g __t1_notty (fish --no-config -c "set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo IDLE; or echo BUSY" 2>/dev/null)
t "is_idle: no controlling tty reports BUSY" BUSY "$__t1_notty"
```

Then the pty half — the two cases that cannot be observed without a terminal:

```fish
# At a prompt the shell owns the tty; inside a foreground child it does not.
# `timeout` is mandatory: an interactive fish outlives its -C command and a
# bare wait would hang the suite.
set -g __t1_pty (timeout 20 script -qfec "fish --no-config -i -C 'set -g tmux_categorize_test 1; source $plugindir/conf.d/tmux-lives-install.fish; __tmux_lives_shell_is_idle; and echo AT-PROMPT-IDLE; or echo AT-PROMPT-BUSY; exit'" /dev/null 2>/dev/null | tr -d '\r')
t "is_idle: at a prompt with a tty reports IDLE" 1 (string match -q '*AT-PROMPT-IDLE*' -- "$__t1_pty"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run it and verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'is_idle|FAIL' | head`
Expected: every `is_idle:` line FAILS — the function does not exist. Confirm they are real assertion failures with printed values, not silent aborts.

- [ ] **Step 3: Implement**

Add to `conf.d/tmux-lives-install.fish`:

```fish
function __tmux_lives_shell_is_idle --description 'True when this shell owns its terminal — no foreground child is running. Compares the ttys foreground process group against the shells own pgid: Linux reads /proc/<pid>/stat, macOS falls back to ps, mirroring the __tcz_pid_comm/__tcz_pid_cmdline split. With no controlling tty (tpgid -1) it returns FALSE ON PURPOSE: the only consumer is a notice printed to a live terminal, so "unsure" must mean "do not print". Known edge, accepted: a long-running fish FUNCTION forks nothing, so fish itself stays in the foreground and reads as idle — fish dispatches events between statements, so the window is small.'
    set -l pid $fish_pid
    set -l tp ''
    set -l pg ''
    if test -r /proc/$pid/stat
        # comm (field 2) is parenthesised and may itself contain spaces, so strip
        # through the LAST ") " before splitting. What remains is
        # [1]=state [2]=ppid [3]=pgrp [4]=session [5]=tty_nr [6]=tpgid
        set -l rest (string replace -r '^.*\) ' '' < /proc/$pid/stat)
        set -l f (string split ' ' -- $rest)
        set pg "$f[3]"
        set tp "$f[6]"
    else
        set -l out (ps -o tpgid=,pgid= -p $pid 2>/dev/null | string trim | string split -n ' ')
        set tp "$out[1]"
        set pg "$out[2]"
    end
    # Guard the numeric compares: a non-numeric field would make `test -gt` error
    # to stderr, and this runs inside an event handler where that lands on the tty.
    string match -qr '^-?[0-9]+$' -- "$tp"; or return 1
    string match -qr '^-?[0-9]+$' -- "$pg"; or return 1
    test "$tp" -gt 0; or return 1
    test "$tp" = "$pg"
end
```

- [ ] **Step 4: Prove the BUSY case with a pty — this is the assertion that matters**

The no-tty and at-prompt cases above are already verified. The case the whole design rests on — *the predicate reports BUSY when called while a foreground child holds the terminal* — has **not** been verified and is yours to prove. Build a pty harness in which the predicate is called from inside a `--on-variable` handler while a `sleep` holds the foreground, and assert it reports BUSY.

Shape that is known to work (from this plan's own research): start `timeout 25 script -qfec "fish -i -C 'touch <marker>; sleep 12'" /dev/null &`, poll for the marker, then set the universal from a second fish with the same `XDG_CONFIG_HOME`. Have the handler append the predicate's verdict to a file and assert it says BUSY.

**If it reports IDLE while a child is running, stop and report it** — that would invalidate the "print when idle" decision, and the fallback is an always-silent handler.

- [ ] **Step 5: Run the tests and the full gate**

Run `fish tests/test-tmux-install.fish 2>&1 | tail -3`, then the full gate (foreground, `timeout: 300000`).
Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(update): add __tmux_lives_shell_is_idle

Compares the tty's foreground process group against the shell's own.
Returns false with no controlling tty -- the only consumer prints to a
live terminal, so 'unsure' must mean 'do not print'."
```

---

### Task 2: `__tmux_lives_shell_reload` — the handler

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add immediately after `__tmux_lives_shell_is_idle`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_shell_is_idle` (Task 1).
- Produces: `__tmux_lives_shell_reload`, registered `--on-variable tmux_lives_reload_token`. Reads the universal `tmux_lives_autoreload` (`0` disables) and the global `__tmux_lives_reloaded_at` (its own dedup marker).

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 2: the reload handler ---------------------------------------------
t "reload: handler exists" 1 (functions -q __tmux_lives_reload; and echo 1; or echo 0)
set -g __t2_body (functions __tmux_lives_reload | string collect)
t "reload: registered on the token variable" 1 (string match -q '*--on-variable tmux_lives_reload_token*' -- "$__t2_body"; and echo 1; or echo 0)
t "reload: bails when not interactive" 1 (string match -q '*status is-interactive*' -- "$__t2_body"; and echo 1; or echo 0)
t "reload: honours the opt-out" 1 (string match -q '*tmux_lives_autoreload*' -- "$__t2_body"; and echo 1; or echo 0)
# It must re-source the two conf.d files and NOT functions/tmux-categorize.fish,
# which is only ever invoked as a script (see the spec for why).
t "reload: re-sources tmux.fish" 1 (string match -q '*conf.d/tmux.fish*' -- "$__t2_body"; and echo 1; or echo 0)
t "reload: re-sources the install file" 1 (string match -q '*tmux-lives-install.fish*' -- "$__t2_body"; and echo 1; or echo 0)
# ⚠ `functions <name>` prints the DESCRIPTION as well as the body, so this
# assertion is defeated if the handler's own description spells the categorizer's
# filename — which an earlier draft of this plan did, and which would have failed
# against correct code. This repo has hit the describe-a-banned-shape trap nine
# times. The description below therefore refers to it WITHOUT the literal path,
# and this assertion strips the description line before matching.
set -g __t2_bodyonly (functions __tmux_lives_reload | string match -v -r '^\s*#|--description' | string collect)
t "reload: body-only extraction is non-empty" 1 (test -n "$__t2_bodyonly"; and echo 1; or echo 0)
t "reload: does NOT source the categorizer" 0 (string match -q '*tmux-categorize*' -- "$__t2_bodyonly"; and echo 1; or echo 0)
t "reload: gates the notice on the idle predicate" 1 (string match -q '*__tmux_lives_shell_is_idle*' -- "$__t2_body"; and echo 1; or echo 0)
```

Those are structural. The behavioural half is a pty harness and is the real test:

```fish
# Fires in an ALREADY-RUNNING shell, re-sources for real, and does it ONCE even
# though a single `set -U` was measured firing the handler twice.
```

Build it as: an isolated `XDG_CONFIG_HOME`; a `conf.d` copy of the plugin; an interactive fish held open by `timeout`; a marker function whose definition is changed on disk mid-run; then `set -U tmux_lives_reload_token …` from a second fish. Assert (a) the changed definition is live in the running shell afterwards, and (b) the notice appears exactly **once**.

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'reload:|FAIL' | head -12`
Expected: every `reload:` line FAILS.

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_shell_reload --on-variable tmux_lives_reload_token --description 'Re-source this plugins conf.d files in place when an update announces itself. Fires in shells that are ALREADY RUNNING, including ones whose foreground is Claude — measured: the event is delivered even while a foreground child holds the terminal, so no send-keys is needed and nothing is ever typed into a pane. Only the two conf.d files are re-sourced; the categorizer under functions/ is deliberately excluded because it is only ever invoked as a script, never autoloaded (see the design doc). NB that exclusion is asserted by a test that greps this function, so do NOT name that file literally here. Prints ONLY when the shell is idle: the handler shares its stdout with whatever is drawing on the tty.'
    status is-interactive; or return
    test "$tmux_lives_autoreload" = 0; and return
    # One `set -U` was measured firing this handler TWICE, so both the re-source
    # and the notice must be idempotent per token value.
    test "$__tmux_lives_reloaded_at" = "$tmux_lives_reload_token"; and return
    set -g __tmux_lives_reloaded_at $tmux_lives_reload_token
    set -l d $__fish_config_dir/conf.d
    for f in $d/tmux.fish $d/tmux-lives-install.fish
        test -r $f; and source $f
    end
    __tmux_lives_shell_is_idle; or return
    echo '↻ tmux-lives reloaded'
    commandline -f repaint
end
```

- [ ] **Step 4: Verify the self-redefinition is safe**

Re-sourcing `tmux-lives-install.fish` **redefines `__tmux_lives_shell_reload` while it is executing.** Confirm fish completes the running invocation with the old body rather than erroring or re-entering. If it does not, the fix is to source into a subshell or defer, and that is a real finding to report — do not paper over it.

- [ ] **Step 5: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(update): re-source the plugin in place on a reload token

A universal-variable handler reaches shells that are already running --
including ones with Claude in the foreground -- so no send-keys is
needed and nothing is typed into any pane."
```

---

### Task 3: The trigger in `_tmux_lives_post_update`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — inside `_tmux_lives_post_update`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_digest` (existing), the `tmux_lives_update_files` test seam (existing).
- Produces: the universal `tmux_lives_reload_token`, and a local `autoreloaded` (`1`/`0`) passed as the new 4th argument to `__tmux_lives_update_note` in Task 4.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 3: the update trigger ---------------------------------------------
# Line-number helper. The obvious idiom for this — measuring the length of a
# lazy `(?s)^.*?needle` match — is BROKEN: `string match -r` returns more than
# one element there, so `string length` yields a LIST and the numeric compare
# dies with "Integer 5 in '5 30' followed by non-digit". Verified before this
# plan shipped; do not "simplify" back to it.
function __t3_lineno --argument-names hay needle
    set -l ls (string split \n -- $hay)
    for i in (seq (count $ls))
        if string match -q "*$needle*" -- $ls[$i]
            echo $i
            return
        end
    end
    echo 0
end

set -g __t3_body (functions _tmux_lives_post_update | string collect)
t "trigger: sets the reload token" 1 (string match -q '*set -U tmux_lives_reload_token*' -- "$__t3_body"; and echo 1; or echo 0)
t "trigger: only sets when the digest changed" 1 (string match -q '*__tmux_lives_digest*' -- "$__t3_body"; and echo 1; or echo 0)

# PLACEMENT IS LOAD-BEARING: below the _tmux_lives_updating early return, plain
# `fisher update` would refresh other shells while `tmux-lives update` silently
# would not. Both line numbers must be FOUND (0 means "not present", which would
# make the ordering compare true for the wrong reason).
set -g __t3_tok (__t3_lineno "$__t3_body" 'set -U tmux_lives_reload_token')
set -g __t3_ret (__t3_lineno "$__t3_body" 'set -q _tmux_lives_updating')
t "trigger: the token line was found" 1 (test "$__t3_tok" -gt 0; and echo 1; or echo 0)
t "trigger: the early-return line was found" 1 (test "$__t3_ret" -gt 0; and echo 1; or echo 0)
t "trigger: fires ABOVE the _tmux_lives_updating early return" 1 (test "$__t3_tok" -gt 0 -a "$__t3_ret" -gt 0 -a "$__t3_tok" -lt "$__t3_ret"; and echo 1; or echo 0)
```

Verified before this plan shipped: with the token line first the ordering assertion holds; with the two lines swapped it fails; and a needle that is absent yields `0`, which the guards above catch.

Plus a behavioural pair, run under the suite's isolated universal store: with the token already equal to the current digest, invoking the trigger must **not** change it; with the token absent or different, it must.

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'trigger:|FAIL' | head`
Expected: all `trigger:` lines FAIL. Note the two "extraction is non-empty" guards exist because a `string match` that finds nothing yields an empty string whose `string length` is 0 — without them, the ordering assertion `0 -lt 0` would be false for the *wrong* reason and read as a real failure.

- [ ] **Step 3: Implement**

Insert into `_tmux_lives_post_update` immediately after `__tmux_lives_write_funcs` and **before** `set -q _tmux_lives_updating; and return`:

```fish
    # Announce the update to every other running shell. MUST sit above the
    # `_tmux_lives_updating` early return: below it, plain `fisher update` would
    # refresh other shells while `tmux-lives update` silently would not, and the
    # divergence would be invisible until someone noticed the two paths disagree.
    # The event fires even when the value is unchanged (measured), so the digest
    # comparison here is the only thing stopping a no-op update — and fisher
    # always re-fetches, so no-op updates are the common case — from refreshing
    # every shell and printing in every idle one.
    set -l files $tmux_lives_update_files
    test -n "$files"; or set files \
        $__fish_config_dir/conf.d/tmux.fish \
        $__fish_config_dir/conf.d/tmux-lives-install.fish \
        $__fish_config_dir/functions/tmux-categorize.fish
    set -l dg (__tmux_lives_digest $files)
    set -l had ''
    set -q tmux_lives_reload_token; and set had $tmux_lives_reload_token
    set -l autoreloaded 0
    if test "$dg" != "$had"
        # A previously-set token means the other shells carry the handler. An
        # ABSENT one means this is the first update shipping the feature, so they
        # do not — and the old `exec fish` advice is still correct for them.
        test -n "$had"; and set autoreloaded 1
        set -U tmux_lives_reload_token $dg
    end
```

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(update): announce updates to other shells

Sets the reload token above the _tmux_lives_updating early return, so
both `fisher update` and `tmux-lives update` reach other shells. Gated
on the digest changing, because the event fires even on an unchanged
value and fisher re-fetches on every update."
```

---

### Task 4: The note stops lying

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_update_note` and its call site in `_tmux_lives_post_update`
- Test: `tests/test-tmux-install.fish` (the 7 existing `note:` assertions are at roughly `:1470-1476`)

**Interfaces:**
- Consumes: `autoreloaded` from Task 3.
- Produces: `__tmux_lives_update_note refreshed removed sessions autoreloaded` — a 4th **trailing optional** argument. Absent or empty means "no auto-reload happened", which is what every existing 3-argument caller and all 7 existing assertions rely on.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 4: the note's auto-reload branch -----------------------------------
# NB the match string is "refreshed automatically", NOT "refreshed". Today's very
# first note line already reads "tmux config refreshed + reloaded", so a bare
# `*refreshed*` PASSES against the unchanged function and proves nothing —
# verified before this plan shipped.
t "note: says other shells refreshed themselves when autoreloaded" 1 (string match -q '*refreshed automatically*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" 1 | string collect); and echo 1; or echo 0)
t "note: does NOT tell you to exec fish in each when autoreloaded" 0 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" 1 | string collect); and echo 1; or echo 0)
# The bootstrap branch: absent 4th arg keeps today's advice, which is correct on
# the first update because those shells have no handler yet.
t "note: keeps the exec fish advice when NOT autoreloaded" 1 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "" "Alpha Beta" | string collect); and echo 1; or echo 0)
# A REMOVED function still needs a real restart everywhere -- re-sourcing cannot
# unset one in the other shells either, so auto-reload does not rescue this case.
t "note: still advises exec fish elsewhere when a function was removed, even autoreloaded" 1 (string match -q '*in each*' -- (__tmux_lives_update_note 1 "__gone" "Alpha" 1 | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'note:|FAIL' | head -12`
Expected: the three new `autoreloaded` assertions FAIL; **all 7 pre-existing `note:` assertions still PASS** — they pass 3 arguments, so the new one defaults empty. If any pre-existing one fails, the default is wrong.

- [ ] **Step 3: Implement**

Change the signature to `--argument-names refreshed removed sessions autoreloaded`, and replace the sessions block:

```fish
    if test -n "$ss[1]"
        set -l uniq (printf '%s\n' $ss | sort -u | string join ', ')
        if test "$autoreloaded" = 1; and test -z "$rm[1]"
            echo "  Other shells refreshed automatically: $uniq"
        else if test "$autoreloaded" = 1
            # They re-sourced, but sourcing cannot unset a function there either.
            echo "  Other shells refreshed automatically: $uniq — but run `exec fish` in each, since the removal above cannot be sourced away."
        else if test -n "$rm[1]"
            echo "  Other shells also run the old version: $uniq — run `exec fish` in each."
        else
            echo "  This shell is current. Other shells still run the old version: $uniq — run `exec fish` in each."
        end
    end
```

Then pass the 4th argument at the call site: `__tmux_lives_update_note $refreshed "$removed" "$(__tmux_lives_stale_sessions)" $autoreloaded`.

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes, all 11 `note:` assertions green.

- [ ] **Step 5: Update the README**

The README describes the post-update advice. Find and correct any statement that other shells must be restarted manually, and state the two cases that still need `exec fish`: a removed function, and the first update after this feature ships.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish README.md
git commit -m "feat(update): the note reports auto-reload instead of advising exec fish

Keeps the old advice on the first update carrying the feature, when the
already-open shells have no handler yet -- distinguished by whether the
token existed before. A removed function still needs a real restart
everywhere, since sourcing cannot unset one."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 `__tmux_lives_shell_is_idle`, fail-safe with no tty | 1 |
| §2 handler: interactive-only, opt-out, re-source two files, idle-gated notice | 2 |
| §2 idempotency (measured double-fire) | 2 Step 3 |
| §2 why the categorizer is excluded | 2 Step 1 (asserted absent) |
| §3 trigger above the early return | 3 |
| §3 digest gating | 3 |
| §4 note bootstrap vs steady state | 4 |
| §4 removals still need `exec fish` | 4 Step 1, fourth assertion |
| Opt-out `tmux_lives_autoreload` | 2 |
| Testing: pty for the predicate | 1 Step 4 |

**Placeholder scan:** Tasks 1 Step 4, 2 Step 1 and 3 Step 1 describe pty/behavioural harnesses by shape rather than giving complete code. That is deliberate — the working shape is given, and a verbatim harness would encourage copying over verifying — but it is the weakest part of this plan and the implementer should expect to iterate there.

**Type consistency:** `__tmux_lives_shell_is_idle` (no args, exit status) and `__tmux_lives_shell_reload` are named identically in Tasks 1, 2 and their assertions. The note's 4th argument is `autoreloaded` in Tasks 3 and 4 and in the call site.

**Known risk, stated rather than hidden:** Task 2's handler re-sources the file that defines it, while it is running. Step 4 exists to verify fish tolerates that. If it does not, Task 2 needs redesign and Tasks 3–4 are unaffected.

**Four defects found in this plan's own pre-flight and fixed before dispatch.** Recorded because the shapes repeat, and because an implementer should read the remaining assertions knowing the author's hit rate:

1. **The ordering assertion was broken.** Measuring a lazy `(?s)^.*?needle` match with `string length` returns a LIST, so the numeric compare died with `Integer 5 in '5 30' followed by non-digit`. Replaced with an explicit line-number helper, verified to hold on correct order, fail on inverted order, and return a guardable `0` when the needle is absent.
2. **A note assertion was vacuous.** It matched `*refreshed*`, and today's first note line already reads "tmux config refreshed + reloaded" — so it passed against the unchanged function. Tightened to `*refreshed automatically*`, verified absent today.
3. **A grep assertion was defeated by its own docstring.** `functions <name>` prints the description too, and the handler's description named the categorizer's file — so "does NOT source the categorizer" would have failed against correct code. The description now avoids the literal and the assertion strips the description line.
4. **`$plugindir` is defined at `tests/test-tmux-install.fish:18`**, confirmed before being referenced — the same file carries a comment at `:1055` about a previous vacuous grep caused by referencing an undefined path variable.
