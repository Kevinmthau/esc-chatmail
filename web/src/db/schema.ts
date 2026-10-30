import Dexie, { type Table } from 'dexie'
import { sha256Hex } from '@/identity/hash'
import type {
  AbandonedMessageRow,
  AccountRow,
  AttachmentRow,
  BlobRow,
  BodyRow,
  ConvoParticipantRow,
  ConversationRow,
  LabelRow,
  MessageRow,
  MsgParticipantRow,
  OutboundSendRow,
  PendingActionRow,
  PersonRow,
  SyncStateRow,
} from './types'

export class ChatmailDB extends Dexie {
  accounts!: Table<AccountRow, string>
  syncState!: Table<SyncStateRow, string>
  conversations!: Table<ConversationRow, string>
  messages!: Table<MessageRow, string>
  bodies!: Table<BodyRow, string>
  people!: Table<PersonRow, string>
  convoParticipants!: Table<ConvoParticipantRow, [string, string]>
  msgParticipants!: Table<MsgParticipantRow, number>
  labels!: Table<LabelRow, string>
  attachments!: Table<AttachmentRow, string>
  blobs!: Table<BlobRow, string>
  pendingActions!: Table<PendingActionRow, number>
  outboundSends!: Table<OutboundSendRow, string>
  abandonedMessages!: Table<AbandonedMessageRow, string>

  constructor(name: string) {
    super(name)
    this.version(1).stores({
      accounts: 'email',
      syncState: 'key',
      conversations:
        'id, &keyHash, participantHash, ' +
        '[participantHash+isArchived+lastMessageDate], ' +
        '[isArchived+pinned+lastMessageDate]',
      messages:
        'id, [conversationId+internalDate], gmThreadId, rfcMessageId, ' +
        '*labelIds, internalDate, [conversationId+isUnread]',
      bodies: 'messageId',
      people: 'email',
      convoParticipants: '[conversationId+email], conversationId',
      msgParticipants: '++pk, messageId, [messageId+kind]',
      labels: 'id',
      attachments: 'id, messageId, contentId, [messageId+contentId]',
      blobs: 'key, lastAccessAt',
      pendingActions: '++id, [status+createdAt], status',
      outboundSends: 'id, status',
      abandonedMessages: 'gmailMessageId, retryCount',
    })

    // v2 adds MessageRow.isCalendarInvite. Purely additive — no index changes,
    // so the store declaration is unchanged and the upgrade only backfills the
    // flag to 0 on rows written before the column existed. Nothing is
    // recomputed here: detection needs the MIME payload, which is not stored,
    // so pre-v2 invites light up on their next sync instead.
    this.version(2)
      .stores({})
      .upgrade((tx) =>
        tx
          .table<MessageRow>('messages')
          .toCollection()
          .modify((message) => {
            message.isCalendarInvite = 0
          }),
      )
  }
}

/**
 * Every account database on this origin starts with this; `listAccountDBNames`
 * enumerates by it, so the sign-out sweep finds databases of accounts this
 * boot never opened (a previous account left behind by a verified switch).
 */
export const ACCOUNT_DB_NAME_PREFIX = 'escmail_'

/** One database per account so sign-out is a clean `db.delete()`. */
export function dbNameForAccount(email: string): string {
  return `${ACCOUNT_DB_NAME_PREFIX}${sha256Hex(email.trim().toLowerCase()).slice(0, 16)}`
}

let current: ChatmailDB | null = null

export function openDBForAccount(email: string): ChatmailDB {
  if (current && current.name === dbNameForAccount(email) && current.isOpen()) {
    return current
  }
  current?.close()
  current = new ChatmailDB(dbNameForAccount(email))
  return current
}

/** The currently open database. Throws when no account DB has been opened. */
export function getDB(): ChatmailDB {
  if (!current) throw new Error('No account database open')
  return current
}

/** The current account database, or null while signed out / between accounts. */
export function getDBIfAvailable(): ChatmailDB | null {
  return current
}

export function setDBForTests(db: ChatmailDB | null): void {
  current = db
}

export async function deleteDBForAccount(email: string): Promise<void> {
  await deleteAccountDB(dbNameForAccount(email))
}

async function deleteAccountDB(name: string): Promise<void> {
  if (current?.name === name) {
    current.close()
    current = null
  }
  await Dexie.delete(name)
}

/**
 * Names of every account database on this origin. Dexie.getDatabaseNames()
 * reads `indexedDB.databases()` where it exists and otherwise the registry
 * Dexie keeps for its own databases, so this also lists databases opened in
 * a previous boot or by another tab. The open database is included even when
 * the enumeration lacks it: Dexie creates a database on its first query, so
 * one opened and never queried is not on disk yet but is still the one
 * getDB() hands out.
 */
export async function listAccountDBNames(): Promise<string[]> {
  let names: string[] = []
  try {
    names = (await Dexie.getDatabaseNames()).filter((name) =>
      name.startsWith(ACCOUNT_DB_NAME_PREFIX),
    )
  } catch {
    // Enumeration unsupported or refused: the open database is still known.
  }
  const open = current?.name
  if (open !== undefined && open.startsWith(ACCOUNT_DB_NAME_PREFIX) && !names.includes(open)) {
    names.push(open)
  }
  return names
}

/**
 * Deletes the named account databases, the open one included. The sign-out
 * sweep passes `listAccountDBNames()`: an account switch keeps the previous
 * account's database (it belongs to that account, and the switch is not its
 * sign-out), so by sign-out more than the current account can be on disk,
 * and deleting only the current one left the other mailbox readable to the
 * next person on the machine.
 */
export async function deleteAccountDBs(names: readonly string[]): Promise<void> {
  for (const name of names) await deleteAccountDB(name)
}
