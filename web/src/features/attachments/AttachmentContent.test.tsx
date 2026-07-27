// AttachmentContent rendering: single image, image grid with '+N' overflow,
// and the non-image file card, each with their download overlays.

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { makeTestDb } from '@/outbox/testSupport'
import { AttachmentContent } from './AttachmentContent'
import { formatByteSize } from './formatByteSize'

let db: ChatmailDB

// happy-dom's URL.createObjectURL rejects blobs that round-tripped through
// fake-indexeddb's structured clone; stub the object-URL surface for tests.
const realCreateObjectURL = URL.createObjectURL
const realRevokeObjectURL = URL.revokeObjectURL

beforeAll(() => {
  let counter = 0
  URL.createObjectURL = vi.fn(() => `blob:test-${++counter}`)
  URL.revokeObjectURL = vi.fn()
})

afterAll(() => {
  URL.createObjectURL = realCreateObjectURL
  URL.revokeObjectURL = realRevokeObjectURL
})

beforeEach(() => {
  db = makeTestDb()
  setDBForTests(db)
})

afterEach(async () => {
  cleanup()
  setDBForTests(null)
  await db.delete()
})

function att(
  overrides: Partial<AttachmentRow> & Pick<AttachmentRow, 'id' | 'messageId'>,
): AttachmentRow {
  return {
    gmailAttachmentId: `g_${overrides.id}`,
    contentId: '',
    filename: 'IMG_1.png',
    mimeType: 'image/png',
    byteSize: 1024,
    width: 0,
    height: 0,
    state: 'queued',
    lastDownloadFailedAt: 0,
    ...overrides,
  }
}

describe('AttachmentContent', () => {
  it('renders nothing for a message without attachments', async () => {
    const { container } = render(<AttachmentContent messageId="m-none" />)
    await waitFor(() => {
      expect(container.firstChild).toBeNull()
    })
  })

  it('renders a single not-yet-downloaded image with a download overlay', async () => {
    await db.attachments.put(att({ id: 'a1', messageId: 'm1', filename: 'photo.png' }))
    render(<AttachmentContent messageId="m1" />)
    expect(await screen.findByRole('button', { name: 'Download photo.png' })).toBeTruthy()
  })

  it('renders a retry overlay for failed downloads', async () => {
    await db.attachments.put(
      att({ id: 'a1', messageId: 'm1', filename: 'photo.png', state: 'failed' }),
    )
    render(<AttachmentContent messageId="m1" />)
    expect(await screen.findByRole('button', { name: 'Retry download of photo.png' })).toBeTruthy()
  })

  it('renders a 2-col grid capped at 4 tiles with a +N overlay for extras', async () => {
    for (let i = 1; i <= 5; i++) {
      await db.attachments.put(att({ id: `a${i}`, messageId: 'm1', filename: `img${i}.png` }))
    }
    const { container } = render(<AttachmentContent messageId="m1" />)

    await screen.findByText('+2')
    expect(container.querySelector('.grid-cols-2')).not.toBeNull()
    // 4 tiles rendered, images 5+ are folded into the overlay count.
    const tiles = screen.getAllByRole('button', { name: /Download img/ })
    expect(tiles).toHaveLength(4)
    expect(screen.queryByRole('button', { name: 'Download img5.png' })).toBeNull()
  })

  it('renders non-image attachments as a filename/size card with download control', async () => {
    await db.attachments.put(
      att({
        id: 'a1',
        messageId: 'm1',
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        byteSize: 2 * 1024 * 1024,
      }),
    )
    render(<AttachmentContent messageId="m1" />)

    expect(await screen.findByText('report.pdf')).toBeTruthy()
    expect(screen.getByText('2.0 MB')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Download report.pdf' })).toBeTruthy()
  })

  it('offers a download anchor for already-downloaded files', async () => {
    await db.attachments.put(
      att({
        id: 'a1',
        messageId: 'm1',
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        state: 'downloaded',
      }),
    )
    await db.blobs.put({
      key: 'a1',
      blob: new Blob(['pdf-bytes'], { type: 'application/pdf' }),
      byteSize: 9,
      lastAccessAt: Date.now(),
    })
    render(<AttachmentContent messageId="m1" />)

    // The overlay button renders first; the anchor appears once the blob loads.
    await waitFor(() => {
      expect(screen.getByLabelText('Download report.pdf').tagName).toBe('A')
    })
    const anchor = screen.getByLabelText('Download report.pdf')
    expect(anchor.getAttribute('download')).toBe('report.pdf')
    expect(anchor.getAttribute('href') ?? '').toContain('blob:')
  })
})

describe('formatByteSize', () => {
  it('formats byte counts humanely', () => {
    expect(formatByteSize(0)).toBe('—')
    expect(formatByteSize(512)).toBe('512 B')
    expect(formatByteSize(2048)).toBe('2 KB')
    expect(formatByteSize(3.5 * 1024 * 1024)).toBe('3.5 MB')
  })
})
