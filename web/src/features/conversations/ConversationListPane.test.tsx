// The pane's two modes, one harness. Multi-select drives explicit pages
// through an external store (setPage), search drives a fixture array through
// the same predicate the real query layer uses; both go through the real
// router so ?q= wiring and selection semantics are exercised together.

import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useSyncExternalStore } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SyncProgress } from '@/db/kv'
import type { ConversationRow as ConversationRecord } from '@/db/types'
import { matchesConversationSearch } from '@/lib/conversationSearch'
import type { ConversationPage } from '@/live/queries'
import { convoRow } from '@/outbox/testSupport'
import { ConversationListPane } from './ConversationListPane'
import { renderWithRouter } from './testSupport'

/** An account whose first sync finished — the only state that means "empty". */
const SYNCED: SyncProgress = { phase: 'idle', lastSyncAt: 1_700_000_000_000 }

// Mutable knobs (reset in beforeEach) so individual tests can drive demo mode,
// the sync state, and the fixture set. The mock factories only close over
// them, so vi.mock hoisting is safe.
let demoMode = true
let syncStatus: SyncProgress | undefined = SYNCED
let conversations: ConversationRecord[] = []

// Multi-select tests push whole pages and re-render through this external
// store; while an override is set it wins over the fixture array.
const listeners = new Set<() => void>()
let pageOverride: ConversationPage | undefined
const getPage = (): ConversationPage | undefined => pageOverride
const subscribePage = (listener: () => void): (() => void) => {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
function setPage(next: ConversationPage): void {
  pageOverride = next
  act(() => {
    for (const listener of listeners) listener()
  })
}

const seen: { unreadOnly: boolean; query: string; limit: number }[] = []

vi.mock('@/app/boot', () => ({
  isDemoMode: () => demoMode,
  getAccountEmail: () => 'tester@example.com',
  signOut: vi.fn(async () => {}),
}))

vi.mock('@/data/actions', () => ({
  requestSync: vi.fn(async () => {}),
  archiveConversation: vi.fn(async () => {}),
  markConversationRead: vi.fn(async () => {}),
  toggleConversationRead: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
}))

vi.mock('@/live/hooks', () => ({
  useSyncStatus: () => syncStatus,
  useConversationPage: (
    unreadOnly: boolean,
    query: string,
    limit: number,
  ): ConversationPage | undefined => {
    const override = useSyncExternalStore(subscribePage, getPage)
    seen.push({ unreadOnly, query, limit })
    if (override !== undefined) return override
    const rows = conversations.filter(
      (c) => (!unreadOnly || c.inboxUnreadCount > 0) && matchesConversationSearch(c, query),
    )
    return { pinned: [], unpinned: rows.slice(0, limit), hasMore: rows.length > limit }
  },
}))

import { archiveConversation, reportSpam } from '@/data/actions'

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

const THREE_ROWS: ConversationPage = {
  pinned: [],
  unpinned: [
    convoRow({ id: 'c1', displayName: 'Alice Chen', inboxUnreadCount: 2 }),
    convoRow({ id: 'c2', displayName: 'Ben Ortiz' }),
    convoRow({ id: 'c3', displayName: 'Chloe Park' }),
  ],
  hasMore: false,
}

function page(rows: ConversationPage['unpinned'], hasMore = false): ConversationPage {
  return { pinned: [], unpinned: rows, hasMore }
}

/** The pane renders the capsule twice (mobile bar + desktop header). */
const searchBoxes = () => screen.getAllByRole('searchbox', { name: 'Search conversations' })

/** jest-dom is not installed; read the input value directly. */
const valueOf = (el: HTMLElement | undefined) => (el as HTMLInputElement | undefined)?.value

function renderPane(initial: ConversationPage = THREE_ROWS) {
  pageOverride = initial
  return renderWithRouter(<ConversationListPane />)
}

/** Enters select mode and returns the rendered options. */
async function enterSelectMode(): Promise<HTMLElement[]> {
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  return screen.findAllByRole('option')
}

function optionNamed(name: string): HTMLElement {
  return screen.getByRole('option', { name: new RegExp(`^${name},`) })
}

beforeEach(() => {
  seen.length = 0
  demoMode = true
  syncStatus = SYNCED
  conversations = CONVERSATIONS
  pageOverride = undefined
  // happy-dom has no layout; TanStack Virtual needs a non-zero outer size.
  vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(800)
  vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(380)
  vi.mocked(archiveConversation).mockReset().mockResolvedValue(undefined)
  vi.mocked(reportSpam).mockReset().mockResolvedValue(undefined)
})

afterEach(() => {
  cleanup()
  listeners.clear()
})

describe('ConversationListPane multi-select', () => {
  it('entering select mode suppresses navigation and shows checkmark circles', async () => {
    const { container } = renderPane()
    // Out of select mode the rows are links into the chat.
    expect(await screen.findAllByRole('link')).toHaveLength(3)

    const options = await enterSelectMode()

    expect(options).toHaveLength(3)
    expect(screen.queryAllByRole('link')).toHaveLength(0)
    expect(container.querySelectorAll('svg[data-icon="circle"]')).toHaveLength(3)
    expect(container.querySelector('svg[data-icon="check-circle"]')).toBeNull()

    // The rows carry no controls of their own any more — the hover quick
    // actions are gone along with the link.
    const listbox = container.querySelector<HTMLElement>('[role="listbox"]')!
    expect(within(listbox).queryAllByRole('button')).toHaveLength(0)
  })

  it('marks the list multiselectable and reflects selection with aria-selected', async () => {
    const { container } = renderPane()
    await enterSelectMode()

    const listbox = container.querySelector('[role="listbox"]')
    expect(listbox?.getAttribute('aria-multiselectable')).toBe('true')

    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')

    expect(optionNamed('Alice Chen').getAttribute('aria-selected')).toBe('true')
    expect(optionNamed('Ben Ortiz').getAttribute('aria-selected')).toBe('false')
    expect(container.querySelectorAll('svg[data-icon="check-circle"]')).toHaveLength(1)

    fireEvent.click(optionNamed('Chloe Park'))
    await screen.findByText('2 Selected')
    expect(optionNamed('Chloe Park').getAttribute('aria-selected')).toBe('true')
  })

  it('toggles a row with the Space key', async () => {
    renderPane()
    await enterSelectMode()

    fireEvent.keyDown(optionNamed('Ben Ortiz'), { key: ' ' })
    await screen.findByText('1 Selected')
    expect(optionNamed('Ben Ortiz').getAttribute('aria-selected')).toBe('true')

    fireEvent.keyDown(optionNamed('Ben Ortiz'), { key: ' ' })
    await screen.findByText('0 Selected')
    expect(optionNamed('Ben Ortiz').getAttribute('aria-selected')).toBe('false')
  })

  it('Select All covers the loaded page only, and reverts once more rows load', async () => {
    renderPane(page(THREE_ROWS.unpinned, true))
    await enterSelectMode()

    fireEvent.click(screen.getByRole('button', { name: 'Select All' }))
    await screen.findByText('3 Selected')
    expect(screen.getByRole('button', { name: 'Deselect All' })).toBeTruthy()
    for (const option of screen.getAllByRole('option')) {
      expect(option.getAttribute('aria-selected')).toBe('true')
    }

    // Paging in more rows must not retroactively select them (iOS selectAll
    // takes the loaded window), so the control offers "Select All" again.
    setPage(
      page([
        ...THREE_ROWS.unpinned,
        convoRow({ id: 'c4', displayName: 'Dana Reed' }),
        convoRow({ id: 'c5', displayName: 'Eli Novak' }),
      ]),
    )
    await screen.findByRole('button', { name: 'Select All' })
    expect(screen.getByText('3 Selected')).toBeTruthy()
    expect(optionNamed('Dana Reed').getAttribute('aria-selected')).toBe('false')

    // Now Select All covers all five, and toggling again clears everything.
    fireEvent.click(screen.getByRole('button', { name: 'Select All' }))
    await screen.findByText('5 Selected')
    fireEvent.click(screen.getByRole('button', { name: 'Deselect All' }))
    await screen.findByText('0 Selected')
  })

  it('drops rows that leave the list out of the selection', async () => {
    renderPane()
    await enterSelectMode()
    fireEvent.click(screen.getByRole('button', { name: 'Select All' }))
    await screen.findByText('3 Selected')

    // A sync (or another tab) archives one of the selected conversations.
    setPage(page(THREE_ROWS.unpinned.filter((row) => row.id !== 'c2')))
    await screen.findByText('2 Selected')
  })

  it('batch archive dispatches once per selected conversation and exits select mode', async () => {
    renderPane()
    await enterSelectMode()

    fireEvent.click(optionNamed('Alice Chen'))
    fireEvent.click(optionNamed('Chloe Park'))
    await screen.findByText('2 Selected')

    fireEvent.click(screen.getByRole('button', { name: 'Archive 2 conversations' }))

    // Exiting select mode restores the normal header and the row links.
    await screen.findByRole('button', { name: 'Select' })
    expect(vi.mocked(archiveConversation).mock.calls).toEqual([['c1'], ['c3']])
    expect(screen.queryAllByRole('option')).toHaveLength(0)
    expect(screen.queryByText('2 Selected')).toBeNull()
  })

  it('batch spam reports every selected conversation and exits select mode', async () => {
    renderPane()
    await enterSelectMode()
    fireEvent.click(screen.getByRole('button', { name: 'Select All' }))
    await screen.findByText('3 Selected')

    fireEvent.click(screen.getByRole('button', { name: 'Report 3 conversations as spam' }))

    await screen.findByRole('button', { name: 'Select' })
    expect(vi.mocked(reportSpam).mock.calls).toEqual([['c1'], ['c2'], ['c3']])
  })

  it('a partial failure keeps select mode with only the failed rows selected', async () => {
    vi.mocked(archiveConversation).mockImplementation((conversationId: string) =>
      conversationId === 'c3' ? Promise.reject(new Error('offline')) : Promise.resolve(),
    )
    renderPane()
    await enterSelectMode()
    fireEvent.click(screen.getByRole('button', { name: 'Select All' }))
    await screen.findByText('3 Selected')

    fireEvent.click(screen.getByRole('button', { name: 'Archive 3 conversations' }))

    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toBe('Could not archive 1 conversation. Try again.')
    // Still in select mode, and only the conversation that did not land is
    // selected — the UI never claims a success it did not get.
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeTruthy()
    expect(screen.getByText('1 Selected')).toBeTruthy()
    expect(optionNamed('Chloe Park').getAttribute('aria-selected')).toBe('true')
    expect(optionNamed('Alice Chen').getAttribute('aria-selected')).toBe('false')
    expect(screen.getByRole('button', { name: 'Archive 1 conversation' })).toBeTruthy()
  })

  it('disables the batch actions while nothing is selected', async () => {
    renderPane()
    await enterSelectMode()

    const archive = screen.getByRole('button', { name: 'Archive' })
    const spam = screen.getByRole('button', { name: 'Report spam' })
    expect(archive.hasAttribute('disabled')).toBe(true)
    expect(spam.hasAttribute('disabled')).toBe(true)

    fireEvent.click(archive)
    expect(vi.mocked(archiveConversation)).not.toHaveBeenCalled()
  })

  it('Cancel and Escape both leave select mode and clear the selection', async () => {
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await screen.findByRole('button', { name: 'Select' })

    // Re-entering starts from an empty selection.
    await enterSelectMode()
    expect(screen.getByText('0 Selected')).toBeTruthy()
    expect(optionNamed('Alice Chen').getAttribute('aria-selected')).toBe('false')

    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')
    fireEvent.keyDown(document, { key: 'Escape' })
    await screen.findByRole('button', { name: 'Select' })

    await enterSelectMode()
    expect(screen.getByText('0 Selected')).toBeTruthy()
  })

  it('Escape already claimed by an overlay (defaultPrevented) keeps select mode', async () => {
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')

    // A Radix-style overlay dismisses on Escape from a capture-phase document
    // listener and preventDefaults; the selection's bubble-phase listener must
    // then leave the mode (and the selection) alone.
    const claim = (event: KeyboardEvent): void => {
      event.preventDefault()
    }
    document.addEventListener('keydown', claim, { capture: true })
    try {
      fireEvent.keyDown(document.body, { key: 'Escape' })
    } finally {
      document.removeEventListener('keydown', claim, { capture: true })
    }

    expect(screen.getByText('1 Selected')).toBeTruthy()
    expect(optionNamed('Alice Chen').getAttribute('aria-selected')).toBe('true')
  })

  it('Escape defers to an open modal dialog', async () => {
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')

    const dialog = document.createElement('dialog')
    dialog.setAttribute('open', '')
    document.body.append(dialog)
    try {
      fireEvent.keyDown(document.body, { key: 'Escape' })
    } finally {
      dialog.remove()
    }

    expect(screen.getByText('1 Selected')).toBeTruthy()
  })

  it('a batch that fails after Cancel does not resurrect the dead session', async () => {
    let rejectArchive: ((error: Error) => void) | undefined
    vi.mocked(archiveConversation).mockImplementation(
      () =>
        new Promise<void>((_resolve, reject) => {
          rejectArchive = reject
        }),
    )
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')
    fireEvent.click(screen.getByRole('button', { name: 'Archive 1 conversation' }))

    // Cancel while the archive is still in flight…
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await screen.findByRole('button', { name: 'Select' })

    // …then it fails. The stale outcome must not surface anywhere.
    await act(async () => {
      rejectArchive?.(new Error('offline'))
      await Promise.resolve()
    })
    expect(screen.queryByRole('alert')).toBeNull()

    // A fresh session starts empty, with no phantom selection or notice.
    await enterSelectMode()
    expect(screen.getByText('0 Selected')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(optionNamed('Alice Chen').getAttribute('aria-selected')).toBe('false')
  })

  it('a batch that finishes after Cancel and re-entry leaves the new session alone', async () => {
    let resolveArchive: (() => void) | undefined
    vi.mocked(archiveConversation).mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          resolveArchive = resolve
        }),
    )
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')
    fireEvent.click(screen.getByRole('button', { name: 'Archive 1 conversation' }))

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await screen.findByRole('button', { name: 'Select' })
    await enterSelectMode()
    fireEvent.click(optionNamed('Chloe Park'))
    await screen.findByText('1 Selected')

    // The old batch completing cleanly must not force-exit the new session or
    // touch its selection.
    await act(async () => {
      resolveArchive?.()
      await Promise.resolve()
    })
    expect(screen.getByText('1 Selected')).toBeTruthy()
    expect(optionNamed('Chloe Park').getAttribute('aria-selected')).toBe('true')
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeTruthy()
  })

  it('moves focus to the heading on entry and back to Select on exit', async () => {
    renderPane()
    await enterSelectMode()
    expect(document.activeElement?.textContent).toBe('0 Selected')

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    const select = await screen.findByRole('button', { name: 'Select' })
    expect(document.activeElement).toBe(select)
  })

  it('a committed search query change exits select mode', async () => {
    const user = userEvent.setup()
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')

    // The desktop capsule stays live in select mode; a committed keystroke
    // reshapes the loaded window (new id set, limit and scroll reset), so the
    // mode ends rather than letting the selection be silently pruned.
    await user.type(searchBoxes()[0]!, 'ben')
    await screen.findByRole('button', { name: 'Select' })
    expect(screen.queryByText(/Selected/)).toBeNull()
  })

  it('clears a failure notice when select mode is left', async () => {
    vi.mocked(archiveConversation).mockRejectedValue(new Error('offline'))
    renderPane()
    await enterSelectMode()
    fireEvent.click(optionNamed('Alice Chen'))
    await screen.findByText('1 Selected')
    fireEvent.click(screen.getByRole('button', { name: 'Archive 1 conversation' }))
    await screen.findByRole('alert')

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await screen.findByRole('button', { name: 'Select' })
    await enterSelectMode()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('keeps the header title in sync with the count', async () => {
    renderPane()
    await screen.findByRole('button', { name: 'Select' })
    const header = document.querySelector('header')!
    expect(within(header).getByText('Chats')).toBeTruthy()

    await enterSelectMode()
    expect(within(header).getByText('0 Selected')).toBeTruthy()

    fireEvent.click(optionNamed('Ben Ortiz'))
    await waitFor(() => {
      expect(within(header).getByText('1 Selected')).toBeTruthy()
    })
  })
})

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

  it('resets a scroll-grown page limit (and the scroll) when the query changes', async () => {
    // Enough rows that the first page leaves hasMore true, and a viewport tall
    // enough that the load-more effect raises the limit without real scrolling.
    conversations = Array.from({ length: 60 }, (_, i) =>
      convoRow({
        id: `c${String(i).padStart(3, '0')}`,
        displayName: `Person ${i}`,
        snippet: i < 10 ? 'moon landing' : 'hello there',
      }),
    )
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(8000)

    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Person 0')
    await waitFor(() => {
      expect(seen.some((call) => call.limit > 50)).toBe(true)
    })

    // A committed keystroke must start over at one page and from the top —
    // not cursor-walk at the grown limit into a stale scroll offset.
    const scroller = document.querySelector<HTMLElement>('.overflow-y-auto')!
    scroller.scrollTop = 2000
    await user.type(searchBoxes()[0]!, 'moon')
    await waitFor(() => {
      expect(seen.at(-1)).toMatchObject({ query: 'moon', limit: 50 })
    })
    expect(scroller.scrollTop).toBe(0)
  })

  it('shows the syncing state, not "No results", while the first sync is pending', async () => {
    // Zero rows during the initial sync means "mail has not arrived yet" — a
    // definitive "No results" for a query would be as false a claim as the
    // mailbox-level empty state.
    demoMode = false
    syncStatus = { phase: 'initial' }
    conversations = []

    const user = userEvent.setup()
    renderWithRouter(<ConversationListPane />)
    await screen.findByText('Syncing your mail…')

    await user.type(searchBoxes()[0]!, 'zzz')
    await waitFor(() => {
      expect(seen.at(-1)).toMatchObject({ query: 'zzz' })
    })
    expect(screen.getByText('Syncing your mail…')).toBeTruthy()
    expect(screen.queryByText('No results for “zzz”')).toBeNull()
  })

  it('leaves the list unsearched when no query is present', async () => {
    renderWithRouter(<ConversationListPane />)
    const list = await screen.findByText('Alice Chen')
    expect(within(list.ownerDocument.body).getByText('Ben Ortiz')).toBeTruthy()
    expect(seen[0]).toMatchObject({ query: '' })
  })
})
