# Picker Responsiveness and Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the theme picker responsive enough that a held arrow scrolls rapidly and stops on release, then land the seed-zone and default-list changes the user asked for.

**Architecture:** Memoize the pure `__tcz_thp_*` row builders in process globals keyed on their full inputs, with a single invalidation point inside `__tcz_thp_reload`. Unify all three held-key paths on one-step-per-frame with discard. Then a 3-row seed colour block with the hex centred inside it, and a default list showing all 35 catalog rows ordered seed-literal first.

**Tech Stack:** fish 4.7.1, tmux 3.3a, no external dependencies. Everything lives in `functions/tmux-categorize.fish` and `conf.d/tmux-lives-install.fish`.

## Global Constraints

- **One conf.d file per feature; ZERO net new files in `conf.d/` or `functions/`.** Add functions to the existing files.
- **Never deploy.** Edit → test → commit → push, then stop. The user runs `fisher update` themselves.
- **The full gate is:** `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'` — run it in the FOREGROUND with an explicit `timeout: 300000`. It exceeds the Bash tool's 120 s default and is otherwise auto-backgrounded, which has stalled six subagents across previous builds.
- **`test-tmux-install.fish` counts differ by exactly 1 between plain fish and `--no-config`.** That is BY DESIGN (one isolation assertion is gated on plain fish). Never "fix" it.
- **Every assertion in this plan must be run against the pre-fix code and shown to FAIL before you trust it.** Briefs in this plan have not been reviewed by anyone but their author; previous builds in this repo averaged well over ten plan defects each, every one caught by implementers rather than by me. If an assertion here passes before you make the change, say so and stop — do not weaken it to fit.
- **Grep guards match COMMENTS.** Describe a banned shape, never spell it. This trap has fired nine times in this repo.
- **`test-tmux-categorize.fish` has no pass counter.** An undefined function called directly inside a `t` invocation aborts the statement, prints nothing, and still reports `ALL PASS`. Always capture into a variable first, then assert on the variable.
- **`string match -r` without `--entire` returns only the matched substring, not the whole line.** This is a documented landmine in this codebase (see `__tmux_lives_theme_catalog_default`). Cache-clearing enumeration must use `-e`.
- **`string match -er` with a CAPTURING group emits the capture alongside the full match.** Found in this plan's own pre-flight: `string match -er '^__tcz_(cc|rc|sc)_'` over variable names yields `__tcz_cc_2 cc __tcz_rc_1_0_0 rc __tcz_sc_seed sc` — the bare `cc`/`rc`/`sc` entries would then be handed to `set -e`, erasing any unrelated variable that happened to carry one of those names. Use a non-capturing group `(?:…)`. Verified both forms directly.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `functions/tmux-categorize.fish` | all picker builders, the draw block, the interactive loop | 1–7 |
| `conf.d/tmux-lives-install.fish` | `__tmux_lives_theme_catalog` row order | 8 |
| `tests/test-tmux-categorize.fish` | picker assertions, frame proof, drain invariant | 1–7 |
| `tests/test-tmux-install.fish` | catalog composition assertions | 8 |

---

### Task 1: Cache infrastructure and the scheme-row cache

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_thp_cacheclear` beside the other top-level `__tcz_thp_*` builders; wrap `__tcz_thp_row`; call the clear from `__tcz_thp_reload` (~:1728)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Produces: `__tcz_thp_cacheclear` (no args, erases every `__tcz_cc_*` / `__tcz_rc_*` / `__tcz_sc_*` global); `__tcz_thp_row_uncached` (the original builder, renamed via `functions --copy`); `__tcz_thp_row <hexes> <name> <selected> <current> [<cachekey>]` — a 5th OPTIONAL argument. With it, the result is cached; without it, behaviour is byte-identical to today and nothing is cached.
- Consumes: nothing.

**Why the 5th argument rather than keying on `$hexes`:** the key must be built with plain string interpolation. A key derived from the palette string needs `string replace` to strip `#` and spaces (both illegal in a fish variable name), which costs two command substitutions per lookup at 0.108 ms each and eats most of the win. Measured: interpolated-key lookup 0.06 ms/row vs 5.6 ms to rebuild.

**Why index is a safe key:** the palette arrays and the caches are invalidated together in `__tcz_thp_reload`. This is load-bearing — see Step 5.

- [ ] **Step 1: Write the failing test**

Add near the other picker builder tests in `tests/test-tmux-categorize.fish`:

```fish
# --- Task 1: the scheme-row cache -----------------------------------------
# The discriminator is a CALL COUNT, not a grep. A "fix" that caches but still
# rebuilds every row passes any string-shaped assertion and fails this one.
set -g __t1_calls 0
functions --copy __tcz_thp_row_uncached __t1_real
function __tcz_thp_row_uncached
    set -g __t1_calls (math $__t1_calls + 1)
    __t1_real $argv
end

set -g __t1_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
__tcz_thp_cacheclear

# transparency: cached output must equal uncached, on miss AND on hit
set -g __t1_a (__t1_real "$__t1_pal" 'mono soft' 0 0 | string escape)
set -g __t1_b (__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 | string escape)
set -g __t1_c (__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 | string escape)
t "rowcache: cached output matches uncached (miss)" "$__t1_a" "$__t1_b"
t "rowcache: cached output matches uncached (hit)"  "$__t1_a" "$__t1_c"

# the hit did no work
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 >/dev/null
t "rowcache: a cache hit calls the builder zero times" 0 $__t1_calls

# a cursor move dirties exactly TWO rows out of 35
__tcz_thp_cacheclear
for i in (seq 35)
    __tcz_thp_row "$__t1_pal" "scheme$i" (test $i -eq 5; and echo 1; or echo 0) 0 $i >/dev/null
end
set -g __t1_calls 0
for i in (seq 35)
    __tcz_thp_row "$__t1_pal" "scheme$i" (test $i -eq 6; and echo 1; or echo 0) 0 $i >/dev/null
end
t "rowcache: moving the cursor one row rebuilds exactly 2 rows" 2 $__t1_calls

# no key -> no caching, byte-identical to the original builder
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 >/dev/null
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 >/dev/null
t "rowcache: omitting the key bypasses the cache entirely" 2 $__t1_calls

# invalidation: clearing forces a rebuild
__tcz_thp_cacheclear
set -g __t1_calls 0
__tcz_thp_row "$__t1_pal" 'mono soft' 0 0 7 >/dev/null
t "rowcache: cacheclear forces a rebuild" 1 $__t1_calls

functions --erase __tcz_thp_row_uncached
functions --copy __t1_real __tcz_thp_row_uncached
```

- [ ] **Step 2: Run it and verify it fails**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E 'rowcache|FAIL' | head -20`
Expected: FAIL on every `rowcache:` line — `__tcz_thp_cacheclear` and `__tcz_thp_row_uncached` do not exist yet. Confirm the failures are real assertion failures with printed values, not silent aborts. If a line is simply absent from the output rather than failing, you have hit the no-pass-counter trap described in Global Constraints — capture into a variable first.

- [ ] **Step 3: Add the clear helper**

Insert as a new top-level function immediately before `__tcz_thp_fg` (~:1229):

```fish
function __tcz_thp_cacheclear --description 'erase every memoized picker builder result. The ONE invalidation point: called from __tcz_thp_reload, which is the only thing that may rewrite the palette arrays. Rows are keyed by INDEX, so a list whose indices shift (expand/collapse) MUST come through here or cached rows go stale against the wrong scheme. -e/--entire is load-bearing: a bare -r returns the matched substring, not the variable name, and would erase nothing.'
    for v in (set --names | string match -er '^__tcz_(?:cc|rc|sc)_')
        set -e $v
    end
end
```

- [ ] **Step 4: Wrap the row builder**

Rename the existing `function __tcz_thp_row` to `function __tcz_thp_row_uncached` (leave its body and description untouched), then add immediately after it:

```fish
function __tcz_thp_row --argument-names hexes name selected current cachekey --description 'memoizing front for __tcz_thp_row_uncached. With <cachekey> (the scheme index) the rendered row is cached in a global and reused; without it, nothing is cached and the call is byte-identical to the uncached builder. The key is built by plain interpolation only — deriving one from <hexes> would need string replace to strip # and spaces, at two command substitutions per lookup, which costs more than it saves (measured 0.06ms interpolated vs 5.6ms to rebuild).'
    test -z "$cachekey"; and __tcz_thp_row_uncached "$hexes" "$name" "$selected" "$current"; and return
    set -l k "__tcz_rc_$cachekey"_"$selected"_"$current"
    set -q $k; and printf '%s\n' $$k; and return
    set -g $k (__tcz_thp_row_uncached "$hexes" "$name" "$selected" "$current")
    printf '%s\n' $$k
end
```

- [ ] **Step 5: Wire the clear into `__tcz_thp_reload`**

In the `__tcz_thp_reload` closure (~:1728), add as the FIRST line of the body, before `set toks; set pals; …`:

```fish
        # Rows are keyed by index; expanding or collapsing shifts what each
        # index means, and a new seed changes every palette. This is the ONE
        # invalidation point, which is what lets the row key stay a bare
        # integer instead of a sanitised palette string.
        __tcz_thp_cacheclear
```

- [ ] **Step 6: Pass the index at the call site**

In the draw block's scheme-row loop, change the row construction to pass the index. The existing line reads `set -l row (__tcz_thp_row "$pals[$idx]" $toks[$idx] $selflag $curflag)`; append `$idx` as a fifth argument.

- [ ] **Step 7: Run the tests and verify they pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -3`
Expected: `ALL PASS`

- [ ] **Step 8: Run the full gate**

Run the gate from Global Constraints, foreground, `timeout: 300000`.
Expected: 8/8 `ALL PASS` in both modes.

- [ ] **Step 9: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "perf(picker): cache rendered scheme rows

A cursor move changes exactly two rows -- the one losing the selection
band and the one gaining it -- but the draw rebuilt all 35. Measured on
the row loop at the user's geometry: 135.3ms today, 2.2ms cached."
```

---

### Task 2: Cache the static rows

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_preview`, `__tcz_thp_tabstrip`, `__tcz_thp_seedzone`, `__tcz_thp_leg`, `__tcz_thp_staterow`, `__tcz_thp_band`
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_cacheclear` from Task 1.
- Produces: nothing new; each builder gains an optional trailing `cachekey` argument with the same contract as Task 1's.

**Estimate, stated honestly:** the static rows are believed to be roughly 58 ms of the frame, extrapolated from two frame sizes rather than measured directly. **Step 1 measures it for real before you change anything** — if the true figure is much smaller, say so in your report; the task may not be worth its complexity and that is a legitimate finding, not a failure.

- [ ] **Step 1: Measure the static cost directly**

Write a throwaway probe in the scratchpad that sources the categorizer with `tmux_categorize_test` set, then times each of the six builders in a bare loop (no `eval` wrapper — `eval` costs more than the callees and will corrupt the reading; this happened during spec research). Record ms/call for each.

Report the numbers in your task report. Proceed with caching only those builders costing more than 0.5 ms/call; note any you skip and why.

- [ ] **Step 2: Write the failing test**

For each builder you are caching, add a call-count test of the same shape as Task 1's, using its own real arguments. Example for the preview bar — repeat this pattern per builder rather than writing "similar to the above":

```fish
set -g __t2_calls 0
functions --copy __tcz_thp_preview_uncached __t2_prev_real
function __tcz_thp_preview_uncached
    set -g __t2_calls (math $__t2_calls + 1)
    __t2_prev_real $argv
end
__tcz_thp_cacheclear
set -g __t2_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
set -g __t2_a (__t2_prev_real 50 "$__t2_pal" '#f5f5f5' somehost | string escape)
set -g __t2_b (__tcz_thp_preview 50 "$__t2_pal" '#f5f5f5' somehost k1 | string escape)
t "staticcache: preview cached output matches uncached" "$__t2_a" "$__t2_b"
set -g __t2_calls 0
__tcz_thp_preview 50 "$__t2_pal" '#f5f5f5' somehost k1 >/dev/null
t "staticcache: preview hit calls the builder zero times" 0 $__t2_calls
functions --erase __tcz_thp_preview_uncached
functions --copy __t2_prev_real __tcz_thp_preview_uncached
```

- [ ] **Step 3: Run and verify failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E 'staticcache|FAIL' | head -20`
Expected: FAIL on every `staticcache:` line.

- [ ] **Step 4: Apply the Task 1 wrapper pattern to each builder**

Rename each to `<name>_uncached` and add a memoizing front with a trailing optional `cachekey`, exactly as in Task 1 Step 4. Do not invent a different mechanism per builder — one pattern, repeated.

- [ ] **Step 5: Pass keys at the draw-block call sites**

The key must encode everything that varies. For the seed zone that is `<editing>_<chan>_<r>_<g>_<b>`; for the preview it is the cursor's scheme index; for the legend it is `<editing>`; for the state rows it is `<selected>_<live>`. The tab chip is drawn once per frame from values fixed at picker-open, so a constant key is correct there.

- [ ] **Step 6: Run the tests and the full gate**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -3`, then the full gate, foreground, `timeout: 300000`.
Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 7: Re-measure the whole frame and report**

Re-run your Step 1 probe plus a whole-frame measurement. Report before/after ms for: browsing curated, browsing expanded, editing. These numbers go in the commit message and the final summary.

- [ ] **Step 8: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "perf(picker): cache the frame-constant static rows

Once scheme rows are cached, the static rows dominate. None of them
change while the cursor moves."
```

---

### Task 3: Memoize the swatch strip

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_cells` (~:1238)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_thp_cacheclear`.
- Produces: `__tcz_thp_cells <hexes> [<cachekey>]`, same optional-key contract.

**Context:** `__tcz_thp_cells` costs 5.4 ms and is 96 % of an uncached row (5.6 ms). After Task 1 it only runs for genuinely dirty rows, so this saves roughly 2 × 5.4 ms per frame — the smallest of the three perf tasks, and the one to drop if it fights the frame proof.

- [ ] **Step 1: Write the failing test**

```fish
set -g __t3_calls 0
functions --copy __tcz_thp_cells_uncached __t3_real
function __tcz_thp_cells_uncached
    set -g __t3_calls (math $__t3_calls + 1)
    __t3_real $argv
end
__tcz_thp_cacheclear
set -g __t3_pal '#44502f #798c7e #98b3a0 #c9decf #98b3a0 #1caf80 #e0f5e6'
set -g __t3_a (__t3_real "$__t3_pal" | string escape)
set -g __t3_b (__tcz_thp_cells "$__t3_pal" 3 | string escape)
set -g __t3_c (__tcz_thp_cells "$__t3_pal" 3 | string escape)
t "cellcache: cached matches uncached (miss)" "$__t3_a" "$__t3_b"
t "cellcache: cached matches uncached (hit)"  "$__t3_a" "$__t3_c"
set -g __t3_calls 0
__tcz_thp_cells "$__t3_pal" 3 >/dev/null
t "cellcache: a hit calls the builder zero times" 0 $__t3_calls
set -g __t3_calls 0
__tcz_thp_cells "$__t3_pal" >/dev/null
__tcz_thp_cells "$__t3_pal" >/dev/null
t "cellcache: omitting the key bypasses the cache" 2 $__t3_calls
functions --erase __tcz_thp_cells_uncached
functions --copy __t3_real __tcz_thp_cells_uncached
```

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E 'cellcache|FAIL' | head`
Expected: FAIL on every `cellcache:` line.

- [ ] **Step 3: Apply the wrapper pattern**

Rename to `__tcz_thp_cells_uncached`; add the memoizing front using key `"__tcz_cc_$cachekey"`. `__tcz_thp_row_uncached` calls `__tcz_thp_cells` and must pass its own `cachekey` straight through.

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "perf(picker): memoize the swatch strip

~17 command substitutions per call, 96% of an uncached row."
```

---

### Task 4: Give edit-mode ↑↓ a drain

**Files:**
- Modify: `functions/tmux-categorize.fish` — the `editing` branch of `case up down pgup pgdn` (~:2348)
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:** consumes nothing from earlier tasks; independent of 1–3.

**The defect:** the non-editing branch drains held repeats; the editing branch does not. Every autorepeat byte therefore gets its own full-frame rebuild, unbounded. `chan` clamps to 1–3, so the user sees two changes and then a frozen screen until release.

- [ ] **Step 1: Write the failing test**

Timing behaviour needs a real tty — grep cannot see it, and this exact class of bug survived nine per-task reviews on a previous branch. Drive the real arm through a pty:

```fish
# --- Task 4: edit-mode channel select must drain -------------------------
# Extract the real editing branch and run it against a pty holding a burst of
# queued down-arrows. Without a drain, chan advances once and the remaining
# bytes stay buffered for the next frame -- an unbounded backlog. With one,
# the buffer is empty afterward.
set -g EDITARM (awk '/case up down pgup pgdn/,/^            case left right$/' $catfile | string collect)
t "editarm extraction is non-empty" 1 (test -n "$EDITARM"; and echo 1; or echo 0)
t "editarm extraction stopped at the right anchor" 1 (string match -q '*case left right*' -- "$EDITARM"; and echo 1; or echo 0)
set -g __t4_drains (string match -a -r 'while true(?=\n\s+stty min 0 time )' -- "$EDITARM" | count)
t "editarm: the editing branch has a compliant drain" 1 $__t4_drains
```

Then the behavioural half. Drive the REAL extracted arm with a stubbed reader that hands it a queued burst, and assert both that the burst was consumed and that `chan` advanced only once. This is a genuine discriminator: pre-fix the arm never reads past the first key, so the stub still has queued tokens left.

```fish
# stub the reader with a scripted queue, and stty with a no-op, so the real
# arm can be evald in-process. __t4_fed counts how many tokens it consumed.
set -g __t4_queue down down down down
set -g __t4_fed 0
function __t4_readkey
    set -g __t4_fed (math $__t4_fed + 1)
    if test $__t4_fed -le (count $__t4_queue)
        echo $__t4_queue[$__t4_fed]
    else
        echo cancel
    end
end
function __t4_run
    functions --copy __tcz_popup_readkey __t4_saved_readkey
    functions --copy __t4_readkey __tcz_popup_readkey
    function stty; end
    set -l editing 1
    set -l chan 1
    set -l tok down
    set -l focus list
    set -l sel 0
    set -l sel2 0
    set -l n 35
    set -l WIN 31
    eval $EDITARM
    functions --erase stty
    functions --copy __t4_saved_readkey __tcz_popup_readkey
    echo "$chan $__t4_fed"
end
set -g __t4_res (string split ' ' -- (__t4_run))
t "editarm: chan advances exactly one step for a held burst" 2 "$__t4_res[1]"
t "editarm: the drain consumed the whole queued burst" 5 "$__t4_res[2]"
```

`__t4_fed` of 5 means the drain read all four queued `down`s plus the terminating `cancel`. Pre-fix it is 0, because the editing branch never reads again after `$tok`.

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E 'editarm|FAIL' | head`
Expected: `editarm: the editing branch has a compliant drain` FAILS with `0`, and the pty assertion FAILS with a non-zero leftover.

- [ ] **Step 3: Implement the drain**

Inside the `if test "$editing" = 1` branch, after the existing `switch $tok` that moves `chan`, add a drain that swallows queued `up`/`down` without counting them. It must mirror the non-editing branch exactly, including re-asserting `stty min 0 time 0` on the line immediately inside the loop — `__tcz_popup_readkey`'s CSI branch leaves the tty blocking on return, and a drain read after it hangs. Restore `stty min 1 time 0` after the loop.

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes. Confirm the drain-invariant assertion still reports 1 — a compliant drain raises both counts by one and leaves the difference unchanged.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "fix(picker): drain held repeats in edit-mode channel select

case up/down drained only in its non-editing branch, so holding a key
in the seed editor queued one full frame per autorepeat byte. chan
clamps at 1-3, which is why it read as two jerks and then a dead
screen until release."
```

---

### Task 5: Slider ←→ discards instead of summing

**Files:**
- Modify: `functions/tmux-categorize.fish` — `case left right` (~:2415)
- Test: `tests/test-tmux-categorize.fish`

**The change:** the slider's drain currently accumulates (`set delta (math "$delta - 8")` per queued key), so a burst applies one large jump and no intermediate value is ever drawn — there is nothing to stop on. Discard instead, applying exactly one 8-unit step per frame.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 5: the slider drain must DISCARD, not accumulate ---------------
set -g LRARM (awk '/^            case left right$/,/^            case m$/' $catfile | string collect)
t "lrarm extraction is non-empty" 1 (test -n "$LRARM"; and echo 1; or echo 0)
t "lrarm extraction stopped at the right anchor" 1 (string match -q '*case m*' -- "$LRARM"; and echo 1; or echo 0)
# the accumulating forms must be gone from the drain
set -g __t5_acc (string match -a -r 'set delta \(math' -- "$LRARM" | count)
t "lrarm: the drain no longer accumulates delta" 0 $__t5_acc
```

Plus the behavioural half, same technique as Task 4: drive the REAL extracted arm with a stubbed reader holding four queued `right`s, and assert the channel moved by exactly one 8-unit step rather than five.

```fish
set -g __t5_queue right right right right
set -g __t5_fed 0
function __t5_readkey
    set -g __t5_fed (math $__t5_fed + 1)
    if test $__t5_fed -le (count $__t5_queue)
        echo $__t5_queue[$__t5_fed]
    else
        echo cancel
    end
end
function __t5_run
    functions --copy __tcz_popup_readkey __t5_saved_readkey
    functions --copy __t5_readkey __tcz_popup_readkey
    function stty; end
    set -l editing 1
    set -l chan 1
    set -l tok right
    set -l seedr 100
    set -l seedg 100
    set -l seedb 100
    set -l seed '#646464'
    set -l flashfield ''
    set -l seeddirty 0
    eval $LRARM
    functions --erase stty
    functions --copy __t5_saved_readkey __tcz_popup_readkey
    echo $seedr
end
set -g __t5_r (__t5_run)
t "lrarm: a held burst moves the channel one step, not five" 108 "$__t5_r"
```

Pre-fix this yields **140** (100 + 8 + 8×4, the summed burst). Post-fix it yields 108. That difference is the whole point of the task, so if it does not fail at 140 first, the extraction anchors are wrong — investigate rather than adjusting the expected value.

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E 'lrarm|FAIL' | head`
Expected: `lrarm: the drain no longer accumulates delta` FAILS with a count of 2.

- [ ] **Step 3: Implement**

In the `case left right` drain, replace the two accumulating arms with swallow-only arms matching the list drain's `case up down`, and keep `case '*'; break`. `delta` stays at its initial ±8.

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "fix(picker): the seed slider steps once per frame

Summing the burst meant intermediate values were never drawn, so there
was nothing to stop on -- the user's 'skips renders, hard to stop in
the right spot'. Same rule as the list now."
```

---

### Task 6: Seed colour block 2 rows → 3, hex centred inside

**Files:**
- Modify: `functions/tmux-categorize.fish` — `__tcz_thp_seedzone` (~:1522), `STATIC_IDLE`/`STATIC_EDIT` (:1955-1956)
- Test: `tests/test-tmux-categorize.fish` (`:2666-2667` STATIC pins, `:2705-2708` floor pins)

**Interfaces:** `__tcz_thp_seedzone`'s signature and row-count contract change: 4 rows idle, 9 editing.

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 6: the seed block is three rows, hex centred inside ------------
set -g __t6_idle (__tcz_thp_seedzone 50 '#5f772b' 96 0.47 0.09 0 1 95 119 43 | count)
set -g __t6_edit (__tcz_thp_seedzone 50 '#5f772b' 96 0.47 0.09 1 1 95 119 43 | count)
t "seedzone: idle is 4 rows"    4 $__t6_idle
t "seedzone: editing is 9 rows" 9 $__t6_edit
t "idle static is 17" 17 "$STATIC9I"
t "editing static is 22" 22 "$STATIC9E"
t "floor: rows 24 is rejected (below STATIC_EDIT + 3)" '' (__t9_floor 24)
t "floor: rows 25 is admitted" admit (__t9_floor 25)
# the hex renders INSIDE the block, not to its right: on the middle block row,
# stripped of SGR, the hex must be preceded by fewer columns than the block width
set -g __t6_mid (__tcz_thp_seedzone 50 '#5f772b' 96 0.47 0.09 0 1 95 119 43)[3]
set -g __t6_plain (__tcz_strip_sgr "$__t6_mid")
t "seedzone: the hex sits inside the block" 1 (string match -qr '^.\s{0,3}#5f772b' -- "$__t6_plain"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run and verify failure**

Expected: idle reports 3, editing 8, statics 16/21, and the floor pins fail at the shifted values.

- [ ] **Step 3: Implement the layout**

In `__tcz_thp_seedzone`: emit three block rows instead of two. The middle one carries the hex centred within the 12-column block — pad left and right around the 7-character hex — painted with the contrast-aware foreground the picker already computes for the seed, plus the existing muted `hue/L/C` readout to the right of the block. The first and third block rows are block only. Update the function description to state 4/9 rows and that the hex is now interior.

Then set `STATIC_IDLE 17` and `STATIC_EDIT 22`.

- [ ] **Step 4: Update the STATIC and floor pins**

Change `test-tmux-categorize.fish:2666-2667` to expect 17 and 22, and the floor pins from 19/20/23-rejected + 24-admitted to 20/21/24-rejected + 25-admitted. Update the comment above the floor pins, which currently narrates the 22→21 history, to record this change too — **and then grep the whole test file for the old literals**, because an incompletely-applied correction has reached an implementer in this repo before.

- [ ] **Step 5: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes. The frame-row proof reads the STATIC values out of the source by regex, so it should follow automatically — if it does not, the extraction regex has drifted and that is a real finding.

- [ ] **Step 6: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): 3-row seed block with the hex centred inside it

The admission floor rises with STATIC_EDIT, from 24 to 25 popup rows
(29 to 30 client rows at -h 85%)."
```

---

### Task 7: Show all 35 by default; `m` collapses

**Files:**
- Modify: `functions/tmux-categorize.fish` — `expanded` init (:1675), the `m` arm (~:2460), the legend text
- Test: `tests/test-tmux-categorize.fish`

- [ ] **Step 1: Write the failing test**

```fish
# --- Task 7: the picker opens on the full catalog ------------------------
set -g SLB7 (functions __tcz_theme_picker | string collect)
set -g __t7_init (string match -rg 'set -l expanded (\d)' -- "$SLB7")
t "picker opens expanded" 1 "$__t7_init"
# the legend must not still advertise m as expanding
set -g __t7_leg (string match -a -r "'m expand'" -- "$SLB7" | count)
t "legend no longer says m expands" 0 $__t7_leg
```

- [ ] **Step 2: Run and verify failure**

Expected: `picker opens expanded` FAILS with `0`; the legend assertion FAILS with `1`.

- [ ] **Step 3: Implement**

Set `expanded` to 1 at :1675. The `m` arm at :2480 already toggles symmetrically and already calls `__tcz_thp_reload` before reading `$n`, so it needs no logic change — verify that by reading it rather than assuming. Update the legend pair from `m expand` to `m curated`.

Leave the `More Schemes` divider exactly as it is: it now appears on open, which is the intent.

- [ ] **Step 4: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): open on the full catalog, m collapses to curated"
```

---

### Task 8: Catalog ordered seed-literal first

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_theme_catalog` (:749)
- Test: `tests/test-tmux-install.fish`

**The change:** reorder the tier sequence from `soft glow slate chip deep core` to `glow soft chip slate core deep` — literal before derived at each placement, with the bar → tabs → cap progression preserved. Because `_default` and `_rest` are both filters over this one function, both inherit the order, which is exactly the "literal-first within each group" the user confirmed.

**Do not add, remove, or re-flag any row.** The set stays 35 with the same 14 flagged default. This is purely a reordering.

- [ ] **Step 1: Write the failing test**

```fish
set -g CAT8 (__tmux_lives_theme_catalog)
t "catalog is still 35 rows" 35 (count $CAT8)
t "catalog still has 14 defaults" 14 (count (__tmux_lives_theme_catalog_default))
# literal rows all precede derived rows
set -g __t8_lastlit 0
set -g __t8_firstder 999
for i in (seq (count $CAT8))
    set -l f (string split '|' -- $CAT8[$i])
    if test "$f[4]" = literal
        set __t8_lastlit $i
    else if test $i -lt $__t8_firstder
        set __t8_firstder $i
    end
end
t "every literal row precedes every derived row" 1 (test $__t8_lastlit -lt $__t8_firstder; and echo 1; or echo 0)
t "the first catalog row is literal" literal (string split '|' -- $CAT8[1])[4]
```

- [ ] **Step 2: Run and verify failure**

Run: `fish tests/test-tmux-install.fish 2>&1 | grep -E 'literal|FAIL' | head`
Expected: `every literal row precedes every derived row` FAILS — today's first row is `mono soft`, which is derived.

- [ ] **Step 3: Reorder**

Rewrite the `printf '%s\n' \` argument list in tier order `glow soft chip slate core deep`, moving whole tier blocks without editing any row's contents. Update the function description, which currently states "derived before literal within each".

- [ ] **Step 4: Verify no row changed**

Run a diff of the sorted row sets before and after — they must be identical. Sorting removes order, so this isolates "did any row's text change" from "did the order change":

```bash
git stash && fish -c 'set -g tmux_categorize_test 1; source conf.d/tmux-lives-install.fish; __tmux_lives_theme_catalog' | sort > /tmp/cat-before.txt
git stash pop && fish -c 'set -g tmux_categorize_test 1; source conf.d/tmux-lives-install.fish; __tmux_lives_theme_catalog' | sort > /tmp/cat-after.txt
diff /tmp/cat-before.txt /tmp/cat-after.txt && echo "IDENTICAL SET"
```

- [ ] **Step 5: Run the tests and the full gate**

Expected: `ALL PASS`, 8/8 both modes. `test-tmux-install.fish` pins catalog counts and the 14 default NAMES; none of those are order-sensitive, so they should be unaffected. If an order-sensitive assertion surfaces, report it rather than reordering to suit it.

- [ ] **Step 6: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(theme): order the catalog seed-literal first

The user wants to see the literal-seed schemes grouped so they can
judge whether the trend they are sensing between literal and derived
is real. Pure reordering -- same 35 rows, same 14 curated."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 memoize pure builders | 1, 2, 3 |
| §1 single invalidation point in `__tcz_thp_reload` | 1 Step 5 |
| §1 `m` reload invariant | 1 Step 5 comment + 7 Step 3 |
| §2 edit-mode drain | 4 |
| §2 slider discard | 5 |
| §2 drain invariant unchanged at 1 | 4 Step 4 |
| §2 direction-blindness deliberately unfixed | no task, by design |
| §3 seed block 3 rows, hex centred | 6 |
| §3 STATIC 17/22, floor 25/30 | 6 Steps 3-4 |
| §4 all 35 default, divider kept, `m` collapses | 7 |
| §4 literal-first ordering | 8 |
| Testing §2 call counters | 1, 2, 3 |
| Testing §6 pty harness | 4 |
| Testing §8 caches cleared between assertions | 1 (`__tcz_thp_cacheclear` is production code, used by tests) |

**Placeholder scan:** no TBD/TODO. Task 2 Step 1 is a measurement step with a real deliverable (numbers in the report) rather than a placeholder, and its outcome may legitimately reduce the task's scope.

**Type consistency:** `__tcz_thp_cacheclear` (no args) is named identically in Tasks 1, 2, 3. The optional trailing argument is called `cachekey` throughout. Cache prefixes are `__tcz_cc_` (cells), `__tcz_rc_` (rows), `__tcz_sc_` (static), and the clear helper's regex covers all three.

**One defect found and fixed during self-review, recorded because the shape repeats:** Task 5's behavioural assertion originally echoed a variable the test itself had just set, so it would have passed against unmodified code — a vacuous assertion of exactly the kind that has reached implementers on four previous branches. It is replaced with a stub-and-eval harness that drives the real extracted arm and yields 140 pre-fix against 108 post-fix. Task 4's behavioural half was rewritten the same way, replacing a fragile nested-quoting pty invocation that would more likely have failed to run at all than to test anything.

**Verify-before-trusting still applies to every assertion above, including the two just rewritten.** They are reasoned, not executed — no assertion in this plan has been run. Each task's Step 2 exists to prove its own failure first, and an assertion that passes pre-fix is a plan bug to report, never a test to soften.
