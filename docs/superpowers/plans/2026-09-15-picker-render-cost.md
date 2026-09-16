# Picker Render Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The theme picker stops stalling for seconds. Opening it (or toggling `o`/`m`/`M`, or applying a seed) is instant once a seed's schemes have been rendered, and the first render of a seed is materially faster.

**Architecture:** Two independent layers. (1) An in-process memo on the two pure colour-decode primitives, which the engine calls with the same inputs repeatedly. (2) A file-backed render cache keyed by engine-file checksum + seed, holding `recipe → 7 hexes`, which survives the picker's per-process lifetime (the picker runs as its own `fish --no-config` process, so a file is the only carrier). Then the picker and `setup theme list` call the cached renderer instead of the raw one.

**Tech Stack:** fish 4.7, the repo's `tests/test-*.fish` gate.

**Spec:** none — user-chosen option after controller measurement, below.

## Evidence (controller, 2026-09-15)

Measured on rocket (fish 4.7) and macwork (M4 Pro), rendering the 42-row v6 catalog at seed `#78b34c`:

| | rocket | macwork |
|---|---|---|
| render all 42 schemes (what a cold list build costs) | **4,981 ms** | **2,491 ms** |
| per scheme, average / worst | 119 / 265 ms | 59 / 95 ms |
| `__tcz_thp_order` over 42 (every list rebuild) | 372 ms | — |
| build 30 scheme rows (uncached) | 98 ms | — |
| one scheme row (uncached) | 2 ms | — |

Inside one render (`complementary bright`, rocket, 107 ms): `__tmux_lives_theme_constrain` is **78 ms** of it; `ramp` 2.9 ms, `arrange` 0.3 ms, `anchors` 0.2 ms. The cost is conversion churn, not arithmetic in any one stage: that render calls `__tmux_lives_hex_to_rgb01` **46 times for 20 distinct hexes** and `__tmux_lives_oklch_hex` 19 times (all distinct). Across the whole catalog: **1,699 decode calls for 521 distinct hexes — 69% repeats.** Primitive costs: `rgb_to_oklch` 0.8 ms, `oklch_hex` 1.9 ms per call.

The user chose to do both layers (memo + persisted cache).

## Global Constraints

- **Never deploy.** No edits under `~/.config/fish`, `~/.tmux.conf`, no `set -U`. Commit on the branch; the user runs `fisher update`.
- **Zero new files** in `conf.d/` or `functions/`. Everything goes in the existing files.
- **Palette output must not change.** Every task proves byte-identical renders for the whole catalog at several seeds, before vs after (the comparison fixture is defined in Task 1 and reused).
- **Test isolation is a live hazard here.** A seam that resolves through `$HOME` escapes the suites' `XDG_CONFIG_HOME` redirect — this project already truncated a real user file that way. Every test that can reach the cache MUST set the seam variable, and Task 2 adds a bracket check proving a full gate run leaves the real cache directory untouched.
- **Tests first**: every new assertion is shown FAILING (or, for pure-perf work, proven by mutation/telemetry as the task specifies) before the fix; paste the FAIL lines verbatim.
- **Foreground suites, explicit `timeout: 600000`**, never `run_in_background`, never a shell `timeout`; if a call comes back backgrounded, abandon it and re-run in the foreground. Filter with `grep -E '^FAIL|ALL PASS|SOME FAILED'`.
- **Capture-first** before `t`; a fish function cannot see its caller's `set -l` locals.
- Never `git checkout`/`git stash` to undo experiments; copy the file, restore from the copy, prove with `diff`.
- The Bash tool runs **zsh**: quote args starting with `=`; non-matching globs abort; loops in zsh syntax or via fish.
- `tests/test-tmux-popup.fish` has a known flaky wall-clock assertion that fails on `main` too — re-run once, report both, do not fix.
- Commits: conventional, no attribution trailer.
- **Briefs in this repo have repeatedly contained defects. If the code disagrees with this plan, the code wins — say so in your report with evidence.**

---

### Task 1: memoize the colour-decode primitives

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_hex_to_rgb01` (~`:561`), `__tmux_lives_rgb_to_oklch` (~`:571`).
- Test: `tests/test-tmux-install.fish` — near the existing engine/colour tests.

**Interfaces:**
- Both functions keep their exact signatures and output. They gain a process-lifetime memo: `__tmux_lives_hex_to_rgb01 <hex>` → 3 lines; `__tmux_lives_rgb_to_oklch <r> <g> <b>` → 3 lines (L, C, H).
- Produces for later tasks: nothing new; Task 2/3 rely only on faster renders.

- [ ] **Step 1: Write the equivalence fixture and the memo tests**

Add to `tests/test-tmux-install.fish`:

```fish
# Render equivalence fixture (2026-09-15): the memo and the render cache must not
# change a single byte of any palette. Three seeds x the whole catalog, hashed.
function __tml_render_digest --argument-names seed --description 'pure: a digest of every catalog palette at <seed>'
    set -l out
    for row in (__tmux_lives_theme_catalog_v6)
        set -l f (string split '|' -- $row)
        set -a out (printf '%s|%s' "$f[1]" (string join ' ' (__tmux_lives_theme_render "$seed" $f[2] $f[3] $f[4] $f[5] $f[6])))
    end
    printf '%s\n' $out | cksum
end
```

Pin the digests as constants for seeds `#78b34c`, `#c0703a`, `#3a6fc0`: run the fixture against the PRE-change code, paste the three values into the test as literals, and assert them. (These are non-regression guards, green before and after — say so in your report; their job is to fail if the memo changes output.)

Then the memo's own behaviour, which must FAIL pre-change:

```fish
# The memo is per-process and keyed by the exact argument text. Counting real work is
# the only way to see it: wrap the uncached body and count calls through it.
set -g __tml_memo_probe 0
functions -c __tmux_lives_hex_to_rgb01_uncached __tml_hr_probe_bak
functions -e __tmux_lives_hex_to_rgb01_uncached
function __tmux_lives_hex_to_rgb01_uncached; set -g __tml_memo_probe (math $__tml_memo_probe + 1); __tml_hr_probe_bak $argv; end
__tmux_lives_hex_to_rgb01 '#123456' >/dev/null
__tmux_lives_hex_to_rgb01 '#123456' >/dev/null
__tmux_lives_hex_to_rgb01 '#123456' >/dev/null
set -l probe1 $__tml_memo_probe
t "hex_to_rgb01: three identical calls do the work once" 1 "$probe1"
__tmux_lives_hex_to_rgb01 '#654321' >/dev/null
set -l probe2 $__tml_memo_probe
t "hex_to_rgb01: a different hex does new work" 2 "$probe2"
functions -e __tmux_lives_hex_to_rgb01_uncached; functions -c __tml_hr_probe_bak __tmux_lives_hex_to_rgb01_uncached; functions -e __tml_hr_probe_bak
set -e __tml_memo_probe
```

Add the same pair for `__tmux_lives_rgb_to_oklch` (three identical triples, then a different one). Also assert the memoized functions still reject/handle their edge inputs exactly as before — check what the current bodies do with a non-hex string or out-of-range numbers and pin that behaviour unchanged (if the current function has no guard, do NOT add one; the memo must not change semantics).

- [ ] **Step 2: Run to verify the memo tests fail**

`fish tests/test-tmux-install.fish 2>&1 | grep -E '^FAIL|ALL PASS|SOME FAILED'`. The four memo assertions must FAIL (the `_uncached` function does not exist yet, so they will fail on the `functions -c` of a missing function — that is an acceptable RED as long as it is the memo assertions that go red; if the failure mode is a silently-aborted statement instead, restructure the test so it fails loudly, per the constraints). Paste the FAIL lines.

- [ ] **Step 3: Implement**

Rename each existing body to `<name>_uncached` (keeping its docstring, with a line saying it is the uncached core) and add a memoizing front under the original name. Use parallel-array globals, not dynamic variable names: a hex is safe in a name but the rgb triple ("0.470588 0.701961 0.298039") is not, and one pattern for both is easier to reason about.

```fish
function __tmux_lives_hex_to_rgb01 --argument hex --description 'memoizing front for __tmux_lives_hex_to_rgb01_uncached. Pure function, so the memo is process-lifetime and needs no invalidation: the engine decodes the same hexes over and over (measured: 1,699 calls for 521 distinct hexes across one catalog render), and each decode is ~0.8ms of fish math.'
    set -l i (contains -i -- "$hex" $__tml_hr_keys)
    if test -n "$i"
        printf '%s\n' (string split ' ' -- $__tml_hr_vals[$i])
        return
    end
    set -l v (__tmux_lives_hex_to_rgb01_uncached $hex)
    set -ga __tml_hr_keys "$hex"
    set -ga __tml_hr_vals (string join ' ' $v)
    printf '%s\n' $v
end
```

Mirror it for `__tmux_lives_rgb_to_oklch` with key `"$r $g $b"` and globals `__tml_ro_keys`/`__tml_ro_vals`.

Two things to verify rather than assume: that the uncached functions emit exactly 3 lines for valid input (so join/split round-trips), and what they emit for invalid input (the memo must reproduce it, including emitting nothing — check that a zero-length `$v` does not store a bogus entry; if it can, skip caching that case and say so).

- [ ] **Step 4: Run to verify, and measure**

- `fish tests/test-tmux-install.fish` and `fish --no-config tests/test-tmux-install.fish` → ALL PASS (counts rise by the number of assertions you added; report both).
- Re-run the three pinned digests → unchanged (that is the byte-identity proof).
- Time the catalog render before/after in a throwaway script (source `conf.d/tmux-lives-install.fish`, render all 42 rows at `#78b34c`, `date +%s%N` around it). Baseline is 4,981 ms on rocket — measure your own baseline from a pristine copy on the same machine and load, and report both numbers.

- [ ] **Step 5: Full gate** — both modes; report every trailer.

- [ ] **Step 6: Commit** — `perf(theme): memoize the colour-decode primitives`, body carrying the measured before/after.

---

### Task 2: a file-backed render cache

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — new `__tmux_lives_render_cache_path`, `__tmux_lives_engine_key`, `__tmux_lives_theme_render_cached`, placed beside the other `*_path` seam helpers and the engine.
- Test: `tests/test-tmux-install.fish`.

**Interfaces:**
- Produces: `__tmux_lives_theme_render_cached <seedHex> <mode> <Lspan> <peakC> <peakPos> <arrangement>` → identical output to `__tmux_lives_theme_render`, served from cache when present.
- Produces: `__tmux_lives_render_cache_path` → the cache DIRECTORY, seam `tmux_lives_render_cache_dir`, default `$XDG_CACHE_HOME/tmux-lives` when `XDG_CACHE_HOME` is set, else `$HOME/.cache/tmux-lives` (follow the existing `__tmux_lives_state_path` / `__tmux_lives_funcs_path` seam idiom).
- Produces: `__tmux_lives_engine_key` → a short token that changes whenever the engine changes.

- [ ] **Step 1: Write the failing tests**

All cache tests MUST set the seam first (`set -gx tmux_lives_render_cache_dir /tmp/tml-rc-$fish_pid`) and remove that directory at the end. Assertions:

1. `__tmux_lives_render_cache_path` honours the seam; with the seam unset and `XDG_CACHE_HOME` set it is `$XDG_CACHE_HOME/tmux-lives`; with both unset it is `$HOME/.cache/tmux-lives`.
2. First call to `__tmux_lives_theme_render_cached` for a recipe creates a cache file and returns exactly what `__tmux_lives_theme_render` returns for the same arguments (compare the two outputs directly).
3. Second call returns the same 7 hexes **without rendering**: prove it by shadowing `__tmux_lives_theme_render` with a counter (same `functions -c` pattern as Task 1) and asserting the counter did not advance.
4. A different seed does not hit the first seed's entry (render count advances, values differ).
5. The engine key changes when the engine changes: capture `__tmux_lives_engine_key`, append a comment line to a COPY of the install file that the key is computed from, recompute, assert different — design the key so this is testable (see Step 3), and restore the copy.
6. Entries under a stale engine key are not served: write a cache file by hand under a bogus key, assert a render for that recipe still calls the real renderer.
7. A corrupt or truncated cache line is ignored rather than served: hand-write a file with a line missing fields and one with a non-hex palette, assert the renderer is called and the corrupt line does not reach the output.
8. Concurrency: two appends interleaved do not lose an entry — simulate by appending a second entry between a read and a write in the same process, then asserting both are readable.
9. **Isolation bracket:** record the real cache directory's existence/mtime (`$HOME/.cache/tmux-lives`) before the suite's cache block and assert it is unchanged afterwards.

- [ ] **Step 2: Run to verify they fail** — the functions do not exist, so make sure each assertion fails LOUDLY (capture-first), not by aborting a statement silently. Paste the FAIL lines.

- [ ] **Step 3: Implement**

- `__tmux_lives_engine_key`: derive it from the sourced install file's own bytes, so it is automatic — no constant a future change must remember to bump. At load time the file already knows its own path; capture it once (`set -g __tmux_lives_install_src (status filename)` at the top of the file, near the other load-time setup) and have `__tmux_lives_engine_key` return `cksum < $__tmux_lives_install_src` reduced to its first field, memoized in a global so it costs one subprocess per process. If `status filename` is unavailable or the file unreadable, return a token that disables caching (see below) rather than a wrong key.
- Cache file: one per engine key + seed — `<cache dir>/<engine key>-<seed without '#'>.tsv`, lines `<recipe fields joined by spaces><TAB><7 hexes joined by spaces>`.
- `__tmux_lives_theme_render_cached`: validate the seed shape exactly as `__tmux_lives_theme_render` does (never pass a bad seed to the decoder); read the file once per process into parallel-array globals keyed by recipe (re-read only if the process has not loaded it); on a hit, print the 7 hexes; on a miss, call `__tmux_lives_theme_render`, append the line with `>>` (a single short write; tolerate a duplicate key by letting the LAST line win on read), and print. If the cache directory cannot be created or written, fall back to rendering every time — never fail a render because of the cache.
- Prune: when creating a cache file, delete files in the cache directory whose engine-key prefix differs from the current one. Do it with an explicit glob guarded by a non-empty key (this repo has shipped a glob-collapse bug before: an empty variable turning `*-*.tsv` into something far broader).
- Do NOT change `__tmux_lives_theme_render` itself.

- [ ] **Step 4: Verify**

Tests both modes; the three pinned digests from Task 1 unchanged; the isolation bracket green; full gate both modes.

- [ ] **Step 5: Commit** — `feat(theme): cache rendered palettes per engine version and seed`

---

### Task 3: use the cache where the picker builds lists

**Files:**
- Modify: `functions/tmux-categorize.fish` — the render call in `__tcz_thp_reload` (~`:2577`), the anchor-row render (~`:2798`), the roll renders (~`:2835`, ~`:3682`).
- Modify: `conf.d/tmux-lives-install.fish` — `setup theme list`'s render loop (~`:1724`) and the live-apply render (~`:1681`) if it is on an interactive path; leave the fragment render (~`:116`) alone unless it is trivially safe.
- Test: `tests/test-tmux-categorize.fish`.

- [ ] **Step 1: Write the failing test**

In the categorize suite, with the cache seam set to a temp dir: build the picker's reload path twice for the same seed and assert the second build performs no renders (shadow `__tmux_lives_theme_render` with a counter, as in Task 2). If `__tcz_thp_reload` is a nested function unreachable from the suite, assert instead that the source of the reload/roll/anchor call sites names `__tmux_lives_theme_render_cached` — bounded by an `awk` extraction of the enclosing function with a non-empty check, and paired with one end-to-end assertion through whatever entry point the suite can reach. Say in the report which shape you used and why.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — swap the named call sites to `__tmux_lives_theme_render_cached`. The picker sources `conf.d/tmux-lives-install.fish` before use (verify), so the function is available; if any call site can run without that source, leave it on the raw renderer and report it.

- [ ] **Step 4: Verify and measure**

- Tests both modes; full gate both modes.
- Measure the real win: with a temp cache dir, time a cold build of all 42 renders and then a warm one, and report both (cold ≈ Task 1's improved figure, warm should be tens of milliseconds).

- [ ] **Step 5: Commit** — `perf(picker): serve scheme lists from the render cache`

---

### Task 4: stop forking `seq` inside the gamut clamp

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_gamut_chroma` (~`:624`).
- Test: `tests/test-tmux-install.fish`.

**Why:** measured on rocket at HEAD 66bff56 — `__tmux_lives_gamut_chroma` runs **759 times per 42-scheme catalog render**, and its `for i in (seq 1 12)` forks an external `seq` each time at **0.88 ms**, i.e. **~668 ms of a 4,198 ms render (16%)** spent forking. Only 574 of the 759 calls are distinct, so memoizing the function is not worth its lookup cost; the fork is the free win.

**Hard constraint:** the loop must still run exactly 12 iterations with the same arithmetic in the same order. Do NOT change the iteration count, add an early-exit tolerance, or re-group the `math` expressions: this project's clamps are calibrated at the 8-bit quantisation floor, and a re-associated float or one fewer bisection step can move a rendered hex.

- [ ] **Step 1: Write the failing test** — a source-shape guard beside the engine tests: `__tmux_lives_gamut_chroma`'s body must contain no `seq` (extract the function body with the suite's established `awk '/^function __tmux_lives_gamut_chroma/,/^end$/'` idiom, assert the extraction is non-empty first, then assert zero `seq` hits). Also assert the body still contains a 12-iteration bound (grep for `12`), so a future edit cannot silently change the iteration count. Prove both FAIL/pass appropriately against the current code and paste the lines.
- [ ] **Step 2: Run to verify the `seq` guard fails.**
- [ ] **Step 3: Implement** — replace `for i in (seq 1 12)` with a counter loop, e.g. `set -l i 0; while test $i -lt 12; set i (math $i + 1); …; end`, leaving every line inside the loop byte-identical.
- [ ] **Step 4: Verify** — the three pinned render digests from Task 1 unchanged (that is the byte-identity proof); full gate both modes; re-measure the catalog render and report before/after on the same machine and load.
- [ ] **Step 5: Commit** — `perf(theme): drop the seq fork from the gamut clamp`
