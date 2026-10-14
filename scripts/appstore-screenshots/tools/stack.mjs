// node tools/stack.mjs out.png x y w h in1.png in2.png ... -> vertical stack of the same crop, 8px white rule between
import { readFileSync, writeFileSync } from 'node:fs';
import { decodePNG, encodeRGB, toOpaqueRGB } from '../png.mjs';
const [out, x, y, w, h, ...ins] = process.argv.slice(2); const X=+x, Y=+y, Wd=+w, Ht=+h, gap = 8;
const H = ins.length * Ht + (ins.length - 1) * gap; const buf = Buffer.alloc(Wd * H * 3, 255);
ins.forEach((p, k) => { const img = toOpaqueRGB(decodePNG(readFileSync(p))); for (let j = 0; j < Ht; j++) img.data.copy(buf, ((k * (Ht + gap)) + j) * Wd * 3, ((Y + j) * img.width + X) * 3, ((Y + j) * img.width + X + Wd) * 3); });
writeFileSync(out, encodeRGB({ width: Wd, height: H, data: buf }));
