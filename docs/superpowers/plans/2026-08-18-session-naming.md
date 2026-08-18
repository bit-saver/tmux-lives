# Session Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Name sessions after the project directory they were started in, show a `project · task` display for claude sessions, and stop using the running process name entirely.

**Architecture:** Two new pure helpers compute the project and the display string. `__tcz_snapshot` calls them instead of its per-category naming, so the picker gets the new display with no change to the row's shape. `__tcz_categorize` derives the safe tmux name from the project and writes the pretty form to a new `@tmux_lives_display` option, which the status bar and tab title read through tmux format strings.

**Tech Stack:** fish 4.x, tmux 3.3a (rocket) / 3.7b (macwork), the repo's existing `-L`-socket + PATH-shim test harness.

**Spec:** `docs/superpowers/specs/2026-08-18-session-naming-design.md` — read it first; this plan argues from it.

## Global Constraints

- **The snapshot row keeps EXACTLY 5 tab-separated fields.** Five call sites split it with `string split -m 4`, which makes the last field greedy — appending a field would silently fold into `display`. Do not change the arity.
- **`@tmux_lives_name` is an EXTERNAL claim.** Nothing in this repo writes it and nothing in this plan may start. It outranks everything and must keep suppressing renames, or neurotto breaks.
- **`@tmux_lives_display` is cleared at the TOP of every `__tcz_categorize` iteration**, before both early `continue`s, or a hand-renamed session keeps a stale display forever.
- **Target with the helpers, never a bare name.** `__tcz_session_target` for `set-option`/`show-option`/`capture-pane`; `__tcz_pane_target` for `list-panes`. A purely numeric session name resolves as the CURRENT session otherwise.
- **Capture command substitutions into a variable before comparing.** `test -z (cmd)` throws on zero output, and an undefined function called directly inside `t` aborts the whole statement silently while the suite still reports ALL PASS.
- **Every assertion must be proven to FAIL against the pre-change code.** Briefs in this plan have not been executed; treat them as suspect and say so if one cannot go red.
- Gate: `for m in "" "--no-config"; do for t in tests/test-*.fish; do fish $m "$t"; done; done` — 8/8 ALL PASS both modes. Pass an explicit `timeout: 600000` to the Bash tool; the gate exceeds the 120s default and gets auto-backgrounded. **Do not background it.**

---

### Task 1: `__tcz_project_name` — the project rule

**Files:**
- Modify: `functions/tmux-categorize.fish` (add beside `__tcz_slugify`, near line 14)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_project_name <path>` → the basename, or NOTHING when the path is generic or empty.

- [ ] **Step 1: Write the failing tests**

Add next to the existing `__tcz_slugify` tests:

```fish
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
```

- [ ] **Step 2: Run and verify it fails**

Run: `timeout 600 fish tests/test-tmux-categorize.fish 2>&1 | grep -a "project:"`
Expected: the four non-empty cases FAIL with `got []` (the function does not exist, so each capture is empty). The three empty-expectation cases PASS — they are non-regression guards, not discriminators, and that is fine.

- [ ] **Step 3: Implement**

```fish
function __tcz_project_name --argument-names path --description 'session start dir -> project name, or NOTHING when the directory carries no project meaning. Generic dirs ($HOME, /, /tmp) deliberately yield empty so the caller falls back to gen-N rather than naming a session `bitsaver` or `tmp`. Spaces are PRESERVED: this feeds the display layer, and the safe tmux name is slugified separately by the caller.'
    test -n "$path"; or return
    set -l p (string replace -r '/+$' '' -- "$path")
    test -n "$p"; or return              # "/" collapses to empty
    contains -- "$p" "$HOME" /tmp /var/tmp; and return
    path basename -- "$p"
end
```

- [ ] **Step 4: Run and verify it passes**

Run: `timeout 600 fish tests/test-tmux-categorize.fish 2>&1 | grep -a "project:"`
Expected: all seven PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(naming): add __tcz_project_name, the project rule"
```

---

### Task 2: `__tcz_display_name` — composition

**Files:**
- Modify: `functions/tmux-categorize.fish` (immediately after `__tcz_project_name`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_project_name` from Task 1.
- Produces: `__tcz_display_name <category> <project> <task>` → the display string, or NOTHING when there is nothing worth showing.

- [ ] **Step 1: Write the failing tests**

```fish
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
```

- [ ] **Step 2: Run and verify it fails**

Run: `timeout 600 fish tests/test-tmux-categorize.fish 2>&1 | grep -a "display:"`
Expected: the five non-empty cases FAIL with `got []`.

**`display: running IGNORES the process name` is the discriminator for the whole "no more `node`" requirement** — it is passed `node` as the task and must not return it.

- [ ] **Step 3: Implement**

```fish
function __tcz_display_name --argument-names category project task --description 'compose what a human reads: "project · task" for a claude session, the project alone for anything else. The task is DELIBERATELY ignored outside the claude category — that is what stops a node dev server reading as `node`. Uses U+00B7, the same separator the status bar already puts between fields. Returns nothing when there is neither a project nor a task, leaving the caller on the tmux name.'
    if test "$category" = claude; and test -n "$project"; and test -n "$task"
        echo "$project · $task"
        return
    end
    test -n "$project"; and echo "$project"; and return
    test "$category" = claude; and test -n "$task"; and echo "$task"
end
```

- [ ] **Step 4: Run and verify it passes**

Expected: all six PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(naming): add __tcz_display_name, project-then-task composition"
```

---

### Task 3: `__tcz_snapshot` uses the project

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_snapshot`, the `sess_fmt` line and the `set -l display` switch (around lines 341 and 396-414)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: both helpers from Tasks 1-2.
- Produces: the snapshot row's 5th field now carries the new display. **Arity unchanged — still exactly 5 fields.**

- [ ] **Step 1: Write the failing tests**

```fish
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
```

- [ ] **Step 2: Run and verify it fails**

Expected: the first FAILS with `got [sleep]` — today a `running` session displays `$firstcmd`, the process name. The arity assertion PASSES at both ends; it is the guard that the fix does not break the five `string split -m 4` consumers.

- [ ] **Step 3: Implement**

Add `#{session_path}` to `sess_fmt` (free — same `list-sessions` call) and carry it. Change the line at ~341 to:

```fish
    set -l sess_fmt (printf '#{session_name}\t#{session_attached}\t#{session_last_attached}\t#{@tmux_lives_name}\t#{session_path}')
```

Then in the session loop that populates `$sdisp`, capture the path into a parallel `$spath` list the same way. Replace the whole `set -l display` / `switch $cats[$i]` block with:

```fish
        set -l proj
        test -n "$j"; and set proj (__tcz_project_name "$spath[$j]")
        set -l task
        if test "$cats[$i]" = claude
            set task (__tcz_cmdline_name $cpid[$i])
            test -n "$task"; or set task (__tcz_title_name "$ctitle[$i]")
        end
        set -l display (__tcz_display_name $cats[$i] "$proj" "$task")
        # @tmux_lives_name is an EXTERNAL claim and outranks everything.
        test -n "$j"; and test -n "$sdisp[$j]"; and set display "$sdisp[$j]"
```

Leave the `printf` emit line exactly as it is.

- [ ] **Step 4: Run and verify it passes**

Run the whole suite: `timeout 600 fish tests/test-tmux-categorize.fish`
Expected: ALL PASS. **Several existing snapshot assertions will need updating** — the `snap: boring command -> general` and `snap: real program -> still running` tests assert the CATEGORY (field 2) and must still pass untouched, but any test asserting field 5 for a non-claude session now expects the project. Update those expectations and say in your report exactly which ones you changed and why; do not change a category assertion.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(naming): snapshot displays the project, never the process name"
```

---

### Task 4: `__tcz_categorize` — safe name and the display option

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_categorize` (around lines 455-500)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_project_name`, `__tcz_display_name`.
- Produces: sessions named for their project; `@tmux_lives_display` set on named sessions and absent on every other.

- [ ] **Step 1: Write the failing tests**

```fish
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
```

- [ ] **Step 2: Run and verify it fails**

Expected: `session named for its project` FAILS (today it is named `sleep`), and both display assertions FAIL with `got []` since nothing writes the option. The three protection assertions PASS at both ends — they are the guards that this task must not break, **and the claim one is the single most important assertion in this cycle.**

- [ ] **Step 3: Implement**

At the TOP of the `for line in (__tcz_snapshot $only)` body, immediately after `set -l cur $f[1]` and **before** the claim check and the ownership guard, clear the option:

```fish
        # Cleared FIRST, before both early continues. A session only carries a
        # display in the same pass that named it -- otherwise a hand-renamed or
        # claimed session keeps a stale one forever and the user's own rename
        # looks ignored.
        tmux set-option -u -t (__tcz_session_target "$cur") @tmux_lives_display 2>/dev/null
```

Replace the `switch $f[2]` desired-name block with the project rules:

```fish
        set -l proj (__tcz_project_name "$paths_$cur")
        set -l desired
        if test -n "$proj"
            set desired (__tcz_slugify "$proj")
        else
            string match -qr '^gen-[0-9]+$' -- "$cur"; and continue
        end
```

`$paths_$cur` comes from ONE batched lookup taken once, BEFORE the loop — not a
`display-message` per session, which would re-add the per-session tmux calls the
2026-08-17 narrowing work just removed:

```fish
    set -l TAB (printf '\t')
    for l in (tmux list-sessions -F "#{session_name}$TAB#{session_path}" 2>/dev/null)
        set -l kv (string split -m 1 $TAB -- $l)
        test (count $kv) -eq 2; or continue
        set -g paths_$kv[1] $kv[2]
    end
```

After the successful `rename-session` and `@tmux_auto_name` stamp, write the display.
**Field 5 of the snapshot row IS the composed display already** (Task 3 made it so) —
do NOT call `__tcz_display_name` again here, or you compose a display out of a display:

```fish
        test -n "$f[5]"; and tmux set-option -t (__tcz_session_target "$desired") @tmux_lives_display "$f[5]" 2>/dev/null
```

- [ ] **Step 4: Run and verify it passes**

Run: `timeout 600 fish tests/test-tmux-categorize.fish`
Expected: ALL PASS. Existing `cat:` assertions that expect a command-derived name (`sleep`, etc.) now expect the project or `gen-N`; update them and report exactly which and why.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(naming): name sessions for their project, write @tmux_lives_display"
```

---

### Task 5: the format-string surfaces

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_status_identity` (~line 249) and `__tcz_session_title` (~line 3085)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `@tmux_lives_display` written in Task 4.

- [ ] **Step 1: Write the failing tests**

```fish
set -g ident (__tcz_status_identity)
t "identity: consults the display option" 1 \
    (string match -q '*@tmux_lives_display*' -- "$ident"; and echo 1; or echo 0)
t "identity: the claim still appears first" 1 \
    (test (string match -r '@tmux_lives_name' -- "$ident" | count) -ge 1; and echo 1; or echo 0)

cleanup
mkdir -p $HOME/tcz-title-$fish_pid/deep
tmux new-session -d -s ts1 -c $HOME/tcz-title-$fish_pid
sleep 0.4
tmux send-keys -t ts1 "cd $HOME/tcz-title-$fish_pid/deep" Enter
sleep 1.0
set -g title_after (__tcz_session_title ts1)
t "title: pinned to the session start dir, not the pane cwd" 1 \
    (string match -q '*tcz-title-'$fish_pid'*' -- "$title_after"; and string match -qv '*deep*' -- "$title_after"; and echo 1; or echo 0)
rm -rf $HOME/tcz-title-$fish_pid
cleanup
```

- [ ] **Step 2: Run and verify it fails**

Expected: `identity: consults the display option` FAILS (0) — the format string has no such reference. `title: pinned to the session start dir` FAILS (0) — `__tcz_session_title` reads `pane_current_path`, which followed the `cd` into `deep`.

- [ ] **Step 3: Implement**

In `__tcz_status_identity`, insert the display between the claim and the fallback, keeping the claim outermost. The non-claude branch becomes, in order: `@tmux_lives_name`, then `@tmux_lives_display`, then `#{session_name}`; the claude branch becomes `@tmux_lives_name`, then `@tmux_lives_display`, then `@tmux_lives_claude`.

In `__tcz_session_title`, replace the `list-panes` path lookup with the session's own start directory and prefer the display option:

```fish
    set -l path (tmux display-message -p -t (__tcz_pane_target "$session") '#{session_path}' 2>/dev/null)
    set -l name (tmux show-option -qv -t (__tcz_session_target "$session") @tmux_lives_name 2>/dev/null)
    test -n "$name"; or set name (tmux show-option -qv -t (__tcz_session_target "$session") @tmux_lives_display 2>/dev/null)
    test -n "$name"; or set name (__tcz_dir_display $path)
```

- [ ] **Step 4: Run and verify it passes**

Run the full gate, both modes. Expected 8/8 ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(naming): status identity and tab title read the display option"
```

---

### Task 6: mutation pass, docs, and the gate

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the mutation battery**

Restore from a FILE COPY between mutations, never `git checkout` — the work may be uncommitted and `git checkout` reverts to HEAD, which destroyed an implementation mid-battery on 2026-08-16. Verify byte-identity after each restore.

Mutate each of these and record which assertions break; each must break its OWN group and leave the others green:

1. `__tcz_project_name` drops the generic-dir check → `$HOME`/`/tmp` cases.
2. `__tcz_display_name` returns `$task` for the `running` category → the process-name discriminator.
3. The clear-at-top moves BELOW the ownership guard → the staleness assertion.
4. The claim check is removed from `__tcz_categorize` → the neurotto regression assertion.
5. `__tcz_session_title` goes back to `pane_current_path` → the tab-title pin.

- [ ] **Step 2: Run the full gate**

```bash
for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done
```

Expected: 8/8 ALL PASS both modes. The `test-tmux-install.fish` count differing by 1 between modes is BY DESIGN.

- [ ] **Step 3: Document**

Add a paragraph to `CLAUDE.md` before `## claude-mem history` covering: the three-layer model and its precedence; that `@tmux_lives_name` is an external claim nothing here writes; that `#{session_path}` is stable while `#{pane_current_path}` follows `cd`; that the display is cleared at the top of every iteration and why; and that process names are never used for naming while the categories still drive picker grouping.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): record the project-anchored session naming model"
```
