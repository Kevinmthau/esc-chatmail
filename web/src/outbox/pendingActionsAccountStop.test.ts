// Pending-action drain against account-scoped and throttle failures: a quota
// or cancellation error restores the row and stops the drain (the user's
// intent waits for the account), a throttle 403 — reaching the drain as
// RateLimitError — is a retriable failure, never an abandonment.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { BatchModifyParams, LabelChanges } from '@/gmail/endpoints'
import { QuotaExhaustedError, RateLimitError, RequestAbortedError } from '@/gmail/errors'
import { drainPendingActions, enqueue, type OutboxApi } from './pendingActions'
import { convoRow, makeTestDb, msgRow, NOW } from './testSupport'

interface StubApi extends OutboxApi {
  batchCalls: BatchModifyParams[]
  modifyCalls: Array<{ id: string; changes: LabelChanges }>
  error: Error | null
}

function makeStubApi(error: Error | null): StubApi {
  const api: StubApi = {
    batchCalls: [],
    modifyCalls: [],
    error,
    batchModify(params) {
      api.batchCalls.push(params)
      return api.error === null ? Promise.resolve() : Promise.reject(api.error)
    },
    modifyMessage(id, changes) {
      api.modifyCalls.push({ id, changes })
      return api.error === null ? Promise.resolve() : Promise.reject(api.error)
    },
  }
  return api
}

describe('drainPendingActions account-scoped stop', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.bulkAdd([
      msgRow({ id: 'm1', conversationId: 'c1' }),
      msgRow({ id: 'm2', conversationId: 'c1' }),
    ])
    await enqueue(db, { actionType: 'archive', conversationId: 'c1', messageId: 'm1' }, NOW)
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageId: 'm2' }, NOW + 1)
  })

  afterEach(async () => {
    await db.delete()
  })

  for (const [label, error] of [
    ['QuotaExhaustedError', new QuotaExhaustedError('Daily limit exceeded')],
    ['RequestAbortedError', new RequestAbortedError()],
  ] as const) {
    // Revert-check: isAccountScopedSyncAbort in processRow (pendingActions.ts)
    // — reverted, the row is set 'abandoned' after one attempt and m2 is
    // attempted anyway.
    it(`${label}: restores the row as pending and stops the drain`, async () => {
      const api = makeStubApi(error)

      const result = await drainPendingActions(db, api, { now: () => NOW })

      expect(result).toEqual({ processed: 0, completed: 0, failed: 0, abandoned: 0 })
      expect(api.modifyCalls.map((c) => c.id)).toEqual(['m1'])
      const rows = await db.pendingActions.toCollection().sortBy('createdAt')
      expect(rows.map((r) => r.status)).toEqual(['pending', 'pending'])
      expect(rows[0]?.retryCount).toBe(0)

      // Once the account is usable again the same rows drain in order.
      api.error = null
      const retry = await drainPendingActions(db, api, { now: () => NOW + 1000 })
      expect(retry.completed).toBe(2)
    })
  }

  // Revert-check: classify403 in gmailFetch.ts turns the throttle 403 into
  // the RateLimitError this drain already retries; a plain GmailApiError(403)
  // is abandoned on its first attempt.
  it('a throttle (RateLimitError without Retry-After) is a retriable failure, not an abandonment', async () => {
    const api = makeStubApi(new RateLimitError(null))

    const result = await drainPendingActions(db, api, { now: () => NOW })

    expect(result.abandoned).toBe(0)
    expect(result.failed).toBeGreaterThan(0)
    const rows = await db.pendingActions.toCollection().sortBy('createdAt')
    expect(rows[0]).toMatchObject({ status: 'failed', retryCount: 1 })
    expect(rows.every((r) => r.status !== 'abandoned')).toBe(true)
  })
})
