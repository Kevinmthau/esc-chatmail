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
    let canViewOriginalHTML: Bool

    enum HTMLLoadSource: Equatable {
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
        canViewOriginalHTML: Bool = false
    ) {
        self.html = html
        self.source = source
        self.presentation = presentation
        self.nativeText = nativeText
        self.canViewOriginalHTML = canViewOriginalHTML
    }
}

private final class CachedHTMLLoadResultBox {
    let result: HTMLLoadResult

    init(_ result: HTMLLoadResult) {
        self.result = result
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
    private let htmlCacheKeyLock = NSLock()
    private var htmlCacheKeysByMessageID: [String: Set<String>] = [:]

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
        // Limit cache to ~50MB with both count and cost limits for proper memory pressure response
        htmlCache.countLimit = 1000
        htmlCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
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
        let cacheKey = cacheKey(
            messageId: messageId,
            plainText: normalizedFallbackText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
            cleanupMode: cleanupMode,
            displayPurpose: displayPurpose,
            originalHTMLPreference: originalHTMLPreference
        )

        if let cachedResult = htmlCache.object(forKey: cacheKey) {
            return cachedResult.result
        }

        // Method 1: Try loading from message ID.
        // Treat empty HTML as missing so we can fall back to storage URI / recovery / plain text.
        if contentHandler.htmlFileExists(for: messageId),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(for: messageId)),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let prepared = await wrappedHTMLIfMeaningful(
                html,
                messageId: messageId,
                plainText: normalizedFallbackText,
                senderEmail: senderEmail,
                subject: subject,
                isDarkMode: isDarkMode,
                cleanupMode: cleanupMode,
                displayPurpose: displayPurpose,
                originalHTMLPreference: originalHTMLPreference
            ) {
                switch prepared {
                case .html(let wrapped):
                    return cachedHTMLResult(
                        html: wrapped.html,
                        source: .messageId,
                        shouldCache: wrapped.shouldCache,
                        cacheKey: cacheKey,
                        messageId: messageId
                    )
                case .nativePlainText(let text):
                    return qualityFallbackResult(text)
                }
            }
            Log.debug("loadContent: Method 1 (messageId file) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
        }

        // Method 2: Try loading from stored URI
        if let urlString = bodyStorageURI,
           let url = StorageURIResolver.resolve(urlString),
           FileManager.default.fileExists(atPath: url.path),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(from: url)),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let prepared = await wrappedHTMLIfMeaningful(
                html,
                messageId: messageId,
                plainText: normalizedFallbackText,
                senderEmail: senderEmail,
                subject: subject,
                isDarkMode: isDarkMode,
                cleanupMode: cleanupMode,
                displayPurpose: displayPurpose,
                originalHTMLPreference: originalHTMLPreference
            ) {
                switch prepared {
                case .html(let wrapped):
                    return cachedHTMLResult(
                        html: wrapped.html,
                        source: .storageURI,
                        shouldCache: wrapped.shouldCache,
                        cacheKey: cacheKey,
                        messageId: messageId
                    )
                case .nativePlainText(let text):
                    return qualityFallbackResult(text)
                }
            }
            Log.debug("loadContent: Method 2 (storageURI) rejected by wrappedHTMLIfMeaningful for \(messageId) (htmlLen=\(html.count))", category: .ui)
        }

        // Method 3: Extract embedded HTML from raw RFC822 source stored in bodyText
        if let text = bodyText,
           let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: text),
           let prepared = await wrappedHTMLIfMeaningful(
               rawSourceHTML,
               messageId: messageId,
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject,
               isDarkMode: isDarkMode,
               cleanupMode: cleanupMode,
               displayPurpose: displayPurpose,
               originalHTMLPreference: originalHTMLPreference
           ) {
            switch prepared {
            case .html(let wrapped):
                return cachedHTMLResult(
                    html: wrapped.html,
                    source: .rawSourceHTML,
                    shouldCache: wrapped.shouldCache,
                    cacheKey: cacheKey,
                    messageId: messageId
                )
            case .nativePlainText(let text):
                return qualityFallbackResult(text)
            }
        }

        // Method 4: Recovery - fetch from Gmail API if local content missing
        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId),
           let prepared = await wrappedHTMLIfMeaningful(
               html,
               messageId: messageId,
               plainText: normalizedFallbackText,
               senderEmail: senderEmail,
               subject: subject,
               isDarkMode: isDarkMode,
               cleanupMode: cleanupMode,
               displayPurpose: displayPurpose,
               originalHTMLPreference: originalHTMLPreference
           ) {
            switch prepared {
            case .html(let wrapped):
                return cachedHTMLResult(
                    html: wrapped.html,
                    source: .recovered,
                    shouldCache: wrapped.shouldCache,
                    cacheKey: cacheKey,
                    messageId: messageId
                )
            case .nativePlainText(let text):
                return qualityFallbackResult(text)
            }
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
        bodyText: String? = nil
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

        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId) {
            return canonicalHTMLSource(from: html)
        }

        return nil
    }

    /// Invalidates cached HTML content for a message (both light/dark variants).
    func invalidate(messageId: String) {
        let keys: [String]
        htmlCacheKeyLock.lock()
        keys = Array(htmlCacheKeysByMessageID.removeValue(forKey: messageId) ?? [])
        htmlCacheKeyLock.unlock()

        for key in keys {
            htmlCache.removeObject(forKey: key as NSString)
        }
    }

#if DEBUG
    func debugCachedVariantCount(for messageId: String) -> Int {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }
        return htmlCacheKeysByMessageID[messageId]?.count ?? 0
    }

    func debugTotalCachedVariantCount() -> Int {
        htmlCacheKeyLock.lock()
        defer { htmlCacheKeyLock.unlock() }
        return htmlCacheKeysByMessageID.values.reduce(0) { $0 + $1.count }
    }
#endif

    private func cacheKey(
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

    private func cachedHTMLResult(
        html: String,
        source: HTMLLoadResult.HTMLLoadSource,
        shouldCache: Bool,
        cacheKey: NSString,
        messageId: String
    ) -> HTMLLoadResult {
        let result = HTMLLoadResult(html: html, source: source)

        guard shouldCache else {
            return result
        }

        let cost = html.utf8.count
        htmlCache.setObject(CachedHTMLLoadResultBox(result), forKey: cacheKey, cost: cost)

        htmlCacheKeyLock.lock()
        htmlCacheKeysByMessageID[messageId, default: []].insert(cacheKey as String)
        htmlCacheKeyLock.unlock()

        return result
    }

    private func qualityFallbackResult(_ text: String) -> HTMLLoadResult {
        HTMLLoadResult(
            html: nil,
            source: .qualityFallback,
            presentation: .nativePlainText,
            nativeText: text,
            canViewOriginalHTML: true
        )
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
        Task.detached(priority: .utility) {
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
