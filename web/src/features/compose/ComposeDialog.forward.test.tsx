// Compose dialog in FORWARD mode (port of ComposeView .forward): prefilled
// subject/body, empty recipients, and a send that dispatches a new message
// carrying the forward payload.

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
import { patchHappyDomForDomPurify } from '@/features/reader/happyDomPatch'
import { FORWARD_MARKER } from '@/outbox/forwardMetadata'
import { makeTestDb, msgRow, seedAccount } from '@/outbox/testSupport'
import { ComposeDialog } from './ComposeDialog'

patchHappyDomForDomPurify()

vi.mock('@/data/actions', () => ({
  sendMessage: vi.fn(),
  searchPeople: vi.fn(),
  findConversationByParticipants: vi.fn(),
}))
import * as actions from '@/data/actions'

afterEach(cleanup)

function renderForward(messageId: string, onClose: () => void = vi.fn()) {
  const rootRoute = createRootRoute()
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: () => <ComposeDialog onClose={onClose} forwardMessageId={messageId} />,
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

const toInput = async () => screen.findByRole<HTMLInputElement>('combobox', { name: 'To:' })
const subjectInput = () => screen.getByLabelText<HTMLInputElement>('Subject:')
const bodyInput = () => screen.getByLabelText<HTMLTextAreaElement>('Message body')

describe('ComposeDialog forward mode', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    setDBForTests(db)
    await seedAccount(db)
    await db.messages.add(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        subject: 'Quarterly numbers',
        senderName: 'Bob Jones',
        senderEmail: 'bob@example.com',
        bodyText: 'Numbers are in.',
      }),
    )
    vi.mocked(actions.searchPeople).mockResolvedValue([])
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue(null)
    vi.mocked(actions.sendMessage).mockResolvedValue({ messageId: 'g1', conversationId: 'c9' })
  })

  afterEach(async () => {
    setDBForTests(null)
    await db.delete()
  })

  it('opens titled Forward with the prefilled subject and forwarded block, recipients empty', async () => {
    renderForward('m1')

    await waitFor(() => expect(subjectInput().value).toBe('Fwd: Quarterly numbers'))
    expect(screen.getByRole('heading', { name: 'Forward' })).toBeTruthy()

    const body = bodyInput().value
    expect(body).toContain(FORWARD_MARKER)
    expect(body).toContain('From: Bob Jones')
    expect(body).toContain('Subject: Quarterly numbers')
    expect(body.endsWith('Numbers are in.')).toBe(true)
    // Recipients start empty (no chips) and the To field holds the focus.
    expect((await toInput()).value).toBe('')
    expect(screen.queryByRole('button', { name: /Remove/ })).toBeNull()
    expect(document.activeElement).toBe(await toInput())
  })

  it('keeps Send disabled until a recipient is committed, then sends as a forward', async () => {
    const onClose = vi.fn()
    const user = userEvent.setup()
    renderForward('m1', onClose)
    await waitFor(() => expect(subjectInput().value).toBe('Fwd: Quarterly numbers'))

    const send = () => screen.getByRole<HTMLButtonElement>('button', { name: 'Send' })
    expect(send().disabled).toBe(true)

    await user.type(await toInput(), 'dana@example.com{Enter}')
    expect(send().disabled).toBe(false)
    await user.click(send())

    await waitFor(() => expect(actions.sendMessage).toHaveBeenCalledTimes(1))
    const draft = vi.mocked(actions.sendMessage).mock.calls[0]?.[0]
    expect(draft?.to).toEqual(['dana@example.com'])
    expect(draft?.forward?.subject).toBe('Fwd: Quarterly numbers')
    expect(draft?.body).toContain(FORWARD_MARKER)
    expect(draft?.body).toContain('Numbers are in.')
    // Plain-text source: no html alternative, and never any threading fields
    // (a forward is a new message — see outbox/send).
    expect(draft?.forward?.htmlBody).toBeUndefined()
    expect(draft?.conversationId).toBeUndefined()

    expect(onClose).toHaveBeenCalledTimes(1)
    await screen.findByText('chat-stub')
  })

  it('sends the user note above the forwarded block, in text and html', async () => {
    await db.messages.update('m1', { hasHtmlBody: 1 })
    await db.bodies.add({
      messageId: 'm1',
      html: '<html><body><p>Rich body</p><script>alert(1)</script></body></html>',
    })
    const user = userEvent.setup()
    renderForward('m1')
    await waitFor(() => expect(subjectInput().value).toBe('Fwd: Quarterly numbers'))

    await user.type(await toInput(), 'dana@example.com{Enter}')
    // Type the note at the very top, above the prefilled block.
    await user.click(bodyInput())
    await user.keyboard('{Control>}{Home}{/Control}Take a look.')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => expect(actions.sendMessage).toHaveBeenCalledTimes(1))
    const draft = vi.mocked(actions.sendMessage).mock.calls[0]?.[0]
    expect(draft?.body.startsWith('Take a look.')).toBe(true)

    const html = draft?.forward?.htmlBody ?? ''
    expect(html.indexOf('Take a look.')).toBeLessThan(html.indexOf(FORWARD_MARKER))
    expect(html).toContain('Rich body')
    // Sanitized: the original's script never reaches the outgoing message.
    expect(html).not.toContain('<script')
    expect(html).not.toContain('alert(1)')
  })

  it('lets the edited subject win over the prefilled one', async () => {
    const user = userEvent.setup()
    renderForward('m1')
    await waitFor(() => expect(subjectInput().value).toBe('Fwd: Quarterly numbers'))

    await user.clear(subjectInput())
    await user.type(subjectInput(), 'Fwd: numbers (fyi)')
    await user.type(await toInput(), 'dana@example.com{Enter}')
    await user.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => expect(actions.sendMessage).toHaveBeenCalledTimes(1))
    expect(vi.mocked(actions.sendMessage).mock.calls[0]?.[0].forward?.subject).toBe(
      'Fwd: numbers (fyi)',
    )
  })

  // Forward composes fresh: the dedup banner's "Open chat" would drop the
  // subject and forwarded content into a bare reply-bar draft.
  it('never offers the dedup-to-existing-chat banner', async () => {
    vi.mocked(actions.findConversationByParticipants).mockResolvedValue('c9')
    const user = userEvent.setup()
    renderForward('m1')
    await waitFor(() => expect(subjectInput().value).toBe('Fwd: Quarterly numbers'))

    await user.type(await toInput(), 'dana@example.com{Enter}')
    await new Promise((resolve) => setTimeout(resolve, 50))

    expect(screen.queryByText(/already have a chat/i)).toBeNull()
    expect(actions.findConversationByParticipants).not.toHaveBeenCalled()
  })

  it('warns about attachments the send cannot carry', async () => {
    await db.attachments.add({
      id: 'm1:1',
      messageId: 'm1',
      gmailAttachmentId: 'a1',
      contentId: '',
      filename: 'deck.pdf',
      mimeType: 'application/pdf',
      byteSize: 10,
      width: 0,
      height: 0,
      state: 'downloaded',
      lastDownloadFailedAt: 0,
    })
    renderForward('m1')

    await screen.findByText('1 attachment could not be included')
  })

  it('stays a usable compose when the forwarded message is gone', async () => {
    renderForward('missing')

    const send = () => screen.getByRole<HTMLButtonElement>('button', { name: 'Send' })
    await waitFor(() => expect(send().disabled).toBe(true))
    expect(bodyInput().value).toBe('')
    expect(subjectInput().value).toBe('')
  })
})
