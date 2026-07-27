import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from './errors'
import {
  BACKOFF_CAP_MS,
  backoffDelayMs,
  DEFAULT_MAX_ATTEMPTS,
  performRetryingRequest,
} from './client'
import {
  BATCH_MODIFY_CHUNK_SIZE,
  batchModify,
  getAttachment,
  getMessage,
  getProfile,
  listHistory,
  listLabels,
  listMessages,
  listSendAs,
  modifyMessage,
  sendMessage,
} from './endpoints'
import { GMAIL_API_BASE } from './gmailFetch'
import type { TokenBroker } from './gmailFetch'
import { HistoryIdExpiredError } from './historyError'

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const server = setupServer()

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

function stubBroker(...tokens: string[]): TokenBroker {
  let index = 0
  return {
    getToken: () => Promise.resolve(tokens[index] ?? tokens[tokens.length - 1]!),
    refreshAfter: (staleToken: string) => {
      if (tokens[index] !== staleToken) return Promise.resolve(tokens[index]!)
      index = Math.min(index + 1, tokens.length - 1)
      return Promise.resolve(tokens[index]!)
    },
  }
}

/** Fake sleep: resolves immediately, records every requested delay (ms). */
function fakeSleep() {
  const delays: number[] = []
  return {
    delays,
    sleep: (ms: number) => {
      delays.push(ms)
      return Promise.resolve()
    },
  }
}

/** rng pinned to 0.5 → zero jitter, so backoff delays are exact. */
const noJitter = () => 0.5

const gmailError = (code: number, message: string, reason?: string) => ({
  error: { code, message, errors: reason ? [{ reason, message }] : [] },
})

// ---------------------------------------------------------------------------
// Retry engine
// ---------------------------------------------------------------------------

describe('performRetryingRequest', () => {
  it('sleeps the server-paced Retry-After on 429, then succeeds', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        if (calls === 1) {
          return HttpResponse.json(gmailError(429, 'Rate limited'), {
            status: 429,
            headers: { 'Retry-After': '7' },
          })
        }
        return HttpResponse.json({ emailAddress: 'me@example.com', historyId: '42' })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const profile = await getProfile(stubBroker('tok'), { sleep, random: noJitter })

    expect(profile.emailAddress).toBe('me@example.com')
    expect(calls).toBe(2)
    expect(delays).toEqual([7_000]) // seconds → ms, straight from Retry-After
  })

  // A 429 with no Retry-After used to be reported as an explicit 60s wait, so
  // each retry slept a full minute — three attempts spent two minutes of a
  // worker slot on a burst the ladder would have paced in ~3s. Now the null
  // pacing falls through to the exponential backoff, which also ADVANCES (the
  // second delay is doubled), so repeated unpaced 429s still back off.
  it('backs off exponentially on a 429 that carries no Retry-After', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        if (calls <= 2) {
          return HttpResponse.json(gmailError(429, 'Rate limited'), { status: 429 })
        }
        return HttpResponse.json({ emailAddress: 'me@example.com', historyId: '42' })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const profile = await getProfile(stubBroker('tok'), { sleep, random: noJitter })

    expect(profile.emailAddress).toBe('me@example.com')
    expect(calls).toBe(3)
    expect(delays).toEqual([backoffDelayMs(0, noJitter), backoffDelayMs(1, noJitter)])
    // Nowhere near the 60s-per-attempt the old default cost.
    expect(delays.reduce((a, b) => a + b, 0)).toBeLessThan(10_000)
  })

  it('throws RateLimitError once 429s exhaust the attempt budget', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        return HttpResponse.json(gmailError(429, 'Rate limited'), {
          status: 429,
          headers: { 'Retry-After': '1' },
        })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await getProfile(stubBroker('tok'), { maxAttempts: 2, sleep }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(RateLimitError)
    expect((failure as RateLimitError).retryAfterSeconds).toBe(1)
    expect(calls).toBe(2)
    expect(delays).toEqual([1_000]) // final 429 throws without sleeping again
  })

  it('retries a 5xx GET with exponential backoff, then succeeds', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        if (calls <= 2) {
          return HttpResponse.json(gmailError(500, 'Backend Error', 'backendError'), {
            status: 500,
          })
        }
        return HttpResponse.json({ emailAddress: 'me@example.com', historyId: '42' })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const profile = await getProfile(stubBroker('tok'), { sleep, random: noJitter })

    expect(profile.emailAddress).toBe('me@example.com')
    expect(calls).toBe(3)
    expect(delays).toEqual([1_000, 2_000]) // base 1s, factor 2, zero jitter
  })

  it('exhausts the default 4 attempts on persistent 5xx and surfaces the error', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        return HttpResponse.json(gmailError(503, 'Service Unavailable'), { status: 503 })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await getProfile(stubBroker('tok'), { sleep, random: noJitter }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(GmailApiError)
    expect((failure as GmailApiError).status).toBe(503)
    expect(calls).toBe(DEFAULT_MAX_ATTEMPTS)
    expect(delays).toEqual([1_000, 2_000, 4_000])
  })

  it('keeps backoff delays inside the ±10% jitter bounds', async () => {
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () =>
        HttpResponse.json(gmailError(500, 'Backend Error'), { status: 500 }),
      ),
    )
    const { delays, sleep } = fakeSleep()

    await getProfile(stubBroker('tok'), { maxAttempts: 4, sleep }).catch(() => undefined)

    expect(delays).toHaveLength(3)
    const expectedBases = [1_000, 2_000, 4_000]
    delays.forEach((delay, i) => {
      const base = expectedBases[i]!
      expect(delay).toBeGreaterThanOrEqual(base * 0.9)
      expect(delay).toBeLessThanOrEqual(base * 1.1)
    })
  })

  it('retries a network error on a GET', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        if (calls === 1) return HttpResponse.error()
        return HttpResponse.json({ emailAddress: 'me@example.com', historyId: '42' })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const profile = await getProfile(stubBroker('tok'), { sleep, random: noJitter })

    expect(profile.emailAddress).toBe('me@example.com')
    expect(calls).toBe(2)
    expect(delays).toEqual([1_000])
  })

  it('treats AuthRequiredError as terminal (never retried here)', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () => {
        calls += 1
        return new HttpResponse(null, { status: 401 })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await getProfile(stubBroker('tok-1', 'tok-2'), { sleep }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(AuthRequiredError)
    // Exactly the transport's original + single refreshed replay; the retry
    // engine adds no further attempts.
    expect(calls).toBe(2)
    expect(delays).toEqual([])
  })

  it('treats non-429 4xx as terminal without sleeping', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/messages/missing`, () => {
        calls += 1
        return HttpResponse.json(gmailError(404, 'Not Found', 'notFound'), { status: 404 })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await getMessage(stubBroker('tok'), 'missing', 'full', { sleep }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(GmailApiError)
    expect(failure).toMatchObject({ status: 404, reason: 'notFound' })
    expect(calls).toBe(1)
    expect(delays).toEqual([])
  })

  it('lets mapStatus replace a terminal 4xx error', async () => {
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/profile`, () =>
        HttpResponse.json(gmailError(404, 'Not Found'), { status: 404 }),
      ),
    )

    class CustomError extends Error {}
    const failure = await performRetryingRequest(
      stubBroker('tok'),
      '/users/me/profile',
      undefined,
      {
        allowsRetransmission: true,
        mapStatus: (status) => (status === 404 ? new CustomError('mapped') : null),
      },
    ).catch((err: unknown) => err)

    expect(failure).toBeInstanceOf(CustomError)
  })
})

describe('backoffDelayMs', () => {
  it('progresses 1s → 2s → 4s … and caps at 30s (zero jitter)', () => {
    expect(backoffDelayMs(0, noJitter)).toBe(1_000)
    expect(backoffDelayMs(1, noJitter)).toBe(2_000)
    expect(backoffDelayMs(2, noJitter)).toBe(4_000)
    expect(backoffDelayMs(3, noJitter)).toBe(8_000)
    expect(backoffDelayMs(4, noJitter)).toBe(16_000)
    expect(backoffDelayMs(5, noJitter)).toBe(30_000) // 32s capped
    expect(backoffDelayMs(10, noJitter)).toBe(BACKOFF_CAP_MS)
  })

  it('applies at most ±10% jitter at the rng extremes', () => {
    expect(backoffDelayMs(2, () => 0)).toBe(4_000 * 0.9)
    expect(backoffDelayMs(2, () => 0.999999)).toBeCloseTo(4_000 * 1.1, 0)
    expect(backoffDelayMs(10, () => 0)).toBe(BACKOFF_CAP_MS * 0.9)
  })
})

// ---------------------------------------------------------------------------
// Send: never retransmit
// ---------------------------------------------------------------------------

describe('sendMessage', () => {
  it('does NOT retransmit after a 5xx (exactly one invocation)', async () => {
    let calls = 0
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/send`, () => {
        calls += 1
        return HttpResponse.json(gmailError(503, 'Service Unavailable'), { status: 503 })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await sendMessage(stubBroker('tok'), { raw: 'ZW1haWw=' }, { sleep }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(GmailApiError)
    expect((failure as GmailApiError).status).toBe(503)
    expect(calls).toBe(1)
    expect(delays).toEqual([])
  })

  it('treats a network error as terminal (ambiguous — may have been delivered)', async () => {
    let calls = 0
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/send`, () => {
        calls += 1
        return HttpResponse.error()
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await sendMessage(stubBroker('tok'), { raw: 'ZW1haWw=' }, { sleep }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(NetworkError)
    expect(calls).toBe(1)
    expect(delays).toEqual([])
  })

  it('still retries on 429 (proven rejection, nothing was processed)', async () => {
    let calls = 0
    const bodies: unknown[] = []
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/send`, async ({ request }) => {
        calls += 1
        bodies.push(await request.json())
        if (calls === 1) {
          return HttpResponse.json(gmailError(429, 'Rate limited'), {
            status: 429,
            headers: { 'Retry-After': '2' },
          })
        }
        return HttpResponse.json({ id: 'm1', threadId: 't1' })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const sent = await sendMessage(
      stubBroker('tok'),
      { raw: 'ZW1haWw=', threadId: 't1' },
      { sleep },
    )

    expect(sent).toEqual({ id: 'm1', threadId: 't1' })
    expect(calls).toBe(2)
    expect(delays).toEqual([2_000])
    expect(bodies[0]).toEqual({ raw: 'ZW1haWw=', threadId: 't1' })
  })

  it('omits threadId from the body when not provided', async () => {
    let body: unknown
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/send`, async ({ request }) => {
        body = await request.json()
        return HttpResponse.json({ id: 'm1', threadId: 't1' })
      }),
    )

    await sendMessage(stubBroker('tok'), { raw: 'ZW1haWw=' })

    expect(body).toEqual({ raw: 'ZW1haWw=' })
  })
})

// ---------------------------------------------------------------------------
// History: 404 → HistoryIdExpiredError
// ---------------------------------------------------------------------------

describe('listHistory', () => {
  it('maps a 404 to HistoryIdExpiredError without retrying', async () => {
    let calls = 0
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/history`, () => {
        calls += 1
        return HttpResponse.json(gmailError(404, 'Requested entity was not found.', 'notFound'), {
          status: 404,
        })
      }),
    )
    const { delays, sleep } = fakeSleep()

    const failure = await listHistory(
      stubBroker('tok'),
      { startHistoryId: '12345' },
      { sleep },
    ).catch((err: unknown) => err)

    expect(failure).toBeInstanceOf(HistoryIdExpiredError)
    expect(calls).toBe(1)
    expect(delays).toEqual([])
  })

  it('keeps other 4xx as GmailApiError', async () => {
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/history`, () =>
        HttpResponse.json(gmailError(403, 'Quota exceeded', 'quotaExceeded'), { status: 403 }),
      ),
    )

    const failure = await listHistory(stubBroker('tok'), { startHistoryId: '12345' }).catch(
      (err: unknown) => err,
    )

    expect(failure).toBeInstanceOf(GmailApiError)
    expect(failure).toMatchObject({ status: 403, reason: 'quotaExceeded' })
  })

  it('passes startHistoryId and pageToken as query params', async () => {
    let url: URL | undefined
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/history`, ({ request }) => {
        url = new URL(request.url)
        return HttpResponse.json({ historyId: '999', history: [] })
      }),
    )

    const response = await listHistory(stubBroker('tok'), {
      startHistoryId: '12345',
      pageToken: 'page-2',
    })

    expect(response.historyId).toBe('999')
    expect(url?.searchParams.get('startHistoryId')).toBe('12345')
    expect(url?.searchParams.get('pageToken')).toBe('page-2')
  })
})

// ---------------------------------------------------------------------------
// batchModify chunking
// ---------------------------------------------------------------------------

describe('batchModify', () => {
  it('chunks 2500 ids into 3 calls of 1000/1000/500, labels on every call', async () => {
    const bodies: { ids: string[]; addLabelIds?: string[]; removeLabelIds?: string[] }[] = []
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/batchModify`, async ({ request }) => {
        bodies.push((await request.json()) as (typeof bodies)[number])
        return new HttpResponse(null, { status: 204 })
      }),
    )
    const ids = Array.from({ length: 2500 }, (_, i) => `msg-${i}`)

    await batchModify(stubBroker('tok'), { ids, removeLabelIds: ['INBOX'], addLabelIds: ['SPAM'] })

    expect(bodies).toHaveLength(3)
    expect(bodies.map((b) => b.ids.length)).toEqual([1000, 1000, 500])
    expect(bodies[0]!.ids[0]).toBe('msg-0')
    expect(bodies[1]!.ids[0]).toBe(`msg-${BATCH_MODIFY_CHUNK_SIZE}`)
    expect(bodies[2]!.ids[499]).toBe('msg-2499')
    for (const body of bodies) {
      expect(body.addLabelIds).toEqual(['SPAM'])
      expect(body.removeLabelIds).toEqual(['INBOX'])
    }
  })

  it('makes a single call when ids fit one chunk', async () => {
    let calls = 0
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/batchModify`, () => {
        calls += 1
        return new HttpResponse(null, { status: 204 })
      }),
    )

    await batchModify(stubBroker('tok'), { ids: ['a', 'b'], removeLabelIds: ['UNREAD'] })

    expect(calls).toBe(1)
  })
})

// ---------------------------------------------------------------------------
// Endpoint shapes
// ---------------------------------------------------------------------------

describe('endpoints', () => {
  it('listMessages passes q, pageToken and maxResults', async () => {
    let url: URL | undefined
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/messages`, ({ request }) => {
        url = new URL(request.url)
        return HttpResponse.json({
          messages: [{ id: 'm1', threadId: 't1' }],
          nextPageToken: 'next',
        })
      }),
    )

    const response = await listMessages(stubBroker('tok'), {
      q: 'after:123 -label:spam',
      pageToken: 'p1',
      maxResults: 500,
    })

    expect(response.messages).toEqual([{ id: 'm1', threadId: 't1' }])
    expect(url?.searchParams.get('q')).toBe('after:123 -label:spam')
    expect(url?.searchParams.get('pageToken')).toBe('p1')
    expect(url?.searchParams.get('maxResults')).toBe('500')
  })

  it('listMessages defaults maxResults to 100 and omits q/pageToken', async () => {
    let url: URL | undefined
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/messages`, ({ request }) => {
        url = new URL(request.url)
        return HttpResponse.json({})
      }),
    )

    await listMessages(stubBroker('tok'))

    expect(url?.searchParams.get('maxResults')).toBe('100')
    expect(url?.searchParams.has('q')).toBe(false)
    expect(url?.searchParams.has('pageToken')).toBe(false)
  })

  it('getMessage requests the given format', async () => {
    let url: URL | undefined
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/messages/msg-1`, ({ request }) => {
        url = new URL(request.url)
        return HttpResponse.json({ id: 'msg-1', threadId: 't1' })
      }),
    )

    const message = await getMessage(stubBroker('tok'), 'msg-1', 'metadata')

    expect(message.id).toBe('msg-1')
    expect(url?.searchParams.get('format')).toBe('metadata')
  })

  it('listLabels and listSendAs unwrap their list envelopes (missing → [])', async () => {
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/labels`, () => HttpResponse.json({})),
      http.get(`${GMAIL_API_BASE}/users/me/settings/sendAs`, () =>
        HttpResponse.json({
          sendAs: [{ sendAsEmail: 'me@example.com', isPrimary: true }],
        }),
      ),
    )

    expect(await listLabels(stubBroker('tok'))).toEqual([])
    expect(await listSendAs(stubBroker('tok'))).toEqual([
      { sendAsEmail: 'me@example.com', isPrimary: true },
    ])
  })

  it('modifyMessage POSTs label changes and returns the message', async () => {
    let body: unknown
    server.use(
      http.post(`${GMAIL_API_BASE}/users/me/messages/msg-9/modify`, async ({ request }) => {
        body = await request.json()
        return HttpResponse.json({ id: 'msg-9', threadId: 't9', labelIds: ['STARRED'] })
      }),
    )

    const message = await modifyMessage(stubBroker('tok'), 'msg-9', {
      addLabelIds: ['STARRED'],
      removeLabelIds: ['UNREAD'],
    })

    expect(message.labelIds).toEqual(['STARRED'])
    expect(body).toEqual({ addLabelIds: ['STARRED'], removeLabelIds: ['UNREAD'] })
  })

  it('getAttachment hits the attachments path and returns the DTO', async () => {
    server.use(
      http.get(`${GMAIL_API_BASE}/users/me/messages/msg-1/attachments/att-1`, () =>
        HttpResponse.json({ size: 3, data: 'YWJj' }),
      ),
    )

    const attachment = await getAttachment(stubBroker('tok'), 'msg-1', 'att-1')

    expect(attachment).toEqual({ size: 3, data: 'YWJj' })
  })
})
