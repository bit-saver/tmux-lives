# tmux-lives Unified Command + Configurable Switcher Keys — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse all user commands under one `tmux-lives <command>` dispatcher with a full help page, and make the switcher keybinds configurable + persisted via `tmux-lives setup`.

**Architecture:** Rename the existing standalone command functions to `__tmux_lives_*` helpers in place (behavior-preserving), then add a `tmux-lives` dispatcher that routes to them. `render_fragment` takes the two keys as args (pure); `setup` resolves/persists them via universal vars.

**Tech Stack:** fish 3.x+, tmux 3.3a+ (brace-block `if-shell`). Pure fish, no new files.

## Global Constraints

- **Zero net-new files** in `conf.d/` or `functions/`; tests stay in `tests/`. New helpers underscore-prefixed.
- **Standalone names removed** (`ts`, `tmuxauto`, `tmtake`, `fixssh`, `tmux-setup`, `tmux-teardown`, `tmux-status`) → only `tmux-lives <verb>`. No shipped aliases.
- **Key flag mapping:** `--prefix-key K` → `bind-key <K>` (prefix), default `S`. `--switcher-key K` → `bind-key -n <K>` (no-prefix), default `M-s`. Empty value disables a bind. Unset var → default; set-but-empty var → disabled.
- **Universal vars:** `tmux_lives_prefix_key`, `tmux_lives_switcher_key` (machine-managed by `setup`).
- **No internal-caller breakage:** autostart uses `__tmux_autostart`; fragment binds call the categorizer directly; commandeer hook calls the categorizer. None use the user command names.
- **Commits:** `feat:`/`refactor:`/`docs:` prefix; end every message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Direct-to-`main`; push after each commit.
- **Run all suites:** `for t in tests/test-*.fish; fish $t; end` (each prints its pass line).

---

### Task 1: Rename user commands → `__tmux_lives_*` helpers (behavior-preserving)

**Files:**
- Modify: `conf.d/tmux.fish` (rename 4 functions + self-calls + usage text)
- Modify: `conf.d/tmux-lives-install.fish` (rename 3 functions)
- Test: `tests/test-tmux-auto.fish` (update 3 call sites)

**Interfaces — Produces:** `__tmux_lives_switch [name]`, `__tmux_lives_auto <on|off|status|toggle>`, `__tmux_lives_take <session>`, `__tmux_lives_fixssh`, `__tmux_lives_setup`, `__tmux_lives_teardown`, `__tmux_lives_status` (bodies identical to today's `ts`/`tmuxauto`/`tmtake`/`fixssh`/`tmux-setup`/`tmux-teardown`/`tmux-status`).

- [ ] **Step 1: Rename in `conf.d/tmux.fish`** (function headers + internal references; bodies otherwise unchanged):
  - `function ts ...` → `function __tmux_lives_switch ...`. In its body, change the usage echo `"No sessions. Create one with: ts <name>"` → `"No sessions. Create one with: tmux-lives switch <name>"`.
  - `function tmuxauto ...` → `function __tmux_lives_auto ...`. In the `toggle` case, change the self-calls `tmuxauto on` / `tmuxauto off` → `__tmux_lives_auto on` / `__tmux_lives_auto off`. Change usage echo `"usage: tmuxauto on|off|status|toggle"` → `"usage: tmux-lives auto on|off|status|toggle"`.
  - `function fixssh ...` → `function __tmux_lives_fixssh ...`. Change usage echo `"fixssh: not inside tmux"` → `"tmux-lives fixssh: not inside tmux"`.
  - `function tmtake ...` → `function __tmux_lives_take ...` (keep `--argument-names session`).

- [ ] **Step 2: Rename in `conf.d/tmux-lives-install.fish`** (headers only; bodies unchanged):
  - `function tmux-setup ...` → `function __tmux_lives_setup ...`
  - `function tmux-teardown ...` → `function __tmux_lives_teardown ...`
  - `function tmux-status ...` → `function __tmux_lives_status ...`

- [ ] **Step 3: Update the 3 test call sites** in `tests/test-tmux-auto.fish`:
  - `tmuxauto off >/dev/null` → `__tmux_lives_auto off >/dev/null`
  - `tmuxauto on >/dev/null` → `__tmux_lives_auto on >/dev/null`
  - the bare `ts` (Component C block) → `__tmux_lives_switch`

- [ ] **Step 4: Run the full suite**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: every suite prints `ALL PASS` / `ALL PASS (N)`. (The help-content and install-message text tests in `test-tmux-install.fish` still reference old names as *text* — they pass; they're updated in Tasks 3–4.)

- [ ] **Step 5: Commit**

```bash
git add conf.d/tmux.fish conf.d/tmux-lives-install.fish tests/test-tmux-auto.fish
git commit -m "refactor: rename user commands to __tmux_lives_* helpers (no behavior change)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 2: Configurable switcher keys — `render_fragment` params + resolver

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment` signature/body; add `__tmux_lives_key`; update `__tmux_lives_setup`'s render call)
- Test: `tests/test-tmux-install.fish` (fragment-bind assertions + resolver)

**Interfaces:**
- Consumes: `__tmux_lives_setup` (Task 1).
- Produces: `__tmux_lives_render_fragment <cat> <prefix_key> <switcher_key>` (empty key ⇒ that bind omitted); `__tmux_lives_key <varname> <default>` (unset⇒default, set⇒value incl. empty).

- [ ] **Step 1: Write failing tests** — append to the fragment-test block in `tests/test-tmux-install.fish` (after the existing `set -l frag ...` line, which must change to pass keys). First change the render line near the top from `set -l frag (__tmux_lives_render_fragment /X/cat.fish | string collect)` to:

```fish
set -l frag (__tmux_lives_render_fragment /X/cat.fish S M-s | string collect)
```

Then append these assertions after the existing fragment assertions:

```fish
t "fragment binds prefix S"        1 (string match -q '*bind-key S display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment binds no-prefix M-s"   1 (string match -q '*bind-key -n M-s display-popup*' -- "$frag"; and echo 1; or echo 0)
t "fragment menu fallback both"    1 (string match -q '*bind-key -n M-s run-shell*' -- "$frag"; and echo 1; or echo 0)
set -l fragc (__tmux_lives_render_fragment /X/cat.fish C-a C-s | string collect)
t "fragment custom prefix key"     1 (string match -q '*bind-key C-a display-popup*' -- "$fragc"; and echo 1; or echo 0)
t "fragment custom switcher key"   1 (string match -q '*bind-key -n C-s display-popup*' -- "$fragc"; and echo 1; or echo 0)
set -l fragp (__tmux_lives_render_fragment /X/cat.fish S '' | string collect)
t "disabled switcher: no -n bind"  0 (string match -q '*bind-key -n*' -- "$fragp"; and echo 1; or echo 0)
t "disabled switcher: prefix kept" 1 (string match -q '*bind-key S display-popup*' -- "$fragp"; and echo 1; or echo 0)
set -l frags (__tmux_lives_render_fragment /X/cat.fish '' M-s | string collect)
t "disabled prefix: no prefix bind" 0 (string match -q '*bind-key S *' -- "$frags"; and echo 1; or echo 0)
# resolver
set -U _tl_k C-x
t "key: set var wins"   "C-x" (__tmux_lives_key _tl_k S)
set -U _tl_k ''
t "key: empty disables" ""    (__tmux_lives_key _tl_k S)
set -e _tl_k
t "key: unset -> default" "S" (__tmux_lives_key _tl_k S)
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — `__tmux_lives_render_fragment` now gets 3 args but old body ignores them and emits the hardcoded `bind-key S` only (no `-n M-s`), and `__tmux_lives_key` is undefined.

- [ ] **Step 3: Add `__tmux_lives_key`** (place near the top of `conf.d/tmux-lives-install.fish`):

```fish
function __tmux_lives_key --description 'Effective switcher key: VARNAME unset -> DEFAULT; set (even empty) -> its value'
    set -l name $argv[1]
    set -q $name; or begin; echo $argv[2]; return; end
    echo $$name
end
```

- [ ] **Step 4: Rewrite `__tmux_lives_render_fragment`** to take the two keys and build the bind block (accumulate lines, one `printf`):

```fish
function __tmux_lives_render_fragment --description 'Emit the tmux.conf fragment (categorizer path + switcher key binds)'
    # $cat is interpolated unquoted into nested tmux+sh quote layers; assumes no spaces.
    set -l cat $argv[1]
    set -l pkey $argv[2]   # prefix-table key ('' = no prefix bind)
    set -l skey $argv[3]   # no-prefix/direct key ('' = no direct bind)
    set -l popup
    set -l menu
    if test -n "$pkey"
        set -a popup "    bind-key $pkey display-popup -E -w 80% -h 70% -- fish --no-config $cat popup '#{client_name}'"
        set -a menu  "    bind-key $pkey run-shell 'fish --no-config $cat menu'"
    end
    if test -n "$skey"
        set -a popup "    bind-key -n $skey display-popup -E -w 80% -h 70% -- fish --no-config $cat popup '#{client_name}'"
        set -a menu  "    bind-key -n $skey run-shell 'fish --no-config $cat menu'"
    end
    set -l f
    set -a f "# tmux-lives — managed fragment. Generated by 'tmux-lives setup'; edit the plugin, not this."
    set -a f "set -g @plugin 'tmux-plugins/tmux-resurrect'"
    set -a f "set -g @plugin 'tmux-plugins/tmux-continuum'"
    set -a f "set -g @resurrect-strategy-nvim 'session'"
    set -a f "set -g @resurrect-strategy-vim  'session'"
    set -a f "set -g @resurrect-capture-pane-contents 'on'"
    set -a f "set -g @continuum-save-interval '15'"
    set -a f "set -g status-interval 15"
    set -a f "if-shell '! tmux show-options -gv status-right 2>/dev/null | grep -q tmux-categorize' \\"
    set -a f "    'set -ga status-right \"#(fish --no-config $cat tick)\"'"
    if test -n "$popup"
        set -a f "if-shell 'tmux list-commands 2>/dev/null | grep -q display-popup' {"
        set -a f $popup
        set -a f "} {"
        set -a f $menu
        set -a f "}"
    end
    set -a f "set-hook -g client-session-changed {"
    set -a f "    if-shell -F '#{m:shellfish-*,#{client_session}}' {"
    set -a f "        run-shell \"fish --no-config $cat commandeer '#{client_name}' '#{client_session}'\""
    set -a f "    }"
    set -a f "}"
    set -a f "set -ga update-environment \"LC_TERMINAL\""
    set -a f "set -ga update-environment \"LC_TERMINAL_VERSION\""
    set -a f "# Load declared plugins via TPM (setup clones them); without this they are"
    set -a f "# present but never sourced — no resurrect save/restore, no continuum autosave."
    set -a f "run '~/.tmux/plugins/tpm/tpm'"
    printf '%s\n' $f
end
```

- [ ] **Step 5: Update `__tmux_lives_setup`'s render call** — change `__tmux_lives_render_fragment $cat > $fragment` to:

```fish
    __tmux_lives_render_fragment $cat (__tmux_lives_key tmux_lives_prefix_key S) (__tmux_lives_key tmux_lives_switcher_key M-s) > $fragment
```

- [ ] **Step 6: Run install suite, then full suite**

Run: `fish tests/test-tmux-install.fish` → `ALL PASS (N)`.
Run: `for t in tests/test-*.fish; fish $t; end` → all green. (The existing `fragment binds S via display-popup guard` / `... popup subcommand` / `fallback uses menu` / `runs tpm` assertions still pass with default `S`/`M-s`.)

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: render_fragment takes configurable prefix/switcher keys (brace-block binds, disable-on-empty)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 3: `tmux-lives` dispatcher + help + `setup` key flags

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (replace the help-only `tmux-lives` with the dispatcher; add `__tmux_lives_help`, `__tmux_lives_setup_cmd`)
- Test: `tests/test-tmux-install.fish` (rewrite help-content tests; add routing + flag-parse tests)

**Interfaces:**
- Consumes: all `__tmux_lives_*` helpers (Tasks 1–2), `__tmux_lives_status_lines`.
- Produces: `tmux-lives <command> [args]` dispatcher; `__tmux_lives_help`; `__tmux_lives_setup_cmd <flags>` (parses `--prefix-key`/`--switcher-key` → `set -U` → `__tmux_lives_setup`).

- [ ] **Step 1: Write failing tests** — in `tests/test-tmux-install.fish`, REPLACE the existing help block (the `set -l hlp (tmux-lives | string collect)` group, currently asserting `tmux-setup`/`ts [name]`/`tmuxauto` + `Setup / lifecycle:` / `Daily use:` headers, the `-h`/`help`/unknown/`__tmux_lives_help_hint` lines) with:

```fish
set -l hlp (tmux-lives | string collect)
t "help lists setup"     1 (string match -q '*setup *' -- "$hlp"; and echo 1; or echo 0)
t "help lists status"    1 (string match -q '*status *' -- "$hlp"; and echo 1; or echo 0)
t "help lists switch"    1 (string match -q '*switch *' -- "$hlp"; and echo 1; or echo 0)
t "help lists auto"      1 (string match -q '*auto *' -- "$hlp"; and echo 1; or echo 0)
t "help mentions --prefix-key"   1 (string match -q '*--prefix-key*' -- "$hlp"; and echo 1; or echo 0)
t "help mentions --switcher-key" 1 (string match -q '*--switcher-key*' -- "$hlp"; and echo 1; or echo 0)
t "help -h equals bare"  1 (test "$hlp" = (tmux-lives -h | string collect); and echo 1; or echo 0)
tmux-lives bogus 2>/dev/null
t "unknown command returns 1" 1 $status
# routing: stub a helper, confirm the dispatcher calls it
functions -c __tmux_lives_take __tl_take_real
function __tmux_lives_take; set -g _tl_routed "take:$argv[1]"; end
set -g _tl_routed ''
tmux-lives take foo
t "routes take -> helper" "take:foo" "$_tl_routed"
functions -e __tmux_lives_take; functions -c __tl_take_real __tmux_lives_take
# setup flag parsing persists the universal vars (stub the heavy setup body)
functions -c __tmux_lives_setup __tl_setup_real
function __tmux_lives_setup; end
set -e tmux_lives_prefix_key tmux_lives_switcher_key
tmux-lives setup --prefix-key C-a --switcher-key C-s
t "flag persists prefix-key"   "C-a" "$tmux_lives_prefix_key"
t "flag persists switcher-key" "C-s" "$tmux_lives_switcher_key"
set -e tmux_lives_prefix_key tmux_lives_switcher_key
functions -e __tmux_lives_setup; functions -c __tl_setup_real __tmux_lives_setup
```

- [ ] **Step 2: Run to verify failure**

Run: `fish tests/test-tmux-install.fish`
Expected: FAIL — help text still lists old names; `tmux-lives setup ...` not routed/parsed (the old `tmux-lives` only prints help); routing/flag assertions fail.

- [ ] **Step 3: Add `__tmux_lives_help`** (replace the body content of the old help function with the grouped page):

```fish
function __tmux_lives_help --description 'tmux-lives command list'
    printf '%s\n' \
        'tmux-lives — categorized tmux sessions + persistence (fisher plugin)' \
        '' \
        'Usage: tmux-lives <command> [args]' \
        '' \
        'Setup / lifecycle:' \
        '  setup [--prefix-key K] [--switcher-key K]   wire ~/.tmux.conf + TPM/resurrect/continuum;' \
        '                                              set switcher keys (defaults: prefix S, Opt+s=M-s;' \
        '                                              empty value disables that bind)' \
        '  status                                      check install health (incl. switcher keys)' \
        '  teardown                                    remove the wiring (TPM plugins left in place)' \
        '' \
        'Daily:' \
        '  switch [name]                               switch/create a categorized session' \
        '  auto on|off|status|toggle                   control auto-attach on SSH login' \
        '  take <name>                                 force-take a session (detach a stale/ghost client)' \
        '  fixssh                                      refresh SSH_AUTH_SOCK inside a reattached session' \
        '  help                                        this list' \
        '' \
        'Tip: create your own aliases, e.g. `alias ts="tmux-lives switch"`.'
end
```

- [ ] **Step 4: Add `__tmux_lives_setup_cmd`** (flag parsing → persist → setup):

```fish
function __tmux_lives_setup_cmd --description 'Parse switcher-key flags (persist as universal vars), then run setup'
    while test (count $argv) -ge 2
        switch $argv[1]
            case --prefix-key
                set -U tmux_lives_prefix_key $argv[2]; set -e argv[1..2]
            case --switcher-key
                set -U tmux_lives_switcher_key $argv[2]; set -e argv[1..2]
            case '*'
                echo "tmux-lives setup: unknown option '$argv[1]'" >&2; return 1
        end
    end
    if test (count $argv) -gt 0
        echo "tmux-lives setup: unknown/!incomplete option '$argv[1]'" >&2; return 1
    end
    __tmux_lives_setup
end
```

- [ ] **Step 5: Replace the `tmux-lives` function with the dispatcher:**

```fish
function tmux-lives --description 'tmux-lives: unified command — setup/status/teardown/switch/auto/take/fixssh'
    set -l cmd $argv[1]
    switch "$cmd"
        case '' help -h --help
            __tmux_lives_help
        case setup
            __tmux_lives_setup_cmd $argv[2..]
        case status
            echo "tmux-lives status:"
            __tmux_lives_status_lines | sed 's/^/  /'
        case teardown
            __tmux_lives_teardown
        case switch
            __tmux_lives_switch $argv[2..]
        case auto
            __tmux_lives_auto $argv[2..]
        case take
            __tmux_lives_take $argv[2..]
        case fixssh
            __tmux_lives_fixssh
        case '*'
            echo "tmux-lives: unknown command '$cmd'" >&2
            __tmux_lives_help >&2
            return 1
    end
end
```

(The old `tmux-status` logic now lives in the `status` case. `__tmux_lives_status` from Task 1 is no longer called by the dispatcher; remove that now-dead `__tmux_lives_status` function to avoid confusion — its body duplicated the `status` case.)

- [ ] **Step 6: Run install suite, then full suite**

Run: `fish tests/test-tmux-install.fish` → `ALL PASS (N)`.
Run: `for t in tests/test-*.fish; fish $t; end` → all green.

- [ ] **Step 7: Commit**

```bash
git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish
git commit -m "feat: tmux-lives dispatcher (subcommands + help) and setup --prefix-key/--switcher-key

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```

---

### Task 4: `status` keys line + messages + docs + full-suite gate

**Files:**
- Modify: `conf.d/tmux-lives-install.fish` (`__tmux_lives_status_lines` keys line; post-install/update messages)
- Modify: `README.md`, `CLAUDE.md`, spec status
- Test: `tests/test-tmux-status.fish` (or `test-tmux-install.fish`) keys-line assertion; update install-message tests

- [ ] **Step 1: Add the switcher-keys line** to `__tmux_lives_status_lines` (append before `printf '%s\n' $r`):

```fish
    set -l pk (__tmux_lives_key tmux_lives_prefix_key S); test -n "$pk"; or set pk '(off)'
    set -l sk (__tmux_lives_key tmux_lives_switcher_key M-s); test -n "$sk"; or set sk '(off)'
    set -a r "OK switcher keys: prefix=$pk  no-prefix=$sk"
```

- [ ] **Step 2: Update the post-install/update messages** in `conf.d/tmux-lives-install.fish` to the new surface:
  - In `_tmux_lives_post_install`: change the `tmux-setup` line to `    tmux-lives setup     # wire tmux + plugins` and `tmux-status` to `    tmux-lives status    # verify`.
  - `_tmux_lives_post_update` is unchanged (already references `tmux-lives` + `exec fish`).

- [ ] **Step 3: Update the message + keys tests:**
  - In `tests/test-tmux-install.fish`, the install-message assertions (`install msg names tmux-setup` / `tmux-status`) → assert the message contains `tmux-lives setup` and `tmux-lives status`:
    ```fish
    t "install msg names tmux-lives setup"  1 (string match -q '*tmux-lives setup*' -- "$inst"; and echo 1; or echo 0)
    t "install msg names tmux-lives status" 1 (string match -q '*tmux-lives status*' -- "$inst"; and echo 1; or echo 0)
    ```
  - In `tests/test-tmux-status.fish`, add: `t "status shows switcher keys" 1 (__tmux_lives_status_lines | string match -q '*switcher keys: prefix=*'; and echo 1; or echo 0)` (set/erase `tmux_lives_*` vars around it as needed so it reflects defaults).

- [ ] **Step 4: Update docs** — `README.md` and `CLAUDE.md`: replace the command list with the `tmux-lives <verb>` surface (setup/status/teardown/switch/auto/take/fixssh), note `tmux-lives setup --prefix-key/--switcher-key`, and that users alias their own shortcuts. In the spec `docs/superpowers/specs/2026-06-21-tmux-lives-unified-command-design.md`, set `- **Status:** Implemented (Linux suites green; Mac live-smoke pending)`.

- [ ] **Step 5: Full-suite gate**

Run: `for t in tests/test-*.fish; fish $t; end`
Expected: all eight suites green. If any fail, STOP and report.

- [ ] **Step 6: Commit + push + vault re-publish**

```bash
git add conf.d/tmux-lives-install.fish tests/ README.md CLAUDE.md docs/superpowers/specs/2026-06-21-tmux-lives-unified-command-design.md
git commit -m "docs: unified tmux-lives surface — status keys, messages, README/CLAUDE, spec status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
```
Then re-run `vault-publish` on the spec and reflow the vault copy (single-line paragraphs).

---

## Post-implementation (user-owned)
On the Mac: `fisher update` (or remove+install), then `tmux-lives setup` (binds prefix S + Opt+s), `tmux-lives status` (shows keys), `tmux-lives setup --switcher-key C-s` rebinds, `tmux-lives switch` works.

## Self-review notes
- **Spec coverage:** dispatcher+subcommands → T1 (helpers) + T3 (routing/help); key config (flags/persist/render/disable) → T2 + T3; status keys → T4; messages/docs → T4; removal of standalone names → T1. ✓
- **Placeholders:** none — exact code for all novel logic; precise rename mappings for mechanical parts.
- **Name consistency:** `__tmux_lives_switch/_auto/_take/_fixssh/_setup/_teardown`, `__tmux_lives_render_fragment <cat> <pkey> <skey>`, `__tmux_lives_key`, `__tmux_lives_setup_cmd`, `__tmux_lives_help`, vars `tmux_lives_prefix_key`/`tmux_lives_switcher_key` — used identically across tasks.
