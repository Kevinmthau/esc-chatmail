import CryptoKit
import Foundation
import UIKit

struct EmailPreviewSnapshotCacheEntry: Equatable, Sendable {
    let imageData: Data
    let displayHeight: CGFloat
    let pixelScale: CGFloat
    let createdAt: Date
}

enum EmailPreviewSnapshotCacheKey {
    static let rendererVersion = "snapshot-v4"

    static func make(
        previewCacheKey: String,
        renderedHTML: String,
        containerWidth: CGFloat,
        isDarkMode: Bool
    ) -> String {
        let roundedWidth = max(1, Int(containerWidth.rounded()))
        return [
            previewCacheKey,
            "html:\(contentFingerprint(for: renderedHTML))",
            "width:\(roundedWidth)",
            "dark:\(isDarkMode)",
            "renderer:\(rendererVersion)"
        ].joined(separator: "|")
    }

    static func filenameComponent(for cacheKey: String) -> String {
        SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func contentFingerprint(for html: String) -> String {
        SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor EmailPreviewSnapshotCache: PeriodicCleanupHandler {
    static let shared = EmailPreviewSnapshotCache(startsPeriodicCleanup: true)

    private struct Metadata: Codable {
        let displayHeight: Double
        let pixelScale: Double
        let createdAt: TimeInterval
        let imageByteCount: Int
    }

    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval
    private let maxCacheSize: Int64
    private let fileManager: FileManager
    private let cleanupTask = PeriodicCleanupTask()
    private var isCleaningUp = false

    init(
        cacheDirectory: URL? = nil,
        maxCacheAge: TimeInterval = 7 * 24 * 60 * 60,
        maxCacheSize: Int64 = 50 * 1024 * 1024,
        fileManager: FileManager = .default,
        startsPeriodicCleanup: Bool = false
    ) {
        self.fileManager = fileManager
        self.maxCacheAge = maxCacheAge
        self.maxCacheSize = maxCacheSize

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.cacheDirectory = cachesRoot.appendingPathComponent("EmailPreviewSnapshots", isDirectory: true)
        }

        Self.createDirectoryIfNeeded(at: self.cacheDirectory, fileManager: fileManager)

        if startsPeriodicCleanup {
            Task { self.cleanupTask.start(handler: self, interval: .hours(1), runImmediately: true) }
        }
    }

    func load(for cacheKey: String) -> EmailPreviewSnapshotCacheEntry? {
        let paths = paths(for: cacheKey)
        guard fileManager.fileExists(atPath: paths.image.path),
              fileManager.fileExists(atPath: paths.metadata.path),
              let metadataData = FileSystemErrorHandler.loadData(from: paths.metadata, category: .general),
              let imageData = FileSystemErrorHandler.loadData(from: paths.image, category: .general),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData) else {
            removeFiles(for: cacheKey)
            return nil
        }

        let createdAt = Date(timeIntervalSince1970: metadata.createdAt)
        guard Date().timeIntervalSince(createdAt) <= maxCacheAge else {
            removeFiles(for: cacheKey)
            return nil
        }

        touch(paths.image)
        touch(paths.metadata)

        return EmailPreviewSnapshotCacheEntry(
            imageData: imageData,
            displayHeight: CGFloat(metadata.displayHeight),
            pixelScale: CGFloat(metadata.pixelScale),
            createdAt: createdAt
        )
    }

    @discardableResult
    func store(
        image: UIImage,
        displayHeight: CGFloat,
        pixelScale: CGFloat,
        for cacheKey: String
    ) -> EmailPreviewSnapshotCacheEntry? {
        guard let imageData = image.jpegData(compressionQuality: 0.82) ?? image.pngData() else {
            return nil
        }

        let now = Date()
        let metadata = Metadata(
            displayHeight: Double(HTMLPreviewSizing.clampedHeight(displayHeight)),
            pixelScale: Double(pixelScale),
            createdAt: now.timeIntervalSince1970,
            imageByteCount: imageData.count
        )

        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            return nil
        }

        Self.createDirectoryIfNeeded(at: cacheDirectory, fileManager: fileManager)
        let paths = paths(for: cacheKey)
        let wroteImage = FileSystemErrorHandler.writeData(imageData, to: paths.image, category: .general)
        let wroteMetadata = FileSystemErrorHandler.writeData(metadataData, to: paths.metadata, category: .general)
        guard wroteImage, wroteMetadata else {
            removeFiles(for: cacheKey)
            return nil
        }

        return EmailPreviewSnapshotCacheEntry(
            imageData: imageData,
            displayHeight: CGFloat(metadata.displayHeight),
            pixelScale: CGFloat(metadata.pixelScale),
            createdAt: now
        )
    }

    func remove(for cacheKey: String) {
        removeFiles(for: cacheKey)
    }

    func clearAll() {
        FileSystemErrorHandler.removeItem(at: cacheDirectory, category: .general)
        Self.createDirectoryIfNeeded(at: cacheDirectory, fileManager: fileManager)
    }

    func performCleanup() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        let cacheDirectory = self.cacheDirectory
        let maxCacheAge = self.maxCacheAge
        let maxCacheSize = self.maxCacheSize
        let fileManager = self.fileManager
        await Task.detached(priority: .utility) {
            Self.performCleanup(
                cacheDirectory: cacheDirectory,
                maxCacheAge: maxCacheAge,
                maxCacheSize: maxCacheSize,
                fileManager: fileManager
            )
        }.value
        isCleaningUp = false
    }

    private func paths(for cacheKey: String) -> (image: URL, metadata: URL) {
        let component = EmailPreviewSnapshotCacheKey.filenameComponent(for: cacheKey)
        return (
            cacheDirectory.appendingPathComponent("\(component).jpg"),
            cacheDirectory.appendingPathComponent("\(component).json")
        )
    }

    private func removeFiles(for cacheKey: String) {
        let paths = paths(for: cacheKey)
        FileSystemErrorHandler.removeItem(at: paths.image, category: .general)
        FileSystemErrorHandler.removeItem(at: paths.metadata, category: .general)
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func createDirectoryIfNeeded(at directory: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: directory.path) else {
            return
        }
        FileSystemErrorHandler.createDirectory(at: directory, category: .general)
    }

    private static func performCleanup(
        cacheDirectory: URL,
        maxCacheAge: TimeInterval,
        maxCacheSize: Int64,
        fileManager: FileManager
    ) {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        var liveFiles: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let fileSize = values.fileSize else {
                continue
            }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > maxCacheAge {
                FileSystemErrorHandler.removeItem(at: fileURL, category: .general)
                continue
            }

            let size = Int64(fileSize)
            totalSize += size
            liveFiles.append((fileURL, modifiedAt, size))
        }

        guard totalSize > maxCacheSize else {
            return
        }

        for file in liveFiles.sorted(by: { $0.date < $1.date }) {
            guard totalSize > maxCacheSize else {
                break
            }

            FileSystemErrorHandler.removeItem(at: file.url, category: .general)
            totalSize -= file.size
        }
    }
}
