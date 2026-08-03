import { describe, expect, it } from 'vitest'
import { conversationCountLabel, runBatchAction } from './batchActions'

describe('runBatchAction', () => {
  it('applies the action once per conversation, strictly in order', async () => {
    const started: string[] = []
    const finished: string[] = []
    let inFlight = 0
    let maxInFlight = 0

    const result = await runBatchAction(['a', 'b', 'c'], async (id) => {
      started.push(id)
      inFlight += 1
      maxInFlight = Math.max(maxInFlight, inFlight)
      await Promise.resolve()
      inFlight -= 1
      finished.push(id)
    })

    expect(started).toEqual(['a', 'b', 'c'])
    expect(finished).toEqual(['a', 'b', 'c'])
    // Sequential, never overlapping: pendingActions drains in createdAt order
    // (tiebroken by insertion id), so the enqueues must not interleave.
    expect(maxInFlight).toBe(1)
    expect(result).toEqual({ succeeded: ['a', 'b', 'c'], failed: [] })
  })

  it('collects failures instead of throwing, and keeps going', async () => {
    const attempted: string[] = []
    const result = await runBatchAction(['a', 'b', 'c'], async (id) => {
      attempted.push(id)
      if (id === 'b') throw new Error('boom')
      await Promise.resolve()
    })

    // A failure mid-batch does not abandon the rest of the selection.
    expect(attempted).toEqual(['a', 'b', 'c'])
    expect(result).toEqual({ succeeded: ['a', 'c'], failed: ['b'] })
  })

  it('reports every id as failed when nothing lands', async () => {
    const result = await runBatchAction(['a', 'b'], () => Promise.reject(new Error('offline')))
    expect(result).toEqual({ succeeded: [], failed: ['a', 'b'] })
  })

  it('handles an empty selection', async () => {
    const result = await runBatchAction([], () => Promise.resolve())
    expect(result).toEqual({ succeeded: [], failed: [] })
  })
})

describe('conversationCountLabel', () => {
  it('singularizes exactly one conversation', () => {
    expect(conversationCountLabel(1)).toBe('1 conversation')
    expect(conversationCountLabel(0)).toBe('0 conversations')
    expect(conversationCountLabel(3)).toBe('3 conversations')
  })
})
