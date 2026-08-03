// Unified retry engine over the gmailFetch transport.
//
// Port of GmailAPIClient.performRetryingRequest (esc-chatmail/Services/API/
// GmailAPIClient.swift) + Services/Retry/* onto the web transport. The
// engine owns 429 pacing and 5xx/network exponential backoff; gmailFetch
// already owns the once-only 401 refresh+replay, so AuthRequiredError is
// always terminal here.
//
// Simplifications vs iOS (per plan): the 120s total-retry circuit breaker
// and RateLimitTracker sliding window are replaced by a per-request
// maxAttempts budget.
//
// DEVIATION from iOS ConnectionErrorDetector.isPreTransmissionError: the
// browser fetch API rejects with an opaque TypeError for every transport
// failure — DNS, refused connection, TLS, and dropped-mid-flight all look
// identical — so the web cannot prove a request never reached the server.
// iOS retries non-idempotent sends on proven pre-transmission failures;
// here, when retransmission is not allowed (and the method is not GET), a
// NetworkError is terminal. Safe direction: never double-send.

import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from './errors'
import { gmailFetch } from './gmailFetch'
import type { GmailFetchOptions, TokenBroker } from './gmailFetch'

export const DEFAULT_MAX_ATTEMPTS = 4
export const BACKOFF_BASE_MS = 1_000
export const BACKOFF_FACTOR = 2
export const BACKOFF_CAP_MS = 30_000
/** ±10% jitter, mirroring Services/Retry/ExponentialBackoff.swift. */
export const BACKOFF_JITTER = 0.1

export interface RetryBehavior {
  /** Total attempts including the first (default 4). Every retry — 429, 5xx, network — consumes one. */
  maxAttempts?: number
  /**
   * false for non-idempotent requests (messages.send): after an ambiguous
   * failure (5xx, network error) the request is never resent, because the
   * server may already have processed it. GET requests are exempt — they
   * are idempotent by definition and always safe to resend.
   */
  allowsRetransmission: boolean
  /**
   * Consulted before throwing a terminal non-5xx GmailApiError so callers
   * can map statuses specially (history 404 → HistoryIdExpiredError).
   * Return null to keep the original GmailApiError. Receives the thrown
   * GmailApiError rather than the raw body — gmailFetch has already
   * consumed the body into {status, reason, message}.
   */
  mapStatus?: (status: number, error: GmailApiError) => Error | null
  /** Injectable delay for tests. Receives milliseconds. */
  sleep?: (ms: number) => Promise<void>
  /** Injectable RNG for tests ([0,1), defaults to Math.random). */
  random?: () => number
  /** Injectable fetch, threaded through to gmailFetch. */
  fetchImpl?: typeof fetch
}

/**
 * Backoff delay for the given 0-indexed retry: min(base·factor^n, cap) ± 10%
 * jitter. Exported for direct unit testing of the progression.
 */
export function backoffDelayMs(retryIndex: number, random: () => number = Math.random): number {
  const raw = Math.min(BACKOFF_BASE_MS * BACKOFF_FACTOR ** retryIndex, BACKOFF_CAP_MS)
  const jitter = raw * BACKOFF_JITTER * (random() * 2 - 1)
  return raw + jitter
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * Perform an authenticated Gmail request with unified retry semantics:
 *
 * - RateLimitError (429): sleep the server-paced retryAfterSeconds (already
 *   capped at 60s by gmailFetch), or the exponential backoff when the response
 *   carried no Retry-After; retry, counting against maxAttempts.
 * - GmailApiError 5xx: exponential backoff (1s base, ×2, cap 30s, ±10%
 *   jitter), retry — only when retransmission is safe (allowed or GET).
 * - NetworkError: same backoff retry when retransmission is safe; terminal
 *   otherwise (see the pre-transmission deviation note above).
 * - AuthRequiredError: terminal (gmailFetch already refreshed+replayed once).
 * - Other GmailApiError (4xx…): terminal; mapStatus is consulted first.
 */
export async function performRetryingRequest(
  broker: TokenBroker,
  path: string,
  init: RequestInit | undefined,
  behavior: RetryBehavior,
): Promise<Response> {
  const maxAttempts = behavior.maxAttempts ?? DEFAULT_MAX_ATTEMPTS
  const sleep = behavior.sleep ?? defaultSleep
  const random = behavior.random ?? Math.random
  const method = (init?.method ?? 'GET').toUpperCase()
  const retransmissionSafe = behavior.allowsRetransmission || method === 'GET'
  const fetchOptions: GmailFetchOptions | undefined = behavior.fetchImpl
    ? { fetchImpl: behavior.fetchImpl }
    : undefined

  // 0-indexed count of backoff sleeps taken so far; drives the exponential
  // progression for 5xx/network retries (429 uses server pacing instead).
  let backoffRetries = 0

  for (let attempt = 1; ; attempt += 1) {
    try {
      return await gmailFetch(broker, path, init, fetchOptions)
    } catch (err) {
      if (err instanceof AuthRequiredError) {
        throw err
      }
      if (err instanceof RateLimitError) {
        if (attempt >= maxAttempts) throw err
        // Server pacing only when the server actually paced us. A 429 with no
        // Retry-After takes the exponential ladder (and advances it) instead of
        // spending a full minute per attempt on a guess.
        if (err.retryAfterSeconds === null) {
          await sleep(backoffDelayMs(backoffRetries, random))
          backoffRetries += 1
        } else {
          await sleep(err.retryAfterSeconds * 1_000)
        }
        continue
      }
      if (err instanceof GmailApiError) {
        if (err.status >= 500 && err.status <= 599) {
          if (!retransmissionSafe || attempt >= maxAttempts) throw err
          await sleep(backoffDelayMs(backoffRetries, random))
          backoffRetries += 1
          continue
        }
        // Terminal status (4xx other than 429 — gmailFetch owns 401/429).
        const mapped = behavior.mapStatus?.(err.status, err)
        throw mapped ?? err
      }
      if (err instanceof NetworkError) {
        if (!retransmissionSafe || attempt >= maxAttempts) throw err
        await sleep(backoffDelayMs(backoffRetries, random))
        backoffRetries += 1
        continue
      }
      throw err
    }
  }
}
