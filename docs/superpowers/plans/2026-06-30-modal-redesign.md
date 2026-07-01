# In-Tmux Modal Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the looping in-popup command modal with a single-shot launcher (pick → close → run visibly) plus a native `M-r` key-table scratch-resize mode, redesign the legend (design B + keybind table), and rename "switcher" → "picker".

**Architecture:** The `M-m` launcher stays a fish `display-popup` but becomes single-shot — draw the legend once, read one key, dispatch, exit. Actions that need the screen back (picker, session changes) run *after* the popup closes (`run-shell -b` deferral / plain exit), so tmux never has to nest popups. Live scratch resizing moves to a native tmux key-table (`tmuxlives-resize`) entered by `M-r`, where the panes stay visible.

**Tech Stack:** fish 4.x, tmux 3.3a, the existing `t`/`vis` test harness.

## Global Constraints

- ZERO new files. Runtime code → `functions/tmux-categorize.fish`; fragment/config → `conf.d/tmux-lives-install.fish`; tests extend `tests/test-tmux-*.fish`.
- **Test isolation is a hard invariant.** Any test that drives server-mutating code must hit a throwaway `-L` socket (PATH `tmux` shim in `tests/test-tmux-categorize.fish`, or the `tmux_lives_tmux_socket` seam) or stub it. The suite must NEVER write the live `~/.config/tmux/tmux-lives.conf`, reload the live server, or clobber `tmux_lives_*` universals. Do NOT call the real `__tmux_lives_write_fragment` / `__tmux_lives_color_cmd` / `__tcz_resize_enter` against the live system — verify via the automated tests only.
- Assert helper `t <desc> <expected> <actual>` (each file defines it); `vis` strips SGR (popup/categorize tests). Reuse; invent nothing.
- fish `math` has NO comparison operators; use `test`.
- Suite gate: `fish -c 'for t in tests/test-*.fish; fish $t; end'` → every suite `ALL PASS`, 0 FAIL. Known PRE-EXISTING flake (ignore): `tests/test-tmux-restore.fish` intermittently emits one stderr line "no server running on .../test-restore-<pid>".
- Default binds: `M-m` modal, `M-t` scratch, `M-r` resize, `M-s`/`prefix S` picker.
- Commit trailer: end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Do NOT deploy (the user runs `tl update`). Commit only.

## File Structure

- `functions/tmux-categorize.fish`: redesign `__tcz_modal_legend` (Task 1); simplify `__tcz_modal_action` + `__tcz_modal_readkey` (Task 2); rewrite `__tcz_modal` single-shot + slim `__tcz_modal_run` (Task 3); add `__tcz_scratch_resize` + `__tcz_resize_enter` + dispatch (Task 4); update `__tcz_modal_menu_args` label (Task 7).
- `conf.d/tmux-lives-install.fish`: `__tmux_lives_render_fragment` gains the resize key (argv[8]) + `M-r` bind + `tmuxlives-resize` key-table + passes effective keys to the modal bind (Task 5); `__tmux_lives_write_fragment` passes the resize key; `__tmux_lives_keys_cmd` + help gain `--resize-key` (Task 6).

---

## Task 1: Redesign `__tcz_modal_legend` (design B + keybind table)

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_modal_legend`
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces: `__tcz_modal_legend <has_scratch> <modalkey> <scratchkey> <resizekey> <switcherkey>` → prints the ANSI legend box. Category headers (session/scratch/config) colored 208/cyan/green; command keys orange; a `keys` rule then a two-column table of the four global binds with their functions; picker (not switcher) label.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-popup.fish`, replace the existing `__tcz_modal_legend` test block (the `LEG0`/`LEG1` assertions added for the old modal) with:

```fish
# ---------------------------------------------------------------------
# command launcher legend (design B: categorized + keybind table)
# ---------------------------------------------------------------------
function flat --description 'collapse a fish list (multiline) to one SGR-stripped space-joined string'
    set -l s (string join ' ' $argv)
    string replace -a (printf '\n') ' ' -- (vis "$s")
end
set -g LG (flat (__tcz_modal_legend 1 M-m M-t M-r M-s))
t "legend title tmux-lives"     yes (string match -q '*tmux-lives*' -- "$LG"; and echo yes; or echo no)
t "legend session header"       yes (string match -q '*session*' -- "$LG"; and echo yes; or echo no)
t "legend scratch header"       yes (string match -q '*scratch*' -- "$LG"; and echo yes; or echo no)
t "legend config header"        yes (string match -q '*config*' -- "$LG"; and echo yes; or echo no)
t "legend says picker not switcher" yes (string match -q '*picker*' -- "$LG"; and string match -q '*switcher*' -- "$LG"; and echo no; or echo yes)
t "legend command keys p/n/c/g" yes (string match -q '*p*picker*n*new*' -- "$LG"; and string match -q '*c*clear*g*categorize*' -- "$LG"; and echo yes; or echo no)
t "legend scratch cmds t/r"     yes (string match -q '*t*toggle*r*resize*' -- "$LG"; and echo yes; or echo no)
t "legend config cmd b"         yes (string match -q '*b*bar color*' -- "$LG"; and echo yes; or echo no)
t "legend keys table shows binds+fns" yes (string match -q '*M-m*menu*M-r*resize*' -- "$LG"; and string match -q '*M-t*scratch*M-s*picker*' -- "$LG"; and echo yes; or echo no)
t "legend keys table honors configured binds" yes (string match -q '*C-a*menu*' -- (flat (__tcz_modal_legend 1 C-a M-t M-r M-s)); and echo yes; or echo no)
t "legend esc close"            yes (string match -q '*esc*close*' -- "$LG"; and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — the new signature/content isn't there yet (old legend took only `has_scratch` and said "switcher").

- [ ] **Step 3: Replace `__tcz_modal_legend`**

```fish
function __tcz_modal_legend --argument-names has_scratch modalkey scratchkey resizekey switcherkey --description 'pure: the command-launcher legend box (design B: categorized commands + keybind table). Keys passed in so it reflects the effective binds.'
    set -l O (printf '\e[38;5;208m'); set -l OD (printf '\e[38;5;130m')  # orange, dim-orange border
    set -l CY (printf '\e[36m'); set -l GR (printf '\e[32m')
    set -l T (printf '\e[0m'); set -l M (printf '\e[2m'); set -l MO (printf '\e[22m')
    set -l W 28                                   # inner width (between the borders)
    # a full-width category rule: "cat ─────" padded to W, in colour $c
    function __tcz_ml_rule --no-scope-shadowing
        set -l label $argv[1]; set -l col $argv[2]; set -l w $argv[3]
        set -l lead "$label "
        set -l dash (string repeat -n (math "$w - "(string length -- "$lead")) ─)
        printf '%s│%s %s%s%s │\n' $OD $col "$lead$dash" $OD
    end
    # a padded command/plain row (visible content already built; pad to W)
    function __tcz_ml_row --no-scope-shadowing
        set -l content $argv[1]; set -l vis $argv[2]; set -l w $argv[3]
        set -l pad (math "$w - $vis"); test $pad -lt 0; and set pad 0
        printf '%s│%s%s%s│\n' $OD "$content"(string repeat -n $pad ' ') $OD
    end
    set -l lines
    # top border with title
    set -a lines $OD"╭─ "$O"tmux-lives"$OD" "(string repeat -n (math "$W - 12") ─)"╮"$T
    set -a lines (__tcz_ml_rule "session" $O $W | string trim -r)
    set -a lines (__tcz_ml_row "   $O"p"$T picker    $O"n"$T new" "   p picker    n new" $W)
    set -a lines (__tcz_ml_row "   $O"c"$T clear     $O"g"$T categorize" "   c clear     g categorize" $W)
    set -a lines (__tcz_ml_rule "scratch" $CY $W | string trim -r)
    set -a lines (__tcz_ml_row "   $O"t"$T toggle    $O"r"$T resize…" "   t toggle    r resize…" $W)
    set -a lines (__tcz_ml_rule "config" $GR $W | string trim -r)
    set -a lines (__tcz_ml_row "   $O"b"$T bar color" "   b bar color" $W)
    set -a lines (__tcz_ml_rule "keys" $M $W | string trim -r)
    set -a lines (__tcz_ml_row "  $M"$modalkey" menu     $resizekey" resize"$T "  $modalkey menu     $resizekey resize" $W)
    set -a lines (__tcz_ml_row "  $M"$scratchkey" scratch  $switcherkey" picker"$T "  $scratchkey scratch  $switcherkey picker" $W)
    set -a lines (__tcz_ml_row "  $M"esc"$T close" "  esc close" $W)
    set -a lines $OD"╰"(string repeat -n (math "$W + 1") ─)"╯"$T
    functions -e __tcz_ml_rule __tcz_ml_row
    printf '%s\n' $lines
end
```

Note: the inner `__tcz_ml_rule`/`__tcz_ml_row` helpers are defined and erased inside the function so they don't leak. `--no-scope-shadowing` lets them see the caller's vars; they only use their args here, so it is belt-and-suspenders. Visible-width strings are passed explicitly (second arg) because the content carries SGR.

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: PASS (`ALL PASS`). Alignment need not be pixel-perfect for the content assertions; visual polish is a runtime concern.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(modal): redesign legend (design B categorized + keybind table, picker)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Simplify `__tcz_modal_action` + `__tcz_modal_readkey` for the launcher keys

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_modal_action`, `__tcz_modal_readkey`
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces: `__tcz_modal_action <key>` → one of `picker new clear categorize scratch resize color close noop` (no `has_scratch` arg anymore — the launcher is single-shot; resize-mode gating happens in `__tcz_resize_enter`). `__tcz_modal_readkey` → keyname incl. `p` and `r`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-popup.fish`, replace the old `__tcz_modal_action` / `__tcz_modal_readkey` test blocks with:

```fish
t "action p -> picker" picker (__tcz_modal_action p)
t "action n -> new" new (__tcz_modal_action n)
t "action c -> clear" clear (__tcz_modal_action c)
t "action g -> categorize" categorize (__tcz_modal_action g)
t "action t -> scratch" scratch (__tcz_modal_action t)
t "action r -> resize" resize (__tcz_modal_action r)
t "action b -> color" color (__tcz_modal_action b)
t "action esc -> close" close (__tcz_modal_action esc)
t "action q -> close" close (__tcz_modal_action q)
t "action z -> noop" noop (__tcz_modal_action z)

t "readkey p" p (printf 'p' | __tcz_modal_readkey 2>/dev/null)
t "readkey r" r (printf 'r' | __tcz_modal_readkey 2>/dev/null)
t "readkey n" n (printf 'n' | __tcz_modal_readkey 2>/dev/null)
t "readkey enter" enter (printf '\r' | __tcz_modal_readkey 2>/dev/null)
t "readkey bare esc" esc (printf '\e' | __tcz_modal_readkey 2>/dev/null)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — `p`/`r` unmapped; action still expects a scratch arg / emits old tokens.

- [ ] **Step 3: Replace the two functions**

```fish
function __tcz_modal_action --argument-names key --description 'pure: launcher keyname -> action token (single-shot; resize-mode gating is in __tcz_resize_enter)'
    switch "$key"
        case p; echo picker
        case n; echo new
        case c; echo clear
        case g; echo categorize
        case t; echo scratch
        case r; echo resize
        case b; echo color
        case esc q; echo close
        case '*'; echo noop
    end
end

function __tcz_modal_readkey --description 'read one keystroke -> keyname (launcher letters; enter/esc parsed)'
    set -l b ''
    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read b
    test -z "$b"; and begin; echo close; return; end          # EOF
    switch "$b"
        case 0d 0a; echo enter; return
        case 70; echo p; return
        case 6e; echo n; return
        case 63; echo c; return
        case 67; echo g; return
        case 74; echo t; return
        case 72; echo r; return
        case 62; echo b; return
        case 71; echo q; return
        case 1b; echo esc; return
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
git commit -m "feat(modal): launcher key map (p picker, r resize; single-shot action set)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Rewrite `__tcz_modal` single-shot + `__tcz_modal_run` (close-then-run)

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_modal`, `__tcz_modal_run`; `modal` case in `__tcz_main`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_modal_legend` (Task 1, 5-arg), `__tcz_modal_action`/`__tcz_modal_readkey` (Task 2), `__tcz_scratch`, `__tcz_open_switcher`, `__tcz_categorize`, `__tcz_resize_enter` (Task 4).
- Produces: `__tcz_modal_run <action> <client>` → performs the action (single-shot; no return value needed). `__tcz_modal <client> <modalkey> <scratchkey> <resizekey> <switcherkey>` → draw once, read one key, dispatch, exit. `__tcz_main` dispatches `modal` → `__tcz_modal $argv[2..]`.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-categorize.fish`, replace the old modal test block (the `__tcz_modal_run scratch/categorize/...` and `MSRC` source-asserts) with:

```fish
# ---------------------------------------------------------------------
# launcher dispatch (__tcz_modal_run) — single-shot, close-then-run
# ---------------------------------------------------------------------
fresh_server
t "run scratch creates a marked pane" 1 (__tcz_modal_run scratch ''; command tmux -L $sock list-panes -F '#{@tmux_lives_scratch}' | grep -c '^1$')
fresh_server
t "run categorize runs (no crash)" 0 (__tcz_modal_run categorize ''; echo $status)
t "run close is a no-op" 0 (__tcz_modal_run close ''; echo $status)
t "run picker uses deferred run-shell -b" yes (string match -q '*run-shell -b*open-switcher*' -- (functions __tcz_modal_run | string collect); and echo yes; or echo no)
command tmux -L $sock kill-server 2>/dev/null
# loop-free launcher wiring (interactive popup is runtime-verified)
set -g MSRC (functions __tcz_modal | string collect)
t "modal reads one key (no while loop)" yes (string match -q '*__tcz_modal_readkey*' -- "$MSRC"; and string match -q '*while true*' -- "$MSRC"; and echo no; or echo yes)
t "modal draws legend" yes (string match -q '*__tcz_modal_legend*' -- "$MSRC"; and echo yes; or echo no)
t "modal dispatches via run" yes (string match -q '*__tcz_modal_run*' -- "$MSRC"; and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_modal_run` still has the old loop-oriented tokens / `__tcz_modal` still loops.

- [ ] **Step 3: Rewrite the runner and the single-shot loop-free modal**

Replace `__tcz_modal_run` and `__tcz_modal` with:

```fish
function __tcz_modal_run --argument-names action client --description 'perform one launcher action (single-shot; the popup exits right after)'
    switch "$action"
        case picker
            # Defer: run AFTER this popup closes, so the picker popup is not nested.
            tmux run-shell -b "fish --no-config $__tcz_self open-switcher '$client'" 2>/dev/null
        case new
            fish -c 'tmux-lives new' 2>/dev/null
        case clear
            fish -c 'tmux-lives clear' 2>/dev/null
            tmux display-message 'tmux-lives: cleared idle sessions' 2>/dev/null
        case categorize
            __tcz_categorize >/dev/null 2>&1
            tmux display-message 'tmux-lives: categorized' 2>/dev/null
        case scratch
            __tcz_scratch "$client"
        case resize
            __tcz_resize_enter "$client"
        case color
            # cooked-read prompt handled by the loop-free __tcz_modal (needs the tty); no-op here
        case close noop
            # nothing
    end
end

function __tcz_modal --argument-names client modalkey scratchkey resizekey switcherkey --description 'single-shot command launcher (runs inside display-popup): draw legend, read ONE key, act, exit'
    if test -z "$client"; or string match -q '*#{*' -- "$client"
        set client (tmux display-message -p '#{client_name}' 2>/dev/null)
    end
    test -n "$modalkey"; or set modalkey M-m
    test -n "$scratchkey"; or set scratchkey M-t
    test -n "$resizekey"; or set resizekey M-r
    test -n "$switcherkey"; or set switcherkey M-s
    set -l sp (__tcz_scratch_pane)
    set -l has 0; test -n "$sp[1]"; and set has 1
    set -l saved (stty -g)
    stty -icanon -echo min 1 time 0
    printf '\e[?25l\e[2J\e[H'
    __tcz_modal_legend $has $modalkey $scratchkey $resizekey $switcherkey
    set -l action (__tcz_modal_action (__tcz_modal_readkey))
    if test "$action" = color
        stty "$saved" 2>/dev/null
        printf '\e[2J\e[H bar color (css), empty cancels: '
        set -l val ''
        read -l val
        test -n "$val"; and fish -c 'tmux-lives setup color $argv[1]' "$val" 2>/dev/null
    else
        __tcz_modal_run $action "$client"
    end
    stty $saved 2>/dev/null
    printf '\e[?25h\e[2J\e[H'
    return 0
end
```

Note: `has` uses the guarded form (`test -n "$sp[1]"`) — never `test -n (__tcz_scratch_pane)[1]`, which reads as `test -n` (true) when the result is empty. `has` is passed to the legend for a possible future "dim resize when no scratch"; the Task 1 legend accepts it.

Update `__tcz_main`'s `modal` case to forward all args:

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
git commit -m "feat(modal): single-shot launcher — draw, read one key, close-then-run

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Scratch resize verbs — `__tcz_scratch_resize` + `__tcz_resize_enter`

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_scratch_resize`, `__tcz_resize_enter`; `scratch-resize` / `resize-enter` cases in `__tcz_main`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_scratch_pane` (existing).
- Produces: `__tcz_scratch_resize <L|R|U|D>` → resize the marked scratch pane (4 cols horizontal, 2 rows vertical). `__tcz_resize_enter <client>` → if a scratch exists, `switch-client -c <client> -T tmuxlives-resize` + show the hint; else a `display-message` nudge and NO table switch. `__tcz_main` dispatches both.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-categorize.fish`, after the Task 3 block, add:

```fish
# ---------------------------------------------------------------------
# scratch resize verbs
# ---------------------------------------------------------------------
fresh_server
__tcz_scratch      # create a scratch so there are two panes
set -g w0 (command tmux -L $sock list-panes -F '#{pane_width}' | sort -n | head -1)
__tcz_scratch_resize L
set -g w1 (command tmux -L $sock list-panes -F '#{pane_width}' | sort -n | head -1)
t "scratch_resize changes a pane width" yes (test "$w0" != "$w1"; and echo yes; or echo no)
# resize-enter with a scratch switches the key table (assert via source: uses switch-client -T)
t "resize_enter uses tmuxlives-resize table" yes (string match -q '*switch-client*tmuxlives-resize*' -- (functions __tcz_resize_enter | string collect); and echo yes; or echo no)
t "resize_enter nudges when no scratch" yes (string match -q '*display-message*' -- (functions __tcz_resize_enter | string collect); and echo yes; or echo no)
# no-scratch: resize-enter must NOT error
fresh_server
t "resize_enter no-scratch is clean" 0 (__tcz_resize_enter ''; echo $status)
command tmux -L $sock kill-server 2>/dev/null
t "main dispatches scratch-resize" yes (string match -q '*scratch-resize*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
t "main dispatches resize-enter" yes (string match -q '*resize-enter*' -- (functions __tcz_main | string collect); and echo yes; or echo no)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — verbs undefined.

- [ ] **Step 3: Implement the verbs + dispatch**

Add near `__tcz_scratch_orient`:

```fish
function __tcz_scratch_resize --argument-names dir --description 'resize the marked scratch pane (L/R = 4 cols, U/D = 2 rows)'
    set -l p (__tcz_scratch_pane)
    test -n "$p[1]"; or return 0
    switch "$dir"
        case L; tmux resize-pane -t "$p[1]" -L 4 2>/dev/null
        case R; tmux resize-pane -t "$p[1]" -R 4 2>/dev/null
        case U; tmux resize-pane -t "$p[1]" -U 2 2>/dev/null
        case D; tmux resize-pane -t "$p[1]" -D 2 2>/dev/null
    end
end

function __tcz_resize_enter --argument-names client --description 'enter the native scratch resize key-table if a scratch exists; else nudge'
    set -l p (__tcz_scratch_pane)
    if test -z "$p[1]"
        tmux display-message 'tmux-lives: no scratch pane — press the scratch key to create one' 2>/dev/null
        return 0
    end
    test -n "$client"; and tmux switch-client -c "$client" -T tmuxlives-resize 2>/dev/null; or tmux switch-client -T tmuxlives-resize 2>/dev/null
    tmux display-message -d 0 'scratch:  ←→↑↓ resize · h/w split · x close · esc done' 2>/dev/null
end
```

Add to `__tcz_main` (after the `scratch` case):

```fish
        case scratch-resize
            __tcz_scratch_resize $argv[2]
        case resize-enter
            __tcz_resize_enter $argv[2..]
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS. (`__tcz_resize_enter ''` on a fresh single-pane server takes the nudge path — `display-message` needs no client and returns 0.)

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(scratch): scratch-resize verb + resize-enter (native key-table entry)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Fragment — `M-r` bind + `tmuxlives-resize` key-table + modal bind passes keys

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (argv[8] + binds), `__tmux_lives_write_fragment` (pass resize key)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: the `modal` / `resize-enter` / `scratch-resize` verbs (Tasks 3–4).
- Produces: `__tmux_lives_render_fragment <cat> <pkey> <skey> <color> <invert> <modalkey> <scratchkey> <resizekey>` — argv[8] added. The modal popup bind now passes the effective keys as literal argv; a root `M-r` bind runs `resize-enter`; a `tmuxlives-resize` key-table block is emitted (arrows→scratch-resize+re-enter, h/w→orient+re-enter, x→kill+exit, Escape/Enter→root+clear hint).

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, in the fragment-render section, add:

```fish
set -g FRAGR (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r | string collect)
t "fragment modal bind passes keys" yes (string match -q "*cat.fish modal '#{client_name}' 'M-m' 'M-t' 'M-r' 'M-s'*" -- "$FRAGR"; and echo yes; or echo no)
t "fragment binds M-r to resize-enter" yes (string match -q '*bind-key -n M-r run-shell*resize-enter*' -- "$FRAGR"; and echo yes; or echo no)
t "fragment defines resize key-table" yes (string match -q '*bind-key -T tmuxlives-resize*' -- "$FRAGR"; and echo yes; or echo no)
t "resize table arrow re-enters (sticky)" yes (string match -q '*tmuxlives-resize Left*scratch-resize L*switch-client -T tmuxlives-resize*' -- "$FRAGR"; and echo yes; or echo no)
t "resize table esc returns to root" yes (string match -q '*tmuxlives-resize Escape*switch-client -T root*' -- "$FRAGR"; and echo yes; or echo no)
set -g FRAGR0 (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t '' | string collect)
t "no M-r bind when resize key empty" no (string match -q '*resize-enter*' -- "$FRAGR0"; and echo yes; or echo no)
# rendered fragment still parses on a real -L server
set -g rsock tli-rz-$fish_pid
command tmux -L $rsock new-session -d 2>/dev/null
printf '%s\n' "$FRAGR" | string replace -a '/x/cat.fish' '/tmp/nope.fish' > /tmp/tli-rzfrag-$fish_pid.conf
t "resize fragment parses (source-file rc0)" 0 (command tmux -L $rsock source-file /tmp/tli-rzfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $rsock kill-server 2>/dev/null; rm -f /tmp/tli-rzfrag-$fish_pid.conf
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — render takes only 7 args; no M-r bind / key-table; modal bind doesn't pass keys.

- [ ] **Step 3: Extend `__tmux_lives_render_fragment`**

Add argv[8] near the top (after `set -l scratchkey $argv[7]`):

```fish
    set -l resizekey $argv[8]   # root-table scratch-resize-mode key ('' = no bind)
```

Change the modal popup/menu binds (the `if test -n "$modalkey"` block) so the popup bind passes the effective keys as literal argv:

```fish
    if test -n "$modalkey"
        set -a popup "    bind-key -n $modalkey display-popup -E -w 64% -h 55% -- fish --no-config $cat modal '#{client_name}' '$modalkey' '$scratchkey' '$resizekey' '$skey'"
        set -a menu  "    bind-key -n $modalkey run-shell 'fish --no-config $cat modal-menu'"
    end
```

After the always-on scratch bind line (`test -n "$scratchkey"; and set -a f ...`), add the resize-mode bind + key table:

```fish
    if test -n "$resizekey"
        set -a f "bind-key -n $resizekey run-shell \"fish --no-config $cat resize-enter '#{client_name}'\""
        set -a f "bind-key -T tmuxlives-resize Left  { run-shell \"fish --no-config $cat scratch-resize L\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize Right { run-shell \"fish --no-config $cat scratch-resize R\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize Up    { run-shell \"fish --no-config $cat scratch-resize U\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize Down  { run-shell \"fish --no-config $cat scratch-resize D\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize h     { run-shell \"fish --no-config $cat scratch-orient h\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize w     { run-shell \"fish --no-config $cat scratch-orient w\" ; switch-client -T tmuxlives-resize }"
        set -a f "bind-key -T tmuxlives-resize x       run-shell \"fish --no-config $cat scratch-kill\""
        set -a f "bind-key -T tmuxlives-resize Escape  switch-client -T root"
        set -a f "bind-key -T tmuxlives-resize Enter   switch-client -T root"
    end
```

This references two categorizer verbs that must exist: `scratch-orient` and `scratch-kill`. `scratch-orient <h|w>` is already dispatched? Confirm/add both cases to `__tcz_main` in this task (they are thin wrappers):

```fish
        case scratch-orient
            __tcz_scratch_orient $argv[2]
        case scratch-kill
            __tcz_scratch   # toggle: since a scratch exists, this removes it
```

(These are added in `functions/tmux-categorize.fish`; commit them with this task since the fragment references them.)

- [ ] **Step 3b: Pass the resize key from `__tmux_lives_write_fragment`**

Append the resize key to the `__tmux_lives_render_fragment` call:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) (__tmux_lives_key tmux_lives_modal_key M-m) (__tmux_lives_key tmux_lives_scratch_key M-t) (__tmux_lives_key tmux_lives_resize_key M-r) > $fragment
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS. Pre-existing render tests still pass (7-arg / 5-arg callers leave argv[8] empty → no resize bind).

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): render M-r resize key-table + pass effective keys to the modal bind

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `setup keys --resize-key` + help

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_keys_cmd`, `__tmux_lives_setup_help_lines`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `setup keys --resize-key <key>` sets universal `tmux_lives_resize_key`.

- [ ] **Step 1: Write the failing test**

Add to the `setup keys` test block in `tests/test-tmux-install.fish`:

```fish
set -e tmux_lives_resize_key
functions -c __tmux_lives_write_fragment __wf3_bak
function __tmux_lives_write_fragment; end
__tmux_lives_keys_cmd --resize-key M-r
t "keys --resize-key persists" M-r "$tmux_lives_resize_key"
functions -e __tmux_lives_write_fragment; functions -c __wf3_bak __tmux_lives_write_fragment; functions -e __wf3_bak
set -e tmux_lives_resize_key
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `--resize-key` is an unknown option.

- [ ] **Step 3: Add the flag + help**

In `__tmux_lives_keys_cmd`'s `while` switch, add:

```fish
            case --resize-key
                set -U tmux_lives_resize_key $argv[2]; set changed 1; set -e argv[1..2]
```

In `__tmux_lives_setup_help_lines`, add a line under the modal/scratch key lines:

```fish
        "      --resize-key <key>    scratch resize mode (default: M-r; '' off)" \
```

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS. Framed setup help still fits 80 cols (the new line matches the width of the existing `--modal-key` line).

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): setup keys --resize-key

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: display-menu fallback picker rename

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_modal_menu_args`
- Test: `tests/test-tmux-popup.fish`

**Interfaces:**
- Produces: `__tcz_modal_menu_args` labels the switcher entry "picker".

- [ ] **Step 1: Write the failing test**

Update the menu-args test in `tests/test-tmux-popup.fish`:

```fish
t "menu-args labels picker not switcher" yes (string match -q '*picker*' -- "$MM"; and string match -q '*switcher*' -- "$MM"; and echo no; or echo yes)
```

(where `$MM` is the existing `(__tcz_modal_menu_args | string collect)` capture.)

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL — the entry still reads "switcher".

- [ ] **Step 3: Rename the label**

In `__tcz_modal_menu_args`, change the switcher line's label from `'switcher'` to `'picker'` (leave the `open-switcher` command verb unchanged).

- [ ] **Step 4: Run to verify pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(modal): rename switcher -> picker in the display-menu fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after Task 7)

- [ ] **Full suite green + no live drift**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: every suite `ALL PASS`, 0 FAIL, no non-restore-flake stderr. Also confirm the live fragment/server were untouched: `grep -cE 'M-r|tmuxlives-resize' ~/.config/tmux/tmux-lives.conf` is `0` and `tmux list-keys -T root | grep -c ' M-r '` is `0` (the suite must not have deployed).

- [ ] **Docs (CLAUDE.md + README + vault)**: update the in-tmux surface description — the single-shot launcher, `M-r` resize mode, `setup keys --resize-key`, and the switcher→picker rename. Re-run `vault-publish` for the README. Commit.

## Runtime pre-flight (user-validated on real tmux + ShellFish — not unit-testable)

- The launcher `p` action: `run-shell -b … open-switcher` opens the picker *after* the launcher popup closes (no nesting). If timing races, fall back to a keybinding chain or a short defer.
- The cooked `read` for `b` (bar color) inside `display-popup -E`.
- `M-r`: `switch-client -c <client> -T tmuxlives-resize` actually enters the mode; arrows resize the visible scratch and the mode stays sticky; `esc`/`enter` exit; the `display-message -d 0` hint shows.
- `M-r` / `M-t` / `M-m` don't collide with the user's terminal binds.

## Self-Review

**Spec coverage:** Part A (single-shot launcher + close-then-run) → Tasks 2–3; Part B (design-B legend) → Task 1; Part C (M-r resize mode) → Tasks 4–5; Part D (picker rename) → Tasks 1, 7 + docs; Part E (menu fallback) → Task 7; Part F (config) → Tasks 5–6. ✓

**Placeholder scan:** none — every step has complete code. The Task 3 note flags the one line to delete (the un-guarded `has` computation) so the implementer doesn't transcribe both.

**Type/name consistency:** action tokens from `__tcz_modal_action` (Task 2: `picker new clear categorize scratch resize color close noop`) all have arms in `__tcz_modal_run` (Task 3) — except `resize` which routes to `__tcz_resize_enter` (Task 4) and `color` which the loop-free `__tcz_modal` handles inline; both are accounted for. `__tcz_scratch_resize`/`__tcz_resize_enter`/`__tcz_scratch_orient`/`scratch-kill` verbs referenced by the fragment (Task 5) are all defined (Tasks 4–5). `__tmux_lives_render_fragment` arg order `cat pkey skey color invert modalkey scratchkey resizekey` (Task 5) matches `__tmux_lives_write_fragment`'s call. The modal bind passes `$skey` (the switcher key) as the 5th modal arg = `switcherkey` in `__tcz_modal`/`__tcz_modal_legend`.
