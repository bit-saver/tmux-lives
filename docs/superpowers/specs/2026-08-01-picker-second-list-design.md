# Theme picker — second list, layout revision, and input fixes — design

Status: approved in brainstorm 2026-08-01 (visual companion mocks `15-picker-layout.html`, `16-picker-revised.html`, rendered at the live seed `#4f8728` against the real 52×26 geometry). Supersedes the queued notes in `docs/2026-08-01-theme-picker-issues.md`, which this absorbs. The theme **engine, catalog, CLI and fragment are untouched** — this is entirely `__tcz_theme_picker` and its `__tcz_thp_*` builders in `functions/tmux-categorize.fish`.

## Why

Three defects from live use, plus a layout pass the user asked for after re-reading the picker on screen.

**The `off` row never belonged in the scheme list.** It is drawn outside the windowed list, so it is on screen permanently no matter where you have scrolled — *"I don't need to be reminded of it while I'm scrolling the list."* Ordering was never the problem (it is already last in the selection order); visibility was. And conceptually it is not a catalog entry at all: like `current`, it is a state of the install rather than a scheme you might pick.

**Esc cannot restore the seed.** The RGB slider screen commits it immediately:

```fish
fish -c 'tmux-lives setup color $argv[1]' (printf '#%02x%02x%02x' $r $g $b) >/dev/null 2>&1
```

`setup color` writes the universal, re-renders the fragment and applies live. The picker never captured the original, so `cancel`'s existing `__tmux_lives_theme_apply_live` revert has nothing to restore *to* — and since every role derives from the seed, the scheme looks unrestored too even though its universals are correct. One root cause, two symptoms.

**Held ↑↓ outruns the render and overshoots.** The drain-coalescing added 2026-07-29 (`cc10d93`) sums the whole burst and applies it as one net move; its own comment states the intent — *"a held key then scrolls FASTER (more rows per redraw) and stops dead on release."* That fixed an unbounded redraw backlog but traded it for this: intermediate positions are never drawn, and release lands on the accumulated total rather than the last row the user saw. The requested behaviour is neither the old queue-everything nor today's collapse-the-burst.

## The design

### 1. Frame

The popup stays `-w 52 -h 26` and the draw must emit **exactly 26 rows in every state**. Static rows go 16 → **15**, so the scheme window goes `WIN` 10 → **11**.

| # | row |
|---|---|
| 1 | `╭─ theme ─ preview ────╮` |
| 2 | tab chip |
| 3 | preview bar |
| 4 | `├─ configuration ────┤` |
| 5 | `SEED   #4f8728` |
| 6 | `├─ schemes ─────────┤` |
| 7–17 | 11 scheme rows |
| 18 | `├────────────────────┤` |
| 19 | current row |
| 20 | off row |
| 21 | `├────────────────────┤` |
| 22–24 | legend × 3 |
| 25 | note |
| 26 | `╰────────────────────╯` |

The row freed by the horizontal seed goes to the window, not to shrinking the frame.

### 2. The configuration zone

`adjustments` is renamed **`configuration`**, and its one field goes horizontal: the label `SEED` and the value share row 5 rather than stacking. `SEED` keeps its uppercase styling and `muted` colour; the value keeps its seed-coloured chip.

`__tcz_thp_kv` returns two lines (a labels row and a values row) laid out by `__tcz_thp_spread`. With a single field the two-row form is pure overhead. **`__tcz_thp_kv` and `__tcz_thp_spread` lose their only caller and are deleted** — the same disposal `__tcz_thp_litkv` got when the phase arms went.

### 3. Section titles

All zone-separator labels render in a new **`title`** role: `#d2782a`, bold — the brand orange pulled down about 18%, distinct from both the frame rule and the undimmed brand used for the picker's own `theme` title. Added to `__tcz_theme` alongside the existing roles.

Applies to `configuration` and `schemes`. The second list's rule is **untitled** — there is no word that covers "your current theme, and off" and the user would rather have none than a bad one.

### 4. The schemes rule loses its subtitle and counts

`├─ schemes · near-seed → bold ── ▲2 ▼4 ─┤` becomes `├─ schemes ─┤`. The user does not find either half useful and wants the clutter gone.

**Known cost, accepted:** the counts were the only cue that the list scrolls at all. The window still scrolls; you simply cannot see how much is hidden.

### 5. The second list

Rows 19–20 are a **second selectable list** holding the current theme and `off`. Shape, in the 50-column content area:

```
▐ ▇▇▇▇▇▇▇▇▇▇▇▇▇▇  mono soft                  current
  ▇▇▇▇▇▇▇▇▇▇▇▇▇▇  legacy look                    off
└1┘└─── 14 ───┘└1┘└──── name, left ────┘└─ label, right ─┘
```

Selector `▐` (1 col, `brand` when selected) · band (14 cols) · space (1) · the scheme name left-aligned · the role label **right-aligned**, its last character one column short of the border. The current row names the persisted theme's catalog entry (`mono soft`); the off row reads `legacy look`. The role labels are `current` and `off`.

This replaces `__tcz_thp_off_row` with a single builder serving both rows — **`__tcz_thp_staterow <bandhex> <name> <label> <selected> <live>`** — and `__tcz_thp_off_row` is deleted rather than kept alongside.

### 6. `current` as a live-state readout

The right-hand **`current` label renders bold in `brand` when the persisted theme is what is actually applied to the bar**, and in `muted` otherwise. Apply-preview any listed scheme with `a` and it drops to muted.

**Precisely:** live is true when no preview is in effect, *or* when the preview in effect is the current row's own recipe. Today's `previewed` is a bare 0/1 flag set at two different apply sites — the current row (`functions/tmux-categorize.fish:2185`) and a listed scheme (`:2197`) — so it cannot distinguish those cases. It becomes three-valued: `0` none, `1` a listed scheme, `2` the current row; live is `previewed != 1`. It is never reset, which is correct — `cancel` needs it to know a revert is owed — so within a picker session, previewing a listed scheme leaves `current` muted until you preview the current row again or close.

That is a genuine state readout rather than a static label, and it is what makes removing the chevron safe — it says something the chevron never did.

The `off` row's label is always `muted`; it is a destination, not a state. (An install actually running `off` shows the current row's own band in the legacy colour, which already reads as such.)

### 7. Both chevrons go

- The `❯` prefixing the current row is removed. It sat on a permanently-non-cursor row wearing a glyph that means "cursor" — misleading, as reported, and now redundant against the `current` label.
- The `❯` marking the matching entry **inside the scheme list** is also removed. That row is instead marked by rendering **its name in `brand`, bold** — the same visual language as the `current` label, and no glyph pretending to be a cursor.

`__tcz_thp_row`'s `current` parameter changes meaning from "prefix a chevron" to "render the name as the current entry", and its hard-coded `\e[38;5;179m` switcher-yellow goes with the glyph.

### 8. Swatch separation

Each swatch cell stops being a background-filled space and becomes **`▇` (U+2587, lower seven-eighths block) drawn in the role colour**, leaving one eighth of the cell clear at the top. Vertically adjacent swatches no longer merge into a single block.

Applies to the scheme rows and the second list's bands. **Not** the preview bar — that is a facsimile of the real status bar and must stay solid.

The selection mechanism needs no change: the draw loop already re-asserts `sel-bg` after every reset inside a selected row, so the gap picks up the selection band on the cursor row and the popup background elsewhere.

**New dependency, accepted:** Block Elements are a font requirement where the swatch previously needed none. The picker already requires a Nerd Font for its powerline separators, so this adds no new class of risk.

### 9. Tab moves between the lists

**`⇥` (Tab, byte `0x09`)** moves the cursor between the scheme list and the second list. `↑↓`/`jk` clamp **within** whichever list has focus and never cross.

`c` is retired. Its objection was semantic: a key meaning "current" that lands you on current, from which you arrow to off, promises one thing and does another. Tab carries no such claim, is the conventional "other list" affordance, and toggles back the same way.

`0x09` is added to the **shared** `__tcz_popup_readkey`. That is a proven no-op for the session switcher, which has no `case '*'` — the same argument that covered `p/P/m/M` and `c`. A regression assertion covers it.

Selection state becomes a focused-list model — the scheme list keeps `sel` over `0..n-1`, the second list gets its own `0..1` — replacing today's linear `0..n-1` schemes, `n` off, `n+1` current with its `c`-only unreachable tail.

Legend becomes:

```
↑↓ move    ⇞⇟ page     b  seed
m  more    z  shake    ⇥  current/off
a  apply   ⏎  save     esc close
```

### 10. Esc restores the seed

The seed screens (RGB sliders and typed hex) become **preview-only**: they apply live without persisting, exactly as `a` does for schemes. **`⏎` is what commits**, through the same CLI path as today.

The picker's anchor snapshot gains the seed, captured at open, so `cancel` restores it alongside the theme. Both must be restored — restoring the theme alone is what makes the current behaviour look broken, since every role derives from the seed.

Rejected alternative: capture the original and re-issue `setup color` on cancel. It leaves a window where the universal and fragment have been written and rewritten, and each fragment write re-sources `status-right` — which evicts tmux-continuum's autosave hook (see `docs/2026-07-30-handoff-status-right-and-update-environment.md`). Preview-only avoids the write entirely.

### 11. Held ↑↓ rate-limits with discard

Replace accumulate-and-jump with **move at most one row per render cycle and discard the surplus**. The drain loop stays — it is what prevents the redraw backlog — but it swallows the queued repeats rather than counting them.

Consequences, which are the requested behaviour: the selection is always drawn at the position it currently occupies, a held key scrolls at whatever rate the terminal can actually paint, and release stops on the last row that was visibly rendered.

`PgUp`/`PgDn` keep moving by `WIN` per press — they are discrete and not autorepeated in practice — and they still coalesce.

**Do not lose the drain-hang guard.** `stty min 0 time $gap` must be re-asserted *inside* the loop: `__tcz_popup_readkey`'s CSI branch leaves the tty blocking on return, and a drain read after it hangs. That hazard has been hit for real once.

## What does not change

The theme engine, catalog, `setup theme` CLI, the fragment renderer, the seven role `@options`, the tab chip and preview builders, `__tcz_thp_window`, `__tcz_thp_leg`, `__tcz_thp_zsep`, the `b`/`m`/`z`/`a`/`⏎` bindings, and the session switcher (`__tcz_popup`) beyond the shared readkey gaining one token.

## Testing

`tests/test-tmux-categorize.fish`. Pure builders are directly testable; the interactive loop is asserted by grepping its body, as the existing picker tests do.

**Builders:**
- `__tcz_thp_staterow` — visible width is exactly 50 for both rows, in every selected/live combination; the label's last column is one short of the border; the name is left-aligned; `live` toggles the label between `brand`-bold and `muted`.
- `__tcz_thp_row` — visible width exactly 50; `current` renders the name in `brand` bold and emits **no** `❯`; swatch cells use `▇` and not a background fill.
- `__tcz_theme title` returns the `#d2782a` SGR.
- `__tcz_thp_zsep` with a title renders it in the `title` role.

**Frame:**
- The draw emits **exactly 26 rows in every state** — cursor in the scheme list, cursor in the second list, previewing, not previewing, catalog collapsed and expanded. Assert by counting, not by eye.
- `WIN` is 11 and appears exactly once (a second literal would drift from the dispatch that pages by it).
- Popup geometry stays `-w 52 -h 26` at all three open sites, with the stale-size bans the existing suite already carries.

**Guards:**
- No `❯` anywhere in the picker body.
- No `\e[38;5;179m` (the retired switcher-yellow chevron colour).
- `__tcz_thp_off_row`, `__tcz_thp_kv`, `__tcz_thp_spread` are gone from the file.
- No `near-seed` or `▲`/`▼` scroll-count construction in the picker body.
- The scheme list's own rows never render the off state (`off` appears only via `__tcz_thp_staterow`).

**Input:**
- `__tcz_popup_readkey` maps `0x09` to `tab`, and the session switcher is unaffected — assert `__tcz_popup`'s dispatch has no `tab` arm and no `case '*'`.
- The ↑↓ arm applies at most one step per iteration and discards the remainder — assert structurally, since rate over time is not unit-testable.
- The drain loop re-asserts non-blocking mode inside itself.

**Seed:**
- The seed screens contain no `setup color` invocation (preview-only).
- The anchor snapshot captures the seed at open.
- `cancel` restores both the theme and the seed.

## Non-goals

- The theme engine and catalog — untouched. The big-area derivation is a separate, already-planned cycle.
- The session switcher's own layout.
- The tab chip and preview builders.
- Reinstating a scroll-position cue in some other form. If losing the counts turns out to hurt, that is a follow-up.

## Open, for live judgment

- Whether one eighth is the right swatch gap. Chosen from a rendered four-way comparison, but a mockup is not a terminal.
- Whether the retired scroll counts are missed.
- The exact right-margin on the role labels — specified as one column short of the border, trivially adjustable.
