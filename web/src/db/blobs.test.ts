import { Blob as NodeBlob } from 'node:buffer'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ChatmailDB } from './schema'
import type { AttachmentRow } from './types'
import {
  BlobQuotaExceededError,
  getBlob,
  isQuotaExceededError,
  pruneBlobs,
  putBlob,
  resetBlobPruneCountersForTests,
} from './blobs'

// happy-dom's Blob does not survive fake-indexeddb's structured clone.
globalThis.Blob = NodeBlob as unknown as typeof Blob

let db: ChatmailDB
let dbCounter = 0

function bytes(size: number): Blob {
  return new Blob(['x'.repeat(size)])
}

function quotaError(): DOMException {
  return new DOMException('The quota has been exceeded.', 'QuotaExceededError')
}

/** Fakes navigator.storage.estimate() for the duration of a test. */
function stubStorageEstimate(estimate: StorageEstimate | null): void {
  const storage =
    estimate === null ? undefined : { estimate: () => Promise.resolve(estimate), persist: () => {} }
  Object.defineProperty(globalThis.navigator, 'storage', {
    value: storage,
    configurable: true,
    writable: true,
  })
}

function attachmentRow(id: string, state: AttachmentRow['state']): AttachmentRow {
  return {
    id,
    messageId: 'm1',
    gmailAttachmentId: `g_${id}`,
    contentId: '',
    filename: 'a.png',
    mimeType: 'image/png',
    byteSize: 0,
    width: 0,
    height: 0,
    state,
    lastDownloadFailedAt: 0,
  }
}

/** An inline (cid) part: no gmailAttachmentId, so nothing can re-fetch it. */
function inlineAttachmentRow(id: string): AttachmentRow {
  return { ...attachmentRow(id, 'downloaded'), gmailAttachmentId: '', contentId: `${id}@x` }
}

beforeEach(() => {
  db = new ChatmailDB(`test_blobs_${++dbCounter}`)
  resetBlobPruneCountersForTests()
  stubStorageEstimate(null)
})

afterEach(async () => {
  resetBlobPruneCountersForTests()
  stubStorageEstimate(null)
  await db.delete()
})

describe('isQuotaExceededError', () => {
  it('recognizes DOMExceptions and Dexie-wrapped quota errors', () => {
    expect(isQuotaExceededError(quotaError())).toBe(true)
    expect(isQuotaExceededError({ name: 'DexieError', inner: quotaError() })).toBe(true)
    expect(isQuotaExceededError(new Error('boom'))).toBe(false)
    expect(isQuotaExceededError(null)).toBe(false)
  })
})

describe('pruneBlobs', () => {
  it('evicts least-recently-used blobs until the budget fits', async () => {
    await db.blobs.bulkPut([
      { key: 'old', blob: bytes(100), byteSize: 100, lastAccessAt: 1 },
      { key: 'mid', blob: bytes(100), byteSize: 100, lastAccessAt: 2 },
      { key: 'new', blob: bytes(100), byteSize: 100, lastAccessAt: 3 },
    ])

    expect(await pruneBlobs(db, 150)).toBe(2)
    expect((await db.blobs.toCollection().primaryKeys()).sort()).toEqual(['new'])
  })

  it("resets an evicted attachment's state so the UI offers a re-download", async () => {
    await db.attachments.bulkPut([attachmentRow('a1', 'downloaded'), attachmentRow('a2', 'failed')])
    await db.blobs.bulkPut([
      { key: 'a1', blob: bytes(100), byteSize: 100, lastAccessAt: 1 },
      { key: 'a2', blob: bytes(100), byteSize: 100, lastAccessAt: 2 },
    ])

    await pruneBlobs(db, 0)

    expect((await db.attachments.get('a1'))?.state).toBe('queued')
    // Non-'downloaded' states are left alone (a failed row keeps its retry UI).
    expect((await db.attachments.get('a2'))?.state).toBe('failed')
  })

  it('skips inline bytes and evicts a re-fetchable attachment instead', async () => {
    await db.attachments.bulkPut([
      inlineAttachmentRow('inline'),
      attachmentRow('server', 'downloaded'),
    ])
    await db.blobs.bulkPut([
      // The inline blob is the LRU tail — pure recency would evict it first.
      { key: 'inline', blob: bytes(100), byteSize: 100, lastAccessAt: 1 },
      { key: 'server', blob: bytes(100), byteSize: 100, lastAccessAt: 2 },
    ])

    expect(await pruneBlobs(db, 150)).toBe(1)

    // Inline bytes are the only copy that exists: no gmailAttachmentId means no
    // download path and no re-sync can ever restore them.
    expect(await db.blobs.toCollection().primaryKeys()).toEqual(['inline'])
    expect((await db.attachments.get('inline'))?.state).toBe('downloaded')
    expect((await db.attachments.get('server'))?.state).toBe('queued')
  })

  it('leaves the budget unmet rather than destroying irreplaceable bytes', async () => {
    await db.attachments.bulkPut([inlineAttachmentRow('i1'), inlineAttachmentRow('i2')])
    await db.blobs.bulkPut([
      { key: 'i1', blob: bytes(100), byteSize: 100, lastAccessAt: 1 },
      { key: 'i2', blob: bytes(100), byteSize: 100, lastAccessAt: 2 },
    ])
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)

    expect(await pruneBlobs(db, 0)).toBe(0)

    expect((await db.blobs.toCollection().primaryKeys()).sort()).toEqual(['i1', 'i2'])
    expect(warn).toHaveBeenCalledOnce()
  })

  it('sizes the default budget from navigator.storage.estimate()', async () => {
    // 1000-byte quota → 50% budget = 500 bytes, so 3 × 300 bytes must shrink.
    stubStorageEstimate({ quota: 1000, usage: 900 })
    await db.blobs.bulkPut([
      { key: 'b1', blob: bytes(300), byteSize: 300, lastAccessAt: 1 },
      { key: 'b2', blob: bytes(300), byteSize: 300, lastAccessAt: 2 },
      { key: 'b3', blob: bytes(300), byteSize: 300, lastAccessAt: 3 },
    ])

    // usage/quota is 0.9 → the tighter 25% budget (250 bytes) applies.
    expect(await pruneBlobs(db)).toBe(3)
  })
})

describe('putBlob', () => {
  it('prunes opportunistically once the put cadence is reached', async () => {
    stubStorageEstimate({ quota: 1000, usage: 100 })
    // Budget = 50% of 1000 = 500 bytes; 20 × 50 bytes = 1000 written.
    for (let i = 0; i < 20; i++) {
      await putBlob(db, `k${i}`, bytes(50))
    }

    const remaining = await db.blobs.toArray()
    const total = remaining.reduce((sum, row) => sum + row.byteSize, 0)
    expect(total).toBeLessThanOrEqual(500)
    // The newest writes survive; the oldest are the ones evicted.
    expect(await getBlob(db, 'k19')).not.toBeNull()
    expect(await getBlob(db, 'k0')).toBeNull()
  })

  it('evicts and retries once when the store reports QuotaExceededError', async () => {
    await db.blobs.bulkPut([
      { key: 'old1', blob: bytes(100), byteSize: 100, lastAccessAt: 1 },
      { key: 'old2', blob: bytes(100), byteSize: 100, lastAccessAt: 2 },
    ])
    const put = vi.spyOn(db.blobs, 'put')
    put.mockRejectedValueOnce(quotaError())

    await expect(putBlob(db, 'fresh', bytes(10))).resolves.toBeUndefined()

    expect(put).toHaveBeenCalledTimes(2) // failed put + retry after eviction
    expect(await getBlob(db, 'fresh')).not.toBeNull()
    // The LRU tail was evicted to make room.
    expect(await getBlob(db, 'old1')).toBeNull()
  })

  it('throws a typed BlobQuotaExceededError when even eviction does not help', async () => {
    vi.spyOn(db.blobs, 'put').mockRejectedValue(quotaError())

    await expect(putBlob(db, 'fresh', bytes(10))).rejects.toBeInstanceOf(BlobQuotaExceededError)
  })

  it('propagates non-quota errors untouched', async () => {
    const failure = new Error('disk on fire')
    vi.spyOn(db.blobs, 'put').mockRejectedValue(failure)

    await expect(putBlob(db, 'fresh', bytes(10))).rejects.toBe(failure)
  })

  it('inside a transaction, fails fast with the typed error and no eviction', async () => {
    await db.blobs.put({ key: 'old', blob: bytes(100), byteSize: 100, lastAccessAt: 1 })
    const put = vi.spyOn(db.blobs, 'put')

    await expect(
      db.transaction('rw', db.blobs, db.attachments, async () => {
        put.mockRejectedValueOnce(quotaError())
        await putBlob(db, 'fresh', bytes(10))
      }),
    ).rejects.toBeInstanceOf(BlobQuotaExceededError)

    // No retry, and the eviction pass never ran inside the doomed transaction.
    expect(put).toHaveBeenCalledTimes(1)
    expect(await getBlob(db, 'old')).not.toBeNull()
  })
})
