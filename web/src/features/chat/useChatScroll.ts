// The chat scroll engine (plan §Chat scroll decision): no virtualizer. The
// scroller is a normal-flow overflow-y column with [overflow-anchor:none];
// this hook does all anchoring manually:
//   - initial position: restore the saved scrollTop for the conversation, else
//     jump to the bottom, in useLayoutEffect (before first paint); pinned is
//     seeded from that restored position so observer initial deliveries cannot
//     clobber it
//   - pinned tracking: IntersectionObserver on a 1px bottom sentinel
//     (root = scroller, rootMargin 48px)
//   - append: stick to the bottom when pinned or on own sends (smooth only for
//     own sends without reduced motion), otherwise raise the new-messages pill
//   - prepend (load older): snapshot scrollHeight/scrollTop/first-id before
//     raising the window limit, then restore the visual position — but only on
//     the emission that actually grew the window at the top (an append racing
//     the in-flight load is handled as an append and re-baselines the snapshot)
//   - ResizeObservers re-stick when pinned (reply-bar growth, media loading)

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import {
  diffAppended,
  initialPinned,
  pillCount,
  prependCorrection,
  resolveAppend,
  windowGrewAtTop,
  type AppendMessageLike,
} from './useChatScroll.helpers'

/** Saved scroll offsets per conversation (module-level; survives remounts). */
const savedScrollTops = new Map<string, number>()

export function clearSavedScrollTopsForTests(): void {
  savedScrollTops.clear()
}

function prefersReducedMotion(): boolean {
  return (
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  )
}

export interface UseChatScrollOptions {
  conversationId: string
  messages: readonly AppendMessageLike[]
  hasOlder: boolean
  /** Raises the window limit; the messages array grows at the front later. */
  onLoadOlder: () => void
}

export interface ChatScrollApi {
  scrollerRef: React.RefObject<HTMLDivElement | null>
  contentRef: React.RefObject<HTMLDivElement | null>
  topSentinelRef: React.RefObject<HTMLDivElement | null>
  bottomSentinelRef: React.RefObject<HTMLDivElement | null>
  /** New-messages pill count; 0 hides the pill. */
  newCount: number
  scrollToBottom: (smooth?: boolean) => void
  /** Pill click: scroll down and clear the count. */
  jumpToNew: () => void
}

function setScrollTop(scroller: HTMLDivElement, top: number, smooth: boolean): void {
  if (typeof scroller.scrollTo === 'function') {
    scroller.scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' })
  } else {
    scroller.scrollTop = top
  }
}

export function useChatScroll({
  conversationId,
  messages,
  hasOlder,
  onLoadOlder,
}: UseChatScrollOptions): ChatScrollApi {
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const contentRef = useRef<HTMLDivElement | null>(null)
  const topSentinelRef = useRef<HTMLDivElement | null>(null)
  const bottomSentinelRef = useRef<HTMLDivElement | null>(null)

  const pinnedRef = useRef(true)
  const didInitRef = useRef(false)
  const isPrependingRef = useRef(false)
  const prependSnapRef = useRef<{ height: number; top: number; firstId: string | null } | null>(
    null,
  )
  const prevLastIdRef = useRef<string | null>(null)
  // Observer callbacks read the latest props through this ref.
  const latestRef = useRef({ hasOlder, onLoadOlder, firstId: messages[0]?.id ?? null })
  latestRef.current = { hasOlder, onLoadOlder, firstId: messages[0]?.id ?? null }

  const [newCount, setNewCount] = useState(0)

  const scrollToBottom = useCallback((smooth = false) => {
    const scroller = scrollerRef.current
    if (scroller === null) return
    setScrollTop(scroller, scroller.scrollHeight, smooth && !prefersReducedMotion())
  }, [])

  const jumpToNew = useCallback(() => {
    setNewCount(0)
    scrollToBottom(true)
  }, [scrollToBottom])

  // Initial position + append/prepend anchoring, before paint.
  useLayoutEffect(() => {
    const scroller = scrollerRef.current
    if (scroller === null) return

    if (!didInitRef.current) {
      didInitRef.current = true
      const saved = savedScrollTops.get(conversationId)
      setScrollTop(scroller, saved ?? scroller.scrollHeight, false)
      // A restored mid-history position must not count as pinned, or the
      // ResizeObserver's initial delivery would immediately re-stick to the
      // bottom and clobber the restore.
      pinnedRef.current = initialPinned(saved, scroller.scrollHeight, scroller.clientHeight)
      prevLastIdRef.current = messages.at(-1)?.id ?? null
      return
    }

    if (isPrependingRef.current) {
      const snap = prependSnapRef.current
      if (snap !== null && windowGrewAtTop(snap.firstId, messages)) {
        setScrollTop(
          scroller,
          prependCorrection(snap.height, snap.top, scroller.scrollHeight),
          false,
        )
        isPrependingRef.current = false
        prependSnapRef.current = null
        prevLastIdRef.current = messages.at(-1)?.id ?? null
        return
      }
      // The window did not grow at the top: an append (or refetch) raced the
      // in-flight load-older. Handle it as a normal append below, then refresh
      // the snapshot baseline so the eventual prepend correction excludes this
      // emission's growth.
    }

    const diff = diffAppended(prevLastIdRef.current, messages)
    const action = resolveAppend(pinnedRef.current, diff, prefersReducedMotion())
    if (action.kind === 'stick') {
      scrollToBottom(action.smooth)
    } else if (action.kind === 'pill') {
      setNewCount((c) => pillCount(c, { type: 'append', incomingCount: action.increment }))
    }
    prevLastIdRef.current = messages.at(-1)?.id ?? null
    if (isPrependingRef.current) {
      prependSnapRef.current = {
        height: scroller.scrollHeight,
        top: scroller.scrollTop,
        firstId: messages[0]?.id ?? null,
      }
    }
  }, [conversationId, messages, scrollToBottom])

  // Pinned tracking + load-older trigger.
  useEffect(() => {
    const scroller = scrollerRef.current
    const bottom = bottomSentinelRef.current
    const top = topSentinelRef.current
    if (scroller === null || typeof IntersectionObserver === 'undefined') return

    const observers: IntersectionObserver[] = []

    if (bottom !== null) {
      const bottomObserver = new IntersectionObserver(
        (entries) => {
          const entry = entries.at(-1)
          if (entry === undefined) return
          pinnedRef.current = entry.isIntersecting
          if (entry.isIntersecting) setNewCount(0)
        },
        { root: scroller, rootMargin: '48px' },
      )
      bottomObserver.observe(bottom)
      observers.push(bottomObserver)
    }

    if (top !== null) {
      const topObserver = new IntersectionObserver(
        (entries) => {
          const entry = entries.at(-1)
          if (entry === undefined || !entry.isIntersecting) return
          const { hasOlder: canLoad, onLoadOlder: load, firstId } = latestRef.current
          if (!canLoad || isPrependingRef.current || !didInitRef.current) return
          prependSnapRef.current = {
            height: scroller.scrollHeight,
            top: scroller.scrollTop,
            firstId,
          }
          isPrependingRef.current = true
          load()
        },
        { root: scroller, rootMargin: '96px' },
      )
      topObserver.observe(top)
      observers.push(topObserver)
    }

    return () => {
      for (const observer of observers) observer.disconnect()
    }
  }, [conversationId])

  // Re-stick when pinned and the content or viewport resizes (media loading,
  // reply-bar growth, on-screen keyboard).
  useEffect(() => {
    const scroller = scrollerRef.current
    const content = contentRef.current
    if (scroller === null || typeof ResizeObserver === 'undefined') return

    const observer = new ResizeObserver(() => {
      if (pinnedRef.current) setScrollTop(scroller, scroller.scrollHeight, false)
    })
    observer.observe(scroller)
    if (content !== null) observer.observe(content)
    return () => observer.disconnect()
  }, [conversationId])

  // Save the scroll position for restore-on-return.
  useEffect(() => {
    // The scroller node is stable for the lifetime of this effect.
    const scroller = scrollerRef.current
    return () => {
      if (scroller !== null) savedScrollTops.set(conversationId, scroller.scrollTop)
    }
  }, [conversationId])

  return {
    scrollerRef,
    contentRef,
    topSentinelRef,
    bottomSentinelRef,
    newCount,
    scrollToBottom,
    jumpToNew,
  }
}
