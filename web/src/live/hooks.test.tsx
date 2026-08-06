import { act, cleanup, renderHook } from '@testing-library/react'
import { Component, type ReactNode } from 'react'
import { afterEach, describe, expect, it } from 'vitest'
import { deleteDBForAccount, openDBForAccount, setDBForTests } from '@/db/schema'
import { useAccountLiveQuery, useSyncStatus } from './hooks'

const ACCOUNT = 'live-hook-test@example.com'
const REPLACEMENT_ACCOUNT = 'replacement-live-hook-test@example.com'
const queryErrors: Error[] = []

class QueryErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true }
  }

  componentDidCatch(error: Error): void {
    queryErrors.push(error)
  }

  render(): ReactNode {
    return this.state.failed ? null : this.props.children
  }
}

afterEach(async () => {
  cleanup()
  await deleteDBForAccount(ACCOUNT)
  await deleteDBForAccount(REPLACEMENT_ACCOUNT)
  setDBForTests(null)
  queryErrors.length = 0
})

describe('account live queries', () => {
  it('stays safely unresolved when the signed-out UI has no account database', async () => {
    setDBForTests(null)
    const { result } = renderHook(() => useSyncStatus(), { wrapper: QueryErrorBoundary })

    // liveQuery invokes its callback after subscribing; let that turn finish
    // so this checks for the render error, not merely the hook's initial value.
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)))

    expect(result.current).toBeUndefined()
    expect(queryErrors).toEqual([])
  })

  it('drops a result that resolves after the current account database changes', async () => {
    openDBForAccount(ACCOUNT)
    let resolveQuery!: (value: string) => void
    const pending = new Promise<string>((resolve) => {
      resolveQuery = resolve
    })

    const { result } = renderHook(() => useAccountLiveQuery(() => pending), {
      wrapper: QueryErrorBoundary,
    })
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)))

    openDBForAccount(REPLACEMENT_ACCOUNT)
    await act(async () => {
      resolveQuery('stale account data')
      await pending
    })

    expect(result.current).toBeUndefined()
    expect(queryErrors).toEqual([])
  })
})
