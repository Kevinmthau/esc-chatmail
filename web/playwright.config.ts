import { defineConfig, devices } from '@playwright/test'

// E2E smoke against a production build pinned to demo mode by .env.e2e (no
// OAuth client id → local fixture data, the full UI is exercisable). The build
// runs here rather than reusing `pnpm build` because that one is the real
// production artifact, client id and all, which boots to the login screen.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    // iPhone viewport/touch emulation, but on Chromium — only that browser is
    // installed locally and in CI.
    { name: 'mobile', use: { ...devices['iPhone 13'], browserName: 'chromium' } },
  ],
  webServer: {
    command: 'corepack pnpm build:e2e && corepack pnpm preview --port 4173 --strictPort',
    url: 'http://localhost:4173',
    // Never reuse a stray 4173: it may be serving a non-demo build, which
    // fails every test on a missing fixture rather than on anything real.
    reuseExistingServer: false,
    // Covers a full production build, not just server boot.
    timeout: 180_000,
  },
})
