# ShellFish Bar Color + Non-ShellFish Baseline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a `client-attached` tmux hook, color the ShellFish client's toolbar with this server's configured color, and re-apply a user-owned `~/.tmux-lives.conf` baseline for non-ShellFish clients.

**Architecture:** The managed fragment installs one always-present `set-hook -g client-attached` that calls a new categorizer subcommand `on-attach <client_pid> <client_tty> [color]`. That subcommand detects ShellFish by reading the attaching client process's environment (`/proc/<pid>/environ` on Linux, `ps eww` on macOS); ShellFish → emit the `setbarcolor` OSC straight to the client tty; non-ShellFish → `tmux source-file ~/.tmux-lives.conf` when present. Two config surfaces: `tmux-lives setup color <css>` (universal var, baked into the fragment) and `tmux-lives setup conf [edit|add]` (manages the user-owned baseline file).

**Tech Stack:** fish shell, tmux, `base64`, `/proc` (Linux) / `ps eww` (macOS). Tests are fish scripts under `tests/`.

## Global Constraints

- fish 4.x; tmux 3.3a or newer; `client-attached` hook (tmux ≥ 2.4).
- **Zero new files** in `conf.d/` or `functions/` — all code joins `conf.d/tmux-lives-install.fish` and `functions/tmux-categorize.fish`. (`~/.tmux-lives.conf` is a runtime artifact in `$HOME`, not a repo file.)
- Detection is a **substring** match for `LC_TERMINAL=ShellFish` (capital F) over the client process environment — works for both Linux per-line `/proc` output and the macOS single-line `ps eww` output.
- The bar-color escape written directly to `#{client_tty}` uses the **non-passthrough** form `ESC ] 6 ; settoolbar://?ver=2&color=<base64(color)> BEL` (the passthrough wrapper is only for pane→client forwarding).
- The `client-attached` hook is installed **unconditionally** (even with no color) because it also drives the non-ShellFish baseline branch.
- ShellFish branch must **not** force `mouse on` — color only.
- `~/.tmux-lives.conf` is seeded once with a commented template and **never overwritten** by setup.
- The framed `tmux-lives setup -h` page must stay ≤ 80 columns.
- Test seams (mirroring existing `tcz_force_ps`/`tmux_categorize_test`): `tmux_lives_fake_environ` (inject a fake client environ), `tmux_lives_baseline_conf` (override the baseline path).
- Deployment is the user's `fisher update`; a Claude session never deploys.

Run the full suite at any time with:
```bash
fish -c 'for t in tests/test-*.fish; echo "== $t =="; fish $t | tail -1; end'
```

---

### Task 1: ShellFish detection helpers (categorizer)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add after `__tcz_pid_cmdline`, ~line 76)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces:
  - `__tcz_pid_environ <pid>` → echoes the process environment, one `KEY=VALUE` per line (Linux) or a single line (macOS `ps eww`). Honors seam `tmux_lives_fake_environ` (a list → printed one per line) and `tcz_force_ps` (force the `ps` branch).
  - `__tcz_client_is_shellfish <pid>` → returns 0 iff the environment contains `LC_TERMINAL=ShellFish`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, immediately after the `__tcz_pane_is_claude` block (after line 59, before the `# Pure: name helpers` section):

```fish
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
# real /proc: our own shell's environ has no LC_TERMINAL=ShellFish under the test runner
t "is_shellfish: real self pid -> no" "1" (__tcz_client_is_shellfish $fish_pid; echo $status)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-categorize.fish`
Expected: lines like `FAIL - is_shellfish: exact env -> yes` (function `__tcz_client_is_shellfish` not defined yet → nonzero status mismatch), and `SOME FAILED` at the end.

- [ ] **Step 3: Implement the helpers**

In `functions/tmux-categorize.fish`, add directly after `__tcz_pid_cmdline` (after its closing `end`, ~line 76):

```fish
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the five new `ok   - is_shellfish: …` lines and `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(categorize): ShellFish client detection via process environ"
```

---

### Task 2: Bar-color emission helper (categorizer)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add after `__tcz_client_is_shellfish`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_emit_barcolor <tty> <color>` → writes `ESC ] 6 ; settoolbar://?ver=2&color=<base64(color)> BEL` to `<tty>`; no-op when `<color>` is empty.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-categorize.fish` after the detection block from Task 1:

```fish
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: `FAIL - barcolor: exact escape bytes …` (function not defined → empty output), `SOME FAILED`.

- [ ] **Step 3: Implement the helper**

In `functions/tmux-categorize.fish`, add after `__tcz_client_is_shellfish`:

```fish
function __tcz_emit_barcolor --argument-names tty color --description 'write the ShellFish setbarcolor OSC for <color> to <tty> (non-passthrough; client-tty level)'
    test -n "$color"; or return 0
    printf '\033]6;settoolbar://?ver=2&color=%s\a' (printf '%s' "$color" | base64) > $tty
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fish tests/test-tmux-categorize.fish`
Expected: `ok   - barcolor: exact escape bytes`, `ok   - barcolor: empty color writes nothing`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(categorize): emit ShellFish setbarcolor OSC to a tty"
```

---

### Task 3: `on-attach` subcommand + dispatch (categorizer)

**Files:**
- Modify: `functions/tmux-categorize.fish` (add `__tcz_on_attach` before `__tcz_main`; add a `case on-attach` to `__tcz_main`; extend the usage string)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_client_is_shellfish` (Task 1), `__tcz_emit_barcolor` (Task 2).
- Produces: `__tcz_on_attach <client_pid> <client_tty> [color]` → ShellFish: emit color to tty; else: `tmux source-file <baseline>` when it exists. Baseline path = `$tmux_lives_baseline_conf` if set (seam), else `$HOME/.tmux-lives.conf`. Reachable as `fish --no-config <cat> on-attach …`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish` after the emission block from Task 2 (the `$sock`/`$shimdir` integration harness from the top of the file is in scope here):

```fish
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
set -e tmux_lives_fake_environ
set -e tmux_lives_baseline_conf
rm -f $oaf $oabase
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-categorize.fish`
Expected: `FAIL - on-attach: …` (function not defined), `SOME FAILED`.

- [ ] **Step 3: Implement the subcommand + dispatch**

In `functions/tmux-categorize.fish`, add `__tcz_on_attach` immediately before `function __tcz_main` (~line 788):

```fish
function __tcz_on_attach --argument-names pid tty color --description 'on-attach <client_pid> <client_tty> [color]: ShellFish -> set bar color; else re-apply the non-ShellFish baseline'
    if __tcz_client_is_shellfish $pid
        __tcz_emit_barcolor $tty $color
    else
        set -l baseline (set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf")
        test -e $baseline; and tmux source-file $baseline 2>/dev/null
    end
    return 0
end
```

In `__tcz_main`, add a case after `case commandeer` / `__tcz_commandeer $argv[2..]` (around line 810):

```fish
        case on-attach
            __tcz_on_attach $argv[2..]
```

Update the usage string (the `case '*'` echo, ~line 816) to include `on-attach`:

```fish
            echo "usage: tmux-categorize.fish categorize|tick|overview|menu|open-switcher|popup|claim|ghosts|switch|commandeer|on-attach|slug|new-general" >&2
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the three new `ok   - on-attach: …` lines and `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(categorize): on-attach subcommand — color ShellFish, baseline others"
```

---

### Task 4: Render the `client-attached` hook in the fragment

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (add a 4th `color` arg + the hook); `__tmux_lives_write_fragment` (pass the color)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: the categorizer `on-attach` subcommand (Task 3) by name (the fragment is plain text; no runtime dependency at render time).
- Produces: `__tmux_lives_render_fragment <cat> <pkey> <skey> [color]` now also emits `set-hook -g client-attached { run-shell "fish --no-config <cat> on-attach '#{client_pid}' '#{client_tty}' '<color>'" }`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` after the existing fragment assertions (after line 28, before the `automatic-rename-format` block):

```fish
set -l fragbc (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" | string collect)
t "fragment has client-attached hook" 1 (string match -q '*client-attached*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook calls on-attach"     1 (string match -q '*on-attach*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook passes client_pid"   1 (string match -q '*on-attach*#{client_pid}*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment hook passes client_tty"   1 (string match -q '*#{client_tty}*' -- "$fragbc"; and echo 1; or echo 0)
t "fragment bakes the color"          1 (string match -q '*#1f6feb*' -- "$fragbc"; and echo 1; or echo 0)
set -l fragnc (__tmux_lives_render_fragment /X/cat.fish S M-s '' | string collect)
t "hook present without a color"      1 (string match -q '*client-attached*on-attach*' -- "$fragnc"; and echo 1; or echo 0)
t "3-arg call still renders the hook" 1 (string match -q '*client-attached*' -- (__tmux_lives_render_fragment /X/cat.fish S M-s | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: fragment has client-attached hook => got [0]` (and the others), no `client-attached` in the rendered fragment yet.

- [ ] **Step 3: Implement the hook + wire the color**

In `conf.d/tmux-lives-install.fish`, in `__tmux_lives_render_fragment`, read the color from a new 4th arg. Change the arg block at the top of the function:

```fish
    set -l cat $argv[1]
    set -l pkey $argv[2]   # prefix-table key ('' = no prefix bind)
    set -l skey $argv[3]   # no-prefix/direct key ('' = no direct bind)
    set -l color $argv[4]  # ShellFish bar color baked into the client-attached hook ('' = none)
```

Then, immediately after the commandeer hook block (after the `set -a f "}"` that closes `set-hook -g client-session-changed`, ~line 50), add:

```fish
    set -a f "set-hook -g client-attached {"
    set -a f "    run-shell \"fish --no-config $cat on-attach '#{client_pid}' '#{client_tty}' '$color'\""
    set -a f "}"
```

In `__tmux_lives_write_fragment`, pass the configured color as the 4th argument:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) (__tmux_lives_key tmux_lives_bar_color '') > $fragment
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the seven new `t` assertions pass; the run prints `ALL PASS (<n>)` with no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(install): render client-attached hook (bakes bar color)"
```

---

### Task 5: `setup color` command + dispatch + help + verify

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_color_cmd`; add `color` to `__tmux_lives_setup_dispatch` and to the hidden top-level `tmux-lives` case; add a help line to `__tmux_lives_setup_help_lines`; add a status line to `__tmux_lives_status_lines`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_write_fragment` (Task 4), `__tmux_lives_key`.
- Produces: `__tmux_lives_color_cmd [<css>]` — no arg prints the current color; an arg sets `tmux_lives_bar_color` (universal) and re-renders the fragment; `""` clears it.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` after the key-resolver tests (after line 53):

```fish
# setup color: stores the universal var + bakes into the re-rendered fragment
set -l cfrag /tmp/tli-colorfrag-$fish_pid.conf
function __tmux_lives_write_fragment --description 'test stub: render to a temp path'
    __tmux_lives_render_fragment /X/cat.fish S M-s (__tmux_lives_key tmux_lives_bar_color '') > /tmp/tli-colorfrag-$fish_pid.conf
end
set -e tmux_lives_bar_color
t "color: empty when unset" 1 (string match -q '*none*' -- (__tmux_lives_color_cmd); and echo 1; or echo 0)
__tmux_lives_color_cmd "#ff8800" >/dev/null
t "color: stored in universal var" "#ff8800" "$tmux_lives_bar_color"
t "color: baked into fragment" 1 (string match -q '*#ff8800*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
__tmux_lives_color_cmd "" >/dev/null
t "color: cleared to empty" "" "$tmux_lives_bar_color"
functions -e __tmux_lives_write_fragment
set -e tmux_lives_bar_color
rm -f $cfrag
# help + verify mention color
t "setup help lists color" 1 (string match -q '*color*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "verify reports bar color" 1 (string match -q '*bar color*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: color: empty when unset …` (function `__tmux_lives_color_cmd` undefined), plus the help/verify failures.

- [ ] **Step 3: Implement the command + wiring**

In `conf.d/tmux-lives-install.fish`, add `__tmux_lives_color_cmd` near `__tmux_lives_keys_cmd` (after it):

```fish
function __tmux_lives_color_cmd --description 'tmux-lives setup color [<css-color>]: per-server ShellFish toolbar color'
    if test (count $argv) -eq 0
        set -l c (__tmux_lives_key tmux_lives_bar_color '')
        test -n "$c"; and echo "bar color: $c"; or echo "bar color: (none)"
        return 0
    end
    set -U tmux_lives_bar_color $argv[1]
    __tmux_lives_write_fragment
    if test -n "$argv[1]"
        echo "tmux-lives: bar color set to $argv[1] (applied to ShellFish clients on attach)"
    else
        echo "tmux-lives: bar color cleared"
    end
end
```

In `__tmux_lives_setup_dispatch`, add after `case keys` / `__tmux_lives_keys_cmd $argv[2..]`:

```fish
        case color
            __tmux_lives_color_cmd $argv[2..]
```

In the `tmux-lives` function's hidden top-level shortcut case, add `color`:

```fish
        case install i verify v teardown keys auto color
            # hidden shortcut: setup subcommands also work at top level (kept out of help)
            __tmux_lives_setup_dispatch $argv
```

In `__tmux_lives_setup_help_lines`, add this line to the `printf '%s\n' …` list, after the `auto …` line (keep the first field padded to column 28, total ≤ 76 chars):

```fish
        'color [<css-color>]         set the per-server ShellFish toolbar color'
```

In `__tmux_lives_status_lines`, add before the final `printf '%s\n' $r` (after the switcher-keys line):

```fish
    set -l bc (__tmux_lives_key tmux_lives_bar_color ''); test -n "$bc"; or set bc '(none)'
    set -a r "OK bar color: $bc"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the new color/help/verify assertions pass; `ALL PASS (<n>)`, no `FAIL:` lines.

- [ ] **Step 5: Verify the framed help still fits 80 columns**

Run:
```bash
fish -c 'source conf.d/tmux-lives-install.fish; __tmux_lives_setup_help | awk "{ print length, \$0 }" | sort -rn | head -1'
```
Expected: the widest line's length is ≤ 80.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): 'setup color' — per-server ShellFish toolbar color"
```

---

### Task 6: `~/.tmux-lives.conf` baseline + `setup conf` command

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_baseline_path`, `__tmux_lives_seed_baseline`, `__tmux_lives_conf_cmd`; add `conf` to `__tmux_lives_setup_dispatch` and the hidden top-level case; seed the file in `__tmux_lives_setup`; add a help line and a verify line
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces:
  - `__tmux_lives_baseline_path` → `$tmux_lives_baseline_conf` (seam) or `$HOME/.tmux-lives.conf`.
  - `__tmux_lives_seed_baseline <path>` → writes the commented template iff the file is absent (idempotent).
  - `__tmux_lives_conf_cmd [edit|add <cmd…>]` → no arg prints path+contents; `add` seeds+appends+sources; `edit` seeds+opens `$EDITOR`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` after the color tests from Task 5:

```fish
# baseline file: seed-once + conf add
set -g tmux_lives_baseline_conf /tmp/tli-baseline-$fish_pid.conf
rm -f $tmux_lives_baseline_conf
t "baseline: path honors seam" "$tmux_lives_baseline_conf" (__tmux_lives_baseline_path)
__tmux_lives_seed_baseline (__tmux_lives_baseline_path)
t "baseline: seeded file exists" 1 (test -e $tmux_lives_baseline_conf; and echo 1; or echo 0)
t "baseline: template is commented" 1 (string match -q '*# set -g mouse off*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
printf '# hand edit\n' >> $tmux_lives_baseline_conf
__tmux_lives_seed_baseline (__tmux_lives_baseline_path)
t "baseline: seed never overwrites" 1 (string match -q '*hand edit*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
__tmux_lives_conf_cmd add 'set -g mouse off' >/dev/null
t "baseline: conf add appends line" 1 (grep -qF 'set -g mouse off' $tmux_lives_baseline_conf; and echo 1; or echo 0)
t "baseline: conf (no arg) shows path" 1 (string match -q "*$tmux_lives_baseline_conf*" -- (__tmux_lives_conf_cmd | string collect); and echo 1; or echo 0)
rm -f $tmux_lives_baseline_conf
set -e tmux_lives_baseline_conf
# help + verify mention conf/baseline
t "setup help lists conf" 1 (string match -q '*conf*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
t "verify reports baseline" 1 (string match -q '*baseline*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: baseline: path honors seam …` (functions undefined), plus help/verify failures.

- [ ] **Step 3: Implement the helpers + command + wiring**

In `conf.d/tmux-lives-install.fish`, add near `__tmux_lives_color_cmd`:

```fish
function __tmux_lives_baseline_path --description 'path to the user-owned non-ShellFish baseline file (seam: tmux_lives_baseline_conf)'
    set -q tmux_lives_baseline_conf; and echo $tmux_lives_baseline_conf; or echo "$HOME/.tmux-lives.conf"
end

function __tmux_lives_seed_baseline --argument-names f --description 'create the baseline file with a commented template iff absent (never overwrites)'
    test -e $f; and return 0
    printf '%s\n' \
        '# tmux-lives baseline — re-applied whenever a NON-ShellFish client attaches.' \
        "# Put tmux settings here that ShellFish's integration shouldn't get to keep." \
        '# Example:' \
        '# set -g mouse off' > $f
end

function __tmux_lives_conf_cmd --description 'tmux-lives setup conf [edit|add <tmux-command>]: manage ~/.tmux-lives.conf'
    set -l f (__tmux_lives_baseline_path)
    switch "$argv[1]"
        case ''
            echo "baseline file: $f"
            if test -e $f
                cat $f
            else
                echo "(does not exist yet — run 'tmux-lives setup conf edit' to create it)"
            end
        case edit
            __tmux_lives_seed_baseline $f
            set -l ed $EDITOR
            test -n "$ed"; or set ed vi
            $ed $f
        case add
            __tmux_lives_seed_baseline $f
            printf '%s\n' (string join ' ' $argv[2..]) >> $f
            tmux source-file $f 2>/dev/null
            echo "tmux-lives: added to $f"
        case '*'
            echo "tmux-lives setup conf: unknown option '$argv[1]'" >&2
            echo "usage: tmux-lives setup conf [edit|add <tmux-command>]" >&2
            return 1
    end
end
```

In `__tmux_lives_setup_dispatch`, add after the `case color` block:

```fish
        case conf
            __tmux_lives_conf_cmd $argv[2..]
```

In the hidden top-level shortcut case, add `conf`:

```fish
        case install i verify v teardown keys auto color conf
            __tmux_lives_setup_dispatch $argv
```

In `__tmux_lives_setup` (the installer), seed the baseline once — add after the `echo "tmux-lives setup: ensured source-file line in ~/.tmux.conf"` line:

```fish
    __tmux_lives_seed_baseline (__tmux_lives_baseline_path)
    echo "tmux-lives setup: baseline file at "(__tmux_lives_baseline_path)" (edit: tmux-lives setup conf edit)"
```

In `__tmux_lives_setup_help_lines`, add after the `color …` line (first field padded to column 28, ≤ 76 chars):

```fish
        'conf [edit|add <cmd>]       edit the non-ShellFish baseline (~/.tmux-lives.conf)'
```

In `__tmux_lives_status_lines`, add after the bar-color line:

```fish
    set -l bf (__tmux_lives_baseline_path)
    test -e $bf; and set -a r "OK baseline $bf present"; or set -a r "OK baseline $bf (none yet)"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the new baseline assertions pass; `ALL PASS (<n>)`, no `FAIL:` lines.

- [ ] **Step 5: Verify the framed help still fits 80 columns**

Run:
```bash
fish -c 'source conf.d/tmux-lives-install.fish; __tmux_lives_setup_help | awk "{ print length, \$0 }" | sort -rn | head -1'
```
Expected: the widest line's length is ≤ 80.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): non-ShellFish baseline ~/.tmux-lives.conf + 'setup conf'"
```

---

### Task 7: Documentation (README + CLAUDE.md)

**Files:**
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Run the full suite (regression gate before docs)**

Run:
```bash
fish -c 'set -l bad 0; for t in tests/test-*.fish; fish $t >/dev/null 2>&1; or set bad 1; fish $t | string match -q "*FAIL*"; and set bad 1; end; test $bad -eq 0; and echo ALLGREEN; or echo SOMEFAIL'
```
Expected: `ALLGREEN`.

- [ ] **Step 2: Update `README.md`**

Add a "ShellFish tab color & non-ShellFish baseline" subsection documenting:
- `tmux-lives setup color <css>` — set this server's ShellFish toolbar color (e.g. `tmux-lives setup color "#1f6feb"`); `tmux-lives setup color ""` clears it.
- `tmux-lives setup conf [edit|add <cmd>]` — manage `~/.tmux-lives.conf`, tmux commands re-applied whenever a non-ShellFish client attaches (e.g. `set -g mouse off`).
- One sentence on behavior: a `client-attached` hook colors ShellFish tabs and re-applies the baseline for other clients; the color reaches only the ShellFish client.

- [ ] **Step 3: Update `CLAUDE.md`**

In the project status paragraph, document: the `client-attached` hook in the managed fragment calling the categorizer `on-attach <client_pid> <client_tty> <color>`; detection via the client process environ (`/proc`→`ps`); the two config surfaces (`setup color` universal var baked into the fragment, `setup conf` managing the user-owned, never-overwritten `~/.tmux-lives.conf`); and the seams `tmux_lives_fake_environ` / `tmux_lives_baseline_conf`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: ShellFish bar color + non-ShellFish baseline (setup color/conf)"
```

---

## Self-Review

**Spec coverage:**
- Per-server color on ShellFish attach → Tasks 2, 3, 4, 5. ✓
- Color reaches only the ShellFish client (write to `#{client_tty}`) → Task 2 (non-passthrough escape) + Task 4 (hook passes `#{client_tty}`). ✓
- Non-ShellFish baseline re-applied → Tasks 3 (source-file branch) + 6 (file + command). ✓
- User-owned, never-overwritten baseline → Task 6 (seed-once, idempotent test). ✓
- Detection via client_pid environ, cross-platform substring → Task 1. ✓
- Config surfaces `setup color` / `setup conf`, hidden top-level shortcuts, help, verify → Tasks 5, 6. ✓
- Hook always installed (drives baseline even with no color) → Task 4 (`hook present without a color` test). ✓
- ShellFish branch does not force mouse → Tasks 2/3 emit color only; no `mouse` write anywhere. ✓
- Zero new files → all edits land in the two existing source files. ✓
- 80-col help → Tasks 5/6 Step 5 checks. ✓
- Docs → Task 7. ✓

**Placeholder scan:** every code step contains complete fish; no TBD/TODO. ✓

**Type/name consistency:** `__tcz_pid_environ`, `__tcz_client_is_shellfish`, `__tcz_emit_barcolor`, `__tcz_on_attach`, `on-attach` subcommand, `__tmux_lives_color_cmd`, `__tmux_lives_baseline_path`, `__tmux_lives_seed_baseline`, `__tmux_lives_conf_cmd`, seams `tmux_lives_fake_environ` / `tmux_lives_baseline_conf` / `tmux_lives_bar_color` — used identically across tasks and tests. ✓

**Live-verification items (post-merge, user-run; not blockers for the tasks):** the direct `#{client_tty}` OSC write on a real ShellFish attach; the macOS `ps eww` environ read; the end-to-end mouse-baseline restore on a plain-terminal attach.
