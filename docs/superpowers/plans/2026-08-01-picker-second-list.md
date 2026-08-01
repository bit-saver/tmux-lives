# Theme Picker — Second List, Layout Revision, Input Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `off` out of the scheme list into a second selectable list beside the current theme, revise the picker's layout, and fix its two input defects.

**Architecture:** All changes live in `functions/tmux-categorize.fish` — the pure `__tcz_thp_*` builders and the `__tcz_theme_picker` loop. The theme engine, catalog, `setup theme` CLI and the rendered fragment are untouched. The picker's linear selection model (`0..n-1` schemes, `n` off, `n+1` current-reachable-only-by-`c`) is replaced by a two-list focus model: the scheme list keeps `sel` over `0..n-1`, a second list gets its own `sel2` over `0..1`, and `⇥` moves between them.

**Tech Stack:** fish 4.7.1, tmux 3.3a. The picker runs under `fish --no-config` inside a `display-popup`.

**Spec:** `docs/superpowers/specs/2026-08-01-picker-second-list-design.md`

**Branch:** `feat/picker-second-list` off `main`.

## Global Constraints

- **The popup is `-w 52 -h 26` and the draw MUST emit exactly 26 rows in EVERY state** — cursor in either list, previewing or not, catalog collapsed or expanded. The frame is 15 static rows + an 11-row scheme window after Task 4. Emitting 27 scrolls the top border off (a defect this picker has shipped before); emitting 25 leaves a gap. Every task that changes row composition states its arithmetic.
- **Geometry is pinned at three open sites** and by tests: `functions/tmux-categorize.fish` (the modal launcher's `k`), `conf.d/tmux-lives-install.fish` (the `M-k` fragment bind), and `conf.d/tmux-lives-install.fish` (the `setup theme` CLI path). This plan does not change the geometry, so all three stay `-w 52 -h 26`.
- **Zero net new files** in `conf.d/` or `functions/`. New functions go in the existing `functions/tmux-categorize.fish`, underscore-prefixed.
- **`math` has NO comparison operators.** fish's `test` compares floats. Compute into a variable, then `test` it.
- **Never write the quoted-math-index shape** (a double-quoted variable whose subscript is a `math` call). It is a fish "Invalid index value" error that sprays a stack trace into the popup, and a grep guard bans it. **The guard matches comments too** — describe the shape, never spell it, or you trip the guard while explaining it.
- **A zero-output command substitution used as a bare argument VANISHES from the argument list**, silently shifting every later `printf` field. Capture into a variable first, then interpolate it **quoted**. `string repeat -n 0` produces zero output — this is exactly how it bites.
- **`__tcz_popup_readkey` is SHARED** with the session switcher (`__tcz_popup`). Adding a token is safe because `__tcz_popup`'s dispatch has cases only for `up`/`down`/`enter`/`kill`/`cancel` and **no `case '*'`** — verified. A regression assertion covers it.
- **Deployment is the user's `fisher update`.** Commit and push; never copy into `~/.config/fish/`.
- **The agent Bash tool is zsh, not bash.** Wrap stderr-byte checks in `bash -c '…'`. Write commit messages to a file and use `git commit -F`.
- **A test whose actual-value command substitution calls an UNDEFINED function does not fail.** fish aborts the whole statement, `t` never runs, nothing prints, and `test-tmux-categorize.fish` (no pass counter) still reports `ALL PASS`. **Every new builder in this plan gets a `functions -q` existence assertion**, and every grep guard is paired with a positive count so an empty input cannot make it pass vacuously.
- **Gate for every task:** all 8 suites green under **both** plain `fish` and `fish --no-config`.

  ```bash
  bash -c 'for m in "" "--no-config"; do echo "-- fish $m --"; for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; timeout 150 fish $m "$t" </dev/null 2>&1 | tail -1; done; done'
  ```

  Baseline at the start of this work: 8 `ALL PASS`, `test-tmux-install.fish` at **502** (plain) / **501** (`--no-config`).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `functions/tmux-categorize.fish` | The categorizer: pure picker builders + the interactive `__tcz_theme_picker` loop | Modified — 1 theme role added, 3 builders added, 3 deleted, 2 rewritten, the loop's selection model replaced |
| `tests/test-tmux-categorize.fish` | Picker builder + loop-body assertions | Modified — new builder tests, guards, and updates to the assertions that pin the old model |
| `docs/superpowers/plans/2026-08-01-picker-second-list.md` | This plan | Created |
| `CLAUDE.md` | Project record | Modified in the final task |

`conf.d/tmux-lives-install.fish` is **not** touched: geometry is unchanged and the engine is out of scope.

---

## Task 1: The `title` theme role

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme` (add a case), `__tcz_thp_zsep` (use it)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_theme title` → the SGR for `#d2782a`. Every later task's separators use it.

Row composition unchanged.

- [ ] **Step 1: Create the branch**

```bash
cd /home/bitsaver/workspace/tmux-lives
git checkout main && git pull --ff-only origin main
git checkout -b feat/picker-second-list
```

- [ ] **Step 2: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, immediately before the `# __tcz_status_right_merge` section:

```fish
# ---------------------------------------------------------------------
# __tcz_theme title — section separators in dimmed orange
# ---------------------------------------------------------------------
# The brand orange pulled down ~18%: distinct from the frame rule AND from the
# undimmed brand the picker uses for its own `theme` title in the top border.
t "theme title role is the dimmed orange" (printf '\e[38;2;210;120;42m') (__tcz_theme title)
set -g ZS (__tcz_thp_zsep 40 schemes (__tcz_theme border) (__tcz_theme reset))
t "zsep label wears the title role" 1 (string match -q '*'(__tcz_theme title)'*' -- "$ZS"; and echo 1; or echo 0)
t "zsep label no longer wears muted"  0 (string match -q '*'(__tcz_theme muted)'*' -- "$ZS"; and echo 1; or echo 0)
t "zsep is still exactly w visible cols" 40 (string length --visible -- "$ZS")
# an empty label still falls through to the plain rule
t "zsep with no label is the plain rule" 40 (string length --visible -- (__tcz_thp_zsep 40 '' (__tcz_theme border) (__tcz_theme reset)))
```

- [ ] **Step 3: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "theme title|zsep"
```

Expected: `FAIL` on `theme title role`, `zsep label wears the title role`, and `zsep label no longer wears muted`. The two width assertions should already pass.

- [ ] **Step 4: Add the role**

In `__tcz_theme`, add immediately after the `case muted;` line:

```fish
        # section-separator titles: the brand orange pulled down ~18%. Distinct from
        # `border` (which would blend the label into the rule it sits on) and from
        # `brand` (which the top border's own `theme` title already uses).
        case title;  printf '\e[38;2;210;120;42m'
```

Also extend the function's `--description` role list from `(brand/border/key/muted/value/mark/flash/sel-bg/sel-fg/reset)` to `(brand/border/title/key/muted/value/mark/flash/sel-bg/sel-fg/reset)`.

- [ ] **Step 5: Point `__tcz_thp_zsep` at it**

In `__tcz_thp_zsep`, replace:

```fish
    set -l MUT (__tcz_theme muted)
```

with:

```fish
    set -l MUT (__tcz_theme title)
```

and update the function's `--description`, changing `BOLD muted label` to `BOLD title-role label`.

- [ ] **Step 6: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`.

- [ ] **Step 7: Run the full gate, both fish modes**

Use the command from Global Constraints. Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 8: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): section titles in a dimmed-orange `title` role

The separators wore `muted`, the same warm tan as ordinary row text, so the
zones did not read as structure. `title` is the brand orange pulled down ~18% —
distinct from the frame rule it sits on, and from the undimmed brand the top
border already uses for the picker's own name.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 2: Swatch separation — the `▇` glyph

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_thp_cells` and `__tcz_thp_band`, rewire `__tcz_thp_row`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces:
  - `__tcz_thp_cells <hexes>` → the 7×2-col gradient strip, 14 visible cols, each cell `▇` in the role colour. Task 3 and Task 5 both use it.
  - `__tcz_thp_band <hex>` → a 14-col band in one colour with the same top gap. Task 5 uses it for the `off` row.

Row composition unchanged.

The swatch stops being a background-filled cell and becomes a foreground glyph, leaving one eighth of the cell clear at the top so vertically adjacent strips stop merging into one block. On a selected row the gap shows the selection band, because the draw loop already re-asserts `sel-bg` after every reset inside the row — no change needed there.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, immediately after the Task 1 block:

```fish
# ---------------------------------------------------------------------
# __tcz_thp_cells / __tcz_thp_band — swatches with a top gap
# ---------------------------------------------------------------------
# A terminal cannot shave pixels, but ▇ (U+2587, lower seven-eighths) drawn in the
# role colour leaves one eighth of the cell clear at the TOP, so stacked strips
# stop reading as one solid block. Foreground glyph, NOT a background fill.
t "cells fn exists" 1 (functions -q __tcz_thp_cells; and echo 1; or echo 0)
t "band fn exists"  1 (functions -q __tcz_thp_band; and echo 1; or echo 0)
set -g CELLS (__tcz_thp_cells '#112233 #223344 #334455 #445566 #556677 #667788 #778899')
t "cells is 14 visible cols" 14 (string length --visible -- "$CELLS")
t "cells uses the seven-eighths block" 14 (count (string match -ra '▇' -- "$CELLS"))
t "cells sets FOREGROUND, not background" 0 (count (string match -ra '48;2;' -- "$CELLS"))
t "cells carries each role colour" 1 (string match -q '*38;2;17;34;51*' -- "$CELLS"; and echo 1; or echo 0)
# a non-hex cell degrades to a blank gap, keeping the strip aligned
t "cells degrades non-hex to blanks" 14 (string length --visible -- (__tcz_thp_cells '#112233 nope #334455 #445566 #556677 #667788 #778899'))
set -g BAND (__tcz_thp_band '#5f772b')
t "band is 14 visible cols" 14 (string length --visible -- "$BAND")
t "band uses the same glyph"  14 (count (string match -ra '▇' -- "$BAND"))
t "band degrades non-hex to blanks" 14 (string length --visible -- (__tcz_thp_band nope))
# and the scheme row still measures the same as before
t "row strip is still 14 cols inside the row" 1 (string match -q '*▇▇*' -- (__tcz_thp_row '#112233 #223344 #334455 #445566 #556677 #667788 #778899' demo 0 0); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "cells|band|row strip"
```

Expected: `FAIL` on `cells fn exists` and `band fn exists`. **The other assertions will not appear at all** — that is the vacuity trap, and it is why the two existence assertions come first. Do not read their absence as success.

- [ ] **Step 3: Add the two builders**

Insert into `functions/tmux-categorize.fish` immediately BEFORE `function __tcz_thp_row`:

```fish
function __tcz_thp_cells --argument-names hexes --description 'pure: the 7x2-col gradient strip (14 visible cols). Each cell is ▇ (U+2587, lower seven-eighths) drawn in the role colour rather than a filled cell, so one eighth stays clear at the TOP and vertically adjacent strips stop merging into one block (2026-08-01). Non-hex cells degrade to blank gaps so the strip stays aligned.'
    set -l cells ''
    for hex in (string split ' ' -- "$hexes")
        set -l fg (__tcz_thp_fg "$hex")
        if test -n "$fg"
            set cells "$cells$fg▇▇"(printf '\e[0m')
        else
            set cells "$cells  "
        end
    end
    printf '%s\n' "$cells"
end

function __tcz_thp_band --argument-names hex --description 'pure: a 14-col band in one colour, drawn with the same ▇ top gap as __tcz_thp_cells so the second list lines up with the scheme list. Non-hex -> 14 blanks.'
    set -l fg (__tcz_thp_fg "$hex")
    if test -z "$fg"
        printf '%s\n' '              '
        return
    end
    printf '%s\n' "$fg"(string repeat -n 14 ▇)(printf '\e[0m')
end
```

- [ ] **Step 4: Rewire `__tcz_thp_row` to use them**

In `__tcz_thp_row`, replace the inline cell loop:

```fish
    set -l cells ''
    for hex in (string split ' ' -- "$hexes")
        set -l bg (__tcz_thp_bg "$hex")
        if test -n "$bg"
            set cells "$cells$bg  "(printf '\e[0m')
        else
            set cells "$cells  "
        end
    end
```

with:

```fish
    set -l cells (__tcz_thp_cells "$hexes")
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`.

- [ ] **Step 6: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 7: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): swatches get a top gap so stacked strips stop merging

A terminal cannot shave pixels, but ▇ (U+2587) drawn in the role colour instead
of filling the cell leaves one eighth clear at the top. Extracted the strip into
__tcz_thp_cells and added __tcz_thp_band for the second list, so both lists draw
their 14 columns the same way.

The swatch is now a foreground glyph, so on a selected row the gap shows the
selection band — the draw loop already re-asserts sel-bg after every reset inside
the row, so this needed no change there.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 3: `__tcz_thp_staterow` replaces `__tcz_thp_off_row`

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_thp_staterow`, delete `__tcz_thp_off_row`, update its two call sites
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_cells`, `__tcz_thp_band` (Task 2)
- Produces: `__tcz_thp_staterow <w> <cells> <name> <label> <selected> <live>` → one second-list row, exactly `<w>` visible cols: marker(1) + cells(14) + space(1) + name left-aligned + pad + label + one trailing space. Task 5 draws both rows with it.

Row composition unchanged — this is a 1:1 replacement at both existing call sites, still rendering an off row and a current row in the same two positions. The layout change happens in Task 5.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 2 block:

```fish
# ---------------------------------------------------------------------
# __tcz_thp_staterow — the second list's row: name left, role label RIGHT
# ---------------------------------------------------------------------
t "staterow fn exists" 1 (functions -q __tcz_thp_staterow; and echo 1; or echo 0)
set -g SR (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'mono soft' current 0 1)
t "staterow is exactly w visible cols" 50 (string length --visible -- "$SR")
t "staterow shows the name" 1 (string match -q '*mono soft*' -- "$SR"; and echo 1; or echo 0)
t "staterow shows the label" 1 (string match -q '*current*' -- "$SR"; and echo 1; or echo 0)
# the label ends one column short of the border: exactly one trailing space
t "staterow label ends one col short" 1 (string match -qr 'current(\e\[[0-9;]*m)* $' -- "$SR"; and echo 1; or echo 0)
# live -> the label is bold in brand; not live -> muted
t "staterow live label wears brand" 1 (string match -q '*'(__tcz_theme brand)'current*' -- "$SR"; and echo 1; or echo 0)
set -g SRD (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'mono soft' current 0 0)
t "staterow not-live label wears muted" 1 (string match -q '*'(__tcz_theme muted)'current*' -- "$SRD"; and echo 1; or echo 0)
t "staterow not-live is still w cols" 50 (string length --visible -- "$SRD")
# selection puts the ▐ marker in brand and brightens the name
set -g SRS (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'legacy look' off 1 0)
t "staterow selected shows the marker" 1 (string match -q '*▐*' -- "$SRS"; and echo 1; or echo 0)
t "staterow selected is still w cols" 50 (string length --visible -- "$SRS")
# width holds for a long name and a short label, and vice versa
t "staterow long name still w cols" 50 (string length --visible -- (__tcz_thp_staterow 50 (__tcz_thp_band '#5f772b') 'a-very-long-scheme-name-here' off 0 0))
# it accepts a full 7-role strip too — the current row shows its real palette
t "staterow accepts a 7-role strip" 50 (string length --visible -- (__tcz_thp_staterow 50 (__tcz_thp_cells '#112233 #223344 #334455 #445566 #556677 #667788 #778899') 'mono soft' current 0 1))
# and the retired builder is gone
t "off_row builder is gone" 0 (grep -c '__tcz_thp_off_row' $catfile)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "staterow|off_row"
```

Expected: `FAIL` on `staterow fn exists` and on `off_row builder is gone`. The rest will not appear (vacuity trap).

- [ ] **Step 3: Add the builder**

Insert into `functions/tmux-categorize.fish` immediately AFTER `__tcz_thp_row`'s closing `end`:

```fish
function __tcz_thp_staterow --argument-names w cells name label selected live --description 'pure: one SECOND-LIST row, exactly <w> visible cols: marker(1) + <cells>(14) + space(1) + <name> left-aligned + pad + <label> flush right + one trailing space. <cells> is pre-rendered (__tcz_thp_cells for a palette, __tcz_thp_band for a single colour) so both lists draw their 14 columns identically. <live> = 1 renders the label BOLD in `brand` — it means this really is what is on the bar right now, which is the readout that replaced the chevron; otherwise muted.'
    set -l marker ' '
    set -l namecol (__tcz_theme muted)
    if test "$selected" = 1
        set marker (__tcz_theme brand)'▐'(__tcz_theme reset)
        set namecol (__tcz_theme sel-fg)(printf '\e[1m')
    end
    set -l labcol (__tcz_theme muted)
    set -l labon ''
    if test "$live" = 1
        set labcol (__tcz_theme brand)
        set labon (printf '\e[1m')
    end
    # marker(1) + cells(14) + space(1) + name + pad + label + trailing space(1)
    set -l nlen (string length --visible -- "$name")
    set -l llen (string length --visible -- "$label")
    set -l pad (math "$w - 17 - $nlen - $llen")
    test $pad -lt 1; and set pad 1
    # Capture the repeat into a var and interpolate it QUOTED: a zero-output command
    # substitution used as a bare argument VANISHES from the arg list and shifts every
    # later printf field. The -lt 1 floor also catches math's "-0" STRING.
    set -l padstr (string repeat -n $pad ' ')
    printf '%s%s %s%s%s%s%s%s%s \n' \
        "$marker" "$cells" \
        "$namecol" "$name" (__tcz_theme reset) \
        "$padstr" \
        "$labon$labcol" "$label" (__tcz_theme reset)
end
```

- [ ] **Step 4: Delete `__tcz_thp_off_row` and update its two call sites**

Delete the whole `__tcz_thp_off_row` function (its `function` line through its unindented closing `end`).

In `__tcz_theme_picker`'s draw block, replace the off-row construction:

```fish
        set -l offrow (__tcz_thp_off_row "$legacy" $offflag)
```

with:

```fish
        set -l offrow (__tcz_thp_staterow $IW (__tcz_thp_band "$legacy") 'legacy look' off $offflag 0)
```

and replace the anchor-row construction:

```fish
        set -l anchrow ''
        if test -n "$anchpal"
            set anchrow (__tcz_thp_row "$anchpal" "$anch_scheme · current" $anchflag 1)
        else
            set anchrow (__tcz_thp_off_row "$legacy" $anchflag "$anch_scheme · current" 1)
        end
```

with:

```fish
        set -l anchcells (__tcz_thp_band "$legacy")
        test -n "$anchpal"; and set anchcells (__tcz_thp_cells "$anchpal")
        set -l anchrow (__tcz_thp_staterow $IW "$anchcells" "$anch_scheme" current $anchflag 1)
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`. If assertions elsewhere fail because they pinned the old `❯ <scheme> · current` text, update them to the new `<scheme>` / `current` split — the chevron and the ` · current` suffix are both gone by design.

- [ ] **Step 6: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 7: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): one builder for both second-list rows, role label flush right

__tcz_thp_staterow replaces __tcz_thp_off_row and serves the current row too:
swatch, then the scheme name, then the role label (`current` / `off`) aligned to
the right edge. The current row keeps its real 7-role palette; off keeps a single
band; both draw their 14 columns through the same helpers so the lists align.

The label renders bold-orange when `live` — that readout is what makes dropping
the chevron safe, and it says something the chevron never did.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 4: Horizontal `SEED`, `configuration`, and an 11-row window

**Files:**
- Modify: `functions/tmux-categorize.fish` — the draw block's adjustments zone, `WIN`, delete `__tcz_thp_kv` and `__tcz_thp_spread`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: nothing new
- Produces: `WIN` becomes 11. Task 5's paging reads the same variable.

**Row arithmetic:** the adjustments zone goes from 3 rows (zsep + labels + values) to 2 (zsep + one combined row): **−1**. `WIN` goes 10 → 11: **+1**. Frame stays exactly **26**.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 3 block:

```fish
# ---------------------------------------------------------------------
# layout: horizontal SEED, `configuration`, an 11-row window
# ---------------------------------------------------------------------
set -g PK (functions __tcz_theme_picker | string collect)
t "zone is titled configuration" 1 (string match -q '*configuration*' -- "$PK"; and echo 1; or echo 0)
t "the old adjustments title is gone" 0 (string match -q '*adjustments*' -- "$PK"; and echo 1; or echo 0)
t "SEED label and value share one row" 1 (string match -q '*SEED*' -- "$PK"; and echo 1; or echo 0)
t "the two-row kv builder is gone"     0 (grep -c '__tcz_thp_kv' $catfile)
t "the spread builder is gone"         0 (grep -c '__tcz_thp_spread' $catfile)
t "scheme window is 11 rows"           1 (string match -q '*set -l WIN 11*' -- "$PK"; and echo 1; or echo 0)
t "WIN is defined exactly once"        1 (count (string match -ra 'set -l WIN ' -- "$PK"))
t "no stale WIN 10"                    0 (string match -q '*set -l WIN 10*' -- "$PK"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "configuration|adjustments|SEED|kv builder|spread builder|WIN"
```

Expected: `FAIL` on `zone is titled configuration`, `the old adjustments title is gone`, both builder-gone assertions, `scheme window is 11 rows`, and `no stale WIN 10`.

- [ ] **Step 3: Replace the adjustments zone with one horizontal row**

In the draw block, replace:

```fish
        set -a lines (__tcz_thp_zsep $IW 'adjustments' $BORDER $RST)
        set -l kv1 (__tcz_thp_kv $IW "$flashfield" seed "$seedchip")
        set -a lines (__tcz_thp_ln "$kv1[1]" $IW $BORDER $RST)
        set -a lines (__tcz_thp_ln "$kv1[2]" $IW $BORDER $RST)
```

with:

```fish
        set -a lines (__tcz_thp_zsep $IW 'configuration' $BORDER $RST)
        # ONE horizontal row: label and value side by side. The zone holds a single
        # field now that phase is hidden, so the stacked label-row/value-row form was
        # pure overhead — and the row it frees goes to the scheme window below.
        set -l seedlab (__tcz_theme muted)
        test "$flashfield" = seed; and set seedlab (__tcz_theme flash)
        set -l seedrow (printf '%sSEED%s   %s' "$seedlab" $RST "$seedchip")
        set -a lines (__tcz_thp_ln "$seedrow" $IW $BORDER $RST)
```

- [ ] **Step 4: Grow the window and update the frame comment**

Change `set -l WIN 10` to `set -l WIN 11`.

Update the long frame comment above the windowed list so its arithmetic matches: it currently reads "16 static rows (border/chip/preview/adjustments-zsep/kv×2/schemes-zsep/off/current-zsep/anchor/blank-zsep/legend×3/note/bottom-border) + WIN scheme rows = 26". Replace that parenthetical with:

```
15 static rows (border/chip/preview/configuration-zsep/seed/schemes-zsep/off/
current-zsep/anchor/blank-zsep/legend×3/note/bottom-border) + WIN scheme rows = 26
```

- [ ] **Step 5: Delete the two orphaned builders**

Delete `__tcz_thp_kv` and `__tcz_thp_spread` entirely (each `function` line through its unindented closing `end`). `__tcz_thp_kv` was the draw's only caller of itself, and `__tcz_thp_spread`'s only caller was `__tcz_thp_kv` — verified, so deleting `kv` orphans `spread`.

- [ ] **Step 6: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`. Existing assertions that pinned `adjustments` or the kv/spread builders must be updated, not deleted — carry their intent to the new form.

- [ ] **Step 7: Verify the frame is still exactly 26 rows**

The draw builds `$lines` before emitting. Count them directly rather than trusting the arithmetic:

```bash
fish -c 'set -g tmux_categorize_test 1; source functions/tmux-categorize.fish
set -l body (functions __tcz_theme_picker | string collect)
# every `set -a lines` in the draw contributes rows; the window contributes WIN
echo "set -a lines sites: "(count (string match -ra "set -a lines" -- "$body"))
echo "WIN: "(string match -r "set -l WIN [0-9]+" -- "$body")'
```

Expected: `WIN: set -l WIN 11`. The authoritative row count is asserted live in Task 9's smoke check; this step is a sanity read.

- [ ] **Step 8: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 9: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): SEED goes horizontal, the zone becomes `configuration`

Phase is hidden and pinned, so the zone holds a single field — the stacked
label-row/value-row form was pure overhead. Label and value now share one row,
and the freed row goes to the scheme window: 11 visible schemes instead of 10,
frame still exactly 26.

__tcz_thp_kv and __tcz_thp_spread are deleted; kv was the draw's only user and
spread's only caller was kv.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 5: The second list and `⇥` focus

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_readkey` (add `tab`), `__tcz_thp_vismap` (clamp `0..n-1`), `__tcz_theme_picker` (focus model, draw, dispatch, legend, schemes rule)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_staterow` (Task 3), `WIN` = 11 (Task 4)
- Produces: the focus model — `focus` is `list` or `state`, `sel` covers `0..n-1`, `sel2` covers `0..1` (0 = current, 1 = off). Tasks 6 and 7 branch on `focus`.

**Row arithmetic:** the pinned off row is removed from below the window (**−1**); the `current` zsep becomes untitled (same row, **0**); the anchor row becomes the current staterow (**0**); the off staterow joins the second list (**+1**). Net **0**. Frame stays exactly **26**.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 4 block:

```fish
# ---------------------------------------------------------------------
# second list + ⇥ focus
# ---------------------------------------------------------------------
# readkey gains one token. Safe for the SHARED switcher: __tcz_popup's dispatch
# has cases only for up/down/enter/kill/cancel and NO case '*', so an unlisted
# token is silently ignored there — the same argument that covered p/P/m/M and c.
t "readkey maps 0x09 to tab" 1 (string match -q '*case 09*tab*' -- (functions __tcz_popup_readkey | string collect); and echo 1; or echo 0)
set -g POPBODY (functions __tcz_popup | string collect)
t "switcher has no tab arm"   0 (string match -q '*case tab*' -- "$POPBODY"; and echo 1; or echo 0)
t "switcher still has no catch-all" 0 (string match -q "*case '*'*" -- "$POPBODY"; and echo 1; or echo 0)

# vismap now clamps to the SCHEME list only — off left it, so n is no longer a stop
t "vismap down stops at n-1" 4 (__tcz_thp_vismap 4 5 down)
t "vismap up stops at 0"     0 (__tcz_thp_vismap 0 5 up)
t "vismap walks normally"    3 (__tcz_thp_vismap 2 5 down)
t "vismap never yields n"    0 (set -l bad 0; for s in 0 1 2 3 4; for d in up down; test (__tcz_thp_vismap $s 5 $d) -ge 5; and set bad 1; end; end; echo $bad)

set -g PK2 (functions __tcz_theme_picker | string collect)
t "picker tracks focus"      1 (string match -q '*set -l focus list*' -- "$PK2"; and echo 1; or echo 0)
t "picker tracks sel2"       1 (string match -q '*set -l sel2 0*' -- "$PK2"; and echo 1; or echo 0)
t "picker has a tab arm"     1 (string match -q '*case tab*' -- "$PK2"; and echo 1; or echo 0)
t "the c key is retired"     0 (string match -q '*case c*' -- "$PK2"; and echo 1; or echo 0)
t "legend offers current/off" 1 (string match -q '*current/off*' -- "$PK2"; and echo 1; or echo 0)
t "legend drops the c entry"  0 (string match -q '*c current*' -- "$PK2"; and echo 1; or echo 0)
# the schemes rule loses its subtitle and scroll counts
t "schemes rule is bare"      0 (string match -q '*near-seed*' -- "$PK2"; and echo 1; or echo 0)
t "no scroll-count marks"     0 (string match -q '*▲*' -- "$PK2"; and echo 1; or echo 0)
# the second list's rule is untitled
t "second list rule is untitled" 0 (string match -q "*__tcz_thp_zsep \$IW 'current'*" -- "$PK2"; and echo 1; or echo 0)
# no chevrons anywhere, and the retired switcher-yellow is gone with them
t "no chevron in the picker"  0 (count (string match -ra '❯' -- "$PK2"))
t "switcher-yellow retired"   0 (string match -q '*38;5;179*' -- "$PK2"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "readkey maps|vismap|focus|sel2|tab arm|c key|legend|schemes rule|scroll-count|untitled|chevron|switcher-yellow"
```

Expected: `FAIL` on the readkey token, the vismap clamp assertions, and every picker-body assertion.

- [ ] **Step 3: Add the `tab` token to the shared readkey**

In `__tcz_popup_readkey`'s first `switch "$b"`, add immediately before `case 71; echo cancel; return`:

```fish
        case 09; echo tab; return                    # TAB (theme-picker: switch lists)
```

Add `tab` to the function's `--description` token list.

- [ ] **Step 4: Clamp `__tcz_thp_vismap` to the scheme list**

Replace the body's `down` clamp:

```fish
        set vp (math $vp + 1)
        test $vp -gt $n; and set vp $n
```

with:

```fish
        set vp (math $vp + 1)
        set -l last (math $n - 1)
        test $last -lt 0; and set last 0
        test $vp -gt $last; and set vp $last
```

Replace the `--description` with:

```
pure: move the picker cursor one step within the SCHEME list — scheme_0 … scheme_{n-1} (sel 0..n-1). up = max(0, sel-1); down = min(n-1, sel+1). The second list (current + off) is a SEPARATE list with its own cursor, reached only with ⇥, so this never leaves the scheme range.
```

- [ ] **Step 5: Add the focus state**

In `__tcz_theme_picker`, immediately after the anchor snapshot block (`set -l anch_mode $mode`), add:

```fish
    # Two-list model. The scheme list owns `sel` (0..n-1); the second list — the
    # current theme and off — owns `sel2` (0 = current, 1 = off). ⇥ moves between
    # them and ↑↓ never crosses. This replaces the old linear order, where off was
    # sel n and the current row was an sel n+1 tail reachable only by pressing c.
    set -l focus list
    set -l sel2 0
```

- [ ] **Step 6: Rewire the draw**

Replace the schemes separator line:

```fish
        set -l below (math "$n - $start - $count")
        set -l marks ''
        test $start -gt 0; and set marks "$marks ▲$start"
        test $below -gt 0; and set marks "$marks ▼$below"
        set -a lines (__tcz_thp_zsep $IW 'schemes · near-seed → bold'"$marks" $BORDER $RST)
```

with:

```fish
        # Bare `schemes`: the subtitle and the ▲n ▼n scroll counts are gone at the
        # user's request. KNOWN COST, accepted: those counts were the only cue that
        # the list scrolls at all. It still scrolls; you just cannot see how much.
        set -a lines (__tcz_thp_zsep $IW schemes $BORDER $RST)
```

In the scheme-row loop, make selection depend on focus, and drop the chevron flag:

```fish
                set -l selflag 0
                test $focus = list; and test $i -eq $sel; and set selflag 1
                set -l curflag 0
                test "$recipes[$idx]" = "$anch_scheme|$anch_place|$anch_mode"; and test "$phase" = "$anch_phase"; and set curflag 1
                set -l row (__tcz_thp_row "$pals[$idx]" $toks[$idx] $selflag $curflag)
```

(`curflag` keeps its name but now means "render this name as the current entry" — Task 5 Step 8 changes `__tcz_thp_row` accordingly.)

Replace the pinned off row, the `current` zsep and the anchor row — i.e. everything from `set -l offflag 0` through the `set -a lines (__tcz_thp_ln "$anchrow" …)` line — with:

```fish
        # ── second list: the current theme and off. Untitled: no word covers both,
        # and the user would rather have none than a bad one. ⇥ moves the cursor here.
        set -a lines (__tcz_thp_zsep $IW '' $BORDER $RST)
        set -l curflag2 0
        test $focus = state; and test $sel2 -eq 0; and set curflag2 1
        set -l anchcells (__tcz_thp_band "$legacy")
        test -n "$anchpal"; and set anchcells (__tcz_thp_cells "$anchpal")
        set -l currow (__tcz_thp_staterow $IW "$anchcells" "$anch_scheme" current $curflag2 $islive)
        if test $curflag2 -eq 1
            set currow (string replace -a -- "$RST" "$RST$SELBG" "$currow")
            set currow "$SELBG$currow$RST"
        end
        set -a lines (__tcz_thp_ln "$currow" $IW $BORDER $RST)
        set -l offflag 0
        test $focus = state; and test $sel2 -eq 1; and set offflag 1
        set -l offrow (__tcz_thp_staterow $IW (__tcz_thp_band "$legacy") 'legacy look' off $offflag 0)
        if test $offflag -eq 1
            set offrow (string replace -a -- "$RST" "$RST$SELBG" "$offrow")
            set offrow "$SELBG$offrow$RST"
        end
        set -a lines (__tcz_thp_ln "$offrow" $IW $BORDER $RST)
```

`$islive` is introduced in Task 6. Until then, add `set -l islive 1` immediately above the second-list block so this task stands alone; Task 6 replaces that line with the real computation.

Also simplify the window anchor — `sel` can no longer exceed `n-1`, so the clamp is dead:

```fish
        set -l win (__tcz_thp_window $sel $n $WIN)
```

- [ ] **Step 7: Rewire the dispatch**

In the `case up down pgup pgdn` arm, replace the movement application (the `set -l dir down` block through the `for _i in …` loop) with:

```fish
                if test $focus = state
                    # the second list is two rows; clamp within it
                    set sel2 (math "$sel2 + $steps")
                    test $sel2 -lt 0; and set sel2 0
                    test $sel2 -gt 1; and set sel2 1
                else
                    set -l dir down
                    test $steps -lt 0; and set dir up
                    for _i in (seq (math "abs($steps)"))
                        set sel (__tcz_thp_vismap $sel $n $dir)
                    end
                end
```

Replace the whole `case c` arm with:

```fish
            case tab
                # move between the two lists. `c` is retired: a key meaning "current"
                # that lands on current, from which you arrow to off, promises one
                # thing and does another. ⇥ carries no such claim and toggles back.
                test $focus = list; and set focus state; or set focus list
                set flashfield ''
```

In the `case m` arm, replace the post-reload clamp:

```fish
                test $sel -gt (math $n + 1); and set sel (math $n + 1)
```

with:

```fish
                set -l lastrow (math $n - 1)
                test $lastrow -lt 0; and set lastrow 0
                test $sel -gt $lastrow; and set sel $lastrow
```

In the `case z` arm, add `set focus list` immediately after `set sel $zi` — a shake lands on a scheme, so the cursor belongs in the scheme list.

- [ ] **Step 8: Drop the chevron from the scheme row**

In `__tcz_thp_row`, replace:

```fish
    set -l curpre ''
    if test "$current" = 1
        set -l CUR (printf '\e[38;5;179m')
        set -l R2 (printf '\e[0m')
        set curpre "$CUR❯ $R2"
    end
    printf '%s%s %s%s%s%s' "$marker" "$cells" "$curpre" "$namecol" "$name" (__tcz_theme reset)
```

with:

```fish
    # The current entry is marked by its NAME, in brand bold — the same language as
    # the second list's `current` label. The old ❯ prefix is gone: it sat on a row
    # that is never the cursor while wearing a glyph that means "cursor".
    if test "$current" = 1; and test "$selected" != 1
        set namecol (__tcz_theme brand)(printf '\e[1m')
    end
    printf '%s%s %s%s%s' "$marker" "$cells" "$namecol" "$name" (__tcz_theme reset)
```

and change the `--description`'s tail from `+ [current chevron +] name; … <current> = 1 prefixes name with "❯ " in switcher yellow` to `+ name; … <current> = 1 renders the name in brand bold (the current entry), unless the row is also the cursor, where the selection styling wins`.

- [ ] **Step 9: Update the legend**

Replace the legend line:

```fish
        for lline in (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake c current  a apply '⏎' save esc close)
```

with:

```fish
        for lline in (__tcz_thp_leg 3 '↑↓' move '⇞⇟' page b seed  m more z shake '⇥' current/off  a apply '⏎' save esc close)
```

- [ ] **Step 10: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`. Assertions elsewhere that pinned the old linear model (`sel n+1`, the `c` key, `vismap never yields n+1`) must be rewritten to the two-list model, not deleted.

- [ ] **Step 11: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 12: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): off joins current in a second list; ⇥ moves between them

off was never a catalog entry — like current it is a state of the install, and it
was drawn OUTSIDE the scroll window so it sat on screen no matter where you had
scrolled. Ordering was never the problem; visibility was.

The two now share an untitled section at the bottom, as a second selectable list
with its own cursor. ⇥ moves between the lists and ↑↓ never crosses. `c` is
retired — a key meaning "current" that lands on current, from which you arrow to
off, promises one thing and does another.

Both chevrons are gone. The current entry in the scheme list is marked by its name
in brand bold instead, matching the `current` label's language, with no glyph
pretending to be a cursor. The schemes rule loses its subtitle and scroll counts.

Frame arithmetic: pinned off row -1, off staterow +1, net 0 — still exactly 26.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 6: `current` as a live-state readout

**Files:**
- Modify: `functions/tmux-categorize.fish` — `previewed` becomes three-valued; the draw computes `islive`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: the `focus` model (Task 5), `__tcz_thp_staterow`'s `<live>` argument (Task 3)
- Produces: `islive` — 1 when the persisted theme is what is actually applied.

Row composition unchanged.

`previewed` is today a bare 0/1 flag set at two different apply sites — previewing the current row and previewing a listed scheme both set it to 1 — so it cannot answer "is what's on the bar still the persisted theme". It becomes three-valued.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 5 block:

```fish
# ---------------------------------------------------------------------
# `current` is a live-state readout, not a static label
# ---------------------------------------------------------------------
set -g PK3 (functions __tcz_theme_picker | string collect)
# previewed is three-valued: 0 none, 1 a listed scheme, 2 the current row
t "preview state distinguishes the current row" 1 (string match -q '*set previewed 2*' -- "$PK3"; and echo 1; or echo 0)
t "preview state distinguishes a listed scheme" 1 (string match -q '*set previewed 1*' -- "$PK3"; and echo 1; or echo 0)
# live is "not previewing something else"
t "islive is derived from previewed" 1 (string match -q '*set -l islive*' -- "$PK3"; and echo 1; or echo 0)
t "islive is false only for a listed preview" 1 (string match -q '*test $previewed -eq 1*islive 0*' -- "$PK3"; and echo 1; or echo 0)
# the revert on cancel must still fire for BOTH preview kinds
t "cancel reverts for any preview" 1 (string match -q '*test $previewed -ne 0*' -- "$PK3"; and echo 1; or echo 0)
# and the placeholder from Task 5 is gone
t "the islive placeholder is gone" 0 (string match -q '*set -l islive 1*' -- "$PK3"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "preview state|islive|cancel reverts"
```

Expected: `FAIL` on the three-valued assertions, `islive is derived`, `cancel reverts for any preview`, and `the islive placeholder is gone`.

- [ ] **Step 3: Make `previewed` three-valued**

In the `case a` arm, the current-row branch already reads `set previewed 1` — change it to:

```fish
                    set previewed 2
```

Leave the listed-scheme branch's `set previewed 1` as it is. Add a comment above the arm:

```fish
            # previewed: 0 none, 1 a LISTED scheme, 2 the current row. The distinction
            # matters because previewing the current row still leaves the persisted
            # theme on the bar — so `current` stays lit. It is never reset: `cancel`
            # needs it to know a revert is owed.
```

- [ ] **Step 4: Compute `islive` in the draw**

Replace the Task 5 placeholder `set -l islive 1` with:

```fish
        # `current` is lit only while the persisted theme really is what is applied.
        # Previewing the current row (previewed 2) still satisfies that; previewing a
        # listed scheme (previewed 1) does not.
        set -l islive 1
        test $previewed -eq 1; and set islive 0
```

- [ ] **Step 5: Widen the cancel revert**

In the `case cancel` arm, replace:

```fish
                if test $previewed -eq 1
```

with:

```fish
                if test $previewed -ne 0
```

- [ ] **Step 6: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`.

- [ ] **Step 7: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 8: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(picker): `current` lights only while it is what is actually applied

previewed was a bare flag set at two different apply sites, so it could not tell
"previewing the current row" (which still leaves the persisted theme on the bar)
from "previewing a listed scheme" (which does not). It is now three-valued and
the label follows it: bold orange when live, muted the moment you preview
something else.

That readout is what makes removing the chevron safe — it says something the
chevron never did. cancel's revert widens to fire for either preview kind.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 7: Esc restores the seed

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_sliders` and `__tcz_thp_hexentry` become preview-only; `case enter` commits the seed; `case cancel` restores it
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: the `focus` model (Task 5)
- Produces: nothing new.

Row composition unchanged.

The seed screens commit immediately via `tmux-lives setup color`, which writes the universal, re-renders the fragment and applies. The picker never captured the original, so `cancel` has nothing to restore to — and since every role derives from the seed, the scheme looks unrestored too. They become preview-only; `⏎` commits.

**No engine change is needed.** `__tmux_lives_key` reads `set -q <name>` then `echo $$name`, so a `set -g tmux_lives_bar_color <seed>` inside the `fish -c` child **shadows the universal** for that child only — verified. Live preview with a candidate seed therefore costs one extra assignment in the existing `fish -c` invocation.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 6 block:

```fish
# ---------------------------------------------------------------------
# Esc restores the seed: the seed screens are preview-only, ⏎ commits
# ---------------------------------------------------------------------
set -g SLB (functions __tcz_theme_picker | string collect)
# the seed screens must no longer persist anything
t "seed screens do not run setup color" 0 (count (string match -ra 'setup color' -- "$SLB"))
# the anchor snapshot carries the seed so cancel can restore it
t "anchor snapshot captures the seed" 1 (string match -q '*set -l anch_seed*' -- "$SLB"; and echo 1; or echo 0)
# live preview shadows the universal in the child rather than writing it
t "preview shadows the seed in the child" 1 (string match -q '*set -g tmux_lives_bar_color*' -- "$SLB"; and echo 1; or echo 0)
# saving commits the seed — exactly once, in the EXIT path, never in a seed screen.
# awk scopes the two seed screens out first; `setup color` must survive only outside them.
set -g SEEDSCREENS (awk '/^    function __tcz_thp_sliders/,/^    end$/' $catfile; awk '/^    function __tcz_thp_hexentry/,/^    end$/' $catfile | string collect)
t "no setup color inside the seed screens" 0 (count (string match -ra 'setup color' -- "$SEEDSCREENS"))
t "exactly one setup color in the picker"  1 (count (string match -ra 'setup color' -- "$SLB"))
t "the commit is guarded on a changed seed" 1 (string match -q '*"$seed" != "$anch_seed"*' -- "$SLB"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "seed screens|anchor snapshot captures|preview shadows|enter commits"
```

Expected: `FAIL` on `seed screens do not run setup color`, `anchor snapshot captures the seed`, and `preview shadows the seed in the child`.

- [ ] **Step 3: Capture the seed in the anchor snapshot**

In the anchor snapshot block, add:

```fish
    set -l anch_seed $seed
```

- [ ] **Step 4: Make the seed screens preview-only**

In `__tcz_thp_sliders`, replace the commit:

```fish
                    fish -c 'tmux-lives setup color $argv[1]' (printf '#%02x%02x%02x' $r $g $b) >/dev/null 2>&1
```

with:

```fish
                    # PREVIEW ONLY — ⏎ at the top level is what commits. Writing the
                    # universal here is why Esc could not restore the seed: it was
                    # already gone, and every role derives from it, so the scheme
                    # looked unrestored too even with its own universals intact.
                    set seed (printf '#%02x%02x%02x' $r $g $b)
                    set seedfg (__tmux_lives_contrast_fg "$seed")
                    __tcz_thp_reload
```

Apply the same change in `__tcz_thp_hexentry` wherever it commits the typed hex — replace its `setup color` invocation with the same three lines, using its own assembled hex.

- [ ] **Step 5: Preview with the candidate seed**

In the `case a` arm, both branches call `fish -c '__tmux_lives_theme_apply_live $argv' …`. Prefix each with a seed shadow so the preview reflects an uncommitted seed:

```fish
                    fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $anch_scheme $anch_place $anch_mode $anch_phase $anch_viv $anch_shape $anch_ease $anch_contrast >/dev/null 2>&1
```

and for the listed-scheme branch:

```fish
                    fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live $argv[2..]' "$seed" $rel $rplace $rmode $phase $viv $shape $ease $contrast >/dev/null 2>&1
```

- [ ] **Step 6: Commit the seed on save, restore it on cancel**

In the exit path, before the existing `setup theme` invocation, add:

```fish
    # Commit the seed only if it actually moved — `setup color` re-renders the
    # fragment, and every fragment write re-sources status-right.
    if test -n "$apply"; and test "$seed" != "$anch_seed"
        fish -c 'tmux-lives setup color $argv[1]' "$seed" >/dev/null 2>&1
    end
```

In the `case cancel` arm, replace:

```fish
                if test $previewed -ne 0
                    fish -c __tmux_lives_theme_apply_live >/dev/null 2>&1
                end
```

with:

```fish
                # Restore BOTH. Restoring the theme alone is what made this look
                # broken: every role derives from the seed, so a correct theme
                # rendered against a changed seed still is not what you started with.
                if test $previewed -ne 0; or test "$seed" != "$anch_seed"
                    fish -c 'set -g tmux_lives_bar_color $argv[1]; __tmux_lives_theme_apply_live' "$anch_seed" >/dev/null 2>&1
                end
```

- [ ] **Step 7: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`.

- [ ] **Step 8: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 9: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
fix(picker): Esc restores the seed — the seed screens are preview-only

The RGB slider and typed-hex screens committed immediately via `setup color`,
which writes the universal, re-renders the fragment and applies. The picker never
captured the original, so cancel had nothing to restore to — and since every role
derives from the seed, the scheme looked unrestored too even with its own
universals correct. One root cause, both halves of the report.

⏎ now commits, and only when the seed actually moved. No engine change was
needed: __tmux_lives_key reads `set -q` then `$$name`, so a `set -g` inside the
existing `fish -c` child shadows the universal for that child alone — verified —
which is enough to preview an uncommitted seed on the real bar.

Chosen over capture-and-restore because that writes the seed twice, and every
fragment write re-sources status-right.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 8: Held ↑↓ rate-limits with discard

**Files:**
- Modify: `functions/tmux-categorize.fish` — the `case up down pgup pgdn` drain loop
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: the `focus` model (Task 5)
- Produces: nothing new.

Row composition unchanged.

The 2026-07-29 coalescing **sums** the burst and applies it as one net move — its own comment says "a held key then scrolls FASTER (more rows per redraw)". That fixed an unbounded redraw backlog but traded it for this: intermediate positions are never drawn, and release lands on the accumulated total rather than the last row the user saw. The requested behaviour is neither: **rate-limit with discard**.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, after the Task 7 block:

```fish
# ---------------------------------------------------------------------
# held ↑↓ rate-limits with DISCARD, it does not accumulate
# ---------------------------------------------------------------------
set -g DRAIN (string match -r '(?s)case up down pgup pgdn.*?case tab' -- (functions __tcz_theme_picker | string collect))
t "the drain arm was found" 1 (test -n "$DRAIN"; and echo 1; or echo 0)
# a queued up/down must NOT add to steps — that is the accumulate-and-jump bug
t "queued arrows do not accumulate" 0 (count (string match -ra 'case up;   set steps \(math "\$steps - 1"\)' -- "$DRAIN"))
t "queued arrows are swallowed"     1 (string match -q '*case up down; set gap 1*' -- "$DRAIN"; and echo 1; or echo 0)
# pages DO still coalesce — they are discrete and not autorepeated
t "pages still coalesce" 1 (string match -q '*case pgup;*steps*WIN*' -- "$DRAIN"; and echo 1; or echo 0)
# the drain-hang guard must survive: readkey's CSI branch leaves the tty BLOCKING
t "drain re-asserts non-blocking inside the loop" 1 (string match -q '*while true*stty min 0 time $gap*' -- "$DRAIN"; and echo 1; or echo 0)
t "drain restores blocking on exit" 1 (string match -q '*stty min 1 time 0*' -- "$DRAIN"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | grep -E "drain arm|queued arrows|pages still|drain re-asserts|drain restores"
```

Expected: `FAIL` on `queued arrows do not accumulate` and `queued arrows are swallowed`.

- [ ] **Step 3: Replace accumulate with discard**

In the `case up down pgup pgdn` arm, replace the drain loop's `switch "$k2"`:

```fish
                    switch "$k2"
                        case up;   set steps (math "$steps - 1"); set gap 1
                        case down; set steps (math "$steps + 1"); set gap 1
                        case pgup; set steps (math "$steps - $WIN"); set gap 1
                        case pgdn; set steps (math "$steps + $WIN"); set gap 1
                        case '*';  break
                    end
```

with:

```fish
                    switch "$k2"
                        # SWALLOW queued autorepeats without counting them. Summing the
                        # burst (the 2026-07-29 form) moved many rows per redraw, so the
                        # intermediate positions were never drawn and release landed on
                        # the accumulated total rather than the last row you saw. One row
                        # per render cycle instead: a held key scrolls at whatever rate
                        # the terminal can actually paint, and release stops where it is.
                        case up down; set gap 1
                        # pages DO coalesce — discrete, not autorepeated in practice
                        case pgup; set steps (math "$steps - $WIN"); set gap 1
                        case pgdn; set steps (math "$steps + $WIN"); set gap 1
                        case '*';  break
                    end
```

Also replace the arm's leading comment block (the one beginning "Drain-coalescing, the same shape the phase arrows have used since 2026-07-19") with:

```fish
                # Drain, then move ONE row. The drain is what prevents the original
                # defect — an unbounded redraw backlog that kept scrolling for seconds
                # after release — but it must not COUNT what it swallows. Re-assert
                # non-blocking INSIDE the loop: readkey's CSI branch leaves the tty
                # blocking on return, and a drain read after it hangs (hit for real once).
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
fish tests/test-tmux-categorize.fish </dev/null 2>&1 | tail -1
```

Expected: `ALL PASS`.

- [ ] **Step 5: Run the full gate, both fish modes**

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 6: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
fix(picker): held arrows rate-limit with discard instead of summing the burst

The 2026-07-29 coalescing summed every queued autorepeat and applied it as one
net move — its own comment says a held key "scrolls FASTER (more rows per
redraw)". That fixed an unbounded redraw backlog but traded it for this: the
intermediate positions were never drawn, so you could not see what you were
scrolling, and release landed on the accumulated total rather than the last row
you actually saw.

The drain stays — it is what prevents the backlog — but it now swallows queued
arrows without counting them, so movement is one row per render cycle and release
stops where the cursor is visibly drawn. Pages still coalesce; they are discrete
and not autorepeated.
EOF
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -F /tmp/msg.txt
```

---

## Task 9: Verify the frame, document, and finish

**Files:**
- Modify: `CLAUDE.md`
- Test: no new tests; this task is the whole-branch verification

- [ ] **Step 1: Prove the frame is exactly 26 rows in every state**

This is the assertion the plan's arithmetic has been promising, and it must be measured, not reasoned. Add to `tests/test-tmux-categorize.fish`:

```fish
# The popup is -h 26 and the draw must emit EXACTLY 26 rows in every state, or the
# top border scrolls off (shipped once already). Count the `set -a lines` sites and
# the window, rather than trusting arithmetic in a comment.
set -g DRAWBODY (functions __tcz_theme_picker | string collect)
t "frame: WIN is 11"                1 (string match -q '*set -l WIN 11*' -- "$DRAWBODY"; and echo 1; or echo 0)
t "frame: legend is 3 rows"         1 (string match -q '*__tcz_thp_leg 3*' -- "$DRAWBODY"; and echo 1; or echo 0)
t "frame: two untitled rules"       2 (count (string match -ra "thp_zsep .IW ''" -- "$DRAWBODY"))
t "frame: popup height still 26"    1 (string match -q '*-w 52 -h 26*' -- (cat $catfile | string collect); and echo 1; or echo 0)
t "frame: no stale popup heights"   0 (count (string match -ra '\-w 52 \-h (2[0-57-9]|1[0-9])' -- (cat $catfile | string collect)))
```

Run the suite; expected `ALL PASS`.

- [ ] **Step 2: Full verification**

```bash
bash -c 'for m in "" "--no-config"; do echo "-- fish $m --"; for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; timeout 150 fish $m "$t" </dev/null 2>&1 | tail -1; done; done'
bash -c 'fish --no-config -c "set -g tmux_categorize_test 1; source functions/tmux-categorize.fish" 2>&1 >/dev/null | wc -c'
```

Expected: 8 `ALL PASS` in each mode, and `0` stderr bytes.

- [ ] **Step 3: Update `CLAUDE.md`**

Append to the theme/picker section, matching the file's dense-prose style:

```markdown
**Picker second list + layout revision + input fixes (2026-08-01, `feat/picker-second-list`; spec `docs/superpowers/specs/2026-08-01-picker-second-list-design.md`, plan `docs/superpowers/plans/2026-08-01-picker-second-list.md`):** `off` LEFT the scheme list — it was drawn OUTSIDE the scroll window, so it sat on screen wherever you scrolled ("I don't need to be reminded of it while I'm scrolling"); ordering was never the problem, visibility was, and conceptually it is a state of the install like `current`, not a catalog entry. The two now share an **untitled** section as a **second selectable list**: **`⇥` (Tab, byte `0x09`, added to the SHARED `__tcz_popup_readkey` — proven a no-op for the switcher, which has no `case '*'`)** moves the cursor between the lists and `↑↓` clamps within whichever has focus. Selection is now `focus` (`list`/`state`) + `sel` (`0..n-1`) + `sel2` (`0`=current, `1`=off), replacing the linear `0..n-1`/`n`=off/`n+1`=current-reachable-only-by-`c` model; **`c` is retired** (a key meaning "current" that lands on current, from which you arrow to off, promises one thing and does another). New pure builder **`__tcz_thp_staterow <w> <cells> <name> <label> <selected> <live>`** replaces `__tcz_thp_off_row`: swatch, name left, role label **flush right**. **`current` is a LIVE-STATE readout** — bold `brand` only while the persisted theme is what is actually applied; `previewed` became three-valued (`0` none / `1` a listed scheme / `2` the current row) because a bare flag could not tell "previewing the current row" (still live) from "previewing a listed scheme" (not). **BOTH chevrons are gone** — the current entry in the list is marked by its NAME in brand bold instead (no glyph pretending to be a cursor); the hard-coded `\e[38;5;179m` switcher-yellow went with them. Layout: `SEED` label+value on ONE row (`__tcz_thp_kv`/`__tcz_thp_spread` deleted — kv was the only caller of itself and spread's only caller was kv), zone renamed **`configuration`**, all separator titles in a new **`title`** role (`#d2782a`, brand pulled down ~18%), schemes rule stripped of its subtitle AND its `▲n ▼n` counts (**known accepted cost: those were the only cue that the list scrolls**), and the freed row went to the window — **`WIN` 10→11**, frame still EXACTLY 26 (15 static + 11). Swatches are now **`▇` (U+2587) in the role colour, not a filled cell**, leaving one eighth clear at the top so stacked strips stop merging (`__tcz_thp_cells`/`__tcz_thp_band`; the selection band shows through the gap for free, since the draw already re-asserts `sel-bg` after every reset). **Esc restores the SEED:** the RGB-slider and typed-hex screens are **preview-only** and `⏎` commits — they used to call `setup color` immediately, so the original was gone before Esc could restore it, and since every role derives from the seed the scheme looked unrestored too (ONE root cause, both halves of the report). **No engine change was needed**: `__tmux_lives_key` reads `set -q` then `$$name`, so a `set -g tmux_lives_bar_color` inside the existing `fish -c` child SHADOWS the universal for that child alone — enough to preview an uncommitted seed on the real bar. Chosen over capture-and-restore because that writes the seed twice and every fragment write re-sources `status-right`. **Held `↑↓` now rate-limits with DISCARD:** the 2026-07-29 drain SUMMED the burst ("a held key scrolls FASTER") so intermediate positions were never drawn and release landed on the accumulated total, not the last row you saw; the drain stays (it is what prevents the redraw backlog) but swallows queued arrows without counting them — one row per render cycle. Pages still coalesce. ⚠️ The drain-hang guard is load-bearing: `stty min 0 time $gap` MUST be re-asserted INSIDE the loop, because readkey's CSI branch leaves the tty blocking. **Pending live smoke:** the `⇥` feel, the `▇` gap on a real Nerd Font, the `current` label lighting/dimming as you preview, and Esc restoring a changed seed.
```

- [ ] **Step 4: Commit the docs**

```bash
cat > /tmp/msg.txt <<'EOF'
docs(claude): record the picker second list, layout revision, and input fixes
EOF
git add CLAUDE.md
git commit -F /tmp/msg.txt
```

- [ ] **Step 5: Request review**

Use `superpowers:requesting-code-review` for a whole-branch review before merging. Do not skip it — the last three cycles each had a real defect caught only at whole-branch review, including a vacuous test suite and a guard that failed open.

- [ ] **Step 6: Finish the branch**

Use `superpowers:finishing-a-development-branch`. The project default is **merge to `main` locally, then push** — do not open a PR and do not ask which option.

**Do NOT deploy.** Finished changes reach the live `~/.config/fish/` only via the user's own `fisher update`.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 frame (15 static + 11 window = 26) | Task 4 (arithmetic), Task 5 (arithmetic), Task 9 (measured) |
| §2 configuration zone, horizontal SEED, kv/spread deleted | Task 4 |
| §3 the `title` role | Task 1 |
| §4 schemes rule loses subtitle + counts | Task 5 |
| §5 the second list + `__tcz_thp_staterow` | Task 3 (builder), Task 5 (wiring) |
| §6 `current` as a live-state readout, `previewed` three-valued | Task 6 |
| §7 both chevrons go | Task 3 (current row), Task 5 (list row) |
| §8 swatch separation | Task 2 |
| §9 `⇥` moves between the lists, `c` retired, legend | Task 5 |
| §10 Esc restores the seed | Task 7 |
| §11 held ↑↓ rate-limits with discard | Task 8 |
| Testing — builders, frame, guards, input, seed | Tasks 1-8 inline, Task 9 for the frame |
| Non-goals | No tasks, by definition |

No gaps.

**Placeholder scan:** none. Every code step carries the literal code; every test step the literal assertions.

**Type consistency:** `__tcz_thp_cells`/`__tcz_thp_band` are introduced in Task 2 and consumed by Task 3's `staterow` and Task 5's draw with the same signatures. `__tcz_thp_staterow`'s 6 arguments are fixed in Task 3 and called identically in Task 5. `focus`/`sel2` are introduced in Task 5 and read in Tasks 6, 7, 8. `islive` is introduced as a placeholder in Task 5 Step 6 and replaced by the real computation in Task 6 Step 4 — Task 6 asserts the placeholder is gone, so the two cannot both survive.

**Three risks worth naming for the implementer:**

1. **Task 5 is the largest task and touches the draw and the dispatch together.** They cannot be split without leaving the frame broken between commits. Read the current `__tcz_theme_picker` body before editing rather than trusting these snippets to match byte-for-byte.
2. **Existing assertions pin the old model.** Tasks 3, 4 and 5 will each break tests elsewhere in `test-tmux-categorize.fish` that assert `❯`, `sel n+1`, the `c` key, `adjustments`, or `WIN 10`. Every one of those must be **rewritten to the new model, not deleted** — deleting them silently drops coverage.
3. **Task 7's seed-commit assertions depend on the two seed screens being NESTED functions** (`__tcz_thp_sliders` and `__tcz_thp_hexentry` are defined inside `__tcz_theme_picker` with `--no-scope-shadowing`, so their `function`/`end` lines are indented four spaces — which is what the `awk` ranges match). If a task moves either to top level, the ranges silently match nothing and both assertions pass vacuously. Verify the `awk` extraction is non-empty before trusting it — `test -n "$SEEDSCREENS"` is a one-line guard.
