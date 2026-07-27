import { describe, expect, it } from 'vitest'
import {
  base64UrlDecodeToBytes,
  base64UrlDecodeToString,
  decodeHtmlEntities,
  decodeQuotedPrintable,
  decodeTransferEncoding,
  looksQuotedPrintable,
} from './decode'

function b64url(text: string): string {
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

describe('base64UrlDecode', () => {
  it('decodes URL-safe alphabet (- and _)', () => {
    // 0xfb 0xef 0xbe encodes to "++++" in standard base64 → "----" URL-safe.
    expect(base64UrlDecodeToBytes('----')).toEqual(new Uint8Array([0xfb, 0xef, 0xbe]))
    expect(base64UrlDecodeToBytes('____')).toEqual(new Uint8Array([0xff, 0xff, 0xff]))
  })

  it('re-pads unpadded payloads', () => {
    expect(base64UrlDecodeToString(b64url('hi'))).toBe('hi')
    expect(base64UrlDecodeToString(b64url('hello'))).toBe('hello')
    expect(base64UrlDecodeToString(b64url('hell'))).toBe('hell')
  })

  it('strips incidental whitespace before decoding', () => {
    const encoded = b64url('hello world')
    const noisy = `${encoded.slice(0, 4)}\r\n${encoded.slice(4, 8)}\t ${encoded.slice(8)}`
    expect(base64UrlDecodeToString(noisy)).toBe('hello world')
  })

  it('decodes multibyte UTF-8', () => {
    expect(base64UrlDecodeToString(b64url(unescape(encodeURIComponent('héllo — ✓'))))).toBe(
      'héllo — ✓',
    )
  })

  it('returns null for undecodable payloads', () => {
    expect(base64UrlDecodeToBytes('a')).toBeNull()
    expect(base64UrlDecodeToString('!!!!')).toBeNull()
  })
})

describe('decodeQuotedPrintable', () => {
  it('decodes hex escapes', () => {
    expect(decodeQuotedPrintable('a=3Db')).toBe('a=b')
    expect(decodeQuotedPrintable('=3Chtml=3E')).toBe('<html>')
    expect(decodeQuotedPrintable('you=27ll')).toBe("you'll")
  })

  it('decodes lowercase hex escapes', () => {
    expect(decodeQuotedPrintable('a=3db')).toBe('a=b')
  })

  it('removes soft line breaks (=\\n and =\\r\\n)', () => {
    expect(decodeQuotedPrintable('foo=\nbar')).toBe('foobar')
    expect(decodeQuotedPrintable('foo=\r\nbar')).toBe('foobar')
  })

  it('keeps literal = when not a valid escape', () => {
    expect(decodeQuotedPrintable('a=zb')).toBe('a=zb')
    expect(decodeQuotedPrintable('trailing=')).toBe('trailing=')
  })

  it('decodes multibyte UTF-8 escape sequences', () => {
    expect(decodeQuotedPrintable('caf=C3=A9')).toBe('café')
  })
})

describe('looksQuotedPrintable heuristic', () => {
  it('detects soft line breaks', () => {
    expect(looksQuotedPrintable('abc=\ndef')).toBe(true)
    expect(looksQuotedPrintable('abc=\r\ndef')).toBe(true)
  })

  it('detects common hex escapes case-insensitively', () => {
    expect(looksQuotedPrintable('a=3Db')).toBe(true)
    expect(looksQuotedPrintable('a=3db')).toBe(true)
    expect(looksQuotedPrintable('a=3Cb')).toBe(true)
    expect(looksQuotedPrintable('a=3Eb')).toBe(true)
  })

  it('rejects plain text', () => {
    expect(looksQuotedPrintable('nothing here')).toBe(false)
    expect(looksQuotedPrintable('price = 10')).toBe(false)
  })
})

describe('decodeTransferEncoding', () => {
  it('decodes QP when the header says quoted-printable', () => {
    const headers = [{ name: 'Content-Transfer-Encoding', value: 'quoted-printable' }]
    expect(decodeTransferEncoding('a=3Db', headers)).toBe('a=b')
  })

  it('applies the header-absent heuristic', () => {
    expect(decodeTransferEncoding('a=3Db', undefined)).toBe('a=b')
    expect(decodeTransferEncoding('plain text', undefined)).toBe('plain text')
  })

  it('does not decode when the header names another encoding', () => {
    const headers = [{ name: 'Content-Transfer-Encoding', value: '7bit' }]
    expect(decodeTransferEncoding('a=3Db', headers)).toBe('a=3Db')
  })
})

describe('decodeHtmlEntities', () => {
  it('decodes named entities', () => {
    expect(decodeHtmlEntities('Thank&nbsp;you &amp; goodbye')).toBe('Thank you & goodbye')
    expect(decodeHtmlEntities('&lt;tag&gt;')).toBe('<tag>')
  })

  it('decodes numeric and hex entities', () => {
    expect(decodeHtmlEntities('Price&#160;$100')).toBe('Price $100')
    expect(decodeHtmlEntities('Price&#x00A0;$100')).toBe('Price $100')
    expect(decodeHtmlEntities('&#8217;')).toBe("'")
  })

  it('strips zero-width characters and entities', () => {
    expect(decodeHtmlEntities('a&zwnj;b&#8204;c')).toBe('abc')
    expect(decodeHtmlEntities('a\u200Bb')).toBe('ab')
  })

  it('leaves unknown entities intact', () => {
    expect(decodeHtmlEntities('&unknown; stays')).toBe('&unknown; stays')
  })
})
