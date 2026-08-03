// On-demand attachment download: Gmail attachments endpoint → base64url decode
// → blobs table → state 'downloaded'. Mirrors the reader's inline-cid download
// path (features/reader/useEmailHtml keeps its helper private, so the
// attachments module carries its own copy with the same broker-registration
// pattern; the app shell wires both at startup).

import { putBlob } from '@/db/blobs'
import type { ChatmailDB } from '@/db/schema'
import type { AttachmentRow } from '@/db/types'
import { getAttachment } from '@/gmail/endpoints'
import type { TokenBroker } from '@/gmail/gmailFetch'
import { base64UrlDecodeToBytes } from '@/mime/decode'

let downloadBroker: TokenBroker | null = null

/** The app shell registers its AuthBroker once at startup (null on sign-out). */
export function setAttachmentDownloadBroker(broker: TokenBroker | null): void {
  downloadBroker = broker
}

const inFlight = new Map<string, Promise<Blob | null>>()

export function isAttachmentDownloadInFlight(attachmentId: string): boolean {
  return inFlight.has(attachmentId)
}

/**
 * Downloads an attachment's bytes and persists them. Returns the Blob, or null
 * when the download is impossible (no broker / local-only part) or failed —
 * failures stamp state 'failed' + lastDownloadFailedAt for the retry overlay.
 * Concurrent calls for the same attachment share one request.
 *
 * A full origin quota is not a terminal condition: putBlob evicts the LRU tail
 * and retries, so this succeeds where it used to leave the row failed forever.
 * If even that fails the row is marked failed like any other error — the retry
 * affordance is the right next step either way.
 */
export async function downloadAttachment(
  db: ChatmailDB,
  attachment: AttachmentRow,
): Promise<Blob | null> {
  const broker = downloadBroker
  if (broker === null || attachment.gmailAttachmentId === '') return null

  const existing = inFlight.get(attachment.id)
  if (existing !== undefined) return existing

  const task = (async (): Promise<Blob | null> => {
    try {
      const response = await getAttachment(
        broker,
        attachment.messageId,
        attachment.gmailAttachmentId,
      )
      const bytes = base64UrlDecodeToBytes(response.data)
      if (bytes === null) throw new Error('Undecodable attachment payload')
      const blob = new Blob([bytes.buffer as ArrayBuffer], {
        type: attachment.mimeType.length > 0 ? attachment.mimeType : 'application/octet-stream',
      })
      await putBlob(db, attachment.id, blob)
      await db.attachments.update(attachment.id, { state: 'downloaded', byteSize: blob.size })
      return blob
    } catch {
      await db.attachments
        .update(attachment.id, { state: 'failed', lastDownloadFailedAt: Date.now() })
        .catch(() => undefined)
      return null
    } finally {
      inFlight.delete(attachment.id)
    }
  })()

  inFlight.set(attachment.id, task)
  return task
}
