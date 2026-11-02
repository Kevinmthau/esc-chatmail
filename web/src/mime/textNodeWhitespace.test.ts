// Text-node whitespace in the paragraph-aware DOM walk follows SwiftSoup's
// TextNode.text(): every whitespace run, newlines included, is one space, so
// line structure comes only from block and <br> boundaries.

import { describe, expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { extractPlainTextFromHtml, paragraphAwareText, parseHtmlDocument } from './htmlText'

describe('paragraphAwareText text-node whitespace', () => {
  // Revert-check: normalisedTextNodeText in htmlText.ts (TEXT_NODE_WHITESPACE_RUN_PATTERN).
  it('extractPlainTextFromHtml_sourceWrappedParagraph_joinsWithOneSpace', () => {
    expect(extractPlainTextFromHtml('<p>Hello\nworld</p>')).toBe('Hello world')
    expect(extractPlainTextFromHtml('<p>Hello\r\n   world</p>')).toBe('Hello world')
  })

  /// Outlook/Word hard-wrap paragraph text at ~76 columns with CRLF; the wrap
  /// after a sentence end and before a capitalised word must not become a
  /// paragraph break.
  it('extractPlainTextFromHtml_outlookCrlfWrappedParagraph_yieldsOneParagraph', () => {
    const html =
      '<p class=MsoNormal>Thanks for the update on the proposal.\r\nI will review it tomorrow and send comments.\r\nBest,<o:p></o:p></p>\r\n<p class=MsoNormal>Jane<o:p></o:p></p>'

    expect(extractPlainTextFromHtml(html)).toBe(
      'Thanks for the update on the proposal. I will review it tomorrow and send comments. Best,\n\nJane',
    )
  })

  it('processChatBubbleText_outlookCrlfWrappedParagraph_rendersOneParagraphThenSignOff', () => {
    const html =
      '<p class=MsoNormal>Thanks for the update on the proposal.\r\nI will review it tomorrow and send comments.\r\nBest,<o:p></o:p></p>\r\n<p class=MsoNormal>Jane<o:p></o:p></p>'

    const result = processChatBubbleText(html, { inputKind: 'html' })

    expect(result.mainText).toBe(
      'Thanks for the update on the proposal. I will review it tomorrow and send comments.\n\nBest,\n\nJane',
    )
  })

  it('paragraphAwareText_explicitBreaksAndBlocks_stillProduceLineStructure', () => {
    const body = parseHtmlDocument('<div>One\nline<br>Two</div><p>Three\n</p>').body

    expect(paragraphAwareText(body)).toBe('One line\nTwo\n\nThree')
  })

  /// HONEST SCOPE: SwiftSoup normalises <pre> text as well (no
  /// preserveWhitespace exception in TextNode.text()), so iOS also flattens
  /// preformatted line breaks; this pins parity, not a preference.
  it('extractPlainTextFromHtml_preformattedBlock_matchesSwiftSoupCollapse', () => {
    expect(extractPlainTextFromHtml('<pre>line one\nline two</pre>')).toBe('line one line two')
  })

  it('extractPlainTextFromHtml_tabsAndNbspRuns_collapseToOneSpace', () => {
    expect(extractPlainTextFromHtml('<p>a\t   b</p>')).toBe('a b')
  })
})
