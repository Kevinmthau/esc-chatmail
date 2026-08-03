import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { cn } from '@/lib/cn'

interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  /** Required — icon-only buttons must name themselves for assistive tech. */
  'aria-label': string
  children: ReactNode
}

/** 44px-hit-target icon button. */
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { className, children, type, ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type ?? 'button'}
      className={cn(
        'flex size-11 items-center justify-center rounded-full text-accent',
        'hover:bg-bg-elev active:opacity-70 disabled:opacity-40',
        'focus-visible:outline-2 focus-visible:outline-accent',
        className,
      )}
      {...rest}
    >
      {children}
    </button>
  )
})
