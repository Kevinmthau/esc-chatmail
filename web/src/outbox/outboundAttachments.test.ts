// Staging picked files: the downscale-then-cap ordering, the visible skip
// message iOS never had, and the cid/fingerprint matcher sync uses to adopt an
// optimistic row instead of duplicating it.

import { describe, expect, it, vi } from 'vitest'
import type { AttachmentRow } from '@/db/types'
import { MAX_ATTACHMENT_BYTES } from '@/lib/constants'
import type { ImageIO } from './imageProcessor'
import {
  isLocalAttachmentId,
  localAttachmentRow,
  matchLocalAttachment,
  prepareAttachments,
  skippedAttachmentMessage,
  type PendingAttachment,
  type SkippedAttachment,
} from './outboundAttachments'

function file(name: string, type: string, byteSize: number): File {
  return new File([new Uint8Array(byteSize)], name, { type })
}

/** Decoder reporting fixed dimensions; the encoder yields `encodedBytes`. */
function fakeImageIO(width: number, height: number, encodedBytes = 1024): ImageIO {
  return {
    decode: () => Promise.resolve({ width, height, source: {} as CanvasImageSource }),
    encode: () => Promise.resolve(new Blob([new Uint8Array(encodedBytes)], { type: 'image/jpeg' })),
  }
}

/** Decoder that always fails, like a HEIC outside Safari. */
const undecodableIO: ImageIO = {
  decode: () => Promise.resolve(null),
  encode: () => Promise.resolve(null),
}

function attachmentRow(overrides: Partial<AttachmentRow> = {}): AttachmentRow {
  return {
    id: 'local_a1',
    messageId: 'u1',
    gmailAttachmentId: '',
    contentId: '',
    filename: 'photo.jpg',
    mimeType: 'image/jpeg',
    byteSize: 2048,
    width: 0,
    height: 0,
    state: 'uploaded',
    lastDownloadFailedAt: 0,
    ...overrides,
  }
}

describe('prepareAttachments', () => {
  it('downscales an oversized photo BEFORE the size check, so it still attaches', async () => {
    // 30 MB source, over the 25 MB cap; the 4096px re-encode brings it under.
    const source = file('IMG_0001.png', 'image/png', 1024)
    vi.spyOn(source, 'size', 'get').mockReturnValue(30 * 1024 * 1024)

    const prepared = await prepareAttachments([source], {
      image: { io: fakeImageIO(6000, 4000, 3 * 1024 * 1024) },
    })

    expect(prepared.skipped).toEqual([])
    expect(prepared.attachments).toHaveLength(1)
    const attachment = prepared.attachments[0]!
    expect(attachment.byteSize).toBe(3 * 1024 * 1024)
    expect(attachment.mimeType).toBe('image/jpeg')
    // Re-encoded to JPEG, so the extension follows the bytes.
    expect(attachment.filename).toBe('IMG_0001.jpg')
    expect(attachment.width).toBe(4096)
    expect(attachment.height).toBe(2731)
    expect(isLocalAttachmentId(attachment.id)).toBe(true)
  })

  it('passes an in-cap image through untouched, keeping its name and type', async () => {
    const prepared = await prepareAttachments([file('shot.png', 'image/png', 4096)], {
      image: { io: fakeImageIO(1200, 900) },
    })

    const attachment = prepared.attachments[0]!
    expect(attachment.filename).toBe('shot.png')
    expect(attachment.mimeType).toBe('image/png')
    expect(attachment.byteSize).toBe(4096)
    expect(attachment.width).toBe(1200)
    expect(attachment.height).toBe(900)
  })

  it('skips a file still over the cap after processing, and names it', async () => {
    const big = file('huge.pdf', 'application/pdf', 1024)
    vi.spyOn(big, 'size', 'get').mockReturnValue(MAX_ATTACHMENT_BYTES + 1)

    const prepared = await prepareAttachments([big, file('ok.pdf', 'application/pdf', 10)])

    expect(prepared.attachments.map((a) => a.filename)).toEqual(['ok.pdf'])
    expect(prepared.skipped).toEqual([
      { filename: 'huge.pdf', reason: 'tooLarge', byteSize: MAX_ATTACHMENT_BYTES + 1 },
    ])
    // iOS silently `continue`d past this; the user must be told.
    expect(skippedAttachmentMessage(prepared.skipped)).toContain('huge.pdf')
    expect(skippedAttachmentMessage(prepared.skipped)).toContain('25 MB')
  })

  it('skips an image whose downscaled bytes are still over the cap', async () => {
    const source = file('massive.png', 'image/png', 1024)
    vi.spyOn(source, 'size', 'get').mockReturnValue(80 * 1024 * 1024)

    const prepared = await prepareAttachments([source], {
      image: { io: fakeImageIO(20_000, 20_000, MAX_ATTACHMENT_BYTES + 1) },
    })

    expect(prepared.attachments).toEqual([])
    expect(prepared.skipped[0]?.reason).toBe('tooLarge')
  })

  it('attaches an undecodable image as-is instead of dropping it', async () => {
    const prepared = await prepareAttachments([file('photo.heic', 'image/heic', 2048)], {
      image: { io: undecodableIO },
    })

    expect(prepared.skipped).toEqual([])
    expect(prepared.attachments[0]?.filename).toBe('photo.heic')
    expect(prepared.attachments[0]?.mimeType).toBe('image/heic')
  })

  it('does not run image processing on non-images', async () => {
    const io = fakeImageIO(9000, 9000)
    const decode = vi.spyOn(io, 'decode')

    const prepared = await prepareAttachments([file('report.pdf', 'application/pdf', 64)], {
      image: { io },
    })

    expect(decode).not.toHaveBeenCalled()
    expect(prepared.attachments[0]?.mimeType).toBe('application/pdf')
  })

  it('falls back to application/octet-stream when the browser reports no type', async () => {
    const prepared = await prepareAttachments([file('mystery', '', 16)])
    expect(prepared.attachments[0]?.mimeType).toBe('application/octet-stream')
  })

  it('gives every staged file its own local id', async () => {
    const prepared = await prepareAttachments([
      file('a.pdf', 'application/pdf', 8),
      file('b.pdf', 'application/pdf', 8),
    ])
    const [first, second] = prepared.attachments
    expect(first?.id).not.toBe(second?.id)
  })
})

describe('skippedAttachmentMessage', () => {
  const skipped = (filename: string): SkippedAttachment => ({
    filename,
    reason: 'tooLarge',
    byteSize: MAX_ATTACHMENT_BYTES + 1,
  })

  it('is null when nothing was skipped', () => {
    expect(skippedAttachmentMessage([])).toBeNull()
  })

  it('names every skipped file', () => {
    const message = skippedAttachmentMessage([skipped('a.png'), skipped('b.png')]) ?? ''
    expect(message).toContain('a.png')
    expect(message).toContain('b.png')
  })
})

describe('localAttachmentRow', () => {
  it('writes a queued row with no gmailAttachmentId (so the LRU pruner spares it)', () => {
    const pending: PendingAttachment = {
      id: 'local_x',
      filename: 'photo.jpg',
      mimeType: 'image/jpeg',
      blob: new Blob(['bytes']),
      byteSize: 5,
      width: 100,
      height: 50,
    }

    expect(localAttachmentRow(pending, 'u1')).toEqual({
      id: 'local_x',
      messageId: 'u1',
      gmailAttachmentId: '',
      contentId: '',
      filename: 'photo.jpg',
      mimeType: 'image/jpeg',
      byteSize: 5,
      width: 100,
      height: 50,
      state: 'queued',
      lastDownloadFailedAt: 0,
    })
  })
})

describe('matchLocalAttachment', () => {
  const incoming = {
    contentId: '',
    filename: 'photo.jpg',
    mimeType: 'image/jpeg',
    byteSize: 2048,
  }

  it('matches on filename + mimeType + byte size', () => {
    const row = attachmentRow()
    expect(matchLocalAttachment(incoming, [row], new Set())?.id).toBe('local_a1')
  })

  it('ignores case and surrounding whitespace in the filename', () => {
    const row = attachmentRow({ filename: '  Photo.JPG ' })
    expect(matchLocalAttachment(incoming, [row], new Set())?.id).toBe('local_a1')
  })

  it('prefers a Content-ID match over the fingerprint', () => {
    const byCid = attachmentRow({ id: 'local_cid', contentId: 'logo@x', filename: 'other.png' })
    const byFingerprint = attachmentRow({ id: 'local_fp' })
    const match = matchLocalAttachment(
      { ...incoming, contentId: 'logo@x' },
      [byFingerprint, byCid],
      new Set(),
    )
    expect(match?.id).toBe('local_cid')
  })

  it('never fingerprint-matches a row that carries its own Content-ID', () => {
    const row = attachmentRow({ contentId: 'inline@x' })
    expect(matchLocalAttachment(incoming, [row], new Set())).toBeNull()
  })

  it('skips rows an earlier incoming part already claimed', () => {
    const first = attachmentRow({ id: 'local_1' })
    const second = attachmentRow({ id: 'local_2' })
    const match = matchLocalAttachment(incoming, [first, second], new Set(['local_1']))
    expect(match?.id).toBe('local_2')
  })

  it('ignores server-side rows entirely', () => {
    const serverRow = attachmentRow({ id: 'm1:2', gmailAttachmentId: 'ATT1' })
    expect(matchLocalAttachment(incoming, [serverRow], new Set())).toBeNull()
  })

  it('returns null on a size mismatch rather than guessing', () => {
    const row = attachmentRow({ byteSize: 2049 })
    expect(matchLocalAttachment(incoming, [row], new Set())).toBeNull()
  })
})
