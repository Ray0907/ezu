#!/bin/zsh
# Rebuild assets/diagrams-*.png: real Ghostty window captures of every sample diagram.
# macOS only. Needs Ghostty, ImageMagick (magick) and Screen Recording permission for the shell.
# Opens one Ghostty window; Ghostty may ask once to allow it to run /bin/zsh.
set -eu
cd "${0:A:h}"
BG='#282828'  # the Ghostty background, so cropped captures blend into the gallery
S=out/shots
rm -rf $S && mkdir -p $S/state $S/raw $S/crop

node -e "import('./samples.mjs').then(m => { for (const [k, v] of Object.entries(m.default))
  require('fs').writeFileSync('$S/' + k + '.mmd', v + '\n') })"

cat > $S/drive.sh <<'DRIVE'
#!/bin/zsh
cd "${0:A:h}/../.."
for f in out/shots/*.mmd; do
  n=${f:t:r}
  clear
  printf '\n  \e[1m%s\e[0m\n\n' $n
  node ezu.js $f
  touch out/shots/state/$n.ready
  while [ ! -e out/shots/state/$n.done ]; do sleep 0.2; done
done
touch out/shots/state/ALL
sleep 3
DRIVE
chmod +x $S/drive.sh

cat > $S/winid.js <<'JXA'
ObjC.import('CoreGraphics');
function run() {
  const l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0)));
  const w = l.find(x => x.kCGWindowName === 'ezu-shot');
  return w ? String(w.kCGWindowNumber) : '';
}
JXA

open -na Ghostty --args --title=ezu-shot --window-width=110 --window-height=34 \
  --window-save-state=never --background-opacity=1 --window-show-tab-bar=never -e $PWD/$S/drive.sh
for i in {1..50}; do WID=$(osascript -l JavaScript $S/winid.js); [ -n "$WID" ] && break; sleep 0.5; done
[ -n "$WID" ] || { echo 'capture window not found' >&2; exit 1; }

while [ ! -e $S/state/ALL ]; do
  for r in $S/state/*.ready(N); do
    n=${r:t:r}
    [ -e $S/state/$n.done ] && continue
    sleep 1.2  # let the terminal finish drawing the image
    screencapture -x -o -l $WID $S/raw/$n.png && touch $S/state/$n.done
  done
  sleep 0.3
done

# flatten the rounded corners, hide the cursor, crop to content, halve the retina size
for f in $S/raw/*.png; do
  n=${f:t:r}
  magick $f -background $BG -alpha remove -alpha off -fill $BG -draw 'rectangle 0,60 40,1420' $S/crop/$n.flat.png
  box=$(magick $S/crop/$n.flat.png -crop 1880x1290+40+90 +repage -fuzz 0 -format '%@' info:)
  w=${box%%x*}; rest=${box#*x}; h=${rest%%+*}; xy=${rest#*+}; x=${xy%%+*}; y=${xy#*+}
  magick $S/crop/$n.flat.png -crop $((w+24))x$((h+24))+$((40+x-12))+$((90+y-12)) +repage \
    -resize 50% $S/crop/$n.t.png
done

# tile 3x3, each column as wide and each row as tall as its largest cell
gallery() {
  local g=$1; shift; local names=("$@") cw=(0 0 0) rh=(0 0 0) i n w h r c
  for i in {1..9}; do
    n=$names[$i]; c=$(( (i-1)%3 + 1 )); r=$(( (i-1)/3 + 1 ))
    w=$(magick identify -format %w $S/crop/$n.t.png); h=$(magick identify -format %h $S/crop/$n.t.png)
    (( w > cw[c] )) && cw[c]=$w; (( h > rh[r] )) && rh[r]=$h
  done
  local rows=()
  for r in 1 2 3; do
    local cells=()
    for c in 1 2 3; do
      n=$names[$(( (r-1)*3 + c ))]
      magick $S/crop/$n.t.png -background $BG -gravity northwest \
        -extent $((cw[c]+40))x$((rh[r]+30)) $S/crop/cell-$n.png
      cells+=($S/crop/cell-$n.png)
    done
    magick $cells +append $S/crop/row-$g-$r.png; rows+=($S/crop/row-$g-$r.png)
  done
  magick $rows -append -bordercolor $BG -border 20 assets/diagrams-$g.png
}
mkdir -p assets
gallery structure flowchart class state er requirement block architecture c4 c4container
gallery flow sequence gantt timeline journey gitgraph kanban mindmap packet ishikawa
gallery data pie xychart quadrant radar sankey treemap venn wardley treeview
echo 'wrote assets/diagrams-{structure,flow,data}.png'
