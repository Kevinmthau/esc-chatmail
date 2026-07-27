import { describe, expect, it, vi } from 'vitest'
import {
  AUTH_EPOCH_STORAGE_KEY,
  AUTH_HAS_SIGNED_IN_STORAGE_KEY,
  AUTH_SCOPES,
  AUTH_SESSION_STORAGE_KEY,
  AuthBroker,
  AuthRequiredError,
} from './authBroker'
import type {
  AuthChannel,
  AuthState,
  GisRevocationResponse,
  GisSurface,
  GisTokenClientConfig,
  GisTokenResponse,
  StoredAuthSession,
} from './authBroker'

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

function memoryStorage(): Storage {
  const map = new Map<string, string>()
  const storage = {
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
  return storage
}

class FakeGis {
  time = 1_700_000_000_000
  storage = memoryStorage()
  /** Set to simulate production's separate durable flag store (localStorage). */
  flagStorage: Storage | undefined
  pendingRequests: GisTokenClientConfig[] = []
  requestCount = 0
  revoked: string[] = []
  /** Replaced to simulate a revocation that fails asynchronously (e.g. CSP). */
  revokeResult: GisRevocationResponse | null = null

  surface(): GisSurface {
    const surface: GisSurface = {
      createTokenClient: (cfg) => ({
        requestAccessToken: () => {
          this.requestCount += 1
          this.pendingRequests.push(cfg)
        },
      }),
      revoke: (token, done) => {
        this.revoked.push(token)
        if (this.revokeResult !== null) done?.(this.revokeResult)
      },
      now: () => this.time,
      storage: this.storage,
    }
    if (this.flagStorage !== undefined) surface.flagStorage = this.flagStorage
    return surface
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

  failNext(error = 'interaction_required'): GisTokenClientConfig {
    const cfg = this.pendingRequests.shift()
    if (!cfg) throw new Error('no pending token request')
    cfg.callback({ error })
    return cfg
  }
}

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

function newBroker(gis: FakeGis, createChannel: () => AuthChannel | null = () => null): AuthBroker {
  return new AuthBroker(gis.surface(), { clientId: 'test-client-id', createChannel })
}

async function completeSignIn(
  broker: AuthBroker,
  gis: FakeGis,
  token = 'tok-1',
  expiresInSeconds = 3600,
): Promise<void> {
  const flight = broker.interactiveSignIn('user@example.com')
  gis.grantNext({ access_token: token, expires_in: expiresInSeconds })
  await flight
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('AuthBroker interactive sign-in', () => {
  it('reaches ready, returns the token, and persists the epoch-stamped session', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    expect(broker.getState()).toBe('signed_out')

    const flight = broker.interactiveSignIn('user@example.com')
    expect(broker.getState()).toBe('authorizing')
    const cfg = gis.grantNext({ access_token: 'tok-1', expires_in: 3600 })
    await flight

    expect(cfg.prompt).toBe('consent') // first-ever sign-in prompts for consent
    expect(broker.getState()).toBe('ready')
    // The typed value is a HINT, not an identity: it is offered to GIS but the
    // broker carries no verified account until setAccountEmail runs.
    expect(cfg.login_hint).toBe('user@example.com')
    expect(broker.getEmail()).toBeNull()
    expect(broker.getLoginHint()).toBe('user@example.com')
    await expect(broker.getToken()).resolves.toBe('tok-1')

    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record.accessToken).toBe('tok-1')
    expect(record.epoch).toBe(0)
    expect(record.expiresAt).toBe(gis.time + 3_600_000)
    expect(gis.storage.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBe('1')
  })

  it('uses empty prompt after the first ever sign-in', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis)

    const again = broker.interactiveSignIn()
    const cfg = gis.grantNext({ access_token: 'tok-2' })
    await again
    expect(cfg.prompt).toBe('')
  })

  it('scope-denied grant moves to needs_interaction and rejects typed', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)

    const flight = broker.interactiveSignIn('user@example.com')
    gis.grantNext({ scope: 'openid email profile' }) // gmail.modify missing
    await expect(flight).rejects.toBeInstanceOf(AuthRequiredError)
    expect(broker.getState()).toBe('needs_interaction')
    // No usable token was cached or persisted.
    expect(gis.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
  })

  it('scope-denied rejection carries the scope_denied reason', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)

    const flight = broker.interactiveSignIn()
    gis.grantNext({ scope: 'openid email profile' })
    await expect(flight).rejects.toMatchObject({ reason: 'scope_denied' })
    expect(broker.getState()).toBe('needs_interaction')

    // getToken while needs_interaction rejects without touching GIS.
    const before = gis.requestCount
    await expect(broker.getToken()).rejects.toBeInstanceOf(AuthRequiredError)
    expect(gis.requestCount).toBe(before)
  })

  it('user-cancelled first sign-in reverts to signed_out', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)

    const flight = broker.interactiveSignIn()
    gis.failNext('access_denied')
    await expect(flight).rejects.toBeInstanceOf(AuthRequiredError)
    expect(broker.getState()).toBe('signed_out')
  })
})

describe('AuthBroker getToken', () => {
  it('rejects with AuthRequiredError when signed out', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await expect(broker.getToken()).rejects.toMatchObject({
      name: 'AuthRequiredError',
      reason: 'signed_out',
    })
  })

  it('treats the 5-minute horizon as expired (boundary) and beyond it as fresh', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 3600)
    const grantedAt = gis.time

    // Exactly 5 minutes remaining -> expiring soon -> renewal starts.
    gis.time = grantedAt + 3_600_000 - 300_000
    const renewing = broker.getToken()
    expect(gis.requestCount).toBe(2) // 1 sign-in + 1 renewal
    gis.grantNext({ access_token: 'tok-2' })
    await expect(renewing).resolves.toBe('tok-2')

    // Just over 5 minutes remaining -> cached token served, no GIS call.
    const secondGrantAt = gis.time
    gis.time = secondGrantAt + 3_600_000 - 300_001
    await expect(broker.getToken()).resolves.toBe('tok-2')
    expect(gis.requestCount).toBe(2)
  })

  it('shares exactly one renewal across concurrent callers', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 100) // within the 5-min horizon

    const p1 = broker.getToken()
    const p2 = broker.getToken()
    const p3 = broker.getToken()
    expect(gis.requestCount).toBe(2) // sign-in + ONE shared renewal
    expect(gis.pendingRequests).toHaveLength(1)

    const cfg = gis.grantNext({ access_token: 'tok-2' })
    expect(cfg.prompt).toBe('') // silent renewal
    await expect(Promise.all([p1, p2, p3])).resolves.toEqual(['tok-2', 'tok-2', 'tok-2'])
  })

  it('renewal failure moves to needs_interaction and rejects callers typed', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 100)

    const p1 = broker.getToken()
    const p2 = broker.getToken()
    gis.failNext()
    await expect(p1).rejects.toBeInstanceOf(AuthRequiredError)
    await expect(p2).rejects.toBeInstanceOf(AuthRequiredError)
    expect(broker.getState()).toBe('needs_interaction')
  })
})

describe('AuthBroker silent renewal is bound to the account', () => {
  it('sends the known account as login_hint on every silent renewal', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 3600) // hint user@example.com
    broker.setAccountEmail('verified@example.com')

    // Automatic renewal (no user gesture): the token crossed the 5-min horizon.
    gis.time += 3_600_000 - 200_000
    const renewing = broker.getToken()
    const cfg = gis.grantNext({ access_token: 'tok-2' })
    await expect(renewing).resolves.toBe('tok-2')

    // Regression: renewSilently used to call acquire({prompt: ''}) with NO
    // hint, so GIS resolved the grant against whatever Google account happens
    // to be the browser's current session — another account's token, adopted
    // silently onto this account's database.
    expect(cfg.login_hint).toBe('verified@example.com')
    expect(cfg.prompt).toBe('')
  })

  it('also hints the 401-recovery renewal', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')

    const refreshing = broker.refreshAfter('tok-1')
    const cfg = gis.grantNext({ access_token: 'tok-2' })
    await expect(refreshing).resolves.toBe('tok-2')
    expect(cfg.login_hint).toBe('user@example.com')
  })

  it('notifies listeners when a renewal SWAPS the token on an already-ready broker', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 3600)

    const seen: AuthState[] = []
    broker.subscribe((state) => seen.push(state))

    gis.time += 3_600_000 - 200_000
    const renewing = broker.getToken()
    gis.grantNext({ access_token: 'tok-2' })
    await expect(renewing).resolves.toBe('tok-2')

    // Regression: the broker was already 'ready', so setState() early-returned
    // and NO listener fired — boot's account verification never ran and the
    // fresh (possibly foreign) token was used against the open DB unchecked.
    expect(seen).toEqual(['ready'])
  })

  it('does not double-notify when the renewal returns the same token', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 3600)

    const seen: AuthState[] = []
    broker.subscribe((state) => seen.push(state))

    gis.time += 3_600_000 - 200_000
    const renewing = broker.getToken()
    gis.grantNext({ access_token: 'tok-1' }) // same grant re-issued
    await expect(renewing).resolves.toBe('tok-1')
    expect(seen).toEqual([])
  })
})

describe('AuthBroker durable sign-in flag', () => {
  it('keeps the has-signed-in flag out of per-tab storage', async () => {
    const gis = new FakeGis()
    const durable = memoryStorage() // stands in for localStorage
    gis.flagStorage = durable
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')

    // The token record stays per-tab; only the non-secret UX flag is durable.
    expect(gis.storage.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBeNull()
    expect(durable.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBe('1')

    // Regression: a new tab / cold start (fresh sessionStorage, same durable
    // store) used to see firstEverSignIn === true and re-prompt the full
    // restricted-scope consent screen on every launch.
    const coldStart = new FakeGis()
    coldStart.flagStorage = durable
    const rebooted = newBroker(coldStart)
    const flight = rebooted.interactiveSignIn('user@example.com')
    const cfg = coldStart.grantNext({ access_token: 'tok-2' })
    await flight
    expect(cfg.prompt).toBe('')
  })

  it('clears the durable flag on sign-out so consent is requested again', async () => {
    const gis = new FakeGis()
    const durable = memoryStorage()
    gis.flagStorage = durable
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')

    await broker.signOut()
    expect(durable.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBeNull()

    const again = broker.interactiveSignIn()
    const cfg = gis.grantNext({ access_token: 'tok-3' })
    await again
    expect(cfg.prompt).toBe('consent')
  })
})

describe('AuthBroker revocation observability', () => {
  it('reports an asynchronous revocation failure instead of swallowing it', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')
    // A CSP refusal (or network error) surfaces through the callback, never as
    // a synchronous throw — the try/catch alone could not see it.
    gis.revokeResult = { successful: false, error: 'csp_blocked' }
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    await broker.signOut()

    expect(gis.revoked).toEqual(['tok-1'])
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('revocation failed'))
    warn.mockRestore()
  })
})

describe('AuthBroker refreshAfter', () => {
  it('returns the current token without GIS when someone already refreshed', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-2')

    const before = gis.requestCount
    await expect(broker.refreshAfter('tok-1-stale')).resolves.toBe('tok-2')
    expect(gis.requestCount).toBe(before)
  })

  it('renews single-flight when the stale token is still current', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')

    const r1 = broker.refreshAfter('tok-1')
    const r2 = broker.refreshAfter('tok-1')
    expect(gis.pendingRequests).toHaveLength(1)
    gis.grantNext({ access_token: 'tok-2' })
    await expect(r1).resolves.toBe('tok-2')
    await expect(r2).resolves.toBe('tok-2')
  })
})

describe('AuthBroker epoch guard', () => {
  it('rejects a late grant callback that lands after signOut and never resurrects the session', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 100)

    const renewing = broker.getToken() // starts a renewal (token inside horizon)
    expect(gis.pendingRequests).toHaveLength(1)

    await broker.signOut()
    expect(broker.getState()).toBe('signed_out')

    // The GIS callback fires late, after the epoch was bumped.
    gis.grantNext({ access_token: 'zombie-token' })
    await expect(renewing).rejects.toMatchObject({
      name: 'AuthRequiredError',
      reason: 'stale_epoch',
    })

    // Nothing was cached, persisted, or state-transitioned by the late grant.
    expect(broker.getState()).toBe('signed_out')
    expect(gis.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
    await expect(broker.getToken()).rejects.toBeInstanceOf(AuthRequiredError)

    // A fresh broker on the same storage boots signed out.
    const rebooted = newBroker(gis)
    expect(rebooted.getState()).toBe('signed_out')
  })
})

describe('AuthBroker sessionStorage restore', () => {
  it('accepts a record whose epoch matches the stored epoch', async () => {
    const gis = new FakeGis()
    const record: StoredAuthSession = {
      accessToken: 'restored-tok',
      expiresAt: gis.time + 3_600_000,
      scope: AUTH_SCOPES,
      epoch: 3,
      email: 'user@example.com',
    }
    gis.storage.setItem(AUTH_EPOCH_STORAGE_KEY, '3')
    gis.storage.setItem(AUTH_SESSION_STORAGE_KEY, JSON.stringify(record))

    const broker = newBroker(gis)
    expect(broker.getState()).toBe('ready')
    expect(broker.getEmail()).toBe('user@example.com')
    await expect(broker.getToken()).resolves.toBe('restored-tok')
    expect(gis.requestCount).toBe(0)
  })

  it('rejects a stale-epoch record and removes it', async () => {
    const gis = new FakeGis()
    const record: StoredAuthSession = {
      accessToken: 'stale-tok',
      expiresAt: gis.time + 3_600_000,
      scope: AUTH_SCOPES,
      epoch: 2,
      email: 'user@example.com',
    }
    gis.storage.setItem(AUTH_EPOCH_STORAGE_KEY, '3')
    gis.storage.setItem(AUTH_SESSION_STORAGE_KEY, JSON.stringify(record))

    const broker = newBroker(gis)
    expect(broker.getState()).toBe('signed_out')
    expect(gis.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
    await expect(broker.getToken()).rejects.toBeInstanceOf(AuthRequiredError)
  })
})

describe('AuthBroker setAccountEmail', () => {
  it('adopts the verified email and re-persists the session record', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1') // login hint user@example.com

    broker.setAccountEmail('verified@example.com')

    expect(broker.getEmail()).toBe('verified@example.com')
    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record.email).toBe('verified@example.com')
    expect(record.accessToken).toBe('tok-1')
  })

  it('ignores empty values and does not persist without a cached grant', () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    broker.setAccountEmail('  ')
    expect(broker.getEmail()).toBeNull()
    broker.setAccountEmail('someone@example.com')
    expect(broker.getEmail()).toBe('someone@example.com')
    expect(gis.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
  })
})

describe('AuthBroker login hint is never an identity', () => {
  it('keeps a typed hint out of getEmail() and out of the persisted record', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)

    // The user types an address on the sign-in card; GIS's account chooser
    // grants a DIFFERENT account (login_hint is only a hint).
    const flight = broker.interactiveSignIn('typo@gmail.com')
    gis.grantNext({ access_token: 'tok-1' })
    await flight

    // Regression: interactiveSignIn used to do `this.email = hint`, so the
    // unverified typed address became the account identity — it named the
    // database, the accounts row and the alias set, and was persisted with the
    // token so a reload restored the same wrong pairing.
    expect(broker.getEmail()).toBeNull()
    const record = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(record.email).toBeNull()

    // Only verification supplies an identity — and it is what gets persisted.
    broker.setAccountEmail('real@example.com')
    expect(broker.getEmail()).toBe('real@example.com')
    const verified = JSON.parse(
      gis.storage.getItem(AUTH_SESSION_STORAGE_KEY) ?? 'null',
    ) as StoredAuthSession
    expect(verified.email).toBe('real@example.com')
  })

  it('still offers the unverified hint to GIS on a silent renewal', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1', 3600) // hint user@example.com

    gis.time += 3_600_000 - 200_000
    const renewing = broker.getToken()
    const cfg = gis.grantNext({ access_token: 'tok-2' })
    await expect(renewing).resolves.toBe('tok-2')

    // Splitting hint from identity must not un-bind renewals: without a hint
    // GIS resolves them against the browser's current default Google account.
    expect(cfg.login_hint).toBe('user@example.com')
  })

  it('lowercases hints and verified emails so they cannot key two DBs', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)

    const flight = broker.interactiveSignIn('  Kevin.Thau@Gmail.COM ')
    const cfg = gis.grantNext({ access_token: 'tok-1' })
    await flight

    // dbNameForAccount lowercases before hashing but db.accounts' primary key
    // does not, so a mixed-case address would key the row differently from the
    // database it names.
    expect(cfg.login_hint).toBe('kevin.thau@gmail.com')
    expect(broker.getLoginHint()).toBe('kevin.thau@gmail.com')
    broker.setAccountEmail('Real@Example.com')
    expect(broker.getEmail()).toBe('real@example.com')
  })

  it('drops the hint on sign-out', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis)

    await broker.signOut()

    expect(broker.getLoginHint()).toBeNull()
  })
})

describe('AuthBroker signOut', () => {
  it('runs wipe hooks, revokes best-effort, and clears storage', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    await completeSignIn(broker, gis, 'tok-1')

    const calls: string[] = []
    broker.registerWipeHook(() => {
      calls.push('sync-hook')
    })
    broker.registerWipeHook(async () => {
      await Promise.resolve()
      calls.push('async-hook')
    })
    broker.registerWipeHook(() => {
      throw new Error('hook failure must not block sign-out')
    })

    await broker.signOut()

    expect(calls).toEqual(['sync-hook', 'async-hook'])
    expect(gis.revoked).toEqual(['tok-1'])
    expect(broker.getState()).toBe('signed_out')
    expect(gis.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
    expect(gis.storage.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBeNull()
    expect(gis.storage.getItem(AUTH_EPOCH_STORAGE_KEY)).toBe('1')
    expect(broker.getEmail()).toBeNull()

    // Sign-in flag cleared -> the next sign-in prompts for consent again.
    const again = broker.interactiveSignIn()
    const cfg = gis.grantNext({ access_token: 'tok-3' })
    await again
    expect(cfg.prompt).toBe('consent')
  })

  it('notifies subscribers across the state machine', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    const states: AuthState[] = []
    const unsubscribe = broker.subscribe((state) => states.push(state))

    await completeSignIn(broker, gis)
    await broker.signOut()
    unsubscribe()

    // Transitions after unsubscribe are not delivered.
    const again = broker.interactiveSignIn()
    gis.grantNext({ access_token: 'tok-9' })
    await again

    expect(states).toEqual(['authorizing', 'ready', 'signed_out'])
  })
})

describe('AuthBroker cross-tab sign-out', () => {
  it('drops the other tab state when one tab signs out', async () => {
    const hub = makeHub()
    const gisA = new FakeGis()
    const gisB = new FakeGis()
    const tabA = newBroker(gisA, () => hub.create())
    const tabB = newBroker(gisB, () => hub.create())
    await completeSignIn(tabA, gisA, 'tok-a')
    await completeSignIn(tabB, gisB, 'tok-b')
    expect(tabB.getState()).toBe('ready')

    await tabA.signOut()

    expect(tabB.getState()).toBe('signed_out')
    expect(tabB.getEmail()).toBeNull()
    await expect(tabB.getToken()).rejects.toMatchObject({ reason: 'signed_out' })
  })

  it('clears the receiving tab storage so a reload cannot resurrect the session', async () => {
    const hub = makeHub()
    const gisA = new FakeGis()
    const gisB = new FakeGis()
    const tabA = newBroker(gisA, () => hub.create())
    const tabB = newBroker(gisB, () => hub.create())
    await completeSignIn(tabA, gisA, 'tok-a')
    await completeSignIn(tabB, gisB, 'tok-b')

    await tabA.signOut()

    // Tab B's PER-TAB sessionStorage must not retain the retired token or the
    // pre-sign-out epoch; only in-memory state was dropped before the fix.
    expect(gisB.storage.getItem(AUTH_SESSION_STORAGE_KEY)).toBeNull()
    expect(gisB.storage.getItem(AUTH_HAS_SIGNED_IN_STORAGE_KEY)).toBeNull()
    expect(gisB.storage.getItem(AUTH_EPOCH_STORAGE_KEY)).toBe('1')

    // Reloading tab B (a fresh broker over the same storage) boots signed out
    // instead of restoring to 'ready' with the revoked token.
    const rebooted = newBroker(gisB)
    expect(rebooted.getState()).toBe('signed_out')
    await expect(rebooted.getToken()).rejects.toMatchObject({ reason: 'signed_out' })
  })

  it('discards a grant in flight in the receiving tab (epoch adopted)', async () => {
    const hub = makeHub()
    const gisA = new FakeGis()
    const gisB = new FakeGis()
    const tabA = newBroker(gisA, () => hub.create())
    const tabB = newBroker(gisB, () => hub.create())
    await completeSignIn(tabA, gisA, 'tok-a')
    await completeSignIn(tabB, gisB, 'tok-b', 100)

    const renewing = tabB.getToken() // renewal in flight in tab B
    await tabA.signOut() // broadcast bumps tab B's epoch

    gisB.grantNext({ access_token: 'zombie-token' })
    await expect(renewing).rejects.toMatchObject({ reason: 'stale_epoch' })
    expect(tabB.getState()).toBe('signed_out')
  })
})
