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
        case recovered
        case plainTextFallback
        case notFound
    }
}

/// Service for loading HTML content from various sources
final class HTMLContentLoader {
    static let shared = HTMLContentLoader()

    private let contentHandler: HTMLContentHandler
    private let sanitizer: HTMLSanitizerService

    /// In-memory cache for wrapped HTML content to avoid repeated disk I/O
    /// Key format: "\(messageId)_\(isDarkMode)" to cache both light and dark variants
    private let htmlCache = NSCache<NSString, NSString>()

    init(
        contentHandler: HTMLContentHandler = HTMLContentHandler(),
        sanitizer: HTMLSanitizerService = .shared
    ) {
        self.contentHandler = contentHandler
        self.sanitizer = sanitizer
        // Limit cache to ~50MB with both count and cost limits for proper memory pressure response
        htmlCache.countLimit = 1000
        htmlCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    /// Resolves a storage URI string to a valid file URL
    func resolveStorageURI(_ urlString: String) -> URL? {
        if urlString.starts(with: "/") {
            return URL(fileURLWithPath: urlString)
        } else if urlString.starts(with: "file://") {
            return URL(string: urlString)
        } else {
            return URL(string: urlString)
        }
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
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none
    ) async -> HTMLLoadResult {
        // Check memory cache first
        let cacheKey = "\(messageId)_\(isDarkMode)_\(cleanupMode.rawValue)" as NSString
        if let cachedHTML = htmlCache.object(forKey: cacheKey) {
            return HTMLLoadResult(html: cachedHTML as String, source: .messageId)
        }

        // Method 1: Try loading from message ID.
        // Treat empty HTML as missing so we can fall back to storage URI / recovery / plain text.
        if contentHandler.htmlFileExists(for: messageId),
           let html = contentHandler.loadHTML(for: messageId),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)
            let wrapped = sanitizer.wrapHTMLForDisplay(preparedHTML, isDarkMode: isDarkMode)
            let cost = wrapped.utf8.count
            htmlCache.setObject(wrapped as NSString, forKey: cacheKey, cost: cost)
            return HTMLLoadResult(html: wrapped, source: .messageId)
        }

        // Method 2: Try loading from stored URI
        if let urlString = bodyStorageURI,
           let url = resolveStorageURI(urlString),
           FileManager.default.fileExists(atPath: url.path),
           let html = contentHandler.loadHTML(from: url),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)
            let wrapped = sanitizer.wrapHTMLForDisplay(preparedHTML, isDarkMode: isDarkMode)
            let cost = wrapped.utf8.count
            htmlCache.setObject(wrapped as NSString, forKey: cacheKey, cost: cost)
            return HTMLLoadResult(html: wrapped, source: .storageURI)
        }

        // Method 3: Recovery - fetch from Gmail API if local content missing
        if let html = await HTMLContentRecoveryService.shared.recoverHTMLContent(messageId: messageId) {
            let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)
            let wrapped = sanitizer.wrapHTMLForDisplay(preparedHTML, isDarkMode: isDarkMode)
            let cost = wrapped.utf8.count
            htmlCache.setObject(wrapped as NSString, forKey: cacheKey, cost: cost)
            return HTMLLoadResult(html: wrapped, source: .recovered)
        }

        // Method 4: Plain text fallback (don't cache as it's trivial to generate)
        if let text = bodyText, !text.isEmpty {
            let html = convertPlainTextToHTML(text)
            let wrapped = sanitizer.wrapHTMLForDisplay(html, isDarkMode: isDarkMode)
            return HTMLLoadResult(html: wrapped, source: .plainTextFallback)
        }

        return HTMLLoadResult(html: nil, source: .notFound)
    }

    /// Loads content with timeout support
    func loadContentWithTimeout(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode = .none,
        timeout: TimeInterval = 5.0
    ) async -> HTMLLoadResult {
        return await withTaskGroup(of: HTMLLoadResult?.self) { group in
            // Content loading task
            group.addTask {
                await self.loadContent(
                    messageId: messageId,
                    bodyStorageURI: bodyStorageURI,
                    bodyText: bodyText,
                    isDarkMode: isDarkMode,
                    cleanupMode: cleanupMode
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
                let key = "\(messageId)_\(isDarkMode)_\(cleanupMode.rawValue)" as NSString
                htmlCache.removeObject(forKey: key)
            }
        }
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
            if !hasMeaningfulHTMLContent(cleaned) {
                // If signature removal was too aggressive, fall back to quote-only cleanup.
                let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
                return fallbackToOriginalIfCleanedEmpty(cleaned: quotedOnly, original: html)
            }
            return cleaned
        }
    }

    private func fallbackToOriginalIfCleanedEmpty(cleaned: String, original: String) -> String {
        if hasMeaningfulHTMLContent(cleaned) {
            return cleaned
        }
        return original
    }

    private func hasMeaningfulHTMLContent(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // If it has obvious renderable media, treat it as meaningful even if text extraction is empty.
        if html.range(of: "<img", options: .caseInsensitive) != nil ||
            html.range(of: "<svg", options: .caseInsensitive) != nil ||
            html.range(of: "background-image", options: .caseInsensitive) != nil {
            return true
        }

        let extracted = TextProcessing.extractPlainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !extracted.isEmpty
    }

    private func convertPlainTextToHTML(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Match Apple Mail's default behavior: display the main content and collapse
        // quoted history behind a "See More" affordance.
        // Keep the sender's sign-off visible (signature removal is a chat-bubble concern).
        let extraction = PlainTextQuoteRemover.extractQuotes(from: normalized, removingSignature: false)

        func escapeHTML(_ input: String) -> String {
            input
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        let main = escapeHTML(extraction.mainContent)

        let quotedHTML: String = extraction.quotedParts.map { part in
            let quote = escapeHTML(part.text)
            let attribution = part.attribution.map { escapeHTML($0) }

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
        let detailsSection: String
        if !quotedHTML.isEmpty && !main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
}
