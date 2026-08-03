// Per-conversation compose drafts, kept in a module store so they survive
// navigation within the session (the iOS ChatReplyBar draft behavior).
// Mounted reply bars subscribe via useSyncExternalStore, so external writes —
// compose "Open chat" seeding, failed-send restores — reach a ReplyBar that is
// already on screen instead of only affecting the next mount.

import { useCallback, useSyncExternalStore } from 'react'

const drafts = new Map<string, string>()
const listeners = new Set<() => void>()

function emit(): void {
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function clearDraftsForTests(): void {
  drafts.clear()
  emit()
}

/**
 * Sets a conversation's draft from outside the chat pane (e.g. compose
 * "Open chat" carries the typed body into that chat's reply bar). A mounted
 * ReplyBar for the conversation updates immediately; otherwise the next mount
 * picks the value up.
 */
export function setDraft(conversationId: string, value: string): void {
  if ((drafts.get(conversationId) ?? '') === value) return
  if (value === '') drafts.delete(conversationId)
  else drafts.set(conversationId, value)
  emit()
}

/**
 * Failed-send restore: gives the body back only while the conversation's draft
 * is still empty, so a late failure never clobbers text the user typed after
 * the send (or a newer draft written from another mount).
 */
export function restoreDraftIfEmpty(conversationId: string, value: string): void {
  if ((drafts.get(conversationId) ?? '') !== '') return
  setDraft(conversationId, value)
}

export function useDraft(conversationId: string): [string, (value: string) => void] {
  const value = useSyncExternalStore(
    subscribe,
    useCallback(() => drafts.get(conversationId) ?? '', [conversationId]),
  )
  const set = useCallback((next: string) => setDraft(conversationId, next), [conversationId])
  return [value, set]
}
