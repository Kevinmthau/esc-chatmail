import * as RadixContextMenu from '@radix-ui/react-context-menu'
import type { ReactNode } from 'react'
import { cn } from '@/lib/cn'

const CONTENT_CLASSES =
  'z-50 min-w-44 rounded-xl border border-border bg-bg-elev p-1 shadow-lg motion-reduce:animate-none'

const ITEM_CLASSES =
  'flex cursor-default select-none items-center gap-2 rounded-lg px-3 py-2 text-sm outline-none ' +
  'data-[highlighted]:bg-accent data-[highlighted]:text-white data-[disabled]:opacity-40'

/** Right-click / long-press menu (bubbles, conversation rows). */
export function ContextMenu({ trigger, children }: { trigger: ReactNode; children: ReactNode }) {
  return (
    <RadixContextMenu.Root>
      <RadixContextMenu.Trigger asChild>{trigger}</RadixContextMenu.Trigger>
      <RadixContextMenu.Portal>
        <RadixContextMenu.Content className={CONTENT_CLASSES} collisionPadding={8}>
          {children}
        </RadixContextMenu.Content>
      </RadixContextMenu.Portal>
    </RadixContextMenu.Root>
  )
}

export function ContextMenuItem({
  onSelect,
  disabled,
  destructive,
  children,
}: {
  onSelect: () => void
  disabled?: boolean
  destructive?: boolean
  children: ReactNode
}) {
  return (
    <RadixContextMenu.Item
      className={cn(ITEM_CLASSES, destructive && 'text-danger data-[highlighted]:bg-danger')}
      disabled={disabled}
      onSelect={onSelect}
    >
      {children}
    </RadixContextMenu.Item>
  )
}
