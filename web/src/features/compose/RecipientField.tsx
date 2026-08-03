import { useEffect, useId, useState, type KeyboardEvent, type ChangeEvent } from 'react'
import { searchPeople } from '@/data/actions'
import type { PersonRow } from '@/db/types'
import { RecipientAutocomplete } from './RecipientAutocomplete'
import { RecipientChip } from './RecipientChip'
import {
  addChip,
  autocompleteOptionId,
  hasChipSeparator,
  isValidRecipient,
  splitOnChipSeparators,
  splitRecipientSegment,
  type RecipientChipData,
} from './recipients'

export const AUTOCOMPLETE_DEBOUNCE_MS = 150
export const AUTOCOMPLETE_LIMIT = 8

/**
 * "To:" row — wrapping chips + inline combobox input with people autocomplete
 * (port of iOS RecipientInputSection). Commit rules: ',' or ';' (handled in
 * onChange so IME/paste input works too) or Enter commits the typed text;
 * blur commits only valid text; Backspace on an empty input removes the last
 * chip. Each committed segment is expanded by splitRecipientSegment, so an
 * Outlook-style paste ('a@b.com; c@d.com' or space-joined) becomes several
 * valid chips instead of one chip the MIME builder would reject. Invalid
 * chips are kept, tinted danger, and excluded from send by the model layer.
 */
export function RecipientField({
  chips,
  onChipsChange,
  disabled = false,
}: {
  chips: readonly RecipientChipData[]
  onChipsChange: (chips: RecipientChipData[]) => void
  disabled?: boolean
}) {
  const inputId = useId()
  const listId = `${inputId}-listbox`
  const [text, setText] = useState('')
  const [results, setResults] = useState<PersonRow[]>([])
  const [highlight, setHighlight] = useState(-1)
  const [focused, setFocused] = useState(false)
  const [suppressed, setSuppressed] = useState(false)
  const [announcement, setAnnouncement] = useState('')

  const showList = focused && !suppressed && results.length > 0

  // Debounced people search; already-chipped addresses are filtered out.
  useEffect(() => {
    const query = text.trim()
    if (query === '') {
      setResults([])
      setHighlight(-1)
      return
    }
    let stale = false
    const timer = setTimeout(() => {
      searchPeople(query, AUTOCOMPLETE_LIMIT)
        .then((people) => {
          if (stale) return
          const chipped = new Set(chips.map((chip) => chip.normalized))
          setResults(people.filter((person) => !chipped.has(person.email)))
          setHighlight(-1)
        })
        .catch(() => {
          // No DB / transient failure: just show no suggestions.
        })
    }, AUTOCOMPLETE_DEBOUNCE_MS)
    return () => {
      stale = true
      clearTimeout(timer)
    }
  }, [text, chips])

  const commitText = (raw: string, current: readonly RecipientChipData[]): RecipientChipData[] => {
    const { next, added, duplicate } = addChip(current, raw)
    if (added !== null) {
      setAnnouncement(
        added.valid ? `Added ${added.email}` : `Added ${added.email} — not a valid email address`,
      )
    } else if (duplicate) {
      setAnnouncement(`${raw.trim()} is already a recipient`)
    }
    return next
  }

  /** Commits one segment, expanding a multi-address paste into several chips. */
  const commitSegment = (
    raw: string,
    current: readonly RecipientChipData[],
  ): RecipientChipData[] => {
    let next: RecipientChipData[] = [...current]
    for (const address of splitRecipientSegment(raw)) next = commitText(address, next)
    return next
  }

  const selectPerson = (person: PersonRow): void => {
    onChipsChange(commitText(person.email, chips))
    setText('')
    setSuppressed(true)
  }

  const removeChip = (chip: RecipientChipData): void => {
    onChipsChange(chips.filter((existing) => existing.id !== chip.id))
    setAnnouncement(`Removed ${chip.email}`)
  }

  const handleChange = (event: ChangeEvent<HTMLInputElement>): void => {
    const value = event.target.value
    setSuppressed(false)
    if (!hasChipSeparator(value)) {
      setText(value)
      return
    }
    // Typed or pasted ',' / ';': commit every complete segment, keep the remainder.
    const parts = splitOnChipSeparators(value)
    const remainder = parts.pop() ?? ''
    let next: RecipientChipData[] = [...chips]
    for (const part of parts) next = commitSegment(part, next)
    onChipsChange(next)
    setText(remainder)
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key === 'Enter') {
      event.preventDefault()
      const highlighted = showList && highlight >= 0 ? results[highlight] : undefined
      if (highlighted !== undefined) {
        selectPerson(highlighted)
      } else if (text.trim() !== '') {
        onChipsChange(commitSegment(text, chips))
        setText('')
      }
      return
    }
    if (event.key === 'Backspace' && text === '' && chips.length > 0) {
      const last = chips[chips.length - 1]
      if (last !== undefined) removeChip(last)
      return
    }
    if (event.key === 'ArrowDown' && results.length > 0) {
      event.preventDefault()
      setSuppressed(false)
      setHighlight((index) => (index + 1) % results.length)
      return
    }
    if (event.key === 'ArrowUp' && results.length > 0) {
      event.preventDefault()
      setSuppressed(false)
      setHighlight((index) => (index <= 0 ? results.length - 1 : index - 1))
      return
    }
    if (event.key === 'Escape' && showList) {
      // Close the popover without letting Esc bubble up and close the dialog.
      event.preventDefault()
      event.stopPropagation()
      setSuppressed(true)
    }
  }

  const handleBlur = (): void => {
    setFocused(false)
    // Only commit text that is entirely sendable (a single address, or a
    // paste that expands into addresses); half-typed text stays in the input.
    const addresses = splitRecipientSegment(text)
    if (addresses.length > 0 && addresses.every((address) => isValidRecipient(address))) {
      onChipsChange(commitSegment(text, chips))
      setText('')
    }
  }

  return (
    <div className="flex items-start gap-2 border-b border-border px-4 py-2">
      <label htmlFor={inputId} className="pt-1 text-sm text-fg-muted">
        To:
      </label>
      <div className="relative flex min-w-0 flex-1 flex-wrap items-center gap-1">
        {chips.map((chip) => (
          <RecipientChip key={chip.id} chip={chip} onRemove={() => removeChip(chip)} />
        ))}
        <input
          id={inputId}
          type="text"
          role="combobox"
          aria-expanded={showList}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={
            showList && highlight >= 0 ? autocompleteOptionId(listId, highlight) : undefined
          }
          autoComplete="off"
          spellCheck={false}
          autoFocus
          disabled={disabled}
          value={text}
          onChange={handleChange}
          onKeyDown={handleKeyDown}
          onFocus={() => setFocused(true)}
          onBlur={handleBlur}
          className="min-w-24 flex-1 bg-transparent py-1 text-sm text-fg outline-none placeholder:text-fg-muted"
        />
        {showList && (
          <RecipientAutocomplete
            listId={listId}
            results={results}
            highlightIndex={highlight}
            onSelect={selectPerson}
            onHighlight={setHighlight}
          />
        )}
      </div>
      <span role="status" aria-live="polite" className="sr-only">
        {announcement}
      </span>
    </div>
  )
}
