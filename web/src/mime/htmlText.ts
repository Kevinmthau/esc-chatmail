// HTML → plain-text extraction.
// Ports TextProcessing.extractPlainText (markup detection + malformed-HTML
// regex recovery), EmailDOMTextExtractor (paragraph-aware DOM walk),
// EmailDOMFragmentParser (table-fragment context parsing) and the
// standalone-attribution line filter of ChatBubbleTextProcessor.

import { decodeHtmlEntities } from './decode'

// MARK: - DOM parsing

export function parseHtmlDocument(html: string): Document {
  return new DOMParser().parseFromString(html, 'text/html')
}

/**
 * EmailDOMFragmentParser.parse: a fragment that opens with a table section
 * is parsed inside its required parent context so the HTML5 "in body"
 * insertion mode does not drop the rows and cells (leaving bare text under
 * `<body>`). The context element's children become the body's children, so
 * fragment-in → fragment-out callers still read `body.innerHTML`.
 */
export function parseHtmlFragmentDocument(html: string, inputIsFragment: boolean): Document {
  if (inputIsFragment) {
    const contextTagName = tableFragmentContextTagName(html)
    if (contextTagName !== null) {
      return parseFragmentInContext(html, contextTagName)
    }
  }
  return parseHtmlDocument(html)
}

function parseFragmentInContext(html: string, contextTagName: string): Document {
  const document = parseHtmlDocument('')
  const body = document.body
  if (!body) {
    return parseHtmlDocument(html)
  }

  // Setting innerHTML on a detached element runs the fragment parsing
  // algorithm with that element as context (the DOM counterpart of
  // SwiftSoup's Parser.parseFragment(html, context, baseUri)).
  const context = document.createElement(contextTagName)
  context.innerHTML = html
  for (const node of Array.from(context.childNodes)) {
    body.appendChild(node)
  }
  return document
}

function tableFragmentContextTagName(html: string): string | null {
  const tagName = leadingOpeningTagName(html)
  if (tagName === null) return null

  switch (tagName) {
    case 'caption':
    case 'colgroup':
    case 'tbody':
    case 'tfoot':
    case 'thead':
      return 'table'
    case 'col':
      return 'colgroup'
    case 'tr':
      return 'tbody'
    case 'td':
    case 'th':
      return 'tr'
    default:
      return null
  }
}

function leadingOpeningTagName(html: string): string | null {
  let index = 0

  while (index < html.length) {
    while (index < html.length && /\s/.test(html[index]!)) {
      index += 1
    }
    if (index >= html.length) return null
    if (html[index] !== '<') return null

    const afterOpen = index + 1
    if (afterOpen >= html.length) return null

    if (html.startsWith('!--', afterOpen)) {
      const commentEnd = html.indexOf('-->', afterOpen)
      if (commentEnd === -1) return null
      index = commentEnd + 3
      continue
    }

    if (!/\p{L}/u.test(html[afterOpen]!)) {
      return null
    }

    let nameEnd = afterOpen
    while (nameEnd < html.length && isTagNameCharacter(html[nameEnd]!)) {
      nameEnd += 1
    }

    return html.slice(afterOpen, nameEnd).toLowerCase()
  }

  return null
}

const NODE_ELEMENT = 1
const NODE_TEXT = 3

// MARK: - Paragraph-aware DOM text extraction

const BLOCK_TAGS = new Set([
  'p',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'main',
  'nav',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'pre',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'address',
  'figure',
  'figcaption',
  'hr',
])

const CELL_TAGS = new Set(['td', 'th'])

const INVISIBLE_TAGS = new Set([
  'script',
  'style',
  'head',
  'title',
  'meta',
  'link',
  'noscript',
  'template',
])

function isCollapseWhitespace(ch: string): boolean {
  if (ch === '\n') return false
  return /\s/.test(ch)
}

function stripZeroWidth(text: string): string {
  return text.replace(/(?:\u200B|\u200C|\u200D|\uFEFF)/g, '')
}

class TextBuffer {
  string = ''
  private pendingInlineSpace = false
  private blockBoundary = true // suppresses leading whitespace

  appendText(text: string): void {
    if (text.length === 0) return

    const cleaned = stripZeroWidth(text)
    if (cleaned.length === 0) return

    let startIndex = 0
    if (this.blockBoundary) {
      while (startIndex < cleaned.length && isCollapseWhitespace(cleaned[startIndex]!)) {
        startIndex += 1
      }
      if (startIndex === cleaned.length) {
        return
      }
    }

    let collapsed = ''
    let lastWasWhitespace = false
    for (const char of cleaned.slice(startIndex)) {
      if (isCollapseWhitespace(char)) {
        if (!lastWasWhitespace) {
          collapsed += ' '
        }
        lastWasWhitespace = true
      } else {
        collapsed += char
        lastWasWhitespace = false
      }
    }

    if (this.pendingInlineSpace || (collapsed.startsWith(' ') && this.string.length > 0)) {
      if (!this.string.endsWith(' ') && !this.string.endsWith('\n')) {
        this.string += ' '
      }
    }

    const trimmed = collapsed.startsWith(' ') ? collapsed.slice(1) : collapsed
    if (trimmed.length === 0) return

    this.string += trimmed
    this.pendingInlineSpace = collapsed.endsWith(' ')
    this.blockBoundary = false
  }

  appendInlineSpace(): void {
    this.pendingInlineSpace = true
  }

  flushPendingInlineSpace(): void {
    this.pendingInlineSpace = false
  }

  appendNewline(): void {
    this.pendingInlineSpace = false
    this.string += '\n'
    this.blockBoundary = false
  }

  appendParagraphBreak(): void {
    this.pendingInlineSpace = false
    if (this.string.endsWith('\n\n') || this.string.length === 0) {
      this.blockBoundary = true
      return
    }
    if (this.string.endsWith('\n')) {
      this.string += '\n'
    } else {
      this.string += '\n\n'
    }
    this.blockBoundary = true
  }

  markLineBoundary(): void {
    this.pendingInlineSpace = false
    if (this.string.length === 0 || this.string.endsWith('\n')) {
      this.blockBoundary = true
      return
    }
    this.string += '\n'
    this.blockBoundary = true
  }

  markBlockBoundary(): void {
    this.pendingInlineSpace = false
    if (this.string.length === 0 || this.string.endsWith('\n\n')) {
      this.blockBoundary = true
      return
    }
    if (this.string.endsWith('\n')) {
      this.string += '\n'
    } else {
      this.string += '\n\n'
    }
    this.blockBoundary = true
  }
}

interface ParagraphTextOptions {
  divsAsLineBreaks?: boolean
  shouldSkipElement?: (element: Element) => boolean
}

// SwiftSoup's TextNode.text() (what the iOS walk feeds its buffer) is
// normaliseWhitespace(wholeText): every run of HTML whitespace (space, tab,
// newline, form feed, carriage return, NBSP) becomes one space before the
// buffer sees it, with no <pre> exception. Line structure comes only from
// the explicit block and <br> boundaries below, so a newline that is merely
// source wrapping (Outlook/Word hard-wrap paragraphs at ~76 columns) must
// not survive as a hard line break: downstream unwrapping keeps a wrap after
// a sentence end or before a capitalised word, which split one paragraph
// into several on web while iOS rendered one.
const TEXT_NODE_WHITESPACE_RUN_PATTERN = /[ \t\n\f\r\u00A0]+/g

function normalisedTextNodeText(data: string): string {
  return data.replace(TEXT_NODE_WHITESPACE_RUN_PATTERN, ' ')
}

function walk(node: Node, buffer: TextBuffer, options: ParagraphTextOptions): void {
  if (node.nodeType === NODE_TEXT) {
    buffer.appendText(normalisedTextNodeText((node as Text).data))
    return
  }
  if (node.nodeType !== NODE_ELEMENT) {
    return
  }
  const element = node as Element
  const tag = element.tagName.toLowerCase()

  if (INVISIBLE_TAGS.has(tag)) {
    return
  }

  if (options.shouldSkipElement?.(element) === true) {
    return
  }

  switch (tag) {
    case 'br':
      buffer.appendNewline()
      return
    case 'hr':
      buffer.appendParagraphBreak()
      return
    case 'img':
      // Skip alt text: emails frequently use it for tracking pixels.
      return
    default:
      break
  }

  const isBlock = BLOCK_TAGS.has(tag)
  const usesLineBoundary = options.divsAsLineBreaks === true && tag === 'div'
  const isCell = CELL_TAGS.has(tag)

  if (isBlock) {
    buffer.flushPendingInlineSpace()
    if (usesLineBoundary) {
      buffer.markLineBoundary()
    } else {
      buffer.markBlockBoundary()
    }
  }

  for (const child of Array.from(element.childNodes)) {
    walk(child, buffer, options)
  }

  if (isCell) {
    buffer.appendInlineSpace()
  }
  if (isBlock) {
    if (usesLineBoundary) {
      buffer.markLineBoundary()
    } else {
      buffer.markBlockBoundary()
    }
  }
}

function normalizeExtracted(text: string): string {
  let result = ''
  let consecutiveNewlines = 0
  for (const char of text) {
    if (char === '\n') {
      consecutiveNewlines += 1
      if (consecutiveNewlines <= 2) {
        result += char
      }
    } else {
      consecutiveNewlines = 0
      result += char
    }
  }
  return result.trim()
}

/** Extracts paragraph-aware plain text from an element subtree. */
export function paragraphAwareText(root: Element, options: ParagraphTextOptions = {}): string {
  const buffer = new TextBuffer()
  walk(root, buffer, options)
  return normalizeExtracted(buffer.string)
}

/**
 * jsoup-style collapsed single-line text for an element (cells contribute
 * trailing spaces, all whitespace collapsed).
 */
export function collapsedElementText(element: Element): string {
  return paragraphAwareText(element)
    .replace(/\u00A0/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

// MARK: - Markup detection (TextProcessing port)

const KNOWN_HTML_TAG_NAMES = new Set([
  'a',
  'abbr',
  'address',
  'area',
  'article',
  'aside',
  'audio',
  'b',
  'bdi',
  'bdo',
  'blockquote',
  'body',
  'br',
  'caption',
  'center',
  'cite',
  'code',
  'col',
  'colgroup',
  'data',
  'datalist',
  'dd',
  'del',
  'details',
  'dfn',
  'dialog',
  'dir',
  'div',
  'dl',
  'dt',
  'em',
  'figcaption',
  'figure',
  'font',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'head',
  'header',
  'hgroup',
  'hr',
  'html',
  'i',
  'iframe',
  'img',
  'input',
  'ins',
  'kbd',
  'li',
  'link',
  'main',
  'map',
  'mark',
  'menu',
  'meta',
  'meter',
  'nav',
  'noscript',
  'object',
  'ol',
  'p',
  'picture',
  'pre',
  'progress',
  'q',
  'rp',
  'rt',
  'ruby',
  's',
  'samp',
  'script',
  'section',
  'small',
  'source',
  'span',
  'strike',
  'strong',
  'style',
  'sub',
  'summary',
  'sup',
  'svg',
  'table',
  'tbody',
  'td',
  'template',
  'textarea',
  'tfoot',
  'th',
  'thead',
  'time',
  'title',
  'tr',
  'track',
  'u',
  'ul',
  'var',
  'video',
  'wbr',
])

function isTagNameCharacter(ch: string): boolean {
  return /[\p{L}\p{N}]/u.test(ch) || ch === '-' || ch === ':' || ch === '_'
}

function isAsciiLetter(ch: string): boolean {
  return /[a-zA-Z]/.test(ch)
}

/** Finds the index of the closing `>` of a tag starting scan at startIndex. */
function tagEndIndex(html: string, startIndex: number): number | null {
  let index = startIndex
  let quote: string | null = null

  while (index < html.length) {
    const character = html[index]!
    if (quote !== null) {
      if (character === quote) {
        quote = null
      }
    } else if (character === '"' || character === "'") {
      quote = character
    } else if (character === '>') {
      return index
    }
    index += 1
  }

  return null
}

function tagHasAttributes(html: string, nameEnd: number, tagEnd: number): boolean {
  let index = nameEnd
  let hasAttributeSeparator = false

  while (index < tagEnd) {
    if (/\s/.test(html[index]!)) {
      hasAttributeSeparator = true
      index += 1
      continue
    }

    if (!hasAttributeSeparator || html[index] === '/') {
      return false
    }

    const attributeNameStart = index
    while (index < tagEnd && isAttributeNameCharacter(html[index]!)) {
      index += 1
    }

    if (attributeNameStart >= index) {
      return false
    }

    while (index < tagEnd && /\s/.test(html[index]!)) {
      index += 1
    }

    if (index < tagEnd && html[index] === '=') {
      return true
    }

    hasAttributeSeparator = false
  }

  return false
}

function isAttributeNameCharacter(ch: string): boolean {
  return (
    !/\s/.test(ch) &&
    ch !== '/' &&
    ch !== '>' &&
    ch !== '=' &&
    ch !== '"' &&
    ch !== "'" &&
    ch !== '<'
  )
}

function hasExplicitCloseTag(tagName: string, html: string, startIndex: number): boolean {
  let index = startIndex

  while (true) {
    const tagStart = html.indexOf('<', index)
    if (tagStart === -1) return false
    const afterOpen = tagStart + 1
    if (afterOpen >= html.length) return false

    if (html[afterOpen] !== '/') {
      index = afterOpen
      continue
    }

    const nameStart = afterOpen + 1
    let nameEnd = nameStart
    while (nameEnd < html.length && isTagNameCharacter(html[nameEnd]!)) {
      nameEnd += 1
    }

    const closeName = html.slice(nameStart, nameEnd)
    const tagEnd = tagEndIndex(html, nameEnd)
    if (closeName.toLowerCase() !== tagName.toLowerCase() || tagEnd === null) {
      index = nameEnd
      continue
    }

    let closeRemainder = nameEnd
    while (closeRemainder < tagEnd && /\s/.test(html[closeRemainder]!)) {
      closeRemainder += 1
    }

    if (closeRemainder === tagEnd) {
      return true
    }

    index = tagEnd + 1
  }
}

export function containsLikelyHtmlMarkup(html: string): boolean {
  let index = 0

  while (true) {
    const tagStart = html.indexOf('<', index)
    if (tagStart === -1) return false
    const nextIndex = tagStart + 1
    if (nextIndex >= html.length) return false

    const firstCharacter = html[nextIndex]!
    if (isAsciiLetter(firstCharacter) || /\p{L}/u.test(firstCharacter)) {
      const tagEnd = tagEndIndex(html, nextIndex)
      if (tagEnd !== null) {
        let tagNameEnd = nextIndex
        while (tagNameEnd < html.length && isTagNameCharacter(html[tagNameEnd]!)) {
          tagNameEnd += 1
        }

        const tagName = html.slice(nextIndex, tagNameEnd).toLowerCase()
        if (
          KNOWN_HTML_TAG_NAMES.has(tagName) ||
          tagHasAttributes(html, tagNameEnd, tagEnd) ||
          hasExplicitCloseTag(tagName, html, tagEnd + 1)
        ) {
          return true
        }
      }
    } else if (firstCharacter === '!') {
      if (
        html.slice(nextIndex).toLowerCase().startsWith('!doctype') &&
        tagEndIndex(html, nextIndex) !== null
      ) {
        return true
      }
      if (html.slice(nextIndex).startsWith('!--') && html.indexOf('-->', nextIndex) !== -1) {
        return true
      }
    }

    if (firstCharacter === '/') {
      const nameStart = nextIndex + 1
      let nameEnd = nameStart
      while (nameEnd < html.length && isTagNameCharacter(html[nameEnd]!)) {
        nameEnd += 1
      }

      const tagName = html.slice(nameStart, nameEnd).toLowerCase()
      if (
        nameStart < html.length &&
        /\p{L}/u.test(html[nameStart]!) &&
        KNOWN_HTML_TAG_NAMES.has(tagName) &&
        tagEndIndex(html, nameEnd) !== null
      ) {
        return true
      }
    }

    index = nextIndex
  }
}

export function containsUnclosedOpeningTag(html: string): boolean {
  let index = 0

  while (true) {
    const tagStart = html.indexOf('<', index)
    if (tagStart === -1) return false
    const nameStart = tagStart + 1
    if (nameStart >= html.length) return false

    if (/\p{L}/u.test(html[nameStart]!) && tagEndIndex(html, nameStart) === null) {
      return true
    }

    index = nameStart
  }
}

// MARK: - Plain-text normalization / malformed-HTML recovery

function normalizePlainTextInput(text: string): string {
  let normalized = decodeHtmlEntities(text)

  normalized = normalized.replace(/[\u200B\u200C\u200D]/g, '')
  normalized = normalized.replace(/[ \t]+/g, ' ')
  normalized = normalized.replace(/\n[ \t]*\n/g, '\n\n')
  normalized = normalized.replace(/(\s*\n\s*){2,}/g, '\n\n')
  normalized = normalized
    .split('\n')
    .map((line) => line.trim())
    .join('\n')

  return normalized.trim()
}

function recoverPlainTextFromMalformedHtml(html: string): string {
  let text = html

  // Avoid leaking <head> metadata / conditional comments into bubble text.
  text = text.replace(/<head\b[^>]*>[\s\S]*?<\/head>/gi, '')
  text = text.replace(/<!--[\s\S]*?-->/gi, '')

  // Remove script and style tags and their content.
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/g, '')
  text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/g, '')

  // Consecutive <br> pairs → paragraph break, single <br> → newline.
  text = text.replace(/<br[^>]*>\s*<br[^>]*>/g, '\n\n')
  text = text.replace(/<br[^>]*>/g, '\n')

  // Paragraphs and headings get double newlines.
  text = text.replace(/<\/p>/g, '\n\n')
  text = text.replace(/<\/h[1-6]>/g, '\n\n')

  // Div closures create single newlines.
  text = text.replace(/<\/div>/gi, '\n')

  // List items on their own lines.
  text = text.replace(/<\/li>/gi, '\n')

  // Tables: preserve row boundaries, space between cells.
  text = text.replace(/<\/t[dh]>/gi, ' ')
  text = text.replace(/<\/tr>/gi, '\n')
  text = text.replace(/<\/table>/gi, '\n\n')

  // Remove all HTML tags.
  text = text.replace(/<[^>]+>/g, '')
  // Remove truncated opening tags (snippet cut mid-tag).
  text = text.replace(/<[a-zA-Z][^>\n]*(?=\n|$)/g, '')

  text = decodeHtmlEntities(text)

  text = text.replace(/[\u200B\u200C\u200D]/g, '')

  text = text.replace(/[ \t]+/g, ' ')
  text = text.replace(/\n[ \t]*\n/g, '\n\n')
  text = text.replace(/(\s*\n\s*){2,}/g, '\n\n')

  text = text
    .split('\n')
    .map((line) => line.trim())
    .join('\n')

  return text.trim()
}

/**
 * Extracts plain text from HTML: DOM-backed when the input parses as real
 * markup, regex recovery for malformed fragments, normalization for plain
 * text that isn't markup at all.
 */
export function extractPlainTextFromHtml(html: string): string {
  if (containsUnclosedOpeningTag(html)) {
    return recoverPlainTextFromMalformedHtml(html)
  }

  if (!containsLikelyHtmlMarkup(html)) {
    return normalizePlainTextInput(html)
  }

  const document = parseHtmlDocument(html)
  const root = document.body ?? document.documentElement
  if (root) {
    const text = paragraphAwareText(root, { divsAsLineBreaks: true })
    if (text.length > 0) {
      return text
    }
  }

  return recoverPlainTextFromMalformedHtml(html)
}

// MARK: - Standalone quote attribution lines (ChatBubbleTextProcessor port)

const HTML_TEXT_QUOTE_ATTRIBUTION_SUFFIXES = [
  'wrote:',
  'schrieb:',
  'a écrit :',
  'a écrit:',
  'escribió:',
  'ha scritto:',
  'escreveu:',
  'schreef:',
]

export function isHtmlTextQuoteAttributionLine(text: string): boolean {
  const lowercased = text.toLowerCase()
  return HTML_TEXT_QUOTE_ATTRIBUTION_SUFFIXES.some((suffix) => lowercased.endsWith(suffix))
}

const STANDALONE_QUOTE_ATTRIBUTION_DATE_PREFIXES = ['on ', 'am ', 'le ', 'el ', 'il ', 'em ', 'op ']

/**
 * A genuine attribution needs more than the "wrote:" suffix — prose like
 * "Here is what I wrote:" must survive. Real client attributions start
 * with a date preposition ("On …", "Am …") or embed the quoted sender's
 * address.
 */
export function isStandaloneQuoteAttributionLine(line: string): boolean {
  if (!isHtmlTextQuoteAttributionLine(line)) return false

  const lowercased = line.toLowerCase()
  if (STANDALONE_QUOTE_ATTRIBUTION_DATE_PREFIXES.some((prefix) => lowercased.startsWith(prefix))) {
    return true
  }
  return line.includes('@') || line.includes('<')
}

/**
 * Drops lines that are ONLY a quote attribution ("On …, Olga wrote:")
 * without truncating anything after them. The containers-only cleanup
 * removes the quoted blockquote but leaves its attribution line behind;
 * truncating at it (the residual-marker behavior) would rediscard the
 * content that follows. Run only when
 * `HtmlProcessingCleanupResult.stripStandaloneQuoteAttributionLines` is set:
 * the fuller modes already truncate attributions in the DOM, and running the
 * line filter on their output risks deleting legitimate prose.
 */
export function removeStandaloneQuoteAttributionLines(text: string): string {
  const lines = text.split('\n')
  if (lines.length <= 1) return text

  const kept = lines.filter((line) => !isStandaloneQuoteAttributionLine(line.trim()))
  if (kept.length === lines.length) return text
  return kept.join('\n')
}
