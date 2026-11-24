import { describe, expect, it } from 'vitest'
import { GmailApiError, NetworkError } from '../gmail/errors'
import type { GmailMessage, GmailPart } from '../gmail/types'
import { MAXIMUM_CONTINUATIONS_PER_KIND, joinedHtml, joinedPlainText } from './mimeBody'
import { LargeBodyFetchError, parseGmailMessage } from './parse'

// A body a mail client split around something it placed in the text
// (architecture review gap-message-shape-extremes#3, gap-mime-decoding-i18n#4).
// Ports MessageProcessorSplitBodyTests case for case.

function b64url(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

const headers = [
  { name: 'From', value: 'Alice <alice@example.com>' },
  { name: 'To', value: 'me@example.com' },
  { name: 'Subject', value: 'Split body' },
]

function message(parts: GmailPart[], mimeType = 'multipart/mixed'): GmailMessage {
  return {
    id: 'split-body',
    threadId: 'split-body-thread',
    internalDate: '1700000000000',
    labelIds: ['INBOX'],
    payload: { partId: '0', mimeType, headers, parts },
  }
}

function textPart(partId: string, mimeType: string, text: string): GmailPart {
  return { partId, mimeType, body: { data: b64url(text), size: text.length } }
}

function largeTextPart(
  partId: string,
  mimeType: string,
  attachmentId: string,
  size = 30_000,
): GmailPart {
  return { partId, mimeType, body: { attachmentId, size } }
}

function filePart(
  partId: string,
  mimeType: string,
  filename: string,
  disposition: string,
): GmailPart {
  return {
    partId,
    mimeType,
    filename,
    headers: [{ name: 'Content-Disposition', value: disposition }],
    body: { data: b64url('\xff\xd8'), size: 2 },
  }
}

function inlinePhoto(partId: string): GmailPart {
  return filePart(
    partId,
    'image/jpeg',
    `image${partId}.jpeg`,
    `inline; filename="image${partId}.jpeg"`,
  )
}

const fragmentA =
  '<html><head><style>p{color:red}</style></head><body dir="auto"><div>SEG_A</div></body></html>'
const fragmentB =
  '<html><head><meta charset="utf-8"></head><body dir="auto"><div>SEG_B</div></body></html>'

describe('split bodies', () => {
  // Revert-check: the continuation branch of mimeBody.ts walk.
  it('keeps the words after an inline photo', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'Look at this TOKEN_BEFORE'),
        inlinePhoto('0.1'),
        textPart('0.2', 'text/plain', 'TOKEN_AFTER the photo'),
      ]),
    )

    expect(parsed!.plainText).toBe('Look at this TOKEN_BEFORE\n\nTOKEN_AFTER the photo')
    expect(parsed!.attachments).toHaveLength(1)
  })

  it('keeps every fragment in order around several photos', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'ONE'),
        inlinePhoto('0.1'),
        textPart('0.2', 'text/plain', 'TWO'),
        inlinePhoto('0.3'),
        inlinePhoto('0.4'),
        textPart('0.5', 'text/plain', 'THREE'),
      ]),
    )

    expect(parsed!.plainText).toBe('ONE\n\nTWO\n\nTHREE')
  })

  // Revert-check: the `inline` test in isInlineFilePart.
  it('does not join text after an attached file', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'REAL_BODY'),
        filePart('0.1', 'application/pdf', 'report.pdf', 'attachment'),
        textPart('0.2', 'text/plain', 'LIST_FOOTER'),
      ]),
    )

    expect(parsed!.plainText).toBe('REAL_BODY')
  })

  it('does not join after an attachment disposition that names inline', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'REAL_BODY'),
        filePart('0.1', 'image/png', 'inline.png', 'attachment; filename="inline.png"'),
        textPart('0.2', 'text/plain', 'LIST_FOOTER'),
      ]),
    )

    expect(parsed!.plainText).toBe('REAL_BODY')
  })

  it('does not join two text parts side by side', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'REAL_BODY'),
        textPart('0.1', 'text/plain', 'TRAILING_GENERATED_TOKEN'),
      ]),
    )

    expect(parsed!.plainText).toBe('REAL_BODY')
  })

  // Revert-check: isMultipartMixed in walk (joining in every container).
  it('does not join the parts of a multipart/related', async () => {
    const parsed = await parseGmailMessage(
      message(
        [
          textPart('0.0', 'text/html', '<html><body><p>ROOT</p></body></html>'),
          inlinePhoto('0.1'),
          textPart('0.2', 'text/html', '<html><body><p>RESOURCE</p></body></html>'),
        ],
        'multipart/related',
      ),
    )

    expect(parsed!.html).toContain('ROOT')
    expect(parsed!.html).not.toContain('RESOURCE')
  })

  it('leaves the body as it was for an empty trailing fragment', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'ONLY_WORDS'),
        inlinePhoto('0.1'),
        textPart('0.2', 'text/plain', '  \n'),
      ]),
    )

    expect(parsed!.plainText).toBe('ONLY_WORDS')
  })

  it('stores both HTML fragments around an inline PDF in one body', async () => {
    const parsed = await parseGmailMessage(
      message(
        [
          textPart('0.0', 'text/plain', 'SEG_A\n\nSEG_B'),
          {
            partId: '0.1',
            mimeType: 'multipart/mixed',
            parts: [
              textPart('0.1.0', 'text/html', fragmentA),
              filePart('0.1.1', 'application/pdf', 'plan.pdf', 'inline'),
              textPart('0.1.2', 'text/html', fragmentB),
            ],
          },
        ],
        'multipart/alternative',
      ),
    )

    expect(parsed!.html).toBe(
      '<html><head><style>p{color:red}</style></head><body dir="auto"><div>SEG_A</div>' +
        '<div>SEG_B</div></body></html>',
    )
  })

  it('does not join an HTML fragment with nothing visible', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/html', fragmentA),
        inlinePhoto('0.1'),
        textPart(
          '0.2',
          'text/html',
          '<html><body><div style="display:none">TRACKER</div></body></html>',
        ),
      ]),
    )

    expect(parsed!.html).not.toContain('TRACKER')
  })

  // Revert-check: answering null for a failed continuation fetch.
  it('throws when a continuation cannot be fetched for a transient reason', async () => {
    await expect(
      parseGmailMessage(
        message([
          textPart('0.0', 'text/plain', 'BEFORE'),
          inlinePhoto('0.1'),
          largeTextPart('0.2', 'text/plain', 'continuation'),
        ]),
        {
          fetchLargeBody: () => Promise.reject(new NetworkError('offline')),
        },
      ),
    ).rejects.toBeInstanceOf(LargeBodyFetchError)
  })

  it('keeps the first fragment when a continuation is gone server-side', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'BEFORE'),
        inlinePhoto('0.1'),
        largeTextPart('0.2', 'text/plain', 'continuation'),
      ]),
      {
        fetchLargeBody: () => Promise.reject(new GmailApiError(404, 'notFound', 'gone')),
      },
    )

    expect(parsed!.plainText).toBe('BEFORE')
  })

  it('fetches and joins a continuation served by attachmentId', async () => {
    const fetched: string[] = []
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/plain', 'BEFORE'),
        inlinePhoto('0.1'),
        largeTextPart('0.2', 'text/plain', 'continuation'),
      ]),
      {
        fetchLargeBody: (_messageId, attachmentId) => {
          fetched.push(attachmentId)
          return Promise.resolve(b64url('AFTER'))
        },
      },
    )

    expect(parsed!.plainText).toBe('BEFORE\n\nAFTER')
    expect(fetched).toEqual(['continuation'])
  })

  // Revert-check: admitsAnother's count.
  it('leaves out continuations past the count bound', async () => {
    const parts = [textPart('p0', 'text/plain', 'F0')]
    for (let index = 1; index <= 20; index++) {
      parts.push(inlinePhoto(`i${index}`), textPart(`p${index}`, 'text/plain', `F${index}`))
    }

    const parsed = await parseGmailMessage(message(parts))
    const fragments = parsed!.plainText!.split('\n\n')

    expect(fragments).toHaveLength(MAXIMUM_CONTINUATIONS_PER_KIND + 1)
    expect(fragments.at(-1)).toBe(`F${MAXIMUM_CONTINUATIONS_PER_KIND}`)
  })

  // Revert-check: the declared-size test in joiningContinuation.
  it('does not fetch a continuation declared larger than the byte bound', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/html', fragmentA),
        inlinePhoto('0.1'),
        largeTextPart('0.2', 'text/html', 'huge', 2 * 1024 * 1024 + 1),
      ]),
      {
        fetchLargeBody: () => Promise.reject(new Error('must not be fetched')),
      },
    )

    expect(parsed!.html).toBe(fragmentA)
  })
})

describe('continuation bounds and kinds', () => {
  // Revert-check: counting only joined continuations (readCount after the join).
  it('counts a refused continuation toward the bound', async () => {
    const parts = [textPart('0', 'text/html', fragmentA)]
    for (let index = 1; index <= 100; index++) {
      parts.push(
        inlinePhoto(`i${index}`),
        largeTextPart(`h${index}`, 'text/html', `hidden-${index}`),
      )
    }
    let fetches = 0
    const parsed = await parseGmailMessage(message(parts), {
      fetchLargeBody: () => {
        fetches += 1
        return Promise.resolve(b64url('<html><body><div hidden>x</div></body></html>'))
      },
    })

    expect(parsed!.html).toBe(fragmentA)
    expect(fetches).toBe(MAXIMUM_CONTINUATIONS_PER_KIND)
  })

  // Revert-check: passing `kinds` rather than `missingKinds` to the child's walk.
  it('fetches no HTML continuation in a container walked for plain text', async () => {
    const parsed = await parseGmailMessage(
      message([
        textPart('0.0', 'text/html', fragmentA),
        {
          partId: '0.1',
          mimeType: 'multipart/mixed',
          parts: [
            textPart('0.1.0', 'text/html', fragmentB),
            inlinePhoto('0.1.1'),
            largeTextPart('0.1.2', 'text/html', 'dropped-anyway'),
            textPart('0.1.3', 'text/plain', 'PLAIN'),
          ],
        },
      ]),
      { fetchLargeBody: () => Promise.reject(new Error('must not be fetched')) },
    )

    expect(parsed!.html).toBe(fragmentA)
    expect(parsed!.plainText).toBe('PLAIN')
  })
})

describe('joinedHtml', () => {
  it("puts the fragment's body content before the closing body tag", () => {
    expect(
      joinedHtml(
        '<HTML><BODY><p>A</p></BODY></HTML>',
        '<html><head><title>x</title></head><Body class="b"><p>B</p></bOdY></html>',
      ),
    ).toBe('<HTML><BODY><p>A</p><p>B</p></BODY></HTML>')
  })

  it('does not end the body tag at a > in a quoted attribute value', () => {
    expect(joinedHtml('<body>A</body>', `<body onload="a>b" data-x='c>d'>B</body>`)).toBe(
      '<body>AB</body>',
    )
  })

  it('does not take a body-like tag name for the body', () => {
    expect(joinedHtml('<body>A</body>', '<bodyguard>B</bodyguard>')).toBe(
      '<body>A<bodyguard>B</bodyguard></body>',
    )
  })

  it('appends at the end without closing tags', () => {
    expect(joinedHtml('<div>A</div>', '<div>B</div>')).toBe('<div>A</div><div>B</div>')
    expect(joinedHtml('<html><div>A</div></html>', '<div>B</div>')).toBe(
      '<html><div>A</div><div>B</div></html>',
    )
  })

  it('keeps non-ASCII text whole', () => {
    expect(joinedHtml('<body>Ünïcödé 😀</body>', '<body>İstanbul ſ</body>')).toBe(
      '<body>Ünïcödé 😀İstanbul ſ</body>',
    )
  })
})

describe('joinedPlainText', () => {
  // Revert-check: trimming with /[\r\n]+$/ again. HONEST SCOPE: asserts a
  // time, about a hundred times the linear scan's.
  it('is linear in a long run of line breaks inside the base', () => {
    const run = '\n'.repeat(120_000)
    const started = performance.now()
    const joined = joinedPlainText(`A${run}x\n\n`, 'B')
    expect(performance.now() - started).toBeLessThan(1000)
    expect(joined).toBe(`A${run}x\n\nB`)
  })

  it('makes the seam one blank line', () => {
    expect(joinedPlainText('A\r\n\r\n', '\n\nB\n')).toBe('A\n\nB\n')
  })
})
