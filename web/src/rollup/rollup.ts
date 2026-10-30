// Conversation rollup: the single authority for derived conversation-list
// fields and the archive state machine.
//
// Ports of:
// - ConversationRollupSnapshot.swift (makeRollup / applyRollup)
// - ConversationRoutingPolicy.applyArchiveState (archive state machine)
// - MessagePreviewText.conversationPreview (Message+Extensions.swift) for the
//   per-message list preview.
// - ConversationRollupUpdater.updateDisplayNameOnly (upgradedConversationTitle)
//   for the title re-derivation that ends every rollup.
//
// Deviation from iOS: the web schema has no separate `hidden` flag — the
// isArchived mirror of archivedAt covers list filtering, so hidden=true maps
// to isArchived=1 and hidden=false to isArchived=0.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, ConvoParticipantRow, MessageRow, PersonRow } from '@/db/types'
import {
  isAddressDerivedDisplayName,
  isEmailAddressShapedDisplayName,
  isHideMyEmailDisplayName,
  normalizeEmail,
} from '@/identity/normalizeEmail'
import { compareSwiftStrings } from '@/identity/participantSet'
import { createCleanSnippet, isForwardedSubject } from '@/mime/preview'
import { conversationDisplayName, personNames } from '@/sync/participantSetRepair'

/** Messages carrying any of these labels are invisible to the rollup. */
export const EXCLUDED_MAILBOX_LABEL_IDS: ReadonlySet<string> = new Set(['SPAM', 'DRAFT', 'TRASH'])

export interface Rollup {
  /** Epoch ms of the latest visible message; 0 when there is none. */
  lastMessageDate: number
  /**
   * conversationPreview of the newest visible message whose preview is
   * non-empty; '' when no visible message has one. Already trimmed.
   */
  snippet: string
  hasInbox: boolean
  inboxUnreadCount: number
  /** Epoch ms of the latest INBOX message; 0 when there is none. */
  latestInboxDate: number
  hasSentOrFromMe: boolean
  hasReceived: boolean
  latestVisibleMessageIsOutgoing: boolean
  isSentOnlyConversation: boolean
}

function nonEmpty(text: string | null | undefined): string | null {
  if (text === null || text === undefined) return null
  const trimmed = text.trim()
  return trimmed === '' ? null : trimmed
}

const FORWARD_PREFIX_RE = /^\s*(?:fwd|fw)\s*:\s*/i

/**
 * Strips repeated leading "Fwd:"/"Fw:" prefixes. Falls back to the original
 * subject when stripping would leave nothing.
 */
export function normalizedForwardSubject(subject: string): string {
  let normalized = subject
  for (;;) {
    const stripped = normalized.replace(FORWARD_PREFIX_RE, '')
    if (stripped === normalized) break
    normalized = stripped
  }
  const trimmed = normalized.trim()
  return trimmed === '' ? subject : trimmed
}

/**
 * One-line conversation-list preview for a message. Port of
 * MessagePreviewText.conversationPreview: forwarded subjects render as
 * `Fwd: "<subject>"`, newsletters use the subject, everything else falls back
 * through cleanedSnippet -> compacted chatPreviewText -> snippet -> subject.
 * Returns '' when no candidate has content.
 */
export function conversationPreview(message: MessageRow): string {
  const subject = nonEmpty(message.subject)

  if (isForwardedSubject(message.subject) && subject !== null) {
    return `Fwd: "${normalizedForwardSubject(subject)}"`
  }

  if (message.isNewsletter === 1 && subject !== null) {
    return subject
  }

  return (
    nonEmpty(message.cleanedSnippet) ??
    nonEmpty(createCleanSnippet(message.chatPreviewText, Number.POSITIVE_INFINITY, false)) ??
    nonEmpty(message.snippet) ??
    subject ??
    ''
  )
}

function isVisibleMessage(labelIds: readonly string[]): boolean {
  return !labelIds.some((id) => EXCLUDED_MAILBOX_LABEL_IDS.has(id))
}

function isOutgoing(message: MessageRow): boolean {
  return message.isFromMe === 1 || message.labelIds.includes('SENT')
}

/** Computes the derived rollup fields from a conversation's full message set. */
export function makeRollup(messages: readonly MessageRow[]): Rollup {
  let latestVisible: MessageRow | null = null
  let latestVisiblePreview: MessageRow | null = null
  let latestVisiblePreviewText = ''
  let hasInbox = false
  let latestInboxDate = 0
  let inboxUnreadCount = 0
  let hasSentOrFromMe = false
  let hasReceived = false

  for (const message of messages) {
    if (isVisibleMessage(message.labelIds)) {
      if (latestVisible === null || message.internalDate > latestVisible.internalDate) {
        latestVisible = message
      }
      if (
        latestVisiblePreview === null ||
        message.internalDate > latestVisiblePreview.internalDate
      ) {
        const preview = conversationPreview(message)
        if (preview !== '') {
          latestVisiblePreview = message
          latestVisiblePreviewText = preview
        }
      }
    }

    if (message.labelIds.includes('INBOX')) {
      hasInbox = true
      if (message.isUnread === 1) {
        inboxUnreadCount += 1
      }
      if (message.internalDate > latestInboxDate) {
        latestInboxDate = message.internalDate
      }
    }

    if (isOutgoing(message)) {
      hasSentOrFromMe = true
    }
    if (message.isFromMe === 0) {
      hasReceived = true
    }
  }

  const latestVisibleMessageIsOutgoing = latestVisible !== null && isOutgoing(latestVisible)

  return {
    lastMessageDate: latestVisible?.internalDate ?? 0,
    snippet: latestVisiblePreviewText,
    hasInbox,
    inboxUnreadCount,
    latestInboxDate,
    hasSentOrFromMe,
    hasReceived,
    latestVisibleMessageIsOutgoing,
    isSentOnlyConversation: hasSentOrFromMe && !hasReceived && !hasInbox,
  }
}

/**
 * Archive state machine (ConversationRoutingPolicy.applyArchiveState), pure:
 * - any INBOX message unarchives;
 * - sent-only conversations and conversations whose latest visible message is
 *   outgoing keep their current archive state;
 * - everything else auto-archives (at `now`) if currently active.
 */
export function applyArchiveState(
  conversation: ConversationRow,
  rollup: Rollup,
  now: number,
): ConversationRow {
  if (rollup.hasInbox) {
    if (conversation.archivedAt === 0 && conversation.isArchived === 0) return conversation
    return { ...conversation, archivedAt: 0, isArchived: 0 }
  }

  if (rollup.isSentOnlyConversation) {
    return conversation
  }

  if (rollup.latestVisibleMessageIsOutgoing) {
    return conversation
  }

  if (conversation.archivedAt === 0) {
    return { ...conversation, archivedAt: now, isArchived: 1 }
  }
  return conversation
}

/**
 * Applies a rollup to a conversation row (pure — returns an updated copy).
 * Mirrors ConversationRollupSnapshot.apply: derived fields are overwritten,
 * snippet is cleared when no visible message remains, and the archive state
 * machine runs last. Idempotent: applying the same rollup twice (with any
 * `now`) equals applying it once.
 */
export function applyRollup(
  conversation: ConversationRow,
  rollup: Rollup,
  now: number,
): ConversationRow {
  const updated: ConversationRow = {
    ...conversation,
    lastMessageDate: rollup.lastMessageDate,
    snippet: rollup.lastMessageDate === 0 ? '' : rollup.snippet,
    hasInbox: rollup.hasInbox ? 1 : 0,
    inboxUnreadCount: rollup.inboxUnreadCount,
    latestInboxDate: rollup.latestInboxDate,
  }
  return applyArchiveState(updated, rollup, now)
}

/**
 * A stored Person name that stands for the person rather than for the
 * address (PersonDisplayNameResolver.sanitizedRealDisplayName): non-empty,
 * not a Hide My Email label, and neither the address itself nor a
 * re-formatting of its local part. An address-shaped name counts as the
 * address: the stored-name repair (displayNameRepair.ts) owns recovering a
 * real name for it, and the title must not change under that pass.
 */
function isRealPersonName(name: string | undefined, email: string): boolean {
  const trimmed = name?.trim()
  if (trimmed === undefined || trimmed === '') return false
  return (
    !isHideMyEmailDisplayName(trimmed) &&
    !isAddressDerivedDisplayName(trimmed, email) &&
    !isEmailAddressShapedDisplayName(trimmed, email)
  )
}

/**
 * The title a rollup writes over `stored`, or null to keep it. Port of
 * ConversationRollupUpdater.updateDisplayNameOnly for participant-keyed
 * conversations: the title is rebuilt from the conversation's participants
 * and the stored Person names on every rollup, so a chat created from a bare
 * `alice@example.com` header reads "Alice Smith" once any header names her,
 * and a new chat with someone already known by name starts with that name.
 * Only ever an upgrade: with no real name among the participants the stored
 * title stays (iOS keeps the stored title as the fallback rather than
 * downgrading it to joined addresses), and a rebuilt title equal to the
 * stored one is not rewritten. The rebuilt title is
 * participantSetRepair.conversationDisplayName's, so this, the participant-set
 * repair and the stored-name repairs never disagree on one conversation.
 * `participants` are normalized emails; the result sorts them the way the
 * repairs do.
 */
export function upgradedConversationTitle(
  stored: string,
  participants: readonly string[],
  names: ReadonlyMap<string, string>,
): string | null {
  const sorted = [
    ...new Set(participants.map((email) => normalizeEmail(email)).filter((email) => email !== '')),
  ].sort(compareSwiftStrings)
  if (sorted.length === 0) return null
  if (!sorted.some((email) => isRealPersonName(names.get(email), email))) return null
  const rebuilt = conversationDisplayName({ participants: sorted }, names)
  return rebuilt === stored ? null : rebuilt
}

/**
 * Recomputes and persists the rollup for one conversation, ending with the
 * title re-derivation (iOS runs updateDisplayNameOnly at the end of every
 * updateRollups).
 *
 * Runs its own 'rw' transaction when called standalone; when called inside
 * an existing db.transaction, Dexie nests it into the outer transaction, so
 * callers batching per-page saves get one atomic write. That outer
 * transaction must cover all four tables named here (messages, conversations,
 * convoParticipants, people): Dexie refuses a nested transaction naming a
 * table the parent lacks, and reading the title's inputs beside the parent
 * instead (Dexie.ignoreTransaction + waitFor) deadlocked under the test
 * suite's parallel load when another transaction held the store. All compute
 * here is synchronous (no non-Dexie awaits), so the transaction cannot
 * auto-commit early.
 */
export async function rollupConversation(
  db: ChatmailDB,
  conversationId: string,
  now: number,
): Promise<void> {
  await db.transaction(
    'rw',
    [db.messages, db.conversations, db.convoParticipants, db.people],
    async () => {
      const [messages, conversation] = await Promise.all([
        db.messages
          .where('[conversationId+internalDate]')
          .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
          .toArray(),
        db.conversations.get(conversationId),
      ])
      if (conversation === undefined) return

      const rolled = applyRollup(conversation, makeRollup(messages), now)
      const displayName = await rolledConversationTitle(db, rolled)
      await db.conversations.put(displayName === null ? rolled : { ...rolled, displayName })
    },
  )
}

/**
 * upgradedConversationTitle over the conversation's stored participant rows
 * and their Person rows. A conversation without participant rows keeps its
 * title, as does one carrying a list address: its title is not
 * participant-derived (web persists no list conversations today; the guard
 * mirrors iOS, where only the identifier-derived upgrade touches a list).
 */
async function rolledConversationTitle(
  db: ChatmailDB,
  conversation: ConversationRow,
): Promise<string | null> {
  const rows: ConvoParticipantRow[] = await db.convoParticipants
    .where('conversationId')
    .equals(conversation.id)
    .toArray()
  if (rows.length === 0 || rows.some((row) => row.role === 'listAddress')) return null
  const participants = [
    ...new Set(rows.map((row) => normalizeEmail(row.email)).filter((email) => email !== '')),
  ]
  const people: Array<PersonRow | undefined> = await db.people.bulkGet(participants)
  const names = personNames(people.filter((person): person is PersonRow => person !== undefined))
  return upgradedConversationTitle(conversation.displayName, participants, names)
}
