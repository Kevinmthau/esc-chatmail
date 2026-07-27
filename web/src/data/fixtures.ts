// Demo-mode fixture data: ~12 conversations (mixed unread/pinned/group, one
// newsletter with an HTML body) with timestamps spread over several weeks, so
// the app is fully explorable without an OAuth client. Seeding is idempotent
// via the syncState key 'fixturesSeeded'.
//
// Dexie tx rule: the whole plan (including hashes/uuids) is computed BEFORE
// the single rw transaction that applies it.

import type { ChatmailDB } from '@/db/schema'
import type {
  AccountRow,
  BodyRow,
  ConversationRow,
  ConvoParticipantRow,
  MessageRow,
  PersonRow,
} from '@/db/types'
import {
  makeConversationIdentity,
  makeRecipientParticipantSetIdentity,
} from '@/identity/participantSet'

export const FIXTURES_SEEDED_KEY = 'fixturesSeeded'

const DEMO_EMAIL = 'demo@example.com'

const MINUTE = 60 * 1000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

interface FixtureMessage {
  /** Sender email, or the literal 'me' for outgoing demo-account messages. */
  from: string
  text: string
  /** Age of the message relative to the seed time. */
  ageMs: number
  unread?: boolean
  subject?: string
  /** Newsletter message: gets an HTML body row + isNewsletter flag. */
  html?: string
}

interface FixtureConversation {
  /** Participants (excluding the demo account): [email, displayName]. */
  people: Array<[string, string]>
  pinned?: boolean
  messages: FixtureMessage[]
}

const NEWSLETTER_HTML =
  '<html><body style="margin:0;font-family:Arial,sans-serif;background:#f4f4f7">' +
  '<div style="max-width:600px;margin:0 auto;background:#ffffff;padding:24px">' +
  '<h1 style="color:#4f46e5;font-size:22px">The Daily Digest</h1>' +
  '<p style="color:#374151">Five things worth reading this morning, curated for you.</p>' +
  '<h2 style="font-size:16px">1. Browsers keep getting faster</h2>' +
  '<p style="color:#6b7280">A deep dive into this year&#39;s engine benchmarks.</p>' +
  '<h2 style="font-size:16px">2. The quiet rise of local-first apps</h2>' +
  '<p style="color:#6b7280">Why your next favorite tool might not need a backend.</p>' +
  '<a href="https://example.com/digest" style="color:#4f46e5">Read the full issue</a>' +
  '</div></body></html>'

/** ~12 conversations, newest first; ages spread from minutes to weeks. */
function fixtureSpecs(): FixtureConversation[] {
  return [
    {
      people: [['alice@example.com', 'Alice Chen']],
      pinned: true,
      messages: [
        { from: 'me', text: 'Want to grab lunch Thursday?', ageMs: 2 * HOUR },
        {
          from: 'alice@example.com',
          text: 'Yes! Noon at the usual spot?',
          ageMs: 40 * MINUTE,
          unread: true,
        },
        {
          from: 'alice@example.com',
          text: 'Sounds good, see you then!',
          ageMs: 10 * MINUTE,
          unread: true,
        },
      ],
    },
    {
      people: [['ben@example.com', 'Ben Ortiz']],
      messages: [
        {
          from: 'ben@example.com',
          text: 'Sent over the contract draft — take a look when you can.',
          ageMs: 5 * HOUR,
        },
        { from: 'me', text: 'Got it, will review tonight.', ageMs: 4 * HOUR },
      ],
    },
    {
      people: [
        ['alice@example.com', 'Alice Chen'],
        ['ben@example.com', 'Ben Ortiz'],
        ['chloe@example.com', 'Chloe Park'],
      ],
      messages: [
        {
          from: 'chloe@example.com',
          text: 'Cabin is booked for the 14th!',
          ageMs: 1 * DAY + 6 * HOUR,
        },
        { from: 'me', text: 'Amazing. I can drive one carload.', ageMs: 1 * DAY + 5 * HOUR },
        {
          from: 'alice@example.com',
          text: 'I will bring the board games.',
          ageMs: 1 * DAY + 2 * HOUR,
          unread: true,
        },
      ],
    },
    {
      people: [['newsletter@dailydigest.example', 'The Daily Digest']],
      messages: [
        {
          from: 'newsletter@dailydigest.example',
          text: 'Five things worth reading this morning.',
          ageMs: 2 * DAY + 3 * HOUR,
          unread: true,
          subject: 'The Daily Digest — Tuesday edition',
          html: NEWSLETTER_HTML,
        },
      ],
    },
    {
      people: [['dana@example.com', 'Dana West']],
      messages: [
        {
          from: 'dana@example.com',
          text: 'Photos from the weekend are up, link inside.',
          ageMs: 3 * DAY,
        },
        { from: 'me', text: 'These are great — thanks for sharing!', ageMs: 3 * DAY - 2 * HOUR },
      ],
    },
    {
      people: [['eli@example.com', 'Eli Stone']],
      messages: [
        { from: 'me', text: 'Did the parts arrive yet?', ageMs: 4 * DAY + HOUR },
        {
          from: 'eli@example.com',
          text: 'Yep, everything is here. Assembly this weekend?',
          ageMs: 4 * DAY,
        },
      ],
    },
    {
      people: [['fatima@example.com', 'Fatima Khan']],
      pinned: true,
      messages: [
        {
          from: 'fatima@example.com',
          text: 'Reminder: book club moved to Thursday at 7.',
          ageMs: 5 * DAY,
        },
      ],
    },
    {
      people: [
        ['dana@example.com', 'Dana West'],
        ['eli@example.com', 'Eli Stone'],
      ],
      messages: [
        {
          from: 'eli@example.com',
          text: 'Splitting the dinner bill three ways — $28 each.',
          ageMs: 6 * DAY,
        },
        { from: 'me', text: 'Just sent mine.', ageMs: 6 * DAY - HOUR },
      ],
    },
    {
      people: [['grace@example.com', 'Grace Liu']],
      messages: [
        {
          from: 'grace@example.com',
          text: 'The garden plot application went through!',
          ageMs: 10 * DAY,
          unread: true,
        },
      ],
    },
    {
      people: [['hank@example.com', 'Hank Miller']],
      messages: [
        { from: 'me', text: 'Happy birthday, Hank!', ageMs: 2 * 7 * DAY },
        {
          from: 'hank@example.com',
          text: 'Thanks so much! Party details coming soon.',
          ageMs: 2 * 7 * DAY - 3 * HOUR,
        },
      ],
    },
    {
      people: [['ivy@example.com', 'Ivy Nguyen']],
      messages: [
        {
          from: 'ivy@example.com',
          text: 'Found that book you mentioned at the used store.',
          ageMs: 3 * 7 * DAY,
        },
      ],
    },
    {
      people: [['jorge@example.com', 'Jorge Ruiz']],
      messages: [
        {
          from: 'jorge@example.com',
          text: 'Course syllabus attached — week one is intro material.',
          ageMs: 4 * 7 * DAY,
        },
        { from: 'me', text: 'Perfect, see you in class.', ageMs: 4 * 7 * DAY - 5 * HOUR },
      ],
    },
  ]
}

interface FixturePlan {
  account: AccountRow
  conversations: ConversationRow[]
  messages: MessageRow[]
  bodies: BodyRow[]
  people: PersonRow[]
  convoParticipants: ConvoParticipantRow[]
}

function buildFixturePlan(now: number): FixturePlan {
  const myAliases: ReadonlySet<string> = new Set([DEMO_EMAIL])
  const plan: FixturePlan = {
    account: {
      email: DEMO_EMAIL,
      historyId: 'demo',
      aliases: [DEMO_EMAIL],
      sendAsAliases: [
        {
          email: DEMO_EMAIL,
          displayName: 'Demo',
          isDefault: true,
          isPrimary: true,
          verificationStatus: 'accepted',
        },
      ],
      installTs: now - 60 * DAY,
      sendAsRefreshedAt: now,
    },
    conversations: [],
    messages: [],
    bodies: [],
    people: [],
    convoParticipants: [],
  }

  const peopleByEmail = new Map<string, string>()

  fixtureSpecs().forEach((spec, convoIndex) => {
    const emails = spec.people.map(([email]) => email)
    const displayNames = Object.fromEntries(spec.people)
    for (const [email, name] of spec.people) peopleByEmail.set(email, name)

    const setIdentity = makeRecipientParticipantSetIdentity(emails, myAliases)
    if (setIdentity === null) return
    const identity = makeConversationIdentity(setIdentity, displayNames)
    const conversationId = `demo-c-${convoIndex + 1}`

    const messages = spec.messages.map((msg, msgIndex): MessageRow => {
      const isFromMe = msg.from === 'me'
      const senderEmail = isFromMe ? DEMO_EMAIL : msg.from
      const unread = msg.unread === true && !isFromMe
      const labelIds = isFromMe ? ['SENT'] : unread ? ['INBOX', 'UNREAD'] : ['INBOX']
      const internalDate = now - msg.ageMs
      return {
        id: `demo-m-${convoIndex + 1}-${msgIndex + 1}`,
        conversationId,
        gmThreadId: `demo-t-${convoIndex + 1}`,
        rfcMessageId: `<demo-m-${convoIndex + 1}-${msgIndex + 1}@demo.example>`,
        references: '',
        internalDate,
        subject: msg.subject ?? '',
        snippet: msg.text,
        cleanedSnippet: msg.text,
        chatPreviewText: msg.text,
        bodyText: msg.text,
        hasHtmlBody: msg.html !== undefined ? 1 : 0,
        senderEmail,
        senderName: isFromMe ? 'Demo' : (peopleByEmail.get(senderEmail) ?? senderEmail),
        deliveredToAddress: isFromMe ? '' : DEMO_EMAIL,
        replyFromAddress: DEMO_EMAIL,
        isFromMe: isFromMe ? 1 : 0,
        isUnread: unread ? 1 : 0,
        isNewsletter: msg.html !== undefined ? 1 : 0,
        hasAttachments: 0,
        labelIds,
        localModifiedAt: 0,
      }
    })

    for (const [index, msg] of spec.messages.entries()) {
      if (msg.html !== undefined) {
        const row = messages[index]
        if (row !== undefined) plan.bodies.push({ messageId: row.id, html: msg.html })
      }
    }

    const inboxMessages = messages.filter((m) => m.labelIds.includes('INBOX'))
    const newest = messages.reduce((a, b) => (b.internalDate > a.internalDate ? b : a))
    const newestInboxDate = inboxMessages.reduce((max, m) => Math.max(max, m.internalDate), 0)
    const unreadCount = inboxMessages.filter((m) => m.isUnread === 1).length

    plan.conversations.push({
      id: conversationId,
      keyHash: identity.keyHash,
      participantHash: identity.participantHash,
      type: identity.type,
      displayName: spec.people.map(([, name]) => name).join(', '),
      snippet: newest.chatPreviewText,
      lastMessageDate: newest.internalDate,
      latestInboxDate: newestInboxDate,
      hasInbox: inboxMessages.length > 0 ? 1 : 0,
      inboxUnreadCount: unreadCount,
      pinned: spec.pinned === true ? 1 : 0,
      muted: 0,
      archivedAt: 0,
      isArchived: 0,
      createdAt: messages.reduce((min, m) => Math.min(min, m.internalDate), now) - MINUTE,
    })
    plan.messages.push(...messages)
    for (const email of setIdentity.participants) {
      plan.convoParticipants.push({ conversationId, email, role: 'normal' })
    }
  })

  plan.people = [...peopleByEmail.entries()].map(([email, displayName]) => ({
    email,
    displayName,
  }))

  return plan
}

/**
 * Seeds the demo fixtures exactly once per database.
 * @returns true when this call performed the seed, false when already seeded.
 */
export async function seedFixturesOnce(db: ChatmailDB, now: number = Date.now()): Promise<boolean> {
  const plan = buildFixturePlan(now)
  return db.transaction(
    'rw',
    [
      db.syncState,
      db.accounts,
      db.conversations,
      db.messages,
      db.bodies,
      db.people,
      db.convoParticipants,
    ],
    async () => {
      const seeded = await db.syncState.get(FIXTURES_SEEDED_KEY)
      if (seeded !== undefined) return false
      await db.accounts.put(plan.account)
      await db.conversations.bulkAdd(plan.conversations)
      await db.messages.bulkAdd(plan.messages)
      await db.bodies.bulkAdd(plan.bodies)
      await db.people.bulkPut(plan.people)
      await db.convoParticipants.bulkPut(plan.convoParticipants)
      await db.syncState.put({ key: FIXTURES_SEEDED_KEY, value: now })
      return true
    },
  )
}
