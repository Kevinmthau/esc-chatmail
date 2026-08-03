import { describe, expect, it } from 'vitest'
import {
  diffAppended,
  initialPinned,
  pillCount,
  prependCorrection,
  resolveAppend,
  shouldStick,
  windowGrewAtTop,
  type AppendMessageLike,
} from './useChatScroll.helpers'

function msg(id: string, isFromMe = 0): AppendMessageLike {
  return { id, isFromMe }
}

describe('initialPinned', () => {
  it('is pinned when there is no saved offset (fresh open jumps to the bottom)', () => {
    expect(initialPinned(undefined, 1000, 400)).toBe(true)
  })

  it('is NOT pinned when the saved offset sits mid-history', () => {
    expect(initialPinned(100, 1000, 400)).toBe(false)
  })

  it('is pinned when the saved offset is at (or within the epsilon of) the bottom', () => {
    expect(initialPinned(600, 1000, 400)).toBe(true)
    expect(initialPinned(560, 1000, 400)).toBe(true) // within the 48px epsilon
    expect(initialPinned(540, 1000, 400)).toBe(false) // just outside
  })
})

describe('windowGrewAtTop', () => {
  const base = [msg('a'), msg('b'), msg('c')]

  it('detects rows inserted before the previous first row', () => {
    expect(windowGrewAtTop('a', [msg('old1'), msg('old2'), ...base])).toBe(true)
  })

  it('rejects an append-only emission (first row unchanged)', () => {
    expect(windowGrewAtTop('a', [...base, msg('d')])).toBe(false)
  })

  it('rejects an emission where the previous first row was evicted', () => {
    expect(windowGrewAtTop('a', [msg('b'), msg('c'), msg('d')])).toBe(false)
  })

  it('rejects when there was no previous first row', () => {
    expect(windowGrewAtTop(null, base)).toBe(false)
  })
})

describe('shouldStick', () => {
  it('sticks when pinned', () => {
    expect(shouldStick(true, false)).toBe(true)
  })

  it('sticks on own append even when unpinned', () => {
    expect(shouldStick(false, true)).toBe(true)
  })

  it('does not stick when unpinned with no own append', () => {
    expect(shouldStick(false, false)).toBe(false)
  })
})

describe('prependCorrection', () => {
  it('keeps the anchor message stationary by adding the height growth', () => {
    // 1000px tall, scrolled to 120; prepend grows content to 1600px.
    expect(prependCorrection(1000, 120, 1600)).toBe(720)
  })

  it('is the identity when nothing grew', () => {
    expect(prependCorrection(1000, 350, 1000)).toBe(350)
  })

  it('handles shrinkage without going below the delta', () => {
    expect(prependCorrection(1000, 350, 900)).toBe(250)
  })
})

describe('diffAppended', () => {
  const base = [msg('a'), msg('b'), msg('c')]

  it('returns nothing on initial load (no previous anchor)', () => {
    expect(diffAppended(null, base).appended).toHaveLength(0)
  })

  it('returns nothing when the anchor id vanished (full refetch)', () => {
    expect(diffAppended('zz', base).appended).toHaveLength(0)
  })

  it('returns nothing when the anchor is still last', () => {
    expect(diffAppended('c', base).appended).toHaveLength(0)
  })

  it('detects appended messages after the anchor', () => {
    const next = [...base, msg('d'), msg('e', 1)]
    const diff = diffAppended('c', next)
    expect(diff.appended.map((m) => m.id)).toEqual(['d', 'e'])
    expect(diff.incomingCount).toBe(1)
    expect(diff.hasOwnAppend).toBe(true)
  })

  it('ignores prepended older messages (anchor still last)', () => {
    const next = [msg('old1'), msg('old2'), ...base]
    expect(diffAppended('c', next).appended).toHaveLength(0)
  })

  it('counts only incoming messages toward the pill', () => {
    const next = [...base, msg('d', 1)]
    const diff = diffAppended('c', next)
    expect(diff.incomingCount).toBe(0)
    expect(diff.hasOwnAppend).toBe(true)
  })
})

describe('pillCount', () => {
  it('accumulates appended incoming counts', () => {
    let count = 0
    count = pillCount(count, { type: 'append', incomingCount: 2 })
    count = pillCount(count, { type: 'append', incomingCount: 1 })
    expect(count).toBe(3)
  })

  it('resets to zero', () => {
    expect(pillCount(7, { type: 'reset' })).toBe(0)
  })

  it('ignores negative increments', () => {
    expect(pillCount(2, { type: 'append', incomingCount: -5 })).toBe(2)
  })
})

describe('resolveAppend', () => {
  it('does nothing without appended messages', () => {
    expect(resolveAppend(true, diffAppended(null, [msg('a')]), false)).toEqual({ kind: 'none' })
  })

  it('sticks (not smooth) when pinned and the append is incoming', () => {
    const diff = diffAppended('a', [msg('a'), msg('b')])
    expect(resolveAppend(true, diff, false)).toEqual({ kind: 'stick', smooth: false })
  })

  it('sticks smoothly for own sends when motion is allowed', () => {
    const diff = diffAppended('a', [msg('a'), msg('b', 1)])
    expect(resolveAppend(false, diff, false)).toEqual({ kind: 'stick', smooth: true })
  })

  it('never smooth-scrolls under reduced motion', () => {
    const diff = diffAppended('a', [msg('a'), msg('b', 1)])
    expect(resolveAppend(false, diff, true)).toEqual({ kind: 'stick', smooth: false })
  })

  it('raises the pill for incoming messages while unpinned', () => {
    const diff = diffAppended('a', [msg('a'), msg('b'), msg('c')])
    expect(resolveAppend(false, diff, false)).toEqual({ kind: 'pill', increment: 2 })
  })
})
