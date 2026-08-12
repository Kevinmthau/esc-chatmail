import Foundation
import CryptoKit

struct AttachmentPaths {
    struct SynthesizedInlinePayload: Sendable {
        let attachmentId: String
        let data: Data
        let filename: String
        let mimeType: String
        let contentId: String?
        let size: Int
    }

    /// CANONICAL directory names — account-boundary inspection and cleanup
    /// (AccountScopedMailboxFileInspector, FreshInstallHandler) reference
    /// these; never duplicate the literals.
    static let attachmentsFolder = "Attachments"
    static let previewsFolder = "Previews"
    /// Legacy caches-directory folder: nothing creates it anymore, it is only
    /// inspected and removed during account cleanup.
    static let legacyAttachmentCacheFolder = "AttachmentCache"
    
    static func setupDirectories() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let attachmentsURL = appSupportURL.appendingPathComponent(attachmentsFolder)
        let previewsURL = appSupportURL.appendingPathComponent(previewsFolder)

        FileSystemErrorHandler.createDirectory(at: attachmentsURL, category: .attachment)
        FileSystemErrorHandler.createDirectory(at: previewsURL, category: .attachment)
    }
    
    static func originalPath(idOrUUID: String, ext: String) -> String {
        let filename = sanitizeFilename(idOrUUID)
        return "\(attachmentsFolder)/\(filename).\(ext)"
    }

    /// Returns a message-scoped path for a remote Gmail attachment.
    ///
    /// Gmail attachment IDs are only meaningful together with their message ID.
    /// Keeping both values in the storage identity prevents two messages that
    /// happen to reuse an attachment ID from sharing one file on disk.
    static func originalPath(messageId: String, attachmentId: String, ext: String) -> String {
        "\(attachmentsFolder)/\(remoteStorageIdentifier(messageId: messageId, attachmentId: attachmentId)).\(ext)"
    }
    
    static func previewPath(idOrUUID: String, ext: String = "jpg") -> String {
        let filename = sanitizeFilename(idOrUUID)
        return "\(previewsFolder)/\(filename).\(ext)"
    }

    static func previewPath(
        messageId: String,
        attachmentId: String,
        ext: String = "jpg"
    ) -> String {
        "\(previewsFolder)/\(remoteStorageIdentifier(messageId: messageId, attachmentId: attachmentId)).\(ext)"
    }

    /// An opaque, stable identity suitable for in-memory attachment caches.
    /// Any attachment linked to a message uses the composite identity. This
    /// includes synthesized `local_inline_*` rows whose IDs can repeat across
    /// messages. Nil-message compose attachments retain ID-only compatibility.
    static func cacheIdentity(messageId: String?, attachmentId: String) -> String {
        guard let messageId, !messageId.isEmpty else {
            return attachmentId
        }
        return remoteStorageIdentifier(messageId: messageId, attachmentId: attachmentId)
    }

    /// Whether a persisted remote attachment path uses the current composite
    /// identity. Existing ID-only paths remain persisted only to identify rows
    /// that need lazy migration; readers must not expose their bytes.
    static func usesRemoteIdentity(
        _ relativePath: String?,
        messageId: String,
        attachmentId: String
    ) -> Bool {
        guard let relativePath else { return false }
        let filename = URL(fileURLWithPath: relativePath)
            .deletingPathExtension()
            .lastPathComponent
        return filename == remoteStorageIdentifier(
            messageId: messageId,
            attachmentId: attachmentId
        )
    }

    /// Whether a stored attachment path is safe to read for the supplied
    /// attachment identity. Remote attachment IDs are not globally unique, so
    /// their files are usable only when the path proves the composite message
    /// and attachment identity. Locally-created compose attachments retain
    /// their ID-only storage layout.
    static func isReadableStoragePath(
        _ relativePath: String?,
        messageId: String?,
        attachmentId: String
    ) -> Bool {
        guard let relativePath, !relativePath.isEmpty else { return false }
        // `local_inline_*` rows are synthesized from received message parts.
        // Their deterministic IDs can repeat across messages, so they require
        // the same composite identity as Gmail-backed remote attachments.
        if attachmentId.hasPrefix("local_") && !attachmentId.hasPrefix("local_inline_") {
            return true
        }
        guard let messageId, !messageId.isEmpty else { return false }
        return usesRemoteIdentity(
            relativePath,
            messageId: messageId,
            attachmentId: attachmentId
        )
    }

    /// Extracts authoritative embedded attachment bytes from a full Gmail
    /// message. Legacy `local_inline_*` files used an attachment-only path that
    /// could be shared by sibling messages, so those bytes must never be copied
    /// into message-scoped storage. Recomputing the deterministic ID from this
    /// message's MIME part proves the recovered payload belongs to this row.
    static func synthesizedInlinePayloads(
        in gmailMessage: GmailMessage
    ) -> [String: SynthesizedInlinePayload] {
        guard let payload = gmailMessage.payload else { return [:] }

        var recovered: [String: SynthesizedInlinePayload] = [:]

        func traverse(_ part: MessagePart) {
            let trimmedFilename = part.filename?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mimeType = part.mimeType ?? "application/octet-stream"
            let contentId = part.headers?
                .first(where: { $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame })?
                .value
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

            if part.body?.attachmentId == nil,
               !(part.mimeType?.hasPrefix("multipart/") ?? false),
               let encodedData = part.body?.data,
               shouldTreatInlineDataPartAsAttachment(
                   part,
                   trimmedFilename: trimmedFilename,
                   contentId: contentId
               ),
               let decodedData = decodeGmailBase64Data(encodedData) {
                let size = part.body?.size ?? decodedData.count
                let attachmentId = synthesizedInlineAttachmentID(
                    partId: part.partId,
                    trimmedFilename: trimmedFilename,
                    mimeType: mimeType,
                    contentId: contentId,
                    size: size
                )
                if recovered[attachmentId] == nil {
                    let filename = trimmedFilename.isEmpty
                        ? "attachment.\(fileExtension(for: mimeType))"
                        : trimmedFilename
                    recovered[attachmentId] = SynthesizedInlinePayload(
                        attachmentId: attachmentId,
                        data: decodedData,
                        filename: filename,
                        mimeType: mimeType,
                        contentId: contentId,
                        size: size
                    )
                }
            }

            part.parts?.forEach(traverse)
        }

        traverse(payload)
        return recovered
    }

    static func synthesizedInlineAttachmentID(
        partId: String?,
        trimmedFilename: String,
        mimeType: String,
        contentId: String?,
        size: Int
    ) -> String {
        let fingerprint = "\(partId ?? "")|\(trimmedFilename)|\(mimeType)|\(contentId ?? "")|\(size)"
        let hash = SHA256.hash(data: Data(fingerprint.utf8))
        let hashHex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "local_inline_\(hashHex)"
    }

    private static func shouldTreatInlineDataPartAsAttachment(
        _ part: MessagePart,
        trimmedFilename: String,
        contentId: String?
    ) -> Bool {
        let contentDisposition = part.headers?
            .first(where: { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame })?
            .value
            .lowercased() ?? ""

        if contentDisposition.contains("attachment") || !trimmedFilename.isEmpty {
            return true
        }
        if contentDisposition.contains("inline"), contentId?.isEmpty == false {
            return true
        }
        return (part.mimeType?.lowercased().hasPrefix("image/") ?? false) &&
            contentId?.isEmpty == false
    }

    private static func decodeGmailBase64Data(_ encodedData: String) -> Data? {
        let normalized = encodedData
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")
        let remainder = normalized.count % 4
        let padded = remainder == 0
            ? normalized
            : normalized + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
    }

    private static func remoteStorageIdentifier(
        messageId: String,
        attachmentId: String
    ) -> String {
        // Length-prefix both values so concatenation is unambiguous before
        // hashing. Forty hex characters provide a compact 160-bit identity
        // while keeping filenames comfortably below filesystem limits.
        let identity = "\(messageId.utf8.count):\(messageId)\(attachmentId.utf8.count):\(attachmentId)"
        let hashed = SHA256.hash(data: Data(identity.utf8))
        let hashString = hashed.map { String(format: "%02x", $0) }.joined()
        return "remote_\(hashString.prefix(40))"
    }
    
    private static func sanitizeFilename(_ id: String) -> String {
        // If the ID is too long (>50 chars), use a hash instead
        // iOS has a 255 byte filename limit, but we want to be conservative
        if id.count > 50 {
            // Create a stable SHA256 hash of the long ID
            let inputData = Data(id.utf8)
            let hashed = SHA256.hash(data: inputData)
            // Convert to hex string (64 chars)
            let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
            // Take first 32 chars of hash for a reasonable filename
            return String(hashString.prefix(32))
        }
        // Also sanitize any potentially problematic characters
        let sanitized = id.replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: "\\", with: "_")
                          .replacingOccurrences(of: ":", with: "_")
        return sanitized
    }
    
    static func fullURL(for relativePath: String?) -> URL? {
        guard let relativePath = relativePath,
              let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL.appendingPathComponent(relativePath)
    }
    
    static func relativePath(from url: URL) -> String? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let appSupportPath = appSupportURL.path
        let urlPath = url.path
        
        if urlPath.hasPrefix(appSupportPath) {
            return String(urlPath.dropFirst(appSupportPath.count + 1))
        }
        return nil
    }
    
    static func saveData(_ data: Data, to relativePath: String) -> Bool {
        guard let url = fullURL(for: relativePath) else { return false }
        
        do {
            try data.write(to: url)
            return true
        } catch {
            Log.error("Failed to save attachment data", category: .attachment, error: error)
            return false
        }
    }
    
    static func loadData(from relativePath: String?) -> Data? {
        guard let url = fullURL(for: relativePath) else { return nil }
        return FileSystemErrorHandler.loadData(from: url, category: .attachment)
    }

    static func deleteFile(at relativePath: String?) {
        guard let url = fullURL(for: relativePath) else { return }
        FileSystemErrorHandler.removeItem(at: url, category: .attachment)
    }
    
    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        // Images
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/heic", "image/heif":
            return "heic"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/bmp":
            return "bmp"
        case "image/tiff":
            return "tiff"

        // PDF
        case "application/pdf":
            return "pdf"

        // Video
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "video/x-m4v":
            return "m4v"

        // Microsoft Word
        case "application/msword":
            return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"

        // Microsoft Excel
        case "application/vnd.ms-excel":
            return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
            return "xlsx"

        // Microsoft PowerPoint
        case "application/vnd.ms-powerpoint":
            return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return "pptx"

        // Apple iWork
        case "application/vnd.apple.pages", "application/x-iwork-pages-sffpages":
            return "pages"
        case "application/vnd.apple.numbers", "application/x-iwork-numbers-sffnumbers":
            return "numbers"
        case "application/vnd.apple.keynote", "application/x-iwork-keynote-sffkey":
            return "keynote"

        // Text files
        case "text/plain":
            return "txt"
        case "text/csv":
            return "csv"
        case "text/rtf", "application/rtf":
            return "rtf"
        case "text/html":
            return "html"
        case "text/xml", "application/xml":
            return "xml"
        case "application/json":
            return "json"

        // Archives
        case "application/zip", "application/x-zip-compressed":
            return "zip"
        case "application/x-rar-compressed":
            return "rar"
        case "application/x-7z-compressed":
            return "7z"
        case "application/gzip":
            return "gz"
        case "application/x-tar":
            return "tar"

        // Fallbacks with pattern matching
        case let type where type.contains("image"):
            return "jpg"
        case let type where type.contains("pdf"):
            return "pdf"
        case let type where type.contains("word"):
            return "docx"
        case let type where type.contains("excel") || type.contains("spreadsheet"):
            return "xlsx"
        case let type where type.contains("powerpoint") || type.contains("presentation"):
            return "pptx"
        case let type where type.contains("pages"):
            return "pages"
        case let type where type.contains("numbers"):
            return "numbers"
        case let type where type.contains("keynote"):
            return "keynote"
        case let type where type.contains("video"):
            return "mp4"

        default:
            return "dat"
        }
    }
}
