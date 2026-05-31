import Foundation

struct ParsedEmailKey: Hashable, Sendable {
    let messageId: String
    let sourceSignature: String
}

struct ParsedEmailRenderQualityFacts: Equatable, Sendable {
    let renderableHTML: String
    let metrics: EmailDocumentRenderQualityMetrics
    let visibleText: String
    let hiddenPrimaryContentCount: Int
}

enum EmailRenderQualityHints {
    static let footerLineHints = [
        "unsubscribe",
        "manage preferences",
        "privacy policy",
        "view in browser",
        "view online",
        "do not reply",
        "do-not-reply",
        "all rights reserved",
        "mailing address",
        "terms of use",
        "security center"
    ]

    static let primaryContentHints = [
        "action",
        "button",
        "cta",
        "primary"
    ]
}

/// Immutable facts derived from one canonical parsed HTML email.
///
/// The underlying `EmailDocument` is intentionally kept private: SwiftSoup's
/// document type is mutable, so consumers share precomputed value facts instead
/// of passing a live DOM across concurrency boundaries.
final class ParsedEmail: @unchecked Sendable {
    let key: ParsedEmailKey
    let canonicalHTML: String
    let plainText: String
    let previewPlainText: String?
    let referencedInlineContentIDs: Set<String>
    let htmlMetrics: EmailDocumentHTMLMetrics
    let renderQuality: ParsedEmailRenderQualityFacts
    let htmlSummary: EmailPreviewHTMLSummary

    private let document: EmailDocument

    init(
        key: ParsedEmailKey,
        canonicalHTML: String,
        document: EmailDocument
    ) {
        self.key = key
        self.canonicalHTML = canonicalHTML
        self.document = document
        self.plainText = document.plainText(preserveParagraphs: true)
        self.previewPlainText = document.previewPlainText()
        self.referencedInlineContentIDs = document.referencedInlineContentIDs()
        self.htmlMetrics = EmailDocumentHTMLMetrics(classificationHTML: canonicalHTML)
        self.htmlSummary = document.previewHTMLSummary()

        let renderableHTML = HTMLMeaningfulContentChecker.renderableHTML(from: canonicalHTML)
        let renderableMetrics = document.renderableQualityMetrics(
            footerLineHints: EmailRenderQualityHints.footerLineHints,
            primaryContentHints: EmailRenderQualityHints.primaryContentHints
        )
        self.renderQuality = ParsedEmailRenderQualityFacts(
            renderableHTML: renderableHTML,
            metrics: renderableMetrics,
            visibleText: document.renderablePlainText(preserveParagraphs: true),
            hiddenPrimaryContentCount: document.hiddenPrimaryContentCount(
                primaryContentHints: EmailRenderQualityHints.primaryContentHints
            )
        )
    }

    static func parse(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        parser: (String) throws -> EmailDocument? = { try EmailDocument.parse($0) }
    ) throws -> ParsedEmail? {
        guard let document = try parser(canonicalHTML) else {
            return nil
        }
        return ParsedEmail(
            key: ParsedEmailKey(messageId: messageId, sourceSignature: sourceSignature),
            canonicalHTML: canonicalHTML,
            document: document
        )
    }
}

protocol ParsedEmailProviding: Sendable {
    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String
    ) async -> ParsedEmail?

    func invalidate(messageId: String) async
}

actor ParsedEmailProvider: ParsedEmailProviding {
    static let shared = ParsedEmailProvider()

    private let parser: (String) throws -> EmailDocument?
    private let countLimit: Int
    private var cache: [ParsedEmailKey: ParsedEmail] = [:]
    private var cacheOrder: [ParsedEmailKey] = []
    private var parseAttemptCount = 0
    private var parseFailureCount = 0

    init(
        countLimit: Int = 256,
        parser: @escaping (String) throws -> EmailDocument? = { try EmailDocument.parse($0) }
    ) {
        self.countLimit = countLimit
        self.parser = parser
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String
    ) async -> ParsedEmail? {
        let key = ParsedEmailKey(messageId: messageId, sourceSignature: sourceSignature)
        if let cached = cache[key] {
            logCacheEvent("cache-hit", key: key)
            return cached
        }

        pruneStaleEntries(for: messageId, keeping: key)

        let start = Date()
        parseAttemptCount += 1
        do {
            guard let parsed = try ParsedEmail.parse(
                messageId: messageId,
                sourceSignature: sourceSignature,
                canonicalHTML: canonicalHTML,
                parser: parser
            ) else {
                parseFailureCount += 1
                logFailure(key: key, duration: Date().timeIntervalSince(start))
                return nil
            }

            cache[key] = parsed
            cacheOrder.append(key)
            enforceCountLimit()
            logCacheEvent("cache-miss", key: key, duration: Date().timeIntervalSince(start))
            return parsed
        } catch {
            parseFailureCount += 1
            logFailure(key: key, duration: Date().timeIntervalSince(start))
            return nil
        }
    }

    func invalidate(messageId: String) async {
        cache = cache.filter { $0.key.messageId != messageId }
        cacheOrder.removeAll { $0.messageId == messageId }
    }

#if DEBUG
    func debugParseAttemptCount() -> Int {
        parseAttemptCount
    }

    func debugParseFailureCount() -> Int {
        parseFailureCount
    }

    func debugCachedCount() -> Int {
        cache.count
    }
#endif

    private func pruneStaleEntries(for messageId: String, keeping key: ParsedEmailKey) {
        let staleKeys = cache.keys.filter { $0.messageId == messageId && $0 != key }
        guard !staleKeys.isEmpty else { return }

        for staleKey in staleKeys {
            cache.removeValue(forKey: staleKey)
        }
        cacheOrder.removeAll { staleKeys.contains($0) }
    }

    private func enforceCountLimit() {
        guard countLimit > 0 else {
            cache.removeAll()
            cacheOrder.removeAll()
            return
        }

        while cache.count > countLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func logCacheEvent(
        _ event: String,
        key: ParsedEmailKey,
        duration: TimeInterval? = nil
    ) {
        var components = [
            "ParsedEmailProvider",
            "event=\(event)",
            "message=\(key.messageId)",
            "sourceSignature=\(key.sourceSignature)"
        ]
        if let duration {
            components.append("duration=\(String(format: "%.3f", duration))s")
        }

        Log.diagnostic(.htmlPreview, level: .debug, components.joined(separator: " "), category: .ui)
    }

    private func logFailure(key: ParsedEmailKey, duration: TimeInterval) {
        Log.diagnostic(
            .htmlPreview,
            level: .debug,
            "ParsedEmailProvider event=parse-failure message=\(key.messageId) sourceSignature=\(key.sourceSignature) duration=\(String(format: "%.3f", duration))s failures=\(parseFailureCount)",
            category: .ui
        )
    }
}
