# Picker Partial Repaint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the theme picker emit only the rows that changed — ~747 bytes instead of ~12,697 — so it stops stuttering over a remote SSH link.

**Architecture:** A new top-level `__tcz_popup_emit` holds the previously painted frame and emits cursor-addressed rows for whichever ones differ, falling back to the existing whole-frame paint when forced or when the row count changes. Both of the picker's emit sites route through it. Once input settles, one full repaint self-heals any drift between our model of the screen and reality.

**Tech Stack:** fish 4.7.1, tmux 3.3a (rocket) / 3.7b (macwork), no new dependencies, no new files.

**Spec:** `docs/superpowers/specs/2026-08-21-picker-partial-repaint-design.md`

## Global Constraints

- **Zero new files.** Everything goes in `functions/tmux-categorize.fish` and `tests/test-tmux-categorize.fish`. This repo's one-file-per-feature convention is a stated user preference, not a style guess.
- **The session switcher's emit at `__tcz_popup_draw` is out of scope** and must remain byte-identical.
- **Construction is out of scope.** Do not touch the row cache, `__tcz_thp_reload`, `__tcz_thp_cacheclear`, the arrow drain, or the 700 ms seed batch.
- **The full-paint path must stay byte-identical to today's emission.** It is the fallback and the regression anchor.
- **`__tcz_pe_*` and `__tcz_popup_emit` were checked against the existing definitions and are free.** Do not rename them without re-checking — fish redefines functions silently and this project shipped exactly that collision once.
- Gate before every commit: `for t in tests/test-*.fish; fish $t; end` and again with `fish --no-config`. Expect `ALL PASS` from all 9 suites.

### Operational notes — read before dispatching or implementing

- **Briefs in this repo have contained defects.** Multiple prior cycles found every plan defect in the plan, not the implementations. **If the code disagrees with this plan, the code wins — say so in your report rather than following the plan into a bug.**
- **Prove every assertion FAILS before the change.** An assertion nobody has seen fail is not evidence. Where an assertion is a deliberate non-regression guard (correctly passing before and after) this plan says so explicitly; do not report those as vacuous.
- **`test-tmux-categorize.fish` has no pass counter.** It prints `ALL PASS` whenever nothing set `FAIL`, so a block that never runs still reports success. **An undefined function called directly inside a `t` invocation aborts the whole statement — `t` never runs, nothing prints, and the suite still says `ALL PASS`.** Always capture into a variable first, then pass the variable to `t`.
- **Pass an explicit `timeout: 600000` on any Bash call running the gate.** The tool's 120 s default silently backgrounds it. **If a call comes back saying it was backgrounded, abandon it and re-run in the foreground** — waiting on it is futile and has stalled seven agents on this project.
- **Never run the suite under a shell `timeout`.** `timeout 120 fish tests/test-tmux-categorize.fish` truncates at ~215 assertions with no trailer and no visible failures — a false clean.
- **Capture FAIL lines.** `tail -1` hides which assertion fired.
- The agent Bash tool is **zsh**, not bash. Wrap stderr-byte-count checks in `bash -c '…'`.

---

### Task 1: The differential emitter

**Files:**
- Modify: `functions/tmux-categorize.fish` — add `__tcz_popup_emit` as a **top-level** function (not nested inside `__tcz_theme_picker`), placed immediately before `function __tcz_popup_draw` so the two frame-emitters sit together.
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `__tcz_popup_emit <row>...` — takes the frame's rows as positional arguments, emits to stdout, returns 0. Owns three globals: `__tcz_pe_prev` (list of rows last painted), `__tcz_pe_force` (`1` forces a whole-frame paint on the next call), `__tcz_pe_partial` (`1` when the last paint was partial). Tasks 2 and 3 set `__tcz_pe_force` and read `__tcz_pe_partial`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`, immediately after the existing `__t9_*` frame-proof block (search for the last `t "frame: ` assertion and append after it, before the next `# ---` section header).

Two helpers first.

**The capture technique is load-bearing and was verified against real fish before this plan was written.** Fish splits a command substitution on newlines. The whole-frame path emits a newline *between* every row, so a 3-row frame captures as **3 elements**; a differential paint is entirely cursor-addressed with no newlines at all and captures as **exactly 1**. That element count is the full-vs-partial discriminator throughout this block. Do not "fix" the splitting — it is the signal.

Three techniques were tried and rejected, so nobody repeats them: piping through `string collect` does not prevent the split (the pipe re-splits downstream); `string escape` after a pipe escapes each line separately and still yields N elements; and `string match -q '*\e\[J*'` never matches, because in glob mode `\e` is a literal backslash-e rather than ESC.

```fish
# --- __tcz_popup_emit: differential frame emission ---------------------------
# The picker repainted its whole 52-row frame on every keypress: 12,697 bytes
# to communicate a 747-byte change. Fine locally, unusable over the iPad's SSH
# link. See docs/superpowers/specs/2026-08-21-picker-partial-repaint-design.md.
function __t10_emit --description 'run __tcz_popup_emit with the given rows and return what it emitted, AS CAPTURED. The split fish performs on the command substitution is deliberate and is the assertion signal: the whole-frame path writes a newline BETWEEN rows so it yields one element per row, while a differential paint is cursor-addressed with no newlines and yields exactly one. Verified against real fish.'
    __tcz_popup_emit $argv
end

function __t10_emit_bytes --description 'byte count of what __tcz_popup_emit emitted for the given rows. Goes through a file so no shell layer can reshape the bytes being counted.'
    set -l f (mktemp)
    __tcz_popup_emit $argv >$f
    set -l n (wc -c <$f | string trim)
    rm -f $f
    echo $n
end

function __t10_reset --description 'clear the emitters state so a test starts from a known first-paint'
    set -e __tcz_pe_prev
    set -e __tcz_pe_force
    set -e __tcz_pe_partial
end
```

Now the assertions. Note the existence check comes first and is captured into a variable — see the operational note about the undefined-function trap.

```fish
set -g __t10_exists (functions -q __tcz_popup_emit; and echo 1; or echo 0)
t "emit: __tcz_popup_emit is defined" 1 $__t10_exists

# (a) WIRE FORMAT — pinned against a hand-written expected string, no parser.
# The partial path has no newlines, so it captures as a single element and can
# be compared exactly. This is the assertion that stops the test and the
# implementation from sharing a wrong assumption about the escape shape.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null           # first paint, discarded
set -g __t10_part (__t10_emit AAA XXX CCC)        # row 2 only
set -g __t10_want (printf '\e[?2026h\e[2;1HXXX\e[K\e[?2026l')
t "emit: one changed row emits exactly one addressed write" "$__t10_want" "$__t10_part"
t "emit: a partial paint captures as a single element (no newlines)" 1 (count $__t10_part)

# (b) FIRST PAINT IS FULL. Three rows, three elements.
__t10_reset
set -g __t10_first (__t10_emit AAA BBB CCC)
t "emit: the first paint is a whole-frame paint" 3 (count $__t10_first)

# (c) NOTHING CHANGED — emits nothing at all.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_same (__t10_emit_bytes AAA BBB CCC)
t "emit: an identical frame emits zero bytes" 0 $__t10_same

# (d) ROW-COUNT CHANGE forces a full paint (the geometry guard).
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_grew (__t10_emit AAA BBB CCC DDD)
t "emit: a different row count forces a whole-frame paint" 4 (count $__t10_grew)

# (e) FORCE flag.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __tcz_pe_force 1
set -g __t10_forced (__t10_emit AAA BBB CCC)
t "emit: __tcz_pe_force repaints in full even when nothing changed" 3 (count $__t10_forced)
t "emit: a full paint clears the force flag" 0 "$__tcz_pe_force"

# (f) PARTIAL flag drives Task 3's self-heal, so pin both transitions.
__t10_reset
__tcz_popup_emit AAA BBB CCC >/dev/null
set -g __t10_pf_full "$__tcz_pe_partial"
__tcz_popup_emit AAA XXX CCC >/dev/null
set -g __t10_pf_part "$__tcz_pe_partial"
t "emit: a full paint leaves __tcz_pe_partial 0" 0 "$__t10_pf_full"
t "emit: a partial paint sets __tcz_pe_partial 1" 1 "$__t10_pf_part"

# (g) EMPTY ROWS survive. If fish ever dropped an empty element from the saved
# frame the row COUNT would shift and every later diff would be garbage. This
# guards a fish behaviour the emitter depends on, not the emitter itself.
__t10_reset
__tcz_popup_emit AAA '' CCC >/dev/null
set -g __t10_emptycount (count $__tcz_pe_prev)
t "emit: an empty row is preserved in the saved frame" 3 $__t10_emptycount

# (h) REAL GEOMETRY — the number this whole change exists for. Two consecutive
# frames at the user's actual size (62-row client -> 52-row popup, expanded
# catalog, one-row cursor move), via the same __t9_draw_nocc harness the frame
# proof uses, which evals the REAL draw block rather than a reimplementation.
# Measured today: the full frame is 12,697 bytes and 747 of them change.
# The 2000 threshold is deliberately loose — it must not go red because a
# layout tweak alters a row's width — but it is nowhere near loose enough for
# a whole-frame repaint to slip through. $PAL9 is the synthetic palette the
# frame proof above already uses; it is script-scoped and in scope here.
__t10_reset
set -g __t10_g1 (__t9_draw_nocc_text list 0 35 21 0 mono "$PAL9" '' 1 14 52 0 1)
set -g __t10_g2 (__t9_draw_nocc_text list 0 35 22 0 mono "$PAL9" '' 1 14 52 0 1)
t "emit: the real-geometry fixture really is 52 rows" 52 (count $__t10_g1)
__tcz_popup_emit $__t10_g1 >/dev/null
set -g __t10_gbytes (__t10_emit_bytes $__t10_g2)
t "emit: a one-row cursor move at real geometry stays under 2000 bytes" 1 (test "$__t10_gbytes" -lt 2000; and echo 1; or echo 0)
t "emit: ...and is not zero, i.e. the two fixture frames really do differ" 1 (test "$__t10_gbytes" -gt 0; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL' | head -20`

Expected: the existence assertion fails (`expected [1] got [0]`) and every assertion built on `__t10_emit` / `__t10_emit_bytes` fails or reports empty.

**Confirm the suite trailer is `SOME FAILED`, not `ALL PASS`.** If it says `ALL PASS`, the block did not run — that is the undefined-function abort described in the operational notes, and it means your RED phase is fictional. Fix the capture-into-a-variable pattern before continuing.

- [ ] **Step 3: Implement the emitter**

Insert immediately before `function __tcz_popup_draw` in `functions/tmux-categorize.fish`:

```fish
function __tcz_popup_emit --description 'Paint a popup frame differentially: emit only the rows whose text differs from the previously painted frame, each cursor-addressed, so a one-row cursor move ships ~747 bytes instead of the whole ~12.7KB frame. That is the difference between smooth and unusable over a remote SSH link — construction is only ~30ms, so on the iPad emission WAS the per-keypress cost (docs/superpowers/specs/2026-08-21-picker-partial-repaint-design.md). Falls back to the historical whole-frame paint when __tcz_pe_force is set, or when the incoming row count differs from the previous frame: frames of different heights cannot be meaningfully diffed, and a resized popup is the likeliest way for our model of the screen to stop matching reality. Owns __tcz_pe_prev (rows last painted), __tcz_pe_force, and __tcz_pe_partial (set when the last paint was partial, so the caller can schedule a full self-heal once input settles).'
    set -l n (count $argv)
    test $n -eq 0; and return
    if test "$__tcz_pe_force" = 1; or test (count $__tcz_pe_prev) -ne $n
        # The historical whole-frame emission, unchanged. Newlines BETWEEN rows
        # only: a trailing newline after the last row scrolls the top border off.
        printf '\e[?2026h\e[H'
        test $n -gt 1; and printf '%s\e[K\n' $argv[1..-2]
        printf '%s\e[K' $argv[-1]
        printf '\e[J\e[?2026l'
        set -g __tcz_pe_prev $argv
        set -g __tcz_pe_force 0
        set -g __tcz_pe_partial 0
        return
    end
    # Collect dirty indices first, THEN emit. Two passes over 52 strings is
    # free, and it means the sync wrapper is never written for a frame with
    # nothing in it.
    set -l dirty
    for i in (seq $n)
        test "$argv[$i]" = "$__tcz_pe_prev[$i]"; or set -a dirty $i
    end
    set -g __tcz_pe_prev $argv
    test (count $dirty) -eq 0; and return
    printf '\e[?2026h'
    for i in $dirty
        # Row content goes through %s as an ARGUMENT, never into the format
        # string: rows carry arbitrary text and a literal % would otherwise be
        # interpreted as a conversion.
        printf '\e[%d;1H%s\e[K' $i "$argv[$i]"
    end
    printf '\e[?2026l'
    set -g __tcz_pe_partial 1
end
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | tail -1` — expect `ALL PASS`. Also capture FAIL lines: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'` — expect no output.

- [ ] **Step 5: Mutation-check the two assertions that matter**

Assertion (a) and (c) are the ones a wrong implementation would slip past. Prove they discriminate. **Take a file copy immediately before each mutation and restore from it — never `git checkout`, which reverts to HEAD and destroys uncommitted work. Re-take the copy before each mutation; a stale copy reverts everything newer than itself.**

1. `cp functions/tmux-categorize.fish /tmp/pe-orig.fish`
2. Mutation A — change `'\e[%d;1H%s\e[K'` to `'\e[%dH%s\e[K'` (drop the column). Run the suite. **Expect assertion (a) to FAIL.** Restore; `diff /tmp/pe-orig.fish functions/tmux-categorize.fish` must be empty.
3. Re-take the copy. Mutation B — delete the `test (count $dirty) -eq 0; and return` line. Run the suite. **Expect assertion (c) to FAIL** (it will emit a 16-byte empty sync frame). Restore and diff.

Report both mutation results verbatim. If either mutation leaves the suite green, the assertion is decorative — say so rather than proceeding.

- [ ] **Step 6: Run the full gate**

```bash
for m in "" "--no-config"; do for t in tests/test-*.fish; do out=$(fish $m "$t" </dev/null 2>&1); printf "%-32s %-11s %s\n" "$(basename $t)" "${m:-plain}" "$(echo "$out" | tail -1)"; echo "$out" | grep -E "^FAIL" | sed "s/^/   >> /"; done; done
```

Expected: 9 suites × 2 modes, all `ALL PASS`. `test-tmux-install.fish` reports 708 plain / 707 `--no-config` — **that 1-count delta is BY DESIGN**, one isolation assertion is gated on plain fish. Pass `timeout: 600000`.

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): differential frame emitter

__tcz_popup_emit holds the previously painted frame and emits only the
rows that differ, cursor-addressed. Falls back to the historical
whole-frame paint when forced or when the row count changes, which is
the geometry guard — frames of different heights cannot be diffed.

Not wired to anything yet."
```

---

### Task 2: Route both picker emit sites through it

**Files:**
- Modify: `functions/tmux-categorize.fish` — three edits inside `__tcz_theme_picker`.
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_popup_emit`, `__tcz_pe_force` from Task 1.
- Produces: the picker's frames now flow through the emitter. Task 3 depends on `__tcz_pe_partial` being set by real picker paints.

- [ ] **Step 1: Write the failing tests**

The emit sites live inside a ~1000-line function, so these are source-shape guards. **Bound them to the extracted function body and assert the extraction is non-empty first** — an empty extraction makes everything built on it vacuous, which has happened here before.

`functions <name>` prints the description and in-body comments as well as the code, so a guard can be defeated by its own prose. Strip comment lines before matching.

Append after Task 1's block:

**Count matching LINES, not regex hits on the whole body.** Matching the literal `\e[?2026h\e[H` inside a fish regex needs `\\e\[\?2026h\\e\[H` — four backslash-escaping levels between the source, the fish string and the regex — and the three plausible spellings of it do not agree. Two of them silently return zero hits, which is a guard that always passes. Splitting into lines and matching the bare substring `2026h` is unambiguous, and it was verified against the real file: **2 lines before this task, 0 after**. Comments are already stripped from the body, so the `DECSET 2026` comment cannot defeat it.

```fish
# --- the picker routes BOTH its frames through the emitter -------------------
set -g __t10_body (functions __tcz_theme_picker | string match -rv '^\s*#' | string collect)
t "wiring: picker body extraction is non-empty" 1 (test -n "$__t10_body"; and echo 1; or echo 0)
set -g __t10_bodylines (string split \n -- "$__t10_body")

set -g __t10_calls (string match -r '__tcz_popup_emit ' -- $__t10_bodylines | count)
t "wiring: picker calls the emitter at both its frames" 2 $__t10_calls

set -g __t10_inline (string match -r '2026h' -- $__t10_bodylines | count)
t "wiring: no inline whole-frame paint remains in the picker" 0 $__t10_inline

# NON-REGRESSION GUARD (correctly passes before AND after this task): the
# session switcher is deliberately out of scope. Its per-keypress content is a
# live capture-pane of a different session, so nearly every row genuinely
# differs and a diff would buy almost nothing. Do not report this as vacuous.
set -g __t10_swlines (string split \n -- (functions __tcz_popup_draw | string match -rv '^\s*#' | string collect))
t "wiring: the session switcher still paints whole frames" 1 (string match -r '2026h' -- $__t10_swlines | count)
t "wiring: the session switcher does not use the emitter" 0 (string match -r '__tcz_popup_emit' -- $__t10_swlines | count)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'`

Expected: `wiring: picker calls the emitter at both its frames` fails (`expected [2] got [0]`) and `no inline whole-frame paint remains` fails (`expected [0] got [2]`). The two switcher guards pass — they are the labelled non-regression pair.

- [ ] **Step 3: Replace the main frame's emission**

In `__tcz_theme_picker`, find this block (it is preceded by a comment beginning `# Synchronized update (DECSET 2026): commit the whole frame atomically`):

```fish
        printf '\e[?2026h\e[H'
        test (count $lines) -gt 1; and printf '%s\e[K\n' $lines[1..-2]
        printf '%s\e[K' $lines[-1]
        printf '\e[J\e[?2026l'
```

Replace the four lines with:

```fish
        __tcz_popup_emit $lines
```

Replace the preceding comment with:

```fish
        # Differential paint: only the rows that changed go out (~747 bytes
        # instead of ~12,697). __tcz_popup_emit falls back to the whole frame
        # when forced or when the height changes.
```

- [ ] **Step 4: Replace the hex-entry screen's emission**

In the nested `__tcz_thp_hexentry`, find:

```fish
            printf '\e[?2026h\e[H'
            test (count $helines) -gt 1; and printf '%s\e[K\n' $helines[1..-2]
            printf '%s\e[K' $helines[-1]
            printf '\e[J\e[?2026l'
```

Replace with:

```fish
            __tcz_popup_emit $helines
```

Leave the surrounding comment, adjusting its first sentence to say the paint is differential.

- [ ] **Step 5: Force a full paint at the boundaries**

Two edits.

First, at picker entry — find `printf '\e[?25l\e[2J'` and add immediately after it:

```fish
    # The screen was just cleared, so the emitter's model of it is stale by
    # definition. Force the first paint to be whole.
    set -e __tcz_pe_prev
    set -g __tcz_pe_force 1
```

Second, at the hex-entry call site — find `test "$editing" = 1; and __tcz_thp_hexentry` and replace with:

```fish
                if test "$editing" = 1
                    # The hex-entry screen owns the whole terminal while it
                    # runs, and hands it back with different content. Force a
                    # whole paint on each side of the handover so neither
                    # frame diffs against the other's leftovers.
                    set -g __tcz_pe_force 1
                    __tcz_thp_hexentry
                    set -g __tcz_pe_force 1
                end
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'` — expect no output. Then `| tail -1` — expect `ALL PASS`.

- [ ] **Step 7: Prove the picker still draws the same frame**

The wiring guards are source-shape only. Confirm behaviour did not move: the existing `__t9_frame_rows` assertions (26-row frames, and the height-derived ones) all still pass, because construction is untouched. Confirm that explicitly:

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -c '^FAIL'` — expect `0`.

- [ ] **Step 8: Run the full gate and commit**

Full gate command as in Task 1 Step 6, `timeout: 600000`.

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): route both picker frames through the emitter

Main frame and hex-entry screen now emit differentially. Forced whole
paints at picker entry and on each side of the hex-entry handover, where
the emitter's model of the screen is stale by construction.

The session switcher is deliberately untouched — its preview pane makes
nearly every row differ on a cursor move, so a diff buys nothing there."
```

---

### Task 3: Self-heal when input settles

**Files:**
- Modify: `functions/tmux-categorize.fish` — the settle-poll block in `__tcz_theme_picker`.
- Test: `tests/test-tmux-categorize.fish`

**Interfaces:**
- Consumes: `__tcz_pe_partial`, `__tcz_pe_force` from Task 1; the wiring from Task 2.
- Produces: nothing later tasks depend on. This is the last task.

**Why this exists:** differential emission is only correct while our model of the screen matches reality. A client resize (the iPad's on-screen keyboard, or rotating the device), a redraw of the popup from underneath, or bytes dropped on a bad link all leave a stale mix that no later partial paint corrects — every later frame only touches rows that changed *since* the stale one.

- [ ] **Step 1: Write the failing tests**

The settle block is deep inside the interactive loop and cannot be called directly, so this is an anchored source guard plus a note that the runtime behaviour is live-smoke-only. The file already uses `# BEGIN floor-check` / `# END floor-check` markers for exactly this purpose; follow that precedent.

**This block must extract from the UN-stripped body.** `$__t10_body` from Task 2 has comment lines removed, and `# BEGIN self-heal` / `# END self-heal` *are* comments — reusing it would make every assertion here vacuous. The `# BEGIN floor-check` precedent already in this file reads `functions __tcz_theme_picker | string collect` with no stripping, which is why it works. Follow it exactly.

```fish
# --- the settle poll also heals a partially-painted screen -------------------
# NB: un-stripped body. The BEGIN/END markers are comments, so the
# comment-stripped $__t10_body from the wiring block above cannot see them.
set -g __t10_raw (functions __tcz_theme_picker | string collect)
t "self-heal: raw picker body extraction is non-empty" 1 (test -n "$__t10_raw"; and echo 1; or echo 0)

set -g __t10_heal (string match -r '# BEGIN self-heal(.|\n)*?# END self-heal' -- "$__t10_raw" | string collect)
t "self-heal: the marked block exists" 1 (test -n "$__t10_heal"; and echo 1; or echo 0)
t "self-heal: it forces a whole repaint" 1 (string match -q '*__tcz_pe_force 1*' -- "$__t10_heal"; and echo 1; or echo 0)
t "self-heal: it clears the partial flag, which is what stops it looping" 1 (string match -q '*__tcz_pe_partial 0*' -- "$__t10_heal"; and echo 1; or echo 0)

# The gate must arm on a partial paint IN ADDITION to the two existing
# conditions. flashfield and seeddirty are deliberately independent — three
# sibling key arms clear flashfield on unrelated keypresses, and coupling them
# once silently cancelled a pending seed batch. Assert all three survive.
set -g __t10_gate (string match -r 'if test -n "\$flashfield"; or test "\$seeddirty" = 1[^\n]*' -- "$__t10_raw" | string collect)
t "self-heal: the settle gate still tests flashfield and seeddirty" 1 (test -n "$__t10_gate"; and echo 1; or echo 0)
t "self-heal: the settle gate also arms on a partial paint" 1 (string match -q '*__tcz_pe_partial*' -- "$__t10_gate"; and echo 1; or echo 0)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'`

Expected: `the marked block exists` fails, both block-content assertions fail, and `the settle gate also arms on a partial paint` fails. **`the settle gate still tests flashfield and seeddirty` must PASS** — it is pinning existing behaviour that this task must not break.

- [ ] **Step 3: Widen the gate**

Find:

```fish
        if test -n "$flashfield"; or test "$seeddirty" = 1
```

Replace with:

```fish
        if test -n "$flashfield"; or test "$seeddirty" = 1; or test "$__tcz_pe_partial" = 1
```

- [ ] **Step 4: Heal on timeout**

Inside the same block's `if test "$tok" = timeout` branch, after the existing `if test "$seeddirty" = 1 … end` and immediately before the `continue`, insert:

```fish
                # BEGIN self-heal
                # A partial paint means our model of the screen is only as good
                # as the assumption that nothing else touched it. A resize, a
                # redraw from underneath, or a dropped byte would leave a stale
                # mix that no later partial paint corrects — later frames only
                # touch rows that changed since the stale one. Input has now
                # settled, so a whole repaint costs nothing anybody is waiting
                # on. Clearing the partial flag is what terminates this: the
                # next iteration has no flash, no batch and no partial paint
                # outstanding, so it drops to a normal blocking read. One heal
                # per scroll burst.
                if test "$__tcz_pe_partial" = 1
                    set -g __tcz_pe_force 1
                    set -g __tcz_pe_partial 0
                end
                # END self-heal
                continue
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `fish tests/test-tmux-categorize.fish 2>&1 | grep -E '^FAIL'` — expect no output.

- [ ] **Step 6: Mutation-check the loop-termination guard**

The clearing of `__tcz_pe_partial` is the only thing preventing an endless repaint loop, and no in-process test can observe the loop. Prove the guard sees its absence.

1. `cp functions/tmux-categorize.fish /tmp/pe-heal.fish`
2. Delete the `set -g __tcz_pe_partial 0` line from the self-heal block.
3. Run the suite. **Expect `self-heal: it clears the partial flag` to FAIL.**
4. Restore from the copy; `diff /tmp/pe-heal.fish functions/tmux-categorize.fish` must be empty.

- [ ] **Step 7: Run the full gate and commit**

Full gate command as in Task 1 Step 6, `timeout: 600000`.

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(picker): repaint in full once input settles

Differential emission is only correct while our model of the screen
matches reality; a resize or a dropped byte leaves a stale mix no later
partial paint corrects. The existing ~0.7s settle poll now also arms on
a partial paint and forces one whole repaint. Clearing the partial flag
is what stops it looping."
```

---

## Verification before calling this done

Invoke `superpowers:verification-before-completion`. Evidence required, not assertions:

- 9 suites × 2 modes, all `ALL PASS`, with FAIL lines captured (not `tail -1`). `test-tmux-install.fish` at 708 / 707 — the delta is by design.
- The measured byte figure at real geometry. Re-run the frame measurement from the spec (52-row popup, expanded 35, one-row cursor move) and report the actual emitted byte count. **Expect roughly 747; anything near 12,697 means the wiring is not live.**
- All four mutation results, verbatim, with the post-restore `diff` shown empty each time.

## What cannot be tested here, and goes to the user

Everything about how this *feels* is runtime-only over a real link. The live smoke, after `fisher update`:

- **The reversal.** Hold down, then up, then down on the iPad over ShellFish. This is the most sensitive probe available, because the arrow drain is direction-blind and discards a queued burst including the direction change. If that is smooth, this worked.
- **The self-heal.** It is a full 12,697-byte repaint of *identical* content, and with no working sync wrapper on tmux 3.3a it may show as a visible sweep about a second after scrolling stops. If it does, the fix is to skip the heal when the frame is byte-identical to `__tcz_pe_prev` — deliberately not built up front.
- **Hex entry.** Type a colour in the seed editor and confirm the screen is correct on entry, during typing, and on the way back to the main frame.
- **Seed edit mode.** `b`, drag a channel, `esc`. The frame changes wholesale here and is deliberately *not* force-repainted, so this is where a diff bug would show.
