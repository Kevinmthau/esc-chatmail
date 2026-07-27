import { Avatar } from './Avatar'
import { cn } from '@/lib/cn'

// Port of AvatarStackView.swift: group avatars arranged in a 44px frame —
// 2 = left/right, 3 = triangle, 4 = corners; 20px sub-avatars.
const LAYOUTS: Record<number, string[]> = {
  2: ['left-0 top-1/2 -translate-y-1/2', 'right-0 top-1/2 -translate-y-1/2'],
  3: ['left-1/2 top-0 -translate-x-1/2', 'bottom-0 left-0', 'bottom-0 right-0'],
  4: ['left-0 top-0', 'right-0 top-0', 'bottom-0 left-0', 'bottom-0 right-0'],
}

export function AvatarStack({ names, className }: { names: string[]; className?: string }) {
  if (names.length <= 1) {
    return <Avatar name={names[0] ?? '?'} className={className} />
  }
  const shown = names.slice(0, 4)
  const layout = LAYOUTS[Math.min(shown.length, 4)]!
  return (
    <div aria-hidden className={cn('relative size-11 shrink-0', className)}>
      {shown.map((name, i) => (
        <Avatar
          key={`${name}-${i}`}
          name={name}
          size="compact"
          className={cn('absolute ring-[1.5px] ring-bg', layout[i])}
        />
      ))}
    </div>
  )
}
