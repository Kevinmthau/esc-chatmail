import { afterEach, describe, expect, it } from 'vitest'
import { setLocksForTests, withConvoLock } from './creationLock'

afterEach(() => {
  setLocksForTests(undefined)
})

describe('withConvoLock (in-process fallback)', () => {
  it('serializes same-hash sections in FIFO order', async () => {
    setLocksForTests(null)
    const events: string[] = []
    let inside = 0

    await Promise.all(
      Array.from({ length: 5 }, (_, i) =>
        withConvoLock('hash-a', async () => {
          inside += 1
          expect(inside).toBe(1)
          events.push(`start-${i}`)
          await new Promise((resolve) => setTimeout(resolve, 1))
          events.push(`end-${i}`)
          inside -= 1
        }),
      ),
    )

    expect(events).toEqual([
      'start-0',
      'end-0',
      'start-1',
      'end-1',
      'start-2',
      'end-2',
      'start-3',
      'end-3',
      'start-4',
      'end-4',
    ])
  })

  it('does not serialize different hashes against each other', async () => {
    setLocksForTests(null)
    let bStarted = false
    const gate = new Promise<void>((resolve) => {
      setTimeout(resolve, 5)
    })

    const a = withConvoLock('hash-a', async () => {
      await gate
      expect(bStarted).toBe(true)
    })
    const b = withConvoLock('hash-b', () => {
      bStarted = true
      return Promise.resolve()
    })
    await Promise.all([a, b])
  })

  it('releases the lock after a rejection', async () => {
    setLocksForTests(null)
    await expect(withConvoLock('hash-a', () => Promise.reject(new Error('boom')))).rejects.toThrow(
      'boom',
    )
    const result = await withConvoLock('hash-a', () => Promise.resolve('ok'))
    expect(result).toBe('ok')
  })

  it('returns the callback result', async () => {
    setLocksForTests(null)
    expect(await withConvoLock('hash-a', () => Promise.resolve(42))).toBe(42)
  })

  it('uses an injected lock manager when provided', async () => {
    const requested: string[] = []
    setLocksForTests({
      request: (name, callback) => {
        requested.push(name)
        return Promise.resolve(callback())
      },
    })
    expect(await withConvoLock('abc', () => Promise.resolve('done'))).toBe('done')
    expect(requested).toEqual(['convo:abc'])
  })
})
