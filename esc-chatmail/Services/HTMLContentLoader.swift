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
    let sourceSignature: String?

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
        nativeText: String? = nil,
        sourceSignature: String? = nil
    ) {
        self.html = html
        self.source = source
        self.presentation = presentation
        self.nativeText = nativeText
        self.sourceSignature = sourceSignature
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

struct PreparedOriginalHTML: Sendable {
    let html: String
    let shouldCache: Bool
}

private enum PreparedLoadResult {
    case html(WrappedHTMLResult)
    case nativePlainText(String)
}

private enum RemoteImageFallbackWarmupScope {
    case attachmentStyle
    case riskyModernFormat
}

/// Service for loading HTML content from various sources
final class HTMLContentLoader {
    static let shared = HTMLContentLoader()
    static let remoteImageAttachmentFallbackDidWarmNotification = Notification.Name("HTMLContentLoader.remoteImageAttachmentFallbackDidWarm")
    static let remoteImageAttachmentFallbackMessageIdUserInfoKey = "messageId"
    static let contentSourceDidChangeNotification = Notification.Name("HTMLContentLoader.contentSourceDidChange")
    static let contentSourceDidChangeMessageIdUserInfoKey = "messageId"
    static let contentSourceDidChangeSourceSignatureUserInfoKey = "sourceSignature"

    private let contentHandler: HTMLContentHandler
    private let sanitizer: HTMLSanitizerService
    private let remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback
    private let qualityEvaluator: EmailRenderQualityEvaluator
    private let parsedEmailProvider: any ParsedEmailProviding
    private let recoveryService: any HTMLContentRecovering

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
        qualityEvaluator: EmailRenderQualityEvaluator = EmailRenderQualityEvaluator(),
        parsedEmailProvider: any ParsedEmailProviding = ParsedEmailProvider.shared,
        recoveryService: any HTMLContentRecovering = HTMLContentRecoveryService.shared
    ) {
        self.contentHandler = contentHandler
        self.sanitizer = sanitizer
        self.remoteImageAttachmentFallback = remoteImageAttachmentFallback
        self.qualityEvaluator = qualityEvaluator
        self.parsedEmailProvider = parsedEmailProvider
        self.recoveryService = recoveryService
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
            invalidateCachedResults(messageId: messageId) { _ in true }
        } else if let cachedResult = cachedHTMLResultForUnavailableSource(variantKey: variantKey) {
            return cachedResult
        }

        // Method 4: Recovery - fetch from Gmail API if local content missing
        if let recoveredHTML = await recoveryService.recoverHTMLContent(messageId: messageId),
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
                    nativeText: normalizedText,
                    sourceSignature: "plainText:\(sourceSignature(for: normalizedText))"
                )
            }

            let html = convertPlainTextToHTML(normalizedText)
            let wrapped = sanitizer.wrapHTMLForDisplay(
                html,
                isDarkMode: isDarkMode,
                displayPurpose: displayPurpose
            )
            if HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) {
                return HTMLLoadResult(
                    html: wrapped,
                    source: .plainTextFallback,
                    sourceSignature: "plainText:\(sourceSignature(for: normalizedText))"
                )
            }
        }

        return HTMLLoadResult(html: nil, source: .notFound)
    }

    /// Loads content with timeout support.
    ///
    /// Uses `withSoftTimeout` instead of `withTaskGroup`: `loadContent` awaits
    /// shared `Task<_, Never>` recovery work that ignores cooperative
    /// cancellation, so a `withTaskGroup`-based race would still block until
    /// the work finished. The soft timeout returns `.notFound` to the caller on
    /// deadline while the underlying work continues to warm caches for the next
    /// open. Mirrors the change in `OriginalEmailSourceLoader.loadOriginalEmailSource`.
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
        let result = await withSoftTimeout(seconds: timeout) {
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
        return result ?? HTMLLoadResult(html: nil, source: .notFound)
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
        await loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery
        )?.html
    }

    /// Loads typed canonical content without applying preview/full-message presentation wrappers.
    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        allowRecovery: Bool = true
    ) async -> CanonicalEmailContent? {
        await CanonicalEmailContentLoader(
            contentHandler: contentHandler,
            recoveryService: recoveryService
        ).loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery
        )
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
        let sourceSignature = sourceSignature(for: normalizedCanonicalHTML)
        guard let prepared = await wrappedHTMLIfMeaningful(
            normalizedCanonicalHTML,
            sourceSignature: sourceSignature,
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

    /// Wraps canonical HTML for the full original-email reader. This method deliberately
    /// avoids preview cleanup, preview CSS, and original-readable plain-text quality fallback.
    func prepareOriginalHTML(
        fromCanonicalHTML canonicalHTML: String,
        messageId: String,
        sourceLocation: CanonicalEmailSourceLocation = .messageFile,
        plainText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil,
        isDarkMode: Bool
    ) async -> String? {
        await prepareOriginalHTMLForCaching(
            fromCanonicalHTML: canonicalHTML,
            messageId: messageId,
            sourceLocation: sourceLocation,
            plainText: plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode
        )?.html
    }

    func prepareOriginalHTMLForCaching(
        fromCanonicalHTML canonicalHTML: String,
        messageId: String,
        sourceLocation: CanonicalEmailSourceLocation = .messageFile,
        plainText: String? = nil,
        senderEmail: String? = nil,
        subject: String? = nil,
        isDarkMode: Bool
    ) async -> PreparedOriginalHTML? {
        guard let normalizedCanonicalHTML = canonicalHTMLSource(from: canonicalHTML) else {
            return nil
        }

        let normalizedFallbackText = normalizedMeaningfulPlainText(from: plainText)
        let variantKey = cacheVariantKey(
            messageId: messageId,
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: .none,
            displayPurpose: .original,
            originalHTMLPreference: .preferHTML
        )

        guard let prepared = await cacheableOrPreparedHTMLResult(
            normalizedCanonicalHTML,
            source: htmlLoadSource(for: sourceLocation),
            messageId: messageId,
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: .none,
            displayPurpose: .original,
            originalHTMLPreference: .preferHTML,
            variantKey: variantKey
        ) else {
            return nil
        }

        guard prepared.result.presentation == .html,
              let html = prepared.result.html else {
            return nil
        }

        return PreparedOriginalHTML(html: html, shouldCache: prepared.shouldCache)
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
        Task {
            await RenderedMessageCache.shared.invalidate(messageId: messageId, reason: .explicit)
            await parsedEmailProvider.invalidate(messageId: messageId)
        }
    }

    /// Invalidates cached HTML content and awaits shared rendered/parsed cache invalidation.
    func invalidateContent(messageId: String) async {
        invalidateCachedResults(messageId: messageId) { _ in true }
        await RenderedMessageCache.shared.invalidate(messageId: messageId, reason: .explicit)
        await parsedEmailProvider.invalidate(messageId: messageId)
    }

    @MainActor
    static func postContentSourceDidChange(messageId: String, sourceSignature: String?) {
        var userInfo: [String: Any] = [
            contentSourceDidChangeMessageIdUserInfoKey: messageId
        ]
        if let sourceSignature {
            userInfo[contentSourceDidChangeSourceSignatureUserInfoKey] = sourceSignature
        }

        NotificationCenter.default.post(
            name: contentSourceDidChangeNotification,
            object: nil,
            userInfo: userInfo
        )
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

    private struct CacheableHTMLLoadResult {
        let result: HTMLLoadResult
        let shouldCache: Bool
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
        await cacheableOrPreparedHTMLResult(
            html,
            source: source,
            messageId: messageId,
            plainText: plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode,
            displayPurpose: displayPurpose,
            originalHTMLPreference: originalHTMLPreference,
            variantKey: variantKey
        )?.result
    }

    private func cacheableOrPreparedHTMLResult(
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
    ) async -> CacheableHTMLLoadResult? {
        let sourceSignature = sourceSignature(for: html)
        let cacheKey = cacheKey(
            variantKey: variantKey,
            source: source,
            sourceSignature: sourceSignature
        )

        if let cachedResult = htmlCache.object(forKey: cacheKey) {
            return CacheableHTMLLoadResult(result: cachedResult.result, shouldCache: true)
        }

        guard let prepared = await wrappedHTMLIfMeaningful(
            html,
            sourceSignature: sourceSignature,
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
            return CacheableHTMLLoadResult(
                result: cachedHTMLResult(
                    html: wrapped.html,
                    source: source,
                    shouldCache: wrapped.shouldCache,
                    cacheKey: cacheKey,
                    variantKey: variantKey,
                    messageId: messageId,
                    sourceSignature: sourceSignature
                ),
                shouldCache: wrapped.shouldCache
            )
        case .nativePlainText(let text):
            return CacheableHTMLLoadResult(result: qualityFallbackResult(text), shouldCache: true)
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
        messageId: String,
        sourceSignature: String
    ) -> HTMLLoadResult {
        let result = HTMLLoadResult(html: html, source: source, sourceSignature: sourceSignature)

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
        sourceSignature: String,
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

        // Full original-email reader open path (preferHTML): JavaScript is disabled in every
        // reader/preview WebView config, links are gated by the navigation policy, and the wrapper
        // emits a hardened CSP. Keep a narrow active-markup/event-handler strip so scripts, meta
        // refresh, frames, base/link/object/svg markup cannot load or navigate, but preserve inert
        // visible content such as noscript fallbacks and CTA/receipt text in button/label markup.
        // Keep the existing href/src URL safety pass so unsupported links stay inert and unsafe
        // image sources never reach WebKit. Broader URL/CSS/tracking rewrites are redundant work
        // here and can corrupt complex nested-table HTML. Remote http(s) images load directly via
        // WebKit when possible; risky modern-format image candidates still use the original
        // nonblocking attachment fallback below. The automatic-preference original path
        // (chat-derived previews, quality fallback) keeps full sanitization below.
        if displayPurpose == .original, originalHTMLPreference == .preferHTML {
            let activeMarkupSafeHTML = sanitizer.removeOriginalReaderActiveMarkupAndEventHandlers(preparedHTML)
            let safeHTML = sanitizer.sanitizeOriginalReaderURLs(activeMarkupSafeHTML)
            guard HTMLMeaningfulContentChecker.hasMeaningfulContent(safeHTML) else {
                Log.debug("wrappedHTMLIfMeaningful: original preferHTML content not meaningful for \(messageId) (len=\(safeHTML.count))", category: .ui)
                return nil
            }

            let cachedRewrite = await remoteImageAttachmentFallback.cachedRiskyModernFormatImages(
                in: safeHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: safeHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail,
                    scope: .riskyModernFormat
                )
            }

            let wrapped = sanitizer.wrapSanitizedHTMLForDisplay(
                cachedRewrite.html,
                isDarkMode: isDarkMode,
                displayPurpose: .original,
                headSerialization: .stringOnly
            )
            guard HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) else {
                Log.debug("wrappedHTMLIfMeaningful: wrapped original preferHTML not meaningful for \(messageId) (len=\(wrapped.count))", category: .ui)
                return nil
            }

            return .html(WrappedHTMLResult(html: wrapped, shouldCache: !cachedRewrite.hasPendingUpdates))
        }

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
            let parsedEmail = await parsedEmailProvider.parsedEmail(
                messageId: messageId,
                sourceSignature: [
                    sourceSignature,
                    "sanitized",
                    "cleanup:\(cleanupMode.rawValue)",
                    "purpose:\(displayPurpose.rawValue)"
                ].joined(separator: "|"),
                canonicalHTML: sanitizedHTML,
                includeRenderQuality: true
            )
            let evaluation = qualityEvaluator.evaluate(
                parsedEmail: parsedEmail,
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
            let cachedRewrite = await remoteImageAttachmentFallback.cachedInlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: sanitizedHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail
                )
            }
            // Skip a second full sanitize pass when the attachment-image rewrite changed nothing
            // (the common case for the full-view open). Re-sanitizing identical, already-sanitized
            // HTML is wasted CPU on the hot path and a known corruption risk for complex
            // nested-table newsletters; only re-sanitize when the rewrite actually mutated the HTML.
            if cachedRewrite.html == sanitizedHTML {
                rewrittenHTML = sanitizedHTML
            } else {
                rewrittenHTML = sanitizer.sanitize(
                    cachedRewrite.html,
                    rewriteModernImageFormatHints: rewriteImageHints
                )
            }
            shouldCache = !cachedRewrite.hasPendingUpdates
        case .preview:
            let cachedRewrite = await remoteImageAttachmentFallback.previewInlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: sanitizedHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail
                )
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

    private func warmRemoteImageAttachmentFallback(
        in html: String,
        currentHTML: String,
        messageId: String,
        senderEmail: String?,
        scope: RemoteImageFallbackWarmupScope = .attachmentStyle
    ) {
        let remoteImageAttachmentFallback = self.remoteImageAttachmentFallback
        // Warm rewritten image data promptly so a near-immediate reopen can pick up the cached
        // result instead of waiting behind low-priority detached work.
        Task(priority: .userInitiated) {
            let warmedRewrite: HTMLRemoteImageAttachmentFallback.CachedRewriteResult
            switch scope {
            case .attachmentStyle:
                _ = await remoteImageAttachmentFallback.inlineAttachmentStyleImages(
                    in: html,
                    senderEmail: senderEmail
                )
                warmedRewrite = await remoteImageAttachmentFallback.cachedInlineAttachmentStyleImages(
                    in: html,
                    senderEmail: senderEmail
                )
            case .riskyModernFormat:
                _ = await remoteImageAttachmentFallback.inlineRiskyModernFormatImages(
                    in: html,
                    senderEmail: senderEmail
                )
                warmedRewrite = await remoteImageAttachmentFallback.cachedRiskyModernFormatImages(
                    in: html,
                    senderEmail: senderEmail
                )
            }

            if !warmedRewrite.hasPendingUpdates, warmedRewrite.html != currentHTML {
                Log.debug(
                    "Warmed attachment-style remote image fallback for message \(messageId)",
                    category: .ui
                )
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.remoteImageAttachmentFallbackDidWarmNotification,
                        object: self,
                        userInfo: [Self.remoteImageAttachmentFallbackMessageIdUserInfoKey: messageId]
                    )
                }
            }
        }
    }

}
