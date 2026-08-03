import { Blob as NodeBlob } from 'node:buffer'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getBlob, resetBlobPruneCountersForTests } from '@/db/blobs'
import { ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'

// happy-dom's Blob does not survive fake-indexeddb's structured clone.
globalThis.Blob = NodeBlob as unknown as typeof Blob

const getAttachmentMock = vi.hoisted(() => vi.fn())
vi.mock('@/gmail/endpoints', () => ({ getAttachment: getAttachmentMock }))

const { downloadAttachment, setAttachmentDownloadBroker } = await import('./download')

const fakeBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

let db: ChatmailDB
let dbCounter = 0

function attachmentRow(overrides: Partial<AttachmentRow> & { id: string }): AttachmentRow {
  return {
    messageId: 'm1',
    gmailAttachmentId: 'g1',
    contentId: '',
    filename: 'a.png',
    mimeType: 'image/png',
    byteSize: 0,
    width: 0,
    height: 0,
    state: 'queued',
    lastDownloadFailedAt: 0,
    ...overrides,
  }
}

function quotaError(): DOMException {
  return new DOMException('The quota has been exceeded.', 'QuotaExceededError')
}

beforeEach(() => {
  db = new ChatmailDB(`test_download_${++dbCounter}`)
  resetBlobPruneCountersForTests()
  setAttachmentDownloadBroker(fakeBroker)
  getAttachmentMock.mockReset()
  // "img" in base64url.
  getAttachmentMock.mockResolvedValue({ size: 3, data: 'aW1n' })
})

afterEach(async () => {
  setAttachmentDownloadBroker(null)
  resetBlobPruneCountersForTests()
  await db.delete()
})

describe('downloadAttachment', () => {
  it('stores the bytes and marks the row downloaded', async () => {
    const row = attachmentRow({ id: 'a1' })
    await db.attachments.put(row)

    const blob = await downloadAttachment(db, row)

    expect(await blob?.text()).toBe('img')
    expect(await getBlob(db, 'a1')).not.toBeNull()
    expect((await db.attachments.get('a1'))?.state).toBe('downloaded')
  })

  it('recovers from a full quota by evicting older blobs', async () => {
    await db.blobs.bulkPut([
      { key: 'stale1', blob: new Blob(['old']), byteSize: 3, lastAccessAt: 1 },
      { key: 'stale2', blob: new Blob(['old']), byteSize: 3, lastAccessAt: 2 },
    ])
    const row = attachmentRow({ id: 'a2' })
    await db.attachments.put(row)
    // The origin is full for the first write only; eviction makes room.
    vi.spyOn(db.blobs, 'put').mockRejectedValueOnce(quotaError())

    const blob = await downloadAttachment(db, row)

    expect(await blob?.text()).toBe('img')
    expect(await getBlob(db, 'a2')).not.toBeNull()
    expect((await db.attachments.get('a2'))?.state).toBe('downloaded')
    expect(await getBlob(db, 'stale1')).toBeNull()
  })

  it('marks the row failed (never throws) when storage stays full', async () => {
    const row = attachmentRow({ id: 'a3' })
    await db.attachments.put(row)
    vi.spyOn(db.blobs, 'put').mockRejectedValue(quotaError())

    await expect(downloadAttachment(db, row)).resolves.toBeNull()

    const stored = await db.attachments.get('a3')
    expect(stored?.state).toBe('failed')
    expect(stored?.lastDownloadFailedAt).toBeGreaterThan(0)
  })
})
