// Recovery for a stale lazily-loaded chunk.
//
// Routes are code-split (autoCodeSplitting) and ComposeDialog is lazy(), so
// each is a separately hashed chunk fetched on first use. A new deploy's worker
// activates as soon as it installs (vite.config.ts registerType 'autoUpdate')
// and purges the old-hash chunks from the shared precache, and the host serves
// only the current deploy's assets. A page still running the old index.html
// (the reload onto the new build has not landed, or no worker controls it)
// fails its next first-time import — open Compose, first open of a chat route.
// Vite reports that as `vite:preloadError`; its documented recovery is a
// reload, which fetches the current index.html and matching chunks.

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
    // for the document; that must decline the reload, not escape the listener.
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

/**
 * True when no recovery reload is on record within the window; stamps this one.
 * The stamp has to survive the reload, because it is the only thing that bounds
 * the loop: a page with no usable storage would reload forever on a chunk that
 * stays broken, so it declines and lets the error surface instead.
 */
function claimReload(storage: Storage | undefined, at: number): boolean {
  if (storage === undefined) return false
  try {
    const last = Number.parseInt(storage.getItem(PRELOAD_ERROR_RELOAD_KEY) ?? '', 10)
    if (Number.isFinite(last) && at - last < PRELOAD_ERROR_RELOAD_WINDOW_MS) return false
    storage.setItem(PRELOAD_ERROR_RELOAD_KEY, String(at))
    return true
  } catch {
    return false
  }
}
