# Design — picker input coalescing (burst read + single redraw)

**Date:** 2026-07-08
**Status:** SHIPPED to main 2026-07-08 (4 TDD tasks; final whole-branch review opus = ready-to-merge, no Critical/Important; 8/8 suites green). Pending: user's `fisher update` + live smoke (hold-↓ tracking, x→y/n confirm, SS3 nav).
**Repo:** tmux-lives (`functions/tmux-categorize.fish`, `tests/test-tmux-popup.fish`)
**Builds on:** the pure-fish two-pane popup switcher — `__tcz_popup` (the read/draw loop), `__tcz_popup_readkey` (byte→key reader, being replaced), `__tcz_popup_draw`/`__tcz_popup_preview` (the per-frame `capture-pane`).

## Why

The picker's up/down arrows lag noticeably when the host is under load. The lag is not tl's fault at the baseline — it's raw SSH (no predictive echo) over a bursty, ~load-5 host — but the picker's loop is structured so its cost scales with **keystrokes**, which amplifies that host lag badly.

`__tcz_popup`'s loop is `draw → read ONE key → repeat`, and `draw` runs `tmux capture-pane` for the live preview on every frame. So each arrow key costs, host-side:

- **~8 process forks to read one key** — `__tcz_popup_readkey` reads the 3-byte arrow escape (`\e[A`) one byte at a time via `dd bs=1 count=1 | od`, plus two `stty` calls.
- **one `tmux capture-pane`** — a full colored capture + ANSI clip of the newly-selected session's pane, on every redraw.

Holding ↓ down a 10-item list = ~10 sequential `(8 forks + capture)` cycles, one at a time, each stalling in the run queue. Measured on this host: key-read ~4.6 ms, capture ~2.3 ms per keypress even at low load; under a load-5 burst each fork waits for a scheduler timeslice and they stack.

The fix is to make the loop's cost scale with **input bursts** instead of keystrokes: read everything buffered at once, apply all the navigation, redraw once.

## Goals

- Holding / mashing ↑↓ jumps straight to the settled position with **one** `capture-pane` + redraw per burst, instead of one per intermediate step.
- Cut the per-key fork cost: read a whole burst in ~1 `dd`/`od` pair rather than ~8 forks per key.
- **Zero user-visible behavior change** — every key (↑↓/`j`/`k`/`Enter`/`x`+confirm/`q`/`Esc`) behaves exactly as today.
- The risky logic (byte→key parsing) becomes a **pure, tty-free, unit-tested** function.
- No new dependency on the live tmux server in tests (the project's isolation invariant); pure tests + pipe-fed reads, as the current `readkey` tests already do.

## Non-goals (YAGNI)

- **No deferred/async preview** (Tier 3): drawing the list instantly and firing `capture-pane` only after input goes idle would need a timeout-based pseudo-async read. Once coalescing exists, a single deliberate press already costs just one capture (~2–3 ms) — not worth adding that complexity to a loop with a history of subtle key bugs.
- **No change to `__tcz_modal_readkey`** (the launcher's single-key reader) — it reads one key then closes; no hot path, no perf issue.
- **No change to the `x`/kill `y/n` confirm reader** — a single deliberate keypress, left byte-by-byte.
- **No host-load, SSH, or mosh changes** — that is the separate system-side track and not tl's job. (Mosh specifically cannot help the picker: it predicts line-oriented typed-text echo, not full-screen popup redraws.)

## Design

### The loop restructure — cost scales with bursts, not keys

`__tcz_popup`'s inner loop changes from consuming one key per iteration to consuming one **burst** per iteration:

```
while true
    __tcz_popup_draw $sel $listw $prevw $rows "$current" -- $model   # once per burst
    set -l brk 0
    for k in (__tcz_popup_read_keys)          # blocks for ≥1 key, drains the rest
        switch $k
            case up;    test $sel -gt 0;              and set sel (math $sel - 1)
            case down;  test $sel -lt (math $n - 1);  and set sel (math $sel + 1)
            case enter; set result <name at sel>; set brk 1; break
            case kill;  <confirm + kill + refresh model/sel/n>; test $n -gt 0; or set brk 1
                        break
            case cancel; set brk 1; break
            # 'other' — ignored
        end
    end
    test $brk -eq 1; and break
end
```

`draw` stays at the top of the loop, so it fires exactly once per burst (once per iteration). Navigation deltas in a burst all apply before the next draw; the first terminal key (`enter`/`cancel`/`kill`) applies and breaks the inner `for`, discarding any bytes after it in that burst.

### Two new functions (replacing `__tcz_popup_readkey`)

**1. `__tcz_popup_parse_keys` — pure, fully unit-testable.**
Arguments: a list of hex bytes. Returns: a list of key tokens (`up`/`down`/`enter`/`cancel`/`kill`/`other`), one per recognized key. Holds *all* the byte→key logic currently inside `__tcz_popup_readkey`:

- `6a`→`down` (`j`), `6b`→`up` (`k`), `71`→`cancel` (`q`), `78`→`kill` (`x`), `0d`/`0a`→`enter`.
- `1b 5b <b>` (CSI) and `1b 4f <b>` (SS3): `41`→`up`, `42`→`down`, else `other`.
- A trailing lone `1b` (or `1b 5b` / `1b 4f` with no final byte) → `cancel` (bare Esc), matching today's behavior.
- Any other byte → `other`.

No `dd`, no `stty`, no tty — bytes in, tokens out. This is the change's risk surface, and it is now trivially testable.

**2. `__tcz_popup_read_keys` — thin, impure.**
Reads one burst and returns tokens. One `dd bs=256 count=1 | od -An -tx1` grabs everything currently buffered (blocking for the first byte via the ambient `stty … min 1 time 0`, so the loop idles cheaply; returning all bytes present, so a held arrow's whole run comes back in one read). If the chunk ends mid-escape (dangling `1b` / `1b 5b` / `1b 4f`), one `stty min 0 time 1` completion read fetches the tail — the same safety the current ESC follow-read gives, generalized to the chunk. Passes the hex bytes to `__tcz_popup_parse_keys` and echoes the tokens. Pipe-testable exactly like `readkey` is today (`stty` no-ops harmlessly on a pipe, `2>/dev/null`).

`__tcz_popup_readkey` is removed; its only caller is the loop, and its 4 existing tests migrate to the new functions.

### Behavior preservation

- All keys behave identically; the `x`/kill flow keeps its own blocking `y/n` read and its model refresh unchanged.
- Terminal keys mid-burst are honored, not dropped: `down down enter` applies both downs then selects the settled row. This is strictly safer than today, where an `x` immediately followed by another key could misread the trailing byte as the `y/n` answer.
- Bare `Esc` vs. arrow disambiguation is preserved by the parser's trailing-`1b` rule plus the completion read.

## Testing & isolation (hard invariant)

All in `tests/test-tmux-popup.fish`, pure/pipe-fed, no live tmux (`tmux_categorize_test=1`, the existing `t "desc" expected (actual)` helper):

- **`__tcz_popup_parse_keys`** (pure — the bulk of the coverage):
  - single keys: `1b 5b 41`→`up`, `1b 5b 42`→`down`, `1b 4f 41`→`up`, `1b 4f 42`→`down`, `6a`→`down`, `6b`→`up`, `0d`→`enter`, `0a`→`enter`, `71`→`cancel`, `78`→`kill`, `1b` (alone)→`cancel`.
  - bursts: `1b 5b 42 1b 5b 42 1b 5b 42` → `down down down`; mixed `1b 5b 42 6a 6b` → `down down up`; nav-then-terminal `1b 5b 42 0d` → `down enter`; split escape `… 1b` at end → completion path (covered via `read_keys`).
  - junk bytes → `other` (ignored by the loop).
- **`__tcz_popup_read_keys`** (integration, pipe-fed, mirroring the current `readkey` tests): `printf '\e[A' | __tcz_popup_read_keys` → `up`; `printf '\e[B\e[B' | …` → `down down`; SS3 forms.
- The 4 existing `readkey` SS3/CSI tests are rewritten against `read_keys` (single key → one-element list).
- No change needed to the `layout`/`truncate`/`list_lines`/`clip`/`draw` tests.

## Rollout

Ships via the user's `fisher update` (never a Claude deploy). Runtime smoke in the live picker: open it, hold ↓ through a long list → selection tracks smoothly and lands where released, preview updates once at the end; `Enter` switches, `x`→`y` kills with the confirm, `q`/`Esc` cancel — all unchanged, and the arrow lag under load is gone.

## Decisions / open questions

- **Chunk size 256 bytes** — far larger than any realistic navigation burst between loop iterations; the completion read covers the rare mid-escape split.
- **`draw` stays at loop top** (one draw per burst) rather than moving it after apply — minimal diff to a bug-prone loop; a redundant redraw on an all-`other` burst is negligible.
- **Discard burst bytes after a terminal key** — acceptable (and safer than today); the `y/n` confirm still reads fresh.
