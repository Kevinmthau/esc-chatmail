// Optimistic send pipeline. Port of Services/Send/
// {GmailSendService+OptimisticUpdates,OutboundMessageCoordinator,
// OutboundSendMutationTracker}.swift.
//
// Ordering invariants carried over:
// 0. the MIME is built BEFORE anything optimistic exists, so an address the
//    builder refuses fails the send with nothing to roll back;
// 1. optimistic message + conversation bump + journal write in ONE tx;
// 2. the Gmail send call is NEVER retransmitted (endpoints.sendMessage);
// 3. on acceptance the journal is stamped 'committed' with the remote ids
//    BEFORE local reconciliation, so a crash between the two is recoverable
//    at startup (replayAbandonedSends);
// 4. reconcile swaps the optimistic UUID PK to the Gmail id (delete+add in
//    one tx, body row moved, attachment rows re-parented and marked
//    'uploaded'), or deletes the optimistic row when sync already delivered
//    the sent copy;
// 5. failure WITHOUT attachments deletes the optimistic row, recomputes the
//    conversation rollup from the messages that remain (never a blind
//    snapshot restore, which would clobber concurrent sync updates), and
//    deletes a newly-minted-and-now-empty conversation;
// 6. failure WITH attachments KEEPS the message and marks it (and its
//    attachment rows) failed, so the user can retry from the bubble instead
//    of re-picking files whose bytes only exist on this device
//    (GmailSendService+OptimisticUpdates.handleFailedOptimisticMessage).

import Dexie from 'dexie'
import { BlobQuotaExceededError, putBlob } from '@/db/blobs'
import type { ChatmailDB } from '@/db/schema'
import type { AttachmentRow, MessageRow, OutboundSendRow } from '@/db/types'
import {
  sendMessage as sendMessageEndpoint,
  type EndpointOptions,
  type SendMessageParams,
} from '@/gmail/endpoints'
import type { SendMessageResponse } from '@/gmail/types'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { normalizeEmail } from '@/identity/normalizeEmail'
import { makeConversationIdentity } from '@/identity/participantSet'
import { makeStoredRecipientParticipantSetIdentity } from '@/identity/recipientIdentity'
import { resolveConversation } from '@/identity/routing'
import { newId } from '@/lib/uuid'
import { createCleanSnippet } from '@/mime/preview'
import { conversationPreview, rollupConversation } from '@/rollup/rollup'
import { isAcceptedForSending, normalizedAliasAddress } from '@/sync/aliases'
import {
  buildNew,
  buildReply,
  encodeRawForSend,
  InvalidRecipientsError,
  InvalidSenderError,
  MessageTooLargeError,
  NoValidRecipientsError,
  type BuildNewInput,
  type MimeAttachment,
} from './mimeBuilder'
import {
  localAttachmentRow,
  MAX_ATTACHMENT_LABEL,
  newLocalAttachmentId,
  type PendingAttachment,
} from './outboundAttachments'
import { buildReplyMetadata, type ReplyMetadata } from './replyMetadata'

/** Pending journals older than this with no optimistic row are swept at boot. */
export const STALE_PENDING_SEND_MS = 10 * 60 * 1000

/** Typed failure surfaced to the compose UI; `cause` carries the transport error. */
export class SendFailedError extends Error {
  /**
   * Copy safe to show verbatim in the compose UI (address rejections name the
   * offending addresses); null when only the generic failure line applies.
   */
  readonly userMessage: string | null

  /**
   * True when the failed send left a retryable message bubble behind (the
   * attachment path). The composer must NOT restore the draft or the picked
   * files in that case — they now live in the bubble, and putting them back
   * would double the message the moment the retry succeeds.
   */
  readonly keptFailedMessage: boolean

  /** Conversation the retryable bubble lives in; null when nothing was kept. */
  readonly conversationId: string | null

  constructor(
    message: string,
    options?: {
      cause?: unknown
      userMessage?: string
      keptFailedMessage?: boolean
      conversationId?: string
    },
  ) {
    super(message, options)
    this.name = 'SendFailedError'
    this.userMessage = options?.userMessage ?? null
    this.keptFailedMessage = options?.keptFailedMessage ?? false
    this.conversationId = options?.conversationId ?? null
  }
}

/** Fallback copy for a send failure with no user-actionable explanation. */
export const GENERIC_SEND_ERROR = 'Message could not be sent. Try again.'

/**
 * UI-facing text for a failed send: the specific reason when the failure
 * carries one (an address the MIME builder refused), the generic line
 * otherwise. Pure — safe to import straight into components.
 */
export function sendFailureMessage(error: unknown): string {
  return error instanceof SendFailedError && error.userMessage !== null
    ? error.userMessage
    : GENERIC_SEND_ERROR
}

/**
 * Wraps a pre-flight failure (address validation in particular) as a
 * SendFailedError with UI-ready copy naming what was rejected.
 */
function asSendFailure(error: unknown): SendFailedError {
  if (error instanceof SendFailedError) return error
  if (error instanceof InvalidRecipientsError) {
    const list = error.addresses.join(', ')
    return new SendFailedError(error.message, {
      cause: error,
      userMessage:
        error.addresses.length === 1
          ? `${list} is not a valid email address.`
          : `These are not valid email addresses: ${list}.`,
    })
  }
  if (error instanceof NoValidRecipientsError) {
    return new SendFailedError(error.message, {
      cause: error,
      userMessage: 'There is no one to send this message to.',
    })
  }
  if (error instanceof InvalidSenderError) {
    return new SendFailedError(error.message, {
      cause: error,
      userMessage: 'Your send-from address is not a valid email address.',
    })
  }
  if (error instanceof MessageTooLargeError) {
    return new SendFailedError(error.message, {
      cause: error,
      userMessage: `This message is too large to send. Remove an attachment and try again (each file may be up to ${MAX_ATTACHMENT_LABEL}).`,
    })
  }
  if (error instanceof BlobQuotaExceededError) {
    return new SendFailedError(error.message, {
      cause: error,
      userMessage: 'There is not enough storage on this device to attach these files.',
    })
  }
  return new SendFailedError('Send failed', { cause: error })
}

/** Network surface for the send call; injectable for tests. */
export interface SendApi {
  send(params: SendMessageParams): Promise<SendMessageResponse>
}

export function makeSendApi(broker: TokenBroker, options?: EndpointOptions): SendApi {
  return { send: (params) => sendMessageEndpoint(broker, params, options) }
}

/** Forward-specific overrides carried by a compose-mode forward. */
export interface ForwardSendPayload {
  /** 'Fwd: '-prefixed subject; '' sends as '(No Subject)'. */
  subject: string
  /** Complete html alternative; absent sends text/plain only. */
  htmlBody?: string
}

export interface SendDraft {
  /** Reply into an existing conversation. */
  conversationId?: string
  /** New-recipient send; ignored when conversationId is set. */
  to?: readonly string[]
  body: string
  /**
   * Send-as alias email chosen in the compose UI. Overrides the reply-from
   * ladder's pick when it matches an accepted account alias; otherwise the
   * ladder's choice stands (never fails a send over a stale picker value).
   */
  fromAlias?: string
  /**
   * Present when this send is a forward. A forward is a NEW message (iOS
   * composes fresh in .forward mode): it keeps the resolved conversation and
   * its reply-from alias, but carries its own subject and NO threading
   * headers — see the override in sendMessage.
   */
  forward?: ForwardSendPayload
  /** Files staged by the picker (outbox/outboundAttachments.prepareAttachments). */
  attachments?: readonly PendingAttachment[]
}

export interface SendOptions {
  api?: SendApi
  now?: () => number
  /** Immutable forward semantics recovered from a failed send's journal. */
  preservedForwardEnvelope?: PreservedForwardEnvelope
  /**
   * A failed message this send replaces (retryFailedSend). Its whole graph —
   * message, attachment rows, blobs, journal — is deleted INSIDE the new
   * send's optimistic transaction, never before it: those blobs are the only
   * copy of the user's files anywhere, so a retry that dies pre-flight
   * (invalid recipients, missing conversation, quota) must abort the delete
   * with everything else and leave the failed bubble in custody of the bytes.
   */
  replacesFailedMessageId?: string
}

/**
 * The fields a failed forward cannot safely derive from its conversation on
 * retry. Attachment bytes already live durably in blobs; ids pin their order.
 * Stored as an unindexed addition to the outbound journal (no Dexie migration).
 */
export interface PreservedForwardEnvelope {
  metadata: ReplyMetadata
  attachmentIds: string[]
  htmlBody?: string
}

type OutboundSendWithForwardEnvelope = OutboundSendRow & {
  forwardEnvelope?: PreservedForwardEnvelope
}

export interface SendResult {
  /** The Gmail message id the send committed as. */
  messageId: string
  conversationId: string
}

function cloneReplyMetadata(metadata: ReplyMetadata): ReplyMetadata {
  return {
    ...metadata,
    recipients: [...metadata.recipients],
    references: [...metadata.references],
    replyFrom: { ...metadata.replyFrom },
  }
}

function makePreservedForwardEnvelope(
  metadata: ReplyMetadata,
  attachments: readonly PendingAttachment[],
  htmlBody?: string,
): PreservedForwardEnvelope {
  return {
    metadata: cloneReplyMetadata(metadata),
    attachmentIds: attachments.map((attachment) => attachment.id),
    ...(htmlBody !== undefined ? { htmlBody } : {}),
  }
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

export async function sendMessage(
  db: ChatmailDB,
  broker: TokenBroker,
  draft: SendDraft,
  opts: SendOptions = {},
): Promise<SendResult> {
  const now = opts.now ?? Date.now
  const api = opts.api ?? makeSendApi(broker)

  const account = await db.accounts.toCollection().first()
  if (account === undefined) throw new SendFailedError('No account is configured')
  const myAliases: ReadonlySet<string> = new Set(account.aliases)

  // (a) Resolve the target conversation.
  let conversationId: string
  let newlyInserted = false
  if (draft.conversationId !== undefined) {
    const existing = await db.conversations.get(draft.conversationId)
    if (existing === undefined) throw new SendFailedError('Conversation not found')
    conversationId = existing.id
  } else {
    // Compose path: the participant hash MUST come from identity/participantSet
    // so the optimistic conversation and the synced-back copy hash identically.
    const setIdentity = await makeStoredRecipientParticipantSetIdentity(
      db,
      draft.to ?? [],
      myAliases,
    )
    if (setIdentity === null) throw new SendFailedError('No valid recipients')
    const identity = makeConversationIdentity(setIdentity)
    const resolved = await resolveConversation(
      db,
      identity,
      {
        isInboxArrival: false,
        isUnread: false,
        messageDate: now(),
        snippet: draft.body.trim(),
      },
      true,
    )
    conversationId = resolved.conversation.id
    newlyInserted = resolved.created
  }

  // (b) Reply metadata + MIME, BEFORE anything optimistic exists. The builder
  // rejects smuggled/invalid addresses by throwing (InvalidSenderError /
  // InvalidRecipientsError), so building here means a rejection has nothing to
  // roll back — building it after the optimistic insert (as this used to)
  // escaped the try that owns rollbackFailedSend and left a permanently
  // "Sending…" bubble plus an orphaned 'pending' journal.
  const attachments = draft.attachments ?? []
  let metadata: ReplyMetadata
  let raw: string
  try {
    const preservedForward = opts.preservedForwardEnvelope
    metadata =
      preservedForward !== undefined
        ? cloneReplyMetadata(preservedForward.metadata)
        : await buildReplyMetadata(db, conversationId, myAliases)
    if (
      preservedForward === undefined &&
      draft.conversationId === undefined &&
      (draft.to?.length ?? 0) > 0
    ) {
      // Conversation routing intentionally removes self except for its
      // note-to-self fallback, while MIME must preserve every recipient the
      // user explicitly entered on a NEW compose. Existing-conversation
      // replies keep buildReplyMetadata's normal self-filtering behavior.
      metadata = { ...metadata, recipients: [...(draft.to ?? [])] }
    }
    if (metadata.recipients.length === 0) {
      throw new SendFailedError('No recipients to send to', {
        userMessage: 'There is no one to send this message to.',
      })
    }
    if (preservedForward === undefined && draft.fromAlias !== undefined) {
      // Exact-address compare (normalizedAliasAddress), NOT the full Gmail
      // canonicalization: normalizeEmail strips dots/plus-tags on gmail.com, so
      // it would collapse distinct sendAs aliases (me@ vs me+news@) onto the
      // first match and silently send from the wrong identity.
      const wanted = normalizedAliasAddress(draft.fromAlias)
      const chosen = account.sendAsAliases.find(
        (alias) => isAcceptedForSending(alias) && normalizedAliasAddress(alias.email) === wanted,
      )
      if (chosen !== undefined) metadata = { ...metadata, replyFrom: chosen }
    }
    if (preservedForward === undefined && draft.forward !== undefined) {
      // A forward is not a reply. buildReplyMetadata always targets the
      // conversation's newest message, so forwarding to someone you already
      // chat with would otherwise inherit that message's subject ('Re: …'),
      // its In-Reply-To/References chain and its Gmail thread — stitching an
      // unrelated message into their thread. Recipients and the reply-from
      // alias still come from the ladder; everything threading-related is
      // dropped so this goes out as a new message.
      metadata = {
        ...metadata,
        subject: draft.forward.subject,
        threadId: '',
        inReplyTo: '',
        references: [],
      }
    }
    // Attachment bytes are read (and the payload-size ceiling enforced) here,
    // in the same pre-optimistic step as address validation: a message Gmail's
    // simple send endpoint would refuse for size fails identically on every
    // retry, so leaving a retryable bubble behind would be a lie.
    raw = encodeRawForSend(
      buildOutboundMime(
        metadata,
        draft.body,
        await toMimeParts(attachments),
        preservedForward?.htmlBody ?? draft.forward?.htmlBody,
      ),
    )
  } catch (error) {
    // The compose path already minted the conversation in (a); drop it again
    // so a rejected address cannot leave a phantom empty chat in the list
    // (no journal exists yet, so replayAbandonedSends would never sweep it).
    if (newlyInserted) await deleteEmptyConversation(db, conversationId)
    throw asSendFailure(error)
  }

  // (c) Optimistic insert + journal, one tx.
  // newId(), not crypto.randomUUID: the latter is secure-context-only.
  const optimisticId = newId()
  const sentAt = now()
  const optimistic = makeOptimisticMessage(
    optimisticId,
    conversationId,
    draft.body,
    metadata,
    sentAt,
    attachments.length > 0,
  )
  try {
    await db.transaction(
      'rw',
      [db.conversations, db.messages, db.bodies, db.attachments, db.blobs, db.outboundSends],
      async () => {
        const conversation = await db.conversations.get(conversationId)
        if (conversation === undefined) throw new SendFailedError('Conversation not found')
        // A retry hands over the failed predecessor here, in the same
        // transaction as the replacement's insert: abort one, abort both.
        const replaces = opts.replacesFailedMessageId
        if (replaces !== undefined) {
          await deleteMessageAttachments(db, replaces)
          await db.messages.delete(replaces)
          await db.bodies.delete(replaces)
          await db.outboundSends.delete(replaces)
        }
        const forwardEnvelope =
          opts.preservedForwardEnvelope !== undefined || draft.forward !== undefined
            ? makePreservedForwardEnvelope(
                metadata,
                attachments,
                opts.preservedForwardEnvelope?.htmlBody ?? draft.forward?.htmlBody,
              )
            : undefined
        const journal: OutboundSendWithForwardEnvelope = {
          id: optimisticId,
          conversationId,
          newlyInsertedConversation: newlyInserted ? 1 : 0,
          createdAt: sentAt,
          status: 'pending',
          conversationSnapshot: {
            archivedAt: conversation.archivedAt,
            isArchived: conversation.isArchived,
            displayName: conversation.displayName,
            lastMessageDate: conversation.lastMessageDate,
            snippet: conversation.snippet,
          },
          remoteCommittedMessageId: '',
          remoteCommittedThreadId: '',
          ...(forwardEnvelope !== undefined ? { forwardEnvelope } : {}),
        }
        await db.messages.add(optimistic)
        // Rows and bytes commit together: a row whose blob is missing renders
        // a download control that can never resolve (nothing on the server has
        // these bytes yet), and an orphan blob is prunable garbage.
        for (const attachment of attachments) {
          await db.attachments.put(localAttachmentRow(attachment, optimisticId))
          await putBlob(db, attachment.id, attachment.blob, sentAt)
        }
        const preview = conversationPreview(optimistic)
        await db.conversations.put({
          ...conversation,
          lastMessageDate: sentAt,
          snippet: preview !== '' ? preview : conversation.snippet,
        })
        await db.outboundSends.add(journal)
      },
    )
  } catch (error) {
    // Nothing was committed (the transaction aborted whole), so this is still
    // the pre-optimistic world: drop a conversation minted in (a) and report.
    if (newlyInserted) await deleteEmptyConversation(db, conversationId)
    throw asSendFailure(error)
  }

  // (d) Send. The endpoint never retransmits — an ambiguous failure must not
  // risk a duplicate email.
  if (attachments.length > 0) await markAttachmentState(db, optimisticId, 'uploading')

  let response: SendMessageResponse
  try {
    response = await api.send({
      raw,
      ...(metadata.threadId !== '' ? { threadId: metadata.threadId } : {}),
    })
  } catch (error) {
    // (f) Failure: roll the optimistic graph back, or keep it as a retryable
    // failed bubble when it carries attachments.
    const kept = await failSend(db, optimisticId, now())
    throw new SendFailedError('Send failed', {
      cause: error,
      keptFailedMessage: kept,
      conversationId,
    })
  }

  // (e) Success: journal 'committed' + remote ids FIRST (crash-safe), then
  // reconcile the local store and refresh the rollup.
  await db.outboundSends.update(optimisticId, {
    status: 'committed',
    remoteCommittedMessageId: response.id,
    remoteCommittedThreadId: response.threadId,
  })
  await reconcileCommittedSend(db, optimisticId, now())

  return { messageId: response.id, conversationId }
}

/** Reads the staged blobs into the byte form the MIME builder consumes. */
async function toMimeParts(attachments: readonly PendingAttachment[]): Promise<MimeAttachment[]> {
  return Promise.all(
    attachments.map(async (attachment) => ({
      data: new Uint8Array(await attachment.blob.arrayBuffer()),
      filename: attachment.filename,
      mimeType: attachment.mimeType,
    })),
  )
}

/** Renders the outbound MIME; throws the builder's address-validation errors. */
function buildOutboundMime(
  metadata: ReplyMetadata,
  body: string,
  attachments: readonly MimeAttachment[],
  htmlBody?: string,
): string {
  const mimeInput: BuildNewInput = {
    from: {
      email: metadata.replyFrom.email,
      ...(metadata.replyFrom.displayName !== '' ? { name: metadata.replyFrom.displayName } : {}),
    },
    to: metadata.recipients,
    textBody: body,
    ...(metadata.subject !== '' ? { subject: metadata.subject } : {}),
    // A forward's html alternative and staged attachments compose: the builder
    // nests the alternative section inside multipart/mixed when both exist.
    ...(htmlBody !== undefined ? { htmlBody } : {}),
    ...(attachments.length > 0 ? { attachments } : {}),
  }
  return metadata.inReplyTo !== ''
    ? buildReply({ ...mimeInput, inReplyTo: metadata.inReplyTo, references: metadata.references })
    : buildNew(mimeInput)
}

/** Bulk state write for one message's local attachment rows. */
async function markAttachmentState(
  db: ChatmailDB,
  messageId: string,
  state: AttachmentRow['state'],
): Promise<void> {
  await db.attachments.where('messageId').equals(messageId).modify({ state })
}

/**
 * Drops a conversation minted for a send that failed before the optimistic
 * insert. Guarded on emptiness: a concurrent sync may have delivered a real
 * message into it while the metadata/MIME step ran.
 */
async function deleteEmptyConversation(db: ChatmailDB, conversationId: string): Promise<void> {
  await db.transaction('rw', [db.conversations, db.convoParticipants, db.messages], async () => {
    const remaining = await db.messages
      .where('[conversationId+internalDate]')
      .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
      .count()
    if (remaining > 0) return
    await db.conversations.delete(conversationId)
    await db.convoParticipants.where('conversationId').equals(conversationId).delete()
  })
}

function makeOptimisticMessage(
  id: string,
  conversationId: string,
  body: string,
  metadata: ReplyMetadata,
  sentAt: number,
  hasAttachments: boolean,
): MessageRow {
  const trimmedBody = body.trim()
  return {
    id,
    conversationId,
    gmThreadId: metadata.threadId,
    rfcMessageId: '',
    references: '',
    internalDate: sentAt,
    subject: metadata.subject,
    snippet: body.slice(0, 120),
    cleanedSnippet: createCleanSnippet(body, Number.POSITIVE_INFINITY, false) ?? '',
    chatPreviewText: trimmedBody,
    bodyText: body,
    hasHtmlBody: 0,
    senderEmail: normalizeEmail(metadata.replyFrom.email),
    senderName: metadata.replyFrom.displayName,
    deliveredToAddress: '',
    replyFromAddress: metadata.replyFrom.email,
    isFromMe: 1,
    isUnread: 0,
    isNewsletter: 0,
    isCalendarInvite: 0,
    hasAttachments: hasAttachments ? 1 : 0,
    labelIds: ['SENT'],
    localModifiedAt: 0,
    sendState: 'pending',
  }
}

// ---------------------------------------------------------------------------
// Reconcile / rollback / replay
// ---------------------------------------------------------------------------

/**
 * Finalizes a journal whose remote send committed: if sync already delivered
 * the sent copy, the optimistic row (and body, and attachments) is deleted;
 * otherwise the optimistic row's PK is swapped to the Gmail id (delete+add in
 * one tx, body moved, attachment rows re-parented and marked 'uploaded') and
 * marked sent. Idempotent; safe to re-run at startup.
 *
 * The swap deliberately keeps the attachment rows' `local_` ids: they are also
 * the blob keys, so renaming them would mean copying every attachment's bytes.
 * Sync adopts them into the server identity later — see
 * outboundAttachments.matchLocalAttachment, applied in sync/persist's
 * putAttachments when the sent copy comes back down.
 */
export async function reconcileCommittedSend(
  db: ChatmailDB,
  journalId: string,
  now: number = Date.now(),
): Promise<void> {
  const journal = await db.outboundSends.get(journalId)
  if (journal === undefined || journal.status !== 'committed') return
  const remoteId = journal.remoteCommittedMessageId
  if (remoteId === '') return

  await db.transaction(
    'rw',
    [db.messages, db.bodies, db.attachments, db.blobs, db.outboundSends],
    async () => {
      const syncedCopy = await db.messages.get(remoteId)
      const optimistic = await db.messages.get(journalId)

      if (syncedCopy !== undefined) {
        // Duplicate delivery: sync won the race; drop the optimistic row. Its
        // attachment rows go with it — the synced copy carries the server's
        // own rows, whose bytes are re-fetchable from Gmail, so keeping both
        // would show every attachment twice.
        if (optimistic !== undefined) {
          await deleteMessageAttachments(db, journalId)
          await db.messages.delete(journalId)
          await db.bodies.delete(journalId)
        }
      } else if (optimistic !== undefined) {
        await db.messages.delete(journalId)
        await db.messages.add({
          ...optimistic,
          id: remoteId,
          gmThreadId: journal.remoteCommittedThreadId,
          sendState: 'sent',
        })
        const body = await db.bodies.get(journalId)
        if (body !== undefined) {
          await db.bodies.delete(journalId)
          await db.bodies.add({ messageId: remoteId, html: body.html })
        }
        await db.attachments
          .where('messageId')
          .equals(journalId)
          .modify({ messageId: remoteId, state: 'uploaded' })
      }

      await db.outboundSends.update(journalId, { status: 'finalized' })
    },
  )

  await rollupConversation(db, journal.conversationId, now)
}

/** Deletes a message's attachment rows and their blobs (Dexie-only). */
async function deleteMessageAttachments(db: ChatmailDB, messageId: string): Promise<void> {
  const ids = await db.attachments.where('messageId').equals(messageId).primaryKeys()
  if (ids.length === 0) return
  await db.attachments.bulkDelete(ids)
  await db.blobs.bulkDelete(ids)
}

/**
 * Resolves a failed send. Returns true when the optimistic message was KEPT as
 * a retryable failed bubble.
 *
 * Port of handleFailedOptimisticMessage: a message carrying local attachments
 * survives (marked failed, attachments marked failed) because its bytes exist
 * nowhere else — deleting it would silently destroy the files the user picked.
 * A text-only message is removed, so nothing that was never sent can look
 * delivered.
 */
async function failSend(db: ChatmailDB, journalId: string, now: number): Promise<boolean> {
  const journal = await db.outboundSends.get(journalId)
  if (journal === undefined) return false

  const optimistic = await db.messages.get(journalId)
  const attachmentCount =
    optimistic === undefined ? 0 : await db.attachments.where('messageId').equals(journalId).count()

  if (optimistic === undefined || attachmentCount === 0) {
    await rollbackFailedSend(db, journalId, now)
    return false
  }

  await db.transaction(
    'rw',
    [db.messages, db.attachments, db.conversations, db.outboundSends],
    async () => {
      await db.messages.put({ ...optimistic, sendState: 'failed' })
      await db.attachments.where('messageId').equals(journalId).modify({ state: 'failed' })
      // The message stays, so the conversation's derived fields are recomputed
      // (not snapshot-restored) from the set that still includes it — the
      // failed bubble is genuinely the newest thing in this chat.
      await rollupConversation(db, journal.conversationId, now)
      await db.outboundSends.update(journalId, { status: 'failed' })
    },
  )
  return true
}

/**
 * Rolls back a failed send: deletes the optimistic row (+body), deletes the
 * conversation entirely when it was minted for this send and is now empty,
 * and marks the journal 'failed'. The surviving conversation's derived fields
 * are recomputed by rollupConversation from the messages that actually remain
 * — NOT restored from the journaled snapshot, which is stale the moment a
 * concurrent sync delivers an inbound message while the send is in flight
 * (a blind snapshot restore would regress lastMessageDate/snippet/archive
 * state over the newer real message).
 */
async function rollbackFailedSend(db: ChatmailDB, journalId: string, now: number): Promise<void> {
  const journal = await db.outboundSends.get(journalId)
  if (journal === undefined) return

  await db.transaction(
    'rw',
    [
      db.messages,
      db.bodies,
      db.attachments,
      db.blobs,
      db.conversations,
      db.convoParticipants,
      db.outboundSends,
    ],
    async () => {
      await deleteMessageAttachments(db, journalId)
      await db.messages.delete(journalId)
      await db.bodies.delete(journalId)

      const conversation = await db.conversations.get(journal.conversationId)
      if (conversation !== undefined) {
        const remaining = await db.messages
          .where('[conversationId+internalDate]')
          .between([conversation.id, Dexie.minKey], [conversation.id, Dexie.maxKey])
          .count()
        if (journal.newlyInsertedConversation === 1 && remaining === 0) {
          await db.conversations.delete(conversation.id)
          await db.convoParticipants.where('conversationId').equals(conversation.id).delete()
        } else {
          // Nests into this transaction (its table set is a subset).
          await rollupConversation(db, conversation.id, now)
        }
      }

      await db.outboundSends.update(journalId, { status: 'failed' })
    },
  )
}

export interface ReplayOptions {
  now?: () => number
}

/**
 * Startup recovery scan (OutboundSendMutationTracker replay /
 * reconcileAbandonedOptimisticSendMutations):
 * - finalized journals and orphaned failed journals older than the stale
 *   window are swept. A failed journal whose retryable attachment bubble still
 *   exists is retained because it owns the forward retry envelope;
 * - 'committed' journals (crash between remote accept and local reconcile)
 *   re-run the reconcile;
 * - 'pending' journals older than 10 minutes are abandoned sends (a crash
 *   mid-send): when the optimistic row is gone the journal is stale debris
 *   and deleted; when the row still exists it goes through the same failure
 *   path as a live send — iOS reconcileAbandonedOptimisticSendMutations routes
 *   journals with no remote-committed result through
 *   handleFailedOptimisticMessage, so a text-only message is deleted and the
 *   conversation restored, while one carrying attachments is kept as a
 *   retryable failed bubble. Otherwise the bubble would show "Sending…"
 *   forever with no code path ever resolving it.
 */
export async function replayAbandonedSends(
  db: ChatmailDB,
  opts: ReplayOptions = {},
): Promise<void> {
  const now = opts.now ?? Date.now

  const terminal = await db.outboundSends
    .where('status')
    .anyOf('failed', 'finalized')
    .filter((journal) => now() - journal.createdAt >= STALE_PENDING_SEND_MS)
    .toArray()
  const terminalIdsToDelete: string[] = []
  for (const journal of terminal) {
    const withForwardEnvelope: OutboundSendWithForwardEnvelope = journal
    if (journal.status === 'failed' && withForwardEnvelope.forwardEnvelope !== undefined) {
      const message = await db.messages.get(journal.id)
      if (message?.sendState === 'failed') continue
    }
    terminalIdsToDelete.push(journal.id)
  }
  if (terminalIdsToDelete.length > 0) await db.outboundSends.bulkDelete(terminalIdsToDelete)

  const committed = await db.outboundSends.where('status').equals('committed').toArray()
  for (const journal of committed) {
    await reconcileCommittedSend(db, journal.id, now())
  }

  const pending = await db.outboundSends.where('status').equals('pending').toArray()
  for (const journal of pending) {
    if (now() - journal.createdAt < STALE_PENDING_SEND_MS) continue
    const optimistic = await db.messages.get(journal.id)
    if (optimistic === undefined) {
      await db.outboundSends.delete(journal.id)
    } else {
      await failSend(db, journal.id, now())
    }
  }
}

/**
 * Re-sends a message left behind by a failed send (the attachment path). The
 * staged files are read back into memory and handed to sendMessage, which
 * deletes the failed graph — message, body, attachment rows and their blobs,
 * journal — inside its own optimistic transaction (replacesFailedMessageId).
 * A success therefore leaves exactly one bubble, a post-optimistic failure
 * leaves exactly one NEW failed bubble, and a pre-flight failure aborts the
 * delete along with the insert, leaving the ORIGINAL failed bubble — and the
 * only copy of the bytes — untouched and still retryable.
 */
export async function retryFailedSend(
  db: ChatmailDB,
  broker: TokenBroker,
  messageId: string,
  opts: SendOptions = {},
): Promise<SendResult> {
  const message = await db.messages.get(messageId)
  if (message === undefined) throw new SendFailedError('No message to retry')
  if (message.sendState !== 'failed') throw new SendFailedError('Message did not fail to send')

  const journal: OutboundSendWithForwardEnvelope | undefined = await db.outboundSends.get(messageId)
  const forwardEnvelope = journal?.forwardEnvelope
  const rows = await db.attachments.where('messageId').equals(messageId).toArray()
  const rowsById = new Map(rows.map((row) => [row.id, row]))
  const orderedRows =
    forwardEnvelope !== undefined
      ? forwardEnvelope.attachmentIds.map((id) => rowsById.get(id))
      : rows
  const attachments: PendingAttachment[] = []
  for (const row of orderedRows) {
    if (row === undefined) {
      throw new SendFailedError('A forwarded attachment is no longer available')
    }
    const blobRow = await db.blobs.get(row.id)
    if (blobRow === undefined) {
      if (forwardEnvelope !== undefined) {
        throw new SendFailedError('A forwarded attachment is no longer available')
      }
      continue
    }
    attachments.push({
      // A fresh id: the old row is deleted (inside the replacement's
      // optimistic transaction) along with its blob.
      id: newLocalAttachmentId(),
      filename: row.filename,
      mimeType: row.mimeType,
      blob: blobRow.blob,
      byteSize: blobRow.blob.size,
      width: row.width,
      height: row.height,
    })
  }

  // The failed graph is NOT deleted here. sendMessage deletes it inside its
  // optimistic transaction (replacesFailedMessageId), so a retry that fails
  // before that commit — invalid recipients, a conversation that vanished,
  // storage quota — leaves the failed bubble (and the only copy of the
  // attachment bytes) exactly where it was, still retryable.
  return sendMessage(
    db,
    broker,
    {
      conversationId: message.conversationId,
      body: message.bodyText,
      attachments,
      ...(forwardEnvelope !== undefined
        ? {
            forward: {
              subject: forwardEnvelope.metadata.subject,
              ...(forwardEnvelope.htmlBody !== undefined
                ? { htmlBody: forwardEnvelope.htmlBody }
                : {}),
            },
          }
        : {}),
    },
    {
      ...opts,
      replacesFailedMessageId: messageId,
      ...(forwardEnvelope !== undefined ? { preservedForwardEnvelope: forwardEnvelope } : {}),
    },
  )
}
