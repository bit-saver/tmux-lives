# tmux-lives — fish plugin

**tmux-lives** is a standalone, cross-platform **fisher plugin** (`bit-saver/tmux-lives`) providing tmux
automation: categorized sessions, a popup session picker, persistence across reboots, ShellFish/iTerm2
coexistence, and a generated OKLCH theme engine for the status bar and tab colours. Extracted from
`~/.config/fish`; shipped and live on Linux (rocket) and macOS (macwork).

---

## ⚠ This file is pruned, not append-only

This file was 231 KB on 2026-09-02 because each cycle appended a narrative and none was removed.

**When you write here, you also prune here.** Before adding a cycle narrative, delete the narrative it
supersedes. A paragraph describing an engine that no longer exists in the codebase is not history worth
carrying — it is a live-looking claim about dead code. The pre-prune text and the deep war stories: "Where
the history lives", below. **Budget: keep this file under ~40 KB.** If a cycle needs more than a few
paragraphs, the detail belongs in a memory file or a spec, with a pointer from here.

---

## Deployment — the one rule that never bends

**A Claude session NEVER deploys.** Finished changes reach the live `~/.config/fish/` only via the
**user's own `fisher update`**, run by them in their interactive fish.

- Never `cp` a change into `~/.config/fish/{conf.d,functions}/`, and never edit `~/.tmux.conf` or set
  universal variables to ship something.
- `fisher install`/`update` also *hang* in the Claude bash sandbox (parallel fetch needs job control).
- If a change needs live verification, push it and ask for a `fisher update`.
- ✅ **Temporary test edits to a live file are allowed** for observation, if restored **byte-identical**
  afterwards and proved with a `diff` — restore via `git show <installed-commit>:<path> > <live-path>`.

See memory `[[deploy_via_fisher_update_only]]`.

---

## Layout

| Path | What |
|---|---|
| `conf.d/tmux.fish` | Shell-side: autostart, session creation, `tmux-lives <verb>` dispatcher, the `--on-variable` reload handler, the Alt+S shell keybind |
| `conf.d/tmux-lives-install.fish` | Install side: `tmux-lives setup …`, the fragment renderer/writer, the theme engine (v6), post-update note |
| `functions/tmux-categorize.fish` | The categorizer — run as a **script** (`fish --no-config $cat <verb>`), never autoloaded. Session naming, the status tick, the popup picker, the theme picker, OSC emission |
| `tests/test-*.fish` | The gate — 9 suites |
| `tests/tick-rate-ab.fish`, `tests/truncate-perf.fish` | Hand-run, not `test-*`: tick-rate-ab samples a live pty window; truncate-perf times `__tcz_popup_truncate` |
| `docs/superpowers/specs/` | Design docs for shipped features, still accurate |
| `docs/history/` | Archived prose. Not guidance |

`docs/superpowers/plans/` holds only in-flight plans (now: landing chooser v2) — **plans are deleted once
their work ships**; git is the archive. Specs for shipped features stay.

---

## Live wiring

Installed by fisher to `~/.config/fish/{conf.d/tmux.fish, conf.d/tmux-lives-install.fish,
functions/tmux-categorize.fish}`, tracked in `fish_plugins` + `_fisher_plugins`.

`~/.tmux.conf` **sources a managed fragment** — its last lines are
`source-file ~/.config/tmux/tmux-lives.conf` then the TPM run-line. All tmux-lives wiring (categorize
tick, key binds, ShellFish commandeer (`client-session-changed`) + `client-attached` hooks, `LC_TERMINAL`
passthrough, resurrect/continuum declarations, theme `@options`, the status-format) lives in that
**rendered fragment**, `tmux-lives setup`-managed — never hand-edited or hardcoded in `~/.tmux.conf`.

New fragment wiring goes live on `fisher update` alone (`_tmux_lives_post_update` re-renders the fragment
when one exists); `tmux-lives setup install` is the from-scratch path.

**Two user-owned config surfaces** the fragment respects: `~/.tmux-lives.conf` (general user config,
sourced at fragment load and re-applied on non-ShellFish attach; `setup conf edit|add|reset`) and
`~/.config/tmux/tmux-lives-state.conf` (machine-owned status position/visibility toggles, sourced
*after* the style setup so it wins).

**TPM loads plugins AFTER our fragment**, so a plugin silently wins every conflict with it — why
`tmux-sensible` was dropped rather than fought; its three settings worth keeping were ported into the
fragment: `set -s escape-time 0`, `focus-events on`, `display-time 4000`.

---

## Command surface

Everything is `tmux-lives <verb>`. Help-page order: meta cluster `help` · `setup` · `update`, then the
session cluster `new/attach/picker/fix/categorize/clear/close` (aliases `u`, `n/a/p/f/c/x|q`).

- `setup install | verify | teardown | keys | auto | color | conf | cap | theme | landing` — the setup
  subcommands also work top-level as a **hidden**, undocumented shortcut (`tmux-lives auto on`).
- `update`/`u` wraps `fisher update bit-saver/tmux-lives` and reports whether anything actually changed
  (cksum digest before/after), diverting fisher's output to a temp file via `>file` — **not** a `(…)`
  capture, which breaks fisher's background-job fetch.
- Help pages are framed by `__tmux_lives_box` with content from `__tmux_lives_help_lines` /
  `__tmux_lives_setup_help_lines` (frame and content kept separate so ordering is testable unframed).
  ⚠ It measures with `string length --visible` and pads via a **quoted** variable — an inline
  `(string repeat -n 0 …)` expands to **zero args** and silently shifts the trailing printf fields.

⚠ **Every catalog scheme name is two words** (`mono deep`, `complementary bright`) —
`__tmux_lives_theme_cmd`'s `case '*'` **accumulates** positionals into one name so both quoted and
unquoted forms work; `list`/`off` are matched by earlier arms and unaffected.

Keys (all configurable via `setup keys`, `''` disables, baked into the fragment):
`prefix S` / `M-s` picker · `M-m` single-shot launcher · `M-t` scratch split · `M-r` resize key-table ·
`M-k` theme picker · `C-M-a` status position · `C-M-s` status visibility.

**Alt+S also works at a bare prompt outside tmux.** fish's preset `alt-s` prepends sudo to the previous
command; a plain `conf.d` bind outranks it. **`bind -M insert` is required** — a vi prompt starts in insert
mode, so a default-mode-only bind is never reachable.

---

## Dev loop and the gate

```
edit → run the gate → commit + push. Stop there.
```

Gate:

```fish
for t in tests/test-*.fish; fish $t; end          # then again with: fish --no-config $t
```

- Run **each mode as its own foreground Bash call** with an explicit `timeout: 600000`. If a call
  reports it was backgrounded, abandon it and re-run in the foreground.
- **Never** wrap the suite in a shell `timeout` — it truncates with no trailer and reads as a false clean.
- Capture failures with `grep -E '^FAIL'`, **never `tail -1`** — that hides which assertion fired.
- Current: **9/9 `ALL PASS` in both modes.** `test-tmux-install.fish` reports **960 plain / 959 `--no-config`**
  on every host. **The 1-count delta between modes is BY DESIGN** (one isolation assertion gated on plain
  fish) — do not "fix" it.
- `test-tmux-categorize.fish` and `test-tmux-auto.fish` print `ALL PASS` with **no count** — judge by the
  absence of `FAIL` lines. Only `test-tmux-install.fish`, `test-generic.fish` (3) and
  `test-tmux-status.fish` (4) report numbers; `test-tmux-popup.fish`'s timing assertion is now the
  hand-run `tests/truncate-perf.fish`.
- Sweep leaked `-L` sockets from `/tmp/tmux-1000/` after heavy runs. **Never touch `default`**; leave
  `neurotest*` alone. Killing a tmux server does **not** unlink its socket file.

### Test isolation

Every `tests/test-*.fish` opens with an identical **self-re-exec guard**: it mints a throwaway dir,
points `XDG_CONFIG_HOME` at it, and relaunches the suite under it. **Fish binds its universal store at
process startup**, so re-exec is the only mechanism, and it **fails closed** on mktemp failure.

Load-bearing details, each of which was a bug once:
- Mode is preserved across the re-exec via `test (count $fish_function_path) -gt 0`.
  **`set -q __fish_initialized` is a trap** — it is itself a universal, so in the child's fresh store it
  reads unset under plain fish too, misclassifying every run as `--no-config`.
- The interpreter is pinned with `set -l fish_bin (status fish-path)` (a command substitution in command
  position is a syntax error).
- `test-generic.fish` greps every suite for the **anchor line** `if not set -q TMUX_LIVES_TEST_UVARS`, not
  the bare name (a comment mentioning it defeated the first version).

**Known isolation hole, unfixed:** the `tmux_lives_funcs_file` seam is a *variable*, so the
`XDG_CONFIG_HOME` redirect misses it. `test-tmux-auto.fish`'s old hole (a fish-function `tmux` shim that
subprocesses cannot see) is closed structurally: a PATH shim pinned to the suite's `-L` socket with
`-f /dev/null`, `TMUX`/`TMUX_PANE` erased, a recorder categorizer stub. Copy that prologue into any new
suite. See `[[tmux_test_isolation]]`.

**A third $HOME seam, guarded:** `tmux_lives_render_cache_dir` — the categorize and install suites set it.
⚠ The directory is shared (the landing app keeps `projects.tsv` there): its prune deletes only
`<digits>-<hex6>.tsv` files. Any suite that can start a landing app must export
`tmux_lives_claude_projects_dir` / `tmux_lives_project_cache` (auto, categorize, install do; install once
wrote the real `projects.tsv`). Real-cache brackets check this run's **footprint** (seam rows, its own
fixture folders, an emptied file), never an mtime: the user's landing apps rewrite `projects.tsv` mid-run.

---

## Session naming

Two layers, since 2026-08-18 (spec `docs/superpowers/specs/2026-08-18-session-naming-design.md`):

1. A **safe tmux address** — `__tcz_project_name`, collision-suffixed by `__tcz_unique`. Never carries
   arbitrary `--name` text, so `tmux ls` / `-t` targets stay predictable.
2. A separate human **display** — `__tcz_display_name`: `"project · task"` for a claude session,
   project alone for anything else. Composed into `@tmux_lives_display`, read by
   `__tcz_status_identity` (precedence `@tmux_lives_name` > `@tmux_lives_display` > raw name).

**The project name comes from the ACTIVE PANE's cwd** (2026-08-29), not `#{session_path}`: a git-root
walk via `__tcz_git_root`, then that root's basename, else the path's own basename.

- `test -e`, **not `-d`** — in a linked worktree or a submodule `.git` is a regular *file*, and this
  project uses `git worktree` for isolated builds.
- **Never** a `git rev-parse` subprocess — per-session forks burned four cores on macOS.
- A generic walk result (`$HOME`, `/`, `/tmp`, `/var/tmp`) counts as "no repo found" and falls back to
  the path's own basename — else a dotfiles repo at `$HOME/.git` collides every non-project directory.
- `session_path` is **strictly dominated**: it equals the pane path until a `cd` and is stale after one.

Sessions are born in the **invoking shell's cwd**, except `__tcz_commandeer`, which pins `$HOME` at its
call site (not inside `__tcz_new_general`'s other, real-cwd caller) — reached via `client-session-changed` →
`run-shell`, which executes at the tmux **server's** cwd, wherever the server was started.

Restored claude breadcrumbs **are stamped** (`@tmux_auto_name`) — unstamped, a name froze at save time
while its pane moved on. The breadcrumb branch still `continue`s past the idle-kill; that half is
load-bearing.

Duplicate displays get a **bracketed ordinal** — `Sonos [1]` / `Sonos [2]` (a bare trailing number reads
as an iteration count), every member numbered, ordered by **sorted session name**.

**Known, deliberately not fixed:** `__tcz_snapshot`/`__tcz_overview` consult only the `@tmux_lives_name`
claim, never ownership — a hand-named session still renders its *project* in the picker.

---

## The status tick and its cost

The status bar's `#(…)` job **is** the scheduler (no daemon) — it runs the categorizer's `tick` verb
every `status-interval` (15).

**`status-right` is MERGED, not assigned.** tmux-continuum schedules its autosave by *prepending*
`#(continuum_save.sh)` to `status-right`; a bare `set -g status-right` discarded it and silently killed
snapshotting. `__tcz_status_right_merge` keeps a foreign prefix and replaces only our own part. The
prefix is kept **only** if it is nothing but `#(…)` groups and whitespace — a looser "contains `#(`"
test would weld a user's decorated `#(uptime) %H:%M` on forever, and tmux's *default* status-right must
be dropped or we paint two clocks. Driven by a plain `run-shell`, which is **synchronous** in tmux 3.3a
(only `-b` backgrounds).

`set -ga update-environment` is guarded per name with `show -gv` + `grep -qx` — **`show -gv` prints one
name per line**, so `-x` is exact and load-bearing (a substring match lets `LC_TERMINAL_VERSION` satisfy
the `LC_TERMINAL` check), and `&&` makes it **fail closed** (a bare `! tmux … | grep` misreads "absent").

**Two batching layers, both one snapshot per pass, flushed at the top of `__tcz_main`:**

- `__tcz_tmux_load` — four tmux calls per pass (`show -g`, `list-sessions -F`, `list-panes -a -F`, a
  lazily-loaded `list-clients -F`), taking the tick from **44 client spawns to 9** steady-state.
- `__tcz_ps_load` — one `ps` snapshot pair per pass, feeding all pid helpers.

⚠ **Both flush functions must use a GLOB, never a regex.** `string match -r` with a *prefix pattern*
returns the matched **substring**, so `string match -r '^__tcz_tmux_'` erases a variable literally named
`__tcz_tmux_` while every real entry silently survives — shipped once in `__tcz_ps_flush`.

**Staleness rule:** a memoized read is stale the moment something in the same pass writes what it reads.
Flush **after the write**, not before each read — a flush-per-read-site rule is easy to omit and
impossible to notice missing. `@tmux_lives_display` deliberately stays **live** (not memoized):
`__tcz_tmux_flush` is a coarse glob whose blast radius would evict the pane/client memos too.

**Emission is deduped.** The tick emits OSC title/colour only when the value changed for that tty
(per-tty cache in `@tmux_lives_emit_<tty>_{title,color}`); discrete events force-emit — this is what
killed a ShellFish cursor flicker from unconditional OSC writes every cycle. `__tcz_set_claude_opt`
dedups for the same reason: **any** bar redraw re-emits the cursor.

⚠ **Empty-cache gotcha:** `test "$x" = (__tcz_emit_get …)` **throws** when nothing is cached (fish
zero-word command substitution) — capture into a var first: `set -l cached (…); test "$x" = "$cached"`.

**Verified in production:** tick rate = `clients ÷ status-interval` exactly, and tmux-lives is out of the
host's top-5 CPU — `[[tick_tmux_call_batching]]`. A tick self-rate-limit was **DROPPED unbuilt**
(2026-09-14, user's call) — `[[tick_self_rate_limit]]`.

---

## ShellFish / iTerm2 integration

Detection reads the attaching client's process environ (`/proc/<pid>/environ` on Linux, `ps eww` on
macOS) via `__tcz_pid_environ`; `__tcz_client_terminal` maps a pid to `shellfish` / `iterm2` / `other`
from `LC_TERMINAL`.

- **ShellFish** gets the bar colour as an OSC written directly to `#{client_tty}` (only that tab sees
  it); **iTerm2** mirrors it via an OSC 6 tab-colour triplet.
- **Everything else** triggers `tmux source-file ~/.tmux-lives.conf` to re-apply the user's own settings
  so ShellFish's forced options don't leak.
- Tab title is `[<h>] <dir> [(C)]`, `<h>` the **first character** of the short hostname (the tab strip is
  the scarcest space in the UI); `(C)` when any pane runs claude.
- A tab that drops its colour with no re-attach (iOS suspend/resume, mosh reconnect) is caught by a
  **colour-only backstop** re-emit every `@tmux_lives_heal_interval` seconds (default 120).

**The cursor strobe — there are TWO, check which before acting.** The discriminator needs no tooling:

| | Fires when | Fix |
|---|---|---|
| #1 | **Any** redraw, so an idle pane strobes too | `set -g cursor-style block` — a steady style is invisible when re-emitted. tmux's `cstyle` feature re-emits the style on every redraw and ShellFish resets the cursor each time |
| #2 | **Only** inside an actively-working Claude pane | `terminal-features xterm*:sync` |

#2's mechanism: tmux picks synchronized-output support **per client, at attach, from its own terminal
identification, and never asks the client** — `tmux info` shows `Sync: [missing]` for ShellFish and
present for Ghostty on the **same server/session/TERM**. Gated to **tmux ≥3.7** (3.3a never answers
DECRQM, so it's immune); the probe uses `sort -V` (a numeric compare gets 3.10 > 3.7 wrong). Universal
`tmux_lives_sync_terminals`, fragment argv[18]; it and `tmux_lives_cursor_style` are **`set -U`-only**
(no `setup` setter — known wart).

⚠ **Three testing traps here** (unknown feature names accepted silently, vacuous parse tests on a
malformed `source-file` line, quote-mutations that still work because tmux concatenates adjacent quoted
strings) — see `[[shellfish_cursor_flicker]]`.

---

## Theme engine — where it actually stands

**v6 is wired and live in production code.** Every v5 call site is gone. `__tmux_lives_render_fragment`
and `__tmux_lives_theme_roll` still call `__tmux_lives_theme_render` directly — the fragment runs at
setup/update time and must never let a cache miss break a live apply, and `theme_roll` samples a fresh
recipe per attempt so there is nothing to cache. `__tmux_lives_theme_apply_live`,
`__tmux_lives_theme_list`, and the picker (`__tcz_theme_picker`) instead call the file-cached front,
`__tmux_lives_theme_render_cached` (see "The render cache", below). The v5 engine is **deleted**
(2026-09-14); only `__tmux_lives_theme_relationships` survives, because `__tmux_lives_migrate_v4`'s reset
branch still calls it.

A theme is now a **catalog scheme NAME resolving to a five-field recipe** (`mode Lspan peakC peakPos
arrangement`) via `__tmux_lives_theme_recipe`. **The recipe is the stored identity** — the name is a
label, never persisted as such.

```
tmux-lives setup theme <scheme>|list|off
```

`--place`/`--mode`/`--phase` all now **error**: "was removed in v6 — a scheme is now a recipe ... chosen
by name; see 'tmux-lives setup theme list'".

**Catalog: 42 rows, 14 curated.** `__tmux_lives_theme_catalog_v6` is the complete 7-mode × 6-arrangement
grid — one tuned recipe per cell, curation only *removes*. `_v6_default` flags the 14 curated rows (two
arrangements per mode, all reachable cold); `_v6_rest` is the other 28, appended when expanded (no
header). `mono deep` is the one hand-placed row — kept for being the user's repeatedly-favourite palette,
not for being the most robust (bound-1 margin 0.0050 vs ≥0.0113 elsewhere).

**Migration (`__tmux_lives_migrate_v6`) resets to `mono deep`, preserving only the seed** — v5's
relationship/place/mode/phase have no v6 mapping. Idempotent, runs on `fisher update`.

In the theme picker `z` **rolls the real recipe space** (session-local 12-entry history).

### The tie-break is structural, not a float comparison

`__tmux_lives_theme_rampidx` gives every role an **integer** ramp index; `constrain`'s swap compares
ramp-index distance, not lightness, so two roles can't silently exchange on a sub-0.005 perturbation.

### The v6 pipeline

Four pure stages, composed by `__tmux_lives_theme_render`:

1. **`__tmux_lives_theme_anchors`** — seed hue + harmony mode → 1–4 hue angles (the classical set); the
   seed is anchor one in every mode, why `analogous` uses offsets `0 -30 30`.
2. **`__tmux_lives_theme_ramp`** — seven `(L,C)` pairs, with lightness span/peak chroma/peak position as
   **independent** dimensions; the window is positioned so the seed's own L falls inside it.
3. **`__tmux_lives_theme_arrange`** — six named permutations of ramp position onto role, a **PURE
   PERMUTATION**. Anything that substitutes a colour belongs in `constrain`, not here.
4. **`__tmux_lives_theme_constrain`** — four stages in a **fixed, load-bearing order**: big-role lightness
   clamp → big-role chroma clamp → no-white → **text-contrast floor LAST** (legibility is correctness,
   and every earlier stage can move `bar` or `text`).

Roles: `bar sep tabs active windows cap text`. "Big three" = `bar`/`tabs`/`cap`.

### The three bounds

Reverse-engineered from palettes the user had already praised, then confirmed 7/7 by blind prediction.
**Hue placement is not a factor** — see `[[three_bounds_palette_rule]]` for the falsification and why.

| | Bound | Enforced? |
|---|---|---|
| 1 | Peak chroma **0.105–0.180** | **No, and no clamp can** — a dark seed's gamut caps peak chroma near 0.082 regardless of the recipe; it's the catalog's job (above) |
| 2 | Big-three **mean** chroma ≤ **0.095** | Yes — scaled down together so the three keep their relative structure rather than flattening to one value |
| 3 | Big-three max lightness ≤ **0.70** | Yes — **but the clamp targets 0.695** (quantisation headroom against the chroma clamp that runs next). Do not tidy to 0.70 — `[[three_bounds_palette_rule]]` |

### Still open

**All six arrangements place `text` at ramp index 1 or 7** (both ends of the chroma curve), so at
`peakPos ≈ 0.5`, `text` renders at C 0.011–0.013, below v5's pinned 0.030. Not blocking — a curated
recipe can avoid a mid-ramp `peakPos` if it matters in practice.

### OKLCH facts that make an assertion unsatisfiable if guessed

`peakC` is gamut-capped **hue-dependently** (0.26 at purple, 0.15 at green); hue families need a 25°
tolerance counted **circularly**; the text floor needs **two** stages; stage two does **not** preserve
chroma. Full numbers: `[[theme_engine_v6]]`.

### The render cache

`__tmux_lives_theme_render_cached` file-caches `__tmux_lives_theme_render`, keyed on **engine key +
seed** — one file per pair (`<cache dir>/<engine key>-<seed>.tsv`), one line per five-field recipe. The
engine key is a **cksum of the install file's own bytes** (`__tmux_lives_engine_key`), so the cache
self-invalidates the moment the theme engine's code changes — no version constant to bump by hand. Lives
at `tmux_lives_render_cache_dir` (seam), else `$XDG_CACHE_HOME/tmux-lives`, else `$HOME/.cache/tmux-lives`.
A miss renders, appends one line, and prunes stale-engine files. **Never fails a render over the cache**
— an unreadable engine key or an uncreatable directory falls straight back to the raw renderer.

## The picker (theme + session)

Both are `display-popup` UIs drawn by `functions/tmux-categorize.fish`.

**Geometry facts, measured — not guessed:**
- A popup **taller than the client does not clamp: it refuses to open** (`height too large`). That is
  why the theme picker uses `-w 52 -h 85%` and not a constant.
- **No tmux command resizes an open popup**; `stty size` **does** report a popup's own size
  (`$LINES`/`$COLUMNS` not exported); `-w/-h` percentages work and are exact, `-w '#{client_width}'`
  is rejected.
- `WIN = rows - STATIC` (`STATIC_IDLE 17` / `STATIC_EDIT 22`), gated on the **stricter** `STATIC_EDIT`
  (25 popup rows = 30 client rows) — an idle-only floor once admitted a 20-row popup that overflowed
  the instant `b` was pressed.

**Performance — four layers, all measured (`[[popup_geometry_and_perf]]`):**
1. **Construction** cost is the **number of fish command substitutions**, not any one builder (a call
   inside `(…)` is 19× a plain call) — fixed by memoizing the row/static/swatch builders behind **one**
   helper (`__tcz_thp_reload`), which also makes a bare-integer row cache key legal.
2. **Emission.** `__tcz_popup_emit` diffs against `__tcz_pe_prev` and emits only changed rows in a sync
   wrapper, full-painting only when forced or the row **count** differs — a big win in a keypress burst,
   a small loss on isolated ones (break-even ≈ 1 key/0.7s). The session switcher is deliberately **out
   of scope** — its cursor move changes nearly every row.
3. **Input.** One rule on every held-key path: **discard, one step per frame.** ⚠ `stty min 0 time 0`
   must be re-asserted **inside** every drain loop (readkey's CSI branch leaves the tty blocking), and
   the arrow poll must never escalate its timeout or autorepeat outpaces it and the picker stalls.
4. **Rendering.** Colour-decode is memoized per process and the gamut clamp no longer forks `seq`
   (**~0.88ms/call, 759 calls/render**); warm, served from the render cache (above), the scheme list
   build is **17–19ms** vs. seconds cold.

**tmux 3.3a DROPS app-sent DECSET 2026** (a bogus `?9999` behaves identically — tmux does not forward
private modes it doesn't implement), so the sync wrapper never reaches ShellFish there — it paints
progressively, the symptom is *stuttering*, not a frozen screen.

**Seed editor:** `a` = "show me what this seed does" (rebuild strips, stay in editor); `⏎` = "this is
the seed — apply it and let me out" — both **local**, no tmux option, no tab OSC; applying the seed is
not adopting a scheme. Staleness is **derived** from `$stripseed`, not tracked as a flag (a flag can't
answer "edit, `a`, then `esc`", where the seed reverts but strips still show the abandoned edit) — stale
strips render faint, and the dim state is part of the row cache key.

**Auto-apply was built, tried live and REJECTED** ("wayyyy too much… everything is so lacking in
responsivity") — do not re-propose it; a toggle doesn't rescue a feature whose cost is felt unasked.
See `[[config_vs_adoption]]`.

---

## macOS

Runtime-only persistence (no launchd units; continuum autosave + first-access restore), `/proc`→`ps`
detection, bare cold-start on first attach. Install: `fisher install bit-saver/tmux-lives` then
`tmux-lives setup install`.

**`pgrep` is the expensive primitive on macOS and `ps` the cheap one — the Linux intuition inverts.**
`/usr/bin/pgrep` delegates to the `sysmond` **root daemon**, walking every process *and thread* per call,
with the cost **invisible from inside**. `pgrep` is **absent from the file entirely** — `[[macos_pgrep_sysmond]]`.

**On macOS a native-install claude pane's `pane_current_command` is its version (`2.1.270`)**, with the
real `claude` a child of the pane pid. Detect claude with `__tcz_pane_is_claude`, never a literal cmd
match — `__tcz_set_claude_opt` did the latter and left `@tmux_lives_claude` (the bar's ✦) empty on every
macwork session until 2026-09-16.

**Two settled dead ends — do not re-chase:**
- **`reattach-to-user-namespace` as `default-command` is a proven no-op** on macOS 26.5.2 — GUI
  window/menu-bar placement is governed by the Aqua **audit session** `asid`, not the bootstrap domain.
  Findings: `docs/macos-gui-namespace-findings.md`.
- The `-ww` rationale for `ps` **did not survive Mac verification** (no truncation measured); it stays as
  free insurance. Details: `docs/2026-08-18-verification-pgrep-sysmond-fix-on-macos.md`.

---

## Standing decisions — do not reopen

- **NO WHITE is a hard exclusion** (settled 2026-08-25, ban → prior → **ban**) — the user named the bias
  themselves and chose it anyway. Do not re-offer white "where it fits".
- **Non-mono harmony schemes are rejected** (2026-09-21, "way too crazy") — do not re-offer radical range.
- **Muted is a style the user LIKES.** The defect was ever only **fixedness**, not dimness — raising the
  ceiling relocates the single destination and costs a style they want.
- **Hue placement is NOT what makes a palette work**, refuted three ways. Do not build another
  hue-placement rule.
- **Cohesion is a curve, not uniformity.** Forcing one hue family read as *less* cohesive — the liked
  palette's tiny `sep` separators carry its **highest chroma**, and flattening crushed it. **Never
  hand-assign a role colour** — always sample the ramp.
- **ShellFish's tab bar is the optimization target**, not the tmux status bar (`tabs` ≈ 1.8× `bar` by
  area) — every colour mockup renders a ShellFish and a cmux view; ShellFish decides, cmux may veto.
- **Colour/UI mockups must be a faithful facsimile of the real widget**, not abstract swatches.

---

## Traps that cost real time

**Environment**
- ⛔ **Every agent shell runs inside the user's LIVE tmux, so `TMUX` names his real server — and `TMUX`
  beats `TMUX_TMPDIR`.** Every ad-hoc tmux command in a probe names its socket (`-L name` / `-S path`);
  never a bare `kill-server`. A review agent killed the live server this way on 2026-09-29
  (`docs/2026-09-29-review-agent-killed-live-tmux-server.md`). Put this rule in every sub-agent prompt.
- **The agent Bash tool runs zsh.** A non-matching glob **aborts the whole command** (`rm -rf a/* b/*` can
  silently no-op) — use `find … -delete`. MULTIOS also leaks stdout into a stderr-only pipe count; wrap
  in `bash -c '…'`.
- **Never `find /` on this host** — two CIFS mounts park a whole-fs scan in uninterruptible D state
  (even SIGKILL sits pending).
- **The code-review-graph MCP indexes 0 files here** — no fish parser exists; the global "use the graph
  before Grep" rule does not apply in this repo.
- **When a subagent is editing a file, measure from `git show`, not the worktree** — a mid-edit
  measurement can be off by 100+ bytes and defer a real defect.

**fish** (see memory `[[fish_gotchas_that_lie]]` — these return a confidently *wrong* answer, not an error)
- `eval` returns status **0** on a parse error, and its `math` diagnostics **bypass in-process `2>`**.
- A variable is never word-split into command + args; a keyword arriving via expansion is rejected. There
  is **no** variable form of a seamed command — spell it out in both branches.
- **`printf --` is not an option terminator** — fish takes `--` as the format string and discards the
  rest, silently. See `[[fish_printf_dashdash]]`.
- Autoloaded functions **never reload** when their file changes (redefinition is **silent**); a
  **double-quoted** `"$x[(math …)]"` list index is an *error*, not an index (grep-guarded).
- A zero-output command substitution collapses the whole enclosing argument to an empty list, and
  `string match -r` with a prefix pattern returns the **matched substring**, not a boolean.

**tmux 3.3a** (see memory `[[tmux_target_quirks]]`)
- **A colon-less `-t` is read as a WINDOW target first**, so a bare name collides with window names (every
  Claude window is `claude`) and numbers; `=name` (no colon) misroutes too. The exact session form for
  option/window/pane/capture commands is `=name:` (`__tcz_session_target`, pure; `conf.d/tmux.fish` spells
  it inline). Session-typed commands (`has-session`, `rename-session`, `kill-session`, `switch-client`,
  `list-clients`) keep `=name`. A collision test must erase `TMUX`/`TMUX_PANE` and build in both creation
  orders, or it can pass by luck.
- An **unquoted `#hex`** option value is a tmux **comment** — the option silently goes empty and
  `source-file` still returns rc0.
- tmux **silently accepts an unknown `terminal-features` name**, and a `-L` test socket still loads
  `~/.tmux.conf` unless started `-f /dev/null`.

**Migrations** (see `[[theme_clobber_during_dev_is_fine]]`)
- **A migration that validates against its OWN version's vocabulary poisons every later version.** Guard
  each one first with `set -q <later-version-marker>; and return 0` — `__tmux_lives_migrate_v4` once ran
  unguarded before `_v6` and reset 36 of 42 v6 schemes on every `fisher update`. ⚠ An isolated call proves
  nothing about the chain: store a non-default recipe and run the migrations in
  `_tmux_lives_post_update`'s real order.
- **Standing rule: a version migration RESETS, it never preserves.** Keep the seed, erase retired
  universals, write the new default. No mapping logic.

**Testing** (see memory `[[sdd_assertion_discipline]]`)
- **A test whose command substitution calls an undefined function does not fail** — fish aborts the whole
  statement, nothing prints, and a suite with no pass counter still reports `ALL PASS`. **A guard can
  also be green by sampling luck** — perturb the sampling grid before trusting a bounds ratchet.
- **A vacuous assertion is the default failure mode here** — grep guards match COMMENTS too (describing a
  banned shape in prose has tripped its own guard twice), so bound every body-grep to a variable defined
  *above* it and pair it with a positive count. **Modifying a pre-existing guard is the highest-risk edit
  in the file** — a retarget can silently shrink its capture and print a false pass unconditionally.
- **A rendered-output fixture can't pin an invariant the engine itself hunts for and relocates** — assert
  the table from source (`awk`-extract the block), with a vacuity guard.
- **Never `git checkout` to revert a mutation** with uncommitted work — it reverts to HEAD. Restore from a
  file copy taken beforehand and prove byte-identity with `diff`.
- **A mutation battery proves the mutations you chose were caught, not that your assertions are awake** —
  and the recurring shape, confirmed ten times, is that **an invariant one stage establishes is not one a
  later stage is obliged to preserve.** A fixed order is necessary, not sufficient.

---

## Landing session

Spec: `docs/superpowers/specs/2026-09-26-landing-session-design.md` (vault `Tmux-lives/Landing Session - Design`).
Every automatic entry (login, outside-tmux `picker`, new ShellFish tab) and every closing tab lands on a
per-tab `_landing-N` chooser (live sessions · idle Claude projects · new shell).

- **Identity is the NAME**, never a session option: `__tcz_is_landing` (categorizer) and `__tmux_is_landing`
  (shell side) must agree; `__tcz_free_name <prefix> <taken…>` mints `gen-N` and `_landing-N`. **Kill
  switch** = universal `tmux_lives_landing` (only the literal `on` is on; unset = on), fragment argv[19],
  `setup landing on|off|status`; `off` must equal pre-landing behavior exactly.
- **Close path** = global `remain-on-exit on` + a `pane-died` hook → `session-close` (`__tcz_session_close`:
  land every client, then kill; shared with `close` and the app's `x`). Hook is `#{q:…}`-quoted with a
  `|| tmux kill-pane` fallback. ⚠ The handler resolves the session from the **pane id** (a tick can
  rename it mid-close); categorize never renames a session whose active pane is dead.
  **`detach-on-destroy off` is refuted** (MRU session first). `remain-on-exit` and the three hooks are
  server-global: `off` and teardown restore them.
- **Creation** — `__tcz_landing_new [client]` retries a lost name race; a failed switch kills only its own
  session, by id. Login/`picker` run `landing-new` then `exec tmux attach-session`; they and `close` go
  legacy on no name or **no managed fragment** (nothing would clean up). `picker -t` keeps take-over.
  `fisher update` respawns every live landing pane (`__tmux_lives_landing_respawn`).
- **Sweep** — the tick kills clientless `_landing-*` from the loaded memo (zero tmux calls when none);
  ⚠ it **spares any under 10 s old**: `landing-new` creates detached and the shell attaches later.
- **Excluded from** categorize/rename, snapshot+overview, both general-picks, `prune`, `clear`, tab titles
  and restore (a restored clientless landing is killed by name). `after-new-window`/`-split-window` hooks evict a
  window opened inside landing to a `gen-N` in `$HOME`.
- **App** — diff-painted (an idle refresh writes nothing); live rows every 3 s (15 s after a minute with no
  key; seams `tmux_lives_landing_idle_after`/`_idle_refresh`), the idle-project list every 10th pass
  (cache `projects.tsv`; seams in "Test isolation");
  `d` detaches, `q`/Esc are no-ops (one token in `__tcz_popup_readkey`).
- **Input** — a key acts only alone: with more already pending it is typed-ahead or pasted text (ShellFish
  types `cd "<dir>"`⏎ into each new tab), drained to a 0.3 s gap unless a held move; CR LF is one ⏎. All
  input is drained until a quiet second after the first paint, 2 s at most (settle; tests: `__tcg_ready`).

**Harness facts learned:**
- A `script` pty client needs `env SHELL=/bin/sh` (zsh mangles `=name`) and a long-lived silent stdin
  (`sleep N |`, or a FIFO held open read-write, whose writes are keystrokes: `__tcg_kbd_client`); a bare
  `script` forwards EOF as Ctrl-D and detaches within ~100 ms.
- `pane-died` is **window-scoped** (`show-hooks -gw`, not `-g`); `show-hooks` lists *unset* hook names, so
  assert on the `[N]` form. Test servers need `-f /dev/null` or the live fragment's hooks fire in them.
- A throwaway-server rehearsal needs `HOME` redirected, the fragment's `run '~/.tmux/plugins/tpm/tpm'` line
  stripped (TPM would load the real resurrect/continuum), and `set -g default-command /bin/sh` (a login
  `sh` resets `PATH` via `/etc/profile`, so the shim and fake `claude` vanish).

---

## Current state — 2026-09-29

**The landing session** (`7528599`) is deployed on both machines; its type-ahead fix and idle cadence are
merged on `main` and await the user's `fisher update`.

### Theme work — ON HOLD, direction changed 2026-09-21/22

The user rejected the non-mono v6 schemes ("way too crazy") and handed colour decisions to Claude. Target:
the seed used **verbatim** as one colour + its shades + greys, HSB-style seed controls, maybe a second
colour later (v6 ignores seed chroma; seed lightness only shifts the ramp window). Prototype
`artifacts/mockgen/v7proto.py` (gitignored, rocket only); mock `05-seed-plus-grey.html` awaits the user.
See `[[mono-first-not-radical]]`, `[[mockups-must-render-the-real-thing]]`.

### Shipped — the rules they left behind

- **Legibility floors** — text 0.40 · active 0.32 · windows 0.26 · sep 0.15 · ✦ 0.15 against `bar`, in
  `__tmux_lives_theme_floor_role` (swap, then nudge; roles lock). ⚠ Do NOT prefer the dark nudge; the
  chroma cost is ACCEPTED — `[[three_bounds_palette_rule]]`.
- **Mono-only** — `M` → `__tmux_lives_theme_mono_grid` (36 rows); triples are read out of the catalog.
- **Titles** — OSC **0** to every attached client (iTerm2's tab label follows only OSC 0/1); colour escapes
  stay terminal-gated. `client-session-changed` titles a new client before `client-attached` fires, so
  `__tcz_on_attach` has no retitle (`[[tmux_attach_hook_order]]`). A correct bar proves nothing about the title.

### Open

- **Chooser v2** — approved 2026-10-01, spec updated, not built (see the spec's Status line).
- **Theme picker top border flickers on scroll** (2026-10-01) — not reproduced (959 frames, 3.3a+3.7b);
  suspects: stray stderr, or the client shrinking (size read once). Awaiting the user's observations.
- **iTerm2 real host** — wanted (`OSC 1337 RemoteHost`), deferred 2026-10-01. Workspace-TUI sidebar: after v2.
- **Login hardening pending:** a landing session that vanishes before the attach `exec` ends the SSH login
  (`has-session` guard).
- `close`'s help row still says "and exit" (a test pins it); with landing on the tab lands instead.
- `README.md`'s Retired settings line about `--polarity`/`--range` — inherited, unverified.

---

## Where the history lives

- **`docs/history/2026-09-02-claude-md-full-archive.md`** — the verbatim 231 KB `CLAUDE.md` as it stood
  before this prune. History, not guidance.
- **git** — `git log --diff-filter=D -- <path>` finds the commit that removed any deleted doc.
- **The memory store** (`~/.claude/projects/-home-bitsaver-workspace-tmux-lives/memory/`), indexed by
  `MEMORY.md` — the durable knowledge layer; **prefer adding depth there over growing this file.**
- **claude-mem:** history through **2026-06-17** is labelled `fish` (this project was extracted from
  `~/.config/fish`), not `tmux-lives` — query `project: "fish"` too (terms: tmux, auto-tmux, categorize,
  shellfish, resurrect).
