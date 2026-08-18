# Verification → tmux-lives: the pgrep/sysmond fix, measured on a Mac

**From:** the same macwork session that filed `docs/2026-08-17-handoff-pgrep-sysmond-macos.md`, 2026-08-18. **Not touched by me** — no tmux-lives file was read-modified, no commit, no push, and no running tmux server option changed. This document is new; your committed copy of the original handoff is untouched (verified byte-identical to what I sent).

This closes the open item you recorded at the end of the CLAUDE.md entry for `0e3bc1c` + `8501879` + `6e26023`:

> ⚠️ **STILL UNVERIFIED ON A MAC** — both macOS-only findings were invisible to the Linux gate; one pass on macwork with a claude pane attached settles them in seconds.

**One of the two macOS-only findings does not reproduce.** Details in §3. Everything else verifies clean.

**Baseline:** the vendored copies on macwork are byte-identical to your current `main` HEAD, so this measures the shipped code:

```
53d5b0cdab873b074ba1c3b728d95fcd9537c12fcf68d75d814f405e2c7c08ce  functions/tmux-categorize.fish   (repo HEAD + macwork)
d3e8e9aa9899e64404ba45c98f76a42c7f63c8f73d5ef90515e51e3dcc37a425  conf.d/tmux.fish                 (repo HEAD + macwork)
```

Host: macOS 26.5.2 (25F84), Apple M4 Pro 14 cores (10P+4E), 48 GB, tmux 3.7b, fish 4.8.1. Live server: 9 sessions, 10 attached clients, 4 of them claude panes.

---

## 1. The storm is gone

Same counting-shim harness as the original handoff, same machine, same server:

| Measurement | Before (`cb67e06`) | After (`6e26023`) |
|---|---|---|
| `tick` — `pgrep` spawns | 11 | **0** |
| `tick` — `ps` spawns | 46 | **12** |
| `tick` — total spawns | 57 | **12** |
| `tick` — wall time | 1.280 s | **0.941 s** |
| `categorize` — spawns | — | **2** (0 `pgrep`, 2 `ps`) |
| `sysmond` CPU | 330–449% sustained | **0.0%, four consecutive 5 s samples** |
| distinct `pgrep` pids per 400-sample loop | 1,897 active / 264 idle | **0** |

`pgrep` is absent from the process table entirely under live load — not reduced, absent. The `categorize` pass at 2 spawns is exactly the snapshot pair, confirming `__tcz_ps_load` memoizes as designed across both consumers.

The 12 spawns left in a `tick` break down as **2 snapshot calls + 10 × `ps eww -p <client_pid>`** — one environ read per attached client. See §4.

## 2. The macOS branch is correct

Exercised against live claude panes on the real server, calling the functions directly:

```
__tcz_pid_children(40438)  = 85516          # pane shell -> its claude child, no pgrep
__tcz_pid_comm(62483)      = claude
__tcz_cmdline_name(3680)   = Watchface 40   # -> live session name "Watchface-40"
```

The macOS shape you documented is present and handled: `pane_current_command` reports the version-named binary (`2.1.234`), `pane_pid` is the fish pane shell, and the real claude process is its child.

One apparent failure checked and cleared: `__tcz_cmdline_name(40438)` returns empty, but correctly — that pane's claude is `claude -c --enable-auto-mode`, with no `--name` to find.

## 3. ⚠️ The `-ww` premise does not reproduce on macOS 26.5.2

Your note records `-ww` as **"LOAD-BEARING AND I SHIPPED IT MISSING (review-caught)"**, on the mechanism that BSD `ps` sets termwidth 79 whenever no `ioctl(TIOCGWINSZ)` succeeds and truncates the last column — with the claude path at 65 chars against a 67-column budget, "two of margin", after which every `comm` check is "false, silently and totally".

Tested under exactly that condition — no tty on any standard stream, and `COLUMNS` stripped from the environment:

```
$ tty
not a tty
$ [ -t 1 ] && echo YES || echo NO
NO

$ env -u COLUMNS ps -A     -o pid=,args= < /dev/null | awk '$1==1764 {print length($0)}'
4869
$ env -u COLUMNS ps -A -ww -o pid=,args= < /dev/null | awk '$1==1764 {print length($0)}'
4869

$ env -u COLUMNS ps -A     -o pid=,ppid=,comm= < /dev/null | awk '{if(length($0)>m)m=length($0)} END{print m}'
279
$ env -u COLUMNS ps -A -ww -o pid=,ppid=,comm= < /dev/null | awk '{if(length($0)>m)m=length($0)} END{print m}'
279
```

**No truncation, with or without `-ww`** — a 4,869-character args line and a 279-character comm line both survive intact. The silent-failure scenario is not reachable on this OS version.

Two supporting corrections to the same passage:

- **The claude paths on macwork are 61 characters, not 65** (`/Users/tyler.hebenstreit/.local/share/claude/versions/2.1.234`), so the stated margin was understated even on the premise's own terms.
- **The claude process's `comm` is the bare string `claude`, not a full executable path.** The `ps` line for it is 18 characters total. So the `path basename` logic is not exercised by the case it was written for. It is still needed in general — the longest `comm` line on this host is 279 chars, so plenty of *other* processes do report full paths.

**Recommendation: keep `-ww`.** It is harmless, it is defensive, and it is correct on any system that does truncate — dropping it would be a regression on principle. But the CLAUDE.md entry currently records as established fact a silent-total-failure mode that this host cannot produce, and a margin figure that is wrong for this host. That is worth softening to "defensive against BSD `ps` truncation, not observed on macOS 26.5.2", so a future reader does not treat it as a confirmed near-miss. Whether some earlier macOS truncates this way I have no way to test from here.

## 4. The one O(N) term left, and a concrete way to close it

A `tick` still issues **one `ps eww -p <pid>` per attached client** (10 here) for the `LC_TERMINAL` read in `__tcz_client_terminal`. That is O(attached clients) rather than the old O(panes × children), so it is no longer a scaling hazard — but it is 10 of the 12 remaining spawns.

You explicitly and correctly declined to fold environ into the shared snapshot, since `ps -Aeww` would carry every process's entire environment. **Two narrower options avoid that objection:**

1. **Batch only the client pids.** `ps eww -p 1,2,3` accepts a pid list, so all 10 reads collapse into a single spawn — one process's-worth of environment per client, never the whole machine. Takes a tick from 12 spawns to 3. Parsing is by leading pid, the same shape you already handle.
2. **Memoize across passes, not just within one.** `LC_TERMINAL` is fixed for the lifetime of a client pid — it cannot change without the client reconnecting. Keying the memo on client pid and invalidating on a changed client list takes this to ~0 spawns in the steady state, since the client set is stable for hours.

They compose: batch on a cold cache, then serve warm.

## 5. Running your suite natively on macOS — your call, with a caveat

Your new tests (+290 lines) reach the fallback branch through the `tcz_force_ps` seam on Linux, which is the right design and is why this was catchable without a Mac. Running the same suite *natively* on macwork would additionally cover the genuine no-`/proc` gate and the real `ps` output shapes.

I did not run it, deliberately. `tests/test-tmux-categorize.fish` drives integration cases through a `$shimdir/tmux` PATH shim onto an isolated socket, and `__tcz_categorize` renames sessions. macwork currently has 9 live sessions with real work in them, including several attached claude panes. If the shim fails to propagate into any subprocess on macOS the way it does on Linux, a pass would rename the user's live sessions. That is recoverable but disruptive, and it is not my call to make on your test harness. If you want it run, say so and I will — ideally after you confirm the shim's propagation assumption holds for `fish --no-config` subprocesses on macOS, or with a guard that refuses to run against a server holding unowned sessions.

## 6. What I did NOT touch

- **No tmux-lives file was modified, on macwork or on rocket.** No commit, no push, no `git add`. This doc is new and untracked; your committed `docs/2026-08-17-handoff-pgrep-sysmond-macos.md` is byte-identical to what I originally sent (`c82dddce…`) and I left it that way rather than appending to a file you had already committed.
- **No running tmux server option was changed.** I never applied the `status-right` mitigation that was on the table before your fix landed — it was never needed.
- Function calls in §2 were made by sourcing the installed copy in a throwaway `fish --no-config`, and `tick`/`categorize` were each invoked once under a `PATH` shim to count spawns — the same operations tmux performs on every status refresh.
- **Outside your repo, for completeness:** the same anti-pattern existed in one of the user's own fish functions (`restart-app.fish` spin-polled `pgrep -xq` at 5 Hz while waiting for an app to quit). That is user-owned, not yours, and I fixed it there — noted only so you know the hazard class was swept beyond tmux-lives. The user's `itheme.fish` has a single one-shot `pgrep` that is genuinely negligible and was left alone.
