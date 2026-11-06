import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MsgParticipantRow } from '@/db/types'
import { makeParticipantSetIdentity } from '@/identity/participantSet'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
  PARTICIPANT_SET_REPAIR_PROGRESS_KEY,
  PARTICIPANT_SET_REPAIR_SIGNATURE_KEY,
  repairParticipantSetConversations,
} from './participantSetRepair'
import { makeTestDb, ME, NOW, seedAccount } from './testSupport'

const ALICE = 'alice@example.com'
const BOB = 'bob@example.com'
const RELAY = 'relay@privaterelay.appleid.com'
const WORK_ALIAS = 'me@work.example'
const MY_ALIASES = new Set([ME])

function hashFor(...emails: string[]): string {
  return makeParticipantSetIdentity(new Set(emails), MY_ALIASES).participantHash
}

function participant(
  messageId: string,
  email: string,
  kind: MsgParticipantRow['kind'],
  displayName = '',
): MsgParticipantRow {
  return { messageId, email, displayName, kind }
}

let db: ChatmailDB

beforeEach(async () => {
  db = makeTestDb()
  await seedAccount(db)
})

afterEach(async () => {
  await db.delete()
})

describe('repairParticipantSetConversations', () => {
  it('atomically merges a stale HME conversation and preserves user state, addressing, and rollup', async () => {
    const source = convoRow({
      id: 'source',
      participantHash: hashFor(ALICE, RELAY),
      pinned: 1,
      muted: 1,
      lastMessageDate: 300,
    })
    const destination = convoRow({
      id: 'destination',
      participantHash: hashFor(ALICE),
      lastMessageDate: 100,
      snippet: 'older',
    })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.bulkAdd([
      msgRow({
        id: 'old-destination-message',
        conversationId: destination.id,
        internalDate: 100,
        cleanedSnippet: 'older',
        isUnread: 0,
      }),
      msgRow({
        id: 'stale-message',
        conversationId: source.id,
        internalDate: 300,
        cleanedSnippet: 'newest',
        isUnread: 1,
      }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('old-destination-message', ALICE, 'from', 'Alice'),
      participant('old-destination-message', ME, 'to'),
      participant('stale-message', ALICE, 'from', 'Alice'),
      participant('stale-message', ME, 'to'),
      participant('stale-message', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    // Hash-correct but recipient-stale: reply metadata reads these rows, so the
    // repair must rebuild them even though the destination already exists.
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
      { conversationId: destination.id, email: RELAY, role: 'normal' },
    ])
    const actionId = await db.pendingActions.add({
      actionType: 'archiveConversation',
      status: 'pending',
      messageId: '',
      conversationId: source.id,
      messageIds: ['stale-message'],
      retryCount: 0,
      createdAt: NOW,
      lastAttempt: 0,
    })

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result).toMatchObject({
      performed: true,
      movedMessageCount: 1,
      createdConversationCount: 0,
      deletedConversationCount: 1,
      rebuiltConversationCount: 1,
    })
    expect(await db.conversations.get(source.id)).toBeUndefined()
    expect((await db.messages.get('stale-message'))?.conversationId).toBe(destination.id)
    expect(
      await db.convoParticipants.where('conversationId').equals(destination.id).toArray(),
    ).toEqual([{ conversationId: destination.id, email: ALICE, role: 'normal' }])
    expect(await db.pendingActions.get(actionId)).toMatchObject({ conversationId: destination.id })

    const repaired = await db.conversations.get(destination.id)
    expect(repaired).toMatchObject({
      participantHash: hashFor(ALICE),
      displayName: 'Alice',
      pinned: 1,
      muted: 1,
      lastMessageDate: 300,
      latestInboxDate: 300,
      hasInbox: 1,
      inboxUnreadCount: 1,
      snippet: 'newest',
    })
  })

  it('does not guess when legacy message rows omit a normal source participant', async () => {
    const source = convoRow({
      id: 'mixed-source',
      participantHash: hashFor(ALICE, BOB),
      pinned: 1,
      muted: 1,
    })
    await db.conversations.add(source)
    await db.messages.bulkAdd([
      msgRow({ id: 'alice-message', conversationId: source.id, internalDate: 100 }),
      msgRow({ id: 'bob-message', conversationId: source.id, internalDate: 200 }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('alice-message', ALICE, 'from', 'Alice'),
      participant('alice-message', ME, 'to'),
      participant('bob-message', BOB, 'from', 'Bob'),
      participant('bob-message', ME, 'to'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: BOB, displayName: 'Bob' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: BOB, role: 'normal' },
    ])

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result).toMatchObject({
      movedMessageCount: 0,
      createdConversationCount: 0,
      deletedConversationCount: 0,
      rebuiltConversationCount: 0,
    })
    expect(await db.conversations.get(source.id)).toMatchObject({ pinned: 1, muted: 1 })
    expect((await db.messages.get('alice-message'))?.conversationId).toBe(source.id)
    expect((await db.messages.get('bob-message'))?.conversationId).toBe(source.id)
    expect(await db.convoParticipants.where('conversationId').equals(source.id).toArray()).toEqual([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: BOB, role: 'normal' },
    ])
  })

  it('keeps a legacy multi-From message whose persisted row retained only the first sender', async () => {
    const source = convoRow({
      id: 'legacy-multi-from',
      participantHash: hashFor(ALICE, BOB),
      pinned: 1,
    })
    await db.conversations.add(source)
    await db.messages.add(
      msgRow({
        id: 'legacy-multi-from-message',
        conversationId: source.id,
        senderEmail: ALICE,
      }),
    )
    // Before the persistence fix, the conversation was correctly keyed and
    // seeded from the full raw From header but MsgParticipant retained only
    // its first mailbox. Repair has no raw header with which to disambiguate
    // this from a true one-sender message, so it must leave the row anchored.
    await db.msgParticipants.bulkAdd([
      participant('legacy-multi-from-message', ALICE, 'from', 'Alice'),
      participant('legacy-multi-from-message', ME, 'to'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: BOB, displayName: 'Bob' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: BOB, role: 'normal' },
    ])

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result).toMatchObject({
      movedMessageCount: 0,
      createdConversationCount: 0,
      deletedConversationCount: 0,
      rebuiltConversationCount: 0,
    })
    expect((await db.messages.get('legacy-multi-from-message'))?.conversationId).toBe(source.id)
    expect(await db.conversations.get(source.id)).toMatchObject({
      participantHash: hashFor(ALICE, BOB),
      pinned: 1,
    })
  })

  it.each([
    {
      activeJournalStatus: 'committed',
      terminalMessageState: 'sent',
      terminalJournalStatus: 'finalized',
    },
    {
      activeJournalStatus: 'pending',
      terminalMessageState: 'failed',
      terminalJournalStatus: 'failed',
    },
  ] as const)(
    'defers an active rowless send, then repairs it after it becomes $terminalMessageState',
    async ({ activeJournalStatus, terminalMessageState, terminalJournalStatus }) => {
      const source = convoRow({
        id: 'optimistic-source',
        participantHash: hashFor(ALICE, RELAY),
        pinned: 1,
        muted: 1,
      })
      const destination = convoRow({
        id: 'alice-destination',
        participantHash: hashFor(ALICE),
        pinned: 0,
        muted: 0,
      })
      await db.conversations.bulkAdd([source, destination])
      await db.messages.bulkAdd([
        msgRow({ id: 'stale', conversationId: source.id, internalDate: 100 }),
        msgRow({
          id: 'optimistic',
          conversationId: source.id,
          internalDate: 500,
          isFromMe: 1,
          labelIds: ['SENT'],
          sendState: 'pending',
          cleanedSnippet: 'still sending',
        }),
      ])
      await db.msgParticipants.bulkAdd([
        participant('stale', ALICE, 'from'),
        participant('stale', ME, 'to'),
        participant('stale', RELAY, 'cc'),
      ])
      await db.people.bulkPut([
        { email: ALICE, displayName: 'Alice' },
        { email: RELAY, displayName: 'Hide My Email' },
      ])
      await db.convoParticipants.bulkPut([
        { conversationId: source.id, email: ALICE, role: 'normal' },
        { conversationId: source.id, email: RELAY, role: 'normal' },
        { conversationId: source.id, email: ME, role: 'me' },
        { conversationId: destination.id, email: ALICE, role: 'normal' },
      ])
      await db.outboundSends.add({
        id: 'optimistic',
        conversationId: source.id,
        newlyInsertedConversation: 0,
        createdAt: NOW,
        status: activeJournalStatus,
        conversationSnapshot: null,
        remoteCommittedMessageId: '',
        remoteCommittedThreadId: '',
      })

      const activeResult = await repairParticipantSetConversations(db, ME, NOW)

      expect(activeResult).toMatchObject({ movedMessageCount: 0, deletedConversationCount: 0 })
      expect((await db.messages.get('stale'))?.conversationId).toBe(source.id)
      expect((await db.messages.get('optimistic'))?.conversationId).toBe(source.id)
      // The signature must remain incomplete so the same inputs retry once the
      // active send atomically reaches a terminal state.
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()

      const terminalMessageId =
        terminalMessageState === 'sent' ? 'remote-sent-message' : 'optimistic'
      if (terminalMessageState === 'sent') {
        const optimistic = await db.messages.get('optimistic')
        expect(optimistic).toBeDefined()
        await db.messages.delete('optimistic')
        await db.messages.add({
          ...optimistic!,
          id: terminalMessageId,
          sendState: terminalMessageState,
        })
      } else {
        await db.messages.update('optimistic', { sendState: terminalMessageState })
      }
      await db.outboundSends.update('optimistic', { status: terminalJournalStatus })
      const terminalResult = await repairParticipantSetConversations(db, ME, NOW + 1)

      expect(terminalResult).toMatchObject({ movedMessageCount: 2, deletedConversationCount: 1 })
      expect((await db.messages.get('stale'))?.conversationId).toBe(destination.id)
      expect((await db.messages.get(terminalMessageId))?.conversationId).toBe(destination.id)
      expect(await db.conversations.get(source.id)).toBeUndefined()
      expect(await db.conversations.get(destination.id)).toMatchObject({ pinned: 1, muted: 1 })
      expect(await db.outboundSends.get('optimistic')).toMatchObject({
        conversationId: destination.id,
      })
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
    },
  )

  it.each(['pending', 'committed'] as const)(
    'does not select or mutate a $status send conversation as an unrelated repair destination',
    async (status) => {
      const source = convoRow({
        id: 'unrelated-stale-source',
        participantHash: hashFor(ALICE, RELAY),
        lastMessageDate: 100,
      })
      const protectedDestination = convoRow({
        id: 'protected-send-destination',
        participantHash: hashFor(ALICE),
        displayName: 'Alice',
        snippet: 'still sending',
        lastMessageDate: 500,
        latestInboxDate: 0,
        hasInbox: 0,
        pinned: 1,
      })
      const archivedFallback = convoRow({
        id: 'older-archived-destination',
        participantHash: hashFor(ALICE),
        archivedAt: 50,
        isArchived: 1,
        lastMessageDate: 50,
      })
      await db.conversations.bulkAdd([source, protectedDestination, archivedFallback])
      await db.messages.bulkAdd([
        msgRow({
          id: 'unrelated-stale-message',
          conversationId: source.id,
          internalDate: 100,
        }),
        msgRow({
          id: 'protected-optimistic-message',
          conversationId: protectedDestination.id,
          internalDate: 500,
          isFromMe: 1,
          labelIds: ['SENT'],
          sendState: 'pending',
          cleanedSnippet: 'still sending',
        }),
      ])
      await db.msgParticipants.bulkAdd([
        participant('unrelated-stale-message', ALICE, 'from', 'Alice'),
        participant('unrelated-stale-message', ME, 'to'),
        participant('unrelated-stale-message', RELAY, 'cc'),
      ])
      await db.people.bulkPut([
        { email: ALICE, displayName: 'Alice' },
        { email: RELAY, displayName: 'Hide My Email' },
      ])
      const protectedParticipantRows = [
        { conversationId: protectedDestination.id, email: ALICE, role: 'normal' as const },
      ]
      await db.convoParticipants.bulkPut([
        { conversationId: source.id, email: ALICE, role: 'normal' },
        { conversationId: source.id, email: RELAY, role: 'normal' },
        ...protectedParticipantRows,
      ])
      await db.outboundSends.add({
        id: 'protected-optimistic-message',
        conversationId: protectedDestination.id,
        newlyInsertedConversation: 0,
        createdAt: NOW,
        status,
        conversationSnapshot: null,
        remoteCommittedMessageId: status === 'committed' ? 'remote-message' : '',
        remoteCommittedThreadId: status === 'committed' ? 'remote-thread' : '',
      })

      const result = await repairParticipantSetConversations(db, ME, NOW)

      expect(result).toMatchObject({
        movedMessageCount: 0,
        createdConversationCount: 0,
        deletedConversationCount: 0,
      })
      expect((await db.messages.get('unrelated-stale-message'))?.conversationId).toBe(source.id)
      expect(await db.conversations.get(source.id)).toEqual(source)
      expect(await db.conversations.get(protectedDestination.id)).toEqual(protectedDestination)
      expect(await db.conversations.get(archivedFallback.id)).toEqual(archivedFallback)
      expect(
        await db.convoParticipants
          .where('conversationId')
          .equals(protectedDestination.id)
          .toArray(),
      ).toEqual(protectedParticipantRows)
      expect(await db.outboundSends.get('protected-optimistic-message')).toMatchObject({
        conversationId: protectedDestination.id,
        status,
      })
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()

      await db.messages.update('protected-optimistic-message', { sendState: 'sent' })
      await db.outboundSends.update('protected-optimistic-message', { status: 'finalized' })
      const terminalResult = await repairParticipantSetConversations(db, ME, NOW + 1)

      expect(terminalResult).toMatchObject({
        movedMessageCount: 1,
        createdConversationCount: 0,
        deletedConversationCount: 1,
      })
      expect((await db.messages.get('unrelated-stale-message'))?.conversationId).toBe(
        protectedDestination.id,
      )
      expect(await db.conversations.get(source.id)).toBeUndefined()
      expect(await db.conversations.get(archivedFallback.id)).toEqual(archivedFallback)
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
    },
  )

  it('defers a protected resident rebuild until its send becomes terminal', async () => {
    const protectedConversation = convoRow({
      id: 'protected-stale-addressing',
      participantHash: hashFor(ALICE),
      displayName: 'Stale Alice',
    })
    await db.conversations.add(protectedConversation)
    await db.messages.bulkAdd([
      msgRow({ id: 'protected-resident', conversationId: protectedConversation.id }),
      msgRow({
        id: 'protected-optimistic',
        conversationId: protectedConversation.id,
        internalDate: NOW,
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'pending',
      }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('protected-resident', ALICE, 'from', 'Alice'),
      participant('protected-resident', ME, 'to'),
    ])
    await db.people.put({ email: ALICE, displayName: 'Alice' })
    const staleRows = [
      { conversationId: protectedConversation.id, email: ALICE, role: 'normal' as const },
      { conversationId: protectedConversation.id, email: ME, role: 'me' as const },
    ]
    await db.convoParticipants.bulkPut(staleRows)
    await db.outboundSends.add({
      id: 'protected-optimistic',
      conversationId: protectedConversation.id,
      newlyInsertedConversation: 0,
      createdAt: NOW,
      status: 'pending',
      conversationSnapshot: null,
      remoteCommittedMessageId: '',
      remoteCommittedThreadId: '',
    })

    const activeResult = await repairParticipantSetConversations(db, ME, NOW)

    expect(activeResult).toMatchObject({ movedMessageCount: 0, rebuiltConversationCount: 0 })
    expect(await db.conversations.get(protectedConversation.id)).toEqual(protectedConversation)
    expect(
      await db.convoParticipants.where('conversationId').equals(protectedConversation.id).toArray(),
    ).toEqual(staleRows)
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()

    await db.messages.update('protected-optimistic', { sendState: 'sent' })
    await db.outboundSends.update('protected-optimistic', { status: 'finalized' })
    const terminalResult = await repairParticipantSetConversations(db, ME, NOW + 1)

    expect(terminalResult).toMatchObject({ movedMessageCount: 0, rebuiltConversationCount: 1 })
    expect(await db.conversations.get(protectedConversation.id)).toMatchObject({
      displayName: 'Alice',
    })
    expect(
      await db.convoParticipants.where('conversationId').equals(protectedConversation.id).toArray(),
    ).toEqual([{ conversationId: protectedConversation.id, email: ALICE, role: 'normal' }])
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
  })

  it('does not guess for a terminal rowless message whose conversation rows are ambiguous', async () => {
    const source = convoRow({
      id: 'ambiguous-source',
      participantHash: hashFor(ALICE, RELAY),
    })
    await db.conversations.add(source)
    await db.messages.add(
      msgRow({
        id: 'ambiguous-sent',
        conversationId: source.id,
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'sent',
      }),
    )
    // These rows hash to Alice, not the source's Alice+relay hash. They cannot
    // prove which identity the rowless message was originally composed into.
    await db.convoParticipants.add({
      conversationId: source.id,
      email: ALICE,
      role: 'normal',
    })

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result.movedMessageCount).toBe(0)
    expect((await db.messages.get('ambiguous-sent'))?.conversationId).toBe(source.id)
    expect(await db.conversations.get(source.id)).toBeDefined()
  })

  it('selects an archived destination without reactivating it unless rollup policy requires it', async () => {
    const source = convoRow({ id: 'archived-source', participantHash: hashFor(ALICE, RELAY) })
    const archivedDestination = convoRow({
      id: 'archived-destination',
      participantHash: hashFor(ALICE),
      lastMessageDate: 200,
      latestInboxDate: 0,
      hasInbox: 0,
      archivedAt: 400,
      isArchived: 1,
    })
    await db.conversations.bulkAdd([source, archivedDestination])
    await db.messages.add(
      msgRow({
        id: 'archived-message',
        conversationId: source.id,
        internalDate: 300,
        labelIds: [],
        isUnread: 0,
      }),
    )
    await db.msgParticipants.bulkAdd([
      participant('archived-message', ALICE, 'from'),
      participant('archived-message', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: archivedDestination.id, email: ALICE, role: 'normal' },
    ])

    await repairParticipantSetConversations(db, ME, NOW)

    // Native uses reactivateArchivedIfNeeded=true as selection-only here. The
    // final rollup owns reactivation; this non-INBOX received message keeps the
    // selected epoch archived instead of minting or unarchiving another row.
    expect((await db.messages.get('archived-message'))?.conversationId).toBe(archivedDestination.id)
    expect(await db.conversations.get(archivedDestination.id)).toMatchObject({
      archivedAt: 400,
      isArchived: 1,
    })
    expect(await db.conversations.count()).toBe(1)
  })

  it('keeps a newly created replacement archived for an archived outgoing source', async () => {
    const source = convoRow({
      id: 'archived-outgoing-source',
      participantHash: hashFor(ALICE, RELAY),
      lastMessageDate: 300,
      archivedAt: 400,
      isArchived: 1,
    })
    await db.conversations.add(source)
    await db.messages.add(
      msgRow({
        id: 'archived-outgoing-message',
        conversationId: source.id,
        internalDate: 300,
        labelIds: ['SENT'],
        isFromMe: 1,
      }),
    )
    await db.msgParticipants.bulkAdd([
      participant('archived-outgoing-message', ME, 'from'),
      participant('archived-outgoing-message', ALICE, 'to'),
      participant('archived-outgoing-message', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
    ])

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result).toMatchObject({ movedMessageCount: 1, createdConversationCount: 1 })
    expect(await db.conversations.get(source.id)).toBeUndefined()
    const replacementId = (await db.messages.get('archived-outgoing-message'))?.conversationId
    expect(replacementId).toBeDefined()
    expect(await db.conversations.get(replacementId ?? '')).toMatchObject({
      participantHash: hashFor(ALICE),
      archivedAt: 400,
      isArchived: 1,
    })
  })

  it('reruns when Person enrichment changes Hide-My-Email classification', async () => {
    const source = convoRow({
      id: 'enrichment-source',
      participantHash: hashFor(ALICE, RELAY),
    })
    const destination = convoRow({
      id: 'enrichment-destination',
      participantHash: hashFor(ALICE),
    })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.add(msgRow({ id: 'enriched-later', conversationId: source.id }))
    await db.msgParticipants.bulkAdd([
      participant('enriched-later', ALICE, 'from'),
      participant('enriched-later', ME, 'to'),
      participant('enriched-later', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Relay' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
    ])

    const first = await repairParticipantSetConversations(db, ME, NOW)
    const firstSignature = await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)
    expect(first).toMatchObject({ performed: true, movedMessageCount: 0 })
    expect((await db.messages.get('enriched-later'))?.conversationId).toBe(source.id)

    await db.people.put({ email: RELAY, displayName: 'Hide My Email' })
    const second = await repairParticipantSetConversations(db, ME, NOW + 1)
    const secondSignature = await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)

    expect(second).toMatchObject({ performed: true, movedMessageCount: 1 })
    expect(secondSignature?.value).not.toBe(firstSignature?.value)
    expect((await db.messages.get('enriched-later'))?.conversationId).toBe(destination.id)
  })

  it('reruns when the cached identity alias set changes', async () => {
    const source = convoRow({
      id: 'alias-source',
      participantHash: hashFor(ALICE, WORK_ALIAS),
    })
    const destination = convoRow({ id: 'alias-destination', participantHash: hashFor(ALICE) })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.add(msgRow({ id: 'alias-message', conversationId: source.id }))
    await db.msgParticipants.bulkAdd([
      participant('alias-message', ALICE, 'from'),
      participant('alias-message', WORK_ALIAS, 'to'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: WORK_ALIAS, displayName: 'Me at Work' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: WORK_ALIAS, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
    ])

    expect(await repairParticipantSetConversations(db, ME, NOW)).toMatchObject({
      performed: true,
      movedMessageCount: 0,
    })
    const account = await db.accounts.get(ME)
    expect(account).toBeDefined()
    await db.accounts.put({ ...account!, aliases: [ME, WORK_ALIAS] })

    expect(await repairParticipantSetConversations(db, ME, NOW + 1)).toMatchObject({
      performed: true,
      movedMessageCount: 1,
    })
    expect((await db.messages.get('alias-message'))?.conversationId).toBe(destination.id)
  })

  it('rolls moves and the marker back together so a failed pass is retryable', async () => {
    const source = convoRow({ id: 'retry-source', participantHash: hashFor(ALICE, RELAY) })
    const destination = convoRow({ id: 'retry-destination', participantHash: hashFor(ALICE) })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.add(msgRow({ id: 'retry-message', conversationId: source.id }))
    await db.msgParticipants.bulkAdd([
      participant('retry-message', ALICE, 'from'),
      participant('retry-message', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
    ])
    const deleteSpy = vi
      .spyOn(db.conversations, 'delete')
      .mockRejectedValueOnce(new Error('injected delete failure'))

    await expect(repairParticipantSetConversations(db, ME, NOW)).rejects.toThrow(
      'injected delete failure',
    )
    deleteSpy.mockRestore()

    expect((await db.messages.get('retry-message'))?.conversationId).toBe(source.id)
    expect(await db.conversations.get(source.id)).toBeDefined()
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()

    const retry = await repairParticipantSetConversations(db, ME, NOW + 1)
    expect(retry).toMatchObject({ performed: true, movedMessageCount: 1 })
    expect((await db.messages.get('retry-message'))?.conversationId).toBe(destination.id)
  })

  // Revert-check: the PARTICIPANT_SET_REPAIR_PROGRESS_KEY row each chunk
  // commits (nextProgress). Without it every chunk restarts from the oldest
  // message, so the walk never ends and the chunk guard below throws.
  it('resumes an interrupted chunked pass from its cursor and writes the signature only at the end', async () => {
    const destination = convoRow({
      id: 'resume-destination',
      participantHash: hashFor(ALICE),
      displayName: 'Alice',
    })
    const sources = [1, 2, 3].map((n) =>
      convoRow({ id: `resume-source-${n}`, participantHash: hashFor(ALICE, RELAY) }),
    )
    await db.conversations.bulkAdd([destination, ...sources])
    await db.messages.bulkAdd(
      sources.map((source, index) =>
        msgRow({
          id: `resume-${index + 1}`,
          conversationId: source.id,
          internalDate: 100 * (index + 1),
        }),
      ),
    )
    await db.msgParticipants.bulkAdd(
      [1, 2, 3].flatMap((n) => [
        participant(`resume-${n}`, ALICE, 'from', 'Alice'),
        participant(`resume-${n}`, ME, 'to'),
        participant(`resume-${n}`, RELAY, 'cc'),
      ]),
    )
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: destination.id, email: ALICE, role: 'normal' },
      ...sources.flatMap((source) => [
        { conversationId: source.id, email: ALICE, role: 'normal' as const },
        { conversationId: source.id, email: RELAY, role: 'normal' as const },
      ]),
    ])

    // The tab dies while the second chunk is still uncommitted.
    await expect(
      repairParticipantSetConversations(db, ME, NOW, {
        chunkSize: 1,
        beforeChunkCommit: (chunkIndex) => {
          if (chunkIndex === 1) throw new Error('tab killed')
        },
      }),
    ).rejects.toThrow('tab killed')

    expect((await db.messages.get('resume-1'))?.conversationId).toBe(destination.id)
    expect((await db.messages.get('resume-2'))?.conversationId).toBe('resume-source-2')
    expect(await db.conversations.get('resume-source-1')).toBeUndefined()
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()
    expect((await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY))?.value).toMatchObject({
      throughInternalDate: 100,
      blockedByActiveSend: false,
    })

    const chunks: number[] = []
    const resumed = await repairParticipantSetConversations(db, ME, NOW + 1, {
      chunkSize: 1,
      beforeChunkCommit: (chunkIndex) => {
        chunks.push(chunkIndex)
        if (chunkIndex > 10) throw new Error('walk did not resume')
      },
    })

    // resume-2, resume-3, then the empty chunk that ends the walk.
    expect(chunks).toEqual([0, 1, 2])
    expect(resumed).toMatchObject({
      performed: true,
      movedMessageCount: 2,
      deletedConversationCount: 2,
    })
    for (const n of [1, 2, 3]) {
      expect((await db.messages.get(`resume-${n}`))?.conversationId).toBe(destination.id)
    }
    expect(await db.conversations.count()).toBe(1)
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()
  })

  // Revert-check: `progress.blockedByActiveSend ||` in the chunk's next
  // progress row. Without it the later, unblocked chunk clears the deferral
  // the first chunk recorded, and the end of the walk writes the signature.
  it('withholds the signature when an earlier chunk deferred to an active send', async () => {
    const protectedConversation = convoRow({
      id: 'journal-protected',
      participantHash: hashFor(ALICE),
      displayName: 'Stale Alice',
    })
    const healthy = convoRow({
      id: 'healthy-bob',
      participantHash: hashFor(BOB),
      displayName: 'Bob',
    })
    await db.conversations.bulkAdd([protectedConversation, healthy])
    await db.messages.bulkAdd([
      msgRow({
        id: 'protected-resident',
        conversationId: protectedConversation.id,
        internalDate: 100,
      }),
      msgRow({ id: 'healthy-message', conversationId: healthy.id, internalDate: 200 }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('protected-resident', ALICE, 'from', 'Alice'),
      participant('protected-resident', ME, 'to'),
      participant('healthy-message', BOB, 'from', 'Bob'),
      participant('healthy-message', ME, 'to'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: BOB, displayName: 'Bob' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: protectedConversation.id, email: ALICE, role: 'normal' },
      { conversationId: healthy.id, email: BOB, role: 'normal' },
    ])
    // The journal-before-row edge: the outbox published the journal, but not
    // yet the optimistic row, so only the journal protects the conversation.
    await db.outboundSends.add({
      id: 'journal-only-send',
      conversationId: protectedConversation.id,
      newlyInsertedConversation: 0,
      createdAt: NOW,
      status: 'pending',
      conversationSnapshot: null,
      remoteCommittedMessageId: '',
      remoteCommittedThreadId: '',
    })

    const result = await repairParticipantSetConversations(db, ME, NOW, { chunkSize: 1 })

    expect(result).toMatchObject({ performed: true, rebuiltConversationCount: 0 })
    expect(await db.conversations.get(protectedConversation.id)).toEqual(protectedConversation)
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()
    // The walk ended; the next pass starts fresh rather than resuming.
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()
  })

  // Revert-check: the type/displayName comparison before the resident
  // conversations.put. Without it the rows-only repair below rewrites a
  // conversation row whose fields did not change.
  it('rebuilds stale addressing rows without rewriting an unchanged conversation row', async () => {
    const healthy = convoRow({
      id: 'healthy-alice',
      participantHash: hashFor(ALICE),
      displayName: 'Alice',
    })
    const staleRows = convoRow({
      id: 'stale-rows-bob',
      participantHash: hashFor(BOB),
      displayName: 'Bob',
    })
    await db.conversations.bulkAdd([healthy, staleRows])
    await db.messages.bulkAdd([
      msgRow({ id: 'healthy-alice-message', conversationId: healthy.id, internalDate: 100 }),
      msgRow({ id: 'stale-rows-message', conversationId: staleRows.id, internalDate: 200 }),
    ])
    await db.msgParticipants.bulkAdd([
      participant('healthy-alice-message', ALICE, 'from', 'Alice'),
      participant('healthy-alice-message', ME, 'to'),
      participant('stale-rows-message', BOB, 'from', 'Bob'),
      participant('stale-rows-message', ME, 'to'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: BOB, displayName: 'Bob' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: healthy.id, email: ALICE, role: 'normal' },
      { conversationId: staleRows.id, email: BOB, role: 'normal' },
      { conversationId: staleRows.id, email: ME, role: 'me' },
    ])
    const putSpy = vi.spyOn(db.conversations, 'put')

    const result = await repairParticipantSetConversations(db, ME, NOW)
    // Read before mockRestore, which also clears the recorded calls.
    const putCalls = putSpy.mock.calls.length
    putSpy.mockRestore()

    expect(result).toMatchObject({ performed: true, rebuiltConversationCount: 1 })
    expect(putCalls).toBe(0)
    expect(
      await db.convoParticipants.where('conversationId').equals(staleRows.id).toArray(),
    ).toEqual([{ conversationId: staleRows.id, email: BOB, role: 'normal' }])
    expect(await db.conversations.get(healthy.id)).toEqual(healthy)
    expect(await db.conversations.get(staleRows.id)).toEqual(staleRows)
  })

  // Revert-check: the `storedProgress.signature === signature` comparison.
  // Without it a walk left by an older alias set resumes past messages it
  // never examined under the current one.
  it('restarts a walk left by an older signature from the oldest message', async () => {
    const source = convoRow({ id: 'restart-source', participantHash: hashFor(ALICE, RELAY) })
    const destination = convoRow({ id: 'restart-destination', participantHash: hashFor(ALICE) })
    await db.conversations.bulkAdd([source, destination])
    await db.messages.add(
      msgRow({ id: 'restart-message', conversationId: source.id, internalDate: 100 }),
    )
    await db.msgParticipants.bulkAdd([
      participant('restart-message', ALICE, 'from'),
      participant('restart-message', RELAY, 'cc'),
    ])
    await db.people.bulkPut([
      { email: ALICE, displayName: 'Alice' },
      { email: RELAY, displayName: 'Hide My Email' },
    ])
    await db.convoParticipants.bulkPut([
      { conversationId: source.id, email: ALICE, role: 'normal' },
      { conversationId: source.id, email: RELAY, role: 'normal' },
      { conversationId: destination.id, email: ALICE, role: 'normal' },
    ])
    await db.syncState.put({
      key: PARTICIPANT_SET_REPAIR_PROGRESS_KEY,
      value: {
        signature: 'older-signature',
        throughInternalDate: NOW,
        blockedByActiveSend: false,
        createdDestinationIds: [],
      },
    })

    const result = await repairParticipantSetConversations(db, ME, NOW)

    expect(result).toMatchObject({ performed: true, movedMessageCount: 1 })
    expect((await db.messages.get('restart-message'))?.conversationId).toBe(destination.id)
    expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()
  })

  describe('PR 362 review follow-ups', () => {
    /**
     * One source per message, each keyed with RELAY in its hash, and (unless
     * `withDestination` is false) the healthy hash(ALICE) destination they
     * all merge into once RELAY is classified Hide My Email.
     */
    async function seedRelayMoves(
      messages: ReadonlyArray<{ id: string; internalDate: number; archived?: boolean }>,
      options: { relayName?: string; withDestination?: boolean } = {},
    ): Promise<string> {
      const destinationId = 'relay-destination'
      if (options.withDestination !== false) {
        await db.conversations.add(
          convoRow({ id: destinationId, participantHash: hashFor(ALICE), displayName: 'Alice' }),
        )
        await db.convoParticipants.put({
          conversationId: destinationId,
          email: ALICE,
          role: 'normal',
        })
      }
      for (const message of messages) {
        const sourceId = `source-${message.id}`
        await db.conversations.add(
          convoRow({
            id: sourceId,
            participantHash: hashFor(ALICE, RELAY),
            ...(message.archived === true ? { archivedAt: 50, isArchived: 1 } : {}),
          }),
        )
        await db.messages.add(
          msgRow({
            id: message.id,
            conversationId: sourceId,
            internalDate: message.internalDate,
            ...(message.archived === true ? { labelIds: [] } : {}),
          }),
        )
        await db.msgParticipants.bulkAdd([
          participant(message.id, ALICE, 'from', 'Alice'),
          participant(message.id, ME, 'to'),
          participant(message.id, RELAY, 'cc'),
        ])
        await db.convoParticipants.bulkPut([
          { conversationId: sourceId, email: ALICE, role: 'normal' },
          { conversationId: sourceId, email: RELAY, role: 'normal' },
        ])
      }
      await db.people.bulkPut([
        { email: ALICE, displayName: 'Alice' },
        { email: RELAY, displayName: options.relayName ?? 'Hide My Email' },
      ])
      return destinationId
    }

    async function seedHealthyBob(id: string, internalDate: number): Promise<void> {
      await db.conversations.add(
        convoRow({ id: `healthy-${id}`, participantHash: hashFor(BOB), displayName: 'Bob' }),
      )
      await db.messages.add(msgRow({ id, conversationId: `healthy-${id}`, internalDate }))
      await db.msgParticipants.bulkAdd([
        participant(id, BOB, 'from', 'Bob'),
        participant(id, ME, 'to'),
      ])
      await db.convoParticipants.put({
        conversationId: `healthy-${id}`,
        email: BOB,
        role: 'normal',
      })
      await db.people.put({ email: BOB, displayName: 'Bob' })
    }

    // Revert-check: the PARTICIPANT_SET_REPAIR_PROGRESS_KEY delete in the
    // matching-marker branch (the stale row survives and resumes later), and
    // its `storedProgress !== undefined` guard (the usual no-op deletes).
    it('discards a stale progress row beside a matching marker and keeps the usual no-op read-only', async () => {
      await seedRelayMoves([{ id: 'stale-progress-message', internalDate: 100 }])
      await repairParticipantSetConversations(db, ME, NOW)
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
      // Aliases A completed, a walk under B was killed past its first chunk,
      // and the aliases are back to A.
      await db.syncState.put({
        key: PARTICIPANT_SET_REPAIR_PROGRESS_KEY,
        value: {
          signature: 'walk-under-other-aliases',
          throughInternalDate: 100,
          blockedByActiveSend: false,
          createdDestinationIds: [],
        },
      })

      expect(await repairParticipantSetConversations(db, ME, NOW + 1)).toMatchObject({
        performed: false,
      })
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()

      const deleteSpy = vi.spyOn(db.syncState, 'delete')
      const putSpy = vi.spyOn(db.syncState, 'put')
      const noOp = await repairParticipantSetConversations(db, ME, NOW + 2)
      const writes = deleteSpy.mock.calls.length + putSpy.mock.calls.length
      deleteSpy.mockRestore()
      putSpy.mockRestore()
      expect(noOp).toMatchObject({ performed: false })
      expect(writes).toBe(0)
    })

    // Revert-check: the retireStaleMarker delete after a chunk's progress
    // write. Without it the old marker outlives the killed walk's moves and
    // the return to the old aliases is a no-op.
    it('retires the previous marker with the first chunk of a walk under new inputs', async () => {
      const destination = convoRow({
        id: 'round-trip-destination',
        participantHash: hashFor(ALICE),
      })
      await db.conversations.add(destination)
      await db.convoParticipants.put({
        conversationId: destination.id,
        email: ALICE,
        role: 'normal',
      })
      for (const [index, date] of [100, 200].entries()) {
        const sourceId = `round-trip-source-${index}`
        await db.conversations.add(
          convoRow({ id: sourceId, participantHash: hashFor(ALICE, WORK_ALIAS) }),
        )
        await db.messages.add(
          msgRow({ id: `round-trip-${index}`, conversationId: sourceId, internalDate: date }),
        )
        await db.msgParticipants.bulkAdd([
          participant(`round-trip-${index}`, ALICE, 'from'),
          participant(`round-trip-${index}`, WORK_ALIAS, 'to'),
        ])
        await db.convoParticipants.bulkPut([
          { conversationId: sourceId, email: ALICE, role: 'normal' },
          { conversationId: sourceId, email: WORK_ALIAS, role: 'normal' },
        ])
      }
      await db.people.put({ email: ALICE, displayName: 'Alice' })

      await repairParticipantSetConversations(db, ME, NOW)
      const markerA = (await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY))?.value
      expect(markerA).toBeDefined()

      const account = await db.accounts.get(ME)
      await db.accounts.put({ ...account!, aliases: [ME, WORK_ALIAS] })
      await expect(
        repairParticipantSetConversations(db, ME, NOW + 1, {
          chunkSize: 1,
          beforeChunkCommit: (chunkIndex) => {
            if (chunkIndex === 1) throw new Error('tab killed')
          },
        }),
      ).rejects.toThrow('tab killed')
      expect((await db.messages.get('round-trip-0'))?.conversationId).toBe(destination.id)
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()

      await db.accounts.put({ ...account!, aliases: [ME] })
      const back = await repairParticipantSetConversations(db, ME, NOW + 2)

      expect(back).toMatchObject({ performed: true })
      expect((await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY))?.value).toBe(markerA)
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()
    })

    // Revert-check: the `else if (previousSignature !== undefined)` marker
    // delete in the walk's final chunk. A PR 362 build kept the old marker
    // through a walk; one that ends blocked must still retire it.
    it('retires a stale marker when a walk inherited from an older build ends blocked', async () => {
      await seedRelayMoves([{ id: 'inherited-walk', internalDate: 100 }])
      await repairParticipantSetConversations(db, ME, NOW)
      const current = (await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY))?.value
      expect(current).toBeDefined()
      await db.syncState.put({ key: PARTICIPANT_SET_REPAIR_SIGNATURE_KEY, value: 'older-marker' })
      await db.syncState.put({
        key: PARTICIPANT_SET_REPAIR_PROGRESS_KEY,
        value: {
          signature: current,
          throughInternalDate: NOW,
          blockedByActiveSend: true,
          createdDestinationIds: [],
        },
      })

      expect(await repairParticipantSetConversations(db, ME, NOW + 1)).toMatchObject({
        performed: true,
      })
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY)).toBeUndefined()
    })

    // Revert-check: the `message.sendState === 'pending'` term in
    // hasRowlessActiveOutgoing. Without a journal, only it protects the row.
    // HONEST SCOPE: this and the next test pin that the keys-first rewrite is
    // exactly as strict as the old full-row scan; nothing here observes which
    // rows it loads, so a revert to the scan would still pass both.
    it('still protects a conversation holding a journal-less pending rowless send', async () => {
      await seedRelayMoves([{ id: 'beside-pending', internalDate: 100 }])
      await db.messages.add(
        msgRow({
          id: 'journal-less-pending',
          conversationId: 'source-beside-pending',
          internalDate: 200,
          isFromMe: 1,
          labelIds: ['SENT'],
          sendState: 'pending',
        }),
      )

      const result = await repairParticipantSetConversations(db, ME, NOW)

      expect(result).toMatchObject({ performed: true, movedMessageCount: 0 })
      expect((await db.messages.get('beside-pending'))?.conversationId).toBe(
        'source-beside-pending',
      )
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeUndefined()
    })

    // Revert-check: the withParticipantRows filter in hasRowlessActiveOutgoing.
    // Without it a pending send that already has participant rows protects
    // its conversation as if it were rowless.
    it('does not protect a conversation whose pending send has participant rows', async () => {
      const destination = await seedRelayMoves([{ id: 'beside-addressed', internalDate: 100 }])
      await db.messages.add(
        msgRow({
          id: 'addressed-pending',
          conversationId: 'source-beside-addressed',
          internalDate: 200,
          isFromMe: 1,
          labelIds: ['SENT'],
          sendState: 'pending',
        }),
      )
      await db.msgParticipants.bulkAdd([
        participant('addressed-pending', ME, 'from'),
        participant('addressed-pending', ALICE, 'to'),
        participant('addressed-pending', RELAY, 'cc'),
      ])

      const result = await repairParticipantSetConversations(db, ME, NOW)

      expect(result).toMatchObject({ performed: true })
      expect((await db.messages.get('beside-addressed'))?.conversationId).toBe(destination)
    })

    // Revert-check: `state.inputs === null ||` in the chunk's fullRead test.
    // Without the carried snapshot every chunk reads the whole people table.
    it('reads the people table once per call plus once to confirm the signature', async () => {
      await seedRelayMoves([
        { id: 'snapshot-1', internalDate: 100 },
        { id: 'snapshot-2', internalDate: 200 },
        { id: 'snapshot-3', internalDate: 300 },
      ])
      const toArraySpy = vi.spyOn(db.people, 'toArray')

      const result = await repairParticipantSetConversations(db, ME, NOW, { chunkSize: 1 })
      const fullReads = toArraySpy.mock.calls.length
      toArraySpy.mockRestore()

      expect(result).toMatchObject({ performed: true, movedMessageCount: 3 })
      expect(fullReads).toBe(2)
    })

    // Revert-check: the `messages.length === 0 && !fullRead` retry. Without
    // it the walk writes the signature it began under although a Person read
    // only by an earlier chunk changed class after that chunk committed.
    it('confirms the signature with a full read before ending the walk', async () => {
      const destination = await seedRelayMoves([{ id: 'early-relay', internalDate: 100 }], {
        relayName: 'Relay',
      })
      await seedHealthyBob('late-bob', 200)

      const result = await repairParticipantSetConversations(db, ME, NOW, {
        chunkSize: 1,
        beforeChunkCommit: async (chunkIndex) => {
          if (chunkIndex === 0) await db.people.put({ email: RELAY, displayName: 'Hide My Email' })
        },
      })

      expect(result).toMatchObject({ performed: true, movedMessageCount: 1 })
      expect((await db.messages.get('early-relay'))?.conversationId).toBe(destination)
      expect(await db.syncState.get(PARTICIPANT_SET_REPAIR_SIGNATURE_KEY)).toBeDefined()
    })

    // Revert-check: the Hide-My-Email comparison against the snapshot in the
    // per-chunk Person refresh. Without it the change is found only at the
    // end of the walk, which then walks every chunk a second time.
    it('restarts at the first chunk that reads a Person whose class changed', async () => {
      await seedHealthyBob('first-bob', 100)
      const destination = await seedRelayMoves([{ id: 'later-relay', internalDate: 200 }], {
        relayName: 'Relay',
      })
      const chunks: number[] = []

      await repairParticipantSetConversations(db, ME, NOW, {
        chunkSize: 1,
        beforeChunkCommit: async (chunkIndex) => {
          chunks.push(chunkIndex)
          if (chunkIndex === 0) await db.people.put({ email: RELAY, displayName: 'Hide My Email' })
        },
      })

      // first-bob, then the restart: first-bob, later-relay, the empty end.
      expect(chunks).toEqual([0, 1, 2, 3])
      expect((await db.messages.get('later-relay'))?.conversationId).toBe(destination)
    })

    // Revert-check: the restOfDate read in readMessageChunk. Without it the
    // resumed walk starts above the split date and never sees tie-c.
    it('splits a date shared by more messages than a chunk holds without skipping any', async () => {
      const destination = await seedRelayMoves([
        { id: 'tie-a', internalDate: 100 },
        { id: 'tie-b', internalDate: 100 },
        { id: 'tie-c', internalDate: 100 },
      ])

      await expect(
        repairParticipantSetConversations(db, ME, NOW, {
          chunkSize: 2,
          beforeChunkCommit: (chunkIndex) => {
            if (chunkIndex === 1) throw new Error('tab killed')
          },
        }),
      ).rejects.toThrow('tab killed')
      // The first chunk held exactly two of the three tied messages.
      expect((await db.messages.get('tie-a'))?.conversationId).toBe(destination)
      expect((await db.messages.get('tie-b'))?.conversationId).toBe(destination)
      expect((await db.messages.get('tie-c'))?.conversationId).toBe('source-tie-c')
      expect((await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY))?.value).toMatchObject({
        throughInternalDate: 100,
        throughMessageId: 'tie-b',
      })

      const resumed = await repairParticipantSetConversations(db, ME, NOW + 1, { chunkSize: 2 })

      expect(resumed).toMatchObject({ performed: true, movedMessageCount: 1 })
      expect((await db.messages.get('tie-c'))?.conversationId).toBe(destination)
    })

    // Revert-check: the `row.throughMessageId === undefined ||` acceptance in
    // isRepairProgress. Without it a row written before the field existed is
    // rejected and the walk restarts from the oldest message.
    it('resumes a progress row written before throughMessageId existed after its date', async () => {
      await seedRelayMoves([
        { id: 'legacy-1', internalDate: 100 },
        { id: 'legacy-2', internalDate: 200 },
      ])
      await expect(
        repairParticipantSetConversations(db, ME, NOW, {
          chunkSize: 1,
          beforeChunkCommit: (chunkIndex) => {
            if (chunkIndex === 1) throw new Error('tab killed')
          },
        }),
      ).rejects.toThrow('tab killed')
      const stored = (await db.syncState.get(PARTICIPANT_SET_REPAIR_PROGRESS_KEY))?.value as Record<
        string,
        unknown
      >
      const { throughMessageId, ...legacy } = stored
      expect(throughMessageId).toBe('legacy-1')
      await db.syncState.put({ key: PARTICIPANT_SET_REPAIR_PROGRESS_KEY, value: legacy })
      const chunks: number[] = []

      const resumed = await repairParticipantSetConversations(db, ME, NOW + 1, {
        chunkSize: 1,
        beforeChunkCommit: (chunkIndex) => {
          chunks.push(chunkIndex)
        },
      })

      // legacy-2, then the empty chunk that ends the walk.
      expect(chunks).toEqual([0, 1])
      expect(resumed).toMatchObject({ performed: true, movedMessageCount: 1 })
    })

    // Revert-check: `if (!state.everyMessageIndexed) continue` in the
    // drained-source loop. Without it the source reads as drained through
    // the index and is deleted under the row the index cannot see.
    it('keeps a source holding a message the internalDate index cannot see', async () => {
      const destination = await seedRelayMoves([{ id: 'indexed-move', internalDate: 100 }])
      await db.messages.add(
        msgRow({
          id: 'unindexed-row',
          conversationId: 'source-indexed-move',
          internalDate: Number.NaN,
        }),
      )
      expect(await db.messages.orderBy('internalDate').count()).toBe(1)

      const result = await repairParticipantSetConversations(db, ME, NOW)

      expect(result).toMatchObject({ movedMessageCount: 1, deletedConversationCount: 0 })
      expect((await db.messages.get('indexed-move'))?.conversationId).toBe(destination)
      expect(await db.conversations.get('source-indexed-move')).toBeDefined()
    })

    /**
     * A hash(ALICE, RELAY) source holding `messages`, each received (from
     * Alice, not in INBOX) or sent by me, which all merge into one new
     * hash(ALICE) shell once RELAY is classified Hide My Email.
     */
    async function seedShellMerge(
      sourceId: string,
      archived: boolean,
      messages: ReadonlyArray<{ id: string; internalDate: number; sent: boolean }>,
    ): Promise<void> {
      await db.conversations.add(
        convoRow({
          id: sourceId,
          participantHash: hashFor(ALICE, RELAY),
          ...(archived ? { archivedAt: 50, isArchived: 1 } : {}),
        }),
      )
      await db.convoParticipants.bulkPut([
        { conversationId: sourceId, email: ALICE, role: 'normal' },
        { conversationId: sourceId, email: RELAY, role: 'normal' },
      ])
      for (const message of messages) {
        await db.messages.add(
          msgRow({
            id: message.id,
            conversationId: sourceId,
            internalDate: message.internalDate,
            ...(message.sent
              ? { isFromMe: 1, labelIds: ['SENT'], senderEmail: ME }
              : { labelIds: [], senderEmail: ALICE }),
          }),
        )
        await db.msgParticipants.bulkAdd(
          message.sent
            ? [
                participant(message.id, ME, 'from'),
                participant(message.id, ALICE, 'to'),
                participant(message.id, RELAY, 'cc'),
              ]
            : [
                participant(message.id, ALICE, 'from', 'Alice'),
                participant(message.id, ME, 'to'),
                participant(message.id, RELAY, 'cc'),
              ],
        )
      }
      await db.people.bulkPut([
        { email: ALICE, displayName: 'Alice' },
        { email: RELAY, displayName: 'Hide My Email' },
      ])
    }

    /** Runs the walk one message per chunk; returns the shell's archivedAt at each commit. */
    async function walkOneMessagePerChunk(shellMessageId: string): Promise<number[]> {
      const archivedAtCommit: number[] = []
      await repairParticipantSetConversations(db, ME, NOW, {
        chunkSize: 1,
        beforeChunkCommit: async () => {
          const shellId = (await db.messages.get(shellMessageId))?.conversationId
          const shell = shellId === undefined ? undefined : await db.conversations.get(shellId)
          if (shell !== undefined) archivedAtCommit.push(shell.archivedAt)
        },
      })
      return archivedAtCommit
    }

    // Revert-check: the unconditional createdDestinationIds.add for a new
    // shell. Carrying only shells created archived leaves this one, created
    // active and then auto-archived by chunk 0's rollup, out of the set, so
    // chunk 1 moves the active source's reply into it without reactivating.
    it('reactivates a shell created active that an earlier chunk rollup archived', async () => {
      await seedShellMerge('active-source', false, [
        { id: 'received-first', internalDate: 100, sent: false },
        { id: 'reply-later', internalDate: 200, sent: true },
      ])

      const archivedAtCommit = await walkOneMessagePerChunk('received-first')

      // Chunk 0's rollup auto-archived the shell; chunk 1 moved the reply in.
      expect(archivedAtCommit.slice(0, 2)).toEqual([NOW, 0])
      const shellId = (await db.messages.get('received-first'))?.conversationId
      expect((await db.messages.get('reply-later'))?.conversationId).toBe(shellId)
      expect(await db.conversations.get(shellId!)).toMatchObject({ isArchived: 0, archivedAt: 0 })
    })

    // Revert-check: keeping a reactivated shell in createdDestinationIds
    // (dropping it on reactivation). Chunk 1 reactivates the shell, its
    // rollup archives it again, and chunk 2 must still reactivate it.
    it('reactivates a shell again after a later chunk rollup re-archived it', async () => {
      await seedShellMerge('archived-source', true, [
        { id: 'archived-first', internalDate: 100, sent: false },
      ])
      await seedShellMerge('active-source', false, [
        { id: 'received-middle', internalDate: 200, sent: false },
        { id: 'reply-last', internalDate: 300, sent: true },
      ])

      const archivedAtCommit = await walkOneMessagePerChunk('archived-first')

      // Seeded archived from its source (50), reactivated by chunk 1 and
      // auto-archived again by that chunk's rollup (NOW), and reactivated
      // for good by chunk 2.
      expect(archivedAtCommit.slice(0, 3)).toEqual([50, NOW, 0])
      const shellId = (await db.messages.get('archived-first'))?.conversationId
      expect((await db.messages.get('received-middle'))?.conversationId).toBe(shellId)
      expect((await db.messages.get('reply-last'))?.conversationId).toBe(shellId)
      expect(await db.conversations.get(shellId!)).toMatchObject({ isArchived: 0, archivedAt: 0 })
    })
  })
})
