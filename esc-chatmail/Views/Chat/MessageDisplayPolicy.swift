import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Forwarded/newsletter messages always use HTML preview cards.
    /// Transactional HTML with rich structure can also use preview cards.
    static func shouldShowHTMLPreview(
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isNewsletter: Bool,
        hasRichHTMLContent: Bool
    ) -> Bool {
        hasHTMLSource && (isForwardedEmail || isNewsletter || hasRichHTMLContent)
    }
}
