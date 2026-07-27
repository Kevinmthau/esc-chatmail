import { describe, expect, it, vi } from 'vitest'
import { AUTH_SCOPES, AuthBroker, AuthRequiredError } from '../auth/authBroker'
import type { GisSurface, GisTokenClientConfig } from '../auth/authBroker'
import { GmailApiError, NetworkError, RateLimitError } from './errors'
import { GMAIL_API_BASE, gmailFetch } from './gmailFetch'
import type { TokenBroker } from './gmailFetch'

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

function stubBroker(...tokens: string[]): TokenBroker & { refreshCalls: string[] } {
  let index = 0
  const refreshCalls: string[] = []
  return {
    refreshCalls,
    getToken: () => Promise.resolve(tokens[index]!),
    refreshAfter: (staleToken: string) => {
      refreshCalls.push(staleToken)
      // Mirrors the broker contract: if the current token already differs from
      // the stale one, return it; otherwise advance to the next token.
      if (tokens[index] !== staleToken) return Promise.resolve(tokens[index]!)
      index = Math.min(index + 1, tokens.length - 1)
      return Promise.resolve(tokens[index]!)
    },
  }
}

type FetchHandler = (url: string, init: RequestInit | undefined) => Response | Promise<Response>

function mockFetch(handler: FetchHandler) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) =>
    handler(
      typeof input === 'string' ? input : input instanceof URL ? input.href : input.url,
      init,
    ),
  )
}

function authHeader(init: RequestInit | undefined): string | null {
  return new Headers(init?.headers).get('Authorization')
}

function json(status: number, body: unknown, headers?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('gmailFetch', () => {
  it('attaches the Bearer token and joins the path onto the Gmail v1 base', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(200, { ok: true }))

    const response = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl })

    expect(response.ok).toBe(true)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
    const [url, init] = fetchImpl.mock.calls[0]!
    expect(url).toBe(`${GMAIL_API_BASE}/users/me/profile`)
    expect(authHeader(init)).toBe('Bearer tok-1')
  })

  it('joins paths without a leading slash too', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(200, {}))

    await gmailFetch(broker, 'users/me/labels', undefined, { fetchImpl })

    expect(fetchImpl.mock.calls[0]![0]).toBe(`${GMAIL_API_BASE}/users/me/labels`)
  })

  it('preserves caller headers while adding Authorization', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(200, {}))

    await gmailFetch(
      broker,
      '/users/me/messages/send',
      { method: 'POST', headers: { 'Content-Type': 'message/rfc822' } },
      { fetchImpl },
    )

    const [, init] = fetchImpl.mock.calls[0]!
    const headers = new Headers(init?.headers)
    expect(headers.get('Content-Type')).toBe('message/rfc822')
    expect(headers.get('Authorization')).toBe('Bearer tok-1')
    expect(init?.method).toBe('POST')
  })

  it('on 401 refreshes via the broker and replays exactly once', async () => {
    const broker = stubBroker('tok-1', 'tok-2')
    const fetchImpl = mockFetch((_url, init) =>
      authHeader(init) === 'Bearer tok-2'
        ? json(200, { ok: true })
        : new Response(null, { status: 401 }),
    )

    const response = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl })

    expect(response.status).toBe(200)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    expect(broker.refreshCalls).toEqual(['tok-1'])
    expect(authHeader(fetchImpl.mock.calls[1]![1])).toBe('Bearer tok-2')
  })

  it('throws AuthRequiredError when the replay also returns 401', async () => {
    const broker = stubBroker('tok-1', 'tok-2')
    const fetchImpl = mockFetch(() => new Response(null, { status: 401 }))

    await expect(
      gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }),
    ).rejects.toBeInstanceOf(AuthRequiredError)
    expect(fetchImpl).toHaveBeenCalledTimes(2) // never replays more than once
  })

  it('propagates AuthRequiredError from getToken without fetching', async () => {
    const broker: TokenBroker = {
      getToken: () => Promise.reject(new AuthRequiredError('Not signed in', 'signed_out')),
      refreshAfter: () => Promise.reject(new AuthRequiredError('Not signed in', 'signed_out')),
    }
    const fetchImpl = mockFetch(() => json(200, {}))

    await expect(
      gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }),
    ).rejects.toMatchObject({
      name: 'AuthRequiredError',
      reason: 'signed_out',
    })
    expect(fetchImpl).not.toHaveBeenCalled()
  })

  it('maps 429 to RateLimitError and caps Retry-After at 60', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(429, {}, { 'Retry-After': '120' }))

    await expect(
      gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }),
    ).rejects.toMatchObject({
      name: 'RateLimitError',
      retryAfterSeconds: 60,
    })
  })

  it('uses the numeric Retry-After when it is under the cap', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(429, {}, { 'Retry-After': '7' }))

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect(failure).toBeInstanceOf(RateLimitError)
    expect((failure as RateLimitError).retryAfterSeconds).toBe(7)
  })

  // Null, not the 60s cap. Gmail's per-user 429s often omit Retry-After, and
  // reporting the cap for those made an unpaced burst indistinguishable from an
  // explicit "wait a minute" — each retry then slept a full 60s of a worker slot
  // against a 3-attempt budget. Null lets the caller use its own ladder.
  it('reports NO Retry-After as null rather than defaulting to the 60s cap', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => new Response(null, { status: 429 }))

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect(failure).toBeInstanceOf(RateLimitError)
    expect((failure as RateLimitError).retryAfterSeconds).toBeNull()
  })

  it('reports an unparseable Retry-After as null too', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => json(429, {}, { 'Retry-After': 'soon' }))

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect((failure as RateLimitError).retryAfterSeconds).toBeNull()
  })

  it('parses the Gmail JSON error body into GmailApiError', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() =>
      json(500, {
        error: {
          code: 500,
          message: 'Backend Error',
          errors: [{ reason: 'backendError', message: 'Backend Error' }],
        },
      }),
    )

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect(failure).toBeInstanceOf(GmailApiError)
    expect(failure).toMatchObject({ status: 500, reason: 'backendError', message: 'Backend Error' })
  })

  it('falls back to a generic message for non-JSON error bodies', async () => {
    const broker = stubBroker('tok-1')
    const fetchImpl = mockFetch(() => new Response('<html>oops</html>', { status: 503 }))

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect(failure).toBeInstanceOf(GmailApiError)
    expect(failure).toMatchObject({ status: 503, message: 'Gmail API error 503' })
    expect((failure as GmailApiError).reason).toBeUndefined()
  })

  it('wraps a fetch rejection into NetworkError with the cause attached', async () => {
    const broker = stubBroker('tok-1')
    const cause = new TypeError('Failed to fetch')
    const fetchImpl = vi.fn((_input: RequestInfo | URL, _init?: RequestInit) =>
      Promise.reject(cause),
    )

    const failure = await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl }).catch(
      (err: unknown) => err,
    )
    expect(failure).toBeInstanceOf(NetworkError)
    expect((failure as NetworkError).message).toBe('Failed to fetch')
    expect((failure as NetworkError).cause).toBe(cause)
  })
})

describe('gmailFetch + AuthBroker integration', () => {
  // Minimal fake GIS surface (mirrors the harness in authBroker.test.ts).
  function makeGis() {
    const map = new Map<string, string>()
    const storage = {
      get length() {
        return map.size
      },
      clear: () => {
        map.clear()
      },
      getItem: (key: string) => map.get(key) ?? null,
      key: (index: number) => [...map.keys()][index] ?? null,
      removeItem: (key: string) => {
        map.delete(key)
      },
      setItem: (key: string, value: string) => {
        map.set(key, value)
      },
    }

    const pendingRequests: GisTokenClientConfig[] = []
    let requestCount = 0
    const surface: GisSurface = {
      createTokenClient: (cfg) => ({
        requestAccessToken: () => {
          requestCount += 1
          pendingRequests.push(cfg)
        },
      }),
      revoke: () => undefined,
      now: () => Date.now(),
      storage,
    }
    return {
      surface,
      pendingRequests,
      requestCount: () => requestCount,
      grantNext(accessToken: string) {
        const cfg = pendingRequests.shift()
        if (!cfg) throw new Error('no pending token request')
        cfg.callback({ access_token: accessToken, expires_in: 3600, scope: AUTH_SCOPES })
      },
    }
  }

  it('concurrent 401s share exactly one broker refresh', async () => {
    const gis = makeGis()
    const broker = new AuthBroker(gis.surface, {
      clientId: 'test-client-id',
      createChannel: () => null,
    })
    const signIn = broker.interactiveSignIn('user@example.com')
    gis.grantNext('tok-1')
    await signIn

    const fetchImpl = mockFetch((_url, init) =>
      authHeader(init) === 'Bearer tok-2'
        ? json(200, { ok: true })
        : new Response(null, { status: 401 }),
    )

    const p1 = gmailFetch(broker, '/users/me/messages/a', undefined, { fetchImpl })
    const p2 = gmailFetch(broker, '/users/me/messages/b', undefined, { fetchImpl })

    // Both requests hit 401 and call refreshAfter('tok-1'); the broker
    // single-flights so exactly ONE GIS renewal is started.
    await vi.waitFor(() => {
      expect(gis.pendingRequests.length).toBe(1)
    })
    gis.grantNext('tok-2')

    const [r1, r2] = await Promise.all([p1, p2])
    expect(r1.ok).toBe(true)
    expect(r2.ok).toBe(true)
    expect(gis.requestCount()).toBe(2) // 1 sign-in + 1 shared renewal
    expect(fetchImpl).toHaveBeenCalledTimes(4) // 2 originals + 2 replays
  })
})
