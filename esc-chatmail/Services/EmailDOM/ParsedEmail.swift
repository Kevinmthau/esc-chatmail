import Foundation

struct ParsedEmailKey: Hashable, Sendable {
    let messageId: String
    let sourceSignature: String
}

struct ParsedEmailAccountGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
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

/// Immutable value facts derived from one canonical parsed HTML email.
///
/// `EmailDocument` is parsed only while constructing this value. The mutable
/// DOM is not retained, so parsed facts can safely cross concurrency boundaries.
struct ParsedEmail: Equatable, Sendable {
    let key: ParsedEmailKey
    let canonicalHTML: String
    let plainText: String
    let previewPlainText: String?
    let referencedInlineContentIDs: Set<String>
    let htmlMetrics: EmailDocumentHTMLMetrics
    let renderQuality: ParsedEmailRenderQualityFacts?
    let htmlSummary: EmailPreviewHTMLSummary
    let previewImages: [EmailPreviewImage]?

    private init(
        key: ParsedEmailKey,
        canonicalHTML: String,
        plainText: String,
        previewPlainText: String?,
        referencedInlineContentIDs: Set<String>,
        htmlMetrics: EmailDocumentHTMLMetrics,
        renderQuality: ParsedEmailRenderQualityFacts?,
        htmlSummary: EmailPreviewHTMLSummary,
        previewImages: [EmailPreviewImage]?
    ) {
        self.key = key
        self.canonicalHTML = canonicalHTML
        self.plainText = plainText
        self.previewPlainText = previewPlainText
        self.referencedInlineContentIDs = referencedInlineContentIDs
        self.htmlMetrics = htmlMetrics
        self.renderQuality = renderQuality
        self.htmlSummary = htmlSummary
        self.previewImages = previewImages
    }

    private static func makeRenderQualityFacts(
        canonicalHTML: String,
        document: EmailDocument
    ) -> ParsedEmailRenderQualityFacts {
        let renderableHTML = HTMLMeaningfulContentChecker.renderableHTML(from: canonicalHTML)
        let renderableMetrics = document.renderableQualityMetrics(
            footerLineHints: EmailRenderQualityHints.footerLineHints,
            primaryContentHints: EmailRenderQualityHints.primaryContentHints
        )
        return ParsedEmailRenderQualityFacts(
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
        includeRenderQuality: Bool = false,
        includePreviewImages: Bool = false,
        parser: (String) throws -> EmailDocument? = { try EmailDocument.parse($0) }
    ) throws -> ParsedEmail? {
        guard let document = try parser(canonicalHTML) else {
            return nil
        }
        return ParsedEmail(
            key: ParsedEmailKey(messageId: messageId, sourceSignature: sourceSignature),
            canonicalHTML: canonicalHTML,
            plainText: document.plainText(preserveParagraphs: true),
            previewPlainText: document.previewPlainText(),
            referencedInlineContentIDs: document.referencedInlineContentIDs(),
            htmlMetrics: EmailDocumentHTMLMetrics(classificationHTML: canonicalHTML),
            renderQuality: includeRenderQuality
                ? Self.makeRenderQualityFacts(canonicalHTML: canonicalHTML, document: document)
                : nil,
            htmlSummary: document.previewHTMLSummary(),
            previewImages: includePreviewImages
                ? EmailPreviewImageExtractor().extractImages(from: canonicalHTML)
                : nil
        )
    }
}

protocol ParsedEmailProviding: Sendable {
    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool,
        includePreviewImages: Bool
    ) async -> ParsedEmail?

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool,
        includePreviewImages: Bool,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async -> ParsedEmail?

    func captureAccountGeneration() async -> ParsedEmailAccountGeneration?
    func isAccountGenerationCurrent(_ generation: ParsedEmailAccountGeneration) async -> Bool

    func invalidate(messageId: String) async
    func invalidate(
        messageId: String,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async
}

extension ParsedEmailProviding {
    func captureAccountGeneration() async -> ParsedEmailAccountGeneration? {
        nil
    }

    func isAccountGenerationCurrent(_ generation: ParsedEmailAccountGeneration) async -> Bool {
        false
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool,
        includePreviewImages: Bool,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async -> ParsedEmail? {
        guard expectedAccountGeneration == nil else { return nil }
        return await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: includeRenderQuality,
            includePreviewImages: includePreviewImages
        )
    }

    func invalidate(
        messageId: String,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async {
        guard expectedAccountGeneration == nil else { return }
        await invalidate(messageId: messageId)
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String
    ) async -> ParsedEmail? {
        await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: false,
            includePreviewImages: false
        )
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async -> ParsedEmail? {
        await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: false,
            includePreviewImages: false,
            expectedAccountGeneration: expectedAccountGeneration
        )
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool
    ) async -> ParsedEmail? {
        await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: includeRenderQuality,
            includePreviewImages: false
        )
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async -> ParsedEmail? {
        await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: includeRenderQuality,
            includePreviewImages: false,
            expectedAccountGeneration: expectedAccountGeneration
        )
    }
}

actor ParsedEmailProvider: ParsedEmailProviding {
    static let shared = ParsedEmailProvider()

    private let parser: (String) throws -> EmailDocument?
    private let countLimit: Int
    private var cache: [ParsedEmailKey: ParsedEmail] = [:]
    private var cacheOrder: [ParsedEmailKey] = []
    private var parseAttemptCount = 0
    private var parseFailureCount = 0
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0

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
        canonicalHTML: String,
        includeRenderQuality: Bool = false,
        includePreviewImages: Bool = false
    ) async -> ParsedEmail? {
        await parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: canonicalHTML,
            includeRenderQuality: includeRenderQuality,
            includePreviewImages: includePreviewImages,
            expectedAccountGeneration: nil
        )
    }

    func parsedEmail(
        messageId: String,
        sourceSignature: String,
        canonicalHTML: String,
        includeRenderQuality: Bool = false,
        includePreviewImages: Bool = false,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async -> ParsedEmail? {
        guard accepts(expectedAccountGeneration) else { return nil }
        let key = ParsedEmailKey(messageId: messageId, sourceSignature: sourceSignature)
        let cached = cache[key]
        let cachedHasRequestedFacts = (!includeRenderQuality || cached?.renderQuality != nil)
            && (!includePreviewImages || cached?.previewImages != nil)
        if let cached, cachedHasRequestedFacts {
            logCacheEvent("cache-hit", key: key)
            return cached
        }

        if cached == nil {
            pruneStaleEntries(for: messageId, keeping: key)
        }

        let start = Date()
        parseAttemptCount += 1
        do {
            guard let parsed = try ParsedEmail.parse(
                messageId: messageId,
                sourceSignature: sourceSignature,
                canonicalHTML: canonicalHTML,
                includeRenderQuality: includeRenderQuality || cached?.renderQuality != nil,
                includePreviewImages: includePreviewImages || cached?.previewImages != nil,
                parser: parser
            ) else {
                parseFailureCount += 1
                logFailure(key: key, duration: Date().timeIntervalSince(start))
                return nil
            }

            cache[key] = parsed
            if cached == nil {
                cacheOrder.append(key)
            }
            enforceCountLimit()
            logCacheEvent(
                cached == nil ? "cache-miss" : "cache-upgrade",
                key: key,
                duration: Date().timeIntervalSince(start)
            )
            return parsed
        } catch {
            parseFailureCount += 1
            logFailure(key: key, duration: Date().timeIntervalSince(start))
            return nil
        }
    }

    func invalidate(messageId: String) async {
        await invalidate(messageId: messageId, expectedAccountGeneration: nil)
    }

    func invalidate(
        messageId: String,
        expectedAccountGeneration: ParsedEmailAccountGeneration?
    ) async {
        guard accepts(expectedAccountGeneration) else { return }
        cache = cache.filter { $0.key.messageId != messageId }
        cacheOrder.removeAll { $0.messageId == messageId }
    }

    func clearAll() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func closeAccountWorkAndClear() {
        acceptsAccountWork = false
        accountGeneration &+= 1
        clearAll()
    }

    func reopenAccountWork() {
        accountGeneration &+= 1
        acceptsAccountWork = true
    }

    func captureAccountGeneration() async -> ParsedEmailAccountGeneration? {
        guard acceptsAccountWork else { return nil }
        return ParsedEmailAccountGeneration(value: accountGeneration)
    }

    func isAccountGenerationCurrent(_ generation: ParsedEmailAccountGeneration) async -> Bool {
        accepts(generation)
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

    func debugCachedSourceSignatures(messageId: String) -> Set<String> {
        Set(cache.keys.filter { $0.messageId == messageId }.map(\.sourceSignature))
    }
#endif

    private func accepts(_ expectedGeneration: ParsedEmailAccountGeneration?) -> Bool {
        guard acceptsAccountWork else { return false }
        return expectedGeneration.map { $0.value == accountGeneration } ?? true
    }

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
