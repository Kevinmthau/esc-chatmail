import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Forwarded/newsletter messages always use HTML preview cards.
    /// Rich HTML previews are conservative in one-to-one *reply threads* to avoid
    /// treating person-to-person replies like newsletters, but should still show
    /// for genuinely rich transactional/marketing HTML.
    static func shouldShowHTMLPreview(
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isNewsletter: Bool,
        hasRichHTMLContent: Bool,
        isFromMe: Bool,
        isOneToOneConversation: Bool,
        subject: String?
    ) -> Bool {
        guard hasHTMLSource else { return false }

        if isForwardedEmail {
            return true
        }

        // Keep one-to-one replies in chat bubbles, even if upstream heuristics are noisy.
        if isOneToOneConversation {
            if isFromMe {
                return false
            }

            let normalizedSubject = subject?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if normalizedSubject.hasPrefix("re:") {
                return false
            }
        }

        if isNewsletter {
            return true
        }

        // Transactional/marketing HTML can be genuinely rich even in one-to-one conversations.
        // Trust `hasRichHTMLContent` to filter out signature cruft.
        return hasRichHTMLContent
    }
}
