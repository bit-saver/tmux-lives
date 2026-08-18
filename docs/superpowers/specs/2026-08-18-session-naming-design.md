# Session naming — project-anchored names, a display layer, and no more process names

**Status: APPROVED, NOT BUILT** (2026-08-18). Design agreed in chat; implementation plan not yet written. Supersedes nothing — it changes the naming rules inside `__tcz_categorize` and adds one tmux option; the ownership guard, the category model, and the picker's grouping are untouched.

## The problem, in the user's words

Four distinct complaints, raised together on 2026-08-17:

1. **"I hate the hyphenation. Some have hyphens and some don't; it's weird."**
2. **"The most useful identification for me between TL sessions is the project name"** — derived from the directory basename where the session was started, because "I always start claude from a directory that's tied to the project as a means of organization and identification."
3. **"Running process isn't really helpful either. When I run Neurotto's CLI it gets displayed as `node`."**
4. **"If I actually name a session, I think that name should stick and not get replaced by any activities within the session (except for claude code sessions)."**

They also offered a compromise they expected to be necessary — "I'm willing to forego session names entirely, if that's going to be an issue" — which turned out not to be needed. See below.

## What was already true, measured rather than assumed

Four facts were established before designing, and three of them changed the design:

- **Hand-named sessions ALREADY stick.** Verified on an isolated socket: a session auto-named `sleep`, hand-renamed to `My Project`, survives a categorize pass untouched, because `__tcz_owned` returns false for any session whose name does not match its own `@tmux_auto_name` stamp. **Complaint 4 is therefore not a missing feature.** Either the user hit a path that re-stamps, or what got replaced was a claude session — which is the exception they themselves carved out. Worth confirming with them if it recurs, but nothing here needs to change to satisfy it.
- **tmux session names CAN contain spaces**, and `-t "=Hello World"` targets correctly (verified). So the hyphenation is not forced by tmux — `__tcz_slugify` collapses every run of non-alphanumerics to a dash by choice.
- **`#{session_path}` is stable; `#{pane_current_path}` is not.** Measured with a real shell: after `cd subdir`, `session_path` still reports the session's creation directory while `pane_current_path` follows. The current code derives names from the pane path, which is why a name can drift when the user moves around.
- **Nothing in tmux-lives SETS `@tmux_lives_name`.** It is read in four places and written in none — it is purely an external claim, set by apps such as neurotto. Critically, `__tcz_categorize` treats any session carrying it as claimed and skips it entirely. **This is the constraint that shapes the design**: had the categorizer started writing that option for auto-derived names, every session would have looked claimed and all renaming would have frozen — silently.

## The model

Three layers with a strict precedence, rather than one overloaded name.

| layer | source | written by | example |
|---|---|---|---|
| **claim** | `@tmux_lives_name` | the user, or an app (neurotto) | `Neurotto CLI` |
| **display** | `@tmux_lives_display` — NEW | the categorizer | `neurotto · Fix the picker lag` |
| **tmux name** | the session name itself | the categorizer | `neurotto` |

**What any surface shows = claim, else display, else the tmux name.** The claim keeps winning and keeps suppressing auto-renaming, exactly as today; nothing about neurotto's integration changes.

The split exists because the two names have genuinely different jobs. The tmux name is an *address* — it flows into `-t` targets, `rename-session`, `switch-client`, `capture-pane`, and this repo has been bitten by both a quote in a session name enabling command injection through the display-menu layer and by purely numeric names mis-resolving. The display is *prose* — it only ever gets printed. Keeping arbitrary user- and task-derived text out of the address is the whole point.

## The rules

**Project = `basename(#{session_path})`** — the directory the session was STARTED in.

**"No project"** means `session_path` is `$HOME`, `/`, or `/tmp`. Everything else counts as a project. An empty or unreadable `session_path` is treated as no project, so the fallback is `gen-N` rather than an empty name.

| session | tmux name | display |
|---|---|---|
| claude, started in `~/projects/neurotto` | `neurotto` | `neurotto · Fix the picker lag` |
| node server, started in `~/projects/neuro` | `neuro` | `neuro` |
| any session started in `~` or `/tmp` | `gen-1` | none |
| hand-named by the user | untouched | untouched |
| carrying an app claim | untouched | untouched |

**The running process name is never used again.** The `claude` / `running` / `general` categories still drive the picker's grouping and colours, and still drive whether a task name is appended — they simply stop driving the name itself.

**Collisions stay informative.** Two claude sessions in one project take tmux names `neurotto` and `neurotto-2` via the existing `__tcz_unique`, while their displays stay distinct through the task half. Hyphens therefore survive only in the address, never in what the user reads.

**The task half** for a claude session is the same string the current code already derives — `--name` when present, else the parsed pane title — via `__tcz_cmdline_name` / `__tcz_title_name`. No new extraction logic.

## Surfaces

| surface | shows | change |
|---|---|---|
| Opt+S picker | display | reads the new option |
| status-bar centre identity | display | `__tcz_status_identity` gains a precedence step |
| ShellFish / iTerm2 tab title | display | `__tcz_session_title` reads it, AND switches from active-pane dir to `session_path` so it stops moving on `cd` |
| `tmux ls`, `choose-tree` | tmux name | unchanged — the accepted cost of the split |

## Decision register

| ID | Decision | Who | Why | Alternatives if criticised | Symptom that points here |
|---|---|---|---|---|---|
| N1 | Safe tmux name + separate pretty display, rather than either alone | user (picked from 3) | one name everywhere would put arbitrary text into every `-t` target; display-only would leave `tmux ls` hyphenated | rename the session outright; display-only | "why does `tmux ls` disagree with the picker" |
| N2 | A NEW `@tmux_lives_display` option, not `@tmux_lives_name` | claude | the categorizer writing the claim option would make every session look claimed and freeze all renaming, silently | overload the claim and special-case the writer | app claims stop working, or renaming stops |
| N3 | Project = `basename(session_path)`, not `pane_current_path` | claude | measured: the pane path follows `cd`, the session path does not | use the pane path; use `pane_start_path` | a name changes when you `cd` |
| N4 | "No project" = `$HOME`, `/`, `/tmp` | claude | a small explicit denylist is predictable; the user said the *directory* is the organising signal | require a `.git` dir; treat every dir as a project | a project dir wrongly falls back to `gen-N`, or `~` gets a useless name |
| N5 | Display is `project · task` for claude sessions | user (picked from 3) | two claude sessions in one project stay distinguishable without hand-naming | project only; task appended only when it disambiguates | displays too long on a narrow ShellFish tab |
| N6 | `·` as the separator | claude | already the between-fields separator in the status bar | any other glyph; a plain space | the separator reads as noise |
| N7 | Non-claude sessions in a project dir get the project name too | user (picked from 3) | a node server in `~/projects/neuro` is more usefully `neuro` than `node` | `gen-N` for everything non-claude; project always, even at `$HOME` | non-claude names feel noisy or collide |
| N8 | Process names dropped entirely from naming | user | "running process isn't really helpful" | keep them as a fallback when there is no project | you miss knowing what a session is running |
| N9 | Tab title switches to `session_path` | claude | consistency with the rest; it currently moves on `cd` | leave it on the active pane's dir | the tab stops tracking where you actually are |
| N11 | `@tmux_lives_display` is cleared at the top of every iteration, before the early bailouts | claude | otherwise a hand-renamed or claim-carrying session keeps a stale display forever, making the user's own rename look ignored | validate the display against the `@tmux_auto_name` stamp instead | you rename a session and the picker still shows the old name |
| N10 | Complaint 4 needs no code change | claude | measured — the ownership guard already protects hand-names | investigate the specific path that re-stamped | a hand-named session gets renamed again |

## Blast radius

All in `functions/tmux-categorize.fish` unless noted.

- `__tcz_snapshot` — capture `#{session_path}` alongside the existing pane fields, and carry it into the emitted row. This is the one schema change; every consumer of the row splits on a fixed field count, so the additions must be appended, not inserted.
- `__tcz_categorize` — replace the `switch $f[2]` desired-name computation with the project rules, and manage `@tmux_lives_display` (see the staleness hazard below, which dictates WHERE in the loop that happens).
- `__tcz_status_identity` — add the display step to the format string. NB this is baked into the managed fragment at render time, so it reaches a running server only on the next `fisher update` / setup action.
- `__tcz_session_title` — read the display option, and take the dir from `session_path`.
- `__tcz_overview` — show the display in the picker list.
- A new pure helper for project extraction, so the rules are unit-testable without a tmux server.

## The staleness hazard, and why the clear happens early

**Caught in spec self-review, before any code.** `__tcz_categorize` bails out of its loop early twice — once for a session carrying an app claim, once for a session the ownership guard says is hand-named — and both `continue` before any naming work. A display option written on an earlier pass would therefore survive both bailouts forever.

The consequence is precisely the complaint this cycle exists to honour: a session auto-named `neurotto` with display `neurotto · Fix the picker lag`, then hand-renamed by the user to `My Project`, would keep showing `neurotto · Fix the picker lag` in the picker, the status bar and the tab title. The user's rename would appear to have been ignored — a worse failure than the hyphenation it replaced, because it looks like the tool overriding a deliberate choice.

**Rule: clear `@tmux_lives_display` at the TOP of each iteration, before either early `continue`.** A session is only given a display in the same pass that gives it a name; anything the categorizer declines to name carries no display at all, and falls back to the tmux name (or its claim, which outranks both). Nothing can go stale because nothing survives a pass it did not earn.

This also settles the claimed case cleanly: precedence already hides a stale display behind a claim, but clearing it means removing a claim later reveals the tmux name rather than a resurrected old display.

**A rejected alternative, recorded because it looks tidier than it is:** honour the display only when `session_name == @tmux_auto_name`, so a rename invalidates it automatically with no bookkeeping. It fails on the surface that matters most — the status bar reads the option through a tmux format string, and expressing that comparison there is both awkward and easy to get wrong, in the one place a mistake is most visible.

## Testing

**Pure, no server:** project extraction from a path; the `$HOME` / `/` / `/tmp` fallback; composition of `project · task`; behaviour with an empty task; a path with spaces or punctuation in the basename.

**Integration on an isolated `-L` socket:** a session started in a project dir gets the expected tmux name AND display; `cd`-ing the pane elsewhere does not change either; two sessions in one project collide to `-2` in the address while their displays stay distinct; a hand-named session is untouched; **a session carrying `@tmux_lives_name` is still skipped by categorize and still displays the claim** — that last one is the regression that would break neurotto and is the single most important assertion in this cycle.

**Guard:** the process name must not reappear as a naming source. Pin it by asserting a `running` session in a project dir is named for the project, and separately that the category is still reported as `running` — so the categories keep working while the naming stops using them.

## Explicitly not doing

- Renaming the session to the pretty form (rejected as N1 — arbitrary text in `-t` targets).
- Any change to the `claude` / `running` / `general` classification, the picker's grouping, or the ownership guard.
- Any change to how the claude task name is extracted.
- Compaction or renumbering of existing `gen-N` names — stable once assigned, by existing design.
