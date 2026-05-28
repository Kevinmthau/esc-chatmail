import CryptoKit
import Foundation

protocol EmailPreviewSourceLoading: Sendable {
    func loadPreviewSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        allowRecovery: Bool
    ) async -> EmailPreviewSource?
}

final class EmailPreviewSourceLoader: EmailPreviewSourceLoading, @unchecked Sendable {
    static let shared = EmailPreviewSourceLoader()

    private final class CachedSourceBox {
        let source: EmailPreviewSource

        init(_ source: EmailPreviewSource) {
            self.source = source
        }
    }

    private let htmlContentLoader: HTMLContentLoader
    private let classifier: EmailPreviewClassifier
    private let imageExtractor: EmailPreviewImageExtractor
    private let cache = NSCache<NSString, CachedSourceBox>()

    init(
        htmlContentLoader: HTMLContentLoader = .shared,
        classifier: EmailPreviewClassifier = EmailPreviewClassifier(),
        imageExtractor: EmailPreviewImageExtractor = EmailPreviewImageExtractor()
    ) {
        self.htmlContentLoader = htmlContentLoader
        self.classifier = classifier
        self.imageExtractor = imageExtractor
        cache.countLimit = 512
        cache.totalCostLimit = 30 * 1024 * 1024
    }

    func loadPreviewSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        allowRecovery: Bool = true
    ) async -> EmailPreviewSource? {
        guard let canonicalContent = await htmlContentLoader.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery
        ),
              let canonicalHTML = canonicalContent.html else {
            return nil
        }

        let sourceSignature = canonicalContent.sourceSignature
        let cacheKey = self.cacheKey(
            messageId: messageId,
            sourceSignature: sourceSignature,
            previewMode: Self.previewMode(
                bodyText: canonicalContent.plainText,
                senderEmail: senderEmail,
                subject: subject,
                allowRecovery: allowRecovery
            )
        )

        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.source
        }

        let extractedContent = EmailPreviewContentExtractor.extract(
            canonicalHTML: canonicalHTML,
            bodyText: canonicalContent.plainText,
            imageExtractor: imageExtractor
        )
        let classification = classifier.classify(
            canonicalHTML: canonicalHTML,
            bodyText: extractedContent.plainText,
            extractedText: extractedContent.htmlText,
            senderEmail: senderEmail,
            subject: subject
        )

        let source = EmailPreviewSource(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            plainText: extractedContent.plainText,
            extractedText: extractedContent.htmlText,
            extractedImages: extractedContent.images,
            htmlSummary: extractedContent.htmlSummary,
            classification: classification,
            sourceKind: canonicalContent.sourceKind,
            hasHTMLSource: canonicalContent.hasHTMLSource
        )

        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "EmailPreviewSourceLoader message \(messageId): sourceKind=\(canonicalContent.sourceKind.rawValue) sourceLocation=\(canonicalContent.sourceLocation.rawValue)",
            category: .ui
        )

        cache.setObject(CachedSourceBox(source), forKey: cacheKey as NSString, cost: canonicalHTML.utf8.count)
        return source
    }

    private func cacheKey(
        messageId: String,
        sourceSignature: String,
        previewMode: String
    ) -> String {
        [
            messageId,
            sourceSignature,
            previewMode
        ].joined(separator: "|")
    }

    private static func previewMode(
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        allowRecovery: Bool
    ) -> String {
        [
            "source-preview-v1",
            "body:\(Self.fingerprint(for: bodyText))",
            "sender:\(Self.fingerprint(for: senderEmail))",
            "subject:\(Self.fingerprint(for: subject))",
            "recovery:\(allowRecovery)"
        ].joined(separator: "|")
    }

    private static func fingerprint(for text: String?) -> String {
        guard let text = text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return "nil"
        }

        return SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

enum EmailPreviewContentExtractor {
    static func extract(
        canonicalHTML: String,
        bodyText: String?,
        imageExtractor: EmailPreviewImageExtractor = EmailPreviewImageExtractor()
    ) -> EmailPreviewExtractedContent {
        let domQuery = EmailPreviewDOMQuery(html: canonicalHTML)
        return EmailPreviewExtractedContent(
            plainText: normalizedPlainText(from: bodyText),
            htmlText: normalizedHTMLText(from: canonicalHTML, domQuery: domQuery),
            images: imageExtractor.extractImages(from: canonicalHTML),
            htmlSummary: htmlSummary(from: canonicalHTML, domQuery: domQuery)
        )
    }

    static func normalizedPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }

        let normalized = normalizedText(RawEmailSourceSanitizer.extractDisplayText(from: text))
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedHTMLText(from html: String) -> String? {
        normalizedHTMLText(from: html, domQuery: EmailPreviewDOMQuery(html: html))
    }

    private static func normalizedHTMLText(from html: String, domQuery: EmailPreviewDOMQuery?) -> String? {
        if let domText = domQuery?.plainText() {
            return domText
        }

        let recoveredText = normalizedText(TextProcessing.extractPlainText(from: html))
        return recoveredText.isEmpty ? nil : recoveredText
    }

    static func normalizedOptionalText(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedText(_ text: String?) -> String {
        guard let text else { return "" }

        return normalizePreviewScalars(HTMLEntityDecoder.decode(text))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePreviewScalars(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if isInvisiblePreviewScalar(scalar) {
                return ""
            }

            if isPreviewSpaceScalar(scalar) {
                return " "
            }

            return String(scalar)
        }
        .joined()
    }

    private static func isInvisiblePreviewScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x180E,
             0x200B...0x200F,
             0x202A...0x202E,
             0x2060...0x206F,
             0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isPreviewSpaceScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00A0, 0x1680,
             0x2000...0x200A,
             0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func htmlSummary(from _: String, domQuery: EmailPreviewDOMQuery?) -> EmailPreviewHTMLSummary {
        domQuery?.htmlSummary() ?? EmailPreviewHTMLSummary(
            h1Text: nil,
            h2Text: nil,
            titleText: nil,
            preheaderText: nil,
            actionLinkTexts: []
        )
    }
}

enum EmailPreviewRemoteImageURL {
    static func normalizedForNativePreview(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "http",
              components.host?.isEmpty == false else {
            return rawURL
        }

        components.scheme = "https"
        return components.string ?? rawURL
    }
}

struct EmailPreviewImageExtractor {
    private let sanitizer: HTMLSanitizerService

    init(sanitizer: HTMLSanitizerService = .shared) {
        self.sanitizer = sanitizer
    }

    func extractImages(from canonicalHTML: String, maxImages: Int = 12) -> [EmailPreviewImage] {
        let sanitizedHTML = sanitizer.sanitize(canonicalHTML)
        return EmailPreviewDOMQuery(html: sanitizedHTML)?.images(maxImages: maxImages) ?? []
    }
}
