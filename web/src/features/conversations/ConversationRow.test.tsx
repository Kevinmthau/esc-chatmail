import { cleanup, fireEvent, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConversationRow as ConversationRecord } from '@/db/types'
import { formatTimestamp } from '@/lib/formatTimestamp'
import { ConversationRow } from './ConversationRow'
import { renderWithRouter } from './testSupport'

vi.mock('@/data/actions', () => ({
  archiveConversation: vi.fn(async () => {}),
  markConversationRead: vi.fn(async () => {}),
  toggleConversationRead: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
  requestSync: vi.fn(async () => {}),
}))

import { archiveConversation, reportSpam, toggleConversationRead } from '@/data/actions'

const NOW = Date.now()

function record(overrides: Partial<ConversationRecord> = {}): ConversationRecord {
  return {
    id: 'c1',
    keyHash: 'kh1',
    participantHash: 'ph1',
    type: 'oneToOne',
    displayName: 'Alice Chen',
    snippet: 'Sounds good, see you then!',
    lastMessageDate: NOW,
    latestInboxDate: NOW,
    hasInbox: 1,
    inboxUnreadCount: 2,
    pinned: 1,
    muted: 0,
    archivedAt: 0,
    isArchived: 0,
    createdAt: NOW - 1000,
    ...overrides,
  }
}

describe('ConversationRow', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // Auto-cleanup is off (no vitest globals); unmount between tests explicitly.
  afterEach(cleanup)

  it('renders dot, pin, name, snippet, and timestamp for an unread pinned row', async () => {
    const convo = record()
    const { container } = renderWithRouter(<ConversationRow conversation={convo} filter="unread" />)

    const link = await screen.findByRole('link', { name: 'Alice Chen, 2 unread' })
    const href = link.getAttribute('href') ?? ''
    expect(href).toContain('/chats/c1')
    expect(href).toContain('filter=unread')

    expect(screen.getByText('Alice Chen')).toBeTruthy()
    expect(screen.getByText('Sounds good, see you then!')).toBeTruthy()
    expect(screen.getByText(formatTimestamp(convo.lastMessageDate))).toBeTruthy()
    // Unread dot (accent circle) and pin glyph.
    expect(container.querySelector('span.bg-accent')).not.toBeNull()
    expect(container.querySelector('svg[data-icon="pin"]')).not.toBeNull()
  })

  it('omits dot and pin on a read, unpinned row and labels it read', async () => {
    const { container } = renderWithRouter(
      <ConversationRow conversation={record({ inboxUnreadCount: 0, pinned: 0 })} />,
    )

    await screen.findByRole('link', { name: 'Alice Chen, read' })
    expect(container.querySelector('span.bg-accent')).toBeNull()
    expect(container.querySelector('svg[data-icon="pin"]')).toBeNull()
  })

  it('renders an avatar stack for group conversations', async () => {
    const { container } = renderWithRouter(
      <ConversationRow
        conversation={record({ type: 'group', displayName: 'Alice Chen, Ben Ortiz, Chloe Park' })}
      />,
    )
    await screen.findByRole('link', { name: /Alice Chen, Ben Ortiz, Chloe Park/ })
    // AvatarStack renders one sub-avatar per member (up to 4) in a relative frame.
    expect(container.querySelectorAll('.relative.size-11 > div').length).toBe(3)
  })

  it('hover action buttons invoke the data actions module', async () => {
    renderWithRouter(<ConversationRow conversation={record()} />)

    fireEvent.click(await screen.findByRole('button', { name: 'Archive' }))
    expect(vi.mocked(archiveConversation)).toHaveBeenCalledWith('c1')

    fireEvent.click(screen.getByRole('button', { name: 'Mark read' }))
    expect(vi.mocked(toggleConversationRead)).toHaveBeenCalledWith('c1')
  })

  it('read rows offer Mark unread via the same toggle action', async () => {
    renderWithRouter(<ConversationRow conversation={record({ inboxUnreadCount: 0 })} />)

    fireEvent.click(await screen.findByRole('button', { name: 'Mark unread' }))
    expect(vi.mocked(toggleConversationRead)).toHaveBeenCalledWith('c1')
  })

  it('context menu exposes Archive / Mark read / Report spam', async () => {
    renderWithRouter(<ConversationRow conversation={record()} />)

    const link = await screen.findByRole('link', { name: 'Alice Chen, 2 unread' })
    fireEvent.contextMenu(link)

    const spamItem = await screen.findByText('Report spam')
    fireEvent.click(spamItem)
    expect(vi.mocked(reportSpam)).toHaveBeenCalledWith('c1')
  })
})
