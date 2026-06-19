# tmux-lives — fish plugin

**tmux-lives** is the tmux automation system (categorized sessions, switcher, persistence,
ShellFish coexistence) extracted from `~/.config/fish` into a standalone, cross-platform
**fisher plugin** (Linux now; macOS = spec 2).

**Status (2026-06-18):** spec-1 extraction **done** (tagged `spec1-extraction-parity`, no
behavior change) and the **ts live-preview switcher** is built — `prefix S`/`ts` open an fzf
`display-popup` with a live `capture-pane` preview + the categorized list, falling back to the
old `display-menu` when fzf is absent. All test suites pass (`for t in tests/test-*.fish; fish
$t; end`). See `docs/superpowers/` for the specs/plans.

**NOT yet cut over:** the live, running system is still `~/.config/fish` until you run the
cutover below. Two pieces remain: this cutover, and the macOS port (spec 2 — launchd vs the
`type -q systemctl` branches in `tmux-setup`/`teardown`/`status`). Known constraint: fzf has no
non-selectable rows, so the `── claude ──` header rows are landable-but-no-op (a deliberate,
cosmetic trade-off — see the `project-tmux-lives` memory).

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
