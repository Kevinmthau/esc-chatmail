// Incremental sync via the Gmail History API. Port of
// IncrementalSyncOrchestrator + HistoryProcessor(+LabelOperations,
// +MessageDeletions) + HistoryCollectionPhase.
//
// Phase order (invariant-critical):
//   1  history collection (≤50 pages; truncation keeps the ORIGINAL cursor)
//   2  fetch + persist new messages
//   2b abandoned drain (failures never block cursor advancement)
//   3  label ops — AFTER fetch so the rows exist — deletions, then adds, then
//      removals, respecting the 30-min localModifiedAt guard
//   4  reconciliation (missed-message check every sync; label repair on TTL)
//   ∎  finalize: historyId + rollups in ONE rw transaction.

import {
  getLastSuccessfulSyncAt,
  setLabelReconciledAt,
  setLastSuccessfulSyncAt,
  setSyncProgress,
} from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import type { AccountRow, Flag } from '@/db/types'
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
  historyIdAdvanced: boolean
  wasTruncated: boolean
}

export type SyncRunResult = IncrementalSyncResult | InitialSyncResult

interface HistoryCollection {
  records: HistoryRecord[]
  newMessageIds: string[]
  latestHistoryId: string
  wasTruncated: boolean
}

/**
 * Pages listHistory up to MAX_HISTORY_PAGES. New-message ids come from
 * messagesAdded, excluding anything already labeled SPAM/DRAFT/TRASH, deduped
 * across records. On truncation the ORIGINAL startHistoryId is kept so pages
 * 51+ are never lost.
 */
async function collectHistory(deps: SyncDeps, startHistoryId: string): Promise<HistoryCollection> {
  const records: HistoryRecord[] = []
  const newMessageIds = new Set<string>()
  let latestHistoryId = startHistoryId
  let pageToken: string | undefined
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
      }
    }
  }

  return { records, newMessageIds: [...newMessageIds], latestHistoryId, wasTruncated: false }
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
 * Advances the history cursor and recomputes rollups for every touched
 * conversation in ONE rw transaction: later syncs can never observe message
 * changes without the derived conversation state, and vice versa.
 */
async function finalizeSync(
  db: ChatmailDB,
  accountEmail: string,
  historyIdToSave: string | null,
  touchedConversationIds: ReadonlySet<string>,
  now: number,
): Promise<void> {
  await db.transaction('rw', db.messages, db.conversations, db.accounts, async () => {
    for (const conversationId of touchedConversationIds) {
      await rollupConversation(db, conversationId, now)
    }
    if (historyIdToSave !== null) {
      const account = await db.accounts.get(accountEmail)
      if (account !== undefined) {
        await db.accounts.put({ ...account, historyId: historyIdToSave })
      }
    }
  })
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

  // Phase 1: history collection (HistoryIdExpiredError → recovery).
  let history: HistoryCollection
  try {
    history = await collectHistory(deps, account.historyId)
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
  // A message that fetched fine but produced no persistable plan (parser
  // rejected it) must not be dropped without a trace — but it is terminal, not
  // transient: the identical response reparses to the identical null, so
  // feeding it into failedIds would keep hadFailures true forever, freezing
  // lastSuccessfulSyncAt and stalling the cursor two syncs out of three. Park
  // it in the abandoned registry as a tombstone instead.
  await recordUnprocessableMessages(db, unprocessablePlanIds(plans), depsNow(deps))
  const applied = await applyPersist(db, plans, depsNow(deps))
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
    await recordUnprocessableMessages(db, unprocessablePlanIds(missedPlans), depsNow(deps))
    const missedApplied = await applyPersist(db, missedPlans, depsNow(deps))
    for (const id of missedApplied.touchedConversationIds) touched.add(id)
  }
  const labelReconcile = await reconcileLabels(db, api, depsNow(deps))
  if (labelReconcile !== null) {
    for (const id of labelReconcile.touchedConversationIds) touched.add(id)
  }
  await deps.hooks?.onPhase?.('incremental:afterReconcile')

  // Advance decision: truncation keeps the original cursor unconditionally.
  const hadFailures = failedIds.length > 0
  if (hadFailures) await recordSyncFailure(db, failedIds)
  const now = depsNow(deps)
  let advance = false
  if (!history.wasTruncated) {
    advance = await shouldAdvanceHistoryId(db, hadFailures, now)
  }

  // Finalize: historyId + rollups in ONE durable transaction.
  const historyIdToSave =
    advance && history.latestHistoryId !== account.historyId ? history.latestHistoryId : null
  await finalizeSync(db, deps.accountEmail, historyIdToSave, touched, now)

  // Post-save bookkeeping (only after the durable save, mirroring iOS).
  await recordAbandonedRetryOutcome(db, drainOutcome)
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
  }
}
