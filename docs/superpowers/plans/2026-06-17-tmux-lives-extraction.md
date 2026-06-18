# tmux-lives Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the existing tmux automation from `~/.config/fish` into a standalone public fisher plugin (`tmux-lives`) at `~/workspace/tmux-lives`, with identical behavior and all test suites passing.

**Architecture:** A fisher plugin carries the runtime in `conf.d/tmux.fish`; the categorizer is the one `functions/` file (a standalone script invoked by path); a consolidated `conf.d/tmux-lives-install.fish` defines `tmux-setup`/`tmux-teardown`/`tmux-status` plus helpers, and embeds the `~/.tmux.conf` fragment (no undeployable template). No behavior change — repackaging + de-hardcoding only.

**Tech Stack:** fish 4.x, tmux 3.3a, fisher, TPM (tmux-resurrect/continuum), systemd system units, bash/git.

## Global Constraints

- **No behavior change.** Live behavior must be identical before/after. The gate: `test-tmux-auto` (22), `test-tmux-restore` (5, gcc), `test-tmux-categorize` (83, gcc), `test-tmux-shellfish` each print `ALL PASS`.
- **No host-specifics in committed files.** No `bitsaver`, literal `1000`, `/home/bitsaver`, `/Users/...`. Derive at runtime: `$USER`/`id -un`, `id -u`, `$__fish_config_dir`, `$HOME`.
- **Convention:** consolidated `conf.d/<feature>.fish` files holding all their functions — NOT scattered `functions/*.fish`. The categorizer is the sole `functions/` member because fisher must deploy it as a path-invoked script and it must NOT be sourced at shell startup.
- **fisher reality:** fisher deploys only `.fish` under `conf.d/ functions/ completions/ themes/`. `tests/` and docs are repo-only. Any non-`.fish` runtime data (the fragment) must be embedded in a deployed `.fish` file.
- **Linux only here.** macOS/launchd is spec 2 — keep all OS-specific logic inside `tmux-setup`/`tmux-teardown`/`tmux-status` so spec 2 touches nothing else.
- **Read-only source refs:** `~/.config/fish/conf.d/tmux.fish`, `~/.config/fish/custom/scripts/{tmux-categorize.fish,install-tmux-save-unit.sh,test-*.fish}`, and the auto-tmux block in `~/.tmux.conf` (~lines 125–168).
- **Repo root:** `~/workspace/tmux-lives` (`$REPO`). Commit after every task. This plan does NOT modify the live `~/.config/fish`.

---

### Task 0: Scaffold the repo

**Files:** Create `$REPO/.gitignore`, `$REPO/README.md`, dirs `conf.d/ functions/ tests/`

- [ ] **Step 1: Init repo + dirs**

```bash
cd ~/workspace/tmux-lives
git init -q
mkdir -p conf.d functions tests
printf '/artifacts/\n*.bak\n' > .gitignore
```

- [ ] **Step 2: README stub**

```bash
printf '# tmux-lives\n\nCategorized tmux session automation + persistence, as a fisher plugin.\n\n## Install\n\n```\nfisher install <owner>/tmux-lives\ntmux-setup     # wires ~/.tmux.conf, TPM plugins, systemd units\ntmux-status    # verify\n```\n' > README.md
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -qm "chore: scaffold tmux-lives plugin repo"
```

---

### Task 1: Vendor conf.d/tmux.fish, repoint categorizer default

**Files:**
- Create: `$REPO/conf.d/tmux.fish` (copied verbatim)
- Modify: `$REPO/conf.d/tmux.fish:10`

**Interfaces:**
- Produces: `$tmux_categorize_script` defaulting to `$__fish_config_dir/functions/tmux-categorize.fish` (Task 2 deploys it there).

- [ ] **Step 1: Copy verbatim**

```bash
cp ~/.config/fish/conf.d/tmux.fish ~/workspace/tmux-lives/conf.d/tmux.fish
```

- [ ] **Step 2: Repoint the default**

In `conf.d/tmux.fish` line 10, replace
`set -q tmux_categorize_script; or set -g tmux_categorize_script "$HOME/.config/fish/custom/scripts/tmux-categorize.fish"`
with
`set -q tmux_categorize_script; or set -g tmux_categorize_script "$__fish_config_dir/functions/tmux-categorize.fish"`

- [ ] **Step 3: Syntax check** — Run: `fish -n ~/workspace/tmux-lives/conf.d/tmux.fish` — Expected: exit 0, no output.

- [ ] **Step 4: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux.fish && git commit -qm "feat: vendor conf.d/tmux.fish, deploy-relative categorizer path"
```

---

### Task 2: Relocate the categorizer into functions/

**Files:** Create `$REPO/functions/tmux-categorize.fish` (verbatim copy)

**Interfaces:** Produces a path-invoked script (`fish --no-config <path> <subcommand>`) — subcommands unchanged: `categorize ghosts slug menu overview claim commandeer switch tick`.

- [ ] **Step 1: Copy verbatim**

```bash
cp ~/.config/fish/custom/scripts/tmux-categorize.fish ~/workspace/tmux-lives/functions/tmux-categorize.fish
```

- [ ] **Step 2: Verify runs as a script** — Run: `fish --no-config ~/workspace/tmux-lives/functions/tmux-categorize.fish slug "prod:debug"` — Expected: `prod-debug`

- [ ] **Step 3: Verify a no-op subcommand** — Run: `fish --no-config ~/workspace/tmux-lives/functions/tmux-categorize.fish tick` — Expected: empty, exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/workspace/tmux-lives && git add functions/tmux-categorize.fish && git commit -qm "feat: relocate categorizer to functions/ (fisher-deployable)"
```

---

### Task 3: Port the four test suites, repointed at the repo

**Files:** Create `$REPO/tests/test-tmux-auto.fish`, `tests/test-tmux-restore.fish`, `tests/test-tmux-categorize.fish`, `tests/test-tmux-shellfish.fish`

**Interfaces:** Consumes Tasks 1–2. Produces four suites that source the repo copies and print `ALL PASS`.

- [ ] **Step 1: Copy the four suites**

```bash
cd ~/workspace/tmux-lives
cp ~/.config/fish/custom/scripts/test-tmux-auto.fish       tests/test-tmux-auto.fish
cp ~/.config/fish/custom/scripts/test-tmux-restore.fish    tests/test-tmux-restore.fish
cp ~/.config/fish/custom/scripts/test-tmux-categorize.fish tests/test-tmux-categorize.fish
cp ~/.config/fish/custom/scripts/test-shellfish.fish       tests/test-tmux-shellfish.fish
```

- [ ] **Step 2: Repoint each suite to the repo**

In every copied suite, replace the source anchor `set -g fishdir "$HOME/.config/fish"` with the repo root derived from the test's own location:

```fish
set -g plugindir (path resolve (status dirname)/..)
```

Then replace throughout each file:
- `$fishdir/conf.d/tmux.fish` → `$plugindir/conf.d/tmux.fish`
- `$fishdir/custom/scripts/tmux-categorize.fish` → `$plugindir/functions/tmux-categorize.fish`
- any remaining `$fishdir` → `$plugindir`

In suites that source `conf.d/tmux.fish`, force the categorizer path to the repo copy so the conf.d default is bypassed:

```fish
set -gx tmux_categorize_script $plugindir/functions/tmux-categorize.fish
```

- [ ] **Step 3: Scope test-tmux-shellfish.fish to the plugin**

Open `tests/test-tmux-shellfish.fish`. **Keep** assertions about the tmux `update-environment`/`LC_TERMINAL`(+`_VERSION`) passthrough and any commandeer/tmux-side behavior. **Delete** assertions that exercise the clipboard/sharesheet helpers (`pbcopy`/`pbpaste`/`sharesheet`/`quicklook`/`textastic`/`setbarcolor`/…) — those test `conf.d/shellfish.fish`, which stays in `~/.config/fish`. Adjust the suite's expected pass-count so the summary stays accurate.

- [ ] **Step 4: Run all four** — Run:
```bash
cd ~/workspace/tmux-lives
for t in tests/test-tmux-auto tests/test-tmux-restore tests/test-tmux-categorize tests/test-tmux-shellfish
    echo "== $t =="; fish $t.fish
end
```
Expected: each prints `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add tests && git commit -qm "test: port suites to repo, scope ShellFish to tmux behavior"
```

---

### Task 4: Install-helpers (render fragment, unit text, source-line)

**Files:**
- Create: `$REPO/conf.d/tmux-lives-install.fish`
- Test: `$REPO/tests/test-tmux-install.fish`

**Interfaces:**
- Produces (pure/testable):
  - `__tmux_lives_render_fragment <categorize_path>` → prints the tmux fragment with the categorizer path interpolated.
  - `__tmux_lives_save_unit_text <user> <uid>` / `__tmux_lives_restore_unit_text <user> <uid>` → print the two systemd unit texts.
  - `__tmux_lives_ensure_source_line <tmux_conf> <fragment_path>` → idempotently inserts `source-file <fragment>` before the TPM run-line.

- [ ] **Step 1: Write the failing test** (`tests/test-tmux-install.fish`)

```fish
#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1] => got [$argv[3]]"; end; end

set -l frag (__tmux_lives_render_fragment /X/cat.fish | string collect)
t "fragment has categorizer path" 1 (string match -q '*/X/cat.fish*' -- "$frag"; and echo 1; or echo 0)
t "fragment has update-environment" 1 (string match -q '*update-environment*LC_TERMINAL*' -- "$frag"; and echo 1; or echo 0)
t "fragment has commandeer hook" 1 (string match -q '*client-session-changed*' -- "$frag"; and echo 1; or echo 0)

set -l u (__tmux_lives_save_unit_text alice 1234 | string collect)
t "unit uid"       1 (string match -q '*user@1234.service*' -- "$u"; and echo 1; or echo 0)
t "unit user"      1 (string match -q '*su - alice*' -- "$u"; and echo 1; or echo 0)
t "unit no bitsaver" 0 (string match -q '*bitsaver*' -- "$u"; and echo 1; or echo 0)

set -l tc /tmp/tli-$fish_pid.conf
printf 'set -g foo 1\nrun \'~/.tmux/plugins/tpm/tpm\'\n' > $tc
__tmux_lives_ensure_source_line $tc /frag.conf
__tmux_lives_ensure_source_line $tc /frag.conf
t "source-line added once" 1 (grep -c 'source-file /frag.conf' $tc)
set -l n (string split : (grep -n 'source-file /frag.conf' $tc))[1]
set -l m (string split : (grep -n 'tpm/tpm' $tc))[1]
t "source-line before tpm" 1 (test $n -lt $m; and echo 1; or echo 0)
rm -f $tc

test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
```

- [ ] **Step 2: Run, verify it fails** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` — Expected: FAIL (functions undefined).

- [ ] **Step 3: Implement `conf.d/tmux-lives-install.fish`** (helpers only; public commands added in later tasks)

```fish
# tmux-lives install/uninstall/status. All functions live here (one conf.d file
# per feature). No startup trigger — these are user-invoked commands.

function __tmux_lives_render_fragment --description 'Emit the tmux.conf fragment with the categorizer path interpolated'
    set -l cat $argv[1]
    printf '%s\n' \
        "# tmux-lives — managed fragment. Generated by tmux-setup; edit the plugin, not this." \
        "set -g @plugin 'tmux-plugins/tmux-resurrect'" \
        "set -g @plugin 'tmux-plugins/tmux-continuum'" \
        "set -g @resurrect-strategy-nvim 'session'" \
        "set -g @resurrect-strategy-vim  'session'" \
        "set -g @resurrect-capture-pane-contents 'on'" \
        "set -g @continuum-save-interval '15'" \
        "set -g status-interval 15" \
        "if-shell '! tmux show-options -gv status-right 2>/dev/null | grep -q tmux-categorize' \\" \
        "    'set -ga status-right \"#(fish --no-config $cat tick)\"'" \
        "bind-key S run-shell \"fish --no-config $cat menu\"" \
        "set-hook -g client-session-changed {" \
        "    if-shell -F '#{m:shellfish-*,#{client_session}}' {" \
        "        run-shell \"fish --no-config $cat commandeer '#{client_name}' '#{client_session}'\"" \
        "    }" \
        "}" \
        "set -ga update-environment \"LC_TERMINAL\"" \
        "set -ga update-environment \"LC_TERMINAL_VERSION\""
end

function __tmux_lives_save_unit_text --description 'systemd save-on-shutdown unit text'
    set -l user $argv[1]; set -l uid $argv[2]
    printf '%s\n' \
        "[Unit]" \
        "Description=Save user tmux sessions (resurrect) before shutdown" \
        "DefaultDependencies=no" "Before=shutdown.target" \
        "After=user@$uid.service" "Conflicts=shutdown.target" "" \
        "[Service]" "Type=oneshot" "RemainAfterExit=yes" "ExecStart=/usr/bin/true" \
        "ExecStop=/usr/bin/su - $user -c 'tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh'" "" \
        "[Install]" "WantedBy=multi-user.target"
end

function __tmux_lives_restore_unit_text --description 'systemd restore-at-boot unit text'
    set -l user $argv[1]; set -l uid $argv[2]
    printf '%s\n' \
        "[Unit]" "Description=Restore user tmux sessions (resurrect) at boot" \
        "After=multi-user.target user@$uid.service" "" \
        "[Service]" "Type=oneshot" \
        "ExecStart=/usr/bin/su - $user -c 'fish -c __tmux_restore'" "" \
        "[Install]" "WantedBy=multi-user.target"
end

function __tmux_lives_ensure_source_line --description 'Idempotently source the fragment before the TPM run-line'
    set -l tmux_conf $argv[1]; set -l fragment $argv[2]
    set -l line "source-file $fragment"
    test -f $tmux_conf; or touch $tmux_conf
    grep -qF -- "$line" $tmux_conf; and return 0
    if grep -q "tpm/tpm" $tmux_conf
        set -l tmp (mktemp)
        awk -v L="$line" '/tpm\/tpm/ && !d {print L; d=1} {print}' $tmux_conf > $tmp
        mv $tmp $tmux_conf
    else
        printf '%s\n' "$line" >> $tmux_conf
    end
end
```

- [ ] **Step 4: Run, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` — Expected: `ALL PASS (8)`

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish && git commit -qm "feat: install helpers (fragment/unit/source-line), tested"
```

---

### Task 5: tmux-setup orchestrator

**Files:** Modify `$REPO/conf.d/tmux-lives-install.fish` (append `tmux-setup`)

**Interfaces:** Consumes the Task 4 helpers. Produces `tmux-setup` (renders fragment to `~/.config/tmux/tmux-lives.conf`, wires `~/.tmux.conf`, ensures TPM+resurrect+continuum, installs+enables systemd units via sudo).

- [ ] **Step 1: Append `tmux-setup`**

```fish
function tmux-setup --description 'tmux-lives: install fragment + tmux.conf wiring + TPM plugins + systemd units'
    set -l cat "$__fish_config_dir/functions/tmux-categorize.fish"
    set -l tmuxdir "$HOME/.config/tmux"
    set -l fragment "$tmuxdir/tmux-lives.conf"

    mkdir -p $tmuxdir
    __tmux_lives_render_fragment $cat > $fragment
    echo "tmux-setup: wrote $fragment"

    __tmux_lives_ensure_source_line "$HOME/.tmux.conf" $fragment
    echo "tmux-setup: ensured source-file line in ~/.tmux.conf"

    set -l tpm "$HOME/.tmux/plugins/tpm"
    test -d $tpm; or git clone -q https://github.com/tmux-plugins/tpm $tpm
    for p in tmux-resurrect tmux-continuum
        set -l d "$HOME/.tmux/plugins/$p"
        test -d $d; or git clone -q https://github.com/tmux-plugins/$p $d
    end
    echo "tmux-setup: TPM + resurrect + continuum present"

    if type -q systemctl
        set -l user (id -un); set -l uid (id -u)
        echo "tmux-setup: installing systemd units (sudo required)…"
        __tmux_lives_save_unit_text $user $uid | sudo tee /etc/systemd/system/tmux-resurrect-save.service >/dev/null
        __tmux_lives_restore_unit_text $user $uid | sudo tee /etc/systemd/system/tmux-resurrect-restore.service >/dev/null
        sudo systemctl daemon-reload
        sudo systemctl enable --now tmux-resurrect-save.service
        sudo systemctl enable tmux-resurrect-restore.service
        echo "tmux-setup: systemd units installed + enabled"
    else
        echo "tmux-setup: no systemd — skipping service layer (macOS/launchd is spec 2)"
    end
    echo "tmux-setup: done — run tmux-status to verify, and open a NEW tmux window to pick up the fragment."
end
```

- [ ] **Step 2: Syntax + render-into-tmux sanity (no sudo side effects)** — Run:
```bash
fish -n ~/workspace/tmux-lives/conf.d/tmux-lives-install.fish
fish -c "source ~/workspace/tmux-lives/conf.d/tmux-lives-install.fish; __tmux_lives_render_fragment /tmp/cat.fish | tmux -L tlcheck -f /dev/stdin start-server \; show-options -g status-interval; tmux -L tlcheck kill-server" 2>&1 | grep -q 'status-interval 15' && echo "fragment parses in tmux: OK"
```
Expected: `fragment parses in tmux: OK` (proves the generated fragment is valid tmux syntax on an isolated `-L` server).

- [ ] **Step 3: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish && git commit -qm "feat: tmux-setup orchestrator"
```

---

### Task 6: tmux-teardown

**Files:** Modify `$REPO/conf.d/tmux-lives-install.fish`; extend `$REPO/tests/test-tmux-install.fish`

**Interfaces:** Produces `__tmux_lives_remove_source_line <tmux_conf> <fragment>` + `tmux-teardown`.

- [ ] **Step 1: Add failing test** (append before the summary line in `tests/test-tmux-install.fish`)

```fish
set -l tc2 /tmp/tlt-$fish_pid.conf
printf 'source-file /frag.conf\nrun \'~/.tmux/plugins/tpm/tpm\'\n' > $tc2
__tmux_lives_remove_source_line $tc2 /frag.conf
t "source-line removed" 0 (grep -c 'source-file /frag.conf' $tc2)
__tmux_lives_remove_source_line $tc2 /frag.conf
t "remove idempotent" 0 (grep -c 'source-file /frag.conf' $tc2)
rm -f $tc2
```

- [ ] **Step 2: Run, verify new assertions fail** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` — Expected: FAIL (`__tmux_lives_remove_source_line` undefined).

- [ ] **Step 3: Append implementation** to `conf.d/tmux-lives-install.fish`

```fish
function __tmux_lives_remove_source_line --description 'Remove the fragment source-file line'
    set -l tmux_conf $argv[1]; set -l fragment $argv[2]
    test -f $tmux_conf; or return 0
    set -l tmp (mktemp)
    grep -vF -- "source-file $fragment" $tmux_conf > $tmp
    mv $tmp $tmux_conf
end

function tmux-teardown --description 'tmux-lives: remove fragment + tmux.conf wiring + systemd units'
    set -l fragment "$HOME/.config/tmux/tmux-lives.conf"
    __tmux_lives_remove_source_line "$HOME/.tmux.conf" $fragment
    rm -f $fragment
    echo "tmux-teardown: removed fragment + source-file line"
    if type -q systemctl
        echo "tmux-teardown: removing systemd units (sudo)…"
        sudo systemctl disable --now tmux-resurrect-save.service 2>/dev/null
        sudo systemctl disable tmux-resurrect-restore.service 2>/dev/null
        sudo rm -f /etc/systemd/system/tmux-resurrect-{save,restore}.service
        sudo systemctl daemon-reload
        echo "tmux-teardown: systemd units removed"
    end
    echo "tmux-teardown: done. (TPM plugins under ~/.tmux/plugins left in place.)"
end
```

- [ ] **Step 4: Run, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-install.fish` — Expected: `ALL PASS (10)`

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish tests/test-tmux-install.fish && git commit -qm "feat: tmux-teardown (reverses setup)"
```

---

### Task 7: tmux-status doctor

**Files:** Modify `$REPO/conf.d/tmux-lives-install.fish`; create `$REPO/tests/test-tmux-status.fish`

**Interfaces:** Produces `__tmux_lives_status_lines` (one `OK …`/`MISSING …` per layer) + `tmux-status`.

- [ ] **Step 1: Write failing test** (`tests/test-tmux-status.fish`)

```fish
#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
source $plugindir/conf.d/tmux-lives-install.fish
set -g pass 0; set -g fail 0
function t; test "$argv[2]" = "$argv[3]"; and set -g pass (math $pass+1); or begin; set -g fail (math $fail+1); echo "FAIL: $argv[1]"; end; end
set -l out (__tmux_lives_status_lines | string collect)
t "checks fragment"    1 (string match -q '*fragment*'    -- "$out"; and echo 1; or echo 0)
t "checks categorizer" 1 (string match -q '*categorizer*' -- "$out"; and echo 1; or echo 0)
t "emits OK or MISSING" 1 (string match -qr 'OK|MISSING' -- "$out"; and echo 1; or echo 0)
test $fail -eq 0; and echo "ALL PASS ($pass)"; or echo "FAILED ($fail)"
```

- [ ] **Step 2: Run, verify it fails** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-status.fish` — Expected: FAIL.

- [ ] **Step 3: Append implementation** to `conf.d/tmux-lives-install.fish`

```fish
function __tmux_lives_status_lines --description 'One status line per tmux-lives layer'
    set -l cat "$__fish_config_dir/functions/tmux-categorize.fish"
    set -l fragment "$HOME/.config/tmux/tmux-lives.conf"
    set -l r
    test -f "$__fish_config_dir/conf.d/tmux.fish"; and set -a r "OK conf.d/tmux.fish deployed"; or set -a r "MISSING conf.d/tmux.fish (fisher install …)"
    test -f $cat; and set -a r "OK categorizer deployed"; or set -a r "MISSING categorizer"
    test -f $fragment; and set -a r "OK tmux fragment present"; or set -a r "MISSING tmux fragment (run tmux-setup)"
    grep -qF -- "source-file $fragment" "$HOME/.tmux.conf" 2>/dev/null; and set -a r "OK ~/.tmux.conf sources fragment"; or set -a r "MISSING source-file line"
    test -d "$HOME/.tmux/plugins/tmux-resurrect"; and set -a r "OK tmux-resurrect present"; or set -a r "MISSING tmux-resurrect"
    if type -q systemctl
        systemctl is-enabled tmux-resurrect-save.service >/dev/null 2>&1; and set -a r "OK save service enabled"; or set -a r "MISSING save service (run tmux-setup)"
    end
    printf '%s\n' $r
end

function tmux-status --description 'tmux-lives: report install health across all layers'
    echo "tmux-lives status:"
    __tmux_lives_status_lines | sed 's/^/  /'
end
```

- [ ] **Step 4: Run, verify pass** — Run: `fish ~/workspace/tmux-lives/tests/test-tmux-status.fish` — Expected: `ALL PASS (3)`

- [ ] **Step 5: Commit**

```bash
cd ~/workspace/tmux-lives && git add conf.d/tmux-lives-install.fish tests/test-tmux-status.fish && git commit -qm "feat: tmux-status doctor"
```

---

### Task 8: Genericness audit

**Files:** Create `$REPO/tests/test-generic.fish`

- [ ] **Step 1: Write the test** (`tests/test-generic.fish`)

```fish
#!/usr/bin/env fish
set -g plugindir (path resolve (status dirname)/..)
set -l hits (grep -rnE 'bitsaver|/home/[a-z]|/Users/|user@1000|su - bitsaver' \
    $plugindir/conf.d $plugindir/functions 2>/dev/null)
if test -n "$hits"
    echo "FAIL: host-specifics found:"; printf '%s\n' $hits; echo "FAILED"
else
    echo "ALL PASS (1)"
end
```

- [ ] **Step 2: Run; fix any hit** — Run: `fish ~/workspace/tmux-lives/tests/test-generic.fish` — Expected: `ALL PASS (1)`. If a hit appears (e.g. a stray `$HOME/.config/fish` literal), replace with `$__fish_config_dir` and re-run.

- [ ] **Step 3: Commit**

```bash
cd ~/workspace/tmux-lives && git add tests/test-generic.fish && git commit -qm "test: genericness guard"
```

---

### Task 9: End-to-end parity verification

**Files:** none (verification + tag)

- [ ] **Step 1: Full suite run** — Run:
```bash
cd ~/workspace/tmux-lives
for t in tests/test-tmux-auto tests/test-tmux-restore tests/test-tmux-categorize tests/test-tmux-shellfish tests/test-tmux-install tests/test-tmux-status tests/test-generic
    echo "== $t =="; fish $t.fish
end
```
Expected: every suite prints `ALL PASS`.

- [ ] **Step 2: Local fisher install into a throwaway config** — Run:
```bash
set -lx TLCFG /tmp/fishcfg-$fish_pid
mkdir -p $TLCFG
fish -c "set -gx __fish_config_dir $TLCFG; fisher install ~/workspace/tmux-lives" 2>&1 | tail -5
ls $TLCFG/conf.d/tmux.fish $TLCFG/conf.d/tmux-lives-install.fish $TLCFG/functions/tmux-categorize.fish
```
Expected: fisher reports installed; all three files exist.

- [ ] **Step 3: Behavior parity spot-check (human gate)** — With the plugin sourced, confirm `__tmux_categorize`, `ts`, the `tick`/`menu`/`commandeer` subcommands, prune, and restore behave identically to `~/.config/fish` today. The suites cover the logic; this is the verification-before-completion gate before claiming done.

- [ ] **Step 4: Tag** — Run:
```bash
cd ~/workspace/tmux-lives && git tag spec1-extraction-parity && git log --oneline | head -14
```

---

## Notes for the executor

- **Cutover is NOT in this plan.** Making `~/workspace/tmux-lives` the *active* config (replacing the `~/.config/fish` tmux copies + running the Claude-context `replicate`) happens after parity sign-off — see the repo `CLAUDE.md`. This plan only builds + proves the plugin; it never edits the live `~/.config/fish` tmux files.
- **GitHub owner** for the public repo is still TBD; only the later publish step needs it.
- **macOS/launchd** is confined to `tmux-setup`/`tmux-teardown`/`tmux-status` (the `type -q systemctl` branches) and is spec 2.
