import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useSyncExternalStore } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SyncProgress } from '@/db/kv'
import type { ConversationPage } from '@/live/queries'
import { convoRow } from '@/outbox/testSupport'
import { ConversationListPane } from './ConversationListPane'
import { renderWithRouter } from './testSupport'

/** An account whose first sync finished — the only state that means "empty". */
const SYNCED: SyncProgress = { phase: 'idle', lastSyncAt: 1_700_000_000_000 }

// The pane drives Select All from whatever the list has loaded, so these tests
// need to push a NEW page and re-render. A tiny external store does that
// without reaching into the virtualizer.
const listeners = new Set<() => void>()
let currentPage: ConversationPage | undefined
const getPage = (): ConversationPage | undefined => currentPage
const subscribePage = (listener: () => void): (() => void) => {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
function setPage(next: ConversationPage): void {
  currentPage = next
  act(() => {
    for (const listener of listeners) listener()
  })
}

vi.mock('@/live/hooks', () => ({
  useConversationPage: () => useSyncExternalStore(subscribePage, getPage),
  useSyncStatus: () => SYNCED,
}))

vi.mock('@/app/boot', () => ({
  isDemoMode: () => false,
  getAccountEmail: () => 'tester@example.com',
  signOut: vi.fn(async () => {}),
}))

vi.mock('@/data/actions', () => ({
  archiveConversation: vi.fn(async () => {}),
  markConversationRead: vi.fn(async () => {}),
  toggleConversationRead: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
  requestSync: vi.fn(async () => {}),
}))

import { archiveConversation, reportSpam } from '@/data/actions'

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

function renderPane(initial: ConversationPage = THREE_ROWS) {
  currentPage = initial
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

describe('ConversationListPane multi-select', () => {
  // Auto-cleanup is off (no vitest globals); unmount between tests explicitly.
  afterEach(() => {
    cleanup()
    listeners.clear()
  })

  // happy-dom has no layout: offsetWidth/offsetHeight are 0, which makes
  // TanStack Virtual's outerSize 0 and its range empty. Give elements a size
  // so virtual rows render.
  beforeEach(() => {
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(800)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(380)
    vi.mocked(archiveConversation).mockReset().mockResolvedValue(undefined)
    vi.mocked(reportSpam).mockReset().mockResolvedValue(undefined)
  })

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
