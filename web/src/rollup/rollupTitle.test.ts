// The title re-derivation that ends every rollup (port of
// ConversationRollupUpdater.updateDisplayNameOnly): a title frozen at shell
// creation from a bare address upgrades to the Person's real name, a new chat
// with someone already known by name starts with it, and a stored title is
// never downgraded. Driven through the real persist path, and through the
// nested-transaction shapes of the callers that cannot widen their table sets.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { calculateParticipantHash } from '@/identity/participantSet'
import { rollupConversations } from '@/sync/initial'
import { applyPersist, preparePersist, type PersistContext } from '@/sync/persist'
import { makeTestDb, ME, NOW, textMessage } from '@/sync/testSupport'
import { rollupConversation, upgradedConversationTitle } from './rollup'

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  await db.delete()
})

const ctx: PersistContext = {
  myAliases: new Set([ME]),
  hideMyEmailAddresses: new Set(),
  sendAsAliases: [
    {
      email: ME,
      displayName: '',
      isDefault: true,
      isPrimary: true,
      verificationStatus: 'accepted',
    },
  ],
  knownLabelIds: null,
}

const ALICE = 'alice@example.com'
const BOB = 'bob@example.com'

async function persist(from: string, id: string, internalDate: number): Promise<void> {
  const plans = await preparePersist([textMessage({ id, from, internalDate })], ctx)
  await applyPersist(db, plans, NOW)
}

async function conversationWith(...participants: string[]) {
  const hash = calculateParticipantHash(participants)
  const conversation = (await db.conversations.toArray()).find((c) => c.participantHash === hash)
  expect(conversation).toBeDefined()
  return conversation!
}

describe('upgradedConversationTitle', () => {
  const names = (entries: Array<[string, string]>) => new Map(entries)

  // Revert-check: upgradedConversationTitle (rollup.ts)
  it('rebuilds a bare-address title from a real Person name', () => {
    expect(upgradedConversationTitle(ALICE, [ALICE], names([[ALICE, 'Alice Smith']]))).toBe(
      'Alice Smith',
    )
  })

  it('keeps the stored title when no participant has a real name', () => {
    expect(upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, '']]))).toBeNull()
    expect(upgradedConversationTitle('Alice Smith', [ALICE], names([]))).toBeNull()
  })

  it('does not count a Hide My Email label, the address, or its local part as a name', () => {
    expect(
      upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, 'Hide My Email']])),
    ).toBeNull()
    expect(upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, ALICE]]))).toBeNull()
    expect(upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, 'alice']]))).toBeNull()
    expect(
      upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, `'${ALICE}'`]])),
    ).toBeNull()
  })

  it('returns null when the rebuilt title equals the stored one', () => {
    expect(
      upgradedConversationTitle('Alice Smith', [ALICE], names([[ALICE, 'Alice Smith']])),
    ).toBeNull()
  })

  it('joins a group the way the participant-set repair does, addresses for unnamed people', () => {
    expect(
      upgradedConversationTitle(`${ALICE}, ${BOB}`, [BOB, ALICE], names([[ALICE, 'Alice Smith']])),
    ).toBe(`Alice Smith, ${BOB}`)
  })

  it('keeps the title of a conversation without participants', () => {
    expect(upgradedConversationTitle('Anything', [], names([[ALICE, 'Alice']]))).toBeNull()
  })
})

describe('rollupConversation: title re-derivation', () => {
  // Revert-check: rolledConversationTitle (rollup.ts)
  it('upgrades a title created from a bare address once a later header names the sender', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    expect((await conversationWith(ALICE)).displayName).toBe(ALICE)

    await persist(`Alice Smith <${ALICE}>`, 'm2', NOW - 4000)
    const conversation = await conversationWith(ALICE)
    expect((await db.people.get(ALICE))?.displayName).toBe('Alice Smith')

    await rollupConversation(db, conversation.id, NOW)

    expect((await db.conversations.get(conversation.id))?.displayName).toBe('Alice Smith')
  })

  it('titles a new chat from a bare address with the Person name already stored', async () => {
    await db.people.put({ email: BOB, displayName: 'Bob Jones' })
    await persist(BOB, 'm1', NOW - 5000)
    const conversation = await conversationWith(BOB)
    expect(conversation.displayName).toBe(BOB)

    await rollupConversation(db, conversation.id, NOW)

    expect((await db.conversations.get(conversation.id))?.displayName).toBe('Bob Jones')
  })

  it('never downgrades a named title when the Person row holds no real name', async () => {
    await persist(`Alice Smith <${ALICE}>`, 'm1', NOW - 5000)
    const conversation = await conversationWith(ALICE)
    expect(conversation.displayName).toBe('Alice Smith')
    await db.people.put({ email: ALICE, displayName: '' })

    await rollupConversation(db, conversation.id, NOW)

    expect((await db.conversations.get(conversation.id))?.displayName).toBe('Alice Smith')
  })

  it('leaves a conversation without participant rows alone', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    const conversation = await conversationWith(ALICE)
    await db.people.put({ email: ALICE, displayName: 'Alice Smith' })
    await db.convoParticipants.where('conversationId').equals(conversation.id).delete()

    await rollupConversation(db, conversation.id, NOW)

    expect((await db.conversations.get(conversation.id))?.displayName).toBe(ALICE)
  })

  // initial.rollupConversations (and the sync finalize) nest the rollup in
  // their own transaction, which must carry all four rollup tables for the
  // title inputs to reach it on the path every synced message takes.
  // Revert-check: rolledConversationTitle (rollup.ts) and the four-table
  // transaction in initial.rollupConversations.
  it('upgrades the title through the real sync caller rollupConversations', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    await persist(`Alice Smith <${ALICE}>`, 'm2', NOW - 4000)
    const conversation = await conversationWith(ALICE)

    await rollupConversations(db, new Set([conversation.id]), NOW)

    expect((await db.conversations.get(conversation.id))?.displayName).toBe('Alice Smith')
  })

  it('still commits the rollup fields atomically with the parent transaction', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    await persist(`Alice Smith <${ALICE}>`, 'm2', NOW - 4000)
    const conversation = await conversationWith(ALICE)

    await expect(
      db.transaction(
        'rw',
        [db.messages, db.conversations, db.convoParticipants, db.people],
        async () => {
          await rollupConversation(db, conversation.id, NOW)
          throw new Error('abort after rollup')
        },
      ),
    ).rejects.toThrow('abort after rollup')

    expect((await db.conversations.get(conversation.id))?.displayName).toBe(ALICE)
  })

  // The rollup never reads beside its parent transaction (an outside read on
  // a store another transaction held deadlocked under load), so a parent
  // missing one of the title tables is refused by Dexie rather than served.
  // Revert-check: the fixed table list in rollupConversation's transaction.
  it('refuses to nest in a parent that lacks a title table', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    await persist(`Alice Smith <${ALICE}>`, 'm2', NOW - 4000)
    const conversation = await conversationWith(ALICE)

    await expect(
      db.transaction('rw', db.messages, db.conversations, db.convoParticipants, async () => {
        await rollupConversation(db, conversation.id, NOW)
      }),
    ).rejects.toThrow()

    expect((await db.conversations.get(conversation.id))?.displayName).toBe(ALICE)
  })

  it('nests fully when the parent covers every table the title reads', async () => {
    await persist(ALICE, 'm1', NOW - 5000)
    await persist(`Alice Smith <${ALICE}>`, 'm2', NOW - 4000)
    const conversation = await conversationWith(ALICE)

    await db.transaction(
      'rw',
      [db.messages, db.conversations, db.convoParticipants, db.people],
      async () => {
        await rollupConversation(db, conversation.id, NOW)
      },
    )

    expect((await db.conversations.get(conversation.id))?.displayName).toBe('Alice Smith')
  })
})
