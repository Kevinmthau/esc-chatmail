import { createFileRoute } from '@tanstack/react-router'
import { ChatPane } from '@/features/chat/ChatPane'
import { ReaderDialog } from '@/features/reader/ReaderDialog'

type ChatSearch = {
  reader?: string
}

export const Route = createFileRoute('/chats/$conversationId')({
  validateSearch: (search: Record<string, unknown>): ChatSearch => ({
    reader: typeof search.reader === 'string' ? search.reader : undefined,
  }),
  component: ChatPage,
})

function ChatPage() {
  const { conversationId } = Route.useParams()
  const { reader } = Route.useSearch()
  return (
    <div className="flex h-dvh min-w-0 flex-1 flex-col">
      <ChatPane conversationId={conversationId} />
      <ReaderDialog messageId={reader} />
    </div>
  )
}
