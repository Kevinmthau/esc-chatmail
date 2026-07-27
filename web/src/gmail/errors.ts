// Typed errors thrown by the Gmail transport (gmailFetch.ts).

// Auth failures surface as the broker's own error type so callers can catch
// one class across the auth and transport layers.
export { AuthRequiredError } from '../auth/authBroker'
export type { AuthRequiredReason } from '../auth/authBroker'

/**
 * 429 from Gmail. `retryAfterSeconds` is parsed from Retry-After and capped at
 * 60; it is NULL when the response carried no usable header.
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

/** Non-2xx Gmail API response (other than the handled 401/429 paths). */
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

/** Transport-level failure (fetch rejected, e.g. offline / DNS / CORS). */
export class NetworkError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options)
    this.name = 'NetworkError'
  }
}
