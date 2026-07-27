// RFC-2822 MIME builder for outbound sends. Port of Services/Compose/
// MimeBuilder/{MimeBuilder,+Headers,+SimpleMessage,+Alternative,
// +MultipartMessage}.swift.
//
// Structures produced (iOS MimeBuilder+Alternative's doc comment verbatim):
//
//   text only, no attachments          text/plain (8bit)
//   text only, attachments             multipart/mixed
//                                      ├── text/plain (8bit)
//                                      └── attachments
//   text+html, no attachments          multipart/alternative
//                                      ├── text/plain (base64)
//                                      └── text/html  (base64)
//   text+html, attachments             multipart/mixed
//                                      ├── multipart/alternative
//                                      └── attachments
//   text+html, inline images           multipart/mixed
//                                      ├── multipart/related
//                                      │   ├── multipart/alternative
//                                      │   └── inline parts (Content-ID)
//                                      └── attachments
//
// Body parts wrap base64 at 76 characters, attachment parts at 64 — matching
// iOS's .lineLength76Characters / .lineLength64Characters exactly.
//
// Deviation from iOS: iOS's plain-text builder (buildMultipartMessage) has no
// multipart/related branch, so inline parts passed without an htmlBody are
// silently dropped. Here they are emitted into the multipart/mixed container
// as inline (Content-ID-carrying) parts instead — nothing a caller attached is
// ever discarded without a signal.
//
// Every header value passes through sanitizeHeaderValue (CRLF-injection
// defense) before being emitted. Line endings are \r\n throughout.
//
// Address validation (recipient-smuggling defense): stored participant
// emails come from inbound headers and can contain smuggled extra addresses
// (e.g. 'billing@acme.com, harvest@evil.tld' captured whole from a crafted
// From header). The builder is the enforcement boundary — parse-side changes
// would risk iOS participant-hash parity — so every address emitted into
// From/To must pass isSingleAddrSpec and threading headers only accept
// well-formed <message-id> tokens. A rejected recipient FAILS THE SEND
// (InvalidRecipientsError names it) rather than being dropped: silently
// narrowing the recipient set would deliver a group message to fewer people
// than the conversation header shows, with no signal anywhere.

import { newId } from '@/lib/uuid'

export interface MimeFrom {
  email: string
  /** Display name; RFC-2047-encoded when non-ASCII, quoted when it has specials. */
  name?: string
}

/** A file attached to an outbound message (iOS AttachmentData). */
export interface MimeAttachment {
  data: Uint8Array
  filename: string
  mimeType: string
}

/** An attachment referenced from the HTML body as `cid:<contentId>`. */
export interface MimeInlineAttachment extends MimeAttachment {
  /** Content-ID WITHOUT angle brackets; the builder adds them. */
  contentId: string
}

export interface BuildNewInput {
  from: MimeFrom
  to: readonly string[]
  subject?: string
  textBody: string
  /** When present the message is multipart/alternative (text + html). */
  htmlBody?: string
  /** Regular attachments (Content-Disposition: attachment). */
  attachments?: readonly MimeAttachment[]
  /** Inline parts (Content-ID + Content-Disposition: inline). */
  inlineAttachments?: readonly MimeInlineAttachment[]
}

export interface BuildReplyInput extends BuildNewInput {
  /** RFC 2822 Message-ID of the message being replied to (angle brackets included). */
  inReplyTo: string
  /** References chain, oldest first; space-joined into the References header. */
  references: readonly string[]
}

export interface MimeBuildOptions {
  /** Injectable clock for deterministic Date headers in tests. */
  now?: Date
}

/** Base64 line length for encoded body parts (iOS .lineLength76Characters). */
export const BASE64_LINE_LENGTH = 76

/** Base64 line length for attachment parts (iOS .lineLength64Characters). */
export const ATTACHMENT_BASE64_LINE_LENGTH = 64

/**
 * Ceiling on the base64url `raw` payload Gmail's simple `messages/send`
 * endpoint accepts (the resumable-upload endpoint is what lifts it, and is not
 * implemented here). Documented as 35 MB; enforced before the request so an
 * oversized send fails locally with a typed error instead of burning an upload
 * and coming back as an opaque 4xx.
 */
export const MAX_SEND_RAW_BYTES = 35 * 1024 * 1024

/**
 * Thrown when the encoded message exceeds MAX_SEND_RAW_BYTES. Carries both
 * numbers so the compose UI can say how far over the limit the message is.
 */
export class MessageTooLargeError extends Error {
  readonly rawBytes: number
  readonly limitBytes: number

  constructor(rawBytes: number, limitBytes: number) {
    super(`Encoded message is ${rawBytes} bytes; the send limit is ${limitBytes}`)
    this.name = 'MessageTooLargeError'
    this.rawBytes = rawBytes
    this.limitBytes = limitBytes
  }
}

// ---------------------------------------------------------------------------
// Address validation (recipient-smuggling defense)
// ---------------------------------------------------------------------------

/**
 * Thrown when the `to` list carries no address at all: the send must fail
 * loudly rather than silently go nowhere.
 */
export class NoValidRecipientsError extends Error {
  constructor() {
    super('No recipients remain after address validation')
    this.name = 'NoValidRecipientsError'
  }
}

/**
 * Thrown when one or more `to` entries fail the single-addr-spec check.
 * `addresses` carries the offenders so the compose UI can name them — the
 * send is refused whole rather than quietly narrowed to the survivors.
 */
export class InvalidRecipientsError extends Error {
  readonly addresses: readonly string[]

  constructor(addresses: readonly string[]) {
    super(`Not a single addr-spec: ${addresses.join(', ')}`)
    this.name = 'InvalidRecipientsError'
    this.addresses = [...addresses]
  }
}

/** Thrown when the From address fails the single-addr-spec check. */
export class InvalidSenderError extends Error {
  constructor(address: string) {
    super(`From address is not a single addr-spec: ${address}`)
    this.name = 'InvalidSenderError'
  }
}

/**
 * Conservative single-addr-spec shape check. Rejects anything that could
 * smuggle extra recipients or restructure the header: whitespace (incl.
 * Unicode), ',', ';', '<', '>', quotes, parens, square brackets, backslash,
 * colon, and control characters; requires exactly one '@' with a non-empty
 * local part and a domain without leading/trailing/doubled dots. Deliberately
 * permissive about non-ASCII (EAI addresses) and Gmail dot/plus forms.
 */
export function isSingleAddrSpec(address: string): boolean {
  if (address === '' || address.length > 320) return false
  // eslint-disable-next-line no-control-regex
  if (/[\s,;<>()[\]\\":\x00-\x1f\x7f]/u.test(address)) return false
  const at = address.indexOf('@')
  if (at < 1 || at !== address.lastIndexOf('@') || at === address.length - 1) return false
  const domain = address.slice(at + 1)
  if (domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) return false
  return true
}

/**
 * Loose `<message-id>` token check for In-Reply-To/References values:
 * a single angle-bracketed token with no whitespace or nested brackets.
 * (CR/LF is already stripped by sanitizeHeaderValue before this runs.)
 */
export function isMessageIdToken(token: string): boolean {
  return /^<[^<>\s]+>$/u.test(token)
}

/** Domain used in generated Message-ID headers. */
export const MESSAGE_ID_DOMAIN = 'inbox-chat.web'

// ---------------------------------------------------------------------------
// Header helpers (MimeBuilder+Headers.swift)
// ---------------------------------------------------------------------------

/**
 * Strips CR/LF sequences from a header value so user-controlled text can
 * never inject additional headers, then trims (sanitizeHeaderValue).
 */
export function sanitizeHeaderValue(value: string): string {
  return value.replaceAll('\r\n', ' ').replaceAll('\r', ' ').replaceAll('\n', ' ').trim()
}

/**
 * RFC-2047 encodes a header value when it contains non-ASCII characters:
 * `=?UTF-8?B?<base64>?=`. ASCII-only values pass through sanitized.
 */
export function encodeHeaderIfNeeded(text: string): string {
  const sanitized = sanitizeHeaderValue(text)
  // eslint-disable-next-line no-control-regex
  if (/^[\x00-\x7F]*$/.test(sanitized)) return sanitized
  return `=?UTF-8?B?${encodeUtf8Base64(sanitized)}?=`
}

/**
 * `Name <email>` From-header formatting: empty name → bare address; names
 * with `"<>,@\` specials are quoted (RFC 5322 quoted-string: backslashes
 * escaped first, then quotes); other names are RFC-2047-encoded when needed.
 * Deviation from iOS: the name is CRLF-stripped before the specials check
 * (strictly safer).
 */
export function formatFromHeader(email: string, name?: string): string {
  const sanitizedEmail = sanitizeHeaderValue(email)
  const sanitizedName = name === undefined ? '' : sanitizeHeaderValue(name)
  if (sanitizedName === '') return sanitizedEmail

  if (/["<>,@\\]/.test(sanitizedName)) {
    const escaped = sanitizedName.replaceAll('\\', '\\\\').replaceAll('"', '\\"')
    return `"${escaped}" <${sanitizedEmail}>`
  }
  return `${encodeHeaderIfNeeded(sanitizedName)} <${sanitizedEmail}>`
}

const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const
const MONTH_NAMES = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
] as const

function pad2(value: number): string {
  return String(value).padStart(2, '0')
}

/** RFC-2822 date in the local timezone: `EEE, dd MMM yyyy HH:mm:ss Z` (en-US). */
export function formatRfc2822Date(date: Date): string {
  const offsetMinutes = -date.getTimezoneOffset()
  const sign = offsetMinutes >= 0 ? '+' : '-'
  const absOffset = Math.abs(offsetMinutes)
  const zone = `${sign}${pad2(Math.floor(absOffset / 60))}${pad2(absOffset % 60)}`
  const day = DAY_NAMES[date.getDay()] ?? 'Sun'
  const month = MONTH_NAMES[date.getMonth()] ?? 'Jan'
  return `${day}, ${pad2(date.getDate())} ${month} ${date.getFullYear()} ${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())} ${zone}`
}

// newId(), not crypto.randomUUID: the latter is secure-context-only, so it is
// undefined on a plain-http LAN origin and would throw on every send there.
function generateMessageId(): string {
  return `<${newId()}@${MESSAGE_ID_DOMAIN}>`
}

function generateBoundary(): string {
  return `----Boundary${newId().replaceAll('-', '')}`
}

// ---------------------------------------------------------------------------
// Base64 helpers (unicode-safe)
// ---------------------------------------------------------------------------

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  const chunkSize = 0x8000
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize))
  }
  return btoa(binary)
}

function encodeUtf8Base64(text: string): string {
  return bytesToBase64(new TextEncoder().encode(text))
}

/** Wraps a base64 string at `lineLength` characters per line, \r\n separated. */
function wrapBase64(base64: string, lineLength: number): string {
  const lines: string[] = []
  for (let i = 0; i < base64.length; i += lineLength) {
    lines.push(base64.slice(i, i + lineLength))
  }
  return lines.join('\r\n')
}

/** Base64 body encoding wrapped at 76 characters per line, \r\n separated. */
function encodeBodyBase64(text: string): string {
  return wrapBase64(encodeUtf8Base64(text), BASE64_LINE_LENGTH)
}

/** base64url-encodes a MIME string (unicode-safe) for Gmail's `raw` field. */
export function toBase64Url(mime: string): string {
  return encodeUtf8Base64(mime).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '')
}

/**
 * base64url-encodes a built MIME message for `messages/send`, refusing
 * anything past MAX_SEND_RAW_BYTES. Callers run this BEFORE the optimistic
 * insert so an over-limit message fails with nothing to roll back — retrying
 * it would fail identically, so keeping a retryable failed bubble would be a
 * lie.
 */
export function encodeRawForSend(mime: string, limitBytes: number = MAX_SEND_RAW_BYTES): string {
  const raw = toBase64Url(mime)
  // base64url output is ASCII, so string length is byte length.
  if (raw.length > limitBytes) throw new MessageTooLargeError(raw.length, limitBytes)
  return raw
}

// ---------------------------------------------------------------------------
// Attachment part helpers
// ---------------------------------------------------------------------------

/** RFC 2045 token character class (used for the type/subtype shape check). */
const MIME_TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/u

/**
 * Narrows a caller-supplied media type to `type/subtype` of RFC 2045 tokens,
 * falling back to application/octet-stream. Without this a crafted type
 * (`image/png; boundary="…"`) could add parameters to — or restructure — the
 * part header it is interpolated into.
 */
export function sanitizeMimeType(mimeType: string): string {
  const sanitized = sanitizeHeaderValue(mimeType).toLowerCase()
  const slash = sanitized.indexOf('/')
  if (slash < 1) return 'application/octet-stream'
  const type = sanitized.slice(0, slash)
  const subtype = sanitized.slice(slash + 1)
  if (!MIME_TOKEN.test(type) || !MIME_TOKEN.test(subtype)) return 'application/octet-stream'
  return `${type}/${subtype}`
}

/**
 * Escapes a value for an RFC 2045 quoted-string parameter (`filename="…"`):
 * backslashes first, then quotes. Deviation from iOS, which interpolates the
 * filename raw — a name containing `"` would otherwise close the parameter
 * early and let the rest of the name be parsed as header syntax.
 *
 * Non-ASCII stays raw UTF-8 inside the quoted string, matching iOS: strictly
 * RFC 2045 headers are ASCII (RFC 2231 `filename*=` is the conformant spell),
 * but Gmail's API accepts the 8-bit form and hands the same name back on
 * sync, which keeps matchLocalAttachment's filename fingerprint stable. If a
 * receiving client mangles such a name, RFC 2231 is the fix — as its own
 * change, on both platforms.
 */
function quoteParameterValue(value: string): string {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')
}

/** CRLF-stripped filename, never empty (an unnamed part is undownloadable). */
function sanitizeFilename(filename: string): string {
  const sanitized = sanitizeHeaderValue(filename)
  return sanitized === '' ? 'attachment' : sanitized
}

/**
 * Content-ID body with angle brackets and whitespace removed — the builder
 * supplies the brackets, and a value carrying its own would nest them.
 * Returns '' when nothing usable remains (the part is then emitted inline
 * without a Content-ID rather than with a malformed one).
 */
function sanitizeContentId(contentId: string): string {
  return sanitizeHeaderValue(contentId).replaceAll(/[<>\s]/gu, '')
}

/**
 * One attachment part. `contentId` null → Content-Disposition: attachment;
 * non-null → Content-ID + Content-Disposition: inline (iOS emits both headers
 * for inline parts, in that order).
 */
function attachmentPart(
  boundary: string,
  attachment: MimeAttachment,
  contentId: string | null,
): string {
  const filename = quoteParameterValue(sanitizeFilename(attachment.filename))
  const mimeType = sanitizeMimeType(attachment.mimeType)

  let part = `--${boundary}\r\n`
  part += `Content-Type: ${mimeType}; name="${filename}"\r\n`
  part += 'Content-Transfer-Encoding: base64\r\n'
  if (contentId !== null && contentId !== '') part += `Content-ID: <${contentId}>\r\n`
  part += `Content-Disposition: ${contentId === null ? 'attachment' : 'inline'}; filename="${filename}"\r\n`
  part += '\r\n'
  part += wrapBase64(bytesToBase64(attachment.data), ATTACHMENT_BASE64_LINE_LENGTH)
  part += '\r\n'
  return part
}

function attachmentParts(
  boundary: string,
  attachments: readonly MimeAttachment[],
  inline: readonly MimeInlineAttachment[],
): string {
  let parts = ''
  for (const part of inline)
    parts += attachmentPart(boundary, part, sanitizeContentId(part.contentId))
  for (const part of attachments) parts += attachmentPart(boundary, part, null)
  return parts
}

/** The complete multipart/alternative section: header, both parts, terminator. */
function alternativeSection(boundary: string, textBody: string, htmlBody: string): string {
  let section = `Content-Type: multipart/alternative; boundary="${boundary}"\r\n`
  section += '\r\n'

  section += `--${boundary}\r\n`
  section += 'Content-Type: text/plain; charset=UTF-8\r\n'
  section += 'Content-Transfer-Encoding: base64\r\n'
  section += '\r\n'
  section += encodeBodyBase64(textBody)
  section += '\r\n'

  section += `--${boundary}\r\n`
  section += 'Content-Type: text/html; charset=UTF-8\r\n'
  section += 'Content-Transfer-Encoding: base64\r\n'
  section += '\r\n'
  section += encodeBodyBase64(htmlBody)
  section += '\r\n'

  section += `--${boundary}--\r\n`
  return section
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

interface ReplyHeaders {
  inReplyTo: string
  references: readonly string[]
}

function buildMime(
  input: BuildNewInput,
  reply: ReplyHeaders | null,
  options?: MimeBuildOptions,
): string {
  const fromEmail = sanitizeHeaderValue(input.from.email)
  if (!isSingleAddrSpec(fromEmail)) throw new InvalidSenderError(fromEmail)

  // Smuggling defense: every recipient must be a single addr-spec (stored
  // participant emails can carry smuggled extra addresses from crafted
  // inbound headers). A rejected address fails the whole send naming the
  // offender — dropping it would send the message to fewer people than the
  // user believes with no signal at all. Entries that sanitize to nothing
  // carry no address to report and are simply absent.
  const recipients: string[] = []
  const invalid: string[] = []
  for (const address of input.to) {
    const sanitized = sanitizeHeaderValue(address)
    if (sanitized === '') continue
    if (isSingleAddrSpec(sanitized)) recipients.push(sanitized)
    else invalid.push(sanitized)
  }
  if (invalid.length > 0) throw new InvalidRecipientsError(invalid)
  if (recipients.length === 0) throw new NoValidRecipientsError()

  let mime = ''
  mime += `From: ${formatFromHeader(fromEmail, input.from.name)}\r\n`
  mime += `To: ${recipients.join(', ')}\r\n`

  const subject = input.subject === undefined ? '' : sanitizeHeaderValue(input.subject)
  mime += `Subject: ${subject === '' ? '(No Subject)' : encodeHeaderIfNeeded(subject)}\r\n`

  mime += `Date: ${formatRfc2822Date(options?.now ?? new Date())}\r\n`
  mime += `Message-ID: ${generateMessageId()}\r\n`

  if (reply !== null) {
    // Threading values originate from inbound headers; only emit well-formed
    // <message-id> tokens so a crafted stored value cannot restructure the
    // header (CRLF is stripped by sanitizeHeaderValue first).
    const inReplyTo = sanitizeHeaderValue(reply.inReplyTo)
    if (inReplyTo !== '' && isMessageIdToken(inReplyTo)) mime += `In-Reply-To: ${inReplyTo}\r\n`
    const references = reply.references
      .map((ref) => sanitizeHeaderValue(ref))
      .filter((ref) => isMessageIdToken(ref))
    if (references.length > 0) mime += `References: ${references.join(' ')}\r\n`
  }

  mime += 'MIME-Version: 1.0\r\n'

  const attachments = input.attachments ?? []
  const inlineAttachments = input.inlineAttachments ?? []
  const hasParts = attachments.length > 0 || inlineAttachments.length > 0

  if (input.htmlBody === undefined) {
    if (!hasParts) {
      // Plain text only (MimeBuilder+SimpleMessage.swift).
      mime += 'Content-Type: text/plain; charset=UTF-8\r\n'
      mime += 'Content-Transfer-Encoding: 8bit\r\n'
      mime += '\r\n'
      mime += input.textBody
      if (!input.textBody.endsWith('\r\n')) mime += '\r\n'
      return mime
    }

    // multipart/mixed around an 8bit text part (MimeBuilder+MultipartMessage).
    const mixedBoundary = generateBoundary()
    mime += `Content-Type: multipart/mixed; boundary="${mixedBoundary}"\r\n`
    mime += '\r\n'

    mime += `--${mixedBoundary}\r\n`
    mime += 'Content-Type: text/plain; charset=UTF-8\r\n'
    mime += 'Content-Transfer-Encoding: 8bit\r\n'
    mime += '\r\n'
    mime += input.textBody
    mime += '\r\n'

    mime += attachmentParts(mixedBoundary, attachments, inlineAttachments)
    mime += `--${mixedBoundary}--\r\n`
    return mime
  }

  // multipart/alternative: text + html, both base64 (MimeBuilder+Alternative).
  if (!hasParts) {
    mime += alternativeSection(generateBoundary(), input.textBody, input.htmlBody)
    return mime
  }

  // multipart/mixed → [multipart/related →] multipart/alternative. Boundaries
  // are generated in the order the containers open (mixed, related,
  // alternative), matching iOS.
  const mixedBoundary = generateBoundary()
  mime += `Content-Type: multipart/mixed; boundary="${mixedBoundary}"\r\n`
  mime += '\r\n'
  mime += `--${mixedBoundary}\r\n`

  const relatedBoundary = inlineAttachments.length > 0 ? generateBoundary() : null
  if (relatedBoundary !== null) {
    mime += `Content-Type: multipart/related; boundary="${relatedBoundary}"\r\n`
    mime += '\r\n'
    mime += `--${relatedBoundary}\r\n`
  }

  mime += alternativeSection(generateBoundary(), input.textBody, input.htmlBody)

  if (relatedBoundary !== null) {
    mime += attachmentParts(relatedBoundary, [], inlineAttachments)
    mime += `--${relatedBoundary}--\r\n`
  }

  mime += attachmentParts(mixedBoundary, attachments, [])
  mime += `--${mixedBoundary}--\r\n`
  return mime
}

/** Builds a new (non-reply) RFC-2822 message; returns the raw MIME string. */
export function buildNew(input: BuildNewInput, options?: MimeBuildOptions): string {
  return buildMime(input, null, options)
}

/** Builds a reply with In-Reply-To/References threading headers. */
export function buildReply(input: BuildReplyInput, options?: MimeBuildOptions): string {
  return buildMime(input, { inReplyTo: input.inReplyTo, references: input.references }, options)
}
