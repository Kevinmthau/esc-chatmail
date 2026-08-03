// DOM-based quote/signature stripping over parsed HTML.
// Port of esc-chatmail/Services/EmailDOM/EmailDOMQuoteRemover*.swift
// (SwiftSoup → DOMParser).

import { collapsedElementText, paragraphAwareText, parseHtmlDocument } from './htmlText'
import {
  EMAIL_ADDRESS_PATTERN,
  FROM_HEADER_PREFIXES,
  PHONE_PATTERN,
  SENT_OR_DATE_HEADER_PREFIXES,
  STANDALONE_CONTACT_LABEL_PATTERN,
  SUBJECT_HEADER_PREFIXES,
  TO_HEADER_PREFIXES,
  WEB_URL_PATTERN,
  ADDRESS_KEYWORD_PATTERN,
} from './patterns'
import { looksLikeNameLine } from './text'

export type QuoteRemovalMode = 'quotedOnly' | 'quotedAndSignatures'

const NODE_ELEMENT = 1
const NODE_TEXT = 3
const NODE_COMMENT = 8

// MARK: - Input shape detection

export function hasDocumentWrapper(html: string): boolean {
  return (
    containsTagPrefix('<!doctype', html) ||
    containsTagPrefix('<html', html) ||
    containsTagPrefix('<head', html) ||
    containsTagPrefix('<body', html)
  )
}

function containsTagPrefix(prefix: string, html: string): boolean {
  const lower = html.toLowerCase()
  let searchStart = 0

  while (true) {
    const start = lower.indexOf(prefix, searchStart)
    if (start === -1) return false
    const boundaryIndex = start + prefix.length
    if (boundaryIndex === html.length || !isTagNameCharacter(html[boundaryIndex]!)) {
      return true
    }
    searchStart = boundaryIndex
  }
}

function isTagNameCharacter(ch: string): boolean {
  return /[\p{L}\p{N}]/u.test(ch) || ch === '-' || ch === ':' || ch === '_'
}

// MARK: - Public API

/**
 * Removes quoted history (and optionally signatures/footers) from HTML.
 * Fragment in → fragment out; document in → document out. Falls back to the
 * input on any internal error.
 */
export function removeQuotesFromHtml(
  html: string | null | undefined,
  mode: QuoteRemovalMode = 'quotedAndSignatures',
): string | null {
  if (html === null || html === undefined) return null

  const inputIsFragment = !hasDocumentWrapper(html)
  let document: Document
  try {
    document = parseHtmlDocument(html)
  } catch {
    return html
  }
  const body = document.body
  if (!body) return html

  try {
    removeQuotedContainers(document)
    const didTruncateAtStructuralBoundary = truncateAtStructuralBoundaries(document)
    if (!didTruncateAtStructuralBoundary) {
      truncateAtTextMarkers(document)
    }
    if (mode === 'quotedAndSignatures') {
      removeSignatureWrappers(document)
      removeFooterContainers(document)
      truncateAtSignatureMarkers(document)
      truncateTrailingContactSignature(document)
    }
    if (inputIsFragment) {
      return body.innerHTML
    }
    return document.documentElement?.outerHTML ?? body.innerHTML
  } catch {
    return html
  }
}

// MARK: - Tree surgery

function collectTextNodes(rootElement: Element): Text[] {
  const result: Text[] = []
  const stack: Node[] = [rootElement]
  while (stack.length > 0) {
    const node = stack.pop()!
    if (node.nodeType === NODE_TEXT) {
      if ((node as Text).data.trim().length > 0) {
        result.push(node as Text)
      }
    } else {
      const children = Array.from(node.childNodes)
      for (let i = children.length - 1; i >= 0; i--) {
        stack.push(children[i]!)
      }
    }
  }
  return result
}

interface VisibleLineElement {
  element: Element
  text: string
}

interface InlineHeaderLine {
  text: string
  startTextNode: Text | null
  startOffset: number
}

const VISIBLE_LINE_ELEMENT_TAGS = new Set(['div', 'li', 'p', 'tr'])
const INLINE_HEADER_BLOCK_ELEMENT_TAGS = new Set(['div', 'p', 'td', 'th'])

function tagName(element: Element): string {
  return element.tagName.toLowerCase()
}

function isHiddenFromVisibleText(element: Element): boolean {
  if (element.hasAttribute('hidden')) {
    return true
  }

  const style = (element.getAttribute('style') ?? '').toLowerCase().replace(/\s+/g, '')
  return style.includes('display:none') || style.includes('visibility:hidden')
}

function normalizedVisibleLineText(text: string): string {
  return text
    .replace(/\u00A0/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function normalizedElementLineText(element: Element): string {
  return normalizedVisibleLineText(collapsedElementText(element))
}

function visibleLineElements(
  rootElement: Element,
  includingEmpty: boolean,
  stoppingBefore: Element | null = null,
): VisibleLineElement[] {
  const result: VisibleLineElement[] = []
  let reachedTarget = false

  const walkNode = (node: Node): void => {
    if (reachedTarget) return
    if (node.nodeType !== NODE_ELEMENT) return
    const element = node as Element
    if (stoppingBefore !== null && element === stoppingBefore) {
      reachedTarget = true
      return
    }
    if (isHiddenFromVisibleText(element)) return
    const tag = tagName(element)
    if (
      VISIBLE_LINE_ELEMENT_TAGS.has(tag) &&
      !hasDescendantVisibleLineElement(element) &&
      !elementContainsDescendantTable(element)
    ) {
      const text = normalizedElementLineText(element)
      if (includingEmpty || text.length > 0) {
        result.push({ element, text })
      }
      return
    }

    for (const child of Array.from(element.childNodes)) {
      walkNode(child)
    }
  }

  walkNode(rootElement)
  return result
}

function inlineHeaderBlockElements(rootElement: Element): Element[] {
  const result: Element[] = []

  const walkNode = (node: Node): void => {
    if (node.nodeType !== NODE_ELEMENT) return
    const element = node as Element
    if (isHiddenFromVisibleText(element)) return
    const tag = tagName(element)
    if (
      INLINE_HEADER_BLOCK_ELEMENT_TAGS.has(tag) &&
      elementContainsBR(element) &&
      !hasDescendantInlineHeaderBlockElement(element)
    ) {
      result.push(element)
      return
    }

    for (const child of Array.from(element.childNodes)) {
      walkNode(child)
    }
  }

  walkNode(rootElement)
  return result
}

function inlineHeaderLines(element: Element): InlineHeaderLine[] {
  const result: InlineHeaderLine[] = []
  let currentText = ''
  let currentStartTextNode: Text | null = null
  let currentStartOffset = 0

  const appendText = (rawText: string, textNode: Text): void => {
    const normalized = rawText.replace(/\u00A0/g, ' ')
    const firstTextIndex = normalized.search(/\S/)
    if (firstTextIndex === -1) {
      return
    }

    if (currentStartTextNode === null) {
      currentStartTextNode = textNode
      currentStartOffset = firstTextIndex
    }

    const collapsed = normalizedVisibleLineText(normalized)
    if (collapsed.length === 0) return

    if (currentText.length > 0 && !currentText.endsWith(' ')) {
      currentText += ' '
    }
    currentText += collapsed
  }

  const finishLine = (): void => {
    result.push({
      text: normalizedVisibleLineText(currentText),
      startTextNode: currentStartTextNode,
      startOffset: currentStartOffset,
    })
    currentText = ''
    currentStartTextNode = null
    currentStartOffset = 0
  }

  const walkNode = (node: Node): void => {
    if (node.nodeType === NODE_TEXT) {
      appendText((node as Text).data, node as Text)
      return
    }
    if (node.nodeType !== NODE_ELEMENT) return
    const element = node as Element
    if (isHiddenFromVisibleText(element)) return
    if (tagName(element) === 'br') {
      finishLine()
      return
    }

    for (const child of Array.from(element.childNodes)) {
      walkNode(child)
    }
  }

  for (const child of Array.from(element.childNodes)) {
    walkNode(child)
  }

  finishLine()
  return result
}

function hasDescendantVisibleLineElement(element: Element): boolean {
  for (const child of Array.from(element.childNodes)) {
    if (child.nodeType !== NODE_ELEMENT) continue
    const childElement = child as Element
    if (isHiddenFromVisibleText(childElement)) continue
    if (VISIBLE_LINE_ELEMENT_TAGS.has(tagName(childElement))) {
      return true
    }
    if (hasDescendantVisibleLineElement(childElement)) {
      return true
    }
  }
  return false
}

function hasDescendantInlineHeaderBlockElement(element: Element): boolean {
  for (const child of Array.from(element.childNodes)) {
    if (child.nodeType !== NODE_ELEMENT) continue
    const childElement = child as Element
    if (isHiddenFromVisibleText(childElement)) continue
    if (
      INLINE_HEADER_BLOCK_ELEMENT_TAGS.has(tagName(childElement)) &&
      elementContainsBR(childElement)
    ) {
      return true
    }
    if (hasDescendantInlineHeaderBlockElement(childElement)) {
      return true
    }
  }
  return false
}

function elementContainsBR(element: Element): boolean {
  for (const child of Array.from(element.childNodes)) {
    if (child.nodeType !== NODE_ELEMENT) continue
    const childElement = child as Element
    if (isHiddenFromVisibleText(childElement)) continue
    if (tagName(childElement) === 'br') {
      return true
    }
    if (elementContainsBR(childElement)) {
      return true
    }
  }
  return false
}

function elementContainsDescendantTable(element: Element): boolean {
  for (const child of Array.from(element.childNodes)) {
    if (child.nodeType !== NODE_ELEMENT) continue
    const childElement = child as Element
    if (isHiddenFromVisibleText(childElement)) continue
    if (tagName(childElement) === 'table') {
      return true
    }
    if (elementContainsDescendantTable(childElement)) {
      return true
    }
  }
  return false
}

function tableDepth(table: Element): number {
  let depth = 0
  let current = table.parentElement
  while (current) {
    if (tagName(current) === 'body') {
      break
    }
    depth += 1
    current = current.parentElement
  }
  return depth
}

function hasVisibleTextBefore(target: Element, rootElement: Element): boolean {
  let reachedTarget = false
  let sawText = false

  const walkNode = (node: Node): void => {
    if (reachedTarget || sawText) return

    if (node.nodeType === NODE_ELEMENT) {
      const element = node as Element
      if (element === target) {
        reachedTarget = true
        return
      }
      if (isHiddenFromVisibleText(element)) return
    }

    if (node.nodeType === NODE_TEXT && normalizedVisibleLineText((node as Text).data).length > 0) {
      sawText = true
      return
    }

    for (const child of Array.from(node.childNodes)) {
      walkNode(child)
    }
  }

  walkNode(rootElement)
  return sawText
}

function removeAllSiblingsAfter(node: Node): void {
  const parent = node.parentNode
  if (!parent) return
  let found = false
  for (const child of Array.from(parent.childNodes)) {
    if (found) {
      parent.removeChild(child)
      continue
    }
    if (child === node) {
      found = true
    }
  }
}

/**
 * Truncates the document at the given text node/offset: text before the match
 * is preserved, everything after (at every ancestor level up to body) removed.
 */
function truncateAtTextNode(textNode: Text, matchStart: number, fullText: string): void {
  removeAllSiblingsAfter(textNode)

  let current: Element | null = textNode.parentElement
  while (current) {
    if (tagName(current) === 'body') break
    removeAllSiblingsAfter(current)
    current = current.parentElement
  }

  const prefix = fullText.slice(0, Math.max(0, Math.min(matchStart, fullText.length)))
  if (prefix.trim().length === 0) {
    textNode.remove()
  } else {
    textNode.data = prefix
  }
}

/** Removes the element and everything after it in document order (up to body). */
function removeFromHereForward(element: Element): void {
  removeAllSiblingsAfter(element)

  let current: Element | null = element.parentElement
  while (current) {
    if (tagName(current) === 'body') break
    removeAllSiblingsAfter(current)
    current = current.parentElement
  }

  element.remove()
}

// MARK: - Comment-delimited regions

function walkAllComments(node: Node, visit: (comment: Comment) => void): void {
  if (node.nodeType === NODE_COMMENT) {
    visit(node as Comment)
  }
  for (const child of Array.from(node.childNodes)) {
    walkAllComments(child, visit)
  }
}

function removeCommentDelimitedRegions(
  document: Document,
  openHint: string,
  closeHint: string,
): void {
  const body = document.body
  if (!body) return
  const comments: Comment[] = []
  walkAllComments(body, (comment) => {
    comments.push(comment)
  })

  const openMatch = openHint.toLowerCase()
  const closeMatch = closeHint.toLowerCase()
  let open: Comment | undefined
  let close: Comment | undefined
  for (const comment of comments) {
    const data = comment.data.toLowerCase()
    if (open === undefined && data.includes(openMatch)) {
      open = comment
    } else if (open !== undefined && close === undefined && data.includes(closeMatch)) {
      close = comment
    }
  }
  if (open === undefined || close === undefined) return

  const openParent = open.parentNode
  const closeParent = close.parentNode
  if (openParent && openParent === closeParent) {
    let inside = false
    for (const child of Array.from(openParent.childNodes)) {
      if (!inside) {
        if (child === open) {
          inside = true
        }
        continue
      }
      if (child === close) {
        openParent.removeChild(child)
        inside = false
        continue
      }
      openParent.removeChild(child)
    }
    open.remove()
    return
  }
  open.remove()
  close.remove()
}

// MARK: - Containers (provider-specific)

const QUOTED_CONTAINER_SELECTORS: string[] = [
  // Gmail
  'div.gmail_quote',
  'div.gmail_attr',
  // Apple Mail
  'blockquote[type="cite"]',
  'div.AppleMailSignature',
  // Mozilla / Thunderbird
  'div.moz-cite-prefix',
  // Outlook desktop
  'div.OutlookMessageHeader',
  // Generic
  'blockquote',
]

function removeQuotedContainers(document: Document): void {
  // border-left styled divs are commonly used as quote blocks.
  for (const element of Array.from(document.querySelectorAll('div[style*="border-left"]'))) {
    element.remove()
  }

  for (const selector of QUOTED_CONTAINER_SELECTORS) {
    for (const element of Array.from(document.querySelectorAll(selector))) {
      element.remove()
    }
  }

  removeCommentDelimitedRegions(document, 'originalmessage', '/originalmessage')
}

// MARK: - Structural boundaries

const STRUCTURAL_QUOTE_SELECTORS: string[] = ['[id*="mail-editor-reference-message-container"]']

function truncateAtStructuralBoundaries(document: Document): boolean {
  for (const selector of STRUCTURAL_QUOTE_SELECTORS) {
    const first = document.querySelector(selector)
    if (first) {
      removeFromHereForward(first)
      return true
    }
  }

  // Outlook desktop border-top gray header block with From/Sent/To/Subject.
  for (const element of Array.from(document.querySelectorAll('div[style]'))) {
    const style = (element.getAttribute('style') ?? '').toLowerCase()
    if (!style.includes('border-top') || !style.includes('#e1e1e1')) continue
    const lower = normalizedElementLineText(element).toLowerCase()
    if (!lower.includes('from:') || !lower.includes('subject:') || !lower.includes('to:')) continue
    removeFromHereForward(element)
    return true
  }

  if (truncateAtStrongHeaderBoundary(document)) {
    return true
  }

  if (truncateAtHeaderTableBoundary(document)) {
    return true
  }

  if (truncateAtHeaderBlockBoundary(document)) {
    return true
  }

  if (truncateAtInlineHeaderBlockBoundary(document)) {
    return true
  }

  return false
}

function truncateAtStrongHeaderBoundary(document: Document): boolean {
  let fromElement: Element | null = null

  for (const element of Array.from(document.querySelectorAll('strong'))) {
    switch (normalizedQuoteHeaderLabel(normalizedElementLineText(element))) {
      case 'from':
        if (fromElement === null) {
          fromElement = element
        }
        break
      case 'subject': {
        if (fromElement === null) continue
        removeFromHereForward(quoteHeaderBoundaryElement(fromElement))
        return true
      }
      default:
        continue
    }
  }

  return false
}

function normalizedQuoteHeaderLabel(text: string): string {
  const normalized = text
    .replace(/\u00A0/g, ' ')
    .trim()
    .toLowerCase()
  switch (normalized) {
    case 'from:':
      return 'from'
    case 'subject:':
      return 'subject'
    default:
      return ''
  }
}

const QUOTE_HEADER_BOUNDARY_TAGS = new Set(['div', 'li', 'p', 'tr'])

function quoteHeaderBoundaryElement(element: Element): Element {
  let current: Element | null = element
  while (current) {
    if (tagName(current) === 'body') {
      break
    }
    if (QUOTE_HEADER_BOUNDARY_TAGS.has(tagName(current))) {
      return current
    }
    current = current.parentElement
  }
  return element
}

interface HeaderTableBoundaryCandidate {
  removalElement: Element
  boundaryLineIndex: number
  tableDepth: number
}

function truncateAtHeaderTableBoundary(document: Document): boolean {
  const body = document.body
  if (!body) return false
  const tables = Array.from(document.querySelectorAll('table'))
  const candidates: HeaderTableBoundaryCandidate[] = []

  for (const table of tables) {
    const precedingLines = visibleLineElements(body, true, table)
    const tableLines = visibleLineElements(table, true)
    const lines = precedingLines.concat(tableLines)
    const lineTexts = lines.map((l) => l.text)

    const localStartIndex = tableLines.findIndex((l) => isFromHeaderLine(l.text))
    if (localStartIndex === -1) {
      continue
    }
    const startIndex = precedingLines.length + localStartIndex

    const boundary = quoteHeaderBoundaryMatch(startIndex, lineTexts)
    if (boundary === null) {
      continue
    }

    if (!hasQuoteHeaderSequence(startIndex, lineTexts, boundary.kind === 'contactSignature')) {
      continue
    }
    const removalElement = boundary.kind === 'hard' ? lines[boundary.index]!.element : table
    const boundaryLineIndex = boundary.kind === 'hard' ? boundary.index : startIndex

    candidates.push({
      removalElement,
      boundaryLineIndex,
      tableDepth: tableDepth(table),
    })
  }

  if (candidates.length === 0) return false

  candidates.sort((lhs, rhs) => {
    if (lhs.boundaryLineIndex === rhs.boundaryLineIndex) {
      return rhs.tableDepth - lhs.tableDepth
    }
    return lhs.boundaryLineIndex - rhs.boundaryLineIndex
  })

  removeFromHereForward(candidates[0]!.removalElement)
  return true
}

function truncateAtHeaderBlockBoundary(document: Document): boolean {
  const body = document.body
  if (!body) return false
  const lines = visibleLineElements(body, true)
  const lineTexts = lines.map((l) => l.text)

  for (let index = 0; index < lines.length; index++) {
    if (!isFromHeaderLine(lines[index]!.text)) {
      continue
    }

    const boundary = quoteHeaderBoundaryMatch(index, lineTexts)
    if (boundary === null) {
      continue
    }

    if (!hasQuoteHeaderSequence(index, lineTexts, boundary.kind === 'contactSignature')) {
      continue
    }

    const removalElement =
      boundary.kind === 'hard' ? lines[boundary.index]!.element : lines[index]!.element
    removeFromHereForward(removalElement)
    return true
  }

  return false
}

function truncateAtInlineHeaderBlockBoundary(document: Document): boolean {
  const body = document.body
  if (!body) return false

  for (const element of inlineHeaderBlockElements(body)) {
    const lines = inlineHeaderLines(element)
    const lineTexts = lines.map((l) => l.text)

    for (let index = 0; index < lineTexts.length; index++) {
      if (!isFromHeaderLine(lineTexts[index]!)) {
        continue
      }

      const boundary = quoteHeaderBoundaryMatch(index, lineTexts)
      const requiresStrongInlineSignal = boundary === null
      const requireSubject = boundary?.kind === 'contactSignature' || requiresStrongInlineSignal

      if (!hasQuoteHeaderSequence(index, lineTexts, requireSubject)) {
        continue
      }

      if (requiresStrongInlineSignal) {
        if (
          !hasCurrentMessageContentBeforeInlineHeaderBlock(index, lineTexts, element, body) ||
          !hasCompleteQuoteHeaderSequence(index, lineTexts) ||
          !headerSequenceContainsEmailAddress(index, lineTexts)
        ) {
          continue
        }
      }

      const removalLineIndex = boundary?.kind === 'hard' ? boundary.index : index
      const line = lines[removalLineIndex]!
      const textNode = line.startTextNode
      if (textNode === null) {
        removeFromHereForward(element)
        return true
      }

      truncateAtTextNode(textNode, line.startOffset, textNode.data)
      return true
    }
  }

  return false
}

type QuoteHeaderBoundaryKind = 'hard' | 'contactSignature'

interface QuoteHeaderBoundaryMatch {
  kind: QuoteHeaderBoundaryKind
  index: number
}

function quoteHeaderBoundaryMatch(
  startIndex: number,
  lineTexts: string[],
): QuoteHeaderBoundaryMatch | null {
  if (startIndex <= 0) return null

  for (let candidate = startIndex - 1; candidate >= 0; candidate--) {
    const previousText = lineTexts[candidate]!
    if (previousText.length === 0) continue

    if (isTextualQuoteBoundaryLine(previousText)) {
      return { kind: 'hard', index: candidate }
    }

    if (isContactSignatureLine(previousText)) {
      return { kind: 'contactSignature', index: candidate }
    }

    return null
  }

  return null
}

function isFromHeaderLine(text: string): boolean {
  const lowercased = text.toLowerCase()
  return FROM_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))
}

function isTextualQuoteBoundaryLine(text: string): boolean {
  const lowercased = text.toLowerCase()
  if (lowercased.includes('begin forwarded message:')) {
    return true
  }
  if (lowercased.includes('forwarded message') && lowercased.includes('--')) {
    return true
  }
  if (lowercased.includes('original message') && lowercased.includes('--')) {
    return true
  }
  return lowercased.trim() === '________________________________'
}

function hasQuoteHeaderSequence(
  startIndex: number,
  lineTexts: string[],
  requireSubject = false,
): boolean {
  let sawTo = false
  let sawSentOrDate = false
  let sawSubject = false
  const upperBound = Math.min(lineTexts.length, startIndex + 24)

  if (startIndex + 1 >= upperBound) return false

  for (let index = startIndex + 1; index < upperBound; index++) {
    const lowercased = lineTexts[index]!.toLowerCase()
    if (TO_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawTo = true
    }
    if (SENT_OR_DATE_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawSentOrDate = true
    }
    if (SUBJECT_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawSubject = true
    }

    if (sawTo && (sawSentOrDate || sawSubject)) {
      if (!requireSubject || sawSubject) {
        return true
      }
    }
  }

  return false
}

function hasCompleteQuoteHeaderSequence(startIndex: number, lineTexts: string[]): boolean {
  let sawTo = false
  let sawSentOrDate = false
  let sawSubject = false
  const upperBound = Math.min(lineTexts.length, startIndex + 24)

  if (startIndex + 1 >= upperBound) return false

  for (let index = startIndex + 1; index < upperBound; index++) {
    const lowercased = lineTexts[index]!.toLowerCase()
    if (TO_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawTo = true
    }
    if (SENT_OR_DATE_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawSentOrDate = true
    }
    if (SUBJECT_HEADER_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
      sawSubject = true
    }

    if (sawTo && sawSentOrDate && sawSubject) {
      return true
    }
  }

  return false
}

function headerSequenceContainsEmailAddress(startIndex: number, lineTexts: string[]): boolean {
  const upperBound = Math.min(lineTexts.length, startIndex + 24)
  if (startIndex >= upperBound) return false

  for (let index = startIndex; index < upperBound; index++) {
    if (containsEmailAddress(lineTexts[index]!)) {
      return true
    }
  }

  return false
}

function hasCurrentMessageContentBeforeInlineHeaderBlock(
  startIndex: number,
  lineTexts: string[],
  element: Element,
  body: Element,
): boolean {
  if (lineTexts.slice(0, startIndex).some((t) => t.length > 0)) {
    return true
  }

  return hasVisibleTextBefore(element, body)
}

// MARK: - Text markers ("On … wrote:")

const TEXT_TRUNCATION_PATTERNS: RegExp[] = [
  /(?:^|[\r\n])\s*On .{1,400}? wrote:/i,
  /(?:^|[\r\n])\s*On [A-Z][a-z]+ \d{1,2}, \d{4} at \d{1,2}:\d{2}\s*[AP]M,/i,
  /(?:^|[\r\n])\s*-{2,}\s*Original Message\s*-{2,}/i,
  /(?:^|[\r\n])\s*(?:Le|Am)\s.{1,200}?\s(?:a écrit|schrieb):/i,
]

interface TextMarkerMatch {
  index: number
  length: number
}

function earliestTextMarkerMatch(text: string): TextMarkerMatch | null {
  let best: TextMarkerMatch | null = null
  for (const pattern of TEXT_TRUNCATION_PATTERNS) {
    const match = pattern.exec(text)
    if (!match) continue
    const candidate = { index: match.index, length: match[0].length }
    if (
      best === null ||
      candidate.index < best.index ||
      (candidate.index === best.index && candidate.length < best.length)
    ) {
      best = candidate
    }
  }
  return best
}

interface TextMarkerCandidate {
  textNode: Text
  matchStart: number
  fullText: string
  textNodeIndex: number
}

function isEarlierTextMarkerCandidate(lhs: TextMarkerCandidate, rhs: TextMarkerCandidate): boolean {
  if (lhs.textNodeIndex === rhs.textNodeIndex) {
    return lhs.matchStart < rhs.matchStart
  }
  return lhs.textNodeIndex < rhs.textNodeIndex
}

function truncateAtTextMarkers(document: Document): void {
  const body = document.body
  if (!body) return
  const textNodes = collectTextNodes(body)
  const candidates: TextMarkerCandidate[] = []
  const single = singleTextNodeMarkerCandidate(textNodes)
  if (single) candidates.push(single)
  const split = inlineSplitTextMarkerCandidate(textNodes, body)
  if (split) candidates.push(split)

  if (candidates.length === 0) return
  candidates.sort((a, b) => (isEarlierTextMarkerCandidate(a, b) ? -1 : 1))
  const candidate = candidates[0]!

  truncateAtTextNode(candidate.textNode, candidate.matchStart, candidate.fullText)
}

function singleTextNodeMarkerCandidate(textNodes: Text[]): TextMarkerCandidate | null {
  for (let index = 0; index < textNodes.length; index++) {
    const textNode = textNodes[index]!
    const text = textNode.data
    const match = earliestTextMarkerMatch(text)
    if (!match) continue
    return {
      textNode,
      matchStart: match.index,
      fullText: text,
      textNodeIndex: index,
    }
  }
  return null
}

interface TextNodeGroup {
  container: Element
  textNodes: Text[]
}

interface TextRun {
  textNode: Text | null
  text: string
  startOffset: number
}

const TEXT_MARKER_CONTAINER_TAGS = new Set([
  'address',
  'article',
  'blockquote',
  'caption',
  'dd',
  'div',
  'dt',
  'footer',
  'header',
  'li',
  'main',
  'p',
  'pre',
  'section',
  'td',
  'th',
])

function inlineSplitTextMarkerCandidate(
  textNodes: Text[],
  body: Element,
): TextMarkerCandidate | null {
  const textNodeIndexes = new Map<Text, number>()
  for (let index = 0; index < textNodes.length; index++) {
    textNodeIndexes.set(textNodes[index]!, index)
  }

  const groups = groupedTextNodesByMarkerContainer(textNodes, body)
  let bestCandidate: TextMarkerCandidate | null = null

  for (const group of groups) {
    if (group.textNodes.length <= 1) continue
    const runs = textRuns(group)
    if (runs.length <= 1) continue

    const combinedText = runs.map((r) => r.text).join('')
    const match = earliestTextMarkerMatch(combinedText)
    if (!match) continue
    const run = textRunForTruncation(match.index, runs)
    if (!run || run.textNode === null) continue
    const textNodeIndex = textNodeIndexes.get(run.textNode)
    if (textNodeIndex === undefined) continue

    const candidate: TextMarkerCandidate = {
      textNode: run.textNode,
      matchStart: Math.max(0, match.index - run.startOffset),
      fullText: run.text,
      textNodeIndex,
    }
    if (bestCandidate === null || isEarlierTextMarkerCandidate(candidate, bestCandidate)) {
      bestCandidate = candidate
    }
  }

  return bestCandidate
}

function groupedTextNodesByMarkerContainer(textNodes: Text[], body: Element): TextNodeGroup[] {
  const groups: TextNodeGroup[] = []
  const groupIndexesByContainer = new Map<Element, number>()

  for (const textNode of textNodes) {
    const container = nearestTextMarkerContainer(textNode, body)
    if (!container) continue

    const existing = groupIndexesByContainer.get(container)
    if (existing !== undefined) {
      groups[existing]!.textNodes.push(textNode)
    } else {
      groupIndexesByContainer.set(container, groups.length)
      groups.push({ container, textNodes: [textNode] })
    }
  }

  return groups
}

function nearestTextMarkerContainer(textNode: Text, body: Element): Element | null {
  let current = textNode.parentElement
  while (current) {
    if (current === body) {
      return body
    }
    if (TEXT_MARKER_CONTAINER_TAGS.has(tagName(current))) {
      return current
    }
    current = current.parentElement
  }
  return null
}

function textRuns(group: TextNodeGroup): TextRun[] {
  const runs: TextRun[] = []
  let offset = 0
  const targetTextNodes = new Set(group.textNodes)
  let hasSeenTargetTextNode = false
  let pendingLineBreakCount = 0

  const appendRun = (textNode: Text | null, text: string): void => {
    runs.push({ textNode, text, startOffset: offset })
    offset += text.length
  }

  const flushPendingLineBreaks = (): void => {
    if (pendingLineBreakCount <= 0) return
    appendRun(null, '\n'.repeat(pendingLineBreakCount))
    pendingLineBreakCount = 0
  }

  const walkNode = (node: Node): void => {
    if (node.nodeType === NODE_TEXT) {
      const textNode = node as Text
      if (!targetTextNodes.has(textNode)) return
      const text = textNode.data
      if (text.length === 0) return
      if (hasSeenTargetTextNode) {
        flushPendingLineBreaks()
      }
      appendRun(textNode, text)
      hasSeenTargetTextNode = true
      return
    }

    if (node.nodeType !== NODE_ELEMENT) return
    const element = node as Element
    if (tagName(element) === 'br') {
      if (hasSeenTargetTextNode) {
        pendingLineBreakCount += 1
      }
      return
    }

    for (const child of Array.from(element.childNodes)) {
      walkNode(child)
    }
  }

  for (const child of Array.from(group.container.childNodes)) {
    walkNode(child)
  }

  return runs
}

function textRunForTruncation(offset: number, runs: TextRun[]): TextRun | null {
  const containing = runs.find(
    (run) =>
      run.textNode !== null &&
      offset >= run.startOffset &&
      offset < run.startOffset + run.text.length,
  )
  if (containing) return containing

  return runs.find((run) => run.textNode !== null && run.startOffset > offset) ?? null
}

// MARK: - Signatures

const SIGNATURE_WRAPPER_SELECTORS: string[] = [
  'div.gmail_signature',
  'div.gmail_signature_prefix',
  'div[data-smartmail="gmail_signature"]',
  'div[id*="ms-outlook-mobile-signature"]',
  'div[class*="ms-outlook-mobile-signature"]',
  'div.ms-outlook-signature',
  'div[id="Signature"]',
  'div.signature',
  'div[class*="moz-signature"]',
]

const SIGN_OFF_PHRASES = new Set([
  'all the best',
  'best',
  'best regards',
  'best wishes',
  'cheers',
  'kind regards',
  'many thanks',
  'regards',
  'sincerely',
  'thank you',
  'thanks',
  'warm regards',
  'warmly',
  'yours truly',
])

const SIGN_OFF_PHRASES_FOR_PREFIX_MATCHING = [...SIGN_OFF_PHRASES].sort((a, b) => {
  if (a.length === b.length) return a < b ? -1 : 1
  return b.length - a.length
})

function removeSignatureWrappers(document: Document): void {
  for (const selector of SIGNATURE_WRAPPER_SELECTORS) {
    for (const element of Array.from(document.querySelectorAll(selector))) {
      const replacement = preservedSignOffHTML(element)
      if (replacement.length === 0) {
        element.remove()
      } else {
        element.insertAdjacentHTML('beforebegin', replacement)
        element.remove()
      }
    }
  }
}

function preservedSignOffHTML(element: Element): string {
  let lines = paragraphAwareText(element)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0)

  if (lines[0] === '--') {
    lines = lines.slice(1)
  }

  if (lines.length === 0) return ''

  if (isLikelyCombinedSignOffAndNameLine(lines[0]!)) {
    return `<div>${escapedHTML(lines[0]!)}</div>`
  }

  if (!isLikelySignOffLine(lines[0]!)) return ''

  const preserved = [lines[0]!]
  if (lines.length > 1 && looksLikeNameLine(lines[1]!)) {
    preserved.push(lines[1]!)
  }

  return `<div>${preserved.map(escapedHTML).join('<br>')}</div>`
}

function isLikelySignOffLine(line: string): boolean {
  const normalized = line
    .toLowerCase()
    .trim()
    .replace(/^\p{P}+/u, '')
    .replace(/\p{P}+$/u, '')
  return SIGN_OFF_PHRASES.has(normalized)
}

function isLikelyCombinedSignOffAndNameLine(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed.length > 60) return false

  const lowercased = trimmed.toLowerCase()
  for (const signOff of SIGN_OFF_PHRASES_FOR_PREFIX_MATCHING) {
    for (const separator of [',', ' ']) {
      const prefix = signOff + separator
      if (!lowercased.startsWith(prefix)) continue
      const remainder = trimmed.slice(prefix.length).trim()
      return looksLikeNameLine(remainder)
    }
  }

  return false
}

function escapedHTML(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

const SIGNATURE_TEXT_MARKERS: RegExp[] = [
  /^\s*--\s*$/i,
  /Sent from my (?:iPhone|iPad|Android|Galaxy|Pixel|Samsung)/i,
  /Sent from (?:Outlook|Mail for Windows|Spark|ProtonMail|BlueMail|Gmail|Yahoo Mail)/i,
  /Get Outlook for/i,
  /This email is confidential/i,
  /This e-mail is meant for only the intended recipient/i,
  /Notice To Recipient:/i,
  /If you are not the intended recipient/i,
  /\*Wire Fraud/i,
  /Wire Fraud is Real/i,
  /Before wiring any money/i,
]

function truncateAtSignatureMarkers(document: Document): void {
  const body = document.body
  if (!body) return
  const textNodes = collectTextNodes(body)
  for (const textNode of textNodes) {
    const text = textNode.data
    for (const pattern of SIGNATURE_TEXT_MARKERS) {
      const match = pattern.exec(text)
      if (match) {
        truncateAtTextNode(textNode, match.index, text)
        return
      }
    }
  }
}

const SIGNATURE_CITY_STATE_ZIP_PATTERN = /^[A-Z][A-Z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$/i

const SIGNATURE_TITLE_KEYWORDS = [
  'director',
  'manager',
  'vp',
  'vice president',
  'president',
  'founder',
  'ceo',
  'cfo',
  'cto',
  'coo',
  'realtor',
  'broker',
  'associate',
  'sales',
  'agent',
  'partner',
  'principal',
  'owner',
  'specialist',
]

const SIGNATURE_ORGANIZATION_KEYWORDS = [
  ' inc',
  ' inc.',
  ' llc',
  ' ltd',
  ' corp',
  ' corp.',
  ' corporation',
  ' company',
  ' co.',
  ' partners',
  ' group',
  ' llp',
  ' lp',
]

const CONTACT_LIST_INTRO_KEYWORDS = ['contact', 'email', 'reviewer', 'recipient']

function truncateTrailingContactSignature(document: Document): void {
  const body = document.body
  if (!body) return
  const lines = visibleLineElements(body, true)
  let lastNonEmpty = -1
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i]!.text.length > 0) {
      lastNonEmpty = i
      break
    }
  }
  if (lastNonEmpty === -1) return
  if (!isContactSignatureLine(lines[lastNonEmpty]!.text)) return

  const scanStart = Math.max(0, lastNonEmpty - 32)
  let contactLineCount = 0
  let signatureStart = lastNonEmpty
  let strongSupportLineCount = 0
  let signatureSupportLineCount = 0
  let nonEmailContactLineCount = 0
  let sawSignOffBeforeSignature = false
  let precedingBodyLine: string | null = null
  let scanIndex = lastNonEmpty

  while (scanIndex >= scanStart) {
    const text = lines[scanIndex]!.text
    if (text.length === 0) {
      const previousNonEmptyIndex = previousNonEmptyLineIndex(scanIndex, scanStart, lines)
      if (previousNonEmptyIndex === null) {
        break
      }

      const previousText = lines[previousNonEmptyIndex]!.text
      if (!isContactSignatureLine(previousText) && !isSignatureSupportLine(previousText)) {
        precedingBodyLine = previousText
        break
      }

      scanIndex = previousNonEmptyIndex
      continue
    }

    if (isLikelySignOffLine(text)) {
      sawSignOffBeforeSignature = true
      break
    }

    if (isContactSignatureLine(text)) {
      contactLineCount += 1
      if (hasNonEmailContactSignal(text)) {
        nonEmailContactLineCount += 1
      }
      signatureStart = scanIndex
      scanIndex -= 1
      continue
    }

    if (!isSignatureSupportLine(text)) {
      precedingBodyLine = text
      break
    }

    if (isStrongSignatureSupportLine(text)) {
      strongSupportLineCount += 1
    }
    signatureSupportLineCount += 1
    signatureStart = scanIndex
    scanIndex -= 1
  }

  if (contactLineCount < 2) return

  let nonEmptyRemovalCount = 0
  for (let i = signatureStart; i <= lastNonEmpty; i++) {
    if (lines[i]!.text.length > 0) nonEmptyRemovalCount += 1
  }
  if (nonEmptyRemovalCount < 3) return
  if (precedingBodyLine !== null && isContactListIntroLine(precedingBodyLine)) {
    return
  }
  const hasStrongSignal = sawSignOffBeforeSignature || strongSupportLineCount > 0
  const hasWeakSinglePersonSignature =
    signatureSupportLineCount === 1 && nonEmailContactLineCount > 0
  if (!hasStrongSignal && !hasWeakSinglePersonSignature) {
    return
  }

  for (let index = signatureStart; index <= lastNonEmpty; index++) {
    lines[index]!.element.remove()
  }
}

function previousNonEmptyLineIndex(
  index: number,
  lowerBound: number,
  lines: VisibleLineElement[],
): number | null {
  if (index <= lowerBound) return null

  for (let candidate = index - 1; candidate >= lowerBound; candidate--) {
    if (lines[candidate]!.text.length > 0) {
      return candidate
    }
  }

  return null
}

function isContactSignatureLine(text: string): boolean {
  if (text.length === 0) return false
  if (EMAIL_ADDRESS_PATTERN.test(text)) return true
  if (WEB_URL_PATTERN.test(text)) return true
  if (PHONE_PATTERN.test(text)) return true
  if (ADDRESS_KEYWORD_PATTERN.test(text)) return true
  if (SIGNATURE_CITY_STATE_ZIP_PATTERN.test(text)) return true
  if (STANDALONE_CONTACT_LABEL_PATTERN.test(text)) return true
  return false
}

function containsEmailAddress(text: string): boolean {
  return EMAIL_ADDRESS_PATTERN.test(text)
}

function hasNonEmailContactSignal(text: string): boolean {
  if (WEB_URL_PATTERN.test(text)) return true
  if (PHONE_PATTERN.test(text)) return true
  if (ADDRESS_KEYWORD_PATTERN.test(text)) return true
  if (SIGNATURE_CITY_STATE_ZIP_PATTERN.test(text)) return true
  if (STANDALONE_CONTACT_LABEL_PATTERN.test(text)) return true
  return false
}

function isSignatureSupportLine(text: string): boolean {
  if (text.length === 0) return false
  if (isStrongSignatureSupportLine(text)) {
    return true
  }
  if (looksLikeSignatureNameSupportLine(text)) {
    return true
  }
  return false
}

function isStrongSignatureSupportLine(text: string): boolean {
  const lowercased = text.toLowerCase()
  if (SIGNATURE_TITLE_KEYWORDS.some((keyword) => lowercased.includes(keyword))) {
    return true
  }
  if (SIGNATURE_ORGANIZATION_KEYWORDS.some((keyword) => lowercased.includes(keyword))) {
    return true
  }
  return false
}

function isContactListIntroLine(text: string): boolean {
  const lowercased = text.trim().toLowerCase()
  return lowercased.endsWith(':') && CONTACT_LIST_INTRO_KEYWORDS.some((k) => lowercased.includes(k))
}

function looksLikeSignatureNameSupportLine(text: string): boolean {
  const trimmed = text.trim()
  if (!looksLikeNameLine(trimmed)) return false

  if (/[.,:;!?]/.test(trimmed)) return false

  const words = trimmed.split(/\s+/).filter((w) => w.length > 0)
  return words.every((word) => {
    const firstLetter = [...word].find((ch) => /\p{L}/u.test(ch))
    if (firstLetter === undefined) return false
    return firstLetter !== firstLetter.toLowerCase()
  })
}

// MARK: - Footer containers

const FOOTER_SELECTORS: string[] = [
  'div[class*="footer"]',
  'table[class*="footer"]',
  'div[id*="footer"]',
  'table[class*="social"]',
  'div[class*="social"]',
  'div[class*="unsubscribe"]',
  'p[class*="unsubscribe"]',
  'table[class*="signature"]',
]

const SIGNATURE_CLASS_TOKENS = new Set(['sig', 'signature'])

const MAJORITY_TEXT_GUARD_RATIO = 0.6

function removeFooterContainers(document: Document): void {
  const body = document.body
  if (!body) return
  const documentTextLength = visibleTextLength(body)

  for (const selector of FOOTER_SELECTORS) {
    for (const element of Array.from(document.querySelectorAll(selector))) {
      removeUnlessMajorityText(element, documentTextLength)
    }
  }
  removeSignatureTokenDivs(document, documentTextLength)
}

function removeSignatureTokenDivs(document: Document, documentTextLength: number): void {
  for (const element of Array.from(document.querySelectorAll('div[class]'))) {
    const classAttribute = (element.getAttribute('class') ?? '').toLowerCase()
    const tokens = classAttribute.split(/[-_\s]+/).filter((t) => t.length > 0)
    if (tokens.some((token) => SIGNATURE_CLASS_TOKENS.has(token))) {
      removeUnlessMajorityText(element, documentTextLength)
    }
  }
}

function removeUnlessMajorityText(element: Element, documentTextLength: number): void {
  if (documentTextLength <= 0) {
    element.remove()
    return
  }

  const elementTextLength = visibleTextLength(element)
  if (elementTextLength >= documentTextLength * MAJORITY_TEXT_GUARD_RATIO) {
    return
  }
  element.remove()
}

function visibleTextLength(element: Element): number {
  return collapsedElementText(element).trim().length
}
