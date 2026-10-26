#!/bin/sh
# E2E: every diagram type renders to a valid, non-blank PNG; bad input fails nonzero.
set -e; cd "$(dirname "$0")"; mkdir -p out; fail=0
# piped output is plain text by default; the suites below check the rich output, so force it
export EZU_GRAPHICS=on
run() { # name, mermaid text
  printf '%s\n' "$2" | ./ezu.js --png "out/$1.png"
  node -e "const b=require('fs').readFileSync('out/$1.png');if(b.slice(1,4).toString()!=='PNG'||b.length<1500)process.exit(1)" \
    && echo "ok   $1" || { echo "FAIL $1"; fail=1; }
}
run flowchart 'flowchart LR
  A[Start] --> B{Ok?}
  B -->|yes| C[Done]
  B -->|no| A'
run sequence 'sequenceDiagram
  Alice->>Bob: hi
  Bob-->>Alice: yo'
run pie 'pie title Pets
  "Dogs" : 5
  "Cats" : 3'
run class 'classDiagram
  Animal <|-- Dog'
run er 'erDiagram
  USER ||--o{ ORDER : places'
run gantt 'gantt
  title T
  dateFormat YYYY-MM-DD
  section S
  Task :a1, 2026-01-01, 5d'
# no unresolved var() leaks into any output
node --input-type=module -e "
import {flatten} from './ezu.js'; import {render} from 'pele';
for (const t of ['flowchart TD\n A-->B','pie\n \"a\":1','sequenceDiagram\n A->>B: x']) {
  if (/var\(/.test(flatten(render(t).svg, {}))) { console.log('FAIL var leak'); process.exit(1) } }
console.log('ok   no var() leak')" || fail=1
if echo 'not a diagram ???' | ./ezu.js --png out/bad.png 2>/dev/null; then echo "FAIL bad input exit 0"; fail=1; else echo "ok   bad input nonzero"; fi
# markdown: mermaid fence becomes a kitty image escape, prose kept (forced TTY md branch ignores TTY)
printf '# Title\n\nhello **prose**\n\n- li one\n\n| h1 | h2 |\n|----|----|\n| c1 | c2 |\n\n```mermaid\nflowchart LR\n  A-->B\n```\n\nafter\n' > out/doc.md
./ezu.js out/doc.md > out/md.txt
grep -q 'hello' out/md.txt && grep -q 'li one' out/md.txt && grep -q 'c2' out/md.txt && ! grep -q '\*\*prose' out/md.txt && grep -q 'after' out/md.txt && grep -aq $'\033_Ga=T' out/md.txt \
  && ! grep -aq '```mermaid' out/md.txt && echo "ok   markdown" || { echo "FAIL markdown"; fail=1; }
# typography: prose wraps at <=72 cols (45-75 rule); numeric table columns right-align
{ printf '# T\n\n'; for i in $(seq 60); do printf 'word%s ' $i; done; printf '\n\n| name | qty |\n|------|-----|\n| a | 1 |\n| b | 22 |\n'; } > out/typo.md
./ezu.js out/typo.md > out/typo.txt
max=$(grep word out/typo.txt | awk '{ if (length($0)>m) m=length($0) } END { print m }')
[ "$(grep -c word out/typo.txt)" -ge 2 ] && [ "$max" -le 72 ] && sed 's/\x1b\[[0-9;]*m//g' out/typo.txt | grep -Eq '│  +1 │' \
  && ! sed 's/\x1b\[[0-9;]*m//g' out/typo.txt | grep -v '^$' | grep -qv '^  ' \
  && echo "ok   typography" || { echo "FAIL typography (max=$max)"; fail=1; }
# CJK: wide chars wrap by display width (<=72 cells incl. margin) and tables stay aligned
{ printf '# 標題\n\n'; for i in $(seq 30); do printf '這是一段很長的中文句子%s，' $i; done
  printf '\n\n| 名稱 | 數量 |\n|------|-----|\n| 蘋果 | 1 |\n| 香蕉和橘子 | 22 |\n'; } > out/cjk.md
./ezu.js out/cjk.md > out/cjk.txt
node --input-type=module -e "
import sw from 'string-width'; import fs from 'node:fs';
const ls = fs.readFileSync('out/cjk.txt','utf8').replace(/\x1b\[[0-9;]*m/g,'').split('\n').filter(Boolean);
const tbl = ls.filter(l => /[│┌├└]/.test(l));
process.exit(ls.every(l => sw(l) <= 72) && ls.every(l => l.startsWith('  ')) && new Set(tbl.map(sw)).size === 1 ? 0 : 1)" \
  && echo "ok   cjk" || { echo "FAIL cjk"; fail=1; }
# links: OSC 8 hyperlinks for http(s)/mailto only; table alignment survives them
printf '[ok](https://example.com/a?b=1) [mail](mailto:a@b.co) [bad](javascript:alert(1)) [ftp](ftp://x.y/f)\n\n| n | link |\n|---|------|\n| 1 | [site](https://example.com) |\n| 22 | plain |\n' > out/link.md
./ezu.js out/link.md > out/link.txt
osc=$'\033]8;;'
{ grep -aq "${osc}https://example.com/a?b=1"$'\a' out/link.txt \
  && grep -aq "${osc}mailto:a@b.co"$'\a' out/link.txt \
  && ! grep -aq "${osc}javascript" out/link.txt && ! grep -aq "${osc}ftp" out/link.txt \
  && node --input-type=module -e "
import sw from 'string-width'; import fs from 'node:fs';
const ls = fs.readFileSync('out/link.txt','utf8').replace(/\x1b\]8;;[^\x07]*\x07/g,'').replace(/\x1b\[[0-9;]*m/g,'').split('\n').filter(l => /[│┌├└]/.test(l));
process.exit(new Set(ls.map(sw)).size === 1 ? 0 : 1)"; } \
  && echo "ok   links" || { echo "FAIL links"; fail=1; }
# a link that wraps must close at each line end, so the left margin is never part of the hyperlink
{ printf '[%s](https://example.com/x) tail\n' "$(for i in $(seq 40); do printf 'w%s ' $i; done)"; } > out/linkwrap.md
./ezu.js out/linkwrap.md > out/linkwrap.txt
node --input-type=module -e "
import fs from 'node:fs';
const ls = fs.readFileSync('out/linkwrap.txt','utf8').split('\n').filter(Boolean);
const bal = l => (l.match(/\x1b\]8;;[^\x07]+\x07/g)||[]).length === (l.match(/\x1b\]8;;\x07/g)||[]).length;
const withLink = ls.filter(l => /\x1b\]8;;[^\x07]+\x07/.test(l)).length;
process.exit(withLink >= 2 && ls.every(bal) ? 0 : 1)" \
  && echo "ok   link wrap" || { echo "FAIL link wrap"; fail=1; }
# hyperlink bytes are zero-width: a short sentence with a long-URL link must not wrap early
printf 'A [link](https://example.com/aaaaaaaaaaaaaaaaaaaa) here.\n' > out/linkwidth.md
./ezu.js out/linkwidth.md > out/linkwidth.txt
[ "$(grep -c . out/linkwidth.txt)" = 1 ] && echo "ok   link width" || { echo "FAIL link width"; fail=1; }
# a table wider than the text column must stay intact (never hard-cut mid-row)
printf '| 欄位一 | col two | col three | col four | col five | col six | col seven |\n|---|---|---|---|---|---|---|\n| aaaaaaaaaaaa | bbbbbbbbbbbb | cccccccccccc | dddddddddddd | eeeeeeeeeeee | ffffffffff | gg |\n' > out/widetable.md
./ezu.js out/widetable.md > out/widetable.txt
node --input-type=module -e "
import sw from 'string-width'; import fs from 'node:fs';
const ls = fs.readFileSync('out/widetable.txt','utf8').replace(/\x1b\[[0-9;]*m/g,'').split('\n').filter(Boolean);
process.exit(ls.length === 5 && new Set(ls.map(sw)).size === 1 ? 0 : 1)" \
  && echo "ok   wide table" || { echo "FAIL wide table"; fail=1; }
# width fit: natural cols = ceil(px/cell), capped at terminal width; kitty gets c=
node --input-type=module -e "
import {fit, kitty} from './ezu.js'; import fs from 'node:fs';
const ok = fit(400,80,20)===20 && fit(4000,80,20)===80 && fit(1,80,20)===1;
const png = fs.readFileSync('out/flowchart.png');
const w = png.readUInt32BE(16);
const esc = kitty(png, fit(w,10,10));
process.exit(ok && esc.includes('c=') && esc.startsWith('\x1b_Ga=T,f=100,c=') ? 0 : 1)" \
  && echo "ok   width fit" || { echo "FAIL width fit"; fail=1; }
# escape injection: ESC/BEL/OSC from untrusted markdown must not reach the terminal
printf 'safe \033]52;c;ZXZpbA==\007 text\n' > out/evil.md
./ezu.js out/evil.md > out/evil.txt
grep -aq $'\033]52' out/evil.txt && { echo "FAIL escape injection"; fail=1; } || echo "ok   escape injection stripped"
# single-binary build (bun): runs outside the project with no node_modules, renders diagram and markdown
if command -v bun >/dev/null 2>&1; then
  bun build ./ezu.js --compile --outfile out/ezu-bin >/dev/null 2>&1
  bin="$PWD/out/ezu-bin"; tmp=$(mktemp -d); mkdir "$tmp/run"; cp "$bin" "$tmp/run/ezu"
  printf 'flowchart LR\n  A[開始 Start] --> B\n' > "$tmp/run/d.mmd"
  printf '# T\n\n```mermaid\nflowchart LR\n  A-->B\n```\n' > "$tmp/run/d.md"
  ( cd "$tmp/run" && ./ezu --png d.png d.mmd && ./ezu d.md > d.txt )
  node -e "const b=require('fs').readFileSync('$tmp/run/d.png');process.exit(b.slice(1,4).toString()==='PNG'&&b.length>1500?0:1)" \
    && grep -aq $'\033_Ga=T' "$tmp/run/d.txt" && echo "ok   single binary" || { echo "FAIL single binary"; fail=1; }
  rm -rf "$tmp"
else echo "skip single binary (no bun)"; fi
# --- capability probe, non-TTY output, --width, theme, usage ---
# resolveCaps is the single decision point: probe reply + env + tty in, capabilities out
node --input-type=module -e "
import {resolveCaps} from './ezu.js';
const E = '\x1b', DA = E + '[?62;4c', OK = E + '_Gi=31;OK' + E + '\\\\';
const R = (reply, env = {}, tty = true) => resolveCaps({reply, env, tty});
const g = (...a) => R(...a).graphics;
const bg = (c, reply) => R(reply).light === c;
const checks = [
  g(E + '[6;36;18t' + OK + DA) === true,
  R(E + '[6;36;18t' + OK + DA).cellW === 18,
  R(E + '[6;40;22t' + DA).cellW === 22,
  g(DA, {KITTY_WINDOW_ID: '1'}) === false,
  g(DA + OK) === false,
  g(null, {TERM_PROGRAM: 'ghostty'}) === true,
  g(null, {TERM_PROGRAM: 'WezTerm'}) === true,
  g(null, {TERM: 'xterm-kitty'}) === true,
  g(null, {TERM: 'xterm-ghostty'}) === true,
  g(null, {KITTY_WINDOW_ID: '3'}) === true,
  g(null, {TERM: 'xterm-256color', TERM_PROGRAM: 'Apple_Terminal'}) === false,
  g(OK + DA, {EZU_GRAPHICS: 'off'}) === false,
  g(DA, {EZU_GRAPHICS: 'on'}) === true,
  g(null, {EZU_GRAPHICS: 'on'}, false) === true,
  g(OK + DA, {}, false) === false,
  bg(true, E + ']11;rgb:ffff/ffff/ffff\x07' + DA),
  bg(true, E + ']11;rgb:ff/ff/ff' + E + '\\\\' + DA),
  bg(false, E + ']11;rgb:1e1e/1e1e/2e2e\x07' + DA),
  bg(false, E + ']11;rgb:0000/0000/0000\x07'),
  bg(false, DA),
  bg(false, null),
];
const bad = checks.map((c, i) => c ? null : i).filter(i => i !== null);
if (bad.length) { console.log('failed checks', bad); process.exit(1); }" \
  && echo "ok   capability resolution" || { echo "FAIL capability resolution"; fail=1; }
# real round trip through a pty: the probe reply decides, env hints only when the terminal is silent
if command -v python3 >/dev/null 2>&1; then
cat > out/ptyrun.py <<'PY'
import os, pty, sys
reply, cmd = os.fsencode(sys.argv[1]), sys.argv[2:]
pid, fd = pty.fork()
if pid == 0: os.execvp(cmd[0], cmd)
out, sent = b'', False
while True:
    try: d = os.read(fd, 65536)
    except OSError: break
    if not d: break
    out += d
    if not sent and b'\x1b[c' in out:
        sent = True
        if reply: os.write(fd, reply)
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(out); sys.exit(os.waitstatus_to_exitcode(st))
PY
printf '# T\n\n```mermaid\nflowchart LR\n  A-->B\n```\n' > out/pty.md
pty() { # reply, extra env assignments...: run ezu on out/pty.md in a pty with a clean env
  r=$1; shift
  env -u EZU_GRAPHICS -u KITTY_WINDOW_ID TERM_PROGRAM=x TERM=xterm "$@" python3 out/ptyrun.py "$r" ./ezu.js out/pty.md
}
pty $'\033[6;36;18t\033_Gi=31;OK\033\\\033[?62;4c' > out/pty-ok.txt
pty $'\033[?62c' KITTY_WINDOW_ID=1 > out/pty-da.txt
pty '' TERM_PROGRAM=ghostty > out/pty-hint.txt
pty '' > out/pty-none.txt
{ grep -aq $'\033_Ga=T' out/pty-ok.txt && ! grep -aq $'\033_Ga=T' out/pty-da.txt && grep -aq 'A-->B' out/pty-da.txt \
  && grep -aq $'\033_Ga=T' out/pty-hint.txt && ! grep -aq $'\033_Ga=T' out/pty-none.txt && grep -aq 'A-->B' out/pty-none.txt; } \
  && echo "ok   probe round trip (pty)" || { echo "FAIL probe round trip (pty)"; fail=1; }
# no file and a terminal on stdin: usage on stderr, exit 1, no hang
rc=0; env -u EZU_GRAPHICS timeout 10 python3 out/ptyrun.py '' ./ezu.js > out/usage.txt || rc=$?
[ $rc = 1 ] && grep -aq '^usage: ezu' out/usage.txt && echo "ok   usage without input" || { echo "FAIL usage without input (rc=$rc)"; fail=1; }
else echo "skip pty tests (no python3)"; fi
# piped markdown is plain: no APC graphics, no OSC 8, alt text, note plus source, text (url) links
printf '# T\n\n![alt text here](flowchart.png)\n\n[site](https://example.com/p)\n\n```mermaid\nflowchart LR\n  A-->B\n```\n' > out/plain.md
env -u EZU_GRAPHICS ./ezu.js out/plain.md > out/plain.txt
sed 's/\x1b\[[0-9;]*m//g' out/plain.txt > out/plain.clean.txt
{ ! grep -aq $'\033_G' out/plain.txt && ! grep -aq $'\033]8' out/plain.txt \
  && grep -q 'alt text here' out/plain.clean.txt && grep -q 'site (https://example.com/p)' out/plain.clean.txt \
  && grep -q 'mermaid' out/plain.clean.txt && grep -q 'A-->B' out/plain.clean.txt; } \
  && echo "ok   piped markdown is plain" || { echo "FAIL piped markdown is plain"; fail=1; }
# EZU_GRAPHICS=off drops graphics (note plus source); EZU_GRAPHICS=on forces them on a pipe (out/md.txt)
EZU_GRAPHICS=off ./ezu.js out/doc.md > out/goff.txt
{ ! grep -aq $'\033_G' out/goff.txt && grep -aq 'flowchart LR' out/goff.txt && grep -aq 'mermaid' out/goff.txt \
  && grep -aq $'\033_Ga=T' out/md.txt; } \
  && echo "ok   graphics off and forced on" || { echo "FAIL graphics off and forced on"; fail=1; }
# --width / -w: content width; 0 is the full terminal width (80 piped) minus the margins; bad values fail
width_max() { grep word out/typo.txt | sed 's/\x1b\[[0-9;]*m//g' | awk '{ if (length($0)>m) m=length($0) } END { print m }'; }
./ezu.js --width 40 out/typo.md > out/typo.txt; w40=$(width_max)
./ezu.js -w 40 out/typo.md > out/typo.txt; w40s=$(width_max)
./ezu.js --width 0 out/typo.md > out/typo.txt; w0=$(width_max)
./ezu.js out/typo.md > out/typo.txt; wdef=$(width_max)
werr=0
for bad in abc -3 2.5 ''; do
  if ./ezu.js --width "$bad" out/typo.md 2>out/werr.txt >/dev/null; then werr=1; fi
  grep -q '^ezu: invalid width$' out/werr.txt || werr=1
done
[ "$w40" -le 42 ] && [ "$w40" -ge 30 ] && [ "$w40s" = "$w40" ] && [ "$w0" -gt 72 ] && [ "$w0" -le 78 ] && [ "$wdef" -le 72 ] && [ $werr = 0 ] \
  && echo "ok   width flag" || { echo "FAIL width flag (40=$w40 -w=$w40s 0=$w0 default=$wdef err=$werr)"; fail=1; }
# theme: --dark is the explicit default; --light differs; piped output never probes
printf 'flowchart LR\n  A-->B\n' > out/theme.mmd
./ezu.js --png out/t-dark.png --dark out/theme.mmd; ./ezu.js --png out/t-light.png --light out/theme.mmd; ./ezu.js --png out/t-def.png out/theme.mmd
{ cmp -s out/t-dark.png out/t-def.png && ! cmp -s out/t-dark.png out/t-light.png; } \
  && echo "ok   dark and light flags" || { echo "FAIL dark and light flags"; fail=1; }
./test-syntax.sh || fail=1
[ $fail = 0 ] && echo ALL GREEN || { echo RED; exit 1; }
