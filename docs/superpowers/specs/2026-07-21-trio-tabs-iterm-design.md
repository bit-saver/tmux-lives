# Theme v3.3: harmonious trio (tabs · bar · caps) + iTerm2 tab mirroring

**Date:** 2026-07-21 (from the user's trio directive + a visual-companion
choice: kin-ramp selected over tabs=cap and tabs=seed)
**Status:** approved in-session
**Extends:** `2026-07-20-scheme-bar-variation-design.md`

## Problems

1. v3.2 pinned the ShellFish tabs to the seed verbatim. The tab bar sits
   DIRECTLY on the status bar (one stacked visual unit), so far-hue schemes
   (`full`, `aurora`, …) put a 100°+ hue clash right where the calibrated
   kin rule demands ≤25–50°. User: the tabs are part of a TRIO that must be
   harmonious together.
2. `fire`'s shipped bar recipe (t_bar = 0.05) lands at the arc's +130° END —
   a BLUE bar. The spec's own example value pointed at the wrong arc end;
   the warm end of fire's 130→−44 arc is t ≈ 1.0.
3. The user wants iTerm2 tabs to mirror the ShellFish look (per-theme tab
   color + title).

## 1. Trio rule — tabs = kin ramp (user-selected from live-computed mock)

In `__tmux_lives_theme_palette`, the tabs role becomes a derived kin of the
bar+cap pair (replacing seed-verbatim):

- hue: bar hue + (circular ΔH(bar→cap)) / 2 — halfway to the cap.
- L: bar L + dir·0.16, dir = the kincap direction (lighter for bar L < 0.55,
  else darker), clamped [0.05, 0.95].
- C: the CAP's chroma (so muted-cap schemes get muted tabs).
- Applies to ALL schemes including `mono` (bar=seed → kin cap → ramp tabs;
  v3.2's mono-tabs-take-ring-1 special case is DELETED).
- Implemented as a pure `__tmux_lives_theme_kintabs <barhex> <caphex>` →
  tabs hex, called by the palette; the ring/accents/text/cap derivations are
  untouched. Rotation still never moves tabs.
- Acceptance predicate extension (tested): ΔH(bar,tabs) ≤ 30° (it is half
  the family offset by construction, max 20–25), ΔL(bar,tabs) ∈
  [0.10, 0.22], tabs C within 0.02 of cap C — across the scheme × seed
  panel.

## 2. Seed home base → the ✦ mark

The tabs give up home-base duty, so the seed verbatim moves to the smallest
always-visible accent: `@tmux_lives_mark_fg` (the ✦ identity mark) is set to
the SEED hex instead of the cap sample — in BOTH emit sites (fragment render
and `__tmux_lives_theme_apply_live`). The palette's 7-role output contract
is unchanged (mark is not a palette role). Legacy/off branch keeps its
current mark behavior. Seed visibility after this wave: the ✦ mark (every
scheme), `mono`'s bar, and the picker's anchor row + seed swatches.

## 3. fire bar recipe fix

`__tmux_lives_theme_barpos` fire: t_bar 0.05 → **0.95** (ΔL −0.03 and empty
capC unchanged) — the bar lands ≈ +87° warm gold (distinct from `warm`'s
≈70° umber). Test: fire's bar hue in [60°, 110°] of absolute OKLCH hue for
the reference seed (verbatim-value test on the existing seed panel replaces
any pin that captured the blue value).

## 4. iTerm2 tab mirroring

- **Detection generalization:** `__tcz_client_terminal <pid>` → `shellfish`
  | `iterm2` | `other`, from the client environ's `LC_TERMINAL` (values
  `ShellFish` / `iTerm2`; same `__tcz_pid_environ` machinery + fake-environ
  seam). `__tcz_client_is_shellfish` becomes a thin wrapper (kept — many
  call sites + tests).
- **Emission:** `__tcz_emit_itermtab <tty> <hex>` writes iTerm2's tab-color
  OSC triplet to the tty:
  `\e]6;1;bg;red;brightness;R\a` + `;green;…G` + `;blue;…B` (decimal 0-255
  from the hex). Non-hex input → emit the reset `\e]6;1;bg;*;default\a`.
- **Wiring (mirror the ShellFish paths):** everywhere the categorizer emits
  the ShellFish bar color / title per client (`__tcz_recolor`,
  `__tcz_on_attach`, `__tcz_retitle`, the tick's dedup path, the heal
  backstop), an `iterm2` branch emits the TAB color (the tabs-role color via
  `__tcz_tab_color`, same resolved value ShellFish tabs get) and the same
  OSC 2 title. Dedup caches: reuse the existing per-tty
  `@tmux_lives_emit_<tty>_{title,color}` keys — the cached value is the
  resolved color, terminal-agnostic; only the emitted ESCAPE differs by
  terminal type at write time.
- The baseline re-apply path for non-ShellFish clients: iTerm2 clients are
  now "colored" clients — they must NOT trigger the non-ShellFish baseline
  re-source (which exists to undo ShellFish's forced options; iTerm over
  plain SSH never had them forced). Decision: `__tcz_on_attach` treats
  iterm2 like `other` for the baseline step (unchanged behavior) but ALSO
  emits tab color + title. Only the emission is new.

## 5. Remove the claude window coloring (user addition, same session)

The coral `claude` window-name tint "mostly detracts from the theme":

- Fragment render: the `window-status-format` / `window-status-current-format`
  conditionals lose the `@tmux_lives_claude_color` branch — `claude` windows
  render like any other window (windows role; current bold + text role). The
  `@tmux_lives_claude_color` seed line is removed from the fragment.
- The picker's fake-bar preview (`__tcz_thp_preview`) and tab-strip mock
  drop their hardcoded `#D97757` coral accordingly.
- NOT touched: the ✦ claude-presence indicator (`@tmux_lives_claude`, the
  `(C)` title suffix, categorize detection) — presence stays, color goes.

## Testing

Pure: kintabs (hue-halfway circular incl. wraparound, L step + dir + clamp,
C from cap); predicate extension on the panel; fire hue band; barpos pin
update; mono-tabs special case gone (grep + behavior); mark_fg = seed in
both emit sites (fragment string + apply-live push args); emit_itermtab
escape bytes (exact triplet for a known hex; reset for non-hex);
client_terminal via the fake-environ seam (ShellFish/iTerm2/other);
is_shellfish wrapper still true only for shellfish. Suites both configs.
Runtime-only (live smoke): actual iTerm tab color/title over SSH+tmux,
ShellFish stack look, the trio on the real bar.

## Out of scope

- Per-scheme seed-static bars beyond mono (await the user's post-deploy
  verdict on v3.2's 1-static/9-shifted mix).
- Other terminals' tab/titlebar protocols (kitty, WezTerm — future).
- Picker changes (the strips/tab-strip preview render whatever the palette
  returns; the preview chip detection stays ShellFish-only until live
  feedback says otherwise).
