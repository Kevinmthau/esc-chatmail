// Send gate parity with iOS ComposeViewModel.canSend: an invalid chip holds
// the send and is named, rather than being dropped from it silently.

import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from '@tanstack/react-router'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { makeTestDb, seedAccount } from '@/outbox/testSupport'
import { ComposeDialog } from './ComposeDialog'
import { invalidRecipientMessage, makeChip } from './recipients'

vi.mock('@/data/actions', () => ({
  sendMessage: vi.fn(),
  searchPeople: vi.fn(),
  findConversationByParticipants: vi.fn(),
}))
import * as actions from '@/data/actions'

afterEach(cleanup)

function renderDialog() {
  const rootRoute = createRootRoute()
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: () => <ComposeDialog onClose={vi.fn()} />,
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  return render(<RouterProvider router={router} />)
}

const toInput = async () => screen.findByRole('combobox', { name: 'To:' })
const sendButton = () => screen.getByRole<HTMLButtonElement>('button', { name: 'Send' })

describe('ComposeDialog invalid recipients', () => {
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

  // Revert-check: ComposeDialog canSend's `invalidRecipientNotice === null`
  // term — without it a valid chip beside the invalid one enables Send and the
  // send goes to the valid chip only.
  it('holds Send while an invalid chip sits beside a valid one, and names it', async () => {
    const user = userEvent.setup()
    renderDialog()

    await user.type(await toInput(), 'alice@example.com, bob@example{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello both')

    expect(screen.getByRole('button', { name: 'Remove alice@example.com' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Remove bob@example' })).toBeTruthy()
    expect(screen.getByText('bob@example is not a valid email address.')).toBeTruthy()
    expect(sendButton().disabled).toBe(true)

    await user.click(sendButton())
    expect(actions.sendMessage).not.toHaveBeenCalled()
  })

  it('releases Send once the invalid chip is removed', async () => {
    vi.mocked(actions.sendMessage).mockResolvedValue({ messageId: 'm1', conversationId: 'c1' })
    const user = userEvent.setup()
    renderDialog()

    await user.type(await toInput(), 'alice@example.com, bob@example{Enter}')
    await user.type(screen.getByLabelText('Message body'), 'hello')
    expect(sendButton().disabled).toBe(true)

    await user.click(screen.getByRole('button', { name: 'Remove bob@example' }))

    expect(screen.queryByText(/is not a valid email address/)).toBeNull()
    expect(sendButton().disabled).toBe(false)

    await user.click(sendButton())
    await waitFor(() =>
      expect(actions.sendMessage).toHaveBeenCalledWith({
        to: ['alice@example.com'],
        body: 'hello',
      }),
    )
  })

  it('lists every invalid chip when more than one holds the send', async () => {
    const user = userEvent.setup()
    renderDialog()

    await user.type(await toInput(), 'bob@example, carol@nowhere{Enter}')

    expect(
      screen.getByText('These are not valid email addresses: bob@example, carol@nowhere.'),
    ).toBeTruthy()
  })
})

describe('invalidRecipientMessage', () => {
  // Revert-check: invalidRecipientMessage
  it('is null when every chip is valid', () => {
    expect(invalidRecipientMessage([makeChip('a@example.com')!, makeChip('b@example.com')!])).toBe(
      null,
    )
  })

  it('names a single invalid chip in the builder rejection shape', () => {
    expect(invalidRecipientMessage([makeChip('a@example.com')!, makeChip('nope')!])).toBe(
      'nope is not a valid email address.',
    )
  })

  it('lists several invalid chips in commit order', () => {
    expect(invalidRecipientMessage([makeChip('x@y')!, makeChip('Bob <bob@example.com>')!])).toBe(
      'These are not valid email addresses: x@y, Bob <bob@example.com>.',
    )
  })
})
