// Bounded-concurrency message fetching with per-message retry and failure
// classification. Port of MessageFetcher.fetchWithBoundedConcurrency /
// fetchBatch (Services/Sync/MessageFetcher.swift), simplified per plan:
// concurrency 15 → 5, and the retry ladder lives here (the injected
// api.getMessage makes exactly one attempt per call).

import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from '@/gmail/errors'
import type { GmailMessage } from '@/gmail/types'
import { mapWithConcurrency } from './concurrency'
import type { GmailSyncApi } from './deps'

/**
 * `messages.get` costs 5 quota units against Gmail's 250 units/user/second
 * budget, so 8 in flight at typical latency sits at or above the throttle for
 * a whole backfill. 5 leaves headroom for the parallel large-body tier and the
 * user's other clients.
 */
export const FETCH_CONCURRENCY = 5
export const FETCH_MAX_ATTEMPTS = 3
export const FETCH_BASE_DELAY_MS = 500

export interface FetchFailure {
  id: string
  /**
   * true: auth/4xx/decode — retrying the same request cannot succeed.
   * false: 5xx/network/rate-limit exhaustion — may succeed on a later sync.
   */
  permanent: boolean
}

export interface BoundedFetchResult {
  /** Successfully fetched messages, sorted oldest-first (persistence order). */
  fetched: GmailMessage[]
  /** 404 — the message no longer exists server-side (dropped silently). */
  goneIds: string[]
  failed: FetchFailure[]
}

export interface FetchMessagesOptions {
  concurrency?: number
  /** Attempts per message (default 3). */
  maxAttempts?: number
  sleep?: (ms: number) => Promise<void>
  random?: () => number
}

type Classification = 'gone' | 'permanent' | 'retriable'

interface ClassifiedError {
  classification: Classification
  retryAfterSeconds: number | null
}

export function classifyFetchError(error: unknown): ClassifiedError {
  if (error instanceof RateLimitError) {
    return { classification: 'retriable', retryAfterSeconds: error.retryAfterSeconds }
  }
  if (error instanceof NetworkError) {
    return { classification: 'retriable', retryAfterSeconds: null }
  }
  if (error instanceof GmailApiError) {
    if (error.status === 404) return { classification: 'gone', retryAfterSeconds: null }
    if (error.status >= 500) return { classification: 'retriable', retryAfterSeconds: null }
    return { classification: 'permanent', retryAfterSeconds: null }
  }
  // AuthRequiredError, decode failures, unknown errors: permanent — retrying
  // the identical request cannot succeed (mirrors MessageFetcher's default).
  if (error instanceof AuthRequiredError) {
    return { classification: 'permanent', retryAfterSeconds: null }
  }
  return { classification: 'permanent', retryAfterSeconds: null }
}

/**
 * Retry delay for attempt `attempt` (1-based): 500ms/1s/2s exponential base,
 * a larger server Retry-After dominates, plus 0–25% jitter.
 */
export function fetchRetryDelayMs(
  attempt: number,
  retryAfterSeconds: number | null,
  random: () => number = Math.random,
): number {
  const synthetic = FETCH_BASE_DELAY_MS * 2 ** Math.max(0, attempt - 1)
  const base =
    retryAfterSeconds !== null && retryAfterSeconds > 0
      ? Math.max(synthetic, retryAfterSeconds * 1000)
      : synthetic
  return Math.round(base * (1 + random() * 0.25))
}

function chronological(messages: GmailMessage[]): GmailMessage[] {
  return [...messages].sort((a, b) => Number(a.internalDate ?? '0') - Number(b.internalDate ?? '0'))
}

/**
 * Fetches `ids` with bounded concurrency. Each id gets up to `maxAttempts`
 * attempts with backoff; failures are classified so the caller can gate
 * historyId advancement (permanent vs may-recover).
 */
export async function fetchMessagesBounded(
  api: Pick<GmailSyncApi, 'getMessage'>,
  ids: readonly string[],
  options: FetchMessagesOptions = {},
): Promise<BoundedFetchResult> {
  const concurrency = Math.max(1, options.concurrency ?? FETCH_CONCURRENCY)
  const maxAttempts = Math.max(1, options.maxAttempts ?? FETCH_MAX_ATTEMPTS)
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  const random = options.random ?? Math.random

  const fetched: GmailMessage[] = []
  const goneIds: string[] = []
  const failed: FetchFailure[] = []

  // Adaptive backpressure: the first 429 in a batch halves the in-flight width
  // for the remainder of it. Continuing at full width against a throttled
  // account only converts more messages into retry-ladder sleeps.
  let effectiveConcurrency = concurrency

  const fetchOne = async (id: string): Promise<void> => {
    for (let attempt = 1; ; attempt += 1) {
      try {
        const message = await api.getMessage(id, 'full')
        fetched.push(message)
        return
      } catch (error) {
        const { classification, retryAfterSeconds } = classifyFetchError(error)
        if (error instanceof RateLimitError) {
          effectiveConcurrency = Math.max(1, Math.floor(effectiveConcurrency / 2))
        }
        if (classification === 'gone') {
          goneIds.push(id)
          return
        }
        if (classification === 'permanent') {
          failed.push({ id, permanent: true })
          return
        }
        if (attempt >= maxAttempts) {
          failed.push({ id, permanent: false })
          return
        }
        await sleep(fetchRetryDelayMs(attempt, retryAfterSeconds, random))
      }
    }
  }

  await mapWithConcurrency(ids, concurrency, (id) => fetchOne(id), {
    limit: () => effectiveConcurrency,
  })

  return { fetched: chronological(fetched), goneIds, failed }
}
