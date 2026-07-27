import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { patchHappyDomForDomPurify } from '@/features/reader/happyDomPatch'
import { FORWARD_MARKER } from '@/outbox/forwardMetadata'
import { makeTestDb, ME, msgRow, seedAccount } from '@/outbox/testSupport'
import { buildForwardDraft, skippedAttachmentWarning } from './forwardSource'

// Must run before the first sanitize call (DOMPurify caches document methods
// when its module initializes).
patchHappyDomForDomPurify()

describe('buildForwardDraft', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
  })

  afterEach(async () => {
    await db.delete()
  })

  async function seedMessage(overrides: Parameters<typeof msgRow>[0]) {
    await db.messages.add(msgRow(overrides))
  }

  it('returns null when the message is gone', async () => {
    expect(await buildForwardDraft(db, 'nope')).toBeNull()
  })

  it("builds the 'Fwd: ' subject and the plain-text forwarded block", async () => {
    await seedMessage({
      id: 'm1',
      conversationId: 'c1',
      subject: 'Quarterly numbers',
      senderName: 'Bob Jones',
      senderEmail: 'bob@example.com',
      bodyText: 'Numbers are in.',
    })
    await db.msgParticipants.bulkAdd([
      { messageId: 'm1', email: 'bob@example.com', displayName: 'Bob', kind: 'from' },
      { messageId: 'm1', email: ME, displayName: '', kind: 'to' },
      { messageId: 'm1', email: 'dana@example.com', displayName: '', kind: 'cc' },
    ])

    const draft = await buildForwardDraft(db, 'm1')

    expect(draft?.subject).toBe('Fwd: Quarterly numbers')
    expect(draft?.header.from).toBe('Bob Jones')
    expect(draft?.header.subject).toBe('Quarterly numbers')
    // The user's own alias is excluded from the To line; From rows never appear.
    expect(draft?.header.to).toBe('dana@example.com')
    expect(draft?.body).toContain(FORWARD_MARKER)
    expect(draft?.body).toContain('From: Bob Jones')
    expect(draft?.body).toContain('Subject: Quarterly numbers')
    expect(draft?.body).toContain('To: dana@example.com')
    expect(draft?.body.endsWith('Numbers are in.')).toBe(true)
  })

  it('falls back to the address when the sender has no display name', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', senderName: '  ' })
    expect((await buildForwardDraft(db, 'm1'))?.header.from).toBe('bob@example.com')
  })

  it('omits the To line when the message has no stored participants', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1' })
    const draft = await buildForwardDraft(db, 'm1')
    expect(draft?.header.to).toBe('')
    expect(draft?.body).not.toContain('To: ')
  })

  // Source selection: the stored HTML body wins whenever there is one.
  it('prefers the stored HTML body and returns it as a sanitized fragment', async () => {
    await seedMessage({
      id: 'm1',
      conversationId: 'c1',
      hasHtmlBody: 1,
      bodyText: 'plain fallback',
    })
    await db.bodies.add({
      messageId: 'm1',
      html: '<html><body><p>Rich <b>body</b></p></body></html>',
    })

    const draft = await buildForwardDraft(db, 'm1')

    expect(draft?.sanitizedContentHtml).toContain('<p>Rich <b>body</b></p>')
    // A fragment, not the sanitizer's viewer document.
    expect(draft?.sanitizedContentHtml).not.toContain('<!doctype')
    expect(draft?.sanitizedContentHtml).not.toContain('Content-Security-Policy')
    // The text alternative still carries the plain-text body.
    expect(draft?.body).toContain('plain fallback')
  })

  it('selects plain text when the message has no HTML body', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasHtmlBody: 0, bodyText: 'just text' })
    const draft = await buildForwardDraft(db, 'm1')
    expect(draft?.sanitizedContentHtml).toBeNull()
    expect(draft?.body).toContain('just text')
  })

  it('selects plain text when hasHtmlBody is set but the body row is missing', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasHtmlBody: 1, bodyText: 'just text' })
    expect((await buildForwardDraft(db, 'm1'))?.sanitizedContentHtml).toBeNull()
  })

  it('falls back to the chat preview when bodyText is empty', async () => {
    await seedMessage({
      id: 'm1',
      conversationId: 'c1',
      bodyText: '',
      chatPreviewText: 'preview only',
    })
    expect((await buildForwardDraft(db, 'm1'))?.body.endsWith('preview only')).toBe(true)
  })

  it('entity-decodes the snippet fallback — the one API-encoded arm of the ladder', async () => {
    await seedMessage({
      id: 'm1',
      conversationId: 'c1',
      bodyText: '',
      chatPreviewText: '',
      snippet: 'Tom &amp; Jerry &#39;24',
    })
    expect((await buildForwardDraft(db, 'm1'))?.body.endsWith("Tom & Jerry '24")).toBe(true)
  })

  // Security: the forwarded HTML is DOMPurify output, never the stored bytes.
  it('sanitizes the original HTML — script/iframe/handlers never survive', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasHtmlBody: 1 })
    await db.bodies.add({
      messageId: 'm1',
      html:
        '<html><body><p onclick="steal()">Hi</p>' +
        '<script>fetch("https://evil.example")</script>' +
        '<iframe src="https://evil.example"></iframe>' +
        '<a href="javascript:alert(1)">tap</a>' +
        '</body></html>',
    })

    const html = (await buildForwardDraft(db, 'm1'))?.sanitizedContentHtml ?? ''

    expect(html).not.toContain('<script')
    expect(html).not.toContain('fetch(')
    expect(html).not.toContain('<iframe')
    expect(html).not.toContain('onclick')
    expect(html).not.toContain('javascript:')
    expect(html).toContain('Hi')
  })

  it('drops cid: image sources that the outgoing message cannot carry', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasHtmlBody: 1 })
    await db.bodies.add({
      messageId: 'm1',
      html: '<html><body><img src="cid:logo@x" alt="Logo"><img src="https://ok.example/a.png"></body></html>',
    })

    const html = (await buildForwardDraft(db, 'm1'))?.sanitizedContentHtml ?? ''

    expect(html).not.toContain('cid:')
    expect(html).toContain('alt="Logo"')
    expect(html).toContain('https://ok.example/a.png')
  })

  it('drops cid: srcset and background carriers alongside img src', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasHtmlBody: 1 })
    await db.bodies.add({
      messageId: 'm1',
      html:
        '<html><body><img srcset="cid:one 1x, cid:two 2x" alt="hero">' +
        '<table><tbody><tr><td background="cid:three">cell</td></tr></tbody></table>' +
        '</body></html>',
    })
    const fragment = (await buildForwardDraft(db, 'm1'))?.sanitizedContentHtml ?? ''
    expect(fragment).toContain('hero')
    expect(fragment).toContain('cell')
    expect(fragment).not.toContain('cid:')
  })

  it('counts attachments this send cannot carry', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1', hasAttachments: 1 })
    await db.attachments.bulkAdd([
      {
        id: 'm1:1',
        messageId: 'm1',
        gmailAttachmentId: 'a1',
        contentId: '',
        filename: 'deck.pdf',
        mimeType: 'application/pdf',
        byteSize: 10,
        width: 0,
        height: 0,
        state: 'downloaded',
        lastDownloadFailedAt: 0,
      },
      {
        id: 'm1:2',
        messageId: 'm1',
        gmailAttachmentId: 'a2',
        contentId: 'logo@x',
        filename: 'logo.png',
        mimeType: 'image/png',
        byteSize: 10,
        width: 0,
        height: 0,
        state: 'downloaded',
        lastDownloadFailedAt: 0,
      },
    ])

    expect((await buildForwardDraft(db, 'm1'))?.skippedAttachmentCount).toBe(2)
  })

  it('reports no skipped attachments for a message without any', async () => {
    await seedMessage({ id: 'm1', conversationId: 'c1' })
    expect((await buildForwardDraft(db, 'm1'))?.skippedAttachmentCount).toBe(0)
  })
})

describe('skippedAttachmentWarning', () => {
  it('agrees in number', () => {
    expect(skippedAttachmentWarning(1)).toBe('1 attachment could not be included')
    expect(skippedAttachmentWarning(3)).toBe('3 attachments could not be included')
  })
})
