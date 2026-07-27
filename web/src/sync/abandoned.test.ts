import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { GmailApiError } from '@/gmail/errors'
import {
  consecutiveFailureCount,
  drainAbandoned,
  MAX_ABANDONED_RETRIES,
  MAX_CONSECUTIVE_SYNC_FAILURES,
  persistentFailedIds,
  recordAbandonedRetryOutcome,
  recordSyncFailure,
  recordSyncSuccess,
  retryableAbandonedIds,
  shouldAdvanceHistoryId,
} from './abandoned'
import { runIncrementalSync, type IncrementalSyncResult } from './incremental'
import type { PersistContext } from './persist'
import {
  makeTestDb,
  ME,
  NOW,
  seedAccount,
  StubGmailApi,
  testDeps,
  textMessage,
} from './testSupport'

let db: ChatmailDB
let api: StubGmailApi

beforeEach(() => {
  db = makeTestDb()
  api = new StubGmailApi()
})

afterEach(async () => {
  await db.delete()
})

const ctx: PersistContext = {
  myAliases: new Set([ME]),
  sendAsAliases: [
    {
      email: ME,
      displayName: '',
      isDefault: true,
      isPrimary: true,
      verificationStatus: 'accepted',
    },
  ],
  knownLabelIds: null,
}

describe('failure tracking', () => {
  it('counts consecutive failures and dedupes tracked ids', async () => {
    await recordSyncFailure(db, ['a', 'b'])
    await recordSyncFailure(db, ['b', 'c'])
    expect(await consecutiveFailureCount(db)).toBe(2)
    expect(await persistentFailedIds(db)).toEqual(['a', 'b', 'c'])
    await recordSyncSuccess(db)
    expect(await consecutiveFailureCount(db)).toBe(0)
    expect(await persistentFailedIds(db)).toEqual([])
  })

  it('holds the cursor until the third consecutive failure, then abandons and advances', async () => {
    await recordSyncFailure(db, ['stuck'])
    expect(await shouldAdvanceHistoryId(db, true, NOW)).toBe(false)
    await recordSyncFailure(db, ['stuck'])
    expect(await shouldAdvanceHistoryId(db, true, NOW)).toBe(false)
    await recordSyncFailure(db, ['stuck'])
    expect(await consecutiveFailureCount(db)).toBe(MAX_CONSECUTIVE_SYNC_FAILURES)

    expect(await shouldAdvanceHistoryId(db, true, NOW)).toBe(true)
    const abandoned = await db.abandonedMessages.get('stuck')
    expect(abandoned).toMatchObject({ gmailMessageId: 'stuck', retryCount: 0, abandonedAt: NOW })
    // Tracking reset once the ids were parked.
    expect(await consecutiveFailureCount(db)).toBe(0)
    expect(await persistentFailedIds(db)).toEqual([])
  })

  it('re-abandonment refreshes the record without consuming the drain retry budget', async () => {
    await db.abandonedMessages.put({
      gmailMessageId: 'stuck',
      abandonedAt: NOW - 1000,
      reason: 'old',
      retryCount: 2,
    })
    await recordSyncFailure(db, ['stuck'])
    await recordSyncFailure(db, ['stuck'])
    await recordSyncFailure(db, ['stuck'])
    await shouldAdvanceHistoryId(db, true, NOW)
    expect((await db.abandonedMessages.get('stuck'))?.retryCount).toBe(2)
  })
})

describe('recordAbandonedRetryOutcome', () => {
  it('deletes recovered and gone ids, increments failures, gives up at 5', async () => {
    await db.abandonedMessages.bulkPut([
      { gmailMessageId: 'rec', abandonedAt: NOW, reason: 'r', retryCount: 1 },
      { gmailMessageId: 'gone', abandonedAt: NOW, reason: 'r', retryCount: 0 },
      { gmailMessageId: 'fail', abandonedAt: NOW, reason: 'r', retryCount: 0 },
      {
        gmailMessageId: 'last',
        abandonedAt: NOW,
        reason: 'r',
        retryCount: MAX_ABANDONED_RETRIES - 1,
      },
    ])
    await recordAbandonedRetryOutcome(db, {
      recoveredIds: ['rec'],
      goneIds: ['gone'],
      failedIds: ['fail', 'last'],
    })
    expect(await db.abandonedMessages.get('rec')).toBeUndefined()
    expect(await db.abandonedMessages.get('gone')).toBeUndefined()
    expect((await db.abandonedMessages.get('fail'))?.retryCount).toBe(1)
    // Reached the cap: given up permanently (deleted).
    expect(await db.abandonedMessages.get('last')).toBeUndefined()
  })

  it('retryableAbandonedIds excludes exhausted records and orders oldest first', async () => {
    await db.abandonedMessages.bulkPut([
      { gmailMessageId: 'new', abandonedAt: NOW, reason: 'r', retryCount: 0 },
      { gmailMessageId: 'old', abandonedAt: NOW - 5000, reason: 'r', retryCount: 4 },
      {
        gmailMessageId: 'done',
        abandonedAt: NOW - 9000,
        reason: 'r',
        retryCount: MAX_ABANDONED_RETRIES,
      },
    ])
    expect(await retryableAbandonedIds(db)).toEqual(['old', 'new'])
  })
})

describe('drainAbandoned', () => {
  it('recovers a fetchable message and reports it; 404 goes to goneIds', async () => {
    await db.abandonedMessages.bulkPut([
      { gmailMessageId: 'ok', abandonedAt: NOW - 2000, reason: 'r', retryCount: 0 },
      { gmailMessageId: 'vanished', abandonedAt: NOW - 1000, reason: 'r', retryCount: 0 },
    ])
    api.messages.set('ok', textMessage({ id: 'ok', from: 'alice@example.com' }))

    const result = await drainAbandoned(db, api, ctx, NOW)
    expect(result.outcome.recoveredIds).toEqual(['ok'])
    expect(result.outcome.goneIds).toEqual(['vanished'])
    expect(result.outcome.failedIds).toEqual([])
    expect(await db.messages.get('ok')).toBeDefined()
  })

  it('makes exactly ONE attempt per id (no in-drain retries)', async () => {
    await db.abandonedMessages.put({
      gmailMessageId: 'flaky',
      abandonedAt: NOW,
      reason: 'r',
      retryCount: 0,
    })
    api.getMessageErrors.set('flaky', () => new GmailApiError(500, 'backendError', 'boom'))
    const result = await drainAbandoned(db, api, ctx, NOW)
    expect(result.outcome.failedIds).toEqual(['flaky'])
    expect(api.getMessageCalls.filter((c) => c.startsWith('flaky'))).toHaveLength(1)
  })
})

describe('end-to-end via incremental sync', () => {
  it('after 3 failed syncs the cursor advances anyway and a later drain recovers the message', async () => {
    await seedAccount(db)
    api.getMessageErrors.set('stuck', () => new GmailApiError(500, 'backendError', 'boom'))
    api.historyFactory = () => ({
      historyId: 'h2',
      history: [
        {
          id: '1',
          messagesAdded: [
            { message: { id: 'stuck', threadId: 't', labelIds: ['INBOX', 'UNREAD'] } },
          ],
        },
      ],
    })

    // Syncs 1 and 2: cursor held.
    for (let i = 0; i < 2; i += 1) {
      const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
      expect(result.historyIdAdvanced).toBe(false)
      expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    }

    // Sync 3: threshold reached → abandon + advance.
    const third = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(third.historyIdAdvanced).toBe(true)
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect((await db.abandonedMessages.get('stuck'))?.retryCount).toBe(0)

    // Sync 4: the server recovered; the drain fetches it and clears the record.
    api.getMessageErrors.delete('stuck')
    api.messages.set(
      'stuck',
      textMessage({ id: 'stuck', from: 'alice@example.com', internalDate: NOW - 1000 }),
    )
    api.historyFactory = () => ({ historyId: 'h3', history: [] })
    await runIncrementalSync(testDeps(db, api))

    expect(await db.messages.get('stuck')).toBeDefined()
    expect(await db.abandonedMessages.get('stuck')).toBeUndefined()
  })

  it('a 404 during the drain deletes the record without blocking the cursor', async () => {
    await seedAccount(db)
    await db.abandonedMessages.put({
      gmailMessageId: 'ghost',
      abandonedAt: NOW,
      reason: 'r',
      retryCount: 1,
    })
    api.historyFactory = () => ({ historyId: 'h2', history: [] })

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.historyIdAdvanced).toBe(true)
    expect(await db.abandonedMessages.get('ghost')).toBeUndefined()
  })
})
