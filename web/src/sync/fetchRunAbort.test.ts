// Run-level abort in fetchMessagesBounded (port of MessageFetcher's
// accountScopedAbortError path): an auth, quota or cancellation error stops
// the batch, gives no id a verdict, and rethrows so no cursor can commit.

import { describe, expect, it, vi } from 'vitest'
import { makeGmailSyncApi } from './deps'
import {
  AuthRequiredError,
  QuotaExhaustedError,
  RateLimitError,
  RequestAbortedError,
} from '@/gmail/errors'
import type { TokenBroker } from '@/gmail/gmailFetch'
import type { GmailMessage } from '@/gmail/types'
import { classifyFetchError, fetchMessagesBounded } from './fetch'

function msg(id: string): GmailMessage {
  return { id, threadId: `t_${id}`, internalDate: '1000' }
}

const instant = { sleep: () => Promise.resolve(), random: () => 0 }

/**
 * getMessage that answers on the next macrotask so two workers are genuinely
 * in flight together; `failing` ids reject with `error` on every attempt.
 */
function slowApi(failing: ReadonlySet<string>, error: Error) {
  const calls: string[] = []
  return {
    calls,
    getMessage: (id: string): Promise<GmailMessage> => {
      calls.push(id)
      return new Promise((resolve, reject) => {
        setTimeout(() => (failing.has(id) ? reject(error) : resolve(msg(id))), 0)
      })
    },
  }
}

describe('classifyFetchError account-scoped errors', () => {
  // Revert-check: isAccountScopedSyncAbort in gmail/errors.ts and the 'abort'
  // branch of classifyFetchError.
  it('classifies auth, quota and caller abort as a run abort, never permanent', () => {
    expect(classifyFetchError(new QuotaExhaustedError('spent')).classification).toBe('abort')
    expect(
      classifyFetchError(new AuthRequiredError('sign in', 'needs_interaction')).classification,
    ).toBe('abort')
    expect(classifyFetchError(new RequestAbortedError()).classification).toBe('abort')
  })
})

describe('fetchMessagesBounded run abort', () => {
  for (const [label, error] of [
    ['QuotaExhaustedError', new QuotaExhaustedError('Daily limit exceeded')],
    ['AuthRequiredError', new AuthRequiredError('sign in', 'needs_interaction')],
    ['RequestAbortedError', new RequestAbortedError()],
  ] as const) {
    // Revert-check: runAbortError in fetchMessagesBounded — reverted, the
    // batch resolves with the failing id bucketed as a permanent failure and
    // every later id still requested.
    it(`${label}: stops claiming ids, gives no verdict, rethrows the error`, async () => {
      const api = slowApi(new Set(['a']), error)
      const ids = ['a', 'b', 'c', 'd', 'e', 'f']

      const outcome = await fetchMessagesBounded(api, ids, {
        ...instant,
        concurrency: 2,
      }).catch((err: unknown) => err)

      expect(outcome).toBe(error)
      // a and b were in flight when a failed; the worker that b releases
      // afterwards claims c but must not issue it.
      expect(api.calls).toEqual(['a', 'b'])
    })
  }

  it('surfaces the first abort when several in-flight requests fail account-wide', async () => {
    const first = new QuotaExhaustedError('first')
    const api = slowApi(new Set(['a', 'b']), first)
    const outcome = await fetchMessagesBounded(api, ['a', 'b', 'c'], {
      ...instant,
      concurrency: 2,
    }).catch((err: unknown) => err)
    expect(outcome).toBe(first)
    expect(api.calls).toEqual(['a', 'b'])
  })

  // Revert-check: classify403 in gmailFetch.ts — reverted, the 403 reaches
  // this batch as a terminal GmailApiError and m1 lands in `failed` after one
  // attempt.
  it('retries a throttle 403 from the real endpoint and still fetches the message', async () => {
    const broker: TokenBroker = {
      getToken: () => Promise.resolve('tok'),
      refreshAfter: () => Promise.resolve('tok'),
    }
    let attempts = 0
    const fetchImpl = vi.fn(() => {
      attempts += 1
      if (attempts === 1) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              error: {
                code: 403,
                message: 'User-rate limit exceeded.',
                errors: [{ reason: 'userRateLimitExceeded' }],
              },
            }),
            { status: 403, headers: { 'Content-Type': 'application/json' } },
          ),
        )
      }
      return Promise.resolve(
        new Response(JSON.stringify(msg('m1')), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
    }) as unknown as typeof fetch
    const api = makeGmailSyncApi(broker, { fetchImpl })

    const result = await fetchMessagesBounded(api, ['m1'], instant)

    expect(result.failed).toEqual([])
    expect(result.fetched.map((m) => m.id)).toEqual(['m1'])
    expect(fetchImpl).toHaveBeenCalledTimes(2)
  })

  it('a RateLimitError still halves the in-flight width and retries (unchanged)', async () => {
    let attempts = 0
    const api = {
      getMessage: (id: string): Promise<GmailMessage> => {
        attempts += 1
        return attempts === 1 ? Promise.reject(new RateLimitError(null)) : Promise.resolve(msg(id))
      },
    }
    const result = await fetchMessagesBounded(api, ['m1'], instant)
    expect(result.fetched.map((m) => m.id)).toEqual(['m1'])
    expect(result.failed).toEqual([])
  })
})
