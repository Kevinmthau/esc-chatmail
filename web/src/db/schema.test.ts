// Schema migrations. A populated database written at an older version must
// open at the current one without losing rows.

import Dexie from 'dexie'
import { afterEach, describe, expect, it } from 'vitest'
import { ChatmailDB, dbNameForAccount } from './schema'
import type { MessageRow } from './types'

/** The v1 store declarations, verbatim — a fixture, never re-derived from schema.ts. */
const V1_STORES = {
  accounts: 'email',
  syncState: 'key',
  conversations:
    'id, &keyHash, participantHash, ' +
    '[participantHash+isArchived+lastMessageDate], ' +
    '[isArchived+pinned+lastMessageDate]',
  messages:
    'id, [conversationId+internalDate], gmThreadId, rfcMessageId, ' +
    '*labelIds, internalDate, [conversationId+isUnread]',
  bodies: 'messageId',
  people: 'email',
  convoParticipants: '[conversationId+email], conversationId',
  msgParticipants: '++pk, messageId, [messageId+kind]',
  labels: 'id',
  attachments: 'id, messageId, contentId, [messageId+contentId]',
  blobs: 'key, lastAccessAt',
  pendingActions: '++id, [status+createdAt], status',
  outboundSends: 'id, status',
  abandonedMessages: 'gmailMessageId, retryCount',
}

/** A message row as v1 wrote it: no isCalendarInvite column at all. */
function v1Message(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    conversationId: 'c1',
    gmThreadId: 't1',
    rfcMessageId: `<${id}@mail.example.com>`,
    references: '',
    internalDate: 1_800_000_000_000,
    subject: 'Hello',
    snippet: 'Body',
    cleanedSnippet: 'Body',
    chatPreviewText: 'Body',
    bodyText: 'Body',
    hasHtmlBody: 0,
    senderEmail: 'bob@example.com',
    senderName: 'Bob',
    deliveredToAddress: 'me@example.com',
    replyFromAddress: 'me@example.com',
    isFromMe: 0,
    isUnread: 1,
    isNewsletter: 0,
    hasAttachments: 0,
    labelIds: ['INBOX', 'UNREAD'],
    localModifiedAt: 0,
    ...overrides,
  }
}

let name = ''

afterEach(async () => {
  if (name !== '') await Dexie.delete(name)
  name = ''
})

describe('ChatmailDB migrations', () => {
  it('upgrades a populated v1 database, defaulting isCalendarInvite to 0', async () => {
    name = `test_migrate_${crypto.randomUUID()}`

    const v1 = new Dexie(name)
    v1.version(1).stores(V1_STORES)
    await v1.open()
    expect(v1.verno).toBe(1)
    await v1.table('messages').bulkAdd([v1Message('m1'), v1Message('m2', { isNewsletter: 1 })])
    await v1.table('conversations').add({
      id: 'c1',
      keyHash: 'kh',
      participantHash: 'ph',
      type: 'oneToOne',
      displayName: 'Bob',
      snippet: 'Body',
      lastMessageDate: 1_800_000_000_000,
      latestInboxDate: 1_800_000_000_000,
      hasInbox: 1,
      inboxUnreadCount: 1,
      pinned: 0,
      muted: 0,
      archivedAt: 0,
      isArchived: 0,
      createdAt: 1_799_000_000_000,
    })
    await v1.table('bodies').add({ messageId: 'm1', html: '<p>Body</p>' })
    v1.close()

    const db = new ChatmailDB(name)
    await db.open()
    expect(db.verno).toBe(2)

    const messages = await db.messages.orderBy('id').toArray()
    expect(messages.map((m) => m.id)).toEqual(['m1', 'm2'])
    for (const message of messages) {
      expect(message.isCalendarInvite).toBe(0)
      expect(message.calendarEvent).toBeUndefined()
    }
    // Untouched columns and sibling tables survive the upgrade.
    expect(messages[1]?.isNewsletter).toBe(1)
    expect(messages[0]?.labelIds).toEqual(['INBOX', 'UNREAD'])
    expect(await db.conversations.count()).toBe(1)
    expect((await db.bodies.get('m1'))?.html).toBe('<p>Body</p>')

    // The v1 indexes still resolve after the version bump.
    const unread = await db.messages.where('[conversationId+isUnread]').equals(['c1', 1]).count()
    expect(unread).toBe(2)

    db.close()
  })

  it('opens a fresh database directly at the current version', async () => {
    name = `test_fresh_${crypto.randomUUID()}`
    const db = new ChatmailDB(name)
    await db.open()
    expect(db.verno).toBe(2)

    const row: MessageRow = {
      ...(v1Message('m1') as unknown as MessageRow),
      isCalendarInvite: 1,
      calendarEvent: {
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
      },
    }
    await db.messages.add(row)

    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(1)
    expect(stored?.calendarEvent?.title).toBe('Design sync')
    expect(stored?.calendarEvent?.startMs).toBe(Date.UTC(2026, 2, 18, 18, 0, 0))
    db.close()
  })
})

describe('dbNameForAccount', () => {
  it('is stable and case/whitespace insensitive', () => {
    expect(dbNameForAccount('  Me@Example.com ')).toBe(dbNameForAccount('me@example.com'))
  })
})
