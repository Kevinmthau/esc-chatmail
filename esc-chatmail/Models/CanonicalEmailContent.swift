import CryptoKit
import Foundation

enum CanonicalEmailSourceKind: String, Equatable, Sendable {
    case html
    case plainText
    case recoveredHTML
}

enum CanonicalEmailSourceLocation: String, Equatable, Sendable {
    case messageFile
    case storageURI
    case rawSourceHTML
    case recoveredHTML
    case plainText
}

struct CanonicalEmailContent: Equatable, Sendable {
    let html: String?
    let plainText: String?
    let hasHTMLSource: Bool
    let sourceSignature: String
    let sourceKind: CanonicalEmailSourceKind
    let sourceLocation: CanonicalEmailSourceLocation
    let inlineAttachmentContentIDs: [String]

    init(
        html: String?,
        plainText: String?,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        sourceSignature: String? = nil,
        inlineAttachmentContentIDs: [String] = []
    ) {
        let normalizedHTML = Self.normalizedNonEmpty(html)
        let normalizedPlainText = Self.normalizedNonEmpty(plainText)

        self.html = normalizedHTML
        self.plainText = normalizedPlainText
        self.hasHTMLSource = normalizedHTML != nil
        self.sourceKind = sourceKind
        self.sourceLocation = sourceLocation
        self.sourceSignature = sourceSignature ?? Self.makeSourceSignature(
            html: normalizedHTML,
            plainText: normalizedPlainText,
            sourceKind: sourceKind
        )
        self.inlineAttachmentContentIDs = inlineAttachmentContentIDs
    }

    private static func normalizedNonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeSourceSignature(
        html: String?,
        plainText: String?,
        sourceKind: CanonicalEmailSourceKind
    ) -> String {
        let sourceText = html ?? plainText ?? ""
        let digest = SHA256.hash(data: Data(sourceText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(sourceKind.rawValue):\(digest)"
    }
}
