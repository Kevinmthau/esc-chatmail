import { describe, expect, it, vi } from 'vitest'
import {
  buildNew,
  buildReply,
  encodeHeaderIfNeeded,
  encodeRawForSend,
  formatFromHeader,
  formatRfc2822Date,
  InvalidRecipientsError,
  InvalidSenderError,
  isMessageIdToken,
  isSingleAddrSpec,
  MessageTooLargeError,
  NoValidRecipientsError,
  sanitizeHeaderValue,
  sanitizeMimeType,
  toBase64Url,
} from './mimeBuilder'

type UuidString = `${string}-${string}-${string}-${string}-${string}`

const UUID = '00000000-0000-4000-8000-000000000000'
const BOUNDARY = `----Boundary${UUID.replaceAll('-', '')}`
const NOW = new Date(2026, 0, 15, 12, 30, 45)

// Distinct ids so each nesting level's boundary is distinguishable. The
// builder consumes them in call order: Message-ID, then one per container it
// opens (mixed → related → alternative).
const MESSAGE_UUID: UuidString = '00000000-0000-4000-8000-00000000000a'
const MIXED_UUID: UuidString = '00000000-0000-4000-8000-00000000000b'
const RELATED_UUID: UuidString = '00000000-0000-4000-8000-00000000000c'
const ALTERNATIVE_UUID: UuidString = '00000000-0000-4000-8000-00000000000d'

function boundaryFor(uuid: string): string {
  return `----Boundary${uuid.replaceAll('-', '')}`
}

function mockUuid(): void {
  vi.spyOn(crypto, 'randomUUID').mockReturnValue(UUID)
}

/** Hands out the given ids in order, repeating the last one afterwards. */
function mockUuids(...uuids: UuidString[]): void {
  const spy = vi.spyOn(crypto, 'randomUUID')
  for (const uuid of uuids) spy.mockReturnValueOnce(uuid)
  spy.mockReturnValue(uuids[uuids.length - 1] ?? MESSAGE_UUID)
}

function base64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64')
}

function bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text)
}

function utf8Base64(text: string): string {
  return Buffer.from(text, 'utf8').toString('base64')
}

/** The raw (still line-wrapped) body of the part with this exact Content-Type. */
function base64PayloadOfPart(mime: string, contentType: string): string {
  const start = mime.indexOf(`Content-Type: ${contentType}\r\n`)
  if (start < 0) throw new Error(`no part with Content-Type: ${contentType}`)
  const bodyStart = mime.indexOf('\r\n\r\n', start) + 4
  // base64 never contains '-', so '\r\n--' can only be the next boundary.
  return mime.slice(bodyStart, mime.indexOf('\r\n--', bodyStart))
}

function lineLengthsOfPart(mime: string, contentType: string): number[] {
  return base64PayloadOfPart(mime, contentType)
    .split('\r\n')
    .map((line) => line.length)
}

function withoutDateLine(mime: string): string {
  return mime.replace(/^Date: .*\r\n/mu, '')
}

function dateLine(mime: string): string {
  return /^Date: (.*)\r$/mu.exec(mime)?.[1] ?? ''
}

function decodeBase64Url(raw: string): string {
  return Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
}

function rfc2047(text: string): string {
  return `=?UTF-8?B?${Buffer.from(text, 'utf8').toString('base64')}?=`
}

describe('sanitizeHeaderValue', () => {
  it('replaces CR/LF sequences with spaces and trims', () => {
    expect(sanitizeHeaderValue('  a\r\nb\rc\nd  ')).toBe('a b c d')
  })
})

describe('encodeHeaderIfNeeded', () => {
  it('passes ASCII through unchanged', () => {
    expect(encodeHeaderIfNeeded('Plain subject')).toBe('Plain subject')
  })

  it('RFC-2047 encodes non-ASCII as UTF-8 base64', () => {
    expect(encodeHeaderIfNeeded('Zoë Müller')).toBe(rfc2047('Zoë Müller'))
    expect(encodeHeaderIfNeeded('Zoë Müller')).toBe('=?UTF-8?B?Wm/DqyBNw7xsbGVy?=')
  })
})

describe('formatFromHeader', () => {
  it('returns the bare address when no name', () => {
    expect(formatFromHeader('a@b.com')).toBe('a@b.com')
    expect(formatFromHeader('a@b.com', '')).toBe('a@b.com')
  })

  it('quotes names containing specials, escaping quotes', () => {
    expect(formatFromHeader('a@b.com', 'Doe, John')).toBe('"Doe, John" <a@b.com>')
    expect(formatFromHeader('a@b.com', 'The "Boss"')).toBe('"The \\"Boss\\"" <a@b.com>')
  })

  it('escapes backslashes before quotes so a name cannot terminate the quoted-string early', () => {
    // Name `Acme\"`: the backslash must become `\\` and the quote `\"` —
    // without backslash escaping the emitted `\\"` ends the quoted-string
    // early, letting the rest of the name be parsed as an addr-spec.
    expect(formatFromHeader('a@b.com', String.raw`Acme\"`)).toBe(String.raw`"Acme\\\"" <a@b.com>`)
    expect(formatFromHeader('me@acme.com', String.raw`Acme\" <spoof@evil.tld> \"`)).toBe(
      String.raw`"Acme\\\" <spoof@evil.tld> \\\"" <me@acme.com>`,
    )
  })

  it('quotes a name whose only special is a backslash (never emits it bare)', () => {
    // A trailing lone backslash previously took the unquoted branch, emitting
    // `Acme\ <a@b.com>` (invalid phrase / escapes nothing meaningful).
    expect(formatFromHeader('a@b.com', 'Acme\\')).toBe('"Acme\\\\" <a@b.com>')
  })

  it('RFC-2047 encodes non-ASCII names', () => {
    expect(formatFromHeader('a@b.com', 'Zoë Müller')).toBe(`${rfc2047('Zoë Müller')} <a@b.com>`)
  })
})

describe('formatRfc2822Date', () => {
  it('produces the en-US RFC-2822 shape', () => {
    const formatted = formatRfc2822Date(NOW)
    expect(formatted).toMatch(
      /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$/u,
    )
    expect(formatted).toContain('15 Jan 2026')
    expect(formatted).toContain('12:30:45')
  })
})

describe('buildNew', () => {
  it('builds the plain-text golden message', () => {
    mockUuid()
    const mime = buildNew(
      {
        from: { email: 'alice@example.com' },
        to: ['bob@example.com', 'carol@example.com'],
        subject: 'Hello',
        textBody: 'Hi there',
      },
      { now: NOW },
    )

    expect(withoutDateLine(mime)).toBe(
      'From: alice@example.com\r\n' +
        'To: bob@example.com, carol@example.com\r\n' +
        'Subject: Hello\r\n' +
        `Message-ID: <${UUID}@inbox-chat.web>\r\n` +
        'MIME-Version: 1.0\r\n' +
        'Content-Type: text/plain; charset=UTF-8\r\n' +
        'Content-Transfer-Encoding: 8bit\r\n' +
        '\r\n' +
        'Hi there\r\n',
    )
    expect(dateLine(mime)).toBe(formatRfc2822Date(NOW))
  })

  it('falls back to (No Subject) and encodes non-ASCII names/subjects', () => {
    mockUuid()
    const noSubject = buildNew(
      { from: { email: 'a@b.com' }, to: ['x@y.com'], textBody: 'b' },
      { now: NOW },
    )
    expect(noSubject).toContain('Subject: (No Subject)\r\n')

    const encoded = buildNew(
      {
        from: { email: 'a@b.com', name: 'Zoë Müller' },
        to: ['x@y.com'],
        subject: 'Grüße',
        textBody: 'b',
      },
      { now: NOW },
    )
    expect(encoded).toContain(`From: ${rfc2047('Zoë Müller')} <a@b.com>\r\n`)
    expect(encoded).toContain(`Subject: ${rfc2047('Grüße')}\r\n`)
  })

  it('strips CRLF from every header value (header-injection defense)', () => {
    mockUuid()
    const mime = buildNew(
      {
        from: { email: 'a@b.com', name: 'Evil\r\nX-Name: injected' },
        subject: 'Hi\r\nBcc: victim@example.com',
        to: ['ok@y.com'],
        textBody: 'b',
      },
      { now: NOW },
    )
    expect(mime).not.toMatch(/^Bcc:/mu)
    expect(mime).not.toMatch(/^X-Name:/mu)
    expect(mime).toContain('To: ok@y.com\r\n')
    expect(mime).toContain('Subject: Hi Bcc: victim@example.com\r\n')
  })

  it('refuses a CRLF-injected recipient instead of emitting it', () => {
    mockUuid()
    expect(() =>
      buildNew(
        {
          from: { email: 'a@b.com' },
          to: ['x@y.com\r\nX-To: injected', 'ok@y.com'],
          textBody: 'b',
        },
        { now: NOW },
      ),
    ).toThrow(InvalidRecipientsError)
  })

  // Regression: a rejected recipient must FAIL the send naming the offender.
  // Dropping it and sending to the survivors delivered a group message to
  // fewer people than the conversation header shows, with no signal anywhere.
  it('refuses the whole send when one recipient is a smuggled comma address, naming it', () => {
    mockUuid()
    let thrown: unknown
    try {
      buildNew(
        {
          from: { email: 'me@example.com' },
          to: ['billing@acme.com, harvest@evil.tld', 'ok@example.com'],
          textBody: 'b',
        },
        { now: NOW },
      )
    } catch (error) {
      thrown = error
    }
    expect(thrown).toBeInstanceOf(InvalidRecipientsError)
    expect((thrown as InvalidRecipientsError).addresses).toEqual([
      'billing@acme.com, harvest@evil.tld',
    ])
  })

  it('refuses the whole send when one recipient is an angle-bracket name-addr', () => {
    mockUuid()
    let thrown: unknown
    try {
      buildNew(
        {
          from: { email: 'me@example.com' },
          to: ['Bob <bob@evil.tld>', 'ok@example.com'],
          textBody: 'b',
        },
        { now: NOW },
      )
    } catch (error) {
      thrown = error
    }
    expect(thrown).toBeInstanceOf(InvalidRecipientsError)
    expect((thrown as InvalidRecipientsError).addresses).toEqual(['Bob <bob@evil.tld>'])
  })

  it('throws NoValidRecipientsError when the recipient list carries no address', () => {
    mockUuid()
    expect(() =>
      buildNew({ from: { email: 'me@example.com' }, to: ['   '], textBody: 'b' }, { now: NOW }),
    ).toThrow(NoValidRecipientsError)
  })

  it('throws InvalidSenderError when the From address is not a single addr-spec', () => {
    mockUuid()
    expect(() =>
      buildNew(
        {
          from: { email: 'me@example.com, evil@evil.tld' },
          to: ['ok@example.com'],
          textBody: 'b',
        },
        { now: NOW },
      ),
    ).toThrow(InvalidSenderError)
  })

  it('passes ordinary addresses through, including gmail dot/plus forms', () => {
    mockUuid()
    const mime = buildNew(
      {
        from: { email: 'me@example.com' },
        to: ['first.last@gmail.com', 'user+tag@gmail.com', 'x-y_z@sub.example.co.uk'],
        textBody: 'b',
      },
      { now: NOW },
    )
    expect(mime).toContain(
      'To: first.last@gmail.com, user+tag@gmail.com, x-y_z@sub.example.co.uk\r\n',
    )
  })

  it('builds multipart/alternative with 76-char base64 parts that roundtrip', () => {
    mockUuid()
    const textBody = 'plain '.repeat(60)
    const htmlBody = `<p>${'é'.repeat(150)}</p>`
    const mime = buildNew(
      { from: { email: 'a@b.com' }, to: ['x@y.com'], subject: 'S', textBody, htmlBody },
      { now: NOW },
    )

    expect(mime).toContain(`Content-Type: multipart/alternative; boundary="${BOUNDARY}"\r\n`)
    expect(mime.endsWith(`--${BOUNDARY}--\r\n`)).toBe(true)

    const sections = [
      ...mime.matchAll(/Content-Transfer-Encoding: base64\r\n\r\n([A-Za-z0-9+/=\r\n]+?)\r\n--/gu),
    ].map((m) => m[1] ?? '')
    expect(sections).toHaveLength(2)

    for (const section of sections) {
      for (const line of section.split('\r\n')) {
        expect(line.length).toBeLessThanOrEqual(76)
        expect(line.length).toBeGreaterThan(0)
      }
    }
    const [textPart, htmlPart] = sections
    expect(Buffer.from((textPart ?? '').replaceAll('\r\n', ''), 'base64').toString('utf8')).toBe(
      textBody,
    )
    expect(Buffer.from((htmlPart ?? '').replaceAll('\r\n', ''), 'base64').toString('utf8')).toBe(
      htmlBody,
    )
  })
})

describe('buildNew with attachments', () => {
  const PDF = bytes('%PDF-1.4 fake report bytes')
  const PNG = bytes('\x89PNG fake logo bytes')

  it('builds the multipart/mixed golden message for one attachment', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mixed = boundaryFor(MIXED_UUID)

    const mime = buildNew(
      {
        from: { email: 'alice@example.com' },
        to: ['bob@example.com'],
        subject: 'Hello',
        textBody: 'Hi there',
        attachments: [{ data: PDF, filename: 'report.pdf', mimeType: 'application/pdf' }],
      },
      { now: NOW },
    )

    expect(withoutDateLine(mime)).toBe(
      'From: alice@example.com\r\n' +
        'To: bob@example.com\r\n' +
        'Subject: Hello\r\n' +
        `Message-ID: <${MESSAGE_UUID}@inbox-chat.web>\r\n` +
        'MIME-Version: 1.0\r\n' +
        `Content-Type: multipart/mixed; boundary="${mixed}"\r\n` +
        '\r\n' +
        `--${mixed}\r\n` +
        'Content-Type: text/plain; charset=UTF-8\r\n' +
        'Content-Transfer-Encoding: 8bit\r\n' +
        '\r\n' +
        'Hi there\r\n' +
        `--${mixed}\r\n` +
        'Content-Type: application/pdf; name="report.pdf"\r\n' +
        'Content-Transfer-Encoding: base64\r\n' +
        'Content-Disposition: attachment; filename="report.pdf"\r\n' +
        '\r\n' +
        `${base64(PDF)}\r\n` +
        `--${mixed}--\r\n`,
    )
  })

  it('builds the mixed → related → alternative golden message for an inline image + attachment', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID, RELATED_UUID, ALTERNATIVE_UUID)
    const mixed = boundaryFor(MIXED_UUID)
    const related = boundaryFor(RELATED_UUID)
    const alternative = boundaryFor(ALTERNATIVE_UUID)
    const textBody = 'See the logo.'
    const htmlBody = '<p>See the <img src="cid:logo@inbox-chat.web"></p>'

    const mime = buildNew(
      {
        from: { email: 'alice@example.com' },
        to: ['bob@example.com'],
        subject: 'Hello',
        textBody,
        htmlBody,
        attachments: [{ data: PDF, filename: 'report.pdf', mimeType: 'application/pdf' }],
        inlineAttachments: [
          {
            data: PNG,
            filename: 'logo.png',
            mimeType: 'image/png',
            contentId: 'logo@inbox-chat.web',
          },
        ],
      },
      { now: NOW },
    )

    expect(withoutDateLine(mime)).toBe(
      'From: alice@example.com\r\n' +
        'To: bob@example.com\r\n' +
        'Subject: Hello\r\n' +
        `Message-ID: <${MESSAGE_UUID}@inbox-chat.web>\r\n` +
        'MIME-Version: 1.0\r\n' +
        `Content-Type: multipart/mixed; boundary="${mixed}"\r\n` +
        '\r\n' +
        `--${mixed}\r\n` +
        `Content-Type: multipart/related; boundary="${related}"\r\n` +
        '\r\n' +
        `--${related}\r\n` +
        `Content-Type: multipart/alternative; boundary="${alternative}"\r\n` +
        '\r\n' +
        `--${alternative}\r\n` +
        'Content-Type: text/plain; charset=UTF-8\r\n' +
        'Content-Transfer-Encoding: base64\r\n' +
        '\r\n' +
        `${utf8Base64(textBody)}\r\n` +
        `--${alternative}\r\n` +
        'Content-Type: text/html; charset=UTF-8\r\n' +
        'Content-Transfer-Encoding: base64\r\n' +
        '\r\n' +
        `${utf8Base64(htmlBody)}\r\n` +
        `--${alternative}--\r\n` +
        `--${related}\r\n` +
        'Content-Type: image/png; name="logo.png"\r\n' +
        'Content-Transfer-Encoding: base64\r\n' +
        'Content-ID: <logo@inbox-chat.web>\r\n' +
        'Content-Disposition: inline; filename="logo.png"\r\n' +
        '\r\n' +
        `${base64(PNG)}\r\n` +
        `--${related}--\r\n` +
        `--${mixed}\r\n` +
        'Content-Type: application/pdf; name="report.pdf"\r\n' +
        'Content-Transfer-Encoding: base64\r\n' +
        'Content-Disposition: attachment; filename="report.pdf"\r\n' +
        '\r\n' +
        `${base64(PDF)}\r\n` +
        `--${mixed}--\r\n`,
    )
  })

  it('omits the multipart/related wrapper when there are no inline parts', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID, ALTERNATIVE_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'text',
        htmlBody: '<p>html</p>',
        attachments: [{ data: PDF, filename: 'report.pdf', mimeType: 'application/pdf' }],
      },
      { now: NOW },
    )

    expect(mime).not.toContain('multipart/related')
    expect(mime).toContain(`Content-Type: multipart/mixed; boundary="${boundaryFor(MIXED_UUID)}"`)
    // The alternative opens directly inside the mixed container.
    expect(mime).toContain(
      `--${boundaryFor(MIXED_UUID)}\r\nContent-Type: multipart/alternative; boundary="${boundaryFor(ALTERNATIVE_UUID)}"\r\n`,
    )
  })

  it('wraps attachment base64 at 64 characters and body base64 at 76', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID, ALTERNATIVE_UUID)
    // 600 bytes → 800 base64 characters: many full lines at either width.
    const big = new Uint8Array(600).map((_, i) => (i * 7) % 256)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'plain '.repeat(80),
        htmlBody: `<p>${'x'.repeat(400)}</p>`,
        attachments: [{ data: big, filename: 'blob.bin', mimeType: 'application/octet-stream' }],
      },
      { now: NOW },
    )

    const bodyLines = lineLengthsOfPart(mime, 'text/plain; charset=UTF-8')
    expect(Math.max(...bodyLines)).toBe(76)
    const attachmentLines = lineLengthsOfPart(mime, 'application/octet-stream; name="blob.bin"')
    expect(Math.max(...attachmentLines)).toBe(64)
    // Round-trip: the wrapped payload decodes back to the original bytes.
    const encoded = base64PayloadOfPart(mime, 'application/octet-stream; name="blob.bin"')
    expect([...Buffer.from(encoded.replaceAll('\r\n', ''), 'base64')]).toEqual([...big])
  })

  it('escapes quotes and backslashes in filenames so a name cannot restructure the header', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'b',
        attachments: [
          {
            data: bytes('x'),
            // A raw interpolation would close the parameter and let the rest
            // be parsed as header syntax.
            filename: String.raw`evil".pdf`,
            mimeType: 'application/pdf',
          },
        ],
      },
      { now: NOW },
    )

    expect(mime).toContain(String.raw`Content-Type: application/pdf; name="evil\".pdf"`)
    expect(mime).toContain(String.raw`Content-Disposition: attachment; filename="evil\".pdf"`)
  })

  it('keeps a non-ASCII filename as raw UTF-8 in the quoted parameters (documented choice)', () => {
    // Strictly RFC 2045 headers are ASCII (RFC 2231 filename*= is the
    // conformant spelling), but iOS interpolates raw UTF-8, Gmail's API
    // accepts it and echoes the same name back on sync — which keeps
    // matchLocalAttachment's filename fingerprint stable. Pinned so a switch
    // to RFC 2231 has to be its own deliberate change, on both platforms.
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'photo',
        attachments: [{ data: bytes('x'), filename: 'Fotoğraf ✓.jpg', mimeType: 'image/jpeg' }],
      },
      { now: NOW },
    )

    expect(mime).toContain('Content-Type: image/jpeg; name="Fotoğraf ✓.jpg"')
    expect(mime).toContain('Content-Disposition: attachment; filename="Fotoğraf ✓.jpg"')
  })

  it('strips CRLF from attachment metadata (header-injection defense)', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'b',
        attachments: [
          {
            data: bytes('x'),
            filename: 'ok.pdf\r\nBcc: victim@example.com',
            mimeType: 'application/pdf',
          },
        ],
      },
      { now: NOW },
    )

    expect(mime).not.toMatch(/^Bcc:/mu)
    expect(mime).toContain('name="ok.pdf Bcc: victim@example.com"')
  })

  it('falls back to application/octet-stream for a media type carrying parameters', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'b',
        attachments: [
          {
            data: bytes('x'),
            filename: 'x.png',
            // A crafted type could otherwise add a boundary parameter and
            // restructure the part.
            mimeType: `image/png; boundary="${boundaryFor(MIXED_UUID)}"`,
          },
        ],
      },
      { now: NOW },
    )

    expect(mime).toContain('Content-Type: application/octet-stream; name="x.png"')
  })

  it('emits inline parts into the mixed container when there is no html body', () => {
    // iOS's plain-text builder drops inline parts entirely; they are kept here.
    mockUuids(MESSAGE_UUID, MIXED_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'b',
        inlineAttachments: [
          { data: PNG, filename: 'logo.png', mimeType: 'image/png', contentId: 'logo@x' },
        ],
      },
      { now: NOW },
    )

    expect(mime).toContain('Content-ID: <logo@x>\r\n')
    expect(mime).toContain('Content-Disposition: inline; filename="logo.png"\r\n')
    expect(mime).toContain(base64(PNG))
  })

  it('strips angle brackets a Content-ID brings along instead of nesting them', () => {
    mockUuids(MESSAGE_UUID, MIXED_UUID, RELATED_UUID, ALTERNATIVE_UUID)
    const mime = buildNew(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 't',
        htmlBody: '<p>h</p>',
        inlineAttachments: [
          { data: PNG, filename: 'logo.png', mimeType: 'image/png', contentId: '<logo@x>' },
        ],
      },
      { now: NOW },
    )

    expect(mime).toContain('Content-ID: <logo@x>\r\n')
    expect(mime).not.toContain('<<')
  })
})

describe('sanitizeMimeType', () => {
  it('keeps well-formed types and rejects everything else', () => {
    expect(sanitizeMimeType('image/PNG')).toBe('image/png')
    expect(sanitizeMimeType('application/vnd.ms-excel')).toBe('application/vnd.ms-excel')
    for (const bad of ['', 'image', '/png', 'image/', 'image/png; charset=x', 'a b/c']) {
      expect(sanitizeMimeType(bad), bad).toBe('application/octet-stream')
    }
  })
})

describe('encodeRawForSend', () => {
  it('returns the base64url payload when it fits', () => {
    expect(encodeRawForSend('Subject: hi\r\n\r\nbody\r\n')).toBe(
      toBase64Url('Subject: hi\r\n\r\nbody\r\n'),
    )
  })

  it('refuses a payload past the endpoint ceiling, naming both sizes', () => {
    // 100 ASCII characters → 136 base64url characters, over a 100-byte limit.
    let thrown: unknown
    try {
      encodeRawForSend('x'.repeat(100), 100)
    } catch (error) {
      thrown = error
    }
    expect(thrown).toBeInstanceOf(MessageTooLargeError)
    expect((thrown as MessageTooLargeError).limitBytes).toBe(100)
    expect((thrown as MessageTooLargeError).rawBytes).toBeGreaterThan(100)
  })
})

describe('buildReply', () => {
  it('adds In-Reply-To and space-joined References after Message-ID', () => {
    mockUuid()
    const mime = buildReply(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        subject: 'Re: Hello',
        textBody: 'reply',
        inReplyTo: '<orig@mail.example.com>',
        references: ['<r1@mail.example.com>', '<r2@mail.example.com>'],
      },
      { now: NOW },
    )
    expect(mime).toContain('In-Reply-To: <orig@mail.example.com>\r\n')
    expect(mime).toContain('References: <r1@mail.example.com> <r2@mail.example.com>\r\n')
    const messageIdIndex = mime.indexOf('Message-ID:')
    const inReplyToIndex = mime.indexOf('In-Reply-To:')
    const mimeVersionIndex = mime.indexOf('MIME-Version:')
    expect(messageIdIndex).toBeLessThan(inReplyToIndex)
    expect(inReplyToIndex).toBeLessThan(mimeVersionIndex)
  })

  it('omits empty threading headers', () => {
    mockUuid()
    const mime = buildReply(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'reply',
        inReplyTo: '',
        references: [],
      },
      { now: NOW },
    )
    expect(mime).not.toContain('In-Reply-To:')
    expect(mime).not.toContain('References:')
  })

  it('drops threading values that are not well-formed <message-id> tokens', () => {
    mockUuid()
    const mime = buildReply(
      {
        from: { email: 'a@b.com' },
        to: ['x@y.com'],
        textBody: 'reply',
        inReplyTo: 'orig@mail.example.com, extra-garbage',
        references: ['<ok@x.com>', 'bare-id@x.com', '<sp aced@x.com>', '<nested<id>@x.com>'],
      },
      { now: NOW },
    )
    expect(mime).not.toContain('In-Reply-To:')
    expect(mime).toContain('References: <ok@x.com>\r\n')
    expect(mime).not.toContain('bare-id')
    expect(mime).not.toContain('sp aced')
    expect(mime).not.toContain('nested')
  })
})

describe('isSingleAddrSpec', () => {
  it('accepts conservative single addr-specs', () => {
    for (const address of [
      'a@b.com',
      'first.last@gmail.com',
      'user+tag@gmail.com',
      'x-y_z@sub.example.co.uk',
      "o'brien@example.ie",
    ]) {
      expect(isSingleAddrSpec(address), address).toBe(true)
    }
  })

  it('rejects smuggling shapes and malformed addresses', () => {
    for (const address of [
      '',
      'billing@acme.com, harvest@evil.tld',
      'a@b.com; c@d.com',
      'Bob <bob@evil.tld>',
      'a b@c.com',
      '"quoted local"@c.com',
      'a@b@c.com',
      'no-at-sign',
      '@b.com',
      'a@',
      'a@.b.com',
      'a@b.com.',
      'a@b..com',
      'a\\@b.com',
      'a@b.com\x00',
    ]) {
      expect(isSingleAddrSpec(address), address).toBe(false)
    }
  })
})

describe('isMessageIdToken', () => {
  it('accepts a single angle-bracketed token and rejects everything else', () => {
    expect(isMessageIdToken('<id@mail.example.com>')).toBe(true)
    expect(isMessageIdToken('id@mail.example.com')).toBe(false)
    expect(isMessageIdToken('<a@x> <b@x>')).toBe(false)
    expect(isMessageIdToken('<sp aced@x>')).toBe(false)
    expect(isMessageIdToken('<nested<id>@x>')).toBe(false)
    expect(isMessageIdToken('')).toBe(false)
  })
})

describe('toBase64Url', () => {
  it('is unicode-safe and url-safe', () => {
    const mime = 'Subject: Grüße 🎉\r\n\r\nBody é\r\n'
    const encoded = toBase64Url(mime)
    expect(encoded).not.toMatch(/[+/=]/u)
    expect(decodeBase64Url(encoded)).toBe(mime)
  })
})
