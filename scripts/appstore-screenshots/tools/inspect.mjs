// node tools/inspect.mjs capture.png  -> prints row/column profile of non-black content,
// to find card bounds and where a screen's meaningful content ends.
import { readFileSync } from 'node:fs';
import { decodePNG } from '../png.mjs';

const img = decodePNG(readFileSync(process.argv[2]));
const { width, height, channels, data } = img;
const px = (x, y) => {
  const i = (y * width + x) * channels;
  return [data[i], data[i + 1], data[i + 2]];
};
const lum = ([r, g, b]) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

console.log('size', width, height, 'channels', channels, 'chunks', [...new Set(img.chunks)].join(','));
// rows containing any non-black pixel (lum > 12)
let runs = [], start = -1;
for (let y = 0; y < height; y++) {
  let any = false;
  for (let x = 0; x < width; x += 2) if (lum(px(x, y)) > 12) { any = true; break; }
  if (any && start < 0) start = y;
  if (!any && start >= 0) { runs.push([start, y - 1]); start = -1; }
}
if (start >= 0) runs.push([start, height - 1]);
console.log('non-black row runs:', runs.map(r => r.join('-')).join('  '));

if (process.argv[3]) {
  // probe a specific row: print first/last non-black x
  const y = +process.argv[3];
  let first = -1, last = -1;
  for (let x = 0; x < width; x++) if (lum(px(x, y)) > 12) { if (first < 0) first = x; last = x; }
  console.log(`row ${y}: first ${first} last ${last}`, 'color@center', px(width >> 1, y));
}
if (process.argv[4]) {
  // probe a column: runs of non-black
  const x = +process.argv[4];
  let rs = [], s = -1;
  for (let y = 0; y < height; y++) {
    const on = lum(px(x, y)) > 12;
    if (on && s < 0) s = y;
    if (!on && s >= 0) { rs.push([s, y - 1]); s = -1; }
  }
  console.log(`col ${x} runs:`, rs.map(r => r.join('-')).join('  '));
}
