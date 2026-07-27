import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { PendingActionRow } from '@/db/types'
import type { BatchModifyParams, LabelChanges } from '@/gmail/endpoints'
import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from '@/gmail/errors'
import {
  drainPendingActions,
  enqueue,
  labelChangesForAction,
  MAX_PENDING_ACTION_RETRIES,
  pendingActionBackoffMs,
  STALE_PROCESSING_MS,
  type OutboxApi,
} from './pendingActions'
import { convoRow, makeTestDb, msgRow, NOW } from './testSupport'

interface StubApi extends OutboxApi {
  batchCalls: BatchModifyParams[]
  modifyCalls: Array<{ id: string; changes: LabelChanges }>
  error: Error | null
}

function makeStubApi(): StubApi {
  const api: StubApi = {
    batchCalls: [],
    modifyCalls: [],
    error: null,
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

function makeSleepRecorder(onSleep?: () => void): {
  sleeps: number[]
  sleep: (ms: number) => Promise<void>
} {
  const sleeps: number[] = []
  return {
    sleeps,
    sleep: (ms) => {
      sleeps.push(ms)
      onSleep?.()
      return Promise.resolve()
    },
  }
}

describe('labelChangesForAction', () => {
  it('maps every action type to the exact Gmail label changes', () => {
    expect(labelChangesForAction('markRead')).toEqual({ removeLabelIds: ['UNREAD'] })
    expect(labelChangesForAction('markUnread')).toEqual({ addLabelIds: ['UNREAD'] })
    expect(labelChangesForAction('archive')).toEqual({ removeLabelIds: ['INBOX'] })
    expect(labelChangesForAction('archiveConversation')).toEqual({ removeLabelIds: ['INBOX'] })
    expect(labelChangesForAction('star')).toEqual({ addLabelIds: ['STARRED'] })
    expect(labelChangesForAction('unstar')).toEqual({ removeLabelIds: ['STARRED'] })
    expect(labelChangesForAction('reportSpam')).toEqual({
      addLabelIds: ['SPAM'],
      removeLabelIds: ['INBOX'],
    })
  })
})

describe('pendingActionBackoffMs', () => {
  it('doubles from 2s per retry and caps at 30s', () => {
    expect(pendingActionBackoffMs(0)).toBe(2000)
    expect(pendingActionBackoffMs(1)).toBe(4000)
    expect(pendingActionBackoffMs(2)).toBe(8000)
    expect(pendingActionBackoffMs(3)).toBe(16000)
    expect(pendingActionBackoffMs(4)).toBe(30000)
    expect(pendingActionBackoffMs(10)).toBe(30000)
  })
})

describe('drainPendingActions', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await db.conversations.add(convoRow({ id: 'c1' }))
  })

  afterEach(async () => {
    await db.delete()
  })

  it('executes a batch action, completes it, and clears untouched localModifiedAt', async () => {
    await db.messages.bulkAdd([
      msgRow({ id: 'm1', conversationId: 'c1', localModifiedAt: NOW - 1000 }),
      // Re-modified AFTER the claim time: guard must be kept.
      msgRow({
        id: 'm2',
        conversationId: 'c1',
        localModifiedAt: NOW + 5000,
        internalDate: NOW - 100,
      }),
    ])
    await enqueue(
      db,
      { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1', 'm2'] },
      NOW,
    )

    const api = makeStubApi()
    const result = await drainPendingActions(db, api, { now: () => NOW })

    expect(api.batchCalls).toEqual([{ ids: ['m1', 'm2'], removeLabelIds: ['UNREAD'] }])
    expect(result).toEqual({ processed: 1, completed: 1, failed: 0, abandoned: 0 })
    expect((await db.pendingActions.toArray())[0]?.status).toBe('completed')
    expect((await db.messages.get('m1'))?.localModifiedAt).toBe(0)
    expect((await db.messages.get('m2'))?.localModifiedAt).toBe(NOW + 5000)
  })

  it('uses modifyMessage for single-message actions', async () => {
    await db.messages.add(msgRow({ id: 'm1', conversationId: 'c1' }))
    await enqueue(db, { actionType: 'markUnread', conversationId: 'c1', messageId: 'm1' }, NOW)

    const api = makeStubApi()
    await drainPendingActions(db, api, { now: () => NOW })

    expect(api.batchCalls).toHaveLength(0)
    expect(api.modifyCalls).toEqual([{ id: 'm1', changes: { addLabelIds: ['UNREAD'] } }])
  })

  it('sweeps completed rows at the start of the next drain', async () => {
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1'] }, NOW)
    const api = makeStubApi()
    await drainPendingActions(db, api, { now: () => NOW })
    expect(await db.pendingActions.count()).toBe(1)

    await drainPendingActions(db, api, { now: () => NOW })
    expect(await db.pendingActions.count()).toBe(0)
  })

  it('marks retriable failures failed with retryCount++, backing off on later drains', async () => {
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1'] }, NOW)
    const api = makeStubApi()
    api.error = new GmailApiError(503, 'backendError', 'boom')

    const recorder1 = makeSleepRecorder()
    const r1 = await drainPendingActions(db, api, { now: () => NOW, sleep: recorder1.sleep })
    expect(r1.failed).toBe(1)
    expect(recorder1.sleeps).toEqual([]) // fresh pending row: no backoff
    let row = (await db.pendingActions.toArray())[0]
    expect(row?.status).toBe('failed')
    expect(row?.retryCount).toBe(1)

    const recorder2 = makeSleepRecorder()
    await drainPendingActions(db, api, { now: () => NOW, sleep: recorder2.sleep })
    expect(recorder2.sleeps).toEqual([4000]) // 2^1 * 2s
    row = (await db.pendingActions.toArray())[0]
    expect(row?.retryCount).toBe(2)

    const recorder3 = makeSleepRecorder()
    api.error = null
    await drainPendingActions(db, api, { now: () => NOW, sleep: recorder3.sleep })
    expect(recorder3.sleeps).toEqual([8000]) // 2^2 * 2s
    expect((await db.pendingActions.toArray())[0]?.status).toBe('completed')
  })

  it('treats RateLimitError and NetworkError as retriable', async () => {
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1'] }, NOW)
    await enqueue(db, { actionType: 'markUnread', conversationId: 'c1', messageId: 'm2' }, NOW + 1)
    const api = makeStubApi()
    api.error = new RateLimitError(10)
    await drainPendingActions(db, api, { now: () => NOW, sleep: () => Promise.resolve() })
    api.error = new NetworkError('offline')
    await drainPendingActions(db, api, { now: () => NOW, sleep: () => Promise.resolve() })

    const rows = await db.pendingActions.toArray()
    expect(rows.every((r) => r.status === 'failed')).toBe(true)
  })

  it('abandons non-retriable 4xx failures immediately', async () => {
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1'] }, NOW)
    const api = makeStubApi()
    api.error = new GmailApiError(404, 'notFound', 'gone')

    const result = await drainPendingActions(db, api, { now: () => NOW })
    expect(result.abandoned).toBe(1)
    expect((await db.pendingActions.toArray())[0]?.status).toBe('abandoned')
  })

  it('abandons after the retry budget is exhausted', async () => {
    const row: PendingActionRow = {
      actionType: 'markRead',
      status: 'failed',
      messageId: '',
      conversationId: 'c1',
      messageIds: ['m1'],
      retryCount: MAX_PENDING_ACTION_RETRIES - 1,
      createdAt: NOW - 1000,
      lastAttempt: NOW - 1000,
    }
    await db.pendingActions.add(row)
    const api = makeStubApi()
    api.error = new GmailApiError(500, 'backendError', 'boom')

    const recorder = makeSleepRecorder()
    const result = await drainPendingActions(db, api, { now: () => NOW, sleep: recorder.sleep })
    // 2^4 * 2s capped, minus the 1s already elapsed since lastAttempt.
    expect(recorder.sleeps).toEqual([29000])
    expect(result.abandoned).toBe(1)
    const updated = (await db.pendingActions.toArray())[0]
    expect(updated?.status).toBe('abandoned')
    expect(updated?.retryCount).toBe(MAX_PENDING_ACTION_RETRIES)
  })

  it('skips failed rows that already exhausted their retries', async () => {
    await db.pendingActions.add({
      actionType: 'markRead',
      status: 'failed',
      messageId: '',
      conversationId: 'c1',
      messageIds: ['m1'],
      retryCount: MAX_PENDING_ACTION_RETRIES,
      createdAt: NOW - 1000,
      lastAttempt: NOW - 1000,
    })
    const api = makeStubApi()
    const result = await drainPendingActions(db, api, { now: () => NOW })
    expect(result.processed).toBe(0)
    expect(api.batchCalls).toHaveLength(0)
  })

  it('resets stale processing rows to failed and retries them in the same drain', async () => {
    await db.pendingActions.add({
      actionType: 'archiveConversation',
      status: 'processing',
      messageId: '',
      conversationId: 'c1',
      messageIds: ['m1'],
      retryCount: 0,
      createdAt: NOW - STALE_PROCESSING_MS - 60_000,
      lastAttempt: NOW - STALE_PROCESSING_MS - 60_000,
    })
    const api = makeStubApi()
    const recorder = makeSleepRecorder()
    const result = await drainPendingActions(db, api, { now: () => NOW, sleep: recorder.sleep })

    // Backoff window (2s) elapsed 10+ minutes ago: retry immediately.
    expect(recorder.sleeps).toEqual([])
    expect(result.completed).toBe(1)
    expect(api.batchCalls).toEqual([{ ids: ['m1'], removeLabelIds: ['INBOX'] }])
    expect((await db.pendingActions.toArray())[0]?.status).toBe('completed')
  })

  it('leaves fresh processing rows alone', async () => {
    await db.pendingActions.add({
      actionType: 'markRead',
      status: 'processing',
      messageId: '',
      conversationId: 'c1',
      messageIds: ['m1'],
      retryCount: 0,
      createdAt: NOW - 1000,
      lastAttempt: NOW - 1000,
    })
    const api = makeStubApi()
    const result = await drainPendingActions(db, api, { now: () => NOW })
    expect(result.processed).toBe(0)
    expect((await db.pendingActions.toArray())[0]?.status).toBe('processing')
  })

  it('executes an older failed retry before a newer pending action (strict createdAt order)', async () => {
    await db.messages.add(msgRow({ id: 'm1', conversationId: 'c1' }))
    // markUnread hit a retriable failure earlier…
    await db.pendingActions.add({
      actionType: 'markUnread',
      status: 'failed',
      messageId: 'm1',
      conversationId: 'c1',
      messageIds: [],
      retryCount: 1,
      createdAt: NOW - 10_000,
      lastAttempt: NOW - 10_000,
    })
    // …then the user opened the chat and markRead was enqueued (newest intent).
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageId: 'm1' }, NOW)

    const api = makeStubApi()
    await drainPendingActions(db, api, { now: () => NOW, sleep: () => Promise.resolve() })

    // The stale retry must run FIRST so the newest intent lands last remotely.
    expect(api.modifyCalls).toEqual([
      { id: 'm1', changes: { addLabelIds: ['UNREAD'] } },
      { id: 'm1', changes: { removeLabelIds: ['UNREAD'] } },
    ])
    const rows = await db.pendingActions.toArray()
    expect(rows.every((r) => r.status === 'completed')).toBe(true)
  })

  it('runs fresh actions first instead of sleeping through older rows still in backoff', async () => {
    // Three archives failed while offline; their 4s window has NOT elapsed.
    for (const [i, id] of ['m1', 'm2', 'm3'].entries()) {
      await db.pendingActions.add({
        actionType: 'archive',
        status: 'failed',
        messageId: id,
        conversationId: 'c1',
        messageIds: [],
        retryCount: 1,
        createdAt: NOW - 3000 + i,
        lastAttempt: NOW - 1000,
      })
    }
    // …then the user marked a different conversation read (newest intent).
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageId: 'm4' }, NOW)

    const api = makeStubApi()
    const sleptAfterCalls: number[] = []
    const recorder = makeSleepRecorder(() => sleptAfterCalls.push(api.modifyCalls.length))
    await drainPendingActions(db, api, { now: () => NOW, sleep: recorder.sleep })

    // The fresh action is not stuck behind three backoff windows…
    expect(api.modifyCalls.map((call) => call.id)).toEqual(['m4', 'm1', 'm2', 'm3'])
    expect(sleptAfterCalls).toEqual([1])
    // …and the three deferred rows share ONE remaining window (4s - 1s elapsed).
    expect(recorder.sleeps).toEqual([3000])
    const rows = await db.pendingActions.toArray()
    expect(rows.every((r) => r.status === 'completed')).toBe(true)
  })

  it('keeps a newer action ordered behind a deferred retry for the same message', async () => {
    await db.messages.add(msgRow({ id: 'm1', conversationId: 'c1' }))
    await db.pendingActions.add({
      actionType: 'markUnread',
      status: 'failed',
      messageId: 'm1',
      conversationId: 'c1',
      messageIds: [],
      retryCount: 1,
      createdAt: NOW - 10_000,
      // Window not elapsed: the row is deferred, and so is everything queued
      // behind it for m1 — otherwise markRead would land before its retry.
      lastAttempt: NOW,
    })
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageId: 'm1' }, NOW + 1)

    const api = makeStubApi()
    const recorder = makeSleepRecorder()
    await drainPendingActions(db, api, { now: () => NOW, sleep: recorder.sleep })

    expect(api.modifyCalls).toEqual([
      { id: 'm1', changes: { addLabelIds: ['UNREAD'] } },
      { id: 'm1', changes: { removeLabelIds: ['UNREAD'] } },
    ])
    expect(recorder.sleeps).toEqual([4000])
  })

  it('restores the row and stops on auth failures', async () => {
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m1'] }, NOW)
    await enqueue(db, { actionType: 'markRead', conversationId: 'c1', messageIds: ['m2'] }, NOW + 1)
    const api = makeStubApi()
    api.error = new AuthRequiredError('signed out', 'signed_out')

    const result = await drainPendingActions(db, api, { now: () => NOW })
    expect(result.processed).toBe(0)
    // Only the first row was attempted; both remain pending for later.
    expect(api.batchCalls).toHaveLength(1)
    const rows = await db.pendingActions.toArray()
    expect(rows.every((r) => r.status === 'pending' && r.retryCount === 0)).toBe(true)
  })
})
