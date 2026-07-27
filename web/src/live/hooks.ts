import { useLiveQuery } from 'dexie-react-hooks'
import { getDB } from '@/db/schema'
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

export function useConversationPage(
  unreadOnly: boolean,
  limit: number,
): ConversationPage | undefined {
  return useLiveQuery(
    () => queryConversationList(getDB(), { unreadOnly, limit }),
    [unreadOnly, limit],
  )
}

export function useConversation(id: string): ConversationRow | undefined {
  return useLiveQuery(() => queryConversation(getDB(), id), [id])
}

export function useChatWindow(
  conversationId: string,
  limit: number,
): { messages: MessageRow[]; hasOlder: boolean } | undefined {
  return useLiveQuery(
    () => queryChatWindow(getDB(), conversationId, { limit }),
    [conversationId, limit],
  )
}

export function useMessageBody(messageId: string): string | null | undefined {
  return useLiveQuery(() => queryMessageBody(getDB(), messageId), [messageId])
}

export function useSyncStatus(): SyncProgress | undefined {
  return useLiveQuery(() => querySyncStatus(getDB()), [])
}

export function useOutboundStates(conversationId: string): OutboundSendRow[] | undefined {
  return useLiveQuery(() => queryOutboundStates(getDB(), conversationId), [conversationId])
}

export function usePendingActionCount(): number | undefined {
  return useLiveQuery(() => queryPendingActionCount(getDB()), [])
}
