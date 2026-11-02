// Table-section fragments (a body that opens with tr/td/th/tbody/thead/
// tfoot/caption/colgroup/col) are parsed in their required parent context so
// the quote remover sees rows and cells, not fostered bare text. Ports the
// iOS EmailDOMFragmentParser pin testRemoveQuotes_standaloneTableRowFragmentPreservesLayout.

import { describe, expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { removeQuotesFromHtml } from './html'
import { parseHtmlDocument, parseHtmlFragmentDocument } from './htmlText'

describe('parseHtmlFragmentDocument', () => {
  // Revert-check: parseHtmlFragmentDocument / tableFragmentContextTagName in htmlText.ts.
  it('parseHtmlFragmentDocument_leadingRowFragment_keepsRowsUnderBody', () => {
    const html = '<tr><td>Visible body.</td></tr>'

    expect(parseHtmlFragmentDocument(html, true).body.innerHTML).toBe(html)
    // The body context the plain parser uses drops the row structure.
    expect(parseHtmlDocument(html).body.innerHTML).toBe('Visible body.')
  })

  it.each([
    ['<td>Left</td><td>Right</td>', 'tr context'],
    ['<th>Head</th>', 'tr context'],
    ['<thead><tr><th>H</th></tr></thead>', 'table context'],
    ['<tbody><tr><td>B</td></tr></tbody>', 'table context'],
    ['<tfoot><tr><td>F</td></tr></tfoot>', 'table context'],
    ['<caption>Cap</caption>', 'table context'],
    ['<colgroup><col span="2"></colgroup>', 'table context'],
    ['<col span="2"><col>', 'colgroup context'],
  ])('parseHtmlFragmentDocument_tableSectionFragment_roundTrips %s (%s)', (html) => {
    expect(parseHtmlFragmentDocument(html, true).body.innerHTML).toBe(html)
  })

  it('parseHtmlFragmentDocument_leadingCommentAndWhitespace_stillDetectsRowContext', () => {
    const html = '<!-- preheader -->\n  <tr><td>Visible body.</td></tr>'

    expect(parseHtmlFragmentDocument(html, true).body.innerHTML).toContain(
      '<tr><td>Visible body.</td></tr>',
    )
  })

  it('parseHtmlFragmentDocument_documentInputOrNonTableLead_usesPlainParser', () => {
    expect(parseHtmlFragmentDocument('<tr><td>x</td></tr>', false).body.innerHTML).toBe('x')
    expect(parseHtmlFragmentDocument('<div>x</div><tr><td>y</td></tr>', true).body.innerHTML).toBe(
      '<div>x</div>y',
    )
    expect(parseHtmlFragmentDocument('plain text <tr>', true).body.innerHTML).toBe('plain text ')
  })
})

describe('removeQuotesFromHtml on table-section fragments', () => {
  // Revert-check: removeQuotesFromHtml parsing through parseHtmlFragmentDocument.
  it('removeQuotesFromHtml_standaloneTableRowFragment_preservesLayout', () => {
    const result = removeQuotesFromHtml('<tr><td>Visible body.</td></tr>') ?? ''
    const lowercased = result.toLowerCase()

    expect(lowercased).not.toContain('<html')
    expect(lowercased).not.toContain('<body')
    expect(lowercased).toContain('<tr')
    expect(result).toContain('<td>Visible body.</td>')
  })

  /// With the rows intact the trailing-contact signature pass sees two line
  /// elements and strips the signature row; fostered text had no lines at all.
  it('removeQuotesFromHtml_rowFragmentWithSignatureRow_removesSignatureRow', () => {
    const html =
      '<tr><td>Current reply.</td></tr><tr><td>John Smith<br>Partner<br>john@example.test<br>415-555-1212</td></tr>'

    expect(removeQuotesFromHtml(html)).toBe('<tr><td>Current reply.</td></tr>')
  })

  it('processChatBubbleText_rowFragmentWithSignatureRow_showsOnlyTheReply', () => {
    const html =
      '<tr><td>Current reply.</td></tr><tr><td>John Smith<br>Partner<br>john@example.test<br>415-555-1212</td></tr>'

    expect(processChatBubbleText(html, { inputKind: 'html' }).mainText).toBe('Current reply.')
  })

  it('removeQuotesFromHtml_cellFragmentWithQuoteContainer_keepsCellsAndDropsQuote', () => {
    const html = '<td>Reply.</td><td><blockquote>Quoted</blockquote></td>'

    expect(removeQuotesFromHtml(html)).toBe('<td>Reply.</td><td></td>')
  })
})
