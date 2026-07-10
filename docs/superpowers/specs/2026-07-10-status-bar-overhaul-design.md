# Design — status-bar overhaul (centered identity, powerline caps, mode indicators)

**Date:** 2026-07-10
**Status:** Designed (approved in brainstorming → writing-plans next)
**Repo:** tmux-lives (`conf.d/tmux-lives-install.fish` fragment + baseline, `functions/tmux-categorize.fish`)
**Builds on:** the machine-managed fragment (`__tmux_lives_render_fragment`), the ShellFish-derived `status-style` (`__tmux_lives_derive_status`), the `#(tick)` self-heal + continuum autosave in `status-right`, the `~/.tmux-lives.conf` baseline (`__tmux_lives_baseline_template`), the `tmuxlives-resize` key-table (`M-r`), and the client-environ detection used for ShellFish (`__tcz_pid_environ`).

## Why

The current status bar (left `❯ #{session_name}`, `#I:#W` windows, right 12h clock) is functional but the user finds their own tweaks unsatisfying and wants a deliberate, better-looking bar. Three concrete needs emerged: (1) the important identity (session / display name / Claude name) should sit **dead-center**; (2) a clear **host indicator** — on the Mac, "am I on `rocket` (SSH) or local?" is not obvious; (3) **mode feedback** — a prefix indicator, and especially a resize-mode indicator, because after `M-r` scratch-resize the user is "never sure if I've properly exited." A polished, icon-driven bar (Nerd Font available everywhere) addresses all three while preserving the functional plumbing (ShellFish color, self-heal tick, continuum, position/visibility toggles).

## Goals

- **Centered identity**: `<display-name> ✦ <claude-name>` dead-center. `✦` marks a Claude session; display name = `@tmux_lives_name` → else session name; Claude name = `claude --name`.
- **Ends-only powerline**: a **host cap** far-left and a **clock cap** far-right (colored powerline segments in the ShellFish-derived color); everything between is flat.
- **Host cap** always shows the hostname + a **remote/local glyph** (`cod-remote` when SSH, `cod-vm` when local), so `rocket`-over-SSH is unmistakable from the local Mac.
- **Windows** flat on the left, **names only** (no `#I:` index), `•`-separated, current window bold.
- **Clock cap**: existing 12h month-first format, `·`-separated fields.
- **Purposeful separators**: `✦` = Claude mark (not a separator), `•` = between windows, `·` = between fields.
- **Prefix indicator**: while the prefix is held, the caps take an accent color and a `❯` appears center ("tmux is awaiting a command").
- **Resize indicator**: while in the `tmuxlives-resize` key-table, the caps take a distinct accent and a persistent `◇ RESIZE ◇` tag (with the live keys) shows center — visible until the instant you exit.
- **Preserve all plumbing**: ShellFish per-host `status-style`, the invisible `#(tick)` (self-heal / retitle / bar-color re-emit), continuum autosave, and the `C-M-a`/`C-M-s` position/visibility toggles keep working unchanged.
- **Live-tunable**: accent colors and host glyphs are read from tmux `@options`, so `tmux set -g @tmux_lives_prefix_color …` retunes the bar with no re-render.
- **Testable** without mutating the live server (the project's isolation invariant): a pure format-string builder + pure helpers, plus a `-L`-socket parse check.

## Non-goals (YAGNI)

- No configurable separator glyphs (✦/•/· are fixed) and no configurable zone order — the layout is opinionated. (Colors and host glyphs *are* configurable.)
- No per-client SSH detection inside the format (tmux exposes no `#{client_ssh}`); the remote/local glyph is a **per-host** determination (see Design), which matches the user's "rocket = remote server, Mac = local" reality.
- No multi-line status bar (`status-format[1]`), no mouse-region features beyond preserving existing window click-select where feasible.
- No change to resurrect/continuum behavior, the categorizer, the picker, or the modal.

## Design

### Layout mechanism — `status-format[0]` with three align zones

tmux centers only the window list, so true left/center/right requires overriding **`status-format[0]`** with `#[align=left/centre/right]`:

- **left zone** — host cap (powerline) + the window list (`#{W:…}` iteration, names-only, `•` between, current bold).
- **centre zone** — identity, plus the prefix `❯` and the `◇ RESIZE ◇` badge (conditionals).
- **right zone** — clock cap (powerline) that **renders `status-right`** via `#{T;=/#{status-right-length}:status-right}`.

Rendering `status-right` inside the right zone is what preserves the plumbing: `status-right` stays `#{T:@tmux_lives_status_right}#(… tick …)` and continuum still prepends its autosave hook when TPM runs — both invisible, both inside the clock cap. `status-style` (ShellFish color) is unchanged and provides the bar background + the cap base color.

The fragment sets `status-format[0]` **after** sourcing `~/.tmux-lives.conf`, so the baseline can't clobber it. Existing users' old baseline `status-left`/`window-status-format` lines become harmless no-ops (nothing references them once `status-format[0]` is overridden).

### The format is built by a pure function

A new pure builder — `__tmux_lives_status_format <accent-opt-names> <glyph-opt-names> …` (exact signature in the plan) — returns the `status-format[0]` string from its inputs, calling **no tmux**. `__tmux_lives_render_fragment` calls it and emits `set -g status-format[0] "<string>"`. This keeps the (large, fiddly) format string unit-testable: assert it contains the three `#[align=…]` zones, the `#{W:…}` window iteration with `•`/no-index, the `✦`/`·` separators, the `#{?client_prefix,…}` and `#{?#{==:#{client_key_table},tmuxlives-resize},…}` conditionals, and that the right zone references `status-right`.

### Host cap — hostname + remote/local glyph

- Always shows `#{host_short}` (or the cached `__tcz_hostname`) — the hostname alone already disambiguates `rocket`/`macwork`.
- The glyph is chosen by `@tmux_lives_host_kind` (`remote`|`local`), referenced in the format as `#{?#{==:#{@tmux_lives_host_kind},remote},<remote-glyph>,<local-glyph>}`.
- **Default detection**: on setup/attach, if unset, tmux-lives sets `@tmux_lives_host_kind` from whether the environment shows an SSH connection (`SSH_CONNECTION`/`SSH_TTY`; reuse the client-environ read that ShellFish detection already uses). Per-host by nature (the Mac's server resolves `local`, rocket's resolves `remote`). **Overridable** via a `setup` flag / `@option`.
- Glyphs come from `@tmux_lives_glyph_remote` / `@tmux_lives_glyph_local` (defaults: `cod-remote` ``, `cod-vm` ``), so they're swappable live (e.g. try `md-ssh`).

### Identity, windows, clock

- **Identity** (centre): `#{?#{!=:#{@tmux_lives_name},},#{@tmux_lives_name},#{session_name}}` then, when the session runs Claude, ` ✦ <claude-name>`. Claude detection + name reuse the categorizer's existing session-scoped logic (a session `@option` the tick already maintains, or `__tcz_session_has_claude` surfaced as an `@option` — decided in the plan; the format must be pure tmux, so any process inspection is pushed to the tick which writes an `@option`).
- **Windows** (left): `#{W:<not-current fmt>,<current fmt>}` → `#W` name only, `•` separator, current bold; drop `#I`.
- **Clock cap** (right): unchanged `@tmux_lives_status_right` = `%-I:%M %p · %b %-d`, wrapped in the powerline cap.

### Prefix + resize indicators

Pure format conditionals in the centre + caps:
- **Prefix**: `#{?client_prefix, …accent… ❯ , …normal… }` — caps recolor to `@tmux_lives_prefix_color`, a `❯` prefixes the identity.
- **Resize**: `#{?#{==:#{client_key_table},tmuxlives-resize}, …accent… ◇ RESIZE ◇ …keys… , …identity… }` — caps recolor to `@tmux_lives_resize_color`, identity is replaced by the badge + a short key hint (`arrows move · x kill · esc/enter done`). Both are per-client (`client_prefix`/`client_key_table` are client-scoped), so only the client actually in that state sees it.

### Config surface (all live-tunable `@options`, with defaults baked by the fragment)

`@tmux_lives_prefix_color`, `@tmux_lives_resize_color` (default amber family, e.g. `colour214`/`colour208`); `@tmux_lives_host_kind`; `@tmux_lives_glyph_remote`/`_local`; existing `@tmux_lives_status_right`. Defaults set in the fragment/baseline; the format reads the `@options` so `tmux set -g @… …` retunes without a re-render. A thin `setup` surface (e.g. `setup bar --prefix-color …`, `--host-kind …`) persists chosen values as universals baked on the next render — consistent with `setup color`.

### Ownership shift + where code lives

- **`conf.d/tmux-lives-install.fish`**: `__tmux_lives_render_fragment` emits `set -g status-format[0] "…"` (from the new pure builder) after sourcing the baseline; keeps the existing `status-right`/`status-style`/tick/continuum/toggle lines. New pure `__tmux_lives_status_format` builder. `__tmux_lives_baseline_template` **drops** the `status-left`/`window-status-format`/`window-status-current-format`/`-style` lines (now owned by the fragment) and keeps the clock `@var` + any user-owned prefs; seeds the new `@option` defaults.
- **`functions/tmux-categorize.fish`**: host-kind detection helper (SSH-env read, likely folding into `__tcz_on_attach`), and — if Claude name/flag must reach the pure format — the tick writes a session `@option` (e.g. `@tmux_lives_claude`) the format reads.

## Testing & isolation (hard invariant)

Pure / seam-based, no live-server mutation:
- **`__tmux_lives_status_format`** (pure): assert the three `#[align=…]` zones present and ordered; window iteration is names-only with `•`; `✦`/`·` in their roles; `#{?client_prefix…}` and `#{?#{==:#{client_key_table},tmuxlives-resize}…}` conditionals present with the accent `@options`; right zone references `status-right` (so tick/continuum survive); host cap references `@tmux_lives_host_kind` + the glyph `@options`.
- **host-kind detection** (pure/seam): with `tmux_lives_fake_environ` containing `SSH_CONNECTION=…` → `remote`; without → `local`; explicit override wins.
- **fragment render** (`tests/test-tmux-install.fish`): the rendered fragment contains the `status-format[0]` line and still contains the `status-right` tick + continuum plugin + `status-style`; and the rendered fragment **parses** on a private `-L` socket (`source-file` rc0), as the existing status/resize fragment-parse tests already do.
- **baseline template**: no longer emits `status-left`/`window-status-format`; still emits the clock `@var`.

## Rollout

Ships via the user's `fisher update` (never a Claude deploy); getting new fragment wiring live is `fisher update` + any `setup` action (or `fisher update` alone — the post-update handler re-renders). Existing users keep their `~/.tmux-lives.conf`; the old status-left/window lines become no-ops, but a `setup conf reset` gets the lean new baseline. Runtime smoke: centered identity; host cap shows hostname + correct glyph on rocket vs Mac; windows names-only `•`; prefix press → caps glow + `❯`; `M-r` → amber caps + `◇ RESIZE ◇` that clears on exit; ShellFish color, tick self-heal, continuum, and `C-M-a`/`C-M-s` toggles all still work.

## Decisions / open questions

- **Window index dropped** (names only) — confirmed.
- **Fragment owns `status-format[0]`** (layout moves out of the user baseline) — confirmed.
- **Prefix/resize accents = live-tunable `@options`, default amber family** — the user will judge the exact colors in action and retune via `tmux set -g @…`.
- **Remote/local glyph is per-host** (`@tmux_lives_host_kind`, SSH-auto-detected, overridable) — not per-client, since tmux exposes no per-client SSH format.
- **Glyphs**: `cod-remote` (remote) / `cod-vm` (local) defaults; `md-ssh` rejected (tiny baked lettering illegible at bar size); swappable via `@option`.
- **Claude name/flag into the pure format**: via a session `@option` the tick maintains (keeps the format tmux-only) — exact var named in the plan.
