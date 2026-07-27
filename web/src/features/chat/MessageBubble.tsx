// One chat message row (port of MessageBubble.swift + MessageContentView):
// avatar slot (filled on last-of-run), sender name (groups, first-of-run),
// optional subject line, then content routed through lib/displayPolicy —
// preview card for newsletter/transactional HTML, text bubble for personal
// mail — and the timestamp/unread/send-state meta line.

import { Link, useNavigate } from '@tanstack/react-router'
import { Avatar } from '@/components/ui/Avatar'
import { ContextMenu, ContextMenuItem } from '@/components/ui/ContextMenu'
import { UnreadDot } from '@/components/ui/UnreadDot'
import type { MessageRow } from '@/db/types'
import { AttachmentContent } from '@/features/attachments/AttachmentContent'
import { HtmlPreviewCard } from '@/features/reader/HtmlPreviewCard'
import type { RunDecoration } from '@/lib/bubbleRuns'
import { cn } from '@/lib/cn'
import { messageDisplayMode } from '@/lib/displayPolicy'
import { formatTimestamp } from '@/lib/formatTimestamp'
import { isForwardedSubject } from '@/mime/preview'
import { useRichHtmlContent } from './useRichHtmlContent'

// --- Row ---------------------------------------------------------------------

export interface MessageBubbleProps {
  message: MessageRow
  decoration: RunDecoration
  isOneToOne: boolean
  /** Focuses the reply bar (context-menu Reply). */
  onReply: () => void
}

export function MessageBubble({ message, decoration, isOneToOne, onReply }: MessageBubbleProps) {
  const navigate = useNavigate({ from: '/chats/$conversationId' })
  const isMe = message.isFromMe === 1
  const hasRichHTMLContent = useRichHtmlContent(message)

  const mode = messageDisplayMode({
    hasHTMLSource: message.hasHtmlBody === 1,
    isForwardedEmail: isForwardedSubject(message.subject),
    isNewsletter: message.isNewsletter === 1,
    hasRichHTMLContent,
    isFromMe: isMe,
    isOneToOneConversation: isOneToOne,
    subject: message.subject,
    senderEmail: message.senderEmail,
  })

  const senderLabel =
    message.senderName.trim().length > 0 ? message.senderName : message.senderEmail
  const text = (
    message.chatPreviewText.trim().length > 0 ? message.chatPreviewText : message.bodyText
  ).trim()
  const subject = message.subject.trim()
  const showSubjectLine =
    mode !== 'previewCard' && subject.length > 0 && subject.toLowerCase() !== text.toLowerCase()

  const openReader = (): void => {
    void navigate({ to: '.', search: (prev) => ({ ...prev, reader: message.id }) })
  }

  // Forward opens the compose dialog (mounted by the /chats layout) in forward
  // mode; the message id travels in the search param, like `reader`.
  const openForward = (): void => {
    void navigate({ to: '.', search: (prev) => ({ ...prev, forward: message.id }) })
  }

  return (
    <ContextMenu
      trigger={
        <div className={cn('flex w-full items-end gap-2 py-0.5', isMe && 'flex-row-reverse')}>
          {!isMe && (
            <div data-testid="avatar-slot" className="w-6 shrink-0">
              {decoration.showAvatar && <Avatar name={senderLabel} size="bubble" />}
            </div>
          )}

          <div
            className={cn(
              'flex min-w-0 max-w-[320px] flex-col gap-1',
              isMe ? 'items-end' : 'items-start',
            )}
          >
            {decoration.showSenderName && (
              <span className="text-fg-muted px-1 text-xs">{senderLabel}</span>
            )}
            {showSubjectLine && (
              <span className="text-fg-muted px-1 text-xs font-medium">{subject}</span>
            )}

            {message.hasAttachments === 1 && <AttachmentContent messageId={message.id} />}

            <BubbleContent message={message} mode={mode} text={text} senderLabel={senderLabel} />

            <BubbleMeta message={message} />
          </div>
        </div>
      }
    >
      <ContextMenuItem onSelect={onReply}>Reply</ContextMenuItem>
      <ContextMenuItem onSelect={openForward}>Forward</ContextMenuItem>
      {message.hasHtmlBody === 1 && (
        <ContextMenuItem onSelect={openReader}>View original</ContextMenuItem>
      )}
    </ContextMenu>
  )
}

// --- Content routing ---------------------------------------------------------

function BubbleContent({
  message,
  mode,
  text,
  senderLabel,
}: {
  message: MessageRow
  mode: 'textBubble' | 'previewCard'
  text: string
  senderLabel: string
}) {
  const isMe = message.isFromMe === 1

  if (mode === 'previewCard') {
    return (
      <div className="w-72 max-w-full">
        <HtmlPreviewCard messageId={message.id} subject={message.subject} sender={senderLabel} />
      </div>
    )
  }

  if (text.length > 0) {
    return (
      <div
        className={cn(
          'rounded-bubble px-3 py-2',
          isMe ? 'bg-bubble-out text-bubble-out-fg' : 'bg-bubble-in text-bubble-in-fg',
        )}
      >
        <BubbleText text={text} />
        {message.hasHtmlBody === 1 && (
          <Link
            from="/chats/$conversationId"
            to="."
            search={(prev) => ({ ...prev, reader: message.id })}
            className="rounded-chip mt-1 block w-fit border border-current/40 px-2 py-0.5 text-xs font-medium opacity-80 hover:opacity-100"
          >
            View original
          </Link>
        )}
      </div>
    )
  }

  if (message.hasHtmlBody === 1) {
    return (
      <Link
        from="/chats/$conversationId"
        to="."
        search={(prev) => ({ ...prev, reader: message.id })}
        className="rounded-bubble bg-accent px-3 py-2 text-sm font-medium text-white active:opacity-70"
      >
        View original
      </Link>
    )
  }

  if (message.hasAttachments === 1) return null

  return (
    <div
      className={cn(
        'rounded-bubble px-3 py-2 text-[15px] italic',
        isMe ? 'bg-bubble-out text-bubble-out-fg' : 'bg-bubble-in text-bubble-in-fg',
      )}
    >
      No preview available
    </div>
  )
}

// Safe URL linkification: the body text is split around http(s) matches and
// rendered as React text nodes + anchors — never innerHTML.
const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+/g

export function BubbleText({ text }: { text: string }) {
  const nodes: React.ReactNode[] = []
  const pattern = new RegExp(URL_PATTERN.source, URL_PATTERN.flags)
  let lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > lastIndex) nodes.push(text.slice(lastIndex, match.index))
    const url = match[0]
    nodes.push(
      <a
        key={`${match.index}-${url}`}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        className="underline"
      >
        {url}
      </a>,
    )
    lastIndex = match.index + url.length
  }
  if (lastIndex < text.length) nodes.push(text.slice(lastIndex))

  return (
    <p className="select-text whitespace-pre-wrap break-words text-[15px] leading-snug">{nodes}</p>
  )
}

// --- Meta line ---------------------------------------------------------------

function BubbleMeta({ message }: { message: MessageRow }) {
  const incomingUnread = message.isFromMe !== 1 && message.isUnread === 1
  return (
    <div className="flex items-center gap-1 px-1">
      {incomingUnread && <UnreadDot size="bubble" />}
      <span className="text-fg-muted text-[11px]">{formatTimestamp(message.internalDate)}</span>
      {message.sendState === 'pending' && (
        <span className="text-fg-muted animate-pulse text-[11px] motion-reduce:animate-none">
          Sending…
        </span>
      )}
      {message.sendState === 'failed' && (
        <span className="text-danger text-[11px] font-medium">Send failed</span>
      )}
    </div>
  )
}
