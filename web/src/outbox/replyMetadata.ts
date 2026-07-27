// Reply metadata for composing into an existing conversation. Port of
// Services/Compose/ReplyMetadataBuilder.swift (+ OutboundReplyContextBuilder
// and the ReplyAddressHint ladder from ReplySnapshots.swift): recipients come
// from the conversation's PARTICIPANT rows (not the last message's headers),
// threading targets the newest message, and the reply-from alias is selected
// via the shared sync/replyFrom ladder.

import Dexie from 'dexie'
import type { ChatmailDB } from '@/db/schema'
import type { MessageRow, MsgParticipantRow, SendAsAlias } from '@/db/types'
import { normalizeEmail } from '@/identity/normalizeEmail'
import { deduplicated, normalizedAliasAddress } from '@/sync/aliases'
import { selectReplyFromAlias } from '@/sync/replyFrom'

export interface ReplyMetadata {
  /** Conversation participants minus the user's own aliases (normalized compare). */
  recipients: string[]
  /** 'Re: '-prefixed target subject ('' when the target has none). */
  subject: string
  /** Gmail thread id of the newest message; '' when it is optimistic/absent. */
  threadId: string
  /** RFC Message-ID of the newest message; '' when absent. */
  inReplyTo: string
  /** Target's References chain + its own Message-ID, deduped, order kept. */
  references: string[]
  /** Alias the reply must be sent from (throws SendAsAliasUnavailableError). */
  replyFrom: SendAsAlias
}

/** 'Re: ' prefix, idempotent and case-insensitive (MimeBuilder.prefixSubjectForReply). */
export function prefixSubjectForReply(subject: string): string {
  const trimmed = subject.trim()
  if (trimmed === '') return ''
  if (trimmed.toLowerCase().startsWith('re:')) return trimmed
  return `Re: ${trimmed}`
}

function buildReferences(referencesHeader: string, rfcMessageId: string): string[] {
  const chain = referencesHeader.split(/\s+/u).filter((ref) => ref !== '')
  if (rfcMessageId !== '') chain.push(rfcMessageId)
  const seen = new Set<string>()
  const deduped: string[] = []
  for (const ref of chain) {
    if (seen.has(ref)) continue
    seen.add(ref)
    deduped.push(ref)
  }
  return deduped
}

// ---------------------------------------------------------------------------
// Reply-address hints (ReplySnapshots.swift ReplyAddressHint)
// ---------------------------------------------------------------------------

interface ReplyAddressHint {
  deliveredToAddress: string | null
  replyFromAddress: string | null
}

function nonEmptyAddress(value: string): string | null {
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

/** Hint from the message's own stored addresses; null when both are empty. */
function storedAddressHint(message: MessageRow): ReplyAddressHint | null {
  const deliveredToAddress = nonEmptyAddress(message.deliveredToAddress)
  const replyFromAddress = nonEmptyAddress(message.replyFromAddress)
  if (deliveredToAddress === null && replyFromAddress === null) return null
  return { deliveredToAddress, replyFromAddress }
}

const RECIPIENT_KIND_RANK: Record<string, number> = { to: 0, cc: 1, bcc: 2 }

/**
 * Fallback when a message carries no stored addresses (persisted while the
 * alias list was empty): an alias matched among its To/Cc/Bcc participant
 * rows, sorted by kind rank then email, preferring a non-default alias
 * (ReplyAddressHint.participantAddressHint).
 */
function participantAddressHint(
  participants: readonly MsgParticipantRow[],
  aliases: readonly SendAsAlias[],
): ReplyAddressHint | null {
  if (aliases.length === 0) return null

  const recipients = participants
    .filter((row) => RECIPIENT_KIND_RANK[row.kind] !== undefined)
    .sort((a, b) => {
      const rankDiff = (RECIPIENT_KIND_RANK[a.kind] ?? 0) - (RECIPIENT_KIND_RANK[b.kind] ?? 0)
      if (rankDiff !== 0) return rankDiff
      return a.email.toLowerCase().localeCompare(b.email.toLowerCase())
    })

  const matches: SendAsAlias[] = []
  for (const row of recipients) {
    const normalized = normalizedAliasAddress(row.email)
    const alias = aliases.find((a) => normalizedAliasAddress(a.email) === normalized)
    if (alias !== undefined) matches.push(alias)
  }

  const alias = matches.find((a) => !a.isDefault) ?? matches[0]
  if (alias === undefined) return null
  return { deliveredToAddress: alias.email, replyFromAddress: alias.email }
}

/** Stored addresses first, then the participant-derived alias match. */
async function replyAddressHint(
  db: ChatmailDB,
  message: MessageRow,
  aliases: readonly SendAsAlias[],
): Promise<ReplyAddressHint | null> {
  const stored = storedAddressHint(message)
  if (stored !== null) return stored
  const participants = await db.msgParticipants.where('messageId').equals(message.id).toArray()
  return participantAddressHint(participants, aliases)
}

/**
 * Conversation-level hint: the newest non-fromMe message that yields a hint
 * (ReplyConversationSnapshot.latestReplyAddressHint).
 */
async function conversationAddressHint(
  db: ChatmailDB,
  messagesNewestFirst: readonly MessageRow[],
  aliases: readonly SendAsAlias[],
): Promise<ReplyAddressHint | null> {
  for (const message of messagesNewestFirst) {
    if (message.isFromMe === 1) continue
    const hint = await replyAddressHint(db, message, aliases)
    if (hint !== null) return hint
  }
  return null
}

/**
 * Builds the metadata needed to send a reply into `conversationId`.
 * @param myAliases Normalized identity aliases (account row `aliases`) used to
 *   exclude self from the recipient list.
 */
export async function buildReplyMetadata(
  db: ChatmailDB,
  conversationId: string,
  myAliases: ReadonlySet<string>,
): Promise<ReplyMetadata> {
  const account = await db.accounts.toCollection().first()
  if (account === undefined) {
    throw new Error('No account row; cannot build reply metadata')
  }

  const participants = await db.convoParticipants
    .where('conversationId')
    .equals(conversationId)
    .toArray()
  const recipients = participants
    .map((row) => row.email)
    .filter((email) => !myAliases.has(normalizeEmail(email)))

  const messages = await db.messages
    .where('[conversationId+internalDate]')
    .between([conversationId, Dexie.minKey], [conversationId, Dexie.maxKey])
    .toArray()
  const newestFirst = [...messages].reverse()
  const target = newestFirst[0]

  // Reply-from resolution ladder (ReplyMetadataBuilder: `replyingTo ??
  // conversation` per field): the target's stored addresses, then an alias
  // among its To/Cc/Bcc participants, then the newest non-fromMe message's
  // hint conversation-wide.
  const hintAliases = deduplicated(account.sendAsAliases)
  const targetHint = target !== undefined ? await replyAddressHint(db, target, hintAliases) : null
  let convoHint: ReplyAddressHint | null = null
  if (
    targetHint === null ||
    targetHint.replyFromAddress === null ||
    targetHint.deliveredToAddress === null
  ) {
    convoHint = await conversationAddressHint(db, newestFirst, hintAliases)
  }

  const replyFrom = selectReplyFromAlias(
    targetHint?.replyFromAddress ?? convoHint?.replyFromAddress ?? null,
    targetHint?.deliveredToAddress ?? convoHint?.deliveredToAddress ?? null,
    account.sendAsAliases,
    { fallbackEmail: account.email },
  )

  if (target === undefined) {
    return { recipients, subject: '', threadId: '', inReplyTo: '', references: [], replyFrom }
  }

  return {
    recipients,
    subject: prefixSubjectForReply(target.subject),
    threadId: target.gmThreadId,
    inReplyTo: target.rfcMessageId,
    references: buildReferences(target.references, target.rfcMessageId),
    replyFrom,
  }
}
