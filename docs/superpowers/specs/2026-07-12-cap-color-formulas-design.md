# Cap-color formulas (color-theory secondary color) — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm), pending plan
**Branch:** `feat/cap-color-formulas` (base `f0bda95`)

## Motivation

The powerline end-caps derive their color from the bar via one fixed rule: a luminance-adaptive brightness *shade* (`__tmux_lives_derive_cap_bg`). This adds a **choice of color-theory relationships** for generating the cap ("secondary") from the bar ("primary") — monochromatic, analogous, complementary, split-complementary, triadic — picked from an interactive swatch popup or a CLI command. The stored choice re-derives automatically when the bar color changes.

## Formulas

Five families. The stored token lives in the universal **`tmux_lives_cap`** (front-facing name is "cap"), default **`mono`**. Directional families carry a `+`/`-`; `mono` and `complementary` are single.

| Token | Family | Hue rotation | Notes |
|---|---|---|---|
| `mono` | Monochromatic | 0° (same hue) | **The current brightness shade, kept bit-for-bit** (`__tmux_lives_derive_cap_bg`). Adaptive: lighter on a dark bar / darker on a light bar. No direction (auto). Default. |
| `analogous+` / `analogous-` | Analogous | +30° / −30° | Neighboring hues; subtle. |
| `complementary` | Complementary | 180° | Opposite hue; max pop. Single. |
| `split+` / `split-` | Split-complementary | +150° / +210° | Either side of the complement. |
| `triadic+` / `triadic-` | Triadic | +120° / −120° | Evenly spaced. |

`tmux_lives_cap` also accepts a **literal `#hex`** as an escape hatch: if the value matches `#rrggbb`, use it verbatim as the cap (formula bypassed). Unknown/empty token → fall back to `mono`.

## Derivation

- **`mono`** → `__tmux_lives_derive_cap_bg <bar_hex>` (existing, unchanged).
- **Hue families** → new pure `__tmux_lives_cap_hue <bar_hex> <degrees>`: RGB→HSL, `H' = (H + deg) mod 360`, `S' = max(S, 0.22)` (floor so a near-grey bar still shows the rotated hue), `L'` = the same adaptive shift as `mono` (`L<0.5` → `L + (1-L)*0.28` lighten; else `L*0.72` darken), HSL→RGB→`#rrggbb`. Verified against a reference implementation (values in the plan).
- **Dispatcher** `__tmux_lives_cap_from_formula <bar_hex> <token>` → routes to the literal-hex / `mono` / `__tmux_lives_cap_hue <deg>` path per the table. Empty/unparseable bar → empty (caller keeps its fallback).
- **Cap foreground** — the fixed `@tmux_lives_cap_fg colour231` (white) is replaced by an **auto-derived contrast fg**: new `__tmux_lives_contrast_fg <hex>` → near-white on a dark cap, near-black on a light cap (luminance threshold, reusing `derive_status`'s coefficients). This keeps the host glyph + hostname readable on any hue. The slant→bar transition (`@tmux_lives_bar_bg`) is unchanged.

## Storage & integration

- Universal **`tmux_lives_cap`** (default `mono`), read at fragment-render time like the other keys (`__tmux_lives_key tmux_lives_cap mono`) and passed as a new positional arg (argv[12]) to `__tmux_lives_render_fragment`.
- The fragment computes `@tmux_lives_cap_bg = __tmux_lives_cap_from_formula $barbg $cap` (replacing the fixed `__tmux_lives_derive_cap_bg`) and `@tmux_lives_cap_fg = __tmux_lives_contrast_fg $capbg`. Both quoted (the `#hex` comment gotcha).

## Two selection surfaces (same stored token)

**CLI (the backup):** `tmux-lives setup cap <token>|list` (`__tmux_lives_cap_cmd`).
- `setup cap <token>` → validate, `set -U tmux_lives_cap <token>`, and **apply live** without a re-render: set `@tmux_lives_cap_bg`/`@tmux_lives_cap_fg` directly on the live server (via the `tmux_lives_tmux_socket` seam, like `setup color --apply`).
- `setup cap list` → print every token with a truecolor ANSI swatch + label (uses the current bar color).
- `setup cap` (no arg) → open the picker.
- Directions are separate tokens here (`analogous+` / `analogous-`), per the brainstorm.

**Picker (the star):** categorizer verb `cap-picker` → `__tcz_cap_picker`, a `display-popup -E` reusing the switcher's raw-key loop (`__tcz_popup_readkey`/draw pattern).
- Rows = the 5 families; each renders a **live truecolor swatch** (a `#[bg=<cap>]` block, computed from the current bar) + the family name + the resulting hex.
- Keys: `↑↓`/`j`/`k` move; `←`/`→` (or `h`/`l`) **flip direction** on directional families (swatch redraws instantly); `Enter` apply (writes `tmux_lives_cap` + applies live, same path as the CLI); `Esc`/`q` cancel. `display-menu` fallback where `display-popup` is unavailable.
- Pure core is testable: `__tcz_cap_families` (ordered token list), `__tcz_cap_flip <token>` (toggle +/-), `__tcz_cap_swatch_line <bar> <token>` (the styled row string).

## Testing

- Pure `__tmux_lives_cap_hue` — known `(bar, deg)` → exact hex, both directions (reference values baked in the plan). `__tmux_lives_cap_from_formula` token dispatch incl. literal `#hex` passthrough and `mono`→`derive_cap_bg` equivalence. `__tmux_lives_contrast_fg` (dark cap→light fg, light cap→dark fg).
- Picker pure helpers (`__tcz_cap_families`/`_flip`/`_swatch_line`).
- CLI: `setup cap <token>` sets the universal + the live `@options` (pinned to a `-L` socket via the seam); `list` output contains a swatch for each token.
- Fragment-render seeds `@tmux_lives_cap_bg` from the formula + `@tmux_lives_cap_fg` derived; rendered fragment parses on a private `-L` socket.
- All isolated: `-L` sockets / stubs, never the default socket.

## Non-goals

- Not touching the prefix / resize / claude accent colors (`@tmux_lives_prefix_color` etc.) — cap only.
- Not a full theme system, not per-client.
- The `mono` shade factor (currently `0.25`; a "subtler" `0.12` was floated separately) is out of scope here — `mono` keeps its current derivation.
