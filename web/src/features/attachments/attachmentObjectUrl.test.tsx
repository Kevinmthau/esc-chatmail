// Attachment object URLs never carry a sender-declared document type: only
// raster images keep their type, everything else is minted as octet-stream and
// SVG/HTML parts take the file card instead of an <img> tile.

import { Blob as NodeBlob } from 'node:buffer'
import { cleanup, render, renderHook, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { makeTestDb } from '@/outbox/testSupport'
import { AttachmentContent } from './AttachmentContent'
import { isRasterImageType, objectUrlSourceBlob } from './attachmentObjectUrl'
import { useAttachmentUrl } from './useAttachmentUrl'

// happy-dom's Blob does not survive fake-indexeddb's structured clone.
globalThis.Blob = NodeBlob as unknown as typeof Blob

let db: ChatmailDB

// Object URLs are opaque strings, so keep a url → blob map to prove WHICH
// blob (and which type) a given url was minted from.
const minted: Array<{ url: string; blob: Blob }> = []
const originalCreate = URL.createObjectURL
const originalRevoke = URL.revokeObjectURL

function mintedBlobFor(url: string | null): Blob | undefined {
  return minted.find((entry) => entry.url === url)?.blob
}

beforeEach(() => {
  minted.length = 0
  let counter = 0
  URL.createObjectURL = (blob: Blob) => {
    const url = `blob:test/${++counter}`
    minted.push({ url, blob })
    return url
  }
  URL.revokeObjectURL = () => undefined
  db = makeTestDb()
  setDBForTests(db)
})

afterEach(async () => {
  cleanup()
  URL.createObjectURL = originalCreate
  URL.revokeObjectURL = originalRevoke
  setDBForTests(null)
  await db.delete()
})

async function seed(id: string, mimeType: string, filename: string, bytes: string): Promise<void> {
  const row: AttachmentRow = {
    id,
    messageId: 'm1',
    gmailAttachmentId: `g_${id}`,
    contentId: '',
    filename,
    mimeType,
    byteSize: bytes.length,
    width: 0,
    height: 0,
    state: 'downloaded',
    lastDownloadFailedAt: 0,
  }
  await db.attachments.put(row)
  await db.blobs.put({
    key: id,
    blob: new Blob([bytes], { type: mimeType }),
    byteSize: bytes.length,
    lastAccessAt: Date.now(),
  })
}

describe('isRasterImageType', () => {
  // Revert-check: isRasterImageType (a `startsWith('image/')` check admits svg)
  it('isRasterImageType_svgAndNonImages_areNotRaster', () => {
    expect(isRasterImageType('image/svg+xml')).toBe(false)
    expect(isRasterImageType('text/html')).toBe(false)
    expect(isRasterImageType('application/pdf')).toBe(false)
    expect(isRasterImageType('image/x-icon')).toBe(false)
    expect(isRasterImageType('')).toBe(false)
  })

  it('isRasterImageType_allowlistedRasterTypes_areRaster', () => {
    for (const type of [
      'image/jpeg',
      'image/png',
      'image/gif',
      'image/webp',
      'image/avif',
      'image/bmp',
      'IMAGE/PNG',
      'image/png; name="a.png"',
    ]) {
      expect(isRasterImageType(type), type).toBe(true)
    }
  })
})

describe('objectUrlSourceBlob', () => {
  // Revert-check: objectUrlSourceBlob
  it('objectUrlSourceBlob_nonRasterBlob_isRetypedToOctetStreamWithTheSameBytes', async () => {
    const svg = new Blob(['<svg onload="alert(1)"/>'], { type: 'image/svg+xml' })
    const exposed = objectUrlSourceBlob(svg)
    expect(exposed).not.toBe(svg)
    expect(exposed.type).toBe('application/octet-stream')
    expect(await exposed.text()).toBe('<svg onload="alert(1)"/>')
    // The stored blob is untouched.
    expect(svg.type).toBe('image/svg+xml')
  })

  it('objectUrlSourceBlob_rasterBlob_isExposedAsIs', () => {
    const png = new Blob(['png'], { type: 'image/png' })
    expect(objectUrlSourceBlob(png)).toBe(png)
  })
})

describe('useAttachmentUrl object URL type', () => {
  // Revert-check: objectUrlSourceBlob call in useAttachmentUrl.acquireUrl
  it('useAttachmentUrl_htmlAndSvgAttachments_mintOctetStreamUrls', async () => {
    await seed('h1', 'text/html', 'payload.html', '<script>1</script>')
    await seed('s1', 'image/svg+xml', 'evil.svg', '<svg/>')

    const html = renderHook(() => useAttachmentUrl('h1'))
    await waitFor(() => expect(html.result.current).not.toBeNull())
    expect(mintedBlobFor(html.result.current)?.type).toBe('application/octet-stream')

    const svg = renderHook(() => useAttachmentUrl('s1'))
    await waitFor(() => expect(svg.result.current).not.toBeNull())
    expect(mintedBlobFor(svg.result.current)?.type).toBe('application/octet-stream')
  })

  it('useAttachmentUrl_rasterAttachment_keepsItsImageType', async () => {
    await seed('p1', 'image/png', 'photo.png', 'png-bytes')
    const { result } = renderHook(() => useAttachmentUrl('p1'))
    await waitFor(() => expect(result.current).not.toBeNull())
    expect(mintedBlobFor(result.current)?.type).toBe('image/png')
  })
})

describe('AttachmentContent image routing', () => {
  // Revert-check: isRasterImageType filter in AttachmentContent
  it('attachmentContent_svgAttachment_rendersAFileCardNotAnImageTile', async () => {
    await seed('s1', 'image/svg+xml', 'evil.svg', '<svg/>')
    render(<AttachmentContent messageId="m1" />)
    await waitFor(() => {
      expect(screen.getByLabelText('Download evil.svg').tagName).toBe('A')
    })
    expect(screen.queryByRole('img')).toBeNull()
    expect(screen.queryByRole('button', { name: 'View evil.svg' })).toBeNull()
    expect(
      mintedBlobFor(screen.getByLabelText('Download evil.svg').getAttribute('href'))?.type,
    ).toBe('application/octet-stream')
  })

  it('attachmentContent_pngAttachment_rendersAnImageTile', async () => {
    await seed('p1', 'image/png', 'photo.png', 'png-bytes')
    render(<AttachmentContent messageId="m1" />)
    expect(await screen.findByRole('button', { name: 'View photo.png' })).toBeTruthy()
    expect(screen.getByRole('img', { name: 'photo.png' }).getAttribute('src')).toContain('blob:')
  })
})
