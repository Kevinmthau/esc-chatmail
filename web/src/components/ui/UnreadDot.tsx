import { cn } from '@/lib/cn'

/** Accent unread indicator: 10px in the list, 6px in bubbles. */
export function UnreadDot({
  size = 'list',
  className,
}: {
  size?: 'list' | 'bubble'
  className?: string
}) {
  return (
    <span
      aria-hidden
      className={cn(
        'inline-block shrink-0 rounded-full bg-accent',
        size === 'list' ? 'size-2.5' : 'size-1.5',
        className,
      )}
    />
  )
}
