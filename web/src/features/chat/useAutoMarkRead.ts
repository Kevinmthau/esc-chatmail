// Auto-mark-read (port of the ChatView appear/foreground behavior): while the
// chat is mounted, the document is visible, and the conversation has unread
// messages, fire data/actions.markConversationRead after a 500ms debounce.
//
// Triggers, mirroring iOS isChatActiveAndUncovered semantics:
//   - entering the chat (mount / conversation switch): mark unconditionally
//   - visibilitychange back to visible, or the unread count changing while the
//     chat stays mounted (new mail arriving): mark — UNLESS the unread state
//     was just produced locally. The user's explicit "Mark unread" (RowActions
//     while this chat is open in the desktop split view) stamps a fresh
//     localModifiedAt on the newest unread INBOX message
//     (outbox/messageActions.toggleConversationRead); auto-undoing it 500ms
//     later would silently revert the user's action. Genuinely new synced mail
//     always carries localModifiedAt 0, so it still marks read.

import { useEffect, useRef } from 'react'
import { markConversationRead } from '@/data/actions'
import { getDB, type ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { useConversation } from '@/live/hooks'

const MARK_READ_DEBOUNCE_MS = 500

/** How long a local mark-unread suppresses non-entry auto-mark-read. */
export const LOCAL_UNREAD_SUPPRESS_MS = 30_000

/**
 * True when the newest (by internalDate) of the given unread messages was
 * modified locally within the suppression window — the signature of an
 * explicit mark-unread rather than new incoming mail.
 */
export function isFreshLocalUnread(messages: readonly MessageRow[], now: number): boolean {
  let newest: MessageRow | undefined
  for (const message of messages) {
    if (newest === undefined || message.internalDate > newest.internalDate) newest = message
  }
  if (newest === undefined || newest.localModifiedAt === 0) return false
  const age = now - newest.localModifiedAt
  return age >= 0 && age < LOCAL_UNREAD_SUPPRESS_MS
}

/** DB check: does the conversation's newest unread INBOX message carry a fresh local stamp? */
export async function hasFreshLocalUnread(
  db: ChatmailDB,
  conversationId: string,
  now: number = Date.now(),
): Promise<boolean> {
  const unread = await db.messages
    .where('[conversationId+isUnread]')
    .equals([conversationId, 1])
    .filter((message) => message.labelIds.includes('INBOX'))
    .toArray()
  return isFreshLocalUnread(unread, now)
}

export function useAutoMarkRead(conversationId: string): void {
  const conversation = useConversation(conversationId)
  const unreadCount = conversation?.inboxUnreadCount ?? 0
  // Which conversation this hook has already "entered" — lets re-runs of the
  // effect distinguish chat entry (mark unconditionally) from in-place unread
  // changes (respect a fresh local mark-unread).
  const enteredRef = useRef<string | null>(null)

  useEffect(() => {
    const isEntry = enteredRef.current !== conversationId
    enteredRef.current = conversationId
    if (unreadCount === 0) return

    let timer: ReturnType<typeof setTimeout> | undefined
    let cancelled = false

    const fire = async (respectLocalUnread: boolean): Promise<void> => {
      if (respectLocalUnread) {
        try {
          if (await hasFreshLocalUnread(getDB(), conversationId)) return
        } catch {
          return // no account DB open; nothing to mark
        }
        if (cancelled) return
      }
      void markConversationRead(conversationId)
    }

    const schedule = (respectLocalUnread: boolean): void => {
      if (document.visibilityState !== 'visible') return
      timer = setTimeout(() => {
        void fire(respectLocalUnread)
      }, MARK_READ_DEBOUNCE_MS)
    }

    const onVisibilityChange = (): void => {
      if (timer !== undefined) clearTimeout(timer)
      schedule(true)
    }

    schedule(!isEntry)
    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => {
      cancelled = true
      if (timer !== undefined) clearTimeout(timer)
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
  }, [conversationId, unreadCount])
}
