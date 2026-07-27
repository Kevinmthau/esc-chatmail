// Downscaling policy for outbound images: the 4096px cap, the pass-through
// for anything already inside it, and the failure modes that must not lose the
// user's file.

import { describe, expect, it, vi } from 'vitest'
import { JPEG_QUALITY, MAX_IMAGE_DIMENSION } from '@/lib/constants'
import { processImage, resizeTarget, type DecodedImage, type ImageIO } from './imageProcessor'

/** A decoder that reports fixed dimensions and an encoder that records its call. */
function fakeIO(
  size: { width: number; height: number } | null,
  encoded: Blob | null = new Blob(['jpeg-bytes'], { type: 'image/jpeg' }),
): { io: ImageIO; encode: ReturnType<typeof vi.fn>; closed: () => number } {
  let closeCount = 0
  const encode = vi.fn(() => Promise.resolve(encoded))
  const io: ImageIO = {
    decode: () =>
      Promise.resolve(
        size === null
          ? null
          : ({
              width: size.width,
              height: size.height,
              source: {} as CanvasImageSource,
              close: () => {
                closeCount += 1
              },
            } satisfies DecodedImage),
      ),
    encode,
  }
  return { io, encode, closed: () => closeCount }
}

function imageBlob(byteSize = 1024): Blob {
  return new Blob([new Uint8Array(byteSize)], { type: 'image/png' })
}

describe('resizeTarget', () => {
  it('returns null while the longest edge is inside the cap', () => {
    expect(resizeTarget(4096, 2000, MAX_IMAGE_DIMENSION)).toBeNull()
    expect(resizeTarget(100, 100, MAX_IMAGE_DIMENSION)).toBeNull()
  })

  it('scales the longest edge down to the cap, preserving aspect ratio', () => {
    expect(resizeTarget(8192, 4096, MAX_IMAGE_DIMENSION)).toEqual({ width: 4096, height: 2048 })
    expect(resizeTarget(4096, 8192, MAX_IMAGE_DIMENSION)).toEqual({ width: 2048, height: 4096 })
  })

  it('never scales a dimension to zero', () => {
    // A 10000×1 panorama: the short edge rounds to 0 without the floor.
    expect(resizeTarget(10_000, 1, MAX_IMAGE_DIMENSION)).toEqual({ width: 4096, height: 1 })
  })
})

describe('processImage', () => {
  it('resizes an image past the cap and reports the new size', async () => {
    const { io, encode } = fakeIO({ width: 6000, height: 3000 })

    const result = await processImage(imageBlob(), { io })

    expect(result).not.toBeNull()
    expect(result?.resized).toBe(true)
    expect(result?.width).toBe(4096)
    expect(result?.height).toBe(2048)
    expect(result?.blob.type).toBe('image/jpeg')
    // Quality comes from the shared constant, not a local literal.
    expect(encode).toHaveBeenCalledWith(expect.anything(), 4096, 2048, JPEG_QUALITY)
  })

  it('passes a small image through byte-for-byte without re-encoding', async () => {
    const { io, encode } = fakeIO({ width: 800, height: 600 })
    const blob = imageBlob()

    const result = await processImage(blob, { io })

    expect(result).toEqual({ blob, width: 800, height: 600, resized: false })
    // Re-encoding an in-cap image only loses quality (and often grows PNGs).
    expect(encode).not.toHaveBeenCalled()
  })

  it('returns null when the browser cannot decode the blob', async () => {
    const { io } = fakeIO(null)
    expect(await processImage(imageBlob(), { io })).toBeNull()
  })

  it('returns null when the encoder fails, so the original bytes are used', async () => {
    const { io } = fakeIO({ width: 9000, height: 9000 }, null)
    expect(await processImage(imageBlob(), { io })).toBeNull()
  })

  it('rejects degenerate dimensions rather than drawing a zero-size canvas', async () => {
    const { io } = fakeIO({ width: 0, height: 100 })
    expect(await processImage(imageBlob(), { io })).toBeNull()
  })

  it('releases the decoder even when no resize happens', async () => {
    const { io, closed } = fakeIO({ width: 10, height: 10 })
    await processImage(imageBlob(), { io })
    expect(closed()).toBe(1)
  })

  it('honours an explicit maxDimension override', async () => {
    const { io, encode } = fakeIO({ width: 1000, height: 500 })
    await processImage(imageBlob(), { io, maxDimension: 500 })
    expect(encode).toHaveBeenCalledWith(expect.anything(), 500, 250, JPEG_QUALITY)
  })
})
