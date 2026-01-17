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

    /// Array of attachments for convenient iteration
    var attachmentsArray: [Attachment] {
        Array(typedAttachments)
    }

    /// Attachments suitable for display (excludes likely signature images)
    var displayableAttachments: [Attachment] {
        attachmentsArray.filter { !$0.isLikelySignatureImage }
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

    /// Checks if the message is a forwarded email by looking for forward indicators
    var isForwardedEmail: Bool {
        // Check subject line for "FW:" or "Fwd:" prefix
        if let subject = subject, !subject.isEmpty {
            let subjectLower = subject.lowercased()
            if subjectLower.hasPrefix("fwd:") ||
               subjectLower.hasPrefix("fw:") ||
               subjectLower.contains("fwd:") ||
               subjectLower.contains("fw:") {
                return true
            }
        }

        // Check body content for strong forward indicators
        let bodyText = [snippet, cleanedSnippet].compactMap { $0 }.joined(separator: " ")

        let strongForwardIndicators = [
            "Begin forwarded message:",
            "---------- Forwarded message",
            "------ Original Message ------",
            "-----Original Message-----",
            "Forwarded message from"
        ]

        for indicator in strongForwardIndicators {
            if bodyText.range(of: indicator, options: .caseInsensitive) != nil {
                return true
            }
        }

        return false
    }
}
