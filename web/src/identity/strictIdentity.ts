// Port of esc-chatmail/Services/Conversation/Message+ParticipantSetIdentity.swift.
// Strict participant-set identity derived from persisted MsgParticipant rows.

import { isHideMyEmailDisplayName, normalizeEmail } from './normalizeEmail'
import { makeParticipantSetIdentity, type ParticipantSetIdentity } from './participantSet'
import type { MsgParticipantRow } from '@/db/types'

/**
 * Mirrors the header path's participant extraction — From+To+Cc, BCC excluded,
 * self-aliases removed, same deterministic self-only fallback — via the shared
 * `makeParticipantSetIdentity` core. Both paths must produce identical hashes
 * or migrated and freshly-synced messages fork into duplicate chats.
 *
 * Returns null when the message has no participant rows at all. A row-less
 * message's recipient set is unknowable — `senderEmail` alone cannot
 * reconstruct To/Cc, and for the user's own sent messages (whose rows were
 * never written on the optimistic-send reconciliation path) it would collapse
 * them into the note-to-self chat. Such messages must not be re-homed.
 *
 * @param senderEmail Stored un-normalized; only supplements a legacy row set
 *   that lacks a 'from' row. Pass '' when absent.
 * @param personDisplayNames Normalized email -> current person display name
 *   (i.e. db.people). iOS's Hide-My-Email check reads the live, enrichable
 *   Person record (`participant.person?.displayName`), NOT the header name
 *   frozen on the participant row, so the strict derivation must consult the
 *   same enriched name or the two platforms key HME mail differently.
 */
export function strictParticipantSetIdentity(
  msgParticipants: readonly MsgParticipantRow[],
  senderEmail: string,
  myAliases: ReadonlySet<string>,
  personDisplayNames: ReadonlyMap<string, string>,
): ParticipantSetIdentity | null {
  const emails = new Set<string>()
  let hasFromRow = false
  let hasIdentityRow = false

  for (const participant of msgParticipants) {
    // BCC is excluded from identity, matching the header path.
    if (participant.kind === 'bcc') continue
    hasIdentityRow = true
    if (participant.kind === 'from') {
      hasFromRow = true
      // The header path drops a From whose display name is a Hide-My-Email
      // placeholder; mirror it here so both derivations key HME mail the same
      // way. Like iOS, test the person's CURRENT display name (which can have
      // been enriched since the row was written); fall back to the frozen row
      // name only when no person row exists — on web the email lives on the
      // row, so a missing person must not drop the participant the way iOS's
      // `guard let person` does.
      const personName = personDisplayNames.get(normalizeEmail(participant.email))
      if (isHideMyEmailDisplayName(personName ?? participant.displayName)) continue
    }
    // Row emails are normalized at write time; re-normalizing is idempotent.
    const normalized = normalizeEmail(participant.email)
    if (normalized !== '') emails.add(normalized)
  }

  if (!hasIdentityRow) return null

  if (!hasFromRow && senderEmail !== '') {
    const normalized = normalizeEmail(senderEmail)
    if (normalized !== '') emails.add(normalized)
  }

  if (emails.size === 0) return null
  return makeParticipantSetIdentity(emails, myAliases)
}
