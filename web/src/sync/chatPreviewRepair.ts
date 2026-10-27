// Re-derives the stored previews of received HTML messages after the cleanup behind
// them changes: the web half of iOS's ChatPreviewRepair `receivedHTMLRederivation`.
// Ingestion derives chatPreviewText and cleanedSnippet once, at persist time, and
// Gmail never re-sends a message it already delivered, so a signature the cleanup
// has since learned to remove stayed in a stored preview until this pass rewrote it
// from the stored body. Bump CHAT_PREVIEW_DERIVATION_VERSION with any change to the
// HTML cleanup behind createChatPreviewText / createCleanedSnippet that changes their
// output (iOS bumps CacheVersioning.chatPreviewDerivationVersion for the same
// changes), so stores that finished the walk run it again.
//
// Received rows with a stored HTML body only. An outgoing row keeps its composer
// text (an outgoing forward's preview also reads headers that are not stored), and a
// row without a body keeps what its plain text or snippet gave it. The derivation is
// the HTML half of persist's: when the stored body cleans to nothing the row keeps
// its preview, because persist fell back to the plain text, which is stored capped.
//
// Unlike the one-shot repairs this pass can touch every message, so it walks the
// primary key in batches, each in its own transaction that commits the cursor with
// the rewritten rows and their rollups, and stops at a per-run budget. A large
// mailbox converges over several syncs instead of one long transaction holding the
// messages table. Like the other repairs, a failure is logged and the next sync
// resumes from the last committed batch.

import type { ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { createChatPreviewText, createCleanedSnippet } from '@/mime/preview'
import { rollupConversation } from '@/rollup/rollup'

export const CHAT_PREVIEW_DERIVATION_VERSION = '2026-10-27-signature-mvpn-inline-v1'
export const CHAT_PREVIEW_REPAIR_KEY = 'chatPreviewRepair'
export const CHAT_PREVIEW_REPAIR_BATCH_SIZE = 100
export const CHAT_PREVIEW_REPAIR_MESSAGES_PER_RUN = 1000

interface ChatPreviewRepairState {
  version: string
  /** Last message id a committed batch scanned; null before the first batch. */
  lastId: string | null
  done: boolean
}

export interface ChatPreviewRepairResult {
  /** False means this version's walk had already finished. */
  performed: boolean
  /** True once the walk reached the last message for this version. */
  completed: boolean
  scannedMessageCount: number
  rewrittenMessageCount: number
  recomputedConversationCount: number
}

/**
 * Runs up to one budget of the repair. A failure is logged and the next sync
 * resumes from the last committed batch; the sync that ran it carries on.
 */
export async function repairStoredChatPreviewsIfNeeded(db: ChatmailDB, now: number): Promise<void> {
  try {
    await rederiveStoredChatPreviews(db, now)
  } catch (error) {
    console.warn('[previews] chat preview repair failed; will retry', error)
  }
}

/**
 * Walks the messages from the stored cursor, rewriting the previews the current
 * cleanup derives differently and recomputing their conversations' rollups, until
 * the walk finishes or `budget` messages have been scanned.
 */
export async function rederiveStoredChatPreviews(
  db: ChatmailDB,
  now: number,
  budget = CHAT_PREVIEW_REPAIR_MESSAGES_PER_RUN,
): Promise<ChatPreviewRepairResult> {
  const result: ChatPreviewRepairResult = {
    performed: false,
    completed: false,
    scannedMessageCount: 0,
    rewrittenMessageCount: 0,
    recomputedConversationCount: 0,
  }
  while (result.scannedMessageCount < budget) {
    const limit = Math.min(CHAT_PREVIEW_REPAIR_BATCH_SIZE, budget - result.scannedMessageCount)
    const batch = await rederiveBatch(db, now, limit)
    if (batch === null) return result
    result.performed = true
    result.scannedMessageCount += batch.scanned
    result.rewrittenMessageCount += batch.rewritten
    result.recomputedConversationCount += batch.recomputed
    if (batch.done) {
      result.completed = true
      break
    }
  }
  return result
}

async function rederiveBatch(
  db: ChatmailDB,
  now: number,
  limit: number,
): Promise<{ scanned: number; rewritten: number; recomputed: number; done: boolean } | null> {
  return db.transaction(
    'rw',
    [db.syncState, db.messages, db.bodies, db.conversations],
    async () => {
      const state = repairState((await db.syncState.get(CHAT_PREVIEW_REPAIR_KEY))?.value)
      if (state?.version === CHAT_PREVIEW_DERIVATION_VERSION && state.done) return null
      // A cursor left by an earlier version restarts the walk: rows it already passed
      // were derived by the code that version replaced.
      const cursor = state?.version === CHAT_PREVIEW_DERIVATION_VERSION ? state.lastId : null

      const rows =
        cursor === null
          ? await db.messages.orderBy('id').limit(limit).toArray()
          : await db.messages.where('id').above(cursor).limit(limit).toArray()
      const eligible = rows.filter((message) => message.isFromMe === 0 && message.hasHtmlBody === 1)
      const bodies = await db.bodies.bulkGet(eligible.map((message) => message.id))

      const rewritten: MessageRow[] = []
      const conversationIds = new Set<string>()
      eligible.forEach((message, index) => {
        const html = bodies[index]?.html
        if (html === undefined) return
        const chatPreviewText = createChatPreviewText(html, null, null)
        const cleanedSnippet = createCleanedSnippet(html, null, null)
        let changed = false
        if (chatPreviewText !== null && chatPreviewText !== message.chatPreviewText) {
          message.chatPreviewText = chatPreviewText
          changed = true
        }
        if (cleanedSnippet !== null && cleanedSnippet !== message.cleanedSnippet) {
          message.cleanedSnippet = cleanedSnippet
          changed = true
        }
        if (!changed) return
        rewritten.push(message)
        conversationIds.add(message.conversationId)
      })

      if (rewritten.length > 0) {
        await db.messages.bulkPut(rewritten)
        // Nested into this transaction, so each rollup reads the rewritten rows.
        for (const conversationId of conversationIds) {
          await rollupConversation(db, conversationId, now)
        }
      }

      const done = rows.length < limit
      const next: ChatPreviewRepairState = {
        version: CHAT_PREVIEW_DERIVATION_VERSION,
        lastId: rows.at(-1)?.id ?? cursor,
        done,
      }
      // Last write by design: the cursor commits with this batch's rows or not at all.
      await db.syncState.put({ key: CHAT_PREVIEW_REPAIR_KEY, value: next })

      return {
        scanned: rows.length,
        rewritten: rewritten.length,
        recomputed: conversationIds.size,
        done,
      }
    },
  )
}

function repairState(value: unknown): ChatPreviewRepairState | null {
  if (typeof value !== 'object' || value === null) return null
  const candidate = value as Partial<ChatPreviewRepairState>
  if (typeof candidate.version !== 'string' || typeof candidate.done !== 'boolean') return null
  return {
    version: candidate.version,
    lastId: typeof candidate.lastId === 'string' ? candidate.lastId : null,
    done: candidate.done,
  }
}
