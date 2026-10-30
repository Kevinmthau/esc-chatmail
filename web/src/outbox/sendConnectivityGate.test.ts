// The pre-transmission connectivity gate (port of OutboundConnectivityGate):
// a send tapped while the browser KNOWS it is offline waits, bounded, for a
// path and otherwise fails before admission as a definite "not sent" — the
// draft comes back — instead of a fetch rejection the post-admission matrix
// must read as ambiguous and retain as sent.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { SendFailedError, sendMessage, type SendApi, type SendConnectivity } from './send'
import { convoRow, makeTestDb, msgRow, NOW, seedAccount } from './testSupport'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

function countingApi(): { api: SendApi; calls: () => number } {
  let calls = 0
  const api: SendApi = {
    send: () => {
      calls += 1
      return Promise.resolve({ id: 'g_new', threadId: 't1', labelIds: ['SENT'] })
    },
  }
  return { api, calls: () => calls }
}

describe('sendMessage pre-transmission connectivity gate', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.convoParticipants.add({
      conversationId: 'c1',
      email: 'bob@example.com',
      role: 'normal',
    })
    await db.messages.add(
      msgRow({
        id: 'g_orig',
        conversationId: 'c1',
        gmThreadId: 't1',
        rfcMessageId: '<orig@mail.example.com>',
        subject: 'Hello',
        internalDate: NOW - 60_000,
      }),
    )
  })

  afterEach(async () => {
    await db.delete()
  })

  // Revert-check: waitForUsablePath / the gate before recordSendAdmission in
  // sendMessage — without it the request is admitted and its failure is ambiguous.
  it('fails before admission when the path never returns: nothing sent, draft restorable', async () => {
    const { api, calls } = countingApi()
    let waits = 0
    const connectivity: SendConnectivity = {
      isOnline: () => false,
      waitForOnline: () => {
        waits += 1
        return Promise.resolve()
      },
    }

    const error = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'typed in the elevator' },
      { api, connectivity, now: () => NOW },
    ).catch((thrown: unknown) => thrown)

    expect(error).toBeInstanceOf(SendFailedError)
    expect((error as SendFailedError).userMessage).toMatch(/offline/)
    expect((error as SendFailedError).keptFailedMessage).toBe(false)
    expect(waits).toBe(1)
    expect(calls()).toBe(0)
    const own = await db.messages.filter((row) => row.isFromMe === 1).toArray()
    expect(own).toHaveLength(0)
    const journals = await db.outboundSends.toArray()
    expect(journals.map((journal) => journal.status)).toEqual(['failed'])
    expect(journals[0]?.admittedAt).toBeUndefined()
  })

  it('sends once the path returns within the wait', async () => {
    const { api, calls } = countingApi()
    let online = false
    const connectivity: SendConnectivity = {
      isOnline: () => online,
      waitForOnline: () => {
        online = true
        return Promise.resolve()
      },
    }

    const result = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'after the tunnel' },
      { api, connectivity, now: () => NOW },
    )

    expect(result.delivery).toBe('committed')
    expect(calls()).toBe(1)
  })

  it('does not wait at all while the browser reports a path', async () => {
    const { api, calls } = countingApi()
    let waits = 0
    const connectivity: SendConnectivity = {
      isOnline: () => true,
      waitForOnline: () => {
        waits += 1
        return Promise.resolve()
      },
    }

    await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'online' },
      { api, connectivity, now: () => NOW },
    )

    expect(waits).toBe(0)
    expect(calls()).toBe(1)
  })
})
