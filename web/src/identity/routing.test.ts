import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ChatmailDB } from '@/db/schema'
import type { ConversationRow } from '@/db/types'
import {
  resolveConversation,
  selectParticipantHashConversation,
  shouldReactivateArchivedConversation,
} from './routing'
import { makeConversationIdentity, makeParticipantSetIdentity } from './participantSet'
import type { ConversationIdentity } from './participantSet'

function makeIdentity(
  participants: string[],
  displayNames: Record<string, string> = {},
): ConversationIdentity {
  return makeConversationIdentity(
    makeParticipantSetIdentity(new Set(participants), new Set(['me@gmail.com'])),
    displayNames,
  )
}

function conversationRow(overrides: Partial<ConversationRow>): ConversationRow {
  return {
    id: crypto.randomUUID(),
    keyHash: crypto.randomUUID(),
    participantHash: 'hash',
    type: 'oneToOne',
    displayName: '',
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
    ...overrides,
  }
}

describe('shouldReactivateArchivedConversation', () => {
  it('INBOX, from-me, and SENT reactivate; everything else does not', () => {
    expect(shouldReactivateArchivedConversation(['INBOX', 'UNREAD'], false)).toBe(true)
    expect(shouldReactivateArchivedConversation([], true)).toBe(true)
    expect(shouldReactivateArchivedConversation(['SENT'], false)).toBe(true)
    expect(shouldReactivateArchivedConversation(['CATEGORY_PROMOTIONS'], false)).toBe(false)
    expect(shouldReactivateArchivedConversation([], false)).toBe(false)
  })
})

describe('selectParticipantHashConversation', () => {
  it('prefers the most recent active conversation', () => {
    const older = conversationRow({ lastMessageDate: 100 })
    const newer = conversationRow({ lastMessageDate: 200 })
    const archived = conversationRow({ lastMessageDate: 300, archivedAt: 400, isArchived: 1 })
    expect(selectParticipantHashConversation([older, archived, newer], false)).toBe(newer)
  })

  it('falls back through latestInboxDate and archivedAt for recency', () => {
    const inboxOnly = conversationRow({ lastMessageDate: 0, latestInboxDate: 500 })
    const dateOnly = conversationRow({ lastMessageDate: 400 })
    expect(selectParticipantHashConversation([dateOnly, inboxOnly], false)).toBe(inboxOnly)
  })

  it('returns null for archived-only candidates without reactivation', () => {
    const archived = conversationRow({ lastMessageDate: 300, archivedAt: 400, isArchived: 1 })
    expect(selectParticipantHashConversation([archived], false)).toBeNull()
  })

  it('reuses the most recent archived conversation when reactivating', () => {
    const olderArchived = conversationRow({ lastMessageDate: 100, archivedAt: 150, isArchived: 1 })
    const newerArchived = conversationRow({ lastMessageDate: 300, archivedAt: 350, isArchived: 1 })
    expect(selectParticipantHashConversation([olderArchived, newerArchived], true)).toBe(
      newerArchived,
    )
  })

  it('returns null for an empty candidate list', () => {
    expect(selectParticipantHashConversation([], true)).toBeNull()
  })
})

describe('resolveConversation', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = new ChatmailDB(`test-${crypto.randomUUID()}`)
  })

  afterEach(async () => {
    await db.delete()
  })

  it('creates a fully seeded shell for an unread inbox arrival', async () => {
    const identity = makeIdentity(['alice@example.com', 'me@gmail.com'], {
      'alice@example.com': 'Alice Smith',
    })
    const { conversation, created } = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: true, messageDate: 1_700_000_000_000, snippet: 'hey' },
      true,
    )

    expect(created).toBe(true)
    expect(conversation.keyHash).toBe(identity.keyHash)
    expect(conversation.participantHash).toBe(identity.participantHash)
    expect(conversation.type).toBe('oneToOne')
    expect(conversation.hasInbox).toBe(1)
    expect(conversation.inboxUnreadCount).toBe(1)
    expect(conversation.latestInboxDate).toBe(1_700_000_000_000)
    expect(conversation.lastMessageDate).toBe(1_700_000_000_000)
    expect(conversation.snippet).toBe('hey')
    expect(conversation.displayName).toBe('Alice Smith')
    expect(conversation.archivedAt).toBe(0)
    expect(conversation.isArchived).toBe(0)

    const stored = await db.conversations.get(conversation.id)
    expect(stored).toEqual(conversation)

    const participants = await db.convoParticipants
      .where('conversationId')
      .equals(conversation.id)
      .toArray()
    expect(participants).toEqual([
      { conversationId: conversation.id, email: 'alice@example.com', role: 'normal' },
    ])

    const person = await db.people.get('alice@example.com')
    expect(person).toEqual({ email: 'alice@example.com', displayName: 'Alice Smith' })
  })

  it('a read inbox arrival seeds hasInbox without an unread count', async () => {
    const identity = makeIdentity(['bob@example.com'])
    const { conversation } = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: false, messageDate: 42 },
      true,
    )
    expect(conversation.hasInbox).toBe(1)
    expect(conversation.inboxUnreadCount).toBe(0)
    expect(conversation.latestInboxDate).toBe(42)
  })

  it('a non-inbox message seeds no inbox indicators', async () => {
    const identity = makeIdentity(['carol@example.com'])
    const { conversation } = await resolveConversation(
      db,
      identity,
      { isInboxArrival: false, isUnread: true, messageDate: 42 },
      true,
    )
    expect(conversation.hasInbox).toBe(0)
    expect(conversation.inboxUnreadCount).toBe(0)
    expect(conversation.latestInboxDate).toBe(0)
    expect(conversation.lastMessageDate).toBe(42)
  })

  it('reuses the existing active conversation instead of creating', async () => {
    const identity = makeIdentity(['alice@example.com'])
    const first = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: true, messageDate: 100 },
      true,
    )
    const second = await resolveConversation(
      db,
      makeIdentity(['alice@example.com']),
      { isInboxArrival: true, isUnread: true, messageDate: 200 },
      true,
    )
    expect(second.created).toBe(false)
    expect(second.conversation.id).toBe(first.conversation.id)
    expect(await db.conversations.count()).toBe(1)
  })

  it('archived epoch + reactivate=false mints a NEW epoch row', async () => {
    const identity = makeIdentity(['alice@example.com'])
    const first = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: true, messageDate: 100 },
      true,
    )
    await db.conversations.update(first.conversation.id, { archivedAt: 150, isArchived: 1 })

    const secondIdentity = makeIdentity(['alice@example.com'])
    const second = await resolveConversation(
      db,
      secondIdentity,
      { isInboxArrival: false, isUnread: false, messageDate: 200 },
      false,
    )

    expect(second.created).toBe(true)
    expect(second.conversation.id).not.toBe(first.conversation.id)
    expect(second.conversation.participantHash).toBe(first.conversation.participantHash)
    expect(second.conversation.keyHash).not.toBe(first.conversation.keyHash)
    expect(await db.conversations.count()).toBe(2)

    const original = await db.conversations.get(first.conversation.id)
    expect(original?.isArchived).toBe(1)
  })

  it('archived epoch + reactivate=true un-archives the same row', async () => {
    const identity = makeIdentity(['alice@example.com'])
    const first = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: true, messageDate: 100 },
      true,
    )
    await db.conversations.update(first.conversation.id, { archivedAt: 150, isArchived: 1 })

    const second = await resolveConversation(
      db,
      makeIdentity(['alice@example.com']),
      { isInboxArrival: true, isUnread: true, messageDate: 200 },
      true,
    )

    expect(second.created).toBe(false)
    expect(second.conversation.id).toBe(first.conversation.id)
    expect(second.conversation.archivedAt).toBe(0)
    expect(second.conversation.isArchived).toBe(0)
    expect(await db.conversations.count()).toBe(1)

    const stored = await db.conversations.get(first.conversation.id)
    expect(stored?.archivedAt).toBe(0)
    expect(stored?.isArchived).toBe(0)
  })

  it('selects the most recent active epoch among several', async () => {
    const identity = makeIdentity(['alice@example.com'])
    const hash = identity.participantHash
    const older = conversationRow({ participantHash: hash, lastMessageDate: 100 })
    const newer = conversationRow({ participantHash: hash, lastMessageDate: 300 })
    const archived = conversationRow({
      participantHash: hash,
      lastMessageDate: 500,
      archivedAt: 600,
      isArchived: 1,
    })
    await db.conversations.bulkAdd([older, newer, archived])

    const resolved = await resolveConversation(
      db,
      identity,
      { isInboxArrival: true, isUnread: false, messageDate: 700 },
      true,
    )
    expect(resolved.created).toBe(false)
    expect(resolved.conversation.id).toBe(newer.id)
  })

  it('10 concurrent resolves for the same hash create exactly one row', async () => {
    const setIdentity = makeParticipantSetIdentity(
      new Set(['alice@example.com', 'bob@example.com']),
      new Set(['me@gmail.com']),
    )
    const results = await Promise.all(
      Array.from({ length: 10 }, (_, i) =>
        resolveConversation(
          db,
          makeConversationIdentity(setIdentity),
          { isInboxArrival: true, isUnread: true, messageDate: 1000 + i },
          true,
        ),
      ),
    )

    const rows = await db.conversations.toArray()
    expect(rows).toHaveLength(1)
    const ids = new Set(results.map((r) => r.conversation.id))
    expect(ids.size).toBe(1)
    expect(results.filter((r) => r.created)).toHaveLength(1)

    const participants = await db.convoParticipants.toArray()
    expect(participants).toHaveLength(2)
  })

  // crypto.randomUUID is [SecureContext], so it is undefined on a plain-http
  // LAN origin — the shell's `id` used to throw there, wedging every arrival.
  it('creates a shell in an insecure context (no crypto.randomUUID)', async () => {
    const real = globalThis.crypto
    vi.stubGlobal('crypto', {
      getRandomValues: <T extends ArrayBufferView>(array: T): T => real.getRandomValues(array),
    })
    try {
      const identity = makeIdentity(['alice@example.com'])
      const { conversation, created } = await resolveConversation(
        db,
        identity,
        { isInboxArrival: true, isUnread: true, messageDate: 42 },
        true,
      )

      expect(created).toBe(true)
      expect(conversation.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      )
      expect(await db.conversations.get(conversation.id)).toEqual(conversation)
    } finally {
      vi.unstubAllGlobals()
    }
  })
})
