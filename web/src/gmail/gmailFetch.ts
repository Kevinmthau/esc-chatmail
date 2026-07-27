// Authed Gmail REST transport.
//
// gmailFetch(broker, path, init?) attaches a Bearer token from the auth
// broker, replays ONCE after a 401 (through the broker's single-flight
// refreshAfter), and converts failures into the typed errors in errors.ts.

import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from './errors'

export const GMAIL_API_BASE = 'https://gmail.googleapis.com/gmail/v1'

const MAX_RETRY_AFTER_SECONDS = 60

/** Structural subset of AuthBroker the transport needs (stubbable in tests). */
export interface TokenBroker {
  getToken(): Promise<string>
  refreshAfter(staleToken: string): Promise<string>
}

export interface GmailFetchOptions {
  /** Injectable fetch for tests. Defaults to the global fetch. */
  fetchImpl?: typeof fetch
}

/**
 * Perform an authenticated Gmail API request.
 *
 * @param path Path relative to the Gmail v1 base (leading slash optional),
 *             or a full http(s) URL which is used as-is.
 * @throws AuthRequiredError when no token can be produced, or the replayed
 *         request still returns 401.
 * @throws RateLimitError on 429 (Retry-After parsed, capped at 60s).
 * @throws GmailApiError on other non-2xx responses.
 * @throws NetworkError when fetch itself rejects.
 */
export async function gmailFetch(
  broker: TokenBroker,
  path: string,
  init?: RequestInit,
  options?: GmailFetchOptions,
): Promise<Response> {
  const fetchImpl = options?.fetchImpl ?? fetch
  const url = resolveUrl(path)

  const token = await broker.getToken()
  let response = await doFetch(fetchImpl, url, init, token)

  if (response.status === 401) {
    // Someone may already have refreshed; refreshAfter dedupes on the token
    // this request actually used and single-flights the renewal otherwise.
    const freshToken = await broker.refreshAfter(token)
    response = await doFetch(fetchImpl, url, init, freshToken)
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
  if (!response.ok) {
    throw await toApiError(response)
  }
  return response
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

async function doFetch(
  fetchImpl: typeof fetch,
  url: string,
  init: RequestInit | undefined,
  token: string,
): Promise<Response> {
  const headers = new Headers(init?.headers)
  headers.set('Authorization', `Bearer ${token}`)
  try {
    return await fetchImpl(url, { ...init, headers })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Network request failed'
    throw new NetworkError(message, { cause: err })
  }
}

function resolveUrl(path: string): string {
  if (path.startsWith('https://') || path.startsWith('http://')) return path
  return path.startsWith('/') ? `${GMAIL_API_BASE}${path}` : `${GMAIL_API_BASE}/${path}`
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

async function toApiError(response: Response): Promise<GmailApiError> {
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
  return new GmailApiError(response.status, reason, message)
}
