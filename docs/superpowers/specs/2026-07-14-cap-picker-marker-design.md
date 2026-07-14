# Cap-picker — active-column marker + frame fixes (design)

**Date:** 2026-07-14
**Status:** approved
**Branch:** `fix/cap-picker-marker`
**Follows:** `2026-07-13-cap-picker-v2-design.md` (shipped @ `853f30c`)

## Why

The user's first live smoke of cap-picker v2 surfaced three problems, two of them
regressions introduced by that ship:

1. **The popup has no top border.**
2. **The `d m a` header letters don't line up with the swatch columns**, and the
   misalignment *changes* as `←→` moves the active role.
3. **The tan `▎` active-column marker is jarring** — it competes with the colour
   scheme it exists to help you read, and it is the *same colour* as the `▐`
   selection marker.

## Root causes (diagnosed, not guessed)

**Top border.** The frame emits exactly **22 rows** (title · labels · values · sep ·
header · 10 swatch rows · sep · 3 footer · sep · status · bottom). The draw loop runs
`printf '%s\e[K\n' $lines`, so the *last* row also gets a trailing newline, putting the
cursor on row 23 of a 22-row popup. The terminal scrolls one line and row 1 — the top
border — is lost. The symptom (exactly one row gone) confirms `-h 22` yields exactly 22
usable rows, so the popup size is right and the trailing newline is the defect.

**Alignment.** Two independent faults compound:
- The header is `d  m  a` (letter pitch **3**) while the swatch cells are 2 columns wide
  and adjacent (cell pitch **2**). With the strip starting at inner col 3, cells sit at
  3-4 / 5-6 / 7-8 but letters sit at 2 / 5 / 8. Only `m` ever lands correctly.
- `__tcz_cap_swatch_line` **prepends** `▎` to the active cell, which *inserts* a column
  and shifts that cell and everything right of it. The header is static, so it cannot
  track the shift — the misalignment varies with the active role.

The marker is therefore not an innocent bystander to the alignment bug; it is half of it.

## Decision

Adopt **C2**: no per-row marker; underline the active-role cell **on the selected row
only**, in a neutral grey.

Rationale: the per-row marker answers "which swatch on this row is live?" — but the
primary cluster already previews exactly that (swatch + `#hex` + role name) for the row
the cursor is on, and updates as the cursor moves. Marking all ten rows answers a
question that is never asked about rows 4–10, at the cost of a jarring band and the
column shift. C2 puts the cue exactly where it is meaningful and leaves the rest of the
strip an unbroken colour band.

Rejected alternatives:
- **Keep the tan `▎`, make the header track it** — preserves the shift, the split and the
  colour clash. Fixes nothing at the root.
- **Grey `▎` in a constant 1-col gutter** — width-stable (so the header aligns), but the
  gutter must be present on *every* column to stay stable, permanently fragmenting the
  band into three blocks. Trades a jarring marker for a permanently split strip.
- **Underline on every row** — no shift, no split, but 10 stacked underlines turn the
  active column into a hatched band; noisier than the cue is worth.

## Changes

### 1. New theme role `mark`

`__tcz_theme` gains `mark` → `\e[38;2;138;138;138m` (`#8a8a8a`, a true neutral grey).

Distinct from `key` (`#f5cf8a`, tan — the `▐` selector) and from `muted` (`#9a8a72`, a
*warm* tan-grey — description text). The marker must not read as part of the warm palette
or as part of the colour story; it is a rule, not an accent. Neutral grey also stays
legible in both directions: darker than a light swatch (`#a89b00`), lighter than a dark
one (`#4e6242`).

### 2. `__tcz_cap_swatch_line` — underline instead of insert

Signature is unchanged: `<dimhex> <mutedhex> <accenthex> <scheme> <selected> <activecol>`.

- Remove the `▎` prepend entirely. Cells are always adjacent — the strip is always
  exactly 6 visible columns regardless of `activecol`.
- When `selected` = 1, the `activecol` cell is rendered with SGR 4 (underline) plus an
  explicit `mark` foreground, so the rule draws grey:
  `\e[4m<mark>\e[48;2;R;G;Bm  \e[0m`
- When `selected` = 0, no underline on any cell. `activecol` is inert.
- Unchanged: the `▐` selector (`key`) / two-space lead, and the scheme name
  (`sel-fg`+bold when selected, else `muted`).

The helper gets *simpler*: `activecol` stops changing the geometry and only selects which
cell takes a decoration.

### 3. New pure helper `__tcz_cap_dma <activecol>`

Extract the `d m a` header from the picker's draw loop into a pure, unit-testable helper
returning the coloured header at **letter pitch 2** (`d m a`, 5 visible columns), active
letter in `key`, others in `muted`.

Extracting it matters: the alignment is the thing that broke, and inline draw-loop code is
not reachable by the unit suite. As a pure helper its visible width and letter positions
become assertable, so this bug cannot silently return.

### 4. Picker draw loop

- Header row content becomes `"  "` + `__tcz_cap_dma` + gap + legend (2-space lead, so
  `d`/`m`/`a` land at inner cols 3 / 5 / 7 — directly over cells at 3-4 / 5-6 / 7-8).
- Gap formula changes from `($IW - 1) - …` to `($IW - 2) - …` to account for the wider
  lead, keeping the row exactly `IW` wide.
- Suppress the trailing newline on the final row:
  emit rows `1..-2` with `\n`, then row `-1` without. Guard `count $lines -gt 1` — a
  `printf '%s\n'` with a zero-element list prints one spurious blank line (the project's
  recurring zero-output-collapse hazard).

Popup geometry is **unchanged** at `-w 44 -h 22`: with the trailing newline gone, the
22-row frame hugs the 22-row popup exactly — no scroll, no dead row, and no dependence on
the height being a magic number.

## Testing

Pure helpers are unit-tested; the raw-tty draw loop stays manual-smoke (it cannot run in
the sandbox), so its two changes get source-grep guards consistent with the existing
picker tests.

| Behaviour | Test |
|---|---|
| `mark` role returns a truecolor SGR | `test-tmux-categorize.fish` |
| `mark` ≠ `key` and ≠ `muted` | as above (guards the reported colour collision) |
| strip is 6 visible cols for every `activecol` | swatch-line; the anti-shift guard |
| selected row underlines the *active* cell | assert `\e[4m<mark>\e[48;2;<active rgb>` |
| unselected row has no underline at all | assert no `\e[4m` |
| still exactly 3 truecolor cells | retained from v2 |
| `__tcz_cap_dma` is 5 visible cols (`d m a`) | the alignment guard |
| `__tcz_cap_dma` colours only the active letter `key` | per activecol 1/2/3 |
| draw suppresses the final newline | source-grep `$lines[1..-2]` |

## Out of scope

- **`dim` is scheme-invariant.** At the user's bar (`#36442d`), `dim` is `#4e6242` for all
  ten schemes — only `muted`/`accent` take the scheme's hue rotation. At `cap_role = dim`
  (the user's current setting) the scheme choice therefore has no effect on the cap, and
  the `d` column renders as ten identical swatches. Real finding, separate decision
  (engine gap vs. intentional "dim = neutral shade of the bar"); tracked for the user's
  return.
- Phase B whole-bar theming.
