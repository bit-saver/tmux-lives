# Theme picker latency — root cause found, fix NOT built (on hold 2026-08-17)

> **UNPARKED 2026-08-21. The open question at the bottom is ANSWERED: transmission is the cause.** The A/B was run and a second control was added to close a confound the first left open. Design approved at `docs/superpowers/specs/2026-08-21-picker-partial-repaint-design.md`. **One claim in this document is wrong** — see "Correction" at the bottom. Everything else re-measured within drift at `HEAD`.
>
> | | Aug 17 | at `HEAD`, Aug 21 |
> |---|---|---|
> | warm frame construction | 27-32 ms | 29.7 ms |
> | bytes per frame | 14,485 | 12,697 |
> | bytes that change | 821 | 747 |
> | amplification | 17.6× | 17× |

**Status: PARKED mid-investigation**, one question short of a decision. Phase 1 of systematic debugging is complete and the root cause is measured. Nothing was changed. Resume by answering the single open question at the bottom.

## The report

User, 2026-08-17: *"The picker is still a bit unresponsive. It can be laggy, slow to respond to keypresses. Or ignores them completely. I never know if my keypress worked or not because too often I'll double press thinking it didn't work when really it was just slow to show anything change."*

Confirmed with them that this is the **theme picker** (`M-k`, `__tcz_theme_picker`), **not** the session switcher — they said explicitly "Session picker is fine I think." That matters: my first hypothesis was the switcher (which genuinely has no drain and no cache, and whose live `capture-pane` preview costs 27-28 ms of a ~38 ms redraw) and it was **wrong**. Do not re-chase it.

This is a shipped fix that did not deliver: the 2026-08-14 `feat/picker-responsiveness` cycle targeted exactly this picker and measured 167 ms -> 35 ms.

## Measured (rocket, load ~2.5, install byte-identical to HEAD)

| measurement | value |
|---|---|
| warm frame (cursor move, cache hit) | **27-32 ms** |
| cold frame (after any cache clear / reload) | **225-247 ms** |
| **bytes emitted per frame** | **14,485** |
| **bytes that actually change moving one row** | **821** (4 of 52 rows) |
| **amplification** | **17.6x** |
| frame wrapper | `\e[?2026h` … `\e[?2026l` (synchronized output) |
| SGR escapes per frame | 893 |

Geometry measured is the user's real one: 62-row client -> 52-row popup, 35 schemes, `STATIC_IDLE 17` / `STATIC_EDIT 22`.

Method: the suite's own `__t9_frame_rows` / `__t9_draw_nocc` harness, which `eval`s the **real** draw block extracted from the production file — not a reimplementation. `__t9_draw_nocc` is the no-cacheclear variant and is what a cursor move actually costs.

## Root cause

**The picker repaints the entire 52-row, 14.5 KB frame on every keypress, to communicate an 821-byte change, wrapped in synchronized output so the terminal paints nothing until all of it arrives.**

The caching from 2026-08-14 works — construction really is ~30 ms. The bottleneck moved to **emission**, which was never measured.

Two consequences that match the report exactly:

- Over a remote link the per-keypress cost is dominated by shipping 14.5 KB, not by the 30 ms of compute.
- Because of the sync wrapper there is **no progressive paint**, so a slow frame and an ignored keypress are indistinguishable to the user. That is the "I never know if my keypress worked" half, and it is a *feedback* defect, not only a speed one.

## The important part: this invalidates the reasoning that rejected the fix

CLAUDE.md records, from the 2026-08-14 cycle:

> **Partial repaint was considered and rejected**: it optimises EMISSION while the cost is CONSTRUCTION. Rebuilding 35 rows to emit 2 still pays the full price.

That was **correct when written and is wrong now, precisely because the caching succeeded.** Construction was 128-266 ms then and is 27-32 ms now; emission was never measured. The ratio has inverted, so the conclusion inverts with it. Do not treat the earlier rejection as settled — treat it as correctly decided on numbers that no longer hold.

## Secondary finding, not the main one

Any operation reaching `__tcz_thp_reload` costs **225-247 ms** because it clears all caches. Cursor movement does not reload (verified), so this is not the reported symptom, but it is the ceiling on `m` (expand/collapse), `enter`, and the deferred seed batch.

## THE OPEN QUESTION — answer this first on resume

I measured the bytes; I did **not** measure the user's link. "14.5 KB ≈ 100 ms" is arithmetic, not measurement, and this project's own lesson ([[terminal-lag-diagnosis]]) is to get the A/B control before blaming the environment.

The picker runs on whichever host's tmux you are in and paints back to your terminal, so:

- **iPad via ShellFish** — frame crosses a wifi/cellular SSH link
- **Mac in cmux on macwork's own local tmux** — frame never leaves the machine

**If transmission is the cause, the iPad is dramatically worse and the local Mac case is near-instant. If it is equally laggy locally, the root cause above is WRONG** and the investigation returns to Phase 1 rather than building on it.

## Fix shape if the A/B confirms transmission

Emit only the changed rows (cursor-addressed) instead of the whole frame — 821 bytes instead of 14,485. Keep the construction caching exactly as it is; it is doing its job. The frame proof (`__t9_frame_rows`) asserts row COUNT and would not notice partial emission, so it needs a companion assertion on emitted BYTES, and the synchronized-output wrapper has to stay correct across a partial paint.

Not designed, not planned, not built.

---

# ANSWER (2026-08-21): transmission, confirmed by a two-stage A/B

The user ran the discriminating test and reported the iPad **stutters badly** on a held down/up/down reversal while local cmux is smooth. That alone was **not** sufficient: at the time of the report the two sides differed in host (rocket vs macwork), tmux version (3.3a vs 3.7b) **and** transport, because rocket had only been brought up to `HEAD` at 07:43 that morning.

A second control closed it. Opening the theme picker on **rocket from cmux over the LAN** — same host, same tmux 3.3a, same code, same 29.7 ms construction — is **smooth**. Only the wire differs between that and the iPad case, so transport is the sole remaining variable.

| test | result |
|---|---|
| iPad → ShellFish → rocket (wifi/cellular) | stutters |
| cmux → macwork (local) | smooth |
| **cmux → rocket (LAN)** | **smooth** |

The reversal is the most sensitive probe available and it is worth knowing why, because it is the test to repeat after the fix. The arrow drain is discard-based, one step per frame, and deliberately direction-blind (`case up down` discards either token). When frames are wire-bound rather than CPU-bound the write blocks, autorepeat piles up in the tty buffer, and the drain swallows the entire queued burst as one net step — and on a reversal the swallowed taps are precisely the ones that change direction. Hold-down is merely slow; down → up → down is what makes it look broken.

# Correction: the "no progressive paint" claim does not hold on tmux 3.3a

This document states that the synchronized-output wrapper means the terminal paints nothing until the whole frame arrives, so a slow frame and an ignored keypress are indistinguishable. That was inferred from the bytes the picker *emits*; it was never checked against what tmux *forwards*.

**Measured on rocket: tmux 3.3a drops app-sent `\e[?2026h`/`l` entirely.** It never reaches ShellFish. A bogus `\e[?9999h`/`l` control behaves identically, so this is not specific to 2026 — tmux simply does not forward private modes it does not implement, and app-sent DECSET 2026 support landed after 3.6a.

So on the user's iPad path ShellFish paints **progressively** as the 12.7 KB arrives, and the symptom is pure throughput. That matches the user's word *stuttering*, and it differs from this document's original report ("I never know if my keypress worked"), which is the all-or-nothing signature. The feedback defect described above is real but applies to tmux ≥ 3.7 — macwork, where the project's own `terminal-features xterm*:sync` fix deliberately enables synchronized output — not to rocket.

**Method note, because two earlier attempts at this measurement were void.** The agent shell here is zsh; it mangled the quoting, the pane printed the escape sequences as literal text, and a `grep` for `[?2026` matched those literals and reported "forwarded". The measurement above puts the emitter in a file so no quoting layer can corrupt it, verifies the emitter writes real ESC bytes, reads the client pty with a hexdump rather than a string match, and carries the `?9999` control. A probe that cannot discriminate returns a confident wrong answer — this file's own synthetic-probe lesson, hit again.
