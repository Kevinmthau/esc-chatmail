// Ported from esc-chatmailTests/TextProcessing/RFC2047DecoderTests.swift.
import { describe, expect, it } from 'vitest'
import { containsEncodedWord, decodeRfc2047 } from './rfc2047Decoder'

describe('containsEncodedWord', () => {
  it('detects an encoded word', () => {
    expect(containsEncodedWord('=?utf-8?B?Sm9zw6k=?=')).toBe(true)
  })

  it('rejects plain text and a lone opener or closer', () => {
    expect(containsEncodedWord('John Smith')).toBe(false)
    expect(containsEncodedWord('what?= no opener')).toBe(false)
    expect(containsEncodedWord('opener only =?')).toBe(false)
  })
})

describe('decodeRfc2047', () => {
  describe('B encoding', () => {
    it('decodes base64 UTF-8', () => {
      expect(decodeRfc2047('=?utf-8?B?SsO2cmcgTcO8bGxlcg==?=')).toBe('Jörg Müller')
    })

    it('decodes base64 with its padding missing', () => {
      // Some senders strip the trailing "=" padding ("Sm9zw6k=" → "Sm9zw6k").
      // HONEST SCOPE: no web code restores the padding (iOS does by hand);
      // this pins that atob's forgiving-base64 accepts it missing.
      expect(decodeRfc2047('=?utf-8?B?Sm9zw6k?=')).toBe('José')
    })

    it('decodes base64 ISO-8859-1', () => {
      expect(decodeRfc2047('=?iso-8859-1?B?TfxsbGVyIEdtYkg=?=')).toBe('Müller GmbH')
    })

    it('decodes base64 GB2312', () => {
      expect(decodeRfc2047('=?gb2312?B?vqm2qw==?=')).toBe('京东')
    })
  })

  describe('Q encoding', () => {
    it('decodes Q-encoded UTF-8', () => {
      expect(decodeRfc2047('=?utf-8?q?Jos=C3=A9_Garc=C3=ADa?=')).toBe('José García')
    })

    it('reads an underscore as a space', () => {
      expect(decodeRfc2047('=?us-ascii?Q?John_Smith?=')).toBe('John Smith')
    })

    it('passes literal characters through', () => {
      expect(decodeRfc2047('=?utf-8?Q?Costco_Wholesale?=')).toBe('Costco Wholesale')
    })
  })

  describe('multiple words', () => {
    it('drops whitespace between encoded words', () => {
      // RFC 2047 §6.2: linear whitespace between adjacent encoded words is
      // deleted; the encoded content carries any intended spacing.
      // HONEST SCOPE: same-charset words join one byte run, so the space is
      // dropped by the join and by the `previousWasDecodedWord` test alike;
      // neither mutation alone fails this. The next two tests pin each path.
      expect(decodeRfc2047('=?utf-8?B?QWNtZQ==?= =?utf-8?B?Q29ycA==?=')).toBe('AcmeCorp')
    })

    it('drops whitespace between encoded words of different charsets', () => {
      // Revert-check: appending every separator in `decodeRfc2047` (dropping
      // the `previousWasDecodedWord` test) fails this test.
      expect(decodeRfc2047('=?utf-8?B?QWNtZQ==?= =?iso-8859-1?Q?Corp?=')).toBe('AcmeCorp')
    })

    it('decodes a multibyte character split across words', () => {
      // "Émilie" with the two UTF-8 bytes of "É" split across words: bytes
      // must accumulate across the run before charset decoding.
      // Revert-check: never joining the pending run in `decodeRfc2047`
      // (`joinsPendingRun` always false) fails this test.
      expect(decodeRfc2047('=?UTF-8?B?ww==?= =?UTF-8?B?iW1pbGll?=')).toBe('Émilie')
    })

    it('preserves the text around an encoded word', () => {
      expect(decodeRfc2047('Re: =?utf-8?B?Sm9zw6k=?= update')).toBe('Re: José update')
    })

    it('decodes a charset carrying a language tag', () => {
      // RFC 2231 language suffix on the charset ("utf-8*en").
      // Revert-check: dropping the tag strip in `normalizedCharset` fails this
      // test on the GB2312 word: "gb2312*zh" is an unknown label, and the
      // UTF-8 and Latin-1 fallbacks garble it. The UTF-8 word alone passes
      // either way, through the UTF-8 fallback.
      expect(decodeRfc2047('=?utf-8*en?B?Sm9zw6k=?=')).toBe('José')
      expect(decodeRfc2047('=?gb2312*zh?B?vqm2qw==?=')).toBe('京东')
    })
  })

  describe('malformed input stays verbatim', () => {
    it('leaves plain text unchanged', () => {
      expect(decodeRfc2047('John Smith')).toBe('John Smith')
    })

    it.each([
      ['invalid base64', '=?utf-8?B?!!!notbase64!!!?='],
      ['an invalid Q hex escape', '=?utf-8?Q?bad=ZZescape?='],
      ['a truncated Q hex escape', '=?utf-8?Q?bad=A?='],
      ['an unknown encoding letter', '=?utf-8?X?abcdef?='],
    ])('keeps a word with %s verbatim', (_label, garbled) => {
      expect(decodeRfc2047(garbled)).toBe(garbled)
    })

    it('falls back to UTF-8 for an unknown charset', () => {
      // "Sm9zw6k=" is valid UTF-8 ("José") mislabeled with a bogus charset.
      expect(decodeRfc2047('=?x-no-such-charset?B?Sm9zw6k=?=')).toBe('José')
    })

    it('falls back to UTF-8 for 8-bit bytes labeled us-ascii', () => {
      // TextDecoder reads the us-ascii label as windows-1252 and would show
      // "JosÃ©"; iOS decodes it as strict ASCII, which refuses the bytes.
      // Revert-check: dropping the ASCII branch in `decodeWithCharset` fails
      // this test.
      expect(decodeRfc2047('=?us-ascii?Q?Jos=C3=A9?=')).toBe('José')
    })

    it('falls back to Latin-1 for bytes that are not UTF-8', () => {
      // 0xE9 alone is invalid UTF-8; Latin-1 maps every byte.
      expect(decodeRfc2047('=?utf-8?Q?Jos=E9?=')).toBe('José')
    })

    it('keeps the spacing around an undecodable word between valid ones', () => {
      expect(decodeRfc2047('=?utf-8?B?QWNtZQ==?= =?utf-8?X?bad?= tail')).toBe(
        'Acme =?utf-8?X?bad?= tail',
      )
    })

    it('decodes empty encoded text to nothing', () => {
      expect(decodeRfc2047('=?utf-8?B??=')).toBe('')
      expect(decodeRfc2047('=?utf-8?Q??=')).toBe('')
    })
  })

  describe('large input', () => {
    const text = 'a'.repeat(200_000)

    it.each([
      ['Q', text],
      ['B', btoa(text)],
    ])('decodes a single ~200 KB %s-encoded word without throwing', (encoding, encodedText) => {
      // One word's bytes used to be appended with a spread, which throws
      // RangeError past V8's ~120 K call-argument limit; the throw escaped
      // extractDisplayName and failed the whole sync batch.
      // Revert-check: restoring `pendingBytes.push(...wordBytes)` in
      // `decodeRfc2047` fails both cases.
      expect(decodeRfc2047(`=?utf-8?${encoding}?${encodedText}?=`)).toBe(text)
    })
  })
})
