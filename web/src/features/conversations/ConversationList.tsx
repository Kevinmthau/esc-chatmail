import { useVirtualizer } from '@tanstack/react-virtual'
import { useEffect, useMemo, useRef, useState } from 'react'
import { Skeleton } from '@/components/ui/Skeleton'
import type { SyncProgress } from '@/db/kv'
import { CONVERSATION_ROW_HEIGHT } from '@/lib/constants'
import { useConversationPage, useSyncStatus } from '@/live/hooks'
import type { ConversationPage } from '@/live/queries'
import { ConversationRow } from './ConversationRow'
import { EnvelopeIcon } from './icons'
import { useConversationSelection } from './selection'
import { isFirstSyncPending, syncProgressDetail } from './syncState'

const PAGE_SIZE = 50
/** Raise the page limit when the viewport reaches the last N rows. */
const LOAD_MORE_THRESHOLD_ROWS = 10

interface ConversationListProps {
  filter?: 'unread'
  /** Demo mode seeds every fixture up front and never syncs: zero rows is empty. */
  demo?: boolean
}

/**
 * Virtualized conversation list (fixed 88px rows, pinned block first, then
 * unpinned newest-first). Scrolling near the end raises the live-query limit
 * by one page (infinite scroll).
 */
export function ConversationList({ filter, demo = false }: ConversationListProps) {
  const [limit, setLimit] = useState(PAGE_SIZE)
  const page = useConversationPage(filter === 'unread', limit)
  const status = useSyncStatus()

  // Keep the last resolved page visible while a bigger limit re-resolves, so
  // load-more never flashes the skeletons.
  const lastPageRef = useRef<ConversationPage | undefined>(undefined)
  if (page !== undefined) lastPageRef.current = page
  const view = page ?? lastPageRef.current

  const rows = useMemo(() => (view ? [...view.pinned, ...view.unpinned] : []), [view])

  // Publish the loaded window to the selection context: Select All covers
  // exactly these rows, and rows that leave the list drop out of the selection.
  const { selecting, selectedIds, toggleSelection, registerSelectableIds } =
    useConversationSelection()
  const rowIds = useMemo(() => rows.map((row) => row.id), [rows])
  useEffect(() => {
    registerSelectableIds(rowIds)
  }, [rowIds, registerSelectableIds])

  const parentRef = useRef<HTMLDivElement>(null)
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => CONVERSATION_ROW_HEIGHT,
    overscan: 6,
    initialRect: { width: 380, height: 800 },
  })

  const items = virtualizer.getVirtualItems()
  const lastVisibleIndex = items.at(-1)?.index ?? 0
  const hasMore = view?.hasMore === true
  useEffect(() => {
    if (hasMore && lastVisibleIndex >= rows.length - LOAD_MORE_THRESHOLD_ROWS) {
      setLimit((current) => current + PAGE_SIZE)
    }
  }, [hasMore, lastVisibleIndex, rows.length])

  if (view === undefined) return <SkeletonRows />
  if (rows.length === 0) {
    // Zero rows is ambiguous: an initial sync fetches and persists a whole
    // 500-message page before anything lands in Dexie, so a real inbox reads
    // as empty for minutes. Only state that the mailbox is empty once a sync
    // has actually delivered; until then say that mail is still on its way.
    if (status === undefined) return <SkeletonRows />
    if (!demo && isFirstSyncPending(status)) return <SyncingState status={status} />
    return <EmptyState filter={filter} />
  }

  return (
    <div
      ref={parentRef}
      className="h-full overflow-y-auto"
      // Listbox semantics only in select mode: outside it the rows are links,
      // which are not options.
      role={selecting ? 'listbox' : undefined}
      aria-multiselectable={selecting ? true : undefined}
      aria-label={selecting ? 'Conversations' : undefined}
    >
      <div className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
        {items.map((item) => {
          const conversation = rows[item.index]
          if (conversation === undefined) return null
          return (
            <div
              key={conversation.id}
              // The virtualizer's positioning wrapper must not sit between the
              // listbox and its options in the accessibility tree.
              role={selecting ? 'presentation' : undefined}
              className="absolute inset-x-0 top-0"
              style={{ height: item.size, transform: `translateY(${item.start}px)` }}
            >
              <ConversationRow
                conversation={conversation}
                filter={filter}
                selecting={selecting}
                selected={selectedIds.has(conversation.id)}
                onToggleSelect={toggleSelection}
              />
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Zero rows because the first sync has not delivered anything yet. */
function SyncingState({ status }: { status: SyncProgress }) {
  const detail = syncProgressDetail(status)
  return (
    <div className="flex h-full min-h-0 flex-col">
      <div role="status" aria-live="polite" className="px-4 pt-4 pb-2 text-center">
        <p className="text-fg-muted text-sm font-medium">
          {status.phase === 'idle' ? 'Waiting to sync…' : 'Syncing your mail…'}
        </p>
        {detail !== undefined && <p className="text-fg-muted text-xs">{detail}</p>}
        {status.lastError !== undefined && (
          <p className="text-fg-muted text-xs" title={status.lastError}>
            Last attempt failed — retrying.
          </p>
        )}
      </div>
      <div className="min-h-0 flex-1 overflow-hidden">
        <SkeletonRows />
      </div>
    </div>
  )
}

function SkeletonRows() {
  return (
    <div aria-hidden className="px-3">
      {Array.from({ length: 8 }, (_, i) => (
        <div
          key={i}
          className="flex items-center gap-3"
          style={{ height: CONVERSATION_ROW_HEIGHT }}
        >
          <Skeleton className="size-11 rounded-full" />
          <div className="flex-1 space-y-2">
            <Skeleton className="h-3.5 w-1/3" />
            <Skeleton className="h-3 w-3/4" />
          </div>
        </div>
      ))}
    </div>
  )
}

function EmptyState({ filter }: { filter?: 'unread' }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-1 px-8 text-center">
      <EnvelopeIcon className="text-fg-muted mb-1 size-10" />
      <p className="font-semibold">
        {filter === 'unread' ? 'No unread chats' : 'No conversations yet'}
      </p>
      <p className="text-fg-muted text-sm">
        {filter === 'unread' ? 'You are all caught up.' : 'New mail will appear here as chats.'}
      </p>
    </div>
  )
}
