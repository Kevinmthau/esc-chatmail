import { Link } from '@tanstack/react-router'
import { Avatar } from '@/components/ui/Avatar'
import { AvatarStack } from '@/components/ui/AvatarStack'
import { ContextMenu } from '@/components/ui/ContextMenu'
import { UnreadDot } from '@/components/ui/UnreadDot'
import type { ConversationRow as ConversationRecord } from '@/db/types'
import { cn } from '@/lib/cn'
import { formatTimestamp } from '@/lib/formatTimestamp'
import { CheckCircleIcon, CircleIcon, PinIcon } from './icons'
import { RowActions, RowContextMenuItems } from './RowActions'

interface ConversationRowProps {
  conversation: ConversationRecord
  /** Active list filter, preserved when navigating into the chat. */
  filter?: 'unread'
  /** Multi-select mode: the row toggles selection instead of navigating. */
  selecting?: boolean
  selected?: boolean
  onToggleSelect?: (conversationId: string) => void
}

/**
 * One 88px conversation list row (port of the iOS ConversationRowView):
 * unread-dot slot, avatar/avatar-stack, semibold name (+pin), relative
 * timestamp, 2-line snippet. Hover reveals quick actions; right-click opens
 * the row context menu.
 *
 * In multi-select mode the row becomes a listbox option: a leading
 * checkmark-circle, no link, no quick actions or context menu (iOS drops its
 * swipe actions the same way). Both modes lay out inside the same 88px box, so
 * the virtualizer's fixed row size holds either way.
 */
export function ConversationRow({
  conversation,
  filter,
  selecting = false,
  selected = false,
  onToggleSelect,
}: ConversationRowProps) {
  const unread = conversation.inboxUnreadCount > 0
  const names = conversation.displayName
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name !== '')
  const timeLabel =
    conversation.lastMessageDate > 0 ? formatTimestamp(conversation.lastMessageDate) : ''
  const unreadLabel = unread ? `${conversation.inboxUnreadCount} unread` : 'read'
  const rowLabel = `${conversation.displayName}, ${unreadLabel}`

  const body = (
    <>
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
        <span className="text-fg-muted mt-0.5 line-clamp-2 text-sm">{conversation.snippet}</span>
      </span>
    </>
  )

  if (selecting) {
    const toggle = (): void => onToggleSelect?.(conversation.id)
    return (
      <div
        role="option"
        aria-selected={selected}
        aria-label={rowLabel}
        tabIndex={0}
        onClick={toggle}
        onKeyDown={(event) => {
          // Space is the listbox idiom for toggling an option; Enter mirrors
          // the pointer affordance.
          if (event.key !== ' ' && event.key !== 'Enter') return
          event.preventDefault()
          toggle()
        }}
        className={cn(
          'focus-visible:outline-accent flex h-full cursor-default items-center gap-2 px-2',
          'focus-visible:-outline-offset-2 focus-visible:outline-2',
          selected ? 'bg-bg-elev' : 'hover:bg-bg-elev',
        )}
      >
        <span className="flex shrink-0 items-center justify-center pl-1">
          {selected ? (
            <CheckCircleIcon className="text-accent size-6" />
          ) : (
            <CircleIcon className="text-fg-muted size-6" />
          )}
        </span>
        {body}
      </div>
    )
  }

  return (
    <ContextMenu
      trigger={
        <div className="group relative h-full">
          <Link
            to="/chats/$conversationId"
            params={{ conversationId: conversation.id }}
            search={{ filter }}
            aria-label={rowLabel}
            className="hover:bg-bg-elev focus-visible:outline-accent flex h-full items-center gap-2 px-2 focus-visible:-outline-offset-2 focus-visible:outline-2"
          >
            {body}
          </Link>
          <RowActions conversationId={conversation.id} unread={unread} />
        </div>
      }
    >
      <RowContextMenuItems conversationId={conversation.id} unread={unread} />
    </ContextMenu>
  )
}
