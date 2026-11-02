// References header trimming and folding (port of
// MimeBuilder.formatReferencesHeader / trimmedReferences): root + the 20 most
// recent IDs, IDs that cannot fit any line dropped, folded at 78 with CRLF+SP.

import { describe, expect, it } from 'vitest'
import {
  buildReply,
  formatReferencesHeader,
  HEADER_LINE_HARD_LIMIT,
  HEADER_LINE_SOFT_LIMIT,
  REFERENCES_RECENT_ID_LIMIT,
  trimmedReferences,
} from './mimeBuilder'

/**
 * 50-character Message-IDs, numbered so order is checkable. Short enough that
 * two fit on a 78-character line; a chain of 40 space-joined is ~2000
 * characters, double the hard limit.
 */
function chain(count: number): string[] {
  return Array.from(
    { length: count },
    (_, index) => `<CA+${String(index).padStart(3, '0')}${'x'.repeat(27)}@mail.gmail.com>`,
  )
}

function headerLines(mime: string, field: string): string[] {
  const headerBlock = mime.split('\r\n\r\n')[0] ?? ''
  const lines = headerBlock.split('\r\n')
  const start = lines.findIndex((line) => line.startsWith(`${field}: `))
  if (start === -1) return []
  const out = [lines[start]!]
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index]!
    if (!line.startsWith(' ')) break
    out.push(line)
  }
  return out
}

describe('trimmedReferences', () => {
  // Revert-check: the root + suffix(REFERENCES_RECENT_ID_LIMIT) slice.
  it('keeps the thread root plus the 20 most recent IDs of a 40-id chain, in order', () => {
    const ids = chain(40)
    const trimmed = trimmedReferences(ids)

    expect(trimmed).toHaveLength(REFERENCES_RECENT_ID_LIMIT + 1)
    expect(trimmed[0]).toBe(ids[0])
    expect(trimmed.slice(1)).toEqual(ids.slice(-REFERENCES_RECENT_ID_LIMIT))
    // The parent's Message-ID (the last entry) always survives, last.
    expect(trimmed.at(-1)).toBe(ids.at(-1))
  })

  it('leaves a chain of 21 or fewer IDs untouched', () => {
    expect(trimmedReferences(chain(21))).toEqual(chain(21))
    expect(trimmedReferences(chain(3))).toEqual(chain(3))
    expect(trimmedReferences([])).toEqual([])
  })

  it('re-tokenizes entries carrying several IDs or folding whitespace, and drops malformed tokens', () => {
    const [a, b, c] = chain(3) as [string, string, string]
    expect(trimmedReferences([`${a} ${b}`, `\r\n ${c}`, 'not-an-id', '<a b@x>'])).toEqual([a, b, c])
  })

  // Revert-check: the utf8Length(id) <= maxIdLength filter.
  it('drops an ID that could not fit a header line even alone, keeping the rest', () => {
    const [a, b] = chain(2) as [string, string]
    const tooLong = `<${'y'.repeat(HEADER_LINE_HARD_LIMIT - 'References: '.length)}@x>`
    const justFits = `<${'y'.repeat(HEADER_LINE_HARD_LIMIT - 'References: '.length - 4)}@x>`
    expect(trimmedReferences([a, tooLong, b])).toEqual([a, b])
    expect(trimmedReferences([a, justFits, b])).toEqual([a, justFits, b])
  })
})

describe('formatReferencesHeader', () => {
  // Revert-check: the fold branch in formatReferencesHeader — a space-joined
  // 21-id line is ~1500 characters.
  it('folds a 40-id chain so no line exceeds 78 characters including the field name', () => {
    const value = formatReferencesHeader(chain(40))
    expect(value).not.toBeNull()
    const lines = `References: ${value}`.split('\r\n')
    expect(lines.length).toBeGreaterThan(1)
    for (const [index, line] of lines.entries()) {
      if (index > 0) expect(line.startsWith(' ')).toBe(true)
      expect(line.length).toBeLessThanOrEqual(HEADER_LINE_SOFT_LIMIT)
    }
    // Unfolding gives back exactly the trimmed chain.
    expect(value!.replaceAll('\r\n ', ' ').split(' ')).toEqual(trimmedReferences(chain(40)))
  })

  it('packs IDs greedily onto a line and gives an over-long ID a line of its own', () => {
    const short = ['<a@x>', '<b@x>', '<c@x>']
    expect(formatReferencesHeader(short)).toBe('<a@x> <b@x> <c@x>')

    const long = `<${'z'.repeat(90)}@x>`
    expect(formatReferencesHeader(['<a@x>', long, '<b@x>'])).toBe(`<a@x>\r\n ${long}\r\n <b@x>`)
    // A msg-id cannot be folded internally: the root goes first even when the
    // field name plus the root alone already passes the soft limit.
    expect(formatReferencesHeader([long, '<b@x>'])).toBe(`${long}\r\n <b@x>`)
  })

  it('returns null when no usable ID remains', () => {
    expect(formatReferencesHeader([])).toBeNull()
    expect(formatReferencesHeader(['garbage', ''])).toBeNull()
  })
})

describe('buildReply References emission', () => {
  // Revert-check: formatReferencesHeader call in buildMime — the old
  // `references.join(' ')` emits one 1500-character line.
  it('emits the trimmed, folded chain for a 40-reply thread and keeps In-Reply-To', () => {
    const ids = chain(40)
    const mime = buildReply({
      from: { email: 'me@example.com' },
      to: ['bob@example.com'],
      subject: 'Re: Hello',
      textBody: 'hi',
      inReplyTo: ids.at(-1)!,
      references: ids,
    })

    const lines = headerLines(mime, 'References')
    expect(lines.length).toBeGreaterThan(1)
    for (const line of lines) {
      expect(line.length).toBeLessThanOrEqual(HEADER_LINE_SOFT_LIMIT)
    }
    const unfolded = lines
      .join('')
      .replace(/^References: /u, '')
      .split(' ')
      .filter((token) => token !== '')
    expect(unfolded).toEqual([ids[0], ...ids.slice(-REFERENCES_RECENT_ID_LIMIT)])
    expect(mime).toContain(`In-Reply-To: ${ids.at(-1)}\r\n`)
    // Every header line in the message respects the hard limit.
    for (const line of (mime.split('\r\n\r\n')[0] ?? '').split('\r\n')) {
      expect(line.length).toBeLessThanOrEqual(HEADER_LINE_HARD_LIMIT)
    }
  })

  it('still emits a short chain on one line', () => {
    const mime = buildReply({
      from: { email: 'me@example.com' },
      to: ['bob@example.com'],
      textBody: 'hi',
      inReplyTo: '<b@x>',
      references: ['<a@x>', '<b@x>'],
    })
    expect(headerLines(mime, 'References')).toEqual(['References: <a@x> <b@x>'])
  })
})
