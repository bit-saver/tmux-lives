# Picker Legibility and Auto-apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a scheme's colours readable at a glance, give the seed editor room, and apply a scheme automatically once the cursor settles on it.

**Architecture:** The swatch strip stops being seven equal cells and becomes six roles sized by measured on-screen area, with a blank column marking the trim tier. The seed zone stops being fixed-height and becomes 3 rows idle / 8 editing, which turns `STATIC` from a constant into a function of mode. Auto-apply hangs off the timed-poll branch that already defers the seed batch.

**Tech Stack:** fish shell; tmux 3.3a (rocket) / 3.7b (macwork); tests are fish scripts driven by a `t` assertion helper.

**Spec:** `docs/superpowers/specs/2026-08-08-picker-legibility-and-autoapply-design.md`

## Global Constraints

- **The gate is 8 suites printing `ALL PASS` under BOTH `fish` and `fish --no-config`.** Run it in the FOREGROUND and **pass an explicit `timeout: 300000`** — the 16-run gate exceeds the Bash tool's 120s default, which auto-backgrounds it and has stalled three agents on this project:
  `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'`
- Baseline before this plan: 8/8 both modes, `test-tmux-install.fish` at **635 (plain) / 634 (--no-config)**. The 1-count delta is BY DESIGN — never "fix" it.
- `tests/test-tmux-popup.fish` has one wall-clock assertion that fails on a loaded machine. This plan never touches the function it measures. Re-run rather than investigate. **Check `uptime` before trusting any timing measurement** — a runaway once put this box at load 76 and invalidated a whole round of them.
- **Every assertion must be shown FAILING before you implement.** State the observed failure text. Distinguish fix-discriminators from non-regression guards; do not call the latter vacuous.
- **Prefer behavioural assertions over source-text greps.** Three consecutive reviews on the previous branch found greps that proved nothing: three had gone silently vacuous, nine survived five real breakages, and one feature died from a single deleted line with the whole gate green.
- **Anchor every extraction on stable content, never absolute line numbers, and assert it non-empty first.** Check the inverse too: a terminator that never matches captures through EOF — non-empty but wrong. `functions <name> | string collect` is the structurally safe form for a whole function body.
- **An undefined function used as a DIRECT argument inside a `t` call aborts the whole statement** — nothing prints, and `test-tmux-categorize.fish` has no pass counter, so it still reports ALL PASS. A RED phase can be entirely fictional. Capture into a variable first.
- **Test guards here grep source text and match COMMENTS too.** Never spell a banned shape in a comment. Tripped nine times in this repo, twice on the last branch, once by the plan author.
- fish gotchas, each of which has caused a real defect here: a zero-output command substitution used as a bare argument VANISHES rather than passing empty, shifting later positionals; `string repeat -n 0` emits nothing, which silently deleted a border row; `eval` not `source` for extracted blocks, because `source` opens its own local scope.
- Measure widths with `string length --visible`. Plain `string length` counts SGR escapes and will be wrong.
- Do NOT deploy: never touch `~/.config/fish/`, `~/.tmux.conf`, or `~/.config/tmux/tmux-lives.conf`. The user deploys via `fisher update`.
- **Do not run a filesystem-wide scan** (`find /`, `grep -r /`). Two CIFS mounts park such a scan in uninterruptible I/O; one recently crippled this server. Scope every search to the repo.
- No new files in `conf.d/` or `functions/`.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `functions/tmux-categorize.fish` | every picker builder and the interactive loop | 1, 2, 3, 4, 5, 6 |
| `conf.d/tmux-lives-install.fish` | the `window-status-current-format` line | 6 |
| `tests/test-tmux-categorize.fish` | picker assertions, the frame proof | 1, 2, 3, 4, 5, 6 |
| `tests/test-tmux-install.fish` | fragment assertions | 6 |
| `README.md`, `CLAUDE.md` | docs | 7 |

---

### Task 1: Swatch strip weighted by area

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_cells` (1238), `__tcz_thp_band` (1251), `__tcz_thp_row` docstring (1260), `__tcz_thp_staterow` (1276)
- Test: `tests/test-tmux-categorize.fish` (existing width assertions at 1361-1372)

**Interfaces:**
- Produces: `__tcz_thp_cells <hexes>` → **15** visible columns from the same 7-hex input. `__tcz_thp_band <hex>` → 15 visible columns. Both unchanged in signature.

**The mapping.** Input stays the engine's palette order, `bar sep tabs active windows cap text` (fish indices 1-7). Output is ordered by measured on-screen area, drops `active`, and carries a blank tier column:

| output position | palette index | role | cells |
|---|---|---|---|
| 1 | 3 | `tabs` | 5 |
| 2 | 1 | `bar` | 4 |
| 3 | 6 | `cap` | 2 |
| 4 | — | blank | 1 |
| 5 | 5 | `windows` | 1 |
| 6 | 2 | `sep` | 1 |
| 7 | 7 | `text` | 1 |

`tabs` leads because it covers roughly 1.8× the area of `bar` on the user's screen. `active` is dropped because `@tmux_lives_active_fg` is pushed on every apply and no format string reads it — Task 6 wires it and adds its cell back.

⚠️ **The existing `▇`-count assertion will pass unchanged and prove nothing.** Inked cells go 14 → 14 (5+4+2+1+1+1), because the fifteenth column is the blank gap. Only the *width* moves. Assert width and per-role runs; do not lean on the glyph count.

- [ ] **Step 1: Write the failing tests**

Replace the four existing assertions at `tests/test-tmux-categorize.fish:1361-1368` and add the new ones:

```fish
set -l CELLS (__tcz_thp_cells '#112233 #223344 #334455 #445566 #556677 #667788 #778899')
t "cells is 15 visible cols" 15 (string length --visible -- "$CELLS")
# Inked cells stay 14 (5+4+2+1+1+1) because the 15th column is the tier gap,
# so this count CANNOT discriminate the change. Kept only as a non-regression
# guard that the seven-eighths glyph is still what draws a cell.
t "cells still uses the seven-eighths block" 14 (count (string match -ra '▇' -- "$CELLS"))
t "cells degrades non-hex to blanks" 15 (string length --visible -- (__tcz_thp_cells '#112233 nope #334455 #445566 #556677 #667788 #778899'))
set -l BAND (__tcz_thp_band '#112233')
t "band is 15 visible cols" 15 (string length --visible -- "$BAND")
t "band blank fallback is 15 visible cols" 15 (string length --visible -- (__tcz_thp_band nope))

# --- ordering and widths, asserted on the RENDERED strip -----------------------
# Each role gets a distinguishable colour so a run length is unambiguous.
# Order is by on-screen area: tabs bar cap · gap · windows sep text.
set -g W1 (__tcz_thp_cells '#010101 #020202 #030303 #040404 #050505 #060606 #070707')
set -g W1V (__tcz_strip_sgr "$W1")
t "strip: tabs leads with 5 cells" 1 (string match -qr '^(\e\[[0-9;]*m)*[^\e]*▇{5}' -- "$W1"; and echo 1; or echo 0)
# fg colour order proves WHICH role sits where, independent of run length.
set -g W1SEQ (string join ' ' (string match -ra '38;2;[0-9]+;[0-9]+;[0-9]+' -- "$W1"))
t "strip: role order is tabs bar cap windows sep text" \
  "38;2;3;3;3 38;2;1;1;1 38;2;6;6;6 38;2;5;5;5 38;2;2;2;2 38;2;7;7;7" "$W1SEQ"
t "strip: active (#040404) is absent" 0 (string match -ra '38;2;4;4;4' -- "$W1" | count)
t "strip: exactly one blank tier column" 1 (string match -ra '  ' -- "$W1V" | count)
```

- [ ] **Step 2: Run and confirm the right things fail**

Run: `fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "^FAIL" | head -20`

Expected FAIL (discriminators): `cells is 15 visible cols => got [14]`, `cells degrades non-hex to blanks => got [14]`, `band is 15 visible cols => got [14]`, `band blank fallback => got [14]`, `strip: tabs leads with 5 cells => got [0]`, `strip: role order… => got [38;2;1;1;1 …]`, `strip: active … absent => got [1]`, `strip: exactly one blank tier column => got [0]`.

Expected PASS (non-regression guard): `cells still uses the seven-eighths block`. Record that it passes at both ends and do not call it vacuous — it guards the glyph, which this task keeps.

- [ ] **Step 3: Rewrite `__tcz_thp_cells`**

```fish
function __tcz_thp_cells --argument-names hexes --description 'pure: the scheme swatch strip, 15 visible cols. Input is the engine palette order (bar sep tabs active windows cap text); OUTPUT is ordered by measured on-screen area — tabs(5) bar(4) cap(2), a blank tier column, then windows(1) sep(1) text(7 -> 1). tabs leads because it covers ~1.8x the area of bar on a real ShellFish client. active is NOT drawn: apply_live pushes @tmux_lives_active_fg and no format string reads it, so a cell for it would show a colour that appears nowhere. Each cell is ▇ (U+2587, lower seven-eighths) in the role colour rather than a filled cell, so one eighth stays clear at the TOP and vertically adjacent strips stop merging. Non-hex roles degrade to blanks of the same width so the strip stays aligned.'
    set -l pal (string split ' ' -- "$hexes")
    set -l RST (printf '\e[0m')
    set -l cells ''
    # idx into the palette, then how many columns that role gets. idx 0 = the
    # tier gap: big areas to its left, trim to its right. Widths sum to 15.
    for pair in 3:5 1:4 6:2 0:1 5:1 2:1 7:1
        set -l f (string split ':' -- $pair)
        set -l idx $f[1]
        set -l wid $f[2]
        if test $idx -eq 0
            set cells "$cells"(string repeat -n $wid ' ')
            continue
        end
        set -l fg ''
        test (count $pal) -ge $idx; and set fg (__tcz_thp_fg "$pal[$idx]")
        if test -n "$fg"
            set cells "$cells$fg"(string repeat -n $wid ▇)"$RST"
        else
            set cells "$cells"(string repeat -n $wid ' ')
        end
    end
    printf '%s\n' "$cells"
end
```

- [ ] **Step 4: Widen `__tcz_thp_band` to match**

The second list must line up with the scheme list, so the band takes the same 15 columns. In `__tcz_thp_band`, change the blank fallback from 14 spaces to 15 and `string repeat -n 14 ▇` to `-n 15`. Update its docstring's two "14" mentions to 15.

⚠️ Write the fallback as `(string repeat -n 15 ' ')` captured or interpolated, not as a literal run of spaces you have to count by eye.

- [ ] **Step 5: Update the two docstrings that state the old geometry**

`__tcz_thp_row` (1260) says `7×2-col gradient strip(14)`. `__tcz_thp_staterow` (1276) says `<cells>(14)` and `both lists draw their 14 columns identically`, and its body carries the comment `marker(1) + cells(14) + space(1) + …`. Restate all of them as 15. **Read `__tcz_thp_staterow`'s width arithmetic and confirm it derives from `$w` and the rendered cells rather than a literal 14** — if a literal is doing load-bearing work there, fix it and say so in your report.

- [ ] **Step 6: Run the full gate and commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): weight the swatch strip by on-screen area"
```

---

### Task 2: Marker and highlight geometry

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_row` (1260), `__tcz_thp_staterow` (1276), the draw block's selection band
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_cells` at 15 columns from Task 1.
- Produces: no signature change. The marker glyph becomes `▌`; the band spans the marker's cell through to the right frame glyph.

**Why `▌` and not a narrower swatch.** `▐` (U+2590) inks the *right* half of its cell, so it hugs the first colour square. `▌` (U+258C) inks the *left* half — same width, same full height, nothing mismatching the `▇` swatches — which leaves **0.5 cell clear on each side** of the marker, because the frame's `│` inks the centre of its own cell. The symmetry costs zero extra columns. A half-*width* swatch cell was designed and rejected: it would have needed a full-height glyph beside 7/8-height ones.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 2: marker glyph and band extent ---------------------------------------
# ▌ (U+258C, LEFT half block) replaces ▐ (U+2590, RIGHT half). Same width and
# height; the ink moves to the left of the cell, which buys half a column of
# clearance from the first swatch without spending a column on it.
set -g R2 (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 1 0)
t "row: selected marker is the left half block" 1 (string match -q '*▌*' -- "$R2"; and echo 1; or echo 0)
t "row: the right half block is gone" 0 (string match -ra '▐' -- "$R2" | count)
set -g S2 (__tcz_thp_staterow 50 (__tcz_thp_band '#112233') current live 1 1)
t "staterow: selected marker is the left half block" 1 (string match -q '*▌*' -- "$S2"; and echo 1; or echo 0)
t "staterow: the right half block is gone" 0 (string match -ra '▐' -- "$S2" | count)
# Unselected rows must carry no marker ink at all, only its column.
set -g R2U (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 0 0)
t "row: unselected row has no marker glyph" 0 (string match -ra '▌|▐' -- "$R2U" | count)
```

- [ ] **Step 2: Run and confirm it fails**

Expected: the four `▌`/`▐` assertions fail (`got [0]` and `got [1]` respectively). `row: unselected row has no marker glyph` PASSES at both ends — a non-regression guard.

- [ ] **Step 3: Swap the glyph**

In `__tcz_thp_row` and `__tcz_thp_staterow`, change `set marker (__tcz_theme brand)'▐'(__tcz_theme reset)` to use `▌`. Both functions carry the identical line; change both. Do not describe the old glyph in a comment — a guard counts it.

- [ ] **Step 4: Extend the band to the right frame edge**

The draw block currently styles the selected row by replacing resets with `$RST$SELBG` and wrapping the row, which leaves the band stopping at the end of the text. Extend it so the band covers the marker's cell through the last inner column, with the two `│` glyphs left bare. `__tcz_thp_ln` already pads content to `$IW` before wrapping, so applying `$SELBG` to the padded content — rather than to the row before padding — achieves this.

- [ ] **Step 5: Prove the band reaches the right edge, behaviourally**

Extract the real draw block and assert on its rendered output rather than on the styling source. The selected row's visible text must run the full inner width with the band still in effect at the final column:

```fish
# The band must reach the last inner column, not stop at the end of the name.
set -g BANDROW (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 | string match -r '.*▌.*')
t "band row extraction is non-empty" 1 (test -n "$BANDROW"; and echo 1; or echo 0)
set -g BANDVIS (__tcz_strip_sgr "$BANDROW")
t "selected row is exactly the inner width plus both borders" 52 (string length --visible -- "$BANDVIS")
# sel-bg must still be the active background when the final inner column is drawn.
# NB the signature to look for is a reset followed by PADDING, not a reset
# followed by the border glyph: __tcz_thp_ln's printf emits the border SGR
# immediately before the closing border, so a reset can never sit directly
# against it and that form of the assertion is unsatisfiable at both ends.
t "band survives to the right border" 0 (string match -ra '\e\[0m ' -- "$BANDROW" | count)
```

Mutation-check this: revert Step 4 only, confirm `band survives to the right border` fails, restore, confirm it passes.

- [ ] **Step 6: Run the full gate and commit**

```bash
git commit -m "fix(picker): left-half marker and a band that reaches the frame"
```

---

### Task 3: The seed zone becomes mode-dependent

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_seedzone` (1497)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_thp_seedzone <w> <hex> <hue> <L> <C> <editing> <chan> <r> <g> <b>` → **3 lines when `editing` is 0, 8 lines when `editing` is 1.** Every line stays exactly `w + 2` visible columns. Signature unchanged.

**The row inventory is the contract.**

| row | idle (`editing` 0) | editing (`editing` 1) |
|---|---|---|
| 1 | zone separator, label `seed` | same |
| 2 | colour block row 1 · `#rrggbb` · `hue N° · L N · C N` | same |
| 3 | colour block row 2 | same |
| 4 | — | blank |
| 5 | — | R bar, selected iff `chan` = 1 |
| 6 | — | G bar, selected iff `chan` = 2 |
| 7 | — | B bar, selected iff `chan` = 3 |
| 8 | — | blank |

Two rows of block read as a square, because terminal cells run about 2:1. The readouts sit to the right of the block, where the row had empty space anyway. Blank rows surround the slider group; none divides it.

Deleted from the previous version: the 4-row `__tcz_thp_swatch` call, its duplicate hex and readout lines, and the copy `rendered as-is on the bar; companions derive from it`.

`__tcz_thp_slider` is fixed at 39 visible columns and other callers depend on that — do not change it. Pad its output to `w`, then wrap with `__tcz_thp_ln`.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 3: the seed zone is 3 rows idle, 8 editing ---------------------------
set -g SZI (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 0 1 95 119 43)
set -g SZE (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 1 95 119 43)
t "seedzone idle is 3 rows" 3 (count $SZI)
t "seedzone editing is 8 rows" 8 (count $SZE)
for i in (seq 3)
    set -l v (__tcz_strip_sgr "$SZI[$i]")
    t "idle row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
for i in (seq 8)
    set -l v (__tcz_strip_sgr "$SZE[$i]")
    t "editing row $i is exactly 52 visible cols" 52 (string length --visible -- "$v")
end
# Rows 1-3 are identical between states: only the slider block appears.
t "rows 1-3 are identical in both states" 1 (test "$SZI[1]$SZI[2]$SZI[3]" = "$SZE[1]$SZE[2]$SZE[3]"; and echo 1; or echo 0)
t "idle shows the hex" 1 (string match -q '*5f772b*' -- (string join ' ' $SZI); and echo 1; or echo 0)
t "idle shows the readouts beside it" 1 (string match -q '*hue*' -- (string join ' ' $SZI); and echo 1; or echo 0)
t "the retired copy is gone" 0 (string match -ra 'rendered as-is' -- (string join ' ' $SZE) | count)
# Blank rows surround the slider group and none divides it.
set -g SZE4 (__tcz_strip_sgr "$SZE[4]"); set -g SZE8 (__tcz_strip_sgr "$SZE[8]")
t "row 4 is blank" 1 (string match -qr '^│ *│$' -- "$SZE4"; and echo 1; or echo 0)
t "row 8 is blank" 1 (string match -qr '^│ *│$' -- "$SZE8"; and echo 1; or echo 0)
t "rows 5-7 all carry a channel bar" 3 (count (string match -ra 'R|G|B' -- (string join \n $SZE[5..7])))
# The selected channel tracks chan.
set -g SZC2 (__tcz_thp_seedzone 50 '#5f772b' 123 0.47 0.078 1 2 95 119 43)
t "chan=1 marks row 5, not row 6" 1 (test "$SZE[5]" != "$SZC2[5]" -a "$SZE[6]" != "$SZC2[6]"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and confirm it fails**

Expected: `seedzone idle is 3 rows => got [8]` and the idle width loop reporting on 8 rows. `seedzone editing is 8 rows` PASSES already (the old zone was 8) — a non-regression guard, not a discriminator. Record which is which.

- [ ] **Step 3: Rewrite the builder**

Emit row 1 with `__tcz_thp_zsep $w seed $BORDER $RST`. Build the two block rows from `__tcz_thp_bg` on the seed hex — a run of spaces on a coloured background, since a block row is a filled area rather than a glyph strip. Put the hex bold and the readouts in the `muted` role to the right of the block on row 2, and leave row 3's right side empty. Wrap rows 2-8 in `__tcz_thp_ln $… $w $BORDER $RST`.

Guard the non-hex case: a seed that fails to parse must still emit 3 or 8 rows of the right width, with a blank block.

- [ ] **Step 4: Do NOT commit yet — the gate is red until `STATIC` follows**

Changing the zone from 8 rows to 3 leaves the frame 5 rows short of the popup, so the frame proof fails. That is correct and expected: the zone height and `STATIC` are one change, and this plan never commits a red gate. Continue straight into Step 5. Record which frame assertions failed here, because that failure is your evidence the zone really moved.

**Additionally modify, from Step 5 on:** `functions/tmux-categorize.fish` — `set -l STATIC 21` (2004), the `WIN` derivation (2008), the seed-zone call site, the key dispatch's mode changes; and `tests/test-tmux-categorize.fish` — `__t9_frame_rows` and the frame assertions.

**`STATIC` becomes 16 idle and 21 editing.** `WIN = rows − STATIC`. The draw must emit exactly `rows` lines in both states.

**These two numbers are not final.** Task 5 adds an eleventh legend pair, which costs a legend row and raises them to 17 and 22. They are correct as of this task, and Task 5 owns the change. Do not pre-empt it here — the frame assertions you write now must pass at 16/21.

**The arithmetic.** The old zone was 8 rows inside a `STATIC` of 21. Idle: `21 − 8 + 3 = 16`. Editing: `21 − 8 + 8 = 21`. On a 52-row popup that shows **36 schemes idle** and 31 editing, against 31 today.

⚠️ **`STATIC` is currently bound by no test.** It lives *above* the frame proof's extraction range (`awk '/set -l curpal/,/╰/'`), and `__t9_frame_rows` restates the number instead of reading it. Changing 21 to 20 keeps all eight suites green while the frame overflows its popup and scrolls the top border away — the 2026-07-14 defect. The previous plan claimed the frame proof was this number's authority; it was not. **Fix that first, in Step 1, before touching the source.**

- [ ] **Step 5: Make the harness read `STATIC` from the source**

```fish
# The frame proof must derive WIN from the REAL STATIC, not restate it.
# STATIC lives above the draw block's extraction range, so read it out of the
# function body. Without this, a wrong STATIC keeps every suite green while the
# frame overflows its popup by the difference.
set -g PBODY9 (functions __tcz_theme_picker | string collect)
t "picker body for STATIC extraction is non-empty" 1 (test -n "$PBODY9"; and echo 1; or echo 0)
set -g STATIC9I (string match -rg 'set -l STATIC_IDLE (\d+)' -- "$PBODY9")
set -g STATIC9E (string match -rg 'set -l STATIC_EDIT (\d+)' -- "$PBODY9")
t "STATIC_IDLE extraction is non-empty" 1 (test -n "$STATIC9I"; and echo 1; or echo 0)
t "STATIC_EDIT extraction is non-empty" 1 (test -n "$STATIC9E"; and echo 1; or echo 0)
t "idle static is 16" 16 "$STATIC9I"
t "editing static is 21" 21 "$STATIC9E"
```

Then inside `__t9_frame_rows`, replace `set -l WIN (math "$rows - 21")` with a derivation from `$STATIC9I`/`$STATIC9E` selected by the harness's `editing` parameter (added by the previous branch's final fix wave — it is already there).

- [ ] **Step 6: Run and confirm the extractions fail**

Expected: `STATIC_IDLE extraction is non-empty => got [0]` and `STATIC_EDIT … => got [0]`, because the source still declares a single `STATIC`. The two non-empty guards failing FIRST is the point — they prove the value assertions beneath them cannot pass vacuously.

- [ ] **Step 7: Split `STATIC` in the source**

Replace `set -l STATIC 21` with two declarations and a mode-selected current value:

```fish
    # The seed zone is 3 rows idle and 8 editing (see __tcz_thp_seedzone), so the
    # static row count depends on mode. Both names are read directly by the frame
    # proof, which derives its own WIN from them rather than restating a literal —
    # a wrong value here used to keep the whole gate green while the frame
    # overflowed the popup and scrolled its own top border away.
    set -l STATIC_IDLE 16
    set -l STATIC_EDIT 21
```

Derive `WIN` from whichever applies, and recompute it wherever `editing` changes — the `b` toggle, the `⏎`-while-editing arm, and the `esc`-while-editing arm. `WIN` is read by both the draw loop and the paging dispatch, so one value must serve both.

- [ ] **Step 8: Re-clamp the window on every mode change**

Growing the zone costs 5 window rows, which can push the selected row out of view. After each `WIN` change, clamp the window so the selected row stays visible. `__tcz_thp_window` already returns a start that keeps `sel` inside the window; call it with the new `WIN` rather than adjusting `sel`.

Assert it, because the spec requires it and nothing else covers it. The property is that a deep selection stays inside the window after the mode change — the cursor must not move to achieve that:

```fish
# Entering edit mode costs 5 window rows. A selection near the bottom of the
# expanded catalog must stay VISIBLE, and sel itself must not be moved to
# achieve it — the window scrolls, the cursor does not.
# window <sel> <total> <winsize> -> "<start> <count>"
set -g CLAMPI (__tcz_thp_window 30 36 31)   # idle:    WIN 52-16 = 36 -> 31 usable
set -g CLAMPE (__tcz_thp_window 30 36 31)
set -g WI (string split ' ' -- (__tcz_thp_window 30 36 (math "52 - $STATIC9I")))
set -g WE (string split ' ' -- (__tcz_thp_window 30 36 (math "52 - $STATIC9E")))
t "idle window keeps sel=30 visible"    1 (test 30 -ge $WI[1] -a 30 -lt (math "$WI[1] + $WI[2]"); and echo 1; or echo 0)
t "editing window keeps sel=30 visible" 1 (test 30 -ge $WE[1] -a 30 -lt (math "$WE[1] + $WE[2]"); and echo 1; or echo 0)
t "the two windows differ (the zone really costs rows)" 1 (test "$WI[2]" != "$WE[2]"; and echo 1; or echo 0)
```

Then confirm behaviourally that the dispatch re-derives `WIN` rather than leaving a stale one: extract the `case b` arm, `eval` it against a seeded `WIN`, and assert `WIN` changed. A stale `WIN` is the failure mode here, and it is invisible to the frame proof, which computes its own.

- [ ] **Step 9: Extend the frame proof to both modes**

Assert the draw emits exactly `rows` in each mode, at several popup heights:

```fish
t "frame: 26 rows idle"      26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1)
t "frame: 26 rows editing"   26 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 1)
t "frame: 40 rows idle"      40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40 0 1)
t "frame: 40 rows editing"   40 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 40 1 1)
t "frame: 52 rows idle"      52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52 0 1)
t "frame: 52 rows editing"   52 (__t9_frame_rows list 0 35 34 0 mono "$PAL9" '' 1 14 52 1 1)
t "frame: 24 rows editing (the floor)" 24 (__t9_frame_rows list 0 14 0 0 mono "$PAL9" '' 0 14 24 1 1)
```

Note the 40-row idle case drives the padding branch (`WIN` 24 against a 14-row list), which is the branch a previous task lost coverage of when `STATIC` rose. Keep at least one padding case in each mode.

- [ ] **Step 10: Prove the proof is sensitive, in both modes and at both `STATIC` values**

Three mutations, each restored byte-identically and verified with `diff`:
1. Inject one extra `set -a lines` into the draw block. **Every** size in **both** modes must report one too many. A proof that only catches one mode is worse than the constant it replaced.
2. Change `STATIC_IDLE` to 15. Every idle assertion must fail by one; editing must stay green.
3. Change `STATIC_EDIT` to 20. Every editing assertion must fail by one; idle must stay green.

Report the observed counts for all three. Mutation 2 and 3 are the ones proving the harness genuinely reads the source.

- [ ] **Step 11: Run the full gate and commit**

One commit for the whole task: the zone and `STATIC` land together, gate green.

```bash
git commit -m "feat(picker): seed zone is 3 rows idle, 8 editing; the static count follows the mode"
```

---

### Task 4: Mode-aware legend

**Files:**
- Modify: `functions/tmux-categorize.fish` — the legend loop (2228)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `editing` from Task 3.

**Why this task exists.** The user reported that pressing `⏎` in the seed editor "closes the whole picker." `case enter` already gates on `editing` and only clears the mode — the dispatch is correct. The **footer is static**, so while editing it advertises `⏎ save` and `esc close` and names none of the channel keys. Pressing `⏎` silently left edit mode, nothing looked saved, and a second `⏎` saved and closed. The bug is the legend.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 5: the legend tells the truth in each mode ---------------------------
# The reported "enter closes the picker" bug lives here, not in the dispatch:
# a static footer advertised save/close while editing and never named ←→ or t.
set -g LEGI (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 0 1 | string collect)
set -g LEGE (__t9_frame_text list 0 14 0 0 mono "$PAL9" '' 0 14 26 1 1 | string collect)
t "idle legend extraction is non-empty" 1 (test -n "$LEGI"; and echo 1; or echo 0)
t "editing legend extraction is non-empty" 1 (test -n "$LEGE"; and echo 1; or echo 0)
t "editing legend names the channel keys" 1 (string match -q '*channel*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend names adjust" 1 (string match -q '*adjust*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend names type hex" 1 (string match -q '*type hex*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend says keep, not save" 1 (string match -q '*keep*' -- "$LEGE"; and echo 1; or echo 0)
t "editing legend does not advertise close" 0 (string match -ra 'close' -- "$LEGE" | count)
t "idle legend still advertises save and close" 1 (string match -q '*save*' -- "$LEGI"; and string match -q '*close*' -- "$LEGI"; and echo 1; or echo 0)
t "idle legend does not name channels" 0 (string match -ra 'channel' -- "$LEGI" | count)
```

- [ ] **Step 2: Run and confirm it fails**

Expected: the five editing-legend assertions fail, because the editing frame currently renders the browsing footer. The two idle assertions PASS at both ends.

- [ ] **Step 3: Branch the legend on mode**

```fish
        if test "$editing" = 1
            set leglines (__tcz_thp_leg 3 '↑↓' channel '←→' adjust t 'type hex'  '⏎' keep esc revert)
        else
            set leglines (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake '⇥' current/off  a apply '⏎' save esc close)
        end
```

⚠️ **Both legends must occupy the same number of rows, and this task must not change that number.** `STATIC_IDLE` and `STATIC_EDIT` from Task 3 each account for a fixed legend height, so a legend that grows breaks the frame in both modes with the cause hidden three sections away.

Measured: `__tcz_thp_leg 3` lays out three pairs per row, and the browsing legend's **10 pairs produce 3 rows**. The editing set above is 5 pairs, which produces 2. **Pad the editing legend to 3 rows.**

Do NOT add `A auto` here. It is the eleventh pair, **11 pairs produce 4 rows**, and that extra row belongs to Task 6 along with the `STATIC` adjustment it forces. Assert the row count so the constraint is enforced rather than remembered:

```fish
t "browsing legend is 3 rows" 3 (count (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake '⇥' current/off  a apply '⏎' save esc close))
t "editing legend is padded to the same 3 rows" 3 (count $LEGEROWS)
```

- [ ] **Step 4: Run the full gate and commit**

```bash
git commit -m "fix(picker): the legend follows the mode"
```

---

### Task 5: Auto-apply on dwell

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_readkey` (882), the settle branch (2241-2280), the movement arms, the legend from Task 5
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: universal `tmux_lives_theme_autoapply`, default on. `A` toggles it.

**The principle this obeys.** The user's rule: configuration is cheap and private; adoption touches the real bar. Settling on a scheme row already means "this is a candidate," so applying there is legitimate. Dragging a seed slider is configuration and must NOT reach the real bar.

**The dwell reuses the existing timed poll.** The branch at 2241 already runs `stty min 0 time 5` and calls `__tcz_popup_readkey timeout` when a flash is pending or a seed batch is owed. Auto-apply joins that gate as a third condition rather than adding a second timer. **That makes the dwell 500 ms, not the ~400 ms the spec estimates** — one timer serving three purposes beats three values, and the difference is imperceptible. Say so in your report; do not add a second timeout.

⚠️ **`A` (byte `0x41`) is absent from `__tcz_popup_readkey`'s outer switch.** Proven behaviourally: `printf A | __tcz_popup_readkey` returns `other`, where `printf a` returns `a`.

⚠️ **Do not verify that with a grep.** `case 41` already appears in the function, inside the ESC branch, where `0x41` is the final byte of `ESC [ A` — the up arrow. Grepping finds the arrow handler and suggests `A` is wired. The plan author made that mistake twice before the one-line behavioural test settled it. The two switches are separate; adding `case 41; echo A` to the outer one is safe.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 6: auto-apply on dwell -----------------------------------------------
# A is absent from readkey's OUTER switch. Assert the mapping behaviourally:
# grepping `case 41` finds the ESC-branch arrow handler and misleads.
t "readkey maps 0x41 to A" A (printf A | __tcz_popup_readkey)
set -g POPBODY6 (functions __tcz_popup | string collect)
t "switcher body extraction is non-empty" 1 (test -n "$POPBODY6"; and echo 1; or echo 0)
t "switcher has no case A (readkey's A token is a safe no-op there)" 0 (string match -qr 'case A\b' -- "$POPBODY6"; and echo 1; or echo 0)
# The picker must have a toggle arm and consult the universal.
set -g PB6 (functions __tcz_theme_picker | string collect)
t "picker body extraction is non-empty" 1 (test -n "$PB6"; and echo 1; or echo 0)
t "picker has an A arm" 1 (string match -qr 'case A$' -- "$PB6"; and echo 1; or echo 0)
t "picker reads the autoapply universal" 1 (string match -q '*tmux_lives_theme_autoapply*' -- "$PB6"; and echo 1; or echo 0)
```

Then a behavioural test of the dwell, in the style the previous branch established: extract the settle branch by content anchor, stub its inputs, `eval` it, and count applies. Define the harness — do not leave it implied:

```fish
# Extract the real settle branch and drive it with a scripted token. Anchored on
# content, not line numbers; asserted non-empty before anything is built on it.
set -g SETTLE6 (awk '/if test -n "\$flashfield"; or test "\$seeddirty" = 1/,/^        else$/' $catfile | string collect)
t "settle branch extraction is non-empty" 1 (test -n "$SETTLE6"; and echo 1; or echo 0)
t "settle extraction stopped at the else, not EOF" 0 (string match -ra 'case cancel' -- "$SETTLE6" | count)

# <autoapply 0|1> <token the stubbed readkey returns> -> number of applies fired.
# eval, not source: source opens its own local scope, so a `set -l` inside the
# extracted block would not survive the call returning.
function __t6_settle_applies --argument-names autoapply tok
    set -g __t6_applies 0
    function __tcz_popup_readkey; echo $__t6_tok; end
    function stty; end
    function __tcz_thp_reload; end
    function __tcz_thp_reanchor; end
    function __tcz_thp_autoapply_now; set -g __t6_applies (math $__t6_applies + 1); end
    set -g __t6_tok $tok
    set -l flashfield ''
    set -l seeddirty 0
    set -l applydue 1
    set -l autoapply $autoapply
    set -l lines one
    eval $SETTLE6
    functions -e __tcz_popup_readkey stty __tcz_thp_reload __tcz_thp_reanchor __tcz_thp_autoapply_now
    echo $__t6_applies
end

# One settle applies exactly once; a key arriving first applies zero times.
t "settle with autoapply armed applies once" 1 (__t6_settle_applies 1 timeout)
t "a key arriving before the timeout applies zero times" 0 (__t6_settle_applies 1 down)
t "settle with autoapply off applies zero times" 0 (__t6_settle_applies 0 timeout)
t "two consecutive settles do not stack applies" 1 (__t6_settle_applies 1 timeout)
```

This requires the apply itself to live in a named function (`__tcz_thp_autoapply_now`) rather than inline in the settle branch, so the harness can count it. Factor it out as part of Step 4 — the `a` arm should call the same function, which also removes the duplication between the two paths.

- [ ] **Step 2: Run and confirm it fails**

Expected: `readkey maps 0x41 to A => got [other]`, `picker has an A arm => got [0]`, `picker reads the autoapply universal => got [0]`, and the three dwell assertions failing or aborting until the harness exists. The switcher guard PASSES at both ends.

- [ ] **Step 3: Map `A` and add the paired convention guard**

Add `case 41; echo A; return` to `__tcz_popup_readkey`'s outer switch, beside the other shift-letter cases, and extend the function's docstring token list. The two assertions from Step 1 are the repo's standing pair for a shared-reader token — `c` and `⇥` both have them, and `t` shipped without them last branch, which left the whole feature deletable by removing one line with the gate green.

- [ ] **Step 4: Add the toggle and the dwell**

Read the universal at open through the same `fish -c` child that `__tcz_thp_init` already uses for the other seven — do not add a second subprocess. Default it on when unset. `case A` flips the in-memory flag, updates the note, and writes the universal through a config-loaded child at the same action-site tier as the other writes.

Arm the dwell by setting a pending flag on every movement arm that lands on a new row, and join it to the settle gate at 2241. On timeout with the flag set and auto-apply on, run the same apply the `a` arm runs — including the `__tcz_recolor` tab emit — then clear the flag.

⚠️ Applies must not stack. Clear the pending flag before the apply, not after, so a slow apply cannot leave a second one armed.

- [ ] **Step 5: Add `A auto` to the browsing legend — and pay for the row it costs**

Add `A auto` as the eleventh pair of the browsing legend, so the toggle has visible feedback showing its current state.

⚠️ **This adds a legend row, and `STATIC` must move with it.** Measured: 10 pairs render 3 rows, 11 pairs render 4. Task 4 deliberately left `A auto` out and asserted 3 rows precisely so this cost lands here, in the task that causes it.

So this step also:
1. Bumps `STATIC_IDLE` 16 → **17** and `STATIC_EDIT` 21 → **22**.
2. Pads the editing legend from 3 rows to **4**, keeping both modes equal.
3. Updates Task 4's two legend row-count assertions from 3 to 4, and Task 3's `idle static is 16` / `editing static is 21` to 17 and 22.

The frame proof reads `STATIC` out of the source, so it will follow automatically — but the two value assertions are literals and will fail until you update them. **That failure is the proof working.** Do not adjust the harness to paper over it; change the expected values and re-run the sensitivity mutations from Task 3 Step 10 at the new numbers.

On a 52-row popup the visible scheme count becomes 35 idle and 30 editing, against 31 today.

- [ ] **Step 6: Run the full gate and commit**

```bash
git commit -m "feat(picker): apply a scheme automatically once the cursor settles"
```

---

### Task 6: Cleanup and the `active` role

**Files:**
- Modify: `functions/tmux-categorize.fish` — delete `__tcz_thp_sliders` (1838) and `__tcz_thp_seedrow` (1403), their teardown lines, and `__tcz_thp_cells`
- Modify: `conf.d/tmux-lives-install.fish:131` — `window-status-current-format`
- Test: `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tcz_thp_cells` at **16** columns, with `active` as a fourth trim cell.

**Why now.** Both functions lost their last caller when the seed zone absorbed them, and this plan rewrites the zone they belonged to. `active` is the inverse case: the engine computes it and `apply_live` pushes `@tmux_lives_active_fg`, but no format string reads it, so it renders nowhere in any session. The user's rule was "if there's a chance we'll get use out of them, we should keep them" — so wire it rather than delete it. It pays off when they adopt multi-window tmux, exactly like `sep`.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 6: dead builders gone, active wired ---------------------------------
t "sliders builder is gone" 0 (string match -ra 'function __tcz_thp_sliders' -- (cat $catfile | string collect) | count)
t "seedrow builder is gone" 0 (string match -ra 'function __tcz_thp_seedrow' -- (cat $catfile | string collect) | count)
t "no teardown for the removed sliders" 0 (string match -ra 'functions -e __tcz_thp_sliders' -- (cat $catfile | string collect) | count)
# active earns its cell only now that something paints it.
set -g CELLS7 (__tcz_thp_cells '#010101 #020202 #030303 #040404 #050505 #060606 #070707')
t "cells is 16 visible cols once active is drawn" 16 (string length --visible -- "$CELLS7")
t "active (#040404) now appears" 1 (string match -ra '38;2;4;4;4' -- "$CELLS7" | count)
```

In `tests/test-tmux-install.fish`, beside the other fragment assertions:

```fish
t "current window wears the active role" yes (string match -q '*@tmux_lives_active_fg*' -- "$FRAG"; and echo yes; or echo no)
```

- [ ] **Step 2: Run and confirm it fails**

Expected: all five categorize assertions fail, and the install assertion fails with `got [no]`.

- [ ] **Step 3: Delete the two dead builders**

Remove both function definitions and the `functions -e __tcz_thp_sliders` teardown line. Three existing assertions reference them and will fail loudly rather than silently — update them rather than deleting the coverage: the drain-count guard drops by one (the sliders carried their own drain loop), and two reachability greps go.

⚠️ **The Step-4b drain invariant from the previous branch survives this deletion** — removing the sliders takes `while true` from 4 to 3 and the stty-followed count from 3 to 2, so `total − safe` stays 1. Verify that rather than assuming it.

- [ ] **Step 4: Wire `active` and give it a cell**

In `conf.d/tmux-lives-install.fish:131`, point `window-status-current-format` at `@tmux_lives_active_fg` instead of `@tmux_lives_text_fg`. Then add `4:1` to `__tcz_thp_cells`'s pair list, after the trim roles, taking the strip to 16 columns. Widen `__tcz_thp_band` to 16 to match, and update every docstring stating 15.

- [ ] **Step 5: Run the full gate and commit**

```bash
git commit -m "refactor(picker): drop the dead seed builders; paint the active role"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (the picker subsection, ~105-115), `CLAUDE.md`

- [ ] **Step 1: Update the README picker subsection**

Document the mode-dependent seed zone and that the visible scheme count differs between browsing and editing; the `A` auto-apply toggle and its dwell; the area-ordered swatch strip and what each width means; and the corrected edit-mode keys (`↑↓` channel, `←→` adjust, `t` type hex, `⏎` keep, `esc` revert). Match the file's existing voice: direct, second person, backticked keys, no changelog framing.

- [ ] **Step 2: Add the CLAUDE.md paragraph**

House style: a bolded lead-in naming the change, the date, and the branch, then one dense paragraph. Record the configuration-versus-adoption principle and that it is the user's; the measured 1.8× tabs-to-bar area ratio that reordered the strip; `active` having been unpainted in every session until now; `STATIC` splitting into **17 idle / 22 editing** and the frame proof finally *reading* it out of the source rather than restating a literal; that the eleventh legend pair costs a whole legend row, which is why both numbers are one higher than the zone arithmetic alone suggests; the `▌`-for-`▐` swap and why a half-width swatch cell was rejected; the 500 ms dwell shared with the flash and seed-batch timers; and that the reported ENTER bug was a lying legend rather than a broken dispatch.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: record the picker legibility pass and auto-apply"
```

---

## Final verification

- [ ] Full gate: 8 `ALL PASS` in BOTH modes; record final counts and confirm the plain/`--no-config` delta is still exactly 1.
- [ ] Frame proof sensitivity re-proven at every size in BOTH modes, plus the two `STATIC` mutations.
- [ ] `fish -c 'set -U | string match "tmux_lives_*"'` — only `tmux_lives_theme_autoapply` added, nothing else changed.
- [ ] Nothing deployed: `~/.config/fish/`, `~/.tmux.conf` and `~/.config/tmux/tmux-lives.conf` untouched.
- [ ] Confirm no comment added anywhere spells a shape a guard counts.
