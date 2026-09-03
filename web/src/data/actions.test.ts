import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import { makeRecipientParticipantSetIdentity } from '@/identity/participantSet'
import { convoRow, makeTestDb, ME, seedAccount } from '@/outbox/testSupport'
import {
  configureDataActions,
  drainOutbox,
  findConversationByParticipants,
  requestSync,
  searchPeople,
} from './actions'

describe('data/actions facade', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    setDBForTests(db)
    configureDataActions(null)
    await seedAccount(db)
  })

  afterEach(async () => {
    setDBForTests(null)
    configureDataActions(null)
    await db.delete()
  })

  describe('findConversationByParticipants', () => {
    it('finds the active epoch via the canonical participant hash', async () => {
      const identity = makeRecipientParticipantSetIdentity(['bob@example.com'], new Set([ME]))
      await db.conversations.add(
        convoRow({ id: 'c1', participantHash: identity?.participantHash ?? '' }),
      )

      // Raw, un-normalized input still routes to the same hash.
      await expect(findConversationByParticipants(['  BOB@Example.com '])).resolves.toBe('c1')
    })

    it('ignores archived-only epochs and unknown participants', async () => {
      const identity = makeRecipientParticipantSetIdentity(['bob@example.com'], new Set([ME]))
      await db.conversations.add(
        convoRow({
          id: 'c1',
          participantHash: identity?.participantHash ?? '',
          archivedAt: 123,
          isArchived: 1,
        }),
      )

      await expect(findConversationByParticipants(['bob@example.com'])).resolves.toBeNull()
      await expect(findConversationByParticipants(['nobody@example.com'])).resolves.toBeNull()
      await expect(findConversationByParticipants([])).resolves.toBeNull()
    })

    it('uses cached Hide My Email classification for recipient lookup', async () => {
      const relay = 'relay@privaterelay.appleid.com'
      const identity = makeRecipientParticipantSetIdentity([ME], new Set([ME]))
      await db.people.add({ email: relay, displayName: 'Hide My Email' })
      await db.conversations.add(
        convoRow({ id: 'self-chat', participantHash: identity?.participantHash ?? '' }),
      )

      await expect(findConversationByParticipants([relay])).resolves.toBe('self-chat')
    })
  })

  describe('searchPeople', () => {
    beforeEach(async () => {
      await db.people.bulkAdd([
        { email: 'bob@example.com', displayName: 'Bob Jones' },
        { email: 'alice@example.com', displayName: 'Bobby Tables' },
        { email: 'zed@example.com', displayName: 'Zed' },
      ])
    })

    it('matches email prefix (case-insensitive) and display-name contains', async () => {
      const results = await searchPeople('BOB')
      expect(results.map((p) => p.email).sort()).toEqual(['alice@example.com', 'bob@example.com'])
    })

    it('respects the limit and returns [] for blank queries', async () => {
      await expect(searchPeople('e', 1)).resolves.toHaveLength(1)
      await expect(searchPeople('   ')).resolves.toEqual([])
    })
  })

  it('requestSync and drainOutbox no-op cleanly when no broker is configured', async () => {
    await expect(requestSync()).resolves.toBeUndefined()
    await expect(drainOutbox()).resolves.toBeUndefined()
  })
})
