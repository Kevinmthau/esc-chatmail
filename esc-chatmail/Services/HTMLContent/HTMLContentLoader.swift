import CryptoKit
import Foundation

struct HTMLContentInvalidationAccountContext: Sendable {
    let htmlContent: HTMLContentAccountGeneration
    let resultCache: HTMLContentResultCacheAccountGeneration
    let renderedMessage: RenderedMessageCacheAccountGeneration
    let parsedEmail: ParsedEmailAccountGeneration?
}

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

// Internal (not private): the +SourcePreparation extension produces these and
// the loader's cache orchestration (this file) consumes them.
struct WrappedHTMLResult {
    let html: String
    let shouldCache: Bool
}

struct PreparedOriginalHTML: Sendable {
    let html: String
    let shouldCache: Bool
}

// Internal (not private): return type of wrappedHTMLIfMeaningful in
// +SourcePreparation, consumed by the load paths in this file.
enum PreparedLoadResult {
    case html(WrappedHTMLResult)
    case nativePlainText(String)
}

// Internal (not private): used by warmRemoteImageAttachmentFallback in
// +SourcePreparation.
enum RemoteImageFallbackWarmupScope {
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

    // Internal (not private) so the +SourcePreparation extension can reach them.
    let contentHandler: HTMLContentHandler
    let sanitizer: HTMLSanitizerService
    let remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback
    let qualityEvaluator: EmailRenderQualityEvaluator
    let parsedEmailProvider: any ParsedEmailProviding
    private let recoveryService: any HTMLContentRecovering

    /// In-memory cache for prepared HTML content to avoid repeated disk I/O.
    /// Keyed by the display variant (plus automatic original-view evaluator
    /// inputs) and the source content signature.
    private let resultCache = HTMLContentResultCache()

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
    }

    func captureAccountGeneration() -> HTMLContentAccountGeneration? {
        contentHandler.captureAccountGeneration()
    }

    func isAccountGenerationCurrent(_ generation: HTMLContentAccountGeneration) -> Bool {
        contentHandler.isAccountGenerationCurrent(generation)
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
        originalHTMLPreference: OriginalEmailHTMLPreference = .automatic,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) async -> HTMLLoadResult {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration),
              let resultCacheGeneration = resultCache.captureAccountGeneration() else {
            return HTMLLoadResult(html: nil, source: .notFound)
        }
        guard let recoveryGeneration = await recoveryService.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration),
              resultCache.isAccountGenerationCurrent(resultCacheGeneration) else {
            return HTMLLoadResult(html: nil, source: .notFound)
        }
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
        if contentHandler.htmlFileExists(for: messageId, expectedGeneration: accountGeneration) {
            if let html = canonicalHTMLSource(from: contentHandler.loadHTML(
                for: messageId,
                expectedGeneration: accountGeneration
            )),
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
                    variantKey: variantKey,
                    accountGeneration: accountGeneration,
                    resultCacheGeneration: resultCacheGeneration
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
            if let html = canonicalHTMLSource(from: contentHandler.loadHTML(
                from: url,
                expectedGeneration: accountGeneration
            )),
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !rejectedHTMLSources.isEmpty {
                    invalidateCachedResults(
                        messageId: messageId,
                        sources: rejectedHTMLSources,
                        expectedGeneration: resultCacheGeneration
                    )
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
                    variantKey: variantKey,
                    accountGeneration: accountGeneration,
                    resultCacheGeneration: resultCacheGeneration
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
                    invalidateCachedResults(
                        messageId: messageId,
                        sources: rejectedHTMLSources,
                        expectedGeneration: resultCacheGeneration
                    )
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
                    variantKey: variantKey,
                    accountGeneration: accountGeneration,
                    resultCacheGeneration: resultCacheGeneration
                ) {
                    return result
                }
                Log.debug("loadContent: Method 3 (rawSourceHTML) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
            }
            rejectedHTMLSources.insert(.rawSourceHTML)
        }

        if !rejectedHTMLSources.isEmpty {
            invalidateCachedResults(
                messageId: messageId,
                expectedGeneration: resultCacheGeneration
            ) { _ in true }
        } else if contentHandler.isAccountGenerationCurrent(accountGeneration),
                  let cachedResult = resultCache.resultForVariant(
                      variantKey as String,
                      expectedGeneration: resultCacheGeneration
                  ) {
            return cachedResult
        }

        // Method 4: Recovery - fetch from Gmail API if local content missing
        if let recoveredHTML = await recoveryService.recoverHTMLContent(
            messageId: messageId,
            expectedAccountGeneration: recoveryGeneration
        ),
           contentHandler.isAccountGenerationCurrent(accountGeneration),
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
               variantKey: variantKey,
               accountGeneration: accountGeneration,
               resultCacheGeneration: resultCacheGeneration
           ) {
            return result
        }

        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return HTMLLoadResult(html: nil, source: .notFound)
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
        timeout: TimeInterval = 5.0,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) async -> HTMLLoadResult {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return HTMLLoadResult(html: nil, source: .notFound)
        }
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
                originalHTMLPreference: originalHTMLPreference,
                expectedAccountGeneration: accountGeneration
            )
        }
        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return HTMLLoadResult(html: nil, source: .notFound)
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
        await loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery,
            expectedAccountGeneration: nil
        )
    }

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        allowRecovery: Bool,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent? {
        await CanonicalEmailContentLoader(
            contentHandler: contentHandler,
            recoveryService: recoveryService
        ).loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery,
            expectedAccountGeneration: expectedAccountGeneration
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
        cleanupMode: HTMLContentCleanupMode = .none,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) async -> String? {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        guard let remoteImageAccountGeneration = await remoteImageAttachmentFallback.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
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
            originalHTMLPreference: .automatic,
            accountGeneration: accountGeneration,
            remoteImageAccountGeneration: remoteImageAccountGeneration
        ) else {
            return nil
        }
        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
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
        isDarkMode: Bool,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) async -> PreparedOriginalHTML? {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration),
              let resultCacheGeneration = resultCache.captureAccountGeneration() else {
            return nil
        }
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
            variantKey: variantKey,
            accountGeneration: accountGeneration,
            resultCacheGeneration: resultCacheGeneration
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

    /// Captures every cache generation needed to invalidate content without an
    /// old account operation reaching into caches that have since reopened.
    func captureInvalidationAccountContext(
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) async -> HTMLContentInvalidationAccountContext? {
        guard let htmlContent = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(htmlContent),
              let resultCacheGeneration = resultCache.captureAccountGeneration(),
              let renderedMessage = await RenderedMessageCache.shared.captureAccountGeneration() else {
            return nil
        }
        let parsedEmail = await parsedEmailProvider.captureAccountGeneration()
        guard contentHandler.isAccountGenerationCurrent(htmlContent),
              resultCache.isAccountGenerationCurrent(resultCacheGeneration),
              await RenderedMessageCache.shared.isAccountGenerationCurrent(renderedMessage) else {
            return nil
        }
        if let parsedEmail,
           !(await parsedEmailProvider.isAccountGenerationCurrent(parsedEmail)) {
            return nil
        }
        return HTMLContentInvalidationAccountContext(
            htmlContent: htmlContent,
            resultCache: resultCacheGeneration,
            renderedMessage: renderedMessage,
            parsedEmail: parsedEmail
        )
    }

    /// Invalidates cached HTML content and awaits shared rendered/parsed cache invalidation.
    func invalidateContent(messageId: String) async {
        guard let accountContext = await captureInvalidationAccountContext() else { return }
        await invalidateContent(messageId: messageId, accountContext: accountContext)
    }

    func invalidateContent(
        messageId: String,
        accountContext: HTMLContentInvalidationAccountContext
    ) async {
        guard contentHandler.isAccountGenerationCurrent(accountContext.htmlContent),
              resultCache.isAccountGenerationCurrent(accountContext.resultCache),
              await RenderedMessageCache.shared.isAccountGenerationCurrent(
                  accountContext.renderedMessage
              ) else {
            return
        }
        if let parsedEmail = accountContext.parsedEmail,
           !(await parsedEmailProvider.isAccountGenerationCurrent(parsedEmail)) {
            return
        }

        invalidateCachedResults(
            messageId: messageId,
            expectedGeneration: accountContext.resultCache
        ) { _ in true }
        await RenderedMessageCache.shared.invalidate(
            messageId: messageId,
            reason: .explicit,
            expectedAccountGeneration: accountContext.renderedMessage
        )
        if let parsedEmail = accountContext.parsedEmail {
            await parsedEmailProvider.invalidate(
                messageId: messageId,
                expectedAccountGeneration: parsedEmail
            )
        }
    }

    func closeAccountWorkAndClearCaches() async {
        await remoteImageAttachmentFallback.closeAccountWorkAndAwait()
        resultCache.closeAccountWorkAndClear()
        await RenderedMessageCache.shared.closeAccountWorkAndClear()
        await ParsedEmailProvider.shared.closeAccountWorkAndClear()
    }

    func reopenAccountWork() async {
        await remoteImageAttachmentFallback.reopenAccountWork()
        resultCache.reopenAccountWork()
        await RenderedMessageCache.shared.reopenAccountWork()
        await ParsedEmailProvider.shared.reopenAccountWork()
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
        sources: Set<HTMLLoadResult.HTMLLoadSource>,
        expectedGeneration: HTMLContentResultCacheAccountGeneration? = nil
    ) {
        invalidateCachedResults(
            messageId: messageId,
            expectedGeneration: expectedGeneration
        ) { sources.contains($0) }
    }

    private func invalidateCachedResults(
        messageId: String,
        expectedGeneration: HTMLContentResultCacheAccountGeneration? = nil,
        matching shouldInvalidate: (HTMLLoadResult.HTMLLoadSource) -> Bool
    ) {
        resultCache.invalidate(
            messageId: messageId,
            matching: shouldInvalidate,
            expectedGeneration: expectedGeneration
        )
    }

#if DEBUG
    func debugCachedVariantCount(for messageId: String) -> Int {
        resultCache.variantCount(for: messageId)
    }

    func debugTotalCachedVariantCount() -> Int {
        resultCache.totalVariantCount()
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
        variantKey: NSString,
        accountGeneration: HTMLContentAccountGeneration,
        resultCacheGeneration: HTMLContentResultCacheAccountGeneration
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
            variantKey: variantKey,
            accountGeneration: accountGeneration,
            resultCacheGeneration: resultCacheGeneration
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
        variantKey: NSString,
        accountGeneration: HTMLContentAccountGeneration,
        resultCacheGeneration: HTMLContentResultCacheAccountGeneration
    ) async -> CacheableHTMLLoadResult? {
        guard contentHandler.isAccountGenerationCurrent(accountGeneration),
              let remoteImageAccountGeneration = await remoteImageAttachmentFallback.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        let sourceSignature = sourceSignature(for: html)
        let cacheKey = cacheKey(
            variantKey: variantKey,
            source: source,
            sourceSignature: sourceSignature
        )

        if contentHandler.isAccountGenerationCurrent(accountGeneration),
           let cachedResult = resultCache.result(
               forKey: cacheKey,
               expectedGeneration: resultCacheGeneration
           ) {
            return CacheableHTMLLoadResult(result: cachedResult, shouldCache: true)
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
            originalHTMLPreference: originalHTMLPreference,
            accountGeneration: accountGeneration,
            remoteImageAccountGeneration: remoteImageAccountGeneration
        ) else {
            return nil
        }

        guard contentHandler.isAccountGenerationCurrent(accountGeneration),
              resultCache.isAccountGenerationCurrent(resultCacheGeneration) else {
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
                    sourceSignature: sourceSignature,
                    accountGeneration: accountGeneration,
                    resultCacheGeneration: resultCacheGeneration
                ),
                shouldCache: wrapped.shouldCache
            )
        case .nativePlainText(let text):
            return CacheableHTMLLoadResult(result: qualityFallbackResult(text), shouldCache: true)
        }
    }

    private func cachedHTMLResult(
        html: String,
        source: HTMLLoadResult.HTMLLoadSource,
        shouldCache: Bool,
        cacheKey: NSString,
        variantKey: NSString,
        messageId: String,
        sourceSignature: String,
        accountGeneration: HTMLContentAccountGeneration,
        resultCacheGeneration: HTMLContentResultCacheAccountGeneration
    ) -> HTMLLoadResult {
        let result = HTMLLoadResult(html: html, source: source, sourceSignature: sourceSignature)

        guard shouldCache,
              contentHandler.isAccountGenerationCurrent(accountGeneration),
              resultCache.isAccountGenerationCurrent(resultCacheGeneration) else {
            return result
        }

        resultCache.store(
            result,
            cacheKey: cacheKey,
            variantKey: variantKey,
            messageId: messageId,
            cost: html.utf8.count,
            expectedGeneration: resultCacheGeneration
        )

        return result
    }

}
