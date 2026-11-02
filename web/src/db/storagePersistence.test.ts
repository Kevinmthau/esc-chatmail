import { afterEach, describe, expect, it } from 'vitest'
import { getSyncProgress, setSyncProgress } from './kv'
import { ChatmailDB } from './schema'
import { getStoragePersistent, setStoragePersistent } from './storagePersistence'

// Revert-check: storagePersistence.ts keying the verdict on its own syncState
// row. Stored in the syncProgress row instead, `setSyncProgress` (a wholesale
// put) drops it in the first test, and the verdict shows up in the progress
// row in the second.

describe('storagePersistence', () => {
  const db = new ChatmailDB('escmail_storagePersistenceTest')

  afterEach(async () => {
    await db.syncState.clear()
  })

  it('a sync progress replacement leaves the recorded verdict intact', async () => {
    await setStoragePersistent(db, true)
    await setSyncProgress(db, { phase: 'initial', fetchedCount: 0 })
    await setSyncProgress(db, { phase: 'idle', lastSyncAt: 1 })
    expect(await getStoragePersistent(db)).toBe(true)
  })

  it('the verdict is not part of the sync progress row', async () => {
    await setSyncProgress(db, { phase: 'incremental' })
    await setStoragePersistent(db, false)
    expect(await getSyncProgress(db)).toEqual({ phase: 'incremental' })
    expect(await getStoragePersistent(db)).toBe(false)
  })

  it('reads undefined before any boot recorded a verdict', async () => {
    expect(await getStoragePersistent(db)).toBeUndefined()
  })
})
