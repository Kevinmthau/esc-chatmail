// UI-facing data-actions facade: thin wrappers over the outbox module bound
// to the current account DB and auth broker. Components import from here so
// they never touch db/broker plumbing directly.
//
// Drain wiring: every local mutation that enqueues a pending action kicks a
// best-effort drain immediately; startOutboxAutoDrain() re-drains when the
// browser comes back online.

import { getDB, type ChatmailDB } from '@/db/schema'
import type { PersonRow } from '@/db/types'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { makeRecipientParticipantSetIdentity } from '@/identity/participantSet'
import { selectParticipantHashConversation } from '@/identity/routing'
import { newId } from '@/lib/uuid'
import * as messageActions from '@/outbox/messageActions'
import { drainPendingActions, makeOutboxApi } from '@/outbox/pendingActions'
import {
  replayAbandonedSends,
  retryFailedSend as retryFailedSendOutbox,
  sendMessage as sendMessageOutbox,
  SendFailedError,
  type SendDraft,
  type SendResult,
} from '@/outbox/send'

export type { SendDraft, SendResult }

/** Broker used by network-touching actions. null = signed out (they no-op/throw). */
let currentBroker: TokenBroker | null = null

/**
 * Demo mode (no OAuth client configured): sends run the real optimistic
 * pipeline against a stub transport that "commits" locally after a short
 * delay, so the whole send UX is exercisable without Google.
 */
let demoMode = false

/** Wires the facade to the app's auth broker (call at boot / sign-in / sign-out). */
export function configureDataActions(
  broker: TokenBroker | null,
  opts: { demo?: boolean } = {},
): void {
  currentBroker = broker
  demoMode = opts.demo ?? false
}

const demoStubBroker: TokenBroker = {
  getToken: () => Promise.resolve('demo-token'),
  refreshAfter: () => Promise.resolve('demo-token'),
}

function makeDemoSendApi(): Parameters<typeof sendMessageOutbox>[3] {
  return {
    api: {
      send: async () => {
        await new Promise((r) => setTimeout(r, 400))
        const suffix = newId().slice(0, 12)
        return { id: `demo-${suffix}`, threadId: `demo-thread-${suffix}` }
      },
    },
  }
}

function openDb(): ChatmailDB | null {
  try {
    return getDB()
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

export async function sendMessage(draft: SendDraft): Promise<SendResult> {
  const broker = currentBroker
  if (broker !== null) return sendMessageOutbox(getDB(), broker, draft)
  if (demoMode) return sendMessageOutbox(getDB(), demoStubBroker, draft, makeDemoSendApi())
  throw new SendFailedError('Not signed in')
}

/** Re-sends a failed message from its bubble (attachments and all). */
export async function retrySend(messageId: string): Promise<SendResult> {
  const broker = currentBroker
  if (broker !== null) return retryFailedSendOutbox(getDB(), broker, messageId)
  if (demoMode) {
    return retryFailedSendOutbox(getDB(), demoStubBroker, messageId, makeDemoSendApi())
  }
  throw new SendFailedError('Not signed in')
}

/** Startup recovery for crashed optimistic sends. No-ops without an open DB. */
export async function replayOutboundSends(): Promise<void> {
  const db = openDb()
  if (db === null) return
  await replayAbandonedSends(db)
}

// ---------------------------------------------------------------------------
// Local-first mutations (each kicks a best-effort drain)
// ---------------------------------------------------------------------------

export async function markConversationRead(conversationId: string): Promise<void> {
  await messageActions.markConversationRead(getDB(), conversationId)
  void drainOutbox()
}

export async function toggleConversationRead(conversationId: string): Promise<void> {
  await messageActions.toggleConversationRead(getDB(), conversationId)
  void drainOutbox()
}

export async function archiveConversation(conversationId: string): Promise<void> {
  await messageActions.archiveConversation(getDB(), conversationId)
  void drainOutbox()
}

export async function reportSpam(conversationId: string): Promise<void> {
  await messageActions.reportSpam(getDB(), conversationId)
  void drainOutbox()
}

// ---------------------------------------------------------------------------
// Lookups
// ---------------------------------------------------------------------------

/**
 * Finds the ACTIVE conversation epoch for a raw recipient list, or null.
 * Hashing goes through identity/participantSet (canonical — never local).
 */
export async function findConversationByParticipants(emails: string[]): Promise<string | null> {
  const db = getDB()
  const account = await db.accounts.toCollection().first()
  const myAliases: ReadonlySet<string> = new Set(account?.aliases ?? [])
  const setIdentity = makeRecipientParticipantSetIdentity(emails, myAliases)
  if (setIdentity === null) return null

  const candidates = await db.conversations
    .where('participantHash')
    .equals(setIdentity.participantHash)
    .toArray()
  const active = selectParticipantHashConversation(candidates, false)
  return active?.id ?? null
}

/** People search: email prefix (case-insensitive) plus display-name contains. */
export async function searchPeople(prefix: string, limit = 10): Promise<PersonRow[]> {
  const db = getDB()
  const query = prefix.trim().toLowerCase()
  if (query === '') return []

  const byEmail = await db.people.where('email').startsWithIgnoreCase(query).limit(limit).toArray()
  const seen = new Set(byEmail.map((person) => person.email))
  const byName = await db.people
    .filter((person) => !seen.has(person.email) && person.displayName.toLowerCase().includes(query))
    .limit(limit)
    .toArray()

  return [...byEmail, ...byName].slice(0, limit)
}

// ---------------------------------------------------------------------------
// Sync + outbox drain
// ---------------------------------------------------------------------------

/**
 * Requests a manual sync pass. No-ops cleanly when no broker/DB/account is
 * available. The sync engine is imported dynamically to keep it out of the
 * initial UI bundle.
 */
export async function requestSync(): Promise<void> {
  const broker = currentBroker
  const db = openDb()
  if (broker === null || db === null) return
  const account = await db.accounts.toCollection().first()
  if (account === undefined) return

  const [{ runSync }, { makeGmailSyncApi }] = await Promise.all([
    import('@/sync/engine'),
    import('@/sync/deps'),
  ])
  await runSync({ db, api: makeGmailSyncApi(broker), accountEmail: account.email }, 'manual')
}

/** Best-effort pending-action drain; errors are swallowed (retried later). */
export async function drainOutbox(): Promise<void> {
  const broker = currentBroker
  const db = openDb()
  if (broker === null || db === null) return
  try {
    await drainPendingActions(db, makeOutboxApi(broker))
  } catch {
    // Drain is opportunistic; the queue persists and will be retried.
  }
}

/** Drains whenever the browser comes back online. Returns a cleanup function. */
export function startOutboxAutoDrain(): () => void {
  const handler = (): void => {
    void drainOutbox()
  }
  window.addEventListener('online', handler)
  return () => {
    window.removeEventListener('online', handler)
  }
}
