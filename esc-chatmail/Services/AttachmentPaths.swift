import Foundation
import CryptoKit

struct AttachmentPaths {
    private static let attachmentsFolder = "Attachments"
    private static let previewsFolder = "Previews"
    
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
    
    static func previewPath(idOrUUID: String, ext: String = "jpg") -> String {
        let filename = sanitizeFilename(idOrUUID)
        return "\(previewsFolder)/\(filename).\(ext)"
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
