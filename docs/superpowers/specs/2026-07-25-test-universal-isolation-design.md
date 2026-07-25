# Test harness — fish-universal isolation seam — design

Status: approved in brainstorm 2026-07-25. Closes the long-standing follow-up "tests need a fish-universal isolation seam (like `tmux_lives_tmux_socket`)" carried since the gallery-picker build. Test-harness only — no change to `conf.d/`, `functions/`, the theme engine, the CLI, or any shipped behavior.

## Why

tmux-lives persists its configuration in fish **universal variables** (`tmux_lives_theme`, `_theme_place`, `_theme_mode`, `_bar_color`, `_prefix_key`, …). Fish keeps every universal for the whole machine in ONE file: `~/.config/fish/fish_variables`.

The suite tests the real CLI, so a test that runs `__tmux_lives_theme_cmd ember --place cap --mode literal` genuinely executes `set -U` against that real file — the same file holding the user's live configuration. The tests compensate with hand-written save/restore blocks, and that bookkeeping has holes.

**The defect is not an accident of a killed test — a clean, fully-passing run destroys user configuration every time.** Concretely, in `tests/test-tmux-install.fish`:

- Line 863 sets `tmux_lives_theme_place` / `tmux_lives_theme_mode` through the real CLI; lines 894-895 erase them. **Neither name appears in the `_th_names` save list at line 780**, so the restore at 944-947 never puts them back. The later `_m_saved` guard at line 1122 tries to save them, but they were destroyed 230 lines earlier, so it records "absent" and line 1147 erases them one final time.
- Lines 146, 155, 163, 181 and 623 erase `tmux_lives_modal_key`, `_scratch_key`, `_resize_key`, `_status_pos_key`, `_status_vis_key`, `_theme_key` and `_prefix_key` with no save/restore at all.
- `tests/test-tmux-status.fish:10` erases `tmux_lives_prefix_key` and `tmux_lives_switcher_key` and the script ends two lines later.

This is confirmed live: the user's universals currently hold `tmux_lives_theme sage` with **no** `_theme_place` / `_theme_mode`, and **no** keybind universals at all. Their real theme is `sage/high/derived`; the erased placement is why the pending restore command exists. Restoring it is pointless until this is fixed, because the next suite run erases it again.

There is a second, sharper exposure. The widest guarded window spans lines 780-947 — 165 lines including a 10-palette perf loop and four subprocess spawns. Fish has no script-scope exit trap, so a Ctrl-C, a fatal error, or a command timeout anywhere inside leaves the user's universals in whatever half-written state the last assertion produced. That is exactly what happened on 2026-07-25 (a bash timeout killed the suite mid-run, stranding `tmux_lives_bar_color` at the test's hard-coded `#485b3c`), and the comment at lines 364-366 records an earlier instance from 2026-07-16.

Neither the existing `-L` socket seam nor the PATH shim can help: `set -U` writes to `fish_variables`, not to tmux, and `fish --no-config` deliberately does not persist universals at all, so it cannot be used as an isolation mechanism either.

## What was verified (fish 4.7.1, tmux 3.3a, this host)

| Question | Result |
| --- | --- |
| Does `XDG_CONFIG_HOME` redirect fish's universal store? | **Yes.** A `set -U` under a redirected `XDG_CONFIG_HOME` lands in `$XDG_CONFIG_HOME/fish/fish_variables`; the real file stayed byte-identical. |
| Can a running fish re-point its store mid-process? | **No.** Setting `XDG_CONFIG_HOME` after startup wrote to the real store anyway. The redirect must precede the test process. |
| Does `fish --no-config` still skip universals under the redirect? | **Yes.** The contract asserted at `test-tmux-install.fish:936-941` is unaffected. |
| Do nested `fish -c` children inherit the redirect? | **Yes** (exported), so CLI paths that `set -U` inside child shells are captured too. |
| Does the existing suite pass under the redirect? | **Yes — all 8 suites ALL PASS, unmodified** (install 464, 0 bytes stderr), with `~/.config/fish/fish_variables` byte-identical before and after (`4290006163 207596`). |
| Do the re-exec mechanics behave? | **Yes**, prototyped: body ran exactly once, `$argv` preserved, exit code propagated, a deliberate `set -U tmux_lives_*` landed in the temp store, temp dir removed. (The prototype used `mktemp -d -t …`; the spec below switches to the explicit-template form for BSD portability — see Open items.) |

The decisive consequence: **the isolation mechanism itself needs no change to any test body.** No assertion, stub, or seam has to move for the redirect to work — the suite is already green under it. The further changes in sections 2-5 are separately chosen scope, not requirements of the mechanism.

## The design

### 1. A self-re-exec guard at the top of every test file

Each of the 8 `tests/test-*.fish` files begins with a guard that, when the sentinel is absent, creates a throwaway config directory, points `XDG_CONFIG_HOME` at it, re-runs the same file under it, then removes the directory and propagates the exit code. The sentinel prevents recursion.

```fish
if not set -q TMUX_LIVES_TEST_UVARS
    set -l d (mktemp -d /tmp/tmux-lives-uv.XXXXXX)
    if test -z "$d"; or not test -d "$d"
        echo "FATAL: cannot create an isolated universal store; refusing to run" >&2
        exit 1
    end
    set -gx TMUX_LIVES_TEST_UVARS $d
    set -gx XDG_CONFIG_HOME $d
    fish (status filename) $argv
    set -l rc $status
    rm -rf $d
    exit $rc
end
```

Three properties matter and are load-bearing:

- **Fail closed.** If `mktemp` fails, the test aborts rather than running against the real store. An unprotected run must never be the fallback.
- **Guarded delete.** `rm -rf $d` runs only on a verified non-empty directory path.
- **Repeated, not shared.** The guard is duplicated in each file rather than sourced from a helper, so every test file remains self-contained and safe when run standalone — the invocation path that caused the 2026-07-25 incident — with no ordering or path-resolution dependency.

The guard is deliberately placed above everything, including each suite's `gcc`-availability check, so no code path can reach a `set -U` before isolation is active.

### 2. Suites must fail loudly

`tests/test-tmux-install.fish` (line 1179), `tests/test-tmux-status.fish` (line 12) and `tests/test-generic.fish` end on an `echo`, so they return 0 to the shell even when assertions fail. Each gains an explicit `exit` driven by its own failure counter, matching the five suites that already do this. Without it the guard's exit-code propagation is meaningless and an automated loop cannot distinguish green from red.

### 3. A test proving the isolation is live

A new assertion in `tests/test-tmux-install.fish` writes a probe universal and confirms the isolation actually took effect:

- `$TMUX_LIVES_TEST_UVARS` is set and equals `$XDG_CONFIG_HOME` (the guard ran).
- `$XDG_CONFIG_HOME` is not `$HOME/.config` (the store is genuinely elsewhere).
- After `set -U tmux_lives_isolation_probe …`, the value appears in `$XDG_CONFIG_HOME/fish/fish_variables` and does **not** appear in `$HOME/.config/fish/fish_variables` (read-only check of the real file).

If the guard ever regresses, this fails instead of silently eating configuration again.

### 4. A structural guard so new test files cannot skip it

`tests/test-generic.fish` already greps source for banned patterns. It gains a check that **every** `tests/test-*.fish` contains the `TMUX_LIVES_TEST_UVARS` sentinel. A test file added later without the guard fails the suite immediately.

### 5. Existing save/restore bookkeeping stays, with its hole closed

The roughly ten hand-written save/restore blocks in `test-tmux-install.fish` are **kept** as a redundant second layer. Removing about 80 lines of bookkeeping is real risk for no user-visible gain once the redirect is in place, and it would need its own careful review.

One correctness fix goes in: `tmux_lives_theme_place` and `tmux_lives_theme_mode` are added to the `_th_names` list at line 780, closing the specific hole that has been deleting the user's theme placement. This is belt-and-braces only — with the guard active, neither list can reach the real store.

Noted but deliberately not fixed: the `_m_saved` restore at line 1147 uses `string split '=' $kv`, which splits on every `=` and would truncate any saved value containing one. No current `tmux_lives_*` value contains `=`, and under the guard the blast radius is a temp file, so this stays a latent nit rather than scope.

## Side effect closed for free

`XDG_CONFIG_HOME` also repoints `$__fish_config_dir`, which makes two production guards short-circuit harmlessly during tests: `__tmux_lives_write_fragment`'s `test -f $cat; or return`, and `__tmux_lives_color_cmd`'s `fish --no-config $__fish_config_dir/functions/tmux-categorize.fish recolor`. The second one matters — the block at `test-tmux-install.fish:275-297` currently runs with the real config dir and fires OSC colour escapes at the user's attached ShellFish clients on every suite run. After this change it cannot. The later blocks that override `__fish_config_dir` by hand (lines 300, 334, 858) become redundant but stay, consistent with keeping the second layer.

## What changes in code

- `tests/test-tmux-install.fish` — guard; `exit` on failure count; `_th_names` gains `tmux_lives_theme_place` and `tmux_lives_theme_mode`; the new isolation-proof assertions.
- `tests/test-tmux-status.fish` — guard; `exit` on failure count.
- `tests/test-generic.fish` — guard; `exit` on failure; the new every-test-file-has-the-guard check.
- `tests/test-tmux-categorize.fish`, `test-tmux-popup.fish`, `test-tmux-auto.fish`, `test-tmux-restore.fish`, `test-tmux-shellfish.fish` — guard only.

Nothing outside `tests/` is touched.

## Testing

- **Full gate:** all 8 suites green under plain `fish` and under `fish --no-config`, with the install suite at its current count plus the new assertions, and 0 bytes of stderr from the categorize suite.
- **Isolation proof:** the assertions in section 3, plus an explicit before/after `cksum` of the real `fish_variables` across a whole-suite run showing it byte-identical.
- **Destructive probe:** confirm a deliberately hostile `set -U tmux_lives_bar_color` inside a test lands only in the temp store.
- **Standalone-run proof:** `fish tests/test-tmux-install.fish` on its own leaves the real store byte-identical — the specific path that failed on 2026-07-25.
- **Interrupt proof:** kill a suite mid-run (SIGTERM, mimicking the original incident) and confirm the real store is byte-identical afterwards. This is the assertion the old save/restore design could never satisfy.
- **Failure signalling:** deliberately break one assertion in each of the three amended suites and confirm a non-zero exit code.
- **Structural guard:** removing the guard from any test file fails `test-generic.fish`.

## Out of scope

The user's two pending actions (`tmux-lives setup theme sage --place high --mode derived`, then `fisher update`) happen after this lands, so the restore sticks. Also excluded: removing the redundant save/restore blocks, the `string split '=' $kv` nit, the picker cosmetic renames (`anch_*` to `cur*`), the dead `__tcz_popup_readkey` byte mappings, the orphaned `__tmux_lives_theme_schemes`, and the `Cscale` saturation tuning.

## Open items

- **macOS portability of the guard.** `mktemp -d <explicit template>` is the form that works on both GNU and BSD coreutils, and is used here for that reason; `-t` is avoided because BSD and GNU interpret it differently. Unverified on macOS — worth confirming during the pending Mac smoke, since the suite is expected to run there.
- **`TMPDIR` awareness.** The template hard-codes `/tmp`. If macOS or a sandbox needs `$TMPDIR`, the template becomes `$TMPDIR`-relative with a `/tmp` fallback. Decide at plan time.
- **Leftover temp directories.** The guard removes its directory on a normal exit; a SIGKILL leaks one. Given the repo already accumulates stale `-L` test sockets, a periodic sweep of `/tmp/tmux-lives-uv.*` may be worth adding later, but is not part of this change.
