import type { ChatmailDB } from './schema'

// Typed accessors over the syncState key-value table.

export interface SyncProgress {
  phase: 'idle' | 'initial' | 'incremental' | 'recovery'
  fetchedCount?: number
  totalEstimate?: number
  lastSyncAt?: number
  lastError?: string
}

/**
 * Durable position for the next bounded History API slice. Port of
 * ForegroundHistoryCheckpoint: a row always carries a real Gmail continuation
 * token for the slice after `startHistoryId`'s cursor; absence means the next
 * sync starts from the Account's still-frozen cursor. Gmail page tokens are
 * opaque and are persisted byte-for-byte.
 */
export interface HistoryContinuation {
  /** The Account historyId the token continues from; a mismatch makes the token garbage. */
  startHistoryId: string
  pageToken: string
}

const SYNC_PROGRESS_KEY = 'syncProgress'
const LAST_SUCCESSFUL_SYNC_KEY = 'lastSuccessfulSyncAt'
const LABEL_RECONCILE_AT_KEY = 'labelReconciledAt'
const HISTORY_CONTINUATION_KEY = 'historyContinuation'

export async function getSyncProgress(db: ChatmailDB): Promise<SyncProgress> {
  const row = await db.syncState.get(SYNC_PROGRESS_KEY)
  return (row?.value as SyncProgress | undefined) ?? { phase: 'idle' }
}

export async function setSyncProgress(db: ChatmailDB, progress: SyncProgress): Promise<void> {
  await db.syncState.put({ key: SYNC_PROGRESS_KEY, value: progress })
}

export async function getLastSuccessfulSyncAt(db: ChatmailDB): Promise<number> {
  const row = await db.syncState.get(LAST_SUCCESSFUL_SYNC_KEY)
  return (row?.value as number | undefined) ?? 0
}

export async function setLastSuccessfulSyncAt(db: ChatmailDB, at: number): Promise<void> {
  await db.syncState.put({ key: LAST_SUCCESSFUL_SYNC_KEY, value: at })
}

export async function getLabelReconciledAt(db: ChatmailDB): Promise<number> {
  const row = await db.syncState.get(LABEL_RECONCILE_AT_KEY)
  return (row?.value as number | undefined) ?? 0
}

export async function setLabelReconciledAt(db: ChatmailDB, at: number): Promise<void> {
  await db.syncState.put({ key: LABEL_RECONCILE_AT_KEY, value: at })
}

/** Null when no continuation is stored or the stored row is malformed. */
export async function getHistoryContinuation(db: ChatmailDB): Promise<HistoryContinuation | null> {
  const row = await db.syncState.get(HISTORY_CONTINUATION_KEY)
  const value = row?.value as Partial<HistoryContinuation> | undefined
  if (
    value === undefined ||
    typeof value.startHistoryId !== 'string' ||
    typeof value.pageToken !== 'string' ||
    value.pageToken.trim() === ''
  ) {
    return null
  }
  return { startHistoryId: value.startHistoryId, pageToken: value.pageToken }
}

/**
 * Dexie-only, so a call inside the sync finalize transaction joins it: the
 * continuation commits or dies with the slice's effects, exactly like the
 * staged iOS checkpoint. Rejects an empty token (ForegroundHistoryCheckpointStore
 * .emptyPageToken) — a row without a real token would resume nowhere.
 */
export async function setHistoryContinuation(
  db: ChatmailDB,
  continuation: HistoryContinuation,
): Promise<void> {
  if (continuation.pageToken.trim() === '') {
    throw new Error('A Gmail history continuation token cannot be empty')
  }
  await db.syncState.put({ key: HISTORY_CONTINUATION_KEY, value: continuation })
}

export async function clearHistoryContinuation(db: ChatmailDB): Promise<void> {
  await db.syncState.delete(HISTORY_CONTINUATION_KEY)
}
