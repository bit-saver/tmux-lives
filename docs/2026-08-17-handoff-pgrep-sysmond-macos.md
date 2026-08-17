# Handoff → tmux-lives: the macOS `pgrep` fallback in `__tcz_pid_children` pegs ~4 cores via `sysmond`

**From:** a session on **macwork** (Tyler's M4 Pro), 2026-08-17. **Not touched by me** — I made no change to `functions/tmux-categorize.fish`, `conf.d/tmux.fish`, `conf.d/tmux-lives-install.fish`, `~/.config/tmux/tmux-lives.conf`, `~/.tmux.conf`, or any running tmux server's options. Diagnosis, measurement, and a proposed fix shape only. The fix belongs here because the macwork copies are vendored installs of this repo and would be overwritten by an update.

Found while investigating "why is my fan at 63% and why is `sysmond` dominating CPU" on macwork. The user routed it here rather than letting me patch the installed copy.

**Baseline:** the installed files on macwork are **byte-identical to this repo's `main` HEAD (`cb67e06`)**, so every line number below maps 1:1 onto your tree.

```
4b66d71d93e0e78c05a7bdf6a162d4efb492eac66a7a4dbb0e7beab1cfebc444  functions/tmux-categorize.fish   (repo)
4b66d71d93e0e78c05a7bdf6a162d4efb492eac66a7a4dbb0e7beab1cfebc444  ~/.config/fish/functions/tmux-categorize.fish   (macwork)
9c2e00fcc60335e88cce88139cbb070519ac8ec1f6b4c24548c96ee2f36d691d  conf.d/tmux.fish   (repo)
9c2e00fcc60335e88cce88139cbb070519ac8ec1f6b4c24548c96ee2f36d691d  ~/.config/fish/conf.d/tmux.fish   (macwork)
```

---

## Defect — on macOS, `__tcz_pid_children` routes every call through a root daemon that enumerates the whole machine

**Severity: high.** Sustained **~4 of 14 cores** consumed by `/usr/libexec/sysmond`, machine at **0.4% idle**, fan at 63%, on a desktop doing no heavy work. macOS only; Linux hosts are unaffected. The cost is invisible in tmux-lives' own accounting because it is billed to a root daemon in a different process.

### Root cause

`functions/tmux-categorize.fish:94-111`:

```fish
function __tcz_pid_children --description 'pid -> direct child pids (portable: /proc on Linux, pgrep elsewhere)'
    set -l pid $argv[1]
    test -n "$pid"; or return
    # `pgrep -P` walks every entry in /proc on each call, so it costs whatever the
    # host's process count costs — measured at ~140 ms on a 400-process Docker host
    # versus ~2 ms for this read. The tick called it 10x, which was 77% of a 1.9 s
    # tick and kept ~2 cores busy. [...]
    if test -d /proc/$pid/task; and not set -q tcz_force_ps
        for f in /proc/$pid/task/*/children
            string split -n ' ' <$f 2>/dev/null
        end
    else
        pgrep -P $pid 2>/dev/null       # ← macOS ALWAYS lands here
    end
end
```

The comment at `:97-100` already documents this exact pathology and its magnitude ("kept ~2 cores busy"), but the mitigation was only ever implemented for `/proc`. **macOS has no `/proc`, so every call on macOS takes the `else` branch — the branch the comment describes as the known-bad one.**

**And on macOS it is strictly worse than the Linux case that comment measured**, for a non-obvious reason:

```
$ otool -L /usr/bin/pgrep | grep -i sysmon
	/usr/lib/libsysmon.dylib (compatibility version 1.0.0, current version 1.0.0)

$ otool -L /bin/ps | grep -c libsysmon
0
```

`/usr/bin/pgrep` (and `pkill`) delegate process enumeration to **`/usr/libexec/sysmond`**, a root daemon that walks every process *and every thread* on the host per request. `/bin/ps` does not — it is clean. So on macOS the intuition inverts: **`pgrep` is the expensive primitive and `ps` is the cheap one.** On Linux `pgrep` scans `/proc` in-process and never involves a daemon, which is why this never showed up on rocket.

Two consequences worth knowing:

1. **The cost is externalized.** One `tick` reports only 0.23 s user + 0.25 s system of its own CPU, but takes **1.280 s wall**. The missing time is `sysmond` doing the enumeration on the tick's behalf, on a different process's ledger. Anything that profiles tmux-lives from the inside will under-report this by roughly an order of magnitude.
2. **It is self-amplifying.** `sysmond`'s per-call cost scales with the host's process/thread census. Each pass spawns 57 short-lived processes, which raises the census, which makes the next `pgrep` more expensive.

### Evidence (macwork, 2026-08-17, 10:20–10:55 CDT)

Environment:

```
macOS 26.5.2 (25F84) · Apple M4 Pro, 14 cores (10P + 4E) · 48 GB
tmux 3.7b · fish 4.8.1
tmux server /private/tmp/tmux-502/default: 9 sessions, 9 panes, 10 ATTACHED CLIENTS
host census at time of measurement: 1,287 processes / 8,930 threads
```

**`sysmond` load** — five consecutive 5 s samples, with no `pgrep`/`pkill` of my own running (I verified my own diagnostics were not contaminating the reading):

```
$ top -l 5 -s 5 -pid 439 -stats pid,cpu,time,th
439  393.8  09:23:42  12/1
439  449.0  09:24:05  12/4
439  447.7  09:24:28  12/5
439  385.0  09:24:48  12/3
```

Mostly *system* time across 12–13 worker threads, i.e. kernel process/thread enumeration. Cumulative `sysmond` CPU reached 11h08m.

**Cost of one `tick`** — measured by putting counting shims for `pgrep` and `ps` first on `PATH` and invoking the same command your `status-right` runs:

```
$ time PATH="$SHIM:$PATH" fish --no-config \
    ~/.config/fish/functions/tmux-categorize.fish tick '#23a353'
0.23s user 0.25s system 37% cpu 1.280 total

pgrep invocations in one tick: 11
ps    invocations in one tick: 46
                               --
total subprocess spawns:       57

$ sort pgrep.log | uniq -c | sort -rn | head -4
   3 pgrep -P 76739
   3 pgrep -P 3680
   3 pgrep -P 10034
   2 pgrep -P 26615
```

Note the repeats: the same pane pid is walked 2–3 times within a single tick, because `__tcz_cmdline_name` (`:241`) and the claude-detection loop (`:269`) each call `__tcz_pid_children` independently on the same pid.

**Aggregate rate in the wild** — sampling `ps -Ao pid=,ppid=,comm=` in a tight loop for roughly 10 seconds and counting distinct `pgrep`/`pkill` pids:

```
distinct pgrep/pkill PIDs seen: 1897        # ≈ 190 pgrep spawns/second
--- their parents (each a short-lived `fish --no-config` doing one pass) ---
  14 spawns  ppid=66939
  14 spawns  ppid=60686
  13 spawns  ppid=65414
  13 spawns  ppid=65319
  13 spawns  ppid=65111
```

**Ruled out** (so you don't re-tread this): quitting Activity Monitor changed nothing — `sysmond` held 385–449% afterward. `systemstats` had 13.99 s of CPU across a 52 h uptime. iStat Menus, CleanMyMac's HealthMonitor, and Macs Fan Control's privileged helper contain no `libsysmon` reference at all (iStat gets power data from a persistent `powermetrics -i 2000` child of its own root daemon instead). `sysdiagnosed`/`spindump`/`tailspind`/`ReportCrash` were all ≤ 37 s cumulative. A sweep of every *running* executable found exactly three `libsysmon` clients — Activity Monitor, `systemstats`, `sysmond` — which is precisely why this took a while: **the real clients are thousands of ~5 ms `pgrep` processes that no sweep of running binaries can ever see.**

### Why the rate is ~26× what `status-interval` implies

`status-interval` is **not** the dominant term. Three triggers stack:

1. **`status-right` renders per client, not per server.** The tick lives in `status-right` (rendered by `__tmux_lives_render_fragment` in `conf.d/tmux-lives-install.fish`), and tmux evaluates `status-right` once **per attached client**. macwork has **10 clients attached to one server**. At `status-interval 15` that is only ~0.67 ticks/s ≈ 7.3 pgrep/s — an order of magnitude below what was measured.
2. **`fish_postexec` runs a full pass after every command in every shell.** `conf.d/tmux.fish:262`:
   ```fish
   function __tmux_categorize_on_postexec --on-event fish_postexec
       set -q TMUX; or return 0
       fish --no-config $tmux_categorize_script categorize >/dev/null 2>&1 &
       disown
   end
   ```
   Backgrounded and disowned, so passes overlap and pile up rather than serialize. `__tcz_claim` at `:258` spawns a second `fish --no-config … claim` per command on top of that. On a machine with many active panes (5 Claude Code sessions, node dev servers, 31 fish shells) this is the main driver.
3. **tmux redraws the status bar on events**, not only on the interval — pane output, focus changes, session renames.

This is consistent with the arithmetic: ~190 pgrep/s ÷ 11 pgrep per pass ≈ **17 passes/second**, which the 15 s interval cannot explain but per-command hooks across ~10 active panes can.

---

## Proposed fix

**Primary — one cached `ps` snapshot per pass, feeding all three pid helpers.**

Three helpers share the same shape ("`/proc` fast path, else one subprocess **per pid**"):

| Helper | Line | non-Linux fallback |
|---|---|---|
| `__tcz_pid_comm` | `:57` | `ps -o comm= -p $pid` |
| `__tcz_pid_cmdline` | `:70` | `ps -o args= -p $pid` |
| `__tcz_pid_children` | `:94` | `pgrep -P $pid` |

A single `ps -Ao pid=,ppid=,comm=,args=` answers **all three, for all pids, in one spawn**. That takes a tick from 57 spawns to 1, and removes `sysmond` from the path entirely because `ps` is `libsysmon`-clean.

Design notes for whoever picks this up:

- **Cache lifetime should be one pass**, not process lifetime — set a global on entry to `tick`/`categorize` and clear it on exit. The `fish --no-config` invocations are already one-shot, but `__tcz_pid_children` is also reachable from long-lived interactive shells via the `conf.d` hooks, and those must not serve a stale table.
- The PID-recycling tolerance already documented at `:239` ("*worst case is a harmless miss*") still holds, and arguably improves: a single atomic snapshot is *more* internally consistent than N separate `pgrep`/`ps` calls taken milliseconds apart.
- Parsing `args=` needs care since it contains spaces — keep it the last column and split on first-N fields, or take two snapshots (`pid,ppid,comm` and `pid,args`) if that reads cleaner. Two spawns is still 28× better than 57.
- Dedupe the repeated walk of the same pane pid within one tick (`:241` and `:269`) — the snapshot makes this free, but the redundant calls are worth removing for clarity.

**Secondary — the `fish_postexec` full-categorize is the dominant trigger and deserves its own decision.** Even at 1 spawn per pass, firing a *full* `categorize` after every command in every shell is a lot of work for a status bar. Options: debounce (skip if a pass ran within the last N seconds), or narrow the postexec path to the current pane instead of a whole-server recategorize. This is independent of the primary fix and would have prevented the blast radius even with the current `pgrep` implementation.

**Considered and rejected:** batching `pgrep` (it has no multi-parent form — `-P` takes one ppid). `tcz_force_ps` is not a mitigation lever; it forces the *slow* path, which is the opposite of what the name suggests to a reader coming from macOS.

---

## Testing — this macOS-only defect is testable on rocket

`tests/test-tmux-categorize.fish` already flips the seam to exercise the non-Linux branch on Linux:

```fish
tests/test-tmux-categorize.fish:694:  set -g tcz_force_ps 1
tests/test-tmux-categorize.fish:697:  set -e tcz_force_ps
```

So no Mac is needed to write a regression test. Suggested invariant:

> With `tcz_force_ps` set, one `tick` (and one `categorize`) pass spawns **O(1)** subprocesses, independent of pane count and process-tree depth — not O(panes × children).

**Assert on spawn count, not CPU or wall time.** On Linux `pgrep` scans `/proc` and never touches `sysmond`, so the CPU symptom is unreproducible there; the spawn count is the portable invariant that actually encodes the bug. The counting-shim recipe I used, which works unchanged in a test:

```bash
mkdir -p "$SHIM"
printf '#!/bin/bash\necho "pgrep $*" >> %s/pgrep.log\nexec /usr/bin/pgrep "$@"\n' "$LOGDIR" > "$SHIM/pgrep"
printf '#!/bin/bash\necho "ps $*" >> %s/ps.log\nexec /bin/ps "$@"\n' "$LOGDIR" > "$SHIM/ps"
chmod +x "$SHIM/pgrep" "$SHIM/ps"
PATH="$SHIM:$PATH" fish --no-config functions/tmux-categorize.fish tick '#23a353'
wc -l "$LOGDIR/pgrep.log" "$LOGDIR/ps.log"
```

A tighter test could stub `pgrep`/`ps` entirely and assert the exact call count, since a pure `ps`-snapshot implementation should call each at most once or twice per pass.

---

## Reproduce on a Mac

```bash
# 1. confirm the fallback branch is the one macOS takes
test -d /proc && echo "has /proc" || echo "no /proc → else branch always"

# 2. confirm pgrep is a sysmond client and ps is not
otool -L /usr/bin/pgrep | grep libsysmon
otool -L /bin/ps        | grep -c libsysmon    # → 0

# 3. count spawns for one tick (shims above)
PATH="$SHIM:$PATH" fish --no-config ~/.config/fish/functions/tmux-categorize.fish tick '#23a353'

# 4. watch the daemon while tmux clients are attached and commands are being run
top -l 5 -s 5 -pid "$(pgrep -x sysmond)" -stats pid,cpu,time,th

# 5. count pgrep spawns system-wide over ~10s
for i in $(seq 1 400); do ps -Ao pid=,ppid=,comm=; done \
  | awk '{n=$3; sub(/.*\//,"",n); if (n ~ /^\(?pgrep/) print $1" "$2}' | sort -u | wc -l
```

Amplifiers to reproduce faithfully: **several attached clients on one server** (10 here), and **active fish panes running commands** (the `fish_postexec` path). A single client sitting idle will look nearly fine.

---

## What I did NOT touch

- **No tmux-lives file was modified**, on macwork or on rocket. `functions/tmux-categorize.fish`, `conf.d/tmux.fish`, `conf.d/tmux-lives-install.fish`, `~/.config/tmux/tmux-lives.conf`, and `~/.tmux.conf` are all untouched.
- **No running tmux server's options were changed.** `status-right` still contains the tick on macwork; the storm is still live as of this writing. I offered the user a reversible mitigation (drop the tick segment from the live server) and they chose to route the fix here instead.
- I ran `tick` **exactly once**, under a `PATH` shim, to count its subprocess spawns — the same operation tmux performs on every status refresh.
- **This document is untracked** in your working tree. I did not `git add`, commit, or push.
- **Unrelated but relevant to any before/after numbers taken on macwork:** during the same investigation I killed Nextcloud's `FileProviderExt` (pid 2934), which had burned 49 hours of CPU in a 52-hour uptime stuck in a Realm write/commit loop. It relaunched clean at 0.37% of a core. That changed the machine's baseline mid-investigation, so treat any macwork measurement timestamped before ~10:45 CDT as including an extra fully-consumed core from an unrelated process. All `sysmond` figures above are unaffected — they were taken both before and after that kill with no change.

---

## Addendum — a controlled A/B that isolates the `fish_postexec` trigger

Later the same day the user left the machine for ~2 hours. **The 10 clients stayed attached the whole time**, so command activity in fish panes was the only variable that changed. Same measurement loop, same server, same host:

| Metric | Active (10:20–10:55) | Away (13:00) |
|---|---|---|
| `sysmond` CPU | 330–449% sustained | 0% at rest, bursting to 180.5% |
| distinct `pgrep` spawns per ~10 s loop | 1,897 | **264** (−86%) |
| attached clients | 10 | 10 (unchanged) |
| host idle | 0.4–2.65% | 83.2% |
| load average | 22–30 | 13.8 |
| processes / threads | 1,287 / 8,930 | 1,173 / 8,593 |

Consecutive 5 s samples while idle: `0.0, 15.3, 180.5, 0.0` — a **bursty** profile, consistent with ~10 clients' status ticks landing together on a timer, versus the flat 330–449% saturation seen under command activity.

**This is the cleanest evidence in this document for the fix priority.** Holding client count constant and removing only per-command activity cut `pgrep` spawns by 86%. The `fish_postexec` full-categorize (`conf.d/tmux.fish:262`) is therefore the dominant term, and the `status-right` tick is the floor — which means the secondary fix (debounce or narrow the postexec path) is worth doing *even if* the primary `ps`-snapshot fix lands, and vice versa: they address different halves.

**Two caveats against reading the idle number as "fine":**

1. **The floor is not free.** `sysmond` cumulative CPU went 668:30 → 726:49 across the quiet window, i.e. **~58 minutes of CPU in ~115 minutes of wall time, averaging ~50% of one core with the user absent and nothing running.**
2. **The floor is still above what `status-interval` predicts.** 264 spawns per ~10 s ≈ 26 `pgrep`/s ÷ 11 per tick ≈ **2.4 ticks/second**, against the ~0.67/s that `status-interval 15` across 10 clients implies — roughly 3.5× over. That gap is event-driven status redraws (pane output, focus changes, renames), so any fix that reasons only about `status-interval` will under-predict the remaining load.
