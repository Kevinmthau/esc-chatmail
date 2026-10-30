// Sync entry point: cross-tab exclusive `sync:<account>` Web Lock with
// ifAvailable semantics (a held lock means another tab is syncing — skip, do
// not queue), initial-vs-incremental routing, and error capture into the
// syncProgress kv row.

import { setSyncProgress } from '@/db/kv'
import { AuthRequiredError, QuotaExhaustedError } from '@/gmail/errors'
import {
  repairStoredChatPreviewsIfNeeded,
  seedChatPreviewRepairOnFreshStoreIfNeeded,
} from './chatPreviewRepair'
import { depsNow, type SyncDeps } from './deps'
import { repairStoredDisplayNamesIfNeeded } from './displayNameRepair'
import { runIncrementalSync, type SyncRunResult } from './incremental'
import { repairParticipantSetConversations } from './participantSetRepair'
import { repairStoredSubjectsIfNeeded } from './subjectRepair'

export type SyncReason = 'manual' | 'startup' | 'interval' | 'visibility' | 'online'

/** Extra history slices one run drains after a truncated one (each is up to 50 pages). */
export const MAX_CONTINUATION_SLICES_PER_RUN = 20

export interface RunSyncOutcome {
  /** false: another sync already holds the lock — nothing ran. */
  ran: boolean
  result?: SyncRunResult
  error?: unknown
}

interface IfAvailableLock {
  request<T>(name: string, callback: (acquired: boolean) => Promise<T>): Promise<T>
}

/** undefined = use navigator.locks when present; null = force the fallback. */
let lockOverride: IfAvailableLock | null | undefined

export function setSyncLockForTests(lock: IfAvailableLock | null | undefined): void {
  lockOverride = lock
}

/** In-process fallback: a plain held-name set (ifAvailable semantics only). */
const heldFallbackLocks = new Set<string>()

async function withFallbackLock<T>(
  name: string,
  callback: (acquired: boolean) => Promise<T>,
): Promise<T> {
  if (heldFallbackLocks.has(name)) return callback(false)
  heldFallbackLocks.add(name)
  try {
    return await callback(true)
  } finally {
    heldFallbackLocks.delete(name)
  }
}

function currentLock(): IfAvailableLock {
  if (lockOverride !== undefined && lockOverride !== null) return lockOverride
  if (lockOverride === null) return { request: withFallbackLock }
  if (
    typeof navigator !== 'undefined' &&
    typeof (navigator.locks as LockManager | null | undefined)?.request === 'function'
  ) {
    return {
      request: async (name, callback) =>
        await navigator.locks.request(name, { ifAvailable: true }, (lock) =>
          callback(lock !== null),
        ),
    }
  }
  return { request: withFallbackLock }
}

export function syncLockName(accountEmail: string): string {
  return `sync:${accountEmail}`
}

/**
 * Runs one sync pass under the per-account exclusive lock. If the lock is
 * held (another tab/run), returns `{ran: false}` immediately. Errors are
 * captured into the syncProgress kv row (`lastError`) and returned, not
 * thrown — except that the outcome carries them for callers that care.
 */
export async function runSync(deps: SyncDeps, reason: SyncReason): Promise<RunSyncOutcome> {
  void reason
  return currentLock().request(syncLockName(deps.accountEmail), async (acquired) => {
    if (!acquired) return { ran: false }
    try {
      // The one-shot stored-name repairs run first: a Person stored as
      // `'Hide My Email'` counts as a relay only once its quotes are peeled,
      // and the participant-set repair reads that classification.
      await repairStoredDisplayNamesIfNeeded(deps.db)
      // The cached alias/People snapshot can repair stale local routing before
      // any network work. A second pass catches aliases or Person display-name
      // enrichment learned during this sync; its signature gate makes the
      // usual no-change pass a small metadata check.
      await repairParticipantSetConversations(deps.db, deps.accountEmail, depsNow(deps))
      // One-shot and local-only, so it runs before network work too. It
      // never reads participants, so its place relative to the
      // participant-set repairs does not matter.
      await repairStoredSubjectsIfNeeded(deps.db, depsNow(deps))
      // Before the network pass, while a new sign-in's store is still empty: the
      // initial sync derives every preview with the current cleanup, so the preview
      // repair below has nothing to re-derive.
      await seedChatPreviewRepairOnFreshStoreIfNeeded(deps.db)
      let result = await runIncrementalSync(deps)
      // A truncated history slice staged its continuation token; the next run
      // resumes from it, so drain a backlog back-to-back (iOS schedules an
      // immediate follow-up) instead of one slice per scheduler tick. Bounded,
      // and only for a STAGED continuation: a truncated slice that was held
      // (blocking failures) staged nothing and waits for the tick, so a
      // persistent failure is not hammered.
      for (let slice = 0; slice < MAX_CONTINUATION_SLICES_PER_RUN; slice += 1) {
        if (result.mode !== 'incremental' || !result.continuationStaged) break
        result = await runIncrementalSync(deps)
      }
      // Local-only too, but one budget can take seconds on a large mailbox, so it runs
      // after the network pass rather than holding new mail behind it. It never reads
      // participants or subjects, so its place among the other repairs does not matter.
      await repairStoredChatPreviewsIfNeeded(deps.db, depsNow(deps))
      await repairParticipantSetConversations(deps.db, deps.accountEmail, depsNow(deps))
      return { ran: true, result }
    } catch (error) {
      const message =
        error instanceof AuthRequiredError
          ? 'Sign-in required'
          : error instanceof QuotaExhaustedError
            ? 'Gmail quota exhausted'
            : error instanceof Error
              ? error.message
              : String(error)
      try {
        await setSyncProgress(deps.db, { phase: 'idle', lastError: message })
      } catch {
        // The progress write is best-effort; the original error wins.
      }
      return { ran: true, error }
    }
  })
}
