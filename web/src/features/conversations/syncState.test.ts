import { describe, expect, it } from 'vitest'
import { isFirstSyncPending, syncProgressDetail } from './syncState'

describe('isFirstSyncPending', () => {
  it('is true for every state that has not delivered a first sync', () => {
    // runInitialSync's opening write, history recovery, a fresh/evicted DB and
    // the engine's error write (phase idle + lastError, no lastSyncAt) all mean
    // "unknown", not "empty mailbox".
    expect(isFirstSyncPending({ phase: 'initial', fetchedCount: 0 })).toBe(true)
    expect(isFirstSyncPending({ phase: 'recovery' })).toBe(true)
    expect(isFirstSyncPending({ phase: 'idle' })).toBe(true)
    expect(isFirstSyncPending({ phase: 'idle', lastSyncAt: 0 })).toBe(true)
    expect(isFirstSyncPending({ phase: 'idle', lastError: 'Sign-in required' })).toBe(true)
  })

  it('is false for an idle account with a recorded success', () => {
    expect(isFirstSyncPending({ phase: 'idle', lastSyncAt: 1_700_000_000_000 })).toBe(false)
  })

  it('is false during an incremental run even though it drops lastSyncAt', () => {
    // setSyncProgress replaces the whole row, so an in-flight incremental has
    // no lastSyncAt — but it only runs after a completed initial sync, so the
    // empty state must not flap on every poll.
    expect(isFirstSyncPending({ phase: 'incremental' })).toBe(false)
  })
})

describe('syncProgressDetail', () => {
  it('is undefined until the counter moves, so the line never freezes at 0', () => {
    expect(syncProgressDetail({ phase: 'initial', fetchedCount: 0 })).toBeUndefined()
    expect(syncProgressDetail({ phase: 'incremental' })).toBeUndefined()
  })

  it('includes the estimate as a denominator when it is bigger than the count', () => {
    expect(syncProgressDetail({ phase: 'initial', fetchedCount: 500, totalEstimate: 3000 })).toBe(
      '500 of about 3000 messages',
    )
  })

  it('drops an estimate the count has already passed', () => {
    expect(syncProgressDetail({ phase: 'initial', fetchedCount: 3200, totalEstimate: 3000 })).toBe(
      '3200 messages',
    )
  })
})
