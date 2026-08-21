# The theme picker paints 12,697 bytes to say 747

**Status: APPROVED, NOT BUILT** (2026-08-21). Resolves the open question parked in `docs/2026-08-17-theme-picker-latency-findings.md`, which is now answered and annotated rather than superseded — its measurements stand, one of its claims did not.

## The problem

Every keypress in the theme picker repaints the entire frame. At the user's real geometry — a 62-row iPad/ShellFish client, so a 52-row popup, expanded to all 35 schemes — that is **12,697 bytes to communicate a 747-byte change**, an amplification of **17×**. Two rows of fifty-two actually differ when the cursor moves one row.

Over a local link nobody notices. Over the iPad's wifi/cellular SSH link it is the entire per-keypress cost, and the picker stutters.

## How the root cause was established

The 2026-08-14 `feat/picker-responsiveness` cycle cut *construction* from 128-266 ms to ~30 ms by memoizing the pure row builders. It succeeded. The bottleneck moved to *emission*, which nobody had measured. The Aug-17 investigation measured emission and then parked, one control short of a conclusion, because bytes are not latency and this project's own standing rule is to get the A/B before blaming the environment.

That control has now been run, and a second one was added to close a confound the first left open.

| test | result |
|---|---|
| iPad → ShellFish → rocket (wifi/cellular) | **stutters**, badly, on a held down/up/down reversal |
| cmux → macwork (local, never leaves the machine) | smooth |
| **cmux → rocket (LAN)** — same host, same tmux 3.3a, same code | **smooth** |

The third row is the one that matters. The first two differ in host, tmux version, *and* transport; the third holds host, version, code and construction cost fixed and varies only the wire. Transport is the sole remaining variable.

Re-measured at `HEAD` on rocket via the suite's own `__t9_draw_nocc` harness, which `eval`s the real draw block rather than a reimplementation:

| | Aug 17 | **at `HEAD`, 2026-08-21** |
|---|---|---|
| warm frame construction (cursor move, cache hit) | 27-32 ms | **29.7 ms** |
| bytes emitted per frame | 14,485 | **12,697** |
| bytes that change moving one row | 821 | **747** (2 of 52 rows) |
| amplification | 17.6× | **17×** |

The finding reproduces; the small drop is layout drift since August. Construction at 29.7 ms is a ~34 fps ceiling and cannot produce the reported symptom, which is why the local cases are smooth.

### One claim from the Aug-17 doc does not hold, and it changes the emphasis

That doc states the synchronized-output wrapper means "no progressive paint", so a slow frame and an ignored keypress are indistinguishable. **Measured on rocket: tmux 3.3a drops app-sent `\e[?2026h`/`l` entirely** — it never reaches ShellFish. A bogus `\e[?9999h`/`l` control behaves identically, so this is simply tmux not forwarding private modes it does not implement; app-sent DECSET 2026 support landed after 3.6a.

So on the user's iPad path ShellFish is painting **progressively** as the 12.7 KB arrives. The symptom is pure throughput, which matches the user's word *stuttering*. The all-or-nothing feedback defect the Aug-17 doc describes is real but applies to tmux ≥ 3.7 — macwork, where `terminal-features xterm*:sync` deliberately turns sync on — not to rocket.

Two earlier probes of this question were void: the agent shell is zsh, it mangled the quoting, and the pane printed the escape sequences as literal text which a `grep` then matched. The measurement above uses a file-based emitter with no quoting layer, and a hexdump rather than a string match.

## What gets built

**Row diff with cursor addressing.** Construction is untouched: all 52 rows are built exactly as they are today. The frame is compared row-by-row against the previously painted frame, and only rows whose string differs are emitted, each addressed with `\e[<n>;1H`.

Nothing needs to know *why* a row changed. The thing compared is the thing emitted, which is what makes it correct by construction.

Two alternatives were considered and rejected. Tracking dirty rows at construction time (the row cache is already keyed `<index>_<selected>_<current>`, so it implicitly knows) is marginally cheaper but creates a second source of truth about what changed; when the two disagree the result is a stale screen and a green test suite, which is a failure mode this project has been bitten by repeatedly. Scroll regions (`\e[<t>;<b>r` plus index/reverse-index) would emit the fewest possible bytes for a cursor move, but the frame has fixed zones above and below the list, the seed zone changes height between modes, and it interacts badly with the popup border. It is a micro-optimization on top of the diff and can be added later if 747 bytes ever proves too many.

### Scope

Both of the picker's emit sites, through one shared helper: the main frame at `functions/tmux-categorize.fish:2953` and the hex-entry screen at `:2466`. Both repaint wholly per keystroke on the same link.

The session switcher's own emit at `:1487` is **out of scope**. Moving the cursor there changes the selected row *and* every row's right-hand pane, because that pane is a live `capture-pane` of a different session — so nearly every row genuinely differs and differential emission would buy close to nothing. This is reasoned, not measured; if the switcher ever needs the same treatment, measure it first.

### The emitter

One new function, `__tcz_popup_emit`, added to `functions/tmux-categorize.fish`. Zero new files, per this repo's one-file-per-feature convention. The name and the `__tcz_pe_*` prefix were both checked against the existing definitions before being chosen — fish redefines silently, and this project shipped exactly that collision once.

It takes the frame's rows as arguments and owns three globals: `__tcz_pe_prev` (the rows last painted), `__tcz_pe_force`, and `__tcz_pe_partial`.

It paints in full when `__tcz_pe_force` is set, or when the incoming row count differs from `__tcz_pe_prev`. That count check is the geometry guard: a frame of a different height can never be meaningfully diffed against the previous one, and a resized popup is the most likely way for the two to disagree. The full path is byte-for-byte the emission that exists today.

Otherwise it emits `\e[<n>;1H<row>\e[K` for each differing row, wrapped in the same `\e[?2026h`/`\e[?2026l`.

Three fish hazards it must dodge, each one previously live in this file:

- Row content reaches `printf` as a `%s` **argument**, never as part of the format string, so a literal `%` in a row cannot be interpreted.
- The joined escape sequence is guarded by a `count -gt 0` before being interpolated. A zero-element list collapses a `printf` argument rather than passing through as an empty string, which has silently deleted output here before.
- When no row differs it emits **nothing at all**. That is correct — the screen already shows the right thing — and it must not be "fixed" into emitting a no-op frame.

The sync wrapper stays on both paths. It is inert on tmux 3.3a, which drops it, and correct on 3.7b where the project's own `terminal-features xterm*:sync` fix turns synchronized output on; a 747-byte atomic commit is strictly better than a 747-byte torn one.

The cursor needs no parking. The picker hides it for its entire life (`\e[?25l` at `:2657`, restored at `:3324`), so where a partial paint leaves it is invisible.

### Forced repaint

Deliberately a short list: picker entry, and either side of the hex-entry screen, which paints its own frame through the same emitter. Plus the settle self-heal below.

Explicitly **not** on entering or leaving seed-edit mode. The row count stays 52 while the content shifts wholesale, so the diff emits nearly everything anyway; forcing would spend the full 12,697 where the diff may spend less. Explicitly **not** after `__tcz_thp_reload` either — every palette changed, so the diff emits what actually differs, which is the honest number.

### Self-heal when input settles

Differential emission is only correct while the model of the screen matches reality. A client resize (the iPad's on-screen keyboard appearing, or the device rotating), a redraw of the popup from underneath, or bytes dropped on a bad link all leave a stale mix that no later partial paint corrects, because every later frame only touches rows that changed since the stale one.

The picker already has a settle poll — a `stty min 0 time 7` read that fires ~0.7 s after the last keypress — but it arms only when a flash or a deferred seed batch is owed. It gains one clause so it also arms whenever a partial paint has happened since the last full one. On timeout it sets `__tcz_pe_force`, clears `__tcz_pe_partial`, and falls into the existing `continue`, which repaints in full.

Clearing `__tcz_pe_partial` is what terminates it: the next iteration has no flash, no batch and no partial paint outstanding, so it drops to a normal blocking read. **One heal per scroll burst.**

The existing gate's two conditions must both survive intact. `flashfield` and `seeddirty` are deliberately independent — three sibling key arms clear `flashfield` on unrelated keypresses, and coupling them once silently cancelled a pending seed batch. The new clause is a third independent condition, not a replacement for either.

## Testing

The existing frame proof (`__t9_frame_rows`) asserts row **count** and is structurally blind to whether emission matches construction. It stays as it is — it is still the guard for row count — and gains a companion.

**Two** new assertions, because neither is sufficient alone:

**Equivalence.** A pure screen model: start from frame 1's rows, apply frame 2's *emitted bytes* by parsing the `\e[<n>;1H` addresses, and assert the resulting screen equals frame 2 rendered in full. This is the property that actually matters — a partial paint must produce the same screen as a full repaint.

**Byte reduction.** Assert that a one-row cursor move emits **under 2,000 bytes**, against a measured full frame of 12,697 and a measured change of 747. The threshold is deliberately loose rather than pinned at 747: it must not go red because a future layout change alters a row's width, but it is nowhere near loose enough to pass a full repaint. This is what proves the optimization exists at all.

They discriminate different mutations, which is the whole point. An emitter that drops a changed row passes the byte test and **fails** equivalence. An emitter that always paints in full passes equivalence and **fails** the byte test. Both must be shown to fail against the pre-fix code before either is trusted, per this project's standing assertion rule; a single blanket assertion catching both mutations would look equally green and be far weaker.

The new proof has its own blind spot and it should be stated rather than discovered: it sees bytes and row addresses, not whether a row's *content* is correct. That remains `__t9_frame_text`'s job. A proof that counts one dimension cannot see another — this file has learned that twice.

## Explicitly not doing

- The session switcher's emit at `:1487`, for the reason above.
- Scroll-region optimization.
- Anything to construction, the row cache, `__tcz_thp_reload`, the arrow drain, or the 700 ms seed batch.
- Anything about the separate, still-unexplained large-repaint flicker recorded in the cursor-flicker findings. Do not fold it into this.

## Risks, for the live smoke

The self-heal is a full 12,697-byte repaint of **identical** content, and with no working sync wrapper on tmux 3.3a it may show as a visible sweep about a second after scrolling stops. If it does, the fix is to skip the heal when the frame is byte-identical to `__tcz_pe_prev`. That is deliberately not built up front — better to see whether it is real than design against a hypothetical.

The reversal case is the one to test, because it is the most sensitive probe available. The arrow drain is discard-based, one step per frame, and direction-blind: when frames are wire-bound the write blocks, autorepeat queues in the tty buffer, and the drain swallows the whole burst including the direction change. Hold-down is merely slow; **down → up → down is what makes it look broken**. If that is smooth on the iPad, this worked.
