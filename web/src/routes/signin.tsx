import { createFileRoute } from '@tanstack/react-router'
import { SignInCard } from '@/features/auth/SignInCard'

export const Route = createFileRoute('/signin')({
  component: SignInPage,
})

function SignInPage() {
  return (
    <main className="flex h-dvh items-center justify-center p-4">
      <SignInCard />
    </main>
  )
}
