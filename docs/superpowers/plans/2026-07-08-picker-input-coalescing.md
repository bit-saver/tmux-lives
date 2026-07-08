# Picker Input Coalescing Implementation Plan

> ⛔ **REVERTED 2026-07-08 (same day it shipped).** This plan was executed and merged, then reverted: the burst-coalescing regressed the picker *feel* on a fast local machine (held ↓ jumps in chunks instead of scrolling smoothly), and the LXC lag it targeted was host-side scheduling load, not the picker. See the design doc's Status block for the full post-mortem. Retained as an execution record. Do not re-run as-is.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the picker's up/down arrows responsive under host load by coalescing its read/draw loop so cost scales with input bursts instead of keystrokes.

**Architecture:** Replace the byte-by-byte `__tcz_popup_readkey` with a pure, unit-tested byte→token parser (`__tcz_popup_parse_keys`) plus a thin burst reader (`__tcz_popup_read_keys`) that drains all buffered input in one `dd`/`od` pair. Extract the loop's navigation reducer into a pure `__tcz_popup_apply_keys`. Then `__tcz_popup`'s loop consumes one burst per iteration and redraws (with its `capture-pane` preview) once per burst.

**Tech Stack:** fish shell; tmux 3.3a; the existing pure-test harness in `tests/test-tmux-popup.fish` (`tmux_categorize_test=1`, no live tmux).

## Global Constraints

- **No new external dependencies** — only `dd`, `od`, `stty`, and fish builtins already used by the picker.
- **Tests are pure / pipe-fed** — no test touches the live tmux server or universals (the project's hard isolation invariant). Source the script with `set -g tmux_categorize_test 1`.
- **Zero user-visible behavior change** — every key (↑↓ / `j` / `k` / `Enter` / `x`+`y/n` confirm / `q` / `Esc`) behaves exactly as before.
- **Do NOT deploy.** Finished work reaches the live host only via the user's own `fisher update`. Edit → test → commit. Never `cp` into `~/.config/fish/` or edit `~/.tmux.conf`.
- **All key tokens are one of:** `up`, `down`, `enter`, `cancel`, `kill`, `other`.
- **Full suite green before done:** `for t in tests/test-*.fish; fish $t; end` — all 8 suites report `ALL PASS`.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- **`functions/tmux-categorize.fish`** — all four functions live in the popup-helpers section (currently around `__tcz_popup_readkey` at line 698 and `__tcz_popup_preview` at 693). Insert the three new pure/thin readers immediately after the existing `__tcz_popup_readkey` function; add `__tcz_popup_apply_keys` alongside them. Modify the `__tcz_popup` loop (the `while true` block at lines 944-972). Remove `__tcz_popup_readkey` (lines 698-736) in the final task.
- **`tests/test-tmux-popup.fish`** — add pure-test blocks for the new functions; in the final task, replace the 8 `__tcz_popup_readkey` tests (lines 177-184) with the loop-wiring structural assertions.

Function responsibilities:
- `__tcz_popup_parse_keys` — pure: hex bytes → key tokens. The change's entire risk surface; exhaustively tested.
- `__tcz_popup_hex_dangling` — pure predicate: does a hex list end mid escape-sequence? (the completion-read trigger).
- `__tcz_popup_read_keys` — thin/impure: one burst read from stdin (+ completion read for a split escape) → tokens.
- `__tcz_popup_apply_keys` — pure: reduce a token burst against `(sel, n)` → settled `sel` + resulting action.
- `__tcz_popup` loop — orchestration: `draw → read_keys → apply_keys → act`, one burst per iteration.

---

### Task 1: `__tcz_popup_parse_keys` — pure byte→token parser

**Files:**
- Modify: `functions/tmux-categorize.fish` (insert immediately after `__tcz_popup_readkey`, ~line 736)
- Test: `tests/test-tmux-popup.fish` (add a block after the existing readkey tests, ~line 184)

**Interfaces:**
- Consumes: nothing.
- Produces: `__tcz_popup_parse_keys <hexbyte...>` — echoes one token per line (`up`/`down`/`enter`/`cancel`/`kill`/`other`) for each key recognized in the hex-byte argument list. CSI `1b 5b 41/42` and SS3 `1b 4f 41/42` → up/down; `6a`→down, `6b`→up, `0d`/`0a`→enter, `71`→cancel, `78`→kill; a trailing lone `1b` → cancel; anything else → other.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-popup.fish` after line 184 (`t "readkey q=cancel" …`):

```fish
# ---------------------------------------------------------------------
# __tcz_popup_parse_keys — pure hex-byte -> key tokens (one per line)
# ---------------------------------------------------------------------
t "parse CSI up"        up     (__tcz_popup_parse_keys 1b 5b 41)
t "parse CSI down"      down   (__tcz_popup_parse_keys 1b 5b 42)
t "parse SS3 up"        up     (__tcz_popup_parse_keys 1b 4f 41)
t "parse SS3 down"      down   (__tcz_popup_parse_keys 1b 4f 42)
t "parse j=down"        down   (__tcz_popup_parse_keys 6a)
t "parse k=up"          up     (__tcz_popup_parse_keys 6b)
t "parse CR=enter"      enter  (__tcz_popup_parse_keys 0d)
t "parse LF=enter"      enter  (__tcz_popup_parse_keys 0a)
t "parse q=cancel"      cancel (__tcz_popup_parse_keys 71)
t "parse x=kill"        kill   (__tcz_popup_parse_keys 78)
t "parse bare ESC=cancel" cancel (__tcz_popup_parse_keys 1b)
t "parse junk=other"    other  (__tcz_popup_parse_keys ff)
t "parse triple down"   "down down down" (__tcz_popup_parse_keys 1b 5b 42 1b 5b 42 1b 5b 42 | string join ' ')
t "parse mixed nav"     "down down up"   (__tcz_popup_parse_keys 1b 5b 42 6a 6b | string join ' ')
t "parse nav then enter" "down enter"    (__tcz_popup_parse_keys 1b 5b 42 0d | string join ' ')
t "parse burst nav then kill" "up kill"  (__tcz_popup_parse_keys 6b 78 | string join ' ')
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL lines for the new `parse …` assertions (`__tcz_popup_parse_keys` is an unknown command → empty output → mismatch), ending `SOME FAILED`.

- [ ] **Step 3: Write the implementation**

Insert into `functions/tmux-categorize.fish` immediately after the `__tcz_popup_readkey` function (after its closing `end`, ~line 736):

```fish
function __tcz_popup_parse_keys --description 'pure: hex byte list (argv) -> key tokens (up/down/enter/cancel/kill/other), one per line'
    set -l N (count $argv)
    set -l i 1
    while test $i -le $N
        switch $argv[$i]
            case 6a
                echo down                            # j
            case 6b
                echo up                              # k
            case 71
                echo cancel                          # q
            case 78
                echo kill                            # x
            case 0d 0a
                echo enter                           # CR / LF
            case 1b                                  # ESC: CSI/SS3 arrow, or bare ESC
                set -l b2 ''; set -l b3 ''
                test (math $i + 1) -le $N; and set b2 $argv[(math $i + 1)]
                test (math $i + 2) -le $N; and set b3 $argv[(math $i + 2)]
                if test "$b2" = 5b; or test "$b2" = 4f     # [ or O
                    switch "$b3"
                        case 41
                            echo up                  # A (up)
                        case 42
                            echo down                # B (down)
                        case '*'
                            echo other               # incomplete/unknown CSI/SS3
                    end
                    set i (math $i + 2)              # consumed b2 (+ b3)
                else if test -z "$b2"
                    echo cancel                      # bare trailing ESC
                else
                    echo cancel                      # ESC + non-arrow -> cancel (b2 reparsed next)
                end
            case '*'
                echo other
        end
        set i (math $i + 1)
    end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: all `parse …` lines print `ok`; file ends `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(picker): pure __tcz_popup_parse_keys (hex bytes -> key tokens)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `__tcz_popup_hex_dangling` + `__tcz_popup_read_keys` — burst reader

**Files:**
- Modify: `functions/tmux-categorize.fish` (insert after `__tcz_popup_parse_keys`)
- Test: `tests/test-tmux-popup.fish` (add a block after the Task 1 parse tests)

**Interfaces:**
- Consumes: `__tcz_popup_parse_keys` (Task 1).
- Produces:
  - `__tcz_popup_hex_dangling <hexbyte...>` — returns 0 (true) iff the byte list ends mid escape-sequence: a lone trailing `1b`, or `1b 5b` / `1b 4f` awaiting the final byte; else returns 1.
  - `__tcz_popup_read_keys` — reads one input burst from stdin, echoes key tokens (one per line). Drains all currently-buffered bytes in one read; if the burst ends mid escape-sequence, does a short non-blocking completion read to fetch the tail.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-popup.fish` after the Task 1 parse block:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_hex_dangling — pure: ends mid escape-sequence?
# ---------------------------------------------------------------------
t "dangling lone ESC"     yes (__tcz_popup_hex_dangling 1b;       and echo yes; or echo no)
t "dangling ESC["         yes (__tcz_popup_hex_dangling 1b 5b;    and echo yes; or echo no)
t "dangling ESCO"         yes (__tcz_popup_hex_dangling 1b 4f;    and echo yes; or echo no)
t "complete arrow ok"     no  (__tcz_popup_hex_dangling 1b 5b 41; and echo yes; or echo no)
t "plain byte ok"         no  (__tcz_popup_hex_dangling 6a;       and echo yes; or echo no)
t "empty ok"              no  (__tcz_popup_hex_dangling;          and echo yes; or echo no)

# ---------------------------------------------------------------------
# __tcz_popup_read_keys — one burst from stdin -> tokens (pipe-fed; stty no-ops)
# ---------------------------------------------------------------------
t "read_keys CSI up"      up   (printf '\e[A' | __tcz_popup_read_keys 2>/dev/null)
t "read_keys SS3 down"    down (printf '\eOB' | __tcz_popup_read_keys 2>/dev/null)
t "read_keys j=down"      down (printf 'j'    | __tcz_popup_read_keys 2>/dev/null)
t "read_keys x=kill"      kill (printf 'x'    | __tcz_popup_read_keys 2>/dev/null)
t "read_keys bare esc"    cancel (printf '\e' | __tcz_popup_read_keys 2>/dev/null)
t "read_keys burst 2 down" "down down" (printf '\e[B\e[B' | __tcz_popup_read_keys 2>/dev/null | string join ' ')
t "read_keys burst nav+enter" "down enter" (printf '\e[B\r' | __tcz_popup_read_keys 2>/dev/null | string join ' ')
```

(The last case feeds the bytes `1b 5b 42 0d` — a down arrow immediately followed by a carriage return — asserting a nav key and a terminal key coalesce in one burst.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL lines for `dangling …` and `read_keys …` (unknown commands), ending `SOME FAILED`.

- [ ] **Step 3: Write the implementation**

Insert into `functions/tmux-categorize.fish` immediately after `__tcz_popup_parse_keys`:

```fish
function __tcz_popup_hex_dangling --description 'pure: true if hex byte list ends mid escape sequence (lone 1b, or 1b 5b / 1b 4f awaiting final byte)'
    set -l n (count $argv)
    test $n -ge 1; or return 1
    test $argv[$n] = 1b; and return 0
    if test $n -ge 2; and test $argv[(math $n - 1)] = 1b
        test $argv[$n] = 5b; or test $argv[$n] = 4f; and return 0
    end
    return 1
end

function __tcz_popup_read_keys --description 'read one input burst from stdin -> key tokens; drains all buffered bytes in one read, completes a split trailing escape'
    # `dd` MUST be the HEAD of a real pipeline here, NOT wrapped in a command
    # substitution. When this function runs as a pipe's RHS (as in the tests, and
    # possible at runtime), a `(dd …)` command sub does NOT inherit the piped
    # stdin — the same fish quirk the old __tcz_popup_readkey documented. So dd
    # reads the tty/pipe as the pipeline head and `read -z` captures the hex into
    # a function-scope var. One read grabs everything buffered (ambient stty is
    # min 1 time 0: block for the first byte, return the whole burst). od can wrap
    # to several lines for a big burst; `-z` reads them all, then flatten newlines.
    set -l raw ''
    dd bs=256 count=1 2>/dev/null | od -An -tx1 | read -lz raw
    set -l hex (string split -n ' ' -- (string replace -a \n ' ' -- "$raw"))
    # Rare: the burst was cut mid escape-sequence (byte stream split across reads,
    # or a bare ESC). Grab the tail non-blocking, mirroring the old ESC follow-read.
    # (On a pipe the stty calls no-op and dd hits EOF -> the loop breaks at once.)
    if test (count $hex) -gt 0
        stty min 0 time 1 2>/dev/null
        while __tcz_popup_hex_dangling $hex
            set -l mraw ''
            dd bs=8 count=1 2>/dev/null | od -An -tx1 | read -lz mraw
            set -l more (string split -n ' ' -- (string replace -a \n ' ' -- "$mraw"))
            test (count $more) -gt 0; or break
            set hex $hex $more
        end
        stty min 1 time 0 2>/dev/null
    end
    __tcz_popup_parse_keys $hex
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: all `dangling …` and `read_keys …` lines `ok`; file ends `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(picker): __tcz_popup_read_keys burst reader (+ hex_dangling)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `__tcz_popup_apply_keys` — pure navigation reducer

**Files:**
- Modify: `functions/tmux-categorize.fish` (insert after `__tcz_popup_read_keys`)
- Test: `tests/test-tmux-popup.fish` (add a block after the Task 2 read_keys tests)

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `__tcz_popup_apply_keys <sel> <n> <token...>` — reduces the token burst starting from selection index `sel` over a list of `n` items. Prints two lines: the settled selection index (clamped to `0..n-1`), then the action (`nav` if only navigation, else the first terminal key encountered: `enter` / `cancel` / `kill`). `other` tokens are ignored.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-popup.fish` after the Task 2 block:

```fish
# ---------------------------------------------------------------------
# __tcz_popup_apply_keys — pure: (sel n tokens...) -> "<newsel>\n<action>"
# ---------------------------------------------------------------------
t "apply 3 downs from 0/5"     "3 nav"    (__tcz_popup_apply_keys 0 5 down down down | string join ' ')
t "apply up clamps at 0"       "0 nav"    (__tcz_popup_apply_keys 0 5 up | string join ' ')
t "apply down clamps at n-1"   "4 nav"    (__tcz_popup_apply_keys 4 5 down | string join ' ')
t "apply nav then enter"       "2 enter"  (__tcz_popup_apply_keys 0 5 down down enter | string join ' ')
t "apply enter uses settled sel" "3 enter" (__tcz_popup_apply_keys 1 5 down down enter | string join ' ')
t "apply up then cancel"       "1 cancel" (__tcz_popup_apply_keys 2 5 up cancel | string join ' ')
t "apply down then kill"       "1 kill"   (__tcz_popup_apply_keys 0 5 down kill | string join ' ')
t "apply other ignored"        "0 nav"    (__tcz_popup_apply_keys 0 5 other other | string join ' ')
t "apply first terminal wins"  "1 enter"  (__tcz_popup_apply_keys 0 5 down enter cancel | string join ' ')
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-popup.fish`
Expected: FAIL lines for `apply …` (unknown command), ending `SOME FAILED`.

- [ ] **Step 3: Write the implementation**

Insert into `functions/tmux-categorize.fish` immediately after `__tcz_popup_read_keys`:

```fish
function __tcz_popup_apply_keys --argument-names sel n --description 'pure: reduce a key-token burst -> "<newsel>\n<action>" (action = nav|enter|cancel|kill); nav clamps 0..n-1'
    set -e argv[1..2]                 # remaining argv = tokens
    set -l s $sel
    set -l action nav
    for k in $argv
        switch $k
            case up
                test $s -gt 0; and set s (math $s - 1)
            case down
                test $s -lt (math $n - 1); and set s (math $s + 1)
            case enter
                set action enter; break
            case cancel
                set action cancel; break
            case kill
                set action kill; break
            case '*'
                # 'other' -> ignore
        end
    end
    printf '%s\n%s\n' $s $action
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-popup.fish`
Expected: all `apply …` lines `ok`; file ends `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "feat(picker): pure __tcz_popup_apply_keys nav/action reducer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewire `__tcz_popup` loop to burst-read; remove `__tcz_popup_readkey`

**Files:**
- Modify: `functions/tmux-categorize.fish` — the `__tcz_popup` `while true` loop (lines 944-972); delete `__tcz_popup_readkey` (lines 698-736).
- Test: `tests/test-tmux-popup.fish` — replace the 8 `__tcz_popup_readkey` tests (lines 177-184) with loop-wiring structural assertions.

**Interfaces:**
- Consumes: `__tcz_popup_read_keys` (Task 2), `__tcz_popup_apply_keys` (Task 3).
- Produces: nothing new (behavior-preserving rewrite of the loop).

- [ ] **Step 1: Write/replace the tests**

In `tests/test-tmux-popup.fish`, delete the 8 lines currently at 177-184 (the `__tcz_popup_readkey …` block — its coverage now lives in the `parse_keys` and `read_keys` blocks) and the 3-line comment above them (173-176). Replace that block with:

```fish
# ---------------------------------------------------------------------
# __tcz_popup loop wiring — consumes bursts via read_keys + apply_keys,
# and the byte-by-byte __tcz_popup_readkey is gone.
# ---------------------------------------------------------------------
set -g POPUP_SRC (functions __tcz_popup | string collect)
t "loop uses read_keys"  yes (string match -q '*__tcz_popup_read_keys*'  -- "$POPUP_SRC"; and echo yes; or echo no)
t "loop uses apply_keys" yes (string match -q '*__tcz_popup_apply_keys*' -- "$POPUP_SRC"; and echo yes; or echo no)
t "old readkey removed"  yes (functions -q __tcz_popup_readkey; and echo no; or echo yes)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-popup.fish`
Expected: `loop uses read_keys`/`loop uses apply_keys` FAIL (loop still calls `__tcz_popup_readkey`), and `old readkey removed` FAIL (still defined). Ends `SOME FAILED`.

- [ ] **Step 3: Rewire the loop**

In `functions/tmux-categorize.fish`, replace the entire `while true … end` loop (lines 944-972) with:

```fish
    while true
        __tcz_popup_draw $sel $listw $prevw $rows "$current" -- $model
        set -l act (__tcz_popup_apply_keys $sel $n (__tcz_popup_read_keys))
        set sel $act[1]
        switch $act[2]
            case enter
                set result (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
                break
            case kill
                # x: confirm on the bottom row, then kill + refresh the list
                set -l target (string split -m 1 $TAB -- $model[(math $sel + 1)])[1]
                if test -n "$target"
                    printf '\e[%s;1H\e[K\e[1;38;5;208m  kill %s ?  (y/n)\e[0m' $rows "$target"
                    set -l ans ''
                    dd bs=1 count=1 2>/dev/null | od -An -tx1 | string trim | read ans
                    if test "$ans" = 79; or test "$ans" = 59   # y / Y
                        tmux kill-session -t "=$target" 2>/dev/null
                        set model (__tcz_overview)
                        set n (count $model)
                        test $n -gt 0; or break
                        test $sel -ge $n; and set sel (math $n - 1)
                    end
                end
            case cancel
                break
            # 'nav' -> sel already updated above; loop redraws once
        end
    end
```

- [ ] **Step 4: Remove `__tcz_popup_readkey`**

In `functions/tmux-categorize.fish`, delete the whole `__tcz_popup_readkey` function (its `function __tcz_popup_readkey … end`, originally lines 698-736). Its byte-parsing behavior is fully covered by `__tcz_popup_parse_keys` (Task 1) and exercised through `__tcz_popup_read_keys` (Task 2).

- [ ] **Step 5: Run the popup suite to verify it passes**

Run: `fish tests/test-tmux-popup.fish`
Expected: the 3 `loop …` / `readkey removed` assertions `ok`; file ends `ALL PASS`.

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: every suite ends `ALL PASS` (8 suites).

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-popup.fish
git commit -m "refactor(picker): coalesce read/draw loop; drop per-key __tcz_popup_readkey

__tcz_popup now reads one input burst per iteration (read_keys), applies
all nav deltas at once (apply_keys), and redraws + captures preview once
per burst instead of per keystroke. Removes the ~8-fork-per-key byte reader.
Behavior is unchanged; arrow lag under host load is gone.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual smoke (runtime-only — after the user's `fisher update`)

Not automatable in the pure suite (needs a tty + live tmux). The user validates after deploying:

- Open the picker (`prefix S` / `Opt+s`); **hold ↓** through a long session list → the selection tracks smoothly and lands where released; the preview updates once at the end (not one lag-step per row).
- `Enter` switches to the highlighted session; `q` / `Esc` cancel instantly; `x` → `y` kills with the `kill <name>? (y/n)` confirm and refreshes; `x` → `n` leaves it.
- `j` / `k` still move; SS3-mode terminals (application-cursor-keys) still navigate.
- Under a load burst, arrow response is noticeably snappier than before.

---

## Self-Review

**Spec coverage:**
- Loop restructure (cost scales with bursts) → Task 4. ✓
- Pure `__tcz_popup_parse_keys` → Task 1. ✓
- Thin `__tcz_popup_read_keys` (one chunked read + completion) → Task 2. ✓
- Behavior preservation (all keys, kill confirm, bare-Esc disambiguation) → preserved in Task 4 loop + Task 1 parser + Task 2 completion read; asserted across parse/read/apply tests. ✓
- Testing plan (pure parser + pipe-fed reads + migrated readkey tests) → Tasks 1-4. ✓
- Isolation invariant (no live tmux in tests) → all tests pure/pipe-fed. ✓
- Refinements beyond the spec's "two functions": `__tcz_popup_apply_keys` and `__tcz_popup_hex_dangling` are extracted purely to make the loop's nav logic and the completion trigger unit-testable — serving the spec's stated "pure, unit-tested" goal. ✓

**Placeholder scan:** none — every step has concrete code/commands and expected output.

**Type/name consistency:** `__tcz_popup_parse_keys`, `__tcz_popup_hex_dangling`, `__tcz_popup_read_keys`, `__tcz_popup_apply_keys` used identically across definition, tests, and the loop. `apply_keys` returns two lines consumed as `$act[1]`/`$act[2]`. Token vocabulary (`up/down/enter/cancel/kill/other`) and action vocabulary (`nav/enter/cancel/kill`) are consistent throughout.
