// Request bounds on the Gmail transport: a per-request timeout (the browser
// fetch API has none) surfacing as the ambiguous NetworkError, and a caller
// AbortSignal surfacing as the terminal RequestAbortedError.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { performRetryingRequest } from './client'
import { NetworkError, RequestAbortedError } from './errors'
import {
  ATTACHMENT_REQUEST_TIMEOUT_MS,
  DEFAULT_REQUEST_TIMEOUT_MS,
  gmailFetch,
  SEND_REQUEST_TIMEOUT_MS,
} from './gmailFetch'
import type { TokenBroker } from './gmailFetch'

const broker: TokenBroker = {
  getToken: () => Promise.resolve('tok'),
  refreshAfter: () => Promise.resolve('tok'),
}

/** A fetch that never answers but honors its AbortSignal like the real one. */
function hangingFetch() {
  const signals: AbortSignal[] = []
  const impl = vi.fn(
    (_input: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal
        if (signal === undefined || signal === null) return
        signals.push(signal)
        signal.addEventListener('abort', () => reject(signal.reason as Error), { once: true })
      }),
  )
  return { impl: impl as unknown as typeof fetch, calls: impl, signals }
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('gmailFetch request timeout', () => {
  // Revert-check: the timer in doFetch (gmailFetch.ts) — without it this
  // promise never settles.
  it('rejects a silent request with NetworkError after the 30s default', async () => {
    const { impl } = hangingFetch()
    const pending = gmailFetch(broker, '/users/me/messages/m1', undefined, {
      fetchImpl: impl,
    }).catch((err: unknown) => err)

    await vi.advanceTimersByTimeAsync(DEFAULT_REQUEST_TIMEOUT_MS - 1)
    let settled = false
    void pending.then(() => {
      settled = true
    })
    await Promise.resolve()
    expect(settled).toBe(false)

    await vi.advanceTimersByTimeAsync(1)
    const error = await pending
    expect(error).toBeInstanceOf(NetworkError)
    expect((error as Error).message).toContain('timed out')
  })

  it('gives attachment GETs the 60s resource timeout', async () => {
    const { impl } = hangingFetch()
    const pending = gmailFetch(broker, '/users/me/messages/m1/attachments/ATT1', undefined, {
      fetchImpl: impl,
    }).catch((err: unknown) => err)

    await vi.advanceTimersByTimeAsync(DEFAULT_REQUEST_TIMEOUT_MS)
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(ATTACHMENT_REQUEST_TIMEOUT_MS - DEFAULT_REQUEST_TIMEOUT_MS)
    expect(await pending).toBeInstanceOf(NetworkError)
  })

  // Revert-check: the messages/send branch of defaultTimeoutMs — reverted,
  // the upload is cut at 30s and the non-retransmittable send ends ambiguous.
  it('gives messages.send the 60s resource timeout, never the 30s idle bound', async () => {
    const { impl } = hangingFetch()
    const pending = gmailFetch(
      broker,
      '/users/me/messages/send',
      { method: 'POST', body: '{}' },
      { fetchImpl: impl },
    ).catch((err: unknown) => err)

    await vi.advanceTimersByTimeAsync(DEFAULT_REQUEST_TIMEOUT_MS)
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(SEND_REQUEST_TIMEOUT_MS - DEFAULT_REQUEST_TIMEOUT_MS)
    expect(await pending).toBeInstanceOf(NetworkError)
  })

  it('honors an explicit timeoutMs override', async () => {
    const { impl } = hangingFetch()
    const pending = gmailFetch(broker, '/users/me/profile', undefined, {
      fetchImpl: impl,
      timeoutMs: 5_000,
    }).catch((err: unknown) => err)
    await vi.advanceTimersByTimeAsync(5_000)
    expect(await pending).toBeInstanceOf(NetworkError)
  })

  it('clears the timer once the response arrives', async () => {
    const fetchImpl = vi.fn(() =>
      Promise.resolve(new Response('{}', { status: 200 })),
    ) as unknown as typeof fetch
    await gmailFetch(broker, '/users/me/profile', undefined, { fetchImpl })
    expect(vi.getTimerCount()).toBe(0)
  })

  it('is retried by the engine like any transport failure on an idempotent request', async () => {
    const { impl, calls } = hangingFetch()
    const pending = performRetryingRequest(broker, '/users/me/profile', undefined, {
      allowsRetransmission: true,
      fetchImpl: impl,
      maxAttempts: 2,
      sleep: () => Promise.resolve(),
    }).catch((err: unknown) => err)
    await vi.advanceTimersByTimeAsync(DEFAULT_REQUEST_TIMEOUT_MS)
    await vi.advanceTimersByTimeAsync(DEFAULT_REQUEST_TIMEOUT_MS)
    expect(await pending).toBeInstanceOf(NetworkError)
    expect(calls).toHaveBeenCalledTimes(2)
  })
})

describe('gmailFetch caller abort', () => {
  // Revert-check: the RequestAbortedError branches in doFetch.
  it('rejects with RequestAbortedError when the caller signal fires mid-flight', async () => {
    const { impl, signals } = hangingFetch()
    const controller = new AbortController()
    const pending = gmailFetch(broker, '/users/me/profile', undefined, {
      fetchImpl: impl,
      signal: controller.signal,
    }).catch((err: unknown) => err)

    await vi.advanceTimersByTimeAsync(10)
    expect(signals).toHaveLength(1)
    controller.abort()
    const error = await pending
    expect(error).toBeInstanceOf(RequestAbortedError)
    expect(error).not.toBeInstanceOf(NetworkError)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('refuses an already-aborted signal without issuing the request', async () => {
    const { impl, calls } = hangingFetch()
    const controller = new AbortController()
    controller.abort()
    const error = await gmailFetch(broker, '/users/me/profile', undefined, {
      fetchImpl: impl,
      signal: controller.signal,
    }).catch((err: unknown) => err)
    expect(error).toBeInstanceOf(RequestAbortedError)
    expect(calls).not.toHaveBeenCalled()
  })

  it('is terminal in the retry engine: an abandoned request is never resent', async () => {
    const { impl, calls } = hangingFetch()
    const controller = new AbortController()
    const pending = performRetryingRequest(broker, '/users/me/profile', undefined, {
      allowsRetransmission: true,
      fetchImpl: impl,
      signal: controller.signal,
      sleep: () => Promise.resolve(),
    }).catch((err: unknown) => err)
    await vi.advanceTimersByTimeAsync(10)
    controller.abort()
    expect(await pending).toBeInstanceOf(RequestAbortedError)
    expect(calls).toHaveBeenCalledTimes(1)
  })
})
