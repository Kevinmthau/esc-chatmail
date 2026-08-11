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

    /// Collision-safe local path for rendering or opening attachment bytes.
    /// Legacy ID-only paths for remote attachments remain persisted only long
    /// enough to trigger migration and must never be exposed to a reader.
    var readableLocalURLValue: String? {
        readableStoragePath(localURL)
    }

    /// Collision-safe preview path for rendering attachment thumbnails.
    var readablePreviewURLValue: String? {
        readableStoragePath(previewURL)
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
        guard FileManager.default.fileExists(atPath: fullURL.path) else { return true }

        // Files written before remote attachment storage became message-scoped
        // can alias a sibling message that reuses the same Gmail attachment ID.
        // Lazily replace the file when the attachment next appears instead of
        // exposing bytes that may have been overwritten by a sibling message.
        let requiresMessageScopedIdentity = !isLocalAttachment ||
            (id?.hasPrefix("local_inline_") ?? false)
        if requiresMessageScopedIdentity {
            guard let messageId = message?.id, let attachmentId = id else {
                return true
            }
            if !AttachmentPaths.usesRemoteIdentity(
                localPath,
                messageId: messageId,
                attachmentId: attachmentId
            ) {
                return true
            }
            if let previewPath = previewURL,
               !AttachmentPaths.usesRemoteIdentity(
                   previewPath,
                   messageId: messageId,
                   attachmentId: attachmentId
               ) {
                return true
            }
        }

        return false
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

    private func readableStoragePath(_ path: String?) -> String? {
        guard let attachmentId = id,
              AttachmentPaths.isReadableStoragePath(
                  path,
                  messageId: message?.id,
                  attachmentId: attachmentId
              ) else {
            return nil
        }
        return path
    }
}
