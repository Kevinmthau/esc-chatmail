import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow, OutboundSendRow } from '@/db/types'
import { getSyncProgress, type SyncProgress } from '@/db/kv'

// Canonical read queries the UI consumes through useLiveQuery. Paging is
// keyset-based (never offset — offset is O(n) cursor walking in IndexedDB).

export interface ConversationPage {
  pinned: ConversationRow[]
  unpinned: ConversationRow[]
  /** True when another page of unpinned conversations likely exists. */
  hasMore: boolean
}

/**
 * Active conversations, pinned block first, then unpinned newest-first,
 * both driven by the [isArchived+pinned+lastMessageDate] index.
 */
export async function queryConversationList(
  db: ChatmailDB,
  opts: { unreadOnly: boolean; limit: number },
): Promise<ConversationPage> {
  const pinned = await db.conversations
    .where('[isArchived+pinned+lastMessageDate]')
    .between([0, 1, -Infinity], [0, 1, Infinity])
    .reverse()
    .toArray()

  let unpinnedQuery = db.conversations
    .where('[isArchived+pinned+lastMessageDate]')
    .between([0, 0, -Infinity], [0, 0, Infinity])
    .reverse()

  if (opts.unreadOnly) {
    unpinnedQuery = unpinnedQuery.filter((c) => c.inboxUnreadCount > 0)
  }
  const unpinned = await unpinnedQuery.limit(opts.limit + 1).toArray()

  const hasMore = unpinned.length > opts.limit
  return {
    pinned: opts.unreadOnly ? pinned.filter((c) => c.inboxUnreadCount > 0) : pinned,
    unpinned: hasMore ? unpinned.slice(0, opts.limit) : unpinned,
    hasMore,
  }
}

/**
 * Newest `limit` messages of a conversation, returned oldest→newest.
 * Load-older passes a smaller `before` (exclusive internalDate upper bound).
 */
export async function queryChatWindow(
  db: ChatmailDB,
  conversationId: string,
  opts: { limit: number; before?: number },
): Promise<{ messages: MessageRow[]; hasOlder: boolean }> {
  const upper = opts.before ?? Infinity
  const page = await db.messages
    .where('[conversationId+internalDate]')
    .between([conversationId, -Infinity], [conversationId, upper], true, false)
    .reverse()
    .limit(opts.limit + 1)
    .toArray()
  const hasOlder = page.length > opts.limit
  const window = hasOlder ? page.slice(0, opts.limit) : page
  window.reverse()
  return { messages: window, hasOlder }
}

export async function queryConversation(
  db: ChatmailDB,
  id: string,
): Promise<ConversationRow | undefined> {
  return db.conversations.get(id)
}

export async function queryMessageBody(db: ChatmailDB, messageId: string): Promise<string | null> {
  const row = await db.bodies.get(messageId)
  return row?.html ?? null
}

export async function querySyncStatus(db: ChatmailDB): Promise<SyncProgress> {
  return getSyncProgress(db)
}

export async function queryOutboundStates(
  db: ChatmailDB,
  conversationId: string,
): Promise<OutboundSendRow[]> {
  // The journal is tiny (in-flight sends only); a table scan is fine.
  const all = await db.outboundSends.toArray()
  return all.filter((s) => s.conversationId === conversationId && s.status !== 'finalized')
}

export async function queryPendingActionCount(db: ChatmailDB): Promise<number> {
  return db.pendingActions.where('status').anyOf(['pending', 'processing', 'failed']).count()
}
