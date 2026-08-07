# Theme picker — integrated seed section, height-adaptive frame, live seed regeneration — design

Status: approved in brainstorm 2026-08-07. Folds the seed editor into the theme picker as a permanent section, makes the popup's height adapt to the client, and regenerates schemes as the seed moves. Also fixes a real defect found while investigating: the picker never restores the ShellFish/iTerm2 tab colour.

## Why

Four complaints from live use, all about the same screen.

**The seed editor is unframed content floating on your scrollback.** The theme picker opens with `display-popup -B`, which disables tmux's own border, and draws its own `╭─╯` frame. The seed screens then run `\e[2J` — wiping that frame — and print bare rows with no border glyphs at all. The user's rule is general and correct: anything overlaid on terminal history needs a border separating it from what's behind. The switcher and the modal launcher already comply; only the seed screens do not.

**The seed editor is a separate screen, so you cannot see a seed and its consequences at once.** You leave the scheme list to change the seed, come back, and only then discover what it did. Since every role derives from the seed, that is the single most consequential control in the picker and it is the one you cannot watch.

**"I'm not 100% sure ESC restores my existing scheme."** Investigated rather than reassured — see the finding below. The tmux side is correct; the tab colour is not restored at all.

**The picker shows 11 schemes on a 62-row client.** The frame is pinned at exactly 26 rows regardless of how much screen exists.

## Measured facts this design rests on

All measured on tmux 3.3a (rocket, the constraining version — macwork runs 3.7b).

| Fact | Result |
|---|---|
| Resize a popup while open | **Impossible.** `display-popup` is the only popup command and takes its size at creation. |
| A command reading its own popup size | **Works.** `stty size` returns `12 40` inside a `-w 40 -h 12` popup. `$LINES`/`$COLUMNS` are not exported. |
| `-w`/`-h` percentages | **Work, and are exact.** 70% of 24 rows → 16, 85% → 20, 90% → 21 (floor). |
| `-w '#{client_width}'` | **Rejected** — "width invalid". Formats do not expand in size arguments. |
| Popup taller than the client | **Hard failure.** "height too large"; the popup does not open at all. tmux does not clamp. |
| Real client sizes | 193×62, 206×62, one 201×46. The ShellFish/iPad tab is **206×62**. |
| One palette | **~40 ms** (12-iteration gamut clamp dominates) |
| 14 curated rows | **~310–400 ms** |
| All 35 rows | **~700–800 ms** |

Two of these are load-bearing. Because a too-tall popup **fails to open rather than clamping**, a hardcoded taller height is not safe — hence the percentage. And because a full palette batch costs 310–800 ms, live regeneration cannot be per-keystroke — hence the split between what updates live and what waits for a pause.

## The finding: ESC does not restore the tab colour

Reproduced end to end on a private socket, with the persisted state shadowed as globals:

```
A persisted            bg=#44502f,fg=#a5b094  cap=#536f53  tabs=#32795d
B previewing coral     bg=#653f3c,fg=#c3a29e  cap=#796243  tabs=#5f772b
C after ESC            bg=#44502f,fg=#a5b094  cap=#536f53  tabs=#32795d   ← identical to A
D previewed, new seed  bg=#32496a,fg=#9bacc4
E after ESC (seed too) bg=#44502f,fg=#a5b094  cap=#536f53  tabs=#32795d   ← identical to A
```

Both branches of the cancel guard restore byte-identically. **The tmux side is correct.**

The tab colour is a different surface. `__tcz_theme_picker` contains **zero** calls to `__tcz_recolor`: previewing sets the `@tmux_lives_tabs_color` option, but nothing emits the OSC to the terminal. The only thing that does is the status tick, every **15 seconds**, reading that option through `__tcz_tab_color`. So:

```
T+0s   press `a`   → status bar changes instantly; tab unchanged
T+3s   tick fires  → tab turns the previewed colour
T+5s   press ESC   → status bar restores instantly; tab still previewed
T+18s  tick fires  → tab finally restores
```

For thirteen seconds the bar shows the real scheme and the tab shows the abandoned one — on the surface the user describes as ten times the size of the status bar. It self-heals, which is why it has been hard to pin down. Live seed regeneration would make this far more visible, so it is fixed here rather than deferred.

## Design

### 1. Height adapts; width does not

The bind opens the picker at **`-w 52 -h 85%`** and the picker reads `stty size` at startup, deriving exactly one quantity:

```
WIN = rows - STATIC        where STATIC = 22
```

`STATIC` is today's 15 fixed rows, minus the single seed row the new section replaces, plus the 8-row seed section: `15 - 1 + 8 = 22`. On the real clients that gives **WIN 30** at 62 rows (85% → 52) and **WIN 17** at 46 rows (85% → 39), against 11 today.

85% is chosen over 90% to leave the popup visibly inset rather than nearly edge-to-edge, and over 70% because that would give only 10 scheme rows on the 46-row client — fewer than today, which is the outcome this change exists to avoid.

Everything else — every row builder, every width — is unchanged. This is deliberately the smallest possible slice of "make the picker responsive": one variable, not a layout engine. Full width-responsiveness remains deferred as its own project.

**Why a percentage rather than a taller fixed height:** a fixed height that exceeds the client does not degrade, it refuses to open. A percentage always fits.

**Degradation floor.** If `rows < STATIC + 3` the picker cannot draw a usable list. It prints a single framed line saying the terminal is too short and exits, rather than rendering a broken frame. This is unreachable on the user's real clients (46–62 rows) but must not corrupt the display on a small one.

### 2. The seed section

A permanent zone above the scheme list, at a **fixed height whether or not you are editing**, so toggling never makes the list jump:

- a zone separator (1 row)
- the large colour square from the current seed screen (4 rows)
- three rows that are **readouts when idle** (hex, hue, lightness, chroma) and become the **three stacked R/G/B bars when editing**

Total 8 rows. The bars stay stacked and horizontal — one per channel, as today. They are not collapsed onto a single line: their relative lengths are how you compare channels, and that read is the reason to have bars rather than numbers.

`b` toggles edit mode. It is already bound to the seed screen and already in the legend, so muscle memory carries over.

**In edit mode:** `←→` moves the selected channel, `↑↓` selects the channel, `⏎` keeps the change, `esc` reverts to the seed the picker opened with and leaves edit mode **without closing the picker**. **Outside edit mode** `↑↓` still moves the scheme cursor. The two modes never contend for the arrows, which is why edit mode is explicit rather than implicit.

`b` is ignored while the cursor is in the second list (the `⇥` current/off list) — that list has no seed of its own, and silently entering edit mode from it would leave the arrows doing something the cursor position does not explain.

**Typed hex survives.** The existing `t`-to-type-a-hex path (`__tcz_thp_hexentry`) is reachable with `t` while in edit mode, for when you already know the value you want. It keeps its current behaviour — preview-only, `⏎` commits, `esc` reverts — and on exit returns to edit mode rather than to a separate screen. It is the one part of the old seed screen that still needs its own full-frame drawing, so it must gain the border the rest of this change removes the need for.

### 3. Live regeneration

Per-keystroke regeneration of the whole list is not affordable. Split by what the eye is actually on:

- **Live, on every channel change (~40 ms):** the colour square, the preview bar, and the **cursor's own scheme row**.
- **On settle:** the remaining visible strips re-render once input goes idle.

So you see your seed's effect immediately on the row you are looking at, and the rest catches up a beat later. The idle detection needed here is the same primitive the deferred auto-apply feature will need.

### 4. Tab colour emitted directly

Preview and cancel call `__tcz_recolor` in **force** mode (not dedup — the dedup cache would suppress a restore that returns to a previously-emitted value). The 15-second lag disappears in both directions.

## Testing

The frame proof is the strongest guard in this file: it extracts the real draw block and `eval`s it against real state, and it currently asserts a constant 26. It becomes **parametric in one variable** — for a popup of `R` rows, the draw emits exactly `R` rows — asserted across several sizes and across both seed-section states (idle and editing). Its sensitivity must be re-proven by injecting an extra row and observing the count go wrong at each size, exactly as the constant version was.

Beyond that: `WIN` derivation from `stty size` including the degradation floor; that the seed section is the same height idle and editing (the anti-jump property); that edit mode captures the arrows and idle mode does not; that `esc` in edit mode restores the seed and does **not** close the picker; and that preview and cancel each emit the tab OSC in force mode.

## Out of scope

Swatch weighting and ordering by placement size; auto-apply on dwell; full width-responsiveness; and the accents derivation redesign. Each is its own piece.
