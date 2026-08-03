// Exact port of esc-chatmail/Views/Chat/MessageDisplayPolicy.swift plus the
// PreviewTextUtilities.senderDomain trust anchoring it depends on.
//
// Personal email stays in chat bubbles. Incoming forwarded mail falls back to
// the full preview card. Newsletter messages can still use HTML preview cards.
// Rich HTML previews are conservative in one-to-one *reply threads* to avoid
// treating person-to-person replies like newsletters, but should still show
// for genuinely rich transactional/marketing HTML.

import { extractEmail } from '@/identity/normalizeEmail'

export type MessageDisplayMode = 'textBubble' | 'previewCard'

/** Field-for-field mirror of MessageDisplayPolicy.shouldShowHTMLPreview's parameters. */
export interface MessageDisplayInput {
  /** An HTML body exists (or local HTML file/URI metadata in the iOS model). */
  hasHTMLSource: boolean
  isForwardedEmail: boolean
  isNewsletter: boolean
  /** Verdict of the rich-content classifier (mime/richContent.hasGenuineRichContent). */
  hasRichHTMLContent: boolean
  isFromMe: boolean
  isOneToOneConversation: boolean
  subject: string | null
  senderEmail: string | null
  isLikelyCalendarInvite?: boolean
}

// eBay buyer/seller relay senders, BILL approval/transactional notifications,
// and marketplace relay/system senders.
const TRUSTED_TRANSACTIONAL_REPLY_DOMAIN_SUFFIXES: ReadonlySet<string> = new Set([
  'members.ebay.com',
  'bill.com',
  'amazon.com',
  'etsy.com',
  'mercari.com',
  'offerup.com',
  'poshmark.com',
])

/**
 * PreviewTextUtilities.normalizedSourceDomain: parses the sender's domain out
 * of a raw From value ("Name <a@b>", bare address, ...).
 */
export function normalizedSourceDomain(senderEmail: string | null | undefined): string | null {
  const trimmed = senderEmail?.trim() ?? ''
  if (trimmed.length === 0) return null

  const extracted = extractEmail(trimmed) ?? trimmed
  const atIndex = extracted.lastIndexOf('@')
  if (atIndex === -1 || atIndex >= extracted.length - 1) return null

  const domain = extracted
    .slice(atIndex + 1)
    .toLowerCase()
    .replace(/^www\./, '')
    .replace(/^[ <>"'()[\],:;]+/, '')
    .replace(/[ <>"'()[\],:;]+$/, '')

  return domain.length === 0 ? null : domain
}

function domainMatchesSuffix(domain: string | null, suffixes: ReadonlySet<string>): boolean {
  if (domain === null) return false
  const lowered = domain.toLowerCase()
  if (lowered.length === 0) return false
  for (const suffix of suffixes) {
    if (lowered === suffix || lowered.endsWith(`.${suffix}`)) return true
  }
  return false
}

/**
 * Trust checks anchor on the parsed sender domain: substring matching on the
 * raw sender string would accept spoofs like "a@members.ebay.com.evil.com" and
 * display-name forgeries like "relay@members.ebay.com <a@evil.com>".
 */
export function isTrustedTransactionalSender(senderEmail: string | null | undefined): boolean {
  return domainMatchesSuffix(
    normalizedSourceDomain(senderEmail),
    TRUSTED_TRANSACTIONAL_REPLY_DOMAIN_SUFFIXES,
  )
}

function shouldAllowRichReplyPreview(
  senderEmail: string | null,
  hasRichHTMLContent: boolean,
): boolean {
  return hasRichHTMLContent && isTrustedTransactionalSender(senderEmail)
}

/** MessageDisplayPolicy.shouldShowHTMLPreview, branch for branch. */
export function shouldShowHtmlPreview(input: MessageDisplayInput): boolean {
  const {
    hasHTMLSource,
    isForwardedEmail,
    isNewsletter,
    hasRichHTMLContent,
    isFromMe,
    isOneToOneConversation,
    subject,
    senderEmail,
  } = input
  const isLikelyCalendarInvite = input.isLikelyCalendarInvite ?? false

  const trustedTransactionalSender = isTrustedTransactionalSender(senderEmail)
  // Allow newsletter and rich-content preview routing even if the local HTML
  // metadata is missing. The preview loader can still recover embedded HTML.
  const allowNewsletterRecoveryPreview = isNewsletter && !isForwardedEmail
  if (
    !hasHTMLSource &&
    !trustedTransactionalSender &&
    !hasRichHTMLContent &&
    !allowNewsletterRecoveryPreview
  ) {
    return false
  }

  if (isForwardedEmail) {
    return !isFromMe
  }

  // Trusted transactional system senders should render as preview cards even
  // when HTML metadata/rich-content classification is conservative.
  if (trustedTransactionalSender && !isFromMe) {
    return true
  }

  const normalizedSubject = subject?.trim().toLowerCase() ?? ''
  const isReplySubject = normalizedSubject.startsWith('re:')
  const allowsOneToOneReplyPreview =
    isOneToOneConversation && shouldAllowRichReplyPreview(senderEmail, hasRichHTMLContent)

  // Keep one-to-one replies in chat bubbles, even if upstream heuristics are noisy.
  if (isOneToOneConversation) {
    if (isFromMe) {
      return false
    }

    if (isReplySubject && !allowsOneToOneReplyPreview) {
      return false
    }
  }

  // Keep personal reply chains in group threads as bubbles unless we have
  // strong newsletter classification.
  if (isReplySubject && !isNewsletter && !allowsOneToOneReplyPreview) {
    return false
  }

  if (isNewsletter) {
    return true
  }

  if (isLikelyCalendarInvite) {
    return true
  }

  // Transactional/marketing HTML can be genuinely rich even in one-to-one
  // conversations. Trust hasRichHTMLContent to filter out signature cruft.
  return hasRichHTMLContent
}

/** Routes a message to its chat rendering: text bubble vs HTML preview card. */
export function messageDisplayMode(input: MessageDisplayInput): MessageDisplayMode {
  return shouldShowHtmlPreview(input) ? 'previewCard' : 'textBubble'
}
