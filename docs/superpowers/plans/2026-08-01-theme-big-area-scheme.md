# Big-Area Scheme Derivation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a theme's relationship move the two *large* areas (status bar and tab bar) instead of the endcap, so a scheme reads as a palette built around the seed.

**Architecture:** `__tmux_lives_theme_curve` is rewritten. The seed anchors one large area (chosen by `--place`); the relationship's signed hue travel separates the *other* large area from it; the endcap becomes a quiet bridge at half the travel, floored at a calibrated per-hue-family minimum separation. Depth (lightness) is fixed per role and never moves — hue differentiates, lightness coheres. The endcap taper is deleted, `--place low|high` is retired, and the catalog is retiered. **The ink (`__tmux_lives_theme_accents`) is not touched.**

**Tech Stack:** fish 4.7.1, tmux 3.3a. Pure-fish OKLCH colour maths already in `conf.d/tmux-lives-install.fish`. Tests are plain fish scripts under `tests/`.

**Spec:** `docs/superpowers/specs/2026-08-01-theme-big-area-scheme-design.md`

**Branch:** `feat/big-area-scheme` off `main`.

## Global Constraints

- **Zero net new files** in `conf.d/` or `functions/`. All engine changes go in the existing `conf.d/tmux-lives-install.fish`. New functions are underscore-prefixed. (Test files and docs don't count.)
- **`math` has NO comparison operators.** fish's `test` does compare floats (`-lt`/`-gt`/`-ge`). Compute `abs(...)` into a variable first, then `test` it. Every existing float comparison in this file follows that shape — match it.
- **A command substitution in command position is a fish syntax error.** Capture into a variable first.
- **Never write the quoted-math-index shape** (a double-quoted variable whose index is a `math` call). It is a fish "Invalid index value" error and a grep guard bans it. The guard matches **comments too** — describe the shape in prose, never spell it out, or you will trip the guard while explaining it.
- **A `set -a` argument that concatenates a string with a zero-output command substitution collapses to an empty list**, silently dropping the whole line. Compute into a variable first, then interpolate it **quoted**.
- **Unquoted `#hex` in a rendered fragment line is a tmux comment.** Single-quote hex values in fragment output. (Not expected to come up here — no fragment lines change — but it is the standing rule for this file.)
- **Deployment is the user's `fisher update`.** Never copy anything into `~/.config/fish/`. Commit and push; stop there.
- **The agent Bash tool is zsh, not bash.** `cmd 2>&1 >/dev/null | wc -c` leaks stdout into the pipe — wrap stderr-byte checks in `bash -c '…'`. Write commit messages to a file and use `git commit -F`; backticks and `$0` in a double-quoted `-m` get expanded.
- **Gate for every task:** all 8 suites green under **both** plain `fish` and `fish --no-config`.

  ```bash
  bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish "$t" </dev/null 2>&1 | tail -1; done'
  bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish --no-config "$t" </dev/null 2>&1 | tail -1; done'
  ```

  Baseline at the start of this work: all 8 `ALL PASS`, `test-tmux-install.fish` at **492**.
- Each test file opens with an identical `XDG_CONFIG_HOME` self-re-exec isolation guard. **Do not touch it.** It is why `set -U` in tests cannot damage the developer's real universals.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `conf.d/tmux-lives-install.fish` | The whole install-side engine: OKLCH core, theme derivation, catalog, `setup` CLI, fragment renderer, migrations | Modified — one new function, one rewritten, one deleted, catalog retiered, CLI validator + help row narrowed, one new migration |
| `tests/test-tmux-install.fish` | Engine + CLI + fragment assertions | Modified — taper tests deleted, curve tests replaced, family/bridge/anchor/travel/ink/migration tests added, catalog counts updated |
| `docs/superpowers/plans/2026-08-01-theme-big-area-scheme.md` | This plan | Created |
| `CLAUDE.md` | The project's living record | Modified in the final task |

No other file changes. `functions/tmux-categorize.fish` (the picker) is untouched: both its `__tmux_lives_theme_palette` call sites stay 9-arg, and it renders whatever the catalog and engine produce.

---

## Task 1: The family table, and a pin on the ink

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — add `__tmux_lives_theme_family` immediately after `__tmux_lives_theme_reldef` (currently ends at line 748), before `__tmux_lives_theme_taper`
- Test: `tests/test-tmux-install.fish` — new section after the `# ---- v4: relationship table ----` block (currently ends at line 1004)

**Interfaces:**
- Consumes: `__tmux_lives_norm360 <hue>` → hue wrapped into `[0,360)`; `__tmux_lives_theme_accents <barHex> <capHex>` → 4 lines `sep active windows text`
- Produces: `__tmux_lives_theme_family <hue>` → one integer, the minimum hue separation in degrees the endcap keeps from the bar. Task 2 and Task 3 both call it.

Two pure additions the rewrite depends on: the helper it will call, and the guard proving what it must not disturb.

- [ ] **Step 1: Create the branch**

```bash
cd /home/bitsaver/workspace/tmux-lives
git checkout -b feat/big-area-scheme
```

- [ ] **Step 2: Write the failing tests**

Insert into `tests/test-tmux-install.fish` immediately after the line `t "valid junk"  1 (__tmux_lives_theme_valid junk; echo $status)`:

```fish

# ---- v5: kin-cap family table ----
# Fitted in the 2026-07-20 calibration study (4 rounds, user as blind subject, ~84% of
# judgments explained; the rule-generated validation batch scored 9/10 vs 5/10 pre-rule).
# Restored from the v3.3 kincap rule the v4 rewrite deleted.
t "family warm/earth 40"           40 (__tmux_lives_theme_family 60)
t "family olive/green 20"          20 (__tmux_lives_theme_family 125)
t "family teal 30"                 30 (__tmux_lives_theme_family 185)
t "family blue 25"                 25 (__tmux_lives_theme_family 240)
t "family purple 18"               18 (__tmux_lives_theme_family 300)
t "family red low 15"              15 (__tmux_lives_theme_family 10)
t "family red high 15"             15 (__tmux_lives_theme_family 350)
t "family lower bound 40 is warm"  40 (__tmux_lives_theme_family 40)
t "family upper bound 90 is olive" 20 (__tmux_lives_theme_family 90)
t "family wraps past 360"          20 (__tmux_lives_theme_family 485)

# ---- the ink is NOT part of the big-area rewrite: pin it byte-identical ----
# __tmux_lives_theme_accents is deliberately untouched (the user's instruction: "the ink
# isn't what needs changing currently"). These four hexes are its output at a fixed bar,
# captured from the pre-rewrite engine. If a later refactor drifts the ink, this fails.
set -l ink (__tmux_lives_theme_accents '#405733' '#6cb040')
t "ink returns 4"  4         (count $ink)
t "ink sep"        '#7f8a78' $ink[1]
t "ink active"     '#cfdcc9' $ink[2]
t "ink windows"    '#a0b198' $ink[3]
t "ink text"       '#cfdcc8' $ink[4]
# the cap argument is declared and unused — documented as intentional for now, not a bug
# to fix in this cycle. Changing the cap must not change the ink.
set -l ink2 (__tmux_lives_theme_accents '#405733' '#ff0000')
t "ink is independent of the cap argument" "$ink" "$ink2"
```

- [ ] **Step 3: Run the tests and verify they fail**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -20
```

Expected: `FAIL` lines for every `family …` assertion (the function does not exist yet, so the command substitution is empty). The six `ink …` assertions should already **pass** — they pin existing behaviour.

- [ ] **Step 4: Write the implementation**

Insert into `conf.d/tmux-lives-install.fish` immediately after the `end` that closes `__tmux_lives_theme_reldef`:

```fish

function __tmux_lives_theme_family --argument-names hue --description 'v5 kin-cap family table: OKLCH bar hue -> the minimum hue separation, in degrees, that the endcap keeps from the bar. Fitted in the 2026-07-20 calibration study (4 rounds, blind numbered tiles; ~84% of judgments explained, and the rule-generated validation batch scored 9/10 vs 5/10 pre-rule). Restored from the v3.3 kincap rule the v4 rewrite deleted, in the role it was actually fitted for: bar and endcap judged as a PAIR. Blue and red/pink are untested extrapolations — first suspects if a future seed misbehaves.'
    set -l h (__tmux_lives_norm360 $hue)
    if test $h -ge 40; and test $h -lt 90
        echo 40
    else if test $h -ge 90; and test $h -lt 160
        echo 20
    else if test $h -ge 160; and test $h -lt 210
        echo 30
    else if test $h -ge 210; and test $h -lt 280
        echo 25
    else if test $h -ge 280; and test $h -lt 330
        echo 18
    else
        echo 15
    end
end
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -5
```

Expected: `ALL PASS (508)` — 492 baseline + 16 new assertions (10 family + 6 ink).

- [ ] **Step 6: Run the full gate, both fish modes**

```bash
bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish "$t" </dev/null 2>&1 | tail -1; done'
bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish --no-config "$t" </dev/null 2>&1 | tail -1; done'
```

Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 7: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(theme): restore the calibrated kin-cap family table; pin the ink

__tmux_lives_theme_family maps an OKLCH bar hue to the minimum hue separation
the endcap keeps from it — the table fitted in the 2026-07-20 calibration study
and deleted in the v4 rewrite. The big-area curve uses it as the bridge floor.

Also pins __tmux_lives_theme_accents byte-identical at a fixed bar. The ink is
deliberately out of scope for this rewrite, and the pin is what proves it stayed
that way — including that the declared-but-unused cap argument still changes
nothing.
EOF
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -F /tmp/msg.txt
```

---

## Task 2: Rewrite the curve — anchor, travel, bridge

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — delete `__tmux_lives_theme_taper` (currently lines 750-762), rewrite `__tmux_lives_theme_curve` (currently lines 764-824)
- Test: `tests/test-tmux-install.fish` — delete the `# ---- v4: endcap taper ----` block (currently lines 1006-1023), replace the `# ---- v4: curve (bar/tabs/cap) ----` block (currently lines 1025-1058)

**Interfaces:**
- Consumes: `__tmux_lives_theme_family <hue>` (Task 1); `__tmux_lives_theme_reldef <name>` → signed degrees; `__tmux_lives_hex_to_rgb01`, `__tmux_lives_rgb_to_oklch`, `__tmux_lives_oklch_hex L C H`, `__tmux_lives_norm360`
- Produces: `__tmux_lives_theme_curve <seedHex> <relationship> <place> <mode> <phase>` → 3 lines `bar tabs cap`. **Signature unchanged**, so `__tmux_lives_theme_palette` and both picker call sites need no edit.

`place=cap` is **not** handled in this task — it falls through to the default branch and behaves as `bar`. Task 3 adds it. That is a working intermediate: cap-placed catalog rows still render a valid 7-hex palette, just not their intended one.

- [ ] **Step 1: Write the failing tests**

In `tests/test-tmux-install.fish`, **delete** the entire `# ---- v4: endcap taper ----` block (from the `# ---- v4: endcap taper ----` comment through the `t "taper tabsC follows" …` line inclusive), and **replace** the `# ---- v4: curve (bar/tabs/cap) ----` block (from that comment through `t "curve bad rel empty" …` inclusive) with:

```fish
# ---- v5: curve — two large areas and a bridge ----
function _oklch_of --argument-names hex   # -> "L C H"
    set -l r (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $r[1] $r[2] $r[3]
end
function _dhue --argument-names a b       # circular |a-b| in degrees
    set -l d (math "abs($a - $b)")
    test $d -gt 180; and set d (math "360 - $d")
    echo $d
end
set -l seed '#5f772b'          # L .533  C .106  H 124.7 -> family 20
set -l so (_oklch_of $seed)
set -l tri (__tmux_lives_theme_curve $seed ember bar derived 0)
t "curve returns 3" 3 (count $tri)
for i in 1 2 3
    t "curve role $i is hex" 1 (string match -qr '^#[0-9a-f]{6}$' -- $tri[$i]; and echo 1; or echo 0)
end

# ANCHOR INVARIANCE — the placed large area never moves between relationships.
# This is the whole point of the rewrite: there is always something to defer to.
set -l anchor_bar
set -l anchor_tabs
for r in mono wheat mint amber sage ember teal coral
    set -l pb (__tmux_lives_theme_curve $seed $r bar derived 0)
    set -l pt (__tmux_lives_theme_curve $seed $r tabs derived 0)
    set -a anchor_bar $pb[1]
    set -a anchor_tabs $pt[2]
end
t "anchor: the bar is invariant at place=bar"   1 (test (count (printf '%s\n' $anchor_bar | sort -u)) -eq 1; and echo 1; or echo 0)
t "anchor: the tabs are invariant at place=tabs" 1 (test (count (printf '%s\n' $anchor_tabs | sort -u)) -eq 1; and echo 1; or echo 0)
set -l abo (_oklch_of $anchor_bar[1])
set -l dseed (_dhue $abo[3] $so[3])
t "anchor: the bar holds the seed hue" 1 (test $dseed -lt 2; and echo 1; or echo 0)

# TRAVEL — the OTHER large area sits |sd| away from the anchor.
# Tolerance 2 deg: assertions run on RENDERED hexes, which quantise to 8-bit sRGB and
# gamut-clamp. Measured worst error at this seed is 0.99 deg.
set -l travbad 0
for r in mono wheat mint amber sage ember teal coral
    set -l sd (__tmux_lives_theme_reldef $r)
    set -l p (__tmux_lives_theme_curve $seed $r bar derived 0)
    set -l hb (_oklch_of $p[1])
    set -l ht (_oklch_of $p[2])
    set -l got (_dhue $ht[3] $hb[3])
    set -l want (math "abs($sd)")
    set -l err (math "abs($got - $want)")
    test $err -lt 2; or set travbad (math $travbad + 1)
end
t "travel: the tab bar sits |sd| from the bar" 0 $travbad

# BRIDGE — |Hcap - Hbar| == max(|sd|/2, family(Hbar)).
# Deliberately NOT "the cap lies between the bar and the tabs": at low travel the family
# floor dominates, so at mono the tabs sit at the bar's hue while the cap sits `family`
# away from it. The floor is the guarantee the endcap never collapses into the bar.
# Measured worst error at this seed is 0.93 deg.
set -l bridgebad 0
for pl in bar tabs
    for r in mono wheat mint amber sage ember teal coral
        set -l sd (__tmux_lives_theme_reldef $r)
        set -l p (__tmux_lives_theme_curve $seed $r $pl derived 0)
        set -l hb (_oklch_of $p[1])
        set -l hc (_oklch_of $p[3])
        set -l fam (__tmux_lives_theme_family $hb[3])
        set -l want (math "max(abs($sd) / 2, $fam)")
        set -l got (_dhue $hc[3] $hb[3])
        set -l err (math "abs($got - $want)")
        test $err -lt 2; or set bridgebad (math $bridgebad + 1)
    end
end
t "bridge: the cap sits max(|sd|/2, family) from the bar" 0 $bridgebad
set -l mp (__tmux_lives_theme_curve $seed mono bar derived 0)
set -l mhb (_oklch_of $mp[1])
set -l mhc (_oklch_of $mp[3])
set -l mfloor (_dhue $mhc[3] $mhb[3])
t "bridge: the cap never collapses into the bar at mono" 1 (test $mfloor -gt 15; and echo 1; or echo 0)

# DEPTH — fixed per role, never moves. Hue differentiates, lightness coheres.
set -l dp (__tmux_lives_theme_curve $seed teal bar derived 0)
set -l dLb (_oklch_of $dp[1])
set -l dLt (_oklch_of $dp[2])
set -l dLc (_oklch_of $dp[3])
t "depth: the bar is darker than the tab bar" 1 (test $dLb[1] -lt $dLt[1]; and echo 1; or echo 0)
set -l capstep (math "abs($dLc[1] - $dLb[1])")
t "depth: the cap is one 0.10 step off the bar" 1 (test $capstep -gt 0.08; and test $capstep -lt 0.12; and echo 1; or echo 0)

# MONO IS UNCHANGED — the two large areas are byte-identical to the pre-rewrite engine.
# The tab chroma constant 0.0713 is exactly what the deleted taper produced at zero
# travel (capC 0.115 * 0.62), so mono's ramp did not move. Verified at three seeds.
set -l m (__tmux_lives_theme_curve $seed mono bar derived 0)
t "mono bar unchanged by the rewrite"  '#44502f' $m[1]
t "mono tabs unchanged by the rewrite" '#5e7239' $m[2]

# LITERAL — the placed role renders the seed's exact hex.
set -l lb (__tmux_lives_theme_curve $seed coral bar literal 0)
set -l lt (__tmux_lives_theme_curve $seed coral tabs literal 0)
t "curve literal bar = seed"  '#5f772b' $lb[1]
t "curve literal tabs = seed" '#5f772b' $lt[2]

# bad inputs -> nothing
t "curve bad seed empty" 0 (count (__tmux_lives_theme_curve 'notahex' ember bar derived 0))
t "curve bad rel empty"  0 (count (__tmux_lives_theme_curve $seed nope bar derived 0))

# the taper is gone — grep the SOURCE, not the runtime function table (a `functions -q`
# check would falsely differ between plain fish, which loads the developer's live fisher
# install, and `fish --no-config`, which does not).
t "endcap taper gone" 0 (grep -c '__tmux_lives_theme_taper' $plugindir/conf.d/tmux-lives-install.fish)
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | grep FAIL | head -20
```

Expected: failures on `anchor: …`, `travel: …`, `bridge: …`, `mono … unchanged`, `curve literal tabs = seed`, and `endcap taper gone` — the old engine still puts the travel on the endcap and still defines the taper.

- [ ] **Step 3: Delete the taper**

In `conf.d/tmux-lives-install.fish`, delete the entire `__tmux_lives_theme_taper` function — the `function __tmux_lives_theme_taper …` line through its closing unindented `end`, and the blank line after it.

- [ ] **Step 4: Replace the curve**

Replace the whole `__tmux_lives_theme_curve` function (from `function __tmux_lives_theme_curve …` through its closing unindented `end`) with:

```fish
function __tmux_lives_theme_curve --argument-names seedHex relationship place mode phase --description 'v5 core: TWO LARGE AREAS AND A BRIDGE. The seed anchors one large area (place = bar|tabs); the relationship signed travel separates the OTHER large area from it; the endcap bridges at half that travel, floored at the calibrated family separation so it never collapses into the bar. Depth is FIXED per role — hue differentiates, lightness coheres. Derived: seed L/C damped into the ramp; literal: the placed role renders the seed verbatim. -> bar tabs cap (3 hexes). Non-hex seed / unknown relationship -> nothing.'
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l sd (__tmux_lives_theme_reldef "$relationship")
    test -n "$sd"; or return
    test -n "$phase"; or set phase 0
    set -l rgb (__tmux_lives_hex_to_rgb01 $seedHex)
    set -l ok (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
    set -l sL $ok[1]; set -l sC $ok[2]; set -l sH $ok[3]
    # damped seed influence on the derived ramp
    # (fish `test` compares floats with -lt/-gt; `math` has NO comparison ops)
    set -l Ldamp (math "0.5 * ($sL - 0.51)")
    test $Ldamp -lt -0.10; and set Ldamp -0.10
    test $Ldamp -gt 0.10; and set Ldamp 0.10
    set -l Cscale (math "0.5 * ($sC / 0.078 - 1) + 1")
    test $Cscale -lt 0.6; and set Cscale 0.6
    test $Cscale -gt 1.4; and set Cscale 1.4
    # depth is FIXED per role: the bar is the dark ground, the tab bar one step lighter.
    # 0.0713 is exactly what the deleted taper produced at zero travel (0.115 * 0.62),
    # so mono's two large areas are byte-identical to the pre-rewrite engine.
    set -l Lbar (math "0.40 + $Ldamp")
    set -l Ltabs (math "0.51 + $Ldamp")
    set -l Cbar (math "0.045 * $Cscale")
    set -l Ctabs (math "0.0713 * $Cscale")
    # signed bridge offset, measured FROM THE BAR: half the tab bar's travel. At
    # place=tabs the bar is the one that travelled, so the tabs sit at -sd from it and
    # the cap comes back toward them. Direction is the travel's, + when travel is zero.
    set -l half (math "$sd / 2")
    test "$place" = tabs; and set half (math "0 - $sd / 2")
    set -l dir 1
    test $half -lt 0; and set dir -1
    # the seed anchors one large area; the OTHER travels by sd.
    set -l Hbar $sH
    set -l Htabs $sH
    switch "$place"
        case tabs
            set Hbar (math "$sH + $sd")
        case '*'
            set Htabs (math "$sH + $sd")
    end
    set Hbar (__tmux_lives_norm360 (math "$Hbar + $phase"))
    set Htabs (__tmux_lives_norm360 (math "$Htabs + $phase"))
    # clamp the L values (unrolled — avoids the $$var-indirection gotcha)
    test $Lbar -lt 0.05; and set Lbar 0.05
    test $Lbar -gt 0.95; and set Lbar 0.95
    test $Ltabs -lt 0.05; and set Ltabs 0.05
    test $Ltabs -gt 0.95; and set Ltabs 0.95
    set -l bar (__tmux_lives_oklch_hex $Lbar $Cbar $Hbar)
    set -l tabs (__tmux_lives_oklch_hex $Ltabs $Ctabs $Htabs)
    # literal: the placed role renders the seed's EXACT hex (verbatim, not a recompute —
    # an OKLCH round-trip can drift a channel). The anchor already lands that role's
    # derived hue on the seed hue; this pins its L and C to the seed too.
    if test "$mode" = literal
        set -l s (string lower -- $seedHex)
        switch "$place"
            case tabs; set tabs $s
            case '*';  set bar $s
        end
    end
    # endcap = quiet BRIDGE off the RENDERED bar (so `literal` is honoured): half the
    # travel, floored at the calibrated family separation.
    set -l brgb (__tmux_lives_hex_to_rgb01 $bar)
    set -l bok (__tmux_lives_rgb_to_oklch $brgb[1] $brgb[2] $brgb[3])
    set -l Lcap (math "$bok[1] + 0.10")
    test $bok[1] -ge 0.55; and set Lcap (math "$bok[1] - 0.10")
    test $Lcap -lt 0.05; and set Lcap 0.05
    test $Lcap -gt 0.95; and set Lcap 0.95
    set -l mag (math "abs($half)")
    set -l minsep (__tmux_lives_theme_family $bok[3])
    test $mag -lt $minsep; and set mag $minsep
    set -l Hcap (__tmux_lives_norm360 (math "$bok[3] + $dir * $mag"))
    set -l cap (__tmux_lives_oklch_hex $Lcap $bok[2] $Hcap)
    printf '%s\n' $bar $tabs $cap
end
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -5
```

Expected: `ALL PASS`. The count drops by the 12 deleted taper assertions and 5 deleted curve assertions, and rises by the ~20 new ones.

- [ ] **Step 6: Run the full gate, both fish modes**

Use the two commands from Global Constraints. Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 7: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(theme): the big areas carry the scheme, not the endcap

The v4 curve put the roles at fixed positions (bar t=0, tabs t=0.42, cap t=1)
with hue H0 + sd*t, so the endcap absorbed the relationship's ENTIRE travel and
the bar absorbed none. At place=bar the bar's hue was exactly the seed's in every
relationship — byte-identical across all eight — so a scheme was defined by the
smallest swath on screen while the two largest areas stayed put.

Now the seed anchors one large area, the relationship separates the OTHER large
area from it, and the endcap bridges at half the travel with a floor at the
calibrated family separation. Depth is fixed per role.

Deletes the taper: it existed only to mute far-travelled endcaps, and the endcap
no longer travels far. That also retires the ember-knee constant that cost a full
debugging cycle.

mono is unchanged — the tab chroma constant 0.0713 is exactly what the taper
produced at zero travel, verified byte-identical at three seeds.

place=cap is not handled yet; it falls through to the bar branch. Next task.
EOF
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -F /tmp/msg.txt
```

---

## Task 3: Cap placement — the seed on the endcap

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_curve` (the `switch "$place"` blocks and the cap computation)
- Test: `tests/test-tmux-install.fish` — new section immediately after the `t "endcap taper gone" …` line from Task 2

**Interfaces:**
- Consumes: everything Task 2 produces
- Produces: no new function. `__tmux_lives_theme_curve` gains `place=cap` support — the cap carries the seed, and the bar is solved backwards.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-tmux-install.fish` right after `t "endcap taper gone" …`:

```fish

# ---- v5: cap placement — the seed on the endcap, the bar solved backwards ----
# The accent-led minority. Neither large area is anchored here; the endcap is.
set -l cp (__tmux_lives_theme_curve $seed amber cap derived 0)
t "cap placement returns 3" 3 (count $cp)
set -l cpo (_oklch_of $cp[3])
set -l cperr (_dhue $cpo[3] $so[3])
t "cap placement: the cap carries the seed hue" 1 (test $cperr -lt 2; and echo 1; or echo 0)
set -l cpl (__tmux_lives_theme_curve $seed coral cap literal 0)
t "cap placement literal = seed exactly" '#5f772b' $cpl[3]
# literal at cap must pin ONLY the cap — the bar is still derived
t "cap placement literal leaves the bar derived" 0 (test "$cpl[1]" = '#5f772b'; and echo 1; or echo 0)
# the bar is solved BACK from the seed by the family separation, so it is NOT at the seed hue
set -l cpb (_oklch_of $cp[1])
set -l cpbd (_dhue $cpb[3] $so[3])
t "cap placement: the bar steps off the seed hue" 1 (test $cpbd -gt 15; and echo 1; or echo 0)
# the cap is the anchor here, so it is the invariant one
set -l capbad 0
for r in mono wheat mint amber sage ember teal coral
    set -l p (__tmux_lives_theme_curve $seed $r cap derived 0)
    set -l o (_oklch_of $p[3])
    set -l d (_dhue $o[3] $so[3])
    test $d -lt 2; or set capbad (math $capbad + 1)
end
t "cap placement: the cap holds the seed hue in every relationship" 0 $capbad
# and the two large areas still sit |sd| apart
set -l cptrav 0
for r in mono wheat mint amber sage ember teal coral
    set -l sd (__tmux_lives_theme_reldef $r)
    set -l p (__tmux_lives_theme_curve $seed $r cap derived 0)
    set -l hb (_oklch_of $p[1])
    set -l ht (_oklch_of $p[2])
    set -l got (_dhue $ht[3] $hb[3])
    set -l want (math "abs($sd)")
    set -l err (math "abs($got - $want)")
    test $err -lt 2; or set cptrav (math $cptrav + 1)
end
t "cap placement: the large areas still sit |sd| apart" 0 $cptrav
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | grep FAIL | head
```

Expected: `cap placement: the cap carries the seed hue`, `cap placement literal = seed exactly`, `cap placement: the bar steps off the seed hue`, and `the cap holds the seed hue in every relationship` all fail — `cap` currently falls through to the bar branch.

- [ ] **Step 3: Add the cap branch to the hue switch**

In `__tmux_lives_theme_curve`, replace the placement switch:

```fish
    set -l Hbar $sH
    set -l Htabs $sH
    switch "$place"
        case tabs
            set Hbar (math "$sH + $sd")
        case '*'
            set Htabs (math "$sH + $sd")
    end
```

with:

```fish
    set -l capseed 0
    set -l Hbar $sH
    set -l Htabs $sH
    switch "$place"
        case tabs
            set Hbar (math "$sH + $sd")
        case cap
            # the seed lands on the ENDCAP; solve the bar backwards. The bridge offset
            # depends on the BAR's hue, which is what we are solving for, so the family
            # separation is evaluated at the SEED's hue — a deliberate single pass, not
            # an iteration. Deterministic and testable.
            set capseed 1
            set -l m0 (math "abs($sd / 2)")
            set -l f0 (__tmux_lives_theme_family $sH)
            test $m0 -lt $f0; and set m0 $f0
            set Hbar (math "$sH - $dir * $m0")
            set Htabs (math "$Hbar + $sd")
        case '*'
            set Htabs (math "$sH + $sd")
    end
```

- [ ] **Step 4: Teach `literal` not to pin the bar at cap placement**

Replace the literal switch:

```fish
        switch "$place"
            case tabs; set tabs $s
            case '*';  set bar $s
        end
```

with:

```fish
        switch "$place"
            case tabs; set tabs $s
            case cap;  # the cap is the seed — pinned below, where the cap is built
            case '*';  set bar $s
        end
```

An empty `case` body is legal fish; `cap` matches here and falls through to neither of the other branches.

- [ ] **Step 5: Branch the cap computation**

Replace the bridge computation:

```fish
    set -l mag (math "abs($half)")
    set -l minsep (__tmux_lives_theme_family $bok[3])
    test $mag -lt $minsep; and set mag $minsep
    set -l Hcap (__tmux_lives_norm360 (math "$bok[3] + $dir * $mag"))
    set -l cap (__tmux_lives_oklch_hex $Lcap $bok[2] $Hcap)
```

with:

```fish
    set -l cap
    if test $capseed -eq 1
        # the seed is placed HERE: verbatim in literal, at cap depth on the seed's hue
        # in derived. Either way the cap is the anchor and does not move by relationship.
        if test "$mode" = literal
            set cap (string lower -- $seedHex)
        else
            set cap (__tmux_lives_oklch_hex $Lcap $bok[2] (__tmux_lives_norm360 (math "$sH + $phase")))
        end
    else
        set -l mag (math "abs($half)")
        set -l minsep (__tmux_lives_theme_family $bok[3])
        test $mag -lt $minsep; and set mag $minsep
        set -l Hcap (__tmux_lives_norm360 (math "$bok[3] + $dir * $mag"))
        set cap (__tmux_lives_oklch_hex $Lcap $bok[2] $Hcap)
    end
```

- [ ] **Step 6: Update the function description**

Change `place = bar|tabs` in the `--description` to:

```
place = bar|tabs anchors a LARGE area; place = cap anchors the endcap instead (the accent-led minority) and solves the bar backwards
```

- [ ] **Step 7: Run the tests and verify they pass**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -5
```

Expected: `ALL PASS`.

- [ ] **Step 8: Run the full gate, both fish modes**

Use the two commands from Global Constraints. Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 9: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(theme): cap placement — the seed anchors the endcap, the bar solves backwards

The accent-led minority: neither large area is anchored, the endcap is. The cap
carries the seed (verbatim in literal, at cap depth on the seed's hue in derived),
the bar is solved back from it by the family separation, and the tab bar travels
by the relationship from there — so the two large areas still sit |sd| apart.

The family separation is evaluated at the SEED's hue rather than the bar's,
because the bar is what we are solving for. A deliberate single pass, not an
iteration.
EOF
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -F /tmp/msg.txt
```

---

## Task 4: Retire `--place low|high`

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — five places name the retired tokens and **all five must change or the Step 1 guard fails**: the `render_fragment` argv comment (line ~29), `__tmux_lives_theme_cmd`'s `--description` (line ~911), the `--rotate` error message (line ~970), the `--place` validator (lines ~1019-1026), and the setup-help place row (line ~1168). Plus a new `__tmux_lives_migrate_v41` beside the other migrations (after `__tmux_lives_migrate_v4`, line ~1334), wired into `_tmux_lives_post_update`. (The curve's own `case low`/`case high` are already gone — Task 2's rewrite dropped them.)
- Test: `tests/test-tmux-install.fish` — additions after `t "theme: invalid mode mutates nothing" …` (line ~842), and after the v4 migration block

**Interfaces:**
- Consumes: nothing new
- Produces: `__tmux_lives_migrate_v41` → rewrites a stored `tmux_lives_theme_place` of `low`/`high` to `bar`. Idempotent, returns 0.

`low`/`high` mean "partway along the curve". The big-area model has no curve to sit partway along. Neither has ever had a catalog row — the CLI was the only route.

- [ ] **Step 1: Write the failing tests**

Insert after `t "theme: invalid mode mutates nothing" 0 (set -q tmux_lives_theme_mode; and echo 1; or echo 0)`:

```fish
t "theme: --place low rejected"  1 (__tmux_lives_theme_cmd ember --place low 2>/dev/null; echo $status)
t "theme: --place high rejected" 1 (__tmux_lives_theme_cmd ember --place high 2>/dev/null; echo $status)
t "theme: --place error names the three survivors" 1 (__tmux_lives_theme_cmd ember --place low 2>&1 | string match -q '*bar, tabs, cap*'; and echo 1; or echo 0)
t "theme: --place low mutates nothing" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "theme: --rotate error no longer offers low/high" 0 (__tmux_lives_theme_cmd ember --rotate 2 2>&1 | string match -q '*low*'; and echo 1; or echo 0)
```

And append a migration block immediately after the existing `# --- v4: migration ----` section (find it by the `__tmux_lives_migrate_v4` assertions):

```fish

# --- v4.1: place low/high retirement ---------------------------------------------
set -U tmux_lives_theme_place low
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: low -> bar" bar $tmux_lives_theme_place
set -U tmux_lives_theme_place high
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: high -> bar" bar $tmux_lives_theme_place
set -U tmux_lives_theme_place tabs
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: tabs is left alone" tabs $tmux_lives_theme_place
set -U tmux_lives_theme_place cap
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: cap is left alone" cap $tmux_lives_theme_place
set -U tmux_lives_theme_place low
__tmux_lives_migrate_v41 >/dev/null
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41 is idempotent" bar $tmux_lives_theme_place
set -e tmux_lives_theme_place
__tmux_lives_migrate_v41 >/dev/null
t "migrate v41: an unset place stays unset" 0 (set -q tmux_lives_theme_place; and echo 1; or echo 0)
t "post-update runs migrate v41" 1 (awk '/^function _tmux_lives_post_update/,/^end$/' $plugindir/conf.d/tmux-lives-install.fish | grep -c '__tmux_lives_migrate_v41')
t "help place row drops low/high" 0 (__tmux_lives_setup_help_lines | string match -q '*low|high*'; and echo 1; or echo 0)
# The retired tokens survive ONLY inside the migration that retires them. awk strips
# that function body (its closing `end` is unindented at column 0; nested if/for `end`s
# are indented and do not match) before grepping what remains. Two shapes are banned:
# the switch form `low high` and the help/error form `low|high`.
# NB this grep matches COMMENTS too — if you need to explain the retirement anywhere
# else in the install file, describe it, don't spell either shape out.
t "no low/high switch token outside the migration" 0 (awk '/^function __tmux_lives_migrate_v41/,/^end$/ {next} {print}' $plugindir/conf.d/tmux-lives-install.fish | grep -c 'low high')
t "no low/high help token outside the migration"   0 (awk '/^function __tmux_lives_migrate_v41/,/^end$/ {next} {print}' $plugindir/conf.d/tmux-lives-install.fish | grep -cF 'low|high')
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | grep FAIL | head
```

Expected: `--place low rejected` fails (still accepted, returns 0), the migration assertions fail (function undefined), and both greps fail.

- [ ] **Step 3: Narrow the `--place` validator**

In `__tmux_lives_theme_cmd`, change:

```fish
    if test $have_place -eq 1
        switch "$place"
            case bar tabs cap low high
            case '*'
                echo "tmux-lives setup theme: invalid place '$place' — valid: bar, tabs, cap, low, high" >&2
                return 1
        end
    end
```

to:

```fish
    if test $have_place -eq 1
        switch "$place"
            case bar tabs cap
            case '*'
                echo "tmux-lives setup theme: invalid place '$place' — valid: bar, tabs, cap" >&2
                return 1
        end
    end
```

- [ ] **Step 4: Update the `--rotate` error and the docstring**

Change the `--rotate` case message from `use --place bar|tabs|cap|low|high to move the seed instead` to:

```fish
                echo "tmux-lives setup theme: --rotate was removed in v4 — use --place bar|tabs|cap to move the seed instead" >&2
```

And in `__tmux_lives_theme_cmd`'s `--description`, change `[--place bar|tabs|cap|low|high]` to `[--place bar|tabs|cap]`.

- [ ] **Step 4b: Update the fragment argv comment**

`__tmux_lives_render_fragment` documents its argv positions in comments, and position 14 names the retired tokens. This is a **comment**, and the guard in Step 1 greps comments too — miss it and the guard fails with no functional change to point at. Change line ~29 from:

```fish
    set -l place $argv[14]        #   14 place       seed placement bar|tabs|cap|low|high ('' = bar)
```

to:

```fish
    set -l place $argv[14]        #   14 place       seed placement bar|tabs|cap ('' = bar)
```

- [ ] **Step 5: Update the setup-help row**

In `__tmux_lives_setup_help_lines`, change:

```fish
        "      --place <p>           bar|tabs|cap|low|high (default: bar)" \
```

to:

```fish
        "      --place <p>           bar|tabs|cap (default: bar)" \
```

Column alignment is unaffected — the description column starts at the same offset and the text is shorter.

- [ ] **Step 6: Add the migration**

Insert immediately after the `end` closing `__tmux_lives_migrate_v4`:

```fish

function __tmux_lives_migrate_v41 --description 'v4 -> v4.1 big-area migration: --place low|high meant "partway along the curve", and the big-area model has no curve to sit partway along — the seed anchors a large area (or the endcap). Rewrite a stored low/high to bar. Idempotent; runs on fisher update.'
    set -q tmux_lives_theme_place; or return 0
    contains -- "$tmux_lives_theme_place" low high; or return 0
    set -U tmux_lives_theme_place bar
    echo "tmux-lives: theme place low/high retired — the seed now anchors a large area; set to bar (see 'tmux-lives setup theme list')"
    return 0
end
```

- [ ] **Step 7: Wire it into the post-update handler**

In `_tmux_lives_post_update`, add the call after `__tmux_lives_migrate_v4`:

```fish
    __tmux_lives_migrate_v2
    __tmux_lives_migrate_v31
    __tmux_lives_migrate_v4
    __tmux_lives_migrate_v41
```

- [ ] **Step 8: Run the tests and verify they pass**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -5
```

Expected: `ALL PASS`.

- [ ] **Step 9: Run the full gate, both fish modes**

Use the two commands from Global Constraints. Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 10: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(theme): retire --place low|high

They meant "partway along the curve" and the big-area model has no curve to sit
partway along — the seed anchors a large area, or the endcap. Neither ever had a
catalog row; the CLI was the only route to them.

__tmux_lives_migrate_v41 rewrites a stored low/high to bar on fisher update,
idempotently, with a one-line notice — the shape v4 used to retire --rotate.
EOF
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -F /tmp/msg.txt
```

---

## Task 5: Retier the catalog

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_catalog` (lines ~710-728)
- Test: `tests/test-tmux-install.fish` — the catalog block (lines ~854-894)

**Interfaces:**
- Consumes: nothing new
- Produces: `__tmux_lives_theme_catalog` → **36** rows of `name|relationship|place|mode|default`; `__tmux_lives_theme_catalog_default` → the **14** flagged rows. The picker and `setup theme list` both read these and need no edit.

Bar and tab placements become symmetric (8 relationships × derived/literal each), since both are now first-class dominant placements. Cap-placed schemes survive as a four-row accent-led minority, ordered last. **The 14 default names are unchanged** — every one of today's defaults still exists under the new tiering.

- [ ] **Step 1: Write the failing tests**

Replace the catalog assertions. Change the two count lines:

```fish
t "catalog has 36 entries" 36 (count (__tmux_lives_theme_catalog))
t "catalog default is 14"  14 (count (__tmux_lives_theme_catalog_default))
```

and the subset check's literal `14` stays as-is. Then **delete** these four now-false assertions (the gaps they pinned are deliberately filled):

```fish
t "catalog: wheat has 5 rows" …
t "catalog: mint has 4 rows"  …
t "catalog: no mint at tabs (both rejected)" …
t "catalog: no wheat at tabs derived" …
```

and replace `t "catalog: cap placement holds exactly 13" …` with the block below. Per-tier counts are pinned **exactly** — a `>=` bound passed on the pre-cut catalog in the last weeding pass and caught nothing.

```fish
# Tier composition, pinned EXACTLY. bar and tabs are symmetric (8 relationships x
# derived/literal each) because both are now first-class dominant placements; cap
# survives as a 4-row accent-led minority, ordered last.
t "catalog: soft is 8 (bar derived)"   8 (count (__tmux_lives_theme_catalog | string match -r '\|bar\|derived\|'))
t "catalog: glow is 8 (bar literal)"   8 (count (__tmux_lives_theme_catalog | string match -r '\|bar\|literal\|'))
t "catalog: slate is 8 (tabs derived)" 8 (count (__tmux_lives_theme_catalog | string match -r '\|tabs\|derived\|'))
t "catalog: chip is 8 (tabs literal)"  8 (count (__tmux_lives_theme_catalog | string match -r '\|tabs\|literal\|'))
t "catalog: cap placement holds exactly 4" 4 (count (__tmux_lives_theme_catalog | string match -r '\|cap\|'))
t "catalog: every relationship appears at both large placements" 0 (set -l bad 0; for r in mono wheat mint amber sage ember teal coral; for pl in bar tabs; test (count (__tmux_lives_theme_catalog | string match -r "\|$r\|$pl\|")) -eq 2; or set bad (math $bad + 1); end; end; echo $bad)
# the cap rows are exactly the four that were already curated defaults
t "catalog: amber deep present" 1 (count (__tmux_lives_theme_catalog | string match -r '^amber deep\|'))
t "catalog: coral deep present" 1 (count (__tmux_lives_theme_catalog | string match -r '^coral deep\|'))
t "catalog: sage core present"  1 (count (__tmux_lives_theme_catalog | string match -r '^sage core\|'))
t "catalog: teal core present"  1 (count (__tmux_lives_theme_catalog | string match -r '^teal core\|'))
t "catalog: all four cap rows are defaults" 4 (count (__tmux_lives_theme_catalog_default | string match -r '\|cap\|'))
# cap rows sort LAST — the accent-led minority is at the bottom of the picker list
t "catalog: the last 4 rows are the cap rows" 4 (count (__tmux_lives_theme_catalog | tail -4 | string match -r '\|cap\|'))
# the 14 curated default NAMES are unchanged by the retiering
t "catalog: default names unchanged" "amber chip amber deep amber soft coral deep coral soft ember glow ember slate mint soft mono soft sage core sage glow teal core teal glow wheat soft" (__tmux_lives_theme_catalog_default | string replace -r '\|.*' '' | sort | string join ' ')
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | grep FAIL | head
```

Expected: the count and tier assertions fail against the 37-row catalog.

- [ ] **Step 3: Replace the catalog**

Replace the whole `__tmux_lives_theme_catalog` function with:

```fish
function __tmux_lives_theme_catalog --description 'v5 gallery catalog: 36 schemes as name|relationship|place|mode|default (1 = in the curated default 14). Tiers soft/glow/slate/chip/deep/core — bar, then tabs, then cap; derived before literal within each. bar and tabs are SYMMETRIC (all 8 relationships x both modes) because both are first-class dominant placements: the seed anchors one, the relationship moves the other. cap survives as a 4-row accent-led minority, ordered LAST — there neither large area is anchored, which is the inversion the big-area model exists to remove. Rows within a tier run safe -> wild by |travel|. Shared source of truth for the picker + setup theme list.'
    printf '%s\n' \
        'mono soft|mono|bar|derived|1'    'wheat soft|wheat|bar|derived|1' \
        'mint soft|mint|bar|derived|1'    'amber soft|amber|bar|derived|1' \
        'sage soft|sage|bar|derived|0'    'ember soft|ember|bar|derived|0' \
        'teal soft|teal|bar|derived|0'    'coral soft|coral|bar|derived|1' \
        'mono glow|mono|bar|literal|0'    'wheat glow|wheat|bar|literal|0' \
        'mint glow|mint|bar|literal|0'    'amber glow|amber|bar|literal|0' \
        'sage glow|sage|bar|literal|1'    'ember glow|ember|bar|literal|1' \
        'teal glow|teal|bar|literal|1'    'coral glow|coral|bar|literal|0' \
        'mono slate|mono|tabs|derived|0'  'wheat slate|wheat|tabs|derived|0' \
        'mint slate|mint|tabs|derived|0'  'amber slate|amber|tabs|derived|0' \
        'sage slate|sage|tabs|derived|0'  'ember slate|ember|tabs|derived|1' \
        'teal slate|teal|tabs|derived|0'  'coral slate|coral|tabs|derived|0' \
        'mono chip|mono|tabs|literal|0'   'wheat chip|wheat|tabs|literal|0' \
        'mint chip|mint|tabs|literal|0'   'amber chip|amber|tabs|literal|1' \
        'sage chip|sage|tabs|literal|0'   'ember chip|ember|tabs|literal|0' \
        'teal chip|teal|tabs|literal|0'   'coral chip|coral|tabs|literal|0' \
        'amber deep|amber|cap|derived|1'  'coral deep|coral|cap|derived|1' \
        'sage core|sage|cap|literal|1'    'teal core|teal|cap|literal|1'
end
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
fish tests/test-tmux-install.fish </dev/null 2>&1 | tail -5
```

Expected: `ALL PASS`.

- [ ] **Step 5: Verify the gallery renders end-to-end**

```bash
fish -c 'source conf.d/tmux-lives-install.fish; set -U tmux_lives_bar_color "#5f772b"; __tmux_lives_theme_list' | cat -A | head -3
fish -c 'source conf.d/tmux-lives-install.fish; set -U tmux_lives_bar_color "#5f772b"; __tmux_lives_theme_list' | wc -l
```

Expected: 36 lines, each a colour-escape strip followed by a name and a cap hex. **Note this writes a universal** — it runs outside the test harness's isolation, so use a throwaway `XDG_CONFIG_HOME`:

```bash
d=$(mktemp -d); XDG_CONFIG_HOME=$d fish -c 'source conf.d/tmux-lives-install.fish; set -U tmux_lives_bar_color "#5f772b"; __tmux_lives_theme_list' | wc -l; rm -rf "$d"
```

- [ ] **Step 6: Run the full gate, both fish modes**

Use the two commands from Global Constraints. Expected: 8 `ALL PASS` in each mode.

- [ ] **Step 7: Commit**

```bash
cat > /tmp/msg.txt <<'EOF'
feat(theme): retier the catalog — bar and tabs symmetric, cap a 4-row minority

Both large placements are now first-class, so they get symmetric coverage: all 8
relationships at bar and at tabs, derived and literal, 32 rows. The gaps in the
old slate/chip tiers were weeded against a derivation where a tabs-placed scheme
moved the tab bar by only 42% of the travel — those verdicts do not transfer, so
the gaps are filled and the set gets re-weeded from live use.

Cap placement survives as a 4-row accent-led minority ordered last: exactly the
four rows that were already curated defaults. 37 -> 36 rows; the 14 default NAMES
are unchanged.

Per-tier counts are pinned exactly — a >= bound passed on the pre-cut catalog in
the last weeding pass and caught nothing.
EOF
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -F /tmp/msg.txt
```

---

## Task 6: Document, verify, and finish the branch

**Files:**
- Modify: `CLAUDE.md` — the theme paragraph
- Test: no new tests; this task is the whole-branch verification

**Interfaces:**
- Consumes: everything
- Produces: a merged branch

- [ ] **Step 1: Update `CLAUDE.md`**

Append to the theme section (after the v4 gallery-picker paragraph), matching the file's existing dense-prose style:

```markdown
**Theme v5 — big-area scheme derivation SHIPPED (2026-08-01, `feat/big-area-scheme`; spec `docs/superpowers/specs/2026-08-01-theme-big-area-scheme-design.md`, plan `docs/superpowers/plans/2026-08-01-theme-big-area-scheme.md`):** the v4 curve put the roles at fixed positions (bar `t=0`, tabs `t=0.42`, cap `t=1`) with hue `H0 + sd·t`, so **the endcap absorbed the relationship's ENTIRE travel and the bar absorbed none** — at `place=bar` the bar's hue was exactly the seed's in every relationship (verified byte-identical across all 8 at seed `#4f8728`), so a scheme was defined by the SMALLEST swath on screen while the two largest areas stayed put. That is the mechanical cause of the user's "I'm not sensing that the schemes complement one colour more than the others". Replaced by **two large areas and a bridge**: the seed anchors one large area (`--place bar|tabs`), the relationship's signed travel separates the OTHER large area from it, and the endcap bridges at **half** the travel floored at the calibrated **kin-cap family separation** (`__tmux_lives_theme_family`, restored from the 2026-07-20 study the v4 rewrite deleted — warm/earth +40 · olive +20 · teal +30 · blue +25 · purple +18 · red +15; blue/red are untested extrapolations). **Depth is FIXED per role** (bar L 0.40, tabs L 0.51, cap ΔL 0.10) — hue differentiates, lightness coheres. `place=cap` survives as the accent-led minority: the cap carries the seed and the bar is solved BACKWARDS, with the family separation evaluated at the SEED's hue (a deliberate single pass, since the bar is what's being solved for). **`__tmux_lives_theme_taper` DELETED** — it existed only to mute far-travelled endcaps, which no longer exist; that also retires the ember-knee constant. **`--place low|high` retired** (`__tmux_lives_migrate_v41`, idempotent on fisher update). Catalog **37→36**, bar/tabs symmetric (8 relationships × derived/literal each), cap a 4-row minority ordered last; **the 14 default NAMES are unchanged**. **`mono` is byte-identical to the old engine at both large areas** (the tabs chroma constant `0.0713` is exactly what the taper produced at zero travel) — the regression anchor. **The ink (`__tmux_lives_theme_accents`) is DELIBERATELY UNTOUCHED** per the user ("the ink isn't what needs changing currently") and is now pinned byte-identical by test; it remains cap-blind by construction, and `active` remains a computed-but-never-painted role, both documented as intentional. Test tolerances are **2°** on rendered hexes (they quantise to 8-bit sRGB and gamut-clamp; measured worst error at the canonical seed `#5f772b` is 0.99° travel / 0.93° bridge). **Pending live smoke:** whether the far end of the ladder (sage/teal/coral at a saturated seed) is too bold on a large area — `--vividness` is the named future home for that dial and remains inert, along with `--shape`/`--ease`/`--contrast`.
```

- [ ] **Step 2: Commit the docs**

```bash
cat > /tmp/msg.txt <<'EOF'
docs(claude): record the big-area scheme derivation
EOF
git add CLAUDE.md
git commit -F /tmp/msg.txt
```

- [ ] **Step 3: Full verification**

```bash
bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish "$t" </dev/null 2>&1 | tail -1; done'
bash -c 'for t in tests/test-*.fish; do printf "%-34s " "$(basename "$t")"; fish --no-config "$t" </dev/null 2>&1 | tail -1; done'
```

Expected: 8 `ALL PASS` in each mode.

Confirm the categorizer still sources clean with zero stderr (the tool shell is zsh, so this must be wrapped):

```bash
bash -c 'fish --no-config -c "set -g tmux_categorize_test 1; source functions/tmux-categorize.fish" 2>&1 >/dev/null | wc -c'
```

Expected: `0`.

Confirm the universals were not damaged by the run — the isolation guard should make this a no-op:

```bash
fish -c 'for v in tmux_lives_theme tmux_lives_theme_place tmux_lives_theme_mode tmux_lives_bar_color; printf "%-28s %s\n" $v (set -q $v; and echo $$v; or echo "(unset)"); end'
```

Expected: unchanged from before the run (`teal` / `tabs` / `derived` / `#4f8728` at time of writing).

- [ ] **Step 4: Request review**

Use `superpowers:requesting-code-review` for a whole-branch review before merging. Do not skip this — the last two theme cycles each had a real defect caught only at whole-branch review.

- [ ] **Step 5: Finish the branch**

Use `superpowers:finishing-a-development-branch`. The project default is **merge to `main` locally, then push** — do not open a PR and do not ask which option.

**Do NOT deploy.** Finished changes reach the live `~/.config/fish/` only via the user's own `fisher update`. Tell the user it's merged and pushed, and stop.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 the model — anchor/travel/depth table | Task 2 (bar/tabs), Task 3 (cap) |
| §2 the bridge rule + family table | Task 1 (table), Task 2 (bridge) |
| §3 literal mode | Task 2, Task 3 |
| §4 retirements — taper | Task 2 |
| §4 retirements — `--place low\|high` + migration | Task 4 |
| §5 catalog 36/14 | Task 5 |
| What does not change — ink pin | Task 1 |
| What does not change — `active` stays dead | No task needed (nothing changes); documented in Task 6 |
| Testing — anchor/travel/bridge/depth/literal/cap/ink/catalog/migration | Tasks 1-5 |
| Testing — guards | Task 2 (taper), Task 4 (low/high) |
| Non-goals | No tasks, by definition; recorded in Task 6 |

No gaps.

**Placeholder scan:** none. Every code step carries the literal code to write, every test step the literal assertions, every expected value was measured against a running prototype rather than predicted.

**Type consistency:** `__tmux_lives_theme_family` is called with a hue and returns degrees in Tasks 1, 2, 3 — consistent. `__tmux_lives_theme_curve`'s 5-argument signature and 3-line output are unchanged from the current engine, so `__tmux_lives_theme_palette` (9-arg) and both picker call sites keep working untouched. `capseed`, `half`, `dir`, `minsep`, `Hcap` are introduced in Task 2 and reused with the same meaning in Task 3. The test helpers `_oklch_of` and `_dhue` are defined once in Task 2 and used in Task 3 — Task 3's tests must therefore be appended *after* Task 2's block, which the file placement specifies.

**One risk worth naming for the implementer:** Task 3 edits three separate places inside the function Task 2 wrote. If Tasks 2 and 3 are done by different subagents, the Task 3 agent must read the current `__tmux_lives_theme_curve` before editing rather than trusting the snippets here to match byte-for-byte.
