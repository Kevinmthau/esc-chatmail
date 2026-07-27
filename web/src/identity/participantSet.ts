// Port of esc-chatmail/Services/Conversation/ConversationIdentity.swift.
// CANONICAL participant-set derivation shared by the sync router, the
// compose/optimistic-send path, and migrations. The hashes produced here are a
// cross-platform contract with iOS — see the hard-coded vectors in
// participantSet.test.ts.

import { sha256Hex } from './hash'
import { normalizeEmail } from './normalizeEmail'
import { newId } from '@/lib/uuid'
import type { ConversationType } from '@/db/types'

/**
 * The participant-set core of a conversation identity: the sorted,
 * self-excluded participant list and its canonical hash, without the
 * per-instance keyHash/epoch parts.
 */
export interface ParticipantSetIdentity {
  /** Sorted, normalized, aliases removed (or self-fallback). */
  participants: string[]
  participantHash: string
  type: ConversationType
}

export interface ConversationIdentity {
  /** "p|<sorted participants>|<uuid>" — unique per conversation instance. */
  key: string
  /** SHA256 hex of key (unique per conversation instance/epoch). */
  keyHash: string
  /** SHA256 hex of the participant key (same for all convos with same people). */
  participantHash: string
  type: ConversationType
  /** Normalized emails, excluding "me". */
  participants: string[]
  /** Normalized email -> display name. */
  participantDisplayNames: Record<string, string>
}

/**
 * String ordering parity with Swift's `String` `<` — the comparator behind
 * `participants.sorted()` in ConversationIdentity.swift. Swift compares
 * canonically-equivalent (NFC-normalized) Unicode scalar values, while the JS
 * default sort compares raw UTF-16 code units. The two diverge only for
 * strings containing astral characters (whose surrogate code units order
 * before U+E000..U+FFFF) or non-NFC sequences (e.g. combining accents); for
 * pure-ASCII input — every realistic normalized email — the order is
 * byte-identical, so the hard-coded ASCII parity vectors are unaffected.
 * Exported for tests.
 */
export function compareSwiftStrings(a: string, b: string): number {
  if (a === b) return 0
  const result = compareCodePoints(a.normalize('NFC'), b.normalize('NFC'))
  if (result !== 0) return result
  // Canonically-equivalent but byte-different strings compare equal in Swift
  // (Set/sort order there is unspecified); tie-break on raw code points so
  // the web sort stays deterministic.
  return compareCodePoints(a, b)
}

function compareCodePoints(a: string, b: string): number {
  let i = 0
  while (i < a.length && i < b.length) {
    // `?? 0` is unreachable: `i` always indexes a valid unit.
    const ca = a.codePointAt(i) ?? 0
    const cb = b.codePointAt(i) ?? 0
    if (ca !== cb) return ca < cb ? -1 : 1
    // Equal code points advance both strings by the same number of units.
    i += ca > 0xffff ? 2 : 1
  }
  if (a.length === b.length) return 0
  return a.length < b.length ? -1 : 1
}

/**
 * Calculates the participant hash from participant emails.
 * CANONICAL IMPLEMENTATION — use this everywhere, do not duplicate.
 * @param participants Normalized emails (the user's aliases already excluded).
 */
export function calculateParticipantHash(participants: readonly string[]): string {
  return sha256Hex(`p|${[...participants].sort(compareSwiftStrings).join('|')}`)
}

/**
 * Derives the participant-set identity for a message's people.
 * @param normalizedEmails From+To+Cc addresses already normalized via
 *   `normalizeEmail`, with BCC and Hide-My-Email entries excluded.
 * @param myAliases Normalized self addresses to exclude from the set.
 */
export function makeParticipantSetIdentity(
  normalizedEmails: ReadonlySet<string>,
  myAliases: ReadonlySet<string>,
): ParticipantSetIdentity {
  const parts = [...normalizedEmails].filter((email) => !myAliases.has(email))

  let participants: string[]
  if (parts.length === 0) {
    // Self-conversation: deterministic alias selection (sorted order).
    const firstAlias = [...myAliases].sort(compareSwiftStrings)[0]
    const firstEmail = [...normalizedEmails].sort(compareSwiftStrings)[0]
    if (firstAlias !== undefined) {
      participants = [firstAlias]
    } else if (firstEmail !== undefined) {
      participants = [firstEmail]
    } else {
      participants = ['unknown@email.com']
    }
  } else {
    participants = parts.sort(compareSwiftStrings)
  }

  return {
    participants,
    participantHash: calculateParticipantHash(participants),
    type: participants.length <= 1 ? 'oneToOne' : 'group',
  }
}

/**
 * Compose-side participant-set identity for a raw recipient list.
 * Returns null when no recipient yields a usable normalized address.
 */
export function makeRecipientParticipantSetIdentity(
  recipients: readonly string[],
  myAliases: ReadonlySet<string>,
): ParticipantSetIdentity | null {
  const normalized = new Set(recipients.map(normalizeEmail).filter((email) => email !== ''))
  if (normalized.size === 0) return null
  return makeParticipantSetIdentity(normalized, myAliases)
}

/**
 * Builds a full per-instance ConversationIdentity (fresh keyHash epoch) from a
 * participant-set identity. The keyHash embeds a UUID so multiple conversation
 * epochs can exist for the same participantHash (archived vs active).
 *
 * The UUID comes from `newId()`, not `crypto.randomUUID` — the latter is
 * secure-context-only and would throw on a plain-http LAN origin. The epoch id
 * only has to be unique, never unguessable; `participantHash` (the
 * cross-platform contract) is untouched by it.
 */
export function makeConversationIdentity(
  setIdentity: ParticipantSetIdentity,
  displayNames: Record<string, string> = {},
): ConversationIdentity {
  const participantKey = `p|${setIdentity.participants.join('|')}`
  const uniqueKey = `${participantKey}|${newId()}`

  return {
    key: uniqueKey,
    keyHash: sha256Hex(uniqueKey),
    participantHash: setIdentity.participantHash,
    type: setIdentity.type,
    participants: setIdentity.participants,
    participantDisplayNames: displayNames,
  }
}
