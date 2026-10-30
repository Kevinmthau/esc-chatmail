// Optimistic send pipeline. Port of Services/Send/
// {GmailSendService+OptimisticUpdates,OutboundMessageCoordinator,
// OutboundSendMutationTracker}.swift.
//
// Ordering invariants carried over:
// 0. the MIME is built BEFORE anything optimistic exists, so an address the
//    builder refuses fails the send with nothing to roll back;
// 1. optimistic message + conversation bump + journal write in ONE tx; the
//    row carries the deterministic Message-ID the MIME emits
//    (mimeBuilder.messageIdForOptimisticSend), so a reply can thread onto it
//    before sync echoes it and the echo can be matched back to it;
// 2. the Gmail send call is NEVER retransmitted (endpoints.sendMessage), and
//    the journal records admission (admittedAt) right before it, so cold
//    recovery can tell a crash before the request from one after it;
// 3. on acceptance the journal is stamped 'committed' with the remote ids
//    BEFORE local reconciliation, so a crash between the two is recoverable
//    at startup (replayAbandonedSends); a failure after admission that is not
//    a definite rejection is recorded as 'ambiguous' and the row is retained
//    as sent, never resent — see the outcome matrix at step (d);
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

import Dexie, { type Table } from 'dexie'
import { BlobQuotaExceededError, putBlob } from '@/db/blobs'
import type { ChatmailDB } from '@/db/schema'
import type { AttachmentRow, MessageRow, OutboundSendRow } from '@/db/types'
import {
  sendMessage as sendMessageEndpoint,
  type EndpointOptions,
  type SendMessageParams,
} from '@/gmail/endpoints'
import {
  AuthRequiredError,
  GmailApiError,
  NetworkError,
  QuotaExhaustedError,
  RateLimitError,
} from '@/gmail/errors'
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
  messageIdForOptimisticSend,
  MessageTooLargeError,
  NoValidRecipientsError,
  optimisticSendIdFromMessageId,
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
  /**
   * Send a NEW message into `conversationId` rather than a reply: no 'Re: '
   * subject, no In-Reply-To/References, no threadId. retryFailedSend sets it
   * for a retained row that first went out without a thread (a plain compose,
   * or a reply whose target had no thread id yet), so the retry keeps the
   * headers the first attempt had instead of threading onto whatever is newest
   * now. Ignored without conversationId: the compose path is always new.
   */
  asNewMessage?: boolean
}

export interface SendOptions {
  api?: SendApi
  now?: () => number
  /** Network-path source for the pre-transmission gate; the browser's by default. */
  connectivity?: SendConnectivity
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

/**
 * Journal status for a send Gmail may have accepted: the request was admitted
 * and no verdict came back (OutboundSendRemoteState.ambiguousMessageID). The
 * row is retained as sent under its local id until sync echoes the server copy
 * (reconcileSyncedSendEcho) and is never resent. This module reads and writes
 * the journal through journalTable, whose row type also carries the unindexed
 * forward-retry envelope.
 */
export const AMBIGUOUS_SEND_STATUS = 'ambiguous'

type OutboundSendJournalStatus = OutboundSendRow['status'] | typeof AMBIGUOUS_SEND_STATUS

/**
 * Unindexed additions to the journal row (no Dexie migration): the forward
 * retry envelope, and the transmission-admission marker.
 */
interface OutboundSendJournalExtras {
  forwardEnvelope?: PreservedForwardEnvelope
  /**
   * Epoch ms the request was handed to the transport. Written immediately
   * before api.send (iOS recordRemoteSendAdmission): a journal still 'pending'
   * with this set may have been processed by Gmail, one without it never
   * reached the network.
   */
  admittedAt?: number
}

/** The journal as this module reads it; OutboundSendRow is assignable to it. */
type OutboundSendJournal = Omit<OutboundSendRow, 'status'> & {
  status: OutboundSendJournalStatus
} & OutboundSendJournalExtras

/**
 * The outbound journal with this module's wider row type. The stored shape is
 * the same table; only the status union and the unindexed extras differ, so
 * the one cast lives here.
 */
function journalTable(db: ChatmailDB): Table<OutboundSendJournal, string> {
  return db.outboundSends
}

export interface SendResult {
  /**
   * The Gmail message id the send committed as — or, when delivery is
   * 'unknown', the local row id the message is retained under.
   */
  messageId: string
  conversationId: string
  /**
   * 'committed' when Gmail acknowledged the send; 'unknown' when the request
   * was admitted but no verdict came back (5xx, transport failure, lost
   * response). Both are successful admissions to the composer: the message
   * row stays and is never resent. sendMessage always sets it; it is optional
   * only so a stub result predating it still satisfies the type.
   */
  delivery?: 'committed' | 'unknown'
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

  // The optimistic id is minted before the MIME is built: the Message-ID the
  // header carries derives from it, and the same value is stored on the row
  // (makeOptimisticMessage) so the two can never disagree.
  // newId(), not crypto.randomUUID: the latter is secure-context-only.
  const optimisticId = newId()
  const rfcMessageId = messageIdForOptimisticSend(optimisticId)

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
    const isNewMessage =
      draft.conversationId === undefined ||
      draft.forward !== undefined ||
      draft.asNewMessage === true
    if (preservedForward === undefined && isNewMessage) {
      // A compose or a forward is not a reply (iOS .compose/.forward requests
      // carry threadId nil and no reply metadata). buildReplyMetadata targets
      // the conversation's newest message, so a new message to someone you
      // already chat with would otherwise inherit that message's subject
      // ('Re: …'), its In-Reply-To/References chain and its Gmail thread —
      // the recipient sees a subjectless note arrive as a reply stitched under
      // a months-old mail. Recipients and the reply-from alias still come from
      // the ladder; everything threading-related is dropped so this goes out
      // as a new message. The web compose sheet has no subject field, so a
      // plain compose sends '(No Subject)' exactly like iOS newMessage mode.
      metadata = {
        ...metadata,
        subject: draft.forward?.subject ?? '',
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
        rfcMessageId,
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
  const sentAt = now()
  const optimistic = makeOptimisticMessage(
    optimisticId,
    rfcMessageId,
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
        const journal: OutboundSendJournal = {
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
        await journalTable(db).add(journal)
      },
    )
  } catch (error) {
    // Nothing was committed (the transaction aborted whole), so this is still
    // the pre-optimistic world: drop a conversation minted in (a) and report.
    if (newlyInserted) await deleteEmptyConversation(db, conversationId)
    throw asSendFailure(error)
  }

  // (d) Send. The endpoint never retransmits — Gmail's messages.send has no
  // idempotency key, so an ambiguous failure must not risk a duplicate email.
  //
  // Outcome matrix (port of the OutboundMessageCoordinator post-barrier
  // matrix; misclassifying a new error class here is a duplicate-send hazard):
  //
  //   before the optimistic insert   address/size/quota rejection → thrown as
  //                                  SendFailedError with nothing to roll back
  //   definite rejection             GmailApiError 4xx, RateLimitError (429 is
  //                                  refused before processing — the transport
  //                                  already retransmits on it for that
  //                                  reason), QuotaExhaustedError (a 403
  //                                  verdict), AuthRequiredError → failSend:
  //                                  text-only rolled back, with attachments
  //                                  kept as a retryable failed bubble
  //   ambiguous                      GmailApiError 5xx, NetworkError (fetch
  //                                  rejected mid-flight: the web cannot prove
  //                                  the request never arrived), a failed
  //                                  response parse after a 2xx, and anything
  //                                  else thrown once admitted → the row is
  //                                  retained as sent and the journal marked
  //                                  'ambiguous' (recordAmbiguousSend); the
  //                                  send SUCCEEDS to the composer so no draft
  //                                  is restored and no retry is offered, and
  //                                  sync's echo replaces the row later
  //
  // Admission is journaled first (admittedAt): a crash between here and the
  // verdict leaves a 'pending' journal that replayAbandonedSends must treat as
  // ambiguous, not as never sent.
  if (!(await waitForUsablePath(opts.connectivity ?? browserConnectivity()))) {
    const kept = await failSend(db, optimisticId, now())
    throw new SendFailedError('No internet connection', {
      cause: new NetworkError('The browser reports no network path'),
      userMessage: 'You appear to be offline. Check your connection and try again.',
      keptFailedMessage: kept,
      conversationId,
    })
  }
  if (attachments.length > 0) await markAttachmentState(db, optimisticId, 'uploading')
  await recordSendAdmission(db, optimisticId, now())

  let response: SendMessageResponse
  try {
    response = await api.send({
      raw,
      ...(metadata.threadId !== '' ? { threadId: metadata.threadId } : {}),
    })
  } catch (error) {
    if (!isDefiniteSendRejection(error)) {
      await recordAmbiguousSend(db, optimisticId, now())
      return { messageId: optimisticId, conversationId, delivery: 'unknown' }
    }
    // (f) Definite rejection: roll the optimistic graph back, or keep it as a
    // retryable failed bubble when it carries attachments.
    const kept = await failSend(db, optimisticId, now())
    throw new SendFailedError('Send failed', {
      cause: error,
      ...(error instanceof QuotaExhaustedError
        ? {
            userMessage:
              'Gmail refused the send: this account has used up its sending quota for today.',
          }
        : {}),
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

  return { messageId: response.id, conversationId, delivery: 'committed' }
}

/**
 * True when Gmail refused the request without processing it, so the message
 * was definitely not sent: a 4xx verdict, a rate limit (429 is issued before
 * the request body is acted on, which is also why the transport retransmits
 * sends on it), a quota refusal (a 403 verdict the transport re-types, iOS
 * isAmbiguousSendFailure: "rate/quota rejection ... prove Gmail did not commit
 * send"), or an authentication refusal. Everything else thrown after
 * admission is ambiguous — including the untyped SyntaxError a lost or
 * malformed 2xx body raises in endpoints.sendMessage, which is why this is an
 * allow-list and not a deny-list.
 */
export function isDefiniteSendRejection(error: unknown): boolean {
  if (error instanceof GmailApiError) return error.status < 500
  return (
    error instanceof RateLimitError ||
    error instanceof QuotaExhaustedError ||
    error instanceof AuthRequiredError
  )
}

/**
 * The browser's view of the network path, as the pre-transmission gate reads
 * it. `isOnline` is navigator.onLine: false only when the browser KNOWS there
 * is no path (airplane mode, every interface down); true also covers a path
 * that may not reach Gmail, which is what the post-admission matrix is for.
 */
export interface SendConnectivity {
  isOnline: () => boolean
  /** Resolves when the browser reports a path again, or after `timeoutMs`. */
  waitForOnline: (timeoutMs: number) => Promise<void>
}

/** NetworkConfig.sendConnectivityWaitTimeout on iOS. */
export const SEND_CONNECTIVITY_WAIT_MS = 30_000

function browserConnectivity(): SendConnectivity {
  const nav = globalThis.navigator as { onLine?: boolean } | undefined
  return {
    isOnline: () => nav?.onLine !== false,
    waitForOnline: (timeoutMs) =>
      new Promise((resolve) => {
        const target = globalThis as unknown as EventTarget | undefined
        if (target === undefined || typeof target.addEventListener !== 'function') {
          resolve()
          return
        }
        const done = (): void => {
          clearTimeout(timer)
          target.removeEventListener('online', done)
          resolve()
        }
        const timer = setTimeout(done, timeoutMs)
        target.addEventListener('online', done)
      }),
  }
}

/**
 * Pre-transmission connectivity gate (port of
 * OutboundConnectivityGate.waitForUsablePath): on a known-absent path the
 * send waits, bounded, for the path to return and otherwise fails BEFORE
 * admission, so an offline tap is a definite "not sent" (text-only rolled
 * back with the draft restored, attachments kept as a retryable bubble)
 * rather than a request whose fetch rejection the post-admission matrix must
 * read as ambiguous. navigator.onLine cannot tell a dropped request from no
 * network at all, so this is the only place offline is distinguished.
 */
async function waitForUsablePath(connectivity: SendConnectivity): Promise<boolean> {
  if (connectivity.isOnline()) return true
  await connectivity.waitForOnline(SEND_CONNECTIVITY_WAIT_MS)
  return connectivity.isOnline()
}

/** Stamps the transmission-admission marker on a pending journal. */
async function recordSendAdmission(db: ChatmailDB, journalId: string, now: number): Promise<void> {
  const journals = journalTable(db)
  const journal = await journals.get(journalId)
  if (journal === undefined || journal.status !== 'pending') return
  await journals.put({ ...journal, admittedAt: now })
}

/**
 * Records a send whose verdict never arrived (port of
 * recordAmbiguousRemoteSend): the optimistic row is retained as sent under its
 * local id, its attachment rows marked uploaded (the bytes are local and
 * render), and the journal marked 'ambiguous'. Nothing here may invite a
 * resend — the recipient may already have the message. Sync matches the echo
 * by the row's deterministic Message-ID (reconcileSyncedSendEcho); until then
 * the row shows as sent. Only a 'pending' journal transitions: a journal the
 * echo already finalized keeps that verdict.
 */
async function recordAmbiguousSend(db: ChatmailDB, journalId: string, now: number): Promise<void> {
  await db.transaction(
    'rw',
    [
      db.messages,
      db.attachments,
      db.conversations,
      db.convoParticipants,
      db.people,
      db.outboundSends,
    ],
    async () => {
      const journals = journalTable(db)
      const journal = await journals.get(journalId)
      if (journal === undefined || journal.status !== 'pending') return
      const optimistic = await db.messages.get(journalId)
      if (optimistic !== undefined) {
        await db.messages.put({ ...optimistic, sendState: 'sent' })
        await db.attachments.where('messageId').equals(journalId).modify({ state: 'uploaded' })
        await rollupConversation(db, journal.conversationId, now)
      }
      await journals.put({ ...journal, status: AMBIGUOUS_SEND_STATUS })
    },
  )
}

/** Echo of an own send as sync parsed it from the server copy. */
export interface SyncedSendEcho {
  /** Message-ID header of the synced copy (angle brackets included). */
  rfcMessageId: string
  /** Gmail message id of the synced copy. */
  remoteMessageId: string
  remoteThreadId: string
}

/**
 * Adopts sync's echo of a send this device made, identified by the
 * deterministic Message-ID the optimistic row was stamped with: the journal is
 * committed with the echo's ids and reconciled exactly as an acknowledged send
 * is (reconcileCommittedSend), which swaps the row's PK to the Gmail id and
 * re-parents its attachment rows when the echo has not been inserted yet, or
 * drops the local row when it has. This is how a delivery-unknown send
 * ('ambiguous' journal) converges; it also settles a 'pending' journal whose
 * verdict is still in flight — the later verdict finds the journal finalized
 * and leaves it so. Returns false when the Message-ID names no live journal.
 *
 * Intended caller: sync/persist, before its apply transaction (this runs its
 * own transactions and a rollup), for a from-me message whose
 * optimisticSendIdFromMessageId is non-null.
 */
export async function reconcileSyncedSendEcho(
  db: ChatmailDB,
  echo: SyncedSendEcho,
  now: number = Date.now(),
): Promise<boolean> {
  const optimisticId = optimisticSendIdFromMessageId(echo.rfcMessageId)
  if (optimisticId === null) return false
  const journals = journalTable(db)
  const journal = await journals.get(optimisticId)
  if (journal === undefined) return false
  if (journal.status === 'finalized' || journal.status === 'failed') return false
  if (journal.status !== 'committed') {
    await journals.put({
      ...journal,
      status: 'committed',
      remoteCommittedMessageId: echo.remoteMessageId,
      remoteCommittedThreadId: echo.remoteThreadId,
    })
  }
  await reconcileCommittedSend(db, optimisticId, now)
  return true
}

/**
 * Settles a delivery-unknown send whose echo sync has already stored under
 * its Gmail id: the server copy carries the deterministic Message-ID the row
 * was stamped with (the messages table indexes rfcMessageId), so it is found
 * without the sync pipeline's help and adopted through reconcileSyncedSendEcho,
 * which drops the retained local row. Until sync/persist reconciles echoes
 * itself this runs at startup only, so the chat shows the echo beside the
 * retained row until the next launch. False when no echo has arrived.
 */
async function adoptStoredEchoOfAmbiguousSend(
  db: ChatmailDB,
  journal: OutboundSendJournal,
  now: number,
): Promise<boolean> {
  const rfcMessageId = messageIdForOptimisticSend(journal.id)
  const echo = (await db.messages.where('rfcMessageId').equals(rfcMessageId).toArray()).find(
    (row) => row.id !== journal.id && row.isFromMe === 1,
  )
  if (echo === undefined) return false
  return reconcileSyncedSendEcho(
    db,
    { rfcMessageId, remoteMessageId: echo.id, remoteThreadId: echo.gmThreadId },
    now,
  )
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
  messageId: string,
  htmlBody?: string,
): string {
  const mimeInput: BuildNewInput = {
    from: {
      email: metadata.replyFrom.email,
      ...(metadata.replyFrom.displayName !== '' ? { name: metadata.replyFrom.displayName } : {}),
    },
    to: metadata.recipients,
    messageId,
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

/**
 * The optimistic row. Its rfcMessageId is the Message-ID the MIME went out
 * with and its references the chain the header carried, so a reply composed
 * before sync echoes this message threads onto it exactly as it would onto the
 * server copy (buildReplyMetadata), and the echo is matched back to this row
 * (reconcileSyncedSendEcho).
 */
function makeOptimisticMessage(
  id: string,
  rfcMessageId: string,
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
    rfcMessageId,
    references: metadata.inReplyTo !== '' ? metadata.references.join(' ') : '',
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
  const journal = await journalTable(db).get(journalId)
  // Only a pending send can fail: a journal sync's echo already finalized
  // (reconcileSyncedSendEcho raced the verdict) proves the message was sent.
  if (journal === undefined || journal.status !== 'pending') return false

  const optimistic = await db.messages.get(journalId)
  const attachmentCount =
    optimistic === undefined ? 0 : await db.attachments.where('messageId').equals(journalId).count()

  if (optimistic === undefined || attachmentCount === 0) {
    await rollbackFailedSend(db, journalId, now)
    return false
  }

  await db.transaction(
    'rw',
    [
      db.messages,
      db.attachments,
      db.conversations,
      db.convoParticipants,
      db.people,
      db.outboundSends,
    ],
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
      db.people,
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
 * - 'ambiguous' journals are retained for as long as their row exists: the
 *   journal is what marks the row as delivery-unknown, and sync's echo is the
 *   only thing that settles it — adopted here when sync has already stored
 *   it (adoptStoredEchoOfAmbiguousSend). One whose row is gone is stale
 *   debris;
 * - 'pending' journals older than 10 minutes are abandoned sends (a crash
 *   mid-send): when the optimistic row is gone the journal is stale debris
 *   and deleted. When the row still exists, the admission marker decides, as
 *   iOS reconcileAbandonedOptimisticSendMutations does with its in-flight
 *   marker: a send admitted to the transport (admittedAt set) may have been
 *   processed by Gmail and is preserved as delivery-unknown, never retried;
 *   one never admitted goes through the same failure path as a live definite
 *   rejection — a text-only message is deleted and the conversation restored,
 *   one carrying attachments is kept as a retryable failed bubble. Otherwise
 *   the bubble would show "Sending…" forever with no code path resolving it.
 *   Cold recovery never retries: it only converts markers.
 */
export async function replayAbandonedSends(
  db: ChatmailDB,
  opts: ReplayOptions = {},
): Promise<void> {
  const now = opts.now ?? Date.now
  const journals = journalTable(db)

  const terminal = await journals
    .where('status')
    .anyOf('failed', 'finalized')
    .filter((journal) => now() - journal.createdAt >= STALE_PENDING_SEND_MS)
    .toArray()
  const terminalIdsToDelete: string[] = []
  for (const journal of terminal) {
    if (journal.status === 'failed' && journal.forwardEnvelope !== undefined) {
      const message = await db.messages.get(journal.id)
      if (message?.sendState === 'failed') continue
    }
    terminalIdsToDelete.push(journal.id)
  }
  if (terminalIdsToDelete.length > 0) await journals.bulkDelete(terminalIdsToDelete)

  const committed = await journals.where('status').equals('committed').toArray()
  for (const journal of committed) {
    await reconcileCommittedSend(db, journal.id, now())
  }

  const ambiguous = await journals.where('status').equals(AMBIGUOUS_SEND_STATUS).toArray()
  for (const journal of ambiguous) {
    if (await adoptStoredEchoOfAmbiguousSend(db, journal, now())) continue
    if (now() - journal.createdAt < STALE_PENDING_SEND_MS) continue
    if ((await db.messages.get(journal.id)) === undefined) {
      await journals.delete(journal.id)
    }
  }

  const pending = await journals.where('status').equals('pending').toArray()
  for (const journal of pending) {
    if (now() - journal.createdAt < STALE_PENDING_SEND_MS) continue
    const optimistic = await db.messages.get(journal.id)
    if (optimistic === undefined) {
      await journals.delete(journal.id)
    } else if (journal.admittedAt !== undefined) {
      await recordAmbiguousSend(db, journal.id, now())
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

  const journal = await journalTable(db).get(messageId)
  // A delivery-unknown send is retained as sent, so the sendState check above
  // already refuses it; the journal is the durable word on it, and a resend of
  // a message Gmail may have delivered is the one outcome this path must never
  // produce.
  if (journal?.status === AMBIGUOUS_SEND_STATUS) {
    throw new SendFailedError('Message may already have been delivered')
  }
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
      // A retained row with no thread went out as a new message (a plain
      // compose, or a reply whose target had no thread yet); the retry must
      // not turn it into a 'Re:' threaded under whatever is newest now.
      ...(forwardEnvelope === undefined && message.gmThreadId === '' ? { asNewMessage: true } : {}),
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
