import { Link } from '@tanstack/react-router'
import { Avatar } from '@/components/ui/Avatar'
import { AvatarStack } from '@/components/ui/AvatarStack'
import { ContextMenu } from '@/components/ui/ContextMenu'
import { UnreadDot } from '@/components/ui/UnreadDot'
import type { ConversationRow as ConversationRecord } from '@/db/types'
import { formatTimestamp } from '@/lib/formatTimestamp'
import { PinIcon } from './icons'
import { RowActions, RowContextMenuItems } from './RowActions'

interface ConversationRowProps {
  conversation: ConversationRecord
  /** Active list filter, preserved when navigating into the chat. */
  filter?: 'unread'
}

/**
 * One 88px conversation list row (port of the iOS ConversationRowView):
 * unread-dot slot, avatar/avatar-stack, semibold name (+pin), relative
 * timestamp, 2-line snippet. Hover reveals quick actions; right-click opens
 * the row context menu.
 */
export function ConversationRow({ conversation, filter }: ConversationRowProps) {
  const unread = conversation.inboxUnreadCount > 0
  const names = conversation.displayName
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name !== '')
  const timeLabel =
    conversation.lastMessageDate > 0 ? formatTimestamp(conversation.lastMessageDate) : ''
  const unreadLabel = unread ? `${conversation.inboxUnreadCount} unread` : 'read'

  return (
    <ContextMenu
      trigger={
        <div className="group relative h-full">
          <Link
            to="/chats/$conversationId"
            params={{ conversationId: conversation.id }}
            search={{ filter }}
            aria-label={`${conversation.displayName}, ${unreadLabel}`}
            className="hover:bg-bg-elev focus-visible:outline-accent flex h-full items-center gap-2 px-2 focus-visible:-outline-offset-2 focus-visible:outline-2"
          >
            <span className="flex w-2.5 shrink-0 justify-center">{unread && <UnreadDot />}</span>
            {conversation.type === 'group' && names.length > 1 ? (
              <AvatarStack names={names} />
            ) : (
              <Avatar name={names[0] ?? conversation.displayName} />
            )}
            <span className="min-w-0 flex-1 pr-1">
              <span className="flex items-center gap-1.5">
                {conversation.pinned === 1 && <PinIcon className="text-fg-muted size-3 shrink-0" />}
                <span className="min-w-0 truncate font-semibold">{conversation.displayName}</span>
                <span className="text-fg-muted ml-auto shrink-0 pl-2 text-xs">{timeLabel}</span>
              </span>
              <span className="text-fg-muted mt-0.5 line-clamp-2 text-sm">
                {conversation.snippet}
              </span>
            </span>
          </Link>
          <RowActions conversationId={conversation.id} unread={unread} />
        </div>
      }
    >
      <RowContextMenuItems conversationId={conversation.id} unread={unread} />
    </ContextMenu>
  )
}
