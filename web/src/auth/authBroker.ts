// Auth broker: Google Identity Services (GIS) token lifecycle for the web app.
//
// Ports the token-lifecycle invariants from the iOS app
// (esc-chatmail/Services/Security/TokenManager.swift + AuthSession.swift):
//   - 5-minute expiry horizon: a token within 5 minutes of expiry is treated as
//     expired and renewed before use (TokenInfo.isExpiringSoon).
//   - Single-flight renewal: concurrent callers share ONE renewal
//     (TaskCoordinator.getOrCreateTask).
//   - Epoch guard: sign-out bumps a monotonically increasing epoch in the same
//     synchronous section that drops cached state; every acquisition snapshots
//     the epoch before calling GIS and discards the result if the epoch moved,
//     so a grant that raced a sign-out can never resurrect the session
//     (TokenManager cacheEpoch discipline).
//   - Scope enforcement: every grant must include gmail.modify or the session
//     is not usable (AuthSession.hasRequiredGmailScope).

export type AuthState = 'signed_out' | 'authorizing' | 'ready' | 'needs_interaction'

export type AuthRequiredReason =
  | 'signed_out'
  | 'needs_interaction'
  | 'renewal_failed'
  | 'scope_denied'
  | 'stale_epoch'
  | 'account_changed'

/** Typed error rejected to callers whenever a token cannot be produced without user interaction. */
export class AuthRequiredError extends Error {
  readonly reason: AuthRequiredReason

  constructor(message: string, reason: AuthRequiredReason) {
    super(message)
    this.name = 'AuthRequiredError'
    this.reason = reason
  }
}

/**
 * A successfully verified grant belongs to a different Google account than
 * the session that requested it. The new account is adopted, but the request
 * that triggered the switch must stop: it still owns the previous account's
 * database and other session-scoped dependencies.
 */
export class AuthAccountChangedError extends AuthRequiredError {
  readonly previousEmail: string
  readonly nextEmail: string

  constructor(previousEmail: string, nextEmail: string) {
    super(`Google account changed from ${previousEmail} to ${nextEmail}`, 'account_changed')
    this.name = 'AuthAccountChangedError'
    this.previousEmail = previousEmail
    this.nextEmail = nextEmail
  }
}

// ---------------------------------------------------------------------------
// GIS surface (injectable so tests never touch real Google Identity Services)
// ---------------------------------------------------------------------------

export interface GisTokenResponse {
  access_token?: string
  /** Seconds until expiry. GIS documents a number; be tolerant of strings. */
  expires_in?: number | string
  /** Space-delimited scopes actually granted. */
  scope?: string
  error?: string
  error_description?: string
}

export interface GisClientError {
  type?: string
  message?: string
}

export interface GisTokenClientConfig {
  client_id: string
  scope: string
  prompt: '' | 'consent'
  login_hint?: string
  callback: (response: GisTokenResponse) => void
  error_callback?: (error: GisClientError) => void
}

export interface GisTokenClient {
  requestAccessToken(): void
}

/** `google.accounts.oauth2.revoke`'s callback payload. */
export interface GisRevocationResponse {
  successful?: boolean
  error?: string
  error_description?: string
}

export interface GisSurface {
  createTokenClient(cfg: GisTokenClientConfig): GisTokenClient
  revoke(token: string, done?: (response: GisRevocationResponse) => void): void
  now(): number
  /** Session-scoped store for the token record (per-tab by design). */
  storage: Storage
  /**
   * Durable store for non-secret UX flags (has-ever-signed-in). Defaults to
   * `storage`; production passes localStorage so closing the tab does not
   * re-trigger the full restricted-scope consent screen.
   */
  flagStorage?: Storage
}

// ---------------------------------------------------------------------------
// Cross-tab channel (injectable; a manual fake works when tests need one)
// ---------------------------------------------------------------------------

export interface AuthChannelMessageEvent {
  data: unknown
}

export interface AuthChannel {
  postMessage(message: unknown): void
  onmessage: ((ev: AuthChannelMessageEvent) => void) | null
  close(): void
}

export interface AuthSignOutMessage {
  type: 'signed_out'
  epoch: number
}

export interface AuthBrokerOptions {
  /** Defaults to import.meta.env.VITE_GOOGLE_CLIENT_ID. */
  clientId?: string
  /** Defaults to a real BroadcastChannel('auth') when available. */
  createChannel?: () => AuthChannel | null
  /**
   * Resolves the Gmail profile email using the candidate token directly.
   * Injectable so broker tests do not touch the network.
   */
  verifyAccessToken?: (accessToken: string) => Promise<string>
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const GMAIL_MODIFY_SCOPE = 'https://www.googleapis.com/auth/gmail.modify'
export const AUTH_SCOPES = `openid email profile ${GMAIL_MODIFY_SCOPE}`

/** iOS 5-minute horizon: tokens closer than this to expiry are treated as expired. */
const EXPIRY_HORIZON_MS = 5 * 60 * 1000

export const AUTH_SESSION_STORAGE_KEY = 'esc.auth.session.v1'
export const AUTH_EPOCH_STORAGE_KEY = 'esc.auth.epoch.v1'
export const AUTH_HAS_SIGNED_IN_STORAGE_KEY = 'esc.auth.hasSignedIn.v1'
export const AUTH_CHANNEL_NAME = 'auth'

export interface StoredAuthSession {
  accessToken: string
  expiresAt: number
  scope: string
  epoch: number
  email: string | null
}

// ---------------------------------------------------------------------------
// Broker
// ---------------------------------------------------------------------------

type Listener = (state: AuthState) => void
type WipeHook = () => void | Promise<void>

interface CachedGrant {
  accessToken: string
  expiresAt: number
  scope: string
}

export class AuthBroker {
  private readonly gis: GisSurface
  /** Durable (non-secret) flag store; see GisSurface.flagStorage. */
  private readonly flagStorage: Storage
  private readonly clientId: string
  private readonly channel: AuthChannel | null
  private readonly verifyAccessToken: (accessToken: string) => Promise<string>
  private readonly listeners = new Set<Listener>()
  private readonly wipeHooks: WipeHook[] = []

  private state: AuthState = 'signed_out'
  /** Sign-out generation. Bumped synchronously by signOut; acquisitions snapshot it. */
  private epoch = 0
  private cached: CachedGrant | null = null
  /**
   * VERIFIED account identity only — never a typed/remembered login hint. New
   * grants set it only after the candidate token resolves Gmail's profile;
   * restore() accepts only records written after that verification. Everything
   * that names a database, an accounts row, or an alias set derives from this.
   */
  private email: string | null = null
  /**
   * UNVERIFIED login hint (what the user typed on the sign-in card, or the last
   * account this broker asked GIS for). GIS treats login_hint as a suggestion
   * and may grant a completely different account, so this value may only ever
   * be used as a login_hint — never as an identity.
   */
  private loginHint: string | null = null
  /**
   * Blocks token access after a verified account switch until the app confirms
   * it has established dependencies for the new account via setAccountEmail.
   */
  private accountChange: AuthAccountChangedError | null = null
  /** Single-flight acquisition shared by all concurrent callers. */
  private pending: Promise<string> | null = null

  constructor(gis: GisSurface, options: AuthBrokerOptions = {}) {
    this.gis = gis
    this.flagStorage = gis.flagStorage ?? gis.storage
    this.clientId = options.clientId ?? envClientId()
    this.verifyAccessToken = options.verifyAccessToken ?? verifyAccessTokenWithGmailProfile
    this.restore()
    this.channel = (options.createChannel ?? defaultCreateChannel)()
    if (this.channel) {
      this.channel.onmessage = (ev) => {
        this.onChannelMessage(ev.data)
      }
    }
  }

  // -- Observation ----------------------------------------------------------

  /** For React (useSyncExternalStore): notifies on every state transition. */
  subscribe(listener: Listener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  getState(): AuthState {
    return this.state
  }

  /**
   * The VERIFIED account email, or null when this grant's account has not been
   * resolved yet. Callers that name a database / accounts row / alias set must
   * use this (never getLoginHint()).
   */
  getEmail(): string | null {
    return this.email
  }

  /**
   * Best available `login_hint` for the next GIS request: the verified account
   * when known, otherwise the last unverified hint. NOT an identity.
   */
  getLoginHint(): string | null {
    return this.email ?? this.loginHint
  }

  /** Expiry of the cached grant (ms epoch), or null when there is no grant. */
  getExpiresAt(): number | null {
    return this.cached?.expiresAt ?? null
  }

  /**
   * Adopts an independently VERIFIED account email for the current grant.
   * Acquisition performs this verification before publishing a new token;
   * callers that already fetched the profile may use this to reinforce or
   * correct restored identity. Typed login hints never flow through here.
   */
  setAccountEmail(email: string): void {
    const normalized = normalizeLoginHint(email)
    if (normalized === null) return
    if (normalized === this.email) {
      // The app has opened/re-established this verified account's DB and may
      // now expose its token to newly created session-scoped workers.
      this.accountChange = null
      return
    }
    this.email = normalized
    this.accountChange = null
    if (this.cached !== null) this.persistSession(this.cached)
  }

  /** Sign-out cleanup hooks (DB wipe, cache clears). Returns an unregister function. */
  registerWipeHook(hook: WipeHook): () => void {
    this.wipeHooks.push(hook)
    return () => {
      const index = this.wipeHooks.indexOf(hook)
      if (index >= 0) this.wipeHooks.splice(index, 1)
    }
  }

  // -- Token acquisition ----------------------------------------------------

  /**
   * Returns the cached access token when it is fresher than the 5-minute
   * horizon; otherwise starts (or joins) exactly one silent renewal.
   */
  getToken(): Promise<string> {
    if (this.state === 'signed_out') {
      return Promise.reject(new AuthRequiredError('Not signed in', 'signed_out'))
    }
    if (this.state === 'needs_interaction') {
      return Promise.reject(new AuthRequiredError('User interaction required', 'needs_interaction'))
    }
    if (this.accountChange !== null) return Promise.reject(this.accountChange)
    const cached = this.cached
    if (cached && cached.expiresAt - this.gis.now() > EXPIRY_HORIZON_MS) {
      return Promise.resolve(cached.accessToken)
    }
    return this.renewSilently()
  }

  /**
   * 401 recovery path. If the current token already differs from the token the
   * failed request used, someone else refreshed — return it. Otherwise renew
   * (single-flight, shared with getToken callers).
   */
  refreshAfter(staleToken: string): Promise<string> {
    if (this.state === 'signed_out') {
      return Promise.reject(new AuthRequiredError('Not signed in', 'signed_out'))
    }
    if (this.state === 'needs_interaction') {
      return Promise.reject(new AuthRequiredError('User interaction required', 'needs_interaction'))
    }
    if (this.accountChange !== null) return Promise.reject(this.accountChange)
    const cached = this.cached
    if (cached && cached.accessToken !== staleToken) {
      return Promise.resolve(cached.accessToken)
    }
    return this.renewSilently()
  }

  /**
   * User-gesture sign-in. First ever sign-in prompts for consent; later
   * sign-ins use prompt '' (silent when the Google session still exists).
   */
  async interactiveSignIn(loginHint?: string): Promise<void> {
    const firstEverSignIn = safeGet(this.flagStorage, AUTH_HAS_SIGNED_IN_STORAGE_KEY) == null
    const prompt: '' | 'consent' = firstEverSignIn ? 'consent' : ''
    const hint = normalizeLoginHint(loginHint)
    // A typed hint is NOT an identity: GIS may (and with the account chooser
    // routinely does) grant a different account than the hint names. Adopting
    // it as this.email would name the database, the accounts row and the alias
    // set after an account that does not own the token. It stays a hint until
    // the candidate token's Gmail profile is verified inside acquire().
    if (hint !== null) this.loginHint = hint
    const previousState = this.state
    this.setState('authorizing')

    const flight = this.acquire(hint !== null ? { prompt, loginHint: hint } : { prompt })
    const shared: Promise<string> = flight.then(
      (token) => {
        if (this.pending === shared) this.pending = null
        return token
      },
      (err: unknown) => {
        if (this.pending === shared) this.pending = null
        // Scope-denied and stale-epoch failures already moved the state;
        // anything else (user cancel, popup failure) reverts to where we were.
        if (this.state === 'authorizing') this.setState(previousState)
        throw toAuthRequired(err, 'needs_interaction')
      },
    )
    if (this.pending === null) this.pending = shared
    await shared
    safeSet(this.flagStorage, AUTH_HAS_SIGNED_IN_STORAGE_KEY, '1')
  }

  /**
   * Sign out. The epoch bump, cache drop, and signed_out transition happen
   * synchronously (before any await) so no acquisition started afterwards can
   * resurrect the retired generation. Persisted state is retired in that same
   * section so a reload during a slow wipe cannot restore it.
   */
  async signOut(): Promise<void> {
    const tokenToRevoke = this.cached?.accessToken ?? null

    // Retire the sign-in generation synchronously (iOS clearTokens critical section).
    this.epoch += 1
    this.cached = null
    this.email = null
    this.loginHint = null
    this.accountChange = null
    this.pending = null

    // Persist retirement before ANY awaited cleanup. A reload/crash while a
    // DB wipe is pending must observe the new epoch, never the old token.
    safeRemove(this.gis.storage, AUTH_SESSION_STORAGE_KEY)
    safeRemove(this.flagStorage, AUTH_HAS_SIGNED_IN_STORAGE_KEY)
    safeSet(this.gis.storage, AUTH_EPOCH_STORAGE_KEY, String(this.epoch))

    // Broadcast so other tabs drop their state.
    if (this.channel) {
      try {
        const message: AuthSignOutMessage = { type: 'signed_out', epoch: this.epoch }
        this.channel.postMessage(message)
      } catch {
        // Channel closed by the environment; local sign-out proceeds.
      }
    }

    this.setState('signed_out')

    // Best-effort revoke. GIS reports failures through the callback (a CSP
    // refusal or network error never throws synchronously), so pass one:
    // otherwise a policy that blocks the revocation endpoint leaves the grant
    // alive at Google with no trace at all.
    if (tokenToRevoke !== null) {
      try {
        this.gis.revoke(tokenToRevoke, (response) => {
          if (response.successful === false) reportRevocationFailure(response)
        })
      } catch (err) {
        reportRevocationFailure({ error: err instanceof Error ? err.message : 'revoke threw' })
      }
    }

    // Wipe hooks (DB wipe, caches). Failures must not block sign-out.
    for (const hook of this.wipeHooks) {
      try {
        await hook()
      } catch {
        // Best-effort cleanup; continue with remaining hooks.
      }
    }
  }

  /** Detach from the cross-tab channel and drop listeners (tests, teardown). */
  close(): void {
    if (this.channel) {
      try {
        this.channel.close()
      } catch {
        // Already closed.
      }
    }
    this.listeners.clear()
  }

  // -- Internals ------------------------------------------------------------

  private restore(): void {
    this.epoch = readStoredEpoch(this.gis.storage)
    const raw = safeGet(this.gis.storage, AUTH_SESSION_STORAGE_KEY)
    if (raw === null) return
    const record = parseStoredSession(raw)
    if (record === null || record.epoch !== this.epoch || !scopeIncludesGmailModify(record.scope)) {
      // Stale-epoch (or malformed) records belong to a retired sign-in
      // generation and must never resurrect a session.
      safeRemove(this.gis.storage, AUTH_SESSION_STORAGE_KEY)
      return
    }
    this.cached = {
      accessToken: record.accessToken,
      expiresAt: record.expiresAt,
      scope: record.scope,
    }
    this.email = record.email
    this.state = 'ready'
  }

  private setState(next: AuthState): void {
    if (this.state === next) return
    this.state = next
    this.notify(next)
  }

  private notify(state: AuthState): void {
    for (const listener of [...this.listeners]) listener(state)
  }

  private renewSilently(): Promise<string> {
    if (this.pending) return this.pending
    // Bind the renewal to the account this broker already represents. Without
    // a login_hint GIS resolves the grant against the browser's CURRENT default
    // Google session, which may be a different account — that token would then
    // be run against this account's database. The hint is a request, not a
    // guarantee (Google may ignore it), so acquire() verifies the candidate's
    // Gmail profile before promotion. A token swap then notifies listeners so
    // the app can re-establish account-scoped dependencies.
    const hint = this.getLoginHint()
    const flight: Promise<string> = this.acquire(
      hint !== null ? { prompt: '', loginHint: hint } : { prompt: '' },
    ).then(
      (token) => {
        if (this.pending === flight) this.pending = null
        return token
      },
      (err: unknown) => {
        if (this.pending === flight) this.pending = null
        const failure = toAuthRequired(err, 'renewal_failed')
        // A sign-out mid-flight already moved us to signed_out. An account
        // change deliberately adopted the verified replacement grant and
        // published ready; the old-session caller alone must be rejected.
        if (this.state !== 'signed_out' && failure.reason !== 'account_changed') {
          this.setState('needs_interaction')
        }
        throw failure
      },
    )
    this.pending = flight
    return flight
  }

  private acquire(opts: { prompt: '' | 'consent'; loginHint?: string }): Promise<string> {
    // Snapshot the sign-out generation BEFORE calling GIS: if signOut bumps
    // the epoch while the grant is in flight, the result is discarded.
    const epochAtStart = this.epoch
    const accountAtStart = this.email
    return new Promise<string>((resolve, reject) => {
      let settled = false
      const settleOnce = (fn: () => void) => {
        if (settled) return
        settled = true
        fn()
      }

      const cfg: GisTokenClientConfig = {
        client_id: this.clientId,
        scope: AUTH_SCOPES,
        prompt: opts.prompt,
        callback: (response) => {
          settleOnce(() => {
            void this.verifyAndPromote(response, epochAtStart, accountAtStart).then(resolve, reject)
          })
        },
        error_callback: (error) => {
          settleOnce(() => {
            reject(
              new AuthRequiredError(
                error.message ?? error.type ?? 'Token client error',
                'renewal_failed',
              ),
            )
          })
        },
      }
      if (opts.loginHint !== undefined) cfg.login_hint = opts.loginHint

      try {
        this.gis.createTokenClient(cfg).requestAccessToken()
      } catch (err) {
        settleOnce(() => {
          reject(toAuthRequired(err, 'renewal_failed'))
        })
      }
    })
  }

  /** Verify a candidate grant before it becomes observable to general callers. */
  private async verifyAndPromote(
    response: GisTokenResponse,
    epochAtStart: number,
    accountAtStart: string | null,
  ): Promise<string> {
    if (this.epoch !== epochAtStart) {
      throw new AuthRequiredError('Signed out during token acquisition', 'stale_epoch')
    }
    if (response.error !== undefined || !response.access_token) {
      throw new AuthRequiredError(
        response.error_description ?? response.error ?? 'Token grant failed',
        'renewal_failed',
      )
    }
    if (!scopeIncludesGmailModify(response.scope)) {
      this.setState('needs_interaction')
      throw new AuthRequiredError(
        'Gmail permission was not granted; re-consent required',
        'scope_denied',
      )
    }

    const expiresInSeconds = Number(response.expires_in ?? 0)
    const grant: CachedGrant = {
      accessToken: response.access_token,
      expiresAt: this.gis.now() + expiresInSeconds * 1000,
      scope: response.scope ?? '',
    }
    const verifiedEmail = normalizeLoginHint(await this.verifyAccessToken(grant.accessToken))
    if (verifiedEmail === null) {
      throw new AuthRequiredError(
        'Gmail profile did not include an account email',
        'renewal_failed',
      )
    }

    // Verification is asynchronous. Re-check the generation before publishing
    // anything so sign-out during the profile request still wins.
    if (this.epoch !== epochAtStart) {
      throw new AuthRequiredError('Signed out during token verification', 'stale_epoch')
    }

    const previousToken = this.cached?.accessToken ?? null
    const expectedEmail = accountAtStart ?? this.email
    const accountChange =
      expectedEmail !== null && expectedEmail !== verifiedEmail
        ? new AuthAccountChangedError(expectedEmail, verifiedEmail)
        : null

    if (accountChange !== null) {
      // Retire the old account generation before publishing the replacement.
      // This invalidates other work tied to the old session, while persisting
      // a self-consistent {token, email, epoch} record for the new account.
      this.epoch += 1
    }
    this.cached = grant
    this.email = verifiedEmail
    this.accountChange = accountChange
    this.persistSession(grant)

    const wasReady = this.state === 'ready'
    this.setState('ready')
    if (wasReady && previousToken !== grant.accessToken) this.notify('ready')

    if (accountChange !== null) {
      // The ready notification synchronously tears down old account workers.
      // Rejecting the triggering request prevents it from resuming with the
      // new token while it still holds the previous account's DB/context.
      throw accountChange
    }
    return grant.accessToken
  }

  private persistSession(grant: CachedGrant): void {
    const record: StoredAuthSession = {
      accessToken: grant.accessToken,
      expiresAt: grant.expiresAt,
      scope: grant.scope,
      epoch: this.epoch,
      email: this.email,
    }
    safeSet(this.gis.storage, AUTH_SESSION_STORAGE_KEY, JSON.stringify(record))
    safeSet(this.gis.storage, AUTH_EPOCH_STORAGE_KEY, String(this.epoch))
  }

  private onChannelMessage(data: unknown): void {
    if (!isSignOutMessage(data)) return
    // Adopt the remote generation and always advance past our own, so any
    // acquisition in flight in THIS tab is discarded by its epoch snapshot.
    this.epoch = Math.max(this.epoch + 1, data.epoch)
    this.cached = null
    this.email = null
    this.loginHint = null
    this.accountChange = null
    this.pending = null
    // sessionStorage is PER-TAB: the originating tab's signOut cleared only
    // its own storage. Mirror that persistence here, or a reload of THIS tab
    // would restore() the retired token from this tab's storage and resurrect
    // the signed-out session. (The DB wipe belongs to the originating tab;
    // the token record must go everywhere.)
    safeRemove(this.gis.storage, AUTH_SESSION_STORAGE_KEY)
    safeRemove(this.flagStorage, AUTH_HAS_SIGNED_IN_STORAGE_KEY)
    safeSet(this.gis.storage, AUTH_EPOCH_STORAGE_KEY, String(this.epoch))
    this.setState('signed_out')
  }
}

// ---------------------------------------------------------------------------
// Production wiring
// ---------------------------------------------------------------------------

interface GoogleOauth2Namespace {
  initTokenClient(config: GisTokenClientConfig): GisTokenClient
  revoke(token: string, done?: (response: GisRevocationResponse) => void): void
}

declare global {
  interface Window {
    google?: {
      accounts?: {
        oauth2?: GoogleOauth2Namespace
      }
    }
  }
}

/**
 * Wires the broker to the real GIS script, sessionStorage (the token record —
 * per-tab on purpose), localStorage (durable non-secret flags), and
 * BroadcastChannel.
 */
export function createGisAuthBroker(options: AuthBrokerOptions = {}): AuthBroker {
  const oauth2 = window.google?.accounts?.oauth2
  if (!oauth2) {
    throw new Error('Google Identity Services is not loaded (window.google.accounts.oauth2)')
  }
  return new AuthBroker(
    {
      createTokenClient: (cfg) => oauth2.initTokenClient(cfg),
      revoke: (token, done) => {
        oauth2.revoke(token, done)
      },
      now: () => Date.now(),
      storage: window.sessionStorage,
      flagStorage: durableFlagStorage(),
    },
    options,
  )
}

/** localStorage when usable (private modes can throw on access), else session. */
function durableFlagStorage(): Storage {
  try {
    const storage = window.localStorage
    const probe = 'esc.auth.probe'
    storage.setItem(probe, '1')
    storage.removeItem(probe)
    return storage
  } catch {
    return window.sessionStorage
  }
}

/**
 * Sign-out revocation failed. Not fatal (local state is already wiped), but it
 * means the grant is still live at Google — the common cause is a CSP that
 * does not allow the revocation endpoint, which is otherwise invisible.
 */
function reportRevocationFailure(response: GisRevocationResponse): void {
  const detail = response.error_description ?? response.error ?? 'unknown error'
  console.warn(`[auth] token revocation failed on sign-out: ${detail}`)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function envClientId(): string {
  const env: Record<string, unknown> = import.meta.env
  const id = env['VITE_GOOGLE_CLIENT_ID']
  return typeof id === 'string' ? id : ''
}

function defaultCreateChannel(): AuthChannel | null {
  if (typeof BroadcastChannel === 'undefined') return null
  return new BroadcastChannel(AUTH_CHANNEL_NAME) as unknown as AuthChannel
}

/**
 * Resolve the account using only the unpromoted candidate token. Supplying a
 * tiny TokenBroker avoids calling AuthBroker.getToken() from inside its own
 * acquisition single-flight (which would otherwise await itself forever).
 */
async function verifyAccessTokenWithGmailProfile(accessToken: string): Promise<string> {
  const { getProfile } = await import('../gmail/endpoints')
  const candidateBroker = {
    getToken: () => Promise.resolve(accessToken),
    refreshAfter: () =>
      Promise.reject(
        new AuthRequiredError('Gmail rejected the candidate access token', 'renewal_failed'),
      ),
  }
  const profile = await getProfile(candidateBroker)
  return profile.emailAddress
}

function scopeIncludesGmailModify(scope: string | undefined): boolean {
  if (!scope) return false
  return scope.split(/\s+/).includes(GMAIL_MODIFY_SCOPE)
}

/**
 * Trims AND lowercases. Addresses flow straight into dbNameForAccount (which
 * lowercases before hashing) and into db.accounts' primary key (which does
 * not), so a mixed-case value would otherwise key the row differently from the
 * database it names.
 */
function normalizeLoginHint(value: string | undefined): string | null {
  if (value === undefined) return null
  const trimmed = value.trim().toLowerCase()
  return trimmed === '' ? null : trimmed
}

function toAuthRequired(err: unknown, reason: AuthRequiredReason): AuthRequiredError {
  if (err instanceof AuthRequiredError) return err
  const message = err instanceof Error ? err.message : 'Token acquisition failed'
  return new AuthRequiredError(message, reason)
}

function isSignOutMessage(data: unknown): data is AuthSignOutMessage {
  if (typeof data !== 'object' || data === null) return false
  const record = data as Record<string, unknown>
  return record['type'] === 'signed_out' && typeof record['epoch'] === 'number'
}

function readStoredEpoch(storage: Storage): number {
  const raw = safeGet(storage, AUTH_EPOCH_STORAGE_KEY)
  if (raw === null) return 0
  const value = Number.parseInt(raw, 10)
  return Number.isFinite(value) && value >= 0 ? value : 0
}

function parseStoredSession(raw: string): StoredAuthSession | null {
  try {
    const value: unknown = JSON.parse(raw)
    if (typeof value !== 'object' || value === null) return null
    const record = value as Record<string, unknown>
    const accessToken = record['accessToken']
    const expiresAt = record['expiresAt']
    const scope = record['scope']
    const epoch = record['epoch']
    const email = record['email']
    if (typeof accessToken !== 'string' || accessToken === '') return null
    if (typeof expiresAt !== 'number' || !Number.isFinite(expiresAt)) return null
    if (typeof scope !== 'string') return null
    if (typeof epoch !== 'number' || !Number.isFinite(epoch)) return null
    return {
      accessToken,
      expiresAt,
      scope,
      epoch,
      email: typeof email === 'string' ? email : null,
    }
  } catch {
    return null
  }
}

function safeGet(storage: Storage, key: string): string | null {
  try {
    return storage.getItem(key)
  } catch {
    return null
  }
}

function safeSet(storage: Storage, key: string, value: string): void {
  try {
    storage.setItem(key, value)
  } catch {
    // Storage can be unavailable (private mode, quota); persistence is best-effort.
  }
}

function safeRemove(storage: Storage, key: string): void {
  try {
    storage.removeItem(key)
  } catch {
    // Best-effort.
  }
}
