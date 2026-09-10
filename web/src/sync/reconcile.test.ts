import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getLastSuccessfulSyncAt, setLabelReconciledAt, setLastSuccessfulSyncAt } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { GmailApiError } from '@/gmail/errors'
import { persistentFailedIds } from './abandoned'
import { applyPersist, preparePersist, type PersistContext } from './persist'
import {
  findMissedMessageIds,
  LABEL_RECONCILE_TTL_MS,
  missedMessageStartMs,
  reconcileLabels,
} from './reconcile'
import { runIncrementalSync } from './incremental'
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
  hideMyEmailAddresses: new Set(),
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

async function seedMessage(
  id: string,
  labelIds: string[],
  overrides: { localModifiedAt?: number } = {},
): Promise<void> {
  const plans = await preparePersist(
    [textMessage({ id, from: 'alice@example.com', labelIds, internalDate: NOW - 5000 })],
    ctx,
  )
  await applyPersist(db, plans, NOW)
  if (overrides.localModifiedAt !== undefined) {
    await db.messages.update(id, { localModifiedAt: overrides.localModifiedAt })
  }
}

describe('missedMessageStartMs', () => {
  const install = NOW - 10 * 24 * 60 * 60 * 1000
  it('is lastSync − 5min, capped at now − 24h, never before install − 5min', () => {
    expect(missedMessageStartMs(NOW - 60_000, install, NOW)).toBe(NOW - 60_000 - 300_000)
    // Very old lastSync: capped at 24h.
    expect(missedMessageStartMs(NOW - 48 * 3600_000, install, NOW)).toBe(NOW - 24 * 3600_000)
    // No lastSync: 1h fallback.
    expect(missedMessageStartMs(0, install, NOW)).toBe(NOW - 3600_000)
    // Fresh install dominates.
    expect(missedMessageStartMs(0, NOW - 60_000, NOW)).toBe(NOW - 60_000 - 300_000)
  })
})

describe('findMissedMessageIds', () => {
  it('returns only ids missing locally', async () => {
    await setLastSuccessfulSyncAt(db, NOW - 60_000)
    await seedMessage('have', ['INBOX'])
    api.listPages = [
      {
        messages: [
          { id: 'have', threadId: 't' },
          { id: 'missing', threadId: 't' },
        ],
      },
    ]
    const missing = await findMissedMessageIds(db, api, NOW - 1000_000, NOW)
    expect(missing).toEqual(['missing'])
    expect(api.listCalls[0]?.q).toContain('-label:spam')
    expect(api.listCalls[0]?.maxResults).toBe(500)
  })
})

describe('reconcileLabels', () => {
  it('repairs INBOX/UNREAD drift and reports touched conversations', async () => {
    await seedMessage('m1', ['INBOX', 'UNREAD'])
    // Remote truth: archived + read.
    api.messages.set('m1', textMessage({ id: 'm1', from: 'alice@example.com', labelIds: [] }))
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]

    const result = await reconcileLabels(db, api, NOW)
    expect(result).not.toBeNull()
    expect(result!.completed).toBe(true)
    expect(result!.repairedCount).toBe(1)
    const row = (await db.messages.get('m1'))!
    expect(row.labelIds).not.toContain('INBOX')
    expect(row.isUnread).toBe(0)
    expect(result!.touchedConversationIds.size).toBe(1)
    // Fast-path indicators already applied.
    const conversation = (await db.conversations.toArray())[0]!
    expect(conversation.inboxUnreadCount).toBe(0)
    expect(conversation.hasInbox).toBe(0)
  })

  it('is TTL-gated at 30 minutes', async () => {
    await setLabelReconciledAt(db, NOW - LABEL_RECONCILE_TTL_MS + 1000)
    expect(await reconcileLabels(db, api, NOW)).toBeNull()
    await setLabelReconciledAt(db, NOW - LABEL_RECONCILE_TTL_MS - 1000)
    expect(await reconcileLabels(db, api, NOW)).not.toBeNull()
  })

  it('never re-adds INBOX over a local SPAM label', async () => {
    await seedMessage('m1', ['INBOX'])
    await db.messages.update('m1', { labelIds: ['SPAM'] })
    api.messages.set(
      'm1',
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX'] }),
    )
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]

    const result = await reconcileLabels(db, api, NOW)
    expect(result!.repairedCount).toBe(0)
    expect((await db.messages.get('m1'))!.labelIds).toEqual(['SPAM'])
  })

  it('never touches messages with a fresh localModifiedAt', async () => {
    await seedMessage('m1', ['INBOX', 'UNREAD'], { localModifiedAt: NOW - 5 * 60 * 1000 })
    api.messages.set('m1', textMessage({ id: 'm1', from: 'alice@example.com', labelIds: [] }))
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]

    const result = await reconcileLabels(db, api, NOW)
    expect(result!.repairedCount).toBe(0)
    expect((await db.messages.get('m1'))!.labelIds).toContain('INBOX')
  })

  it('skips messages targeted by an outbox action, so a drain completing mid-pass is not reverted', async () => {
    await seedMessage('m1', ['INBOX', 'UNREAD'])
    // A drain completed a local mark-read between the remote fetch and the
    // repair tx: the guard is cleared (localModifiedAt 0) and the action row
    // is 'completed' (swept only at the start of the next drain).
    await db.messages.update('m1', { isUnread: 0, labelIds: ['INBOX'], localModifiedAt: 0 })
    await db.pendingActions.add({
      actionType: 'markRead',
      status: 'completed',
      messageId: 'm1',
      conversationId: 'c-any',
      messageIds: [],
      retryCount: 0,
      createdAt: NOW - 1000,
      lastAttempt: NOW - 500,
    })
    // Pre-fetched remote state is stale: still UNREAD.
    api.messages.set(
      'm1',
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] }),
    )
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]

    const result = await reconcileLabels(db, api, NOW)
    expect(result!.repairedCount).toBe(0)
    expect(result!.skippedCount).toBe(1)
    expect((await db.messages.get('m1'))!.isUnread).toBe(0)
  })

  it('still repairs drift behind a STALE completed action row', async () => {
    // 'completed' rows are only deleted at the START of the next drain, and a
    // drain only happens on a local mutation or an 'online' event. If the user
    // opens a thread (mark-read) and then just leaves the tab open, that row
    // sits there forever — and blocking on it disables the very repair
    // reconciliation exists for, silently, on every 30-minute pass.
    await seedMessage('m1', ['INBOX'])
    await db.messages.update('m1', { isUnread: 0, localModifiedAt: 0 })
    await db.pendingActions.add({
      actionType: 'markRead',
      status: 'completed',
      messageId: 'm1',
      conversationId: 'c-any',
      messageIds: [],
      retryCount: 0,
      createdAt: NOW - 40 * 60 * 1000,
      lastAttempt: NOW - 35 * 60 * 1000,
    })
    // The user marked the thread unread on another device and the history
    // record was dropped: only reconciliation can find this.
    api.messages.set(
      'm1',
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] }),
    )
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]

    const result = await reconcileLabels(db, api, NOW)
    expect(result!.repairedCount).toBe(1)
    expect((await db.messages.get('m1'))!.isUnread).toBe(1)
  })

  it('marks the pass incomplete on metadata fetch failures (TTL not recorded)', async () => {
    await seedMessage('m1', ['INBOX'])
    api.getMessageErrors.set('m1', () => new GmailApiError(500, 'backendError', 'boom'))
    api.listPages = [{ messages: [{ id: 'm1', threadId: 't' }] }]
    const result = await reconcileLabels(db, api, NOW)
    expect(result!.completed).toBe(false)
  })

  it('treats a metadata 404 as deleted (still completed)', async () => {
    api.listPages = [{ messages: [{ id: 'ghost', threadId: 't' }] }]
    const result = await reconcileLabels(db, api, NOW)
    expect(result!.completed).toBe(true)
  })
})

describe('reconciliation inside incremental sync', () => {
  it('fetches and persists a missed message found by the list check', async () => {
    await seedAccount(db)
    await setLastSuccessfulSyncAt(db, NOW - 60_000)
    api.historyFactory = () => ({ historyId: 'h2', history: [] })
    api.messages.set(
      'missed',
      textMessage({ id: 'missed', from: 'bob@example.com', internalDate: NOW - 2000 }),
    )
    // First list call = missed-message check; second = label reconciliation.
    api.listPages = [{ messages: [{ id: 'missed', threadId: 't' }] }, {}]

    await runIncrementalSync(testDeps(db, api))
    expect(await db.messages.get('missed')).toBeDefined()
    const conversation = (await db.conversations.toArray()).find((c) =>
      c.displayName.includes('bob'),
    )
    expect(conversation?.inboxUnreadCount).toBe(1)
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW)
  })

  it('records missed-message fetch failures instead of silently dropping them', async () => {
    await seedAccount(db)
    await setLastSuccessfulSyncAt(db, NOW - 60_000)
    api.historyFactory = () => ({ historyId: 'h2', history: [] })
    api.listPages = [{ messages: [{ id: 'missed', threadId: 't' }] }, {}]
    // Every fetch attempt for the missed id fails (e.g. transient 503s).
    api.getMessageErrors.set('missed', () => new GmailApiError(503, 'backendError', 'boom'))

    await runIncrementalSync(testDeps(db, api))

    // The id enters the consecutive-failure pipeline (→ abandoned registry
    // after 3 strikes) and the sync must NOT stamp clean success — otherwise
    // the shrinking lookback window would move past the message forever.
    expect(await persistentFailedIds(db)).toContain('missed')
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW - 60_000)
  })
})
