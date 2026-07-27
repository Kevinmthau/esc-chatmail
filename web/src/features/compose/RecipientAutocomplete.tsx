import { Avatar } from '@/components/ui/Avatar'
import { cn } from '@/lib/cn'
import type { PersonRow } from '@/db/types'
import { autocompleteOptionId } from './recipients'

/**
 * Suggestion popover under the recipient input. Presentational: the field owns
 * the query, debounce, highlight index and keyboard handling.
 */
export function RecipientAutocomplete({
  listId,
  results,
  highlightIndex,
  onSelect,
  onHighlight,
}: {
  listId: string
  results: readonly PersonRow[]
  highlightIndex: number
  onSelect: (person: PersonRow) => void
  onHighlight: (index: number) => void
}) {
  if (results.length === 0) return null
  return (
    <ul
      id={listId}
      role="listbox"
      aria-label="Suggested people"
      className="absolute left-0 top-full z-10 mt-1 max-h-64 w-full min-w-64 overflow-y-auto rounded-card border border-border bg-bg py-1 shadow-lg"
    >
      {results.map((person, index) => (
        <li
          key={person.email}
          id={autocompleteOptionId(listId, index)}
          role="option"
          aria-selected={index === highlightIndex}
          className={cn(
            'flex cursor-pointer items-center gap-2 px-3 py-2',
            index === highlightIndex && 'bg-bg-elev',
          )}
          // preventDefault keeps focus in the input so blur-commit never races a click.
          onMouseDown={(event) => event.preventDefault()}
          onMouseEnter={() => onHighlight(index)}
          onClick={() => onSelect(person)}
        >
          <Avatar name={person.displayName || person.email} size="compact" />
          <span className="flex min-w-0 flex-col">
            {person.displayName !== '' && (
              <span className="truncate text-sm text-fg">{person.displayName}</span>
            )}
            <span className="truncate text-xs text-fg-muted">{person.email}</span>
          </span>
        </li>
      ))}
    </ul>
  )
}
