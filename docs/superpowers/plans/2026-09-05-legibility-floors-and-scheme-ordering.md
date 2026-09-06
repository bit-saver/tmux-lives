# Legibility Floors and Scheme Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee every foreground painted on the tmux status bar is legible against it, and let the theme picker sort its schemes by colour so relatives of a colour you like sit together.

**Architecture:** Part A generalises `__tmux_lives_theme_constrain`'s fourth stage from "the `text` floor" to "the foreground floors" by extracting the existing 245-line single-role implementation into a parameterised, independently testable helper and calling it four times with a descending staircase of thresholds. Roles are floored most-demanding first and **locked** once satisfied, so a later role's swap can never undo an earlier role's guarantee. Part B adds a sort key derived from the picker's own swatch-strip order and an `o` toggle persisted in a universal.

**Tech Stack:** fish 4.7.1 (no external dependencies — all OKLCH maths uses fish's builtin `math`), tmux 3.3a, fisher plugin layout. Tests are plain fish scripts under `tests/`.

**Spec:** `docs/superpowers/specs/2026-09-05-legibility-floors-and-scheme-ordering-design.md`

## Global Constraints

- **NEVER deploy.** Do not copy anything into `~/.config/fish/` or edit `~/.tmux.conf`. Commit and push only; the user runs `fisher update` themselves.
- **The gate is 9 suites in two modes.** `for t in tests/test-*.fish; fish $t; end`, then again with `fish --no-config $t`. **Run each mode as its own foreground Bash call with an explicit `timeout: 600000`.** Never wrap the suite in a shell `timeout` — it truncates with no trailer and reads as a false clean. Capture failures with `grep -E '^FAIL'`, never `tail -1`.
- **Baseline counts before any change:** `test-tmux-install.fish` **917 plain / 916 `--no-config`** (the 1-count delta is BY DESIGN — one isolation assertion is gated on plain fish; do not "fix" it), `test-tmux-categorize.fish` **1406**, `test-generic.fish` **2**, `test-tmux-status.fish` **4**. `test-tmux-categorize.fish` and `test-tmux-auto.fish` print `ALL PASS` with **no count** — judge them by the absence of `FAIL` lines.
- **`arrange` stays a pure permutation.** Every substitution belongs in `constrain`. Do not add colour selection to `__tmux_lives_theme_arrange`.
- **The constrain stage order is fixed and load-bearing:** big-role lightness clamp → big-role chroma clamp → no-white → foreground floors LAST.
- **Bound 3's clamp targets 0.695, not 0.70.** Quantisation headroom. Do not "tidy" it.
- **No white.** The light ceiling is **0.88** and the no-white chroma floor is **C ≥ 0.055 when L > 0.72**. Both are hard.
- **The dark extreme is 0.05.**
- **Big roles are `1 3 6`** (bar, tabs, cap); **foreground roles are `2 4 5 7`** (sep, active, windows, text). These two sets are an unlinked partition — nothing checks they stay in sync. If you change one, check the other by hand.
- **Role order is `bar sep tabs active windows cap text`** = indices 1..7.
- **The staircase, exact values:** `text` 0.40 · `active` 0.32 · `windows` 0.26 · `sep` 0.15 · ✦ mark 0.15.
- **Prove every assertion FAILS before its fix.** Plan assertions are suspect: the previous cycle authored eleven defective ones into its own task briefs.
- **Grep guards in this repo match COMMENTS.** Line-anchor every source grep, and never spell a banned shape in prose near its own guard.
- **A test whose command substitution calls an undefined function does not fail** — fish aborts the statement, nothing prints, and a suite with no pass counter still says `ALL PASS`. Bound every body-grep to a variable defined above it and pair it with a positive count.
- **fish gotchas that return a wrong answer rather than an error:** `printf --` is not an option terminator; `string match -r` with a prefix pattern returns the matched substring, not a boolean; a zero-output command substitution collapses the whole enclosing argument to an empty list; a double-quoted `"$x[(math …)]"` index is an error.
- **The agent Bash tool runs zsh.** A non-matching glob aborts the whole command — use `find … -delete`.
- **Sweep leaked `-L` sockets** from `/tmp/tmux-1000/` after heavy runs. **Never touch `default`**; leave `neurotest*` alone.
- **Commit format:** `<type>(<scope>): <description>` with a body. Types: feat, fix, refactor, docs, test, chore, perf, ci.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `conf.d/tmux-lives-install.fish` | engine + fragment + CLI | Extract `__tmux_lives_theme_floor_role`; add `__tmux_lives_theme_floors`; add `__tmux_lives_theme_mark`; call the mark helper at `:162` |
| `functions/tmux-categorize.fish` | categorizer + pickers | Add `__tcz_thp_sortkey` / `__tcz_thp_order`; `case o`; remove the `More Schemes` header and its virtual-row accounting; mark helper in the preview |
| `tests/test-tmux-install.fish` | engine tests | Tasks 1–5, 6 |
| `tests/test-tmux-categorize.fish` | picker tests | Tasks 7–8 |

`__tmux_lives_theme_constrain` is already the largest function in the repo at ~425 lines. Task 1 extracts ~150 of those into a helper, which is a net improvement to a file this plan has to keep editing.

---

## Task 1: Extract the text floor into a parameterised helper

Pure refactor. **The output must be byte-identical across a full sweep** — this is what de-risks every task after it.

**Files:**
- Modify: `conf.d/tmux-lives-install.fish:901-1146` (the floor block inside `__tmux_lives_theme_constrain`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_rampidx`, `__tmux_lives_rgb_to_oklch`, `__tmux_lives_hex_to_rgb01`, `__tmux_lives_oklch_hex` (all existing).
- Produces: `__tmux_lives_theme_floor_role <floor> <roleidx> <pat> <locked-csv> <h1..h7>` → prints the seven hexes, one per line, with `<roleidx>` floored against `bar` (index 1). `<locked-csv>` is a comma-separated list of role indices that may NOT be used as swap donors (empty string for none). Later tasks call this four times.

- [ ] **Step 1: Capture the byte-identity baseline**

This is the control the whole refactor is judged against. Run it BEFORE touching anything.

```bash
cat > /tmp/tli-floorbase-$$.fish <<'EOF'
source conf.d/tmux-lives-install.fish
for seed in '#485b3c' '#63abab' '#87cb48' '#7a00ff' '#b03a48' '#0088ff'
    for row in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' -- $row)
        printf '%s %s %s\n' $seed "$f[1]" (string join ' ' (__tmux_lives_theme_render $seed $f[2] $f[3] $f[4] $f[5] $f[6]))
    end
end
EOF
fish --no-config /tmp/tli-floorbase-$$.fish > /tmp/tli-floorbase-before.txt
wc -l /tmp/tli-floorbase-before.txt   # expect 252
```

- [ ] **Step 2: Write the failing test for the new helper**

Add to `tests/test-tmux-install.fish`, near the other `__tmux_lives_theme_constrain` assertions (around `:3058`):

```fish
# --- Task 1: __tmux_lives_theme_floor_role extraction -------------------------
# An evenly-spaced synthetic ramp. bar (index 1) sits at L~0.13; index 7 at
# L~0.72. Floor the text role against it and assert the gap actually clears,
# measured on the ROUND-TRIPPED hex rather than the requested lightness.
set -g T1IN '#101010' '#2a2a2a' '#444444' '#5e5e5e' '#787878' '#929292' '#acacac'
set -g T1OUT (__tmux_lives_theme_floor_role 0.40 7 '' '' $T1IN)
t "T1: floor_role returns seven hexes" 7 (count $T1OUT)
set -g T1BL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T1OUT[1]))
set -g T1TL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T1OUT[7]))
t "T1: text clears its 0.40 floor against bar" 1 (test (math "abs($T1TL[1] - $T1BL[1])") -ge 0.40; and echo 1; or echo 0)
t "T1: bar is untouched by the floor" "$T1IN[1]" "$T1OUT[1]"
# The locked list must exclude a donor. Lock 2, 4 and 5 and the swap has no
# candidate left, so the nudge must carry it alone and still clear the floor.
set -g T1LK (__tmux_lives_theme_floor_role 0.40 7 '' '2,4,5' $T1IN)
set -g T1LKL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T1LK[7]))
t "T1: clears the floor with every donor locked" 1 (test (math "abs($T1LKL[1] - $T1BL[1])") -ge 0.40; and echo 1; or echo 0)
t "T1: locked roles keep their colours" "$T1IN[2] $T1IN[4] $T1IN[5]" "$T1LK[2] $T1LK[4] $T1LK[5]"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' | head`

Expected: `FAIL: T1: floor_role returns seven hexes => got [0]` — the function does not exist, so the command substitution yields an empty list.

⚠ Confirm you see that exact FAIL line. If the suite prints `ALL PASS` instead, your assertion is vacuous — fish aborted the statement silently. Fix the assertion before continuing.

- [ ] **Step 4: Extract the helper**

Cut lines `901-1146` of `conf.d/tmux-lives-install.fish` (from `# The floor. Role 1 is bar, role 7 is text.` through the end of that block) and rewrite as a standalone function placed immediately BEFORE `__tmux_lives_theme_constrain`. Preserve every comment verbatim — they record review-caught defects and measured counter-examples that are still true.

Mechanical substitutions, and nothing else:

| was | becomes |
|---|---|
| the literal `0.40` (**every occurrence — there are 10, not the 6 an earlier draft of this table claimed; replacing only some would leave stray literals that silently ignore a caller's floor**) | `$floor` |
| `$out[7]` | `$out[$role]` |
| `set out[7]` | `set out[$role]` |
| `set best 7` / `test $best -ne 7` | `set best $role` / `test $best -ne $role` |
| `$ridx[7]` | `$ridx[$role]` |
| the candidate list `for i in 2 4 5` | `for i in $cands` |

```fish
function __tmux_lives_theme_floor_role --description 'v6: force ONE foreground role to clear <floor> OKLCH lightness against bar (role 1), by swapping with another unlocked foreground role first and nudging its lightness only if no swap suffices. Prints the seven role hexes. <locked> is a comma-separated list of role indices that may not donate — roles already floored by an earlier call, so a later role can never undo an earlier guarantee. Extracted verbatim from the single-role text floor; the comments below record review-caught defects and measured counter-examples that all still hold.'
    set -l floor $argv[1]
    set -l role $argv[2]
    set -l pat "$argv[3]"
    set -l lockcsv "$argv[4]"
    set -l out $argv[5..11]
    test (count $out) -eq 7; or return 1

    # Swap candidates: the FOREGROUND roles only (2 sep, 4 active, 5 windows,
    # 7 text), never the big roles 1/3/6. Spec constraint C2: a swap is an
    # EXCHANGE, so a big role chosen here would RECEIVE this role's colour,
    # and a floored foreground is often light — measured at this function's
    # own contract boundary, cap came back at L 0.879756 from an input whose
    # big roles all entered at or below L 0.659, breaching bound 3 by 0.18.
    # The floor runs LAST, after both clamps, so nothing downstream catches it.
    #
    # This set is the other half of the big-role set at :777 (1 3 6) — an
    # unlinked partition, not a shared constant. If either changes, check the
    # other by hand.
    set -l locked (string split ',' -- "$lockcsv")
    set -l cands
    for i in 2 4 5 7
        test $i -eq $role; and continue
        contains -- "$i" $locked; and continue
        set -a cands $i
    end

    set -l lb (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[1]))
    set -l lt (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$role]))
    if test (math "abs($lt[1] - $lb[1])") -lt $floor
        # ... the extracted body, with the substitutions in the table above ...
    end
    printf '%s\n' $out
end
```

Then replace the removed block inside `__tmux_lives_theme_constrain` with a single call:

```fish
    set out (__tmux_lives_theme_floor_role 0.40 7 "$pat" '' $out)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: `ALL PASS (922)` — the 917 baseline plus the 5 assertions in the block above. **Count the `t "…"` lines you actually added and expect baseline + that number.** Do not invent an assertion to hit a number this plan states; if the plan's arithmetic and your count disagree, your count wins and the plan is wrong.

- [ ] **Step 6: Prove byte-identity — this is the real gate for this task**

```bash
fish --no-config /tmp/tli-floorbase-$$.fish > /tmp/tli-floorbase-after.txt
diff /tmp/tli-floorbase-before.txt /tmp/tli-floorbase-after.txt && echo "IDENTICAL"
```

Expected: `IDENTICAL`. **If even one line differs, the extraction changed behaviour — stop and find out why.** Do not proceed with a "close enough" diff.

- [ ] **Step 7: Run the full gate, both modes**

Two separate foreground Bash calls, `timeout: 600000` each:

```bash
for t in tests/test-*.fish; do fish $t; done 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'
```
```bash
for t in tests/test-*.fish; do fish --no-config $t; done 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'
```

Expected: 9 × `ALL PASS`, install at 922 plain / 921 `--no-config` (the 1-count delta is BY DESIGN).

- [ ] **Step 8: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "refactor(theme): extract the text floor into a parameterised per-role helper

Pure refactor, proven byte-identical across 252 renders (6 seeds x 42
schemes). __tmux_lives_theme_floor_role takes the floor, the role index,
the arrangement pattern and a locked-donor list, so the next task can call
it four times with a staircase of thresholds instead of copying 150 lines
of review-hardened nudge logic three more times.

Every comment is preserved verbatim: they record measured counter-examples
(cap at L 0.879756 breaching bound 3 by 0.18; the nudge loop stalling at
bar L 0.4798) that are still true of the extracted code."
```

---

## Task 2: The staircase — floor all four foreground roles

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_theme_constrain`, the single call added in Task 1)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_floor_role` from Task 1.
- Produces: `__tmux_lives_theme_floors` → prints four `role:floor` lines, the single source of truth for the staircase. Task 4 and Task 6 both read it.

- [ ] **Step 1: Write the failing tests**

```fish
# --- Task 2: the staircase ---------------------------------------------------
t "T2: floors table has four rows" 4 (count (__tmux_lives_theme_floors))
t "T2: text floor" "7:0.40" (__tmux_lives_theme_floors)[1]
t "T2: active floor" "4:0.32" (__tmux_lives_theme_floors)[2]
t "T2: windows floor" "5:0.26" (__tmux_lives_theme_floors)[3]
t "T2: sep floor" "2:0.15" (__tmux_lives_theme_floors)[4]

# The ordering is itself an invariant: descending, so the scarce
# high-contrast colours go to the roles that need them most and a later
# role can never outbid an earlier one.
set -g T2DESC 1
set -g T2PREV 999
for r in (__tmux_lives_theme_floors)
    set -l fv (string split ':' -- $r)[2]
    test "$fv" -lt "$T2PREV"; or set T2DESC 0
    set T2PREV $fv
end
t "T2: floors are strictly descending" 1 $T2DESC

# End to end through the real pipeline: every foreground clears its own floor.
set -g T2P (__tmux_lives_theme_render '#485b3c' square 0.30 0.13 0.75 split)
set -g T2BL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T2P[1]))
set -g T2OK 1
for r in (__tmux_lives_theme_floors)
    set -l f (string split ':' -- $r)
    set -l rl (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T2P[$f[1]]))
    test (math "abs($rl[1] - $T2BL[1])") -ge $f[2]; or set T2OK 0
end
t "T2: square split at the user's seed clears every floor" 1 $T2OK
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' | head`

Expected: `FAIL: T2: floors table has four rows => got [0]`, and `FAIL: T2: square split at the user's seed clears every floor => got [0]`.

The second one is the bug itself — that scheme currently renders `sep` at ΔL 0.101 against a 0.15 floor and `windows` at 0.252 against 0.26. **Confirm you see it fail**; it is the regression test for the reported defect.

- [ ] **Step 3: Add the floors table and the loop**

```fish
function __tmux_lives_theme_floors --description 'v6: the foreground legibility staircase, role:floor, STRICTLY DESCENDING. Four floors and not one shared value, because a single floor pushes text, active and windows all to bar +/- floor, collapsing three roles onto two lightness values -- this project already measured that forcing similarity reads as LESS cohesive, since the small roles carry the palette curve. Descending order is load-bearing: roles are floored most-demanding first and locked, so the scarce high-contrast colours are allocated to the roles that need them most and no later swap can undo an earlier guarantee. Values are calibrated against a 210-render sweep, not derived; see the spec.'
    printf '%s\n' 7:0.40 4:0.32 5:0.26 2:0.15
end
```

Replace Task 1's single call inside `__tmux_lives_theme_constrain` with:

```fish
    # The foreground floors. Most-demanding first; each role LOCKS once
    # satisfied so a later role's swap cannot take its colour back. That
    # lock is the whole reason this terminates with all four guarantees
    # simultaneously true — this repo's single most-repeated defect shape
    # is "an invariant one stage establishes is not one a later stage is
    # obliged to preserve", confirmed ten times.
    set -l flocked
    for frow in (__tmux_lives_theme_floors)
        set -l ff (string split ':' -- $frow)
        set out (__tmux_lives_theme_floor_role $ff[2] $ff[1] "$pat" (string join ',' $flocked) $out)
        set -a flocked $ff[1]
    end
```

- [ ] **Step 4: Run to verify it passes**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL' ; fish tests/test-tmux-install.fish 2>&1 | tail -1`
Expected: no FAIL lines, and a total of **922 plus however many `t "…"` assertions you added in Step 1**. Assert the delta, not an absolute — this plan's stated totals have already been wrong once.

- [ ] **Step 5: Full-sweep ratchet — every role, every scheme, six seeds**

Add this as a real assertion, not a one-off script:

```fish
# --- Task 2: the ratchet -----------------------------------------------------
# The whole point of a ratchet is that it fires on a breach ANYWHERE, so it
# sweeps rather than samples. A guard that samples can be green by luck: this
# project's bounds ratchet passed while 46 renders breached, and moving peakC
# one step (0.13 -> 0.14) turned it red.
set -g T2BREACH 0
for seed in '#485b3c' '#63abab' '#87cb48' '#7a00ff' '#b03a48' '#0088ff'
    for row in (__tmux_lives_theme_catalog_v6)
        set -l cf (string split '|' -- $row)
        set -l p (__tmux_lives_theme_render $seed $cf[2] $cf[3] $cf[4] $cf[5] $cf[6])
        test (count $p) -eq 7; or continue
        set -l bl (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $p[1]))
        for r in (__tmux_lives_theme_floors)
            set -l f (string split ':' -- $r)
            set -l rl (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $p[$f[1]]))
            test (math "abs($rl[1] - $bl[1])") -ge $f[2]; or set T2BREACH (math $T2BREACH + 1)
        end
    end
end
t "T2 ratchet: zero floor breaches across 252 renders x 4 roles" 0 $T2BREACH
```

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'T2 ratchet|^ALL PASS'`
Expected: no FAIL line for the ratchet.

- [ ] **Step 6: Perturbation — prove the ratchet can go red**

A ratchet that has never failed is not known to work. Temporarily edit `__tmux_lives_theme_floors` to raise the `sep` floor `2:0.15` → `2:0.30`, re-run, and confirm the ratchet **fails with a non-zero count**. Then restore it and confirm green again.

```bash
cp conf.d/tmux-lives-install.fish /tmp/tli-t2-restore.fish   # copy FIRST — never `git checkout` to revert, the tree has uncommitted work
sed -i 's/2:0.15$/2:0.30/' conf.d/tmux-lives-install.fish
fish tests/test-tmux-install.fish 2>&1 | grep 'T2 ratchet'   # expect a FAIL with a non-zero count
cp /tmp/tli-t2-restore.fish conf.d/tmux-lives-install.fish
diff /tmp/tli-t2-restore.fish conf.d/tmux-lives-install.fish && echo RESTORED
fish tests/test-tmux-install.fish 2>&1 | grep -c 'T2 ratchet'  # expect 0 FAIL lines
```

Record the observed breach count in the commit message.

- [ ] **Step 7: Run the full gate, both modes** (as Task 1 Step 7)

- [ ] **Step 8: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): floor all four bar foregrounds, on a descending staircase

The reported bug: windows (role 5) is status-style's fg, painted straight on
bar, and only text was constrained. Measured across 5 seeds x 42 schemes,
windows reached dL 0.012 / WCAG 1.05 and sep never once cleared the text
floor.

Four floors, not one (text 0.40 / active 0.32 / windows 0.26 / sep 0.15).
A shared 0.40 would move 71.3% of role-instances by a mean 0.215 lightness
with 0/210 schemes currently clearing it, and would collapse three text
roles onto bar +/- floor -- the 'uniformity is the opposite of cohesion'
failure this project already measured.

Roles are floored most-demanding first and LOCKED once satisfied, so a
later swap cannot undo an earlier guarantee.

Ratchet sweeps 252 renders x 4 roles; perturbation (sep 0.15 -> 0.30)
turns it red at N breaches, so it is not green by sampling luck."
```

---

## Task 3: The donor-side check

A swap is an exchange. Task 1 excludes *locked* roles from donating, but an **unlocked** donor still receives the failing colour and may itself then be unable to meet its own (lower) floor by nudging alone. Prove the guarantee holds simultaneously, and fix it if it does not.

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_theme_floor_role`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tmux_lives_theme_floors`, `__tmux_lives_theme_floor_role`.
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 3: the donor side --------------------------------------------------
# A donor receives the colour the floored role rejected. Because floors run
# in descending order, a donor's own floor is always LOWER, so it usually
# still passes -- but "usually" is not a guarantee, and the ratchet in Task 2
# would only catch it if a real catalog recipe happened to trigger it.
# This drives the case directly with a fixture built to trip it: a ramp whose
# only far colour sits on a role that is itself about to be floored.
set -g T3IN '#3a3a3a' '#404040' '#454545' '#4a4a4a' '#505050' '#555555' '#f0e8d8'
set -g T3OUT (__tmux_lives_theme_constrain $T3IN deep)
set -g T3BL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T3OUT[1]))
set -g T3OK 1
for r in (__tmux_lives_theme_floors)
    set -l f (string split ':' -- $r)
    set -l rl (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T3OUT[$f[1]]))
    test (math "abs($rl[1] - $T3BL[1])") -ge $f[2]; or set T3OK 0
end
t "T3: all four floors hold simultaneously on an adversarial fixture" 1 $T3OK
# No colour may be duplicated by a swap — a swap is an exchange, not a copy.
t "T3: no foreground colour is duplicated" 4 (count (printf '%s\n' $T3OUT[2] $T3OUT[4] $T3OUT[5] $T3OUT[7] | sort -u))
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL.*T3'`

If **both** assertions already pass, the locking from Task 2 was sufficient on this fixture. **Do not skip the task** — construct a harder fixture until one fails, or record in the commit that the property is structurally guaranteed and explain why in a source comment. A test that has never failed proves nothing.

- [ ] **Step 3: Add the donor-side guard**

Inside `__tmux_lives_theme_floor_role`, before committing a swap, reject any donor that could not itself clear its own floor with the incoming colour:

```fish
        # A swap is an EXCHANGE: the donor RECEIVES the colour this role just
        # rejected. Floors run descending so the donor's floor is lower and it
        # usually still clears -- but only a check makes that a guarantee
        # rather than a tendency, and "an invariant one stage establishes is
        # not one a later stage is obliged to preserve" is this repo's most
        # repeated defect shape.
        if test $best -ne $role
            set -l dfloor 0
            for frow in (__tmux_lives_theme_floors)
                set -l ff (string split ':' -- $frow)
                test "$ff[1]" = "$best"; and set dfloor $ff[2]
            end
            set -l incoming (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $out[$role]))
            if test (math "abs($incoming[1] - $lb[1])") -lt $dfloor
                # The donor cannot host this colour. Decline the swap and let
                # the nudge below carry the role on its own.
                set best $role
            end
        end
```

- [ ] **Step 4: Run to verify it passes**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL.*T3'`
Expected: no output.

- [ ] **Step 5: Re-run the Task 2 ratchet**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'T2 ratchet'`
Expected: no FAIL. Declining swaps must not have introduced a breach elsewhere.

- [ ] **Step 6: Full gate, both modes; then commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): a swap may not push its donor below the donor's own floor

A swap is an exchange, so the donor receives the colour the floored role
rejected. Descending floor order makes that usually safe; this makes it
guaranteed. When the donor cannot host the incoming colour the swap is
declined and the nudge carries the role alone."
```

---

## Task 4: Bounds and no-white non-regression

The floors now re-encode four roles instead of one, after both big-role clamps have run. Those clamps are already documented as fighting at the quantisation floor.

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (extend the C3 re-check comment; fix if a breach is found)
- Test: `tests/test-tmux-install.fish`

**Interfaces:** no new symbols.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 4: nothing the floors touch may breach the older bounds ------------
set -g T4B2 0   # bound 2: mean chroma of bar/tabs/cap <= 0.095
set -g T4B3 0   # bound 3: max lightness of bar/tabs/cap <= 0.70
set -g T4NW 0   # no-white: L > 0.72 requires C >= 0.055, and L <= 0.88 always
for seed in '#485b3c' '#63abab' '#87cb48' '#7a00ff' '#b03a48' '#0088ff'
    for row in (__tmux_lives_theme_catalog_v6)
        set -l cf (string split '|' -- $row)
        set -l p (__tmux_lives_theme_render $seed $cf[2] $cf[3] $cf[4] $cf[5] $cf[6])
        test (count $p) -eq 7; or continue
        set -l cs 0
        set -l lmax 0
        for i in 1 3 6
            set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $p[$i]))
            set cs (math "$cs + $o[2]")
            test "$o[1]" -gt "$lmax"; and set lmax $o[1]
        end
        test (math "$cs / 3") -gt 0.095; and set T4B2 (math $T4B2 + 1)
        test "$lmax" -gt 0.70; and set T4B3 (math $T4B3 + 1)
        for i in 1 2 3 4 5 6 7
            set -l o (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $p[$i]))
            test "$o[1]" -gt 0.88; and set T4NW (math $T4NW + 1)
            test "$o[1]" -gt 0.72; and test "$o[2]" -lt 0.055; and set T4NW (math $T4NW + 1)
        end
    end
end
t "T4: bound 2 breaches after the floors" 0 $T4B2
t "T4: bound 3 breaches after the floors" 0 $T4B3
t "T4: no-white breaches after the floors" 0 $T4NW
```

- [ ] **Step 2: Run and record the result**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL.*T4'`

Two outcomes, both legitimate:
- **No FAIL** → the floors did not disturb the older bounds. Record the zero counts in the commit; the assertions stay as permanent regression cover.
- **A FAIL with a non-zero count** → extend the C3 re-check (`conf.d/tmux-lives-install.fish:1014`) so it runs for every role the stage touches, not just `text`, and re-run.

- [ ] **Step 3: Re-derive the C3 comment's invariant per floor**

The existing comment asserts *"this branch is only reached with a LIGHT-side target (the dir-flip pre-check above already routes bar > 0.48 to dark from the start, so bar <= 0.48 always holds here)"*. That 0.48 is `0.88 - 0.40` — it is **floor-dependent**. For `sep` at 0.15 the equivalent threshold is `0.88 - 0.15 = 0.73`.

Update the comment to state the general form and stop quoting a single number as if it were universal:

```fish
            # ... the dir-flip pre-check routes bar > (0.88 - $floor) to dark
            # from the start, so bar <= (0.88 - $floor) always holds here.
            # That threshold is 0.48 at the text floor of 0.40 and 0.73 at the
            # glyph floor of 0.15 — it is FLOOR-DEPENDENT, not the constant
            # this comment used to name.
```

- [ ] **Step 4: Full gate, both modes; then commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "test(theme): pin bounds 2/3 and no-white against the widened floors

The floors now re-encode four roles instead of one, after both big-role
clamps have run, and those clamps are documented as fighting at the
quantisation floor. Sweeps 252 renders and counts breaches of all three
older bounds.

Also corrects the C3 re-check's invariant comment, which named 0.48 as a
constant. It is 0.88 - floor: 0.48 for text, 0.73 for the glyphs."
```

---

## Task 5: The ✦ mark helper

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (add the helper; call it at `:162`)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Produces: `__tmux_lives_theme_mark <barhex> <seedhex>` → prints one hex, the seed floored to 0.15 lightness against bar. Task 8 calls it from the picker preview.

⚠ **Do NOT widen `__tmux_lives_theme_render` to eight outputs.** `test (count …) -eq 7` appears in the fragment renderer, `theme_apply_live`, `theme_list` and several picker sites; the v6 surface cycle recorded the fragment-argv renumber as its sharpest hazard and this is one glyph.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 5: the mark ---------------------------------------------------------
# ΔL 0.000 was MEASURED in the shipped engine — the ✦ is sometimes exactly the
# bar colour — so the identical case is reachable, not hypothetical.
set -g T5A (__tmux_lives_theme_mark '#2a2e28' '#2a2e28')
set -g T5AB (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 '#2a2e28'))
set -g T5AL (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $T5A))
t "T5: an identical seed and bar are separated to the glyph floor" 1 (test (math "abs($T5AL[1] - $T5AB[1])") -ge 0.15; and echo 1; or echo 0)
# A seed that already clears the floor is returned untouched — the ✦ is the
# seed's home base and must stay the literal seed wherever it legibly can.
set -g T5B (__tmux_lives_theme_mark '#2a2e28' '#d8c8a8')
t "T5: a seed that already clears the floor is unchanged" '#d8c8a8' $T5B
t "T5: non-hex input degrades to the seed unchanged" 'default' (__tmux_lives_theme_mark 'colour236' 'default')
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL.*T5'`
Expected: three FAIL lines, the first `got []`.

- [ ] **Step 3: Implement**

```fish
function __tmux_lives_theme_mark --argument-names barhex seedhex --description 'v6: the ✦ presence glyph, which is the SEED rather than a palette role and so is not covered by render(). Returns the seed floored to the glyph threshold (0.15 OKLCH lightness) against bar, keeping hue and chroma. Measured: the shipped engine reaches dL 0.000 / WCAG 1.00 here — the mark is sometimes exactly the bar colour. A seed already clearing the floor is returned VERBATIM: the mark is the seeds home base and must stay the literal seed wherever it legibly can. Non-hex input (a colourNNN fallback, or "default" when the theme is off) is returned unchanged. Lives here, not inside render(), so renders seven-element contract is untouched.'
    set -l sb (__tmux_lives_hex_to_rgb01 "$barhex")
    set -l ss (__tmux_lives_hex_to_rgb01 "$seedhex")
    if test (count $sb) -ne 3; or test (count $ss) -ne 3
        echo "$seedhex"
        return
    end
    set -l lb (__tmux_lives_rgb_to_oklch $sb[1] $sb[2] $sb[3])
    set -l ls (__tmux_lives_rgb_to_oklch $ss[1] $ss[2] $ss[3])
    if test (math "abs($ls[1] - $lb[1])") -ge 0.15
        echo "$seedhex"
        return
    end
    set -l up (math "$lb[1] + 0.15")
    set -l dn (math "$lb[1] - 0.15")
    set -l newL $up
    set -l dir 1
    # Same ceiling as the floors: 0.88, never near-white.
    test "$up" -gt 0.88; and set newL $dn; and set dir -1
    set -l cand (__tmux_lives_oklch_hex $newL $ls[2] $ls[3])
    set -l tries 0
    while test $tries -lt 10
        set -l back (__tmux_lives_rgb_to_oklch (__tmux_lives_hex_to_rgb01 $cand))
        test (math "abs($back[1] - $lb[1])") -ge 0.15; and break
        set newL (math "$newL + $dir * 0.01")
        test "$newL" -gt 0.88; and set newL 0.88
        test "$newL" -lt 0.05; and set newL 0.05
        set cand (__tmux_lives_oklch_hex $newL $ls[2] $ls[3])
        set tries (math "$tries + 1")
    end
    echo $cand
end
```

- [ ] **Step 4: Wire it into the fragment**

`conf.d/tmux-lives-install.fish:162` currently reads:

```fish
        set -a f "set -g @tmux_lives_mark_fg '$seedhex'"          # the ✦ mark = the seed's home base
```

Replace with:

```fish
        set -a f "set -g @tmux_lives_mark_fg '"(__tmux_lives_theme_mark "$barbg" "$seedhex")"'"   # the ✦ mark = the seed's home base, floored to stay visible on bar
```

⚠ `$barbg` is assigned at `:145` inside the `themed` branch; this line is inside `if test $themed -eq 1`, so it is in scope. Verify by reading `:143-165` before editing.

- [ ] **Step 5: Add the fragment assertion**

`__tmux_lives_render_fragment` takes **18 positional arguments** and has no `--argument-names`, so every one is an unlabelled `$argv[N]`. The map, verified against the live caller at `conf.d/tmux-lives-install.fish:300`:

| # | meaning | # | meaning |
|---|---|---|---|
| 1 | categorizer path | 10 | status-vis key |
| 2 | prefix key | 11 | cursor style |
| 3 | switcher key | 12 | theme key |
| 4 | **bar colour (the seed)** | 13 | **theme mode** |
| 5 | status invert | 14 | **lspan** |
| 6 | modal key | 15 | **peakc** |
| 7 | scratch key | 16 | **peakpos** |
| 8 | resize key | 17 | **arrangement** |
| 9 | status-pos key | 18 | sync terminals |

```fish
# --- Task 5: the fragment uses the floored mark ------------------------------
# Bound to a variable defined ABOVE, and paired with a positive count, so an
# empty render cannot pass this by matching nothing.
set -g T5FRAG (__tmux_lives_render_fragment /X/cat.fish S M-s '#485b3c' 0 M-m M-t M-r C-M-a C-M-s block M-k square 0.30 0.13 0.75 split 'xterm*')
t "T5: fragment renders a non-empty body" 1 (test (count $T5FRAG) -gt 20; and echo 1; or echo 0)
t "T5: fragment sets mark_fg exactly once" 1 (printf '%s\n' $T5FRAG | grep -c '@tmux_lives_mark_fg')
t "T5: mark_fg is not the bare seed" 0 (printf '%s\n' $T5FRAG | grep -c "@tmux_lives_mark_fg '#485b3c'")
```

⚠ Positions 13–17 are the recipe and **were renumbered once already** (syncterm 17→18), which the v6 surface cycle recorded as its sharpest hazard. If you add or move an argument, fix `:300` and every test caller in the same commit.

- [ ] **Step 6: Run to verify it passes; full gate, both modes; then commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "fix(theme): floor the ✦ mark so it cannot vanish into the bar

The ✦ is the raw seed hex, not a palette role, so render()'s seven-element
contract never covered it — measured dL 0.000 / WCAG 1.00, the mark is
sometimes exactly the bar colour.

A small helper rather than an eighth render output: count -eq 7 appears in
the fragment renderer, apply_live, theme_list and several picker sites, and
the argv renumber was the last cycle's sharpest hazard. A seed that already
clears the floor is returned verbatim, so the mark stays the literal seed
wherever it legibly can."
```

---

## Task 6: The sort key

**Files:**
- Modify: `functions/tmux-categorize.fish` (new pure helpers near the other `__tcz_thp_*` pure functions, around `:1846`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces:
  - `__tcz_thp_sortkey <seedhue> <7 space-separated hexes>` → one fixed-width sortable string.
  - `__tcz_thp_order <seedhex> <pal1> <pal2> …` → prints the 1-based indices of the palettes in colour order, one per line.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 6: colour ordering --------------------------------------------------
# Fixed-width keys so a plain lexicographic sort is a correct numeric sort.
# Blocks are walked in the swatch strip's own order (tabs bar cap windows sep
# text active, functions/tmux-categorize.fish:1873), each contributing
# hue-from-seed then lightness.
set -g T6K (__tcz_thp_sortkey 120 '#101010 #2a2a2a #444444 #5e5e5e #787878 #929292 #acacac')
t "T6: key is fixed width" 84 (string length -- "$T6K")
# Two palettes differing only in the TABS hue must order by that hue, and the
# one nearer the seed hue clockwise must come first.
set -g T6A '#202020 #303030 #d02020 #404040 #505050 #606060 #707070'
set -g T6B '#202020 #303030 #20d020 #404040 #505050 #606060 #707070'
t "T6: green seed puts the green-tabs palette first" "2 1" (string join ' ' (__tcz_thp_order '#20d020' "$T6A" "$T6B"))
t "T6: red seed puts the red-tabs palette first" "1 2" (string join ' ' (__tcz_thp_order '#d02020' "$T6A" "$T6B"))
# Determinism: the row caches are keyed by position, so a wobbling order
# would silently mis-key them.
t "T6: order is deterministic across repeated calls" (string join ' ' (__tcz_thp_order '#20d020' "$T6A" "$T6B")) (string join ' ' (__tcz_thp_order '#20d020' "$T6A" "$T6B"))
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL.*T6'`

⚠ This suite has **no pass counter** — it prints a bare `ALL PASS`. Judge by FAIL lines only. If you see neither a FAIL nor your assertions' effects, the statement aborted silently; fix the assertion before continuing.

- [ ] **Step 3: Implement**

```fish
function __tcz_thp_sortkey --argument-names seedhue hexes --description 'pure: a fixed-width lexicographically-sortable key for one palette. Walks the swatch strips OWN block order (tabs 3, bar 1, cap 6, windows 5, sep 2, text 7, active 4 — see __tcz_thp_cells_uncached at :1873) so the sort is legible off the strip the user is already looking at. Each block contributes clockwise hue distance from the seed hue, then lightness: hue alone interleaves lights and darks, so a hue group would read as a jumble rather than a ramp. Fixed width (%07.3f + %05.3f per block, 7 blocks = 84 chars) so a plain `sort` is a correct numeric sort with no multi-key parsing.'
    set -l pal (string split ' ' -- "$hexes")
    set -l key ''
    for idx in 3 1 6 5 2 7 4
        set -l h ''
        test (count $pal) -ge $idx; and set h "$pal[$idx]"
        # Validate the SHAPE before converting. __tmux_lives_hex_to_rgb01 has no
        # shape check of its own — a non-hex string reaches `math "0xno/255"` and
        # fish's math diagnostics go straight to STDERR, which they do bypassing
        # in-process redirection. This helper runs inside a display-popup that is
        # painting a frame to the tty, so stray stderr lands in the middle of the
        # drawing and corrupts it. Checking first costs one `string match`.
        if not string match -qr '^#[0-9a-fA-F]{6}$' -- "$h"
            # Non-hex degrades to the far end so it sorts last rather than
            # collapsing the whole key (a zero-output substitution would empty
            # the enclosing argument entirely).
            set key "$key"(printf '%07.3f%05.3f' 999.999 9.999)
            continue
        end
        set -l rgb (__tmux_lives_hex_to_rgb01 "$h")
        set -l o (__tmux_lives_rgb_to_oklch $rgb[1] $rgb[2] $rgb[3])
        set -l d (math "($o[3] - $seedhue + 360) % 360")
        set key "$key"(printf '%07.3f%05.3f' $d $o[1])
    end
    printf '%s\n' "$key"
end

function __tcz_thp_order --description 'pure: 1-based palette indices in colour order. argv[1] is the seed hex; argv[2..] are space-joined 7-hex palettes. Ties break on the original index so the total order is STABLE — the row caches are keyed by position, and a wobbling order would silently mis-key them.'
    set -l seedhex $argv[1]
    set -l shue 0
    if string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedhex"
        set -l srgb (__tmux_lives_hex_to_rgb01 "$seedhex")
        set shue (__tmux_lives_rgb_to_oklch $srgb[1] $srgb[2] $srgb[3])[3]
    end
    set -l lines
    set -l i 0
    for p in $argv[2..]
        set i (math $i + 1)
        set -a lines (printf '%s|%05d' (__tcz_thp_sortkey $shue "$p") $i)
    end
    printf '%s\n' $lines | sort | string replace -r '^.*\|0*' ''
end
```

- [ ] **Step 4: Run to verify it passes; commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): a colour sort key keyed off the swatch strip's own order

Blocks are walked tabs, bar, cap, windows, sep, text, active — the same
left-to-right order __tcz_thp_cells_uncached already draws them in — so the
sort is legible off the strip without explanation. Each block contributes
clockwise hue-from-seed then lightness; hue alone interleaves lights and
darks and a hue group would read as a jumble.

Fixed-width keys make a plain sort a correct numeric sort, and ties break on
the original index so the total order is stable — the row caches are keyed
by position and a wobbling order would mis-key them."
```

---

## Task 7: The `o` toggle, its universal, and the cache invalidation

**Files:**
- Modify: `functions/tmux-categorize.fish` (`__tcz_thp_init` ~`:2470`, `__tcz_thp_reload` ~`:2513`, the key dispatch ~`:3303`)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_order` from Task 6.
- Produces: universal `tmux_lives_theme_order` ∈ {`catalog`, `colour`}, default `catalog`.

⚠ **The hazard this task exists around:** `__tcz_thp_row` and `__tcz_thp_cells` are keyed by **scheme index**, and the memo's stated correctness argument is *"a scheme's hexes cannot change without a reload, and every reload goes through `__tcz_thp_cacheclear`"*. Reordering violates that premise directly. **The toggle must call `__tcz_thp_cacheclear`.** Without it the picker paints stale rows and the frame is well-formed but wrong — there is no other symptom.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 7: the order toggle -------------------------------------------------
# Carries state forward TWICE — reorder, read, reorder back, read — because a
# stateful defect that survives one transition often fails on the second.
set -g T7SRC (functions __tcz_theme_picker)
t "T7: picker source is non-empty" 1 (test (string length -- "$T7SRC") -gt 1000; and echo 1; or echo 0)
t "T7: o is dispatched" 1 (printf '%s\n' $T7SRC | grep -cE '^\s+case o$')
t "T7: the toggle clears the row caches" 1 (printf '%s\n' $T7SRC | awk '/^ +case o$/,/^ +case /' | grep -c '__tcz_thp_cacheclear')
t "T7: the order universal is read at init" 1 (printf '%s\n' $T7SRC | grep -c 'tmux_lives_theme_order')
```

⚠ `functions <name>` prints the description and in-body comments as well as the code, so a grep for a literal can be satisfied by that literal appearing in prose. **Do not describe `case o` or `__tcz_thp_cacheclear` in any comment inside this function** — this repo has tripped its own grep guards on comments five separate times.

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL.*T7'`
Expected: three FAIL lines (all but the source-non-empty guard).

- [ ] **Step 3: Read the universal at init**

In `__tcz_thp_init` (~`:2470`), which already runs one `fish -c` to read universals, add `tmux_lives_theme_order` to that read and default it:

```fish
        set order catalog
        test "$initorder" = colour; and set order colour
```

- [ ] **Step 4: Apply the order in `__tcz_thp_reload`**

After the existing loop that populates `$toks`/`$pals`/`$fgs`/`$tabsfgs`/`$recipes`, reorder all five in lockstep when `$order` is `colour`:

```fish
        if test "$order" = colour
            # All five arrays are index-parallel; they must be permuted
            # together or a row renders one scheme's name over another's
            # colours.
            set -l perm (__tcz_thp_order "$seed" $pals)
            # Apply the permutation ONLY if it is a complete one. A short or
            # empty perm would silently truncate the catalog to nothing and
            # the frame would still render, just empty — this file has already
            # shipped one defect of exactly that shape (a zero-output command
            # substitution collapsing an enclosing list), and a picker that
            # shows no schemes has no other symptom to notice it by.
            if test (count $perm) -eq (count $pals)
                set -l t2; set -l p2; set -l f2; set -l b2; set -l r2
                for i in $perm
                    set -a t2 $toks[$i]; set -a p2 $pals[$i]; set -a f2 $fgs[$i]
                    set -a b2 $tabsfgs[$i]; set -a r2 $recipes[$i]
                end
                set toks $t2; set pals $p2; set fgs $f2; set tabsfgs $b2; set recipes $r2
            end
        end
```

⚠ `__tcz_thp_reload` already calls `__tcz_thp_cacheclear` as its first statement, so a reload-driven reorder is safe. The toggle in Step 5 goes through the same reload, which is why it inherits the invalidation.

- [ ] **Step 5: Add the dispatch**

In the main `switch $tok` (~`:3303`), beside `case m`:

```fish
            case o
                if test "$order" = colour
                    set order catalog
                else
                    set order colour
                end
                __tcz_thp_reload
                set sel 0
                set WIN (math "$rows - $STATIC_IDLE")
                fish -c 'set -U tmux_lives_theme_order $argv[1]' "$order" >/dev/null 2>&1
                set note "● order: $order"
```

`set sel 0` matters: the cursor is a position, and after a permutation the old position points at a different scheme. Resetting to the top is the honest behaviour — following the previously-selected scheme to its new position is a nicety that can come later if it is missed.

- [ ] **Step 6: Add the legend entry**

`o` must appear in the browsing legend or it is undiscoverable. Read `__tcz_thp_leg_uncached` (~`:2355`) and add a pair. ⚠ The legend is **3 rows of 9 pairs at pitch 3** and the frame emits exactly as many rows as the popup — adding a tenth pair without checking the arithmetic overflows the frame. Count the existing pairs before adding, and if the row is full, place `o` where `More Schemes` frees space in Task 8.

- [ ] **Step 7: Run to verify it passes**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL.*T7'`
Expected: no output.

- [ ] **Step 8: Prove the cache invalidation assertion can fail**

Remove `__tcz_thp_reload` from the `case o` body (leaving the toggle), re-run, and confirm the cacheclear assertion goes **red**. Restore from a file copy taken beforehand and prove byte-identity with `diff` — **never `git checkout`, the tree has uncommitted work.**

- [ ] **Step 9: Full gate, both modes; then commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): o toggles colour ordering, persisted per user

Reordering violates the row caches' stated correctness argument — they are
keyed by scheme INDEX and assume hexes cannot change without a reload — so
the toggle goes through __tcz_thp_reload, whose first statement is the one
invalidation point. Without that the frame is well-formed and shows the
wrong rows, with no other symptom.

All five index-parallel arrays are permuted in lockstep. The cursor resets
to the top: a position means a different scheme after a permutation."
```

---

## Task 8: Remove the More Schemes header

**Files:**
- Modify: `functions/tmux-categorize.fish` (`:3086`, `:3098-3103`, and `__tcz_thp_grouphdr` at `:2120` if it becomes unused)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:** no new symbols.

⚠ The header is a **virtual row**: `:3086` adds `+1` to `vsel` past `$ndefault`, and `:3098`/`:3103` special-case the boundary. Removing it means the virtual-row count equals the scheme count everywhere. This is an off-by-one hazard in scrolling maths that is already subtle — `__tcz_thp_vismap` and `__tcz_thp_window` both consume it.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 8: no group header -------------------------------------------------
set -g T8SRC (functions __tcz_theme_picker)
t "T8: picker source is non-empty" 1 (test (string length -- "$T8SRC") -gt 1000; and echo 1; or echo 0)
t "T8: no More Schemes header is emitted" 0 (printf '%s\n' $T8SRC | grep -c 'thp_grouphdr')
# The virtual-row offset that existed only for the header must go with it, or
# the cursor and the window disagree by one at the boundary.
t "T8: no ndefault virtual-row offset remains" 0 (printf '%s\n' $T8SRC | grep -cE 'set vsel \(math \$sel \+ 1\)')
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL.*T8'`
Expected: two FAIL lines with counts of 1.

- [ ] **Step 3: Remove the header and its accounting**

- `:3086` — delete `test $sel -ge $ndefault; and set vsel (math $sel + 1)`.
- `:3098-3099` — delete the `if test "$expanded" = 1; and test $i -eq $ndefault` branch that emits the header row.
- `:3103` — the `$i -gt $ndefault` branch adjusts an index for the header; delete or simplify so the index maps 1:1.
- `$ndefault` at `:2467` stays — `m` still needs it to decide how many rows to show.
- `__tcz_thp_grouphdr` at `:2120` becomes unused. **Delete it and its tests**, rather than leaving dead code with a passing test that proves nothing about the product.

**Existing tests that assert the header exists — these WILL fail and must be updated, not worked around:**

| location | what it asserts | do |
|---|---|---|
| `tests/test-tmux-categorize.fish:5515` | header absent when collapsed | keep — still true, now trivially |
| `tests/test-tmux-categorize.fish:5516` | **header present when expanded near the boundary** | **invert to absent** |
| `tests/test-tmux-categorize.fish:5519` | header absent when expanded and scrolled past | keep |
| `tests/test-tmux-categorize.fish:6321-6329` | the `__tcz_thp_grouphdr` unit block | **delete with the function** |

Also update `__t9_frame_rows`' description at `tests/test-tmux-categorize.fish:5144`, which documents `expanded`/`ndefault` as "Task 8 additions (More Schemes header + virtual-row window)". Leaving that prose in place would describe a mechanism that no longer exists — exactly the "live-looking claim about dead code" this project prunes for.

- [ ] **Step 4: Verify the frame arithmetic still balances**

The frame must emit **exactly as many rows as the popup**. Losing a virtual row changes the count.

```bash
fish tests/test-tmux-categorize.fish 2>&1 | grep -iE 'FAIL.*(frame|row|window|geometry|vismap)'
```

Expected: no output. If a geometry assertion fires, the freed row must be reclaimed by the scheme window (`WIN`), not left as a gap.

- [ ] **Step 5: Full gate, both modes; then commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "refactor(picker): drop the More Schemes header and its virtual row

Under colour ordering the header is meaningless — sorting interleaves
curated and non-curated rows — and it cost a row of a popup where rows are
the scarce resource and the admission floor is computed against the
stricter editing layout.

m stays: collapsing to the curated 14 is a real filter. Only the header
row and the +1 virtual-row offset go, so the scheme index maps 1:1 to the
rendered row again. __tcz_thp_grouphdr had no other caller and is deleted
with its tests rather than left as dead code with a green assertion."
```

---

## Task 9: Whole-branch verification

**Files:** none modified unless a defect is found.

- [ ] **Step 1: Full gate, both modes, from a clean tree**

Expected: 9 × `ALL PASS`. Record the exact counts; install should be baseline 917 + the assertions added by Tasks 1–5, categorize baseline 1406 + Tasks 6–8.

- [ ] **Step 2: Re-run the contrast survey and diff against the spec's numbers**

The spec's tables were measured on the pre-fix engine. Re-run the same sweep and confirm every foreground now clears its floor, then record the new distribution in the commit — the "after" table is the evidence the bug is fixed.

- [ ] **Step 3: Chroma-delta report**

The source at `conf.d/tmux-lives-install.fish:968` records that a push toward an extreme can cost **20%–93%** of the requested chroma. That was one role; it is now four. Measure the chroma of all four foreground roles before and after across the 252-render sweep and report mean and worst-case loss. **If the loss is severe, say so plainly in the handoff** — it is a real cost of this fix and the user should decide whether to trade some legibility back, not discover it on their bar.

- [ ] **Step 4: Socket hygiene**

```bash
ls /tmp/tmux-1000/
```

Expected: only `default` and any `neurotest*`. Remove any `test-*` leftovers with `find /tmp/tmux-1000 -name 'test-*' -delete` — **not** a glob, since the agent shell is zsh and a non-matching glob aborts the whole command.

- [ ] **Step 5: Request a whole-branch review**

Use `superpowers:requesting-code-review`. **A test that exercises one link cannot see a defect in the chain** — the last cycle's Critical survived nine clean task reviews because every migration test called its function in isolation and nothing ran the composition. Here the composition is the four floor calls in sequence, and the reviewer must drive that, not the helper alone.

- [ ] **Step 6: Merge to main and push**

Per the standing default: verify the suite is green on the branch, merge to `main`, re-verify on the merged result, push, delete the branch. Do not open a PR.

---

## Self-Review

**Spec coverage.** Part A's staircase → Tasks 2 and 3. Swap-then-nudge → Tasks 1 and 3. Bidirectional nudge → preserved verbatim by Task 1's extraction and pinned by Task 2's ratchet across six seeds including a light one (`#0088ff`). `mark` helper → Task 5. no-white / bounds interaction → Task 4. Chroma-loss risk → Task 9 Step 3. Part B's sort key → Task 6. Toggle, universal, cache hazard → Task 7. More Schemes → Task 8. Ten test requirements → distributed across Tasks 2 (ratchet, perturbation), 3 (donor), 4 (bounds), 5 (mark, identical case), 6 (determinism), 7 (persistence, state carried twice), 8 (frame arithmetic), 9 (whole-branch).

**Placeholder scan.** Task 1 Step 4 deliberately elides the extracted body as `# ... the extracted body ...` — it is a 150-line verbatim move whose text is already in the file, and reproducing it here would invite retyping rather than cutting. The substitution table above it is exact and exhaustive. Task 5 Step 5 and Task 7 Step 6 direct the implementer to read a signature or count before writing, because both are argument-position hazards where a copied placeholder is worse than a lookup.

**Type consistency.** `__tmux_lives_theme_floor_role <floor> <roleidx> <pat> <locked-csv> <h1..h7>` is defined in Task 1 and called with that arity in Tasks 2 and 3. `__tmux_lives_theme_floors` emits `role:floor` and is split on `:` identically in Tasks 2, 3 and 4. `__tcz_thp_sortkey <seedhue> <hexes>` and `__tcz_thp_order <seedhex> <pals…>` are defined in Task 6 and called with that arity in Task 7.

**One gap accepted deliberately:** Task 7 Step 6 may find the legend row full, in which case `o`'s legend entry depends on Task 8 freeing space. The dependency is stated in the step rather than resolved by reordering the tasks, because Task 8 touches frame arithmetic and is safer after the toggle exists to exercise it.
