// Chat entry through the REAL useConversation: the live query resolves a turn
// after the id changes (undefined on mount, the previous chat's row on a
// desktop switch), so the entry decision must wait for the row of the chat
// being entered. Regression for "Mark unread, then open the chat within 30s:
// it stays unread" — with a synchronous mock of useConversation the entry
// path looks reachable, which is why these go through the real hook.

import { cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { markConversationRead } from '@/data/actions'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { convoRow, makeTestDb, msgRow } from '@/outbox/testSupport'
import { useAutoMarkRead } from './useAutoMarkRead'

vi.mock('@/data/actions', () => ({
  markConversationRead: vi.fn(async () => {}),
}))

const mockedMarkRead = vi.mocked(markConversationRead)

/** Debounce is 500ms; leave margin for the async suppression check. */
const SETTLE_MS = 900

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** A chat the user just marked unread from the list: one unread INBOX message, freshly stamped. */
async function seedFreshlyMarkedUnread(db: ChatmailDB, id: string): Promise<void> {
  await db.conversations.put(convoRow({ id, inboxUnreadCount: 1 }))
  await db.messages.put(
    msgRow({
      id: `${id}-m1`,
      conversationId: id,
      isUnread: 1,
      labelIds: ['INBOX'],
      localModifiedAt: Date.now(),
    }),
  )
}

describe('useAutoMarkRead: entry through the real live query', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = makeTestDb()
    setDBForTests(db)
  })

  afterEach(async () => {
    cleanup()
    setDBForTests(null)
    await db.delete()
    vi.clearAllMocks()
  })

  // Revert-check: the `resolved` gate in useAutoMarkRead (useAutoMarkRead.ts)
  it('marks read on mounting into a freshly marked-unread chat (row resolves after mount)', async () => {
    await seedFreshlyMarkedUnread(db, 'c1')

    renderHook(({ id }) => useAutoMarkRead(id), { initialProps: { id: 'c1' } })

    await vi.waitFor(() => expect(mockedMarkRead).toHaveBeenCalledWith('c1'), { timeout: 3000 })
  })

  it('marks read on switching to a freshly marked-unread chat (previous row served first)', async () => {
    await db.conversations.put(convoRow({ id: 'a', inboxUnreadCount: 0 }))
    await seedFreshlyMarkedUnread(db, 'b')

    const { result, rerender } = renderHook(({ id }) => useAutoMarkRead(id), {
      initialProps: { id: 'a' },
    })
    // Let chat A's row resolve, as it would have long before the user clicks B.
    await sleep(50)
    expect(result.current).toBeUndefined()
    expect(mockedMarkRead).not.toHaveBeenCalled()

    rerender({ id: 'b' })

    await vi.waitFor(() => expect(mockedMarkRead).toHaveBeenCalledWith('b'), { timeout: 3000 })
    expect(mockedMarkRead).not.toHaveBeenCalledWith('a')
  })

  it('still leaves an in-place mark-unread alone once the chat has been entered', async () => {
    await db.conversations.put(convoRow({ id: 'c1', inboxUnreadCount: 0 }))
    await db.messages.put(
      msgRow({ id: 'm1', conversationId: 'c1', isUnread: 0, labelIds: ['INBOX'] }),
    )
    renderHook(({ id }) => useAutoMarkRead(id), { initialProps: { id: 'c1' } })
    await sleep(50) // the row resolves: entry consumed with nothing to mark

    // "Mark unread" from the split-view list while the chat stays mounted.
    await db.messages.put(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        isUnread: 1,
        labelIds: ['INBOX'],
        localModifiedAt: Date.now(),
      }),
    )
    await db.conversations.put(convoRow({ id: 'c1', inboxUnreadCount: 1 }))

    await sleep(SETTLE_MS)
    expect(mockedMarkRead).not.toHaveBeenCalled()
  })
})
