# tmux-lives — fish plugin

**tmux-lives** is the tmux automation system (categorized sessions, switcher, persistence,
ShellFish coexistence) extracted from `~/.config/fish` into a standalone, cross-platform
**fisher plugin** (Linux now; macOS = spec 2).

**Status (2026-06-21): SHIPPED + LIVE on the Linux host.** spec-1 extraction done + unified command refactor done. The **popup switcher** is the live switcher — `prefix S` and `Opt+s` (`bind -n M-s`) open a pure-fish two-pane `display-popup`: categorized list (claude/running/general) with `╭──`/`│` category-colored border, `▐` selected block, muted-yellow `❯` current marker, live `capture-pane` preview. **Keys:** `↑↓`/`j`/`k` move · `Enter` switch · `x` kill highlighted session (`kill <name>? (y/n)` confirm → kill + refresh) · `Esc`/`q` cancel. `display-menu` is the no-`display-popup` fallback. 8 suites pass: `for t in tests/test-*.fish; fish $t; end`. All functionality is under `tmux-lives <verb>` (setup/status/teardown/switch/auto/take/fixssh); `tmux-lives setup --prefix-key K --switcher-key K` configures and persists keys; `fisher install`/`update` print post-install/update guidance.

### Live wiring (the cutover, done 2026-06-19 — REAL fisher install)
- Installed via `fisher install bit-saver/tmux-lives` → files live at `~/.config/fish/{conf.d/tmux.fish,
  conf.d/tmux-lives-install.fish, functions/tmux-categorize.fish}`, tracked in `fish_plugins` + `_fisher_plugins`.
- `conf.d/tmux.fish` resolves the categorizer via `$__fish_config_dir/functions/tmux-categorize.fish` (portable).
- `~/.tmux.conf` (hand-maintained, NOT via `tmux-lives setup` — would duplicate its existing resurrect/continuum/
  sensible/yank) hardcodes the bind paths to `~/.config/fish/functions/tmux-categorize.fish`. `tmux-lives setup` is
  for a FRESH host (e.g. the Mac); this host was reconciled in place.
- **Dev loop from here:** edit → `for t in tests/test-*.fish; fish $t; end` → commit + push → then make it live:
  `fisher update` (works in the user's interactive fish) OR `cp` the changed `conf.d/`+`functions/` files into
  `~/.config/fish/`. ⚠️ `fisher install/update` HANGS inside the Claude bash sandbox (parallel-fetch needs job
  control) — from a Claude session use the `cp` sync; the user can run `fisher update` themselves.

**macOS port (spec 2): implemented** — runtime-only persistence (no launchd units; continuum autosave + first-access restore), `/proc`→`ps` detection (`__tcz_pid_comm`/`__tcz_pid_cmdline`), bare-switch cold-start when no server. **Pending:** live Mac smoke (categorize as claude, cold-start `tmux-lives switch`, reboot-restore). On the Mac: `fisher install bit-saver/tmux-lives` + run `tmux-lives setup` (binds `prefix S` + `Opt+s` by default; use `--prefix-key`/`--switcher-key` to customize).

## claude-mem history

This project was extracted from `~/.config/fish`; its development history (through
2026-06-17) lives in claude-mem under the project label **`fish`**, not `tmux-lives`.
When searching claude-mem / mem-search for prior work on this system, also query
`project: "fish"` (terms like "tmux", "auto-tmux", "categorize", "shellfish",
"resurrect"). New observations from this repo are tagged `tmux-lives`.

## Migrating the Claude context here (run at switch-time)

The conversation history + file-based memories still live under the
`~/.config/fish` namespace. When you're ready to make this repo the primary working
dir, replicate that context with the migration skill (one command; reversible):

```bash
rm -rf ~/.claude/projects/-home-bitsaver-workspace-tmux-lives        # clear the empty /add-dir stub
bash ~/.claude/skills/migrating-project-directories/scripts/claude-code-migrate.sh \
     --mode replicate ~/.config/fish ~/workspace/tmux-lives
```

Do this **last** (right before switching), so it captures the latest state rather
than a stale pre-extraction snapshot. `~/.config/fish` is left fully intact.
