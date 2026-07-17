# Picker In-Process Performance + Change-Flash + Shift-Reverse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the per-keypress subprocess in the theme picker (source the engine in-process + cache batches + rotate-as-permutation), add a timed blue change-flash on the adjustments zone, and shift-reverse for the cycling knobs.

**Architecture:** All changes live in `functions/tmux-categorize.fish` (`__tcz_theme_picker` + its nested seed screens, `__tcz_popup_readkey`, `__tcz_thp_kv`, `__tcz_theme`) plus one perf-guard test in the install suite. The engine (`conf.d/tmux-lives-install.fish`) is NOT modified — the picker sources it once at open and calls its functions directly.

**Tech Stack:** fish 4.7.1, tmux 3.3a, the repo's `t "<desc>" <expected> <got>` harness.

**Spec:** `docs/superpowers/specs/2026-07-17-picker-performance-flash-design.md` — read it first.

## Global Constraints

- Deploy = the user's `fisher update` ONLY. Never touch `~/.config/fish/`, `~/.tmux.conf`, or the user's universals outside test save/restore guards. Never kill a running suite. Tests driving `tmux` pin the `tmux_lives_tmux_socket` seam or a PATH shim.
- fish gotchas (grep-guard/review-enforced): `"$x[(math …)]"` quoted math-index BANNED (unquoted or via-var); a zero-output command substitution as a bare argument VANISHES (capture into a var, pass quoted); no comparisons inside `math`; SGR escapes in `set` strings must be printf-captured vars (fish does not interpret `\e` in quotes; printf FORMAT strings do); every raw-tty drain loop re-asserts `stty min 0 time 0` INSIDE each iteration; the frame's last row is emitted without `\n`.
- Exact values from the spec: flash color truecolor `#5fa8e8` = SGR `\e[38;2;95;168;232m`; flash timeout = `stty min 0 time 5` (≈0.5 s); cache key = `"$seed|$phase|$viv|$shape|$ease|$contrast"` (rotate EXCLUDED); rotation permutation = displayed support position `i` (pal fields 2..6 → positions 1..5) holds original support `((i - 1 - $rotate) % 5 + 5) % 5 + 1`; readkey timeout-mode token is exactly `timeout`; uppercase keys V=56 S=53 E=45 D=44 O=4f (hex).
- The Bash tool's shell is zsh: run suites as `fish tests/test-tmux-categorize.fish` etc.; cross-check final runs with `fish --no-config` (plain runs can be flattered by the live fisher install). Full gate: `fish -c 'for t in tests/test-*.fish; fish $t; end'`.
- Commit after every task; push happens at branch completion.

## File Structure

- `functions/tmux-categorize.fish` — all four tasks.
- `tests/test-tmux-categorize.fish` — guards, builders, readkey.
- `tests/test-tmux-install.fish` — the coarse in-process perf guard (the engine lives install-side).
- `README.md`, `CLAUDE.md` — folded into Task 4.

Work on branch: `git checkout -b feat/picker-perf-flash` (from current `main`).

---

### Task 1: In-process engine — no `fish -c` inside the picker

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme_picker` open (~L1322), `__tcz_thp_init` (~L1339), `__tcz_thp_reload` (~L1369), hexentry readout (~L1402) + apply (~L1418), slider readout (~L1455) + apply (~L1507), `a`/`cancel` (~L1697/1709), post-loop saves (~L1722-1726)
- Test: `tests/test-tmux-categorize.fish` (grep-guard), `tests/test-tmux-install.fish` (perf guard)

**Interfaces:**
- Consumes: engine functions from `conf.d/tmux-lives-install.fish` (`__tmux_lives_key`, `__tmux_lives_seed_hex`, `__tmux_lives_derive_status`, `__tmux_lives_contrast_fg`, `__tmux_lives_theme_schemes`, `__tmux_lives_theme_palette <seedHex> <scheme> <phase> <viv> <shape> <ease> <contrast> <rotate>`, `__tmux_lives_theme_apply_live [7 args]`, `__tmux_lives_hex_to_rgb01`, `__tmux_lives_rgb_to_oklch`, the `tmux-lives` dispatcher).
- Produces: a picker whose ONLY subprocesses are tmux calls and readkey's dd/od. Task 2 modifies the in-process `__tcz_thp_reload` this task creates.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-tmux-categorize.fish`, next to the other picker grep-guards:

```fish
# perf fix: the picker must never spawn a fish subprocess per keypress —
# the engine is sourced in-process at open. Extract the function body
# (top-level `end` closes it; nested helpers' `end`s are indented).
set -l pbody (awk '/^function __tcz_theme_picker/,/^end$/' $catfile | string collect)
t "guard: no fish -c inside the picker" 0 (string match -q '*fish -c*' -- "$pbody"; and echo 1; or echo 0)
t "guard: picker sources the engine" 1 (string match -q '*conf.d/tmux-lives-install.fish*' -- "$pbody"; and echo 1; or echo 0)
```

In `tests/test-tmux-install.fish`, at the end of the theme-engine section (before the section's universal restore):

```fish
# coarse perf guard (environment-tolerant, like the truncate guard): one
# in-process 10-scheme batch must complete well under a second.
set -l _pt0 (date +%s%N)
for _tok in (__tmux_lives_theme_schemes)
    __tmux_lives_theme_palette '#485b3c' $_tok 0 balanced arc linear auto 0 >/dev/null
end
set -l _pt1 (date +%s%N)
set -l _ptms (math "($_pt1 - $_pt0) / 1000000")
t "perf: in-process 10-palette batch < 1000ms" 1 (test $_ptms -lt 1000; and echo 1; or echo 0)
```

(Capture each timestamp into its own var BEFORE the `math` — a command substitution does not run inside a math expression string.)

- [ ] **Step 2: Run to verify failure.** `fish tests/test-tmux-categorize.fish` — both new guards FAIL (the body still contains `fish -c`, no source line). The install-suite perf guard already PASSES (the engine is already this fast in-process) — it is a regression fence, not a red test; note that in the report.

- [ ] **Step 3: Source the engine at picker open.** In `__tcz_theme_picker`, right after the leading comment block (before `set -l seed ''`):

```fish
    # Source the install-side engine ONCE — every palette/state/apply call
    # below runs in-process. A per-keypress `fish -c` costs a process spawn +
    # full config load (the 2026-07-17 live lag, brutal on macOS); this file's
    # only top-level statement is a guarded pi global, so sourcing is safe.
    set -l __tcz_engine "$__fish_config_dir/conf.d/tmux-lives-install.fish"
    test -r $__tcz_engine; and source $__tcz_engine
```

- [ ] **Step 4: Convert `__tcz_thp_init`.** Replace its whole body (the `fish -c` block and the ten `test (count $init)` readers) with direct calls:

```fish
    function __tcz_thp_init --no-scope-shadowing
        set seed (__tmux_lives_seed_hex (__tmux_lives_key tmux_lives_bar_color ""))
        set theme (__tmux_lives_key tmux_lives_theme mono)
        set phase (__tmux_lives_key tmux_lives_theme_phase 0)
        set viv (__tmux_lives_key tmux_lives_theme_vividness balanced)
        set shape (__tmux_lives_key tmux_lives_theme_shape arc)
        set ease (__tmux_lives_key tmux_lives_theme_ease linear)
        set contrast (__tmux_lives_key tmux_lives_theme_contrast auto)
        set rotate (__tmux_lives_key tmux_lives_theme_rotate 0)
        set legacy ''
        set -l ds (__tmux_lives_derive_status (__tmux_lives_key tmux_lives_bar_color "") (__tmux_lives_key tmux_lives_status_invert 0))
        test -n "$ds"; and set legacy (string replace -rf '.*bg=([^,]+).*' '$1' -- "$ds")
        set seedfg '#f5f5f5'
        set -l sfg (__tmux_lives_contrast_fg "$seed")
        test -n "$sfg"; and set seedfg $sfg
        test -n "$seed"; or set seed '#3a3a3a'   # no seed yet: neutral, so the picker still teaches
    end
```

(If the engine failed to source, these calls silently produce empty values and the picker degrades exactly as the old subprocess path did with a missing plugin.)

- [ ] **Step 5: Convert `__tcz_thp_reload`.** Replace the `for line in (fish -c … )` loop with the direct loop (same output lists):

```fish
    function __tcz_thp_reload --no-scope-shadowing --description 'batch: all 10 palettes + cap fgs + tabs fgs, in-process'
        set toks; set pals; set fgs; set tabsfgs
        for tok in (__tmux_lives_theme_schemes)
            set -l p (__tmux_lives_theme_palette $seed $tok $phase $viv $shape $ease $contrast $rotate)
            test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
            set -a toks $tok
            set -a pals (string join " " $p)
            set -a fgs (__tmux_lives_contrast_fg "$p[6]")
            set -a tabsfgs (__tmux_lives_contrast_fg "$p[3]")
        end
    end
```

NB the two `contrast_fg` results can be EMPTY (blank p fields) — `set -a fgs (…)` with empty output appends NOTHING and desyncs the four lists. Capture-and-quote instead:

```fish
            set -l cf (__tmux_lives_contrast_fg "$p[6]")
            set -l tf (__tmux_lives_contrast_fg "$p[3]")
            set -a fgs "$cf"
            set -a tabsfgs "$tf"
```

(Use this corrected form; same for `set -a pals "(string join …)"` → `set -l pj (string join " " $p); set -a pals "$pj"`.)

- [ ] **Step 6: Convert the seed screens.** In `__tcz_thp_hexentry` (~L1402) and `__tcz_thp_sliders` (~L1455), replace each readout `set -l ro (fish -c '…' $X 2>/dev/null)` with:

```fish
                        set -l rgb (__tmux_lives_hex_to_rgb01 $cand)
                        set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
                        set -l ro (printf '%.0f %.2f %.3f' $ok[3] $ok[1] $ok[2])
```

(in the sliders, `$cand` is `$hex`). Replace the two seed applies `fish -c 'tmux-lives setup color $argv[1]' "$X" >/dev/null 2>&1` with `tmux-lives setup color "$X" >/dev/null 2>&1`.

- [ ] **Step 7: Convert preview/revert/saves.** `case a`: `__tmux_lives_theme_apply_live $ptok $phase $viv $shape $ease $contrast $rotate >/dev/null 2>&1`. `case cancel`: `__tmux_lives_theme_apply_live >/dev/null 2>&1`. Post-loop: `tmux-lives setup theme off >/dev/null 2>&1` and `tmux-lives setup theme "$apply" --phase "$phase" --vividness "$viv" --shape "$shape" --ease "$ease" --contrast "$contrast" --rotate "$rotate" >/dev/null 2>&1`. Update the function's leading comment (the "config-loaded fish -c subprocesses" paragraph) to say the engine is sourced in-process.

- [ ] **Step 8: Run.** `fish tests/test-tmux-categorize.fish` and `fish tests/test-tmux-install.fish`, both also `--no-config` — ALL PASS (guards now green).

- [ ] **Step 9: Commit.** `git add -A && git commit -m "perf(theme): picker sources the engine in-process — zero per-keypress fish subprocesses"`

---

### Task 2: Batch cache + rotate as display-side permutation

**Files:**
- Modify: `functions/tmux-categorize.fish` — new pure `__tcz_thp_rotpal` in the thp builder block (after `__tcz_thp_swatch`); `__tcz_thp_reload` (from Task 1); the picker's local declarations (~L1365)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Task 1's in-process reload; engine palette (8-arg).
- Produces: `__tcz_thp_rotpal <rotate> <pal>` → the pal string with support fields 2..6 cyclically permuted (bar 1 / text 7 fixed); reload caches rotate-0 batches keyed `"$seed|$phase|$viv|$shape|$ease|$contrast"` and applies rotation + fg-picks after fetch. `o`/`O` presses therefore cost a cache hit + permutation.

- [ ] **Step 1: Write the failing tests** (categorize suite; the parity tests source BOTH files — add `source $plugindir/conf.d/tmux-lives-install.fish` if the suite doesn't already, where `$plugindir` follows the install suite's pattern `(path resolve (status dirname)/..)`):

```fish
# rotate is a display-side permutation: parity with the engine for r=0..4
set -l base (__tmux_lives_theme_palette '#485b3c' wide 25 vivid arc cubic lighter 0)
set -l basestr (string join ' ' $base)
for r in 0 1 2 3 4
    set -l eng (__tmux_lives_theme_palette '#485b3c' wide 25 vivid arc cubic lighter $r)
    set -l engstr (string join ' ' $eng)
    t "rotpal parity r=$r" "$engstr" (__tcz_thp_rotpal $r "$basestr")
end
```

- [ ] **Step 2: Run.** FAIL (`__tcz_thp_rotpal` undefined).

- [ ] **Step 3: Implement the pure permutation** (in the thp builder block, after `__tcz_thp_swatch`):

```fish
function __tcz_thp_rotpal --argument-names rotate pal --description 'pure: apply the rotate permutation display-side — support fields 2..6 of a rotate-0 pal string cyclically shifted (same index math as the engine); bar (1) and text (7) fixed. Non-7-field input returned unchanged.'
    set -l p (string split ' ' -- $pal)
    test (count $p) -eq 7; or begin; printf '%s' "$pal"; return; end
    string match -qr '^[0-4]$' -- "$rotate"; or set rotate 0
    set -l out $p[1]
    for i in 1 2 3 4 5
        set -l j (math "(($i - 1 - $rotate) % 5 + 5) % 5 + 1")
        set -l k (math "$j + 1")
        set -a out $p[$k]
    end
    set -a out $p[7]
    printf '%s' (string join ' ' $out)
end
```

- [ ] **Step 4: Run.** Parity tests PASS.

- [ ] **Step 5: Add the cache + rotation to reload.** Declare `set -l cachekeys` / `set -l cacheblobs` beside `set -l toks` (~L1365). Replace Task 1's `__tcz_thp_reload` body:

```fish
    function __tcz_thp_reload --no-scope-shadowing --description 'batch: all 10 palettes + fgs, in-process; rotate-0 results cached by knob-state key, rotation applied as a display-side permutation (o never recomputes)'
        set toks; set pals; set fgs; set tabsfgs
        set -l key "$seed|$phase|$viv|$shape|$ease|$contrast"
        set -l blob ''
        set -l ci (contains -i -- "$key" $cachekeys)
        if test -n "$ci"
            set blob $cacheblobs[$ci]
        else
            set -l lines
            for tok in (__tmux_lives_theme_schemes)
                set -l p (__tmux_lives_theme_palette $seed $tok $phase $viv $shape $ease $contrast 0)
                test (count $p) -eq 7; or set p "" "" "" "" "" "" ""
                # per-support contrast fgs (any support can rotate onto cap/tabs)
                set -l sfgs
                for si in 2 3 4 5 6
                    set -l sf (__tmux_lives_contrast_fg "$p[$si]")
                    set -a sfgs "$sf"
                end
                set -l pj (string join ' ' $p)
                set -l fj (string join ' ' $sfgs)
                set -a lines "$tok|$pj|$fj"
            end
            set -l bj (string join \x1e $lines)
            set blob "$bj"
            set -a cachekeys "$key"
            set -a cacheblobs "$blob"
        end
        for line in (string split \x1e -- $blob)
            set -l f (string split '|' -- $line)
            test -n "$f[1]"; or continue
            set -a toks $f[1]
            set -l rp (__tcz_thp_rotpal $rotate "$f[2]")
            set -a pals "$rp"
            # displayed cap = support position 5, tabs = position 2 (post-perm)
            set -l sfgs (string split ' ' -- $f[3])
            set -l jc (math "((5 - 1 - $rotate) % 5 + 5) % 5 + 1")
            set -l jt (math "((2 - 1 - $rotate) % 5 + 5) % 5 + 1")
            set -a fgs "$sfgs[$jc]"
            set -a tabsfgs "$sfgs[$jt]"
        end
    end
```

- [ ] **Step 6: Add the behavioral tests** (categorize suite). Cache/fg parity is loop-internal, so pin it through a probe that mirrors the fg-pick contract:

```fish
# post-rotation fg pick contract: the displayed cap/tabs fgs equal
# contrast_fg of the ROTATED pal's fields 6 and 3
set -l rot 2
set -l rp (__tcz_thp_rotpal $rot "$basestr")
set -l rpf (string split ' ' -- $rp)
set -l wantcap (__tmux_lives_contrast_fg "$rpf[6]")
set -l wanttabs (__tmux_lives_contrast_fg "$rpf[3]")
set -l sfgs
for si in 2 3 4 5 6
    set -l sf (__tmux_lives_contrast_fg (string split ' ' -- $basestr)[$si])
    set -a sfgs "$sf"
end
set -l jc (math "((5 - 1 - $rot) % 5 + 5) % 5 + 1")
set -l jt (math "((2 - 1 - $rot) % 5 + 5) % 5 + 1")
t "fg pick: cap fg matches rotated pal" "$wantcap" "$sfgs[$jc]"
t "fg pick: tabs fg matches rotated pal" "$wanttabs" "$sfgs[$jt]"
```

NB `(string split ' ' -- $basestr)[$si]` — a command-substitution INDEXED BY A VAR is fine (the ban is quoted-with-inline-math); if fish rejects the direct form, capture the split into a var first.

- [ ] **Step 7: Run.** `fish tests/test-tmux-categorize.fish` plain + `--no-config` — ALL PASS.

- [ ] **Step 8: Commit.** `git add -A && git commit -m "perf(theme): batch cache keyed by knob state; rotate is a free display-side permutation"`

---

### Task 3: Change-flash (timed ~0.5 s)

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_theme` (add `flash` role, ~L1730), `__tcz_popup_readkey` (timeout mode, ~L764), `__tcz_thp_kv` (flash arg, ~L1216), the picker loop (flash state + timed read + kv call sites, ~L1560-1712), seed screens (flash on seed apply)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Tasks 1-2 loop shape.
- Produces: `__tcz_theme flash` → `\e[38;2;95;168;232m`; `__tcz_popup_readkey [timeout]` → empty read yields `timeout` when the first arg is `timeout`, else `cancel`; `__tcz_thp_kv <w> <flashfield> [<label> <value>]…` (flashfield `''` = none; case-insensitive label match renders that pair in the flash role).

- [ ] **Step 1: Write the failing tests:**

```fish
# flash role + timeout readkey + kv flash
t "theme flash role" (printf '\e[38;2;95;168;232m') (__tcz_theme flash)
t "readkey timeout mode" timeout (printf '' | __tcz_popup_readkey timeout)
t "readkey EOF still cancels by default" cancel (printf '' | __tcz_popup_readkey)
set -l FLASH (__tcz_theme flash)
set -l kvf (__tcz_thp_kv 50 vividness seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv flash colors the flagged label" 1 (string match -q "*$FLASH*VIVIDNESS*" -- "$kvf[1]"; and echo 1; or echo 0)
t "kv flash colors the flagged value" 1 (string match -q "*$FLASH*balanced*" -- "$kvf[2]"; and echo 1; or echo 0)
t "kv flash leaves others muted" 0 (string match -q "*$FLASH*SEED*" -- "$kvf[1]"; and echo 1; or echo 0)
set -l kvn (__tcz_thp_kv 50 '' seed '#485b3c' phase '+15°' vividness balanced shape arc)
t "kv no-flash has no flash SGR" 0 (string match -q "*$FLASH*" -- "$kvn[1]$kvn[2]"; and echo 1; or echo 0)
# widths identical with and without flash
t "kv flash width-neutral" (string length --visible -- (__tcz_strip_sgr "$kvn[2]")) (string length --visible -- (__tcz_strip_sgr "$kvf[2]"))
```

Also UPDATE every existing `__tcz_thp_kv` test call in this suite to the new signature (insert `''` as the second argument) — same expected outputs.

- [ ] **Step 2: Run.** FAIL (no flash role; readkey lacks the mode; kv arity).

- [ ] **Step 3: Implement.**
  - `__tcz_theme`: add `case flash; printf '\e[38;2;95;168;232m'` with comment `# change-flash blue (picker adjustments zone; 2026-07-17 UX request)` beside the other roles.
  - `__tcz_popup_readkey`: `function __tcz_popup_readkey --argument-names mode --description 'read one keystroke -> up|down|left|right|v|V|s|S|e|E|d|D|o|O|a|r|b|enter|cancel|kill|timeout|other; with mode=timeout an empty read returns timeout instead of cancel'` and change the EOF line to:

```fish
    if test -z "$b"
        test "$mode" = timeout; and echo timeout; or echo cancel
        return
    end
```

  (The docstring's V/S/E/D/O tokens land in Task 4 — write the docstring once here.)
  - `__tcz_thp_kv`: signature `--argument-names w flashfield`, pairs start at `$argv[3..]`; inside the loop:

```fish
        set -l FL ''
        test -n "$flashfield"; and string match -qi -- "$flashfield" $rest[1]; and set FL (__tcz_theme flash)
        if test -n "$FL"
            set lr "$lr$FL$lab$RST$lpad"
            set vr "$vr$FL$vplain$RST$vpad"
        else
            set lr "$lr$MUT$lab$RST$lpad"
            set vr "$vr$rest[2]$RST$vpad"
        end
```

  (`$vplain` already exists — the stripped value; the flash replaces the value's own SGR by design.)
  - Picker loop: declare `set -l flashfield ''` beside `set -l note ''`. Kv call sites become `(__tcz_thp_kv $IW "$flashfield" seed "$seedchip" …)` / `(__tcz_thp_kv $IW "$flashfield" contrast …)`. Knob cases set it before their reload: left/right→`set flashfield phase`, v→vividness, s→shape, e→ease, d→contrast, o→rotate; `r`→`set flashfield ''`. In `__tcz_thp_hexentry` and `__tcz_thp_sliders` (both `--no-scope-shadowing`), after a successful seed apply (beside their `__tcz_thp_init`/`__tcz_thp_reload` calls): `set flashfield seed`.
  - The read: replace `switch (__tcz_popup_readkey)` with:

```fish
        set -l tok
        if test -n "$flashfield"
            # flash active: wait up to ~0.5s; on timeout clear the flash and
            # repaint. A real key is handled exactly like the blocking read.
            stty min 0 time 5 2>/dev/null
            set tok (__tcz_popup_readkey timeout)
            stty min 1 time 0 2>/dev/null
            if test "$tok" = timeout
                set flashfield ''
                continue
            end
        else
            set tok (__tcz_popup_readkey)
        end
        switch $tok
```

- [ ] **Step 4: Run.** `fish tests/test-tmux-categorize.fish` plain + `--no-config` — ALL PASS (including the updated kv tests).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(theme): timed blue change-flash on the picker's adjustments zone"`

---

### Task 4: Shift-reverse + docs + full-suite gate

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_popup_readkey` cases, the picker dispatch; `README.md` (Theming section), `CLAUDE.md` (status paragraph)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: Task 3's flashfield + readkey docstring.
- Produces: readkey tokens `V S E D O`; picker reverse cycles.

- [ ] **Step 1: Failing tests:**

```fish
t "readkey V" V (echo -n V | __tcz_popup_readkey)
t "readkey S" S (echo -n S | __tcz_popup_readkey)
t "readkey E" E (echo -n E | __tcz_popup_readkey)
t "readkey D" D (echo -n D | __tcz_popup_readkey)
t "readkey O" O (echo -n O | __tcz_popup_readkey)
```

- [ ] **Step 2: Run.** FAIL (uppercase bytes fall to `other`).

- [ ] **Step 3: Implement.** readkey single-byte cases beside the lowercase ones:

```fish
        case 56; echo V; return                      # V (theme-picker: vividness backward)
        case 53; echo S; return                      # S (theme-picker: shape toggle)
        case 45; echo E; return                      # E (theme-picker: ease toggle)
        case 44; echo D; return                      # D (theme-picker: contrast backward)
        case 4f; echo O; return                      # O (theme-picker: rotate backward)
```

Picker dispatch — fold into the existing arms (S/E share their lowercase toggles) and add the reverse arms:

```fish
            case v
                switch "$viv"
                    case soft;     set viv balanced
                    case balanced; set viv vivid
                    case '*';      set viv soft
                end
                set flashfield vividness
                __tcz_thp_reload
            case V
                switch "$viv"
                    case vivid;    set viv balanced
                    case balanced; set viv soft
                    case '*';      set viv vivid
                end
                set flashfield vividness
                __tcz_thp_reload
            case s S
                test "$shape" = arc; and set shape flat; or set shape arc
                set flashfield shape
                __tcz_thp_reload
            case e E
                test "$ease" = linear; and set ease cubic; or set ease linear
                set flashfield ease
                __tcz_thp_reload
            case D
                switch "$contrast"
                    case auto;    set contrast darker
                    case darker;  set contrast lighter
                    case '*';     set contrast auto
                end
                set flashfield contrast
                __tcz_thp_reload
            case O
                set rotate (math "($rotate + 4) % 5")
                set flashfield rotate
                __tcz_thp_reload
```

(`case s S` / `case e E` merge the lowercase arm — delete the separate lowercase arms when merging; `v`/`d`/`o` keep separate lowercase arms with their existing forward logic + their Task 3 flashfield lines.)

- [ ] **Step 4: Docs.** README Theming picker paragraph: one sentence — "Hold shift on a cycling key (V/S/E/D/O) to step it backward; changed values flash blue for half a second." CLAUDE.md theme-v3 paragraph: append one compact sentence recording this wave (in-process engine + cache + rotate-permutation ≈ subprocess-free keypresses, measured root cause = per-press config-loaded fish -c, worst on macOS; timed `#5fa8e8` change-flash; shift-reverse; spec `2026-07-17-picker-performance-flash-design.md`; live smoke pending).

- [ ] **Step 5: Full gate.** `fish -c 'for t in tests/test-*.fish; fish $t; end'` AND the same under `fish --no-config -c` — all 8 suites ALL PASS.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat(theme): shift-reverse knob cycling (V/S/E/D/O) + docs"`

---

## Post-plan (not tasks)

- Final whole-branch review (opus), then `superpowers:finishing-a-development-branch` (house default: merge to main + push).
- Runtime-only, user live smoke after `fisher update`: felt latency on Mac + iPad (the headline), phase scrubbing, flash timing/color, shift keys through ShellFish and Mac keyboards, `o` instant-ness.
