// The deterministic Message-ID of an optimistic send (port of
// MimeBuilder.messageId(forOptimisticMessageID:)): stored on the row, emitted
// in the header, and used both to thread a later reply onto an own message
// sync has not echoed yet and to recognize that echo.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { OutboundSendRow } from '@/db/types'
import type { TokenBroker } from '@/gmail/gmailFetch'
import type { SendMessageResponse } from '@/gmail/types'
import { messageIdForOptimisticSend, optimisticSendIdFromMessageId } from './mimeBuilder'
import { buildReplyMetadata, isLocalOptimisticRow } from './replyMetadata'
import { AMBIGUOUS_SEND_STATUS, reconcileSyncedSendEcho, sendMessage, type SendApi } from './send'
import { convoRow, makeTestDb, ME, msgRow, NOW, seedAccount } from './testSupport'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

function decodeBase64Url(raw: string): string {
  return Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
}

/** A send whose api call blocks until released, capturing the raw MIME. */
/**
 * A send API whose verdict the test hands out. The verdict is a deferred the
 * request awaits, not a resolver captured at call time: a test observes the
 * optimistic row (written before the request) and may release the verdict
 * before sendMessage has reached api.send, which under a loaded suite it
 * sometimes has not — a release recorded as "nothing to resolve" hung the
 * send until the test timed out.
 */
function heldApi(): {
  api: SendApi
  raw: () => string
  release: (response: SendMessageResponse) => void
} {
  let captured = ''
  let release: (response: SendMessageResponse) => void = () => {}
  const verdict = new Promise<SendMessageResponse>((resolve) => {
    release = resolve
  })
  const api: SendApi = {
    send: (params) => {
      captured = decodeBase64Url(params.raw)
      return verdict
    },
  }
  return { api, raw: () => captured, release: (response) => release(response) }
}

async function waitUntil(condition: () => Promise<boolean>, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error('timed out waiting for condition')
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

function makeJournal(
  overrides: Partial<OutboundSendRow> & Pick<OutboundSendRow, 'id'>,
): OutboundSendRow {
  return {
    conversationId: 'c1',
    newlyInsertedConversation: 0,
    createdAt: NOW,
    status: 'pending',
    conversationSnapshot: null,
    remoteCommittedMessageId: '',
    remoteCommittedThreadId: '',
    ...overrides,
  }
}

describe('messageIdForOptimisticSend', () => {
  // Revert-check: optimisticSendIdFromMessageId's strict re-encode check.
  it('round-trips the optimistic id and rejects anything it did not derive', () => {
    const id = '3f2b1c9a-7d4e-4a1b-9c8d-0e1f2a3b4c5d'
    const messageId = messageIdForOptimisticSend(id)
    expect(messageId).toMatch(/^<esc-[0-9a-f]+@inbox-chat\.web>$/u)
    expect(optimisticSendIdFromMessageId(messageId)).toBe(id)

    expect(optimisticSendIdFromMessageId('<abc@inbox-chat.web>')).toBeNull()
    expect(optimisticSendIdFromMessageId('<esc-@inbox-chat.web>')).toBeNull()
    expect(optimisticSendIdFromMessageId('<esc-abc@inbox-chat.web>')).toBeNull()
    expect(optimisticSendIdFromMessageId('<esc-ZZ@inbox-chat.web>')).toBeNull()
    // Same bytes under a foreign domain cannot impersonate a local row.
    expect(optimisticSendIdFromMessageId(messageId.replace('inbox-chat.web', 'x.y'))).toBeNull()
    // Uppercase hex re-encodes differently, so it is not ours either.
    expect(optimisticSendIdFromMessageId(messageId.toUpperCase())).toBeNull()
  })
})

describe('optimistic row Message-ID and reply threading', () => {
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
        references: '<r0@mail.example.com>',
        subject: 'Hello',
        internalDate: NOW - 60_000,
      }),
    )
  })

  afterEach(async () => {
    await db.delete()
  })

  async function pendingRow() {
    return (await db.messages.where('conversationId').equals('c1').toArray()).find(
      (row) => row.sendState === 'pending',
    )
  }

  // Revert-check: the rfcMessageId / references arguments of
  // makeOptimisticMessage and the messageId passed into buildOutboundMime.
  it('stores the emitted Message-ID and References chain on the optimistic row, and keeps them across the PK swap', async () => {
    const held = heldApi()
    const inFlight = sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'first' },
      { api: held.api, now: () => NOW },
    )
    await waitUntil(async () => (await pendingRow()) !== undefined && held.raw() !== '')

    const optimistic = (await pendingRow())!
    expect(optimistic.rfcMessageId).toBe(messageIdForOptimisticSend(optimistic.id))
    expect(held.raw()).toContain(`Message-ID: ${optimistic.rfcMessageId}\r\n`)
    expect(optimistic.references).toBe('<r0@mail.example.com> <orig@mail.example.com>')
    expect(isLocalOptimisticRow(optimistic)).toBe(true)

    held.release({ id: 'g_first', threadId: 't1', labelIds: ['SENT'] })
    await inFlight

    const sent = await db.messages.get('g_first')
    expect(sent?.rfcMessageId).toBe(optimistic.rfcMessageId)
    expect(sent?.references).toBe(optimistic.references)
    // Once it carries Gmail's id it is no longer a local row.
    expect(isLocalOptimisticRow(sent!)).toBe(false)
  })

  // Revert-check: storing rfcMessageId on the optimistic row — with '' the
  // second reply builds with inReplyTo '' and goes out without threading.
  it('threads a reply onto an own reply that committed but sync has not echoed yet', async () => {
    const first = heldApi()
    const firstSend = sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'first' },
      { api: first.api, now: () => NOW },
    )
    await waitUntil(() => Promise.resolve(first.raw() !== ''))
    first.release({ id: 'g_first', threadId: 't1', labelIds: ['SENT'] })
    await firstSend
    const firstMessageId = (await db.messages.get('g_first'))!.rfcMessageId

    const second = heldApi()
    const secondSend = sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'second' },
      { api: second.api, now: () => NOW + 1 },
    )
    await waitUntil(() => Promise.resolve(second.raw() !== ''))
    second.release({ id: 'g_second', threadId: 't1', labelIds: ['SENT'] })
    await secondSend

    expect(second.raw()).toContain(`In-Reply-To: ${firstMessageId}\r\n`)
    expect(second.raw()).toContain(
      `References: <r0@mail.example.com> <orig@mail.example.com>\r\n ${firstMessageId}\r\n`,
    )
  })

  // Revert-check: latestReplyTarget / isUnresolvedLocalSend in replyMetadata.
  it('skips a reply still in flight and threads onto the newest settled message instead', async () => {
    const held = heldApi()
    const inFlight = sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'first' },
      { api: held.api, now: () => NOW },
    )
    await waitUntil(async () => (await pendingRow()) !== undefined)

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.inReplyTo).toBe('<orig@mail.example.com>')
    expect(metadata.references).toEqual(['<r0@mail.example.com>', '<orig@mail.example.com>'])
    expect(metadata.threadId).toBe('t1')
    expect(metadata.subject).toBe('Re: Hello')

    held.release({ id: 'g_first', threadId: 't1', labelIds: ['SENT'] })
    await inFlight
  })

  it('skips a retained failed row and a delivery-unknown row as reply targets', async () => {
    await db.messages.bulkAdd([
      msgRow({
        id: 'u_failed',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        labelIds: ['SENT'],
        gmThreadId: 't1',
        rfcMessageId: messageIdForOptimisticSend('u_failed'),
        internalDate: NOW - 2000,
      }),
      msgRow({
        id: 'u_amb',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'sent',
        labelIds: ['SENT'],
        gmThreadId: 't1',
        rfcMessageId: messageIdForOptimisticSend('u_amb'),
        internalDate: NOW - 1000,
      }),
    ])
    await db.outboundSends.bulkAdd([
      makeJournal({ id: 'u_failed', status: 'failed' }),
      {
        ...makeJournal({ id: 'u_amb' }),
        status: AMBIGUOUS_SEND_STATUS,
      } as unknown as OutboundSendRow,
    ])

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.inReplyTo).toBe('<orig@mail.example.com>')
    expect(metadata.threadId).toBe('t1')
  })

  it('lets a thread-less local send block older thread metadata rather than falling back', async () => {
    // A plain compose still in flight: its thread id is not known yet.
    await db.messages.add(
      msgRow({
        id: 'u_compose',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'pending',
        labelIds: ['SENT'],
        gmThreadId: '',
        rfcMessageId: messageIdForOptimisticSend('u_compose'),
        internalDate: NOW - 1000,
      }),
    )

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.threadId).toBe('')
    expect(metadata.inReplyTo).toBe('')
    expect(metadata.references).toEqual([])
    expect(metadata.recipients).toEqual(['bob@example.com'])
  })
})

describe('reconcileSyncedSendEcho', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'c1' }))
  })

  afterEach(async () => {
    await db.delete()
  })

  // Revert-check: reconcileSyncedSendEcho's committed-status write before
  // reconcileCommittedSend.
  it('commits an ambiguous journal with the echo ids and swaps the retained row onto them', async () => {
    const rfcMessageId = messageIdForOptimisticSend('u1')
    await db.messages.add(
      msgRow({
        id: 'u1',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'sent',
        labelIds: ['SENT'],
        gmThreadId: '',
        rfcMessageId,
        internalDate: NOW - 1000,
      }),
    )
    await db.outboundSends.add({
      ...makeJournal({ id: 'u1' }),
      status: AMBIGUOUS_SEND_STATUS,
    } as unknown as OutboundSendRow)

    const adopted = await reconcileSyncedSendEcho(
      db,
      { rfcMessageId, remoteMessageId: 'g1', remoteThreadId: 't9' },
      NOW,
    )

    expect(adopted).toBe(true)
    expect(await db.messages.get('u1')).toBeUndefined()
    const swapped = await db.messages.get('g1')
    expect(swapped?.gmThreadId).toBe('t9')
    expect(swapped?.sendState).toBe('sent')
    expect(swapped?.rfcMessageId).toBe(rfcMessageId)
    const journal = await db.outboundSends.get('u1')
    expect(journal?.status).toBe('finalized')
    expect(journal?.remoteCommittedMessageId).toBe('g1')
  })

  it('ignores a Message-ID that names no live journal', async () => {
    expect(
      await reconcileSyncedSendEcho(db, {
        rfcMessageId: '<foreign@mail.example.com>',
        remoteMessageId: 'g1',
        remoteThreadId: 't1',
      }),
    ).toBe(false)
    expect(
      await reconcileSyncedSendEcho(db, {
        rfcMessageId: messageIdForOptimisticSend('never-journaled'),
        remoteMessageId: 'g1',
        remoteThreadId: 't1',
      }),
    ).toBe(false)
    await db.outboundSends.add(makeJournal({ id: 'u_done', status: 'finalized' }))
    expect(
      await reconcileSyncedSendEcho(db, {
        rfcMessageId: messageIdForOptimisticSend('u_done'),
        remoteMessageId: 'g1',
        remoteThreadId: 't1',
      }),
    ).toBe(false)
  })
})
