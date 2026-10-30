// Recovery for a stale lazily-loaded chunk.
//
// Routes are code-split (autoCodeSplitting) and ComposeDialog is lazy(), so
// each is a separately hashed chunk fetched on first use. The service worker
// updates on prompt (vite.config.ts registerType) with no clientsClaim, so
// when one tab accepts an update the new worker purges the old-hash chunks
// from the shared precache while every other open tab stays controlled by the
// old worker and its old index.html. That tab's next first-time import — open
// Compose, first open of a chat route — misses the cache and 404s at the
// host, which serves only the current deploy's assets. Vite reports that as
// `vite:preloadError`; its documented recovery is a reload, which fetches the
// current index.html and matching chunks.

/** Where the last recovery reload was stamped; per tab, so tabs do not share one budget. */
export const PRELOAD_ERROR_RELOAD_KEY = 'esc.preloadError.reloadedAt.v1'
/**
 * A second preload error inside this window is not a stale deploy (the reload
 * just fetched the current one) but an outage or a broken build; reloading
 * again would loop forever. Let that error surface instead.
 */
export const PRELOAD_ERROR_RELOAD_WINDOW_MS = 60_000

export interface PreloadErrorRecoveryHost {
  addEventListener(type: 'vite:preloadError', listener: (event: Event) => void): void
  location: { reload(): void }
  sessionStorage?: Storage
}

export interface PreloadErrorRecoveryOptions {
  now?: () => number
}

/**
 * Installs the `vite:preloadError` handler: reloads once, and lets the error
 * through (Vite then throws it to the importer) when a reload already
 * happened inside PRELOAD_ERROR_RELOAD_WINDOW_MS.
 */
export function installPreloadErrorRecovery(
  host: PreloadErrorRecoveryHost,
  options: PreloadErrorRecoveryOptions = {},
): void {
  const now = options.now ?? (() => Date.now())
  host.addEventListener('vite:preloadError', (event) => {
    const at = now()
    // The sessionStorage GETTER itself throws when storage access is denied
    // for the document; a throw here would skip the reload entirely.
    let storage: Storage | undefined
    try {
      storage = host.sessionStorage
    } catch {
      storage = undefined
    }
    if (!claimReload(storage, at)) return
    // Prevents Vite from throwing the import error into the suspended route or
    // dialog, which would flash its error boundary for the instant before the
    // reload lands.
    event.preventDefault()
    host.location.reload()
  })
}

/** True when no recovery reload is on record within the window; stamps this one. */
function claimReload(storage: Storage | undefined, at: number): boolean {
  let last = Number.NaN
  try {
    last = Number.parseInt(storage?.getItem(PRELOAD_ERROR_RELOAD_KEY) ?? '', 10)
  } catch {
    // Storage unavailable (private mode): fall through and reload once per
    // page lifetime below.
  }
  if (Number.isFinite(last) && at - last < PRELOAD_ERROR_RELOAD_WINDOW_MS) return false
  if (storage === undefined) return claimInMemory()
  try {
    storage.setItem(PRELOAD_ERROR_RELOAD_KEY, String(at))
  } catch {
    return claimInMemory()
  }
  return true
}

let reloadedWithoutStorage = false

/**
 * Without usable storage the stamp cannot survive the reload, so the budget is
 * one reload per page lifetime: a reload that reproduces the error has a
 * fresh page and reloads once more, and a reload that fixes it is done.
 */
function claimInMemory(): boolean {
  if (reloadedWithoutStorage) return false
  reloadedWithoutStorage = true
  return true
}
