// Chat header: mobile back link (filter-preserving), avatar + resolved display
// name, group participant-count subtitle, and the ellipsis menu with
// Archive / Report Spam (both navigate back to the list).

import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { useLiveQuery } from 'dexie-react-hooks'
import { Avatar } from '@/components/ui/Avatar'
import { IconButton } from '@/components/ui/IconButton'
import { Menu, MenuItem } from '@/components/ui/Menu'
import { Skeleton } from '@/components/ui/Skeleton'
import { archiveConversation, reportSpam } from '@/data/actions'
import { getDB } from '@/db/schema'
import { useConversation } from '@/live/hooks'

export function ChatHeader({ conversationId }: { conversationId: string }) {
  const conversation = useConversation(conversationId)
  const participantCount = useLiveQuery(
    () => getDB().convoParticipants.where('conversationId').equals(conversationId).count(),
    [conversationId],
  )
  const search = useSearch({ strict: false })
  const navigate = useNavigate()
  const listSearch = { filter: search.filter }

  const goBackToList = (): void => {
    void navigate({ to: '/chats', search: listSearch })
  }

  const onArchive = async (): Promise<void> => {
    await archiveConversation(conversationId)
    goBackToList()
  }

  const onReportSpam = async (): Promise<void> => {
    await reportSpam(conversationId)
    goBackToList()
  }

  const isGroup = conversation?.type === 'group'
  const displayName = conversation?.displayName ?? ''

  return (
    <header className="border-border bg-glass flex h-14 shrink-0 items-center gap-2 border-b px-2 backdrop-blur-xl">
      <Link
        to="/chats"
        search={listSearch}
        aria-label="Back to chats"
        className="text-accent hover:bg-bg-elev flex size-11 shrink-0 items-center justify-center rounded-full active:opacity-70 md:hidden"
      >
        <svg width="22" height="22" viewBox="0 0 22 22" fill="none" aria-hidden>
          <path
            d="M13.5 4.5L7 11l6.5 6.5"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </Link>

      <Avatar name={displayName} size="standard" className="size-9 text-[13px]" />

      <div className="min-w-0 flex-1">
        {conversation === undefined ? (
          <Skeleton className="h-5 w-40" />
        ) : (
          <>
            <h2 className="text-fg truncate text-[15px] font-semibold leading-tight">
              {displayName.trim().length > 0 ? displayName : 'Conversation'}
            </h2>
            {isGroup && (
              <p className="text-fg-muted truncate text-xs leading-tight">
                {`${participantCount ?? 0} participants`}
              </p>
            )}
          </>
        )}
      </div>

      <Menu
        trigger={
          <IconButton aria-label="Conversation actions">
            <svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
              <circle cx="4" cy="10" r="1.6" />
              <circle cx="10" cy="10" r="1.6" />
              <circle cx="16" cy="10" r="1.6" />
            </svg>
          </IconButton>
        }
      >
        <MenuItem onSelect={() => void onArchive()}>Archive</MenuItem>
        <MenuItem destructive onSelect={() => void onReportSpam()}>
          Report Spam
        </MenuItem>
      </Menu>
    </header>
  )
}
