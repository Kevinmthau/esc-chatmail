// The SENT echo of an optimistic send lands on applyMessagePlan's existing-row
// branch (reconcileCommittedSend swapped the optimistic key to the Gmail id
// without writing msgParticipants), so that branch must seed the participant
// rows a row-less message is otherwise missing forever — while leaving a row
// that already has them alone.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { convoRow, msgRow } from '@/outbox/testSupport'
import { applyPersist, preparePersist, type PersistContext } from './persist'
import { makeTestDb, ME, NOW, textMessage } from './testSupport'

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

const sentEcho = () =>
  textMessage({
    id: 'gm1',
    from: ME,
    to: ['alice@example.com'],
    cc: ['carol@example.com'],
    labelIds: ['SENT'],
    internalDate: NOW - 1000,
  })

describe('applyMessagePlan existing-row participants', () => {
  // Revert-check: the msgParticipants.count()/bulkAdd block in
  // applyMessagePlan's existing branch (persist.ts).
  it('seeds msgParticipants for a reconciled optimistic send when its SENT echo is persisted', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    // The store as reconcileCommittedSend leaves it: Gmail id, sent, no rows.
    await db.messages.add(
      msgRow({
        id: 'gm1',
        conversationId: 'c1',
        senderEmail: ME,
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'sent',
      }),
    )
    expect(await db.msgParticipants.where('messageId').equals('gm1').count()).toBe(0)

    const plans = await preparePersist([sentEcho()], ctx)
    await applyPersist(db, plans, NOW)

    const rows = await db.msgParticipants.where('messageId').equals('gm1').toArray()
    expect(rows.map((r) => `${r.kind}:${r.email}`).sort()).toEqual([
      'cc:carol@example.com',
      'from:me@example.com',
      'to:alice@example.com',
    ])
    // Still the same row, updated in place.
    expect((await db.messages.get('gm1'))?.conversationId).toBe('c1')
  })

  it('leaves existing participant rows alone when the same message is persisted again', async () => {
    const first = await preparePersist([sentEcho()], ctx)
    await applyPersist(db, first, NOW)
    const before = await db.msgParticipants.where('messageId').equals('gm1').toArray()
    expect(before).toHaveLength(3)
    // A repair may have enriched a display name; a re-persist must not undo it.
    await db.msgParticipants.update(before[0]!.pk!, { displayName: 'Repaired' })

    const again = await preparePersist([sentEcho()], ctx)
    await applyPersist(db, again, NOW + 1)

    const after = await db.msgParticipants.where('messageId').equals('gm1').toArray()
    expect(after).toHaveLength(3)
    expect(after.find((r) => r.pk === before[0]!.pk)?.displayName).toBe('Repaired')
  })
})
