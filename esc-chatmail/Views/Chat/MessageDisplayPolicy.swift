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

    /// Whether a bubble routed to text (not the HTML preview card) shows the "Loading..." pill
    /// instead of its text while the async content load is still running.
    ///
    /// Incoming HTML keeps the pill: until content detection finishes, the only text on hand is
    /// raw/partial HTML-derived text that the load may replace or route to a preview card.
    ///
    /// The user's own non-forwarded rows with a stored `chatPreviewText` skip it. Their final
    /// text is already known: the loader publishes the stored preview as `fullTextContent`,
    /// `resolvedVisibleText` prefers it anyway, and rich-content classification is always false
    /// for `isFromMe`, so the row ends as this same text bubble. The pill bought nothing there and
    /// cost a visible text → "Loading..." → text flicker on every reply: sync replaces the
    /// optimistic row with Gmail's echo, a new object ID, so the bubble remounts with a fresh
    /// view model, and the echo (always multipart/alternative) has an HTML source. A multi-line
    /// reply also collapsed to the one-line pill and regrew. Newsletter and calendar-invite rows
    /// are excluded because they can route to a preview card instead.
    ///
    /// The same own rows with no stored preview but with displayed attachments skip it too: an
    /// attachments-only reply. Its stored preview is blank because it has no text of its own
    /// (its plain body is at most the quoted original, which chat display strips), so the load
    /// finds no text either and the bubble ends as it renders before the load: the attachments,
    /// plus the row's fallback preview if it has one. The pill bought nothing there either: it
    /// showed "Loading..." under the attachments and then vanished. Since the transcript keeps
    /// one view across Gmail's echo (`ChatMessageDisplayIdentity`), the echo itself refreshes in
    /// place and no longer reaches this branch, but every fresh mount of such a row still did:
    /// reopening the chat, the row re-entering the loaded window, or an echo that landed while
    /// the chat was closed. A legacy own row with text but no stored preview (the backfill fills
    /// those) shows its fallback preview, if any, until the load swaps in its text, instead of
    /// the pill.
    static func showsTextLoadingPlaceholder(
        hasLoadedContent: Bool,
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isFromMe: Bool,
        isNewsletter: Bool,
        isLikelyCalendarInvite: Bool,
        chatPreviewText: String?,
        hasDisplayableAttachments: Bool
    ) -> Bool {
        guard !hasLoadedContent else { return false }
        if isForwardedEmail { return true }
        guard hasHTMLSource else { return false }

        let isOwnTextBubble = isFromMe && !isNewsletter && !isLikelyCalendarInvite
        guard isOwnTextBubble else { return true }
        let rendersStoredOwnPreview = MessagePreviewText.nonEmpty(chatPreviewText) != nil
        return !rendersStoredOwnPreview && !hasDisplayableAttachments
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
