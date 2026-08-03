import { cn } from '@/lib/cn'

/** Shimmering placeholder block. */
export function Skeleton({ className }: { className?: string }) {
  return (
    <div
      aria-hidden
      className={cn('animate-pulse rounded-lg bg-bg-elev motion-reduce:animate-none', className)}
    />
  )
}
