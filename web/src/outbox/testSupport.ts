// Shared harness for the outbox test suites: fresh per-test ChatmailDB and
// row factories. Test-only module (imported exclusively from *.test.ts).

import { ChatmailDB } from '@/db/schema'
import type { AccountRow, ConversationRow, MessageRow } from '@/db/types'

export const ME = 'me@example.com'
export const NOW = 1_800_000_000_000

export function makeTestDb(): ChatmailDB {
  return new ChatmailDB(`test_outbox_${crypto.randomUUID()}`)
}

export async function seedAccount(
  db: ChatmailDB,
  overrides: Partial<AccountRow> = {},
): Promise<AccountRow> {
  const row: AccountRow = {
    email: ME,
    historyId: 'h1',
    aliases: [ME],
    sendAsAliases: [
      {
        email: ME,
        displayName: '',
        isDefault: true,
        isPrimary: true,
        verificationStatus: 'accepted',
      },
    ],
    installTs: NOW - 24 * 60 * 60 * 1000,
    sendAsRefreshedAt: NOW,
    ...overrides,
  }
  await db.accounts.put(row)
  return row
}

export function convoRow(
  overrides: Partial<ConversationRow> & Pick<ConversationRow, 'id'>,
): ConversationRow {
  return {
    keyHash: `kh_${overrides.id}`,
    participantHash: `ph_${overrides.id}`,
    type: 'oneToOne',
    displayName: 'Bob',
    snippet: '',
    lastMessageDate: NOW - 60 * 60 * 1000,
    latestInboxDate: NOW - 60 * 60 * 1000,
    hasInbox: 1,
    inboxUnreadCount: 0,
    pinned: 0,
    muted: 0,
    archivedAt: 0,
    isArchived: 0,
    createdAt: NOW - 2 * 60 * 60 * 1000,
    ...overrides,
  }
}

export function msgRow(
  overrides: Partial<MessageRow> & Pick<MessageRow, 'id' | 'conversationId'>,
): MessageRow {
  return {
    gmThreadId: 't1',
    rfcMessageId: `<${overrides.id}@mail.example.com>`,
    references: '',
    internalDate: NOW - 60 * 60 * 1000,
    subject: 'Hello',
    snippet: 'Body',
    cleanedSnippet: 'Body',
    chatPreviewText: 'Body',
    bodyText: 'Body',
    hasHtmlBody: 0,
    senderEmail: 'bob@example.com',
    senderName: 'Bob',
    deliveredToAddress: ME,
    replyFromAddress: ME,
    isFromMe: 0,
    isUnread: 0,
    isNewsletter: 0,
    isCalendarInvite: 0,
    hasAttachments: 0,
    labelIds: ['INBOX'],
    localModifiedAt: 0,
    ...overrides,
  }
}
