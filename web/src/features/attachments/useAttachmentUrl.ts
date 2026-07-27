// Object-URL lifecycle for attachment blobs: a module cache refcounts URLs per
// attachment id so multiple mounted views (bubble + lightbox) share one URL,
// and the URL is revoked when the last consumer unmounts.

import { useEffect, useState } from 'react'
import { useLiveQuery } from 'dexie-react-hooks'
import { getDB } from '@/db/schema'

interface CacheEntry {
  url: string
  blob: Blob
  refs: number
}

const urlCache = new Map<string, CacheEntry>()

function acquireUrl(key: string, blob: Blob): string {
  const entry = urlCache.get(key)
  if (entry !== undefined && entry.blob === blob) {
    entry.refs += 1
    return entry.url
  }
  const url = URL.createObjectURL(blob)
  urlCache.set(key, { url, blob, refs: 1 })
  return url
}

function releaseUrl(key: string, url: string): void {
  const entry = urlCache.get(key)
  if (entry === undefined || entry.url !== url) {
    // A newer blob replaced this entry; revoke the orphaned URL directly.
    URL.revokeObjectURL(url)
    return
  }
  entry.refs -= 1
  if (entry.refs <= 0) {
    URL.revokeObjectURL(entry.url)
    urlCache.delete(key)
  }
}

/**
 * Live object URL for a stored attachment blob. Returns null while the blob is
 * absent (not downloaded yet). Pass null to disable (keeps hook order stable).
 */
export function useAttachmentUrl(attachmentId: string | null): string | null {
  // Read the row directly (db/blobs.getBlob touches lastAccessAt, which would
  // retrigger this liveQuery forever).
  const blobRow = useLiveQuery(
    () => (attachmentId === null ? undefined : getDB().blobs.get(attachmentId)),
    [attachmentId],
  )
  // useLiveQuery keeps the PREVIOUS emission across a deps change, so right
  // after the lightbox pages to the next image `blobRow` is still the previous
  // image's row. Binding it to the new id would mint an object URL showing
  // image N-1 under image N's filename (and download it under that name).
  const blob = blobRow?.key === attachmentId ? blobRow.blob : null

  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    if (attachmentId === null || blob === null) {
      setUrl(null)
      return
    }
    const acquired = acquireUrl(attachmentId, blob)
    setUrl(acquired)
    return () => {
      releaseUrl(attachmentId, acquired)
    }
  }, [attachmentId, blob])

  return url
}
