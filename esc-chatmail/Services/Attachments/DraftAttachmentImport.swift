import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared policy for locally imported compose and reply attachments.
enum DraftAttachmentImport {
    // An app attachment budget, not an exact provider MIME/request-size limit.
    static let maximumTotalBytes: Int64 = 25 * 1024 * 1024

    struct PreparedImage: Sendable {
        let data: Data
        let size: CGSize
        let mimeType: String
        let fileExtension: String

        func filename(replacingExtensionOf filename: String) -> String {
            (filename as NSString).deletingPathExtension + "." + fileExtension
        }
    }

    enum ImportError: LocalizedError {
        case sizeLimit(filename: String)
        case unreadable(filename: String)
        case cannotSave(filename: String)

        var errorDescription: String? {
            switch self {
            case .sizeLimit(let filename):
                return "\(filename) would exceed the 25 MB combined attachment budget. Choose a smaller file or remove another attachment."
            case .unreadable(let filename):
                return "\(filename) could not be read. Try selecting it again."
            case .cannotSave(let filename):
                return "\(filename) could not be saved. Free some device storage and try again."
            }
        }
    }

    static func validateSize(byteCount: Int64, existingByteCount: Int64, filename: String) throws {
        guard byteCount >= 0, existingByteCount >= 0,
              existingByteCount <= maximumTotalBytes,
              byteCount <= maximumTotalBytes - existingByteCount else {
            throw ImportError.sizeLimit(filename: filename)
        }
    }

    static func totalByteCount(_ sizes: [Int64]) -> Int64 {
        sizes.reduce(0) { total, size in
            min(maximumTotalBytes + 1, total + min(maximumTotalBytes + 1, max(0, size)))
        }
    }

    static func preflightDocument(at url: URL, existingByteCount: Int64) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize else {
            throw ImportError.unreadable(filename: url.lastPathComponent)
        }
        try validateSize(
            byteCount: Int64(byteCount),
            existingByteCount: existingByteCount,
            filename: url.lastPathComponent
        )
    }

    static func prepareImage(
        data: Data,
        filename: String,
        existingByteCount: Int64
    ) throws -> PreparedImage {
        try validateSize(byteCount: Int64(data.count), existingByteCount: existingByteCount, filename: filename)
        let (processed, size) = ImageProcessor.processImage(data: data)
        guard let processed, let size,
              let source = CGImageSourceCreateWithData(processed as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let mimeType = type.preferredMIMEType,
              let fileExtension = type.preferredFilenameExtension else {
            throw ImportError.unreadable(filename: filename)
        }
        try validateSize(byteCount: Int64(processed.count), existingByteCount: existingByteCount, filename: filename)
        return PreparedImage(data: processed, size: size, mimeType: mimeType, fileExtension: fileExtension)
    }

    static func failureMessage(_ failures: [String]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.joined(separator: "\n\n")
    }
}
