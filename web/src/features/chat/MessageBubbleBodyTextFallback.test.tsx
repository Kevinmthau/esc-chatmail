// MessageBubble never renders raw bodyText: a blank stored preview routes the
// body through the same quote/forward stripping the preview derivation used.

import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import type { RunDecoration } from '@/lib/bubbleRuns'
import { makeTestDb, msgRow } from '@/outbox/testSupport'
import { MessageBubble } from './MessageBubble'
import { resolveBubbleText } from './resolveBubbleText'
import { clearRichContentCacheForTests } from './useRichHtmlContent'

vi.mock('@/data/actions', () => ({ retrySend: vi.fn() }))

vi.mock('@tanstack/react-router', () => ({
  Link: ({ children }: { children?: ReactNode }) => <a data-testid="router-link">{children}</a>,
  useNavigate: () => vi.fn(),
}))

vi.mock('@/features/reader/HtmlPreviewCard', () => ({
  HtmlPreviewCard: ({ messageId }: { messageId: string }) => (
    <div data-testid="preview-card" data-message-id={messageId} />
  ),
}))

vi.mock('@/features/attachments/AttachmentContent', () => ({
  AttachmentContent: ({ messageId }: { messageId: string }) => (
    <div data-testid="attachment-content" data-message-id={messageId} />
  ),
}))

const DECORATION: RunDecoration = {
  isFirstOfRun: true,
  isLastOfRun: true,
  showAvatar: true,
  showSenderName: false,
}

const QUOTE_ONLY_REPLY =
  'On Mon, Jan 5, 2026 at 9:00 AM Alice <alice@example.com> wrote:\n' +
  '> Can you make it?\n' +
  '> Let me know.'

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

function renderBubble(message: MessageRow) {
  return render(
    <MessageBubble
      message={message}
      decoration={DECORATION}
      isOneToOne
      onReply={() => undefined}
    />,
  )
}

describe('MessageBubble blank-preview fallback', () => {
  // Revert-check: resolveBubbleText (the old `chatPreviewText || bodyText` renders the quote)
  it('messageBubble_blankPreviewWithQuoteOnlyBody_rendersNoBubbleText', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        chatPreviewText: '',
        bodyText: QUOTE_ONLY_REPLY,
        snippet: QUOTE_ONLY_REPLY,
      }),
    )
    expect(screen.queryByText(/Can you make it/)).toBeNull()
    expect(screen.queryByText(/wrote:/)).toBeNull()
    expect(screen.getByText('No preview available')).toBeTruthy()
  })

  // Revert-check: resolveBubbleText
  it('messageBubble_blankPreviewQuoteOnlyBodyWithAttachments_showsOnlyTheAttachments', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        hasAttachments: 1,
        chatPreviewText: '',
        bodyText: QUOTE_ONLY_REPLY,
      }),
    )
    expect(screen.getByTestId('attachment-content')).toBeTruthy()
    expect(screen.queryByText(/Can you make it/)).toBeNull()
    expect(screen.queryByText('No preview available')).toBeNull()
  })

  // Revert-check: resolveBubbleText
  it('messageBubble_blankPreviewWithReplyAboveQuote_rendersOnlyTheReply', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        chatPreviewText: '',
        bodyText: `Thanks, see you there!\n\n${QUOTE_ONLY_REPLY}`,
      }),
    )
    expect(screen.getByText('Thanks, see you there!')).toBeTruthy()
    expect(screen.queryByText(/Can you make it/)).toBeNull()
  })

  it('messageBubble_storedPreview_isShownAsIs', () => {
    renderBubble(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        chatPreviewText: 'Stored preview',
        bodyText: QUOTE_ONLY_REPLY,
      }),
    )
    expect(screen.getByText('Stored preview')).toBeTruthy()
  })
})

describe('resolveBubbleText', () => {
  // Revert-check: resolveBubbleText
  it('resolveBubbleText_blankPreview_returnsEmptyWhenTheFallbackYieldsNothing', () => {
    expect(resolveBubbleText('', QUOTE_ONLY_REPLY)).toBe('')
    expect(resolveBubbleText('   ', '')).toBe('')
  })

  it('resolveBubbleText_storedPreview_winsOverBodyText', () => {
    expect(resolveBubbleText('  Hi  ', 'Something else')).toBe('Hi')
  })
})
