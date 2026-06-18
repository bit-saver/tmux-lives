# ts Live-Preview Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the `ts` / `prefix S` switcher to show a live `capture-pane` preview beside the tailored categorized list (via fzf in a `display-popup`), with a header restyle, muted-yellow current marker, and `gen-N` general-session naming.

**Architecture:** All logic lives in `functions/tmux-categorize.fish` (categorizer) + `conf.d/tmux.fish` (`ts`) + the fragment in `conf.d/tmux-lives-install.fish` (`prefix S`). The fzf path is **optional**: a new `open-switcher` dispatcher opens an fzf `display-popup` when fzf is installed and otherwise falls back to today's `display-menu`. fzf input is a new deterministic, unit-tested builder; the fzf *look* is tuned against a real render.

**Tech Stack:** fish 4.x, tmux 3.3a, fzf 0.38 (optional), bash test harness.

## Global Constraints

- **fzf is OPTIONAL.** Every fzf-path change MUST preserve the `display-menu` fallback: with no fzf installed, `ts`/`prefix S` behave as today (digit-jump intact). This is the macOS-portability seam.
- **No host-specifics** (the spec-1 genericness guard `tests/test-generic.fish` must stay green): no literal `bitsaver`/`1000`/`/home/`/`/Users/`.
- **All existing suites stay `ALL PASS`:** `test-tmux-auto` (22), `test-tmux-restore` (5), `test-tmux-categorize` (updated count), `test-tmux-shellfish` (3), `test-tmux-install` (updated if the `bind-key S` line changes), `test-tmux-status` (3), `test-generic` (1). Run from the repo root: `fish tests/<suite>.fish`.
- **fzf labels use ANSI SGR escapes** (`\e[38;5;…m`); the `display-menu` builder uses tmux `#[fg=…]` markup. Do NOT mix the two syntaxes.
- **Categorizer invocation model unchanged:** still invoked as `fish --no-config $__tcz_self <subcommand>` from tmux `#()`/run-shell. The script path is available inside the script as `$__tcz_self`.
- **Palette:** claude = tmux colour208 (orange) / ANSI `38;5;208`; running = cyan (`6`); general = green (`2`); current session = muted yellow `colour143` / ANSI `38;5;143`.
- **Tests live in** `tests/test-tmux-categorize.fish` (sources the categorizer with `tmux_categorize_test=1` to suppress the main dispatch) unless noted. New `__tcz_*` helper names — keep the `__tcz_` prefix; these are internal, no collision risk.
- **Repo:** `~/workspace/tmux-lives` (`$REPO`), on `main`, has a remote. Commit after each task; push at the end (or per task — low-risk).

---

### Task 1: `gen-N` general-session naming

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_free_number`→`__tcz_free_gen`, `__tcz_owned`, `__tcz_categorize`, `__tcz_new_general`); Test `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Produces `__tcz_free_gen <taken...> -> "gen-N"` (smallest free N starting at 1).
- `__tcz_owned <name>` now true for `^(gen-)?[0-9]+$` (legacy numeric + gen-N) or `@tmux_auto_name` match.

- [ ] **Step 1: Update the unit tests** in `tests/test-tmux-categorize.fish` — find the assertions for `__tcz_free_number` and the general-naming behavior and change them to `gen-N`. Replace the `__tcz_free_number` unit assertions with:

```fish
t "free_gen: empty -> gen-1"        "gen-1" (__tcz_free_gen)
t "free_gen: gen-1 taken -> gen-2"  "gen-2" (__tcz_free_gen gen-1)
t "free_gen: skips gaps"            "gen-2" (__tcz_free_gen gen-1 gen-3)
t "owned: gen-N"                    "0" (__tcz_owned gen-2; echo $status)
t "owned: legacy numeric"           "0" (__tcz_owned 4; echo $status)
t "owned: hand name (no stamp)"     "1" (__tcz_owned mydev; echo $status)
```

(Keep using the suite's existing `t <desc> <expected> <actual>` helper. For `__tcz_owned` the legacy-numeric/gen-N cases don't touch tmux — the regex returns before the `show-option` call.)

- [ ] **Step 2: Run, verify the new assertions fail**

Run: `fish ~/workspace/tmux-lives/tests/test-tmux-categorize.fish`
Expected: FAIL (`__tcz_free_gen` undefined; old general-naming assertions gone).

- [ ] **Step 3: Implement.** In `functions/tmux-categorize.fish`:

Replace `__tcz_free_number` (currently lines ~31–37) with:

```fish
function __tcz_free_gen --description 'argv = taken names -> smallest free gen-N (N from 1)'
    set -l n 1
    while contains -- "gen-$n" $argv
        set n (math $n + 1)
    end
    echo "gen-$n"
end
```

In `__tcz_owned` (line ~152) change the fast-path regex:

```fish
    string match -qr '^(gen-)?[0-9]+$' -- "$cur"; and return 0
```

In `__tcz_categorize`, the general stable-skip (line ~173) — make `gen-N` stable but let bare numerics be renamed:

```fish
                string match -qr '^gen-[0-9]+$' -- "$cur"; and continue
```

…and the fallback namer (line ~182):

```fish
        test -n "$desired"; or set desired (__tcz_free_gen $others)
```

In `__tcz_new_general` (line ~373):

```fish
    set -l name (__tcz_free_gen (tmux list-sessions -F '#{session_name}' 2>/dev/null))
```

Then `grep -n __tcz_free_number functions/tmux-categorize.fish tests/*.fish` — there should be NO remaining references. If any remain, update them to `__tcz_free_gen`.

- [ ] **Step 4: Run tests, verify pass**

Run: `fish ~/workspace/tmux-lives/tests/test-tmux-categorize.fish`
Expected: `ALL PASS (N)` (N = the suite's new total). Also run `fish ~/workspace/tmux-lives/tests/test-tmux-auto.fish` (it shares the idle-list cross-check) → `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish && git commit -qm "feat: name general sessions gen-N (auto-renames legacy numerics)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Header restyle + muted-yellow current (display-menu builder)

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_menu_args`, lines ~231–317); Test `tests/test-tmux-categorize.fish`.

**Interfaces:** `__tcz_menu_args` output unchanged in structure (triples for `display-menu`); only the header text and the current-row color change.

- [ ] **Step 1: Write failing tests.** Add to `tests/test-tmux-categorize.fish` (the suite already exercises `__tcz_menu_args`; mirror its style). Feed a synthetic overview with a current session and assert the new header + yellow:

```fish
set -l TAB (printf '\t')
set -l ov "neuro$TAB""claude$TAB""0$TAB""100$TAB""neuro
mydev$TAB""general$TAB""1$TAB""50$TAB""mydev"
set -l margs (printf '%s\n' $ov | __tcz_menu_args neuro | string join "\n")
t "menu: 2-dash lead-in header"  "yes" (string match -q '*── claude *' -- "$margs"; and echo yes; or echo no)
t "menu: header rule to edge"    "yes" (string match -q '*── claude ────*' -- "$margs"; and echo yes; or echo no)
t "menu: current uses yellow"    "yes" (string match -q '*#[fg=colour143]*' -- "$margs"; and echo yes; or echo no)
t "menu: current not dimmed"     "no"  (string match -q '*#\[dim\]*' -- "$margs"; and echo yes; or echo no)
```

- [ ] **Step 2: Run, verify fail** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-categorize.fish` — Expected: FAIL (old header `────`/`#[dim]`).

- [ ] **Step 3: Implement.** In `__tcz_menu_args`:

Header block (currently lines ~294–299) → 2-dash lead-in + rule filling the full width:

```fish
            set -l word "── $group "
            set -l right (math "$total - "(string length -- "$word"))
            test $right -lt 2; and set right 2
            printf '%s\n%s\n%s\n' \
                "-#[fg=$hcol,bold]$word"(string repeat -n $right ─)"#[default]" '' ''
```

Current-row color (the `set dim 1` row gets yellow instead of dim). Where the label is finalized (line ~277), change:

```fish
        test "$e_dim[$i]" = 1; and set label "#[fg=colour143]$label#[default]"
```

(Leave the `▸ $f[5]` base and `[current]` indicator from lines ~251–252 as-is — only the styling changes from dim to yellow.)

- [ ] **Step 4: Run tests, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-categorize.fish` — Expected: `ALL PASS (N)`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish && git commit -qm "feat: restyle menu headers (── name ──) + muted-yellow current marker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: fzf input/label builder (`__tcz_fzf_lines`)

**Files:** Modify `functions/tmux-categorize.fish` (new `__tcz_fzf_lines`); Test `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Consumes: `__tcz_overview` lines on stdin (`name⇥category⇥attached⇥last⇥display`).
- Produces: `__tcz_fzf_lines <current>` → one line per row, `TAB`-delimited `<session>⇥<ANSI-label>`. Category-change rows emit a colored separator with an **empty** field 1. Field 1 is the session for fzf preview/accept; field 2 is the shown label.

- [ ] **Step 1: Write failing tests** in `tests/test-tmux-categorize.fish`:

```fish
set -l TAB (printf '\t')
set -l ov "neuro$TAB""claude$TAB""0$TAB""100$TAB""neuro
gen-1$TAB""general$TAB""0$TAB""50$TAB""gen-1"
set -l fl (printf '%s\n' $ov | __tcz_fzf_lines neuro)
# first emitted line is the claude separator: empty field 1
set -l sep1 (string split -m 1 $TAB -- $fl[1])
t "fzf: separator has empty session field" "" "$sep1[1]"
t "fzf: separator shows category rule"     "yes" (string match -q '*── claude *' -- "$fl[2]"; and echo yes; or echo no)
# the neuro row: field 1 == session name, label carries yellow ANSI (current)
set -l nl (printf '%s\n' $fl | string match -e neuro)[1]
set -l nf (string split -m 1 $TAB -- $nl)
t "fzf: row field1 is session"   "neuro" "$nf[1]"
t "fzf: current row yellow ANSI" "yes" (string match -q '*38;5;143*' -- "$nl"; and echo yes; or echo no)
# gen-1 row present, session field intact
t "fzf: gen row field1"          "gen-1" (set -l g (printf '%s\n' $fl | string match -e 'gen-1')[1]; string split -m 1 $TAB -- $g)[1]
```

- [ ] **Step 2: Run, verify fail** — Expected: FAIL (`__tcz_fzf_lines` undefined).

- [ ] **Step 3: Implement** `__tcz_fzf_lines` in `functions/tmux-categorize.fish` (near `__tcz_menu_args`):

```fish
function __tcz_fzf_lines --argument-names current --description 'overview lines -> session\tANSI-label for fzf (+ colored separator rows w/ empty session)'
    set -l TAB (printf '\t')
    set -l ESC (printf '\e')
    set -l RST "$ESC""[0m"
    set -l group ''
    while read -l line
        set -l f (string split -m 4 $TAB -- $line)
        test (count $f) -ge 5; or continue
        if test "$f[2]" != "$group"
            set group $f[2]
            set -l c 208
            test "$group" = running; and set c 6
            test "$group" = general; and set c 2
            printf '%s%s%s── %s %s%s\n' '' $TAB "$ESC[1;38;5;$c""m" "$group" (string repeat -n 26 ─) "$RST"
        end
        set -l label "$f[5]"
        set -l mark ''
        if test -n "$current"; and test "$f[1]" = "$current"
            set label "$ESC[38;5;143m▸ $f[5]$RST"
            set mark "$ESC[38;5;143m[current]$RST"
        else if test "$f[3]" = 1
            set mark "$ESC[2m[attached]$RST"
        end
        printf '%s%s%s  %s\n' "$f[1]" $TAB "$label" "$mark"
    end
end
```

(The 26-dash rule and exact spacing are starting values; the on-screen look is tuned in Task 6. Field structure — session in field 1, label+mark in field 2 — is the contract the tests lock.)

- [ ] **Step 4: Run tests, verify pass** — Expected: `ALL PASS (N)`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish tests/test-tmux-categorize.fish && git commit -qm "feat: __tcz_fzf_lines — ANSI session list for the fzf switcher

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `open-switcher` dispatcher + `fzfpick` + `ts` wiring

**Files:** Modify `functions/tmux-categorize.fish` (`__tcz_open_switcher`, `__tcz_fzfpick`, `__tcz_main` cases, usage line); `conf.d/tmux.fish` (`ts`); Test `tests/test-tmux-categorize.fish`.

**Interfaces:**
- Consumes: `__tcz_fzf_lines` (Task 3), `__tcz_overview`, `__tcz_switch`, `__tcz_menu`.
- Produces: subcommands `open-switcher <client>` and `fzfpick <client>`.

- [ ] **Step 1: Write failing tests** (fallback decision + separator no-op) in `tests/test-tmux-categorize.fish`. The suite already builds a PATH shim dir (`$shimdir`) for fake `tmux`/`claude`; reuse it to add/remove a fake `fzf`:

```fish
# open-switcher chooses popup (fzf present) vs menu (absent). Stub both branches'
# side effects by shimming `tmux` to echo its first arg, and toggling `fzf` on PATH.
printf '#!/bin/sh\necho "TMUX:$1"\n' > $shimdir/tmux; chmod +x $shimdir/tmux
printf '#!/bin/sh\nexit 0\n' > $shimdir/fzf; chmod +x $shimdir/fzf
t "switcher: fzf present -> display-popup" "yes" (string match -q '*TMUX:display-popup*' -- (__tcz_open_switcher c1 2>&1 | string join ' '); and echo yes; or echo no)
rm $shimdir/fzf
t "switcher: no fzf -> display-menu"       "yes" (string match -q '*TMUX:display-menu*' -- (__tcz_open_switcher c1 2>&1 | string join ' '); and echo yes; or echo no)
rm -f $shimdir/tmux
```

(Restore any global `tmux` shim the suite relies on afterward if needed — follow the suite's existing teardown pattern.)

- [ ] **Step 2: Run, verify fail** — Expected: FAIL (`__tcz_open_switcher` undefined).

- [ ] **Step 3: Implement.** Add to `functions/tmux-categorize.fish`:

```fish
function __tcz_open_switcher --argument-names client --description 'open the switcher: fzf display-popup if available, else display-menu'
    if command -q fzf
        tmux display-popup -E -w 80% -h 70% -- fish --no-config $__tcz_self fzfpick "$client"
    else
        __tcz_menu
    end
end

function __tcz_fzfpick --argument-names client --description 'fzf session picker (runs inside the display-popup); switch on accept'
    __tcz_categorize >/dev/null 2>&1
    set -l current (tmux display-message -c "$client" -p '#{session_name}' 2>/dev/null)
    test -n "$current"; or set current (tmux display-message -p '#{session_name}' 2>/dev/null)
    set -l TAB (printf '\t')
    set -l choice (__tcz_overview | __tcz_fzf_lines "$current" | fzf \
        --ansi --delimiter $TAB --with-nth 2 --layout=reverse-list \
        --prompt 'switch ❯ ' --pointer '▌' --info inline \
        --preview 'tmux capture-pane -ep -t "={1}"' \
        --preview-window 'right,50%,border-left' \
        --color 'bg:-1,fg:-1,hl:208,fg+:15,bg+:236,hl+:208,pointer:208,prompt:81,info:240,border:240')
    test -n "$choice"; or return 0
    set -l sess (string split -m 1 $TAB -- $choice)[1]
    test -n "$sess"; or return 0    # separator row -> no-op
    __tcz_switch "$sess" "$client"
end
```

Add cases to `__tcz_main` (after `case menu`):

```fish
        case open-switcher
            __tcz_open_switcher $argv[2]
        case fzfpick
            __tcz_fzfpick $argv[2]
```

…and update the usage string (line ~446) to include `open-switcher|fzfpick`.

In `conf.d/tmux.fish`, the inside-tmux `ts` branch (lines ~193–197) routes through the dispatcher with the client:

```fish
    if set -q TMUX
        set -l client (tmux display-message -p '#{client_name}' 2>/dev/null)
        env tmux_auto_ghost_minutes=$tmux_auto_ghost_minutes \
            fish --no-config $tmux_categorize_script open-switcher "$client"
        return
    end
```

- [ ] **Step 4: Run tests, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-categorize.fish` → `ALL PASS (N)`; `fish -n ~/workspace/tmux-lives/conf.d/tmux.fish` → exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish conf.d/tmux.fish tests/test-tmux-categorize.fish && git commit -qm "feat: open-switcher/fzfpick — fzf live-preview popup with display-menu fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `prefix S` binding (fragment) + install-test update

**Files:** Modify `conf.d/tmux-lives-install.fish` (`__tmux_lives_render_fragment`); Test `tests/test-tmux-install.fish`.

**Interfaces:** Consumes the `fzfpick`/`menu` subcommands. The fragment's `bind-key S` becomes fzf-aware at load time via `if-shell`.

- [ ] **Step 1: Update the install test.** In `tests/test-tmux-install.fish`, the assertion that checks the rendered fragment's `bind-key S` (the "menu bind" check) must now expect the `if-shell`-guarded popup binding. Replace it with:

```fish
t "fragment binds S via if-shell" 1 (string match -q '*if-shell*command -v fzf*' -- "$frag"; and echo 1; or echo 0)
t "fragment popup uses fzfpick"   1 (string match -q '*display-popup*fzfpick*' -- "$frag"; and echo 1; or echo 0)
t "fragment fallback uses menu"   1 (string match -q '*run-shell*menu*' -- "$frag"; and echo 1; or echo 0)
```

(Adjust the suite's expected pass count for the net change in assertions.)

- [ ] **Step 2: Run, verify fail** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` — Expected: FAIL.

- [ ] **Step 3: Implement.** In `__tmux_lives_render_fragment` (in `conf.d/tmux-lives-install.fish`), replace the single `bind-key S run-shell …menu…` line with an `if-shell`-guarded pair (decided when the fragment is sourced):

```fish
        "if-shell 'command -v fzf >/dev/null 2>&1' \\" \
        "    \"bind-key S display-popup -E -w 80% -h 70% -- fish --no-config $cat fzfpick '#{client_name}'\" \\" \
        "    \"bind-key S run-shell 'fish --no-config $cat menu'\"" \
```

(Keep `$cat` interpolation as the rest of the fragment does. The popup path binds `display-popup` directly — the canonical, reliable way; the no-fzf path keeps today's menu binding with digit-jump.)

- [ ] **Step 4: Run tests, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` → `ALL PASS (N)`. Also confirm the rendered fragment parses on an isolated tmux server:

```bash
fish -c "source ~/workspace/tmux-lives/conf.d/tmux-lives-install.fish; __tmux_lives_render_fragment /tmp/cat.fish" > /tmp/frag.conf
tmux -L tlcheck -f /tmp/frag.conf start-server \; list-keys -T prefix \; kill-server 2>&1 | grep -q 'bind-key.*S ' && echo "S bound: OK"
```
Expected: `S bound: OK`.

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish && git commit -qm "feat: prefix S opens fzf preview popup (if-shell guarded; menu fallback)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Live styling pass + full verification (human gate)

**Files:** Possibly tweak the `fzf --color`/`--preview-window`/`--pointer` and `__tcz_fzf_lines` spacing in `functions/tmux-categorize.fish` based on the real render. No new files.

- [ ] **Step 1: Full automated suite** — Run:
```bash
cd ~/workspace/tmux-lives
for t in test-tmux-auto test-tmux-restore test-tmux-categorize test-tmux-shellfish test-tmux-install test-tmux-status test-generic; do
  echo "== $t =="; fish tests/$t.fish | tail -1
done
```
Expected: every suite `ALL PASS`.

- [ ] **Step 2: Real render.** Drive the live popup and capture it for review. Inside a real tmux session (fzf installed), with the categorizer reachable:
```bash
# from a tmux pane, with the plugin's categorizer at $cat:
tmux display-popup -E -w 80% -h 70% -- fish --no-config <path-to>/functions/tmux-categorize.fish fzfpick "$(tmux display-message -p '#{client_name}')"
```
Capture a screenshot of the popup (categorized list + live preview).

- [ ] **Step 3: Tune to match the approved mockup.** Adjust `--color`, `--preview-window`, `--pointer`, `--prompt`, and the `__tcz_fzf_lines` separator width/spacing until the look matches the design (colored `── name ──` headers, muted-yellow current, tailored — not default-fzf). **Get the user's sign-off on the screenshot.** Re-run the `test-tmux-categorize` suite after any `__tcz_fzf_lines` change.

- [ ] **Step 4: Commit any tuning + push**

```bash
cd ~/workspace/tmux-lives && git add -A && git commit -qm "polish: tune fzf switcher styling to match the design

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push origin main
git tag ts-live-preview && git push origin ts-live-preview
```

---

## Notes for the executor

- **Order matters:** Task 1 (gen-N) and Task 2 (restyle) are independent categorizer changes; Tasks 3→4→5 build the fzf path bottom-up (data builder → dispatcher → binding); Task 6 is the interactive gate. Each task ends green.
- **The no-fzf fallback is sacred** — never let an fzf-path change break `ts`/`prefix S` when fzf is absent. Tasks 4 and 5 both carry explicit fallback paths; verify by shimming fzf off PATH.
- **Don't run `tmux-setup`/`open-switcher`/`fzfpick` against the live config blindly** — they mutate the real tmux. Use isolated `-L` servers / throwaway invocations for automated checks; the live render in Task 6 is the deliberate exception (user-driven).
- **Cutover is still separate** — this lands in the plugin repo; making it active on the user's machine (and the macOS port) are later steps.
