# Status Bar Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tmux-lives status bar with a `status-format[0]` design — ends-only powerline caps (host far-left, clock far-right), flat middle with the window list on the left and the session/Claude identity dead-center, plus prefix and `M-r` resize mode indicators — preserving the ShellFish color, the self-heal tick, continuum autosave, and the position/visibility toggles.

**Architecture:** A pure fish builder returns the full `status-format[0]` string (all tunable values referenced as tmux `@options`). `__tmux_lives_render_fragment` emits it after sourcing the baseline, sets the `window-status-*` options it depends on, and seeds the `@option` defaults (glyphs, accent/cap colors from the ShellFish-derived color, host-kind). The right zone renders `status-right` (`#{T;=/#{status-right-length}:status-right}`), so the invisible `#(tick)` and continuum autosave survive untouched. The categorizer writes a per-session `@tmux_lives_claude` option so the pure format can show `✦ <name>` without process inspection.

**Tech Stack:** fish; tmux 3.3a `status-format[0]` with `#[align]` zones, `#{W:…}` window iteration, `#{?…}` conditionals; the existing `-L`-socket + stub test harnesses.

## Global Constraints

- **fish shell**; target **tmux 3.3a**; no new external dependencies.
- **Preserve the plumbing:** the right zone MUST render `status-right` via `#{T;=/#{status-right-length}:status-right}` so `#(… tick …)` (ShellFish self-heal / retitle / bar-color re-emit) and continuum's prepended autosave keep running. `status-style` (ShellFish color) is unchanged. `C-M-a`/`C-M-s` position/visibility toggles keep working.
- **Verified tmux idioms (use verbatim; sandbox-tested):**
  - Window list (names-only, current bold, no trailing separator): `#{W:#{T:window-status-format}#{?window_end_flag,,#{window-status-separator}},#{T:window-status-current-format}#{?window_end_flag,,#{window-status-separator}}}` with `window-status-format='#W'`, `window-status-current-format='#[bold]#W#[nobold]'`, `window-status-separator=' • '`. (`#{W:other,current}` — arg1 is non-current, arg2 current; the option value must be template-expanded with `#{T:…}`, not `#{…}`.)
  - Identity: `#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}#{?#{!=:#{@tmux_lives_claude},}, ✦ #{@tmux_lives_claude},}`
  - Prefix: `#{?client_prefix,…,…}` · Resize: `#{?#{==:#{client_key_table},tmuxlives-resize},…,…}` (both client-scoped).
  - Host glyph: `#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}`.
- **Separator roles:** `✦` = Claude mark, `•` = between windows, `·` = between fields. Fixed (not configurable).
- **Config = live-tunable `@options`** (`@tmux_lives_prefix_color`, `@tmux_lives_resize_color`, `@tmux_lives_cap_bg`, `@tmux_lives_cap_fg`, `@tmux_lives_glyph_remote`, `@tmux_lives_glyph_local`, `@tmux_lives_host_kind`, existing `@tmux_lives_status_right`); the format references them by name so `tmux set -g @… …` retunes with no re-render. Defaults seeded by the fragment.
- **Glyph codepoints** (generate via 8-digit `printf '\U…'`, never paste literal PUA): powerline right-slant U+E0B0 = `\U0000e0b0`, left-slant U+E0B2 = `\U0000e0b2`; `cod-remote` U+EB3A = `\U0000eb3a`; `cod-vm` U+EA7A = `\U0000ea7a`. BMP glyphs are safe as literals: `✦`(U+2726) `•`(U+2022) `·`(U+00B7) `◇`(U+25C7) `❯`(U+276F).
- **No live-server mutation in tests** (isolation invariant): pure builders + `tmux_lives_*` seams + private `-L` sockets only. Run the suite with `for t in tests/test-*.fish; fish $t; end` — all 8 end `ALL PASS`.
- **Do NOT deploy.** Edit → test → commit. The user runs `fisher update`.
- **Commit trailer:** end every commit with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- **`functions/tmux-categorize.fish`** — new pure `__tcz_status_format` (returns the format string; lives with the other `__tmux_lives_*`/`__tcz_*` helpers), new pure `__tcz_host_kind` (env/universal → remote|local), and the categorizer writes `@tmux_lives_claude` per session (extend the existing categorize/snapshot pass).
- **`conf.d/tmux-lives-install.fish`** — `__tmux_lives_render_fragment` emits the `window-status-*` options, the `@option` defaults (glyphs, cap/accent colors derived from the ShellFish color, host-kind), and `set -g status-format[0] "<builder output>"` after sourcing the baseline; `__tmux_lives_baseline_template` drops the `status-left`/`window-status-*` lines.
- **Tests:** `tests/test-tmux-categorize.fish` (builder, host-kind, `@tmux_lives_claude`), `tests/test-tmux-install.fish` (fragment contains the new lines + still contains tick/continuum/status-style; rendered fragment parses on a `-L` socket).

---

## Task 1: pure `__tcz_status_format` builder

**Files:**
- Modify: `functions/tmux-categorize.fish` (add the function near the other `__tmux_lives_*` helpers)
- Test: `tests/test-tmux-categorize.fish` (new block)

**Interfaces:**
- Consumes: nothing.
- Produces: `__tcz_status_format` — takes no arguments, echoes the complete `status-format[0]` string. All tunable values are referenced as `@options` (not baked). The string has three `#[align=…]` zones; the right zone renders `status-right`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish` (after the session_title block):

```fish
# ---------------------------------------------------------------------
# __tcz_status_format — pure status-format[0] builder
# ---------------------------------------------------------------------
set -g SF (__tcz_status_format)
t "sf has all three align zones" yes (string match -q '*#[align=left]*' -- "$SF"; and string match -q '*#[align=centre]*' -- "$SF"; and string match -q '*#[align=right]*' -- "$SF"; and echo yes; or echo no)
t "sf right zone renders status-right (tick/continuum preserved)" yes (string match -q '*#{T;=/#{status-right-length}:status-right}*' -- "$SF"; and echo yes; or echo no)
t "sf window list is names-only, no trailing sep" yes (string match -q '*#{W:*window_end_flag*window-status-separator*' -- "$SF"; and echo yes; or echo no)
t "sf window list template-expands the option" yes (string match -q '*#{T:window-status-format}*' -- "$SF"; and echo yes; or echo no)
t "sf identity honors @tmux_lives_name then session_name" yes (string match -q '*#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}*' -- "$SF"; and echo yes; or echo no)
t "sf identity shows claude name with diamond mark" yes (string match -q '*#{?#{!=:#{@tmux_lives_claude},}, ✦ #{@tmux_lives_claude},}*' -- "$SF"; and echo yes; or echo no)
t "sf host cap picks glyph by host_kind" yes (string match -q '*#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}*' -- "$SF"; and echo yes; or echo no)
t "sf host cap shows hostname" yes (string match -q '*#{host_short}*' -- "$SF"; and echo yes; or echo no)
t "sf prefix shows chevron via client_prefix" yes (string match -q '*#{?client_prefix,*❯*' -- "$SF"; and echo yes; or echo no)
t "sf resize badge via key-table" yes (string match -q '*#{?#{==:#{client_key_table},tmuxlives-resize},*◇ RESIZE ◇*' -- "$SF"; and echo yes; or echo no)
t "sf caps recolor on prefix/resize" yes (string match -q '*#{@tmux_lives_prefix_color}*' -- "$SF"; and string match -q '*#{@tmux_lives_resize_color}*' -- "$SF"; and string match -q '*#{@tmux_lives_cap_bg}*' -- "$SF"; and echo yes; or echo no)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the `sf …` assertions FAIL (`__tcz_status_format` unknown → empty `$SF`), file ends `SOME FAILED`.

- [ ] **Step 3: Write the implementation**

Add to `functions/tmux-categorize.fish`:

```fish
function __tcz_status_format --description 'pure: the status-format[0] string (all tunables are @options; right zone renders status-right so tick/continuum survive)'
    # PUA glyphs via codepoints (never paste literal PUA): powerline slants.
    set -l slantR (printf '\U0000e0b0')   # right-pointing, closes a left-anchored cap
    set -l slantL (printf '\U0000e0b2')   # left-pointing, opens a right-anchored cap
    # The cap background follows the mode: prefix -> prefix color, resize -> resize color, else the base cap bg.
    set -l capbg '#{?client_prefix,#{@tmux_lives_prefix_color},#{?#{==:#{client_key_table},tmuxlives-resize},#{@tmux_lives_resize_color},#{@tmux_lives_cap_bg}}}'
    set -l glyph '#{?#{==:#{@tmux_lives_host_kind},remote},#{@tmux_lives_glyph_remote},#{@tmux_lives_glyph_local}}'
    set -l win '#{W:#{T:window-status-format}#{?window_end_flag,,#{window-status-separator}},#{T:window-status-current-format}#{?window_end_flag,,#{window-status-separator}}}'
    set -l id '#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}#{?#{!=:#{@tmux_lives_claude},}, ✦ #{@tmux_lives_claude},}'
    # host cap (far left): styled segment + slant into the bar, then the window list (flat)
    set -l hostcap "#[fg=#{@tmux_lives_cap_fg},bg=$capbg] $glyph #{host_short} #[fg=$capbg,bg=default,none]$slantR#[default]"
    # centre: prefix chevron, else resize badge, else identity
    set -l centre "#{?client_prefix,❯ ,}#{?#{==:#{client_key_table},tmuxlives-resize},◇ RESIZE ◇  #[fg=#{@tmux_lives_cap_fg}]arrows move · x kill · esc/enter done,$id}"
    # clock cap (far right): slant opening the cap, then status-right (tick + continuum live here)
    set -l clockcap "#[fg=$capbg,bg=default]$slantL#[fg=#{@tmux_lives_cap_fg},bg=$capbg] #{T;=/#{status-right-length}:status-right} #[default]"
    echo "#[align=left]$hostcap $win#[align=centre]$centre#[align=right]$clockcap"
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fish tests/test-tmux-categorize.fish`
Expected: all `sf …` lines `ok`; file ends `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(bar): pure __tcz_status_format builder (align-zone status-format[0])

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: per-session `@tmux_lives_claude` (so the pure format can show `✦ <name>`)

**Files:**
- Modify: `functions/tmux-categorize.fish` (in the categorize pass that already iterates sessions)
- Test: `tests/test-tmux-categorize.fish` (new block, tmux-stub style)

**Interfaces:**
- Consumes: nothing new.
- Produces: `__tcz_set_claude_opt <session>` — sets tmux option `@tmux_lives_claude` on `<session>` to the session's Claude `--name` (empty string when the session runs no Claude). Called from the categorize pass for each session. Uses the bare session name for `set-option` (the `=`-target quirk — see [[tmux-target-quirks]]).

- [ ] **Step 1: Write the failing test**

Add to `tests/test-tmux-categorize.fish` (tmux-stub block; the stub records `set-option` calls):

```fish
# --- @tmux_lives_claude population (drives the ✦ name in the bar) ---
set -g CLAUDE_SET ''
function tmux
    switch "$argv[1]"
        case set-option
            set -g CLAUDE_SET "$argv"   # capture the last set-option
        case list-panes
            printf '%s\n' $tcz_claude_panes
    end
end
set -g tcz_claude_panes (printf 'claude\t4242')
functions -q __tcz_cmdline_name; or function __tcz_cmdline_name; echo opus; end
__tcz_set_claude_opt sA
t "set_claude_opt writes @tmux_lives_claude with the name" yes (string match -q '*set-option*sA*@tmux_lives_claude*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
set -g tcz_claude_panes (printf 'fish\t4242')
set -g CLAUDE_SET ''
__tcz_set_claude_opt sA
t "set_claude_opt clears @tmux_lives_claude for non-claude" yes (string match -q '*@tmux_lives_claude*' -- "$CLAUDE_SET"; and not string match -q '*opus*' -- "$CLAUDE_SET"; and echo yes; or echo no)
functions -e tmux; set -e tcz_claude_panes; set -e CLAUDE_SET
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_set_claude_opt` unknown. `SOME FAILED`.

- [ ] **Step 3: Implement**

Add to `functions/tmux-categorize.fish` (reuse the existing per-pane claude detection: `list-panes -s -t "=$session"` with `#{pane_current_command}\t#{pane_pid}`, and `__tcz_cmdline_name` for the `--name`):

```fish
function __tcz_set_claude_opt --argument-names session --description 'set @tmux_lives_claude on <session> = its claude --name (empty if no claude pane). BARE name for set-option (=target quirk).'
    test -n "$session"; or return
    set -l TAB (printf '\t')
    set -l name ''
    for line in (tmux list-panes -s -t "=$session" -F "#{pane_current_command}$TAB#{pane_pid}" 2>/dev/null)
        set -l parts (string split $TAB -- $line)
        test "$parts[1]" = claude; or continue
        set name (__tcz_cmdline_name $parts[2])
        test -n "$name"; and break
    end
    tmux set-option -t "$session" @tmux_lives_claude "$name" 2>/dev/null
end
```

Then, in the categorize pass that already loops sessions (search for the loop that calls `__tcz_categorize`/`__tcz_snapshot` per session — the `tick`/`categorize` verb path), add a call `__tcz_set_claude_opt $session` for each session so the option stays current on the ~15s tick and on categorize. (Wire it where the loop already has `$session` in scope; do not add a new loop.)

- [ ] **Step 4: Run to verify it passes**

Run: `fish tests/test-tmux-categorize.fish`
Expected: both `set_claude_opt …` lines `ok`; `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(bar): categorizer sets @tmux_lives_claude per session for the identity mark

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: pure `__tcz_host_kind` (remote vs local)

**Files:**
- Modify: `functions/tmux-categorize.fish`
- Test: `tests/test-tmux-categorize.fish` (new block)

**Interfaces:**
- Consumes: nothing.
- Produces: `__tcz_host_kind` — echoes `remote` or `local`. Precedence: the universal `tmux_lives_host_kind` if set (explicit override); else `remote` when `$SSH_CONNECTION` or `$SSH_TTY` is non-empty; else `local`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-categorize.fish`:

```fish
# --- host-kind detection (seeds @tmux_lives_host_kind -> which glyph) ---
set -e tmux_lives_host_kind
set -lx SSH_CONNECTION '10.0.0.5 40000 10.0.0.1 22'; set -e SSH_TTY
t "host_kind remote when SSH_CONNECTION set" remote (__tcz_host_kind)
set -e SSH_CONNECTION
t "host_kind local with no ssh env" local (__tcz_host_kind)
set -gx tmux_lives_host_kind remote   # explicit override wins even locally
t "host_kind override wins" remote (__tcz_host_kind)
set -e tmux_lives_host_kind
```

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-categorize.fish`
Expected: FAIL — `__tcz_host_kind` unknown. `SOME FAILED`.

- [ ] **Step 3: Implement**

Add to `functions/tmux-categorize.fish`:

```fish
function __tcz_host_kind --description 'remote|local: universal tmux_lives_host_kind override, else SSH env, else local'
    if set -q tmux_lives_host_kind; and test -n "$tmux_lives_host_kind"
        echo $tmux_lives_host_kind; return
    end
    if test -n "$SSH_CONNECTION"; or test -n "$SSH_TTY"
        echo remote; return
    end
    echo local
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `fish tests/test-tmux-categorize.fish`
Expected: the three `host_kind …` lines `ok`; `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish
git commit -m "feat(bar): __tcz_host_kind (SSH-env auto-detect + universal override)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: fragment + baseline integration

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` — `__tmux_lives_render_fragment` (emit window-status options, @option defaults, `status-format[0]`); `__tmux_lives_baseline_template` (drop the status-left/window lines)
- Test: `tests/test-tmux-install.fish`

**Interfaces:**
- Consumes: `__tcz_status_format` (Task 1), `__tcz_host_kind` (Task 3), the existing `__tmux_lives_derive_status`.
- Produces: a rendered fragment that sets the new bar and still carries the tick/continuum/status-style.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-tmux-install.fish` (near the existing fragment-render assertions; `$FRAG` is the rendered fragment string built the same way the file already builds it for other tests):

```fish
# --- status-bar overhaul: fragment carries the new bar + keeps the plumbing ---
set -g BAR (__tmux_lives_render_fragment /tmp/cat.fish | string collect)
t "fragment sets status-format[0]" yes (string match -q '*set -g status-format\[0\]*' -- "$BAR"; and echo yes; or echo no)
t "fragment still sets status-right with the tick" yes (string match -q '*set -g status-right*tick*' -- "$BAR"; and echo yes; or echo no)
t "fragment sets window-status-format names-only" yes (string match -q "*set -g window-status-format '#W'*" -- "$BAR"; and echo yes; or echo no)
t "fragment sets window-status-separator bullet" yes (string match -q '*window-status-separator*•*' -- "$BAR"; and echo yes; or echo no)
t "fragment seeds host-kind + glyph + accent @options" yes (string match -q '*@tmux_lives_host_kind*' -- "$BAR"; and string match -q '*@tmux_lives_glyph_remote*' -- "$BAR"; and string match -q '*@tmux_lives_prefix_color*' -- "$BAR"; and echo yes; or echo no)
t "fragment still sets status-style (shellfish color)" yes (string match -q '*set -g status-style*' -- "$BAR"; and echo yes; or echo no)
# rendered fragment must PARSE on a private -L socket (source-file rc0)
set -g sfsock tli-bar-$fish_pid
command tmux -L $sfsock new-session -d 2>/dev/null
printf '%s\n' $BAR > /tmp/tli-barfrag-$fish_pid.conf
t "bar fragment parses (source-file rc0)" 0 (command tmux -L $sfsock source-file /tmp/tli-barfrag-$fish_pid.conf 2>/dev/null; echo $status)
command tmux -L $sfsock kill-server 2>/dev/null; rm -f /tmp/tli-barfrag-$fish_pid.conf
# baseline no longer owns the layout
set -g BT (__tmux_lives_baseline_template | string collect)
t "baseline no longer sets status-left" yes (string match -q '*set -g status-left *' -- "$BT"; and echo no; or echo yes)
t "baseline no longer sets window-status-format" yes (string match -q '*window-status-format*' -- "$BT"; and echo no; or echo yes)
t "baseline still sets the clock @var" yes (string match -q '*@tmux_lives_status_right*' -- "$BT"; and echo yes; or echo no)
```

(If the file already stubs `_tmux_lives_post_update`/`__tmux_lives_write_fragment` for isolation, keep those stubs; this task only reads the rendered string + parses it on a private socket.)

- [ ] **Step 2: Run to verify it fails**

Run: `fish tests/test-tmux-install.fish`
Expected: the new `fragment …`/`baseline …` assertions FAIL. `SOME FAILED`.

- [ ] **Step 3: Implement — fragment**

In `__tmux_lives_render_fragment` (`conf.d/tmux-lives-install.fish`), after the existing `status-right`/`status-style` lines (around line 58-60) and before the persisted position/visibility source, add the window-status options, the `@option` defaults, and the `status-format[0]`. Derive the cap/accent colors from the ShellFish color (reuse `__tmux_lives_derive_status`'s bg as the cap bg; pick readable defaults). Use `$cat` (the categorizer path already in scope) to call the builder/host-kind at render time:

```fish
    # --- status bar overhaul: names-only window list, @option-driven caps ---
    set -a f "set -g window-status-format '#W'"
    set -a f "set -g window-status-current-format '#[bold]#W#[nobold]'"
    set -a f "set -g window-status-separator ' • '"
    # cap/accent colors: cap bg from the ShellFish-derived bar bg; accents a fixed amber family.
    set -l capbg (__tmux_lives_derive_status_bg $color $invert)   # helper: just the bg hex, or a default
    test -n "$capbg"; or set capbg colour238
    set -a f "set -g @tmux_lives_cap_bg $capbg"
    set -a f "set -g @tmux_lives_cap_fg colour231"
    set -a f "set -g @tmux_lives_prefix_color colour214"
    set -a f "set -g @tmux_lives_resize_color colour208"
    set -a f "set -g @tmux_lives_glyph_remote '"(printf '\U0000eb3a')"'"   # cod-remote
    set -a f "set -g @tmux_lives_glyph_local '"(printf '\U0000ea7a')"'"    # cod-vm
    set -a f "set -g @tmux_lives_host_kind "(fish --no-config $cat host-kind)
    set -a f "set -g @tmux_lives_claude ''"
    set -a f "set -g status-format[0] \""(fish --no-config $cat status-format)"\""
```

Add two thin verbs to the categorizer dispatch (`__tcz_main` in `functions/tmux-categorize.fish`) so the fragment can call them at render time without sourcing the whole file inline: `host-kind` → `__tcz_host_kind`, `status-format` → `__tcz_status_format`. (Follow the existing verb-dispatch pattern; these two just echo the pure functions' output.)

Add the tiny bg-extractor helper next to `__tmux_lives_derive_status` in `conf.d/tmux-lives-install.fish`:

```fish
function __tmux_lives_derive_status_bg --description 'css color + invert -> just the bg hex of the derived status-style (empty if unparseable)'
    set -l ss (__tmux_lives_derive_status $argv[1] $argv[2])
    test -n "$ss"; or return 0
    string replace -rf '.*bg=([^,]+).*' '$1' -- $ss
end
```

- [ ] **Step 4: Implement — baseline**

In `__tmux_lives_baseline_template` (`conf.d/tmux-lives-install.fish`, ~line 481-497), DELETE the `set -g status-left …`, `set -g status-left-length …`, `set -g window-status-format …`, `set -g window-status-current-format …`, and `set -g window-status-current-style …` lines (the fragment now owns layout). KEEP `set -g @tmux_lives_status_right …` (the clock var), `status-right-length`, and any non-layout user prefs. Add a short comment noting layout is now owned by the fragment's `status-format[0]`.

- [ ] **Step 5: Run the install suite**

Run: `fish tests/test-tmux-install.fish`
Expected: all new `fragment …`/`baseline …`/`bar fragment parses` lines `ok`; `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: every suite ends `ALL PASS` (8 suites).

- [ ] **Step 7: Commit**

```bash
git add functions/tmux-categorize.fish conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat(bar): render the new status-format[0] bar; baseline yields layout to the fragment

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual smoke (runtime-only — after the user's `fisher update`)

Not automatable (needs an attached client + Nerd Font). The user validates:
- Centered identity `session ✦ opus`; host cap shows `‹glyph› rocket` with `cod-remote` on rocket / `cod-vm` on the Mac; window list names-only `main • logs • test`, current bold; clock cap right with the 12h date.
- Prefix press → caps glow (amber) + `❯` center. `M-r` → amber caps + persistent `◇ RESIZE ◇` with the key hint, clearing the instant you exit.
- ShellFish bar color still self-heals (~15s tick), continuum still autosaves, `C-M-a`/`C-M-s` still toggle position/visibility.
- Live-tune: `tmux set -g @tmux_lives_prefix_color colour45` retints the prefix state with no re-render.

---

## Self-Review

**Spec coverage:** centered identity + `✦`/`•`/`·` roles → Task 1 (+ Task 2 for the claude name); ends-only powerline caps + ShellFish color → Task 1 builder + Task 4 cap-bg derivation; host cap + remote/local glyph → Task 1 + Task 3 + Task 4 seeding; names-only windows → Task 1 + Task 4 options; clock cap preserving tick/continuum → Task 1 right zone (`status-right`) + Task 4 keeps `status-right`; prefix/resize indicators → Task 1 conditionals; live-tunable @options → Task 1 references + Task 4 defaults; ownership shift → Task 4 baseline edit; testing/isolation → pure + stub + `-L` parse throughout. ✓

**Placeholder scan:** every step has concrete code/commands + expected output; verified tmux idioms are inline verbatim.

**Type/name consistency:** `__tcz_status_format` (no args), `__tcz_host_kind` (→ remote|local), `__tcz_set_claude_opt <session>`, `__tmux_lives_derive_status_bg <css> <invert>`, categorizer verbs `host-kind`/`status-format`, and the `@option` names (`@tmux_lives_cap_bg`/`_cap_fg`/`_prefix_color`/`_resize_color`/`_glyph_remote`/`_glyph_local`/`_host_kind`/`_claude`) are used identically across tasks.
