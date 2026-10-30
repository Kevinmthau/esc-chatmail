// Attachment admission parity with MessageProcessor.extractAttachments /
// shouldTreatInlineDataPartAsAttachment: nameless server parts and
// inline-disposition Content-ID parts.

import { describe, expect, it } from 'vitest'
import type { GmailMessage, GmailPart } from '../gmail/types'
import {
  checkForAttachments,
  extractAttachments,
  isInlineDataAttachmentPart,
  isServerAttachmentPart,
} from './attachments'
import { parseGmailMessage } from './parse'

function b64url(text: string): string {
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

const baseHeaders = [
  { name: 'Subject', value: 'Report' },
  { name: 'From', value: 'Robot <robot@example.com>' },
  { name: 'To', value: 'me@example.com' },
  { name: 'Date', value: 'Mon, 1 Jan 2024 00:00:00 +0000' },
]

function message(payload: GmailPart): GmailMessage {
  return {
    id: 'msg-1',
    threadId: 'thread-1',
    internalDate: '1704067200000',
    labelIds: ['INBOX'],
    payload,
  }
}

describe('server attachment admission', () => {
  // Revert-check: isServerAttachmentPart — the old attachmentId path required
  // isAttachmentPart, which has no branch for a nameless, undisposed binary.
  it('extracts a nameless application/pdf behind an attachmentId as attachment.pdf', async () => {
    const payload: GmailPart = {
      partId: '',
      mimeType: 'multipart/mixed',
      headers: baseHeaders,
      parts: [
        { partId: '0', mimeType: 'text/plain', body: { data: b64url('Report attached.') } },
        {
          partId: '1',
          mimeType: 'application/pdf',
          filename: '',
          body: { attachmentId: 'att-noname', size: 4_096 },
        },
      ],
    }

    expect(isServerAttachmentPart(payload.parts![1]!)).toBe(true)
    expect(checkForAttachments(payload)).toBe(true)
    expect(extractAttachments(payload)).toEqual([
      expect.objectContaining({
        id: 'att-noname',
        filename: 'attachment.pdf',
        mimeType: 'application/pdf',
        size: 4_096,
        inlineData: null,
      }),
    ])

    const parsed = await parseGmailMessage(message(payload))
    expect(parsed!.hasAttachments).toBe(true)
    expect(parsed!.attachments.map((attachment) => attachment.id)).toEqual(['att-noname'])
    expect(parsed!.plainText).toBe('Report attached.')
  })

  // Revert-check: isServerAttachmentPart — an application/octet-stream part
  // with no name is what Gmail lists as "noname"; it is still a file.
  it('extracts a nameless application/octet-stream behind an attachmentId', () => {
    const payload: GmailPart = {
      partId: '',
      mimeType: 'multipart/mixed',
      parts: [
        {
          partId: '1',
          mimeType: 'application/octet-stream',
          body: { attachmentId: 'att-blob', size: 10 },
        },
      ],
    }

    expect(extractAttachments(payload)).toEqual([
      expect.objectContaining({ id: 'att-blob', filename: 'attachment.dat' }),
    ])
  })

  it('keeps oversized text bodies behind an attachmentId as bodies, not attachments', () => {
    // The guard the widening must not lose: Gmail's indirection for large
    // text/html and text/plain bodies looks identical to a nameless part.
    const htmlBody: GmailPart = {
      partId: '0',
      mimeType: 'text/html',
      body: { attachmentId: 'large-html', size: 90_000 },
    }
    const plainBody: GmailPart = {
      partId: '1',
      mimeType: 'text/plain',
      body: { attachmentId: 'large-plain', size: 90_000 },
    }
    const payload: GmailPart = {
      partId: '',
      mimeType: 'multipart/alternative',
      parts: [plainBody, htmlBody],
    }

    expect(isServerAttachmentPart(htmlBody)).toBe(false)
    expect(isServerAttachmentPart(plainBody)).toBe(false)
    expect(checkForAttachments(payload)).toBe(false)
    expect(extractAttachments(payload)).toEqual([])
  })

  it('still admits a named text part behind an attachmentId', () => {
    const transcript: GmailPart = {
      partId: '1',
      mimeType: 'text/plain',
      filename: 'transcript.txt',
      body: { attachmentId: 'att-txt', size: 12_000 },
    }
    expect(isServerAttachmentPart(transcript)).toBe(true)
  })
})

describe('inline-disposition Content-ID admission', () => {
  // Revert-check: isInlineDataAttachmentPart — the inline-disposition +
  // Content-ID branch of iOS shouldTreatInlineDataPartAsAttachment.
  it('extracts an inline text/calendar part referenced by Content-ID without a filename', () => {
    const ics = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR'
    const calendar: GmailPart = {
      partId: '1',
      mimeType: 'text/calendar; method=REQUEST',
      headers: [
        { name: 'Content-Disposition', value: 'inline' },
        { name: 'Content-ID', value: '<invite@example.com>' },
      ],
      body: { data: b64url(ics), size: ics.length },
    }
    const payload: GmailPart = { partId: '', mimeType: 'multipart/mixed', parts: [calendar] }

    expect(isInlineDataAttachmentPart(calendar)).toBe(true)
    expect(checkForAttachments(payload)).toBe(true)
    const [attachment] = extractAttachments(payload)
    expect(attachment).toMatchObject({
      filename: 'attachment.dat',
      mimeType: 'text/calendar; method=REQUEST',
      contentId: 'invite@example.com',
    })
    expect(attachment?.inlineData).not.toBeNull()
  })

  // Revert-check: isInlineDataAttachmentPart
  it('extracts an inline application/pdf part referenced by Content-ID without a filename', () => {
    const pdf: GmailPart = {
      partId: '2',
      mimeType: 'application/pdf',
      headers: [
        { name: 'Content-Disposition', value: 'inline' },
        { name: 'Content-ID', value: '<ticket@example.com>' },
      ],
      body: { data: b64url('%PDF-1.7'), size: 8 },
    }

    expect(extractAttachments({ partId: '', mimeType: 'multipart/mixed', parts: [pdf] })).toEqual([
      expect.objectContaining({ filename: 'attachment.pdf', contentId: 'ticket@example.com' }),
    ])
  })

  it('leaves an inline Content-ID HTML root as the body, not an attachment', () => {
    // The multipart/related root carries both headers on many senders; it
    // feeds the content walk and must not also become an attachment.html tile.
    const root: GmailPart = {
      partId: '0',
      mimeType: 'text/html',
      headers: [
        { name: 'Content-Disposition', value: 'inline' },
        { name: 'Content-ID', value: '<root-html@x>' },
      ],
      body: { data: b64url('<p>Related root</p>') },
    }

    expect(isInlineDataAttachmentPart(root)).toBe(false)
    expect(
      extractAttachments({ partId: '', mimeType: 'multipart/related', parts: [root] }),
    ).toEqual([])
  })

  it('does not admit an inline disposition without a Content-ID', () => {
    const part: GmailPart = {
      partId: '1',
      mimeType: 'application/pdf',
      headers: [{ name: 'Content-Disposition', value: 'inline' }],
      body: { data: b64url('%PDF-1.7'), size: 8 },
    }
    expect(isInlineDataAttachmentPart(part)).toBe(false)
  })
})
