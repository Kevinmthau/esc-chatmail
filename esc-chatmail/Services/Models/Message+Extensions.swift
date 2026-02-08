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
        let allAttachments = attachmentsArray.filter { !$0.isLikelySignatureImage }

        // Only filter inline images for received messages that will display HTML
        // Messages from the user (isFromMe) display as plain text, so their inline images
        // need to show in the attachment grid
        guard !isFromMe else {
            return allAttachments
        }

        // If message has HTML content, filter out attachments that are displayed inline via cid: URLs
        let referencedCIDs = extractReferencedContentIDs()
        guard !referencedCIDs.isEmpty else {
            return allAttachments
        }

        return allAttachments.filter { attachment in
            guard let contentId = attachment.contentId, !contentId.isEmpty else {
                return true // No Content-ID, always show
            }
            // Hide if this Content-ID is referenced in the HTML body
            return !referencedCIDs.contains(contentId)
        }
    }

    /// Extracts Content-IDs referenced via cid: URLs in the message's HTML body
    private func extractReferencedContentIDs() -> Set<String> {
        // Try to load HTML content for this message
        guard let html = HTMLContentHandler.shared.loadHTML(for: id) else {
            return []
        }

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
                if !contentId.isEmpty {
                    referencedCIDs.insert(contentId)
                }
            }

            searchRange = endOfCID..<html.endIndex
        }

        return referencedCIDs
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
}
