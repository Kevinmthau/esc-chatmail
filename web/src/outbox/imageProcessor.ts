// Client-side image downscaling for outbound attachments. Port of
// Services/Utilities/ImageProcessor.swift (processImage): cap the longest edge
// at MAX_IMAGE_DIMENSION and re-encode as JPEG at JPEG_QUALITY; an image
// already inside the cap is passed through BYTE-FOR-BYTE (iOS returns the
// original Data whenever scale >= 1 — re-encoding it would only lose quality
// and, for PNG/WebP sources, often grow the file).
//
// The decode/encode pair is injectable because the browser primitives it needs
// (createImageBitmap, canvas 2d, canvas.toBlob) do not exist in the happy-dom
// test environment. Production uses the default implementation below;
// imageProcessor.test.ts drives the policy through fakes.

import { JPEG_QUALITY, MAX_IMAGE_DIMENSION } from '@/lib/constants'

/** A decoded image plus the handle needed to draw it onto a canvas. */
export interface DecodedImage {
  readonly width: number
  readonly height: number
  readonly source: CanvasImageSource
  /** Releases the decoder's resources (ImageBitmap.close). */
  close?: () => void
}

/** Browser primitives the processor needs; replaced wholesale in tests. */
export interface ImageIO {
  decode(blob: Blob): Promise<DecodedImage | null>
  encode(image: DecodedImage, width: number, height: number, quality: number): Promise<Blob | null>
}

export interface ProcessedImage {
  /** The original blob when no resize was needed, otherwise a JPEG. */
  blob: Blob
  width: number
  height: number
  /** True when `blob` is a freshly encoded JPEG rather than the input. */
  resized: boolean
}

export interface ProcessImageOptions {
  maxDimension?: number
  quality?: number
  io?: ImageIO
}

/**
 * Target size for an image whose longest edge must fit `maxDimension`, or null
 * when it already does (iOS `scale >= 1.0` → return the original). Dimensions
 * are rounded to whole pixels and floored at 1 so a very lopsided image cannot
 * scale to a zero-width canvas.
 */
export function resizeTarget(
  width: number,
  height: number,
  maxDimension: number,
): { width: number; height: number } | null {
  const longest = Math.max(width, height)
  if (longest <= maxDimension) return null
  const scale = maxDimension / longest
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  }
}

function hasValidDimensions(image: DecodedImage): boolean {
  return (
    Number.isFinite(image.width) &&
    Number.isFinite(image.height) &&
    image.width > 0 &&
    image.height > 0
  )
}

// ---------------------------------------------------------------------------
// Default browser IO
// ---------------------------------------------------------------------------

function canvasToBlob(canvas: HTMLCanvasElement, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => {
    canvas.toBlob((blob) => resolve(blob), 'image/jpeg', quality)
  })
}

export const browserImageIO: ImageIO = {
  async decode(blob) {
    if (typeof createImageBitmap !== 'function') return null
    try {
      const bitmap = await createImageBitmap(blob)
      return {
        width: bitmap.width,
        height: bitmap.height,
        source: bitmap,
        close: () => bitmap.close(),
      }
    } catch {
      // Format the browser cannot decode (HEIC on non-Safari, a corrupt file):
      // the caller attaches the original bytes untouched.
      return null
    }
  },

  async encode(image, width, height, quality) {
    try {
      if (typeof OffscreenCanvas === 'function') {
        const canvas = new OffscreenCanvas(width, height)
        const context = canvas.getContext('2d')
        if (context === null) return null
        context.drawImage(image.source, 0, 0, width, height)
        return await canvas.convertToBlob({ type: 'image/jpeg', quality })
      }
      if (typeof document === 'undefined') return null
      const canvas = document.createElement('canvas')
      canvas.width = width
      canvas.height = height
      const context = canvas.getContext('2d')
      if (context === null) return null
      context.drawImage(image.source, 0, 0, width, height)
      return await canvasToBlob(canvas, quality)
    } catch {
      return null
    }
  },
}

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

/**
 * Downscales `blob` if its longest edge exceeds `maxDimension`. Returns null
 * when the image could not be decoded or re-encoded at all — the caller then
 * attaches the original bytes rather than dropping the file (iOS's picker
 * `continue`s past an unprocessable image, losing it silently).
 */
export async function processImage(
  blob: Blob,
  options: ProcessImageOptions = {},
): Promise<ProcessedImage | null> {
  const io = options.io ?? browserImageIO
  const maxDimension = options.maxDimension ?? MAX_IMAGE_DIMENSION
  const quality = options.quality ?? JPEG_QUALITY

  if (blob.size === 0) return null

  const decoded = await io.decode(blob)
  if (decoded === null) return null

  try {
    if (!hasValidDimensions(decoded)) return null

    const target = resizeTarget(decoded.width, decoded.height, maxDimension)
    if (target === null) {
      return { blob, width: decoded.width, height: decoded.height, resized: false }
    }

    const encoded = await io.encode(decoded, target.width, target.height, quality)
    if (encoded === null) return null
    return { blob: encoded, width: target.width, height: target.height, resized: true }
  } finally {
    decoded.close?.()
  }
}
