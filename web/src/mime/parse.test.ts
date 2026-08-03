import { describe, expect, it, vi } from 'vitest'
import { GmailApiError, NetworkError } from '../gmail/errors'
import type { GmailMessage, GmailPart } from '../gmail/types'
import { extractAttachments } from './attachments'
import { LargeBodyFetchError, parseGmailMessage } from './parse'

function b64url(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function message(payload: GmailPart, overrides: Partial<GmailMessage> = {}): GmailMessage {
  return {
    id: 'msg-1',
    threadId: 'thread-1',
    internalDate: '1753000000000',
    labelIds: ['INBOX', 'UNREAD'],
    snippet: 'snippet text',
    payload,
    ...overrides,
  }
}

const baseHeaders = [
  { name: 'Subject', value: 'Hello there' },
  { name: 'From', value: 'Jane Doe <Jane.Doe@Example.com>' },
  { name: 'To', value: 'Kevin Thau <kmthau@gmail.com>, other@example.com' },
  { name: 'Cc', value: '"Smith, Bob" <bob@example.com>' },
  { name: 'Reply-To', value: 'reply@example.com' },
  { name: 'In-Reply-To', value: '<prev@id>' },
  { name: 'References', value: '<a@id> <b@id>' },
  { name: 'Message-ID', value: '<msg@id>' },
  { name: 'List-Id', value: '<list.example.com>' },
  { name: 'List-Unsubscribe', value: '<mailto:unsub@example.com>' },
  { name: 'Precedence', value: 'bulk' },
]

describe('parseGmailMessage headers', () => {
  it('parses addresses, references, and list headers', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/plain',
        headers: baseHeaders,
        body: { data: b64url('Hi!') },
      }),
    )

    expect(parsed).not.toBeNull()
    const headers = parsed!.headers
    expect(headers.subject).toBe('Hello there')
    expect(headers.from).toEqual({ email: 'jane.doe@example.com', name: 'Jane Doe' })
    expect(headers.fromRaw).toBe('Jane Doe <Jane.Doe@Example.com>')
    expect(headers.to).toEqual([
      { email: 'kmthau@gmail.com', name: 'Kevin Thau' },
      { email: 'other@example.com', name: null },
    ])
    expect(headers.cc).toEqual([{ email: 'bob@example.com', name: 'Smith, Bob' }])
    expect(headers.replyTo).toBe('reply@example.com')
    expect(headers.inReplyTo).toBe('<prev@id>')
    expect(headers.references).toEqual(['<a@id>', '<b@id>'])
    expect(headers.messageIdHeader).toBe('<msg@id>')
    expect(headers.listId).toBe('<list.example.com>')
    expect(headers.listUnsubscribe).toBe('<mailto:unsub@example.com>')
    expect(headers.precedence).toBe('bulk')
    expect(parsed!.internalDate).toBe(1753000000000)
  })

  it('returns null without payload headers', async () => {
    expect(await parseGmailMessage({ id: 'x', threadId: 'y' })).toBeNull()
  })
})

describe('parseGmailMessage content extraction', () => {
  it('walks nested multipart and fills both html and plain slots', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/mixed',
        headers: baseHeaders,
        parts: [
          {
            partId: '0',
            mimeType: 'multipart/alternative',
            parts: [
              { partId: '0.0', mimeType: 'text/plain', body: { data: b64url('Plain body') } },
              {
                partId: '0.1',
                mimeType: 'text/html',
                body: { data: b64url('<div>HTML body</div>') },
              },
            ],
          },
          {
            partId: '1',
            mimeType: 'application/pdf',
            filename: 'file.pdf',
            body: { attachmentId: 'att-1', size: 1234 },
          },
        ],
      }),
    )

    expect(parsed!.html).toBe('<div>HTML body</div>')
    expect(parsed!.plainText).toBe('Plain body')
    expect(parsed!.hasAttachments).toBe(true)
    expect(parsed!.attachments).toHaveLength(1)
    expect(parsed!.attachments[0]!.id).toBe('att-1')
  })

  it('keeps an inline Content-ID HTML root as body content, not an attachment', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/related',
        headers: baseHeaders,
        parts: [
          {
            partId: '0',
            mimeType: 'text/html',
            headers: [
              { name: 'Content-Disposition', value: 'inline' },
              { name: 'Content-ID', value: '<root-html@x>' },
            ],
            body: { data: b64url('<p>Related root</p>') },
          },
        ],
      }),
    )

    expect(parsed!.html).toBe('<p>Related root</p>')
    expect(parsed!.attachments).toEqual([])
    expect(parsed!.hasAttachments).toBe(false)
  })

  it('skips attachment parts as body content (filename and disposition)', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/mixed',
        headers: baseHeaders,
        parts: [
          {
            partId: '0',
            mimeType: 'text/plain',
            filename: 'notes.txt',
            body: { data: b64url('ATTACHED TEXT') },
          },
          {
            partId: '1',
            mimeType: 'text/html',
            headers: [{ name: 'Content-Disposition', value: 'attachment; filename="a.html"' }],
            body: { data: b64url('<p>ATTACHED HTML</p>') },
          },
          { partId: '2', mimeType: 'text/plain', body: { data: b64url('Real body') } },
        ],
      }),
    )

    expect(parsed!.plainText).toBe('Real body')
    expect(parsed!.html).toBeNull()
  })

  it('fetches large bodies through the injected fetchLargeBody', async () => {
    const fetchLargeBody = vi.fn((_messageId: string, attachmentId: string) => {
      expect(attachmentId).toBe('body-att-9')
      return Promise.resolve(b64url('<div>Large HTML</div>'))
    })

    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/alternative',
        headers: baseHeaders,
        parts: [
          { partId: '0', mimeType: 'text/plain', body: { data: b64url('small plain') } },
          { partId: '1', mimeType: 'text/html', body: { attachmentId: 'body-att-9', size: 90000 } },
        ],
      }),
      { fetchLargeBody },
    )

    expect(fetchLargeBody).toHaveBeenCalledWith('msg-1', 'body-att-9')
    expect(parsed!.html).toBe('<div>Large HTML</div>')
    expect(parsed!.plainText).toBe('small plain')
    // attachmentId is Gmail's indirection for this body, not an attachment.
    expect(parsed!.attachments).toEqual([])
    expect(parsed!.hasAttachments).toBe(false)
  })

  it('surfaces transient large-body failures without producing an incomplete message', async () => {
    const fetchLargeBody = vi.fn(() => Promise.reject(new NetworkError('offline')))

    const result = parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/html',
        headers: baseHeaders,
        body: { attachmentId: 'body-att-9', size: 90_000 },
      }),
      { fetchLargeBody },
    )

    await expect(result).rejects.toMatchObject({
      name: 'LargeBodyFetchError',
      messageId: 'msg-1',
      attachmentId: 'body-att-9',
    } satisfies Partial<LargeBodyFetchError>)
  })

  it('treats a missing large-body part as a deterministic empty body', async () => {
    const fetchLargeBody = vi.fn(() => Promise.reject(new GmailApiError(404, 'notFound', 'gone')))
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/html',
        headers: baseHeaders,
        body: { attachmentId: 'gone-body', size: 90_000 },
      }),
      { fetchLargeBody },
    )

    expect(parsed!.html).toBeNull()
    expect(parsed!.attachments).toEqual([])
  })

  it('never downloads binary attachments for the embedded-HTML rescue', async () => {
    // No text/html part anywhere, so the rescue path runs. It must not treat a
    // 30MB PDF as a candidate body: that means an attachments.get, a ~40MB
    // base64 buffer, a full decode and a regex scan over 30M chars, per
    // attachment, per message, for something that can never be HTML.
    const fetchLargeBody = vi.fn(() => Promise.resolve(b64url('%PDF-1.7 binary junk')))

    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/mixed',
        headers: baseHeaders,
        parts: [
          { partId: '0', mimeType: 'text/plain', body: { data: b64url('Just a note.') } },
          {
            partId: '1',
            mimeType: 'application/pdf',
            filename: 'scan.pdf',
            body: { attachmentId: 'att-pdf', size: 30_000_000 },
          },
          // Textual, so the MIME-type gate alone would let it through — but an
          // attached transcript is not a body slot either.
          {
            partId: '2',
            mimeType: 'text/plain',
            filename: 'transcript.txt',
            body: { attachmentId: 'att-txt', size: 12_000_000 },
          },
          // Same, marked by Content-Disposition rather than filename.
          {
            partId: '3',
            mimeType: 'message/rfc822',
            headers: [{ name: 'Content-Disposition', value: 'attachment; filename="fwd.eml"' }],
            body: { attachmentId: 'att-eml', size: 8_000_000 },
          },
        ],
      }),
      { fetchLargeBody },
    )

    expect(fetchLargeBody).not.toHaveBeenCalled()
    expect(parsed!.html).toBeNull()
    expect(parsed!.plainText).toBe('Just a note.')
  })

  it('rescues embedded HTML from a large TEXT part without touching a sibling binary part', async () => {
    // The rescue still has to follow the large-body indirection for textual
    // parts — it just must not do so for non-textual ones, even when they carry
    // no filename or Content-Disposition to mark them as attachments.
    const rawSource = [
      'Delivered-To: person@example.com',
      'Received: by 2002:a05 with SMTP id x;',
      'Return-Path: <sender@example.com>',
      'MIME-Version: 1.0',
      'Content-Type: multipart/alternative; boundary="b42"',
      '',
      '--b42',
      'Content-Type: text/html; charset="utf-8"',
      '',
      '<html><body><div>RESCUED_TOKEN</div></body></html>',
      '',
      '--b42--',
    ].join('\n')
    const fetchLargeBody = vi.fn((_messageId: string, attachmentId: string) => {
      if (attachmentId === 'att-text') return Promise.resolve(b64url(rawSource))
      return Promise.resolve(b64url('binary'))
    })

    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/mixed',
        headers: baseHeaders,
        parts: [
          {
            partId: '0',
            mimeType: 'application/octet-stream',
            body: { attachmentId: 'att-bin', size: 25_000_000 },
          },
          { partId: '1', mimeType: 'text/plain', body: { attachmentId: 'att-text', size: 90_000 } },
        ],
      }),
      { fetchLargeBody },
    )

    const fetchedIds = fetchLargeBody.mock.calls.map((call) => call[1])
    expect(fetchedIds).toEqual(['att-text'])
    expect(parsed!.html).toContain('RESCUED_TOKEN')
  })

  it('decodes quoted-printable bodies (header and heuristic)', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'multipart/alternative',
        headers: baseHeaders,
        parts: [
          {
            partId: '0',
            mimeType: 'text/plain',
            headers: [{ name: 'Content-Transfer-Encoding', value: 'quoted-printable' }],
            body: { data: b64url('you=27ll see soft=\nwrap') },
          },
          {
            partId: '1',
            mimeType: 'text/html',
            // No transfer-encoding header: the =3D/=3C heuristic must kick in.
            body: { data: b64url('=3Cdiv=3Ea=3Db=3C/div=3E') },
          },
        ],
      }),
    )

    expect(parsed!.plainText).toBe("you'll see softwrap")
    expect(parsed!.html).toBe('<div>a=b</div>')
  })

  it('rescues embedded HTML from raw-source textual bodies when no html part exists', async () => {
    const rawSource = [
      'Delivered-To: person@example.com',
      'Received: by 2002:a05 with SMTP id x;',
      '        Tue, 7 Apr 2026 12:33:01 -0700 (PDT)',
      'X-Received: by 2002:ac8 with SMTP id y;',
      'Return-Path: <sender@example.com>',
      'MIME-Version: 1.0',
      'Content-Type: multipart/alternative; boundary="b123456789"',
      '',
      '--b123456789',
      'Content-Type: text/plain; charset="utf-8"',
      '',
      'Plain fallback',
      '',
      '--b123456789',
      'Content-Type: text/html; charset="utf-8"',
      '',
      '<html><body><div>EMBEDDED_HTML_TOKEN</div></body></html>',
      '',
      '--b123456789--',
    ].join('\n')

    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/plain',
        headers: baseHeaders,
        body: { data: b64url(rawSource) },
      }),
    )

    expect(parsed!.html).toContain('EMBEDDED_HTML_TOKEN')
  })

  it('falls back to plain text extracted from HTML when no plain part exists', async () => {
    const parsed = await parseGmailMessage(
      message({
        partId: '',
        mimeType: 'text/html',
        headers: baseHeaders,
        body: { data: b64url('<div>Only html</div>') },
      }),
    )

    expect(parsed!.html).toBe('<div>Only html</div>')
    expect(parsed!.plainText).toBe('Only html')
  })
})

describe('extractAttachments', () => {
  it('dedupes by attachmentId and skips multipart containers', () => {
    const part: GmailPart = {
      partId: '',
      mimeType: 'multipart/mixed',
      body: { attachmentId: 'container-should-be-skipped' },
      parts: [
        {
          partId: '1',
          mimeType: 'application/pdf',
          filename: 'a.pdf',
          body: { attachmentId: 'dup', size: 10 },
        },
        {
          partId: '2',
          mimeType: 'application/pdf',
          filename: 'a.pdf',
          body: { attachmentId: 'dup', size: 10 },
        },
      ],
    }

    const attachments = extractAttachments(part)
    expect(attachments).toHaveLength(1)
    expect(attachments[0]!.id).toBe('dup')
    expect(attachments[0]!.filename).toBe('a.pdf')
  })

  it('creates deterministic local ids for inline CID images and strips <> from Content-ID', () => {
    const inlinePart: GmailPart = {
      partId: '0.1',
      mimeType: 'image/png',
      filename: '',
      headers: [{ name: 'Content-ID', value: '<image001.png@01DC.1234>' }],
      body: { data: b64url('PNGDATA'), size: 7 },
    }
    const tree: GmailPart = {
      partId: '',
      mimeType: 'multipart/related',
      parts: [inlinePart, inlinePart],
    }

    const attachments = extractAttachments(tree)
    expect(attachments).toHaveLength(1)
    const attachment = attachments[0]!
    expect(attachment.id).toMatch(/^local_inline_[0-9a-f]{16}$/)
    expect(attachment.contentId).toBe('image001.png@01DC.1234')
    expect(attachment.filename).toBe('attachment.png')
    expect(attachment.size).toBe(7)
    expect(attachment.inlineData).not.toBeNull()

    // Deterministic across runs.
    expect(extractAttachments(tree)[0]!.id).toBe(attachment.id)
  })

  it('keeps server-backed CID images while ignoring bare body indirection', () => {
    const tree: GmailPart = {
      partId: '',
      mimeType: 'multipart/related',
      parts: [
        {
          partId: '0',
          mimeType: 'text/html',
          body: { attachmentId: 'large-html', size: 90_000 },
        },
        {
          partId: '1',
          mimeType: 'image/png',
          headers: [{ name: 'Content-ID', value: '<remote-logo@x>' }],
          body: { attachmentId: 'remote-logo', size: 5_000 },
        },
      ],
    }

    expect(extractAttachments(tree)).toEqual([
      expect.objectContaining({ id: 'remote-logo', contentId: 'remote-logo@x' }),
    ])
  })

  it('ignores inline data parts that do not look like attachments', () => {
    const tree: GmailPart = {
      partId: '',
      mimeType: 'multipart/alternative',
      parts: [
        { partId: '0', mimeType: 'text/plain', body: { data: b64url('body') } },
        { partId: '1', mimeType: 'text/html', body: { data: b64url('<p>b</p>') } },
      ],
    }

    expect(extractAttachments(tree)).toHaveLength(0)
  })

  it('uses the attachment disposition to capture inline data parts', () => {
    const tree: GmailPart = {
      partId: '',
      mimeType: 'multipart/mixed',
      parts: [
        {
          partId: '1',
          mimeType: 'text/calendar',
          headers: [{ name: 'Content-Disposition', value: 'attachment' }],
          body: { data: b64url('BEGIN:VCALENDAR'), size: 15 },
        },
      ],
    }

    const attachments = extractAttachments(tree)
    expect(attachments).toHaveLength(1)
    expect(attachments[0]!.filename).toBe('attachment.dat')
  })
})
