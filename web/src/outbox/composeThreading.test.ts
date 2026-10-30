// A plain compose is a NEW message even when its recipients resolve to an
// existing chat (iOS .compose requests: threadId nil, no reply metadata, the
// sheet's subject). Only a reply inherits the chat's threading.

import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { makeRecipientParticipantSetIdentity } from '@/identity/participantSet'
import type { PendingAttachment } from './outboundAttachments'
import { retryFailedSend, sendMessage } from './send'
import { convoRow, makeTestDb, ME, msgRow, NOW, seedAccount, storableBlob } from './testSupport'

const SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'
const ALIAS = 'me+work@example.com'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

const server = setupServer()

function decodeBase64Url(raw: string): string {
  return Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
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

describe('compose into an existing chat', () => {
  let db: ChatmailDB

  beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
  afterAll(() => server.close())

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db, {
      aliases: [ME, ALIAS],
      sendAsAliases: [
        {
          email: ME,
          displayName: '',
          isDefault: true,
          isPrimary: true,
          verificationStatus: 'accepted',
        },
        {
          email: ALIAS,
          displayName: 'Work',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'accepted',
        },
      ],
    })
    // The real participant hash, so routing lands the compose in c1 rather
    // than minting a fresh (and vacuously thread-less) conversation.
    const setIdentity = makeRecipientParticipantSetIdentity(
      ['bob@example.com'],
      new Set([ME, ALIAS]),
    )
    await db.conversations.add(
      convoRow({ id: 'c1', participantHash: setIdentity!.participantHash }),
    )
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
    server.resetHandlers()
    await db.delete()
  })

  // Revert-check: the `draft.conversationId === undefined` term of
  // isNewMessage in sendMessage — without it the compose inherits c1's
  // 'Re: Hello', In-Reply-To/References and threadId.
  it('sends a fresh message: no Re: subject, no threading headers, no threadId, same chat', async () => {
    const { captured } = respondWith('g_new', 't_new')

    const result = await sendMessage(
      db,
      broker,
      { to: ['bob@example.com'], body: 'a brand new note' },
      { now: () => NOW },
    )

    expect(result.conversationId).toBe('c1')
    expect(await db.conversations.count()).toBe(1)
    expect(captured).toHaveLength(1)
    expect(captured[0]?.threadId).toBeUndefined()
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain('To: bob@example.com\r\n')
    expect(mime).toContain('Subject: (No Subject)\r\n')
    expect(mime).not.toContain('Re: Hello')
    expect(mime).not.toContain('In-Reply-To:')
    expect(mime).not.toContain('References:')

    const sent = await db.messages.get('g_new')
    expect(sent?.subject).toBe('')
    expect(sent?.references).toBe('')
    expect(sent?.gmThreadId).toBe('t_new')
  })

  it('keeps the recipients and the chosen reply-from alias while dropping the threading', async () => {
    const { captured } = respondWith('g_alias', 't_alias')

    await sendMessage(
      db,
      broker,
      { to: ['bob@example.com'], body: 'from work', fromAlias: ALIAS },
      { now: () => NOW },
    )

    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain(`From: Work <${ALIAS}>\r\n`)
    expect(mime).toContain('To: bob@example.com\r\n')
    expect(captured[0]?.threadId).toBeUndefined()
    expect(mime).not.toContain('In-Reply-To:')
  })

  it('a reply into the same chat still threads (control)', async () => {
    const { captured } = respondWith('g_reply', 't1')

    await sendMessage(db, broker, { conversationId: 'c1', body: 'a reply' }, { now: () => NOW })

    expect(captured[0]?.threadId).toBe('t1')
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain('Subject: Re: Hello\r\n')
    expect(mime).toContain('In-Reply-To: <orig@mail.example.com>\r\n')
  })

  // Revert-check: the asNewMessage flag retryFailedSend sets for a
  // thread-less retained row — without it the retry threads the compose onto
  // whatever is newest in the chat by then.
  it('retrying a failed compose keeps it a new message even after newer mail arrived', async () => {
    server.use(
      http.post(SEND_URL, () =>
        HttpResponse.json(
          { error: { code: 400, message: 'rejected', errors: [{ reason: 'invalidArgument' }] } },
          { status: 400 },
        ),
      ),
    )
    const blob = storableBlob([new Uint8Array([1, 2, 3, 4])], { type: 'image/png' })
    const attachment: PendingAttachment = {
      id: 'local_a1',
      filename: 'photo.png',
      mimeType: 'image/png',
      byteSize: blob.size,
      width: 10,
      height: 10,
      blob,
    }
    await sendMessage(
      db,
      broker,
      { to: ['bob@example.com'], body: 'compose with photo', attachments: [attachment] },
      { now: () => NOW },
    ).catch(() => undefined)
    const failed = (await db.messages.where('conversationId').equals('c1').toArray()).find(
      (row) => row.sendState === 'failed',
    )
    expect(failed?.gmThreadId).toBe('')

    // Bob replies in the old thread before the user taps Retry.
    await db.messages.add(
      msgRow({
        id: 'g_newer',
        conversationId: 'c1',
        gmThreadId: 't1',
        rfcMessageId: '<newer@mail.example.com>',
        subject: 'Re: Hello',
        internalDate: NOW + 1000,
      }),
    )
    const { captured } = respondWith('g_retried', 't_retried')

    await retryFailedSend(db, broker, failed!.id, { now: () => NOW + 2000 })

    expect(captured[0]?.threadId).toBeUndefined()
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain('Subject: (No Subject)\r\n')
    expect(mime).not.toContain('In-Reply-To:')
    expect(mime).not.toContain('References:')
  })
})
