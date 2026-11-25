// The one walk of a Gmail message's MIME tree that decides its body.
// Port of MIMEBodyExtractor (esc-chatmail/Services/Sync/MIMEBodyExtractor.swift),
// rule for rule; see its header for the reasoning.
//
// The walk keeps, for each kind, the first leaf in tree order that is not
// blank. The one addition: inside a multipart/mixed, a text leaf directly
// after a part with an `inline` disposition that is a file is joined to the
// leaf of its kind the same multipart/mixed gave the body (iPhone Mail sends a
// photo placed mid-message as multipart/mixed [text, photo, text]). Plain text
// joins after a blank line, HTML as the content of its <body> before the first
// fragment's </body>. A blank fragment, or HTML with nothing visible, is left
// out, and nothing stands in for the file. The join is bounded, and a
// continuation past either bound is not fetched; the count bound counts every
// continuation read, joined or not.

import type { GmailPart } from '../gmail/types'
import { isAttachmentPart } from './attachments'
import { hasMeaningfulContent } from './richContent'

export type BodyKind = 'html' | 'plainText'

export interface MimeBody {
  html: string | null
  plainText: string | null
}

/** Continuations read for a body of one kind, at most, joined or not. */
export const MAXIMUM_CONTINUATIONS_PER_KIND = 15

/** UTF-8 bytes of continuation read for a body of one kind, at most, joined or not. */
export const MAXIMUM_CONTINUATION_UTF8_BYTES = 2 * 1024 * 1024

interface ContinuationBudget {
  readCount: Record<BodyKind, number>
  readBytes: Record<BodyKind, number>
}

function remainingBytes(budget: ContinuationBudget, kind: BodyKind): number {
  return MAXIMUM_CONTINUATION_UTF8_BYTES - budget.readBytes[kind]
}

function admitsAnother(budget: ContinuationBudget, kind: BodyKind): boolean {
  return budget.readCount[kind] < MAXIMUM_CONTINUATIONS_PER_KIND && remainingBytes(budget, kind) > 0
}

const ALL_KINDS: readonly BodyKind[] = ['html', 'plainText']

/**
 * Walks `part` for the kinds asked for. `decodedBody` is the caller's, with
 * the caller's failure policy, and is called once for each leaf the body may
 * take, in tree order, and never for a file.
 */
export async function extractMimeBody(
  part: GmailPart,
  decodedBody: (part: GmailPart) => Promise<string | null>,
  kinds: readonly BodyKind[] = ALL_KINDS,
): Promise<MimeBody> {
  const budget: ContinuationBudget = {
    readCount: { html: 0, plainText: 0 },
    readBytes: { html: 0, plainText: 0 },
  }
  return walk(part, kinds, budget, decodedBody)
}

async function walk(
  part: GmailPart,
  kinds: readonly BodyKind[],
  budget: ContinuationBudget,
  decodedBody: (part: GmailPart) => Promise<string | null>,
): Promise<MimeBody> {
  if (isAttachmentPart(part)) {
    return { html: null, plainText: null }
  }

  const mimeType = resolvedMimeType(part)
  const leafKind = kindOfLeafMimeType(mimeType)
  if (leafKind !== null) {
    const body: MimeBody = { html: null, plainText: null }
    if (kinds.includes(leafKind)) {
      body[leafKind] = nonBlank(await decodedBody(part))
    }
    return body
  }

  const parts = part.parts
  if (parts === undefined || parts.length === 0) {
    return { html: null, plainText: null }
  }

  const joinsContinuations = isMultipartMixed(mimeType)
  const body: MimeBody = { html: null, plainText: null }
  const kindsFromOwnLeaves = new Set<BodyKind>()
  let followsInlineFile = false

  for (const child of parts) {
    const childLeafKind = bodyLeafKind(child)
    const base = childLeafKind === null ? null : body[childLeafKind]
    if (
      joinsContinuations &&
      followsInlineFile &&
      childLeafKind !== null &&
      kinds.includes(childLeafKind) &&
      kindsFromOwnLeaves.has(childLeafKind) &&
      base !== null
    ) {
      body[childLeafKind] = await joiningContinuation(
        child,
        childLeafKind,
        base,
        budget,
        decodedBody,
      )
    } else {
      // Once every kind asked for has a body, only a continuation can still
      // change it, and nothing else is walked or fetched. A child is asked
      // only for the kinds still missing, so no fetch is spent on a body that
      // would be dropped and sync joins what recovery (HTML only) joins.
      const missingKinds = kinds.filter((kind) => body[kind] === null)
      if (missingKinds.length > 0) {
        const childBody = await walk(child, missingKinds, budget, decodedBody)
        for (const kind of missingKinds) {
          const value = childBody[kind]
          if (value === null) continue
          body[kind] = value
          if (childLeafKind === kind) {
            kindsFromOwnLeaves.add(kind)
          }
        }
      }
    }
    followsInlineFile = isInlineFilePart(child)
  }

  return body
}

async function joiningContinuation(
  part: GmailPart,
  kind: BodyKind,
  base: string,
  budget: ContinuationBudget,
  decodedBody: (part: GmailPart) => Promise<string | null>,
): Promise<string> {
  if (!admitsAnother(budget, kind)) return base
  const remaining = remainingBytes(budget, kind)
  const declaredSize = part.body?.size
  if (declaredSize !== undefined && declaredSize > remaining) return base

  budget.readCount[kind] += 1
  const fragment = nonBlank(await decodedBody(part))
  if (fragment === null) return base
  const fragmentBytes = utf8Length(fragment)
  if (fragmentBytes > remaining) return base
  // Counted once read, joined or not: a refused fragment was still fetched
  // and checked by hasMeaningfulContent, whose regexes are quadratic in it.
  budget.readBytes[kind] += fragmentBytes

  let joined: string
  if (kind === 'plainText') {
    joined = joinedPlainText(base, fragment)
  } else {
    if (!hasMeaningfulContent(fragment)) return base
    joined = joinedHtml(base, fragment)
  }
  return joined
}

function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length
}

// MARK: - Joining

function isLineBreak(code: number): boolean {
  return code === 0x0d || code === 0x0a
}

/**
 * `base`, a blank line, then `fragment`, with the seam made one blank line.
 * The breaks are taken off by a scan from each end, never a regular
 * expression: `/[\r\n]+$/` backtracks through every run of line breaks the
 * sender's text holds (80,000 took 3.6 s in V8).
 */
export function joinedPlainText(base: string, fragment: string): string {
  let end = base.length
  while (end > 0 && isLineBreak(base.charCodeAt(end - 1))) end--
  let start = 0
  while (start < fragment.length && isLineBreak(fragment.charCodeAt(start))) start++
  return base.slice(0, end) + '\n\n' + fragment.slice(start)
}

/**
 * `base` with the content of `fragment`'s <body> put before `base`'s last
 * `</body` (else its last `</html`, else its end). A fragment with no <body>
 * tag is put whole. Tag names match in ASCII case only and the text is cut
 * only at ASCII characters, so the result is the Swift port's, which works on
 * UTF-8 bytes.
 */
export function joinedHtml(base: string, fragment: string): string {
  let content = fragment
  const bodyStart = endOfOpeningBodyTag(fragment)
  if (bodyStart !== null) {
    const end =
      lastOffset('</body', fragment, bodyStart) ??
      lastOffset('</html', fragment, bodyStart) ??
      fragment.length
    content = fragment.slice(bodyStart, end)
  }

  const insertion = lastOffset('</body', base, 0) ?? lastOffset('</html', base, 0) ?? base.length
  return base.slice(0, insertion) + content + base.slice(insertion)
}

function isHtmlWhitespace(code: number): boolean {
  return code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d
}

/**
 * The offset just past the `>` of the first `<body` start tag, or null when
 * there is none or it never ends. A `>` inside a quoted attribute value (a
 * quote right after `=`) does not end the tag.
 */
function endOfOpeningBodyTag(text: string): number | null {
  let start = 0
  for (;;) {
    const tagStart = firstOffset('<body', text, start)
    if (tagStart === null) return null
    const afterName = tagStart + '<body'.length
    if (afterName >= text.length) return null
    const next = text.charCodeAt(afterName)
    if (!(isHtmlWhitespace(next) || next === 0x2f || next === 0x3e)) {
      start = tagStart + 1
      continue
    }

    let quote: number | null = null
    let followsEquals = false
    for (let index = afterName; index < text.length; index++) {
      const code = text.charCodeAt(index)
      if (quote !== null) {
        if (code === quote) quote = null
      } else if (code === 0x3e) {
        return index + 1
      } else if (code === 0x3d) {
        followsEquals = true
      } else if ((code === 0x22 || code === 0x27) && followsEquals) {
        quote = code
        followsEquals = false
      } else if (!isHtmlWhitespace(code)) {
        followsEquals = false
      }
    }
    return null
  }
}

/** `pattern` is lowercase ASCII. */
function matchesAsciiCaseInsensitive(pattern: string, text: string, offset: number): boolean {
  for (let index = 0; index < pattern.length; index++) {
    let code = text.charCodeAt(offset + index)
    if (code >= 0x41 && code <= 0x5a) code += 0x20
    if (code !== pattern.charCodeAt(index)) return false
  }
  return true
}

function firstOffset(pattern: string, text: string, start: number): number | null {
  for (let index = start; index <= text.length - pattern.length; index++) {
    if (matchesAsciiCaseInsensitive(pattern, text, index)) return index
  }
  return null
}

function lastOffset(pattern: string, text: string, start: number): number | null {
  for (let index = text.length - pattern.length; index >= start; index--) {
    if (matchesAsciiCaseInsensitive(pattern, text, index)) return index
  }
  return null
}

// MARK: - Classifying parts

function headerValueOf(part: GmailPart, name: string): string | null {
  const header = part.headers?.find((h) => h.name.toLowerCase() === name)
  return header ? header.value : null
}

/** The part's MIME type, else its Content-Type header's value. */
export function resolvedMimeType(part: GmailPart): string | null {
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

function normalizedMimeType(mimeType: string | null): string | null {
  if (mimeType === null) return null
  const normalized = mimeType.trim().toLowerCase()
  return normalized.length > 0 ? normalized : null
}

export function isHtmlMimeType(mimeType: string | null): boolean {
  return normalizedMimeType(mimeType)?.startsWith('text/html') === true
}

export function isPlainTextMimeType(mimeType: string | null): boolean {
  return normalizedMimeType(mimeType)?.startsWith('text/plain') === true
}

function isMultipartMixed(mimeType: string | null): boolean {
  return normalizedMimeType(mimeType)?.startsWith('multipart/mixed') === true
}

function kindOfLeafMimeType(mimeType: string | null): BodyKind | null {
  if (isHtmlMimeType(mimeType)) return 'html'
  if (isPlainTextMimeType(mimeType)) return 'plainText'
  return null
}

/** The kind of body `part` is, when it is a text leaf the walk reads. */
function bodyLeafKind(part: GmailPart): BodyKind | null {
  if ((part.parts?.length ?? 0) > 0 || isAttachmentPart(part)) return null
  return kindOfLeafMimeType(resolvedMimeType(part))
}

/**
 * Something a mail client placed in the text: a leaf whose disposition type
 * is `inline` and that is not itself a body leaf.
 */
function isInlineFilePart(part: GmailPart): boolean {
  if ((part.parts?.length ?? 0) > 0) return false
  if (normalizedMimeType(resolvedMimeType(part))?.startsWith('multipart/') === true) return false
  if (bodyLeafKind(part) !== null) return false
  const disposition = (headerValueOf(part, 'content-disposition') ?? '').toLowerCase()
  const dispositionType = disposition.split(';', 1)[0]?.trim() ?? ''
  return dispositionType === 'inline'
}

function nonBlank(value: string | null): string | null {
  if (value === null) return null
  return value.trim().length === 0 ? null : value
}
