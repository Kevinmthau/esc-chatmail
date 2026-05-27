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

        return legacyNormalizedHTMLText(from: html)
    }

    private static func legacyNormalizedHTMLText(from html: String) -> String? {
        let normalized = normalizedText(TextProcessing.extractPlainText(from: html))
        return normalized.isEmpty ? nil : normalized
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

    private static func htmlSummary(from html: String, domQuery: EmailPreviewDOMQuery?) -> EmailPreviewHTMLSummary {
        if let domQuery {
            return domQuery.htmlSummary()
        }

        return legacyHTMLSummary(from: html)
    }

    private static func legacyHTMLSummary(from html: String) -> EmailPreviewHTMLSummary {
        EmailPreviewHTMLSummary(
            h1Text: firstTagText("h1", in: html),
            h2Text: firstTagText("h2", in: html),
            titleText: firstTagText("title", in: html),
            preheaderText: firstPreheaderText(in: html),
            actionLinkTexts: actionLinkTexts(in: html)
        )
    }

    private static func firstTagText(_ tagName: String, in html: String) -> String? {
        let pattern = "<\(tagName)\\b[^>]*>([\\s\\S]*?)</\(tagName)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return legacyNormalizedHTMLText(from: String(html[range]))
    }

    private static func firstPreheaderText(in html: String) -> String? {
        let pattern = "<(?:div|span)\\b[^>]*(?:class\\s*=\\s*[\"'][^\"']*preheader[^\"']*[\"']|id\\s*=\\s*[\"'][^\"']*preheader[^\"']*[\"'])[^>]*>([\\s\\S]*?)</(?:div|span)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return legacyNormalizedHTMLText(from: String(html[range]))
    }

    private static func actionLinkTexts(in html: String, maxLinks: Int = 12, maxScannedLinks: Int = 48) -> [String] {
        let pattern = "<a\\b[^>]*>([\\s\\S]*?)</a>"
        guard maxLinks > 0, maxScannedLinks > 0 else {
            return []
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var linkTexts: [String] = []
        var scannedLinks = 0
        regex.enumerateMatches(in: html, options: [], range: NSRange(html.startIndex..., in: html)) { match, _, stop in
            scannedLinks += 1
            guard let match,
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else {
                if scannedLinks >= maxScannedLinks {
                    stop.pointee = true
                }
                return
            }

            if let text = legacyNormalizedHTMLText(from: String(html[range])) {
                linkTexts.append(text)
            }

            if linkTexts.count >= maxLinks || scannedLinks >= maxScannedLinks {
                stop.pointee = true
            }
        }

        return linkTexts
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
        if let domQuery = EmailPreviewDOMQuery(html: sanitizedHTML) {
            return domQuery.images(maxImages: maxImages)
        }

        return legacyExtractImages(from: sanitizedHTML, maxImages: maxImages)
    }

    private func legacyExtractImages(from sanitizedHTML: String, maxImages: Int) -> [EmailPreviewImage] {
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }

        let matches = regex.matches(
            in: sanitizedHTML,
            options: [],
            range: NSRange(sanitizedHTML.startIndex..., in: sanitizedHTML)
        )
        let candidateMatches = Array(matches.prefix(maxImages))

        return candidateMatches.enumerated().compactMap { index, match in
            guard let range = Range(match.range, in: sanitizedHTML) else {
                return nil
            }

            let tag = String(sanitizedHTML[range])
            guard let sourceURL = attributeValue(named: "src", in: tag) else {
                return nil
            }

            let descriptor = [
                attributeValue(named: "alt", in: tag),
                attributeValue(named: "class", in: tag)
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            return EmailPreviewImage(
                sourceURL: sourceURL,
                width: numericAttribute(named: "width", in: tag),
                height: numericAttribute(named: "height", in: tag),
                descriptor: descriptor,
                followingText: followingTextAfterImage(
                    at: index,
                    in: sanitizedHTML,
                    matches: candidateMatches
                ),
                index: index
            )
        }
    }

    private func followingTextAfterImage(
        at index: Int,
        in html: String,
        matches: [NSTextCheckingResult]
    ) -> String {
        guard index < matches.count,
              let currentRange = Range(matches[index].range, in: html) else {
            return ""
        }

        let segmentStart = currentRange.upperBound
        let nextImageStart = nextImageStartIndex(after: index, in: html, matches: matches)
        let maximumEnd = html.index(segmentStart, offsetBy: 2_500, limitedBy: nextImageStart) ?? nextImageStart
        guard segmentStart < maximumEnd else {
            return ""
        }

        let segment = String(html[segmentStart..<maximumEnd])
        return normalizedText(TextProcessing.extractPlainText(from: segment))
    }

    private func nextImageStartIndex(
        after index: Int,
        in html: String,
        matches: [NSTextCheckingResult]
    ) -> String.Index {
        let nextIndex = index + 1
        guard nextIndex < matches.count,
              let nextRange = Range(matches[nextIndex].range, in: html) else {
            return html.endIndex
        }

        return nextRange.lowerBound
    }

    private func attributeValue(named attribute: String, in tag: String) -> String? {
        let pattern = "\(attribute)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: tag) else {
                continue
            }

            let value = normalizedText(String(tag[range]))
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func numericAttribute(named attribute: String, in tag: String) -> Int? {
        guard let value = attributeValue(named: attribute, in: tag) else {
            return nil
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)"#,
            options: []
        ),
              let match = regex.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return nil
        }

        return roundedPositiveInteger(from: String(value[range]))
    }

    private func roundedPositiveInteger(from numericValue: String) -> Int? {
        var value = numericValue
        if value.hasPrefix("-") {
            return nil
        }

        if value.hasPrefix("+") {
            value.removeFirst()
        }

        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? ""
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        let integerDigits = integerPart.drop { $0 == "0" }
        let normalizedInteger = integerDigits.isEmpty ? "0" : String(integerDigits)
        let maxInteger = String(Int.max)

        guard normalizedInteger.count < maxInteger.count
                || (normalizedInteger.count == maxInteger.count && normalizedInteger <= maxInteger),
              var rounded = Int(normalizedInteger) else {
            return nil
        }

        if let firstFractionDigit = fractionPart.first,
           (firstFractionDigit.wholeNumberValue ?? 0) >= 5 {
            guard rounded < Int.max else {
                return nil
            }
            rounded += 1
        }

        guard rounded > 0 else {
            return nil
        }
        return rounded
    }

    private func normalizedText(_ text: String) -> String {
        HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
