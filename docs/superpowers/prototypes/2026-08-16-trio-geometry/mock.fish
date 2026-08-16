#!/usr/bin/env fish
# Builds the today-vs-proposed mockup. Faithful facsimile, not swatches:
# ShellFish tab strip (46px, 50% width, half coloured / half bare chrome)
# stacked on a tight 23px tmux status row with CSS-slant powerline caps.
source /tmp/claude-1000/-home-bitsaver-workspace-tmux-lives/75c340ac-07c0-4f40-9ddc-081f92efbdab/scratchpad/proto-trio.fish

set -l seed '#97cb38'
set -l out /home/bitsaver/.claude-mock-shared/tmux-lives/content/trio-accent.html

function _unit -a bar tabs cap sep win text label
    echo "<div class=\"unit\">"
    echo "  <div class=\"strip\">"
    echo "    <div class=\"tab on\" style=\"background:$tabs;color:$text\">~/workspace/tmux-lives</div>"
    echo "    <div class=\"tab off\">rocket</div>"
    echo "  </div>"
    echo "  <div class=\"bar\" style=\"background:$bar\">"
    echo "    <div class=\"cap l\" style=\"background:$cap\"><span>rocket</span></div>"
    echo "    <div class=\"wins\" style=\"color:$win\">claude<span style=\"color:$sep\"> &bull; </span>shell</div>"
    echo "    <div class=\"ident\" style=\"color:$text\">&#10022; tmux-lives</div>"
    echo "    <div class=\"cap r\" style=\"background:$cap\"><span>Aug 16 &middot; 7:51 AM</span></div>"
    echo "  </div>"
    echo "  <div class=\"hex\">$label &nbsp; <b>$bar</b> $tabs <b>$cap</b></div>"
    echo "</div>"
end

begin
echo '<style>'
echo 'body{background:#14140f;color:#d8d2c4;font:14px/1.5 -apple-system,Segoe UI,sans-serif;margin:0;padding:28px 32px;}'
echo 'h1{font-size:19px;margin:0 0 4px;color:#ff8a1f;font-weight:650;}'
echo 'p.sub{margin:0 0 26px;color:#9a8a72;font-size:13px;max-width:900px;}'
echo 'h2{font-size:13px;text-transform:uppercase;letter-spacing:.09em;color:#d2782a;margin:30px 0 12px;border-bottom:1px solid #3a3226;padding-bottom:6px;}'
echo '.row{display:grid;grid-template-columns:1fr 1fr;gap:26px;margin-bottom:20px;}'
echo '.colhead{font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:#9a8a72;margin-bottom:7px;}'
echo '.unit{width:100%;}'
echo '.strip{display:flex;height:46px;border-radius:7px 7px 0 0;overflow:hidden;}'
echo '.tab{flex:1;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600;}'
echo '.tab.off{background:#26262a;color:#7c7c84;font-weight:400;}'
echo '.bar{height:23px;display:flex;align-items:stretch;font-size:11.5px;position:relative;overflow:hidden;}'
echo '.cap{display:flex;align-items:center;padding:0 9px;color:#14140f;font-weight:600;}'
echo '.cap.l{clip-path:polygon(0 0,100% 0,calc(100% - 9px) 100%,0 100%);padding-right:16px;}'
echo '.cap.r{clip-path:polygon(9px 0,100% 0,100% 100%,0 100%);padding-left:16px;margin-left:auto;}'
echo '.wins{display:flex;align-items:center;padding-left:11px;}'
echo '.ident{position:absolute;left:50%;transform:translateX(-50%);display:flex;align-items:center;height:23px;font-weight:600;}'
echo '.hex{font:11px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;color:#7d7466;margin-top:6px;}'
echo '.hex b{color:#a89a84;font-weight:500;}'
echo '.flag{color:#e8663c;font-weight:600;}'
echo '</style>'

echo "<h1>Trio geometry &mdash; today vs proposed</h1>"
echo "<p class=\"sub\">Seed <code>$seed</code>. Left column is the shipped engine, right is the proposed &ldquo;accent outside the pair&rdquo; geometry. Each unit is a ShellFish tab strip (46px, half coloured so the tint is judged as one tab among others) stacked on a 23px tmux status row &mdash; real proportions. Hexes are <b>bar</b>, tabs, <b>cap</b>. Nothing is installed; this is a throwaway prototype.</p>"

for tier in 'the collision cases|wheat soft|mint soft|wheat slate|mint slate|wheat glow|mint glow' \
            'curated defaults|sage glow|teal glow|mint chip|sage chip|coral chip|mono soft|wheat soft|amber soft|wheat slate|amber slate|ember slate|teal slate|sage core|amber deep'
    set -l parts (string split '|' -- $tier)
    echo "<h2>$parts[1]</h2>"
    if test "$parts[1]" = 'the collision cases'
        echo "<p class=\"sub\" style=\"margin:-6px 0 16px\">In these, today&rsquo;s endcap sits on the tab hue (&Delta;H under 1&deg;) at the same lightness (&Delta;L 0.01) &mdash; two colours pretending to be three.</p>"
    end
    for want in $parts[2..-1]
        for line in (__tmux_lives_theme_catalog)
            set -l f (string split '|' -- $line)
            test "$f[1]" = "$want"; or continue
            set -l now (__tmux_lives_theme_palette "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
            set -l pro (proto_trio "$seed" "$f[2]" "$f[3]" "$f[4]" 0)
            set -l pa (__tmux_lives_theme_accents $pro[1] $pro[3])
            echo '<div class="row">'
            echo '<div><div class="colhead">today &mdash; '$f[1]'</div>'
            _unit $now[1] $now[3] $now[6] $now[2] $now[5] $now[7] 'today'
            echo '</div>'
            echo '<div><div class="colhead">proposed &mdash; '$f[1]'</div>'
            _unit $pro[1] $pro[2] $pro[3] $pa[1] $pa[3] $pa[4] 'proposed'
            echo '</div>'
            echo '</div>'
        end
    end
end
end > $out
echo "wrote $out"
