// Final-integration regressions for the compose wiring:
// 1. AliasPicker selection reaches data/actions.sendMessage as `fromAlias`.
// 2. "Open chat" (dedup banner) carries the typed body into that chat's
//    reply-bar draft via features/chat/useDraft's module map.

import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from '@tanstack/react-router'
import { cleanup, render, renderHook, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { ReplyBar } from '@/features/chat/ReplyBar'
import { clearDraftsForTests, useDraft } from '@/features/chat/useDraft'
import { convoRow, makeTestDb, ME, seedAccount } from '@/outbox/testSupport'
import { ComposeDialog } from './ComposeDialog'

vi.mock('@/data/actions', () => ({
  sendMessage: vi.fn(),
  searchPeople: vi.fn(),
  findConversationByParticipants: vi.fn(),
}))
import * as actions from '@/data/actions'

afterEach(cleanup)

function renderDialog(onClose: () => void) {
  const rootRoute = createRootRoute()
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: () => <ComposeDialog onClose={onClose} />,
  })
  const chatRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/chats/$conversationId',
    component: () => <div>chat-stub</div>,
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute, chatRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  return render(<RouterProvider router={router} />)
}

const toInput = async () => screen.findByRole('combobox', { name: 'To:' })

describe('compose integration wiring', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = makeTestDb()
    setDBForTests(db)
    clearDraftsForTests()
    vi.mocked(actions.searchPeople).mockResolvedValue([])
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue(null)
  })

  afterEach(async () => {
    setDBForTests(null)
    clearDraftsForTests()
    await db.delete()
  })

  it('passes the picked From: alias to sendMessage as fromAlias', async () => {
    await seedAccount(db, {
      sendAsAliases: [
        {
          email: ME,
          displayName: '',
          isDefault: true,
          isPrimary: true,
          verificationStatus: 'accepted',
        },
        {
          email: 'work@example.com',
          displayName: 'Work',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'accepted',
        },
      ],
    })
    vi.mocked(actions.sendMessage).mockResolvedValue({ messageId: 'm1', conversationId: 'c1' })
    const user = userEvent.setup()
    renderDialog(vi.fn())

    await user.selectOptions(await screen.findByLabelText('From:'), 'work@example.com')
    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() =>
      expect(actions.sendMessage).toHaveBeenCalledWith({
        to: ['bob@example.com'],
        body: 'hello',
        fromAlias: 'work@example.com',
      }),
    )
  })

  it('omits fromAlias when the picker is untouched', async () => {
    await seedAccount(db)
    vi.mocked(actions.sendMessage).mockResolvedValue({ messageId: 'm1', conversationId: 'c1' })
    const user = userEvent.setup()
    renderDialog(vi.fn())

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() =>
      expect(actions.sendMessage).toHaveBeenCalledWith({ to: ['bob@example.com'], body: 'hello' }),
    )
  })

  it('carries the typed body into the existing chat draft on "Open chat"', async () => {
    await seedAccount(db)
    await db.conversations.put(convoRow({ id: 'c9', displayName: 'Bob' }))
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue('c9')
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderDialog(onClose)

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'draft to carry')
    await user.click(await screen.findByRole('button', { name: 'Open chat' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    await screen.findByText('chat-stub')
    const { result } = renderHook(() => useDraft('c9'))
    expect(result.current[0]).toBe('draft to carry')
  })

  it('seeds an ALREADY-MOUNTED reply bar when "Open chat" targets the open conversation', async () => {
    // Desktop split view: the chat with this recipient is already open (its
    // ReplyBar mounted) while the user types into the compose dialog. "Open
    // chat" must hand the body to the live reply bar, not only to future
    // mounts of it.
    await seedAccount(db)
    await db.conversations.put(convoRow({ id: 'c9', displayName: 'Bob' }))
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue('c9')
    const user = userEvent.setup()

    const rootRoute = createRootRoute()
    const indexRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '/',
      component: () => <ComposeDialog onClose={vi.fn()} />,
    })
    const chatRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '/chats/$conversationId',
      component: () => <div>chat-stub</div>,
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([indexRoute, chatRoute]),
      history: createMemoryHistory({ initialEntries: ['/'] }),
    })
    // The reply bar lives outside the routed area (like the persistent chat
    // pane in the desktop layout) so it stays mounted across the navigation.
    render(
      <>
        <ReplyBar conversationId="c9" onSent={() => undefined} />
        <RouterProvider router={router} />
      </>,
    )

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'typed in compose')
    await user.click(await screen.findByRole('button', { name: 'Open chat' }))

    await waitFor(() => {
      const replyBox = screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Message' })
      expect(replyBox.value).toBe('typed in compose')
    })
  })
})
