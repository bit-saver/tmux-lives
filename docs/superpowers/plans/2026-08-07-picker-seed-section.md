# Picker Seed Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the seed editor into the theme picker as a permanent section, make the popup height adapt to the client so you see far more schemes, and regenerate the cursor's scheme live as the seed moves.

**Architecture:** The popup opens at a percentage height instead of a fixed 26 rows; the picker reads `stty size` and derives one quantity, `WIN = rows - STATIC`. The seed editor stops being a separate full-screen takeover and becomes an 8-row section of the main frame, fixed-height whether idle or editing so the list never jumps. Live regeneration is split by cost: one palette (~40 ms) updates immediately, the full batch (310–800 ms) waits for input to settle.

**Tech Stack:** fish shell; tmux 3.3a (rocket) / 3.7b (macwork); tests are fish scripts driven by a `t` assertion helper.

**Spec:** `docs/superpowers/specs/2026-08-07-picker-seed-section-design.md`

## Global Constraints

- **The gate is 8 suites printing `ALL PASS` under BOTH `fish` and `fish --no-config`.** Run in the FOREGROUND, never backgrounded:
  `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'`
- Baseline before this plan: `test-tmux-install.fish` at **632 (plain) / 631 (--no-config)**. The 1-count delta is BY DESIGN — never "fix" it.
- `tests/test-tmux-popup.fish` has one timing assertion that can flake under machine load. Re-run before treating it as real.
- **Every assertion must be shown FAILING before you implement.** State the observed failure. Distinguish **fix-discriminators** (must fail pre-change) from **non-regression guards** (correctly pass at both ends) — do not call the latter vacuous, and do not claim the former passed when it did not.
- **An undefined function as a DIRECT argument inside a `t` call aborts the whole statement** — nothing prints and a suite with no pass counter still reports ALL PASS. Capture into a variable first, and give every new function a `functions -q` existence assertion.
- `$catfile` is `set -l` and exists ONLY in `tests/test-tmux-categorize.fish` (definitions around lines 1407, 1520, 2229). A guard above a definition — or in the install suite, where it does not exist — expands to an empty path and passes vacuously.
- An awk range that matches nothing yields an empty string; assert extractions are non-empty.
- Test guards grep source text and **match COMMENTS too**. Never spell a banned shape in a comment.
- The picker runs under `fish --no-config`, which neither reads nor writes universals. Keep universal access to config-loaded `fish -c` children at action sites only — never in the per-keypress path.
- Do NOT deploy: never modify `~/.config/fish/`, `~/.tmux.conf`, or `~/.config/tmux/tmux-lives.conf`.
- No new file in `conf.d/` or `functions/`.
- **Popup geometry: `-w 52 -h 85%`.** Width stays 52 everywhere. `STATIC = 22` once the seed section exists (15 today − 1 replaced seed row + 8).

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `functions/tmux-categorize.fish` | picker builders + interactive loop | 1, 3, 4, 5, 6 |
| `conf.d/tmux-lives-install.fish` | the `M-k` bind and the `setup theme` open site | 1 |
| `tests/test-tmux-categorize.fish` | picker assertions incl. the frame proof | 1, 3, 4, 5, 6 |
| `tests/test-tmux-install.fish` | fragment/bind assertions | 1 |
| `README.md`, `CLAUDE.md` | docs | 7 |

---

### Task 1: Height-adaptive frame

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker` (`set -l WIN 11` at ~1913, the docstring at 1595, the `M-m k` open site at ~1085)
- Modify: `conf.d/tmux-lives-install.fish` — the `M-k` bind (~190), the `setup theme` no-arg open (~990)
- Test: `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: the picker derives `WIN` from its own popup height. The draw emits exactly `rows` lines for a popup of `rows` rows. `STATIC` is **15** after this task (the seed section arrives in Task 3 and raises it to 22).

**Why a percentage and not a bigger fixed number:** measured on 3.3a, a popup taller than the client does not clamp — it prints `height too large` and **does not open at all**. A fixed 40 would break the picker outright on any shorter window. A percentage always fits.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, near the other fragment-bind assertions:

```fish
# --- Task 1: the picker opens at a percentage height, not a fixed 26 ----------
# A popup taller than the client FAILS to open on tmux 3.3a ("height too large") —
# it does not clamp. So the height must be a percentage, which always fits.
set -g FRAGH (__tmux_lives_render_fragment /x/cat.fish S M-s '' 0 M-m M-t M-r C-M-a C-M-s block M-k mono bar derived 0 'xterm*' | string collect)
t "theme-picker bind uses a percentage height" yes (string match -q '*-w 52 -h 85%*' -- "$FRAGH"; and echo yes; or echo no)
t "theme-picker bind no longer pins 26 rows" no (string match -q '*-w 52 -h 26*' -- "$FRAGH"; and echo yes; or echo no)
```

In `tests/test-tmux-categorize.fish`, **below** a `set -l catfile` definition:

```fish
# --- Task 1: WIN is derived from the popup height ------------------------------
set -g WINSRC (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$WINSRC"; and echo 1; or echo 0)
t "picker no longer hardcodes a window size" 0 (string match -ra 'set -l WIN 11' -- "$WINSRC" | count)
t "picker reads its own popup size" 1 (string match -qr 'stty size' -- "$WINSRC"; and echo 1; or echo 0)
t "no open site still pins 26 rows" 0 (grep -c -- '-w 52 -h 26' $catfile)
```

- [ ] **Step 2: Run both suites and confirm the right things fail**

Run: `fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -6` and `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -8`

Expected: all four content assertions FAIL (`got [no]`, `got [yes]`, `got [1]`, `got [0]`, `got [1]`). `picker body extraction is non-empty` must PASS — if it fails, the awk range is wrong and every guard under it is meaningless.

- [ ] **Step 3: Derive WIN from the popup's own size**

Replace `set -l WIN 11` (~1913):

```fish
    # The popup opens at a PERCENTAGE height, because a popup taller than the client
    # does not clamp on tmux 3.3a — it refuses to open. So the picker cannot know its
    # height in advance and must ask. `stty size` reports the popup's real dimensions
    # ($LINES/$COLUMNS are not exported into a popup). One derived quantity; every
    # other measurement in this function stays fixed.
    set -l STATIC 15
    set -l dims (stty size 2>/dev/null | string split ' ')
    set -l rows 26
    test (count $dims) -ge 1; and test -n "$dims[1]"; and set rows $dims[1]
    set -l WIN (math "$rows - $STATIC")
    if test $WIN -lt 3
        # Too short to draw a usable list. Say so plainly rather than rendering a
        # frame that overflows and scrolls its own top border away.
        printf '\e[2J\e[H tmux-lives: window too short for the theme picker\n (needs %s rows, has %s)\n' (math "$STATIC + 3") $rows
        stty $saved 2>/dev/null
        return 0
    end
```

- [ ] **Step 4: Change the three open sites to a percentage**

`conf.d/tmux-lives-install.fish` (~190 and ~990) and `functions/tmux-categorize.fish` (~1085): replace `-w 52 -h 26` with `-w 52 -h 85%` in all three.

- [ ] **Step 4b: Pad the scheme window so the frame always fills the popup**

⚠️ **Without this the frame does not equal the popup height and Step 5's assertions cannot pass.** `__tcz_thp_window` returns `"0 <total>"` when `total <= winsize` (`functions/tmux-categorize.fish:1461-1462`) and the draw loop emits exactly `count` rows with no padding. Measured: `__tcz_thp_window 34 36 37` → `0 36`. So with a window LARGER than the list, the frame comes out short by `WIN - total`.

Today this is invisible because `WIN` is 11 and the list is always 14 or 36. Once `WIN` is derived it routinely exceeds the list: on the user's 62-row client `-h 85%` is 52 rows, so `WIN` is 30 (37 before the seed section lands) against a 14-row collapsed list.

Two consequences, the second worse than the first: the box stops short of the popup bottom, and pressing `m` GROWS the box by 16 rows — a bigger visual jump than the seed-zone jump Task 3 is specifically designed to prevent.

Fix in the **draw loop**, after the scheme-row `for`: emit `WIN - count` blank framed rows (`__tcz_thp_ln '' $IW $BORDER $RST`). Do **not** change `__tcz_thp_window` — it is a pure builder whose short-list contract is pinned by `tests/test-tmux-categorize.fish:1686` (`"0 5"` for `0 5 8`), and other assertions depend on it.

This makes "the draw emits exactly `rows` lines" true in every state, which is exactly what the frame proof asserts.

- [ ] **Step 5: Make the frame proof parametric**

`__t9_frame_rows` currently hardcodes `set -l WIN 11` and every assertion expects 26. Give it a `rows` parameter, set `WIN` to `rows - 15` inside it, and assert the draw emits exactly `rows`:

```fish
t "frame: emits exactly its height — 26 rows (today's size)" 26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26)
t "frame: emits exactly its height — 39 rows"                39 (__t9_frame_rows list 0 35 0 1 mono "$PAL9" '' 1 14 39)
t "frame: emits exactly its height — 52 rows"                52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52)
t "frame: emits exactly its height — 18 rows (the floor)"    18 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 18)
```

- [ ] **Step 6: Re-prove the frame proof is still sensitive**

Inject one extra `set -a lines` into the draw block, run the frame assertions, confirm EVERY size reports one too many (27/40/53/19), then revert and confirm the counts return. A parametric proof that only catches the 26 case is worse than the constant one it replaced. Report what you observed at each size.

- [ ] **Step 7: Update the picker docstring**

The docstring at 1595 states `-w 52 -h 26` and "EXACTLY 26 rows (15 static + an 11-row scheme window)". Restate it as a percentage height with a derived window.

- [ ] **Step 8: Run the full gate and commit**

```bash
git add functions/tmux-categorize.fish conf.d/tmux-lives-install.fish tests/
git commit -m "feat(picker): derive the scheme window from the popup height"
```

---

### Task 2: Emit the tab colour on preview and cancel

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker`'s `case a` sites and `case cancel`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_recolor <color> [dedup]` (existing).

**The defect, measured:** `__tcz_theme_picker` contains **zero** calls to `__tcz_recolor`. Previewing sets `@tmux_lives_tabs_color` but nothing emits the OSC; only the 15-second status tick does, via `__tcz_tab_color`. So the ShellFish/iTerm2 tab lags up to 15 s behind in both directions, and after ESC the bar shows your real scheme while the tab still shows the abandoned one. **Force mode, not dedup** — the dedup cache would suppress a restore that returns to a previously-emitted value.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 2: preview and cancel emit the tab OSC directly -----------------------
# Without this the tab lags the status bar by up to one status-interval (15s) in
# BOTH directions, so ESC appears not to restore. Force mode, not dedup: the dedup
# cache would suppress a restore that returns to an already-emitted value.
set -g PB2 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB2"; and echo 1; or echo 0)
t "picker emits the tab colour on preview/cancel" yes (string match -qr '__tcz_recolor' -- "$PB2"; and echo yes; or echo no)
t "picker's recolor calls are force, not dedup" 0 (string match -ra '__tcz_recolor[^\n]*dedup' -- "$PB2" | count)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `picker emits the tab colour on preview/cancel => got [no]`. The extraction and the dedup guards PASS already (there are no calls at all yet) — the dedup one is a non-regression guard, not a discriminator.

- [ ] **Step 3: Emit after each apply-preview and after the cancel restore**

After each of the three `case a` apply-live sites, and after the `case cancel` restore, resolve the effective tab colour and emit it:

```fish
                    set -l tabhex (__tcz_tab_color '')
                    test -n "$tabhex"; and __tcz_recolor "$tabhex"
```

`__tcz_tab_color` reads the live `@tmux_lives_tabs_color`, which the apply-live call has just set — so this must come AFTER it, not before.

- [ ] **Step 4: Run the full gate and commit**

```bash
git commit -m "fix(picker): emit the tab colour on preview and cancel instead of waiting for the tick"
```

---

### Task 3: The seed section (idle state)

**Files:**
- Modify: `functions/tmux-categorize.fish` — new pure builder beside the other `__tcz_thp_*` builders; the draw block; `STATIC` from Task 1
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_thp_seedzone <w> <hex> <hue> <L> <C> <editing> <chan> <r> <g> <b>` → exactly 8 lines, each exactly **`w` + 2** visible columns. `editing` = 0 renders three readout rows; `editing` = 1 renders three R/G/B bars (Task 4 uses that path).
- `STATIC` becomes **22**.

**Why `w` + 2 and not `w`:** every row of this frame carries its own border glyphs. `__tcz_thp_zsep` prints `├` + `w` cols + `┤`, and `__tcz_thp_ln` prints `│` + content padded to `w` + `│` — both `w + 2` visible columns. So the seed zone returns **fully-framed** rows: row 1 is a `__tcz_thp_zsep`, rows 2–8 are content wrapped in `__tcz_thp_ln` inside the builder. The draw then appends all 8 verbatim with no further wrapping, and the existing `configuration` zsep at ~1982 is what row 1 replaces. Measure at `w` = 50 and expect **52**.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 3: the seed zone ------------------------------------------------------
# FIXED height whether idle or editing, so toggling edit mode never makes the
# scheme list jump. Idle shows readouts in the three rows that become sliders.
t "seedzone exists" 0 (functions -q __tcz_thp_seedzone; echo $status)
set -g SZ (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 0 1 95 119 43)
t "seedzone is exactly 8 rows" 8 (count $SZ)
for i in (seq 8)
    set -l v (string replace -ra '\x1b\[[0-9;]*m' '' -- "$SZ[$i]")
    # w + 2: the border glyphs are part of every row in this frame.
    t "seedzone row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
t "seedzone shows the hex when idle" yes (string match -q '*5f772b*' -- (string join ' ' $SZ); and echo yes; or echo no)
# The anti-jump property: editing must not change the row count.
set -g SZE (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 1 95 119 43)
t "seedzone is 8 rows while editing too" 8 (count $SZE)
t "editing renders bars, idle does not" yes (test "$SZ[6]" != "$SZE[6]"; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `seedzone exists => got [1]`, then the dependent assertions abort or fail. Add an empty stub, re-run, and confirm the row-count and width assertions now fail with REAL values rather than aborting — that proves they are live.

- [ ] **Step 3: Implement the builder**

Reuse the existing builders rather than re-deriving them: `__tcz_thp_swatch` already renders a 4-line colour band with readouts, and `__tcz_thp_slider <label> <value> <selected>` already renders one 32-cell channel bar at a fixed 39 visible columns. Read both before writing anything.

**The row inventory is the contract — all 8 rows, in order:**

| row | idle (`editing` = 0) | editing (`editing` = 1) |
|---|---|---|
| 1 | zone separator, label `seed` | same |
| 2–5 | colour band (4 rows) for `<hex>` | same |
| 6 | `#rrggbb` | R bar, selected iff `chan` = 1 |
| 7 | `hue <hue>° · L <L>` | G bar, selected iff `chan` = 2 |
| 8 | `chroma <C>` | B bar, selected iff `chan` = 3 |

Rows 1–5 are identical in both states; only 6–8 differ. That is what makes the section fixed-height and the list jump-free, and it is what the anti-jump assertion checks.

Measure with `string length --visible`, which discounts SGR escapes — a plain `string length` counts them and will be wrong.

**Rows 2–8 ALL need padding, not just 6–8.** Measured at `w` = 50: `__tcz_thp_swatch` returns rows of **21 / 46 / 40 / 39** visible columns and `__tcz_thp_slider` is fixed at **39**. None of them reaches 50. Pad each to `w` and then wrap it in `__tcz_thp_ln`, which pads to `w` itself and adds the borders — so passing it short content is safe and the explicit pad is belt-and-braces. Do **not** change either builder's own width; other callers depend on both.

- [ ] **Step 4: Wire it into the draw and raise STATIC**

Replace the single `__tcz_thp_seedrow` call in the draw with the 8-row zone, and change `set -l STATIC 15` to `set -l STATIC 22`.

- [ ] **Step 5: Extend the frame proof for the new static count**

The frame proof asserts the draw emits exactly `rows`. With STATIC now 22 that still holds, but the harness's own `WIN` derivation must move from `rows - 15` to `rows - 22`, and the floor case changes from 18 to 25. Update both, re-run at 26/39/52/25, and re-inject the extra row to confirm sensitivity at each.

- [ ] **Step 6: Run the full gate and commit**

```bash
git commit -m "feat(picker): the seed becomes a permanent 8-row section"
```

---

### Task 4: Edit mode

**Files:**
- Modify: `functions/tmux-categorize.fish` — the key dispatch in `__tcz_theme_picker`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_seedzone`'s `editing`/`chan`/`r`/`g`/`b` parameters from Task 3.

**Behaviour:** `b` toggles edit mode. In edit mode `←→` moves the selected channel by ±8 (drain-coalesced, as the existing sliders are), `↑↓` selects the channel, `⏎` keeps the change, `esc` reverts to the seed the picker opened with and leaves edit mode **without closing the picker**. Outside edit mode `↑↓` still moves the scheme cursor. `b` is ignored while focus is on the second list.

⚠️ **The drain loop must re-assert `stty min 0 time $gap` INSIDE each iteration.** `__tcz_popup_readkey`'s CSI branch leaves the tty blocking on return, and a drain read after it will hang. This has been hit for real. Also: do NOT escalate `gap` on the arrow arm — a poll that never times out means the loop never yields to a redraw, which produced a stall that took a pty harness to find.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 4: edit mode ----------------------------------------------------------
set -g PB4 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB4"; and echo 1; or echo 0)
t "b toggles an edit mode" yes (string match -qr 'set editing' -- "$PB4"; and echo yes; or echo no)
t "arrows are mode-dependent" yes (string match -qr 'test "\$editing" = 1' -- "$PB4"; and echo yes; or echo no)
# The esc-in-edit-mode arm must clear the mode WITHOUT leaving the loop. Bound the
# grep to the arm itself: an unanchored multiline pattern over a 700-line body
# matches something the moment edit mode exists at all and proves nothing.
# Anchor on the two unique markers the implementation must place around it.
set -g ESCARM4 (string match -r 'BEGIN edit-esc(.|\n)*?END edit-esc' -- "$PB4")
t "edit-esc arm is uniquely anchored and non-empty" 1 (test -n "$ESCARM4"; and echo 1; or echo 0)
t "edit-esc arm clears the mode" 1 (string match -ra 'set editing 0' -- "$ESCARM4" | count)
t "edit-esc arm does not break the loop" 0 (string match -ra '\bbreak\b' -- "$ESCARM4" | count)
# The drain-hang guard is load-bearing and has been hit for real.
set -g DR4 (string match -ra 'stty min 0 time' -- "$PB4" | count)
t "drain loops re-assert non-blocking mode" yes (test $DR4 -ge 2; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: the three edit-mode assertions fail. The drain guard's status depends on the existing loops — record which it is and treat it accordingly (discriminator vs non-regression guard).

- [ ] **Step 3: Add the mode and route the arrows**

Add `set -l editing 0` and `set -l chan 1` beside the other picker locals. In the dispatch, branch `up`/`down`/`left`/`right` on `$editing`. Add `case b` to toggle it (ignored when `focus` is `state`). In edit mode, `⏎` clears `editing` and keeps the value; `esc` restores the opening seed and clears `editing` **without `break`**.

Wrap the esc-in-edit-mode branch in the two comment markers the test anchors on, so the guard is bounded to that arm rather than the whole function body:

```fish
                # BEGIN edit-esc
                # Leaves edit mode only — the picker stays open. No break here:
                # esc while editing reverts the seed, it does not close the picker.
                ...
                # END edit-esc
```

- [ ] **Step 4: Verify the arrows do not leak between modes**

Manually confirm by inspection that no arrow path can both move the scheme cursor and change a channel in the same keypress, and that `esc` in edit mode cannot reach the loop's `break`.

- [ ] **Step 5: Run the full gate and commit**

```bash
git commit -m "feat(picker): b toggles seed edit mode; arrows follow the mode"
```

---

### Task 5: Typed hex from edit mode

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_hexentry`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- `t` while in edit mode opens the typed-hex editor; on exit it returns to edit mode, not to a separate screen.

**This is the one screen that still draws its own full frame**, so it is the one place that must GAIN a border rather than inherit one. It currently clears the popup with `\e[2J` and prints bare rows inside a `-B` (borderless) popup — content floating on the user's scrollback, which is the defect this whole change exists to remove.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 5: typed hex is framed ------------------------------------------------
# The picker opens with display-popup -B, so tmux draws NO border; every screen
# must draw its own or it floats on the scrollback.
set -g HB5 (awk '/function __tcz_thp_hexentry/,/^    end$/' $catfile | string collect)
t "hexentry body extraction is non-empty" 1 (test -n "$HB5"; and echo 1; or echo 0)
t "hexentry draws its own border" yes (string match -qr '╭|╰' -- "$HB5"; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `hexentry draws its own border => got [no]`.

- [ ] **Step 3: Frame the typed-hex screen**

Draw the same `╭─╯` frame the main picker uses, at the same width, around the existing content. Reuse `__tcz_thp_ln` and `__tcz_theme border` rather than hand-rolling glyphs.

- [ ] **Step 4: Return to edit mode on exit**

On `⏎` or `esc`, return to the picker with `editing` still 1, so `t` reads as a detour within edit mode rather than a separate destination.

- [ ] **Step 5: Run the full gate and commit**

```bash
git commit -m "fix(picker): frame the typed-hex screen; return to edit mode"
```

---

### Task 6: Live regeneration

**Files:**
- Modify: `functions/tmux-categorize.fish` — the edit-mode channel handler and `__tcz_thp_reload`
- Test: `tests/test-tmux-categorize.fish`

**Measured costs — this split exists because of them:** one palette ~40 ms; 14 rows ~310–400 ms; 35 rows ~700–800 ms. Per-keystroke full regeneration is not affordable.

**Behaviour:** on each channel change, recompute ONLY the colour square, the preview bar, and the cursor's own scheme row (~40 ms). When input settles, re-render the remaining visible strips.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 6: live regeneration is scoped to one palette -------------------------
# A full batch is 310-800ms; one palette is ~40ms. The per-keystroke path must
# compute ONE palette, not call the batch reload.
set -g EB6 (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "picker body extraction is non-empty" 1 (test -n "$EB6"; and echo 1; or echo 0)
# Count call sites rather than pattern-matching across lines. A multiline regex over
# a 700-line body is fragile and hard to prove non-vacuous; a count is neither. The
# picker had exactly 2 palette calls (the batch reload and the anchor); the live
# channel path adds a third, and it must be a DIRECT call, not another reload.
t "picker now has exactly 3 palette call sites" 3 (string match -ra '__tmux_lives_theme_palette ' -- "$EB6" | count)
# Perf fence: one palette must stay well under a redraw budget.
set -g T6A (date +%s%N)
__tmux_lives_theme_palette '#5f772b' amber bar derived 0 >/dev/null
set -g T6B (date +%s%N)
t "one palette is under 150ms" yes (test (math "($T6B - $T6A) / 1000000") -lt 150; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `picker now has exactly 3 palette call sites => got [2]` — the picker has exactly two today (`functions/tmux-categorize.fish:1682` and `:1891`). The perf fence PASSES already — it is a non-regression guard against the palette getting slower, not a discriminator.

⚠️ **An existing guard collides with this task and must be updated, not worked around.** `tests/test-tmux-categorize.fish:2277` asserts `consolidated guard: exactly 2 palette call sites`. Adding the live path makes it 3. Change the expected value to 3 — do NOT relax the assertion to a lower bound, and do not delete it. This repo has previously shipped a `>=` bound that passed against pre-change data and hid a real composition change; an exact count is the point of that guard.

⚠️ **That guard's pattern constrains how you write the new call.** It matches `__tmux_lives_theme_palette \$` — the argument immediately after the space must start with `$`. A call whose first argument is a literal (`__tmux_lives_theme_palette "#5f772b" …`) would NOT be counted, so the guard would still read 2 and your update to 3 would fail. Pass the seed through a variable, as both existing call sites do.

- [ ] **Step 3: Recompute one palette on each channel change**

In the edit-mode channel handler, after updating the channel value: recompute the seed hex, recompute the cursor row's palette with `__tmux_lives_theme_palette` (5 args), and repaint the seed zone, preview bar and cursor row. Do NOT call `__tcz_thp_reload`.

- [ ] **Step 4: Batch-reload on settle**

Reuse the existing drain loop's timeout: when a drain iteration times out (input has settled), call `__tcz_thp_reload` once so the remaining strips catch up. The reload cache is keyed on the seed, so a changed seed correctly misses and recomputes.

- [ ] **Step 5: Confirm it does not regress held-arrow behaviour**

The existing arrow handling rate-limits with discard rather than summing. Confirm a held channel key still yields one visible step per render cycle and stops dead on release. If you cannot verify this without a pty, say so rather than claiming it.

- [ ] **Step 6: Run the full gate and commit**

```bash
git commit -m "feat(picker): regenerate the cursor's scheme live as the seed moves"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (the picker subsection), `CLAUDE.md`

- [ ] **Step 1: Update the README picker subsection**

Document the seed section, `b` for edit mode and its key semantics, that the popup height now adapts (so the number of visible schemes depends on your terminal), and that the typed-hex path is reached with `t` from edit mode. Update the key legend to match what ships.

- [ ] **Step 2: Add the CLAUDE.md paragraph**

Record: the percentage-height decision and **why** (a too-tall popup fails to open rather than clamping — the fact that forces it); `STATIC = 22` and the derived `WIN`; the seed zone's fixed height as the anti-jump property; the measured palette costs that force the live/settle split; and the tab-OSC defect with its 15-second symptom.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: record the picker seed section and height-adaptive frame"
```

---

## Final verification

- [ ] Full gate: 8 `ALL PASS` in BOTH modes; record final counts and confirm the plain/`--no-config` delta is still exactly 1.
- [ ] Frame proof sensitivity re-proven at every size tested, not just one.
- [ ] `fish -c 'set -U | string match "tmux_lives_*"'` — no universal leaked.
- [ ] Nothing deployed: `~/.config/fish/`, `~/.tmux.conf` and `~/.config/tmux/tmux-lives.conf` untouched.
