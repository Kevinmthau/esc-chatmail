/// <reference types="vitest/config" />
import { fileURLToPath } from 'node:url'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { VitePWA } from 'vite-plugin-pwa'

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url))

export default defineConfig({
  plugins: [
    tanstackRouter({ target: 'react', autoCodeSplitting: true }),
    react(),
    tailwindcss(),
    VitePWA({
      // There is no installed user base to protect, so updates apply without
      // asking: a new deploy's worker skips waiting and the page reloads onto
      // it (registerServiceWorker), even mid-send. Go back to 'prompt' with a
      // reload toast once the app has real users.
      registerType: 'autoUpdate',
      // Manifest icons are precached automatically; the tab favicon is not,
      // and without this an offline launch shows no tab icon.
      includeAssets: ['icons/favicon-32.png'],
      manifest: {
        name: 'MushMail',
        short_name: 'MushMail',
        description: 'A chat-style Gmail client',
        id: '/',
        start_url: '/',
        display: 'standalone',
        background_color: '#ffffff',
        theme_color: '#007aff',
        icons: [
          { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          {
            src: '/icons/maskable-512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        navigateFallback: '/index.html',
        // The email viewer document must always be served as itself, never the
        // SPA shell.
        navigateFallbackDenylist: [/^\/email-frame\.html/],
        // Never cache Gmail API responses: mail data lives in Dexie, and cached
        // authed responses would be a liability. The SW is a dumb shell cache.
        runtimeCaching: [
          {
            urlPattern: /^https:\/\/gmail\.googleapis\.com\//,
            handler: 'NetworkOnly',
          },
        ],
      },
    }),
  ],
  resolve: {
    alias: {
      '@': r('./src'),
      // The iOS golden test corpus is the single source of truth for MIME/preview
      // parity — imported directly, never copied.
      '@fixtures': r('../esc-chatmailTests/TestSupport/Fixtures'),
    },
  },
  server: {
    strictPort: true,
    port: 5173,
    fs: { allow: ['.', '../esc-chatmailTests/TestSupport/Fixtures'] },
  },
  test: {
    environment: 'happy-dom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    restoreMocks: true,
  },
})
