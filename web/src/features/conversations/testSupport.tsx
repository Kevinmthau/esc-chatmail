// Test-only render harness: mounts UI inside a minimal memory router whose
// route tree knows /chats and /chats/$conversationId, so <Link> hrefs resolve.
// Imported exclusively from *.test.tsx files.

import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from '@tanstack/react-router'
import { render, type RenderResult } from '@testing-library/react'
import type { ReactNode } from 'react'

export function renderWithRouter(ui: ReactNode, initialPath = '/chats'): RenderResult {
  const rootRoute = createRootRoute()
  const chatsRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: 'chats',
    component: () => <>{ui}</>,
  })
  const conversationRoute = createRoute({
    getParentRoute: () => chatsRoute,
    path: '$conversationId',
    component: () => null,
  })
  const routeTree = rootRoute.addChildren([chatsRoute.addChildren([conversationRoute])])
  const router = createRouter({
    routeTree,
    history: createMemoryHistory({ initialEntries: [initialPath] }),
  })
  return render(<RouterProvider router={router} />)
}
