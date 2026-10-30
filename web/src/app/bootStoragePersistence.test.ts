import { afterEach, describe, expect, it, vi } from 'vitest'
import { getSyncProgress, setSyncProgress } from '@/db/kv'
import { deleteDBForAccount, getDB } from '@/db/schema'
import { getStoragePersistent } from '@/db/storagePersistence'
import { getAuthState, resetBootForTests, startBoot } from './boot'
import { FakeGis, bootWithBroker, seedStoredSession } from './bootTestSupport'

// Boot records the navigator.storage.persist verdict so the UI can tell the
// user their mailbox is evictable. It used to live inside the syncProgress
// row, which every sync writer replaces wholesale, so the startup sync that
// follows the request erased it within the same boot.
//
// Revert-check: requestPersistentStorage writing through setStoragePersistent
// (boot.ts). Put back as `setSyncProgress(db, { ...progress, storagePersistent })`,
// the verdict is undefined after the sync's progress write below.

const { getProfileMock } = vi.hoisted(() => ({ getProfileMock: vi.fn() }))

vi.mock('@/gmail/endpoints', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/gmail/endpoints')>()),
  getProfile: getProfileMock,
}))
vi.mock('@/sync/engine', () => ({
  runSync: vi.fn(() => Promise.resolve({ ran: true })),
}))
vi.mock('@/sync/scheduler', () => ({
  startScheduler: vi.fn(() => () => {}),
}))
vi.mock('@/outbox/pendingActions', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/outbox/pendingActions')>()),
  drainPendingActions: vi.fn(() => Promise.resolve()),
}))

const A = 'a@example.com'

function stubStorageManager(manager: Partial<StorageManager>): () => void {
  Object.defineProperty(navigator, 'storage', { value: manager, configurable: true })
  return () => {
    Reflect.deleteProperty(navigator, 'storage')
  }
}

describe('boot persistent-storage verdict', () => {
  afterEach(async () => {
    resetBootForTests()
    getProfileMock.mockReset()
    localStorage.clear()
    await deleteDBForAccount(A)
  })

  it('records the persist() verdict under its own key, where a sync progress write cannot erase it', async () => {
    const restore = stubStorageManager({
      persisted: () => Promise.resolve(false),
      persist: () => Promise.resolve(true),
    })
    try {
      const gis = new FakeGis()
      seedStoredSession(gis, { email: A, accessToken: 'tok-a' })
      bootWithBroker(gis, getProfileMock)
      await startBoot()
      await vi.waitFor(() => {
        expect(getAuthState()).toBe('ready')
      })
      await vi.waitFor(async () => {
        expect(await getStoragePersistent(getDB())).toBe(true)
      })

      // What the startup sync does moments later: replace the progress row.
      await setSyncProgress(getDB(), { phase: 'initial', fetchedCount: 0 })

      expect(await getStoragePersistent(getDB())).toBe(true)
      // And the verdict never rode inside the row the sync engine owns.
      expect(await getSyncProgress(getDB())).toEqual({ phase: 'initial', fetchedCount: 0 })
    } finally {
      restore()
    }
  })

  it('records a denied verdict as false, not as absent', async () => {
    const restore = stubStorageManager({
      persisted: () => Promise.resolve(false),
      persist: () => Promise.resolve(false),
    })
    try {
      const gis = new FakeGis()
      seedStoredSession(gis, { email: A, accessToken: 'tok-a' })
      bootWithBroker(gis, getProfileMock)
      await startBoot()
      await vi.waitFor(async () => {
        expect(await getStoragePersistent(getDB())).toBe(false)
      })
    } finally {
      restore()
    }
  })
})
