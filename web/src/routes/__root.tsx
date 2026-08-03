import { Navigate, Outlet, createRootRoute, useLocation } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { signIn, startBoot, useAuthState } from '@/app/boot'
import { ReloadPrompt } from '@/app/ReloadPrompt'
import { Spinner } from '@/features/auth/Spinner'

export const Route = createRootRoute({
  component: RootLayout,
})

function RootLayout() {
  useEffect(() => {
    void startBoot()
  }, [])
  const auth = useAuthState()
  const pathname = useLocation({ select: (location) => location.pathname })
  const onSignin = pathname === '/signin'

  if (auth === 'unknown') {
    return (
      <div role="status" aria-label="Loading" className="flex h-dvh items-center justify-center">
        <Spinner className="text-fg-muted size-8" />
      </div>
    )
  }
  if (auth === 'signed_out' && !onSignin) return <Navigate to="/signin" replace />
  if ((auth === 'ready' || auth === 'demo') && onSignin) return <Navigate to="/chats" replace />

  const showExpiredBanner = auth === 'needs_interaction' || (auth === 'authorizing' && !onSignin)
  return (
    <>
      {showExpiredBanner && <SessionExpiredBanner />}
      <Outlet />
      <ReloadPrompt />
    </>
  )
}

/**
 * Non-modal overlay shown when the Google session needs a user gesture to
 * renew. The app stays fully usable underneath (local data is intact).
 */
function SessionExpiredBanner() {
  const [pending, setPending] = useState(false)

  const continueSignIn = async () => {
    setPending(true)
    try {
      await signIn()
    } catch {
      // Still needs interaction; the banner stays up for another attempt.
    } finally {
      setPending(false)
    }
  }

  return (
    <div
      role="alert"
      className="border-border bg-bg-elev fixed inset-x-0 top-0 z-50 flex items-center justify-center gap-3 border-b px-4 py-2 text-sm shadow-sm"
    >
      <span>Session expired</span>
      <button
        type="button"
        disabled={pending}
        onClick={() => void continueSignIn()}
        className="rounded-chip bg-accent px-3 py-1 font-medium text-white active:opacity-70 disabled:opacity-40"
      >
        {pending ? 'Signing in…' : 'Continue'}
      </button>
    </div>
  )
}
