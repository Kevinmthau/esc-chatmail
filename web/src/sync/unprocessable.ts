// Tombstones for messages Gmail returns successfully but that the parser
// cannot turn into a row (`parseGmailMessage` → null: no payload/headers).
//
// These are terminal by construction: re-fetching the identical response
// produces the identical null, so they must NOT feed the transient-failure
// pipeline. Counting them as sync failures freezes lastSuccessfulSyncAt, holds
// the history cursor back two syncs out of three, and churns the abandoned
// registry forever, because `findMissedMessageIds` re-lists the id on every
// single sync (it is absent locally and always will be). Instead they are
// parked in `abandonedMessages` with an explicit terminal marker (and the
// legacy retryCount threshold for older readers), which keeps a durable,
// inspectable trace, keeps the drain away from them, and lets the cursor
// advance.

import type { ChatmailDB } from '@/db/schema'
import type { PersistPlan } from './persist'

export const UNPROCESSABLE_REASON = 'Message payload could not be parsed'
// Compatibility marker for older builds that inferred terminal records from
// the former five-attempt ceiling instead of the explicit `terminal` field.
const LEGACY_TERMINAL_RETRY_COUNT = 5

/** Parks unparseable ids as terminal abandoned records (never drained). */
export async function recordUnprocessableMessages(
  db: ChatmailDB,
  gmailMessageIds: readonly string[],
  now: number,
): Promise<void> {
  if (gmailMessageIds.length === 0) return
  await db.transaction('rw', db.abandonedMessages, async () => {
    for (const gmailMessageId of gmailMessageIds) {
      await db.abandonedMessages.put({
        gmailMessageId,
        abandonedAt: now,
        reason: UNPROCESSABLE_REASON,
        retryCount: LEGACY_TERMINAL_RETRY_COUNT,
        terminal: 1,
      })
    }
  })
}

/** The unprocessable ids among `plans`, ready for the registry. */
export function unprocessablePlanIds(plans: readonly PersistPlan[]): string[] {
  return plans.filter((plan) => plan.kind === 'unprocessable').map((plan) => plan.id)
}
