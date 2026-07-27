import { cleanup, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SyncProgress } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { queryConversationList, type ConversationPage } from '@/live/queries'
import { convoRow, makeTestDb } from '@/outbox/testSupport'
import { ConversationList } from './ConversationList'
import { renderWithRouter } from './testSupport'

const pageRef: { current: ConversationPage | undefined } = { current: undefined }
const statusRef: { current: SyncProgress | undefined } = { current: undefined }

/** An account whose first sync finished — the only state that means "empty". */
const SYNCED: SyncProgress = { phase: 'idle', lastSyncAt: 1_700_000_000_000 }

vi.mock('@/live/hooks', () => ({
  useConversationPage: () => pageRef.current,
  useSyncStatus: () => statusRef.current,
}))

vi.mock('@/data/actions', () => ({
  archiveConversation: vi.fn(async () => {}),
  markConversationRead: vi.fn(async () => {}),
  toggleConversationRead: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
}))

describe('conversation list filtering (queryConversationList)', () => {
  let db: ChatmailDB | null = null

  afterEach(async () => {
    await db?.delete()
    db = null
  })

  it('filter=unread hides read rows in both the pinned block and the page', async () => {
    db = makeTestDb()
    await db.conversations.bulkAdd([
      convoRow({ id: 'read-1', displayName: 'Read One', inboxUnreadCount: 0 }),
      convoRow({ id: 'unread-1', displayName: 'Unread One', inboxUnreadCount: 2 }),
      convoRow({ id: 'pinned-read', displayName: 'Pinned Read', pinned: 1, inboxUnreadCount: 0 }),
      convoRow({
        id: 'pinned-unread',
        displayName: 'Pinned Unread',
        pinned: 1,
        inboxUnreadCount: 1,
      }),
    ])

    const unreadOnly = await queryConversationList(db, { unreadOnly: true, limit: 50 })
    expect(unreadOnly.pinned.map((c) => c.id)).toEqual(['pinned-unread'])
    expect(unreadOnly.unpinned.map((c) => c.id)).toEqual(['unread-1'])

    const all = await queryConversationList(db, { unreadOnly: false, limit: 50 })
    expect(all.pinned.map((c) => c.id)).toEqual(
      expect.arrayContaining(['pinned-read', 'pinned-unread']),
    )
    expect(all.unpinned).toHaveLength(2)
  })
})

describe('ConversationList rendering states', () => {
  // Auto-cleanup is off (no vitest globals); unmount between tests explicitly.
  afterEach(cleanup)

  // happy-dom has no layout: offsetWidth/offsetHeight are 0, which makes
  // TanStack Virtual's outerSize 0 and its range empty. Give elements a size
  // so virtual rows render. (restoreMocks resets these spies per test.)
  beforeEach(() => {
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(800)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(380)
    statusRef.current = SYNCED
  })

  it('shows skeleton rows while the page is loading', async () => {
    pageRef.current = undefined
    const { container } = renderWithRouter(<ConversationList />)
    await waitFor(() => {
      expect(container.querySelector('.animate-pulse')).not.toBeNull()
    })
  })

  it('shows the empty state when a completed sync found no conversations', async () => {
    pageRef.current = { pinned: [], unpinned: [], hasMore: false }
    renderWithRouter(<ConversationList />)
    await screen.findByText('No conversations yet')
    expect(screen.queryByText('Syncing your mail…')).toBeNull()
  })

  it('shows the unread empty state under the unread filter', async () => {
    pageRef.current = { pinned: [], unpinned: [], hasMore: false }
    renderWithRouter(<ConversationList filter="unread" />)
    await screen.findByText('No unread chats')
  })

  it('renders pinned rows before unpinned rows', async () => {
    pageRef.current = {
      pinned: [convoRow({ id: 'p1', displayName: 'Pinned Pat', pinned: 1 })],
      unpinned: [convoRow({ id: 'u1', displayName: 'Unpinned Uma' })],
      hasMore: false,
    }
    renderWithRouter(<ConversationList />)

    const pinned = await screen.findByText('Pinned Pat')
    const unpinned = await screen.findByText('Unpinned Uma')
    // Pinned row is laid out above the unpinned row.
    const top = (el: Element) =>
      Number.parseFloat(
        /translateY\((\d+(?:\.\d+)?)px\)/.exec(
          el.closest('[style]')?.getAttribute('style') ?? '',
        )?.[1] ?? 'NaN',
      )
    expect(top(pinned)).toBeLessThan(top(unpinned))
  })
})

describe('ConversationList first-run sync state', () => {
  afterEach(cleanup)

  beforeEach(() => {
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(800)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(380)
    pageRef.current = { pinned: [], unpinned: [], hasMore: false }
    statusRef.current = undefined
  })

  it('never claims the mailbox is empty while the initial sync is still running', async () => {
    // runInitialSync writes {phase:'initial', fetchedCount: 0} and does not
    // persist anything until the first 500-message page completes.
    statusRef.current = { phase: 'initial', fetchedCount: 0 }
    const { container } = renderWithRouter(<ConversationList />)

    await screen.findByText('Syncing your mail…')
    expect(screen.queryByText('No conversations yet')).toBeNull()
    expect(container.querySelector('.animate-pulse')).not.toBeNull()
  })

  it('does not claim "all caught up" under the unread filter during the initial sync', async () => {
    statusRef.current = { phase: 'initial', fetchedCount: 0 }
    renderWithRouter(<ConversationList filter="unread" />)

    await screen.findByText('Syncing your mail…')
    expect(screen.queryByText('No unread chats')).toBeNull()
  })

  it('shows fetched/estimated progress once the counter moves', async () => {
    statusRef.current = { phase: 'initial', fetchedCount: 120, totalEstimate: 3000 }
    renderWithRouter(<ConversationList />)

    await screen.findByText('Syncing your mail…')
    await screen.findByText('120 of about 3000 messages')
  })

  it('holds off on the empty state after an evicted/never-synced boot', async () => {
    // phase idle, but no sync has ever completed (fresh install, evicted DB,
    // or offline fallback) — "No conversations yet" would be a lie.
    statusRef.current = { phase: 'idle' }
    renderWithRouter(<ConversationList />)

    await screen.findByText('Waiting to sync…')
    expect(screen.queryByText('No conversations yet')).toBeNull()
  })

  it('surfaces the last sync error while the first sync has not landed', async () => {
    statusRef.current = { phase: 'idle', lastError: 'Sign-in required' }
    renderWithRouter(<ConversationList />)

    const line = await screen.findByText('Last attempt failed — retrying.')
    expect(line.getAttribute('title')).toBe('Sign-in required')
    expect(screen.queryByText('No conversations yet')).toBeNull()
  })

  it('shows skeletons rather than the empty state before sync status resolves', async () => {
    statusRef.current = undefined
    const { container } = renderWithRouter(<ConversationList />)

    await waitFor(() => {
      expect(container.querySelector('.animate-pulse')).not.toBeNull()
    })
    expect(screen.queryByText('No conversations yet')).toBeNull()
  })

  it('renders rows regardless of sync phase', async () => {
    pageRef.current = {
      pinned: [],
      unpinned: [convoRow({ id: 'u1', displayName: 'Unpinned Uma' })],
      hasMore: false,
    }
    statusRef.current = { phase: 'initial', fetchedCount: 500, totalEstimate: 3000 }
    renderWithRouter(<ConversationList />)

    await screen.findByText('Unpinned Uma')
    expect(screen.queryByText('Syncing your mail…')).toBeNull()
  })

  it('keeps the caught-up empty state while an incremental sync polls', async () => {
    // setSyncProgress drops lastSyncAt for the duration of every run, so a
    // pure lastSyncAt check would flap this view on each poll.
    statusRef.current = { phase: 'incremental' }
    renderWithRouter(<ConversationList filter="unread" />)

    await screen.findByText('No unread chats')
    expect(screen.queryByText('Syncing your mail…')).toBeNull()
  })

  it('treats demo mode as fully seeded (fixtures never write sync progress)', async () => {
    statusRef.current = { phase: 'idle' }
    renderWithRouter(<ConversationList demo />)

    await screen.findByText('No conversations yet')
    expect(screen.queryByText('Waiting to sync…')).toBeNull()
  })
})
