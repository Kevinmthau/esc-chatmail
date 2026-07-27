# Inbox Chat — Web

A web-native version of the esc-chatmail iOS app: a chat-style Gmail client that
renders email as iMessage-like conversations. Client-only PWA — the browser
talks to the Gmail REST API directly; all mail data stays on-device in
IndexedDB. There is no backend.

## Stack

React 19 · Vite · TypeScript (strict) · TanStack Router · Tailwind CSS v4 ·
Dexie (IndexedDB) · Google Identity Services (OAuth) · Vitest + MSW + fake-indexeddb

## Getting started

```bash
cd web
corepack pnpm install
corepack pnpm dev        # http://localhost:5173
```

With no OAuth client configured the app boots in **demo mode** (local fixture
data, no Google account needed). To connect a real Gmail account, create an
OAuth client:

### Creating the OAuth client (one-time)

1. Open [console.cloud.google.com](https://console.cloud.google.com) and select
   the project **esc-gmail-client** (the same project the iOS app uses — the
   consent screen and Gmail API are already configured).
2. APIs & Services → Credentials → **Create Credentials → OAuth client ID**.
3. Application type: **Web application**. Name: `esc-chatmail-web`.
4. Authorized JavaScript origins: `http://localhost:5173` and
   `http://127.0.0.1:5173` (add your production origin later).
   **No redirect URIs** — the GIS token model uses a popup, not redirects.
5. Create, copy the client ID, and paste it into [`.env`](.env) as
   `VITE_GOOGLE_CLIENT_ID`.

Notes:

- `gmail.modify` is a **restricted** scope. Keep the consent screen in
  _Testing_ mode with your account added as a test user — that avoids Google's
  security assessment. Tokens in Testing mode expire after 7 days of inactivity.
- Origin changes in the console can take a few minutes to propagate.
- The client ID is public by nature (it appears in every token request), which
  is why `.env` is committed — same precedent as the iOS
  `Configuration/Debug.xcconfig`.

## Commands

```bash
corepack pnpm dev            # dev server (strict port 5173)
corepack pnpm test           # vitest run
corepack pnpm typecheck      # tsr generate && tsc -b
corepack pnpm lint           # eslint, zero warnings allowed
corepack pnpm format         # prettier --write
corepack pnpm build          # typecheck + production build to dist/
```

## Architecture

```
src/
├── auth/        GIS token lifecycle (epoch guard, single-flight refresh)
├── gmail/       REST client: authed fetch, unified retry engine, endpoints
├── db/          Dexie schema — one database per account
├── identity/    participant-set conversation keying (the product's core:
│                chats are keyed by WHO, not by Gmail thread)
├── mime/        Gmail payload parsing, quote-stripping, newsletter scoring
├── rollup/      derived conversation state (snippet, unread counts, archive)
├── sync/        initial backfill + incremental history sync + reconciliation
├── outbox/      durable pending-action queue, optimistic send journal, the
│                RFC-2822 MIME builder, and outbound attachment staging
│                (downscale → 25 MB cap → local rows + blobs)
├── live/        Dexie liveQuery layer consumed by the UI
├── features/    conversations · chat · compose · reader · attachments · auth
├── components/  UI primitives (Avatar, Modal, Menu, …)
└── routes/      TanStack Router file routes (split view: list ⇄ chat)
```

Behavioral parity with the iOS app is enforced by importing the iOS golden test
corpus directly (`../esc-chatmailTests/TestSupport/Fixtures/golden_message_corpus.json`)
— quote-stripping, bubble text, newsletter detection, snippet selection, and
display-policy routing all run against the same fixtures as the Swift code.

## Security model for email HTML

Email HTML is sanitized with DOMPurify, then rendered inside
`public/email-frame.html` — a dedicated viewer document loaded in an iframe
with `sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"`
(opaque origin, no `allow-same-origin`) and its own strict CSP. Inline `cid:`
images are transferred as Blobs via `postMessage` and object URLs are minted
inside the frame. The app document's CSP never widens for email content.
