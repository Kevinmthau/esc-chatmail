import Foundation

/// Result of HTML content loading
struct HTMLLoadResult {
    let html: String?
    let source: HTMLLoadSource

    enum HTMLLoadSource {
        case messageId
        case storageURI
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
        // Limit cache to ~50MB assuming average 50KB per HTML
        htmlCache.countLimit = 1000
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
    /// - Returns: HTMLLoadResult with wrapped HTML and source indicator
    func loadContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String? = nil,
        isDarkMode: Bool
    ) async -> HTMLLoadResult {
        // Check memory cache first
        let cacheKey = "\(messageId)_\(isDarkMode)" as NSString
        if let cachedHTML = htmlCache.object(forKey: cacheKey) {
            return HTMLLoadResult(html: cachedHTML as String, source: .messageId)
        }

        // Method 1: Try loading from message ID
        if contentHandler.htmlFileExists(for: messageId),
           let html = contentHandler.loadHTML(for: messageId) {
            let wrapped = sanitizer.wrapHTMLForDisplay(html, isDarkMode: isDarkMode)
            htmlCache.setObject(wrapped as NSString, forKey: cacheKey)
            return HTMLLoadResult(html: wrapped, source: .messageId)
        }

        // Method 2: Try loading from stored URI
        if let urlString = bodyStorageURI,
           let url = resolveStorageURI(urlString),
           FileManager.default.fileExists(atPath: url.path),
           let html = contentHandler.loadHTML(from: url) {
            let wrapped = sanitizer.wrapHTMLForDisplay(html, isDarkMode: isDarkMode)
            htmlCache.setObject(wrapped as NSString, forKey: cacheKey)
            return HTMLLoadResult(html: wrapped, source: .storageURI)
        }

        // Method 3: Plain text fallback (don't cache as it's trivial to generate)
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
        timeout: TimeInterval = 5.0
    ) async -> HTMLLoadResult {
        return await withTaskGroup(of: HTMLLoadResult?.self) { group in
            // Content loading task
            group.addTask {
                await self.loadContent(
                    messageId: messageId,
                    bodyStorageURI: bodyStorageURI,
                    bodyText: bodyText,
                    isDarkMode: isDarkMode
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

    private func convertPlainTextToHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")

        return """
        <html>
        <body>
        <pre style="white-space: pre-wrap; word-wrap: break-word; font-family: -apple-system, system-ui;">
        \(escaped)
        </pre>
        </body>
        </html>
        """
    }
}
