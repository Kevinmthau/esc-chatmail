// Outbound attachment preparation and the local attachment-row lifecycle.
// Ports of:
// - Views/Components/AttachmentPicker.swift (image processing BEFORE the 25 MB
//   check, `local_<uuid>` ids, oversize files skipped)
// - Services/Compose/ComposeAttachmentManager.swift (draft-side add/remove)
// - Services/Send/GmailSendService+Attachments.swift (queued → uploading →
//   uploaded | failed)
// - Services/Sync/Persistence/MessagePersister+Updates.swift
//   (matchingOptimisticLocalAttachment: the cid-then-fingerprint match that
//   lets the synced-back sent copy adopt the local row instead of duplicating
//   it)
//
// Deviation from iOS, deliberately: the picker there `continue`s past an
// oversize or unprocessable file, so the user is never told a photo did not
// make it. Here every skip is reported (skippedAttachmentMessage), and an
// image the browser cannot decode is attached as-is instead of being dropped.

import type { AttachmentRow } from '@/db/types'
import { MAX_ATTACHMENT_BYTES } from '@/lib/constants'
import { newId } from '@/lib/uuid'
import { fileExtensionForMimeType } from '@/mime/attachments'
import { processImage, type ProcessImageOptions } from './imageProcessor'

/** Prefix marking an attachment row that exists only on this device. */
export const LOCAL_ATTACHMENT_ID_PREFIX = 'local_'

/** Human-readable form of MAX_ATTACHMENT_BYTES for UI copy. */
export const MAX_ATTACHMENT_LABEL = `${Math.round(MAX_ATTACHMENT_BYTES / (1024 * 1024))} MB`

/** A file staged in the composer, not yet written to the database. */
export interface PendingAttachment {
  /** Local attachment-row id (`local_<uuid>`); doubles as the blob key. */
  id: string
  filename: string
  mimeType: string
  blob: Blob
  byteSize: number
  /** Pixel dimensions for images; 0 when unknown or not an image. */
  width: number
  height: number
}

export type SkipReason = 'tooLarge'

export interface SkippedAttachment {
  filename: string
  reason: SkipReason
  byteSize: number
}

export interface PreparedAttachments {
  attachments: PendingAttachment[]
  skipped: SkippedAttachment[]
}

export interface PrepareAttachmentsOptions {
  maxBytes?: number
  /** Forwarded to processImage (tests inject the decode/encode pair). */
  image?: ProcessImageOptions
}

export function newLocalAttachmentId(): string {
  // newId(), not crypto.randomUUID: the latter is secure-context-only.
  return `${LOCAL_ATTACHMENT_ID_PREFIX}${newId()}`
}

export function isLocalAttachmentId(id: string): boolean {
  return id.startsWith(LOCAL_ATTACHMENT_ID_PREFIX)
}

/** Replaces (or appends) a filename's extension, e.g. after a JPEG re-encode. */
function withExtension(filename: string, extension: string): string {
  const trimmed = filename.trim()
  const base = trimmed === '' ? 'attachment' : trimmed
  const dot = base.lastIndexOf('.')
  // A leading dot is part of the name (".profile"), not an extension.
  const stem = dot > 0 ? base.slice(0, dot) : base
  return `${stem}.${extension}`
}

function mimeTypeForFile(file: File): string {
  const type = file.type.trim()
  return type === '' ? 'application/octet-stream' : type
}

/**
 * Stages one file: images are downscaled first (so a 12 MP photo that would
 * blow the cap is accepted at 4096px), then the size limit is applied to the
 * bytes that will actually be sent — the iOS ordering exactly.
 */
export async function prepareAttachment(
  file: File,
  options: PrepareAttachmentsOptions = {},
): Promise<PendingAttachment | SkippedAttachment> {
  const maxBytes = options.maxBytes ?? MAX_ATTACHMENT_BYTES
  const sourceMimeType = mimeTypeForFile(file)

  let blob: Blob = file
  let mimeType = sourceMimeType
  let filename = file.name
  let width = 0
  let height = 0

  if (sourceMimeType.startsWith('image/')) {
    const processed = await processImage(file, options.image ?? {})
    if (processed !== null) {
      blob = processed.blob
      width = processed.width
      height = processed.height
      if (processed.resized) {
        mimeType = 'image/jpeg'
        filename = withExtension(filename, fileExtensionForMimeType('image/jpeg'))
      }
    }
  }

  if (blob.size > maxBytes) {
    return { filename: file.name, reason: 'tooLarge', byteSize: blob.size }
  }

  return {
    id: newLocalAttachmentId(),
    filename:
      filename.trim() === '' ? `attachment.${fileExtensionForMimeType(mimeType)}` : filename,
    mimeType,
    blob,
    byteSize: blob.size,
    width,
    height,
  }
}

function isSkipped(result: PendingAttachment | SkippedAttachment): result is SkippedAttachment {
  return 'reason' in result
}

/** Stages a picked file list, partitioned into staged and skipped entries. */
export async function prepareAttachments(
  files: readonly File[],
  options: PrepareAttachmentsOptions = {},
): Promise<PreparedAttachments> {
  const prepared: PreparedAttachments = { attachments: [], skipped: [] }
  for (const file of files) {
    const result = await prepareAttachment(file, options)
    if (isSkipped(result)) prepared.skipped.push(result)
    else prepared.attachments.push(result)
  }
  return prepared
}

/** UI copy naming what was left behind; null when nothing was skipped. */
export function skippedAttachmentMessage(skipped: readonly SkippedAttachment[]): string | null {
  if (skipped.length === 0) return null
  const names = skipped.map((entry) => `“${entry.filename}”`)
  if (names.length === 1) {
    return `${names[0]} is over the ${MAX_ATTACHMENT_LABEL} limit and was not attached.`
  }
  return `${names.join(', ')} are over the ${MAX_ATTACHMENT_LABEL} limit and were not attached.`
}

// ---------------------------------------------------------------------------
// Attachment rows
// ---------------------------------------------------------------------------

/**
 * The row an optimistic send writes for a staged attachment. gmailAttachmentId
 * is '' — nothing on the server can supply these bytes yet, which is exactly
 * what keeps db/blobs' LRU pruner from evicting them (see evictableKeys).
 */
export function localAttachmentRow(
  attachment: PendingAttachment,
  messageId: string,
): AttachmentRow {
  return {
    id: attachment.id,
    messageId,
    gmailAttachmentId: '',
    contentId: '',
    filename: attachment.filename,
    mimeType: attachment.mimeType,
    byteSize: attachment.byteSize,
    width: attachment.width,
    height: attachment.height,
    state: 'queued',
    lastDownloadFailedAt: 0,
  }
}

export function normalizedAttachmentFilename(filename: string): string {
  return filename.trim().toLowerCase()
}

/** The identifying fields of an incoming (server-parsed) attachment. */
export interface IncomingAttachmentIdentity {
  contentId: string
  filename: string
  mimeType: string
  byteSize: number
}

/**
 * Finds the local row an incoming server attachment is the synced-back copy
 * of: Content-ID when both carry one, otherwise filename + mimeType + byte
 * size among cid-less rows. `consumed` holds rows already claimed by an
 * earlier incoming part so two identical files in one message cannot both
 * match the same row.
 *
 * Returns null rather than guessing — an unmatched incoming part is simply
 * inserted as a new row.
 */
export function matchLocalAttachment(
  incoming: IncomingAttachmentIdentity,
  candidates: readonly AttachmentRow[],
  consumed: ReadonlySet<string>,
): AttachmentRow | null {
  const available = candidates.filter((row) => isLocalAttachmentId(row.id) && !consumed.has(row.id))
  if (available.length === 0) return null

  if (incoming.contentId !== '') {
    const byContentId = available.find((row) => row.contentId === incoming.contentId)
    if (byContentId !== undefined) return byContentId
  }

  const filename = normalizedAttachmentFilename(incoming.filename)
  return (
    available.find(
      (row) =>
        row.contentId === '' &&
        normalizedAttachmentFilename(row.filename) === filename &&
        row.mimeType === incoming.mimeType &&
        row.byteSize === incoming.byteSize,
    ) ?? null
  )
}
