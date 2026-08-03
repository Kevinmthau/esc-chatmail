import { describe, expect, it } from 'vitest'
import type { SyncReason } from './engine'
import { SCHEDULER_INTERVAL_MS, SCHEDULER_MIN_GAP_MS, startScheduler } from './scheduler'

interface Listener {
  type: string
  fn: () => void
}

function makeTarget() {
  const listeners: Listener[] = []
  return {
    listeners,
    addEventListener: (type: string, fn: () => void) => listeners.push({ type, fn }),
    removeEventListener: (type: string, fn: () => void) => {
      const index = listeners.findIndex((l) => l.type === type && l.fn === fn)
      if (index >= 0) listeners.splice(index, 1)
    },
    fire(type: string) {
      for (const l of [...listeners]) if (l.type === type) l.fn()
    },
  }
}

function harness(options: { visibility?: string } = {}) {
  const runs: SyncReason[] = []
  const doc = Object.assign(makeTarget(), { visibilityState: options.visibility ?? 'visible' })
  const win = makeTarget()
  let tick: (() => void) | null = null
  let clock = 1_000_000
  let cleared: unknown = null

  const stop = startScheduler({
    runSync: (reason) => {
      runs.push(reason)
      return Promise.resolve()
    },
    now: () => clock,
    doc,
    win,
    setIntervalFn: (handler) => {
      tick = handler
      return 'timer'
    },
    clearIntervalFn: (handle) => {
      cleared = handle
    },
  })

  return {
    runs,
    doc,
    win,
    stop,
    advance: (ms: number) => {
      clock += ms
    },
    tick: () => tick?.(),
    wasCleared: () => cleared === 'timer',
  }
}

describe('startScheduler', () => {
  it('fires on the interval only while visible', () => {
    const h = harness()
    h.tick()
    expect(h.runs).toEqual(['interval'])

    h.advance(SCHEDULER_INTERVAL_MS)
    h.doc.visibilityState = 'hidden'
    h.tick()
    expect(h.runs).toEqual(['interval'])
    h.stop()
  })

  it('enforces the 30s minimum gap across triggers', () => {
    const h = harness()
    h.tick()
    h.advance(SCHEDULER_MIN_GAP_MS - 1)
    h.win.fire('online')
    h.doc.fire('visibilitychange')
    expect(h.runs).toEqual(['interval'])

    h.advance(1)
    h.win.fire('online')
    expect(h.runs).toEqual(['interval', 'online'])
    h.stop()
  })

  it('syncs when the tab becomes visible, but not when it hides', () => {
    const h = harness({ visibility: 'hidden' })
    h.doc.fire('visibilitychange')
    expect(h.runs).toEqual([])

    h.doc.visibilityState = 'visible'
    h.doc.fire('visibilitychange')
    expect(h.runs).toEqual(['visibility'])
    h.stop()
  })

  it('syncs on reconnect', () => {
    const h = harness()
    h.win.fire('online')
    expect(h.runs).toEqual(['online'])
    h.stop()
  })

  it('stop() removes listeners and clears the timer', () => {
    const h = harness()
    h.stop()
    expect(h.doc.listeners).toHaveLength(0)
    expect(h.win.listeners).toHaveLength(0)
    expect(h.wasCleared()).toBe(true)

    h.win.fire('online')
    h.tick()
    expect(h.runs).toEqual([])
  })
})
