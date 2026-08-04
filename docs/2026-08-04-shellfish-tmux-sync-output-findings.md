# Cursor flicker in tmux: tmux advertises synchronized output it cannot deliver

**Date:** 2026-08-04
**Reporter environment:** Secure ShellFish (iOS) → SSH → macOS 26.x → tmux → Claude Code 2.1.221

## Summary

When Claude Code runs inside tmux 3.7b under ShellFish, the terminal cursor flickers continuously while Claude is rendering. The same Claude version in the same ShellFish tab **without** tmux is completely steady, and inside tmux 3.3a it is also completely steady.

The cause is a capability-negotiation gap. ShellFish does not implement DECSET 2026 (synchronized output). tmux 3.7b does, and when an application inside tmux asks whether the terminal supports mode 2026, **tmux answers for itself rather than for the client terminal**. Claude Code takes that "yes" at face value, begins wrapping every render frame in synchronized-output markers, and tmux flushes at each frame boundary. ShellFish, unable to buffer, paints every intermediate frame — including the cursor hide/show that Claude emits ~21 times per second. The application pays the full cost of synchronized output and receives none of its benefit.

## Evidence

The same DECRQM query for mode 2026 (`ESC [ ? 2026 $ p`), issued from the same ShellFish client in four contexts:

| Context | Reply | Interpretation | Flicker |
|---|---|---|---|
| ShellFish directly, no tmux | *(none)* | mode 2026 not supported | none |
| inside tmux 3.3a | *(none)* | not supported | none |
| inside tmux 3.6a | *(none)* | not supported | only when output adds a line |
| inside tmux 3.7b | `ESC [ ? 2026 ; 2 $ y` | **supported** (status 2 = reset) | continuous |

The contradiction is the first and last rows: the same terminal reports "not supported" on its own and "supported" through tmux 3.7b.

Claude Code's decision logic, from the 2.1.221 binary:

```js
o = n?.status === 1 || n?.status === 2;  l_d(o)      // status 2 → true
...
function une(){
  if (process.env.CLAUDE_BG_BACKEND === "daemon") return xv()?.syncOutput !== false;
  if (te.TMUX) return wIo === true;                   // inside tmux this is the ONLY input
  if (nr(process.env.CLAUDE_CODE_FORCE_SYNC_OUTPUT)) return true;
  /* … per-terminal allowlist … */
}
```

Inside tmux the DECRQM result is the sole determinant. `CLAUDE_CODE_FORCE_SYNC_OUTPUT` sits after the early return and is unreachable, and in any case only forces synchronized output *on*. There is no user-facing way to disable it inside tmux.

Supporting measurement: capturing a Claude pane's output with `tmux pipe-pane` during active rendering shows roughly 21 cursor hide/show pairs per second (`ESC[?25l` / `ESC[?25h`), and zero cursor-*style* escapes (`ESC[n q`). This is cursor visibility, not cursor style — a previously known tmux cursor-style flicker, cured by pinning `cursor-style`, is a different problem and is not involved here.

## Reproduction

1. In ShellFish, SSH to a host and confirm the terminal does not support mode 2026:
   ```
   printf '\033[?2026$p'    # no reply
   ```
2. Start tmux 3.7b, and issue the same query from inside a pane. tmux replies `ESC[?2026;2$y`.
3. Run Claude Code in that pane and give it work that streams output. The cursor flickers continuously.
4. Repeat with tmux 3.3a. The query goes unanswered and the flicker does not occur.

## Who could fix this, and how

Three changes would each resolve it independently. They are listed in the order we believe is most useful, not most blameworthy.

**1. ShellFish implements DECSET 2026.** This is the change that benefits ShellFish users most directly, and it is worth making on its own merits regardless of this bug. Synchronized output is a widely adopted standard — iTerm2, WezTerm, kitty, ghostty, foot, Alacritty, contour and others support it — and it exists precisely to eliminate the class of flicker seen here. With ShellFish supporting it, tmux's "yes" becomes true, atomicity carries end to end, and rendering improves for every full-screen TUI, not just Claude Code.

**2. tmux stops advertising a capability it cannot relay.** Arguably the clearest defect: tmux answers a capability query about *the terminal* by describing *itself*, when the whole point of mode 2026 is an end-to-end guarantee. tmux knows its client's capabilities and could answer accordingly, or decline to answer when it cannot pass synchronization through.

**3. Claude Code does not treat tmux's answer as authoritative.** It already special-cases tmux (`if (te.TMUX) return wIo === true`), so it is aware it is running under a multiplexer; it could additionally consider the client terminal, or expose a way to opt out.

To be explicit: **ShellFish is not misbehaving.** It correctly declines to claim a capability it does not have. The request here is a feature, not a bug fix — but it is the feature that would resolve this, and it would improve ShellFish's rendering of full-screen terminal applications generally.

## A second, unexplained issue

tmux 3.6a does **not** answer the mode 2026 query, so Claude Code does not enable synchronized output there — yet a milder flicker still occurs, specifically when output adds a new line (i.e. when the pane scrolls). Updates in place, such as a timer ticking on a single line, are clean.

We have no explanation for this. It is not the synchronized-output mechanism described above, since that is inactive on 3.6a. We note it because it means "downgrade tmux below 3.7" only fully resolves the problem at 3.3a, and because it may or may not share a cause with the primary issue.

## What we ruled out

Recorded so others do not repeat the work. Each of the following was measured and eliminated:

- tmux's `cursor-style` handling and the `cstyle` terminal feature (zero DECSCUSR escapes in 78 KB of captured output)
- tmux-lives, our own tmux configuration (a bare `tmux -f /dev/null` reproduces it)
- Claude Code's `tui` renderer setting (`fullscreen` vs `default`; flickers on both)
- transport (plain `sshd` on both hosts, no mosh), pane and client geometry (identical), system load, and the Linux/macOS distinction
- `terminal-overrides` stripping `civis` — mechanically suppresses cursor hiding entirely, but makes the result visibly worse, as the cursor then remains visible and moves during repaints

## Related

- anthropics/claude-code#37283 — "TUI flickers/cursor jumps in tmux during streaming output (missing DECSET 2026 synchronized output)"
- tmux/tmux#4744 — added support for application-sent synchronized output, merged 2025-12-17, twelve days after the 3.6a release. This is consistent with 3.7b answering the query and 3.6a not.
