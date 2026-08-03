import type { ReactNode } from 'react'
import { cn } from '@/lib/cn'

/** Translucent blurred bar chrome (the iOS "glass" bottom bar). */
export function GlassBar({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        'bg-glass border-border border-t backdrop-blur-xl',
        'pb-[env(safe-area-inset-bottom)]',
        className,
      )}
    >
      {children}
    </div>
  )
}
