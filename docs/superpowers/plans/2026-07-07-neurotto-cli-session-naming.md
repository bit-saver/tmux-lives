# Neurotto CLI Session Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One canonical neurotto CLI session shown as "Neurotto CLI" (slug `cli`), via a tmux-lives `@tmux_lives_name` display override + boring-command deprioritization, consumed by a dedicated create-or-switch `x/cli.sh`.

**Architecture:** tmux-lives Tasks 1–3 add a reusable naming mechanism (self-contained, ships via `fisher update`); neurotto Task 4 opts in. Tasks 1–3 land on tmux-lives branch `feat/neurotto-cli-naming`; Task 4 lands on a neurotto branch and deploys separately.

**Tech Stack:** fish, tmux 3.3a (tmux-lives); bash, tmux (neurotto).

## Global Constraints

- **Test runner (tmux-lives):** `fish tests/test-<suite>.fish`; full gate `fish -c 'for t in tests/test-*.fish; fish $t; end'` — every suite `ALL PASS`.
- **Hard isolation:** no test touches the live default-socket tmux server. `tests/test-tmux-categorize.fish` already uses a **PATH `tmux` shim** that redirects to `tmux -L <private-socket>` — reuse it (create a session on the private socket, set options, run the function, assert, `kill-server`). Never call bare `tmux` against the user's server in a test.
- **tmux 3.3a quirk (verified in `__tcz_owned`):** `tmux show-option -t "=name" …` returns empty even on success — for reading a session option, target the **bare name** (`-t "$name"`), not `=name`. (For `display-message`/`rename`/`switch`, `=name` is correct.)
- **Exact strings:** display name `Neurotto CLI`; slug/command `cli`; boring list `tail less watch cat more bat`; option key `@tmux_lives_name`.
- fish `math` has no comparison operators — use `test`.
- Commit trailer (tmux-lives, verbatim): `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. (neurotto Task 4 uses the same trailer.)
- Do NOT deploy (tmux-lives via user's `fisher update`; neurotto via user's `deploy`); do NOT edit `~/.config` or `~/.tmux.conf`.
- Branches: tmux-lives `feat/neurotto-cli-naming` (spec committed there); neurotto `feat/cli-dedicated-session` (Task 4).

## File Structure

- tmux-lives `functions/tmux-categorize.fish`: `$__tcz_boring` list; `@tmux_lives_name` read + display override in `__tcz_snapshot`; no-rename guard in `__tcz_categorize`; `@tmux_lives_name` override in `__tcz_session_title`.
- tmux-lives `tests/test-tmux-categorize.fish`: tests for all three.
- tmux-lives `CLAUDE.md`: one documenting sentence.
- neurotto `x/cli.sh` + `x/kill.sh` / `x/toggle.sh` / `x/resize.sh` / `x/tmux.sh` / `src/cli/index.ts`: dedicated create-or-switch session slug `cli` + set `@tmux_lives_name`.

---

### Task 1: `@tmux_lives_name` display override (tmux-lives)

**Files:**
- Modify: `functions/tmux-categorize.fish` (`__tcz_snapshot`, `__tcz_categorize`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: a session with option `@tmux_lives_name "X"` → `__tcz_snapshot`'s `display` field is `X`; `__tcz_categorize` does not rename that session (its tmux name is left untouched).

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish`, using the suite's existing private-`-L`-socket / `tmux` PATH-shim harness (create sessions on the private socket, as the other categorize tests do), add a block:
  - create a session (e.g. `dev1`); `tmux set-option -t dev1 @tmux_lives_name "Neurotto CLI"`;
  - assert `__tcz_snapshot | string match -q '*\tNeurotto CLI'` for that session's line (the display, 5th tab field, is `Neurotto CLI`);
  - run `__tcz_categorize`; assert the session is STILL named `dev1` (`tmux has-session -t "=dev1"` succeeds and no `Neurotto CLI`-named session exists).
  Follow the exact stub/socket setup already used by the recolor/snapshot tests in this file.

- [ ] **Step 2: Run it and verify it fails.** `fish tests/test-tmux-categorize.fish` → FAIL (display is the dir/category name, and categorize renames it).

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

  (a) In `__tcz_snapshot`, extend the session format + capture the option. Change `sess_fmt` (currently `#{session_name}\t#{session_attached}\t#{session_last_attached}`) to add the option:
```fish
    set -l sess_fmt (printf '#{session_name}\t#{session_attached}\t#{session_last_attached}\t#{@tmux_lives_name}')
```
  In the session-attributes loop, capture it (mirror `snames`/`satt`/`slast`), using `-m 3` so a display value can't be split:
```fish
    set -l snames; set -l satt; set -l slast; set -l sdisp
    for line in (tmux list-sessions -F $sess_fmt 2>/dev/null)
        set -l f (string split -m 3 $TAB -- $line)
        test (count $f) -ge 3; or continue
        set -a snames $f[1]; set -a satt $f[2]; set -a slast $f[3]
        set -a sdisp (test (count $f) -ge 4; and echo $f[4]; or echo '')
    end
```
  In the per-session display loop, after the `switch $cats[$i]` block sets `display`, override with the explicit name when present (reuse the `$j` index already computed for att/last):
```fish
        test -n "$j"; and test -n "$sdisp[$j]"; and set display "$sdisp[$j]"
        printf '%s\t%s\t%s\t%s\t%s\n' $names[$i] $cats[$i] $att $last "$display"
```

  (b) In `__tcz_categorize`, right after `set -l cur $f[1]`, skip claimed sessions:
```fish
        # A session with an explicit @tmux_lives_name is claimed by an app; leave its slug alone.
        set -l claimed (tmux show-option -qv -t "$cur" @tmux_lives_name 2>/dev/null)
        test -n "$claimed"; and continue
```

- [ ] **Step 4: Run the test and verify it passes.** `fish tests/test-tmux-categorize.fish` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(name): @tmux_lives_name display override (snapshot display + no-rename)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Boring-command deprioritization (tmux-lives)

**Files:**
- Modify: `functions/tmux-categorize.fish` (the `$__tcz_shells` definition site + the running-category branch in `__tcz_snapshot`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: a session whose only non-shell pane command is in `$__tcz_boring` (`tail less watch cat more bat`) is categorized `general` (dir-named), never `running`/`tail`.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish` (private-socket harness), add: create a session whose active pane runs `tail -f somefile` (or a stubbed pane whose `pane_current_command` is `tail`); assert `__tcz_snapshot`'s line for it is category `general` and its display is the directory basename (NOT `tail`). Follow the file's existing pane-stub pattern.

- [ ] **Step 2: Run it and verify it fails.** `fish tests/test-tmux-categorize.fish` → FAIL (session is `running`/`tail`).

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:
  (a) Beside the `__tcz_shells` definition (the `set … __tcz_shells fish bash sh zsh dash` line near the top of the file), add:
```fish
set -g __tcz_boring tail less watch cat more bat
```
  (Match the scope — `-g` or `-l` — of the adjacent `__tcz_shells` line.)
  (b) In `__tcz_snapshot`, the running branch currently:
```fish
        else if not contains -- $f[2] $__tcz_shells
            test "$cats[$i]" = claude; or set cats[$i] running
            test -z "$firstcmd[$i]"; and set firstcmd[$i] $f[2]
        end
```
  Add the boring guard:
```fish
        else if not contains -- $f[2] $__tcz_shells; and not contains -- $f[2] $__tcz_boring
            test "$cats[$i]" = claude; or set cats[$i] running
            test -z "$firstcmd[$i]"; and set firstcmd[$i] $f[2]
        end
```

- [ ] **Step 4: Run the test and verify it passes.** `fish tests/test-tmux-categorize.fish` → PASS. Also confirm a session with a REAL running program (e.g. `node`) is still `running` (add/keep an assertion so the guard didn't over-reach).

- [ ] **Step 5: Commit.**
```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(name): deprioritize boring pager/tailer commands in session naming

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: ShellFish title honors `@tmux_lives_name` + docs (tmux-lives)

**Files:**
- Modify: `functions/tmux-categorize.fish` (`__tcz_session_title`), `CLAUDE.md`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `@tmux_lives_name` (Task 1); `__tcz_format_title`/`__tcz_hostname`/`__tcz_dir_display` (existing).
- Produces: `__tcz_session_title <session>` uses `@tmux_lives_name` (when set) as the middle instead of the dir basename.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish`, in the `__tcz_session_title` test area (the `function tmux` switch-stub block), extend the stub to also answer `show-option` for `@tmux_lives_name` (echo `Neurotto CLI`), and assert `__tcz_session_title sA` → `macwork: Neurotto CLI` (with `tmux_lives_hostname=macwork`), overriding the dir. Keep an existing no-`@tmux_lives_name` assertion (dir path) so the fallback still holds.

- [ ] **Step 2: Run it and verify it fails.** `fish tests/test-tmux-categorize.fish` → FAIL (title still uses the dir).

- [ ] **Step 3: Implement.** In `__tcz_session_title`, replace the dir computation so the explicit name wins:
```fish
    set -l name (tmux show-option -qv -t "$session" @tmux_lives_name 2>/dev/null)
    test -n "$name"; or set name (__tcz_dir_display $path)
    __tcz_format_title (__tcz_hostname) "$name" $claude
```
  (Remove the now-redundant `set -l dir (__tcz_dir_display $path)` line it replaces.)

- [ ] **Step 4: Run the test + full gate.** `fish tests/test-tmux-categorize.fish` → PASS; `fish -c 'for t in tests/test-*.fish; fish $t; end'` → all 8 suites `ALL PASS`.

- [ ] **Step 5: Document in CLAUDE.md.** In the status-bar/ShellFish paragraph, add:
```
A session may set `@tmux_lives_name "<name>"`; the categorizer then shows `<name>` as its display (switcher + overview) WITHOUT renaming the tmux session (the slug is left alone), and the ShellFish tab title (`__tcz_session_title`) uses `<name>` instead of the dir basename. Generic pager/tailer commands (`$__tcz_boring`: tail/less/watch/cat/more/bat) no longer name a session — they fall back to the directory.
```

- [ ] **Step 6: Commit.**
```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish CLAUDE.md
git commit -m "feat(name): ShellFish title honors @tmux_lives_name; document the mechanism

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**→ After Task 3: the tmux-lives mechanism is complete and shippable. Finish that branch (merge to main + push) before Task 4 (a separate repo/deploy).**

---

### Task 4: neurotto — one dedicated "Neurotto CLI" session

**Files (neurotto repo, branch `feat/cli-dedicated-session`):**
- Modify: `x/cli.sh` (the session slug + create-or-switch flow + set `@tmux_lives_name`)
- Modify: `x/kill.sh`, `x/toggle.sh`, `x/resize.sh`, `x/tmux.sh`, `src/cli/index.ts` (retarget the `cli` slug)

**Interfaces:**
- Consumes: tmux-lives `@tmux_lives_name` (Tasks 1/3, shipped).
- Produces: `cli` from anywhere lands on one session named `cli`, displayed "Neurotto CLI".

- [ ] **Step 1: Change the slug + create-or-switch in `x/cli.sh`.** Set `session=cli` (was `neurotto_cli_session`). Replace the IN_SESSION new-window/new-session branch with create-or-switch:
```bash
# One canonical dedicated session. Reuse it if present (create-or-switch), else build it.
if tmux has-session -t "=$session" 2>/dev/null; then
  if [ -n "$TMUX" ]; then tmux switch-client -t "=$session"; else tmux -u attach-session -t "=$session"; fi
  exit 0
fi
[ -n "$TMUX" ] || tmux -u -V start-server 2>/dev/null
tmux -u new-session -x- -y- -d -s "$session" -n "$window"
tmux set-option -t "=$session" @tmux_lives_name "Neurotto CLI"
```
  Keep the existing 2-pane build (`splitw`/`send-keys`/`select-pane -d`) targeting the new session's window, then at the end attach-or-switch:
```bash
if [ -n "$TMUX" ]; then tmux switch-client -t "=$session"; else tmux -u attach-session -t "=$session"; fi
```

- [ ] **Step 2: Retarget the `cli` slug in the sibling scripts.** In `x/kill.sh`, `x/toggle.sh`, `x/resize.sh`, `x/tmux.sh`, and `src/cli/index.ts`, replace references to the old session name `neurotto_cli_session` with `cli` (e.g. `kill-session -t neurotto_cli_session` → `kill-session -t "=cli"`). Fix the malformed probe in `src/cli/index.ts` (`tmux has-session -t ":neurotto_cli_window"` → `tmux has-session -t "=cli"`). The internal window name `neurotto_cli_window` (used by `kill.sh`/`resize.sh` pattern matches) stays as-is.

- [ ] **Step 3: Verify.** `cd /home/bitsaver/workspace/neurotto && bunx tsc --noEmit` → clean (for the index.ts edit). `bun test` → still green (no test regressions). Grep to confirm no stale `neurotto_cli_session` targets remain: `grep -rn 'neurotto_cli_session' x/ src/` → none (or only comments).

- [ ] **Step 4: Live smoke (deferred to user, post-deploy).** Do NOT run the CLI live here. Note for the user: from a shell → `cli` creates one `cli`/"Neurotto CLI" session; from inside tmux → `cli` switches to it (creating if absent), never adds a window to your work session; the switcher/tab show "Neurotto CLI".

- [ ] **Step 5: Commit (neurotto).**
```bash
git add x/cli.sh x/kill.sh x/toggle.sh x/resize.sh x/tmux.sh src/cli/index.ts
git commit -m "feat(cli): one dedicated 'Neurotto CLI' session (slug cli, create-or-switch)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** `@tmux_lives_name` display override — T1 (snapshot display + no-rename) ✓; boring-command deprioritization — T2 ✓; feature-(a) title honors the name — T3 ✓; neurotto dedicated create-or-switch session + set the name + retarget slug — T4 ✓; docs — T3 ✓; isolation via the `-L` socket / PATH-shim harness — all tmux-lives tasks ✓. Non-goals (orphan reaping, general rename UI) omitted.
- **Placeholder scan:** production code is exact; test steps specify assertions + reuse the existing harness (the implementer writes the fish by following the file's established `-L`-socket/stub patterns — which they must read).
- **Type/name consistency:** `@tmux_lives_name` (option key), `Neurotto CLI` (display), `cli` (slug), `$__tcz_boring` list — identical across T1–T4; `__tcz_session_title` (T3) consumes the same option T1 reads.
- **Ordering / shippability:** T1→T2→T3 are tmux-lives (merge first, ships via fisher update, harmless without a consumer); T4 is neurotto (separate branch/deploy, depends on T1/T3 being live). Each side is independently shippable.
