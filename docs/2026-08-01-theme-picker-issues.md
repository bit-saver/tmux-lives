# Theme picker — open issues (queued, not started)

Reported by the user 2026-08-01 from live use of the gallery picker (`__tcz_theme_picker`, `functions/tmux-categorize.fish`). Diagnosed to code here so the eventual fix cycle starts from evidence rather than a restatement. **None of these are fixed.** They are queued behind the big-area scheme work (`docs/superpowers/plans/2026-08-01-theme-big-area-scheme.md`).

All three are picker/input concerns. The theme *engine* is not implicated in any of them.

---

## Issue 1 — Esc does not restore the original scheme + seed

**As reported:** "After applying a scheme, pressing ESC does not restore the original scheme + seed color if changed."

**Diagnosis.** The `cancel` arm does attempt a revert:

```fish
case cancel
    if test $previewed -eq 1
        fish -c __tmux_lives_theme_apply_live >/dev/null 2>&1
    end
    break
```

No-arg `__tmux_lives_theme_apply_live` re-reads the *persisted* universals and re-applies, so the relationship/place/mode side is restorable. **The seed is not.** The RGB slider screen commits it immediately, on apply, inside the picker:

```fish
fish -c 'tmux-lives setup color $argv[1]' (printf '#%02x%02x%02x' $r $g $b) >/dev/null 2>&1
```

`setup color` does `set -U tmux_lives_bar_color`, re-renders the fragment, and applies live. By the time Esc is pressed the original seed is gone — the picker never captured it, so there is nothing to restore *to*.

That also explains the scheme half of the report: every role derives from the seed, so even a correctly-restored relationship renders against the new seed and the bar does not return to what it looked like at open.

**Shape of the fix.** One root cause, two candidate remedies:

1. **Preview-only sliders** (preferred) — the seed screen applies live *without* persisting, exactly as `a` does for schemes; `⏎` is what commits it. Consistent with how every other knob in the picker already behaves, and makes Esc's existing revert sufficient.
2. **Capture and restore** — snapshot `tmux_lives_bar_color` into the anchor at open and re-issue `setup color <original>` on cancel. Simpler, but leaves a window where the universal and fragment have been rewritten and re-rewritten, which is churn the fragment reload makes expensive (and see the continuum interaction in `docs/2026-07-30-handoff-status-right-and-update-environment.md`).

Whichever is chosen, the anchor snapshot should carry the seed so the `current` row previews and saves against the seed it was captured with.

---

## Issue 2 — Held ↑↓ outruns the render, and overshoots on release

**As reported:** "The held up/down doesn't work properly. It ticks invisibly after a couple ticks are rendered so you can't see what you're currently scrolling. The held arrow should cause the selected scheme to move up/down at a rate that's within renderable tolerances. Releasing the arrow should stop EXACTLY where the current tick is visibly showing a selected scheme so that it moves no further."

**Diagnosis.** The drain-coalescing added 2026-07-29 (`cc10d93`) deliberately **sums** the whole burst and applies it as one net move:

```fish
set -l steps 0
switch $tok
    case up;   set steps -1
    case down; set steps 1
    ...
end
set -l gap 0
while true
    stty min 0 time $gap 2>/dev/null
    set -l k2 (__tcz_popup_readkey)
    switch "$k2"
        case up;   set steps (math "$steps - 1"); set gap 1
        ...
        case '*';  break
    end
end
```

Its own comment states the intent: *"a held key then scrolls FASTER (more rows per redraw) and stops dead on release."* That fixed the original defect — an unbounded redraw backlog that kept scrolling for seconds after release — but it traded it for this one. Because `steps` accumulates without bound, a held arrow jumps many rows per render cycle, so the intermediate positions are never drawn, and the position it lands on is the accumulated total rather than the last one the user actually saw.

**The requested behaviour is different from both.** Not "collapse the burst" and not "queue every press", but **rate-limit with discard**: move at most a small fixed number of rows per render cycle and *drop* the surplus presses, so the selection is always visibly rendered at its current position and release stops on the last rendered row.

**Shape of the fix.** Cap the applied movement per iteration (1 row, possibly 2 if a held key feels too slow) and discard the remainder instead of adding it to `steps`. The drain loop stays — it is what prevents the backlog — but it becomes "swallow the queued repeats" rather than "count them". PgUp/PgDn should keep moving by `WIN` per press, since those are discrete and not autorepeated in practice.

**Do not lose the drain-hang guard.** `stty min 0 time $gap` must be re-asserted *inside* the loop: `__tcz_popup_readkey`'s CSI branch leaves the tty blocking on return, and a drain read after it will hang. That hazard is documented and was hit for real once already.

---

## Issue 3 — The `off` row is pinned and always visible

**As reported:** "Keep the OFF scheme at the bottom of the list or somewhere less prominent. I don't need to be reminded of it while I'm scrolling the list."

**Diagnosis.** `off` *is* last in the linear selection order (`sel = n`), so ordering is not the problem — **visibility** is. It is drawn unconditionally, outside the windowed scheme list:

```fish
if test $count -gt 0
    for i in (seq $start (math $start + $count - 1))
        ...                      # the 10-row scroll window
    end
end
set -l offflag 0
test $sel -eq $n; and set offflag 1
set -l offrow (__tcz_thp_off_row "$legacy" $offflag)
...
set -a lines (__tcz_thp_ln "$offrow" $IW $BORDER $RST)
```

So it sits below the window permanently, on screen no matter where the list is scrolled. The picker's own docstring calls it "a pinned off row" — this is working as built, and the build was wrong for how it feels in use.

**Shape of the fix.** Two options, user to pick:

1. **Scroll it with the list** — treat `off` as row `n` inside the window so it only appears once scrolled to the bottom. Costs one row of scheme window unless the frame grows.
2. **Move it out of the list entirely** — reach it by a dedicated key the way `c` reaches the current zone, and drop the always-drawn row.

**Frame arithmetic is load-bearing here.** The popup is `-w 52 -h 26` and the draw must emit **exactly 26 rows in every state** — 16 static chrome/off/current/legend rows plus a fixed 10-row scheme window. Removing or relocating the off row changes that count and must be rebalanced, or the top border scrolls off (a defect this picker has already shipped once). The three open sites (`__tmux_lives_cap_picker`'s successor in `conf.d/tmux-lives-install.fish`, the `M-k` fragment bind, and `__tcz_modal_run`'s `k`) all pin the geometry and are asserted by tests.

---

## Sequencing note

Issues 2 and 3 both touch the picker's draw/dispatch loop and the 26-row frame budget; doing them together avoids rebalancing the frame twice. Issue 1 is independent and touches the seed-entry screens plus the anchor snapshot.
