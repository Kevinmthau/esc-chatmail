import { cleanup, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithRouter } from '@/features/conversations/testSupport'
import { ChatHeader } from './ChatHeader'

// The header only needs a resolved conversation and a participant count; both
// live hooks are stubbed so the test exercises the navigation wiring.
vi.mock('@/live/hooks', () => ({
  useAccountLiveQuery: () => 1,
  useConversation: () => ({ id: 'c1', type: 'dm', displayName: 'Ben Ortiz' }),
}))
vi.mock('@/data/actions', () => ({
  archiveConversation: vi.fn(async () => {}),
  reportSpam: vi.fn(async () => {}),
}))

afterEach(cleanup)

describe('ChatHeader list navigation', () => {
  it('carries the committed search query and filter back to the list', async () => {
    // The row link carried ?q= (and ?filter=) into the chat; every way back
    // out must round-trip them, or the list snaps back to unfiltered.
    renderWithRouter(<ChatHeader conversationId="c1" />, '/chats/c1?q=ortiz&filter=unread')

    const back = await screen.findByRole('link', { name: 'Back to chats' })
    expect(back.getAttribute('href')).toContain('q=ortiz')
    expect(back.getAttribute('href')).toContain('filter=unread')
  })

  it('drops nothing but the conversation when no search is active', async () => {
    renderWithRouter(<ChatHeader conversationId="c1" />, '/chats/c1')

    const back = await screen.findByRole('link', { name: 'Back to chats' })
    expect(back.getAttribute('href')).not.toContain('q=')
  })
})
