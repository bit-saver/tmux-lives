# Theme surface — inert-knob removal, curated rebalance, and the More Schemes section — design

Status: approved in brainstorm 2026-08-06. Three coordinated changes to the theme surface, sequenced so the cross-cutting signature change lands before the UI work. The **derivation is untouched** — no colour any existing recipe produces changes, except where a stored inert universal is erased (which by definition changed nothing anyway).

## Why

Three unrelated complaints arrived together, and they share a surface.

**Four knobs lie.** `--vividness`, `--shape`, `--ease` and `--contrast` are accepted by the CLI, stored as universals, threaded through the fragment and displayed in the picker — and none of them affects the output. This was recorded as "accepted-but-inert" during v4 and never resolved. It is not a suspicion: swinging all four to their extremes (`vivid flat cubic darker` against `balanced arc linear auto`) produces **byte-identical palettes on all 35 catalog rows**. The user currently has `contrast darker` and `vividness vivid` stored on rocket, both doing nothing.

**The picker opens on a sample that under-represents the surface that dominates the screen.** The curated set is **8 bar / 2 tabs / 4 cap** against a catalog of 16 bar / 15 tabs / 4 cap. The ShellFish tab bar is, in the user's words, roughly ten times the size of the status bar; tabs placement is where a scheme reaches it, and it is 2 of the 14 rows they actually see on open. Cap gets 4 despite being 4 of 35 overall.

**Expanding the catalog reshuffles everything.** `m` swaps the row source from the 14 curated entries to all 35, and the full catalog is in *tier* order, so the curated rows are scattered through the result. The user: *"it completely rewrites the entire list of schemes. You have no idea which ones you've been seeing and which are new."* A fix landed 2026-07-29 to preserve the cursor **by name**, which keeps your place but does nothing for the list around it.

## Scope

In: the three parts below. Out, deliberately: the accents derivation redesign and the collapse it causes (see "Deferred" at the end), the stale README theming section, and the two parked picker cosmetics from the second-list build.

## Sequencing

Part 1 → Part 2 → Part 3, and the order is load-bearing. Part 1 changes `__tmux_lives_theme_palette` from 9 parameters to 5 and renumbers the fragment argv; doing it first means Part 3's picker work is written once, against the settled signature. The equivalent change during the v4 build rippled to four callers and left the suite red across three tasks, so Part 1 is its own task and does not share a commit with UI work.

## Part 1 — remove the inert knobs

`--vividness`, `--shape`, `--ease`, `--contrast` are deleted from every surface.

**Engine.** `__tmux_lives_theme_palette` goes from `seedHex relationship place mode phase vividness shape ease contrast` to `seedHex relationship place mode phase`. `__tmux_lives_theme_apply_live`'s explicit-values mode goes from exactly 8 args (`relationship place mode phase viv shape ease contrast`) to exactly 4 (`relationship place mode phase`). The no-arg form, which reads the universals, is unchanged.

**Fragment.** Argv 17–20 (`themeviv`, `themeshape`, `themeease`, `themecontrast`) are removed. **The sync argument shipped earlier on 2026-08-06 moves from 21 to 17**, and `__tmux_lives_render_fragment` drops from 21 positionals to 17. `__tmux_lives_write_fragment`'s call site loses the four `__tmux_lives_key` lookups.

**CLI.** The four flags become explicit errors, in the same shape `--rotate` already uses:

```
tmux-lives setup theme: --vividness was removed in v5.1 — it never affected the output
```

Silence was rejected: a flag that is accepted and ignored is exactly the state being cleaned up, and a script passing one should be told rather than quietly misled.

**Migration.** New `__tmux_lives_migrate_v51`, chained after `_v41` in `_tmux_lives_post_update`, erases `tmux_lives_theme_vividness`, `_shape`, `_ease`, `_contrast`. Idempotent, one notice line only when something was actually erased. No value is preserved because no value ever meant anything.

**Picker.** The `viv`/`shape`/`ease`/`contrast` locals and their `anch_*` counterparts go. Its two `__tmux_lives_theme_palette` calls become 5-arg, and its **three explicit-arg** `__tmux_lives_theme_apply_live` sites become 4-arg. The knobs were already hidden from the legend, so there is no visible change here.

**Call sites, counted rather than estimated.** `__tmux_lives_theme_palette` has **five**: `__tmux_lives_render_fragment`, `__tmux_lives_theme_apply_live`, `__tmux_lives_theme_list` (install side), plus the picker's reload and anchor calls. `__tmux_lives_theme_apply_live` has **three explicit-arg** call sites, all in the picker, and **four no-arg** sites (one in the picker's Esc revert, three install-side) which read the universals and are unaffected by this change.

**Docs.** `__tmux_lives_theme_cmd`'s description, the `setup` help row for `theme`, README, CLAUDE.md.

### Testing Part 1

The inertness is the premise, so pin it: a test that the *engine* produces identical output for every relationship × place × mode is what justifies deletion, and it must be written against the **pre-change** code where the arguments still exist. After the change, assert the new arity directly (calling with 9 args must not silently succeed as if the extra four were meaningful), assert the CLI errors on each of the four flags, and assert the migration erases all four and is idempotent on a second run.

## Part 2 — rebalance the curated 14

Still 14 rows, moving from 8 bar / 2 tabs / 4 cap to **5 bar / 7 tabs / 2 cap**, with all eight relationships represented at least once.

| tier | placement · mode | rows |
|---|---|---|
| `soft` / `glow` | bar | `mono soft`, `wheat soft`, `amber soft`, `sage glow`, `teal glow` |
| `slate` / `chip` | tabs | `mint chip`, `coral chip`, `wheat slate`, `amber slate`, `ember slate`, `sage chip`, `teal slate` |
| `deep` / `core` | cap | `amber deep`, `sage core` |

Relationship coverage: mono 1, wheat 2, mint 1, amber 3, ember 1, sage 3, teal 3, coral 1.

This is one `default` flag per catalog row — no engine change, no new function. It is a taste call and is expected to be adjusted by eye later; the value here is that the opening view stops under-representing tabs.

### Testing Part 2

Pin the composition **exactly**, not with a lower bound — a `>=` assertion passed against the pre-cut catalog during the 2026-07-28 weeding pass and hid a real composition change. Assert the count stays 14, the per-placement split is 5/7/2, and every one of the eight relationships appears at least once. Assert the *names* too: counts alone cannot see a swap.

## Part 3 — the More Schemes section

### Model

Collapsed, nothing changes: the same 14 rows in the same order. Expanding **appends** a labelled group instead of reshuffling.

```
  ▇▇▇▇▇▇▇▇▇▇▇▇▇▇ teal slate
  ── More Schemes ───────────────────────────
 ▐▇▇▇▇▇▇▇▇▇▇▇▇▇▇ mono glow
  ▇▇▇▇▇▇▇▇▇▇▇▇▇▇ wheat glow
```

The reload composes **curated-then-rest** rather than catalog order, so the first 14 never move. That is the actual fix for "you have no idea which ones you've been seeing" — cursor preservation was treating the symptom.

A new pure install-side helper `__tmux_lives_theme_catalog_rest` returns the non-default rows in catalog order, keeping `__tmux_lives_theme_catalog` the single source of truth. The picker composes `catalog_default` + `catalog_rest`.

### The header

A row inside the scrolling list, not a frame element. The `├─ label ─┤` zone-separator form was explicitly rejected by the user: a section border "would make it look far too separate" and break the single-list feel. The header is a floating rule that never touches either border.

Geometry, stated exactly so it cannot be guessed at: the row is `IW` visible columns like every other list row. Column 1 is blank (where a scheme row carries its `▐` selection marker — the header is never selectable, so it is always blank). Columns 2–3 are `──`, then a space, then the label bold in the `title` role, then a space, then `─` repeated to fill, stopping **one column short of `IW`** so a blank column separates the rule from the right border. A new pure builder `__tcz_thp_grouphdr <w> <label>` owns this, matching the existing `__tcz_thp_*` convention of a pure, independently testable row builder.

It is drawn only when expanded.

### Why no skip logic is needed

`sel` indexes **schemes only**. The header is a pure display insertion at a fixed virtual position, so `sel` can never land on it and `__tcz_thp_vismap` needs no header awareness at all. Moving down from the last curated row goes to the first row of the rest; moving up does the reverse. The user's "it just skips over it" requirement falls out of the data model rather than being implemented as a special case — which matters because a special case here would have to be duplicated in `↑↓`, PgUp/PgDn, `z` and the collapse clamp, and one of those would eventually be missed.

### Geometry

The popup stays **52×26**, and the draw must still emit exactly 26 rows in every state. The header occupies one of the 11 window slots while it is on screen, so you see 10 schemes plus the header there and 11 once scrolled past. Growing to 27 was rejected: it costs a row everywhere including on the phone, and re-pins geometry at all three open sites.

The scroll window is computed over **virtual** rows — `n + 1` when expanded, `n` when collapsed — and `__tcz_thp_window` is unchanged, since it already takes a total and a selection. The caller converts: a scheme index at or past the header's position maps to virtual index `+ 1`. The draw loop walks virtual indices and emits either the header or a scheme row.

### Collapse

`m` again returns to the 14. If the selection was below the header it clamps to the last curated row; if it was within the curated set it stays where it is. The existing name-based re-find is kept as the mechanism.

### Interactions

`z` shake picks a row by name and still resolves, since names are unchanged. PgUp/PgDn page by `WIN` over virtual rows. The `⇥` second list (`current` / `off`) is untouched — it has its own focus and cursor.

### Testing Part 3

The existing 26-row proof extracts the real draw block from the live file and evaluates it against real state; it gains states for collapsed, expanded with the header on screen, and expanded scrolled past the header. That harness was verified sensitive by injecting a deliberate extra row, and the same check applies here.

Beyond the frame count, assert the properties that would actually regress: the first 14 rows are identical collapsed and expanded (the whole point), the header appears only when expanded, and moving down from the last curated row selects the first row of the rest rather than anything else.

## Risks

**The signature change is less dangerous than it first appears, and the real hazard is elsewhere.** Verified: fish silently ignores arguments beyond `--argument-names`, so *shrinking* a signature by removing trailing parameters leaves every existing 9-arg call site working identically. The v4 build went red because that change **reordered and added** parameters; removing trailing ones is not the same operation. Call sites can therefore be cleaned up in a later task without an intervening broken state.

**The genuinely atomic change is the fragment argv renumber.** Removing positions 17–20 shifts `syncterm` from 21 to 17, and `__tmux_lives_render_fragment` and `__tmux_lives_write_fragment` must move in the same commit or the fragment silently renders with the sync feature disabled — a failure with no error, no rc, and no visible symptom until someone's cursor starts strobing again. That pairing is the one place where a half-applied change is dangerous.

**Assertions are the other risk.** The last two builds in this repo produced four separate waves of defective assertions — vacuous body-greps, one unsatisfiable, one self-contradictory pair, and one whose sample comment contained the substring its own guard counted. Every assertion in the plan must be shown **failing against the pre-change code** before it is trusted, and preference goes to asserting effects over grepping source. A grep-only guard on Part 1 would be especially weak, since the strings being removed appear in comments and docs as well.

## Deferred

**The accents redesign, and the collapse it causes.** Measured at both live seeds, across all 35 catalog rows, six of the seven roles take only **11 distinct values** (`bar`, `sep`, `tabs`, `active`, `windows`, `text`); only `cap` reaches 19. So 35 rows resolve to roughly 11 underlying looks, and rows that differ "by a hair" are ones where only the endcap moved. The cause is structural: `__tmux_lives_theme_accents` derives all four supporting roles from the bar and ignores its `capHex` argument entirely, so whenever the bar repeats they repeat with it. This is the user's "too samesey" observation as a number. It needs its own brainstorm and is not in this cycle.

The stale README theming section (it still documents `aurora`/`sunset`/`complement` and advertises `--rotate`, which now exits 1) and the two parked picker cosmetics from the second-list build also remain open.
