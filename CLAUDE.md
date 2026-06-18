# tmux-lives — fish plugin (WIP)

This repo will hold **tmux-lives** — the tmux automation system being extracted from
`~/.config/fish` into a standalone, cross-platform **fisher plugin** (Linux + macOS).
Status: **scaffolding** — the plugin design/extraction is being planned. Until
extraction completes, the live, authoritative system still lives in `~/.config/fish`
(`conf.d/tmux.fish`, `custom/scripts/tmux-categorize.fish`, the four test suites,
`docs/auto-tmux.md`). Treat that as source of truth; this repo is being assembled.

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
