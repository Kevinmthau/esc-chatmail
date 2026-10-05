import Foundation

/// Shared preview-routing inputs, mirrored by web/src/lib/displayPolicy.ts.
struct MessageDisplayInput {
    let hasHTMLSource: Bool
    let isForwardedEmail: Bool
    let isNewsletter: Bool
    /// The row's rich-content verdict: the one the bubble's async content load published,
    /// before that the verdict stored on the row, and false while neither is known
    /// (`MessageDisplayPolicy.resolvedRichVerdict`).
    /// `private(set)` only so `withRichHTMLContent(_:)` can copy the value.
    private(set) var hasRichHTMLContent: Bool
    let isFromMe: Bool
    let isOneToOneConversation: Bool
    let subject: String?
    let senderEmail: String?
    let isLikelyCalendarInvite: Bool

    init(
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isNewsletter: Bool,
        hasRichHTMLContent: Bool,
        isFromMe: Bool,
        isOneToOneConversation: Bool,
        subject: String?,
        senderEmail: String?,
        isLikelyCalendarInvite: Bool = false
    ) {
        self.hasHTMLSource = hasHTMLSource
        self.isForwardedEmail = isForwardedEmail
        self.isNewsletter = isNewsletter
        self.hasRichHTMLContent = hasRichHTMLContent
        self.isFromMe = isFromMe
        self.isOneToOneConversation = isOneToOneConversation
        self.subject = subject
        self.senderEmail = senderEmail
        self.isLikelyCalendarInvite = isLikelyCalendarInvite
    }

    /// This row with the content load's rich-content verdict replaced, for asking the routing
    /// what a load could still decide (`MessageDisplayPolicy.loadCanRouteToHTMLPreview`).
    ///
    /// A copy of the value, not a second initializer call: `isLikelyCalendarInvite` is a
    /// defaulted parameter, so a rebuilt input that dropped a field would still compile. Not
    /// mirrored by the web port, which has no loading placeholder.
    func withRichHTMLContent(_ hasRichHTMLContent: Bool) -> MessageDisplayInput {
        var copy = self
        copy.hasRichHTMLContent = hasRichHTMLContent
        return copy
    }
}
