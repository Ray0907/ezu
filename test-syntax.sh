#!/bin/sh
# E2E for syntax coverage: every Mermaid type and variant renders; markdown constructs come out right.
cd "$(dirname "$0")"; mkdir -p out/s; fail=0
ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
strip() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\a]*\a//g'; }   # BSD sed: [^\a] is literal, fine for these checks
imgs() { grep -ao $'\033_Ga=T' "$1" | wc -l | tr -d ' '; }

# mermaid: every diagram type and syntax variant produces a valid PNG
node --input-type=module -e "
import samples, {variants} from './samples.mjs'; import {toPng} from './ezu.js';
let bad = 0;
for (const [group, set] of [['type', samples], ['variant', variants]])
  for (const [k, t] of Object.entries(set)) {
    try { const b = toPng(t); if (b.slice(1,4).toString() !== 'PNG' || b.length < 1500) throw new Error('tiny'); }
    catch (e) { console.log('  ' + group + ' ' + k + ': ' + String(e.message).split('\n')[0]); bad++; }
  }
process.exit(bad ? 1 : 0)" && ok "mermaid types+variants" || bad "mermaid types+variants"

# mermaid fences: ~~~, longer fence, info string, inside list, inside blockquote; plain code is not an image
cat > out/s/fences.md <<'MD'
~~~mermaid
flowchart LR
  A-->B
~~~

````mermaid
flowchart LR
  C-->D
````

```mermaid title="x"
flowchart LR
  E-->F
```

- item

  ```mermaid
  flowchart LR
    G-->H
  ```

> ```mermaid
> flowchart LR
>   I-->J
> ```

```js
const notDiagram = 1;
```
MD
./ezu.js out/s/fences.md > out/s/fences.txt
[ "$(imgs out/s/fences.txt)" = 5 ] && grep -q notDiagram out/s/fences.txt && ok "mermaid fence forms" || bad "mermaid fence forms ($(imgs out/s/fences.txt) images)"

# a broken diagram shows an error and the source, and the rest of the document still renders
printf 'before\n\n```mermaid\nnot a diagram\n```\n\nafter\n' > out/s/broken.md
./ezu.js out/s/broken.md > out/s/broken.txt; rc=$?
[ $rc = 0 ] && strip < out/s/broken.txt | grep -q 'mermaid error' && grep -q 'not a diagram' out/s/broken.txt && grep -q after out/s/broken.txt \
  && ok "broken diagram isolated" || bad "broken diagram isolated (rc=$rc)"

# ordered list keeps its start number
printf '3. three\n4. four\n' > out/s/start.md
./ezu.js out/s/start.md | strip | grep -q '3\. three' && ./ezu.js out/s/start.md | strip | grep -q '4\. four' && ok "ordered start" || bad "ordered start"

# hanging indent: wrapped list/quote lines keep their indent, no orphans, <=72 cells
L="alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu"
printf -- "- $L\n  - $L\n\n> $L\n> > $L\n" > out/s/hang.md
./ezu.js out/s/hang.md | strip > out/s/hang.txt
node --input-type=module -e "
import sw from 'string-width'; import fs from 'node:fs';
const ls = fs.readFileSync('out/s/hang.txt','utf8').split('\n').filter(l => l.replace(/[ │]/g,''));
const textCol = l => l.search(/[^ │*]/);
// each block starts with 'alpha'; every other line is a continuation and must hang at that block's text column
let col = -1, ok = ls.every(l => sw(l) <= 72), orphans = 0;
for (const l of ls) {
  if (/^[ │*]*alpha/.test(l)) col = textCol(l);
  else ok = ok && textCol(l) === col;
  if (l.replace(/[│*]/g,'').split(/\s+/).filter(Boolean).length === 1) orphans++;
}
process.exit(ok && orphans === 0 ? 0 : 1)" && ok "hanging indent" || { bad "hanging indent"; cat out/s/hang.txt; }
grep -q '│ │ ' out/s/hang.txt && ok "nested quote bars" || bad "nested quote bars"

# soft line breaks join; hard breaks stay; hr fits the column
printf 'one\ntwo\n\nhard  \nbreak\n\n---\n' > out/s/soft.md
./ezu.js out/s/soft.md | strip > out/s/soft.txt
hr=$(node --input-type=module -e "
import sw from 'string-width'; import fs from 'node:fs';
const l = fs.readFileSync('out/s/soft.txt','utf8').split('\n').find(l => /─{5,}/.test(l)); console.log(l ? sw(l) : 999)")
grep -q 'one two' out/s/soft.txt && grep -q 'hard$' out/s/soft.txt && [ "$hr" -le 72 ] \
  && ok "soft/hard breaks, hr" || bad "soft/hard breaks, hr (hr=$hr)"

# html: tags dropped, content kept, comments hidden
printf 'a <u>under</u> b <!-- hidden --> c\n\n<details><summary>Sum</summary>\n\nbody\n\n</details>\n' > out/s/html.md
./ezu.js out/s/html.md | strip > out/s/html.txt
grep -q 'a under b' out/s/html.txt && ! grep -q 'hidden\|<u>\|<details>' out/s/html.txt && grep -q Sum out/s/html.txt && grep -q body out/s/html.txt \
  && ok "inline html" || bad "inline html"

# images: local png/svg render; remote, absolute and non-image paths fall back to text and never crash
./ezu.js --png out/s/pic.png <<'MM'
flowchart LR
  A-->B
MM
printf '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="#888"/></svg>' > out/s/pic.svg
printf 'hello' > out/s/notimg.txt
cat > out/s/img.md <<'MD'
![local](pic.png)

![vector](pic.svg)

![remote](https://example.com/a.png)

![abs](/etc/hosts)

![text](notimg.txt)

![missing](nope.png)
MD
./ezu.js out/s/img.md > out/s/img.txt; rc=$?
[ $rc = 0 ] && [ "$(imgs out/s/img.txt)" = 2 ] && strip < out/s/img.txt | grep -q 'remote' && strip < out/s/img.txt | grep -q 'abs' \
  && ok "images" || bad "images (rc=$rc, $(imgs out/s/img.txt) rendered)"

# image safety: only files inside the document's tree render; no symlink escape, FIFO hang, SVG-embedded
# local images or giant SVG canvases. The one legitimate local image still renders.
cp out/s/pic.png out/outside.png
ln -sf ../outside.png out/s/escape.png
rm -f out/s/fifo.png; mkfifo out/s/fifo.png
printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="40"><image xlink:href="%s/out/s/pic.png" width="40" height="40"/></svg>' "$PWD" > out/s/ext.svg
printf '<svg xmlns="http://www.w3.org/2000/svg" width="1000000" height="1000000"><rect width="9" height="9"/></svg>' > out/s/huge.svg
cat > out/s/sec.md <<'MD'
![ok](pic.png)

![up](../outside.png)

![link](escape.png)

![fifo](fifo.png)

![ext](ext.svg)

![huge](huge.svg)
MD
start=$(date +%s)
timeout 20 ./ezu.js out/s/sec.md > out/s/sec.txt; rc=$?
elapsed=$(( $(date +%s) - start ))
[ $rc = 0 ] && [ "$(imgs out/s/sec.txt)" = 1 ] && [ $elapsed -lt 10 ] \
  && ok "image safety" || bad "image safety (rc=$rc, $(imgs out/s/sec.txt) rendered, ${elapsed}s)"
rm -f out/s/fifo.png

# svg safety: resvg loads local paths from any href-like attribute, so SVG that came from untrusted text (pele
# output or an .svg file) may only reference data:, #fragments or http(s)/mailto. Bypass attempts must all fail.
node --input-type=module - <<'JS' && ok "mermaid svg safety" || bad "mermaid svg safety"
import { toPng } from './ezu.js';
const abs = process.cwd() + '/out/s/pic.png';
let bad = 0; const note = m => { console.log('  ' + m); bad++; };
// image shapes pointing at local files are refused; links and plain diagrams still work
for (const [k, img] of [['abs', abs], ['rel', 'out/s/pic.png']])
  { try { toPng(`flowchart LR\n A@{ img: "${img}", label: "x", w: 60, h: 60 }`); note('mermaid img ' + k + ' was not refused'); } catch {} }
for (const t of ['flowchart LR\n A-->B\n click A href "https://example.com" _blank', 'flowchart LR\n A-->B'])
  { try { toPng(t); } catch (e) { note('legit mermaid refused: ' + e.message); } }
process.exit(bad ? 1 : 0);
JS

svg() { printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:q="http://www.w3.org/1999/xlink" width="40" height="40">%s</svg>' "$2" > "out/s/$1.svg"; }
svg a-prefix "<image q:href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
svg a-single "<image href='$PWD/out/s/pic.png' width=\"40\" height=\"40\"/>"
svg a-entity "<image href=\"&#47;${PWD#/}/out/s/pic.png\" width=\"40\" height=\"40\"/>"
svg a-feimage "<filter id=\"f\"><feImage xlink:href=\"$PWD/out/s/pic.png\"/></filter><rect width=\"40\" height=\"40\" filter=\"url(#f)\"/>"
svg a-spaced "<image href = \"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
# parser differentials: shapes where a regex and an XML parser disagree about what is an attribute
svg b-swallow "<g a='href=\"data:'/><image href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\" b='\"'/>"
svg b-comment "<!-- href=\"data:x\" --><image href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
svg b-cdata "<text><![CDATA[ href=\"#a\" ]]></text><image href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
svg b-gt "<g a=\">\"/><image href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
svg b-nsdecl "<image xmlns:z=\"http://www.w3.org/1999/xlink\" z:href=\"$PWD/out/s/pic.png\" width=\"40\" height=\"40\"/>"
printf '<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY p "%s/out/s/pic.png">]><svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><image href="&p;" width="40" height="40"/></svg>' "$PWD" > out/s/a-doctype.svg
# raster data: URIs are decoded by resvg too: a tiny PNG header can claim 60000x60000 pixels, and other raster/nested formats are not vetted
bomb=$(node -e "const b=Buffer.alloc(33);Buffer.from('89504e470d0a1a0a0000000d49484452','hex').copy(b);b.writeUInt32BE(60000,16);b.writeUInt32BE(60000,20);b[24]=8;b[25]=6;process.stdout.write(b.toString('base64'))")
svg a-pngbomb "<image href=\"data:image/png;base64,$bomb\" width=\"40\" height=\"40\"/>"
svg a-jpeg '<image href="data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBD" width="40" height="40"/>'
svg a-nested '<image href="data:image/svg+xml;base64,PHN2Zy8+" width="40" height="40"/>'
svg g-use '<defs><rect id="r" width="20" height="20" fill="#444"/></defs><use href="#r"/><use xlink:href="#r" x="20"/>'
svg g-data '<image href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==" width="40" height="40"/>'
: > out/s/svgsec.md
for f in a-prefix a-single a-entity a-feimage a-spaced a-doctype a-pngbomb a-jpeg a-nested b-swallow b-comment b-cdata b-gt b-nsdecl; do printf '![%s](%s.svg)\n\n' "$f" "$f" >> out/s/svgsec.md; done
./ezu.js out/s/svgsec.md > out/s/svgsec.txt; rc=$?
[ $rc = 0 ] && [ "$(imgs out/s/svgsec.txt)" = 0 ] && ok "svg file bypass attempts refused" || bad "svg file bypass attempts refused (rc=$rc, $(imgs out/s/svgsec.txt) rendered)"
printf '![use](g-use.svg)\n\n![data](g-data.svg)\n' > out/s/svgok.md
./ezu.js out/s/svgok.md > out/s/svgok.txt
[ "$(imgs out/s/svgok.txt)" = 2 ] && ok "svg fragments and data uris render" || bad "svg fragments and data uris render ($(imgs out/s/svgok.txt))"

# planted relative paths: resvg resolves non-data hrefs against the cwd, so a directory named "https:" or a file
# named "#frag" next to the user could be drawn. Output must equal the same SVG with the image removed.
rm -rf out/plant; mkdir -p out/plant/https: ; cp out/s/pic.png out/plant/https:/pic.png; cp out/s/pic.png 'out/plant/#frag'
node --input-type=module - <<'JS' && ok "planted relative paths" || bad "planted relative paths"
import fs from 'node:fs';
import { svgToPng, selfContained, withEmptyCwd } from './ezu.js';
const wrap = inner => `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="40">${inner}</svg>`;
const blank = svgToPng(wrap(''), {});
// layer 2: while resvg parses/renders, the cwd is an empty directory; afterwards it is restored
const before = process.cwd();
const inside = withEmptyCwd(() => ({ cwd: process.cwd(), entries: fs.readdirSync('.').length }));
let bad = 0;
if (inside.entries !== 0 || inside.cwd === before || process.cwd() !== before || fs.existsSync(inside.cwd)) bad++, console.log('  empty-cwd isolation failed');
process.chdir('out/plant'); const note = m => { console.log('  ' + m); bad++; };
for (const [k, href] of [['https dir', 'https://pic.png'], ['hash file', '#frag'], ['mailto', 'mailto:x']])
  if (!svgToPng(wrap(`<image href="${href}" width="40" height="40"/>`), {}).equals(blank)) note(k + ' drew a local file');
const a = selfContained(wrap('<a href="https://example.com/x"><rect width="9" height="9"/></a>'));
if (/https:|example\.com/.test(a) || !/href="#"/.test(a)) note('link hrefs were not neutralized');
process.exit(bad ? 1 : 0);
JS
rm -rf out/plant

# fonts: scanning every system font costs ~200 ms per diagram, so load only the face the text needs
node --input-type=module - <<'JS' && ok "font selection" || bad "font selection"
import fs from 'node:fs';
import { fontOptions, toPng } from './ezu.js';
import samples from './samples.mjs';
let bad = 0; const note = m => { console.log('  ' + m); bad++; };
// decide from the files themselves whether this machine can use the fast path, not from fontOptions' answer
const have = ['/System/Library/Fonts/Supplemental/Arial.ttf', '/Library/Fonts/Arial Unicode.ttf'].every(f => fs.existsSync(f));
if (!have) { console.log('  (known font files absent; system-font fallback is expected here)'); process.exit(0); }
const ascii = fontOptions('<text>Hello</text>'), wide = fontOptions('<text>開始</text>');
if (ascii.loadSystemFonts || ascii.fontFiles.length !== 1) note('ascii text should use one font file');
if (wide.loadSystemFonts || wide.fontFiles.length !== 1 || wide.fontFiles[0] === ascii.fontFiles[0]) note('non-ascii text should use a different, wider font');
if (!fontOptions('<text>x</text>', ['/nonexistent/']).loadSystemFonts) note('missing fonts must fall back to system fonts');
// 10 ascii diagrams must not pay a font scan each (was ~200 ms apiece, ~2 s total)
const t = performance.now(); for (let i = 0; i < 10; i++) toPng(samples.flowchart);
const ms = performance.now() - t; if (ms > 1000) note('10 renders took ' + ms.toFixed(0) + ' ms');
process.exit(bad ? 1 : 0);
JS

# inline markup must render inside list items too (tight items hold their inline tokens in a text token)
printf -- '- **bold** *it* `code` [link](https://x.y) ~~gone~~ \\*esc\\* ref[^1]\n- second **bold**\n\n1. **ordered bold**\n\n> - **quoted bold**\n\n[^1]: note\n' > out/s/li.md
FORCE_COLOR=3 ./ezu.js out/s/li.md > out/s/li.txt
plain=$(sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\a]*\a//g' out/s/li.txt)
{ ! printf '%s' "$plain" | grep -qF '**' && ! printf '%s' "$plain" | grep -qF '~~' && ! printf '%s' "$plain" | grep -qF '[link](' \
  && ! printf '%s' "$plain" | grep -qF '[^1]' && printf '%s' "$plain" | grep -q 'ref¹' && printf '%s' "$plain" | grep -q '\*esc\*' \
  && grep -aq $'\033\\[1mbold' out/s/li.txt && grep -aq $'\033]8;;https://x.y/' out/s/li.txt; } \
  && ok "list item inline markup" || { bad "list item inline markup"; printf '%s\n' "$plain" | head -8; }

# task lists: the box and its text share one line with a single space, tight or loose, with nested items
cat > out/s/task.md <<'MD'
- [ ] tight one
- [x] tight two **bold**

- [ ] loose one

- [x] loose two
  1. nested a
  2. nested b
MD
./ezu.js out/s/task.md | sed 's/\x1b\[[0-9;]*m//g' > out/s/task.txt
grep -qE '\* \[ \] tight one$' out/s/task.txt && grep -qE '\* \[x\] tight two bold$' out/s/task.txt \
  && grep -qE '\* \[ \] loose one$' out/s/task.txt && grep -qE '\* \[x\] loose two$' out/s/task.txt \
  && ok "task list boxes" || { bad "task list boxes"; cat out/s/task.txt; }

# nested lists stay compact when colour is on (no whitespace-only lines between items)
printf -- '- a\n  1. b\n  2. c\n     - d\n- e\n' > out/s/nest.md
FORCE_COLOR=3 ./ezu.js out/s/nest.md | sed 's/\x1b\[[0-9;]*m//g' > out/s/nest.txt
[ "$(sed '$d' out/s/nest.txt | grep -c '^ *$')" = 0 ] && ok "nested list compact in colour" || { bad "nested list compact in colour"; cat -v out/s/nest.txt; }

# footnotes: references become superscripts, definitions a numbered list at the end; undefined stays literal
printf 'Claim[^a] and more[^b], undefined[^zz].\n\n[^a]: First note.\n[^b]: Second note.\n' > out/s/fn.md
./ezu.js out/s/fn.md | strip > out/s/fn.txt
grep -q 'Claim¹' out/s/fn.txt && grep -q 'more²' out/s/fn.txt && grep -q '1\. First note' out/s/fn.txt && grep -q '2\. Second note' out/s/fn.txt \
  && grep -qF 'undefined[^zz]' out/s/fn.txt && ! grep -qF '[^a]' out/s/fn.txt && ok "footnotes" || { bad "footnotes"; cat out/s/fn.txt; }

[ $fail = 0 ]
