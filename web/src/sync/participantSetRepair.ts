// Retryable repair for conversations persisted under an obsolete participant
// identity. The signature gate makes the full scan cheap after it has observed
// the current alias set and every Person currently classified as Hide My Email.

import { sha256Hex } from '@/identity/hash'
import { isHideMyEmailDisplayName, normalizeEmail } from '@/identity/normalizeEmail'
import {
  calculateParticipantHash,
  compareSwiftStrings,
  makeConversationIdentity,
  makeParticipantSetIdentity,
  type ParticipantSetIdentity,
} from '@/identity/participantSet'
import { selectParticipantHashConversation, reinsertConversationShell } from '@/identity/routing'
import { strictParticipantSetIdentity } from '@/identity/strictIdentity'
import { newId } from '@/lib/uuid'
import { conversationPreview, rollupConversation } from '@/rollup/rollup'
import type { ChatmailDB } from '@/db/schema'
import type {
  ConversationRow,
  ConvoParticipantRow,
  MessageRow,
  MsgParticipantRow,
  PersonRow,
} from '@/db/types'

export const PARTICIPANT_SET_REPAIR_SIGNATURE_KEY = 'participantSetRepairSignature'

// Bump whenever strict identity extraction or the repair algorithm changes in
// a way that requires stores which already completed the pass to run again.
const PARTICIPANT_SET_REPAIR_VERSION = 2

export interface ParticipantSetRepairResult {
  /** False means no account/aliases were available, or the signature matched. */
  performed: boolean
  movedMessageCount: number
  createdConversationCount: number
  deletedConversationCount: number
  rebuiltConversationCount: number
}

const NOT_PERFORMED: ParticipantSetRepairResult = {
  performed: false,
  movedMessageCount: 0,
  createdConversationCount: 0,
  deletedConversationCount: 0,
  rebuiltConversationCount: 0,
}

interface PlannedMove {
  message: MessageRow
  sourceId: string
  destinationId: string
}

function byMessageOrder(a: MessageRow, b: MessageRow): number {
  return a.internalDate - b.internalDate || compareSwiftStrings(a.id, b.id)
}

function participantRowsByMessage(
  rows: readonly MsgParticipantRow[],
): Map<string, MsgParticipantRow[]> {
  const grouped = new Map<string, MsgParticipantRow[]>()
  for (const row of rows) {
    const existing = grouped.get(row.messageId)
    if (existing === undefined) grouped.set(row.messageId, [row])
    else existing.push(row)
  }
  return grouped
}

function participantRowsByConversation(
  rows: readonly ConvoParticipantRow[],
): Map<string, ConvoParticipantRow[]> {
  const grouped = new Map<string, ConvoParticipantRow[]>()
  for (const row of rows) {
    const existing = grouped.get(row.conversationId)
    if (existing === undefined) grouped.set(row.conversationId, [row])
    else existing.push(row)
  }
  return grouped
}

function personNames(people: readonly PersonRow[]): Map<string, string> {
  const names = new Map<string, string>()
  for (const person of people) {
    const email = normalizeEmail(person.email)
    if (email !== '') names.set(email, person.displayName)
  }
  return names
}

function repairSignature(myAliases: ReadonlySet<string>, people: readonly PersonRow[]): string {
  const aliases = [...myAliases].sort(compareSwiftStrings)
  const hideMyEmailAddresses = [
    ...new Set(
      people
        .filter((person) => isHideMyEmailDisplayName(person.displayName))
        .map((person) => normalizeEmail(person.email))
        .filter((email) => email !== ''),
    ),
  ].sort(compareSwiftStrings)

  return sha256Hex(
    JSON.stringify({
      version: PARTICIPANT_SET_REPAIR_VERSION,
      aliases,
      hideMyEmailAddresses,
    }),
  )
}

function displayNamesForIdentity(
  identity: ParticipantSetIdentity,
  names: ReadonlyMap<string, string>,
): Record<string, string> {
  const result: Record<string, string> = {}
  for (const email of identity.participants) {
    const name = names.get(email)?.trim()
    if (name !== undefined && name !== '' && !isHideMyEmailDisplayName(name)) {
      result[email] = name
    }
  }
  return result
}

function conversationDisplayName(
  identity: ParticipantSetIdentity,
  names: ReadonlyMap<string, string>,
): string {
  const displayNames = displayNamesForIdentity(identity, names)
  return identity.participants.map((email) => displayNames[email] ?? email).join(', ')
}

/**
 * Repaired identity from conversation rows, but only when their raw,
 * self-filtered, or HME-repaired set reproduces the source hash. Otherwise the
 * rows are stale/ambiguous and cannot safely supplement message rows.
 */
function validatedConversationIdentity(
  conversation: ConversationRow,
  rows: readonly ConvoParticipantRow[],
  myAliases: ReadonlySet<string>,
  names: ReadonlyMap<string, string>,
): ParticipantSetIdentity | null {
  if (rows.length === 0 || rows.some((row) => row.role === 'listAddress')) return null

  const rawEmails = new Set<string>()
  for (const row of rows) {
    const email = normalizeEmail(row.email)
    if (email === '') return null
    rawEmails.add(email)
  }
  const withoutHideMyEmail = new Set(
    [...rawEmails].filter((email) => !isHideMyEmailDisplayName(names.get(email))),
  )
  const rawHash = calculateParticipantHash([...rawEmails])
  const selfFilteredIdentity = makeParticipantSetIdentity(rawEmails, myAliases)
  const repairedIdentity = makeParticipantSetIdentity(withoutHideMyEmail, myAliases)
  if (
    conversation.participantHash !== rawHash &&
    conversation.participantHash !== selfFilteredIdentity.participantHash &&
    conversation.participantHash !== repairedIdentity.participantHash
  ) {
    return null
  }
  return repairedIdentity
}

function isOutgoing(message: MessageRow): boolean {
  return message.isFromMe === 1 || message.labelIds.includes('SENT')
}

function isTerminalRowlessOutgoing(
  message: MessageRow,
  rows: readonly MsgParticipantRow[],
): boolean {
  return (
    rows.length === 0 &&
    isOutgoing(message) &&
    (message.sendState === 'sent' || message.sendState === 'failed')
  )
}

function sameParticipantRows(
  current: readonly ConvoParticipantRow[],
  expectedEmails: readonly string[],
): boolean {
  if (current.length !== expectedEmails.length) return false
  const expected = new Set(expectedEmails)
  const currentEmails = new Set(current.map((row) => normalizeEmail(row.email)))
  return (
    current.every((row) => row.role === 'normal') &&
    currentEmails.size === expected.size &&
    expectedEmails.every((email) => currentEmails.has(email))
  )
}

function conversationNeedsIdentityRepair(
  conversation: ConversationRow,
  currentRows: readonly ConvoParticipantRow[],
  identity: ParticipantSetIdentity,
  names: ReadonlyMap<string, string>,
): boolean {
  return (
    !sameParticipantRows(currentRows, identity.participants) ||
    conversation.type !== identity.type ||
    conversation.displayName !== conversationDisplayName(identity, names)
  )
}

/**
 * Repairs participant-keyed conversations from persisted message participant
 * rows. The whole operation, including its signature marker, is one Dexie
 * transaction: an exception rolls every move back and leaves the old marker so
 * the next sync retries.
 *
 * Active optimistic sends never move. A terminal sent/failed row with no
 * MsgParticipant rows may move only when its source conversation rows provide
 * an unambiguous identity; otherwise the row remains anchored.
 */
export async function repairParticipantSetConversations(
  db: ChatmailDB,
  accountEmail: string,
  now: number = Date.now(),
): Promise<ParticipantSetRepairResult> {
  return db.transaction(
    'rw',
    [
      db.accounts,
      db.syncState,
      db.conversations,
      db.messages,
      db.people,
      db.convoParticipants,
      db.msgParticipants,
      db.pendingActions,
      db.outboundSends,
    ],
    async () => {
      const account = await db.accounts.get(accountEmail)
      if (account === undefined) return NOT_PERFORMED

      const myAliases = new Set(
        [account.email, ...(account.aliases ?? [])]
          .map(normalizeEmail)
          .filter((email) => email !== ''),
      )
      if (myAliases.size === 0) return NOT_PERFORMED

      const people = await db.people.toArray()
      const signature = repairSignature(myAliases, people)
      const previousSignature = await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)
      if (previousSignature?.value === signature) return NOT_PERFORMED

      const [
        allMessages,
        allParticipantRows,
        initialConversations,
        initialConvoParticipantRows,
        outboundSends,
      ] = await Promise.all([
        db.messages.toArray(),
        db.msgParticipants.toArray(),
        db.conversations.toArray(),
        db.convoParticipants.toArray(),
        db.outboundSends.toArray(),
      ])
      const messages = allMessages.sort(byMessageOrder)
      const rowsByMessage = participantRowsByMessage(allParticipantRows)
      const rowsByConversation = participantRowsByConversation(initialConvoParticipantRows)
      const names = personNames(people)
      const identityByMessageId = new Map<string, ParticipantSetIdentity>()
      const conversationsById = new Map(initialConversations.map((row) => [row.id, row]))
      const activeOutboundSends = outboundSends.filter(
        (row) => row.status === 'pending' || row.status === 'committed',
      )
      const activeOutboundMessageIds = new Set(activeOutboundSends.map((row) => row.id))
      const activeOutboundConversationIds = new Set(
        activeOutboundSends.map((row) => row.conversationId),
      )
      const protectedConversationIds = new Set(activeOutboundConversationIds)
      for (const message of messages) {
        const rows = rowsByMessage.get(message.id) ?? []
        if (
          rows.length === 0 &&
          isOutgoing(message) &&
          (message.sendState === 'pending' || activeOutboundMessageIds.has(message.id))
        ) {
          protectedConversationIds.add(message.conversationId)
        }
      }
      const conversationsByHash = new Map<string, ConversationRow[]>()
      for (const conversation of initialConversations) {
        const candidates = conversationsByHash.get(conversation.participantHash)
        if (candidates === undefined) {
          conversationsByHash.set(conversation.participantHash, [conversation])
        } else {
          candidates.push(conversation)
        }
      }
      const destinationByHash = new Map<string, ConversationRow>()
      const createdDestinationIds = new Set<string>()
      const moves: PlannedMove[] = []
      const touchedConversationIds = new Set<string>()
      let createdConversationCount = 0
      let blockedByActiveSend = false

      for (const message of messages) {
        const messageParticipantRows = rowsByMessage.get(message.id) ?? []
        const source = conversationsById.get(message.conversationId)
        let identity = strictParticipantSetIdentity(
          messageParticipantRows,
          message.senderEmail,
          myAliases,
          names,
        )

        if (
          identity === null &&
          source !== undefined &&
          isTerminalRowlessOutgoing(message, messageParticipantRows)
        ) {
          identity = validatedConversationIdentity(
            source,
            rowsByConversation.get(source.id) ?? [],
            myAliases,
            names,
          )
        }

        if (identity === null) {
          if (
            source !== undefined &&
            protectedConversationIds.has(source.id) &&
            messageParticipantRows.length === 0 &&
            isOutgoing(message)
          ) {
            const eventualIdentity = validatedConversationIdentity(
              source,
              rowsByConversation.get(source.id) ?? [],
              myAliases,
              names,
            )
            if (
              eventualIdentity !== null &&
              (eventualIdentity.participantHash !== source.participantHash ||
                conversationNeedsIdentityRepair(
                  source,
                  rowsByConversation.get(source.id) ?? [],
                  eventualIdentity,
                  names,
                ))
            ) {
              blockedByActiveSend = true
            }
          }
          continue
        }

        // Older persistence kept only the first mailbox from a multi-address
        // From header even though conversation identity included every mailbox.
        // Raw From is no longer available here, so a normal participant that
        // appears only in the source rows is indistinguishable from a truncated
        // message row. Move only when removing current self/HME entries from a
        // hash-validated source produces the same strict identity as the message.
        if (source !== undefined && source.participantHash !== identity.participantHash) {
          const repairedSourceIdentity = validatedConversationIdentity(
            source,
            rowsByConversation.get(source.id) ?? [],
            myAliases,
            names,
          )
          if (
            repairedSourceIdentity === null ||
            repairedSourceIdentity.participantHash !== identity.participantHash
          ) {
            continue
          }
        }
        identityByMessageId.set(message.id, identity)

        if (source?.participantHash === identity.participantHash) continue
        if (source !== undefined && protectedConversationIds.has(source.id)) {
          blockedByActiveSend = true
          continue
        }

        let destination = destinationByHash.get(identity.participantHash)
        if (destination === undefined) {
          // An active send owns its shell and rollback snapshot. Do not let an
          // unrelated repair move messages into that shell or roll it up.
          const sameHashCandidates = conversationsByHash.get(identity.participantHash) ?? []
          // Native parity: `true` widens selection to the newest archived
          // epoch when no active one exists; this selector does not reactivate
          // it. The final rollup below remains the sole archive-state owner.
          destination = selectParticipantHashConversation(sameHashCandidates, true) ?? undefined
          if (destination !== undefined && protectedConversationIds.has(destination.id)) {
            // Bypassing the canonical protected destination could either mint
            // a parallel shell or revive an older archived epoch. Retry after
            // the send releases the selected destination instead.
            blockedByActiveSend = true
            continue
          }
        }

        if (destination === undefined) {
          destination = await reinsertConversationShell(
            db,
            newId(),
            makeConversationIdentity(identity, displayNamesForIdentity(identity, names)),
            {
              isInboxArrival: message.labelIds.includes('INBOX'),
              isUnread: message.isUnread === 1,
              messageDate: message.internalDate,
              snippet: conversationPreview(message),
            },
          )
          if (source !== undefined && source.isArchived !== 0) {
            // Sent-only/latest-outgoing rollups preserve the shell's current
            // archive state. Seed a replacement from its archived source so
            // historical sent mail does not resurface as a new active chat.
            destination = {
              ...destination,
              archivedAt: source.archivedAt,
              isArchived: source.isArchived,
            }
            await db.conversations.put(destination)
          }
          createdDestinationIds.add(destination.id)
          conversationsById.set(destination.id, destination)
          conversationsByHash.set(identity.participantHash, [destination])
          createdConversationCount += 1
        }
        if (
          source !== undefined &&
          source.isArchived === 0 &&
          destination.isArchived !== 0 &&
          createdDestinationIds.has(destination.id)
        ) {
          // Active wins if this newly created bucket combines messages from
          // both active and archived source conversations.
          destination = { ...destination, archivedAt: 0, isArchived: 0 }
          await db.conversations.put(destination)
          conversationsById.set(destination.id, destination)
        }
        destinationByHash.set(identity.participantHash, destination)

        moves.push({
          message,
          sourceId: message.conversationId,
          destinationId: destination.id,
        })
      }

      const finalMessageCount = new Map<string, number>()
      for (const message of messages) {
        finalMessageCount.set(
          message.conversationId,
          (finalMessageCount.get(message.conversationId) ?? 0) + 1,
        )
      }

      // Because messages are ordered oldest-to-newest, the final value is the
      // destination of the source's latest moved message. That is the stable
      // recipient for pinned/muted state when a mixed source fully drains.
      const lastDestinationBySource = new Map<string, string>()
      for (const move of moves) {
        finalMessageCount.set(move.sourceId, (finalMessageCount.get(move.sourceId) ?? 0) - 1)
        finalMessageCount.set(
          move.destinationId,
          (finalMessageCount.get(move.destinationId) ?? 0) + 1,
        )
        lastDestinationBySource.set(move.sourceId, move.destinationId)
        move.message.conversationId = move.destinationId
        touchedConversationIds.add(move.sourceId)
        touchedConversationIds.add(move.destinationId)
      }
      if (moves.length > 0) await db.messages.bulkPut(moves.map((move) => move.message))

      // failed/finalized journals are terminal and do not need a shell on
      // their own. A retryable failed attachment send still has its optimistic
      // MessageRow, so finalMessageCount protects that conversation directly.
      const deletedConversationIds = new Set<string>()
      const replacementByDeletedSource = new Map<string, string>()

      for (const [sourceId, destinationId] of lastDestinationBySource) {
        if ((finalMessageCount.get(sourceId) ?? 0) !== 0) continue
        // Normally a live send has a rowless optimistic MessageRow, which is
        // counted above. This also protects the tiny journal-before-row recovery
        // edge if another outbox transaction published only the journal.
        if (activeOutboundConversationIds.has(sourceId)) {
          blockedByActiveSend = true
          continue
        }

        const source = conversationsById.get(sourceId)
        const destination = conversationsById.get(destinationId)
        if (source === undefined || destination === undefined) continue

        if (
          (source.pinned === 1 && destination.pinned === 0) ||
          (source.muted === 1 && destination.muted === 0)
        ) {
          const updatedDestination: ConversationRow = {
            ...destination,
            pinned: source.pinned === 1 || destination.pinned === 1 ? 1 : 0,
            muted: source.muted === 1 || destination.muted === 1 ? 1 : 0,
          }
          await db.conversations.put(updatedDestination)
          conversationsById.set(destinationId, updatedDestination)
        }

        await db.convoParticipants.where('conversationId').equals(sourceId).delete()
        await db.conversations.delete(sourceId)
        conversationsById.delete(sourceId)
        deletedConversationIds.add(sourceId)
        replacementByDeletedSource.set(sourceId, destinationId)
      }

      if (replacementByDeletedSource.size > 0) {
        await db.pendingActions.toCollection().modify((row) => {
          const destinationId = replacementByDeletedSource.get(row.conversationId)
          if (destinationId !== undefined) row.conversationId = destinationId
        })
        await db.outboundSends.toCollection().modify((row) => {
          const destinationId = replacementByDeletedSource.get(row.conversationId)
          if (destinationId !== undefined) row.conversationId = destinationId
        })
      }

      // Use the post-move message ownership to find one resident strict
      // identity for each conversation. This also fixes stale addressing rows
      // on conversations that did not have to move: replies consume these rows
      // directly, so hash parity alone is insufficient.
      const residentIdentityByConversation = new Map<string, ParticipantSetIdentity>()
      for (const message of messages) {
        if (residentIdentityByConversation.has(message.conversationId)) continue
        const conversation = conversationsById.get(message.conversationId)
        const identity = identityByMessageId.get(message.id)
        if (
          conversation !== undefined &&
          identity !== undefined &&
          conversation.participantHash === identity.participantHash
        ) {
          residentIdentityByConversation.set(message.conversationId, identity)
        }
      }

      const currentConvoParticipants = new Map<string, ConvoParticipantRow[]>()
      for (const row of await db.convoParticipants.toArray()) {
        const existing = currentConvoParticipants.get(row.conversationId)
        if (existing === undefined) currentConvoParticipants.set(row.conversationId, [row])
        else existing.push(row)
      }

      let rebuiltConversationCount = 0
      for (const [conversationId, identity] of residentIdentityByConversation) {
        const conversation = conversationsById.get(conversationId)
        if (conversation === undefined) continue

        const currentRows = currentConvoParticipants.get(conversationId) ?? []
        // A pending/committed send owns its conversation shell until the
        // outbox reaches a terminal state. Defer only when repair is actually
        // needed so a healthy anchor cannot starve unrelated migration work.
        if (protectedConversationIds.has(conversationId)) {
          if (conversationNeedsIdentityRepair(conversation, currentRows, identity, names)) {
            blockedByActiveSend = true
          }
          continue
        }

        if (!sameParticipantRows(currentRows, identity.participants)) {
          await db.convoParticipants.where('conversationId').equals(conversationId).delete()
          for (const email of identity.participants) {
            if (!names.has(email)) {
              await db.people.put({ email, displayName: '' })
              names.set(email, '')
            }
          }
          await db.convoParticipants.bulkPut(
            identity.participants.map((email) => ({
              conversationId,
              email,
              role: 'normal' as const,
            })),
          )
          rebuiltConversationCount += 1
        }

        const updated: ConversationRow = {
          ...conversation,
          type: identity.type,
          displayName: conversationDisplayName(identity, names),
        }
        await db.conversations.put(updated)
        conversationsById.set(conversationId, updated)
      }

      for (const conversationId of touchedConversationIds) {
        if (!deletedConversationIds.has(conversationId)) {
          await rollupConversation(db, conversationId, now)
        }
      }

      // Last write by design. A thrown read/write above aborts the transaction,
      // so the old signature remains and a later sync retries the whole pass.
      if (!blockedByActiveSend) {
        await db.syncState.put({ key: PARTICIPANT_SET_REPAIR_SIGNATURE_KEY, value: signature })
      }

      return {
        performed: true,
        movedMessageCount: moves.length,
        createdConversationCount,
        deletedConversationCount: deletedConversationIds.size,
        rebuiltConversationCount,
      }
    },
  )
}
