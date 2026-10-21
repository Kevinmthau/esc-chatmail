import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { CalendarEventData } from '@/db/types'
import { convoRow, msgRow } from '@/outbox/testSupport'
import { runSync } from './engine'
import {
  decodeEncodedSubjectsIfNeeded,
  ENCODED_SUBJECT_REPAIR_KEY,
  type EncodedSubjectRepairResult,
} from './subjectRepair'
import { makeTestDb, ME, NOW, seedAccount, StubGmailApi, testDeps } from './testSupport'

// UTF-8 base64 encoded words for "Trip plans" and "Fwd: Trip plans".
const ENCODED_TRIP_PLANS = '=?utf-8?B?VHJpcCBwbGFucw==?='
const ENCODED_FORWARD = '=?utf-8?B?RndkOiBUcmlwIHBsYW5z?='

function calendarEvent(title: string): CalendarEventData {
  return {
    title,
    startMs: NOW,
    endMs: NOW + 30 * 60 * 1000,
    timeZone: '',
    isAllDay: 0,
    location: '',
    organizer: '',
    method: 'REQUEST',
    status: '',
    source: 'Google Calendar',
  }
}

async function subject(messageId: string): Promise<string | undefined> {
  return (await db.messages.get(messageId))?.subject
}

async function snippet(conversationId: string): Promise<string | undefined> {
  return (await db.conversations.get(conversationId))?.snippet
}

async function flag(): Promise<unknown> {
  return (await db.syncState.get(ENCODED_SUBJECT_REPAIR_KEY))?.value
}

async function repair(): Promise<EncodedSubjectRepairResult> {
  return decodeEncodedSubjectsIfNeeded(db, NOW)
}

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  vi.restoreAllMocks()
  await db.delete()
})

describe('decodeEncodedSubjectsIfNeeded', () => {
  // Revert-check: dropping the `bulkPut` write or the `rollupConversation`
  // call in `decodeEncodedSubjectsIfNeeded` fails this test.
  it('decodes the subject and re-derives the forward preview that spelled it', async () => {
    await db.conversations.add(convoRow({ id: 'trip', snippet: `Fwd: "${ENCODED_TRIP_PLANS}"` }))
    await db.messages.add(
      msgRow({ id: 'm1', conversationId: 'trip', subject: `Fwd: ${ENCODED_TRIP_PLANS}` }),
    )

    expect(await repair()).toEqual({
      performed: true,
      decodedSubjectCount: 1,
      retitledCalendarEventCount: 0,
      recomputedConversationCount: 1,
    })

    expect(await subject('m1')).toBe('Fwd: Trip plans')
    expect(await snippet('trip')).toBe('Fwd: "Trip plans"')
    expect(await flag()).toBe(true)
  })

  // iOS decodes the stored snippet in place, which cannot help here: the
  // encoded word hid the "Fwd:" prefix, so the snippet holds no encoded word.
  // Revert-check: replacing the `rollupConversation` call in
  // `decodeEncodedSubjectsIfNeeded` with an in-place snippet decode fails
  // this test.
  it('turns a forward whose whole subject was encoded into a forward preview', async () => {
    await db.conversations.add(convoRow({ id: 'trip', snippet: 'See below.' }))
    await db.messages.add(
      msgRow({
        id: 'm1',
        conversationId: 'trip',
        subject: ENCODED_FORWARD,
        cleanedSnippet: 'See below.',
      }),
    )

    await repair()

    expect(await subject('m1')).toBe('Fwd: Trip plans')
    expect(await snippet('trip')).toBe('Fwd: "Trip plans"')
  })

  // Revert-check: dropping the `decoded === message.subject` skip in
  // `decodeEncodedSubjectsIfNeeded` fails this test.
  it('leaves a subject the decoder cannot change alone, along with its conversation', async () => {
    // A stale snippet any recompute would replace with the message's 'Body'.
    await db.conversations.add(convoRow({ id: 'budget', snippet: 'Stale snippet' }))
    await db.messages.add(
      msgRow({ id: 'm1', conversationId: 'budget', subject: 'Budget =?utf-8?Q?bad=ZZ?= review' }),
    )

    expect(await repair()).toEqual({
      performed: true,
      decodedSubjectCount: 0,
      retitledCalendarEventCount: 0,
      recomputedConversationCount: 0,
    })

    expect(await subject('m1')).toBe('Budget =?utf-8?Q?bad=ZZ?= review')
    expect(await snippet('budget')).toBe('Stale snippet')
    expect(await flag()).toBe(true)
  })

  // Revert-check: dropping the `invitedSubjectTitle` re-derivation in
  // `decodeEncodedSubjectsIfNeeded` fails this test.
  it('re-derives an invite title that fell back to the encoded subject, and keeps a SUMMARY', async () => {
    const encodedInvite = '=?utf-8?Q?Invitation:_Caf=C3=A9_sync_@_Mon_Oct_20?='
    await db.conversations.add(convoRow({ id: 'invites' }))
    await db.messages.bulkAdd([
      msgRow({
        id: 'no-summary',
        conversationId: 'invites',
        subject: encodedInvite,
        isCalendarInvite: 1,
        // invitedSubjectTitle of the encoded subject: no prefix or " @ " tail
        // to strip until the subject is decoded.
        calendarEvent: calendarEvent(encodedInvite),
      }),
      msgRow({
        id: 'with-summary',
        conversationId: 'invites',
        subject: encodedInvite,
        isCalendarInvite: 1,
        calendarEvent: calendarEvent('Quarterly review'),
      }),
    ])

    expect(await repair()).toMatchObject({ decodedSubjectCount: 2, retitledCalendarEventCount: 1 })

    const noSummary = await db.messages.get('no-summary')
    expect(noSummary?.subject).toBe('Invitation: Café sync @ Mon Oct 20')
    expect(noSummary?.calendarEvent).toEqual(calendarEvent('Café sync'))
    const withSummary = await db.messages.get('with-summary')
    expect(withSummary?.subject).toBe('Invitation: Café sync @ Mon Oct 20')
    expect(withSummary?.calendarEvent).toEqual(calendarEvent('Quarterly review'))
  })

  // Revert-check: dropping the `flag?.value === true` early return in
  // `decodeEncodedSubjectsIfNeeded` fails this test.
  it('runs once: after the flag latches, it leaves the store alone', async () => {
    expect(await repair()).toMatchObject({ performed: true })
    await db.conversations.add(convoRow({ id: 'trip', snippet: 'Stale snippet' }))
    await db.messages.add(msgRow({ id: 'm1', conversationId: 'trip', subject: ENCODED_FORWARD }))

    expect(await repair()).toEqual({
      performed: false,
      decodedSubjectCount: 0,
      retitledCalendarEventCount: 0,
      recomputedConversationCount: 0,
    })

    expect(await subject('m1')).toBe(ENCODED_FORWARD)
    expect(await snippet('trip')).toBe('Stale snippet')
  })

  // Revert-check: running the body of `decodeEncodedSubjectsIfNeeded` outside
  // its `db.transaction` fails this test (the decoded subjects commit before
  // the rollup throws).
  it('commits nothing when a rollup write fails, so the next run retries', async () => {
    await db.conversations.add(convoRow({ id: 'trip', snippet: `Fwd: "${ENCODED_TRIP_PLANS}"` }))
    await db.messages.add(
      msgRow({ id: 'm1', conversationId: 'trip', subject: `Fwd: ${ENCODED_TRIP_PLANS}` }),
    )
    const put = vi.spyOn(db.conversations, 'put').mockImplementation(() => {
      throw new Error('quota exceeded')
    })

    await expect(repair()).rejects.toThrow('quota exceeded')

    expect(await subject('m1')).toBe(`Fwd: ${ENCODED_TRIP_PLANS}`)
    expect(await snippet('trip')).toBe(`Fwd: "${ENCODED_TRIP_PLANS}"`)
    expect(await flag()).toBeUndefined()

    put.mockRestore()
    expect(await repair()).toMatchObject({ performed: true, decodedSubjectCount: 1 })
    expect(await snippet('trip')).toBe('Fwd: "Trip plans"')
  })
})

describe('runSync', () => {
  let api: StubGmailApi

  beforeEach(() => {
    api = new StubGmailApi()
  })

  // Revert-check: dropping the `repairStoredSubjectsIfNeeded` call from
  // `runSync` fails this test, and so does moving it after
  // `runIncrementalSync` (the network work this test observes).
  it('decodes stored subjects before its network work', async () => {
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'trip', snippet: 'See below.' }))
    await db.messages.add(
      msgRow({
        id: 'm1',
        conversationId: 'trip',
        subject: ENCODED_FORWARD,
        cleanedSnippet: 'See below.',
      }),
    )
    const listHistory = api.listHistory.bind(api)
    api.listHistory = async (params) => {
      expect(await subject('m1')).toBe('Fwd: Trip plans')
      expect(await snippet('trip')).toBe('Fwd: "Trip plans"')
      return listHistory(params)
    }
    api.historyFactory = () => ({ historyId: 'h2', history: [] })

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(await flag()).toBe(true)
  })

  // Revert-check: dropping the try/catch in `repairStoredSubjectsIfNeeded`
  // fails this test.
  it('carries on with the sync when the subject repair fails, leaving it to retry', async () => {
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'trip' }))
    await db.messages.add(msgRow({ id: 'm1', conversationId: 'trip', subject: ENCODED_FORWARD }))
    vi.spyOn(db.messages, 'bulkPut').mockImplementation(() => {
      throw new Error('quota exceeded')
    })
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    api.historyFactory = () => ({ historyId: 'h2', history: [] })

    const outcome = await runSync(testDeps(db, api), 'manual')

    expect(outcome.error).toBeUndefined()
    expect((await db.accounts.get(ME))?.historyId).toBe('h2')
    expect(warn).toHaveBeenCalledTimes(1)
    expect(await subject('m1')).toBe(ENCODED_FORWARD)
    expect(await flag()).toBeUndefined()
  })
})
