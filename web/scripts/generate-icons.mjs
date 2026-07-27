// Generates the PWA icon PNGs without native deps: a blue rounded square with
// a white chat-bubble glyph, rasterized by per-pixel coverage tests and
// encoded as PNG by hand (zlib from node:zlib).
//
// Run: node scripts/generate-icons.mjs   (writes public/icons/*.png)

import { deflateSync } from 'node:zlib'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), '../public/icons')

const BLUE = [0x00, 0x7a, 0xff]
const WHITE = [0xff, 0xff, 0xff]

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

function encodePng(size, pixelAt) {
  const raw = Buffer.alloc(size * (size * 3 + 1))
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 3 + 1)
    raw[rowStart] = 0 // filter: none
    for (let x = 0; x < size; x++) {
      const [r, g, b] = pixelAt(x, y)
      const i = rowStart + 1 + x * 3
      raw[i] = r
      raw[i + 1] = g
      raw[i + 2] = b
    }
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0)
  ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 2 // color type: truecolor
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

function insideRoundedRect(x, y, left, top, w, h, r) {
  const right = left + w
  const bottom = top + h
  if (x < left || x >= right || y < top || y >= bottom) return false
  const cx = Math.max(left + r, Math.min(x, right - r))
  const cy = Math.max(top + r, Math.min(y, bottom - r))
  return (
    (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2 ||
    (x >= left + r && x < right - r) ||
    (y >= top + r && y < bottom - r)
  )
}

function makeIcon(size, { maskable }) {
  // Maskable icons need the glyph inside the 80% safe zone; regular icons get
  // a rounded-square background with a small transparent-free margin (we use
  // opaque truecolor, so "margin" is just background bleed).
  const bgRadius = maskable ? 0 : Math.round(size * 0.18)
  const s = size
  const bubble = {
    left: s * 0.22,
    top: s * 0.26,
    w: s * 0.56,
    h: s * 0.38,
    r: s * 0.14,
  }
  return encodePng(size, (x, y) => {
    if (!maskable && !insideRoundedRect(x, y, 0, 0, s, s, bgRadius)) return WHITE
    // Chat-bubble tail: triangle from bubble bottom-left pointing down-left.
    const inTail =
      y >= bubble.top + bubble.h - s * 0.02 &&
      y <= bubble.top + bubble.h + s * 0.1 &&
      x >= bubble.left + s * 0.06 &&
      x <= bubble.left + s * 0.06 + (bubble.top + bubble.h + s * 0.1 - y)
    if (insideRoundedRect(x, y, bubble.left, bubble.top, bubble.w, bubble.h, bubble.r) || inTail) {
      return WHITE
    }
    return BLUE
  })
}

mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(join(OUT_DIR, 'icon-192.png'), makeIcon(192, { maskable: false }))
writeFileSync(join(OUT_DIR, 'icon-512.png'), makeIcon(512, { maskable: false }))
writeFileSync(join(OUT_DIR, 'maskable-512.png'), makeIcon(512, { maskable: true }))
writeFileSync(join(OUT_DIR, 'apple-touch-icon.png'), makeIcon(180, { maskable: true }))
console.log('icons written to', OUT_DIR)
