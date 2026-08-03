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

function buildRouter(ui: ReactNode, initialPath: string) {
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
  return createRouter({
    routeTree,
    history: createMemoryHistory({ initialEntries: [initialPath] }),
  })
}

/** The RenderResult plus the router itself, for asserting on search params. */
export type RenderWithRouterResult = RenderResult & {
  router: ReturnType<typeof buildRouter>
}

export function renderWithRouter(ui: ReactNode, initialPath = '/chats'): RenderWithRouterResult {
  const router = buildRouter(ui, initialPath)
  return { ...render(<RouterProvider router={router} />), router }
}
