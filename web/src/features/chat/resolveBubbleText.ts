// The text a chat bubble shows for a row (MessageBubble's one text input).

import { bodyTextFallback } from '@/mime/bodyTextFallback'

/**
 * The stored preview is exactly what the bubble shows. When it is blank, the
 * row's bodyText is still the raw parsed plain text — the quoted history,
 * forwarded header block or signature the preview derivation stripped — so it
 * is never rendered verbatim: it runs through the fallback iOS's compatibility
 * path runs (MessageBubbleContentSource.bodyTextFallback), and nothing from it
 * means no text, leaving the attachments / View original / No preview
 * branches to render. Only mainText is consumed here; the rich-content term is
 * useRichHtmlContent's, so the classifier is skipped (it never changes
 * mainText). Memoized by the caller because this runs per row.
 */
export function resolveBubbleText(chatPreviewText: string, bodyText: string): string {
  const preview = chatPreviewText.trim()
  if (preview.length > 0) return preview
  if (bodyText.trim().length === 0) return ''
  return bodyTextFallback(bodyText, false).mainText ?? ''
}
