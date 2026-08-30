# Palette Constraints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the v6 engine produce palettes that satisfy the measured bounds — big-three mean chroma <= 0.095 and big-three max lightness <= 0.70 — while keeping the light end tinted rather than near-white, and pin the result with a guard that the palettes the user rejected still fail.

**Architecture:** `__tmux_lives_theme_arrange` becomes what its name says: a **pure permutation** of seven ramp-ordered colours onto seven roles. Everything that *substitutes* a colour — the lightness clamp, the chroma clamp, the no-white pass and the text-contrast floor — moves into one new function, `__tmux_lives_theme_constrain`, applied by `__tmux_lives_theme_render` after arranging. The order inside that function is load-bearing and fixed by this plan.

**Tech Stack:** fish 4.7.1. No new files, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-28-palette-constraints-design.md`

## Why the constraints do not live in `arrange`

This was measured, not assumed, and it is the single most important thing in this plan.

Applying the four changes inside `__tmux_lives_theme_arrange` breaks **11 existing assertions**. `arrange` is contractually a pure permutation, and several tests recover the role-to-ramp-index mapping by feeding it a known fixture and observing where each colour lands. The clamps and the no-white pass *substitute* colours, which destroys that contract and every recovery-based test with it — including the four that pin v6's documented round-robin hue mapping.

Moving the substituting work out of `arrange` takes the same four changes from **11 failures to 3**. The remaining three are genuine design conflicts, resolved explicitly below rather than by loosening a test.

## Global Constraints

- **Zero new files.** Everything lands in `conf.d/tmux-lives-install.fish` and `tests/test-tmux-install.fish`.
- **Nothing in the v5 cluster may change**: `__tmux_lives_theme_palette`, `_curve`, `_barpos`, `_family`, `_kincap`, `_accents`, `_reldef`, `_catalog`, `_apply_live`, `_cmd`. Byte-identical.
- **`__tmux_lives_theme_anchors` and `__tmux_lives_theme_ramp` do not change at all.**
- **`arrange` must remain a pure permutation** once Task 3 is done. Any later task that makes it substitute a colour is wrong.
- **Hue is never constrained.** No task may add a rule about which hue a role takes; that was refuted three times. See the spec's "Hue placement is not a constraint".
- **Never hand-assign a role colour.** Every colour comes from the ramp, possibly with lightness or chroma adjusted. Hand-assigned constants destroy the chroma curve, which is what "less cohesive" meant.
- **The order inside `__tmux_lives_theme_constrain` is fixed:** big-role lightness clamp -> big-role chroma clamp -> no-white -> text floor. The floor runs **last** because legibility is correctness, and because every earlier step can move `bar` or `text`.
- **Bound 1 (peak chroma 0.105-0.180) is NOT an engine guarantee.** At a dark seed the sRGB gamut caps peak chroma at 0.082 however much is requested, so no clamp can raise it. Bound 1 belongs to whoever picks recipes — the surface plan. This plan does not enforce it and its guard does not assert it.
- Gate before every commit: `for t in tests/test-*.fish; fish $t; end` and again with `fish --no-config`. All 9 suites `ALL PASS`. `test-tmux-install.fish` is at **798 plain / 797 `--no-config`** at the start of this plan; the 1-count delta is **BY DESIGN** and stays 1.

### Operational notes — read before dispatching or implementing

- **Briefs in this repo have contained defects, including in this plan.** If the code disagrees with the brief, **the code wins** — report it rather than following the brief into a bug.
- **Prove every assertion FAILS before the change.** An assertion nobody has seen fail is not evidence.
- **`fish`'s `math` has no comparison operators.** Use `test`, which handles floats natively.
- **An unquoted `#rrggbb` starts a fish COMMENT.** Always quote hex literals in test data.
- **A command substitution inside a QUOTED list subscript** is a fish "Invalid index value" error. Capture the index first.
- Pass an explicit **`timeout: 600000`** on any Bash call running the gate. **If a call reports it was backgrounded, abandon it and re-run in the foreground.**
- **Never run the suite under a shell `timeout`** — it truncates with no trailer and reads as a false clean.
- Capture FAIL lines with `grep -E '^FAIL'`, never `tail -1`.
- The Bash tool runs **zsh**, not bash.
- **Never `git checkout` to revert a mutation** — restore from a file copy and `diff` to prove byte-identity.
- **Do not dispatch subagents.**

---

### Task 1: The bounds helper and the holdout guard

**Files:**
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__t6_bounds <hex>...` -> `"<peakC> <big3meanC> <big3maxL>"`, and `__t6_inbounds <hex>...` -> `1` or `0` for bounds 2 and 3 only. Later tasks consume both.

No production code. This builds the measuring instrument and pins the three rejected palettes, so no later change can loosen the bounds without a named assertion going red.

- [ ] **Step 1: Write the tests**

Add immediately after the existing `__t6_families` helper in `tests/test-tmux-install.fish`.

```fish
# --- palette bounds ----------------------------------------------------------
# Bounds separating the palettes the user picked from the ones they rejected,
# derived from the liked set only and checked against the rejects as a holdout.
# See docs/superpowers/specs/2026-08-28-palette-constraints-design.md.
#   1. peak chroma           0.105 <= pk <= 0.180   (NOT enforced here — see below)
#   2. big-three mean chroma        <= 0.095
#   3. big-three max lightness      <= 0.70
# Roles are bar sep tabs active windows cap text; the big three are 1, 3 and 6.
#
# Bound 1 is deliberately NOT part of __t6_inbounds. At a dark seed the sRGB
# gamut caps peak chroma at 0.082 however much the recipe requests, so no engine
# change can satisfy it — it is the catalog's job to pick a workable peakC.
# __t6_bounds still REPORTS it so the surface plan can check it later.
function __t6_bounds --description 'v6 test helper: seven role hexes -> "<peakC> <big3meanC> <big3maxL>". The measuring instrument for the palette bounds.'
    set -l Ls
    set -l Cs
    for h in $argv
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        set -a Ls $o[1]
        set -a Cs $o[2]
    end
    set -l pk 0
    for c in $Cs
        test "$c" -gt "$pk"; and set pk $c
    end
    set -l bigL 0
    for i in 1 3 6
        test "$Ls[$i]" -gt "$bigL"; and set bigL $Ls[$i]
    end
    printf '%s %s %s\n' $pk (math "($Cs[1] + $Cs[3] + $Cs[6]) / 3") $bigL
end

function __t6_inbounds --description 'v6 test helper: 1 if the seven hexes satisfy the two ENGINE-enforced bounds (big-three chroma and lightness). Bound 1 is the catalog s job and is excluded on purpose.'
    set -l b (string split ' ' -- (__t6_bounds $argv))
    test "$b[2]" -gt 0.095; and echo 0; and return
    test "$b[3]" -gt 0.70; and echo 0; and return
    echo 1
end

# The helper must measure, not merely run.
set -g B6M (string split ' ' -- (__t6_bounds '#4b4f48' '#82ab62' '#5d6c52' '#c9e0bb' '#a7c591' '#6f8b5b' '#c9e0bb'))
t "bounds: helper returns three fields" 3 (count $B6M)
t "bounds: peak chroma is the palette maximum, not the first role" 1 (test "$B6M[1]" -gt 0.10; and echo 1; or echo 0)
t "bounds: big-three max lightness ignores the small roles" 1 (test "$B6M[3]" -lt 0.70; and echo 1; or echo 0)

# HOLDOUT. Rejected by the user in live judgement, NOT used to derive anything.
# The pale-pink triadic violates bound 3 (big-three lightness 0.88) and the
# over-hot triadic violates bound 2 (big-three chroma 0.126); both are engine
# bounds. The flat foundation violates only bound 1, so it is asserted against
# __t6_bounds directly rather than through __t6_inbounds.
t "bounds holdout: the pale-pink triadic fails" 0 (__t6_inbounds '#4b4f48' '#96787b' '#f9c9cc' '#91a484' '#a0bddd' '#5d6875' '#c9e0bb')
t "bounds holdout: the over-hot triadic fails" 0 (__t6_inbounds '#b71445' '#65aeff' '#5b9a00' '#ffbac0' '#65a3ea' '#2d2424' '#c9e0bb')
set -g B6FLAT (string split ' ' -- (__t6_bounds '#4b4f48' '#8b9684' '#5c6c51' '#9eb38f' '#9eb38f' '#6d8b55' '#c3d9b4'))
t "bounds holdout: the flat foundation is under the peak-chroma floor" 1 (test "$B6FLAT[1]" -lt 0.105; and echo 1; or echo 0)
# ...and the palette they love must pass, or the bounds are simply wrong.
t "bounds: the reference mono passes the engine bounds" 1 (__t6_inbounds '#4b4f48' '#82ab62' '#5d6c52' '#c9e0bb' '#a7c591' '#6f8b5b' '#c9e0bb')
```

- [ ] **Step 2: Run and prove the holdout is not vacuous**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no output — all eight pass immediately. This task measures; it does not change behaviour.

Then temporarily widen `__t6_inbounds`'s lightness test from `-gt 0.70` to `-gt 0.95` and re-run. `bounds holdout: the pale-pink triadic fails` must FAIL (its big-three lightness is 0.88). Restore and re-run. Record both outputs.

- [ ] **Step 3: Commit**

```bash
git add tests/test-tmux-install.fish
git commit -m "test(theme): the palette bounds helper and its holdout

Two bounds the engine can enforce - big-three chroma and lightness -
plus the peak-chroma bound it cannot, reported but not asserted: at a
dark seed the gamut caps peak chroma at 0.082 whatever the recipe asks
for, so that one belongs to whoever picks recipes.

Pins the three rejected palettes so no later change can loosen the
bounds without a named assertion going red."
```

---

### Task 2: Re-index the arrangements so big roles draw from the dark half

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — the `switch "$pattern"` block inside `__tmux_lives_theme_arrange`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: the invariant that `bar` (role 1), `tabs` (role 3) and `cap` (role 6) never draw a ramp index above 4. Task 4's clamp relies on this to stay rare.

Five of six arrangements place a large surface on ramp index 6 or 7, where L 0.88-0.97 lives. `deep` is the exception — and `deep` is the arrangement behind the palette the user calls their favourite.

- [ ] **Step 1: Write the failing test**

```fish
# C1a: the three large surfaces draw from the dark half of the ramp. Checked
# against the arrangement TABLE, not rendered output, so a future arrangement
# cannot violate it silently at a seed nobody tested.
set -g A6BIGOK 1
for pat in (__tmux_lives_theme_arrangements)
    # Recover the index list by feeding seven distinguishable hexes through
    # arrange. Derived, never hardcoded: the list lives inside a switch the
    # test cannot read.
    set -l fix '#1d1d1d' '#3a3a3a' '#575757' '#747474' '#919191' '#aeaeae' '#f2f2f2'
    set -l out (__tmux_lives_theme_arrange $pat $fix)
    for r in 1 3 6
        for p in (seq 7)
            if test "$out[$r]" = "$fix[$p]"
                test $p -gt 4; and set -g A6BIGOK 0
            end
        end
    end
end
t "arrange: no big role draws a ramp index above 4" 1 $A6BIGOK
```

- [ ] **Step 2: Run and verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: `FAIL: arrange: no big role draws a ramp index above 4 => got [0]`

- [ ] **Step 3: Re-index**

Replace the six `case` bodies in `__tmux_lives_theme_arrange`'s `switch "$pattern"`. `deep` is unchanged — it already complied.

```fish
        case deep
            set idx 1 4 2 6 5 3 7
        case bright
            set idx 4 5 3 7 6 2 1
        case centre
            set idx 3 5 2 6 7 4 1
        case split
            set idx 1 3 4 5 6 2 7
        case stack
            set idx 2 5 3 6 4 1 7
        case accent
            set idx 3 5 4 6 2 1 7
```

Each is a permutation of 1-7. List positions are `bar sep tabs active windows cap text`, so positions 1, 3 and 6 now hold only indices 1-4; indices 5, 6 and 7 go to the small roles.

- [ ] **Step 4: Run and verify it passes**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL'`
Expected: no output. The pre-existing permutation and pattern-distinctness assertions must also still pass.

- [ ] **Step 5: Mutation-check**

`cp conf.d/tmux-lives-install.fish /tmp/t2.fish` first. Change `stack` to `2 5 3 6 4 7 1` (cap back to index 7). **Expect the new assertion to FAIL** reporting `[0]`. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): big roles draw from the dark half of the ramp

Five of six arrangements placed a large surface on ramp index 6 or 7,
where L 0.88-0.97 lives - the pale big surface the user rejected at
every seed it appeared at. bar, tabs and cap now take only indices 1-4.

deep is unchanged: it already complied, and it is the arrangement
behind the palette the user calls their favourite."
```

---

### Task 3: Make `arrange` a pure permutation

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — move the text-floor block out of `__tmux_lives_theme_arrange` into a new `__tmux_lives_theme_constrain`; call it from `__tmux_lives_theme_render`
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_constrain <7 hexes>` -> seven hexes, the floor applied. Tasks 4-6 add to this function, in order.
- `__tmux_lives_theme_arrange` keeps its signature but now only permutes.

This task moves code without changing behaviour. It exists so Tasks 4-6 have somewhere to live that does not break `arrange`'s permutation contract.

- [ ] **Step 1: Write the failing test**

```fish
# arrange is a PURE permutation: every output colour is one of the inputs, even
# for a fixture narrow enough that the contrast floor would otherwise fire.
# This is what the recovery-based mapping tests depend on.
set -g A6PURE 1
set -g A6NARROW '#4a4a4a' '#565656' '#626262' '#6e6e6e' '#7a7a7a' '#868686' '#929292'
for pat in (__tmux_lives_theme_arrangements)
    for h in (__tmux_lives_theme_arrange $pat $A6NARROW)
        contains -- $h $A6NARROW; or set -g A6PURE 0
    end
end
t "arrange: is a pure permutation even on a narrow fixture" 1 $A6PURE
# ...and the floor still happens, just later: render must still enforce it.
set -g A6RF (__tmux_lives_theme_render '#5f772b' mono 0.30 0.12 0.5 centre)
set -g A6RFB (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6RF[1]))
set -g A6RFT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6RF[7]))
t "render: the text-contrast floor is still enforced after the move" 1 (test (math "abs($A6RFT[1] - $A6RFB[1])") -ge 0.40; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify it fails**

Expected: `FAIL: arrange: is a pure permutation even on a narrow fixture => got [0]` — the narrow fixture makes stage two fire, substituting a colour that is not in the input.

- [ ] **Step 3: Move the floor**

Cut the entire floor block from `__tmux_lives_theme_arrange` — everything from the `# The floor. Role 1 is bar, role 7 is text.` comment down to just before the function's final `printf '%s\n' $out`. Paste it verbatim into a new function placed immediately after `__tmux_lives_theme_arrange`:

```fish
function __tmux_lives_theme_constrain --description 'v6: seven arranged role hexes -> the same seven made ACCEPTABLE. arrange decides which colour goes where and stays a pure permutation; this decides what a colour must become. Order is load-bearing and fixed: big-role lightness clamp, big-role chroma clamp, no-white, then the text-contrast floor LAST because legibility is correctness and every earlier step can move bar or text.'
    set -l out $argv
    test (count $out) -eq 7; or return 1

    # <the floor block, moved verbatim from arrange>

    printf '%s\n' $out
end
```

Then in `__tmux_lives_theme_render`, replace the final line `__tmux_lives_theme_arrange "$arrangement" $hexes` with:

```fish
    set -l pal (__tmux_lives_theme_arrange "$arrangement" $hexes)
    test (count $pal) -eq 7; or return
    __tmux_lives_theme_constrain $pal
```

Update `__tmux_lives_theme_arrange`'s description so it no longer claims to enforce the floor — it permutes, nothing more.

- [ ] **Step 4: Run and verify it passes**

Expected: no output from `grep -E '^FAIL'`.

**Four pre-existing assertions will now be testing the wrong function.** Measured in pre-flight, these are exactly the ones that break, all because they call `__tmux_lives_theme_arrange` and expect the floor to have been applied:

- `arrange: text clears the contrast floor in EVERY pattern`
- `arrange: a mid-ramp bar still gets legible text (centre)`
- `arrange: a mid-ramp bar still gets legible text (accent)`
- `arrange: stage two actually moved lightness (precondition for the next two)`

Repoint each at `__tmux_lives_theme_constrain` — the call becomes `__tmux_lives_theme_constrain (__tmux_lives_theme_arrange $pat $fixture)`. Do not weaken them; the properties they check are unchanged, only the function that provides them has moved. Rename them from `arrange:` to `constrain:` so the prefix keeps matching the function under test. If a fifth assertion breaks, report it — the pre-flight list is exhaustive and a surprise means something else moved.

- [ ] **Step 5: Mutation-check**

`cp conf.d/tmux-lives-install.fish /tmp/t3.fish` first. Delete the `__tmux_lives_theme_constrain $pal` call from `render`, returning `$pal` directly. **Expect `render: the text-contrast floor is still enforced after the move` to FAIL** while `arrange: is a pure permutation` keeps PASSING — that pairing proves the two properties are now independent. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "refactor(theme): arrange permutes, constrain substitutes

arrange is contractually a pure permutation, and several tests recover
the role-to-ramp mapping by feeding it a fixture and seeing where each
colour lands. The contrast floor substitutes a colour, which breaks that
contract - measured, applying the palette constraints inside arrange
broke 11 assertions, four of them the ones pinning v6's round-robin hue
mapping.

Behaviour is unchanged. This is where the next three tasks live."
```

---

### Task 4: Clamp big roles that are too light

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — inside `__tmux_lives_theme_constrain`, **first**, before the floor block
- Test: `tests/test-tmux-install.fish`

Task 2 is necessary but not sufficient: the ramp window is positioned by the seed's own lightness, so a light seed with a narrow span puts **every** position above the bound — measured, ramp index 1 reaches L 0.77.

- [ ] **Step 1: Write the failing test**

```fish
# C1b: no arrangement table can fix a window that sits entirely above the
# bound. Measured: at a light seed with a narrow span, ramp index 1 reaches
# L 0.77. The clamp is what makes bound 3 unconditional.
set -g A6LIGHT (__tmux_lives_theme_render '#dfe8c8' mono 0.20 0.14 0.5 deep)
t "constrain: a light seed still yields seven roles" 7 (count $A6LIGHT)
set -g A6LB (string split ' ' -- (__t6_bounds $A6LIGHT))
t "constrain: a light seed's big roles stay under the lightness bound" 1 (test "$A6LB[3]" -le 0.70; and echo 1; or echo 0)
# ...and the clamp must not fire when it is not needed.
set -g A6NB (string split ' ' -- (__t6_bounds (__tmux_lives_theme_render '#5f772b' mono 0.55 0.11 0.5 deep)))
t "constrain: a normal seed is untouched by the lightness clamp" 1 (test "$A6NB[3]" -le 0.70; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify it fails**

Expected: `FAIL: constrain: a light seed's big roles stay under the lightness bound => got [0]`

- [ ] **Step 3: Implement**

Insert at the **top** of `__tmux_lives_theme_constrain`, before the floor block:

```fish
    # Bound 3: no large surface may be pale. The arrangement table keeps big
    # roles on ramp indices 1-4, but that is not sufficient — the window is
    # positioned by the seed's own lightness, so a light seed with a narrow span
    # can put EVERY position above the bound (measured: index 1 reaches L 0.77).
    #
    # The consequence is deliberate: big surfaces stay dark whatever the seed's
    # lightness. The seed still positions the ramp and so still shapes the small
    # roles and the overall spread — it just no longer drags the large surfaces
    # pale, which the user rejected at every seed it appeared at.
    for r in 1 3 6
        set -l lo (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$r]))
        if test "$lo[1]" -gt 0.70
            set -l newL 0.70
            set -l cand (__tmux_lives_oklch_hex $newL $lo[2] $lo[3])
            set -l tries 0
            # Hex encoding is lossy, so a target placed exactly ON the bound can
            # round to just over it. Nudge until the ACTUAL round-tripped value
            # clears, rather than trusting the request.
            while test $tries -lt 10
                set -l back (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $cand))
                test "$back[1]" -le 0.70; and break
                set newL (math "$newL - 0.01")
                set cand (__tmux_lives_oklch_hex $newL $lo[2] $lo[3])
                set tries (math $tries + 1)
            end
            set out[$r] $cand
        end
    end
```

- [ ] **Step 4: Run and verify it passes — and update the one assertion this deliberately narrows**

`render: the seeds own LIGHTNESS places the whole palette` will now FAIL. That is the intended consequence, not a regression: it asserts that a dark seed and a light seed produce disjoint lightness windows, and clamping big roles at 0.70 pulls the light seed's big roles down into the dark seed's range.

The claim narrows rather than disappears — the seed's lightness still places the **small** roles. Rewrite it to assert disjointness over the small roles only, and add a companion asserting the clamp did its job:

```fish
# The seed's lightness still places the palette, but the BIG roles are now
# clamped so a light seed cannot drag the large surfaces pale. The claim
# therefore narrows to the small roles (2 sep, 4 active, 5 windows, 7 text).
set -g V6DARKMAXL 0
for i in 2 4 5 7
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $V6DARK[$i]))
    test "$o[1]" -gt "$V6DARKMAXL"; and set -g V6DARKMAXL $o[1]
end
set -g V6LIGHTMINL 1
for i in 2 4 5 7
    set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $V6LIGHT[$i]))
    test "$o[1]" -lt "$V6LIGHTMINL"; and set -g V6LIGHTMINL $o[1]
end
t "render: the seeds own LIGHTNESS still places the small roles" 1 (test "$V6DARKMAXL" -lt "$V6LIGHTMINL"; and echo 1; or echo 0)
set -g V6LIGHTB (string split ' ' -- (__t6_bounds $V6LIGHT))
t "render: but a light seed no longer drags the big roles pale" 1 (test "$V6LIGHTB[3]" -le 0.70; and echo 1; or echo 0)
```

Keep the existing `$V6DARK`/`$V6LIGHT` definitions above it unchanged — the hue-matched seed pair is still the right fixture.

- [ ] **Step 5: Mutation-check**

`cp conf.d/tmux-lives-install.fish /tmp/t4.fish` first. Change the guard to `if false`. **Expect the light-seed assertion to FAIL and the normal-seed one to keep PASSING** — that pairing proves the clamp fires only where needed rather than flattening every palette. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): clamp big roles the ramp window leaves pale

The window is positioned by the seed's lightness, so a light seed with a
narrow span puts every position above the bound - index 1 reaches L 0.77
and no arrangement table can reach that. Makes bound 3 unconditional."
```

---

### Task 5: Clamp big-role chroma, and accept where the peak must live

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — inside `__tmux_lives_theme_constrain`, after the lightness clamp, before the floor
- Test: `tests/test-tmux-install.fish`

**This task has a consequence that must be stated rather than discovered.** Scaling big-role chroma down means that when a recipe's chroma peak lands on a big role, the palette's overall peak drops with it. Measured at the same recipe: peak `0.203 on tabs` under `accent`, versus `0.260 on sep` under `deep`.

So bound 2 implies **the chroma peak belongs on a small role.** That is not a compromise invented to make a test pass — it is where the peak sits in the palette the user likes most, where `sep`, the tiny `•` separators, carries 0.110 while nothing else exceeds 0.078.

- [ ] **Step 1: Write the failing test**

```fish
# Bound 2: the three large surfaces must not compete. Scale their chroma down
# together, preserving their relative structure rather than flattening them.
set -g A6HOT (string split ' ' -- (__t6_bounds (__tmux_lives_theme_render '#87cb48' triadic 0.62 0.14 0.5 centre)))
t "constrain: big-three chroma is held under the bound" 1 (test "$A6HOT[2]" -le 0.095; and echo 1; or echo 0)
# The clamp must SCALE, not flatten: the three keep their relative order.
set -g A6SCALED (__tmux_lives_theme_render '#87cb48' triadic 0.62 0.14 0.5 centre)
set -g A6SC1 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6SCALED[1]))
set -g A6SC3 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6SCALED[3]))
t "constrain: the clamp scales rather than flattening (big roles still differ)" 1 (test (math "abs($A6SC1[2] - $A6SC3[2])") -gt 0.005; and echo 1; or echo 0)
# The peak belongs on a SMALL role. deep puts ramp index 4 - where peakPos 0.5
# peaks - on sep, so a vivid recipe keeps its peak.
set -g A6VIV (string split ' ' -- (__t6_bounds (__tmux_lives_theme_render '#7a00ff' triadic 0.65 0.26 0.5 deep)))
t "constrain: a vivid recipe still reaches high chroma when its peak is on a small role" 1 (test "$A6VIV[1]" -ge 0.22; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify the first assertion fails**

Expected: `FAIL: constrain: big-three chroma is held under the bound => got [0]`.

- [ ] **Step 3: Implement**

Insert immediately after the lightness clamp:

```fish
    # Bound 2: the three large surfaces must not compete for attention. Scale
    # all three together so their relative structure survives — flattening them
    # to a common value is what "less cohesive" meant.
    #
    # Consequence, stated because it is load-bearing: when a recipe's chroma
    # peak lands on a big role it is scaled down with the rest, so the palette's
    # peak belongs on a SMALL role. That is where it sits in the palette the
    # user likes most — sep carries 0.110 while nothing else exceeds 0.078.
    set -l bc1 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l bc3 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[3]))
    set -l bc6 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[6]))
    set -l meanC (math "($bc1[2] + $bc3[2] + $bc6[2]) / 3")
    if test "$meanC" -gt 0.095
        set -l target 0.095
        set -l tries 0
        while test $tries -lt 10
            set -l k (math "$target / $meanC")
            set out[1] (__tmux_lives_oklch_hex $bc1[1] (math "$bc1[2] * $k") $bc1[3])
            set out[3] (__tmux_lives_oklch_hex $bc3[1] (math "$bc3[2] * $k") $bc3[3])
            set out[6] (__tmux_lives_oklch_hex $bc6[1] (math "$bc6[2] * $k") $bc6[3])
            set -l a1 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
            set -l a3 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[3]))
            set -l a6 (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[6]))
            test (math "($a1[2] + $a3[2] + $a6[2]) / 3") -le 0.095; and break
            set target (math "$target - 0.003")
            set tries (math $tries + 1)
        end
    end
```

The loop exists for the same reason the lightness clamp's does: scaling to exactly 0.095 lands at 0.0956 after the hex round trip. Measured — without the loop, 6 of 108 combinations still breach.

- [ ] **Step 4: Run and verify it passes**

**Then check the pre-existing range guard.** `range: the envelope reaches the high end of the users liked palettes` uses the `accent` arrangement, which places the peak on `tabs` — a big role — so it will now fail. **Change that probe's arrangement to `deep`** and add this comment above it:

```fish
# deep, not accent: bound 2 scales big-role chroma down, so a recipe whose peak
# lands on a big role no longer reaches the high end. The peak belongs on a
# small role — which is where it sits in the palette the user likes most.
```

Do not widen the 0.22 threshold. If `deep` does not reach it, report the measured value and stop.

- [ ] **Step 5: Mutation-check**

`cp conf.d/tmux-lives-install.fish /tmp/t5.fish` first.

Change `if test "$meanC" -gt 0.095` to `if false`. **Expect `constrain: big-three chroma is held under the bound` to FAIL.** Restore and `diff`.

Then re-take the copy and replace the scaling with a flatten — set all three to exactly `0.095` rather than scaling. **Expect `constrain: the clamp scales rather than flattening` to FAIL** while the bound assertion still passes. That pairing is what proves the clamp preserves structure rather than merely satisfying the number. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): hold big-three chroma under the bound by scaling

The three large surfaces must not compete. Scaling all three together
keeps their relative structure; flattening them to one value is what
'less cohesive' meant.

Consequence: a recipe whose chroma peak lands on a big role loses it,
so the peak belongs on a small role - which is where it sits in the
palette the user likes most, sep at 0.110."
```

---

### Task 6: No white

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — inside `__tmux_lives_theme_constrain`, after the chroma clamp and **before** the floor block; plus the floor's light-side ceiling
- Test: `tests/test-tmux-install.fish`

The user excludes white. A genuinely tinted light colour is not white; a near-neutral one is.

**This is where the third measured conflict lives.** The no-white pass caps lightness at 0.88. The contrast floor needs `text` at `bar ± 0.40`. If no-white ran *after* the floor it would pull `text` back under the floor — measured, the full-palette span lands at 0.3999 against a `>= 0.40` assertion that has always had only 0.0006 of margin. The resolution is ordering plus a lowered ceiling: no-white runs **before** the floor, and the floor's light-side ceiling drops from 0.97 to 0.88 so it can never push `text` back into white. With `bar` clamped at 0.70, the floor falls to the dark side whenever the light side would exceed 0.88, which keeps both rules satisfiable.

- [ ] **Step 1: Write the failing test**

```fish
# C3: no role may be a near-neutral near-white. A tinted light colour is fine.
function __t6_nowhite_ok --description 'v6 test helper: 1 if no role is a near-neutral near-white'
    for h in $argv
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $h))
        test "$o[1]" -gt 0.88; and echo 0; and return
        if test "$o[1]" -gt 0.72
            test "$o[2]" -lt 0.055; and echo 0; and return
        end
    end
    echo 1
end
# square/centre at the user's own seed rendered cap #f8f3fb - L 0.97, chroma 0.008.
t "nowhite: the square recipe has no near-white role" 1 (__t6_nowhite_ok (__tmux_lives_theme_render '#87cb48' square 0.62 0.14 0.5 centre))
t "nowhite: a wide-span mono has no near-white role" 1 (__t6_nowhite_ok (__tmux_lives_theme_render '#5f772b' mono 0.70 0.14 0.5 bright))
# ...and no-white must not cost legibility: the floor still holds.
set -g A6NWF (__tmux_lives_theme_render '#5f772b' mono 0.70 0.14 0.5 bright)
set -g A6NWB (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6NWF[1]))
set -g A6NWT (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $A6NWF[7]))
t "nowhite: the contrast floor still holds after the cap" 1 (test (math "abs($A6NWT[1] - $A6NWB[1])") -ge 0.40; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify it fails**

Expected: at least `FAIL: nowhite: the square recipe has no near-white role => got [0]`.

- [ ] **Step 3: Implement**

First, lower the floor's light-side ceiling. In the floor block inside `__tmux_lives_theme_constrain`, change:

```fish
            test "$up" -gt 0.97; and set newL $dn; and set dir -1
```

to:

```fish
            # 0.88, not 0.97: the light end must stay tinted, never near-white.
            # With bar clamped at 0.70 this makes the floor fall to the dark
            # side whenever the light side would breach, so the contrast floor
            # and the no-white rule stay simultaneously satisfiable.
            test "$up" -gt 0.88; and set newL $dn; and set dir -1
```

and change both `test "$newL" -gt 0.97; and set newL 0.97` clamps in that block to `0.88`.

Second, insert the no-white pass immediately **before** the floor block:

```fish
    # C3. No white. A near-neutral near-white reads as belonging to no palette;
    # a genuinely tinted light colour does not. Runs BEFORE the floor, so the
    # floor has the final say on legibility and cannot be undone by this pass.
    for r in (seq 7)
        set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$r]))
        set -l L $o[1]
        set -l C $o[2]
        set -l changed 0
        if test "$L" -gt 0.88
            set L 0.88
            set changed 1
        end
        if test "$L" -gt 0.72; and test "$C" -lt 0.055
            set C 0.055
            set changed 1
        end
        test $changed -eq 1; and set out[$r] (__tmux_lives_oklch_hex $L $C $o[3])
    end
```

- [ ] **Step 4: Run and verify it passes**

The pre-existing floor assertions must all still pass. If any fails, report it rather than loosening the floor — legibility is correctness, not taste.

- [ ] **Step 5: Mutation-check**

`cp conf.d/tmux-lives-install.fish /tmp/t6.fish` first.

Delete the whole no-white pass. **Expect both `nowhite:` colour assertions to FAIL.** Restore and `diff`.

Re-take the copy and change only `set C 0.055` to `set C 0.010`. **Expect the `nowhite:` assertions to FAIL again** — proving the chroma floor does work rather than the lightness cap carrying both. Restore and `diff`.

Re-take the copy and move the no-white pass to AFTER the floor block. **Expect `nowhite: the contrast floor still holds after the cap` to FAIL** — proving the ordering is load-bearing and not incidental. Restore and `diff`.

- [ ] **Step 6: Full gate and commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): no role may be a near-neutral near-white

square/centre at the user's own seed rendered a cap of #f8f3fb - L 0.97
at chroma 0.008. Cap lightness at 0.88 and give any light role real
chroma.

Ordering is load-bearing: no-white runs before the contrast floor, and
the floor's light-side ceiling drops to 0.88 so it can never push text
back into white. Running it after the floor puts the full-palette span
at 0.3999 against a 0.40 floor."
```

---

### Task 7: The bounds guard across arrangements and seeds

**Files:**
- Test: `tests/test-tmux-install.fish`

This is the assertion the plan exists to make true.

- [ ] **Step 1: Write the test**

```fish
# The regression guard for the palette constraints. Every arrangement, at seeds
# spanning the space that broke things: the user's own, a dark one, a light one,
# a saturated one, a desaturated one. Bound 1 is excluded by construction -
# see __t6_inbounds - because the gamut, not the engine, decides it.
set -g A6FAILS
for seed in '#87cb48' '#5f772b' '#2f6fb3' '#7a00ff' '#dfe8c8' '#1a2010'
    for pat in (__tmux_lives_theme_arrangements)
        for recipe in 'mono 0.55 0.11 0.5' 'triadic 0.62 0.14 0.5' 'square 0.45 0.13 0.4'
            set -l rc (string split ' ' -- $recipe)
            set -l pal (__tmux_lives_theme_render $seed $rc[1] $rc[2] $rc[3] $rc[4] $pat)
            if test (count $pal) -ne 7
                set -a A6FAILS "$seed/$rc[1]/$pat:norender"
                continue
            end
            test (__t6_inbounds $pal) -eq 1; or set -a A6FAILS "$seed/$rc[1]/$pat"
        end
    end
end
t "bounds: every arrangement satisfies the engine bounds at every probe seed" 0 (count $A6FAILS)
# Surface WHICH combinations failed - a bare count sends the next reader hunting.
test (count $A6FAILS) -eq 0; or echo "  bounds failures: $A6FAILS"
```

- [ ] **Step 2: Run**

**If this fails, that is the most important possible outcome of this plan.** Report the listed combinations with their measured values and STOP. Do not widen the bounds and do not drop a seed. Pre-flight measured this at **zero failures across all 108 combinations** with Tasks 2-6 applied, so a failure means an implementation diverged from the plan.

- [ ] **Step 3: Mutation-check the guard**

`cp conf.d/tmux-lives-install.fish /tmp/t7.fish` first.

Disable Task 4's lightness clamp (`if false`). **Expect the guard to FAIL naming the light seed `#dfe8c8`.** Restore and `diff`.

Re-take the copy and disable Task 5's chroma clamp. **Expect the guard to FAIL naming `bright` and `centre` combinations** — measured, those are the arrangements that put big roles nearest the chroma peak. Restore and `diff`.

Both mutations must leave Task 1's holdout assertions passing; they are fixed hex values and cannot be affected by engine changes. If a holdout moves, the harness is wrong, not the engine.

- [ ] **Step 4: Full gate and commit**

```bash
git add tests/test-tmux-install.fish
git commit -m "test(theme): pin the engine bounds across arrangements and seeds

Six arrangements x six probe seeds x three recipes, spanning light,
dark, saturated and desaturated. The regression guard for the whole
constraints spec: the bounds came from palettes the user picked, and
the ones they rejected still fail them."
```

---

## Self-review

**Spec coverage.** C1a is Task 2, C1b is Task 4, C2 is Task 6's ordering plus the floor move in Task 3, C3 is Task 6. Bound 2 is Task 5. Bound 3 is Tasks 2 and 4. Bound 1 is deliberately unenforced and the plan says so in three places — Global Constraints, Task 1's comment, and Task 7's comment.

**Deviation from the spec, recorded.** The spec frames the changes as "two structural corrections to the arrangement stage". Pre-flight showed that applying them inside `arrange` breaks 11 assertions, four of which pin v6's round-robin hue mapping. Task 3 therefore introduces `__tmux_lives_theme_constrain` and `arrange` becomes a pure permutation. The spec should be amended to match once this lands.

**Pre-flight measured, against a scratch build of all six tasks: engine bounds 2 and 3 pass at ALL 108 combinations, and exactly six existing assertions break** — four repointed in Task 3, one narrowed in Task 4, one re-probed in Task 5. No other assertion moves.

**The three conflicts pre-flight found, and where each is resolved.** `stage two preserves hue` — Task 3 moves the floor, and Step 4 requires repointing the pre-existing floor assertions at the new function. `the text floor widens the full palette` — Task 6, by ordering no-white before the floor and lowering the ceiling. `the envelope reaches the high end` — Task 5, by moving the probe to an arrangement whose peak lands on a small role, with the reasoning recorded as a design consequence.

**Not covered, deliberately.** The spec's four open questions are decisions, not implementation: how many arrangements survive (this plan re-indexes all six rather than dropping any — the reversible choice), whether bound 2 needs a floor, whether the bounds survive a wider derivation set, and the neutral-seed case. `#4a4a4a` is deliberately **not** among Task 7's probe seeds: it cannot reach bound 1's floor at any requested chroma (measured, 0.101 at a request of 0.28), and the spec has not decided what should happen there.

**Type consistency.** `__t6_bounds` returns three space-separated fields everywhere; `__t6_inbounds` and `__t6_nowhite_ok` return 0 or 1. Role indices are 1-based throughout and the big three are 1, 3 and 6 in every task. `__tmux_lives_theme_constrain` takes and returns exactly seven hexes.
