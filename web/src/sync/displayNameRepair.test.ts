import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MsgParticipantRow } from '@/db/types'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
  ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY,
  decodeRfc2047DisplayNamesIfNeeded,
  peelQuoteWrappedDisplayNamesIfNeeded,
  QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY,
  repairAddressShapedPersonDisplayNamesIfNeeded,
  repairStoredDisplayNamesIfNeeded,
  RFC2047_DISPLAY_NAME_REPAIR_KEY,
} from './displayNameRepair'
import { makeTestDb, ME } from './testSupport'

const JACOB = 'jacob.laycock@studs.com'
const BOB = 'bob@example.com'
const JOSE = 'jose@example.com'
// "José García", as a B-encoded and a Q-encoded word.
const JOSE_B = '=?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?='
const JOSE_Q = '=?utf-8?Q?Jos=C3=A9_Garc=C3=ADa?='

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

// Before sanitizeDisplayName decoded them, every stored copy of a name a
// header spelled as an RFC 2047 encoded word kept the raw word.
describe('decodeRfc2047DisplayNamesIfNeeded', () => {
  // Revert-check: dropping any of the three `bulkPut` writes, or the
  // `refreshConversationTitles` call, in `decodeRfc2047DisplayNamesIfNeeded`
  // fails this test.
  it('decodes every stored copy of the name and re-derives the title that spelled it', async () => {
    await db.people.bulkPut([
      { email: JOSE, displayName: JOSE_B },
      { email: BOB, displayName: 'Bob Smith' },
    ])
    await addConversation('group', [JOSE, BOB], `${JOSE_B}, Bob Smith`)
    await db.messages.add(
      msgRow({ id: 'from-jose', conversationId: 'group', senderEmail: JOSE, senderName: JOSE_B }),
    )
    await db.msgParticipants.bulkAdd([
      participant('from-jose', JOSE, 'from', JOSE_B),
      participant('from-jose', ME, 'to'),
      participant('from-jose', BOB, 'cc', '=?iso-8859-1?Q?Bob_Smith?='),
    ])

    const result = await decodeRfc2047DisplayNamesIfNeeded(db)

    expect(result).toEqual({
      performed: true,
      decodedPersonCount: 1,
      decodedParticipantCount: 2,
      decodedSenderNameCount: 1,
      refreshedConversationCount: 1,
    })
    expect(await db.people.get(JOSE)).toEqual({ email: JOSE, displayName: 'José García' })
    expect((await db.messages.get('from-jose'))?.senderName).toBe('José García')
    const rows = await db.msgParticipants.where('messageId').equals('from-jose').toArray()
    expect(rows.map((row) => row.displayName)).toEqual(['José García', '', 'Bob Smith'])
    expect(await title('group')).toBe('Bob Smith, José García')
    expect(await flag(RFC2047_DISPLAY_NAME_REPAIR_KEY)).toBe(true)
  })

  // A title spells its creating message's header names, which no row this
  // pass decodes need still hold: here the Person row took a clean name and
  // the message is gone.
  // Revert-check: passing `refreshConversationTitles` only the conversations
  // of the decoded rows (`conversationIdsOfPeople(db, decodedPeople)`), as the
  // peel pass reaches them, instead of every conversation fails this test.
  it('re-derives a title that spells an encoded word even where no decoded name reaches it', async () => {
    await db.people.put({ email: JOSE, displayName: 'José García' })
    await addConversation('stale', [JOSE], JOSE_Q)

    const result = await decodeRfc2047DisplayNamesIfNeeded(db)

    expect(result).toMatchObject({ decodedPersonCount: 0, refreshedConversationCount: 1 })
    expect(await title('stale')).toBe('José García')
  })

  // Re-deriving swaps a title's creation-time header names for Person names;
  // a title without an encoded word cannot spell an encoded name, so it keeps
  // them.
  // Revert-check: replacing the `containsEncodedWord` filter passed to
  // `refreshConversationTitles` with one that accepts every title fails this
  // test.
  it('leaves a title without an encoded word as created, even in a conversation it decodes names in', async () => {
    await db.people.put({ email: JOSE, displayName: JOSE_B })
    await addConversation('jose', [JOSE], 'José')

    const result = await decodeRfc2047DisplayNamesIfNeeded(db)

    expect(result).toMatchObject({ decodedPersonCount: 1, refreshedConversationCount: 0 })
    expect(await title('jose')).toBe('José')
  })

  // A quote-wrapped name is the peel pass's, and a word the decoder rejects
  // (a malformed `=XX` escape, an unknown encoding) is kept by ingestion too.
  // Revert-check: dropping the `containsEncodedWord` gate in
  // `decodedDisplayName` fails this test (the quote-wrapped name would be
  // peeled here), and so does dropping its `decoded === stored` check (the
  // rejected words would be rewritten unchanged and counted).
  it('leaves a name without a decodable encoded word to the other passes', async () => {
    const names = ["'Jacob Laycock'", '=?utf-8?Q?bad=ZZ?=', '=?utf-8?X?abc?=', 'Q=?A']
    await db.people.bulkPut(names.map((displayName, i) => ({ email: `p${i}@x.com`, displayName })))
    await db.messages.bulkAdd(
      names.map((senderName, i) => msgRow({ id: `m${i}`, conversationId: 'c', senderName })),
    )
    await db.msgParticipants.bulkAdd(
      names.map((displayName, i) => participant(`m${i}`, `p${i}@x.com`, 'from', displayName)),
    )

    const result = await decodeRfc2047DisplayNamesIfNeeded(db)

    expect(result).toEqual({
      performed: true,
      decodedPersonCount: 0,
      decodedParticipantCount: 0,
      decodedSenderNameCount: 0,
      refreshedConversationCount: 0,
    })
    expect((await db.people.toArray()).map((person) => person.displayName)).toEqual(names)
    expect((await db.messages.toArray()).map((message) => message.senderName)).toEqual(names)
    expect((await db.msgParticipants.toArray()).map((row) => row.displayName)).toEqual(names)
  })

  // Revert-check: dropping the flag check at the top of
  // `decodeRfc2047DisplayNamesIfNeeded` fails this test.
  it('runs once: an encoded name stored after the flag latched is left to ingestion', async () => {
    expect((await decodeRfc2047DisplayNamesIfNeeded(db)).performed).toBe(true)
    await db.people.put({ email: JOSE, displayName: JOSE_B })

    expect((await decodeRfc2047DisplayNamesIfNeeded(db)).performed).toBe(false)
    expect((await db.people.get(JOSE))?.displayName).toBe(JOSE_B)
  })

  // Revert-check: writing the flag outside the pass's transaction (before the
  // writes, in a transaction of its own) fails this test.
  it('commits nothing, flag included, when a write fails', async () => {
    await db.people.put({ email: JOSE, displayName: JOSE_B })
    await addConversation('encoded', [JOSE], JOSE_B)
    vi.spyOn(db.conversations, 'bulkPut').mockImplementation(() => {
      throw new Error('quota exceeded')
    })

    await expect(decodeRfc2047DisplayNamesIfNeeded(db)).rejects.toThrow('quota exceeded')

    expect((await db.people.get(JOSE))?.displayName).toBe(JOSE_B)
    expect(await title('encoded')).toBe(JOSE_B)
    expect(await flag(RFC2047_DISPLAY_NAME_REPAIR_KEY)).toBeUndefined()
  })
})

describe('repairStoredDisplayNamesIfNeeded', () => {
  // The ranking never lets a name still holding an encoded word replace even
  // an address, so the address pass can recover "Jake" only once the header
  // name it reads is decoded.
  // Revert-check: running `decodeRfc2047DisplayNamesIfNeeded` after
  // `repairAddressShapedPersonDisplayNamesIfNeeded` fails this test.
  it('decodes the participant names the address pass recovers a name from first', async () => {
    await db.people.put({ email: JACOB, displayName: JACOB })
    await addConversation('solo', [JACOB], JACOB)
    await db.messages.add(msgRow({ id: 'encoded', conversationId: 'solo' }))
    await db.msgParticipants.add(participant('encoded', JACOB, 'to', '=?utf-8?B?SmFrZQ==?='))

    await repairStoredDisplayNamesIfNeeded(db)

    expect((await db.people.get(JACOB))?.displayName).toBe('Jake')
    expect(await title('solo')).toBe('Jake')
  })

  // Outlook wraps a name in quotes outside an encoded word or inside it. On a
  // store whose peel pass latched before the decode pass existed, the peel
  // pass cannot remove the quotes decoding exposes, so the decode pass must.
  // Revert-check: replacing `sanitizeDisplayName` with `decodeRfc2047` in
  // `decodeRfc2047DisplayNamesIfNeeded` and `decodedDisplayName` fails this
  // test.
  it('peels the quotes decoding exposes even when the peel pass already ran', async () => {
    await db.syncState.put({ key: QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY, value: true })
    await db.people.put({ email: JACOB, displayName: '=?utf-8?Q?=27Jacob_Laycock=27?=' })
    await addConversation('solo', [JACOB], '=?utf-8?Q?=27Jacob_Laycock=27?=')
    await db.messages.add(
      msgRow({ id: 'outlook', conversationId: 'solo', senderName: "'=?utf-8?Q?Jacob_Laycock?='" }),
    )
    await db.msgParticipants.add(
      participant('outlook', JACOB, 'from', "'=?utf-8?Q?Jacob_Laycock?='"),
    )

    await repairStoredDisplayNamesIfNeeded(db)

    expect((await db.people.get(JACOB))?.displayName).toBe('Jacob Laycock')
    expect((await db.messages.get('outlook'))?.senderName).toBe('Jacob Laycock')
    expect((await db.msgParticipants.toArray()).map((row) => row.displayName)).toEqual([
      'Jacob Laycock',
    ])
    expect(await title('solo')).toBe('Jacob Laycock')
  })
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
