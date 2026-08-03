import { describe, expect, it } from 'vitest'
import { AuthRequiredError, GmailApiError, NetworkError, RateLimitError } from '@/gmail/errors'
import type { GmailMessage } from '@/gmail/types'
import {
  classifyFetchError,
  FETCH_CONCURRENCY,
  fetchMessagesBounded,
  fetchRetryDelayMs,
} from './fetch'

function msg(id: string, internalDate = 1000): GmailMessage {
  return { id, threadId: `t_${id}`, internalDate: String(internalDate) }
}

function apiFor(impl: (id: string) => Promise<GmailMessage>): {
  getMessage: (id: string, format: 'full' | 'metadata') => Promise<GmailMessage>
} {
  return { getMessage: (id) => impl(id) }
}

const instantSleep = { sleep: () => Promise.resolve(), random: () => 0 }

describe('classifyFetchError', () => {
  it('maps errors onto gone/permanent/retriable', () => {
    expect(classifyFetchError(new GmailApiError(404, 'notFound', 'nope')).classification).toBe(
      'gone',
    )
    expect(classifyFetchError(new GmailApiError(400, 'badRequest', 'bad')).classification).toBe(
      'permanent',
    )
    expect(classifyFetchError(new GmailApiError(500, 'backendError', 'boom')).classification).toBe(
      'retriable',
    )
    expect(classifyFetchError(new NetworkError('offline')).classification).toBe('retriable')
    expect(
      classifyFetchError(new AuthRequiredError('sign in', 'needs_interaction')).classification,
    ).toBe('permanent')
    expect(classifyFetchError(new Error('decode failed')).classification).toBe('permanent')
    const rateLimited = classifyFetchError(new RateLimitError(7))
    expect(rateLimited.classification).toBe('retriable')
    expect(rateLimited.retryAfterSeconds).toBe(7)
  })
})

describe('fetchRetryDelayMs', () => {
  it('follows the 500ms/1s/2s ladder with zero jitter', () => {
    expect(fetchRetryDelayMs(1, null, () => 0)).toBe(500)
    expect(fetchRetryDelayMs(2, null, () => 0)).toBe(1000)
    expect(fetchRetryDelayMs(3, null, () => 0)).toBe(2000)
  })

  it('adds at most 25% jitter', () => {
    expect(fetchRetryDelayMs(1, null, () => 1)).toBe(625)
  })

  it('honors a larger server Retry-After over the synthetic backoff', () => {
    expect(fetchRetryDelayMs(1, 7, () => 0)).toBe(7000)
    // Smaller Retry-After never shortens the ladder.
    expect(fetchRetryDelayMs(3, 1, () => 0)).toBe(2000)
  })
})

describe('fetchMessagesBounded', () => {
  it('fetches everything and sorts chronologically', async () => {
    const store = new Map([
      ['a', msg('a', 300)],
      ['b', msg('b', 100)],
      ['c', msg('c', 200)],
    ])
    const result = await fetchMessagesBounded(
      apiFor((id) => Promise.resolve(store.get(id)!)),
      ['a', 'b', 'c'],
      instantSleep,
    )
    expect(result.fetched.map((m) => m.id)).toEqual(['b', 'c', 'a'])
    expect(result.failed).toEqual([])
    expect(result.goneIds).toEqual([])
  })

  it('retries 5xx with backoff, then succeeds', async () => {
    const delays: number[] = []
    let attempts = 0
    const result = await fetchMessagesBounded(
      apiFor((id) => {
        attempts += 1
        if (attempts < 3) return Promise.reject(new GmailApiError(500, 'backendError', 'boom'))
        return Promise.resolve(msg(id))
      }),
      ['a'],
      {
        sleep: (ms) => {
          delays.push(ms)
          return Promise.resolve()
        },
        random: () => 0,
      },
    )
    expect(result.fetched.map((m) => m.id)).toEqual(['a'])
    expect(delays).toEqual([500, 1000])
  })

  it('sleeps the server Retry-After on rate limiting', async () => {
    const delays: number[] = []
    let attempts = 0
    await fetchMessagesBounded(
      apiFor((id) => {
        attempts += 1
        if (attempts === 1) return Promise.reject(new RateLimitError(9))
        return Promise.resolve(msg(id))
      }),
      ['a'],
      {
        sleep: (ms) => {
          delays.push(ms)
          return Promise.resolve()
        },
        random: () => 0,
      },
    )
    expect(delays).toEqual([9000])
  })

  it('classifies exhausted transient failures as non-permanent', async () => {
    const result = await fetchMessagesBounded(
      apiFor(() => Promise.reject(new GmailApiError(503, 'backendError', 'down'))),
      ['a'],
      instantSleep,
    )
    expect(result.failed).toEqual([{ id: 'a', permanent: false }])
  })

  it('fails permanently on 4xx without retrying', async () => {
    let calls = 0
    const result = await fetchMessagesBounded(
      apiFor(() => {
        calls += 1
        return Promise.reject(new GmailApiError(403, 'forbidden', 'no'))
      }),
      ['a'],
      instantSleep,
    )
    expect(result.failed).toEqual([{ id: 'a', permanent: true }])
    expect(calls).toBe(1)
  })

  it('drops 404s silently into goneIds', async () => {
    const result = await fetchMessagesBounded(
      apiFor((id) =>
        id === 'gone'
          ? Promise.reject(new GmailApiError(404, 'notFound', 'nope'))
          : Promise.resolve(msg(id)),
      ),
      ['a', 'gone'],
      instantSleep,
    )
    expect(result.goneIds).toEqual(['gone'])
    expect(result.fetched.map((m) => m.id)).toEqual(['a'])
  })

  it('bounds concurrency at the default width', async () => {
    let inFlight = 0
    let maxInFlight = 0
    const ids = Array.from({ length: 40 }, (_, i) => `m${i}`)
    await fetchMessagesBounded(
      apiFor(async (id) => {
        inFlight += 1
        maxInFlight = Math.max(maxInFlight, inFlight)
        await new Promise((resolve) => setTimeout(resolve, 1))
        inFlight -= 1
        return msg(id)
      }),
      ids,
      instantSleep,
    )
    expect(maxInFlight).toBeLessThanOrEqual(FETCH_CONCURRENCY)
    expect(maxInFlight).toBeGreaterThan(1)
  })

  it('keeps the default width inside Gmail per-user quota headroom', () => {
    // messages.get costs 5 quota units against 250 units/user/second. 8 in
    // flight at typical latency sits at or above the throttle for a whole
    // backfill, which is exactly how a 429 storm starts.
    expect(FETCH_CONCURRENCY * 5).toBeLessThanOrEqual(30)
  })

  it('halves the in-flight width for the rest of the batch after a 429', async () => {
    // A single 429 on the first id: continuing at full width against an
    // already-throttled account only converts more messages into 60s retry
    // sleeps, so the batch must shed workers and stay shed.
    let inFlight = 0
    let throttledOnce = false
    const widths: number[] = []

    const ids = Array.from({ length: 40 }, (_, i) => `m${i}`)
    await fetchMessagesBounded(
      apiFor(async (id) => {
        inFlight += 1
        widths.push(inFlight)
        await new Promise((resolve) => setTimeout(resolve, 1))
        inFlight -= 1
        if (!throttledOnce) {
          throttledOnce = true
          throw new RateLimitError(1)
        }
        return msg(id)
      }),
      ids,
      instantSleep,
    )

    // Steady state after the workers in flight at throttle time drained.
    const tail = widths.slice(-20)
    expect(Math.max(...tail)).toBeLessThanOrEqual(Math.floor(FETCH_CONCURRENCY / 2))
    // ...and the batch really did start out wider than that.
    expect(Math.max(...widths)).toBe(FETCH_CONCURRENCY)
  })
})
