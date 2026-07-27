// Conversation rollup: the single authority for derived conversation-list
// fields and the archive state machine.
//
// Ports of:
// - ConversationRollupSnapshot.swift (makeRollup / applyRollup)
// - ConversationRoutingPolicy.applyArchiveState (archive state machine)
// - MessagePreviewText.conversationPreview (Message+Extensions.swift) for the
//   per-message list preview.
//
// Deviation from iOS: the web schema has no separate `hidden` flag — the
// isArchived mirror of archivedAt covers list filtering, so hidden=true maps
// to isArchived=1 and hidden=false to isArchived=0.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow } from '@/db/types'
import { createCleanSnippet, isForwardedSubject } from '@/mime/preview'

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
 * Recomputes and persists the rollup for one conversation.
 *
 * Runs its own 'rw' transaction over messages+conversations when called
 * standalone; when called inside an existing db.transaction whose table set
 * includes messages and conversations, Dexie nests it into the outer
 * transaction automatically, so callers batching per-page saves get one
 * atomic write. All compute here is synchronous (no non-Dexie awaits), so the
 * transaction cannot auto-commit early.
 */
export async function rollupConversation(
  db: ChatmailDB,
  conversationId: string,
  now: number,
): Promise<void> {
  await db.transaction('rw', db.messages, db.conversations, async () => {
    const [messages, conversation] = await Promise.all([
      db.messages
        .where('[conversationId+internalDate]')
        .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
        .toArray(),
      db.conversations.get(conversationId),
    ])
    if (conversation === undefined) return

    await db.conversations.put(applyRollup(conversation, makeRollup(messages), now))
  })
}
