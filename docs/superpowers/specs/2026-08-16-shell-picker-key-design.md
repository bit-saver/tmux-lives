# Shell-side switcher key — design record and decision register

**Status: SHIPPED to `main` @ `817828a`** (2026-08-16). Bounded change, built TDD, reviewed, mutation-proven. Reaches the machines on the next `fisher update`.

This is "Part A" of a two-part workflow proposition. Part B — federating rocket's and macwork's session lists into one picker — is **not started** and is deliberately deferred until Part A has been lived with. See the end of this file.

## The problem, and its actual cause

Pressing Opt+S at a bare prompt *outside* tmux dropped a stray `sudo …` on the command line. The user's framing was that Ghostty/cmux/iTerm2 needed the shortcut commandeering.

The real cause is neither the terminals nor tmux. **fish binds `alt-s` itself**, as a preset:

```
bind --preset alt-s 'for cmd in sudo doas please run0; if command -q $cmd; fish_commandline_prepend $cmd; break; end; end'
```

`fish_commandline_prepend` recalls the PREVIOUS commandline when the current one is empty, so at a bare prompt it pulls back your last command and prefixes `sudo`. Reproduced on a pty: it produced `sudo vi cap.fish` and sat at a password prompt until killed.

**Consequence for the design: the fix belongs in fish, not in the terminals.** One binding covers Ghostty, iTerm2, cmux and ShellFish, and it is dormant inside tmux whenever the managed fragment is installed with a matching key, because tmux's root-table `bind -n M-s` consumes the key before the pane shell sees it. The same key therefore means the same thing in and out of tmux with no coordination between them.

`tmux-lives picker` outside tmux already ensured a server, categorized, and opened the popup (`conf.d/tmux.fish:185`), so the change only puts existing behaviour on a key.

## Decision register

Same contract as the trio-geometry register: when the shipped thing is criticised, look up the symptom and the alternatives are already listed. `claude` decisions are ones the user delegated on 2026-08-16 ("I'd prefer to let you tackle all of these details… I'll decide once I start seeing what it will look like").

| ID | Decision | Who | Why | Alternatives if criticised | Symptom that points here |
|---|---|---|---|---|---|
| K1 | Bind in **fish**, not in Ghostty/iTerm2 config | claude | one binding covers every terminal, and it is dormant inside tmux automatically | per-emulator keybinds; a wrapper script | the key behaves differently between terminals |
| K2 | Do **not** define `fish_user_key_bindings` | claude | the user defines it themselves (binds `\cl`); a plugin defining it silently clobbers theirs | own the function and call the user's from it | Ctrl+L or another personal binding stops working |
| K3 | Derive the key from the existing `tmux_lives_switcher_key` | claude | configuring one configures both; the same key in and out of tmux | a separate `tmux_lives_shell_key` universal | user wants different keys in and out of tmux |
| K4 | Only `M-<single char>` translates; anything else does not bind | claude | `C-M-a`, `M-Space` have no unambiguous fish spelling; guessing is worse than declining | translate more forms; error loudly instead of silently declining | a configured key silently does nothing outside tmux |
| K5 | Action puts `tmux-lives picker` on the line and executes it | claude | behaves like a typed command — visible, errors surface normally, repeatable | call the function directly from the binding | the command appearing in history or on screen is unwanted |
| K6 | Refuses to fire over typed input | claude | the picker `exec`s into tmux, so typed input would be lost with no way back | fire anyway; stash and restore (impossible across exec) | "I pressed it and nothing happened" |
| K7 | Also `bind -M insert` | claude (review-found) | fish's preset occupies insert/default/visual; default-only is listed but unreachable for vi users, who start in insert | bind all modes explicitly; detect the mode | vi users still get the sudo hijack |
| K8 | Uppercase custom keys unhandled under the kitty protocol | claude | `M-S` arrives as `alt-shift-s` there, not `alt-S`; the default `M-s` is fine in both encodings | translate to `alt-shift-<c>` when uppercase | an uppercase custom key does nothing in kitty-protocol terminals |
| K9 | pty harness runs under `TERM=dumb` | claude | fish waits out unanswered capability queries for ~10.4s per spawn; 10424ms → 275ms, suite 55s → 10s | accept the cost; answer the queries | a pty test starts behaving oddly and TERM is suspected |
| K10 | Part B (host federation) deferred, not designed | user | ship the small fix, live with it, then judge whether the remaining friction earns the complexity | design both together | "I still have to `sshr` first" |

## What is NOT solved

A **fresh local tab that is not SSHed anywhere** still needs `sshr` before the key gets you rocket's sessions. In a tab already SSHed to rocket the key works there, because tmux-lives is installed on both machines. Closing the remaining gap is Part B.

## Testing notes

21 assertions in `tests/test-tmux-auto.fish`. The behavioural half needs a pty because no grep can see a keypress.

**Three things in that harness are load-bearing, each found by the harness failing to discriminate:**

1. `XDG_DATA_HOME` must be redirected. fish history lives there and the suite's isolation guard covers `XDG_CONFIG_HOME` **only**, so without it every simulated keypress lands in the user's real `fish_history` — which happened during development and had to be cleaned.
2. History must be **seeded**. The preset prepends to the PREVIOUS commandline; with an empty history it is a no-op, so "no longer prepends sudo" passed against unfixed code.
3. `sudo` must be **faked onto PATH**. The preset gates on `command -q sudo`, so a stub satisfies it, and executing the recalled line then hits the stub instead of blocking on a real password prompt.

Also: `tmux-lives` had to be stubbed as a **function**, not a PATH binary. fish resolves functions before `$PATH`, so a stub binary was silently ignored and the real dispatcher ran.

**Seven mutations, all caught, each discriminating:** no bind (2 assertions), empty-prompt guard removed (1), permissive regex (5), wrong fish prefix (8), no `-M insert` (2), wrong dispatched verb (2), empty-key guard removed (1).

**Two of my own tests were vacuous before mutation exposed them:** the empty-prompt guard test used Ctrl-C, which cancels the very execution `commandline -f execute` queues, so it could not tell the two states apart; and the fired-assertion matched only the marker and not the verb, so dispatching `clear` — a sibling verb that kills idle sessions — passed the whole gate.

## Process note worth carrying

**Never use `git checkout` to revert a mutation while the work is uncommitted.** Doing so reverted to HEAD and destroyed the implementation; three of four mutation results in that run were consequently meaningless and looked plausible. Restore from a file copy and assert byte-identity afterwards.
