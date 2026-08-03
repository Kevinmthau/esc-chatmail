// Shared harness for the sync test suites: fresh per-test ChatmailDB, a
// scriptable GmailSyncApi stub, Gmail message builders, and deterministic
// SyncDeps. Test-only module (imported exclusively from *.test.ts).

import { ChatmailDB } from '@/db/schema'
import type { AccountRow } from '@/db/types'
import { GmailApiError } from '@/gmail/errors'
import type {
  AttachmentResponse,
  GmailHeader,
  GmailLabel,
  GmailMessage,
  GmailProfile,
  HistoryListResponse,
  MessagesListResponse,
  SendAsEntry,
} from '@/gmail/types'
import type { ListHistoryParams, ListMessagesParams } from '@/gmail/endpoints'
import type { GmailSyncApi, SyncDeps } from './deps'

export const ME = 'me@example.com'
export const NOW = 1_800_000_000_000

export function makeTestDb(): ChatmailDB {
  return new ChatmailDB(`test_sync_${crypto.randomUUID()}`)
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

export function b64url(text: string): string {
  return btoa(unescape(encodeURIComponent(text)))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/u, '')
}

export interface TextMessageOptions {
  id: string
  threadId?: string
  from?: string
  to?: string[]
  cc?: string[]
  bcc?: string[]
  subject?: string
  body?: string
  snippet?: string
  labelIds?: string[]
  internalDate?: number
  extraHeaders?: GmailHeader[]
  /** Omit the body part entirely (previews come out empty). */
  noBody?: boolean
}

/** Builds a plain-text Gmail API message fixture. */
export function textMessage(options: TextMessageOptions): GmailMessage {
  const headers: GmailHeader[] = [
    { name: 'From', value: options.from ?? 'alice@example.com' },
    { name: 'To', value: (options.to ?? [ME]).join(', ') },
    { name: 'Subject', value: options.subject ?? 'Hello' },
    { name: 'Message-ID', value: `<${options.id}@mail.example.com>` },
    ...(options.cc !== undefined && options.cc.length > 0
      ? [{ name: 'Cc', value: options.cc.join(', ') }]
      : []),
    ...(options.bcc !== undefined && options.bcc.length > 0
      ? [{ name: 'Bcc', value: options.bcc.join(', ') }]
      : []),
    ...(options.extraHeaders ?? []),
  ]

  const message: GmailMessage = {
    id: options.id,
    threadId: options.threadId ?? `thread_${options.id}`,
    labelIds: options.labelIds ?? ['INBOX', 'UNREAD'],
    internalDate: String(options.internalDate ?? NOW - 60 * 60 * 1000),
    payload: {
      partId: '',
      mimeType: 'text/plain',
      headers,
      ...(options.noBody === true
        ? {}
        : { body: { size: 10, data: b64url(options.body ?? `Body of ${options.id}`) } }),
    },
  }
  if (options.snippet !== undefined) message.snippet = options.snippet
  return message
}

export class StubGmailApi implements GmailSyncApi {
  profile: GmailProfile = { emailAddress: ME, historyId: 'h1' }
  sendAs: SendAsEntry[] = [
    { sendAsEmail: ME, isPrimary: true, isDefault: true, verificationStatus: 'accepted' },
  ]
  labels: GmailLabel[] = [
    { id: 'INBOX', name: 'INBOX' },
    { id: 'UNREAD', name: 'UNREAD' },
    { id: 'SENT', name: 'SENT' },
    { id: 'IMPORTANT', name: 'IMPORTANT' },
  ]

  messages = new Map<string, GmailMessage>()
  /** listMessages responses served in order; null → always empty. */
  listPages: MessagesListResponse[] | null = null
  listCalls: ListMessagesParams[] = []

  historyPages: HistoryListResponse[] = []
  /** When set, every listHistory call goes through this instead of the queue. */
  historyFactory: ((params: ListHistoryParams) => HistoryListResponse) | null = null
  historyError: Error | null = null
  historyCalls: ListHistoryParams[] = []

  /** id → error factory (called with the 1-based attempt for that id). */
  getMessageErrors = new Map<string, (attempt: number) => Error | null>()
  getMessageCalls: string[] = []
  private attemptsByMessageId = new Map<string, number>()
  attachmentResponses = new Map<string, AttachmentResponse>()
  /** `${messageId}:${attachmentId}` → error factory. */
  getAttachmentErrors = new Map<string, (attempt: number) => Error | null>()
  getAttachmentCalls: string[] = []
  private attemptsByAttachmentKey = new Map<string, number>()

  getProfile(): Promise<GmailProfile> {
    return Promise.resolve(this.profile)
  }

  listSendAs(): Promise<SendAsEntry[]> {
    return Promise.resolve(this.sendAs)
  }

  listLabels(): Promise<GmailLabel[]> {
    return Promise.resolve(this.labels)
  }

  listMessages(params: ListMessagesParams): Promise<MessagesListResponse> {
    this.listCalls.push(params)
    if (this.listPages === null) return Promise.resolve({})
    return Promise.resolve(this.listPages.shift() ?? {})
  }

  getMessage(id: string, format: 'full' | 'metadata'): Promise<GmailMessage> {
    this.getMessageCalls.push(`${id}:${format}`)
    const attempt = (this.attemptsByMessageId.get(id) ?? 0) + 1
    this.attemptsByMessageId.set(id, attempt)

    const errorFactory = this.getMessageErrors.get(id)
    if (errorFactory !== undefined) {
      const error = errorFactory(attempt)
      if (error !== null) return Promise.reject(error)
    }

    const message = this.messages.get(id)
    if (message === undefined) {
      return Promise.reject(new GmailApiError(404, 'notFound', `Message ${id} not found`))
    }
    return Promise.resolve(message)
  }

  listHistory(params: ListHistoryParams): Promise<HistoryListResponse> {
    this.historyCalls.push(params)
    if (this.historyError !== null) return Promise.reject(this.historyError)
    if (this.historyFactory !== null) return Promise.resolve(this.historyFactory(params))
    return Promise.resolve(this.historyPages.shift() ?? { historyId: params.startHistoryId })
  }

  getAttachment(messageId: string, attachmentId: string): Promise<AttachmentResponse> {
    const key = `${messageId}:${attachmentId}`
    this.getAttachmentCalls.push(key)
    const attempt = (this.attemptsByAttachmentKey.get(key) ?? 0) + 1
    this.attemptsByAttachmentKey.set(key, attempt)
    const error = this.getAttachmentErrors.get(key)?.(attempt)
    if (error !== undefined && error !== null) return Promise.reject(error)
    return Promise.resolve(this.attachmentResponses.get(key) ?? { size: 0, data: '' })
  }
}

export interface TestDepsOptions {
  now?: () => number
  hooks?: SyncDeps['hooks']
}

/** Deterministic SyncDeps: fixed clock, instant sleep, pinned rng. */
export function testDeps(
  db: ChatmailDB,
  api: StubGmailApi,
  options: TestDepsOptions = {},
): SyncDeps {
  const deps: SyncDeps = {
    db,
    api,
    accountEmail: ME,
    now: options.now ?? (() => NOW),
    sleep: () => Promise.resolve(),
    random: () => 0,
  }
  if (options.hooks !== undefined) deps.hooks = options.hooks
  return deps
}
