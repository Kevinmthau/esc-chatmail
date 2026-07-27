// Durable offline action queue: enqueue + drain. Port of
// Services/PendingActions/{PendingActionsManager,PendingActionProcessor,
// ActionExecutor}.swift.
//
// Semantics carried over:
// - claim order: strict createdAt across pending AND retriable failed rows
//   (PendingActionProcessor sorts by createdAt over both statuses);
// - action → Gmail label mapping (ActionExecutor);
// - retriable failures (429 / 5xx / network) → status 'failed' + retryCount++,
//   with a 2^retryCount * 2s backoff (cap 30s) measured from lastAttempt: a
//   failed row whose window has not elapsed is DEFERRED to the end of the drain
//   (together with anything ordered behind it for the same messages) instead of
//   blocking the queue head, so fresh user actions are not stuck behind it;
// - non-retriable failures (other 4xx) → 'abandoned';
// - stale 'processing' rows older than 10 minutes reset to 'failed';
// - completed rows swept at the start of the next drain;
// - success clears localModifiedAt on the affected messages only when the
//   message was not re-modified after the claim (lastAttempt vs
//   localModifiedAt comparison inside the tx);
// - single-flight via the cross-tab 'outbox' Web Lock, with the same
//   in-process FIFO fallback pattern as identity/creationLock.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { PendingActionRow, PendingActionType } from '@/db/types'
import {
  batchModify,
  modifyMessage,
  type EndpointOptions,
  type BatchModifyParams,
  type LabelChanges,
} from '@/gmail/endpoints'
import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from '@/gmail/errors'
import type { TokenBroker } from '@/gmail/gmailFetch'

export const MAX_PENDING_ACTION_RETRIES = 5
export const STALE_PROCESSING_MS = 10 * 60 * 1000
export const PENDING_ACTION_BACKOFF_CAP_MS = 30_000

/** Backoff slept before retrying a failed action: 2^retryCount * 2s, cap 30s. */
export function pendingActionBackoffMs(retryCount: number): number {
  return Math.min(2 ** retryCount * 2_000, PENDING_ACTION_BACKOFF_CAP_MS)
}

// ---------------------------------------------------------------------------
// Gmail mapping (ActionExecutor.swift)
// ---------------------------------------------------------------------------

/** Label changes each action type applies remotely. */
export function labelChangesForAction(actionType: PendingActionType): LabelChanges {
  switch (actionType) {
    case 'markRead':
      return { removeLabelIds: ['UNREAD'] }
    case 'markUnread':
      return { addLabelIds: ['UNREAD'] }
    case 'archive':
    case 'archiveConversation':
      return { removeLabelIds: ['INBOX'] }
    case 'star':
      return { addLabelIds: ['STARRED'] }
    case 'unstar':
      return { removeLabelIds: ['STARRED'] }
    case 'reportSpam':
      return { addLabelIds: ['SPAM'], removeLabelIds: ['INBOX'] }
  }
}

/** Network surface the drain uses; injectable for tests. */
export interface OutboxApi {
  batchModify(params: BatchModifyParams): Promise<void>
  modifyMessage(id: string, changes: LabelChanges): Promise<void>
}

/** Binds the real Gmail endpoints to a token broker. */
export function makeOutboxApi(broker: TokenBroker, options?: EndpointOptions): OutboxApi {
  return {
    batchModify: (params) => batchModify(broker, params, options),
    modifyMessage: async (id, changes) => {
      await modifyMessage(broker, id, changes, options)
    },
  }
}

// ---------------------------------------------------------------------------
// Enqueue
// ---------------------------------------------------------------------------

export interface EnqueueAction {
  actionType: PendingActionType
  conversationId: string
  /** Single-message actions. */
  messageId?: string
  /** Batch actions. */
  messageIds?: readonly string[]
}

/**
 * Adds one pending action. Dexie-only, so calls inside an outer transaction
 * that includes pendingActions join it atomically.
 */
export async function enqueue(
  db: ChatmailDB,
  action: EnqueueAction,
  now: number = Date.now(),
): Promise<number> {
  const row: PendingActionRow = {
    actionType: action.actionType,
    status: 'pending',
    messageId: action.messageId ?? '',
    conversationId: action.conversationId,
    messageIds: [...(action.messageIds ?? [])],
    retryCount: 0,
    createdAt: now,
    lastAttempt: 0,
  }
  return db.pendingActions.add(row)
}

// ---------------------------------------------------------------------------
// Single-flight 'outbox' lock (pattern from identity/creationLock.ts)
// ---------------------------------------------------------------------------

export const OUTBOX_LOCK_NAME = 'outbox'

interface LockRequester {
  request: <T>(name: string, callback: () => Promise<T>) => Promise<T>
}

/** undefined = use the real navigator.locks; null = force the in-process fallback. */
let locksOverride: LockRequester | null | undefined

/** Test hook: pass null to force the fallback mutex, undefined to restore default. */
export function setOutboxLocksForTests(locks: LockRequester | null | undefined): void {
  locksOverride = locks
}

function currentLocks(): LockRequester | null {
  if (locksOverride !== undefined) return locksOverride
  if (
    typeof navigator !== 'undefined' &&
    typeof (navigator.locks as LockManager | null | undefined)?.request === 'function'
  ) {
    return {
      request: async (name, callback) => await navigator.locks.request(name, () => callback()),
    }
  }
  return null
}

/** Tail of the in-process pending chain (single lock name). */
let fallbackTail: Promise<void> = Promise.resolve()

async function withFallbackLock<T>(fn: () => Promise<T>): Promise<T> {
  const prev = fallbackTail
  let release!: () => void
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  fallbackTail = prev.then(() => gate)

  await prev
  try {
    return await fn()
  } finally {
    release()
  }
}

function withOutboxLock<T>(fn: () => Promise<T>): Promise<T> {
  const locks = currentLocks()
  if (locks !== null) return locks.request(OUTBOX_LOCK_NAME, fn)
  return withFallbackLock(fn)
}

// ---------------------------------------------------------------------------
// Drain
// ---------------------------------------------------------------------------

export interface DrainOptions {
  now?: () => number
  /** Injectable backoff sleep (tests). */
  sleep?: (ms: number) => Promise<void>
  maxRetries?: number
}

export interface DrainResult {
  processed: number
  completed: number
  failed: number
  abandoned: number
}

function isRetriableError(error: unknown): boolean {
  if (error instanceof RateLimitError) return true
  if (error instanceof NetworkError) return true
  if (error instanceof GmailApiError) return error.status >= 500
  return false
}

function affectedMessageIds(row: PendingActionRow): string[] {
  if (row.messageIds.length > 0) return row.messageIds
  return row.messageId !== '' ? [row.messageId] : []
}

/**
 * Rows eligible for this drain, in strict createdAt order ACROSS pending and
 * retriable failed rows (tiebreak on id). iOS PendingActionProcessor claims
 * with a single createdAt-ascending fetch over both statuses; running all
 * pendings before older failed retries would let a stale retry re-apply an
 * outdated mutation AFTER the user's newest intent (markRead enqueued after a
 * failed markUnread must execute after its retry, not before).
 */
async function claimableRows(db: ChatmailDB, maxRetries: number): Promise<PendingActionRow[]> {
  const pending = await db.pendingActions
    .where('[status+createdAt]')
    .between(['pending', Dexie.minKey], ['pending', Dexie.maxKey])
    .toArray()
  const failed = await db.pendingActions
    .where('[status+createdAt]')
    .between(['failed', Dexie.minKey], ['failed', Dexie.maxKey])
    .toArray()
  const rows = [...pending, ...failed.filter((row) => row.retryCount < maxRetries)]
  rows.sort((a, b) => a.createdAt - b.createdAt || (a.id ?? 0) - (b.id ?? 0))
  return rows
}

/**
 * Marks the action completed and clears localModifiedAt on its messages —
 * but only for messages NOT re-modified after the claim: a message whose
 * localModifiedAt is newer than the claim time has a fresher local mutation
 * in flight and must keep its conflict guard.
 */
async function completeAction(
  db: ChatmailDB,
  row: PendingActionRow,
  claimedAt: number,
): Promise<void> {
  await db.transaction('rw', db.pendingActions, db.messages, async () => {
    if (row.id !== undefined) {
      await db.pendingActions.update(row.id, { status: 'completed' })
    }
    for (const messageId of affectedMessageIds(row)) {
      const message = await db.messages.get(messageId)
      if (message === undefined) continue
      if (message.localModifiedAt !== 0 && message.localModifiedAt <= claimedAt) {
        await db.messages.update(messageId, { localModifiedAt: 0 })
      }
    }
  })
}

/**
 * Drains the pending-action queue: claims rows in createdAt order, executes
 * them against Gmail, and applies the retry/abandon state machine. Rows still
 * inside their retry backoff run last (see drainLocked), never in front of
 * newer actions for unrelated messages. Single-flight under the 'outbox' lock
 * (cross-tab safe).
 */
export function drainPendingActions(
  db: ChatmailDB,
  api: OutboxApi,
  opts: DrainOptions = {},
): Promise<DrainResult> {
  return withOutboxLock(() => drainLocked(db, api, opts))
}

async function drainLocked(
  db: ChatmailDB,
  api: OutboxApi,
  opts: DrainOptions,
): Promise<DrainResult> {
  const now = opts.now ?? Date.now
  const sleep =
    opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)))
  const maxRetries = opts.maxRetries ?? MAX_PENDING_ACTION_RETRIES
  const result: DrainResult = { processed: 0, completed: 0, failed: 0, abandoned: 0 }

  // Sweep completed rows from earlier drains.
  await db.pendingActions.where('status').equals('completed').delete()

  // Reset stale 'processing' rows (a crashed/killed drain) to 'failed'.
  const staleCutoff = now() - STALE_PROCESSING_MS
  await db.pendingActions
    .where('status')
    .equals('processing')
    .filter((row) => row.lastAttempt === 0 || row.lastAttempt < staleCutoff)
    .modify({ status: 'failed' })

  const rows = await claimableRows(db, maxRetries)

  // Pass 1: everything whose backoff window has elapsed, in createdAt order.
  // A row that is not ready yet is deferred rather than slept on, and so is
  // every later row touching one of its messages — otherwise the newest intent
  // would land remotely BEFORE the stale retry that is still queued for it.
  const deferred: PendingActionRow[] = []
  const deferredMessageIds = new Set<string>()
  let stoppedForAuth = false

  for (const row of rows) {
    if (row.id === undefined) continue
    const ids = affectedMessageIds(row)
    const notReady = readyAt(row) > now()
    const blocked = ids.some((id) => deferredMessageIds.has(id))
    if (notReady || blocked) {
      deferred.push(row)
      for (const id of ids) deferredMessageIds.add(id)
      continue
    }
    stoppedForAuth = await processRow(db, api, row, result, now, maxRetries)
    if (stoppedForAuth) break
  }

  // Pass 2: the deferred rows, still in createdAt order. Sleeps are measured
  // against a virtual clock so N rows sharing one backoff window cost ONE wait,
  // not one per row.
  if (!stoppedForAuth) {
    let sleptUntil = 0
    for (const row of deferred) {
      if (row.id === undefined) continue
      const target = readyAt(row)
      const elapsedAt = Math.max(now(), sleptUntil)
      if (target > elapsedAt) {
        await sleep(target - elapsedAt)
        sleptUntil = target
      }
      if (await processRow(db, api, row, result, now, maxRetries)) break
    }
  }

  return result
}

/** Epoch ms at which a claimed row may be attempted; 0 for never-tried rows. */
function readyAt(row: PendingActionRow): number {
  if (row.status !== 'failed') return 0
  return row.lastAttempt + pendingActionBackoffMs(row.retryCount)
}

/** Executes one claimed row. Returns true when the drain must stop (auth). */
async function processRow(
  db: ChatmailDB,
  api: OutboxApi,
  row: PendingActionRow,
  result: DrainResult,
  now: () => number,
  maxRetries: number,
): Promise<boolean> {
  const rowId = row.id
  if (rowId === undefined) return false
  const previousStatus = row.status

  const claimedAt = now()
  await db.pendingActions.update(rowId, { status: 'processing', lastAttempt: claimedAt })
  result.processed += 1

  const ids = affectedMessageIds(row)
  if (ids.length === 0) {
    await db.pendingActions.update(rowId, { status: 'completed' })
    result.completed += 1
    return false
  }

  try {
    const changes = labelChangesForAction(row.actionType)
    if (row.messageIds.length > 0) {
      await api.batchModify({ ids, ...changes })
    } else {
      const single = ids[0]
      if (single !== undefined) await api.modifyMessage(single, changes)
    }
    await completeAction(db, row, claimedAt)
    result.completed += 1
  } catch (error) {
    if (error instanceof AuthRequiredError) {
      // Not a queue failure: restore the row and stop draining until auth
      // is available again.
      await db.pendingActions.update(rowId, { status: previousStatus, lastAttempt: claimedAt })
      result.processed -= 1
      return true
    }
    if (isRetriableError(error)) {
      const retryCount = row.retryCount + 1
      const status = retryCount >= maxRetries ? 'abandoned' : 'failed'
      await db.pendingActions.update(rowId, { status, retryCount, lastAttempt: claimedAt })
      if (status === 'failed') result.failed += 1
      else result.abandoned += 1
    } else {
      // Non-retriable (4xx and unexpected errors): retrying cannot succeed.
      await db.pendingActions.update(rowId, { status: 'abandoned', lastAttempt: claimedAt })
      result.abandoned += 1
    }
  }
  return false
}
