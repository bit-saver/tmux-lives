# Handoff → tmux-lives: a review sub-agent killed the owner's live tmux server (2026-09-29 07:08)

**From:** the monitoring session on rocket (`~/projects/monitoring`), 2026-09-29.
**Status:** diagnosed with evidence. The owner has already reconnected; this is not an outage now, it's a defect in how this project's agents test tmux.
**Nothing in this repo was edited except this file.**

## What happened

At 07:08:40 CDT, all six of the owner's ShellFish SSH sessions to rocket closed at once. Every Claude session running inside tmux died with them, including this project's own session `d755b5a7-b64b-40b6-87cc-bc2921c2c352` (`CLAUDE_PID` 350976), mid-review. Rocket itself was fine: up 2 days, sshd running since boot, 31/31 containers up.

## Root cause: `TMUX` beats `TMUX_TMPDIR`

Review sub-agent `agent-aae325b5b335d1a7d` (in that session's `subagents/`) ran this probe at 12:08:37.883Z. Excerpt:

```
D=/tmp/claude-1000/review7-tt-$RANDOM
env TMUX_TMPDIR=$D $BIN -f /dev/null new-session -d -s livelike
...
env TMUX_TMPDIR=$D $BIN kill-server
```

The agent's shell ran inside a pane of the owner's real server, so it inherited `TMUX=/tmp/tmux-1000/default,328034,…`. **When `TMUX` is set, tmux talks to that server and ignores `TMUX_TMPDIR`.** So:

- `new-session -d -s livelike` created a session on the **real** server. The script's own next line proves it: `TMUX unset: error connecting to /tmp/claude-1000/review7-tt-23140/tmux-1000/default (No such file or directory)`. The throwaway server was never created.
- `kill-server` killed the **real** server (pid 328034, 8 sessions).

## Evidence, all on rocket

| Time (CDT) | Source | Event |
|---|---|---|
| 07:08:37.883 | sub-agent transcript | the probe starts |
| 07:08:38 | `ps` | orphan server 362819 starts: `tmux new-session -d -s x` from the probe's `TMUX=fake` case, cwd `review7-tt-23140` |
| 07:08:39.314 | user journal | `utempter[362811]: [ppid=328034]` — the `livelike` pane opens on the real server |
| 07:08:40.138–.177 | user journal | 8× `utempter [ppid=328034]` — 8 panes torn down by `kill-server` |
| 07:08:40.266–.274 | user journal | 6× `sshd: Received disconnect from 10.0.30.120 … 11: Bye!` |
| 07:08:40.536 | sub-agent transcript | the probe's result returns; no further entries from that session |

The `pgrep` the agent ran 7 seconds earlier (12:08:30Z) listed the live server it then killed: `328034 tmux -u new-session -d -s __tmux_restore_holder_328025`, plus the owner's six `attach-session` clients.

## Proposed fix (yours to decide)

- **Any test or probe that starts or kills a tmux server must drop `TMUX` as well as setting the socket**: `env -u TMUX TMUX_TMPDIR=$D tmux …`, or name the socket explicitly with `tmux -S "$D/sock" …` / `-L name`. An explicit `-S`/`-L` is the most robust, because it doesn't depend on the environment at all.
- Worth a standing rule in this repo's `CLAUDE.md`, and in the prompts it gives review/implementer sub-agents: **never run `kill-server` without an explicit `-S` or `-L`.** The sub-agents run inside the owner's live tmux, so a bare `kill-server` targets his server by default.
- The existing test suites may already isolate correctly (the `neurotest-*` sockets suggest explicit sockets elsewhere). This was an ad-hoc review probe, which is exactly where isolation gets skipped.

## What I did and did not touch

- **Killed** the orphan server 362819. It had been unreachable since its socket directory was `rm -rf`'d; it's gone.
- **Did not touch** anything in this repo's code, config, tests, `~/.config/fish/conf.d/tmux.fish`, or the restore logic. Restore worked as designed: the owner's reconnect at 07:16:13 rebuilt all 8 sessions via `__tmux_restore_holder_373505`.
- The interrupted review (session `d755b5a7`, "review7" of the landing work at `8c5d6eb`) never finished. Its verdict is unknown.

## Outcome (tmux-lives session, 2026-09-29)

Accepted as diagnosed. The rule — every tmux command an agent types names its socket with `-L`/`-S`, never a bare `kill-server`, subprocesses get `env -u TMUX` plus a `-L` shim — is now in this repo's `CLAUDE.md` (Environment traps), leads the sub-agent constraints file every dispatch of the landing-session build carries, and is recorded in project memory and `~/.claude/docs/lessons.md`. The interrupted review was re-run from scratch under that rule.
