# Status Bar Color (derived from ShellFish color) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tmux-lives setup color <css> [-i]` also colors the global tmux status bar with a shade derived from the ShellFish color — lighter by default, darker with `-i`/`--invert` — with auto-contrast status text.

**Architecture:** A pure `__tmux_lives_derive_status <color> <invert>` helper parses the color (hex / `rgb()`), applies the lighten/darken formula, and emits a `bg=#rrggbb,fg=black|white` string. `__tmux_lives_render_fragment` bakes `set -g status-style <that>` into the managed fragment when the value is non-empty. `__tmux_lives_color_cmd` parses the `-i` flag, persists `tmux_lives_status_invert`, and re-renders.

**Tech Stack:** fish shell (`math` with `round()`/hex/comparison), tmux. Tests are fish scripts under `tests/`.

## Global Constraints

- All code lands in `conf.d/tmux-lives-install.fish`. **Zero new files.**
- Formula per RGB channel `c` (0–255): lighter (default) `c' = round(c + (255 − c) × 0.25)`; darker (`-i`) `c' = round(c × 0.75)`. Emit `bg` as lowercase `#rrggbb`.
- Status fg: integer luminance `L = round(0.299·r + 0.587·g + 0.114·b)` (0–255); `fg = black` if `L > 140` (≈ 0.55), else `fg = white` (tmux named colors). **fish `math` has no comparison operators — use `test $L -gt 140`, not `math "… > 0.55"`.**
- Parse only **hex** (`#rrggbb`, `#rgb`) and **`rgb()/rgba()`**. Anything else (named, `color(p3 …)`, empty) → derive helper echoes **nothing** and the `status-style` line is omitted (bar stays at the tmux default).
- `-i`/`--invert` only takes effect when setting a color; `-i` with no color is an error (no bare toggle). Direction persists as universal var `tmux_lives_status_invert` (`1`/`0`).
- One knob: `tmux-lives setup color` drives both the existing ShellFish tab color and the new status bar. `setup color ""` clears both.
- Framed `tmux-lives setup -h` must stay ≤ 80 **visible** columns.
- Tests must save/restore the real universal vars `tmux_lives_bar_color` AND `tmux_lives_status_invert` (the command sets `-U`).
- Reference exact derived values (verified by hand): `#1f6feb` lighter → `bg=#5793f0,fg=white`; `#1f6feb` darker → `bg=#1753b0,fg=white`.

Run the full suite any time:
```bash
fish -c 'for t in tests/test-*.fish; echo "== $t =="; fish $t | tail -1; end'
```

---

### Task 1: `__tmux_lives_derive_status` helper (pure formula)

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add the function near `__tmux_lives_color_cmd`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_derive_status <color> <invert>` → echoes `bg=#rrggbb,fg=black|white` (lowercase hex) for parseable hex/`rgb()`, lighter when `<invert>` ≠ `1`, darker when `<invert>` = `1`; echoes **nothing** for unparseable/empty input.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` immediately after the baseline block (after the line `t "verify reports baseline" 1 (...)`):

```fish
# status color derivation: lighten/darken + auto-contrast fg + parse scope
t "derive: lighter #1f6feb"  "bg=#5793f0,fg=white" (__tmux_lives_derive_status "#1f6feb" 0)
t "derive: darker  #1f6feb"  "bg=#1753b0,fg=white" (__tmux_lives_derive_status "#1f6feb" 1)
t "derive: short hex == long" (__tmux_lives_derive_status "#1199ff" 0) (__tmux_lives_derive_status "#19f" 0)
t "derive: rgb() == hex"      (__tmux_lives_derive_status "#1f6feb" 0) (__tmux_lives_derive_status "rgb(31, 111, 235)" 0)
t "derive: light base -> black fg" "bg=#fff2a6,fg=black" (__tmux_lives_derive_status "#ffee88" 0)
t "derive: dark base -> white fg"  "bg=#4c5864,fg=white" (__tmux_lives_derive_status "#102030" 0)
t "derive: named -> empty" "" (__tmux_lives_derive_status "red" 0)
t "derive: empty -> empty"  "" (__tmux_lives_derive_status "" 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: derive: lighter #1f6feb …` (function `__tmux_lives_derive_status` undefined → empty output).

- [ ] **Step 3: Implement the helper**

In `conf.d/tmux-lives-install.fish`, add directly above `function __tmux_lives_color_cmd`:

```fish
function __tmux_lives_derive_status --description 'css color + invert(0/1) -> "bg=#rrggbb,fg=black|white" for status-style; empty if unparseable'
    set -l color (string lower -- $argv[1])
    set -l invert $argv[2]
    test -n "$color"; or return
    set -l r; set -l g; set -l b
    set -l m (string match -rg '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$' -- $color)
    if test (count $m) -eq 3
        set r (math "0x$m[1]"); set g (math "0x$m[2]"); set b (math "0x$m[3]")
    else
        set m (string match -rg '^#([0-9a-f])([0-9a-f])([0-9a-f])$' -- $color)
        if test (count $m) -eq 3
            set r (math "0x$m[1]$m[1]"); set g (math "0x$m[2]$m[2]"); set b (math "0x$m[3]$m[3]")
        else
            set m (string match -rg '^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)' -- $color)
            if test (count $m) -eq 3
                set r $m[1]; set g $m[2]; set b $m[3]
            else
                return
            end
        end
    end
    # clamp 0-255
    for v in r g b
        set -l x $$v
        test "$x" -gt 255; and set $v 255
    end
    if test "$invert" = 1
        set r (math "round($r * 0.75)"); set g (math "round($g * 0.75)"); set b (math "round($b * 0.75)")
    else
        set r (math "round($r + (255 - $r) * 0.25)"); set g (math "round($g + (255 - $g) * 0.25)"); set b (math "round($b + (255 - $b) * 0.25)")
    end
    set -l hex (printf '#%02x%02x%02x' $r $g $b)
    # fish `math` has NO comparison operators — compute integer luminance (0-255) and
    # compare with `test`. 0.55 * 255 ≈ 140, so L > 140 → black text, else white.
    set -l fg white
    set -l L (math "round(0.299 * $r + 0.587 * $g + 0.114 * $b)")
    test $L -gt 140; and set fg black
    echo "bg=$hex,fg=$fg"
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the eight new `derive:` assertions pass; the run ends with `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): __tmux_lives_derive_status — lighten/darken color for status bar"
```

---

### Task 2: Bake `status-style` into the fragment

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (5th `invert` arg + emit line); `__tmux_lives_write_fragment` (pass invert)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_derive_status` (Task 1).
- Produces: `__tmux_lives_render_fragment <cat> <pkey> <skey> [color] [invert]` now emits `set -g status-style bg=…,fg=…` when the derived value is non-empty.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` after the existing fragment color tests (after `t "3-arg call still renders the hook" …`):

```fish
set -l fragss (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" 0 | string collect)
t "fragment status-style lighter" 1 (string match -q '*set -g status-style bg=#5793f0,fg=white*' -- "$fragss"; and echo 1; or echo 0)
set -l fragssi (__tmux_lives_render_fragment /X/cat.fish S M-s "#1f6feb" 1 | string collect)
t "fragment status-style darker"  1 (string match -q '*status-style bg=#1753b0*' -- "$fragssi"; and echo 1; or echo 0)
set -l fragssn (__tmux_lives_render_fragment /X/cat.fish S M-s "" 0 | string collect)
t "no color -> no status-style"   0 (string match -q '*status-style*' -- "$fragssn"; and echo 1; or echo 0)
t "no color -> hook still there"  1 (string match -q '*client-attached*' -- "$fragssn"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: fragment status-style lighter …` (no `status-style` line emitted yet).

- [ ] **Step 3: Implement**

In `conf.d/tmux-lives-install.fish`, in `__tmux_lives_render_fragment`, add the 5th arg under the existing `set -l color $argv[4]` line (around line 15):

```fish
    set -l invert $argv[5]  # 1 = darker status bar; else lighter
```

Then, immediately after the `status-right` block (the two lines ending with `'    'set -ga status-right \"#(fish --no-config $cat tick)\"'`), add:

```fish
    set -l ss (__tmux_lives_derive_status $color $invert)
    test -n "$ss"; and set -a f "set -g status-style $ss"
```

In `__tmux_lives_write_fragment`, pass the invert universal var as the 5th argument:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) > $fragment
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the four new fragment assertions pass; `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(install): bake derived status-style into the managed fragment"
```

---

### Task 3: `setup color` `-i` flag + persistence + verify/help

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_color_cmd` (flag parse + persist + show), `__tmux_lives_status_lines` (direction), `__tmux_lives_setup_help_lines` (help row)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_write_fragment` (Task 2), `__tmux_lives_key`.
- Produces: `tmux-lives setup color [<css>] [-i|--invert]` — sets `tmux_lives_bar_color` + `tmux_lives_status_invert`; no-arg shows color + direction; `-i` without a color errors.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, find the existing color test block (it stubs `__tmux_lives_write_fragment` to render to `$cfrag` and saves/restores `tmux_lives_bar_color`). Make three edits:

(a) Update the stub to pass the invert arg — replace the stub body line with:
```fish
    __tmux_lives_render_fragment /X/cat.fish S M-s (__tmux_lives_key tmux_lives_bar_color '') (__tmux_lives_key tmux_lives_status_invert 0) > /tmp/tli-colorfrag-$fish_pid.conf
```

(b) Extend the save/restore to also cover `tmux_lives_status_invert`. After the existing `set _bc_val $tmux_lives_bar_color` save, add:
```fish
set -l _si_had 0
set -l _si_val
if set -q tmux_lives_status_invert
    set _si_had 1
    set _si_val $tmux_lives_status_invert
end
set -e tmux_lives_status_invert
```
and in the restore (next to the `tmux_lives_bar_color` restore at the end of the block) add:
```fish
if test $_si_had -eq 1
    set -U tmux_lives_status_invert $_si_val
else
    set -e tmux_lives_status_invert
end
```

(c) Add these assertions right after the existing `t "color: cleared to empty" …` line (while the stub + save/restore are in effect):
```fish
__tmux_lives_color_cmd "#1f6feb" -i >/dev/null
t "color -i: invert var = 1"     "1" "$tmux_lives_status_invert"
t "color -i: fragment darker"    1 (string match -q '*status-style bg=#1753b0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
__tmux_lives_color_cmd "#1f6feb" >/dev/null
t "color no -i: invert var = 0"  "0" "$tmux_lives_status_invert"
t "color: fragment lighter"      1 (string match -q '*status-style bg=#5793f0*' -- (cat $cfrag | string collect); and echo 1; or echo 0)
t "color show: reports lighter"  1 (string match -q '*status bar: lighter*' -- (__tmux_lives_color_cmd | string collect); and echo 1; or echo 0)
t "color -i no color: rc1"       1 (__tmux_lives_color_cmd -i >/dev/null 2>&1; echo $status)
__tmux_lives_color_cmd "" >/dev/null
```

Also add a verify + help assertion (anywhere after the block):
```fish
t "verify reports status direction" 1 (string match -q '*status bar:*' -- (__tmux_lives_status_lines | string collect); and echo 1; or echo 0)
t "help color row mentions -i" 1 (string match -q '*color*-i*' -- (__tmux_lives_setup_help_lines | string collect); and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-install.fish`
Expected: `FAIL: color -i: invert var = 1 …` (color_cmd ignores `-i`; `tmux_lives_status_invert` unset), plus the verify/help failures.

- [ ] **Step 3: Implement**

Replace `__tmux_lives_color_cmd` in `conf.d/tmux-lives-install.fish` with:

```fish
function __tmux_lives_color_cmd --description 'tmux-lives setup color [<css-color>] [-i|--invert]: ShellFish tab color + derived status bar'
    set -l invert 0
    set -l color
    set -l have_color 0
    for a in $argv
        switch $a
            case -i --invert
                set invert 1
            case '*'
                set color $a; set have_color 1
        end
    end
    if test (count $argv) -eq 0
        set -l c (__tmux_lives_key tmux_lives_bar_color '')
        set -l dir lighter; test (__tmux_lives_key tmux_lives_status_invert 0) = 1; and set dir darker
        test -n "$c"; and echo "bar color: $c (status bar: $dir)"; or echo "bar color: (none)"
        return 0
    end
    if test $have_color -eq 0
        echo "tmux-lives setup color: -i needs a color, e.g. tmux-lives setup color \"#1f6feb\" -i" >&2
        return 1
    end
    if test -n "$color"; and string match -qr '[^A-Za-z0-9#(),./% -]' -- $color
        echo "tmux-lives setup color: invalid color '$color' — use a CSS color (red, #1f6feb, rgb(...), color(p3 ...))" >&2
        return 1
    end
    set -U tmux_lives_bar_color $color
    set -U tmux_lives_status_invert $invert
    __tmux_lives_write_fragment
    if test -n "$color"
        set -l dir lighter; test $invert -eq 1; and set dir darker
        echo "tmux-lives: bar color set to $color (ShellFish tab; status bar $dir)"
    else
        echo "tmux-lives: bar color cleared"
    end
end
```

In `__tmux_lives_status_lines`, replace the existing two bar-color lines:
```fish
    set -l bc (__tmux_lives_key tmux_lives_bar_color ''); test -n "$bc"; or set bc '(none)'
    set -a r "OK bar color: $bc"
```
with:
```fish
    set -l bc (__tmux_lives_key tmux_lives_bar_color ''); test -n "$bc"; or set bc '(none)'
    if test "$bc" = '(none)'
        set -a r "OK bar color: $bc"
    else
        set -l bdir lighter; test (__tmux_lives_key tmux_lives_status_invert 0) = 1; and set bdir darker
        set -a r "OK bar color: $bc (status bar: $bdir)"
    end
```

In `__tmux_lives_setup_help_lines`, replace the existing color row:
```fish
        'color [<css-color>]         set the per-server ShellFish toolbar color' \
```
with:
```fish
        'color [<css>] [-i]          ShellFish tab color (+ status bar; -i darker)' \
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-install.fish`
Expected: the new color/verify/help assertions pass; `ALL PASS (<n>)`, no `FAIL:`.

- [ ] **Step 5: Verify the framed help still fits 80 columns**

Run:
```bash
fish -c 'source conf.d/tmux-lives-install.fish; set -l mx 0; for l in (__tmux_lives_setup_help); set -l w (string length --visible -- $l); test $w -gt $mx; and set mx $w; end; echo $mx'
```
Expected: ≤ 80.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(setup): 'setup color -i' for a darker status bar + verify/help direction"
```

---

### Task 4: Documentation (README + CLAUDE.md)

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Full suite gate (regression check before docs)**

Run:
```bash
fish -c 'set -l bad 0; for t in tests/test-*.fish; fish $t 2>&1 | string match -q "*FAIL*"; and set bad 1; end; test $bad -eq 0; and echo ALLGREEN; or echo SOMEFAIL'
```
Expected: `ALLGREEN`.

- [ ] **Step 2: Update `README.md`**

In the `### ShellFish tab color & non-ShellFish baseline` subsection, add a sentence and update the color examples to show `-i`:
- Note that `setup color` also tints the tmux **status bar** with a shade derived from the ShellFish color (lighter by default, `-i`/`--invert` for darker), visible to every client; status text auto-contrasts.
- Update the `tmux-lives setup color "#1f6feb"` example block to include a `tmux-lives setup color "#1f6feb" -i   # darker status bar` line.

- [ ] **Step 3: Update `CLAUDE.md`**

In the ShellFish bar-color sentence of the status paragraph, document: `setup color` now also derives the global `status-style` from the ShellFish color via `__tmux_lives_derive_status` (lighter `c+(255-c)*0.25` / darker `c*0.75` with `-i`, persisted as `tmux_lives_status_invert`, baked into the fragment), with luminance-based black/white status fg; parses hex/`rgb()` only (graceful skip otherwise); the status bar was previously the tmux default green (unclaimed).

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: status bar color derived from the ShellFish color (setup color -i)"
```

---

## Self-Review

**Spec coverage:**
- Lighter/darker formula → Task 1 (helper) + constraints. ✓
- Auto-contrast fg by luminance → Task 1. ✓
- Hex / `rgb()` parse, graceful skip otherwise → Task 1 (named/empty → empty tests). ✓
- `status-style` baked into the fragment, omitted when no/unparseable color → Task 2. ✓
- One knob, `-i` persisted as `tmux_lives_status_invert`, `-i`-needs-color error, show direction → Task 3. ✓
- verify reports direction; help row shows `-i`; 80-col frame → Task 3 (Step 5). ✓
- Docs → Task 4. ✓
- Save/restore both universal vars in tests → Task 3 Step 1(b). ✓

**Placeholder scan:** every code step has complete fish; no TBD/TODO. ✓

**Type/name consistency:** `__tmux_lives_derive_status`, `tmux_lives_status_invert`, the 5-arg `__tmux_lives_render_fragment`, and the exact derived values (`#5793f0`/`#1753b0`) are used identically across tasks. ✓

**Live-verify item (post-merge, user-run):** the actual rendered bar color + status-text contrast on a real terminal (formula + contrast are unit-tested; final look is a visual check).
