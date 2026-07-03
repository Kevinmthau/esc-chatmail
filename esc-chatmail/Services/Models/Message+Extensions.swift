import Foundation
import CoreData

private enum AttachmentDeduplicationKey: Hashable {
    case contentId(String)
    case file(filename: String, mimeType: String, byteSize: Int64)
    case objectID(NSManagedObjectID)
}

/// NSCache entry for the memoized calendar-invite likelihood.
private final class CalendarInviteLikelihoodEntry {
    let fingerprint: Int
    let value: Bool

    init(fingerprint: Int, value: Bool) {
        self.fingerprint = fingerprint
        self.value = value
    }
}

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
    @NSManaged public var chatPreviewText: String?
    @NSManaged public var deliveredToAddress: String?
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
    @NSManaged public var replyFromAddress: String?
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

    /// True when this outgoing message still has local attachments being uploaded.
    var isSendingLocalAttachments: Bool {
        guard isFromMe else { return false }
        return attachmentsArray.contains { attachment in
            attachment.isLocalAttachment &&
            (attachment.state == .queued || attachment.state == .uploading)
        }
    }

    /// True when a local attachment upload failed for this outgoing message.
    var hasFailedLocalAttachmentUploads: Bool {
        guard isFromMe else { return false }
        return attachmentsArray.contains { attachment in
            attachment.isLocalAttachment && attachment.state == .failed
        }
    }

    /// Memoized: the signal evaluation (raw-source sanitizer pass plus three
    /// text normalizations and regex scans) runs once per row-model mapping
    /// on the main actor, so repeated window resolutions re-paid it for every
    /// message. Keyed by objectID and invalidated by a fingerprint of the
    /// inputs; CalendarInviteSignals stays the single source of truth.
    var isLikelyCalendarInvite: Bool {
        let fingerprint = calendarInviteSignalFingerprint
        if let cached = Self.calendarInviteLikelihoodCache.object(forKey: objectID),
           cached.fingerprint == fingerprint {
            return cached.value
        }

        let value = computeIsLikelyCalendarInvite()
        Self.calendarInviteLikelihoodCache.setObject(
            CalendarInviteLikelihoodEntry(fingerprint: fingerprint, value: value),
            forKey: objectID
        )
        return value
    }

    private static let calendarInviteLikelihoodCache: NSCache<NSManagedObjectID, CalendarInviteLikelihoodEntry> = {
        let cache = NSCache<NSManagedObjectID, CalendarInviteLikelihoodEntry>()
        cache.countLimit = 512
        return cache
    }()

    private var calendarInviteSignalFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(subject)
        hasher.combine(cleanedSnippet ?? snippet)
        hasher.combine(bodyText)
        hasher.combine(attachmentsArray.contains { $0.isCalendarInviteAttachment })
        return hasher.finalize()
    }

    private func computeIsLikelyCalendarInvite() -> Bool {
        let normalizedSubject = CalendarInviteSignals.normalizedSignalText(subject).lowercased()
        let normalizedSnippet = CalendarInviteSignals.normalizedSignalText(cleanedSnippet ?? snippet).lowercased()
        let normalizedBody = CalendarInviteSignals.normalizedSignalText(
            bodyText.map { RawEmailSourceSanitizer.extractDisplayText(from: $0) }
        ).lowercased()
        let combinedText = [normalizedSubject, normalizedSnippet, normalizedBody]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let hasCalendarAttachment = attachmentsArray.contains { $0.isCalendarInviteAttachment }
        let hasGoogleCalendarMarker = CalendarInviteSignals.containsGoogleCalendarMarker(combinedText)
        let hasInviteSubjectPrefix = CalendarInviteSignals.hasInviteSubjectPrefix(normalizedSubject)
        let hasCalendarStructure =
            CalendarInviteSignals.structuralTextMarkers.filter { combinedText.contains($0) }.count >= 2
        let hasDateSignal = CalendarInviteSignals.containsDateTimeSignal(combinedText)

        if hasGoogleCalendarMarker {
            return true
        }

        if hasCalendarAttachment && (hasInviteSubjectPrefix || hasCalendarStructure || hasDateSignal) {
            return true
        }

        return hasInviteSubjectPrefix && hasCalendarStructure && hasDateSignal
    }

    /// Attachments suitable for display in the chat UI, filtered against a
    /// precomputed HTML analysis (the live render path builds the analysis via
    /// MessageBubbleHTMLAnalysisBuilder; ChatMessageRowModel carries the
    /// snapshot equivalent for bubbles).
    func displayableAttachments(
        using htmlAnalysis: MessageBubbleHTMLAnalysis,
        hidingInlineReferencedInHTML: Bool,
        hidingCalendarInviteAttachments: Bool? = nil
    ) -> [Attachment] {
        let allAttachments = deduplicatedAttachments(in: attachmentsArray.filter { attachment in
            guard !attachment.isLikelySignatureImage else { return false }

            guard let contentId = EmailDocument.normalizedContentID(attachment.contentId) else {
                return true
            }

            return !htmlAnalysis.nonDisplayableInlineContentIDs.contains(contentId)
        })

        guard hidingInlineReferencedInHTML else {
            return allAttachments
        }

        guard !isFromMe else {
            return allAttachments
        }

        let cidFilteredAttachments: [Attachment]
        if htmlAnalysis.referencedInlineContentIDs.isEmpty {
            cidFilteredAttachments = allAttachments
        } else {
            cidFilteredAttachments = allAttachments.filter { attachment in
                guard let contentId = EmailDocument.normalizedContentID(attachment.contentId) else {
                    return true
                }
                return !htmlAnalysis.referencedInlineContentIDs.contains(contentId)
            }
        }

        let shouldHideCalendarInviteAttachments =
            hidingCalendarInviteAttachments ?? htmlAnalysis.supportsCalendarInvitePreviewCard

        guard shouldHideCalendarInviteAttachments else {
            return cidFilteredAttachments
        }

        return cidFilteredAttachments.filter { !$0.isCalendarInviteAttachment }
    }

    /// Returns one canonical attachment per repeated Content-ID or repeated file fingerprint.
    /// This protects the UI and forward-compose flow from Gmail messages that repeat the same
    /// attachment part multiple times.
    func deduplicatedAttachments(in attachments: [Attachment]) -> [Attachment] {
        var bestByKey: [AttachmentDeduplicationKey: (index: Int, attachment: Attachment)] = [:]
        var deduplicated: [Attachment] = []

        for attachment in attachments {
            let key = attachmentDeduplicationKey(for: attachment)

            if let existing = bestByKey[key] {
                if shouldPreferDeduplicatedAttachment(attachment, over: existing.attachment) {
                    deduplicated[existing.index] = attachment
                    bestByKey[key] = (existing.index, attachment)
                }
                continue
            }

            bestByKey[key] = (deduplicated.count, attachment)
            deduplicated.append(attachment)
        }

        return deduplicated
    }

    var attachmentsForForwarding: [Attachment] {
        deduplicatedAttachments(in: attachmentsArray)
    }

    private func attachmentDeduplicationKey(for attachment: Attachment) -> AttachmentDeduplicationKey {
        if let contentId = EmailDocument.normalizedContentID(attachment.contentId) {
            return .contentId(contentId)
        }

        let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byteSize = attachment.byteSize

        if !filename.isEmpty || !mimeType.isEmpty || byteSize > 0 {
            return .file(filename: filename, mimeType: mimeType, byteSize: byteSize)
        }

        return .objectID(attachment.objectID)
    }

    private func shouldPreferDeduplicatedAttachment(_ lhs: Attachment, over rhs: Attachment) -> Bool {
        deduplicatedAttachmentRetentionScore(lhs) > deduplicatedAttachmentRetentionScore(rhs)
    }

    private func deduplicatedAttachmentRetentionScore(_ attachment: Attachment) -> Int {
        var score = 0

        if attachment.isReady {
            score += 4
        }
        if attachment.localURL != nil {
            score += 2
        }
        if attachment.byteSize > 0 {
            score += 1
        }
        if attachment.pageCount > 0 || attachment.width > 0 || attachment.height > 0 {
            score += 1
        }

        return score
    }

    /// Type-safe accessor for bodyText (alias for consistency)
    var bodyTextValue: String? {
        bodyText
    }

    /// Type-safe accessor for chatPreviewText (alias for consistency)
    var chatPreviewTextValue: String? {
        chatPreviewText
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
    /// Sent, forwarded, and newsletter messages keep original structure by default.
    var htmlDisplayCleanupMode: HTMLContentCleanupMode {
        if isFromMe || isForwardedEmail || isNewsletter {
            return .none
        }
        return .quotedAndSignature
    }

    /// Preferred one-line preview for conversation list rows.
    /// Forwarded messages use subject-based preview for better readability.
    var conversationPreviewText: String? {
        if let forwardedDisplaySubject {
            return "Fwd: \"\(forwardedDisplaySubject)\""
        }

        if isNewsletter, let subject = subject, !subject.isEmpty {
            return subject
        }

        return cleanedSnippet ?? snippet
    }

    var forwardedDisplaySubject: String? {
        guard isForwardedEmail,
              let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            return nil
        }

        return normalizedForwardSubject(from: subject)
    }

    var outgoingForwardedDisplayContent: ForwardedMessageDisplayContent? {
        guard isFromMe, isForwardedEmail else {
            return nil
        }

        return ForwardedMessageDisplayParser.parseOutgoingForward(
            from: bodyTextValue ?? snippet
        )
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
