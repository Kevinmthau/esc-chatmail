import Foundation
import CoreData

/// Shared shape of the two attachment representations the chat UI filters for
/// display: the Core Data `Attachment` and its row-model snapshot
/// `ChatMessageAttachmentModel`.
protocol DisplayFilterableAttachment {
    var contentId: String? { get }
    var filename: String { get }
    var mimeType: String { get }
    var byteSize: Int64 { get }
    var pageCount: Int16 { get }
    var width: Int16 { get }
    var height: Int16 { get }
    var localURL: String? { get }
    var objectID: NSManagedObjectID { get }
    var isReady: Bool { get }
    var isLikelySignatureImage: Bool { get }
    var isCalendarInviteAttachment: Bool { get }
}

extension Attachment: DisplayFilterableAttachment {}
extension ChatMessageAttachmentModel: DisplayFilterableAttachment {}

private enum AttachmentDeduplicationKey: Hashable {
    case contentId(String)
    case file(filename: String, mimeType: String, byteSize: Int64)
    case objectID(NSManagedObjectID)
}

/// Canonical implementation of the chat-UI attachment display filter:
/// signature-image filter → non-displayable CID filter → sender guard →
/// referenced-CID filter → calendar-invite filter, over deduplicated
/// attachments. `Message` and `ChatMessageRowModel` both delegate here.
enum AttachmentDisplayFilter {
    /// Attachments suitable for display in the chat UI, filtered against a
    /// precomputed HTML analysis (the live render path builds the analysis via
    /// MessageBubbleHTMLAnalysisBuilder; ChatMessageRowModel carries the
    /// snapshot equivalent for bubbles).
    static func displayableAttachments<A: DisplayFilterableAttachment>(
        in attachments: [A],
        using htmlAnalysis: MessageBubbleHTMLAnalysis,
        isFromMe: Bool,
        hidingInlineReferencedInHTML: Bool,
        hidingCalendarInviteAttachments: Bool?
    ) -> [A] {
        let allAttachments = deduplicatedAttachments(in: attachments.filter { attachment in
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

        let cidFilteredAttachments: [A]
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
    static func deduplicatedAttachments<A: DisplayFilterableAttachment>(in attachments: [A]) -> [A] {
        var bestByKey: [AttachmentDeduplicationKey: (index: Int, attachment: A)] = [:]
        var deduplicated: [A] = []

        for attachment in attachments {
            let key = deduplicationKey(for: attachment)

            if let existing = bestByKey[key] {
                if retentionScore(attachment) > retentionScore(existing.attachment) {
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

    private static func deduplicationKey(
        for attachment: some DisplayFilterableAttachment
    ) -> AttachmentDeduplicationKey {
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

    /// Prefers the copy most useful to keep: ready state dominates, then a
    /// local file, then known size and media metadata.
    private static func retentionScore(_ attachment: some DisplayFilterableAttachment) -> Int {
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
}
