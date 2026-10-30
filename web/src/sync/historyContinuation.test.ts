// History continuation checkpoint (port of ForegroundHistoryCheckpointStore +
// IncrementalSyncOrchestrator's advance block): a slice truncated at the page
// cap stages its next page token so the following run resumes at page 51
// while the Account cursor stays frozen.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getHistoryContinuation, getLastSuccessfulSyncAt, setHistoryContinuation } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { GmailApiError } from '@/gmail/errors'
import { HistoryIdExpiredError } from '@/gmail/historyError'
import type { ListHistoryParams } from '@/gmail/endpoints'
import type { HistoryListResponse } from '@/gmail/types'
import { consecutiveFailureCount, MAX_CONSECUTIVE_SYNC_FAILURES } from './abandoned'
import {
  isInvalidHistoryPageTokenError,
  MAX_HISTORY_PAGES,
  runIncrementalSync,
  type IncrementalSyncResult,
} from './incremental'
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

function added(id: string): HistoryListResponse['history'] {
  return [
    {
      id: `rec_${id}`,
      messagesAdded: [{ message: { id, threadId: `t_${id}`, labelIds: ['INBOX', 'UNREAD'] } }],
    },
  ]
}

/**
 * A mailbox whose history is MAX_HISTORY_PAGES + 1 pages long: page 0 adds
 * `first`, every page links to `p<n+1>`, and the page behind the cap token
 * (`p<cap>`) is terminal, adds `beyondCap`, and reports the new cursor.
 */
function longHistory(first: string, beyondCap: string, finalHistoryId = 'h2') {
  return (params: ListHistoryParams): HistoryListResponse => {
    const page = params.pageToken === undefined ? 0 : Number(params.pageToken.slice(1))
    if (page >= MAX_HISTORY_PAGES) {
      return { historyId: finalHistoryId, history: added(beyondCap) }
    }
    return {
      historyId: 'h999',
      nextPageToken: `p${page + 1}`,
      ...(page === 0 ? { history: added(first) } : {}),
    }
  }
}

async function sync(): Promise<IncrementalSyncResult> {
  return (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
}

describe('history continuation', () => {
  // Revert-check: finalizeSync's 'stage' branch / loadCompatibleContinuation
  // in incremental.ts — without them the second run restarts at page 1,
  // never requests page 51, re-fetches m1 and leaves the cursor at h1.
  it('truncated slice stages its page token, the next run resumes from it and only then advances the cursor', async () => {
    await seedAccount(db)
    api.messages.set('m1', textMessage({ id: 'm1', internalDate: NOW - 5000 }))
    api.messages.set('m51', textMessage({ id: 'm51', internalDate: NOW - 1000 }))
    api.historyFactory = longHistory('m1', 'm51')

    const first = await sync()
    expect(first.wasTruncated).toBe(true)
    expect(first.historyIdAdvanced).toBe(false)
    expect(first.needsFollowUp).toBe(true)
    expect(api.historyCalls).toHaveLength(MAX_HISTORY_PAGES)
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    expect(await getHistoryContinuation(db)).toEqual({
      startHistoryId: 'h1',
      pageToken: `p${MAX_HISTORY_PAGES}`,
    })
    // The slice's effects landed with the checkpoint: m1 is persisted.
    expect(await db.messages.get('m1')).toBeDefined()
    expect(await getLastSuccessfulSyncAt(db)).toBe(0)

    api.historyCalls = []
    api.getMessageCalls = []
    const second = await sync()
    expect(api.historyCalls).toEqual([{ startHistoryId: 'h1', pageToken: `p${MAX_HISTORY_PAGES}` }])
    // Page 1's message is not re-fetched; page 51's is.
    expect(api.getMessageCalls).toEqual(['m51:full'])
    expect(await db.messages.get('m51')).toBeDefined()
    expect(second.wasTruncated).toBe(false)
    expect(second.historyIdAdvanced).toBe(true)
    expect(second.needsFollowUp).toBe(false)
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(await getHistoryContinuation(db)).toBeNull()
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW)
  })

  // Revert-check: loadCompatibleContinuation's startHistoryId comparison.
  it('discards a continuation stored for another cursor and replays from the frozen cursor', async () => {
    await seedAccount(db, { historyId: 'h1' })
    await setHistoryContinuation(db, { startHistoryId: 'h0', pageToken: 'stale' })
    api.historyPages = [{ historyId: 'h2' }]

    const result = await sync()

    expect(api.historyCalls).toEqual([{ startHistoryId: 'h1' }])
    expect(result.historyIdAdvanced).toBe(true)
    expect(await getHistoryContinuation(db)).toBeNull()
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
  })

  // Revert-check: the `sliceResolved` gate in runIncrementalSync — staging
  // regardless of the ledger would skip past a slice whose message never
  // materialized.
  it('stages no checkpoint when the truncated slice had blocking failures, and keeps retrying the same slice', async () => {
    await seedAccount(db)
    api.getMessageErrors.set('m1', () => new GmailApiError(500, 'backendError', 'boom'))
    api.historyFactory = longHistory('m1', 'm51')

    const result = await sync()

    expect(result.wasTruncated).toBe(true)
    expect(result.needsFollowUp).toBe(true)
    expect(await getHistoryContinuation(db)).toBeNull()
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    expect(await consecutiveFailureCount(db)).toBe(1)

    // The next run starts over from the frozen cursor, not from page 51.
    api.historyCalls = []
    await sync()
    expect(api.historyCalls[0]).toEqual({ startHistoryId: 'h1' })
  })

  it('stages the checkpoint once the escape hatch abandons the stuck ids', async () => {
    await seedAccount(db)
    api.getMessageErrors.set('m1', () => new GmailApiError(500, 'backendError', 'boom'))
    api.historyFactory = longHistory('m1', 'm51')

    for (let run = 1; run < MAX_CONSECUTIVE_SYNC_FAILURES; run += 1) {
      await sync()
      expect(await getHistoryContinuation(db)).toBeNull()
    }
    await sync()

    expect(await getHistoryContinuation(db)).toEqual({
      startHistoryId: 'h1',
      pageToken: `p${MAX_HISTORY_PAGES}`,
    })
    expect(await db.abandonedMessages.get('m1')).toBeDefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
  })

  // Revert-check: isInvalidHistoryPageTokenError + the restart in
  // runIncrementalSync's phase 1.
  it('drops a stored token Gmail rejects and replays once from the frozen cursor', async () => {
    await seedAccount(db)
    await setHistoryContinuation(db, { startHistoryId: 'h1', pageToken: 'dead' })
    api.historyFactory = (params) => {
      if (params.pageToken === 'dead') {
        throw new GmailApiError(400, 'invalidArgument', 'Invalid pageToken')
      }
      return { historyId: 'h2' }
    }

    const result = await sync()

    expect(api.historyCalls).toEqual([
      { startHistoryId: 'h1', pageToken: 'dead' },
      { startHistoryId: 'h1' },
    ])
    expect(result.historyIdAdvanced).toBe(true)
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(await getHistoryContinuation(db)).toBeNull()
  })

  it('propagates the same rejection on a first page (no stored token)', async () => {
    await seedAccount(db)
    api.historyError = new GmailApiError(400, 'invalidArgument', 'Invalid pageToken')

    await expect(runIncrementalSync(testDeps(db, api))).rejects.toBeInstanceOf(GmailApiError)
    expect(api.historyCalls).toHaveLength(1)
  })

  // Revert-check: clearHistoryContinuation in runHistoryRecovery.
  it('clears the continuation when the cursor expires and recovery runs', async () => {
    await seedAccount(db)
    await setHistoryContinuation(db, { startHistoryId: 'h1', pageToken: 'p50' })
    api.historyError = new HistoryIdExpiredError('expired')
    api.profile = { emailAddress: ME, historyId: 'h5' }
    api.listPages = [{}]

    const result = await sync()

    expect(result.mode).toBe('recovery')
    expect(await getHistoryContinuation(db)).toBeNull()
    expect((await db.accounts.get(ME))?.historyId).toBe('h5')
  })
})

describe('isInvalidHistoryPageTokenError', () => {
  it('matches only a 4xx whose message or reason names the page token', () => {
    expect(
      isInvalidHistoryPageTokenError(
        new GmailApiError(400, 'invalidArgument', 'Invalid pageToken'),
      ),
    ).toBe(true)
    expect(
      isInvalidHistoryPageTokenError(
        new GmailApiError(400, 'invalidPageToken', 'Request contains an invalid argument.'),
      ),
    ).toBe(true)
    expect(
      isInvalidHistoryPageTokenError(
        new GmailApiError(400, 'invalidArgument', 'Page token expired'),
      ),
    ).toBe(true)
    // Names the frozen cursor: that is history expiry, never a token replay.
    expect(
      isInvalidHistoryPageTokenError(
        new GmailApiError(400, 'invalidArgument', 'Invalid startHistoryId and pageToken'),
      ),
    ).toBe(false)
    expect(
      isInvalidHistoryPageTokenError(new GmailApiError(400, 'invalidArgument', 'Bad request')),
    ).toBe(false)
    expect(
      isInvalidHistoryPageTokenError(new GmailApiError(500, 'backendError', 'Invalid pageToken')),
    ).toBe(false)
    expect(isInvalidHistoryPageTokenError(new Error('Invalid pageToken'))).toBe(false)
  })
})

describe('kv history continuation', () => {
  it('rejects an empty token and reads back a stored one byte-for-byte', async () => {
    await expect(
      setHistoryContinuation(db, { startHistoryId: 'h1', pageToken: '  ' }),
    ).rejects.toThrow()
    await setHistoryContinuation(db, { startHistoryId: 'h1', pageToken: ' p=1/== ' })
    expect(await getHistoryContinuation(db)).toEqual({
      startHistoryId: 'h1',
      pageToken: ' p=1/== ',
    })
  })

  it('treats a malformed stored row as absent', async () => {
    await db.syncState.put({ key: 'historyContinuation', value: { pageToken: 'x' } })
    expect(await getHistoryContinuation(db)).toBeNull()
  })
})
