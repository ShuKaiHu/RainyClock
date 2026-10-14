#!/usr/bin/env node
// Review sheet: every frame of one language side by side on dark grey.
//
//   node sheet.mjs spec.json out-dir [sheet.png]          frames in spec order, from out-dir
//   node sheet.mjs --files a.png b.png ... --out sheet.png  any list of frames
//   options: --width 420 (frame width), --no-labels
//
// With a spec, the sheet goes to out-dir/<lang>-sheet.png unless a path is given, and a frame
// that has no PNG (it failed its checks) shows as an empty slot marked "failed". Each frame is
// first scaled with sips (Core Image resampling, sharper than Chrome's), then laid out by
// headless Chrome and saved as opaque RGB like the frames themselves.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { decodePNG, encodeRGB, toOpaqueRGB } from './png.mjs';
import { screenshot } from './chrome.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FRAME = { W: 1320, H: 2868 };
const GAP = 24;
const BG = '#26272B';

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function parse(argv) {
  const o = { files: null, out: null, width: 420, labels: true, pos: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--files') { o.files = []; while (argv[i + 1] && !argv[i + 1].startsWith('--')) o.files.push(argv[++i]); }
    else if (a === '--out') o.out = argv[++i];
    else if (a === '--width') o.width = +argv[++i];
    else if (a === '--no-labels') o.labels = false;
    else o.pos.push(a);
  }
  return o;
}

async function main() {
  const o = parse(process.argv.slice(2));
  let tiles, out, title;
  if (o.files) {
    if (!o.out || !o.files.length) throw new Error('usage: node sheet.mjs --files a.png b.png ... --out sheet.png');
    tiles = o.files.map((f) => ({ label: basename(f, '.png'), path: resolve(f) }));
    out = resolve(o.out);
    title = 'sheet';
  } else {
    const [specPath, outDir, sheetPath] = o.pos;
    if (!specPath || !outDir) throw new Error('usage: node sheet.mjs spec.json out-dir [sheet.png]');
    const spec = JSON.parse(readFileSync(specPath, 'utf8'));
    const lang = /^zh/.test(spec.lang ?? '') ? 'zh-Hant' : 'en';
    const prefix = spec.prefix ?? lang;
    tiles = spec.frames.map((f) => ({ label: f.id, path: resolve(outDir, `${prefix}-${f.id}.png`) }));
    out = resolve(sheetPath ?? join(outDir, `${prefix}-sheet.png`));
    title = prefix;
  }

  const w = Math.round(o.width), h = Math.round((w * FRAME.H) / FRAME.W);
  const work = join(HERE, '.work', 'sheet');
  mkdirSync(work, { recursive: true });
  tiles.forEach((t, i) => {
    t.ok = existsSync(t.path);
    if (!t.ok) return;
    t.small = join(work, `${i}-${basename(t.path)}`);
    const r = spawnSync('sips', ['--resampleHeightWidth', String(h), String(w), t.path, '--out', t.small], { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`sips failed on ${t.path}: ${r.stderr}`);
  });

  const labelH = o.labels ? 44 : 0;
  const W = tiles.length * w + (tiles.length + 1) * GAP;
  const H = h + labelH + 2 * GAP;
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(title)}</title><style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: ${W}px; height: ${H}px; overflow: hidden; background: ${BG}; }
  body { font: 500 20px/1 system-ui, "PingFang TC", sans-serif; color: rgba(255,255,255,0.62); -webkit-font-smoothing: antialiased; }
  .row { display: flex; gap: ${GAP}px; padding: ${GAP}px; }
  .tile { width: ${w}px; }
  .tile img, .tile .missing { display: block; width: ${w}px; height: ${h}px; }
  .missing { border: 2px dashed rgba(255,120,120,0.55); display: flex !important; align-items: center; justify-content: center; color: rgba(255,140,140,0.9); }
  .label { height: ${labelH}px; padding-top: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style></head><body><div class="row">${tiles.map((t) => `<div class="tile">${t.ok
    ? `<img src="${pathToFileURL(t.small).href}" alt="">`
    : '<div class="missing">failed — no file</div>'}${o.labels ? `<div class="label">${esc(t.label)}</div>` : ''}</div>`).join('')}</div></body></html>`;
  const htmlPath = join(work, 'sheet.html');
  writeFileSync(htmlPath, html);
  mkdirSync(dirname(out), { recursive: true });
  await screenshot(htmlPath, out, { profileDir: join(HERE, 'chrome-profile'), w: W, h: H });
  writeFileSync(out, encodeRGB(toOpaqueRGB(decodePNG(readFileSync(out)))));
  console.log(`${out} (${W}x${H}, ${tiles.filter((t) => t.ok).length}/${tiles.length} frames)`);
}

main().catch((e) => { console.error(e.message); process.exit(1); });
