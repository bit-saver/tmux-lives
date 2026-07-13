# macOS GUI-namespace: investigation findings (why tmux-lives builds nothing)

**Investigated 2026-07-13 on the live Mac (macOS 26.5.2, Apple Silicon, tmux 3.6b) via `ssh mac`. Outcome: NO tmux-lives code change.** Supersedes the original macOS GUI-namespace handoff (filed 2026-07-12 on 26.5.1, since removed), whose recommended fix does not work on macOS 26.

## The original premise
A tmux server started from SSH/launchd sits in the wrong launchd **bootstrap domain**, so processes inside it can't reach the GUI (pasteboard, `open`, window/menu-bar placement). Recommended fix: install `reattach-to-user-namespace` and set `default-command "reattach-to-user-namespace -l fish"` on macOS, plus a `gopen`/`launchctl asuser` fallback and a TCC note in `setup verify`.

## What's actually true on macOS 26.5.2 (measured; asid = audit-session id, Aqua/GUI = 100002)
| Path | Result |
|---|---|
| `pbcopy` / `pbpaste` from a broken (SSH-rooted) shell | ✅ works both ways — Apple relaxed pasteboard access |
| GUI app via `open -a` | ✅ lands in **Aqua (100002)** — LaunchServices routes GUI launches correctly regardless of caller |
| GUI **binary run directly** (child of a tmux pane) | ❌ inherits the tmux server's non-Aqua session (~101089) |
| `reattach-to-user-namespace` wrapper | ❌ **no-op** — re-parents the Mach bootstrap subset but leaves the **audit session unchanged**; a reattach-wrapped process stayed at the shell's non-Aqua asid, never reaching Aqua |
| `launchctl asuser <uid>` from a non-Aqua session | ❌ needs **root** ("Could not switch to audit session … Operation not permitted") |

GUI window/menu-bar placement is governed by the **Aqua audit session (asid)**, not the Mach bootstrap domain that `reattach` touches — which is why `reattach` provably does not fix it on macOS 26, and why `launchctl asuser` (the audit-session mechanism) is what "worked" in the original evidence, but only from a context that already had audit-session rights (it needs root across sessions).

## Decision: tmux-lives changes nothing
- The handoff's `reattach` `default-command` would ship a **no-op that looks like a fix** — rejected.
- `pbcopy` and `open -a` already work — two of the three symptoms are moot.
- The only genuine gap (directly-launched GUI binaries inheriting the wrong session) has a trivial workaround (`open -a <App>` / `open <App>.app`). The only real fix is to **Aqua-root the tmux server via a `gui/502` LaunchAgent**, which is a disproportionate reversal of the spec-2 "macOS = runtime-only, no launchd units" design for a narrow, dev-only, workaround-able case — rejected.
- The TCC gotcha (Screen Recording / Accessibility / Automation permissions attach to the tmux binary `/opt/homebrew/bin/tmux`, not the terminal app) remains a real, useful thing to surface in `setup verify` **someday**, but it is orthogonal to this GUI-placement issue and was not built here.

## The real problem was never tmux
The app that triggered this (`pingy-mac`) runs from `/Applications/Pingy.app` in **Aqua (100002)**, launched normally by launchd/LaunchServices — it has no tmux/domain problem. Its off-screen menu-bar icon is its own `NSStatusItem`/window-frame logic (stale saved frame vs. the current multi-display layout, or menu-bar fullness). Handed off to the pingy-mac session at `~/projects/pingy-mac/HANDOFF-from-tmux-lives-gui-namespace.md`.
