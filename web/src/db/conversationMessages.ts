import Dexie from 'dexie'
import type { ChatmailDB } from './schema'

/**
 * Every message of a conversation, oldest first, through the
 * [conversationId+internalDate] index. Every writer stores a finite
 * internalDate (parse.ts falls back to Date.now(), the outbox uses its send
 * time), so no row is missing from it. A row whose internalDate is not a valid
 * IndexedDB key would be: callers that delete a conversation once this reads
 * empty must not trust it alone (participantSetRepair checks the index count).
 */
export function conversationMessagesQuery(db: ChatmailDB, conversationId: string) {
  return db.messages
    .where('[conversationId+internalDate]')
    .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
}
