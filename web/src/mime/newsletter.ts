// Newsletter/promotion scoring, port of
// MessageProcessor.calculateNewsletterScore (weights and patterns verbatim).

import { extractEmail } from './address'

export const NEWSLETTER_THRESHOLD = 50

export type NewsletterSignal =
  | 'gmail_promotions'
  | 'gmail_updates'
  | 'gmail_forums'
  | 'list_unsubscribe'
  | 'list_unsubscribe_post_one_click'
  | 'list_id'
  | 'precedence_bulk'
  | 'sender_noreply'
  | 'sender_newsletter'
  | 'sender_marketing'
  | 'sender_notifications'
  | 'sender_support'
  | 'reply_to_mismatch'
  | 'high_recipient_count'
  | 'very_high_recipient_count'
  | 'subject_discount'
  | 'subject_newsletter'
  | 'subject_urgency'
  | 'subject_periodic'

export interface NewsletterSignalHeaders {
  from?: string | null
  replyTo?: string | null
  subject?: string | null
  listUnsubscribe?: string | null
  listUnsubscribePost?: string | null
  listId?: string | null
  precedence?: string | null
  toCount: number
  ccCount: number
}

export interface NewsletterDetectionResult {
  isNewsletter: boolean
  score: number
  signals: NewsletterSignal[]
}

/** Calculates the weighted newsletter score; threshold 50. */
export function calculateNewsletterScore(
  labelIds: readonly string[],
  headers: NewsletterSignalHeaders,
): NewsletterDetectionResult {
  let score = 0
  const signals: NewsletterSignal[] = []

  // Gmail categorization (ML-based, generally accurate)
  if (labelIds.includes('CATEGORY_PROMOTIONS')) {
    score += 40
    signals.push('gmail_promotions')
  }
  if (labelIds.includes('CATEGORY_UPDATES')) {
    score += 30
    signals.push('gmail_updates')
  }
  if (labelIds.includes('CATEGORY_FORUMS')) {
    score += 20
    signals.push('gmail_forums')
  }

  // Mailing list headers
  if (headers.listUnsubscribe !== null && headers.listUnsubscribe !== undefined) {
    score += 35
    signals.push('list_unsubscribe')
  }
  const listUnsubscribePost = headers.listUnsubscribePost?.toLowerCase()
  if (
    listUnsubscribePost !== undefined &&
    listUnsubscribePost.includes('list-unsubscribe=one-click')
  ) {
    score += 20
    signals.push('list_unsubscribe_post_one_click')
  }
  if (headers.listId !== null && headers.listId !== undefined) {
    score += 25
    signals.push('list_id')
  }

  // Precedence header
  const precedence = headers.precedence?.toLowerCase()
  if (precedence !== undefined && ['bulk', 'list', 'junk'].includes(precedence)) {
    score += 30
    signals.push('precedence_bulk')
  }

  // Sender patterns — first-match-only (strongest first).
  const from = headers.from?.toLowerCase()
  if (from !== undefined && from !== null) {
    const newsletterPatterns = ['newsletter@', 'marketing@', 'promo@', 'promotions@']
    const strongPatterns = ['noreply@', 'no-reply@', 'donotreply@', 'do-not-reply@']
    const notificationPatterns = [
      'notifications@',
      'alerts@',
      'digest@',
      'updates@',
      'news@',
      'mailer@',
    ]
    const supportPatterns = ['support@', 'hello@', 'team@', 'info@']

    if (newsletterPatterns.some((p) => from.includes(p))) {
      score += 35
      signals.push('sender_newsletter')
    } else if (strongPatterns.some((p) => from.includes(p))) {
      score += 25
      signals.push('sender_noreply')
    } else if (notificationPatterns.some((p) => from.includes(p))) {
      score += 20
      signals.push('sender_notifications')
    } else if (supportPatterns.some((p) => from.includes(p))) {
      score += 5
      signals.push('sender_support')
    }
  }

  // Reply-To mismatch (weak signal)
  const replyToLower = headers.replyTo?.toLowerCase()
  if (from !== undefined && from !== null && replyToLower !== undefined && replyToLower !== null) {
    const fromEmail = extractEmail(from)?.toLowerCase()
    const replyToEmail = extractEmail(replyToLower)?.toLowerCase()
    if (fromEmail !== undefined && replyToEmail !== undefined && fromEmail !== replyToEmail) {
      score += 10
      signals.push('reply_to_mismatch')
    }
  }

  // Recipient count
  const totalRecipients = headers.toCount + headers.ccCount
  if (totalRecipients > 50) {
    score += 25
    signals.push('very_high_recipient_count')
  } else if (totalRecipients > 20) {
    score += 15
    signals.push('high_recipient_count')
  }

  // Subject patterns
  const subject = headers.subject?.toLowerCase()
  if (subject !== undefined && subject !== null) {
    const discountPatterns = ['% off', 'sale', 'discount']
    if (discountPatterns.some((p) => subject.includes(p))) {
      score += 15
      signals.push('subject_discount')
    }

    const newsletterPatterns = ['newsletter', 'digest']
    if (newsletterPatterns.some((p) => subject.includes(p))) {
      score += 20
      signals.push('subject_newsletter')
    }

    const urgencyPatterns = [
      'unsubscribe',
      'limited time',
      "don't miss",
      'act now',
      'expires',
      'special offer',
    ]
    if (urgencyPatterns.some((p) => subject.includes(p))) {
      score += 20
      signals.push('subject_urgency')
    }

    const periodicPatterns = ['weekly', 'monthly']
    if (periodicPatterns.some((p) => subject.includes(p))) {
      score += 5
      signals.push('subject_periodic')
    }
  }

  return {
    isNewsletter: score >= NEWSLETTER_THRESHOLD,
    score,
    signals,
  }
}
