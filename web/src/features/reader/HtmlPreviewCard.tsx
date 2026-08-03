// Generic HTML preview card: header chrome above a scaled, non-interactive
// EmailFrame preview. The whole card is one overlay link that opens the
// reader (search param `reader: messageId`) on the current chat route.

import { Link } from '@tanstack/react-router'
import { Skeleton } from '@/components/ui/Skeleton'
import { PREVIEW_HEIGHT_DEFAULT } from '@/lib/constants'
import { EmailFrame } from './EmailFrame'
import { useEmailHtml } from './useEmailHtml'

interface HtmlPreviewCardProps {
  messageId: string
  subject: string
  /** Sender display line (name or address), already resolved by the caller. */
  sender: string
}

export function HtmlPreviewCard({ messageId, subject, sender }: HtmlPreviewCardProps) {
  const email = useEmailHtml(messageId, 'preview')
  const title = subject.trim().length > 0 ? subject.trim() : 'Email'

  return (
    <div className="border-border bg-bg-elev rounded-card relative overflow-hidden border">
      <div className="border-border border-b px-3 py-2">
        <p className="text-fg truncate text-sm font-semibold">{title}</p>
        <p className="text-fg-muted truncate text-xs">{sender}</p>
      </div>

      {email.status === 'loading' && (
        <div style={{ height: PREVIEW_HEIGHT_DEFAULT }}>
          <Skeleton className="h-full w-full rounded-none" />
        </div>
      )}

      {email.status === 'failed' && (
        <div className="flex items-baseline gap-2 px-3 py-4">
          <p className="text-fg-muted text-sm">Preview unavailable</p>
          <span className="text-accent text-sm font-medium">Open original</span>
        </div>
      )}

      {email.status === 'ready' && email.html !== undefined && (
        <div className="relative">
          <EmailFrame html={email.html} cidBlobs={email.cidBlobs ?? {}} mode="preview" />
          <div
            aria-hidden
            className="from-bg-elev pointer-events-none absolute inset-x-0 bottom-0 h-8 bg-gradient-to-t to-transparent"
          />
        </div>
      )}

      <Link
        from="/chats/$conversationId"
        to="."
        search={(prev) => ({ ...prev, reader: messageId })}
        aria-label={`Open email: ${title}`}
        className="absolute inset-0"
      />
    </div>
  )
}
