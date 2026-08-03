// Dependency bundle for the sync orchestrators.
//
// Everything the sync engine touches over the network goes through
// `GmailSyncApi` so tests can inject MSW-backed endpoints or plain stubs, and
// timing/randomness are injectable for deterministic retry tests.

import type { ChatmailDB } from '@/db/schema'
import type { TokenBroker } from '@/gmail/gmailFetch'
import {
  getAttachment,
  getMessage,
  getProfile,
  listHistory,
  listLabels,
  listMessages,
  listSendAs,
  type EndpointOptions,
  type ListHistoryParams,
  type ListMessagesParams,
} from '@/gmail/endpoints'
import type {
  AttachmentResponse,
  GmailLabel,
  GmailMessage,
  GmailProfile,
  HistoryListResponse,
  MessagesListResponse,
  SendAsEntry,
} from '@/gmail/types'

export interface GmailSyncApi {
  getProfile(): Promise<GmailProfile>
  listSendAs(): Promise<SendAsEntry[]>
  listLabels(): Promise<GmailLabel[]>
  listMessages(params: ListMessagesParams): Promise<MessagesListResponse>
  /**
   * Single-attempt message fetch: retry/backoff/classification is owned by
   * sync/fetch.ts (single retry owner, mirroring MessageFetcher's
   * `maxRetries: 1` contract with the iOS API client).
   */
  getMessage(id: string, format: 'full' | 'metadata'): Promise<GmailMessage>
  listHistory(params: ListHistoryParams): Promise<HistoryListResponse>
  getAttachment(messageId: string, attachmentId: string): Promise<AttachmentResponse>
}

/** Binds the real Gmail endpoints to a token broker. */
export function makeGmailSyncApi(broker: TokenBroker, options?: EndpointOptions): GmailSyncApi {
  return {
    getProfile: () => getProfile(broker, options),
    listSendAs: () => listSendAs(broker, options),
    listLabels: () => listLabels(broker, options),
    listMessages: (params) => listMessages(broker, params, options),
    getMessage: (id, format) => getMessage(broker, id, format, { ...options, maxAttempts: 1 }),
    listHistory: (params) => listHistory(broker, params, options),
    getAttachment: (messageId, attachmentId) =>
      getAttachment(broker, messageId, attachmentId, options),
  }
}

/** Test hooks fired at sync phase boundaries; throwing simulates a crash. */
export interface SyncHooks {
  onPhase?: (phase: string) => void | Promise<void>
}

export interface SyncDeps {
  db: ChatmailDB
  api: GmailSyncApi
  /** The account email keying the accounts row (the DB is per-account). */
  accountEmail: string
  now?: () => number
  sleep?: (ms: number) => Promise<void>
  random?: () => number
  hooks?: SyncHooks
}

export function depsNow(deps: SyncDeps): number {
  return (deps.now ?? Date.now)()
}

export function depsSleep(deps: SyncDeps): (ms: number) => Promise<void> {
  return deps.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)))
}

export function depsRandom(deps: SyncDeps): () => number {
  return deps.random ?? Math.random
}

/** Large-body fetcher for parseGmailMessage, backed by the attachments endpoint. */
export function makeFetchLargeBody(
  api: GmailSyncApi,
): (messageId: string, attachmentId: string) => Promise<string> {
  return async (messageId, attachmentId) => {
    const response = await api.getAttachment(messageId, attachmentId)
    return response.data
  }
}
