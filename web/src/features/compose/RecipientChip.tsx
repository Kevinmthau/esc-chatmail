import { cn } from '@/lib/cn'
import type { RecipientChipData } from './recipients'

/**
 * A committed recipient pill. Valid chips use the accent tint; invalid ones
 * the danger tint (and are excluded from send by the model layer).
 */
export function RecipientChip({
  chip,
  onRemove,
}: {
  chip: RecipientChipData
  onRemove: () => void
}) {
  return (
    <span
      data-valid={chip.valid}
      className={cn(
        'flex max-w-full items-center gap-1 rounded-chip px-2.5 py-0.5 text-sm',
        chip.valid ? 'bg-accent/15 text-accent' : 'bg-danger/15 text-danger',
      )}
    >
      <span className="truncate">{chip.email}</span>
      <button
        type="button"
        aria-label={`Remove ${chip.email}`}
        onClick={onRemove}
        className="flex size-4 shrink-0 items-center justify-center rounded-full hover:bg-fg/10 focus-visible:outline-2 focus-visible:outline-accent"
      >
        <svg
          viewBox="0 0 12 12"
          className="size-2.5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          aria-hidden
        >
          <path d="M2.5 2.5l7 7M9.5 2.5l-7 7" />
        </svg>
      </button>
    </span>
  )
}
