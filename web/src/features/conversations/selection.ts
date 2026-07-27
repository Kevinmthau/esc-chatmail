// Multi-select state for the conversation list. Port of
// Services/ConversationList/ConversationSelectionService.swift.
//
// Two deliberate choices:
//
// - Ephemeral, not router state. A selection is a transient UI mode; putting it
//   in the URL would make it survive reloads and back/forward navigation, and
//   would resurrect ids that no longer exist in the list.
// - Keyed by conversation id, never by row index. The list is virtualized over
//   recycled fixed-height rows, so an index-keyed selection would follow the
//   viewport instead of the conversations.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'

const EMPTY_SELECTION: ReadonlySet<string> = new Set()

export interface ConversationSelection {
  /** Whether the list is in multi-select mode. */
  selecting: boolean
  selectedIds: ReadonlySet<string>
  selectedCount: number
  /** How many rows Select All covers — the loaded window (see toggleSelectAll). */
  selectableCount: number
  /** True when every loaded row is selected: the "Deselect All" state. */
  allSelected: boolean
  enterSelectMode: () => void
  exitSelectMode: () => void
  toggleSelection: (conversationId: string) => void
  toggleSelectAll: () => void
  /** Replaces the selection outright (used to keep a failed batch selected). */
  setSelection: (conversationIds: readonly string[]) => void
  /** Called by the list with the ids it currently has loaded. */
  registerSelectableIds: (conversationIds: readonly string[]) => void
}

/**
 * Inert default: a list mounted outside a selection provider simply never
 * enters select mode, rather than throwing. ConversationList's own unit tests
 * mount it bare, and selection is an enhancement the list does not depend on.
 */
const INERT_SELECTION: ConversationSelection = {
  selecting: false,
  selectedIds: EMPTY_SELECTION,
  selectedCount: 0,
  selectableCount: 0,
  allSelected: false,
  enterSelectMode: () => {},
  exitSelectMode: () => {},
  toggleSelection: () => {},
  toggleSelectAll: () => {},
  setSelection: () => {},
  registerSelectableIds: () => {},
}

export const ConversationSelectionContext = createContext<ConversationSelection>(INERT_SELECTION)

export function useConversationSelection(): ConversationSelection {
  return useContext(ConversationSelectionContext)
}

function sameIds(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((id, index) => id === b[index])
}

/**
 * Drops selected ids the list no longer offers — archived elsewhere, filtered
 * out, or removed by a sync (iOS subtracts the same removed ids in
 * ConversationListViewModel). Returns the input set unchanged when nothing was
 * pruned so the identity check keeps React from re-rendering.
 */
function pruneSelection(
  selected: ReadonlySet<string>,
  loaded: readonly string[],
): ReadonlySet<string> {
  if (selected.size === 0) return selected
  const available = new Set(loaded)
  const kept = [...selected].filter((id) => available.has(id))
  return kept.length === selected.size ? selected : new Set(kept)
}

/** Owns the selection state; the pane publishes it through the context above. */
export function useConversationSelectionState(): ConversationSelection {
  const [selecting, setSelecting] = useState(false)
  const [selectedIds, setSelectedIds] = useState<ReadonlySet<string>>(EMPTY_SELECTION)
  const [selectableIds, setSelectableIds] = useState<readonly string[]>([])

  const enterSelectMode = useCallback(() => {
    setSelecting(true)
  }, [])

  const exitSelectMode = useCallback(() => {
    setSelecting(false)
    setSelectedIds(EMPTY_SELECTION)
  }, [])

  const toggleSelection = useCallback((conversationId: string) => {
    setSelectedIds((current) => {
      const next = new Set(current)
      if (!next.delete(conversationId)) next.add(conversationId)
      return next
    })
  }, [])

  const setSelection = useCallback((conversationIds: readonly string[]) => {
    setSelectedIds(new Set(conversationIds))
  }, [])

  const registerSelectableIds = useCallback((conversationIds: readonly string[]) => {
    setSelectableIds((current) =>
      sameIds(current, conversationIds) ? current : [...conversationIds],
    )
    setSelectedIds((current) => pruneSelection(current, conversationIds))
  }, [])

  /**
   * Select All covers the rows the list has actually loaded, not the whole
   * mailbox: iOS passes `filteredConversationItems` — the paged window — to
   * selectAll, and toggles to a clear when the counts already match. Loading
   * another page therefore flips the control back to "Select All".
   */
  const toggleSelectAll = useCallback(() => {
    setSelectedIds((current) =>
      current.size === selectableIds.length ? EMPTY_SELECTION : new Set(selectableIds),
    )
  }, [selectableIds])

  // Escape leaves select mode — unless a modal dialog is open, which owns the
  // key for itself (the reader and compose both render a native <dialog>).
  useEffect(() => {
    if (!selecting) return
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      if (document.querySelector('dialog[open]') !== null) return
      exitSelectMode()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [selecting, exitSelectMode])

  return useMemo(
    () => ({
      selecting,
      selectedIds,
      selectedCount: selectedIds.size,
      selectableCount: selectableIds.length,
      allSelected: selectableIds.length > 0 && selectedIds.size === selectableIds.length,
      enterSelectMode,
      exitSelectMode,
      toggleSelection,
      toggleSelectAll,
      setSelection,
      registerSelectableIds,
    }),
    [
      selecting,
      selectedIds,
      selectableIds,
      enterSelectMode,
      exitSelectMode,
      toggleSelection,
      toggleSelectAll,
      setSelection,
      registerSelectableIds,
    ],
  )
}
