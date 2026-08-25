import { useState, type FormEvent } from 'react'
import { signIn } from '@/app/boot'
import { AuthRequiredError } from '@/auth/authBroker'
import { Spinner } from './Spinner'

type SignInError = 'scope_denied' | 'generic'

/** Centered sign-in card: identity, optional login hint, Google sign-in. */
export function SignInCard() {
  const [hint, setHint] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<SignInError | null>(null)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (pending) return
    setPending(true)
    setError(null)
    try {
      const trimmed = hint.trim()
      await signIn(trimmed === '' ? undefined : trimmed)
    } catch (err) {
      setError(
        err instanceof AuthRequiredError && err.reason === 'scope_denied'
          ? 'scope_denied'
          : 'generic',
      )
    } finally {
      setPending(false)
    }
  }

  return (
    <div className="bg-bg-elev w-full max-w-sm rounded-2xl p-8 text-center shadow-sm">
      <div className="bg-accent mx-auto flex size-14 items-center justify-center rounded-2xl text-white">
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
          className="size-7"
        >
          <rect x="3" y="5" width="18" height="14" rx="2" />
          <path d="m3 7 9 6 9-6" />
        </svg>
      </div>
      <h1 className="mt-4 text-2xl font-semibold">MushMail</h1>
      <p className="text-fg-muted mt-1 text-sm">A chat-style Gmail client</p>

      <form className="mt-6 text-left" onSubmit={(event) => void submit(event)}>
        <label htmlFor="signin-email" className="text-fg-muted block text-xs font-medium">
          Email (optional)
        </label>
        <input
          id="signin-email"
          type="email"
          autoComplete="email"
          placeholder="you@gmail.com"
          value={hint}
          onChange={(event) => setHint(event.target.value)}
          className="border-border bg-bg focus:outline-accent mt-1 w-full rounded-lg border px-3 py-2 text-sm focus:outline-2"
        />
        <button
          type="submit"
          disabled={pending}
          className="bg-accent mt-4 flex w-full items-center justify-center gap-2 rounded-lg px-4 py-2.5 font-medium text-white active:opacity-70 disabled:opacity-40"
        >
          {pending && <Spinner className="size-4" />}
          {pending ? 'Waiting for Google…' : 'Continue with Google'}
        </button>
      </form>

      {error !== null && (
        <p role="alert" className="text-danger mt-4 text-sm">
          {error === 'scope_denied'
            ? 'Gmail access was not granted. MushMail needs the Gmail permission to show and send your mail — try again and allow Gmail access on the consent screen.'
            : 'Sign-in did not complete. Please try again.'}
        </p>
      )}
    </div>
  )
}
