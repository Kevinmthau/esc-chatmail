// Local id generation that survives an insecure origin.
//
// `crypto.randomUUID()` is `[SecureContext]` in the Web Crypto spec, so it is
// simply *undefined* on a plain-http origin that is not localhost/127.0.0.1 —
// exactly the setup used for the first realistic mobile test of this
// mobile-first PWA (`pnpm dev --host`, then browsing to http://192.168.x.x:5173
// from a phone) and for any plain-http deployment. Calling it there throws
// "crypto.randomUUID is not a function" on the first conversation created or
// message sent, surfacing as an opaque sync failure. `crypto.getRandomValues()`
// is NOT secure-context gated, so it stays available in those contexts and
// supplies the same 122 random bits.
//
// THESE IDS ARE LOCAL-ONLY AND NOT SECURITY-BEARING. They name Dexie rows
// (conversation ids, optimistic message ids, recipient chip keys) and salt the
// conversation-identity epoch key. They are never secrets, capabilities, or
// authorization tokens, and nothing downstream assumes they are unguessable.
// That is what makes the final `Math.random` tail acceptable for an environment
// with no Web Crypto at all: it costs uniqueness margin, not security. Anything
// that ever does need unpredictability must not use this helper.
//
// (Other secure-context-only APIs degrade on their own: `navigator.locks` is
// feature-detected in creationLock.ts / engine.ts / pendingActions.ts and falls
// back to an in-process lock, and service-worker registration — hence PWA
// install — is simply unavailable. LAN testing over https, e.g. a tunnel or a
// self-signed cert, remains the way to exercise those.)

/** Web Crypto as it may actually exist at runtime, rather than as lib.dom types it. */
type MaybeCrypto = Partial<Crypto> | undefined

/**
 * A random v4-shaped UUID string, usable in insecure contexts.
 *
 * Prefers `crypto.randomUUID()`, falls back to `crypto.getRandomValues()`, and
 * only then to `Math.random()`. Use this instead of `crypto.randomUUID()` at
 * every call site.
 */
export function newId(): string {
  // Read through globalThis on every call so tests can stub the global.
  const webCrypto: MaybeCrypto = globalThis.crypto
  if (typeof webCrypto?.randomUUID === 'function') {
    return webCrypto.randomUUID()
  }
  return formatUuidV4(randomBytes(webCrypto))
}

function randomBytes(webCrypto: MaybeCrypto): Uint8Array {
  const bytes = new Uint8Array(16)
  if (typeof webCrypto?.getRandomValues === 'function') {
    webCrypto.getRandomValues(bytes)
    return bytes
  }
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Math.floor(Math.random() * 256)
  }
  return bytes
}

/** Stamps the version (4) and variant (RFC 4122) bits, then hex-formats 8-4-4-4-12. */
function formatUuidV4(bytes: Uint8Array): string {
  // `?? 0` is unreachable: the array is always 16 bytes long.
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80

  let out = ''
  for (let i = 0; i < bytes.length; i += 1) {
    if (i === 4 || i === 6 || i === 8 || i === 10) out += '-'
    out += (bytes[i] ?? 0).toString(16).padStart(2, '0')
  }
  return out
}
