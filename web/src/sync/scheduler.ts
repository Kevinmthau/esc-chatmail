// Polling scheduler — the web equivalent of the iOS foreground sync loop
// (60s interval, 30s minimum gap), Page Visibility-aware, plus sync-on-focus
// and sync-on-reconnect triggers. All timers/documents are injectable so
// tests run without a real DOM clock.

import type { SyncReason } from './engine'

export const SCHEDULER_INTERVAL_MS = 60_000
export const SCHEDULER_MIN_GAP_MS = 30_000

interface EventTargetLike {
  addEventListener(type: string, listener: () => void): void
  removeEventListener(type: string, listener: () => void): void
}

export interface SchedulerOptions {
  runSync: (reason: SyncReason) => Promise<unknown>
  intervalMs?: number
  minGapMs?: number
  now?: () => number
  /** Defaults to the global document (visibilitychange + visibilityState). */
  doc?: EventTargetLike & { visibilityState: string }
  /** Defaults to the global window ('online' events). */
  win?: EventTargetLike
  setIntervalFn?: (handler: () => void, ms: number) => unknown
  clearIntervalFn?: (handle: unknown) => void
}

/**
 * Starts the scheduler; returns a stop() that removes every listener/timer.
 * Triggers: visibilitychange→visible, window 'online', and a 60s interval
 * gated by document visibility. Every trigger respects the 30s minimum gap.
 */
export function startScheduler(options: SchedulerOptions): () => void {
  const intervalMs = options.intervalMs ?? SCHEDULER_INTERVAL_MS
  const minGapMs = options.minGapMs ?? SCHEDULER_MIN_GAP_MS
  const now = options.now ?? Date.now
  const doc = options.doc ?? (typeof document !== 'undefined' ? document : undefined)
  const win = options.win ?? (typeof window !== 'undefined' ? window : undefined)
  const setIntervalFn =
    options.setIntervalFn ?? ((handler: () => void, ms: number) => setInterval(handler, ms))
  const clearIntervalFn =
    options.clearIntervalFn ??
    ((handle: unknown) => clearInterval(handle as ReturnType<typeof setInterval>))

  let lastRunAt = 0
  let stopped = false

  const maybeRun = (reason: SyncReason): void => {
    if (stopped) return
    const at = now()
    if (at - lastRunAt < minGapMs) return
    lastRunAt = at
    void options.runSync(reason).catch(() => {
      // Sync errors are recorded in kv progress by the engine; never unhandled.
    })
  }

  const onVisibility = (): void => {
    if (doc?.visibilityState === 'visible') maybeRun('visibility')
  }
  const onOnline = (): void => {
    maybeRun('online')
  }
  const onTick = (): void => {
    if (doc === undefined || doc.visibilityState === 'visible') maybeRun('interval')
  }

  doc?.addEventListener('visibilitychange', onVisibility)
  win?.addEventListener('online', onOnline)
  const timer = setIntervalFn(onTick, intervalMs)

  return () => {
    stopped = true
    doc?.removeEventListener('visibilitychange', onVisibility)
    win?.removeEventListener('online', onOnline)
    clearIntervalFn(timer)
  }
}
