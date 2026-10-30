import { describe, expect, it } from 'vitest'
import { AUTH_SCOPES, AuthBroker } from './authBroker'
import type { AuthState, GisSurface, GisTokenClientConfig, GisTokenResponse } from './authBroker'

// A silent renewal retired by a sign-out still settles later: GIS delivers
// the first popup's callback (or its popup_closed error) after the user has
// signed back in through a second popup, and a profile verification parked
// across the sign-out rejects once it resumes. None of those settles may
// demote the fresh session.
//
// Revert-check: renewSilently's `epochAtStart` guard. With the demotion keyed
// on `this.state !== 'signed_out'` again, every test below sees
// 'needs_interaction' published over the re-established 'ready' and getToken
// rejecting with 'User interaction required' despite the cached tok-2.

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
  verifyToken: (accessToken: string) => Promise<string> = () => Promise.resolve('user@example.com')

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
}

function newBroker(gis: FakeGis): AuthBroker {
  return new AuthBroker(gis.surface(), {
    clientId: 'test-client-id',
    createChannel: () => null,
    verifyAccessToken: (accessToken) => gis.verifyToken(accessToken),
  })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((res) => {
    resolve = res
  })
  return { promise, resolve }
}

/**
 * Signs in as tok-1, moves the clock inside the 5-minute horizon so getToken
 * starts a renewal, and returns that in-flight renewal with its GIS request.
 */
async function startRenewal(gis: FakeGis, broker: AuthBroker) {
  const signIn = broker.interactiveSignIn('user@example.com')
  gis.grantNext({ access_token: 'tok-1' })
  await signIn
  gis.time += 3_600_000 - 60_000
  const renewal = broker.getToken()
  const request = gis.pendingRequests.shift()
  if (!request) throw new Error('renewal did not reach GIS')
  return { renewal, request }
}

/** Signs out and signs back in as tok-2; the renewal from before stays unsettled. */
async function signOutAndBackIn(gis: FakeGis, broker: AuthBroker): Promise<void> {
  await broker.signOut()
  expect(broker.getState()).toBe('signed_out')
  const again = broker.interactiveSignIn('user@example.com')
  gis.grantNext({ access_token: 'tok-2' })
  await again
  expect(broker.getState()).toBe('ready')
}

function recordStates(broker: AuthBroker): AuthState[] {
  const states: AuthState[] = []
  broker.subscribe((state) => states.push(state))
  return states
}

describe('AuthBroker retired renewal settling after a re-sign-in', () => {
  it('a retired renewal whose GIS grant lands after re-sign-in keeps the fresh session ready', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    const { renewal, request } = await startRenewal(gis, broker)
    await signOutAndBackIn(gis, broker)
    const states = recordStates(broker)

    // GIS settles the first popup now: the old flight's epoch snapshot is
    // stale, so verifyAndPromote rejects it before touching the cache.
    request.callback({ access_token: 'tok-stale', expires_in: 3600, scope: AUTH_SCOPES })
    await expect(renewal).rejects.toMatchObject({ reason: 'stale_epoch' })

    expect(states).toEqual([])
    expect(broker.getState()).toBe('ready')
    await expect(broker.getToken()).resolves.toBe('tok-2')
  })

  it('a retired renewal whose popup is closed after re-sign-in keeps the fresh session ready', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    const { renewal, request } = await startRenewal(gis, broker)
    await signOutAndBackIn(gis, broker)
    const states = recordStates(broker)

    request.error_callback?.({ type: 'popup_closed' })
    await expect(renewal).rejects.toMatchObject({ reason: 'renewal_failed' })

    expect(states).toEqual([])
    expect(broker.getState()).toBe('ready')
    await expect(broker.getToken()).resolves.toBe('tok-2')
  })

  it('a renewal parked in profile verification across sign-out and re-sign-in keeps the fresh session ready', async () => {
    const gis = new FakeGis()
    const broker = newBroker(gis)
    const parked = deferred<string>()
    gis.verifyToken = (accessToken) =>
      accessToken === 'tok-stale' ? parked.promise : Promise.resolve('user@example.com')
    const { renewal, request } = await startRenewal(gis, broker)
    // The grant arrived before the sign-out; its verification is still out.
    request.callback({ access_token: 'tok-stale', expires_in: 3600, scope: AUTH_SCOPES })
    await signOutAndBackIn(gis, broker)
    const states = recordStates(broker)

    parked.resolve('user@example.com')
    await expect(renewal).rejects.toMatchObject({ reason: 'stale_epoch' })

    expect(states).toEqual([])
    expect(broker.getState()).toBe('ready')
    await expect(broker.getToken()).resolves.toBe('tok-2')
  })

  it('a renewal of the current generation that fails still moves to needs_interaction', async () => {
    // The guard keys on the epoch, not on the state: a live renewal failing
    // under an unchanged epoch is exactly the case the demotion exists for.
    const gis = new FakeGis()
    const broker = newBroker(gis)
    const { renewal, request } = await startRenewal(gis, broker)

    request.error_callback?.({ type: 'popup_closed' })
    await expect(renewal).rejects.toMatchObject({ reason: 'renewal_failed' })

    expect(broker.getState()).toBe('needs_interaction')
    await expect(broker.getToken()).rejects.toMatchObject({ reason: 'needs_interaction' })
  })
})
