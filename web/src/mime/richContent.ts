// Rich-content classification and the HTML cleanup degradation chain.
// Ports: ProcessedTextCache.hasGenuineRichContent (+ helpers),
// HTMLMeaningfulContentChecker, HTMLCleanupFallback.

import { removeQuotesFromHtml, type QuoteRemovalMode } from './html'
import { extractPlainTextFromHtml } from './htmlText'

// MARK: - Meaningful content check (HTMLMeaningfulContentChecker)

const MAX_HIDDEN_ELEMENT_STRIP_PASSES = 4

const HIDDEN_ELEMENT_PATTERNS: RegExp[] = [
  // Explicit hidden attribute.
  /<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*\bhidden\b[^>]*>[\s\S]*?<\/\1>/gi,
  // Inline style patterns that are genuinely non-rendered.
  /<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*style\s*=\s*['"][^'"]*(?:display\s*:\s*none|visibility\s*:\s*hidden|mso-hide\s*:\s*all|opacity\s*:\s*0(?:\.0+)?)[^'"]*['"][^>]*>[\s\S]*?<\/\1>/gi,
  // Hidden class conventions seen in email templates.
  /<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*class\s*=\s*['"][^'"]*(?:\bm-hide\b|\bpreheader\b|\bpreview-text\b)[^'"]*['"][^>]*>[\s\S]*?<\/\1>/gi,
]

const INVISIBLE_CHARACTER_PATTERN = /(?:\u200B|\u200C|\u200D|\uFEFF|\u00A0|\s)+/g

function stripNonRenderableContent(html: string): string {
  let filtered = html
    .replace(/<!--[\s\S]*?-->/gi, '')
    .replace(/<head\b[^>]*>[\s\S]*?<\/head>/gi, '')

  for (const regex of HIDDEN_ELEMENT_PATTERNS) {
    for (let pass = 0; pass < MAX_HIDDEN_ELEMENT_STRIP_PASSES; pass++) {
      const updated = filtered.replace(regex, '')
      if (updated === filtered) {
        break
      }
      filtered = updated
    }
  }

  return filtered
}

function normalizeInvisibleText(text: string): string {
  const normalized = text
    .replace(/\u200B/g, '')
    .replace(/\u200C/g, '')
    .replace(/\u200D/g, '')
    .replace(/\uFEFF/g, '')
    .replace(/\u00A0/g, ' ')
    .replace(INVISIBLE_CHARACTER_PATTERN, '')

  return normalized.trim()
}

/** True when the HTML still renders something visible after hidden-content stripping. */
export function hasMeaningfulContent(html: string): boolean {
  const trimmed = html.trim()
  if (trimmed.length === 0) return false

  const renderableHTML = stripNonRenderableContent(trimmed)
  if (renderableHTML.trim().length === 0) return false

  // Image-only templates are still meaningful content.
  if (
    /<img/i.test(renderableHTML) ||
    /<svg/i.test(renderableHTML) ||
    /background-image/i.test(renderableHTML)
  ) {
    return true
  }

  const extracted = extractPlainTextFromHtml(renderableHTML)
  return normalizeInvisibleText(extracted).length > 0
}

// MARK: - Cleanup degradation chain (HTMLCleanupFallback)

export interface HtmlProcessingCleanupResult {
  html: string
  /** True when every cleanup mode wiped the content and the original was kept. */
  applyPlainTextQuoteRemoval: boolean
}

export function cleanedHtmlForCleanupModes(
  html: string,
  modes: QuoteRemovalMode[],
): { html: string; appliedMode: QuoteRemovalMode | null } {
  for (const mode of modes) {
    const cleaned = removeQuotesFromHtml(html, mode) ?? html
    if (hasMeaningfulContent(cleaned)) {
      return { html: cleaned, appliedMode: mode }
    }
  }

  return { html, appliedMode: null }
}

/**
 * ProcessedTextCache.cleanedHTMLForProcessing: try quote+signature removal,
 * then quote-only, falling back to the original HTML.
 */
export function cleanedHtmlForProcessing(html: string): HtmlProcessingCleanupResult {
  const fallback = cleanedHtmlForCleanupModes(html, ['quotedAndSignatures', 'quotedOnly'])
  return {
    html: fallback.html,
    applyPlainTextQuoteRemoval: fallback.appliedMode === null,
  }
}

// MARK: - Rich content classification

function countOccurrences(needle: string, haystackLower: string): number {
  let count = 0
  let index = 0
  while (true) {
    const found = haystackLower.indexOf(needle, index)
    if (found === -1) break
    count += 1
    index = found + needle.length
  }
  return count
}

function countHtmlElements(lowercased: string): {
  imgCount: number
  tableCount: number
  cidCount: number
  linkCount: number
} {
  return {
    imgCount: countOccurrences('<img', lowercased),
    tableCount: countOccurrences('<table', lowercased),
    cidCount: countOccurrences('cid:', lowercased),
    linkCount: countOccurrences('<a ', lowercased) + countOccurrences('<a>', lowercased),
  }
}

function approximateTextContent(html: string): string {
  return html
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function isSimpleDivWrappedText(html: string, lowercased: string): boolean {
  if (!lowercased.includes('<div')) return false

  const richIndicators = [
    '<table',
    '<img',
    '<video',
    '<iframe',
    '<object',
    '<embed',
    '<article',
    '<section',
    '<header',
    '<footer',
    '<nav',
    '<style',
    'background-image',
    'background:url',
    'background: url',
    'class="button',
    'class="btn',
    'class="cta',
    'role="button',
  ]

  for (const indicator of richIndicators) {
    if (lowercased.includes(indicator)) {
      return false
    }
  }

  const afterSimpleStrip = html.replace(
    /<\/?(?:div|span|br|p|a|b|i|strong|em|font|blockquote)[^>]*>/g,
    '',
  )

  const remainingTagCount = afterSimpleStrip.split('<').length - 1
  return remainingTagCount === 0
}

const TRANSACTIONAL_PATTERNS = [
  'security alert',
  'new sign-in',
  'new signin',
  "if this wasn't you",
  'if this was not you',
  'review activity',
  'verify your',
  'confirm your',
  'password reset',
  'reset your password',
  'one-time passcode',
  'one time passcode',
  'statement is ready',
  'account activity',
  'account number ending',
  'account ending in',
  'service message',
  'invoice',
  'receipt',
  'order confirmation',
  'tracking number',
  'payment receipt',
  'deposit declined',
  'daily deposit limit',
  'mobile check deposit',
]

function isLikelyTransactionalOrMarketingContent(
  lowercasedHTML: string,
  textContent: string,
  linkCount: number,
  hasNewsletterIndicators: boolean,
): boolean {
  if (textContent.length <= 200) return false

  if (hasNewsletterIndicators) {
    return true
  }

  const lowercasedText = textContent.toLowerCase()

  let transactionalHitCount = 0
  for (const pattern of TRANSACTIONAL_PATTERNS) {
    if (lowercasedText.includes(pattern) || lowercasedHTML.includes(pattern)) {
      transactionalHitCount += 1
    }
  }

  const hasNoReplyLanguage =
    lowercasedText.includes('do not reply') ||
    lowercasedText.includes("don't reply") ||
    lowercasedText.includes('do not respond') ||
    lowercasedText.includes("don't respond") ||
    lowercasedText.includes('noreply') ||
    lowercasedText.includes('no-reply')
  if (hasNoReplyLanguage) {
    transactionalHitCount += 1
  }

  if (linkCount >= 6) {
    return true
  }

  if (linkCount >= 2 && transactionalHitCount >= 1) {
    return true
  }

  if (transactionalHitCount >= 2) {
    return true
  }

  return transactionalHitCount >= 1 && textContent.length > 700
}

function findMatchingClosingDiv(html: string, start: number): number | null {
  const lower = html.toLowerCase()
  let depth = 0
  let searchIndex = start

  while (searchIndex < html.length) {
    const nextOpen = lower.indexOf('<div', searchIndex)
    const nextClose = lower.indexOf('</div', searchIndex)

    if (nextOpen !== -1 && (nextClose === -1 || nextOpen < nextClose)) {
      depth += 1
      searchIndex = nextOpen + 4
    } else if (nextClose !== -1) {
      depth -= 1
      const closeTagEnd = html.indexOf('>', nextClose)
      if (closeTagEnd === -1) return null
      const afterClose = closeTagEnd + 1
      searchIndex = afterClose
      if (depth === 0) {
        return afterClose
      }
    } else {
      return null
    }
  }

  return null
}

function stripAppleRichLinkPreviews(html: string): string {
  let result = html
  let searchStart = 0

  while (searchStart < result.length) {
    const lower = result.toLowerCase()
    const markerIndex = lower.indexOf('apple-rich-link', searchStart)
    if (markerIndex === -1) break

    const divStart = lower.lastIndexOf('<div', markerIndex)
    if (divStart === -1) break
    const endIndex = findMatchingClosingDiv(result, divStart)
    if (endIndex === null) break

    result = result.slice(0, divStart) + result.slice(endIndex)
    searchStart = divStart
  }

  return result
}

/**
 * Determines if HTML contains genuine rich content (newsletters, receipts)
 * vs personal-email signature cruft.
 */
export function hasGenuineRichContent(html: string): boolean {
  const htmlForAnalysis = stripAppleRichLinkPreviews(html)
  const lowercased = htmlForAnalysis.toLowerCase()

  // Always rich: video/iframe/embed/object.
  if (
    lowercased.includes('<video') ||
    lowercased.includes('<iframe') ||
    lowercased.includes('<object') ||
    lowercased.includes('<embed')
  ) {
    return true
  }

  // Always rich: semantic HTML5 elements.
  if (
    lowercased.includes('<article') ||
    lowercased.includes('<section') ||
    lowercased.includes('<header') ||
    lowercased.includes('<footer') ||
    lowercased.includes('<nav')
  ) {
    return true
  }

  const { imgCount, tableCount, cidCount, linkCount } = countHtmlElements(lowercased)

  const hasNewsletterIndicators =
    lowercased.includes('unsubscribe') ||
    lowercased.includes('view in browser') ||
    lowercased.includes('email preferences') ||
    lowercased.includes('privacy policy') ||
    lowercased.includes('manage preferences') ||
    lowercased.includes('update your preferences')

  if (
    imgCount === 0 &&
    tableCount === 0 &&
    cidCount === 0 &&
    isSimpleDivWrappedText(htmlForAnalysis, lowercased)
  ) {
    const textContent = approximateTextContent(htmlForAnalysis)
    return isLikelyTransactionalOrMarketingContent(
      lowercased,
      textContent,
      linkCount,
      hasNewsletterIndicators,
    )
  }

  const textContent = approximateTextContent(htmlForAnalysis)

  const hasBackgroundImages =
    lowercased.includes('background-image') ||
    lowercased.includes('background:url') ||
    lowercased.includes('background: url')

  const hasButtonElements =
    lowercased.includes('class="button') ||
    lowercased.includes("class='button") ||
    lowercased.includes('role="button') ||
    lowercased.includes('class="btn') ||
    lowercased.includes('class="cta')

  const hasTransactionalSignals = isLikelyTransactionalOrMarketingContent(
    lowercased,
    textContent,
    linkCount,
    hasNewsletterIndicators,
  )

  const isLikelySignatureOnly =
    imgCount <= 10 &&
    tableCount <= 5 &&
    cidCount <= 10 &&
    !hasBackgroundImages &&
    !hasButtonElements

  if (isLikelySignatureOnly) {
    if (hasNewsletterIndicators && textContent.length > 200) {
      return true
    }

    if (linkCount > 15) {
      return true
    }

    if (tableCount >= 2 && textContent.length > 200) {
      return true
    }

    if (tableCount >= 1 && hasTransactionalSignals) {
      return true
    }

    return false
  }

  const totalElements = imgCount + tableCount + cidCount
  const charsPerElement =
    totalElements > 0 ? Math.floor(textContent.length / totalElements) : textContent.length

  if (charsPerElement < 50 && textContent.length < 500) {
    if (
      tableCount >= 6 &&
      (hasButtonElements || hasNewsletterIndicators || hasTransactionalSignals)
    ) {
      return true
    }

    if (linkCount > 15 && textContent.length > 300) {
      return true
    }
    return false
  }

  if (hasNewsletterIndicators && totalElements > 5) {
    return true
  }

  if ((hasBackgroundImages || hasButtonElements) && textContent.length > 300) {
    return true
  }

  let score = 0

  score += Math.min(imgCount * 2, 20)
  score += Math.min(tableCount * 3, 30)
  score += Math.min(linkCount, 20)
  if (cidCount > 0) score += 5

  if (hasBackgroundImages) score += 15
  if (hasButtonElements) score += 10
  if (hasNewsletterIndicators) score += 25

  if (textContent.length > 200) score += 10
  if (textContent.length > 500) score += 10

  if (charsPerElement < 40 && textContent.length < 400) score -= 10

  return score >= 40
}
