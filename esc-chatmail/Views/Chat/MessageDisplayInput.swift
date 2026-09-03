import Foundation

/// Shared preview-routing inputs, mirrored by web/src/lib/displayPolicy.ts.
struct MessageDisplayInput {
    let hasHTMLSource: Bool
    let isForwardedEmail: Bool
    let isNewsletter: Bool
    let hasRichHTMLContent: Bool
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
}
