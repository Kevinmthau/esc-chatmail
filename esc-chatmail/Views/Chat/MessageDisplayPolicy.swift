import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Forwarded/newsletter messages always use HTML preview cards.
    /// Rich HTML previews are conservative in one-to-one conversations to avoid
    /// treating person-to-person replies like newsletters.
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

        // Rich HTML preview is useful in larger/list conversations, but too noisy for one-to-one.
        return hasRichHTMLContent && !isOneToOneConversation
    }
}
