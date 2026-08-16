#!/usr/bin/env fish
# PROTOTYPE ONLY — throwaway. Implements the proposed "accent outside the pair"
# trio geometry so a mockup can render REAL computed colour instead of guesses.
# Nothing here is installed; the shipped engine is untouched.
source /home/bitsaver/workspace/tmux-lives/conf.d/tmux-lives-install.fish

# --- calibratable constants (starting values; the blind study fits these) -----
set -g P_D1   0.11    # bar -> tabs lightness step
set -g P_D2   0.11    # tabs -> cap lightness step  (today this is effectively -0.01)
set -g P_CBAR 0.045   # bar chroma base
set -g P_CTAB 0.0713  # tabs chroma base
set -g P_CCAP 0.0713  # cap chroma base (today = bar's, i.e. the DULLEST of the three)

function _p_ok -a hex
    set -l r (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $r[1] $r[2] $r[3]
end

# proposed: seed relationship place mode phase -> bar tabs cap
function proto_trio -a seedHex relationship place mode phase
    string match -qr '^#[0-9a-fA-F]{6}$' -- "$seedHex"; or return
    set -l sd (__tmux_lives_theme_reldef "$relationship"); test -n "$sd"; or return
    test -n "$phase"; or set phase 0
    set -l ok (_p_ok $seedHex)
    set -l sL $ok[1]; set -l sC $ok[2]; set -l sH $ok[3]

    set -l Ldamp (math "0.5 * ($sL - 0.51)")
    test $Ldamp -lt -0.10; and set Ldamp -0.10
    test $Ldamp -gt 0.10; and set Ldamp 0.10
    set -l Cscale (math "0.5 * ($sC / 0.078 - 1) + 1")
    test $Cscale -lt 0.6; and set Cscale 0.6
    test $Cscale -gt 1.4; and set Cscale 1.4

    # ---- hues: the anchor holds the seed hue, the partner travels by sd -------
    set -l Hbar $sH; set -l Htabs $sH
    switch "$place"
        case tabs; set Hbar (math "$sH + $sd")
        case cap;  set Htabs (math "$sH + $sd")   # pair placed together; cap anchors below
        case '*';  set Htabs (math "$sH + $sd")
    end

    # ---- the ACCENT sits BEYOND the pair, continuing away from the anchor ----
    # dir = anchor -> partner. At sd = 0 the pair is one hue, so default to +.
    set -l dir 1
    test $sd -lt 0; and set dir -1
    set -l k (__tmux_lives_theme_family $sH)   # starting accent offset; study refits
    set -l Hcap
    switch "$place"
        case tabs;  set Hcap (math "$Hbar + $dir * $k")    # beyond the bar (the traveller)
        case cap
            # the cap anchors: put the PAIR before it so the accent is still beyond.
            set Hcap  $sH
            set Htabs (math "$sH - $dir * $k")
            set Hbar  (math "$Htabs - $dir * $sd")
        case '*';   set Hcap (math "$Htabs + $dir * $k")   # beyond the tabs
    end

    # ---- depth: ABSOLUTE targets per role, monotonic, cap ABOVE tabs ---------
    # Absolute (not anchor-relative) so a bright seed can never lift the status
    # bar off its dark ground -- that is today's behaviour and it is correct.
    # The one change vs today: the cap moves from barL+0.10 (which lands ON the
    # tabs) to tabsL+d2, giving a genuine three-step ramp.
    set -l Lbar  (math "0.40 + $Ldamp")
    set -l Ltabs (math "$Lbar + $P_D1")
    set -l Lcap  (math "$Ltabs + $P_D2")
    test $Lbar  -lt 0.05; and set Lbar 0.05
    test $Lbar  -gt 0.95; and set Lbar 0.95
    test $Ltabs -lt 0.05; and set Ltabs 0.05
    test $Ltabs -gt 0.95; and set Ltabs 0.95
    test $Lcap  -lt 0.05; and set Lcap 0.05
    test $Lcap  -gt 0.95; and set Lcap 0.95

    # mode reaches the CAP via chroma, so literal/derived differ in the big 3
    # (not only in the placed role) -- this is what separates chip from slate.
    set -l capC (math "$P_CCAP * $Cscale")
    test "$mode" = literal; and set capC (math "$capC * 1.35")

    set -l bar  (__tmux_lives_oklch_hex $Lbar  (math "$P_CBAR * $Cscale") (__tmux_lives_norm360 (math "$Hbar + $phase")))
    set -l tabs (__tmux_lives_oklch_hex $Ltabs (math "$P_CTAB * $Cscale") (__tmux_lives_norm360 (math "$Htabs + $phase")))
    set -l cap  (__tmux_lives_oklch_hex $Lcap  $capC (__tmux_lives_norm360 (math "$Hcap + $phase")))

    # literal: the placed role renders the seed's exact hex
    if test "$mode" = literal
        set -l s (string lower -- $seedHex)
        switch "$place"
            case tabs; set tabs $s
            case cap;  set cap $s
            case '*';  set bar $s
        end
    end
    printf '%s\n' $bar $tabs $cap
end
