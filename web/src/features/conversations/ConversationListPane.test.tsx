import { cleanup, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SyncProgress } from '@/db/kv'
import type { ConversationRow as ConversationRecord } from '@/db/types'
import { matchesConversationSearch } from '@/lib/conversationSearch'
import type { ConversationPage } from '@/live/queries'
import { convoRow } from '@/outbox/testSupport'
import { ConversationListPane } from './ConversationListPane'
import { renderWithRouter } from './testSupport'

// End-to-end through the real router: SearchField writes ?q=, the layout reads
// it back, and the list re-queries. Only the Dexie layer is stubbed — with the
// same predicate the real query uses, so this exercises the wiring rather than
// re-testing the matcher (see lib/conversationSearch.test.ts for that).

const SYNCED: SyncProgress = { phase: 'idle', lastSyncAt: 1_700_000_000_000 }

const CONVERSATIONS: ConversationRecord[] = [
  convoRow({ id: 'alice', displayName: 'Alice Chen', snippet: 'Lunch on Thursday?' }),
  convoRow({
    id: 'ben',
    displayName: 'Ben Ortiz',
    snippet: 'Got it, will review tonight.',
    inboxUnreadCount: 1,
  }),
  convoRow({ id: 'digest', displayName: 'The Daily Digest', snippet: 'Five things worth reading' }),
]

const seen: { unreadOnly: boolean; query: string; limit: number }[] = []

vi.mock('@/app/boot', () => ({ isDemoMode: () => true, getAccountEmail: () => null }))
vi.mock('@/data/actions', () => ({
  requestSync: vi.fn(async () => {}),
  archiveConversation: vi.fn(async () => {}),
  toggleConversationRead: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
}))
vi.mock('@/live/hooks', () => ({
  useSyncStatus: () => SYNCED,
  useConversationPage: (unreadOnly: boolean, query: string, limit: number): ConversationPage => {
    seen.push({ unreadOnly, query, limit })
    const rows = CONVERSATIONS.filter(
      (c) => (!unreadOnly || c.inboxUnreadCount > 0) && matchesConversationSearch(c, query),
    )
    return { pinned: [], unpinned: rows.slice(0, limit), hasMore: rows.length > limit }
  },
}))

/** The pane renders the capsule twice (mobile bar + desktop header). */
const searchBoxes = () => screen.getAllByRole('searchbox', { name: 'Search conversations' })

/** jest-dom is not installed; read the input value directly. */
const valueOf = (el: HTMLElement | undefined) => (el as HTMLInputElement | undefined)?.value

beforeEach(() => {
  seen.length = 0
  // happy-dom has no layout; TanStack Virtual needs a non-zero outer size.
  vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(800)
  vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(380)
})

afterEach(cleanup)

describe('conversation search in the list pane', () => {
  it('filters rows as you type and restores them when cleared', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    await user.type(searchBoxes()[0]!, 'ortiz')

    await screen.findByText('Ben Ortiz')
    await waitFor(() => {
      expect(screen.queryByText('Alice Chen')).toBeNull()
    })
    expect(screen.queryByText('The Daily Digest')).toBeNull()

    await user.click(screen.getAllByRole('button', { name: 'Clear search' })[0]!)

    await screen.findByText('Alice Chen')
    await screen.findByText('The Daily Digest')
  })

  it('matches the snippet, not just the name', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    await user.type(searchBoxes()[0]!, 'thursday')

    await screen.findByText('Alice Chen')
    await waitFor(() => {
      expect(screen.queryByText('Ben Ortiz')).toBeNull()
    })
  })

  it('shows the search-specific empty state, not the no-conversations one', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    await user.type(searchBoxes()[0]!, 'zzz')

    await screen.findByText('No results for “zzz”')
    expect(screen.queryByText('No conversations yet')).toBeNull()
    expect(screen.queryByText('New mail will appear here as chats.')).toBeNull()
  })

  it('composes with the unread filter rather than replacing it', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />, '/chats?filter=unread')
    await screen.findByText('Ben Ortiz')
    expect(screen.queryByText('Alice Chen')).toBeNull()

    // 'chen' matches only Alice, who is read: the filter still applies.
    await user.type(searchBoxes()[0]!, 'chen')
    await screen.findByText('No results for “chen”')

    await waitFor(() => {
      expect(seen.at(-1)).toMatchObject({ unreadOnly: true, query: 'chen' })
    })
  })

  it('publishes the committed query to ?q= and restores it on reload', async () => {
    const user = userEvent.setup()
    const { router, unmount } = renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    await user.type(searchBoxes()[0]!, 'ortiz')
    await waitFor(() => {
      expect(router.state.location.search).toMatchObject({ q: 'ortiz' })
    })
    unmount()

    // A reload lands on the same URL: the field comes back filled and applied.
    renderWithRouter(<ConversationListPane />, '/chats?q=ortiz')
    await screen.findByText('Ben Ortiz')
    await waitFor(() => {
      expect(valueOf(searchBoxes()[0])).toBe('ortiz')
    })
    expect(screen.queryByText('Alice Chen')).toBeNull()
  })

  it('replaces rather than pushes, so Back does not retype the query', async () => {
    const user = userEvent.setup()
    const { router } = renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    const before = router.history.length
    await user.type(searchBoxes()[0]!, 'ortiz')
    await waitFor(() => {
      expect(router.state.location.search).toMatchObject({ q: 'ortiz' })
    })
    // Five keystrokes, zero new history entries.
    expect(router.history.length).toBe(before)
  })

  it('preserves the query into the chat route, so Back returns a searched list', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    await user.type(searchBoxes()[0]!, 'ortiz')
    const row = await screen.findByRole('link', { name: /Ben Ortiz/ })
    await waitFor(() => {
      expect(row.getAttribute('href')).toContain('q=ortiz')
    })
  })

  it('Escape clears the query and keeps focus in the field', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    const box = searchBoxes()[0]!
    await user.type(box, 'ortiz')
    await screen.findByText('Ben Ortiz')

    await user.keyboard('{Escape}')

    expect(valueOf(box)).toBe('')
    expect(document.activeElement).toBe(box)
    await screen.findByText('Alice Chen')
  })

  it('offers no clear button until there is something to clear', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    expect(screen.queryByRole('button', { name: 'Clear search' })).toBeNull()
    await user.type(searchBoxes()[0]!, 'o')
    expect(screen.getAllByRole('button', { name: 'Clear search' }).length).toBeGreaterThan(0)
  })

  it('keeps the mobile and desktop capsules in sync (one committed query)', async () => {
    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Alice Chen')

    const boxes = searchBoxes()
    expect(boxes).toHaveLength(2)
    await user.type(boxes[0]!, 'ortiz')

    await waitFor(() => {
      expect(valueOf(boxes[1])).toBe('ortiz')
    })
  })

  it('leaves the list unsearched when no query is present', async () => {
    renderWithRouter(<ConversationListPane />)
    const list = await screen.findByText('Alice Chen')
    expect(within(list.ownerDocument.body).getByText('Ben Ortiz')).toBeTruthy()
    expect(seen[0]).toMatchObject({ query: '' })
  })
})
