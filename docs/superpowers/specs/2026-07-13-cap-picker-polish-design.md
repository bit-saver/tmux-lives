# Cap-picker polish + scratch width — Design (Phase A)

**Status:** approved 2026-07-13. Phase A of the cap-color enhancements; **Phase B (whole-bar theming — wire dim/muted/text + bar color across the bar, meaningful column labels) is a separate later spec.** Deploy is user-only via `fisher update`.

## Goal
Small, self-contained refinements to the cap-color picker + one unrelated scratchpad tweak the user asked to fold in:

1. **Full border + separator** on the picker so the key-reference stops blending into the background.
2. **Restore the last-applied selection on open** so exploring formulas doesn't re-pick the last one by accident.
3. **A dedicated `M-k` keybind** that opens the cap picker directly.
4. **Widen the default scratchpad** from 33% → 45%.

(Column labels — the user's other request — are **deferred to Phase B**, because meaningful "which element does this color drive" labels require the roles to actually drive elements, which is Phase B.)

## Constraints
- fish 4.7.1, tmux 3.3a+/3.6b, no new deps. Touch only `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, and the two test files.
- The categorizer runs as `fish --no-config`; it CANNOT read fish universals directly (verified empirically) — it reads config via a config-loaded `fish -c` subprocess or via tmux `@options`. The picker already uses this pattern.
- Test isolation: `-L` socket via `tmux_lives_tmux_socket`; `set -U` tests save/clear/restore the universal (no leak). All 8 suites `ALL PASS`.
- The interactive raw-tty picker loop + live keybinds + the live `split-window` are runtime/manual-smoke by design; unit tests cover the pure helpers, fragment render, and CLI.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Item 1 — Full border + separator (`__tcz_cap_picker`)
Today the picker draws `╭─ cap color ─╮` / swatch rows (each wrapped by `__tcz_cap_ln` in `│…│`) / `╰─╯`, then `printf`s the key-reference footer **below the closed box, unbordered** (picker ~line 1183).

**Change:** move the footer *inside* the frame. New draw order:
```
╭─ cap color ─────────╮   top border (unchanged)
│ ▐ ▪▪▪ mono          │   swatch rows (unchanged, via __tcz_cap_ln)
│   ▪▪▪ complementary │
│   … (6 families) …  │
├─────────────────────┤   NEW separator: OD-colored ├ + ─×IW + ┤
│ ↑↓ move   ←→ flip   │   footer rows, each via __tcz_cap_ln (bordered)
│ v vivid   w wheel   │
│ ⏎ apply   esc cancel│
│ wheel ryb · vivid   │   current wheel/vividness status (bordered)
╰─────────────────────╯   bottom border (unchanged)
```
- Add a small pure helper `__tcz_cap_sep <IW> <OD> <T>` → the `├`+(`─`×IW)+`┤` line (mirrors the `╭`/`╰` construction; quoted-`string repeat` to avoid the zero-arg splice gotcha). Unit-testable.
- The footer lines are wrapped with the existing `__tcz_cap_ln` so borders align (padded by SGR-stripped visible width). Each footer line ≤ IW (30) — all current lines fit.
- **Row budget:** 1 top + 6 swatches + 1 sep + 4 footer + 1 bottom = 13 rows ≤ the popup's `-h 15`; inner width 30 + 2 borders = 32 ≤ `-w 34`. Fits the existing popup size — no caller change.

**Acceptance:** the whole picker reads as one bordered box with a visible divider between swatches and keys. (Visual = manual smoke; `__tcz_cap_sep` unit-tested.)

## Item 2 — Restore last-applied selection on open (`__tcz_cap_picker`)
On open the picker starts `sel = 0` (mono) and `families` at their `+` defaults; only `wheel`/`vividness` restore from universals. Add formula+direction restore.

- Extend the init `fish -c` (picker ~1107) to also echo `(__tmux_lives_key tmux_lives_cap mono)` — the last-applied formula token.
- New pure helper **`__tcz_cap_restore <formula> <families…>`** → prints ONE line: the 0-based index of the `families` entry whose base matches `formula`'s base, or `-1` when there's no match. Single responsibility — index lookup only; it does not mutate anything. Logic:
  - Strip a trailing `+`/`-` to get the base (`triadic-` → `triadic`), match it against each family's base (`triadic+` → `triadic`), return the first matching index.
  - `mono`/`complementary`/`tetradic` (no direction) match themselves.
  - A literal `#hex` cap (not a family) or an unknown token → `-1`.
- The picker calls it after building `families`. If the index ≥ 0: `set sel $index` and set that family entry to the stored token verbatim (`set families[(math $sel + 1)] $formula`) so the highlighted row shows the stored `+/−` direction. If `-1`: leave `sel = 0`, families unchanged (graceful — e.g. a `#hex` cap). `v`/`w` restore is already present.

**Acceptance:** apply `triadic-` at `vivid`/`ryb`, reopen → cursor is on the `triadic-` row with `[wheel ryb · vivid]` shown. Unit-test `__tcz_cap_restore` across mono/complementary/tetradic/analogous±/split±/triadic±/#hex/unknown.

## Item 3 — Dedicated `M-k` keybind (`conf.d/tmux-lives-install.fish`)
Add a configurable Option bind that opens the cap picker directly in its own `display-popup` (the cap-picker verb runs *inside* a popup — same wrapper the modal's `k` fix uses).

- New universal `tmux_lives_cap_key` (default `M-k`, `''` disables), consistent with `tmux_lives_modal_key`/`_scratch_key`/`_resize_key`.
- `__tmux_lives_render_fragment` gains **argv[15] = cap_key**; when non-empty it bakes:
  `bind-key -n <cap_key> display-popup -B -E -w 34 -h 15 -- fish --no-config $cat cap-picker '#{client_name}'`
  (mirrors `__tmux_lives_cap_picker`'s popup dims and the modal `k` deferred-open shape).
- The `__tmux_lives_write_fragment` call site appends `(__tmux_lives_key tmux_lives_cap_key M-k)` as argv[15].
- `setup keys` gains `--cap-key <k>` (stores `tmux_lives_cap_key`), and the setup-help line documents it — mirroring the existing `--modal-key`/`--scratch-key`/`--resize-key` flags.
- No tmux default collision (`bind -n M-<letter>` is unused by tmux defaults; verified).

**Acceptance:** `render_fragment … M-k` (argv[15]) contains the `bind-key -n M-k … cap-picker` line; `''` omits it; `setup keys --cap-key M-c` sets the universal. Unit-tested in `test-tmux-install.fish` (fragment render + `set -U` save/restore). Live `M-k` opens the picker = manual smoke.

## Item 4 — Scratchpad width (`__tcz_scratch`, `__tcz_scratch_orient`)
Both split the scratch pane with `tmux split-window … -p 33` (33%). Change the constant to **`-p 45`** at both sites (`__tcz_scratch` ~1363, `__tcz_scratch_orient` ~1391).

- Chosen as a plain constant (YAGNI): fish universals aren't visible to the `--no-config` categorizer, so live-tunability would require the heavier `@tmux_lives_scratch_width` `@option`-via-fragment machinery — disproportionate for a width. Trivial to expose later if wanted.

**Acceptance:** a fresh scratch (`M-t`) and an orient toggle both open at ~45% width. (Live `split-window` = manual smoke.)

## Testing summary
- **Unit (added):** `__tcz_cap_sep` (separator line), `__tcz_cap_restore` (formula→sel/direction across all families + #hex/unknown) in `test-tmux-categorize.fish`; fragment bakes the `M-k` bind + `setup keys --cap-key` sets the universal (with save/restore) in `test-tmux-install.fish`.
- **Manual smoke (runtime, after `tl update`):** the bordered box + divider render; reopen lands on the last formula/direction; `M-k` opens the picker; the scratch opens wider.
- Full suite: `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`, pristine.

## Out of scope (Phase B, separate spec)
Wiring `dim`/`muted`/`text` (and the bar bg) into actual bar elements (✦ mark, session/window text, mode accents), meaningful per-column element labels, and any `tmux_lives_theme_bar` opt-in.
