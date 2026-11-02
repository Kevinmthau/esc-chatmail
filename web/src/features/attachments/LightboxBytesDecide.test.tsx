// Lightbox shows whatever bytes exist, regardless of the row's state — the
// bytes-decide rule AttachmentContent's tiles already follow.

import { Blob as NodeBlob } from 'node:buffer'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { setDBForTests, type ChatmailDB } from '@/db/schema'
import type { AttachmentRow, AttachmentState } from '@/db/types'
import { makeTestDb } from '@/outbox/testSupport'
import { Lightbox } from './Lightbox'

// happy-dom's Blob does not survive fake-indexeddb's structured clone.
globalThis.Blob = NodeBlob as unknown as typeof Blob

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

let db: ChatmailDB

beforeEach(() => {
  db = makeTestDb()
  setDBForTests(db)
})

afterEach(async () => {
  cleanup()
  setDBForTests(null)
  await db.delete()
})

function image(id: string, state: AttachmentState): AttachmentRow {
  return {
    id,
    messageId: 'm1',
    gmailAttachmentId: '',
    contentId: '',
    filename: 'photo.jpg',
    mimeType: 'image/jpeg',
    byteSize: 100,
    width: 0,
    height: 0,
    state,
    lastDownloadFailedAt: 0,
  }
}

async function seedBlob(id: string): Promise<void> {
  await db.blobs.put({
    key: id,
    blob: new Blob(['jpeg-bytes'], { type: 'image/jpeg' }),
    byteSize: 10,
    lastAccessAt: Date.now(),
  })
}

describe('Lightbox bytes-decide rule', () => {
  // Revert-check: Lightbox's `useAttachmentUrl(current?.id ?? null)` (the old state === 'downloaded' gate)
  it.each<AttachmentState>(['queued', 'uploaded', 'failed'])(
    'lightbox_ownSentImageWithLocalBytesInState_%s_showsTheImageAndDownloadLink',
    async (state) => {
      await seedBlob('local_1')
      render(
        <Lightbox images={[image('local_1', state)]} initialIndex={0} onClose={() => undefined} />,
      )
      await waitFor(() => {
        expect(screen.getByRole('img', { name: 'photo.jpg' }).getAttribute('src')).toContain(
          'blob:',
        )
      })
      expect(screen.getByLabelText('Download photo.jpg').tagName).toBe('A')
      expect(screen.queryByText('Image not downloaded')).toBeNull()
    },
  )

  it('lightbox_imageWithoutLocalBytes_showsThePlaceholder', async () => {
    render(
      <Lightbox images={[image('a1', 'uploaded')]} initialIndex={0} onClose={() => undefined} />,
    )
    expect(await screen.findByText('Image not downloaded')).toBeTruthy()
    expect(screen.queryByRole('img')).toBeNull()
  })
})
