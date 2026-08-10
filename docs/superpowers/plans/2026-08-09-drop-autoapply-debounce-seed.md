# Drop auto-apply, debounce the seed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove auto-apply entirely, and make a seed channel keypress cost nothing but a redraw — regenerating the scheme strips only after a 700 ms pause.

**Why:** the user tried `d68deb0` live and reported it "wayyyy too much… everything is so lacking in responsivity." Three costs had stacked: auto-apply firing a 200-400 ms real-bar apply every time the cursor settled, a ~40 ms palette recompute on every channel keypress, and a frame that grew from 61 ms to 122 ms per redraw. Their instruction: cancel auto-apply, and "on the seed change just debounce the crap out of it — wait until the user stops on a color as if asking to see what it looks like, and then apply it to the schemes."

**Their two clarifications:** a channel keypress redraws the seed zone only, with **zero** palette work (scheme strips stay at the old seed until the pause); and the debounce is **700 ms** — past a mid-adjustment hesitation, short enough that a deliberate stop feels answered.

**Note "apply it to the schemes" means the picker's own scheme strips**, not the real bar. Nothing in this change makes the real bar move; only `a` and `⏎` still do. That is the standing principle: configuration is private, adoption touches the bar.

## Global Constraints

- **Gate: 8 suites `ALL PASS` under BOTH `fish` and `fish --no-config`.** FOREGROUND, **`timeout: 300000`** — the 16-run gate exceeds the 120s default and auto-backgrounds, which stalled four agents on this project:
  `bash -c 'for m in "" "--no-config"; do for t in tests/test-*.fish; do printf "%-32s " "$(basename $t)"; fish $m "$t" </dev/null | tail -1; done; done'`
- Baseline at `d68deb0`: 8/8 both modes, `test-tmux-install.fish` **635 / 634** (the 1-count delta is BY DESIGN, never "fix" it), `test-tmux-categorize.fish` **917**. This change REMOVES a feature, so the categorize count will fall — report the new figure and account for the drop.
- **Every assertion shown FAILING before implementing.** Removing a feature inverts the usual shape: assertions that its machinery is *absent* must fail while it is still present.
- **An undefined function used as a DIRECT argument in a `t` call aborts the whole statement** — nothing prints and the suite still says ALL PASS. Deleting things is how a suite goes silently vacuous. After every deletion, confirm no surviving assertion calls what you removed, and reconcile the `ok` count.
- **A proof that counts row *elements* cannot see display *columns*.** The 26-row frame proof missed a one-column overflow at `d68deb0` for exactly this reason. Any row you touch needs a width check too.
- Guards grep source text and match COMMENTS. Never spell a banned shape in a comment.
- fish: zero-output command substitution as a bare argument VANISHES; `string repeat -n 0` emits nothing; `eval` not `source` for extracted blocks.
- Do NOT deploy: never touch `~/.config/fish/`, `~/.tmux.conf`, `~/.config/tmux/tmux-lives.conf`.
- **No filesystem-wide scans** (`find /`) — CIFS mounts park them in uninterruptible I/O.
- Work in FULL-TREE copies for mutation experiments; a lone test file loses its `$plugindir` self-location and yields false readings.

---

### Task 1: Remove auto-apply

**Files:** `functions/tmux-categorize.fish`, `conf.d/tmux-lives-install.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-install.fish`

**Everything to remove, inventoried from the source:**

| what | where |
|---|---|
| `case 41; echo A` in the shared reader's outer switch | `functions/tmux-categorize.fish:930` |
| its paired convention guard (mapping resolves + switcher has no arm) | `tests/test-tmux-categorize.fish` |
| `case A` arm and the universal write | `:2623` region |
| `set -l autoapply 1` and the init 8th echo that reads the universal | `:1696`, `:1710`, `:1727` |
| `set -l applydue 0` and every arming site | `:2034`; arms in the movement arm, `case z`, `case m` |
| the settle branch's `applydue` condition and its apply call | `:2318`, `:2356-2379` |
| `A auto`, the browsing legend's tenth pair | the legend if/else |

**Then reverse the arithmetic the tenth pair paid for:**
- browsing legend **4 → 3** rows; editing legend pad **4 → 3**
- `STATIC_IDLE` **17 → 16**, `STATIC_EDIT` **22 → 21**
- the open-time floor therefore admits `rows ≥ 24` again (it gates on `STATIC_EDIT` — keep that; it is what stops a later `b` overflowing a popup that already opened)
- update the four literal assertions that pin those numbers, and re-run the three sensitivity mutations at 16/21

**Keep `__tcz_thp_apply_now`** (rename from `__tcz_thp_autoapply_now` — it is now only `case a`'s body). Extracting it removed a real duplication and its tests are behavioural; keep both, just rename. `case a` and its `__tcz_recolor` emit stay exactly as they are.

**Add a migration** erasing the now-retired `tmux_lives_theme_autoapply`, idempotently, chained after the existing `__tmux_lives_migrate_*` functions in `conf.d/tmux-lives-install.fish`. The user may have pressed `A` while testing, so an orphan is likely, and every retired universal in this project has been erased this way.

- [ ] **Step 1: Write the absence assertions and confirm they fail**
- [ ] **Step 2: Remove the machinery**
- [ ] **Step 3: Reverse the arithmetic; update the four pinned literals**
- [ ] **Step 4: Re-run the three frame sensitivity mutations at 16/21** — extra row (+1 every size both modes); wrong `STATIC_IDLE` (idle only); wrong `STATIC_EDIT` (editing only, plus the floor assertion)
- [ ] **Step 5: Add the migration; assert it is idempotent**
- [ ] **Step 6: Reconcile the assertion-count drop, run the gate, commit**

---

### Task 2: Debounce the seed, and document both changes

**Files:** `functions/tmux-categorize.fish`, `tests/test-tmux-categorize.fish`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Remove the per-keypress palette recompute**

The channel arm currently recomputes the cursor's own scheme immediately. Delete that. A keypress must cost a seed-zone redraw and nothing else — **zero palette calls.** The picker's palette call sites go **3 → 2**; three separate exact-count guards pin that number (they were bumped 2 → 3 when the live path was added) — return all three to 2.

Assert it behaviourally: drive the channel arm with a counter wrapped around `__tmux_lives_theme_palette` and assert **0** calls per keypress. That is the discriminator; a source-text grep is not.

- [ ] **Step 2: Move the settle poll from 500 ms to 700 ms**

`stty min 0 time 5` → `time 7`. One timer serves the flash, the seed batch and nothing else now. Pin the value — an existing guard counted occurrences rather than the value, which let `time 5` → `time 10` pass green.

- [ ] **Step 3: Confirm the batch still fires on settle and still reaches everything**

The `seeddirty` path must still run `__tcz_thp_reload` **and** `__tcz_thp_reanchor` once per settle — reload for the strips, reanchor so the `current` row's band tracks the new seed. Without reanchor that row keeps the old seed's palette for the rest of the session. Assert the `current` row's rendered band changes after a seed edit plus settle, matching a direct palette call for the new seed.

- [ ] **Step 4: Docs**

README: auto-apply and the `A` key are gone from the key list; a channel keypress moves only the slider; the schemes regenerate after a ~700 ms pause. Correct the legend row count and the visible-scheme figures that the removed pair changes. CLAUDE.md: one paragraph in house style — the user's live verdict, the three stacked costs, what was removed, and that `STATIC` returned to 16/21 because the tenth legend pair went with it.

- [ ] **Step 5: Run the gate and commit**
