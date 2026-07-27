// Assembles the compose-time forward context from the stored message
// (port of ChatViewModel.prepareForwardContext + MessageFormatBuilder's
// ForwardSource construction).
//
// This is the layer that touches Dexie and the DOM; outbox/forwardMetadata
// stays pure. The original HTML body goes through the SAME DOMPurify pipeline
// the reader uses (features/reader/sanitizeEmailHtml) before any of it can
// reach an outgoing message — a forward must never re-emit raw remote markup.

import type { ChatmailDB } from '@/db/schema'
import { normalizeEmail } from '@/identity/normalizeEmail'
import { queryMessageBody } from '@/live/queries'
import {
  buildForwardTextBlock,
  formatForwardDate,
  prefixSubjectForForward,
  type ForwardHeaderFields,
} from '@/outbox/forwardMetadata'
import { sanitizeEmailHtml } from '@/features/reader/sanitizeEmailHtml'

export interface ForwardDraft {
  sourceMessageId: string
  /** 'Fwd: '-prefixed subject; '' when the original had none. */
  subject: string
  /** Prefilled compose body: blank lines, then the forwarded-message block. */
  body: string
  /** Kept so the html alternative can be rebuilt around the user's note at send. */
  header: ForwardHeaderFields
  /** Sanitized original body fragment; null when the source is text-only. */
  sanitizedContentHtml: string | null
  /**
   * Attachments on the original that this send cannot carry (the MIME builder
   * has no multipart/mixed yet). Surfaced as iOS's compose warning.
   */
  skippedAttachmentCount: number
}

/** Header kinds that make up the original's "To:" line. */
const RECIPIENT_KINDS = new Set(['to', 'cc'])

/**
 * Reduces a sanitized email DOCUMENT to the body markup worth forwarding.
 * The sanitizer's own `<head>` (viewer CSP + reader styles) is viewer chrome,
 * not message content, so only `<body>` travels.
 *
 * `cid:` image sources are dropped along the way: inline parts cannot be
 * carried without multipart/related, so leaving the reference behind would
 * only give the recipient a broken image pointing at a part that is not there.
 */
function toForwardableFragment(sanitizedDocument: string): string {
  const doc = new DOMParser().parseFromString(sanitizedDocument, 'text/html')
  const body = doc.body
  if (body === null) return ''
  for (const img of Array.from(body.querySelectorAll('img'))) {
    if (/^cid:/i.test(img.getAttribute('src') ?? '')) img.removeAttribute('src')
  }
  return body.innerHTML
}

/**
 * Builds everything the compose dialog needs to open in forward mode.
 * Returns null when the message is gone (the chat was pruned mid-navigation).
 */
export async function buildForwardDraft(
  db: ChatmailDB,
  messageId: string,
): Promise<ForwardDraft | null> {
  const message = await db.messages.get(messageId)
  if (message === undefined) return null

  const account = await db.accounts.toCollection().first()
  const myAliases = new Set(account?.aliases ?? [])

  // The From line comes from the message's own sender fields. iOS reconstructs
  // it from the participant list only because its ForwardSource carries no
  // sender; MessageRow does, and it is the header verbatim.
  const senderName = message.senderName.trim()
  const from = senderName !== '' ? senderName : message.senderEmail

  const participants = await db.msgParticipants.where('messageId').equals(messageId).toArray()
  const to = participants
    .filter((row) => RECIPIENT_KINDS.has(row.kind))
    .map((row) => row.email)
    .filter((email) => !myAliases.has(normalizeEmail(email)))
    .join(', ')

  const header: ForwardHeaderFields = {
    from,
    date: formatForwardDate(message.internalDate),
    subject: message.subject.trim(),
    to,
  }

  const rawHtml = message.hasHtmlBody === 1 ? await queryMessageBody(db, messageId) : null
  let sanitizedContentHtml: string | null = null
  if (rawHtml !== null && rawHtml !== '') {
    try {
      const sanitized = await sanitizeEmailHtml(rawHtml, { mode: 'full' })
      sanitizedContentHtml = toForwardableFragment(sanitized.html)
    } catch {
      // Sanitization failed: forward as plain text rather than either dropping
      // the forward or letting unsanitized markup through.
      sanitizedContentHtml = null
    }
  }

  // Content for the text part, iOS's `bodyText ?? snippet` ladder.
  const content =
    message.bodyText.trim() !== ''
      ? message.bodyText
      : message.chatPreviewText.trim() !== ''
        ? message.chatPreviewText
        : message.snippet

  const skippedAttachmentCount = await db.attachments.where('messageId').equals(messageId).count()

  return {
    sourceMessageId: messageId,
    subject: prefixSubjectForForward(message.subject),
    body: buildForwardTextBlock(header, content),
    header,
    sanitizedContentHtml,
    skippedAttachmentCount,
  }
}

/** iOS's compose warning copy for attachments a forward cannot carry. */
export function skippedAttachmentWarning(count: number): string {
  return `${count} attachment${count === 1 ? '' : 's'} could not be included`
}
