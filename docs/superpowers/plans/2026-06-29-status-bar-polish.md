# Status Bar Polish + General Config File — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tinted true-hex status text, `~/.tmux-lives.conf` promoted to the general (load + non-SF-attach) config file seeded with status-bar polish, status-right via `#{T:@var}`, and a `setup conf reset` command.

**Architecture:** `__tmux_lives_derive_status` emits a hex tint of the bar's hue as the status fg. The fragment sources `~/.tmux-lives.conf` at load, sets a default `@tmux_lives_status_right`, and wires `status-right "#{T:@tmux_lives_status_right}#(… tick)"` (continuum prepends its save). The seeded file holds the editable status-bar polish; `setup conf reset` restores it (backup first).

**Tech Stack:** fish shell (`math` with `round()`/hex; no comparison operators), tmux. Tests are fish scripts under `tests/`.

## Global Constraints

- All code in `conf.d/tmux-lives-install.fish`. **Zero new files.**
- Tint formula (per derived-bar channel `c`): dark bar (`L ≤ 140`) → `round(c + (255−c)×0.68)`; light bar (`L > 140`) → `round(c × 0.32)`; emit `bg=#rrggbb,fg=#rrggbb` (both lowercase hex). `L = round(0.299r + 0.587g + 0.114b)`. **fish `math` has no comparison operators — use `test $L -gt 140`.**
- **Verified tint vectors** (test expectations): `#1f6feb 0`→`bg=#5793f0,fg=#c9dcfa`; `#1f6feb 1`→`bg=#1753b0,fg=#b5c8e6`; `#ffee88 0`→`bg=#fff2a6,fg=#524d35`; `#102030 0`→`bg=#4c5864,fg=#c6cacd`; `#87af00 1`→`bg=#658300,fg=#ced7ad`.
- `status-right` MUST reference the var with the **`T:` modifier**: `#{T:@tmux_lives_status_right}` (a bare `#{@var}` is not strftime-expanded — verified). The user's file sets only the `@var`, never `status-right`.
- The general file is sourced at load via `if-shell '[ -f <path> ]' 'source-file <path>'`; `<path>` = `(__tmux_lives_baseline_path)` (honors the `tmux_lives_baseline_conf` seam).
- Seed is idempotent (never overwrites); `setup conf reset` force-writes (after a `.bak` backup).
- Framed `tmux-lives setup -h` ≤ 80 visible columns.
- Tests must save/restore real universal vars they touch.

Full suite: `fish -c 'for t in tests/test-*.fish; echo "== $t =="; fish $t | tail -1; end'`

---

### Task 1: Tinted status-text fg (`__tmux_lives_derive_status`)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_derive_status` (the fg lines + the description)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_derive_status <color> <invert>` → `bg=#rrggbb,fg=#rrggbb` (fg is now a tinted hex, not `black`/`white`).

- [ ] **Step 1: Update the failing test expectations**

In `tests/test-tmux-install.fish`, change the existing derive assertions to the tinted values, and the one fragment-status-style assertion that pins the fg. Replace these lines:

```fish
t "derive: lighter #1f6feb"  "bg=#5793f0,fg=white" (__tmux_lives_derive_status "#1f6feb" 0)
t "derive: darker  #1f6feb"  "bg=#1753b0,fg=white" (__tmux_lives_derive_status "#1f6feb" 1)
t "derive: light base -> black fg" "bg=#fff2a6,fg=black" (__tmux_lives_derive_status "#ffee88" 0)
t "derive: dark base -> white fg"  "bg=#4c5864,fg=white" (__tmux_lives_derive_status "#102030" 0)
```
with:
```fish
t "derive: lighter #1f6feb"  "bg=#5793f0,fg=#c9dcfa" (__tmux_lives_derive_status "#1f6feb" 0)
t "derive: darker  #1f6feb"  "bg=#1753b0,fg=#b5c8e6" (__tmux_lives_derive_status "#1f6feb" 1)
t "derive: light base tinted" "bg=#fff2a6,fg=#524d35" (__tmux_lives_derive_status "#ffee88" 0)
t "derive: dark base tinted"  "bg=#4c5864,fg=#c6cacd" (__tmux_lives_derive_status "#102030" 0)
```
and change the Task-2-era fragment assertion:
```fish
t "fragment status-style lighter" 1 (string match -q '*set -g status-style bg=#5793f0,fg=white*' -- "$fragss"; and echo 1; or echo 0)
```
to:
```fish
t "fragment status-style lighter" 1 (string match -q '*set -g status-style bg=#5793f0,fg=#c9dcfa*' -- "$fragss"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: derive: lighter #1f6feb …` (still produces `fg=white`).

- [ ] **Step 3: Implement the tint**

In `conf.d/tmux-lives-install.fish`, replace these lines in `__tmux_lives_derive_status`:
```fish
    # fish `math` has NO comparison operators — compute integer luminance (0-255) and
    # compare with `test`. 0.55 * 255 ≈ 140, so L > 140 → black text, else white.
    set -l fg white
    set -l L (math "round(0.299 * $r + 0.587 * $g + 0.114 * $b)")
    test $L -gt 140; and set fg black
    echo "bg=$hex,fg=$fg"
```
with:
```fish
    # Tinted text (Light tint f=0.68): a hex shade of the bar's own hue, blended toward
    # white (dark bar) or black (light bar). Palette-independent; visible hue, still clearly
    # light/dark. fish `math` has no comparison operators -> integer luminance + test.
    set -l L (math "round(0.299 * $r + 0.587 * $g + 0.114 * $b)")
    set -l tr; set -l tg; set -l tb
    if test $L -gt 140
        set tr (math "round($r * 0.32)"); set tg (math "round($g * 0.32)"); set tb (math "round($b * 0.32)")
    else
        set tr (math "round($r + (255 - $r) * 0.68)"); set tg (math "round($g + (255 - $g) * 0.68)"); set tb (math "round($b + (255 - $b) * 0.68)")
    end
    echo "bg=$hex,fg="(printf '#%02x%02x%02x' $tr $tg $tb)
```
Also update the function's `--description` from `… -> "bg=#rrggbb,fg=black|white" …` to `… -> "bg=#rrggbb,fg=#rrggbb" …`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): tinted true-hex status text (fixes palette tan)"
```

---

### Task 2: Fragment sources the general config + wires status-right via `#{T:@var}`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_baseline_path` (existing).
- Produces: the fragment sources `~/.tmux-lives.conf` (guarded), sets a default `@tmux_lives_status_right`, and sets `status-right "#{T:@tmux_lives_status_right}#(… tick)"` (replacing the old guarded `set -ga status-right` append).

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` after the existing fragment status-style tests (search for `t "no color -> no status-style"`):
```fish
set -l fragsr (__tmux_lives_render_fragment /X/cat.fish S M-s "" 0 | string collect)
t "fragment sources user config"  1 (string match -q '*source-file*.tmux-lives.conf*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment default status-right var" 1 (string match -q '*set -g @tmux_lives_status_right*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment status-right uses T:@var" 1 (string match -q '*set -g status-right "#{T:@tmux_lives_status_right}*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment status-right keeps tick"  1 (string match -q '*#{T:@tmux_lives_status_right}#(fish*tick)*' -- "$fragsr"; and echo 1; or echo 0)
t "fragment drops old -ga status-right" 0 (string match -q '*set -ga status-right*' -- "$fragsr"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: fragment sources user config …` etc. (the new wiring isn't there yet; the old `set -ga status-right` still present).

- [ ] **Step 3: Implement**

In `conf.d/tmux-lives-install.fish`, in `__tmux_lives_render_fragment`, add after `set -l invert $argv[5]  # …`:
```fish
    set -l baseline (__tmux_lives_baseline_path)
```
Then replace these two lines:
```fish
    set -a f "if-shell '! tmux show-options -gv status-right 2>/dev/null | grep -q tmux-categorize' \\"
    set -a f "    'set -ga status-right \"#(fish --no-config $cat tick)\"'"
```
with:
```fish
    # Source the user's general config (~/.tmux-lives.conf) if present — applies to every
    # client at load (and is re-sourced on non-ShellFish attach). It sets status-left, the
    # lengths, window-status styles, and overrides the @tmux_lives_status_right time below.
    set -a f "set -g @tmux_lives_status_right \"%-I:%M %p · %b %-d \""
    set -a f "if-shell '[ -f $baseline ]' 'source-file $baseline'"
    # status-right = the time format via #{T:@var} (so strftime applies) + our tick.
    # continuum prepends its autosave hook when TPM runs. The user's file sets only the
    # @var, never status-right, so a re-source can't wipe the tick/continuum.
    set -a f "set -g status-right \"#{T:@tmux_lives_status_right}#(fish --no-config $cat tick)\""
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Live smoke — tmux parses it and the time renders, no pane_title cruft**

Run:
```bash
fish -c '
source conf.d/tmux-lives-install.fish
set -l f /tmp/tli-sbpolish-smoke.conf
__tmux_lives_render_fragment /home/bitsaver/workspace/tmux-lives/functions/tmux-categorize.fish S M-s "" 0 > $f
set -l sk tli-sbpolish
command tmux -L $sk new-session -d 2>/dev/null
command tmux -L $sk source-file $f 2>/tmp/tli-sb.err; echo "source rc=$status"
echo "rendered status-right: ["(command tmux -L $sk display-message -p "#{T;=/60:status-right}")"]"
echo "has pane_title? "(command tmux -L $sk show -gv status-right | string match -q "*pane_title*"; and echo YES; or echo no)
command tmux -L $sk kill-server 2>/dev/null; rm -f $f /tmp/tli-sb.err'
```
Expected: `source rc=0`; the rendered status-right shows an expanded clock (e.g. `7:54 PM · Jun 29`); `has pane_title? no`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(install): source ~/.tmux-lives.conf + status-right via #{T:@var}"
```

---

### Task 3: Seed the general config with active status-bar polish

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — factor `__tmux_lives_baseline_template`; rewrite `__tmux_lives_seed_baseline`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_baseline_template` → prints the default config (status-bar polish + commented non-SF baseline). `__tmux_lives_seed_baseline <f>` → writes it iff `<f>` absent (idempotent).

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, in the baseline block (search for `t "baseline: template is commented"`), replace that assertion and add new ones:
```fish
t "baseline: seeds status-left"     1 (string match -q '*set -g status-left*session_name*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
t "baseline: seeds status-right var" 1 (string match -q '*@tmux_lives_status_right*%-I:%M*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
t "baseline: seeds window-current"  1 (string match -q '*window-status-current-style*bold*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
t "baseline: keeps commented mouse"  1 (string match -q '*# set -g mouse off*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
```
(Leave the existing `baseline: seeded file exists`, `baseline: seed never overwrites`, and `baseline: conf add …` assertions as-is.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: baseline: seeds status-left …` (the seed is still the old commented-only template).

- [ ] **Step 3: Implement**

In `conf.d/tmux-lives-install.fish`, replace `__tmux_lives_seed_baseline` with a template function + an idempotent seeder:
```fish
function __tmux_lives_baseline_template --description 'print the default ~/.tmux-lives.conf (status-bar polish + non-ShellFish baseline)'
    printf '%s\n' \
        '# ~/.tmux-lives.conf — your general tmux-lives config.' \
        '# Sourced when tmux-lives loads (every client) and re-applied when a NON-ShellFish' \
        "# client attaches. Edit freely; 'tmux-lives setup conf reset' restores these defaults." \
        '' \
        '# --- status bar ---' \
        'set -g status-left " ❯ #{session_name} "' \
        'set -g status-left-length 40' \
        'set -g status-right-length 60' \
        '# status-right content goes through this var so tmux-lives keeps the categorize tick' \
        '# + continuum autosave attached (it sets the actual status-right). 12h, month-first:' \
        'set -g @tmux_lives_status_right "%-I:%M %p · %b %-d "' \
        '# make the active window stand out' \
        'set -g window-status-format         " #I:#W "' \
        'set -g window-status-current-format " #I:#W "' \
        'set -g window-status-current-style  "bold"' \
        '' \
        '# --- non-ShellFish baseline (re-applied when a non-ShellFish client attaches) ---' \
        "# Settings ShellFish's integration forces that you want undone for other clients." \
        '# Example:' \
        '# set -g mouse off'
end

function __tmux_lives_seed_baseline --argument-names f --description 'create the baseline file from the template iff absent (never overwrites)'
    test -e $f; and return 0
    __tmux_lives_baseline_template > $f
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Live smoke — tmux sources the seeded file cleanly**

Run:
```bash
fish -c '
source conf.d/tmux-lives-install.fish
set -l f /tmp/tli-seed-smoke.conf; rm -f $f
__tmux_lives_baseline_template > $f
set -l sk tli-seed
command tmux -L $sk new-session -d 2>/dev/null
command tmux -L $sk source-file $f 2>/tmp/tli-seed.err; echo "source rc=$status  err=["(cat /tmp/tli-seed.err)"]"
echo "status-left=["(command tmux -L $sk show -gv status-left)"]  win-current-style=["(command tmux -L $sk show -gv window-status-current-style)"]"
command tmux -L $sk kill-server 2>/dev/null; rm -f $f /tmp/tli-seed.err'
```
Expected: `source rc=0  err=[]`; status-left shows `❯ #{session_name}`; window-status-current-style `bold`.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): seed ~/.tmux-lives.conf with active status-bar polish"
```

---

### Task 4: `setup conf reset` + help row

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_conf_cmd` (add `reset`); `__tmux_lives_setup_help_lines` (conf row)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_baseline_template`, `__tmux_lives_baseline_path` (existing).
- Produces: `tmux-lives setup conf reset` → backs up the file to `<path>.bak` (if it exists), force-writes the template, sources it, rc 0.

- [ ] **Step 1: Write the failing test**

In `tests/test-tmux-install.fish`, in the baseline block (after `t "baseline: conf add with no cmd rc1"`), add:
```fish
printf 'set -g @user_edit 1\n' > $tmux_lives_baseline_conf
__tmux_lives_conf_cmd reset >/dev/null
t "conf reset: backup has user edit" 1 (string match -q '*@user_edit*' -- (cat "$tmux_lives_baseline_conf.bak" | string collect); and echo 1; or echo 0)
t "conf reset: file restored to template" 1 (string match -q '*@tmux_lives_status_right*' -- (cat $tmux_lives_baseline_conf | string collect); and echo 1; or echo 0)
rm -f "$tmux_lives_baseline_conf.bak"
```
Add a help assertion (after the existing conf help assertion):
```fish
t "help conf row shows reset" 1 (string match -q '*conf*reset*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: conf reset: backup has user edit …` (no `reset` case yet; `reset` falls through to the unknown-option error).

- [ ] **Step 3: Implement**

In `__tmux_lives_conf_cmd`, add a `case reset` after the `case add` block (before `case '*'`):
```fish
        case reset
            test -e $f; and cp $f "$f.bak"
            __tmux_lives_baseline_template > $f
            tmux source-file $f 2>/dev/null
            if test -e "$f.bak"
                echo "tmux-lives: restored defaults to $f (previous version saved to $f.bak)"
            else
                echo "tmux-lives: wrote default $f"
            end
```
Update the usage strings in `__tmux_lives_conf_cmd` (the `case '*'` lines) from `… [edit|add <tmux-command>]` to `… [edit|add <tmux-command>|reset]`.

In `__tmux_lives_setup_help_lines`, replace the conf row:
```fish
        'conf [edit|add <cmd>]       edit non-ShellFish baseline (~/.tmux-lives.conf)' \
```
with:
```fish
        'conf [edit|add|reset]       manage ~/.tmux-lives.conf (reset=defaults)' \
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Verify the framed help fits 80 columns**

Run:
```bash
fish -c 'source conf.d/tmux-lives-install.fish; set -l mx 0; for l in (__tmux_lives_setup_help); set -l w (string length --visible -- $l); test $w -gt $mx; and set mx $w; end; echo $mx'
```
Expected: ≤ 80.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): 'setup conf reset' — backup + restore default ~/.tmux-lives.conf"
```

---

### Task 5: Documentation (README + CLAUDE.md)

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Full suite gate**

Run:
```bash
fish -c 'set -l bad 0; for t in tests/test-*.fish; fish $t 2>&1 | string match -q "*FAIL*"; and set bad 1; end; test $bad -eq 0; and echo ALLGREEN; or echo SOMEFAIL'
```
Expected: `ALLGREEN`.

- [ ] **Step 2: Update `README.md`**

In the `### ShellFish tab color & non-ShellFish baseline` subsection, add a short paragraph: `~/.tmux-lives.conf` is now the general tmux-lives config (sourced at load + re-applied on non-ShellFish attach), seeded with status-bar polish (longer names, `❯ session` left, 12h/month-first clock, highlighted current window) — edit it freely; `tmux-lives setup conf reset` restores the defaults (backing up your version to `.bak`). Note the status text auto-tints to the bar color.

- [ ] **Step 3: Update `CLAUDE.md`**

In the status paragraph's ShellFish/`setup color` sentence, document: the status fg is now a hex tint of the bar (`__tmux_lives_derive_status`, f=0.68 toward white/black by luminance); `~/.tmux-lives.conf` is the general config sourced at fragment load (`if-shell '[ -f … ]' 'source-file …'`) + on non-SF attach, seeded with active status-bar polish via `__tmux_lives_baseline_template`; `status-right` is `#{T:@tmux_lives_status_right}#(tick)` (the `T:` makes strftime reach the user-set `@var`; the file never sets status-right, so a re-source can't wipe the tick/continuum); `setup conf reset` backs up + restores defaults.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: status bar polish + general ~/.tmux-lives.conf config file"
```

---

## Self-Review

**Spec coverage:**
- Part A tinted fg → Task 1 (+ verified vectors in constraints). ✓
- Part B source-at-load + `#{T:@var}` status-right + default var → Task 2. ✓
- Part C seeded active polish → Task 3 (`__tmux_lives_baseline_template`). ✓
- Part D `setup conf reset` (backup + restore) + help row → Task 4. ✓
- Docs → Task 5. ✓
- Existing-old-file caveat → covered by `setup conf reset` (Task 4) + docs (Task 5). ✓

**Placeholder scan:** every code step has complete fish; no TBD/TODO. ✓

**Type/name consistency:** `__tmux_lives_baseline_template`, `__tmux_lives_seed_baseline`, `@tmux_lives_status_right`, `#{T:@tmux_lives_status_right}`, and the verified tint vectors are used identically across tasks. ✓

**Live-verify items (post-merge, user-run):** the rendered bar on a real ShellFish/terminal attach (time shows, no pane_title, autosave + categorize still fire); a user with an old commented-only `~/.tmux-lives.conf` runs `setup conf reset` once to pick up the polish.
