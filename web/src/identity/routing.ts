// Conversation routing: which conversation row a message lands in.
// Port of ConversationRoutingPolicy.swift + the find-or-create half of
// ConversationCreationSerializer.swift / MessageConversationRouter.swift.

import { withConvoLock } from './creationLock'
import { isBetterDisplayNameForEmail } from './normalizeEmail'
import { newId } from '@/lib/uuid'
import type { ConversationIdentity } from './participantSet'
import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, ConvoParticipantRow, PersonRow } from '@/db/types'

/**
 * Whether an incoming message may reactivate an archived conversation epoch
 * instead of minting a new one: inbox arrivals and the user's own mail do.
 */
export function shouldReactivateArchivedConversation(
  labelIds: readonly string[],
  isFromMe: boolean,
): boolean {
  return labelIds.includes('INBOX') || isFromMe || labelIds.includes('SENT')
}

function conversationRecencyDate(row: ConversationRow): number {
  return row.lastMessageDate || row.latestInboxDate || row.archivedAt || 0
}

function mostRecent(rows: readonly ConversationRow[]): ConversationRow | null {
  let best: ConversationRow | null = null
  for (const row of rows) {
    // Strictly-greater keeps the earlier element on ties, matching Swift max(by:).
    if (best === null || conversationRecencyDate(row) > conversationRecencyDate(best)) {
      best = row
    }
  }
  return best
}

/**
 * Selects which same-participantHash conversation epoch to reuse. Active
 * conversations are always eligible (most recent wins); archived conversations
 * are only reused when the caller's message should reactivate them. Returns
 * null when a new epoch must be minted.
 */
export function selectParticipantHashConversation(
  candidates: readonly ConversationRow[],
  reactivateArchivedIfNeeded: boolean,
): ConversationRow | null {
  const active = mostRecent(candidates.filter((row) => row.isArchived === 0))
  if (active !== null) return active

  if (!reactivateArchivedIfNeeded) return null

  return mostRecent(candidates)
}

/** Inbox-indicator seed for a freshly created conversation shell (ConversationInboxSeed). */
export interface ResolveSeed {
  isInboxArrival: boolean
  isUnread: boolean
  /** Epoch ms of the message being routed; seeds lastMessageDate/latestInboxDate. */
  messageDate: number
  /** Optional row-preview seed (prevents a "No messages" flash). */
  snippet?: string
}

export interface ResolvedConversation {
  conversation: ConversationRow
  created: boolean
}

/**
 * Finds or creates the conversation for `identity`, serialized per
 * participantHash so concurrent arrivals cannot mint duplicate rows.
 *
 * On create the shell row is fully seeded (snippet, dates, inbox indicators,
 * display name, participants) because it is visible in the list before its
 * first message persists. On reuse of an archived epoch with
 * `reactivateArchivedIfNeeded`, the row is un-archived.
 */
export function resolveConversation(
  db: ChatmailDB,
  identity: ConversationIdentity,
  seed: ResolveSeed,
  reactivateArchivedIfNeeded: boolean,
): Promise<ResolvedConversation> {
  return withConvoLock(identity.participantHash, () =>
    db.transaction('rw', [db.conversations, db.convoParticipants, db.people], async () => {
      const candidates = await db.conversations
        .where('participantHash')
        .equals(identity.participantHash)
        .toArray()

      const existing = selectParticipantHashConversation(candidates, reactivateArchivedIfNeeded)
      if (existing !== null) {
        if (reactivateArchivedIfNeeded && existing.isArchived !== 0) {
          existing.archivedAt = 0
          existing.isArchived = 0
          await db.conversations.put(existing)
        }
        return { conversation: existing, created: false }
      }

      const conversation = createConversationShell(identity, seed)
      await db.conversations.add(conversation)
      await seedParticipants(db, conversation.id, identity)
      return { conversation, created: true }
    }),
  )
}

/**
 * Re-inserts a fully seeded conversation shell with a FIXED id inside an open
 * transaction. Used by the persist apply-tx to heal the resolve→apply race:
 * the conversation resolveConversation returned can be deleted (e.g. by a
 * failed-send rollback of a newly minted, still-empty conversation) before
 * the apply transaction runs; recreating the shell under the same id keeps
 * the about-to-be-inserted message reachable. The caller's transaction must
 * cover conversations, convoParticipants, and people.
 */
export async function reinsertConversationShell(
  db: ChatmailDB,
  id: string,
  identity: ConversationIdentity,
  seed: ResolveSeed,
): Promise<ConversationRow> {
  const conversation: ConversationRow = { ...createConversationShell(identity, seed), id }
  await db.conversations.add(conversation)
  await seedParticipants(db, conversation.id, identity)
  return conversation
}

function createConversationShell(
  identity: ConversationIdentity,
  seed: ResolveSeed,
): ConversationRow {
  const displayName = identity.participants
    .map((email) => identity.participantDisplayNames[email] ?? email)
    .join(', ')

  return {
    // newId(), not crypto.randomUUID: the latter is secure-context-only.
    id: newId(),
    keyHash: identity.keyHash,
    participantHash: identity.participantHash,
    type: identity.type,
    displayName,
    snippet: seed.snippet ?? '',
    lastMessageDate: seed.messageDate,
    latestInboxDate: seed.isInboxArrival ? seed.messageDate : 0,
    hasInbox: seed.isInboxArrival ? 1 : 0,
    inboxUnreadCount: seed.isInboxArrival && seed.isUnread ? 1 : 0,
    pinned: 0,
    muted: 0,
    archivedAt: 0,
    isArchived: 0,
    createdAt: Date.now(),
  }
}

async function seedParticipants(
  db: ChatmailDB,
  conversationId: string,
  identity: ConversationIdentity,
): Promise<void> {
  const participantRows: ConvoParticipantRow[] = identity.participants.map((email) => ({
    conversationId,
    email,
    role: 'normal',
  }))
  await db.convoParticipants.bulkPut(participantRows)

  // Person find-or-create, mirroring PersonFactory: create missing people and
  // upgrade display names that are better than what is stored.
  for (const email of identity.participants) {
    const displayName = identity.participantDisplayNames[email]
    const existing = await db.people.get(email)
    if (existing === undefined) {
      const person: PersonRow = { email, displayName: displayName ?? '' }
      await db.people.put(person)
    } else if (
      displayName !== undefined &&
      isBetterDisplayNameForEmail(displayName, existing.displayName, email)
    ) {
      await db.people.put({ email, displayName })
    }
  }
}
