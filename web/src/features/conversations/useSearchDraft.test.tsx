import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SEARCH_DEBOUNCE_MS, useSearchDraft } from './useSearchDraft'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

/** Renders the hook with a controllable `committed` value, like the router. */
function renderDraft(initial = '') {
  const commit = vi.fn<(next: string) => void>()
  const view = renderHook(({ committed }) => useSearchDraft(committed, commit), {
    initialProps: { committed: initial },
  })
  return { ...view, commit }
}

describe('useSearchDraft (iOS ConversationSearchService)', () => {
  it('shows keystrokes immediately but commits only after 150ms', () => {
    const { result, commit } = renderDraft()

    act(() => {
      result.current.setDraft('a')
    })
    expect(result.current.draft).toBe('a')
    expect(commit).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS - 1)
    })
    expect(commit).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(commit).toHaveBeenCalledExactlyOnceWith('a')
  })

  it('commits once for a burst of keystrokes, with the final value', () => {
    const { result, commit } = renderDraft()

    for (const text of ['a', 'al', 'ali', 'alic', 'alice']) {
      act(() => {
        result.current.setDraft(text)
        vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS - 20)
      })
    }
    expect(commit).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS)
    })
    expect(commit).toHaveBeenCalledExactlyOnceWith('alice')
  })

  it('publishes an emptied field immediately, without waiting out the debounce', () => {
    // iOS's debounceSearch() returns early for empty text; making the full list
    // wait 150ms to come back after a delete reads as a stall.
    const { result, commit } = renderDraft()

    act(() => {
      result.current.setDraft('a')
      result.current.setDraft('')
    })
    expect(commit).toHaveBeenCalledExactlyOnceWith('')

    // ...and the superseded keystroke never lands afterwards.
    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS * 2)
    })
    expect(commit).toHaveBeenCalledTimes(1)
  })

  it('clear() empties and commits at once, cancelling any pending debounce', () => {
    const { result, commit } = renderDraft()

    act(() => {
      result.current.setDraft('alice')
    })
    act(() => {
      result.current.clear()
    })
    expect(result.current.draft).toBe('')
    expect(commit).toHaveBeenCalledExactlyOnceWith('')

    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS * 2)
    })
    expect(commit).toHaveBeenCalledTimes(1)
  })

  it('starts from the committed query (reload with ?q= already set)', () => {
    const { result } = renderDraft('bob')
    expect(result.current.draft).toBe('bob')
  })

  it('adopts an externally changed query (back/forward)', () => {
    const { result, rerender } = renderDraft('bob')

    act(() => {
      rerender({ committed: 'carol' })
    })
    expect(result.current.draft).toBe('carol')

    act(() => {
      rerender({ committed: '' })
    })
    expect(result.current.draft).toBe('')
  })

  it('does not clobber keystrokes typed while its own commit is in flight', () => {
    // Committing round-trips through a router navigation. If `committed`
    // catching up to the value we sent were treated as an external change, the
    // characters typed during that round trip would be erased under the user.
    const { result, rerender } = renderDraft()

    act(() => {
      result.current.setDraft('ali')
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS)
    })
    act(() => {
      result.current.setDraft('alice')
    })

    // The router only now reports the earlier commit.
    act(() => {
      rerender({ committed: 'ali' })
    })
    expect(result.current.draft).toBe('alice')
  })

  it('adopting an external change cancels a pending keystroke commit', () => {
    // With ?q=ali committed, the user types a keystroke (timer armed) and then
    // navigates Back/Forward before it fires. The field adopts the external
    // value; the stale keystroke must not rewrite the URL underneath it.
    const { result, commit, rerender } = renderDraft('ali')

    act(() => {
      result.current.setDraft('x')
    })
    act(() => {
      rerender({ committed: 'book' })
    })
    expect(result.current.draft).toBe('book')

    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS * 2)
    })
    expect(commit).not.toHaveBeenCalled()
    expect(result.current.draft).toBe('book')
  })

  it('drops a pending commit on unmount (iOS cleanup())', () => {
    const { result, commit, unmount } = renderDraft()

    act(() => {
      result.current.setDraft('alice')
    })
    unmount()
    act(() => {
      vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS * 2)
    })
    expect(commit).not.toHaveBeenCalled()
  })
})
