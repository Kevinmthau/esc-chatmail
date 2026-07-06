import Foundation

/// Canonical implementation of the HTML cleanup degradation chain: try each
/// removal mode in order and keep the first output that still has meaningful
/// content, falling back to the original HTML when every mode wipes it.
///
/// Previously three verbatim copies: `ProcessedTextCache
/// .cleanedHTMLForProcessing`, `HTMLContentLoader.prepareHTMLForDisplay`, and
/// `MessageBubbleHTMLAnalysisBuilder.cleanedHTMLForAttachmentFiltering`.
enum HTMLCleanupFallback {
    struct Result: Equatable {
        /// The first cleanup output that retained meaningful content, or the
        /// original HTML when no mode did.
        let html: String
        /// The mode that produced `html`; nil when every attempt wiped the
        /// content and the original HTML was returned.
        let appliedMode: HTMLQuoteRemover.RemovalMode?
    }

    static func cleanedHTML(
        from html: String,
        modes: [HTMLQuoteRemover.RemovalMode]
    ) -> Result {
        for mode in modes {
            let cleaned = HTMLQuoteRemover.removeQuotes(from: html, mode: mode) ?? html
            if HTMLMeaningfulContentChecker.hasMeaningfulContent(cleaned) {
                return Result(html: cleaned, appliedMode: mode)
            }
        }

        return Result(html: html, appliedMode: nil)
    }
}
