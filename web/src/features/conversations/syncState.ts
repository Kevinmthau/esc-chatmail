import type { SyncProgress } from '@/db/kv'

// Interpretation of the syncProgress kv row for the conversation list. Lives
// outside the components so the list and its header line share one reading of
// "has this account actually synced yet?".

/**
 * True while the list may still be waiting on the account's first delivery of
 * mail — the states where zero rows must NOT be reported as "no conversations".
 *
 * - `initial`/`recovery`: a backfill is running. It fetches and persists a
 *   whole 500-message page before anything reaches Dexie, so a real inbox
 *   reads as empty for minutes.
 * - `incremental`: only reachable once a historyId exists, i.e. after a
 *   completed initial sync — zero rows there really is an empty (or fully
 *   filtered) mailbox. Important because setSyncProgress replaces the whole
 *   row, dropping `lastSyncAt` for the duration of every run: treating an
 *   in-flight incremental as "unsynced" would flap the empty state on every
 *   poll.
 * - `idle`: trustworthy only once a run has recorded `lastSyncAt`. A fresh
 *   install, an evicted database, the offline fallback and a failed first run
 *   all sit at idle with no recorded success.
 */
export function isFirstSyncPending(status: SyncProgress): boolean {
  switch (status.phase) {
    case 'initial':
    case 'recovery':
      return true
    case 'incremental':
      return false
    case 'idle':
      return (status.lastSyncAt ?? 0) === 0
  }
}

/**
 * Human progress detail for an in-flight sync ("120 of about 3000 messages"),
 * or undefined when nothing has been counted yet — a counter frozen at
 * "0 messages" reads as broken, so callers fall back to a bare "Syncing…".
 */
export function syncProgressDetail(status: SyncProgress): string | undefined {
  const fetched = status.fetchedCount ?? 0
  if (fetched <= 0) return undefined
  const total = status.totalEstimate
  // resultSizeEstimate is an estimate: drop it once the count overtakes it.
  if (total !== undefined && total > fetched) return `${fetched} of about ${total} messages`
  return `${fetched} messages`
}
