import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import type { GmailMessage } from '@/gmail/types'
import { calculateParticipantHash } from '@/identity/participantSet'
import { strictParticipantSetIdentity } from '@/identity/strictIdentity'
import { convoRow, msgRow, storableBlob } from '@/outbox/testSupport'
import {
  applyPersist,
  LOCAL_MODIFICATION_MAX_AGE_MS,
  mergeExistingMessage,
  preparePersist,
  preparePersistPlan,
  PREPARE_CONCURRENCY,
  type MessagePersistPlan,
  type PersistContext,
} from './persist'
import { b64url, makeTestDb, ME, NOW, textMessage } from './testSupport'

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
})

afterEach(async () => {
  await db.delete()
})

const ctx: PersistContext = {
  myAliases: new Set([ME]),
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

async function persistMessages(
  messages: Parameters<typeof preparePersist>[0],
  now = NOW,
): Promise<Awaited<ReturnType<typeof applyPersist>>> {
  const plans = await preparePersist(messages, ctx)
  return applyPersist(db, plans, now)
}

describe('preparePersistPlan', () => {
  it('classifies SPAM/DRAFT/TRASH messages as excluded', async () => {
    const plan = await preparePersistPlan(
      textMessage({ id: 'm1', labelIds: ['SPAM', 'UNREAD'] }),
      ctx,
    )
    expect(plan).toEqual({ kind: 'excluded', id: 'm1', label: 'SPAM' })
  })

  it('classifies payload-less messages as unprocessable', async () => {
    const plan = await preparePersistPlan({ id: 'm1', threadId: 't1', labelIds: ['INBOX'] }, ctx)
    expect(plan).toEqual({ kind: 'unprocessable', id: 'm1' })
  })

  it('derives the message row fields (from/unread/previews/labels)', async () => {
    const plan = (await preparePersistPlan(
      textMessage({
        id: 'm1',
        from: 'Alice Smith <alice@example.com>',
        subject: 'Lunch?',
        body: 'Are you free at noon?',
        labelIds: ['INBOX', 'UNREAD'],
        internalDate: NOW - 1000,
      }),
      ctx,
    )) as MessagePersistPlan
    expect(plan.kind).toBe('message')
    expect(plan.message.senderEmail).toBe('alice@example.com')
    expect(plan.message.senderName).toBe('Alice Smith')
    expect(plan.message.isFromMe).toBe(0)
    expect(plan.message.isUnread).toBe(1)
    expect(plan.message.subject).toBe('Lunch?')
    expect(plan.message.cleanedSnippet).toBe('Are you free at noon?')
    expect(plan.message.labelIds).toEqual(['INBOX', 'UNREAD'])
    expect(plan.message.rfcMessageId).toBe('<m1@mail.example.com>')
    expect(plan.bodyHtml).toBeNull()
  })

  it('keys identity by From+To+Cc minus self, BCC excluded, Hide-My-Email dropped', async () => {
    const plan = (await preparePersistPlan(
      textMessage({
        id: 'm1',
        from: 'alice@example.com',
        to: [ME, 'bob@example.com'],
        cc: ['Hide My Email <relay@privaterelay.appleid.com>'],
        bcc: ['secret@example.com'],
      }),
      ctx,
    )) as MessagePersistPlan
    expect(plan.identity.participants).toEqual(['alice@example.com', 'bob@example.com'])
    expect(plan.identity.participantHash).toBe(
      calculateParticipantHash(['alice@example.com', 'bob@example.com']),
    )
    // BCC is stored on the message but excluded from identity.
    expect(plan.participants.map((p) => `${p.kind}:${p.email}`)).toContain('bcc:secret@example.com')
    expect(plan.participants.some((p) => p.email.includes('privaterelay'))).toBe(false)
  })

  it.each(['to', 'cc'] as const)(
    'matches header identity when legacy rows still contain a Hide-My-Email %s recipient',
    async (kind) => {
      // Revert-check: the strict row derivation must exclude HME To/Cc rows
      // just as preparePersistPlan's real header path does.
      const plan = (await preparePersistPlan(
        textMessage({
          id: 'hme-parity',
          from: 'alice@example.com',
          to: [ME],
          [kind]: [ME, 'Hide My Email <relay@icloud.com>'],
        }),
        ctx,
      )) as MessagePersistPlan
      // Current persistence already excludes HME recipients. Model the
      // legacy/enriched row set consumed by migration and repair instead.
      const legacyRows = [
        ...plan.participants.map((participant) => ({ ...participant, messageId: plan.message.id })),
        { messageId: plan.message.id, email: 'relay@icloud.com', displayName: '', kind },
      ]
      const rowIdentity = strictParticipantSetIdentity(
        legacyRows,
        plan.message.senderEmail,
        ctx.myAliases,
        new Map([['relay@icloud.com', 'Hide My Email']]),
      )

      expect(plan.identity.participants).toEqual(['alice@example.com'])
      expect(rowIdentity?.participants).toEqual(plan.identity.participants)
      expect(rowIdentity?.participantHash).toBe(plan.identity.participantHash)
      expect(rowIdentity?.type).toBe(plan.identity.type)
    },
  )

  it('includes every mailbox of a multi-address From header in identity (iOS parity)', async () => {
    // Rare but valid RFC 5322 shape; iOS makeConversationIdentity splits the
    // whole raw From value and inserts BOTH addresses.
    const plan = (await preparePersistPlan(
      textMessage({
        id: 'm1',
        from: 'Alice <alice@x.com>, Bob <bob@y.com>',
        to: [ME],
      }),
      ctx,
    )) as MessagePersistPlan
    expect(plan.identity.participants).toEqual(['alice@x.com', 'bob@y.com'])
    expect(plan.identity.participantHash).toBe(
      calculateParticipantHash(['alice@x.com', 'bob@y.com']),
    )
    // The message row still keeps the first mailbox as the sender.
    expect(plan.message.senderEmail).toBe('alice@x.com')
  })

  it.each(['From', 'To', 'Cc'])(
    'preserves quoted local-part brackets in %s participants and identity',
    async (headerName) => {
      const email = '"a<b"@example.com'
      const mailbox = `Display <${email}>`
      const plan = (await preparePersistPlan(
        textMessage({
          id: 'quoted-local-part',
          from: headerName === 'From' ? mailbox : ME,
          to: headerName === 'To' ? [ME, mailbox] : [ME],
          cc: headerName === 'Cc' ? [mailbox] : [],
        }),
        ctx,
      )) as MessagePersistPlan

      expect(plan.identity.participants).toEqual([email])
      expect(plan.identity.participantHash).toBe(calculateParticipantHash([email]))
      expect(plan.participants).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: headerName.toLowerCase(), email }),
        ]),
      )
    },
  )

  it.each(['From', 'To', 'Cc'])(
    'preserves later %s recipients after a display name with an unbalanced angle bracket',
    async (headerName) => {
      const mailboxes = 'Tom <3 Jerry <tom@x.com>, Alice <alice@example.com>'
      const plan = (await preparePersistPlan(
        textMessage({
          id: 'nested-display-name-group',
          from: headerName === 'From' ? mailboxes : ME,
          to: headerName === 'To' ? [ME, mailboxes] : [ME],
          cc: headerName === 'Cc' ? [mailboxes] : [],
        }),
        ctx,
      )) as MessagePersistPlan

      const participants = ['alice@example.com', 'tom@x.com']
      expect(plan.identity.participants).toEqual(participants)
      expect(plan.identity.participantHash).toBe(calculateParticipantHash(participants))
      expect(plan.identity.type).toBe('group')
      if (headerName !== 'From') {
        const recipientEmails = plan.participants
          .filter((p) => p.kind === headerName.toLowerCase() && p.email !== ME)
          .map((p) => p.email)
          .sort()
        expect(recipientEmails).toEqual(participants)
      }
    },
  )

  it('marks own sent mail isFromMe and resolves reply-from', async () => {
    const plan = (await preparePersistPlan(
      textMessage({
        id: 'm1',
        from: `Me <${ME}>`,
        to: ['bob@example.com'],
        labelIds: ['SENT'],
      }),
      ctx,
    )) as MessagePersistPlan
    expect(plan.message.isFromMe).toBe(1)
    expect(plan.message.replyFromAddress).toBe(ME)
    expect(plan.message.deliveredToAddress).toBe(ME)
    expect(plan.reactivateArchived).toBe(true)
  })

  it('intersects labels with knownLabelIds, but treats an empty set as lookup failure', async () => {
    const msg = textMessage({ id: 'm1', labelIds: ['INBOX', 'UNREAD', 'Label_77'] })
    const scoped = (await preparePersistPlan(msg, {
      ...ctx,
      knownLabelIds: new Set(['INBOX', 'UNREAD']),
    })) as MessagePersistPlan
    expect(scoped.message.labelIds).toEqual(['INBOX', 'UNREAD'])

    const failedLookup = (await preparePersistPlan(msg, {
      ...ctx,
      knownLabelIds: new Set(),
    })) as MessagePersistPlan
    expect(failedLookup.message.labelIds).toEqual(['INBOX', 'UNREAD', 'Label_77'])
  })
})

describe('preparePersist fan-out', () => {
  /** A message whose text/html body is oversized, so parsing must fetch it. */
  function largeBodyMessage(id: string): GmailMessage {
    return {
      id,
      threadId: `t_${id}`,
      labelIds: ['INBOX'],
      internalDate: String(NOW),
      payload: {
        partId: '',
        mimeType: 'text/html',
        headers: [
          { name: 'From', value: 'alice@example.com' },
          { name: 'To', value: ME },
          { name: 'Subject', value: 'Big' },
        ],
        body: { size: 5_000_000, attachmentId: `att_${id}` },
      },
    }
  }

  it('turns a failed large-body fetch into a retryable plan', async () => {
    const plan = await preparePersistPlan(largeBodyMessage('m1'), {
      ...ctx,
      fetchLargeBody: () => Promise.reject(new Error('offline')),
    })

    expect(plan).toEqual({ kind: 'retryableFailure', id: 'm1' })
  })

  it('bounds concurrent large-body fetches instead of fanning out over the whole page', async () => {
    // The message-GET tier is bounded at FETCH_CONCURRENCY, but parsing opens a
    // SECOND network tier (attachments.get for oversized bodies). An unbounded
    // Promise.all over a 500-message page puts 500 of those in flight at once —
    // an instant 429 wall plus hundreds of simultaneous multi-MB buffers, and
    // fetchLargeBodyContent swallows the resulting errors, so the messages
    // persist with empty bodies and no repair path.
    const messages = Array.from({ length: 40 }, (_, i) => largeBodyMessage(`m${i}`))
    let inFlight = 0
    let maxInFlight = 0
    let calls = 0

    const plans = await preparePersist(messages, {
      ...ctx,
      fetchLargeBody: async () => {
        inFlight += 1
        calls += 1
        maxInFlight = Math.max(maxInFlight, inFlight)
        await new Promise((resolve) => setTimeout(resolve, 1))
        inFlight -= 1
        return b64url('<html><body>big</body></html>')
      },
    })

    expect(calls).toBe(messages.length)
    expect(maxInFlight).toBeLessThanOrEqual(PREPARE_CONCURRENCY)
    expect(maxInFlight).toBeGreaterThan(1)
    // Input order is still preserved despite the sliding window.
    expect(plans.map((p) => (p.kind === 'message' ? p.message.id : p.id))).toEqual(
      messages.map((m) => m.id),
    )
  })
})

describe('applyPersist — creation and routing', () => {
  it('merges messages with the same participant set across Gmail threads into one conversation', async () => {
    await persistMessages([
      textMessage({
        id: 'm1',
        threadId: 'tA',
        from: 'alice@example.com',
        internalDate: NOW - 2000,
      }),
      textMessage({
        id: 'm2',
        threadId: 'tB',
        from: 'alice@example.com',
        internalDate: NOW - 1000,
      }),
    ])

    const conversations = await db.conversations.toArray()
    expect(conversations).toHaveLength(1)
    const messages = await db.messages.toArray()
    expect(messages).toHaveLength(2)
    expect(new Set(messages.map((m) => m.conversationId))).toEqual(new Set([conversations[0]!.id]))
  })

  it('seeds the sole first message idempotently (unread count 1, not 2)', async () => {
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] }),
    ])
    const conversation = (await db.conversations.toArray())[0]!
    expect(conversation.inboxUnreadCount).toBe(1)
    expect(conversation.hasInbox).toBe(1)
    expect(conversation.lastMessageDate).toBeGreaterThan(0)
    expect(conversation.snippet).not.toBe('')
  })

  it('increments the unread count for subsequent messages', async () => {
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', internalDate: NOW - 2000 }),
      textMessage({ id: 'm2', from: 'alice@example.com', internalDate: NOW - 1000 }),
    ])
    const conversation = (await db.conversations.toArray())[0]!
    expect(conversation.inboxUnreadCount).toBe(2)
  })

  it('persists body, participants, people, and attachments with the message', async () => {
    const msg = textMessage({
      id: 'm1',
      from: 'Alice Smith <alice@example.com>',
      body: 'hello',
    })
    msg.payload = {
      partId: '',
      mimeType: 'multipart/mixed',
      headers: msg.payload!.headers!,
      parts: [
        { partId: '0', mimeType: 'text/html', body: { data: 'PGI-aGk8L2I-' } },
        {
          partId: '1',
          mimeType: 'application/pdf',
          filename: 'doc.pdf',
          body: { attachmentId: 'ATT123', size: 999 },
        },
      ],
    }
    await persistMessages([msg])

    const stored = (await db.messages.toArray())[0]!
    expect(stored.hasHtmlBody).toBe(1)
    expect(stored.hasAttachments).toBe(1)
    expect((await db.bodies.get('m1'))?.html).toBe('<b>hi</b>')

    const participants = await db.msgParticipants.where('messageId').equals('m1').toArray()
    expect(participants.map((p) => p.kind).sort()).toEqual(['from', 'to'])
    expect((await db.people.get('alice@example.com'))?.displayName).toBe('Alice Smith')

    const attachments = await db.attachments.where('messageId').equals('m1').toArray()
    expect(attachments).toHaveLength(1)
    expect(attachments[0]!.id).toBe('m1:1')
    expect(attachments[0]!.gmailAttachmentId).toBe('ATT123')
    expect(attachments[0]!.state).toBe('queued')
  })

  it('recreates the conversation shell when it is deleted between resolve and apply', async () => {
    const plans = await preparePersist(
      [textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] })],
      ctx,
    )
    // Simulate rollbackFailedSend deleting the freshly resolved conversation
    // in the gap between resolution and the apply transaction.
    const result = await applyPersist(db, plans, NOW, {
      afterResolve: async (conversationId) => {
        if (conversationId === null) return
        await db.conversations.delete(conversationId)
        await db.convoParticipants.where('conversationId').equals(conversationId).delete()
      },
    })

    // The message must NOT be orphaned: a shell exists under its
    // conversationId with seeded indicators and participants.
    const message = await db.messages.get('m1')
    expect(message).toBeDefined()
    const conversation = await db.conversations.get(message!.conversationId)
    expect(conversation).toBeDefined()
    expect(conversation!.inboxUnreadCount).toBe(1)
    expect(conversation!.hasInbox).toBe(1)
    expect(conversation!.snippet).not.toBe('')
    const participants = await db.convoParticipants
      .where('conversationId')
      .equals(message!.conversationId)
      .toArray()
    expect(participants.map((p) => p.email)).toEqual(['alice@example.com'])
    expect(result.persistedMessageIds.has('m1')).toBe(true)
  })

  it('deletes the local copy when a message moved to an excluded mailbox, and never inserts it', async () => {
    await persistMessages([textMessage({ id: 'm1', from: 'alice@example.com' })])
    expect(await db.messages.get('m1')).toBeDefined()

    const result = await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['TRASH'] }),
      textMessage({ id: 'm2', from: 'alice@example.com', labelIds: ['SPAM'] }),
    ])
    expect(await db.messages.get('m1')).toBeUndefined()
    expect(await db.messages.get('m2')).toBeUndefined()
    expect(await db.bodies.get('m1')).toBeUndefined()
    expect(result.deletedMessageIds).toEqual(new Set(['m1']))
  })
})

describe('applyPersist — inline attachment scoping', () => {
  /** Two different messages carrying byte-identical inline parts (recurring
   * newsletter/signature images: same partId, filename, mime, cid, size). */
  function inlineImageMessage(id: string, internalDate: number) {
    const msg = textMessage({ id, from: 'alice@example.com', internalDate })
    msg.payload = {
      partId: '',
      mimeType: 'multipart/related',
      headers: msg.payload!.headers!,
      parts: [
        { partId: '0', mimeType: 'text/html', body: { data: b64url('<b>hi</b>') } },
        {
          partId: '0.1',
          mimeType: 'image/png',
          filename: '',
          headers: [{ name: 'Content-ID', value: '<logo@x>' }],
          body: { data: b64url('PNGDATA'), size: 7 },
        },
      ],
    }
    return msg
  }

  it('keys inline attachment rows per message so identical parts never collide', async () => {
    await persistMessages([
      inlineImageMessage('m1', NOW - 2000),
      inlineImageMessage('m2', NOW - 1000),
    ])

    const rows1 = await db.attachments.where('messageId').equals('m1').toArray()
    const rows2 = await db.attachments.where('messageId').equals('m2').toArray()
    // Old content-only ids collided globally: persisting m2 re-parented m1's
    // row, leaving m1 with no attachment and a broken cid: lookup.
    expect(rows1).toHaveLength(1)
    expect(rows2).toHaveLength(1)
    expect(rows1[0]!.id).not.toBe(rows2[0]!.id)
    expect(await db.blobs.get(rows1[0]!.id)).toBeDefined()
    expect(await db.blobs.get(rows2[0]!.id)).toBeDefined()

    // Trashing m2 cascades only its own attachment + blob; m1's inline bytes
    // survive (they are not refetchable: gmailAttachmentId is '').
    await persistMessages([
      textMessage({ id: 'm2', from: 'alice@example.com', labelIds: ['TRASH'] }),
    ])
    expect(await db.attachments.get(rows1[0]!.id)).toBeDefined()
    expect(await db.blobs.get(rows1[0]!.id)).toBeDefined()
    expect(await db.attachments.get(rows2[0]!.id)).toBeUndefined()
    expect(await db.blobs.get(rows2[0]!.id)).toBeUndefined()
  })

  it('suppresses an unrecoverable inline row on quota failure and repairs it on re-sync', async () => {
    const quotaError = new DOMException('quota', 'QuotaExceededError')
    const put = vi.spyOn(db.blobs, 'put').mockRejectedValue(quotaError)
    const message = inlineImageMessage('m1', NOW - 2000)

    const first = await persistMessages([message])

    expect(put).toHaveBeenCalled()
    expect(first.retryableMessageIds).toEqual(new Set(['m1']))
    expect((await db.messages.get('m1'))?.hasAttachments).toBe(0)
    expect(await db.attachments.where('messageId').equals('m1').count()).toBe(0)
    expect(await db.blobs.count()).toBe(0)

    put.mockRestore()
    const second = await persistMessages([message])
    expect(second.retryableMessageIds).toEqual(new Set())
    const repaired = await db.attachments.where('messageId').equals('m1').toArray()
    expect(repaired).toHaveLength(1)
    expect(repaired[0]!.state).toBe('downloaded')
    expect(await db.blobs.get(repaired[0]!.id)).toBeDefined()
    expect((await db.messages.get('m1'))?.hasAttachments).toBe(1)
  })
})

describe('applyPersist — updating existing messages', () => {
  it('preserves non-empty previews when the incoming payload has none', async () => {
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', body: 'Original body text' }),
    ])
    const before = (await db.messages.get('m1'))!
    expect(before.cleanedSnippet).toBe('Original body text')

    await persistMessages([textMessage({ id: 'm1', from: 'alice@example.com', noBody: true })])
    const after = (await db.messages.get('m1'))!
    expect(after.cleanedSnippet).toBe('Original body text')
    expect(after.bodyText).toBe('Original body text')
  })

  it('skips label/unread writes while localModifiedAt is fresh, applies when stale', async () => {
    await persistMessages([textMessage({ id: 'm1', from: 'alice@example.com' })])

    // Local mark-read 5 minutes ago.
    await db.messages.update('m1', {
      isUnread: 0,
      labelIds: ['INBOX'],
      localModifiedAt: NOW - 5 * 60 * 1000,
    })
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] }),
    ])
    let row = (await db.messages.get('m1'))!
    expect(row.isUnread).toBe(0)
    expect(row.labelIds).toEqual(['INBOX'])

    // 40 minutes ago: stale — the server state wins again.
    await db.messages.update('m1', { localModifiedAt: NOW - 40 * 60 * 1000 })
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', labelIds: ['INBOX', 'UNREAD'] }),
    ])
    row = (await db.messages.get('m1'))!
    expect(row.isUnread).toBe(1)
    expect(row.labelIds).toEqual(['INBOX', 'UNREAD'])
  })

  it('keeps the ±1 fast-path arithmetic consistent when read state changes server-side', async () => {
    await persistMessages([
      textMessage({ id: 'm1', from: 'alice@example.com', internalDate: NOW - 2000 }),
      textMessage({ id: 'm2', from: 'alice@example.com', internalDate: NOW - 1000 }),
    ])
    expect((await db.conversations.toArray())[0]!.inboxUnreadCount).toBe(2)

    // m1 read server-side.
    await persistMessages([
      textMessage({
        id: 'm1',
        from: 'alice@example.com',
        labelIds: ['INBOX'],
        internalDate: NOW - 2000,
      }),
    ])
    expect((await db.conversations.toArray())[0]!.inboxUnreadCount).toBe(1)
  })

  it('is idempotent: re-persisting the identical message changes nothing', async () => {
    const msg = textMessage({ id: 'm1', from: 'alice@example.com' })
    await persistMessages([msg])
    const before = await db.conversations.toArray()
    await persistMessages([msg])
    const after = await db.conversations.toArray()
    expect(after).toEqual(before)
    expect(await db.messages.count()).toBe(1)
  })
})

describe('adopting optimistic outbound attachments', () => {
  const PHOTO_BYTES = new Uint8Array([1, 2, 3, 4])

  /**
   * The store as it looks right after a successful send reconcile: the message
   * carries the Gmail id, and its attachment rows are still the local ones
   * (`local_<uuid>`, no gmailAttachmentId) whose blobs are the ONLY copy of
   * those bytes anywhere.
   */
  async function seedSentMessageWithLocalAttachment(
    overrides: Partial<AttachmentRow> = {},
  ): Promise<void> {
    await db.conversations.add(convoRow({ id: 'c1' }))
    await db.messages.add(
      msgRow({
        id: 'm1',
        conversationId: 'c1',
        senderEmail: ME,
        isFromMe: 1,
        labelIds: ['SENT'],
        hasAttachments: 1,
        sendState: 'sent',
      }),
    )
    await db.attachments.put({
      id: 'local_a1',
      messageId: 'm1',
      gmailAttachmentId: '',
      contentId: '',
      filename: 'photo.png',
      mimeType: 'image/png',
      byteSize: PHOTO_BYTES.length,
      width: 100,
      height: 50,
      state: 'uploaded',
      lastDownloadFailedAt: 0,
      ...overrides,
    })
    await db.blobs.put({
      key: overrides.id ?? 'local_a1',
      blob: storableBlob([PHOTO_BYTES], { type: 'image/png' }),
      byteSize: PHOTO_BYTES.length,
      lastAccessAt: NOW,
    })
  }

  /** The sent copy as Gmail hands it back, with a server-side attachment part. */
  function syncedSentCopy(options: { filename?: string; size?: number } = {}): GmailMessage {
    const msg = textMessage({ id: 'm1', from: ME, labelIds: ['SENT'] })
    msg.payload = {
      partId: '',
      mimeType: 'multipart/mixed',
      headers: msg.payload!.headers!,
      parts: [
        { partId: '0', mimeType: 'text/plain', body: { size: 4, data: b64url('body') } },
        {
          partId: '1',
          mimeType: 'image/png',
          filename: options.filename ?? 'photo.png',
          body: { attachmentId: 'ATT1', size: options.size ?? PHOTO_BYTES.length },
        },
      ],
    }
    return msg
  }

  /** The same sent copy when Gmail embeds the small attachment bytes inline. */
  function inlineSyncedSentCopy(): GmailMessage {
    const msg = syncedSentCopy()
    msg.payload!.parts![1]!.body = { data: b64url('ABCD'), size: PHOTO_BYTES.length }
    return msg
  }

  it('adopts the local row into the server identity instead of duplicating it', async () => {
    await seedSentMessageWithLocalAttachment()

    await persistMessages([syncedSentCopy()])

    const rows = await db.attachments.where('messageId').equals('m1').toArray()
    expect(rows).toHaveLength(1)
    const row = rows[0]!
    expect(row.id).toBe('m1:1')
    expect(row.gmailAttachmentId).toBe('ATT1')
    // The bytes are already here, so nothing needs downloading.
    expect(row.state).toBe('downloaded')
    // Dimensions were measured at pick time; Gmail's payload carries none.
    expect(row.width).toBe(100)
    expect(row.height).toBe(50)

    // The blob moved with the row — the old key is gone, not orphaned.
    expect(await db.blobs.get('local_a1')).toBeUndefined()
    expect((await db.blobs.get('m1:1'))?.byteSize).toBe(PHOTO_BYTES.length)
  })

  it('retains usable local bytes when inline server-identity adoption exceeds quota', async () => {
    await seedSentMessageWithLocalAttachment()
    const put = vi
      .spyOn(db.blobs, 'put')
      .mockRejectedValueOnce(new DOMException('quota', 'QuotaExceededError'))

    const failed = await persistMessages([inlineSyncedSentCopy()])

    expect(failed.retryableMessageIds).toEqual(new Set(['m1']))
    expect(
      (await db.attachments.where('messageId').equals('m1').toArray()).map((row) => row.id),
    ).toEqual(['local_a1'])
    expect(await db.blobs.get('local_a1')).toBeDefined()
    expect(await db.blobs.get('m1:1')).toBeUndefined()

    put.mockRestore()
    const recovered = await persistMessages([inlineSyncedSentCopy()])
    const adopted = (await db.attachments.where('messageId').equals('m1').first())!
    expect(recovered.retryableMessageIds).toEqual(new Set())
    expect(adopted.id).not.toBe('local_a1')
    expect(adopted.state).toBe('downloaded')
    expect(adopted.gmailAttachmentId).toBe('')
    expect(await db.blobs.get('local_a1')).toBeUndefined()
    expect(await db.blobs.get(adopted.id)).toBeDefined()
  })

  it('matches on Content-ID when both sides carry one', async () => {
    await seedSentMessageWithLocalAttachment({ contentId: 'logo@x', filename: 'renamed.png' })
    const msg = syncedSentCopy({ filename: 'server-name.png', size: 999 })
    msg.payload!.parts![1]!.headers = [{ name: 'Content-ID', value: '<logo@x>' }]

    await persistMessages([msg])

    const rows = await db.attachments.where('messageId').equals('m1').toArray()
    expect(rows).toHaveLength(1)
    expect(rows[0]!.id).toBe('m1:1')
    expect(rows[0]!.filename).toBe('server-name.png')
  })

  it('inserts a second row when nothing matches, keeping the local bytes', async () => {
    await seedSentMessageWithLocalAttachment()

    // A different file: same name, different size.
    await persistMessages([syncedSentCopy({ size: 4096 })])

    const rows = await db.attachments.where('messageId').equals('m1').toArray()
    expect(rows.map((row) => row.id).sort()).toEqual(['local_a1', 'm1:1'])
    expect(await db.blobs.get('local_a1')).toBeDefined()
  })

  it('is idempotent: a second sync of the same copy adds nothing', async () => {
    await seedSentMessageWithLocalAttachment()

    await persistMessages([syncedSentCopy()])
    await persistMessages([syncedSentCopy()])

    const rows = await db.attachments.where('messageId').equals('m1').toArray()
    expect(rows.map((row) => row.id)).toEqual(['m1:1'])
    expect(await db.blobs.count()).toBe(1)
  })
})

describe('calendar invites', () => {
  const ICS = [
    'BEGIN:VCALENDAR',
    'PRODID:-//Google Inc//Google Calendar 70.9054//EN',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'DTSTART:20260318T180000Z',
    'DTEND:20260318T190000Z',
    'ORGANIZER;CN=Alice Smith:mailto:alice@example.com',
    'SUMMARY:Design sync',
    'LOCATION:Conference Room B',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n')

  const INVITE_BODY = 'Design sync\nWhen\nWed Mar 18, 2026 2:00pm\nWhere\nRoom B\n'

  function inviteMessage(id: string, ics = ICS): GmailMessage {
    return {
      id,
      threadId: `thread_${id}`,
      labelIds: ['INBOX', 'UNREAD'],
      internalDate: String(NOW - 60 * 60 * 1000),
      snippet: 'You have been invited to the following event.',
      payload: {
        partId: '',
        mimeType: 'multipart/alternative',
        headers: [
          { name: 'From', value: 'Alice Smith <alice@example.com>' },
          { name: 'To', value: ME },
          { name: 'Subject', value: 'Invitation: Design sync' },
          { name: 'Message-ID', value: `<${id}@mail.example.com>` },
        ],
        parts: [
          {
            partId: '0',
            mimeType: 'text/plain',
            body: { data: b64url(INVITE_BODY) },
          },
          {
            partId: '1',
            mimeType: 'text/calendar; charset="UTF-8"; method=REQUEST',
            body: { data: b64url(ics) },
          },
        ],
      },
    }
  }

  it('persists the flag and the extracted event', async () => {
    await persistMessages([inviteMessage('m1')])
    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(1)
    expect(stored?.calendarEvent?.title).toBe('Design sync')
    expect(stored?.calendarEvent?.startMs).toBe(Date.UTC(2026, 2, 18, 18, 0, 0))
    expect(stored?.calendarEvent?.organizer).toBe('Alice Smith')
    expect(stored?.calendarEvent?.source).toBe('Google Calendar')
  })

  it('leaves ordinary mail unflagged and event-less', async () => {
    await persistMessages([textMessage({ id: 'm1', body: 'Lunch at noon?' })])
    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(0)
    expect(stored?.calendarEvent).toBeUndefined()
  })

  it('keeps the stored event when a re-fetch carries no calendar part', async () => {
    await persistMessages([inviteMessage('m1')])
    // Re-fetched with the .ics only reachable as a server attachment: still an
    // invite by the text signals, but nothing inline to re-extract from.
    await persistMessages([
      textMessage({ id: 'm1', subject: 'Invitation: Design sync', body: INVITE_BODY }),
    ])
    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(1)
    expect(stored?.calendarEvent?.title).toBe('Design sync')
  })

  it('replaces the stored event when the organizer updates the invite', async () => {
    await persistMessages([inviteMessage('m1')])
    await persistMessages([
      inviteMessage(
        'm1',
        ICS.replace('SUMMARY:Design sync', 'SUMMARY:Design sync (moved)').replace(
          'DTSTART:20260318T180000Z',
          'DTSTART:20260319T180000Z',
        ),
      ),
    ])
    const stored = await db.messages.get('m1')
    expect(stored?.calendarEvent?.title).toBe('Design sync (moved)')
    expect(stored?.calendarEvent?.startMs).toBe(Date.UTC(2026, 2, 19, 18, 0, 0))
  })

  it('clears the flag when the message stops looking like an invite', async () => {
    await persistMessages([inviteMessage('m1')])
    await persistMessages([textMessage({ id: 'm1', subject: 'Lunch?', body: 'Free at noon?' })])
    expect((await db.messages.get('m1'))?.isCalendarInvite).toBe(0)
  })

  it('drops the stored event when the flag genuinely clears', async () => {
    // calendarEvent is only meaningful while the flag is set (db/types); a
    // real content transition takes both away together.
    await persistMessages([inviteMessage('m1')])
    await persistMessages([textMessage({ id: 'm1', subject: 'Lunch?', body: 'Free at noon?' })])
    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(0)
    expect(stored?.calendarEvent).toBeUndefined()
  })

  it('keeps the flag and event across a blind re-fetch that saw no content', async () => {
    await persistMessages([inviteMessage('m1')])
    // Metadata-only payload / an oversized body whose fetch failed: empty
    // body, no calendar part. The parse has lost the signals, not the invite —
    // clearing here would strand or destroy a real stored event.
    await persistMessages([textMessage({ id: 'm1', subject: 'Design sync', body: '' })])
    const stored = await db.messages.get('m1')
    expect(stored?.isCalendarInvite).toBe(1)
    expect(stored?.calendarEvent?.title).toBe('Design sync')
  })
})

describe('mergeExistingMessage guard window', () => {
  it('uses the 30-minute boundary exactly', async () => {
    const plan = (await preparePersistPlan(
      textMessage({ id: 'm1', labelIds: ['INBOX', 'UNREAD'] }),
      ctx,
    )) as MessagePersistPlan
    const base = (await preparePersistPlan(
      textMessage({ id: 'm1', labelIds: ['INBOX'] }),
      ctx,
    )) as MessagePersistPlan
    const existing = {
      ...base.message,
      conversationId: 'c1',
      isUnread: 0 as const,
      localModifiedAt: NOW - LOCAL_MODIFICATION_MAX_AGE_MS + 1,
    }
    // One ms inside the window: guarded.
    expect(mergeExistingMessage(existing, plan, NOW).isUnread).toBe(0)
    // Exactly at the boundary: stale.
    const atBoundary = { ...existing, localModifiedAt: NOW - LOCAL_MODIFICATION_MAX_AGE_MS }
    expect(mergeExistingMessage(atBoundary, plan, NOW).isUnread).toBe(1)
  })
})
