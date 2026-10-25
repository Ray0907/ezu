#!/usr/bin/env node
// Render the README snapshots from the real ezu CLI on synthetic documents.
// Usage: node demo/screenshot.mjs   (writes assets/*.png; needs Chrome, or CHROME=/path/to/chrome)
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import stringWidth from 'string-width';
import samples from '../samples.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FONT = 14, CH = FONT * 0.602, LINE = 18, PAD = 20, COLS = 80; // Menlo advance is 0.602 em
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ezu-shot-'));
process.on('exit', () => fs.rmSync(work, { recursive: true, force: true }));

const PALETTE = { 30: '#45475a', 31: '#f38ba8', 32: '#a6e3a1', 33: '#f9e2af', 34: '#89b4fa', 35: '#f5c2e7', 36: '#94e2d5',
  37: '#bac2de', 90: '#7f849c', 91: '#f38ba8', 92: '#a6e3a1', 93: '#f9e2af', 94: '#89b4fa', 95: '#f5c2e7', 96: '#94e2d5', 97: '#cdd6f4' };
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// one line of ezu output (SGR styles, OSC 8 links) to HTML; wide characters take exactly two cells
function lineToHtml(line) {
  const st = { fg: null, bold: false, dim: false, it: false, ul: false };
  let out = '';
  for (const tok of line.split(/(\x1b\[[\d;]*m|\x1b\]8;;[^\x07]*\x07)/)) {
    if (tok.startsWith('\x1b]')) continue;
    if (tok.startsWith('\x1b[')) {
      const p = tok.slice(2, -1).split(';').map(Number);
      for (let i = 0; i < p.length; i++) {
        const c = p[i] || 0;
        if (c === 0) Object.assign(st, { fg: null, bold: false, dim: false, it: false, ul: false });
        else if (c === 1) st.bold = true; else if (c === 2) st.dim = true; else if (c === 3) st.it = true; else if (c === 4) st.ul = true;
        else if (c === 22) st.bold = st.dim = false; else if (c === 23) st.it = false; else if (c === 24) st.ul = false;
        else if (c === 39) st.fg = null; else if (PALETTE[c]) st.fg = PALETTE[c];
        else if (c === 38 && p[i + 1] === 2) { st.fg = `rgb(${p[i + 2]},${p[i + 3]},${p[i + 4]})`; i += 4; }
      }
      continue;
    }
    if (!tok) continue;
    const css = [st.fg && `color:${st.fg}`, st.bold && 'font-weight:700', st.dim && 'opacity:.7', st.it && 'font-style:italic', st.ul && 'text-decoration:underline']
      .filter(Boolean).join(';');
    const html = [...tok].map(ch => stringWidth(ch) === 2 ? `<i class="w">${esc(ch)}</i>` : esc(ch)).join('');
    out += css ? `<span style="${css}">${html}</span>` : html;
  }
  return out;
}

// the real CLI, piped, so it writes its 80-column default; kitty image escapes are placed back as <img>
function terminalHtml(mdFile) {
  const out = execFileSync(path.join(ROOT, 'ezu.js'), [mdFile], { env: { ...process.env, FORCE_COLOR: '3' }, maxBuffer: 1 << 28 }).toString();
  let rows = 0;
  const body = out.replace(/\n$/, '').split('\n').map(line => {
    const chunks = [...line.matchAll(/\x1b_G([^;]*);([^\x1b]*)\x1b\\/g)];
    if (!chunks.length) { rows++; return `<div class="l">${lineToHtml(line) || '&nbsp;'}</div>`; }
    const cols = +chunks[0][1].match(/c=(\d+)/)[1];
    const png = Buffer.from(chunks.map(m => m[2]).join(''), 'base64');
    const h = Math.ceil(cols * CH * (png.readUInt32BE(20) / png.readUInt32BE(16)) / LINE) * LINE;
    rows += h / LINE;
    return `<div style="height:${h}px;margin-left:2ch"><img src="data:image/png;base64,${png.toString('base64')}" style="width:${cols}ch;display:block"></div>`;
  }).join('');
  return { body, rows };
}

const PAGE = inner => `<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;background:#11111b}
.term{box-sizing:border-box;padding:${PAD}px;background:#1e1e2e;color:#cdd6f4;font:${FONT}px/${LINE}px Menlo,monospace}
.l{white-space:pre;height:${LINE}px}.w{display:inline-block;width:2ch;font-style:normal;text-align:center}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:16px;background:#11111b;font:13px/1.2 -apple-system,sans-serif}
.grid figure{margin:0;background:#1e1e2e;border-radius:6px;padding:10px;display:flex;flex-direction:column;align-items:center;gap:8px;justify-content:space-between}
.grid img{max-width:100%;max-height:200px;object-fit:contain}.grid figcaption{color:#9399b2}</style>${inner}`;

function shot(name, html, width, height) {
  const page = path.join(work, name + '.html');
  fs.writeFileSync(page, html);
  const png = path.join(ROOT, 'assets', name + '.png');
  fs.rmSync(png, { force: true });
  try {
    execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
      `--window-size=${width},${height}`, `--screenshot=${png}`, `file://${page}`], { stdio: 'ignore' });
  } catch {} // Chrome exits non-zero on harmless macOS warnings
  if (!fs.existsSync(png)) throw new Error('screenshot failed: ' + name);
  console.log('assets/' + name + '.png');
}

fs.mkdirSync(path.join(ROOT, 'assets'), { recursive: true });
for (const [name, file] of [['terminal', 'demo/demo.md']]) {
  const { body, rows } = terminalHtml(path.join(ROOT, file));
  shot(name, PAGE(`<div class="term" style="width:${Math.ceil(COLS * CH) + 2 * PAD}px">${body}</div>`),
    Math.ceil(COLS * CH) + 2 * PAD, rows * LINE + 2 * PAD);
}

// one real ezu render per diagram type, laid out on a grid
const { toPng } = await import('../ezu.js');
const types = ['flowchart', 'sequence', 'class', 'state', 'er', 'gantt', 'pie', 'gitgraph', 'mindmap'];
const figs = types.map(t => `<figure><img src="data:image/png;base64,${toPng(samples[t]).toString('base64')}"><figcaption>${t}</figcaption></figure>`);
shot('diagrams', PAGE(`<div class="grid">${figs.join('')}</div>`), 1240, 3 * 252 + 4 * 16);
