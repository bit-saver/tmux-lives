# ShellFish "Status Bar — Missing color." — findings from the macwork fish session

From: the `~/.config/fish` session on macwork, 2026-09-23. Read-only diagnosis; nothing in tmux-lives, on either machine, was changed. Written at the user's request so this session has what the macwork side found. The investigation started in the `~/projects/claude` session on macwork (its handoff, `~/.claude/session-data/2026-09-22-fish-config-shellfish-missing-color-handoff.tmp` on macwork, is summarised here so you don't need it).

## Symptom

On the iPad (Secure ShellFish, tabs attached to tmux), a native alert **"Status Bar" / "Missing color."** appears intermittently. First captured 2026-09-19 19:14 over a macwork tab. The user says it appears **on switching to a tab**. Still open: whether that means switching iPad ShellFish tabs (which may reconnect, so `client-attached` fires) or switching tmux sessions inside one tab (`client-session-changed`). The answer decides which path below is the prime suspect.

## Versions checked

- macwork runs the fisher-installed copy of `functions/tmux-categorize.fish` (sha1 `f4497ed…`). rocket's `~/workspace/tmux-lives` HEAD `9b58245` has `dc04a3d…`. They differ (at least by `5076e04`, the OSC 0 title change), but **every line cited below is identical at the same line numbers in both**, so the findings hold for HEAD.

## What was established (verified against HEAD)

1. **The colour value is never bad.** `__tcz_emit_barcolor` (`:440-443`) guards an empty colour, base64-encodes with `printf '%s' … | base64 | string join ''` (macOS `base64` adds a trailing `\n`; command substitution plus `string join` strips it), and writes `ESC ]6;settoolbar://?ver=2&color=<b64> BEL`. Every caller resolves the colour through `__tcz_tab_color` (`@tmux_lives_tabs_color`, else the hook's `'#5bbf93'`). On macwork the emit cache holds `"#4f6f5f"` for all four ShellFish ttys. No path can send an empty value, an unexpanded `#{…}`, or a colour name.
2. **It is written straight to the client tty, not through tmux.** `> $tty`, no DCS passthrough, no lock. So it races tmux's own output on that pty.
3. **`commandeer` never sets a colour.** `__tcz_commandeer` (`:1196-1232`) only calls `switch-client`. The old handoff's "attach plus commandeer double-emit" hypothesis is dead. `retitle` emits titles only (and those are also raw tty writes).
4. **Who does emit:**
   - `on-attach` → `__tcz_on_attach` (`:4066`): for ShellFish it emits, then writes the cache (`__tcz_emit_set`), then retitles. It runs as a separate `run-shell` process from the `client-attached` hook.
   - `tick` (`:4370-4374`), via `status-right` `#(…)` every `status-interval` (15s on macwork): `__tcz_recolor … dedup` (emits only when the cached colour differs), then when `__tcz_heal_due` fires (every `@tmux_lives_heal_interval`, 120s) an un-deduped `__tcz_recolor` that **re-emits to every ShellFish client on the server**.
5. **Possible double-send on attach (plausible, not verified):** `on-attach` emits *before* it writes the cache. If the new client's first status draw starts its own `tick` in that window, the tick reads a stale cache and emits again. That gives two processes writing the same OSC to the same tty during tmux's full-screen redraw for the new client. Whether a newly attached client's first redraw starts `#()` jobs immediately is tmux behaviour nobody has checked yet.

## Leading hypothesis

At the attach or switch moment, tmux is writing a full redraw to the tty while one or two separate processes write the raw OSC into the same pty. If their writes interleave, ShellFish parses a `settoolbar` URL whose `color` is cut off or missing, and reports "Missing color". That fits both the trigger (tab switch) and the intermittency. **Unproven. No emission has yet been correlated with a popup.**

## ⚠ A second live sender, outside tmux-lives — check this first

The earlier handoff said rocket's malformed `barcolor=` line was commented out. **Only half of that block is.** rocket `~/.config/fish/config.fish:40,53-58`:

```fish
set -g barcolor 99AA33
...
if functions -q setbarcolor
  if status is-interactive; and isatty stdout
    # printf '\e]6;settoolbar://?ver=2&barcolor=%s\a' $barcolor
    setbarcolor $barcolor
  end
end
```

`setbarcolor` is defined by ShellFish's integration (`conf.d/shellfish.fish:272`) only when `LC_TERMINAL=ShellFish`, so **every interactive fish that starts on rocket inside a ShellFish tab sends `settoolbar://?ver=2&color=<base64 of "99AA33">`**. ShellFish's own usage text lists valid values as `red, #f00, #ff0000, rgb(…)`; bare `99AA33` has no `#`, so it is probably not a colour ShellFish can parse. (The helper also leaves `base64`'s trailing newline before the BEL, but that is ShellFish's own code and presumably tolerated.) If a ShellFish tab switch reconnects, it starts a fresh shell on rocket and would fire this every time.

This is fish config, not tmux-lives: the macwork fish session is reporting it here only because it bears on your investigation. Fixing it belongs to whoever owns rocket's `~/.config/fish`, and the user can make that change.

**10-second discriminating test (user, in a ShellFish tab on rocket):** `setbarcolor 99AA33`, then `setbarcolor '#99AA33'`. If the first pops "Missing color" and the second doesn't, this is the cause (or a cause), and the tmux-lives race below may be a red herring. It does not explain popups over macwork tabs unless those tabs also start a shell on rocket; macwork's config calls `setbarcolor` nowhere.

## Also ruled out

- macwork's `rocket_config.fish` is a stale copy that nothing sources.
- On macwork, `conf.d/shellfish.fish` / `functions/shellfish.fish` never emit `settoolbar` automatically.

## Suggested next step (yours to decide)

Evidence before a fix: log each emission from `__tcz_emit_barcolor` (timestamp with ms, tty, caller — attach, tick-dedup or tick-heal — and the exact bytes). The user then switches tabs until the popup appears and notes the time. Two emissions within a few ms for one switch points at the attach-versus-tick double-send; a single clean emission points at tearing against tmux's redraw.

Fix shapes to weigh once the log says which: write the cache before emitting (or have on-attach claim the tty) so the tick cannot double-send; defer the attach emission until after the redraw (`run-shell -b` plus a short delay); serialise per-tty emits with a lock. Note that DCS passthrough only applies to output from a pane's program, so a hook-run process has no pane to pass through. Getting the OSC into tmux's own output stream would need a pane-side emitter.
