import { registerSW } from 'virtual:pwa-register'

/**
 * Registers the shell-cache service worker (registerType 'autoUpdate'): a
 * newly deployed worker activates as soon as it installs and the page reloads
 * onto the new build, with no prompt.
 */
export function registerServiceWorker() {
  registerSW({
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
}
