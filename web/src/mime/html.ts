// DOM-based quote/signature stripping over parsed HTML.
// Port of esc-chatmail/Services/EmailDOM/EmailDOMQuoteRemover*.swift
// (SwiftSoup → DOMParser).

import { collapsedElementText, paragraphAwareText, parseHtmlDocument } from './htmlText'
import {
  EMAIL_ADDRESS_PATTERN,
  FROM_HEADER_PREFIXES,
  SENT_OR_DATE_HEADER_PREFIXES,
  STANDALONE_CONTACT_LABEL_PATTERN,
  SUBJECT_HEADER_PREFIXES,
  TO_HEADER_PREFIXES,
  WEB_URL_PATTERN,
  ADDRESS_KEYWORD_PATTERN,
  SIGN_OFF_PHRASES,
  DESCRIPTIVE_PHONE_LINE_PATTERN,
  isStrongSignatureSupportLine,
  shouldPreserveSignatureNameLine,
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

interface VisibleLineLink {
  rawTarget: string
  visibleText: string
}

interface InlineHeaderLine {
  links: VisibleLineLink[]
  nonLinkText: string
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

function inlineHeaderLines(element: Element, splitBlockLines = false): InlineHeaderLine[] {
  const result: InlineHeaderLine[] = []
  let currentText = ''
  let currentNonLinkText = ''
  let currentLinks = new Map<Element, VisibleLineLink>()
  let currentStartTextNode: Text | null = null
  let currentStartOffset = 0

  const appendText = (rawText: string, textNode: Text, anchor: Element | null): void => {
    const normalized = rawText.replace(/\u00A0/g, ' ')
    // Keep actual anchor fragments together, including formatting inside a word.
    // Shared line text/offsets below retain their existing whitespace contract.
    if (anchor) {
      const link = currentLinks.get(anchor) ?? {
        rawTarget: anchor.getAttribute('href') ?? '',
        visibleText: '',
      }
      link.visibleText += normalized
      currentLinks.set(anchor, link)
    } else {
      currentNonLinkText += normalized
    }
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
      links: [...currentLinks.values()]
        .map((link) => ({ ...link, visibleText: normalizedVisibleLineText(link.visibleText) }))
        .filter((link) => link.visibleText.length > 0),
      nonLinkText: normalizedVisibleLineText(currentNonLinkText),
      startTextNode: currentStartTextNode,
      startOffset: currentStartOffset,
    })
    currentText = ''
    currentNonLinkText = ''
    currentLinks = new Map()
    currentStartTextNode = null
    currentStartOffset = 0
  }

  const walkNode = (node: Node, anchor: Element | null = null): void => {
    if (node.nodeType === NODE_TEXT) {
      appendText((node as Text).data, node as Text, anchor)
      return
    }
    if (node.nodeType !== NODE_ELEMENT) return
    const element = node as Element
    if (isHiddenFromVisibleText(element)) return
    if (tagName(element) === 'br') {
      finishLine()
      return
    }

    // Table directory records may use paragraphs instead of <br> sublines.
    // Only the signature table guard opts into these boundaries.
    const isBlockLine = splitBlockLines && VISIBLE_LINE_ELEMENT_TAGS.has(tagName(element))
    if (isBlockLine && currentText) finishLine()
    for (const child of Array.from(element.childNodes)) {
      walkNode(child, tagName(element) === 'a' ? element : anchor)
    }
    if (isBlockLine && currentText) finishLine()
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
function truncateAtTextNode(
  textNode: Text,
  matchStart: number,
  fullText: string,
  boundary: Element | null = null,
): void {
  removeAllSiblingsAfter(textNode)

  let current: Element | null = textNode.parentElement
  while (current) {
    if (tagName(current) === 'body' || current === boundary) break
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

  if (lines.length <= 1 || !shouldPreserveSignatureNameLine(lines[1]!)) return ''
  const preserved = [lines[0]!, lines[1]!]

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
      return shouldPreserveSignatureNameLine(remainder)
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

const SIGNATURE_PHONE_PATTERN = /(^|[^\p{L}\p{N}_])(\+?\(?\p{Nd}(?:[\p{Nd}\s().-]*\p{Nd})?)/gu

const SIGNATURE_DECIMAL_DIGIT_PATTERN = /\p{Nd}/u

const SIGNATURE_PHONE_FORMAT_SEPARATOR_PATTERN = /[\s.-]/u

const SIGNATURE_PHONE_KNOWN_LABEL_PATTERN =
  /^(?:m|c|o|f|d|t|p|w|h|tel|tél|telephone(?:\s+number)?|téléphone(?:\s+number)?|telefono|teléfono|telefon|phone(?:\s+number)?|cell(?:ular)?(?:\s+(?:phone|number))?|mobile(?:\s+(?:phone|number))?|office(?:\s+phone)?|m[oó]vil|portable|work(?:\s+phone)?|home(?:\s+phone)?|direct(?:\s+(?:phone|line))?|desk(?:\s+(?:phone|line))?|main(?:\s+(?:phone|line))?|fax)\s*(?:[:.]|\|)?$/iu

const SIGNATURE_PHONE_EXTENSION_PATTERN = /^(?:x|ext\.?|extension|#)\s*:?\s*\p{Nd}+\s*[.,;]?$/iu

const SIGNATURE_PHONE_SUFFIX_LABEL_PATTERN =
  /^(?:\([\p{L}\p{M}][\p{L}\p{M}-]{0,20}\)|mobile|cell|office|work|home|direct|desk|main|fax)\s*[.,;]?$/iu

const SIGNATURE_NON_PHONE_DATE_PATTERN =
  /^(?:(?:19|20)\p{Nd}{2}(?:-|\.)(?:\p{Nd}{1,2}(?:-|\.)\p{Nd}{1,2}|\p{Nd}{4})|\p{Nd}{1,2}(?:-|\.)\p{Nd}{1,2}(?:-|\.)(?:19|20)\p{Nd}{2})$/u
const SIGNATURE_TIME_RANGE_PATTERN =
  /^(?:[01]?\d|2[0-3])[.:]?[0-5]\d-(?:(?:[01]?\d|2[0-3])[.:]?[0-5]\d|24[.:]?00)$/
const SIGNATURE_BARE_HOURS_LABEL_PATTERN = /^after[ -]hours\s*:$/i

// A bare whitespace rewrite doubled existing separators and failed the empty-segment guard.
const SIGNATURE_INLINE_PHONE_LABEL_SEPARATOR_PATTERN =
  /(?:\s*[|•│┃¦]\s*|\s+)(?=(?:[mcofdtpwh]|tel|telephone|phone|cell|mobile|office|work|home|direct|desk|main|fax)\s*:)/gi

const CONTACT_LIST_INTRO_KEYWORDS = ['contact', 'email', 'reviewer', 'recipient']

interface SignatureLine extends VisibleLineElement {
  links: VisibleLineLink[]
  nonLinkText: string
  startTextNode: Text | null
  startOffset: number
}

// Expand only signature scanning; quote/header passes retain their existing line units.
function signatureLines(body: Element): SignatureLine[] {
  return visibleLineElements(body, true).flatMap((line) => {
    const element = line.element
    const cells =
      tagName(element) === 'tr'
        ? Array.from(element.children).filter((cell) => ['td', 'th'].includes(tagName(cell)))
        : []
    if (cells.length > 0 || element.querySelector('br')) {
      return (cells.length > 0 ? cells : [element]).flatMap((cell) =>
        inlineHeaderLines(cell).map((subline) => ({ ...subline, element })),
      )
    }
    const projected = inlineHeaderLines(element)[0]!
    return [
      {
        ...line,
        links: projected.links,
        nonLinkText: projected.nonLinkText,
        startTextNode: null,
        startOffset: 0,
      },
    ]
  })
}

// Inclusive backward distance: the terminal line plus 80 prior slots; blanks consume slots.
const DOM_SIGNATURE_LOOKBACK = 80

function truncateTrailingContactSignature(document: Document): void {
  const body = document.body
  if (!body) return
  const lines = signatureLines(body)
  let lastNonEmpty = -1
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i]!.text.length > 0) {
      lastNonEmpty = i
      break
    }
  }
  if (lastNonEmpty === -1) return
  let lastContact = lastNonEmpty
  let tailCount = 0
  while (!isTrailingSignatureContact(lines[lastContact]!)) {
    if (
      isContactSignatureLine(lines[lastContact]!.text) ||
      tailCount >= 3 ||
      !isSignatureTailLine(lines[lastContact]!.text)
    )
      return
    const previous = previousNonEmptyLineIndex(lastContact, 0, lines)
    if (previous === null) return
    tailCount += 1
    lastContact = previous
  }

  const scanStart = Math.max(0, lastNonEmpty - DOM_SIGNATURE_LOOKBACK)
  let contactLineCount = 0
  let fillerCount = 0
  let signatureStart = lastContact
  let strongSupportLineCount = 0
  let signatureSupportLineCount = 0
  let nonEmailContactLineCount = 0
  let sawSignOffBeforeSignature = false
  let precedingBodyLine: string | null = null
  let scanIndex = lastContact

  while (scanIndex >= scanStart) {
    const text = lines[scanIndex]!.text
    if (text.length === 0) {
      const previousNonEmptyIndex = previousNonEmptyLineIndex(scanIndex, scanStart, lines)
      if (previousNonEmptyIndex === null) {
        break
      }

      const previousText = lines[previousNonEmptyIndex]!.text
      if (
        !isContactSignatureLine(previousText) &&
        !trailingSignatureLinkContact(lines[previousNonEmptyIndex]!) &&
        !isSignatureSupportLine(previousText) &&
        !isLikelySignOffLine(previousText) &&
        !isSignatureProductList(previousText)
      ) {
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

    if (isContactSignatureLine(text) || trailingSignatureLinkContact(lines[scanIndex]!)) {
      if (!isTrailingSignatureContact(lines[scanIndex]!)) {
        precedingBodyLine = text
        break
      }
      contactLineCount += 1
      if (
        hasNonEmailContactSignal(text) ||
        trailingSignatureLinkContact(lines[scanIndex]!) === 'phone'
      ) {
        nonEmailContactLineCount += 1
      }
      signatureStart = scanIndex
      scanIndex -= 1
      continue
    }

    if (isSignatureProductList(text)) {
      // Once the name/title has been reached, a product list above it belongs to the body.
      if (contactLineCount === 0 || fillerCount >= 3 || signatureSupportLineCount > 0) {
        precedingBodyLine = text
        break
      }
      fillerCount += 1
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

  if (contactLineCount < 2 || isSignatureProductList(lines[signatureStart]!.text)) return

  const candidateLines = lines.slice(signatureStart, lastNonEmpty + 1)
  if (hasRepeatedPersonContactRecords(candidateLines)) return
  if (
    shouldPreserveContactTable(
      candidateLines,
      sawSignOffBeforeSignature || strongSupportLineCount > 0,
    )
  ) {
    return
  }

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

  // Widening the range for metadata must not claim unmarked body media,
  // including images between the contacts and footer or inside a footer line.
  if (tailCount > 0) {
    for (let index = signatureStart; index <= lastNonEmpty; index++) {
      if (containsSignatureTailMedia(lines[index]!.element)) return
    }
  }
  let preservedHTML = ''
  if (sawSignOffBeforeSignature) {
    if (
      shouldPreserveSignatureNameLine(lines[signatureStart]!.text) &&
      !isContactSignatureLine(lines[signatureStart]!.text) &&
      !trailingSignatureLinkContact(lines[signatureStart]!)
    ) {
      preservedHTML = `<div>${escapedHTML(lines[scanIndex]!.text)}<br>${escapedHTML(lines[signatureStart]!.text)}</div>`
    }
    signatureStart = scanIndex
  }
  // Preserve unmarked media after the signature; only explicit wrappers own their images.
  removeSignatureLines(lines, signatureStart, lastNonEmpty, preservedHTML)
}

function hasRepeatedPersonContactRecords(
  lines: Pick<InlineHeaderLine, 'text' | 'links' | 'nonLinkText'>[],
): boolean {
  let pendingName = false
  let personRecords = 0
  for (const line of lines) {
    if (isTrailingSignatureContactLine(line.text) || trailingSignatureLinkContact(line)) {
      if (pendingName) {
        personRecords += 1
        if (personRecords > 1) return true
        pendingName = false
      }
    } else if (
      isStrongSignatureSupportLine(line.text) ||
      (looksLikeSignatureNameSupportLine(line.text) && shouldPreserveSignatureNameLine(line.text))
    ) {
      // Multiple name/company lines before one contact group still form one record.
      pendingName = true
    }
  }
  return false
}

// Column headings and repeated person records distinguish directories from signatures.
function shouldPreserveContactTable(lines: SignatureLine[], hasStrongSignal: boolean): boolean {
  const tables = new Set<Element>()
  const cells = new Set<Element>()
  for (const line of lines) {
    if (!line.text) continue
    const element = line.startTextNode?.parentElement ?? line.element
    const table = element.closest('table')
    if (table) tables.add(table)
    const cell = element.closest('td, th')
    if (cell) cells.add(cell)
  }
  // A name, email, and phone in separate columns are insufficient evidence on their own.
  if (!hasStrongSignal && cells.size > 1) return true

  const fieldHeadings = new Set([
    'name',
    'full name',
    'role',
    'title',
    'email',
    'e-mail',
    'phone',
    'telephone',
  ])
  for (const table of tables) {
    let personRows = 0
    for (const row of Array.from(table.querySelectorAll('tr'))) {
      if (row.closest('table') !== table) continue
      const rowCells = Array.from(row.children).filter((cell) =>
        ['td', 'th'].includes(tagName(cell)),
      )
      if (rowCells.some((cell) => tagName(cell) === 'th')) return true
      const cellLines = rowCells.map((cell) => inlineHeaderLines(cell, true))
      const texts = cellLines.map((lines) =>
        lines
          .map((line) => line.text)
          .join(' ')
          .trim(),
      )
      if (
        texts.filter((text) => fieldHeadings.has(text.toLowerCase().replace(/:$/, ''))).length >= 2
      ) {
        return true
      }
      // Direct cell names can be absent from the outer scan when child blocks follow them.
      if (hasRepeatedPersonContactRecords(cellLines.flat())) return true
      // An explicit contact label can resemble a name; it cannot also establish a person row.
      const nameCandidates = [
        ...texts.filter(
          (_, index) => !cellLines[index]!.some((line) => trailingSignatureLinkContact(line)),
        ),
        ...cellLines
          .flat()
          .filter((line) => !trailingSignatureLinkContact(line))
          .map((line) => line.text),
      ]
      if (
        nameCandidates.some(
          (text) =>
            looksLikeSignatureNameSupportLine(text) && shouldPreserveSignatureNameLine(text),
        ) &&
        (texts.some(isContactSignatureLine) ||
          cellLines.some((lines) => lines.some((line) => trailingSignatureLinkContact(line))))
      ) {
        personRows += 1
        if (personRows > 1) return true
      }
    }
  }
  return false
}

// Trim shared blocks; remove whole rows only when no authored prefix shares that row.
function removeSignatureLines(
  lines: SignatureLine[],
  start: number,
  end: number,
  html: string,
): void {
  const first = lines[start]!
  // Text embedded in a diagram is part of the media, not a safe signature boundary.
  if (first.startTextNode?.parentElement?.closest('svg, video, audio, object, iframe, canvas'))
    return
  // A CID link or background on the boundary's ancestor owns content too.
  let parent = first.startTextNode?.parentElement
  while (parent) {
    if (hasSignatureMediaAttributes(parent)) return
    if (parent === first.element) break
    parent = parent.parentElement
  }
  // Sub-line truncation must preserve the same unmarked trailing media as whole-block cleanup.
  if (first.startTextNode) {
    if (containsMediaAfterSignature(first.startTextNode, first.element)) return
  } else if (containsSignatureTailMedia(first.element)) {
    return
  }
  const checked = new Set([first.element])
  for (const line of lines.slice(start, end + 1)) {
    if (checked.has(line.element)) continue
    checked.add(line.element)
    if (containsSignatureTailMedia(line.element)) return
  }
  const hasPrefix =
    lines.slice(0, start).some((line) => line.element === first.element && line.text.length > 0) ||
    hasMediaBeforeSignature(first.startTextNode, first.element)
  if (hasPrefix && first.startTextNode) {
    truncateAtTextNode(
      first.startTextNode,
      first.startOffset,
      first.startTextNode.data,
      first.element,
    )
    if (html) {
      const target =
        tagName(first.element) === 'tr'
          ? (first.element.lastElementChild ?? first.element)
          : first.element
      target.insertAdjacentHTML('beforeend', html)
    }
  } else {
    if (html) {
      if (tagName(first.element) === 'tr') {
        const row = first.element.ownerDocument.createElement('tr')
        const cell = first.element.ownerDocument.createElement('td')
        cell.innerHTML = html
        row.append(cell)
        first.element.before(row)
      } else {
        first.element.insertAdjacentHTML('beforebegin', html)
      }
    }
    first.element.remove()
  }
  const removed = new Set([first.element])
  for (let index = start; index <= end; index++) {
    const element = lines[index]!.element
    if (!removed.has(element)) {
      removed.add(element)
      element.remove()
    }
  }
}

function containsMediaAfterSignature(boundary: Text, root: Element): boolean {
  let reachedBoundary = false
  const stack: Node[] = [root]
  while (stack.length > 0) {
    const node = stack.pop()!
    if (node === boundary) {
      reachedBoundary = true
      continue
    }
    if (reachedBoundary && node.nodeType === NODE_ELEMENT) {
      if (containsSignatureTailMedia(node as Element)) return true
      // The subtree was checked as a whole.
      continue
    }
    stack.push(...Array.from(node.childNodes).reverse())
  }
  return false
}

function hasSignatureMediaAttributes(element: Element): boolean {
  return (
    ['src', 'srcset', 'background', 'poster'].some((name) => element.hasAttribute(name)) ||
    ['href', 'xlink:href'].some((name) => /cid:/i.test(element.getAttribute(name) ?? '')) ||
    /url\s*\(/i.test(element.getAttribute('style') ?? '')
  )
}

function hasMediaBeforeSignature(boundary: Text | null, root: Element): boolean {
  if (!boundary) return false
  const stack: Node[] = [root]
  while (stack.length > 0) {
    const node = stack.pop()!
    if (node === boundary) return false
    if (node.nodeType === NODE_ELEMENT) {
      const element = node as Element
      if (
        ['img', 'picture', 'svg', 'video', 'audio', 'object', 'embed', 'iframe', 'canvas'].includes(
          tagName(element),
        ) ||
        hasSignatureMediaAttributes(element)
      )
        return true
    }
    stack.push(...Array.from(node.childNodes).reverse())
  }
  return false
}

// Link targets are evidence only for this pass; quote/header and extracted text stay unchanged.
function trailingSignatureLinkContact(
  line: Pick<InlineHeaderLine, 'links' | 'nonLinkText'>,
): 'email' | 'phone' | null {
  if (line.links.length === 0) return null
  const surrounding = line.nonLinkText.replace(
    /^[\s|•│┃¦:;,.()[\]–—-]+|[\s|•│┃¦:;,.()[\]–—-]+$/gu,
    '',
  )
  if (
    surrounding &&
    !/^(?:email|e-mail|e|tel|telephone|phone|t|office|work|direct|mobile|cell|fax)$/i.test(
      surrounding,
    )
  ) {
    return null
  }
  const surroundingIsEmail = /^(?:email|e-mail|e)$/i.test(surrounding)
  let kind: 'email' | 'phone' = 'email'
  for (const link of line.links) {
    if (/[\r\n\u2028\u2029]/.test(link.rawTarget)) return null
    if (/^mailto:/i.test(link.rawTarget)) {
      const target = /^mailto:([^?]+)(?:\?[^\s]*)?$/i.exec(link.rawTarget)?.[1]
      const local = target?.split('@')[0] ?? ''
      if (
        (surrounding && !surroundingIsEmail) ||
        !target ||
        local.startsWith('.') ||
        local.endsWith('.') ||
        local.includes('..') ||
        !/^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$/i.test(
          target,
        ) ||
        !/^(?:email|e-mail)(?: me| us)?$/i.test(link.visibleText)
      )
        return null
    } else if (/^tel:\+?[0-9(). -]+$/i.test(link.rawTarget)) {
      const digits = link.rawTarget.replace(/\D/g, '').length
      if (
        (surrounding && surroundingIsEmail) ||
        digits < 7 ||
        digits > 15 ||
        !/^(?:tel|telephone|phone|call(?: me| us| the office)?)$/i.test(link.visibleText)
      )
        return null
      kind = 'phone'
    } else {
      return null
    }
  }
  return kind
}

function isTrailingSignatureContact(line: SignatureLine): boolean {
  return isTrailingSignatureContactLine(line.text) || trailingSignatureLinkContact(line) !== null
}

// Contact tokens may have labels or a name, but must not swallow an authored instruction.
// Keep the broader contact predicate unchanged for quote/header detection.
export function isTrailingSignatureContactLine(text: string): boolean {
  if (!isContactSignatureLine(text)) return false
  const hasLink = EMAIL_ADDRESS_PATTERN.test(text) || WEB_URL_PATTERN.test(text)
  if (!hasLink) {
    return (
      isSignaturePhoneLine(text) ||
      SIGNATURE_CITY_STATE_ZIP_PATTERN.test(text) ||
      STANDALONE_CONTACT_LABEL_PATTERN.test(text) ||
      isSignaturePostalLine(text)
    )
  }
  const remainder = text
    .replace(new RegExp(EMAIL_ADDRESS_PATTERN.source, 'gi'), '')
    .replace(new RegExp(WEB_URL_PATTERN.source, 'gi'), '')
    .replace(/mailto:|[<>]/gi, '')
  return remainder.split(/[|•│┃¦]/u).every((segment) => {
    const label = segment
      .replace(/^[\s<>()[\]:;,.]+|[\s<>()[\]:;,.]+$/g, '')
      .replace(/^(?:email|e-mail|website|web|url|tel|phone|e|w|t)\s*:?\s+/i, '')
    return (
      label.length === 0 ||
      ['e', 'email', 'e-mail', 'w', 'web', 'website', 'url'].includes(label.toLowerCase()) ||
      looksLikeSignatureNameSupportLine(label) ||
      isSignaturePhoneLine(label) ||
      SIGNATURE_CITY_STATE_ZIP_PATTERN.test(label) ||
      isSignaturePostalLine(label)
    )
  })
}

function isSignaturePostalLine(text: string): boolean {
  return (
    /\p{Nd}/u.test(text) &&
    /^(?:\p{Nd}|suite\b|ste\b|floor\b|fl\b)/iu.test(text) &&
    ADDRESS_KEYWORD_PATTERN.test(text)
  )
}

function containsSignatureTailMedia(element: Element): boolean {
  const mediaSelector =
    'img, picture, svg, video, audio, object, embed, iframe, [src], [srcset], [background], [poster]'
  if (element.matches(mediaSelector) || element.querySelector(mediaSelector)) return true
  // CID references also include linked attachments (href/xlink:href).
  if (/cid:/i.test(element.outerHTML)) return true
  return [element, ...element.querySelectorAll('[style]')].some((candidate) =>
    /url\s*\(/i.test(candidate.getAttribute('style') ?? ''),
  )
}

function isSignatureTailLine(text: string): boolean {
  // Match the entire known boilerplate sentence. A heading or keyword match
  // would also swallow authored discussion or a postscript in the same block.
  if (
    /^(?:(?:confidentiality notice|disclaimer)\s*:\s*)?this e-?mail and any attachments are for the exclusive(?: and confidential)? use of the intended recipients?\.?$/i.test(
      text,
    )
  ) {
    return true
  }

  // A whole license/registration identifier is metadata. Sentences containing
  // a number, short slogans, and pipe-separated choices are ambiguous body text.
  if (text.length > 160) return false
  return /^(?:(?:licen[cs]e|registration|npn)\b(?:\s+(?:number|no\.?))?\s*[:#]?\s*[A-Z0-9-]*\d[A-Z0-9-]*|licensed in [A-Z]{2}(?:\s*(?:,|&|\band\b)\s*[A-Z]{2})*\s*[-–—]\s*NPN\s*[:#]?\s*\d[\d-]*)\.?$/i.test(
    text,
  )
}

function isSignatureProductList(text: string): boolean {
  const segments = text.split(/[|•]/)
  return (
    segments.length >= 3 &&
    segments.every((segment) => {
      const words = segment.trim().split(/\s+/).filter(Boolean)
      return (
        words.length >= 1 &&
        words.length <= 3 &&
        !/\p{Nd}/u.test(segment) &&
        !segment.includes('@') &&
        !segment.includes('http') &&
        !segment.includes('www.') &&
        !/[.!?:;]/.test(segment)
      )
    })
  )
}

function previousNonEmptyLineIndex(
  index: number,
  lowerBound: number,
  lines: SignatureLine[],
): number | null {
  if (index <= lowerBound) return null

  for (let candidate = index - 1; candidate >= lowerBound; candidate--) {
    if (lines[candidate]!.text.length > 0) {
      return candidate
    }
  }

  return null
}

export function isContactSignatureLine(text: string): boolean {
  if (text.length === 0) return false
  if (EMAIL_ADDRESS_PATTERN.test(text)) return true
  if (WEB_URL_PATTERN.test(text)) return true
  if (isSignaturePhoneLine(text)) return true
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
  if (isSignaturePhoneLine(text)) return true
  if (ADDRESS_KEYWORD_PATTERN.test(text)) return true
  if (SIGNATURE_CITY_STATE_ZIP_PATTERN.test(text)) return true
  if (STANDALONE_CONTACT_LABEL_PATTERN.test(text)) return true
  return false
}

function isSignaturePhoneLine(text: string): boolean {
  const normalized = text
    .trim()
    .replace(/\s+\/\s+/g, '|')
    .replace(SIGNATURE_INLINE_PHONE_LABEL_SEPARATOR_PATTERN, '|')
  const segments = normalized.split(/[|•│┃¦]/u).map((segment) => segment.trim())
  if (segments.length === 0 || segments.some((segment) => segment.length === 0)) {
    return false
  }

  let foundPhone = false
  let phoneWasLabeled = false
  let requiresClearlyFormattedPhone = false
  for (const segment of segments) {
    if (isSignaturePhoneSegment(segment)) {
      if (requiresClearlyFormattedPhone && !isClearlyFormattedSignaturePhoneSegment(segment)) {
        return false
      }
      const firstDigit = segment.search(SIGNATURE_DECIMAL_DIGIT_PATTERN)
      if (firstDigit >= 0) {
        phoneWasLabeled ||= isStandaloneSignaturePhoneLabel(
          normalizedSignaturePhonePrefix(segment.slice(0, firstDigit)),
        )
      }
      foundPhone = true
      requiresClearlyFormattedPhone = false
      continue
    }

    if (foundPhone) {
      if (!isSignaturePhoneModifier(segment, phoneWasLabeled)) return false
      continue
    }

    if (!isSignaturePhoneLeadingSegment(segment)) return false
    if (isStandaloneSignaturePhoneLabel(segment)) {
      requiresClearlyFormattedPhone = false
    } else if (!isStrongSignatureSupportLine(segment)) {
      requiresClearlyFormattedPhone = true
    }
  }

  return foundPhone
}

function isSignaturePhoneSegment(text: string): boolean {
  let phone: string | undefined
  let phoneStart = -1
  for (const candidateMatch of text.matchAll(SIGNATURE_PHONE_PATTERN)) {
    const boundary = candidateMatch[1] ?? ''
    const candidate = candidateMatch[2] ?? ''
    let digitCount = 0
    for (const character of candidate) {
      if (SIGNATURE_DECIMAL_DIGIT_PATTERN.test(character)) digitCount += 1
    }
    if (digitCount >= 7 && !SIGNATURE_NON_PHONE_DATE_PATTERN.test(candidate)) {
      phone = candidate
      phoneStart = (candidateMatch.index ?? 0) + boundary.length
      break
    }
  }
  if (!phone || phoneStart < 0) return false

  const prefix = normalizedSignaturePhonePrefix(text.slice(0, phoneStart))
  const suffix = text.slice(phoneStart + phone.length)
  if (!isAllowedSignaturePhoneSuffix(suffix)) return false

  const compactCandidate = phone.replace(/\s+/g, '')
  return (
    prefix.length === 0 ||
    SIGNATURE_PHONE_KNOWN_LABEL_PATTERN.test(prefix) ||
    (DESCRIPTIVE_PHONE_LINE_PATTERN.test(text) &&
      !SIGNATURE_NON_PHONE_DATE_PATTERN.test(compactCandidate) &&
      !(
        SIGNATURE_BARE_HOURS_LABEL_PATTERN.test(prefix) &&
        SIGNATURE_TIME_RANGE_PATTERN.test(compactCandidate)
      ))
  )
}

function isSignaturePhoneLeadingSegment(text: string): boolean {
  if (isStandaloneSignaturePhoneLabel(text) || isStrongSignatureSupportLine(text)) {
    return true
  }

  const words = text.split(/\s+/).filter((word) => word.length > 0)
  return words.length >= 2 && looksLikeSignatureNameSupportLine(text)
}

const SIGNATURE_WEEKDAY = String.raw`(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)`
const SIGNATURE_TIME = String.raw`(?:\d{1,2}(?::\d{2})?\s*(?:am|pm))`
const SIGNATURE_DAY_RANGE = SIGNATURE_WEEKDAY + String.raw`\s*[-–—]\s*` + SIGNATURE_WEEKDAY
const SIGNATURE_TIME_RANGE = SIGNATURE_TIME + String.raw`\s*[-–—]\s*` + SIGNATURE_TIME
const SIGNATURE_BUSINESS_HOURS_PATTERN = new RegExp(
  '^(?:' +
    SIGNATURE_DAY_RANGE +
    String.raw`(?:\s+` +
    SIGNATURE_TIME_RANGE +
    ')?|' +
    SIGNATURE_TIME_RANGE +
    '|24/7)$',
  'i',
)

function isSignaturePhoneModifier(text: string, allowsBusinessHours: boolean): boolean {
  return (
    SIGNATURE_PHONE_EXTENSION_PATTERN.test(text) ||
    SIGNATURE_PHONE_SUFFIX_LABEL_PATTERN.test(text) ||
    isStandaloneSignaturePhoneLabel(text) ||
    (allowsBusinessHours && SIGNATURE_BUSINESS_HOURS_PATTERN.test(text))
  )
}

function isStandaloneSignaturePhoneLabel(text: string): boolean {
  return SIGNATURE_PHONE_KNOWN_LABEL_PATTERN.test(text)
}

function isClearlyFormattedSignaturePhoneSegment(text: string): boolean {
  const firstDigit = text.search(SIGNATURE_DECIMAL_DIGIT_PATTERN)
  if (firstDigit >= 0) {
    const prefix = normalizedSignaturePhonePrefix(text.slice(0, firstDigit))
    if (isStandaloneSignaturePhoneLabel(prefix)) return true
  }

  if (/[+():]/.test(text)) return true

  let separatorCount = 0
  for (const character of text) {
    if (SIGNATURE_PHONE_FORMAT_SEPARATOR_PATTERN.test(character)) {
      separatorCount += 1
    }
  }
  const lowercased = text.toLowerCase()
  return separatorCount >= 2 || lowercased.includes('ext') || lowercased.includes('x')
}

function normalizedSignaturePhonePrefix(rawPrefix: string): string {
  let prefix = rawPrefix.trim()
  while (prefix.endsWith('+') || prefix.endsWith('(')) {
    prefix = prefix.slice(0, -1).trim()
  }
  return prefix
}

function isAllowedSignaturePhoneSuffix(rawSuffix: string): boolean {
  let suffix = rawSuffix.trim()
  if (/^[.,;]/.test(suffix)) {
    suffix = suffix.slice(1).trim()
  }
  if (suffix.length === 0) return true

  return (
    SIGNATURE_PHONE_EXTENSION_PATTERN.test(suffix) ||
    SIGNATURE_PHONE_SUFFIX_LABEL_PATTERN.test(suffix)
  )
}

export function isSignatureSupportLine(text: string): boolean {
  if (text.length === 0) return false
  if (isStrongSignatureSupportLine(text)) {
    return true
  }
  if (looksLikeSignatureNameSupportLine(text)) {
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
