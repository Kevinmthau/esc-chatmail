// Integration regression for the compose AliasPicker passthrough:
// SendDraft.fromAlias overrides the reply-from ladder when (and only when)
// it matches an accepted send-as alias on the account.

import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { sendMessage } from './send'
import { convoRow, makeTestDb, ME, msgRow, seedAccount } from './testSupport'

const SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'
const ALIAS = 'work@example.com'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

const server = setupServer()

function decodeBase64Url(raw: string): string {
  return Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64').toString('utf8')
}

function captureSend(): { captured: { raw: string }[] } {
  const captured: { raw: string }[] = []
  server.use(
    http.post(SEND_URL, async ({ request }) => {
      captured.push((await request.json()) as { raw: string })
      return HttpResponse.json({ id: 'gm1', threadId: 't1', labelIds: ['SENT'] })
    }),
  )
  return { captured }
}

describe('sendMessage fromAlias passthrough', () => {
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
          displayName: 'Work Me',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'accepted',
        },
        {
          email: 'pending@example.com',
          displayName: '',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'pending',
        },
      ],
    })
    await db.conversations.put(convoRow({ id: 'c1' }))
    await db.convoParticipants.bulkAdd([
      { conversationId: 'c1', email: 'bob@example.com', role: 'normal' },
      { conversationId: 'c1', email: ME, role: 'me' },
    ])
    await db.messages.put(msgRow({ id: 'm1', conversationId: 'c1' }))
  })

  afterEach(async () => {
    server.resetHandlers()
    await db.delete()
  })

  it('sends From: the chosen accepted alias (case-insensitive match)', async () => {
    const { captured } = captureSend()
    await sendMessage(db, broker, {
      conversationId: 'c1',
      body: 'hi',
      fromAlias: 'Work@Example.com',
    })
    expect(captured).toHaveLength(1)
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain(`From: Work Me <${ALIAS}>`)
    const sent = await db.messages.get('gm1')
    expect(sent?.replyFromAddress).toBe(ALIAS)
    expect(sent?.senderEmail).toBe(ALIAS)
  })

  it('keeps Gmail dot/plus sendAs aliases distinct (exact-address match, no canonical collapse)', async () => {
    // Full Gmail canonicalization (normalizeEmail) maps me@ and me+news@ to
    // the same key; the fromAlias override must use exact-address compare or
    // the picked plus-tag alias silently collapses onto the primary.
    const GMAIL_ME = 'me@gmail.com'
    const GMAIL_PLUS = 'me+news@gmail.com'
    await seedAccount(db, {
      aliases: [GMAIL_ME],
      sendAsAliases: [
        {
          email: GMAIL_ME,
          displayName: '',
          isDefault: true,
          isPrimary: true,
          verificationStatus: 'accepted',
        },
        {
          email: GMAIL_PLUS,
          displayName: '',
          isDefault: false,
          isPrimary: false,
          verificationStatus: 'accepted',
        },
      ],
    })

    const { captured } = captureSend()
    await sendMessage(db, broker, {
      conversationId: 'c1',
      body: 'hi',
      fromAlias: GMAIL_PLUS,
    })
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain(`From: ${GMAIL_PLUS}\r\n`)
  })

  it('ignores a fromAlias that is not an accepted alias (ladder pick stands)', async () => {
    const { captured } = captureSend()
    await sendMessage(db, broker, {
      conversationId: 'c1',
      body: 'hi',
      fromAlias: 'pending@example.com',
    })
    const mime = decodeBase64Url(captured[0]?.raw ?? '')
    expect(mime).toContain(`From: ${ME}`)
    expect(mime).not.toContain('pending@example.com')
  })
})
