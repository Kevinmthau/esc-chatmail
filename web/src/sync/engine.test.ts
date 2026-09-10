import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getSyncProgress } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { makeParticipantSetIdentity } from '@/identity/participantSet'
import { convoRow, msgRow } from '@/outbox/testSupport'
import { runSync, setSyncLockForTests, syncLockName } from './engine'
import {
  PARTICIPANT_SET_REPAIR_SIGNATURE_KEY,
  repairParticipantSetConversations,
} from './participantSetRepair'
import {
  makeTestDb,
  ME,
  NOW,
  seedAccount,
  StubGmailApi,
  testDeps,
  textMessage,
} from './testSupport'

const ALICE = 'alice@example.com'
const RELAY = 'relay@privaterelay.appleid.com'

function hashFor(...emails: string[]): string {
  return makeParticipantSetIdentity(new Set(emails), new Set([ME])).participantHash
}

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

  it('repairs with cached aliases before the first network request', async () => {
    await seedAccount(db)
    const source = convoRow({ id: 'pre-source', participantHash: hashFor(ALICE, RELAY) })
    const destination = convoRow({ id: 'pre-destination', participantHash: hashFor(ALICE) })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.add(msgRow({ id: 'pre-message', conversationId: source.id }))
    await db.msgParticipants.bulkAdd([
      { messageId: 'pre-message', email: ALICE, displayName: 'Alice', kind: 'from' },
      { messageId: 'pre-message', email: ME, displayName: '', kind: 'to' },
      { messageId: 'pre-message', email: RELAY, displayName: '', kind: 'cc' },
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
    ])

    const listHistory = api.listHistory.bind(api)
    api.listHistory = async (params) => {
      // This is inside the API call, so observing the new owner here proves
      // the repair ran under the lock before incremental network work began.
      expect((await db.messages.get('pre-message'))?.conversationId).toBe(destination.id)
      return listHistory(params)
    }
    api.historyFactory = () => ({ historyId: 'h2', history: [] })

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect(await db.conversations.get(source.id)).toBeUndefined()
    expect((await db.messages.get('pre-message'))?.conversationId).toBe(destination.id)
  })

  it('runs again after sync so Person enrichment can repair older messages', async () => {
    await seedAccount(db)
    const source = convoRow({ id: 'post-source', participantHash: hashFor(ALICE, RELAY) })
    await db.conversations.add(source)
    await db.messages.add(msgRow({ id: 'older-message', conversationId: source.id }))
    await db.msgParticipants.bulkAdd([
      { messageId: 'older-message', email: ALICE, displayName: 'Alice', kind: 'from' },
      { messageId: 'older-message', email: ME, displayName: '', kind: 'to' },
      { messageId: 'older-message', email: RELAY, displayName: '', kind: 'cc' },
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Relay' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
    ])

    api.messages.set(
      'enrichment-message',
      textMessage({
        id: 'enrichment-message',
        from: `Hide My Email <${RELAY}>`,
        to: [ME, `Alice <${ALICE}>`],
        internalDate: NOW - 1000,
      }),
    )
    api.historyPages = [
      {
        historyId: 'h2',
        history: [
          {
            id: '900',
            messagesAdded: [
              {
                message: {
                  id: 'enrichment-message',
                  threadId: 'thread_enrichment-message',
                  labelIds: ['INBOX', 'UNREAD'],
                },
              },
            ],
          },
        ],
      },
    ]

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect(await db.people.get(RELAY)).toMatchObject({ displayName: 'Hide My Email' })
    const older = await db.messages.get('older-message')
    const incoming = await db.messages.get('enrichment-message')
    expect(older?.conversationId).toBe(incoming?.conversationId)
    expect((await db.conversations.get(older?.conversationId ?? ''))?.participantHash).toBe(
      hashFor(ALICE),
    )
    expect(await db.conversations.get(source.id)).toBeUndefined()
  })

  it('routes a new unnamed relay from cached HME People without invalidating the repair marker', async () => {
    await seedAccount(db)
    await db.people.put({ email: RELAY, displayName: 'Hide My Email' })
    // Establish the marker with the same aliases and Person classification the
    // post-sync pass will see. The history cursor will advance independently.
    expect(await repairParticipantSetConversations(db, ME, NOW)).toMatchObject({
      performed: true,
      movedMessageCount: 0,
    })
    const markerBefore = await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)

    api.messages.set(
      'unnamed-relay-message',
      textMessage({
        id: 'unnamed-relay-message',
        from: RELAY,
        to: [ME, `Alice <${ALICE}>`],
        internalDate: NOW - 1000,
      }),
    )
    api.historyPages = [
      {
        historyId: 'h2',
        history: [
          {
            id: '901',
            messagesAdded: [
              {
                message: {
                  id: 'unnamed-relay-message',
                  threadId: 'thread_unnamed-relay-message',
                  labelIds: ['INBOX', 'UNREAD'],
                },
              },
            ],
          },
        ],
      },
    ]

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect(await db.people.get(RELAY)).toMatchObject({ displayName: 'Hide My Email' })
    const message = await db.messages.get('unnamed-relay-message')
    const conversation = await db.conversations.get(message?.conversationId ?? '')
    expect(conversation?.participantHash).toBe(hashFor(ALICE))
    expect(await db.conversations.count()).toBe(1)
    expect(
      await db.convoParticipants
        .where('conversationId')
        .equals(conversation?.id ?? '')
        .toArray(),
    ).toEqual([{ conversationId: conversation?.id, email: ALICE, role: 'normal' }])
    expect(
      (await db.msgParticipants.where('messageId').equals('unnamed-relay-message').toArray()).some(
        (row) => row.email === RELAY,
      ),
    ).toBe(false)
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toEqual(markerBefore)
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
