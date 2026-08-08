# Theme picker — legibility and auto-apply

**Date:** 2026-08-08
**Status:** approved, not built
**Supersedes:** the seed-zone portion of `2026-08-07-picker-seed-section-design.md` (that design shipped; this revises it)

## Goal

Make a scheme's colours readable at a glance, give the seed editor room to breathe, and apply a scheme automatically once the cursor settles on it.

## The principle that organizes the costs

The user drew the line during design: **configuration is cheap and private; adoption touches the real bar.** Seeing a colour on the actual status bar and tab strip means you are close to choosing it.

| | reaches | cost | trigger |
|---|---|---|---|
| Configuration | the picker only | ~40 ms | seed drag, live scheme regeneration |
| Adoption-adjacent | real bar + tab strip | 200–400 ms | landing on a scheme row, `a`, `⏎` |

Auto-apply obeys this rather than violating it: settling on a scheme row already means "this is a candidate." Dragging a slider does not.

## Facts this design rests on

Each was measured, not assumed.

- On the user's iPad, five full-width ShellFish tabs occupy ~46 px above a ~23 px tmux status row that is mostly bare background. **`tabs` covers roughly 1.8× the area of `bar`.**
- `sep` renders zero pixels in a single-window session. It is wired and painted; only circumstance hides it.
- `active` renders zero pixels in every session. `__tmux_lives_theme_apply_live` pushes `@tmux_lives_active_fg` and **no format string reads it.**
- At seed `#ffb31f`, the curated rows `mono soft`, `wheat soft` and `amber soft` share five of seven roles. Only `tabs` and `cap` differ.
- One palette costs ~40 ms; the 14-row batch costs 310–400 ms; all 35 rows cost 700–800 ms.
- `case enter` already keeps the seed and stays in the picker while `editing` is 1. The footer, which is static, advertises `⏎ save` and `esc close` in that state and names none of the channel keys.

## 1 · The seed zone becomes mode-dependent

Today the zone is a fixed 8 rows so the scheme list never shifts. The user chose movement over stillness: a compact idle zone shows more schemes, and edit mode gets real space.

**Idle — 3 rows.** A `seed` separator, then a 2-row square block in the seed colour. Terminal cells run about 2:1, so two rows read as a square. The hex and the hue/lightness/chroma readouts sit to the right of the block, in space that was already empty.

**Editing — 8 rows.** The same separator and square, one blank row, the three channel bars adjacent, one blank row. Space surrounds the block; no space divides the channels.

Deleted: the duplicated hex and readouts, and the copy reading "rendered as-is on the bar; companions derive from it."

**`STATIC` stops being a constant.** It becomes 16 idle and 21 editing, so `WIN = rows − STATIC(editing)`. A 52-row popup shows **36 schemes idle** and 31 editing, against 31 today. Two invariants hold: the draw emits exactly `rows` lines in both states, and the window re-clamps on every mode change so **the selected row stays visible**.

## 2 · Row anatomy

**Swatch field — 15 cells, ordered by on-screen area.**

| cells | role | tier |
|---|---|---|
| 5 | `tabs` | big |
| 4 | `bar` | big |
| 2 | `cap` | big |
| 1 | — | blank, the tier boundary |
| 1 | `windows` | trim |
| 1 | `sep` | trim |
| 1 | `text` | trim |

The blank column carries the boundary. Width alone signals weakly; a break signals plainly. `active` earns a fourth trim cell once §5 wires it, taking the field to 16.

**Marker — `▌` (U+258C, left half block), replacing `▐` (U+2590, right half block).** Both glyphs are half-width and full-height, so nothing mismatches the `▇` swatches. The frame's `│` inks the centre of its cell and `▌` inks the left half of the next, which leaves **0.5 cell clear on each side** of the marker. The symmetry costs no extra column.

A half-*width* swatch cell was designed and rejected: `▐` is full height where `▇` is 7/8, so the leading cell stood one eighth taller.

**Highlight — the marker's cell through to the right frame glyph.** Both `│` characters stay bare.

## 3 · Auto-apply

`A` toggles it. The universal `tmux_lives_theme_autoapply` persists it. It defaults on.

An apply fires **~400 ms after movement stops** and never during a burst. Holding `↓` applies nothing; releasing applies the row you landed on. Scheme rows and the `current`/`off` rows behave alike. Each apply re-emits the tab colour, so ShellFish tracks it at once.

The dwell reuses the settle primitive that already defers the seed batch.

⚠️ **`A` (byte `0x41`) is absent from `__tcz_popup_readkey`'s outer switch, so the key cannot fire until the mapping exists.** Proven behaviourally: `printf A | __tcz_popup_readkey` returns `other`, where `printf a` returns `a`.

⚠️ **Do not verify this with a grep — `case 41` already appears in the function and means something else.** Inside the ESC branch, `0x41` is the final byte of `ESC [ A`, the up arrow. So the two switches both need `case 41` for unrelated purposes, and grepping the function finds the arrow handler and suggests `A` is wired. I made exactly that mistake while reviewing this spec, twice, before a one-line behavioural test settled it. Adding `case 41; echo A` to the outer switch is safe; the switches are separate.

That reader is shared with the session switcher, and this repo's standing convention pairs every token added to it with two guards: one asserting the mapping resolves, one asserting the switcher has no arm for the token. `c` and `⇥` both got the pair; `t` shipped without it last branch, and the whole feature proved deletable by removing one line with all eight suites green. Scope the switcher guard through `functions __tcz_popup | string collect` rather than an indentation anchor — an `awk` range keyed on indentation matches the switcher's own cases earlier in the file.

The reader also still carries `V S E D O P M`, mappings whose consumers were removed with the vividness, shape, ease, contrast, rotate and placement knobs. Leave them; retiring dead mappings belongs to its own pass.

## 4 · The legend becomes mode-aware

This fixes the reported ENTER bug, which lives in the footer rather than the dispatch.

**Browsing:** `↑↓ move · ⇞⇟ page · b seed · m more · z shake · ⇥ current/off · a apply · A auto · ⏎ save · esc close`

**Editing:** `↑↓ channel · ←→ adjust · t type hex · ⏎ keep · esc revert`

## 5 · Cleanup in the same pass

- Delete `__tcz_thp_sliders` (~90 lines) and `__tcz_thp_seedrow`. Both lost their last caller when the seed zone absorbed them.
- Point `window-status-current-format` at `@tmux_lives_active_fg`. One line gives the current window its own colour and retires a role that computes into nothing.

## Non-goals

- **The engine keeps its current derivation.** `tabs` leads the *display*; it does not lead the *derivation*. A scheme that needs the tab colour to cohere collapses in cmux, which paints no tab at all. `bar` and `cap` must still stand alone.
- **`t` stays a separate framed screen.** Folding hex entry into the zone would add a second input mode there.
- **The accents redesign waits.** Six of seven roles still resolve to 11 distinct values across 35 rows.

## Testing

- **Frame proof, both modes.** The draw emits exactly `rows` lines idle and editing, across popup heights and both catalog sizes. The harness reads `STATIC` out of the source rather than restating it, so a wrong value fails every size uniformly.
- **Behavioural over textual.** Extract the dispatch arm, stub its input, `eval` it, assert the resulting state. Three consecutive reviews on the previous branch found source-text greps that proved nothing: three had gone silently vacuous, nine survived five real breakages, and one feature died from a single deleted line with the suite green.
- **Window re-clamp.** Scroll deep, enter edit mode, and confirm the selected row remains visible.
- **Dwell.** A burst applies once. A single step applies once. Neither applies twice.
- **Marker and highlight.** Assert the rendered row, not the glyph constant.

Runtime-only, for live smoke after `fisher update`: how `▌` and the 15-cell field read in a Nerd Font, whether 400 ms feels right, and whether the list shifting on `b` reads as movement or as jump.

## Deferred, with reasons

- **`sep` keeps its cell** although it renders nothing today. The user intends to adopt multi-window tmux: "If there's a chance we'll get use out of them, we should keep them."
- **Idle keeps the readouts** parked beside the hex, where they cost no rows.
- **The fallback for the marker** is a leading pad column, if two thin verticals a cell apart read as a double border on real hardware.
