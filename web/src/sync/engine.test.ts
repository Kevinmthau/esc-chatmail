import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getSyncProgress } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { runSync, setSyncLockForTests, syncLockName } from './engine'
import { makeTestDb, ME, seedAccount, StubGmailApi, testDeps } from './testSupport'

let db: ChatmailDB
let api: StubGmailApi

beforeEach(() => {
  db = makeTestDb()
  api = new StubGmailApi()
})

afterEach(async () => {
  setSyncLockForTests(undefined)
  await db.delete()
})

describe('runSync', () => {
  it('runs an incremental sync under the per-account lock', async () => {
    await seedAccount(db)
    api.historyFactory = () => ({ historyId: 'h2', history: [] })
    const outcome = await runSync(testDeps(db, api), 'manual')
    expect(outcome.ran).toBe(true)
    expect(outcome.error).toBeUndefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
  })

  it('skips entirely when the lock is already held (ifAvailable, no queueing)', async () => {
    setSyncLockForTests({
      request: (name, callback) => {
        expect(name).toBe(syncLockName(ME))
        return callback(false)
      },
    })
    const outcome = await runSync(testDeps(db, api), 'interval')
    expect(outcome).toEqual({ ran: false })
    expect(api.historyCalls).toHaveLength(0)
  })

  it('serializes concurrent runs in-process: the second is skipped', async () => {
    setSyncLockForTests(null) // force the fallback held-set
    await seedAccount(db)
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    api.historyFactory = () => ({ historyId: 'h2', history: [] })
    const slowDeps = testDeps(db, api)
    slowDeps.hooks = {
      onPhase: async (phase) => {
        if (phase === 'incremental:afterHistory') await gate
      },
    }

    const first = runSync(slowDeps, 'manual')
    const second = await runSync(testDeps(db, api), 'interval')
    expect(second.ran).toBe(false)
    release()
    expect((await first).ran).toBe(true)
  })

  it('captures sync errors into kv progress lastError instead of throwing', async () => {
    await seedAccount(db)
    api.historyError = new Error('network exploded')
    const outcome = await runSync(testDeps(db, api), 'online')
    expect(outcome.ran).toBe(true)
    expect(outcome.error).toBeInstanceOf(Error)
    const progress = await getSyncProgress(db)
    expect(progress.phase).toBe('idle')
    expect(progress.lastError).toBe('network exploded')
  })
})
