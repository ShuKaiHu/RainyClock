// Rain on a fogged window at blue hour — paints the key art into <canvas id="art">.
// Driven by generate.mjs (same folder), which passes the config as window.SCENE.
//
// Depth, back to front:
//   1. the world: a dawn sky with rain cloud, a city and a street receding to a vanishing point
//   2. rain falling outside, between the street and the glass (blurred with the city)
//   3. the outer face of the pane: rain drops, merged and oblong drops, a few running trails
//   4. the inner face: condensation fog, with a hand-wiped clear patch where the type sits,
//      beads pushed to the edge of the wipe, and drips running down out of it; the outer
//      drops stay sharp only through the wipe, and are diffused behind the fog
// Drops are lenses: each shows the world behind it upside down and smaller, with a thin bright
// rim along its lower edge and a tiny highlight; no dark outlines. Nothing here is an image
// file. Sizes are px for a 3840 px wide canvas. Every random choice comes from one seeded
// generator, so a given config paints the same pixels on every run.
(function () {
  'use strict';
  const C = window.SCENE;
  const W = C.W, H = C.H, P = 160, TAU = Math.PI * 2;
  const hz = C.hz, vpX = C.vpX, sunX = C.sunX;

  // ---- deterministic randomness and helpers ----
  const mulberry = (a) => () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const R = mulberry(C.seed);
  const rnd = (a = 0, b = 1) => a + (b - a) * R();
  const chance = (p) => R() < p;
  const pick = (arr) => arr[Math.floor(R() * arr.length)];
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (t) => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
  const canvas = (w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; };
  const rgba = (rgb, a) => `rgba(${rgb},${clamp(a, 0, 1).toFixed(4)})`;
  function field(cols, rows, seed) {
    const r = mulberry(C.seed + seed), g = [];
    for (let i = 0; i < (cols + 1) * (rows + 1); i++) g.push(r());
    return (x, y) => {
      const fx = clamp(x / W, 0, 0.9999) * cols, fy = clamp(y / H, 0, 0.9999) * rows;
      const ix = Math.floor(fx), iy = Math.floor(fy), sx = smooth(fx - ix), sy = smooth(fy - iy);
      const at = (i, j) => g[j * (cols + 1) + i];
      return lerp(lerp(at(ix, iy), at(ix + 1, iy), sx), lerp(at(ix, iy + 1), at(ix + 1, iy + 1), sx), sy);
    };
  }
  // soft elliptical glow, eased fall-off, no rim
  function glow(ctx, x, y, rx, ry, rgb, a, rot = 0) {
    if (rx <= 0 || ry <= 0 || a <= 0) return;
    ctx.save(); ctx.translate(x, y); ctx.rotate(rot); ctx.scale(1, ry / rx);
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, rx);
    [[0, 1], [0.2, 0.82], [0.45, 0.48], [0.7, 0.18], [0.88, 0.05], [1, 0]].forEach(([s, m]) => g.addColorStop(s, rgba(rgb, a * m)));
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(0, 0, rx, 0, TAU); ctx.fill(); ctx.restore();
  }
  function blurred(src, px, sx = 0, sy = 0, w = W, h = H) {
    const c = canvas(w, h), g = c.getContext('2d');
    g.filter = `blur(${px}px)`; g.drawImage(src, -sx, -sy); g.filter = 'none';
    return c;
  }
  const COL = {
    amber: '255,170,60', gold: '255,204,120', warm: '255,228,190', cyan: '110,227,253', ice: '200,236,255',
    red: '255,78,96', pink: '255,122,190', lav: '204,191,255', teal: '96,236,214', led: '170,240,255',
  };
  const inRect = (x, y, z, m = 0) => x > z.x - m && x < z.x + z.w + m && y > z.y - m && y < z.y + z.h + m;

  // =====================================================================================
  // 1. The world, painted sharp into a padded canvas.
  // =====================================================================================
  const raw = canvas(W + 2 * P, H + 2 * P), rc = raw.getContext('2d');
  rc.translate(P, P);
  const lights = [];

  // ---- sky: dawn under rain cloud ----
  {
    const g = rc.createLinearGradient(0, -P, 0, hz);
    C.sky.forEach(([s, c]) => g.addColorStop(s, c));
    rc.fillStyle = g; rc.fillRect(-P, -P, W + 2 * P, hz + P + 2);
    // the lighter, higher sky: a few breaks of pale blue
    for (let i = 0; i < 7; i++) glow(rc, rnd(-200, W + 200), rnd(-0.1, 0.32) * hz, rnd(700, 1400), rnd(160, 320), '150,178,236', rnd(0.12, 0.24));
    // dawn at the horizon: rose spread, peach core, a hot line; a cool cyan band above the warm
    const dawn = C.dawn || 1;
    glow(rc, sunX, hz, 2900 * Math.sqrt(dawn), 470 * dawn, '246,160,170', 0.42 * dawn);
    glow(rc, sunX, hz, 1700 * Math.sqrt(dawn), 260 * dawn, '255,184,140', 0.72 * Math.min(dawn, 1.3));
    glow(rc, sunX, hz, 760, 92, '255,226,180', 0.95);
    glow(rc, sunX, hz - 4, 2300, 26, '255,240,215', 0.55);
    glow(rc, sunX, hz - C.cyanLine, 2400, 46, '150,236,255', 0.30);
    // rain cloud: a band of soft indigo masses across the middle of the sky
    const cb = C.clouds;
    for (let i = 0; i < cb.n; i++) {
      const x = rnd(-400, W + 400), y = lerp(cb.y0, cb.y1, Math.pow(R(), 0.9));
      const rx = rnd(700, 1700), near = 1 - clamp(Math.abs(x - sunX) / 2600, 0, 1);
      glow(rc, x, y, rx, rx * rnd(0.12, 0.26), cb.rgb, rnd(cb.a[0], cb.a[1]) * (0.75 + 0.25 * near), rnd(-0.05, 0.05));
    }
    // undersides catching the dawn, near the horizon only
    for (let i = 0; i < 26; i++) {
      const x = sunX + rnd(-2100, 2100), y = hz - rnd(70, 0.34 * hz);
      const near = 1 - clamp(Math.abs(x - sunX) / 2200, 0, 1), rx = rnd(260, 900);
      glow(rc, x, y, rx, rx * rnd(0.04, 0.09), i % 3 ? '255,190,180' : COL.lav, rnd(0.08, 0.22) * (0.3 + 0.7 * near), rnd(-0.03, 0.03));
    }
  }

  // ---- city ----
  function windowColour() {
    const t = R();
    if (t < 0.6) return `255,${Math.round(rnd(190, 224))},${Math.round(rnd(120, 168))}`;
    if (t < 0.9) return `${Math.round(rnd(184, 214))},${Math.round(rnd(220, 240))},255`;
    return COL.cyan;
  }
  function skyline(L) {
    let x = -P - rnd(0, 200);
    while (x < W + P) {
      const w = rnd(L.wMin, L.wMax);
      let h = L.hMin + (L.hMax - L.hMin) * Math.pow(R(), L.curve || 1.6);
      if (chance(L.towerP || 0.07)) h *= rnd(1.3, 1.7);
      if (L.open) { const d = Math.abs(x + w / 2 - vpX) / L.open; if (d < 1) h *= lerp(0.15, 1, d * d); }
      const lz = C.lowZone; if (lz && x + w > lz.x0 && x < lz.x1) h = Math.min(h, Math.max(20, L.base - lz.yMin));
      const top = L.base - h;
      rc.fillStyle = L.fill;
      rc.fillRect(x, top, w, L.base - top + 4);
      if (chance(0.35)) rc.fillRect(x + w * 0.2, top - h * 0.07, w * 0.6, h * 0.07 + 2);
      if (chance(0.12)) rc.fillRect(x + w * 0.48, top - h * 0.2, Math.max(3, w * 0.04), h * 0.2);
      const cw = L.win.cw, ch = L.win.ch;
      for (let yy = top + ch * 0.8; yy < L.base - ch * 0.5; yy += ch) {
        const fb = rnd(0.2, 1.8);
        for (let xx = x + cw * 0.5; xx < x + w - cw * 0.6; xx += cw) {
          if (!chance(L.win.p * fb)) continue;
          const col = windowColour();
          rc.fillStyle = rgba(col, rnd(L.win.a[0], L.win.a[1]));
          rc.fillRect(xx, yy, cw * 0.56, ch * 0.5);
          if (L.bokehP && chance(L.bokehP) && yy < H + 40) lights.push({ x: xx + cw * 0.28, y: yy + ch * 0.25, rgb: col, r: rnd(L.bokehR[0], L.bokehR[1]), a: rnd(0.22, 0.42), p: 4 });
        }
      }
      if (L.neonP && chance(L.neonP) && !(C.calm || []).some((z) => inRect(x + w / 2, top + h * 0.4, z, 260))) {
        const col = pick(L.neon || [COL.cyan, COL.pink, COL.cyan, COL.teal]);
        const sw = rnd(0.1, 0.24) * w, sh = rnd(0.6, 1.6) * sw;
        const sx = x + rnd(0.1, 0.8) * w, sy = top + rnd(0.12, 0.5) * (L.base - top);
        rc.fillStyle = rgba(col, 0.95); rc.fillRect(sx, sy, sw, sh);
        glow(rc, sx + sw / 2, sy + sh / 2, sw * 2.2, sh * 1.6, col, 0.35);
        if (sy + sh / 2 < H + 40) lights.push({ x: sx + sw / 2, y: sy + sh / 2, rgb: col, r: rnd(L.bokehR[0], L.bokehR[1]) * 1.25, a: rnd(0.4, 0.55), p: 6 });
      }
      x += w + rnd(-0.12, 0.3) * w;
    }
  }
  skyline(C.city[0]);
  rc.globalCompositeOperation = 'screen';
  glow(rc, sunX, hz - 20, 1700, 300, '255,170,150', 0.30);
  glow(rc, sunX, hz, 2800, 480, '160,150,235', 0.16);
  rc.globalCompositeOperation = 'source-over';
  C.city.slice(1).forEach(skyline);
  (C.signs || []).forEach((s) => {
    rc.fillStyle = rgba(COL[s.c], 0.95); rc.fillRect(s.x - s.w / 2, s.y - s.h / 2, s.w, s.h);
    glow(rc, s.x, s.y, s.w * 2.6, s.h * 2, COL[s.c], 0.45);
    lights.push({ x: s.x, y: s.y, rgb: COL[s.c], r: s.r, a: s.a, p: 7 });
  });

  // ---- street, wet, receding to the vanishing point ----
  {
    const g = rc.createLinearGradient(0, hz, 0, H + P);
    g.addColorStop(0, C.ground[0]); g.addColorStop(1, C.ground[1]);
    rc.save(); rc.filter = 'blur(30px)'; rc.fillStyle = g; rc.beginPath();
    rc.moveTo(vpX - 700, hz + 4); rc.lineTo(vpX + 700, hz + 4);
    rc.lineTo(W + 3 * P, H + P); rc.lineTo(-3 * P, H + P); rc.closePath(); rc.fill(); rc.restore();
    // the road catching the dawn
    glow(rc, vpX, lerp(hz, H, 0.45), 420, (H - hz) * 0.75, '255,176,150', 0.2);
    glow(rc, vpX, hz + 20, 900, 70, '255,200,170', 0.35);
  }
  function perspective(n, X, Y, zMin, zMax, make) {
    for (let i = 0; i < n; i++) {
      const u = (i + rnd(0.15, 0.85)) / n;
      const z = 1 / lerp(1 / zMax, 1 / zMin, Math.pow(u, 1.15));
      make(vpX + X / z + rnd(-10, 10) / z, hz + Y / z, z);
    }
  }
  const S = C.street;
  const lampCol = () => (chance(S.cyanP) ? COL.led : chance(0.7) ? COL.amber : COL.gold);
  [-1, 1].forEach((side) => perspective(S.lamps, side * S.lampX, S.lampY, S.zMin, S.zMax, (x, y, z) => {
    if (chance(0.15)) return;
    const lat = rnd(-0.12, 0.2) * S.lampX / z, up = rnd(-0.25, 0.1) * S.lampY / z;
    lights.push({ x: x + side * lat, y: y + up, rgb: lampCol(), r: S.lampR / Math.pow(z, 0.88) * rnd(0.85, 1.15), a: rnd(0.36, 0.6), p: 8 / Math.sqrt(z), z, refl: true });
  }));
  perspective(S.cars, S.laneX, S.laneY, S.zMin * 1.3, S.zMax, (x, y, z) => {
    const sp = 64 / z;
    [-1, 1].forEach((s) => lights.push({ x: x + s * sp / 2, y, rgb: COL.red, r: S.carR / Math.pow(z, 0.88), a: 0.44, p: 6 / Math.sqrt(z), z, refl: true }));
  });
  perspective(S.cars, -S.laneX, S.laneY, S.zMin * 1.3, S.zMax, (x, y, z) => {
    const sp = 64 / z, col = chance(0.5) ? COL.warm : COL.ice;
    [-1, 1].forEach((s) => lights.push({ x: x + s * sp / 2, y, rgb: col, r: S.carR / Math.pow(z, 0.88), a: 0.42, p: 7 / Math.sqrt(z), z, refl: true }));
  });
  (C.extraLights || []).forEach((l) => lights.push({ x: l.x, y: l.y, rgb: COL[l.c] || l.c, r: l.r, a: l.a, p: 6 }));
  // wet asphalt: every street light leaves a long reflection below it
  lights.forEach((l) => {
    if (!l.refl) return;
    glow(rc, l.x, l.y + l.p * 4, l.p * 3, l.p * 16, l.rgb, 0.45);
    glow(rc, l.x, l.y, l.p * 2.2, l.p * 2.2, l.rgb, 0.9);
  });
  // far lights at the horizon: specks, never discs
  for (let i = 0; i < 70; i++) {
    const x = vpX + rnd(-1, 1) * rnd(0, 1) * 1500, y = hz + rnd(-14, 26);
    glow(rc, x, y, rnd(4, 9), rnd(4, 9), pick([COL.amber, COL.warm, COL.red, COL.ice, COL.gold]), rnd(0.5, 0.9));
  }

  // =====================================================================================
  // 2. Out of focus: the world blurred, its lights as bokeh, rain falling in front of it.
  // =====================================================================================
  const bg = blurred(raw, C.bgBlur, P, P), bc = bg.getContext('2d');
  // bokeh: sized by depth, soft edged, a faint ring at the rim, the calm zone left alone
  function disc(ctx, l) {
    const { x, y, r, rgb } = l;
    let a = l.a;
    (C.calm || []).forEach((z) => { if (inRect(x, y, z, r * 0.6)) a *= 0.3; });
    glow(ctx, x, y, r * 1.9, r * 1.9, rgb, a * 0.16);
    const g = ctx.createRadialGradient(x - r * 0.1, y - r * 0.12, 0, x, y, r);
    g.addColorStop(0, rgba(rgb, a * 0.5)); g.addColorStop(0.62, rgba(rgb, a * 0.6));
    g.addColorStop(0.86, rgba(rgb, a * 0.74)); g.addColorStop(0.94, rgba(rgb, a * 0.9));
    g.addColorStop(0.975, rgba(rgb, a * 0.45)); g.addColorStop(1, rgba(rgb, 0));
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill();
  }
  bc.globalCompositeOperation = 'screen';
  lights.slice().sort((p, q) => p.r - q.r).forEach((l) => {
    if (l.r >= C.minDisc) disc(bc, l); else glow(bc, l.x, l.y, l.r * 1.6, l.r * 1.6, l.rgb, l.a * 0.8);
  });
  bc.globalCompositeOperation = 'source-over';

  // rain falling outside: several depths, slanted, never evenly spaced, lit by what is behind it
  {
    const sw = Math.ceil(W / 16), sh = Math.ceil(H / 16), small = canvas(sw, sh), sg = small.getContext('2d');
    sg.drawImage(bg, 0, 0, sw, sh);
    const lum = sg.getImageData(0, 0, sw, sh).data;
    const L = (x, y) => {
      const i = (clamp(Math.floor(y / 16), 0, sh - 1) * sw + clamp(Math.floor(x / 16), 0, sw - 1)) * 4;
      return (0.3 * lum[i] + 0.59 * lum[i + 1] + 0.11 * lum[i + 2]) / 255;
    };
    const gust = field(7, 4, 404), area = (W * H) / (3840 * 1646);
    C.rain.layers.forEach((ly) => {
      const c = canvas(W, H), g = c.getContext('2d');
      g.lineCap = 'round';
      const n = Math.round(ly.n * area);
      for (let i = 0, made = 0; made < n && i < n * 4; i++) {
        const x = rnd(-200, W + 200), y = rnd(-300, H);
        if (!chance(lerp(0.25, 1, gust(x, y)))) continue;
        made++;
        const len = ly.len[0] * Math.pow(ly.len[1] / ly.len[0], R());
        const ang = C.rain.angle + rnd(-0.03, 0.03);
        let a = rnd(ly.a[0], ly.a[1]) * (0.35 + 1.9 * Math.pow(L(x, y), 1.6));
        (C.calm || []).forEach((z) => { if (inRect(x, y, z, 60)) a *= C.rain.calmMul; });
        const col = chance(0.3) ? '150,236,255' : '222,240,255';
        const x2 = x - Math.sin(ang) * len, y2 = y + Math.cos(ang) * len;
        const gr = g.createLinearGradient(x, y, x2, y2);
        gr.addColorStop(0, rgba(col, 0)); gr.addColorStop(0.35, rgba(col, a)); gr.addColorStop(1, rgba(col, a * 0.6));
        g.strokeStyle = gr; g.lineWidth = rnd(ly.w[0], ly.w[1]);
        g.beginPath(); g.moveTo(x, y); g.lineTo(x2, y2); g.stroke();
      }
      bc.save(); bc.globalCompositeOperation = 'screen'; bc.filter = `blur(${ly.blur}px)`; bc.drawImage(c, 0, 0); bc.restore();
    });
  }

  // =====================================================================================
  // 3. What a drop sees: the world sharper, lights as bright specks.
  // =====================================================================================
  const sharp = canvas(W + 2 * P, H + 2 * P), sc = sharp.getContext('2d');
  sc.filter = 'blur(5px)'; sc.drawImage(raw, 0, 0); sc.filter = 'none';
  sc.globalAlpha = 0.45; sc.drawImage(bg, P, P); sc.globalAlpha = 1;
  sc.translate(P, P); sc.globalCompositeOperation = 'screen';
  lights.forEach((l) => { glow(sc, l.x, l.y, l.p * 4, l.p * 4, l.rgb, 0.6); glow(sc, l.x, l.y, l.p, l.p, '255,255,255', 0.9); });
  sc.setTransform(1, 0, 0, 1, 0, 0); sc.globalCompositeOperation = 'source-over';

  // ---- drop shapes: round, oblong, merged; star-shaped contours around a centre ----
  function contour(d) {
    const N = 56, rr = new Array(N);
    if (d.kind === 'merged') {
      // union of circles, measured along rays from the area centroid, then smoothed (surface tension)
      let ax = 0, ay = 0, at = 0;
      d.parts.forEach((c) => { const m = c.r * c.r; ax += c.x * m; ay += c.y * m; at += m; });
      const cx = ax / at, cy = ay / at;
      for (let i = 0; i < N; i++) {
        const t = (i / N) * TAU, ux = Math.cos(t), uy = Math.sin(t);
        let best = 0;
        d.parts.forEach((c) => {
          const ox = c.x - cx, oy = c.y - cy, b = ux * ox + uy * oy, q = b * b - (ox * ox + oy * oy - c.r * c.r);
          if (q >= 0) best = Math.max(best, b + Math.sqrt(q));
        });
        rr[i] = best;
      }
      for (let pass = 0; pass < 3; pass++) {
        const cp = rr.slice();
        for (let i = 0; i < N; i++) rr[i] = Math.max(cp[i], (cp[(i + N - 1) % N] + 2 * cp[i] + cp[(i + 1) % N]) / 4);
      }
      d.cx = d.x + cx; d.cy = d.y + cy;
    } else {
      for (let i = 0; i < N; i++) {
        const t = (i / N) * TAU;
        rr[i] = d.r * (1 + d.w1 * Math.sin(2 * t + d.p1) + d.w2 * Math.sin(3 * t + d.p2));
      }
      d.cx = d.x; d.cy = d.y;
    }
    const pts = [];
    for (let i = 0; i < N; i++) {
      const t = (i / N) * TAU, s = Math.sin(t), c = Math.cos(t);
      // gravity: a fuller, rounder bottom and a narrower top
      const gy = s > 0 ? 1 + d.sag * s : 1 - 0.1 * d.sag * -s;
      const gx = s < 0 ? 1 - 0.14 * d.sag * -s : 1 + 0.06 * d.sag * s;
      pts.push([d.cx + c * rr[i] * d.sx * gx, d.cy + s * rr[i] * d.sy * gy]);
    }
    const p = new Path2D(), mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
    const m0 = mid(pts[N - 1], pts[0]); p.moveTo(m0[0], m0[1]);
    for (let i = 0; i < N; i++) { const a = pts[i], m = mid(a, pts[(i + 1) % N]); p.quadraticCurveTo(a[0], a[1], m[0], m[1]); }
    p.closePath();
    let top = Infinity, bot = -Infinity, left = Infinity, right = -Infinity;
    pts.forEach(([x, y]) => { top = Math.min(top, y); bot = Math.max(bot, y); left = Math.min(left, x); right = Math.max(right, x); });
    d.box = { top, bot, left, right };
    d.R = Math.max(right - left, bot - top) / 2;
    d.path = p;
    return d;
  }
  function makeDrop(x, y, r, kind) {
    const d = { x, y, r, kind, sx: rnd(0.94, 1.04), sy: rnd(0.97, 1.08), sag: rnd(0.06, 0.2),
      w1: rnd(0, r > 10 ? 0.06 : 0.03), p1: rnd(0, TAU), w2: rnd(0, r > 10 ? 0.04 : 0.02), p2: rnd(0, TAU) };
    if (kind === 'oblong') { d.sy = rnd(1.25, 1.7); d.sx = rnd(0.84, 0.95); d.sag = rnd(0.16, 0.28); }
    if (kind === 'merged') {
      d.parts = [{ x: 0, y: 0, r }];
      const n = chance(0.35) ? 2 : 1;
      for (let i = 0; i < n; i++) {
        const rr = r * rnd(0.45, 0.82), ang = rnd(-Math.PI, Math.PI), dist = (r + rr) * rnd(0.5, 0.78);
        d.parts.push({ x: Math.cos(ang) * dist, y: Math.sin(ang) * dist * 0.9, r: rr });
      }
    }
    return contour(d);
  }

  // A drop is a lens: the world behind, inverted and minified; bright lower rim; tiny highlight.
  function lens(ctx, d, alpha = 1, lift = 0) {
    const { cx, cy, R: r, path } = d;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.clip(path);
    const fx = cx, fy = lerp(cy, hz, 0.45), Rv = 110 + 5.2 * r, ext = r * 1.25;
    ctx.translate(cx, cy); ctx.scale(-1, -1);
    ctx.drawImage(sharp, fx - Rv + P, fy - Rv * 0.8 + P, 2 * Rv, 1.6 * Rv, -ext, -ext, 2 * ext, 2 * ext);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    // water gathers a little light
    ctx.globalCompositeOperation = 'screen';
    ctx.fillStyle = `rgba(190,204,255,${(0.07 + lift).toFixed(3)})`; ctx.fill(path);
    ctx.globalCompositeOperation = 'source-over';
    // the faintest edge, only along the upper half
    let g = ctx.createRadialGradient(cx, cy + r * 0.35, r * 0.75, cx, cy + r * 0.2, r * 1.3);
    g.addColorStop(0, 'rgba(12,14,44,0)'); g.addColorStop(1, `rgba(12,14,44,${(r > 8 ? 0.18 : 0.07) * (1 - 2 * lift)})`);
    ctx.fillStyle = g; ctx.fill(path);
    // thin bright rim along the lower edge
    g = ctx.createLinearGradient(0, cy - r * 0.1, 0, d.box.bot);
    g.addColorStop(0, 'rgba(240,248,255,0)'); g.addColorStop(0.55, 'rgba(240,248,255,0.16)'); g.addColorStop(1, 'rgba(244,250,255,0.75)');
    ctx.strokeStyle = g; ctx.lineWidth = Math.max(1.6, r * 0.16); ctx.stroke(path);
    ctx.restore();
    // tiny highlight, top-left
    if (r > 3) {
      ctx.save(); ctx.globalAlpha = alpha;
      ctx.translate(cx - r * 0.36, cy - r * 0.44); ctx.rotate(-0.6); ctx.scale(1, 0.55);
      const hr = Math.max(1.2, r * 0.14);
      g = ctx.createRadialGradient(0, 0, 0, 0, 0, hr);
      g.addColorStop(0, 'rgba(255,255,255,0.95)'); g.addColorStop(0.5, 'rgba(255,255,255,0.6)'); g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(0, 0, hr, 0, TAU); ctx.fill();
      ctx.restore();
    }
  }

  // =====================================================================================
  // 4. Outer face of the glass: rain drops and running trails.
  // =====================================================================================
  const outer = canvas(W, H), oc = outer.getContext('2d');
  oc.drawImage(bg, 0, 0);
  const D = C.drops, dens = field(8, 4, 101), placed = [], cell = 100, grid = new Map();
  const key = (i, j) => i + ',' + j;
  function free(x, y, r, gap = 3) {
    const reach = r + 90;
    for (let i = Math.floor((x - reach) / cell); i <= Math.floor((x + reach) / cell); i++)
      for (let j = Math.floor((y - reach) / cell); j <= Math.floor((y + reach) / cell); j++) {
        const b = grid.get(key(i, j)); if (!b) continue;
        for (const d of b) if (Math.hypot(d.x - x, d.y - y) < d.r * 1.15 + r + gap) return false;
      }
    return true;
  }
  function add(d) {
    placed.push(d);
    const kk = key(Math.floor(d.x / cell), Math.floor(d.y / cell));
    if (!grid.has(kk)) grid.set(kk, []);
    grid.get(kk).push(d);
  }
  const calmAt = (x, y, r) => (C.calm || []).some((z) => inRect(x, y, z, r + 30));

  // running trails: a drop that has run down, its track, beads left behind, a tapered tail
  const trails = [];
  (D.trails || []).forEach((t) => {
    const head = makeDrop(t.x, t.y, t.r, 'oblong');
    add(head);
    const pts = []; let x = t.x, y = t.y - t.r * 0.8, drift = rnd(-0.6, 0.6);
    while (y > t.y - t.len) { pts.push([x, y]); y -= rnd(14, 26); drift = clamp(drift + rnd(-0.35, 0.35), -1.2, 1.2); x += drift * rnd(1, 4); }
    trails.push({ head, pts, w: t.r * rnd(0.5, 0.62) });
  });
  function trailPath(tr, grow = 0) {
    const p = new Path2D(), n = tr.pts.length;
    const hw = (i) => { const t = i / (n - 1); return tr.w * (t < 0.55 ? 1 - 0.3 * t : (1 - 0.3 * 0.55) * (1 - smooth((t - 0.55) / 0.45))) + grow; };
    for (let i = 0; i < n; i++) { const [x, y] = tr.pts[i]; i ? p.lineTo(x - hw(i), y) : p.moveTo(x - hw(i), y); }
    for (let i = n - 1; i >= 0; i--) { const [x, y] = tr.pts[i]; p.lineTo(x + hw(i), y); }
    p.closePath();
    return p;
  }
  trails.forEach((tr) => {
    if (tr.pts.length < 3) return;
    const p = trailPath(tr);
    oc.save(); oc.clip(p);
    oc.drawImage(bg, -3, -1);                        // a film of water shifts what is behind it
    oc.globalCompositeOperation = 'screen'; oc.fillStyle = 'rgba(200,214,255,0.08)'; oc.fill(p);
    oc.restore();
    oc.save(); oc.lineWidth = 1.6;
    oc.strokeStyle = 'rgba(236,244,255,0.28)';
    oc.beginPath(); tr.pts.forEach(([x, y], i) => { const t = i / (tr.pts.length - 1), hw = tr.w * (1 - smooth((t - 0.55) / 0.45)) * 0.9; i ? oc.lineTo(x - hw, y) : oc.moveTo(x - hw, y); }); oc.stroke();
    oc.restore();
    // beads left along the track
    let s = rnd(0.8, 2) * tr.w;
    const total = tr.pts.length;
    while (s < total * 20) {
      const i = Math.min(total - 1, Math.floor(s / 20)), t = i / (total - 1);
      if (t > 0.85) break;
      const [x, y] = tr.pts[i], r = tr.w * rnd(0.25, 0.75) * (1 - 0.6 * t);
      if (r > 1.6) add(makeDrop(x + rnd(-0.5, 0.5) * tr.w, y, r, chance(0.3) ? 'oblong' : 'round'));
      s += rnd(1.2, 4.5) * tr.w;
    }
  });

  function scatter(count, rMin, rMax, pow, kinds, inCalm) {
    const area = (W * H) / (3840 * 1646);
    const n = Math.round(count * area);
    let made = 0, tries = 0;
    while (made < n && tries < n * 50) {
      tries++;
      const x = rnd(-30, W + 30), y = rnd(-30, H + 30);
      if (!chance(lerp(0.25, 1.2, dens(x, y)))) continue;
      let r = lerp(rMin, rMax, Math.pow(R(), pow));
      if (calmAt(x, y, r)) { if (!chance(inCalm)) continue; r = Math.min(r, D.calmMaxR); }
      if (!free(x, y, r)) continue;
      add(makeDrop(x, y, r, pick(kinds)));
      made++;
    }
  }
  const calmP = D.calmP || [0, 0.12, 0.3];   // how many drops a calm zone keeps, by size
  scatter(D.large, 24, D.maxR, 1.4, ['merged', 'oblong', 'round', 'merged'], calmP[0]);
  scatter(D.medium, 9, 24, 1.5, ['round', 'round', 'oblong', 'merged'], calmP[1]);
  scatter(D.small, 2.6, 9, 1.4, ['round', 'round', 'round', 'oblong'], calmP[2]);
  placed.sort((a, b) => a.R - b.R).forEach((d) => lens(oc, d));

  // =====================================================================================
  // 5. Inner face: condensation, a hand-wiped clear patch, drips running out of it.
  // =====================================================================================
  const F = C.fog;
  // the fog itself: the scene scattered (blurred, lifted, glowing) plus a fine bead texture
  const fog = blurred(outer, F.blur), fc = fog.getContext('2d');
  fc.fillStyle = rgba(F.haze, F.hazeA); fc.fillRect(0, 0, W, H);
  {
    const g = fc.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, rgba(F.haze, F.hazeTop)); g.addColorStop(0.5, rgba(F.haze, 0)); g.addColorStop(1, rgba(F.haze, F.hazeBottom));
    fc.fillStyle = g; fc.fillRect(0, 0, W, H);
    // lights glow through the fog; squaring the source keeps the glow to the lights, not the sky
    const big = blurred(outer, 110), bg2 = big.getContext('2d');
    bg2.globalCompositeOperation = 'multiply'; bg2.drawImage(big, 0, 0); bg2.drawImage(big, 0, 0);
    fc.save(); fc.globalCompositeOperation = 'screen'; fc.globalAlpha = F.glowA; fc.drawImage(big, 0, 0); fc.restore();
  }
  // condensation texture: thousands of tiny beads (pre-rendered sprites)
  {
    const sprite = (r) => {
      const s = Math.ceil(r * 2 + 4), c = canvas(s, s), g = c.getContext('2d'), o = s / 2;
      g.fillStyle = 'rgba(255,255,255,0.10)'; g.beginPath(); g.arc(o, o, r, 0, TAU); g.fill();
      g.fillStyle = 'rgba(10,12,40,0.10)'; g.beginPath(); g.arc(o, o - r * 0.25, r * 0.7, 0, TAU); g.fill();
      g.strokeStyle = 'rgba(255,255,255,0.30)'; g.lineWidth = Math.max(0.8, r * 0.35);
      g.beginPath(); g.arc(o, o, r * 0.8, 0.15 * Math.PI, 0.85 * Math.PI); g.stroke();
      return c;
    };
    const sprites = [1.1, 1.6, 2.2, 3.0, 4.0].map(sprite);
    const dn = field(30, 14, 707), area = (W * H) / (3840 * 1646);
    const n = Math.round(F.micro * area);
    for (let i = 0; i < n; i++) {
      const x = rnd(0, W), y = rnd(0, H);
      if (!chance(lerp(0.35, 1, dn(x, y)))) continue;
      const s = sprites[Math.min(4, Math.floor(Math.pow(R(), 2.2) * 5))];
      fc.globalAlpha = rnd(0.45, 1);
      fc.drawImage(s, x - s.width / 2, y - s.width / 2);
    }
    fc.globalAlpha = 1;
  }

  // the mask: where the fog is, and how thick
  const mask = canvas(W, H), mk = mask.getContext('2d');
  {
    const g = mk.createLinearGradient(0, 0, 0, H);
    F.density.forEach(([s, a]) => g.addColorStop(s, `rgba(255,255,255,${a})`));
    mk.fillStyle = g; mk.fillRect(0, 0, W, H);
    // uneven: thinner patches here and there
    mk.globalCompositeOperation = 'destination-out';
    for (let i = 0; i < 16; i++) glow(mk, rnd(0, W), rnd(0, H), rnd(300, 800), rnd(150, 400), '0,0,0', rnd(0.06, 0.16));
    // the wipe: overlapping finger strokes, each a rounded band with a ragged end
    mk.filter = `blur(${F.feather}px)`;
    F.swipes.forEach((s) => {
      const p = new Path2D(), n = 120, e = 2.2, jit = field(16, 3, Math.round(s.x + s.y));
      for (let i = 0; i < n; i++) {
        const t = (i / n) * TAU, c = Math.cos(t), sn = Math.sin(t);
        const rr = 1 / Math.pow(Math.pow(Math.abs(c), e) + Math.pow(Math.abs(sn), e), 1 / e);
        const end = Math.pow(Math.abs(c), 4), j = 1 + (jit((i / n) * W, s.y) - 0.5) * (0.05 + 0.16 * end);
        const x = s.x + c * rr * s.rx * j, y = s.y + sn * rr * s.ry * j;
        const rx = x - s.x, ry = y - s.y, cr = Math.cos(s.rot || 0), sr = Math.sin(s.rot || 0);
        const X = s.x + rx * cr - ry * sr, Y = s.y + rx * sr + ry * cr;
        i ? p.lineTo(X, Y) : p.moveTo(X, Y);
      }
      p.closePath();
      mk.fillStyle = 'rgba(0,0,0,1)'; mk.fill(p);
    });
    mk.filter = 'none';
    mk.globalCompositeOperation = 'source-over';
    // a faint film left by the wipe, with finger streaks along each stroke
    F.swipes.forEach((s) => {
      for (let i = 0; i < F.streaks; i++) {
        const off = rnd(-0.8, 0.8) * s.ry, bow = rnd(-0.35, 0.35) * s.ry, a = rnd(0.03, 0.08);
        const x0 = s.x - s.rx * rnd(0.7, 0.95), x1 = s.x + s.rx * rnd(0.7, 0.95);
        mk.save(); mk.filter = `blur(${rnd(5, 10)}px)`;
        mk.strokeStyle = `rgba(255,255,255,${a})`; mk.lineWidth = rnd(8, 22); mk.lineCap = 'round';
        mk.beginPath();
        for (let x = x0; x <= x1; x += 40) {
          const t = (x - s.x) / s.rx, y = s.y + off + bow * t * t + Math.sin(t * 2 + off) * 4;
          const cr = Math.cos(s.rot || 0), sr = Math.sin(s.rot || 0), rx = x - s.x, ry = y - s.y;
          const X = s.x + rx * cr - ry * sr, Y = s.y + rx * sr + ry * cr;
          x === x0 ? mk.moveTo(X, Y) : mk.lineTo(X, Y);
        }
        mk.stroke(); mk.restore();
      }
    });
  }
  // read the mask back once: alpha lookup for drips and beads
  let md = mk.getImageData(0, 0, W, H).data;
  const fogAt = (x, y) => md[(clamp(Math.round(y), 0, H - 1) * W + clamp(Math.round(x), 0, W - 1)) * 4 + 3] / 255;

  // drips: water gathered at the bottom of the wipe runs down, clearing a line through the fog
  const inner = [];
  const dripLines = [];
  function drip(x, y0, len, w) {
    const pts = []; let x1 = x, drift = 0;
    for (let y = y0; y < y0 + len; y += 8) { pts.push([x1, y]); drift = clamp(drift + rnd(-0.25, 0.25), -0.7, 0.7); x1 += drift; }
    mk.save(); mk.globalCompositeOperation = 'destination-out'; mk.filter = 'blur(2px)';
    mk.lineCap = 'round'; mk.lineJoin = 'round';
    for (let i = 1; i < pts.length; i++) {
      const t = i / pts.length;
      mk.strokeStyle = `rgba(0,0,0,${lerp(0.5, 0.72, t).toFixed(3)})`; mk.lineWidth = w * lerp(0.45, 0.95, t);
      mk.beginPath(); mk.moveTo(pts[i - 1][0], pts[i - 1][1]); mk.lineTo(pts[i][0], pts[i][1]); mk.stroke();
    }
    mk.restore();
    dripLines.push({ pts, w });
    const [hx, hy] = pts[pts.length - 1];
    inner.push(makeDrop(hx, hy + w * 0.3, w * rnd(0.95, 1.2), 'oblong'));
    for (let i = 0; i < pts.length - 6; i += Math.round(rnd(5, 11))) if (chance(0.45)) inner.push(makeDrop(pts[i][0] + rnd(-0.3, 0.3) * w, pts[i][1], w * rnd(0.16, 0.32), 'round'));
  }
  F.drips.forEach((d) => {
    // start where the wipe ends: scan down from inside the patch to the fog
    let y = d.from;
    while (y < H - 20 && fogAt(d.x, y) < 0.5) y += 4;
    drip(d.x, y - d.w * 0.6, d.len, d.w);
    inner.push(makeDrop(d.x, y - d.w * 0.3, d.w * rnd(0.9, 1.15), 'merged'));
  });
  (F.freeDrips || []).forEach((d) => drip(d.x, d.y, d.len, d.w));
  md = mk.getImageData(0, 0, W, H).data;

  // beads pushed to the edge of the wipe, and scattered through the fog
  {
    const b = F.edgeBox, area = (W * H) / (3840 * 1646);
    let made = 0, tries = 0;
    while (made < F.edgeBeads && tries < F.edgeBeads * 60) {
      tries++;
      const x = rnd(b.x, b.x + b.w), y = rnd(b.y, b.y + b.h), a = fogAt(x, y);
      if (a < 0.08 || a > 0.66) continue;
      if (calmAt(x, y, 4)) continue;
      if (!chance(lerp(0.6, 1, (y - b.y) / b.h))) continue;
      const big = y > b.y + b.h * 0.5 && chance(0.22);
      inner.push(makeDrop(x, y, big ? rnd(6, 11) : rnd(2, 6.5), chance(0.25) ? 'oblong' : 'round'));
      made++;
    }
    const n = Math.round(F.beads * area);
    made = 0; tries = 0;
    while (made < n && tries < n * 30) {
      tries++;
      const x = rnd(0, W), y = rnd(0, H);
      if (!chance(fogAt(x, y))) continue;
      inner.push(makeDrop(x, y, rnd(1.6, 4.6) * (chance(0.06) ? 1.6 : 1), 'round'));
      made++;
    }
  }

  // =====================================================================================
  // 6. Composite, light, grain.
  // =====================================================================================
  const art = document.getElementById('art'), ac = art.getContext('2d');
  ac.drawImage(outer, 0, 0);
  {
    // Under the fog the outer drops are diffused too; only the wiped glass stays sharp. The fog
    // is drawn at 70-92% over this, so a sharp layer here would show every drop's rim and
    // highlight through it as a soap bubble. outer goes first so the blurred copy's soft edges
    // show outer, not the page; the mask taken out twice leaves ~3% of the sharp layer under fog.
    const clear = canvas(W, H), cg = clear.getContext('2d');
    cg.drawImage(outer, 0, 0);
    cg.globalCompositeOperation = 'destination-out'; cg.drawImage(mask, 0, 0); cg.drawImage(mask, 0, 0);
    ac.drawImage(blurred(outer, 10), 0, 0);
    ac.drawImage(clear, 0, 0);
  }
  fc.globalCompositeOperation = 'destination-in'; fc.drawImage(mask, 0, 0);
  fc.globalCompositeOperation = 'source-over';
  ac.drawImage(fog, 0, 0);
  dripLines.forEach(({ pts, w }) => {
    const hw = (i) => w * lerp(0.45, 0.95, i / pts.length) * 0.45, p = new Path2D();
    pts.forEach(([x, y], i) => (i ? p.lineTo(x - hw(i), y) : p.moveTo(x - hw(i), y)));
    for (let i = pts.length - 1; i >= 0; i--) p.lineTo(pts[i][0] + hw(i), pts[i][1]);
    p.closePath();
    ac.save(); ac.clip(p);
    ac.drawImage(outer, 2, 0);                                  // the film of water shifts the view a hair
    ac.globalCompositeOperation = 'screen'; ac.fillStyle = 'rgba(200,214,255,0.07)'; ac.fill(p);
    ac.restore();
    const edge = (side, col) => { ac.beginPath(); pts.forEach(([x, y], i) => (i ? ac.lineTo(x + side * hw(i), y) : ac.moveTo(x + side * hw(i), y))); ac.strokeStyle = col; ac.stroke(); };
    ac.save(); ac.lineWidth = 1; edge(-1, 'rgba(240,246,255,0.12)'); edge(1, 'rgba(10,12,40,0.10)'); ac.restore();
  });
  inner.sort((a, b) => a.R - b.R).forEach((d) => lens(ac, d, 0.92, 0.12));
  (C.blooms || []).forEach((b) => { ac.globalCompositeOperation = 'screen'; glow(ac, b.x, b.y, b.rx, b.ry, b.rgb, b.a); });
  ac.globalCompositeOperation = 'source-over';
  (C.shades || []).forEach((b) => glow(ac, b.x, b.y, b.rx, b.ry, b.rgb, b.a));
  {
    ac.save(); ac.translate(W / 2, H * 0.5); ac.scale(1, H / W);
    const g = ac.createRadialGradient(0, 0, W * 0.36, 0, 0, W * 0.8);
    g.addColorStop(0, 'rgba(8,10,34,0)'); g.addColorStop(1, rgba('8,10,34', C.vignette));
    ac.fillStyle = g; ac.fillRect(-W, -W, 2 * W, 2 * W); ac.restore();
  }
  {
    const id = ac.getImageData(0, 0, W, H), px = id.data, gr = mulberry(C.seed ^ 0x5eed), amp = C.grain;
    const sat = C.grade ? C.grade.sat : 1, con = C.grade ? C.grade.con : 1;
    // exposure: a gamma below 1 lifts the shadows and mids and leaves white where it is
    const gam = (C.grade && C.grade.gamma) || 1, lut = new Float32Array(256);
    for (let v = 0; v < 256; v++) lut[v] = 255 * Math.pow(v / 255, gam);
    for (let i = 0; i < px.length; i += 4) {
      const r = lut[px[i]], g = lut[px[i + 1]], b = lut[px[i + 2]], l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      const n = (gr() + gr() + gr() - 1.5) * amp;
      px[i] = 128 + (l + (r - l) * sat - 128) * con + n;
      px[i + 1] = 128 + (l + (g - l) * sat - 128) * con + n;
      px[i + 2] = 128 + (l + (b - l) * sat - 128) * con + n;
    }
    ac.putImageData(id, 0, 0);
  }
  document.documentElement.dataset.painted = '1';
})();
