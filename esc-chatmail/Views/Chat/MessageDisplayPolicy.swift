import Foundation

enum MessageDisplayPolicy {
    /// Personal email should stay in chat bubbles.
    /// Forwarded mail should stay in chat bubbles because the subject already
    /// signals the forward and tapping the bubble opens the full email.
    /// Newsletter messages can still use HTML preview cards.
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
        subject: String?,
        senderEmail: String?
    ) -> Bool {
        let trustedTransactionalSender = isTrustedTransactionalSender(senderEmail)
        // Allow rich-content fallback rendering even if the HTML file/URI metadata is missing.
        guard hasHTMLSource || trustedTransactionalSender || hasRichHTMLContent else { return false }

        if isForwardedEmail {
            return false
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

        // Transactional/marketing HTML can be genuinely rich even in one-to-one conversations.
        // Trust `hasRichHTMLContent` to filter out signature cruft.
        return hasRichHTMLContent
    }

    static func isTrustedTransactionalSender(_ senderEmail: String?) -> Bool {
        guard let domain = senderDomain(from: senderEmail) else {
            return false
        }

        return trustedTransactionalReplyDomainSuffixes.contains { suffix in
            domain == suffix || domain.hasSuffix(".\(suffix)")
        }
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

    private static func senderDomain(from senderEmail: String?) -> String? {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !senderEmail.isEmpty else {
            return nil
        }

        let extractedEmail = EmailNormalizer.extractEmail(from: senderEmail) ?? senderEmail
        let normalizedEmail = extractedEmail
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[]"))

        guard let atIndex = normalizedEmail.lastIndex(of: "@"),
              atIndex < normalizedEmail.index(before: normalizedEmail.endIndex) else {
            return nil
        }

        let rawDomain = normalizedEmail[normalizedEmail.index(after: atIndex)...]
        let domain = rawDomain
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[],:;"))
            .lowercased()

        return domain.isEmpty ? nil : domain
    }
}
