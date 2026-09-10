// Sync entry point: cross-tab exclusive `sync:<account>` Web Lock with
// ifAvailable semantics (a held lock means another tab is syncing — skip, do
// not queue), initial-vs-incremental routing, and error capture into the
// syncProgress kv row.

import { setSyncProgress } from '@/db/kv'
import { AuthRequiredError } from '@/gmail/errors'
import { depsNow, type SyncDeps } from './deps'
import { runIncrementalSync, type SyncRunResult } from './incremental'
import { repairParticipantSetConversations } from './participantSetRepair'

export type SyncReason = 'manual' | 'startup' | 'interval' | 'visibility' | 'online'

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
      // The cached alias/People snapshot can repair stale local routing before
      // any network work. A second pass catches aliases or Person display-name
      // enrichment learned during this sync; its signature gate makes the
      // usual no-change pass a small metadata check.
      await repairParticipantSetConversations(deps.db, deps.accountEmail, depsNow(deps))
      const result = await runIncrementalSync(deps)
      await repairParticipantSetConversations(deps.db, deps.accountEmail, depsNow(deps))
      return { ran: true, result }
    } catch (error) {
      const message =
        error instanceof AuthRequiredError
          ? 'Sign-in required'
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
