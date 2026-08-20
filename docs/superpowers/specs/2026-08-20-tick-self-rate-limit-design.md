# The tick needs a self-rate-limit — batching fixed the cost, not the rate

**Status: APPROVED, NOT BUILT** (2026-08-20). Follow-up to the tick call-batching cycle. Independent of it: batching makes each tick cheap, this caps how often it runs at all. Both are wanted.

## Why this exists

The batching cycle took the tick from **44 `tmux` client spawns to 9** in steady state. That is real and unconditional. But an A/B on an isolated server with real pty clients measured something the cycle's own hypothesis did not predict:

| clients | rate old → new | calls/invocation | net spawns/sec |
|---|---|---|---|
| 8 | 0.83 → 0.67 /s | 71 → 12 | **59 → 8** (7.4× better) |
| 16 | 4.9 → **10.0** /s | 111 → 20 | **549 → 200** (2.6× better) |

**At 16 clients the batched tick fires roughly twice as often, not less.** Reproduced four times, including with the old/new order reversed.

The spec that drove the batching cycle claimed a ~1 s `#()` job "is essentially always eligible to restart, so getting the tick under a few tens of milliseconds fixes the rate as a side effect." **That was half wrong, and the correction is the point of this document.** The plausible mechanism — hedged, not verified against tmux internals — is that tmux reuses a still-running `#()` job across near-simultaneous evaluations, so a *slow* job occupies that "don't restart" window *longer* and a *fast* job gets re-armed *more* as concurrency rises.

The user's Mac runs 11 clients, between the two measured points, and was at roughly 10 of 14 cores. Batching alone should get it to somewhere in the 1.5–4 core range — better, plausibly not fixed. **200 spawns/sec is still a lot of process creation for a status bar.**

## The core observation

**`status-interval` does not rate-limit a `#()` job, and the tick has no self-limit of its own.** It does its full work every single time tmux asks, however often that is. Nothing in the codebase caps that.

So the rate is not a property we control today — it is whatever tmux's re-arm behaviour produces, times the client count. Batching changed the cost per invocation and, at high concurrency, made the invocation count *worse*.

## The design

**Gate the tick on elapsed time, in the cheapest possible way, and make the fast path do no work at all.**

- The check must cost **zero `tmux` calls**. A `tmux` read to decide whether to skip would defeat the purpose at exactly the concurrency where it matters most. Use a file mtime under `/tmp` (or `$XDG_RUNTIME_DIR`), read with fish builtins, no subprocess.
- If the last full pass was under the threshold ago, **exit immediately and emit nothing.** Cost approaches fish's own startup, which is ~6 ms — against ~9 tmux round-trips today.
- Default the threshold to something under `status-interval` so a genuinely-due tick is never skipped. `status-interval` is 15 s; a threshold around 5 s bounds the rate at 0.2/s per host regardless of client count, while still refreshing well inside the interval.
- Make it configurable and disableable, following the file's existing convention for such knobs (a universal read via `__tmux_lives_key`, `0` disables). Note the two existing precedents — `tmux_lives_cursor_style` and `tmux_lives_sync_terminals` — are `set -U`-only with no `setup` CLI surface, which is a recorded wart rather than a pattern to copy; prefer a CLI setter if it is cheap.

**The state is per-host, not per-client.** Every client's evaluation triggers the same work against the same server, so one timestamp for the whole server is correct. Two clients evaluating simultaneously should produce one pass, not two.

## What must NOT be skipped

This is where a careless implementation breaks things. The tick verb does several jobs, and they do not all tolerate being rate-limited identically:

- `__tcz_categorize` — the naming pass. Safe to skip; the `fish_postexec` hook covers the responsive case, and the tick is the backstop.
- `__tcz_recolor` / `__tcz_retitle` in **dedup** mode — safe to skip, they are idempotent and self-healing.
- The **heal backstop** (`__tcz_heal_due`) — already has its own ~120 s timer. Skipping ticks lengthens its effective granularity; check that a 5 s gate does not push heal past its own interval in a way that matters.
- **`continuum_save.sh`** is *not* ours and sits in the same `status-right`. It must be untouched — dropping it silently kills tmux-continuum's autosave, which this project has already been bitten by (`docs/2026-07-30-handoff-status-right-and-update-environment.md`). Verify the gate cannot affect it.

## Testing

**Rate is the property, so assert the property.** The existing `tests/test-tmux-tick-calls.fish` harness counts `tmux` invocations under a `PATH` shim; extend that shape: invoke the tick twice in quick succession and assert the second issues **zero** tmux calls, then invoke past the threshold and assert it does a full pass.

**Do not assert wall-clock durations.** This repo has a load-sensitive timing assertion that flakes and trains a re-run-until-green reflex. Inject the clock instead — `tmux_auto_now` already exists as a seam for exactly this in `conf.d/tmux.fish`.

Mutation-prove both directions: remove the gate and confirm the "second tick is free" assertion fires; force the gate always-on and confirm the "past the threshold does a full pass" assertion fires. A gate that always skips is as broken as one that never does, and only the second direction catches it.

**Re-run `tests/tick-rate-ab.fish`** afterwards. It is the only measurement that speaks to the actual pathology, and it is deliberately outside the gate because it samples a live window.

## Honest limits

- The re-arm mechanism is **unverified against tmux internals**. This design does not depend on understanding it — a hard cap works whatever tmux is doing — but do not let the hypothesis in this document harden into a fact, the way the previous cycle's rate prediction did.
- A rate limit trades freshness for cost. At a 5 s threshold the status bar can be up to 5 s stale beyond its normal interval. That is almost certainly fine for session names and tab colours; it is the user's call if they disagree.
- This does not remove the value of batching. At 8 clients the batched tick was already 7.4× better on net traffic; the limiter caps the tail at high concurrency rather than replacing the cost work.
