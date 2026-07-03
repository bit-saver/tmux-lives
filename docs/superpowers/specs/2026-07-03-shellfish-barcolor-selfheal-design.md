# Design — ShellFish bar-color self-heal (tick re-emit)

**Date:** 2026-07-03
**Status:** Designed (awaiting user review → writing-plans)
**Builds on:** the ShellFish per-server bar color (`__tcz_emit_barcolor` OSC, the `client-attached` → `on-attach` hook, `__tcz_recolor`, `setup color`/`--apply`).

## Why

ShellFish tabs occasionally show a **stale** bar color — a new `Cmd+T` tab whose `client-attached` emit was missed/raced, a tab open when the color changed, or a reattached tab. Live diagnosis (2026-07-02) confirmed the tab *is* detected as ShellFish (`LC_TERMINAL=ShellFish` present) and that `setup color --apply` (which re-emits via `__tcz_recolor`) fixes it — and that **re-emitting the same color is silent (no flicker)**. So the tab can always receive the OSC; it just isn't re-pushed at the right time. This makes that refresh automatic so the user never has to run `--apply` manually.

## Goals

- A stale ShellFish tab self-heals to the stored color within ~15s, with no manual command and no flicker.
- Covers every staleness cause (missed `client-attached`, race, mid-session color change, reattach) with one mechanism.
- Zero effect on non-ShellFish clients and the no-color case.
- No new test touches the live tmux server / universals (the project's hard isolation invariant).

## Non-goals (YAGNI)

- A `client-focus-in` hook for instant switch-back refresh — the periodic re-emit already covers backgrounded stale tabs, and `client-attached` still colors fresh tabs instantly; the extra hook depends on ShellFish sending tmux focus events (uncertain) for marginal gain.
- Throttling — `status-interval` (15s) already bounds how often the tick's `#()` runs.

## Design — piggyback the status-right tick

tmux refreshes a `status-right` `#()` command every `status-interval` (15s). The managed fragment already runs the categorize tick there: `status-right = "#{T:@tmux_lives_status_right}#(fish --no-config $cat tick)"`. Two changes turn that into a bar-color self-heal:

### 1. Fragment — bake the color into the tick call

`__tmux_lives_render_fragment` renders the tick call with the ShellFish color as an argument:

```
set -g status-right "#{T:@tmux_lives_status_right}#(fish --no-config $cat tick '$color')"
```

`$color` is already an argument to the render (argv[4], the same value baked into the `on-attach` hook). Because `setup color` re-renders the fragment (`__tmux_lives_write_fragment`), the baked tick color stays current — identical lifecycle to the `on-attach` hook's baked color. When no color is set the render is `tick ''`.

Rationale for baking (not reading the universal): the tick runs under `fish --no-config`, which does **not** see the `tmux_lives_bar_color` universal (verified — it returns empty). Baking mirrors the existing on-attach pattern and needs no new render argument.

### 2. Categorizer — the tick re-emits

`__tcz_main`'s `tick` case, after the existing categorize, re-emits when a non-empty color was passed:

```
case tick
    __tcz_categorize >/dev/null 2>&1
    test -n "$argv[2]"; and __tcz_recolor $argv[2]
    return 0
```

`__tcz_recolor` iterates `tmux list-clients`, filters to ShellFish clients (`__tcz_client_is_shellfish`), and emits the OSC to each client's tty — so non-ShellFish tabs are skipped and an empty color is a no-op (double-guarded: the `test -n` here plus `__tcz_recolor`'s own empty guard). `tmux` is on the system PATH under `--no-config`, so `list-clients` works.

### Data flow

`setup color <css>` → `write_fragment` bakes `$color` into the `on-attach` hook **and** the tick call → every ~15s tmux runs `#(… tick '<css>')` → `__tcz_categorize` + `__tcz_recolor <css>` → OSC re-emitted to every attached ShellFish tty → any stale tab refreshes silently. `client-attached` continues to color fresh tabs instantly; the tick is the safety net.

## Architecture / where things live

- `conf.d/tmux-lives-install.fish`: one-line change to the `status-right` render in `__tmux_lives_render_fragment` (append `'$color'` to the tick call).
- `functions/tmux-categorize.fish`: extend the `tick` case in `__tcz_main` (one `test -n … and __tcz_recolor` line).

## Testing & isolation (hard invariant)

- **Fragment render** (`tests/test-tmux-install.fish`): the rendered tick call bakes the color — assert `*tick '#1f6feb'*` when a color is passed to `__tmux_lives_render_fragment`, and `*tick ''*` (no color) when it isn't. Pure render, no live touch.
- **Categorizer tick re-emit** (`tests/test-tmux-categorize.fish`): reuse the existing `__tcz_recolor` stub harness (stub `function tmux` to fake `list-clients`, write to temp ttys, inject `tmux_lives_fake_environ` for ShellFish detection). Assert `__tcz_main tick "#1f6feb"` writes the OSC to the shellfish client tty; `__tcz_main tick ''` and bare `__tcz_main tick` write nothing (backward-compat). No live server mutation.

## Pre-flight (tmux 3.3a — already established this session)

- `#()` in `status-right` is refreshed on `status-interval` (15s), bounding the re-emit cadence — no throttle needed.
- Re-emitting the identical `settoolbar` OSC is silent in ShellFish (no flicker) — user-confirmed live 2026-07-02.
- `fish --no-config` cannot read the `tmux_lives_bar_color` universal → the color must be baked into the tick call (verified).
- `__tcz_recolor` / `__tcz_client_is_shellfish` / `__tcz_emit_barcolor` already exist and are exercised by the current suite.
