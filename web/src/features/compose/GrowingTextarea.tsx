import { useLayoutEffect, useRef, type KeyboardEvent } from 'react'

// Auto-growing message input. Local copy for the compose dialog: as of
// 2026-07-25 src/features/chat does not exist yet, so there is no shared
// GrowingTextarea to import. If the chat feature later exports one, swap this
// out for that export.

const MAX_HEIGHT_PX = 120

export function GrowingTextarea({
  value,
  onChange,
  onSubmit,
  placeholder = 'Message',
  disabled = false,
}: {
  value: string
  onChange: (value: string) => void
  /** Enter (without Shift) submits; Shift+Enter inserts a newline. */
  onSubmit?: () => void
  placeholder?: string
  disabled?: boolean
}) {
  const ref = useRef<HTMLTextAreaElement>(null)

  useLayoutEffect(() => {
    const el = ref.current
    if (el === null) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, MAX_HEIGHT_PX)}px`
  }, [value])

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>): void => {
    if (event.key === 'Enter' && !event.shiftKey && onSubmit !== undefined) {
      event.preventDefault()
      onSubmit()
    }
  }

  return (
    <textarea
      ref={ref}
      rows={1}
      value={value}
      placeholder={placeholder}
      aria-label="Message body"
      disabled={disabled}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={handleKeyDown}
      className="max-h-30 min-w-0 flex-1 resize-none rounded-bubble border border-border bg-bg px-3 py-1.5 text-[15px] text-fg outline-none placeholder:text-fg-muted focus:border-accent/50 disabled:opacity-60"
    />
  )
}
