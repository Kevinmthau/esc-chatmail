// Sync's copy of a send this device made carries the deterministic Message-ID
// the optimistic row was stamped with. Persist adopts that echo before applying
// it, so a delivery-unknown send (journal 'ambiguous') and a send whose verdict
// is still in flight converge into the one Gmail row instead of a second copy
// beside the retained local one.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { OutboundSendRow } from '@/db/types'
import { messageIdForOptimisticSend } from '@/outbox/mimeBuilder'
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

const LOCAL_ID = 'u_local'
const RFC_MESSAGE_ID = messageIdForOptimisticSend(LOCAL_ID)

function journal(status: OutboundSendRow['status']): OutboundSendRow {
  return {
    id: LOCAL_ID,
    conversationId: 'c1',
    newlyInsertedConversation: 0,
    createdAt: NOW - 2000,
    status,
    conversationSnapshot: null,
    remoteCommittedMessageId: '',
    remoteCommittedThreadId: '',
    ...(status === 'ambiguous' ? { admittedAt: NOW - 1500 } : {}),
  }
}

/** The SENT echo as Gmail returns it: the stamped Message-ID, not the fixture default. */
function echo() {
  const message = textMessage({
    id: 'gm1',
    threadId: 't1',
    from: ME,
    to: ['alice@example.com'],
    labelIds: ['SENT'],
    internalDate: NOW - 1000,
  })
  for (const header of message.payload!.headers!) {
    if (header.name === 'Message-ID') header.value = RFC_MESSAGE_ID
  }
  return message
}

async function seedRetainedRow(status: OutboundSendRow['status']) {
  await db.conversations.add(convoRow({ id: 'c1' }))
  await db.messages.add(
    msgRow({
      id: LOCAL_ID,
      conversationId: 'c1',
      senderEmail: ME,
      isFromMe: 1,
      labelIds: ['SENT'],
      sendState: status === 'ambiguous' ? 'sent' : 'pending',
      rfcMessageId: RFC_MESSAGE_ID,
      internalDate: NOW - 2000,
    }),
  )
  await db.outboundSends.add(journal(status))
}

describe('applyPersist adopts the echo of an own send', () => {
  // Revert-check: the reconcileSyncedSendEcho call in applyPersist's plan loop.
  it('converges a delivery-unknown send into the echoed Gmail row and finalizes its journal', async () => {
    await seedRetainedRow('ambiguous')

    const plans = await preparePersist([echo()], ctx)
    await applyPersist(db, plans, NOW)

    const own = await db.messages.filter((row) => row.isFromMe === 1).toArray()
    expect(own.map((row) => row.id)).toEqual(['gm1'])
    expect(own[0]).toMatchObject({ conversationId: 'c1', sendState: 'sent', gmThreadId: 't1' })
    expect((await db.outboundSends.get(LOCAL_ID))?.status).toBe('finalized')
  })

  it('settles a send whose verdict is still in flight when its echo arrives first', async () => {
    await seedRetainedRow('pending')

    const plans = await preparePersist([echo()], ctx)
    await applyPersist(db, plans, NOW)

    const own = await db.messages.filter((row) => row.isFromMe === 1).toArray()
    expect(own.map((row) => row.id)).toEqual(['gm1'])
    expect((await db.outboundSends.get(LOCAL_ID))?.status).toBe('finalized')
  })

  it('leaves an unrelated own message alone', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    const plans = await preparePersist(
      [textMessage({ id: 'gm2', from: ME, to: ['alice@example.com'], labelIds: ['SENT'] })],
      ctx,
    )
    await applyPersist(db, plans, NOW)

    expect(await db.messages.get('gm2')).toBeDefined()
    expect(await db.outboundSends.count()).toBe(0)
  })
})
