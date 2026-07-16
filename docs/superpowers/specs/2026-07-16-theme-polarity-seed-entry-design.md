# Theme v3 follow-up: explicit polarity + seed-entry UX

**Date:** 2026-07-16 (evening, from the user's first working picker smoke)
**Status:** approved in-session — decisions made by the user
**Extends:** `2026-07-16-theme-v3-phase2-3-design.md`

## Problems (observed live)

1. **Seed brightness silently decided bar polarity.** The engine's light-seed inversion (seed OKLCH L ≥ 0.60 → ramp flips light) made the user's bright seed `#87af00` render a near-white bar and put a white `bar` swatch first in every picker row. The seed's job is to donate HUE only; inferring theme polarity from its brightness conflates the two. User decision: **explicit polarity, like IDE light/dark themes.**
2. **Seed entry hides the hue-only contract.** Changing the seed between same-hue colors (`#87af00`→`#ccff44`) changes nothing visible — correct per the model (only hue is consumed), but the entry UI (a cooked `read` that leaks fish's default `read>` prompt, no preview, no feedback) makes it read as broken.

## Changes

### 1. Explicit polarity (auto-inversion removed)

- `__tmux_lives_theme_palette` gains a 9th arg `polarity` (`dark`|`light`, `''` = `dark`): `light` swaps the L endpoints; the seed-L ≥ 0.60 auto-inversion is DELETED.
- New universal `tmux_lives_theme_polarity` (default `dark`); CLI flag `setup theme --polarity dark|light` (validated, persisted, applied live); fragment argv 19 `themepolarity`; `theme_apply_live`/`theme_list`/no-arg state print carry it.
- Picker: init reads it (10th init line); new `d` key toggles dark↔light (full reload); the info line shows it; Enter passes `--polarity`.
- Info line reformatted to fit the new field at worst case exactly IW (50): `<seed> · <+N°> · <vividness> · <shape> · <ease> · <polarity>` — no `seed ` label, no leading space.

### 2. Seed entry: raw-mode hex line with live swatch + hue readout

- The picker's `b` sub-mode drops the cooked `read` (and its `read>` leak) for a raw-tty hex editor: type `0-9a-f` (`#` implied/ignored), backspace edits, Enter applies (3- or 6-digit only), Esc cancels.
- The entry line shows, live: the buffer, a truecolor swatch of the candidate once it parses, and the candidate's extracted **hue readout** (`hue N°`) — computed via one install-side `fish -c` per parse-complete (len 3 or 6), never per keystroke.
- The prompt copy states the contract: the seed's **hue** drives the theme.
- Apply path unchanged (`setup color` silenced → re-init → full reload → note line).

## Deferred (official agenda)

- **RGB slider seed picker** (user's preferred entry style): a slider sub-screen (↑↓ channel, ←→ adjust, live swatch + hex + hue) on the picker's existing raw-tty machinery. Next wave, on request.
- `setup color` without `-i` silently resets `tmux_lives_status_invert` (bit the user via `b`); invert is legacy-only under always-on — revisit with the slider wave.

## Testing

Engine: bright seed + default → ASCENDING (dark) ramp; `--polarity light` → descending; 9th-arg default. CLI: validation, persistence, state print. Fragment: argv 19, `show -gv` on a `-L` socket. Picker: structure greps (`d` key case, `--polarity` in the apply, no `read -l` in the b-case, `__tcz_thp_readchar` present, hue copy present); `__tcz_thp_info` width lock at the 50-col worst case.
