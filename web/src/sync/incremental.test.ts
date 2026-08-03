import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getLabelReconciledAt, getLastSuccessfulSyncAt, setLastSuccessfulSyncAt } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { HistoryIdExpiredError } from '@/gmail/historyError'
import type { HistoryListResponse } from '@/gmail/types'
import { calculateParticipantHash } from '@/identity/participantSet'
import { makeRollup } from '@/rollup/rollup'
import { MAX_ABANDONED_RETRIES, persistentFailedIds } from './abandoned'
import {
  applyHistoryLabelOps,
  MAX_HISTORY_PAGES,
  recoveryQueryStartMs,
  runIncrementalSync,
  type IncrementalSyncResult,
} from './incremental'
import { applyPersist, preparePersist, type PersistContext } from './persist'
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
import { UNPROCESSABLE_REASON } from './unprocessable'

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

/** Seeds one persisted alice conversation with messages m1 (read) and m2 (unread). */
async function seedAliceConversation(): Promise<void> {
  const plans = await preparePersist(
    [
      textMessage({
        id: 'm1',
        from: 'alice@example.com',
        labelIds: ['INBOX'],
        internalDate: NOW - 5000,
      }),
      textMessage({
        id: 'm2',
        from: 'alice@example.com',
        labelIds: ['INBOX', 'UNREAD'],
        internalDate: NOW - 4000,
        body: 'Second message',
      }),
    ],
    ctx,
  )
  await applyPersist(db, plans, NOW)
}

async function aliceConversation() {
  const hash = calculateParticipantHash(['alice@example.com'])
  const conversation = (await db.conversations.toArray()).find((c) => c.participantHash === hash)
  expect(conversation).toBeDefined()
  return conversation!
}

function historyPage(partial: Partial<HistoryListResponse>): HistoryListResponse {
  return { historyId: 'h2', ...partial }
}

describe('runIncrementalSync', () => {
  it('falls back to initial sync when no historyId exists', async () => {
    await seedAccount(db, { historyId: '' })
    api.listPages = [{}]
    const result = await runIncrementalSync(testDeps(db, api))
    expect(result.mode).toBe('initial')
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
  })

  it('persists messagesAdded as a new bubble with a live unread count and advances the cursor', async () => {
    await seedAccount(db)
    const incoming = textMessage({
      id: 'm10',
      from: 'alice@example.com',
      body: 'New arrival',
      internalDate: NOW - 1000,
    })
    api.messages.set('m10', incoming)
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '900',
            messagesAdded: [
              { message: { id: 'm10', threadId: 't10', labelIds: ['INBOX', 'UNREAD'] } },
            ],
          },
        ],
      }),
    ]

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.mode).toBe('incremental')
    expect(result.newMessageCount).toBe(1)
    expect(result.historyIdAdvanced).toBe(true)

    expect(await db.messages.get('m10')).toBeDefined()
    const conversation = await aliceConversation()
    expect(conversation.inboxUnreadCount).toBe(1)
    expect(conversation.snippet).toBe('New arrival')
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW)
  })

  it('holds the cursor for a transient large-body failure and later persists the full body', async () => {
    await seedAccount(db)
    api.messages.set('large', {
      id: 'large',
      threadId: 't-large',
      internalDate: String(NOW - 1000),
      labelIds: ['INBOX', 'UNREAD'],
      payload: {
        partId: '',
        mimeType: 'text/html',
        headers: [
          { name: 'From', value: 'alice@example.com' },
          { name: 'To', value: ME },
          { name: 'Subject', value: 'Large body' },
        ],
        body: { attachmentId: 'body-large', size: 90_000 },
      },
    })
    api.historyFactory = () =>
      historyPage({
        history: [
          {
            id: '901',
            messagesAdded: [
              { message: { id: 'large', threadId: 't-large', labelIds: ['INBOX', 'UNREAD'] } },
            ],
          },
        ],
      })
    api.getAttachmentErrors.set(
      'large:body-large',
      () => new Error('transient attachment transport failure'),
    )

    const failed = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(failed.historyIdAdvanced).toBe(false)
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    expect(await db.messages.get('large')).toBeUndefined()

    api.getAttachmentErrors.delete('large:body-large')
    api.attachmentResponses.set('large:body-large', {
      size: 20,
      data: b64url('<p>Complete body</p>'),
    })
    const recovered = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult

    expect(recovered.historyIdAdvanced).toBe(true)
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect((await db.bodies.get('large'))?.html).toBe('<p>Complete body</p>')
    expect((await db.messages.get('large'))?.hasAttachments).toBe(0)
  })

  it('holds the cursor when inline bytes exceed quota and retries the same message', async () => {
    await seedAccount(db)
    const incoming = textMessage({ id: 'inline', from: 'alice@example.com' })
    incoming.payload = {
      partId: '',
      mimeType: 'multipart/related',
      headers: incoming.payload!.headers!,
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
    api.messages.set('inline', incoming)
    api.historyFactory = () =>
      historyPage({
        history: [
          {
            id: '902',
            messagesAdded: [
              { message: { id: 'inline', threadId: 't-inline', labelIds: ['INBOX'] } },
            ],
          },
        ],
      })
    const put = vi
      .spyOn(db.blobs, 'put')
      .mockRejectedValueOnce(new DOMException('quota', 'QuotaExceededError'))

    const failed = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(failed.historyIdAdvanced).toBe(false)
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    expect((await db.messages.get('inline'))?.hasAttachments).toBe(0)
    expect(await db.attachments.where('messageId').equals('inline').count()).toBe(0)

    const recovered = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    const attachment = (await db.attachments.where('messageId').equals('inline').first())!
    expect(recovered.historyIdAdvanced).toBe(true)
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(attachment.state).toBe('downloaded')
    expect(await db.blobs.get(attachment.id)).toBeDefined()
    expect((await db.messages.get('inline'))?.hasAttachments).toBe(1)

    put.mockRestore()
  })

  it('skips messagesAdded already labeled SPAM/DRAFT/TRASH', async () => {
    await seedAccount(db)
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '900',
            messagesAdded: [
              { message: { id: 'spam1', threadId: 't', labelIds: ['SPAM'] } },
              { message: { id: 'draft1', threadId: 't', labelIds: ['DRAFT'] } },
            ],
          },
        ],
      }),
    ]
    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.newMessageCount).toBe(0)
    expect(api.getMessageCalls.filter((c) => c.startsWith('spam1'))).toHaveLength(0)
    expect(result.historyIdAdvanced).toBe(true)
  })

  it('decrements the unread count when UNREAD is removed', async () => {
    await seedAccount(db)
    await seedAliceConversation()
    expect((await aliceConversation()).inboxUnreadCount).toBe(1)

    api.historyPages = [
      historyPage({
        history: [
          {
            id: '901',
            labelsRemoved: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['UNREAD'] }],
          },
        ],
      }),
    ]
    await runIncrementalSync(testDeps(db, api))

    expect((await db.messages.get('m2'))?.isUnread).toBe(0)
    expect((await aliceConversation()).inboxUnreadCount).toBe(0)
  })

  it('deletes locally on messagesDeleted and rolls the conversation up', async () => {
    await seedAccount(db)
    await seedAliceConversation()
    const before = await aliceConversation()
    expect(before.snippet).toBe('Second message')

    api.historyPages = [
      historyPage({
        history: [{ id: '902', messagesDeleted: [{ message: { id: 'm2', threadId: 't' } }] }],
      }),
    ]
    await runIncrementalSync(testDeps(db, api))

    expect(await db.messages.get('m2')).toBeUndefined()
    const after = await aliceConversation()
    expect(after.snippet).toBe('Body of m1')
    expect(after.lastMessageDate).toBe(NOW - 5000)
    expect(after.inboxUnreadCount).toBe(0)
  })

  it('keeps the ORIGINAL cursor when history is truncated at the page cap', async () => {
    await seedAccount(db)
    api.historyFactory = (params) => ({
      history: [],
      historyId: 'h999',
      nextPageToken: 'more',
      ...(params.pageToken === undefined ? {} : {}),
    })

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.wasTruncated).toBe(true)
    expect(result.historyIdAdvanced).toBe(false)
    expect(api.historyCalls).toHaveLength(MAX_HISTORY_PAGES)
    expect((await db.accounts.get(ME))?.historyId).toBe('h1')
    // A truncated run is not a "successful sync" for the reconcile window.
    expect(await getLastSuccessfulSyncAt(db)).toBe(0)
  })

  it('ignores server label changes inside the 30-minute localModifiedAt window, applies stale ones', async () => {
    await seedAccount(db)
    await seedAliceConversation()

    // Local mark-read 5 minutes ago (m2 was unread server-side).
    await db.messages.update('m2', {
      isUnread: 0,
      labelIds: ['INBOX'],
      localModifiedAt: NOW - 5 * 60 * 1000,
    })
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '903',
            labelsAdded: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['UNREAD'] }],
          },
        ],
      }),
    ]
    await runIncrementalSync(testDeps(db, api))
    expect((await db.messages.get('m2'))?.isUnread).toBe(0)

    // Same change with a 40-minute-old local mutation: server wins.
    await db.messages.update('m2', { localModifiedAt: NOW - 40 * 60 * 1000 })
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '904',
            labelsAdded: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['UNREAD'] }],
          },
        ],
      }),
    ]
    await runIncrementalSync(testDeps(db, api))
    expect((await db.messages.get('m2'))?.isUnread).toBe(1)
  })

  it('deletes the local copy when history adds an excluded label', async () => {
    await seedAccount(db)
    await seedAliceConversation()
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '905',
            labelsAdded: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['TRASH'] }],
          },
        ],
      }),
    ]
    await runIncrementalSync(testDeps(db, api))
    expect(await db.messages.get('m2')).toBeUndefined()
    expect((await aliceConversation()).snippet).toBe('Body of m1')
  })

  it('recovers from an expired historyId via list-sync and stores the fresh cursor', async () => {
    await seedAccount(db, { historyId: 'h-expired' })
    api.historyError = new HistoryIdExpiredError('expired')
    api.profile = { emailAddress: ME, historyId: 'h-fresh' }
    api.messages.set(
      'r1',
      textMessage({ id: 'r1', from: 'alice@example.com', internalDate: NOW - 1000 }),
    )
    api.listPages = [{ messages: [{ id: 'r1', threadId: 'tr1' }] }]

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.mode).toBe('recovery')
    expect(result.newMessageCount).toBe(1)
    expect(result.historyIdAdvanced).toBe(true)
    expect(await db.messages.get('r1')).toBeDefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h-fresh')
  })

  it('captures the recovery history cursor BEFORE listing so racing mail is re-covered', async () => {
    await seedAccount(db, { historyId: 'h-expired' })
    api.historyError = new HistoryIdExpiredError('expired')
    api.profile = { emailAddress: ME, historyId: 'h-before-list' }
    api.listPages = [{}]
    // Simulate mail arriving while the recovery pages are consumed: by the
    // time the list runs, the mailbox's live historyId has advanced.
    const originalList = api.listMessages.bind(api)
    api.listMessages = (params) => {
      api.profile = { emailAddress: ME, historyId: 'h-after-list' }
      return originalList(params)
    }

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
    expect(result.mode).toBe('recovery')
    // Storing the post-list cursor would skip messages that raced the
    // listing; the pre-list capture lets the next incremental re-cover them.
    expect((await db.accounts.get(ME))?.historyId).toBe('h-before-list')
  })

  it('tombstones unprocessable fetched messages without stalling the cursor or re-fetching them', async () => {
    await seedAccount(db)
    await setLastSuccessfulSyncAt(db, NOW - 60_000)
    // Fetches fine but the parser rejects it (no payload/headers).
    api.messages.set('bad', { id: 'bad', threadId: 't', labelIds: ['INBOX'] })
    api.historyPages = [
      historyPage({
        history: [
          {
            id: '910',
            messagesAdded: [{ message: { id: 'bad', threadId: 't', labelIds: ['INBOX'] } }],
          },
        ],
      }),
    ]
    // The reconciliation list keeps offering the id, because it is absent
    // locally and always will be.
    api.listPages = null
    api.listMessages = () => Promise.resolve({ messages: [{ id: 'bad', threadId: 't' }] })

    const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult

    expect(await db.messages.get('bad')).toBeUndefined()
    // Recorded as a terminal tombstone, not silently skipped...
    const tombstone = await db.abandonedMessages.get('bad')
    expect(tombstone?.reason).toBe(UNPROCESSABLE_REASON)
    expect(tombstone?.retryCount).toBe(MAX_ABANDONED_RETRIES)
    // ...and NOT as a transient failure: reparsing the identical response
    // yields the identical null, so counting it would keep hadFailures true on
    // every sync forever — freezing lastSuccessfulSyncAt, holding the cursor
    // back two syncs out of three, and churning the abandoned registry.
    expect(await persistentFailedIds(db)).toEqual([])
    expect(result.historyIdAdvanced).toBe(true)
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW)

    // A second sync must not re-fetch it: the registry owns it now.
    api.historyPages = [historyPage({})]
    const callsBefore = api.getMessageCalls.length
    await runIncrementalSync(testDeps(db, api))
    expect(api.getMessageCalls.slice(callsBefore)).not.toContain('bad:full')
  })

  it('records the label-reconcile TTL only after a completed pass', async () => {
    await seedAccount(db)
    api.historyPages = [historyPage({})]
    await runIncrementalSync(testDeps(db, api))
    expect(await getLabelReconciledAt(db)).toBe(NOW)
  })
})

describe('recoveryQueryStartMs', () => {
  it('uses max(lastSync − 10min, install − 5min)', () => {
    const install = NOW - 1000_000
    expect(recoveryQueryStartMs(NOW - 60_000, install, NOW)).toBe(NOW - 60_000 - 600_000)
    expect(recoveryQueryStartMs(NOW - 900_000, install, NOW)).toBe(install - 300_000)
    expect(recoveryQueryStartMs(0, install, NOW)).toBe(install - 300_000)
  })
})

describe('applyHistoryLabelOps ordering', () => {
  it('applies deletions before label changes within a record set', async () => {
    await seedAliceConversation()
    const touched = await applyHistoryLabelOps(
      db,
      [
        {
          id: '1',
          messagesDeleted: [{ message: { id: 'm1', threadId: 't' } }],
          labelsRemoved: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['UNREAD'] }],
        },
      ],
      NOW,
    )
    expect(await db.messages.get('m1')).toBeUndefined()
    expect((await db.messages.get('m2'))?.isUnread).toBe(0)
    expect(touched.size).toBe(1)
  })
})

// ---------------------------------------------------------------------------
// Crash matrix: kill between each incremental phase, rerun, assert invariants.
// ---------------------------------------------------------------------------

describe('incremental crash matrix', () => {
  const phases = [
    'incremental:afterHistory',
    'incremental:afterFetch',
    'incremental:afterLabelOps',
    'incremental:afterReconcile',
  ] as const

  for (const crashPhase of phases) {
    it(`survives a crash at ${crashPhase}`, async () => {
      await seedAccount(db)
      await seedAliceConversation()
      api.messages.set(
        'm10',
        textMessage({
          id: 'm10',
          from: 'alice@example.com',
          body: 'Newest',
          internalDate: NOW - 1000,
        }),
      )
      api.historyFactory = () => ({
        historyId: 'h2',
        history: [
          {
            id: '900',
            messagesAdded: [
              { message: { id: 'm10', threadId: 't10', labelIds: ['INBOX', 'UNREAD'] } },
            ],
            labelsRemoved: [{ message: { id: 'm2', threadId: 't' }, labelIds: ['UNREAD'] }],
          },
        ],
      })

      const crashingDeps = testDeps(db, api, {
        hooks: {
          onPhase: (phase) => {
            if (phase === crashPhase) throw new Error(`crash at ${phase}`)
          },
        },
      })
      await expect(runIncrementalSync(crashingDeps)).rejects.toThrow(`crash at ${crashPhase}`)

      // The cursor never advanced past an incomplete run.
      expect((await db.accounts.get(ME))?.historyId).toBe('h1')

      // Restart with the same history feed: the rerun converges.
      const result = (await runIncrementalSync(testDeps(db, api))) as IncrementalSyncResult
      expect(result.historyIdAdvanced).toBe(true)

      // Invariants: no duplicate rows, correct read states, cursor advanced.
      expect(await db.messages.count()).toBe(3)
      expect((await db.messages.get('m2'))?.isUnread).toBe(0)
      expect((await db.messages.get('m10'))?.isUnread).toBe(1)
      expect(await db.conversations.count()).toBe(1)

      const conversation = await aliceConversation()
      // The stored counts must equal a from-scratch rollup (no drift).
      const rollup = makeRollup(await db.messages.toArray())
      expect(conversation.inboxUnreadCount).toBe(rollup.inboxUnreadCount)
      expect(conversation.inboxUnreadCount).toBe(1)
      expect(conversation.snippet).toBe('Newest')
      expect(conversation.lastMessageDate).toBe(NOW - 1000)
      expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    })
  }
})
