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
import { isLocalOptimisticRow } from './replyMetadata'

const ACTION_TABLES = ['messages', 'conversations', 'pendingActions', 'outboundSends'] as const

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

/**
 * The ids a conversation-wide Gmail action may name: only rows with a Gmail
 * id of their own (MessageActions.gmailMessageIDForConversationAction).
 *
 * The user's own send keeps its local UUID until sync replaces it with
 * Gmail's echo: while it sends, and for good once retained as not sent
 * (sendState 'failed') or delivery unknown (shown as sent, with an
 * 'ambiguous' outbound journal under its id). That is not a Gmail message
 * id. One such id in the single batchModify this action becomes made Gmail
 * reject the whole request, and the processor abandons a non-retriable
 * failure at once, so the archive or spam report never reached Gmail for any
 * message in the conversation — while the local change stood until sync
 * reverted it. The row still takes the local change; its echo arrives as an
 * outgoing message, which is never inbox presence.
 */
async function remoteActionableIds(
  db: ChatmailDB,
  messages: readonly MessageRow[],
): Promise<string[]> {
  const candidates = messages.filter((m) => !isLocalOptimisticRow(m))
  if (candidates.length === 0) return []
  const journaled = new Set(
    await db.outboundSends
      .where('id')
      .anyOf(candidates.map((m) => m.id))
      .primaryKeys(),
  )
  return candidates.filter((m) => !journaled.has(m.id)).map((m) => m.id)
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

    const messageIds = await remoteActionableIds(db, unread)
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

    const messageIds = await remoteActionableIds(db, [newestInbox])
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

    const messageIds = await remoteActionableIds(db, affected)
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

    const messageIds = await remoteActionableIds(db, messages)
    if (messageIds.length > 0) {
      await enqueue(db, { actionType: 'reportSpam', conversationId, messageIds }, now)
    }
  })
}
