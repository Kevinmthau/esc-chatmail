import Foundation
import UIKit

/// Stores avatar images as binary files on disk instead of base64 strings in Core Data.
/// This reduces database bloat by ~33% and improves query performance.
actor AvatarStorage {
    static let shared = AvatarStorage()

    private nonisolated let avatarsDirectory: URL
    private let fileManager = FileManager.default

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.avatarsDirectory = documentsPath.appendingPathComponent("Avatars")
        Self.createDirectoryIfNeeded(at: avatarsDirectory)
    }

    private static func createDirectoryIfNeeded(at directory: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            FileSystemErrorHandler.createDirectory(at: directory, category: .general)
        }
    }

    // MARK: - Public API

    /// Saves avatar image data and returns a file:// URL string for storage in Core Data
    func saveAvatar(for email: String, imageData: Data) -> String? {
        let filename = safeFilename(for: email)
        let fileURL = avatarsDirectory.appendingPathComponent(filename)

        do {
            // Compress image if it's too large (> 50KB)
            let dataToSave: Data
            if imageData.count > 50_000, let image = UIImage(data: imageData) {
                dataToSave = image.jpegData(compressionQuality: 0.7) ?? imageData
            } else {
                dataToSave = imageData
            }

            try dataToSave.write(to: fileURL, options: .atomic)
            return fileURL.absoluteString
        } catch {
            Log.error("Failed to save avatar for \(email)", category: .general, error: error)
            return nil
        }
    }

    /// Loads avatar image data from a file:// URL
    func loadAvatar(from urlString: String) -> Data? {
        guard urlString.hasPrefix("file://"),
              let url = URL(string: urlString) else {
            return nil
        }

        return FileSystemErrorHandler.loadData(from: url, category: .general)
    }

    /// Checks if avatar exists for email
    func avatarExists(for email: String) -> Bool {
        let filename = safeFilename(for: email)
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Gets the file URL for an email's avatar (whether it exists or not)
    func avatarURL(for email: String) -> String {
        let filename = safeFilename(for: email)
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        return fileURL.absoluteString
    }

    /// Deletes avatar for email
    func deleteAvatar(for email: String) {
        let filename = safeFilename(for: email)
        let fileURL = avatarsDirectory.appendingPathComponent(filename)
        FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
    }

    /// Deletes all cached avatars
    func deleteAllAvatars() {
        FileSystemErrorHandler.removeItem(at: avatarsDirectory, category: .general)
        Self.createDirectoryIfNeeded(at: avatarsDirectory)
    }

    /// Calculates total storage used by avatars
    func calculateStorageSize() -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(at: avatarsDirectory,
                                                   includingPropertiesForKeys: [.fileSizeKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    // MARK: - Migration

    /// Migrates base64 data URLs to file storage
    /// Returns the new file:// URL if migration succeeded, nil otherwise
    func migrateFromBase64(email: String, base64URL: String) -> String? {
        guard base64URL.hasPrefix("data:image") else { return nil }

        // Extract base64 data
        guard let commaIndex = base64URL.firstIndex(of: ",") else { return nil }
        let base64String = String(base64URL[base64URL.index(after: commaIndex)...])
        guard let imageData = Data(base64Encoded: base64String) else { return nil }

        // Save to file
        return saveAvatar(for: email, imageData: imageData)
    }

    // MARK: - Private Helpers

    private func safeFilename(for email: String) -> String {
        // Create a safe filename from email by hashing it
        let normalized = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = normalized.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(32) ?? "unknown"
        return "\(hash).jpg"
    }
}
