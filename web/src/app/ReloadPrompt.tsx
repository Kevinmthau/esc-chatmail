import { useRegisterSW } from 'virtual:pwa-register/react'

/**
 * PWA update toast (registerType 'prompt'): a new service worker is waiting;
 * the user decides when to reload — never yanked mid-send.
 */
export function ReloadPrompt() {
  const {
    needRefresh: [needRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return
      // Long-lived tabs learn about updates on refocus and hourly.
      const check = () => void registration.update()
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') check()
      })
      setInterval(check, 60 * 60 * 1000)
    },
  })

  if (!needRefresh) return null
  return (
    <div
      role="status"
      className="border-border bg-bg-elev text-fg fixed bottom-4 left-1/2 z-50 flex -translate-x-1/2 items-center gap-3 rounded-2xl border px-4 py-2 text-sm shadow-lg"
    >
      <span>Update available</span>
      <button
        type="button"
        onClick={() => void updateServiceWorker(true)}
        className="rounded-chip bg-accent px-3 py-1 font-medium text-white active:opacity-70"
      >
        Reload
      </button>
    </div>
  )
}
