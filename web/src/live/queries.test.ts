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

describe('queryConversationList search', () => {
  const seedSearchCorpus = async () =>
    db.conversations.bulkAdd([
      conv('alice', {
        displayName: 'Alice Chen',
        snippet: 'Lunch on Thursday?',
        lastMessageDate: 400,
      }),
      conv('ben', {
        displayName: 'Ben Ortiz',
        snippet: 'Got it, will review tonight.',
        lastMessageDate: 300,
        inboxUnreadCount: 1,
      }),
      conv('digest', {
        displayName: 'The Daily Digest',
        snippet: 'Five things worth reading',
        lastMessageDate: 200,
      }),
      conv('pin', {
        displayName: 'Pinned Pat',
        snippet: 'about lunch',
        lastMessageDate: 100,
        pinned: 1,
      }),
    ])

  it('matches on displayName', async () => {
    await seedSearchCorpus()
    const page = await queryConversationList(db, { unreadOnly: false, query: 'ortiz', limit: 10 })
    expect(page.unpinned.map((c) => c.id)).toEqual(['ben'])
  })

  it('matches on snippet, case-insensitively', async () => {
    await seedSearchCorpus()
    const page = await queryConversationList(db, { unreadOnly: false, query: 'LUNCH', limit: 10 })
    expect(page.unpinned.map((c) => c.id)).toEqual(['alice'])
    // The pinned block is searched by the same predicate.
    expect(page.pinned.map((c) => c.id)).toEqual(['pin'])
  })

  it('returns nothing when the query misses both fields', async () => {
    await seedSearchCorpus()
    const page = await queryConversationList(db, { unreadOnly: false, query: 'zzz', limit: 10 })
    expect(page.unpinned).toEqual([])
    expect(page.pinned).toEqual([])
    expect(page.hasMore).toBe(false)
  })

  it('composes with the unread filter instead of replacing it', async () => {
    await seedSearchCorpus()
    // 'e' hits every fixture; only Ben is unread.
    const both = await queryConversationList(db, { unreadOnly: true, query: 'e', limit: 10 })
    expect(both.unpinned.map((c) => c.id)).toEqual(['ben'])

    // A query that matches only read rows yields nothing under Unread.
    const none = await queryConversationList(db, { unreadOnly: true, query: 'Chen', limit: 10 })
    expect(none.unpinned).toEqual([])

    // Same query without the filter still finds it.
    const all = await queryConversationList(db, { unreadOnly: false, query: 'Chen', limit: 10 })
    expect(all.unpinned.map((c) => c.id)).toEqual(['alice'])
  })

  it('treats an empty query as "not searching"', async () => {
    await seedSearchCorpus()
    const page = await queryConversationList(db, { unreadOnly: false, query: '', limit: 10 })
    expect(page.unpinned).toHaveLength(3)
  })

  it('fills full pages when matches are sparse, and pages the rest by keyset', async () => {
    // 200 rows, only every 20th matching: a page read that filtered AFTER the
    // limit would return 2-3 rows with hasMore=false and strand the other
    // matches. Dexie's Collection.filter runs inside the cursor loop, so the
    // walk continues until the page is genuinely full.
    await db.conversations.bulkAdd(
      Array.from({ length: 200 }, (_, i) =>
        conv(`c${String(i).padStart(3, '0')}`, {
          displayName: i % 20 === 0 ? `Needle ${i}` : `Haystack ${i}`,
          lastMessageDate: 10_000 - i,
        }),
      ),
    )

    const first = await queryConversationList(db, { unreadOnly: false, query: 'needle', limit: 4 })
    expect(first.unpinned.map((c) => c.id)).toEqual(['c000', 'c020', 'c040', 'c060'])
    expect(first.hasMore).toBe(true)

    const wholeSet = await queryConversationList(db, {
      unreadOnly: false,
      query: 'needle',
      limit: 50,
    })
    expect(wholeSet.unpinned).toHaveLength(10)
    expect(wholeSet.hasMore).toBe(false)
  })

  it('reports hasMore=false when the matches exactly fill one page', async () => {
    await db.conversations.bulkAdd(
      Array.from({ length: 30 }, (_, i) =>
        conv(`c${i}`, {
          displayName: i < 3 ? `Needle ${i}` : `Haystack ${i}`,
          lastMessageDate: 1000 - i,
        }),
      ),
    )
    const page = await queryConversationList(db, { unreadOnly: false, query: 'needle', limit: 3 })
    expect(page.unpinned).toHaveLength(3)
    expect(page.hasMore).toBe(false)
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
