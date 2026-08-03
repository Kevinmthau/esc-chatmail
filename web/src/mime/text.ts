// Plain-text pipeline: line-ending normalization, email line unwrapping,
// sign-off formatting, and quote extraction.
// Ports: TextProcessing.swift (normalizeLineEndings / isListItem /
// unwrapEmailLineBreaks / formatSignOffLineBreaks) and
// PlainTextQuoteRemover.swift.

import { SIGNATURE_DELIMITER_PATTERN, isUppercaseChar } from './patterns'
import { removeSignature } from './signature'

export interface QuotedPart {
  text: string
  attribution: string | null
  nestingLevel: number
}

export interface QuoteExtractionResult {
  mainContent: string
  quotedParts: QuotedPart[]
}

/** Canonical CRLF/CR → LF normalization for the text-processing pipeline. */
export function normalizeLineEndings(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
}

const LIST_ITEM_PATTERN = /^(\d{1,3}[.)]|[a-zA-Z][.)]|[-*•·]|\([a-zA-Z0-9]{1,3}\))\s/

/** Checks if a line starts with a list item marker. */
export function isListItem(line: string): boolean {
  return LIST_ITEM_PATTERN.test(line.slice(0, 10))
}

export const SIGN_OFF_WORDS = [
  'regards',
  'thanks',
  'thank you',
  'best',
  'cheers',
  'sincerely',
  'yours truly',
  'best wishes',
  'kind regards',
  'warm regards',
  'take care',
  'all the best',
] as const

function trimPunctuation(text: string): string {
  return text.replace(/^\p{P}+/u, '').replace(/\p{P}+$/u, '')
}

function isStandaloneSignOffLine(line: string): boolean {
  const normalized = trimPunctuation(line.toLowerCase().trim())
  return (SIGN_OFF_WORDS as readonly string[]).includes(normalized)
}

export function looksLikeNameLine(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0 || trimmed.length > 40) return false
  if (!/\p{L}/u.test(trimmed)) return false
  if (/\p{Nd}/u.test(trimmed)) return false

  const lowercased = trimmed.toLowerCase()
  const disallowedFragments = [
    '@',
    'http',
    'www.',
    '|',
    'tel:',
    'fax',
    'mobile',
    'office',
    'cell',
    'phone',
  ]
  if (disallowedFragments.some((fragment) => lowercased.includes(fragment))) return false

  const words = trimmed.split(/\s+/).filter((w) => w.length > 0)
  return words.length >= 1 && words.length <= 4
}

function isSignatureDelimiterLine(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed.length === 0) return false
  return SIGNATURE_DELIMITER_PATTERN.test(trimmed)
}

function shouldPreserveLineBreakBetween(currentParagraph: string, nextLine: string): boolean {
  const parts = currentParagraph.split('\n')
  const currentLine = parts[parts.length - 1]?.trim() ?? ''
  return isStandaloneSignOffLine(currentLine) && looksLikeNameLine(nextLine)
}

const SPECIAL_WHITESPACE = /[\u00A0\u2002\u2003\u2009\u200A\u202F\u205F\u3000]/g

/**
 * Unwraps artificial email line breaks (72-80 char wrapping) while preserving
 * paragraph breaks.
 */
export function unwrapEmailLineBreaks(text: string): string {
  let normalizedText = normalizeLineEndings(text)
  normalizedText = normalizedText.replace(SPECIAL_WHITESPACE, ' ')

  const lines = normalizedText.split('\n')
  if (lines.length <= 1) return normalizedText

  const result: string[] = []
  let currentParagraph = ''
  let i = 0

  while (i < lines.length) {
    const trimmedLine = lines[i]!.trim()
    i += 1

    if (trimmedLine.length === 0) {
      if (currentParagraph.length === 0) {
        continue
      }

      // Look ahead to find the next non-empty line.
      let nextNonEmptyIndex = i
      while (nextNonEmptyIndex < lines.length && lines[nextNonEmptyIndex]!.trim().length === 0) {
        nextNonEmptyIndex += 1
      }

      if (nextNonEmptyIndex < lines.length) {
        const nextLine = lines[nextNonEmptyIndex]!.trim()
        const currentIsSignatureDelimiter = isSignatureDelimiterLine(currentParagraph)
        const nextIsSignatureDelimiter = isSignatureDelimiterLine(nextLine)
        const lastChar = currentParagraph.slice(-1)
        const firstChar = nextLine.slice(0, 1)

        const endsWithPunctuation = lastChar !== '' && '.!?'.includes(lastChar)
        const startsWithUppercase = firstChar !== '' && isUppercaseChar(firstChar)

        if (
          !endsWithPunctuation &&
          !startsWithUppercase &&
          !currentIsSignatureDelimiter &&
          !nextIsSignatureDelimiter
        ) {
          // Soft wrap across blank lines — skip the blanks and continue joining.
          continue
        }
      }

      // Real paragraph break.
      result.push(currentParagraph)
      result.push('')
      currentParagraph = ''
      continue
    }

    if (currentParagraph.length === 0) {
      currentParagraph = trimmedLine
    } else {
      if (shouldPreserveLineBreakBetween(currentParagraph, trimmedLine)) {
        currentParagraph += '\n' + trimmedLine
        continue
      }

      const lastChar = currentParagraph.slice(-1)
      const firstChar = trimmedLine.slice(0, 1)

      const endsWithPunctuation = lastChar !== '' && '.!?'.includes(lastChar)
      const startsWithUppercase = firstChar !== '' && isUppercaseChar(firstChar)
      const endsWithColon = lastChar === ':'
      const nextIsListItem = isListItem(trimmedLine)
      const currentIsSignatureDelimiter = isSignatureDelimiterLine(currentParagraph)
      const nextIsSignatureDelimiter = isSignatureDelimiterLine(trimmedLine)

      if (
        !endsWithPunctuation &&
        !endsWithColon &&
        !startsWithUppercase &&
        !nextIsListItem &&
        !currentIsSignatureDelimiter &&
        !nextIsSignatureDelimiter
      ) {
        currentParagraph += ' ' + trimmedLine
      } else {
        result.push(currentParagraph)
        currentParagraph = trimmedLine
      }
    }
  }

  if (currentParagraph.length > 0) {
    result.push(currentParagraph)
  }

  const paragraphs = result.filter((p) => p.length > 0)
  return paragraphs.join('\n\n').trim()
}

/**
 * Adds line breaks before sign-offs when they appear inline at the end of
 * text ("...for your help. Regards, Kevin" → "...help.\n\nRegards,\n\nKevin").
 */
export function formatSignOffLineBreaks(text: string): string {
  let result = text

  for (const signOff of SIGN_OFF_WORDS) {
    const patterns = [
      `([.!?])\\s+(${signOff})([!.])?,?\\s*$`,
      `([.!?])\\s+(${signOff}),\\s+([A-Z][a-z]+)\\s*$`,
      `([.!?])\\s+(${signOff}),\\s+([A-Z][a-z]+)\\s+([A-Z][a-z]+)\\s*$`,
    ]

    for (let patternIndex = 0; patternIndex < patterns.length; patternIndex++) {
      const regex = new RegExp(patterns[patternIndex]!, 'i')
      const match = regex.exec(result)
      if (!match) continue

      const punctuation = match[1]!
      const signOffText = match[2]!

      let trailingPunct: string
      if (patternIndex === 0 && match[3] !== undefined) {
        trailingPunct = match[3]
      } else {
        trailingPunct = ','
      }

      let replacement = `${punctuation}\n\n${signOffText}${trailingPunct}`
      if (patternIndex > 0 && match[3] !== undefined) {
        replacement += `\n\n${match[3]}`
        if (match[4] !== undefined) {
          replacement += ` ${match[4]}`
        }
      }

      result = result.replace(regex, () => replacement)
      break
    }
  }

  return result
}

// MARK: - Quote extraction (PlainTextQuoteRemover)

const QUOTE_INDICATOR_PATTERNS: RegExp[] = [
  // Time-based quotes - English
  /(?:^|\n)On .+ wrote:/i,
  /(?:^|\n)On .+, .+ wrote:/i,
  /> On .+, at .+, .+ wrote:/i,
  // iOS/Apple Mail format
  /On [A-Z][a-z]+ \d{1,2}, \d{4} at \d{1,2}:\d{2}\s*[AP]M,/i,

  // International quote patterns
  /Am .+ schrieb .+:/i,
  /Le .+ a écrit\s*:/i,
  /El .+ escribió:/i,
  /Il .+ ha scritto:/i,
  /Em .+ escreveu:/i,
  /Op .+ schreef .+:/i,

  // Header-based quotes
  /From: .+\nSent: .+\nTo: .+\nSubject: .+/i,
  /From: .+\nSent: .+\nTo: .+\nCc: .+\nSubject: .+/i,
  /From: .+\nDate: .+\nTo: .+\nSubject: .+/i,
  /From: .+\nDate: .+\nTo: .+\nCc: .+\nSubject: .+/i,
  /-----Original Message-----/i,
  /________________________________/i,

  // International header patterns
  /Von: .+\nGesendet: .+\nAn: .+\nBetreff: .+/i,
  /De\s*: .+\nEnvoyé\s*: .+\nÀ\s*: .+\nObjet\s*: .+/i,
  /De: .+\nEnviado: .+\nPara: .+\nAsunto: .+/i,

  // Forward indicators - English
  /Begin forwarded message:/i,
  /(?:^|\n)\s*-{2,}\s*Forwarded message\b.*/i,
  /\s-{2,}\s*Forwarded message\b.*/i,
  /---------- Forwarded message ---------/i,
  /------ Original Message ------/i,
  /(?:^|\n)\s*-{2,}\s*Original Message\b.*/i,

  // Forward indicators - International
  /Weitergeleitete Nachricht/i,
  /Message transféré/i,
  /Mensaje reenviado/i,
  /Messaggio inoltrato/i,
  /Mensagem encaminhada/i,
  /Doorgestuurd bericht/i,
]

const QUOTE_ATTRIBUTION_KEYWORDS = [
  'wrote:',
  'from:',
  'forwarded message',
  'schrieb:',
  'von:',
  'weitergeleitete nachricht',
  'a écrit',
  'de:',
  'message transféré',
  'escribió:',
  'mensaje reenviado',
  'ha scritto:',
  'messaggio inoltrato',
  'escreveu:',
  'mensagem encaminhada',
  'schreef:',
  'doorgestuurd bericht',
]

const HEADER_PREFIXES_LOWERCASED = [
  'from:',
  'sent:',
  'to:',
  'subject:',
  'date:',
  'cc:',
  'von:',
  'gesendet:',
  'an:',
  'betreff:',
  'datum:',
  'de:',
  'de :',
  'envoyé:',
  'envoyé :',
  'à:',
  'à :',
  'objet:',
  'objet :',
  'para:',
  'asunto:',
  'da:',
  'inviato:',
  'oggetto:',
  'assunto:',
  'van:',
  'verzonden:',
  'aan:',
  'onderwerp:',
]

const FORWARD_MARKERS_LOWERCASED = [
  '-----original message-----',
  'begin forwarded message',
  'forwarded message',
  '________________________________',
  'weitergeleitete nachricht',
  'message transféré',
  'mensaje reenviado',
  'messaggio inoltrato',
  'mensagem encaminhada',
  'doorgestuurd bericht',
]

const QUOTE_FROM_HEADER_PREFIXES = ['from:', 'von:', 'de:', 'de :', 'da:', 'van:']
const QUOTE_TO_HEADER_PREFIXES = ['to:', 'an:', 'à:', 'à :', 'para:', 'aan:']
const QUOTE_SENT_OR_DATE_HEADER_PREFIXES = [
  'sent:',
  'date:',
  'gesendet:',
  'datum:',
  'envoyé:',
  'envoyé :',
  'enviado:',
  'inviato:',
  'verzonden:',
]
const QUOTE_SUBJECT_HEADER_PREFIXES = [
  'subject:',
  'betreff:',
  'objet:',
  'objet :',
  'asunto:',
  'oggetto:',
  'assunto:',
  'onderwerp:',
]

/** Removes quoted text from plain text email content. */
export function removeQuotes(text: string | null | undefined): string | null {
  if (text === null || text === undefined) return null
  return extractQuotes(text).mainContent
}

/**
 * Extracts quotes from plain text email content, returning both the main
 * content and the quoted parts.
 */
export function extractQuotes(text: string, removingSignature = true): QuoteExtractionResult {
  let cleanText = text
  const quotedParts: QuotedPart[] = []
  let earliestQuoteIndex = cleanText.length
  let quoteAttribution: string | null = null

  const [patternIndex, attribution] = findEarliestPatternMatchWithAttribution(cleanText)
  if (patternIndex < earliestQuoteIndex) {
    earliestQuoteIndex = patternIndex
    quoteAttribution = attribution
  }

  const [consecutiveIndex, consecutiveAttribution] =
    findConsecutiveQuoteLinesWithAttribution(cleanText)
  if (consecutiveIndex < earliestQuoteIndex) {
    earliestQuoteIndex = consecutiveIndex
    quoteAttribution = consecutiveAttribution
  }

  const [headerBlockIndex, headerBlockAttribution] =
    findHeaderBlockQuoteBoundaryWithAttribution(cleanText)
  if (headerBlockIndex < earliestQuoteIndex) {
    earliestQuoteIndex = headerBlockIndex
    quoteAttribution = headerBlockAttribution
  }

  if (earliestQuoteIndex < cleanText.length) {
    const quotedText = cleanText.slice(earliestQuoteIndex).trim()

    const { cleanedText, maxNestingLevel } = cleanQuotedText(quotedText)
    if (cleanedText.length > 0) {
      quotedParts.push({
        text: cleanedText,
        attribution: quoteAttribution,
        nestingLevel: maxNestingLevel,
      })
    }

    cleanText = cleanText.slice(0, earliestQuoteIndex)
  }

  if (removingSignature) {
    cleanText = removeSignature(cleanText)
  }

  return { mainContent: cleanText.trim(), quotedParts }
}

function findEarliestPatternMatchWithAttribution(text: string): [number, string | null] {
  let earliestIndex = text.length
  let attribution: string | null = null

  for (const regex of QUOTE_INDICATOR_PATTERNS) {
    const match = regex.exec(text)
    if (match && match.index < earliestIndex) {
      earliestIndex = match.index
      const matchedText = match[0].trim()
      const lowercased = matchedText.toLowerCase()
      if (QUOTE_ATTRIBUTION_KEYWORDS.some((keyword) => lowercased.includes(keyword))) {
        attribution = matchedText
      }
    }
  }

  return [earliestIndex, attribution]
}

function cleanQuotedText(text: string): { cleanedText: string; maxNestingLevel: number } {
  const lines = text.split('\n')
  const cleanedLines: string[] = []
  let maxNestingLevel = 0

  for (const line of lines) {
    const { cleanedLine, nestingLevel } = stripQuoteMarkers(line)
    maxNestingLevel = Math.max(maxNestingLevel, nestingLevel)

    const trimmedLine = cleanedLine.trim()
    if (trimmedLine.length === 0) {
      cleanedLines.push(cleanedLine)
      continue
    }

    const lowercased = cleanedLine.toLowerCase()

    if (isQuoteAttributionLine(lowercased)) {
      continue
    }

    if (HEADER_PREFIXES_LOWERCASED.some((prefix) => lowercased.startsWith(prefix))) {
      continue
    }

    if (FORWARD_MARKERS_LOWERCASED.some((marker) => lowercased.includes(marker))) {
      continue
    }

    cleanedLines.push(cleanedLine)
  }

  const result = cleanedLines.join('\n').replace(/\n{3,}/g, '\n\n')
  return { cleanedText: result.trim(), maxNestingLevel }
}

function stripQuoteMarkers(line: string): { cleanedLine: string; nestingLevel: number } {
  let index = 0
  let nestingLevel = 0

  while (index < line.length) {
    const char = line[index]!
    if (char === '>') {
      nestingLevel += 1
      index += 1
      if (index < line.length && line[index] === ' ') {
        index += 1
      }
    } else if (char === ' ' || char === '\t') {
      index += 1
    } else {
      break
    }
  }

  return { cleanedLine: line.slice(index), nestingLevel }
}

const WROTE_PATTERNS = [
  'wrote:',
  'schrieb:',
  'a écrit',
  'escribió:',
  'ha scritto:',
  'escreveu:',
  'schreef:',
]

function isQuoteAttributionLine(lowercased: string): boolean {
  if (!WROTE_PATTERNS.some((pattern) => lowercased.includes(pattern))) {
    return false
  }

  if (WROTE_PATTERNS.some((pattern) => lowercased.endsWith(pattern))) {
    return true
  }

  const datePatterns = ['on ', 'am ', 'le ', 'el ', 'il ', 'em ', 'op ']
  return datePatterns.some((pattern) => lowercased.includes(pattern))
}

const ATTRIBUTION_SUFFIXES = [
  'wrote:',
  'schrieb:',
  'a écrit :',
  'a écrit:',
  'escribió:',
  'ha scritto:',
  'escreveu:',
  'schreef:',
]

function isAttributionLine(lowercased: string): boolean {
  return ATTRIBUTION_SUFFIXES.some((suffix) => lowercased.endsWith(suffix))
}

function findConsecutiveQuoteLinesWithAttribution(text: string): [number, string | null] {
  const lines = text.split('\n')
  let consecutiveQuoteLines = 0

  for (let index = 0; index < lines.length; index++) {
    const trimmedLine = lines[index]!.trim()
    if (trimmedLine.startsWith('>')) {
      consecutiveQuoteLines += 1
      if (consecutiveQuoteLines >= 2) {
        let firstQuoteLineIndex = index - consecutiveQuoteLines + 1
        let attribution: string | null = null

        if (firstQuoteLineIndex > 0) {
          const precedingLine = lines[firstQuoteLineIndex - 1]!.trim()
          if (isAttributionLine(precedingLine.toLowerCase())) {
            firstQuoteLineIndex -= 1
            attribution = precedingLine
          }
        }

        const precedingText = lines.slice(0, firstQuoteLineIndex).join('\n')
        return [precedingText.length, attribution]
      }
    } else {
      consecutiveQuoteLines = 0
    }
  }

  return [text.length, null]
}

function findHeaderBlockQuoteBoundaryWithAttribution(text: string): [number, string | null] {
  const lines = text.split('\n')
  if (lines.length === 0) return [text.length, null]

  const lineStartOffsets: number[] = []
  let runningOffset = 0
  for (let index = 0; index < lines.length; index++) {
    lineStartOffsets.push(runningOffset)
    runningOffset += lines[index]!.length
    if (index < lines.length - 1) {
      runningOffset += 1
    }
  }

  const lookaheadLimit = 24

  for (let index = 0; index < lines.length; index++) {
    const trimmed = lines[index]!.trim()
    if (trimmed.length === 0) continue

    const lowercased = trimmed.toLowerCase()
    if (!QUOTE_FROM_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      continue
    }

    // Quote headers usually start after a blank line.
    if (index > 0) {
      const previousLine = lines[index - 1]!.trim()
      if (previousLine.length > 0) {
        continue
      }
    }

    let sawTo = false
    let sawSentOrDate = false
    let sawSubject = false
    const upperBound = Math.min(lines.length, index + lookaheadLimit)

    if (index + 1 < upperBound) {
      for (let candidateIndex = index + 1; candidateIndex < upperBound; candidateIndex++) {
        const candidate = lines[candidateIndex]!.trim()
        if (candidate.length === 0) continue

        const candidateLower = candidate.toLowerCase()
        if (QUOTE_TO_HEADER_PREFIXES.some((prefix) => candidateLower.startsWith(prefix))) {
          sawTo = true
        }
        if (
          QUOTE_SENT_OR_DATE_HEADER_PREFIXES.some((prefix) => candidateLower.startsWith(prefix))
        ) {
          sawSentOrDate = true
        }
        if (QUOTE_SUBJECT_HEADER_PREFIXES.some((prefix) => candidateLower.startsWith(prefix))) {
          sawSubject = true
        }

        if (sawTo && (sawSentOrDate || sawSubject)) {
          return [lineStartOffsets[index]!, trimmed]
        }
      }
    }
  }

  return [text.length, null]
}
