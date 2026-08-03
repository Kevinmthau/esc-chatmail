import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  useParams,
} from '@tanstack/react-router'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { SendFailedError } from '@/outbox/send'
import { convoRow, makeTestDb, ME, seedAccount } from '@/outbox/testSupport'
import { ComposeDialog } from './ComposeDialog'

vi.mock('@/data/actions', () => ({
  sendMessage: vi.fn(),
  searchPeople: vi.fn(),
  findConversationByParticipants: vi.fn(),
}))
import * as actions from '@/data/actions'

afterEach(cleanup)

function ChatStub() {
  const params = useParams({ strict: false })
  return <div>chat:{params.conversationId ?? ''}</div>
}

/** Renders the dialog inside a memory router with a /chats/$conversationId stub. */
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
    component: ChatStub,
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute, chatRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  return render(<RouterProvider router={router} />)
}

const toInput = async () => screen.findByRole('combobox', { name: 'To:' })

describe('ComposeDialog', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    setDBForTests(db)
    await seedAccount(db)
    vi.mocked(actions.searchPeople).mockResolvedValue([])
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue(null)
  })

  afterEach(async () => {
    setDBForTests(null)
    await db.delete()
  })

  it('sends to the committed chip emails, closes, and navigates to the new chat', async () => {
    vi.mocked(actions.sendMessage).mockResolvedValue({ messageId: 'm1', conversationId: 'c42' })
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderDialog(onClose)

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello there')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() =>
      expect(actions.sendMessage).toHaveBeenCalledWith({
        to: ['bob@example.com'],
        body: 'hello there',
      }),
    )
    expect(onClose).toHaveBeenCalledTimes(1)
    await screen.findByText('chat:c42')
  })

  it('disables send until there is a valid recipient and a body', async () => {
    const user = userEvent.setup()
    renderDialog(vi.fn())
    await toInput() // wait for the router to mount the dialog
    const send = () => screen.getByRole<HTMLButtonElement>('button', { name: 'Send' })

    expect(send().disabled).toBe(true)

    await user.type(screen.getByLabelText('Message body'), 'hi')
    expect(send().disabled).toBe(true)

    await user.type(await toInput(), 'notanemail{Enter}')
    expect(send().disabled).toBe(true) // invalid chip is excluded from send

    await user.type(await toInput(), 'bob@example.com{Enter}')
    expect(send().disabled).toBe(false)
  })

  it('shows the existing-chat banner and Open chat closes + navigates there', async () => {
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue('c9')
    await db.conversations.add(convoRow({ id: 'c9', displayName: 'Bob Jones' }))
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderDialog(onClose)

    await user.type(await toInput(), 'bob@example.com{Enter}')

    await screen.findByText(/You already have a chat with Bob Jones/)
    await user.click(screen.getByRole('button', { name: 'Open chat' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    await screen.findByText('chat:c9')
  })

  it('shows the From alias picker only with more than one sendable alias', async () => {
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
        {
          email: 'unverified@example.com',
          displayName: '',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'pending', // not sendable — must not be listed
        },
      ],
    })
    renderDialog(vi.fn())

    const select = await screen.findByLabelText('From:')
    const options = Array.from((select as HTMLSelectElement).options).map((o) => o.value)
    expect(options).toEqual([ME, 'work@example.com'])
  })

  it('hides the From alias picker with a single sendable alias', async () => {
    renderDialog(vi.fn())
    await toInput()
    await new Promise((resolve) => setTimeout(resolve, 100))
    expect(screen.queryByLabelText('From:')).toBeNull()
  })

  it('surfaces a send failure without closing the dialog', async () => {
    vi.mocked(actions.sendMessage).mockRejectedValue(new Error('boom'))
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderDialog(onClose)

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await screen.findByRole('alert')
    expect(screen.getByRole('alert').textContent).toContain('could not be sent')
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send' }).disabled).toBe(false)
  })

  // Regression: a send refused because an address is invalid must say WHICH
  // address — the generic line left the user retrying a send that can never
  // succeed (and, before the builder threw, a narrowed send looked fine).
  it('names the rejected address when the send fails address validation', async () => {
    vi.mocked(actions.sendMessage).mockRejectedValue(
      new SendFailedError('Not a single addr-spec: a@b.com;c@d.com', {
        userMessage: 'a@b.com;c@d.com is not a valid email address.',
      }),
    )
    const user = userEvent.setup()
    renderDialog(vi.fn())

    await user.type(await toInput(), 'bob@example.com{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await screen.findByRole('alert')
    expect(screen.getByRole('alert').textContent).toContain(
      'a@b.com;c@d.com is not a valid email address.',
    )
  })

  it('closes via the header close button', async () => {
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderDialog(onClose)

    await user.click(await screen.findByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
