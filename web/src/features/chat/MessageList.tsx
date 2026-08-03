// The message scroller: windowed rendering (useChatWindow, +50 per load-older)
// driven by the useChatScroll engine. Mount this keyed by conversationId so all
// scroll state resets on chat switches while the saved-offset Map restores the
// previous position.

import { useMemo, useState, type RefObject } from 'react'
import { Skeleton } from '@/components/ui/Skeleton'
import type { ConversationRow, MessageRow } from '@/db/types'
import { useChatWindow, useConversation } from '@/live/hooks'
import { computeRuns, type RunDecoration } from '@/lib/bubbleRuns'
import { MessageBubble } from './MessageBubble'
import { useChatScroll } from './useChatScroll'

const WINDOW_STEP = 50

const FALLBACK_DECORATION: RunDecoration = {
  isFirstOfRun: true,
  isLastOfRun: true,
  showAvatar: true,
  showSenderName: false,
}

export interface MessageListScrollApi {
  scrollToBottom: (smooth?: boolean) => void
}

export interface MessageListProps {
  conversationId: string
  onReply: () => void
  /** Imperative scroll access for the reply bar's post-send jump. */
  scrollApiRef?: RefObject<MessageListScrollApi | null>
}

export function MessageList({ conversationId, onReply, scrollApiRef }: MessageListProps) {
  const [limit, setLimit] = useState(WINDOW_STEP)
  const window = useChatWindow(conversationId, limit)
  const conversation = useConversation(conversationId)

  if (window === undefined) {
    return (
      <div className="flex min-h-0 flex-1 flex-col justify-end gap-3 p-4">
        <Skeleton className="h-10 w-2/3" />
        <Skeleton className="h-10 w-1/2 self-end" />
        <Skeleton className="h-10 w-3/5" />
      </div>
    )
  }

  return (
    <MessageListInner
      conversationId={conversationId}
      messages={window.messages}
      hasOlder={window.hasOlder}
      onLoadOlder={() => setLimit((l) => l + WINDOW_STEP)}
      conversation={conversation}
      onReply={onReply}
      scrollApiRef={scrollApiRef}
    />
  )
}

function MessageListInner({
  conversationId,
  messages,
  hasOlder,
  onLoadOlder,
  conversation,
  onReply,
  scrollApiRef,
}: {
  conversationId: string
  messages: MessageRow[]
  hasOlder: boolean
  onLoadOlder: () => void
  conversation: ConversationRow | undefined
  onReply: () => void
  scrollApiRef?: RefObject<MessageListScrollApi | null>
}) {
  const {
    scrollerRef,
    contentRef,
    topSentinelRef,
    bottomSentinelRef,
    newCount,
    scrollToBottom,
    jumpToNew,
  } = useChatScroll({ conversationId, messages, hasOlder, onLoadOlder })

  if (scrollApiRef !== undefined) scrollApiRef.current = { scrollToBottom }

  const isGroup = conversation?.type === 'group'
  const isOneToOne = !isGroup
  const runs = useMemo(
    () =>
      computeRuns(
        messages.map((m) => ({ id: m.id, senderEmail: m.senderEmail, isFromMe: m.isFromMe === 1 })),
        { isGroup },
      ),
    [messages, isGroup],
  )

  return (
    <div className="relative min-h-0 flex-1">
      <div
        ref={scrollerRef}
        data-testid="chat-scroller"
        className="h-full overflow-y-auto overscroll-contain [overflow-anchor:none]"
      >
        <div ref={contentRef} className="flex min-h-full flex-col px-3 py-2">
          {/* mt-auto on the first child bottom-aligns short threads. */}
          <div aria-hidden className="mt-auto" />
          <div ref={topSentinelRef} aria-hidden className="h-px shrink-0" />
          {messages.length === 0 && (
            <p className="text-fg-muted py-8 text-center text-sm">No messages</p>
          )}
          {messages.map((message) => (
            <MessageBubble
              key={message.id}
              message={message}
              decoration={runs.get(message.id) ?? FALLBACK_DECORATION}
              isOneToOne={isOneToOne}
              onReply={onReply}
            />
          ))}
          <div ref={bottomSentinelRef} aria-hidden className="h-px shrink-0" />
        </div>
      </div>

      {newCount > 0 && (
        <button
          type="button"
          onClick={jumpToNew}
          className="rounded-chip bg-accent absolute bottom-3 left-1/2 flex -translate-x-1/2 items-center gap-1 px-3 py-1.5 text-sm font-medium text-white shadow-lg active:opacity-80"
        >
          {newCount === 1 ? '1 new message' : `${newCount} new messages`}
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden>
            <path
              d="M7 2v9m0 0L3.5 7.5M7 11l3.5-3.5"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
      )}
    </div>
  )
}
