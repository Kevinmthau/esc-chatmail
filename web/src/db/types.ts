// Row types for the Dexie schema. Ported from the iOS Core Data model
// (esc-chatmail/Models/CoreData/ESCChatmail.xcdatamodeld).
//
// IndexedDB cannot index booleans or null/undefined, so every indexed flag is
// 0 | 1 and every indexed optional date uses 0 as the "absent" sentinel.

export type Flag = 0 | 1

export type ConversationType = 'oneToOne' | 'group'

export type ParticipantRole = 'normal' | 'me' | 'listAddress'

export type ParticipantKind = 'from' | 'to' | 'cc' | 'bcc'

export type AttachmentState = 'queued' | 'uploading' | 'uploaded' | 'failed' | 'downloaded'

export type PendingActionType =
  'markRead' | 'markUnread' | 'archive' | 'archiveConversation' | 'star' | 'unstar' | 'reportSpam'

export type PendingActionStatus = 'pending' | 'processing' | 'failed' | 'completed' | 'abandoned'

export interface AccountRow {
  /** Primary key: the account's email address. */
  email: string
  /** Gmail incremental-sync cursor. Absent/'' means initial sync has not completed. */
  historyId: string
  /** Normalized self addresses (identity set: profile + sendAs + extras). */
  aliases: string[]
  /** Send-as aliases as returned by settings/sendAs, filtered to usable ones. */
  sendAsAliases: SendAsAlias[]
  /** Epoch ms of first sign-in on this device; backfill covers mail after this. */
  installTs: number
  sendAsRefreshedAt: number
}

export interface SendAsAlias {
  email: string
  displayName: string
  isDefault: boolean
  isPrimary: boolean
  verificationStatus: string
}

export interface ConversationRow {
  /** Primary key: locally generated UUID. */
  id: string
  /** SHA256("p|<sorted participants>|<uuid>") — unique per conversation epoch. */
  keyHash: string
  /** SHA256("p|<sorted participants>") — the routing key shared across epochs. */
  participantHash: string
  type: ConversationType
  // Derived (rollup-owned) fields:
  displayName: string
  snippet: string
  /** Epoch ms of latest visible message; 0 when none. Primary sort key. */
  lastMessageDate: number
  /** Epoch ms of latest INBOX message; 0 when none. */
  latestInboxDate: number
  hasInbox: Flag
  inboxUnreadCount: number
  // User state:
  pinned: Flag
  muted: Flag
  /** 0 = active. Non-zero epoch ms = archived; new mail mints a new epoch row. */
  archivedAt: number
  /** Mirror of archivedAt !== 0 for compound indexes. */
  isArchived: Flag
  createdAt: number
}

export interface MessageRow {
  /** Primary key: Gmail message id, or a local UUID for optimistic sends. */
  id: string
  conversationId: string
  gmThreadId: string
  /** RFC 2822 Message-ID header (angle brackets included, as Gmail returns it). */
  rfcMessageId: string
  /** Space-joined References header chain. */
  references: string
  /** Epoch ms from Gmail internalDate. */
  internalDate: number
  subject: string
  snippet: string
  /** Quote/signature-stripped plain text for list previews. */
  cleanedSnippet: string
  /** Chat-bubble-oriented preview text. */
  chatPreviewText: string
  /** Plain-text body (or text extracted from HTML), capped for fallback use. */
  bodyText: string
  /** 1 when an HTML body exists in the bodies table. */
  hasHtmlBody: Flag
  senderEmail: string
  senderName: string
  /** Which of the user's aliases this was delivered to (resolver output). */
  deliveredToAddress: string
  /** Which alias a reply should be sent from (resolver output). */
  replyFromAddress: string
  isFromMe: Flag
  isUnread: Flag
  isNewsletter: Flag
  hasAttachments: Flag
  /** Gmail label ids; multiEntry-indexed. */
  labelIds: string[]
  /**
   * Epoch ms of the last local user mutation (read/star/archive). Server writes
   * must not clobber label/unread state while this is fresher than 30 minutes.
   * 0 when clear.
   */
  localModifiedAt: number
  sendState?: 'pending' | 'sent' | 'failed'
}

export interface BodyRow {
  /** Primary key — matches MessageRow.id (moved on optimistic id swap). */
  messageId: string
  html: string
}

export interface PersonRow {
  /** Primary key: normalized email. */
  email: string
  displayName: string
}

export interface ConvoParticipantRow {
  /** Compound primary key [conversationId+email]. */
  conversationId: string
  /** Normalized email. */
  email: string
  role: ParticipantRole
}

export interface MsgParticipantRow {
  /** Auto-increment primary key. */
  pk?: number
  messageId: string
  /** Normalized email. */
  email: string
  /** Raw display name from the header, '' when absent. */
  displayName: string
  kind: ParticipantKind
}

export interface LabelRow {
  /** Primary key: Gmail label id (e.g. "INBOX"). */
  id: string
  name: string
}

export interface AttachmentRow {
  /**
   * Primary key: `${messageId}:${partId}` for server parts, or
   * `local_inline_<sha256[0..16]>` for inline data parts, or `local_<uuid>` for
   * outbound attachments.
   */
  id: string
  messageId: string
  /** Gmail attachmentId used with the attachments endpoint; '' for inline/local. */
  gmailAttachmentId: string
  /** Content-ID with angle brackets stripped; '' when absent. */
  contentId: string
  filename: string
  mimeType: string
  byteSize: number
  width: number
  height: number
  state: AttachmentState
  lastDownloadFailedAt: number
}

export interface BlobRow {
  /** Primary key — usually an AttachmentRow.id. */
  key: string
  blob: Blob
  byteSize: number
  lastAccessAt: number
}

export interface PendingActionRow {
  /** Auto-increment primary key. */
  id?: number
  actionType: PendingActionType
  status: PendingActionStatus
  /** Single-message actions; '' for batch/conversation actions. */
  messageId: string
  conversationId: string
  /** Batch actions carry the affected message ids. */
  messageIds: string[]
  retryCount: number
  createdAt: number
  lastAttempt: number
}

/**
 * Durable journal for optimistic sends (port of OutboundSendMutationRecord).
 * remoteCommitted* are written the moment Gmail accepts the send — before local
 * reconciliation — so a crash in between is recoverable at startup.
 */
export interface OutboundSendRow {
  /** Primary key: the optimistic message UUID. */
  id: string
  conversationId: string
  newlyInsertedConversation: Flag
  createdAt: number
  status: 'pending' | 'committed' | 'finalized' | 'failed'
  /** Snapshot of conversation fields to restore if the send fails. */
  conversationSnapshot: {
    archivedAt: number
    isArchived: Flag
    displayName: string
    lastMessageDate: number
    snippet: string
  } | null
  remoteCommittedMessageId: string
  remoteCommittedThreadId: string
}

export interface AbandonedMessageRow {
  /** Primary key: the Gmail message id the fetcher gave up on. */
  gmailMessageId: string
  abandonedAt: number
  reason: string
  retryCount: number
}

export interface SyncStateRow {
  /** Primary key. */
  key: string
  value: unknown
}
