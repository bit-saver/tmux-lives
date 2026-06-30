# In-Tmux Command Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux-lives drivable from inside any tmux pane — colored switcher previews, a key-capturing command modal (+ a Claude scratch split), configurable binds, and `setup color` robustness fixes.

**Architecture:** All runtime logic lives in `functions/tmux-categorize.fish` (the existing modal/popup/menu home); bind wiring + config live in the managed fragment rendered by `conf.d/tmux-lives-install.fish`. New behavior is added as small, mostly-pure helpers (`__tcz_*`) that are unit-tested headless, plus thin server-mutating wrappers tested against a throwaway `tmux -L` socket. Zero new files.

**Tech Stack:** fish 4.x, tmux 3.3a, the existing `t`/`vis` test harness in `tests/test-*.fish`.

## Global Constraints

- **Zero new files.** Runtime code → `functions/tmux-categorize.fish`; bind/config → `conf.d/tmux-lives-install.fish`. Tests extend the existing `tests/test-tmux-*.fish`. (one-conf.d-file-per-feature; never add a new `functions/` file.)
- **Test isolation is non-negotiable.** Any code that runs bare `tmux` must, under test, hit a throwaway server — via the PATH `tmux` shim already set up in `tests/test-tmux-categorize.fish` (`$shimdir/tmux` → `exec /usr/bin/tmux -L $sock`) or the `tmux_lives_tmux_socket` seam used in `tests/test-tmux-install.fish`. Tests must NEVER mutate the user's live default-socket server.
- **fish `math` has no comparison operators** (`>`/`<`); use `test`.
- **Suite must stay green with ZERO stderr.** Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'` (wrap fish loops in `fish -c` — the Bash tool's shell mis-parses fish control flow).
- **Assert helper:** every test file defines `function t` with signature `t <desc> <expected> <actual>`. `tests/test-tmux-popup.fish` and `tests/test-tmux-categorize.fish` also define `vis` (strip SGR). Reuse them; do not invent new harness helpers.
- **Do NOT deploy.** Commit + push only; the user runs `fisher update` themselves. Never `cp` into `~/.config/fish`.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Default bind keys** (configurable, persisted as universal vars): modal = `M-m` (`tmux_lives_modal_key`), scratch = `M-t` (`tmux_lives_scratch_key`). Switcher stays `M-s` / prefix `S`.

## File Structure

- `functions/tmux-categorize.fish` — add: `__tcz_strip_sgr`, ANSI-aware `__tcz_popup_truncate`/`__tcz_popup_clip`/`__tcz_popup_preview` (Part A); `__tcz_scratch_pane`/`__tcz_scratch`/`__tcz_scratch_orient` (Part C); `__tcz_modal_legend`/`__tcz_modal_action`/`__tcz_modal_readkey`/`__tcz_modal_run`/`__tcz_modal` (Part B); `__tcz_modal_menu_args`/`__tcz_modal_menu` (Part B fallback); `__tcz_recolor` (Part E); and `scratch`/`modal`/`modal-menu`/`recolor` cases in `__tcz_main`.
- `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` gains modal+scratch binds (args 6/7); `__tmux_lives_write_fragment` resolves+passes the two new keys; `__tmux_lives_keys_cmd` gains `--modal-key`/`--scratch-key`; `__tmux_lives_setup_help_lines` documents them; `__tmux_lives_color_cmd` normalizes bare hex + calls `recolor`.
- Tests: `tests/test-tmux-popup.fish` (Part A + modal pure helpers), `tests/test-tmux-categorize.fish` (scratch, modal run, recolor, menu-args), `tests/test-tmux-install.fish` (fragment binds, keys flags, color normalize).

---

## Task 1: ANSI-aware `__tcz_popup_truncate`

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_truncate` (currently ~`:479`)
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces: `__tcz_popup_truncate <text> <width>` — unchanged signature; now copies SGR escape sequences verbatim (zero display width), never cuts mid-escape, and emits `\e[0m` before the `…` when it truncates a string that contained any SGR.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-popup.fish`, immediately after the existing `__tcz_popup_truncate` test block (the section header near `:35`), add:

```fish
# ANSI-aware: SGR escapes are zero-width, never split, reset before the …
set -g E (printf '\e')
set -g T_FIT "$E[31mhi$E[0m"
t "trunc keeps fitting colored text verbatim" "$T_FIT" (__tcz_popup_truncate "$T_FIT" 10)
set -g T_LONG "$E[31mabcdefghij$E[0m"
set -g T_CUT (__tcz_popup_truncate "$T_LONG" 5)
t "trunc honors visible width (5) ignoring escapes" 5 (string length --visible -- "$T_CUT")
t "trunc resets colour before …" yes (printf '%s' "$T_CUT" | string match -qr '\x1b\[0m…$'; and echo yes; or echo no)
t "trunc leaves no broken escape" "abcd…" (vis "$T_CUT")
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL on the new lines (current truncate counts escape bytes as visible, so width/content are wrong).

- [ ] **Step 3: Replace `__tcz_popup_truncate` with the ANSI-aware version**

```fish
function __tcz_popup_truncate --argument-names text width --description 'truncate text to <width> DISPLAY COLUMNS with trailing … (wide/zero-width AND SGR-aware; never cuts mid-escape; resets colour before the …)'
    test -n "$width"; and test "$width" -gt 0 2>/dev/null; or begin; echo ''; return 0; end
    # Fast path: already fits. `string length --visible` ignores SGR escapes.
    if test (string length --visible -- "$text") -le $width
        echo -- "$text"
        return 0
    end
    set -l ESC (printf '\e')
    set -l BEL (printf '\a')
    set -l budget (math "$width - 1")
    set -l chars (string split '' -- "$text")
    set -l n (count $chars)
    set -l i 1
    set -l acc 0
    set -l out ''
    set -l sawsgr 0
    while test $i -le $n
        set -l ch $chars[$i]
        if test "$ch" = "$ESC"
            # Copy a whole escape sequence verbatim (zero display width). CSI/SGR ends
            # on a final byte in A-Z/a-z; OSC ends on BEL. Never split across the cut.
            set out "$out$ch"; set sawsgr 1; set i (math $i + 1)
            while test $i -le $n
                set -l c2 $chars[$i]
                set out "$out$c2"; set i (math $i + 1)
                if string match -qr '[A-Za-z]' -- "$c2"; or test "$c2" = "$BEL"
                    break
                end
            end
            continue
        end
        set -l cw (string length --visible -- "$ch")
        test (math "$acc + $cw") -gt $budget; and break
        set out "$out$ch"; set acc (math "$acc + $cw"); set i (math $i + 1)
    end
    set -l rst ''
    test $sawsgr -eq 1; and set rst (printf '\e[0m')
    echo -- "$out$rst…"
end
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: PASS (`ALL PASS`). The pre-existing truncate tests (plain text, wide chars) still pass — the fast path and the visible-width budget are unchanged for escape-free input.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(popup): ANSI-aware truncate (zero-width SGR, reset before …)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ANSI-aware `__tcz_popup_clip` + colored `__tcz_popup_preview`

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_strip_sgr`; modify `__tcz_popup_clip` (~`:591`) and `__tcz_popup_preview` (~`:620`)
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Consumes: `__tcz_popup_truncate` (Task 1).
- Produces: `__tcz_strip_sgr <text>` → text with SGR escapes removed. `__tcz_popup_clip` now treats SGR-only lines as blank for the trailing-blank trim and appends a reset to each emitted content line. `__tcz_popup_preview` captures with `capture-pane -e -p` (colored).

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-popup.fish`, just after the existing `__tcz_popup_clip` / preview tests (around `:127`), add:

```fish
# clip: an SGR-only trailing line counts as blank, so real content is bottom-anchored
set -g CBE (printf 'real\n%s[0m\n' $E | __tcz_popup_clip 10 2)
t "clip treats SGR-only line as blank"  real (vis "$CBE[2]")
# clip: each content line ends with a reset so colour can't bleed into the divider
set -g CRS (printf '%s[31mhot\n' $E | __tcz_popup_clip 10 1)
t "clip line ends with reset"  yes (printf '%s' "$CRS[1]" | string match -qr '\x1b\[0m$'; and echo yes; or echo no)
# preview now captures WITH escapes
set -g PVE (functions __tcz_popup_preview | string collect)
t "preview uses capture-pane -e"  yes (string match -q '*capture-pane -e*' -- "$PVE"; and echo yes; or echo no)
t "preview still pipes through clip"  yes (string match -q '*__tcz_popup_clip*' -- "$PVE"; and echo yes; or echo no)
# strip helper
t "strip_sgr removes colour"  abc (__tcz_strip_sgr "$E[31mabc$E[0m")
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_strip_sgr` undefined; preview still uses plain `capture-pane -p`; clip emits no reset.

- [ ] **Step 3a: Add `__tcz_strip_sgr`**

Add immediately before `__tcz_popup_clip`:

```fish
function __tcz_strip_sgr --description 'strip ANSI SGR (colour) escapes from argv[1]'
    string replace -ra '\x1b\[[0-9;]*m' '' -- "$argv[1]"
end
```

- [ ] **Step 3b: Make `__tcz_popup_clip` SGR-aware**

In `__tcz_popup_clip`, change the trailing-blank trim to strip SGR first, and append a reset to each emitted content line. Replace the blank-trim `while` condition and the final emit loop:

```fish
    # drop trailing blank (whitespace-only, ignoring colour) lines so the last kept line is real
    while test (count $lines) -gt 0; and test -z (string trim -- (__tcz_strip_sgr "$lines[-1]"))
        set -e lines[-1]
    end
```

and the final loop:

```fish
    set -l RST (printf '\e[0m')
    for l in $lines
        printf '%s%s\n' (__tcz_popup_truncate "$l" $w) $RST
    end
```

(The top blank-padding loop — `echo ''` rows — is unchanged; blank rows carry no colour.)

- [ ] **Step 3c: Make `__tcz_popup_preview` colored**

```fish
function __tcz_popup_preview --argument-names session w h --description 'colored capture-pane (-e) of session active pane, clipped to w×h'
    test -n "$session"; or return 0
    tmux capture-pane -e -p -t "$session" 2>/dev/null | __tcz_popup_clip $w $h
end
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: PASS. The pre-existing clip tests (`clip top row blank when short`, `clip truncates to w columns`, `preview has no '=' target`) still pass — padding rows stay blank and visible-width is unchanged.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(popup): colored switcher preview (capture-pane -e + SGR-aware clip)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Scratch split (toggle, orientation, dispatch)

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_scratch_pane`, `__tcz_scratch`, `__tcz_scratch_orient`; add `scratch` to `__tcz_main`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces:
  - `__tcz_scratch_pane` → echoes the marked scratch pane id in the current window (empty if none).
  - `__tcz_scratch [client]` → toggle: create+mark+focus a side-by-side shell, or refocus origin + kill the marked pane.
  - `__tcz_scratch_orient <h|w>` → recreate the scratch with a new orientation (`h` side-by-side, `w` stacked).
  - `__tcz_main` dispatches `scratch` → `__tcz_scratch $argv[2..]`.
- Marking: pane option `@tmux_lives_scratch 1`; origin recorded in window option `@tmux_lives_scratch_origin`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-categorize.fish`, near the end (before the final `cleanup` / `ALL PASS` lines), add. These rely on the file's PATH `tmux` shim, so bare `tmux` inside `__tcz_scratch` hits `-L $sock`:

```fish
# ---------------------------------------------------------------------
# scratch split toggle (uses the PATH tmux shim -> isolated -L $sock)
# ---------------------------------------------------------------------
command tmux -L $sock new-session -d -x 120 -y 40
__tcz_scratch
t "scratch create -> one marked pane" 1 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
t "scratch_pane echoes a pane id" yes (string match -qr '^%' -- (__tcz_scratch_pane); and echo yes; or echo no)
t "scratch create -> marked pane is active" 1 (command tmux -L $sock list-panes -F '#{?#{&&:#{pane_active},#{==:#{@tmux_lives_scratch},1}},1,}' | grep -c '^1$')
__tcz_scratch
t "scratch remove -> no marked panes" 0 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
t "scratch remove -> back to one pane" 1 (command tmux -L $sock list-panes | wc -l | string trim)
# orientation: recreate stacked, still exactly one marked pane
__tcz_scratch
__tcz_scratch_orient w
t "scratch_orient keeps one marked pane" 1 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
command tmux -L $sock kill-server 2>/dev/null
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_scratch*` undefined.

- [ ] **Step 3: Implement the scratch helpers**

Add before `__tcz_main` in `functions/tmux-categorize.fish`:

```fish
function __tcz_scratch_pane --description 'echo the marked scratch pane id in the current window (empty if none)'
    tmux list-panes -F '#{?#{==:#{@tmux_lives_scratch},1},#{pane_id},}' 2>/dev/null | string match -rv '^$'
end

function __tcz_scratch --description 'toggle a marked scratch shell pane beside the active pane (create+focus, or refocus origin + kill)'
    set -l existing (__tcz_scratch_pane)
    if test -n "$existing[1]"
        set -l origin (tmux show-options -wqv @tmux_lives_scratch_origin 2>/dev/null)
        test -n "$origin"; and tmux select-pane -t "$origin" 2>/dev/null
        tmux kill-pane -t "$existing[1]" 2>/dev/null
        tmux set-window-option -qu @tmux_lives_scratch_origin 2>/dev/null
        return 0
    end
    set -l origin (tmux list-panes -F '#{?#{pane_active},#{pane_id},}' 2>/dev/null | string match -rv '^$')
    test -n "$origin[1]"; and tmux set-window-option @tmux_lives_scratch_origin "$origin[1]" 2>/dev/null
    tmux split-window -h -p 33 2>/dev/null
    tmux set -p @tmux_lives_scratch 1 2>/dev/null
    return 0
end

function __tcz_scratch_orient --argument-names dir --description 'recreate the scratch pane with a new orientation (h=side-by-side, w=stacked)'
    set -l p (__tcz_scratch_pane)
    test -n "$p[1]"; or return 0
    set -l flag -h; test "$dir" = w; and set flag -v
    tmux kill-pane -t "$p[1]" 2>/dev/null
    tmux split-window $flag -p 33 2>/dev/null
    tmux set -p @tmux_lives_scratch 1 2>/dev/null
    return 0
end
```

Add the dispatch case to `__tcz_main` (after the `popup` case):

```fish
        case scratch
            __tcz_scratch $argv[2..]
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(scratch): toggle a marked scratch shell pane beside the active pane

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Modal pure helpers (legend, action map, key reader)

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_modal_legend`, `__tcz_modal_action`, `__tcz_modal_readkey`
- Test: `tests/test-tmux-popup.fish` (pure-helper home; sources the script with `tmux_categorize_test`)

**Interfaces:**
- Produces:
  - `__tcz_modal_legend <has_scratch>` → ANSI legend lines; the scratch-management row appears only when `has_scratch` = 1.
  - `__tcz_modal_action <keyname> <has_scratch>` → action token: `new clear categorize switcher scratch color close scratch-close orient-h orient-w resize-left resize-right resize-up resize-down noop`.
  - `__tcz_modal_readkey` (reads one keystroke from stdin) → keyname: `n c g s t b h w x q enter up down left right esc other close`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-popup.fish`, before the final `test $FAIL -eq 0` line, add:

```fish
# ---------------------------------------------------------------------
# command modal — pure helpers
# ---------------------------------------------------------------------
function flat --description 'collapse a fish list (multiline) to one SGR-stripped space-joined string'
    set -l s (string join ' ' $argv)
    string replace -a (printf '\n') ' ' -- (vis "$s")
end
set -g LEG0 (flat (__tcz_modal_legend 0))
t "legend has new/clear/categorize" yes (string match -q '*new*clear*categorize*' -- "$LEG0"; and echo yes; or echo no)
t "legend has switcher/scratch/bar color" yes (string match -q '*switcher*scratch*bar color*' -- "$LEG0"; and echo yes; or echo no)
t "legend(0) hides resize row" no (string match -q '*resize*' -- "$LEG0"; and echo yes; or echo no)
set -g LEG1 (flat (__tcz_modal_legend 1))
t "legend(1) shows resize row" yes (string match -q '*resize*split*close*' -- "$LEG1"; and echo yes; or echo no)

t "action n -> new" new (__tcz_modal_action n 0)
t "action c -> clear" clear (__tcz_modal_action c 0)
t "action g -> categorize" categorize (__tcz_modal_action g 0)
t "action s -> switcher" switcher (__tcz_modal_action s 0)
t "action t -> scratch" scratch (__tcz_modal_action t 0)
t "action b -> color" color (__tcz_modal_action b 0)
t "action esc -> close" close (__tcz_modal_action esc 0)
t "action q -> close" close (__tcz_modal_action q 0)
t "action x no-scratch -> noop" noop (__tcz_modal_action x 0)
t "action x with-scratch -> scratch-close" scratch-close (__tcz_modal_action x 1)
t "action left with-scratch -> resize-left" resize-left (__tcz_modal_action left 1)
t "action h with-scratch -> orient-h" orient-h (__tcz_modal_action h 1)
t "action unknown -> noop" noop (__tcz_modal_action z 0)

t "readkey n" n (printf 'n' | __tcz_modal_readkey 2>/dev/null)
t "readkey x" x (printf 'x' | __tcz_modal_readkey 2>/dev/null)
t "readkey enter" enter (printf '\r' | __tcz_modal_readkey 2>/dev/null)
t "readkey CSI up" up (printf '\e[A' | __tcz_modal_readkey 2>/dev/null)
t "readkey CSI left" left (printf '\e[D' | __tcz_modal_readkey 2>/dev/null)
t "readkey bare esc" esc (printf '\e' | __tcz_modal_readkey 2>/dev/null)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — the three `__tcz_modal_*` helpers are undefined.

- [ ] **Step 3: Implement the pure helpers**

Add to `functions/tmux-categorize.fish` (e.g. just before `__tcz_popup`):

```fish
function __tcz_modal_legend --argument-names has_scratch --description 'pure: the command-modal key legend (ANSI); scratch-management row only when a scratch exists'
    set -l O (printf '\e[38;5;208m')   # orange key accent
    set -l D (printf '\e[2m')          # dim
    set -l R (printf '\e[0m')
    set -l rows
    set -a rows "$O n$R new   $O c$R clear   $O g$R categorize"
    set -a rows "$O s$R switcher   $O t$R scratch   $O b$R bar color"
    test "$has_scratch" = 1; and set -a rows "$D scratch:$R $O ←→↑↓$R resize  $O h/w$R split  $O x$R close"
    set -a rows "$O esc$R close"
    printf '%s\n' $rows
end

function __tcz_modal_action --argument-names key has_scratch --description 'pure: modal keyname + scratch-state -> action token'
    switch "$key"
        case n; echo new
        case c; echo clear
        case g; echo categorize
        case s; echo switcher
        case t; echo scratch
        case b; echo color
        case esc q; echo close
        case x;     test "$has_scratch" = 1; and echo scratch-close; or echo noop
        case h;     test "$has_scratch" = 1; and echo orient-h; or echo noop
        case w;     test "$has_scratch" = 1; and echo orient-w; or echo noop
        case left;  test "$has_scratch" = 1; and echo resize-left; or echo noop
        case right; test "$has_scratch" = 1; and echo resize-right; or echo noop
        case up;    test "$has_scratch" = 1; and echo resize-up; or echo noop
        case down;  test "$has_scratch" = 1; and echo resize-down; or echo noop
        case '*';   echo noop
    end
end

function __tcz_modal_readkey --description 'read one keystroke -> keyname (letters as tokens; arrows/enter/esc parsed)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo close; return; end          # EOF
    switch "$b"
        case 0d 0a; echo enter; return
        case 6e; echo n; return
        case 63; echo c; return
        case 67; echo g; return
        case 73; echo s; return
        case 74; echo t; return
        case 62; echo b; return
        case 68; echo h; return
        case 77; echo w; return
        case 78; echo x; return
        case 71; echo q; return
    end
    if test "$b" = 1b                                          # ESC
        stty min 0 time 1 2>/dev/null
        set -l b2 ''
        dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b2
        set -l b3 ''
        if test "$b2" = 5b; or test "$b2" = 4f                 # [ or O
            dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b3
        end
        stty min 1 time 0 2>/dev/null
        if test "$b2" = 5b; or test "$b2" = 4f
            switch "$b3"
                case 41; echo up; return
                case 42; echo down; return
                case 43; echo right; return
                case 44; echo left; return
            end
            echo other; return
        end
        echo esc; return
    end
    echo other
end
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(modal): pure legend + key->action map + key reader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Modal action runner + interactive loop + dispatch

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_modal_run`, `__tcz_modal`; add `modal` to `__tcz_main`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_scratch`, `__tcz_scratch_pane`, `__tcz_scratch_orient` (Task 3); `__tcz_open_switcher`, `__tcz_categorize` (existing); `__tcz_modal_legend`/`__tcz_modal_action`/`__tcz_modal_readkey` (Task 4).
- Produces:
  - `__tcz_modal_run <action> <client>` → performs the action; echoes `close` to exit the modal or `stay` to keep it open (and echoes `color` unchanged so the loop can run its input sub-state).
  - `__tcz_modal [client]` → the interactive `display-popup` loop.
  - `__tcz_main` dispatches `modal` → `__tcz_modal $argv[2..]`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-categorize.fish`, after the scratch tests added in Task 3, add. (`__tcz_modal_run` for `scratch`/`categorize` is server-affecting via the shim; the CLI-shelled actions return tokens.)

```fish
# ---------------------------------------------------------------------
# modal action runner
# ---------------------------------------------------------------------
command tmux -L $sock new-session -d -x 120 -y 40
t "run scratch -> stay" stay (__tcz_modal_run scratch '' | string collect)
t "run scratch created a marked pane" 1 (command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
t "run categorize -> stay" stay (__tcz_modal_run categorize '' | string collect)
t "run close -> close" close (__tcz_modal_run close '' | string collect)
t "run color -> color (loop handles input)" color (__tcz_modal_run color '' | string collect)
t "run noop -> stay" stay (__tcz_modal_run noop '' | string collect)
command tmux -L $sock kill-server 2>/dev/null
# loop wiring (source assertions — the interactive loop is not run headless)
set -g MSRC (functions __tcz_modal | string collect)
t "modal loop reads keys" yes (string match -q '*__tcz_modal_readkey*' -- "$MSRC"; and echo yes; or echo no)
t "modal loop maps actions" yes (string match -q '*__tcz_modal_action*' -- "$MSRC"; and echo yes; or echo no)
t "modal loop draws legend" yes (string match -q '*__tcz_modal_legend*' -- "$MSRC"; and echo yes; or echo no)
t "modal loop runs actions" yes (string match -q '*__tcz_modal_run*' -- "$MSRC"; and echo yes; or echo no)
t "modal loop has colour input sub-state" yes (string match -q '*tmux-lives setup color*' -- "$MSRC"; and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_modal_run` / `__tcz_modal` undefined.

- [ ] **Step 3: Implement the runner and loop**

Add to `functions/tmux-categorize.fish` (after the Task 4 helpers):

```fish
function __tcz_modal_run --argument-names action client --description 'run a modal action token; echo close|stay (color is returned for the loop input sub-state)'
    switch "$action"
        case new
            fish -c 'tmux-lives new' 2>/dev/null; echo close
        case clear
            fish -c 'tmux-lives clear' 2>/dev/null; echo stay
        case categorize
            __tcz_categorize >/dev/null 2>&1; echo stay
        case switcher
            __tcz_open_switcher "$client"; echo close
        case scratch scratch-close
            __tcz_scratch "$client"; echo stay
        case orient-h
            __tcz_scratch_orient h; echo stay
        case orient-w
            __tcz_scratch_orient w; echo stay
        case resize-left
            tmux resize-pane -t (__tcz_scratch_pane)[1] -L 4 2>/dev/null; echo stay
        case resize-right
            tmux resize-pane -t (__tcz_scratch_pane)[1] -R 4 2>/dev/null; echo stay
        case resize-up
            tmux resize-pane -t (__tcz_scratch_pane)[1] -U 2 2>/dev/null; echo stay
        case resize-down
            tmux resize-pane -t (__tcz_scratch_pane)[1] -D 2 2>/dev/null; echo stay
        case color
            echo color
        case close
            echo close
        case '*'
            echo stay
    end
end

function __tcz_modal --argument-names client --description 'key-capturing command modal (runs inside display-popup)'
    if test -z "$client"; or string match -q '*#{*' -- "$client"
        set client (tmux display-message -p '#{client_name}' 2>/dev/null)
    end
    set -l saved (stty -g)
    set -g __tcz_modal_saved $saved
    function __tcz_modal_cleanup --on-signal INT --on-signal TERM
        stty "$__tcz_modal_saved" 2>/dev/null
        printf '\e[?25h\e[0m'
        exit 130
    end
    stty -icanon -echo min 1 time 0
    printf '\e[?25l'
    while true
        set -l sp (__tcz_scratch_pane)
        set -l has 0; test -n "$sp[1]"; and set has 1
        printf '\e[2J\e[H'
        __tcz_modal_legend $has
        set -l action (__tcz_modal_action (__tcz_modal_readkey) $has)
        set -l verdict (__tcz_modal_run $action "$client")
        if test "$verdict" = color
            stty "$saved" 2>/dev/null
            printf '\e[2J\e[H bar color (css), empty cancels: '
            set -l val ''
            read -l val
            stty -icanon -echo min 1 time 0 2>/dev/null
            test -n "$val"; and fish -c 'tmux-lives setup color $argv[1]' "$val" 2>/dev/null
        else if test "$verdict" = close
            break
        end
    end
    functions -e __tcz_modal_cleanup
    set -e __tcz_modal_saved
    stty $saved
    printf '\e[?25h\e[2J\e[H'
    return 0
end
```

Add the dispatch case to `__tcz_main` (after `scratch`):

```fish
        case modal
            __tcz_modal $argv[2..]
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(modal): action runner + display-popup loop with colour input sub-state

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: display-menu fallback for the modal

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_modal_menu_args`, `__tcz_modal_menu`; add `modal-menu` to `__tcz_main`
- Test: `tests/test-tmux-popup.fish` (pure builder) + `tests/test-tmux-categorize.fish` (dispatch)

**Interfaces:**
- Produces:
  - `__tcz_modal_menu_args` → display-menu triples (label / key / command) for the command actions, one per line.
  - `__tcz_modal_menu [client]` → `tmux display-menu` of those actions.
  - `__tcz_main` dispatches `modal-menu` → `__tcz_modal_menu $argv[2..]`.

- [ ] **Step 1: Write the failing test (pure builder)**

In `tests/test-tmux-popup.fish`, after the Task 4 modal tests, add:

```fish
# modal display-menu fallback: builder emits label/key/command triples
set -g MM (__tcz_modal_menu_args | string collect)
t "menu-args lists new" yes (string match -q '*new session*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists scratch" yes (string match -q '*scratch*' -- "$MM"; and echo yes; or echo no)
t "menu-args lists bar color" yes (string match -q '*bar color*' -- "$MM"; and echo yes; or echo no)
t "menu-args binds key n to new" yes (printf '%s' "$MM" | string match -qr 'new session\nn\n'; and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `__tcz_modal_menu_args` undefined.

- [ ] **Step 3: Implement the builder + menu + dispatch**

Add to `functions/tmux-categorize.fish` (near `__tcz_menu`):

```fish
function __tcz_modal_menu_args --description 'display-menu triples (label/key/command) for the command-modal fallback'
    # Each action is a label, a shortcut key, and a tmux command. CLI verbs run via
    # `fish -c`; categorizer-native verbs re-enter this script ($__tcz_self).
    printf '%s\n' \
        'new session'    n "run-shell 'fish -c \"tmux-lives new\"'" \
        'clear idle'     c "run-shell 'fish -c \"tmux-lives clear\"'" \
        'categorize'     g "run-shell 'fish --no-config $__tcz_self tick'" \
        'switcher'       s "run-shell 'fish --no-config $__tcz_self open-switcher'" \
        'scratch toggle' t "run-shell 'fish --no-config $__tcz_self scratch'" \
        'bar color'      b "command-prompt -p 'bar color (css):' 'run-shell \"fish -c \\\"tmux-lives setup color %%\\\"\"'"
end

function __tcz_modal_menu --argument-names client --description 'display-menu fallback for the command modal (no display-popup)'
    set -l args
    __tcz_modal_menu_args | while read -l a
        set -a args "$a"
    end
    test (count $args) -gt 0; or return 0
    tmux display-menu -T ' tmux-lives ' -- $args
end
```

Add the dispatch case to `__tcz_main` (after `modal`):

```fish
        case modal-menu
            __tcz_modal_menu $argv[2..]
```

- [ ] **Step 4a: Add a dispatch smoke test**

In `tests/test-tmux-categorize.fish`, after the modal-run tests, add (asserts the subcommand routes; display-menu needs a client so we only check the dispatch table doesn't error out for an unknown verb):

```fish
set -g MAINSRC (functions __tcz_main | string collect)
t "main dispatches modal" yes (string match -q '*case modal*' -- "$MAINSRC"; and echo yes; or echo no)
t "main dispatches modal-menu" yes (string match -q '*modal-menu*' -- "$MAINSRC"; and echo yes; or echo no)
t "main dispatches scratch" yes (string match -q '*case scratch*' -- "$MAINSRC"; and echo yes; or echo no)
```

- [ ] **Step 4b: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish` then `fish tests/test-tmux-categorize.fish`
Expected: PASS for both.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish tests/test-tmux-categorize.fish
git commit -m "feat(modal): display-menu fallback for no-display-popup terminals

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Fragment binds + `setup keys --modal-key/--scratch-key`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (args 6/7 + bind emission), `__tmux_lives_write_fragment` (resolve+pass keys), `__tmux_lives_keys_cmd` (new flags), `__tmux_lives_setup_help_lines` (doc)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: the `modal` / `modal-menu` / `scratch` categorizer verbs (Tasks 5–6).
- Produces: `__tmux_lives_render_fragment <cat> <pkey> <skey> <color> <invert> <modalkey> <scratchkey>` — two trailing args added; renders a root-table scratch bind (always when set) and a modal bind inside the existing display-popup/menu `if-shell` branch. `setup keys` accepts `--modal-key K` / `--scratch-key K` (universals `tmux_lives_modal_key` / `tmux_lives_scratch_key`).

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, where fragment-render assertions live, add a block that renders with explicit modal/scratch keys and asserts the binds. Use `string collect` to scan the whole fragment:

```fish
set -g FRAG (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t | string collect)
t "fragment binds modal key (popup)" yes (string match -q '*bind-key -n M-m display-popup*cat.fish modal*' -- "$FRAG"; and echo yes; or echo no)
t "fragment binds modal key (menu fallback)" yes (string match -q '*bind-key -n M-m run-shell*modal-menu*' -- "$FRAG"; and echo yes; or echo no)
t "fragment binds scratch key" yes (string match -q '*bind-key -n M-t run-shell*cat.fish scratch*' -- "$FRAG"; and echo yes; or echo no)
# empty modal/scratch keys -> no such binds
set -g FRAG2 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 '' '' | string collect)
t "no modal bind when key empty" no (string match -q '*cat.fish modal*' -- "$FRAG2"; and echo yes; or echo no)
t "no scratch bind when key empty" no (string match -q '*cat.fish scratch*' -- "$FRAG2"; and echo yes; or echo no)
# setup keys flags persist universals
set -e tmux_lives_modal_key; set -e tmux_lives_scratch_key
functions -c __tmux_lives_write_fragment __wf_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --modal-key M-m --scratch-key M-t
t "keys --modal-key persists" M-m "$tmux_lives_modal_key"
t "keys --scratch-key persists" M-t "$tmux_lives_scratch_key"
functions -e __tmux_lives_write_fragment; functions -c __wf_bak __tmux_lives_write_fragment; functions -e __wf_bak
set -e tmux_lives_modal_key; set -e tmux_lives_scratch_key
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — render emits no modal/scratch binds; `--modal-key` is an unknown option.

- [ ] **Step 3a: Extend `__tmux_lives_render_fragment`**

Add args 6/7 near the top (after `set -l invert $argv[5]`):

```fish
    set -l modalkey $argv[6]   # root-table modal key ('' = no bind)
    set -l scratchkey $argv[7] # root-table scratch-toggle key ('' = no bind)
```

Add the modal bind to the existing `$popup`/`$menu` lists (right after the switcher `if test -n "$skey"` block, before `set -l f`):

```fish
    if test -n "$modalkey"
        set -a popup "    bind-key -n $modalkey display-popup -E -w 64% -h 45% -- fish --no-config $cat modal '#{client_name}'"
        set -a menu  "    bind-key -n $modalkey run-shell 'fish --no-config $cat modal-menu'"
    end
```

Add the always-on scratch bind right after the popup/menu `if-shell` block (after its closing `end`, near `:57`):

```fish
    test -n "$scratchkey"; and set -a f "bind-key -n $scratchkey run-shell 'fish --no-config $cat scratch'"
```

- [ ] **Step 3b: Pass the new keys from `__tmux_lives_write_fragment`**

Replace the `__tmux_lives_render_fragment` call (`:131`) so it resolves and forwards the two new keys:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) (__tmux_lives_key tmux_lives_modal_key M-m) (__tmux_lives_key tmux_lives_scratch_key M-t) > $fragment
```

- [ ] **Step 3c: Extend `__tmux_lives_keys_cmd`**

Add two `case` arms inside the `while` switch (alongside `-p`/`-s`):

```fish
            case --modal-key
                set -U tmux_lives_modal_key $argv[2]; set changed 1; set -e argv[1..2]
            case --scratch-key
                set -U tmux_lives_scratch_key $argv[2]; set changed 1; set -e argv[1..2]
```

- [ ] **Step 3d: Document the flags**

In `__tmux_lives_setup_help_lines`, add two lines under the `keys` entries:

```fish
        "      --modal-key <key>     in-tmux command modal (default: M-m; '' off)" \
        "      --scratch-key <key>   Claude scratch-split toggle (default: M-t; '' off)" \
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS. Pre-existing render tests still pass — they call `__tmux_lives_render_fragment` with 5 args, so `$argv[6]`/`$argv[7]` are empty and no new binds appear.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): wire modal + scratch binds; setup keys --modal-key/--scratch-key

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `__tcz_recolor` — immediate ShellFish re-emit

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_recolor`; add `recolor` to `__tcz_main`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_client_is_shellfish`, `__tcz_emit_barcolor`, the `tmux_lives_fake_environ` seam (all existing).
- Produces: `__tcz_recolor <color>` → for every attached client (`tmux list-clients`), emit the ShellFish bar-color OSC to ShellFish clients' ttys. `__tcz_main` dispatches `recolor` → `__tcz_recolor $argv[2..]`.

- [ ] **Step 1: Write the failing test**

In `tests/test-tmux-categorize.fish`, after the modal tests, add. We stub `tmux list-clients` (via a fish `tmux` function that passes everything else through to the shim) and point the "tty" at temp files:

```fish
# ---------------------------------------------------------------------
# recolor: emit the ShellFish OSC to attached ShellFish clients
# ---------------------------------------------------------------------
set -g tt1 /tmp/tcz-tty1-$fish_pid; set -g tt2 /tmp/tcz-tty2-$fish_pid
rm -f $tt1 $tt2; touch $tt1 $tt2
function tmux
    if test "$argv[1]" = list-clients
        printf '%s\n' "111 $tt1" "222 $tt2"
    else
        command tmux $argv
    end
end
set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_recolor '#1f6feb'
t "recolor emits OSC to shellfish client 1" yes (test -s $tt1; and echo yes; or echo no)
t "recolor emits OSC to shellfish client 2" yes (test -s $tt2; and echo yes; or echo no)
t "recolor OSC carries settoolbar" yes (string match -q '*settoolbar*' -- (cat $tt1 | string collect); and echo yes; or echo no)
# non-shellfish env -> no emit
rm -f $tt1; touch $tt1
set -gx tmux_lives_fake_environ "TERM=xterm"
__tcz_recolor '#1f6feb'
t "recolor skips non-shellfish client" no (test -s $tt1; and echo yes; or echo no)
set -e tmux_lives_fake_environ
functions -e tmux
rm -f $tt1 $tt2
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_recolor` undefined.

- [ ] **Step 3: Implement `__tcz_recolor`**

Add near `__tcz_on_attach` in `functions/tmux-categorize.fish`:

```fish
function __tcz_recolor --argument-names color --description 'emit the ShellFish bar-color OSC to every attached ShellFish client (so setup color updates tabs without a reattach)'
    test -n "$color"; or return 0
    set -l TAB (printf '\t')
    for line in (tmux list-clients -F "#{client_pid}$TAB#{client_tty}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        set -l pid $parts[1]
        set -l tty $parts[2]
        test -n "$tty"; or continue
        __tcz_client_is_shellfish $pid; and __tcz_emit_barcolor $tty $color
    end
end
```

Add the dispatch case to `__tcz_main` (after `modal-menu`):

```fish
        case recolor
            __tcz_recolor $argv[2..]
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(color): recolor — emit ShellFish OSC to attached clients on demand

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `setup color` — bare-hex normalize + call `recolor`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_color_cmd`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tcz_recolor` (Task 8), the `tmux_categorize_script` path the rest of the file uses to reach the categorizer (`$__fish_config_dir/functions/tmux-categorize.fish`).
- Produces: `__tmux_lives_color_cmd` now (a) prepends `#` to a bare 3/6-digit hex before storing, and (b) after `__tmux_lives_write_fragment`, invokes `recolor` so attached ShellFish tabs update immediately.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, near the existing color-command tests, add. Stub `__tmux_lives_write_fragment` (no real tmux) and assert the stored universal:

```fish
# Isolate: stub the fragment writer (no real tmux) and point __fish_config_dir at a
# nonexistent dir so the recolor shell-out's `test -f $cat` guard short-circuits.
set -g __old_fcd $__fish_config_dir
set -g __fish_config_dir /tmp/tcz-nofish-$fish_pid
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
functions -c __tmux_lives_write_fragment __wf2_bak
function __tmux_lives_write_fragment; end
__tmux_lives_color_cmd 1f6feb >/dev/null
t "bare 6-hex normalized to #1f6feb" "#1f6feb" "$tmux_lives_bar_color"
t "normalized hex yields non-empty status-style" yes (test -n (__tmux_lives_derive_status "$tmux_lives_bar_color" 0); and echo yes; or echo no)
__tmux_lives_color_cmd abc >/dev/null
t "bare 3-hex normalized to #abc" "#abc" "$tmux_lives_bar_color"
__tmux_lives_color_cmd "#deadbe" >/dev/null
t "already-hashed hex untouched" "#deadbe" "$tmux_lives_bar_color"
__tmux_lives_color_cmd red >/dev/null
t "named colour untouched" red "$tmux_lives_bar_color"
functions -e __tmux_lives_write_fragment; functions -c __wf2_bak __tmux_lives_write_fragment; functions -e __wf2_bak
set -g __fish_config_dir $__old_fcd; set -e __old_fcd
set -e tmux_lives_bar_color; set -e tmux_lives_status_invert
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `1f6feb` is stored verbatim (no `#`), so the first two assertions fail.

- [ ] **Step 3: Add normalization + recolor call to `__tmux_lives_color_cmd`**

After the charset-validation block (`:379-382`) and before `set -U tmux_lives_bar_color $color`, insert:

```fish
    # Normalize a bare 3/6-digit hex to #rrggbb so __tmux_lives_derive_status (which
    # requires the leading #) can parse it; named colours / rgb()/color() are left alone.
    if string match -qr '^[0-9A-Fa-f]{3}$' -- $color; or string match -qr '^[0-9A-Fa-f]{6}$' -- $color
        set color "#$color"
    end
```

Then, after `__tmux_lives_write_fragment` (`:385`), add the immediate re-emit:

```fish
    # Re-emit the ShellFish OSC to attached clients now, so their tab colour updates
    # without waiting for the next client-attached. The emit logic lives in the categorizer.
    set -l cat "$__fish_config_dir/functions/tmux-categorize.fish"
    test -f $cat; and fish --no-config $cat recolor $color 2>/dev/null
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS. The Step 1 `__fish_config_dir` override makes the `recolor` shell-out's `test -f $cat` guard short-circuit, so the install suite stays hermetic (no live tmux, no real categorizer) — and it is restored afterward.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(color): normalize bare hex + re-emit ShellFish OSC on setup color

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after Task 9)

- [ ] **Run the full suite, confirm green + zero stderr**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: every suite prints `ALL PASS` (or `ALL PASS (N)`), no `FAIL`, and no stderr noise.

- [ ] **Confirm no live-server drift**

Run: `tmux list-sessions 2>/dev/null | wc -l` before and after the suite — the count must be unchanged (the suite only touches `-L` sockets / shims).

- [ ] **Update docs (CLAUDE.md + README + vault) for the new in-tmux surface**, then a final commit. (CLAUDE.md: the modal/scratch/colored-preview surface, the `M-m`/`M-t` defaults, the `setup keys --modal-key/--scratch-key` flags, and the `setup color` re-emit/normalize. README: the in-tmux keys. Re-run `vault-publish` for the README if changed.)

---

## Runtime pre-flight (validate live during/after implementation — not unit-testable)

These need a real interactive tmux + ShellFish and are confirmed by the user, not the suite:

- **Live resize under popup:** with the modal open, do the panes redraw as `resize-pane` fires? If tmux 3.3a doesn't redraw under a popup, resize still applies (visible on modal close) — acceptable, but note it.
- **Cooked line read in popup:** the colour input sub-state (`raw → stty saved → read → raw`) reads a full line correctly inside `display-popup -E`.
- **ShellFish re-emit end-to-end:** `tmux-lives setup color "#87af00"` updates an already-attached ShellFish tab immediately (the bug the user hit).
- **Key collisions:** `M-m` / `M-t` don't collide with the user's terminal/tmux binds; if they do, `setup keys --modal-key/--scratch-key` rebinds.

---

## Self-Review

**Spec coverage:**
- Part A (colored preview) → Tasks 1–2. ✓
- Part B (modal: render/keys/dispatch/input sub-state/fallback) → Tasks 4–6. ✓
- Part C (scratch toggle + management) → Task 3 (+ resize/orient wired in Task 5). ✓
- Part D (`setup keys` config + fragment binds) → Task 7. ✓
- Part E (recolor + bare-hex normalize) → Tasks 8–9. ✓
- Testing/isolation constraint → every server-mutating task uses the PATH shim / `-L` socket / stubs; Final-verification step asserts no live drift. ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete fish. The only deferred items are the runtime pre-flight checks, which are inherently interactive and explicitly called out as user-validated, not skipped tests.

**Type/name consistency:** action tokens emitted by `__tcz_modal_action` (Task 4) exactly match the `switch` arms consumed by `__tcz_modal_run` (Task 5): `new clear categorize switcher scratch color close scratch-close orient-h orient-w resize-left resize-right resize-up resize-down noop`. `__tcz_scratch_pane` / `__tcz_scratch` / `__tcz_scratch_orient` (Task 3) are the exact names called in Task 5. `__tcz_recolor` (Task 8) is the verb the `recolor` shell-out in Task 9 invokes. Fragment arg order `cat pkey skey color invert modalkey scratchkey` (Task 7) matches `__tmux_lives_write_fragment`'s call.
