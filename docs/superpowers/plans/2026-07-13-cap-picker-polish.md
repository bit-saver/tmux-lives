# Cap-picker polish + scratch width — Implementation Plan (Phase A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Border the whole cap-picker (separator between swatches and keys), restore the last-applied selection on open, add a dedicated `M-k` keybind, and widen the scratchpad 33%→45%.

**Architecture:** Pure fish helpers (`__tcz_cap_restore`, `__tcz_cap_sep`) unit-tested in `functions/tmux-categorize.fish`; the raw-tty picker loop + live binds + `split-window` are manual smoke. The `M-k` bind threads through `__tmux_lives_render_fragment` (new argv[15]) + `setup keys --cap-key`, mirroring the existing `--modal-key`/`--scratch-key`/`--resize-key` machinery.

**Tech Stack:** fish 4.7.1; tmux 3.3a+/3.6b; existing `-L`-socket + stub test harnesses.

## Global Constraints
- fish 4.7.1, tmux, no new deps. Touch ONLY `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`.
- The categorizer runs as `fish --no-config` — it CANNOT read fish universals directly (verified); read config via a config-loaded `fish -c` or tmux `@options`. Empty leading lines in a command substitution ARE preserved (verified), so the picker's positional `init` reads stay aligned when the bar color is empty.
- Colors emitted into the fragment are single-quoted. Multi-value returns via `printf "%s\n"` + list index; never `set -l a b c (fn)`. Pad frame lines via a QUOTED `string repeat` var (an inline zero-count `(string repeat -n 0 …)` yields zero args and drops trailing printf fields).
- Test isolation: `-L` socket via `tmux_lives_tmux_socket`; any `set -U` test saves/clears/restores the universal (no leak); stub `__tmux_lives_write_fragment` where a command would otherwise re-render the live fragment. Run `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`, pristine. (Bash tool shell is POSIX, not fish — run each suite as `fish tests/test-NAME.fish`; the two big suites take ~40-50s, run individually.)
- Deploy is user-only via `fisher update`. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `__tcz_cap_restore` helper + restore-on-open

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_cap_restore` next to `__tcz_cap_families` (~line 1062); wire it into `__tcz_cap_picker` (init read ~line 1107, after `set -l families`/`set -l sel` ~lines 1137-1139).
- Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_cap_restore <formula> <families…>` → prints ONE line: the 0-based index of the `families` entry whose base (token minus a trailing `+`/`-`) equals `formula`'s base, or `-1` if none match. Pure; mutates nothing.

- [ ] **Step 1 — failing tests** (add near the other `__tcz_cap_*` tests; the `t` helper is `t <desc> <expected> <actual>`):
```fish
set -g FAM (__tcz_cap_families)   # mono complementary analogous+ split+ triadic+ tetradic
t "restore mono -> 0"          0 (__tcz_cap_restore mono $FAM)
t "restore complementary -> 1" 1 (__tcz_cap_restore complementary $FAM)
t "restore analogous- -> 2"    2 (__tcz_cap_restore analogous- $FAM)
t "restore analogous+ -> 2"    2 (__tcz_cap_restore analogous+ $FAM)
t "restore split- -> 3"        3 (__tcz_cap_restore split- $FAM)
t "restore triadic- -> 4"      4 (__tcz_cap_restore triadic- $FAM)
t "restore tetradic -> 5"      5 (__tcz_cap_restore tetradic $FAM)
t "restore #hex -> -1"         -1 (__tcz_cap_restore "#123456" $FAM)
t "restore unknown -> -1"      -1 (__tcz_cap_restore wat $FAM)
t "restore empty -> -1"        -1 (__tcz_cap_restore "" $FAM)
```

- [ ] **Step 2 — run, verify FAIL:** `fish tests/test-tmux-categorize.fish` → FAILED (`Unknown command: __tcz_cap_restore`).

- [ ] **Step 3 — implement** the helper (add after `__tcz_cap_families`):
```fish
function __tcz_cap_restore --argument-names formula --description 'pure: 0-based index of the families entry whose base matches <formula>''s base (trailing +/- stripped), or -1 if none (e.g. #hex/unknown)'
    set -l families $argv[2..]
    set -l base (string replace -r -- '[+-]$' '' $formula)
    for i in (seq (count $families))
        set -l fbase (string replace -r -- '[+-]$' '' $families[$i])
        if test "$fbase" = "$base"
            math $i - 1
            return
        end
    end
    echo -1
end
```

- [ ] **Step 4 — run PASS.** `fish tests/test-tmux-categorize.fish` → all restore tests pass.

- [ ] **Step 5 — wire into `__tcz_cap_picker`.** (a) Extend the init `fish -c` (currently echoes bar, wheel, vividness) to also echo the persisted formula as a 4th line — add this line inside the `fish -c '…'` after the vividness echo:
```fish
        echo (__tmux_lives_key tmux_lives_cap mono)
```
and after the existing `set -l vividness …; test -n "$vividness"; or set vividness vivid` block, add:
```fish
    set -l capformula ''; test (count $init) -ge 4; and set capformula $init[4]
    test -n "$capformula"; or set capformula mono
```
(b) After `set -l families (__tcz_cap_families)` / `set -l n (count $families)` / `set -l sel 0`, add:
```fish
    set -l ridx (__tcz_cap_restore $capformula $families)
    if test $ridx -ge 0
        set sel $ridx
        set families[(math $sel + 1)] $capformula
    end
```

- [ ] **Step 6 — full suite + commit.** `for t in tests/test-*.fish; fish $t; end` → 8× `ALL PASS`, pristine (the picker wiring itself is manual smoke; the helper is covered). Commit: `feat(cap): restore last-applied formula/direction when the picker opens`.

---

### Task 2: full border + separator

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_cap_sep` near `__tcz_cap_ln` (~line 1156); change the `__tcz_cap_picker` draw block (~lines 1166-1183) to fold the footer inside the frame.
- Test: `tests/test-tmux-categorize.fish`.

**Interfaces — Produces:** `__tcz_cap_sep <w> <od> <t>` → prints the frame mid-divider `<od>├` + `─`×w + `┤<t>`.

- [ ] **Step 1 — failing test:**
```fish
t "cap_sep is ├──…──┤ at width w" 1 (test (__tcz_cap_sep 5 '' '') = '├─────┤'; and echo 1; or echo 0)
```

- [ ] **Step 2 — run, verify FAIL** (`Unknown command: __tcz_cap_sep`).

- [ ] **Step 3 — implement** (add right after `__tcz_cap_ln`):
```fish
function __tcz_cap_sep --argument-names w od t --description 'pure: the picker frame''s mid separator line (├──…──┤), inner width w, OD-colored'
    printf '%s├%s┤%s\n' $od (string repeat -n $w ─) $t
end
```

- [ ] **Step 4 — run PASS.**

- [ ] **Step 5 — fold the footer inside the frame.** In `__tcz_cap_picker`'s `while true` draw block: keep the top border and the per-family `__tcz_cap_ln` swatch rows; then REPLACE the old bottom-border-then-unbordered-footer (the `set -a lines $OD"╰"…"╯"$T` line followed by the `printf '\e[K\n ↑↓ move …[%s / %s]…' $wheel $vividness` line) with — separator, four bordered footer rows, then the bottom border:
```fish
        set -a lines (__tcz_cap_sep $IW $OD $T)
        set -a lines (__tcz_cap_ln " ↑↓ move   ←→ flip" $IW $OD $T)
        set -a lines (__tcz_cap_ln " v vivid   w wheel" $IW $OD $T)
        set -a lines (__tcz_cap_ln " ⏎ apply   esc cancel" $IW $OD $T)
        set -a lines (__tcz_cap_ln " wheel $wheel · $vividness" $IW $OD $T)
        set -a lines $OD"╰"(string repeat -n $IW ─)"╯"$T
        printf '\e[H'
        printf '%s\e[K\n' $lines
        printf '\e[J'
```
(The four footer lines are plain text — `__tcz_cap_ln` pads them by SGR-stripped visible width; each is ≤ IW=30. Total rows = 1 top + 6 swatches + 1 sep + 4 footer + 1 bottom = 13 ≤ the popup's `-h 15`.)

- [ ] **Step 6 — full suite + commit.** 8× `ALL PASS`, pristine. Commit: `feat(cap): border the whole picker with a separator above the key list`.

---

### Task 3: dedicated `M-k` cap-picker keybind

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` arg block (~line 29) + bind bakery (~line 124) + the `__tmux_lives_write_fragment` render call site (~line 217) + `__tmux_lives_keys_cmd` (~line 397) + setup-help lines (~line 982).
- Test: `tests/test-tmux-install.fish`.

**Interfaces — Consumes** Task-nothing. `__tmux_lives_render_fragment` gains **argv[15] = cap_key** (`''` = no bind). New universal `tmux_lives_cap_key` (default `M-k`).

- [ ] **Step 1 — failing tests** (mirror the existing modal/scratch bind tests; stub `__tmux_lives_write_fragment` for the `keys_cmd` test as the existing setup tests do, and save/clear/restore `tmux_lives_cap_key`):
```fish
set -g CK (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb M-k | string collect)
t "fragment bakes the cap-key bind" 1 (string match -q "*bind-key -n M-k display-popup*cap-picker*" -- "$CK"; and echo 1; or echo 0)
set -g CK0 (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 M-m M-t M-r C-M-a C-M-s block mono vivid ryb '' | string collect)
t "empty cap-key omits the bind" 1 (string match -q '*cap-picker*' -- "$CK0"; and echo 0; or echo 1)
t "setup keys --cap-key sets the universal" M-c (functions -c __tmux_lives_write_fragment __tmux_lives_wf_orig 2>/dev/null; function __tmux_lives_write_fragment; end; set -l had 0; set -l val; set -q tmux_lives_cap_key; and begin; set had 1; set val $tmux_lives_cap_key; end; set -e tmux_lives_cap_key; __tmux_lives_keys_cmd --cap-key M-c >/dev/null 2>&1; set -l got $tmux_lives_cap_key; set -e tmux_lives_cap_key; test $had -eq 1; and set -U tmux_lives_cap_key $val; functions -e __tmux_lives_write_fragment; functions -q __tmux_lives_wf_orig; and functions -c __tmux_lives_wf_orig __tmux_lives_write_fragment; and functions -e __tmux_lives_wf_orig; echo $got)
t "setup help documents --cap-key" 1 (string match -q '*--cap-key*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
```
(If the existing suite already has a simpler write_fragment stub/save-restore idiom for the modal-key test, reuse that idiom instead of the inline one above — keep it consistent with the file.)

- [ ] **Step 2 — run, verify FAIL:** `fish tests/test-tmux-install.fish` → FAILED.

- [ ] **Step 3 — implement.**
  (a) Arg block — after `set -l wheel $argv[14] …` (~line 29):
```fish
    set -l capkey $argv[15]   # root-table cap-picker key ('' = no bind)
```
  (b) Bind bakery — after the scratch bind (`test -n "$scratchkey"; and set -a f "bind-key -n $scratchkey run-shell '…scratch'"`, ~line 124), add:
```fish
    test -n "$capkey"; and set -a f "bind-key -n $capkey display-popup -B -E -w 34 -h 15 -- fish --no-config $cat cap-picker '#{client_name}'"
```
  (c) Render call site (~line 217) — append after `(__tmux_lives_key tmux_lives_cap_wheel ryb)`:
```fish
 (__tmux_lives_key tmux_lives_cap_key M-k)
```
  (d) `__tmux_lives_keys_cmd` — add after the `--status-vis-key` case (~line 397):
```fish
            case --cap-key
                set -U tmux_lives_cap_key $argv[2]; set changed 1; set -e argv[1..2]
```
  (e) setup-help — after the `--status-pos-key`/`--status-vis-key` help lines (~line 982), add a line:
```fish
        "      --cap-key <key>      cap-color picker (default: M-k; '' off)" \
```

- [ ] **Step 4 — run PASS + full suite.** 8× `ALL PASS`, pristine. Verify no existing fragment test broke (they pass ≤14 args → `capkey` empty → no bind).

- [ ] **Step 5 — commit:** `feat(cap): dedicated M-k cap-picker keybind (setup keys --cap-key)`.

---

### Task 4: scratchpad width 33% → 45%

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_scratch` (~line 1363) and `__tcz_scratch_orient` (~line 1391).
- Test: `tests/test-tmux-categorize.fish`.

- [ ] **Step 1 — failing tests** (the live `split-window` is manual smoke; guard the constant via the function source):
```fish
t "scratch splits at 45%" 1 (functions __tcz_scratch | string match -q '*split-window*-p 45*'; and echo 1; or echo 0)
t "scratch orient splits at 45%" 1 (functions __tcz_scratch_orient | string match -q '*-p 45*'; and echo 1; or echo 0)
```

- [ ] **Step 2 — run, verify FAIL** (still `-p 33`).

- [ ] **Step 3 — implement:** change `tmux split-window -h -p 33` → `tmux split-window -h -p 45` in `__tcz_scratch`, and `tmux split-window $flag -p 33` → `tmux split-window $flag -p 45` in `__tcz_scratch_orient`.

- [ ] **Step 4 — run PASS + full suite.** 8× `ALL PASS`.

- [ ] **Step 5 — commit:** `feat(scratch): widen the default scratch split 33% -> 45%`.

- [ ] **Manual smoke (runtime, after `tl update`):** picker is one bordered box with a divider above the keys; reopening lands on the last formula+direction with the right wheel/vividness; `M-k` opens the picker; `M-t` scratch opens at ~45%.

## Self-Review
Spec coverage: Item 1 (border+separator) → Task 2; Item 2 (restore-on-open) → Task 1; Item 3 (M-k keybind) → Task 3; Item 4 (scratch width) → Task 4. Column labels are explicitly deferred to Phase B (not in this plan). Names consistent: `__tcz_cap_restore` (index only), `__tcz_cap_sep` (divider), `tmux_lives_cap_key`/argv[15]/`--cap-key`. Test isolation (`-L` socket, universal save/restore, write_fragment stub) in Task 3. Fish gotchas (empty-line preservation, quoted `string repeat`, no-config-can't-read-universals) in Global Constraints.
