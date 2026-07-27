import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import {
  archiveConversation,
  markConversationRead,
  reportSpam,
  toggleConversationRead,
} from './messageActions'
import { convoRow, makeTestDb, msgRow, NOW } from './testSupport'

describe('messageActions', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = makeTestDb()
  })

  afterEach(async () => {
    await db.delete()
  })

  describe('markConversationRead', () => {
    it('marks unread INBOX messages read, recounts, and enqueues ONE batch action', async () => {
      await db.conversations.add(convoRow({ id: 'c1', inboxUnreadCount: 2 }))
      await db.messages.bulkAdd([
        msgRow({ id: 'm1', conversationId: 'c1', isUnread: 1, internalDate: NOW - 3000 }),
        msgRow({ id: 'm2', conversationId: 'c1', isUnread: 1, internalDate: NOW - 2000 }),
        msgRow({ id: 'm3', conversationId: 'c1', isUnread: 0, internalDate: NOW - 1000 }),
        // Unread but NOT in INBOX: untouched.
        msgRow({
          id: 'm4',
          conversationId: 'c1',
          isUnread: 1,
          labelIds: ['SENT'],
          internalDate: NOW - 500,
        }),
      ])

      await markConversationRead(db, 'c1', NOW)

      const m1 = await db.messages.get('m1')
      const m2 = await db.messages.get('m2')
      expect(m1?.isUnread).toBe(0)
      expect(m2?.isUnread).toBe(0)
      expect(m1?.localModifiedAt).toBe(NOW)
      expect(m2?.localModifiedAt).toBe(NOW)
      expect((await db.messages.get('m4'))?.isUnread).toBe(1)
      expect((await db.messages.get('m3'))?.localModifiedAt).toBe(0)

      // Recomputed by actual count, not arithmetic.
      expect((await db.conversations.get('c1'))?.inboxUnreadCount).toBe(0)

      const actions = await db.pendingActions.toArray()
      expect(actions).toHaveLength(1)
      expect(actions[0]?.actionType).toBe('markRead')
      expect(actions[0]?.status).toBe('pending')
      expect(new Set(actions[0]?.messageIds)).toEqual(new Set(['m1', 'm2']))
    })

    it('enqueues nothing when there is nothing unread', async () => {
      await db.conversations.add(convoRow({ id: 'c1', inboxUnreadCount: 3 }))
      await db.messages.add(msgRow({ id: 'm1', conversationId: 'c1', isUnread: 0 }))

      await markConversationRead(db, 'c1', NOW)

      expect(await db.pendingActions.count()).toBe(0)
      // Stale seeded count is still corrected by the recount.
      expect((await db.conversations.get('c1'))?.inboxUnreadCount).toBe(0)
    })
  })

  describe('toggleConversationRead', () => {
    it('marks read when any inbox message is unread', async () => {
      await db.conversations.add(convoRow({ id: 'c1', inboxUnreadCount: 1 }))
      await db.messages.add(msgRow({ id: 'm1', conversationId: 'c1', isUnread: 1 }))

      await toggleConversationRead(db, 'c1', NOW)

      expect((await db.messages.get('m1'))?.isUnread).toBe(0)
      expect((await db.pendingActions.toArray())[0]?.actionType).toBe('markRead')
    })

    it('flips the newest INBOX message unread when everything is read', async () => {
      await db.conversations.add(convoRow({ id: 'c1', inboxUnreadCount: 0 }))
      await db.messages.bulkAdd([
        msgRow({ id: 'm_old', conversationId: 'c1', internalDate: NOW - 5000 }),
        msgRow({ id: 'm_new', conversationId: 'c1', internalDate: NOW - 1000 }),
        // Newer but not INBOX: must not be the flip target.
        msgRow({
          id: 'm_sent',
          conversationId: 'c1',
          internalDate: NOW - 500,
          labelIds: ['SENT'],
        }),
      ])

      await toggleConversationRead(db, 'c1', NOW)

      expect((await db.messages.get('m_new'))?.isUnread).toBe(1)
      expect((await db.messages.get('m_new'))?.localModifiedAt).toBe(NOW)
      expect((await db.messages.get('m_old'))?.isUnread).toBe(0)
      expect((await db.conversations.get('c1'))?.inboxUnreadCount).toBe(1)

      const actions = await db.pendingActions.toArray()
      expect(actions).toHaveLength(1)
      expect(actions[0]?.actionType).toBe('markUnread')
      expect(actions[0]?.messageIds).toEqual(['m_new'])
    })
  })

  describe('archiveConversation', () => {
    it('removes INBOX locally, archives the row, and enqueues a batch action', async () => {
      await db.conversations.add(convoRow({ id: 'c1', inboxUnreadCount: 1 }))
      await db.messages.bulkAdd([
        msgRow({
          id: 'm1',
          conversationId: 'c1',
          labelIds: ['INBOX', 'UNREAD', 'IMPORTANT'],
          isUnread: 1,
        }),
        msgRow({ id: 'm2', conversationId: 'c1', labelIds: ['SENT'], internalDate: NOW - 500 }),
      ])

      await archiveConversation(db, 'c1', NOW)

      const m1 = await db.messages.get('m1')
      expect(m1?.labelIds).toEqual(['UNREAD', 'IMPORTANT'])
      expect(m1?.localModifiedAt).toBe(NOW)
      // Non-INBOX messages untouched.
      expect((await db.messages.get('m2'))?.localModifiedAt).toBe(0)

      const conversation = await db.conversations.get('c1')
      expect(conversation?.archivedAt).toBe(NOW)
      expect(conversation?.isArchived).toBe(1)
      expect(conversation?.hasInbox).toBe(0)
      expect(conversation?.inboxUnreadCount).toBe(0)

      const actions = await db.pendingActions.toArray()
      expect(actions).toHaveLength(1)
      expect(actions[0]?.actionType).toBe('archiveConversation')
      expect(actions[0]?.messageIds).toEqual(['m1'])
    })
  })

  describe('reportSpam', () => {
    it('adds SPAM/removes INBOX, archives, and enqueues; skips optimistic sends remotely', async () => {
      await db.conversations.add(convoRow({ id: 'c1' }))
      await db.messages.bulkAdd([
        msgRow({ id: 'm1', conversationId: 'c1', labelIds: ['INBOX'] }),
        msgRow({
          id: 'u_optimistic',
          conversationId: 'c1',
          labelIds: ['SENT'],
          sendState: 'pending',
          internalDate: NOW - 100,
        }),
      ])

      await reportSpam(db, 'c1', NOW)

      const m1 = await db.messages.get('m1')
      expect(m1?.labelIds).toEqual(['SPAM'])
      expect(m1?.localModifiedAt).toBe(NOW)

      const conversation = await db.conversations.get('c1')
      expect(conversation?.isArchived).toBe(1)
      expect(conversation?.archivedAt).toBe(NOW)

      const actions = await db.pendingActions.toArray()
      expect(actions).toHaveLength(1)
      expect(actions[0]?.actionType).toBe('reportSpam')
      // The optimistic message has no server id yet — never sent remotely.
      expect(actions[0]?.messageIds).toEqual(['m1'])
    })
  })
})
