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
        guard let canonicalHTML = await htmlContentLoader.loadCanonicalHTML(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery
        ) else {
            return nil
        }

        let sourceSignature = Self.sourceSignature(for: canonicalHTML)
        let cacheKey = self.cacheKey(
            messageId: messageId,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            allowRecovery: allowRecovery,
            sourceSignature: sourceSignature
        )

        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.source
        }

        let plainText = Self.normalizedPlainText(from: bodyText)
        let extractedText = Self.normalizedHTMLText(from: canonicalHTML)
        let extractedImages = imageExtractor.extractImages(from: canonicalHTML)
        let classification = classifier.classify(
            canonicalHTML: canonicalHTML,
            bodyText: plainText,
            extractedText: extractedText,
            senderEmail: senderEmail,
            subject: subject
        )

        let source = EmailPreviewSource(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            plainText: plainText,
            extractedText: extractedText,
            extractedImages: extractedImages,
            classification: classification
        )

        cache.setObject(CachedSourceBox(source), forKey: cacheKey as NSString, cost: canonicalHTML.utf8.count)
        return source
    }

    private func cacheKey(
        messageId: String,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        allowRecovery: Bool,
        sourceSignature: String
    ) -> String {
        [
            messageId,
            "body:\(Self.fingerprint(for: bodyText))",
            "sender:\(Self.fingerprint(for: senderEmail))",
            "subject:\(Self.fingerprint(for: subject))",
            "recovery:\(allowRecovery)",
            sourceSignature
        ].joined(separator: "|")
    }

    private static func sourceSignature(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
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

    private static func normalizedPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }

        let normalized = normalizedText(RawEmailSourceSanitizer.extractDisplayText(from: text))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedHTMLText(from html: String) -> String? {
        let normalized = normalizedText(TextProcessing.extractPlainText(from: html))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedText(_ text: String) -> String {
        HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EmailPreviewImageExtractor {
    private let sanitizer: HTMLSanitizerService

    init(sanitizer: HTMLSanitizerService = .shared) {
        self.sanitizer = sanitizer
    }

    func extractImages(from canonicalHTML: String, maxImages: Int = 12) -> [EmailPreviewImage] {
        let sanitizedHTML = sanitizer.sanitize(canonicalHTML)
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

        return Int(value.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))
    }

    private func normalizedText(_ text: String) -> String {
        HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
