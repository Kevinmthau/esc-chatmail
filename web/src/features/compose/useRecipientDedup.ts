import { useEffect, useState } from 'react'
import { findConversationByParticipants } from '@/data/actions'
import { getDB } from '@/db/schema'
import { validRecipientEmails, type RecipientChipData } from './recipients'

export interface ExistingChatMatch {
  conversationId: string
  /** Name for the "You already have a chat with <name>" banner. */
  displayName: string
}

// Emails cannot contain newlines, so '\n' is a safe dep-key separator.
const KEY_SEPARATOR = '\n'

/**
 * Dedup-to-existing-chat (port of the iOS compose participant-hash dedup):
 * whenever the committed chip set changes and holds at least one valid
 * address, look up the active conversation epoch for that participant set.
 */
export function useRecipientDedup(chips: readonly RecipientChipData[]): ExistingChatMatch | null {
  const [match, setMatch] = useState<ExistingChatMatch | null>(null)
  const key = validRecipientEmails(chips).join(KEY_SEPARATOR)

  useEffect(() => {
    const emails = key === '' ? [] : key.split(KEY_SEPARATOR)
    if (emails.length === 0) {
      setMatch(null)
      return
    }
    let cancelled = false
    void (async () => {
      try {
        const conversationId = await findConversationByParticipants(emails)
        if (cancelled) return
        if (conversationId === null) {
          setMatch(null)
          return
        }
        const conversation = await getDB().conversations.get(conversationId)
        if (cancelled) return
        setMatch({
          conversationId,
          displayName: conversation?.displayName ?? '',
        })
      } catch {
        if (!cancelled) setMatch(null)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [key])

  return match
}
