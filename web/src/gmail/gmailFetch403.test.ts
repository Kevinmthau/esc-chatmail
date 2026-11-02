// 403 classification by Gmail reason (port of GmailAPIClient.classify403):
// throttle reasons retry like a 429, quota reasons abort the account's work,
// everything else stays a terminal GmailApiError.

import { describe, expect, it, vi } from 'vitest'
import { performRetryingRequest } from './client'
import { GmailApiError, QuotaExhaustedError, RateLimitError } from './errors'
import { gmailFetch } from './gmailFetch'
import type { TokenBroker } from './gmailFetch'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('tok'),
  refreshAfter: () => Promise.resolve('tok'),
}

function forbidden(reason: string | undefined, headers?: Record<string, string>): Response {
  const body = {
    error: {
      code: 403,
      message: `Gmail said no (${reason ?? 'no reason'})`,
      errors: reason === undefined ? [] : [{ reason, message: 'detail' }],
    },
  }
  return new Response(JSON.stringify(body), {
    status: 403,
    headers: { 'Content-Type': 'application/json', ...headers },
  })
}

function fetchSequence(responses: (() => Response)[]) {
  let index = 0
  return vi.fn(() => {
    const next = responses[Math.min(index, responses.length - 1)]!
    index += 1
    return Promise.resolve(next())
  }) as unknown as typeof fetch
}

describe('gmailFetch 403 classification', () => {
  // Revert-check: classify403 in gmailFetch.ts.
  it('maps rateLimitExceeded / userRateLimitExceeded to RateLimitError', async () => {
    for (const reason of ['rateLimitExceeded', 'userRateLimitExceeded']) {
      const error = await gmailFetch(broker, '/users/me/messages/m1', undefined, {
        fetchImpl: fetchSequence([() => forbidden(reason)]),
      }).catch((err: unknown) => err)
      expect(error).toBeInstanceOf(RateLimitError)
      expect((error as RateLimitError).retryAfterSeconds).toBeNull()
    }
  })

  it('honors a Retry-After header on a throttle 403', async () => {
    const error = await gmailFetch(broker, '/users/me/messages/m1', undefined, {
      fetchImpl: fetchSequence([() => forbidden('userRateLimitExceeded', { 'Retry-After': '7' })]),
    }).catch((err: unknown) => err)
    expect(error).toBeInstanceOf(RateLimitError)
    expect((error as RateLimitError).retryAfterSeconds).toBe(7)
  })

  it('maps dailyLimitExceeded / quotaExceeded to QuotaExhaustedError carrying the message', async () => {
    for (const reason of ['dailyLimitExceeded', 'quotaExceeded']) {
      const error = await gmailFetch(broker, '/users/me/messages/m1', undefined, {
        fetchImpl: fetchSequence([() => forbidden(reason)]),
      }).catch((err: unknown) => err)
      expect(error).toBeInstanceOf(QuotaExhaustedError)
      expect((error as Error).message).toBe(`Gmail said no (${reason})`)
    }
  })

  it('keeps policy/scope and reason-less 403s terminal as GmailApiError', async () => {
    for (const reason of ['insufficientPermissions', 'domainPolicy', undefined]) {
      const error = await gmailFetch(broker, '/users/me/messages/m1', undefined, {
        fetchImpl: fetchSequence([() => forbidden(reason)]),
      }).catch((err: unknown) => err)
      expect(error).toBeInstanceOf(GmailApiError)
      expect((error as GmailApiError).status).toBe(403)
      expect((error as GmailApiError).reason).toBe(reason)
    }
  })
})

describe('performRetryingRequest on a classified 403', () => {
  const ok = () => new Response('{}', { status: 200 })
  const instantSleep = { sleep: () => Promise.resolve(), random: () => 0 }

  // Revert-check: classify403 — a plain GmailApiError(403) is terminal here.
  it('retries a throttle 403 on an idempotent request', async () => {
    const fetchImpl = fetchSequence([() => forbidden('userRateLimitExceeded'), ok])
    const response = await performRetryingRequest(broker, '/users/me/messages/m1', undefined, {
      allowsRetransmission: true,
      fetchImpl,
      ...instantSleep,
    })
    expect(response.ok).toBe(true)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
  })

  it('retries a throttle 403 on a non-retransmittable send: a 403 is a proven rejection', async () => {
    const fetchImpl = fetchSequence([() => forbidden('rateLimitExceeded'), ok])
    const response = await performRetryingRequest(
      broker,
      '/users/me/messages/send',
      { method: 'POST', body: '{}' },
      { allowsRetransmission: false, fetchImpl, ...instantSleep },
    )
    expect(response.ok).toBe(true)
    expect(fetchImpl).toHaveBeenCalledTimes(2)
  })

  it('never retries a quota 403', async () => {
    const fetchImpl = fetchSequence([() => forbidden('dailyLimitExceeded'), ok])
    const error = await performRetryingRequest(broker, '/users/me/messages/m1', undefined, {
      allowsRetransmission: true,
      fetchImpl,
      ...instantSleep,
    }).catch((err: unknown) => err)
    expect(error).toBeInstanceOf(QuotaExhaustedError)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })
})
