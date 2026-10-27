import Dexie from 'dexie'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
  CHAT_PREVIEW_DERIVATION_VERSION,
  CHAT_PREVIEW_REPAIR_KEY,
  rederiveStoredChatPreviews,
  seedChatPreviewRepairOnFreshStoreIfNeeded,
} from './chatPreviewRepair'
import { runSync } from './engine'
import {
  makeTestDb,
  ME,
  NOW,
  seedAccount,
  StubGmailApi,
  testDeps,
  textMessage,
} from './testSupport'

// Runs a test's hook each time a chat preview is derived, so a test can look at the
// transaction around the derivation or write while it runs.
const derivation = vi.hoisted(() => ({ onDerive: null as (() => void) | null }))

vi.mock('@/mime/preview', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/mime/preview')>()
  return {
    ...actual,
    createChatPreviewText: (...args: Parameters<typeof actual.createChatPreviewText>) => {
      derivation.onDerive?.()
      return actual.createChatPreviewText(...args)
    },
  }
})

// The MVPN short number shares the telephone row, which the cleanup only reads as
// contact details since the short number splits off the phone.
const SIGNED_HTML =
  '<p>Please see the attached schedule.</p><p>Best regards,</p><p>Wei Lin</p>' +
  '<p>Example Precision Inc.</p><p>Tel: +886-2-5555-0188 Ext. 321 MVPN 6688</p>' +
  '<p>Email: <a href="mailto:wei.lin@example.test">wei.lin@example.test</a></p>'
const LEAKED_PREVIEW =
  'Please see the attached schedule.\n\nBest regards,\n\nWei Lin\n\nExample Precision Inc.' +
  '\n\nTel: +886-2-5555-0188 Ext. 321 MVPN 6688\n\nEmail: wei.lin@example.test'
const LEAKED_SNIPPET =
  'Please see the attached schedule. Best regards, Wei Lin Example Precision Inc. ' +
  'Tel: +886-2-5555-0188 Ext. 321 MVPN 6688 Email: wei.lin@example.test'
const REPAIRED_PREVIEW = 'Please see the attached schedule.\n\nBest regards,\n\nWei Lin'
const REPAIRED_SNIPPET = 'Please see the attached schedule. Best regards, Wei Lin'

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  derivation.onDerive = null
  vi.restoreAllMocks()
  await db.delete()
})

async function addLeakedMessage(
  id: string,
  conversationId: string,
  overrides: Partial<MessageRow> = {},
): Promise<void> {
  await db.messages.add(
    msgRow({
      id,
      conversationId,
      chatPreviewText: LEAKED_PREVIEW,
      cleanedSnippet: LEAKED_SNIPPET,
      hasHtmlBody: 1,
      ...overrides,
    }),
  )
  await db.bodies.put({ messageId: id, html: SIGNED_HTML })
}

async function message(id: string): Promise<MessageRow | undefined> {
  return db.messages.get(id)
}

async function state(): Promise<unknown> {
  return (await db.syncState.get(CHAT_PREVIEW_REPAIR_KEY))?.value
}

describe('rederiveStoredChatPreviews', () => {
  // Revert-check: dropping the `bulkPut` write or the `rollupConversation` call in
  // `rederiveBatch` fails this test.
  it("rewrites a received row's previews from its stored body and recomputes the rollup", async () => {
    await db.conversations.add(convoRow({ id: 'wei', snippet: LEAKED_SNIPPET }))
    await addLeakedMessage('m1', 'wei')

    expect(await rederiveStoredChatPreviews(db, NOW)).toEqual({
      performed: true,
      completed: true,
      scannedMessageCount: 1,
      rewrittenMessageCount: 1,
      recomputedConversationCount: 1,
    })

    expect((await message('m1'))?.chatPreviewText).toBe(REPAIRED_PREVIEW)
    expect((await message('m1'))?.cleanedSnippet).toBe(REPAIRED_SNIPPET)
    expect((await db.conversations.get('wei'))?.snippet).toBe(REPAIRED_SNIPPET)
    expect(await state()).toEqual({
      version: CHAT_PREVIEW_DERIVATION_VERSION,
      lastId: 'm1',
      done: true,
    })
  })

  // Revert-check: `isRederivable` accepting every row, or `rederiveBatch` falling back to ''
  // instead of the stored value when a derivation comes out null, fails this test. HONEST
  // SCOPE: dropping only the read's `isRederivable` filter passes, because the write
  // transaction re-checks it on every row.
  it('leaves outgoing rows, rows without a body, and bodies that clean to nothing alone', async () => {
    // A stale snippet any recompute would replace.
    await db.conversations.add(convoRow({ id: 'wei', snippet: 'Stale snippet' }))
    await addLeakedMessage('m1', 'wei', { isFromMe: 1 })
    await addLeakedMessage('m2', 'wei', { hasHtmlBody: 0 })
    await db.messages.add(
      msgRow({ id: 'm3', conversationId: 'wei', chatPreviewText: 'Kept', hasHtmlBody: 1 }),
    )
    await db.bodies.put({ messageId: 'm3', html: '<div><br></div>' })

    expect(await rederiveStoredChatPreviews(db, NOW)).toMatchObject({
      performed: true,
      completed: true,
      scannedMessageCount: 3,
      rewrittenMessageCount: 0,
    })

    expect((await message('m1'))?.chatPreviewText).toBe(LEAKED_PREVIEW)
    expect((await message('m2'))?.chatPreviewText).toBe(LEAKED_PREVIEW)
    expect((await message('m3'))?.chatPreviewText).toBe('Kept')
    expect((await db.conversations.get('wei'))?.snippet).toBe('Stale snippet')
  })

  // Revert-check: dropping the cursor from the `syncState.put` in `rederiveBatch` (always
  // restarting from the first message) fails this test: the second run never reaches m3.
  it('stops at the budget and resumes from the committed cursor at the next run', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    for (const id of ['m1', 'm2', 'm3']) await addLeakedMessage(id, 'wei')

    expect(await rederiveStoredChatPreviews(db, NOW, 2)).toMatchObject({
      completed: false,
      scannedMessageCount: 2,
      rewrittenMessageCount: 2,
    })
    expect((await message('m3'))?.chatPreviewText).toBe(LEAKED_PREVIEW)

    expect(await rederiveStoredChatPreviews(db, NOW, 2)).toMatchObject({
      completed: true,
      scannedMessageCount: 1,
      rewrittenMessageCount: 1,
    })
    expect((await message('m3'))?.chatPreviewText).toBe(REPAIRED_PREVIEW)
  })

  // Revert-check: dropping the `state.done` early return in `rederiveBatch` fails the
  // first half; dropping the version check on the cursor fails the second half.
  it('skips a finished walk and restarts one an earlier version left', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    await db.syncState.put({
      key: CHAT_PREVIEW_REPAIR_KEY,
      value: { version: CHAT_PREVIEW_DERIVATION_VERSION, lastId: 'm1', done: true },
    })

    expect((await rederiveStoredChatPreviews(db, NOW)).performed).toBe(false)
    expect((await message('m1'))?.chatPreviewText).toBe(LEAKED_PREVIEW)

    await db.syncState.put({
      key: CHAT_PREVIEW_REPAIR_KEY,
      value: { version: '2026-01-01-earlier-v1', lastId: 'm1', done: true },
    })

    expect(await rederiveStoredChatPreviews(db, NOW)).toMatchObject({
      performed: true,
      completed: true,
      rewrittenMessageCount: 1,
    })
    expect((await message('m1'))?.chatPreviewText).toBe(REPAIRED_PREVIEW)
  })

  // Revert-check: deriving inside a transaction in `rederiveBatch` (as the read or the
  // write transaction's callback does) fails this test.
  it('derives with no transaction open', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    const transactions: unknown[] = []
    derivation.onDerive = () => transactions.push(Dexie.currentTransaction ?? null)

    await rederiveStoredChatPreviews(db, NOW)

    expect(transactions).toEqual([null])
    expect((await message('m1'))?.chatPreviewText).toBe(REPAIRED_PREVIEW)
  })

  // Revert-check: writing back the rows as the read transaction returned them, instead of
  // re-reading them in the write transaction, fails this test: the mark-read is reverted.
  it('keeps a local change made while the batch derived', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei', { isUnread: 1 })
    let markRead: Promise<number> | undefined
    derivation.onDerive = () => {
      markRead ??= db.messages.update('m1', { isUnread: 0, localModifiedAt: NOW })
    }

    expect((await rederiveStoredChatPreviews(db, NOW)).rewrittenMessageCount).toBe(1)
    expect(await markRead).toBe(1)

    expect(await message('m1')).toMatchObject({
      isUnread: 0,
      localModifiedAt: NOW,
      chatPreviewText: REPAIRED_PREVIEW,
      cleanedSnippet: REPAIRED_SNIPPET,
    })
  })

  // Revert-check: dropping the comparison with the values the derivation read, in the write
  // transaction of `rederiveBatch`, fails this test: the newer preview is overwritten.
  it('leaves previews another writer changed while the batch derived', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    let rewrite: Promise<number> | undefined
    derivation.onDerive = () => {
      rewrite ??= db.messages.update('m1', { chatPreviewText: 'Newer preview' })
    }

    expect((await rederiveStoredChatPreviews(db, NOW)).rewrittenMessageCount).toBe(0)
    expect(await rewrite).toBe(1)

    expect((await message('m1'))?.chatPreviewText).toBe('Newer preview')
    expect(await state()).toMatchObject({ lastId: 'm1', done: true })
  })

  // Revert-check: dropping the `isRederivable` re-check in the write transaction of
  // `rederiveBatch` fails this test: the row, outgoing by then, takes the received rule's
  // preview.
  it('leaves a row that stopped qualifying while the batch derived', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    let flip: Promise<number> | undefined
    derivation.onDerive = () => {
      flip ??= db.messages.update('m1', { isFromMe: 1 })
    }

    expect((await rederiveStoredChatPreviews(db, NOW)).rewrittenMessageCount).toBe(0)
    expect(await flip).toBe(1)

    expect((await message('m1'))?.chatPreviewText).toBe(LEAKED_PREVIEW)
    expect(await state()).toMatchObject({ lastId: 'm1', done: true })
  })

  // Revert-check: dropping the `isSameRepairState` check in the write transaction of
  // `rederiveBatch` fails this test: the batch writes its cursor over the other walker's
  // finished state and reopens the walk at m1.
  it('leaves the state another walker committed while the batch derived', async () => {
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    await addLeakedMessage('m2', 'wei')
    const finished = { version: CHAT_PREVIEW_DERIVATION_VERSION, lastId: 'm2', done: true }
    let commit: Promise<string> | undefined
    derivation.onDerive = () => {
      commit ??= db.syncState.put({ key: CHAT_PREVIEW_REPAIR_KEY, value: finished })
    }

    // A budget of one message: the batch reads m1 alone, so its own cursor is m1, unfinished.
    expect(await rederiveStoredChatPreviews(db, NOW, 1)).toMatchObject({
      scannedMessageCount: 1,
      rewrittenMessageCount: 0,
    })
    expect(await commit).toBe(CHAT_PREVIEW_REPAIR_KEY)

    expect(await state()).toEqual(finished)
    expect((await message('m1'))?.chatPreviewText).toBe(LEAKED_PREVIEW)
  })
})

describe('seedChatPreviewRepairOnFreshStoreIfNeeded', () => {
  // Revert-check: dropping the emptiness probe fails the second half (and the runSync
  // upgrade test below): a store with messages would skip its walk.
  it('marks the walk finished on a store with no messages, and only there', async () => {
    await seedChatPreviewRepairOnFreshStoreIfNeeded(db)
    expect(await state()).toEqual({
      version: CHAT_PREVIEW_DERIVATION_VERSION,
      lastId: null,
      done: true,
    })

    await db.syncState.delete(CHAT_PREVIEW_REPAIR_KEY)
    await addLeakedMessage('m1', 'wei')
    await seedChatPreviewRepairOnFreshStoreIfNeeded(db)
    expect(await state()).toBeUndefined()
  })

  // Revert-check: returning on any stored state, instead of only this version's, fails this
  // test: an empty store an earlier build left would re-clean everything its initial sync
  // stores.
  it('marks an empty store whose state an earlier version left', async () => {
    await db.syncState.put({
      key: CHAT_PREVIEW_REPAIR_KEY,
      value: { version: 'earlier-version', lastId: 'm9', done: true },
    })

    await seedChatPreviewRepairOnFreshStoreIfNeeded(db)

    expect(await state()).toEqual({
      version: CHAT_PREVIEW_DERIVATION_VERSION,
      lastId: null,
      done: true,
    })
  })

  // Revert-check: returning only on a finished state of this version, as the seed did, fails
  // this test: every sync of an upgraded store's walk probed the messages table.
  it("does not probe the messages while this version's walk is in progress", async () => {
    const inProgress = { version: CHAT_PREVIEW_DERIVATION_VERSION, lastId: 'm1', done: false }
    await db.syncState.put({ key: CHAT_PREVIEW_REPAIR_KEY, value: inProgress })
    await addLeakedMessage('m1', 'wei')
    const limit = vi.spyOn(db.messages, 'limit')
    const count = vi.spyOn(db.messages, 'count')

    await seedChatPreviewRepairOnFreshStoreIfNeeded(db)

    expect(limit).not.toHaveBeenCalled()
    expect(count).not.toHaveBeenCalled()
    expect(await state()).toEqual(inProgress)
  })

  // Revert-check: probing with `db.messages.count()` in the seed fails this test. IndexedDB
  // counts by walking every key, while the seed holds the messages table for writing.
  it('probes one key of a store with messages instead of counting them', async () => {
    await addLeakedMessage('m1', 'wei')
    const count = vi.spyOn(db.messages, 'count')

    await seedChatPreviewRepairOnFreshStoreIfNeeded(db)

    expect(count).not.toHaveBeenCalled()
    expect(await state()).toBeUndefined()
  })
})

describe('runSync', () => {
  // Revert-check: dropping the `seedChatPreviewRepairOnFreshStoreIfNeeded` call from `runSync`
  // fails this test: the repair walks the message the initial sync just stored.
  it('marks a fresh store finished before its initial sync instead of walking it', async () => {
    const api = new StubGmailApi()
    api.profile = { emailAddress: ME, historyId: 'hist-start' }
    api.messages.set('m1', textMessage({ id: 'm1', threadId: 'tA' }))
    api.listPages = [{ messages: [{ id: 'm1', threadId: 'tA' }] }]

    const outcome = await runSync(testDeps(db, api), 'startup')

    expect(outcome.error).toBeUndefined()
    expect(await db.messages.count()).toBe(1)
    expect(await state()).toEqual({
      version: CHAT_PREVIEW_DERIVATION_VERSION,
      lastId: null,
      done: true,
    })
  })

  // Revert-check: dropping the `repairStoredChatPreviewsIfNeeded` call from `runSync`
  // fails this test.
  it('repairs stored previews after its network work', async () => {
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'wei' }))
    await addLeakedMessage('m1', 'wei')
    const api = new StubGmailApi()
    api.historyFactory = () => ({ historyId: 'h2', history: [] })

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect((await message('m1'))?.chatPreviewText).toBe(REPAIRED_PREVIEW)
  })
})
