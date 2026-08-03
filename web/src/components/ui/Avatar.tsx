import { initials } from '@/lib/initials'
import { cn } from '@/lib/cn'

export type AvatarSize = 'standard' | 'bubble' | 'compact'

// Port of InitialsAvatarView.swift: purple gradient monogram circle.
// standard 44px/15px font (2-char single-word prefix), bubble 24px/10px,
// compact 20px/8px (1-char prefix).
const SIZE_CLASSES: Record<AvatarSize, string> = {
  standard: 'size-11 text-[15px]',
  bubble: 'size-6 text-[10px]',
  compact: 'size-5 text-[8px]',
}

export function Avatar({
  name,
  size = 'standard',
  className,
}: {
  name: string
  size?: AvatarSize
  className?: string
}) {
  return (
    <div
      aria-hidden
      className={cn(
        'flex shrink-0 select-none items-center justify-center rounded-full font-semibold text-white',
        'bg-gradient-to-b from-[#9BA3C7] to-[#6B74A6]',
        SIZE_CLASSES[size],
        className,
      )}
    >
      {initials(name, size === 'standard' ? 2 : 1)}
    </div>
  )
}
