// Port of ConversationSearchService
// (esc-chatmail/Services/ConversationList/ConversationSearchService.swift).
//
// iOS splits search input in two: `searchText` updates on every keystroke and
// drives the text field, while `debouncedSearchText` lags by 150ms and is the
// only value the fetch predicate ever sees. This hook is the same split — the
// draft renders, `commit` publishes.

import { useCallback, useEffect, useRef, useState } from 'react'

/** iOS ConversationSearchService's debounce interval (150_000_000 ns). */
export const SEARCH_DEBOUNCE_MS = 150

export interface SearchDraft {
  /** What the input shows — updates on every keystroke. */
  draft: string
  /** Record a keystroke; schedules (or, when emptied, performs) the commit. */
  setDraft: (next: string) => void
  /** Clear button / Escape: empties the field and commits immediately. */
  clear: () => void
}

/**
 * Debounced search-box state.
 *
 * `committed` is the currently published query (the ?q= route param); `commit`
 * publishes a new one. Emptying the field bypasses the debounce, matching
 * `debounceSearch()`'s early return for empty text — waiting 150ms to restore
 * the full list after a clear reads as a stall.
 */
export function useSearchDraft(committed: string, commit: (next: string) => void): SearchDraft {
  const [draft, setDraft] = useState(committed)

  // The value most recently handed to `commit`. Committing round-trips through
  // a router navigation, so `committed` arriving at a value we sent is our own
  // echo — adopting it would clobber keystrokes typed during the round trip.
  // Any other change (back/forward, a link that drops ?q=) is external, and the
  // field follows it — including cancelling any pending keystroke commit, which
  // would otherwise fire after the adoption and rewrite the URL to the stale
  // keystroke while the field shows the adopted value.
  const timerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const sentRef = useRef(committed)
  useEffect(() => {
    if (committed === sentRef.current) return
    sentRef.current = committed
    clearTimeout(timerRef.current)
    setDraft(committed)
  }, [committed])

  // Keep the latest `commit` reachable from the timer without making every
  // callback below churn on each render.
  const commitRef = useRef(commit)
  useEffect(() => {
    commitRef.current = commit
  })

  const publish = useCallback((next: string) => {
    sentRef.current = next
    commitRef.current(next)
  }, [])

  const onDraft = useCallback(
    (next: string) => {
      setDraft(next)
      clearTimeout(timerRef.current)
      if (next === '') {
        publish('')
        return
      }
      timerRef.current = setTimeout(() => publish(next), SEARCH_DEBOUNCE_MS)
    },
    [publish],
  )

  const clear = useCallback(() => {
    clearTimeout(timerRef.current)
    setDraft('')
    publish('')
  }, [publish])

  // iOS ConversationSearchService.cleanup() cancels the pending debounce task
  // when the list disappears; the web equivalent is unmount.
  useEffect(() => () => clearTimeout(timerRef.current), [])

  return { draft, setDraft: onDraft, clear }
}
