import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import { buildReplyMetadata, prefixSubjectForReply } from './replyMetadata'
import { convoRow, makeTestDb, ME, msgRow, NOW, seedAccount } from './testSupport'

describe('prefixSubjectForReply', () => {
  it('prefixes and is idempotent (case-insensitive)', () => {
    expect(prefixSubjectForReply('Hello')).toBe('Re: Hello')
    expect(prefixSubjectForReply('Re: Hello')).toBe('Re: Hello')
    expect(prefixSubjectForReply('RE: Hello')).toBe('RE: Hello')
    expect(prefixSubjectForReply('  re: Hello  ')).toBe('re: Hello')
    expect(prefixSubjectForReply('   ')).toBe('')
  })
})

describe('buildReplyMetadata', () => {
  let db: ChatmailDB

  beforeEach(async () => {
    db = makeTestDb()
    await seedAccount(db)
  })

  afterEach(async () => {
    await db.delete()
  })

  it('takes recipients from participants minus aliases (normalized compare)', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.convoParticipants.bulkAdd([
      { conversationId: 'c1', email: 'bob@example.com', role: 'normal' },
      { conversationId: 'c1', email: 'carol@example.com', role: 'normal' },
      // The user's own alias in a non-canonical form must be excluded.
      { conversationId: 'c1', email: 'Me@Example.com', role: 'me' },
    ])
    await db.messages.add(msgRow({ id: 'g1', conversationId: 'c1' }))

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.recipients).toEqual(['bob@example.com', 'carol@example.com'])
  })

  it('threads off the newest message with Re: idempotence and reference chain', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.convoParticipants.add({
      conversationId: 'c1',
      email: 'bob@example.com',
      role: 'normal',
    })
    await db.messages.bulkAdd([
      msgRow({ id: 'g_old', conversationId: 'c1', internalDate: NOW - 7200_000, subject: 'Old' }),
      msgRow({
        id: 'g_new',
        conversationId: 'c1',
        internalDate: NOW - 1000,
        subject: 'Re: Hello',
        gmThreadId: 't99',
        rfcMessageId: '<new@mail.example.com>',
        references: '<a@x> <b@x> <new@mail.example.com>',
      }),
    ])

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.subject).toBe('Re: Hello')
    expect(metadata.threadId).toBe('t99')
    expect(metadata.inReplyTo).toBe('<new@mail.example.com>')
    // The target's own Message-ID is appended once (dedup, order kept).
    expect(metadata.references).toEqual(['<a@x>', '<b@x>', '<new@mail.example.com>'])
    expect(metadata.replyFrom.email).toBe(ME)
  })

  it('prefixes Re: onto unprefixed subjects', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.add(msgRow({ id: 'g1', conversationId: 'c1', subject: 'Hello' }))
    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.subject).toBe('Re: Hello')
  })

  it('returns empty threading for an optimistic-only target', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.add(
      msgRow({
        id: 'u1',
        conversationId: 'c1',
        gmThreadId: '',
        rfcMessageId: '',
        references: '',
        subject: '',
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'pending',
        deliveredToAddress: '',
        replyFromAddress: '',
      }),
    )
    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.threadId).toBe('')
    expect(metadata.inReplyTo).toBe('')
    expect(metadata.references).toEqual([])
    expect(metadata.subject).toBe('')
    // Falls back to the default alias.
    expect(metadata.replyFrom.email).toBe(ME)
  })

  it('falls back to an alias among the target message participants when stored addresses are empty', async () => {
    // Messages persisted while the alias list was empty (fetch failed/raced)
    // store '' for deliveredTo/replyFrom; iOS ReplyAddressHint then matches an
    // alias among the message's To/Cc/Bcc rows, preferring non-default.
    const ALIAS = 'work@example.com'
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
      ],
    })
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.add(
      msgRow({ id: 'g1', conversationId: 'c1', deliveredToAddress: '', replyFromAddress: '' }),
    )
    await db.msgParticipants.bulkAdd([
      { messageId: 'g1', email: 'bob@example.com', displayName: 'Bob', kind: 'from' },
      { messageId: 'g1', email: ALIAS, displayName: '', kind: 'to' },
      { messageId: 'g1', email: ME, displayName: '', kind: 'cc' },
    ])

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME, ALIAS]))
    // Non-default alias wins over the default even though ME also appears.
    expect(metadata.replyFrom.email).toBe(ALIAS)
  })

  it('falls back to the newest non-fromMe message hint when the target has none', async () => {
    const ALIAS = 'work@example.com'
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
      ],
    })
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.bulkAdd([
      // Older inbound message delivered to the non-default alias.
      msgRow({
        id: 'g_old',
        conversationId: 'c1',
        internalDate: NOW - 7200_000,
        deliveredToAddress: ALIAS,
        replyFromAddress: ALIAS,
      }),
      // Newest message is an optimistic own send with no stored addresses.
      msgRow({
        id: 'u1',
        conversationId: 'c1',
        internalDate: NOW - 1000,
        isFromMe: 1,
        labelIds: ['SENT'],
        sendState: 'pending',
        deliveredToAddress: '',
        replyFromAddress: '',
      }),
    ])

    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME, ALIAS]))
    expect(metadata.replyFrom.email).toBe(ALIAS)
  })

  it('degrades to new-message metadata when the conversation has no messages', async () => {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.convoParticipants.add({
      conversationId: 'c1',
      email: 'bob@example.com',
      role: 'normal',
    })
    const metadata = await buildReplyMetadata(db, 'c1', new Set([ME]))
    expect(metadata.recipients).toEqual(['bob@example.com'])
    expect(metadata.inReplyTo).toBe('')
    expect(metadata.replyFrom.email).toBe(ME)
  })
})
