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
        
        try? fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: previewsURL, withIntermediateDirectories: true)
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
        return try? Data(contentsOf: url)
    }
    
    static func deleteFile(at relativePath: String?) {
        guard let url = fullURL(for: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
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
        case "application/pdf":
            return "pdf"
        case let type where type.contains("image"):
            // Default for other image types
            return "jpg"
        case let type where type.contains("pdf"):
            return "pdf"
        default:
            return "dat"
        }
    }
}