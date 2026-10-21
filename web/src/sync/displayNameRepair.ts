// One-shot repairs for display names stored before normalizeEmail.ts reached
// iOS parity: ports of the name half of
// DataCleanupService.decodeRFC2047HeaderTextIfNeeded,
// DataCleanupService.repairAddressShapedPersonDisplayNamesIfNeeded (iOS #311)
// and DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded (iOS #317).
// Ingestion now stores clean names and ranks a stored encoded, quoted or
// address-shaped name below a clean one, but that heals a Person row only when
// a later header names the same person, and it never touches the names stored
// on messages. Web has no display-time name resolver either: a conversation
// title is a string stored at creation and re-derived only by the
// participant-set repair, so a title saved with an encoded word or the quotes
// keeps them.
//
// Each pass is one Dexie transaction that reads its flag first and writes it
// last, so the flag commits together with the repaired rows or not at all,
// and a pass that throws leaves it clear for the next sync to retry. Like the
// iOS migration keys, the flags are versioned: bump one when the rule its pass
// applies learns a new shape, so stores that latched it select the rows it
// missed.

import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MsgParticipantRow, ParticipantKind, PersonRow } from '@/db/types'
import {
  WRAPPING_QUOTE_OPENERS,
  isBetterDisplayNameForEmail,
  isEmailAddressShapedDisplayName,
  isHideMyEmailDisplayName,
  normalizeEmail,
  sanitizeDisplayName,
  stripWrappingQuotes,
} from '@/identity/normalizeEmail'
import { compareSwiftStrings } from '@/identity/participantSet'
import { containsEncodedWord } from '@/mime/rfc2047Decoder'
import { conversationDisplayName, personNames } from './participantSetRepair'

export const RFC2047_DISPLAY_NAME_REPAIR_KEY = 'decodedRfc2047DisplayNamesV1'

// Already covers the shapes of iOS's V2 key (Outlook's quote-wrapped `'addr'`),
// because `isEmailAddressShapedDisplayName` peels before matching.
export const ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY = 'repairedAddressShapedPersonNamesV1'

export const QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY = 'peeledQuoteWrappedDisplayNamesV1'

export interface Rfc2047DisplayNameRepairResult {
  /** False means the flag was already set. */
  performed: boolean
  decodedPersonCount: number
  decodedParticipantCount: number
  decodedSenderNameCount: number
  refreshedConversationCount: number
}

export interface AddressShapedPersonNameRepairResult {
  /** False means the flag was already set. */
  performed: boolean
  recoveredPersonCount: number
  /** Address-shaped Person rows no stored header names; they keep the address. */
  unrecoveredPersonCount: number
  refreshedConversationCount: number
}

export interface QuoteWrappedDisplayNameRepairResult {
  /** False means the flag was already set. */
  performed: boolean
  peeledPersonCount: number
  peeledParticipantCount: number
  peeledSenderNameCount: number
  refreshedConversationCount: number
}

/**
 * Runs the repairs in iOS's cleanup order. A pass that fails is logged and
 * retried at the next sync, and the sync that ran it carries on: until the
 * pass succeeds, the store keeps the names it held before the repair existed.
 *
 * Decoding comes first because the address pass recovers a name from the
 * names stored on participant rows, and the ranking never lets one still
 * holding an encoded word replace even an address: decoded later, a header
 * that named the person only as `=?utf-8?B?SmFrZQ==?=` would recover nothing,
 * and the address pass would have latched. The peel pass needs no such
 * ordering: the decode pass stores `sanitizeDisplayName`'s result, which peels
 * the quotes decoding exposes itself, so it holds even for a store whose peel
 * flag latched before this pass existed.
 */
export async function repairStoredDisplayNamesIfNeeded(db: ChatmailDB): Promise<void> {
  try {
    await decodeRfc2047DisplayNamesIfNeeded(db)
  } catch (error) {
    console.warn('[displayNames] RFC 2047 display name repair failed; will retry', error)
  }
  try {
    await repairAddressShapedPersonDisplayNamesIfNeeded(db)
  } catch (error) {
    console.warn('[displayNames] address-shaped Person name repair failed; will retry', error)
  }
  try {
    await peelQuoteWrappedDisplayNamesIfNeeded(db)
  } catch (error) {
    console.warn('[displayNames] quote-wrapped display name repair failed; will retry', error)
  }
}

/**
 * One-time repair for names stored with raw RFC 2047 encoded-words
 * (`=?utf-8?B?…?=`), from before `sanitizeDisplayName` decoded them: Person
 * rows, message participant rows, and message sender names, which showed the
 * encoded word as a sender name and in chat titles. The new value is exactly
 * what ingestion now stores for the same header, so a name that decodes to a
 * quote-wrapped one is peeled as well. A word the decoder cannot decode (bad
 * base64, a malformed `=XX` escape) stays, as ingestion keeps it.
 *
 * Every stored title that spells an encoded word is re-derived, as iOS
 * selects them, not only those of the conversations whose names this pass
 * decodes. A title spells the header names of the message that created its
 * conversation, and nothing else may still hold them: the Person row can have
 * taken another name since, and that message can be gone. The other passes
 * also re-derive titles from Person names, which are still encoded wherever
 * this pass failed before them. A title without an encoded word cannot spell
 * an encoded name, and re-deriving it would swap the names it took from its
 * first message's headers for Person names. iOS decodes a title in place;
 * web re-derives it from the decoded Person names, as the other passes do, so
 * a title also loses the quotes decoding exposes.
 *
 * Idempotent: a decoded row no longer changes, so a re-run writes nothing.
 */
export async function decodeRfc2047DisplayNamesIfNeeded(
  db: ChatmailDB,
): Promise<Rfc2047DisplayNameRepairResult> {
  return db.transaction(
    'rw',
    [
      db.syncState,
      db.people,
      db.msgParticipants,
      db.messages,
      db.conversations,
      db.convoParticipants,
    ],
    async () => {
      const flag = await db.syncState.get(RFC2047_DISPLAY_NAME_REPAIR_KEY)
      if (flag?.value === true) {
        return {
          performed: false,
          decodedPersonCount: 0,
          decodedParticipantCount: 0,
          decodedSenderNameCount: 0,
          refreshedConversationCount: 0,
        }
      }

      // Decoded in place, so the titles below are derived from the new names.
      const people = await db.people.toArray()
      const decodedPeople: PersonRow[] = []
      for (const person of people) {
        const decoded = decodedDisplayName(person.displayName)
        if (decoded === null) continue
        person.displayName = decoded
        decodedPeople.push(person)
      }

      const decodedParticipants = (
        await db.msgParticipants
          .filter((row) => decodedDisplayName(row.displayName) !== null)
          .toArray()
      ).map((row) => ({ ...row, displayName: sanitizeDisplayName(row.displayName) }))

      const decodedSenders = (
        await db.messages
          .filter((message) => decodedDisplayName(message.senderName) !== null)
          .toArray()
      ).map((message) => ({ ...message, senderName: sanitizeDisplayName(message.senderName) }))

      if (decodedPeople.length > 0) await db.people.bulkPut(decodedPeople)
      if (decodedParticipants.length > 0) await db.msgParticipants.bulkPut(decodedParticipants)
      if (decodedSenders.length > 0) await db.messages.bulkPut(decodedSenders)

      const refreshedConversationCount = await refreshConversationTitles(
        db,
        new Set(await db.conversations.toCollection().primaryKeys()),
        people,
        containsEncodedWord,
      )

      // Last write by design: it commits with the decoded rows or not at all.
      await db.syncState.put({ key: RFC2047_DISPLAY_NAME_REPAIR_KEY, value: true })

      return {
        performed: true,
        decodedPersonCount: decodedPeople.length,
        decodedParticipantCount: decodedParticipants.length,
        decodedSenderNameCount: decodedSenders.length,
        refreshedConversationCount,
      }
    },
  )
}

/**
 * One-time repair for Person names that hold an email address instead of a
 * name. Before `isBetterDisplayNameForEmail` refused to let an address-shaped
 * name replace a name, a To/Cc header written as
 * `"jacob.laycock@studs.com" <jacob.laycock@studs.com>` could overwrite a
 * stored name with the address, and a one-word name ("Jake") it replaced
 * never came back. This pass recovers a name for those rows from the names
 * stored on the person's message participant rows.
 *
 * iOS keeps a To/Cc name only inside a raw header stored since model v6; web
 * stores every From/To/Cc/Bcc name on its participant row, so any header that
 * ever named the person can supply one. A row no stored header names keeps
 * the address and the flag still latches: a re-run cannot find a name the
 * store does not hold, and the next header that names the person heals it in
 * ingestion.
 *
 * Only the repaired people's conversation titles that contain an "@" are
 * re-derived: a title without one cannot spell the address, and re-deriving
 * it would swap the names it took from its first message's headers for Person
 * names. iOS also refreshes the titles of unrecovered rows, because its titles
 * hide an address-shaped Person name; web titles spell it as stored, so a
 * refresh could not drop it.
 */
export async function repairAddressShapedPersonDisplayNamesIfNeeded(
  db: ChatmailDB,
): Promise<AddressShapedPersonNameRepairResult> {
  return db.transaction(
    'rw',
    [
      db.syncState,
      db.people,
      db.msgParticipants,
      db.messages,
      db.conversations,
      db.convoParticipants,
    ],
    async () => {
      const flag = await db.syncState.get(ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY)
      if (flag?.value === true) {
        return {
          performed: false,
          recoveredPersonCount: 0,
          unrecoveredPersonCount: 0,
          refreshedConversationCount: 0,
        }
      }

      // Repaired in place, so the titles below are derived from the new names.
      const people = await db.people.toArray()
      // The `email` form also matches the person's own dotless,
      // internationalized or domain-literal address (`"ops@intranet"
      // <ops@intranet>`), which a header could store as the name but the
      // bare-address pattern misses. The candidate filter uses the same form,
      // so the two agree on what counts as an address.
      const addressShaped = people.filter((person) =>
        isEmailAddressShapedDisplayName(person.displayName, person.email),
      )

      const repaired: PersonRow[] = []
      if (addressShaped.length > 0) {
        const candidates = await headerNameCandidates(
          db,
          new Set(addressShaped.map((person) => normalizeEmail(person.email))),
        )
        for (const person of addressShaped) {
          const email = normalizeEmail(person.email)
          const name = foldedHeaderDisplayName(email, candidates.get(email) ?? [])
          if (name === null || !isBetterDisplayNameForEmail(name, person.displayName, email)) {
            continue
          }
          person.displayName = name
          repaired.push(person)
        }
      }

      let refreshedConversationCount = 0
      if (repaired.length > 0) {
        await db.people.bulkPut(repaired)
        refreshedConversationCount = await refreshConversationTitles(
          db,
          await conversationIdsOfPeople(db, repaired),
          people,
          (title) => title.includes('@'),
        )
      }

      // Last write by design: it commits with the repaired rows or not at all.
      await db.syncState.put({ key: ADDRESS_SHAPED_PERSON_NAME_REPAIR_KEY, value: true })

      return {
        performed: true,
        recoveredPersonCount: repaired.length,
        unrecoveredPersonCount: addressShaped.length - repaired.length,
        refreshedConversationCount,
      }
    },
  )
}

/**
 * One-time repair for names stored with the wrapping quotes Outlook and
 * Exchange put around a name (`'Jacob Laycock' <…>`), from before
 * `sanitizeDisplayName` peeled them: Person rows, message participant rows,
 * and message sender names. The new value is exactly what ingestion now
 * stores for the same header. The titles of the conversations involved (those
 * of a peeled Person, or holding a message whose names were peeled) are
 * re-derived when they contain a quote; any other title cannot spell a quoted
 * name, and re-deriving it would swap the names it took from its first
 * message's headers for Person names.
 *
 * Idempotent: a peeled row no longer matches, so a re-run writes nothing.
 */
export async function peelQuoteWrappedDisplayNamesIfNeeded(
  db: ChatmailDB,
): Promise<QuoteWrappedDisplayNameRepairResult> {
  return db.transaction(
    'rw',
    [
      db.syncState,
      db.people,
      db.msgParticipants,
      db.messages,
      db.conversations,
      db.convoParticipants,
    ],
    async () => {
      const flag = await db.syncState.get(QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY)
      if (flag?.value === true) {
        return {
          performed: false,
          peeledPersonCount: 0,
          peeledParticipantCount: 0,
          peeledSenderNameCount: 0,
          refreshedConversationCount: 0,
        }
      }

      // Peeled in place, so the titles below are derived from the new names.
      const people = await db.people.toArray()
      const peeledPeople: PersonRow[] = []
      for (const person of people) {
        const peeled = peeledDisplayName(person.displayName)
        if (peeled === null) continue
        person.displayName = peeled
        peeledPeople.push(person)
      }

      const peeledParticipants = (
        await db.msgParticipants
          .filter((row) => peeledDisplayName(row.displayName) !== null)
          .toArray()
      ).map((row) => ({ ...row, displayName: stripWrappingQuotes(row.displayName) }))

      const peeledSenders = (
        await db.messages
          .filter((message) => peeledDisplayName(message.senderName) !== null)
          .toArray()
      ).map((message) => ({ ...message, senderName: stripWrappingQuotes(message.senderName) }))

      if (peeledPeople.length > 0) await db.people.bulkPut(peeledPeople)
      if (peeledParticipants.length > 0) await db.msgParticipants.bulkPut(peeledParticipants)
      if (peeledSenders.length > 0) await db.messages.bulkPut(peeledSenders)

      const conversationIds = await conversationIdsOfPeople(db, peeledPeople)
      for (const message of peeledSenders) conversationIds.add(message.conversationId)
      const participantMessages = await db.messages.bulkGet([
        ...new Set(peeledParticipants.map((row) => row.messageId)),
      ])
      for (const message of participantMessages) {
        if (message !== undefined) conversationIds.add(message.conversationId)
      }
      const refreshedConversationCount = await refreshConversationTitles(
        db,
        conversationIds,
        people,
        (title) => WRAPPING_QUOTE_OPENERS.some((opener) => title.includes(opener)),
      )

      // Last write by design: it commits with the peeled rows or not at all.
      await db.syncState.put({ key: QUOTE_WRAPPED_DISPLAY_NAME_REPAIR_KEY, value: true })

      return {
        performed: true,
        peeledPersonCount: peeledPeople.length,
        peeledParticipantCount: peeledParticipants.length,
        peeledSenderNameCount: peeledSenders.length,
        refreshedConversationCount,
      }
    },
  )
}

/**
 * `stored` with its wrapping quotes peeled, or null when it has none to peel
 * (an inner quote, or none at all), so the row is left untouched.
 */
function peeledDisplayName(stored: string): string | null {
  const peeled = stripWrappingQuotes(stored)
  return peeled === stored.trim() ? null : peeled
}

/**
 * `stored` as `sanitizeDisplayName` now stores it, or null when it holds no
 * encoded word or sanitizing leaves it as it is, so the row is left
 * untouched. A name without an encoded word is the other passes' to repair.
 */
function decodedDisplayName(stored: string): string | null {
  if (!containsEncodedWord(stored)) return null
  const decoded = sanitizeDisplayName(stored)
  return decoded === stored ? null : decoded
}

interface HeaderNameCandidate {
  name: string
  internalDate: number
  messageId: string
  /**
   * Orders the names one message offers the same address (a note to self
   * names its sender in From and To), so the fold does not depend on the
   * order the rows were read in.
   */
  kindRank: number
  /** Header order within one kind; participant rows are added in header order. */
  rowOrder: number
}

const KIND_RANK: Record<ParticipantKind, number> = { from: 0, to: 1, cc: 2, bcc: 3 }

/**
 * Normalized email -> the names stored participant rows offer it. Each row's
 * name is peeled first, as ingestion now stores it, and rows that offer no
 * name are dropped: an empty name, a Hide My Email label (iOS's recovery
 * rejects it too; it would also reclassify the address as a relay), or an
 * address. A row whose message is gone offers nothing.
 */
async function headerNameCandidates(
  db: ChatmailDB,
  emails: ReadonlySet<string>,
): Promise<Map<string, HeaderNameCandidate[]>> {
  const rows: MsgParticipantRow[] = await db.msgParticipants
    .filter((row) => emails.has(normalizeEmail(row.email)))
    .toArray()
  const messages = await db.messages.bulkGet([...new Set(rows.map((row) => row.messageId))])
  const dateByMessageId = new Map<string, number>()
  for (const message of messages) {
    if (message !== undefined) dateByMessageId.set(message.id, message.internalDate)
  }

  const candidates = new Map<string, HeaderNameCandidate[]>()
  for (const row of rows) {
    const internalDate = dateByMessageId.get(row.messageId)
    if (internalDate === undefined) continue
    const email = normalizeEmail(row.email)
    const name = stripWrappingQuotes(row.displayName)
    if (
      name === '' ||
      isHideMyEmailDisplayName(name) ||
      isEmailAddressShapedDisplayName(name, email)
    ) {
      continue
    }
    const candidate: HeaderNameCandidate = {
      name,
      internalDate,
      messageId: row.messageId,
      kindRank: KIND_RANK[row.kind],
      rowOrder: row.pk ?? 0,
    }
    const existing = candidates.get(email)
    if (existing === undefined) candidates.set(email, [candidate])
    else existing.push(candidate)
  }
  return candidates
}

/**
 * The best of `candidates`, folded newest-first through
 * `isBetterDisplayNameForEmail` from no name, so of two equally good names the
 * newer one wins. Null when there are none.
 */
function foldedHeaderDisplayName(
  email: string,
  candidates: readonly HeaderNameCandidate[],
): string | null {
  const newestFirst = [...candidates].sort(
    (a, b) =>
      b.internalDate - a.internalDate ||
      compareSwiftStrings(b.messageId, a.messageId) ||
      a.kindRank - b.kindRank ||
      a.rowOrder - b.rowOrder,
  )
  let winner: string | null = null
  for (const candidate of newestFirst) {
    if (isBetterDisplayNameForEmail(candidate.name, winner, email)) winner = candidate.name
  }
  return winner
}

/** Ids of the conversations `people` take part in. */
async function conversationIdsOfPeople(
  db: ChatmailDB,
  people: readonly PersonRow[],
): Promise<Set<string>> {
  if (people.length === 0) return new Set()
  const emails = new Set(people.map((person) => normalizeEmail(person.email)))
  const rows = await db.convoParticipants
    .filter((row) => emails.has(normalizeEmail(row.email)))
    .toArray()
  return new Set(rows.map((row) => row.conversationId))
}

/**
 * Re-derives the stored title of each of `conversationIds` that
 * `mayNeedRefresh` selects, from its participant rows and `people`, the way
 * the participant-set repair derives one. Returns how many titles changed.
 * A conversation without participant rows keeps its title.
 */
async function refreshConversationTitles(
  db: ChatmailDB,
  conversationIds: ReadonlySet<string>,
  people: readonly PersonRow[],
  mayNeedRefresh: (title: string) => boolean,
): Promise<number> {
  if (conversationIds.size === 0) return 0
  const names = personNames(people)
  const updated: ConversationRow[] = []
  for (const conversation of await db.conversations.bulkGet([...conversationIds])) {
    if (conversation === undefined || !mayNeedRefresh(conversation.displayName)) continue
    const rows = await db.convoParticipants
      .where('conversationId')
      .equals(conversation.id)
      .toArray()
    const participants = [
      ...new Set(rows.map((row) => normalizeEmail(row.email)).filter((email) => email !== '')),
    ].sort(compareSwiftStrings)
    if (participants.length === 0) continue
    const displayName = conversationDisplayName({ participants }, names)
    if (displayName !== conversation.displayName) updated.push({ ...conversation, displayName })
  }
  if (updated.length > 0) await db.conversations.bulkPut(updated)
  return updated.length
}
