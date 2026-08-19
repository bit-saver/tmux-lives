# Handoff → tmux-lives: the tick costs 84 `tmux` client spawns and fires 17× more often than `status-interval` implies

**From:** the macwork session that filed the pgrep/sysmond handoff and its verification, 2026-08-19. **Not touched by me** — no tmux-lives file was modified, no commit, no push. One runtime change was made to the live server on macwork and is documented in §5 with its exact revert.

**Your pgrep fix is working.** `ps` is down to 13 per tick, `pgrep` is absent, `sysmond` is quiet. This is a *different and larger* cost that sat underneath it and that none of us measured, because the original investigation counted `pgrep` and `ps` and never counted `tmux`.

**Severity: high.** macwork was at **4.31% idle, load 11–14, 54% system time**, fan ~50% for a second day. Removing the tick from `status-right` took it to **77.8% idle, 9.4% system time** within seconds. That is ~10 of 14 cores.

---

## 1. Two independent multipliers

**(a) One tick spawns 84 `tmux` client processes.** Counted with a `tmux` shim first on `PATH`, invoking the same command your `status-right` runs:

```
tmux invocations in one tick: 84
ps   invocations in one tick: 13

  37 show-option
  17 show
  17 list-panes
   7 display-message
   4 list-sessions
   2 list-clients
```

Each is a separate process that opens the server socket, does a round-trip, and exits. Wall cost of one tick: **1.075 s, of which 0.83 s is CPU** (0.40 user + 0.43 sys). For comparison, a bare `fish --no-config -c true` is 0.006 s and `continuum_save.sh` is 0.046 s — so essentially the entire tick cost is these 84 round-trips.

**(b) The tick fires 12.1 times per second.**

```
distinct tick fish pids: 207 over 17 s  =>  12.1 ticks/sec
expected from status-interval 15 with 11 attached clients: 0.7/sec
```

**17× over.** `status-interval` is confirmed still `15`, and 11 clients were attached.

12.1 ticks/s × 0.83 s CPU = **10.1 cores**, against a machine showing ~13 cores busy. The arithmetic closes.

## 2. Why the rate is 17× — hypothesis, not proven

Not pane output: I sampled every pane's `history_size` twice five seconds apart and **no pane grew a single line**, so redraws are not being driven by output.

The leading explanation is that **the tick is slow enough to become self-sustaining**. tmux runs `#()` jobs asynchronously and re-runs one whenever the format is evaluated and that job is not currently running. A job taking 1.075 s wall is essentially always eligible to restart, so with 11 clients each evaluating status it re-arms continuously rather than being served from cache between 15 s intervals.

There is a plausible feedback term on top: the tick issues 84 `tmux` client commands, each of which is server work that can dirty the status and trigger another evaluation. I have not proven that loop and am flagging it as a hypothesis — but it predicts the observed behaviour, including why the effect scales with client count rather than with `status-interval`.

**The actionable form of this, independent of the mechanism:** a `#()` status hook that takes ~1 s cannot be rate-limited by `status-interval`, so its cost is bounded by how fast it completes, not by the interval you configured. Getting the tick under a few tens of milliseconds fixes the rate problem as a side effect of fixing the cost problem.

## 3. Where the 84 calls likely collapse

- **37 `show-option` + 17 `show` = 54 calls.** One `tmux show-options -g` (and one `-w` if needed) returns the whole table in a single round-trip; parse it once per pass into the same kind of per-key globals `__tcz_ps_load` already uses for the pid table. This is the single biggest win.
- **17 `list-panes`.** One `list-panes -a -F '<compound format>'` returns every pane and every field in one call. §4 of my 2026-08-18 verification doc noted the per-client `ps eww` reads were the last O(N) term on the `ps` side; this is the same shape on the `tmux` side.
- **7 `display-message`.** `display-message -p` accepts a compound format string, so several value lookups collapse into one call.
- **4 `list-sessions` + 2 `list-clients`.** Almost certainly one each per pass.

A plausible target is **under 5 `tmux` calls per tick**, which would take the tick from ~0.83 s of CPU to a few tens of milliseconds and remove the re-arm behaviour entirely.

Worth noting the same snapshot-and-memoize pattern you already built for `__tcz_ps_load` applies verbatim here — this is that idea extended from `ps` to `tmux`.

## 4. Measure it the same way

The shim recipe, which works unchanged in a test:

```bash
printf '#!/bin/bash\necho "tmux $*" >> %s/tmux.log\nexec /opt/homebrew/bin/tmux "$@"\n' "$LOGDIR" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH" fish --no-config functions/tmux-categorize.fish tick '#23a353'
wc -l "$LOGDIR/tmux.log"
```

Suggested invariant, in the same spirit as the spawn-count assertion you added for `ps`: **one tick issues O(1) `tmux` client invocations, not O(panes) or O(options-read).** This one is fully testable on rocket — it is not macOS-specific in any way, which is why it is worth pinning now.

## 5. Runtime change made on macwork, and how to revert

The user's machine had been hot for two days, so I removed the tick from the **live server's** `status-right`. No file was edited; this is a runtime option on one tmux server and does not survive a config reload.

```
# before (saved verbatim)
#(/Users/tyler.hebenstreit/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh)#{T:@tmux_lives_status_right}#(fish --no-config /Users/tyler.hebenstreit/.config/fish/functions/tmux-categorize.fish tick '#23a353')

# after
#(/Users/tyler.hebenstreit/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh)#{T:@tmux_lives_status_right}
```

**I deliberately preserved the `continuum_save.sh` prefix** and guarded the edit on it being present afterward, because your own `docs/2026-07-30-handoff-status-right-and-update-environment.md` documents that dropping it silently kills tmux-continuum's autosave. Revert is the original string above, re-set with `tmux -S /private/tmp/tmux-502/default set-option -g status-right '<original>'`, or any config reload.

Session auto-naming is unaffected — that runs from the `fish_postexec` path, not the tick. What is lost meanwhile is the tick's status segment.

**Result, measured immediately after:**

| | tick in `status-right` | tick removed |
|---|---|---|
| host idle | 4.31% | **77.8%** |
| system time | 54.19% | **9.4%** |
| user time | 41.48% | 12.8% |
| load average (1 min) | 11.28 | **6.89 and falling** |
| transient shells under the tmux server | ~10/s | none |

That is also the confirming test: nothing else changed on the machine in that window.

## 6. What I did NOT touch

- No tmux-lives file modified, no commit, no push, on macwork or rocket. This doc is new and untracked.
- No change to `conf.d/tmux.fish`, `functions/tmux-categorize.fish`, `~/.config/tmux/tmux-lives.conf`, or `~/.tmux.conf`. The only change is the single live-server option in §5.
- The tick and `categorize` were each invoked once by hand under a `PATH` shim to count spawns — the same operations tmux performs on every status refresh.
- Unrelated finding on macwork, noted only so it is not mistaken for yours: an orphaned `/bin/dash -c while :; do sleep 0.2; done` (pid 18809, parented to launchd, running 21h49m, ~392,000 `sleep` spawns) is not from the user's dotfiles and not from tmux-lives. Its own CPU is 5:04 total, i.e. negligible, and it was left running.
