# tmux-lives — fish plugin

**tmux-lives** is a standalone, cross-platform **fisher plugin** (`bit-saver/tmux-lives`) providing tmux
automation: categorized sessions, a popup session picker, persistence across reboots, ShellFish/iTerm2
coexistence, and a generated OKLCH theme engine for the status bar and tab colours. Extracted from
`~/.config/fish`; shipped and live on Linux (rocket) and macOS (macwork).

---

## ⚠ This file is pruned, not append-only

This file was 231 KB / 205 lines on 2026-09-02 — about 58k tokens loaded into every session — because
each cycle appended a forensic narrative and nothing ever removed one. It was cut to the current state
plus the rules that still bind.

**When you write here, you also prune here.** Before adding a cycle narrative, delete the narrative it
supersedes. A paragraph describing an engine that no longer exists in the codebase is not history worth
carrying — it is a live-looking claim about dead code. The full pre-prune text is at
`docs/history/2026-09-02-claude-md-full-archive.md` and in git; the deep war stories live in the memory
store. **Budget: keep this file under ~40 KB.** If a cycle needs more than a few paragraphs, the detail
belongs in a memory file or a spec, with a pointer from here.

---

## Deployment — the one rule that never bends

**A Claude session NEVER deploys.** Finished changes reach the live `~/.config/fish/` only via the
**user's own `fisher update`**, run by them in their interactive fish.

- Never `cp` a change into `~/.config/fish/{conf.d,functions}/` to make it "live".
- Never edit `~/.tmux.conf` or set universal variables to ship something.
- `fisher install`/`update` also *hang* in the Claude bash sandbox (parallel fetch needs job control) —
  but the rule stands regardless of that.
- If a change "needs to be live to verify": push it and ask the user to `fisher update`.
- ✅ **Temporary test edits to a live file are allowed** for observation, on one strict condition:
  restore it **byte-identical** afterwards and prove it with a `diff`.
  Clean restore: `git show <installed-commit>:<path> > <live-path>`, then `diff`.

See memory `[[deploy_via_fisher_update_only]]`.

---

## Layout

| Path | What |
|---|---|
| `conf.d/tmux.fish` | Shell-side: autostart, session creation, `tmux-lives <verb>` dispatcher, the `--on-variable` reload handler, the Alt+S shell keybind |
| `conf.d/tmux-lives-install.fish` | Install side: `tmux-lives setup …`, the managed-fragment renderer/writer, the theme engine (v5 live + v6 core), post-update note |
| `functions/tmux-categorize.fish` | The categorizer — run as a **script** (`fish --no-config $cat <verb>`), never as an autoloaded function. Session naming, the status tick, the popup picker, the theme picker, OSC emission |
| `tests/test-*.fish` | The gate — 9 suites |
| `tests/tick-rate-ab.fish` | Hand-run only; deliberately NOT named `test-*` so it stays out of the gate (it samples a live window with real pty clients) |
| `docs/superpowers/specs/` | Design docs for shipped features that still describe how the thing works |
| `docs/history/` | Archived prose. Not guidance |

`docs/superpowers/plans/` does not exist by design — **plans are deleted once their work ships**; git is
their archive. Specs for shipped features stay.

---

## Live wiring

Installed by fisher to `~/.config/fish/{conf.d/tmux.fish, conf.d/tmux-lives-install.fish,
functions/tmux-categorize.fish}`, tracked in `fish_plugins` + `_fisher_plugins`.

`~/.tmux.conf` **sources a managed fragment** — its last lines are
`source-file ~/.config/tmux/tmux-lives.conf` then the TPM run-line. All tmux-lives wiring (categorize
tick, key binds, ShellFish commandeer + `client-attached` hooks, `LC_TERMINAL` passthrough,
resurrect/continuum declarations, theme `@options`, the status-format) lives in that **rendered
fragment** and is `tmux-lives setup`-managed — not hand-edited, not hardcoded in `~/.tmux.conf`.

Getting new fragment wiring live = `fisher update` then any `setup` action (or just `fisher update`:
`_tmux_lives_post_update` re-renders the fragment when one exists). `tmux-lives setup install` is the
from-scratch path.

**Two user-owned config surfaces** the fragment respects: `~/.tmux-lives.conf` (general user config,
sourced at fragment load and re-applied on non-ShellFish attach; `setup conf edit|add|reset`) and
`~/.config/tmux/tmux-lives-state.conf` (machine-owned, holds the persisted status position/visibility
toggles; sourced *after* the style setup so it wins).

**TPM loads plugins AFTER our fragment**, so a plugin silently wins every conflict with it. That is why
`tmux-sensible` was dropped (2026-08-05) rather than fought — the three settings worth keeping were
ported into the fragment: `set -s escape-time 0`, `focus-events on`, `display-time 4000`.

---

## Command surface

Everything is `tmux-lives <verb>`. Help-page order: meta cluster `help` · `setup` · `update`, then the
session cluster `new/attach/picker/fix/categorize/clear/close` (aliases `u`, `n/a/p/f/c/x|q`).

- `setup install | verify | teardown | keys | auto | color | conf | cap | theme` — the setup
  subcommands also work at top level as a **hidden** shortcut (`tmux-lives auto on`), deliberately kept
  out of the help.
- `update`/`u` wraps `fisher update bit-saver/tmux-lives` and reports whether anything actually changed
  (cksum digest before/after), diverting fisher's noisy output to a temp file via a `>file` redirect —
  **not** a `(…)` capture, which breaks fisher's background-job fetch.
- Help pages are framed by `__tmux_lives_box` with content from `__tmux_lives_help_lines` /
  `__tmux_lives_setup_help_lines` (frame and content kept separate so ordering is testable unframed).
  ⚠ `__tmux_lives_box` measures with `string length --visible` and pads via a **quoted** variable — an
  inline `(string repeat -n 0 …)` expands to **zero args** and silently shifts the trailing printf
  fields.

Keys (all configurable via `setup keys`, `''` disables, baked into the fragment):
`prefix S` / `M-s` picker · `M-m` single-shot launcher · `M-t` scratch split · `M-r` resize key-table ·
`M-k` theme picker · `C-M-a` status position · `C-M-s` status visibility.

**Alt+S also works at a bare prompt outside tmux.** fish binds `alt-s` itself to a sudo-prepend that
recalls the *previous* command line when the current one is empty; ours overrides it in `conf.d`
(a plain conf.d bind is a user binding and outranks fish's preset). **`bind -M insert` is required and
is not redundant** — a vi prompt starts in insert mode, so a default-mode-only bind is listed but never
reachable.

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
- Current: **9/9 `ALL PASS` in both modes.** `test-tmux-install.fish` reports **839 plain / 838
  `--no-config`**. **The 1-count delta is BY DESIGN** (one isolation assertion is gated on plain fish)
  and has been for many cycles. Do not "fix" it.
- `test-tmux-categorize.fish` and `test-tmux-auto.fish` print `ALL PASS` with **no count** — they have
  no pass counter, so judge them by the absence of `FAIL` lines. Only `test-tmux-install.fish`,
  `test-generic.fish` (2) and `test-tmux-status.fish` (4) report numbers.
- Sweep leaked `-L` sockets from `/tmp/tmux-1000/` after heavy runs. **Never touch `default`**; leave
  `neurotest*` alone, it belongs to another project. Killing a tmux server does **not** unlink its
  socket file.

### Test isolation

Every `tests/test-*.fish` opens with an identical **self-re-exec guard** (md5
`0538ed9cc17766afa9e515812d66f091`): it mints a throwaway dir, points `XDG_CONFIG_HOME` at it, and
relaunches the suite under it. **Fish binds its universal store at process startup, so the redirect
cannot be applied from inside a running test** — re-exec is the only mechanism. It **fails closed**
(mktemp failure → refuse to run).

Load-bearing details, each of which was a bug once:
- Mode is preserved across the re-exec via `test (count $fish_function_path) -gt 0`.
  **`set -q __fish_initialized` is a trap** — it is itself a universal, so in the child's fresh store it
  reads unset under plain fish too, misclassifying every run as `--no-config`.
- The interpreter is pinned with `set -l fish_bin (status fish-path)` — a command substitution in
  command position is a fish syntax error.
- `test-generic.fish` greps every suite for the **anchor line** `if not set -q TMUX_LIVES_TEST_UVARS`,
  not the bare variable name (a comment mentioning the name defeated the first version).

**Known isolation holes, unfixed:** the `tmux_lives_funcs_file` seam is a *variable*, so redirecting
`XDG_CONFIG_HOME` does not cover it; and `test-tmux-auto.fish`'s `tmux` shim is a fish **function** and
does not reach subprocesses — a subprocess under it returns the user's **real** sessions. The one site
that shells out is saved only by `TMUX=fake` failing to connect. Coincidence, not isolation: stub
directly, don't lean on it. See memory `[[tmux_test_isolation]]`.

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

- `test -e`, **not `-d`** — in a linked worktree or a submodule `.git` is a regular *file*. This project
  uses `git worktree` for isolated builds, so `-d` misses its own case.
- **Never** a `git rev-parse` subprocess. Per-session forks are what burned four cores on macOS.
- A generic walk result (`$HOME`, `/`, `/tmp`, `/var/tmp`) is treated as "no repo found" and falls back
  to the path's own basename — otherwise a dotfiles repo at `$HOME/.git` would collide every
  non-project directory into `name` / `name-2` / `name-3`.
- `session_path` is **strictly dominated**: it equals the pane path until a `cd` and is stale after one.
  Measured, seven of eight sessions sat at `$HOME`.

Sessions are born in the **invoking shell's cwd**. The one exception is `__tcz_commandeer`, which pins
`$HOME` **at its call site** (not inside `__tcz_new_general`, which has a second caller with a real cwd)
— it is reached via `client-attached` → `run-shell`, and `run-shell` executes at the tmux **server's**
cwd, an artifact of wherever the server was started.

Restored claude breadcrumbs **are stamped** (`@tmux_auto_name`). They used to be left unstamped so the
ownership guard would preserve their name; under pane-cwd naming that rationale died and the side
effect became the bug — unowned blocks both the rename and the display write, so a name froze at save
time while its pane moved on. The breadcrumb branch still `continue`s past the idle-kill; that half is
load-bearing.

Duplicate displays get a **bracketed ordinal** — `Sonos [1]` / `Sonos [2]`, brackets specifically
(a bare trailing number reads as an iteration count). Every member of a duplicate set is numbered
including the first. Ordered by **sorted session name** so it is stable across passes.

**Known, deliberately not fixed:** `__tcz_snapshot`/`__tcz_overview` recompose displays consulting only
the `@tmux_lives_name` claim, never ownership — so a genuinely hand-named session still renders its
*project* in the picker while every other surface shows its own name.

---

## The status tick and its cost

The status bar's `#(…)` job **is** the scheduler — there is no daemon. It runs the categorizer's `tick`
verb every `status-interval` (15).

**`status-right` is MERGED, not assigned.** tmux-continuum schedules its autosave by *prepending*
`#(continuum_save.sh)` to `status-right`; a bare `set -g status-right` discarded it and silently killed
snapshotting (macwork lost 52 hours of it). `__tcz_status_right_merge` keeps a foreign prefix and
replaces only our own part. The prefix is kept **only** if it is nothing but `#(…)` groups and
whitespace — a looser "contains `#(`" test would weld a user's decorated `#(uptime) %H:%M` on forever,
and tmux's *default* status-right must be dropped or we paint two clocks. Driven by a plain `run-shell`,
which is **synchronous** in tmux 3.3a (only `-b` backgrounds).

`set -ga update-environment` is guarded per name with `show -gv` + `grep -qx`. **`show -gv` prints one
name per line**, so `-x` is exact and load-bearing (a substring match lets `LC_TERMINAL_VERSION` satisfy
the `LC_TERMINAL` check). The `&&` makes it **fail closed** — a bare `! tmux … | grep` reads "absent"
whenever tmux is unreachable, which brought back 54 duplicate copies.

**Two batching layers, both one snapshot per pass, both flushed at the top of `__tcz_main`:**

- `__tcz_tmux_load` — four tmux calls per pass total: `show -g`, `list-sessions -F`, `list-panes -a -F`,
  and a lazily-loaded `list-clients -F`. Took the tick from **44 client spawns to 9** steady-state.
- `__tcz_ps_load` — one `ps` snapshot pair per pass, feeding all pid helpers.

⚠ **Both flush functions must use a GLOB, never a regex.** `string match -r` with a *prefix pattern*
returns the matched **substring**, so `string match -r '^__tcz_tmux_'` erases a variable literally named
`__tcz_tmux_` while every real entry silently survives. That bug shipped once in `__tcz_ps_flush`
(symptom: duplicate pids quietly accumulating).

**Staleness rule:** a memoized read is stale the moment something in the same pass writes what it reads.
Reading the pre-write snapshot is *correct* for a dedup comparison, wrong everywhere else. Flush
**after the write**, not before each read — otherwise every new read site must remember to add its own
flush, which is a required call that is easy to omit and impossible to notice missing.

`@tmux_lives_display` deliberately stays a **live** per-client `show-option` (not memoized): categorize
writes it earlier in the same pass, and `__tcz_tmux_flush` is a coarse glob whose blast radius would
evict the pane and client memos and undo the batching win in the same pass.

**Emission is deduped.** The tick emits OSC title/colour only when the value changed for that tty
(per-tty cache in `@tmux_lives_emit_<tty>_{title,color}`); discrete events force-emit. This killed a
ShellFish cursor flicker — the old tick wrote OSC 2 + OSC 6 every cycle unconditionally.
`__tcz_set_claude_opt` dedups for the same reason: **any** bar redraw re-emits the cursor.

⚠ **The empty-cache dedup gotcha:** `test "$x" = (__tcz_emit_get …)` **throws** when nothing is cached
(fish zero-word command substitution). Capture into a var and quote:
`set -l cached (…); test "$x" = "$cached"`.

**Verified in production 2026-08-20:** 0.33 ticks/sec with 5 clients against an implied `5÷15 = 0.33` —
the old 17× overshoot is gone and tmux-lives no longer appears in the host's top-5 CPU. An isolated
harness once showed a rate *inversion* at 16 clients; **it did not reproduce at real client counts** —
do not treat it as real behaviour. The self-rate-limit design
(`docs/superpowers/specs/2026-08-20-tick-self-rate-limit-design.md`) is APPROVED, NOT BUILT, and
**demoted to optional**.

---

## ShellFish / iTerm2 integration

Detection reads the attaching client's process environ (`/proc/<pid>/environ` on Linux, `ps eww` on
macOS) via `__tcz_pid_environ`; `__tcz_client_terminal` maps a pid to `shellfish` / `iterm2` / `other`
from `LC_TERMINAL`.

- **ShellFish** gets the bar colour as an OSC written directly to `#{client_tty}` — only that tab sees
  it. **iTerm2** mirrors it via an OSC 6 tab-colour triplet.
- **Everything else** triggers `tmux source-file ~/.tmux-lives.conf` to re-apply the user's own settings
  so ShellFish's forced options don't leak.
- Tab title is `[<h>] <dir> [(C)]`, where `<h>` is the **first character** of the short hostname — the
  tab strip is the scarcest space in the UI. `(C)` when any pane runs claude.
- A tab that silently drops its colour with no re-attach (iOS suspend/resume, mosh reconnect) is caught
  by a **colour-only backstop** re-emit every `@tmux_lives_heal_interval` seconds (default 120).

**The cursor strobe — there are TWO, check which before acting.** The discriminator needs no tooling:

| | Fires when | Fix |
|---|---|---|
| #1 | **Any** redraw, so an idle pane strobes too | `set -g cursor-style block` — a steady style is invisible when re-emitted. tmux's `cstyle` feature re-emits the style on every redraw and ShellFish resets the cursor each time |
| #2 | **Only** inside an actively-working Claude pane | `terminal-features xterm*:sync` |

#2's mechanism: `tmux info` reports `Sync: [missing]` for every ShellFish client and present for every
Ghostty client — **same server, same session, same `TERM`**. tmux picks synchronized-output support
**per client, at attach, from its own terminal identification, and never asks the client.** So ShellFish
implementing DECSET 2026 was necessary but never sufficient. Gated to **tmux ≥3.7** (3.3a emits the
older iTerm2 DCS form, and older tmux never answers the DECRQM query so Claude never enables sync —
immune by construction). The version probe uses `sort -V`, because a numeric compare gets 3.10 > 3.7
wrong. Universal `tmux_lives_sync_terminals`, fragment argv[17].

⚠ **Three testing traps here:** tmux **silently accepts an unknown feature name**; `source-file` returns
rc0 with **zero stderr** on a malformed line, so a parse test is vacuous; and a broken-looking quote
mutation still worked (tmux concatenates adjacent quoted strings), so validating the test needed a
commented-out inner command. See memory `[[shellfish_cursor_flicker]]`.

`tmux_lives_cursor_style` and `tmux_lives_sync_terminals` are **`set -U`-only** — neither has a `setup`
CLI setter. Known wart.

---

## Theme engine — where it actually stands

**v6 is wired and live in production code.** All three v5 call sites are gone — the fragment render,
`theme_apply_live`, and `setup theme list` all call `__tmux_lives_theme_render`
(`conf.d/tmux-lives-install.fish:116`, `:1606`, `:1640`). `__tmux_lives_theme_palette` (v5) stays
**defined** but has zero callers left in production; deleting it is a separate, trivially revertible
commit, not yet done.

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
arrangements per mode, all seven modes and all six arrangements reachable cold); `_v6_rest` is the other
28, under the picker's `More Schemes` header. `mono deep` is the one hand-placed row — the user's
repeatedly-favourite palette, kept for being liked, not for being the most robust (bound-1 margin 0.0050
against ≥0.0113 everywhere else).

**Migration (`__tmux_lives_migrate_v6`) resets to `mono deep`, preserving only the seed** — v5's
relationship/place/mode/phase have no v6 mapping, so nothing else survives. Idempotent, runs on
`fisher update`.

**The picker is retargeted**: `__tcz_theme_picker` sources the v6 catalog and renders through
`__tmux_lives_theme_render`; `z` now **rolls the real recipe space** with a session-local 12-entry roll
history, replacing the old geometric-scheme randomizer.

### The tie-break is now structural

The instability this file used to flag — the text-floor swap's strict-inequality float argmax flipping on
sub-0.005 engine perturbations and silently exchanging two roles' colours in a stored recipe — is
**fixed** (`febb67e`). `__tmux_lives_theme_rampidx` gives every role an **integer** ramp index;
`constrain`'s swap compares ramp-index distance, not lightness distance, whenever the arrangement pattern
is known (production always passes it). Integers are distinct by construction — no float tie to sit on. A
synthetic fixture with no pattern still falls back to the old float rule, deliberately.

### The v6 pipeline

Four pure stages, composed by `__tmux_lives_theme_render`:

1. **`__tmux_lives_theme_anchors`** — seed hue + harmony mode → 1–4 hue angles (the classical set). The
   seed is anchor one in every mode, which is why `analogous` uses offsets `0 -30 30`.
2. **`__tmux_lives_theme_ramp`** — seven `(L,C)` pairs. Lightness span, peak chroma and peak position
   are **independent** dimensions, and the window is positioned so the seed's own L falls inside it.
3. **`__tmux_lives_theme_arrange`** — six named permutations of ramp position onto role. **It is a PURE
   PERMUTATION.** Anything that substitutes a colour belongs in `constrain`, not here — several tests
   recover the role→ramp mapping by feeding it a fixture and seeing where each colour lands.
4. **`__tmux_lives_theme_constrain`** — four stages in a **fixed, load-bearing order**:
   big-role lightness clamp → big-role chroma clamp → no-white → **text-contrast floor LAST**
   (legibility is correctness, and every earlier stage can move `bar` or `text`).

Roles: `bar sep tabs active windows cap text`. "Big three" = `bar`/`tabs`/`cap`.

### The three bounds

Reverse-engineered from palettes the user had already praised, then falsified with seven one-property
perturbations — **predictions written down before they looked, all seven correct.**

| | Bound | Enforced? |
|---|---|---|
| 1 | Peak chroma **0.105–0.180** | **No, and no clamp can.** At a dark seed the sRGB gamut caps peak chroma near 0.082 however much a recipe requests. It belongs to whoever curates recipes — the 42-row catalog above |
| 2 | Big-three **mean** chroma ≤ **0.095** | Yes — scaled down together so the three keep their relative structure rather than flattening to one value |
| 3 | Big-three max lightness ≤ **0.70** | Yes — **but the clamp targets 0.695** |

⚠ **Do not tidy 0.695 to 0.70.** The extra 0.005 is quantisation headroom: the chroma clamp that runs
next re-encodes those roles, and an 8-bit round trip pushes lightness back over a 0.70 target. 46
renders breached before this, 13 at the design's own seed `#87cb48`. **The obvious alternative fix was
tried and proven wrong** — a sequential bound-3 re-check after the chroma clamp clears those breaches
but introduces bound-2 breaches, because re-encoding at lower lightness can round-trip to *higher*
chroma below the gamut cusp. The two clamps genuinely fight at the quantisation floor.

**Hue is not one of the bounds.** The decisive experiment put the exact hue the user called "just awful"
on `tabs` twice — L 0.51 (fine) and L 0.88 (not). Same hue, same role. Nothing was ever counting hues;
bound 3 was checking whether a large surface had gone pale.

### The headline result

Across 3,024 renders (12 seeds × 7 modes × 6 arrangements × 6 recipes) the engine produces **3,024
distinct palettes**, peak chroma **0.055–0.250** (median 0.114) against v5's pinned ~0.063, and **the
clamps bind in only ~14% of renders** — they trim outliers rather than defining the output. v5's 35
catalog rows were one palette shape with the hue nudged; this is the opposite, which is the whole reason
the rewrite existed.

### Still open

**All six arrangements place `text` at ramp index 1 or 7** (both ends of the chroma curve), so at
`peakPos ≈ 0.5`, `text` renders at C 0.011–0.013 — *below* v5's pinned 0.030. Not resolved this cycle and
not blocking; a curated recipe can avoid a mid-ramp `peakPos` if it matters in practice.

### OKLCH facts that make an assertion unsatisfiable if guessed

- **`peakC` is a request, not a guarantee** — the sRGB gamut caps it and the cap is **hue-dependent**:
  0.260 at purple, 0.254 at red, but 0.153 at green and 0.140 at cyan.
- **Hue families must be counted with a 25° tolerance, circularly** — never as distinct rounded hues.
  `mono` reports **four** distinct rounded hues, because every colour round-trips through sRGB and the
  gamut clamp shifts it. A linear sort also splits an anchor near 0/360 into two clusters.
- **The text floor needs two stages.** A swap alone cannot rescue a mid-ramp bar (measured: `centre`
  reaches only 0.309 against a 0.40 floor); stage two pushes text's *lightness* to `bar ± 0.40`. Stage
  two then needs a bounded correction loop checking the **round-tripped hex**, because 8-bit
  quantisation makes a target placed exactly on the floor round just under it.
- **Stage two does NOT preserve chroma** (hue yes, 0.1–0.5°). sRGB has no chroma headroom near white,
  so pushing `text` to `bar + 0.40` on the light side destroys chroma by construction — losses run
  20–74%, reaching 93% at C 0.20 / H 290.
- The no-white chroma floor has only ~0.00275 of gamut margin at its worst point (C 0.0577 available at
  L 0.88 / H 269 against 0.055 required). Moving either the 0.88 ceiling or the 0.055 floor can put the
  pair out of reach at the blue-violet end and stall the nudge loop.

See memories `[[theme_engine_v6]]`, `[[three_bounds_palette_rule]]`,
`[[never_white_and_muted_is_a_destination]]`.

---

## The picker (theme + session)

Both are `display-popup` UIs drawn by `functions/tmux-categorize.fish`.

**Geometry facts, measured — not guessed:**
- A popup **taller than the client does not clamp: it refuses to open** (`height too large`). That is
  why the theme picker uses `-w 52 -h 85%` and not a constant.
- **No tmux command resizes an open popup.**
- `stty size` **does** report a popup's own size (`$LINES`/`$COLUMNS` are not exported into it).
- `-w/-h` percentages work and are exact; `-w '#{client_width}'` is rejected.
- `WIN = rows - STATIC`, with `STATIC_IDLE 17` / `STATIC_EDIT 22`. The admission floor gates on the
  **stricter** `STATIC_EDIT` (25 popup rows = 30 client rows) — an idle-only floor admitted a 20-row
  popup that overflowed the instant `b` was pressed.

**Performance — three layers, all measured:**
1. **Construction.** The cost is the **number of fish command substitutions**, not any one builder: a
   function call inside `(…)` costs 0.108 ms against 0.0057 ms for a plain call — **19×**. Fixed by
   memoizing row/static/swatch builders behind **one** clear helper called from **one** place
   (`__tcz_thp_reload`) — that single invalidation point is what makes a bare-integer row key legal.
   Result: 167 ms → 35 ms whole-frame.
2. **Emission.** `__tcz_popup_emit` diffs against `__tcz_pe_prev` and emits only changed rows inside a
   sync wrapper, full-painting when forced or when the row **count** differs. A burst of 40 arrows costs
   47 KB vs 458 KB; **isolated keypresses are 11.7% worse** (break-even ≈ 1.07 keys per 0.7 s window).
   The session switcher is deliberately **out of scope** — its cursor move changes nearly every row.
3. **Input.** One rule on every held-key path: **discard, one step per frame.**
   ⚠ `stty min 0 time 0` **must be re-asserted INSIDE every drain loop**, because readkey's CSI branch
   leaves the tty blocking. ⚠ The arrow poll must **never** escalate its timeout — the loop breaks only
   on a poll *timeout*, so a ~100 ms gap never times out while autorepeat outpaces it, and the picker
   stalls completely.

**tmux 3.3a DROPS app-sent DECSET 2026** (a bogus `?9999` behaves identically — tmux does not forward
private modes it does not implement). So the sync wrapper never reaches ShellFish there and it paints
progressively: the symptom is *stuttering*, not a frozen screen.

**Seed editor:** `a` = "show me what this seed does" (rebuild strips, stay in the editor). `⏎` = "this
is the seed — apply it and let me out". Both are **local** — no tmux option, no tab OSC. Applying the
seed to the schemes is not adopting a scheme. Staleness is **derived** from `$stripseed` (the seed the
strips were actually built from), not tracked as a flag — a flag cannot answer "edit, press `a`, then
`esc`", where the seed reverts but the strips still show the abandoned edit. Stale strips render faint,
and **the dim state is part of the row cache key**.

**Auto-apply was built, tried live and REJECTED** ("wayyyy too much… everything is so lacking in
responsivity"). Do not re-propose it; a toggle does not rescue a feature whose cost is felt unasked.
See memory `[[config_vs_adoption]]`.

---

## macOS

Runtime-only persistence (no launchd units; continuum autosave + first-access restore), `/proc`→`ps`
detection, bare cold-start on first attach. Install: `fisher install bit-saver/tmux-lives` then
`tmux-lives setup install`.

**`pgrep` is the expensive primitive on macOS and `ps` is the cheap one — the Linux intuition inverts.**
`/usr/bin/pgrep` links `libsysmon.dylib` and delegates to the `sysmond` **root daemon**, which walks
every process *and every thread* per call; `/bin/ps` does not. It sat at ~4 of 14 cores, 0.4% idle, fan
63%, on an idle desktop. The cost is also **invisible from inside** — a tick reporting 0.23 s user +
0.25 s system takes 1.280 s wall, because the missing time is billed to another process's ledger.
`pgrep` is now **absent from the file entirely**. See memory `[[macos_pgrep_sysmond]]`.

**Two settled dead ends — do not re-chase:**
- **`reattach-to-user-namespace` as `default-command` is a proven no-op** on macOS 26.5.2. GUI
  window/menu-bar placement is governed by the Aqua **audit session** `asid`, not the bootstrap domain.
  `pbcopy`/`pbpaste` and `open -a` already work. Findings: `docs/macos-gui-namespace-findings.md`.
- The `-ww` rationale for `ps` **did not survive Mac verification** — no truncation was measured with or
  without it. `-ww` stays because it is free and correct on any BSD `ps` that *does* truncate, but read
  it as cheap insurance, not as the fix for a demonstrated failure.
  Details: `docs/2026-08-18-verification-pgrep-sysmond-fix-on-macos.md`.

---

## Standing decisions — do not reopen

- **NO WHITE is a hard exclusion** (settled 2026-08-25). The ruling went ban → prior → **ban**; the user
  named the bias themselves and chose it anyway. Do not re-offer white "where it fits".
- **Muted is a style the user LIKES.** The defect was ever only **fixedness**, not dimness. Raising the
  ceiling relocates the single destination and costs a style they want.
- **Hue placement is NOT what makes a palette work.** Refuted three ways. Do not build another
  hue-placement rule.
- **Cohesion is a curve, not uniformity.** Forcing one hue family produced a palette judged *less*
  cohesive: in the liked palette the tiny `sep` separators carry the **highest chroma in the whole
  palette**, and flattening crushed it. **Never hand-assign a role colour** — always sample the ramp.
- **`arrange` stays a pure permutation.** Substitution belongs in `constrain` only.
- **The constrain order is fixed** and each stage's placement is load-bearing.
- **Bound 1 is the catalog's problem, not the engine's.**
- **The user runs `fisher update`.** A Claude session never deploys.
- **Plans are deleted once their work ships;** specs for shipped features stay.
- **ShellFish's tab bar is the optimization target**, not the tmux status bar (`tabs` ≈ 1.8× `bar` by
  area on the real screen). Every colour mockup renders both a ShellFish and a cmux view; ShellFish
  decides, cmux gets a veto for "actively bad".
- **Colour/UI mockups must be a faithful facsimile of the real widget**, not abstract swatches.

---

## Traps that cost real time

**Environment**
- **The agent Bash tool runs zsh.** A non-matching glob **aborts the whole command** — an `rm -rf a/* b/*`
  silently did nothing because the second glob had no matches. Use `find … -delete`. MULTIOS also makes
  `cmd 2>&1 >/dev/null | wc -c` leak stdout into the pipe; wrap stderr counts in `bash -c '…'`.
- **Never `find /` on this host** — two CIFS mounts park a whole-fs scan in uninterruptible D state
  where even SIGKILL sits pending. One orphan took load to 76.
- **The code-review-graph MCP indexes 0 files here** — no fish parser exists. The global "use the graph
  before Grep" rule does not apply in this repo.
- **When a subagent is editing a file, measure from `git show`, not the worktree.** A stderr measurement
  taken mid-edit was wrong by 141 bytes and led to deferring a real defect.

**fish** (see memory `[[fish_gotchas_that_lie]]` — these return a confidently *wrong* answer, not an error)
- `eval` returns status **0** on a parse error, and its `math` diagnostics **bypass in-process `2>`**.
- A variable is never word-split into command + args; a keyword arriving via expansion is rejected. There
  is **no** variable form of a seamed command — spell it out in both branches.
- **`printf --` is not an option terminator** — fish takes `--` as the format string and discards the
  rest. It wrote a 2-byte history seed and left a shipped guard permanently vacuous.
- Autoloaded functions **never reload** when their file changes; redefinition is **silent**.
- A **double-quoted** `"$x[(math …)]"` list index is an *error*, not an index. Grep-guarded.
- A zero-output command substitution collapses the whole enclosing argument to an empty list.
- `string match -r` with a prefix pattern returns the **matched substring**, not a boolean.

**tmux 3.3a** (see memory `[[tmux_target_quirks]]`)
- A **purely numeric session name** — which every fresh session has — resolves in `-t` as the **current**
  session, and **`=` does not rescue it**; only `-t '$id'` is right. Hence two helpers:
  `__tcz_session_target` (bare-or-id, for `set-option`/`show-option`/`capture-pane`) and
  `__tcz_pane_target` (`=name`-or-id, for `list-panes`). Both cost zero tmux calls for non-numeric names.
- `set-option`/`show-option` **reject** `=name`; so does `capture-pane`.
- An **unquoted `#hex`** option value is a tmux **comment** — the option silently goes empty and
  `source-file` still returns rc0.
- tmux **silently accepts an unknown `terminal-features` name**.
- A `-L` test socket still loads `~/.tmux.conf` unless started `-f /dev/null`.

**Testing** (see memory `[[sdd_assertion_discipline]]`)
- **A test whose command substitution calls an undefined function does not fail** — fish aborts the whole
  statement, nothing prints, and a suite with no pass counter still reports `ALL PASS`.
- **A guard can be green by sampling luck.** The bounds ratchet passed while 46 renders breached; moving
  `peakC` one step (0.13 → 0.14) turned it red. Perturb a sampling grid before trusting it.
- **Grep guards match COMMENTS.** Describing a banned shape in prose has tripped its own guard twice.
- **A vacuous assertion is the default failure mode here** — the `$src`-expands-to-empty class has bitten
  seven times. Bound every body-grep to a variable defined *above* it, and pair it with a positive count.
- **Modifying a pre-existing guard is the highest-risk edit in the file.** One retarget silently reduced a
  capture to 8 bytes so its guard printed `no` unconditionally, suite green.
- **You cannot pin the "no big role on a light ramp index" invariant with a rendered-output fixture.**
  Tried twice — the stage-1 swap hunts for exactly the colour a violation places, so it relocates the
  offender before the check sees it. Assert the table directly by `awk`-extracting the `switch` block
  from source, **with a vacuity guard** (an empty extraction otherwise passes by matching nothing).
- **`__t6_inbounds` is blind below ~5e-7** because fish's `math` rounds the mean chroma it compares.
- **Never `git checkout` to revert a mutation** while work is uncommitted — it reverts to HEAD. Restore
  from a file copy taken immediately beforehand and prove byte-identity with `diff`.
- **A mutation battery proves the mutations you chose were caught, not that your assertions are awake.**
- The recurring shape, confirmed ten times: **an invariant one stage establishes is not one a later stage
  is obliged to preserve.** A fixed order is necessary, not sufficient.

---

## Next work

**The theme surface plan shipped this cycle** (`feat/theme-v6-surface`) — v6 is wired, the tie-instability
finding is fixed, and the two specs this section used to point at are both fully built. See the theme
engine section above for what actually changed; `git log` on that branch for the ordered commits.

**Two things left open, both noted above, neither blocking:** `text` always sits at a ramp end (see
"Still open" under Theme engine); and `__tmux_lives_theme_accents` (the v5 sep/active/windows/text tint
function) is now dead code — v5 has zero production callers — a candidate for the same future cleanup
that deletes `__tmux_lives_theme_palette` itself.

**Deployment status:** the live install on rocket and macwork predates this cycle, so it has none of the
v6 surface wiring, the 42-row catalog, or the structural tie-break fix. The user must run `fisher update`
themselves — doing so will visibly change their bar: the stored `amber / cap / derived` has no v6
equivalent and migrates to `mono deep` (their seed survives).

---

## Where the history lives

- **`docs/history/2026-09-02-claude-md-full-archive.md`** — the verbatim 231 KB `CLAUDE.md` as it stood
  before this prune. History, not guidance.
- **git** — `git log --diff-filter=D -- <path>` finds the commit that removed any deleted doc.
- **The memory store** (`~/.claude/projects/-home-bitsaver-workspace-tmux-lives/memory/`) — the deep war
  stories, indexed by `MEMORY.md`. This is the durable knowledge layer; **prefer adding depth there over
  growing this file.**

### claude-mem

This project was extracted from `~/.config/fish`; its development history through **2026-06-17** is
labelled **`fish`** in claude-mem, not `tmux-lives`. When searching prior work, query
`project: "fish"` as well (terms: tmux, auto-tmux, categorize, shellfish, resurrect). New observations
from this repo are tagged `tmux-lives`.
