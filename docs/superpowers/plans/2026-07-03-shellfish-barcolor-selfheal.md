# ShellFish Bar-color Self-heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make stale ShellFish tab colors self-heal automatically — the status-right categorize tick (refreshed by tmux every `status-interval` = 15s) re-emits the stored bar color to attached ShellFish clients, so a missed `client-attached`, a race, a mid-session color change, or a reattach recovers within ~15s without running `setup color --apply`.

**Architecture:** Bake the ShellFish color into the tick call in the managed fragment (`… tick '$color'`, re-baked on every `setup color`, exactly like the existing `on-attach` hook), and have the categorizer's `tick` verb re-emit it via the existing `__tcz_recolor` when a non-empty color is passed.

**Tech Stack:** fish shell, tmux 3.3a, the existing ShellFish OSC path (`__tcz_recolor` / `__tcz_client_is_shellfish` / `__tcz_emit_barcolor`).

## Global Constraints

- ZERO new repo files. Only edit: `functions/tmux-categorize.fish`, `tests/test-tmux-categorize.fish` (Task 1); `conf.d/tmux-lives-install.fish`, `tests/test-tmux-install.fish`, `CLAUDE.md` (Task 2).
- **Hard test-isolation invariant:** no test may touch the live default-socket tmux server, fragment, or universals. The tick test MUST stub `__tcz_categorize` (a bare `__tcz_main tick …` otherwise runs the full categorize against the user's live server) and reuse the existing recolor stub harness (a `function tmux` faking `list-clients`, temp ttys, `tmux_lives_fake_environ` for ShellFish detection). The fragment render test is pure (render-to-string, no live touch).
- fish `math` has NO comparison operators — use `test`.
- Commit messages MUST end with the trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Do NOT deploy (no `fisher`), do NOT edit `~/.config/fish`, `~/.config/tmux`, or `~/.tmux.conf`.
- Full-suite gate before each commit: `fish -c 'for t in tests/test-*.fish; fish $t; end'` — all 8 suites `ALL PASS`, 0 FAIL (ignorable flake: `test-tmux-restore.fish` may emit one stderr "no server running …" line).
- Re-emitting the identical OSC is silent in ShellFish (no flicker) — user-confirmed live; the tick cadence is bounded by `status-interval` (15s), so no throttle is needed.

---

### Task 1: Categorizer — the tick re-emits the bar color

**Files:**
- Modify: `functions/tmux-categorize.fish` (the `case tick` arm in `__tcz_main`)
- Test: `tests/test-tmux-categorize.fish` (inside the existing recolor block, before its teardown)

**Interfaces:**
- Consumes: `__tcz_recolor <color>` (existing — emits the ShellFish OSC to attached ShellFish clients, filters non-ShellFish, guards empty).
- Produces: `__tcz_main tick <color>` re-emits `<color>` after categorizing; `tick` with an empty/absent color does not emit.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-categorize.fish`, locate the recolor block's last assertion `t "recolor skips non-shellfish client" …` (currently ~line 583). Immediately AFTER that line and BEFORE the teardown line `set -e tmux_lives_fake_environ` (~line 584), insert:

```fish
# tick re-emits the stored bar color (self-heal). Stub __tcz_categorize so the
# tick verb does NOT run the full categorize against the live server; reuse the
# recolor block's `tmux` list-clients stub + temp ttys ($tt1/$tt2) above.
functions -c __tcz_categorize __tcz_cat_bak
function __tcz_categorize; end
rm -f $tt1; touch $tt1; set -gx tmux_lives_fake_environ "LC_TERMINAL=ShellFish"
__tcz_main tick "#1f6feb"
t "tick re-emits color to shellfish client" yes (string match -q '*settoolbar*' -- (cat $tt1 | string collect); and echo yes; or echo no)
rm -f $tt1; touch $tt1
__tcz_main tick ''
t "tick with empty color does not emit" no (test -s $tt1; and echo yes; or echo no)
rm -f $tt1; touch $tt1
__tcz_main tick
t "bare tick (no color) does not emit" no (test -s $tt1; and echo yes; or echo no)
functions -e __tcz_categorize; functions -c __tcz_cat_bak __tcz_categorize; functions -e __tcz_cat_bak
```

(The `tmux` stub, `$tt1`/`$tt2`, and the ShellFish `tmux_lives_fake_environ` are all set up earlier in this same recolor block and are torn down two lines below your insertion, so they are in scope here.)

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `tick re-emits color to shellfish client` gets `no` (the current `case tick` returns before any recolor), final line `SOME FAILED`.

- [ ] **Step 3: Add the re-emit to the tick case.** In `functions/tmux-categorize.fish`, the `case tick` arm currently reads:

```fish
        case tick
            __tcz_categorize >/dev/null 2>&1
            return 0
```

Change it to:

```fish
        case tick
            __tcz_categorize >/dev/null 2>&1
            test -n "$argv[2]"; and __tcz_recolor $argv[2]
            return 0
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `fish tests/test-tmux-categorize.fish`
Expected: PASS — the three new assertions `ok`, final line `ALL PASS`.

- [ ] **Step 5: Run the full gate.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'`
Expected: all 8 suites `ALL PASS`, 0 FAIL (ignore the restore-suite stderr flake).

- [ ] **Step 6: Commit.**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(color): tick re-emits the stored bar color (ShellFish self-heal)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fragment bakes the color into the tick call + docs

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (the `status-right` render in `__tmux_lives_render_fragment`, ~line 58)
- Modify: `CLAUDE.md` (the status/ShellFish paragraph)
- Test: `tests/test-tmux-install.fish` (fragment-render section)

**Interfaces:**
- Consumes: the render's existing `$color` local (`set -l color $argv[4]`, line 15).
- Produces: the rendered `status-right` runs `#(fish --no-config $cat tick '<color>')` — the color Task 1's tick re-emits.

- [ ] **Step 1: Write the failing test.** In `tests/test-tmux-install.fish`, in the fragment-render section (near the existing color-bake render assertions), add:

```fish
set -g FRAGT (__tmux_lives_render_fragment /x/cat.fish S M-s "#1f6feb" 0 | string collect)
t "tick call bakes the bar color" yes (string match -q "*cat.fish tick '#1f6feb'*" -- "$FRAGT"; and echo yes; or echo no)
set -g FRAGT0 (__tmux_lives_render_fragment /x/cat.fish S M-s "" 0 | string collect)
t "tick call empty color when unset" yes (string match -q "*cat.fish tick ''*" -- "$FRAGT0"; and echo yes; or echo no)
```

- [ ] **Step 2: Run it and verify it fails.**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — the render still emits `… tick)` with no color argument, so `tick call bakes the bar color` gets `no` (`FAILED (N)`).

- [ ] **Step 3: Bake the color into the tick call.** In `conf.d/tmux-lives-install.fish` (~line 58), the status-right render currently reads:

```fish
    set -a f "set -g status-right \"#{T:@tmux_lives_status_right}#(fish --no-config $cat tick)\""
```

Change the tick call to pass `'$color'`:

```fish
    set -a f "set -g status-right \"#{T:@tmux_lives_status_right}#(fish --no-config $cat tick '$color')\""
```

- [ ] **Step 4: Run the test and verify it passes.**

Run: `fish tests/test-tmux-install.fish`
Expected: PASS — the two new assertions `ok`, `ALL PASS`.

- [ ] **Step 5: Document the self-heal in CLAUDE.md.** In `CLAUDE.md`, in the status-bar/ShellFish paragraph (the one describing `setup color`, `__tcz_recolor`, and the `client-attached` hook), add a sentence:

```
The status-right categorize tick also re-emits the ShellFish bar color to attached ShellFish clients every ~15s (`status-interval`): the fragment bakes the color into the tick call (`#(… tick '<color>')`, re-baked on every `setup color`), and the `tick` verb runs `__tcz_recolor $argv[2]`. So a stale tab (missed `client-attached`, a race, a mid-session color change, or a reattach) self-heals silently within ~15s — `setup color --apply` is now a manual override rather than a routine fix.
```

- [ ] **Step 6: Run the full gate + confirm no live leak.**

Run: `fish -c 'for t in tests/test-*.fish; fish $t; end'` → all 8 suites `ALL PASS`, 0 FAIL.
Run: `grep -c "tick '" ~/.config/tmux/tmux-lives.conf` → the live fragment is unchanged by the suite (its value is your deployed state, not a test write; just confirm the suite didn't rewrite it — compare before/after if unsure).

- [ ] **Step 7: Commit.**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish CLAUDE.md
git commit -m "feat(color): bake the bar color into the tick call so stale ShellFish tabs self-heal

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Pre-flight (already established this session)

- `#()` in `status-right` is refreshed on `status-interval` (15s) — bounds the re-emit cadence; no throttle needed.
- Re-emitting the identical `settoolbar` OSC is silent in ShellFish (no flicker) — user-confirmed live 2026-07-02.
- `fish --no-config` cannot read the `tmux_lives_bar_color` universal → the color must be baked into the tick call (verified). Baking mirrors the existing `on-attach` hook and needs no new render argument.
- `__tcz_recolor` / `__tcz_client_is_shellfish` / `__tcz_emit_barcolor` exist and are exercised by the current suite.

## Self-Review

- **Spec coverage:** tick re-emit (Task 1) ✓; fragment bakes the color, empty-color case (Task 2) ✓; isolation via categorize-stub + recolor harness, pure render test (both tasks) ✓; docs (Task 2) ✓; non-goals (focus-in hook, throttle) correctly omitted.
- **Placeholder scan:** none — every step carries exact code/commands.
- **Type/name consistency:** `__tcz_main tick <color>` reads `$argv[2]`; the render bakes `'$color'` into `… tick '<color>'` which `$argv[2]` receives; `__tcz_recolor` is the existing verb. Consistent across tasks.
