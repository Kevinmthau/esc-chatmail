import { ContextMenuItem } from '@/components/ui/ContextMenu'
import { IconButton } from '@/components/ui/IconButton'
import { archiveConversation, reportSpam, toggleConversationRead } from '@/data/actions'
import { cn } from '@/lib/cn'
import { ArchiveIcon, MarkReadIcon, MarkUnreadIcon } from './icons'

interface RowActionsProps {
  conversationId: string
  /** Whether the conversation currently shows as unread. */
  unread: boolean
}

/**
 * Hover-revealed quick actions on a conversation row (web stand-in for the
 * iOS swipe actions): archive + toggle read. Revealed on row hover and on
 * keyboard focus.
 */
export function RowActions({ conversationId, unread }: RowActionsProps) {
  return (
    <div
      className={cn(
        'absolute inset-y-0 right-2 flex items-center gap-1',
        'opacity-0 focus-within:opacity-100 group-hover:opacity-100',
      )}
    >
      <IconButton
        aria-label={unread ? 'Mark read' : 'Mark unread'}
        className="bg-bg-elev size-8 shadow-sm"
        onClick={() => void toggleConversationRead(conversationId)}
      >
        {unread ? <MarkReadIcon className="size-4" /> : <MarkUnreadIcon className="size-4" />}
      </IconButton>
      <IconButton
        aria-label="Archive"
        className="bg-bg-elev size-8 shadow-sm"
        onClick={() => void archiveConversation(conversationId)}
      >
        <ArchiveIcon className="size-4" />
      </IconButton>
    </div>
  )
}

/** Context-menu items for a conversation row (Archive / read toggle / spam). */
export function RowContextMenuItems({ conversationId, unread }: RowActionsProps) {
  return (
    <>
      <ContextMenuItem onSelect={() => void archiveConversation(conversationId)}>
        Archive
      </ContextMenuItem>
      <ContextMenuItem onSelect={() => void toggleConversationRead(conversationId)}>
        {unread ? 'Mark read' : 'Mark unread'}
      </ContextMenuItem>
      <ContextMenuItem destructive onSelect={() => void reportSpam(conversationId)}>
        Report spam
      </ContextMenuItem>
    </>
  )
}
