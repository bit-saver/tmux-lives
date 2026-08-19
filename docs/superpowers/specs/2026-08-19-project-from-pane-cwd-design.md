# The project comes from where you ARE, not where the session was born

**Status: APPROVED, NOT BUILT** (2026-08-19). Reverses decisions N3 and N9 of the session-naming design (`2026-08-18-session-naming-design.md`), which shipped at `6da151f`. Everything else in that design — the two-layer name/display model, the claim precedence, `gen-N` stability, the ownership guard, the category model — is unchanged.

## Why the previous decision was wrong, measured on the user's own machine

N3 chose `#{session_path}` over `#{pane_current_path}` on the grounds that the pane path "drifts" when you `cd` while the session path is stable. That argument was never checked against how the user actually works. Their live macwork server, eight sessions, one window and one pane each:

| session | `session_path` | pane cwd | running |
|---|---|---|---|
| `gen-4` | `~` | `~/projects/watchface` | ✳ Watchface 40 |
| `watchface` | `~/projects/watchface` | `~/projects/sounds` | ✳ Sounds 1 |
| `gen-3` | `~` | `~/projects/pingy-android` | ◐ Pingy Android - Part 29 |
| `gen-1` | `~` | `~/projects/pingy-android/user` | fish |
| `myems-web-con` | `~` | `~/Work/myEMS/web` | ✳ myEMS Web |
| `myems-web-con2` | `~` | `~/Work/myEMS/web` | fish |
| `myems-api-con` | `~` | `~/Work/myEMS/api` | fish |
| `gen-2` | `~` | `~` | fish |

**`session_path` is `~` in seven of eight rows, and in the eighth it is actively misleading** — the session *named* `watchface` is the one doing Sounds work, while the session doing Watchface work is called `gen-4`. The name records where a session was born, not what it is doing.

The user's verdict, and it is the correct reading: *"why would we want to use session_path for anything? It's clearly the most unhelpful thing there could be."*

**The decisive argument is that `session_path` is never better.** When a session never moves, `session_path == pane_current_path` and the two agree. They diverge only after a `cd` — and after a `cd`, the pane path is the right answer and the session path is a stale one. So it is a strictly dominated input.

**Why it is `~` so often is our own doing:** all four session-creation sites in `conf.d/tmux.fish` pass `-c "$HOME"`. Every session tmux-lives creates, autostarts or commandeers is born in the home directory, so project-anchored naming was inert for all of them. The final whole-branch review of the naming cycle flagged this consequence; it was recorded and not acted on.

## The rules

**Project = the git root of the active pane's current path, else that path's basename.** Walk up from the pane cwd looking for a `.git` entry, stopping at `$HOME` or `/`; if one is found, use that directory's basename, otherwise use the pane cwd's own basename.

The walk exists for exactly one measured case: `gen-1` sits in `~/projects/pingy-android/user`, whose basename is the useless `user`, while its repo root gives `pingy-android`. On every other live path the two are identical, so this costs nothing and fixes the one bad name.

**It must not fork.** Use `test -d` in a loop, never `git rev-parse`. This project spent a whole cycle removing per-session subprocesses after `pgrep` on macOS routed through a root daemon and burned four cores; do not reintroduce that shape. A handful of stat calls per session per pass is acceptable, a subprocess is not.

**Generic directories are unchanged.** `$HOME`, `/`, `/tmp`, `/var/tmp` still yield no project, so a session genuinely sitting in `~` still becomes `gen-N` with no display. `gen-2` above is correctly unnamed and stays that way.

**Both layers use it.** The tmux name and the display both derive from the pane cwd. The user was explicit that `session_path` should not be used "for anything".

**The name therefore follows a `cd`, and that is not a new class of instability.** Session names in this system already track live state — starting or exiting Claude renames a session today, and has since long before this cycle. `gen-N` stability is the documented exception, not the rule. Collisions continue to be resolved by `__tcz_unique` (`proj`, `proj-2`), and hand-named sessions remain untouchable via the `@tmux_auto_name` ownership guard.

**`__tcz_session_title` falls back to the pane cwd**, restoring what it did before the naming cycle. This is what makes an unowned, hand-named session such as `myems-web-con` show its actual directory instead of `~`.

## Blast radius

- `__tcz_snapshot` — **reinstate a per-session active-pane path accumulator.** Task 3 deleted `$cpath`/`$gpath` because naming had moved to `session_path`; this change needs one back. `pane_fmt` already fetches `#{pane_current_path}` as field 4, so no format change is required. `#{session_path}` can leave `sess_fmt`, which returns that row to four fields and keeps `@tmux_lives_name` greedy-last.
- `__tcz_categorize` — its batched lookup currently reads `#{session_path}` from `list-sessions`, which cannot supply a pane path. It must instead batch over panes. **Take the active pane of the *current window***: `list-panes -a` emits one `pane_active` row per window, so the filter needs `#{?#{&&:#{pane_active},#{window_active}},…,}`. Keep it to **one** tmux call, and keep the narrowed (`fish_postexec`) path narrowed.
- `__tcz_session_title` — fall back to the pane cwd rather than `#{session_path}`. Note the measured constraint from the naming cycle: `list-panes -t <session>` without `-s` resolves to the session's *currently selected* window, which is the right pane here, and `display-message -t "=name"` returns empty for **every** format, so target with `__tcz_session_target`.
- A new pure helper for the git-root walk, so it is unit-testable without a tmux server.

## Expected outcome, projected against the live data above

`gen-4` → `watchface · Watchface 40` · `watchface` → `sounds · Sounds 1` · `gen-3` → `pingy-android · Pingy Android - Part 29` · `gen-1` → `pingy-android` · `gen-2` → unchanged `gen-2` · the three `myems-*` sessions stay hand-named with tabs showing their real directories.

Note `gen-1` and `gen-3` both resolve to project `pingy-android`. Their displays differ by the task half, so they are not duplicates. Where displays genuinely do collide, the bracketed-ordinal rule (`2026-08-19-duplicate-display-suffix-design.md`) applies.

## Testing

**Pure:** the git-root walk finds a repo root from a nested subdirectory; returns the basename when no repo is found; stops at `$HOME` and at `/` rather than escaping; a generic directory still yields nothing; a path with spaces survives.

**Integration on an isolated `-L` socket:** a session whose pane sits in a project dir is named and displayed for that project; **`cd`-ing the pane to a different project renames and re-displays it** (the assertion that encodes this whole change — it must fail against the shipped `session_path` code); a session in `$HOME` still becomes `gen-N` with no display; a hand-named session is still untouched; a claim-carrying session is still skipped.

**Cost:** assert the pass does not gain a tmux call per session and forks no subprocess for the walk. The spawn-count invariant from the sysmond work already has a harness — reuse it.

**Churn:** a pass over an unchanged server must still emit zero `set-option` calls. `cd` fires `fish_postexec`, so this path is now exercised far more often than before.

## Explicitly not doing

- Requiring a `.git` directory as a *gate*. Decision N4 rejected that and it stands: a directory with no repo still yields its basename. The walk is a root-*finder*, not a filter.
- Changing where `conf.d/tmux.fish` creates sessions. Autostart has no better directory than `$HOME` at login, and with the project coming from the pane this no longer matters.
- Any change to `gen-N` stability, the ownership guard, the claim precedence, or the category model.
