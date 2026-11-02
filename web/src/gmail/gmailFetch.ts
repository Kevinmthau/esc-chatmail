// Authed Gmail REST transport.
//
// gmailFetch(broker, path, init?) attaches a Bearer token from the auth
// broker, replays ONCE after a 401 (through the broker's single-flight
// refreshAfter), bounds every request with a timeout, and converts failures
// into the typed errors in errors.ts.

import {
  AuthRequiredError,
  GmailApiError,
  NetworkError,
  QuotaExhaustedError,
  RateLimitError,
  RequestAbortedError,
} from './errors'

export const GMAIL_API_BASE = 'https://gmail.googleapis.com/gmail/v1'

const MAX_RETRY_AFTER_SECONDS = 60

/**
 * Per-request wall-clock bound. The browser fetch API has no timeout of its
 * own: a connection that goes silent (sleep/wake, network path change) never
 * settles, and a sync holding the per-account Web Lock on such a request
 * blocks every later trigger until the tab reloads. iOS pins
 * timeoutIntervalForRequest to max(NetworkConfig.requestTimeout, 30s).
 */
export const DEFAULT_REQUEST_TIMEOUT_MS = 30_000
/**
 * Bound on a whole transfer (NetworkConfig.resourceTimeout, 60s), which is
 * what a total-duration AbortSignal measures. iOS's 30s request timeout is an
 * idle bound that never fires while bytes flow, so the requests that move
 * ~25MB of base64 take this one instead: attachment GETs, and messages.send,
 * whose upload must never be cut shorter than iOS allows — a timeout on the
 * non-retransmittable send is an ambiguous outcome with no resend.
 */
export const RESOURCE_TIMEOUT_MS = 60_000
export const ATTACHMENT_REQUEST_TIMEOUT_MS = RESOURCE_TIMEOUT_MS
export const SEND_REQUEST_TIMEOUT_MS = RESOURCE_TIMEOUT_MS

/** Structural subset of AuthBroker the transport needs (stubbable in tests). */
export interface TokenBroker {
  getToken(): Promise<string>
  refreshAfter(staleToken: string): Promise<string>
}

export interface GmailFetchOptions {
  /** Injectable fetch for tests. Defaults to the global fetch. */
  fetchImpl?: typeof fetch
  /** Overrides the path-derived timeout (DEFAULT_/ATTACHMENT_REQUEST_TIMEOUT_MS). */
  timeoutMs?: number
  /**
   * Caller-owned cancellation (session teardown). Firing it rejects the
   * request with RequestAbortedError, distinct from the timeout's NetworkError
   * so the retry engine never resends a request the caller gave up on.
   */
  signal?: AbortSignal
}

/**
 * Perform an authenticated Gmail API request.
 *
 * @param path Path relative to the Gmail v1 base (leading slash optional),
 *             or an absolute URL under that exact HTTPS API base.
 * @throws AuthRequiredError when no token can be produced, or the replayed
 *         request still returns 401.
 * @throws RateLimitError on 429 (Retry-After parsed, capped at 60s), or on a
 *         403 whose reason is rateLimitExceeded / userRateLimitExceeded.
 * @throws QuotaExhaustedError on a 403 whose reason is dailyLimitExceeded /
 *         quotaExceeded.
 * @throws GmailApiError on other non-2xx responses.
 * @throws NetworkError when fetch itself rejects or the timeout elapses.
 * @throws RequestAbortedError when `options.signal` fires.
 */
export async function gmailFetch(
  broker: TokenBroker,
  path: string,
  init?: RequestInit,
  options?: GmailFetchOptions,
): Promise<Response> {
  const fetchImpl = options?.fetchImpl ?? fetch
  const url = resolveUrl(path)
  const bounds: RequestBounds = {
    timeoutMs: options?.timeoutMs ?? defaultTimeoutMs(url),
    signal: options?.signal,
  }

  const token = await broker.getToken()
  let response = await doFetch(fetchImpl, url, init, token, bounds)

  if (response.status === 401) {
    // Someone may already have refreshed; refreshAfter dedupes on the token
    // this request actually used and single-flights the renewal otherwise.
    const freshToken = await broker.refreshAfter(token)
    response = await doFetch(fetchImpl, url, init, freshToken, bounds)
    if (response.status === 401) {
      throw new AuthRequiredError(
        'Gmail rejected the refreshed token (401 after replay)',
        'needs_interaction',
      )
    }
  }

  if (response.status === 429) {
    throw new RateLimitError(parseRetryAfter(response.headers.get('Retry-After')))
  }
  if (response.status === 403) {
    throw await classify403(response)
  }
  if (!response.ok) {
    throw await toApiError(response)
  }
  return response
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

interface RequestBounds {
  timeoutMs: number
  signal: AbortSignal | undefined
}

function defaultTimeoutMs(url: string): number {
  const pathname = new URL(url).pathname
  if (/\/attachments\//.test(pathname)) return ATTACHMENT_REQUEST_TIMEOUT_MS
  if (/\/messages\/send$/.test(pathname)) return SEND_REQUEST_TIMEOUT_MS
  return DEFAULT_REQUEST_TIMEOUT_MS
}

async function doFetch(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit | undefined,
  token: string,
  bounds: RequestBounds,
): Promise<Response> {
  const headers = new Headers(init?.headers)
  headers.set('Authorization', `Bearer ${token}`)

  // One controller merges the timeout and the caller's signal by hand rather
  // than through AbortSignal.any/timeout: the merged signal must say WHICH
  // source fired (a timeout is an ambiguous transport failure, a caller abort
  // is a deliberate cancellation), and a plain setTimeout stays under test
  // clocks.
  const controller = new AbortController()
  let timedOut = false
  const onCallerAbort = (): void => {
    controller.abort(bounds.signal?.reason)
  }
  if (bounds.signal !== undefined) {
    if (bounds.signal.aborted) throw new RequestAbortedError({ cause: bounds.signal.reason })
    bounds.signal.addEventListener('abort', onCallerAbort, { once: true })
  }
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort(
      new DOMException(`Gmail request timed out after ${bounds.timeoutMs}ms`, 'TimeoutError'),
    )
  }, bounds.timeoutMs)

  try {
    const response = await fetchImpl(url, { ...init, headers, signal: controller.signal })
    // fetch settles at the response headers; the transfer a messages.get or
    // an attachment GET actually spends its time on is the body. Reading it
    // here keeps the timeout and the caller's abort attached to the whole
    // transfer, and hands callers a Response whose body can no longer stall.
    const body = NULL_BODY_STATUSES.has(response.status) ? null : await response.arrayBuffer()
    return new Response(body, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    })
  } catch (err) {
    if (timedOut) {
      throw new NetworkError(`Gmail request timed out after ${bounds.timeoutMs}ms`, { cause: err })
    }
    if (bounds.signal?.aborted === true) {
      throw new RequestAbortedError({ cause: err })
    }
    const message = err instanceof Error ? err.message : 'Network request failed'
    throw new NetworkError(message, { cause: err })
  } finally {
    clearTimeout(timer)
    bounds.signal?.removeEventListener('abort', onCallerAbort)
  }
}

/** Statuses the Response constructor refuses a body for. */
const NULL_BODY_STATUSES = new Set([204, 205, 304])

function resolveUrl(path: string): string {
  const base = new URL(`${GMAIL_API_BASE}/`)
  const isAbsolute = /^[a-z][a-z\d+.-]*:/i.test(path) || path.startsWith('//')

  let resolved: URL
  try {
    resolved = isAbsolute
      ? new URL(path, base)
      : new URL(path.startsWith('/') ? path.slice(1) : path, base)
  } catch {
    throw new TypeError('Invalid Gmail API URL')
  }

  const basePath = base.pathname.replace(/\/$/, '')
  const isWithinApiBase =
    resolved.pathname === basePath || resolved.pathname.startsWith(`${basePath}/`)
  if (resolved.protocol !== 'https:' || resolved.origin !== base.origin || !isWithinApiBase) {
    throw new TypeError('Refusing to send Gmail credentials outside the Gmail API base')
  }

  return resolved.href
}

/**
 * Retry-After in seconds, capped at 60 — or null when the header is absent or
 * unparseable. Null, not the cap: see RateLimitError's note on why an unpaced
 * 429 must not masquerade as an explicit 60-second instruction.
 */
function parseRetryAfter(header: string | null): number | null {
  if (header === null) return null
  const seconds = Number(header)
  if (Number.isFinite(seconds)) return clampRetryAfter(Math.ceil(seconds))
  // Retry-After may also be an HTTP-date.
  const dateMs = Date.parse(header)
  if (!Number.isNaN(dateMs)) return clampRetryAfter(Math.ceil((dateMs - Date.now()) / 1000))
  return null
}

function clampRetryAfter(seconds: number): number {
  return Math.min(Math.max(seconds, 0), MAX_RETRY_AFTER_SECONDS)
}

interface GmailErrorBody {
  error?: {
    code?: number
    message?: string
    status?: string
    errors?: { reason?: string; message?: string }[]
  }
}

interface ParsedErrorBody {
  reason: string | undefined
  message: string
}

async function parseErrorBody(response: Response): Promise<ParsedErrorBody> {
  let reason: string | undefined
  let message = `Gmail API error ${response.status}`
  try {
    const body = (await response.json()) as GmailErrorBody
    const error = body.error
    if (error) {
      if (typeof error.message === 'string' && error.message !== '') message = error.message
      const firstReason = error.errors?.[0]?.reason
      reason = typeof firstReason === 'string' ? firstReason : error.status
    }
  } catch {
    // Non-JSON error body; keep the generic message.
  }
  return { reason, message }
}

async function toApiError(response: Response): Promise<GmailApiError> {
  const { reason, message } = await parseErrorBody(response)
  return new GmailApiError(response.status, reason, message)
}

/**
 * Gmail uses 403 for both retryable rate limiting and terminal policy/scope
 * failures; the nested `errors[].reason` disambiguates. Port of
 * GmailAPIClient.classify403. See
 * https://developers.google.com/workspace/gmail/api/guides/handle-errors
 */
async function classify403(response: Response): Promise<Error> {
  const { reason, message } = await parseErrorBody(response)
  switch (reason) {
    case 'rateLimitExceeded':
    case 'userRateLimitExceeded':
      return new RateLimitError(parseRetryAfter(response.headers.get('Retry-After')))
    case 'dailyLimitExceeded':
    case 'quotaExceeded':
      return new QuotaExhaustedError(message)
    default:
      // Policy/scope failures (insufficientPermissions, domainPolicy,
      // accessNotConfigured, …) and reason-less bodies stay terminal.
      return new GmailApiError(response.status, reason, message)
  }
}
