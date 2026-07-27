// RFC-2822 MIME builder for outbound sends. Port of
// Services/Compose/MimeBuilder/{MimeBuilder,+Headers,+SimpleMessage,+Alternative}.swift.
//
// Scope (MVP): text/plain simple messages and multipart/alternative
// (text + html). Outbound attachments are OUT of scope — the iOS builder's
// multipart/mixed → multipart/related nesting (regular + inline CID
// attachments around the alternative part) is deliberately NOT implemented
// yet. TODO(attachments): port MimeBuilder+MultipartMessage.swift's
// multipart/mixed wrapper when outbound attachments land.
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

export interface BuildNewInput {
  from: MimeFrom
  to: readonly string[]
  subject?: string
  textBody: string
  /** When present the message is multipart/alternative (text + html). */
  htmlBody?: string
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

/** Base64 body encoding wrapped at 76 characters per line, \r\n separated. */
function encodeBodyBase64(text: string): string {
  const base64 = encodeUtf8Base64(text)
  const lines: string[] = []
  for (let i = 0; i < base64.length; i += BASE64_LINE_LENGTH) {
    lines.push(base64.slice(i, i + BASE64_LINE_LENGTH))
  }
  return lines.join('\r\n')
}

/** base64url-encodes a MIME string (unicode-safe) for Gmail's `raw` field. */
export function toBase64Url(mime: string): string {
  return encodeUtf8Base64(mime).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '')
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

  if (input.htmlBody === undefined) {
    // Plain text only (MimeBuilder+SimpleMessage.swift).
    mime += 'Content-Type: text/plain; charset=UTF-8\r\n'
    mime += 'Content-Transfer-Encoding: 8bit\r\n'
    mime += '\r\n'
    mime += input.textBody
    if (!input.textBody.endsWith('\r\n')) mime += '\r\n'
    return mime
  }

  // multipart/alternative: text + html, both base64 (MimeBuilder+Alternative.swift).
  const boundary = generateBoundary()
  mime += `Content-Type: multipart/alternative; boundary="${boundary}"\r\n`
  mime += '\r\n'

  mime += `--${boundary}\r\n`
  mime += 'Content-Type: text/plain; charset=UTF-8\r\n'
  mime += 'Content-Transfer-Encoding: base64\r\n'
  mime += '\r\n'
  mime += encodeBodyBase64(input.textBody)
  mime += '\r\n'

  mime += `--${boundary}\r\n`
  mime += 'Content-Type: text/html; charset=UTF-8\r\n'
  mime += 'Content-Transfer-Encoding: base64\r\n'
  mime += '\r\n'
  mime += encodeBodyBase64(input.htmlBody)
  mime += '\r\n'

  mime += `--${boundary}--\r\n`
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
