# Cap-picker v2 + tl theme palette — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) tracking.

**Goal:** A reusable tmux-lives theme palette + a redesigned flat cap-picker with `←→` cap-role shift (dim/muted/accent as the cap, plumbed through the fragment + CLI), a new `square` scheme, and a `formula`→`scheme` rename.

**Architecture:** New named-color accessor `__tcz_theme` in the categorizer; `__tmux_lives_palette`/`cap_valid`/`cap_cmd` gain `square` + the `scheme` rename; a `tmux_lives_cap_role` universal threads through `__tmux_lives_render_fragment` (argv[16]) + `__tmux_lives_cap_apply_live` + `setup cap --role`; `__tcz_cap_picker` is rebuilt (flat list, tl palette, primary cluster, role-shift, aligned footer).

**Tech Stack:** fish 4.7.1; tmux 3.3a+/3.6b; truecolor SGR; existing `-L`-socket + stub test harnesses; the switcher/modal `__tcz_cap_ln`/`__tcz_cap_sep` frame helpers.

## Global Constraints
- fish 4.7.1, no new deps. Only `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`.
- The picker runs `fish --no-config`: no direct universal reads; config values come via a config-loaded `fish -c`; the theme palette is inline constants.
- **tl theme palette** (truecolor SGR): brand `#ff8a1f`, border `#a86a2c`, key `#f5cf8a`, muted `#9a8a72`, value `#6fc7b8`, sel-bg `#34332f`, sel-fg `#f2efe9`. `key` = keys **and** labels; `value` = values; `muted` = descriptions/unselected.
- **Cap role → palette index:** `dim`=`$pal[2]`, `muted`=`$pal[3]`, `accent`=`$pal[4]`. Universal `tmux_lives_cap_role` default `accent`.
- **scheme** is the user-facing word everywhere (CLI `setup cap <scheme>`, errors, picker, docs). Tokens (`mono`/`triadic-`/`#hex`) + universal `tmux_lives_cap` unchanged.
- `square` offsets: primary +90, secondary +270 (−90). Lock the fish palette hex in tests.
- Colors emitted into the fragment are single-quoted. Multi-value returns via `printf "%s\n"` + list index. `≥1 space` between rendered picker fields. Fish gotchas: no `math` comparisons; capture zero-output substitutions into a var.
- Test isolation: `-L` socket via `tmux_lives_tmux_socket`; `set -U` tests save/clear/restore; stub `__tmux_lives_write_fragment` where a command re-renders. Run `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`, pristine. (Bash tool shell is POSIX; run each suite `fish tests/test-NAME.fish`; big suites ~40-50s, run individually.)
- Deploy user-only via `fisher update`. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: tl theme palette accessor `__tcz_theme`

**Files:** `functions/tmux-categorize.fish` (add near the other pure `__tcz_cap_*` helpers, ~line 1062). Test `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_theme <role>` → the truecolor SGR escape for that role; `reset` → `\e[0m`.

- [ ] **Step 1 — failing tests:**
```fish
t "theme brand is truecolor ff8a1f" 1 (test (__tcz_theme brand) = (printf '\e[38;2;255;138;31m'); and echo 1; or echo 0)
t "theme key is f5cf8a"    1 (test (__tcz_theme key)    = (printf '\e[38;2;245;207;138m'); and echo 1; or echo 0)
t "theme value is 6fc7b8"  1 (test (__tcz_theme value)  = (printf '\e[38;2;111;199;184m'); and echo 1; or echo 0)
t "theme selbg is 34332f bg" 1 (test (__tcz_theme sel-bg) = (printf '\e[48;2;52;51;47m'); and echo 1; or echo 0)
t "theme reset" 1 (test (__tcz_theme reset) = (printf '\e[0m'); and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:**
```fish
function __tcz_theme --argument-names role --description 'tl theme palette -> truecolor SGR for a named role (brand/border/key/muted/value/sel-bg/sel-fg/reset)'
    switch $role
        case brand;  printf '\e[38;2;255;138;31m'
        case border; printf '\e[38;2;168;106;44m'
        case key;    printf '\e[38;2;245;207;138m'
        case muted;  printf '\e[38;2;154;138;114m'
        case value;  printf '\e[38;2;111;199;184m'
        case sel-bg; printf '\e[48;2;52;51;47m'
        case sel-fg; printf '\e[38;2;242;239;233m'
        case reset;  printf '\e[0m'
    end
end
```
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): tl theme palette accessor __tcz_theme`.

---

### Task 2: `square` scheme + `formula`→`scheme` rename

**Files:** `conf.d/tmux-lives-install.fish` — `__tmux_lives_palette` (~637, arg + `square` case), `__tmux_lives_cap_valid` (~752, whitelist), `__tmux_lives_cap_cmd` (~818, desc/help/errors/arg), the error string (~871), the setup-help cap row (~991); `functions/tmux-categorize.fish` — `__tcz_cap_families` (~1062, add `square`), `__tcz_cap_restore` (~1066, arg rename). Tests both files.

**Interfaces — Produces:** `__tmux_lives_palette baseHex scheme wheel vividness` (arg renamed); `square` a valid scheme.

- [ ] **Step 1 — failing tests** (lock the fish hex for `square` — compute it once and paste; if the run differs, lock the actual value):
```fish
# in test-tmux-install.fish
t "palette square accent (#36442d,ryb,vivid)" "<LOCK>" (set -l p (__tmux_lives_palette "#36442d" square ryb vivid); echo $p[4])
t "cap_valid accepts square" 0 (__tmux_lives_cap_valid square; echo $status)
t "setup help says <scheme> not <formula>" 1 (string match -q '*<scheme>*' -- (__tmux_lives_setup_help_lines | string collect); and string match -q '*<formula>*' -- (__tmux_lives_setup_help_lines | string collect); and echo 0; or echo 1)
t "invalid scheme error says scheme" 1 (__tmux_lives_cap_cmd wat 2>&1 | string match -q '*invalid scheme*'; and echo 1; or echo 0)
# in test-tmux-categorize.fish
t "families include square" 1 (contains square (__tcz_cap_families); and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:** in `__tmux_lives_palette`, rename `--argument baseHex formula …` → `… scheme …` (and every `$formula`→`$scheme` in the body); add `case square; set po 90; set so 270` to its offset switch. Add `square` to `__tmux_lives_cap_valid`'s whitelist `case` line and to `__tcz_cap_families`. Rename `__tcz_cap_restore`'s `--argument-names formula` → `scheme` (+ body). In `__tmux_lives_cap_cmd`: rename the local/desc `formula`→`scheme`; change the help/usage `<formula>`→`<scheme>`; change the error string to `invalid scheme '<scheme>' — valid: …, tetradic, square, or #rrggbb`. Update the setup-help cap row `cap [<scheme>] [list] …`. (Compute `<LOCK>` = `fish -c 'source conf.d/tmux-lives-install.fish; set -l p (__tmux_lives_palette "#36442d" square ryb vivid); echo $p[4]'` and paste it into the test.)
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): add square scheme + rename formula->scheme`.

---

### Task 3: flat scheme list + role-aware restore

**Files:** `functions/tmux-categorize.fish` — `__tcz_cap_families` (~1062), `__tcz_cap_restore` (~1066), remove `__tcz_cap_flip` (~1079); tests.

**Interfaces — Produces:** `__tcz_cap_families` → flat 10-token list; `__tcz_cap_restore <scheme> <families…>` → 0-based index of the exact token (or -1).

- [ ] **Step 1 — failing tests:**
```fish
t "families flat = 10 tokens" 10 (count (__tcz_cap_families))
t "families order" "mono complementary analogous+ analogous- split+ split- triadic+ triadic- tetradic square" (__tcz_cap_families | string join ' ')
set -g FAM (__tcz_cap_families)
t "restore exact triadic-" 7 (__tcz_cap_restore triadic- $FAM)
t "restore exact mono" 0 (__tcz_cap_restore mono $FAM)
t "restore exact square" 9 (__tcz_cap_restore square $FAM)
t "restore #hex -> -1" -1 (__tcz_cap_restore "#123456" $FAM)
t "cap_flip removed" 0 (functions -q __tcz_cap_flip; and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:** `__tcz_cap_families` returns the flat list `printf '%s\n' mono complementary analogous+ analogous- split+ split- triadic+ triadic- tetradic square`. Rewrite `__tcz_cap_restore` to return the **exact** index of `$scheme` in `$families` (via `contains -i`, minus 1), or `-1`. Delete `__tcz_cap_flip` and its Phase-A tests (grep `__tcz_cap_flip` in the test file and remove those assertions).
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): flat scheme list + exact-token restore (drop cap_flip)`.

---

### Task 4: `cap_role` — render fragment (argv[16]) + cap seed

**Files:** `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` arg block (~line 30, after `capkey`), the cap seed (`set -l capbg $pal[4]`, ~line 90), the `write_fragment` call site (~219). Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Task 2 palette. `render_fragment` gains **argv[16] = cap_role** (empty → `accent`).

- [ ] **Step 1 — failing tests** (bar `#1f6feb`→bar_bg `#5793f0`; assert each role picks the right palette index):
```fish
set -g RP (__tmux_lives_palette "#5793f0" mono ryb vivid)
set -g FR_ACC (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent | string collect)
t "cap_role accent -> pal[4]" yes (string match -q "*@tmux_lives_cap_bg '"$RP[4]"'*" -- "$FR_ACC"; and echo yes; or echo no)
set -g FR_DIM (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k dim | string collect)
t "cap_role dim -> pal[2]" yes (string match -q "*@tmux_lives_cap_bg '"$RP[2]"'*" -- "$FR_DIM"; and echo yes; or echo no)
set -g FR_DEF (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k '' | string collect)
t "empty cap_role defaults accent" yes (string match -q "*@tmux_lives_cap_bg '"$RP[4]"'*" -- "$FR_DEF"; and echo yes; or echo no)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:** add `set -l caprole $argv[16]; test -n "$caprole"; or set caprole accent` after the `capkey` arg. Add a role→index map and use it in the cap seed — replace `set -l capbg $pal[4]` with:
```fish
    set -l ridx 4
    switch $caprole
        case dim; set ridx 2
        case muted; set ridx 3
    end
    set -l capbg $pal[$ridx]
```
Append `(__tmux_lives_key tmux_lives_cap_role accent)` as argv[16] at the write_fragment call site. (Existing callers pass ≤15 args → `caprole` empty → accent → unchanged behavior; confirm existing cap_bg fragment tests still pass.)
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): render cap from the chosen role (dim/muted/accent) via argv[16]`.

---

### Task 5: `cap_role` — CLI `setup cap --role` + apply-live

**Files:** `conf.d/tmux-lives-install.fish` — `__tmux_lives_cap_apply_live` (~796), `__tmux_lives_cap_cmd` (~818, add `--role` parse). Test `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Task 4's role→index. `setup cap --role <dim|muted|accent>`.

- [ ] **Step 1 — failing tests** (pin `-L` socket; save/clear/restore `tmux_lives_cap_role` like the other universals; reuse the file's write_fragment stub idiom):
```fish
t "cap --role sets universal" muted (…__tmux_lives_cap_cmd --role muted >/dev/null; echo $tmux_lives_cap_role)
t "cap --role applies pal[3] live" 1 (set -l p (__tmux_lives_palette <barbg> <current-scheme> ryb vivid); test (command tmux -L $sock show -gv @tmux_lives_cap_bg) = $p[3]; and echo 1; or echo 0)
t "cap --role rejects junk" 1 (set -e tmux_lives_cap_role; __tmux_lives_cap_cmd --role wat 2>/dev/null; and echo bad; or begin; set -q tmux_lives_cap_role; and echo bad; or echo 1; end)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:** in `__tmux_lives_cap_cmd`, add a `--role <v>` flag (validate `dim|muted|accent`; on bad → error + `return 1` without `set -U`; on good → `set -U tmux_lives_cap_role`, then apply live), mirroring the existing `--vividness`/`--wheel` flag handling. In `__tmux_lives_cap_apply_live`, read the effective role (`__tmux_lives_key tmux_lives_cap_role accent`) and select `$pal[<index>]` instead of hardcoding `$pal[4]` (same role→index switch as Task 4).
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): setup cap --role (dim/muted/accent) + role-aware apply-live`.

---

### Task 6: picker redesign (`__tcz_cap_swatch_line` + `__tcz_cap_picker`)

**Files:** `functions/tmux-categorize.fish` — `__tcz_cap_swatch_line` (~1090), `__tcz_cap_picker` (~1115). Test `tests/test-tmux-categorize.fish` (pure helper only; the raw-tty loop is manual smoke).

**Interfaces — Consumes** Task 1 `__tcz_theme`, Task 3 flat families + restore, Task 5 `setup cap --role`.

**Layout (per the approved mock — draw with `__tcz_theme` + the existing `__tcz_cap_ln`/`__tcz_cap_sep` frame helpers; ≥1 space between fields):**
```
╭─ cap color ─────────────────────────╮   title = brand; border = border
│ primary      scheme      role        │   labels row  (key color)
│ ▪ #f66336    triadic−    accent       │   values (swatch+value color, muted, muted)
├──────────────────────────────────────┤
│ d  m  a            d dim · m muted · a accent │  heads (active col=key, else muted) + right-aligned legend
│ ▪ ▪ ▪   mono                          │   flat rows; active role column marked; sel row = sel-bg + sel-fg
│ …(all 10 schemes)…                    │
├──────────────────────────────────────┤
│ ↑↓ scheme    ←→ cap role              │   footer keys=key, desc=muted, aligned columns
│ v  vividness w  wheel                 │
│ ⏎  apply     esc cancel               │
├──────────────────────────────────────┤
│ wheel ryb    vividness vivid          │   status: labels=key, values=value
╰──────────────────────────────────────╯
```

- [ ] **Step 1 — failing tests** (pure helper): update `__tcz_cap_swatch_line` to take the active-role column and mark it. Signature `__tcz_cap_swatch_line <dimhex> <mutedhex> <accenthex> <scheme> <selected> <activecol>` where activecol ∈ 1|2|3 (dim/muted/accent). Tests:
```fish
set -g L (__tcz_cap_swatch_line "#4b6244" "#8769b0" "#f66336" triadic- 1 3)
t "swatch has 3 truecolor cells" 3 (string match -a -r '\\[48;2;' -- $L | count)
t "swatch shows scheme name" 1 (string match -q '*triadic-*' -- $L; and echo 1; or echo 0)
t "swatch marks active col 3" 1 (string match -q '*'(__tcz_theme key)'*' -- $L; and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:**
  - `__tcz_cap_swatch_line`: render the 3-cell truecolor strip (each cell degrades to a 2-space gap on bad hex), draw a marker (e.g. an underline/bracket in `__tcz_theme key`) on the `activecol` cell, then the scheme name (`sel-fg`+bold if selected else `muted`). Use `__tcz_theme` for all colors.
  - `__tcz_cap_picker`: rebuild the loop:
    - **State:** `scheme` cursor (index into the flat `__tcz_cap_families`), `role` ∈ {dim,muted,accent}, plus the existing `wheel`/`vividness`. Init all from the config-loaded `fish -c` (add `tmux_lives_cap_role accent` to the init reads); position the cursor via `__tcz_cap_restore` and set the initial `role`.
    - **Batch cache:** keep the one config-loaded `fish -c` computing each scheme's dim/muted/accent (now for the 10 flat tokens).
    - **Draw:** title (brand), primary cluster (cluster A — labels row + values row via `__tcz_cap_ln`, 3 aligned columns: primary = swatch + `#hex`(value); scheme (muted); role (muted)), `__tcz_cap_sep`, the `d m a` header with the active column in `key` + the right-aligned legend on the same row, the 10 flat swatch rows (`__tcz_cap_swatch_line … $role_index`), `__tcz_cap_sep`, the 3 aligned footer rows (keys=`key`, desc=`muted`), `__tcz_cap_sep`, the status row (labels=`key`, values=`value`), bottom border. All via `__tcz_cap_ln` so borders align and every field has ≥1 space.
    - **Keys:** `up`/`down` move the scheme cursor; `left`/`right` cycle `role` (dim↔muted↔accent) and refresh the marker/primary; `v` vividness, `w` wheel (recompute batch); `enter` → apply; `cancel` → exit.
    - **Enter:** `fish -c 'tmux-lives setup cap $argv[1] --role $argv[2] --vividness $argv[3] --wheel $argv[4]' "$scheme" "$role" "$vividness" "$wheel"`.
    - Keep the `stty`/cleanup trap. The primary cluster's swatch/#hex = the CURRENT (cursor scheme × role) selection preview.
- [ ] **Step 4 — PASS + full suite** (pure helper green; picker draw is manual smoke). **Step 5 — commit:** `feat(cap): redesigned flat picker — tl palette, primary cluster, role-shift`.

---

### Task 7: taller popup at all three open sites

**Files:** `conf.d/tmux-lives-install.fish` — `__tmux_lives_cap_picker` (~793) + the `M-k` bind in `render_fragment` (~126); `functions/tmux-categorize.fish` — the modal `k` deferred open (~921). Tests both.

- [ ] **Step 1 — failing tests:**
```fish
# install
t "cap_picker popup is taller" 1 (functions __tmux_lives_cap_picker | string match -q '*-w 44 -h 22*'; and echo 1; or echo 0)
set -g MK (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k accent | string collect)
t "M-k bind is taller" 1 (string match -q '*display-popup -B -E -w 44 -h 22*cap-picker*' -- "$MK"; and echo 1; or echo 0)
# categorize
t "modal k open is taller" 1 (functions __tcz_modal_run | string match -q '*-w 44 -h 22*cap-picker*'; and echo 1; or echo 0)
```
- [ ] **Step 2 — FAIL.**
- [ ] **Step 3 — implement:** change `-w 34 -h 15` → `-w 44 -h 22` at all three cap-picker open sites (install `__tmux_lives_cap_picker`, the `capkey` bind line, and `__tcz_modal_run`'s `case cap`). Leave the modal/switcher popup dims alone.
- [ ] **Step 4 — PASS + full suite.** **Step 5 — commit:** `feat(cap): grow the cap-picker popup for the taller v2 layout`.

- [ ] **Manual smoke (runtime, after `tl update`):** full picker (tl palette, gray selection, aligned right border + footer, right-aligned legend); `←→` shifts the cap role live (bar + primary track it); restore-on-open (scheme+role); `square` renders; `M-k` + `M-m`→`k` open the taller picker; `setup cap --role muted` from the CLI.

## Self-Review
Spec coverage: palette →T1; square+rename →T2; flat list+restore →T3; role fragment →T4; role CLI →T5; picker redesign →T6; popup →T7. Role→index (`dim`=2/`muted`=3/`accent`=4) consistent across T4/T5/T6. `scheme` rename in T2 (CLI+palette) with picker labels in T6. argv[16]=cap_role. Deferred (Phase B): modal/switcher palette retrofit, primary-in-picker, whole-bar. Non-testable picker draw is manual-smoke; pure helpers (`__tcz_theme`, `__tcz_cap_families`, `__tcz_cap_restore`, `__tcz_cap_swatch_line`) + fragment/CLI role wiring are unit-tested.
