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

function shouldTreatInlineDataPartAsAttachment(
  part: GmailPart,
  trimmedFilename: string,
  contentId: string | null,
): boolean {
  const contentDisposition = (headerValue(part, 'content-disposition') ?? '').toLowerCase()

  const hasAttachmentDisposition = contentDisposition.includes('attachment')
  const hasInlineDisposition = contentDisposition.includes('inline')
  const isInlineCIDImage =
    (part.mimeType?.toLowerCase().startsWith('image/') ?? false) &&
    contentId !== null &&
    contentId.length > 0

  if (hasAttachmentDisposition) {
    return true
  }

  if (trimmedFilename.length > 0) {
    return true
  }

  if (hasInlineDisposition && contentId !== null && contentId.length > 0) {
    return true
  }

  return isInlineCIDImage
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

/** True when any part in the tree carries a Gmail attachmentId. */
export function checkForAttachments(part: GmailPart): boolean {
  if (part.body?.attachmentId !== undefined) {
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
    const isMultipart = current.mimeType?.startsWith('multipart/') ?? false

    // Content-ID format is typically <unique-id@domain.com>; strip the angle
    // brackets for matching against cid: URLs.
    const rawContentId = headerValue(current, 'content-id')
    const contentId = rawContentId !== null ? rawContentId.replace(/^[<>]+|[<>]+$/g, '') : null

    const attachmentId = current.body?.attachmentId
    if (attachmentId !== undefined && !isMultipart && !seenIds.has(attachmentId)) {
      seenIds.add(attachmentId)
      attachments.push({
        id: attachmentId,
        filename: resolvedAttachmentFilename(trimmedFilename, mimeType),
        mimeType,
        size: current.body?.size ?? 0,
        contentId,
        inlineData: null,
      })
    } else if (
      !isMultipart &&
      current.body?.data !== undefined &&
      shouldTreatInlineDataPartAsAttachment(current, trimmedFilename, contentId)
    ) {
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
