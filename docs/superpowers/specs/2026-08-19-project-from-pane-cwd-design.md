# The project comes from where you ARE, and a session is born where you were

**Status: APPROVED, NOT BUILT.** Written 2026-08-19, revised 2026-08-29 to add a second half. Reverses decisions N3 and N9 of the session-naming design (`2026-08-18-session-naming-design.md`), which shipped at `6da151f`. Everything else in that design — the two-layer name/display model, the claim precedence, `gen-N` stability, the ownership guard, the category model — is unchanged.

The design now covers two independent rules that were originally treated as one topic and one non-topic:

1. **Naming reads the active pane's cwd**, never `#{session_path}`. This is the original 2026-08-19 design, unchanged below.
2. **A session is born where you were.** The 2026-08-19 revision explicitly declined to touch session creation; the user asked for it on 2026-08-28 and it is now part of this design.

Rule 2 does not rescue rule 1 and rule 1 does not make rule 2 pointless — the measurements below show why both are wanted, and why neither alone is enough.

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

**Why it is `~` so often is our own doing:** four session-creation sites in `conf.d/tmux.fish` pass `-c "$HOME"`. Every session tmux-lives creates that way is born in the home directory, so project-anchored naming was inert for all of them. The final whole-branch review of the naming cycle flagged this consequence; it was recorded and not acted on. It is acted on below, as rule 2.

## The rules — naming

**Project = the git root of the active pane's current path, else that path's basename.** Walk up from the pane cwd looking for a `.git` entry, stopping at `$HOME` or `/`; if one is found, use that directory's basename, otherwise use the pane cwd's own basename.

The walk exists for exactly one measured case: `gen-1` sits in `~/projects/pingy-android/user`, whose basename is the useless `user`, while its repo root gives `pingy-android`. On every other live path the two are identical, so this costs nothing and fixes the one bad name.

**It must not fork.** Use `test -d` in a loop, never `git rev-parse`. This project spent a whole cycle removing per-session subprocesses after `pgrep` on macOS routed through a root daemon and burned four cores; do not reintroduce that shape. A handful of stat calls per session per pass is acceptable, a subprocess is not.

**Generic directories are unchanged.** `$HOME`, `/`, `/tmp`, `/var/tmp` still yield no project, so a session genuinely sitting in `~` still becomes `gen-N` with no display. `gen-2` above is correctly unnamed and stays that way.

**Both layers use it.** The tmux name and the display both derive from the pane cwd. The user was explicit that `session_path` should not be used "for anything".

**The name therefore follows a `cd`, and that is not a new class of instability.** Session names in this system already track live state — starting or exiting Claude renames a session today, and has since long before this cycle. `gen-N` stability is the documented exception, not the rule. Collisions continue to be resolved by `__tcz_unique` (`proj`, `proj-2`), and hand-named sessions remain untouchable via the `@tmux_auto_name` ownership guard. The user confirmed this consequence explicitly on 2026-08-29, including that switching to a different *window* moves the ShellFish tab title for the same reason.

**`__tcz_session_title` falls back to the pane cwd**, restoring what it did before the naming cycle. This is what makes an unowned, hand-named session such as `myems-web-con` show its actual directory instead of `~`.

## The rules — where a session is born

Measured on rocket, 2026-08-29, comparing each pane's birth directory against its current one:

| session | `pane_start_path` | `pane_current_path` |
|---|---|---|
| `TMUX-Setup-27` | `~/workspace/tmux-lives` | same |
| `gen-1` | `~` | `~/projects/homeassistant` |
| `gen-2` | `~` | `~/workspace/neurotto` |
| `gen-3` | `~` | `~/projects/monitoring` |
| `neurotto` | `~` | `~/workspace/neurotto` |
| `tasker` | `~` | `~/workspace/tasker` |

**Five of six were born at `~` and reached their project by `cd`.** So the creation rule below fixes none of those five — they are fresh ShellFish tabs, where the creating shell genuinely is at `~`, and only the naming rule above can name them. The one session with a correct name is the one that inherited a real cwd at birth. Rule 2 is a correctness fix for the sessions you create deliberately from somewhere, not a fix for the symptom that started this cycle. Recording that plainly so nobody later reads the creation change as the headline.

**A session inherits the cwd of the shell that asked for it.** The four sites in `__tmux_lives_new` (`conf.d/tmux.fish:225`, `:233`, `:245`, `:247`) drop their `-c "$HOME"`, so `tmux-lives new` issued from a project pane is born in that project.

**`__tcz_new_general` is the exception and gains an explicit `-c "$HOME"`.** It creates the session a fresh ShellFish springboard tab is commandeered onto, and that tab has no invoking cwd worth honouring. Today it passes no `-c` at all, so the session inherits whatever the *caller* happens to have — and the caller on the `client-attached` path is a `run-shell`, which was measured on an isolated `-L` socket to execute at the **tmux server's** cwd, not the pane's. Rocket's server cwd is currently `~/workspace/tmux-lives`, an artifact of where the server was started, so under the naming rule above a commandeered tab would come up named `tmux-lives` until the user `cd`s. Pinning `$HOME` makes it deterministic and keeps `gen-N` sessions genuinely unnamed until they go somewhere.

**Autostart and the restore holder are untouched.** `conf.d/tmux.fish:180` (`exec tmux -u new-session`) already passes no `-c` and so already inherits, which is the rule; at login that cwd is `$HOME` anyway. The `__tmux_restore` holder at `:122` is a throwaway session killed once real sessions exist.

## Blast radius

- `__tcz_snapshot` — **reinstate a per-session active-pane path accumulator.** Task 3 of the naming cycle deleted `$cpath`/`$gpath` because naming had moved to `session_path`; this change needs one back. `pane_fmt` already fetches `#{pane_current_path}`, so no format change is required. `#{session_path}` can leave `sess_fmt`, which returns that row to four fields and keeps `@tmux_lives_name` greedy-last.
- `__tcz_categorize` — its batched lookup currently reads `#{session_path}` from `list-sessions`, which cannot supply a pane path. It must instead batch over panes. **Take the active pane of the *current window***: `list-panes -a` emits one `pane_active` row per window, so the filter needs `#{?#{&&:#{pane_active},#{window_active}},…,}`. Keep it to **one** tmux call, and keep the narrowed (`fish_postexec`) path narrowed.
- `__tcz_session_title` — fall back to the pane cwd rather than `#{session_path}`. Note the measured constraint from the naming cycle: `list-panes -t <session>` without `-s` resolves to the session's *currently selected* window, which is the right pane here, and `display-message -t "=name"` returns empty for **every** format, so target with `__tcz_session_target`.
- A new pure helper for the git-root walk, so it is unit-testable without a tmux server.
- `conf.d/tmux.fish` — remove `-c "$HOME"` at `:225`, `:233`, `:245`, `:247`.
- `__tcz_new_general` (`functions/tmux-categorize.fish:1135`) — add `-c "$HOME"`.

## Expected outcome

Against the macwork data above: `gen-4` → `watchface · Watchface 40` · `watchface` → `sounds · Sounds 1` · `gen-3` → `pingy-android · Pingy Android - Part 29` · `gen-1` → `pingy-android` · `gen-2` → unchanged `gen-2` · the three `myems-*` sessions stay hand-named with tabs showing their real directories.

Against the rocket data: `gen-1` → `homeassistant`, `gen-2` → `neurotto`, `gen-3` → `monitoring`. Note `gen-2` and the hand-named `neurotto` session then share a project. Their displays differ by the task half only if both run Claude; where displays genuinely collide, the bracketed-ordinal rule (`2026-08-19-duplicate-display-suffix-design.md`) applies, and the hand-named session is protected by the ownership guard regardless.

Note `gen-1` and `gen-3` on macwork both resolve to project `pingy-android`. Their displays differ by the task half, so they are not duplicates.

A session created from this repo's own pane is now named `tmux-lives`, and a second one `tmux-lives-2` via `__tcz_unique`. That is the intended behaviour of rule 2, not a collision to design around.

## Testing

**Pure:** the git-root walk finds a repo root from a nested subdirectory; returns the basename when no repo is found; stops at `$HOME` and at `/` rather than escaping; a generic directory still yields nothing; a path with spaces survives.

**Integration on an isolated `-L` socket:** a session whose pane sits in a project dir is named and displayed for that project; **`cd`-ing the pane to a different project renames and re-displays it** (the assertion that encodes the naming half — it must fail against the shipped `session_path` code); a session in `$HOME` still becomes `gen-N` with no display; a hand-named session is still untouched; a claim-carrying session is still skipped.

**Creation, behavioural — not a grep for the flag.** A source grep proves the argument list changed, not that a session lands anywhere; both assertions below must be shown to fail against the pre-fix code:
- `__tcz_new_general` invoked with the caller's cwd set to something other than `$HOME` produces a session whose `pane_start_path` is `$HOME`. Pre-fix this yields the caller's cwd, so the assertion discriminates.
- The in-tmux `tmux-lives new` path, invoked from a temporary project directory, produces a session whose `pane_start_path` is that directory. Pre-fix it is `$HOME`.

The `exec`-ing outside-tmux branches (`:245`, `:247`) replace the process and cannot be driven the same way; assert their argument construction instead and say so, rather than pretending the coverage is equivalent.

**Cost:** assert the pass does not gain a tmux call per session and forks no subprocess for the walk. The spawn-count invariant from the sysmond work already has a harness — reuse it.

**Churn:** a pass over an unchanged server must still emit zero `set-option` calls. `cd` fires `fish_postexec`, so this path is now exercised far more often than before.

## Implementation note

A substantially complete build of the naming half sits on `feat/project-from-pane-cwd` at `41daabc` (+404/−109 across four files): `__tcz_git_root`, `__tcz_project_name` rewired to the pane path, a `__tcz_tmux_activepath` memo populated as a side effect of the pane walk `__tcz_snapshot` already performs, and `__tcz_session_title`/`__tcz_claim` following. Three suites passed; **the full nine-suite gate was never run on it**, so it is unverified rather than done. Resume it rather than restarting, and gate it before trusting any of it.

## Explicitly not doing

- Requiring a `.git` directory as a *gate*. Decision N4 rejected that and it stands: a directory with no repo still yields its basename. The walk is a root-*finder*, not a filter.
- Remembering the last directory across tabs, so that a brand-new ShellFish tab is born in the project you were last in. Offered on 2026-08-29 and declined: it is genuinely new persistent state, and it would stop a new tab landing at home.
- Changing autostart's directory, or the restore holder's.
- Any change to `gen-N` stability, the ownership guard, the claim precedence, or the category model.
