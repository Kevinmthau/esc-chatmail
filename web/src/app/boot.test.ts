import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  AUTH_EPOCH_STORAGE_KEY,
  AUTH_SESSION_STORAGE_KEY,
  AUTH_SCOPES,
  AuthBroker,
  AuthRequiredError,
} from '@/auth/authBroker'
import type {
  AuthChannel,
  GisSurface,
  GisTokenClientConfig,
  GisTokenResponse,
  StoredAuthSession,
} from '@/auth/authBroker'
import { ChatmailDB, dbNameForAccount, deleteDBForAccount, getDB } from '@/db/schema'
import {
  DEMO_ACCOUNT_EMAIL,
  getAccountEmail,
  getAuthState,
  isDemoMode,
  resetBootForTests,
  setBootOverridesForTests,
  signIn,
  signOut,
  startBoot,
} from './boot'

// ---------------------------------------------------------------------------
// Network-module mocks (real-mode tests must never touch the network)
// ---------------------------------------------------------------------------

const { getProfileMock, runSyncMock, startSchedulerMock, drainPendingActionsMock } = vi.hoisted(
  () => ({
    getProfileMock: vi.fn(),
    runSyncMock: vi.fn(() => Promise.resolve({ ran: true })),
    startSchedulerMock: vi.fn(
      (_options: { runSync: (reason: 'manual' | 'startup') => Promise<unknown> }) => () => {},
    ),
    drainPendingActionsMock: vi.fn(() => Promise.resolve()),
  }),
)

vi.mock('@/gmail/endpoints', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/gmail/endpoints')>()),
  getProfile: getProfileMock,
}))
vi.mock('@/sync/engine', () => ({
  runSync: runSyncMock,
}))
vi.mock('@/sync/scheduler', () => ({
  startScheduler: startSchedulerMock,
}))
// Stubbed at the outbox boundary (not at the data/actions facade) so the drain
// under test runs through the real facade, broker binding and DB lookup.
vi.mock('@/outbox/pendingActions', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/outbox/pendingActions')>()),
  drainPendingActions: drainPendingActionsMock,
}))

describe('boot (demo mode)', () => {
  afterEach(async () => {
    resetBootForTests()
    await deleteDBForAccount(DEMO_ACCOUNT_EMAIL)
  })

  it('treats a missing or placeholder client id as demo mode', () => {
    setBootOverridesForTests({ clientId: null })
    expect(isDemoMode()).toBe(true)
    setBootOverridesForTests({ clientId: 'REPLACE_ME.apps.googleusercontent.com' })
    expect(isDemoMode()).toBe(true)
    setBootOverridesForTests({ clientId: '123-real.apps.googleusercontent.com' })
    expect(isDemoMode()).toBe(false)
  })

  it('boots into demo mode: opens the demo DB, seeds fixtures, publishes demo', async () => {
    setBootOverridesForTests({ clientId: null })
    await startBoot()

    expect(getAuthState()).toBe('demo')
    expect(await getDB().conversations.count()).toBe(12)

    // Idempotent: a second startBoot resolves without reseeding.
    await startBoot()
    expect(await getDB().conversations.count()).toBe(12)
  })
})

// ---------------------------------------------------------------------------
// Real-mode harness: a fake GIS surface driving a real AuthBroker
// ---------------------------------------------------------------------------

function memoryStorage(): Storage {
  const map = new Map<string, string>()
  return {
    get length() {
      return map.size
    },
    clear: () => {
      map.clear()
    },
    getItem: (key: string) => map.get(key) ?? null,
    key: (index: number) => [...map.keys()][index] ?? null,
    removeItem: (key: string) => {
      map.delete(key)
    },
    setItem: (key: string, value: string) => {
      map.set(key, value)
    },
  }
}

class FakeGis {
  time = 1_700_000_000_000
  storage = memoryStorage()
  pendingRequests: GisTokenClientConfig[] = []

  surface(): GisSurface {
    return {
      createTokenClient: (cfg) => ({
        requestAccessToken: () => {
          this.pendingRequests.push(cfg)
        },
      }),
      revoke: () => {},
      now: () => this.time,
      storage: this.storage,
    }
  }

  grantNext(overrides: Partial<GisTokenResponse> = {}): GisTokenClientConfig {
    const cfg = this.pendingRequests.shift()
    if (!cfg) throw new Error('no pending token request')
    cfg.callback({
      access_token: 'tok-default',
      expires_in: 3600,
      scope: AUTH_SCOPES,
      ...overrides,
    })
    return cfg
  }

  failNext(error = 'interaction_required'): void {
    const cfg = this.pendingRequests.shift()
    if (!cfg) throw new Error('no pending token request')
    cfg.callback({ error })
  }
}

function seedStoredSession(
  gis: FakeGis,
  opts: { email: string | null; accessToken?: string; expiresInMs?: number },
): void {
  const record: StoredAuthSession = {
    accessToken: opts.accessToken ?? 'tok-stored',
    expiresAt: gis.time + (opts.expiresInMs ?? 3_600_000),
    scope: AUTH_SCOPES,
    epoch: 0,
    email: opts.email,
  }
  gis.storage.setItem(AUTH_EPOCH_STORAGE_KEY, '0')
  gis.storage.setItem(AUTH_SESSION_STORAGE_KEY, JSON.stringify(record))
}

/** Boots real mode with a broker restored from `gis`'s stored session. */
function bootWithBroker(gis: FakeGis, createChannel: () => AuthChannel | null = () => null) {
  const broker = new AuthBroker(gis.surface(), {
    clientId: 'test-client-id',
    createChannel,
    verifyAccessToken: async () => {
      const profile = (await getProfileMock()) as { emailAddress: string }
      return profile.emailAddress
    },
  })
  setBootOverridesForTests({
    clientId: '123-real.apps.googleusercontent.com',
    createBroker: () => broker,
  })
  return broker
}

/** Cross-tab channel hub: `create()` returns another tab's channel endpoint. */
function makeHub() {
  const channels: AuthChannel[] = []
  return {
    create(): AuthChannel {
      const channel: AuthChannel = {
        onmessage: null,
        postMessage(message: unknown) {
          for (const other of channels) {
            if (other !== channel) other.onmessage?.({ data: message })
          }
        },
        close() {
          const index = channels.indexOf(channel)
          if (index >= 0) channels.splice(index, 1)
        },
      }
      channels.push(channel)
      return channel
    },
  }
}

/** Mirrors boot's durable install-timestamp marker key. */
function installMarkerKey(email: string): string {
  return `esc.account.installTs.v1.${dbNameForAccount(email)}`
}

/** Mirrors boot's durable session-evidence marker (grant expiry, ms epoch). */
const SESSION_EVIDENCE_KEY = 'esc.account.sessionUntil.v1'

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('boot (real mode)', () => {
  afterEach(async () => {
    resetBootForTests()
    getProfileMock.mockReset()
    runSyncMock.mockClear()
    drainPendingActionsMock.mockClear()
    startSchedulerMock.mockReset()
    startSchedulerMock.mockImplementation(() => () => {})
    localStorage.clear()
    await deleteDBForAccount('a@example.com')
    await deleteDBForAccount('b@example.com')
    await deleteDBForAccount('real@example.com')
    await deleteDBForAccount('typo@gmail.com')
  })

  it('gates to the sign-in screen when session setup fails before any DB is open', async () => {
    const gis = new FakeGis()
    // Stored record with NO email: the sign-in hint is optional, so the
    // profile email must be fetched before any DB can be opened.
    seedStoredSession(gis, { email: null })
    bootWithBroker(gis)
    getProfileMock.mockRejectedValue(new Error('offline'))

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    // Regression: this used to publish 'needs_interaction', which renders the
    // main app whose queriers call getDB() and crash — no DB was ever opened.
    expect(getAuthState()).toBe('signed_out')
    expect(() => getDB()).toThrow('No account database open')
  })

  it('gates to the sign-in screen when the silent renewal fails before any DB is open', async () => {
    const gis = new FakeGis()
    // Token inside the 5-minute horizon: the profile fetch's getToken() call
    // starts a silent renewal, which we fail below.
    seedStoredSession(gis, { email: null, expiresInMs: 60_000 })
    const broker = bootWithBroker(gis)
    getProfileMock.mockImplementation(async () => {
      await broker.getToken()
      throw new Error('unreachable')
    })

    await startBoot()
    await vi.waitFor(() => {
      expect(gis.pendingRequests.length).toBe(1)
    })
    gis.failNext()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    // Regression: the broker's needs_interaction transition used to be
    // published verbatim with no DB open (→ getDB() crash in the routed UI).
    expect(getAuthState()).toBe('signed_out')
    expect(() => getDB()).toThrow('No account database open')
  })

  it('re-auth granting a DIFFERENT Google account switches DBs instead of adopting the token', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    const broker = bootWithBroker(gis)

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    expect(getAccountEmail()).toBe('a@example.com')
    const dbA = getDB()
    expect(dbA.name).toBe(dbNameForAccount('a@example.com'))
    // Canary row: proves later that A's DB was closed, not wiped.
    await dbA.syncState.put({ key: 'wipe-canary', value: '1' })

    // Session-expired 'Continue': the user picks account B in the GIS popup,
    // so the granted token belongs to b@example.com, not the open DB's a@.
    getProfileMock.mockResolvedValue({ emailAddress: 'b@example.com', historyId: '7' })
    const flight = broker.interactiveSignIn()
    gis.grantNext({ access_token: 'tok-b' })
    await expect(flight).rejects.toMatchObject({ reason: 'account_changed' })

    // Regression: the session-alive ready path used to publish 'ready' with
    // no account cross-check, syncing B's mailbox into A's DB.
    await vi.waitFor(() => {
      expect(getAccountEmail()).toBe('b@example.com')
      expect(getAuthState()).toBe('ready')
    })
    expect(getDB().name).toBe(dbNameForAccount('b@example.com'))

    // A's DB survived the switch (closed, never wiped — it belongs to A).
    const reopenedA = new ChatmailDB(dbNameForAccount('a@example.com'))
    expect(await reopenedA.syncState.get('wipe-canary')).toMatchObject({ value: '1' })
    reopenedA.close()

    // The persisted record now pairs tok-b with b@ — a reload cannot restore
    // the poisoned {B token, A email} pairing.
    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record.email).toBe('b@example.com')
    expect(record.accessToken).toBe('tok-b')
  })

  it('never adopts an unverifiable re-auth grant onto the open account DB', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    const broker = bootWithBroker(gis)

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // Re-auth succeeds at the GIS layer but the account cannot be verified
    // (e.g. offline): the grant must NOT be adopted onto the open session.
    getProfileMock.mockRejectedValue(new Error('offline'))
    const flight = broker.interactiveSignIn()
    gis.grantNext({ access_token: 'tok-unverified' })
    await expect(flight).rejects.toMatchObject({ reason: 'needs_interaction' })

    // Verification failed before promotion, so the old session and token stay
    // coherent and available rather than being torn down under a foreign token.
    expect(getAuthState()).toBe('ready')
    expect(getDB().name).toBe(dbNameForAccount('a@example.com'))
    expect(getAccountEmail()).toBe('a@example.com')
    await expect(broker.getToken()).resolves.toBe('tok-a')
  })

  it('does not expose a replacement or stop the old session before verification', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    const broker = bootWithBroker(gis)

    // Capture the scheduler's sync closure and its stop, so the test can both
    // observe teardown and try to fire a sync mid-verification.
    let capturedSync: ((reason: 'manual') => Promise<unknown>) | null = null
    let schedulerStops = 0
    startSchedulerMock.mockImplementation((options) => {
      capturedSync = options.runSync
      return () => {
        schedulerStops += 1
      }
    })

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    expect(capturedSync).not.toBeNull()
    runSyncMock.mockClear()

    // A new grant lands (banner 'Continue'), and the profile fetch — the only
    // thing that can tell us WHICH account it belongs to — is slow.
    const profile = deferred<{ emailAddress: string; historyId: string }>()
    getProfileMock.mockReturnValue(profile.promise)
    const flight = broker.interactiveSignIn()
    gis.grantNext({ access_token: 'tok-new' })

    // The candidate is still private to AuthBroker. Existing workers remain
    // bound to A and can only observe A's old token while verification waits.
    await Promise.resolve()
    expect(schedulerStops).toBe(0)
    await expect(broker.getToken()).resolves.toBe('tok-a')
    await capturedSync!('manual')
    expect(runSyncMock).toHaveBeenCalledTimes(1)

    profile.resolve({ emailAddress: 'a@example.com', historyId: '9' })
    await flight
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    // Same account: no teardown/restart was needed.
    expect(getDB().name).toBe(dbNameForAccount('a@example.com'))
    expect(schedulerStops).toBe(0)
    expect(startSchedulerMock).toHaveBeenCalledTimes(1)
  })

  it('verifies a SILENT renewal that grants a different account', async () => {
    const gis = new FakeGis()
    // Token inside the 5-minute horizon so getToken() renews silently.
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a', expiresInMs: 60_000 })
    const broker = bootWithBroker(gis)

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    expect(getDB().name).toBe(dbNameForAccount('a@example.com'))

    // Automatic renewal, no user gesture. GIS resolves it against the
    // browser's other signed-in Google account and hands back B's token.
    getProfileMock.mockResolvedValue({ emailAddress: 'b@example.com', historyId: '7' })
    const renewing = broker.getToken()
    const cfg = gis.grantNext({ access_token: 'tok-b' })
    await expect(renewing).rejects.toMatchObject({ reason: 'account_changed' })

    // The renewal is bound to the known account...
    expect(cfg.login_hint).toBe('a@example.com')
    // ...and because the hint is only a hint, the swapped token is verified:
    // regression — the swap moved no auth state, so nothing was notified and
    // B's mailbox was synced straight into A's database.
    await vi.waitFor(() => {
      expect(getDB().name).toBe(dbNameForAccount('b@example.com'))
    })
    expect(getAccountEmail()).toBe('b@example.com')
  })

  it('does not publish ready when a cross-tab sign-out lands mid-establishment', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    const hub = makeHub()
    bootWithBroker(gis, () => hub.create())
    const otherTab = hub.create()

    let schedulerStops = 0
    startSchedulerMock.mockImplementation(() => {
      // The other tab signs out while this tab is still wiring its session
      // (the real window is the cold-cache dynamic imports above this point).
      otherTab.postMessage({ type: 'signed_out', epoch: 1 })
      return () => {
        schedulerStops += 1
      }
    })

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    // Regression: establishSession re-checked the broker only once, before the
    // dynamic imports, then unconditionally published 'ready' — leaving the tab
    // showing the mailbox of a signed-out session, with its scheduler and
    // outbox auto-drain running and unreachable.
    expect(getAuthState()).toBe('signed_out')
    expect(schedulerStops).toBe(1)
  })

  it('restores the backfill window when the account DB was evicted', async () => {
    const installedAt = Date.now() - 3 * 24 * 60 * 60 * 1000 // 3 days ago
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis)

    // First run: the account row exists (written by a completed sync), so the
    // durable install marker adopts its timestamp.
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    await getDB().accounts.put({
      email: 'a@example.com',
      historyId: '4242',
      aliases: ['a@example.com'],
      sendAsAliases: [],
      installTs: installedAt,
      sendAsRefreshedAt: installedAt,
    })

    // Re-boot so the marker picks up the row's installTs.
    resetBootForTests()
    const gis2 = new FakeGis()
    seedStoredSession(gis2, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis2)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // The browser evicts the origin's IndexedDB (or the DB is cleared): all
    // mail AND the account row are gone. localStorage survives.
    resetBootForTests()
    await deleteDBForAccount('a@example.com')
    const gis3 = new FakeGis()
    seedStoredSession(gis3, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis3)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // Regression: the account row was re-created by the next sync with
    // installTs = now, and initialSyncQuery floors the backfill at
    // installTs - 5min — so the user's whole mailbox was replaced by "the last
    // five minutes" with no way to get it back.
    const restored = await getDB().accounts.get('a@example.com')
    expect(restored).toBeDefined()
    expect(restored?.installTs).toBe(installedAt)
    // Empty historyId forces a full initial sync over the restored window.
    expect(restored?.historyId).toBe('')
  })

  it('clamps a restored backfill window to the 30-day fallback', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // An install from two years ago must not trigger a two-year backfill.
    const ancient = Date.now() - 730 * 24 * 60 * 60 * 1000
    await getDB().accounts.put({
      email: 'a@example.com',
      historyId: '99',
      aliases: [],
      sendAsAliases: [],
      installTs: ancient,
      sendAsRefreshedAt: 0,
    })
    resetBootForTests()
    const gis2 = new FakeGis()
    seedStoredSession(gis2, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis2)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    resetBootForTests()
    await deleteDBForAccount('a@example.com')
    const gis3 = new FakeGis()
    seedStoredSession(gis3, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis3)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    const restored = await getDB().accounts.get('a@example.com')
    const window = Date.now() - (restored?.installTs ?? 0)
    expect(window).toBeGreaterThan(29 * 24 * 60 * 60 * 1000)
    expect(window).toBeLessThan(31 * 24 * 60 * 60 * 1000)
  })

  it('leaves a first-ever run to the normal install-time floor', async () => {
    const before = Date.now()
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // No marker existed, so boot must NOT invent an account row: the initial
    // sync creates it with installTs = now (the 5-minute floor is correct for
    // a genuine first install).
    expect(await getDB().accounts.get('a@example.com')).toBeUndefined()
    expect(Number(localStorage.getItem(installMarkerKey('a@example.com')))).toBeGreaterThanOrEqual(
      before,
    )
  })

  it('resolves the REAL account on first sign-in instead of trusting the typed hint', async () => {
    const gis = new FakeGis()
    // No stored session: this is a genuine first sign-in on this origin.
    bootWithBroker(gis)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('signed_out')
    })

    // The user typos (or types an alias) on the sign-in card; GIS's account
    // chooser grants the real account — login_hint is only a hint. Mixed case
    // also pins normalization.
    getProfileMock.mockResolvedValue({ emailAddress: 'Real@Example.com', historyId: '11' })
    const flight = signIn('Typo@Gmail.com')
    await vi.waitFor(() => {
      expect(gis.pendingRequests.length).toBe(1)
    })
    gis.grantNext({ access_token: 'tok-1' })
    await flight
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // Regression: establishSession resolved `b.getEmail() ?? fetchProfileEmail`
    // while interactiveSignIn had set the broker email to the typed hint, so
    // getProfile was NEVER called on a first sign-in. The whole mailbox synced
    // into escmail_<sha256(typo)>, persistAccountAliases unshifted a phantom
    // primary alias (corrupting every participant set and isFromMe), and the
    // next restart opened the REAL account's DB, orphaning the first one past
    // sign-out.
    expect(getDB().name).toBe(dbNameForAccount('real@example.com'))
    expect(getAccountEmail()).toBe('real@example.com')
    expect(getProfileMock).toHaveBeenCalled()

    // The hint's database was never created at all.
    const names = (await indexedDB.databases()).map((info) => info.name)
    expect(names).not.toContain(dbNameForAccount('typo@gmail.com'))

    // Sync (and therefore alias persistence) runs against the verified account.
    expect(runSyncMock).toHaveBeenCalledWith(
      expect.objectContaining({ accountEmail: 'real@example.com' }),
      'startup',
    )

    // Durable + persisted identity both carry the verified address only, so a
    // reload cannot restore the {real token, wrong email} pairing.
    expect(localStorage.getItem('esc.account.last.v1')).toBe('real@example.com')
    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record.email).toBe('real@example.com')
  })

  it('drains the pending-action outbox when a session is established', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // A mutation made offline (or before a token expiry) left a claimable row.
    await getDB().pendingActions.put({
      actionType: 'archiveConversation',
      status: 'failed',
      messageId: 'm1',
      conversationId: 'c1',
      messageIds: ['m1'],
      retryCount: 1,
      createdAt: Date.now(),
      lastAttempt: Date.now(),
    })
    drainPendingActionsMock.mockClear()

    // Cold start (new tab / PWA relaunch): 'online' never fires because the
    // browser was already online, so the only auto-drain trigger never runs.
    resetBootForTests()
    const gis2 = new FakeGis()
    seedStoredSession(gis2, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis2)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // Regression: establishSession registered the 'online' listener and
    // replayed the SEND journal but never drained pendingActions, so an
    // archive/mark-read stranded by an offline burst or a re-auth sat in the
    // queue indefinitely — and reconcileLabels skips those message ids, so
    // nothing repaired the local/remote drift either.
    await vi.waitFor(() => {
      expect(drainPendingActionsMock).toHaveBeenCalled()
    })
    expect(await getDB().pendingActions.count()).toBe(1)
  })

  it('does not promote a transiently unverifiable silent-renewal candidate', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a', expiresInMs: 60_000 })
    const broker = bootWithBroker(gis)

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    expect(startSchedulerMock).toHaveBeenCalledTimes(1)

    // The candidate profile request fails for a transport reason. It must not
    // replace the coherent {A token, A database} session.
    getProfileMock.mockRejectedValue(new Error('Failed to fetch'))
    const renewing = broker.getToken()
    gis.grantNext({ access_token: 'tok-a2' })
    await expect(renewing).rejects.toMatchObject({ reason: 'renewal_failed' })
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('needs_interaction')
    })

    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record).toMatchObject({ accessToken: 'tok-a', email: 'a@example.com' })
    expect(getDB().name).toBe(dbNameForAccount('a@example.com'))
    expect(startSchedulerMock).toHaveBeenCalledTimes(1)

    const callsAtFailure = getProfileMock.mock.calls.length
    window.dispatchEvent(new Event('online'))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(getProfileMock.mock.calls.length).toBe(callsAtFailure)
  })

  it('does NOT retry verification after a DEFINITIVE auth failure', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a', expiresInMs: 60_000 })
    const broker = bootWithBroker(gis)

    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // The grant itself is unusable: only a user gesture can fix that, so the
    // banner must stay and no unattended retry may hammer Google.
    getProfileMock.mockRejectedValue(
      new AuthRequiredError('Gmail rejected the refreshed token', 'needs_interaction'),
    )
    const renewing = broker.getToken()
    gis.grantNext({ access_token: 'tok-a2' })
    await expect(renewing).rejects.toMatchObject({ reason: 'needs_interaction' })
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('needs_interaction')
    })
    const callsAtFailure = getProfileMock.mock.calls.length

    window.dispatchEvent(new Event('online'))
    await new Promise((resolve) => setTimeout(resolve, 20))

    expect(getProfileMock.mock.calls.length).toBe(callsAtFailure)
    expect(getAuthState()).toBe('needs_interaction')
  })

  it('treats a deliberate sign-out as a clean slate, not an eviction', async () => {
    const gis = new FakeGis()
    seedStoredSession(gis, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // An install from months ago, recorded in the durable marker.
    const installedAt = Date.now() - 180 * 24 * 60 * 60 * 1000
    await getDB().accounts.put({
      email: 'a@example.com',
      historyId: '4242',
      aliases: ['a@example.com'],
      sendAsAliases: [],
      installTs: installedAt,
      sendAsRefreshedAt: installedAt,
    })
    resetBootForTests()
    const gis2 = new FakeGis()
    seedStoredSession(gis2, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis2)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })
    expect(Number(localStorage.getItem(installMarkerKey('a@example.com')))).toBe(installedAt)

    await signOut()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('signed_out')
    })

    // Regression: signOut cleared only the last-account key, so the install
    // marker outlived the wipe. Signing back in found a marker with no accounts
    // row, classified the deliberate wipe as an eviction, and re-created the
    // row with historyId '' + installTs clamped to 30 days ago — re-pulling a
    // month of mail into what the user asked to be a clean slate (and leaking
    // one localStorage key per account, forever).
    expect(localStorage.getItem(installMarkerKey('a@example.com'))).toBeNull()

    const before = Date.now()
    resetBootForTests()
    const gis3 = new FakeGis()
    seedStoredSession(gis3, { email: 'a@example.com', accessToken: 'tok-a' })
    bootWithBroker(gis3)
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('ready')
    })

    // A genuine first install: no invented account row, marker stamped now.
    expect(await getDB().accounts.get('a@example.com')).toBeUndefined()
    expect(Number(localStorage.getItem(installMarkerKey('a@example.com')))).toBeGreaterThanOrEqual(
      before,
    )
  })
})

describe('boot without Google Identity Services', () => {
  afterEach(async () => {
    resetBootForTests()
    getProfileMock.mockReset()
    localStorage.clear()
    await deleteDBForAccount('a@example.com')
  })

  function bootWithoutGis(): Promise<void> {
    setBootOverridesForTests({
      clientId: '123-real.apps.googleusercontent.com',
      createBroker: () => {
        throw new Error('Google Identity Services is not loaded')
      },
    })
    return startBoot()
  }

  it('opens the last account offline instead of a sign-in screen it cannot use', async () => {
    // A previous session remembered the account (durable, outside the DB) and
    // its grant has not lapsed yet.
    localStorage.setItem('esc.account.last.v1', 'a@example.com')
    localStorage.setItem(SESSION_EVIDENCE_KEY, String(Date.now() + 30 * 60 * 1000))

    await bootWithoutGis()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    // Regression: boot published 'signed_out', so an installed PWA that is
    // offline (or has accounts.google.com blocked) showed a sign-in button
    // that cannot work, and its fully local mailbox was unreachable.
    expect(getAuthState()).toBe('needs_interaction')
    expect(getDB().name).toBe(dbNameForAccount('a@example.com'))
  })

  it('does NOT open the mailbox when the last session evidence has lapsed', async () => {
    localStorage.setItem('esc.account.last.v1', 'a@example.com')
    // The grant expired an hour ago: nothing says the same user is present.
    localStorage.setItem(SESSION_EVIDENCE_KEY, String(Date.now() - 60 * 60 * 1000))

    await bootWithoutGis()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    // Regression: this auth-less path opened the last account's DB on nothing
    // but a plaintext localStorage address and published 'needs_interaction',
    // which renders the FULL chats UI over the banner — so whoever opened the
    // browser next (offline, or with accounts.google.com blocked) read the
    // previous user's entire mailbox without ever authenticating.
    expect(getAuthState()).toBe('signed_out')
    expect(() => getDB()).toThrow('No account database open')
    // A lapsed marker is dropped so it cannot be re-armed by clock skew.
    expect(localStorage.getItem(SESSION_EVIDENCE_KEY)).toBeNull()
  })

  it('does NOT open the mailbox when no session was ever established here', async () => {
    localStorage.setItem('esc.account.last.v1', 'a@example.com')

    await bootWithoutGis()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })

    expect(getAuthState()).toBe('signed_out')
    expect(() => getDB()).toThrow('No account database open')
  })

  it('falls back to the sign-in screen when no account is remembered', async () => {
    localStorage.setItem(SESSION_EVIDENCE_KEY, String(Date.now() + 30 * 60 * 1000))

    await bootWithoutGis()
    await vi.waitFor(() => {
      expect(getAuthState()).not.toBe('unknown')
    })
    expect(getAuthState()).toBe('signed_out')
    expect(() => getDB()).toThrow('No account database open')
  })
})
