import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
  CHAT_PREVIEW_DERIVATION_VERSION,
  CHAT_PREVIEW_REPAIR_KEY,
  rederiveStoredChatPreviews,
} from './chatPreviewRepair'
import { runSync } from './engine'
import { makeTestDb, NOW, seedAccount, StubGmailApi, testDeps } from './testSupport'

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

  // Revert-check: dropping the `isFromMe === 0 && hasHtmlBody === 1` filter, or the
  // non-null guards on the derived values, in `rederiveBatch` fails this test.
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
})

describe('runSync', () => {
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
