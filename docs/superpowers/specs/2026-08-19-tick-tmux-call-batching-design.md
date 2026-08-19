# The tick spawns a tmux client per lookup — batch them, the way `__tcz_ps_load` already does for `ps`

**Status: APPROVED, NOT BUILT** (2026-08-19). Purely an internal restructure of how the categorizer *reads* tmux state. No user-visible behaviour changes, no naming or display rule changes, no new options.

## The finding

From a macwork handoff (`docs/2026-08-19-handoff-tick-rate-and-tmux-client-spawns.md`), independently reproduced on rocket. **The status-bar tick spawns a separate `tmux` client process for almost every value it reads**, and the count scales with session and client count.

| | rocket (6 sessions, 7 clients) | macwork (8 sessions, 11 clients) |
|---|---|---|
| `tmux` client spawns per tick | **44** | 84 |
| CPU per tick | 0.14 s | 0.83 s |
| measured tick rate | **4.2 /sec** | 12.1 /sec |
| rate implied by `status-interval 15` | 0.46 /sec | 0.7 /sec |
| overshoot | **9×** | 17× |
| sustained cost | ~0.6 of 6 cores | **~10 of 14 cores** |

Removing the tick from macwork's live `status-right` moved that host from **4.31% idle to 77.8% idle** within seconds, with system time falling 54% → 9.4%. That is the confirming A/B.

**The rate is the amplifier and it is a consequence of the cost.** tmux re-runs a `#()` job whenever the format is evaluated and that job is not already running. A job taking ~1s wall is essentially always eligible to restart, so with many clients evaluating status it re-arms continuously instead of being served from cache between intervals. The actionable form, independent of mechanism: **a `#()` hook that takes ~1s cannot be rate-limited by `status-interval` — its cost is bounded by how fast it finishes.** Getting the tick under a few tens of milliseconds should fix the rate as a side effect. **Treat that as a hypothesis to verify after the fix, not as a given.**

## Exactly where the 44 calls go (measured, rocket, normalised)

| shape | n | caller |
|---|---|---|
| `show-option -qv -t S @tmux_lives_name` | 9 | claim checks, per session and per client |
| `show-option -qv -t S @tmux_lives_claude` | 6 | `__tcz_set_claude_opt` dedup read, per session |
| `list-panes -s -t S` (cmd/pid/title) | 6 | `__tcz_set_claude_opt`, per session |
| `show-option -qv -t S @tmux_auto_name` | 4 | `__tcz_owned`, per session |
| `show -gv @tmux_lives_…` | 9 | **one call per key** |
| `list-panes -t S` (active pane path) | 3 | `__tcz_session_title`, per client |
| `list-panes -s -t S` (cmd/pid) | 3 | `__tcz_session_has_claude`, per client |
| `list-sessions` · `list-panes -a` · `list-clients` ×2 | 4 | the legitimate one-shots |

Nine are structural. **Thirty-five are the same handful of facts fetched over and over.**

## The design: one load per pass, memoized — the pattern already in this file

`__tcz_ps_load` solved precisely this shape for `ps` during the sysmond work: take one snapshot per pass into per-key globals, flush it at the top of `__tcz_main`. Extend the same pattern to `tmux`.

**A new `__tcz_tmux_load`, idempotent per pass, issuing at most four calls:**

1. `list-sessions -F` carrying every session `@option` the pass needs.
2. `list-panes -a -F` carrying every pane field, plus `#{window_active}` and `#{pane_active}` so the per-session and per-client walks can be served from it.
3. `list-clients -F` with the union of the fields the two current calls want.
4. `show -g`, parsed once into the global `@option` table.

**All three mechanisms are verified working on the live server**, and none is novel here:
- `list-sessions -F` already reads `#{@tmux_lives_name}` in production, so reading `@tmux_lives_claude`, `@tmux_auto_name` and `@tmux_lives_display` the same way is proven, not speculative.
- `tmux show -g` returns all **37** `@tmux_lives_*` globals in a single call.
- `list-panes -a -F '#{session_name}…#{window_active}#{pane_active}'` supplies everything the per-session walks fetch individually.

**Target: ≤5 `tmux` client spawns per tick**, from 44.

**Flush alongside `__tcz_ps_flush` at the top of `__tcz_main`**, and use the same `__tcz_tmux_*` global-name prefix so one glob clears it. Note the trap that bit the `ps` version: `string match -r` with a prefix pattern returns the *matched substring*, so the flush must use a **glob**, or it erases a variable literally named after the prefix while every real entry survives.

## The hazard this introduces, and it is the one to test hardest

**A memoized read is stale the moment something writes.** Today every lookup is fresh, so a read-after-write inside a pass is self-consistent by accident. After this change it is not.

The known read-then-write in the pass is `__tcz_set_claude_opt` (reads `@tmux_lives_claude` for its dedup, then conditionally writes it). Reading the pre-write snapshot there is *correct* — that is exactly what the dedup wants. But the general rule must be explicit and enforced: **any write to a tmux option must invalidate that key in the memo**, or a later reader in the same pass gets a value that is already wrong.

Audit every write site in the pass (`@tmux_lives_claude`, `@tmux_lives_display`, `@tmux_auto_name`, the per-tty emit caches) and either invalidate on write or prove no later read exists. Do not assume the second — prove it, because "nothing reads it later" is exactly the kind of claim this project has had overturned twice this week.

## Constraints

- **The narrowed (`fish_postexec`) path must stay narrowed.** It exists because a command in one pane cannot change another session's classification. The pane query may be scoped with `-s -t` as it is today; the session and global queries are single calls either way.
- **No behaviour change.** Same names, same displays, same options written, same values. This is a read-path restructure.
- The snapshot row stays exactly 5 tab-separated fields.
- `__tcz_session_target` for `set-option`/`show-option`/`display-message`/`capture-pane`; `__tcz_pane_target` for `list-panes`. Batched calls that name no session sidestep the numeric-name trap entirely, which is a quiet secondary benefit.
- Do not add a subprocess anywhere to compensate.

## Testing

**The invariant, and it is fully testable on Linux — this is not macOS-specific:** *one tick issues O(1) `tmux` client invocations, not O(sessions) or O(clients).* Assert a hard ceiling using the shim recipe from the handoff (a `tmux` wrapper first on `PATH` that logs and `exec`s the real binary), with a fixture of several sessions and clients so a regression to per-session lookups actually trips it. This mirrors the existing spawn-count assertion added for `ps`.

**Equivalence is the other half.** Capture `__tcz_snapshot`, `__tcz_overview` and the emitted option writes before and after, on an identical fixture, and assert byte-identical output. A batching refactor that quietly changes a value is worse than the cost it fixes.

**Staleness:** a test that writes an option mid-pass and then reads it must see the new value.

**Do not assert wall-clock.** This repo already has a load-sensitive timing assertion that flakes and trains a re-run-until-green reflex. Assert the call count, which is deterministic.

## Verify after, do not assume

Re-measure the tick *rate* once the cost drops. The self-sustaining-re-arm explanation predicts the rate falls to roughly `clients / status-interval` on its own. If it does not, the rate has a second cause and this spec only fixed the cost.

## Not doing

- Changing `status-interval`, the heal backstop, or any emission policy.
- Touching the `fish_postexec` narrowing, which is already correct.
- The unrelated orphaned `dash` loop the handoff noticed on macwork; it is not ours and its own CPU is negligible.
