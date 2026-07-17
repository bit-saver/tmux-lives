# Theme v3 follow-up: RGB slider seed picker

**Date:** 2026-07-16 (late; the agenda item from the polarity/seed-entry wave)
**Status:** approved — the user chose slider-based seed selection as their preferred entry style; details below follow the endorsed proposal (↑↓ channel, ←→ adjust, live swatch + hex + hue)
**Extends:** `2026-07-16-theme-polarity-seed-entry-design.md`

## Summary

`b` in the theme picker now opens a **slider screen** (the user's preferred style) instead of the bare hex line: three R/G/B channel rows with truecolor bars, a live swatch + composed hex + extracted-hue readout, ↑↓ selects the channel, ←→ adjusts it (coalesced), Enter applies, Esc cancels — and `t` drops into the typed-hex line editor that shipped in the previous wave (kept intact for paste-in entry; applying or cancelling there returns to the picker as today).

## Design

- **State:** `r g b` ints 0-255, initialised from the current seed (fallback `#3a3a3a`). Composed hex = `printf '#%02x%02x%02x'`.
- **Screen** (replaces the popup content while active, like the hex entry does; DECSET-2026 atomic paint; returns to the picker frame on exit): a title/copy line restating the hue-only contract; a readout line `[swatch] #rrggbb · hue N°`; three slider rows; a keys line (`↑↓ channel · ←→ adjust · t type hex · ⏎ apply · esc cancel`).
- **Slider row** (pure builder `__tcz_thp_slider <label> <value> <selected>`): `▐?` selection marker + channel letter + a 32-cell bar (filled cells in the channel's pure color — `#RR0000`/`#00GG00`/`#0000BB` at the CURRENT channel value so intensity is visible in the bar itself — remainder in dim gap cells) + the right-aligned 0-255 value. Fixed visible width, test-locked.
- **Keys:** ↑↓ move the channel marker; `←`/`→` adjust ±8, clamped 0-255, with the established net-delta drain-coalescing (per-iteration `stty min 0 time 0` re-assert); Enter applies the composed hex via the existing apply path (`setup color` silenced → re-init → full reload → note); Esc cancels (no apply); `t` opens the existing hex line editor — on its apply/cancel, control returns to the PICKER (not back to the sliders), matching today's flow.
- **Hue readout:** recomputed via one install-side `fish -c` per adjust-settle (after the drain), not per press; the swatch/hex are pure-local (no subprocess).
- **Readkey:** `__tcz_thp_readchar` grows arrow tokens (`up|down|left|right`) — its ESC/CSI disambiguation already reads the b2/b3 bytes; classify `41-44` instead of discarding (the hex line editor keeps ignoring them; only the slider screen consumes them).
- **Zero new files; frame/geometry of the outer picker untouched** (the slider screen is a full-clear sub-mode like the hex entry).

## Testing

Pure: `__tcz_thp_slider` visible width fixed across values/selection; fill-count math at 0/128/255; readchar arrow classification (structure). Structure greps: `b`-case opens the slider loop; `t` routes to the hex editor; apply composes `#%02x%02x%02x`; per-iteration stty re-assert in the slider drain. Interactive loop = the user's live smoke.

## Out of scope

Other entry styles (palette grids, named colors); changing the hex editor's semantics; theming beyond the seed.
