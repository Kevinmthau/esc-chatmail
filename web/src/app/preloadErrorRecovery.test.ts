import { describe, expect, it, vi } from 'vitest'
import {
  PRELOAD_ERROR_RELOAD_KEY,
  PRELOAD_ERROR_RELOAD_WINDOW_MS,
  installPreloadErrorRecovery,
} from './preloadErrorRecovery'
import type { PreloadErrorRecoveryHost } from './preloadErrorRecovery'
import { memoryStorage } from './bootTestSupport'

// A tab still controlled by the old service worker after another tab accepted
// an update can no longer load its not-yet-fetched split chunks (the new
// worker purged them from the shared precache and the host serves only the
// current deploy). Vite raises `vite:preloadError`; the recovery is one
// reload, bounded so a broken deploy cannot reload forever.
//
// Revert-check: installPreloadErrorRecovery (and main.tsx's call to it).
// Without the handler no reload happens; without the window guard the
// second event inside the window reloads again.

function fakeHost(storage?: Storage) {
  let handler: ((event: Event) => void) | null = null
  const reload = vi.fn()
  const host: PreloadErrorRecoveryHost = {
    addEventListener: (_type, listener) => {
      handler = listener
    },
    location: { reload },
    ...(storage === undefined ? {} : { sessionStorage: storage }),
  }
  const fire = () => {
    const event = new Event('vite:preloadError', { cancelable: true })
    const preventDefault = vi.spyOn(event, 'preventDefault')
    if (handler === null) throw new Error('handler not installed')
    handler(event)
    return preventDefault
  }
  return { host, reload, fire }
}

describe('preload error recovery', () => {
  it('reloads once on a preload error and swallows the import error', () => {
    const storage = memoryStorage()
    const { host, reload, fire } = fakeHost(storage)
    let now = 1_000_000
    installPreloadErrorRecovery(host, { now: () => now })

    const preventDefault = fire()
    expect(reload).toHaveBeenCalledTimes(1)
    expect(preventDefault).toHaveBeenCalled()
    expect(storage.getItem(PRELOAD_ERROR_RELOAD_KEY)).toBe(String(now))

    // The same error right after the reload is not a stale deploy: let it
    // reach the importer instead of looping.
    now += 1_000
    const second = fire()
    expect(reload).toHaveBeenCalledTimes(1)
    expect(second).not.toHaveBeenCalled()

    // Past the window a new stale deploy is plausible again.
    now += PRELOAD_ERROR_RELOAD_WINDOW_MS
    fire()
    expect(reload).toHaveBeenCalledTimes(2)
  })

  it('honours a reload stamp left by the page before this one (same tab)', () => {
    const storage = memoryStorage()
    const now = 5_000_000
    storage.setItem(PRELOAD_ERROR_RELOAD_KEY, String(now - 2_000))
    const { host, reload, fire } = fakeHost(storage)
    installPreloadErrorRecovery(host, { now: () => now })

    const preventDefault = fire()
    expect(reload).not.toHaveBeenCalled()
    expect(preventDefault).not.toHaveBeenCalled()
  })

  it('without session storage reloads once per page lifetime', () => {
    const { host, reload, fire } = fakeHost()
    installPreloadErrorRecovery(host, { now: () => 0 })

    fire()
    fire()
    expect(reload).toHaveBeenCalledTimes(1)
  })

  // Revert-check: the try/catch around `host.sessionStorage` in
  // installPreloadErrorRecovery — a throwing getter (storage access denied for
  // the document) must take the in-memory one-reload path, not abort the handler.
  // A fresh module instance: the in-memory budget is per page lifetime and the
  // test above already spent this module's.
  it('reloads once when the sessionStorage getter itself throws', async () => {
    vi.resetModules()
    const fresh = await import('./preloadErrorRecovery')
    const { host, reload, fire } = fakeHost()
    Object.defineProperty(host, 'sessionStorage', {
      get() {
        throw new DOMException('Access is denied for this document.', 'SecurityError')
      },
    })
    fresh.installPreloadErrorRecovery(host, { now: () => 1_000_000 })

    const preventDefault = fire()
    expect(reload).toHaveBeenCalledTimes(1)
    expect(preventDefault).toHaveBeenCalled()
  })
})
