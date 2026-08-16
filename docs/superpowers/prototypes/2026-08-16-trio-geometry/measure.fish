#!/usr/bin/env fish
# Measurement probes for the 2026-08-16 trio-geometry design record.
# READ-ONLY and PURE: __tmux_lives_theme_palette touches no universals and no
# tmux server, so none of this can affect a running install.
#
#   fish measure.fish surfaces [seed]   distinguishable appearances, by terminal
#   fish measure.fish big3     [seed]   pairs repeating 2 of 3 big colours  <- the target metric
#   fish measure.fish tabscap  [seed]   tabs-vs-cap separation, all rows, worst first
#   fish measure.fish seeds             the collision across five seed hues (systemic proof)
#   fish measure.fish within   [seed]   closest pair among bar/tabs/cap inside one scheme
#
# Default seed is the user's live one at the time of the study, #97cb38.
# Every number quoted in ../../specs/2026-08-16-trio-geometry-design.md comes
# from here; re-run to reproduce or to re-measure after an engine change.

source (status dirname)/../../../../conf.d/tmux-lives-install.fish

set -l mode $argv[1]
set -l seed $argv[2]
test -n "$seed"; or set seed '#97cb38'

function _ok -a hex
    set -l r (__tmux_lives_hex_to_rgb01 $hex)
    __tmux_lives_rgb_to_oklch $r[1] $r[2] $r[3]
end
function _dh -a a b
    set -l d (math "abs($a - $b)")
    test $d -gt 180; and set d (math "360 - $d")
    echo $d
end
# name|bar|sep|tabs|active|windows|cap|text for every catalog row
function _rows -a seed
    for line in (__tmux_lives_theme_catalog)
        set -l f (string split '|' -- $line)
        set -l p (__tmux_lives_theme_palette "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
        test (count $p) -eq 7; or continue
        echo "$f[1]|$p[1]|$p[2]|$p[3]|$p[4]|$p[5]|$p[6]|$p[7]"
    end
end

switch "$mode"
    case surfaces
        # ShellFish paints the tab strip (all 7 roles visible); cmux paints no
        # tab colour, so `tabs` is invisible there and rows can collide.
        set -l sf; set -l cm; set -l n 0
        for r in (_rows $seed)
            set -l g (string split '|' -- $r); set n (math $n + 1)
            set -a sf "$g[2]$g[3]$g[4]$g[5]$g[6]$g[7]$g[8]"
            set -a cm "$g[2]$g[3]$g[5]$g[6]$g[7]$g[8]"
        end
        printf 'seed %s   rows %d\n' $seed $n
        printf '  ShellFish (7 roles)      %2d distinct\n' (count (printf '%s\n' $sf | sort -u))
        printf '  cmux (6, no tab colour)  %2d distinct\n' (count (printf '%s\n' $cm | sort -u))
        echo 'cmux collision groups:'
        for k in (printf '%s\n' $cm | sort | uniq -d)
            set -l m
            for r in (_rows $seed)
                set -l g (string split '|' -- $r)
                test "$g[2]$g[3]$g[5]$g[6]$g[7]$g[8]" = "$k"; and set -a m $g[1]
            end
            printf '  %s\n' (string join ' = ' $m)
        end

    case big3
        # THE TARGET METRIC. The user's criterion, 2026-08-16: "little to no
        # repetition of 2 colors in the same placements" -- i.e. no two schemes
        # should share 2 or more of bar/tabs/cap. Sharing exactly 1 is fine.
        set -l names; set -l B; set -l T; set -l C
        for r in (_rows $seed)
            set -l g (string split '|' -- $r)
            set -a names $g[1]; set -a B $g[2]; set -a T $g[4]; set -a C $g[7]
        end
        set -l n (count $names)
        printf 'seed %s   schemes %d\n' $seed $n
        printf 'distinct per placement:  bar %d   tabs %d   cap %d   (ideal %d)\n' \
            (count (printf '%s\n' $B | sort -u)) (count (printf '%s\n' $T | sort -u)) \
            (count (printf '%s\n' $C | sort -u)) $n
        set -l s3 0; set -l s2 0; set -l bad
        for i in (seq 1 $n)
            for j in (seq (math $i + 1) $n)
                set -l m 0
                test "$B[$i]" = "$B[$j]"; and set m (math $m + 1)
                test "$T[$i]" = "$T[$j]"; and set m (math $m + 1)
                test "$C[$i]" = "$C[$j]"; and set m (math $m + 1)
                test $m -ge 3; and set s3 (math $s3 + 1)
                test $m -eq 2; and set s2 (math $s2 + 1); and set -a bad "$names[$i] = $names[$j]"
            end
        end
        printf 'pairs sharing all 3 : %d\n' $s3
        printf 'pairs sharing 2 of 3: %d\n' $s2
        for b in $bad; echo "   $b"; end
        echo 'also: pairs sharing a bar but differing in INK (0 => ink is a pure function of bar):'
        set -l viol 0
        set -l rows (_rows $seed)
        for i in (seq 1 (count $rows))
            set -l a (string split '|' -- $rows[$i])
            for j in (seq (math $i + 1) (count $rows))
                set -l b (string split '|' -- $rows[$j])
                test "$a[2]" = "$b[2]"; or continue
                test "$a[3]$a[5]$a[6]$a[8]" != "$b[3]$b[5]$b[6]$b[8]"; and set viol (math $viol + 1)
            end
        end
        printf '   %d\n' $viol

    case tabscap
        # dH(tabs,cap) = | |travel| - max(|travel|/2, family) |, which is EXACTLY
        # zero when |travel| = family. Plus capL = barL+0.10 vs tabsL = barL+0.11,
        # so derived rows are pinned 0.01 apart in depth no matter the seed.
        printf 'seed %s -- tabs vs cap, worst first\n' $seed
        printf '%-13s %-8s %6s %8s %6s\n' scheme mode dL dC dH
        for line in (__tmux_lives_theme_catalog)
            set -l f (string split '|' -- $line)
            set -l p (__tmux_lives_theme_palette "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
            test (count $p) -eq 7; or continue
            set -l t (_ok $p[3]); set -l c (_ok $p[6])
            printf '%.1f|%-13s %-8s %6.3f %8.4f %6.1f\n' (_dh $t[3] $c[3]) $f[1] $f[4] \
                (math "abs($t[1]-$c[1])") (math "abs($t[2]-$c[2])") (_dh $t[3] $c[3])
        end | sort -t'|' -k1 -g | cut -d'|' -f2

    case seeds
        # Systemic proof: the collision is not a green-seed quirk. It moves to
        # whichever relationship matches that hue's `family` value.
        for s in '#97cb38' '#c9782f' '#2f9ec9' '#a8407f' '#c94040'
            set -l o (_ok $s)
            printf '\nseed %s  hue %5.1f  family %s\n' $s $o[3] (__tmux_lives_theme_family $o[3])
            set -l hits 0
            for line in (__tmux_lives_theme_catalog)
                set -l f (string split '|' -- $line)
                set -l p (__tmux_lives_theme_palette "$s" "$f[2]" "$f[3]" "$f[4]" 0)
                test (count $p) -eq 7; or continue
                set -l t (_ok $p[3]); set -l c (_ok $p[6])
                set -l d (_dh $t[3] $c[3])
                test $d -lt 10; or continue
                set hits (math $hits + 1)
                printf '    %-13s dH %4.1f  dL %.3f\n' $f[1] $d (math "abs($t[1]-$c[1])")
            end
            printf '  -> %d of 35 within 10 deg\n' $hits
        end

    case within
        printf 'seed %s -- closest pair among bar/tabs/cap inside each scheme\n' $seed
        for line in (__tmux_lives_theme_catalog)
            set -l f (string split '|' -- $line)
            set -l p (__tmux_lives_theme_palette "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
            test (count $p) -eq 7; or continue
            set -l b (_ok $p[1]); set -l t (_ok $p[3]); set -l c (_ok $p[6])
            set -l mn (math "abs($b[1] - $t[1])"); set -l w 'bar~tabs'; set -l mh (_dh $b[3] $t[3])
            set -l x (math "abs($b[1] - $c[1])")
            test $x -lt $mn; and set mn $x; and set w 'bar~cap'; and set mh (_dh $b[3] $c[3])
            set x (math "abs($t[1] - $c[1])")
            test $x -lt $mn; and set mn $x; and set w 'tabs~cap'; and set mh (_dh $t[3] $c[3])
            printf '  %-13s closest %-9s dL %.3f  dH %5.1f\n' $f[1] $w $mn $mh
        end

    case '*'
        echo 'usage: fish measure.fish surfaces|big3|tabscap|seeds|within [seed]' >&2
        exit 1
end
