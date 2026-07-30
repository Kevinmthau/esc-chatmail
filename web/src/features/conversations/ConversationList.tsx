import { useVirtualizer } from '@tanstack/react-virtual'
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react'
import { Skeleton } from '@/components/ui/Skeleton'
import type { SyncProgress } from '@/db/kv'
import { CONVERSATION_ROW_HEIGHT } from '@/lib/constants'
import { useConversationPage, useSyncStatus } from '@/live/hooks'
import type { ConversationPage } from '@/live/queries'
import { ConversationRow } from './ConversationRow'
import { EnvelopeIcon, SearchIcon } from './icons'
import { useConversationSelection } from './selection'
import { isFirstSyncPending, syncProgressDetail } from './syncState'

const PAGE_SIZE = 50
/** Raise the page limit when the viewport reaches the last N rows. */
const LOAD_MORE_THRESHOLD_ROWS = 10

/**
 * The roving tab stop: the loaded index plus the conversation id it was
 * anchored to. Ids survive list reorders; bare indexes do not.
 */
interface ActiveAnchor {
  index: number
  id: string | null
}

interface ConversationListProps {
  filter?: 'unread'
  /** Committed search query; undefined/'' means not searching. */
  query?: string
  /** Demo mode seeds every fixture up front and never syncs: zero rows is empty. */
  demo?: boolean
}

/**
 * Virtualized conversation list (fixed 88px rows, pinned block first, then
 * unpinned newest-first). Scrolling near the end raises the live-query limit
 * by one page (infinite scroll).
 */
export function ConversationList({ filter, query = '', demo = false }: ConversationListProps) {
  const [limit, setLimit] = useState(PAGE_SIZE)

  // A new query or filter starts over at one page. Carrying a limit grown by
  // infinite scroll into a fresh search would make each committed keystroke
  // cursor-walk for hundreds of matches nobody has scrolled to yet. The reset
  // happens during render (React's adjust-state-on-prop-change pattern), not
  // in an effect: an effect runs a render late, which would let exactly one
  // full-width walk through at the old grown limit before the reset lands.
  const [pageKey, setPageKey] = useState({ query, filter })
  if (pageKey.query !== query || pageKey.filter !== filter) {
    setPageKey({ query, filter })
    setLimit(PAGE_SIZE)
  }

  const page = useConversationPage(filter === 'unread', query, limit)
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

  // APG roving tabindex for the select-mode listbox: one tab stop (the active
  // option) instead of one per row, moved by the arrow keys. The anchor lives
  // here rather than in the rows or the selection context because moving it
  // must also drive the virtualizer, which may not even have the target
  // option in the DOM yet.
  const [activeAnchor, setActiveAnchor] = useState<ActiveAnchor>({ index: 0, id: null })
  const pendingFocusIndexRef = useRef<number | null>(null)
  // A select-mode flip restarts the tab stop at the first option (APG: with
  // nothing selected, the first option is the one tabbable) and abandons any
  // focus move still waiting on the virtualizer. Render-time adjust, same
  // pattern as pageKey above.
  const [activeModeKey, setActiveModeKey] = useState(selecting)
  if (activeModeKey !== selecting) {
    setActiveModeKey(selecting)
    setActiveAnchor({ index: 0, id: null })
    pendingFocusIndexRef.current = null
  }
  // The id wins while its row is still loaded: sync churn reorders this
  // newest-first list under an open selection (new mail bumps rows to the
  // top) without moving DOM focus, and an index-only rove would go stale and
  // aim the next arrow press at the wrong neighbor. A pruned (or
  // never-focused) anchor falls back to the remembered index, clamped to the
  // new end.
  const anchoredIndex =
    activeAnchor.id === null ? -1 : rows.findIndex((row) => row.id === activeAnchor.id)
  const activeIndex =
    anchoredIndex >= 0
      ? anchoredIndex
      : Math.min(activeAnchor.index, Math.max(rows.length - 1, 0))

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

  // A fresh query or filter also starts back at the top. A deep scroll offset
  // carried across would clamp into the shorter result set — mis-positioning
  // the new results and making the load-more effect below re-grow the limit
  // the reset above just cleared. Declared before that effect so the reset
  // scroll position is what it observes.
  useEffect(() => {
    if (parentRef.current !== null) parentRef.current.scrollTop = 0
  }, [query, filter])

  useEffect(() => {
    if (hasMore && lastVisibleIndex >= rows.length - LOAD_MORE_THRESHOLD_ROWS) {
      setLimit((current) => current + PAGE_SIZE)
    }
  }, [hasMore, lastVisibleIndex, rows.length])

  // Arrow keys move the active option; Home/End jump the loaded window's
  // ends. Handled on the listbox, where the indices and the virtualizer
  // live — the row handles only Space/Enter and lets these bubble up.
  // preventDefault keeps the scroller's native keyboard scrolling from
  // moving the viewport a second time.
  const moveActiveOption = (event: KeyboardEvent<HTMLDivElement>): void => {
    // Modified presses are not plain moves (Shift+Arrow is the APG range
    // extension, Cmd/Ctrl combos are platform scroll shortcuts); none are
    // implemented here, so leave them to the browser rather than swallowing
    // them as single-row moves.
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return
    if (rows.length === 0) return
    let next: number
    switch (event.key) {
      case 'ArrowDown':
        next = Math.min(activeIndex + 1, rows.length - 1)
        break
      case 'ArrowUp':
        next = Math.max(activeIndex - 1, 0)
        break
      case 'Home':
        next = 0
        break
      case 'End':
        next = rows.length - 1
        break
      default:
        return
    }
    event.preventDefault()
    if (next === activeIndex) return
    setActiveAnchor({ index: next, id: rows[next]?.id ?? null })
    // The target option may be virtualized out of the DOM. Scroll it into
    // the window; the effect below moves focus once it exists.
    pendingFocusIndexRef.current = next
    virtualizer.scrollToIndex(next)
  }

  // Focus the option a keyboard move targeted. A layout effect so the
  // hand-off lands before paint — after a long jump the same commit unmounts
  // the previously focused option, and a passive effect would let screen
  // readers observe focus falling to <body> for a frame. Deliberately no dep
  // list: the target only renders once the virtualizer has processed the
  // scroll, an extra render later — watch every render until it appears.
  // Focus moves only for pending moves the keyboard handler queued.
  useLayoutEffect(() => {
    const pending = pendingFocusIndexRef.current
    if (pending === null) return
    if (pending >= rows.length) {
      pendingFocusIndexRef.current = null
      return
    }
    const option = parentRef.current?.querySelector<HTMLElement>(
      `[data-index="${String(pending)}"] [role="option"]`,
    )
    if (option == null) return
    pendingFocusIndexRef.current = null
    option.focus()
  })

  if (view === undefined) return <SkeletonRows />
  if (rows.length === 0) {
    // Zero rows is ambiguous until the first sync delivers: an initial sync
    // fetches and persists a whole 500-message page before anything lands in
    // Dexie, so a real inbox reads as empty for minutes. That ambiguity covers
    // searches too — "No results" would be as false a claim as "no
    // conversations yet" while the mailbox has not arrived. Only once a sync
    // has delivered does an empty result mean anything.
    if (status === undefined) return <SkeletonRows />
    if (!demo && isFirstSyncPending(status)) return <SyncingState status={status} />
    // A search that found nothing is its own answer — never the mailbox-level
    // "no conversations yet", which would read as data loss mid-query.
    if (query !== '') return <NoResultsState query={query} />
    return <EmptyState filter={filter} />
  }

  // The active option can be scrolled clean out of the DOM by the mouse; the
  // first rendered option then stands in as the tab stop so the listbox never
  // drops out of the tab order. Focus landing on any option (Tab, click, the
  // stand-in) re-anchors the rove there via onFocus below.
  const activeRendered = items.some((item) => item.index === activeIndex)

  return (
    <div
      ref={parentRef}
      className="h-full overflow-y-auto"
      // Listbox semantics only in select mode: outside it the rows are links,
      // which are not options.
      role={selecting ? 'listbox' : undefined}
      aria-multiselectable={selecting ? true : undefined}
      aria-label={selecting ? 'Conversations' : undefined}
      onKeyDown={selecting ? moveActiveOption : undefined}
    >
      <div
        // Like the positioning wrappers below, the sizing block must vanish
        // from the accessibility tree so options are the listbox's only
        // meaningful descendants.
        role={selecting ? 'presentation' : undefined}
        className="relative w-full"
        style={{ height: virtualizer.getTotalSize() }}
      >
        {items.map((item) => {
          const conversation = rows[item.index]
          if (conversation === undefined) return null
          return (
            <div
              key={conversation.id}
              data-index={item.index}
              // The virtualizer's positioning wrapper must not sit between the
              // listbox and its options in the accessibility tree.
              role={selecting ? 'presentation' : undefined}
              onFocus={
                selecting
                  ? () => {
                      setActiveAnchor({ index: item.index, id: conversation.id })
                    }
                  : undefined
              }
              className="absolute inset-x-0 top-0"
              style={{ height: item.size, transform: `translateY(${item.start}px)` }}
            >
              <ConversationRow
                conversation={conversation}
                filter={filter}
                query={query}
                selecting={selecting}
                selected={selectedIds.has(conversation.id)}
                onToggleSelect={toggleSelection}
                tabbable={item.index === activeIndex || (!activeRendered && item === items[0])}
                posInSet={item.index + 1}
                // ARIA: -1 means "total unknown" — the loaded count is only
                // the true set size once the last page is in.
                setSize={hasMore ? -1 : rows.length}
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

/**
 * Search found nothing. Deliberately distinct from EmptyState: the mailbox is
 * fine, the query just missed — and naming the search's scope explains why a
 * word the user remembers from deep inside a thread does not surface it.
 */
function NoResultsState({ query }: { query: string }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-1 px-8 text-center">
      <SearchIcon className="text-fg-muted mb-1 size-10" />
      <p className="font-semibold">No results for “{query}”</p>
      <p className="text-fg-muted text-sm">Search matches chat names and message previews.</p>
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
