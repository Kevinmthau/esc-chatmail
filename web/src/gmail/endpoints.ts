// Typed Gmail v1 endpoints over the unified retry engine.
//
// Port of GmailAPIClient+Messages/+History/+Labels/+Attachments
// (esc-chatmail/Services/API/). Every endpoint takes the TokenBroker first
// and an optional trailing EndpointOptions for retry-knob injection (tests).

import { performRetryingRequest } from './client'
import type { RetryBehavior } from './client'
import { HistoryIdExpiredError } from './historyError'
import type { TokenBroker } from './gmailFetch'
import type {
  AttachmentResponse,
  GmailLabel,
  GmailMessage,
  GmailProfile,
  HistoryListResponse,
  LabelsListResponse,
  MessagesListResponse,
  SendAsEntry,
  SendAsResponse,
  SendMessageResponse,
} from './types'

/** Gmail batchModify accepts at most 1000 message ids per call. */
export const BATCH_MODIFY_CHUNK_SIZE = 1_000

/** Retry knobs callers/tests may override; never changes retransmission policy. */
export type EndpointOptions = Pick<RetryBehavior, 'maxAttempts' | 'sleep' | 'random' | 'fetchImpl'>

export interface ListMessagesParams {
  q?: string
  pageToken?: string
  /** Defaults to 100 (iOS parity). */
  maxResults?: number
}

export interface ListHistoryParams {
  startHistoryId: string
  pageToken?: string
}

export interface LabelChanges {
  addLabelIds?: string[]
  removeLabelIds?: string[]
}

export interface BatchModifyParams extends LabelChanges {
  ids: string[]
}

export interface SendMessageParams {
  /** base64url-encoded RFC 2822 message. */
  raw: string
  threadId?: string
}

export async function getProfile(
  broker: TokenBroker,
  options?: EndpointOptions,
): Promise<GmailProfile> {
  return getJson(broker, '/users/me/profile', options)
}

export async function listLabels(
  broker: TokenBroker,
  options?: EndpointOptions,
): Promise<GmailLabel[]> {
  const response = await getJson<LabelsListResponse>(broker, '/users/me/labels', options)
  return response.labels ?? []
}

export async function listSendAs(
  broker: TokenBroker,
  options?: EndpointOptions,
): Promise<SendAsEntry[]> {
  const response = await getJson<SendAsResponse>(broker, '/users/me/settings/sendAs', options)
  return response.sendAs ?? []
}

export async function listMessages(
  broker: TokenBroker,
  params: ListMessagesParams = {},
  options?: EndpointOptions,
): Promise<MessagesListResponse> {
  const query = new URLSearchParams({ maxResults: String(params.maxResults ?? 100) })
  if (params.pageToken !== undefined) query.set('pageToken', params.pageToken)
  if (params.q !== undefined) query.set('q', params.q)
  return getJson(broker, `/users/me/messages?${query.toString()}`, options)
}

export async function getMessage(
  broker: TokenBroker,
  id: string,
  format: 'full' | 'metadata',
  options?: EndpointOptions,
): Promise<GmailMessage> {
  const query = new URLSearchParams({ format })
  return getJson(
    broker,
    `/users/me/messages/${encodeURIComponent(id)}?${query.toString()}`,
    options,
  )
}

/**
 * Lists history since startHistoryId. A 404 means the historyId is expired
 * or invalid — surfaced as HistoryIdExpiredError so sync can run recovery
 * (iOS: GmailAPIClient+History.swift maps 404 → APIError.historyIdExpired).
 */
export async function listHistory(
  broker: TokenBroker,
  params: ListHistoryParams,
  options?: EndpointOptions,
): Promise<HistoryListResponse> {
  const query = new URLSearchParams({ startHistoryId: params.startHistoryId })
  if (params.pageToken !== undefined) query.set('pageToken', params.pageToken)
  const response = await performRetryingRequest(
    broker,
    `/users/me/history?${query.toString()}`,
    undefined,
    {
      ...options,
      allowsRetransmission: true,
      mapStatus: (status, error) =>
        status === 404 ? new HistoryIdExpiredError(error.message) : null,
    },
  )
  return (await response.json()) as HistoryListResponse
}

export async function modifyMessage(
  broker: TokenBroker,
  id: string,
  changes: LabelChanges,
  options?: EndpointOptions,
): Promise<GmailMessage> {
  const response = await performRetryingRequest(
    broker,
    `/users/me/messages/${encodeURIComponent(id)}/modify`,
    jsonPost(labelChangesBody(changes)),
    // Label modification is idempotent: safe to retransmit.
    { ...options, allowsRetransmission: true },
  )
  return (await response.json()) as GmailMessage
}

/** Batch-modifies labels, chunking at 1000 ids per call (Gmail API limit). */
export async function batchModify(
  broker: TokenBroker,
  params: BatchModifyParams,
  options?: EndpointOptions,
): Promise<void> {
  for (let start = 0; start < params.ids.length; start += BATCH_MODIFY_CHUNK_SIZE) {
    const chunk = params.ids.slice(start, start + BATCH_MODIFY_CHUNK_SIZE)
    await performRetryingRequest(
      broker,
      '/users/me/messages/batchModify',
      jsonPost({ ids: chunk, ...labelChangesBody(params) }),
      { ...options, allowsRetransmission: true },
    )
  }
}

/**
 * Sends a raw MIME message. Sending is not idempotent and Gmail has no
 * idempotency key: the request is NEVER retransmitted after an ambiguous
 * failure (5xx, network error) — the email could be delivered twice.
 */
export async function sendMessage(
  broker: TokenBroker,
  params: SendMessageParams,
  options?: EndpointOptions,
): Promise<SendMessageResponse> {
  const body: { raw: string; threadId?: string } = { raw: params.raw }
  if (params.threadId !== undefined) body.threadId = params.threadId
  const response = await performRetryingRequest(broker, '/users/me/messages/send', jsonPost(body), {
    ...options,
    allowsRetransmission: false,
  })
  return (await response.json()) as SendMessageResponse
}

export async function getAttachment(
  broker: TokenBroker,
  messageId: string,
  attachmentId: string,
  options?: EndpointOptions,
): Promise<AttachmentResponse> {
  const path = `/users/me/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`
  return getJson(broker, path, options)
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

async function getJson<T>(
  broker: TokenBroker,
  path: string,
  options?: EndpointOptions,
): Promise<T> {
  const response = await performRetryingRequest(broker, path, undefined, {
    ...options,
    allowsRetransmission: true,
  })
  return (await response.json()) as T
}

function jsonPost(body: unknown): RequestInit {
  return {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }
}

function labelChangesBody(changes: LabelChanges): LabelChanges {
  const body: LabelChanges = {}
  if (changes.addLabelIds !== undefined) body.addLabelIds = changes.addLabelIds
  if (changes.removeLabelIds !== undefined) body.removeLabelIds = changes.removeLabelIds
  return body
}
