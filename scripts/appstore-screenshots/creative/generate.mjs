#!/usr/bin/env node
// Rainy Clock — App Store creative assets, "Rain on glass at blue hour".
//
//   node scripts/appstore-screenshots/creative/generate.mjs [--only header-zh-Hant,search-en,...] [--no-review]
//
// Runs from any cwd; every path is resolved from this file. Node 22+, macOS, Google Chrome.
//
// Key art is painted by scene.js inside headless Chrome (canvas 2D, no images): a blue-hour
// city street seen through a rain-covered, fogged window, with the type sitting in a patch
// someone has wiped clear. Type is DOM text in the repo's OFL faces (Inter, Noto Sans TC,
// ../fonts) loaded by @font-face from file:// URLs; no system font is allowed to render. The
// search asset shows the real Alarm-tab capture (docs/appstore-1.8.1-screenshots/raw/*-01-rain)
// as a phone-shaped screen, pixels untouched, bleeding off the bottom just under the Weather
// attribution. Each asset is measured first (dump-dom: type boxes against Apple's safe rect;
// each line's characters against the two faces' cmaps, so a character neither face has, which
// a system font would draw, fails), then screenshotted, re-encoded as opaque 8-bit RGB PNG and
// read back (the art painted, every wordmark/headline line has ink).
//
// Outputs, in docs/appstore-1.8.1-screenshots/creative/:
//   header-<lang>.png  3840 x 1646   product page header
//   search-<lang>.png  3840 x 2560   search results asset
//   review/            in-context mocks (1206 x 2622, light mode) and a sheet; review only:
//                      mock-product-<lang>.png, mock-search-<lang>.png, sheet.png
// An asset that fails a check gets no file (a stale one is removed) and the run exits 1.
// The page HTML it screenshots is left in ../.work/creative-rain/ (gitignored, ~100 KB). Chrome's
// profile goes to the OS temp dir instead: Chrome downloads ~40 MB of models into it.
// Two runs give byte-identical PNGs, given the same Chrome (verified on 154.0.8037.98; the
// run prints the version) and the fonts pinned by sha256 below.

import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { screenshot, dumpDom, readResult, CHROME } from '../chrome.mjs';
import { decodePNG, encodeRGB, toOpaqueRGB } from '../png.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = resolve(HERE, '..');
const REPO = resolve(HERE, '../../..');
const SHOTS = join(REPO, 'docs/appstore-1.8.1-screenshots');
const OUT = join(SHOTS, 'creative'), REVIEW = join(OUT, 'review');
const WORK = join(LIB, '.work/creative-rain'), PROFILE = join(tmpdir(), 'rainyclock-creative-rain-chrome');
mkdirSync(REVIEW, { recursive: true }); mkdirSync(WORK, { recursive: true });
const url = (p) => pathToFileURL(p).href;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// App Store Connect publishes no file-size limit for these; staying under 8 MB is the margin.
const SIZE_LIMIT = 8_000_000;

const FONTS = {
  inter: join(LIB, 'fonts/Inter-opsz-wght.ttf'),
  noto: join(LIB, 'fonts/NotoSansTC-wght.ttf'),
};
// fonts/ is gitignored, so the bytes are pinned here: fetch-fonts.sh downloads them from
// google/fonts at commit e1d6480, and other bytes would move glyphs (and the safe-rect results).
const FONT_SHA256 = {
  inter: '29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031',
  noto: '864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f',
};
const FONT_NAME = { inter: 'Inter', noto: 'Noto Sans TC' };
for (const [k, f] of Object.entries(FONTS)) {
  if (!existsSync(f)) throw new Error(`missing ${f}: run scripts/appstore-screenshots/fetch-fonts.sh`);
  const sha = createHash('sha256').update(readFileSync(f)).digest('hex');
  if (sha !== FONT_SHA256[k]) throw new Error(`${f}: sha256 ${sha}, expected ${FONT_SHA256[k]}; re-run scripts/appstore-screenshots/fetch-fonts.sh`);
}
// The code points each face maps (cmap formats 4 and 12). Chrome draws a character from the
// first face in the stack that maps it, and from a system font when neither does; so a
// character neither maps is exactly a system font rendering.
function cmapOf(file) {
  const b = readFileSync(file);
  let cmap = -1;
  for (let i = 0, n = b.readUInt16BE(4); i < n; i++) if (b.toString('latin1', 12 + 16 * i, 16 + 16 * i) === 'cmap') cmap = b.readUInt32BE(20 + 16 * i);
  if (cmap < 0) throw new Error(`${file}: no cmap table`);
  const subs = [];
  for (let i = 0, n = b.readUInt16BE(cmap + 2); i < n; i++) {
    const r = cmap + 4 + 8 * i, off = cmap + b.readUInt32BE(r + 4);
    subs.push({ pid: b.readUInt16BE(r), eid: b.readUInt16BE(r + 2), off, fmt: b.readUInt16BE(off) });
  }
  const unicode = (s) => s.pid === 0 || (s.pid === 3 && (s.eid === 1 || s.eid === 10));
  const s12 = subs.find((s) => s.fmt === 12 && unicode(s));
  if (s12) {
    const groups = [];
    for (let i = 0, n = b.readUInt32BE(s12.off + 12); i < n; i++) {
      const r = s12.off + 16 + 12 * i;
      groups.push([b.readUInt32BE(r), b.readUInt32BE(r + 4), b.readUInt32BE(r + 8)]);
    }
    return (cp) => groups.some(([a, z, g]) => cp >= a && cp <= z && g + cp - a !== 0);
  }
  const s4 = subs.find((s) => s.fmt === 4 && unicode(s));
  if (!s4) throw new Error(`${file}: no Unicode cmap subtable`);
  const o = s4.off, seg = b.readUInt16BE(o + 6) / 2, ends = o + 14, starts = ends + 2 * seg + 2, deltas = starts + 2 * seg, ranges = deltas + 2 * seg;
  return (cp) => {
    if (cp > 0xffff) return false;
    for (let i = 0; i < seg; i++) {
      if (cp > b.readUInt16BE(ends + 2 * i)) continue;
      const start = b.readUInt16BE(starts + 2 * i);
      if (cp < start) return false;
      const delta = b.readUInt16BE(deltas + 2 * i), ro = b.readUInt16BE(ranges + 2 * i);
      if (!ro) return ((cp + delta) & 0xffff) !== 0;
      const g = b.readUInt16BE(ranges + 2 * i + ro + 2 * (cp - start));
      return g !== 0 && ((g + delta) & 0xffff) !== 0;
    }
    return false;
  };
}
const HAS = Object.fromEntries(Object.entries(FONTS).map(([k, f]) => [k, cmapOf(f)]));
// The PNGs were byte-identical across runs on this Chrome; another build can move them.
const VERIFIED_CHROME = '154.0.8037.98';
const FONT_CSS = `
  @font-face { font-family: "RC Inter"; src: url("${url(FONTS.inter)}") format("truetype"); font-weight: 100 900; font-display: block; }
  @font-face { font-family: "RC Noto TC"; src: url("${url(FONTS.noto)}") format("truetype"); font-weight: 100 900; font-display: block; }`;
// Latin falls to Inter, Han to Noto Sans TC; nothing else is ever allowed to render.
const FAMILY = `'RC Inter', 'RC Noto TC'`;
const FAMILY_ZH = `'RC Noto TC', 'RC Inter'`;

const ICON = join(REPO, 'RainyClock/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png');
const LANG = {
  'zh-Hant': {
    capture: join(SHOTS, 'raw/zh-01-rain.png'),
    wordmark: ['雨天鬧鐘'], under: 'RAINY CLOCK',
    headline: [['下雨天'], ['', '早點', '叫你']],
    sub: ['通勤路線會下雨，', '鬧鐘就提早響'],
    store: { name: '雨天鬧鐘 Rainy Clock', subtitle: '下雨提早叫你起床，颱風停班停課讓你多睡', get: '取得', query: '鬧鐘', shots: ['zh-Hant/01-rain.png', 'zh-Hant/02-typhoon.png', 'zh-Hant/03-rule.png'] },
  },
  en: {
    capture: join(SHOTS, 'raw/en-01-rain.png'),
    wordmark: ['RAINY', 'CLOCK'], under: null,
    headline: [['Rain ahead?'], ['Wake up'], ['', 'earlier', '.']],
    sub: ['Rain on your commute route', 'moves your alarm up.'],
    store: { name: 'Rainy-Clock', subtitle: 'Rain-aware commute alarm', get: 'Get', query: 'alarm', shots: ['en-US/01-rain.png', 'en-US/02-rule.png', 'en-US/03-widget.png'] },
  },
};

// Apple's safe rects (key elements stay inside). The iPhone shows roughly x 330..3530 of the
// header, with round back/share buttons over its top corners.
const KIND = {
  header: { W: 3840, H: 1646, safe: { x: 1097, y: 493, w: 1646, h: 661 }, crop: { x: 320, w: 3200 } },
  search: { W: 3840, H: 2560, safe: { x: 836, y: 765, w: 2168, h: 1030 } },
};
// The header's type as an iPhone shows it: 402 pt across the crop.
const PT_PER_PX = 402 / KIND.header.crop.w;

// ---------------------------------------------------------------------------------------
// Scenes. Sky stops run from the top (incl. the pad above) to the horizon. Blue hour turning
// to dawn under rain cloud: a lifted blue above, an indigo cloud band behind the type, a warm
// horizon with a thin cool line over it. Fog (the condensation on the inside of the pane)
// covers everything except a hand-wiped patch, built from overlapping finger strokes, that
// holds the type.

const SKY = [
  [0, '#3A5DAE'], [0.28, '#4A6FBD'], [0.52, '#5D7EC7'], [0.7, '#7B8BCD'],
  [0.82, '#A797D4'], [0.92, '#E6AABE'], [1, '#FFD4AC'],
];
const GROUND = ['#46437E', '#2A2A5C'];
const FILL = ['#68629E', '#46478A', '#333570'];   // far, mid, near buildings
const RAIN = (k) => ({
  angle: 0.14, calmMul: 0.3,
  layers: [
    { n: 1500 * k, len: [36, 110], w: [1, 1.8], a: [0.07, 0.18], blur: 1.2 },
    { n: 460 * k, len: [110, 270], w: [2, 3.4], a: [0.06, 0.14], blur: 3.2 },
    { n: 80 * k, len: [280, 600], w: [5, 9], a: [0.04, 0.09], blur: 9 },
  ],
});
// Film grain: amplitude of the per-pixel luma noise (sum of three uniforms, σ ≈ 0.5 × amp).
// It is invisible at any size the store shows these, and it is what fills the PNG: the
// search asset is 7.7 MB with none and 10 MB at 1.5, so it gets none. The rain and the
// condensation already break up banding (checked at 4x contrast). The header keeps a trace.
const GRAIN = { header: 1.5, search: 0 };
const GRADE = { sat: 1.15, con: 1.04, gamma: 0.95 };
// finger strokes stacked down the patch: [y, x, rx, ry, rot]
const strokes = (rows) => rows.map(([y, x, rx, ry, rot]) => ({ x, y, rx, ry, rot }));

function sceneFor(kind) {
  const { W, H } = KIND[kind];
  if (kind === 'header') {
    const hz = 1235;
    return {
      W, H, seed: 0x1a2b3c, hz, sunX: 1920, vpX: 1920, sky: SKY, cyanLine: 150, dawn: 1.06,
      clouds: { n: 40, y0: 520, y1: 1040, rgb: '40,48,116', a: [0.08, 0.18] },
      ground: GROUND, bgBlur: 18, minDisc: 24,
      city: [
        { base: hz + 14, hMin: 30, hMax: 210, wMin: 60, wMax: 190, fill: FILL[0], win: { cw: 14, ch: 20, p: 0.18, a: [0.3, 0.6] }, open: 520 },
        { base: hz + 90, hMin: 120, hMax: 420, wMin: 100, wMax: 260, fill: FILL[1], win: { cw: 20, ch: 28, p: 0.28, a: [0.4, 0.85] }, bokehP: 0.006, bokehR: [24, 40], neonP: 0.08, open: 1050 },
        { base: H + 120, hMin: 650, hMax: 1000, wMin: 280, wMax: 520, fill: FILL[2], win: { cw: 32, ch: 44, p: 0.22, a: [0.45, 0.9] }, bokehP: 0.02, bokehR: [40, 84], neonP: 0.2, open: 1650, curve: 1 },
      ],
      // the brand cyan: one sign and one street light, both inside the iPhone's crop
      signs: [{ x: 3180, y: 960, w: 44, h: 150, c: 'cyan', r: 74, a: 0.55 }, { x: 600, y: 1010, w: 130, h: 34, c: 'pink', r: 64, a: 0.38 }],
      street: { lamps: 7, lampX: 1500, lampY: 330, lampR: 170, cars: 5, laneX: 240, laneY: 470, carR: 96, zMin: 1, zMax: 16, cyanP: 0.3 },
      extraLights: [{ x: 420, y: 1560, r: 230, c: 'amber', a: 0.26 }, { x: 3330, y: 1530, r: 240, c: 'cyan', a: 0.26 }],
      rain: RAIN(1),
      calm: [{ x: 1120, y: 560, w: 1600, h: 540 }],
      drops: {
        large: 16, maxR: 46, medium: 220, small: 1100, calmMaxR: 6, calmP: [0, 0.08, 0.2],
        trails: [{ x: 1035, y: 1070, r: 19, len: 620 }, { x: 2835, y: 990, r: 16, len: 540 }, { x: 3380, y: 1400, r: 22, len: 900 }, { x: 500, y: 1260, r: 18, len: 820 }],
      },
      fog: {
        blur: 30, haze: '220,226,250', hazeA: 0.04, hazeTop: 0.025, hazeBottom: 0.10, glowA: 0.9, micro: 70000,
        density: [[0, 0.7], [0.45, 0.78], [1, 0.92]], feather: 9, streaks: 1,
        swipes: strokes([[470, 1990, 560, 90, -0.05], [580, 1915, 820, 108, 0.03], [700, 1950, 930, 116, -0.02], [825, 1910, 975, 118, 0.035],
          [950, 1960, 950, 116, -0.03], [1072, 1900, 870, 110, 0.02], [1185, 1975, 650, 96, -0.04]]),
        drips: [{ x: 1420, from: 1120, len: 260, w: 12 }, { x: 2230, from: 1120, len: 360, w: 13 }, { x: 2560, from: 1100, len: 190, w: 11 }],
        freeDrips: [],
        edgeBox: { x: 850, y: 360, w: 2140, h: 1000 }, edgeBeads: 650, beads: 1600,
      },
      // a band of rain cloud low behind the type, so its lower edge does not sit on the bright horizon
      shades: [{ x: 1920, y: 1010, rx: 1500, ry: 210, rgb: '30,34,96', a: 0.3 }],
      vignette: 0.12, grain: GRAIN.header, grade: GRADE,
    };
  }
  const hz = 1960;
  return {
    W, H, seed: 0x5a5e61, hz, sunX: 2150, vpX: 2560, sky: SKY, cyanLine: 170, dawn: 1.06,
    clouds: { n: 54, y0: 780, y1: 1680, rgb: '40,48,116', a: [0.08, 0.18] },
    ground: GROUND, bgBlur: 24, minDisc: 26,
    city: [
      { base: hz + 16, hMin: 40, hMax: 260, wMin: 60, wMax: 200, fill: FILL[0], win: { cw: 15, ch: 21, p: 0.18, a: [0.3, 0.6] }, open: 560 },
      { base: hz + 130, hMin: 160, hMax: 420, wMin: 110, wMax: 280, fill: FILL[1], win: { cw: 22, ch: 30, p: 0.28, a: [0.4, 0.85] }, bokehP: 0.006, bokehR: [26, 44], neonP: 0.08, open: 1100 },
      { base: H + 160, hMin: 1000, hMax: 1500, wMin: 300, wMax: 560, fill: FILL[2], win: { cw: 36, ch: 48, p: 0.22, a: [0.45, 0.9] }, bokehP: 0.02, bokehR: [44, 90], neonP: 0.2, open: 1900, curve: 1 },
    ],
    signs: [{ x: 3560, y: 1560, w: 50, h: 170, c: 'cyan', r: 84, a: 0.5 }, { x: 330, y: 1700, w: 140, h: 38, c: 'pink', r: 70, a: 0.36 }],
    street: { lamps: 7, lampX: 1700, lampY: 560, lampR: 200, cars: 5, laneX: 300, laneY: 760, carR: 110, zMin: 1, zMax: 16, cyanP: 0.3 },
    extraLights: [{ x: 120, y: 2460, r: 300, c: 'amber', a: 0.24 }, { x: 3740, y: 2420, r: 280, c: 'cyan', a: 0.22 }],
    rain: RAIN(1),
    // the copy's field: drops, rain and bokeh held back so the type sits on calm glass
    calm: [{ x: 760, y: 820, w: 1060, h: 940 }],
    drops: {
      large: 14, maxR: 50, medium: 200, small: 1000, calmMaxR: 5, calmP: [0, 0, 0.06],
      trails: [{ x: 470, y: 1600, r: 21, len: 900 }, { x: 3420, y: 1150, r: 19, len: 760 }, { x: 3640, y: 2200, r: 23, len: 1000 }, { x: 260, y: 2300, r: 18, len: 700 }],
    },
    fog: {
      // micro: condensation beads per header-sized area; fewer than the header's 70000, which
      // looks the same at 1:1 and keeps this asset under SIZE_LIMIT
      blur: 32, haze: '220,226,250', hazeA: 0.04, hazeTop: 0.025, hazeBottom: 0.09, glowA: 0.9, micro: 52000,
      density: [[0, 0.7], [0.45, 0.78], [1, 0.92]], feather: 10, streaks: 1,
      // left ends on one smooth curve (a ragged run of ends read as a dark wedge), right ends as before
      swipes: strokes([[690, 1390, 480, 92, -0.05], [800, 1325, 685, 108, 0.03], [920, 1363, 782, 116, -0.025], [1042, 1345, 795, 118, 0.035],
        [1165, 1365, 830, 116, -0.03], [1288, 1348, 818, 118, 0.025], [1410, 1363, 828, 116, -0.035], [1532, 1338, 792, 116, 0.03],
        [1652, 1353, 782, 112, -0.02], [1768, 1315, 695, 106, 0.04], [1875, 1360, 560, 94, -0.04]]),
      drips: [{ x: 760, from: 1800, len: 320, w: 13 }, { x: 1300, from: 1850, len: 420, w: 14 }, { x: 1640, from: 1800, len: 240, w: 12 }],
      freeDrips: [{ x: 3560, y: 260, len: 560, w: 11 }],
      edgeBox: { x: 360, y: 520, w: 1960, h: 1560 }, edgeBeads: 760, beads: 1600,
    },
    blooms: [{ x: 2440, y: 1560, rx: 1100, ry: 1350, rgb: '150,180,255', a: 0.1 }],
    lowZone: { x0: 560, x1: 1880, yMin: 1790 },
    shades: [{ x: 1260, y: 1560, rx: 1300, ry: 280, rgb: '30,34,96', a: 0.28 }],
    vignette: 0.12, grain: GRAIN.search, grade: GRADE,
  };
}

// ---------------------------------------------------------------------------------------
// Pages.

const SCENE_JS = join(HERE, 'scene.js');

// Fonts: wait for both faces at every weight used, then reveal the type. The measuring
// variant (no painting) also reports what it laid out.
function pageHTML({ W, H, scene, body, css, measure }) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
${FONT_CSS}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: ${W}px; height: ${H}px; overflow: hidden; background: #0A0F2C; }
body { font-family: ${FAMILY}; -webkit-font-smoothing: antialiased; text-rendering: geometricPrecision; font-kerning: normal; }
#art { position: absolute; left: 0; top: 0; width: ${W}px; height: ${H}px; }
.type { visibility: hidden; }
html.fonts .type { visibility: visible; }
${css}
</style></head><body>
<canvas id="art" width="${W}" height="${H}"></canvas>
${body}
<script>window.SCENE = ${JSON.stringify(scene)};</script>
${measure ? '' : `<script src="${url(SCENE_JS)}"></script>`}
<script>
  Promise.all(['500', '600', '700'].map(function (w) {
    return Promise.all([document.fonts.load(w + ' 40px "RC Inter"', 'Ag'), document.fonts.load(w + ' 40px "RC Noto TC"', '雨')]);
  })).then(function () { return document.fonts.ready; }).then(function () {
    var ok = document.fonts.check('600 40px "RC Inter"', 'A') && document.fonts.check('600 40px "RC Noto TC"', '雨');
    if (ok) document.documentElement.classList.add('fonts');
    ${measure ? `
    var out = { fontsOk: ok, boxes: {}, sizes: {}, families: {}, text: {} };
    document.querySelectorAll('[data-key]').forEach(function (el) {
      var r = el.getBoundingClientRect();
      out.boxes[el.dataset.key] = { x: r.left, y: r.top, r: r.right, b: r.bottom };
      var cs = getComputedStyle(el);
      out.sizes[el.dataset.key] = parseFloat(cs.fontSize);
      out.families[el.dataset.key] = cs.fontFamily;
      if (el.textContent.trim()) out.text[el.dataset.key] = el.textContent;
    });
    // ink: the glyph extents on a canvas, for cap-height checks
    var c = document.createElement('canvas').getContext('2d');
    document.querySelectorAll('[data-ink]').forEach(function (el) {
      var cs = getComputedStyle(el);
      c.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
      var m = c.measureText(el.dataset.ink);
      out.sizes[el.dataset.key + ':ink'] = m.actualBoundingBoxAscent;
    });
    var s = document.createElement('script'); s.type = 'application/json'; s.id = 'result';
    s.textContent = JSON.stringify(out); document.body.appendChild(s);` : ''}
  });
</script>
</body></html>`;
}

// Header: the wordmark centred on the safe rect, inside the wiped patch. Shadow at most 10%.
// zh carries the Latin name under the wordmark in brand cyan, at ~12 pt on an iPhone.
const SHADOW = '0 4px 36px rgba(10,12,44,0.10)';
const CYAN = '#6EE3FD', CYAN_LIGHT = '#A9EFFF';
const HEADER_UNDER = { size: 96, track: 0.36, weight: 600 };
function headerPage(lang, measure) {
  const L = LANG[lang], k = KIND.header, cy = k.safe.y + k.safe.h / 2;
  let css, body;
  if (lang === 'zh-Hant') {
    const u = HEADER_UNDER;
    css = `
    .wm { position: absolute; left: 0; width: ${k.W}px; text-align: center; color: #F7F9FF; white-space: nowrap; text-shadow: ${SHADOW}; }
    .zh { top: ${cy - 246}px; font: 600 300px/1 ${FAMILY_ZH}; letter-spacing: 0.24em; padding-left: 0.24em; }
    .sub { top: ${cy + 118}px; font: ${u.weight} ${u.size}px/1 ${FAMILY}; letter-spacing: ${u.track}em; padding-left: ${u.track}em; color: ${CYAN_LIGHT}; }`;
    body = `<div class="type">
      <div class="wm zh"><span data-key="wordmark" data-ink="雨">${esc(L.wordmark[0])}</span></div>
      <div class="wm sub"><span data-key="under" data-ink="R">${esc(L.under)}</span></div>
    </div>`;
  } else {
    css = `
    .wm { position: absolute; left: 0; width: ${k.W}px; text-align: center; color: #F7F9FF; white-space: nowrap;
      font: 600 252px/1 ${FAMILY}; letter-spacing: 0.26em; padding-left: 0.26em; text-shadow: ${SHADOW}; }
    .l1 { top: ${cy - 252 - 22}px; } .l2 { top: ${cy + 22}px; }`;
    body = `<div class="type">
      <div class="wm l1"><span data-key="wordmark" data-ink="R">${esc(L.wordmark[0])}</span></div>
      <div class="wm l2"><span data-key="wordmark2" data-ink="C">${esc(L.wordmark[1])}</span></div>
    </div>`;
  }
  return pageHTML({ W: k.W, H: k.H, scene: sceneFor('header'), body, css, measure });
}

// Search: the real Alarm screen on the right, as large as the safe rect allows, its rim inside
// the safe rect and its alarm card inside it too; the screen bleeds off the bottom just under
// the Weather attribution (capture row 2086), so no empty black shows. The copy sits left on
// the wiped patch, its block centred on the alarm card.
const CAPTURE = { w: 1320, h: 2868, alarmCard: [370, 979], bottomRow: 2150 };
// right: outer edge incl. rim and ring. w is the largest screen whose ring top (y - bez - ring)
// stays inside the safe rect: 1092 puts it at y 765, Apple's safe top, so the status bar is not cut.
const PHONE = { w: 1092, right: 2990, bez: 14, ring: 2 };
const COPY = { left: 872, minGap: 100 };
const SEARCH_TYPE = {
  'zh-Hant': { size: 200, lh: 1.2, track: '0.04em', subSize: 72, subLh: 1.5, subTrack: '0.06em', subGap: 56 },
  en: { size: 156, lh: 1.08, track: '-0.022em', subSize: 63, subLh: 1.42, subTrack: '-0.005em', subGap: 58 },
};
function phoneGeometry() {
  const sw = PHONE.w, sc = sw / CAPTURE.w, sh = Math.round(sw * CAPTURE.h / CAPTURE.w);
  const x = PHONE.right - PHONE.ring - PHONE.bez - sw, y = Math.round(KIND.search.H - CAPTURE.bottomRow * sc);
  const card = { y: y + sc * CAPTURE.alarmCard[0], b: y + sc * CAPTURE.alarmCard[1] };
  return { sw, sh, sc, x, y, card, cardMid: (card.y + card.b) / 2 };
}
function searchPage(lang, measure) {
  const L = LANG[lang], k = KIND.search, zh = lang === 'zh-Hant', T = SEARCH_TYPE[lang];
  const g = phoneGeometry(), bez = PHONE.bez, rad = Math.round(g.sw * 0.13);
  const lines = L.headline.map((parts, i) => {
    const html = parts.length === 1 ? esc(parts[0]) : `${esc(parts[0])}<em>${esc(parts[1])}</em>${esc(parts[2])}`;
    return `<div class="hl"><span data-key="headline${i}" data-ink="${zh ? '雨' : 'R'}">${html}</span></div>`;
  }).join('');
  const subs = L.sub.map((t, i) => `<div class="sl"><span data-key="sub${i}">${esc(t)}</span></div>`).join('');
  // the whole block (headline + subline) centred on the alarm card
  const blockH = L.headline.length * T.size * T.lh + T.subGap + L.sub.length * T.subSize * T.subLh;
  const top = Math.round(g.cardMid - blockH / 2);
  const css = `
  .copy { position: absolute; left: ${COPY.left}px; top: ${top}px; color: #F7F9FF; text-shadow: ${SHADOW}; }
  .hl { white-space: nowrap; font: 600 ${T.size}px/${T.lh} ${zh ? FAMILY_ZH : FAMILY}; letter-spacing: ${T.track}; }
  .hl em { font-style: normal; color: ${CYAN}; }
  .subs { margin-top: ${T.subGap}px; }
  .sl { white-space: nowrap; font: 500 ${T.subSize}px/${T.subLh} ${zh ? FAMILY_ZH : FAMILY}; letter-spacing: ${T.subTrack}; color: rgba(238,244,255,0.94); }
  .phone { position: absolute; left: ${g.x - bez}px; top: ${g.y - bez}px; width: ${g.sw + 2 * bez}px; height: ${g.sh + 2 * bez}px;
    border-radius: ${rad + bez}px; background: #07080F;
    box-shadow: 0 0 0 ${PHONE.ring}px rgba(178,196,244,0.30), 0 40px 120px rgba(8,10,36,0.42), 0 0 220px rgba(110,150,255,0.16); }
  .phone::after { content: ''; position: absolute; inset: 0; border-radius: ${rad + bez}px; pointer-events: none;
    box-shadow: inset 0 0 0 1.5px rgba(255,255,255,0.12); }
  .screen { position: absolute; left: ${bez}px; top: ${bez}px; width: ${g.sw}px; height: ${g.sh}px; border-radius: ${rad}px; overflow: hidden; }
  .screen img { display: block; width: ${g.sw}px; height: ${g.sh}px; }
  .card { position: absolute; left: ${g.x}px; top: ${g.card.y}px; width: ${g.sw}px; height: ${g.card.b - g.card.y}px; pointer-events: none; }`;
  const body = `<div class="phone" data-key="phone"><div class="screen"><img src="${url(L.capture)}"></div></div>
    ${measure ? '<div class="card" data-key="card"></div>' : ''}
    <div class="copy type">${lines}<div class="subs">${subs}</div></div>`;
  return pageHTML({ W: k.W, H: k.H, scene: sceneFor('search'), body, css, measure });
}

// ---------------------------------------------------------------------------------------
// Checks: the faces that rendered, minimum type sizes, everything key inside the safe rect.

function check(kind, lang, res) {
  const k = KIND[kind], s = k.safe, errs = [], notes = [];
  if (!res.fontsOk) errs.push('fonts did not load');
  for (const [key, fam] of Object.entries(res.families)) if (!/^["']RC /.test(fam)) errs.push(`${key}: family ${fam}`);
  // the faces that draw each line: the first in its stack that maps the character, else a system font
  for (const [key, text] of Object.entries(res.text)) {
    const order = /^["']RC Noto TC/.test(res.families[key]) ? ['noto', 'inter'] : ['inter', 'noto'];
    const used = new Set(), missing = new Set();
    for (const ch of text) {
      const face = order.find((f) => HAS[f](ch.codePointAt(0)));
      if (face) used.add(FONT_NAME[face]); else missing.add(`${ch} U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`);
    }
    notes.push(`${key} drawn in ${[...used].join(' + ')}`);
    if (missing.size) errs.push(`${key}: neither OFL face has ${[...missing].join(', ')}, so a system font would draw it`);
  }
  const inX = (b) => b.x >= s.x && b.r <= s.x + s.w, inY = (b) => b.y >= s.y && b.b <= s.y + s.h;
  const tag = (key, b) => `${key} x ${Math.round(b.x)}..${Math.round(b.r)} y ${Math.round(b.y)}..${Math.round(b.b)}`;
  let copyRight = 0;
  for (const [key, b0] of Object.entries(res.boxes)) {
    if (key === 'phone') {
      // the rim and its 2 px ring stay inside horizontally and at the top (a crop to the safe
      // rect keeps the screen's corners and status bar); the bottom bleeds by design
      const b = { ...b0, x: b0.x - PHONE.ring, r: b0.r + PHONE.ring, y: b0.y - PHONE.ring };
      (inX(b) ? notes : errs).push(`${tag(key, b)} (rim incl. ring)${inX(b) ? ' inside safe horizontally' : ' OUTSIDE safe horizontally'}`);
      const top = b.y >= s.y;
      (top ? notes : errs).push(`phone top ${Math.round(b.y)} (rim incl. ring)${top ? ' inside' : ' ABOVE'} safe top ${s.y}`);
      continue;
    }
    if (key === 'card') { (inY(b0) ? notes : errs).push(`${tag(key, b0)} (alarm card)${inY(b0) ? ' inside safe vertically' : ' OUTSIDE safe vertically'}`); continue; }
    if (key.startsWith('headline') || key.startsWith('sub')) copyRight = Math.max(copyRight, b0.r);
    (inX(b0) && inY(b0) ? notes : errs).push(`${tag(key, b0)}${inX(b0) && inY(b0) ? ' inside safe' : ' OUTSIDE safe'}`);
  }
  if (kind === 'search') {
    const gap = res.boxes.phone.x - PHONE.ring - copyRight;
    (gap >= COPY.minGap ? notes : errs).push(`copy to phone gap ${Math.round(gap)} px (min ${COPY.minGap})`);
    const g = phoneGeometry();
    notes.push(`capture scale ${g.sc.toFixed(3)}, rows 0..${Math.round((k.H - g.y) / g.sc)} on canvas`);
  }
  for (const [key, v] of Object.entries(res.sizes)) {
    if (key.endsWith(':ink')) {
      notes.push(`${key} cap/ink height ${Math.round(v)} px`);
      if (kind === 'header' && key.startsWith('wordmark') && v < 180) errs.push(`${key} cap height ${Math.round(v)} < 180`);
    } else if (kind === 'search' && key.startsWith('headline') && v < 150) errs.push(`${key} size ${v} < 150`);
    else if (kind === 'header') {
      const pt = v * PT_PER_PX;
      notes.push(`${key} ${v} px = ${pt.toFixed(1)} pt on an iPhone`);
      if (pt < 11) errs.push(`${key} ${pt.toFixed(1)} pt on an iPhone < 11 pt`);
    }
  }
  return { errs, notes };
}

async function render(file, html, W, H) {
  const name = file.split('/').pop().replace(/\.png$/, '');
  const page = join(WORK, `${name}.html`);
  writeFileSync(page, html);
  await screenshot(page, file, { profileDir: PROFILE, w: W, h: H });
  const img = decodePNG(readFileSync(file));
  if (img.width !== W || img.height !== H) throw new Error(`${name}: ${img.width}x${img.height}, expected ${W}x${H}`);
  writeFileSync(file, encodeRGB(toOpaqueRGB(img, [10, 15, 44])));
  const back = decodePNG(readFileSync(file));
  if (back.channels !== 3) throw new Error(`${name}: not RGB after re-encode`);
  return back;
}

// The render pass loads scene.js and waits on the fonts, and nothing above measures it; so
// read its pixels back. A canvas that did not paint (scene.js threw) leaves the page colour,
// and type still hidden when Chrome took the shot (fonts later than --virtual-time-budget)
// leaves no ink in its own boxes. Each wordmark/headline line is solid #F7F9FF or brand cyan
// inside its strokes: 16,000 px and up per line, against 0-1 px in the art alone (2026-10-10).
const PAGE_BG = [10, 15, 44];
const INK = [[0xF7, 0xF9, 0xFF], [0x6E, 0xE3, 0xFD], [0xA9, 0xEF, 0xFF]], INK_TOL = 12, INK_MIN = 2000;
function inspect(img, res) {
  const { width: W, height: H, data } = img, errs = [], notes = [];
  let bg = 0;
  for (let i = 0; i < data.length; i += 3) if (data[i] === PAGE_BG[0] && data[i + 1] === PAGE_BG[1] && data[i + 2] === PAGE_BG[2]) bg++;
  const share = bg / (W * H);
  (share > 0.01 ? errs : notes).push(`page colour in ${(share * 100).toFixed(2)}% of pixels${share > 0.01 ? ' (> 1%): the art did not paint' : ''}`);
  const near = (i) => INK.some(([r, g, b]) => Math.abs(data[i] - r) <= INK_TOL && Math.abs(data[i + 1] - g) <= INK_TOL && Math.abs(data[i + 2] - b) <= INK_TOL);
  for (const [key, b] of Object.entries(res.boxes)) {
    if (!/^(wordmark|under|headline)/.test(key)) continue;
    let ink = 0;
    for (let y = Math.max(0, Math.floor(b.y)); y < Math.min(H, Math.ceil(b.b)); y++)
      for (let x = Math.max(0, Math.floor(b.x)); x < Math.min(W, Math.ceil(b.r)); x++) if (near((y * W + x) * 3)) ink++;
    (ink < INK_MIN ? errs : notes).push(`${key} ink ${ink} px${ink < INK_MIN ? ` (< ${INK_MIN}): the type did not render` : ''}`);
  }
  return { errs, notes };
}

async function asset(kind, lang) {
  const k = KIND[kind], page = kind === 'header' ? headerPage : searchPage, name = `${kind}-${lang}`;
  const png = join(OUT, `${name}.png`);
  const mfile = join(WORK, `${name}.measure.html`);
  writeFileSync(mfile, page(lang, true));
  const res = readResult(await dumpDom(mfile, { profileDir: PROFILE, w: k.W, h: k.H }));
  const { errs, notes } = check(kind, lang, res);
  console.log(`${name}:\n  ${notes.join('\n  ')}`);
  if (errs.length) {
    rmSync(png, { force: true });
    console.error(`  FAIL\n  ${errs.join('\n  ')}`); process.exitCode = 1; return null;
  }
  const t = Date.now();
  const shot = inspect(await render(png, page(lang, false), k.W, k.H), res);
  const size = statSync(png).size;
  console.log(`  rendered ${png} (${((Date.now() - t) / 1000).toFixed(1)} s, ${(size / 1e6).toFixed(2)} MB)\n  ${shot.notes.join('\n  ')}`);
  if (shot.errs.length) {
    rmSync(png, { force: true });
    console.error(`  FAIL (render)\n  ${shot.errs.join('\n  ')}`); process.exitCode = 1; return null;
  }
  if (size > SIZE_LIMIT) { console.error(`  FAIL  ${(size / 1e6).toFixed(2)} MB > ${SIZE_LIMIT / 1e6} MB: lower GRAIN`); process.exitCode = 1; }
  return png;
}

// ---------------------------------------------------------------------------------------
// Review mocks (not store assets). iPhone 17 Pro, 402 pt @3x = 1206 x 2622, light mode.

const MW = 1206, MH = 2622;
const MOCK_CSS = `${FONT_CSS}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: ${MW}px; height: ${MH}px; overflow: hidden; background: #fff; }
body { font-family: ${FAMILY}; -webkit-font-smoothing: antialiased; color: #000; }
.a { position: absolute; }
.zh { font-family: ${FAMILY_ZH}; }
.status { left: 0; top: 0; width: ${MW}px; height: 160px; font: 600 51px/1 ${FAMILY}; }
.status .t { position: absolute; left: 150px; top: 64px; }
.status .bat { position: absolute; right: 96px; top: 66px; width: 80px; height: 38px; border-radius: 12px; border: 3px solid currentColor; opacity: .9 }
.status .bat::after { content: ''; position: absolute; left: 4px; top: 4px; right: 4px; bottom: 4px; border-radius: 6px; background: currentColor; }
.status .sig { position: absolute; right: 290px; top: 70px; display: flex; gap: 6px; align-items: flex-end; }
.status .sig i { display: block; width: 10px; background: currentColor; border-radius: 3px; }
.island { left: ${(MW - 375) / 2}px; top: 33px; width: 375px; height: 111px; border-radius: 56px; background: #000; }
.btn { width: 112px; height: 112px; border-radius: 56px; background: rgba(255,255,255,0.22); backdrop-filter: blur(20px);
  box-shadow: inset 0 0 0 1.5px rgba(255,255,255,0.32), 0 4px 18px rgba(0,0,0,0.12); }
.btn svg { position: absolute; left: 31px; top: 31px; }
.icon { border-radius: 23.5%; box-shadow: inset 0 0 0 1.5px rgba(0,0,0,0.06); }
.get { border-radius: 999px; text-align: center; font-weight: 700; }
.grey { background: #ECECEF; border-radius: 10px; }
`;
const statusBar = (color) => `<div class="a status" style="color:${color}"><span class="t">9:41</span>
  <span class="sig"><i style="height:16px"></i><i style="height:22px"></i><i style="height:28px"></i><i style="height:34px"></i></span>
  <span class="bat"></span></div><div class="a island"></div>`;
const chevron = `<svg width="50" height="50" viewBox="0 0 50 50"><path d="M30 10 L16 25 L30 40" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const share = `<svg width="50" height="50" viewBox="0 0 50 50"><path d="M25 6 V31 M15 15 L25 5 L35 15" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M17 22 H12 V44 H38 V22 H33" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

// Type in the mocks: explicit properties (no `font` shorthand), the family per language.
const T = (size, weight, color, zh, extra = '') =>
  `font-family:${zh ? FAMILY_ZH : FAMILY};font-size:${size}px;font-weight:${weight};line-height:1.15;color:${color};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;${extra}`;

function mockProduct(lang) {
  const L = LANG[lang], st = L.store, h = KIND.header, sc = MW / h.crop.w, hh = Math.round(h.H * sc);
  const zh = lang === 'zh-Hant';
  const iy = hh + 54, is = 252, tx = 54 + is + 42, tw = MW - tx - 54;
  const shotW = 516, shotH = Math.round(shotW * 2868 / 1320), shotY = iy + is + 300;
  const stat = (x, top, mid, bot) => `<div class="a" style="left:${x}px;top:${iy + is + 70}px;width:250px;text-align:center">
    <div style="${T(27, 600, '#8A8A8E', zh, 'letter-spacing:.04em')}">${top}</div>
    <div class="grey" style="margin:22px auto 0;width:${mid}px;height:44px"></div>
    <div class="grey" style="margin:16px auto 0;width:${bot}px;height:24px"></div></div>`;
  const body = `
  <div class="a" style="left:0;top:0;width:${MW}px;height:${hh}px;overflow:hidden">
    <img class="a" src="${url(join(OUT, `header-${lang}.png`))}" style="left:${-h.crop.x * sc}px;top:0;width:${h.W * sc}px;height:${hh}px">
  </div>
  ${statusBar('#fff')}
  <div class="a btn" style="left:48px;top:190px">${chevron}</div>
  <div class="a btn" style="right:48px;top:190px">${share}</div>
  <img class="a icon" src="${url(ICON)}" style="left:54px;top:${iy}px;width:${is}px;height:${is}px">
  <div class="a" style="left:${tx}px;top:${iy + 24}px;width:${tw}px;${T(62, 700, '#000', zh)}">${esc(st.name)}</div>
  <div class="a" style="left:${tx}px;top:${iy + 102}px;width:${tw}px;${T(40, 400, '#8A8A8E', zh)}">${esc(st.subtitle)}</div>
  <div class="a get" style="left:${tx}px;top:${iy + 168}px;width:186px;height:78px;line-height:78px;background:#0A84FF;${T(40, 700, '#fff', zh, 'line-height:78px;text-align:center')}">${esc(st.get)}</div>
  <div class="a" style="left:54px;top:${iy + is + 40}px;width:${MW - 108}px;height:2px;background:#E5E5EA"></div>
  ${stat(20, zh ? '評分' : 'RATINGS', 110, 180)}${stat(330, zh ? '年齡' : 'AGE', 80, 110)}${stat(640, zh ? '類別' : 'CATEGORY', 120, 140)}${stat(950, zh ? '開發者' : 'DEVELOPER', 90, 150)}
  <div class="a" style="left:54px;top:${iy + is + 236}px;width:${MW - 108}px;height:2px;background:#E5E5EA"></div>
  ${st.shots.slice(0, 3).map((f, i) => `<img class="a" src="${url(join(SHOTS, f))}" style="left:${54 + i * (shotW + 30)}px;top:${shotY}px;width:${shotW}px;height:${shotH}px;border-radius:44px;box-shadow:0 0 0 1.5px rgba(0,0,0,0.06)">`).join('')}`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${MOCK_CSS}</style></head><body>${body}</body></html>`;
}

function mockSearch(lang) {
  const L = LANG[lang], st = L.store, zh = lang === 'zh-Hant';
  const m = 48, aw = MW - 2 * m, ah = Math.round(aw * 2560 / 3840);
  const rowY = 470, is = 186, assetY = rowY + is + 60, tx = m + is + 36, tw = MW - tx - m - 230;
  const chips = (zh ? ['天氣', '鬧鐘 app', '起床', '提醒', '通勤'] : ['clock', 'weather', 'wake up', 'timer', 'sleep']);
  const chipHTML = `<div class="a" style="left:${m}px;top:330px;display:flex;gap:22px;white-space:nowrap">` +
    chips.map((c) => `<div style="height:84px;padding:0 32px;border-radius:42px;border:2px solid #E3E3E8;${T(38, 400, '#1C1C1E', zh, 'line-height:80px;overflow:visible')}">${esc(c)}</div>`).join('') + '</div>';
  const body = `${statusBar('#000')}
  <div class="a" style="left:${m}px;top:180px;width:${MW - 2 * m - 140}px;height:110px;border-radius:55px;background:#EEEEF0"></div>
  <svg class="a" style="left:${m + 36}px;top:213px" width="44" height="44" viewBox="0 0 44 44"><circle cx="18" cy="18" r="13" fill="none" stroke="#3C3C43" stroke-width="5"/><path d="M28 28 L40 40" stroke="#3C3C43" stroke-width="5" stroke-linecap="round"/></svg>
  <div class="a" style="left:${m + 104}px;top:206px;${T(46, 400, '#000', zh)}">${esc(st.query)}</div>
  <div class="a" style="left:${MW - m - 140 - 80}px;top:213px;width:44px;height:44px;border-radius:22px;background:#3C3C43"><svg width="44" height="44" viewBox="0 0 44 44"><path d="M15 15 L29 29 M29 15 L15 29" stroke="#fff" stroke-width="4" stroke-linecap="round"/></svg></div>
  <div class="a" style="left:${MW - m - 110}px;top:180px;width:110px;height:110px;border-radius:55px;background:#EEEEF0"><svg width="110" height="110" viewBox="0 0 110 110"><path d="M40 40 L70 70 M70 40 L40 70" stroke="#000" stroke-width="6" stroke-linecap="round"/></svg></div>
  ${chipHTML}
  <img class="a icon" src="${url(ICON)}" style="left:${m}px;top:${rowY}px;width:${is}px;height:${is}px">
  <div class="a" style="left:${tx}px;top:${rowY + 22}px;width:${tw}px;${T(50, 700, '#000', zh)}">${esc(st.name)}</div>
  <div class="a" style="left:${tx}px;top:${rowY + 90}px;width:${tw}px;${T(38, 400, '#8A8A8E', zh)}">${esc(st.subtitle)}</div>
  <div class="a grey" style="left:${tx}px;top:${rowY + 150}px;width:200px;height:22px"></div>
  <div class="a get" style="left:${MW - m - 200}px;top:${rowY + 50}px;width:200px;height:84px;background:#EEEEF0;${T(42, 700, '#0A84FF', zh, 'line-height:84px;text-align:center')}">${esc(st.get)}</div>
  <img class="a" src="${url(join(OUT, `search-${lang}.png`))}" style="left:${m}px;top:${assetY}px;width:${aw}px;height:${ah}px;border-radius:40px;box-shadow:0 0 0 1.5px rgba(0,0,0,0.05)">
  <div class="a grey" style="left:${m}px;top:${assetY + ah + 90}px;width:${is}px;height:${is}px;border-radius:42px"></div>
  <div class="a grey" style="left:${tx}px;top:${assetY + ah + 120}px;width:380px;height:40px"></div>
  <div class="a grey" style="left:${tx}px;top:${assetY + ah + 186}px;width:520px;height:30px"></div>
  <div class="a get" style="left:${MW - m - 200}px;top:${assetY + ah + 140}px;width:200px;height:84px;background:#EEEEF0"></div>
  <div class="a grey" style="left:${m}px;top:${assetY + ah + 330}px;width:${aw}px;height:${ah}px;border-radius:40px"></div>`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${MOCK_CSS}</style></head><body>${body}</body></html>`;
}

function sheetPage() {
  const tw = 1500, g = 60, lab = 70, hh = Math.round(1646 * tw / 3840), sh = Math.round(2560 * tw / 3840);
  const W = g + 2 * (tw + g), H = g + lab + hh + g + lab + sh + g;
  const tile = (x, y, name, h) => `<div class="a" style="left:${x}px;top:${y}px;font:600 32px/1 ${FAMILY};color:#C9CDD3">${name}.png</div>
    <img class="a" src="${url(join(OUT, name + '.png'))}" style="left:${x}px;top:${y + lab}px;width:${tw}px;height:${h}px;border-radius:12px">`;
  const body = `<div class="a" style="inset:0;background:#202126"></div>` + ['zh-Hant', 'en'].map((lang, i) =>
    tile(g + i * (tw + g), g, `header-${lang}`, hh) + tile(g + i * (tw + g), g + lab + hh + g, `search-${lang}`, sh)).join('');
  return { W, H, html: `<!doctype html><html><head><meta charset="utf-8"><style>${MOCK_CSS.replace(/html, body \{[^}]*\}/, `html, body { width: ${W}px; height: ${H}px; overflow: hidden; }`)}</style></head><body>${body}</body></html>` };
}

// ---------------------------------------------------------------------------------------

const args = process.argv.slice(2);
{
  const v = execFileSync(CHROME, ['--version'], { encoding: 'utf8' }).trim();
  console.log(v);
  if (!v.includes(VERIFIED_CHROME)) console.warn(`  note: byte-identical output was verified on Chrome ${VERIFIED_CHROME}; this build may change the PNG bytes (and the measured boxes)`);
}
const only = args.includes('--only') ? args[args.indexOf('--only') + 1].split(',') : null;
const jobs = [];
for (const kind of ['header', 'search']) for (const lang of ['zh-Hant', 'en']) if (!only || only.includes(`${kind}-${lang}`)) jobs.push([kind, lang]);
for (const [kind, lang] of jobs) await asset(kind, lang);
if (!args.includes('--no-review')) {
  for (const lang of ['zh-Hant', 'en']) {
    if (existsSync(join(OUT, `header-${lang}.png`))) await render(join(REVIEW, `mock-product-${lang}.png`), mockProduct(lang), MW, MH);
    if (existsSync(join(OUT, `search-${lang}.png`))) await render(join(REVIEW, `mock-search-${lang}.png`), mockSearch(lang), MW, MH);
  }
  const s = sheetPage();
  await render(join(REVIEW, 'sheet.png'), s.html, s.W, s.H);
}
console.log('done');
