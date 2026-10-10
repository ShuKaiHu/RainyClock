#!/usr/bin/env node
// Rainy Clock — App Store screenshot compositor ("Quiet Navy", first used for 1.8.1).
// One set-wide headline size, film grain on the canvas, an optional per-frame tint, a
// band-bounded callout and hard layout failures. See README.md.
//
//   node compose.mjs spec.json out-dir [--only id,id] [--weight 400|500|600]
//
// Writes out-dir/<lang>-<id>.png (1320x2868, opaque 8-bit RGB, sRGB chunk) and .jpg (sips,
// quality 100) for every frame that passes its checks. A frame that fails gets no file
// (stale ones from an earlier run are removed) and the run exits 1.
//
// Three stages, all in headless Chrome, one run at a time:
//   1. measure — every frame's copy on one page: picks headline breaks, the set-wide
//      headline size, subline and footnote breaks.
//   2. verify  — every frame's final copy block on one page: heights and widths, from which
//      the set-wide panel top and the per-frame checks follow.
//   3. render  — one screenshot per passing frame.
// No npm dependencies. Node 22+, macOS (sips), Google Chrome.

import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { decodePNG, encodeRGB, encodeGray, toOpaqueRGB } from './png.mjs';
import { screenshot, dumpDom, readResult } from './chrome.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------------------
// The grid, in canvas px (1320 x 2868, the 6.9" App Store slot). Fixed for every frame.
export const GRID = {
  W: 1320,
  H: 2868,
  capW: 1320,            // captures must be exactly this size (6.9" simulator)
  capH: 2868,
  margin: 120,           // copy left edge == panel left edge; also the right margin
  panelWidth: 1080,      // capture scale 1080/1320 = 0.8182
  radiusRatio: 0.075,    // panel corner radius = 7.5% of its width (81 px)
  copyTop: 150,          // top of the headline's first line box
  panelTopMin: 800,      // the 1.7 captures' tab bar (row 2569) stays below the fold from here down
  panelGap: 100,         // the set's panel top sits this far below its tallest copy block...
  minGap: 90,            // ...and a frame whose copy ends closer than this fails
  minVisible: 0.85,      // share of the capture's height that must be on the canvas
};
GRID.s = GRID.panelWidth / GRID.capW;
// The lowest panel top that still shows minVisible of an uncropped capture: 873.
GRID.panelTopMax = Math.floor(GRID.H - GRID.minVisible * GRID.capH * GRID.s);

// Marketing type is set in OFL fonts, not the system's: Apple licenses SF only for UI
// mock-ups, and headlines on store artwork are not that. Inter carries Latin, digits and
// Western punctuation; Han and CJK punctuation fall through to Noto Sans TC (Source Han
// Sans), which follows lang="zh-Hant" for Traditional forms. fetch-fonts.sh downloads both.
const FONT_DIR = join(HERE, 'fonts');
const FONT_FILES = { inter: join(FONT_DIR, 'Inter-opsz-wght.ttf'), notoTC: join(FONT_DIR, 'NotoSansTC-wght.ttf') };
const FAMILY = '"RC Inter", "RC Noto TC", sans-serif';
export const FONT_FACE_CSS = `
  @font-face { font-family: "RC Inter"; src: url("${pathToFileURL(FONT_FILES.inter).href}") format("truetype"); font-weight: 100 900; font-display: block; }
  @font-face { font-family: "RC Noto TC"; src: url("${pathToFileURL(FONT_FILES.notoTC).href}") format("truetype"); font-weight: 100 900; font-display: block; }`;
// A measuring script must not read widths before both faces have loaded at every weight the
// page uses; Chrome only fetches a face once layout asks for it.
const FONTS_READY_JS = `Promise.all(['400','500','600'].map(function (w) {
    return Promise.all([document.fonts.load(w + ' 40px "RC Inter"', 'Ag0'), document.fonts.load(w + ' 40px "RC Noto TC"', '雨')]);
  })).then(function () { return document.fonts.ready; })`;

export const TYPE = {
  'zh-Hant': {
    lang: 'zh-Hant',
    family: FAMILY,
    // indent: optical alignment. Han glyphs carry ~0.07em of side bearing at this size, so
    // the ink would start 11 px inside the panel edge; the indent pulls it back to ~1 px.
    headline: { min: 132, max: 160, lineHeight: 1.18, weight: 500, tracking: '0.02em', indent: '-0.06em' },
    subline: { size: 46, lineHeight: 1.42, tracking: '0.04em', gapEm: 0.2, indent: '-0.06em' },
    tag: { tracking: '0.04em' },
    foot: { tracking: '0.03em' },
    // Headline break classes in priority order: a sentence mark beats a comma beats 、.
    breaks: [/[。？！；：]/, /[，]/, /[、]/],
    clauseMin: 0.3,                 // subline/footnote: a clause break needs short line >= 30% of long
    dropAtBreak: /[，、]$/,          // a line break replaces a trailing comma in display type
    squeeze: /[，、。：；]/,          // centred TW punctuation: trim its side bearings mid-line
    punct: /[，、。：；！？「」『』（）《》〈〉…—・,.;:!?'"()\s]/u,
  },
  en: {
    lang: 'en',
    family: FAMILY,
    headline: { min: 112, max: 140, lineHeight: 1.08, weight: 500, tracking: '-0.02em', indent: '-0.045em' },
    subline: { size: 48, lineHeight: 1.3, tracking: '-0.004em', gapEm: 0.22, indent: '0' },
    tag: { tracking: '0.005em' },
    foot: { tracking: '0' },
    breaks: [/[.?!]$/, /[;:]$/, /[,]$/, /^[—–]$/],
    clauseMin: 0.45,                // "In Taiwan, / a closure where…" (0.2) is refused
    dropAtBreak: null,
    squeeze: null,
    punct: /[\s.,;:!?'"‘’“”()—–-]/u,
  },
};

export const META = {
  gapTop: 30,            // subline -> meta row
  colGap: 22,            // tag -> footnote on one row
  rowGap: 14,            // tag row -> footnote on its own row
  tag: { size: 36, weight: 500, height: 64, padX: 28 },
  foot: { size: 34, weight: 400, lineHeight: 1.36 },
};

export const COLOR = {
  navyTop: '#1A2433',
  navyBottom: '#0F1624',
  glow: '110, 227, 253',                 // #6EE3FD, the widget's glow
  text: '#F4F7FB',
  sub: 'rgba(226, 234, 246, 0.72)',
  foot: 'rgba(226, 234, 246, 0.60)',
  highlight: '#6EE3FD',
  tag: '#6EE3FD',
};

export const GRAIN = { sigma: 0.045, tile: 512, seed: 0x52c10c };   // σ = 4.5% of full scale
export const TINT = { radius: 900, strength: 0.16, min: 0.14, max: 0.18 };
export const CALLOUT = { maxScale: 1.3, minScale: 1.05, overhang: 40, radius: 84 };

// ---------------------------------------------------------------------------------------

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const jsonForScript = (v) => JSON.stringify(v).replace(/</g, '\\u003c');

function pngSize(path) {
  const b = readFileSync(path);
  if (b.length < 24 || b.toString('ascii', 12, 16) !== 'IHDR') throw new Error('not a PNG');
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

function hexToRgb(hex) {
  const h = String(hex).replace('#', '');
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  if (!/^[0-9a-f]{6}$/i.test(full)) throw new Error(`bad colour "${hex}"`);
  const n = parseInt(full, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// English copy gets typographic quotes: Taiwan's -> Taiwan’s, "x" -> “x”. Applied to every
// text field (highlight included, so it still matches) before anything is measured.
export function smartQuotes(s) {
  if (s == null) return s;
  return String(s)
    .replace(/([\p{L}\p{N}])'([\p{L}\p{N}])/gu, '$1\u2019$2')
    .replace(/(^|[\s(\[—–-])'/gu, '$1\u2018')
    .replace(/'/g, '\u2019')
    .replace(/(^|[\s(\[—–-])"/gu, '$1\u201C')
    .replace(/"/g, '\u201D');
}

// Number of "real" characters in a line: what is left after punctuation and spaces.
const letters = (s, t) => [...s].filter((c) => !t.punct.test(c)).length;

// Candidate line splits for a headline. Explicit "\n" (or "|") wins. Otherwise break after
// the strongest punctuation class present, at the occurrence nearest the middle, as long as
// both sides keep two real characters (zh) or a word (en). With no usable mark, every
// break point that leaves no orphan is a candidate and the measuring page keeps the one
// with the narrowest widest line. In zh-Hant a ，or 、 that ends a line is dropped.
export function headlineCandidates(text, t, keepBreakPunct) {
  const finish = (lines) => (t.dropAtBreak && !keepBreakPunct
    ? lines.map((l, i) => (i < lines.length - 1 ? l.replace(t.dropAtBreak, '') : l))
    : lines);
  if (/\n|\|/.test(text)) {
    return { explicit: true, cands: [finish(text.split(/\n|\|/).map((s) => s.trim()).filter(Boolean))] };
  }
  if (t.lang === 'en') {
    const words = text.trim().split(/\s+/);
    if (words.length < 2) return { explicit: false, cands: [[text.trim()]] };
    const split = (i) => [words.slice(0, i + 1).join(' '), words.slice(i + 1).join(' ')];
    for (const cls of t.breaks) {
      let best = -1, bestDist = Infinity;
      words.forEach((w, i) => {
        if (i === words.length - 1 || !cls.test(w)) return;
        const d = Math.abs(split(i)[0].length - text.length / 2);
        if (d < bestDist) { bestDist = d; best = i; }
      });
      if (best >= 0) return { explicit: false, cands: [split(best)] };
    }
    return { explicit: false, cands: words.slice(0, -1).map((_, i) => split(i)) };
  }
  const chars = [...text.trim()];
  const ok = (a, b) => letters(a, t) >= 2 && letters(b, t) >= 2;
  const at = (i) => [chars.slice(0, i + 1).join('').trim(), chars.slice(i + 1).join('').trim()];
  for (const cls of t.breaks) {
    let best = -1, bestDist = Infinity;
    chars.forEach((c, i) => {
      if (i === chars.length - 1 || !cls.test(c)) return;
      const [a, b] = at(i);
      if (!ok(a, b)) return;
      const d = Math.abs(i + 1 - chars.length / 2);
      if (d < bestDist) { bestDist = d; best = i; }
    });
    if (best >= 0) return { explicit: false, cands: [finish(at(best))] };
  }
  const cands = [];
  chars.forEach((c, i) => {
    if (i === chars.length - 1 || t.punct.test(chars[i + 1])) return;   // no line starts with a mark
    const [a, b] = at(i);
    if (ok(a, b)) cands.push(finish([a, b]));
  });
  return { explicit: false, cands: cands.length ? cands : [[text.trim()]] };
}

// Headline lines as HTML, with one highlighted substring (it may span a line break).
// Mid-line CJK punctuation is wrapped so its centred glyph can be squeezed (span.p), and a
// line-final ？！ has its leading side bearing trimmed (span.pe).
// Each line's content sits in an inline-block .lt so its width can be measured.
function linesHTML(lines, highlight, squeeze) {
  const flat = lines.join('');
  let hlStart = -1, hlEnd = -1;
  if (highlight) {
    hlStart = flat.indexOf(highlight);
    if (hlStart >= 0) hlEnd = hlStart + highlight.length;
  }
  let pos = 0;
  return lines.map((line) => {
    const parts = [];
    let inHl = false;
    const units = [...line];
    units.forEach((ch, k) => {
      const hl = pos >= hlStart && pos < hlEnd;
      if (hl !== inHl) { parts.push(hl ? '<em>' : '</em>'); inHl = hl; }
      const isMidPunct = squeeze && squeeze.test(ch) && k > 0 && k < units.length - 1;
      // A line-final ？ or ！ (zh) is centred in its em box, so it would stand ~0.4em off
      // the character before it, over twice the normal gap; its leading half is trimmed.
      const isEndMark = squeeze && /[？！]/.test(ch) && k > 0 && k === units.length - 1;
      parts.push(isMidPunct ? `<span class="p">${esc(ch)}</span>` : isEndMark ? `<span class="pe">${esc(ch)}</span>` : esc(ch));
      pos += ch.length;
    });
    if (inHl) parts.push('</em>');
    return `<span class="line"><span class="lt">${parts.join('')}</span></span>`;
  }).join('');
}

// The copy block of one frame, every line fixed (nothing wraps on its own in the final page).
function copyHTML(frame, L) {
  const t = L.t;
  const sub = L.subLines?.length
    ? `<p class="subline">${L.subLines.map((l) => `<span class="sl">${esc(l)}</span>`).join('')}</p>`
    : '';
  let meta = '';
  if (frame.tag || L.footLines?.length) {
    const foot = L.footLines?.length
      ? `<span class="foot${L.footBeside ? '' : ' own'}">${L.footLines.map((l) => `<span class="fl">${esc(l)}</span>`).join('')}</span>`
      : '';
    meta = `<div class="meta">${frame.tag ? `<span class="tag">${esc(frame.tag)}</span>` : ''}${foot}</div>`;
  }
  return `<header class="copy"><h1>${linesHTML(L.lines, frame.highlight, t.squeeze)}</h1>${sub}${meta}</header>`;
}

function typeCSS(t, hs, weight) {
  const g = GRID;
  return `${FONT_FACE_CSS}
  * { margin: 0; padding: 0; box-sizing: border-box; }
  :root { --hs: ${hs}px; }
  body {
    font-family: ${t.family};
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
    color: ${COLOR.text};
  }
  .copy { position: absolute; left: ${g.margin}px; top: ${g.copyTop}px; width: ${g.panelWidth}px; }
  h1 {
    font-size: var(--hs); line-height: ${t.headline.lineHeight}; font-weight: ${weight};
    letter-spacing: ${t.headline.tracking}; margin-left: ${t.headline.indent};
  }
  h1 .line { display: block; white-space: nowrap; }
  h1 .lt { display: inline-block; white-space: nowrap; }
  h1 em { font-style: normal; color: ${COLOR.highlight}; }
  h1 .p { margin: 0 -0.2em; }
  h1 .pe { margin-left: -0.2em; }
  .subline, .sub-type {
    font-size: ${t.subline.size}px; line-height: ${t.subline.lineHeight}; font-weight: 400;
    letter-spacing: ${t.subline.tracking}; color: ${COLOR.sub};
  }
  .subline { margin-top: calc(var(--hs) * ${t.subline.gapEm}); margin-left: ${t.subline.indent}; }
  .subline .sl, .foot .fl { display: block; white-space: nowrap; width: max-content; }
  .meta {
    margin-top: ${META.gapTop}px; display: flex; flex-wrap: wrap; align-items: center;
    column-gap: ${META.colGap}px; row-gap: ${META.rowGap}px;
  }
  .tag, .tag-type {
    font-size: ${META.tag.size}px; font-weight: ${META.tag.weight}; letter-spacing: ${t.tag.tracking};
    white-space: nowrap; line-height: 1;
  }
  .tag {
    flex: none; display: inline-flex; align-items: center; height: ${META.tag.height}px;
    padding: 0 ${META.tag.padX}px; border-radius: ${META.tag.height / 2}px;
    color: ${COLOR.tag}; background: rgba(${COLOR.glow}, 0.10);
    box-shadow: inset 0 0 0 2px rgba(${COLOR.glow}, 0.42);
  }
  .foot, .foot-type {
    font-size: ${META.foot.size}px; font-weight: ${META.foot.weight}; line-height: ${META.foot.lineHeight};
    letter-spacing: ${t.foot.tracking}; color: ${COLOR.foot};
  }
  .foot { flex: none; }
  .foot.own { flex-basis: 100%; }
`;
}

// ---------------------------------------------------------------------------------------
// Stage 1: measure. Every frame's candidate headlines, subline and meta on one page.

function measureHTML(items, t, weight) {
  const g = GRID;
  const sections = items.map((it, i) => `
  <section data-f="${i}">${it.cands.map((c, j) => `<h1 class="cand" data-c="${j}">${linesHTML(c, it.frame.highlight, t.squeeze)}</h1>`).join('')}</section>`).join('');
  const data = items.map((it) => ({
    sub: it.frame.subline ?? null,
    tag: it.frame.tag ?? null,
    foot: it.frame.footnote ?? null,
  }));
  const cfg = { maxW: g.panelWidth, min: t.headline.min, max: t.headline.max, zh: t.lang !== 'en', tagPad: META.tag.padX, colGap: META.colGap, clauseMin: t.clauseMin };
  return `<!doctype html>
<html lang="${t.lang}"><head><meta charset="utf-8"><title>measure</title>
<style>${typeCSS(t, t.headline.max, weight)}
  html, body { width: ${g.W}px; background: #000; }
  section { width: ${g.panelWidth}px; }
  .probe { display: inline-block; white-space: nowrap; }
  .wrapbox { display: block; white-space: normal; text-wrap: pretty; width: ${g.panelWidth}px; }
</style></head>
<body>${sections}
<div id="probes"></div>
<script>
${FONTS_READY_JS}.then(function () {
  var C = ${jsonForScript(cfg)}, D = ${jsonForScript(data)};
  var out = { frames: [] };
  try {
    var root = document.documentElement;
    var setHs = function (px) { root.style.setProperty('--hs', px + 'px'); };
    var widthOf = function (el) { return el.getBoundingClientRect().width; };
    var lineWidths = function (h) { return Array.prototype.map.call(h.querySelectorAll('.lt'), widthOf); };

    // 1. per frame, the candidate split whose widest line is narrowest (at the max size)
    setHs(C.max);
    var chosen = [];
    document.querySelectorAll('section').forEach(function (sec) {
      var best = null;
      sec.querySelectorAll('h1.cand').forEach(function (h) {
        var m = Math.max.apply(null, lineWidths(h));
        if (!best || m < best.m - 0.01) best = { c: +h.dataset.c, m: m, h: h };
      });
      sec.querySelectorAll('h1.cand').forEach(function (h) { if (h !== best.h) h.remove(); });
      chosen[+sec.dataset.f] = best;
    });

    // 2. one size for the set: the largest whose widest line (any frame) fits the measure.
    // A frame whose line overflows even at the minimum fails on its own and does not set the
    // size, just as a broken frame does not set the panel top: otherwise one bad headline
    // would render every other frame at the minimum, and re-rendering the fixed frame alone
    // (--only) would then leave a set of two sizes on disk.
    setHs(C.min);
    var atMin = chosen.map(function (b) { return lineWidths(b.h); });
    var unfit = atMin.map(function (ws) { return ws.some(function (w) { return w > C.maxW + 0.5; }); });
    setHs(C.max);
    var widest = function () {
      var r = { w: 0, text: '', f: -1 };
      chosen.forEach(function (b, f) {
        if (unfit[f]) return;
        b.h.querySelectorAll('.lt').forEach(function (e) {
          var w = widthOf(e); if (w > r.w) r = { w: w, text: e.textContent, f: f };
        });
      });
      return r;
    };
    var hs = C.max, W = widest();
    if (W.w > C.maxW + 0.5) {
      hs = Math.max(C.min, Math.floor(C.max * C.maxW / W.w));
      setHs(hs); W = widest();
      while (W.w > C.maxW + 0.5 && hs > C.min) { hs--; setHs(hs); W = widest(); }
      while (hs < C.max) {
        setHs(hs + 1); var W2 = widest();
        if (W2.w <= C.maxW + 0.5) { hs++; W = W2; } else { setHs(hs); break; }
      }
    }
    out.hs = hs; out.widest = W;
    out.fitSize = W.w > 0 ? Math.floor(hs * C.maxW / W.w) : C.max;   // what the widest line alone would allow

    // 3. sublines and footnotes: one line if it fits; else break at the clause mark that
    // gives the most even pair of lines; else let Chrome wrap it (text-wrap: pretty).
    var probes = document.getElementById('probes');
    var natW = function (text, cls) {
      var p = document.createElement('span'); p.className = 'probe ' + cls; p.textContent = text;
      probes.appendChild(p); var w = widthOf(p); p.remove(); return w;
    };
    var wrapNatural = function (text, cls) {
      var box = document.createElement('div'); box.className = 'wrapbox ' + cls; box.textContent = text;
      probes.appendChild(box);
      var tn = box.firstChild, r = document.createRange(), lines = [], cur = '', top = null;
      for (var i = 0; i < text.length; i++) {
        r.setStart(tn, i); r.setEnd(tn, i + 1);
        var rs = r.getClientRects();
        if (rs.length) {
          if (top !== null && rs[0].top > top + 2) { lines.push(cur); cur = ''; }
          top = rs[0].top;
        }
        cur += text[i];
      }
      lines.push(cur); box.remove();
      return lines.map(function (l) { return l.trim(); }).filter(Boolean);
    };
    var marks = C.zh ? '，、；：。！？' : '';
    // Kinsoku for the zh fallback: no line starts with a closing mark, none ends with an
    // opening one, and a Latin word or number ("AI", "26", "50%") is never split.
    var noStart = '，、。：；！？」』）》〉…%・', noEnd = '「『（《〈';
    var latin = /[A-Za-z0-9%.]/;
    // One line if it fits. Otherwise the pair of lines that fits and is most even: at a
    // clause mark first, as long as the shorter line keeps C.clauseMin of the longer (so
    // "In Taiwan, / a closure where you live or work…" is refused); else at any word (en)
    // or any allowed character boundary (zh). Only when no two-line split fits does Chrome
    // wrap it, which yields 3+ lines and so a hard failure. Chrome's text-wrap: pretty is
    // not relied on: it left "earlier." alone on a line in testing.
    var breakLines = function (text, cls) {
      if (text.indexOf('\\n') >= 0) {
        var ex = text.split('\\n').map(function (l) { return l.trim(); }).filter(Boolean);
        return { lines: ex, widths: ex.map(function (l) { return natW(l, cls); }), how: 'explicit' };
      }
      var w = natW(text, cls);
      if (w <= C.maxW + 0.5) return { lines: [text], widths: [w], how: 'one line' };
      var clause = null, any = null, weak = null;
      // zh word boundaries from ICU's dictionary segmenter, so the fallback splits 停班|停課
      // rather than 停|班. Without Intl.Segmenter every character boundary is allowed.
      var words = null;
      if (C.zh && typeof Intl !== 'undefined' && Intl.Segmenter) {
        words = {};
        Array.from(new Intl.Segmenter('zh-Hant', { granularity: 'word' }).segment(text)).forEach(function (sg) { words[sg.index] = true; });
      }
      for (var i = 1; i < text.length - 1; i++) {
        var a, b, isClause, isWeak = false;
        if (C.zh) {
          isClause = marks.indexOf(text[i]) >= 0;
          if (!isClause) {
            if (noStart.indexOf(text[i + 1]) >= 0 || noEnd.indexOf(text[i]) >= 0) continue;
            if (latin.test(text[i]) && latin.test(text[i + 1])) continue;
            if (text[i + 1] === ' ') continue;   // a Han–Latin space: break at the space itself
            if (words && !words[i + 1] && text[i] !== ' ') continue;
          }
          a = text.slice(0, i + 1).trim(); b = text.slice(i + 1).trim();
        } else {
          if (text[i + 1] !== ' ') continue;
          isClause = ',;:—.?!'.indexOf(text[i]) >= 0;
          a = text.slice(0, i + 1).trim(); b = text.slice(i + 1).trim();
          // a line that ends on "a" or "I" reads as a stumble; use it only if nothing else fits
          isWeak = /(^|\\s)[aAI]$/.test(a);
        }
        if (!a || !b) continue;
        var wa = natW(a, cls), wb = natW(b, cls);
        if (wa > C.maxW + 0.5 || wb > C.maxW + 0.5) continue;
        var m = Math.max(wa, wb), even = Math.min(wa, wb) / m;
        var cand = { m: m, lines: [a, b], widths: [wa, wb] };
        if (isClause && even >= C.clauseMin && (!clause || m < clause.m)) clause = cand;
        if (isWeak) { if (!weak || m < weak.m) weak = cand; }
        else if (!any || m < any.m) any = cand;
      }
      if (clause) return { lines: clause.lines, widths: clause.widths, how: 'clause mark' };
      if (any || weak) { var p = any || weak; return { lines: p.lines, widths: p.widths, how: 'balanced' }; }
      var nat = wrapNatural(text, cls);
      return { lines: nat, widths: nat.map(function (l) { return natW(l, cls); }), how: 'wrapped' };
    };

    D.forEach(function (d, f) {
      var r = { cand: chosen[f].c, headWidths: lineWidths(chosen[f].h), unfit: unfit[f], headWidthsMin: atMin[f] };
      if (d.sub) r.sub = breakLines(d.sub, 'sub-type');
      if (d.tag) r.tag = { w: natW(d.tag, 'tag-type') + 2 * C.tagPad };
      if (d.foot) {
        var fw = natW(d.foot, 'foot-type');
        var room = d.tag ? C.maxW - r.tag.w - C.colGap : C.maxW;
        if (d.foot.indexOf('\\n') < 0 && fw <= room + 0.5) r.foot = { beside: !!d.tag, lines: [d.foot], widths: [fw], how: 'one line' };
        else { r.foot = breakLines(d.foot, 'foot-type'); r.foot.beside = false; }
      }
      out.frames.push(r);
    });
  } catch (e) { out.error = String(e && e.stack || e); }
  var s = document.createElement('script'); s.type = 'application/json'; s.id = 'result';
  s.textContent = JSON.stringify(out).replace(/</g, '\\\\u003c');
  document.body.appendChild(s);
});
</script>
</body></html>`;
}

// ---------------------------------------------------------------------------------------
// Stage 2: verify. Every frame's final copy block, positioned exactly as on its canvas.

function verifyHTML(blocks, t, hs, weight) {
  const g = GRID;
  return `<!doctype html>
<html lang="${t.lang}"><head><meta charset="utf-8"><title>verify</title>
<style>${typeCSS(t, hs, weight)}
  html, body { width: ${g.W}px; background: #000; }
  .slot { position: relative; width: ${g.W}px; height: ${g.H}px; overflow: hidden; }
</style></head>
<body>${blocks.map((b, i) => `<div class="slot" data-f="${i}">${b}</div>`).join('\n')}
<script>
${FONTS_READY_JS}.then(function () {
  var out = { frames: [] };
  try {
    document.querySelectorAll('.slot').forEach(function (slot) {
      var top0 = slot.getBoundingClientRect().top;
      var rect = function (el) { var r = el.getBoundingClientRect(); return { l: r.left, t: r.top - top0, r: r.right, b: r.bottom - top0, w: r.width, h: r.height }; };
      var all = function (sel) { return Array.prototype.map.call(slot.querySelectorAll(sel), rect); };
      var copy = slot.querySelector('.copy'), tag = slot.querySelector('.tag'), foot = slot.querySelector('.foot');
      out.frames.push({
        copy: rect(copy), head: all('h1 .lt'), sub: all('.subline .sl'), foot: all('.foot .fl'),
        tag: tag ? Object.assign(rect(tag), { sw: tag.scrollWidth, cw: tag.clientWidth }) : null,
        footBox: foot ? rect(foot) : null,
      });
    });
  } catch (e) { out.error = String(e && e.stack || e); }
  var s = document.createElement('script'); s.type = 'application/json'; s.id = 'result';
  s.textContent = JSON.stringify(out).replace(/</g, '\\\\u003c');
  document.body.appendChild(s);
});
</script>
</body></html>`;
}

// ---------------------------------------------------------------------------------------
// Callout: an enlarged crop of the same capture, sitting over its own place in the panel.
// It grows by at most 1.3x the panel scale, and less when its band (the free rows around
// it, in capture px) or the 40 px overhang limit says so. Below 1.05x it is not worth it.

function calloutGeometry(c, crop, panelTop) {
  const g = GRID, s = g.s, errors = [];
  const band = Array.isArray(c.band) ? { top: c.band[0], bottom: c.band[1] } : c.band;
  if (!band || !Number.isFinite(band.top) || !Number.isFinite(band.bottom) || band.bottom <= band.top) {
    return { errors: ['callout needs "band": {"top", "bottom"} in capture px (find it with tools/textrows.mjs)'] };
  }
  if (band.top > c.y + 0.5 || band.bottom < c.y + c.h - 0.5) {
    return { errors: [`callout band ${band.top}-${band.bottom} does not contain its source rows ${c.y}-${c.y + c.h}`] };
  }
  const limits = {
    asked: c.scale ?? CALLOUT.maxScale,
    max: CALLOUT.maxScale,
    band: (band.bottom - band.top) / c.h,
    overhang: (g.panelWidth + 2 * CALLOUT.overhang) / (c.w * s),
  };
  let k = Math.min(...Object.values(limits));
  const limitedBy = Object.entries(limits).find(([, v]) => v === k)[0];
  if (k < CALLOUT.minScale) {
    errors.push(`callout crosses its band: it can only grow ${k.toFixed(3)}x (limited by ${limitedBy}), min ${CALLOUT.minScale}x`);
    return { errors };
  }
  const z = s * k, cw = c.w * z, ch = c.h * z, hCap = c.h * k;
  let topCap = c.y + c.h / 2 - hCap / 2 + (c.nudge?.y ?? 0);
  topCap = Math.min(Math.max(topCap, band.top), band.bottom - hCap);
  let left = g.margin + (c.x + c.w / 2 + (c.nudge?.x ?? 0)) * s - cw / 2;
  left = Math.min(Math.max(left, g.margin - CALLOUT.overhang), g.margin + g.panelWidth + CALLOUT.overhang - cw);
  const top = panelTop + (topCap - crop.top) * s;
  // Assertions on the final rectangle (in capture px for the band).
  const capTop = (top - panelTop) / s + crop.top, capBottom = capTop + ch / s;
  if (capTop < band.top - 0.5 || capBottom > band.bottom + 0.5) errors.push(`callout crosses its band (${capTop.toFixed(0)}-${capBottom.toFixed(0)} vs ${band.top}-${band.bottom})`);
  const over = Math.max(g.margin - left, left + cw - (g.margin + g.panelWidth), panelTop - top);
  if (over > CALLOUT.overhang + 0.5) errors.push(`callout overhangs the panel by ${over.toFixed(0)} px (max ${CALLOUT.overhang})`);
  if (top + ch > g.H) errors.push('callout runs off the bottom of the canvas');
  return {
    errors, k, z, limitedBy, left, top, cw, ch,
    radius: (c.radius ?? CALLOUT.radius) * z,
    img: { w: g.capW * z, left: -c.x * z, top: -c.y * z },
    overhang: Math.max(0, (cw - g.panelWidth) / 2),
    band, capTop, capBottom,
  };
}

// ---------------------------------------------------------------------------------------
// Stage 3: the frame page.

function frameHTML(frame, L, set) {
  const g = GRID, t = L.t;
  const imgURL = pathToFileURL(frame.screenshot).href;
  const crop = L.crop;
  const panelH = crop.bottom > 0 ? Math.round((g.capH - crop.top - crop.bottom) * g.s) : g.H - set.panelTop + 200;

  let tintLayer = '';
  if (frame.tint) {
    const [r, gg, b] = hexToRgb(frame.tint);
    const a = Math.min(TINT.max, Math.max(TINT.min, frame.tintStrength ?? TINT.strength));
    const c = (k) => `rgba(${r}, ${gg}, ${b}, ${(a * k).toFixed(4)})`;
    // An eased fall-off, so the glow has no visible rim.
    tintLayer = `radial-gradient(circle ${TINT.radius}px at 100% 0%, ${c(1)} 0%, ${c(0.72)} 30%, ${c(0.33)} 60%, ${c(0.08)} 85%, ${c(0)} 100%),`;
  }

  let callout = '';
  if (L.callout) {
    const k = L.callout;
    callout = `
  <div class="callout" style="left:${k.left.toFixed(2)}px;top:${k.top.toFixed(2)}px;width:${k.cw.toFixed(2)}px;height:${k.ch.toFixed(2)}px;border-radius:${k.radius.toFixed(2)}px">
    <img src="${imgURL}" style="width:${k.img.w.toFixed(3)}px;left:${k.img.left.toFixed(3)}px;top:${k.img.top.toFixed(3)}px" alt="">
  </div>`;
  }

  return `<!doctype html>
<html lang="${t.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=${g.W}">
<title>${esc(frame.id)}</title>
<style>${typeCSS(t, set.hs, set.weight)}
  html, body { width: ${g.W}px; height: ${g.H}px; overflow: hidden; background: ${COLOR.navyBottom}; }
  .canvas {
    position: relative; width: ${g.W}px; height: ${g.H}px; overflow: hidden; isolation: isolate;
    background:
      ${tintLayer}
      radial-gradient(circle ${Math.round(g.W * 0.9)}px at 0% 100%, rgba(${COLOR.glow}, 0.10), rgba(${COLOR.glow}, 0) 100%),
      linear-gradient(180deg, ${COLOR.navyTop} 0%, ${COLOR.navyBottom} 100%);
  }
  /* Film grain: mid-grey noise in overlay mode, so it adds no tone of its own. It sits under
     the copy, the panel and the callout, so only the canvas carries it. */
  .grain { position: absolute; inset: 0; background: url("${set.grainURL}") repeat; mix-blend-mode: overlay; pointer-events: none; }
  .panel, .callout { position: absolute; overflow: hidden; background: #000; }
  .panel {
    left: ${g.margin}px; top: ${set.panelTop}px; width: ${g.panelWidth}px; height: ${panelH}px;
    border-radius: ${Math.round(g.panelWidth * g.radiusRatio)}px;
    box-shadow: 0 50px 140px rgba(3, 7, 14, 0.55), 0 12px 40px rgba(3, 7, 14, 0.35);
  }
  .panel img { position: absolute; left: 0; top: ${(-crop.top * g.s).toFixed(3)}px; width: ${g.panelWidth}px; }
  .callout { box-shadow: 0 36px 90px rgba(0, 0, 0, 0.60), 0 10px 28px rgba(0, 0, 0, 0.40); }
  .callout img { position: absolute; }
  .panel::after, .callout::after {
    content: ""; position: absolute; inset: 0; border-radius: inherit; pointer-events: none;
    box-shadow: inset 0 0 0 1.5px rgba(255, 255, 255, 0.13);
  }
</style>
</head>
<body>
<div class="canvas">
  <div class="grain"></div>
  ${L.copyHTML}
  <div class="panel"><img src="${imgURL}" alt=""></div>${callout}
</div>
</body>
</html>
`;
}

// ---------------------------------------------------------------------------------------

// Deterministic Gaussian grain tile: mean 128, σ = GRAIN.sigma of full scale.
function writeGrainTile(path) {
  let a = GRAIN.seed >>> 0;
  const rand = () => {                       // mulberry32
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const n = GRAIN.tile, data = Buffer.alloc(n * n), sd = GRAIN.sigma * 255;
  for (let i = 0; i < data.length; i += 2) {
    const u = Math.max(rand(), 1e-12), v = rand();
    const r = Math.sqrt(-2 * Math.log(u));
    data[i] = Math.max(0, Math.min(255, Math.round(128 + sd * r * Math.cos(2 * Math.PI * v))));
    if (i + 1 < data.length) data[i + 1] = Math.max(0, Math.min(255, Math.round(128 + sd * r * Math.sin(2 * Math.PI * v))));
  }
  writeFileSync(path, encodeGray({ width: n, height: n, data }));
}

function finalize(pngPath) {
  const img = decodePNG(readFileSync(pngPath));
  if (img.width !== GRID.W || img.height !== GRID.H) {
    throw new Error(`${pngPath} is ${img.width}x${img.height}, expected ${GRID.W}x${GRID.H}`);
  }
  writeFileSync(pngPath, encodeRGB(toOpaqueRGB(img, hexToRgb(COLOR.navyBottom))));
  const jpg = pngPath.replace(/\.png$/, '.jpg');
  const r = spawnSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '100', pngPath, '--out', jpg], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`sips failed: ${r.stderr}`);
  return jpg;
}

function parseArgs(argv) {
  const pos = [], opt = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--only') opt.only = argv[++i].split(',');
    else if (argv[i] === '--weight') opt.weight = +argv[++i];
    else pos.push(argv[i]);
  }
  return { pos, opt };
}

async function main() {
  const { pos: [specPath, outArg], opt } = parseArgs(process.argv.slice(2));
  if (!specPath || !outArg) {
    console.error('usage: node compose.mjs spec.json out-dir [--only id,id] [--weight 400|500|600]');
    process.exit(2);
  }
  const g = GRID;
  for (const f of Object.values(FONT_FILES)) {
    if (!existsSync(f)) { console.error(`missing font ${f}: run fetch-fonts.sh first`); process.exit(2); }
  }
  const spec = JSON.parse(readFileSync(specPath, 'utf8'));
  // A relative capture path is relative to the spec file, so a spec checked in next to
  // its captures renders from any working directory.
  for (const f of spec.frames ?? []) if (f.screenshot) f.screenshot = resolve(dirname(resolve(specPath)), f.screenshot);
  const lang = /^zh/.test(spec.lang ?? '') ? 'zh-Hant' : 'en';
  const t = TYPE[lang];
  const weight = opt.weight ?? spec.headlineWeight ?? t.headline.weight;
  const prefix = spec.prefix ?? lang;
  const outDir = resolve(outArg);
  const workDir = join(HERE, '.work', prefix);
  const profileDir = join(HERE, 'chrome-profile');
  for (const d of [outDir, workDir]) mkdirSync(d, { recursive: true });
  const chrome = { profileDir, w: g.W, h: g.H };
  const grainPath = join(workDir, 'grain.png');
  writeGrainTile(grainPath);

  // --- Stage 0: static checks, headline candidates.
  const items = spec.frames.map((raw) => {
    const frame = { ...raw };
    if (t.lang === 'en') for (const k of ['headline', 'highlight', 'subline', 'tag', 'footnote']) frame[k] = smartQuotes(frame[k]);
    const it = { frame, name: `${prefix}-${frame.id}`, errors: [], warnings: [] };
    if (!frame.id || !frame.headline || !frame.screenshot) it.errors.push('each frame needs id, headline and screenshot');
    if (frame.screenshot) {
      if (!existsSync(frame.screenshot)) it.errors.push(`capture not found: ${frame.screenshot}`);
      else {
        try {
          const { width, height } = pngSize(frame.screenshot);
          if (width !== g.capW || height !== g.capH) it.errors.push(`capture is ${width}x${height}, must be exactly ${g.capW}x${g.capH}`);
        } catch (e) { it.errors.push(`capture is not a PNG: ${frame.screenshot}`); }
      }
    }
    if (frame.highlight && !String(frame.headline).replace(/\n|\|/g, '').includes(frame.highlight)) it.warnings.push(`highlight "${frame.highlight}" is not in the headline`);
    if (frame.tint) { try { hexToRgb(frame.tint); } catch (e) { it.errors.push(e.message); } }
    const hc = headlineCandidates(String(frame.headline ?? ''), t, frame.keepBreakPunct);
    it.cands = hc.cands;
    it.crop = { top: frame.panelCrop?.top ?? 0, bottom: frame.panelCrop?.bottom ?? 0 };
    return it;
  });
  const only = opt.only ? new Set(opt.only) : null;
  if (only) for (const id of only) if (!items.some((it) => it.frame.id === id)) console.warn(`! --only: no frame "${id}"`);

  // --- Stage 1: measure (all frames, so the set-wide size does not depend on --only).
  writeFileSync(join(workDir, 'measure.html'), measureHTML(items, t, weight));
  const M = readResult(await dumpDom(join(workDir, 'measure.html'), chrome));
  if (M.error) throw new Error(`measuring page failed: ${M.error}`);
  const hs = M.hs;

  items.forEach((it, i) => {
    const m = M.frames[i];
    it.lines = it.cands[m.cand];
    it.subLines = m.sub?.lines ?? [];
    it.footLines = m.foot?.lines ?? [];
    it.footBeside = !!m.foot?.beside;
    it.measure = m;
    const zh = t.lang !== 'en';
    const orphan = (lines, what) => {
      if (!zh) return;
      lines.forEach((l, k) => { if (lines.length > 1 && letters(l, t) <= 1) it.errors.push(`${what} line ${k + 1} 「${l}」 orphans a single character`); });
    };
    if (m.unfit) m.headWidthsMin.forEach((w, k) => { if (w > g.panelWidth + 0.5) it.errors.push(`headline line ${k + 1} "${it.lines[k]}" overflows by ${Math.ceil(w - g.panelWidth)} px even at the minimum ${t.headline.min}px (the set stays at ${hs}px)`); });
    else m.headWidths.forEach((w, k) => { if (w > g.panelWidth + 0.5) it.errors.push(`headline line ${k + 1} "${it.lines[k]}" overflows by ${Math.ceil(w - g.panelWidth)} px at ${hs}px`); });
    orphan(it.lines, 'headline');
    if (it.lines.length === 1 && it.cands.length === 1 && [...it.lines[0]].length > 3) it.warnings.push('headline has no break point and stays on one line');
    if (m.sub) {
      if (m.sub.lines.length > 2) it.errors.push(`subline overflows: it needs ${m.sub.lines.length} lines (max 2)`);
      m.sub.widths.forEach((w, k) => { if (w > g.panelWidth + 0.5) it.errors.push(`subline line ${k + 1} overflows by ${Math.ceil(w - g.panelWidth)} px`); });
      orphan(it.subLines, 'subline');
    }
    if (m.tag && m.tag.w > g.panelWidth + 0.5) it.errors.push(`tag "${it.frame.tag}" does not fit on one line (${Math.round(m.tag.w)} px of ${g.panelWidth})`);
    if (m.foot) {
      orphan(it.footLines, 'footnote');
      m.foot.widths.forEach((w, k) => { if (w > g.panelWidth + 0.5) it.errors.push(`footnote line ${k + 1} overflows by ${Math.ceil(w - g.panelWidth)} px`); });
      if (it.footLines.length > 2) it.warnings.push(`footnote runs to ${it.footLines.length} lines`);
    }
    it.copyHTML = copyHTML(it.frame, { t, lines: it.lines, subLines: it.subLines, footLines: it.footLines, footBeside: it.footBeside });
  });

  // --- Stage 2: verify the final copy blocks.
  writeFileSync(join(workDir, 'verify.html'), verifyHTML(items.map((it) => it.copyHTML), t, hs, weight));
  const V = readResult(await dumpDom(join(workDir, 'verify.html'), chrome));
  if (V.error) throw new Error(`verify page failed: ${V.error}`);
  items.forEach((it, i) => {
    const v = V.frames[i];
    it.verify = v;
    it.copyBottom = v.copy.b;
    v.head.forEach((r, k) => { if (r.w > g.panelWidth + 0.5 && !it.errors.some((e) => e.startsWith('headline line'))) it.errors.push(`headline line ${k + 1} overflows by ${Math.ceil(r.w - g.panelWidth)} px`); });
    v.sub.forEach((r, k) => { if (r.r > g.margin + g.panelWidth + 0.5 && !it.errors.some((e) => e.startsWith('subline'))) it.errors.push(`subline line ${k + 1} overflows the measure`); });
    if (v.tag) {
      if (v.tag.h > META.tag.height + 0.5 || v.tag.sw > v.tag.cw + 1 || v.tag.r > g.margin + g.panelWidth + 0.5) {
        if (!it.errors.some((e) => e.startsWith('tag'))) it.errors.push('tag wraps or overflows its row');
      }
    }
  });

  // Set-wide panel top: below the tallest copy block among the frames whose copy is sound.
  const copyOK = (it) => !it.errors.some((e) => /^(headline|subline|tag|footnote)/.test(e));
  const sound = items.filter(copyOK);
  const tallest = sound.length ? sound.reduce((a, b) => (b.copyBottom > a.copyBottom ? b : a)) : null;
  let panelTop;
  if (Number.isFinite(spec.panelTop)) panelTop = Math.round(spec.panelTop);
  else panelTop = Math.min(g.panelTopMax, Math.max(g.panelTopMin, Math.ceil((tallest?.copyBottom ?? 0) + g.panelGap)));

  // --- Per-frame geometry checks.
  for (const it of items) {
    const gap = panelTop - it.copyBottom;
    it.gap = gap;
    if (gap < g.minGap) {
      const where = gap >= 0 ? `${Math.floor(gap)} px above the panel` : `${Math.ceil(-gap)} px below the panel top`;
      it.errors.push(`copy ends ${where} (min gap ${g.minGap}); cut ${Math.ceil(g.minGap - gap)} px of copy`);
    }
    const visCapH = g.capH - it.crop.top - it.crop.bottom;
    const shown = Math.min(visCapH, (g.H - panelTop) / g.s);
    it.visible = shown / g.capH;
    if (it.visible < g.minVisible - 1e-9) it.errors.push(`only ${(100 * it.visible).toFixed(1)}% of the capture's height is visible (min ${100 * g.minVisible}%)`);
    const c = it.frame.callout;
    if (c && c.w > 0 && c.h > 0) {
      const k = calloutGeometry(c, it.crop, panelTop);
      it.errors.push(...k.errors);
      if (!k.errors.length) it.callout = k;
    }
  }
  const tints = items.filter((it) => it.frame.tint).length;
  const callouts = items.filter((it) => it.frame.callout).length;

  // --- Report the set.
  const W = M.widest;
  console.log(`${prefix}: headline ${hs}px weight ${weight} (range ${t.headline.min}-${t.headline.max}; widest line "${W.text}" in ${items[W.f]?.frame.id} is ${Math.round(W.w)} of ${g.panelWidth} px${M.fitSize < t.headline.max ? `, it alone allows ${M.fitSize}px` : ''})`);
  console.log(`${prefix}: panel top ${panelTop}${Number.isFinite(spec.panelTop) ? ' (spec override)' : ` (tallest copy ends y=${Math.round(tallest?.copyBottom ?? 0)} in ${tallest?.frame.id ?? '-'})`}, ${(100 * Math.min(1, (g.H - panelTop) / g.s / g.capH)).toFixed(1)}% of an uncropped capture visible`);
  items.forEach((it, i) => { if (M.frames[i].unfit) console.log(`${prefix}: ! ${it.frame.id}'s headline is too wide even at ${t.headline.min}px, so it fails and does not set the size — shorten it or break it with "\\n"`); });
  if (tints > 2) console.warn(`${prefix}: ! ${tints} frames carry a tint; keep it to the rain hero (and maybe the typhoon frame)`);
  if (callouts > Math.ceil(items.length / 3)) console.warn(`${prefix}: ! ${callouts} callouts in ${items.length} frames reads as busy`);

  // A full run records the set's geometry next to its frames. A --only run whose geometry
  // differs (the edited copy moved the set's size or panel top) says that the frames it
  // leaves alone are now stale, instead of quietly producing a set of two layouts.
  const stampPath = join(outDir, `${prefix}-set.json`);
  const stamp = { hs, weight, panelTop };
  if (only) {
    let prev = null;
    try { prev = JSON.parse(readFileSync(stampPath, 'utf8')); } catch {}
    if (prev && (prev.hs !== hs || prev.weight !== weight || prev.panelTop !== panelTop)) {
      console.warn(`${prefix}: ! the frames on disk were rendered at ${prev.hs}px / weight ${prev.weight} / panel top ${prev.panelTop}, this run is ${hs}px / ${weight} / ${panelTop}: the frames --only leaves out are now stale, so render the whole set`);
    }
  } else writeFileSync(stampPath, JSON.stringify(stamp) + '\n');

  // --- Stage 3: render.
  const set = { hs, weight, panelTop, grainURL: pathToFileURL(grainPath).href };
  let failed = 0;
  for (const it of items) {
    if (only && !only.has(it.frame.id)) continue;
    const pngPath = join(outDir, `${it.name}.png`), jpgPath = join(outDir, `${it.name}.jpg`);
    const facts = [
      `head ${it.lines.map((l) => `「${l}」`).join('')}`,
      it.subLines.length ? `sub ${it.subLines.length}L` : null,
      it.frame.tag ? `tag ${Math.round(it.measure.tag.w)}px` : null,
      it.footLines.length ? `foot ${it.footBeside ? 'beside tag' : `own row ${it.footLines.length}L`}` : null,
      `copy ends ${Math.round(it.copyBottom)}, gap ${Math.floor(it.gap)}`,
      `visible ${(100 * it.visible).toFixed(1)}%`,
      it.callout ? `callout ${it.callout.k.toFixed(3)}x (${it.callout.limitedBy}) ${Math.round(it.callout.cw)}x${Math.round(it.callout.ch)} overhang ${Math.round(it.callout.overhang)} rows ${Math.round(it.callout.capTop)}-${Math.round(it.callout.capBottom)} in ${it.callout.band.top}-${it.callout.band.bottom}` : null,
      it.frame.tint ? `tint ${it.frame.tint}` : null,
    ].filter(Boolean).join(' · ');
    for (const w of it.warnings) console.warn(`  ! ${it.name}: ${w}`);
    if (it.errors.length) {
      failed++;
      rmSync(pngPath, { force: true }); rmSync(jpgPath, { force: true });
      console.log(`✗ ${it.name}  ${facts}`);
      for (const e of it.errors) console.log(`    FAIL ${e}`);
      continue;
    }
    const htmlPath = join(workDir, `${it.name}.html`);
    writeFileSync(htmlPath, frameHTML(it.frame, { t, crop: it.crop, copyHTML: it.copyHTML, callout: it.callout }, set));
    const t0 = Date.now();
    try {
      await screenshot(htmlPath, pngPath, chrome);
      finalize(pngPath);
    } catch (e) {
      failed++;
      rmSync(pngPath, { force: true }); rmSync(jpgPath, { force: true });
      console.log(`✗ ${it.name}  render failed: ${e.message}`);
      continue;
    }
    console.log(`✓ ${it.name}  ${((Date.now() - t0) / 1000).toFixed(1)}s · ${facts}`);
  }
  if (failed) {
    console.log(`${failed} frame(s) failed; no file was written for them.`);
    process.exit(1);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
}
