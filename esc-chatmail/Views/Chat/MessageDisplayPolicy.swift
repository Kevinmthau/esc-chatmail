import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Only explicit forwarded/newsletter messages use HTML preview cards.
    static func shouldShowHTMLPreview(
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isNewsletter: Bool
    ) -> Bool {
        hasHTMLSource && (isForwardedEmail || isNewsletter)
    }
}
