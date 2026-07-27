import Dexie from 'dexie'
import type { ChatmailDB } from './schema'

// Attachment bytes live in IndexedDB (not OPFS) so blob writes commit in the
// same transaction domain as their metadata rows. LRU-pruned by lastAccessAt:
// putBlob prunes opportunistically (every N puts / M bytes written) and again
// on a QuotaExceededError, so re-fetchable bytes cannot grow without bound and
// a full origin quota cannot permanently wedge attachment downloads. Inline
// (cid) bytes are exempt from eviction — see pruneBlobs.
//
// Every blob write in the app must go through putBlob — a bare db.blobs.put
// throws a raw DOMException that aborts whatever transaction it runs in.

/** Ceiling when the browser reports no quota estimate. */
const DEFAULT_MAX_BYTES = 512 * 1024 * 1024
/** Share of the origin quota the blob store may occupy. */
const QUOTA_BUDGET_FRACTION = 0.5
/** Tighter share once the origin is already near its quota. */
const PRESSURE_BUDGET_FRACTION = 0.25
/** usage/quota at which the tighter budget kicks in. */
const USAGE_PRESSURE_RATIO = 0.8
/** Cadence of the opportunistic prune check: whichever threshold trips first. */
const PUTS_BETWEEN_PRUNE_CHECKS = 20
const BYTES_BETWEEN_PRUNE_CHECKS = 32 * 1024 * 1024
/** Floor on how much a quota-triggered eviction frees, so a retry has headroom. */
const MIN_EVICTION_BYTES = 16 * 1024 * 1024

/**
 * A blob could not be stored because the origin is out of space, and evicting
 * the LRU tail did not free enough. Distinguishable on purpose: callers mark
 * the attachment failed (retry affordance) instead of propagating a raw
 * DOMException into a sync transaction.
 */
export class BlobQuotaExceededError extends Error {
  readonly key: string

  constructor(key: string, options?: { cause?: unknown }) {
    super(`Storage quota exceeded while storing blob ${key}`, options)
    this.name = 'BlobQuotaExceededError'
    this.key = key
  }
}

/** True for a DOMException/Dexie quota error, however deeply it is wrapped. */
export function isQuotaExceededError(error: unknown, depth = 0): boolean {
  if (error === null || typeof error !== 'object' || depth > 3) return false
  const candidate = error as { name?: unknown; code?: unknown; inner?: unknown; cause?: unknown }
  if (candidate.name === 'QuotaExceededError' || candidate.name === 'NS_ERROR_DOM_QUOTA_REACHED') {
    return true
  }
  // Legacy DOMException code for QUOTA_EXCEEDED_ERR.
  if (candidate.code === 22 && typeof candidate.name === 'string') return true
  return (
    isQuotaExceededError(candidate.inner, depth + 1) ||
    isQuotaExceededError(candidate.cause, depth + 1)
  )
}

function inTransaction(): boolean {
  return Dexie.currentTransaction !== null && Dexie.currentTransaction !== undefined
}

async function storageEstimate(): Promise<StorageEstimate | null> {
  try {
    const storage = globalThis.navigator?.storage as StorageManager | undefined
    if (typeof storage?.estimate !== 'function') return null
    return await storage.estimate()
  } catch {
    return null
  }
}

/** Byte budget for the blob store, derived from the origin quota when known. */
async function blobBudgetBytes(): Promise<number> {
  const estimate = await storageEstimate()
  const quota = estimate?.quota ?? 0
  if (quota <= 0) return DEFAULT_MAX_BYTES
  const usage = estimate?.usage ?? 0
  const fraction =
    usage / quota >= USAGE_PRESSURE_RATIO ? PRESSURE_BUDGET_FRACTION : QUOTA_BUDGET_FRACTION
  return Math.min(DEFAULT_MAX_BYTES, Math.floor(quota * fraction))
}

// Opportunistic-prune accounting (module scope: one blob store per open DB).
let putsSinceCheck = 0
let bytesSinceCheck = 0

/** Test hook: forget how much has been written since the last prune check. */
export function resetBlobPruneCountersForTests(): void {
  putsSinceCheck = 0
  bytesSinceCheck = 0
}

async function maybePrune(db: ChatmailDB, writtenBytes: number): Promise<void> {
  putsSinceCheck += 1
  bytesSinceCheck += writtenBytes
  if (putsSinceCheck < PUTS_BETWEEN_PRUNE_CHECKS && bytesSinceCheck < BYTES_BETWEEN_PRUNE_CHECKS) {
    return
  }
  putsSinceCheck = 0
  bytesSinceCheck = 0
  // Pruning is housekeeping: never let it fail the caller's write.
  try {
    await pruneBlobs(db)
  } catch {
    // Ignored.
  }
}

/**
 * Stores attachment bytes. Quota exhaustion evicts the LRU tail and retries
 * once; a second failure throws BlobQuotaExceededError.
 *
 * Called from inside a Dexie transaction it skips the eviction/retry (deleting
 * rows the transaction may not have in scope is worse than failing) and throws
 * the typed error straight away: a caller persisting a message should catch it
 * and skip the blob rather than lose the message write.
 */
export async function putBlob(
  db: ChatmailDB,
  key: string,
  blob: Blob,
  now?: number,
): Promise<void> {
  const row = { key, blob, byteSize: blob.size, lastAccessAt: now ?? Date.now() }
  try {
    await db.blobs.put(row)
  } catch (error) {
    if (!isQuotaExceededError(error)) throw error
    if (inTransaction()) throw new BlobQuotaExceededError(key, { cause: error })

    await freeSpaceFor(db, blob.size)
    try {
      await db.blobs.put(row)
    } catch (retryError) {
      if (!isQuotaExceededError(retryError)) throw retryError
      throw new BlobQuotaExceededError(key, { cause: retryError })
    }
  }
  if (!inTransaction()) await maybePrune(db, blob.size)
}

export async function getBlob(db: ChatmailDB, key: string): Promise<Blob | null> {
  const row = await db.blobs.get(key)
  if (!row) return null
  // Touch outside any caller transaction; failure to touch is harmless.
  void db.blobs.update(key, { lastAccessAt: Date.now() }).catch(() => undefined)
  return row.blob
}

export async function deleteBlob(db: ChatmailDB, key: string): Promise<void> {
  await db.blobs.delete(key)
}

/** Evicts LRU blobs until at least `bytes` (plus headroom) has been freed. */
async function freeSpaceFor(db: ChatmailDB, bytes: number): Promise<number> {
  const total = await totalBlobBytes(db)
  const target = Math.max(0, total - Math.max(bytes * 2, MIN_EVICTION_BYTES))
  return pruneBlobs(db, target)
}

async function totalBlobBytes(db: ChatmailDB): Promise<number> {
  let total = 0
  await db.blobs.each((row) => {
    total += row.byteSize
  })
  return total
}

/**
 * Keys the pruner may delete, i.e. blobs whose bytes can be obtained again: an
 * attachment row carrying a gmailAttachmentId is re-downloadable from Gmail,
 * and a blob with no attachment row at all is orphaned garbage.
 *
 * Everything else is irreplaceable and stays. Inline (cid) parts arrive inside
 * the message payload and get gmailAttachmentId '' — every download path bails
 * on an empty id, and a re-sync skips attachment rows that already exist, so
 * their blob is the only copy that will ever exist locally.
 */
async function evictableKeys(db: ChatmailDB, keys: string[]): Promise<Set<string>> {
  const evictable = new Set(keys)
  const rows = await db.attachments.bulkGet(keys)
  for (const row of rows) {
    if (row !== undefined && row.gmailAttachmentId === '') evictable.delete(row.id)
  }
  return evictable
}

/**
 * Prunes least-recently-used blobs until the total size fits under maxBytes
 * (default: derived from navigator.storage.estimate()). Attachments whose bytes
 * were evicted go back to 'queued' so the UI offers a re-download instead of
 * claiming the file is already local.
 *
 * Only re-fetchable blobs are candidates (see evictableKeys). Evicting an
 * inline part would destroy the message's only copy of those bytes: the reader
 * would render a broken image and the bubble a Download button that can never
 * do anything, forever. Holding them back can leave the budget unmet — that is
 * deliberate. The caller then gets BlobQuotaExceededError, which surfaces as a
 * retryable failure, instead of silent permanent data loss.
 */
export async function pruneBlobs(db: ChatmailDB, maxBytes?: number): Promise<number> {
  const budget = maxBytes ?? (await blobBudgetBytes())
  const rows = await db.blobs.orderBy('lastAccessAt').toArray()
  let total = rows.reduce((sum, r) => sum + r.byteSize, 0)
  if (total <= budget) return 0

  const evictable = await evictableKeys(
    db,
    rows.map((r) => r.key),
  )
  const evicted: string[] = []
  for (const row of rows) {
    if (total <= budget) break
    if (!evictable.has(row.key)) continue
    await db.blobs.delete(row.key)
    total -= row.byteSize
    evicted.push(row.key)
  }
  if (total > budget) {
    console.warn(
      `[blobs] still ${total - budget} bytes over the ${budget}-byte budget after evicting ` +
        `${evicted.length} blobs; the remainder is inline bytes that cannot be re-downloaded`,
    )
  }
  if (evicted.length > 0) {
    await db.attachments
      .where('id')
      .anyOf(evicted)
      .filter((attachment) => attachment.state === 'downloaded')
      .modify({ state: 'queued' })
      .catch(() => 0)
  }
  return evicted.length
}
