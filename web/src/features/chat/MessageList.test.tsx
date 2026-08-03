// Runs integration: MessageList wires computeRuns decorations (avatar only on
// last-of-run, sender names in groups) into each bubble.

import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConversationRow, MessageRow } from '@/db/types'
import { useChatWindow, useConversation } from '@/live/hooks'
import { convoRow, msgRow } from '@/outbox/testSupport'
import { MessageList } from './MessageList'
import type { MessageBubbleProps } from './MessageBubble'
import { clearSavedScrollTopsForTests } from './useChatScroll'

vi.mock('@/live/hooks', () => ({
  useChatWindow: vi.fn(),
  useConversation: vi.fn(),
}))

vi.mock('./MessageBubble', () => ({
  MessageBubble: ({ message, decoration, isOneToOne }: MessageBubbleProps) => (
    <div
      data-testid="bubble"
      data-id={message.id}
      data-show-avatar={String(decoration.showAvatar)}
      data-show-name={String(decoration.showSenderName)}
      data-one-to-one={String(isOneToOne)}
    />
  ),
}))

const mockedWindow = vi.mocked(useChatWindow)
const mockedConversation = vi.mocked(useConversation)

function setWindow(messages: MessageRow[] | undefined, hasOlder = false): void {
  mockedWindow.mockReturnValue(messages === undefined ? undefined : { messages, hasOlder })
}

function setConversation(row: ConversationRow | undefined): void {
  mockedConversation.mockReturnValue(row)
}

beforeEach(() => {
  clearSavedScrollTopsForTests()
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function m(id: string, senderEmail: string, isFromMe: 0 | 1 = 0): MessageRow {
  return msgRow({ id, conversationId: 'c1', senderEmail, isFromMe })
}

describe('MessageList', () => {
  it('renders a skeleton while the window loads', () => {
    setWindow(undefined)
    setConversation(undefined)
    const { container } = render(<MessageList conversationId="c1" onReply={() => undefined} />)
    expect(container.querySelector('.animate-pulse')).not.toBeNull()
    expect(screen.queryByTestId('chat-scroller')).toBeNull()
  })

  it('shows the empty state for a conversation without messages', () => {
    setWindow([])
    setConversation(convoRow({ id: 'c1' }))
    render(<MessageList conversationId="c1" onReply={() => undefined} />)
    expect(screen.getByText('No messages')).toBeTruthy()
  })

  it('decorates bubbles per sender run in a group conversation', () => {
    setWindow([
      m('m1', 'bob@example.com'),
      m('m2', 'bob@example.com'),
      m('m3', 'alice@example.com'),
      m('m4', 'me@example.com', 1),
    ])
    setConversation(convoRow({ id: 'c1', type: 'group' }))
    render(<MessageList conversationId="c1" onReply={() => undefined} />)

    const bubbles = screen.getAllByTestId('bubble')
    expect(bubbles.map((b) => b.getAttribute('data-id'))).toEqual(['m1', 'm2', 'm3', 'm4'])

    const byId = new Map(bubbles.map((b) => [b.getAttribute('data-id'), b]))
    // Avatar only on the last message of each incoming run.
    expect(byId.get('m1')?.getAttribute('data-show-avatar')).toBe('false')
    expect(byId.get('m2')?.getAttribute('data-show-avatar')).toBe('true')
    expect(byId.get('m3')?.getAttribute('data-show-avatar')).toBe('true')
    expect(byId.get('m4')?.getAttribute('data-show-avatar')).toBe('false')
    // Sender name on the first message of each incoming run (group chat).
    expect(byId.get('m1')?.getAttribute('data-show-name')).toBe('true')
    expect(byId.get('m2')?.getAttribute('data-show-name')).toBe('false')
    expect(byId.get('m3')?.getAttribute('data-show-name')).toBe('true')
    expect(byId.get('m4')?.getAttribute('data-show-name')).toBe('false')
    // Group conversations are not one-to-one.
    expect(byId.get('m1')?.getAttribute('data-one-to-one')).toBe('false')
  })

  it('treats one-to-one conversations as one-to-one and hides sender names', () => {
    setWindow([m('m1', 'bob@example.com'), m('m2', 'bob@example.com')])
    setConversation(convoRow({ id: 'c1', type: 'oneToOne' }))
    render(<MessageList conversationId="c1" onReply={() => undefined} />)

    const bubbles = screen.getAllByTestId('bubble')
    expect(bubbles.every((b) => b.getAttribute('data-one-to-one') === 'true')).toBe(true)
    expect(bubbles.every((b) => b.getAttribute('data-show-name') === 'false')).toBe(true)
  })
})
