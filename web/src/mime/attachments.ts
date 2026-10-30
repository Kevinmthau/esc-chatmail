// Attachment extraction, port of MessageProcessor.extractAttachments /
// checkForAttachments and AttachmentPaths.fileExtension.

import { sha256Hex } from '../identity/hash'
import type { GmailPart } from '../gmail/types'
import { base64UrlDecodeToBytes } from './decode'

export interface ParsedAttachment {
  /** Gmail attachmentId, or deterministic `local_inline_<hash>` for inline data parts. */
  id: string
  filename: string
  mimeType: string
  size: number
  /** Content-ID with angle brackets stripped; null when absent. */
  contentId: string | null
  /** Decoded bytes for inline-data parts; null for server attachments. */
  inlineData: Uint8Array | null
}

function headerValue(part: GmailPart, name: string): string | null {
  const header = part.headers?.find((h) => h.name.toLowerCase() === name)
  return header ? header.value : null
}

function normalizedContentId(part: GmailPart): string | null {
  const rawContentId = headerValue(part, 'content-id')
  return rawContentId !== null ? rawContentId.replace(/^[<>]+|[<>]+$/g, '') : null
}

function isMultipartPart(part: GmailPart): boolean {
  return part.mimeType?.toLowerCase().startsWith('multipart/') ?? false
}

function hasContentId(contentId: string | null): contentId is string {
  return contentId !== null && contentId.length > 0
}

/** `text/*`: the media types Gmail hands back behind an attachmentId as oversized bodies. */
function isTextualMimeType(mimeType: string | undefined): boolean {
  return mimeType?.toLowerCase().startsWith('text/') ?? false
}

/** The two body slots the content walk (parse.ts) fills. */
function isBodySlotMimeType(mimeType: string | undefined): boolean {
  const normalized = mimeType?.toLowerCase() ?? ''
  return normalized.startsWith('text/html') || normalized.startsWith('text/plain')
}

/**
 * Attachment evidence from MIME semantics alone — a filename, an `attachment`
 * disposition, or a Content-ID image (MessageProcessor.isAttachmentContentPart
 * plus the CID-image case of its inline-data rule). This is also the body-slot
 * exclusion the content walk (parse.ts) applies, so it must stay free of the
 * attachmentId signal: Gmail uses body.attachmentId as indirection for
 * oversized message bodies too, and a part admitted here is never a body.
 */
export function isAttachmentPart(part: GmailPart): boolean {
  if (isMultipartPart(part)) return false

  const trimmedFilename = part.filename?.trim() ?? ''
  const contentId = normalizedContentId(part)
  const contentDisposition = (headerValue(part, 'content-disposition') ?? '').toLowerCase()

  const hasAttachmentDisposition = contentDisposition.includes('attachment')
  const isInlineCIDImage =
    (part.mimeType?.toLowerCase().startsWith('image/') ?? false) && hasContentId(contentId)

  if (hasAttachmentDisposition) {
    return true
  }

  if (trimmedFilename.length > 0) {
    return true
  }

  return isInlineCIDImage
}

/**
 * MessageProcessor.extractAttachments's server-part rule. iOS takes every
 * non-multipart part carrying an attachmentId; here an oversized `text/*`
 * body arrives the same way (parse.ts follows it through fetchLargeBody), so
 * text parts still need the MIME evidence above. Anything else behind an
 * attachmentId can only be a file: a nameless `application/pdf` with no
 * Content-Disposition (Gmail lists it as "noname") is the attachment iOS
 * shows as `attachment.pdf`, and dropping it leaves the message with no
 * download affordance at all.
 */
export function isServerAttachmentPart(part: GmailPart): boolean {
  if (part.body?.attachmentId === undefined || isMultipartPart(part)) return false
  if (isAttachmentPart(part)) return true
  return !isTextualMimeType(part.mimeType)
}

/**
 * MessageProcessor.shouldTreatInlineDataPartAsAttachment: the MIME evidence
 * above, or an `inline` disposition paired with a Content-ID (a calendar or
 * PDF part a client embeds by reference without naming it). That last branch
 * stops at the body slots: a multipart/related root commonly carries
 * `Content-Disposition: inline` plus a Content-ID, and here the same part
 * feeds the content walk, so it stays the body rather than gaining an
 * `attachment.html` tile beside itself (parse.test pins it).
 */
export function isInlineDataAttachmentPart(part: GmailPart): boolean {
  if (isMultipartPart(part)) return false
  if (isAttachmentPart(part)) return true

  const contentDisposition = (headerValue(part, 'content-disposition') ?? '').toLowerCase()
  const hasInlineDisposition = contentDisposition.includes('inline')
  return (
    hasInlineDisposition &&
    hasContentId(normalizedContentId(part)) &&
    !isBodySlotMimeType(part.mimeType)
  )
}

export function fileExtensionForMimeType(mimeType: string): string {
  const type = mimeType.toLowerCase()
  switch (type) {
    // Images
    case 'image/jpeg':
    case 'image/jpg':
      return 'jpg'
    case 'image/png':
      return 'png'
    case 'image/heic':
    case 'image/heif':
      return 'heic'
    case 'image/gif':
      return 'gif'
    case 'image/webp':
      return 'webp'
    case 'image/bmp':
      return 'bmp'
    case 'image/tiff':
      return 'tiff'

    // PDF
    case 'application/pdf':
      return 'pdf'

    // Video
    case 'video/mp4':
      return 'mp4'
    case 'video/quicktime':
      return 'mov'
    case 'video/x-m4v':
      return 'm4v'

    // Microsoft Word
    case 'application/msword':
      return 'doc'
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      return 'docx'

    // Microsoft Excel
    case 'application/vnd.ms-excel':
      return 'xls'
    case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
      return 'xlsx'

    // Microsoft PowerPoint
    case 'application/vnd.ms-powerpoint':
      return 'ppt'
    case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
      return 'pptx'

    // Apple iWork
    case 'application/vnd.apple.pages':
    case 'application/x-iwork-pages-sffpages':
      return 'pages'
    case 'application/vnd.apple.numbers':
    case 'application/x-iwork-numbers-sffnumbers':
      return 'numbers'
    case 'application/vnd.apple.keynote':
    case 'application/x-iwork-keynote-sffkey':
      return 'keynote'

    // Text files
    case 'text/plain':
      return 'txt'
    case 'text/csv':
      return 'csv'
    case 'text/rtf':
    case 'application/rtf':
      return 'rtf'
    case 'text/html':
      return 'html'
    case 'text/xml':
    case 'application/xml':
      return 'xml'
    case 'application/json':
      return 'json'

    // Archives
    case 'application/zip':
    case 'application/x-zip-compressed':
      return 'zip'
    case 'application/x-rar-compressed':
      return 'rar'
    case 'application/x-7z-compressed':
      return '7z'
    case 'application/gzip':
      return 'gz'
    case 'application/x-tar':
      return 'tar'

    default:
      break
  }

  // Fallbacks with pattern matching (order matches the iOS switch).
  if (type.includes('image')) return 'jpg'
  if (type.includes('pdf')) return 'pdf'
  if (type.includes('word')) return 'docx'
  if (type.includes('excel') || type.includes('spreadsheet')) return 'xlsx'
  if (type.includes('powerpoint') || type.includes('presentation')) return 'pptx'
  if (type.includes('pages')) return 'pages'
  if (type.includes('numbers')) return 'numbers'
  if (type.includes('keynote')) return 'keynote'
  if (type.includes('video')) return 'mp4'

  return 'dat'
}

function resolvedAttachmentFilename(trimmedFilename: string, mimeType: string): string {
  if (trimmedFilename.length === 0) {
    return `attachment.${fileExtensionForMimeType(mimeType)}`
  }
  return trimmedFilename
}

/**
 * True when any part in the tree has both content and attachment semantics —
 * the same two admissions extractAttachments applies, minus the decode.
 */
export function checkForAttachments(part: GmailPart): boolean {
  if (isServerAttachmentPart(part)) {
    return true
  }

  if (part.body?.data !== undefined && isInlineDataAttachmentPart(part)) {
    return true
  }

  if (part.parts) {
    return part.parts.some((subpart) => checkForAttachments(subpart))
  }

  return false
}

/**
 * Recursively extracts attachments: parts with a Gmail attachmentId (deduped
 * by id), plus inline-data parts that behave like attachments (deterministic
 * `local_inline_` id from a content fingerprint).
 */
export function extractAttachments(part: GmailPart): ParsedAttachment[] {
  const attachments: ParsedAttachment[] = []
  const seenIds = new Set<string>()
  const seenInlineFingerprints = new Set<string>()

  const traverse = (current: GmailPart): void => {
    const trimmedFilename = current.filename?.trim() ?? ''
    const mimeType = current.mimeType ?? 'application/octet-stream'

    // Content-ID format is typically <unique-id@domain.com>; strip the angle
    // brackets for matching against cid: URLs.
    const contentId = normalizedContentId(current)

    const attachmentId = current.body?.attachmentId
    if (
      attachmentId !== undefined &&
      isServerAttachmentPart(current) &&
      !seenIds.has(attachmentId)
    ) {
      seenIds.add(attachmentId)
      attachments.push({
        id: attachmentId,
        filename: resolvedAttachmentFilename(trimmedFilename, mimeType),
        mimeType,
        size: current.body?.size ?? 0,
        contentId,
        inlineData: null,
      })
    } else if (current.body?.data !== undefined && isInlineDataAttachmentPart(current)) {
      const decodedData = base64UrlDecodeToBytes(current.body.data)
      if (decodedData !== null) {
        const size = current.body.size ?? decodedData.length
        const fingerprint = `${current.partId ?? ''}|${trimmedFilename}|${mimeType}|${contentId ?? ''}|${size}`
        if (!seenInlineFingerprints.has(fingerprint)) {
          seenInlineFingerprints.add(fingerprint)
          attachments.push({
            id: `local_inline_${sha256Hex(fingerprint).slice(0, 16)}`,
            filename: resolvedAttachmentFilename(trimmedFilename, mimeType),
            mimeType,
            size,
            contentId,
            inlineData: decodedData,
          })
        }
      }
    }

    for (const subpart of current.parts ?? []) {
      traverse(subpart)
    }
  }

  traverse(part)
  return attachments
}
