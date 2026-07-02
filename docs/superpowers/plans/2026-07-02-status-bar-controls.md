# Status-bar Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persisted `Ctrl+Opt+A` / `Ctrl+Opt+S` toggles for tmux status-bar position (top/bottom) and visibility (on/off), plus a `setup color --apply` that reapplies the stored bar color live to both the ShellFish toolbar and the tmux status bar.

**Architecture:** Two categorizer verbs flip the live tmux option and persist it to a machine-owned `~/.config/tmux/tmux-lives-state.conf`; the managed fragment sources that file on load so a fresh server reapplies it. `setup color --apply` reuses `__tmux_lives_derive_status` + the categorizer `recolor` verb to reapply the stored color live, no persistence change.

**Tech Stack:** fish shell, tmux 3.3a, the existing tmux-lives managed-fragment / categorizer / `~/.tmux-lives.conf` config surfaces.

## Global Constraints

- ZERO new files in the repo (the state file is a runtime file under `~/.config/tmux/`, not tracked). Only edit: `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`, `CLAUDE.md`, `README.md`.
- **Hard test-isolation invariant:** no test may touch the live default-socket tmux server, the live managed fragment, or the user's universals. Categorizer tests use the PATH `tmux` shim → `-L $sock`. Install-side tests stub `__tmux_lives_write_fragment` (backup/no-op/restore), drive live tmux through the `tmux_lives_tmux_socket` seam, use the `tmux_lives_state_file` seam for the state file, and save/restore any universal they set.
- fish `math` has NO comparison operators — use `test`.
- Defaults: status-position toggle key `C-M-a`, status-visibility toggle key `C-M-s`.
- State-file path default is `$HOME/.config/tmux/tmux-lives-state.conf`, overridable by the `tmux_lives_state_file` seam. The categorizer's inline default and `__tmux_lives_state_path` MUST stay in sync (cross-reference comment, like the baseline path).
- `__tmux_lives_render_fragment` positional args after this plan: `cat pkey skey color invert modalkey scratchkey resizekey statusposkey statusviskey` (argv[1..10]). `__tmux_lives_write_fragment` passes all 10.
- Framed `setup` help must still fit 80 columns (content ≤ 76).
- Commit messages MUST end with the trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Do NOT deploy (no `fisher`), do NOT edit `~/.config/fish`, `~/.config/tmux`, or `~/.tmux.conf`.
- Full-suite gate before each commit: `fish -c 'for t in tests/test-*.fish; fish $t; end'` — all 8 suites `ALL PASS`, 0 FAIL (ignorable flake: `test-tmux-restore.fish` may emit one stderr "no server running …" line).

---

### Task 1: Categorizer toggle verbs + state-file writer

**Files:**
- Modify: `functions/tmux-categorize.fish` (add three functions near `__tcz_scratch` ~line 1028; add two `__tcz_main` cases ~line 1085)
- Test: `tests/test-tmux-categorize.fish` (new block after the scratch-resize block, ~line 605)

**Interfaces:**
- Produces: `__tcz_status_pos_toggle`, `__tcz_status_vis_toggle` (no args; flip the live option, persist), `__tcz_write_state` (no args; writes the state file from the live values). `__tcz_main` dispatches verbs `status-pos-toggle` and `status-vis-toggle`.
- Consumes: bare `tmux` (PATH shim in tests); `tmux_lives_state_file` seam.

- [ ] **Step 1: Write the failing test.** Append to `tests/test-tmux-categorize.fish` immediately after line 605 (the `main dispatches resize-enter` assertion):

```fish
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
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_status_pos_toggle` is an unknown function (fish prints "Unknown command", the `t` assertions report FAIL, final line `SOME FAILED`).

- [ ] **Step 3: Add the three functions.** In `functions/tmux-categorize.fish`, immediately after `__tcz_scratch` ends (line 1028, the `end` before `__tcz_scratch_orient`), insert:

```fish
function __tcz_write_state --description 'persist the live status-position + visibility to the state file (seam: tmux_lives_state_file; default mirrors __tmux_lives_state_path — keep in sync)'
    set -l pos (tmux show -gv status-position 2>/dev/null); test -n "$pos"; or set pos bottom
    set -l vis (tmux show -gv status 2>/dev/null); test -n "$vis"; or set vis on
    set -l state (set -q tmux_lives_state_file; and echo $tmux_lives_state_file; or echo "$HOME/.config/tmux/tmux-lives-state.conf")
    mkdir -p (path dirname $state) 2>/dev/null
    printf 'set -g status-position %s\nset -g status %s\n' $pos $vis >$state
end
function __tcz_status_pos_toggle --description 'flip status-position top<->bottom, apply live + persist'
    set -l new bottom; test (tmux show -gv status-position 2>/dev/null) = bottom; and set new top
    tmux set -g status-position $new 2>/dev/null
    __tcz_write_state
end
function __tcz_status_vis_toggle --description 'flip status on<->off, apply live + persist'
    set -l new off; test (tmux show -gv status 2>/dev/null) = off; and set new on
    tmux set -g status $new 2>/dev/null
    __tcz_write_state
end
```

- [ ] **Step 4: Add the dispatch cases.** In `__tcz_main`, immediately after the `resize-enter` case (line 1086–1087, `case resize-enter` / `__tcz_resize_enter $argv[2..]`), insert:

```fish
        case status-pos-toggle
            __tcz_status_pos_toggle
        case status-vis-toggle
            __tcz_status_vis_toggle
```

- [ ] **Step 5: Run the test and verify it passes.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS — all new assertions `ok`, final line `ALL PASS`.

- [ ] **Step 6: Run the full gate.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: every suite `ALL PASS`, 0 FAIL (ignore the restore-suite stderr flake).

- [ ] **Step 7: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(status): status-pos/vis toggle verbs + state-file persistence

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fragment — source the state file + emit the toggle binds

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment` args + body; new `__tmux_lives_state_path`; `__tmux_lives_write_fragment` call)
- Test: `tests/test-tmux-install.fish` (extend the fragment-render block, after line 54)

**Interfaces:**
- Consumes: the categorizer verbs `status-pos-toggle` / `status-vis-toggle` (Task 1).
- Produces: `__tmux_lives_state_path` (no args → state-file path, honors `tmux_lives_state_file`). `__tmux_lives_render_fragment` now takes argv[9]=statusposkey, argv[10]=statusviskey and emits an `if-shell … source-file <state>` line plus two guarded `bind-key -n <key> run-shell … status-*-toggle` lines.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-install.fish`, immediately after line 54 (`command tmux -L $rsock kill-server …; rm -f …`), insert:

```fish
# status-bar toggle binds + state-file sourcing
set -g FRAGS (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s | string collect)
t "fragment binds status-pos key" yes (string match -q '*bind-key -n C-M-a run-shell*status-pos-toggle*' -- "$FRAGS"; and echo yes; or echo no)
t "fragment binds status-vis key" yes (string match -q '*bind-key -n C-M-s run-shell*status-vis-toggle*' -- "$FRAGS"; and echo yes; or echo no)
t "fragment sources the state file" yes (string match -q '*if-shell*tmux-lives-state.conf*source-file*tmux-lives-state.conf*' -- "$FRAGS"; and echo yes; or echo no)
set -g FRAGS0 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r '' '' | string collect)
t "no status-pos bind when key empty" no (string match -q '*status-pos-toggle*' -- "$FRAGS0"; and echo yes; or echo no)
t "no status-vis bind when key empty" no (string match -q '*status-vis-toggle*' -- "$FRAGS0"; and echo yes; or echo no)
# the full fragment (with the status binds) still parses on a real -L server
set -g rsock2 tli-sb-$fish_pid
command tmux -L $rsock2 new-session -d 2>/dev/null
printf '%s\n' "$FRAGS" | string replace -a '/x/cat.fish' '/tmp/nope.fish' >/tmp/tli-sbfrag-$fish_pid.conf
t "status fragment parses (source-file rc0)" 0 (command tmux -L $rsock2 source-file /tmp/tli-sbfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $rsock2 kill-server 2>/dev/null; rm -f /tmp/tli-sbfrag-$fish_pid.conf
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `__tmux_lives_render_fragment` ignores argv[9]/argv[10]; no status binds and no state-source line appear (`FAILED (N)`).

- [ ] **Step 3: Add `__tmux_lives_state_path`.** In `conf.d/tmux-lives-install.fish`, immediately after `__tmux_lives_baseline_path` ends (line 432), insert:

```fish
function __tmux_lives_state_path --description 'path to the machine-owned status-toggle state file (seam: tmux_lives_state_file)'
    # Default mirrors __tcz_write_state's inline path in functions/tmux-categorize.fish — keep in sync.
    set -q tmux_lives_state_file; and echo $tmux_lives_state_file; or echo "$HOME/.config/tmux/tmux-lives-state.conf"
end
```

- [ ] **Step 4: Extend `__tmux_lives_render_fragment`.** Three edits inside the function:

(a) After line 19 (`set -l resizekey $argv[8] …`), add:

```fish
    set -l statusposkey $argv[9]   # root-table status-position toggle ('' = no bind)
    set -l statusviskey $argv[10]  # root-table status-visibility toggle ('' = no bind)
```

(b) After line 20 (`set -l baseline (__tmux_lives_baseline_path)`), add:

```fish
    set -l state (__tmux_lives_state_path)
```

(c) After the status-style line (line 57, `test -n "$ss"; and set -a f "set -g status-style $ss"`), add the state-source line so a persisted position/visibility wins over the fragment's + baseline's status setup:

```fish
    # reapply the persisted status-position/visibility (written by the C-M-a/C-M-s toggles)
    set -a f "if-shell '[ -f $state ]' 'source-file $state'"
```

(d) After the resize-mode block ends (line 77, the `end` closing `if test -n "$resizekey"`), add the two toggle binds (mirroring the scratch bind at line 65):

```fish
    test -n "$statusposkey"; and set -a f "bind-key -n $statusposkey run-shell 'fish --no-config $cat status-pos-toggle'"
    test -n "$statusviskey"; and set -a f "bind-key -n $statusviskey run-shell 'fish --no-config $cat status-vis-toggle'"
```

- [ ] **Step 5: Thread the keys through `__tmux_lives_write_fragment`.** On line 151, append two args to the `__tmux_lives_render_fragment` call, immediately before `> $fragment`:

```fish
 (__tmux_lives_key tmux_lives_status_pos_key C-M-a) (__tmux_lives_key tmux_lives_status_vis_key C-M-s)
```

So the full call reads: `__tmux_lives_render_fragment $cat (…prefix…) (…switcher…) (…bar_color…) (…invert…) (…modal…) (…scratch…) (…resize…) (__tmux_lives_key tmux_lives_status_pos_key C-M-a) (__tmux_lives_key tmux_lives_status_vis_key C-M-s) > $fragment`

- [ ] **Step 6: Run the test and verify it passes.**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS — the new assertions `ok`, `ALL PASS`.

- [ ] **Step 7: Run the full gate.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: all 8 suites `ALL PASS`, 0 FAIL.

- [ ] **Step 8: Confirm no live leak, then commit.**

Run: `grep -cE 'status-pos-toggle|status-vis-toggle|tmux-lives-state' ~/.config/tmux/tmux-lives.conf` → expect `0` (the suite didn't write the live fragment).

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(status): fragment sources the state file + emits C-M-a/C-M-s toggle binds

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `setup keys --status-pos-key` / `--status-vis-key` + help

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_keys_cmd` cases; `__tmux_lives_setup_help_lines`)
- Test: `tests/test-tmux-install.fish` (extend the `setup keys` block, after line 72)

**Interfaces:**
- Consumes: the universals baked by `__tmux_lives_write_fragment` (Task 2).
- Produces: `setup keys --status-pos-key <k>` → `tmux_lives_status_pos_key`; `--status-vis-key <k>` → `tmux_lives_status_vis_key`.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-install.fish`, immediately after line 72 (`set -e tmux_lives_resize_key`), insert:

```fish
set -e tmux_lives_status_pos_key; set -e tmux_lives_status_vis_key
functions -c __tmux_lives_write_fragment __wf4_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --status-pos-key C-M-a --status-vis-key C-M-s
t "keys --status-pos-key persists" C-M-a "$tmux_lives_status_pos_key"
t "keys --status-vis-key persists" C-M-s "$tmux_lives_status_vis_key"
functions -e __tmux_lives_write_fragment; functions -c __wf4_bak __tmux_lives_write_fragment; functions -e __wf4_bak
set -e tmux_lives_status_pos_key; set -e tmux_lives_status_vis_key
t "help documents --status-pos-key" yes (string match -q '*--status-pos-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "help documents --status-vis-key" yes (string match -q '*--status-vis-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo yes; or echo no)
t "setup help still fits 80 cols framed" yes (set -l mx 0; for l in (__tmux_lives_setup_help_lines); set -l w (string length --visible -- $l); test $w -gt $mx; and set mx $w; end; test (math "$mx + 4") -le 80; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `--status-pos-key` is an unknown option (the `keys_cmd` prints "unknown option", the persistence assertions and help assertions FAIL).

- [ ] **Step 3: Add the option cases.** In `__tmux_lives_keys_cmd`, immediately after the `--resize-key` case (lines 326–327), insert:

```fish
            case --status-pos-key
                set -U tmux_lives_status_pos_key $argv[2]; set changed 1; set -e argv[1..2]
            case --status-vis-key
                set -U tmux_lives_status_vis_key $argv[2]; set changed 1; set -e argv[1..2]
```

- [ ] **Step 4: Add the help lines.** In `__tmux_lives_setup_help_lines`, immediately after the `--resize-key` line (line 524), insert (description column aligned at col 29, ≤ 76 visible):

```fish
        "      --status-pos-key <key> status bar top/bottom (default: C-M-a; '' off)" \
        "      --status-vis-key <key> status bar hide/show  (default: C-M-s; '' off)" \
```

- [ ] **Step 5: Run the test and verify it passes.**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS — new assertions `ok`, including `setup help still fits 80 cols framed`, `ALL PASS`.

- [ ] **Step 6: Run the full gate.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: all 8 suites `ALL PASS`, 0 FAIL.

- [ ] **Step 7: Commit.**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(status): setup keys --status-pos-key / --status-vis-key + help

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `setup color --apply` / `-a`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_color_cmd`)
- Test: `tests/test-tmux-install.fish` (new block after the color block, after line 195)

**Interfaces:**
- Consumes: `tmux_lives_bar_color`, `tmux_lives_status_invert`, `__tmux_lives_derive_status`, the categorizer `recolor` verb, the `tmux_lives_tmux_socket` seam.
- Produces: `setup color --apply` / `-a` reapplies the stored color live to `status-style` (seam-aware) + the ShellFish OSC (guarded shell-out); no persistence change.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-install.fish`, immediately after line 195 (`rm -f $cfrag`), insert:

```fish
# setup color --apply: reapply stored color live (status-style via the socket seam; recolor guarded)
set -g apsock tli-apply-$fish_pid
command tmux -L $apsock new-session -d 2>/dev/null
set -gx tmux_lives_tmux_socket $apsock
set -g __old_fcd2 $__fish_config_dir
set -g __fish_config_dir /tmp/tcz-nofish2-$fish_pid   # recolor's test -f guard short-circuits
set -l _abc_had 0; set -l _abc_val
if set -q tmux_lives_bar_color; set _abc_had 1; set _abc_val $tmux_lives_bar_color; end
set -l _asi_had 0; set -l _asi_val
if set -q tmux_lives_status_invert; set _asi_had 1; set _asi_val $tmux_lives_status_invert; end
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
t "color --apply with no color: rc1" 1 (__tmux_lives_color_cmd --apply >/dev/null 2>&1; echo $status)
set -U tmux_lives_bar_color "#1f6feb"; set -U tmux_lives_status_invert 0
__tmux_lives_color_cmd --apply >/dev/null
t "color --apply sets derived status-style live" 1 (string match -q '*bg=#5793f0*' -- (command tmux -L $apsock show -gv status-style); and echo 1; or echo 0)
t "color -a rejects an extra color arg (rc1)" 1 (__tmux_lives_color_cmd -a "#abc" >/dev/null 2>&1; echo $status)
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
if test $_abc_had -eq 1; set -U tmux_lives_bar_color $_abc_val; end
if test $_asi_had -eq 1; set -U tmux_lives_status_invert $_asi_val; end
set -g __fish_config_dir $__old_fcd2; set -e __old_fcd2
set -e tmux_lives_tmux_socket
command tmux -L $apsock kill-server 2>/dev/null
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `--apply` is treated as a positional color (invalid), so `color --apply with no color: rc1` may pass by accident but `color --apply sets derived status-style live` FAILS (status-style never set on `$apsock`). Confirm at least the status-style assertion fails.

- [ ] **Step 3: Add the `--apply` mode.** In `__tmux_lives_color_cmd`:

(a) Add an `apply` flag. Change the parse loop (lines 384–394) so the `set -l invert 0` line region gains `set -l apply 0` and the `switch` handles `-a`/`--apply`. Replace lines 384–394 with:

```fish
    set -l invert 0
    set -l color
    set -l have_color 0
    set -l apply 0
    for a in $argv
        switch $a
            case -i --invert
                set invert 1
            case -a --apply
                set apply 1
            case '*'
                set color $a; set have_color 1
        end
    end
```

(b) Immediately after that loop (before line 395's `if test (count $argv) -eq 0`), insert the apply handling:

```fish
    if test $apply -eq 1
        if test $have_color -eq 1
            echo "tmux-lives setup color: --apply takes no color argument" >&2
            return 1
        end
        set -l c (__tmux_lives_key tmux_lives_bar_color '')
        if test -z "$c"
            echo "tmux-lives: no bar color set — set one with: tmux-lives setup color \"#rrggbb\"" >&2
            return 1
        end
        set -l ss (__tmux_lives_derive_status $c (__tmux_lives_key tmux_lives_status_invert 0))
        if test -n "$ss"
            if set -q tmux_lives_tmux_socket
                command tmux -L $tmux_lives_tmux_socket set -g status-style $ss 2>/dev/null
            else
                tmux set -g status-style $ss 2>/dev/null
            end
        end
        set -l cat "$__fish_config_dir/functions/tmux-categorize.fish"
        test -f $cat; and fish --no-config $cat recolor $c 2>/dev/null
        echo "tmux-lives: reapplied bar color $c"
        return 0
    end
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS — all three `color --apply` assertions `ok`, `ALL PASS`.

- [ ] **Step 5: Run the full gate + confirm no leak.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'` → all 8 `ALL PASS`, 0 FAIL.
Run: `fish -c 'echo $tmux_lives_bar_color'` → your real color is unchanged (the block save/restores it).

- [ ] **Step 6: Commit.**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(color): setup color --apply reapplies the stored color live (OSC + status-style)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Docs + vault-publish

**Files:**
- Modify: `CLAUDE.md`, `README.md`

- [ ] **Step 1: Update `README.md`.** In the "In-tmux command surface" section, after the `Scratch resize mode (M-r)` paragraph, add:

```markdown
**Status-bar toggles (`C-M-a` / `C-M-s`)** — `Ctrl+Opt+A` flips the status bar between top and bottom; `Ctrl+Opt+S` hides/shows it. The chosen value is stored in `~/.config/tmux/tmux-lives-state.conf` (machine-owned) and reapplied on every load, so it survives new sessions and reboots. Configure or disable the keys with `setup keys --status-pos-key <k>` / `--status-vis-key <k>` (`''` disables).
```

And in the `setup color` area (or the ShellFish subsection), add a sentence:

```markdown
`tmux-lives setup color --apply` (short `-a`) reapplies the currently-stored color to both surfaces — the ShellFish tab OSC and the tmux status bar — without retyping it (handy if a new ShellFish tab came up without the color).
```

- [ ] **Step 2: Update `CLAUDE.md`.** In the status-bar / ShellFish paragraph, add a sentence documenting: the `C-M-a`/`C-M-s` toggles (`__tcz_status_pos_toggle`/`__tcz_status_vis_toggle` + `__tcz_write_state`), the machine-owned `~/.config/tmux/tmux-lives-state.conf` state file (seam `tmux_lives_state_file`, sourced by the fragment after the baseline so it wins), the `setup keys --status-pos-key`/`--status-vis-key` flags (`tmux_lives_status_pos_key`/`_vis_key`, defaults `C-M-a`/`C-M-s`), and `setup color --apply`/`-a` (reapplies the stored color live to status-style + the ShellFish OSC via `__tcz_recolor`, no re-render).

- [ ] **Step 3: Verify docs + full gate.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'` → all 8 `ALL PASS` (docs don't affect tests, but confirm nothing regressed).

- [ ] **Step 4: Commit + vault-publish the README.**

```bash
git add CLAUDE.md README.md
git commit -m "docs: status-bar toggles (C-M-a/C-M-s) + setup color --apply

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Then invoke the `vault-publish` skill on `README.md` (`--type project --project "$(cat .vault-project)" --title "Tmux-lives - README"`).

---

## Pre-flight (already validated on this host, tmux 3.3a)

- `show -gv status-position` → `top`/`bottom`; `set -g status-position top` rc0.
- `show -gv status` → `on`/`off`; `set -g status off` rc0.
- `bind-key -n C-M-a` / `C-M-s` parse rc0.
- `if-shell '[ -f … ]' 'source-file …'` applies the state file.
- `set -g status-style …` takes effect live.

## Migration note (surface to the user at deploy)

A fresh server currently reports `status-position=top`, so the user sets it manually somewhere (likely `~/.tmux.conf` or `~/.tmux-lives.conf`). Once the toggle owns it via the state file, any manual `status-position` line should be removed to avoid a source-order tug-of-war (the fragment sources the state file after the baseline, so it wins over `~/.tmux-lives.conf`, but a line in `~/.tmux.conf` placed *after* the fragment `source-file` would override the state file).

## Self-Review

- **Spec coverage:** Toggles/state file (Tasks 1–2) ✓; fragment reapply-on-load (Task 2) ✓; configurable keys (Task 3) ✓; `setup color --apply` both surfaces (Task 4) ✓; testing/isolation (each task uses PATH shim / `tmux_lives_tmux_socket` + `tmux_lives_state_file` seams + write_fragment stub + universal save/restore) ✓; docs (Task 5) ✓.
- **Placeholder scan:** none — every step carries exact code/commands.
- **Type/name consistency:** verbs `status-pos-toggle`/`status-vis-toggle`, functions `__tcz_status_pos_toggle`/`__tcz_status_vis_toggle`/`__tcz_write_state`, universals `tmux_lives_status_pos_key`/`tmux_lives_status_vis_key`, flags `--status-pos-key`/`--status-vis-key`, seam `tmux_lives_state_file`, helper `__tmux_lives_state_path` — used consistently across tasks. Render arg order (argv[9]=statusposkey, argv[10]=statusviskey) matches the write_fragment call.
