# Duplicate displays get a bracketed ordinal — `Sonos [1]`, `Sonos [2]`

**Status: APPROVED, NOT BUILT** (2026-08-19). Follows directly from the session-naming cycle merged at `6da151f`. Changes only how a *display* is composed; the tmux name, the category model, the ownership guard and the picker's grouping are untouched.

## The problem

The naming cycle gave every session in a project the project's name as its display. Two sessions started in the same directory therefore render **identically** — `tmux-lives` and `tmux-lives` — while their tmux *addresses* stay distinct (`tmux-lives`, `tmux-lives-2`). The picker shows two rows a human cannot tell apart, and two terminal tabs carry the same title.

This was found by the whole-branch review of that cycle and deliberately deferred rather than fixed silently, because every candidate format invents a convention the spec never approved — and the spec had explicitly rejected hyphens in what the user reads.

## The user's decision

> "if there are duplicate names for display then they should appended with [#], i.e.: Sonos [1], Sonos [2]. The brackets will distinguish it as duplicate names rather than iteration numbers or any other numerical meaning."

Two things are settled by that and are not open: the delimiter is **square brackets**, and **every member of a duplicate set is numbered**, including the first. `Sonos` alone stays `Sonos`; the moment a second one exists both become `Sonos [1]` and `Sonos [2]`.

The reasoning is worth preserving: a bare trailing number reads as a sequence or an iteration count. Brackets read as an annotation *about* the name rather than part of it, which is exactly what the number is.

## What can and cannot collide

Worth stating, because it bounds the whole change:

- **The no-project fallback can never collide.** A session with no project falls back to its tmux *name*, which is unique by construction. So the three sessions currently sharing `$HOME` on the live host (`Sonos`, `gen-1`, `gen-2`) are not duplicates — `$HOME` is a generic directory, yields no project, and each falls back to its own distinct name.
- **A claude session with a task can rarely collide.** Its display is `project · task`; that cannot equal a bare `project`. Two claude sessions in one project with the *same* task text would collide, but the spec's whole point is that the task half distinguishes them.
- **The real case is two non-claude sessions in one project** — two shells in one repo — both showing the bare project name.

## The rules

**A duplicate set is a set of sessions whose composed displays are byte-equal**, size ≥ 2. Equality of the *display*, not of the project: `neurotto · Fix the lag` and `neurotto` are not duplicates.

**Each member gets ` [N]` appended**, N from 1, ordered by **sorted session name**. The address is already unique and stable, so deriving the ordinal from it makes the ordinal stable too — a session keeps its number across passes, which is what stops the display flapping. So `tmux-lives` → `tmux-lives [1]` and `tmux-lives-2` → `tmux-lives [2]`.

**Known cosmetic limit:** ordering is lexicographic, so ten or more duplicates in one project would order `-10` before `-2`. The numbers stay stable and distinct, which is what matters; natural-sort is not worth the complexity for a case that means ten shells in one directory.

**Suffixing happens in `__tcz_snapshot`, over the rows it emits, and only on an unnarrowed pass.** Field 5 carries the suffix, so every consumer — the picker, the menu, and the `@tmux_lives_display` option that the status bar and tab title read — inherits it from one place.

## The narrowed pass, and why it needs a guard

`__tcz_categorize` runs narrowed from `fish_postexec`, once per command. In that mode `__tcz_snapshot` emits **one** row, so it cannot see a duplicate and composes an unsuffixed display.

Left alone, that produces churn on every single command: postexec writes `tmux-lives`, the ~15s tick writes `tmux-lives [1]`, the next command writes `tmux-lives` again. Unconditional per-tick option churn on an option the status bar reads is exactly what caused the ShellFish cursor-flicker bug, so this is not cosmetic.

**Rule: on the write in `__tcz_categorize`, a stored display of the form `<computed> [N]` counts as already-correct and is not rewritten.** The tick owns suffix assignment; the narrowed pass is non-destructive. When a duplicate set drops back to one member, the tick removes the suffix within one interval.

Note what makes this safe rather than clever: the guard is *narrower* than "starts with the computed value" — it matches only a bracketed integer at the very end, so a genuinely different display (`neurotto · Fix [the] lag`) is still written normally.

## Blast radius

All in `functions/tmux-categorize.fish`.

- `__tcz_snapshot` — after all displays are composed and after the `@tmux_lives_name` claim override, group equal displays and append the ordinal. **After** the claim override on purpose: an app-set claim is a deliberate name and must not be renumbered.
- `__tcz_categorize` — the dedup comparison at the display write gains the `<computed> [N]` tolerance.
- Everything downstream is unchanged and inherits the suffix: `__tcz_overview`, `__tcz_popup_list_lines`, `__tcz_menu_args`, `@tmux_lives_display`, `__tcz_status_identity`, `__tcz_session_title`.

**The row stays exactly 5 tab-separated fields.** Four call sites split it `-m 4` with a greedy last field.

## Testing

**Pure/unit:** two sessions in one project both get numbered; a single session in a project gets **no** suffix; three sessions number 1/2/3; ordering follows sorted session name; a claude session with a task is not numbered against a bare-project sibling; a claim-carrying session is never renumbered; the no-project fallback (display = session name) never collides and never gets a suffix.

**Churn (the one that matters):** a narrowed `__tcz_categorize` pass over a session whose stored display is `X [N]` while the computed display is `X` must emit **zero** `set-option` calls. Spy on emitted tmux commands; a green suite without this assertion proves nothing, since the whole failure mode is an extra write nobody sees.

**Guard against the obvious over-correction:** the `[N]` tolerance must not swallow a real change. A stored `X [1]` when the computed display is `Y` must still be rewritten.

## Explicitly not doing

- Renumbering to close gaps when a middle member closes. Numbers are derived fresh from the surviving set each unnarrowed pass, so they renumber naturally; no compaction state is kept.
- Any change to the tmux name. `__tcz_unique`'s `-2`/`-3` address suffixes are unaffected and remain the disambiguator of record.
- Natural-sort ordering for ten or more duplicates (see above).
