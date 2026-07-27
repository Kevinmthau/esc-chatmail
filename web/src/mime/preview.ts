// Snippet/preview composition mirroring MessageProcessor.createCleanedSnippet
// and createChatPreviewText, plus TextSnippetCreator and ForwardingHeuristics.

import { decodeHtmlEntities } from './decode'
import { removeQuotesFromHtml } from './html'
import { extractPlainTextFromHtml } from './htmlText'
import { extractDisplayText } from './rawSource'
import { htmlCompatibilityFallback, plainTextOnlyFallback } from './bubble'
import { removeQuotes } from './text'

// MARK: - Forwarding heuristics

const FORWARD_SUBJECT_PREFIXES = ['fwd:', 'fw:']

const FORWARD_MARKER_PATTERNS: RegExp[] = [
  /(?:^|\n|\r|>)\s*begin\s+forwarded\s+message\b/i,
  /(?:^|\n|\r|>)\s*-{2,}\s*forwarded\s+message\b/i,
  /(?:^|\n|\r|>)\s*-{2,}\s*original\s+message\b/i,
  /(?:^|\n|\r|>)\s*---\s*original\s+message\s*---/i,
]

const INTERNATIONAL_FORWARD_MARKERS = [
  'weitergeleitete nachricht',
  'message transféré',
  'mensaje reenviado',
  'messaggio inoltrato',
  'mensagem encaminhada',
  'doorgestuurd bericht',
]

export function isForwardedSubject(subject: string | null | undefined): boolean {
  const normalizedSubject = subject?.trim().toLowerCase()
  if (normalizedSubject === undefined || normalizedSubject.length === 0) {
    return false
  }
  return FORWARD_SUBJECT_PREFIXES.some((prefix) => normalizedSubject.startsWith(prefix))
}

function containsForwardMarker(text: string | null | undefined): boolean {
  if (text === null || text === undefined || text.length === 0) {
    return false
  }

  if (FORWARD_MARKER_PATTERNS.some((pattern) => pattern.test(text))) {
    return true
  }

  const lowercased = text.toLowerCase()
  return INTERNATIONAL_FORWARD_MARKERS.some((marker) => lowercased.includes(marker))
}

export function indicatesForwarding(
  subject: string | null | undefined,
  contentCandidates: readonly (string | null | undefined)[],
): boolean {
  if (isForwardedSubject(subject)) {
    return true
  }

  return contentCandidates.some((candidate) => containsForwardMarker(candidate))
}

// MARK: - Snippet creation (TextSnippetCreator)

/**
 * Creates a clean snippet from email content: raw-source sanitize, entity
 * decode, quote/signature removal, whitespace collapse.
 */
export function createCleanSnippet(
  text: string | null | undefined,
  maxLength = 5000,
  firstSentenceOnly = false,
): string {
  if (text === null || text === undefined || text.length === 0) return ''

  const sourceText = extractDisplayText(text)
  const decodedSourceText = decodeHtmlEntities(sourceText)

  const cleanedText = removeQuotes(decodedSourceText) ?? decodedSourceText

  const condensed = cleanedText
    .split(/\s+/)
    .filter((token) => token.length > 0)
    .join(' ')

  if (firstSentenceOnly) {
    return extractFirstSentence(condensed)
  }

  if (Number.isFinite(maxLength) && condensed.length > maxLength) {
    return condensed.slice(0, maxLength) + '...'
  }

  return condensed
}

function extractFirstSentence(text: string): string {
  const match = /[.!?](?:\s|$)/.exec(text)
  if (match) {
    return text.slice(0, match.index + match[0].length).trim()
  }

  const limit = Math.min(text.length, 200)
  const snippet = text.slice(0, limit)
  return limit < text.length ? snippet + '...' : snippet
}

// MARK: - Snippet-ready HTML (MessageProcessor.prepareHTMLForSnippet)

/**
 * Removes head metadata, comments, and hidden preheaders that pollute
 * conversation-list previews.
 */
export function prepareHtmlForSnippet(html: string): string {
  let cleaned = html

  cleaned = cleaned.replace(/<head\b[^>]*>[\s\S]*?<\/head>/gi, '')

  cleaned = cleaned.replace(/<!--[\s\S]*?-->/g, '')

  cleaned = cleaned.replace(
    /<([a-zA-Z0-9]+)\b[^>]*style\s*=\s*['"][^'"]*(?:display\s*:\s*none|visibility\s*:\s*hidden|mso-hide\s*:\s*all|max-height\s*:\s*0|opacity\s*:\s*0|font-size\s*:\s*0)[^'"]*['"][^>]*>[\s\S]*?<\/\1>/gi,
    '',
  )

  return cleaned
}

// MARK: - Cleaned snippet (MessageProcessor.createCleanedSnippet)

export function createCleanedSnippet(
  html: string | null | undefined,
  plainText: string | null | undefined,
  snippet: string | null | undefined,
): string | null {
  if (html !== null && html !== undefined) {
    const snippetReadyHTML = prepareHtmlForSnippet(html)
    // First try to remove quoted content for snippets.
    const cleanedHTML = removeQuotesFromHtml(snippetReadyHTML) ?? snippetReadyHTML
    const plainFromHTML = extractPlainTextFromHtml(cleanedHTML)
    const result = createCleanSnippet(plainFromHTML, Number.POSITIVE_INFINITY, false)

    if (result.length === 0) {
      const plainFromRawHTML = extractPlainTextFromHtml(snippetReadyHTML)
      const fallbackResult = createCleanSnippet(plainFromRawHTML, Number.POSITIVE_INFINITY, false)
      if (fallbackResult.length > 0) {
        return fallbackResult
      }
    } else {
      return result
    }
  }

  if (plainText !== null && plainText !== undefined) {
    const sanitizedPlainText = extractDisplayText(plainText)
    const result = createCleanSnippet(sanitizedPlainText, Number.POSITIVE_INFINITY, false)
    if (result.length > 0) {
      return result
    }
  }

  if (snippet !== null && snippet !== undefined) {
    const sanitizedSnippet = extractDisplayText(snippet)
    const result = createCleanSnippet(sanitizedSnippet, Number.POSITIVE_INFINITY, false)
    if (result.length > 0) {
      return result
    }
    // Ultimate fallback: raw snippet when all cleaning strips it.
    return sanitizedSnippet.trim()
  }

  return null
}

// MARK: - Chat preview text (MessageProcessor.createChatPreviewText)

export function createChatPreviewText(
  html: string | null | undefined,
  plainText: string | null | undefined,
  snippet: string | null | undefined,
  isOutgoingForward = false,
): string | null {
  if (isOutgoingForward) {
    const outgoingForwardPreview = createOutgoingForwardChatPreviewText(plainText, snippet)
    if (outgoingForwardPreview.handled) {
      return outgoingForwardPreview.text
    }
  }

  const htmlPreview = htmlCompatibilityFallback(html, false).mainText
  if (htmlPreview !== null) {
    return htmlPreview
  }

  const plainPreview = plainTextOnlyFallback(plainText, true).mainText
  if (plainPreview !== null) {
    return plainPreview
  }

  return plainTextOnlyFallback(snippet, true).mainText
}

function createOutgoingForwardChatPreviewText(
  plainText: string | null | undefined,
  snippet: string | null | undefined,
): { handled: boolean; text: string | null } {
  if (indicatesForwarding(null, [plainText])) {
    return { handled: true, text: plainTextOnlyFallback(plainText, true).mainText }
  }

  if (indicatesForwarding(null, [snippet])) {
    return { handled: true, text: plainTextOnlyFallback(snippet, true).mainText }
  }

  return { handled: false, text: null }
}
