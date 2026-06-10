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

    private let htmlContentLoader: HTMLContentLoader
    private let classifier: EmailPreviewClassifier
    private let imageExtractor: EmailPreviewImageExtractor
    private let parsedEmailProvider: any ParsedEmailProviding
    private let renderedMessageCache: RenderedMessageCache

    init(
        htmlContentLoader: HTMLContentLoader = .shared,
        classifier: EmailPreviewClassifier = EmailPreviewClassifier(),
        imageExtractor: EmailPreviewImageExtractor = EmailPreviewImageExtractor(),
        parsedEmailProvider: any ParsedEmailProviding = ParsedEmailProvider.shared,
        renderedMessageCache: RenderedMessageCache = .shared
    ) {
        self.htmlContentLoader = htmlContentLoader
        self.classifier = classifier
        self.imageExtractor = imageExtractor
        self.parsedEmailProvider = parsedEmailProvider
        self.renderedMessageCache = renderedMessageCache
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
        let variantKey = RenderedMessageVariantKey(
            Self.previewMode(
                bodyText: canonicalContent.plainText,
                senderEmail: senderEmail,
                subject: subject,
                allowRecovery: allowRecovery
            )
        )

        return await renderedMessageCache.previewSource(
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        ) {
            await self.buildPreviewSource(
                messageId: messageId,
                canonicalContent: canonicalContent,
                canonicalHTML: canonicalHTML,
                senderEmail: senderEmail,
                subject: subject
            )
        }
    }

    private func buildPreviewSource(
        messageId: String,
        canonicalContent: CanonicalEmailContent,
        canonicalHTML: String,
        senderEmail: String?,
        subject: String?
    ) async -> EmailPreviewSource {
        let parsedEmail = await parsedEmailProvider.parsedEmail(
            messageId: messageId,
            sourceSignature: canonicalContent.sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: false,
            includePreviewImages: true
        )
        let extractedContent = EmailPreviewContentExtractor.extract(
            canonicalHTML: canonicalHTML,
            bodyText: canonicalContent.plainText,
            parsedEmail: parsedEmail,
            imageExtractor: imageExtractor
        )
        let classification = classifier.classify(
            parsedEmail: parsedEmail,
            canonicalHTML: canonicalHTML,
            bodyText: extractedContent.plainText,
            extractedText: extractedContent.htmlText,
            senderEmail: senderEmail,
            subject: subject
        )

        let source = EmailPreviewSource(
            messageId: messageId,
            sourceSignature: canonicalContent.sourceSignature,
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

        return source
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
        parsedEmail: ParsedEmail? = nil,
        imageExtractor: EmailPreviewImageExtractor = EmailPreviewImageExtractor()
    ) -> EmailPreviewExtractedContent {
        let usesParsedEmail = parsedEmail?.canonicalHTML == canonicalHTML
        let domQuery = usesParsedEmail ? nil : EmailPreviewDOMQuery(html: canonicalHTML)
        return EmailPreviewExtractedContent(
            plainText: normalizedPlainText(from: bodyText),
            htmlText: normalizedHTMLText(from: canonicalHTML, parsedEmail: parsedEmail, domQuery: domQuery),
            images: previewImages(from: canonicalHTML, parsedEmail: parsedEmail, imageExtractor: imageExtractor),
            htmlSummary: htmlSummary(from: canonicalHTML, parsedEmail: parsedEmail, domQuery: domQuery)
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
        normalizedHTMLText(from: html, parsedEmail: nil, domQuery: EmailPreviewDOMQuery(html: html))
    }

    private static func normalizedHTMLText(
        from html: String,
        parsedEmail: ParsedEmail?,
        domQuery: EmailPreviewDOMQuery?
    ) -> String? {
        if parsedEmail?.canonicalHTML == html {
            return parsedEmail?.previewPlainText
        }

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

    private static func htmlSummary(
        from html: String,
        parsedEmail: ParsedEmail?,
        domQuery: EmailPreviewDOMQuery?
    ) -> EmailPreviewHTMLSummary {
        if parsedEmail?.canonicalHTML == html {
            return parsedEmail?.htmlSummary ?? EmailPreviewHTMLSummary(
                h1Text: nil,
                h2Text: nil,
                titleText: nil,
                preheaderText: nil,
                actionLinkTexts: []
            )
        }

        return domQuery?.htmlSummary() ?? EmailPreviewHTMLSummary(
            h1Text: nil,
            h2Text: nil,
            titleText: nil,
            preheaderText: nil,
            actionLinkTexts: []
        )
    }

    private static func previewImages(
        from html: String,
        parsedEmail: ParsedEmail?,
        imageExtractor: EmailPreviewImageExtractor
    ) -> [EmailPreviewImage] {
        if parsedEmail?.canonicalHTML == html,
           let previewImages = parsedEmail?.previewImages {
            return previewImages
        }

        return imageExtractor.extractImages(from: html)
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

    /// Single decision point for native preview cards fetching remote images at
    /// render time. Cards auto-load, matching the full reader and snapshot
    /// WebViews, which also fetch remote content without a consent gate — but
    /// only over HTTPS with a real host, so cached models from older builder
    /// versions can never trigger cleartext or non-web loads.
    static func autoLoadableNativePreviewURL(_ rawURL: String) -> String? {
        let normalized = normalizedForNativePreview(rawURL)
        guard let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }

        return normalized
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
