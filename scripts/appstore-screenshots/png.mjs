// Minimal dependency-free PNG reader/writer (8-bit, non-interlaced, gray/RGB/RGBA).
// Used by compose.mjs to strip the alpha channel Chrome writes into its screenshots and to
// write the film-grain tile, and by tools/*.mjs to measure and crop captures.
import { inflateSync, deflateSync } from 'node:zlib';

const SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

export function decodePNG(buf) {
  if (!buf.subarray(0, 8).equals(SIG)) throw new Error('not a PNG');
  let off = 8, width, height, bitDepth, colorType, interlace;
  const idat = [];
  const chunks = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('ascii', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    chunks.push(type);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (bitDepth !== 8 || interlace !== 0) throw new Error(`unsupported PNG (depth ${bitDepth}, interlace ${interlace})`);
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  if (!channels) throw new Error(`unsupported colour type ${colorType}`);
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(stride * height);
  const bpp = channels;
  for (let y = 0; y < height; y++) {
    const ft = raw[y * (stride + 1)];
    const src = y * (stride + 1) + 1;
    const dst = y * stride;
    const prev = dst - stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[dst + x - bpp] : 0;
      const b = y > 0 ? out[prev + x] : 0;
      const c = x >= bpp && y > 0 ? out[prev + x - bpp] : 0;
      let v = raw[src + x];
      switch (ft) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += b; break;
        case 3: v += (a + b) >> 1; break;
        case 4: {
          const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
          break;
        }
        default: throw new Error(`bad filter ${ft}`);
      }
      out[dst + x] = v & 0xff;
    }
  }
  return { width, height, channels, data: out, chunks };
}

// Encode 8-bit RGB (no alpha) with an sRGB chunk. Each row uses the filter with the
// smallest sum of absolute residuals (the libpng heuristic).
export function encodeRGB({ width, height, data }) {
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  const cand = Array.from({ length: 5 }, () => Buffer.alloc(stride));
  for (let y = 0; y < height; y++) {
    const row = y * stride, prev = row - stride;
    let best = 0, bestSum = Infinity;
    for (let f = 0; f < 5; f++) {
      const o = cand[f];
      let sum = 0;
      for (let x = 0; x < stride; x++) {
        const v = data[row + x];
        const a = x >= 3 ? data[row + x - 3] : 0;
        const b = y > 0 ? data[prev + x] : 0;
        const c = x >= 3 && y > 0 ? data[prev + x - 3] : 0;
        let r;
        if (f === 0) r = v;
        else if (f === 1) r = v - a;
        else if (f === 2) r = v - b;
        else if (f === 3) r = v - ((a + b) >> 1);
        else {
          const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          r = v - (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
        }
        r &= 0xff;
        o[x] = r;
        sum += r < 128 ? r : 256 - r;
      }
      if (sum < bestSum) { bestSum = sum; best = f; }
    }
    raw[y * (stride + 1)] = best;
    cand[best].copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    SIG,
    chunk('IHDR', ihdr),
    chunk('sRGB', Buffer.from([0])),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Encode an 8-bit greyscale image (colour type 0) with an sRGB chunk. Filter 0 on every
// row: the only caller is the film-grain tile, which is noise and does not predict anyway.
export function encodeGray({ width, height, data }) {
  const raw = Buffer.alloc((width + 1) * height);
  for (let y = 0; y < height; y++) data.copy(raw, y * (width + 1) + 1, y * width, (y + 1) * width);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 0;
  return Buffer.concat([
    SIG,
    chunk('IHDR', ihdr),
    chunk('sRGB', Buffer.from([0])),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Drop alpha by compositing over a solid colour (default black; Chrome's screenshot of
// an opaque page is already alpha 255 everywhere, so this is a pure channel strip).
export function toOpaqueRGB(img, bg = [0, 0, 0]) {
  const { width, height, channels, data } = img;
  const out = Buffer.alloc(width * height * 3);
  for (let i = 0, j = 0; i < data.length; i += channels, j += 3) {
    if (channels >= 3) {
      const a = channels === 4 ? data[i + 3] / 255 : 1;
      out[j] = Math.round(data[i] * a + bg[0] * (1 - a));
      out[j + 1] = Math.round(data[i + 1] * a + bg[1] * (1 - a));
      out[j + 2] = Math.round(data[i + 2] * a + bg[2] * (1 - a));
    } else {
      const a = channels === 2 ? data[i + 1] / 255 : 1;
      const g = data[i];
      out[j] = out[j + 1] = out[j + 2] = Math.round(g * a + bg[0] * (1 - a));
    }
  }
  return { width, height, data: out };
}
