import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Incoming forwarded mail falls back to the full preview card when no
    /// structured forward summary is available.
    /// Newsletter messages can still use HTML preview cards.
    /// Rich HTML previews are conservative in one-to-one *reply threads* to avoid
    /// treating person-to-person replies like newsletters, but should still show
    /// for genuinely rich transactional/marketing HTML.
    static func shouldShowHTMLPreview(_ input: MessageDisplayInput) -> Bool {
        let hasHTMLSource = input.hasHTMLSource
        let isForwardedEmail = input.isForwardedEmail
        let isNewsletter = input.isNewsletter
        let hasRichHTMLContent = input.hasRichHTMLContent
        let isFromMe = input.isFromMe
        let isOneToOneConversation = input.isOneToOneConversation
        let subject = input.subject
        let senderEmail = input.senderEmail
        let isLikelyCalendarInvite = input.isLikelyCalendarInvite
        let trustedTransactionalSender = isTrustedTransactionalSender(senderEmail)
        // Allow newsletter and rich-content preview routing even if the local HTML file/URI metadata is missing.
        // The preview loader can still recover embedded/recoverable HTML on demand.
        let allowNewsletterRecoveryPreview = isNewsletter && !isForwardedEmail
        guard hasHTMLSource || trustedTransactionalSender || hasRichHTMLContent || allowNewsletterRecoveryPreview else {
            return false
        }

        if isForwardedEmail {
            return !isFromMe
        }

        // Trusted transactional system senders should render as preview cards even when
        // HTML metadata/rich-content classification is conservative.
        if trustedTransactionalSender && !isFromMe {
            return true
        }

        let normalizedSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isReplySubject = normalizedSubject.hasPrefix("re:")
        let allowsOneToOneReplyPreview =
            isOneToOneConversation &&
            shouldAllowRichReplyPreview(senderEmail: senderEmail, hasRichHTMLContent: hasRichHTMLContent)

        // Keep one-to-one replies in chat bubbles, even if upstream heuristics are noisy.
        if isOneToOneConversation {
            if isFromMe {
                return false
            }

            if isReplySubject && !allowsOneToOneReplyPreview {
                return false
            }
        }

        // Keep personal reply chains in group threads as bubbles unless we have
        // strong newsletter classification.
        if isReplySubject && !isNewsletter && !allowsOneToOneReplyPreview {
            return false
        }

        if isNewsletter {
            return true
        }

        if isLikelyCalendarInvite {
            return true
        }

        // Transactional/marketing HTML can be genuinely rich even in one-to-one conversations.
        // Trust `hasRichHTMLContent` to filter out signature cruft.
        return hasRichHTMLContent
    }

    static func isTrustedTransactionalSender(_ senderEmail: String?) -> Bool {
        PreviewTextUtilities.senderDomain(
            senderEmail,
            matchesDomainOrSuffixIn: trustedTransactionalReplyDomainSuffixes
        )
    }

    private static let trustedTransactionalReplyDomainSuffixes: Set<String> = [
        // eBay buyer/seller relay senders
        "members.ebay.com",
        // BILL approval/transactional notifications
        "bill.com",
        // Marketplace relay/system senders
        "amazon.com",
        "etsy.com",
        "mercari.com",
        "offerup.com",
        "poshmark.com"
    ]

    private static func shouldAllowRichReplyPreview(senderEmail: String?, hasRichHTMLContent: Bool) -> Bool {
        guard hasRichHTMLContent,
              isTrustedTransactionalSender(senderEmail) else {
            return false
        }

        return true
    }
}
