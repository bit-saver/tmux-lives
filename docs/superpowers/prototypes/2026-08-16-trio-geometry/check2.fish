source /tmp/claude-1000/-home-bitsaver-workspace-tmux-lives/75c340ac-07c0-4f40-9ddc-081f92efbdab/scratchpad/proto-trio.fish
set -l seed '#97cb38'
function _dh -a a b
    set -l d (math "abs($a - $b)"); test $d -gt 180; and set d (math "360 - $d"); echo $d
end
set -l names; set -l B; set -l T; set -l C
set -l worst 999
for line in (__tmux_lives_theme_catalog)
    set -l f (string split '|' -- $line)
    set -l p (proto_trio "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
    test (count $p) -eq 3; or continue
    set -a names $f[1]; set -a B $p[1]; set -a T $p[2]; set -a C $p[3]
    set -l t (_p_ok $p[2]); set -l c (_p_ok $p[3])
    set -l dh (_dh $t[3] $c[3]); test $dh -lt $worst; and set worst $dh
end
set -l n (count $names)
printf 'PROPOSED, seed %s, %d schemes\n\n' $seed $n
printf 'smallest tabs~cap hue gap : %.1f deg   (today 0.1)\n' $worst
printf 'distinct bar  : %2d / %d   (today 11)\n' (count (printf '%s\n' $B | sort -u)) $n
printf 'distinct tabs : %2d / %d   (today 11)\n' (count (printf '%s\n' $T | sort -u)) $n
printf 'distinct cap  : %2d / %d   (today 18)\n' (count (printf '%s\n' $C | sort -u)) $n
set -l s3 0; set -l s2 0
set -l bad
for i in (seq 1 $n)
    for j in (seq (math $i + 1) $n)
        set -l m 0
        test "$B[$i]" = "$B[$j]"; and set m (math $m + 1)
        test "$T[$i]" = "$T[$j]"; and set m (math $m + 1)
        test "$C[$i]" = "$C[$j]"; and set m (math $m + 1)
        test $m -ge 3; and set s3 (math $s3 + 1)
        if test $m -eq 2
            set s2 (math $s2 + 1); set -a bad "$names[$i] = $names[$j]"
        end
    end
end
printf '\npairs sharing all 3 : %d   (today 0)\n' $s3
printf 'pairs sharing 2 of 3: %d   (today 18)  <- the target metric\n' $s2
for b in $bad; echo "   $b"; end
echo
echo "sample rows (bar / tabs / cap):"
for i in (seq 1 $n)
    printf '  %-13s %s %s %s\n' $names[$i] $B[$i] $T[$i] $C[$i]
end
