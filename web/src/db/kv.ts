import type { ChatmailDB } from './schema'

// Typed accessors over the syncState key-value table.

export interface SyncProgress {
  phase: 'idle' | 'initial' | 'incremental' | 'recovery'
  fetchedCount?: number
  totalEstimate?: number
  lastSyncAt?: number
  lastError?: string
  storagePersistent?: boolean
}

const SYNC_PROGRESS_KEY = 'syncProgress'
const LAST_SUCCESSFUL_SYNC_KEY = 'lastSuccessfulSyncAt'
const LABEL_RECONCILE_AT_KEY = 'labelReconciledAt'

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
