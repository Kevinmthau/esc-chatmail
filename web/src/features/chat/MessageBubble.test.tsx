// Bubble content routing: displayPolicy verdict → which component renders.

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { retrySend } from '@/data/actions'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { CalendarEventData, MessageRow } from '@/db/types'
import type { RunDecoration } from '@/lib/bubbleRuns'
import { GENERIC_SEND_ERROR } from '@/outbox/send'
import { makeTestDb, msgRow } from '@/outbox/testSupport'
import { MessageBubble } from './MessageBubble'
import { clearRichContentCacheForTests } from './useRichHtmlContent'

const navigate = vi.fn()

vi.mock('@/data/actions', () => ({ retrySend: vi.fn() }))

vi.mock('@tanstack/react-router', () => ({
  Link: ({ children }: { children?: ReactNode }) => <a data-testid="router-link">{children}</a>,
  useNavigate: () => navigate,
}))

vi.mock('@/features/reader/HtmlPreviewCard', () => ({
  HtmlPreviewCard: ({ messageId }: { messageId: string }) => (
    <div data-testid="preview-card" data-message-id={messageId} />
  ),
}))

vi.mock('@/features/attachments/AttachmentContent', () => ({
  AttachmentContent: ({
    messageId,
    hideCalendarInviteAttachments,
  }: {
    messageId: string
    hideCalendarInviteAttachments?: boolean
  }) => (
    <div
      data-testid="attachment-content"
      data-message-id={messageId}
      data-hide-calendar={hideCalendarInviteAttachments === true ? 'true' : 'false'}
    />
  ),
}))

const CALENDAR_EVENT: CalendarEventData = {
  title: 'Design sync',
  startMs: Date.UTC(2026, 2, 18, 18, 0, 0),
  endMs: Date.UTC(2026, 2, 18, 19, 0, 0),
  timeZone: 'America/New_York',
  isAllDay: 0,
  location: 'Conference Room B',
  organizer: 'Alice Smith',
  method: 'REQUEST',
  status: 'CONFIRMED',
  source: 'Google Calendar',
}

const DECORATION: RunDecoration = {
  isFirstOfRun: true,
  isLastOfRun: true,
  showAvatar: true,
  showSenderName: false,
}

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
  setDBForTests(db)
  clearRichContentCacheForTests()
})

afterEach(async () => {
  cleanup()
  setDBForTests(null)
  await db.delete()
})

function renderBubble(
  message: MessageRow,
  opts: { isOneToOne?: boolean; decoration?: Partial<RunDecoration> } = {},
) {
  return render(
    <MessageBubble
      message={message}
      decoration={{ ...DECORATION, ...opts.decoration }}
      isOneToOne={opts.isOneToOne ?? true}
      onReply={() => undefined}
    />,
  )
}

describe('MessageBubble content routing', () => {
  it('renders incoming plain text as a gray bubble', () => {
    const { container } = renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: 'Hello there' }),
    )
    expect(screen.getByText('Hello there')).toBeTruthy()
    expect(container.querySelector('.bg-bubble-in')).not.toBeNull()
    expect(screen.queryByTestId('preview-card')).toBeNull()
  })

  it('mirrors own messages with the outgoing bubble color and no avatar slot', () => {
    const { container } = renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', isFromMe: 1, chatPreviewText: 'Mine' }),
    )
    expect(container.querySelector('.bg-bubble-out')).not.toBeNull()
    expect(container.querySelector('.flex-row-reverse')).not.toBeNull()
    expect(screen.queryByTestId('avatar-slot')).toBeNull()
  })

  it('routes newsletters to the HTML preview card', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        isNewsletter: 1,
        hasHtmlBody: 1,
        subject: 'Weekly digest',
        senderEmail: 'news@list.example.com',
      }),
    )
    expect(screen.getByTestId('preview-card').getAttribute('data-message-id')).toBe('m1')
  })

  it('routes trusted transactional senders to the preview card even without HTML metadata', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        senderEmail: 'relay@members.ebay.com',
        chatPreviewText: 'You have a new message about your order',
      }),
    )
    expect(screen.getByTestId('preview-card')).toBeTruthy()
  })

  it('does not trust spoofed lookalike domains', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        senderEmail: 'relay@members.ebay.com.evil.com',
        chatPreviewText: 'Totally legit',
      }),
    )
    expect(screen.queryByTestId('preview-card')).toBeNull()
    expect(screen.getByText('Totally legit')).toBeTruthy()
  })

  it('upgrades to a preview card once a genuinely rich HTML body loads', async () => {
    await db.bodies.put({
      messageId: 'm1',
      html: '<html><body><section><h1>Big sale</h1></section></body></html>',
    })
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasHtmlBody: 1,
        subject: 'Big sale',
        chatPreviewText: 'Big sale inside',
        senderEmail: 'promo@shop.example.com',
      }),
    )
    await waitFor(() => {
      expect(screen.getByTestId('preview-card')).toBeTruthy()
    })
  })

  it('renders a blue View original bubble when there is HTML but no text', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasHtmlBody: 1,
        subject: 'Re: plans',
        chatPreviewText: '',
        bodyText: '',
        snippet: '',
      }),
    )
    expect(screen.getByText('View original')).toBeTruthy()
    expect(screen.queryByTestId('preview-card')).toBeNull()
  })

  it('shows a View original pill inside text bubbles that also have an HTML body', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasHtmlBody: 1,
        subject: 'Re: plans',
        chatPreviewText: 'Sounds good',
      }),
    )
    expect(screen.getByText('Sounds good')).toBeTruthy()
    expect(screen.getByText('View original')).toBeTruthy()
  })

  it('renders attachments only when there is no text and no HTML', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasAttachments: 1,
        chatPreviewText: '',
        bodyText: '',
      }),
    )
    expect(screen.getByTestId('attachment-content')).toBeTruthy()
    expect(screen.queryByText('No preview available')).toBeNull()
  })

  it('falls back to No preview available when the message is empty', () => {
    renderBubble(msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: '', bodyText: '' }))
    expect(screen.getByText('No preview available')).toBeTruthy()
  })
})

describe('MessageBubble calendar invites', () => {
  const invite = (overrides: Partial<MessageRow> = {}): MessageRow =>
    msgRow({
      id: 'm1',
      conversationId: 'c1',
      hasHtmlBody: 1,
      isCalendarInvite: 1,
      calendarEvent: CALENDAR_EVENT,
      subject: 'Invitation: Design sync',
      senderEmail: 'alice@example.com',
      senderName: 'Alice Smith',
      chatPreviewText: 'You have been invited to the following event.',
      ...overrides,
    })

  it('routes a detected invite to the calendar card, not the generic one', () => {
    renderBubble(invite())
    expect(screen.getByTestId('calendar-invite-card')).toBeTruthy()
    expect(screen.queryByTestId('preview-card')).toBeNull()
    expect(screen.getByText('Design sync')).toBeTruthy()
  })

  it('falls back to the generic card when the invite yielded no event', () => {
    const row = invite()
    delete row.calendarEvent
    renderBubble(row)
    expect(screen.getByTestId('preview-card')).toBeTruthy()
    expect(screen.queryByTestId('calendar-invite-card')).toBeNull()
  })

  it('hides the duplicate .ics attachment tile while the calendar card shows', () => {
    // A real Google invite carries the payload twice: the inline
    // text/calendar part the card renders AND a named .ics server attachment.
    // iOS filters the tile (hidingCalendarInviteAttachments); so must we.
    renderBubble(invite({ hasAttachments: 1 }))
    expect(screen.getByTestId('calendar-invite-card')).toBeTruthy()
    expect(screen.getByTestId('attachment-content').getAttribute('data-hide-calendar')).toBe('true')
  })

  it('keeps attachment tiles for the generic-card fallback', () => {
    const row = invite({ hasAttachments: 1 })
    delete row.calendarEvent
    renderBubble(row)
    expect(screen.getByTestId('attachment-content').getAttribute('data-hide-calendar')).toBe(
      'false',
    )
  })

  it('leaves an ordinary message on its existing route', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasHtmlBody: 1,
        subject: 'Design sync',
        chatPreviewText: 'See you at 3',
      }),
    )
    expect(screen.queryByTestId('calendar-invite-card')).toBeNull()
    expect(screen.getByText('See you at 3')).toBeTruthy()
  })

  it('keeps an invite the policy sends to a bubble out of the calendar card', () => {
    // Own messages in a one-to-one never get a preview card, invite or not.
    renderBubble(invite({ isFromMe: 1 }))
    expect(screen.queryByTestId('calendar-invite-card')).toBeNull()
    expect(screen.getByText('You have been invited to the following event.')).toBeTruthy()
  })
})

describe('MessageBubble chrome', () => {
  it('shows the subject line when it differs from the body', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        subject: 'Project plans',
        chatPreviewText: 'See you at 3',
      }),
    )
    expect(screen.getByText('Project plans')).toBeTruthy()
  })

  it('hides the subject line when it matches the body text', () => {
    renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', subject: 'Ping', chatPreviewText: 'Ping' }),
    )
    expect(screen.getAllByText('Ping')).toHaveLength(1)
  })

  it('fills the avatar slot only when the run decoration says so', () => {
    const { container, rerender } = renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: 'Hi', senderName: 'Bob' }),
      { decoration: { showAvatar: false } },
    )
    expect(container.querySelector('[data-testid="avatar-slot"]')?.childElementCount).toBe(0)
    rerender(
      <MessageBubble
        message={msgRow({
          id: 'm1',
          conversationId: 'c1',
          chatPreviewText: 'Hi',
          senderName: 'Bob',
        })}
        decoration={DECORATION}
        isOneToOne
        onReply={() => undefined}
      />,
    )
    expect(container.querySelector('[data-testid="avatar-slot"]')?.childElementCount).toBe(1)
  })

  it('shows the sender name when decorated (groups, first of run)', () => {
    renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: 'Hi', senderName: 'Alice Baker' }),
      { isOneToOne: false, decoration: { showSenderName: true } },
    )
    expect(screen.getByText('Alice Baker')).toBeTruthy()
  })

  it('shows the unread dot for unread incoming messages', () => {
    const { container } = renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', isUnread: 1, chatPreviewText: 'New' }),
    )
    expect(container.querySelector('[class*="size-1.5"]')).not.toBeNull()
  })

  it('shows Sending… for pending optimistic sends and Send failed for failures', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'pending',
        chatPreviewText: 'Out',
      }),
    )
    expect(screen.getByText('Sending…')).toBeTruthy()
    cleanup()
    renderBubble(
      msgRow({
        id: 'm2',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        chatPreviewText: 'Out',
      }),
    )
    expect(screen.getByText('Send failed')).toBeTruthy()
  })

  // A send that fails with attachments keeps its message; the bytes exist
  // nowhere else, so the bubble has to offer the way back.
  it('offers a retry on a failed send and reports a second failure in place', async () => {
    vi.mocked(retrySend).mockRejectedValueOnce(new Error('still offline'))
    renderBubble(
      msgRow({
        id: 'm2',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        hasAttachments: 1,
        chatPreviewText: 'Out',
      }),
    )

    await userEvent.click(screen.getByRole('button', { name: 'Retry send' }))

    expect(vi.mocked(retrySend)).toHaveBeenCalledWith('m2')
    await waitFor(() => expect(screen.getByText(GENERIC_SEND_ERROR)).toBeTruthy())
  })

  it('linkifies URLs in bubble text without innerHTML', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        chatPreviewText: 'Look at https://example.com/x now',
      }),
    )
    const anchor = screen.getByRole('link', { name: 'https://example.com/x' })
    expect(anchor.getAttribute('href')).toBe('https://example.com/x')
    expect(anchor.getAttribute('rel')).toContain('noopener')
  })
})

describe('MessageBubble context menu', () => {
  /** Long-press/right-click on the bubble row and wait for the Radix content. */
  async function openMenu(): Promise<void> {
    fireEvent.contextMenu(screen.getByText('Sounds good'))
    await screen.findByRole('menuitem', { name: 'Reply' })
  }

  it('offers Reply, Forward and View original', async () => {
    renderBubble(
      msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: 'Sounds good', hasHtmlBody: 1 }),
    )
    await openMenu()

    expect(screen.getByRole('menuitem', { name: 'Forward' })).toBeTruthy()
    expect(screen.getByRole('menuitem', { name: 'View original' })).toBeTruthy()
  })

  it('Forward opens the compose dialog in forward mode for this message', async () => {
    renderBubble(msgRow({ id: 'm7', conversationId: 'c1', chatPreviewText: 'Sounds good' }))
    await openMenu()

    fireEvent.click(screen.getByRole('menuitem', { name: 'Forward' }))

    await waitFor(() => expect(navigate).toHaveBeenCalled())
    const options = navigate.mock.calls.at(-1)?.[0] as {
      to: string
      search: (prev: Record<string, unknown>) => Record<string, unknown>
    }
    expect(options.to).toBe('.')
    // Carried alongside whatever search params the chat route already holds.
    expect(options.search({ filter: 'unread' })).toEqual({ filter: 'unread', forward: 'm7' })
  })

  it('Reply focuses the reply bar instead of navigating', async () => {
    const onReply = vi.fn()
    render(
      <MessageBubble
        message={msgRow({ id: 'm1', conversationId: 'c1', chatPreviewText: 'Sounds good' })}
        decoration={DECORATION}
        isOneToOne
        onReply={onReply}
      />,
    )
    await openMenu()

    fireEvent.click(screen.getByRole('menuitem', { name: 'Reply' }))
    await waitFor(() => expect(onReply).toHaveBeenCalledTimes(1))
  })
})
