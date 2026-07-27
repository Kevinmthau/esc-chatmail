// Initial-sync end-to-end tests over MSW + the real Gmail endpoints module
// (transport → retry engine → orchestrator), against fake-indexeddb.

import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { getLastSuccessfulSyncAt, getSyncProgress } from '@/db/kv'
import type { ChatmailDB } from '@/db/schema'
import { GMAIL_API_BASE, type TokenBroker } from '@/gmail/gmailFetch'
import type { GmailMessage } from '@/gmail/types'
import { calculateParticipantHash } from '@/identity/participantSet'
import {
  consecutiveFailureCount,
  MAX_ABANDONED_RETRIES,
  MAX_CONSECUTIVE_SYNC_FAILURES,
  persistentFailedIds,
  retryableAbandonedIds,
} from './abandoned'
import { makeGmailSyncApi, type SyncDeps } from './deps'
import { initialSyncQuery, runInitialSync } from './initial'
import { makeTestDb, ME, NOW, textMessage } from './testSupport'
import { UNPROCESSABLE_REASON } from './unprocessable'

const server = setupServer()

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

const broker: TokenBroker = {
  getToken: () => Promise.resolve('tok'),
  refreshAfter: () => Promise.resolve('tok'),
}

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  await db.delete()
})

function deps(overrides: Partial<SyncDeps> = {}): SyncDeps {
  return {
    db,
    api: makeGmailSyncApi(broker),
    accountEmail: ME,
    now: () => NOW,
    sleep: () => Promise.resolve(),
    random: () => 0,
    ...overrides,
  }
}

interface FixtureOptions {
  failIds?: Set<string>
  /** Served as a 200 with no payload — a successful fetch the parser rejects. */
  unparseableIds?: Set<string>
}

/** Standard 2-page fixture: 5 messages, alice appearing on both pages. */
function installFixture(options: FixtureOptions = {}): Map<string, GmailMessage> {
  const failIds = options.failIds ?? new Set<string>()
  const unparseableIds = options.unparseableIds ?? new Set<string>()
  const messages = new Map<string, GmailMessage>(
    (
      [
        textMessage({
          id: 'm1',
          threadId: 'tA',
          from: 'alice@example.com',
          internalDate: NOW - 5000,
        }),
        textMessage({
          id: 'm2',
          threadId: 'tB',
          from: 'alice@example.com',
          internalDate: NOW - 4000,
          body: 'Second from alice',
        }),
        textMessage({
          id: 'm3',
          threadId: 'tC',
          from: 'bob@example.com',
          internalDate: NOW - 3000,
        }),
        textMessage({
          id: 'm4',
          threadId: 'tD',
          from: 'alice@example.com',
          internalDate: NOW - 2000,
          body: 'Third from alice',
        }),
        textMessage({
          id: 'm5',
          threadId: 'tE',
          from: 'carol@example.com',
          to: [ME, 'bob@example.com'],
          internalDate: NOW - 1000,
        }),
      ] as GmailMessage[]
    ).map((m) => [m.id, m]),
  )

  server.use(
    http.get(`${GMAIL_API_BASE}/users/me/profile`, () =>
      HttpResponse.json({ emailAddress: ME, historyId: 'hist-start' }),
    ),
    http.get(`${GMAIL_API_BASE}/users/me/settings/sendAs`, () =>
      HttpResponse.json({
        sendAs: [
          { sendAsEmail: ME, isPrimary: true, isDefault: true, verificationStatus: 'accepted' },
        ],
      }),
    ),
    http.get(`${GMAIL_API_BASE}/users/me/labels`, () =>
      HttpResponse.json({
        labels: [
          { id: 'INBOX', name: 'INBOX' },
          { id: 'UNREAD', name: 'UNREAD' },
          { id: 'SENT', name: 'SENT' },
        ],
      }),
    ),
    http.get(`${GMAIL_API_BASE}/users/me/messages`, ({ request }) => {
      const url = new URL(request.url)
      expect(url.searchParams.get('q')).toContain('-label:spam -label:drafts -label:trash')
      expect(url.searchParams.get('maxResults')).toBe('500')
      if (url.searchParams.get('pageToken') === 'page2') {
        return HttpResponse.json({
          messages: [
            { id: 'm4', threadId: 'tD' },
            { id: 'm5', threadId: 'tE' },
          ],
        })
      }
      return HttpResponse.json({
        messages: [
          { id: 'm1', threadId: 'tA' },
          { id: 'm2', threadId: 'tB' },
          { id: 'm3', threadId: 'tC' },
        ],
        nextPageToken: 'page2',
        resultSizeEstimate: 5,
      })
    }),
    http.get(`${GMAIL_API_BASE}/users/me/messages/:id`, ({ params }) => {
      const id = params['id'] as string
      if (failIds.has(id)) {
        return HttpResponse.json({ error: { code: 500, message: 'boom' } }, { status: 500 })
      }
      if (unparseableIds.has(id)) {
        return HttpResponse.json({ id, threadId: `t_${id}`, labelIds: ['INBOX'] })
      }
      const message = messages.get(id)
      if (message === undefined) {
        return HttpResponse.json({ error: { code: 404, message: 'not found' } }, { status: 404 })
      }
      return HttpResponse.json(message)
    }),
  )

  return messages
}

describe('runInitialSync', () => {
  it('syncs two pages end-to-end: conversations keyed by participant set, historyId at the end', async () => {
    installFixture()
    const result = await runInitialSync(deps())

    expect(result.historyIdAdvanced).toBe(true)
    expect(result.messagesProcessed).toBe(5)
    expect(await db.messages.count()).toBe(5)

    // alice's three messages across three Gmail threads share ONE conversation.
    const conversations = await db.conversations.toArray()
    expect(conversations).toHaveLength(3)
    const aliceHash = calculateParticipantHash(['alice@example.com'])
    const alice = conversations.find((c) => c.participantHash === aliceHash)
    expect(alice).toBeDefined()
    const aliceMessages = await db.messages.filter((m) => m.conversationId === alice!.id).toArray()
    expect(aliceMessages.map((m) => m.id).sort()).toEqual(['m1', 'm2', 'm4'])

    // Rollup-owned fields are live for the list.
    expect(alice!.inboxUnreadCount).toBe(3)
    expect(alice!.snippet).toBe('Third from alice')
    expect(alice!.lastMessageDate).toBe(NOW - 2000)

    // Group chat keyed by carol+bob.
    const groupHash = calculateParticipantHash(['bob@example.com', 'carol@example.com'])
    expect(conversations.some((c) => c.participantHash === groupHash && c.type === 'group')).toBe(
      true,
    )

    // Cursor written at the very end, from the START-of-sync profile.
    expect((await db.accounts.get(ME))?.historyId).toBe('hist-start')
    expect((await db.accounts.get(ME))?.aliases).toContain(ME)
    expect(await db.labels.count()).toBe(3)
    expect(await getLastSuccessfulSyncAt(db)).toBe(NOW)
    expect((await getSyncProgress(db)).phase).toBe('idle')
  })

  it('does NOT advance historyId when a message keeps failing; the failure is recorded', async () => {
    installFixture({ failIds: new Set(['m2']) })
    const result = await runInitialSync(deps())

    expect(result.historyIdAdvanced).toBe(false)
    expect(result.failedIds).toEqual(['m2'])
    expect((await db.accounts.get(ME))?.historyId).toBe('')
    // The other messages still persisted.
    expect(await db.messages.count()).toBe(4)
    expect(await consecutiveFailureCount(db)).toBe(1)
    expect(await persistentFailedIds(db)).toEqual(['m2'])

    // Next sync retries and completes (server recovered).
    server.resetHandlers()
    installFixture()
    const retry = await runInitialSync(deps())
    expect(retry.historyIdAdvanced).toBe(true)
    expect(await db.messages.count()).toBe(5)
    expect((await db.accounts.get(ME))?.historyId).toBe('hist-start')
  })

  it('abandons ids stuck across MAX_CONSECUTIVE_SYNC_FAILURES backfills and lets the cursor advance', async () => {
    // Without an escape hatch, one permanently-failing message pins historyId
    // at '' forever: runIncrementalSync routes straight back into initial sync
    // on every tick, and each pass re-lists and re-fetches the whole
    // install-to-now window (which only widens). That is a self-sustaining
    // quota burn from which the account never reaches history sync.
    for (let pass = 1; pass < MAX_CONSECUTIVE_SYNC_FAILURES; pass += 1) {
      server.resetHandlers()
      installFixture({ failIds: new Set(['m2']) })
      const result = await runInitialSync(deps())
      expect(result.historyIdAdvanced).toBe(false)
      expect((await db.accounts.get(ME))?.historyId).toBe('')
      expect(await consecutiveFailureCount(db)).toBe(pass)
    }

    server.resetHandlers()
    installFixture({ failIds: new Set(['m2']) })
    const final = await runInitialSync(deps())

    expect(final.historyIdAdvanced).toBe(true)
    expect((await db.accounts.get(ME))?.historyId).toBe('hist-start')
    // The stuck id is now owned by the abandoned drain, not the cursor.
    expect((await db.abandonedMessages.get('m2'))?.reason).toBe('Max sync failures reached')
    expect(await consecutiveFailureCount(db)).toBe(0)
    // A failed run must NOT masquerade as a successful sync.
    expect(await getLastSuccessfulSyncAt(db)).toBe(0)
  })

  it('records unparseable messages in the abandoned registry instead of dropping them silently', async () => {
    // applyPersist skips 'unprocessable' plans. listSyncPages is shared with
    // history recovery, where the lookback window closes within minutes — a
    // dropped id there is gone for good while the run reports clean success.
    installFixture({ unparseableIds: new Set(['m3']) })
    const result = await runInitialSync(deps())

    expect(await db.messages.get('m3')).toBeUndefined()
    const tombstone = await db.abandonedMessages.get('m3')
    expect(tombstone?.reason).toBe(UNPROCESSABLE_REASON)
    // Terminal: reparsing the identical response yields the identical null, so
    // the drain must never spend fetch attempts on it.
    expect(tombstone?.retryCount).toBe(MAX_ABANDONED_RETRIES)
    expect(await retryableAbandonedIds(db)).not.toContain('m3')
    // A permanently unparseable message must not hold the cursor hostage.
    expect(result.historyIdAdvanced).toBe(true)
    expect(await persistentFailedIds(db)).toEqual([])
  })

  it('leaves a consistent store when killed after page 1 (no historyId, page-1 rollups intact)', async () => {
    installFixture()
    const crashingDeps = deps({
      hooks: {
        onPhase: (phase) => {
          if (phase === 'initial:page:1') throw new Error('simulated crash')
        },
      },
    })

    await expect(runInitialSync(crashingDeps)).rejects.toThrow('simulated crash')

    // Page 1 fully present and presentable; nothing from page 2; no cursor.
    expect((await db.messages.toArray()).map((m) => m.id).sort()).toEqual(['m1', 'm2', 'm3'])
    expect((await db.accounts.get(ME))?.historyId).toBe('')
    const aliceHash = calculateParticipantHash(['alice@example.com'])
    const alice = (await db.conversations.toArray()).find((c) => c.participantHash === aliceHash)!
    expect(alice.inboxUnreadCount).toBe(2)
    expect(alice.snippet).toBe('Second from alice')

    // Restart: the rerun converges with no duplicates.
    const rerun = await runInitialSync(deps())
    expect(rerun.historyIdAdvanced).toBe(true)
    expect(await db.messages.count()).toBe(5)
    expect(await db.conversations.count()).toBe(3)
    const aliceAfter = (await db.conversations.toArray()).find(
      (c) => c.participantHash === aliceHash,
    )!
    expect(aliceAfter.id).toBe(alice.id)
    expect(aliceAfter.inboxUnreadCount).toBe(3)
    expect((await db.accounts.get(ME))?.historyId).toBe('hist-start')
  })

  it('builds the backfill query from install − 5 minutes', () => {
    expect(initialSyncQuery(NOW)).toBe(
      `after:${Math.floor((NOW - 300_000) / 1000)} -label:spam -label:drafts -label:trash`,
    )
  })
})
