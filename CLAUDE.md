# tmux-lives — fish plugin

**tmux-lives** is the tmux automation system (categorized sessions, switcher, persistence,
ShellFish coexistence) extracted from `~/.config/fish` into a standalone, cross-platform
**fisher plugin** (Linux now; macOS = spec 2).

**Status (2026-06-23): SHIPPED + LIVE on the Linux host.** spec-1 extraction done + unified command refactor done. The **popup switcher** is the live switcher — `prefix S` and `Opt+s` (`bind -n M-s`) open a pure-fish two-pane `display-popup`: categorized list (claude/running/general) with `╭──`/`│` category-colored border, `▐` selected block, muted-yellow `❯` current marker, live `capture-pane` preview. **Keys:** `↑↓`/`j`/`k` move · `Enter` switch · `x` kill highlighted session (`kill <name>? (y/n)` confirm → kill + refresh) · `Esc`/`q` cancel. `display-menu` is the no-`display-popup` fallback. 8 suites pass: `for t in tests/test-*.fish; fish $t; end`. All functionality is under `tmux-lives <verb>` — top-level (help-page order): meta cluster `help` · `setup` · `update` then session cluster `new/attach/picker/fix/categorize/clear/close` (short aliases `u`=update, `n/a/p/f/c/x|q`; `fix` was renamed from `fixssh`); **`categorize`/`c`** re-runs `__tmux_categorize` to fix a mis-named session (e.g. macOS version-named claude); **hidden shortcut**: the setup subcommands (`install/i`, `verify/v`, `teardown`, `keys`, `auto`) also work at top level (`tmux-lives auto on` == `tmux-lives setup auto on`) — kept OUT of the help on purpose; **`new`/`n`** no-name path is hardened (guards an empty `#{session_id}` before `switch-client`); setup group: `setup install/verify/teardown/keys/auto` (old `start` and `take` removed; `verify`/`teardown`/key-flags/`auto` nested under `setup`). Help page uses **alias-first columns** (`__tmux_lives_help_lines` renders each row with `printf '%-3s%-28s%s'` = shortcut · command+args · description) so the short forms line up in a left rail; the `help` row was removed (redundant — you already found it). `close` shows only `x` in the help though `q` still routes. Meta cluster is `setup` then `update`, then the session cluster `new/attach/picker/fix/categorize/clear/close`. Both `tmux-lives help` and `tmux-lives setup -h` are framed in a rounded, orange (256-color 208) box via **`__tmux_lives_box`** (title in the top edge, frame orange + title default-fg); content lives in `__tmux_lives_help_lines`/`__tmux_lives_setup_help_lines` (kept separate from the frame so ordering/content is testable on the unframed text). Setup-help descriptions were tightened so the framed page fits 80 cols (was up to 104). NB for `__tmux_lives_box`: it measures width with `string length --visible` (display columns) and pads via a **quoted** var — an inline `(string repeat -n 0 …)` expands to ZERO args and shifts the trailing printf fields (silently broke the colored right border on max-width rows). **`update`/`u`** wraps `fisher update bit-saver/tmux-lives` and reports whether anything changed — it cksum-digests the installed files before/after and prints "already up to date" vs "updated — exec fish", setting a `_tmux_lives_updating` flag that silences the generic post-update event note so there's no double/contradictory message (direct `fisher update` still gets the generic note). fisher always reinstalls (re-`curl`s the HEAD tarball — no version check; confirmed in fisher 4.4.8 source), so `update` **diverts fisher's noisy output to a temp file (a `>file` redirect, NOT a `(…)` capture — that would break fisher's background-job fetch) and only surfaces it when the files changed or fisher failed** — a no-op update is one quiet line. `tmux-lives setup install` wires `~/.tmux.conf` + TPM plugins; `tmux-lives setup keys [-p/-s]` configures key bindings; `fisher install`/`update` print post-install/update guidance.

### Live wiring (the cutover, done 2026-06-19 — REAL fisher install)
- Installed via `fisher install bit-saver/tmux-lives` → files live at `~/.config/fish/{conf.d/tmux.fish,
  conf.d/tmux-lives-install.fish, functions/tmux-categorize.fish}`, tracked in `fish_plugins` + `_fisher_plugins`.
- `conf.d/tmux.fish` resolves the categorizer via `$__fish_config_dir/functions/tmux-categorize.fish` (portable).
- `~/.tmux.conf` (hand-maintained, NOT via `tmux-lives setup` — would duplicate its existing resurrect/continuum/
  sensible/yank) hardcodes the bind paths to `~/.config/fish/functions/tmux-categorize.fish`. `tmux-lives setup` is
  for a FRESH host (e.g. the Mac); this host was reconciled in place.
- **Dev loop from here:** edit → `for t in tests/test-*.fish; fish $t; end` → commit + push. **Stop there.**
  Deployment to the live `~/.config/fish/` is **ALWAYS the user's `fisher update`** — they run it themselves in
  their interactive fish.
- 🚫 **A Claude session does NOT deploy.** Finished changes reach the live `~/.config/fish/` ONLY via the user's
  `fisher update` — never `cp` a finished change into `conf.d/`/`functions/` to make it "live," and don't edit
  `~/.tmux.conf` or set universal vars to ship something. (`fisher install/update` also HANGS in the Claude bash
  sandbox anyway — but the rule stands regardless: the user always deploys.) If a change "needs to be live to
  verify," push it and ask the user to `fisher update`.
- ✅ **Temporary test edits are allowed — but revert EXACTLY.** You may patch a live fisher file to observe a
  behavior in development, on one strict condition: restore it **byte-identical** to its fisher-install state
  afterward and confirm with a diff. Clean restore: `git show <installed-commit>:<path> > <live-path>` then
  `diff` to verify zero drift. Leaving the live copy desynced from what fisher installed is the thing to avoid
  (fisher treats its files as static; drift makes it unclear which copy is authoritative).

**macOS port (spec 2): implemented** — runtime-only persistence (no launchd units; continuum autosave + first-access restore), `/proc`→`ps` detection (`__tcz_pid_comm`/`__tcz_pid_cmdline`), bare cold-start on first attach. **Pending:** live Mac smoke (categorize as claude, cold-start, reboot-restore). On the Mac: `fisher install bit-saver/tmux-lives` + run `tmux-lives setup install` (binds `prefix S` + `Opt+s` by default; use `tmux-lives setup keys -p/-s` to customize).

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
