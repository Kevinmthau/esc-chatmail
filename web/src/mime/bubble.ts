// Chat-bubble text processing pipeline.
// Ports ChatBubbleTextProcessor and the ProcessedTextCache HTML→plain-text
// helpers (removeConsecutivePlainTextQuoteLines, residual quote markers,
// header quote blocks).

import { decodeHtmlEntities } from './decode'
import { extractPlainTextFromHtml } from './htmlText'
import {
  EMAIL_ADDRESS_PATTERN,
  FROM_HEADER_PREFIXES,
  SENT_OR_DATE_HEADER_PREFIXES,
  TO_HEADER_PREFIXES,
} from './patterns'
import { extractDisplayText } from './rawSource'
import { cleanedHtmlForProcessing, hasGenuineRichContent } from './richContent'
import {
  extractQuotes,
  formatSignOffLineBreaks,
  unwrapEmailLineBreaks,
  type QuotedPart,
} from './text'

export type BubbleInputKind = 'html' | 'plainText' | 'autoDetectHTML'

export interface BubbleOptions {
  inputKind: BubbleInputKind
  sanitizeRawEmailSource?: boolean
  decodeHTMLEntities?: boolean
  formatSignOffLineBreaks?: boolean
  classifyRichContent?: boolean
}

export interface BubbleResult {
  mainText: string | null
  quotedParts: QuotedPart[]
  hasRichContent: boolean
}

// Detects genuine HTML tags while avoiding false positives like `5 < 10 > 3`.
const HTML_TAG_PATTERN =
  /<[a-zA-Z][a-zA-Z0-9]*(?:\s[^>]*)?>|<\/[a-zA-Z][a-zA-Z0-9]*>|<[a-zA-Z][a-zA-Z0-9]*(?:\s[^>\n]*)?$/

export function containsHtmlTags(text: string): boolean {
  return HTML_TAG_PATTERN.test(text)
}

/** Master entry point mirroring ChatBubbleTextProcessor.process. */
export function processChatBubbleText(
  content: string | null | undefined,
  options: BubbleOptions,
): BubbleResult {
  if (content === null || content === undefined || content.length === 0) {
    return { mainText: null, quotedParts: [], hasRichContent: false }
  }

  const requestedKind = options.inputKind
  const inputKind: BubbleInputKind =
    requestedKind === 'autoDetectHTML'
      ? containsHtmlTags(content)
        ? 'html'
        : 'plainText'
      : requestedKind

  if (inputKind === 'html') {
    return processHtml(
      content,
      options.decodeHTMLEntities ?? true,
      options.formatSignOffLineBreaks ?? true,
      options.classifyRichContent ?? false,
    )
  }

  return processPlainText(
    content,
    options.sanitizeRawEmailSource ?? true,
    options.decodeHTMLEntities ?? true,
    options.formatSignOffLineBreaks ?? true,
  )
}

export function htmlCompatibilityFallback(
  html: string | null | undefined,
  classifyRichContent: boolean,
): BubbleResult {
  return processChatBubbleText(html, {
    inputKind: 'html',
    sanitizeRawEmailSource: false,
    decodeHTMLEntities: true,
    formatSignOffLineBreaks: true,
    classifyRichContent,
  })
}

export function plainTextOnlyFallback(
  text: string | null | undefined,
  sanitizeRawEmailSource = true,
  decodeHTMLEntitiesOption = true,
): BubbleResult {
  return processChatBubbleText(text, {
    inputKind: 'plainText',
    sanitizeRawEmailSource,
    decodeHTMLEntities: decodeHTMLEntitiesOption,
    formatSignOffLineBreaks: true,
    classifyRichContent: false,
  })
}

export function legacyAutoDetectedFallback(
  text: string | null | undefined,
  sanitizeRawEmailSource: boolean,
  classifyRichContent: boolean,
): BubbleResult {
  return processChatBubbleText(text, {
    inputKind: 'autoDetectHTML',
    sanitizeRawEmailSource,
    decodeHTMLEntities: true,
    formatSignOffLineBreaks: true,
    classifyRichContent,
  })
}

function processHtml(
  html: string,
  decodeEntities: boolean,
  formatSignOffs: boolean,
  classifyRichContent: boolean,
): BubbleResult {
  const cleanup = cleanedHtmlForProcessing(html)

  let plainText = extractPlainTextFromHtmlForBubble(
    cleanup.html,
    decodeEntities,
    formatSignOffs,
    cleanup.applyPlainTextQuoteRemoval,
  )

  if (plainText === null) {
    plainText = extractPlainTextFromHtmlForBubble(html, decodeEntities, formatSignOffs, true)
  }

  const hasRichContent = classifyRichContent ? hasGenuineRichContent(cleanup.html) : false
  return {
    mainText: plainText,
    quotedParts: [],
    hasRichContent,
  }
}

function processPlainText(
  text: string,
  sanitizeRawEmailSource: boolean,
  decodeEntities: boolean,
  formatSignOffs: boolean,
): BubbleResult {
  let processed = text
  if (sanitizeRawEmailSource) {
    processed = extractDisplayText(processed)
  }

  if (decodeEntities) {
    processed = decodeHtmlEntities(processed)
  }

  const unwrapped = unwrapEmailLineBreaks(processed)
  const extractionResult = extractQuotes(unwrapped)
  const mainContent = formatSignOffs
    ? formatSignOffLineBreaks(extractionResult.mainContent)
    : extractionResult.mainContent
  const trimmed = mainContent.trim()

  return {
    mainText: trimmed.length === 0 ? null : trimmed,
    quotedParts: extractionResult.quotedParts,
    hasRichContent: false,
  }
}

// MARK: - HTML → bubble text (ProcessedTextCache.extractPlainTextFromHTML)

function extractPlainTextFromHtmlForBubble(
  html: string,
  decodeEntities: boolean,
  formatSignOffs: boolean,
  applyPlainTextQuoteRemoval: boolean,
): string | null {
  const extracted = extractPlainTextFromHtml(html)
  if (extracted.length === 0) return null

  const decoded = decodeEntities ? decodeHtmlEntities(extracted) : extracted
  const textBeforeUnwrap = applyPlainTextQuoteRemoval
    ? decoded
    : removeConsecutivePlainTextQuoteLines(decoded)
  const unwrapped = unwrapEmailLineBreaks(textBeforeUnwrap)
  let quoteRemoved: string
  if (applyPlainTextQuoteRemoval) {
    quoteRemoved = extractQuotes(unwrapped).mainContent
  } else {
    const headerRemoved = removePlainTextHeaderQuoteBlocks(unwrapped)
    quoteRemoved = removeResidualHtmlTextQuoteMarkers(headerRemoved)
  }
  const formatted = formatSignOffs ? formatSignOffLineBreaks(quoteRemoved) : quoteRemoved
  const trimmed = formatted.trim()
  return trimmed.length === 0 ? null : trimmed
}

function removeConsecutivePlainTextQuoteLines(text: string): string {
  const lines = text.split('\n')
  if (lines.length <= 1) return text

  let consecutiveQuoteLineCount = 0
  for (let index = 0; index < lines.length; index++) {
    const trimmed = lines[index]!.trim()
    if (trimmed.startsWith('>')) {
      consecutiveQuoteLineCount += 1
      if (consecutiveQuoteLineCount >= 2) {
        let firstQuoteLineIndex = index - consecutiveQuoteLineCount + 1
        if (firstQuoteLineIndex > 0) {
          const precedingLine = lines[firstQuoteLineIndex - 1]!.trim()
          if (isHtmlTextQuoteAttributionLine(precedingLine)) {
            firstQuoteLineIndex -= 1
          }
        }
        return lines.slice(0, firstQuoteLineIndex).join('\n')
      }
    } else {
      consecutiveQuoteLineCount = 0
    }
  }

  return text
}

function isHtmlTextQuoteAttributionLine(text: string): boolean {
  const lowercased = text.toLowerCase()
  const attributionSuffixes = [
    'wrote:',
    'schrieb:',
    'a écrit :',
    'a écrit:',
    'escribió:',
    'ha scritto:',
    'escreveu:',
    'schreef:',
  ]
  return attributionSuffixes.some((suffix) => lowercased.endsWith(suffix))
}

const RESIDUAL_HTML_TEXT_QUOTE_MARKER_PATTERNS: RegExp[] = [
  /(?:^|\n)\s*begin forwarded message:\s*/im,
  /(?:^|\n)\s*-{2,}\s*forwarded message\b[^\n]*/im,
  /\s-{2,}\s*forwarded message\b[^\n]*/im,
  /(?:^|\n)\s*-{2,}\s*original message\s*-{2,}[^\n]*/im,
  /(?:^|\n)\s*Am .{1,200}? schrieb .{1,120}\s*:\s*/im,
  /(?:^|\n)\s*Le .{1,200}? a écrit\s*:\s*/im,
  /(?:^|\n)\s*El .{1,200}? escribió\s*:\s*/im,
  /(?:^|\n)\s*Il .{1,200}? ha scritto\s*:\s*/im,
  /(?:^|\n)\s*Em .{1,200}? escreveu\s*:\s*/im,
  /(?:^|\n)\s*Op .{1,200}? schreef .{1,120}\s*:\s*/im,
]

function removeResidualHtmlTextQuoteMarkers(text: string): string {
  let earliest: { index: number; length: number } | null = null
  for (const pattern of RESIDUAL_HTML_TEXT_QUOTE_MARKER_PATTERNS) {
    const match = pattern.exec(text)
    if (!match) continue
    const candidate = { index: match.index, length: match[0].length }
    if (
      earliest === null ||
      candidate.index < earliest.index ||
      (candidate.index === earliest.index && candidate.length < earliest.length)
    ) {
      earliest = candidate
    }
  }

  if (earliest === null) return text
  return text.slice(0, earliest.index)
}

function removePlainTextHeaderQuoteBlocks(text: string): string {
  const lines = text.split('\n')
  if (lines.length <= 1) return text

  const lineStartOffsets: number[] = []
  let runningOffset = 0
  for (let index = 0; index < lines.length; index++) {
    lineStartOffsets.push(runningOffset)
    runningOffset += lines[index]!.length
    if (index < lines.length - 1) {
      runningOffset += 1
    }
  }

  for (let index = 0; index < lines.length; index++) {
    const trimmed = lines[index]!.trim()
    if (trimmed.length === 0) continue

    const lowercased = trimmed.toLowerCase()
    if (!FROM_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      continue
    }

    if (index === 0 || lines[index - 1]!.trim().length > 0) {
      continue
    }

    let sawTo = false
    let sawSentOrDate = false
    let sawEmailAddress = containsHtmlTextEmailAddress(trimmed)
    const upperBound = Math.min(lines.length, index + 24)

    if (index + 1 < upperBound) {
      for (let candidateIndex = index + 1; candidateIndex < upperBound; candidateIndex++) {
        const candidate = lines[candidateIndex]!.trim()
        if (candidate.length === 0) continue

        const candidateLower = candidate.toLowerCase()
        if (TO_HEADER_PREFIXES.some((prefix) => candidateLower.startsWith(prefix))) {
          sawTo = true
        }
        if (SENT_OR_DATE_HEADER_PREFIXES.some((prefix) => candidateLower.startsWith(prefix))) {
          sawSentOrDate = true
        }
        if (containsHtmlTextEmailAddress(candidate)) {
          sawEmailAddress = true
        }

        if (sawTo && sawSentOrDate && sawEmailAddress) {
          return text.slice(0, lineStartOffsets[index])
        }
      }
    }
  }

  return text
}

function containsHtmlTextEmailAddress(text: string): boolean {
  return EMAIL_ADDRESS_PATTERN.test(text)
}
