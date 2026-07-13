# Cap-picker v2 + tl theme palette — Design

**Status:** approved (visual + scope) 2026-07-13, brainstormed with the visual companion. Follows Phase A (cap-picker polish). Deploy user-only via `fisher update`.

## Goal
Redesign the cap-color picker and introduce a small reusable **tmux-lives theme palette**. Four threads:
1. **tl theme palette** — a named color set (brand orange + border/key/muted/value/selection roles), defined once so the picker (and later other menus) draw from named roles, not scattered literals.
2. **Flat scheme list** — every scheme variant is its own row (`↑↓` reaches all); `←→` is freed from direction-flipping.
3. **`←→` cap-role shift** — choose which palette column (dim/muted/accent) becomes the cap, via a stored `cap_role` plumbed through the render fragment + CLI (so the bar actually renders the chosen column, not just a preview).
4. **New scheme `square`** + the redesigned layout (primary cluster, aligned footer, gray selection, right-aligned legend on the `d m a` row).

## Non-goals (Phase B, separate spec later)
- Restyling the modal + switcher menus to the tl palette (the palette is *defined reusably* now; retrofit is a fast-follow).
- Setting the primary/bar color from inside the picker.
- Whole-bar theming (spreading dim/muted/text across the bar).

## Global constraints
- fish 4.7.1, tmux 3.3a+/3.6b, no new deps. Touch `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, and the two test files.
- The picker runs `fish --no-config` → it CANNOT read fish universals directly; it reads config via a config-loaded `fish -c` (already does, for the palette batch) and holds the theme palette as **inline constants** (static brand colors, not user-configurable this round).
- Terminal supports truecolor (swatches already use it). Theme colors emit as SGR (truecolor `\e[38;2;r;g;bm`).
- Test isolation: `-L` socket via `tmux_lives_tmux_socket`; `set -U` tests save/clear/restore (no leak); stub `__tmux_lives_write_fragment` where a command re-renders. `≥1 space` between every rendered field (the padder enforces).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## 1 · tl theme palette
A small accessor in the categorizer, e.g. `__tcz_theme <role>` → the SGR escape for that role (or a set of `set -l` vars seeded once in the picker). Roles + values:

| role | hex | used for |
|---|---|---|
| `brand` | `#ff8a1f` | title, brand accents |
| `border` | `#a86a2c` | frame lines (`╭│╰├┤`) |
| `key` | `#f5cf8a` | keys (`↑↓ v w ⏎ esc`) **and** field labels (`primary scheme role wheel vividness`) |
| `muted` | `#9a8a72` | descriptions, unselected scheme names, the legend words |
| `value` | `#6fc7b8` | values (`#hex`, `ryb`, `vivid`) |
| `sel-bg` | `#34332f` (neutral gray) | selected-row background — gray so it doesn't tint the swatch trio |
| `sel-fg` | `#f2efe9` | selected scheme name |

The picker uses these named roles everywhere (no ad-hoc `\e[38;5;208m`). Reusable verbatim by the modal/switcher in Phase B.

## 2 · Flat scheme list
- `__tcz_cap_families` returns the flat token list: `mono complementary analogous+ analogous- split+ split- triadic+ triadic- tetradic square` (10 rows).
- The picker's `←→` no longer calls `__tcz_cap_flip` (each direction is its own row). `←→` is repurposed for the role-shift (§3). `__tcz_cap_flip` becomes unused by the picker — remove it and its tests (dead after this change).
- `__tcz_cap_restore` (Phase A) already maps a stored formula → its row; with the flat list it's a direct token-index match. Extend restore to ALSO read `tmux_lives_cap_role` and position the active column.

## 3 · New scheme `square`
Add `square` to: `__tmux_lives_cap_valid` (whitelist), `__tmux_lives_palette`'s switch, and `__tcz_cap_families`. Offsets: **primary +90, secondary +270 (−90)**. Note: `square` shares `tetradic`'s default *accent* hue (+90) but has a distinct *muted* (+270) — visible in the strip and via the role-shift; the scheme set is trivially extensible for more-distinct schemes (e.g. analogous-wide ±60) as a later add. Lock the palette hexes from the fish engine in tests.

## 4 · `←→` cap-role shift (the plumbing — the load-bearing part)
The cap is no longer hard-wired to `accent`; the user picks `dim`/`muted`/`accent`.
- **New universal `tmux_lives_cap_role`** ∈ `{dim,muted,accent}`, default `accent`. Role→palette index: `dim`=`$pal[2]`, `muted`=`$pal[3]`, `accent`=`$pal[4]`.
- **Fragment** — `__tmux_lives_render_fragment` gains **argv[16] = cap_role** (empty → `accent`). The cap seed computes `set -l pal (__tmux_lives_palette $barbg $cap $wheel $vividness)`, then `capbg = $pal[<role-index>]` (map role→index; empty/unknown → accent), `capfg = __tmux_lives_contrast_fg $capbg`. The `write_fragment` call site appends `(__tmux_lives_key tmux_lives_cap_role accent)`.
- **CLI** — `__tmux_lives_cap_apply_live` computes `capbg` from the stored role (not `$pal[4]`). `__tmux_lives_cap_cmd` gains `--role <dim|muted|accent>` (validate, `set -U tmux_lives_cap_role`, apply live), alongside the existing positional scheme + `--vividness`/`--wheel`.
- **Picker** — `←→` cycles the active role (`dim`↔`muted`↔`accent`); the swatch strip outlines/marks the active column, the `d m a` header highlights the active letter (`key` color), and the primary cluster's `role` value + swatch + `#hex` track it. `Enter` applies via `fish -c 'tmux-lives setup cap <scheme> --role <role> --vividness <v> --wheel <w>'`.
- Restore-on-open restores formula + role + v/w from the universals.

## 5 · Picker layout (redesign — see the approved v7 mock)
Rows, all drawn with the tl palette + the `__tcz_cap_ln` padder (≥1 space between fields, borders/corners aligned):
```
╭─ cap color ───────────────────────────╮
│ primary      scheme      role          │   labels row (key color)
│ ▪ #f66336    triadic−    accent         │   values (swatch+value, muted, muted)
├────────────────────────────────────────┤
│ d  m  a              d dim · m muted · a accent │  col heads (active=key) + right-aligned legend
│ ▪ ▪ ▪   mono                            │   flat scheme rows; active column outlined
│ …analogous+/-, split+/-, triadic+/-, tetradic, square… │
│ ▪ ▪ ▪   triadic−        (selected: gray bg, bright name) │
├────────────────────────────────────────┤
│ ↑↓ scheme    ←→ cap role                │   footer: keys (key color) + desc (muted), aligned cols
│ v  vividness w  wheel                   │
│ ⏎  apply     esc cancel                 │
├────────────────────────────────────────┤
│ wheel ryb    vividness vivid            │   status: labels (key) + values (value color)
╰────────────────────────────────────────╯
```
- Selection = **neutral gray** bg + bright name (no orange marker biasing the swatches).
- Primary cluster = **cluster A** (label row / value row, 3 aligned columns: primary/scheme/role).
- Legend `d dim · m muted · a accent` (letter=key, word=muted) **right-aligned on the `d m a` row**.
- Terminology: **scheme** everywhere (the harmony name) + **role** (dim/muted/accent). See §7.

## 6 · Popup sizing
The redesigned picker is ~19–20 rows tall, ~40 cols wide. Bump the host `display-popup` height/width at all three open sites: `__tmux_lives_cap_picker` (install.fish, currently `-w 34 -h 15`), the `M-k` bind (fragment), and the `M-m` modal `k` deferred open — to about `-w 44 -h 22` (final values tuned on smoke). Keep them consistent.

## 7 · Terminology rename: `formula` → `scheme`
For consistency (the picker, CLI, and docs must use one word), rename the user-facing term to **scheme** everywhere:
- **CLI** — `setup cap <scheme>`: the help row (`cap [<scheme>] [list]  …`), the three `setup cap` error/usage strings, and every `<formula>`/"formula" placeholder become `<scheme>`/"scheme". The positional value tokens (`mono`/`triadic-`/`#hex`/…) and the universal `tmux_lives_cap` are unchanged — only the *label* changes.
- **Internal** — rename the `formula` argument/local names to `scheme` in the functions this build already edits (`__tmux_lives_palette`, `__tmux_lives_target_hue` if touched, `__tcz_cap_restore`, `__tmux_lives_cap_cmd`) and their call sites/tests, so code-level naming matches. Function names themselves (`__tmux_lives_cap_valid`, `__tmux_lives_cap_cmd`, `__tcz_cap_*`) stay — only the "formula" *word* goes.
- **Docs** — CLAUDE.md / memory references say "scheme".

## Testing
- **Unit (pure):** `__tcz_cap_families` (flat, 10, incl `square`); `__tcz_cap_restore` (flat token→index; role restore); the theme accessor (`__tcz_theme accent` → expected SGR); `__tcz_cap_swatch_line` (3-cell strip + active-column marker); the palette generator `square` case (locked hex); `__tmux_lives_cap_valid` (+`square`; `--role` values).
- **Fragment/CLI:** `render_fragment … <cap_role>` (argv[16]) → cap = `palette[role]` (assert dim/muted/accent each pick the right hex); `setup cap --role muted` sets the universal + applies live (save/restore, no leak); default (no role) → accent (existing behavior preserved).
- **Manual smoke (runtime, after `tl update`):** full picker visual (palette, alignment, gray selection, right-aligned legend); `←→` role-shift live (cap changes to the chosen column, primary/header track it); restore-on-open (formula+role); the taller popup at `M-k` and `M-m`→`k`; `square` renders.

## Self-review notes
Scope coverage: palette →§1; flat list →§2; square →§3; role-shift →§4; layout →§5; popup →§6. The role-shift is the only cross-file plumbing (universal + fragment argv + CLI flag). `←→` is cleanly reassigned (flat list removes the flip). Names: `tmux_lives_cap_role`, `__tcz_theme`, argv[16]. Non-goals (modal/switcher retrofit, primary-in-picker, whole-bar) explicitly deferred.
