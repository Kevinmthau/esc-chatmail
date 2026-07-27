import * as DropdownMenu from '@radix-ui/react-dropdown-menu'
import type { ReactNode } from 'react'
import { cn } from '@/lib/cn'

const CONTENT_CLASSES =
  'z-50 min-w-44 rounded-xl border border-border bg-bg-elev p-1 shadow-lg ' +
  'data-[state=open]:animate-in motion-reduce:animate-none'

const ITEM_CLASSES =
  'flex cursor-default select-none items-center gap-2 rounded-lg px-3 py-2 text-sm outline-none ' +
  'data-[highlighted]:bg-accent data-[highlighted]:text-white data-[disabled]:opacity-40'

export function Menu({ trigger, children }: { trigger: ReactNode; children: ReactNode }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>{trigger}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className={CONTENT_CLASSES} sideOffset={6} collisionPadding={8}>
          {children}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  )
}

export function MenuItem({
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
    <DropdownMenu.Item
      className={cn(ITEM_CLASSES, destructive && 'text-danger data-[highlighted]:bg-danger')}
      disabled={disabled}
      onSelect={onSelect}
    >
      {children}
    </DropdownMenu.Item>
  )
}
