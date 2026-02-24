import Foundation
import CoreData

extension Message {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Message> {
        return NSFetchRequest<Message>(entityName: "Message")
    }

    @NSManaged public var id: String
    @NSManaged public var gmThreadId: String
    @NSManaged public var internalDate: Date
    @NSManaged public var subject: String?
    @NSManaged public var snippet: String?
    @NSManaged public var cleanedSnippet: String?
    @NSManaged public var isFromMe: Bool
    @NSManaged public var isUnread: Bool
    @NSManaged public var isNewsletter: Bool
    @NSManaged public var hasAttachments: Bool
    @NSManaged public var bodyStorageURI: String?
    @NSManaged public var bodyText: String?
    @NSManaged public var senderName: String?
    @NSManaged public var senderEmail: String?
    @NSManaged public var messageId: String?
    @NSManaged public var references: String?
    @NSManaged public var localModifiedAt: Date?
    @NSManaged public var conversation: Conversation?
    @NSManaged public var labels: Set<Label>?
    @NSManaged public var participants: Set<MessageParticipant>?
    @NSManaged public var attachments: Set<Attachment>?

    var content: String? {
        get { cleanedSnippet }
        set { cleanedSnippet = newValue }
    }

    /// Type-safe accessor for attachments with empty set fallback
    var typedAttachments: Set<Attachment> {
        attachments ?? []
    }

    /// True when the message has local HTML content available via storage URI or message-id file.
    var hasHTMLSource: Bool {
        bodyStorageURI != nil || HTMLContentHandler.shared.htmlFileExists(for: id)
    }

    /// Array of attachments for convenient iteration
    var attachmentsArray: [Attachment] {
        Array(typedAttachments)
    }

    /// Attachments suitable for display (excludes signature images and inline images already shown in HTML)
    var displayableAttachments: [Attachment] {
        displayableAttachments(hidingInlineReferencedInHTML: true)
    }

    /// Attachments suitable for display in the chat UI.
    /// - Parameters:
    ///   - hidingInlineReferencedInHTML: When true, hides inline `cid:` images that are referenced by the message HTML
    ///     (to avoid duplicating what the HTML renderer already shows). When false, keeps plain-text bubble behavior
    ///     but still hides signature/quoted-history inline images removed by HTML cleanup.
    func displayableAttachments(hidingInlineReferencedInHTML: Bool) -> [Attachment] {
        let html = loadHTMLSource()
        let nonDisplayableInlineContentIDs = extractNonDisplayableInlineContentIDs(from: html)
        let allAttachments = attachmentsArray.filter { attachment in
            guard !attachment.isLikelySignatureImage else { return false }

            guard let contentId = normalizedContentID(from: attachment.contentId) else {
                return true
            }

            // Hide inline images that only appear in signature/quoted sections removed by cleanup.
            return !nonDisplayableInlineContentIDs.contains(contentId)
        }

        guard hidingInlineReferencedInHTML else {
            return allAttachments
        }

        // Only filter inline images for received messages that will display HTML.
        // Messages from the user (isFromMe) display as plain text, so their inline images
        // need to show in the attachment grid.
        guard !isFromMe else {
            return allAttachments
        }

        // If message has HTML content, filter out attachments that are displayed inline via cid: URLs.
        let referencedCIDs = extractReferencedContentIDs(from: html)
        guard !referencedCIDs.isEmpty else {
            return allAttachments
        }

        return allAttachments.filter { attachment in
            guard let contentId = normalizedContentID(from: attachment.contentId) else {
                return true // No Content-ID, always show
            }
            // Hide if this Content-ID is referenced in the HTML body.
            return !referencedCIDs.contains(contentId)
        }
    }

    /// Hides inline images that appear only in sections removed by quote/signature cleanup.
    /// This keeps signature logos out of plain-text chat bubbles while preserving genuine inline content.
    private func extractNonDisplayableInlineContentIDs(from html: String?) -> Set<String> {
        guard let html else { return [] }

        let originalReferenced = extractReferencedContentIDs(from: html)
        guard !originalReferenced.isEmpty else { return [] }

        let cleaned = cleanedHTMLForAttachmentFiltering(from: html)
        let cleanedReferenced = extractReferencedContentIDs(from: cleaned)
        return originalReferenced.subtracting(cleanedReferenced)
    }

    private func loadHTMLSource() -> String? {
        HTMLContentHandler.shared.loadHTML(for: id)
    }

    private func cleanedHTMLForAttachmentFiltering(from html: String) -> String {
        let quotedAndSignature = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedAndSignature) {
            return quotedAndSignature
        }

        // Signature cleanup can be over-aggressive for some templates; keep quote-only cleanup as fallback.
        let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedOnly) {
            return quotedOnly
        }

        return html
    }

    /// Extracts Content-IDs referenced via cid: URLs in HTML.
    private func extractReferencedContentIDs(from html: String?) -> Set<String> {
        guard let html else { return [] }

        // Match cid: references in src attributes (e.g., src="cid:ii_ml1i6p6v0")
        // Pattern matches: cid: followed by the Content-ID (which may contain letters, numbers, underscores, dots, @)
        var referencedCIDs = Set<String>()

        // Simple regex-free approach: find all occurrences of "cid:" and extract the ID
        let cidPrefix = "cid:"
        var searchRange = html.startIndex..<html.endIndex

        while let cidRange = html.range(of: cidPrefix, options: .caseInsensitive, range: searchRange) {
            let startOfCID = cidRange.upperBound
            // Find the end of the CID (typically ends at quote, space, or angle bracket)
            var endOfCID = startOfCID
            while endOfCID < html.endIndex {
                let char = html[endOfCID]
                if char == "\"" || char == "'" || char == " " || char == ">" || char == "<" {
                    break
                }
                endOfCID = html.index(after: endOfCID)
            }

            if startOfCID < endOfCID {
                let contentId = String(html[startOfCID..<endOfCID])
                if let normalizedContentId = normalizedContentID(from: contentId) {
                    referencedCIDs.insert(normalizedContentId)
                }
            }

            searchRange = endOfCID..<html.endIndex
        }

        return referencedCIDs
    }

    private func normalizedContentID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        var normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        normalized = normalized.removingPercentEncoding ?? normalized
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
    }

    /// Type-safe accessor for bodyText (alias for consistency)
    var bodyTextValue: String? {
        bodyText
    }

    /// Type-safe accessor for senderName (alias for consistency)
    var senderNameValue: String? {
        senderName
    }

    /// Type-safe accessor for senderEmail (alias for consistency)
    var senderEmailValue: String? {
        senderEmail
    }

    /// Type-safe accessor for messageId (alias for consistency)
    var messageIdValue: String? {
        messageId
    }

    /// Type-safe accessor for references (alias for consistency)
    var referencesValue: String? {
        references
    }

    /// Type-safe accessor for localModifiedAt (alias for consistency)
    var localModifiedAtValue: Date? {
        localModifiedAt
    }

    var timestamp: Date {
        get { internalDate }
        set { internalDate = newValue }
    }

    /// Checks if the message is a forwarded email by looking for forward indicators in the subject
    var isForwardedEmail: Bool {
        guard let subject = subject, !subject.isEmpty else {
            return false
        }

        let subjectLower = subject.lowercased().trimmingCharacters(in: .whitespaces)

        // Only check subject prefix - body content can contain forward indicators
        // from quoted messages in reply threads, leading to false positives
        return subjectLower.hasPrefix("fwd:") || subjectLower.hasPrefix("fw:")
    }

    /// Chooses how aggressively to clean HTML before rendering in previews/full views.
    /// Forwarded/newsletter messages keep original structure by default.
    var htmlDisplayCleanupMode: HTMLContentCleanupMode {
        if isForwardedEmail || isNewsletter {
            return .none
        }
        return .quotedAndSignature
    }

    /// Preferred one-line preview for conversation list rows.
    /// Forwarded messages use subject-based preview for better readability.
    var conversationPreviewText: String? {
        if isForwardedEmail, let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            let originalSubject = normalizedForwardSubject(from: subject)
            return "fwd: \"\(originalSubject)\""
        }

        if isNewsletter, let subject = subject, !subject.isEmpty {
            return subject
        }

        return cleanedSnippet ?? snippet
    }

    private func normalizedForwardSubject(from subject: String) -> String {
        var normalized = subject
        while true {
            guard let regex = try? NSRegularExpression(pattern: #"^(?i)\s*(?:fwd|fw)\s*:\s*"#),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  let range = Range(match.range, in: normalized) else {
                break
            }
            normalized.removeSubrange(range)
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? subject : trimmed
    }
}
