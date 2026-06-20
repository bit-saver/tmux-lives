# tmux-lives Install Guidance + Help Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux-lives self-documenting — a `tmux-lives` help command listing every command, plus fisher post-install/update messages telling the user the next step.

**Architecture:** All additions go in the existing `conf.d/tmux-lives-install.fish`. A `tmux-lives` function prints a grouped command list; two `--on-event` handlers print guidance when fisher (re)installs the plugin. Fisher emits `<conf.d-filename>_install`/`_update`, so the handlers bind to `tmux-lives-install_install` / `tmux-lives-install_update`.

**Tech Stack:** fish 3.x+, fisher event handlers, no new dependency.

## Global Constraints

- **Zero net-new files in `conf.d/` or `functions/`** — the help command, the help-hint helper, and both event handlers all go in the existing `conf.d/tmux-lives-install.fish`; tests in the existing `tests/test-tmux-install.fish`. Underscore-prefix internal helpers; `tmux-lives` is the one new user-facing command (verified collision-free).
- **No behavior change to existing commands** — `tmux-setup`/`teardown`/`status`, `ts`, `tmuxauto`, `tmtake`, `fixssh` untouched. All eight suites stay green.
- **Pure fish.** No new dependency.
- **Empirically established fish facts (verified this session):** (1) a dashed `--on-event tmux-lives-install_install` DOES fire; (2) an event handler's stdout is NOT capturable via `(emit …)` — so tests call the handler functions directly for content; (3) `functions --handlers` lists `tmux-lives-install_install _tmux_lives_post_install`, which is how tests assert the dashed-event wiring.
- **Commits** — `feat:`/`docs:` prefix; end every message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; repo is direct-to-`main`; push after each commit.
- **Run all suites:** `for t in tests/test-*.fish; fish $t; end`.

---

### Task 1: `tmux-lives` help command + help-hint helper

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (append the two functions at end of file)
- Test: `tests/test-tmux-install.fish` (append assertions before the final summary line)

**Interfaces:**
- Produces:
  - `tmux-lives [help|-h|--help]` → prints the grouped command list to stdout, returns 0. Any other arg → prints `tmux-lives: unknown command '<arg>'` + the list to stderr, returns 1.
  - `__tmux_lives_help_hint` → echoes ``Run `tmux-lives` to see all commands.`` (consumed by Task 2).

- [ ] **Step 1: Write the failing test**

Append before the final `test $fail -eq 0; …` line in `tests/test-tmux-install.fish`:

```fish
set -l hlp (tmux-lives | string collect)
t "help lists tmux-setup"     1 (string match -q '*tmux-setup*' -- "$hlp"; and echo 1; or echo 0)
t "help lists ts"             1 (string match -q '*ts [name]*' -- "$hlp"; and echo 1; or echo 0)
t "help lists tmuxauto"       1 (string match -q '*tmuxauto*' -- "$hlp"; and echo 1; or echo 0)
t "help has Setup header"     1 (string match -q '*Setup / lifecycle:*' -- "$hlp"; and echo 1; or echo 0)
t "help has Daily header"     1 (string match -q '*Daily use:*' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"       1 (test "$hlp" = (tmux-lives -h | string collect); and echo 1; or echo 0)
t "help 'help' alias works"   1 (string match -q '*tmux-setup*' -- (tmux-lives help | string collect); and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown arg returns 1"     1 $status
t "help hint names tmux-lives" 1 (string match -q '*tmux-lives*' -- (__tmux_lives_help_hint); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL lines (`tmux-lives` / `__tmux_lives_help_hint` unknown command), suite ends `FAILED (N)`.

- [ ] **Step 3: Implement the help command + hint helper**

Append to the end of `conf.d/tmux-lives-install.fish`:

```fish
function __tmux_lives_help_hint --description 'Pointer to the tmux-lives help command'
    echo 'Run `tmux-lives` to see all commands.'
end

function tmux-lives --description 'tmux-lives: list commands and when to use each'
    set -l err 0
    switch "$argv[1]"
        case '' help -h --help
            # fall through: print help to stdout
        case '*'
            echo "tmux-lives: unknown command '$argv[1]'" >&2
            set err 1
    end
    set -l lines \
        'tmux-lives — categorized tmux sessions + persistence (fisher plugin)' \
        '' \
        'Setup / lifecycle:' \
        '  tmux-setup      wire ~/.tmux.conf + TPM/resurrect/continuum (run once on a new host;' \
        '                  macOS: no launchd units — persistence via continuum + first-access restore)' \
        '  tmux-status     check install health across every layer' \
        '  tmux-teardown   remove the wiring (TPM plugins left in place)' \
        '' \
        'Daily use:' \
        '  ts [name]       switch/create a categorized session — popup inside tmux;' \
        '                  with no name and no server, cold-starts your restored sessions' \
        '  tmuxauto …      on | off | status | toggle  — control auto-attach on login' \
        '  tmtake <name>   force-take a session (detach a stale/ghost client)' \
        '  fixssh          refresh SSH_AUTH_SOCK inside a reattached session'
    if test $err -eq 1
        printf '%s\n' $lines >&2
        return 1
    end
    printf '%s\n' $lines
end
```

- [ ] **Step 4: Run the install suite to verify it passes**

Run: `fish tests/test-tmux-install.fish`
Expected: all assertions `ok`, suite ends `ALL PASS (N)`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives help command — lists commands + when to use each

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 2: Post-install / update fisher-event messages

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (append the two event handlers at end of file)
- Test: `tests/test-tmux-install.fish` (append assertions before the final summary line)

**Interfaces:**
- Consumes: `__tmux_lives_help_hint` (Task 1).
- Produces:
  - `_tmux_lives_post_install` (`--on-event tmux-lives-install_install`) → prints fresh-install guidance (names `tmux-setup` + `tmux-status`).
  - `_tmux_lives_post_update` (`--on-event tmux-lives-install_update`) → prints the "open a new shell (exec fish)" note.

- [ ] **Step 1: Write the failing test**

Append before the final summary line in `tests/test-tmux-install.fish` (after Task 1's block):

```fish
# Content — call handlers directly (fish does NOT capture emit handler stdout).
set -l inst (_tmux_lives_post_install | string collect)
t "install msg names tmux-setup"  1 (string match -q '*tmux-setup*' -- "$inst"; and echo 1; or echo 0)
t "install msg names tmux-status" 1 (string match -q '*tmux-status*' -- "$inst"; and echo 1; or echo 0)
set -l upd (_tmux_lives_post_update | string collect)
t "update msg says exec fish"     1 (string match -q '*exec fish*' -- "$upd"; and echo 1; or echo 0)
# Wiring — the dashed --on-event names are actually registered.
functions --handlers | grep -qE 'tmux-lives-install_install[[:space:]]+_tmux_lives_post_install'
t "install handler wired to dashed event" 0 $status
functions --handlers | grep -qE 'tmux-lives-install_update[[:space:]]+_tmux_lives_post_update'
t "update handler wired to dashed event"  0 $status
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL lines (`_tmux_lives_post_install` unknown; grep finds no handler), suite ends `FAILED (N)`.

- [ ] **Step 3: Implement the event handlers**

Append to the end of `conf.d/tmux-lives-install.fish` (after the Task 1 functions):

```fish
function _tmux_lives_post_install --on-event tmux-lives-install_install --description 'Post-install guidance'
    printf '%s\n' \
        '✓ tmux-lives installed. To finish on a new host:' \
        '    tmux-setup     # wire tmux + plugins' \
        '    tmux-status    # verify' \
        '  then open a new tmux window. '(__tmux_lives_help_hint)
end

function _tmux_lives_post_update --on-event tmux-lives-install_update --description 'Post-update note'
    printf '%s\n' '✓ tmux-lives updated — open a new shell (exec fish) to load it. '(__tmux_lives_help_hint)
end
```

- [ ] **Step 4: Run the install suite to verify it passes**

Run: `fish tests/test-tmux-install.fish`
Expected: all assertions `ok`, suite ends `ALL PASS (N)`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: fisher post-install/update messages pointing at tmux-setup + tmux-lives

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 3: Docs + full-suite verification

**Files:**
- Modify: `README.md` (Install section), `CLAUDE.md` (command note), `docs/superpowers/specs/2026-06-20-tmux-lives-install-guidance-design.md` (Status → Implemented)

- [ ] **Step 1: Full-suite regression gate (first)**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: each of the eight suites prints its pass line; no `FAIL`/`FAILED`/`SOME FAILED`. If any fails, STOP and report BLOCKED with the output (do not edit docs).

- [ ] **Step 2: Update `README.md`**

In the `## Install` section, after the install/`tmux-setup` block, add:

```markdown
Run `tmux-lives` at any time to list the commands and when to use each. After `fisher install` you'll see a one-line reminder to run `tmux-setup`.
```

- [ ] **Step 3: Update `CLAUDE.md`**

Add a terse note near the keymap/command description (in the file's existing voice) recording the new discoverability surface, e.g.: ``**`tmux-lives`** (bare/`-h`) lists all commands; `fisher install`/`update` now print post-install/update guidance (handlers on `tmux-lives-install_install`/`_update`).``

- [ ] **Step 4: Flip the spec Status to Implemented**

In `docs/superpowers/specs/2026-06-20-tmux-lives-install-guidance-design.md`, change `- **Status:** Approved (design)` to `- **Status:** Implemented (Linux suites green)`.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-06-20-tmux-lives-install-guidance-design.md
git commit -m "docs: tmux-lives help command + install guidance (README, CLAUDE.md, spec status)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

- [ ] **Step 6: Re-publish the updated spec to the vault**

Re-run `vault-publish` on the spec and reflow the vault copy to single-line paragraphs (no hard wrap), so the vault reflects the Implemented status.

---

## Self-review notes

- **Spec coverage:** help command (exact text, aliases, unknown-arg) → Task 1; install/update messages + dashed-event wiring → Task 2; docs → Task 3; tests (content via direct call, wiring via `functions --handlers`, all-suites-green) → Tasks 1–3. The spec's "shared footer helper" is realized as `__tmux_lives_help_hint` (Task 1, consumed in Task 2).
- **Placeholders:** none — every code/test step is concrete fish.
- **Type/name consistency:** `tmux-lives`, `__tmux_lives_help_hint`, `_tmux_lives_post_install` (event `tmux-lives-install_install`), `_tmux_lives_post_update` (event `tmux-lives-install_update`) — used identically across tasks and tests.
