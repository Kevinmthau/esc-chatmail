// Generates the favicon and PWA icon PNGs from the iOS app icon, so the web
// app and the native app share one piece of artwork. No native deps: the
// source PNG is decoded by hand (zlib from node:zlib), box-filtered down to
// each size, and re-encoded by hand.
//
// The iOS source is a full-bleed opaque square that iOS masks itself. Icons a
// platform masks (apple-touch, maskable) stay full-bleed; icons shown as-is
// (browser tab favicon, manifest "any") get the iOS-style rounded corners cut
// out as transparency, so they read as the same app icon.
//
// Run: node scripts/generate-icons.mjs   (writes public/icons/*.png)

import { deflateSync, inflateSync } from 'node:zlib'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const SOURCE = join(
  HERE,
  '../../esc-chatmail/Resources/Assets.xcassets/AppIcon.appiconset/esc app icon.png',
)
const OUT_DIR = join(HERE, '../public/icons')

// iOS home-screen icon corner radius as a fraction of the icon's side.
const CORNER_RADIUS = 0.2237
// Per-axis subsamples used to anti-alias the rounded-corner edge.
const EDGE_SUBSAMPLES = 4

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

function crc32(buf) {
  let table = crc32.table
  if (!table) {
    table = crc32.table = new Int32Array(256)
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      table[n] = c
    }
  }
  let c = 0xffffffff
  for (const byte of buf) c = table[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(body))
  return Buffer.concat([len, body, crc])
}

function paeth(a, b, c) {
  const p = a + b - c
  const pa = Math.abs(p - a)
  const pb = Math.abs(p - b)
  const pc = Math.abs(p - c)
  if (pa <= pb && pa <= pc) return a
  return pb <= pc ? b : c
}

/** Decodes an 8-bit, non-interlaced RGB or RGBA PNG to { width, height, rgba }. */
function decodePng(file) {
  if (!file.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error('not a PNG')
  let offset = 8
  let header
  const idat = []
  while (offset < file.length) {
    const length = file.readUInt32BE(offset)
    const type = file.toString('ascii', offset + 4, offset + 8)
    const data = file.subarray(offset + 8, offset + 8 + length)
    if (type === 'IHDR') {
      header = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        bitDepth: data[8],
        colorType: data[9],
        interlace: data[12],
      }
    } else if (type === 'IDAT') {
      idat.push(data)
    } else if (type === 'IEND') {
      break
    }
    offset += 12 + length
  }
  const { width, height, bitDepth, colorType, interlace } = header
  const channels = { 2: 3, 6: 4 }[colorType]
  if (bitDepth !== 8 || !channels || interlace !== 0) {
    throw new Error(
      `unsupported PNG: depth ${bitDepth}, color ${colorType}, interlace ${interlace}`,
    )
  }

  const raw = inflateSync(Buffer.concat(idat))
  const stride = width * channels
  const pixels = Buffer.alloc(height * stride)
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)]
    const src = y * (stride + 1) + 1
    const dst = y * stride
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? pixels[dst + i - channels] : 0
      const b = y > 0 ? pixels[dst - stride + i] : 0
      const c = y > 0 && i >= channels ? pixels[dst - stride + i - channels] : 0
      const predictor = [0, a, b, (a + b) >> 1, paeth(a, b, c)][filter]
      if (predictor === undefined) throw new Error(`bad PNG filter ${filter}`)
      pixels[dst + i] = (raw[src + i] + predictor) & 0xff
    }
  }

  const rgba = Buffer.alloc(width * height * 4)
  for (let p = 0; p < width * height; p++) {
    for (let k = 0; k < 3; k++) rgba[p * 4 + k] = pixels[p * channels + k]
    rgba[p * 4 + 3] = channels === 4 ? pixels[p * channels + 3] : 0xff
  }
  return { width, height, rgba }
}

function encodePng(size, rgba) {
  const raw = Buffer.alloc(size * (size * 4 + 1))
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 4 + 1)
    raw[rowStart] = 0 // filter: none
    rgba.copy(raw, rowStart + 1, y * size * 4, (y + 1) * size * 4)
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0)
  ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // color type: truecolor + alpha
  return Buffer.concat([
    PNG_SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/** Area-averaging (box filter) downscale of a square image; exact for non-integer ratios. */
function resize(source, size) {
  const scale = source.width / size
  const out = Buffer.alloc(size * size * 4)
  for (let y = 0; y < size; y++) {
    const y0 = y * scale
    const y1 = y0 + scale
    for (let x = 0; x < size; x++) {
      const x0 = x * scale
      const x1 = x0 + scale
      const sum = [0, 0, 0, 0]
      let total = 0
      for (let sy = Math.floor(y0); sy < Math.ceil(y1); sy++) {
        const wy = Math.min(y1, sy + 1) - Math.max(y0, sy)
        for (let sx = Math.floor(x0); sx < Math.ceil(x1); sx++) {
          const w = wy * (Math.min(x1, sx + 1) - Math.max(x0, sx))
          const i = (sy * source.width + sx) * 4
          for (let k = 0; k < 4; k++) sum[k] += source.rgba[i + k] * w
          total += w
        }
      }
      for (let k = 0; k < 4; k++) out[(y * size + x) * 4 + k] = Math.round(sum[k] / total)
    }
  }
  return out
}

function insideRoundedSquare(x, y, size, r) {
  const cx = Math.max(r, Math.min(x, size - r))
  const cy = Math.max(r, Math.min(y, size - r))
  return (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2
}

/** Cuts iOS-style rounded corners out of an opaque icon as anti-aliased alpha. */
function roundCorners(rgba, size) {
  const r = size * CORNER_RADIUS
  const n = EDGE_SUBSAMPLES
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let covered = 0
      for (let j = 0; j < n; j++) {
        for (let i = 0; i < n; i++) {
          if (insideRoundedSquare(x + (i + 0.5) / n, y + (j + 0.5) / n, size, r)) covered++
        }
      }
      const a = (y * size + x) * 4 + 3
      rgba[a] = Math.round((rgba[a] * covered) / (n * n))
    }
  }
  return rgba
}

function makeIcon(source, size, { rounded }) {
  const rgba = resize(source, size)
  return encodePng(size, rounded ? roundCorners(rgba, size) : rgba)
}

const source = decodePng(readFileSync(SOURCE))
if (source.width !== source.height) throw new Error('iOS app icon must be square')

mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(join(OUT_DIR, 'favicon-32.png'), makeIcon(source, 32, { rounded: true }))
writeFileSync(join(OUT_DIR, 'icon-192.png'), makeIcon(source, 192, { rounded: true }))
writeFileSync(join(OUT_DIR, 'icon-512.png'), makeIcon(source, 512, { rounded: true }))
// The "Esc" glyph sits well inside the maskable 80% safe-zone circle.
writeFileSync(join(OUT_DIR, 'maskable-512.png'), makeIcon(source, 512, { rounded: false }))
// iOS masks apple-touch icons itself and renders transparency as black.
writeFileSync(join(OUT_DIR, 'apple-touch-icon.png'), makeIcon(source, 180, { rounded: false }))
console.log('icons written to', OUT_DIR)
