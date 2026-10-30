import Dexie from 'dexie'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ChatmailDB, dbNameForAccount, deleteDBForAccount, getDB } from '@/db/schema'
import { getAccountEmail, getAuthState, resetBootForTests, signOut, startBoot } from './boot'
import {
  FakeGis,
  SESSION_EVIDENCE_KEY,
  bootWithBroker,
  installMarkerKey,
  seedStoredSession,
} from './bootTestSupport'

// Sign-out must remove EVERY account database on the origin, not only the
// current account's: a verified account switch keeps the previous account's
// database on disk (it belongs to that account), and before the sweep the
// sign-out performed to leave a shared machine left that whole mailbox —
// messages, bodies, attachment blobs — readable in IndexedDB, with its
// install marker.
//
// Revert-check: wipeAllAccountData (boot.ts) over listAccountDBNames /
// deleteAccountDBs (schema.ts). With the wipe hook back to
// `deleteDBForAccount(email)` for the session's account, A's database and
// marker survive the sign-out in both tests below.

const { getProfileMock } = vi.hoisted(() => ({ getProfileMock: vi.fn() }))

vi.mock('@/gmail/endpoints', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/gmail/endpoints')>()),
  getProfile: getProfileMock,
}))
vi.mock('@/sync/engine', () => ({
  runSync: vi.fn(() => Promise.resolve({ ran: true })),
}))
vi.mock('@/sync/scheduler', () => ({
  startScheduler: vi.fn(() => () => {}),
}))
vi.mock('@/outbox/pendingActions', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/outbox/pendingActions')>()),
  drainPendingActions: vi.fn(() => Promise.resolve()),
}))

const A = 'a@example.com'
const B = 'b@example.com'

async function bootAs(email: string, accessToken: string) {
  const gis = new FakeGis()
  seedStoredSession(gis, { email, accessToken })
  const broker = bootWithBroker(gis, getProfileMock)
  await startBoot()
  await vi.waitFor(() => {
    expect(getAuthState()).toBe('ready')
  })
  expect(getDB().name).toBe(dbNameForAccount(email))
  return { broker, gis }
}

async function canaryExists(email: string): Promise<boolean> {
  if (!(await Dexie.exists(dbNameForAccount(email)))) return false
  const db = new ChatmailDB(dbNameForAccount(email))
  try {
    return (await db.syncState.get('wipe-canary')) !== undefined
  } finally {
    db.close()
  }
}

describe('boot sign-out sweeps every account database', () => {
  afterEach(async () => {
    resetBootForTests()
    getProfileMock.mockReset()
    localStorage.clear()
    await deleteDBForAccount(A)
    await deleteDBForAccount(B)
  })

  it('after a verified A→B switch, sign-out deletes both databases and both install markers', async () => {
    const { broker, gis } = await bootAs(A, 'tok-a')
    await getDB().syncState.put({ key: 'wipe-canary', value: '1' })

    // Session-expired 'Continue' where the GIS chooser grants B although the
    // hint named A: boot switches to B's DB and keeps A's on disk.
    getProfileMock.mockResolvedValue({ emailAddress: B, historyId: '7' })
    const flight = broker.interactiveSignIn()
    gis.grantNext({ access_token: 'tok-b' })
    await expect(flight).rejects.toMatchObject({ reason: 'account_changed' })
    await vi.waitFor(() => {
      expect(getAccountEmail()).toBe(B)
      expect(getAuthState()).toBe('ready')
    })
    expect(getDB().name).toBe(dbNameForAccount(B))
    await getDB().syncState.put({ key: 'wipe-canary', value: '1' })

    // Both accounts are established on this origin at this point.
    expect(await canaryExists(A)).toBe(true)
    expect(await canaryExists(B)).toBe(true)
    expect(localStorage.getItem(installMarkerKey(A))).not.toBeNull()
    expect(localStorage.getItem(installMarkerKey(B))).not.toBeNull()

    await signOut()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('signed_out')
    })

    expect(await Dexie.exists(dbNameForAccount(B))).toBe(false)
    // Regression: only B (the current account) was deleted; A's full mailbox
    // stayed on disk for the next person on the machine.
    expect(await Dexie.exists(dbNameForAccount(A))).toBe(false)
    expect(localStorage.getItem(installMarkerKey(A))).toBeNull()
    expect(localStorage.getItem(installMarkerKey(B))).toBeNull()
    expect(() => getDB()).toThrow('No account database open')
  })

  it('the auth-less offline sign-out sweeps a previous account left behind by a switch', async () => {
    // A's database was left on disk by an earlier switch; the device then
    // boots without GIS (offline) on the remembered account B.
    const leftover = new ChatmailDB(dbNameForAccount(A))
    await leftover.syncState.put({ key: 'wipe-canary', value: '1' })
    leftover.close()
    localStorage.setItem(installMarkerKey(A), String(Date.now()))
    localStorage.setItem('esc.account.last.v1', B)
    localStorage.setItem(SESSION_EVIDENCE_KEY, String(Date.now() + 30 * 60 * 1000))
    const { setBootOverridesForTests } = await import('./boot')
    setBootOverridesForTests({
      clientId: '123-real.apps.googleusercontent.com',
      createBroker: () => {
        throw new Error('Google Identity Services is not loaded')
      },
    })
    await startBoot()
    await vi.waitFor(() => {
      expect(getAuthState()).toBe('needs_interaction')
    })
    expect(getDB().name).toBe(dbNameForAccount(B))

    await signOut()

    expect(getAuthState()).toBe('signed_out')
    expect(await Dexie.exists(dbNameForAccount(B))).toBe(false)
    expect(await Dexie.exists(dbNameForAccount(A))).toBe(false)
    expect(localStorage.getItem(installMarkerKey(A))).toBeNull()
    expect(() => getDB()).toThrow('No account database open')
  })
})
