// Typed errors thrown by the Gmail transport (gmailFetch.ts).

// Auth failures surface as the broker's own error type so callers can catch
// one class across the auth and transport layers.
import { AuthRequiredError } from '../auth/authBroker'

export { AuthRequiredError }
export type { AuthRequiredReason } from '../auth/authBroker'

/**
 * 429 from Gmail, or a 403 whose reason is rateLimitExceeded /
 * userRateLimitExceeded (Gmail's per-user throttle uses both statuses; iOS
 * GmailAPIClient.classify403 maps that pair to `.rateLimited`).
 * `retryAfterSeconds` is parsed from Retry-After and capped at 60; it is NULL
 * when the response carried no usable header.
 *
 * Null is deliberately distinct from 60. Gmail's per-user 429s frequently omit
 * Retry-After, and defaulting those to the cap made an unpaced burst
 * indistinguishable from an explicit "wait a minute": every such retry burned a
 * full 60s of a worker slot against a 3-attempt budget, so a transient burst
 * cost minutes instead of the ~1s the exponential ladder would have paced it
 * at. Callers must fall back to their own backoff when this is null.
 */
export class RateLimitError extends Error {
  readonly retryAfterSeconds: number | null

  constructor(retryAfterSeconds: number | null) {
    super(
      retryAfterSeconds === null
        ? 'Gmail rate limit exceeded; no Retry-After given'
        : `Gmail rate limit exceeded; retry after ${retryAfterSeconds}s`,
    )
    this.name = 'RateLimitError'
    this.retryAfterSeconds = retryAfterSeconds
  }
}

/**
 * 403 with reason dailyLimitExceeded / quotaExceeded: the account's quota is
 * spent, so the response proves nothing about the resource being requested.
 * Account-scoped like an auth failure (iOS `APIError.quotaExhausted`,
 * `isAccountScopedSyncAbort`): sync aborts the run with no per-message
 * verdict and the outbox stops draining with its rows left pending.
 */
export class QuotaExhaustedError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'QuotaExhaustedError'
  }
}

/** Non-2xx Gmail API response (other than the handled 401/403/429 paths). */
export class GmailApiError extends Error {
  readonly status: number
  /** Gmail error reason (e.g. 'backendError', 'notFound') when the body carried one. */
  readonly reason?: string

  constructor(status: number, reason: string | undefined, message: string) {
    super(message)
    this.name = 'GmailApiError'
    this.status = status
    if (reason !== undefined) this.reason = reason
  }
}

/**
 * Transport-level failure (fetch rejected, e.g. offline / DNS / CORS), or the
 * per-request timeout elapsed. Ambiguous: the server may or may not have
 * processed the request.
 */
export class NetworkError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options)
    this.name = 'NetworkError'
  }
}

/**
 * The caller's own AbortSignal fired (sign-out / session teardown). Neither a
 * server verdict nor a transport fault: never retried, and sync treats it the
 * way iOS treats task cancellation — propagated, never recorded as a
 * per-message failure.
 */
export class RequestAbortedError extends Error {
  constructor(options?: { cause?: unknown }) {
    super('Gmail request aborted by the caller', options)
    this.name = 'RequestAbortedError'
  }
}

/**
 * Account-wide conditions that prove nothing about the individual Gmail
 * resource being processed, plus caller cancellation. Port of
 * `APIError.isAccountScopedSyncAbort`: sync must abort the run without adding
 * a per-message failure verdict or spending an abandoned-message retry.
 */
export function isAccountScopedSyncAbort(error: unknown): boolean {
  return (
    error instanceof AuthRequiredError ||
    error instanceof QuotaExhaustedError ||
    error instanceof RequestAbortedError
  )
}
