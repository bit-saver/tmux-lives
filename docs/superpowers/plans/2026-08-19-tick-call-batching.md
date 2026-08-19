# Tick call batching — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` to execute this task-by-task.

**Goal:** one tick issues **O(1)** `tmux` client invocations instead of O(sessions)+O(clients). Measured today on rocket: 44 spawns, 0.14 s CPU, firing 4.2×/sec against the 0.46/sec that `status-interval 15` implies. On macwork: 84 spawns, 0.83 s CPU, 12.1×/sec, ~10 of 14 cores.

**Spec:** `docs/superpowers/specs/2026-08-19-tick-tmux-call-batching-design.md` — read it first; it carries the measurements and the reasoning.

**Architecture:** a new `__tcz_tmux_load`, idempotent per pass, takes at most four batched reads into per-key globals and is flushed at the top of `__tcz_main` beside `__tcz_ps_flush`. Every per-session and per-client lookup becomes an accessor over that snapshot. This is the same pattern `__tcz_ps_load` already uses for `ps`; follow it rather than inventing a second shape.

## Global constraints

- **No behaviour change.** Same names, same displays, same options written, same values. This is a read-path restructure and nothing else.
- **The narrowed (`fish_postexec`) path stays narrowed.** A command in one pane cannot change another session's classification. The pane read may stay scoped with `-s -t`; session and global reads are single calls either way.
- **Never add a subprocess** to compensate for a removed tmux call. This project spent a whole cycle removing per-session subprocesses after macOS `pgrep` routed through a root daemon and burned four cores.
- **A memoized read is stale the moment something writes.** Every option write in a pass must invalidate its key in the memo, or be *proven* to have no later reader in the same pass. Prove it — do not assert it. Two claims of exactly that shape have been overturned by measurement on this project in the last week.
- **Flush with a GLOB, not a regex.** `string match -r` with a prefix pattern returns the *matched substring*, so a regex-based flush erases a variable literally named after the prefix while every real entry survives — that exact bug shipped in `__tcz_ps_flush` and was found only by mutation.
- The snapshot row stays exactly 5 tab-separated fields; four call sites split it `-m 4` with a greedy last field.
- `__tcz_session_target` for `set-option`/`show-option`/`display-message`/`capture-pane`; `__tcz_pane_target` for `list-panes`.
- **Do not assert wall-clock anywhere.** This repo already has a load-sensitive timing assertion that flakes and trains a re-run-until-green reflex. Call counts are deterministic; times are not.
- Every assertion proven to FAIL pre-change, except deliberate non-regression guards — label those.
- Gate: 8/8 both modes, `test-tmux-install.fish` 708 plain / 707 `--no-config` (delta by design), `test-tmux-categorize.fish` 1125. Foreground only, explicit `timeout: 600000`, never `&`.

---

## Task 1 — the invariant harness

**The measurement is the deliverable.** Everything after this is judged by it.

Build a harness that runs one `tick` against a fixture of N sessions with a `tmux` shim first on `PATH` that logs each invocation and `exec`s the real binary:

```bash
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> LOG\nexec /usr/bin/tmux "$@"\n' > $SHIM/tmux
```

**Assert the property, not a number.** A magic ceiling drifts with fixture size and invites re-tuning until green. The real invariant is that the count **does not grow with session count**:

> run the tick against a 2-session fixture and a 6-session fixture; the difference in invocation count must be ≤ a small constant.

Today that delta is large, which is your RED. Record the two raw counts in the report so later tasks can show the ratchet.

Also capture an **equivalence baseline**: `__tcz_snapshot` and `__tcz_overview` output, and the set of option writes emitted, for a fixed fixture. Later tasks must reproduce it byte-identically. A batching refactor that quietly changes a value is worse than the cost it fixes.

Use an isolated `-L` socket with `-f /dev/null` and explicit pane commands — without both, the fixture loads the user's real `~/.tmux.conf` and their real login shell, which has destabilised the socket before.

Commit: `test(tick): pin the O(1) tmux-call invariant and an equivalence baseline`

## Task 2 — global `@options` in one read

Nine `show -gv @tmux_lives_…` calls, one per key. `tmux show -g` returns all 37 `@tmux_lives_*` globals in a single call — verified on the live server.

Add `__tcz_tmux_load`'s global half plus accessors, and route every `show -gv @…` reader through it. Flush beside `__tcz_ps_flush` in `__tcz_main`, using the `__tcz_tmux_` prefix and a glob.

Expect the delta from Task 1 to shrink. Report both counts.

Commit: `perf(tick): read global @options in one show -g`

## Task 3 — session `@options` in the read that already happens

Nineteen per-session `show-option -qv -t S @…` calls: 9 `@tmux_lives_name`, 6 `@tmux_lives_claude`, 4 `@tmux_auto_name`.

**`list-sessions -F` can read `@options` — this is proven in production, not speculative:** the existing `sess_fmt` already carries `#{@tmux_lives_name}`. Extend that one call to carry `@tmux_lives_claude`, `@tmux_auto_name` and `@tmux_lives_display` too, and serve `__tcz_owned`, the claim checks and `__tcz_set_claude_opt`'s dedup read from it.

**Watch the field-splitting contract.** Adding fields to a tab-separated format changes which field is greedy. An `@option` holds arbitrary user text and may contain a tab; keep the most arbitrary value last, exactly as the current row keeps `@tmux_lives_name` greedy-last, and adjust every `string split -m N` accordingly.

Biggest single win. Report the counts.

Commit: `perf(tick): fetch session @options in the batched list-sessions`

## Task 4 — pane walks from the one `list-panes -a`

Twelve calls: 6 `list-panes -s -t S` (cmd/pid/title) in `__tcz_set_claude_opt`, 3 `list-panes -s -t S` (cmd/pid) in `__tcz_session_has_claude`, 3 `list-panes -t S` (active path) in `__tcz_session_title`.

One `list-panes -a -F` carrying `#{session_name}`, `#{window_active}`, `#{pane_active}` and the pane fields serves all three — verified on the live server.

**Two measured facts you need.** `list-panes -t <session>` *without* `-s` resolves to the session's **currently selected window**, so serving `__tcz_session_title` from the batch needs the `window_active` **and** `pane_active` filter to pick the same pane it picks today. And `display-message -t "=name"` returns empty for **every** format, not just pane-scoped ones — do not "simplify" any of this into a `display-message`.

Report the counts.

Commit: `perf(tick): serve the per-session pane walks from one list-panes -a`

## Task 5 — clients, and the staleness audit

Merge the two `list-clients` reads into one carrying the union of their fields.

Then the hazard, which is the real content of this task. **Audit every tmux option write reachable in a pass** — `@tmux_lives_claude`, `@tmux_lives_display`, `@tmux_auto_name`, the per-tty emit caches — and for each either invalidate that key in the memo on write, or demonstrate with a repro that no later read exists in the same pass.

Note the one known read-then-write, `__tcz_set_claude_opt`: it reads `@tmux_lives_claude` for its dedup and then conditionally writes it. Reading the pre-write snapshot there is **correct** — that is what the dedup wants. Do not "fix" it.

Add a staleness test: write an option mid-pass, read it after, see the new value.

Commit: `perf(tick): single list-clients read; invalidate memoized keys on write`

## Task 6 — verify the rate, and document

**Re-measure the tick rate.** The spec's explanation — that a ~1s `#()` job is always eligible to re-arm, so `status-interval` stops rate-limiting it — predicts the rate falls to roughly `clients / status-interval` once the cost drops. **That is a hypothesis, not a given.** Measure distinct tick pids over a window, as was done to find this:

```
pgrep -f 'tmux-categorize.fish tick'  sampled over ~15s, count distinct
```

If the rate does **not** fall, say so plainly — it means there is a second cause and this cycle fixed only the cost. That is a useful finding, not a failure.

Then record in `CLAUDE.md`, before `## claude-mem history`: the measured before/after (spawns per tick, CPU, rate, both hosts), the `__tcz_tmux_load` pattern and its flush-with-a-glob trap, the staleness rule for memoized reads, and whether the rate hypothesis held.

`CLAUDE.md` is agent-facing and exempt from the repo's no-hard-wrap rule — wrap it like its surroundings. Do not touch `README.md`.

Commit: `docs(claude): record the tick batching cycle and its measurements`
