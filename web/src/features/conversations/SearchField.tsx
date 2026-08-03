import { getRouteApi, useNavigate } from '@tanstack/react-router'
import { useCallback, useRef } from 'react'
import { cn } from '@/lib/cn'
import { ClearIcon, SearchIcon } from './icons'
import { useSearchDraft } from './useSearchDraft'

const chatsRoute = getRouteApi('/chats')

/**
 * The conversation-list search capsule (iOS ConversationListView.searchBar):
 * magnifier, plain text field, and a clear button once there is text.
 *
 * The committed query lives in the ?q= route param — absent, never '', the same
 * "absence means off" convention ?filter= uses — so it survives reload and comes
 * back with the list when you navigate out of a chat. Keystrokes reach the param
 * through a 150ms debounce (see useSearchDraft).
 */
export function SearchField({ className }: { className?: string }) {
  const { q } = chatsRoute.useSearch()
  const navigate = useNavigate()
  const inputRef = useRef<HTMLInputElement>(null)

  const commit = useCallback(
    (next: string) => {
      void navigate({
        // '.' keeps the current leaf route (the list on mobile, the open chat
        // on desktop) and only rewrites search — same move as FilterMenu.
        to: '.',
        search: (prev) => ({ ...prev, q: next === '' ? undefined : next }),
        // Replace rather than push: one history entry per debounced keystroke
        // would make Back retype the query backwards a fragment at a time.
        replace: true,
      })
    },
    [navigate],
  )

  const { draft, setDraft, clear } = useSearchDraft(q ?? '', commit)

  const clearAndFocus = useCallback(() => {
    clear()
    inputRef.current?.focus()
  }, [clear])

  return (
    <div
      className={cn(
        'bg-bg-elev focus-within:outline-accent flex items-center gap-2 rounded-chip px-3',
        'focus-within:outline-2 focus-within:-outline-offset-2',
        className,
      )}
    >
      <SearchIcon className="text-fg-muted size-4 shrink-0" />
      <input
        ref={inputRef}
        type="search"
        aria-label="Search conversations"
        placeholder="Search"
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key !== 'Escape') return
          // Clear on Escape but hold focus, so the next query starts typing
          // right away. preventDefault also suppresses the native type=search
          // reset, which would empty the input without telling React.
          event.preventDefault()
          clearAndFocus()
        }}
        className={cn(
          'placeholder:text-fg-muted min-w-0 flex-1 bg-transparent py-2 text-sm outline-none',
          // The native WebKit affordance would sit beside our own clear button.
          '[&::-webkit-search-cancel-button]:appearance-none',
        )}
      />
      {draft !== '' && (
        <button
          type="button"
          aria-label="Clear search"
          onClick={clearAndFocus}
          className="text-fg-muted hover:text-fg shrink-0 active:opacity-70"
        >
          <ClearIcon className="size-4" />
        </button>
      )}
    </div>
  )
}
