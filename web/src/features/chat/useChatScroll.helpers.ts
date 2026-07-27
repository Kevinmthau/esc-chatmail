// Pure math for the chat scroll engine (plan §Chat scroll decision). Kept
// DOM-free so the stick / prepend-compensation / pill logic is unit-testable.

export interface AppendMessageLike {
  id: string
  /** 0 | 1 flag straight off MessageRow. */
  isFromMe: number
}

/** Stay glued to the bottom when already pinned there, or on our own sends. */
export function shouldStick(pinned: boolean, hasOwnAppend: boolean): boolean {
  return pinned || hasOwnAppend
}

/** Distance from the bottom still treated as pinned (mirrors the 48px sentinel rootMargin). */
export const PINNED_BOTTOM_EPSILON_PX = 48

/**
 * Initial pinned state after the mount-time scroll restore. With no saved
 * offset we jump to the bottom (pinned); a saved offset counts as pinned only
 * when it actually sits within the epsilon of the bottom. This keeps the
 * ResizeObserver's mandatory initial delivery (which fires before the
 * IntersectionObserver ever updates pinned) from re-sticking to the bottom
 * over a restored mid-history position.
 */
export function initialPinned(
  saved: number | undefined,
  scrollHeight: number,
  clientHeight: number,
): boolean {
  if (saved === undefined) return true
  return saved + clientHeight >= scrollHeight - PINNED_BOTTOM_EPSILON_PX
}

/**
 * Whether this emission actually grew the window at the TOP: the previously
 * first row still exists and now has rows before it. An append that races an
 * in-flight load-older (same first row, growth at the bottom) — or an eviction
 * where the old first row vanished — must NOT consume the prepend correction.
 */
export function windowGrewAtTop(
  prevFirstId: string | null,
  messages: readonly AppendMessageLike[],
): boolean {
  if (prevFirstId === null) return false
  return messages.findIndex((m) => m.id === prevFirstId) > 0
}

/**
 * Scroll correction after older messages are prepended: keep the previously
 * visible message at the same on-screen position by adding the height growth.
 */
export function prependCorrection(
  prevScrollHeight: number,
  prevScrollTop: number,
  newScrollHeight: number,
): number {
  return prevScrollTop + (newScrollHeight - prevScrollHeight)
}

export interface AppendDiff {
  /** Messages that appeared after the previously-last message. */
  appended: AppendMessageLike[]
  incomingCount: number
  hasOwnAppend: boolean
}

/**
 * Diffs the window against the previously-last message id. Only true appends
 * count: on initial load (prevLastId null) or when the anchor id vanished
 * (conversation switch / full refetch) nothing is treated as appended.
 */
export function diffAppended(
  prevLastId: string | null,
  messages: readonly AppendMessageLike[],
): AppendDiff {
  const none: AppendDiff = { appended: [], incomingCount: 0, hasOwnAppend: false }
  if (prevLastId === null) return none
  const anchorIndex = messages.findIndex((m) => m.id === prevLastId)
  if (anchorIndex === -1) return none
  const appended = messages.slice(anchorIndex + 1)
  if (appended.length === 0) return none
  const incomingCount = appended.filter((m) => m.isFromMe !== 1).length
  return {
    appended,
    incomingCount,
    hasOwnAppend: appended.some((m) => m.isFromMe === 1),
  }
}

export type PillAction = { type: 'append'; incomingCount: number } | { type: 'reset' }

/** New-messages pill count reducer. */
export function pillCount(current: number, action: PillAction): number {
  if (action.type === 'reset') return 0
  return current + Math.max(0, action.incomingCount)
}

export type AppendResolution =
  { kind: 'stick'; smooth: boolean } | { kind: 'pill'; increment: number } | { kind: 'none' }

/**
 * What the append effect should do for a given diff: stick to the bottom
 * (smooth only for own sends when motion is allowed), raise the pill count for
 * unseen incoming messages, or nothing.
 */
export function resolveAppend(
  pinned: boolean,
  diff: AppendDiff,
  reducedMotion: boolean,
): AppendResolution {
  if (diff.appended.length === 0) return { kind: 'none' }
  if (shouldStick(pinned, diff.hasOwnAppend)) {
    return { kind: 'stick', smooth: diff.hasOwnAppend && !reducedMotion }
  }
  if (diff.incomingCount > 0) return { kind: 'pill', increment: diff.incomingCount }
  return { kind: 'none' }
}
