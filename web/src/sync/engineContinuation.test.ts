// A truncated history slice stages its continuation; one runSync must drain
// the backlog back-to-back instead of leaving each further slice to the next
// scheduler tick (iOS schedules an immediate follow-up).

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getHistoryContinuation } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { GmailApiError } from '@/gmail/errors'
import type { ListHistoryParams } from '@/gmail/endpoints'
import type { HistoryListResponse } from '@/gmail/types'
import { runSync, setSyncLockForTests } from './engine'
import { MAX_HISTORY_PAGES } from './incremental'
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
  setSyncLockForTests(undefined)
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

/** Two full slices plus a terminal page: page 0 adds `first`, the page behind the second cap adds `last`. */
function threeSliceHistory(first: string, last: string) {
  return (params: ListHistoryParams): HistoryListResponse => {
    const page = params.pageToken === undefined ? 0 : Number(params.pageToken.slice(1))
    if (page >= 2 * MAX_HISTORY_PAGES) {
      return { historyId: 'h2', history: added(last) }
    }
    return {
      historyId: 'h999',
      nextPageToken: `p${page + 1}`,
      ...(page === 0 ? { history: added(first) } : {}),
    }
  }
}

describe('runSync continuation drain', () => {
  // Revert-check: the MAX_CONTINUATION_SLICES_PER_RUN loop in runSync — without
  // it one runSync stops after the first truncated slice with the cursor frozen.
  it('drains every staged continuation slice in one run and advances the cursor', async () => {
    await seedAccount(db)
    api.messages.set('m1', textMessage({ id: 'm1', internalDate: NOW - 5000 }))
    api.messages.set('m101', textMessage({ id: 'm101', internalDate: NOW - 1000 }))
    api.historyFactory = threeSliceHistory('m1', 'm101')

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect(api.historyCalls).toHaveLength(2 * MAX_HISTORY_PAGES + 1)
    expect(api.historyCalls[MAX_HISTORY_PAGES]).toEqual({
      startHistoryId: 'h1',
      pageToken: `p${MAX_HISTORY_PAGES}`,
    })
    expect(await db.messages.get('m1')).toBeDefined()
    expect(await db.messages.get('m101')).toBeDefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(await getHistoryContinuation(db)).toBeNull()
    expect(outcome.result).toMatchObject({ wasTruncated: false, historyIdAdvanced: true })
  })

  // Revert-check: the `continuationStaged` guard of the drain loop — looping on
  // `wasTruncated` replays a held slice up to the bound within one run.
  it('does not replay a truncated slice that was held for blocking failures', async () => {
    await seedAccount(db)
    api.getMessageErrors.set('m1', () => new GmailApiError(500, 'backendError', 'boom'))
    api.messages.set('m101', textMessage({ id: 'm101', internalDate: NOW - 1000 }))
    api.historyFactory = threeSliceHistory('m1', 'm101')

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect(api.historyCalls).toHaveLength(MAX_HISTORY_PAGES)
    expect(await getHistoryContinuation(db)).toBeNull()
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    expect(outcome.result).toMatchObject({ wasTruncated: true, continuationStaged: false })
  })
})
