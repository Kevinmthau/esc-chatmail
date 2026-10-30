// Restore-on-return regressions for the chat scroll engine: leaving a chat
// pinned at the bottom reopens it at the content end (not at the old pixel
// offset above whatever arrived meanwhile), a restored mid-history position
// seeds the new-messages pill with the rows that appeared since, and an
// offset measured against a deeper window (after load-older) is not replayed
// into the reset first page. Same fake-metrics harness as useChatScroll.test.

import { act, cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearSavedScrollTopsForTests, useChatScroll } from './useChatScroll'
import {
  resolveRestore,
  savedScrollPosition,
  type AppendMessageLike,
  type SavedScrollPosition,
} from './useChatScroll.helpers'

interface FakeMetrics {
  scrollHeight: number
  clientHeight: number
}

/** Backs scrollHeight/clientHeight/scrollTop/scrollTo with controllable fakes. */
function installFakeMetrics(node: HTMLElement, metrics: FakeMetrics): void {
  let top = 0
  Object.defineProperty(node, 'scrollHeight', {
    configurable: true,
    get: () => metrics.scrollHeight,
  })
  Object.defineProperty(node, 'clientHeight', {
    configurable: true,
    get: () => metrics.clientHeight,
  })
  Object.defineProperty(node, 'scrollTop', {
    configurable: true,
    get: () => top,
    set: (value: number) => {
      top = value
    },
  })
  Object.defineProperty(node, 'scrollTo', {
    configurable: true,
    value: (options: ScrollToOptions) => {
      top = options.top ?? 0
    },
  })
}

class MockIntersectionObserver {
  readonly callback: IntersectionObserverCallback
  constructor(callback: IntersectionObserverCallback) {
    this.callback = callback
  }
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
  takeRecords(): IntersectionObserverEntry[] {
    return []
  }
}

class MockResizeObserver {
  static instances: MockResizeObserver[] = []
  readonly callback: ResizeObserverCallback
  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
    MockResizeObserver.instances.push(this)
  }
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
  /** Simulates the observer's (mandatory-on-observe) delivery. */
  trigger(): void {
    this.callback([], this)
  }
}

function Harness({
  conversationId,
  messages,
  metrics,
}: {
  conversationId: string
  messages: readonly AppendMessageLike[]
  metrics: FakeMetrics
}) {
  const api = useChatScroll({
    conversationId,
    messages,
    hasOlder: false,
    onLoadOlder: () => undefined,
  })
  // Callback ref: fakes must be in place before the hook's layout effect reads
  // scroll metrics at mount.
  const setScroller = (node: HTMLDivElement | null): void => {
    if (node !== null && !Object.getOwnPropertyDescriptor(node, 'scrollTop')) {
      installFakeMetrics(node, metrics)
    }
    api.scrollerRef.current = node
  }
  return (
    <div ref={setScroller} data-testid="scroller">
      <div ref={api.contentRef}>
        <div ref={api.topSentinelRef} />
        {messages.map((m) => (
          <div key={m.id} />
        ))}
        <div ref={api.bottomSentinelRef} />
      </div>
      <span data-testid="pill-count">{api.newCount}</span>
    </div>
  )
}

beforeEach(() => {
  clearSavedScrollTopsForTests()
  MockResizeObserver.instances = []
  vi.stubGlobal('IntersectionObserver', MockIntersectionObserver)
  vi.stubGlobal('ResizeObserver', MockResizeObserver)
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function msg(id: string, isFromMe = 0): AppendMessageLike {
  return { id, isFromMe }
}

function deliverResizes(): void {
  act(() => {
    for (const observer of MockResizeObserver.instances) observer.trigger()
  })
}

describe('savedScrollPosition / resolveRestore', () => {
  const rows = [msg('a'), msg('b'), msg('c')]

  // Revert-check: savedScrollPosition (useChatScroll.helpers.ts)
  it('saves "bottom" when leaving within the epsilon of the content end', () => {
    expect(savedScrollPosition(600, 1000, 400, rows)).toEqual({ kind: 'bottom' })
    expect(savedScrollPosition(560, 1000, 400, rows)).toEqual({ kind: 'bottom' })
  })

  it('saves the offset with the window bounds when leaving mid-history', () => {
    expect(savedScrollPosition(100, 1000, 400, rows)).toEqual({
      kind: 'offset',
      top: 100,
      firstId: 'a',
      lastId: 'c',
    })
  })

  it('saves "bottom" for an empty window', () => {
    expect(savedScrollPosition(0, 0, 400, [])).toEqual({ kind: 'bottom' })
  })

  // Revert-check: resolveRestore (useChatScroll.helpers.ts)
  it('opens at the bottom with nothing saved or a saved "bottom"', () => {
    expect(resolveRestore(undefined, rows)).toEqual({ kind: 'bottom' })
    expect(resolveRestore({ kind: 'bottom' }, rows)).toEqual({ kind: 'bottom' })
  })

  it('honors a saved offset against the same window, counting rows that arrived since', () => {
    const saved: SavedScrollPosition = { kind: 'offset', top: 100, firstId: 'a', lastId: 'c' }
    expect(resolveRestore(saved, rows)).toEqual({
      kind: 'offset',
      top: 100,
      unseenIncomingCount: 0,
    })
    expect(resolveRestore(saved, [...rows, msg('d'), msg('e', 1), msg('f')])).toEqual({
      kind: 'offset',
      top: 100,
      unseenIncomingCount: 2,
    })
  })

  it('opens at the bottom when the window no longer starts at the saved first row', () => {
    const saved: SavedScrollPosition = { kind: 'offset', top: 100, firstId: 'old1', lastId: 'c' }
    // Deeper window (load-older) reset to the first page on remount.
    expect(resolveRestore(saved, rows)).toEqual({ kind: 'bottom' })
    // Full first page whose oldest rows new mail evicted.
    expect(
      resolveRestore({ kind: 'offset', top: 100, firstId: 'a', lastId: 'c' }, [
        msg('b'),
        msg('c'),
        msg('d'),
      ]),
    ).toEqual({ kind: 'bottom' })
  })
})

describe('useChatScroll: restore on return', () => {
  // Revert-check: savedScrollPosition (useChatScroll.helpers.ts) — a raw
  // scrollTop save reopens at 600 with the two new rows below the fold.
  it('reopens at the content end after leaving pinned at the bottom and mail arriving meanwhile', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const rows = [msg('a'), msg('b'), msg('c')]

    const first = render(<Harness conversationId="c1" messages={rows} metrics={metrics} />)
    const firstScroller = first.getByTestId('scroller')
    firstScroller.scrollTop = 600 // the browser's maximum: pinned at the bottom
    first.unmount()

    // Two messages arrived while away: the window and content grew.
    metrics.scrollHeight = 1400
    const second = render(
      <Harness conversationId="c1" messages={[...rows, msg('d'), msg('e')]} metrics={metrics} />,
    )
    const scroller = second.getByTestId('scroller')
    expect(scroller.scrollTop).toBe(1400)
    expect(second.getByTestId('pill-count').textContent).toBe('0')

    // Reopened pinned: media loading re-sticks instead of leaving a gap.
    metrics.scrollHeight = 1500
    deliverResizes()
    expect(scroller.scrollTop).toBe(1500)
  })

  // Revert-check: resolveRestore (useChatScroll.helpers.ts) — a restore that
  // seeds prevLastId with the current last row raises no pill for 'd' and 'e'.
  it('restores a mid-history position and announces the rows that arrived since', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const rows = [msg('a'), msg('b'), msg('c')]

    const first = render(<Harness conversationId="c2" messages={rows} metrics={metrics} />)
    first.getByTestId('scroller').scrollTop = 100 // reading history
    first.unmount()

    metrics.scrollHeight = 1400
    const second = render(
      <Harness conversationId="c2" messages={[...rows, msg('d'), msg('e')]} metrics={metrics} />,
    )
    const scroller = second.getByTestId('scroller')
    expect(scroller.scrollTop).toBe(100)
    expect(second.getByTestId('pill-count').textContent).toBe('2')

    // Still unpinned: the initial ResizeObserver delivery keeps the position.
    deliverResizes()
    expect(scroller.scrollTop).toBe(100)
  })

  it('opens at the bottom when the saved offset was measured against a deeper window', () => {
    const metrics: FakeMetrics = { scrollHeight: 3000, clientHeight: 400 }
    const page = [msg('m1'), msg('m2'), msg('m3')]

    // After two load-olders the window starts at old1; the user is near the top.
    const first = render(
      <Harness
        conversationId="c3"
        messages={[msg('old1'), msg('old2'), ...page]}
        metrics={metrics}
      />,
    )
    first.getByTestId('scroller').scrollTop = 40
    first.unmount()

    // MessageList remounts with the window reset to its first page.
    metrics.scrollHeight = 1000
    const second = render(<Harness conversationId="c3" messages={page} metrics={metrics} />)
    expect(second.getByTestId('scroller').scrollTop).toBe(1000)
    expect(second.getByTestId('pill-count').textContent).toBe('0')
  })
})
