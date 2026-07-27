// Extracts displayable message content from raw email source blobs
// (transport headers + MIME boundaries that should never reach chat bubbles).
// Port of esc-chatmail/Services/TextProcessing/RawEmailSourceSanitizer.swift.

import { base64DecodeText, decodeQuotedPrintable } from './decode'
import { MIME_BOUNDARY_PATTERN, MIME_HEADER_PREFIXES } from './patterns'
import { normalizeLineEndings } from './text'

const MINIMUM_HEADER_LINES_FOR_RAW_SOURCE = 5

const TRANSPORT_MARKERS: string[] = [
  'delivered-to:',
  'return-path:',
  '\nreceived:',
  'x-received:',
  'arc-seal:',
  'arc-authentication-results:',
  'authentication-results:',
  'dkim-signature:',
  'x-google-dkim-signature:',
]

/** Outcome of attempting to pull an HTML part out of a raw email blob. */
export type RawHtmlExtraction =
  { kind: 'notRawSource' } | { kind: 'rawSourceWithoutHTML' } | { kind: 'html'; html: string }

/**
 * Returns displayable text: raw RFC822 blobs are reduced to their plain-text
 * part (or scaffolding-stripped body); anything else passes through with
 * normalized line endings.
 */
export function extractDisplayText(text: string): string {
  const normalized = normalizeLineEndings(text)
  if (!looksLikeRawEmailSource(normalized)) return normalized

  const withoutTransportHeaders = stripLeadingTransportHeaders(normalized)

  const plainPart = extractPlainTextPart(withoutTransportHeaders)
  if (plainPart !== null && plainPart.length > 0) {
    return plainPart
  }

  return stripMimeScaffolding(withoutTransportHeaders)
}

export function extractHtmlResult(text: string): RawHtmlExtraction {
  const normalized = normalizeLineEndings(text)
  if (!looksLikeRawEmailSource(normalized)) return { kind: 'notRawSource' }

  const withoutTransportHeaders = stripLeadingTransportHeaders(normalized)
  const htmlPart = extractPartBody(
    withoutTransportHeaders,
    (lower) => lower.startsWith('content-type:') && lower.includes('text/html'),
    false,
  )
  if (htmlPart === null) {
    return { kind: 'rawSourceWithoutHTML' }
  }

  const trimmed = htmlPart.trim()
  return trimmed.length === 0 ? { kind: 'rawSourceWithoutHTML' } : { kind: 'html', html: trimmed }
}

/** Embedded-HTML rescue: recovers the text/html part from a raw source blob. */
export function extractHtmlFromRawSource(text: string): string | null {
  const result = extractHtmlResult(text)
  return result.kind === 'html' ? result.html : null
}

function looksLikeRawEmailSource(text: string): boolean {
  const lines = text.split('\n')
  const topHeaderCount = countLeadingHeaderLines(lines)
  const lower = text.toLowerCase()
  const hasMultipartContentType = lower.includes('content-type: multipart/')
  if (hasMultipartContentType && topHeaderCount >= 1 && extractBoundary(text) !== null) {
    return true
  }

  if (topHeaderCount < MINIMUM_HEADER_LINES_FOR_RAW_SOURCE) return false

  return TRANSPORT_MARKERS.some((marker) => lower.includes(marker))
}

function countLeadingHeaderLines(lines: string[]): number {
  let count = 0

  for (const line of lines.slice(0, 80)) {
    if (line.length === 0) {
      break
    }

    if (isHeaderLine(line) || line.startsWith(' ') || line.startsWith('\t')) {
      if (isHeaderLine(line)) {
        count += 1
      }
      continue
    }

    break
  }

  return count
}

function stripLeadingTransportHeaders(text: string): string {
  const lines = text.split('\n')
  let headerCount = 0
  let index = 0

  while (index < lines.length) {
    const line = lines[index]!

    if (line.length === 0) {
      if (headerCount >= MINIMUM_HEADER_LINES_FOR_RAW_SOURCE) {
        const bodyStart = index + 1
        if (bodyStart >= lines.length) return ''
        return lines.slice(bodyStart).join('\n')
      }
      return text
    }

    if (isHeaderLine(line)) {
      headerCount += 1
      index += 1
      continue
    }

    if (line.startsWith(' ') || line.startsWith('\t')) {
      index += 1
      continue
    }

    return text
  }

  return text
}

function extractPlainTextPart(text: string): string | null {
  return extractPartBody(
    text,
    (lower) => lower.startsWith('content-type:') && lower.includes('text/plain'),
    true,
  )
}

function extractPartBody(
  text: string,
  matchingContentType: (lower: string) => boolean,
  stripScaffoldingAfterDecode: boolean,
): string | null {
  const lines = text.split('\n')
  const boundary = extractBoundary(text)
  const knownBoundaries = extractKnownBoundaries(text)

  let index = 0
  while (index < lines.length) {
    const line = lines[index]!
    const trimmed = line.trim()

    if (
      line.length === 0 ||
      isAnyBoundaryLine(trimmed, boundary, knownBoundaries) ||
      !isHeaderLine(line)
    ) {
      index += 1
      continue
    }

    let partHeaders: string[] = []
    let bodyStart = index

    while (bodyStart < lines.length) {
      const headerLine = lines[bodyStart]!
      if (headerLine.length === 0) {
        bodyStart += 1
        break
      }

      if (headerLine.startsWith(' ') || headerLine.startsWith('\t') || isHeaderLine(headerLine)) {
        partHeaders.push(headerLine)
        bodyStart += 1
        continue
      }

      partHeaders = []
      break
    }

    const unfolded = unfoldedHeaderLines(partHeaders).map((h) => h.toLowerCase())
    if (partHeaders.length === 0 || !unfolded.some(matchingContentType)) {
      index = Math.max(bodyStart, index + 1)
      continue
    }

    const bodyLines: string[] = []
    let cursor = bodyStart

    while (cursor < lines.length) {
      const bodyLine = lines[cursor]!
      if (isAnyBoundaryLine(bodyLine, boundary, knownBoundaries)) {
        break
      }
      bodyLines.push(bodyLine)
      cursor += 1
    }

    let body = bodyLines.join('\n')
    body = decodePartBodyIfNeeded(body, partHeaders)
    if (stripScaffoldingAfterDecode || containsEmbeddedMimeScaffolding(body)) {
      body = stripMimeScaffolding(body)
    }
    body = body.trim()

    if (body.length > 0) {
      return body
    }

    index = cursor + 1
  }

  return null
}

function unfoldedHeaderLines(headers: string[]): string[] {
  const unfolded: string[] = []

  for (const header of headers) {
    if (header.startsWith(' ') || header.startsWith('\t')) {
      if (unfolded.length > 0) {
        unfolded[unfolded.length - 1] += ' ' + header.trim()
      } else {
        unfolded.push(header.trim())
      }
      continue
    }

    unfolded.push(header)
  }

  return unfolded
}

function containsEmbeddedMimeScaffolding(text: string): boolean {
  const lower = text.toLowerCase()
  return (
    lower.includes('\ncontent-type:') ||
    lower.includes('\ncontent-transfer-encoding:') ||
    lower.includes('\ncontent-disposition:') ||
    lower.includes('\n--')
  )
}

function decodePartBodyIfNeeded(body: string, headers: string[]): string {
  const lowerHeaders = headers.join('\n').toLowerCase()

  if (lowerHeaders.includes('quoted-printable')) {
    return decodeQuotedPrintable(body)
  }

  if (lowerHeaders.includes('base64')) {
    const decoded = base64DecodeText(body)
    if (decoded !== null) {
      return decoded
    }
  }

  return body
}

function stripMimeScaffolding(text: string): string {
  const lines = text.split('\n')
  const boundary = extractBoundary(text)
  const knownBoundaries = extractKnownBoundaries(text)

  const cleanedLines: string[] = []
  let skipContinuationLine = false

  for (const line of lines) {
    const trimmed = line.trim()
    const lower = trimmed.toLowerCase()

    if (skipContinuationLine) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        continue
      }
      skipContinuationLine = false
    }

    if (isAnyBoundaryLine(trimmed, boundary, knownBoundaries)) {
      continue
    }

    if (MIME_HEADER_PREFIXES.some((prefix) => lower.startsWith(prefix))) {
      skipContinuationLine = true
      continue
    }

    cleanedLines.push(line)
  }

  return cleanedLines.join('\n').trim()
}

function extractBoundary(text: string): string | null {
  const headerRegion = text.split('\n').slice(0, 120).join('\n')
  const match = MIME_BOUNDARY_PATTERN.exec(headerRegion)
  if (!match) return null

  if (match[1] !== undefined && match[1].length > 0) {
    return match[1]
  }
  if (match[2] !== undefined && match[2].length > 0) {
    return match[2]
  }
  return null
}

function extractKnownBoundaries(text: string): Set<string> {
  const lines = text.split('\n')
  const headerRegion = lines.slice(0, 240).join('\n')

  const boundaries = new Set<string>()
  const globalPattern = new RegExp(MIME_BOUNDARY_PATTERN.source, 'gi')
  let match: RegExpExecArray | null
  while ((match = globalPattern.exec(headerRegion)) !== null) {
    if (match[1] !== undefined && match[1].length > 0) {
      boundaries.add(match[1])
      continue
    }
    if (match[2] !== undefined && match[2].length > 0) {
      boundaries.add(match[2])
    }
  }

  // Fallback for raw-source blobs where top-level Content-Type headers were
  // stripped. Real MIME boundaries repeat multiple times.
  const boundaryCounts = new Map<string, number>()
  const scanLimit = Math.min(lines.length, 320)
  for (let index = 0; index < scanLimit; index++) {
    const trimmed = lines[index]!.trim()
    const token = boundaryToken(trimmed)
    if (token === null || !isLikelyFallbackBoundaryLine(index, lines, token)) {
      continue
    }
    boundaryCounts.set(token, (boundaryCounts.get(token) ?? 0) + 1)
  }

  for (const [token, count] of boundaryCounts) {
    if (count >= 2) {
      boundaries.add(token)
    }
  }

  return boundaries
}

function isBoundaryLine(line: string, boundary: string | null): boolean {
  if (!line.startsWith('--')) return false

  if (boundary !== null) {
    return line.startsWith(`--${boundary}`)
  }

  let token = line.slice(2)
  if (token.endsWith('--')) {
    token = token.slice(0, -2)
  }

  if (token.length < 12) return false

  return [...token].every(isValidBoundaryCharacter)
}

function boundaryToken(line: string): string | null {
  if (!line.startsWith('--')) return null

  let token = line.slice(2)
  if (token.endsWith('--')) {
    token = token.slice(0, -2)
  }

  if (token.length < 6) return null
  if (![...token].every(isValidFallbackBoundaryCharacter)) {
    return null
  }

  return token
}

function isLikelyFallbackBoundaryLine(index: number, lines: string[], token: string): boolean {
  const trimmed = lines[index]!.trim()
  if (trimmed === `--${token}--`) {
    return true
  }

  let cursor = index + 1
  while (cursor < lines.length) {
    const nextLine = lines[cursor]!
    if (nextLine.length === 0) {
      cursor += 1
      continue
    }

    return isHeaderLine(nextLine)
  }

  return false
}

function isValidFallbackBoundaryCharacter(character: string): boolean {
  return /[\p{L}\p{N}]/u.test(character) || '()+_-./:=?'.includes(character)
}

function isValidBoundaryCharacter(character: string): boolean {
  return /[\p{L}\p{N}]/u.test(character) || "'()+_,-./:=?".includes(character)
}

function isAnyBoundaryLine(
  line: string,
  preferredBoundary: string | null,
  knownBoundaries: Set<string>,
): boolean {
  if (preferredBoundary !== null && isBoundaryLine(line, preferredBoundary)) {
    return true
  }

  for (const boundary of knownBoundaries) {
    if (boundary === preferredBoundary) continue
    if (isBoundaryLine(line, boundary)) {
      return true
    }
  }

  return false
}

function isHeaderLine(line: string): boolean {
  const trimmed = line.trim()
  const separator = trimmed.indexOf(':')
  if (separator <= 0) {
    return false
  }

  const fieldName = trimmed.slice(0, separator)
  return [...fieldName].every((character) => /[\p{L}\p{N}-]/u.test(character))
}
