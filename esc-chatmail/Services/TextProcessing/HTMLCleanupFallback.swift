import Foundation

/// Canonical implementation of the HTML cleanup degradation chain: try each
/// removal mode in order and keep the first output that still has meaningful
/// content, falling back to the original HTML when every mode wipes it.
///
/// Previously three verbatim copies: `ChatBubbleTextProcessor
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
        // `hasMeaningfulContent` is a pure function of its input, so a mode
        // whose output is byte-identical to one already judged non-meaningful
        // (quoted-only often equals quoted-and-signatures when no signature
        // was found) cannot come out differently; skip the repeat check.
        var rejectedOutputs: [String] = []
        for mode in modes {
            let cleaned = HTMLQuoteRemover.removeQuotes(from: html, mode: mode) ?? html
            if rejectedOutputs.contains(where: { $0.utf8.elementsEqual(cleaned.utf8) }) {
                continue
            }
            if HTMLMeaningfulContentChecker.hasMeaningfulContent(cleaned) {
                return Result(html: cleaned, appliedMode: mode)
            }
            rejectedOutputs.append(cleaned)
        }

        return Result(html: html, appliedMode: nil)
    }
}
