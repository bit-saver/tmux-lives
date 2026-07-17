# Theme picker: in-process performance + change-flash + shift-reverse

**Date:** 2026-07-17 (from the user's first v3.1 live smoke: "several seconds for
every change" on the Mac, phase slow everywhere)
**Status:** approved in-session
**Extends:** `2026-07-17-theme-seed-anchored-design.md`

## Root cause (measured, not guessed)

Every knob press runs `__tcz_thp_reload` = ONE **config-loaded `fish -c`
subprocess** computing 10 palettes + 20 contrast fgs. Measured on rocket (idle):
subprocess batch ≈ 260 ms (startup ~60 ms + math ~180 ms) + draw ≈ 40-80 ms.
The same batch **in-process** (engine sourced once): ≈ 130-180 ms — the spawn
and config load are pure overhead. On macOS process spawn + config load are
several times slower → the Mac's "several seconds." Phase (`←→`) is the
scrubbing knob: every 5° step pays the full cost and held arrows queue
recomputes back-to-back, so it lags on every machine. `contrast_fg` is
negligible (0.65 ms/call). Host-load contention multiplies whatever the
constant is — so the fix is to shrink the constant.

## Fix 1: in-process engine (kills every per-press subprocess)

- At picker open, `__tcz_theme_picker` **sources the install engine once**:
  `source $__fish_config_dir/conf.d/tmux-lives-install.fish` (verified
  side-effect-free at source time: its only top-level statement is a guarded
  `__tmux_lives_pi` global; universals are readable under `--no-config`).
  No fallback path: if that file is missing, the current `fish -c` route has
  no engine either (config-loaded fish gets the functions from the same file).
- EVERY `fish -c` inside `__tcz_theme_picker` (and its nested seed screens)
  becomes a direct in-process call: `__tcz_thp_init`'s state read,
  `__tcz_thp_reload`'s batch, the slider/hexentry hue·L·chroma readouts
  (`__tmux_lives_hex_to_rgb01` + `__tmux_lives_rgb_to_oklch` directly),
  the `a`-preview (`__tmux_lives_theme_apply_live …` directly, both 7-arg and
  0-arg revert), Enter's save and the seed screens' apply
  (`tmux-lives setup theme …` / `tmux-lives setup color …` directly — the
  dispatcher is defined by the sourced file; output silenced as today).
- **Grep-guard test:** zero `fish -c` occurrences inside the
  `__tcz_theme_picker` function body (from its `function` line to its final
  `end`) — pins the fix against regression.

## Fix 2: batch cache (revisited knob states are instant)

- `__tcz_thp_reload` caches its parsed result keyed by
  `"$seed|$phase|$viv|$shape|$ease|$contrast"` — **rotate excluded** (see
  Fix 3). Storage: two picker-local parallel lists (`cachekeys`,
  `cacheblobs`; blob = the reload line format joined with a record
  separator). Hit → parse the blob (no math); miss → compute, append.
  Unbounded within a picker session (entries ~1 KB; bounded by distinct
  states actually visited). Cache dies with the picker process.
- Correctness test: a cache-hit reload yields byte-identical
  toks/pals/fgs/tabsfgs to a fresh compute of the same state.

## Fix 3: rotate is a display-side permutation (no recompute)

- The reload always computes/caches palettes at **rotate 0**. After fetch,
  the picker applies the rotation itself: for each palette, fields 2..6
  (the five supports) are cyclically permuted by the same
  `(($i - 1 - $rotate) % 5 + 5) % 5 + 1` index the engine uses; bar (1) and
  text (7) fixed. Pure helper `__tcz_thp_rotpal <rotate> <pal>` → rotated
  pal string, unit-tested for parity: for a sample seed/scheme,
  `rotpal r (palette … 0)` == `palette … r` for r = 0..4.
- Save/preview authority unchanged: Enter and `a` still pass the real
  `--rotate`/rotate arg to the engine.
- Effect: `o`/`O` presses cost one permutation + draw (~40 ms), never math.

## Feature: change-flash (timed ~0.5 s, user-chosen)

- New tl theme role: `flash` = truecolor `#5fa8e8` fg (in `__tcz_theme`;
  live-retunable by editing the role like the rest of the palette).
- Picker state `flashfield` (empty or one of
  `seed phase vividness shape ease contrast rotate`): set by the knob that
  changed — `←→`→phase, `v/V`→vividness, `s/S`→shape, `e/E`→ease,
  `d/D`→contrast, `o/O`→rotate, seed-apply (from either seed screen)→seed.
  `r` (reset) sets none (the note row already announces it).
- `__tcz_thp_kv` gains a flash arg: `__tcz_thp_kv <w> <flashfield> [<label>
  <value>]…` — the pair whose label matches `<flashfield>`
  (case-insensitive) renders BOTH label and value in the `flash` role
  (label loses muted, value keeps its own SGR replaced by flash fg);
  `''` = no flash. Widths/alignment unchanged (SGR-only difference).
- **Timing loop:** when `flashfield` is set, the draw is followed by a
  **timed read** instead of the blocking read: caller sets
  `stty min 0 time 5` (≈0.5 s), calls `__tcz_popup_readkey timeout`, then
  restores `stty min 1 time 0`. New readkey mode: with a first argument of
  `timeout`, an EMPTY read returns the token `timeout` (instead of
  `cancel`); all other behavior identical. On `timeout` → clear
  `flashfield`, redraw normal, resume the blocking read. On any real token →
  handle it exactly as if it had arrived at the blocking read (a new knob
  press re-flashes its own field). The phase drain loops are untouched —
  they keep their non-flag readkey calls and per-iteration
  `stty min 0 time 0` re-assertions.
- Readkey test: `printf '' | __tcz_popup_readkey timeout` → `timeout`;
  bare-EOF without the flag still → `cancel`.

## Feature: shift-reverse on the cycling knobs

- `__tcz_popup_readkey` gains uppercase single-byte cases:
  `56→V  53→S  45→E  44→D  4f→O`.
- Loop: `V` vividness backward (vivid→balanced→soft→vivid), `D` contrast
  backward (auto→darker→lighter→auto), `O` rotate −1 (`($rotate+4)%5`),
  `S`/`E` same as lowercase (two-state toggles; bound for muscle-memory
  symmetry). All five flash their field like their lowercase twins.
  Arrows already run both directions — phase needs nothing.
- Footer legend unchanged (the lowercase keys remain the documented surface;
  README gains one line noting shift reverses the cycle).

## Testing

- Grep-guard: no `fish -c` inside `__tcz_theme_picker` (Fix 1).
- Cache-hit parity; rotpal-vs-engine parity r=0..4 (Fixes 2-3).
- kv flash: blue SGR present exactly on the flagged pair, absent otherwise;
  visible widths unchanged with and without flash.
- Readkey: V/S/E/D/O tokens; `timeout` mode vs default EOF→cancel.
- Coarse perf guard (environment-tolerant, like the truncate guard): one
  in-process 10-palette batch completes < 1000 ms.
- Runtime-only (user live smoke): actual feel on Mac + iPad, flash timing,
  shift keys through ShellFish/Mac keyboards.

## Out of scope

- Draw-side row caching (draw ≈ 40-80 ms — revisit only if still felt).
- Deferred/idle preview recompute; per-scheme partial reloads (the stale-row
  confusion stays dead).
- The switcher popup and seed-screen key loops beyond the listed changes.
