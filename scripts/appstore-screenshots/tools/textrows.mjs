// node tools/textrows.mjs capture.png y0 y1 [threshold=70]
// Prints the row ranges between y0 and y1 that contain "ink" (a pixel far from its row's
// median luminance). The gaps between runs are where a callout's band can go: from just
// below the UI above the callout's source to just above the UI below it.
import { readFileSync } from 'node:fs';
import { decodePNG } from '../png.mjs';

const [file, a, b, t] = process.argv.slice(2);
if (!file || a == null || b == null) { console.error('usage: node tools/textrows.mjs capture.png y0 y1 [threshold]'); process.exit(2); }
const img = decodePNG(readFileSync(file));
const y0 = +a, y1 = Math.min(+b, img.height - 1), thr = +(t || 70);
const lum = (x, y) => { const i = (y * img.width + x) * img.channels; return (img.data[i] + img.data[i + 1] + img.data[i + 2]) / 3; };
const runs = []; let start = null;
for (let y = y0; y <= y1; y++) {
  const ls = []; for (let x = 70; x < img.width - 70; x += 2) ls.push(lum(x, y));
  const med = [...ls].sort((p, q) => p - q)[ls.length >> 1];
  const ink = ls.some((l) => Math.abs(l - med) > thr);
  if (ink && start === null) start = y;
  if (!ink && start !== null) { runs.push(`${start}-${y - 1}`); start = null; }
}
if (start !== null) runs.push(`${start}-${y1}`);
console.log(runs.join('  '));
