import Foundation
import CoreData

extension Attachment {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Attachment> {
        return NSFetchRequest<Attachment>(entityName: "Attachment")
    }

    @NSManaged public var id: String?
    @NSManaged public var contentId: String?
    @NSManaged public var filename: String
    @NSManaged public var mimeType: String
    @NSManaged public var stateRaw: String
    @NSManaged public var localURL: String?
    @NSManaged public var previewURL: String?
    @NSManaged public var lastDownloadFailedAt: Date?
    @NSManaged public var byteSize: Int64
    @NSManaged public var pageCount: Int16
    @NSManaged public var width: Int16
    @NSManaged public var height: Int16
    @NSManaged public var message: Message?

    /// Whether this is a locally-created attachment (not yet synced)
    var isLocalAttachment: Bool {
        id?.starts(with: "local_") == true
    }

    /// Type-safe accessor for id (alias for consistency)
    var attachmentId: String? {
        id
    }

    /// Type-safe accessor for localURL (alias for consistency)
    var localURLValue: String? {
        localURL
    }

    /// Type-safe accessor for previewURL (alias for consistency)
    var previewURLValue: String? {
        previewURL
    }

    /// Type-safe accessor for filename with default
    var filenameValue: String {
        filename
    }

    /// Type-safe accessor for mimeType with default
    var mimeTypeValue: String {
        mimeType
    }

    var isCalendarInviteAttachment: Bool {
        let normalizedMimeType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedFilename = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedMimeType.hasPrefix("text/calendar") ||
            normalizedMimeType == "application/ics" ||
            normalizedMimeType == "application/ical" ||
            normalizedMimeType == "application/x-ical" ||
            normalizedFilename.hasSuffix(".ics")
    }

    /// Whether this attachment is marked as downloaded but the file is missing from disk
    var needsRedownload: Bool {
        guard state == .downloaded || state == .uploaded else { return false }
        guard let localPath = localURL else { return true }
        guard let fullURL = AttachmentPaths.fullURL(for: localPath) else { return true }
        return !FileManager.default.fileExists(atPath: fullURL.path)
    }

    /// Whether this attachment is likely a signature/logo image (small dimensions or tiny file size)
    var isLikelySignatureImage: Bool {
        guard mimeType.hasPrefix("image/") else { return false }

        // Small file size (< 10KB) - catches tracking pixels and small logos
        if byteSize > 0 && byteSize < AttachmentConfig.signatureImageMaxBytes {
            return true
        }

        // Small dimensions (both <= 100px) - catches logo images after download
        if width > 0 && height > 0 &&
           width <= AttachmentConfig.signatureImageMaxDimension &&
           height <= AttachmentConfig.signatureImageMaxDimension {
            return true
        }

        return false
    }

    var bubbleSnapshot: MessageBubbleAttachmentSnapshot {
        MessageBubbleAttachmentSnapshot(
            contentId: contentId,
            filename: filename,
            mimeType: mimeType,
            stateRaw: stateRaw,
            localURL: localURL,
            byteSize: byteSize,
            pageCount: pageCount,
            width: width,
            height: height
        )
    }
}
