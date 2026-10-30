// Incremental sync via the Gmail History API. Port of
// IncrementalSyncOrchestrator + HistoryProcessor(+LabelOperations,
// +MessageDeletions) + HistoryCollectionPhase.
//
// Phase order (invariant-critical):
//   1  history collection (≤50 pages per slice, resuming from a stored
//      continuation token; truncation keeps the ORIGINAL cursor and stages
//      the next page token instead)
//   2  fetch + persist new messages
//   2b abandoned drain (failures never block cursor advancement)
//   3  label ops — AFTER fetch so the rows exist — deletions, then adds, then
//      removals, respecting the 30-min localModifiedAt guard
//   4  reconciliation (missed-message check every sync; label repair on TTL)
//   ∎  finalize: historyId or continuation + rollups in ONE rw transaction.

import {
  clearHistoryContinuation,
  getHistoryContinuation,
  getLastSuccessfulSyncAt,
  setHistoryContinuation,
  setLabelReconciledAt,
  setLastSuccessfulSyncAt,
  setSyncProgress,
} from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import type { AccountRow, Flag } from '@/db/types'
import { GmailApiError } from '@/gmail/errors'
import { HistoryIdExpiredError } from '@/gmail/historyError'
import type { HistoryRecord } from '@/gmail/types'
import { rollupConversation, EXCLUDED_MAILBOX_LABEL_IDS } from '@/rollup/rollup'
import {
  drainAbandoned,
  recordAbandonedRetryOutcome,
  recordSyncFailure,
  recordSyncSuccess,
  shouldAdvanceHistoryId,
  type AbandonedDrainOutcome,
} from './abandoned'
import { persistAccountAliases } from './aliases'
import { depsNow, depsRandom, depsSleep, type SyncDeps } from './deps'
import { fetchMessagesBounded } from './fetch'
import {
  buildPersistContext,
  listSyncPages,
  runInitialSync,
  type InitialSyncResult,
} from './initial'
import {
  applyFastUpdateForExistingMessage,
  applyPersist,
  LOCAL_MODIFICATION_MAX_AGE_MS,
  preparePersist,
  retryableFailurePlanIds,
  type PersistContext,
} from './persist'
import { findMissedMessageIds, reconcileLabels, SYNC_QUERY_EXCLUSIONS } from './reconcile'
import { recordUnprocessableMessages, unprocessablePlanIds } from './unprocessable'

export const MAX_HISTORY_PAGES = 50
/** History-recovery lookback: lastSync − 10 min, floored at install − 5 min. */
export const RECOVERY_LAST_SYNC_BUFFER_MS = 10 * 60 * 1000
export const RECOVERY_INSTALL_BUFFER_MS = 5 * 60 * 1000
export const SEND_AS_REFRESH_TTL_MS = 24 * 60 * 60 * 1000

export interface IncrementalSyncResult {
  mode: 'incremental' | 'recovery'
  newMessageCount: number
  /** The Account cursor moved. False for a truncated slice even when its continuation was staged. */
  historyIdAdvanced: boolean
  wasTruncated: boolean
  /** The truncated slice staged its continuation token (it had no blocking failures). */
  continuationStaged: boolean
  /**
   * More history is already known to be waiting (a continuation was staged)
   * or this slice must be retried: the caller should run again without
   * waiting for the next scheduler tick (IncrementalSyncResult.needsFollowUp).
   */
  needsFollowUp: boolean
}

export type SyncRunResult = IncrementalSyncResult | InitialSyncResult

interface HistoryCollection {
  records: HistoryRecord[]
  newMessageIds: string[]
  latestHistoryId: string
  wasTruncated: boolean
  /** The token for page 51+ when truncated; null on a terminal slice. */
  nextPageToken: string | null
}

/**
 * Pages listHistory up to MAX_HISTORY_PAGES, starting at `resumeToken` when a
 * compatible continuation is stored. New-message ids come from messagesAdded,
 * excluding anything already labeled SPAM/DRAFT/TRASH, deduped across
 * records. On truncation the ORIGINAL startHistoryId is kept and the next
 * page token is returned so pages 51+ are never lost: the orchestrator stages
 * it with this slice's effects (HistoryCollectionPhase).
 */
async function collectHistory(
  deps: SyncDeps,
  startHistoryId: string,
  resumeToken: string | null,
): Promise<HistoryCollection> {
  const records: HistoryRecord[] = []
  const newMessageIds = new Set<string>()
  let latestHistoryId = startHistoryId
  let pageToken: string | undefined = resumeToken ?? undefined
  let pageCount = 0

  for (;;) {
    const params = pageToken === undefined ? { startHistoryId } : { startHistoryId, pageToken }
    const response = await deps.api.listHistory(params)

    for (const record of response.history ?? []) {
      records.push(record)
      for (const added of record.messagesAdded ?? []) {
        const labels = added.message.labelIds
        if (labels?.some((id) => EXCLUDED_MAILBOX_LABEL_IDS.has(id)) === true) continue
        newMessageIds.add(added.message.id)
      }
    }

    if (response.historyId !== undefined) latestHistoryId = response.historyId
    pageToken = response.nextPageToken
    pageCount += 1

    if (pageToken === undefined) break
    if (pageCount >= MAX_HISTORY_PAGES) {
      return {
        records,
        newMessageIds: [...newMessageIds],
        latestHistoryId: startHistoryId,
        wasTruncated: true,
        nextPageToken: pageToken,
      }
    }
  }

  return {
    records,
    newMessageIds: [...newMessageIds],
    latestHistoryId,
    wasTruncated: false,
    nextPageToken: null,
  }
}

/**
 * Gmail has no dedicated status for an invalid History API page token:
 * observed responses are a 4xx whose message/reason names `pageToken`. Only
 * that narrow shape is matched, and only for a request that carried a stored
 * token, so an unrelated malformed request cannot trigger a checkpoint
 * replay. A message naming the frozen cursor is NOT a token rejection: that
 * is history expiry. (Port of GmailAPIClient.isInvalidHistoryPageTokenResponse;
 * the web listHistory already maps every 404 to HistoryIdExpiredError, whose
 * recovery discards the continuation too.)
 */
export function isInvalidHistoryPageTokenError(error: unknown): boolean {
  if (!(error instanceof GmailApiError)) return false
  if (error.status < 400 || error.status > 499) return false
  const normalize = (text: string): string => text.toLowerCase().replace(/[_\- ]/g, '')
  const message = normalize(error.message)
  if (message.includes('starthistoryid')) return false
  const diagnostic = normalize(`${error.message} ${error.reason ?? ''}`)
  return (
    diagnostic.includes('pagetoken') &&
    (diagnostic.includes('invalid') ||
      diagnostic.includes('expired') ||
      diagnostic.includes('notfound'))
  )
}

/**
 * Loads the stored continuation for this cursor. A row for another cursor is
 * garbage from a cursor that has since moved (ForegroundHistoryCheckpointStore
 * .loadCompatible deletes such rows): it is dropped and the slice replays
 * from the frozen Account cursor.
 */
async function loadCompatibleContinuation(
  db: ChatmailDB,
  startHistoryId: string,
): Promise<string | null> {
  const stored = await getHistoryContinuation(db)
  if (stored === null) return null
  if (stored.startHistoryId !== startHistoryId) {
    await clearHistoryContinuation(db)
    return null
  }
  return stored.pageToken
}

// ---------------------------------------------------------------------------
// Phase 3: label operations
// ---------------------------------------------------------------------------

async function deleteMessageInTx(db: ChatmailDB, messageId: string): Promise<string | null> {
  const existing = await db.messages.get(messageId)
  if (existing === undefined) return null
  const attachmentIds = await db.attachments.where('messageId').equals(messageId).primaryKeys()
  await db.messages.delete(messageId)
  await db.bodies.delete(messageId)
  await db.msgParticipants.where('messageId').equals(messageId).delete()
  await db.attachments.where('messageId').equals(messageId).delete()
  if (attachmentIds.length > 0) await db.blobs.bulkDelete(attachmentIds)
  return existing.conversationId
}

/**
 * Applies the lightweight history operations in order — messagesDeleted
 * (authoritative, always applied), labelsAdded, labelsRemoved — per record.
 * Label/unread changes respect the 30-min localModifiedAt guard; a
 * SPAM/DRAFT/TRASH addition deletes the local copy; INBOX membership changes
 * run the ±1 fast-path arithmetic (full inbox recompute on INBOX-leave).
 * Runs in ONE rw transaction (all ops are Dexie-only).
 */
export async function applyHistoryLabelOps(
  db: ChatmailDB,
  records: readonly HistoryRecord[],
  now: number,
): Promise<Set<string>> {
  const touched = new Set<string>()

  await db.transaction(
    'rw',
    [db.messages, db.bodies, db.msgParticipants, db.attachments, db.blobs, db.conversations],
    async () => {
      const guardActive = (localModifiedAt: number): boolean =>
        localModifiedAt !== 0 && now - localModifiedAt < LOCAL_MODIFICATION_MAX_AGE_MS

      for (const record of records) {
        for (const deleted of record.messagesDeleted ?? []) {
          const conversationId = await deleteMessageInTx(db, deleted.message.id)
          if (conversationId !== null) touched.add(conversationId)
        }

        for (const change of record.labelsAdded ?? []) {
          const message = await db.messages.get(change.message.id)
          if (message === undefined) continue
          if (guardActive(message.localModifiedAt)) continue
          const addedLabels = change.labelIds ?? []

          if (addedLabels.some((id) => EXCLUDED_MAILBOX_LABEL_IDS.has(id))) {
            const conversationId = await deleteMessageInTx(db, message.id)
            if (conversationId !== null) touched.add(conversationId)
            continue
          }

          const previousHadInbox = message.labelIds.includes('INBOX')
          const previousWasUnread = message.isUnread === 1
          const labelSet = new Set(message.labelIds)
          for (const id of addedLabels) labelSet.add(id)
          const isUnread: Flag = addedLabels.includes('UNREAD') ? 1 : message.isUnread
          const updated = { ...message, labelIds: [...labelSet], isUnread }
          await db.messages.put(updated)
          await applyFastUpdateForExistingMessage(
            db,
            updated.conversationId,
            updated,
            previousHadInbox,
            previousWasUnread,
          )
          touched.add(updated.conversationId)
        }

        for (const change of record.labelsRemoved ?? []) {
          const message = await db.messages.get(change.message.id)
          if (message === undefined) continue
          if (guardActive(message.localModifiedAt)) continue
          const removedLabels = new Set(change.labelIds ?? [])

          const previousHadInbox = message.labelIds.includes('INBOX')
          const previousWasUnread = message.isUnread === 1
          const labelIds = message.labelIds.filter((id) => !removedLabels.has(id))
          const isUnread: Flag = removedLabels.has('UNREAD') ? 0 : message.isUnread
          const updated = { ...message, labelIds, isUnread }
          await db.messages.put(updated)
          await applyFastUpdateForExistingMessage(
            db,
            updated.conversationId,
            updated,
            previousHadInbox,
            previousWasUnread,
          )
          touched.add(updated.conversationId)
        }
      }
    },
  )

  return touched
}

// ---------------------------------------------------------------------------
// Finalize
// ---------------------------------------------------------------------------

/**
 * How the durable history position moves at the end of a slice
 * (IncrementalSyncOrchestrator's advance block):
 * - advance: terminal slice, failure policy allows — the Account cursor moves
 *   and any continuation is cleared;
 * - stage: truncated slice, failure policy allows — the cursor stays frozen
 *   and the next page token is stored for the next run;
 * - hold: failures below the escape hatch — nothing moves, so the same slice
 *   (an existing continuation, or the frozen cursor) is retried.
 */
type HistoryPositionMove =
  | { kind: 'advance'; historyId: string }
  | { kind: 'stage'; startHistoryId: string; pageToken: string }
  | { kind: 'hold' }

/**
 * Moves the history position and recomputes rollups for every touched
 * conversation in ONE rw transaction: later syncs can never observe message
 * changes without the derived conversation state, nor a continuation without
 * the slice's effects it skips past, and vice versa.
 */
async function finalizeSync(
  db: ChatmailDB,
  accountEmail: string,
  move: HistoryPositionMove,
  touchedConversationIds: ReadonlySet<string>,
  now: number,
): Promise<void> {
  await db.transaction(
    'rw',
    [db.messages, db.conversations, db.convoParticipants, db.people, db.accounts, db.syncState],
    async () => {
      for (const conversationId of touchedConversationIds) {
        await rollupConversation(db, conversationId, now)
      }
      if (move.kind === 'advance') {
        await clearHistoryContinuation(db)
        const account = await db.accounts.get(accountEmail)
        if (account !== undefined) {
          await db.accounts.put({ ...account, historyId: move.historyId })
        }
      } else if (move.kind === 'stage') {
        await setHistoryContinuation(db, {
          startHistoryId: move.startHistoryId,
          pageToken: move.pageToken,
        })
      }
    },
  )
}

// ---------------------------------------------------------------------------
// History recovery
// ---------------------------------------------------------------------------

export function recoveryQueryStartMs(lastSyncAt: number, installTs: number, now: number): number {
  const installFloor = installTs > 0 ? installTs - RECOVERY_INSTALL_BUFFER_MS : 0
  if (lastSyncAt > 0) {
    return Math.max(lastSyncAt - RECOVERY_LAST_SYNC_BUFFER_MS, installFloor)
  }
  if (installFloor > 0) return installFloor
  return now - 7 * 24 * 60 * 60 * 1000
}

/**
 * historyId-expired recovery: list-sync from
 * max(lastSuccessfulSync − 10 min, install − 5 min), then re-read
 * profile.historyId and store it (failure policy permitting).
 */
async function runHistoryRecovery(
  deps: SyncDeps,
  account: AccountRow,
  ctx: PersistContext,
): Promise<IncrementalSyncResult> {
  const { db, api } = deps
  await setSyncProgress(db, { phase: 'recovery' })
  // The cursor the continuation extended is dead at Gmail; whatever recovery
  // decides about the cursor, the token can never be resumed.
  await clearHistoryContinuation(db)

  const lastSyncAt = await getLastSuccessfulSyncAt(db)
  const startSec = Math.floor(
    recoveryQueryStartMs(lastSyncAt, account.installTs, depsNow(deps)) / 1000,
  )
  const query = `after:${startSec} ${SYNC_QUERY_EXCLUSIONS}`

  // Capture the history cursor BEFORE listing (mirroring runInitialSync):
  // mail arriving while the recovery pages are consumed is then re-covered by
  // the first incremental sync. Capturing after the list would advance the
  // cursor past messages that raced the listing — they would be in neither
  // the consumed pages nor any future history diff.
  const profile = await api.getProfile()

  const result = await listSyncPages(deps, ctx, query, 'recovery')

  const hadFailures = result.failedIds.length > 0
  if (hadFailures) await recordSyncFailure(db, result.failedIds)

  const now = depsNow(deps)
  const advance = await shouldAdvanceHistoryId(db, hadFailures, now)
  if (advance) {
    await db.transaction('rw', db.accounts, async () => {
      const fresh = await db.accounts.get(deps.accountEmail)
      if (fresh !== undefined) await db.accounts.put({ ...fresh, historyId: profile.historyId })
    })
    if (!hadFailures) await setLastSuccessfulSyncAt(db, now)
  }

  await setSyncProgress(db, { phase: 'idle', lastSyncAt: now })
  return {
    mode: 'recovery',
    newMessageCount: result.processedCount,
    historyIdAdvanced: advance,
    wasTruncated: false,
    continuationStaged: false,
    needsFollowUp: !advance,
  }
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

async function refreshSendAsAliasesIfStale(
  deps: SyncDeps,
  account: AccountRow,
): Promise<AccountRow> {
  if (depsNow(deps) - account.sendAsRefreshedAt < SEND_AS_REFRESH_TTL_MS) return account
  try {
    const sendAsList = await deps.api.listSendAs()
    await persistAccountAliases(deps.db, deps.accountEmail, sendAsList, depsNow(deps))
    return (await deps.db.accounts.get(deps.accountEmail)) ?? account
  } catch {
    // Refresh failures fall back to the cached aliases (non-fatal).
    return account
  }
}

export async function runIncrementalSync(deps: SyncDeps): Promise<SyncRunResult> {
  const { db, api } = deps

  let account = await db.accounts.get(deps.accountEmail)
  if (account === undefined || account.historyId === '') {
    return runInitialSync(deps)
  }

  await setSyncProgress(db, { phase: 'incremental' })
  account = await refreshSendAsAliasesIfStale(deps, account)
  const ctx = await buildPersistContext(deps, account)

  // Phase 1: collect one bounded history slice, resuming at a compatible
  // stored continuation while the Account cursor stays frozen
  // (HistoryIdExpiredError → recovery).
  let history: HistoryCollection
  try {
    const resumeToken = await loadCompatibleContinuation(db, account.historyId)
    try {
      history = await collectHistory(deps, account.historyId, resumeToken)
    } catch (error) {
      // Gmail page tokens are opaque and may expire independently of the
      // still-valid history cursor. A rejected stored token is recovered by
      // durably discarding it and replaying from the frozen cursor once; the
      // same error on the first page propagates, because it indicates a
      // different request defect.
      if (resumeToken === null || !isInvalidHistoryPageTokenError(error)) throw error
      await clearHistoryContinuation(db)
      history = await collectHistory(deps, account.historyId, null)
    }
  } catch (error) {
    if (error instanceof HistoryIdExpiredError) {
      return runHistoryRecovery(deps, account, ctx)
    }
    throw error
  }
  await deps.hooks?.onPhase?.('incremental:afterHistory')

  const touched = new Set<string>()
  const failedIds: string[] = []

  // Phase 2: fetch + persist new messages.
  const fetchResult = await fetchMessagesBounded(api, history.newMessageIds, {
    sleep: depsSleep(deps),
    random: depsRandom(deps),
  })
  failedIds.push(...fetchResult.failed.map((f) => f.id))
  const plans = await preparePersist(fetchResult.fetched, ctx)
  failedIds.push(...retryableFailurePlanIds(plans))
  // A message that fetched fine but produced no persistable plan (parser
  // rejected it) must not be dropped without a trace — but it is terminal, not
  // transient: the identical response reparses to the identical null, so
  // feeding it into failedIds would keep hadFailures true forever, freezing
  // lastSuccessfulSyncAt and stalling the cursor two syncs out of three. Park
  // it in the abandoned registry as a tombstone instead.
  await recordUnprocessableMessages(db, unprocessablePlanIds(plans), depsNow(deps))
  const applied = await applyPersist(db, plans, depsNow(deps))
  failedIds.push(...applied.retryableMessageIds)
  for (const id of applied.touchedConversationIds) touched.add(id)
  await deps.hooks?.onPhase?.('incremental:afterFetch')

  // Phase 2b: abandoned drain — one attempt each, never blocks the cursor.
  let drainOutcome: AbandonedDrainOutcome = { recoveredIds: [], goneIds: [], failedIds: [] }
  const drain = await drainAbandoned(db, api, ctx, depsNow(deps), {
    sleep: depsSleep(deps),
    random: depsRandom(deps),
  })
  drainOutcome = drain.outcome
  for (const id of drain.touchedConversationIds) touched.add(id)

  // Phase 3: label operations, applied AFTER fetch so the rows exist.
  const labelTouched = await applyHistoryLabelOps(db, history.records, depsNow(deps))
  for (const id of labelTouched) touched.add(id)
  await deps.hooks?.onPhase?.('incremental:afterLabelOps')

  // Phase 4: reconciliation.
  const missedIds = await findMissedMessageIds(db, api, account.installTs, depsNow(deps))
  if (missedIds.length > 0) {
    const missedFetch = await fetchMessagesBounded(api, missedIds, {
      sleep: depsSleep(deps),
      random: depsRandom(deps),
    })
    // Failed missed-message fetches feed the failure/abandoned registry like
    // phase-2 failures: a dropped-history message whose reconciliation fetch
    // fails would otherwise vanish once the shrinking lookback window moves
    // past it, while the sync still reported clean success.
    failedIds.push(...missedFetch.failed.map((f) => f.id))
    const missedPlans = await preparePersist(missedFetch.fetched, ctx)
    failedIds.push(...retryableFailurePlanIds(missedPlans))
    await recordUnprocessableMessages(db, unprocessablePlanIds(missedPlans), depsNow(deps))
    const missedApplied = await applyPersist(db, missedPlans, depsNow(deps))
    failedIds.push(...missedApplied.retryableMessageIds)
    for (const id of missedApplied.touchedConversationIds) touched.add(id)
  }
  const labelReconcile = await reconcileLabels(db, api, depsNow(deps))
  if (labelReconcile !== null) {
    for (const id of labelReconcile.touchedConversationIds) touched.add(id)
  }
  await deps.hooks?.onPhase?.('incremental:afterReconcile')

  // Resolve this slice's ledger before moving either continuation or cursor.
  // Below the failure threshold nothing moves, so the same slice is retried.
  // Once every outcome is clean or durably abandoned, a truncated slice
  // advances only its continuation; the Account cursor advances only at
  // Gmail's end (IncrementalSyncOrchestrator's advance block).
  const hadFailures = failedIds.length > 0
  if (hadFailures) await recordSyncFailure(db, failedIds)
  const now = depsNow(deps)
  const sliceResolved = await shouldAdvanceHistoryId(db, hadFailures, now)
  let move: HistoryPositionMove = { kind: 'hold' }
  if (sliceResolved) {
    move =
      history.nextPageToken !== null
        ? { kind: 'stage', startHistoryId: account.historyId, pageToken: history.nextPageToken }
        : { kind: 'advance', historyId: history.latestHistoryId }
  }
  const advance = move.kind === 'advance'

  // Finalize: cursor/continuation + rollups in ONE durable transaction.
  await finalizeSync(db, deps.accountEmail, move, touched, now)

  // Post-save bookkeeping (only after the durable save, mirroring iOS). A
  // staged continuation resets failure tracking but is not a terminal
  // success for the reconcile window (failureTracker.commit with
  // recordsSuccessfulSync: false).
  await recordAbandonedRetryOutcome(db, drainOutcome, now)
  if (!hadFailures && !history.wasTruncated) {
    await recordSyncSuccess(db)
    await setLastSuccessfulSyncAt(db, now)
  }
  if (labelReconcile !== null && labelReconcile.completed) {
    await setLabelReconciledAt(db, now)
  }
  await setSyncProgress(db, { phase: 'idle', lastSyncAt: now })

  return {
    mode: 'incremental',
    newMessageCount: applied.persistedMessageIds.size,
    historyIdAdvanced: advance,
    wasTruncated: history.wasTruncated,
    continuationStaged: move.kind === 'stage',
    needsFollowUp: history.wasTruncated || !sliceResolved,
  }
}
