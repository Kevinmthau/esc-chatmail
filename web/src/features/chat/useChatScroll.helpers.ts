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

/** Whether a scroll offset sits within the epsilon of the content end. */
export function isWithinBottomEpsilon(
  scrollTop: number,
  scrollHeight: number,
  clientHeight: number,
): boolean {
  return scrollTop + clientHeight >= scrollHeight - PINNED_BOTTOM_EPSILON_PX
}

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
  return isWithinBottomEpsilon(saved, scrollHeight, clientHeight)
}

/**
 * What the hook remembers about a conversation on leaving it. A pixel offset
 * only means something against the rows it was measured over, so it travels
 * with the window's first and last row ids: MessageList remounts with the
 * window reset to its first page, and new mail evicts the oldest rows of a
 * full page, so the same offset can land on unrelated rows on return.
 */
export type SavedScrollPosition =
  { kind: 'bottom' } | { kind: 'offset'; top: number; firstId: string; lastId: string | null }

/**
 * The position to save when leaving. Within the epsilon of the bottom the
 * user was reading the newest mail, so the restore reopens at the content
 * end (where anything that arrived meanwhile is), as iOS always opens a
 * transcript; a raw offset would reopen above the new rows with nothing
 * pointing at them, because the restore cannot tell "left here" from "left
 * at the bottom, then mail arrived".
 */
export function savedScrollPosition(
  scrollTop: number,
  scrollHeight: number,
  clientHeight: number,
  messages: readonly AppendMessageLike[],
): SavedScrollPosition {
  const firstId = messages[0]?.id
  if (firstId === undefined || isWithinBottomEpsilon(scrollTop, scrollHeight, clientHeight)) {
    return { kind: 'bottom' }
  }
  return { kind: 'offset', top: scrollTop, firstId, lastId: messages.at(-1)?.id ?? null }
}

export type RestoreResolution =
  { kind: 'bottom' } | { kind: 'offset'; top: number; unseenIncomingCount: number }

/**
 * Where to open the transcript on return. A saved offset is honored only
 * when the window still starts at the row it was measured from, so the rows
 * above the offset are the ones it was measured over; otherwise (fresh open,
 * left at the bottom, deeper window reset to the first page, oldest rows
 * evicted by new mail) the transcript opens at the content end. Rows that
 * appeared after the last row seen at leave time are the pill's seed count,
 * so a restored mid-history position still announces what arrived meanwhile.
 */
export function resolveRestore(
  saved: SavedScrollPosition | undefined,
  messages: readonly AppendMessageLike[],
): RestoreResolution {
  if (saved === undefined || saved.kind === 'bottom') return { kind: 'bottom' }
  if (messages[0]?.id !== saved.firstId) return { kind: 'bottom' }
  const diff = diffAppended(saved.lastId, messages)
  return { kind: 'offset', top: saved.top, unseenIncomingCount: diff.incomingCount }
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
