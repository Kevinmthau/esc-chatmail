import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import corpusJson from '@fixtures/golden_message_corpus.json'
import { ChatmailDB } from '@/db/schema'
import type { ConversationRow, MessageRow } from '@/db/types'
import {
  applyArchiveState,
  applyRollup,
  conversationPreview,
  makeRollup,
  normalizedForwardSubject,
  rollupConversation,
} from './rollup'

interface ConversationListSnippetCase {
  id: string
  conversationSnippet?: string | null
  latestMessageSnippet?: string | null
  latestMessageCleanedSnippet?: string | null
  expected: string
  notes?: string
}

const corpus = corpusJson as unknown as {
  conversationListSnippetCases: ConversationListSnippetCase[]
}

function messageRow(overrides: Partial<MessageRow>): MessageRow {
  return {
    id: crypto.randomUUID(),
    conversationId: 'c1',
    gmThreadId: 't1',
    rfcMessageId: '',
    references: '',
    internalDate: 1000,
    subject: '',
    snippet: '',
    cleanedSnippet: '',
    chatPreviewText: '',
    bodyText: '',
    hasHtmlBody: 0,
    senderEmail: 'other@example.com',
    senderName: '',
    deliveredToAddress: '',
    replyFromAddress: '',
    isFromMe: 0,
    isUnread: 0,
    isNewsletter: 0,
    hasAttachments: 0,
    labelIds: [],
    localModifiedAt: 0,
    ...overrides,
  }
}

function conversationRow(overrides: Partial<ConversationRow> = {}): ConversationRow {
  return {
    id: 'c1',
    keyHash: crypto.randomUUID(),
    participantHash: 'hash',
    type: 'oneToOne',
    displayName: 'Other',
    snippet: '',
    lastMessageDate: 0,
    latestInboxDate: 0,
    hasInbox: 0,
    inboxUnreadCount: 0,
    pinned: 0,
    muted: 0,
    archivedAt: 0,
    isArchived: 0,
    createdAt: 0,
    ...overrides,
  }
}

describe('golden corpus: conversationListSnippetCases', () => {
  // Mirrors the iOS test: the list row reads the rollup-owned
  // conversation.snippet field and never re-derives it from message rows at
  // view time.
  it.each(corpus.conversationListSnippetCases)('$id', async (scenario) => {
    const db = new ChatmailDB(`test-${crypto.randomUUID()}`)
    try {
      const conversation = conversationRow({
        snippet: scenario.conversationSnippet ?? '',
        lastMessageDate: Date.now(),
      })
      await db.conversations.add(conversation)

      if (scenario.latestMessageSnippet != null || scenario.latestMessageCleanedSnippet != null) {
        await db.messages.add(
          messageRow({
            conversationId: conversation.id,
            internalDate: Date.now(),
            snippet: scenario.latestMessageSnippet ?? '',
            cleanedSnippet: scenario.latestMessageCleanedSnippet ?? '',
          }),
        )
      }

      const row = await db.conversations.get(conversation.id)
      expect(row?.snippet, scenario.notes).toBe(scenario.expected)
    } finally {
      await db.delete()
    }
  })
})

describe('normalizedForwardSubject', () => {
  it('strips single and stacked fwd/fw prefixes case-insensitively', () => {
    expect(normalizedForwardSubject('Fwd: Meeting notes')).toBe('Meeting notes')
    expect(normalizedForwardSubject('FW: fwd:  Fw: Budget')).toBe('Budget')
    expect(normalizedForwardSubject('  fwd : spaced prefix')).toBe('spaced prefix')
  })

  it('falls back to the original subject when stripping leaves nothing', () => {
    expect(normalizedForwardSubject('Fwd:')).toBe('Fwd:')
    expect(normalizedForwardSubject('fw: ')).toBe('fw: ')
  })
})

describe('conversationPreview', () => {
  it('renders forwarded subjects as Fwd: "<subject minus prefixes>"', () => {
    const m = messageRow({ subject: 'Fwd: Fw: Meeting notes', cleanedSnippet: 'body text' })
    expect(conversationPreview(m)).toBe('Fwd: "Meeting notes"')
  })

  it('forward detection only looks at the subject prefix', () => {
    const m = messageRow({
      subject: 'Re: Fwd: nope',
      cleanedSnippet: 'Begin forwarded message body',
    })
    expect(conversationPreview(m)).toBe('Begin forwarded message body')
  })

  it('uses the subject for newsletters', () => {
    const m = messageRow({
      subject: 'Weekly Digest',
      isNewsletter: 1,
      cleanedSnippet: 'article blurb',
    })
    expect(conversationPreview(m)).toBe('Weekly Digest')
  })

  it('a newsletter without a subject falls back to the text ladder', () => {
    const m = messageRow({ subject: '  ', isNewsletter: 1, cleanedSnippet: 'article blurb' })
    expect(conversationPreview(m)).toBe('article blurb')
  })

  it('prefers cleanedSnippet, then compacted chatPreviewText, then snippet, then subject', () => {
    expect(
      conversationPreview(
        messageRow({
          cleanedSnippet: 'cleaned',
          chatPreviewText: 'chat',
          snippet: 'raw',
          subject: 'subj',
        }),
      ),
    ).toBe('cleaned')
    expect(
      conversationPreview(
        messageRow({
          cleanedSnippet: ' ',
          chatPreviewText: '  hello\n  world  ',
          snippet: 'raw',
          subject: 'subj',
        }),
      ),
    ).toBe('hello world')
    expect(
      conversationPreview(messageRow({ chatPreviewText: '', snippet: ' raw ', subject: 'subj' })),
    ).toBe('raw')
    expect(conversationPreview(messageRow({ subject: ' subj ' }))).toBe('subj')
  })

  it('returns the empty string when nothing has content', () => {
    expect(conversationPreview(messageRow({}))).toBe('')
  })
})

describe('makeRollup', () => {
  it('returns the empty rollup for no messages', () => {
    expect(makeRollup([])).toEqual({
      lastMessageDate: 0,
      snippet: '',
      hasInbox: false,
      inboxUnreadCount: 0,
      latestInboxDate: 0,
      hasSentOrFromMe: false,
      hasReceived: false,
      latestVisibleMessageIsOutgoing: false,
      isSentOnlyConversation: false,
    })
  })

  it('SPAM/DRAFT/TRASH messages are invisible to lastMessageDate and snippet', () => {
    const rollup = makeRollup([
      messageRow({ internalDate: 100, cleanedSnippet: 'visible', labelIds: [] }),
      messageRow({ internalDate: 200, cleanedSnippet: 'spam', labelIds: ['SPAM'] }),
      messageRow({ internalDate: 300, cleanedSnippet: 'draft', labelIds: ['DRAFT'] }),
      messageRow({ internalDate: 400, cleanedSnippet: 'trash', labelIds: ['TRASH'] }),
    ])
    expect(rollup.lastMessageDate).toBe(100)
    expect(rollup.snippet).toBe('visible')
  })

  it('snippet comes from the NEWEST visible message with a non-empty preview', () => {
    const rollup = makeRollup([
      messageRow({ internalDate: 100, cleanedSnippet: 'older preview' }),
      messageRow({ internalDate: 300, cleanedSnippet: '' }),
      messageRow({ internalDate: 200, cleanedSnippet: 'newest preview' }),
    ])
    expect(rollup.lastMessageDate).toBe(300)
    expect(rollup.snippet).toBe('newest preview')
  })

  it('counts unread only for INBOX messages and tracks latestInboxDate', () => {
    const rollup = makeRollup([
      messageRow({ internalDate: 100, labelIds: ['INBOX'], isUnread: 1 }),
      messageRow({ internalDate: 200, labelIds: ['INBOX'], isUnread: 0 }),
      messageRow({ internalDate: 300, labelIds: [], isUnread: 1 }),
      messageRow({ internalDate: 150, labelIds: ['INBOX', 'UNREAD'], isUnread: 1 }),
    ])
    expect(rollup.hasInbox).toBe(true)
    expect(rollup.inboxUnreadCount).toBe(2)
    expect(rollup.latestInboxDate).toBe(200)
  })

  it('an INBOX message hidden from visibility (e.g. TRASH) still counts for inbox state', () => {
    // Matches iOS: the INBOX scan is independent of the visibility filter.
    const rollup = makeRollup([
      messageRow({ internalDate: 100, labelIds: ['INBOX', 'TRASH'], isUnread: 1 }),
    ])
    expect(rollup.hasInbox).toBe(true)
    expect(rollup.inboxUnreadCount).toBe(1)
    expect(rollup.latestInboxDate).toBe(100)
    expect(rollup.lastMessageDate).toBe(0)
  })

  it('hasSentOrFromMe via isFromMe or SENT label; hasReceived via any not-from-me', () => {
    expect(makeRollup([messageRow({ isFromMe: 1 })])).toMatchObject({
      hasSentOrFromMe: true,
      hasReceived: false,
    })
    expect(makeRollup([messageRow({ labelIds: ['SENT'] })])).toMatchObject({
      hasSentOrFromMe: true,
      hasReceived: true,
    })
    expect(makeRollup([messageRow({})])).toMatchObject({
      hasSentOrFromMe: false,
      hasReceived: true,
    })
  })

  it('latestVisibleMessageIsOutgoing tracks the newest visible message only', () => {
    const outgoingLatest = makeRollup([
      messageRow({ internalDate: 100 }),
      messageRow({ internalDate: 200, isFromMe: 1 }),
    ])
    expect(outgoingLatest.latestVisibleMessageIsOutgoing).toBe(true)

    const incomingLatest = makeRollup([
      messageRow({ internalDate: 100, isFromMe: 1 }),
      messageRow({ internalDate: 200 }),
    ])
    expect(incomingLatest.latestVisibleMessageIsOutgoing).toBe(false)

    // The visibility filter applies: a newer TRASH outgoing message does not count.
    const trashedOutgoing = makeRollup([
      messageRow({ internalDate: 100 }),
      messageRow({ internalDate: 200, isFromMe: 1, labelIds: ['TRASH'] }),
    ])
    expect(trashedOutgoing.latestVisibleMessageIsOutgoing).toBe(false)
  })

  it('isSentOnlyConversation = sent-or-from-me and no received and no inbox', () => {
    expect(makeRollup([messageRow({ isFromMe: 1 })]).isSentOnlyConversation).toBe(true)
    expect(makeRollup([messageRow({ isFromMe: 1 }), messageRow({})]).isSentOnlyConversation).toBe(
      false,
    )
    expect(
      makeRollup([messageRow({ isFromMe: 1, labelIds: ['INBOX'] })]).isSentOnlyConversation,
    ).toBe(false)
  })
})

describe('applyRollup / archive state machine', () => {
  const inboxRollup = makeRollup([
    messageRow({ internalDate: 500, labelIds: ['INBOX'], isUnread: 1, cleanedSnippet: 'hi' }),
  ])
  const sentOnlyRollup = makeRollup([
    messageRow({ internalDate: 500, isFromMe: 1, cleanedSnippet: 'sent' }),
  ])
  // Sent-only where the outgoing message is excluded from visibility (trashed):
  // isSentOnlyConversation is true but latestVisibleMessageIsOutgoing is false,
  // so this exercises the sent-only branch on its own.
  const sentOnlyTrashedRollup = makeRollup([
    messageRow({ internalDate: 500, isFromMe: 1, labelIds: ['TRASH'], cleanedSnippet: 'sent' }),
  ])
  const latestOutgoingRollup = makeRollup([
    messageRow({ internalDate: 100, cleanedSnippet: 'in' }),
    messageRow({ internalDate: 200, isFromMe: 1, cleanedSnippet: 'out' }),
  ])
  const receivedNoInboxRollup = makeRollup([
    messageRow({ internalDate: 500, cleanedSnippet: 'archived elsewhere' }),
  ])
  const emptyRollup = makeRollup([])

  it('writes the derived fields onto the row', () => {
    const updated = applyRollup(conversationRow(), inboxRollup, 1000)
    expect(updated).toMatchObject({
      lastMessageDate: 500,
      snippet: 'hi',
      hasInbox: 1,
      inboxUnreadCount: 1,
      latestInboxDate: 500,
    })
  })

  it('clears the snippet when no visible message remains', () => {
    const conv = conversationRow({ snippet: 'stale', lastMessageDate: 400 })
    const updated = applyRollup(conv, emptyRollup, 1000)
    expect(updated.snippet).toBe('')
    expect(updated.lastMessageDate).toBe(0)
  })

  interface ArchiveCase {
    name: string
    rollup: ReturnType<typeof makeRollup>
    before: Partial<ConversationRow>
    after: { archivedAt: number; isArchived: 0 | 1 }
  }

  const cases: ArchiveCase[] = [
    {
      name: 'hasInbox unarchives an archived conversation',
      rollup: inboxRollup,
      before: { archivedAt: 123, isArchived: 1 },
      after: { archivedAt: 0, isArchived: 0 },
    },
    {
      name: 'hasInbox keeps an active conversation active',
      rollup: inboxRollup,
      before: {},
      after: { archivedAt: 0, isArchived: 0 },
    },
    {
      name: 'sent-only keeps an active conversation active',
      rollup: sentOnlyRollup,
      before: {},
      after: { archivedAt: 0, isArchived: 0 },
    },
    {
      name: 'sent-only does NOT reactivate an archived conversation',
      rollup: sentOnlyRollup,
      before: { archivedAt: 123, isArchived: 1 },
      after: { archivedAt: 123, isArchived: 1 },
    },
    {
      name: 'sent-only with no visible messages keeps an active conversation active',
      rollup: sentOnlyTrashedRollup,
      before: {},
      after: { archivedAt: 0, isArchived: 0 },
    },
    {
      name: 'sent-only with no visible messages does NOT reactivate an archived conversation',
      rollup: sentOnlyTrashedRollup,
      before: { archivedAt: 123, isArchived: 1 },
      after: { archivedAt: 123, isArchived: 1 },
    },
    {
      name: 'latest visible outgoing keeps an active conversation active',
      rollup: latestOutgoingRollup,
      before: {},
      after: { archivedAt: 0, isArchived: 0 },
    },
    {
      name: 'latest visible outgoing does NOT reactivate an archived conversation',
      rollup: latestOutgoingRollup,
      before: { archivedAt: 123, isArchived: 1 },
      after: { archivedAt: 123, isArchived: 1 },
    },
    {
      name: 'received-without-inbox auto-archives an active conversation at now',
      rollup: receivedNoInboxRollup,
      before: {},
      after: { archivedAt: 1000, isArchived: 1 },
    },
    {
      name: 'received-without-inbox preserves an existing archivedAt',
      rollup: receivedNoInboxRollup,
      before: { archivedAt: 123, isArchived: 1 },
      after: { archivedAt: 123, isArchived: 1 },
    },
    {
      name: 'empty message set auto-archives an active conversation',
      rollup: emptyRollup,
      before: {},
      after: { archivedAt: 1000, isArchived: 1 },
    },
  ]

  it.each(cases)('$name', ({ rollup, before, after }) => {
    const updated = applyArchiveState(conversationRow(before), rollup, 1000)
    expect({ archivedAt: updated.archivedAt, isArchived: updated.isArchived }).toEqual(after)
  })

  it('does not mutate the input row', () => {
    const conv = conversationRow({ archivedAt: 123, isArchived: 1 })
    applyRollup(conv, inboxRollup, 1000)
    expect(conv.archivedAt).toBe(123)
    expect(conv.hasInbox).toBe(0)
  })

  it('applyRollup is idempotent: applying twice equals applying once', () => {
    for (const rollup of [
      inboxRollup,
      sentOnlyRollup,
      sentOnlyTrashedRollup,
      latestOutgoingRollup,
      receivedNoInboxRollup,
      emptyRollup,
    ]) {
      for (const before of [
        conversationRow(),
        conversationRow({ archivedAt: 123, isArchived: 1 }),
      ]) {
        const once = applyRollup(before, rollup, 1000)
        // A different `now` on the second pass must not move archivedAt.
        const twice = applyRollup(once, rollup, 2000)
        expect(twice).toEqual(once)
      }
    }
  })
})

describe('rollupConversation', () => {
  let db: ChatmailDB

  beforeEach(() => {
    db = new ChatmailDB(`test-${crypto.randomUUID()}`)
  })

  afterEach(async () => {
    await db.delete()
  })

  it('recomputes and persists rollup fields for one conversation', async () => {
    await db.conversations.add(conversationRow({ id: 'c1', snippet: 'stale' }))
    await db.messages.bulkAdd([
      messageRow({
        conversationId: 'c1',
        internalDate: 100,
        labelIds: ['INBOX'],
        isUnread: 1,
        cleanedSnippet: 'first',
      }),
      messageRow({
        conversationId: 'c1',
        internalDate: 200,
        labelIds: ['INBOX'],
        isUnread: 1,
        cleanedSnippet: 'second',
      }),
      // Another conversation's message must not leak in.
      messageRow({
        conversationId: 'c2',
        internalDate: 900,
        labelIds: ['INBOX'],
        isUnread: 1,
        cleanedSnippet: 'other',
      }),
    ])

    await rollupConversation(db, 'c1', 5000)

    const row = await db.conversations.get('c1')
    expect(row).toMatchObject({
      lastMessageDate: 200,
      snippet: 'second',
      hasInbox: 1,
      inboxUnreadCount: 2,
      latestInboxDate: 200,
      archivedAt: 0,
      isArchived: 0,
    })
  })

  it('auto-archives when the messages leave the inbox', async () => {
    await db.conversations.add(conversationRow({ id: 'c1' }))
    await db.messages.add(
      messageRow({ conversationId: 'c1', internalDate: 100, cleanedSnippet: 'archived away' }),
    )

    await rollupConversation(db, 'c1', 7777)

    const row = await db.conversations.get('c1')
    expect(row?.archivedAt).toBe(7777)
    expect(row?.isArchived).toBe(1)
  })

  it('is a no-op for a missing conversation', async () => {
    await expect(rollupConversation(db, 'missing', 1000)).resolves.toBeUndefined()
  })

  it('nests inside an existing rw transaction spanning messages+conversations', async () => {
    await db.conversations.add(conversationRow({ id: 'c1' }))

    await db.transaction('rw', db.messages, db.conversations, async () => {
      await db.messages.add(
        messageRow({
          conversationId: 'c1',
          internalDate: 100,
          labelIds: ['INBOX'],
          isUnread: 1,
          cleanedSnippet: 'inside tx',
        }),
      )
      await rollupConversation(db, 'c1', 1000)
    })

    const row = await db.conversations.get('c1')
    expect(row).toMatchObject({ snippet: 'inside tx', hasInbox: 1, inboxUnreadCount: 1 })
  })
})
