// Local-first user mutations (read/unread, archive, spam). Port of
// Services/PendingActions/MessageActions.swift: apply the change to the local
// store immediately (stamping localModifiedAt so sync's 30-minute conflict
// guard protects it), then enqueue ONE durable PendingAction for the remote
// side. The caller (data/actions facade) triggers a drain afterwards.
//
// Dexie tx rule: everything below is compute → plan → apply with Dexie-only
// awaits inside the transactions.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow } from '@/db/types'
import { enqueue } from './pendingActions'

const ACTION_TABLES = ['messages', 'conversations', 'pendingActions'] as const

function actionTables(db: ChatmailDB) {
  return ACTION_TABLES.map((t) => db[t])
}

function conversationMessagesQuery(db: ChatmailDB, conversationId: string) {
  return db.messages
    .where('[conversationId+internalDate]')
    .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
}

async function unreadInboxMessages(db: ChatmailDB, conversationId: string): Promise<MessageRow[]> {
  return db.messages
    .where('[conversationId+isUnread]')
    .equals([conversationId, 1])
    .filter((message) => message.labelIds.includes('INBOX'))
    .toArray()
}

async function countUnreadInbox(db: ChatmailDB, conversationId: string): Promise<number> {
  return db.messages
    .where('[conversationId+isUnread]')
    .equals([conversationId, 1])
    .filter((message) => message.labelIds.includes('INBOX'))
    .count()
}

/** Recomputes inboxUnreadCount by an actual count — never ±1 arithmetic. */
async function writeRecountedUnread(db: ChatmailDB, conversation: ConversationRow): Promise<void> {
  const inboxUnreadCount = await countUnreadInbox(db, conversation.id)
  await db.conversations.put({ ...conversation, inboxUnreadCount })
}

/** Optimistic sends have no server-side message yet; never enqueue their ids. */
function remoteActionableIds(messages: readonly MessageRow[]): string[] {
  return messages.filter((m) => m.sendState !== 'pending').map((m) => m.id)
}

/**
 * Marks every unread INBOX message in the conversation read, recomputes the
 * conversation's unread count from an actual count, and enqueues ONE batch
 * 'markRead' pending action for the affected ids.
 */
export async function markConversationRead(
  db: ChatmailDB,
  conversationId: string,
  now: number = Date.now(),
): Promise<void> {
  await db.transaction('rw', actionTables(db), async () => {
    const conversation = await db.conversations.get(conversationId)
    if (conversation === undefined) return

    const unread = await unreadInboxMessages(db, conversationId)
    for (const message of unread) {
      await db.messages.put({ ...message, isUnread: 0, localModifiedAt: now })
    }
    await writeRecountedUnread(db, conversation)

    const messageIds = remoteActionableIds(unread)
    if (messageIds.length > 0) {
      await enqueue(db, { actionType: 'markRead', conversationId, messageIds }, now)
    }
  })
}

/**
 * Toggles the conversation's read state: any unread INBOX message → mark all
 * read; otherwise flip the newest INBOX message back to unread.
 */
export async function toggleConversationRead(
  db: ChatmailDB,
  conversationId: string,
  now: number = Date.now(),
): Promise<void> {
  const hasUnread = (await countUnreadInbox(db, conversationId)) > 0
  if (hasUnread) {
    await markConversationRead(db, conversationId, now)
    return
  }

  await db.transaction('rw', actionTables(db), async () => {
    const conversation = await db.conversations.get(conversationId)
    if (conversation === undefined) return

    const newestInbox = await conversationMessagesQuery(db, conversationId)
      .filter((message) => message.labelIds.includes('INBOX'))
      .last()
    if (newestInbox === undefined) return

    await db.messages.put({ ...newestInbox, isUnread: 1, localModifiedAt: now })
    await writeRecountedUnread(db, conversation)

    const messageIds = remoteActionableIds([newestInbox])
    if (messageIds.length > 0) {
      await enqueue(db, { actionType: 'markUnread', conversationId, messageIds }, now)
    }
  })
}

/**
 * Archives a conversation: removes INBOX from every message locally (stamping
 * localModifiedAt), archives the conversation row (clearing its inbox-only
 * indicators, which are now vacuously empty), and enqueues one batch
 * 'archiveConversation' action.
 */
export async function archiveConversation(
  db: ChatmailDB,
  conversationId: string,
  now: number = Date.now(),
): Promise<void> {
  await db.transaction('rw', actionTables(db), async () => {
    const conversation = await db.conversations.get(conversationId)
    if (conversation === undefined) return

    const messages = await conversationMessagesQuery(db, conversationId).toArray()
    const affected = messages.filter((message) => message.labelIds.includes('INBOX'))
    for (const message of affected) {
      await db.messages.put({
        ...message,
        labelIds: message.labelIds.filter((id) => id !== 'INBOX'),
        localModifiedAt: now,
      })
    }

    await db.conversations.put({
      ...conversation,
      archivedAt: now,
      isArchived: 1,
      hasInbox: 0,
      inboxUnreadCount: 0,
      latestInboxDate: 0,
    })

    const messageIds = remoteActionableIds(affected)
    if (messageIds.length > 0) {
      await enqueue(db, { actionType: 'archiveConversation', conversationId, messageIds }, now)
    }
  })
}

/**
 * Reports a conversation as spam: adds SPAM / removes INBOX on every message
 * locally, archives the conversation row, and enqueues one 'reportSpam' batch.
 */
export async function reportSpam(
  db: ChatmailDB,
  conversationId: string,
  now: number = Date.now(),
): Promise<void> {
  await db.transaction('rw', actionTables(db), async () => {
    const conversation = await db.conversations.get(conversationId)
    if (conversation === undefined) return

    const messages = await conversationMessagesQuery(db, conversationId).toArray()
    for (const message of messages) {
      const withoutInbox = message.labelIds.filter((id) => id !== 'INBOX')
      const labelIds = withoutInbox.includes('SPAM') ? withoutInbox : [...withoutInbox, 'SPAM']
      await db.messages.put({ ...message, labelIds, localModifiedAt: now })
    }

    await db.conversations.put({
      ...conversation,
      archivedAt: now,
      isArchived: 1,
      hasInbox: 0,
      inboxUnreadCount: 0,
      latestInboxDate: 0,
    })

    const messageIds = remoteActionableIds(messages)
    if (messageIds.length > 0) {
      await enqueue(db, { actionType: 'reportSpam', conversationId, messageIds }, now)
    }
  })
}
