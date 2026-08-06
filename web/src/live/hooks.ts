import { useLiveQuery } from 'dexie-react-hooks'
import { getDBIfAvailable, type ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow, OutboundSendRow } from '@/db/types'
import type { SyncProgress } from '@/db/kv'
import {
  queryChatWindow,
  queryConversation,
  queryConversationList,
  queryMessageBody,
  queryOutboundStates,
  queryPendingActionCount,
  querySyncStatus,
  type ConversationPage,
} from './queries'

// All hooks return undefined while the first query resolves — components render
// skeletons on undefined. Dexie liveQuery re-runs on any relevant table write,
// including writes from other tabs (storagemutated propagates cross-context),
// which is the web equivalent of the iOS didSaveObjectIDs channel.

/**
 * Account-scoped live query that becomes unresolved during auth teardown.
 *
 * Auth publishes signed-out before its asynchronous IndexedDB wipe finishes.
 * React may therefore leave the outgoing route mounted for one last liveQuery
 * turn. Treat that expected no-account window like an unresolved query rather
 * than throwing from render; real query failures while the same DB is current
 * still propagate to the route error boundary.
 */
export function useAccountLiveQuery<T>(
  query: (db: ChatmailDB) => Promise<T> | T,
  deps: unknown[] = [],
): T | undefined {
  return useLiveQuery<T | undefined>(async () => {
    const db = getDBIfAvailable()
    if (db === null) return undefined
    try {
      const result = await query(db)
      return getDBIfAvailable() === db ? result : undefined
    } catch (error) {
      if (getDBIfAvailable() !== db) return undefined
      throw error
    }
  }, deps)
}

/** `query` is the committed (debounced) search text; '' means "not searching". */
export function useConversationPage(
  unreadOnly: boolean,
  query: string,
  limit: number,
): ConversationPage | undefined {
  return useAccountLiveQuery(
    (db) => queryConversationList(db, { unreadOnly, query, limit }),
    [unreadOnly, query, limit],
  )
}

export function useConversation(id: string): ConversationRow | undefined {
  return useAccountLiveQuery((db) => queryConversation(db, id), [id])
}

export function useChatWindow(
  conversationId: string,
  limit: number,
): { messages: MessageRow[]; hasOlder: boolean } | undefined {
  return useAccountLiveQuery(
    (db) => queryChatWindow(db, conversationId, { limit }),
    [conversationId, limit],
  )
}

export function useMessageBody(messageId: string): string | null | undefined {
  return useAccountLiveQuery((db) => queryMessageBody(db, messageId), [messageId])
}

export function useSyncStatus(): SyncProgress | undefined {
  return useAccountLiveQuery(querySyncStatus)
}

export function useOutboundStates(conversationId: string): OutboundSendRow[] | undefined {
  return useAccountLiveQuery((db) => queryOutboundStates(db, conversationId), [conversationId])
}

export function usePendingActionCount(): number | undefined {
  return useAccountLiveQuery(queryPendingActionCount)
}
