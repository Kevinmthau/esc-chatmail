import Foundation
import CoreData

private enum AttachmentDeduplicationKey: Hashable {
    case contentId(String)
    case file(filename: String, mimeType: String, byteSize: Int64)
    case objectID(NSManagedObjectID)
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

    var isLikelyCalendarInvite: Bool {
        let normalizedSubject = normalizedCalendarInviteSignalText(subject).lowercased()
        let normalizedSnippet = normalizedCalendarInviteSignalText(cleanedSnippet ?? snippet).lowercased()
        let normalizedBody = normalizedCalendarInviteSignalText(
            bodyText.map { RawEmailSourceSanitizer.extractDisplayText(from: $0) }
        ).lowercased()
        let combinedText = [normalizedSubject, normalizedSnippet, normalizedBody]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let hasCalendarAttachment = attachmentsArray.contains { $0.isCalendarInviteAttachment }
        let hasGoogleCalendarMarker = Self.calendarInviteGoogleMarkers.contains { combinedText.contains($0) }
        let hasInviteSubjectPrefix = Self.calendarInviteSubjectPrefixes.contains { normalizedSubject.hasPrefix($0) }
        let hasCalendarStructure =
            Self.calendarInviteStructuralMarkers.filter { combinedText.contains($0) }.count >= 2
        let hasDateSignal =
            combinedText.range(
                of: Self.calendarInviteDatePattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil

        if hasGoogleCalendarMarker {
            return true
        }

        if hasCalendarAttachment && (hasInviteSubjectPrefix || hasCalendarStructure || hasDateSignal) {
            return true
        }

        return hasInviteSubjectPrefix && hasCalendarStructure && hasDateSignal
    }

    /// Attachments suitable for display (excludes signature images and inline images already shown in HTML)
    var displayableAttachments: [Attachment] {
        displayableAttachments(
            hidingInlineReferencedInHTML: true,
            hidingCalendarInviteAttachments: supportsCalendarInvitePreviewCard
        )
    }

    var supportsCalendarInvitePreviewCard: Bool {
        supportsCalendarInvitePreviewCard(canonicalHTML: loadHTMLSource())
    }

    /// Attachments suitable for display in the chat UI.
    /// - Parameters:
    ///   - hidingInlineReferencedInHTML: When true, hides inline `cid:` images that are referenced by the message HTML
    ///     (to avoid duplicating what the HTML renderer already shows). When false, keeps plain-text bubble behavior
    ///     but still hides signature/quoted-history inline images removed by HTML cleanup.
    func displayableAttachments(
        hidingInlineReferencedInHTML: Bool,
        hidingCalendarInviteAttachments: Bool? = nil
    ) -> [Attachment] {
        let html = loadHTMLSource()
        let nonDisplayableInlineContentIDs = extractNonDisplayableInlineContentIDs(from: html)
        let allAttachments = deduplicatedAttachments(in: attachmentsArray.filter { attachment in
            guard !attachment.isLikelySignatureImage else { return false }

            guard let contentId = normalizedContentID(from: attachment.contentId) else {
                return true
            }

            // Hide inline images that only appear in signature/quoted sections removed by cleanup.
            return !nonDisplayableInlineContentIDs.contains(contentId)
        })

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
        let cidFilteredAttachments: [Attachment]
        if referencedCIDs.isEmpty {
            cidFilteredAttachments = allAttachments
        } else {
            cidFilteredAttachments = allAttachments.filter { attachment in
                guard let contentId = normalizedContentID(from: attachment.contentId) else {
                    return true // No Content-ID, always show
                }
                // Hide if this Content-ID is referenced in the HTML body.
                return !referencedCIDs.contains(contentId)
            }
        }

        let shouldHideCalendarInviteAttachments =
            hidingCalendarInviteAttachments ?? supportsCalendarInvitePreviewCard(canonicalHTML: html)

        guard shouldHideCalendarInviteAttachments else {
            return cidFilteredAttachments
        }

        return cidFilteredAttachments.filter { !$0.isCalendarInviteAttachment }
    }

    func displayableAttachments(
        using htmlAnalysis: MessageBubbleHTMLAnalysis,
        hidingInlineReferencedInHTML: Bool,
        hidingCalendarInviteAttachments: Bool? = nil
    ) -> [Attachment] {
        let allAttachments = deduplicatedAttachments(in: attachmentsArray.filter { attachment in
            guard !attachment.isLikelySignatureImage else { return false }

            guard let contentId = normalizedContentID(from: attachment.contentId) else {
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
                guard let contentId = normalizedContentID(from: attachment.contentId) else {
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

    /// Hides inline images that appear only in sections removed by quote/signature cleanup.
    /// This keeps signature logos out of plain-text chat bubbles while preserving genuine inline content.
    private func extractNonDisplayableInlineContentIDs(from html: String?) -> Set<String> {
        guard let html else { return [] }

        let originalReferenced = extractReferencedContentIDs(from: html)
        guard !originalReferenced.isEmpty else { return [] }

        let cleaned = cleanedHTMLForAttachmentFiltering(from: html)
        let cleanedReferenced = extractReferencedContentIDs(from: cleaned)
        let removedByHTMLCleanup = originalReferenced.subtracting(cleanedReferenced)
        let likelySignatureInline = extractLikelySignatureInlineContentIDs(from: html)

        return removedByHTMLCleanup.union(likelySignatureInline)
    }

    private func loadHTMLSource() -> String? {
        let handler = HTMLContentHandler.shared
        if let html = handler.loadHTML(for: id) {
            return html
        }

        guard let bodyStorageURI else {
            return nil
        }

        // Migrate legacy absolute file URLs (e.g. older app container paths) into
        // the canonical Messages/<messageId>.html location when possible.
        if handler.migrateIfNeeded(from: bodyStorageURI),
           let migratedHTML = handler.loadHTML(for: id) {
            return migratedHTML
        }

        guard let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return handler.loadHTML(from: resolvedURL)
    }

    private func supportsCalendarInvitePreviewCard(canonicalHTML: String?) -> Bool {
        guard !isForwardedEmail, isLikelyCalendarInvite else {
            return false
        }

        let previewBuilder = CalendarInvitePreviewBuilder()
        return previewBuilder.buildPreview(
            canonicalHTML: canonicalHTML ?? "",
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        ) != nil
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

    private func normalizedCalendarInviteSignalText(_ text: String?) -> String {
        guard let text else {
            return ""
        }

        return HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                if char == "\"" || char == "'" || char == " " || char == "," ||
                    char == ">" || char == "<" {
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

    /// Extra fallback for Outlook/Word signatures where HTML signature wrappers are inconsistent.
    /// We only hide CIDs when the nearby HTML looks like a trailing sign-off/contact block
    /// and the attachment itself looks like a logo-style inline signature asset.
    private func extractLikelySignatureInlineContentIDs(from html: String) -> Set<String> {
        let lowercasedHTML = html.lowercased()
        guard lowercasedHTML.contains("cid:") else {
            return []
        }

        // Restrict detection to trailing markup where signatures normally live to avoid
        // global false positives from sender text that mentions role/contact words.
        let trailingWindow = String(lowercasedHTML.suffix(6_000))
        let hasSignatureSectionSignals =
            Self.signatureSignOffMarkers.contains { trailingWindow.contains($0) } &&
            (
                Self.signatureContactMarkers.contains { trailingWindow.contains($0) } ||
                Self.signatureRoleMarkers.contains { trailingWindow.contains($0) }
            )

        guard hasSignatureSectionSignals else {
            return []
        }

        let cidPrefix = "cid:"
        var nonDisplayable = Set<String>()
        var searchRange = html.startIndex..<html.endIndex

        while let cidRange = html.range(of: cidPrefix, options: .caseInsensitive, range: searchRange) {
            let startOfCID = cidRange.upperBound
            var endOfCID = startOfCID

            while endOfCID < html.endIndex {
                let char = html[endOfCID]
                if char == "\"" || char == "'" || char == " " || char == "," ||
                    char == ">" || char == "<" {
                    break
                }
                endOfCID = html.index(after: endOfCID)
            }

            defer {
                searchRange = endOfCID..<html.endIndex
            }

            guard startOfCID < endOfCID else { continue }
            guard let normalizedCID = normalizedContentID(from: String(html[startOfCID..<endOfCID])) else {
                continue
            }

            // Heuristic-only fallback: only treat trailing CIDs as likely signature assets.
            let cidOffset = html.distance(from: html.startIndex, to: startOfCID)
            let trailingThreshold = Int(Double(html.count) * 0.45)
            guard cidOffset >= trailingThreshold else {
                continue
            }

            guard isLikelySignatureInlineAttachment(contentID: normalizedCID) else {
                continue
            }
            nonDisplayable.insert(normalizedCID)
        }

        return nonDisplayable
    }

    private func isLikelySignatureInlineAttachment(contentID: String) -> Bool {
        guard let attachment = attachmentsArray.first(where: { normalizedContentID(from: $0.contentId) == contentID }) else {
            return false
        }

        guard attachment.mimeType.hasPrefix("image/") else {
            return false
        }

        let filename = attachment.filename.lowercased()
        let hasSignatureKeyword = filename.contains("logo") || filename.contains("signature") || filename.contains("footer")

        let isGeneratedInlineName = filename.range(
            of: #"^(?:image|img)\d{2,}(?:[_-]\d+)?\.[a-z0-9]{2,5}$"#,
            options: .regularExpression
        ) != nil

        let contentIDLocalPart = contentID.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? contentID
        let isGeneratedInlineContentID = contentIDLocalPart.range(
            of: #"^(?:image|img)\d{2,}(?:[_-]\d+)?(?:\.[a-z0-9]{2,5})?$"#,
            options: .regularExpression
        ) != nil

        let hasLogoLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width >= attachment.height &&
            attachment.width <= 320 &&
            attachment.height <= 120

        let looksLikeGeneratedInlineAsset = isGeneratedInlineName || isGeneratedInlineContentID
        return hasSignatureKeyword || (looksLikeGeneratedInlineAsset && hasLogoLikeDimensions)
    }

    private static let signatureSignOffMarkers = [
        "warmly",
        "best regards",
        "kind regards",
        "regards,",
        "sincerely",
        "thanks,",
        "thank you,",
        "cheers,"
    ]

    private static let signatureContactMarkers = [
        "mailto:",
        "tel:",
        "mobile",
        "phone",
        "www.",
        "linkedin",
        "instagram",
        "twitter"
    ]

    private static let signatureRoleMarkers = [
        "manager",
        "director",
        "president",
        "founder",
        "advisor",
        "broker",
        "realtor",
        "membership"
    ]

    private static let calendarInviteGoogleMarkers = [
        "google calendar",
        "calendar.google.com",
        "meet.google.com",
        "reply for ",
        "view all guest info"
    ]

    private static let calendarInviteSubjectPrefixes = [
        "invitation:",
        "updated invitation:",
        "canceled:",
        "cancelled:"
    ]

    private static let calendarInviteStructuralMarkers = [
        "\nwhen\n",
        "\nwhere\n",
        "\nguests\n",
        "\nmore options\n",
        "yes no maybe"
    ]

    private static let calendarInviteDatePattern = #"\b(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b[\w\s,.:()\-–•]*\b\d{1,2}:\d{2}\s*(?:am|pm)\b"#

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

    private func attachmentDeduplicationKey(for attachment: Attachment) -> AttachmentDeduplicationKey {
        if let contentId = normalizedContentID(from: attachment.contentId) {
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
