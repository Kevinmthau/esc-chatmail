import Foundation

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache {
    static let shared = ProcessedTextCache()

    /// Cached text content with rich content indicator
    struct CachedText: Sendable {
        let plainText: String?
        let hasRichContent: Bool
    }

    private let cache: LRUCacheActor<String, CachedText>

    init() {
        self.cache = LRUCacheActor(config: CacheConfiguration(
            maxItems: 500,
            maxMemoryBytes: nil,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))
    }

    func get(messageId: String) async -> (plainText: String?, hasRichContent: Bool)? {
        guard let entry = await cache.get(messageId) else { return nil }
        return (entry.plainText, entry.hasRichContent)
    }

    func set(messageId: String, plainText: String?, hasRichContent: Bool) async {
        await cache.set(messageId, value: CachedText(plainText: plainText, hasRichContent: hasRichContent))
    }

    func prefetch(messageIds: [String]) async {
        // Filter out already cached messages
        var uncachedIds: [String] = []
        for messageId in messageIds {
            if await !cache.contains(messageId) {
                uncachedIds.append(messageId)
            }
        }
        guard !uncachedIds.isEmpty else { return }

        // Process in batches on background thread
        await Task.detached(priority: .utility) { [uncachedIds] in
            let handler = HTMLContentHandler.shared

            for messageId in uncachedIds {
                let result = Self.processMessage(messageId: messageId, handler: handler)
                await self.set(messageId: messageId, plainText: result.plainText, hasRichContent: result.hasRichContent)
            }
        }.value
    }

    /// Process a single message - can be called from background thread
    nonisolated static func processMessage(messageId: String, handler: HTMLContentHandler) -> (plainText: String?, hasRichContent: Bool) {
        var plainText: String?
        var hasRichContent = false

        if handler.htmlFileExists(for: messageId),
           let html = handler.loadHTML(for: messageId) {
            let extracted = TextProcessing.extractPlainText(from: html)
            if !extracted.isEmpty {
                plainText = TextProcessing.stripQuotedText(from: extracted)
            }

            // Check for rich content (tables, images, video, iframes)
            let lowercased = html.lowercased()
            hasRichContent = lowercased.contains("<table") ||
                            lowercased.contains("<img") ||
                            lowercased.contains("<video") ||
                            lowercased.contains("<iframe")
        }

        return (plainText, hasRichContent)
    }

    func clear() async {
        await cache.clear()
    }

    /// Returns cache statistics for monitoring
    func getStatistics() async -> LRUCacheStatistics {
        await cache.getStatistics()
    }
}

// MARK: - Text Processing Helpers (nonisolated for background thread usage)
enum TextProcessing {
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert explicit line breaks to newlines
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)

        // Paragraphs and headings get double newlines (actual content breaks)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&#34;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")

        // Zero-width characters (strip entirely - they're invisible formatting)
        text = text.replacingOccurrences(of: "&zwnj;", with: "")
        text = text.replacingOccurrences(of: "&zwj;", with: "")
        text = text.replacingOccurrences(of: "&#8204;", with: "")
        text = text.replacingOccurrences(of: "&#8205;", with: "")
        text = text.replacingOccurrences(of: "&#x200C;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#x200D;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "\u{200C}", with: "")
        text = text.replacingOccurrences(of: "\u{200D}", with: "")
        text = text.replacingOccurrences(of: "\u{200B}", with: "") // zero-width space

        // Smart quotes and other typographic entities
        text = text.replacingOccurrences(of: "&ldquo;", with: "\"")
        text = text.replacingOccurrences(of: "&rdquo;", with: "\"")
        text = text.replacingOccurrences(of: "&lsquo;", with: "'")
        text = text.replacingOccurrences(of: "&rsquo;", with: "'")
        text = text.replacingOccurrences(of: "&#8220;", with: "\"")
        text = text.replacingOccurrences(of: "&#8221;", with: "\"")
        text = text.replacingOccurrences(of: "&#8216;", with: "'")
        text = text.replacingOccurrences(of: "&#8217;", with: "'")
        text = text.replacingOccurrences(of: "&ndash;", with: "–")
        text = text.replacingOccurrences(of: "&mdash;", with: "—")
        text = text.replacingOccurrences(of: "&#8211;", with: "–")
        text = text.replacingOccurrences(of: "&#8212;", with: "—")
        text = text.replacingOccurrences(of: "&hellip;", with: "…")
        text = text.replacingOccurrences(of: "&#8230;", with: "…")

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression, range: nil)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    static func stripQuotedText(from text: String) -> String {
        var normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Use regex for efficient multiple newline collapse instead of while loop
        normalizedText = normalizedText.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let lines = normalizedText.components(separatedBy: "\n")
        var newMessageLines: [String] = []
        var lastLineWasEmpty = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Stop at common quoted text markers
            if trimmedLine.starts(with: ">") ||
               (trimmedLine.starts(with: "On ") && trimmedLine.contains("wrote:")) ||
               (trimmedLine.starts(with: "From:") && index > 0) ||
               trimmedLine == "..." ||
               trimmedLine.contains("---------- Forwarded message ---------") ||
               trimmedLine.contains("________________________________") {
                break
            }

            // Skip consecutive empty lines
            let isEmptyLine = trimmedLine.isEmpty
            if isEmptyLine && lastLineWasEmpty {
                continue
            }
            lastLineWasEmpty = isEmptyLine

            newMessageLines.append(trimmedLine.isEmpty ? "" : line)
        }

        return newMessageLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
