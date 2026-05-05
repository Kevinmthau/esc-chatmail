import CryptoKit
import Foundation

enum HTMLContentCleanupMode: String, CaseIterable, Sendable {
    case none
    case quotedOnly
    case quotedAndSignature
}

enum HTMLLoadPresentation: String, Sendable, Equatable {
    case html
    case nativePlainText
}

/// Result of HTML content loading
struct HTMLLoadResult {
    let html: String?
    let source: HTMLLoadSource
    let presentation: HTMLLoadPresentation
    let nativeText: String?

    enum HTMLLoadSource: Hashable {
        case messageId
        case storageURI
        case rawSourceHTML
        case recovered
        case qualityFallback
        case plainTextFallback
        case notFound
    }

    init(
        html: String?,
        source: HTMLLoadSource,
        presentation: HTMLLoadPresentation = .html,
        nativeText: String? = nil
    ) {
        self.html = html
        self.source = source
        self.presentation = presentation
        self.nativeText = nativeText
    }
}

private final class CachedHTMLLoadResultBox {
    let cacheKey: String
    let variantKey: String
    let messageId: String
    let result: HTMLLoadResult

    init(_ result: HTMLLoadResult, cacheKey: String, variantKey: String, messageId: String) {
        self.cacheKey = cacheKey
        self.variantKey = variantKey
        self.messageId = messageId
        self.result = result
    }
}

private final class HTMLContentCacheDelegate: NSObject, NSCacheDelegate {
    weak var owner: HTMLContentLoader?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let box = obj as? CachedHTMLLoadResultBox else { return }
        owner?.removeTrackedCacheKey(box.cacheKey, variantKey: box.variantKey, for: box.messageId)
    }
}

private struct WrappedHTMLResult {
    let html: String
    let shouldCache: Bool
}

private enum PreparedLoadResult {
    case html(WrappedHTMLResult)
    case nativePlainText(String)
}

/// Service for loading HTML content from various sources
final class HTMLContentLoader {
    static let shared = HTMLContentLoader()

    private let contentHandler: HTMLContentHandler
    private let sanitizer: HTMLSanitizerService
    private let remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback
    private let qualityEvaluator: EmailRenderQualityEvaluator
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    private static let previewPaddingRegex: NSRegularExpression? = {
        // Some providers insert long runs of zero-width/nbsp padding to control inbox preview text.
        // Collapse these runs so fallback plain-text rendering does not appear as a blank page.
        try? NSRegularExpression(
            pattern: "[\\u200B\\u200C\\u200D\\uFEFF\\u00A0\\s]{40,}",
            options: []
        )
    }()

    /// In-memory cache for wrapped HTML content to avoid repeated disk I/O.
    /// Keys include the display variant plus automatic original-view evaluator inputs when needed.
    private let htmlCache = NSCache<NSString, CachedHTMLLoadResultBox>()
    private let htmlCacheDelegate: HTMLContentCacheDelegate
    private let htmlCacheKeyLock = NSLock()
    private var htmlCacheKeysByMessageID: [String: Set<String>] = [:]
    private var htmlCacheKeyByVariantKey: [String: String] = [:]

    init(
        contentHandler: HTMLContentHandler = HTMLContentHandler(),
        sanitizer: HTMLSanitizerService = .shared,
        remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback = .shared,
        qualityEvaluator: EmailRenderQualityEvaluator = EmailRenderQualityEvaluator()
    ) {
        self.contentHandler = contentHandler
        self.sanitizer = sanitizer
        self.remoteImageAttachmentFallback = remoteImageAttachmentFallback
        self.qualityEvaluator = qualityEvaluator
        self.htmlCacheDelegate = HTMLContentCacheDelegate()
        // Limit cache to ~50MB with both count and cost limits for proper memory pressure response
        htmlCache.countLimit = 1000
        htmlCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        htmlCache.delegate = htmlCacheDelegate
        htmlCacheDelegate.owner = self
    }

    /// Loads HTML content for a message, trying multiple sources
    /// - Parameters:
    ///   - messageId: The message ID to load content for
    ///   - bodyStorageURI: Optional stored URI path
    ///   - bodyText: Optional plain text fallback
    ///   - isDarkMode: Whether to apply dark mode styling
    ///   - cleanupMode: How aggressively to remove quoted/signature content before wrapping
    /// - Returns: HTMLLoadResult with wrapped HTML and source indicator
    func loadContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none,
        displayPurpose: HTMLDisplayPurpose = .preview,
        originalHTMLPreference: OriginalEmailHTMLPreference = .automatic
    ) async -> HTMLLoadResult {
        let normalizedFallbackText = normalizedMeaningfulPlainText(from: bodyText)
        let variantKey = cacheVariantKey(
            messageId: messageId,
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode,
            displayPurpose: displayPurpose,
            originalHTMLPreference: originalHTMLPreference
        )

        var rejectedHTMLSources = Set<HTMLLoadResult.HTMLLoadSource>()

        // Method 1: Try loading from message ID.
        // Treat empty HTML as unusable so we can fall back to storage URI / recovery / plain text.
        if contentHandler.htmlFileExists(for: messageId) {
            if let html = canonicalHTMLSource(from: contentHandler.loadHTML(for: messageId)),
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let result = await cachedOrPreparedHTMLResult(
                    html,
                    source: .messageId,
                    messageId: messageId,
                    plainText: normalizedFallbackText,
                    senderEmail: senderEmail,
                    subject: subject,
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode,
                    displayPurpose: displayPurpose,
                    originalHTMLPreference: originalHTMLPreference,
                    variantKey: variantKey
                ) {
                    return result
                }
                Log.debug("loadContent: Method 1 (messageId file) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
            }
            rejectedHTMLSources.insert(.messageId)
        }

        // Method 2: Try loading from stored URI
        if let urlString = bodyStorageURI,
           let url = StorageURIResolver.resolve(urlString),
           FileManager.default.fileExists(atPath: url.path) {
            if let html = canonicalHTMLSource(from: contentHandler.loadHTML(from: url)),
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !rejectedHTMLSources.isEmpty {
                    invalidateCachedResults(messageId: messageId, sources: rejectedHTMLSources)
                    rejectedHTMLSources.removeAll()
                }
                if let result = await cachedOrPreparedHTMLResult(
                    html,
                    source: .storageURI,
                    messageId: messageId,
                    plainText: normalizedFallbackText,
                    senderEmail: senderEmail,
                    subject: subject,
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode,
                    displayPurpose: displayPurpose,
                    originalHTMLPreference: originalHTMLPreference,
                    variantKey: variantKey
                ) {
                    return result
                }
                Log.debug("loadContent: Method 2 (storageURI) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
            }
            rejectedHTMLSources.insert(.storageURI)
        }

        // Method 3: Extract embedded HTML from raw RFC822 source stored in bodyText
        if let text = bodyText,
           let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: text) {
            if let html = canonicalHTMLSource(from: rawSourceHTML) {
                if !rejectedHTMLSources.isEmpty {
                    invalidateCachedResults(messageId: messageId, sources: rejectedHTMLSources)
                    rejectedHTMLSources.removeAll()
                }
                if let result = await cachedOrPreparedHTMLResult(
                    html,
                    source: .rawSourceHTML,
                    messageId: messageId,
                    plainText: normalizedFallbackText,
                    senderEmail: senderEmail,
                    subject: subject,
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode,
                    displayPurpose: displayPurpose,
                    originalHTMLPreference: originalHTMLPreference,
                    variantKey: variantKey
                ) {
                    return result
                }
                Log.debug("loadContent: Method 3 (rawSourceHTML) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
            }
            rejectedHTMLSources.insert(.rawSourceHTML)
        }

        if !rejectedHTMLSources.isEmpty {
            invalidate(messageId: messageId)
        } else if let cachedResult = cachedHTMLResultForUnavailableSource(variantKey: variantKey) {
            return cachedResult
        }

        // Method 4: Recovery - fetch from Gmail API if local content missing
        if let recoveredHTML = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId),
           let html = canonicalHTMLSource(from: recoveredHTML),
           let result = await cachedOrPreparedHTMLResult(
               html,
               source: .recovered,
               messageId: messageId,
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject,
               isDarkMode: isDarkMode,
               cleanupMode: cleanupMode,
               displayPurpose: displayPurpose,
               originalHTMLPreference: originalHTMLPreference,
               variantKey: variantKey
           ) {
            return result
        }

        Log.debug("loadContent: All HTML methods failed for \(messageId), falling back to plain text (bodyText=\(bodyText?.count ?? 0) chars)", category: .ui)

        // Method 5: Plain text fallback (don't cache as it's trivial to generate)
        if let normalizedText = normalizedFallbackText {
            if displayPurpose == .original {
                return HTMLLoadResult(
                    html: nil,
                    source: .plainTextFallback,
                    presentation: .nativePlainText,
                    nativeText: normalizedText
                )
            }

            let html = convertPlainTextToHTML(normalizedText)
            let wrapped = sanitizer.wrapHTMLForDisplay(
                html,
                isDarkMode: isDarkMode,
                displayPurpose: displayPurpose
            )
            if HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) {
                return HTMLLoadResult(html: wrapped, source: .plainTextFallback)
            }
        }

        return HTMLLoadResult(html: nil, source: .notFound)
    }

    /// Loads content with timeout support
    func loadContentWithTimeout(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none,
        displayPurpose: HTMLDisplayPurpose = .preview,
        originalHTMLPreference: OriginalEmailHTMLPreference = .automatic,
        timeout: TimeInterval = 5.0
    ) async -> HTMLLoadResult {
        return await withTaskGroup(of: HTMLLoadResult?.self) { group in
            // Content loading task
            group.addTask {
                await self.loadContent(
                    messageId: messageId,
                    bodyStorageURI: bodyStorageURI,
                    bodyText: bodyText,
                    senderEmail: senderEmail,
                    subject: subject,
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode,
                    displayPurpose: displayPurpose,
                    originalHTMLPreference: originalHTMLPreference
                )
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil // Timeout indicator
            }

            // Return first completed result
            for await result in group {
                group.cancelAll()
                return result ?? HTMLLoadResult(html: nil, source: .notFound)
            }

            return HTMLLoadResult(html: nil, source: .notFound)
        }
    }

    /// Loads canonical HTML content without preview/full-message wrapping.
    /// Chat newsletter previews use this to derive native cards from the original message content
    /// instead of scaling the full email DOM inside the thread list.
    func loadCanonicalHTML(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        allowRecovery: Bool = true
    ) async -> String? {
        if contentHandler.htmlFileExists(for: messageId),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(for: messageId)) {
            return html
        }

        if let urlString = bodyStorageURI,
           let url = StorageURIResolver.resolve(urlString),
           FileManager.default.fileExists(atPath: url.path),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(from: url)) {
            return html
        }

        if let text = bodyText,
           let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: text),
           let html = canonicalHTMLSource(from: rawSourceHTML) {
            return html
        }

        guard allowRecovery else {
            return nil
        }

        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId) {
            return canonicalHTMLSource(from: html)
        }

        return nil
    }

    /// Wraps already-loaded canonical HTML for chat preview rendering without reloading the
    /// original source from disk or recovery services again.
    func preparePreviewHTML(
        fromCanonicalHTML canonicalHTML: String,
        messageId: String,
        bodyText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none
    ) async -> String? {
        guard let normalizedCanonicalHTML = canonicalHTMLSource(from: canonicalHTML) else {
            return nil
        }

        let normalizedFallbackText = normalizedMeaningfulPlainText(from: bodyText)
        guard let prepared = await wrappedHTMLIfMeaningful(
            normalizedCanonicalHTML,
            messageId: messageId,
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode,
            displayPurpose: .preview,
            originalHTMLPreference: .automatic
        ) else {
            return nil
        }

        switch prepared {
        case .html(let wrapped):
            return wrapped.html
        case .nativePlainText:
            return nil
        }
    }

    /// Returns canonical stored HTML only when the original-reader heuristics would keep HTML.
    /// Reply quoting uses this to preserve document styling without bypassing the meaningful-content
    /// and quality-fallback checks that protect the full-message path.
    func loadReplyQuotedOriginalHTML(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil
    ) -> String? {
        let normalizedFallbackText = normalizedMeaningfulPlainText(from: bodyText)

        if let replyHTML = approvedReplyQuotedHTML(
            from: contentHandler.loadHTML(for: messageId),
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject
        ) {
            return replyHTML
        }

        if let bodyStorageURI,
           contentHandler.migrateIfNeeded(from: bodyStorageURI),
           let replyHTML = approvedReplyQuotedHTML(
               from: contentHandler.loadHTML(for: messageId),
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject
           ) {
            return replyHTML
        }

        if let bodyStorageURI,
           let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
           FileManager.default.fileExists(atPath: resolvedURL.path),
           let replyHTML = approvedReplyQuotedHTML(
               from: contentHandler.loadHTML(from: resolvedURL),
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject
           ) {
            return replyHTML
        }

        if let bodyText,
           let replyHTML = approvedReplyQuotedHTML(
               from: RawEmailSourceSanitizer.extractHTMLText(from: bodyText),
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject
           ) {
            return replyHTML
        }

        return nil
    }

    /// Invalidates cached HTML content for a message (both light/dark variants).
    func invalidate(messageId: String) {
        invalidateCachedResults(messageId: messageId) { _ in true }
    }

    private func invalidateCachedResults(
        messageId: String,
        sources: Set<HTMLLoadResult.HTMLLoadSource>
    ) {
        invalidateCachedResults(messageId: messageId) { sources.contains($0) }
    }

    private func invalidateCachedResults(
        messageId: String,
        matching shouldInvalidate: (HTMLLoadResult.HTMLLoadSource) -> Bool
    ) {
        let keys: [String]
        htmlCacheKeyLock.lock()
        let trackedKeys = htmlCacheKeysByMessageID[messageId] ?? []
        keys = trackedKeys.filter { key in
            guard let box = htmlCache.object(forKey: key as NSString) else {
                return true
            }
            return shouldInvalidate(box.result.source)
        }
        if !keys.isEmpty {
            let keySet = Set(keys)
            let remainingKeys = trackedKeys.subtracting(keySet)
            if remainingKeys.isEmpty {
                htmlCacheKeysByMessageID.removeValue(forKey: messageId)
            } else {
                htmlCacheKeysByMessageID[messageId] = remainingKeys
            }
            htmlCacheKeyByVariantKey = htmlCacheKeyByVariantKey.filter { !keySet.contains($0.value) }
        }
        htmlCacheKeyLock.unlock()

        for key in keys {
            htmlCache.removeObject(forKey: key as NSString)
        }
    }

#if DEBUG
    func debugCachedVariantCount(for messageId: String) -> Int {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }
        return syncTrackedCacheKeysWithLiveCache(for: messageId)
    }

    func debugTotalCachedVariantCount() -> Int {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }
        let messageIDs = Array(htmlCacheKeysByMessageID.keys)
        return messageIDs.reduce(0) { $0 + syncTrackedCacheKeysWithLiveCache(for: $1) }
    }
#endif

    private func cacheVariantKey(
        messageId: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose,
        originalHTMLPreference: OriginalEmailHTMLPreference
    ) -> NSString {
        let evaluatorInputsKey: String
        if displayPurpose == .original, originalHTMLPreference == .automatic {
            evaluatorInputsKey = [
                cacheFingerprint(for: plainText),
                cacheFingerprint(for: subject),
                cacheFingerprint(for: senderEmail)
            ].joined(separator: "_")
        } else {
            evaluatorInputsKey = "static"
        }

        return "\(messageId)_\(isDarkMode)_\(cleanupMode.rawValue)_\(displayPurpose.rawValue)_\(originalHTMLPreference.rawValue)_\(evaluatorInputsKey)" as NSString
    }

    private func cacheKey(
        variantKey: NSString,
        source: HTMLLoadResult.HTMLLoadSource,
        sourceSignature: String
    ) -> NSString {
        "\(variantKey)_\(cacheComponent(for: source))_\(sourceSignature)" as NSString
    }

    private func cacheFingerprint(for text: String?) -> String {
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

    private func sourceSignature(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    private func cacheComponent(for source: HTMLLoadResult.HTMLLoadSource) -> String {
        switch source {
        case .messageId:
            return "messageId"
        case .storageURI:
            return "storageURI"
        case .rawSourceHTML:
            return "rawSourceHTML"
        case .recovered:
            return "recovered"
        case .qualityFallback:
            return "qualityFallback"
        case .plainTextFallback:
            return "plainTextFallback"
        case .notFound:
            return "notFound"
        }
    }

    private func cachedOrPreparedHTMLResult(
        _ html: String,
        source: HTMLLoadResult.HTMLLoadSource,
        messageId: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose,
        originalHTMLPreference: OriginalEmailHTMLPreference,
        variantKey: NSString
    ) async -> HTMLLoadResult? {
        let cacheKey = cacheKey(
            variantKey: variantKey,
            source: source,
            sourceSignature: sourceSignature(for: html)
        )

        if let cachedResult = htmlCache.object(forKey: cacheKey) {
            return cachedResult.result
        }

        guard let prepared = await wrappedHTMLIfMeaningful(
            html,
            messageId: messageId,
            plainText: plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode,
            displayPurpose: displayPurpose,
            originalHTMLPreference: originalHTMLPreference
        ) else {
            return nil
        }

        switch prepared {
        case .html(let wrapped):
            return cachedHTMLResult(
                html: wrapped.html,
                source: source,
                shouldCache: wrapped.shouldCache,
                cacheKey: cacheKey,
                variantKey: variantKey,
                messageId: messageId
            )
        case .nativePlainText(let text):
            return qualityFallbackResult(text)
        }
    }

    private func cachedHTMLResultForUnavailableSource(variantKey: NSString) -> HTMLLoadResult? {
        let trackedCacheKey: String?

        htmlCacheKeyLock.lock()
        trackedCacheKey = htmlCacheKeyByVariantKey[variantKey as String]
        htmlCacheKeyLock.unlock()

        guard let trackedCacheKey else {
            return nil
        }

        if let cachedResult = htmlCache.object(forKey: trackedCacheKey as NSString) {
            return cachedResult.result
        }

        removeTrackedVariantKey(variantKey as String, ifMappedTo: trackedCacheKey)
        return nil
    }

    private func cachedHTMLResult(
        html: String,
        source: HTMLLoadResult.HTMLLoadSource,
        shouldCache: Bool,
        cacheKey: NSString,
        variantKey: NSString,
        messageId: String
    ) -> HTMLLoadResult {
        let result = HTMLLoadResult(html: html, source: source)

        guard shouldCache else {
            return result
        }

        let cost = html.utf8.count
        let trackedCacheKey = cacheKey as String
        let trackedVariantKey = variantKey as String
        let staleCacheKey = trackCacheKey(trackedCacheKey, variantKey: trackedVariantKey, for: messageId)
        if let staleCacheKey {
            htmlCache.removeObject(forKey: staleCacheKey as NSString)
        }
        htmlCache.setObject(
            CachedHTMLLoadResultBox(
                result,
                cacheKey: trackedCacheKey,
                variantKey: trackedVariantKey,
                messageId: messageId
            ),
            forKey: cacheKey,
            cost: cost
        )

        return result
    }

    private func trackCacheKey(_ cacheKey: String, variantKey: String, for messageId: String) -> String? {
        htmlCacheKeyLock.lock()
        let staleCacheKey = htmlCacheKeyByVariantKey[variantKey]
        if let staleCacheKey, staleCacheKey != cacheKey {
            htmlCacheKeysByMessageID[messageId]?.remove(staleCacheKey)
        }
        htmlCacheKeysByMessageID[messageId, default: []].insert(cacheKey)
        htmlCacheKeyByVariantKey[variantKey] = cacheKey
        htmlCacheKeyLock.unlock()

        return staleCacheKey == cacheKey ? nil : staleCacheKey
    }

    fileprivate func removeTrackedCacheKey(_ cacheKey: String, variantKey: String, for messageId: String) {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }

        guard var trackedKeys = htmlCacheKeysByMessageID[messageId] else { return }
        trackedKeys.remove(cacheKey)

        if trackedKeys.isEmpty {
            htmlCacheKeysByMessageID.removeValue(forKey: messageId)
        } else {
            htmlCacheKeysByMessageID[messageId] = trackedKeys
        }

        if htmlCacheKeyByVariantKey[variantKey] == cacheKey {
            htmlCacheKeyByVariantKey.removeValue(forKey: variantKey)
        }
    }

    private func removeTrackedVariantKey(_ variantKey: String, ifMappedTo cacheKey: String) {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }

        guard htmlCacheKeyByVariantKey[variantKey] == cacheKey else {
            return
        }

        htmlCacheKeyByVariantKey.removeValue(forKey: variantKey)
    }

#if DEBUG
    private func syncTrackedCacheKeysWithLiveCache(for messageId: String) -> Int {
        guard let trackedKeys = htmlCacheKeysByMessageID[messageId] else { return 0 }

        let liveKeys = Set(trackedKeys.filter { htmlCache.object(forKey: $0 as NSString) != nil })
        if liveKeys.isEmpty {
            htmlCacheKeysByMessageID.removeValue(forKey: messageId)
            return 0
        }

        if liveKeys != trackedKeys {
            htmlCacheKeysByMessageID[messageId] = liveKeys
        }

        return liveKeys.count
    }
#endif

    private func qualityFallbackResult(_ text: String) -> HTMLLoadResult {
        HTMLLoadResult(
            html: nil,
            source: .qualityFallback,
            presentation: .nativePlainText,
            nativeText: text
        )
    }

    private func approvedReplyQuotedHTML(
        from html: String?,
        plainText: String?,
        senderEmail: String?,
        subject: String?
    ) -> String? {
        guard let canonicalHTML = canonicalHTMLSource(from: html) else {
            return nil
        }

        let sanitizedHTML = sanitizer.sanitize(
            canonicalHTML,
            rewriteModernImageFormatHints: false
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(sanitizedHTML) else {
            return nil
        }

        let evaluation = qualityEvaluator.evaluate(
            html: sanitizedHTML,
            plainText: plainText,
            senderEmail: senderEmail,
            subject: subject
        )
        guard evaluation.presentation == .html else {
            return nil
        }

        return sanitizedHTML
    }

    private func canonicalHTMLSource(from html: String?) -> String? {
        guard let html else { return nil }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()

        // Older builds could persist the generated plain-text "See More" fallback as if it were
        // the original HTML. Treat those wrappers as stale cache artifacts so we can continue on
        // to raw-source extraction or Gmail recovery and show the real email instead.
        if lowercased.contains("esc-plain-text-styles") ||
            lowercased.contains("esc-plain-main") ||
            lowercased.contains("esc-plain-details") {
            return nil
        }

        return trimmed
    }

    private func wrappedHTMLIfMeaningful(
        _ html: String,
        messageId: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose,
        originalHTMLPreference: OriginalEmailHTMLPreference
    ) async -> PreparedLoadResult? {
        let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)
        let rewriteImageHints = displayPurpose != .original
        let sanitizedHTML = sanitizer.sanitize(
            preparedHTML,
            rewriteModernImageFormatHints: rewriteImageHints
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(sanitizedHTML) else {
            Log.debug("wrappedHTMLIfMeaningful: sanitized HTML not meaningful for \(messageId) (len=\(sanitizedHTML.count))", category: .ui)
            return nil
        }

        if displayPurpose == .original, originalHTMLPreference == .automatic {
            let evaluation = qualityEvaluator.evaluate(
                html: sanitizedHTML,
                plainText: plainText,
                senderEmail: senderEmail,
                subject: subject
            )

            if evaluation.presentation == .nativePlainText,
               let fallbackText = evaluation.fallbackText {
                Log.debug(
                    "wrappedHTMLIfMeaningful: original quality fallback for \(messageId): \(evaluation.summary)",
                    category: .ui
                )
                return .nativePlainText(fallbackText)
            }
        }

        let rewrittenHTML: String
        let shouldCache: Bool
        switch displayPurpose {
        case .original:
            // Full-message rendering should avoid handing risky WEBP/AVIF URLs to WKWebView on the
            // first open. Resolve the attachment-style fallback eagerly so the original reader is
            // closer to Apple Mail behavior instead of showing broken images and decoder errors.
            let originalSafeHTML = await remoteImageAttachmentFallback.inlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            rewrittenHTML = sanitizer.sanitize(
                originalSafeHTML,
                rewriteModernImageFormatHints: rewriteImageHints
            )
            shouldCache = true
        case .preview:
            let cachedRewrite = await remoteImageAttachmentFallback.cachedInlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.needsWarmup {
                warmRemoteImageAttachmentFallback(in: sanitizedHTML, messageId: messageId, senderEmail: senderEmail)
            }
            rewrittenHTML = cachedRewrite.html
            shouldCache = !cachedRewrite.hasPendingUpdates
        }

        // Use wrapSanitizedHTMLForDisplay to avoid re-sanitizing already-sanitized HTML.
        // Triple sanitization (sanitize → sanitize → wrapHTMLForDisplay.sanitize) was corrupting
        // complex newsletter HTML with nested tables and encoded attributes.
        let wrapped = sanitizer.wrapSanitizedHTMLForDisplay(
            rewrittenHTML,
            isDarkMode: isDarkMode,
            displayPurpose: displayPurpose
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) else {
            Log.debug("wrappedHTMLIfMeaningful: wrapped HTML not meaningful for \(messageId) (len=\(wrapped.count))", category: .ui)
            return nil
        }

        return .html(WrappedHTMLResult(html: wrapped, shouldCache: shouldCache))
    }

    private func warmRemoteImageAttachmentFallback(in html: String, messageId: String, senderEmail: String?) {
        let remoteImageAttachmentFallback = self.remoteImageAttachmentFallback
        // Warm rewritten image data promptly so a near-immediate reopen can pick up the cached
        // result instead of waiting behind low-priority detached work.
        Task(priority: .userInitiated) {
            let rewrittenHTML = await remoteImageAttachmentFallback.inlineAttachmentStyleImages(
                in: html,
                senderEmail: senderEmail
            )

            if rewrittenHTML != html {
                Log.debug(
                    "Warmed attachment-style remote image fallback for message \(messageId)",
                    category: .ui
                )
            }
        }
    }

    private func normalizedPlainTextFallback(from text: String) -> String {
        var normalized = RawEmailSourceSanitizer.extractDisplayText(from: text)
        normalized = HTMLEntityDecoder.decode(normalized)

        if looksQuotedPrintable(normalized) {
            normalized = QuotedPrintableDecoder.decode(normalized)
            normalized = HTMLEntityDecoder.decode(normalized)
        }

        normalized = normalized
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        if let regex = Self.previewPaddingRegex {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: " ")
        }

        normalized = normalized
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasMeaningfulPlainText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let nonWhitespace = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return !nonWhitespace.isEmpty
    }

    private func normalizedMeaningfulPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = normalizedPlainTextFallback(from: text)
        return hasMeaningfulPlainText(normalized) ? normalized : nil
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("=\r\n") ||
            lower.contains("=\n") ||
            lower.contains("=3d") ||
            lower.contains("=3c") ||
            lower.contains("=3e")
    }

    private func prepareHTMLForDisplay(_ html: String, cleanupMode: HTMLContentCleanupMode) -> String {
        switch cleanupMode {
        case .none:
            return html
        case .quotedOnly:
            let cleaned = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
            return fallbackToOriginalIfCleanedEmpty(cleaned: cleaned, original: html)
        case .quotedAndSignature:
            let cleaned = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
            if !HTMLMeaningfulContentChecker.hasMeaningfulContent(cleaned) {
                // If signature removal was too aggressive, fall back to quote-only cleanup.
                let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
                return fallbackToOriginalIfCleanedEmpty(cleaned: quotedOnly, original: html)
            }
            return cleaned
        }
    }

    private func fallbackToOriginalIfCleanedEmpty(cleaned: String, original: String) -> String {
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(cleaned) {
            return cleaned
        }
        return original
    }

    private func convertPlainTextToHTML(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Match Apple Mail's default behavior: display the main content and collapse
        // quoted history behind a "See More" affordance.
        // Keep the sender's sign-off visible (signature removal is a chat-bubble concern).
        let extraction = PlainTextQuoteRemover.extractQuotes(from: normalized, removingSignature: false)
        let main = linkifyPlainTextForHTML(extraction.mainContent)

        let quotedHTML: String = extraction.quotedParts.map { part in
            let quote = linkifyPlainTextForHTML(part.text)
            let attribution = part.attribution.map { linkifyPlainTextForHTML($0) }

            // Keep nesting conservative; this is a display hint, not a full quote formatter.
            let level = max(0, min(part.nestingLevel, 3))
            let extraIndent = level > 0 ? "margin-left: \(level * 10)px;" : ""

            var block = ""
            if let attribution, !attribution.isEmpty {
                block += "<div class=\"esc-plain-quote-attr\">\(attribution)</div>"
            }
            block += "<blockquote class=\"esc-plain-quote\" style=\"\(extraIndent)\">\(quote)</blockquote>"
            return block
        }.joined(separator: "\n")

        // If there's no main content, don't hide everything behind "See More".
        let hasMainContent = !extraction.mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let detailsSection: String
        if !quotedHTML.isEmpty && hasMainContent {
            detailsSection = """
            <details class="esc-plain-details">
              <summary>See More</summary>
              <div class="esc-plain-quotes">
                \(quotedHTML)
              </div>
            </details>
            """
        } else if !quotedHTML.isEmpty {
            detailsSection = """
            <div class="esc-plain-quotes">
              \(quotedHTML)
            </div>
            """
        } else {
            detailsSection = ""
        }

        // Style block lives in the fragment so we can keep the wrapper logic generic.
        // (This fragment is sanitized and then wrapped into a full document by HTMLDisplayWrapper.)
        let styles = """
        <style id="esc-plain-text-styles">
          .esc-plain-main {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 17px;
            line-height: 1.45;
          }

          .esc-plain-details {
            margin-top: 14px;
          }

          .esc-plain-details > summary {
            list-style: none;
            color: #007AFF;
            font-size: 15px;
            font-weight: 500;
            user-select: none;
            -webkit-user-select: none;
          }

          .esc-plain-details > summary::-webkit-details-marker {
            display: none;
          }

          .esc-plain-quotes {
            margin-top: 10px;
          }

          .esc-plain-quote-attr {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 15px;
            line-height: 1.35;
            color: rgba(0, 0, 0, 0.6);
            margin: 0 0 6px 0;
          }

          .esc-plain-quote {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 15px;
            line-height: 1.35;
            margin: 0 0 10px 0;
            padding-left: 12px;
            border-left: 2px solid rgba(0, 0, 0, 0.18);
            color: rgba(0, 0, 0, 0.65);
          }

          @media (prefers-color-scheme: dark) {
            .esc-plain-quote-attr {
              color: rgba(255, 255, 255, 0.65);
            }
            .esc-plain-quote {
              border-left-color: rgba(255, 255, 255, 0.22);
              color: rgba(255, 255, 255, 0.70);
            }
          }
        </style>
        """

        return """
        \(styles)
        <div class="esc-plain-main">\(main)</div>
        \(detailsSection)
        """
    }

    private func linkifyPlainTextForHTML(_ text: String) -> String {
        guard let detector = Self.linkDetector else {
            return escapeHTML(text)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return escapeHTML(text)
        }

        var result = ""
        var currentLocation = 0

        for match in matches {
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { continue }

            if range.location > currentLocation {
                let plainSegment = nsText.substring(with: NSRange(location: currentLocation, length: range.location - currentLocation))
                result += escapeHTML(plainSegment)
            }

            let matchedText = nsText.substring(with: range)
            if let detectedURL = match.url,
               let safeURL = normalizedLinkURL(detectedURL: detectedURL, originalText: matchedText) {
                result += "<a href=\"\(escapeHTMLAttribute(safeURL.absoluteString))\">\(escapeHTML(matchedText))</a>"
            } else {
                result += escapeHTML(matchedText)
            }

            currentLocation = range.location + range.length
        }

        if currentLocation < nsText.length {
            result += escapeHTML(nsText.substring(from: currentLocation))
        }

        return result
    }

    private func normalizedLinkURL(detectedURL: URL, originalText: String) -> URL? {
        if let scheme = detectedURL.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else {
                return nil
            }
            return detectedURL
        }

        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("www."),
              let url = URL(string: "https://\(trimmed)") else {
            return nil
        }
        return url
    }

    private func escapeHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeHTMLAttribute(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
