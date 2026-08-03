// Sync failure tracking + abandoned-message registry. Port of
// SyncFailureTracker.swift: after 3 consecutive failed syncs over the same
// stuck ids, the ids are written to abandonedMessages and the history cursor
// advances anyway (deadlock prevention). Each later sync drains up to 50
// abandoned ids with ONE fetch attempt each. Transient records remain durable
// until recovered or confirmed gone, with capped backoff between attempts.

import type { ChatmailDB } from '@/db/schema'
import type { GmailSyncApi } from './deps'
import { fetchMessagesBounded, type FetchMessagesOptions } from './fetch'
import { applyPersist, preparePersist, type PersistContext } from './persist'
import { recordUnprocessableMessages, unprocessablePlanIds } from './unprocessable'

export const MAX_CONSECUTIVE_SYNC_FAILURES = 3
export const MAX_ABANDONED_RETRIES = 5
export const MAX_ABANDONED_PER_SYNC = 50
export const ABANDONED_RETRY_BASE_DELAY_MS = 5 * 60 * 1000
export const ABANDONED_RETRY_MAX_DELAY_MS = 24 * 60 * 60 * 1000

const LEGACY_UNPROCESSABLE_REASON = 'Message payload could not be parsed'

const CONSECUTIVE_FAILURES_KEY = 'syncConsecutiveFailures'
const PERSISTENT_FAILED_IDS_KEY = 'syncPersistentFailedIds'

function isTerminalRecord(record: { terminal?: 0 | 1; reason: string }): boolean {
  // Before `terminal` existed, retryCount=5 plus this exact reason was the
  // only marker for parser tombstones. Other legacy rows remain recoverable.
  return (
    record.terminal === 1 ||
    (record.terminal === undefined && record.reason === LEGACY_UNPROCESSABLE_REASON)
  )
}

export function abandonedRetryDelayMs(retryCount: number): number {
  const exponent = Math.min(Math.max(0, retryCount - 1), 20)
  return Math.min(ABANDONED_RETRY_BASE_DELAY_MS * 2 ** exponent, ABANDONED_RETRY_MAX_DELAY_MS)
}

async function getKvNumber(db: ChatmailDB, key: string): Promise<number> {
  const row = await db.syncState.get(key)
  return (row?.value as number | undefined) ?? 0
}

async function getKvStrings(db: ChatmailDB, key: string): Promise<string[]> {
  const row = await db.syncState.get(key)
  return (row?.value as string[] | undefined) ?? []
}

export async function consecutiveFailureCount(db: ChatmailDB): Promise<number> {
  return getKvNumber(db, CONSECUTIVE_FAILURES_KEY)
}

export async function persistentFailedIds(db: ChatmailDB): Promise<string[]> {
  return getKvStrings(db, PERSISTENT_FAILED_IDS_KEY)
}

/** Resets failure tracking after a fully successful sync. */
export async function recordSyncSuccess(db: ChatmailDB): Promise<void> {
  await db.transaction('rw', db.syncState, async () => {
    await db.syncState.put({ key: CONSECUTIVE_FAILURES_KEY, value: 0 })
    await db.syncState.delete(PERSISTENT_FAILED_IDS_KEY)
  })
}

/** Records failed ids and increments the consecutive-failure counter. */
export async function recordSyncFailure(
  db: ChatmailDB,
  failedIds: readonly string[],
): Promise<void> {
  if (failedIds.length === 0) return
  await db.transaction('rw', db.syncState, async () => {
    const count =
      ((await db.syncState.get(CONSECUTIVE_FAILURES_KEY))?.value as number | undefined) ?? 0
    await db.syncState.put({ key: CONSECUTIVE_FAILURES_KEY, value: count + 1 })

    const existing =
      ((await db.syncState.get(PERSISTENT_FAILED_IDS_KEY))?.value as string[] | undefined) ?? []
    const existingSet = new Set(existing)
    const merged = [...existing, ...failedIds.filter((id) => !existingSet.has(id))]
    await db.syncState.put({ key: PERSISTENT_FAILED_IDS_KEY, value: merged })
  })
}

/**
 * Whether the history cursor may advance despite fetch failures. True when
 * there were no failures, or when MAX_CONSECUTIVE_SYNC_FAILURES is reached —
 * in which case the tracked ids are persisted to abandonedMessages (retryCount
 * 0; the drain owns the retry budget) and tracking resets.
 *
 * Callers must recordSyncFailure BEFORE consulting this.
 */
export async function shouldAdvanceHistoryId(
  db: ChatmailDB,
  hadFailures: boolean,
  now: number,
): Promise<boolean> {
  if (!hadFailures) {
    await recordSyncSuccess(db)
    return true
  }

  const failures = await consecutiveFailureCount(db)
  if (failures < MAX_CONSECUTIVE_SYNC_FAILURES) return false

  const ids = await persistentFailedIds(db)
  await db.transaction('rw', db.syncState, db.abandonedMessages, async () => {
    for (const gmailMessageId of ids) {
      const existing = await db.abandonedMessages.get(gmailMessageId)
      if (existing !== undefined) {
        // retryCount is owned by the drain; re-abandonment must not consume it.
        await db.abandonedMessages.put({
          ...existing,
          abandonedAt: now,
          reason: 'Max sync failures reached',
          terminal: isTerminalRecord(existing) ? 1 : 0,
        })
      } else {
        await db.abandonedMessages.put({
          gmailMessageId,
          abandonedAt: now,
          reason: 'Max sync failures reached',
          retryCount: 0,
          terminal: 0,
          nextAttemptAt: now,
        })
      }
    }
    await db.syncState.put({ key: CONSECUTIVE_FAILURES_KEY, value: 0 })
    await db.syncState.delete(PERSISTENT_FAILED_IDS_KEY)
  })
  return true
}

/** Due transient abandoned ids, oldest due time first. */
export async function retryableAbandonedIds(
  db: ChatmailDB,
  now = Date.now(),
  limit = MAX_ABANDONED_PER_SYNC,
): Promise<string[]> {
  const rows = await db.abandonedMessages.toArray()
  return rows
    .filter(
      (row) =>
        !isTerminalRecord(row) && (row.nextAttemptAt === undefined || row.nextAttemptAt <= now),
    )
    .sort(
      (a, b) => (a.nextAttemptAt ?? 0) - (b.nextAttemptAt ?? 0) || a.abandonedAt - b.abandonedAt,
    )
    .slice(0, limit)
    .map((row) => row.gmailMessageId)
}

export interface AbandonedDrainOutcome {
  recoveredIds: string[]
  goneIds: string[]
  failedIds: string[]
}

/**
 * Applies a drain outcome: recovered and server-side-deleted ids leave the
 * registry; transient failures remain durable and receive capped exponential
 * backoff. Terminal parser tombstones are never touched by the drain.
 */
export async function recordAbandonedRetryOutcome(
  db: ChatmailDB,
  outcome: AbandonedDrainOutcome,
  now = Date.now(),
): Promise<void> {
  const resolved = new Set([...outcome.recoveredIds, ...outcome.goneIds])
  if (resolved.size === 0 && outcome.failedIds.length === 0) return

  await db.transaction('rw', db.abandonedMessages, async () => {
    for (const id of resolved) {
      await db.abandonedMessages.delete(id)
    }
    for (const id of new Set(outcome.failedIds)) {
      const record = await db.abandonedMessages.get(id)
      if (record === undefined || isTerminalRecord(record)) continue
      const retryCount = record.retryCount + 1
      await db.abandonedMessages.put({
        ...record,
        retryCount,
        terminal: 0,
        lastAttemptAt: now,
        nextAttemptAt: now + abandonedRetryDelayMs(retryCount),
      })
    }
  })
}

export interface AbandonedDrainResult {
  outcome: AbandonedDrainOutcome
  touchedConversationIds: Set<string>
}

/**
 * One retry pass over abandoned ids (max 50, ONE fetch attempt each).
 * Recovered messages are persisted; the returned outcome must be applied via
 * recordAbandonedRetryOutcome only AFTER the sync's durable save, so a failed
 * save keeps the records for retry. Drain failures never block cursor
 * advancement — the cursor moved past these ids when they were abandoned.
 */
export async function drainAbandoned(
  db: ChatmailDB,
  api: GmailSyncApi,
  ctx: PersistContext,
  now: number,
  fetchOptions: FetchMessagesOptions = {},
): Promise<AbandonedDrainResult> {
  const empty: AbandonedDrainResult = {
    outcome: { recoveredIds: [], goneIds: [], failedIds: [] },
    touchedConversationIds: new Set(),
  }
  const ids = await retryableAbandonedIds(db, now)
  if (ids.length === 0) return empty

  const fetchResult = await fetchMessagesBounded(api, ids, { ...fetchOptions, maxAttempts: 1 })

  const plans = await preparePersist(fetchResult.fetched, ctx)
  const terminalIds = new Set(unprocessablePlanIds(plans))
  await recordUnprocessableMessages(db, [...terminalIds], now)
  const applied = await applyPersist(db, plans, now)

  // "Recovered" is what actually reached the store (or is now known to live in
  // an excluded mailbox), not what was fetched — otherwise the record would be
  // deleted with nothing to show for it.
  const resolvedIds = new Set<string>(
    [...applied.persistedMessageIds].filter((id) => !applied.retryableMessageIds.has(id)),
  )
  for (const plan of plans) {
    if (plan.kind === 'excluded') resolvedIds.add(plan.id)
  }
  const recoveredIds = fetchResult.fetched.map((m) => m.id).filter((id) => resolvedIds.has(id))
  const unpersisted = fetchResult.fetched
    .map((m) => m.id)
    .filter((id) => !resolvedIds.has(id) && !terminalIds.has(id))

  return {
    outcome: {
      recoveredIds,
      goneIds: fetchResult.goneIds,
      failedIds: [...fetchResult.failed.map((f) => f.id), ...unpersisted],
    },
    touchedConversationIds: applied.touchedConversationIds,
  }
}
