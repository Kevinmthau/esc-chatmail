// Body/content decoding: Gmail base64url, quoted-printable (incl. the
// header-absent heuristic), and HTML entity decoding.
// Ports: MessageProcessor.decodeBase64Data / decodeTransferEncoding /
// looksQuotedPrintable, QuotedPrintableDecoder, HTMLEntityDecoder.

import type { GmailHeader } from '../gmail/types'

const utf8Decoder = new TextDecoder('utf-8')
const utf8Encoder = new TextEncoder()

/**
 * Decodes Gmail's URL-safe base64 (RFC 4648) permissively: `-`/`_` mapped to
 * `+`/`/`, incidental whitespace stripped, padding restored. Returns null when
 * the payload is not decodable.
 */
export function base64UrlDecodeToBytes(data: string): Uint8Array | null {
  let base64 = data
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    .replace(/[\r\n\t ]/g, '')

  const remainder = base64.length % 4
  if (remainder > 0) {
    base64 += '='.repeat(4 - remainder)
  }

  let binary: string
  try {
    binary = atob(base64)
  } catch {
    return null
  }

  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

/** base64url → UTF-8 string (lossy replacement on invalid sequences). */
export function base64UrlDecodeToString(data: string): string | null {
  const bytes = base64UrlDecodeToBytes(data)
  if (bytes === null) return null
  return utf8Decoder.decode(bytes)
}

/** Standard (non-URL-safe) base64 text decode used by the raw-source sanitizer. */
export function base64DecodeText(text: string): string | null {
  const compact = text.replace(/[\n\t ]/g, '')
  if (compact.length === 0) return null

  const remainder = compact.length % 4
  const padded = remainder === 0 ? compact : compact + '='.repeat(4 - remainder)

  let binary: string
  try {
    binary = atob(padded)
  } catch {
    return null
  }
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return utf8Decoder.decode(bytes)
}

function hexValue(byte: number): number | null {
  if (byte >= 48 && byte <= 57) return byte - 48 // 0-9
  if (byte >= 65 && byte <= 70) return byte - 55 // A-F
  if (byte >= 97 && byte <= 102) return byte - 87 // a-f
  return null
}

/** Minimal quoted-printable decoder: soft line breaks and =XX hex escapes. */
export function decodeQuotedPrintableToBytes(text: string): Uint8Array {
  const bytes = utf8Encoder.encode(text)
  const output: number[] = []

  let i = 0
  while (i < bytes.length) {
    const byte = bytes[i]!
    if (byte === 61) {
      // '='
      // Soft line break: "=\r\n" or "=\n"
      if (i + 1 < bytes.length) {
        const next = bytes[i + 1]!
        if (next === 10) {
          i += 2
          continue
        }
        if (next === 13) {
          if (i + 2 < bytes.length && bytes[i + 2] === 10) {
            i += 3
            continue
          }
        }
      }

      // Hex escape: =XX
      if (i + 2 < bytes.length) {
        const hi = hexValue(bytes[i + 1]!)
        const lo = hexValue(bytes[i + 2]!)
        if (hi !== null && lo !== null) {
          output.push(hi * 16 + lo)
          i += 3
          continue
        }
      }

      // Fallback: keep literal '='
      output.push(byte)
      i += 1
    } else {
      output.push(byte)
      i += 1
    }
  }

  return new Uint8Array(output)
}

export function decodeQuotedPrintable(text: string): string {
  return utf8Decoder.decode(decodeQuotedPrintableToBytes(text))
}

/** Header-absent quoted-printable heuristic from MessageProcessor. */
export function looksQuotedPrintable(text: string): boolean {
  if (text.includes('=\r\n') || text.includes('=\n')) {
    return true
  }
  const lower = text.toLowerCase()
  return lower.includes('=3d') || lower.includes('=3c') || lower.includes('=3e')
}

/**
 * Applies Content-Transfer-Encoding to an already base64-decoded body string.
 * Decodes quoted-printable when the header says so, or when the header is
 * absent and the body looks like QP.
 */
export function decodeTransferEncoding(
  text: string,
  headers: readonly GmailHeader[] | undefined,
): string {
  const encoding = headers
    ?.find((h) => h.name.toLowerCase() === 'content-transfer-encoding')
    ?.value.toLowerCase()
  if (encoding !== undefined && encoding.includes('quoted-printable')) {
    return decodeQuotedPrintable(text)
  }
  if (encoding === undefined && looksQuotedPrintable(text)) {
    return decodeQuotedPrintable(text)
  }
  return text
}

// MARK: - HTML entity decoding
//
// Single-pass scanner over the limited entity set the iOS pipeline handles
// (HTMLEntityDecoder / TextProcessing.decodeHTMLEntities).

const NAMED_ENTITY_MAP: Record<string, string> = {
  nbsp: ' ',
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  zwnj: '',
  zwj: '',
  ldquo: '"',
  rdquo: '"',
  lsquo: "'",
  rsquo: "'",
  ndash: '–',
  mdash: '—',
  hellip: '…',
}

const NUMERIC_ENTITY_MAP: Record<string, string> = {
  '160': ' ',
  '39': "'",
  '34': '"',
  '8204': '',
  '8205': '',
  '8220': '"',
  '8221': '"',
  '8216': "'",
  '8217': "'",
  '8211': '–',
  '8212': '—',
  '8230': '…',
}

const HEX_ENTITY_MAP: Record<string, string> = {
  a0: ' ',
  '00a0': ' ',
  '200c': '',
  '200d': '',
}

/**
 * Decodes the pipeline's known HTML entities and strips zero-width characters.
 */
export function decodeHtmlEntities(text: string): string {
  let result = ''
  if (text.includes('&')) {
    let index = 0
    while (index < text.length) {
      if (text[index] === '&') {
        const semicolonIndex = text.indexOf(';', index + 1)
        if (semicolonIndex > index + 1 && semicolonIndex - index <= 12) {
          const entity = text.slice(index + 1, semicolonIndex)
          let replacement: string | undefined
          if (entity.startsWith('#x') || entity.startsWith('#X')) {
            replacement = HEX_ENTITY_MAP[entity.slice(2).toLowerCase()]
          } else if (entity.startsWith('#')) {
            replacement = NUMERIC_ENTITY_MAP[entity.slice(1)]
          } else {
            replacement = NAMED_ENTITY_MAP[entity.toLowerCase()]
          }

          if (replacement !== undefined) {
            result += replacement
            index = semicolonIndex + 1
            continue
          }
        }
      }
      result += text[index]
      index += 1
    }
  } else {
    result = text
  }

  // Strip zero-width Unicode characters.
  return result.replace(/[\u200B\u200C\u200D]/g, '')
}
