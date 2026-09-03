import type { ChatmailDB } from '@/db/schema'
import { extractEmail, isHideMyEmailDisplayName, normalizeEmail } from './normalizeEmail'
import { makeRecipientParticipantSetIdentity, type ParticipantSetIdentity } from './participantSet'

/**
 * Compose/search identity with the same cached Hide-My-Email exclusions used
 * by sync persistence. Only the addressed Person rows are read, keeping this
 * cheap enough for recipient lookup while still catching relays learned from
 * earlier messages.
 */
export async function makeStoredRecipientParticipantSetIdentity(
  db: ChatmailDB,
  recipients: readonly string[],
  myAliases: ReadonlySet<string>,
): Promise<ParticipantSetIdentity | null> {
  const normalizedRecipients = [
    ...new Set(
      recipients
        .map((recipient) => normalizeEmail(extractEmail(recipient) ?? recipient))
        .filter((email) => email !== ''),
    ),
  ]
  if (normalizedRecipients.length === 0) return null

  const people = await db.people.bulkGet(normalizedRecipients)
  const hideMyEmailAddresses = new Set(
    people
      .filter((person) => isHideMyEmailDisplayName(person?.displayName))
      .map((person) => normalizeEmail(person?.email ?? ''))
      .filter((email) => email !== ''),
  )
  return makeRecipientParticipantSetIdentity(recipients, myAliases, hideMyEmailAddresses)
}
