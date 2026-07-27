import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/chats/')({
  component: EmptyPane,
})

function EmptyPane() {
  return (
    <div className="text-fg-muted hidden flex-1 items-center justify-center md:flex">
      <p>Select a conversation</p>
    </div>
  )
}
