// Port of esc-chatmail/Services/TextProcessing/RFC2047Decoder.swift.
//
// Decodes RFC 2047 encoded-words ("=?charset?B?...?=" / "=?charset?Q?...?=")
// that appear in message header values. Gmail's API usually hands back header
// values already decoded to UTF-8, but raw encoded words still reach us —
// malformed messages the API passes through verbatim, and an encoded word
// inside a quoted display name, which RFC 2047 does not allow and so is left
// alone. Undecoded words render as garbage in sender names.

import { hexValue } from './decode'

const utf8Encoder = new TextEncoder()

/**
 * encoded-word := "=?" charset ["*" language] "?" encoding "?" encoded-text "?="
 * charset and encoded-text never contain "?" or whitespace.
 */
const ENCODED_WORD_RE = /=\?([^?\s]+)\?([A-Za-z])\?([^?\s]*)\?=/g

/**
 * Cheap pre-check so callers can skip regex work for the common case.
 * Matches the "=?" opener plus a later "?=" closer; false positives are
 * harmless because `decodeRfc2047` leaves non-matching text untouched.
 */
export function containsEncodedWord(value: string): boolean {
  const openIndex = value.indexOf('=?')
  if (openIndex === -1) return false
  return value.indexOf('?=', openIndex + 2) !== -1
}

/**
 * Decodes every well-formed encoded-word in the value, leaving anything
 * undecodable exactly as it appeared. Linear whitespace BETWEEN two encoded
 * words is dropped (RFC 2047 §6.2); whitespace between an encoded word and
 * ordinary text is preserved.
 */
export function decodeRfc2047(value: string): string {
  if (!containsEncodedWord(value)) return value

  let output = ''
  let cursor = 0
  // Adjacent same-charset words accumulate raw bytes before charset
  // decoding: senders split multibyte characters across encoded words, so
  // decoding word-by-word would corrupt the split character.
  let pendingBytes: number[] = []
  let pendingCharset: string | null = null
  let previousWasDecodedWord = false

  const flushPending = (): void => {
    if (pendingCharset === null) return
    output += decodeBytes(Uint8Array.from(pendingBytes), pendingCharset)
    pendingBytes = []
    pendingCharset = null
  }

  for (const match of value.matchAll(ENCODED_WORD_RE)) {
    const separator = value.slice(cursor, match.index)
    const separatorIsBlank = /^[ \t\r\n]*$/.test(separator)

    const charset = normalizedCharset(match[1] ?? '')
    const encodingKind = (match[2] ?? '').toUpperCase()
    const encodedText = match[3] ?? ''

    const wordBytes =
      encodingKind === 'B'
        ? decodeBase64(encodedText)
        : encodingKind === 'Q'
          ? decodeQ(encodedText)
          : null

    if (wordBytes !== null) {
      const joinsPendingRun =
        pendingCharset !== null && pendingCharset === charset && separatorIsBlank
      if (!joinsPendingRun) {
        flushPending()
        // Whitespace between two encoded words disappears (§6.2); any other
        // separator text is real content.
        if (!(separatorIsBlank && previousWasDecodedWord)) {
          output += separator
        }
        pendingCharset = charset
      }
      pendingBytes.push(...wordBytes)
      previousWasDecodedWord = true
    } else {
      // Undecodable word: keep the surrounding text and the word itself
      // verbatim rather than guessing.
      flushPending()
      output += separator + match[0]
      previousWasDecodedWord = false
    }

    cursor = match.index + match[0].length
  }

  flushPending()
  return output + value.slice(cursor)
}

/**
 * Strips the optional RFC 2231 language tag ("utf-8*en" → "utf-8") and
 * lowercases for comparison/grouping.
 */
function normalizedCharset(raw: string): string {
  const starIndex = raw.indexOf('*')
  return (starIndex > 0 ? raw.slice(0, starIndex) : raw).toLowerCase()
}

function decodeBase64(text: string): Uint8Array | null {
  if (text === '') return new Uint8Array(0)
  // Some senders omit base64 padding. iOS restores it before decoding; atob
  // implements forgiving-base64, which accepts it missing.
  let binary: string
  try {
    binary = atob(text)
  } catch {
    return null
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

function decodeQ(text: string): Uint8Array | null {
  const input = utf8Encoder.encode(text)
  const bytes: number[] = []
  for (let i = 0; i < input.length; i++) {
    const byte = input[i]!
    if (byte === 0x5f) {
      // '_' is an encoded space.
      bytes.push(0x20)
    } else if (byte === 0x3d) {
      // '=' must be followed by two hex digits; anything else fails the word.
      const high = i + 1 < input.length ? hexValue(input[i + 1]!) : null
      const low = i + 2 < input.length ? hexValue(input[i + 2]!) : null
      if (high === null || low === null) return null
      bytes.push((high << 4) | low)
      i += 2
    } else {
      bytes.push(byte)
    }
  }
  return Uint8Array.from(bytes)
}

function decodeBytes(bytes: Uint8Array, charset: string): string {
  // Fallback chain: most mislabeled headers are really UTF-8, and Latin-1
  // maps every byte so it always yields something readable.
  return decodeWithCharset(bytes, charset) ?? decodeWithCharset(bytes, 'utf-8') ?? latin1(bytes)
}

function decodeWithCharset(bytes: Uint8Array, charset: string): string | null {
  // The WHATWG Encoding Standard maps the ASCII labels to windows-1252, which
  // accepts any byte. iOS decodes them as strict ASCII, so 8-bit bytes under a
  // us-ascii label (usually UTF-8 the sender mislabeled) fall through to the
  // UTF-8 fallback here too instead of becoming mojibake. The ISO-8859-1
  // labels are left to TextDecoder's windows-1252, where iOS reads true
  // Latin-1: the two differ only on 0x80-0x9F, which Latin-1 reads as
  // invisible C1 controls and windows-1252 as the punctuation such senders
  // almost always mean.
  if (charset === 'us-ascii' || charset === 'ascii') {
    return bytes.every((byte) => byte < 0x80) ? latin1(bytes) : null
  }
  try {
    return new TextDecoder(charset, { fatal: true }).decode(bytes)
  } catch {
    // RangeError: a charset label TextDecoder does not know. TypeError:
    // bytes that are invalid in that charset.
    return null
  }
}

function latin1(bytes: Uint8Array): string {
  let result = ''
  for (const byte of bytes) result += String.fromCharCode(byte)
  return result
}
