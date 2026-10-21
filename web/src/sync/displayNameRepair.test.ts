import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MsgParticipantRow } from '@/db/types'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
  ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY,
  peelQuoteWrappedDisplayNamesIfNeeded,
  QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY,
  repairAddressShapedPersonDisplayNamesIfNeeded,
} from './displayNameRepair'
import { makeTestDb, ME } from './testSupport'

const JACOB = 'jacob.laycock@studs.com'
const BOB = 'bob@example.com'

function participant(
  messageId: string,
  email: string,
  kind: MsgParticipantRow['kind'],
  displayName = '',
): MsgParticipantRow {
  return { messageId, email, displayName, kind }
}

async function addConversation(id: string, emails: string[], displayName: string): Promise<void> {
  await db.conversations.add(convoRow({ id, displayName }))
  await db.convoParticipants.bulkPut(
    emails.map((email) => ({ conversationId: id, email, role: 'normal' as const })),
  )
}

async function title(conversationId: string): Promise<string | undefined> {
  return (await db.conversations.get(conversationId))?.displayName
}

async function flag(key: string): Promise<unknown> {
  return (await db.syncState.get(key))?.value
}

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  vi.restoreAllMocks()
  await db.delete()
})

// Outlook and Exchange wrap a name in single quotes, and before
// sanitizeDisplayName peeled them every stored copy of the name kept them.
describe('peelQuoteWrappedDisplayNamesIfNeeded', () => {
  // Revert-check: dropping any of the three `bulkPut` writes, or the
  // `refreshConversationTitles` call, in `peelQuoteWrappedDisplayNamesIfNeeded`
  // fails this test.
  it('peels every stored copy of the name and re-derives the title that spelled it', async () => {
    await db.people.bulkPut([
      { email: JACOB, displayName: "'Jacob Laycock'" },
      { email: BOB, displayName: 'Bob Smith' },
    ])
    await addConversation('group', [JACOB, BOB], "Bob Smith, 'Jacob Laycock'")
    await db.messages.add(
      msgRow({
        id: 'from-jacob',
        conversationId: 'group',
        senderEmail: JACOB,
        senderName: "'Jacob Laycock'",
      }),
    )
    await db.msgParticipants.bulkAdd([
      participant('from-jacob', JACOB, 'from', "'Jacob Laycock'"),
      participant('from-jacob', ME, 'to'),
      participant('from-jacob', BOB, 'cc', '‘Bob Smith’'),
    ])

    const result = await peelQuoteWrappedDisplayNamesIfNeeded(db)

    expect(result).toEqual({
      performed: true,
      peeledPersonCount: 1,
      peeledParticipantCount: 2,
      peeledSenderNameCount: 1,
      refreshedConversationCount: 1,
    })
    expect(await db.people.get(JACOB)).toEqual({ email: JACOB, displayName: 'Jacob Laycock' })
    expect((await db.messages.get('from-jacob'))?.senderName).toBe('Jacob Laycock')
    const rows = await db.msgParticipants.where('messageId').equals('from-jacob').toArray()
    expect(rows.map((row) => row.displayName)).toEqual(['Jacob Laycock', '', 'Bob Smith'])
    expect(await title('group')).toBe('Bob Smith, Jacob Laycock')
    expect(await flag(QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY)).toBe(true)
  })

  // A title is built from the creating message's header names, so it can
  // spell the quoted name while the Person row holds a better, unquoted one.
  // Such a conversation is reached only through its messages.
  // Revert-check: dropping the conversation ids of `peeledSenders` fails the
  // 'sender' title; dropping those of `participantMessages` fails the
  // 'recipient' title.
  it('re-derives a title reached only through a message whose names it peeled', async () => {
    await db.people.put({ email: JACOB, displayName: 'Jacob A. Laycock' })
    await addConversation('sender', [JACOB], "'Jacob Laycock'")
    await addConversation('recipient', [JACOB], "'Jacob Laycock'")
    // A legacy row with no participant rows: only its senderName is quoted.
    await db.messages.add(
      msgRow({
        id: 'rowless',
        conversationId: 'sender',
        senderEmail: JACOB,
        senderName: "'Jacob Laycock'",
      }),
    )
    await db.messages.add(
      msgRow({
        id: 'to-jacob',
        conversationId: 'recipient',
        senderEmail: ME,
        senderName: 'Me',
        isFromMe: 1,
      }),
    )
    await db.msgParticipants.bulkAdd([
      participant('to-jacob', ME, 'from', 'Me'),
      participant('to-jacob', JACOB, 'to', "'Jacob Laycock'"),
    ])

    await peelQuoteWrappedDisplayNamesIfNeeded(db)

    expect(await title('sender')).toBe('Jacob A. Laycock')
    expect(await title('recipient')).toBe('Jacob A. Laycock')
    expect((await db.people.get(JACOB))?.displayName).toBe('Jacob A. Laycock')
  })

  // Re-deriving swaps a title's creation-time header names for Person names;
  // a title without a quote cannot spell a quoted name, so it keeps them.
  // Revert-check: dropping the quote-opener filter passed to
  // `refreshConversationTitles` fails this test.
  it('leaves a title without a quote as created, even in a conversation it peels names in', async () => {
    await db.people.put({ email: JACOB, displayName: "'Jacob Laycock'" })
    await addConversation('jake', [JACOB], 'Jake')

    const result = await peelQuoteWrappedDisplayNamesIfNeeded(db)

    expect(result.peeledPersonCount).toBe(1)
    expect(result.refreshedConversationCount).toBe(0)
    expect(await title('jake')).toBe('Jake')
  })

  // HONEST SCOPE: passes with the pass removed too. It fails if
  // `peeledDisplayName` over-matches: a quote inside a name, or one that does
  // not wrap the whole name (Google Groups' relay form), is part of the name.
  it('keeps a quote that does not wrap the whole name', async () => {
    const names = ["Patrick O'Brien", "'Til Tuesday", "'Jacob Laycock' via Studs Team"]
    await db.people.bulkPut(names.map((displayName, i) => ({ email: `p${i}@x.com`, displayName })))
    await db.messages.bulkAdd(
      names.map((senderName, i) => msgRow({ id: `m${i}`, conversationId: 'c', senderName })),
    )
    await db.msgParticipants.bulkAdd(
      names.map((displayName, i) => participant(`m${i}`, `p${i}@x.com`, 'from', displayName)),
    )

    const result = await peelQuoteWrappedDisplayNamesIfNeeded(db)

    expect(result).toMatchObject({
      performed: true,
      peeledPersonCount: 0,
      peeledParticipantCount: 0,
      peeledSenderNameCount: 0,
    })
    expect((await db.people.toArray()).map((person) => person.displayName)).toEqual(names)
    expect((await db.messages.toArray()).map((message) => message.senderName)).toEqual(names)
  })

  // Revert-check: dropping the flag check at the top of
  // `peelQuoteWrappedDisplayNamesIfNeeded` fails this test.
  it('runs once: a quoted name stored after the flag latched is left to ingestion', async () => {
    expect((await peelQuoteWrappedDisplayNamesIfNeeded(db)).performed).toBe(true)
    await db.people.put({ email: JACOB, displayName: "'Jacob Laycock'" })

    expect((await peelQuoteWrappedDisplayNamesIfNeeded(db)).performed).toBe(false)
    expect((await db.people.get(JACOB))?.displayName).toBe("'Jacob Laycock'")
  })

  // Revert-check: writing the flag outside the pass's transaction (before the
  // writes, in a transaction of its own) fails this test, and so does writing
  // the peeled rows outside it.
  it('commits nothing, flag included, when a write fails', async () => {
    await db.people.put({ email: JACOB, displayName: "'Jacob Laycock'" })
    await addConversation('quoted', [JACOB], "'Jacob Laycock'")
    vi.spyOn(db.conversations, 'bulkPut').mockImplementation(() => {
      throw new Error('quota exceeded')
    })

    await expect(peelQuoteWrappedDisplayNamesIfNeeded(db)).rejects.toThrow('quota exceeded')

    expect((await db.people.get(JACOB))?.displayName).toBe("'Jacob Laycock'")
    expect(await title('quoted')).toBe("'Jacob Laycock'")
    expect(await flag(QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY)).toBeUndefined()
  })
})

// Before isBetterDisplayNameForEmail refused it, an address used as a display
// name could replace a stored Person name, and the name never came back.
describe('repairAddressShapedPersonDisplayNamesIfNeeded', () => {
  // Revert-check: dropping the `bulkPut(repaired)` write in
  // `repairAddressShapedPersonDisplayNamesIfNeeded` fails this test, and so
  // does dropping the "@" filter passed to `refreshConversationTitles` (the
  // 'pair' title would become "Bob Smith, Jake").
  it('recovers the name an address replaced and re-derives the titles that spelled the address', async () => {
    await db.people.bulkPut([
      { email: JACOB, displayName: JACOB },
      { email: BOB, displayName: 'Bob Smith' },
    ])
    await addConversation('solo', [JACOB], JACOB)
    await addConversation('pair', [JACOB, BOB], 'Bob, Jake')
    await db.messages.bulkAdd([
      msgRow({ id: 'named', conversationId: 'solo', internalDate: 100 }),
      msgRow({ id: 'address', conversationId: 'solo', internalDate: 200 }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('named', JACOB, 'from', 'Jake'),
      participant('address', JACOB, 'to', JACOB),
    ])

    const result = await repairAddressShapedPersonDisplayNamesIfNeeded(db)

    expect(result).toEqual({
      performed: true,
      recoveredPersonCount: 1,
      unrecoveredPersonCount: 0,
      refreshedConversationCount: 1,
    })
    expect(await db.people.get(JACOB)).toEqual({ email: JACOB, displayName: 'Jake' })
    expect(await title('solo')).toBe('Jake')
    expect(await title('pair')).toBe('Bob, Jake')
    expect(await flag(ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY)).toBe(true)
  })

  // Revert-check: sorting the candidates oldest-first in
  // `foldedHeaderDisplayName` fails this test ("Jake K" would win the tie),
  // and so does dropping the `isHideMyEmailDisplayName` candidate filter
  // ("Hide My Email" would win, reclassifying the address as a relay).
  it('folds the stored names newest-first and rejects a Hide My Email label', async () => {
    await db.people.put({ email: JACOB, displayName: JACOB })
    await db.messages.bulkAdd([
      msgRow({ id: 'oldest', conversationId: 'c', internalDate: 100 }),
      msgRow({ id: 'newer', conversationId: 'c', internalDate: 200 }),
      msgRow({ id: 'newest', conversationId: 'c', internalDate: 300 }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('oldest', JACOB, 'cc', 'Jake K'),
      participant('newer', JACOB, 'to', 'Jake L'),
      participant('newest', JACOB, 'from', 'Hide My Email'),
    ])

    await repairAddressShapedPersonDisplayNamesIfNeeded(db)

    expect((await db.people.get(JACOB))?.displayName).toBe('Jake L')
  })

  // Revert-check: dropping the `stripWrappingQuotes` call in
  // `headerNameCandidates` fails this test.
  it('stores a recovered name the way ingestion now stores it, without its quotes', async () => {
    await db.people.put({ email: JACOB, displayName: `'${JACOB}'` })
    await db.messages.add(msgRow({ id: 'outlook', conversationId: 'c' }))
    await db.msgParticipants.add(participant('outlook', JACOB, 'to', "'Jake'"))

    await repairAddressShapedPersonDisplayNamesIfNeeded(db)

    expect((await db.people.get(JACOB))?.displayName).toBe('Jake')
  })

  // Revert-check: dropping the `isEmailAddressShapedDisplayName` candidate
  // filter in `headerNameCandidates` fails this test: the bare address is the
  // quoted one's shorter spelling, so the ranking lets it replace the stored
  // row and the pass counts an address as a recovered name.
  it('never recovers an address, even a cleaner spelling of the stored one', async () => {
    await db.people.put({ email: JACOB, displayName: `'${JACOB}'` })
    await db.messages.add(msgRow({ id: 'address', conversationId: 'c' }))
    await db.msgParticipants.add(participant('address', JACOB, 'to', JACOB))

    const result = await repairAddressShapedPersonDisplayNamesIfNeeded(db)

    expect(result).toMatchObject({ recoveredPersonCount: 0, unrecoveredPersonCount: 1 })
    expect((await db.people.get(JACOB))?.displayName).toBe(`'${JACOB}'`)
  })

  // A header that repeats a dotless address (`"ops@intranet" <ops@intranet>`)
  // stores a name the bare-address pattern does not match.
  // Revert-check: dropping the `person.email` argument from the selection's
  // `isEmailAddressShapedDisplayName` call fails this test.
  it("selects a row that holds the person's own dotless address", async () => {
    await db.people.put({ email: 'ops@intranet', displayName: 'ops@intranet' })
    await db.messages.add(msgRow({ id: 'ops', conversationId: 'c' }))
    await db.msgParticipants.add(participant('ops', 'ops@intranet', 'from', 'Ops Team'))

    await repairAddressShapedPersonDisplayNamesIfNeeded(db)

    expect((await db.people.get('ops@intranet'))?.displayName).toBe('Ops Team')
  })

  // Revert-check: writing the flag only when every selected row recovered a
  // name fails this test.
  it('keeps an address no stored header names, and still runs only once', async () => {
    await db.people.put({ email: JACOB, displayName: JACOB })
    await addConversation('solo', [JACOB], JACOB)

    expect(await repairAddressShapedPersonDisplayNamesIfNeeded(db)).toEqual({
      performed: true,
      recoveredPersonCount: 0,
      unrecoveredPersonCount: 1,
      refreshedConversationCount: 0,
    })
    expect((await db.people.get(JACOB))?.displayName).toBe(JACOB)
    expect(await title('solo')).toBe(JACOB)

    expect((await repairAddressShapedPersonDisplayNamesIfNeeded(db)).performed).toBe(false)
  })
})
