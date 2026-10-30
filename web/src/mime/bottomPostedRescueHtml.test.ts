// Quote-first (bottom-posted) HTML replies: the containers-only rescue mode
// and the standalone-attribution line filter. Ports the iOS pins in
// HTMLCleanupFallbackTests (bottomPostedReply / markerOnlyQuoteWithoutContainer)
// and ChatBubbleTextProcessorTests (htmlBottomPostedReply,
// htmlBottomPostedContactCard, htmlProseEndingInWroteColon).

import { describe, expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { removeQuotesFromHtml } from './html'
import {
  extractPlainTextFromHtml,
  isStandaloneQuoteAttributionLine,
  removeStandaloneQuoteAttributionLines,
} from './htmlText'
import { cleanedHtmlForCleanupModes, cleanedHtmlForProcessing } from './richContent'

/// Apple-Mail-shaped bottom-post: attribution line and quoted history
/// first, the author's text after.
const bottomPostedHTML = `<div>On Aug 1, 2026, at 9:00 AM, Olga wrote:</div>
<blockquote type="cite"><div>Quoted history line</div></blockquote>
<div>Bottom-posted reply text</div>`

const bottomPostedReplyHTML = `<html><body>
<div>On Aug 1, 2026, at 9:00 AM, Olga Smith &lt;olga@example.com&gt; wrote:</div>
<blockquote type="cite"><div>Are you free for lunch tomorrow?</div></blockquote>
<div>Yes! Tomorrow at noon works great.</div>
</body></html>`

describe('removeQuotesFromHtml quotedContainersOnly', () => {
  // Revert-check: the 'quotedContainersOnly' branch of removeQuotesFromHtml
  // (skipping truncateAtStructuralBoundaries / truncateAtTextMarkers).
  it('quotedContainersOnly_bottomPostedReply_keepsContentAfterQuoteContainer', () => {
    const cleaned = removeQuotesFromHtml(bottomPostedHTML, 'quotedContainersOnly') ?? ''

    expect(cleaned).toContain('Bottom-posted reply text')
    expect(cleaned).not.toContain('Quoted history line')
    // No marker truncation in this mode: the attribution stays for the
    // text-level filter.
    expect(cleaned).toContain('Olga wrote:')
  })

  // Revert-check: the removedQuotedContainerCount === 0 early return in
  // removeQuotesFromHtml, fed by removeQuotedContainers' count.
  it('quotedContainersOnly_markerOnlyQuoteWithoutContainer_returnsEmpty', () => {
    const markerOnlyHTML = `<div>On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:</div>
<div>Earlier message only.</div>`

    expect(removeQuotesFromHtml(markerOnlyHTML, 'quotedContainersOnly')).toBe('')
  })

  // Revert-check: removeSignatureWrappers / removeFooterContainers running
  // for 'quotedContainersOnly' while truncateAtSignatureMarkers does not.
  it('quotedContainersOnly_signatureWrapperAndMarker_removesWrapperButNotMarkerTail', () => {
    const html = `<div>On Aug 1, 2026, at 9:00 AM, Olga wrote:</div>
<blockquote type="cite"><div>Quoted history line</div></blockquote>
<div>Reply text</div>
<div>Sent from my iPhone</div>
<div class="gmail_signature">John Smith<br>Partner</div>`

    const cleaned = removeQuotesFromHtml(html, 'quotedContainersOnly') ?? ''

    expect(cleaned).toContain('Reply text')
    expect(cleaned).toContain('Sent from my iPhone')
    expect(cleaned).not.toContain('class="gmail_signature"')
  })
})

describe('cleanedHtmlForProcessing chain', () => {
  // Revert-check: 'quotedContainersOnly' as the third mode in
  // cleanedHtmlForProcessing.
  it('chain_bottomPostedReply_quotedContainersOnlyRecoversContent', () => {
    const result = cleanedHtmlForCleanupModes(bottomPostedHTML, [
      'quotedAndSignatures',
      'quotedOnly',
      'quotedContainersOnly',
    ])

    expect(result.appliedMode).toBe('quotedContainersOnly')
    expect(result.html).toContain('Bottom-posted reply text')
    expect(result.html).not.toContain('Quoted history line')
  })

  /// Marker-only quote with NO container: there is no boundary between the
  /// quoted history and content, so the containers-only mode must decline
  /// and the chain must fall back to the original (which then goes through
  /// full plain-text quote removal).
  // Revert-check: the removedQuotedContainerCount === 0 early return.
  it('chain_markerOnlyQuoteWithoutContainer_fallsBackToOriginal', () => {
    const markerOnlyHTML = `<div>On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:</div>
<div>Earlier message only.</div>`

    const result = cleanedHtmlForCleanupModes(markerOnlyHTML, [
      'quotedAndSignatures',
      'quotedOnly',
      'quotedContainersOnly',
    ])

    expect(result.appliedMode).toBeNull()
    expect(result.html).toBe(markerOnlyHTML)
  })

  // Revert-check: HtmlProcessingCleanupResult.stripStandaloneQuoteAttributionLines.
  it('cleanedHtmlForProcessing_bottomPostedReply_setsStripAttributionFlagOnly', () => {
    const cleanup = cleanedHtmlForProcessing(bottomPostedReplyHTML)

    expect(cleanup.applyPlainTextQuoteRemoval).toBe(false)
    expect(cleanup.applyTrailingContactSignatureRemoval).toBe(false)
    expect(cleanup.stripStandaloneQuoteAttributionLines).toBe(true)
    expect(cleanup.html).toContain('Yes! Tomorrow at noon works great.')
    expect(cleanup.html).not.toContain('Are you free for lunch tomorrow?')
  })

  it('cleanedHtmlForProcessing_topPostedReply_leavesStripAttributionFlagClear', () => {
    const cleanup = cleanedHtmlForProcessing(
      '<div>Fresh reply.</div><div class="gmail_quote">On Aug 1, 2026, Olga wrote:<br>Quoted</div>',
    )

    expect(cleanup.applyTrailingContactSignatureRemoval).toBe(true)
    expect(cleanup.stripStandaloneQuoteAttributionLines).toBe(false)
  })
})

describe('removeStandaloneQuoteAttributionLines', () => {
  // Revert-check: removeStandaloneQuoteAttributionLines / isStandaloneQuoteAttributionLine.
  it('removeStandaloneQuoteAttributionLines_attributionBeforeContent_dropsOnlyTheAttribution', () => {
    const text =
      'On Aug 1, 2026, at 9:00 AM, Olga Smith <olga@example.com> wrote:\nYes! Tomorrow at noon works great.'

    expect(removeStandaloneQuoteAttributionLines(text)).toBe('Yes! Tomorrow at noon works great.')
  })

  /// Prose that merely ends with "wrote:" is not an attribution: a genuine
  /// one starts with a date preposition or embeds the sender's address.
  it('removeStandaloneQuoteAttributionLines_proseEndingInWroteColon_keepsEveryLine', () => {
    const text = 'Here is what I wrote:\nThe draft is attached for your review.'

    expect(removeStandaloneQuoteAttributionLines(text)).toBe(text)
  })

  it('isStandaloneQuoteAttributionLine_localizedAndAddressShapes_matchGenuineAttributionsOnly', () => {
    expect(isStandaloneQuoteAttributionLine('Am 01.08.2026 um 09:00 Olga Smith schrieb:')).toBe(
      true,
    )
    // The suffix list is exact: a German attribution whose name follows the
    // verb does not end in "schrieb:" and is not matched (same as iOS).
    expect(isStandaloneQuoteAttributionLine('Am 01.08.2026 um 09:00 schrieb Olga:')).toBe(false)
    expect(isStandaloneQuoteAttributionLine('Olga Smith <olga@example.com> wrote:')).toBe(true)
    expect(isStandaloneQuoteAttributionLine('olga@example.com wrote:')).toBe(true)
    expect(isStandaloneQuoteAttributionLine('Here is what I wrote:')).toBe(false)
    expect(isStandaloneQuoteAttributionLine('On the whole it went well')).toBe(false)
  })

  it('removeStandaloneQuoteAttributionLines_singleLine_returnsInputUnchanged', () => {
    const attributionOnly = 'On Aug 1, 2026, Olga wrote:'

    expect(removeStandaloneQuoteAttributionLines(attributionOnly)).toBe(attributionOnly)
  })
})

describe('bottom-posted HTML through the bubble pipeline', () => {
  /// iOS pins mainText === "Yes! Tomorrow at noon works great.": the rescue
  /// keeps the reply and the attribution-line strip drops the "On … wrote:"
  /// the removed blockquote left behind.
  // Revert-check: 'quotedContainersOnly' in cleanedHtmlForProcessing (the
  // bubble was null before it) and the stripStandaloneQuoteAttributionLines
  // wiring in bubble.ts (the attribution line precedes the reply without it).
  it('processChatBubbleText_htmlBottomPostedReply_recoversContentAfterQuote', () => {
    const result = processChatBubbleText(bottomPostedReplyHTML, { inputKind: 'html' })

    expect(result.mainText).toBe('Yes! Tomorrow at noon works great.')

    const cleanup = cleanedHtmlForProcessing(bottomPostedReplyHTML)
    const extracted = extractPlainTextFromHtml(cleanup.html)
    expect(removeStandaloneQuoteAttributionLines(extracted)).toBe(
      'Yes! Tomorrow at noon works great.',
    )
  })

  /// The contact card is the entire reply. The rescue must not serve as
  /// body evidence for a second signature pass that would discard the card.
  // Revert-check: applyTrailingContactSignatureRemoval staying false for the
  // 'quotedContainersOnly' applied mode.
  it('processChatBubbleText_htmlBottomPostedContactCard_preservesRescuedContact', () => {
    const html = `<html><body>
<div>On Aug 1, 2026, at 9:00 AM, Olga Smith &lt;olga@example.com&gt; wrote:</div>
<blockquote type="cite"><div>Please send the engineer's contact.</div></blockquote>
<div>Best,<br>John Smith<br>Partner<br>john@example.test<br>415-555-1212</div>
</body></html>`

    const result = processChatBubbleText(html, { inputKind: 'html' })
    const visibleText = (result.mainText ?? '').split(/\s+/).join(' ')

    expect(visibleText).toContain('Best, John Smith Partner john@example.test 415-555-1212')
    expect(visibleText).not.toContain("Please send the engineer's contact.")
  })

  it('processChatBubbleText_htmlProseEndingInWroteColon_survivesCleanup', () => {
    const html = `<div>Here is what I wrote:</div>
<div>The draft is attached for your review.</div>`

    const result = processChatBubbleText(html, { inputKind: 'html' })

    expect(result.mainText).toContain('Here is what I wrote:')
    expect(result.mainText).toContain('The draft is attached for your review.')
  })
})
