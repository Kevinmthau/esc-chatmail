// Per-participantHash conversation-creation lock (port of
// ConversationCreationSerializer.swift). Uses the Web Locks API when available
// so the guarantee holds across tabs; falls back to an in-process FIFO mutex
// (a Map of promise chains) when navigator.locks is undefined (tests).

interface LockRequester {
  request: <T>(name: string, callback: () => Promise<T>) => Promise<T>
}

/** undefined = use the real navigator.locks; null = force the in-process fallback. */
let locksOverride: LockRequester | null | undefined

/** Test hook: pass null to force the fallback mutex, undefined to restore default. */
export function setLocksForTests(locks: LockRequester | null | undefined): void {
  locksOverride = locks
}

function currentLocks(): LockRequester | null {
  if (locksOverride !== undefined) return locksOverride
  // happy-dom exposes navigator.locks as null, so feature-detect the method.
  if (
    typeof navigator !== 'undefined' &&
    typeof (navigator.locks as LockManager | null | undefined)?.request === 'function'
  ) {
    return {
      // The runtime flattens the callback's promise; the lib typing does not,
      // so await the nested promise explicitly.
      request: async (name, callback) => await navigator.locks.request(name, () => callback()),
    }
  }
  return null
}

/** Tail of the pending chain per lock name. Entries are removed when drained. */
const chains = new Map<string, Promise<void>>()

async function withFallbackLock<T>(name: string, fn: () => Promise<T>): Promise<T> {
  const prev = chains.get(name) ?? Promise.resolve()
  let release!: () => void
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const tail = prev.then(() => gate)
  chains.set(name, tail)

  await prev
  try {
    return await fn()
  } finally {
    release()
    if (chains.get(name) === tail) chains.delete(name)
  }
}

/**
 * Runs `fn` while holding the exclusive conversation-creation lock for
 * `participantHash`. Later callers for the same hash wait for the active one
 * instead of racing through their own find-or-create.
 */
export function withConvoLock<T>(participantHash: string, fn: () => Promise<T>): Promise<T> {
  const name = `convo:${participantHash}`
  const locks = currentLocks()
  if (locks !== null) return locks.request(name, fn)
  return withFallbackLock(name, fn)
}
