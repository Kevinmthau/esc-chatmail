// Bubble text from a persisted bodyText when the stored preview is blank.
// Port of MessageBubbleContentSource.bodyTextFallback
// (esc-chatmail/Services/Chat/MessageBubbleContentSource.swift).

import { htmlCompatibilityFallback, legacyAutoDetectedFallback, type BubbleResult } from './bubble'
import { extractHtmlFromRawSource } from './rawSource'

/**
 * Derives bubble text from a persisted `bodyText` when no stored preview
 * produced any. bodyText is the raw parsed plain text — it still carries the
 * quoted history, forwarded header block and signature the preview derivation
 * stripped — so it goes through the same quote extraction the preview went
 * through rather than straight into the bubble. A raw RFC822 blob whose
 * text/html part can be recovered is processed as HTML; anything else is
 * auto-detected, as the legacy compatibility path always was.
 *
 * `classifyRichContent` only decides whether the HTML branch also evaluates
 * the rich-content term; it never changes `mainText`.
 */
export function bodyTextFallback(bodyText: string, classifyRichContent = true): BubbleResult {
  const fallbackContent = extractHtmlFromRawSource(bodyText) ?? bodyText
  if (fallbackContent !== bodyText) {
    return htmlCompatibilityFallback(fallbackContent, classifyRichContent)
  }
  return legacyAutoDetectedFallback(fallbackContent, true, classifyRichContent)
}
