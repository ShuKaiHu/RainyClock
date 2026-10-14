// node tools/crop.mjs in.png out.png x y w h   -> 1:1 crop, for checking type at full size.
import { readFileSync, writeFileSync } from 'node:fs';
import { decodePNG, encodeRGB, toOpaqueRGB } from '../png.mjs';

const [src, dst, ...r] = process.argv.slice(2);
const [x, y, w, h] = r.map(Number);
const img = toOpaqueRGB(decodePNG(readFileSync(src)));
const out = Buffer.alloc(w * h * 3);
for (let j = 0; j < h; j++) img.data.copy(out, j * w * 3, ((y + j) * img.width + x) * 3, ((y + j) * img.width + x + w) * 3);
writeFileSync(dst, encodeRGB({ width: w, height: h, data: out }));
