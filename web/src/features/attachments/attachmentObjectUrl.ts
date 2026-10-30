// What an attachment's bytes may be exposed AS. A blob: URL minted on the app
// origin IS the app origin: a document loaded from it — right-click "Open in
// new tab", middle-click, iOS long-press; the `download` attribute governs
// only a plain click — reads the mail store and auth state. So the type the
// sender declared never reaches an object URL unless it is a raster image the
// browser can only paint, never run as a document; everything else (SVG,
// HTML, PDF, ...) is re-typed to application/octet-stream, which no browser
// renders inline. The stored blob keeps its real type. iOS has no equivalent
// exposure: attachments are files handed to QuickLook.

const RASTER_IMAGE_TYPES = new Set([
  'image/jpeg',
  // Non-standard but common in the wild for JPEG bytes; browsers sniff and
  // paint it, and routing real photos to a file card is a worse failure than
  // admitting a mislabeled JPEG.
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/avif',
  'image/bmp',
])

/** True for the conservative raster allowlist that renders as an `<img>`. */
export function isRasterImageType(mimeType: string): boolean {
  const essence = mimeType.split(';', 1)[0]?.trim().toLowerCase() ?? ''
  return RASTER_IMAGE_TYPES.has(essence)
}

/** The blob an object URL is minted from: the stored one for raster images, a re-typed copy otherwise. */
export function objectUrlSourceBlob(blob: Blob): Blob {
  if (isRasterImageType(blob.type)) return blob
  return new Blob([blob], { type: 'application/octet-stream' })
}
