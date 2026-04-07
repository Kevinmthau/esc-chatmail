import Foundation

enum HTMLContentCleanupMode: String, CaseIterable, Sendable {
    case none
    case quotedOnly
    case quotedAndSignature
}

/// Result of HTML content loading
struct HTMLLoadResult {
    let html: String?
    let source: HTMLLoadSource

    enum HTMLLoadSource {
        case messageId
        case storageURI
        case rawSourceHTML
        case recovered
        case plainTextFallback
        case notFound
    }
}

private struct WrappedHTMLResult {
    let html: String
    let shouldCache: Bool
}

/// Service for loading HTML content from various sources
final class HTMLContentLoader {
    static let shared = HTMLContentLoader()

    private let contentHandler: HTMLContentHandler
    private let sanitizer: HTMLSanitizerService
    private let remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback
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

    /// In-memory cache for wrapped HTML content to avoid repeated disk I/O
    /// Key format: "\(messageId)_\(isDarkMode)" to cache both light and dark variants
    private let htmlCache = NSCache<NSString, NSString>()

    init(
        contentHandler: HTMLContentHandler = HTMLContentHandler(),
        sanitizer: HTMLSanitizerService = .shared,
        remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback = .shared
    ) {
        self.contentHandler = contentHandler
        self.sanitizer = sanitizer
        self.remoteImageAttachmentFallback = remoteImageAttachmentFallback
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
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none,
        displayPurpose: HTMLDisplayPurpose = .preview
    ) async -> HTMLLoadResult {
        // Check memory cache first
        let cacheKey = "\(messageId)_\(isDarkMode)_\(cleanupMode.rawValue)_\(displayPurpose.rawValue)" as NSString
        if let cachedHTML = htmlCache.object(forKey: cacheKey) {
            return HTMLLoadResult(html: cachedHTML as String, source: .messageId)
        }

        // Method 1: Try loading from message ID.
        // Treat empty HTML as missing so we can fall back to storage URI / recovery / plain text.
        if contentHandler.htmlFileExists(for: messageId),
           let html = contentHandler.loadHTML(for: messageId),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let wrapped = await wrappedHTMLIfMeaningful(
                html,
                messageId: messageId,
                senderEmail: senderEmail,
                isDarkMode: isDarkMode,
                cleanupMode: cleanupMode,
                displayPurpose: displayPurpose
            ) {
                if wrapped.shouldCache {
                    let cost = wrapped.html.utf8.count
                    htmlCache.setObject(wrapped.html as NSString, forKey: cacheKey, cost: cost)
                }
                return HTMLLoadResult(html: wrapped.html, source: .messageId)
            }
        }

        // Method 2: Try loading from stored URI
        if let urlString = bodyStorageURI,
           let url = StorageURIResolver.resolve(urlString),
           FileManager.default.fileExists(atPath: url.path),
           let html = contentHandler.loadHTML(from: url),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let wrapped = await wrappedHTMLIfMeaningful(
                html,
                messageId: messageId,
                senderEmail: senderEmail,
                isDarkMode: isDarkMode,
                cleanupMode: cleanupMode,
                displayPurpose: displayPurpose
            ) {
                if wrapped.shouldCache {
                    let cost = wrapped.html.utf8.count
                    htmlCache.setObject(wrapped.html as NSString, forKey: cacheKey, cost: cost)
                }
                return HTMLLoadResult(html: wrapped.html, source: .storageURI)
            }
        }

        // Method 3: Extract embedded HTML from raw RFC822 source stored in bodyText
        if let text = bodyText,
           let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: text),
           let wrapped = await wrappedHTMLIfMeaningful(
               rawSourceHTML,
               messageId: messageId,
               senderEmail: senderEmail,
               isDarkMode: isDarkMode,
               cleanupMode: cleanupMode,
               displayPurpose: displayPurpose
           ) {
            if wrapped.shouldCache {
                let cost = wrapped.html.utf8.count
                htmlCache.setObject(wrapped.html as NSString, forKey: cacheKey, cost: cost)
            }
            return HTMLLoadResult(html: wrapped.html, source: .rawSourceHTML)
        }

        // Method 4: Recovery - fetch from Gmail API if local content missing
        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId),
           let wrapped = await wrappedHTMLIfMeaningful(
               html,
               messageId: messageId,
               senderEmail: senderEmail,
               isDarkMode: isDarkMode,
               cleanupMode: cleanupMode,
               displayPurpose: displayPurpose
           ) {
            if wrapped.shouldCache {
                let cost = wrapped.html.utf8.count
                htmlCache.setObject(wrapped.html as NSString, forKey: cacheKey, cost: cost)
            }
            return HTMLLoadResult(html: wrapped.html, source: .recovered)
        }

        // Method 5: Plain text fallback (don't cache as it's trivial to generate)
        if let text = bodyText, !text.isEmpty {
            let normalizedText = normalizedPlainTextFallback(from: text)
            if hasMeaningfulPlainText(normalizedText) {
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
        }

        return HTMLLoadResult(html: nil, source: .notFound)
    }

    /// Loads content with timeout support
    func loadContentWithTimeout(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        senderEmail: String? = nil,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none,
        displayPurpose: HTMLDisplayPurpose = .preview,
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
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode,
                    displayPurpose: displayPurpose
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

    /// Invalidates cached HTML content for a message (both light/dark variants).
    func invalidate(messageId: String) {
        for isDarkMode in [false, true] {
            for cleanupMode in HTMLContentCleanupMode.allCases {
                for displayPurpose in HTMLDisplayPurpose.allCases {
                    let key = "\(messageId)_\(isDarkMode)_\(cleanupMode.rawValue)_\(displayPurpose.rawValue)" as NSString
                    htmlCache.removeObject(forKey: key)
                }
            }
        }
    }

    private func wrappedHTMLIfMeaningful(
        _ html: String,
        messageId: String,
        senderEmail: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose
    ) async -> WrappedHTMLResult? {
        let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)
        let sanitizedHTML = sanitizer.sanitize(
            preparedHTML,
            rewriteModernImageFormatHints: displayPurpose != .original
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(sanitizedHTML) else {
            return nil
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
            rewrittenHTML = sanitizer.sanitize(originalSafeHTML)
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

        let wrapped = sanitizer.wrapHTMLForDisplay(
            rewrittenHTML,
            isDarkMode: isDarkMode,
            displayPurpose: displayPurpose
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) else {
            return nil
        }

        return WrappedHTMLResult(html: wrapped, shouldCache: shouldCache)
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
