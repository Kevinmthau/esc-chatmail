import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow } from '@/db/types'
import { queryChatWindow, queryConversationList } from './queries'

let db: ChatmailDB

const conv = (id: string, over: Partial<ConversationRow> = {}): ConversationRow => ({
  id,
  keyHash: `kh-${id}`,
  participantHash: `ph-${id}`,
  type: 'oneToOne',
  displayName: id,
  snippet: '',
  lastMessageDate: 0,
  latestInboxDate: 0,
  hasInbox: 0,
  inboxUnreadCount: 0,
  pinned: 0,
  muted: 0,
  archivedAt: 0,
  isArchived: 0,
  createdAt: 0,
  ...over,
})

const msg = (id: string, conversationId: string, internalDate: number): MessageRow => ({
  id,
  conversationId,
  gmThreadId: '',
  rfcMessageId: '',
  references: '',
  internalDate,
  subject: '',
  snippet: '',
  cleanedSnippet: '',
  chatPreviewText: '',
  bodyText: '',
  hasHtmlBody: 0,
  senderEmail: 'a@x.com',
  senderName: '',
  deliveredToAddress: '',
  replyFromAddress: '',
  isFromMe: 0,
  isUnread: 0,
  isNewsletter: 0,
  isCalendarInvite: 0,
  hasAttachments: 0,
  labelIds: [],
  localModifiedAt: 0,
})

beforeEach(() => {
  db = new ChatmailDB(`test-${crypto.randomUUID()}`)
})

afterEach(async () => {
  await db.delete()
})

describe('queryConversationList', () => {
  it('orders pinned first, then unpinned newest-first, excluding archived', async () => {
    await db.conversations.bulkAdd([
      conv('old', { lastMessageDate: 100 }),
      conv('new', { lastMessageDate: 300 }),
      conv('pinned', { lastMessageDate: 50, pinned: 1 }),
      conv('archived', { lastMessageDate: 400, archivedAt: 1, isArchived: 1 }),
    ])
    const page = await queryConversationList(db, { unreadOnly: false, limit: 10 })
    expect(page.pinned.map((c) => c.id)).toEqual(['pinned'])
    expect(page.unpinned.map((c) => c.id)).toEqual(['new', 'old'])
  })

  it('pages by limit and reports hasMore', async () => {
    await db.conversations.bulkAdd(
      Array.from({ length: 5 }, (_, i) => conv(`c${i}`, { lastMessageDate: i * 10 })),
    )
    const page = await queryConversationList(db, { unreadOnly: false, limit: 3 })
    expect(page.unpinned).toHaveLength(3)
    expect(page.hasMore).toBe(true)
  })

  it('filters to unread when requested', async () => {
    await db.conversations.bulkAdd([
      conv('read', { lastMessageDate: 100 }),
      conv('unread', { lastMessageDate: 50, inboxUnreadCount: 2 }),
    ])
    const page = await queryConversationList(db, { unreadOnly: true, limit: 10 })
    expect(page.unpinned.map((c) => c.id)).toEqual(['unread'])
  })
})

describe('queryChatWindow', () => {
  it('returns the newest window oldest-first and pages older by keyset', async () => {
    await db.messages.bulkAdd(Array.from({ length: 10 }, (_, i) => msg(`m${i}`, 'c1', i * 100)))
    await db.messages.add(msg('other', 'c2', 5000))

    const first = await queryChatWindow(db, 'c1', { limit: 4 })
    expect(first.messages.map((m) => m.id)).toEqual(['m6', 'm7', 'm8', 'm9'])
    expect(first.hasOlder).toBe(true)

    const older = await queryChatWindow(db, 'c1', {
      limit: 4,
      before: first.messages[0]!.internalDate,
    })
    expect(older.messages.map((m) => m.id)).toEqual(['m2', 'm3', 'm4', 'm5'])
  })
})
