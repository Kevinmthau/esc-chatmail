import { Outlet, createFileRoute, useMatch, useNavigate } from '@tanstack/react-router'
import { Suspense, lazy } from 'react'
import { ConversationListPane } from '@/features/conversations/ConversationListPane'

const ComposeDialog = lazy(() =>
  import('@/features/compose/ComposeDialog').then((mod) => ({ default: mod.ComposeDialog })),
)

type ChatsSearch = {
  filter?: 'unread'
  compose?: boolean
  /** Message id being forwarded; opens the compose dialog in forward mode. */
  forward?: string
}

export const Route = createFileRoute('/chats')({
  validateSearch: (search: Record<string, unknown>): ChatsSearch => ({
    filter: search.filter === 'unread' ? 'unread' : undefined,
    compose: search.compose === true ? true : undefined,
    forward:
      typeof search.forward === 'string' && search.forward !== '' ? search.forward : undefined,
  }),
  component: ChatsLayout,
})

function ChatsLayout() {
  const childMatch = useMatch({ from: '/chats/$conversationId', shouldThrow: false })
  const childIsActive = childMatch !== undefined
  const { compose, forward } = Route.useSearch()
  const navigate = useNavigate()
  const closeCompose = (): void => {
    // Stay on the current leaf route; only drop the compose params.
    void navigate({
      to: '.',
      search: (prev) => ({ ...prev, compose: undefined, forward: undefined }),
    })
  }
  return (
    <div className="flex h-dvh">
      <aside
        className={
          // The list pane stays mounted across list<->chat navigation; CSS-only
          // visibility keeps its scroll position alive on mobile.
          'w-full flex-col md:flex md:w-[380px] md:shrink-0 md:border-r md:border-border ' +
          (childIsActive ? 'hidden md:flex' : 'flex')
        }
      >
        <ConversationListPane />
      </aside>
      <main className={'min-w-0 flex-1 ' + (childIsActive ? 'flex' : 'hidden md:flex')}>
        <Outlet />
      </main>
      {(compose === true || forward !== undefined) && (
        <Suspense fallback={null}>
          <ComposeDialog
            onClose={closeCompose}
            {...(forward !== undefined ? { forwardMessageId: forward } : {})}
          />
        </Suspense>
      )}
    </div>
  )
}
