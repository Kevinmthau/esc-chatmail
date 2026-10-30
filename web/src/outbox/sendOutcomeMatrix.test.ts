// Post-admission outcome matrix of sendMessage (send.ts step (d)): a definite
// rejection rolls back or retains a retryable bubble; everything else thrown
// once the request was admitted is ambiguous — retained as sent, journaled
// 'ambiguous', never resent, never offered a retry.

import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { OutboundSendRow } from '@/db/types'
import { makeSendApi } from './send'
import {
  AuthRequiredError,
  GmailApiError,
  NetworkError,
  QuotaExhaustedError,
  RateLimitError,
} from '@/gmail/errors'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { messageIdForOptimisticSend } from './mimeBuilder'
import type { PendingAttachment } from './outboundAttachments'
import {
  AMBIGUOUS_SEND_STATUS,
  isDefiniteSendRejection,
  replayAbandonedSends,
  retryFailedSend,
  sendMessage,
  SendFailedError,
  STALE_PENDING_SEND_MS,
  type SendApi,
} from './send'
import { convoRow, makeTestDb, msgRow, NOW, seedAccount, storableBlob } from './testSupport'

const SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

const server = setupServer()

/** The journal as stored; status may hold the module-private 'ambiguous'. */
async function journalStatus(db: ChatmailDB, id: string): Promise<string | undefined> {
  const journal = await db.outboundSends.get(id)
  return journal?.status
}

function respondWithStatus(status: number): { calls: () => number } {
  let calls = 0
  server.use(
    http.post(SEND_URL, () => {
      calls += 1
      return HttpResponse.json(
        { error: { code: status, message: 'nope', errors: [{ reason: 'backendError' }] } },
        { status },
      )
    }),
  )
  return { calls: () => calls }
}

function pendingAttachment(id: string): PendingAttachment {
  const blob = storableBlob([new Uint8Array([1, 2, 3, 4])], { type: 'image/png' })
  return {
    id,
    filename: 'photo.png',
    mimeType: 'image/png',
    byteSize: blob.size,
    width: 100,
    height: 50,
    blob,
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

/** A journal row carrying fields outside OutboundSendRow (status 'ambiguous', admittedAt). */
function storedJournal(
  row: Omit<OutboundSendRow, 'status'> & { admittedAt?: number; status: string },
) {
  return row as unknown as OutboundSendRow
}

describe('sendMessage outcome matrix', () => {
  let db: ChatmailDB

  beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
  afterAll(() => server.close())

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'c1', snippet: 'old snip' }))
    await db.convoParticipants.add({
      conversationId: 'c1',
      email: 'bob@example.com',
      role: 'normal',
    })
    await db.messages.add(
      msgRow({ id: 'g_orig', conversationId: 'c1', internalDate: NOW - 60_000 }),
    )
  })

  afterEach(async () => {
    server.resetHandlers()
    await db.delete()
  })

  async function ownRows() {
    return (await db.messages.where('conversationId').equals('c1').toArray()).filter(
      (row) => row.isFromMe === 1,
    )
  }

  async function expectAmbiguousRetention(
    result: Awaited<ReturnType<typeof sendMessage>>,
    body: string,
  ): Promise<string> {
    expect(result.delivery).toBe('unknown')
    expect(result.conversationId).toBe('c1')
    const rows = await ownRows()
    expect(rows).toHaveLength(1)
    const retained = rows[0]!
    // Retained under its local id, shown as sent: no retry affordance exists
    // for a message the recipient may already have.
    expect(retained.id).toBe(result.messageId)
    expect(retained.sendState).toBe('sent')
    expect(retained.bodyText).toBe(body)
    expect(retained.rfcMessageId).toBe(messageIdForOptimisticSend(retained.id))
    expect(await journalStatus(db, retained.id)).toBe(AMBIGUOUS_SEND_STATUS)
    // The conversation still reflects it as the newest message.
    expect((await db.conversations.get('c1'))?.snippet).toBe(body)
    return retained.id
  }

  // Revert-check: isDefiniteSendRejection — classifying a 5xx as definite
  // routes it through failSend, which deletes this text-only row and throws.
  it('a 5xx verdict is ambiguous: the row is retained as sent, journaled ambiguous, and nothing is thrown', async () => {
    const { calls } = respondWithStatus(503)

    const result = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'maybe delivered' },
      { now: () => NOW },
    )

    await expectAmbiguousRetention(result, 'maybe delivered')
    // The transport never retransmits a send on 5xx.
    expect(calls()).toBe(1)
  })

  // Revert-check: isDefiniteSendRejection (NetworkError is not in its allow-list).
  it('a transport failure after admission is ambiguous: the web cannot prove the request never arrived', async () => {
    server.use(http.post(SEND_URL, () => HttpResponse.error()))

    const result = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'dropped mid-flight' },
      { now: () => NOW },
    )

    await expectAmbiguousRetention(result, 'dropped mid-flight')
  })

  // Revert-check: isDefiniteSendRejection — the untyped SyntaxError from
  // endpoints.sendMessage's response.json() must not be a definite rejection.
  it('a 2xx whose body cannot be parsed is ambiguous: Gmail accepted, the verdict was lost', async () => {
    server.use(
      http.post(
        SEND_URL,
        () => new HttpResponse('<html>gateway</html>', { status: 200, headers: {} }),
      ),
    )

    const result = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'accepted, verdict lost' },
      { now: () => NOW },
    )

    await expectAmbiguousRetention(result, 'accepted, verdict lost')
  })

  // Revert-check: recordAmbiguousSend — the attachment rows and the journal
  // transition there; without it the bubble keeps 'uploading' rows forever.
  it('an ambiguous send with attachments keeps the bytes, marks them uploaded, and refuses a retry', async () => {
    respondWithStatus(502)

    const result = await sendMessage(
      db,
      broker,
      {
        conversationId: 'c1',
        body: 'photo maybe delivered',
        attachments: [pendingAttachment('local_a1')],
      },
      { now: () => NOW },
    )

    const id = await expectAmbiguousRetention(result, 'photo maybe delivered')
    const rows = await db.attachments.where('messageId').equals(id).toArray()
    expect(rows.map((row) => row.state)).toEqual(['uploaded'])
    expect((await db.blobs.get('local_a1'))?.blob.size).toBe(4)

    // No second messages.send may ever be issued for it.
    let posts = 0
    const api: SendApi = {
      send: () => {
        posts += 1
        return Promise.resolve({ id: 'g_dup', threadId: 't1', labelIds: ['SENT'] })
      },
    }
    await expect(retryFailedSend(db, broker, id, { api, now: () => NOW })).rejects.toBeInstanceOf(
      SendFailedError,
    )
    expect(posts).toBe(0)
    expect((await db.messages.get(id))?.sendState).toBe('sent')
  })

  // Revert-check: the AMBIGUOUS_SEND_STATUS guard in retryFailedSend — the
  // journal is the durable word even if a row somehow reads 'failed'.
  it('retryFailedSend refuses a row whose journal is ambiguous without touching the network', async () => {
    await db.messages.add(
      msgRow({
        id: 'u_amb',
        conversationId: 'c1',
        isFromMe: 1,
        sendState: 'failed',
        labelIds: ['SENT'],
        internalDate: NOW - 1000,
      }),
    )
    await db.outboundSends.add(
      storedJournal({ ...makeJournal({ id: 'u_amb' }), status: AMBIGUOUS_SEND_STATUS }),
    )
    let posts = 0
    const api: SendApi = {
      send: () => {
        posts += 1
        return Promise.resolve({ id: 'g_dup', threadId: 't1', labelIds: ['SENT'] })
      },
    }

    const error = await retryFailedSend(db, broker, 'u_amb', { api, now: () => NOW }).catch(
      (thrown: unknown) => thrown,
    )

    expect(error).toBeInstanceOf(SendFailedError)
    expect((error as SendFailedError).message).toMatch(/already have been delivered/u)
    expect(posts).toBe(0)
    expect(await db.messages.get('u_amb')).toBeDefined()
  })

  // Revert-check: isDefiniteSendRejection (GmailApiError.status < 500).
  it('a 4xx verdict is a definite rejection: the text-only row is rolled back and the send throws', async () => {
    respondWithStatus(400)

    const error = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'refused' },
      { now: () => NOW },
    ).catch((thrown: unknown) => thrown)

    expect(error).toBeInstanceOf(SendFailedError)
    expect((error as SendFailedError).keptFailedMessage).toBe(false)
    expect(await ownRows()).toHaveLength(0)
    const journals = await db.outboundSends.toArray()
    expect(journals.map((journal) => journal.status)).toEqual(['failed'])
    // The rollup recomputes from the messages that remain (g_orig's body).
    expect((await db.conversations.get('c1'))?.snippet).toBe('Body')
  })

  // Revert-check: isDefiniteSendRejection (QuotaExhaustedError branch) — a 403
  // quota verdict is issued before processing; retaining it as sent would lose
  // the message silently, since no echo can ever arrive.
  it('a quota-exhausted 403 is a definite rejection: rolled back and reported, never retained as sent', async () => {
    server.use(
      http.post(SEND_URL, () =>
        HttpResponse.json(
          {
            error: {
              code: 403,
              message: 'Quota exceeded',
              errors: [{ reason: 'dailyLimitExceeded' }],
            },
          },
          { status: 403 },
        ),
      ),
    )

    const error = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'over quota' },
      { now: () => NOW },
    ).catch((thrown: unknown) => thrown)

    expect(error).toBeInstanceOf(SendFailedError)
    expect((error as SendFailedError).cause).toBeInstanceOf(QuotaExhaustedError)
    expect((error as SendFailedError).userMessage).toMatch(/quota/)
    expect(await ownRows()).toHaveLength(0)
    expect((await db.outboundSends.toArray()).map((journal) => journal.status)).toEqual(['failed'])
  })

  // Revert-check: isDefiniteSendRejection (RateLimitError branch) — a 429 is
  // refused before processing, so the row must not be retained as sent.
  it('an exhausted rate limit is a definite rejection, as on iOS', async () => {
    server.use(http.post(SEND_URL, () => new HttpResponse(null, { status: 429 })))

    const error = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'paced out' },
      { now: () => NOW, api: makeSendApi(broker, { maxAttempts: 1 }) },
    ).catch((thrown: unknown) => thrown)

    expect(error).toBeInstanceOf(SendFailedError)
    expect((error as SendFailedError).cause).toBeInstanceOf(RateLimitError)
    expect(await ownRows()).toHaveLength(0)
  })

  it('isDefiniteSendRejection allow-lists refusals and treats everything else as ambiguous', () => {
    expect(isDefiniteSendRejection(new GmailApiError(400, 'invalidArgument', 'bad'))).toBe(true)
    expect(isDefiniteSendRejection(new GmailApiError(403, 'forbidden', 'no'))).toBe(true)
    expect(isDefiniteSendRejection(new GmailApiError(404, 'notFound', 'no'))).toBe(true)
    expect(isDefiniteSendRejection(new RateLimitError(null))).toBe(true)
    expect(isDefiniteSendRejection(new QuotaExhaustedError('quota'))).toBe(true)
    expect(isDefiniteSendRejection(new AuthRequiredError('signed out', 'signed_out'))).toBe(true)

    expect(isDefiniteSendRejection(new GmailApiError(500, 'backendError', 'oops'))).toBe(false)
    expect(isDefiniteSendRejection(new GmailApiError(503, undefined, 'oops'))).toBe(false)
    expect(isDefiniteSendRejection(new NetworkError('fetch failed'))).toBe(false)
    expect(isDefiniteSendRejection(new SyntaxError('Unexpected token <'))).toBe(false)
    expect(isDefiniteSendRejection(new Error('cancelled'))).toBe(false)
  })
})

describe('replayAbandonedSends with ambiguous journals', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'c1' }))
  })

  afterEach(async () => {
    await db.delete()
  })

  function ownRow(id: string, overrides: Partial<Parameters<typeof msgRow>[0]> = {}) {
    return msgRow({
      id,
      conversationId: 'c1',
      isFromMe: 1,
      sendState: 'pending',
      labelIds: ['SENT'],
      rfcMessageId: messageIdForOptimisticSend(id),
      internalDate: NOW - 1000,
      ...overrides,
    })
  }

  // Revert-check: recordSendAdmission / the admittedAt branch in
  // replayAbandonedSends — without the marker the crashed send is retried
  // as a failed bubble although Gmail may have processed it.
  it('converts a stale pending journal that was admitted to the transport into delivery-unknown, never a retryable bubble', async () => {
    await db.messages.add(ownRow('u1', { hasAttachments: 1 }))
    await db.attachments.put({
      id: 'local_a1',
      messageId: 'u1',
      gmailAttachmentId: '',
      contentId: '',
      filename: 'photo.png',
      mimeType: 'image/png',
      byteSize: 4,
      width: 0,
      height: 0,
      state: 'uploading',
      lastDownloadFailedAt: 0,
    })
    const createdAt = NOW - STALE_PENDING_SEND_MS - 60_000
    await db.outboundSends.add(
      storedJournal({ ...makeJournal({ id: 'u1', createdAt }), admittedAt: createdAt + 10 }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    expect((await db.messages.get('u1'))?.sendState).toBe('sent')
    expect((await db.attachments.get('local_a1'))?.state).toBe('uploaded')
    expect(await journalStatus(db, 'u1')).toBe(AMBIGUOUS_SEND_STATUS)
  })

  it('still fails a stale pending journal that never reached the transport', async () => {
    await db.messages.add(ownRow('u2'))
    await db.outboundSends.add(
      makeJournal({ id: 'u2', createdAt: NOW - STALE_PENDING_SEND_MS - 60_000 }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.messages.get('u2')).toBeUndefined()
    expect(await journalStatus(db, 'u2')).toBe('failed')
  })

  // Revert-check: the AMBIGUOUS_SEND_STATUS pass in replayAbandonedSends.
  it('retains an ambiguous journal while its row exists and sweeps one whose row is gone', async () => {
    await db.messages.add(ownRow('u_kept', { sendState: 'sent' }))
    const createdAt = NOW - STALE_PENDING_SEND_MS - 60_000
    await db.outboundSends.bulkAdd([
      storedJournal({ ...makeJournal({ id: 'u_kept', createdAt }), status: AMBIGUOUS_SEND_STATUS }),
      storedJournal({ ...makeJournal({ id: 'u_gone', createdAt }), status: AMBIGUOUS_SEND_STATUS }),
    ])

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await journalStatus(db, 'u_kept')).toBe(AMBIGUOUS_SEND_STATUS)
    expect((await db.messages.get('u_kept'))?.sendState).toBe('sent')
    expect(await db.outboundSends.get('u_gone')).toBeUndefined()
  })

  // Revert-check: adoptStoredEchoOfAmbiguousSend — without it the retained
  // row and sync's echo of the same message both stay in the chat.
  it('adopts the echo sync already stored for an ambiguous send, dropping the retained local row', async () => {
    await db.messages.add(ownRow('u_echo', { sendState: 'sent' }))
    await db.bodies.add({ messageId: 'u_echo', html: '<p>hi</p>' })
    // Sync stored the server copy under its Gmail id with our Message-ID.
    await db.messages.add(
      ownRow('g_echo', {
        sendState: 'sent',
        gmThreadId: 't_echo',
        rfcMessageId: messageIdForOptimisticSend('u_echo'),
        internalDate: NOW - 500,
      }),
    )
    await db.outboundSends.add(
      storedJournal({ ...makeJournal({ id: 'u_echo' }), status: AMBIGUOUS_SEND_STATUS }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.messages.get('u_echo')).toBeUndefined()
    expect(await db.bodies.get('u_echo')).toBeUndefined()
    expect((await db.messages.get('g_echo'))?.sendState).toBe('sent')
    const journal = await db.outboundSends.get('u_echo')
    expect(journal?.status).toBe('finalized')
    expect(journal?.remoteCommittedMessageId).toBe('g_echo')
  })
})
