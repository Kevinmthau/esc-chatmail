// A torn-down session's sync run must not wait out a backoff while it holds the
// per-account lock: abortableSleep wakes on the session's signal, and the next
// request then ends the run as RequestAbortedError.

import { afterEach, describe, expect, it, vi } from 'vitest'
import { performRetryingRequest } from '@/gmail/client'
import { RequestAbortedError } from '@/gmail/errors'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { abortableSleep } from './deps'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

afterEach(() => {
  vi.useRealTimers()
})

describe('abortableSleep', () => {
  it('sleeps the full duration while the signal is quiet', async () => {
    vi.useFakeTimers()
    const sleep = abortableSleep(new AbortController().signal)
    let woke = false
    void sleep(1_000).then(() => {
      woke = true
    })

    await vi.advanceTimersByTimeAsync(999)
    expect(woke).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    expect(woke).toBe(true)
  })

  it('wakes as soon as the signal fires', async () => {
    vi.useFakeTimers()
    const controller = new AbortController()
    let woke = false
    void abortableSleep(controller.signal)(60_000).then(() => {
      woke = true
    })

    controller.abort()
    await vi.advanceTimersByTimeAsync(0)
    expect(woke).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('does not sleep at all once the signal has fired', async () => {
    const controller = new AbortController()
    controller.abort()
    await expect(abortableSleep(controller.signal)(60_000)).resolves.toBeUndefined()
  })

  // Revert-check: abortableSleep's abort listener — a plain sleep holds this
  // promise (and in production the sync lock) for the whole Retry-After.
  it('ends a retry ladder parked on a long Retry-After with RequestAbortedError', async () => {
    const controller = new AbortController()
    const fetchImpl = vi.fn(() =>
      Promise.resolve(new Response('{}', { status: 429, headers: { 'Retry-After': '60' } })),
    )

    const pending = performRetryingRequest(broker, '/users/me/profile', undefined, {
      allowsRetransmission: false,
      fetchImpl,
      signal: controller.signal,
      sleep: abortableSleep(controller.signal),
    }).catch((error: unknown) => error)
    await vi.waitFor(() => {
      expect(fetchImpl).toHaveBeenCalledTimes(1)
    })
    controller.abort()

    expect(await pending).toBeInstanceOf(RequestAbortedError)
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })
})
