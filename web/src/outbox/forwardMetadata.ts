// Forward composition formatting. Port of
// Services/Compose/MessageFormatBuilder.swift (formatForwardedMessage,
// buildHTMLForward, buildFinalHTMLForForward, convertPlainTextToHTML) and
// Services/Compose/ComposeForwardModeContextBuilder.swift.
//
// Pure string work only: no DOM, no Dexie. The DB read and the DOMPurify pass
// that produces `sanitizedContentHtml` live in features/compose/forwardSource
// — this module never sees raw remote HTML, and everything it interpolates
// into markup is escaped here.

import { isForwardedSubject } from '@/mime/preview'

/** Separator line that opens the forwarded block (Gmail's exact wording). */
export const FORWARD_MARKER = '---------- Forwarded message ---------'

/** Variants accepted when splitting a compose body back into its user note. */
const FORWARD_MARKERS = [
  FORWARD_MARKER,
  '---------- Forwarded message ----------',
  '----- Forwarded message -----',
]

/** Header lines that open a forwarded block. Empty strings are omitted. */
export interface ForwardHeaderFields {
  /** Original sender: display name when known, address otherwise. */
  from: string
  /** Pre-formatted original date (formatForwardDate). */
  date: string
  /** Original subject WITHOUT the 'Fwd: ' prefix; '' when it had none. */
  subject: string
  /** Original recipients, comma-joined; '' when none are known. */
  to: string
}

// ---------------------------------------------------------------------------
// Subject
// ---------------------------------------------------------------------------

/**
 * 'Fwd: ' prefix, idempotent and case-insensitive — the mirror of
 * prefixSubjectForReply. Idempotence goes through mime/preview's
 * isForwardedSubject so it recognizes exactly the prefixes ('fwd:', 'fw:')
 * the display heuristic already treats as forwarded, and an already-forwarded
 * subject is passed through untouched rather than growing 'Fwd: Fwd: '.
 */
export function prefixSubjectForForward(subject: string): string {
  const trimmed = subject.trim()
  if (trimmed === '') return ''
  if (isForwardedSubject(trimmed)) return trimmed
  return `Fwd: ${trimmed}`
}

/**
 * Original-message date for the header block. iOS formats in the device
 * locale (.medium date + .short time); here the locale is pinned to en-US so
 * the emitted block is deterministic across environments — a deliberate
 * divergence from iOS, not an oversight.
 */
export function formatForwardDate(timestamp: number): string {
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(
    new Date(timestamp),
  )
}

// ---------------------------------------------------------------------------
// Plain text
// ---------------------------------------------------------------------------

/**
 * The forwarded block prefilled into the compose body: two blank lines (room
 * for the user's note above it), the marker, the header lines, then the
 * original content.
 */
export function buildForwardTextBlock(header: ForwardHeaderFields, content: string): string {
  let text = `\n\n${FORWARD_MARKER}\n`
  text += `From: ${header.from}\n`
  text += `Date: ${header.date}\n`
  if (header.subject !== '') text += `Subject: ${header.subject}\n`
  if (header.to !== '') text += `To: ${header.to}\n`
  text += '\n'
  return text + content
}

/**
 * The user's own note: everything the compose body holds above the forwarded
 * marker (MessageFormatBuilder.extractUserContent). A body with no marker at
 * all is entirely the user's.
 */
export function extractUserNote(body: string): string {
  for (const marker of FORWARD_MARKERS) {
    const index = body.indexOf(marker)
    if (index >= 0) return body.slice(0, index).trim()
  }
  return body.trim()
}

/** Everything from the forwarded marker down; null when no marker remains. */
function forwardedBlockOf(body: string): string | null {
  for (const marker of FORWARD_MARKERS) {
    const index = body.indexOf(marker)
    if (index >= 0) return body.slice(index)
  }
  return null
}

/**
 * True when the compose body still carries the pristine forwarded block —
 * everything from the marker down is byte-identical to what the draft
 * prefilled. The html alternative is rebuilt at send time from the same
 * pristine pieces, so it may only ship while this holds: once the user edits
 * or deletes any of the block, the plain text is the only honest copy, and
 * sending the pristine html would silently ship content they deleted (or
 * hide edits they made) to every client that prefers html.
 */
export function forwardedBlockUnedited(body: string, pristineBody: string): boolean {
  return forwardedBlockOf(body) === forwardedBlockOf(pristineBody)
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

/** Escapes the five HTML specials (MessageFormatBuilder.escapeHTML). */
export function escapeHtml(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

// Runs over ALREADY-ESCAPED text, so the excluded characters ('&', quotes,
// angle brackets) also stop a match from running into an entity.
const AUTOLINK_PATTERN = /(https?:\/\/[^\s<>&"']+|www\.[^\s<>&"']+)/gi

function autoLinkUrls(escaped: string): string {
  return escaped.replace(AUTOLINK_PATTERN, (url) => {
    const href = url.toLowerCase().startsWith('http') ? url : `https://${url}`
    return `<a href="${href}" style="color: #007AFF; text-decoration: none;">${url}</a>`
  })
}

/**
 * Plain text → HTML preserving line breaks and auto-linking URLs
 * (convertPlainTextToHTML). Escaping happens FIRST, so this is safe for
 * arbitrary user text.
 */
export function plainTextToHtml(text: string): string {
  const escaped = autoLinkUrls(escapeHtml(text)).replaceAll('\r\n', '\n').replaceAll('\r', '\n')

  const paragraphs = escaped.split('\n\n')
  if (paragraphs.length === 1) {
    return `<div style="margin: 0;">${escaped.replaceAll('\n', '<br>\n')}</div>`
  }
  return paragraphs
    .map((paragraph) => {
      const trimmed = paragraph.trim()
      if (trimmed === '') return ''
      return `<p style="margin: 0 0 1em 0;">${trimmed.replaceAll('\n', '<br>\n')}</p>`
    })
    .filter((paragraph) => paragraph !== '')
    .join('\n')
}

/** The bordered 'Forwarded message' header block (buildHTMLForward). */
export function buildForwardHeaderHtml(header: ForwardHeaderFields): string {
  const lines = [
    `<div style="margin-bottom: 5px;"><strong>${FORWARD_MARKER}</strong></div>`,
    `<div><strong>From:</strong> ${escapeHtml(header.from)}</div>`,
    `<div><strong>Date:</strong> ${escapeHtml(header.date)}</div>`,
  ]
  if (header.subject !== '') {
    lines.push(`<div><strong>Subject:</strong> ${escapeHtml(header.subject)}</div>`)
  }
  if (header.to !== '') {
    lines.push(`<div><strong>To:</strong> ${escapeHtml(header.to)}</div>`)
  }
  return (
    "<div style=\"font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; " +
    'padding: 10px 0; margin: 20px 0; border-left: 2px solid #ccc; padding-left: 10px; color: #555;">' +
    `\n${lines.join('\n')}\n</div>\n` +
    '<hr style="border: none; border-top: 1px solid #ccc; margin: 10px 0;">'
  )
}

export interface ForwardHtmlInput {
  /** The user's typed note (plain text); '' when they added none. */
  userNote: string
  header: ForwardHeaderFields
  /**
   * The original body, ALREADY through features/reader/sanitizeEmailHtml and
   * reduced to a body fragment. Never raw remote HTML: this string is
   * interpolated into the outgoing message verbatim.
   */
  sanitizedContentHtml: string
}

/**
 * The html part of a forward: the user's note, then the forward header, then
 * the sanitized original (buildFinalHTMLForForward + buildHTMLForward, which
 * insert both after the `<body>` tag of the original document).
 */
export function buildForwardHtmlBody(input: ForwardHtmlInput): string {
  const note = input.userNote.trim()
  const notePart =
    note === '' ? '' : `${plainTextToHtml(note)}\n<div style="margin-bottom: 20px;"></div>\n`
  return (
    '<!DOCTYPE html>\n<html>\n<head><meta charset="UTF-8"></head>\n<body>\n' +
    `${notePart}${buildForwardHeaderHtml(input.header)}\n${input.sanitizedContentHtml}\n` +
    '</body>\n</html>'
  )
}
