// Message persistence: async compute phase producing plain PersistPlan
// objects, then Dexie-only apply transactions. Port of MessagePersister*
// (Services/Sync/Persistence/) on the PersistPlan pattern: no network, crypto
// or parsing inside a transaction.

import Dexie from 'dexie'
import { BlobQuotaExceededError, putBlob } from '@/db/blobs'
import type { ChatmailDB } from '@/db/schema'
import type {
  AttachmentRow,
  ConversationRow,
  MessageRow,
  MsgParticipantRow,
  ParticipantKind,
  SendAsAlias,
} from '@/db/types'
import type { GmailHeader, GmailMessage, GmailPart } from '@/gmail/types'
import { isBetterDisplayNameForEmail, isHideMyEmailDisplayName } from '@/identity/normalizeEmail'
import {
  makeConversationIdentity,
  makeParticipantSetIdentity,
  type ConversationIdentity,
} from '@/identity/participantSet'
import {
  reinsertConversationShell,
  resolveConversation,
  shouldReactivateArchivedConversation,
  type ResolveSeed,
} from '@/identity/routing'
import { calculateNewsletterScore } from '@/mime/newsletter'
import {
  parseEmailAddresses,
  parseGmailMessage,
  type ParsedAddress,
  type ParsedHeaders,
  type ParseGmailMessageOptions,
} from '@/mime/parse'
import { createChatPreviewText, createCleanedSnippet, isForwardedSubject } from '@/mime/preview'
import { conversationPreview, EXCLUDED_MAILBOX_LABEL_IDS } from '@/rollup/rollup'
import { mapWithConcurrency } from './concurrency'
import { resolveReplyFrom, type ReplyFromHeaders } from './replyFrom'

/**
 * The localModifiedAt conflict window: server label/unread writes are skipped
 * while a local user mutation is fresher than this (SyncConfig
 * .maxLocalModificationAge — the entire conflict model).
 */
export const LOCAL_MODIFICATION_MAX_AGE_MS = 30 * 60 * 1000

export interface PersistContext {
  /** Normalized identity aliases (self-removal from participant sets, isFromMe). */
  myAliases: ReadonlySet<string>
  /** Sendable aliases feeding reply-from resolution. */
  sendAsAliases: readonly SendAsAlias[]
  /**
   * Label ids from a successful labels fetch, used to scope label writes.
   * null OR empty means "lookup failed", NOT "no labels": message labels are
   * then applied as-is (iOS gotcha carried over verbatim).
   */
  knownLabelIds: ReadonlySet<string> | null
  fetchLargeBody?: ParseGmailMessageOptions['fetchLargeBody']
}

export interface PlannedAttachment {
  row: Omit<AttachmentRow, 'messageId'>
  /** Decoded bytes for inline data parts; stored in blobs at apply time. */
  inlineData: Uint8Array | null
}

export interface MessagePersistPlan {
  kind: 'message'
  /** conversationId is '' until apply resolves the conversation. */
  message: MessageRow
  bodyHtml: string | null
  participants: Array<Omit<MsgParticipantRow, 'pk' | 'messageId'>>
  /** Person upserts (normalized email → best display name seen, '' if none). */
  people: Array<{ email: string; displayName: string }>
  attachments: PlannedAttachment[]
  /** Fresh-epoch identity; used only if a new conversation must be minted. */
  identity: ConversationIdentity
  reactivateArchived: boolean
}

export type PersistPlan =
  | { kind: 'excluded'; id: string; label: string }
  | { kind: 'unprocessable'; id: string }
  | MessagePersistPlan

export interface PersistApplyResult {
  /** Conversations whose derived state may be stale (need a rollup). */
  touchedConversationIds: Set<string>
  /** Message ids present in the store after apply (created or updated). */
  persistedMessageIds: Set<string>
  /** Message ids deleted locally because they live in an excluded mailbox. */
  deletedMessageIds: Set<string>
}

// ---------------------------------------------------------------------------
// Compute phase
// ---------------------------------------------------------------------------

function rawHeaderValues(headers: readonly GmailHeader[] | undefined, name: string): string[] {
  if (headers === undefined) return []
  return headers.filter((h) => h.name.toLowerCase() === name).map((h) => h.value)
}

function buildReplyFromHeaders(msg: GmailMessage, labelIds: readonly string[]): ReplyFromHeaders {
  const headers = msg.payload?.headers
  const from = rawHeaderValues(headers, 'from')[0]
  const result: ReplyFromHeaders = {
    isSent: labelIds.includes('SENT'),
    to: rawHeaderValues(headers, 'to'),
    cc: rawHeaderValues(headers, 'cc'),
    xOriginalTo: rawHeaderValues(headers, 'x-original-to'),
    envelopeTo: rawHeaderValues(headers, 'envelope-to'),
    deliveredTo: rawHeaderValues(headers, 'delivered-to'),
  }
  if (from !== undefined) result.from = from
  return result
}

interface IdentityParticipants {
  emails: Set<string>
  displayNames: Record<string, string>
}

/**
 * From+To+Cc participant emails and display names for conversation identity.
 * BCC excluded; Hide-My-Email placeholder entries dropped entirely
 * (ConversationIdentity.extractEmailsWithDisplayNames). The From header is
 * re-parsed from its raw value so a multi-mailbox From (rare but valid RFC
 * 5322) contributes EVERY address, matching iOS makeConversationIdentity's
 * split of the whole raw From value — headers.from alone keeps only the
 * first address.
 */
function identityParticipants(headers: ParsedHeaders): IdentityParticipants {
  const emails = new Set<string>()
  const displayNames: Record<string, string> = {}

  const fromEntries: ParsedAddress[] =
    headers.fromRaw !== null ? parseEmailAddresses(headers.fromRaw) : []
  const fromForIdentity =
    fromEntries.length > 0 ? fromEntries : headers.from !== null ? [headers.from] : []
  const entries = [...fromForIdentity, ...headers.to, ...headers.cc]
  for (const entry of entries) {
    if (entry.email === '') continue
    if (isHideMyEmailDisplayName(entry.name)) continue
    if (
      entry.name !== null &&
      isBetterDisplayNameForEmail(entry.name, displayNames[entry.email], entry.email)
    ) {
      displayNames[entry.email] = entry.name
    }
    emails.add(entry.email)
  }

  return { emails, displayNames }
}

/** attachmentId → partId map so attachment row ids can be `${messageId}:${partId}`. */
function attachmentPartIds(payload: GmailPart | undefined): Map<string, string> {
  const map = new Map<string, string>()
  const walk = (part: GmailPart): void => {
    const attachmentId = part.body?.attachmentId
    if (attachmentId !== undefined && part.partId !== undefined && !map.has(attachmentId)) {
      map.set(attachmentId, part.partId)
    }
    for (const sub of part.parts ?? []) walk(sub)
  }
  if (payload !== undefined) walk(payload)
  return map
}

function effectiveLabelIds(
  labelIds: readonly string[],
  knownLabelIds: ReadonlySet<string> | null,
): string[] {
  // Empty prefetched set means the label lookup failed, not that the store
  // has no labels — treating it as authoritative would strip every label.
  if (knownLabelIds === null || knownLabelIds.size === 0) return [...labelIds]
  return labelIds.filter((id) => knownLabelIds.has(id))
}

/** Prepares one Gmail message into a PersistPlan (no Dexie access). */
export async function preparePersistPlan(
  msg: GmailMessage,
  ctx: PersistContext,
): Promise<PersistPlan> {
  const labelIds = msg.labelIds ?? []
  const excludedLabel = labelIds.find((id) => EXCLUDED_MAILBOX_LABEL_IDS.has(id))
  if (excludedLabel !== undefined) {
    return { kind: 'excluded', id: msg.id, label: excludedLabel }
  }

  const parseOptions: ParseGmailMessageOptions = {}
  if (ctx.fetchLargeBody !== undefined) parseOptions.fetchLargeBody = ctx.fetchLargeBody
  const parsed = await parseGmailMessage(msg, parseOptions)
  if (parsed === null) {
    return { kind: 'unprocessable', id: msg.id }
  }

  const headers = parsed.headers
  const isFromMe = headers.from !== null && ctx.myAliases.has(headers.from.email)
  const isUnread = labelIds.includes('UNREAD')

  const cleanedSnippet = createCleanedSnippet(parsed.html, parsed.plainText, parsed.snippet) ?? ''
  const chatPreviewText =
    createChatPreviewText(
      parsed.html,
      parsed.plainText,
      parsed.snippet,
      isFromMe && isForwardedSubject(headers.subject),
    ) ?? ''

  // Documented scope cut vs iOS: MessageProcessor.isNewsletterOrPromotion has
  // a second chance — when the header score is below threshold it runs
  // EmailPreviewClassifier.classify over the HTML body and accepts a
  // .newsletter verdict. That classifier (446 lines, its own heuristics) is
  // not ported yet, so borderline promotional HTML with no list headers can
  // render as a text bubble here while iOS shows a preview card.
  const newsletter = calculateNewsletterScore(labelIds, {
    from: headers.fromRaw,
    replyTo: headers.replyTo,
    subject: headers.subject,
    listUnsubscribe: headers.listUnsubscribe,
    listUnsubscribePost: headers.listUnsubscribePost,
    listId: headers.listId,
    precedence: headers.precedence,
    toCount: headers.to.length,
    ccCount: headers.cc.length,
  })

  const replyFrom = resolveReplyFrom(buildReplyFromHeaders(msg, labelIds), ctx.sendAsAliases)

  const { emails, displayNames } = identityParticipants(headers)
  const setIdentity = makeParticipantSetIdentity(emails, ctx.myAliases)
  const identity = makeConversationIdentity(setIdentity, displayNames)

  // Message participants: from always; to/cc/bcc minus Hide-My-Email entries
  // (MessagePersister+Participants). BCC is stored but excluded from identity.
  const participants: Array<Omit<MsgParticipantRow, 'pk' | 'messageId'>> = []
  const people = new Map<string, string>()
  const addParticipant = (
    email: string,
    name: string | null,
    kind: ParticipantKind,
    skipHideMyEmail: boolean,
  ): void => {
    if (email === '') return
    if (skipHideMyEmail && isHideMyEmailDisplayName(name)) return
    participants.push({ email, displayName: name ?? '', kind })
    const existing = people.get(email)
    if (existing === undefined || isBetterDisplayNameForEmail(name, existing, email)) {
      people.set(email, name?.trim() ?? existing ?? '')
    }
  }
  if (headers.from !== null) addParticipant(headers.from.email, headers.from.name, 'from', false)
  for (const r of headers.to) addParticipant(r.email, r.name, 'to', true)
  for (const r of headers.cc) addParticipant(r.email, r.name, 'cc', true)
  for (const r of headers.bcc) addParticipant(r.email, r.name, 'bcc', true)

  const partIds = attachmentPartIds(msg.payload)
  const attachments: PlannedAttachment[] = parsed.attachments.map((att) => {
    const isInline = att.inlineData !== null
    const partId = partIds.get(att.id)
    // Row ids are ALWAYS message-scoped: the attachments table keys on id
    // globally, and inline `local_inline_<hash>` fingerprints are content-only
    // — two messages carrying an identical inline part (recurring newsletter /
    // signature images) would otherwise collide, re-parenting the shared row
    // and letting one message's delete cascade destroy the other's blob.
    const rowId = isInline ? `${msg.id}:${att.id}` : `${msg.id}:${partId ?? att.id}`
    return {
      row: {
        id: rowId,
        gmailAttachmentId: isInline ? '' : att.id,
        contentId: att.contentId ?? '',
        filename: att.filename,
        mimeType: att.mimeType,
        byteSize: att.size,
        width: 0,
        height: 0,
        state: isInline ? 'downloaded' : 'queued',
        lastDownloadFailedAt: 0,
      },
      inlineData: att.inlineData,
    }
  })

  const message: MessageRow = {
    id: parsed.id,
    conversationId: '',
    gmThreadId: parsed.threadId,
    rfcMessageId: headers.messageIdHeader ?? '',
    references: headers.references.join(' '),
    internalDate: parsed.internalDate,
    subject: headers.subject ?? '',
    snippet: parsed.snippet ?? '',
    cleanedSnippet,
    chatPreviewText,
    bodyText: parsed.plainText ?? '',
    hasHtmlBody: parsed.html !== null ? 1 : 0,
    senderEmail: headers.from?.email ?? '',
    senderName: headers.from?.name ?? '',
    deliveredToAddress: replyFrom.deliveredToAddress ?? '',
    replyFromAddress: replyFrom.replyFromAddress ?? '',
    isFromMe: isFromMe ? 1 : 0,
    isUnread: isUnread ? 1 : 0,
    isNewsletter: newsletter.isNewsletter ? 1 : 0,
    isCalendarInvite: parsed.isLikelyCalendarInvite ? 1 : 0,
    hasAttachments: parsed.hasAttachments || attachments.length > 0 ? 1 : 0,
    labelIds: effectiveLabelIds(labelIds, ctx.knownLabelIds),
    localModifiedAt: 0,
  }
  if (parsed.calendarEvent !== null) {
    message.calendarEvent = parsed.calendarEvent
  }

  return {
    kind: 'message',
    message,
    bodyHtml: parsed.html,
    participants,
    people: [...people.entries()].map(([email, displayName]) => ({ email, displayName })),
    attachments,
    identity,
    reactivateArchived: shouldReactivateArchivedConversation(labelIds, isFromMe),
  }
}

/**
 * Prepare-phase width. `preparePersistPlan` is not pure compute: parsing can
 * issue `fetchLargeBody` → `attachments.get` calls for oversized bodies, so an
 * unbounded `Promise.all` over a 500-message page would put 500 attachment
 * GETs in flight (each with its own retry ladder) behind the carefully bounded
 * message-GET tier. Mirrors SyncConfig.maxConcurrentMessageProcessing.
 */
export const PREPARE_CONCURRENCY = 6

/** Prepares a batch (bounded-concurrency compute, input order preserved). */
export async function preparePersist(
  messages: readonly GmailMessage[],
  ctx: PersistContext,
  concurrency: number = PREPARE_CONCURRENCY,
): Promise<PersistPlan[]> {
  return mapWithConcurrency(messages, concurrency, (msg) => preparePersistPlan(msg, ctx))
}

// ---------------------------------------------------------------------------
// Apply phase (Dexie-only inside transactions)
// ---------------------------------------------------------------------------

function conversationMessagesQuery(db: ChatmailDB, conversationId: string) {
  return db.messages
    .where('[conversationId+internalDate]')
    .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
}

/** Deletes a message and its dependents; returns its conversationId. */
async function deleteMessageCascade(db: ChatmailDB, messageId: string): Promise<string | null> {
  const existing = await db.messages.get(messageId)
  if (existing === undefined) return null
  const attachmentIds = await db.attachments.where('messageId').equals(messageId).primaryKeys()
  await db.messages.delete(messageId)
  await db.bodies.delete(messageId)
  await db.msgParticipants.where('messageId').equals(messageId).delete()
  await db.attachments.where('messageId').equals(messageId).delete()
  if (attachmentIds.length > 0) await db.blobs.bulkDelete(attachmentIds)
  return existing.conversationId
}

async function upsertPeople(
  db: ChatmailDB,
  people: ReadonlyArray<{ email: string; displayName: string }>,
): Promise<void> {
  for (const { email, displayName } of people) {
    const existing = await db.people.get(email)
    if (existing === undefined) {
      await db.people.put({ email, displayName })
    } else if (isBetterDisplayNameForEmail(displayName, existing.displayName, email)) {
      await db.people.put({ email, displayName })
    }
  }
}

async function putAttachments(
  db: ChatmailDB,
  messageId: string,
  planned: readonly PlannedAttachment[],
  now: number,
): Promise<void> {
  const existingRows = await db.attachments.where('messageId').equals(messageId).toArray()
  const existingIds = new Set(existingRows.map((row) => row.id))
  const existingContentIds = new Set(
    existingRows.map((row) => row.contentId).filter((cid) => cid !== ''),
  )

  for (const { row, inlineData } of planned) {
    if (existingIds.has(row.id)) continue
    if (row.contentId !== '' && existingContentIds.has(row.contentId)) continue
    await db.attachments.put({ ...row, messageId })
    existingIds.add(row.id)
    if (row.contentId !== '') existingContentIds.add(row.contentId)
    if (inlineData !== null) {
      const blob = new Blob([inlineData as unknown as BlobPart], { type: row.mimeType })
      // Via putBlob, never a bare db.blobs.put: a full origin quota raises a
      // DOMException that would abort this whole APPLY transaction, losing the
      // page's messages and wedging sync for good once storage fills up.
      // Inline bytes are a cache — drop them and keep the message; the
      // attachment row stays 'queued' so the reader can fetch it on demand.
      try {
        await putBlob(db, row.id, blob, now)
      } catch (error) {
        if (!(error instanceof BlobQuotaExceededError)) throw error
      }
    }
  }
}

/** Recomputes inbox-only indicators from the conversation's message set. */
async function refreshInboxIndicators(
  db: ChatmailDB,
  conversation: ConversationRow,
): Promise<ConversationRow> {
  const messages = await conversationMessagesQuery(db, conversation.id).toArray()
  let hasInbox = false
  let unreadCount = 0
  let latestInboxDate = 0
  for (const message of messages) {
    if (!message.labelIds.includes('INBOX')) continue
    hasInbox = true
    if (message.isUnread === 1) unreadCount += 1
    if (message.internalDate > latestInboxDate) latestInboxDate = message.internalDate
  }
  return {
    ...conversation,
    hasInbox: hasInbox ? 1 : 0,
    inboxUnreadCount: unreadCount,
    latestInboxDate,
  }
}

/**
 * Fast-path list update after inserting a new message
 * (applyFastConversationListUpdateForNewMessage): bump preview/date, and for
 * INBOX arrivals assign-vs-increment the unread count so the path stays
 * idempotent with the creation-time ConversationInboxSeed.
 */
async function applyFastUpdateForNewMessage(
  db: ChatmailDB,
  conversationId: string,
  message: MessageRow,
): Promise<void> {
  const conversation = await db.conversations.get(conversationId)
  if (conversation === undefined) return
  let updated: ConversationRow = { ...conversation }

  if (message.internalDate >= updated.lastMessageDate) {
    updated.lastMessageDate = message.internalDate
    const preview = conversationPreview(message)
    if (preview !== '') updated.snippet = preview
  }

  if (message.labelIds.includes('INBOX')) {
    updated.hasInbox = 1
    if (message.isUnread === 1) {
      // A sole first message was already counted by the creation-time seed;
      // assign instead of incrementing so the fast path stays idempotent.
      const messageCount = await conversationMessagesQuery(db, conversationId).count()
      updated.inboxUnreadCount = messageCount <= 1 ? 1 : updated.inboxUnreadCount + 1
    }
    if (message.internalDate > updated.latestInboxDate) {
      updated.latestInboxDate = message.internalDate
    }
    if (updated.archivedAt !== 0 || updated.isArchived !== 0) {
      updated = { ...updated, archivedAt: 0, isArchived: 0 }
    }
  }

  await db.conversations.put(updated)
}

/**
 * Fast-path list update for an existing message whose labels/read state may
 * have changed (applyFastConversationListUpdateForExistingMessage): ±1 unread
 * arithmetic clamped ≥ 0, full inbox recompute when the message left INBOX.
 */
export async function applyFastUpdateForExistingMessage(
  db: ChatmailDB,
  conversationId: string,
  message: MessageRow,
  previousHadInbox: boolean,
  previousWasUnread: boolean,
): Promise<void> {
  const conversation = await db.conversations.get(conversationId)
  if (conversation === undefined) return
  let updated: ConversationRow = { ...conversation }

  const currentHasInbox = message.labelIds.includes('INBOX')
  const currentUnread = message.isUnread === 1
  const previousUnreadInInbox = previousHadInbox && previousWasUnread
  const currentUnreadInInbox = currentHasInbox && currentUnread

  if (previousUnreadInInbox !== currentUnreadInInbox) {
    updated.inboxUnreadCount = currentUnreadInInbox
      ? updated.inboxUnreadCount + 1
      : Math.max(0, updated.inboxUnreadCount - 1)
  }

  if (currentHasInbox) {
    updated.hasInbox = 1
    if (message.internalDate > updated.latestInboxDate) {
      updated.latestInboxDate = message.internalDate
    }
    if (updated.archivedAt !== 0 || updated.isArchived !== 0) {
      updated = { ...updated, archivedAt: 0, isArchived: 0 }
    }
  } else if (previousHadInbox) {
    // The message left INBOX; recompute inbox-only indicators for correctness.
    updated = await refreshInboxIndicators(db, updated)
  }

  if (message.internalDate >= updated.lastMessageDate) {
    updated.lastMessageDate = message.internalDate
    const preview = conversationPreview(message)
    if (preview !== '') updated.snippet = preview
  }

  await db.conversations.put(updated)
}

function nonEmpty(value: string): string | null {
  return value.trim() === '' ? null : value
}

/**
 * Merges an incoming plan into an existing message row
 * (MessagePersister+Updates, simplified): previews are preserved when the
 * incoming ones are all empty; label/unread writes are skipped entirely while
 * localModifiedAt is fresher than 30 minutes; otherwise labels are rebuilt
 * from the payload.
 */
export function mergeExistingMessage(
  existing: MessageRow,
  plan: MessagePersistPlan,
  now: number,
): MessageRow {
  const incoming = plan.message
  const updated: MessageRow = { ...existing }

  updated.gmThreadId = incoming.gmThreadId
  if (nonEmpty(incoming.subject) !== null) updated.subject = incoming.subject
  updated.isFromMe = incoming.isFromMe
  updated.isNewsletter = incoming.isNewsletter
  // The invite verdict recomputes from content, so only a parse that actually
  // saw content may clear it: a blind re-fetch (metadata-only payload, an
  // oversized body whose fetch failed — both leave bodyText empty and carry no
  // calendar part) has lost the signals, not the invite. Clearing on those
  // would strand a stored calendarEvent behind a 0 flag, breaking the
  // presence contract in db/types.
  if (incoming.isCalendarInvite === 1) {
    updated.isCalendarInvite = 1
  } else if (nonEmpty(incoming.bodyText) !== null || incoming.calendarEvent !== undefined) {
    updated.isCalendarInvite = 0
    // Genuinely no longer an invite: the stored event describes something
    // this message is not, so it goes with the flag.
    delete updated.calendarEvent
  }
  // Keep the stored event when a re-fetch of the same message arrives without
  // one (a metadata-only payload carries no text/calendar part to re-extract).
  if (incoming.calendarEvent !== undefined) {
    updated.calendarEvent = incoming.calendarEvent
  }
  updated.internalDate = incoming.internalDate
  updated.deliveredToAddress = incoming.deliveredToAddress
  updated.replyFromAddress = incoming.replyFromAddress
  updated.rfcMessageId = incoming.rfcMessageId
  updated.references = incoming.references

  const incomingHasPreview =
    nonEmpty(incoming.chatPreviewText) !== null ||
    nonEmpty(incoming.cleanedSnippet) !== null ||
    nonEmpty(incoming.snippet) !== null
  if (incomingHasPreview) {
    updated.snippet = incoming.snippet
    updated.cleanedSnippet = incoming.cleanedSnippet
    updated.chatPreviewText = incoming.chatPreviewText
  }

  if (incoming.senderEmail !== '') {
    updated.senderEmail = incoming.senderEmail
    updated.senderName = incoming.senderName
  }

  if (nonEmpty(incoming.bodyText) !== null) updated.bodyText = incoming.bodyText
  if (plan.bodyHtml !== null) updated.hasHtmlBody = 1

  const guardActive =
    existing.localModifiedAt !== 0 && now - existing.localModifiedAt < LOCAL_MODIFICATION_MAX_AGE_MS
  if (!guardActive) {
    updated.isUnread = incoming.isUnread
    updated.labelIds = incoming.labelIds
  }

  updated.hasAttachments = existing.hasAttachments === 1 || incoming.hasAttachments === 1 ? 1 : 0

  return updated
}

const APPLY_TABLES = [
  'messages',
  'bodies',
  'msgParticipants',
  'people',
  'attachments',
  'blobs',
  'conversations',
  'convoParticipants',
] as const

export interface PersistApplyHooks {
  /**
   * Test seam: awaited between conversation resolution and the apply
   * transaction of a new-message plan (the window in which a concurrent
   * failed-send rollback can delete the resolved conversation).
   */
  afterResolve?: (conversationId: string | null) => Promise<void>
}

/** The seed a message plan uses for creating (or recreating) its conversation shell. */
function planResolveSeed(plan: MessagePersistPlan): ResolveSeed {
  return {
    isInboxArrival: plan.message.labelIds.includes('INBOX'),
    isUnread: plan.message.isUnread === 1,
    messageDate: plan.message.internalDate,
    snippet: conversationPreview(plan.message),
  }
}

async function applyMessagePlan(
  db: ChatmailDB,
  plan: MessagePersistPlan,
  now: number,
  result: PersistApplyResult,
  hooks?: PersistApplyHooks,
): Promise<void> {
  // Resolve outside the write transaction (the per-hash creation lock is a
  // non-Dexie await): shell-before-message publishing, exactly like iOS.
  const preExisting = await db.messages.get(plan.message.id)

  let resolvedConversationId: string | null = null
  if (preExisting === undefined) {
    const resolved = await resolveConversation(
      db,
      plan.identity,
      planResolveSeed(plan),
      plan.reactivateArchived,
    )
    resolvedConversationId = resolved.conversation.id
    await hooks?.afterResolve?.(resolvedConversationId)
  }

  await db.transaction(
    'rw',
    APPLY_TABLES.map((t) => db[t]),
    async () => {
      const existing = await db.messages.get(plan.message.id)
      if (existing !== undefined) {
        const previousHadInbox = existing.labelIds.includes('INBOX')
        const previousWasUnread = existing.isUnread === 1
        const updated = mergeExistingMessage(existing, plan, now)
        await db.messages.put(updated)
        if (plan.bodyHtml !== null) {
          await db.bodies.put({ messageId: updated.id, html: plan.bodyHtml })
        }
        await upsertPeople(db, plan.people)
        await putAttachments(db, updated.id, plan.attachments, now)
        await applyFastUpdateForExistingMessage(
          db,
          updated.conversationId,
          updated,
          previousHadInbox,
          previousWasUnread,
        )
        result.touchedConversationIds.add(updated.conversationId)
        result.persistedMessageIds.add(updated.id)
        return
      }

      if (resolvedConversationId === null) return
      // Resolution happened OUTSIDE this transaction; the conversation can
      // have been deleted in the gap (rollbackFailedSend removes a newly
      // minted, still-empty conversation when its send fails). Inserting the
      // message anyway would orphan it forever — no conversation row would
      // reference it and findMissedMessageIds would see it as present.
      // Recreate the shell under the SAME id from the plan's identity + seed.
      if ((await db.conversations.get(resolvedConversationId)) === undefined) {
        await reinsertConversationShell(
          db,
          resolvedConversationId,
          plan.identity,
          planResolveSeed(plan),
        )
      }
      const message: MessageRow = { ...plan.message, conversationId: resolvedConversationId }
      await db.messages.put(message)
      if (plan.bodyHtml !== null) {
        await db.bodies.put({ messageId: message.id, html: plan.bodyHtml })
      }
      if (plan.participants.length > 0) {
        await db.msgParticipants.bulkAdd(
          plan.participants.map((p) => ({ ...p, messageId: message.id })),
        )
      }
      await upsertPeople(db, plan.people)
      await putAttachments(db, message.id, plan.attachments, now)
      await applyFastUpdateForNewMessage(db, resolvedConversationId, message)
      result.touchedConversationIds.add(resolvedConversationId)
      result.persistedMessageIds.add(message.id)
    },
  )
}

/**
 * Applies plans sequentially in chronological order (message plans sorted by
 * internalDate) so conversation creation, seeding, and fast-path ordering stay
 * deterministic. Each message commits in ONE rw transaction; interruption
 * between messages leaves a consistent store.
 */
export async function applyPersist(
  db: ChatmailDB,
  plans: readonly PersistPlan[],
  now: number,
  hooks?: PersistApplyHooks,
): Promise<PersistApplyResult> {
  const result: PersistApplyResult = {
    touchedConversationIds: new Set(),
    persistedMessageIds: new Set(),
    deletedMessageIds: new Set(),
  }

  const ordered = [...plans].sort((a, b) => {
    const dateOf = (p: PersistPlan): number => (p.kind === 'message' ? p.message.internalDate : 0)
    return dateOf(a) - dateOf(b)
  })

  for (const plan of ordered) {
    if (plan.kind === 'unprocessable') continue
    if (plan.kind === 'excluded') {
      await db.transaction(
        'rw',
        APPLY_TABLES.map((t) => db[t]),
        async () => {
          const conversationId = await deleteMessageCascade(db, plan.id)
          if (conversationId !== null) {
            result.touchedConversationIds.add(conversationId)
            result.deletedMessageIds.add(plan.id)
          }
        },
      )
      continue
    }
    await applyMessagePlan(db, plan, now, result, hooks)
  }

  return result
}

/** Deletes messages reported deleted by history (authoritative). */
export async function deleteMessagesCascade(
  db: ChatmailDB,
  messageIds: readonly string[],
): Promise<Set<string>> {
  const touched = new Set<string>()
  await db.transaction(
    'rw',
    [db.messages, db.bodies, db.msgParticipants, db.attachments, db.blobs],
    async () => {
      for (const id of messageIds) {
        const conversationId = await deleteMessageCascade(db, id)
        if (conversationId !== null) touched.add(conversationId)
      }
    },
  )
  return touched
}
