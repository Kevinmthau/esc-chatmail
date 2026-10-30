// Real-mode boot harness shared by the boot regression suites: a fake GIS
// surface driving a real AuthBroker. Each suite still declares its own
// vi.mock calls (they are hoisted per file) and passes its getProfile mock in.

import {
  AUTH_EPOCH_STORAGE_KEY,
  AUTH_SCOPES,
  AUTH_SESSION_STORAGE_KEY,
  AuthBroker,
} from '@/auth/authBroker'
import type {
  GisSurface,
  GisTokenClientConfig,
  GisTokenResponse,
  StoredAuthSession,
} from '@/auth/authBroker'
import { dbNameForAccount } from '@/db/schema'
import { setBootOverridesForTests } from './boot'

export function memoryStorage(): Storage {
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

export class FakeGis {
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
}

export function seedStoredSession(
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
export function bootWithBroker(gis: FakeGis, getProfile: () => Promise<unknown>): AuthBroker {
  const broker = new AuthBroker(gis.surface(), {
    clientId: 'test-client-id',
    createChannel: () => null,
    verifyAccessToken: async () => {
      const profile = (await getProfile()) as { emailAddress: string }
      return profile.emailAddress
    },
  })
  setBootOverridesForTests({
    clientId: '123-real.apps.googleusercontent.com',
    createBroker: () => broker,
  })
  return broker
}

/** Mirrors boot's durable install-timestamp marker key. */
export function installMarkerKey(email: string): string {
  return `esc.account.installTs.v1.${dbNameForAccount(email)}`
}

/** Mirrors boot's durable session-evidence marker (grant expiry, ms epoch). */
export const SESSION_EVIDENCE_KEY = 'esc.account.sessionUntil.v1'
