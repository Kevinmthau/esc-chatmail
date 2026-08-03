import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { GmailApiError } from '@/gmail/errors'
import {
  abandonedRetryDelayMs,
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
import { UNPROCESSABLE_REASON } from './unprocessable'
import {
  makeTestDb,
  ME,
  NOW,
  b64url,
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
  it('deletes resolved ids but retains and schedules failures at the old retry cap', async () => {
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
    await recordAbandonedRetryOutcome(
      db,
      {
        recoveredIds: ['rec'],
        goneIds: ['gone'],
        failedIds: ['fail', 'last'],
      },
      NOW,
    )
    expect(await db.abandonedMessages.get('rec')).toBeUndefined()
    expect(await db.abandonedMessages.get('gone')).toBeUndefined()
    expect((await db.abandonedMessages.get('fail'))?.retryCount).toBe(1)
    expect(await db.abandonedMessages.get('last')).toMatchObject({
      retryCount: MAX_ABANDONED_RETRIES,
      lastAttemptAt: NOW,
      nextAttemptAt: NOW + abandonedRetryDelayMs(MAX_ABANDONED_RETRIES),
      terminal: 0,
    })
    expect(await retryableAbandonedIds(db, NOW)).not.toContain('last')
    expect(
      await retryableAbandonedIds(db, NOW + abandonedRetryDelayMs(MAX_ABANDONED_RETRIES)),
    ).toContain('last')
  })

  it('excludes scheduled and terminal rows while retaining recoverable legacy rows', async () => {
    await db.abandonedMessages.bulkPut([
      {
        gmailMessageId: 'due',
        abandonedAt: NOW - 5000,
        reason: 'r',
        retryCount: 4,
        terminal: 0,
        nextAttemptAt: NOW,
      },
      {
        gmailMessageId: 'waiting',
        abandonedAt: NOW,
        reason: 'r',
        retryCount: 1,
        terminal: 0,
        nextAttemptAt: NOW + 1,
      },
      {
        gmailMessageId: 'legacy-transient',
        abandonedAt: NOW - 9000,
        reason: 'r',
        retryCount: MAX_ABANDONED_RETRIES,
      },
      {
        gmailMessageId: 'terminal',
        abandonedAt: NOW - 10_000,
        reason: 'r',
        retryCount: MAX_ABANDONED_RETRIES,
        terminal: 1,
      },
      {
        gmailMessageId: 'legacy-terminal',
        abandonedAt: NOW - 11_000,
        reason: UNPROCESSABLE_REASON,
        retryCount: MAX_ABANDONED_RETRIES,
      },
    ])
    expect(await retryableAbandonedIds(db, NOW)).toEqual(['legacy-transient', 'due'])
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

  it('keeps an inline-quota failure retryable instead of reporting it recovered', async () => {
    await db.abandonedMessages.put({
      gmailMessageId: 'inline',
      abandonedAt: NOW,
      reason: 'r',
      retryCount: 0,
    })
    const message = textMessage({ id: 'inline', from: 'alice@example.com' })
    message.payload = {
      partId: '',
      mimeType: 'multipart/related',
      headers: message.payload!.headers!,
      parts: [
        { partId: '0', mimeType: 'text/html', body: { data: b64url('<b>hi</b>') } },
        {
          partId: '1',
          mimeType: 'image/png',
          headers: [{ name: 'Content-ID', value: '<logo@x>' }],
          body: { data: b64url('PNGDATA'), size: 7 },
        },
      ],
    }
    api.messages.set('inline', message)
    const put = vi
      .spyOn(db.blobs, 'put')
      .mockRejectedValueOnce(new DOMException('quota', 'QuotaExceededError'))

    const result = await drainAbandoned(db, api, ctx, NOW)

    expect(result.outcome.recoveredIds).toEqual([])
    expect(result.outcome.failedIds).toEqual(['inline'])
    expect(await db.messages.get('inline')).toBeDefined()
    put.mockRestore()
  })

  it('terminalizes a fetched message that cannot be parsed instead of retrying forever', async () => {
    await db.abandonedMessages.put({
      gmailMessageId: 'broken',
      abandonedAt: NOW,
      reason: 'transport failed',
      retryCount: 2,
      terminal: 0,
    })
    api.messages.set('broken', { id: 'broken', threadId: 't-broken', labelIds: ['INBOX'] })

    const result = await drainAbandoned(db, api, ctx, NOW)

    expect(result.outcome).toEqual({ recoveredIds: [], goneIds: [], failedIds: [] })
    expect(await db.abandonedMessages.get('broken')).toMatchObject({
      gmailMessageId: 'broken',
      reason: UNPROCESSABLE_REASON,
      terminal: 1,
    })
    expect(await retryableAbandonedIds(db, NOW + 365 * 24 * 60 * 60 * 1000)).toEqual([])
  })

  it('recovers after exceeding five attempts instead of losing the tombstone', async () => {
    await db.abandonedMessages.put({
      gmailMessageId: 'stuck',
      abandonedAt: NOW,
      reason: 'r',
      retryCount: MAX_ABANDONED_RETRIES - 1,
      terminal: 0,
      nextAttemptAt: NOW,
    })
    api.getMessageErrors.set('stuck', () => new GmailApiError(500, 'backendError', 'boom'))

    const failed = await drainAbandoned(db, api, ctx, NOW)
    await recordAbandonedRetryOutcome(db, failed.outcome, NOW)
    const retained = (await db.abandonedMessages.get('stuck'))!
    expect(retained.retryCount).toBe(MAX_ABANDONED_RETRIES)
    const retryAt = retained.nextAttemptAt ?? 0
    expect(retryAt).toBeGreaterThan(NOW)

    api.getMessageErrors.delete('stuck')
    api.messages.set('stuck', textMessage({ id: 'stuck', from: 'alice@example.com' }))
    const recovered = await drainAbandoned(db, api, ctx, retryAt)
    await recordAbandonedRetryOutcome(db, recovered.outcome, retryAt)

    expect(await db.messages.get('stuck')).toBeDefined()
    expect(await db.abandonedMessages.get('stuck')).toBeUndefined()
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
