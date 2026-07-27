import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow, OutboundSendRow } from '@/db/types'
import { getSyncProgress, type SyncProgress } from '@/db/kv'
import { matchesConversationSearch } from '@/lib/conversationSearch'

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
 *
 * `unreadOnly` and `query` compose: a row must satisfy both to be visible,
 * mirroring iOS's `matches()` = search AND current filter.
 */
export async function queryConversationList(
  db: ChatmailDB,
  opts: { unreadOnly: boolean; query?: string; limit: number },
): Promise<ConversationPage> {
  const query = opts.query ?? ''
  const rowFilter = opts.unreadOnly || query !== '' ? makeRowFilter(opts.unreadOnly, query) : null

  const pinned = await db.conversations
    .where('[isArchived+pinned+lastMessageDate]')
    .between([0, 1, -Infinity], [0, 1, Infinity])
    .reverse()
    .toArray()

  let unpinnedQuery = db.conversations
    .where('[isArchived+pinned+lastMessageDate]')
    .between([0, 0, -Infinity], [0, 0, Infinity])
    .reverse()

  // Row predicates go through Dexie's Collection.filter — not an Array.filter
  // on the page we just read. Dexie evaluates the predicate inside the cursor
  // loop and `.limit()` only counts rows that survive it, so the cursor keeps
  // walking the [isArchived+pinned+lastMessageDate] index until `limit + 1`
  // matches land. That keeps pages full and `hasMore` honest even when matches
  // are sparse (a query hitting 3 of every 1000 rows still fills a page), which
  // is exactly what the list's grow-the-limit infinite scroll depends on:
  // filtering after the read would hand back a short page with hasMore=false
  // and strand every later match below the fold.
  //
  // The cost is that a filtered read is a cursor walk rather than the indexed
  // fast path — O(rows scanned) to reach the k-th match. That is inherent to
  // substring search in IndexedDB (there is no substring index to build on) and
  // is bounded by the conversation count, which is orders of magnitude smaller
  // than the message count. Paging stays keyset-based; nothing here uses offset.
  if (rowFilter !== null) {
    unpinnedQuery = unpinnedQuery.filter(rowFilter)
  }
  const unpinned = await unpinnedQuery.limit(opts.limit + 1).toArray()

  const hasMore = unpinned.length > opts.limit
  return {
    // The pinned block is read whole (it is small by construction), so a plain
    // post-read filter is fine here — there is no page to come up short.
    pinned: rowFilter !== null ? pinned.filter(rowFilter) : pinned,
    unpinned: hasMore ? unpinned.slice(0, opts.limit) : unpinned,
    hasMore,
  }
}

function makeRowFilter(unreadOnly: boolean, query: string): (c: ConversationRow) => boolean {
  return (c) => (!unreadOnly || c.inboxUnreadCount > 0) && matchesConversationSearch(c, query)
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
