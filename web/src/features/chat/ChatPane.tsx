// The chat screen column: header / message scroller / reply bar (the bar sits
// OUTSIDE the scroller so it never scrolls with content). Auto-mark-read runs
// while the pane is mounted and visible.

import { useRef } from 'react'
import { MessageList, type MessageListScrollApi } from './MessageList'
import { ReplyBar, type ReplyBarApi } from './ReplyBar'
import { ChatHeader } from './ChatHeader'
import { useAutoMarkRead } from './useAutoMarkRead'

export function ChatPane({ conversationId }: { conversationId: string }) {
  useAutoMarkRead(conversationId)
  const scrollApiRef = useRef<MessageListScrollApi | null>(null)
  const replyBarRef = useRef<ReplyBarApi>(null)

  return (
    <div className="bg-bg flex h-full min-w-0 flex-1 flex-col">
      <ChatHeader conversationId={conversationId} />
      <MessageList
        key={conversationId}
        conversationId={conversationId}
        onReply={() => replyBarRef.current?.focus()}
        scrollApiRef={scrollApiRef}
      />
      <ReplyBar
        key={`reply:${conversationId}`}
        ref={replyBarRef}
        conversationId={conversationId}
        onSent={() => scrollApiRef.current?.scrollToBottom(true)}
      />
    </div>
  )
}
