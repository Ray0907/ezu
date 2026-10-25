#!/usr/bin/env node
// Render Mermaid and Markdown to the terminal (Ghostty / kitty graphics protocol).
// usage: ezu [file] [--light] [--md] [--png out.png]   (stdin if no file; .md files are markdown)
import { render } from 'pele';
import { Resvg } from '@resvg/resvg-js';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { Marked } from 'marked';
import { markedTerminal } from 'marked-terminal';
import markedFootnote from 'marked-footnote';
import chalk from 'chalk';
import wrap from 'wrap-ansi';
import { pathToFileURL } from 'node:url';

const DARK = { bg: '#1e1e2e', fg: '#e6e6ef', muted: '#9a9ab0', line: '#b4b4c8', surface: '#2b2b3d',
  'surface-alt': '#363650', border: '#5a5a78', accent: '#7aa2f7' };
const LIGHT = { bg: '#ffffff', fg: '#1f1f1f', muted: '#6e6e6e', line: '#1f1f1f', surface: '#f3f3f3',
  'surface-alt': '#e6e6e6', border: '#8a8a8a', accent: '#5b7bd5' };

// untrusted text must not carry terminal control sequences (OSC 52, title set, ...); keep \n and \t
export const strip = t => t.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, '');

// resvg can't resolve CSS var(); inline theme values, then the --_x indirections.
export function flatten(svg, theme) {
  svg = svg.replace(/var\(--pele-([\w-]+),\s*([^()]*)\)/g, (_, k, fb) => theme[k] ?? fb);
  const defs = Object.fromEntries([...svg.matchAll(/(--_\w+):([^;"]+)/g)].map(m => [m[1], m[2]]));
  for (let i = 0; i < 3; i++) svg = svg.replace(/var\((--_\w+)\)/g, (_, k) => defs[k] ?? 'currentColor');
  return svg;
}

// resvg loads any non-data href as a local path (absolute paths included) and resvg-js can't turn that off,
// so SVG that came from untrusted text, whether pele output or an .svg file, is neutralized twice:
//  1. selfContained(): parse with a real XML parser, check every attribute of every element (any namespace
//     prefix) whose name ends in href, then re-serialize. resvg then reads our own canonical output, so what
//     was validated is what it interprets; a regex can't promise that (one attribute's value can swallow
//     another's `href="`). Only size-capped PNG data: URIs and simple #ids survive, http(s)/mailto links (meaningless in a
//     raster) become "#", anything else is refused. DOCTYPE/entities and processing instructions are dropped.
//  2. withEmptyCwd(): resvg parses (and loads images) in its constructor against the process cwd, so
//     parsing and rendering run from an empty temp directory and a missed relative path finds nothing.
export function selfContained(svg) {
  if (/<!DOCTYPE|<!ENTITY/.test(svg)) throw new Error('svg with DOCTYPE or entities refused');
  const doc = new DOMParser({ onError: (level, msg) => { if (level !== 'warning') throw new Error('svg is not well-formed: ' + msg); } })
    .parseFromString(svg, 'image/svg+xml');
  const walk = el => {
    for (const a of Array.from(el.attributes)) {
      if (!/href$/i.test(a.name) && a.localName !== 'href') continue;
      if (/^#[\w-]*$/.test(a.value)) continue;
      if (/^data:/.test(a.value)) { // resvg decodes embedded rasters: only PNGs whose IHDR is within the pixel cap
        const m = /^data:image\/png;base64,([A-Za-z0-9+/]{32})/.exec(a.value);
        const h = m && Buffer.from(m[1], 'base64');
        if (!h || h.readUInt32BE(16) > 8000 || h.readUInt32BE(20) > 8000) throw new Error('svg with an unsafe data URI refused');
        continue;
      }
      if (/^(https?:\/\/|mailto:)/.test(a.value)) a.value = '#';
      else throw new Error('svg with an external reference refused');
    }
    for (const n of Array.from(el.childNodes)) if (n.nodeType === 1) walk(n);
  };
  if (!doc.documentElement) throw new Error('svg is empty');
  for (const n of Array.from(doc.childNodes)) if (n.nodeType === 7) doc.removeChild(n);
  walk(doc.documentElement);
  return new XMLSerializer().serializeToString(doc);
}

export function withEmptyCwd(fn) {
  const prev = process.cwd(), empty = fs.mkdtempSync(path.join(os.tmpdir(), 'ezu-'));
  try { process.chdir(empty); return fn(); } finally { process.chdir(prev); fs.rmSync(empty, { recursive: true, force: true }); }
}

export const svgToPng = (svg, opts) => withEmptyCwd(() => new Resvg(selfContained(svg), opts).render().asPng());

// Scanning every system font costs ~200 ms per Resvg, i.e. per diagram, and a Resvg is built for each one.
// Load only the face the text needs: Arial for ASCII, Arial Unicode (covers CJK) otherwise; both render
// the same as the system fallback. Without those files (other platforms) it still scans system fonts.
const FONT_DIRS = ['/System/Library/Fonts/Supplemental/', '/Library/Fonts/'];
export function fontOptions(svg, dirs = FONT_DIRS) {
  const name = /[^\x00-\x7f]/.test(svg) ? 'Arial Unicode.ttf' : 'Arial.ttf';
  const file = dirs.map(d => d + name).find(f => fs.existsSync(f));
  return file ? { loadSystemFonts: false, fontFiles: [file] } : { loadSystemFonts: true };
}

export function toPng(text, { light = false } = {}) {
  const theme = light ? LIGHT : DARK;
  const { svg } = render(text);
  const flat = flatten(selfContained(svg), theme);
  if (/var\(/.test(flat)) throw new Error('unresolved var() in svg');
  return svgToPng(flat, { background: theme.bg, fitTo: { mode: 'zoom', value: 2 }, font: fontOptions(flat) });
}

// Links and images must not go through marked-terminal / wrap-ansi as real escapes: they would count as
// visible text and be split across lines. The renderers emit zero-width SGR-shaped markers instead
// (ESC[951;<n>m link open, ESC[952m link close, ESC[953;<n>m image) and indent() swaps them for the real
// OSC 8 / kitty sequences after wrapping. ESC is stripped from the source first, so input can't forge one.
export const URLS = [];
export const IMAGES = [];
const OSC = u => `\x1b]8;;${u}\x07`;
const ANSI = /\x1b\[[\d;]*m/g;

// index in raw after n visible characters; SGR sequences are zero width
function splitAt(raw, n) {
  const sgr = /\x1b\[[\d;]*m/y;
  let i = 0, seen = 0;
  while (i < raw.length && seen < n) {
    sgr.lastIndex = i;
    const m = sgr.exec(raw);
    if (m) i += m[0].length; else { i++; seen++; }
  }
  return i;
}

// Hard-wrap by display width with a hanging indent: continuation lines keep the line's leading
// spaces / quote bars and align under the text after a list bullet. Table rows are left alone,
// since cutting a box row shatters the table.
export function wrapText(text, w) {
  return text.split('\n').map(raw => {
    const v = raw.replace(ANSI, '');
    if (!v.trim() || /^ *[┌├└][─┬┼┴┤┐┘]*$|^ *│.*│$/.test(v)) return raw;
    const lead = v.match(/^[ │]*((?:[*+-]|\d+\.) )?/);
    const i = splitAt(raw, lead[0].length);
    const cont = lead[0].replace(/[*+\-\d.]/g, ' ').replace(/│/g, chalk.gray('│'));
    const [first, ...rest] = wrap(raw.slice(i), Math.max(w - lead[0].length, 20), { hard: true, trim: false }).split('\n');
    return [raw.slice(0, i) + first, ...rest.map(r => cont + r)].join('\n');
  }).join('\n');
}

// Indent each line and resolve markers. A wrapped line inherits open styles from the previous one,
// which would drag the margin into an open hyperlink or underline; close them around the margin and
// restore after it.
export function indent(text, pad) {
  let link = null, ul = false;
  return text.split('\n').map(line => {
    if (!line) return line;
    const head = (ul ? '\x1b[24m' : '') + pad + (ul ? '\x1b[4m' : '') + (link ? OSC(link) : '');
    const body = line.replace(/\x1b\[951;(\d+)m|\x1b\[952m|\x1b\[953;(\d+)m|\x1b\[([\d;]*)m/g, (m, url, img, sgr) => {
      if (url !== undefined) return OSC(link = URLS[url]);
      if (img !== undefined) return IMAGES[img];
      if (m === '\x1b[952m') { link = null; return OSC(''); }
      for (const c of sgr.split(';')) { if (c === '' || c === '0' || c === '24') ul = false; else if (c === '4') ul = true; }
      return m;
    });
    return head + body + (link ? OSC('') : '');
  }).join('\n');
}

// columns to occupy: natural size (px / cell width), never wider than the terminal
export const fit = (px, termCols, cellW) => Math.min(termCols, Math.max(1, Math.ceil(px / cellW)));

// ask the terminal for its cell size in pixels (CSI 16 t); null if it doesn't answer
function cellWidth() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) return Promise.resolve(null);
  return new Promise(done => {
    let buf = '';
    const finish = v => { clearTimeout(t); process.stdin.off('data', on); process.stdin.setRawMode(false); process.stdin.pause(); done(v); };
    const on = d => { buf += d; const m = buf.match(/\x1b\[6;\d+;(\d+)t/); if (m) finish(+m[1]); };
    const t = setTimeout(() => finish(null), 150);
    process.stdin.setRawMode(true); process.stdin.resume(); process.stdin.on('data', on);
    process.stdout.write('\x1b[16t');
  });
}

// kitty graphics: PNG payload in <=4096-byte base64 chunks; cols sets display width (rows keep aspect)
export function kitty(png, cols) {
  const b64 = png.toString('base64');
  let out = '';
  for (let i = 0; i < b64.length; i += 4096) {
    const more = i + 4096 < b64.length ? 1 : 0;
    out += `\x1b_G${i === 0 ? `a=T,f=100,${cols ? `c=${cols},` : ''}` : ''}m=${more};${b64.slice(i, i + 4096)}\x1b\\`;
  }
  return out + '\n';
}

// Local png/svg inside the document's own directory tree only. Remote URLs, other schemes, absolute
// paths, ".." escapes and symlinks that leave the tree stay text, so a document can't make the viewer
// fetch or display arbitrary files. Reads are bounded and non-blocking (a FIFO would hang), SVG canvases
// are size-capped, and SVGs are neutralized by selfContained / withEmptyCwd.
// Returns PNG bytes or null.
const MAX_BYTES = 20e6, MAX_PX = 4000;
function loadImage(href, baseDir) {
  let p; try { p = decodeURI(href); } catch { return null; }
  if (/^[a-z][a-z\d+.-]*:/i.test(p) || path.isAbsolute(p)) return null;
  let fd;
  try {
    const real = fs.realpathSync(path.resolve(baseDir, p));
    const rel = path.relative(fs.realpathSync(baseDir), real);
    if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
    fd = fs.openSync(real, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > MAX_BYTES) return null;
    const b = Buffer.alloc(st.size);
    for (let n = 0, r = 1; n < st.size && r; n += r) r = fs.readSync(fd, b, n, st.size - n, n);
    if (b.subarray(1, 4).toString() === 'PNG') return b.readUInt32BE(16) > 8000 || b.readUInt32BE(20) > 8000 ? null : b;
    if (!/\.svg$/i.test(real)) return null;
    const text = b.toString();
    const opts = { font: fontOptions(text) };
    const { width, height } = withEmptyCwd(() => new Resvg(selfContained(text), opts)); // parses only; the pixmap is allocated on render
    if (!(width > 0 && height > 0) || width * height > 16e6) return null;
    return svgToPng(text, { ...opts, fitTo: { mode: 'zoom', value: Math.min(2, MAX_PX / Math.max(width, height)) } });
  } catch { return null; } finally { if (fd !== undefined) fs.closeSync(fd); }
}

export function renderMarkdown(src, { W, PAD, cols, cellW, baseDir, light }) {
  URLS.length = IMAGES.length = 0;
  const img = png => { IMAGES.push(kitty(png, fit(png.readUInt32BE(16), cols - 2 * PAD.length, cellW)).slice(0, -1)); return `\n\x1b[953;${IMAGES.length - 1}m\n\n`; };

  // marked-terminal keeps a reference to tableOptions, so mutating it per table sets cli-table3 options
  const tableOptions = { style: { head: ['bold'], border: ['grey'] } };
  const ext = markedTerminal({
    reflowText: false, // wrapText below owns wrapping, so list/quote continuation lines can hang
    // three tones: bold for headings, default for body, grey for secondary
    firstHeading: chalk.bold, heading: chalk.bold, link: chalk.cyan, href: chalk.gray.underline,
    tableOptions,
  });
  const r = ext.renderer, orig = { ...r };

  r.table = function (t) { // right-align numeric columns (marked-terminal has no alignment support)
    tableOptions.colAligns = t.header.map((_, c) => t.align[c] ??
      (t.rows.every(row => /^[\s$€£¥+-]*[\d,.]+%?\s*$/.test(row[c].text)) ? 'right' : 'left'));
    return orig.table.call(this, t);
  };
  r.link = function (t) { // untrusted hrefs: http(s)/mailto only, URL-normalized
    const out = orig.link.call(this, t);
    let u; try { u = new URL(t.href); } catch { return out; }
    if (!['http:', 'https:', 'mailto:'].includes(u.protocol) || URLS.length > 999) return out;
    URLS.push(u.href);
    return `\x1b[951;${URLS.length - 1}m${out}\x1b[952m`;
  };
  r.code = function (t) { // ```mermaid in any fence form, nested anywhere; a broken diagram stays local
    if (!/^mermaid(\s|$)/.test(t.lang ?? '')) return orig.code.call(this, t);
    try { return img(toPng(t.text, { light })); } catch (e) {
      return chalk.dim('mermaid error: ' + strip(String(e.message).split('\n')[0])) + '\n' + orig.code.call(this, { ...t, lang: '' });
    }
  };
  r.image = function (t) {
    const png = IMAGES.length > 999 ? null : loadImage(t.href, baseDir);
    return png ? img(png) : orig.image.call(this, t);
  };
  r.text = function (t) { // a tight list item is a text token that carries its inline tokens; marked-terminal prints t.text raw
    return t.tokens ? this.parser.parseInline(t.tokens) : orig.text.call(this, t);
  };
  r.html = t => t.text.replace(/<!--[\s\S]*?-->/g, '').replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, '');
  r.blockquote = function (t) { // a bar per nesting level marks the quoted region
    const inner = this.parser.parse(t.tokens).trim();
    return inner.split('\n').map(l => chalk.gray('│ ') + chalk.italic(l)).join('\n') + '\n\n';
  };
  r.hr = () => '\n' + chalk.dim('─'.repeat(W)) + '\n\n';
  r.list = function (t) { // marked-terminal always numbers from 1
    // colour leaves whitespace-only lines between nested items; drop them
    const out = orig.list.call(this, t).replace(/^(?: |\x1b\[(?!95[123][;m])[0-9;]*m)+\n/gm, '');
    if (!t.ordered || t.start === 1 || t.start === '') return out;
    const lead = Math.min(...[...out.matchAll(/^( *)\d+\. /gm)].map(m => m[1].length));
    return out.replace(/^( *)(\d+)\. /gm, (m, sp, n) => sp.length === lead ? `${sp}${+n + t.start - 1}. ` : m);
  };

  const md = new Marked(ext, {
    // soft line breaks join into one line (CommonMark); hard breaks are separate br tokens
    walkTokens: t => {
      if (t.type === 'text' && !t.tokens) t.text = t.text.replace(/\n/g, ' ');
      // task boxes become plain leading text, so tight and loose items render the same
      if (t.type === 'list_item' && t.task) {
        const first = t.tokens.find(x => x.tokens);
        if (first) first.tokens.unshift({ type: 'text', raw: '', text: t.checked ? '[x] ' : '[ ] ' });
        t.task = false;
      }
    },
  });
  md.use(markedFootnote(), { extensions: [ // render footnotes as superscripts plus a numbered list
    { name: 'footnoteRef', renderer: t => [...t.id].map(d => '⁰¹²³⁴⁵⁶⁷⁸⁹'[d]).join('') },
    { name: 'footnotes', renderer(t) {
      const items = t.items.map(i => `${i.refs[0].id}. ${this.parser.parse(i.content).trim()}`);
      return items.length ? `\n${chalk.dim('─'.repeat(12))}\n\n${items.join('\n')}\n\n` : '';
    } },
  ] });
  return indent(wrapText(md.parse(strip(src)), W), PAD);
}

// import.meta.main exists in Node >= 24.2 and Bun (a compiled binary's argv[1] isn't the script path).
// Older Node falls back to comparing paths; argv[1] isn't a file when a script is piped to node ("-").
const isMain = import.meta.main ?? (() => {
  try { return import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href; } catch { return false; }
})();
if (isMain) {
  const cellW = (await cellWidth()) ?? 18; // ponytail: 18px ≈ retina cell; query fails on terminals without CSI 16 t
  const cols = process.stdout.columns || 80;
  const PAD = '  '; // left margin so nothing touches the window edge
  const W = Math.min(cols - 2 * PAD.length, 70); // content width
  const a = process.argv.slice(2);
  const pi = a.indexOf('--png');
  const pngOut = pi >= 0 ? a.splice(pi, 2)[1] : null;
  const light = a.includes('--light');
  const file = a.find(x => !x.startsWith('--'));
  try {
    const src = fs.readFileSync(file ?? 0, 'utf8');
    if ((a.includes('--md') || /\.(md|markdown)$/i.test(file ?? '')) && !pngOut) {
      process.stdout.write(renderMarkdown(src, { W, PAD, cols, cellW, light,
        baseDir: file ? path.dirname(path.resolve(file)) : process.cwd() })); // no process.exit: let a pipe drain
    } else {
      const png = toPng(src, { light });
      if (pngOut) fs.writeFileSync(pngOut, png);
      else if (process.stdout.isTTY) process.stdout.write(PAD + kitty(png, fit(png.readUInt32BE(16), cols - 2 * PAD.length, cellW)));
      else process.stdout.write(png);
    }
  } catch (e) { console.error('ezu:', strip(String(e.message))); process.exit(1); }
}
