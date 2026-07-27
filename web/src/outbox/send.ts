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
//    one tx, body row moved), or deletes the optimistic row when sync
//    already delivered the sent copy;
// 5. failure deletes the optimistic row, recomputes the conversation rollup
//    from the messages that remain (never a blind snapshot restore, which
//    would clobber concurrent sync updates), and deletes a
//    newly-minted-and-now-empty conversation.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { MessageRow, OutboundSendRow } from '@/db/types'
import {
  sendMessage as sendMessageEndpoint,
  type EndpointOptions,
  type SendMessageParams,
} from '@/gmail/endpoints'
import type { SendMessageResponse } from '@/gmail/types'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { normalizeEmail } from '@/identity/normalizeEmail'
import {
  makeConversationIdentity,
  makeRecipientParticipantSetIdentity,
} from '@/identity/participantSet'
import { resolveConversation } from '@/identity/routing'
import { newId } from '@/lib/uuid'
import { createCleanSnippet } from '@/mime/preview'
import { conversationPreview, rollupConversation } from '@/rollup/rollup'
import { isAcceptedForSending, normalizedAliasAddress } from '@/sync/aliases'
import {
  buildNew,
  buildReply,
  InvalidRecipientsError,
  InvalidSenderError,
  NoValidRecipientsError,
  toBase64Url,
  type BuildNewInput,
} from './mimeBuilder'
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

  constructor(message: string, options?: { cause?: unknown; userMessage?: string }) {
    super(message, options)
    this.name = 'SendFailedError'
    this.userMessage = options?.userMessage ?? null
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
  return new SendFailedError('Send failed', { cause: error })
}

/** Network surface for the send call; injectable for tests. */
export interface SendApi {
  send(params: SendMessageParams): Promise<SendMessageResponse>
}

export function makeSendApi(broker: TokenBroker, options?: EndpointOptions): SendApi {
  return { send: (params) => sendMessageEndpoint(broker, params, options) }
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
}

export interface SendOptions {
  api?: SendApi
  now?: () => number
}

export interface SendResult {
  /** The Gmail message id the send committed as. */
  messageId: string
  conversationId: string
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
    const setIdentity = makeRecipientParticipantSetIdentity(draft.to ?? [], myAliases)
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
  let metadata: ReplyMetadata
  let mime: string
  try {
    metadata = await buildReplyMetadata(db, conversationId, myAliases)
    if (metadata.recipients.length === 0) {
      throw new SendFailedError('No recipients to send to', {
        userMessage: 'There is no one to send this message to.',
      })
    }
    if (draft.fromAlias !== undefined) {
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
    mime = buildOutboundMime(metadata, draft.body)
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
  )
  await db.transaction('rw', [db.conversations, db.messages, db.outboundSends], async () => {
    const conversation = await db.conversations.get(conversationId)
    if (conversation === undefined) throw new SendFailedError('Conversation not found')
    const journal: OutboundSendRow = {
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
    }
    await db.messages.add(optimistic)
    const preview = conversationPreview(optimistic)
    await db.conversations.put({
      ...conversation,
      lastMessageDate: sentAt,
      snippet: preview !== '' ? preview : conversation.snippet,
    })
    await db.outboundSends.add(journal)
  })

  // (d) Send. The endpoint never retransmits — an ambiguous failure must not
  // risk a duplicate email.
  let response: SendMessageResponse
  try {
    response = await api.send({
      raw: toBase64Url(mime),
      ...(metadata.threadId !== '' ? { threadId: metadata.threadId } : {}),
    })
  } catch (error) {
    // (f) Failure: roll back the optimistic graph.
    await rollbackFailedSend(db, optimisticId, now())
    throw new SendFailedError('Send failed', { cause: error })
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

/** Renders the outbound MIME; throws the builder's address-validation errors. */
function buildOutboundMime(metadata: ReplyMetadata, body: string): string {
  const mimeInput: BuildNewInput = {
    from: {
      email: metadata.replyFrom.email,
      ...(metadata.replyFrom.displayName !== '' ? { name: metadata.replyFrom.displayName } : {}),
    },
    to: metadata.recipients,
    textBody: body,
    ...(metadata.subject !== '' ? { subject: metadata.subject } : {}),
  }
  return metadata.inReplyTo !== ''
    ? buildReply({ ...mimeInput, inReplyTo: metadata.inReplyTo, references: metadata.references })
    : buildNew(mimeInput)
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
    hasAttachments: 0,
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
 * the sent copy, the optimistic row (and body) is deleted; otherwise the
 * optimistic row's PK is swapped to the Gmail id (delete+add in one tx, body
 * moved) and marked sent. Idempotent; safe to re-run at startup.
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

  await db.transaction('rw', [db.messages, db.bodies, db.outboundSends], async () => {
    const syncedCopy = await db.messages.get(remoteId)
    const optimistic = await db.messages.get(journalId)

    if (syncedCopy !== undefined) {
      // Duplicate delivery: sync won the race; drop the optimistic row.
      if (optimistic !== undefined) {
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
    }

    await db.outboundSends.update(journalId, { status: 'finalized' })
  })

  await rollupConversation(db, journal.conversationId, now)
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
    [db.messages, db.bodies, db.conversations, db.convoParticipants, db.outboundSends],
    async () => {
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
 * - terminal journals ('failed'/'finalized') older than the stale window are
 *   swept so the table (and queryOutboundStates scans) cannot grow forever;
 * - 'committed' journals (crash between remote accept and local reconcile)
 *   re-run the reconcile;
 * - 'pending' journals older than 10 minutes are abandoned sends (a crash
 *   mid-send): when the optimistic row is gone the journal is stale debris
 *   and deleted; when the row still exists it is rolled back like a failed
 *   send — iOS reconcileAbandonedOptimisticSendMutations routes journals with
 *   no remote-committed result through handleFailedOptimisticMessage, which
 *   deletes the optimistic message (no local attachments exist on web yet)
 *   and restores the conversation — otherwise the bubble would show
 *   "Sending…" forever with no code path ever resolving it.
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
    .primaryKeys()
  if (terminal.length > 0) await db.outboundSends.bulkDelete(terminal)

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
      await rollbackFailedSend(db, journal.id, now())
    }
  }
}
