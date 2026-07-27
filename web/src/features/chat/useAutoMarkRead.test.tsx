// Auto-mark-read triggers: entry marks unconditionally; an unread-count change
// while the chat stays mounted marks only when the unread state did NOT come
// from the user's own "Mark unread" (fresh localModifiedAt stamp). Regression
// for the desktop split view, where RowActions' mark-unread used to be
// auto-undone 500ms later by this hook.

import { cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { markConversationRead } from '@/data/actions'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { useConversation } from '@/live/hooks'
import { toggleConversationRead } from '@/outbox/messageActions'
import { convoRow, makeTestDb, msgRow, NOW } from '@/outbox/testSupport'
import { LOCAL_UNREAD_SUPPRESS_MS, isFreshLocalUnread, useAutoMarkRead } from './useAutoMarkRead'

vi.mock('@/data/actions', () => ({
  markConversationRead: vi.fn(async () => {}),
}))
vi.mock('@/live/hooks', () => ({
  useConversation: vi.fn(),
}))

const mockedMarkRead = vi.mocked(markConversationRead)
const mockedUseConversation = vi.mocked(useConversation)

/** Debounce is 500ms; leave margin for the async suppression check. */
const SETTLE_MS = 900

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function setUnreadCount(count: number): void {
  mockedUseConversation.mockReturnValue(convoRow({ id: 'c1', inboxUnreadCount: count }))
}

describe('useAutoMarkRead', () => {
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

  it('does not auto-undo an explicit mark-unread while the chat stays mounted', async () => {
    await db.conversations.put(convoRow({ id: 'c1', inboxUnreadCount: 0 }))
    await db.messages.put(
      msgRow({ id: 'm1', conversationId: 'c1', isUnread: 0, labelIds: ['INBOX'] }),
    )
    setUnreadCount(0)
    const { rerender } = renderHook(({ id }) => useAutoMarkRead(id), {
      initialProps: { id: 'c1' },
    })

    // User hits "Mark unread" on the row (split view: the chat stays mounted).
    // toggleConversationRead stamps a fresh localModifiedAt on the message.
    await toggleConversationRead(db, 'c1')
    setUnreadCount(1)
    rerender({ id: 'c1' })

    await sleep(SETTLE_MS)
    expect(mockedMarkRead).not.toHaveBeenCalled()
  })

  it('marks read on entering a chat with unread messages, even freshly stamped ones', async () => {
    await db.conversations.put(convoRow({ id: 'c1', inboxUnreadCount: 1 }))
    await db.messages.put(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        isUnread: 1,
        labelIds: ['INBOX'],
        localModifiedAt: Date.now(),
      }),
    )
    setUnreadCount(1)
    renderHook(({ id }) => useAutoMarkRead(id), { initialProps: { id: 'c1' } })

    await vi.waitFor(() => expect(mockedMarkRead).toHaveBeenCalledWith('c1'), { timeout: 3000 })
  })

  it('marks read when new mail arrives while the chat is mounted (no local stamp)', async () => {
    await db.conversations.put(convoRow({ id: 'c1', inboxUnreadCount: 0 }))
    setUnreadCount(0)
    const { rerender } = renderHook(({ id }) => useAutoMarkRead(id), {
      initialProps: { id: 'c1' },
    })

    // A genuinely new synced message: localModifiedAt is 0.
    await db.messages.put(
      msgRow({
        id: 'm2',
        conversationId: 'c1',
        isUnread: 1,
        labelIds: ['INBOX'],
        internalDate: NOW,
        localModifiedAt: 0,
      }),
    )
    setUnreadCount(1)
    rerender({ id: 'c1' })

    await vi.waitFor(() => expect(mockedMarkRead).toHaveBeenCalledWith('c1'), { timeout: 3000 })
  })
})

describe('isFreshLocalUnread', () => {
  const base = { conversationId: 'c1', isUnread: 1 as const, labelIds: ['INBOX'] }

  it('is false with no unread messages', () => {
    expect(isFreshLocalUnread([], NOW)).toBe(false)
  })

  it('is true when the newest unread message carries a fresh local stamp', () => {
    const messages = [msgRow({ id: 'm1', ...base, internalDate: NOW, localModifiedAt: NOW - 500 })]
    expect(isFreshLocalUnread(messages, NOW)).toBe(true)
  })

  it('is false once the stamp ages past the suppression window', () => {
    const messages = [
      msgRow({
        id: 'm1',
        ...base,
        internalDate: NOW,
        localModifiedAt: NOW - LOCAL_UNREAD_SUPPRESS_MS,
      }),
    ]
    expect(isFreshLocalUnread(messages, NOW)).toBe(false)
  })

  it('is governed by the NEWEST unread message: unstamped new mail wins over an older stamp', () => {
    const messages = [
      msgRow({ id: 'old', ...base, internalDate: NOW - 1000, localModifiedAt: NOW - 500 }),
      msgRow({ id: 'new', ...base, internalDate: NOW, localModifiedAt: 0 }),
    ]
    expect(isFreshLocalUnread(messages, NOW)).toBe(false)
  })
})
