// Re-derives the stored previews of received HTML messages after the cleanup behind
// them changes: the web half of iOS's ChatPreviewRepair `receivedHTMLRederivation`.
// Ingestion derives chatPreviewText and cleanedSnippet once, at persist time, and
// Gmail never re-sends a message it already delivered, so a signature the cleanup
// has since learned to remove stayed in a stored preview until this pass rewrote it
// from the stored body. Bump CHAT_PREVIEW_DERIVATION_VERSION with any change to the
// HTML cleanup behind createChatPreviewText / createCleanedSnippet that changes their
// output, so stores that finished the walk run it again. Each platform bumps only for
// a change to its own output: iOS keys its pass on
// CacheVersioning.chatPreviewDerivationVersion, and a bump there for a web-only fix
// re-derives every received row on every iOS device for nothing (the full-width MVPN
// fix bumped this constant alone).
//
// Received rows with a stored HTML body only. An outgoing row keeps its composer
// text (an outgoing forward's preview also reads headers that are not stored), and a
// row without a body keeps what its plain text or snippet gave it. The derivation is
// the HTML half of persist's: when the stored body cleans to nothing the row keeps
// its preview, because persist fell back to the plain text, which is stored capped.
//
// Unlike the one-shot repairs this pass can touch every message, so it walks the
// primary key in batches and stops at a per-run budget: a large mailbox converges
// over several syncs. Each batch reads its rows and bodies in a read-only
// transaction, derives with no transaction open, and writes in one short transaction
// that commits the cursor with the rewritten rows and their rollups, unless another
// walker committed since the read. The derivation parses every body and is the slow
// part; run inside the write transaction it held the messages table while a
// mark-read or a send waited behind it. Like the other repairs, a failure is logged
// and the next sync resumes from the last committed batch.
//
// A store the sync fills from empty needs no walk at all, so the sync marks this
// version's walk finished before its network pass while the store is still empty
// (seedChatPreviewRepairOnFreshStoreIfNeeded).

import type { ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { createChatPreviewText, createCleanedSnippet } from '@/mime/preview'
import { rollupConversation } from '@/rollup/rollup'

export const CHAT_PREVIEW_DERIVATION_VERSION =
  '2026-10-30-bottom-posted-rescue-repeated-signature-text-node-whitespace-v1'
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

/** A row whose stored previews the current cleanup derives differently. */
interface RederivedPreviews {
  id: string
  /** The stored values the derivation compared against. */
  readChatPreviewText: string
  readCleanedSnippet: string
  chatPreviewText: string
  cleanedSnippet: string
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
 * Marks this version's walk finished on a store that holds no messages. The sync
 * calls it before its network pass: everything it then stores is derived by the
 * current cleanup, and without the mark the first sync of a new sign-in re-cleaned
 * every message it had just stored. A store that already holds messages (an
 * upgrade) is left to the walk, and so is a store with any state of this version:
 * the walk that state records started from the first message. A failure is logged,
 * and the walk then runs.
 */
export async function seedChatPreviewRepairOnFreshStoreIfNeeded(db: ChatmailDB): Promise<void> {
  try {
    await db.transaction('rw', [db.syncState, db.messages], async () => {
      const state = repairState((await db.syncState.get(CHAT_PREVIEW_REPAIR_KEY))?.value)
      // Finished or not. Returning on a finished state alone probed the messages table
      // on every sync until an upgraded store finished its walk, which takes a large
      // mailbox many syncs.
      if (state?.version === CHAT_PREVIEW_DERIVATION_VERSION) return
      // One key, not count(): IndexedDB counts by walking every key, and this
      // transaction holds the messages table for writing while it does.
      if ((await db.messages.limit(1).primaryKeys()).length > 0) return
      const finished: ChatPreviewRepairState = {
        version: CHAT_PREVIEW_DERIVATION_VERSION,
        lastId: null,
        done: true,
      }
      await db.syncState.put({ key: CHAT_PREVIEW_REPAIR_KEY, value: finished })
    })
  } catch (error) {
    console.warn('[previews] chat preview repair seed failed; the walk will run', error)
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
  const snapshot = await db.transaction('r', [db.syncState, db.messages, db.bodies], async () => {
    const state = repairState((await db.syncState.get(CHAT_PREVIEW_REPAIR_KEY))?.value)
    if (state?.version === CHAT_PREVIEW_DERIVATION_VERSION && state.done) return null
    // A cursor left by an earlier version restarts the walk: rows it already passed
    // were derived by the code that version replaced.
    const cursor = state?.version === CHAT_PREVIEW_DERIVATION_VERSION ? state.lastId : null

    const rows =
      cursor === null
        ? await db.messages.orderBy('id').limit(limit).toArray()
        : await db.messages.where('id').above(cursor).limit(limit).toArray()
    const eligible = rows.filter(isRederivable)
    const bodies = await db.bodies.bulkGet(eligible.map((message) => message.id))
    return { state, cursor, rows, eligible, bodies }
  })
  if (snapshot === null) return null
  const { state, cursor, rows, eligible, bodies } = snapshot

  // No transaction is open here, so the slow part holds no lock.
  const rederived: RederivedPreviews[] = []
  eligible.forEach((message, index) => {
    const html = bodies[index]?.html
    if (html === undefined) return
    const chatPreviewText = createChatPreviewText(html, null, null) ?? message.chatPreviewText
    const cleanedSnippet = createCleanedSnippet(html, null, null) ?? message.cleanedSnippet
    if (chatPreviewText === message.chatPreviewText && cleanedSnippet === message.cleanedSnippet) {
      return
    }
    rederived.push({
      id: message.id,
      readChatPreviewText: message.chatPreviewText,
      readCleanedSnippet: message.cleanedSnippet,
      chatPreviewText,
      cleanedSnippet,
    })
  })

  return db.transaction(
    'rw',
    [db.syncState, db.messages, db.conversations, db.convoParticipants, db.people],
    async () => {
      // Commit only over the state this batch read. Another walker can commit in
      // between: a second tab when navigator.locks is missing (the fallback lock is
      // per tab), or a tab on another build. Writing this batch's cursor over its state
      // moved the cursor back or reopened a finished walk. The rows are dropped with
      // it: a walker that moved the state past them derived them itself, and one that
      // reset it makes the next read start over. The next read resumes from that state.
      const latest = repairState((await db.syncState.get(CHAT_PREVIEW_REPAIR_KEY))?.value)
      if (!isSameRepairState(latest, state)) {
        return { scanned: rows.length, rewritten: 0, recomputed: 0, done: false }
      }

      // Re-read, and write back only the previews: putting the rows back as read would
      // revert a local change made while the batch derived (a mark-read, an archive).
      // A row whose previews no longer hold what the derivation compared against keeps
      // them, because whatever rewrote them read newer inputs, and so does a row that
      // no longer qualifies. No writer outside the sync lock changes either today; the
      // check keeps an outgoing row out of this rule if one ever does. The body is not
      // re-read: only persist replaces a received row's body, and it runs under the
      // sync lock this walk also holds.
      const current = await db.messages.bulkGet(rederived.map((entry) => entry.id))
      const rewritten: MessageRow[] = []
      const conversationIds = new Set<string>()
      rederived.forEach((entry, index) => {
        const message = current[index]
        if (
          message === undefined ||
          !isRederivable(message) ||
          message.chatPreviewText !== entry.readChatPreviewText ||
          message.cleanedSnippet !== entry.readCleanedSnippet
        ) {
          return
        }
        rewritten.push({
          ...message,
          chatPreviewText: entry.chatPreviewText,
          cleanedSnippet: entry.cleanedSnippet,
        })
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

/** Received rows with a stored HTML body: the only rows this pass re-derives. */
function isRederivable(message: MessageRow): boolean {
  return message.isFromMe === 0 && message.hasHtmlBody === 1
}

function isSameRepairState(
  a: ChatPreviewRepairState | null,
  b: ChatPreviewRepairState | null,
): boolean {
  if (a === null || b === null) return a === b
  return a.version === b.version && a.lastId === b.lastId && a.done === b.done
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
