// Retryable repair for conversations persisted under an obsolete participant
// identity. The signature gate makes the full scan cheap after it has observed
// the current alias set and every Person currently classified as Hide My Email.
// When the signature changes, the scan is a resumable walk over every message
// in bounded chunks, one transaction each (scalability review
// web-participant-repair-full-load), never one transaction over the store.

import { cmp } from 'dexie'
import { conversationMessagesQuery } from '@/db/conversationMessages'
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

/** Normalized email -> stored Person display name. */
export function personNames(people: readonly PersonRow[]): Map<string, string> {
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
  identity: Pick<ParticipantSetIdentity, 'participants'>,
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

/**
 * The title for `identity`'s participants from the stored Person names. The
 * stored-name repair (displayNameRepair.ts) re-derives titles with this too,
 * so the two repairs never write different titles for one conversation.
 */
export function conversationDisplayName(
  identity: Pick<ParticipantSetIdentity, 'participants'>,
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

/** syncState key holding an unfinished chunked pass (see RepairProgress). */
export const PARTICIPANT_SET_REPAIR_PROGRESS_KEY = 'participantSetRepairProgress'

/**
 * Messages read per chunk transaction, never more: a chunk may end partway
 * through the messages sharing one internalDate (see RepairProgress).
 */
export const PARTICIPANT_SET_REPAIR_CHUNK_SIZE = 500

/**
 * Durable position of an unfinished pass. The pass walks every message oldest
 * to newest, one rw transaction per chunk, and this row commits with each
 * chunk's moves. A tab killed mid-pass (an out-of-memory reload on a phone)
 * therefore resumes after the last committed chunk instead of replaying the
 * whole store, which on a large mailbox was a reload loop. The signature is
 * written only when the walk reaches the end.
 */
interface RepairProgress {
  /** The signature this walk is computing. A different current signature restarts it. */
  signature: string
  /**
   * With throughMessageId, the walk's position in the internalDate index:
   * every message ordered at or before (throughInternalDate, throughMessageId)
   * has been processed. Null before the first chunk.
   */
  throughInternalDate: number | null
  /**
   * The last processed message of throughInternalDate, in IndexedDB key order
   * (the index orders equal dates by primary key). Null or absent means the
   * whole date has been processed: rows written before this field existed
   * always ended a chunk on a date boundary.
   */
  throughMessageId?: string | null
  /** An earlier chunk deferred work for an active send, so the end of the walk must not write the signature. */
  blockedByActiveSend: boolean
  /**
   * Every shell this walk created: "active wins" applies to them in later
   * chunks too. The set is not narrowed to shells that are archived now.
   * Each chunk's rollup can auto-archive a shell that was created active or
   * already reactivated (its latest moved message is received and not in
   * INBOX), and a later chunk that moves an active source's message into it
   * must still reactivate it. Otherwise the chat's archive state would depend
   * on where the chunk boundaries fall.
   */
  createdDestinationIds: string[]
}

function isRepairProgress(value: unknown): value is RepairProgress {
  if (typeof value !== 'object' || value === null) return false
  const row = value as Partial<RepairProgress>
  return (
    typeof row.signature === 'string' &&
    (row.throughInternalDate === null || typeof row.throughInternalDate === 'number') &&
    (row.throughMessageId === undefined ||
      row.throughMessageId === null ||
      typeof row.throughMessageId === 'string') &&
    typeof row.blockedByActiveSend === 'boolean' &&
    Array.isArray(row.createdDestinationIds) &&
    row.createdDestinationIds.every((id) => typeof id === 'string')
  )
}

export interface ParticipantSetRepairOptions {
  /** Test seam; production uses PARTICIPANT_SET_REPAIR_CHUNK_SIZE. */
  chunkSize?: number
  /**
   * Test seam, awaited inside each chunk's transaction after its writes and
   * before it commits. A throw aborts that chunk, as a killed tab would.
   */
  beforeChunkCommit?: (chunkIndex: number) => void | Promise<void>
}

type ChunkOutcome =
  | { kind: 'notPerformed' }
  /** Committed nothing; run the same chunk again with a full read of its inputs. */
  | { kind: 'retry' }
  | {
      kind: 'chunk'
      done: boolean
      movedMessageCount: number
      createdConversationCount: number
      deletedConversationCount: number
      rebuiltConversationCount: number
    }

/**
 * The next at most `chunkSize` messages after the progress position, in
 * internalDate index order: by date, and by primary key within a date. That
 * order is a compound (internalDate, id) cursor over a single-field index, so
 * a date shared by more messages than a chunk holds is split across chunks
 * instead of being read whole (the store has no [internalDate+id] index, and
 * index changes wait for scalability step 14). The rest of a split date is
 * found by its primary keys alone, so even a huge tie group costs ids, not
 * rows. Processing follows the same order; nothing re-sorts the chunk, since
 * its last row must be the cursor's next position.
 */
async function readMessageChunk(
  db: ChatmailDB,
  progress: Pick<RepairProgress, 'throughInternalDate' | 'throughMessageId'>,
  chunkSize: number,
): Promise<MessageRow[]> {
  const date = progress.throughInternalDate
  if (date === null) return db.messages.orderBy('internalDate').limit(chunkSize).toArray()

  const chunk: MessageRow[] = []
  const throughId = progress.throughMessageId ?? null
  if (throughId !== null) {
    const restOfDate = (await db.messages.where('internalDate').equals(date).primaryKeys())
      .filter((id) => cmp(id, throughId) > 0)
      .slice(0, chunkSize)
    for (const row of await db.messages.bulkGet(restOfDate)) {
      if (row !== undefined) chunk.push(row)
    }
  }
  if (chunk.length < chunkSize) {
    chunk.push(
      ...(await db.messages
        .where('internalDate')
        .above(date)
        .limit(chunkSize - chunk.length)
        .toArray()),
    )
  }
  return chunk
}

/**
 * Whether `conversationId` holds an active optimistic send with no
 * MsgParticipant rows. The single-transaction pass found these by scanning
 * every message; a chunk sees only its own, so each conversation it consults
 * is checked through its own messages.
 *
 * Keys first: the conversation's message ids and the ids among them that have
 * participant rows both come from indexes without loading a message, so only
 * the rowless messages (optimistic sends, legacy imports) are read in full.
 * Neither sendState nor isFromMe is indexed, so this is the narrowest exact
 * candidate set; the predicate itself is unchanged.
 */
async function hasRowlessActiveOutgoing(
  db: ChatmailDB,
  conversationId: string,
  activeOutboundMessageIds: ReadonlySet<string>,
): Promise<boolean> {
  const messageIds = await conversationMessagesQuery(db, conversationId).primaryKeys()
  if (messageIds.length === 0) return false
  const withParticipantRows = new Set(
    await db.msgParticipants.where('messageId').anyOf(messageIds).uniqueKeys(),
  )
  const rowlessIds = messageIds.filter((id) => !withParticipantRows.has(id))
  if (rowlessIds.length === 0) return false
  for (const message of await db.messages.bulkGet(rowlessIds)) {
    if (
      message !== undefined &&
      isOutgoing(message) &&
      (message.sendState === 'pending' || activeOutboundMessageIds.has(message.id))
    ) {
      return true
    }
  }
  return false
}

/**
 * The walk's view of its signature inputs, carried from chunk to chunk within
 * one call so a chunk need not re-read the whole people table (scalability
 * review, PR 362 follow-up). See repairParticipantSetChunk for how a change
 * between chunks is still detected.
 */
interface WalkInputs {
  /** The normalized alias set the snapshot was taken under. */
  aliasesKey: string
  /** repairSignature over the full people read. */
  signature: string
  /** Normalized email -> display name: the full read, refreshed per chunk for the emails it reads. */
  names: Map<string, string>
}

interface WalkState {
  /** Null forces the next chunk to read every Person and recompute the signature. */
  inputs: WalkInputs | null
  /** Whether the [conversationId+internalDate] index holds every message row; computed on first need. */
  everyMessageIndexed: boolean | null
}

function aliasesKeyOf(myAliases: ReadonlySet<string>): string {
  return JSON.stringify([...myAliases].sort(compareSwiftStrings))
}

/**
 * Repairs participant-keyed conversations from persisted message participant
 * rows, as a chunked walk over every message oldest to newest. Each chunk is
 * one Dexie transaction holding its moves, deletions, rebuilt rows, rollups
 * and the progress row together: an exception rolls that chunk back and the
 * next call resumes from the last committed one. The signature marker is
 * written by the chunk that finds nothing left, so a walk interrupted partway
 * is retried, never mistaken for complete.
 *
 * Active optimistic sends never move. A terminal sent/failed row with no
 * MsgParticipant rows may move only when its source conversation rows provide
 * an unambiguous identity; otherwise the row remains anchored.
 */
export async function repairParticipantSetConversations(
  db: ChatmailDB,
  accountEmail: string,
  now: number = Date.now(),
  options: ParticipantSetRepairOptions = {},
): Promise<ParticipantSetRepairResult> {
  const chunkSize = Math.max(1, options.chunkSize ?? PARTICIPANT_SET_REPAIR_CHUNK_SIZE)
  const total: ParticipantSetRepairResult = { ...NOT_PERFORMED }
  const state: WalkState = { inputs: null, everyMessageIndexed: null }
  for (let chunkIndex = 0; ;) {
    const outcome = await repairParticipantSetChunk(
      db,
      accountEmail,
      now,
      chunkSize,
      chunkIndex,
      state,
      options.beforeChunkCommit,
    )
    if (outcome.kind === 'notPerformed') return total
    // A retry committed nothing and always leaves state.inputs null, so the
    // repeat reads its inputs in full and cannot ask for another retry.
    if (outcome.kind === 'retry') continue
    chunkIndex += 1
    total.performed = true
    total.movedMessageCount += outcome.movedMessageCount
    total.createdConversationCount += outcome.createdConversationCount
    total.deletedConversationCount += outcome.deletedConversationCount
    total.rebuiltConversationCount += outcome.rebuiltConversationCount
    if (outcome.done) return total
  }
}

async function repairParticipantSetChunk(
  db: ChatmailDB,
  accountEmail: string,
  now: number,
  chunkSize: number,
  chunkIndex: number,
  state: WalkState,
  beforeChunkCommit: ParticipantSetRepairOptions['beforeChunkCommit'],
): Promise<ChunkOutcome> {
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
    async (): Promise<ChunkOutcome> => {
      const account = await db.accounts.get(accountEmail)
      if (account === undefined) return { kind: 'notPerformed' }

      const myAliases = new Set(
        [account.email, ...(account.aliases ?? [])]
          .map(normalizeEmail)
          .filter((email) => email !== ''),
      )
      if (myAliases.size === 0) return { kind: 'notPerformed' }

      // People enrichment or an alias change between chunks makes the rest of
      // the walk's inputs differ from its signature, and the walk must then
      // restart. The first chunk of a call reads every Person; later chunks
      // reuse that snapshot and re-read only the Person rows of the emails
      // they consult (below), so a chunk costs its own rows, not the people
      // table. A chunk's identities depend only on those emails' names, so a
      // Hide-My-Email change elsewhere cannot alter its moves; it is caught
      // by the full read before the end of the walk writes the signature.
      const aliasesKey = aliasesKeyOf(myAliases)
      const fullRead = state.inputs === null || state.inputs.aliasesKey !== aliasesKey
      let previousSignature: unknown = undefined
      if (fullRead) {
        const people = await db.people.toArray()
        state.inputs = {
          aliasesKey,
          signature: repairSignature(myAliases, people),
          names: personNames(people),
        }
        previousSignature = (await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY))?.value
      }
      const inputs = state.inputs!
      const signature = inputs.signature

      const storedProgress = (await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY))?.value
      if (fullRead && previousSignature === signature) {
        // A progress row beside a matching marker was left by a walk under
        // another signature that never finished (aliases A done, walk B
        // killed, back to A). Resuming it when B returns would skip every
        // message at or before its cursor, so it goes. With no such row this
        // stays the read-only no-op that most calls are.
        if (storedProgress !== undefined) {
          await db.syncState.delete(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)
        }
        return { kind: 'notPerformed' }
      }

      // A walk for another signature restarts from the oldest message: its
      // committed chunks were computed under aliases or Hide-My-Email
      // classifications that no longer hold.
      const resuming = isRepairProgress(storedProgress) && storedProgress.signature === signature
      if (!fullRead && !resuming) {
        state.inputs = null
        return { kind: 'retry' }
      }
      const progress: RepairProgress = resuming
        ? storedProgress
        : {
            signature,
            throughInternalDate: null,
            throughMessageId: null,
            blockedByActiveSend: false,
            createdDestinationIds: [],
          }

      const messages = await readMessageChunk(db, progress, chunkSize)
      if (messages.length === 0 && !fullRead) {
        // The signature this walk began under is written only after a full
        // read confirms it still holds; a mismatch restarts the walk there.
        state.inputs = null
        return { kind: 'retry' }
      }
      if (messages.length === 0) {
        // Last write of the walk, by design. A deferral recorded by any chunk
        // withholds the marker, so the same inputs walk again once the send
        // reaches a terminal state.
        await db.syncState.delete(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)
        if (!progress.blockedByActiveSend) {
          await db.syncState.put({ key: PARTICIPANT_SET_REPAIR_SIGNATURE_KEY, value: signature })
        } else if (previousSignature !== undefined) {
          // See retireStaleMarker below.
          await db.syncState.delete(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)
        }
        await beforeChunkCommit?.(chunkIndex)
        return {
          kind: 'chunk',
          done: true,
          movedMessageCount: 0,
          createdConversationCount: 0,
          deletedConversationCount: 0,
          rebuiltConversationCount: 0,
        }
      }

      const rowsByMessage = participantRowsByMessage(
        await db.msgParticipants
          .where('messageId')
          .anyOf(messages.map((message) => message.id))
          .toArray(),
      )
      const sourceIds = [...new Set(messages.map((message) => message.conversationId))]
      const conversationsById = new Map<string, ConversationRow>()
      for (const row of await db.conversations.bulkGet(sourceIds)) {
        if (row !== undefined) conversationsById.set(row.id, row)
      }
      const rowsByConversation = participantRowsByConversation(
        await db.convoParticipants.where('conversationId').anyOf(sourceIds).toArray(),
      )
      const names = inputs.names
      if (!fullRead) {
        // Every name this chunk's identities can read: its messages' rows and
        // senders, and its source conversations' rows (destinations are
        // chosen by hash alone). A Hide-My-Email classification that differs
        // from the snapshot means the signature may have moved, so the chunk
        // is redone after a full read; any other name change is taken as is.
        const emails = new Set<string>()
        for (const rows of rowsByMessage.values()) {
          for (const row of rows) emails.add(normalizeEmail(row.email))
        }
        for (const message of messages) emails.add(normalizeEmail(message.senderEmail))
        for (const rows of rowsByConversation.values()) {
          for (const row of rows) emails.add(normalizeEmail(row.email))
        }
        emails.delete('')
        const keys = [...emails]
        const fresh = await db.people.bulkGet(keys)
        for (const [index, person] of fresh.entries()) {
          if (person === undefined) continue
          if (
            isHideMyEmailDisplayName(person.displayName) !==
            isHideMyEmailDisplayName(names.get(keys[index]!))
          ) {
            state.inputs = null
            return { kind: 'retry' }
          }
        }
        for (const [index, person] of fresh.entries()) {
          if (person !== undefined) names.set(keys[index]!, person.displayName)
        }
      }
      const identityByMessageId = new Map<string, ParticipantSetIdentity>()
      // An 'ambiguous' journal retains its row as sent under a local id until
      // the echo adopts it; moving or merging that row away would orphan the
      // reconciliation the same way as for a send still in flight.
      const activeOutboundSends = await db.outboundSends
        .where('status')
        .anyOf(['pending', 'committed', 'ambiguous'])
        .toArray()
      const activeOutboundMessageIds = new Set(activeOutboundSends.map((row) => row.id))
      const activeOutboundConversationIds = new Set(
        activeOutboundSends.map((row) => row.conversationId),
      )
      // Moves never change this answer: a rowless active send has no strict
      // identity and a protected source moves nothing, so it may be asked
      // before or after the chunk's moves.
      const protectionByConversation = new Map<string, boolean>()
      const isProtected = async (conversationId: string): Promise<boolean> => {
        const cached = protectionByConversation.get(conversationId)
        if (cached !== undefined) return cached
        const result =
          activeOutboundConversationIds.has(conversationId) ||
          (await hasRowlessActiveOutgoing(db, conversationId, activeOutboundMessageIds))
        protectionByConversation.set(conversationId, result)
        return result
      }
      // Same-hash candidates come from the participantHash index, so shells
      // created by earlier chunks are found like any other conversation.
      const conversationsByHash = new Map<string, ConversationRow[]>()
      const hashCandidates = async (participantHash: string): Promise<ConversationRow[]> => {
        const cached = conversationsByHash.get(participantHash)
        if (cached !== undefined) return cached
        const candidates: ConversationRow[] = []
        for (const row of await db.conversations
          .where('participantHash')
          .equals(participantHash)
          .toArray()) {
          const current = conversationsById.get(row.id) ?? row
          conversationsById.set(row.id, current)
          candidates.push(current)
        }
        conversationsByHash.set(participantHash, candidates)
        return candidates
      }
      const destinationByHash = new Map<string, ConversationRow>()
      const createdDestinationIds = new Set(progress.createdDestinationIds)
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
            messageParticipantRows.length === 0 &&
            isOutgoing(message) &&
            (await isProtected(source.id))
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
        if (source !== undefined && (await isProtected(source.id))) {
          blockedByActiveSend = true
          continue
        }

        let destination = destinationByHash.get(identity.participantHash)
        if (destination === undefined) {
          // An active send owns its shell and rollback snapshot. Do not let an
          // unrelated repair move messages into that shell or roll it up.
          const sameHashCandidates = await hashCandidates(identity.participantHash)
          // Native parity: `true` widens selection to the newest archived
          // epoch when no active one exists; this selector does not reactivate
          // it. The final rollup below remains the sole archive-state owner.
          destination = selectParticipantHashConversation(sameHashCandidates, true) ?? undefined
          if (destination !== undefined && (await isProtected(destination.id))) {
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
          // Every created shell, archived or not: see RepairProgress.
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
          // both active and archived source conversations, including ones a
          // later chunk reaches.
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

      // Because messages are ordered oldest-to-newest across chunks, the final
      // value is the destination of the source's latest moved message. That is
      // the stable recipient for pinned/muted state when a mixed source fully
      // drains.
      const lastDestinationBySource = new Map<string, string>()
      for (const move of moves) {
        lastDestinationBySource.set(move.sourceId, move.destinationId)
        move.message.conversationId = move.destinationId
        touchedConversationIds.add(move.sourceId)
        touchedConversationIds.add(move.destinationId)
      }
      // Only the conversation id changes; the rest of the row (bodyText
      // included) is never rewritten.
      if (moves.length > 0) {
        await db.messages.bulkUpdate(
          moves.map((move) => ({
            key: move.message.id,
            changes: { conversationId: move.destinationId },
          })),
        )
      }

      // failed/finalized journals are terminal and do not need a shell on
      // their own. A retryable failed attachment send still has its optimistic
      // MessageRow, so the remaining-message count protects that conversation
      // directly. The count reads the store after this chunk's moves, so it
      // covers the source's messages in every chunk, not just this one.
      const deletedConversationIds = new Set<string>()
      const replacementByDeletedSource = new Map<string, string>()

      for (const [sourceId, destinationId] of lastDestinationBySource) {
        if ((await conversationMessagesQuery(db, sourceId).count()) !== 0) continue
        // The count above sees only rows in the [conversationId+internalDate]
        // index, as does the walk. A row whose internalDate is not a valid key
        // (no writer stores one, but nothing enforces it) is in neither, so
        // its conversation would read as drained and be deleted under it.
        // Comparing the index's size with the table's is two key-only counts,
        // taken once per call: every writer stores a valid date, so a store
        // that passes cannot gain such a row between chunks. One that fails
        // keeps every drained source, which is merely an empty chat.
        state.everyMessageIndexed ??=
          (await db.messages.count()) ===
          (await db.messages.orderBy('[conversationId+internalDate]').count())
        if (!state.everyMessageIndexed) continue
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
      // identity for each conversation this chunk reached. This also fixes
      // stale addressing rows on conversations that did not have to move:
      // replies consume these rows directly, so hash parity alone is
      // insufficient.
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

      const currentConvoParticipants = participantRowsByConversation(
        residentIdentityByConversation.size === 0
          ? []
          : await db.convoParticipants
              .where('conversationId')
              .anyOf([...residentIdentityByConversation.keys()])
              .toArray(),
      )

      let rebuiltConversationCount = 0
      for (const [conversationId, identity] of residentIdentityByConversation) {
        const conversation = conversationsById.get(conversationId)
        if (conversation === undefined) continue

        const currentRows = currentConvoParticipants.get(conversationId) ?? []
        // A healthy conversation is left alone. Every chunk it appears in
        // reaches it again, and rewriting an unchanged row would wake every
        // live query on the conversations table for nothing.
        if (!conversationNeedsIdentityRepair(conversation, currentRows, identity, names)) continue
        // A pending/committed send owns its conversation shell until the
        // outbox reaches a terminal state. Defer only when repair is actually
        // needed so a healthy anchor cannot starve unrelated migration work.
        if (await isProtected(conversationId)) {
          blockedByActiveSend = true
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

        const displayName = conversationDisplayName(identity, names)
        if (conversation.type !== identity.type || conversation.displayName !== displayName) {
          const updated: ConversationRow = { ...conversation, type: identity.type, displayName }
          await db.conversations.put(updated)
          conversationsById.set(conversationId, updated)
        }
      }

      for (const conversationId of touchedConversationIds) {
        if (!deletedConversationIds.has(conversationId)) {
          await rollupConversation(db, conversationId, now)
        }
      }

      const lastMessage = messages[messages.length - 1]!
      const nextProgress: RepairProgress = {
        signature,
        throughInternalDate: lastMessage.internalDate,
        throughMessageId: lastMessage.id,
        blockedByActiveSend: progress.blockedByActiveSend || blockedByActiveSend,
        createdDestinationIds: [...createdDestinationIds],
      }
      await db.syncState.put({ key: PARTICIPANT_SET_REPAIR_PROGRESS_KEY, value: nextProgress })
      // retireStaleMarker: a marker for another signature claims a completed
      // walk over a store this chunk has now partly repaired under different
      // inputs. Left in place, a return to those inputs would no-op against
      // it with this chunk's moves still applied, so it goes with the moves.
      if (previousSignature !== undefined) {
        await db.syncState.delete(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)
      }
      await beforeChunkCommit?.(chunkIndex)

      return {
        kind: 'chunk',
        done: false,
        movedMessageCount: moves.length,
        createdConversationCount,
        deletedConversationCount: deletedConversationIds.size,
        rebuiltConversationCount,
      }
    },
  )
}
