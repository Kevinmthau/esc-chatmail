// Hook-level regressions for the chat scroll engine, driven through mock
// Intersection/ResizeObservers (happy-dom provides neither the observer
// deliveries nor real layout, so the harness fakes scroll metrics on the
// scroller node before the hook's layout effects run):
// 1. A restored scroll position survives the ResizeObserver's mandatory
//    initial delivery (pinned must be seeded from the restored position).
// 2. The prepend correction is only consumed by the emission that actually
//    grew the window at the top — an append racing an in-flight load-older
//    must not eat (or misapply) it.

import { act, cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearSavedScrollTopsForTests, useChatScroll } from './useChatScroll'
import type { AppendMessageLike } from './useChatScroll.helpers'

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
  static instances: MockIntersectionObserver[] = []
  readonly callback: IntersectionObserverCallback
  observed: Element[] = []
  constructor(callback: IntersectionObserverCallback) {
    this.callback = callback
    MockIntersectionObserver.instances.push(this)
  }
  observe(element: Element): void {
    this.observed.push(element)
  }
  unobserve(): void {}
  disconnect(): void {}
  takeRecords(): IntersectionObserverEntry[] {
    return []
  }
  trigger(isIntersecting: boolean): void {
    this.callback(
      [{ isIntersecting } as IntersectionObserverEntry],
      this as unknown as IntersectionObserver,
    )
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

/** The observer watching the given sentinel (bottom and top are separate observers). */
function observerFor(sentinel: Element): MockIntersectionObserver {
  const found = MockIntersectionObserver.instances.find((o) => o.observed.includes(sentinel))
  if (found === undefined) throw new Error('no observer registered for sentinel')
  return found
}

function Harness({
  conversationId,
  messages,
  hasOlder,
  onLoadOlder,
  metrics,
}: {
  conversationId: string
  messages: readonly AppendMessageLike[]
  hasOlder: boolean
  onLoadOlder: () => void
  metrics: FakeMetrics
}) {
  const api = useChatScroll({ conversationId, messages, hasOlder, onLoadOlder })
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
        <div ref={api.topSentinelRef} data-testid="top-sentinel" />
        {messages.map((m) => (
          <div key={m.id} />
        ))}
        <div ref={api.bottomSentinelRef} data-testid="bottom-sentinel" />
      </div>
      <span data-testid="pill-count">{api.newCount}</span>
    </div>
  )
}

beforeEach(() => {
  clearSavedScrollTopsForTests()
  MockIntersectionObserver.instances = []
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

describe('useChatScroll: initial position vs observer deliveries', () => {
  it('keeps a restored mid-history position when the initial ResizeObserver delivery fires', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const messages = [msg('a'), msg('b'), msg('c')]

    // First visit: opens at the bottom, user scrolls up into history, leaves.
    const first = render(
      <Harness
        conversationId="c1"
        messages={messages}
        hasOlder={false}
        onLoadOlder={() => undefined}
        metrics={metrics}
      />,
    )
    const firstScroller = first.getByTestId('scroller')
    expect(firstScroller.scrollTop).toBe(1000) // opened pinned to the bottom
    firstScroller.scrollTop = 100 // user scrolls up
    first.unmount() // leave the chat: offset 100 is saved

    // Return to the chat: position restores, then the ResizeObserver delivers
    // its mandatory initial observation.
    const second = render(
      <Harness
        conversationId="c1"
        messages={messages}
        hasOlder={false}
        onLoadOlder={() => undefined}
        metrics={metrics}
      />,
    )
    const scroller = second.getByTestId('scroller')
    expect(scroller.scrollTop).toBe(100) // restored before paint

    act(() => {
      for (const observer of MockResizeObserver.instances) observer.trigger()
    })
    // Old code defaulted pinned=true and re-stuck to the bottom here (1000).
    expect(scroller.scrollTop).toBe(100)
  })

  it('still re-sticks to the bottom on resize when opened fresh (pinned)', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const { getByTestId } = render(
      <Harness
        conversationId="c2"
        messages={[msg('a')]}
        hasOlder={false}
        onLoadOlder={() => undefined}
        metrics={metrics}
      />,
    )
    const scroller = getByTestId('scroller')
    expect(scroller.scrollTop).toBe(1000)

    metrics.scrollHeight = 1200 // media loaded, content grew
    act(() => {
      for (const observer of MockResizeObserver.instances) observer.trigger()
    })
    expect(scroller.scrollTop).toBe(1200)
  })
})

describe('useChatScroll: prepend correction vs racing append', () => {
  it('applies the correction to the top-growth emission, not to an append that lands first', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const base = [msg('m1'), msg('m2'), msg('m3')]
    const onLoadOlder = vi.fn()

    const view = render(
      <Harness
        conversationId="c3"
        messages={base}
        hasOlder={true}
        onLoadOlder={onLoadOlder}
        metrics={metrics}
      />,
    )
    const scroller = view.getByTestId('scroller')

    // User scrolls to the very top; the bottom sentinel reports unpinned and
    // the top sentinel triggers load-older (snapshotting height/top/first-id).
    scroller.scrollTop = 0
    act(() => {
      observerFor(view.getByTestId('bottom-sentinel')).trigger(false)
      observerFor(view.getByTestId('top-sentinel')).trigger(true)
    })
    expect(onLoadOlder).toHaveBeenCalledTimes(1)

    // A new incoming message lands BEFORE the higher-limit query resolves:
    // growth is at the bottom, so no correction may be applied.
    metrics.scrollHeight = 1100
    view.rerender(
      <Harness
        conversationId="c3"
        messages={[...base, msg('m4')]}
        hasOlder={true}
        onLoadOlder={onLoadOlder}
        metrics={metrics}
      />,
    )
    // Old code consumed the prepend snapshot here and scrolled to 0+(1100-1000)=100.
    expect(scroller.scrollTop).toBe(0)
    // The racing append is handled as an append: unpinned incoming -> pill.
    expect(view.getByTestId('pill-count').textContent).toBe('1')

    // The actual older page arrives: NOW the correction runs, measured from
    // the refreshed baseline (1100), keeping the viewport on the same rows.
    metrics.scrollHeight = 1500
    view.rerender(
      <Harness
        conversationId="c3"
        messages={[msg('old1'), msg('old2'), ...base, msg('m4')]}
        hasOlder={false}
        onLoadOlder={onLoadOlder}
        metrics={metrics}
      />,
    )
    // Old code had already cleared the snapshot, leaving this uncompensated.
    expect(scroller.scrollTop).toBe(400)
  })

  it('still compensates a plain load-older with no racing append', () => {
    const metrics: FakeMetrics = { scrollHeight: 1000, clientHeight: 400 }
    const base = [msg('m1'), msg('m2')]
    const view = render(
      <Harness
        conversationId="c4"
        messages={base}
        hasOlder={true}
        onLoadOlder={() => undefined}
        metrics={metrics}
      />,
    )
    const scroller = view.getByTestId('scroller')
    scroller.scrollTop = 20
    act(() => {
      observerFor(view.getByTestId('bottom-sentinel')).trigger(false)
      observerFor(view.getByTestId('top-sentinel')).trigger(true)
    })

    metrics.scrollHeight = 1600
    view.rerender(
      <Harness
        conversationId="c4"
        messages={[msg('old1'), ...base]}
        hasOlder={false}
        onLoadOlder={() => undefined}
        metrics={metrics}
      />,
    )
    expect(scroller.scrollTop).toBe(620) // 20 + (1600 - 1000)
  })
})
