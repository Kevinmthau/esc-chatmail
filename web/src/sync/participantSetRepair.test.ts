import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { MsgParticipantRow } from '@/db/types'
import { makeParticipantSetIdentity } from '@/identity/participantSet'
import { convoRow, msgRow } from '@/outbox/testSupport'
import {
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
})
