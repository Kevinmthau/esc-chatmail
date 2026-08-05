import { Blob as NodeBlob } from 'node:buffer'
import { cleanup, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ChatmailDB, setDBForTests } from '@/db/schema'
import { getBlob, putBlob } from '@/db/blobs'
import type { AttachmentRow } from '@/db/types'
import { patchHappyDomForDomPurify } from './happyDomPatch'

// happy-dom's Blob class does not survive fake-indexeddb's structured clone
// (it comes back as a plain object); node's Blob round-trips intact. The hook
// resolves the global Blob at call time, so overriding here covers it too.
globalThis.Blob = NodeBlob as unknown as typeof Blob

// Must run before the first sanitize call (DOMPurify caches document methods
// and Node.prototype getters when its module initializes).
patchHappyDomForDomPurify()

const getAttachmentMock = vi.hoisted(() => vi.fn())
vi.mock('@/gmail/endpoints', () => ({
  getAttachment: getAttachmentMock,
}))

// Call recorder only — the factory wraps the REAL sanitizer around it, so the
// `restoreMocks: true` project config can never strip the behavior.
const sanitizeSpy = vi.hoisted(() => vi.fn())

vi.mock('./sanitizeEmailHtml', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./sanitizeEmailHtml')>()
  return {
    ...actual,
    sanitizeEmailHtml: (raw: string, opts: { mode: 'preview' | 'full' }) => {
      sanitizeSpy(raw, opts)
      return actual.sanitizeEmailHtml(raw, opts)
    },
  }
})

const { useEmailHtml, setEmailAttachmentBroker, setCidResolutionBudgetForTests } =
  await import('./useEmailHtml')

const fakeBroker = {
  getToken: () => Promise.resolve('token'),
  refreshAfter: () => Promise.resolve('token'),
}

let db: ChatmailDB
let dbCounter = 0

function attachmentRow(overrides: Partial<AttachmentRow> & { id: string }): AttachmentRow {
  return {
    messageId: '',
    gmailAttachmentId: '',
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

beforeEach(() => {
  db = new ChatmailDB(`test_reader_${++dbCounter}`)
  setDBForTests(db)
  setEmailAttachmentBroker(fakeBroker)
  getAttachmentMock.mockReset()
})

afterEach(async () => {
  cleanup()
  setEmailAttachmentBroker(null)
  setCidResolutionBudgetForTests(null)
  setDBForTests(null)
  await db.delete()
})

describe('useEmailHtml', () => {
  it('sanitizes the body and resolves stored cid blobs', async () => {
    const messageId = 'msg-stored-blob'
    await db.bodies.put({ messageId, html: '<p>Hello</p><img src="cid:<logo@x>">' })
    await db.attachments.put(
      attachmentRow({
        id: `${messageId}:0.1`,
        messageId,
        contentId: 'logo@x',
        gmailAttachmentId: 'att-1',
        state: 'downloaded',
      }),
    )
    await putBlob(db, `${messageId}:0.1`, new Blob(['png-bytes'], { type: 'image/png' }))

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    expect(result.current.status).toBe('loading')

    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.html).toContain('Hello')
    expect(result.current.html).toContain('cid:logo@x')
    expect(result.current.html).toContain('Content-Security-Policy')
    expect(result.current.cidBlobs).toHaveProperty('logo@x')
    expect(result.current.cidBlobs?.['logo@x']).toBeInstanceOf(Blob)
    expect(getAttachmentMock).not.toHaveBeenCalled()
  })

  it('resolves cid blobs referenced only through srcset and background carriers', async () => {
    const messageId = 'msg-carriers'
    await db.bodies.put({
      messageId,
      html:
        '<img src="https://x.example/fallback.png" srcset="cid:hero@x 2x">' +
        '<table><tbody><tr><td background="cid:bg@x">cell</td></tr></tbody></table>',
    })
    await db.attachments.bulkPut([
      attachmentRow({
        id: `${messageId}:0.1`,
        messageId,
        contentId: 'hero@x',
        gmailAttachmentId: 'att-hero',
        state: 'downloaded',
      }),
      attachmentRow({
        id: `${messageId}:0.2`,
        messageId,
        contentId: 'bg@x',
        gmailAttachmentId: 'att-bg',
        state: 'downloaded',
      }),
    ])
    await putBlob(db, `${messageId}:0.1`, new Blob(['hero'], { type: 'image/png' }))
    await putBlob(db, `${messageId}:0.2`, new Blob(['bg'], { type: 'image/png' }))

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.cidBlobs).toHaveProperty('hero@x')
    expect(result.current.cidBlobs).toHaveProperty('bg@x')
    expect(getAttachmentMock).not.toHaveBeenCalled()
  })

  it('downloads missing attachment bytes, stores the blob and marks it downloaded', async () => {
    const messageId = 'msg-download'
    await db.bodies.put({ messageId, html: '<img src="cid:photo@x"><p>Body</p>' })
    await db.attachments.put(
      attachmentRow({
        id: `${messageId}:0.2`,
        messageId,
        contentId: 'photo@x',
        gmailAttachmentId: 'att-2',
        state: 'queued',
      }),
    )
    // "img" in base64url.
    getAttachmentMock.mockResolvedValue({ size: 3, data: 'aW1n' })

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('ready'))

    expect(getAttachmentMock).toHaveBeenCalledWith(fakeBroker, messageId, 'att-2')
    expect(result.current.cidBlobs).toHaveProperty('photo@x')

    const stored = await getBlob(db, `${messageId}:0.2`)
    expect(stored).not.toBeNull()
    expect(await stored?.text()).toBe('img')
    const row = await db.attachments.get(`${messageId}:0.2`)
    expect(row?.state).toBe('downloaded')
  })

  it('still renders when a cid cannot be resolved (download failure)', async () => {
    const messageId = 'msg-download-fails'
    await db.bodies.put({ messageId, html: '<img src="cid:broken@x"><p>Body</p>' })
    await db.attachments.put(
      attachmentRow({
        id: `${messageId}:0.3`,
        messageId,
        contentId: 'broken@x',
        gmailAttachmentId: 'att-3',
      }),
    )
    getAttachmentMock.mockRejectedValue(new Error('network'))

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('ready'))

    expect(result.current.html).toContain('Body')
    expect(result.current.cidBlobs).not.toHaveProperty('broken@x')
    const row = await db.attachments.get(`${messageId}:0.3`)
    expect(row?.lastDownloadFailedAt).toBeGreaterThan(0)
  })

  it('caches the sanitized document per messageId+mode', async () => {
    const messageId = 'msg-cache'
    await db.bodies.put({ messageId, html: '<p>Cached</p>' })

    sanitizeSpy.mockClear()
    const first = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(first.result.current.status).toBe('ready'))
    expect(sanitizeSpy).toHaveBeenCalledTimes(1)

    const second = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(second.result.current.status).toBe('ready'))
    expect(sanitizeSpy).toHaveBeenCalledTimes(1)

    // A different mode is a different cache entry.
    const preview = renderHook(() => useEmailHtml(messageId, 'preview'))
    await waitFor(() => expect(preview.result.current.status).toBe('ready'))
    expect(sanitizeSpy).toHaveBeenCalledTimes(2)
  })

  it('re-sanitizes when sync replaces the stored body', async () => {
    const messageId = 'msg-body-updated'
    await db.bodies.put({ messageId, html: '<p>Truncated body</p>' })

    sanitizeSpy.mockClear()
    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.html).toContain('Truncated body'))

    // Sync re-fetched the full body (fetchLargeBody / abandoned drain).
    await db.bodies.put({ messageId, html: '<p>Full body</p>' })

    await waitFor(() => expect(result.current.html).toContain('Full body'))
    expect(result.current.html).not.toContain('Truncated body')
    expect(sanitizeSpy).toHaveBeenCalledTimes(2)
  })

  it('downloads inline images in parallel, not one round trip at a time', async () => {
    const messageId = 'msg-parallel'
    await db.bodies.put({
      messageId,
      html: '<img src="cid:a@x"><img src="cid:b@x"><img src="cid:c@x"><p>Body</p>',
    })
    for (const [i, cid] of ['a@x', 'b@x', 'c@x'].entries()) {
      await db.attachments.put(
        attachmentRow({
          id: `${messageId}:0.${i}`,
          messageId,
          contentId: cid,
          gmailAttachmentId: `att-${cid}`,
        }),
      )
    }

    const release: Array<(value: { size: number; data: string }) => void> = []
    getAttachmentMock.mockImplementation(
      () =>
        new Promise<{ size: number; data: string }>((resolve) => {
          release.push(resolve)
        }),
    )

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))

    // All three requests are in flight before any of them has answered.
    await waitFor(() => expect(getAttachmentMock).toHaveBeenCalledTimes(3))
    for (const resolve of release) resolve({ size: 3, data: 'aW1n' })

    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(Object.keys(result.current.cidBlobs ?? {}).sort()).toEqual(['a@x', 'b@x', 'c@x'])
  })

  it('resolves every inline image of a long newsletter, not just the first 20', async () => {
    const messageId = 'msg-many-cids'
    const cids = Array.from({ length: 25 }, (_, i) => `img${i}@x`)
    await db.bodies.put({
      messageId,
      html: `${cids.map((cid) => `<img src="cid:${cid}">`).join('')}<p>Body</p>`,
    })
    for (const [i, cid] of cids.entries()) {
      const id = `${messageId}:0.${i}`
      await db.attachments.put(
        attachmentRow({
          id,
          messageId,
          contentId: cid,
          gmailAttachmentId: `att-${i}`,
          state: i % 2 === 0 ? 'downloaded' : 'queued',
        }),
      )
      // Even indexes are already in the blob store; odd ones need a download,
      // so both resolution paths have to reach past the old 20-cid cap.
      if (i % 2 === 0) await putBlob(db, id, new Blob([`png-${i}`], { type: 'image/png' }))
    }
    getAttachmentMock.mockResolvedValue({ size: 3, data: 'aW1n' })

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('ready'))

    // Every cid the sanitizer found is mapped: the frame strips the src of any
    // it is not given, so a dropped cid is a permanently broken image.
    expect(Object.keys(result.current.cidBlobs ?? {}).sort()).toEqual([...cids].sort())
    expect(getAttachmentMock).toHaveBeenCalledTimes(12)
  })

  it('starts no new downloads once the resolution budget is spent', async () => {
    const messageId = 'msg-budget-spent'
    setCidResolutionBudgetForTests(0)
    const cids = ['local@x', 'net1@x', 'net2@x']
    await db.bodies.put({
      messageId,
      html: `${cids.map((cid) => `<img src="cid:${cid}">`).join('')}<p>Body</p>`,
    })
    for (const [i, cid] of cids.entries()) {
      await db.attachments.put(
        attachmentRow({
          id: `${messageId}:0.${i}`,
          messageId,
          contentId: cid,
          gmailAttachmentId: `att-${i}`,
        }),
      )
    }
    await putBlob(db, `${messageId}:0.0`, new Blob(['png'], { type: 'image/png' }))
    getAttachmentMock.mockResolvedValue({ size: 3, data: 'aW1n' })

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('ready'))

    // Local bytes still resolve — only the network pass respects the budget,
    // and it fires nothing whose result this render could no longer use.
    expect(Object.keys(result.current.cidBlobs ?? {})).toEqual(['local@x'])
    expect(getAttachmentMock).not.toHaveBeenCalled()
  })

  it('renders the body when an inline image never responds', async () => {
    const messageId = 'msg-hung-image'
    setCidResolutionBudgetForTests(20)
    await db.bodies.put({ messageId, html: '<img src="cid:hung@x"><p>Body text</p>' })
    await db.attachments.put(
      attachmentRow({
        id: `${messageId}:0.1`,
        messageId,
        contentId: 'hung@x',
        gmailAttachmentId: 'att-hung',
      }),
    )
    // Never settles: without a budget the whole body render waits forever.
    getAttachmentMock.mockImplementation(() => new Promise(() => undefined))

    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))

    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.html).toContain('Body text')
    expect(result.current.cidBlobs).not.toHaveProperty('hung@x')
  })

  it('fails when the message has no HTML body, and retry re-runs the pipeline', async () => {
    const messageId = 'msg-no-body'
    const { result } = renderHook(() => useEmailHtml(messageId, 'full'))
    await waitFor(() => expect(result.current.status).toBe('failed'))

    await db.bodies.put({ messageId, html: '<p>Now present</p>' })
    result.current.retry()
    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.html).toContain('Now present')
  })
})
