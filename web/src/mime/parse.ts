// Gmail message parsing: headers, recursive content walk (with large-body
// indirection), embedded-HTML rescue, and attachments.
// Port of MessageProcessor.processGmailMessage / extractHeaders /
// extractContent.

import type { CalendarEventData } from '../db/types'
import { GmailApiError } from '../gmail/errors'
import type { GmailHeader, GmailMessage, GmailPart } from '../gmail/types'
import { addressTokens, extractDisplayName, extractEmail, normalizeEmail } from './address'
import { extractAttachments, isAttachmentPart, type ParsedAttachment } from './attachments'
import { analyzeCalendarInvite } from './calendarInvite'
import { base64UrlDecodeToString, decodeTransferEncoding } from './decode'
import { extractPlainTextFromHtml } from './htmlText'
import { extractDisplayText, extractHtmlFromRawSource } from './rawSource'

export interface ParsedAddress {
  email: string
  name: string | null
}

export interface ParsedHeaders {
  subject: string | null
  /** Parsed From address; null when the header is absent or unparseable. */
  from: ParsedAddress | null
  /** Raw From header value (needed for newsletter sender-pattern scoring). */
  fromRaw: string | null
  to: ParsedAddress[]
  cc: ParsedAddress[]
  bcc: ParsedAddress[]
  replyTo: string | null
  inReplyTo: string | null
  references: string[]
  messageIdHeader: string | null
  listId: string | null
  listUnsubscribe: string | null
  listUnsubscribePost: string | null
  precedence: string | null
}

export interface ParsedMessage {
  id: string
  threadId: string
  headers: ParsedHeaders
  html: string | null
  plainText: string | null
  attachments: ParsedAttachment[]
  hasAttachments: boolean
  /** Epoch milliseconds. */
  internalDate: number
  labelIds: string[]
  snippet: string | null
  /** Calendar-invite verdict (mime/calendarInvite). */
  isLikelyCalendarInvite: boolean
  /** The invite's VEVENT; null when there is none or it did not parse. */
  calendarEvent: CalendarEventData | null
}

export interface ParseGmailMessageOptions {
  /**
   * Fetches a large body part (Gmail returns >~25KB parts with attachmentId
   * instead of inline data). Resolves to the base64url-encoded bytes.
   */
  fetchLargeBody?: (messageId: string, attachmentId: string) => Promise<string>
}

// MARK: - Headers

/**
 * All addresses in a recipient-style header value, token-aware (quoted
 * strings and angle brackets respected). Exported for conversation-identity
 * extraction, which must include EVERY From mailbox (iOS
 * makeConversationIdentity splits the whole raw header value).
 */
export function parseEmailAddresses(headerValue: string): ParsedAddress[] {
  const result: ParsedAddress[] = []
  for (const token of addressTokens(headerValue)) {
    const email = extractEmail(token)
    if (email === null) continue
    result.push({
      email: normalizeEmail(email),
      name: extractDisplayName(token),
    })
  }
  return result
}

function extractHeaders(headers: readonly GmailHeader[]): ParsedHeaders {
  const parsed: ParsedHeaders = {
    subject: null,
    from: null,
    fromRaw: null,
    to: [],
    cc: [],
    bcc: [],
    replyTo: null,
    inReplyTo: null,
    references: [],
    messageIdHeader: null,
    listId: null,
    listUnsubscribe: null,
    listUnsubscribePost: null,
    precedence: null,
  }

  for (const header of headers) {
    switch (header.name.toLowerCase()) {
      case 'subject':
        parsed.subject = header.value
        break
      case 'from': {
        parsed.fromRaw = header.value
        const email = extractEmail(header.value)
        if (email !== null) {
          parsed.from = {
            email: normalizeEmail(email),
            name: extractDisplayName(header.value),
          }
        }
        break
      }
      case 'to':
        parsed.to = parseEmailAddresses(header.value)
        break
      case 'cc':
        parsed.cc = parseEmailAddresses(header.value)
        break
      case 'bcc':
        parsed.bcc = parseEmailAddresses(header.value)
        break
      case 'reply-to':
        parsed.replyTo = header.value
        break
      case 'in-reply-to':
        parsed.inReplyTo = header.value
        break
      case 'references':
        parsed.references = header.value.split(/\s+/).filter((r) => r.length > 0)
        break
      case 'message-id':
        parsed.messageIdHeader = header.value
        break
      case 'list-unsubscribe':
        parsed.listUnsubscribe = header.value
        break
      case 'list-unsubscribe-post':
        parsed.listUnsubscribePost = header.value
        break
      case 'list-id':
        parsed.listId = header.value
        break
      case 'precedence':
        parsed.precedence = header.value
        break
      default:
        break
    }
  }

  return parsed
}

// MARK: - Content extraction

function headerValueOf(part: GmailPart, name: string): string | null {
  const header = part.headers?.find((h) => h.name.toLowerCase() === name)
  return header ? header.value : null
}

function resolvedMimeType(part: GmailPart): string | null {
  const direct = part.mimeType?.trim()
  if (direct !== undefined && direct.length > 0) {
    return direct
  }

  const contentType = headerValueOf(part, 'content-type')?.trim()
  if (contentType === undefined || contentType === null || contentType.length === 0) {
    return null
  }
  return contentType
}

function isHtmlMimeType(mimeType: string | null): boolean {
  if (mimeType === null) return false
  const normalized = mimeType.trim().toLowerCase()
  return normalized.length > 0 && normalized.startsWith('text/html')
}

function isPlainTextMimeType(mimeType: string | null): boolean {
  if (mimeType === null) return false
  const normalized = mimeType.trim().toLowerCase()
  return normalized.length > 0 && normalized.startsWith('text/plain')
}

/**
 * Whether a part could carry raw email source with HTML embedded in it — the
 * only thing the embedded-HTML rescue is looking for. Mirrors
 * HTMLContentRecoveryService.canContainEmbeddedRawSourceHTML: textual parts
 * only, defaulting to true when the type is unknown.
 *
 * Without this gate the rescue decodes (and, for oversized parts, DOWNLOADS)
 * every binary attachment in an HTML-less message just to run a regex over it.
 */
function canContainEmbeddedRawSourceHtml(mimeType: string | null): boolean {
  if (mimeType === null) return true
  const normalized = mimeType.trim().toLowerCase()
  if (normalized.length === 0) return true
  return normalized.startsWith('text/') || normalized.startsWith('message/')
}

export class LargeBodyFetchError extends Error {
  readonly messageId: string
  readonly attachmentId: string

  constructor(messageId: string, attachmentId: string, options?: { cause?: unknown }) {
    super(`Could not fetch large body ${attachmentId} for message ${messageId}`, options)
    this.name = 'LargeBodyFetchError'
    this.messageId = messageId
    this.attachmentId = attachmentId
  }
}

function decodeBody(data: string, headers: readonly GmailHeader[] | undefined): string | null {
  const text = base64UrlDecodeToString(data)
  if (text === null) return null
  return decodeTransferEncoding(text, headers)
}

async function fetchLargeBodyContent(
  attachmentId: string,
  messageId: string,
  headers: readonly GmailHeader[] | undefined,
  fetchLargeBody: ParseGmailMessageOptions['fetchLargeBody'],
): Promise<string | null> {
  if (fetchLargeBody === undefined) return null
  try {
    const base64url = await fetchLargeBody(messageId, attachmentId)
    const text = base64UrlDecodeToString(base64url)
    if (text === null) return null
    return decodeTransferEncoding(text, headers)
  } catch (error) {
    // A missing attachment is deterministic; malformed returned bytes are
    // handled by the decoder above. Everything else may recover later and
    // must prevent an incomplete message from being persisted.
    if (error instanceof GmailApiError && error.status === 404) return null
    throw new LargeBodyFetchError(messageId, attachmentId, { cause: error })
  }
}

/**
 * De-dupes large-body downloads within one message: `extractContent` and the
 * embedded-HTML rescue both walk the same tree, so an oversized text body would
 * otherwise be pulled twice (two `attachments.get` calls, 5 quota units and a
 * multi-MB buffer each).
 */
function memoizeLargeBodyFetch(
  fetchLargeBody: ParseGmailMessageOptions['fetchLargeBody'],
): ParseGmailMessageOptions['fetchLargeBody'] {
  if (fetchLargeBody === undefined) return undefined
  const inFlight = new Map<string, Promise<string>>()
  return (messageId, attachmentId) => {
    const key = `${messageId} ${attachmentId}`
    const existing = inFlight.get(key)
    if (existing !== undefined) return existing
    const pending = fetchLargeBody(messageId, attachmentId)
    inFlight.set(key, pending)
    return pending
  }
}

interface ExtractedMessageContent {
  html: string | null
  plainText: string | null
}

function normalizedNonEmpty(value: string | null): string | null {
  if (value === null) return null
  return value.trim().length === 0 ? null : value
}

function normalizedPlainTextBody(plainText: string | null): string | null {
  if (plainText === null) return null
  const normalized = extractDisplayText(plainText).trim()
  return normalized.length === 0 ? null : normalized
}

async function extractContent(
  part: GmailPart,
  messageId: string,
  injectedFetchLargeBody: ParseGmailMessageOptions['fetchLargeBody'],
): Promise<ExtractedMessageContent> {
  const fetchLargeBody = memoizeLargeBodyFetch(injectedFetchLargeBody)

  const decodedBody = async (current: GmailPart): Promise<string | null> => {
    if (current.body?.data !== undefined) {
      return decodeBody(current.body.data, current.headers)
    }

    if (current.body?.attachmentId !== undefined) {
      return fetchLargeBodyContent(
        current.body.attachmentId,
        messageId,
        current.headers,
        fetchLargeBody,
      )
    }

    return null
  }

  const extract = async (current: GmailPart): Promise<ExtractedMessageContent> => {
    const mimeType = resolvedMimeType(current)

    if (isAttachmentPart(current)) {
      return { html: null, plainText: null }
    }

    if (isHtmlMimeType(mimeType)) {
      return { html: normalizedNonEmpty(await decodedBody(current)), plainText: null }
    }
    if (isPlainTextMimeType(mimeType)) {
      return { html: null, plainText: normalizedNonEmpty(await decodedBody(current)) }
    }

    const parts = current.parts
    if (parts === undefined || parts.length === 0) {
      return { html: null, plainText: null }
    }

    const extracted: ExtractedMessageContent = { html: null, plainText: null }
    for (const subpart of parts) {
      const childContent = await extract(subpart)
      if (extracted.html === null) {
        extracted.html = childContent.html
      }
      if (extracted.plainText === null) {
        extracted.plainText = childContent.plainText
      }
      if (extracted.html !== null && extracted.plainText !== null) {
        break
      }
    }

    return extracted
  }

  const extracted = await extract(part)

  if (extracted.html === null) {
    extracted.html = await extractEmbeddedHtmlFromTextualBodies(part, messageId, fetchLargeBody)
  }

  return { html: extracted.html, plainText: normalizedPlainTextBody(extracted.plainText) }
}

async function extractEmbeddedHtmlFromTextualBodies(
  part: GmailPart,
  messageId: string,
  fetchLargeBody: ParseGmailMessageOptions['fetchLargeBody'],
): Promise<string | null> {
  // An attachment part is never a body slot, so it can never hold the message's
  // embedded HTML — and decoding it would mean pulling the whole file
  // (HTMLContentRecoveryService.collectHTMLCandidates returns [] here too).
  if (isAttachmentPart(part)) return null

  const decodedText = await decodedTextualBody(part, messageId, fetchLargeBody)
  if (decodedText !== null) {
    const extractedHtml = extractHtmlFromRawSource(decodedText)
    if (extractedHtml !== null) {
      const trimmed = extractedHtml.trim()
      if (trimmed.length > 0) {
        return trimmed
      }
    }
  }

  for (const subpart of part.parts ?? []) {
    const html = await extractEmbeddedHtmlFromTextualBodies(subpart, messageId, fetchLargeBody)
    if (html !== null) {
      return html
    }
  }

  return null
}

async function decodedTextualBody(
  part: GmailPart,
  messageId: string,
  fetchLargeBody: ParseGmailMessageOptions['fetchLargeBody'],
): Promise<string | null> {
  if (!canContainEmbeddedRawSourceHtml(resolvedMimeType(part))) return null

  if (part.body?.data !== undefined) {
    return decodeBody(part.body.data, part.headers)
  }

  if (part.body?.attachmentId !== undefined) {
    return fetchLargeBodyContent(part.body.attachmentId, messageId, part.headers, fetchLargeBody)
  }

  return null
}

// MARK: - Entry point

/**
 * Parses a Gmail API message into headers, bodies, and attachments.
 * Returns null when the message carries no payload/headers (mirrors the iOS
 * guard in processGmailMessage).
 */
export async function parseGmailMessage(
  msg: GmailMessage,
  opts: ParseGmailMessageOptions = {},
): Promise<ParsedMessage | null> {
  const payload = msg.payload
  if (payload === undefined || payload.headers === undefined) {
    return null
  }

  const headers = extractHeaders(payload.headers)

  let internalDate = Date.now()
  if (msg.internalDate !== undefined) {
    const parsed = Number(msg.internalDate)
    if (Number.isFinite(parsed)) {
      internalDate = parsed
    }
  }

  const content = await extractContent(payload, msg.id, opts.fetchLargeBody)

  let plainText = content.plainText
  if (plainText === null && content.html !== null) {
    const extracted = extractPlainTextFromHtml(content.html).trim()
    plainText = extracted.length === 0 ? null : extracted
  }

  const attachments = extractAttachments(payload)
  const hasAttachments = attachments.length > 0

  const calendar = analyzeCalendarInvite({
    payload,
    subject: headers.subject,
    snippet: msg.snippet ?? null,
    bodyText: plainText,
  })

  return {
    id: msg.id,
    threadId: msg.threadId,
    headers,
    html: content.html,
    plainText,
    attachments,
    hasAttachments,
    internalDate,
    labelIds: msg.labelIds ?? [],
    snippet: msg.snippet ?? null,
    isLikelyCalendarInvite: calendar.isLikelyCalendarInvite,
    calendarEvent: calendar.event,
  }
}
