// Rich-HTML-content verdict for display-policy routing. hasGenuineRichContent
// needs the HTML body (bodies table); bodies are immutable per message id, so
// verdicts are cached module-wide and the body is only queried until the
// verdict is known.

import { useMemo } from 'react'
import type { MessageRow } from '@/db/types'
import { useAccountLiveQuery } from '@/live/hooks'
import { queryMessageBody } from '@/live/queries'
import { htmlCompatibilityFallback } from '@/mime/bubble'

const RICH_CACHE_MAX = 200
const richContentCache = new Map<string, boolean>()

function cacheRichVerdict(messageId: string, value: boolean): void {
  richContentCache.set(messageId, value)
  while (richContentCache.size > RICH_CACHE_MAX) {
    const oldest = richContentCache.keys().next().value
    if (oldest === undefined) break
    richContentCache.delete(oldest)
  }
}

export function clearRichContentCacheForTests(): void {
  richContentCache.clear()
}

export function useRichHtmlContent(message: MessageRow): boolean {
  const needsBody = message.hasHtmlBody === 1 && !richContentCache.has(message.id)
  const bodyHtml = useAccountLiveQuery(
    (db) => {
      if (!needsBody) return null
      return queryMessageBody(db, message.id)
    },
    [message.id, needsBody],
  )

  return useMemo(() => {
    if (message.hasHtmlBody !== 1) return false
    const cached = richContentCache.get(message.id)
    if (cached !== undefined) return cached
    if (typeof bodyHtml !== 'string' || bodyHtml.length === 0) return false
    // Same entry point as the iOS ProcessedTextCache path: classifyRichContent
    // routes through mime/richContent.hasGenuineRichContent.
    const verdict = htmlCompatibilityFallback(bodyHtml, true).hasRichContent
    cacheRichVerdict(message.id, verdict)
    return verdict
  }, [message.id, message.hasHtmlBody, bodyHtml])
}
