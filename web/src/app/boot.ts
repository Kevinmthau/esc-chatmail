// App bootstrap singleton.
//
// Owns the auth broker + per-account session lifecycle for the whole app:
//   - Real mode: create the GIS auth broker (session restore happens in its
//     constructor), and whenever the broker reaches 'ready', establish the
//     account session — open the per-account Dexie DB, request persistent
//     storage, register the sign-out wipe hook, replay crashed optimistic
//     sends, start the outbox auto-drain, and start the sync scheduler.
//   - Demo mode (no OAuth client id configured): open a local demo DB, seed
//     it with fixtures once, and report the 'demo' auth state — the app then
//     behaves fully locally with no network.
//
// The published `useAuthState()` value only reports 'ready'/'demo' AFTER the
// account DB is open, so any component that calls getDB() renders safely.
// The same invariant holds for every state that renders the main app:
// 'needs_interaction'/'authorizing' are remapped to 'signed_out' (the sign-in
// screen) whenever no account DB is open.

import { useSyncExternalStore } from 'react'
import {
  AuthRequiredError,
  createGisAuthBroker,
  type AuthBroker,
  type AuthState,
} from '@/auth/authBroker'
import { getSyncProgress, setSyncProgress } from '@/db/kv'
import {
  dbNameForAccount,
  deleteDBForAccount,
  getDB,
  openDBForAccount,
  type ChatmailDB,
} from '@/db/schema'

export const DEMO_ACCOUNT_EMAIL = 'demo@example.com'

/** 'unknown' = boot in progress; 'demo' = local fixture mode (no OAuth client). */
export type AppAuthState = 'unknown' | 'demo' | AuthState

// ---------------------------------------------------------------------------
// Config / test overrides
// ---------------------------------------------------------------------------

export interface BootOverrides {
  /** Overrides import.meta.env.VITE_GOOGLE_CLIENT_ID (null = unset). */
  clientId?: string | null
  /** Overrides createGisAuthBroker (lets tests inject a fake broker). */
  createBroker?: () => AuthBroker
}

let overrides: BootOverrides | null = null

export function setBootOverridesForTests(next: BootOverrides | null): void {
  overrides = next
}

function configuredClientId(): string | null {
  if (overrides !== null && 'clientId' in overrides) return overrides.clientId ?? null
  const env: Record<string, unknown> = import.meta.env
  const id = env['VITE_GOOGLE_CLIENT_ID']
  return typeof id === 'string' ? id : null
}

/** Demo mode: no usable OAuth client id → fully local fixture-backed app. */
export function isDemoMode(): boolean {
  const id = configuredClientId()
  return id === null || id.trim() === '' || id.startsWith('REPLACE_ME')
}

// ---------------------------------------------------------------------------
// Published auth state (useSyncExternalStore-compatible)
// ---------------------------------------------------------------------------

let appState: AppAuthState = 'unknown'
const listeners = new Set<() => void>()

function publish(next: AppAuthState): void {
  if (appState === next) return
  appState = next
  for (const listener of [...listeners]) listener()
}

export function subscribeAuthState(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getAuthState(): AppAuthState {
  return appState
}

/** The app-level auth state; 'demo' in demo mode, broker state otherwise. */
export function useAuthState(): AppAuthState {
  return useSyncExternalStore(subscribeAuthState, getAuthState, getAuthState)
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

interface BootSession {
  email: string
  /** Teardown functions (scheduler stop, auto-drain stop, actions unbind). */
  stops: Array<() => void>
  unregisterWipe: () => void
}

let broker: AuthBroker | null = null
let bootPromise: Promise<void> | null = null
let session: BootSession | null = null
let sessionStarting = false
/**
 * Session generation. Bumped by every teardown and every establishSession, so
 * work started under an older generation (a half-finished establishSession, a
 * sync closure captured by a stopped scheduler) can detect that it is stale
 * and abandon itself instead of writing to whatever DB happens to be open.
 */
let sessionGeneration = 0
/**
 * Wipe hook left registered by a torn-down session. signOut() publishes
 * signed_out (→ teardown) BEFORE running wipe hooks, so the hook must stay
 * registered through teardown; it is only unregistered when a new session
 * registers its own.
 */
let staleWipeUnregister: (() => void) | null = null

/** Idempotent app bootstrap. Safe to call from every render entry point. */
export function startBoot(): Promise<void> {
  bootPromise ??= boot()
  return bootPromise
}

async function boot(): Promise<void> {
  if (isDemoMode()) {
    await startDemo()
    return
  }
  await waitForGis()
  let created: AuthBroker
  try {
    created = (overrides?.createBroker ?? createGisAuthBroker)()
  } catch {
    // GIS script unavailable (offline, blocked, or slow past the timeout).
    // signIn() retries broker creation on the next user gesture.
    startOfflineFallback()
    return
  }
  adoptBroker(created)
}

/**
 * No auth broker (the cross-origin GIS script did not load). The mailbox is
 * local and needs no network to read, so open the last account's DB and show
 * the app under the session-expired banner instead of a sign-in screen that
 * cannot work either. Local mutations still queue in the outbox; they drain
 * once a broker exists.
 *
 * This path authenticates NOBODY, so it is gated on evidence that the same
 * user is still present: the durable session-evidence marker, written at
 * establishSession with the grant's own expiry. Offline WITH a live session is
 * fine (a reload, a relaunched PWA, a blocked GIS script); offline with no
 * session — the token's horizon lapsed, or the account was never established
 * on this origin — must show the sign-in screen rather than hand the next
 * person to open the browser a full mailbox UI. With no remembered account
 * there is nothing to show either.
 */
function startOfflineFallback(): void {
  const email = readLastAccountEmail()
  if (email === null || !hasLiveSessionEvidence()) {
    publish('signed_out')
    return
  }
  try {
    openDBForAccount(email)
  } catch {
    publish('signed_out')
    return
  }
  publish('needs_interaction')
}

async function startDemo(): Promise<void> {
  const db = openDBForAccount(DEMO_ACCOUNT_EMAIL)
  const [{ seedFixturesOnce }, { configureDataActions }] = await Promise.all([
    import('@/data/fixtures'),
    import('@/data/actions'),
  ])
  configureDataActions(null, { demo: true })
  await seedFixturesOnce(db)
  publish('demo')
}

function adoptBroker(next: AuthBroker): void {
  broker = next
  next.subscribe(onBrokerState)
  onBrokerState(next.getState())
}

/** True when an account DB is open, i.e. getDB() will not throw. */
function hasOpenDB(): boolean {
  try {
    getDB()
    return true
  } catch {
    return false
  }
}

function onBrokerState(state: AuthState): void {
  if (state === 'ready') {
    if (sessionStarting) return
    if (session !== null) {
      // A new grant landed while a session is already established (e.g. the
      // session-expired banner's Continue). GIS lets the user pick ANY Google
      // account in the popup and the token response carries no account
      // identity, so verify the grant's account before reusing the session.
      void verifySessionAccount()
    } else {
      // Stay 'unknown'/previous until the DB is open; establishSession publishes.
      void establishSession()
    }
    return
  }
  if (state === 'signed_out') teardownSession()
  if ((state === 'needs_interaction' || state === 'authorizing') && !hasOpenDB()) {
    // Without an open account DB the main app cannot render (every querier
    // calls getDB(), which throws), so these states must gate to the sign-in
    // screen — never the banner-over-chats UI.
    publish('signed_out')
    return
  }
  publish(state)
}

async function establishSession(knownEmail?: string): Promise<void> {
  const b = broker
  if (b === null) return
  sessionStarting = true
  // Every await below is a window in which the broker can sign out (including
  // a cross-tab broadcast) or another session can start. Nothing established
  // under a retired generation may be published or left running.
  const generation = ++sessionGeneration
  const current = (): boolean => b.getState() === 'ready' && sessionGeneration === generation
  // Declared outside the try so the catch path can also unwind whatever this
  // attempt already started (listeners, timers, broker bindings).
  const stops: Array<() => void> = []
  let unregisterWipe: (() => void) | null = null
  const bail = (): void => {
    abandonSession(stops, unregisterWipe)
  }
  try {
    // Identity may only come from a VERIFIED source: `knownEmail` (resolved by
    // verifySessionAccount from getProfile), or the broker's verified email
    // (set by setAccountEmail, and restored only from a record setAccountEmail
    // wrote). A login hint the user typed is deliberately NOT in that list —
    // getEmail() returns null while only a hint is known, so a first sign-in
    // always resolves the token's real account here.
    const email = knownEmail ?? b.getEmail() ?? (await fetchProfileEmail(b))
    if (!current()) return // signed out / expired / superseded mid-setup
    // Adopt the resolved account email so the broker's persisted session
    // record pairs the token with the account it actually belongs to. BEFORE
    // openDBForAccount: the DB is named after this value.
    b.setAccountEmail(email)

    const db = openDBForAccount(email)
    rememberAccountEmail(email)

    // Registered BEFORE any long await: signOut() runs its wipe hooks
    // synchronously after publishing signed_out, so a hook registered later
    // would be missed and the account's mail would survive the sign-out.
    staleWipeUnregister?.()
    staleWipeUnregister = null
    unregisterWipe = b.registerWipeHook(() => deleteDBForAccount(email))

    void requestPersistentStorage(db)
    await restoreBackfillWindowIfEvicted(db, email)
    if (!current()) return bail()

    // Outbox: bind the actions facade, replay crashed sends, drain on reconnect.
    const actions = await import('@/data/actions')
    if (!current()) return bail()
    actions.configureDataActions(b)
    stops.push(() => {
      actions.configureDataActions(null)
    })
    void actions.replayOutboundSends()
    // Drain the pending-action queue NOW, not only on the next 'online' event.
    // A queue stranded by an offline mutation or a token expiry outlives the
    // session it was queued in: on a cold start (or after a re-auth) 'online'
    // has already fired and never fires again, so without this the archive /
    // mark-read never reaches Gmail — and reconcileLabels skips those message
    // ids while the rows sit there, so nothing repairs the drift either.
    void actions.drainOutbox()
    stops.push(actions.startOutboxAutoDrain())

    // Attachment downloads (inline cid images in the reader, bubble attachments)
    // need an authed broker to hit the Gmail attachments endpoint.
    const [reader, download] = await Promise.all([
      import('@/features/reader/useEmailHtml'),
      import('@/features/attachments/download'),
    ])
    if (!current()) return bail()
    reader.setEmailAttachmentBroker(b)
    download.setAttachmentDownloadBroker(b)
    stops.push(() => {
      reader.setEmailAttachmentBroker(null)
      download.setAttachmentDownloadBroker(null)
    })

    // Sync: startup pass now, then the visibility/online/interval scheduler.
    const [{ startScheduler }, { runSync }, { makeGmailSyncApi }] = await Promise.all([
      import('@/sync/scheduler'),
      import('@/sync/engine'),
      import('@/sync/deps'),
    ])
    if (!current()) return bail()
    const api = makeGmailSyncApi(b)
    // The generation check makes the closure self-invalidating: a scheduler
    // tick (or an in-flight trigger) that fires after this session was torn
    // down must never run this account's sync against a DB/token that has
    // since changed hands.
    const doSync = (reason: Parameters<typeof runSync>[1]) => {
      if (sessionGeneration !== generation) return Promise.resolve({ ran: false })
      return runSync({ db: getDB(), api, accountEmail: email }, reason)
    }
    stops.push(startScheduler({ runSync: doSync }))
    void doSync('startup')

    if (!current()) return bail()
    session = { email, stops, unregisterWipe }
    cancelVerificationRetry()
    rememberSessionEvidence(b.getExpiresAt())
    publish('ready')
  } catch {
    // Could not establish the session (e.g. profile fetch failed with no
    // stored email). Unwind the half-built session, then: with an open DB,
    // surface needs_interaction so the banner's Continue re-runs sign-in; with
    // NO open DB the main app cannot render, so gate to the sign-in screen.
    bail()
    if (b.getState() === 'ready') publish(hasOpenDB() ? 'needs_interaction' : 'signed_out')
  } finally {
    sessionStarting = false
  }
}

/** Runs the teardowns collected so far by an establishSession that must bail. */
function abandonSession(stops: Array<() => void>, unregisterWipe: (() => void) | null): void {
  for (const stop of stops) {
    try {
      stop()
    } catch {
      // Best-effort.
    }
  }
  stops.length = 0
  // Hand the wipe hook to the same slot teardownSession uses: a sign-out in
  // flight must still find it, and the next session unregisters it.
  if (unregisterWipe !== null) staleWipeUnregister = unregisterWipe
}

/**
 * A new grant landed while a session is already established (e.g. the
 * session-expired banner's Continue, or a silent renewal that the broker
 * resolved against a different Google session). The grant may belong to a
 * DIFFERENT account than the open DB and its token is ALREADY live on the
 * broker, so the session is suspended before anything else: the scheduler,
 * outbox auto-drain and attachment brokers are stopped up front, and only
 * then is the account resolved.
 *   - match        → re-establish the same session (same DB, unchanged);
 *   - mismatch     → establishSession opens the other account's DB (the old
 *     one is closed, never wiped — it belongs to that account);
 *   - unverifiable → stay torn down under the banner, with a bounded automatic
 *     retry for transient failures (see resolveAccountAndEstablish).
 * Suspending FIRST is the invariant: while the account is unverified there
 * must be no worker that can run the new token against the open database.
 */
async function verifySessionAccount(): Promise<void> {
  const b = broker
  const s = session
  if (b === null || s === null) return
  sessionStarting = true
  // Stop the old session's workers BEFORE the profile round trip. The awaited
  // fetch below is a multi-second window (retries/backoff) during which a
  // scheduler tick or outbox drain would otherwise use the NEW, unverified
  // token against the OLD account's open DB.
  teardownSession()
  await resolveAccountAndEstablish(b, s.email)
}

/**
 * Resolves the grant's account and re-establishes a session on it. The session
 * is already torn down when this runs (see verifySessionAccount).
 *
 * A failure here is NOT necessarily terminal. Silent renewals notify on every
 * token swap, so this runs unattended roughly hourly — and the teardown that
 * precedes it removed the scheduler's interval/visibility/online triggers, the
 * outbox auto-drain and the actions broker. Publishing 'needs_interaction' and
 * stopping would therefore leave a valid, freshly renewed token behind a
 * "Session expired" banner with nothing left alive to recover: sync, drain,
 * refresh and send all dead until the user taps Continue. So a TRANSIENT
 * failure (offline, 5xx, 403 rateLimitExceeded, unknown transport error)
 * schedules a bounded retry — backoff plus the next 'online'/visible event —
 * while a DEFINITIVE one (an auth error: the grant itself is unusable) leaves
 * the banner as the only recovery, which is correct because only the user can
 * fix it.
 */
async function resolveAccountAndEstablish(b: AuthBroker, previousEmail: string): Promise<void> {
  sessionStarting = true
  try {
    const email = await fetchProfileEmail(b)
    if (b.getState() !== 'ready' || session !== null) return
    // Correct any stale login-hint in the broker + persisted record.
    b.setAccountEmail(email)
    if (email !== previousEmail) {
      // Different account granted: publish 'unknown' first so the DB-bound UI
      // unmounts before openDBForAccount closes the old DB underneath it.
      publish('unknown')
    }
    cancelVerificationRetry()
    sessionStarting = false
    await establishSession(email)
  } catch (err) {
    // Could not verify which account the token belongs to. The session is
    // already stopped; surface the banner so the user can retry.
    if (session === null && b.getState() === 'ready') {
      publish('needs_interaction')
      if (isTransientVerificationError(err)) scheduleVerificationRetry(b, previousEmail)
      else cancelVerificationRetry()
    }
  } finally {
    sessionStarting = false
  }
}

/**
 * Transient = the token may well be fine and a later attempt can succeed.
 * Definitive = the grant itself is unusable, so only a user gesture helps.
 *
 * Gmail's error classes are matched by name so this module keeps no static
 * import of the gmail layer (it is dynamically imported to stay out of the
 * initial bundle). Unknown/opaque failures count as transient: retrying a
 * profile GET is cheap, and the cost of misclassifying the other way is a
 * dead app behind a false banner.
 */
function isTransientVerificationError(err: unknown): boolean {
  if (err instanceof AuthRequiredError) return false
  if (!(err instanceof Error)) return true
  if (err.name === 'GmailApiError') {
    const status = (err as { status?: unknown }).status
    if (typeof status !== 'number') return true
    // 5xx, request timeout, and the 403 Gmail returns for
    // rateLimitExceeded/userRateLimitExceeded are all worth retrying.
    return status >= 500 || status === 403 || status === 408
  }
  // NetworkError, RateLimitError, and anything unrecognised.
  return true
}

/** Backoff ladder for unattended verification retries. */
const VERIFY_RETRY_DELAYS_MS = [2_000, 10_000, 30_000]
let verifyRetry: { cancel: () => void } | null = null
let verifyRetryAttempt = 0

function cancelVerificationRetry(): void {
  verifyRetry?.cancel()
  verifyRetry = null
  verifyRetryAttempt = 0
}

/**
 * Arms ONE retry of the account verification: whichever comes first of a
 * backoff timer, the browser coming back online, or the tab becoming visible.
 * Bounded by VERIFY_RETRY_DELAYS_MS — after that the banner is all that is
 * left, which is the pre-existing behaviour.
 */
function scheduleVerificationRetry(b: AuthBroker, previousEmail: string): void {
  verifyRetry?.cancel()
  verifyRetry = null
  const attempt = verifyRetryAttempt
  const delay = VERIFY_RETRY_DELAYS_MS[attempt]
  if (delay === undefined) return
  verifyRetryAttempt = attempt + 1

  let done = false
  let timer: ReturnType<typeof setTimeout> | null = null
  const cleanup = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
    window.removeEventListener('online', fire)
    if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisible)
  }
  function fire(): void {
    if (done) return
    done = true
    cleanup()
    verifyRetry = null
    // Anything that changed the world since (sign-out, a session established
    // by another path, a replaced broker) makes this retry meaningless.
    if (broker !== b || session !== null || b.getState() !== 'ready') return
    void resolveAccountAndEstablish(b, previousEmail)
  }
  function onVisible(): void {
    if (typeof document === 'undefined' || document.visibilityState === 'visible') fire()
  }

  timer = setTimeout(fire, delay)
  window.addEventListener('online', fire)
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisible)
  verifyRetry = {
    cancel: () => {
      done = true
      cleanup()
    },
  }
}

function teardownSession(): void {
  // Invalidate anything captured under the outgoing generation, even when no
  // session was established yet (an establishSession still in flight).
  sessionGeneration += 1
  cancelVerificationRetry()
  const s = session
  session = null
  if (s === null) return
  for (const stop of s.stops) {
    try {
      stop()
    } catch {
      // Teardown is best-effort.
    }
  }
  // Keep the wipe hook alive for the sign-out in progress (see declaration).
  staleWipeUnregister = s.unregisterWipe
}

async function fetchProfileEmail(b: AuthBroker): Promise<string> {
  const { getProfile } = await import('@/gmail/endpoints')
  const profile = await getProfile(b)
  return profile.emailAddress.trim().toLowerCase()
}

/**
 * Asks for durable storage and RECORDS the answer. Without persistence the
 * whole mailbox is evictable (Safari drops script-writable storage after 7
 * days of no interaction; Chrome evicts under pressure), so the outcome is
 * kept in syncProgress.storagePersistent where the UI can surface it.
 */
async function requestPersistentStorage(db: ChatmailDB): Promise<void> {
  try {
    const manager = navigator.storage as StorageManager | undefined
    if (manager === undefined) return
    const granted = (await manager.persisted?.()) || ((await manager.persist?.()) ?? false)
    const progress = await getSyncProgress(db)
    if (progress.storagePersistent === granted) return
    await setSyncProgress(db, { ...progress, storagePersistent: granted })
  } catch {
    // Persistence (and recording it) is best-effort.
  }
}

// ---------------------------------------------------------------------------
// Durable, non-evictable-by-intent markers
// ---------------------------------------------------------------------------

const LAST_ACCOUNT_STORAGE_KEY = 'esc.account.last.v1'
const INSTALL_MARKER_PREFIX = 'esc.account.installTs.v1.'
/**
 * Expiry (ms epoch) of the last established session's grant. Durable on
 * purpose: the token record itself lives in per-tab sessionStorage, so nothing
 * else survives a reload/relaunch to tell the auth-less offline fallback that
 * a real session existed here recently. Non-secret — it is a timestamp.
 */
const SESSION_EVIDENCE_STORAGE_KEY = 'esc.account.sessionUntil.v1'
/** Used when a grant reports no expiry; matches GIS's usual 1-hour token. */
const DEFAULT_SESSION_EVIDENCE_MS = 60 * 60 * 1000
/** Parity with iOS SyncConfig.initialSyncFallbackWindow (30 days). */
export const EVICTION_BACKFILL_WINDOW_MS = 30 * 24 * 60 * 60 * 1000

function durableStore(): Storage | null {
  try {
    return window.localStorage
  } catch {
    return null
  }
}

function durableGet(key: string): string | null {
  try {
    return durableStore()?.getItem(key) ?? null
  } catch {
    return null
  }
}

function durableSet(key: string, value: string): void {
  try {
    durableStore()?.setItem(key, value)
  } catch {
    // Best-effort (private mode, quota).
  }
}

/** Last established account, so a boot with no auth broker can still open it. */
function rememberAccountEmail(email: string): void {
  durableSet(LAST_ACCOUNT_STORAGE_KEY, email)
}

function readLastAccountEmail(): string | null {
  const value = durableGet(LAST_ACCOUNT_STORAGE_KEY)?.trim().toLowerCase()
  return value === undefined || value === '' ? null : value
}

function durableRemove(key: string): void {
  try {
    durableStore()?.removeItem(key)
  } catch {
    // Best-effort.
  }
}

function forgetLastAccountEmail(): void {
  durableRemove(LAST_ACCOUNT_STORAGE_KEY)
}

/** Records how long the just-established session's grant stays valid. */
function rememberSessionEvidence(expiresAt: number | null): void {
  const until =
    expiresAt !== null && Number.isFinite(expiresAt) && expiresAt > Date.now()
      ? expiresAt
      : Date.now() + DEFAULT_SESSION_EVIDENCE_MS
  durableSet(SESSION_EVIDENCE_STORAGE_KEY, String(until))
}

/**
 * True while the last established session's grant has not yet lapsed — the
 * only evidence an auth-less boot has that the same user is still around.
 * A lapsed marker is dropped so the check cannot be re-armed by clock skew.
 */
function hasLiveSessionEvidence(): boolean {
  const raw = durableGet(SESSION_EVIDENCE_STORAGE_KEY)
  const until = Number.parseInt(raw ?? '', 10)
  if (!Number.isFinite(until) || until <= Date.now()) {
    if (raw !== null) durableRemove(SESSION_EVIDENCE_STORAGE_KEY)
    return false
  }
  return true
}

function forgetSessionEvidence(): void {
  durableRemove(SESSION_EVIDENCE_STORAGE_KEY)
}

/**
 * Drops the durable install marker for an account whose database is being
 * deliberately destroyed. restoreBackfillWindowIfEvicted exists for a database
 * lost WITHOUT a sign-out; leaving the marker behind would make the next
 * sign-in look like an eviction and re-pull 30 days of mail into what the user
 * asked to be a clean slate (and leak one localStorage key per account).
 */
function forgetInstallMarker(email: string): void {
  durableRemove(INSTALL_MARKER_PREFIX + dbNameForAccount(email))
}

/**
 * Restores the initial-sync backfill floor when the account's database was
 * lost without a sign-out.
 *
 * The backfill window is `installTs - 5min` (sync/initial.ts initialSyncQuery)
 * and `installTs` is stamped `now` whenever the accounts row is CREATED
 * (sync/aliases.ts persistAccountAliases). So an evicted, cleared, or
 * upgrade-failed database silently reduces the user's entire mail history to
 * "the last five minutes" — with no way to get it back, because every other
 * sync path is floored by the same value.
 *
 * The fix is a durable marker outside the database (localStorage) holding the
 * ORIGINAL install timestamp, mirroring how iOS keeps `installTimestamp` in
 * UserDefaults rather than in the store. When the marker outlives the account
 * row we re-create the row with `historyId: ''` (→ a full initial sync) and
 * that timestamp, clamped to a 30-day window (iOS's
 * SyncConfig.initialSyncFallbackWindow) so the backfill stays bounded.
 * persistAccountAliases preserves both fields on an existing row, so the sync
 * that follows adopts the restored floor instead of stamping `now`.
 *
 * Limitation: a whole-origin eviction removes localStorage too, and then
 * nothing local survives to detect the loss — that case is why
 * requestPersistentStorage now records whether the origin got durable storage.
 */
async function restoreBackfillWindowIfEvicted(db: ChatmailDB, email: string): Promise<void> {
  const key = INSTALL_MARKER_PREFIX + dbNameForAccount(email)
  const marker = Number.parseInt(durableGet(key) ?? '', 10)
  const markerTs = Number.isFinite(marker) && marker > 0 ? marker : null
  const now = Date.now()

  let account: { installTs: number } | undefined
  try {
    account = await db.accounts.get(email)
  } catch {
    return // DB closed/deleted underneath us; nothing to restore.
  }

  if (account !== undefined) {
    // Keep the marker at the earliest install we know about.
    if (markerTs === null || account.installTs < markerTs)
      durableSet(key, String(account.installTs))
    return
  }
  if (markerTs === null) {
    // First run for this account on this origin: the sync creates the row.
    durableSet(key, String(now))
    return
  }
  try {
    await db.accounts.put({
      email,
      historyId: '',
      aliases: [],
      sendAsAliases: [],
      installTs: Math.max(markerTs, now - EVICTION_BACKFILL_WINDOW_MS),
      sendAsRefreshedAt: 0,
    })
  } catch {
    // Best-effort; a failed restore only means the default 5-minute floor.
  }
}

// ---------------------------------------------------------------------------
// UI entry points
// ---------------------------------------------------------------------------

/** User-gesture sign-in (sign-in card, session-expired banner). */
export async function signIn(loginHint?: string): Promise<void> {
  await startBoot()
  if (isDemoMode()) return
  let b = broker
  if (b === null) {
    // The GIS script may have loaded after boot gave up; retry now.
    b = (overrides?.createBroker ?? createGisAuthBroker)()
    adoptBroker(b)
  }
  // When the caller gave no hint but an account is already established, bind
  // the grant to it: without a login_hint, GIS lets the user pick ANY Google
  // account, and a foreign token must never be adopted onto this account's DB
  // (verifySessionAccount is the backstop when the accounts still differ).
  const hint = loginHint ?? session?.email ?? b.getLoginHint() ?? undefined
  await b.interactiveSignIn(hint)
}

/** Sign out; the broker's wipe hooks delete the account DB. */
export async function signOut(): Promise<void> {
  const b = broker
  // Forget the account BEFORE the DB goes away: otherwise the next boot's
  // offline fallback would re-open the just-wiped database.
  const remembered = session?.email ?? readLastAccountEmail()
  forgetLastAccountEmail()
  forgetSessionEvidence()
  // A sign-out is a clean slate, not an eviction (see forgetInstallMarker).
  if (remembered !== null) forgetInstallMarker(remembered)
  if (b !== null) {
    await b.signOut()
    return
  }
  // Offline fallback (no broker was ever created): honour the intent locally —
  // there is no grant to revoke, but the mailbox must still go.
  teardownSession()
  if (remembered !== null) await deleteDBForAccount(remembered)
  publish('signed_out')
}

/** Account email for display: session email, verified broker email, or demo. */
export function getAccountEmail(): string | null {
  if (isDemoMode()) return DEMO_ACCOUNT_EMAIL
  // getEmail() is the broker's VERIFIED identity — never a typed login hint,
  // which would otherwise display someone else's address as the signed-in
  // account. The remembered account is the last resort: it is the only
  // identity the offline fallback (no broker, no session) has for the DB it
  // just opened.
  return session?.email ?? broker?.getEmail() ?? readLastAccountEmail()
}

// ---------------------------------------------------------------------------
// GIS readiness
// ---------------------------------------------------------------------------

const GIS_POLL_MS = 50
const GIS_TIMEOUT_MS = 15_000
/**
 * Offline, the cross-origin GIS script can only arrive from the HTTP cache (it
 * is not — and cannot be — precached by the service worker), so give it a
 * short grace period instead of making an installed PWA stare at a spinner for
 * 15 seconds before it can show its local mailbox.
 */
const GIS_OFFLINE_TIMEOUT_MS = 2_000

async function waitForGis(): Promise<void> {
  if (overrides?.createBroker !== undefined) return
  const offline = typeof navigator !== 'undefined' && navigator.onLine === false
  const deadline = Date.now() + (offline ? GIS_OFFLINE_TIMEOUT_MS : GIS_TIMEOUT_MS)
  while (Date.now() < deadline) {
    if (window.google?.accounts?.oauth2 !== undefined) return
    await new Promise((resolve) => setTimeout(resolve, GIS_POLL_MS))
  }
}

// ---------------------------------------------------------------------------
// Test lifecycle
// ---------------------------------------------------------------------------

export function resetBootForTests(): void {
  teardownSession()
  cancelVerificationRetry()
  forgetLastAccountEmail()
  forgetSessionEvidence()
  staleWipeUnregister = null
  broker?.close()
  broker = null
  bootPromise = null
  sessionStarting = false
  appState = 'unknown'
  listeners.clear()
  overrides = null
}
