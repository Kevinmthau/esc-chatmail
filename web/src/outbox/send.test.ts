import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { OutboundSendRow } from '@/db/types'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { makeRecipientParticipantSetIdentity } from '@/identity/participantSet'
import {
  GENERIC_SEND_ERROR,
  replayAbandonedSends,
  sendFailureMessage,
  sendMessage,
  SendFailedError,
  STALE_PENDING_SEND_MS,
  type SendApi,
} from './send'
import { convoRow, makeTestDb, ME, msgRow, NOW, seedAccount } from './testSupport'

const SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

const server = setupServer()

function decodeBase64Url(raw: string): string {
  return Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
}

/** Decodes one base64 MIME part body (everything up to its closing boundary). */
function decodeBase64Body(part: string): string {
  const base64 = part.split(/\r\n--/u)[0]?.replaceAll('\r\n', '') ?? ''
  return Buffer.from(base64, 'base64').toString('utf8')
}

interface CapturedSend {
  raw: string
  threadId?: string
}

function respondWith(id: string, threadId: string): { captured: CapturedSend[] } {
  const captured: CapturedSend[] = []
  server.use(
    http.post(SEND_URL, async ({ request }) => {
      captured.push((await request.json()) as CapturedSend)
      return HttpResponse.json({ id, threadId, labelIds: ['SENT'] })
    }),
  )
  return { captured }
}

function respondWithError(status: number): void {
  server.use(
    http.post(SEND_URL, () =>
      HttpResponse.json(
        { error: { code: status, message: 'rejected', errors: [{ reason: 'invalidArgument' }] } },
        { status },
      ),
    ),
  )
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

describe('sendMessage', () => {
  let db: ChatmailDB

  beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
  afterAll(() => server.close())

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
  })

  afterEach(async () => {
    server.resetHandlers()
    await db.delete()
  })

  async function seedReplyConversation(): Promise<void> {
    await db.conversations.add(convoRow({ id: 'c1', snippet: 'old snip' }))
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
  }

  it('sends a reply end-to-end: threading headers, PK swap, journal finalized', async () => {
    await seedReplyConversation()
    const { captured } = respondWith('g_new', 't1')

    const result = await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'Reply body' },
      {
        now: () => NOW,
      },
    )

    expect(result).toEqual({ messageId: 'g_new', conversationId: 'c1' })

    // Request: threadId passed, MIME carries the reply chain and recipients.
    expect(captured).toHaveLength(1)
    expect(captured[0]?.threadId).toBe('t1')
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain('To: bob@example.com\r\n')
    expect(mime).toContain('Subject: Re: Hello\r\n')
    expect(mime).toContain('In-Reply-To: <orig@mail.example.com>\r\n')
    expect(mime).toContain('References: <r0@mail.example.com> <orig@mail.example.com>\r\n')
    expect(mime).toContain(`From: ${ME}\r\n`)
    expect(mime).toContain('Reply body')

    // PK swap: the optimistic UUID row is gone, the Gmail-id row is 'sent'.
    const sent = await db.messages.get('g_new')
    expect(sent?.sendState).toBe('sent')
    expect(sent?.gmThreadId).toBe('t1')
    expect(sent?.isFromMe).toBe(1)
    expect(await db.messages.count()).toBe(2)

    const journals = await db.outboundSends.toArray()
    expect(journals).toHaveLength(1)
    expect(journals[0]?.status).toBe('finalized')
    expect(journals[0]?.remoteCommittedMessageId).toBe('g_new')

    // Rollup ran: the conversation reflects the new message.
    const conversation = await db.conversations.get('c1')
    expect(conversation?.lastMessageDate).toBe(NOW)
    expect(conversation?.snippet).toBe('Reply body')
  })

  it('creates a conversation through identity/routing for new recipients', async () => {
    respondWith('g_n1', 't_n1')

    const result = await sendMessage(
      db,
      broker,
      { to: ['Dave@Example.com'], body: 'hi dave' },
      {
        now: () => NOW,
      },
    )

    const conversation = await db.conversations.get(result.conversationId)
    const expectedIdentity = makeRecipientParticipantSetIdentity(
      ['Dave@Example.com'],
      new Set([ME]),
    )
    // Compose-path hash goes through identity/participantSet — parity check.
    expect(conversation?.participantHash).toBe(expectedIdentity?.participantHash)
    const participants = await db.convoParticipants
      .where('conversationId')
      .equals(result.conversationId)
      .toArray()
    expect(participants.map((p) => p.email)).toEqual(['dave@example.com'])
    expect((await db.messages.get('g_n1'))?.sendState).toBe('sent')
  })

  it('rolls back and deletes a newly minted conversation on failure', async () => {
    respondWithError(400)

    await expect(
      sendMessage(db, broker, { to: ['dave@example.com'], body: 'hi' }, { now: () => NOW }),
    ).rejects.toBeInstanceOf(SendFailedError)

    expect(await db.conversations.count()).toBe(0)
    expect(await db.convoParticipants.count()).toBe(0)
    expect(await db.messages.count()).toBe(0)
    expect((await db.outboundSends.toArray())[0]?.status).toBe('failed')
  })

  it('recomputes the rollup on failure so the conversation reflects the remaining messages', async () => {
    await seedReplyConversation()
    respondWithError(400)

    await expect(
      sendMessage(db, broker, { conversationId: 'c1', body: 'doomed' }, { now: () => NOW }),
    ).rejects.toBeInstanceOf(SendFailedError)

    // Derived fields come from the surviving message set (g_orig), not from a
    // blind snapshot restore of the pre-send row.
    const conversation = await db.conversations.get('c1')
    expect(conversation?.snippet).toBe('Body')
    expect(conversation?.lastMessageDate).toBe(NOW - 60_000)
    // Optimistic message removed; the original message survives.
    expect(await db.messages.count()).toBe(1)
    expect(await db.messages.get('g_orig')).toBeDefined()
  })

  it('does not regress concurrent sync updates when rolling back a failed send', async () => {
    await seedReplyConversation()
    // Inbound message delivered by sync while the send is in flight, then the
    // send fails: rollback must keep the inbound's newer state, not restore
    // the stale pre-send snapshot.
    const api: SendApi = {
      send: async () => {
        await db.messages.add(
          msgRow({
            id: 'g_in',
            conversationId: 'c1',
            internalDate: NOW - 100,
            snippet: 'inbound wins',
            cleanedSnippet: 'inbound wins',
            chatPreviewText: 'inbound wins',
            bodyText: 'inbound wins',
            isUnread: 1,
          }),
        )
        const conversation = (await db.conversations.get('c1'))!
        await db.conversations.put({
          ...conversation,
          lastMessageDate: NOW - 100,
          snippet: 'inbound wins',
          inboxUnreadCount: 1,
        })
        throw new Error('boom')
      },
    }

    await expect(
      sendMessage(db, broker, { conversationId: 'c1', body: 'doomed' }, { now: () => NOW, api }),
    ).rejects.toBeInstanceOf(SendFailedError)

    const conversation = await db.conversations.get('c1')
    expect(conversation?.lastMessageDate).toBe(NOW - 100)
    expect(conversation?.snippet).toBe('inbound wins')
    expect(conversation?.inboxUnreadCount).toBe(1)
    expect(await db.messages.get('g_in')).toBeDefined()
  })

  // Regression: address validation lives in the MIME builder, which used to
  // run AFTER the optimistic insert and OUTSIDE the try that owns
  // rollbackFailedSend. A rejected address therefore left a 'pending' journal
  // and a message row stuck at sendState 'pending' — a "Sending…" bubble that
  // nothing resolved for the rest of the session (replayAbandonedSends only
  // sweeps journals older than 10 minutes, at boot).
  describe('address validation rejects the send before anything optimistic exists', () => {
    /** Records whether the transport was ever reached. */
    function neverCalledApi(): { calls: number; api: SendApi } {
      const state = { calls: 0, api: { send: () => Promise.reject(new Error('unreachable')) } }
      state.api = {
        send: () => {
          state.calls += 1
          return Promise.reject(new Error('should not transmit'))
        },
      }
      return state
    }

    it('reply into a conversation whose participant smuggles a second address', async () => {
      // The exact case the builder defends against: a whole crafted From
      // header captured as one participant email.
      await db.conversations.add(convoRow({ id: 'c1', snippet: 'old snip' }))
      await db.convoParticipants.add({
        conversationId: 'c1',
        email: 'billing@acme.com, harvest@evil.tld',
        role: 'normal',
      })
      await db.messages.add(
        msgRow({ id: 'g_orig', conversationId: 'c1', internalDate: NOW - 60_000 }),
      )
      const transport = neverCalledApi()

      const error = await sendMessage(
        db,
        broker,
        { conversationId: 'c1', body: 'Reply body' },
        { now: () => NOW, api: transport.api },
      ).catch((thrown: unknown) => thrown)

      expect(error).toBeInstanceOf(SendFailedError)
      // The offending address is named for the compose UI.
      expect(sendFailureMessage(error)).toContain('billing@acme.com, harvest@evil.tld')
      expect(transport.calls).toBe(0)

      // No optimistic debris: no extra message row, no journal, and the
      // conversation rollup was never bumped toward a message never sent.
      expect(await db.messages.count()).toBe(1)
      expect(await db.outboundSends.count()).toBe(0)
      const conversation = await db.conversations.get('c1')
      expect(conversation?.snippet).toBe('old snip')
      expect(conversation?.lastMessageDate).toBe(NOW - 60 * 60 * 1000)
    })

    it('compose to a semicolon-joined paste leaves no phantom conversation, even on retry', async () => {
      const transport = neverCalledApi()
      const draft = { to: ['a@b.com;c@d.com'], body: 'hi' }

      // Twice: the retry the compose dialog invites must not accumulate debris.
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const error = await sendMessage(db, broker, draft, {
          now: () => NOW,
          api: transport.api,
        }).catch((thrown: unknown) => thrown)
        expect(error).toBeInstanceOf(SendFailedError)
        expect(sendFailureMessage(error)).toContain('a@b.com;c@d.com')
      }

      expect(transport.calls).toBe(0)
      // The conversation minted in step (a) is dropped again: no phantom chat
      // in the list, no stuck bubbles accumulating across retries.
      expect(await db.conversations.count()).toBe(0)
      expect(await db.convoParticipants.count()).toBe(0)
      expect(await db.messages.count()).toBe(0)
      expect(await db.outboundSends.count()).toBe(0)
    })

    it('keeps a conversation that a concurrent sync filled while the build ran', async () => {
      // Only an EMPTY newly-minted conversation is dropped; a real inbound
      // message delivered meanwhile must survive the rejection.
      await db.conversations.add(convoRow({ id: 'c1' }))
      await db.convoParticipants.add({
        conversationId: 'c1',
        email: 'billing@acme.com, harvest@evil.tld',
        role: 'normal',
      })
      await db.messages.add(msgRow({ id: 'g_in', conversationId: 'c1' }))

      await expect(
        sendMessage(db, broker, { conversationId: 'c1', body: 'x' }, { now: () => NOW }),
      ).rejects.toBeInstanceOf(SendFailedError)

      expect(await db.conversations.get('c1')).toBeDefined()
      expect(await db.messages.get('g_in')).toBeDefined()
    })

    it('a transport failure still reports the generic copy', async () => {
      await seedReplyConversation()
      respondWithError(400)

      const error = await sendMessage(
        db,
        broker,
        { conversationId: 'c1', body: 'doomed' },
        { now: () => NOW },
      ).catch((thrown: unknown) => thrown)

      expect(sendFailureMessage(error)).toBe(GENERIC_SEND_ERROR)
    })
  })

  it('reconcile-time rollup overwrites conversation state mutated during the network call', async () => {
    await seedReplyConversation()
    // Corrupt the derived fields mid-send: only the rollup that runs inside
    // reconcileCommittedSend can repair them (the optimistic bump already
    // happened before the network call).
    const api: SendApi = {
      send: async () => {
        const conversation = (await db.conversations.get('c1'))!
        await db.conversations.put({ ...conversation, snippet: 'sentinel', lastMessageDate: 1 })
        return { id: 'g_new', threadId: 't1', labelIds: ['SENT'] }
      },
    }

    await sendMessage(
      db,
      broker,
      { conversationId: 'c1', body: 'Reply body' },
      { now: () => NOW, api },
    )

    const conversation = await db.conversations.get('c1')
    expect(conversation?.lastMessageDate).toBe(NOW)
    expect(conversation?.snippet).toBe('Reply body')
  })

  // A forward is a NEW message. The reply-metadata ladder always targets the
  // conversation's newest message, so without the forward override a forward
  // to someone you already chat with would inherit that message's 'Re: '
  // subject, its In-Reply-To/References chain and its Gmail thread.
  describe('forward', () => {
    it('sends without threading headers or threadId, using the Fwd: subject', async () => {
      await seedReplyConversation()
      const { captured } = respondWith('g_fwd', 't_new')

      await sendMessage(
        db,
        broker,
        {
          to: ['bob@example.com'],
          body: 'FYI\n\n---------- Forwarded message ---------\nFrom: Carol\n\nOriginal text',
          forward: { subject: 'Fwd: Quarterly numbers' },
        },
        { now: () => NOW },
      )

      expect(captured).toHaveLength(1)
      // No threadId: Gmail must not staple this onto the existing thread.
      expect(captured[0]?.threadId).toBeUndefined()
      const mime = decodeBase64Url(captured[0]?.raw ?? '')
      expect(mime).toContain('Subject: Fwd: Quarterly numbers\r\n')
      expect(mime).not.toContain('In-Reply-To:')
      expect(mime).not.toContain('References:')
      expect(mime).toContain('Original text')
      // Recipients and the reply-from alias still come from the ladder.
      expect(mime).toContain('To: bob@example.com\r\n')
      expect(mime).toContain(`From: ${ME}\r\n`)
    })

    it('sends multipart/alternative when the forward carries html', async () => {
      await seedReplyConversation()
      const { captured } = respondWith('g_fwd', 't_new')

      await sendMessage(
        db,
        broker,
        {
          to: ['bob@example.com'],
          body: 'text part',
          forward: {
            subject: 'Fwd: Quarterly numbers',
            htmlBody: '<!DOCTYPE html>\n<html>\n<body>\n<p>html part</p>\n</body>\n</html>',
          },
        },
        { now: () => NOW },
      )

      const mime = decodeBase64Url(captured[0]?.raw ?? '')
      expect(mime).toContain('Content-Type: multipart/alternative;')
      expect(mime).toContain('Content-Type: text/plain; charset=UTF-8')
      expect(mime).toContain('Content-Type: text/html; charset=UTF-8')
      const parts = mime.split(/Content-Transfer-Encoding: base64\r\n\r\n/u).slice(1)
      const decoded = parts.map((part) => decodeBase64Body(part))
      expect(decoded[0]).toContain('text part')
      expect(decoded[1]).toContain('<p>html part</p>')
    })

    it('still routes into the participant-set conversation the recipients belong to', async () => {
      await seedReplyConversation()
      const setIdentity = makeRecipientParticipantSetIdentity(['bob@example.com'], new Set([ME]))
      await db.conversations.update('c1', { participantHash: setIdentity?.participantHash })
      const { captured } = respondWith('g_fwd', 't_new')

      const result = await sendMessage(
        db,
        broker,
        { to: ['bob@example.com'], body: 'fwd body', forward: { subject: 'Fwd: hi' } },
        { now: () => NOW },
      )

      expect(result.conversationId).toBe('c1')
      const sent = await db.messages.get('g_fwd')
      expect(sent?.subject).toBe('Fwd: hi')
      expect(await db.conversations.count()).toBe(1)

      // Landing in c1 is only half the contract: c1's reply ladder resolves a
      // newest message with a real gmThreadId and rfcMessageId, so THIS test —
      // not the fresh-conversation one above, whose ladder is already empty —
      // is where deleting the forward override in send.ts would staple the
      // forward onto the existing thread. Pin the request itself.
      expect(captured[0]?.threadId).toBeUndefined()
      const mime = decodeBase64Url(captured[0]?.raw ?? '')
      expect(mime).toContain('Subject: Fwd: hi')
      expect(mime).not.toContain('In-Reply-To:')
      expect(mime).not.toContain('References:')
    })
  })
})

describe('replayAbandonedSends', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
    await db.conversations.add(convoRow({ id: 'c1' }))
  })

  afterEach(async () => {
    await db.delete()
  })

  it('finalizes a committed journal whose reconcile was lost to a crash (bodies move)', async () => {
    await db.messages.add(
      msgRow({
        id: 'u1',
        conversationId: 'c1',
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'pending',
        hasHtmlBody: 1,
        internalDate: NOW - 500,
      }),
    )
    await db.bodies.add({ messageId: 'u1', html: '<p>sent html</p>' })
    await db.outboundSends.add(
      makeJournal({
        id: 'u1',
        status: 'committed',
        remoteCommittedMessageId: 'g9',
        remoteCommittedThreadId: 't9',
      }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.messages.get('u1')).toBeUndefined()
    const swapped = await db.messages.get('g9')
    expect(swapped?.sendState).toBe('sent')
    expect(swapped?.gmThreadId).toBe('t9')
    expect(await db.bodies.get('u1')).toBeUndefined()
    expect((await db.bodies.get('g9'))?.html).toBe('<p>sent html</p>')
    expect((await db.outboundSends.get('u1'))?.status).toBe('finalized')
  })

  it('deletes the optimistic row when sync already delivered the sent copy', async () => {
    await db.messages.bulkAdd([
      msgRow({
        id: 'u1',
        conversationId: 'c1',
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'pending',
        internalDate: NOW - 500,
      }),
      msgRow({
        id: 'g9',
        conversationId: 'c1',
        isFromMe: 1,
        labelIds: ['SENT'],
        gmThreadId: 't9',
        internalDate: NOW - 400,
      }),
    ])
    await db.outboundSends.add(
      makeJournal({
        id: 'u1',
        status: 'committed',
        remoteCommittedMessageId: 'g9',
        remoteCommittedThreadId: 't9',
      }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.messages.get('u1')).toBeUndefined()
    // The synced copy is untouched.
    expect((await db.messages.get('g9'))?.sendState).toBeUndefined()
    expect((await db.outboundSends.get('u1'))?.status).toBe('finalized')
  })

  it('sweeps stale pending journals with no optimistic row, keeping fresh ones', async () => {
    await db.outboundSends.bulkAdd([
      makeJournal({ id: 'u_stale', createdAt: NOW - STALE_PENDING_SEND_MS - 60_000 }),
      makeJournal({ id: 'u_fresh', createdAt: NOW - 1000 }),
    ])

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.outboundSends.get('u_stale')).toBeUndefined()
    expect(await db.outboundSends.get('u_fresh')).toBeDefined()
  })

  it('rolls back a stale pending journal whose optimistic row still exists (no eternal Sending… bubble)', async () => {
    await db.messages.add(
      msgRow({ id: 'u1', conversationId: 'c1', sendState: 'pending', labelIds: ['SENT'] }),
    )
    await db.outboundSends.add(
      makeJournal({ id: 'u1', createdAt: NOW - STALE_PENDING_SEND_MS - 60_000 }),
    )

    await replayAbandonedSends(db, { now: () => NOW })

    // iOS reconcileAbandonedOptimisticSendMutations routes journals with no
    // remote-committed result through the failed-send path: the optimistic
    // row is deleted and the journal marked failed.
    expect(await db.messages.get('u1')).toBeUndefined()
    expect((await db.outboundSends.get('u1'))?.status).toBe('failed')
  })

  it('sweeps stale failed/finalized journals at startup, keeping fresh ones', async () => {
    await db.outboundSends.bulkAdd([
      makeJournal({
        id: 'j_failed_old',
        status: 'failed',
        createdAt: NOW - STALE_PENDING_SEND_MS - 1,
      }),
      makeJournal({
        id: 'j_finalized_old',
        status: 'finalized',
        createdAt: NOW - STALE_PENDING_SEND_MS - 1,
      }),
      makeJournal({ id: 'j_failed_fresh', status: 'failed', createdAt: NOW - 1000 }),
    ])

    await replayAbandonedSends(db, { now: () => NOW })

    expect(await db.outboundSends.get('j_failed_old')).toBeUndefined()
    expect(await db.outboundSends.get('j_finalized_old')).toBeUndefined()
    expect(await db.outboundSends.get('j_failed_fresh')).toBeDefined()
  })
})
