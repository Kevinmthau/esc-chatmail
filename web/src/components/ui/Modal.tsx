import { useEffect, useRef, type ReactNode } from 'react'
import { cn } from '@/lib/cn'

interface ModalProps {
  open: boolean
  onClose: () => void
  children: ReactNode
  /** 'center' = desktop dialog card; 'sheet' = mobile bottom sheet / full drawer. */
  variant?: 'center' | 'sheet'
  ariaLabel: string
  className?: string
}

/**
 * Native <dialog> wrapper: top layer, Esc handling, focus trap/restore and
 * ::backdrop come from the platform. Closing via Esc or backdrop click routes
 * through onClose so router-driven state stays in charge. Unmounting while
 * open (router removes the dialog's parent, e.g. compose after a successful
 * send) still runs close() and restores focus to the pre-open element — the
 * browser only restores focus for an explicit close(), never for removal.
 */
export function Modal({
  open,
  onClose,
  children,
  variant = 'center',
  ariaLabel,
  className,
}: ModalProps) {
  const ref = useRef<HTMLDialogElement>(null)
  const previouslyFocusedRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    const closeAndRestoreFocus = (): void => {
      dialog.close()
      const previous = previouslyFocusedRef.current
      previouslyFocusedRef.current = null
      if (previous !== null && previous.isConnected) previous.focus()
    }
    if (open && !dialog.open) {
      previouslyFocusedRef.current =
        document.activeElement instanceof HTMLElement ? document.activeElement : null
      dialog.showModal()
    }
    if (!open && dialog.open) closeAndRestoreFocus()
    return () => {
      if (dialog.open) closeAndRestoreFocus()
    }
  }, [open])

  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    const handleCancel = (e: Event) => {
      e.preventDefault()
      onClose()
    }
    const handleClick = (e: MouseEvent) => {
      if (e.target === dialog) onClose() // backdrop click
    }
    dialog.addEventListener('cancel', handleCancel)
    dialog.addEventListener('click', handleClick)
    return () => {
      dialog.removeEventListener('cancel', handleCancel)
      dialog.removeEventListener('click', handleClick)
    }
  }, [onClose])

  return (
    <dialog
      ref={ref}
      aria-label={ariaLabel}
      className={cn(
        'bg-bg text-fg backdrop:bg-black/40 m-auto rounded-2xl p-0 shadow-xl',
        variant === 'sheet' &&
          'mx-auto mb-0 mt-auto w-full max-w-none rounded-b-none md:m-auto md:w-auto md:max-w-2xl md:rounded-2xl',
        className,
      )}
    >
      {open ? children : null}
    </dialog>
  )
}
